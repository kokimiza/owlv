# 労務人事 基本設計書

## 0. この文書の位置づけ

本書は [project_management.md](project_management.md) §0.1 で定めた4機能領域のうち、**労務人事**の基本設計を定める。労務人事モジュールは Project ストリームの**購読者**であり、自らイベントの発生源にはならない——人が稼働した・契約したという事実は、Project 側の発注・業務委任イベントに付随して初めて意味を持つためである。

### 0.1 既存 `User.hs` との明確な区別

`src/Core/Domain/User.hs` は **システムへのログイン主体**（OS アカウント・SSH 鍵・Role による画面アクセス権）を表す。これは「誰がこの owlv を操作できるか」という統制の話であり、[user.md](user.md) が定義する。

労務人事モジュールが扱う **Personnel**（人材・外注先個人）は、**「誰が現場で稼働しているか」という雇用・契約上の事実**であり、システムへのログイン権限を持つとは限らない（外注先はそもそも owlv にログインできない）。両者は完全に独立したドメインであり、`User.hs` を流用・拡張しない——目的が違う2つの概念を1つの型に押し込めることは、[CLAUDE.md](../CLAUDE.md) が禁じる責務の混在にあたる。

両者がたまたま同一人物を指す場合（例: 社内クリエイターが owlv にもログインする）は、`PersonnelUserLink Personnel UserId`（任意の弱い関連）として表現し、構造的な依存は持たせない。

---

## 1. ドメインモデル

### 1.1 `Personnel`

```haskell
data PersonnelId = PersonnelId UUID

data EmploymentType
  = FullTimeEmployee     -- 正社員（IAS19 の対象、既存 EmployeeBenefit.hs と直結）
  | FixedTermEmployee     -- 契約社員
  | Contractor            -- 業務委託・外注（個人）
  | CorporateVendor       -- 外注（法人）。Project 側の Partner (Vendor) と1:1で対応する場合が多い

data Personnel = Personnel
  { personnelId       :: PersonnelId
  , personnelTenant    :: TenantId
  , personnelName       :: Text
  , personnelEmploymentType :: EmploymentType
  , personnelPartnerRef :: Maybe PartnerId  -- CorporateVendor/Contractor の場合、既存 Partner.hs への参照
  , personnelUserRef    :: Maybe UserId     -- §0.1 の弱い関連
  , personnelStatus      :: PersonnelStatus -- Active | Suspended | Departed
  }
```

`Personnel` はマスタとして増減するが、商品マスタと違い**繰り返し参照される有限の実体**（人）であるため、マスタ化することに [project_management.md §0.2](project_management.md) の批判は当たらない。

### 1.2 `ContractTerm`（契約条件）

```haskell
data ContractTermId = ContractTermId UUID

data PayBasis
  = MonthlySalary Money
  | DailyRate Money
  | PieceRate Money            -- 件当たり（背景1枚いくら、等）
  | RevenueShare Rational      -- 売上分配率（ライセンス収益の分配等）

data ContractTerm = ContractTerm
  { ctId          :: ContractTermId
  , ctPersonnel   :: PersonnelId
  , ctPayBasis    :: PayBasis
  , ctEffectiveFrom :: Day
  , ctEffectiveTo   :: Maybe Day
  }
```

契約条件は履行期間ごとに新しい `ContractTerm` を追記する（書き換えない）。これは [ifrs_standard.md](ifrs_standard.md) の仕訳行為区分と同じ「事実は追記、書き換えではない」原則を契約条件にも適用したものである。

### 1.3 `WorkAssignment`（稼働割当）

```haskell
data WorkAssignmentId = WorkAssignmentId UUID

data WorkAssignment = WorkAssignment
  { waId          :: WorkAssignmentId
  , waPersonnel   :: PersonnelId
  , waProject     :: ProjectId         -- project_management.md の Project を直接参照
  , waPhase        :: Maybe ProjectPhaseId
  , waExternalOrder :: Maybe ExternalOrderId  -- §2.1: ExternalOrderPlaced から自動生成される場合
  , waAssignedDate :: Day
  , waStatus       :: WorkAssignmentStatus -- Assigned | InProgress | Completed | Cancelled
  }
```

### 1.4 `TimesheetEntry`（稼働実績）

```haskell
data TimesheetEntryId = TimesheetEntryId UUID

data TimesheetEntry = TimesheetEntry
  { tsId          :: TimesheetEntryId
  , tsAssignment  :: WorkAssignmentId
  , tsDate        :: Day
  , tsHours        :: Maybe Decimal     -- 時間給/月給制の場合のみ意味を持つ
  , tsQuantity     :: Maybe Natural     -- 件当たり制の場合（背景5枚中3枚完了、等）
  , tsRecordedBy   :: UserId            -- 入力者（本人または管理者、[user.md] の Role に従う）
  }
```

`TimesheetEntry` は `PayBasis` が `PieceRate`/`DailyRate` 等の場合は必須ではない——`ExternalOrder` の `ConfirmDelivery`（[project_management.md §2.1](project_management.md)）がそのまま完了の事実になるケースが多く、重複入力を強制しない。これも「現場はただ事実を投げるだけ」（[project_management.md §0.1](project_management.md)）の延長である。

---

## 2. Project ストリームの購読

### 2.1 `ExternalOrderPlaced` から `WorkAssignment` を導く

[project_management.md §2.2](project_management.md) の `ExternalOrderPlaced`（例: 「外部A氏に背景5枚を発注、単価5万」）を労務人事モジュールが購読すると、次の照合・記録処理が走る（[project_management.md §5.1](project_management.md) と同じプロセスマネージャ機構、Shell 層 `Shell.Subscribers.ProjectToLabor`）。

```
ExternalOrderPlaced (orderVendor = A氏のPartnerId)
        │
        ▼
1. orderVendor に対応する Personnel を照合する
     - 見つかった場合: その Personnel の ContractTerm が有効か検証する
     - 見つからない場合: PersonnelReconciliationFailed イベントを発行し、人が確認するまで
       WorkAssignment は作らない（自動でマスタを作らない——無断で実体を増やさない）
2. 照合に成功したら WorkAssignmentCreated を発行する
```

この「照合に失敗したら止まる」という挙動は、[user.md §3.1](user.md) の `owl-user-sync` が採用する **「スクリプトの自己申告を信じない」方針**と同じ立場である。Project 側が発注した時点で労務人事側の実体が無条件に作られることはない。

### 2.2 稼働状況の Project 側へのフィードバックは行わない

労務人事モジュールは Project の状態を書き換えない（`decide`/`evolve` は Project 集約に対して労務人事から発行されることはない）。`WorkAssignment`/`TimesheetEntry` の確定は労務人事ストリーム内に閉じ、Project 側の `ExternalOrder.orderStatus` は引き続き [project_management.md §2.1](project_management.md) の `ConfirmDelivery` コマンドのみが更新する。これにより、Project（発生源）と労務人事（確定者の一つ）の間の循環参照を構造的に排除する（§0.1 の「単一発生源」を保つための必須条件）。

---

## 3. コマンド・イベントカタログ

`Core/Command.hs`・`Core/Event.hs` へ以下を追加する（[project_management.md §2](project_management.md) と同じ方針——単一の直和型に新規ドメインのコンストラクタを追加する）。

| コマンド | 発行者 | 説明 |
|---|---|---|
| `RegisterPersonnel` | 人間（Admin/Maintainer） | |
| `RecordContractTerm` | 人間 | |
| `CreateWorkAssignment` | システム（§2.1）または人間 | |
| `RecordTimesheetEntry` | 人間（本人または管理者） | |
| `CompleteWorkAssignment` | システム（`ExternalOrderDeliveryConfirmed` 購読）または人間 | |
| `SuspendPersonnel` / `ReactivatePersonnel` / `MarkPersonnelDeparted` | 人間 | |

| イベント | 説明 |
|---|---|
| `PersonnelRegistered Personnel` | |
| `ContractTermRecorded ContractTerm` | |
| `WorkAssignmentCreated WorkAssignment` | |
| `PersonnelReconciliationFailed ExternalOrderId Text` | §2.1 の照合失敗。財務会計側のアラート対象にもなる（§4） |
| `TimesheetEntryRecorded TimesheetEntry` | |
| `WorkAssignmentCompleted WorkAssignmentId Day` | |
| `PersonnelStatusChanged PersonnelId PersonnelStatus` | |

`evolve` には `personnelIndex :: Map PersonnelId PersonnelAggregate` を `State.hs` に追加する。Project 集約・Journal 集約と同様、他集約への直接参照は持たない。

---

## 4. 財務会計との連動

### 4.1 正社員給与・退職給付（既存 `EmployeeBenefit.hs`、IAS19）

`FullTimeEmployee` の `TimesheetEntry`/`ContractTerm` は、既存の `EmployeeBenefit.hs`（ボーナス・有給休暇・年金・退職給付の会計上の負債）の算定根拠データになる。財務会計モジュールは労務人事ストリームの `ContractTermRecorded`/`TimesheetEntryRecorded` を購読し、[project_management.md §5.1](project_management.md) と同じプロセスマネージャ機構で `BenefitLiabilityRecorded`（既存イベント）を生成する。本書では既存 `EmployeeBenefit.hs` の構造を変更しない——労務人事は新たな**入力源**を提供するだけである。

### 4.2 業務委託費（外注費）

`Contractor`/`CorporateVendor` の場合、会計処理の主たる起点はあくまで [project_management.md §5](project_management.md) の `ExternalOrderPlaced`→仕訳生成経路である。労務人事モジュールはこの経路の**正当性検証**（本当にその外注先と有効な契約があるか）を担うが、仕訳そのものは生成しない。`PersonnelReconciliationFailed` が発生した場合、財務会計モジュールはその発注に基づく仕訳を**保留**（決算除外候補としてフラグを立てる）し、[ifrs_standard.md 第5章](ifrs_standard.md) の判断ログ統制と同様の人間確認を要求する（§8 残課題で詳細化）。

---

## 5. 権限とロール

[user.md §2](user.md) の Role をそのまま使う。`Personnel` 本人が自分の `TimesheetEntry` を入力する操作は Operator 権限で十分であり、`RegisterPersonnel`/`RecordContractTerm`（契約条件の登録）は Maintainer 以上に限定する——契約条件は会計上の負債算定根拠になるため、[ifrs_standard.md §5](ifrs_standard.md) の判断ログ統制に準じた慎重さを要求する。

---

## 6. テスト戦略

- **照合ロジックのプロパティテスト**: `PersonnelReconciliationFailed` が発生する条件（Partner 不在・ContractTerm 失効）を網羅し、誤って `WorkAssignmentCreated` が発行されないことを検証する。
- **循環参照の不在テスト**: 労務人事モジュールのいかなる `decide`/`evolve` も Project 集約・Journal 集約を変更しないことを型レベル/テストレベルで保証する（§2.2）。
- **`EmployeeBenefit` 連動の冪等性テスト**: 同じ `TimesheetEntryRecorded` 列を2回処理しても `BenefitLiabilityRecorded` が重複生成されないこと（[project_management.md §7](project_management.md) と同型）。

---

## 7. 残課題

- **`PersonnelReconciliationFailed` 発生時の財務会計側フラグ運用**: 「保留」状態の仕訳をどのレポートに出し、誰が確認して解除するかの運用フローは未設計。
- **複数 Tenant をまたぐ Personnel**: グループ会社間で同一の外注先個人が複数 Tenant のプロジェクトに稼働するケースの扱いは、[tenant_isolation.md](tenant_isolation.md) の Tenant 分離原則とどう整合させるか別途検討する（現状は Personnel も Tenant スコープ内に閉じる前提）。
- **稼働時間と契約形態の労働法上の整合チェック**: 本書は会計・現場管理の観点のみを扱い、労働基準法等の法令準拠チェック（残業上限等）は範囲外とする。将来必要になれば別モジュールとして追加する。
