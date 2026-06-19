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
import Core.Domain.User (Role, SshPubKey, UserId)

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
  | -- ユーザー管理 (.claude/user.md §2) ────────────────────────────────────

    -- | actor, 新規UserId, 表示名, ロール, 画面スコープ
    CreateUser UserId UserId Text Role [Text]
  | -- | actor, 対象, 新ロール（Admin への変更は ProposeRoleEscalation を要求）
    ChangeUserRole UserId UserId Role
  | -- | actor（既存 Active Admin）, 対象 — Admin 昇格の提案 (dual control 1/2)
    ProposeRoleEscalation UserId UserId
  | -- | actor（提案者以外の既存 Active Admin）, 対象 — 昇格の承認 (dual control 2/2)
    ApproveRoleEscalation UserId UserId
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
  deriving (Eq, Show)
