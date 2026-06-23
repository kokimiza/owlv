# マルチテナント分離 設計書

## 1. 現在の実装状態

owlv は Tenant ごとに会計帳簿を分離する。`Organisation` は1つの Tenant 内部の部門階層であり、Tenant 間の親子関係ではない。

現在の実装は次の構成になっている。

| 層 | 実装 | 役割 |
|---|---|---|
| Haskell 型 | `Core.Domain.Tenant` / `Shell.EventStore.forTenant` | `EventStore` ハンドルを1つの `TenantId` に束縛する |
| PostgreSQL | `events.tenant_id` / `stream_version` / `identity_stream_version` / `tenants` | Tenant stream と Identity stream を同じ `events` テーブル内で分離する |
| RLS | `events_tenant_select` / `events_tenant_insert` / `stream_version_tenant` | `app.tenant_id` 未設定時は fail-closed。設定済みでも他Tenant行を読めない |
| Shell | `CommandExecutor` / `EventClassification` | 1つのコマンドが出したイベントを Tenant event と Identity event に分類して追記する |
| TUI | `app/Main.hs` / `Shell.UserOps.resolveSessionUser` | OSログイン名を User 射影と照合し、現在の `TenantId` と `Role` を TUI に渡す |

正式な DDL は [infra/vm-db/schema.sql](../infra/vm-db/schema.sql)、イベントストアの説明は [infra/vm-db/doc/event-store.md](../infra/vm-db/doc/event-store.md) を参照する。

## 2. 用語整理

| 概念 | 意味 | スコープ |
|---|---|---|
| `Tenant` | 会計帳簿が分離される事業者単位 | システム内に複数 |
| `Organisation` | 1つの Tenant 内部の部門階層 | Tenant 内のみ |
| `User` | AP VM の OS ユーザー名と1:1に対応するアプリ利用者 | Identity stream に保存 |
| `Role` | User が特定 Tenant で持つ権限 | `(User, Tenant)` の組 |

`UserId` は OS ユーザー名そのものなので、User のライフサイクルは Tenant stream ではなく Identity stream に置く。`User` の `userTenantRoles :: Map TenantId Role` が、どの Tenant にアクセスできるかを表す。

## 3. ストリームトポロジ

`events` は1つの物理テーブルだが、`tenant_id` によって2種類のストリームを表す。

```
Identity stream（tenant_id IS NULL）
  └─ UserCreated / UserRoleChanged / UserTenantAccessGranted / UserOsSyncSucceeded / ...

Tenant stream（tenant_id = <TenantId>）
  ├─ TenantCreated / TenantSuspended / TenantArchived
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

`TenantCreated` は対象 Tenant 自身のストリームに入る。`Shell.EventStore.syncTenantRegistry` は、`TenantCreated` / `TenantSuspended` / `TenantArchived` と同じ PostgreSQL トランザクション内で `tenants` レジストリを更新する。

## 4. Haskell 設計

### 4.1 Tenant 型

現在の `TenantId` は `Text` newtype であり、PostgreSQL の `tenant_id UUID` に格納できる文字列を運用上の前提にしている。`defaultTenantId` は開発・初期ブートストラップ用の固定 UUID である。

```haskell
newtype TenantId = TenantId { unTenantId :: Text }

data TenantStatus
  = TenantStatusActive
  | TenantStatusSuspended
  | TenantStatusArchived

data TenantKind
  = StandaloneTenant
  | ConsolidationTenant (NonEmpty TenantId)

data Tenant = Tenant
  { tenantId     :: TenantId
  , tenantName   :: Text
  , tenantStatus :: TenantStatus
  , tenantKind   :: TenantKind
  }
```

`Core` は純粋層なので、UUID発行・DB存在確認・セッション変数設定は Shell/PostgreSQL 側の責務である。

### 4.2 EventStore の束縛

`forTenant :: PG.Connection -> TenantId -> IO (Either AppError EventStore)` は、接続に対して `SELECT set_config('app.tenant_id', ?, false)` を実行し、その Tenant に束縛された `EventStore` を返す。

`EventStore` の利用側は `esLoad` / `esAppend` に TenantId を渡さない。TenantId はクロージャ内に閉じ込められ、呼び出し側で別 Tenant の ID を渡し間違える経路を作らない。

### 4.3 Identity event の扱い

`Core.Event` は Tenant event と Identity event を同じ ADT に持つ。`Shell.EventClassification.isIdentityEvent` が User 系イベントを Identity stream として分類し、`appendToPg` は次のように振り分ける。

- Tenant event: `events.tenant_id = esTenant`
- Identity event: `events.tenant_id = NULL`

1コマンドが両方にまたがるイベントを出しても、`appendToPg` は1トランザクション内で両方のバージョンを確認・更新できる。ただし現在の Core では通常、1コマンドのイベントは片方の stream に閉じる。

## 5. PostgreSQL 設計

### 5.1 テーブル

現在のスキーマは次の4テーブルを使う。

| テーブル | 役割 |
|---|---|
| `tenants` | Tenant レジストリ。真実源は Tenant stream の `TenantCreated` |
| `events` | 追記専用イベントログ本体 |
| `stream_version` | Tenant stream の楽観ロック用カウンタ |
| `identity_stream_version` | Identity stream の楽観ロック用カウンタ |

`events` は UPDATE / DELETE しない。訂正や取消は新しいイベントとして追記する。

### 5.2 RLS

現在の `events` RLS は次の方針である。

```sql
tenant_id IS NULL
OR tenant_id = current_setting('app.tenant_id', true)::uuid
```

つまり Identity stream はログイン解決に必要なため DB レベルでは全 Tenant セッションから見える。Tenant間で無関係な User を画面に出さない制御は、`Core.Domain.User.visibleInTenant` と TUI 側の User 一覧で行う。

この点は旧設計案（Identity event に `home_tenant_id` / `granted_tenant_ids` を非正規化して RLS で絞る案）からの実装時調整である。現在の `schema.sql` には `home_tenant_id` / `granted_tenant_ids` 列は存在しない。

`stream_version` は `tenant_id = current_setting('app.tenant_id', true)::uuid` で RLS をかける。`identity_stream_version` は単一行のカウンタで、機密情報を持たないため RLS を付けない。

### 5.3 ロール分離

DDL 適用・テーブル所有者は `owl_migrator`、アプリ実行時接続は `owl_app`、プロジェクターは `owl_projector` を使う。

`owl_app` は `events` に `SELECT, INSERT`、`stream_version` / `identity_stream_version` に `SELECT, INSERT, UPDATE`、`tenants` に最小限の `SELECT (tenant_id, status)` と `INSERT` / `UPDATE (status)` を持つ。`owl_app` はテーブル所有者ではなく、`NOBYPASSRLS` で運用する。

`owl_projector` は `events` と `tenants(tenant_id, status)` の `SELECT` のみを持つ。SQLite リードモデルへの書き込みは AP VM ローカルファイルへの投影であり、PostgreSQL へイベントを追記する権限は持たない。

## 6. TUI と Tenant 選択

現在の `app/Main.hs` は `defaultTenantId` で `forTenant` し、OSログイン名を `Shell.UserOps.resolveSessionUser` で User 射影と照合してから TUI を起動する。`resolveSessionUser` は User の `userHomeTenant` とその Tenant における `Role` を返す。

残課題:

- Tenant 切替 UI はまだない。
- `defaultTenantId` 以外の Tenant 作成・切替フローは Core/EventStore レベルでは扱えるが、画面導線は未整備。
- TUI の一部 submit 経路はまだ固定 user context を使うため、検証済み `UserId` への置換が必要（[doc/user.md](user.md) §6）。

## 7. CQRS リードモデルとの関係

SQLite リードモデルは [doc/cqrs.md](cqrs.md) の通り Tenant ごとに別ファイルへ分離する。

```
/var/lib/owlv/readmodel/identity.sqlite3
/var/lib/owlv/readmodel/<tenant_id>.sqlite3
```

`owlv-projector` は `listActiveTenantIds` で対象 Tenant を列挙し、Identity stream と各 Tenant stream を個別に catch-up する。現在実装済みのビューは `view_journal_entry` と `view_account_balance` で、固定資産・ECL・判断ログ・KPI は今後追加する。

## 8. テスト戦略

実装済み:

- `test/Core/TenantSpec.hs`: Tenant 作成・停止・廃止、fold の決定性。
- `test/Core/UserSpec.hs`: User の Tenant Role、Admin 初期化、dual control、状態遷移。

今後追加したい統合テスト:

- `owl_app` で `app.tenant_id` を Tenant A に設定し、Tenant B の event が RLS で読めないこと。
- `app.tenant_id` 未設定時に Tenant stream が fail-closed になること。
- `owl_projector` が `INSERT` 権限を持たないこと。
- SQLite の Tenant 別ファイル分離で、別 Tenant の read model を誤って開かないこと。

## 9. 残課題

- **Tenant 切替 UI**: User の `userTenantRoles` から選択可能 Tenant を出し、選択時に `forTenant` で `EventStore` を再束縛する。
- **Identity stream のDBレベル絞り込み**: 現在はアプリ層で `visibleInTenant` により絞る。より強い分離が必要になった場合は、Identity event のメタデータ列追加を再検討する。
- **改ざん検知ハッシュ連鎖（spec §7）**: `row_hash` / `prev_hash` は未実装。導入時は Tenant stream と Identity stream で独立した連鎖にする。
- **物理分離へのエスカレーション**: 規制上の理由で必要な Tenant は、別スキーマまたは別データベースへ切り出す余地を残す。
