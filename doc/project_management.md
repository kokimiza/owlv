# プロジェクト管理 基本設計書

## 0. この文書の位置づけ

owlv は現在、財務会計モジュール（[ifrs_standard.md](ifrs_standard.md) が規定する月次決算確報、`src/Core/Domain/Journal.hs` 等）のみが実装されている。本書は、これに加えて新設する3つの機能領域——**プロジェクト管理（本書）・労務人事（[labor_management.md](labor_management.md)）・管理会計（[management_accounting.md](management_accounting.md)）**——のうち、最も中核となるプロジェクト管理の基本設計を定める。

着想は単純である。建設工事・アニメ制作のような受託・長期プロジェクト型の事業は、小売・製造業のように「商品マスタ」（無尽蔵に増える商品コード台帳）を必要としない。`〇〇工事` `第3話作画` といった「商品」は一度しか使われず、マスタに登記する意味がない。一方で、この種の事業の現場が崩壊する典型的な原因は、**プロジェクト管理（現場の進行管理）と原価管理（コスト管理）が別システムになり、両者が食い違う**ことである。本書はこれを構造的に防ぐ。

### 0.1 設計原則: 単一発生源・多重確定 (Single Source, Multiple Finalizations)

4機能領域を素朴に4つの独立モジュールとして並列実装すると、各モジュールが「自分の正しい数字」を持ち始め、整合性が崩れる（**並列ERPの失敗パターン**）。これを避けるため、本システムは次の非対称な関係を採用する。

```
[ 1. プロジェクト管理 ]  ← 唯一の発生源（イベントストリームの源泉）
        │
        │  Project ストリームへ append される事実
        │  (例: 外部A氏に背景5枚を発注、単価5万円)
        │
        ├───► [ 2. 労務人事 ]    購読者。外注先マスタ・契約形態と照合し、稼働を記録する。
        ├───► [ 3. 財務会計 ]    購読者。発生主義に基づき仕掛品/未払金の仕訳を自動生成する。
        └───► [ 4. 管理会計 ]    購読者。予算消化率を更新し、閾値超過をアラートする。
```

- **「単一ストリーム + 多重解釈」ではない**。各購読者は Project ストリームのイベントをただ読み取るだけでなく、**自分自身の確定基準（締め日・税法・契約条件）に従って、自分のストリームへ新たな事実を書き込む**。これが「単一発生源 + 多重確定」である（§5 で機構を定める）。
- 現場（プロジェクト管理）は「事実を投げるだけ」でよい。会計の確定ルール（月末締め・領収書必須等）を現場入力の時点で強制しないことで、現場が入力をやめてシステムが形骸化する事態（[ifrs_standard.md](ifrs_standard.md) が前提とする規律の崩壊）を避ける。
- 結果として生まれた仕訳・労務記録・KPI を遡れば、必ず単一の Project イベントに行き着く。これが整合性が崩れない理由であり、検証可能性（[ifrs_standard.md 第7章](ifrs_standard.md) の再現性保証要件と同じ立場）の根拠になる。

### 0.2 「商品マスタ不要」の具体的な解決

懸念: 「グッズ販売（有形）やライセンス決済（無形）のような単発即時売上が発生したとき、商品マスタなしでどうするのか」

回答: **それらも極小のワークフロー（1日で開いて閉じる Project）として一元化する**（§6）。Project というラッパーが「3年がかりのアニメ制作」も「1回のグッズ販売」も同じ型で表現する。両者の違いは存続期間の長さだけであり、ドメインモデル上は同一の概念である。

商品名の代わりに分類が必要な箇所（会計上の費用・収益の性質区分）は、**有限の列挙型（`ExpenseNature` / `RevenueNature`、§2.3）** で表現する。これは商品マスタとは違い、勘定科目分類と同じオーダーの個数（十数〜数十種）に留まり、無尽蔵に増えない。「商品マスタを捨てる」とは「無限に増える固有名詞の管理をやめる」ことであり、「有限な性質分類をやめる」ことではない。

---

## 1. ドメインモデル

### 1.1 `Project`

```haskell
data ProjectId = ProjectId UUID

data ProjectLifecycle
  = LongRunning      -- アニメ制作・建設工事等。複数会計期間にわたる
  | SingleTransaction -- グッズ販売・ライセンス決済等。即時に開いて閉じる (§6)

data ProjectStatus
  = ProjectOpen
  | ProjectInProgress
  | ProjectClosed
  | ProjectCancelled

data Project = Project
  { projectId          :: ProjectId
  , projectTenant       :: TenantId         -- doc/tenant_isolation.md §3 の Tenant stream に属する
  , projectOrg          :: OrganisationId   -- 入力部門（既存 Organisation.hs を再利用）
  , projectName          :: Text            -- 自由記述（「〇〇工事」「グッズ販売A」等、マスタ化しない）
  , projectLifecycle    :: ProjectLifecycle
  , projectStatus        :: ProjectStatus
  , projectCustomer      :: Maybe PartnerId  -- 既存 Partner.hs (Customer) を再利用。売上が立つ場合のみ
  , projectBudgetTotal  :: Money            -- 予算総額（0始まりも許容、後から増額可。§1.4）
  , projectOpenedDate   :: Day
  , projectExpectedEndDate :: Maybe Day
  }
```

Project は固有名詞の集積場所であり、商品マスタの代替である。`projectName` は自由記述のままにし、コード化・マスタ化を行わない——それ自体がマスタ管理コストを生むため。検索性は CQRS リードモデル（[cqrs.md §5](cqrs.md)）の全文検索ビューで担保し、Core 側に正規化制約を持ち込まない。

### 1.2 `ProjectPhase`（工程・話数単位の予算）

```haskell
data ProjectPhaseId = ProjectPhaseId UUID

data ProjectPhase = ProjectPhase
  { phaseId       :: ProjectPhaseId
  , phaseProject  :: ProjectId
  , phaseName     :: Text         -- 「第1話」「躯体工事」等
  , phaseBudget   :: Money        -- Project 予算の内訳（Phase予算合計 <= Project予算、decide で検証）
  , phaseStatus   :: ProjectStatus -- Project と同じ語彙を使い回す
  }
```

Phase は Project 予算を業務単位に分割するための任意の中間ノードである。`SingleTransaction` ライフサイクルの Project は通常 Phase を持たない（§6）。

### 1.3 `ExternalOrder`（外部発注、ユーザー提示例の核）

```haskell
data ExternalOrderId = ExternalOrderId UUID

data ExternalOrder = ExternalOrder
  { orderId           :: ExternalOrderId
  , orderProject      :: ProjectId
  , orderPhase        :: Maybe ProjectPhaseId
  , orderVendor       :: PartnerId        -- 既存 Partner.hs (Vendor) を再利用——発注先は「マスタ管理してよいもの」
  , orderDescription  :: Text             -- 「背景5枚」等。自由記述（商品マスタの代替にしない）
  , orderNature       :: ExpenseNature    -- §1.4 有限分類
  , orderUnitPrice    :: Money
  , orderQuantity     :: Natural
  , orderDate         :: Day
  , orderExpectedDate :: Maybe Day
  , orderStatus       :: OrderStatus      -- Ordered | PartiallyDelivered | Delivered | Cancelled
  }
```

発注先（Vendor）はマスタ化してよい——発注先の数は有限で、繰り返し取引されるため正規化に意味がある。商品マスタ不要論が否定するのは「一度しか使わない商品コード」であり、「繰り越し利用される取引先」ではない。これは既存 `Partner.hs` の役割と完全に一致するため、新規の型を作らず再利用する。

### 1.4 性質分類（有限列挙、商品マスタの代替）

```haskell
data ExpenseNature
  = SubcontractCost      -- 外注費
  | MaterialCost         -- 材料費
  | LaborCost            -- 労務費（労務人事モジュール起因、§2 labor_management.md）
  | TravelExpense        -- 旅費交通費
  | LicenseFee           -- ライセンス・権利使用料
  | Consumables          -- 消耗品費
  | Other Text           -- 上記に当たらない場合の説明書き（無制限の固有名詞をここに押し込めない——
                          -- 頻発する Other は §8 残課題として列挙拡張の検討対象にする）

data RevenueNature
  = GoodsSale            -- グッズ販売等の有形即時売上
  | LicenseSettlement    -- ライセンス決済等の無形即時売上
  | LongTermContractRevenue -- 進行基準（IFRS 15、ifrs_standard.md §4.3）に基づく長期契約売上
```

この分類は財務会計モジュールが仕訳を自動生成する際の **account mapping** の鍵になる（§5.2）。分類数は勘定科目分類と同オーダーであり、商品コードのように無尽蔵に増えない——これが「マスタ不要」の構造的根拠である。

### 1.5 予算改定の履歴性

予算は `projectBudgetTotal`/`phaseBudget` というスナップショット属性ではなく、**改定イベントの蓄積**として保持する（§3 のイベントカタログにある `ProjectBudgetRevised`）。`evolve` がイベント列を fold した結果が現在値であり、Journal の仕訳訂正と同じ「新しい事実を追記する、書き換えない」原則（[CLAUDE.md](../CLAUDE.md) のドメイン不変条件）に従う。

---

## 2. コマンド・イベント・不変条件（`decide`/`evolve` への実装方針）

[CLAUDE.md](../CLAUDE.md) の機能追加レシピに従い、`Core/Command.hs` と `Core/Event.hs` の既存の単一直和型に以下のコンストラクタを追加する（既存 22 ドメイン型と同じ並列構造を維持し、Project 専用の別ファイル分割は行わない——`Journal`/`FixedAsset` 等と同列の一ドメインとして扱う）。

### 2.1 コマンド

| コマンド | 主要フィールド | `decide` が検証する不変条件 |
|---|---|---|
| `OpenProject` | Project の全フィールド | `projectBudgetTotal >= 0`、`projectOrg` が存在し発行者が権限を持つ（[user.md](user.md) §2 の OrgPermission） |
| `AddProjectPhase` | ProjectPhase | `phaseBudget` を加算した合計が `projectBudgetTotal` を超えない（超える場合は先に `ReviseProjectBudget` が必要） |
| `ReviseProjectBudget` | ProjectId, 新予算総額, 改定理由 Text | 既存 Phase 予算合計を下回る減額は拒否（Phase 側を先に減らす） |
| `PlaceExternalOrder` | ExternalOrder の全フィールド | `orderProject` が `ProjectInProgress`/`ProjectOpen` であること（`ProjectClosed` への発注は拒否） |
| `ConfirmDelivery` | ExternalOrderId, 確認日, 確認数量 | 確認数量が未確認の残数量を超えない（部分検収を許容） |
| `CancelExternalOrder` | ExternalOrderId, 理由 | `Delivered` 済みの発注はキャンセル不可（[ifrs_standard.md] の取消/反対と同じ「事実は消さない」思想——代わりに損失計上は財務会計側の判断） |
| `RecordSingleTransaction` | §6 参照 | — |
| `CloseProject` | ProjectId, 完了日 | 未確定（`Ordered`/`PartiallyDelivered`）の発注が残る場合は警告イベントを伴うが、クローズ自体は拒否しない（現場が確定を待たずに次へ進めることを優先する。§0.1 の設計原則） |

### 2.2 イベント

| イベント | 説明 |
|---|---|
| `ProjectOpened Project` | |
| `ProjectPhaseAdded ProjectPhase` | |
| `ProjectBudgetRevised ProjectId Money Text` | 新総額・改定理由 |
| `ExternalOrderPlaced ExternalOrder` | **ユーザー提示例の核心イベント**。労務人事・財務会計・管理会計の3者が同時に購読する |
| `ExternalOrderDeliveryConfirmed ExternalOrderId Day Natural` | 確認日・確認数量 |
| `ExternalOrderCancelled ExternalOrderId Text` | |
| `SingleTransactionRecorded SingleTransaction` | §6 |
| `ProjectClosed ProjectId Day` | |

### 2.3 `evolve` への組み込み

`State.hs` の集約状態に `projectIndex :: Map ProjectId ProjectAggregate` を追加する。`ProjectAggregate` は Project 本体・Phase 一覧・発注一覧・現在の予算消化額（受領済み発注の合計、§4 管理会計が参照する数値の Core 側の唯一の真実）を保持する。既存の `AccountMaster`/`Journal` 等の集約と同じ並列構造とし、Project 集約と Journal 集約の間に直接の参照は持たせない——両者をつなぐのは購読（§5）のみであり、Core 内で密結合させない。

---

## 3. ストリームトポロジ上の位置

[tenant_isolation.md §3](tenant_isolation.md) の Tenant stream に新たな「Book」として `ProjectBook` を追加する。既存の `JournalBook`/`CashBook`/`AssetBook` 等と同列であり、新たな Tenant 分離機構やパーティショニング方式は導入しない——既存の `tenant_id` 単位の Postgres ストリームにそのまま乗せる。

```
Tenant stream（tenant_id = <TenantId>）
  ├─ MasterBook
  ├─ ProjectBook        ← 新設。本書の対象 (ExternalOrderPlaced 等)
  ├─ JournalBook         既存
  ├─ CashBook
  ├─ PeriodsBook
  ├─ AssetBook
  ├─ EclBook
  ├─ FxBook
  ├─ JudgmentLogBook
  ├─ LaborBook          ← 新設 (labor_management.md)
  ├─ BenefitBook         既存（IAS19、労務人事の事実から起票される）
  ├─ TaxBook
  └─ ManagementAccountingBook ← 新設 (management_accounting.md)
```

---

## 4. 権限とロール

[user.md §2](user.md) の Role 体系（Operator/Maintainer/Admin）をそのまま使う。プロジェクト管理特有のロール拡張は導入しない。`OrgPermission`（既存）が部門単位のアクセス境界を既に提供しているため、Project もこれに従い `projectOrg` を経由してスコープ制御する。発注の承認権限（一定額以上の発注に上長承認を要求する等）が将来必要になった場合は、`JournalEntry` の決裁フローとは独立した「Project 用の決裁ワークフロー」を検討する（§8 残課題）。

---

## 5. 下流モジュールとの連動機構（最重要）

### 5.1 「購読者」とは何か——プロセスマネージャ・パターン

各下流モジュール（財務会計・労務人事・管理会計）は、CQRS リードモデルの単純な射影（[cqrs.md §3](cqrs.md) の `owlv-projector`、読み取り専用 SQLite を再構築するだけの既存パターン）とは異なる役割を持つ。下流モジュールは Project イベントを読み取った結果として、**新たなコマンドを自分自身のドメインに対して発行し、Event Store へ新しいイベントを追記する**。

これは ES の「プロセスマネージャ（Process Manager）/ サーガ」パターンであり、機構としては [CLAUDE.md](../CLAUDE.md) が定める既存の単一コマンド実行器（イベント読み込み → `evolve` で fold → `decide` → イベント追記）を**そのまま再利用する**。違いは唯一つ——コマンドの発行者（actor）が人間の `UserId` ではなく、システム自身（例: `SystemActor "project-to-ledger-subscriber"`）であることだけである。新しい実行経路を増設しない。

```
[Postgres LISTEN/NOTIFY] (cqrs.md §3.1 と同じ通知機構)
        │ ExternalOrderPlaced を検知
        ▼
[Shell.Subscribers.ProjectToLedger]  (新設、Shell 層。Core には一切手を入れない)
        │ 1. 受信した ExternalOrder の orderNature から account mapping 表を引く (§5.2)
        │ 2. RecordJournalEntry コマンドを組み立てる (actor = システム)
        │ 3. 既存の単一コマンド実行器へそのまま渡す
        ▼
[既存の decide/evolve/EventStore.append]
        │
        ▼
JournalEntryRecorded が Tenant stream の JournalBook に追記される
```

財務会計の確定基準（締め日・領収書必須等、[ifrs_standard.md 第4章](ifrs_standard.md)）は、この Subscriber の内部にのみ存在する。Project 側の `decide` は一切これを知らない——これが §0.1 の「現場は事実を投げるだけ」の実装上の意味である。

### 5.2 Account Mapping（性質分類 → 勘定科目の決定的写像）

```haskell
-- Shell.Subscribers.ProjectToLedger 内、Core ではない（会計方針は頻繁に変わるため
-- Core の決定的ロジックに焼き込まず、設定として外出しする）
natureToAccount :: ExpenseNature -> (AccountCode, AccountCode)  -- (Dr, Cr)
natureToAccount SubcontractCost = ("仕掛品", "未払金")
natureToAccount MaterialCost    = ("仕掛品", "未払金")
...
```

この写像は決定的かつ再現可能でなければならない（[ifrs_standard.md 第7章](ifrs_standard.md) の再現性保証要件と同じ立場）。写像テーブル自体の変更履歴は Git 管理下に置き（[dev_sec_ops.md §4.3](dev_sec_ops.md) の GitOps 方針）、過去の仕訳が当時の写像で再現できることを保証する。

### 5.3 因果関係の保持（トレーサビリティ）

下流モジュールが生成する `JournalEntryRecorded`（および `BenefitLiabilityRecorded`/管理会計のアラートイベント）には、起因となった Project イベントの ID を保持するフィールドを追加する——既存 `JournalEntry` の `entryPriorRef`（訂正元参照、§2.3.5 of ifrs_standard.md に相当する仕訳間の参照）と同じ発想を、**モジュール間の因果関係**にも拡張する。

```haskell
data JournalEntry = JournalEntry
  { ...
  , entryCausationEventId :: Maybe EventId  -- 追加。Project 等、他モジュール起因の場合のみ Just
  }
```

「なぜこの仕訳が生まれたのか」を遡ると必ず単一の Project イベントに突き当たる、という§0.1 の保証は、この1フィールドが実装の核である。

---

## 6. 商品マスタ撤廃の具体的な処理（即時単発取引）

### 6.1 `SingleTransaction`

```haskell
data SingleTransactionId = SingleTransactionId UUID

data SingleTransaction = SingleTransaction
  { stxId          :: SingleTransactionId
  , stxProject     :: ProjectId            -- §6.2 のとおり自動的に開閉される Project に属する
  , stxDescription :: Text                 -- 「グッズA 3個」等、自由記述
  , stxNature      :: RevenueNature
  , stxCounterparty :: Maybe PartnerId
  , stxAmount      :: Money
  , stxDate        :: Day
  , stxTaxTreatment :: TaxTreatment        -- 消費税区分等、既存 Tax.hs の語彙を再利用
  }
```

### 6.2 ライフサイクル: 即座に開いて閉じる Project

`RecordSingleTransaction` コマンドの `decide` は、対象 Project が無い場合に**自動で `ProjectOpened`（`projectLifecycle = SingleTransaction`）を同一トランザクション内で先行発行し、`SingleTransactionRecorded` の直後に `ProjectClosed` を発行する**。運用者は「プロジェクトを開く」という操作を意識する必要はない——UI 上は「販売を記録する」という1ステップで完結し、内部的には極小のワークフロー（Project）として処理される。これが §0.2 で述べた「それらもすべて『極小のワークフロー』として一元化する」の具体的な実装である。

この設計により、商品マスタという「無尽蔵に増えるコード台帳」を持たずに、グッズ販売・ライセンス決済のいずれも長期プロジェクトと完全に同じ会計連動経路（§5）を通過する。財務会計モジュールから見れば、3年がかりのアニメ制作も1回のグッズ販売も「Project ストリームから来た事実」という点で区別がない。

---

## 7. テスト戦略

- **`decide`/`evolve` のプロパティテスト**: 既存 Journal のテスト（debit=credit 再現性）と同じ立場で、Project 予算消化額が「確定済み発注の合計」と常に一致すること（Phase 予算合計 <= Project 予算）をプロパティとして検証する。
- **Account Mapping の決定性テスト**: 同じ `ExternalOrderPlaced` イベント列を2回処理しても同一の `JournalEntryRecorded` が生成されること（[cqrs.md §9](cqrs.md) の冪等性テストと同型）。
- **因果関係チェーンの再現テスト**: 任意の `JournalEntryRecorded`（`entryCausationEventId` が `Just` のもの）から遡って元の `ExternalOrderPlaced` に到達できることを検証する。
- **`SingleTransaction` の暗黙 Project 開閉テスト**: `RecordSingleTransaction` 1コマンドが `ProjectOpened`→`SingleTransactionRecorded`→`ProjectClosed` の3イベントを正しい順序で生成すること。

---

## 8. 残課題

- **発注承認ワークフロー**: 一定額以上の発注に承認を要求する決裁フローは本書では未設計。`JournalEntry` の承認とは別建てにするか共通化するかを別途検討する。
- **`ExpenseNature`/`RevenueNature` の拡張運用**: `Other Text` が頻発するパターンが実機運用で見えてきた場合、列挙子を追加するガバナンス（誰が・どの頻度で見直すか）を定める。
- **進行基準売上（`LongTermContractRevenue`）の測定方法**: [ifrs_standard.md §4.3](ifrs_standard.md)（IFRS15）の進行度測定（インプット法/アウトプット法）と Project の Phase 進捗をどう対応づけるかは、財務会計モジュール側の拡張として別途設計する（本書は Project 側のイベント発行までを範囲とする）。
- **Shell.Subscribers の障害時挙動**: LISTEN/NOTIFY を介したプロセスマネージャが一時停止した場合のリプレイ（チェックポイント方式、[cqrs.md §3.2](cqrs.md) と同型）を明文化する。
- **発注キャンセル後の損失計上**: `CancelExternalOrder` 自体は Project 側で完結するが、すでに財務会計側で仕訳化されていた場合の取消処理（[ifrs_standard.md] の「反対」仕訳）との連動を別途定める。
