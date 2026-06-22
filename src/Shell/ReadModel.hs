{- | SQLite3 リードモデルへの接続管理 (doc/cqrs.md §4, §5)。

Tenantごとに物理的に別ファイルへ分離する(doc/cqrs.md §4.1) — SQLiteには
PostgreSQLのRLSに相当する機構が無いため、「WHERE tenant_id を書き忘れる」
という事故そのものが起こり得ないよう、ファイル分離をTenant隔離の境界に
する。`owlv-app` (TUI) はここを通じて 'openReadOnly' (SQLITE_OPEN_READONLY)
でのみ開き、書き込みAPI自体を公開しない。書き込みは 'Shell.Projector' だけが
'openReadWrite' を使う (doc/cqrs.md §4.2 のシングルライター制約の実体)。
-}
module Shell.ReadModel
  ( ReadModelTarget (..)
  , ReadModel
  , readModelPath
  , openReadOnly
  , openReadWrite
  , closeReadModel
  , queryRows
  , execWrite
  , withWriteTransaction
  ) where

import Control.Exception (SomeException, onException, try)
import Data.Text (Text)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))

import Data.Text qualified as T
import Database.SQLite3 qualified as SQLite

import Core.Domain.Tenant (TenantId (..))
import Shell.AppError (AppError (..))

-- | Identity stream (Userレジストリ等、doc/tenant_isolation.md §4) か、特定の Tenant か。
data ReadModelTarget = Identity | ForTenant TenantId
  deriving (Eq, Ord, Show)

-- | リードモデルファイル群の置き場所 (doc/cqrs.md §2)。AP VM ローカルディスク。
readModelDir :: FilePath
readModelDir = "/var/lib/owlv/readmodel"

newtype ReadModel = ReadModel {rmDb :: SQLite.Database}

{- | ファイル名コンポーネントとして安全な文字だけを許可する。
'Core.Domain.Tenant.mkTenantId' は空文字列しか拒否しないため、ここで
追加の検証を行う — ファイル分離そのものがTenant隔離の境界になる設計
(§4.1) なので、ファイル名生成経路にパストラバーサルの余地を一切
残してはならない。
-}
safeFileComponent :: Text -> Either AppError Text
safeFileComponent t
  | T.null t = Left (AppInputError "tenant id が空です")
  | T.all isSafeChar t = Right t
  | otherwise = Left (AppInputError ("tenant id に使用できない文字が含まれています: " <> t))
 where
  isSafeChar c =
    (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-'

readModelPath :: ReadModelTarget -> Either AppError FilePath
readModelPath Identity = Right (readModelDir </> "identity.sqlite3")
readModelPath (ForTenant tid) = do
  safe <- safeFileComponent (unTenantId tid)
  Right (readModelDir </> (T.unpack safe <> ".sqlite3"))

{- | TUIなど読み取り専用クライアント用。ファイルが存在しなければ失敗する
(リードモデルの新規作成は常に 'Shell.Projector' の責務であり、読み取り側が
副作用として作成してしまうことを避ける)。
-}
openReadOnly :: ReadModelTarget -> IO (Either AppError ReadModel)
openReadOnly target = case readModelPath target of
  Left err -> pure (Left err)
  Right path -> do
    result <-
      try @SomeException $
        SQLite.open2 (T.pack path) [SQLite.SQLOpenReadOnly] SQLite.SQLVFSDefault
    pure $ case result of
      Left ex -> Left (AppConnectionError ("read model open (RO) failed: " <> T.pack (show ex)))
      Right db -> Right (ReadModel db)

{- | 'Shell.Projector' 専用。ディレクトリ・ファイルが無ければ作成し、
WALモード等のPRAGMAを設定する (doc/cqrs.md §5.1)。
-}
openReadWrite :: ReadModelTarget -> IO (Either AppError ReadModel)
openReadWrite target = case readModelPath target of
  Left err -> pure (Left err)
  Right path -> do
    createDirectoryIfMissing True readModelDir
    result <- try @SomeException $ do
      db <-
        SQLite.open2
          (T.pack path)
          [SQLite.SQLOpenReadWrite, SQLite.SQLOpenCreate]
          SQLite.SQLVFSDefault
      SQLite.exec db "PRAGMA journal_mode = WAL"
      SQLite.exec db "PRAGMA synchronous = NORMAL"
      SQLite.exec db "PRAGMA busy_timeout = 5000"
      SQLite.exec db "PRAGMA foreign_keys = ON"
      pure db
    pure $ case result of
      Left ex -> Left (AppConnectionError ("read model open (RW) failed: " <> T.pack (show ex)))
      Right db -> Right (ReadModel db)

closeReadModel :: ReadModel -> IO ()
closeReadModel = SQLite.close . rmDb

{- | SELECT専用。`readRow` は1行分のカラム読み出しを呼び出し側で行う
(列数・型は呼び出し側がスキーマを把握している前提 — doc/cqrs.md §5.4 の
各ビューごとに専用の readRow を書く)。
-}
queryRows ::
  ReadModel ->
  Text ->
  [SQLite.SQLData] ->
  (SQLite.Statement -> IO a) ->
  IO (Either AppError [a])
queryRows rm sql params readRow = do
  result <- try @SomeException $ do
    stmt <- SQLite.prepare (rmDb rm) sql
    SQLite.bind stmt params
    let loop acc = do
          r <- SQLite.step stmt
          case r of
            SQLite.Done -> pure (reverse acc)
            SQLite.Row -> do
              row <- readRow stmt
              loop (row : acc)
    rows <- loop [] `onException` SQLite.finalize stmt
    SQLite.finalize stmt
    pure rows
  pure $ case result of
    Left ex -> Left (AppStorageError (T.pack (show ex)))
    Right rows -> Right rows

-- | INSERT/UPDATE専用 (`Shell.Projector` のビュー書き込み)。1文のみ実行する。
execWrite :: ReadModel -> Text -> [SQLite.SQLData] -> IO (Either AppError ())
execWrite rm sql params = do
  result <- try @SomeException $ do
    stmt <- SQLite.prepare (rmDb rm) sql
    (SQLite.bind stmt params >> SQLite.step stmt >> pure ())
      `onException` SQLite.finalize stmt
    SQLite.finalize stmt
  pure $ case result of
    Left ex -> Left (AppStorageError (T.pack (show ex)))
    Right () -> Right ()

{- | プロジェクター1サイクル分のトランザクション (doc/cqrs.md §3.2-3.3)。
ビュー書き込みとチェックポイント更新を同一トランザクションでコミットすることで、
クラッシュ時に「ビューだけ進んでチェックポイントが古いまま」という
ズレを構造的に起こさない。
-}
withWriteTransaction :: ReadModel -> IO a -> IO (Either AppError a)
withWriteTransaction rm action = do
  result <- try @SomeException $ do
    SQLite.exec (rmDb rm) "BEGIN IMMEDIATE"
    r <- action `onException` SQLite.exec (rmDb rm) "ROLLBACK"
    SQLite.exec (rmDb rm) "COMMIT"
    pure r
  pure $ case result of
    Left ex -> Left (AppStorageError (T.pack (show ex)))
    Right v -> Right v
