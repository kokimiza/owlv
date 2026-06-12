{- | エラーメッセージカタログ。
文言テンプレートを Map に保持し、起動時に一度だけロードする。
renderDomainError / renderAppError はpureなのでテストが容易。
IO 境界はカタログロードの一点（App.hs の初期化）に限定される。
-}
module Shell.ErrorCatalog
  ( ErrorKey (..)
  , ErrorCatalog
  , defaultCatalog
  , renderDomainError
  , renderAppError
  ) where

import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.UUID (toText)

import Data.Map.Strict qualified as Map
import Data.Text qualified as T

import Core.Domain.AccountCode (unAccountCode)
import Core.Domain.AccountingPeriod (AccountingPeriodId (..))
import Core.Domain.CashTransaction (CashTransactionId (..))
import Core.Domain.Journal (JournalEntryId (..))
import Core.Domain.Money (unMoney)
import Core.Domain.OrgPermission (PermScope (..))
import Core.Domain.Organisation (OrganisationId (..))
import Core.Domain.Reconciliation (ReconciliationId (..))
import Core.Error (DomainError (..))
import Shell.AppError (AppError (..))

-- | カタログキー — DomainError コンストラクタ + Shell レベルエラーに 1 対 1 対応。
data ErrorKey
  = EKUnbalancedEntry
  | EKCorrectionMissingPriorRef
  | EKPendingVoucherMissingMemo
  | EKDuplicateEntryId
  | EKOrgNotFound
  | EKOrgPermissionDenied
  | EKPermissionAlreadyGranted
  | EKPermissionNotFound
  | EKDuplicateMasterCode
  | EKMasterNotFound
  | EKEmptyMasterField
  | EKSettlementAccountMissingPartner
  | EKPeriodClosed
  | EKDuplicateCashTransactionId
  | EKDuplicateReconciliationId
  | EKCashTransactionNotFound
  | EKOpenItemNotFound
  | EKReconciliationExceedsOpenBalance
  | EKReconciliationAmountMismatch
  | EKReconciliationNotFound
  | EKReconciliationAlreadyReversed
  | EKPeriodNotFound
  | EKPeriodAlreadyClosed
  | EKDuplicatePeriod
  | EKStorageError
  | EKConnectionError
  | EKNotFound
  | EKConcurrencyConflict
  deriving (Bounded, Enum, Eq, Ord, Show)

-- | テンプレート Map。{0}, {1} … をパラメータで置換する。
newtype ErrorCatalog = ErrorCatalog (Map ErrorKey Text)
  deriving (Eq, Show)

{- | デフォルトカタログ（日本語）。
将来は JSON/YAML ファイルからロードするか、UI 設定で差し替える。
-}
defaultCatalog :: ErrorCatalog
defaultCatalog =
  ErrorCatalog $
    Map.fromList
      [ (EKUnbalancedEntry, "借貸不一致: 借方={0} 貸方={1}")
      , (EKCorrectionMissingPriorRef, "訂正仕訳に先行仕訳参照IDがありません: {0}")
      , (EKPendingVoucherMissingMemo, "証憑未着仕訳に摘要（根拠・到着予定日）が必要です")
      , (EKDuplicateEntryId, "仕訳IDが重複しています: {0}")
      , (EKOrgNotFound, "入力部門が存在しません: {0}")
      , (EKOrgPermissionDenied, "部門 {0} は {1} の権限がありません")
      , (EKPermissionAlreadyGranted, "部門 {0} には既に {1} の権限があります")
      , (EKPermissionNotFound, "部門 {0} に {1} の権限はありません")
      , (EKDuplicateMasterCode, "{0}コードが既に登録済みです: {1}")
      , (EKMasterNotFound, "{0}が見つかりません: {1}")
      , (EKEmptyMasterField, "{0}は必須です")
      , (EKSettlementAccountMissingPartner, "決済科目 {0} には取引先の指定が必要です")
      , (EKPeriodClosed, "会計期間 {0} は既に締切済みです")
      , (EKDuplicateCashTransactionId, "入出金明細IDが重複しています: {0}")
      , (EKDuplicateReconciliationId, "消込IDが重複しています: {0}")
      , (EKCashTransactionNotFound, "入出金明細が存在しません: {0}")
      , (EKOpenItemNotFound, "未消込残高が存在しません: 仕訳={0} 科目={1}")
      , (EKReconciliationExceedsOpenBalance, "消込金額が残高を超過しています: 科目={0} 残高={1} 要求={2}")
      , (EKReconciliationAmountMismatch, "消込合計が入出金金額と不一致: 入出金={0} 消込合計={1}")
      , (EKReconciliationNotFound, "消込が存在しません: {0}")
      , (EKReconciliationAlreadyReversed, "消込は既に取消済みです: {0}")
      , (EKPeriodNotFound, "会計期間が存在しません: {0}")
      , (EKPeriodAlreadyClosed, "会計期間は既に締切済みです: {0}")
      , (EKDuplicatePeriod, "会計期間が既にオープンです: {0}")
      , (EKStorageError, "保存エラー: {0}")
      , (EKConnectionError, "接続エラー: {0}")
      , (EKNotFound, "未検出: {0}")
      , (EKConcurrencyConflict, "競合検出: リトライ上限に達しました。しばらく待ってから再操作してください。")
      ]

-- | Pure render: DomainError → Text（カタログ参照）。
renderDomainError :: ErrorCatalog -> DomainError -> Text
renderDomainError cat err =
  let (key, params) = domainErrorKey err
  in applyTemplate cat key params

{- | Pure render: AppError → Text（カタログ参照）。
AppInputError は mk* バリデータが生成する簡易文言をそのまま返す。
-}
renderAppError :: ErrorCatalog -> AppError -> Text
renderAppError cat (AppDomainError de) = renderDomainError cat de
renderAppError _ (AppInputError t) = t
renderAppError cat (AppStorageError t) = applyTemplate cat EKStorageError [t]
renderAppError cat (AppConnectionError t) = applyTemplate cat EKConnectionError [t]
renderAppError cat (AppNotFound t) = applyTemplate cat EKNotFound [t]
renderAppError cat AppConcurrencyConflict = applyTemplate cat EKConcurrencyConflict []

-- ── internals ────────────────────────────────────────────────────────────────

domainErrorKey :: DomainError -> (ErrorKey, [Text])
domainErrorKey (UnbalancedEntry dr cr) =
  (EKUnbalancedEntry, [T.pack (show (unMoney dr)), T.pack (show (unMoney cr))])
domainErrorKey (CorrectionMissingPriorRef at) =
  (EKCorrectionMissingPriorRef, [T.pack (show at)])
domainErrorKey PendingVoucherMissingMemo =
  (EKPendingVoucherMissingMemo, [])
domainErrorKey (DuplicateEntryId (JournalEntryId uuid)) =
  (EKDuplicateEntryId, [toText uuid])
domainErrorKey (OrgNotFound (OrganisationId oid)) =
  (EKOrgNotFound, [oid])
domainErrorKey (OrgPermissionDenied (OrganisationId oid) scope) =
  (EKOrgPermissionDenied, [oid, renderScope scope])
domainErrorKey (PermissionAlreadyGranted (OrganisationId oid) scope) =
  (EKPermissionAlreadyGranted, [oid, renderScope scope])
domainErrorKey (PermissionNotFound (OrganisationId oid) scope) =
  (EKPermissionNotFound, [oid, renderScope scope])
domainErrorKey (DuplicateMasterCode kind code) =
  (EKDuplicateMasterCode, [kind, code])
domainErrorKey (MasterNotFound kind code) =
  (EKMasterNotFound, [kind, code])
domainErrorKey (EmptyMasterField field) =
  (EKEmptyMasterField, [field])
domainErrorKey (SettlementAccountMissingPartner ac) =
  (EKSettlementAccountMissingPartner, [unAccountCode ac])
domainErrorKey (PeriodClosed apId) =
  (EKPeriodClosed, [renderPeriodId apId])
domainErrorKey (DuplicateCashTransactionId (CashTransactionId uuid)) =
  (EKDuplicateCashTransactionId, [toText uuid])
domainErrorKey (DuplicateReconciliationId (ReconciliationId uuid)) =
  (EKDuplicateReconciliationId, [toText uuid])
domainErrorKey (CashTransactionNotFound (CashTransactionId uuid)) =
  (EKCashTransactionNotFound, [toText uuid])
domainErrorKey (OpenItemNotFound (JournalEntryId uuid) ac) =
  (EKOpenItemNotFound, [toText uuid, unAccountCode ac])
domainErrorKey (ReconciliationExceedsOpenBalance ac avail req) =
  (EKReconciliationExceedsOpenBalance, [unAccountCode ac, showMoney avail, showMoney req])
domainErrorKey (ReconciliationAmountMismatch ctAmt recAmt) =
  (EKReconciliationAmountMismatch, [showMoney ctAmt, showMoney recAmt])
domainErrorKey (ReconciliationNotFound (ReconciliationId uuid)) =
  (EKReconciliationNotFound, [toText uuid])
domainErrorKey (ReconciliationAlreadyReversed (ReconciliationId uuid)) =
  (EKReconciliationAlreadyReversed, [toText uuid])
domainErrorKey (PeriodNotFound apId) =
  (EKPeriodNotFound, [renderPeriodId apId])
domainErrorKey (PeriodAlreadyClosed apId) =
  (EKPeriodAlreadyClosed, [renderPeriodId apId])
domainErrorKey (DuplicatePeriod apId) =
  (EKDuplicatePeriod, [renderPeriodId apId])

renderScope :: PermScope -> Text
renderScope (AccountScope ac) = "勘定科目[" <> unAccountCode ac <> "]"
renderScope (ScreenScope tag) = "画面[" <> tag <> "]"

renderPeriodId :: AccountingPeriodId -> Text
renderPeriodId apId =
  T.pack (show (apYear apId)) <> "年" <> T.pack (show (apMonth apId)) <> "月"

showMoney :: (Show a) => a -> Text
showMoney = T.pack . show

applyTemplate :: ErrorCatalog -> ErrorKey -> [Text] -> Text
applyTemplate (ErrorCatalog m) k ps =
  substitute (Map.findWithDefault (T.pack (show k)) k m) ps

-- | {0}, {1} … をパラメータで置換する。
substitute :: Text -> [Text] -> Text
substitute t ps = foldl' replaceOne t (zip [0 :: Int ..] ps)
 where
  replaceOne acc (i, v) = T.replace ("{" <> T.pack (show i) <> "}") v acc
