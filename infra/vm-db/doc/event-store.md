# イベントストア テーブル定義書

owlv のイベントストアは PostgreSQL 18 単一スキーマで構成する。
正式なDDLは [infra/vm-db/schema.sql](../schema.sql) であり、本書はその設計根拠を説明する文書に位置づけを変えた
（旧版は [Shell/EventStore.hs](../../../src/Shell/EventStore.hs) の `migrate` 関数が真実源だったが、
doc/tenant_isolation.md §6.4 のロール分離により `owl_app`（アプリのランタイム接続）がテーブル所有者で
なくなったため、DDL適用は `owl_migrator` が実行する `schema.sql` に一本化した）。
[Shell/EventStore.hs](../../../src/Shell/EventStore.hs) の `runMigration` は開発用の補助であり、`schema.sql` と同期させること。

対象 DB: `owl`（[infra/vm-db/setup.sh](../setup.sh) が作成）
適用ユーザー: スキーマDDLは `owl_migrator`（テーブル所有者）。アプリの実行時接続は `owl_app`（所有者ではない、RLS前提）。
詳細なテナント分離の設計根拠は [doc/tenant_isolation.md](../../../doc/tenant_isolation.md) を参照。

## 設計方針

- **追記専用**: `events` は UPDATE / DELETE を行わない。訂正は新規イベントの追記で表現する（CLAUDE.md「イベントストアは追記専用」）。
- **payload は JSONB**: 検索・整合性チェックを SQL 側でも行えるよう `JSONB` で持つ。
- **IDENTITY 列**: `BIGSERIAL` ではなく SQL 標準の `GENERATED ALWAYS AS IDENTITY` を使う（PG10+ の推奨）。
- **UUIDv7 をイベント ID に採用**: PostgreSQL 18 の組み込み関数 `uuidv7()` を使う（pgcrypto 等の拡張不要）。時系列ソート可能な UUID をイベント単位の外部参照キーとして持たせる。`seq` は楽観ロック用の内部順序、`event_id` は外部に渡す不変識別子という役割分担。
- **生成列で type を取り出す**: `event_type` を payload から都度導出する代わりにアプリ側で明示挿入する方針は変えないが、整合性検証用に `payload_type` を `VIRTUAL` 生成列として持ち、`event_type` とのズレを検出可能にする。
- **`tenant_id` でテナントを分離する** (doc/tenant_isolation.md §4, §6): `events`/`stream_version` を Tenant ごとに分離する代わりに、同じテーブルに `tenant_id` 列を持たせ、PostgreSQL の Row Level Security で行レベルに絞り込む。`tenant_id IS NULL` の行は Identity stream（Userレジストリ、全社共通 — doc/tenant_isolation.md §4.1）。
- **複数列インデックスは skip scan 前提で設計**: PostgreSQL 18 の B-tree skip scan により、先頭列を絞らない `(tenant_id, event_type, seq)` のような複合インデックスでも `event_type` 単体の絞り込みが効率化される。

## テーブル一覧

| テーブル | 役割 |
|---|---|
| `tenants` | Tenant レジストリ（一覧表示用。真実源は各Tenant streamの先頭イベント `TenantCreated`） |
| `events` | 追記専用イベントログ本体。`tenant_id` でTenant stream/Identity streamを区別 |
| `stream_version` | Tenant streamの楽観的並行性制御用バージョンカウンタ（Tenantごと） |
| `identity_stream_version` | Identity streamの楽観的並行性制御用バージョンカウンタ（単一行） |

---

## `tenants`

```sql
CREATE TABLE IF NOT EXISTS tenants (
    tenant_id   UUID        PRIMARY KEY,
    name        TEXT        NOT NULL,
    status      TEXT        NOT NULL DEFAULT 'active'
                CHECK (status IN ('active', 'suspended', 'archived')),
    kind        TEXT        NOT NULL DEFAULT 'standalone'
                CHECK (kind IN ('standalone', 'consolidation')),
    kind_detail JSONB,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);
```

`tenants` への直接 `SELECT *` は与えない（doc/tenant_isolation.md §6.1）。`owl_platform_admin`（root_admin_username のブートストラップ専用）からのみ全件参照可能。一覧が必要な通常のTenant利用者は、自分の `userTenantRoles` に含まれる `tenant_id` だけをアプリ層（Haskell側）で名前解決する。

例外として、`owl_app` には `tenant_id`/`status` の2列のみに絞った `SELECT` を追加で許可している（doc/tenant_isolation.md §6.6）。日次バッチ（`_owlbatch`、`owl_app` と同等権限で実行）が処理対象のアクティブなTenantを自前で列挙する必要があるため — `name`/`kind`/`kind_detail` 等の付帯情報は渡さない最小権限グラント（[Shell/EventStore.hs](../../../src/Shell/EventStore.hs) の `listActiveTenantIds`、[Batch/Env.hs](../../../batch/Batch/Env.hs) の `loadBatchEnvs`）。

`TenantCreated`/`TenantSuspended`/`TenantArchived` イベントの追記と同一トランザクションでこの表も更新される（[Shell/EventStore.hs](../../../src/Shell/EventStore.hs) の `syncTenantRegistry`）。

---

## `events`

```sql
CREATE TABLE IF NOT EXISTS events (
    seq          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_id     UUID        NOT NULL DEFAULT uuidv7(),
    event_type   TEXT        NOT NULL,
    payload      JSONB       NOT NULL,
    payload_type TEXT GENERATED ALWAYS AS (payload ->> 'type') VIRTUAL,
    tenant_id    UUID        REFERENCES tenants (tenant_id),
    recorded_at  TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),

    CONSTRAINT events_type_matches_payload
        CHECK (payload_type IS NULL OR payload_type = event_type)
);

CREATE UNIQUE INDEX IF NOT EXISTS events_event_id_key ON events (event_id);
CREATE INDEX IF NOT EXISTS events_tenant_type_seq_idx ON events (tenant_id, event_type, seq);
CREATE INDEX IF NOT EXISTS events_recorded_at_idx ON events (recorded_at);
```

| 列 | 型 | 制約 | 説明 |
|---|---|---|---|
| `seq` | `BIGINT IDENTITY` | PK | 追記順を保証する内部シーケンス。楽観ロックの比較値。 |
| `event_id` | `UUID` | NOT NULL, UNIQUE, default `uuidv7()` | 外部公開用の不変イベント識別子。UUIDv7 のため生成順とソート順が一致する。 |
| `event_type` | `TEXT` | NOT NULL | `Core.Event` の代数的データ型コンストラクタ名。 |
| `payload` | `JSONB` | NOT NULL | `Aeson.encode` した `Event` 全体。 |
| `payload_type` | `TEXT` (VIRTUAL GENERATED) | — | `payload->>'type'` を都度算出。`event_type` との不一致を CHECK で検出。 |
| `tenant_id` | `UUID` | NULL可, FK `tenants` | NULL = Identity stream。NOT NULL = その Tenant のストリーム (doc/tenant_isolation.md §4)。**どのSQL文を実行したコードパスか（`forTenant`由来かIdentity stream由来か）だけで値が決まり、Coreのイベントペイロードの内容からは決めない**（§6.2: event_typeの名前リストに依存する設計はドリフトの懸念から不採用）。 |
| `recorded_at` | `TIMESTAMPTZ` | NOT NULL, default `clock_timestamp()` | 記録時刻。`now()` はトランザクション開始時刻で固定されるため、追記順との対応がより厳密な `clock_timestamp()` を使う。 |

### なぜ `now()` ではなく `clock_timestamp()` か

`now()`（= `transaction_timestamp()`）は同一トランザクション内で固定値になる。`appendToPg` は 1 トランザクションで複数イベントを挿入するため、`now()` のままだと同一トランザクションで追記した複数行の `recorded_at` がすべて同一になり、`seq` 順との時系列対応が失われる。`clock_timestamp()` は呼び出し都度の実時刻を返すため、行ごとに異なる値になる。

### Row Level Security (doc/tenant_isolation.md §6.3)

```sql
ALTER TABLE events ENABLE ROW LEVEL SECURITY;
ALTER TABLE events FORCE ROW LEVEL SECURITY;

CREATE POLICY events_tenant_select ON events
  USING (tenant_id IS NULL OR tenant_id = current_setting('app.tenant_id', true)::uuid);

CREATE POLICY events_tenant_insert ON events
  FOR INSERT WITH CHECK (tenant_id IS NULL OR tenant_id = current_setting('app.tenant_id', true)::uuid);
```

`current_setting('app.tenant_id', true)` の第2引数 `true` は「未設定ならエラーでなく NULL を返す」指定。`tenant_id = NULL` は常に偽と評価されるため、**セッション変数を設定し忘れたコネクションは何も見えない（fail-closed）**。

`FORCE ROW LEVEL SECURITY` が無いと、テーブル所有者（このDDLを実行したロール）自身にはRLSが適用されない。`owl_app` を所有者にしない（`createdb`/`schema.sql`適用は `owl_migrator` が行う）のはこれが理由 — 所有者のままだと、いくら `FORCE` を付けてもオーナー自身の接続では事実上RLSを無視できてしまう。

Identity stream（`tenant_id IS NULL`）の行は、ログイン解決（OSユーザー名→Userの逆引き、doc/user.md §4.1）の都合上、Tenant単位の絞り込みを行わない。Tenant間でのUser情報の閲覧制限（「自社のテナントに関係のないUserの情報を見せない」）はアプリ層（`Shell.UserOps`/TUIへの射影）で行う、とした（doc/tenant_isolation.md §4.2 からの実装時の調整 — ログイン時点ではどのTenantの利用者かまだ確定していないため、DBのRLSだけでは表現できない）。

---

## `stream_version` / `identity_stream_version`

```sql
CREATE TABLE IF NOT EXISTS stream_version (
    tenant_id UUID   PRIMARY KEY REFERENCES tenants (tenant_id),
    version   BIGINT NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS identity_stream_version (
    id      INT    PRIMARY KEY CHECK (id = 1),
    version BIGINT NOT NULL DEFAULT 0
);
```

| 列 | 型 | 制約 | 説明 |
|---|---|---|---|
| `stream_version.tenant_id` | `UUID` | PK, FK `tenants` | Tenantごとの行。`esAppend` が `SELECT ... FOR UPDATE` で行ロックし、楽観ロックの比較・更新を行う。行が無い（=未初期化）場合は version 0 として扱う。 |
| `identity_stream_version.id` | `INT` | PK, `CHECK (id = 1)` | Identity stream用の単一行。 |

[Shell/EventStore.hs](../../../src/Shell/EventStore.hs) の `appendToPg` は、追記するイベント群が実際に触れるストリーム（Tenant / Identity）の方だけバージョンを確認・更新する。両方に跨るコマンドは現状のCore実装では発生しないが、発生しても1トランザクション内で両方を扱えるようにしている。

(旧版で「複数アグリゲートに分割する場合はstream_idを追加できる」と書いていた拡張ポイントは、本書のtenant_id導入により実施済みになった。)

---

## マイグレーション運用

- スキーマ変更は [infra/vm-db/schema.sql](../schema.sql) に追記し、`Shell.EventStore.runMigration` も同じ内容に追従させる。追記専用の原則上、テーブルの再作成は行わない（`ALTER TABLE ... ADD COLUMN IF NOT EXISTS` 等で拡張する）。
- 適用は `owl_migrator` で行う（`owl_app` では権限不足で失敗する。doc/tenant_isolation.md §6.4）。
- 単一ストリーム（Stage 1以前）から本スキーマへの移行手順は doc/tenant_isolation.md §7 を参照——既存イベントへの `tenant_id` バックフィルが必要な手動ステップを含む。
- 改ざん検知用ハッシュ連鎖（`prev_hash`/`row_hash`、spec §7）は本スキーマにまだ含まれていない。導入する場合は `tenant_id` ごとに独立したパーティションとして連鎖する方針が doc/tenant_isolation.md §9 で決まっている——実装時に本書を改訂する。
