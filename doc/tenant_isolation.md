# マルチテナント分離 設計書

## 1. 背景・課題

現状、`Core.Domain.Organisation`（部→課→係の階層）・`Core.Domain.User`・`Core.Domain.AccountingPeriod` は存在するが、これらの**親となる「会社・事業者単位」の境界が存在しない**。

[Shell/EventStore.hs](../src/Shell/EventStore.hs) のイベントストアはアプリ全体で**単一ストリーム**（`stream_version` は `id = 1` の単一行）であり、`events` テーブルにも事業者を区別する列がない。[infra/vm-db/doc/event-store.md](../infra/vm-db/doc/event-store.md) 末尾にも「複数アグリゲートに分割する場合は `stream_id` を追加できる」という拡張ポイントが明記されたまま放置されている。また [infra/vm-db/setup.sh](../infra/vm-db/setup.sh) のコメントには当初から「RLS で多重テナント対応」という意図が書かれていたが、実装されていない。

要件は「同じテーブルで `tenant_id` 列を足してWHEREに書き忘れない」という運用上の注意では満たされない。**クエリを1つ間違えただけでは他社のデータに到達できない構造**を、Haskellの型・イベントストアのストリーム分割・PostgreSQLのRLSという3層で重ねて作る。

## 2. 用語整理: Tenant と Organisation の違い

| 概念 | 意味 | スコープ |
|---|---|---|
| **Tenant**（新設） | 会計帳簿が分離される事業者単位（ドラクエのセーブスロット）。法人・子会社ごとに1つ | 複数 |
| `Organisation`（既存） | 1つの Tenant 内部の部門階層（部→課→係） | Tenant 内のみで意味を持つ |
| `AccountingPeriod`（既存） | 1つの Tenant の会計期間（年月） | Tenant ごとに別個に開閉する |

`Organisation.orgParent` は同一 Tenant 内の部門ツリーであり、Tenant 間の親子関係ではない。子会社を別 Tenant として扱う場合、連結処理は別途「Tenant をまたぐ集計バッチ」として設計する（本書のスコープ外、§9）。

## 3. 全体方針: 3層防御

| 層 | 何を保証するか | 仕組み |
|---|---|---|
| ① Haskell 型 | プログラマが他社の `EventStore` ハンドルを取り違えられない | `TenantId` をクロージャに束縛した `EventStore` を生成。呼び出し側に渡せる「生の `TenantId` パラメータ」を作らない |
| ② イベントストア分割 | フォールド時に他社イベントが混入しない | ストリームを **control-plane（全社共通）** と **per-tenant（事業者ごと）** に分割 |
| ③ PostgreSQL RLS | アプリのコード自体に欠陥があっても行レベルで漏れない | `tenant_id` 列 + `FORCE ROW LEVEL SECURITY` ポリシー。session変数未設定時は **fail-closed**（0件） |

①が一番弱く③が一番強いが、③だけでは「正しいテナントとして振る舞っているか」というアプリケーションレベルの権限判定（あるユーザーがこの Tenant にアクセスしてよいか）まではカバーできない。3層は互いの弱点を補う設計であり、どれか1つでは不十分。

## 4. ストリームトポロジ

現状の単一ストリームを2種類に分割する。

```
control-plane stream（1本・全社共通）
  ├─ Tenant の登録・停止・廃止
  └─ User のライフサイクル（OS実体と1:1のため Tenant をまたいで一意）

tenant stream（Tenant ごとに1本）
  ├─ MasterBook  (Organisation / Partner / AccountMaster / SubAccount / OrgPermission)
  ├─ JournalBook
  ├─ CashBook
  ├─ PeriodsBook
  ├─ AssetBook
  ├─ EclBook
  ├─ FxBook
  ├─ JudgmentLogBook
  ├─ BenefitBook
  └─ TaxBook
```

### なぜ User を per-tenant ストリームに入れないのか

[doc/user.md](user.md) §2 のとおり `UserId` = **OS（AP VM）のユーザー名そのもの**であり、`mkUserId` は POSIXユーザー名制約を検証し、OS UID は単調増加カウンタでシステム全体一意に割り当てる（doc/user.md:62, 68）。AP VM は1台の共有OSであり、Unixのユーザー名前空間はTenantをまたいで物理的に単一である。したがって「Tenant Aの`tanaka`」と「Tenant Bの`tanaka`」を別物として両立させることはOSレベルで不可能。User を per-tenant ストリームに分けても、OS同期の時点で衝突が起きるため意味がない。

このため User は control-plane に残し、代わりに **Tenant へのアクセス権を横持ちのグラント** として表現する（§5.2）。これは「経理担当が複数の子会社を兼務する」という実務（ユーザー自身の問いの「別会社、組織のデータが取得できてしまう」懸念への回答）にも対応する——ユーザーは複数Tenantにグラントを持てるが、グラントのないTenantのストリームには**型レベルでハンドルを取得できない**。

## 5. Haskell 設計

### 5.1 `Core/Domain/Tenant.hs`（新設）

```haskell
newtype TenantId = TenantId { unTenantId :: UUID }
  deriving (Eq, Ord, Show)

data TenantStatus = TenantActive | TenantSuspended | TenantArchived
  deriving (Bounded, Enum, Eq, Show)

data Tenant = Tenant
  { tenantId     :: TenantId
  , tenantName   :: Text
  , tenantStatus :: TenantStatus
  }
  deriving (Eq, Show)
```

`Core/Domain/` 配下のため IO 非依存。`TenantId` の生成（UUIDv7発行）は Shell 側の責務（CLAUDE.md: Core は乱数・clockを持てない）。

### 5.2 User の二層構造

```haskell
data User = User
  { userId            :: UserId
  , userOsUid         :: OsUid
  , userHomeTenant    :: TenantId        -- OS provisioning の基準となる「本拠地」Tenant
  , userTenantGrants  :: Set TenantId    -- 横断アクセスを許可された Tenant（homeも含めて良い）
  , ...                                  -- 既存フィールドは変更なし
  }
```

- `userHomeTenant` は作成時に固定。OS同期（doc/user.md §3）はこの値とは独立——OSアカウントは1個のままで変わらない。
- `userTenantGrants` は空集合がデフォルトで `{ userHomeTenant }` のみを意味する（ホワイトリストの初期値はホームのみ。これは既存の `OrgPermission` の「空＝無制限」とは逆の極性なので、`Core.Decide` のコメントで明示する）。
- 新規 Command: `GrantUserTenantAccess UserId TenantId` / `RevokeUserTenantAccess UserId TenantId`。発行者は対象 Tenant の Admin であることを `decide` で検証する（既存の `isActiveAdmin` 相当のチェックを Tenant スコープに拡張）。

### 5.3 `EventStore` の API変更 — クロージャ束縛

現状 `EventStore` はコネクションを束縛するだけの record（[Shell/EventStore.hs:65](../src/Shell/EventStore.hs#L65)）。これを **コネクション + TenantId** を束縛する形に変える。

```haskell
-- 既存: EventStore = EventStore { esLoad :: IO ..., esAppend :: ... }  -- 変更なし

-- 新設: Tenant を閉じ込めて EventStore を作るコンストラクタ
forTenant :: PG.Connection -> TenantId -> EventStore
forTenant conn tid = EventStore
  { esLoad   = loadFromPg conn tid
  , esAppend = appendToPg conn tid
  }

-- control-plane 用（Tenant を取らない、既存と同じ形）
controlPlaneStore :: PG.Connection -> EventStore
```

**なぜ `esLoad`/`esAppend` の型に `TenantId` 引数を生やさないのか**：呼び出し側で `TenantId` を毎回受け渡す設計だと「正しい値を渡し忘れる／別の変数を渡し間違える」という人為ミスの余地が残る。`forTenant` で生成された `EventStore` の値自体が「すでにどの会社の帳簿か確定済みのハンドル」になるようにし、`executeCommand`・`loadXBook` のシグネチャを一切変えない（CLAUDE.mdの「Shellは既定では変更しない、widen the function's inputで対処する」方針に従い、変更点を `EventStore` の生成箇所1箇所に閉じる）。

### 5.4 `CommandExecutor` の二系統化

```haskell
-- 既存のexecuteCommand/loadXBookはそのままTenant用に使う
-- （EventStoreが forTenant 由来であることを呼び出し側が保証する）

executeControlPlaneCommand :: EventStore -> TenantCommand -> IO (Either AppError [TenantEvent])
```

control-plane 用には別の小さな Command/Event ADT（`Core.ControlPlane.Command` / `.Event` / `.Decide` / `.Evolve`、CreateTenant・SuspendTenant・ArchiveTenant・GrantUserTenantAccess等のみ）を新設し、既存の `Core.Command`/`Core.Decide` は**一切変更しない**。

理由：既存の `Command`（`RecordJournalEntry` 等、[Core/Command.hs](../src/Core/Command.hs)）に `TenantId` フィールドを追加する案も検討したが、不要と判断した。`Command` は常に「すでに `forTenant` で確定したストリームに対して」発行されるため、ペイロード内に重複してTenantIdを持たせても、それを検証する場所（`decide`）はそのTenantの`AppBook`しか見えていない以上、二重に持たせる意味がない（その代わりPostgres側の列で物理的に強制する。§6.2）。Command型を肥大化させない。

### 5.5 TUI / AppState — テナント選択 = ハンドルの再束縛

ログイン（doc/user.md §4.1 のOSユーザー名検証）後、`User` 射影から `userHomeTenant` と `userTenantGrants` を取得。テナント切替メニューで選択された `TenantId` が `userTenantGrants` に含まれることを確認した上で、`forTenant conn tid` を呼んで新しい `EventStore` を `AppState` に積み直す。**Tenantの切替は「値の変更」ではなく「ハンドルの再生成」**として実装し、古いハンドルを使い続けるコードパスが残らないようにする（Shell/TUI/Types.hs の `AppState` に `EventStore` を保持しているフィールドを、切替時に丸ごと入れ替える）。

## 6. PostgreSQL 設計

### 6.1 `tenants` テーブル（新設）

```sql
CREATE TABLE IF NOT EXISTS tenants (
    tenant_id   UUID        PRIMARY KEY DEFAULT uuidv7(),
    name        TEXT        NOT NULL,
    status      TEXT        NOT NULL DEFAULT 'active'
                CHECK (status IN ('active', 'suspended', 'archived')),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);
```

### 6.2 `events` への `tenant_id` 追加 + `stream_version` の複合化

```sql
ALTER TABLE events
  ADD COLUMN tenant_id UUID REFERENCES tenants(tenant_id);
  -- control-plane イベントは tenant_id IS NULL のままにする
  -- (Tenant自体の登録イベントがどのTenantにも属さないのは当然のため)

DROP INDEX IF EXISTS events_event_type_seq_idx;
CREATE INDEX IF NOT EXISTS events_tenant_type_seq_idx
  ON events (tenant_id, event_type, seq);

-- stream_version は (tenant_id) を主キーにする。
-- control-plane の行は tenant_id = '00000000-0000-0000-0000-000000000000'（固定の番兵値）を使う
-- ことで「NULLを主キーにできない」制約を回避する。
CREATE TABLE IF NOT EXISTS stream_version (
    tenant_id UUID    PRIMARY KEY,
    version   BIGINT  NOT NULL DEFAULT 0
);
```

`events.tenant_id` は本来 `NOT NULL` にしたいが、control-plane行（Tenant/User系イベント）が無Tenantであるため、`payload_type` から control-plane イベントかどうかを判定する `CHECK` 制約で代替する：

```sql
ALTER TABLE events ADD CONSTRAINT events_tenant_required
  CHECK (
    (event_type IN ('TenantCreated','TenantSuspended','TenantArchived',
                     'UserCreated','UserRoleChanged', /* ... */)
     AND tenant_id IS NULL)
    OR
    (event_type NOT IN (/* 上記と同じリスト */)
     AND tenant_id IS NOT NULL)
  );
```

### 6.3 Row Level Security — fail-closed

```sql
ALTER TABLE events ENABLE ROW LEVEL SECURITY;
ALTER TABLE events FORCE ROW LEVEL SECURITY;   -- テーブル所有者にも適用させる（§6.4参照）

CREATE POLICY events_tenant_select ON events
  USING (
    tenant_id IS NULL  -- control-plane行は全員参照可（Userライフサイクル等）
    OR tenant_id = current_setting('app.tenant_id', true)::uuid
  );

CREATE POLICY events_tenant_insert ON events
  FOR INSERT WITH CHECK (
    tenant_id IS NULL
    OR tenant_id = current_setting('app.tenant_id', true)::uuid
  );

ALTER TABLE stream_version ENABLE ROW LEVEL SECURITY;
ALTER TABLE stream_version FORCE ROW LEVEL SECURITY;

CREATE POLICY stream_version_tenant ON stream_version
  USING (tenant_id = current_setting('app.tenant_id', true)::uuid)
  WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid);
```

`current_setting('app.tenant_id', true)` の第2引数 `true` は「未設定ならエラーでなく `NULL` を返す」指定。`tenant_id = NULL` は常に `false` と評価されるため、**セッション変数を設定し忘れたコネクションは何も見えない（fail-closed）**。これは「クエリを1つ間違えても他社のデータに到達できない」という要件を、アプリのバグだけでなく「設定漏れ」というオペレーションミスからも守る。

### 6.4 ロール分離 — 所有者と実行ロールを分ける（既存設定の修正が必要）

[infra/vm-db/setup.sh:144](../infra/vm-db/setup.sh#L144) は `createdb -O owl_app owl` としており、**`owl_app` がデータベース／テーブルの所有者になっている**。PostgreSQLのRLSは既定でテーブル所有者には適用されない（`FORCE ROW LEVEL SECURITY` を付けても、所有者ロールは `BYPASSRLS` 属性やオーナー権限で迂回できる経路が残る）。これは現状の設定のまま `tenant_id` 列を足しただけではRLSが実質無効化されるため、**修正が必須**。

```sql
-- マイグレーション専用ロール（DDL実行・所有者）
CREATE ROLE owl_migrator WITH LOGIN NOCREATEDB NOCREATEROLE NOSUPERUSER;
-- 実行時ロール（owlv本体・owlv-batch-centerが使う、所有者ではない）
ALTER TABLE events OWNER TO owl_migrator;
ALTER TABLE stream_version OWNER TO owl_migrator;
ALTER TABLE tenants OWNER TO owl_migrator;

GRANT SELECT, INSERT ON events, stream_version TO owl_app;
GRANT SELECT ON tenants TO owl_app;
-- owl_app は BYPASSRLS を持たないことを明示的に確認する
ALTER ROLE owl_app NOBYPASSRLS;
```

`Shell.EventStore.migrate` は今後 `owl_migrator` で実行し、ランタイム接続（`PG.connectPostgreSQL`）は `owl_app` を使う、という2ロール運用に変える。[infra/vm-db/setup.sh](../infra/vm-db/setup.sh) の「DBユーザー・データベース作成」節と `infra/vm-db/pg_hba.conf` に `owl_migrator` 用の認証行を追加する必要がある（運用者が手動マイグレーション時のみ接続、`owl_app` は通常運用のみ）。

### 6.5 セッション変数のセット方法

`PG.connectPostgreSQL` で得たコネクションは、Tenant用クエリを実行する前に毎回:

```sql
SELECT set_config('app.tenant_id', $1, false);  -- false = トランザクション単位でなくセッション単位
```

を実行する。コネクションプール（将来導入する場合）を使うなら `false`（セッション単位）ではなく `true`（トランザクション単位）にし、**コネクションがプールに返却される前に確実にリセットされる**ようにする。現状はコネクションを使い切り型（`forTenant` で1接続を1Tenantに束縛）で運用するため、プール導入は本書のスコープ外だが、導入時に必ず見直す前提を明記する。

### 6.6 インデックス再設計

| 既存 | 変更後 | 理由 |
|---|---|---|
| `events_event_type_seq_idx (event_type, seq)` | `events_tenant_type_seq_idx (tenant_id, event_type, seq)` | RLSフィルタ後のスキャン経路を先頭列に揃える |
| `events_recorded_at_idx (recorded_at)` | `events_tenant_recorded_at_idx (tenant_id, recorded_at)` | Tenant別の監査クエリ（spec §5 判断ログ等）を想定 |

PostgreSQL 18のB-tree skip scanにより `(tenant_id, event_type, seq)` でも `event_type` 単体検索（control-plane行の `tenant_id IS NULL` 検索含む）が効率化される（[infra/vm-db/doc/event-store.md](../infra/vm-db/doc/event-store.md) と同方針）。

## 7. 移行手順

1. `tenants` テーブル作成、既存の全イベントを所有する「デフォルトTenant」を1行 INSERT（既存データの移行先）。
2. `events.tenant_id` を `NOT NULL` 制約なしで追加 → 既存行を一括 `UPDATE events SET tenant_id = '<デフォルトTenantのUUID>' WHERE tenant_id IS NULL AND event_type NOT IN (control-plane一覧)`。
3. control-plane イベント一覧（User系）を確定し、§6.2 の `CHECK` 制約を追加。
4. `stream_version` を複合キー化し、既存の `version` を「デフォルトTenant」の行として移し替え。
5. RLSポリシー・ロール分離（§6.3, §6.4）を適用。
6. Haskell側 `forTenant` を実装し、既存の `newPostgresEventStore` 呼び出し元（`app/Main.hs`）を「デフォルトTenantで `forTenant`」に置き換える時点ではまだ単一Tenant運用と機能的に同値であることを確認（regression防止）。
7. 2つ目のTenantを作成し、§8 のクロステナント漏洩テストが通ることを確認してからTenant作成UIを解放する。

各ステップは `events` の追記専用原則（CLAUDE.md）に違反しない——`ALTER TABLE ADD COLUMN` と一括 `UPDATE` は既存行の論理的内容（`payload`）を変更せず、新設のメタデータ列を埋めるだけである点に注意して実装する。

## 8. テスト戦略

- **Haskell プロパティテスト**: 2つの `TenantId` それぞれで `forTenant` したダミー `EventStore`（インメモリ実装）に対し、TenantAのイベントをfoldした `AppBook` にTenantBの `JournalEntryId` が一切出現しないことを検証する。
- **SQL統合テスト**: `owl_app` ロールで接続し `app.tenant_id` をTenantAにセットした状態で、`SELECT * FROM events WHERE tenant_id = '<TenantB>'` を**明示的に書いても**0件であることを確認する（RLSが`WHERE`の誤りを上書きすることの直接的な証明）。`set_config` を呼ばずに接続した場合も0件（fail-closed）であることを確認する。
- **権限境界テスト**: `owl_migrator` ロールでDDLが通り `owl_app` ロールでは `ALTER TABLE` が拒否されること、`owl_app` が `BYPASSRLS` を持たないことを `pg_roles` で確認する。

## 9. 残課題・将来拡張

- **連結（子会社の合算）**: 本書はTenant間の完全分離のみを扱う。複数子会社Tenantを合算する連結決算機能は、Tenantを跨ぐ専用の読み取り専用バッチ（`owlv-batch-center` 拡張）として別途設計する。RLSをバイパスする必要があるため、専用ロール（例: `owl_consolidator`、特定のTenant集合のみ`SELECT`許可）を新設し、本書のロール分離方針を踏襲する。
- **スキーマ／DB単位分離へのエスカレーション**: 規制上の理由で物理分離が必要なTenant（spec §3 高リスクティア相当）が出た場合、当該Tenantだけ別スキーマまたは別データベースに切り出す escalation path を確保しておく。`forTenant` のシグネチャ（`PG.Connection -> TenantId -> EventStore`）は、接続先を変えるだけで対応できるため、この拡張に対して閉じている。
- **改ざん検知ハッシュ連鎖（spec §7）**: `row_hash`/`prev_hash` の連鎖は現状単一ストリーム前提（[infra/vm-db/doc/event-store.md](../infra/vm-db/doc/event-store.md)）。Tenant分割後はハッシュ連鎖もTenant単位（`tenant_id` ごとに独立した連鎖）に再設計する必要がある——本書では言及のみとし、別途 `infra/vm-db/doc/event-store.md` の改訂で扱う。
