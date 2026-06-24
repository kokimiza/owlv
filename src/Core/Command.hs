module Core.Command
  ( Command (..)
  ) where

import Data.Text (Text)
import Data.Time (Day, UTCTime)

import Core.Domain.AccountMaster (AccountMaster)
import Core.Domain.AccountingPeriod (AccountingPeriodId)
import Core.Domain.CashTransaction (CashTransaction)
import Core.Domain.Ecl (EclMeasurement)
import Core.Domain.EmployeeBenefit (BenefitLiability)
import Core.Domain.ExternalOrder (ExternalOrder, ExternalOrderId, SingleTransaction)
import Core.Domain.FixedAsset (ComponentId, FixedAsset, FixedAssetId)
import Core.Domain.FxRate (FxRate)
import Core.Domain.Journal (JournalEntry)
import Core.Domain.JudgmentLog (JudgmentLog)
import Core.Domain.ManagementAccounting (BudgetAlertId, KpiThreshold, KpiThresholdId)
import Core.Domain.Money (Money)
import Core.Domain.OrgPermission (PermScope)
import Core.Domain.Organisation (Organisation, OrganisationId)
import Core.Domain.Partner (Partner, PartnerId)
import Core.Domain.Personnel (ContractTerm, Personnel, PersonnelId)
import Core.Domain.Project (Project, ProjectId, ProjectPhase, ProjectPhaseId)
import Core.Domain.Reconciliation (Reconciliation, ReconciliationId)
import Core.Domain.SubAccount (SubAccount)
import Core.Domain.Tax (TaxEntry)
import Core.Domain.Tenant (Tenant, TenantId)
import Core.Domain.User (Role, SshPubKey, UserId)
import Core.Domain.WorkAssignment (TimesheetEntry, WorkAssignmentId)

data Command
  = RecordJournalEntry JournalEntry
  | RegisterOrganisation Organisation
  | UpdateOrganisation Organisation
  | GrantOrgPermission OrganisationId PermScope
  | RevokeOrgPermission OrganisationId PermScope
  | RegisterPartner Partner
  | UpdatePartner Partner
  | RegisterAccountMaster AccountMaster
  | UpdateAccountMaster AccountMaster
  | RegisterSubAccount SubAccount
  | UpdateSubAccount SubAccount
  | -- 入出金・消込・期間
    RecordCashTransaction CashTransaction
  | CreateReconciliation Reconciliation
  | -- | 取消日（監査証跡用）
    ReverseReconciliation ReconciliationId Day
  | OpenAccountingPeriod AccountingPeriodId
  | CloseAccountingPeriod AccountingPeriodId
  | -- 固定資産台帳 (§2.4) ─────────────────────────────────────────────────
    RegisterFixedAsset FixedAsset
  | -- | 月次減価償却計上 (§4.7)
    RecordDepreciation FixedAssetId ComponentId Day Money
  | -- | 減損損失認識 (§2.4.5 / IAS 36)
    RecordImpairment
      FixedAssetId
      ComponentId
      Day
      Money
      -- | 減損損失額, 回収可能価額
      Money
  | -- | 減損戻入 (§2.4.5 / IAS 36)
    RecordImpairmentReversal FixedAssetId ComponentId Day Money
  | -- | 再評価 — 再評価モデル採用資産のみ許容 (§2.4.4)
    RevaluateAsset
      FixedAssetId
      ComponentId
      Day
      Money
      -- | 再評価後総額, 再評価差額（OCI）
      Money
  | -- | 除却（使用終了・売却）
    DisposeFixedAsset FixedAssetId ComponentId Day
  | -- 期待信用損失 (§4.7.5〜4.7.12) ─────────────────────────────────────
    RecordEclMeasurement EclMeasurement
  | -- 為替レート (§4.7.13) ─────────────────────────────────────────────
    RecordFxRate FxRate
  | -- 判断ログ (§5) ────────────────────────────────────────────────────
    RecordJudgmentLog JudgmentLog
  | -- 従業員給付 (§4.7.15 / IAS 19) ──────────────────────────────────────
    RecordBenefitLiability BenefitLiability
  | -- 法人所得税 (§4.7.16 / IAS 12) ──────────────────────────────────────
    RecordTaxEntry TaxEntry
  | -- テナント管理 (doc/tenant_isolation.md §4) ─────────────────────────────

    -- | ストリームの先頭イベントとして記録される、Tenant自身のライフサイクル開始
    CreateTenant Tenant
  | -- | actor（対象Tenantの Active Admin）, 対象TenantId
    SuspendTenant UserId TenantId
  | -- | actor（対象Tenantの Active Admin）, 対象TenantId
    ArchiveTenant UserId TenantId
  | -- ユーザー管理 (doc/user.md §2) ────────────────────────────────────

    -- | actor, 新規UserId, 表示名, 所属Tenant（ホーム）, ロール, 画面スコープ
    CreateUser UserId UserId Text TenantId Role [Text]
  | -- | actor, 対象, 新ロール（Admin への変更は ProposeRoleEscalation を要求）— ホームテナントのロールを変更する
    ChangeUserRole UserId UserId Role
  | -- | actor（既存 Active Admin）, 対象 — Admin 昇格の提案 (dual control 1/2)
    ProposeRoleEscalation UserId UserId
  | -- | actor（提案者以外の既存 Active Admin）, 対象 — 昇格の承認 (dual control 2/2)
    ApproveRoleEscalation UserId UserId
  | -- | actor（Active Admin）, 対象, 付与するTenant, ロール — ホームテナント以外への横断アクセス (doc/tenant_isolation.md §5.2)
    GrantUserTenantAccess UserId UserId TenantId Role
  | -- | actor（Active Admin）, 対象, 剥奪するTenant — ホームテナントは剥奪不可
    RevokeUserTenantAccess UserId UserId TenantId
  | GrantUserScope UserId UserId Text -- actor, 対象, 画面タグ
  | RevokeUserScope UserId UserId Text -- actor, 対象, 画面タグ
  | -- | actor（本人または Admin）, 対象, Argon2id ハッシュ済みの値
    SetUserPasswordHash UserId UserId Text
  | -- | actor（本人または Admin）, 対象, 公開鍵
    RegisterUserSshKey UserId UserId SshPubKey
  | SuspendUser UserId UserId -- actor, 対象
  | ReactivateUser UserId UserId -- actor, 対象
  | RemoveUser UserId UserId -- actor, 対象
  | -- | Shell が OS 同期成功を報告する内部コマンド（人間の actor を持たない）
    RecordUserOsSyncSucceeded UserId
  | -- | Shell が OS 同期失敗を報告する内部コマンド（理由付き）
    RecordUserOsSyncFailed UserId Text
  | -- | Shell が定期検証で検出したドリフトを報告する内部コマンド
    RecordUserOsDrift UserId Text
  | -- | Shell が SSH 確立を観測した結果を報告する内部コマンド
    RecordUserLoginObserved UserId UTCTime (Maybe Text)
  | -- プロジェクト管理 (doc/project_management.md §2) ──────────────────────
    OpenProject Project
  | AddProjectPhase ProjectPhase
  | -- | 対象Project, 新予算総額, 改定理由
    ReviseProjectBudget ProjectId Money Text
  | PlaceExternalOrder ExternalOrder
  | -- | 対象発注, 検収日, 今回確認した数量（累積ではなく増分）
    ConfirmExternalOrderDelivery ExternalOrderId Day Int
  | -- | 対象発注, 理由
    CancelExternalOrder ExternalOrderId Text
  | -- | doc/project_management.md §6: 即時単発取引。商品マスタを介さず
    -- 極小のワークフロー(Project)として自動的に開いて閉じる。
    RecordSingleTransaction SingleTransaction OrganisationId TenantId
  | CloseProject ProjectId Day
  | -- 労務人事 (doc/labor_management.md §3) ────────────────────────────────
    RegisterPersonnel Personnel
  | RecordContractTerm ContractTerm
  | -- | 新規WorkAssignmentId, 起因ExternalOrderId, 対象Project, 対象Phase,
    -- 発注先PartnerId（Personnelの照合キー）, 割当日
    CreateWorkAssignment WorkAssignmentId ExternalOrderId ProjectId (Maybe ProjectPhaseId) PartnerId Day
  | RecordTimesheetEntry TimesheetEntry
  | CompleteWorkAssignment WorkAssignmentId Day
  | SuspendPersonnel PersonnelId
  | ReactivatePersonnel PersonnelId
  | MarkPersonnelDeparted PersonnelId
  | -- 管理会計 (doc/management_accounting.md §2) ────────────────────────────
    SetKpiThreshold KpiThreshold
  | RetireKpiThreshold KpiThresholdId
  | -- | 新規BudgetAlertId（しきい値超過時のみ使用、超過なしなら無視される）,
    -- 対象Project, 対象Phase, 評価時刻, 起因ExternalOrder（任意）
    EvaluateBudgetConsumption BudgetAlertId ProjectId (Maybe ProjectPhaseId) UTCTime (Maybe ExternalOrderId)
  deriving (Eq, Show)
