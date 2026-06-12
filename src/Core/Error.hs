module Core.Error
  ( DomainError (..)
  ) where

import Data.Text (Text)

import Core.Domain.AccountCode (AccountCode)
import Core.Domain.AccountingPeriod (AccountingPeriodId)
import Core.Domain.CashTransaction (CashTransactionId)
import Core.Domain.Ecl (EclMeasurementId)
import Core.Domain.FixedAsset (ComponentId, FixedAssetId)
import Core.Domain.FxRate (FxRateId)
import Core.Domain.Journal (JournalActionType, JournalEntryId)
import Core.Domain.JudgmentLog (JudgmentLogId)
import Core.Domain.Money (Money)
import Core.Domain.OrgPermission (PermScope)
import Core.Domain.Organisation (OrganisationId)
import Core.Domain.Reconciliation (ReconciliationId)

data DomainError
  = -- | 借貸不一致 (§4.1)
    UnbalancedEntry Money Money
  | -- | 訂正仕訳に先行仕訳参照IDがない (§4.1, §4.4)
    CorrectionMissingPriorRef JournalActionType
  | -- | 証憑未着なのに摘要が空 (§4.1)
    PendingVoucherMissingMemo
  | -- | 同一IDの仕訳が既に登録済み
    DuplicateEntryId JournalEntryId
  | -- | 入力部門が存在しない
    OrgNotFound OrganisationId
  | -- | 入力部門が対象スコープの権限を持たない
    OrgPermissionDenied OrganisationId PermScope
  | -- | 権限付与対象のスコープが既に付与済み
    PermissionAlreadyGranted OrganisationId PermScope
  | -- | 権限剥奪対象のスコープが存在しない
    PermissionNotFound OrganisationId PermScope
  | -- | マスタコードが既に存在する
    DuplicateMasterCode Text Text
  | -- | マスタコードが存在しない（更新時）
    MasterNotFound Text Text
  | -- | 必須フィールドが空
    EmptyMasterField Text
  | -- | RequiresSettlement 科目の行に取引先が指定されていない
    SettlementAccountMissingPartner AccountCode
  | -- | 締切済み会計期間への起票
    PeriodClosed AccountingPeriodId
  | -- | 同一IDの入出金明細が既に登録済み
    DuplicateCashTransactionId CashTransactionId
  | -- | 同一IDの消込が既に登録済み
    DuplicateReconciliationId ReconciliationId
  | -- | 消込対象の入出金明細が存在しない
    CashTransactionNotFound CashTransactionId
  | -- | 消込対象の OpenItem が存在しない
    OpenItemNotFound JournalEntryId AccountCode
  | -- | 消込金額が OpenItem 残高を超過
    ReconciliationExceedsOpenBalance AccountCode Money Money -- 科目, 残高, 要求額
  | -- | 消込の合計金額が入出金明細の金額と一致しない
    ReconciliationAmountMismatch Money Money -- ctAmount, 消込合計
  | -- | 消込が存在しない（取消時）
    ReconciliationNotFound ReconciliationId
  | -- | 消込が既に取消済み
    ReconciliationAlreadyReversed ReconciliationId
  | -- | 期間が存在しない
    PeriodNotFound AccountingPeriodId
  | -- | 期間が既に締切済み
    PeriodAlreadyClosed AccountingPeriodId
  | -- | 期間が既にオープン（重複登録）
    DuplicatePeriod AccountingPeriodId
  | -- § 固定資産エラー (§2.4) ──────────────────────────────────────

    -- | 同一（資産ID, コンポーネントID）が既に登録済み
    DuplicateFixedAsset FixedAssetId ComponentId
  | -- | 固定資産が存在しない
    FixedAssetNotFound FixedAssetId ComponentId
  | -- | 既に除却済みの資産への操作
    FixedAssetAlreadyDisposed FixedAssetId ComponentId
  | -- | 償却額が残余帳簿価額（帳簿価額 - 残存価額）を超過する
    DepreciationExceedsCarryingAmount FixedAssetId ComponentId Money Money
  | -- | 減損損失額が帳簿価額を超過する
    ImpairmentExceedsCarryingAmount FixedAssetId ComponentId Money Money
  | -- | 減損戻入額が過去の累計減損損失を超過する
    ImpairmentReversalExceedsCumulative FixedAssetId ComponentId Money Money
  | -- | 再評価モデル未採用の資産への再評価操作
    RevaluationNotAllowedForCostModel FixedAssetId ComponentId
  | {- | ECL エラー (§4.7.5) ────────────────────────────────────────
    | 同一IDのECL測定記録が既に存在する
    -}
    DuplicateEclMeasurement EclMeasurementId
  | -- | ECL額が負値
    NegativeEclAmount EclMeasurementId Money
  | {- | 為替レートエラー (§4.7.13) ──────────────────────────────────
    | 同一IDの為替レートが既に存在する
    -}
    DuplicateFxRate FxRateId
  | -- | 為替レートが正値でない
    NonPositiveFxRate FxRateId
  | -- | 通貨コードが3文字でない
    InvalidCurrencyCode Text
  | {- | 判断ログエラー (§5) ──────────────────────────────────────────
    | 同一IDの判断ログが既に存在する
    -}
    DuplicateJudgmentLog JudgmentLogId
  | -- | 判断ログの必須フィールドが空
    JudgmentLogEmptyField Text
  deriving (Eq, Show)
