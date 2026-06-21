-- infra/vm-db/schema.sql — owlv イベントストア スキーマ定義
--
-- 適用方法 (doc/tenant_isolation.md §6.4, infra/vm-db/setup.sh の手順3):
--   psql -U owl_migrator owl -f infra/vm-db/schema.sql
--
-- owl_migrator（テーブル所有者）として実行すること。owl_app で実行すると
-- 以降のALTER等が権限不足で失敗する。owl_app をテーブル所有者にしないのは、
-- PostgreSQLのRLSは所有者には適用されないため — 所有者のままだと
-- FORCE ROW LEVEL SECURITY を付けても実質RLSが無効化される。
--
-- Shell.EventStore.runMigration と同じDDL。両者は同期させること。
-- 詳細な設計根拠は doc/tenant_isolation.md を参照。

CREATE TABLE IF NOT EXISTS tenants
( tenant_id   UUID        PRIMARY KEY
, name        TEXT        NOT NULL
, status      TEXT        NOT NULL DEFAULT 'active'
              CHECK (status IN ('active', 'suspended', 'archived'))
, kind        TEXT        NOT NULL DEFAULT 'standalone'
              CHECK (kind IN ('standalone', 'consolidation'))
, kind_detail JSONB
, created_at  TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE IF NOT EXISTS events
( seq          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY
, event_id     UUID        NOT NULL DEFAULT uuidv7()
, event_type   TEXT        NOT NULL
, payload      JSONB       NOT NULL
, payload_type TEXT GENERATED ALWAYS AS (payload ->> 'type') VIRTUAL
, tenant_id    UUID        REFERENCES tenants (tenant_id)
  -- NULL = Identity stream（Userレジストリ、全社共通）。NOT NULL = Tenant stream。
  -- doc/tenant_isolation.md §4: TenantId NOT NULL 制約を付けない理由は同章参照。
, recorded_at  TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
, CONSTRAINT events_type_matches_payload
    CHECK (payload_type IS NULL OR payload_type = event_type)
);

-- 既存DB（Stage 1以前）からのアップグレード用。フレッシュインストールでは no-op。
ALTER TABLE events ADD COLUMN IF NOT EXISTS tenant_id UUID REFERENCES tenants (tenant_id);

CREATE UNIQUE INDEX IF NOT EXISTS events_event_id_key ON events (event_id);
DROP INDEX IF EXISTS events_event_type_seq_idx;
CREATE INDEX IF NOT EXISTS events_tenant_type_seq_idx ON events (tenant_id, event_type, seq);
CREATE INDEX IF NOT EXISTS events_recorded_at_idx ON events (recorded_at);

CREATE TABLE IF NOT EXISTS stream_version
( tenant_id UUID   PRIMARY KEY REFERENCES tenants (tenant_id)
, version   BIGINT NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS identity_stream_version
( id      INT    PRIMARY KEY CHECK (id = 1)
, version BIGINT NOT NULL DEFAULT 0
);
INSERT INTO identity_stream_version (id, version) VALUES (1, 0) ON CONFLICT DO NOTHING;

-- ── Row Level Security (doc/tenant_isolation.md §6.3) ──────────────────────
-- fail-closed: app.tenant_id が未設定/不正なら0件（クエリエラーまたは空応答）。
-- FORCE は所有者（このスクリプトを実行するowl_migrator自身）にも適用させるため。

ALTER TABLE events ENABLE ROW LEVEL SECURITY;
ALTER TABLE events FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS events_tenant_select ON events;
CREATE POLICY events_tenant_select ON events
  USING (
    tenant_id IS NULL
    OR tenant_id = current_setting('app.tenant_id', true)::uuid
  );

DROP POLICY IF EXISTS events_tenant_insert ON events;
CREATE POLICY events_tenant_insert ON events
  FOR INSERT WITH CHECK (
    tenant_id IS NULL
    OR tenant_id = current_setting('app.tenant_id', true)::uuid
  );

ALTER TABLE stream_version ENABLE ROW LEVEL SECURITY;
ALTER TABLE stream_version FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS stream_version_tenant ON stream_version;
CREATE POLICY stream_version_tenant ON stream_version
  USING (tenant_id = current_setting('app.tenant_id', true)::uuid)
  WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid);

-- identity_stream_version は単一行のみで機密性が無いため RLS は付けない。

-- ── ロール権限 (doc/tenant_isolation.md §6.4) ──────────────────────────────
-- owl_app: 実行時ロール。所有者ではないため上記RLSが適用される。
GRANT SELECT, INSERT ON events, stream_version, identity_stream_version TO owl_app;
-- tenants への直接アクセスは与えない —— 全Tenant名の一覧は owl_app からは見えない
-- (doc/tenant_isolation.md §6.1: 自分のグラント範囲だけをアプリ層で名前解決する)。
ALTER ROLE owl_app NOBYPASSRLS;

-- owl_platform_admin: root_admin_username のブートストラップのみが使う。
GRANT SELECT ON tenants TO owl_platform_admin;
ALTER ROLE owl_platform_admin NOBYPASSRLS;
