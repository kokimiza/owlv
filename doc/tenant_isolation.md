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

`Organisation.orgParent` は同一 Tenant 内の部門ツリーであり、Tenant 間の親子関係ではない。子会社合算（連結）は IFRS 10/IFRS 3 が要求する監査可能な構造を持つ必要があるため、「将来課題」として丸投げせず §4.3 で連結仕訳の**置き場所と権限モデル**を確定する。連結バッチの計算ロジック（消去仕訳のアルゴリズム）自体は別ドキュメントに委ねる。

## 3. 全体方針: 3層防御

| 層 | 何を保証するか | 仕組み |
|---|---|---|
| ① Haskell 型 | プログラマが他社の `EventStore` ハンドルを取り違えられない | `TenantId` をクロージャに束縛した `EventStore` を生成。呼び出し側に渡せる「生の `TenantId` パラメータ」を作らない |
| ② イベントストア分割 | フォールド時に他社イベントが混入しない | ストリームを **Identity stream（Userレジストリ、全社共通）** と **Tenant stream（事業者ごと）** に分割 |
| ③ PostgreSQL RLS | アプリのコード自体に欠陥があっても行レベルで漏れない | `tenant_id` 列 + `FORCE ROW LEVEL SECURITY` ポリシー。session変数未設定時は **fail-closed**（0件） |

①が一番弱く③が一番強いが、③だけでは「正しいテナントとして振る舞っているか」というアプリケーションレベルの権限判定まではカバーできない。3層は互いの弱点を補う設計であり、どれか1つでは不十分。

## 4. ストリームトポロジ

Tenant自身のライフサイクル（作成・停止・廃止）を Identity stream と同じ「全社共通の場所」に置くと、`TenantCreated`/`TenantSuspended` イベントが `tenant_id IS NULL` 扱いになり、RLSのSELECTポリシーで「全社共通領域は全員参照可」としたとき**Aテナントの利用者がBテナントの存在・停止履歴まで見える**という情報漏洩になる（会社の存続・停止情報自体が機密であるケースは多い）。

そのため、Tenantのライフサイクルイベントは「対象テナント自身のストリームの最初のイベント」として記録する（集約ルートの生成イベントは自分のストリームの先頭イベントというイベントソーシングの標準パターン）。これにより**Tenantという概念自体について全社共通の場所に書くものは無くなる**。全社共通で残るのは「OSアカウントと1:1対応する User の登録簿」だけになる（§4.1 で説明する理由により、これだけはOSの制約上分割できない）。

```
Identity stream（1本・全社共通、Userのライフサイクルのみ）
  └─ CreateUser / ChangeUserRole / SuspendUser / RemoveUser / ...

Tenant stream（Tenant ごとに1本。先頭イベントが TenantCreated）
  ├─ TenantCreated / TenantSuspended / TenantArchived   ← 自分自身のライフサイクル
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

### 4.1 なぜ User だけ per-tenant ストリームに入れられないのか

[doc/user.md](user.md) §2 のとおり `UserId` = **OS（AP VM）のユーザー名そのもの**であり、`mkUserId` は POSIXユーザー名制約を検証し、OS UID は単調増加カウンタでシステム全体一意に割り当てる（doc/user.md:62, 68）。AP VM は1台の共有OSであり、Unixのユーザー名前空間はTenantをまたいで物理的に単一である。したがって「Tenant Aの`tanaka`」と「Tenant Bの`tanaka`」を別物として両立させることはOSレベルで不可能。

### 4.2 Identity stream 自体の情報漏洩対策

Identity streamを「全員参照可」にすると、Tenant Aの利用者がTenant Bの従業員一覧・異動履歴・停止履歴まで読めてしまう。これはHR的に機密情報であり、§3③のRLSが正しく機能していても**設計それ自体が漏洩経路**になる。

対策として、Identity streamの各イベント行に、そのUserの `home_tenant_id` と `granted_tenant_ids[]` を**非正規化した列**として持たせ、RLSのSELECTポリシーをこれらの列でも絞る（§6.3）。「自分がアクセスを許可されているTenantに紐づくUserの情報だけ見える」状態にし、「全員参照可」という抜け道を作らない。

### 4.3 連結（ConsolidationTenant）の構造的な位置づけ

連結調整仕訳（投資と資本の相殺消去、非支配株主持分、内部取引消去）はIFRS 10/IAS 27の要求事項であり、どこかに監査可能な形で記録されなければならない。一方で、連結バッチに「全Tenantを読める」特権ロールを作るのは攻撃面が大きい。既存の `userTenantRoles` 機構（§5.2）を使い回せば新しいバイパスロールは不要である。

- `Tenant` に `tenantKind :: TenantKind` を追加し、`TenantKind = StandaloneTenant | ConsolidationTenant (NonEmpty TenantId)` とする。`ConsolidationTenant subs` は連結対象の子会社Tenant群を列挙するだけで、それ自体は**ふつうのTenant**（自分の `JournalBook` を持つ）。
- 連結仕訳（消去仕訳・非支配株主持分計上）は、ConsolidationTenant自身の `JournalBook` に通常の `RecordJournalEntry` として記録する。`VoucherRef` に元データの出典子会社（`sourceTenant :: TenantId`）を追記できるよう `Core.Domain.Journal.VoucherRef` を拡張する（既存の「仕訳行為区分」の枠組みのまま、新しい区分は増やさない）。
- 連結バッチ専用の `User`（サービスアカウント）を作り、`userTenantRoles` にConsolidationTenant（Admin相当）と各子会社Tenant（参照専用ロール）への個別グラントを持たせる。これは§5.2の通常の仕組みであり、RLSをバイパスする特権ロールは**作らない**。
- 連結の計算ロジック（相殺消去アルゴリズム）自体は別ドキュメントで設計する。本書が確定するのは「連結仕訳はTenant隔離の枠内で、ふつうのJournalEntryとして記録される」という構造のみ。

## 5. Haskell 設計

### 5.1 `Core/Domain/Tenant.hs`（新設）

```haskell
newtype TenantId = TenantId { unTenantId :: UUID }
  deriving (Eq, Ord, Show)

data TenantStatus = TenantActive | TenantSuspended | TenantArchived
  deriving (Bounded, Enum, Eq, Show)

data TenantKind
  = StandaloneTenant
  | ConsolidationTenant (NonEmpty TenantId)  -- 連結対象の子会社Tenant群 (§4.3)
  deriving (Eq, Show)

data Tenant = Tenant
  { tenantId     :: TenantId
  , tenantName   :: Text
  , tenantStatus :: TenantStatus
  , tenantKind   :: TenantKind
  }
  deriving (Eq, Show)
```

`Core/Domain/` 配下のため IO 非依存。`TenantId` の生成（UUIDv7発行）は Shell 側の責務（CLAUDE.md: Core は乱数・clockを持てない）。`TenantId` を `Show`/`read` で文字列化してSQLに渡す実装にしないこと。`uuid` パッケージの `toText`/`fromText` を使い、`show`/`read` 経由のラウンドトリップに依存しない（書式の暗黙の前提が将来のGHC/ライブラリ更新で壊れるのを避ける）。

### 5.2 User モデル — Tenantごとに別個の Role を持つ

「あるTenantではAdmin、別のTenantではOperatorに留める」という職務分掌（内部統制）ができないと、子会社を兼務する担当者が全社で同じ権限を持つことになり、IFRSの内部統制評価上の弱点になる。セキュリティの最小権限原則からも、Tenantをまたいで単一の `Role` を共有するのは過剰な権限付与である。そのため `Role` は User 全体ではなく **(User, Tenant) の組** に対して持たせる。

```haskell
data User = User
  { userId          :: UserId
  , userOsUid       :: OsUid
  , userHomeTenant  :: TenantId             -- OS provisioning の基準となる「本拠地」Tenant
  , userTenantRoles :: Map TenantId Role    -- Tenantごとの権限。Map.keys がアクセス可能なTenant集合
  , userDisplayName :: Text
  , userStatus      :: UserStatus
  , userScreenScopes :: [Text]
  , userPasswordHash :: Maybe Text
  , userSshPubKeys   :: [SshPubKey]
  }
```

- `userTenantRoles` は**必ず `userHomeTenant` をキーとして含む**（`decide` で不変条件として強制）。ホームテナント以外へのアクセスは個別グラントが必要——空集合がデフォルトでホームのみを意味する設計（ホワイトリスト方式）。
- OS同期（[doc/user.md](user.md) §3）は `userHomeTenant`/`userTenantRoles` の値とは独立——OSアカウントは1個のまま変わらない。OSグループ（`owl-operators`/`owl-maintainers`相当）へのマッピングは「いずれかのTenantでAdmin以上の権限を持つか」等、既存ロジックの入力を `userRole` 単一値から `userTenantRoles` の集約値に変えるだけで、OS同期の構造自体は変更しない。
- 新規 Command: `GrantUserTenantAccess UserId TenantId Role` / `RevokeUserTenantAccess UserId TenantId` / `ChangeUserTenantRole UserId TenantId Role`。発行者は対象 Tenant で `Admin` ロールを持つことを `decide` で検証する。
- `Core.Domain.OrgPermission` の `PermScope`（画面・勘定科目スコープ）は既存どおり `MasterBook`（= Tenant stream内）に閉じているため変更不要——Organisationの下にある権限はそもそも1つのTenantの中でしか意味を持たない。

### 5.3 `EventStore` の API変更 — クロージャ束縛

現状 `EventStore` はコネクションを束縛するだけの record（[Shell/EventStore.hs:65](../src/Shell/EventStore.hs#L65)）。これを **コネクション + TenantId** を束縛する形に変える。

```haskell
-- 既存: EventStore = EventStore { esLoad :: IO ..., esAppend :: ... }  -- 変更なし

-- Tenant streamを閉じ込めて EventStore を作るコンストラクタ
forTenant :: PG.Connection -> TenantId -> IO (Either AppError EventStore)
-- IO化した理由: 生成時に SELECT set_config('app.tenant_id', ?, false) を必ず1回実行し、
-- 失敗（権限エラー・不正なUUID等）をこの時点で検出してから EventStore を返す（§6.5）。

-- Identity stream用（Userレジストリのみ。Tenantを取らない）
identityStore :: PG.Connection -> EventStore
```

**なぜ `esLoad`/`esAppend` の型に `TenantId` 引数を生やさないのか**：呼び出し側で `TenantId` を毎回受け渡す設計だと「正しい値を渡し忘れる／別の変数を渡し間違える」という人為ミスの余地が残る。`forTenant` で生成された `EventStore` の値自体が「すでにどの会社の帳簿か確定済みのハンドル」になるようにし、`executeCommand`・`loadXBook` のシグネチャを一切変えない（CLAUDE.mdの「Shellは既定では変更しない、widen the function's inputで対処する」方針に従い、変更点を `EventStore` の生成箇所1箇所に閉じる）。

`forTenant`/`identityStore` の実装で `set_config` を呼ぶ際、**SQLインジェクションを避けるため必ずバインドパラメータで渡す**こと。

```haskell
_ <- PG.execute conn "SELECT set_config('app.tenant_id', ?, false)" (PG.Only (UUID.toText (unTenantId tid)))
```

文字列結合でクエリを組み立てるコードは `forTenant` の実装としては許容しない。また、コネクションは **1つの `forTenant` ハンドルにつき1物理コネクションを占有し、ハンドルの生存期間中は他のTenantに転用しない**こと。コネクションプールを将来導入する場合、返却前に必ず `RESET app.tenant_id` を実行するミドルウェアを挟む（§6.5で詳述）。

### 5.4 `CommandExecutor` — Tenant stream と Identity stream は同じ実装を使い分けるだけ

`executeCommand`/`loadXBook` のシグネチャは変更しない。`Core.Command`/`Core.Event`/`Core.Decide`/`Core.Evolve` も変更しない——`RecordJournalEntry` 等の既存コマンドはすべて「すでに `forTenant` で確定したストリームに対して」発行されるため、ペイロード内に重複して `TenantId` を持たせる必要がない（その代わりPostgres側の列で物理的に強制する。§6.2）。

Identity stream用には別の小さな Command/Event ADT（`Core.Identity.Command` / `.Event` / `.Decide` / `.Evolve`、`CreateUser`・`ChangeUserTenantRole`等）を新設する。`Tenant` 自体のライフサイクル（`CreateTenant`/`SuspendTenant`/`ArchiveTenant`）は §4 の方針により**通常の `Core.Command` に追加**し、Tenant streamの最初のコマンドとして扱う（`AppBook` の初期状態に対して `CreateTenant` を発行する1点のみが他のコマンドと違う）。

### 5.5 TUI / AppState — テナント選択 = ハンドルの再束縛

ログイン（doc/user.md §4.1 のOSユーザー名検証）後、Identity streamから `userHomeTenant` と `userTenantRoles` を取得。テナント切替メニューで選択された `TenantId` が `Map.keys userTenantRoles` に含まれることを確認した上で、`forTenant conn tid` を呼んで新しい `EventStore` を `AppState` に積み直す。**Tenantの切替は「値の変更」ではなく「ハンドルの再生成」**として実装し、古いハンドルを使い続けるコードパスが残らないようにする（`Shell/TUI/Types.hs` の `AppState` に `EventStore` を保持しているフィールドを、切替時に丸ごと入れ替える）。

Tenant切替自体も「誰が・いつ・どのTenantを開いたか」という操作ログであり、IFRS監査証跡として残すべきものである。そのため `Shell.Effects.AuditEntry` に `auditTenant :: Maybe TenantId` を追加する（Identity stream操作は `Nothing`）。`executeCommandEff` の `logAudit` 呼び出し時に、その時点で束縛されている `EventStore` がどのTenantかを渡す。Tenant切替そのもの（実際の書き込みを伴わない選択操作）も `TenantSwitched` イベントとしてAudit専用に記録するか、既存の `UserLoginObserved`（doc/user.md §4.1）と同様の枠組みで1イベント追記する——どちらにするかは実装時に既存の `Shell.Interpreters.UserContext` の形に合わせて決める。

## 6. PostgreSQL 設計

### 6.1 `tenants` テーブル（新設・レジストリ用途のみ）

```sql
CREATE TABLE IF NOT EXISTS tenants (
    tenant_id   UUID        PRIMARY KEY,
    name        TEXT        NOT NULL,
    status      TEXT        NOT NULL DEFAULT 'active'
                CHECK (status IN ('active', 'suspended', 'archived')),
    kind        TEXT        NOT NULL DEFAULT 'standalone'
                CHECK (kind IN ('standalone', 'consolidation')),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);
```

このテーブルは**イベントの代替ではない**——真実源は各Tenant streamの先頭イベント `TenantCreated`（§4）であり、`tenants` テーブルはテナント切替メニュー等のための高速な一覧用レジストリ（projectionの一種）。`TenantCreated` を書くトランザクションの中で同時にこの行をINSERTする。

このテーブルへの `SELECT` 権限を `owl_app` に無条件で与えると、「どの会社がこのシステムに乗っているか」という一覧そのものが全テナントから見える。そのため `tenants` テーブルへの直接 `SELECT` は許可しない。Haskell側は「自分の `userTenantRoles` に含まれるTenantId」だけをアプリ内で個別に名前解決する（`WHERE tenant_id = ANY(?)` で自分のグラント集合だけを問い合わせる）。全件一覧が必要なのは [doc/user.md](user.md) の `root_admin_username` によるブートストラップ管理者のみであり、そのケースは専用ロール `owl_platform_admin`（§6.4）からのみ `SELECT *` を許可する。

### 6.2 `events` への列追加

```sql
ALTER TABLE events
  ADD COLUMN tenant_id          UUID REFERENCES tenants(tenant_id),
  ADD COLUMN home_tenant_id     UUID REFERENCES tenants(tenant_id),
  ADD COLUMN granted_tenant_ids UUID[];

DROP INDEX IF EXISTS events_event_type_seq_idx;
CREATE INDEX IF NOT EXISTS events_tenant_type_seq_idx
  ON events (tenant_id, event_type, seq);
CREATE INDEX IF NOT EXISTS events_home_tenant_idx
  ON events (home_tenant_id) WHERE home_tenant_id IS NOT NULL;
```

- **Tenant stream のイベント**（`TenantCreated` 含む）: `tenant_id` に対象Tenantを設定。`home_tenant_id`/`granted_tenant_ids` はNULL。
- **Identity stream のイベント**（User系）: `tenant_id` はNULL。`home_tenant_id` と `granted_tenant_ids` にそのUserの値を書き込む（§4.2）。

「control-planeイベントかどうか」を `event_type` の名前リストを列挙する `CHECK` 制約で判定する案は採らない——将来イベント型が増えるたびに更新を忘れるリスクがあり監査上不確実なうえ、ハードコードされたリストは腐る（運用ドリフトの典型例）。

代わりに、`tenant_id` と `home_tenant_id`/`granted_tenant_ids` の値は**どのSQL文を実行したコードパスか**（`forTenant` 由来の `appendToPg` か、`identityStore` 由来の `appendToPg` か）だけで構造的に決まる——`forTenant` の実装は常に `tenant_id = <束縛されたTenantId>` をリテラルとして埋め込み、`identityStore` の実装は常に `tenant_id = NULL` をリテラルとして埋め込む。Core のイベントペイロードの内容を読んでtenant_idを決めるコードを一切書かない。これにより「新しいイベント型を追加したらCHECKリストを更新する」という運用上の負債が発生しない。§8 のテストでこの構造的性質（2つの `appendToPg` 実装がそれぞれ固定の値しか書かないこと）を直接検証する。

`stream_version` も同様に複合化する:

```sql
CREATE TABLE IF NOT EXISTS stream_version (
    tenant_id UUID    PRIMARY KEY REFERENCES tenants(tenant_id),
    version   BIGINT  NOT NULL DEFAULT 0
);
-- Identity stream用の番兵行（外部キー制約を満たすダミーTenant行は作らず、
-- stream_version とは別の単一行テーブル identity_stream_version を新設する）
CREATE TABLE IF NOT EXISTS identity_stream_version (
    id      INT    PRIMARY KEY CHECK (id = 1),
    version BIGINT NOT NULL DEFAULT 0
);
```

「NULLを主キーにできないので番兵UUIDを使う」案は、`tenants` テーブルへの外部キー制約と矛盾する（番兵UUIDがテナントとして存在してしまう）うえ、`tenant_id = '00000000-...'` という特殊値をRLSポリシーの各所で特別扱いし続ける必要があり複雑になる。Identity streamは性質が異なる（Tenantではない）ので、`stream_version` を共用せず**専用テーブル `identity_stream_version` を素直に分ける**——複雑な番兵値は導入しない。

### 6.3 Row Level Security — fail-closed、かつ Identity stream も漏らさない

```sql
ALTER TABLE events ENABLE ROW LEVEL SECURITY;
ALTER TABLE events FORCE ROW LEVEL SECURITY;   -- テーブル所有者にも適用させる（§6.4参照）

CREATE POLICY events_tenant_select ON events
  USING (
    tenant_id = current_setting('app.tenant_id', true)::uuid
    OR home_tenant_id = current_setting('app.tenant_id', true)::uuid
    OR current_setting('app.tenant_id', true)::uuid = ANY(granted_tenant_ids)
  );

CREATE POLICY events_tenant_insert ON events
  FOR INSERT WITH CHECK (
    tenant_id = current_setting('app.tenant_id', true)::uuid
    OR home_tenant_id = current_setting('app.tenant_id', true)::uuid
    OR current_setting('app.tenant_id', true)::uuid = ANY(granted_tenant_ids)
  );

ALTER TABLE stream_version ENABLE ROW LEVEL SECURITY;
ALTER TABLE stream_version FORCE ROW LEVEL SECURITY;
CREATE POLICY stream_version_tenant ON stream_version
  USING (tenant_id = current_setting('app.tenant_id', true)::uuid)
  WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid);

-- identity_stream_version は単一行であり、Identity streamへの書き込み権限を
-- 持つロール（owl_app 全体）からは常に見える。RLSは不要（テーブルが空でない一意行のみ）。
```

`current_setting('app.tenant_id', true)` の第2引数 `true` は「未設定ならエラーでなく `NULL` を返す」指定。`tenant_id = NULL` は常に `false` と評価されるため、**セッション変数を設定し忘れたコネクションは何も見えない（fail-closed）**。一方、`app.tenant_id` に**不正な値**（空文字列やUUID形式でない文字列）が入っている場合は `::uuid` キャストがエラーになり、クエリ自体が失敗する——これも「黙って他社のデータが見える」より安全な失敗モードであるため、意図的にそのままにする（キャストエラーを握り潰してNULL扱いにする実装をShell側で書かない）。

`events_tenant_select`/`events_tenant_insert` のINSERT用ポリシーは「3つのORのどれかに一致すればよい」という形だが、これはRLSの責務ではなくアプリのコードパスの責務として保証する（§6.2と同じ理由）。`identityStore` の `appendToPg` 実装は **Identity stream用のCore Event型からしか呼ばれない**ようにGHCの型で強制する（`Core.Identity.Event` と `Core.Event` を別の型にし、`identityStore`/`forTenant` それぞれの `esAppend` の型を変えずに内部で正しい型のリストだけを受け取るラッパー関数 `appendIdentityEvents :: EventStore -> [Core.Identity.Event] -> IO ...` / `appendTenantEvents :: EventStore -> [Core.Event] -> IO ...` を公開APIとする）。Postgres側のCHECK制約で型を表現するのではなく、Haskell側の型で表現する——CLAUDE.mdの「Core.Eventは追記専用」という既存方針と同じレベルの保証。

### 6.4 ロール分離 — 所有者と実行ロールを分ける（既存設定の修正が必要）

[infra/vm-db/setup.sh:144](../infra/vm-db/setup.sh#L144) は `createdb -O owl_app owl` としており、**`owl_app` がデータベース／テーブルの所有者になっている**。PostgreSQLのRLSは既定でテーブル所有者には適用されない。これは現状の設定のまま `tenant_id` 列を足しただけではRLSが実質無効化されるため、**修正が必須**。

```sql
-- マイグレーション専用ロール（DDL実行・所有者）
CREATE ROLE owl_migrator WITH LOGIN NOCREATEDB NOCREATEROLE NOSUPERUSER;
ALTER TABLE events OWNER TO owl_migrator;
ALTER TABLE stream_version OWNER TO owl_migrator;
ALTER TABLE identity_stream_version OWNER TO owl_migrator;
ALTER TABLE tenants OWNER TO owl_migrator;

-- 実行時ロール（owlv本体・owlv-batch-centerが使う、所有者ではない）
GRANT SELECT, INSERT ON events, stream_version, identity_stream_version TO owl_app;
ALTER ROLE owl_app NOBYPASSRLS;
-- tenants テーブルへの直接権限は与えない（§6.1）

-- root_admin_username 専用（doc/user.md のブートストラップ管理者のみが使う）
CREATE ROLE owl_platform_admin WITH LOGIN NOCREATEDB NOCREATEROLE NOSUPERUSER;
GRANT SELECT ON tenants TO owl_platform_admin;
ALTER ROLE owl_platform_admin NOBYPASSRLS;
```

`Shell.EventStore.migrate` は今後 `owl_migrator` で実行し、ランタイム接続（`PG.connectPostgreSQL`）は `owl_app`（または `root_admin_username` のセッションに限り `owl_platform_admin`）を使う、という運用に変える。現状の `connectAndMigrate` は**アプリ起動ごとに**マイグレーションを実行しているが（[Shell/EventStore.hs:73-100](../src/Shell/EventStore.hs#L73-L100)）、ロール分離後は `owl_app` がDDL権限を持たないため**この挙動自体を変える必要がある**——マイグレーションは明示的な運用コマンド（`owl-migrate` 等）として分離し、`connectAndMigrate` は「マイグレーション済みであることを前提に接続するだけ」に縮小する。

なお、バックアップ（[infra/host/sbin/owl-control.sh](../infra/host/sbin/owl-control.sh) の `pg_basebackup`）はファイルシステムレベルの物理バックアップであり、SQL/RLSを経由しない。したがってバックアップ用に `BYPASSRLS` を持つロールを新設する必要は**ない**——既存の `owl_repl` ロール（レプリケーション専用）のままで問題ない。

### 6.5 セッション変数のセット方法

`forTenant`/`identityStore` でコネクションを取得した直後、必ず以下を実行する（バインドパラメータ必須、§5.3）:

```haskell
PG.execute conn "SELECT set_config('app.tenant_id', ?, false)" (PG.Only tenantIdText)
```

`false` はセッション単位での設定（トランザクション単位ではない）を意味する。現状はコネクションを使い切り型（`forTenant` で1接続を1Tenantのハンドルの生存期間中ずっと束縛）で運用するため、これで問題ない。

コネクションプール導入時の罠を明記しておく。プールから返却される接続は `app.tenant_id` が前の利用者の値を保持したままになりうる。プールを導入する場合は (a) `set_config` の第3引数を `true`（トランザクション単位）に変える、または (b) プールへの返却フック（`RESET ALL` 相当）を必ず挟む、のいずれかを設計時に選び直すこと。さらに保険として、データベースレベルで安全側のデフォルトを設定しておく:

```sql
ALTER DATABASE owl SET app.tenant_id = '';
```

こうすると、何らかの理由で `set_config` の呼び出しが漏れた新規接続は「空文字列」というUUIDとして不正な値になり、`::uuid` キャストが**即座にエラー**になる（fail-closedがさらに早い段階で発火する）。

### 6.6 既存バッチ処理（cron_batch.md）との整合

[doc/cron_batch.md](cron_batch.md) の `owlv-batch-center`（`_owlbatch` OSアカウント、減価償却・ECL再計算・期間締め等）は、本書の導入後は**処理対象のTenantごとに `forTenant` でハンドルを取得して回す**よう変更する。現状は単一ストリーム前提で全件処理していたはずの箇所が、Tenant単位のループに変わる。`_owlbatch` が使うPostgresロールは `owl_app` と同等の権限（`owl_app` をそのまま使うか、同じ権限セットを持つ `owl_batch` ロールを分けるかは運用ポリシーで決める——少なくとも `owl_migrator`/`owl_platform_admin` の権限は持たせない）。

## 7. 移行手順

1. `tenants` / `identity_stream_version` テーブルを作成。既存の全イベントを所有する「デフォルトTenant」を1行 INSERT（既存データの移行先）。`tenants.tenant_id` に対応する `stream_version` 行も同時に作成する。
2. `events.tenant_id`/`home_tenant_id`/`granted_tenant_ids` を追加（すべて当面NULL許容）。
3. 既存イベントを2分類する: User系イベント（`CreateUser`/`ChangeUserRole`等）は `home_tenant_id = <デフォルトTenant>` を設定し `identity_stream_version` へ移動、それ以外は `tenant_id = <デフォルトTenant>` を設定して既存 `stream_version` 行（複合キー化後）に対応させる。
4. `stream_version` を複合キー化（`tenant_id` 主キー）。
5. RLSポリシー（§6.3）・ロール分離（§6.4）を適用。
6. Haskell側 `forTenant`/`identityStore`/`appendTenantEvents`/`appendIdentityEvents` を実装し、既存の `newPostgresEventStore` 呼び出し元（`app/Main.hs`）を「デフォルトTenantで `forTenant`」に置き換える時点ではまだ単一Tenant運用と機能的に同値であることを確認する（regression防止）。
7. [doc/cron_batch.md](cron_batch.md) のバッチ処理を§6.6の方針でTenant単位ループに変更。
8. 2つ目のTenantを作成し、§8 のクロステナント漏洩テストが通ることを確認してからTenant作成UIを解放する。

各ステップは `events` の追記専用原則（CLAUDE.md）に違反しない——`ALTER TABLE ADD COLUMN` と一括 `UPDATE` は既存行の論理的内容（`payload`）を変更せず、新設のメタデータ列を埋めるだけである点に注意して実装する。

## 8. テスト戦略

- **Haskell プロパティテスト**: 2つの `TenantId` それぞれで `forTenant` したダミー `EventStore`（インメモリ実装）に対し、TenantAのイベントをfoldした `AppBook` にTenantBの `JournalEntryId` が一切出現しないことを検証する。
- **構造的コードパステスト**: `forTenant` の `appendToPg` 実装が常に固定の `tenant_id` を書き、`identityStore` の実装が常に `tenant_id = NULL` を書くことを、実際にSQLを発行して検証する（§6.2/§6.3の構造的保証の検証）。
- **SQL統合テスト**:
  - `owl_app` ロールで接続し `app.tenant_id` をTenantAにセットした状態で、`SELECT * FROM events WHERE tenant_id = '<TenantB>'` を**明示的に書いても**0件であることを確認する（RLSが`WHERE`の誤りを上書きすることの直接的な証明）。
  - `set_config` を呼ばずに接続した場合も0件（fail-closed）であることを確認する。
  - TenantBの従業員に関するUser系イベント（`home_tenant_id = TenantB`）が、TenantAのセッションから見えないことを確認する（§4.2の漏洩対策の検証）。
  - `tenants` テーブルへの直接 `SELECT` が `owl_app` から拒否され、`owl_platform_admin` からのみ許可されることを確認する。
- **権限境界テスト**: `owl_migrator` ロールでDDLが通り `owl_app` ロールでは `ALTER TABLE` が拒否されること、`owl_app`/`owl_platform_admin` がいずれも `BYPASSRLS` を持たないことを `pg_roles` で確認する。

## 9. 残課題

連結（§4.3）とハッシュ連鎖（直下）は構造を確定済みであり、真に先送りするのはスキーマ／DB単位への分離のみ——これは現時点で講じる必要がない過剰設計である。

- **改ざん検知ハッシュ連鎖（spec §7）**: `row_hash`/`prev_hash` の連鎖は、**`tenant_id` ごとに独立したパーティションとして連鎖する**（Identity streamも `identity_stream_version` 配下で独立した1本の連鎖を持つ）。これは先送りせず本書で確定する方針——具体的なDDL（`prev_hash` の参照先を `WHERE tenant_id = NEW.tenant_id ORDER BY seq DESC LIMIT 1` に変える等）は [infra/vm-db/doc/event-store.md](../infra/vm-db/doc/event-store.md) 側の改訂で反映する。
- **スキーマ／DB単位分離へのエスカレーション**: 規制上の理由で物理分離が必要なTenant（spec §3 高リスクティア相当）が出た場合、当該Tenantだけ別スキーマまたは別データベースに切り出す escalation path を確保しておく。`forTenant` のシグネチャ（`PG.Connection -> TenantId -> IO (Either AppError EventStore)`）は、接続先を変えるだけで対応できるため、この拡張に対して閉じている。これは現時点で実装の必要がないため先送りで問題ない。
