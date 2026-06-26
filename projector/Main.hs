{- | owlv-projector — CQRS リードモデルへの転写デーモン (doc/cqrs.md)。

PostgreSQL の `events` を購読 (Pull型・LISTEN/NOTIFYでウェイクアップ短縮、
doc/cqrs.md §3.1) し、SQLite3 のビューへ転写する。アルゴリズム本体
(スキーマ用意・1サイクルの転写・チェックポイント管理) は
'Shell.Projector'/'Shell.ReadModel' に置き、ここはデーモンのループ・
ファイルハンドルのキャッシュ・CLI・終了コードだけを扱う ——
CLAUDE.mdの「app/Main.hs は config・wiring・startup のみ」という方針を
この実行ファイルにも適用したもの (batch/Main.hs と同じ役割分担)。
-}
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, try)
import Control.Monad (forever, void)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Time.Clock (NominalDiffTime, diffUTCTime, getCurrentTime)
import Options.Applicative
import System.Directory (removeFile)
import System.Exit (ExitCode (..), exitFailure, exitWith)
import System.IO (hPutStrLn, stderr)
import System.Timeout (timeout)

import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Database.PostgreSQL.Simple qualified as PG
import Database.PostgreSQL.Simple.Notification qualified as PGN

import Core.Domain.Tenant (TenantId, mkTenantId)
import Shell.AppError (AppError)
import Shell.EventStore (connectDb, listActiveTenantIds)
import Shell.Projector (ensureSchema, runCatchUpCycle)
import Shell.ReadModel
  ( ReadModel
  , ReadModelTarget (..)
  , closeReadModel
  , openReadWrite
  , readModelPath
  )

data RebuildTarget = RebuildIdentity | RebuildTenant Text | RebuildAll

data Cmd = Run | Rebuild RebuildTarget

-- | NOTIFY を取り逃しても2秒で必ず追いつく (doc/cqrs.md §3.1)。
pollIntervalMicros :: Int
pollIntervalMicros = 2 * 1000 * 1000

parser :: Parser Cmd
parser =
  subparser
    ( command "run" (info (pure Run) (progDesc "常駐デーモンとして起動 (既定)"))
        <> command
          "rebuild"
          ( info
              ((Rebuild <$> rebuildTargetParser) <**> helper)
              (progDesc "対象のSQLiteファイルを破棄し、Postgresから全件再生する (doc/cqrs.md §7)")
          )
    )
    <|> pure Run

rebuildTargetParser :: Parser RebuildTarget
rebuildTargetParser =
  argument
    str
    (metavar "identity|all|<tenant_id>" <> help "再構築対象")
    <&> toTarget
 where
  toTarget "identity" = RebuildIdentity
  toTarget "all" = RebuildAll
  toTarget t = RebuildTenant (T.pack t)
  (<&>) p f = f <$> p

opts :: ParserInfo Cmd
opts =
  info
    (parser <**> helper)
    ( fullDesc
        <> progDesc "owlv リードモデル転写デーモン — ロジック本体は Shell.Projector"
        <> header "owlv-projector"
    )

main :: IO ()
main = do
  cmd <- execParser opts
  case cmd of
    Run -> runDaemon
    Rebuild target -> runRebuild target

die99 :: AppError -> IO a
die99 err = do
  hPutStrLn stderr ("起動エラー: " <> show err)
  exitWith (ExitFailure 99)

reportError :: String -> AppError -> IO ()
reportError ctx err = hPutStrLn stderr (ctx <> ": " <> show err)

-- ─────────────────────────────────────────────────────────────
-- run: 常駐デーモン
-- ─────────────────────────────────────────────────────────────

-- | 再接続バックオフの初期値・上限（doc/cqrs.md §3.1 のSPOF対策）。
baseReconnectDelayMicros, maxReconnectDelayMicros :: Int
baseReconnectDelayMicros = 1 * 1000 * 1000
maxReconnectDelayMicros = 5 * 1000 * 1000

-- | 接続が一定時間以上持続したら「安定接続」とみなしバックオフをリセットする。
stableConnectionSeconds :: NominalDiffTime
stableConnectionSeconds = 30

runDaemon :: IO ()
runDaemon = do
  cacheRef <- newIORef Map.empty
  runWithReconnect cacheRef baseReconnectDelayMicros

{- | 接続して常駐ループを実行する。ループ本体が例外で落ちたら
（PG接続断など）、古い read-model ハンドルを捨てて指数バックオフの後に
再接続する。安定して動いていた接続が落ちた場合はバックオフを初期値に戻す。
1テナント単位の失敗は 'sweepOne' が既に吸収しているので、ここで捕まえるのは
「共有 PG.Connection 自体が壊れた」場合だけ。
-}
runWithReconnect :: IORef (Map ReadModelTarget ReadModel) -> Int -> IO ()
runWithReconnect cacheRef delayMicros = do
  connResult <- connectDb
  case connResult of
    Left err -> do
      reportError "PostgreSQL接続失敗、再試行します" err
      threadDelay delayMicros
      runWithReconnect cacheRef (nextDelay delayMicros)
    Right conn -> do
      startedAt <- getCurrentTime
      outcome <- try @SomeException (daemonLoop conn cacheRef)
      PG.close conn
      clearCache cacheRef
      case outcome of
        Left ex -> hPutStrLn stderr ("常駐ループ例外、再接続します: " <> show ex)
        Right () -> pure ()
      finishedAt <- getCurrentTime
      let ranLongEnough = diffUTCTime finishedAt startedAt >= stableConnectionSeconds
          delayMicros' = if ranLongEnough then baseReconnectDelayMicros else nextDelay delayMicros
      threadDelay delayMicros'
      runWithReconnect cacheRef delayMicros'

nextDelay :: Int -> Int
nextDelay d = min maxReconnectDelayMicros (d * 2)

clearCache :: IORef (Map ReadModelTarget ReadModel) -> IO ()
clearCache cacheRef = do
  cache <- readIORef cacheRef
  mapM_ closeReadModel (Map.elems cache)
  modifyIORef' cacheRef (const Map.empty)

daemonLoop :: PG.Connection -> IORef (Map ReadModelTarget ReadModel) -> IO ()
daemonLoop conn cacheRef = do
  _ <- PG.execute_ conn "LISTEN owlv_events"
  forever $ do
    sweepAll conn cacheRef
    -- 通知を待つが、最大 pollIntervalMicros で必ず諦めて次サイクルへ進む。
    -- (Maybe Notification の中身は使わない — payload を見て対象を絞る
    -- 最適化はせず、毎サイクル全Tenant + Identityを素直に掃く。
    -- doc/cqrs.md §5.4 のKPIビューと同じ「再計算すれば必ず合う」方針)
    void (timeout pollIntervalMicros (PGN.getNotification conn))

sweepAll :: PG.Connection -> IORef (Map ReadModelTarget ReadModel) -> IO ()
sweepAll conn cacheRef = do
  tidsResult <- listActiveTenantIds conn
  case tidsResult of
    Left err -> reportError "アクティブTenant一覧取得失敗" err
    Right tids -> mapM_ (sweepOne conn cacheRef) (Identity : map ForTenant tids)

sweepOne :: PG.Connection -> IORef (Map ReadModelTarget ReadModel) -> ReadModelTarget -> IO ()
sweepOne conn cacheRef target = do
  rmResult <- getOrOpen cacheRef target
  case rmResult of
    Left err -> reportError ("readmodel open失敗 " <> show target) err
    Right rm -> do
      let mTid = targetTenant target
      drainResult <- drainCatchUp conn rm mTid
      case drainResult of
        Left err -> reportError ("catch-up失敗 " <> show target) err
        Right () -> pure ()

targetTenant :: ReadModelTarget -> Maybe TenantId
targetTenant Identity = Nothing
targetTenant (ForTenant tid) = Just tid

{- | 0件になるまで繰り返す。`catchUpBatchSize` ぴったりで返ってきた間は
まだ追いついていない可能性が高いため、NOTIFY/ポーリングを待たずに連続で回す。
-}
drainCatchUp :: PG.Connection -> ReadModel -> Maybe TenantId -> IO (Either AppError ())
drainCatchUp conn rm mTid = do
  r <- runCatchUpCycle conn rm mTid
  case r of
    Left err -> pure (Left err)
    Right 0 -> pure (Right ())
    Right _ -> drainCatchUp conn rm mTid

getOrOpen ::
  IORef (Map ReadModelTarget ReadModel) -> ReadModelTarget -> IO (Either AppError ReadModel)
getOrOpen cacheRef target = do
  cache <- readIORef cacheRef
  case Map.lookup target cache of
    Just rm -> pure (Right rm)
    Nothing -> do
      opened <- openReadWrite target
      case opened of
        Left err -> pure (Left err)
        Right rm -> do
          schemaResult <- ensureSchema rm
          case schemaResult of
            Left err -> do
              closeReadModel rm
              pure (Left err)
            Right () -> do
              modifyIORef' cacheRef (Map.insert target rm)
              pure (Right rm)

-- ─────────────────────────────────────────────────────────────
-- rebuild: SQLiteファイルを破棄して全件再生 (doc/cqrs.md §7)
-- ─────────────────────────────────────────────────────────────

runRebuild :: RebuildTarget -> IO ()
runRebuild rt = do
  connResult <- connectDb
  case connResult of
    Left err -> die99 err
    Right conn -> do
      targetsResult <- resolveTargets rt conn
      case targetsResult of
        Left msg -> hPutStrLn stderr msg >> exitFailure
        Right targets -> mapM_ (rebuildOne conn) targets

resolveTargets :: RebuildTarget -> PG.Connection -> IO (Either String [ReadModelTarget])
resolveTargets RebuildIdentity _ = pure (Right [Identity])
resolveTargets RebuildAll conn = do
  tidsResult <- listActiveTenantIds conn
  pure $ case tidsResult of
    Left err -> Left ("Tenant一覧取得失敗: " <> show err)
    Right tids -> Right (Identity : map ForTenant tids)
resolveTargets (RebuildTenant t) _ = pure $ case mkTenantId t of
  Left err -> Left ("不正な tenant id: " <> T.unpack err)
  Right tid -> Right [ForTenant tid]

rebuildOne :: PG.Connection -> ReadModelTarget -> IO ()
rebuildOne conn target = case readModelPath target of
  Left err -> reportError ("パス解決失敗 " <> show target) err
  Right path -> do
    -- WAL/SHM の残骸も一緒に消す。無ければ単に無視する。
    mapM_
      (\p -> void (try @SomeException (removeFile p)))
      [path, path <> "-wal", path <> "-shm"]
    opened <- openReadWrite target
    case opened of
      Left err -> reportError ("再作成失敗 " <> show target) err
      Right rm -> do
        schemaResult <- ensureSchema rm
        case schemaResult of
          Left err -> reportError ("スキーマ作成失敗 " <> show target) err
          Right () -> do
            drainResult <- drainCatchUp conn rm (targetTenant target)
            case drainResult of
              Left err -> reportError ("再生失敗 " <> show target) err
              Right () -> hPutStrLn stderr ("再構築完了: " <> show target)
        closeReadModel rm
