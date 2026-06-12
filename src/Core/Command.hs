module Core.Command
  ( Command (..)
  ) where

import Data.Time (Day)

import Core.Domain.AccountMaster (AccountMaster)
import Core.Domain.AccountingPeriod (AccountingPeriodId)
import Core.Domain.CashTransaction (CashTransaction)
import Core.Domain.Ecl (EclMeasurement)
import Core.Domain.EmployeeBenefit (BenefitLiability)
import Core.Domain.FixedAsset (ComponentId, FixedAsset, FixedAssetId)
import Core.Domain.FxRate (FxRate)
import Core.Domain.Journal (JournalEntry)
import Core.Domain.JudgmentLog (JudgmentLog)
import Core.Domain.Money (Money)
import Core.Domain.OrgPermission (PermScope)
import Core.Domain.Organisation (Organisation, OrganisationId)
import Core.Domain.Partner (Partner)
import Core.Domain.Reconciliation (Reconciliation, ReconciliationId)
import Core.Domain.SubAccount (SubAccount)
import Core.Domain.Tax (TaxEntry)

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
  deriving (Eq, Show)
