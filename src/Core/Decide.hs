module Core.Decide
  ( decide
  ) where

import Data.List.NonEmpty (toList)
import Data.Maybe (isJust, isNothing)
import Data.Time (Day)

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T

import Core.Command (Command (..))
import Core.Domain.AccountCode (AccountCode, unAccountCode)
import Core.Domain.AccountMaster (AccountMaster (..), SettlementBehavior (..))
import Core.Domain.AccountingPeriod (periodIdOf)
import Core.Domain.CashTransaction (CashTransaction (..))
import Core.Domain.Ecl (EclMeasurement (..))
import Core.Domain.EmployeeBenefit (BenefitLiability (..))
import Core.Domain.FixedAsset
  ( ComponentId (..)
  , FixedAsset (..)
  , FixedAssetId (..)
  , MeasurementModel (..)
  , carryingAmount
  )
import Core.Domain.FxRate (CurrencyCode (..), FxRate (..))
import Core.Domain.Journal
  ( JournalEntry (..)
  , JournalEntryId
  , JournalLine (..)
  , VoucherRef (..)
  , creditTotal
  , debitTotal
  , isCorrectionType
  )
import Core.Domain.JudgmentLog (JudgmentLog (..))
import Core.Domain.Money (Money, subtractMoney, zeroMoney)
import Core.Domain.OrgPermission (PermScope (..))
import Core.Domain.Organisation (Organisation (..), OrganisationId (..))
import Core.Domain.Partner (Partner (..), PartnerId (..))
import Core.Domain.Reconciliation
  ( Reconciliation (..)
  , ReconciliationItem (..)
  , reconciliationTotal
  )
import Core.Domain.SubAccount (SubAccount (..), SubAccountId (..))
import Core.Domain.Tax (TaxEntry (..))
import Core.Error (DomainError (..))
import Core.Event (Event (..))
import Core.State
  ( AppBook (..)
  , AssetBook (..)
  , CashBook (..)
  , EclBook (..)
  , FxBook (..)
  , JournalBook (..)
  , JudgmentLogBook (..)
  , MasterBook (..)
  , PeriodsBook (..)
  )

import Core.Domain.AccountingPeriod qualified as AP

decide :: AppBook -> Command -> Either DomainError [Event]
decide book (RecordJournalEntry entry) = do
  checkDuplicate (appJournals book) entry
  checkBalance entry
  checkCorrectionRef entry
  checkVoucherMemo entry
  checkOrgExists (appMasters book) (entryOrg entry)
  mapM_
    (checkOrgAccountPerm (appMasters book) (entryOrg entry) . lineAccount)
    (toList (entryLines entry))
  -- 規程§4.1: 締切済み期間への起票を禁止
  checkPeriodOpen (appPeriods book) (entryDate entry)
  -- RequiresSettlement 科目は取引先の指定が必須
  mapM_ (checkSettlementPartner (appMasters book)) (toList (entryLines entry))
  pure [JournalEntryRecorded entry]
decide book (RegisterOrganisation org) = do
  let m = masterOrgs (appMasters book)
      oid = unOrgId (orgId org)
  checkNonEmpty "組織コード" oid
  checkNonEmpty "組織名称" (orgName org)
  check (Map.member (orgId org) m) (DuplicateMasterCode "組織" oid)
  pure [OrganisationRegistered org]
decide book (UpdateOrganisation org) = do
  let m = masterOrgs (appMasters book)
      oid = unOrgId (orgId org)
  checkNonEmpty "組織名称" (orgName org)
  check (Map.notMember (orgId org) m) (MasterNotFound "組織" oid)
  pure [OrganisationUpdated org]
decide book (GrantOrgPermission oid scope) = do
  let m = masterOrgs (appMasters book)
      perms = Map.findWithDefault Set.empty oid (orgPermissions (appMasters book))
  check (Map.notMember oid m) (MasterNotFound "組織" (unOrgId oid))
  check (Set.member scope perms) (PermissionAlreadyGranted oid scope)
  pure [OrgPermissionGranted oid scope]
decide book (RevokeOrgPermission oid scope) = do
  let m = masterOrgs (appMasters book)
      perms = Map.findWithDefault Set.empty oid (orgPermissions (appMasters book))
  check (Map.notMember oid m) (MasterNotFound "組織" (unOrgId oid))
  check (Set.notMember scope perms) (PermissionNotFound oid scope)
  pure [OrgPermissionRevoked oid scope]
decide book (RegisterPartner p) = do
  let m = masterPartners (appMasters book)
      pid = unPartnerId (partnerId p)
  checkNonEmpty "取引先コード" pid
  checkNonEmpty "取引先名称" (partnerName p)
  check (Map.member (partnerId p) m) (DuplicateMasterCode "取引先" pid)
  pure [PartnerRegistered p]
decide book (UpdatePartner p) = do
  let m = masterPartners (appMasters book)
      pid = unPartnerId (partnerId p)
  checkNonEmpty "取引先名称" (partnerName p)
  check (Map.notMember (partnerId p) m) (MasterNotFound "取引先" pid)
  pure [PartnerUpdated p]
decide book (RegisterAccountMaster am) = do
  let m = masterAccounts (appMasters book)
      code = unAccountCode (amCode am)
  checkNonEmpty "勘定科目コード" code
  checkNonEmpty "勘定科目名称" (amName am)
  check (Map.member (amCode am) m) (DuplicateMasterCode "勘定科目" code)
  pure [AccountMasterRegistered am]
decide book (UpdateAccountMaster am) = do
  let m = masterAccounts (appMasters book)
      code = unAccountCode (amCode am)
  checkNonEmpty "勘定科目名称" (amName am)
  check (Map.notMember (amCode am) m) (MasterNotFound "勘定科目" code)
  pure [AccountMasterUpdated am]
decide book (RegisterSubAccount sa) = do
  let m = masterSubAccounts (appMasters book)
      sid = unSubAccountId (saId sa)
  checkNonEmpty "補助科目コード" sid
  checkNonEmpty "補助科目名称" (saName sa)
  check (Map.member (saId sa) m) (DuplicateMasterCode "補助科目" sid)
  pure [SubAccountRegistered sa]
decide book (UpdateSubAccount sa) = do
  let m = masterSubAccounts (appMasters book)
      sid = unSubAccountId (saId sa)
  checkNonEmpty "補助科目名称" (saName sa)
  check (Map.notMember (saId sa) m) (MasterNotFound "補助科目" sid)
  pure [SubAccountUpdated sa]
decide book (RecordCashTransaction ct) = do
  check
    (Map.member (ctId ct) (cashTransactions (appCash book)))
    (DuplicateCashTransactionId (ctId ct))
  checkPeriodOpen (appPeriods book) (ctDate ct)
  checkOrgExists (appMasters book) (ctOrg ct)
  pure [CashTransactionRecorded ct]
decide book (CreateReconciliation rec) = do
  let cb = appCash book
  check
    (Map.member (recId rec) (reconciliations cb))
    (DuplicateReconciliationId (recId rec))
  check
    (Map.notMember (recCashId rec) (cashTransactions cb))
    (CashTransactionNotFound (recCashId rec))
  checkPeriodOpen (appPeriods book) (recDate rec)
  checkOrgExists (appMasters book) (recOrg rec)
  mapM_ (checkReconciliationItem (openItems cb)) (toList (recItems rec))
  -- 消込合計 = 入出金金額（完全消込を要求）
  let ct = cashTransactions cb Map.! recCashId rec
      recTotal = reconciliationTotal rec
  check (recTotal /= ctAmount ct) (ReconciliationAmountMismatch (ctAmount ct) recTotal)
  pure [ReconciliationCreated rec]
decide book (ReverseReconciliation recId date) = do
  let cb = appCash book
  check
    (Map.notMember recId (reconciliations cb))
    (ReconciliationNotFound recId)
  check
    (Set.member recId (reversedRecs cb))
    (ReconciliationAlreadyReversed recId)
  checkPeriodOpen (appPeriods book) date
  pure [ReconciliationReversed recId date]
decide book (OpenAccountingPeriod apId) = do
  case Map.lookup apId (periodStatus (appPeriods book)) of
    Just AP.PeriodOpen -> Left (DuplicatePeriod apId)
    _ -> pure [AccountingPeriodOpened apId]
decide book (CloseAccountingPeriod apId) = do
  case Map.lookup apId (periodStatus (appPeriods book)) of
    Nothing -> Left (PeriodNotFound apId)
    Just AP.PeriodClosed -> Left (PeriodAlreadyClosed apId)
    Just AP.PeriodOpen -> pure [AccountingPeriodClosed apId]

-- ── 固定資産台帳 (§2.4) ─────────────────────────────────────────────────────

decide book (RegisterFixedAsset fa) = do
  let key = (faId fa, faComponent fa)
  check
    (Map.member key (fixedAssets (appAssets book)))
    (DuplicateFixedAsset (faId fa) (faComponent fa))
  checkNonEmpty "資産管理番号" (unFixedAssetId (faId fa))
  checkNonEmpty "コンポーネント番号" (unComponentId (faComponent fa))
  check (faGrossAmount fa <= zeroMoney) (EmptyMasterField "取得原価は正値必須")
  pure [FixedAssetRegistered fa]
decide book (RecordDepreciation assetId compId day amount) = do
  fa <- lookupAsset (appAssets book) assetId compId
  checkAssetActive assetId compId fa
  checkPeriodOpen (appPeriods book) day
  check (amount <= zeroMoney) (EmptyMasterField "償却額は正値必須")
  -- 規程§2.3.2: 帳簿価額は残存価額を下回ってはならない
  let ca = carryingAmount fa
      residual = faResidualValue fa
      available = if ca > residual then subtractMoney ca residual else zeroMoney
  check (amount > available) (DepreciationExceedsCarryingAmount assetId compId available amount)
  pure [DepreciationRecorded assetId compId day amount]
decide book (RecordImpairment assetId compId day lossAmount recoverable) = do
  fa <- lookupAsset (appAssets book) assetId compId
  checkAssetActive assetId compId fa
  checkPeriodOpen (appPeriods book) day
  check (lossAmount <= zeroMoney) (EmptyMasterField "減損損失額は正値必須")
  -- 規程§2.4.5: 減損損失は帳簿価額を超えることができない
  let ca = carryingAmount fa
  check (lossAmount > ca) (ImpairmentExceedsCarryingAmount assetId compId ca lossAmount)
  pure [ImpairmentRecognized assetId compId day lossAmount recoverable]
decide book (RecordImpairmentReversal assetId compId day amount) = do
  fa <- lookupAsset (appAssets book) assetId compId
  checkAssetActive assetId compId fa
  checkPeriodOpen (appPeriods book) day
  check (amount <= zeroMoney) (EmptyMasterField "戻入額は正値必須")
  -- IAS 36: 戻入は過去の累計減損損失を超えることができない
  let cumLoss = faImpairmentCumulative fa
  check (amount > cumLoss) (ImpairmentReversalExceedsCumulative assetId compId cumLoss amount)
  pure [ImpairmentReversalRecognized assetId compId day amount]
decide book (RevaluateAsset assetId compId day newGross surplus) = do
  fa <- lookupAsset (appAssets book) assetId compId
  checkAssetActive assetId compId fa
  checkPeriodOpen (appPeriods book) day
  -- 規程§2.4.3: 再評価モデル採用資産のみ許容
  check
    (faMeasurementModel fa /= RevaluationModel)
    (RevaluationNotAllowedForCostModel assetId compId)
  check (newGross <= zeroMoney) (EmptyMasterField "再評価後総額は正値必須")
  pure [AssetRevalued assetId compId day newGross surplus]
decide book (DisposeFixedAsset assetId compId day) = do
  fa <- lookupAsset (appAssets book) assetId compId
  checkAssetActive assetId compId fa
  checkPeriodOpen (appPeriods book) day
  pure [FixedAssetDisposed assetId compId day]

-- ── ECL (§4.7.5〜4.7.12) ────────────────────────────────────────────────────

decide book (RecordEclMeasurement m) = do
  check
    (Map.member (eclMeasId m) (eclMeasurements (appEcl book)))
    (DuplicateEclMeasurement (eclMeasId m))
  check (eclMeasAmount m < zeroMoney) (NegativeEclAmount (eclMeasId m) (eclMeasAmount m))
  pure [EclMeasurementRecorded m]

-- ── 為替レート (§4.7.13) ──────────────────────────────────────────────────

decide book (RecordFxRate r) = do
  check
    (Map.member (fxRateId r) (fxRates (appFx book)))
    (DuplicateFxRate (fxRateId r))
  let base = unCurrencyCode (fxBaseCurrency r)
      quote = unCurrencyCode (fxQuoteCurrency r)
  checkNonEmpty "通貨コード（換算元）" base
  checkNonEmpty "通貨コード（換算先）" quote
  -- ISO 4217 は3文字
  check (T.length base /= 3) (InvalidCurrencyCode base)
  check (T.length quote /= 3) (InvalidCurrencyCode quote)
  check (fxRate r <= 0) (NonPositiveFxRate (fxRateId r))
  pure [FxRateRecorded r]

-- ── 判断ログ (§5) ───────────────────────────────────────────────────────────

decide book (RecordJudgmentLog l) = do
  check
    (Map.member (jlId l) (judgmentLogs (appJudgmentLogs book)))
    (DuplicateJudgmentLog (jlId l))
  checkNonEmpty "会計基準引用" (jlStandardRef l)
  checkNonEmpty "算定モデル" (jlModel l)
  checkNonEmpty "承認者" (jlApprover l)
  pure [JudgmentLogRecorded l]

-- ── 従業員給付 (§4.7.15) ─────────────────────────────────────────────────

decide _book (RecordBenefitLiability b) = do
  check (blLiabilityAmount b < zeroMoney) (EmptyMasterField "給付負債額は非負必須")
  pure [BenefitLiabilityRecorded b]

-- ── 法人所得税 (§4.7.16) ─────────────────────────────────────────────────

decide _book (RecordTaxEntry t) = do
  check
    (teEstimatedEffectiveTaxRate t < 0 || teEstimatedEffectiveTaxRate t > 1)
    (EmptyMasterField "ETRは0以上1以下必須")
  pure [TaxEntryRecorded t]

-- ── helpers ────────────────────────────────────────────────────────────────

check :: Bool -> DomainError -> Either DomainError ()
check True err = Left err
check False _ = Right ()

checkDuplicate :: JournalBook -> JournalEntry -> Either DomainError ()
checkDuplicate book entry =
  check
    (Map.member (entryId entry) (journalEntries book))
    (DuplicateEntryId (entryId entry))

-- | 借貸一致検証 規程§4.1
checkBalance :: JournalEntry -> Either DomainError ()
checkBalance entry =
  let dr = debitTotal (entryLines entry)
      cr = creditTotal (entryLines entry)
  in check (dr /= cr) (UnbalancedEntry dr cr)

-- | 訂正仕訳は先行仕訳参照ID必須 規程§4.1, §4.4
checkCorrectionRef :: JournalEntry -> Either DomainError ()
checkCorrectionRef entry =
  check
    (isCorrectionType (entryActionType entry) && null (entryPriorRef entry))
    (CorrectionMissingPriorRef (entryActionType entry))

-- | 証憑未着の場合は摘要（根拠・到着予定日）が必須 規程§4.1
checkVoucherMemo :: JournalEntry -> Either DomainError ()
checkVoucherMemo entry = case entryVoucher entry of
  VoucherPending -> check (T.null (entryMemo entry)) PendingVoucherMissingMemo
  VoucherAttached _ -> Right ()

-- | 入力部門がマスタに存在するか
checkOrgExists :: MasterBook -> OrganisationId -> Either DomainError ()
checkOrgExists mb oid =
  check (Map.notMember oid (masterOrgs mb)) (OrgNotFound oid)

-- | 入力部門が当該科目の使用権限を持つか (空セット=全許可)
checkOrgAccountPerm :: MasterBook -> OrganisationId -> AccountCode -> Either DomainError ()
checkOrgAccountPerm mb oid ac =
  let perms = Map.findWithDefault Set.empty oid (orgPermissions mb)
  in if Set.null perms
       then Right ()
       else
         check
           (Set.notMember (AccountScope ac) perms)
           (OrgPermissionDenied oid (AccountScope ac))

-- | 締切済み期間への操作を禁止。期間未登録 = オープン扱い。
checkPeriodOpen :: PeriodsBook -> Day -> Either DomainError ()
checkPeriodOpen pb day =
  let apId = periodIdOf day
  in case Map.lookup apId (periodStatus pb) of
       Just AP.PeriodClosed -> Left (PeriodClosed apId)
       _ -> Right ()

-- | RequiresSettlement 科目の行は取引先の指定が必須
checkSettlementPartner :: MasterBook -> JournalLine -> Either DomainError ()
checkSettlementPartner mb line =
  case Map.lookup (lineAccount line) (masterAccounts mb) of
    Just am
      | amSettlement am == RequiresSettlement ->
          check (isNothing (linePartner line)) (SettlementAccountMissingPartner (lineAccount line))
    _ -> Right ()

-- | 消込明細1件の検証: OpenItem 存在 + 残高超過チェック
checkReconciliationItem ::
  Map.Map (JournalEntryId, AccountCode) Money ->
  ReconciliationItem ->
  Either DomainError ()
checkReconciliationItem openItemMap ri = do
  let key = (riEntryId ri, riAccount ri)
  case Map.lookup key openItemMap of
    Nothing ->
      Left (OpenItemNotFound (riEntryId ri) (riAccount ri))
    Just available ->
      check
        (riAmount ri > available)
        (ReconciliationExceedsOpenBalance (riAccount ri) available (riAmount ri))

checkNonEmpty :: T.Text -> T.Text -> Either DomainError ()
checkNonEmpty field val = check (T.null val) (EmptyMasterField field)

-- ── 固定資産ヘルパー ──────────────────────────────────────────────────────

lookupAsset :: AssetBook -> FixedAssetId -> ComponentId -> Either DomainError FixedAsset
lookupAsset ab assetId compId =
  case Map.lookup (assetId, compId) (fixedAssets ab) of
    Nothing -> Left (FixedAssetNotFound assetId compId)
    Just fa -> Right fa

checkAssetActive :: FixedAssetId -> ComponentId -> FixedAsset -> Either DomainError ()
checkAssetActive assetId compId fa =
  check (isJust (faDisposalDate fa)) (FixedAssetAlreadyDisposed assetId compId)
