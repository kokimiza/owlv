{- | Append-only event store backed by PostgreSQL, with optimistic concurrency control.

Two physical streams share one `events` table, distinguished by the
`tenant_id` column (doc/tenant_isolation.md §4, §6):

  * Tenant stream: `tenant_id` is the owning Tenant. `TenantCreated` is the
    first event of a Tenant's own stream (it is not a separate "control
    plane" — see §4 for why that was rejected).
  * Identity stream: `tenant_id IS NULL`. Holds the User registry only,
    shared across all Tenants, because `UserId` is the OS account name and
    the AP VM has exactly one Unix namespace (§4.1).

Full DDL lives in infra/vm-db/schema.sql (applied by an operator as the
`owl_migrator` role — see doc/tenant_isolation.md §6.4 for why `owl_app`,
the runtime role this module connects as, must not own the tables: RLS is
not enforced against a table's owner). `runMigration` below is the same DDL
exposed for ad-hoc/dev use; keep the two in sync.

Connection is configured via libpq environment variables:
  PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD

Optimistic concurrency:
  esLoad returns the current StreamVersion (one counter per physical
  stream) alongside the merged, seq-ordered event list.
  esAppend takes the expected StreamVersion; for each physical stream that
  the given events actually touch, it locks that stream's counter row and
  compares it against the expected value. A mismatch on either touched
  counter returns Left AppConcurrencyConflict without writing anything.
  CommandExecutor retries the full load→decide→append cycle on conflict.
-}
module Shell.EventStore
  ( StreamVersion (..)
  , EventStore (..)
  , connectDb
  , forTenant
  , listActiveTenantIds
  , runMigration
  , loadEventsSince
  , bindTenantSession
  ) where

import Control.Exception (SomeException, try)
import Control.Monad (unless, void)
import Data.Int (Int64)
import Data.Text (Text)

import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as AesonKey
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as T
import Database.PostgreSQL.Simple qualified as PG

import Core.Domain.Tenant (Tenant (..), TenantId (..), TenantKind (..), TenantStatus (..))
import Core.Event (Event (..))
import Shell.AppError (AppError (..))
import Shell.EventClassification (isIdentityEvent)

-- | Tenant stream と Identity stream、それぞれの追記回数。楽観ロックの比較値。
data StreamVersion = StreamVersion
  { svTenant :: Int64
  , svIdentity :: Int64
  }
  deriving (Eq, Ord, Show)

{- | Interface for the append-only event store.
esLoad returns the current version together with events.
esAppend takes the expected version and returns AppConcurrencyConflict when
another writer has already advanced a stream that this append touches.
-}
data EventStore = EventStore
  { esLoad :: IO (Either AppError (StreamVersion, [Event]))
  , esAppend :: StreamVersion -> [Event] -> IO (Either AppError ())
  , esTenant :: TenantId
  {- ^ このハンドルが束縛されている Tenant（監査ログ用、doc/tenant_isolation.md §5.5）。
  呼び出し側がこれを使って別の Tenant の `esLoad`/`esAppend` を組み立てることは
  できない（あくまで「既に束縛済みのハンドルがどの Tenant か」を読み取るだけ）。
  -}
  }

{- | Connect to PostgreSQL. No DDL here — schema migration is an explicit,
separately-run operator step (infra/vm-db/schema.sql / runMigration),
because the runtime role this connects as (`owl_app`) must not own the
tables it queries (doc/tenant_isolation.md §6.4).
-}
connectDb :: IO (Either AppError PG.Connection)
connectDb = do
  result <- try @SomeException (PG.connectPostgreSQL "")
  pure $ case result of
    Left ex ->
      Left
        ( AppStorageError
            ( T.unlines
                [ "PostgreSQL 接続失敗"
                , ""
                , "接続情報を libpq 環境変数で設定してください:"
                , "  export PGHOST=localhost"
                , "  export PGPORT=5432"
                , "  export PGDATABASE=owl"
                , "  export PGUSER=owl_app"
                , "  export PGPASSWORD=..."
                , ""
                , "スキーマが未適用の場合は infra/vm-db/schema.sql を owl_migrator で適用してください。"
                , ""
                , "詳細: " <> T.pack (show ex)
                ]
            )
        )
    Right conn -> Right conn

{- | 指定 Tenant に束縛された EventStore を作る (doc/tenant_isolation.md §5.3)。
呼び出し側に生の TenantId を都度渡せる API にはしない —— この関数が返す
EventStore の値そのものが「すでにどの会社の帳簿か確定済みのハンドル」になる
ようにし、`esLoad`/`esAppend` の呼び出し側で TenantId を渡し間違える余地を
構造的に無くす。RLS 用のセッション変数 `app.tenant_id` をここで一度だけ
設定し、以後この EventStore の生存期間中はクロージャに束縛されたままにする。
-}
forTenant :: PG.Connection -> TenantId -> IO (Either AppError EventStore)
forTenant conn tid = do
  result <- bindTenantSession conn tid
  pure $ case result of
    Left err -> Left err
    Right () -> Right (mkTenantStore conn tid)

{- | RLSのセッション変数 `app.tenant_id` をこのコネクション上で設定する
(doc/tenant_isolation.md §5.3, §6.3)。`forTenant` 本体と `Shell.Projector`
の読み取り専用カタッチアップ (doc/cqrs.md §3.2) の双方から呼ばれる共通部分。
-}
bindTenantSession :: PG.Connection -> TenantId -> IO (Either AppError ())
bindTenantSession conn tid = do
  -- バインドパラメータ必須（doc/tenant_isolation.md §5.3: SQLインジェクション対策）。
  result <-
    try @SomeException $
      void $
        PG.execute conn "SELECT set_config('app.tenant_id', ?, false)" (PG.Only (unTenantId tid))
  pure $ case result of
    Left ex -> Left (AppStorageError (T.pack (show ex)))
    Right () -> Right ()

{- | アクティブな Tenant の一覧（doc/tenant_isolation.md §6.6: 日次バッチを
Tenantごとにループさせるための列挙）。`tenants` テーブルへの無条件 SELECT は
§6.1 で原則禁止（全Tenant名を見せない）だが、列を `tenant_id`/`status` だけに
絞った最小権限の GRANT を `owl_app` に追加で与える運用判断とする（schema.sql
参照）— バッチが処理対象を決めるには列挙手段が必須であり、名前やkind等の
付帯情報までは渡さない。
-}
listActiveTenantIds :: PG.Connection -> IO (Either AppError [TenantId])
listActiveTenantIds conn = safeIO $ do
  rows <- PG.query_ conn "SELECT tenant_id FROM tenants WHERE status = 'active'" :: IO [PG.Only Text]
  pure (map (TenantId . (\(PG.Only t) -> t)) rows)

mkTenantStore :: PG.Connection -> TenantId -> EventStore
mkTenantStore conn tid =
  EventStore
    { esLoad = safeIO (loadFromPg conn tid)
    , esAppend = appendToPg conn tid
    , esTenant = tid
    }

-- | Tenant streamとIdentity streamをマージしてseq順に読む。
loadFromPg :: PG.Connection -> TenantId -> IO (StreamVersion, [Event])
loadFromPg conn tid = do
  tenantVer <-
    queryOneVersion
      conn
      "SELECT version FROM stream_version WHERE tenant_id = ?"
      (PG.Only (unTenantId tid))
  identityVer <- queryOneVersion conn "SELECT version FROM identity_stream_version WHERE id = 1" ()
  rows <-
    PG.query
      conn
      "SELECT payload::text FROM events WHERE tenant_id = ? OR tenant_id IS NULL ORDER BY seq ASC"
      (PG.Only (unTenantId tid)) ::
      IO [PG.Only Text]
  events <- mapM (\(PG.Only txt) -> decodeEventText txt) rows
  pure (StreamVersion tenantVer identityVer, events)

decodeEventText :: Text -> IO Event
decodeEventText txt =
  case Aeson.eitherDecodeStrict (BS8.pack (T.unpack txt)) of
    Left err -> fail ("event decode failed: " <> err)
    Right ev -> pure ev

{- | `owlv-projector` (doc/cqrs.md §3.2) のカタッチアップ専用読み取り。
`Shell.EventStore.esLoad` (= 'loadFromPg') と違い、ストリーム全体ではなく
チェックポイント以降の差分だけを、`seq` 付きで返す。

`mTid = Just tid` の場合は呼び出し側が事前に 'bindTenantSession' で
RLSセッション変数を設定しておくこと（このクエリ自体も `tenant_id = ?` で
明示的に絞るが、RLSは多重防御の最終防衛線であり、ここでも有効にしておく
— doc/tenant_isolation.md §3）。`mTid = Nothing` は Identity stream
(`tenant_id IS NULL`) で、これは現在のRLSポリシー上いずれのセッションからも
無条件に見えるため事前の束縛は不要。
-}
loadEventsSince ::
  PG.Connection -> Maybe TenantId -> Int64 -> Int -> IO (Either AppError [(Int64, Event)])
loadEventsSince conn mTid afterSeq lim = safeIO $ do
  rows <- case mTid of
    Just tid ->
      PG.query
        conn
        "SELECT seq, payload::text FROM events \
        \WHERE tenant_id = ? AND seq > ? ORDER BY seq ASC LIMIT ?"
        (unTenantId tid, afterSeq, lim) ::
        IO [(Int64, Text)]
    Nothing ->
      PG.query
        conn
        "SELECT seq, payload::text FROM events \
        \WHERE tenant_id IS NULL AND seq > ? ORDER BY seq ASC LIMIT ?"
        (afterSeq, lim) ::
        IO [(Int64, Text)]
  mapM (\(s, txt) -> (,) s <$> decodeEventText txt) rows

queryOneVersion :: (PG.ToRow q) => PG.Connection -> PG.Query -> q -> IO Int64
queryOneVersion conn q params = do
  rows <- PG.query conn q params :: IO [PG.Only Int64]
  pure $ case rows of
    [PG.Only v] -> v
    _ -> 0 -- 行が無ければまだ何も追記されていない（Tenant未初期化等）。

{- | 与えられたイベント群が実際に触れるストリームだけバージョン確認・追記する
(doc/tenant_isolation.md §6.2 の「触れていないサブストリームの楽観ロックは
検査しない」という簡略化)。1コマンドの decide が生成するイベントは現状すべて
同種（Identity か Tenant のいずれか一方のみ）だが、将来の混在にも対応できる
よう両方を1トランザクションで処理する。
-}
appendToPg :: PG.Connection -> TenantId -> StreamVersion -> [Event] -> IO (Either AppError ())
appendToPg conn tid (StreamVersion expectedTenant expectedIdentity) evts = do
  result <- try @SomeException $ PG.withTransaction conn $ do
    tenantCurrent <-
      if null tenantEvts then pure expectedTenant else lockTenantVersion conn tid
    identityCurrent <-
      if null identityEvts then pure expectedIdentity else lockIdentityVersion conn
    if tenantCurrent /= expectedTenant || identityCurrent /= expectedIdentity
      then pure (Left AppConcurrencyConflict)
      else do
        unless (null tenantEvts) $ do
          syncTenantRegistry conn tenantEvts
          mapM_ (insertEvent conn (Just tid)) tenantEvts
          advanceTenantVersion conn tid (length tenantEvts)
          notifyProjector conn (unTenantId tid)
        unless (null identityEvts) $ do
          mapM_ (insertEvent conn Nothing) identityEvts
          advanceIdentityVersion conn (length identityEvts)
          notifyProjector conn "identity"
        pure (Right ())
  pure $ case result of
    Left ex -> Left (AppStorageError (T.pack (show ex)))
    Right x -> x
 where
  tenantEvts = filter (not . isIdentityEvent) evts
  identityEvts = filter isIdentityEvent evts

{- | コミット後に `owlv-projector` を起こすための、内容を持たない
"起きて" シグナル送信 (doc/cqrs.md §3.1)。

これは購読/Pull型アーキテクチャを崩すものではない —— `appendToPg` は
`Shell.Projector`/`Shell.ReadModel` を一切 import せず、SQLiteの存在も
スキーマも知らない。実際の状態転送は `owlv-projector` が自分の
`_projector_checkpoint` を起点に `loadEventsSince` で能動的に読みに行く
(Pull)側で行われ、`pg_notify` はそのポーリング間隔を短縮するだけの
レイテンシ最適化に過ぎない。リスナーが存在しなくても `pg_notify` は
エラーにならず単に無視されるため (fire-and-forget)、プロジェクターが
停止していてもイベントストアへの書き込みは何の影響も受けない —
コマンド側の「イベントを正しく検証してPostgreSQLへ安全に追記する」
という責務に、リードモデル側の都合は一切混入しない。

PostgreSQLのNOTIFYはトランザクションのコミット後にのみ配送されるため、
このトランザクションがロールバックされた場合に誤って配送されることもない。
チャンネル名は固定で、ペイロードに対象 (TenantIdの文字列、または
Identity streamを表す"identity") を積む。配送が欠落してもプロジェクター側の
ポーリング (§3.1) が最大2秒の遅延で追従するため、NOTIFY自体の到達は
ベストエフォートでよい。
-}
notifyProjector :: PG.Connection -> Text -> IO ()
notifyProjector conn payload =
  void $ PG.execute conn "SELECT pg_notify('owlv_events', ?)" (PG.Only payload)

-- | stream_version行が無ければ0で作成してからFOR UPDATEで行ロックする。
lockTenantVersion :: PG.Connection -> TenantId -> IO Int64
lockTenantVersion conn tid = do
  _ <-
    PG.execute
      conn
      "INSERT INTO stream_version (tenant_id, version) VALUES (?, 0) ON CONFLICT (tenant_id) DO NOTHING"
      (PG.Only (unTenantId tid))
  [PG.Only v] <-
    PG.query
      conn
      "SELECT version FROM stream_version WHERE tenant_id = ? FOR UPDATE"
      (PG.Only (unTenantId tid)) ::
      IO [PG.Only Int64]
  pure v

lockIdentityVersion :: PG.Connection -> IO Int64
lockIdentityVersion conn = do
  [PG.Only v] <-
    PG.query_ conn "SELECT version FROM identity_stream_version WHERE id = 1 FOR UPDATE" ::
      IO [PG.Only Int64]
  pure v

advanceTenantVersion :: PG.Connection -> TenantId -> Int -> IO ()
advanceTenantVersion conn tid n =
  void $
    PG.execute
      conn
      "UPDATE stream_version SET version = version + ? WHERE tenant_id = ?"
      (fromIntegral n :: Int64, unTenantId tid)

advanceIdentityVersion :: PG.Connection -> Int -> IO ()
advanceIdentityVersion conn n =
  void $
    PG.execute
      conn
      "UPDATE identity_stream_version SET version = version + ? WHERE id = 1"
      (PG.Only (fromIntegral n :: Int64))

{- | TenantCreated/TenantSuspended/TenantArchived を `tenants` レジストリ
テーブルにも反映する。`events` への追記と同一トランザクションで行うため、
events.tenant_id の外部キー制約は TenantCreated の時点で必ず満たされる
(doc/tenant_isolation.md §6.1)。
-}
syncTenantRegistry :: PG.Connection -> [Event] -> IO ()
syncTenantRegistry conn = mapM_ syncOne
 where
  syncOne (TenantCreated t) =
    void $
      PG.execute
        conn
        "INSERT INTO tenants (tenant_id, name, status, kind, kind_detail) \
        \VALUES (?, ?, ?, ?, ?::jsonb) ON CONFLICT (tenant_id) DO NOTHING"
        ( unTenantId (tenantId t)
        , tenantName t
        , statusText (tenantStatus t)
        , kindText (tenantKind t)
        , kindDetailJson (tenantKind t)
        )
  syncOne (TenantSuspended tid') =
    void $
      PG.execute
        conn
        "UPDATE tenants SET status = ? WHERE tenant_id = ?"
        (statusText TenantStatusSuspended, unTenantId tid')
  syncOne (TenantArchived tid') =
    void $
      PG.execute
        conn
        "UPDATE tenants SET status = ? WHERE tenant_id = ?"
        (statusText TenantStatusArchived, unTenantId tid')
  syncOne _ = pure ()

statusText :: TenantStatus -> Text
statusText TenantStatusActive = "active"
statusText TenantStatusSuspended = "suspended"
statusText TenantStatusArchived = "archived"

kindText :: TenantKind -> Text
kindText StandaloneTenant = "standalone"
kindText (ConsolidationTenant _) = "consolidation"

kindDetailJson :: TenantKind -> Maybe Text
kindDetailJson StandaloneTenant = Nothing
kindDetailJson k@(ConsolidationTenant _) =
  Just (T.pack (BS8.unpack (LBS.toStrict (Aeson.encode k))))

insertEvent :: PG.Connection -> Maybe TenantId -> Event -> IO ()
insertEvent conn mTid ev =
  void $
    PG.execute
      conn
      "INSERT INTO events (event_type, payload, tenant_id) VALUES (?, ?::jsonb, ?)"
      (eventType ev, payloadText ev, fmap unTenantId mTid)
 where
  payloadText e = T.pack (BS8.unpack (LBS.toStrict (Aeson.encode e)))

eventType :: Event -> Text
eventType ev = case Aeson.toJSON ev of
  Aeson.Object km ->
    case KeyMap.lookup (AesonKey.fromString "type") km of
      Just (Aeson.String t) -> t
      _ -> "Unknown"
  _ -> "Unknown"

-- | Catch any synchronous exception and wrap it as a StorageError.
safeIO :: IO a -> IO (Either AppError a)
safeIO action = do
  result <- try @SomeException action
  pure $ case result of
    Left ex -> Left (AppStorageError (T.pack (show ex)))
    Right v -> Right v

{- | infra/vm-db/schema.sql と同じDDL。`owl_migrator`（テーブル所有者）として
実行することを前提とする — `owl_app` で実行すると ALTER TABLE 等が権限不足で
失敗する（doc/tenant_isolation.md §6.4 の意図通り）。本番運用では
schema.sql を直接 psql で適用する運用とし、この関数は開発時の補助に使う。
2つを同期させること。
-}
runMigration :: PG.Connection -> IO ()
runMigration conn = do
  _ <-
    PG.execute_
      conn
      "CREATE TABLE IF NOT EXISTS tenants \
      \( tenant_id   UUID        PRIMARY KEY \
      \, name        TEXT        NOT NULL \
      \, status      TEXT        NOT NULL DEFAULT 'active' \
      \              CHECK (status IN ('active', 'suspended', 'archived')) \
      \, kind        TEXT        NOT NULL DEFAULT 'standalone' \
      \              CHECK (kind IN ('standalone', 'consolidation')) \
      \, kind_detail JSONB \
      \, created_at  TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp() \
      \)"
  _ <-
    PG.execute_
      conn
      "CREATE TABLE IF NOT EXISTS events \
      \( seq          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY \
      \, event_id     UUID        NOT NULL DEFAULT uuidv7() \
      \, event_type   TEXT        NOT NULL \
      \, payload      JSONB       NOT NULL \
      \, payload_type TEXT GENERATED ALWAYS AS (payload ->> 'type') VIRTUAL \
      \, tenant_id    UUID        REFERENCES tenants (tenant_id) \
      \, recorded_at  TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp() \
      \, CONSTRAINT events_type_matches_payload \
      \    CHECK (payload_type IS NULL OR payload_type = event_type) \
      \)"
  -- 既存DBからのアップグレード用（フレッシュインストールでは無害な no-op）。
  _ <-
    PG.execute_
      conn
      "ALTER TABLE events ADD COLUMN IF NOT EXISTS tenant_id UUID REFERENCES tenants (tenant_id)"
  _ <-
    PG.execute_
      conn
      "CREATE UNIQUE INDEX IF NOT EXISTS events_event_id_key ON events (event_id)"
  _ <- PG.execute_ conn "DROP INDEX IF EXISTS events_event_type_seq_idx"
  _ <-
    PG.execute_
      conn
      "CREATE INDEX IF NOT EXISTS events_tenant_type_seq_idx ON events (tenant_id, event_type, seq)"
  _ <-
    PG.execute_
      conn
      "CREATE INDEX IF NOT EXISTS events_recorded_at_idx ON events (recorded_at)"
  _ <-
    PG.execute_
      conn
      "CREATE TABLE IF NOT EXISTS stream_version \
      \( tenant_id UUID   PRIMARY KEY REFERENCES tenants (tenant_id) \
      \, version   BIGINT NOT NULL DEFAULT 0 \
      \)"
  _ <-
    PG.execute_
      conn
      "CREATE TABLE IF NOT EXISTS identity_stream_version \
      \( id      INT    PRIMARY KEY CHECK (id = 1) \
      \, version BIGINT NOT NULL DEFAULT 0 \
      \)"
  _ <-
    PG.execute_
      conn
      "INSERT INTO identity_stream_version (id, version) VALUES (1, 0) ON CONFLICT DO NOTHING"
  -- RLS（doc/tenant_isolation.md §6.3）。fail-closed: app.tenant_id 未設定時は0件。
  _ <- PG.execute_ conn "ALTER TABLE events ENABLE ROW LEVEL SECURITY"
  _ <- PG.execute_ conn "ALTER TABLE events FORCE ROW LEVEL SECURITY"
  _ <- PG.execute_ conn "DROP POLICY IF EXISTS events_tenant_select ON events"
  _ <-
    PG.execute_
      conn
      "CREATE POLICY events_tenant_select ON events USING ( \
      \  tenant_id IS NULL \
      \  OR tenant_id = current_setting('app.tenant_id', true)::uuid \
      \)"
  _ <- PG.execute_ conn "DROP POLICY IF EXISTS events_tenant_insert ON events"
  _ <-
    PG.execute_
      conn
      "CREATE POLICY events_tenant_insert ON events FOR INSERT WITH CHECK ( \
      \  tenant_id IS NULL \
      \  OR tenant_id = current_setting('app.tenant_id', true)::uuid \
      \)"
  _ <- PG.execute_ conn "ALTER TABLE stream_version ENABLE ROW LEVEL SECURITY"
  _ <- PG.execute_ conn "ALTER TABLE stream_version FORCE ROW LEVEL SECURITY"
  _ <- PG.execute_ conn "DROP POLICY IF EXISTS stream_version_tenant ON stream_version"
  _ <-
    PG.execute_
      conn
      "CREATE POLICY stream_version_tenant ON stream_version USING ( \
      \  tenant_id = current_setting('app.tenant_id', true)::uuid \
      \) WITH CHECK ( \
      \  tenant_id = current_setting('app.tenant_id', true)::uuid \
      \)"
  -- 日次バッチが処理対象Tenantを自前で列挙するための最小権限GRANT
  -- (doc/tenant_isolation.md §6.6, listActiveTenantIds)。
  _ <- PG.execute_ conn "GRANT SELECT (tenant_id, status) ON tenants TO owl_app"
  pure ()
