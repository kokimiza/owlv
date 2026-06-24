# 管理会計 基本設計書

## 0. この文書の位置づけ

本書は [project_management.md](project_management.md) §0.1 で定めた4機能領域のうち、**管理会計**の基本設計を定める。管理会計モジュールは Project ストリームおよび財務会計ストリームの**純粋な購読者**であり、自らの判断で新たな会計事実（仕訳・契約条件等）を生成することはない——管理会計が生成するのは「現状の解釈（KPI・進捗率）」と「閾値超過の通知（アラート）」のみであり、これらは [ifrs_standard.md](ifrs_standard.md) が規定する確定決算の数字に一切影響を与えない。

### 0.1 既存 `Materiality.hs` との違い

`src/Core/Domain/Materiality.hs` は財務報告における重要性基準（[ifrs_standard.md §3.1](ifrs_standard.md)）であり、**外部開示・監査対応の文脈**で「どの誤りが看過できないか」を定める。

管理会計モジュールが扱う閾値（予算消化率85%でアラート、等）は、**内部の経営判断・現場マネジメントの文脈**であり、外部報告とは無関係である。両者の閾値は独立に設定され、片方の変更が他方に影響しない。本書で新設する `KpiThreshold`（§2.2）は `Materiality` を参照しないし、`Materiality` も `KpiThreshold` を参照しない——目的の異なる2つの「閾値」概念を1つの型に統合しない（[CLAUDE.md](../CLAUDE.md) の責務分離原則）。

### 0.2 「予算消化率85%でアラート」の実装上の位置づけ

ユーザー提示例の `[ 4. 管理会計 ] 第1話の予算消化率を85%に更新（アラート判定）` は、次の2段に分解される。

1. **集計**: `ExternalOrderPlaced`/`ExternalOrderDeliveryConfirmed`（[project_management.md §2.2](project_management.md)）を購読し、Phase 単位の消化額を再計算する。これは読み取り専用の射影であり、[cqrs.md §3](cqrs.md) の `owlv-projector` と同じ性質を持つ（新たなイベントを生成しない）。
2. **判定・通知**: 消化率が `KpiThreshold` を超えた場合のみ、`BudgetThresholdBreached` イベントを発行する（§2 のとおりこれは唯一、管理会計モジュールが Event Store に書き込むイベント種別である——アラートが発生した事実そのものは追跡可能性のために永続化する）。

---

## 1. ドメインモデル

### 1.1 `ProjectCostSummary`（読み取り専用の集計、CQRS リードモデル）

```haskell
-- これは Core の集約ではない。owlv-projector が構築する SQLite ビュー
-- (cqrs.md §5 の view_account_balance と同列)
data ProjectCostSummaryRow = ProjectCostSummaryRow
  { pcsProject        :: ProjectId
  , pcsPhase          :: Maybe ProjectPhaseId
  , pcsBudget         :: Money
  , pcsCommitted      :: Money   -- Ordered だが未確定 (orderUnitPrice * orderQuantity の合計)
  , pcsIncurred        :: Money   -- ConfirmDelivery 済み（確定費用）
  , pcsConsumptionRate :: Rational -- (pcsCommitted + pcsIncurred) / pcsBudget
  }
```

このビューは [cqrs.md §5](cqrs.md) の SQLite 物理設計に新規テーブル `view_project_cost_summary` として追加する。Project の予算超過リスクを「未確定の発注も含めて」早期に見せる必要があるため、確定額（`pcsIncurred`）だけでなく約定額（`pcsCommitted`）も並べて持つ。

### 1.2 `KpiThreshold`（Core の集約。閾値の設定自体は事実として記録する）

```haskell
data KpiThresholdId = KpiThresholdId UUID

data KpiMetric
  = BudgetConsumptionRate   -- §0.2 の例
  | ScheduleVariance        -- 予定工程に対する遅延率
  | GrossMarginRate         -- Project 単位の粗利率（確定売上 - 確定費用）

data KpiThreshold = KpiThreshold
  { ktId        :: KpiThresholdId
  , ktTenant    :: TenantId
  , ktMetric    :: KpiMetric
  , ktScope     :: KpiScope        -- ProjectScope ProjectId | PhaseScope ProjectPhaseId | TenantDefault
  , ktWarnAt    :: Rational        -- 例: 0.85
  , ktCriticalAt :: Maybe Rational -- 例: 1.00（予算超過そのもの）
  , ktEffectiveFrom :: Day
  }
```

`KpiThreshold` は人間が設定する Core の事実であり、`decide`/`evolve` を経て Event Store に記録する（§2）。**閾値の設定自体を不変条件のあるコマンドにする**ことで、「いつ・誰が・どの基準でアラートを設定したか」を [ifrs_standard.md 第5章](ifrs_standard.md) の判断ログ統制と同じ思想で追跡可能にする。

### 1.3 `BudgetAlert`（発行されたアラートの記録）

```haskell
data BudgetAlertId = BudgetAlertId UUID

data AlertSeverity = Warning | Critical

data BudgetAlert = BudgetAlert
  { baId        :: BudgetAlertId
  , baThreshold :: KpiThresholdId
  , baProject   :: ProjectId
  , baPhase     :: Maybe ProjectPhaseId
  , baMetricValue :: Rational     -- 判定時点の実測値（例: 0.87）
  , baSeverity   :: AlertSeverity
  , baDetectedAt :: UTCTime
  , baCausationEventId :: EventId -- [project_management.md §5.3](project_management.md) と同じ因果保持
  }
```

---

## 2. コマンド・イベントカタログ

| コマンド | 発行者 | 説明 |
|---|---|---|
| `SetKpiThreshold` | 人間（Admin/Maintainer） | |
| `RetireKpiThreshold` | 人間 | 閾値の無効化（削除ではなく、新規イベントで上書きする——§1.5 of project_management.md と同じ履歴性の原則） |

| イベント | 説明 |
|---|---|
| `KpiThresholdSet KpiThreshold` | |
| `KpiThresholdRetired KpiThresholdId` | |
| `BudgetThresholdBreached BudgetAlert` | システム発行（§2.1 のプロセスマネージャ機構）。**管理会計モジュールが Event Store に書き込む唯一のイベント** |

`State.hs` には `kpiThresholdIndex :: Map KpiThresholdId KpiThreshold` のみを追加する。`ProjectCostSummaryRow`（§1.1）は Core 集約ではなく CQRS リードモデルの一部であるため、`evolve` の対象にはしない——[cqrs.md §6](cqrs.md) が定める「一貫性モデルと読み取りパスの使い分け」にそのまま従う。

### 2.1 アラート判定の実行機構

[project_management.md §5.1](project_management.md) と同じ Shell 層のプロセスマネージャ（`Shell.Subscribers.ProjectBudgetWatcher`）が、`ExternalOrderPlaced`/`ExternalOrderDeliveryConfirmed`（Project ストリーム）と `KpiThresholdSet`（管理会計ストリーム自身）の両方を購読し、消化率を再計算するたびに有効な `KpiThreshold` と比較する。閾値を超えた場合のみ `BudgetThresholdBreached` を発行し、既に同一閾値で `Warning` 済みの場合は再度の `Warning` を重複発行しない（連続アラートのノイズ抑制。具体的な再発行条件——同日内は1回のみ等——は §5 残課題で運用パラメータ化する）。

---

## 3. Project / 財務会計ストリームとの関係

```
[ Project ストリーム ]                [ 財務会計ストリーム ]
  ExternalOrderPlaced                    JournalEntryRecorded
  ExternalOrderDeliveryConfirmed                │
        │                                        │
        └──────────────┬─────────────────────────┘
                        ▼
        [ Shell.Subscribers.ProjectBudgetWatcher ]
                        │
                        ├─► view_project_cost_summary (CQRS リードモデル更新、§1.1)
                        └─► BudgetThresholdBreached (閾値超過時のみ Event Store へ追記)
```

管理会計は**両方**のストリームを参照してよい——Project 側の未確定額（約定段階）と財務会計側の確定額（仕訳済み）を両方見せることが、経営判断の速報性（[ifrs_standard.md](ifrs_standard.md) の確定決算より早いタイミングでの可視化）という管理会計の目的そのものだからである。これは [project_management.md §0.1](project_management.md) が「現場のスピード感」と呼ぶものを、会計確定を待たずに数値化する役割を担う。

---

## 4. 配信（UI）

既存 TUI（[dev_sec_ops.md §1.4](dev_sec_ops.md) の Brick 採用方針）の画面構成に、Project 単位のダッシュボード（予算消化率・進捗・直近アラート一覧）を追加する。表示はあくまで CQRS リードモデル（§1.1, §1.3）からの読み取りに限定し、管理会計の画面から Project/財務会計の確定値を書き換える操作は提供しない（読み取り専用、[audit_engine.md §2.2](audit_engine.md) の fohlen UI と同じ「分析者は書き戻さない」原則をここでも踏襲する）。

---

## 5. テスト戦略

- **消化率算定のプロパティテスト**: `pcsConsumptionRate = (pcsCommitted + pcsIncurred) / pcsBudget` が常に成立し、`ExternalOrderCancelled` 後は対応する `pcsCommitted` が正しく減算されること。
- **アラート重複抑制のテスト**: 同一閾値・同一 Project に対して短時間に複数回しきい値超過が観測されても、`BudgetThresholdBreached` が運用パラメータで定めた頻度を超えて発行されないこと。
- **因果保持テスト**: 任意の `BudgetThresholdBreached` の `baCausationEventId` から遡って `ExternalOrderPlaced`/`ExternalOrderDeliveryConfirmed` に到達できること（[project_management.md §7](project_management.md) と同型）。
- **閾値設定の履歴性テスト**: `KpiThresholdRetired` 後も過去の `BudgetAlert` 記録が、発生当時有効だった閾値を正しく指し続けること（閾値を後から変更しても過去のアラートの意味が変わらない）。

---

## 6. 残課題

- **重複アラート抑制の具体的な運用パラメータ**: 「同日内は1回のみ」等の具体値は実機運用後に確定する。
- **`GrossMarginRate`（粗利率）の確定売上の扱い**: `SingleTransaction`（[project_management.md §6](project_management.md)）は即時確定するため粗利計算が容易だが、`LongRunning` Project の進行基準売上（IFRS15、[ifrs_standard.md §4.3](ifrs_standard.md)）との連動方法は [project_management.md §8](project_management.md) の残課題と合わせて別途設計する。
- **複数 Tenant をまたぐ経営指標の統合表示**: 現状は Tenant ごとに閾値・アラートが独立する前提（[tenant_isolation.md](tenant_isolation.md) の分離原則どおり）。グループ経営的な統合ビューが必要になった場合は、Tenant 境界を破らない集計方法（Tenant ごとの確定値をホスト側で後から合算する等）を別途検討する。
- **`view_project_cost_summary` のリビルド手順**: [cqrs.md §7](cqrs.md) の既存リビルド運用に本ビューを追加するだけで対応可能と見込むが、実機での再構築時間を計測した上で確定する。
