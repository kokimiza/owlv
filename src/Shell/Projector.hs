{- | CQRS リードモデルへの転写装置 (doc/cqrs.md) — PostgreSQL の `events`
(Command側、追記専用の真実源) から SQLite3 のビュー (Query側、検索・一覧・
KPI専用) へイベントを転写する。業務ロジック (`decide`/`evolve`) を一切
含まないため Core ではなく Shell に置く — これは「業務に関係ない」配線
コードであり、CLAUDE.mdの「Coreは純粋、IOはShellのみ」という分割の
そのままの適用である。

このモジュールが SQLite への書き込みを行う唯一の場所になる
(doc/cqrs.md §3, §4.2 のシングルライター制約)。'Shell.ReadModel.openReadOnly'
で開く側 (TUI 画面の検索・一覧クエリ) は別モジュールに任せ、ここには
書き込みAPIしか置かない。
-}
module Shell.Projector
  ( ensureSchema
  , getCheckpoint
  , projectEvent
  , runCatchUpCycle
  , catchUpBatchSize
  ) where

import Control.Exception (Exception, throwIO)
import Data.Int (Int64)
import Data.List.NonEmpty (toList)
import Data.Time (Day, defaultTimeLocale, formatTime)

import Data.Decimal qualified as Decimal
import Data.Text qualified as T
import Data.UUID qualified as UUID
import Database.PostgreSQL.Simple qualified as PG
import Database.SQLite3 qualified as SQLite

import Core.Domain.Journal (DrCr (..), JournalEntry (..), JournalEntryId (..), JournalLine (..))
import Core.Domain.Money (Money, unMoney)
import Core.Domain.Tenant (TenantId)
import Core.Event (Event (..))
import Shell.AppError (AppError (..))
import Shell.EventStore (bindTenantSession, loadEventsSince)
import Shell.ReadModel (ReadModel, execWrite, queryRows, withWriteTransaction)

-- | 1回のカタッチアップで取得する最大イベント数 (doc/cqrs.md §3.2)。
catchUpBatchSize :: Int
catchUpBatchSize = 500

{- | リードモデルのスキーマを用意する (doc/cqrs.md §3.2, §5.4)。
何度呼んでも安全 (`IF NOT EXISTS`)。新しいビューを追加するときは、
マイグレーションではなくファイルの再構築で対応する方針 (doc/cqrs.md §7) —
そのためここに `ALTER TABLE` 相当の分岐は持たない。
-}
ensureSchema :: ReadModel -> IO (Either AppError ())
ensureSchema rm = runStatements rm schemaStatements

schemaStatements :: [T.Text]
schemaStatements =
  [ "CREATE TABLE IF NOT EXISTS _projector_checkpoint ( \
    \  id INTEGER PRIMARY KEY CHECK (id = 1), \
    \  last_seq INTEGER NOT NULL DEFAULT 0, \
    \  updated_at TEXT NOT NULL \
    \)"
  , "INSERT OR IGNORE INTO _projector_checkpoint (id, last_seq, updated_at) \
    \VALUES (1, 0, datetime('now'))"
  , -- doc/cqrs.md §5.4: 伝票検索 (Shell.TUI.Screen.VoucherSearch)。
    -- voucher_date/account_code は Haskell側で算出済みの実カラム
    -- (json_extractによる仮想カラムではない — §5.3と同じ理由: 値は
    -- すでに型付きで手元にあるため、SQL式での再導出を避ける)。
    "CREATE TABLE IF NOT EXISTS view_journal_entry ( \
    \  entry_id TEXT PRIMARY KEY, \
    \  voucher_date TEXT NOT NULL, \
    \  action_type TEXT NOT NULL, \
    \  account_code TEXT NOT NULL, \
    \  memo TEXT NOT NULL, \
    \  payload TEXT NOT NULL \
    \)"
  , "CREATE INDEX IF NOT EXISTS idx_view_journal_entry_date \
    \  ON view_journal_entry(voucher_date)"
  , "CREATE INDEX IF NOT EXISTS idx_view_journal_entry_account \
    \  ON view_journal_entry(account_code)"
  , -- doc/cqrs.md §5.3: balance_minor はHaskell側でMoneyから算出した固定精度の
    -- 整数(最小単位)。SQLite側でのCAST/json_extractによる再導出はしない
    -- (Doubleへの暗黙変換を読み取り経路に持ち込まないため)。
    "CREATE TABLE IF NOT EXISTS view_account_balance ( \
    \  account_code TEXT NOT NULL, \
    \  period TEXT NOT NULL, \
    \  debit_minor INTEGER NOT NULL DEFAULT 0, \
    \  credit_minor INTEGER NOT NULL DEFAULT 0, \
    \  balance_minor INTEGER NOT NULL DEFAULT 0, \
    \  updated_at TEXT NOT NULL, \
    \  PRIMARY KEY (account_code, period) \
    \)"
  , "CREATE INDEX IF NOT EXISTS idx_view_account_balance_period \
    \  ON view_account_balance(period)"
  ]

runStatements :: ReadModel -> [T.Text] -> IO (Either AppError ())
runStatements rm = go
 where
  go [] = pure (Right ())
  go (s : ss) = do
    result <- execWrite rm s []
    case result of
      Left err -> pure (Left err)
      Right () -> go ss

getCheckpoint :: ReadModel -> IO (Either AppError Int64)
getCheckpoint rm = do
  result <-
    queryRows
      rm
      "SELECT last_seq FROM _projector_checkpoint WHERE id = 1"
      []
      (\stmt -> SQLite.columnInt64 stmt 0)
  pure $ case result of
    Left err -> Left err
    Right [] -> Right 0
    Right (v : _) -> Right v

setCheckpoint :: ReadModel -> Int64 -> IO (Either AppError ())
setCheckpoint rm lastSeq =
  execWrite
    rm
    "UPDATE _projector_checkpoint SET last_seq = ?, updated_at = datetime('now') WHERE id = 1"
    [SQLite.SQLInteger lastSeq]

{- | 1イベントをビューへ転写する (doc/cqrs.md §5.4)。
未対応の Event 構成子は no-op (Right ()) — まだ専用ビューを持たない
イベント型は、対応するビューを追加するまで黙って無視する
(doc/cqrs.md §5.4 の初期セットのうち本実装で扱うのは journal/balance のみ。
固定資産・ECL・判断ログ・KPIは将来の拡張として残す)。
-}
projectEvent :: ReadModel -> Event -> IO (Either AppError ())
projectEvent rm (JournalEntryRecorded entry) = projectJournalEntry rm entry
projectEvent _ _ = pure (Right ())

projectJournalEntry :: ReadModel -> JournalEntry -> IO (Either AppError ())
projectJournalEntry rm entry = do
  r1 <- upsertJournalEntry rm entry
  case r1 of
    Left err -> pure (Left err)
    Right () -> upsertAccountBalances rm entry

upsertJournalEntry :: ReadModel -> JournalEntry -> IO (Either AppError ())
upsertJournalEntry rm entry =
  execWrite
    rm
    "INSERT INTO view_journal_entry \
    \  (entry_id, voucher_date, action_type, account_code, memo, payload) \
    \VALUES (?, ?, ?, ?, ?, ?) \
    \ON CONFLICT (entry_id) DO UPDATE SET \
    \  voucher_date = excluded.voucher_date, \
    \  action_type = excluded.action_type, \
    \  account_code = excluded.account_code, \
    \  memo = excluded.memo, \
    \  payload = excluded.payload"
    [ SQLite.SQLText (journalEntryIdText (entryId entry))
    , SQLite.SQLText (dayText (entryDate entry))
    , SQLite.SQLText (T.pack (show (entryActionType entry)))
    , SQLite.SQLText (firstLineAccountCode entry)
    , SQLite.SQLText (entryMemo entry)
    , SQLite.SQLText (encodeJsonText entry)
    ]

{- | 残高は「主キー = (account_code, period)」の上書きであり、増分の差分
管理はしない — このTenantのチェックポイント以前の全件を毎回正しく
再集計できることを優先する (doc/cqrs.md §5.4)。ここでは1イベント分の
増分加算のみを行い、`view_account_balance` 自体は冪等な
`ON CONFLICT DO UPDATE` で積み上げる。
-}
upsertAccountBalances :: ReadModel -> JournalEntry -> IO (Either AppError ())
upsertAccountBalances rm entry = go (toList (entryLines entry))
 where
  period = T.pack (formatTime defaultTimeLocale "%Y-%m" (entryDate entry))
  go [] = pure (Right ())
  go (l : ls) = do
    result <- upsertOneLine l
    case result of
      Left err -> pure (Left err)
      Right () -> go ls
  upsertOneLine l =
    let (debitMinor, creditMinor) = case lineDrCr l of
          Debit -> (moneyToMinor (lineAmount l), 0)
          Credit -> (0, moneyToMinor (lineAmount l))
    in execWrite
         rm
         "INSERT INTO view_account_balance \
         \  (account_code, period, debit_minor, credit_minor, balance_minor, updated_at) \
         \VALUES (?, ?, ?, ?, ?, datetime('now')) \
         \ON CONFLICT (account_code, period) DO UPDATE SET \
         \  debit_minor = view_account_balance.debit_minor + excluded.debit_minor, \
         \  credit_minor = view_account_balance.credit_minor + excluded.credit_minor, \
         \  balance_minor = view_account_balance.balance_minor + excluded.balance_minor, \
         \  updated_at = excluded.updated_at"
         [ SQLite.SQLText (accountCodeText l)
         , SQLite.SQLText period
         , SQLite.SQLInteger debitMinor
         , SQLite.SQLInteger creditMinor
         , SQLite.SQLInteger (debitMinor - creditMinor)
         ]

{- | Money を固定精度(6桁)の整数(最小単位)に変換する。
doc/cqrs.md §5.3: `Money` はJSON上では正確な10進文字列だが、SQLite側で
ソート・集計するために辞書順比較や float への CAST に頼ると数値順を
壊すか CLAUDE.md の "Double禁止" に反する。型付きの `Decimal` が手元にある
今のうちに一度だけ固定精度の整数へ変換し、実カラムとして保存する。
6桁は実務上のどの通貨の補助単位よりも余裕があるよう意図的に広く取る。
-}
moneyToMinor :: Money -> Int64
moneyToMinor m = fromIntegral (Decimal.decimalMantissa (Decimal.roundTo 6 (unMoney m)))

journalEntryIdText :: JournalEntryId -> T.Text
journalEntryIdText (JournalEntryId uuid) = UUID.toText uuid

dayText :: Day -> T.Text
dayText d = T.pack (formatTime defaultTimeLocale "%Y-%m-%d" d)

accountCodeText :: JournalLine -> T.Text
accountCodeText l = T.pack (show (lineAccount l))

firstLineAccountCode :: JournalEntry -> T.Text
firstLineAccountCode entry = case toList (entryLines entry) of
  (l : _) -> accountCodeText l
  [] -> ""

encodeJsonText :: JournalEntry -> T.Text
encodeJsonText = T.pack . show

{- | doc/cqrs.md §3.2 の1サイクル。`mTid = Nothing` は Identity stream。
ビュー書き込みとチェックポイント更新が同一SQLiteトランザクションで
コミットされるため、サイクルの途中でクラッシュしても取りこぼし・
重複のいずれも起こらない (§3.3)。戻り値は実際に処理したイベント数 ——
呼び出し側(app/ProjectorMain.hs)はこれが `catchUpBatchSize` と等しい間、
まだ追いついていない可能性が高いと判断して即座に次のサイクルを回せる。
-}
runCatchUpCycle :: PG.Connection -> ReadModel -> Maybe TenantId -> IO (Either AppError Int)
runCatchUpCycle conn rm mTid = do
  bindResult <- case mTid of
    Nothing -> pure (Right ())
    Just tid -> bindTenantSession conn tid
  case bindResult of
    Left err -> pure (Left err)
    Right () -> do
      checkpointResult <- getCheckpoint rm
      case checkpointResult of
        Left err -> pure (Left err)
        Right lastSeq -> do
          eventsResult <- loadEventsSince conn mTid lastSeq catchUpBatchSize
          case eventsResult of
            Left err -> pure (Left err)
            Right [] -> pure (Right 0)
            Right evts -> do
              txResult <- withWriteTransaction rm (applyAll rm evts)
              pure $ case txResult of
                Left err -> Left err
                Right () -> Right (length evts)

{- | 1サイクル分のイベントをすべて適用し、最後にチェックポイントを進める。
いずれか1件でも失敗したら 'ProjectorFailure' を投げる ——
'Shell.ReadModel.withWriteTransaction' はこれを `onException` で捕まえて
ROLLBACK してから再送するため、途中まで適用された状態が COMMIT されることはない
(`Either` を素直に返すだけでは、呼び出し元が `Left` を見てから明示的に
ROLLBACKする前に COMMIT が走ってしまう —— 失敗は必ず例外として投げる)。
-}
applyAll :: ReadModel -> [(Int64, Event)] -> IO ()
applyAll rm evts = do
  go evts
  case evts of
    [] -> pure ()
    _ -> do
      r <- setCheckpoint rm (maximum (map fst evts))
      either (throwIO . ProjectorFailure) pure r
 where
  go [] = pure ()
  go ((_, ev) : rest) = do
    r <- projectEvent rm ev
    either (throwIO . ProjectorFailure) pure r
    go rest

newtype ProjectorFailure = ProjectorFailure AppError

instance Show ProjectorFailure where
  show (ProjectorFailure e) = show e

instance Exception ProjectorFailure
