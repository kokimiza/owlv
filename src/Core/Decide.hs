module Core.Decide
  ( decide
  ) where

import Data.List (foldl')
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
import Core.Domain.ExternalOrder (ExternalOrder (..), ExternalOrderId, OrderStatus (..), SingleTransaction (..))
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
import Core.Domain.ManagementAccounting
  ( AlertSeverity (..)
  , BudgetAlert (..)
  , KpiMetric (..)
  , KpiScope (..)
  , KpiThreshold (..)
  , KpiThresholdId
  )
import Core.Domain.Money (Money, addMoney, mkMoney, subtractMoney, unMoney, zeroMoney)
import Core.Domain.OrgPermission (PermScope (..))
import Core.Domain.Organisation (Organisation (..), OrganisationId (..))
import Core.Domain.Partner (Partner (..), PartnerId (..))
import Core.Domain.Personnel (ContractTerm (..), Personnel (..), PersonnelId, PersonnelStatus (..))
import Core.Domain.Project (Project (..), ProjectId, ProjectLifecycle (..), ProjectPhase (..), ProjectPhaseId, ProjectStatus (..))
import Core.Domain.Reconciliation
  ( Reconciliation (..)
  , ReconciliationItem (..)
  , reconciliationTotal
  )
import Core.Domain.SubAccount (SubAccount (..), SubAccountId (..))
import Core.Domain.Tax (TaxEntry (..))
import Core.Domain.Tenant (Tenant (..), TenantStatus (..))
import Core.Domain.User
  ( Role (..)
  , SshPubKey (..)
  , User (..)
  , UserId (..)
  , UserStatus (..)
  , isActiveAdmin
  , mkSshPubKey
  , mkUserId
  )
import Core.Domain.WorkAssignment (TimesheetEntry (..), WorkAssignment (..), WorkAssignmentId, WorkAssignmentStatus (..))
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
  , LaborBook (..)
  , ManagementAccountingBook (..)
  , MasterBook (..)
  , PeriodsBook (..)
  , ProjectAggregate (..)
  , ProjectBook (..)
  , UserBook (..)
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

-- ── テナント管理 (doc/tenant_isolation.md §4) ────────────────────────────────

decide book (CreateTenant tenant) = do
  check (isJust (appTenant book)) TenantAlreadyInitialized
  checkNonEmpty "テナント名" (tenantName tenant)
  pure [TenantCreated tenant]
decide book (SuspendTenant actor tid) = do
  t <- lookupCurrentTenant book
  checkActorIsActiveAdmin (appUsers book) actor
  check (tenantId t /= tid) (TenantIdMismatch (tenantId t) tid)
  check (tenantStatus t == TenantStatusSuspended) (TenantAlreadySuspended tid)
  check (tenantStatus t == TenantStatusArchived) (TenantAlreadyArchived tid)
  pure [TenantSuspended tid]
decide book (ArchiveTenant actor tid) = do
  t <- lookupCurrentTenant book
  checkActorIsActiveAdmin (appUsers book) actor
  check (tenantId t /= tid) (TenantIdMismatch (tenantId t) tid)
  check (tenantStatus t == TenantStatusArchived) (TenantAlreadyArchived tid)
  pure [TenantArchived tid]
-- ── ユーザー管理 (doc/user.md §2) ───────────────────────────────────────

decide book (CreateUser actor target name homeTenant role scopes) = do
  let ub = appUsers book
  checkValid (mkUserId (unUserId target)) InvalidUserId
  check (Map.member target (users ub)) (DuplicateUserId target)
  -- ブートストラップ例外: Active な Admin が1人もいなければ actor 検証を免除する
  -- (doc/user.md §7: 実際に発火するのを root_admin_username だけに絞るのは Shell の責務)
  if activeAdminCount ub == 0
    then pure [UserCreated target (ubNextUid ub) name homeTenant role scopes]
    else do
      checkActorIsActiveAdmin ub actor
      pure [UserCreated target (ubNextUid ub) name homeTenant role scopes]
decide book (ChangeUserRole actor target newRole) = do
  let ub = appUsers book
  checkActorIsActiveAdmin ub actor
  _ <- lookupLiveUser ub target
  check (newRole == Admin) (DirectAdminEscalationForbidden target)
  pure [UserRoleChanged target newRole]
decide book (GrantUserTenantAccess actor target tid role) = do
  let ub = appUsers book
  checkActorIsActiveAdmin ub actor
  u <- lookupLiveUser ub target
  check (Map.member tid (userTenantRoles u)) (UserTenantAccessAlreadyGranted target tid)
  check (role == Admin) (DirectAdminEscalationForbidden target)
  pure [UserTenantAccessGranted target tid role]
decide book (RevokeUserTenantAccess actor target tid) = do
  let ub = appUsers book
  checkActorIsActiveAdmin ub actor
  u <- lookupLiveUser ub target
  check (tid == userHomeTenant u) (CannotRevokeHomeTenantAccess target tid)
  check (not (Map.member tid (userTenantRoles u))) (UserTenantAccessNotFound target tid)
  pure [UserTenantAccessRevoked target tid]
decide book (ProposeRoleEscalation actor target) = do
  let ub = appUsers book
  checkActorIsActiveAdmin ub actor
  _ <- lookupLiveUser ub target
  pure [UserRoleEscalationProposed actor target]
decide book (ApproveRoleEscalation actor target) = do
  let ub = appUsers book
  checkActorIsActiveAdmin ub actor
  _ <- lookupLiveUser ub target
  case Map.lookup target (ubPendingEscalations ub) of
    Nothing -> Left (NoPendingRoleEscalation target)
    Just proposer -> do
      check (proposer == actor) (SelfApprovalNotAllowed target)
      pure [UserRoleChanged target Admin]
decide book (GrantUserScope actor target scope) = do
  let ub = appUsers book
  checkActorIsActiveAdmin ub actor
  u <- lookupLiveUser ub target
  check (scope `elem` userScreenScopes u) (UserScopeAlreadyGranted target scope)
  pure [UserScopeGranted target scope]
decide book (RevokeUserScope actor target scope) = do
  let ub = appUsers book
  checkActorIsActiveAdmin ub actor
  u <- lookupLiveUser ub target
  check (scope `notElem` userScreenScopes u) (UserScopeNotFound target scope)
  pure [UserScopeRevoked target scope]
decide book (SetUserPasswordHash actor target hash) = do
  let ub = appUsers book
  _ <- lookupLiveUser ub target
  checkSelfOrAdmin ub actor target
  checkNonEmpty "パスワードハッシュ" hash
  pure [UserPasswordChanged target hash]
decide book (RegisterUserSshKey actor target key) = do
  let ub = appUsers book
  _ <- lookupLiveUser ub target
  checkSelfOrAdmin ub actor target
  checkValid (mkSshPubKey (unSshPubKey key)) InvalidSshPubKey
  -- 鍵共有禁止: 他ユーザーへの登録済みなら拒否。同一ユーザーへの再登録は evolve 側で冪等に吸収する。
  let othersKeys = concatMap userSshPubKeys (Map.elems (Map.delete target (users ub)))
  check (key `elem` othersKeys) (DuplicateSshPubKey (unSshPubKey key))
  pure [UserSshKeyRegistered target key]
decide book (SuspendUser actor target) = do
  let ub = appUsers book
  checkActorIsActiveAdmin ub actor
  _ <- lookupLiveUser ub target
  pure [UserSuspended target]
decide book (ReactivateUser actor target) = do
  let ub = appUsers book
  checkActorIsActiveAdmin ub actor
  _ <- lookupLiveUser ub target
  pure [UserReactivated target]
decide book (RemoveUser actor target) = do
  let ub = appUsers book
  checkActorIsActiveAdmin ub actor
  _ <- lookupLiveUser ub target
  pure [UserRemoved target]
-- Shell が報告する内部コマンド群: 人間の actor を持たない。実 OS 操作の事後確認の結果のみ反映する。
decide book (RecordUserOsSyncSucceeded target) = do
  _ <- lookupLiveUser (appUsers book) target
  pure [UserOsSyncSucceeded target]
decide book (RecordUserOsSyncFailed target reason) = do
  _ <- lookupLiveUser (appUsers book) target
  pure [UserOsSyncFailed target reason]
decide book (RecordUserOsDrift target detail) = do
  _ <- lookupLiveUser (appUsers book) target
  pure [UserOsDriftDetected target detail]
decide book (RecordUserLoginObserved target at srcIp) = do
  _ <- lookupLiveUser (appUsers book) target
  pure [UserLoginObserved target at srcIp]

-- ── プロジェクト管理 (doc/project_management.md §2) ──────────────────────────

decide book (OpenProject p) = do
  let pb = appProjects book
  check (Map.member (projectId p) (projects pb)) (DuplicateProjectId (projectId p))
  checkNonEmpty "プロジェクト名称" (projectName p)
  checkOrgExists (appMasters book) (projectOrg p)
  check (projectBudgetTotal p < zeroMoney) (EmptyMasterField "予算総額は非負必須")
  pure [ProjectOpened p]
decide book (AddProjectPhase phase) = do
  pa <- lookupProject (appProjects book) (phaseProject phase)
  check (Map.member (phaseId phase) (paPhases pa)) (DuplicateProjectPhaseId (phaseId phase))
  checkNonEmpty "工程名称" (phaseName phase)
  check (phaseBudget phase < zeroMoney) (EmptyMasterField "工程予算は非負必須")
  let projectTotal = projectBudgetTotal (paProject pa)
      newPhaseTotal = addMoney (sumPhaseBudgets pa) (phaseBudget phase)
  check
    (newPhaseTotal > projectTotal)
    (PhaseBudgetExceedsProjectBudget (phaseProject phase) projectTotal newPhaseTotal)
  pure [ProjectPhaseAdded phase]
decide book (ReviseProjectBudget pid newTotal reason) = do
  pa <- lookupProject (appProjects book) pid
  checkNonEmpty "予算改定理由" reason
  check (newTotal < zeroMoney) (EmptyMasterField "予算総額は非負必須")
  let phaseTotal = sumPhaseBudgets pa
  check (newTotal < phaseTotal) (ProjectBudgetBelowPhaseCommitments pid newTotal phaseTotal)
  pure [ProjectBudgetRevised pid newTotal reason]
decide book (PlaceExternalOrder o) = do
  pa <- lookupProject (appProjects book) (orderProject o)
  check (Map.member (orderId o) (paOrders pa)) (DuplicateExternalOrderId (orderId o))
  checkProjectOpenForOrders (orderProject o) (paProject pa)
  case orderPhase o of
    Nothing -> pure ()
    Just phid -> check (Map.notMember phid (paPhases pa)) (ProjectPhaseNotFound phid)
  check (orderQuantity o <= 0) (EmptyMasterField "発注数量は正値必須")
  check (orderUnitPrice o < zeroMoney) (EmptyMasterField "発注単価は非負必須")
  pure [ExternalOrderPlaced o]
decide book (ConfirmExternalOrderDelivery oid day qty) = do
  (_, o) <- lookupOrder (appProjects book) oid
  checkOrderModifiable oid (orderStatus o)
  check (qty <= 0) (EmptyMasterField "検収数量は正値必須")
  let newDelivered = orderDeliveredQuantity o + qty
  check
    (newDelivered > orderQuantity o)
    (DeliveredQuantityExceedsOrder oid (orderQuantity o) newDelivered)
  pure [ExternalOrderDeliveryConfirmed oid day qty]
decide book (CancelExternalOrder oid reason) = do
  (_, o) <- lookupOrder (appProjects book) oid
  checkOrderModifiable oid (orderStatus o)
  checkNonEmpty "キャンセル理由" reason
  pure [ExternalOrderCancelled oid reason]
decide book (RecordSingleTransaction stx org tenant) = do
  let pb = appProjects book
  check
    (Map.member (stxProject stx) (projects pb))
    (DuplicateSingleTransactionProject (stxProject stx))
  checkNonEmpty "取引内容" (stxDescription stx)
  check (stxAmount stx < zeroMoney) (EmptyMasterField "取引金額は非負必須")
  checkOrgExists (appMasters book) org
  let shadowProject =
        Project
          { projectId = stxProject stx
          , projectTenant = tenant
          , projectOrg = org
          , projectName = stxDescription stx
          , projectLifecycle = ProjectLifecycleSingleTransaction
          , projectStatus = ProjectStatusOpen
          , projectCustomer = stxCounterparty stx
          , projectBudgetTotal = zeroMoney
          , projectOpenedDate = stxDate stx
          , projectExpectedEndDate = Nothing
          }
  -- doc/project_management.md §6.2: 即時単発取引は商品マスタを介さず
  -- 極小のワークフロー (Project) として自動的に開いて閉じる。
  pure
    [ ProjectOpened shadowProject
    , SingleTransactionRecorded stx
    , ProjectClosed (stxProject stx) (stxDate stx)
    ]
decide book (CloseProject pid day) = do
  pa <- lookupProject (appProjects book) pid
  checkProjectNotAlreadyClosed pid (paProject pa)
  pure [ProjectClosed pid day]
-- ── 労務人事 (doc/labor_management.md §3) ────────────────────────────────────

decide book (RegisterPersonnel p) = do
  let lb = appLabor book
  check (Map.member (personnelId p) (personnelRecords lb)) (DuplicatePersonnelId (personnelId p))
  checkNonEmpty "人材名称" (personnelName p)
  pure [PersonnelRegistered p]
decide book (RecordContractTerm ct) = do
  let lb = appLabor book
  _ <- lookupPersonnel lb (ctPersonnel ct)
  check (Map.member (ctId ct) (contractTerms lb)) (DuplicateContractTermId (ctId ct))
  pure [ContractTermRecorded ct]
decide book (CreateWorkAssignment waid oid pid mPhase vendorPid day) = do
  let lb = appLabor book
  check (Map.member waid (workAssignments lb)) (DuplicateWorkAssignmentId waid)
  -- doc/labor_management.md §2.1: 照合に失敗しても DomainError ではなく
  -- PersonnelReconciliationFailed イベントを返す——「現場が止まらない」ことを
  -- 構造的に保証する（事実は握り潰さない）。
  case findActivePersonnelForVendor lb vendorPid day of
    Just pid' ->
      pure
        [ WorkAssignmentCreated
            WorkAssignment
              { waId = waid
              , waPersonnel = pid'
              , waProject = pid
              , waPhase = mPhase
              , waExternalOrder = Just oid
              , waAssignedDate = day
              , waStatus = WorkAssignmentStatusAssigned
              }
        ]
    Nothing ->
      pure
        [ PersonnelReconciliationFailed
            oid
            "対応する稼働中のPersonnel、または有効な契約条件が見つかりません"
        ]
decide book (RecordTimesheetEntry e) = do
  let lb = appLabor book
  _ <- lookupWorkAssignment lb (tsAssignment e)
  check (Map.member (tsId e) (timesheetEntries lb)) (DuplicateTimesheetEntryId (tsId e))
  pure [TimesheetEntryRecorded e]
decide book (CompleteWorkAssignment waid day) = do
  wa <- lookupWorkAssignment (appLabor book) waid
  checkWorkAssignmentModifiable waid (waStatus wa)
  pure [WorkAssignmentCompleted waid day]
decide book (SuspendPersonnel pid) = do
  p <- lookupPersonnel (appLabor book) pid
  check (personnelStatus p == PersonnelStatusDeparted) (PersonnelAlreadyDeparted pid)
  pure [PersonnelSuspended pid]
decide book (ReactivatePersonnel pid) = do
  p <- lookupPersonnel (appLabor book) pid
  check (personnelStatus p == PersonnelStatusDeparted) (PersonnelAlreadyDeparted pid)
  pure [PersonnelReactivated pid]
decide book (MarkPersonnelDeparted pid) = do
  p <- lookupPersonnel (appLabor book) pid
  check (personnelStatus p == PersonnelStatusDeparted) (PersonnelAlreadyDeparted pid)
  pure [PersonnelDeparted pid]
-- ── 管理会計 (doc/management_accounting.md §2) ───────────────────────────────

decide book (SetKpiThreshold kt) = do
  let mb = appManagementAccounting book
  check (Map.member (ktId kt) (kpiThresholds mb)) (DuplicateKpiThresholdId (ktId kt))
  check (ktWarnAt kt <= 0) (InvalidKpiThresholdValue "ktWarnAtは正値必須")
  case ktCriticalAt kt of
    Nothing -> pure ()
    Just c ->
      check
        (c <= ktWarnAt kt)
        (InvalidKpiThresholdValue "ktCriticalAtはktWarnAtより大きい必要があります")
  pure [KpiThresholdSet kt]
decide book (RetireKpiThreshold ktid) = do
  kt <- lookupKpiThreshold (appManagementAccounting book) ktid
  check (ktRetired kt) (KpiThresholdAlreadyRetired ktid)
  pure [KpiThresholdRetired ktid]
decide book (EvaluateBudgetConsumption alertId pid mPhase now mOrder) = do
  pa <- lookupProject (appProjects book) pid
  let mb = appManagementAccounting book
      (committed, incurred, budget) = consumptionFor pa mPhase
      total = addMoney committed incurred
      scope = maybe (KpiScopeProject pid) KpiScopePhase mPhase
      matching =
        [ kt
        | kt <- Map.elems (kpiThresholds mb)
        , not (ktRetired kt)
        , ktMetric kt == KpiBudgetConsumptionRate
        , ktScope kt == scope
        ]
  if budget <= zeroMoney
    then pure [] -- 予算ゼロでは消化率を評価できない (ゼロ除算回避)
    else case matching of
      [] -> pure []
      -- 複数の有効な閾値が同一スコープに存在する場合は最初の1件のみ評価する
      -- (doc/management_accounting.md §2.1 の簡略化。運用上は1スコープにつき
      -- 1つの有効な閾値を保つことを前提とする)。
      (kt : _) ->
        let warnAmount = mkMoney (unMoney budget * ktWarnAt kt)
            criticalAmount = fmap (\c -> mkMoney (unMoney budget * c)) (ktCriticalAt kt)
            metricValue = unMoney total / unMoney budget
        in case alertSeverityFor total warnAmount criticalAmount of
             Nothing -> pure []
             Just sev ->
               pure
                 [ BudgetThresholdBreached
                     BudgetAlert
                       { baId = alertId
                       , baThreshold = ktId kt
                       , baProject = pid
                       , baPhase = mPhase
                       , baMetricValue = metricValue
                       , baSeverity = sev
                       , baDetectedAt = now
                       , baCausationOrder = mOrder
                       }
                 ]

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

-- ── テナント管理ヘルパー (doc/tenant_isolation.md §4) ─────────────────────────

-- | このストリームの Tenant を取得する。CreateTenant 未発行なら TenantNotInitialized。
lookupCurrentTenant :: AppBook -> Either DomainError Tenant
lookupCurrentTenant book = case appTenant book of
  Nothing -> Left TenantNotInitialized
  Just t -> Right t

-- ── ユーザー管理ヘルパー (doc/user.md §2) ───────────────────────────────

-- | Removed（終端状態）以外のユーザーを取得する。
lookupLiveUser :: UserBook -> UserId -> Either DomainError User
lookupLiveUser ub uid = case Map.lookup uid (users ub) of
  Nothing -> Left (UserNotFound uid)
  Just u
    | userStatus u == Removed -> Left (UserAlreadyRemoved uid)
    | otherwise -> Right u

-- | actor が存在し、Active かつ Admin であることを要求する。
checkActorIsActiveAdmin :: UserBook -> UserId -> Either DomainError ()
checkActorIsActiveAdmin ub actor = case Map.lookup actor (users ub) of
  Just u | isActiveAdmin u -> Right ()
  _ -> Left (ActorNotAuthorized actor)

-- | actor が target 本人、または Active な Admin であることを要求する（自己管理操作用）。
checkSelfOrAdmin :: UserBook -> UserId -> UserId -> Either DomainError ()
checkSelfOrAdmin ub actor target
  | actor == target = Right ()
  | otherwise = case Map.lookup actor (users ub) of
      Just u | isActiveAdmin u -> Right ()
      _ -> Left (NotSelfOrAdmin actor target)

-- | 現在 Active な Admin の人数。0 ならブートストラップ例外を発火させる。
activeAdminCount :: UserBook -> Int
activeAdminCount ub = length (filter isActiveAdmin (Map.elems (users ub)))

-- | mk* バリデータの結果を DomainError に変換する。
checkValid :: Either T.Text a -> (T.Text -> DomainError) -> Either DomainError ()
checkValid (Left e) mkErr = Left (mkErr e)
checkValid (Right _) _ = Right ()

-- ── プロジェクト管理ヘルパー (doc/project_management.md §2) ──────────────────

lookupProject :: ProjectBook -> ProjectId -> Either DomainError ProjectAggregate
lookupProject pb pid = case Map.lookup pid (projects pb) of
  Nothing -> Left (ProjectNotFound pid)
  Just pa -> Right pa

-- | 全Projectを線形探索して発注を見つける。プロジェクト数のオーダーは
-- 小さいことを前提とする (doc/project_management.md の運用規模を想定)。
lookupOrder :: ProjectBook -> ExternalOrderId -> Either DomainError (ProjectId, ExternalOrder)
lookupOrder pb oid =
  case [(pid, o) | (pid, pa) <- Map.toList (projects pb), Just o <- [Map.lookup oid (paOrders pa)]] of
    ((pid, o) : _) -> Right (pid, o)
    [] -> Left (ExternalOrderNotFound oid)

sumPhaseBudgets :: ProjectAggregate -> Money
sumPhaseBudgets pa = foldl' addMoney zeroMoney (map phaseBudget (Map.elems (paPhases pa)))

checkProjectOpenForOrders :: ProjectId -> Project -> Either DomainError ()
checkProjectOpenForOrders pid p =
  check
    (projectStatus p == ProjectStatusClosed || projectStatus p == ProjectStatusCancelled)
    (ProjectNotOpenForOrders pid)

checkProjectNotAlreadyClosed :: ProjectId -> Project -> Either DomainError ()
checkProjectNotAlreadyClosed pid p =
  check
    (projectStatus p == ProjectStatusClosed || projectStatus p == ProjectStatusCancelled)
    (ProjectAlreadyClosed pid)

checkOrderModifiable :: ExternalOrderId -> OrderStatus -> Either DomainError ()
checkOrderModifiable oid st =
  check (st == OrderDelivered || st == OrderCancelled) (ExternalOrderAlreadyFinalized oid)

-- | 指定スコープ（Phase 指定時はその Phase のみ、未指定なら Project 全体）の
-- 約定額(committed)・確定額(incurred)・予算(budget)を算出する
-- (doc/project_management.md §2.3, doc/management_accounting.md §0.2)。
consumptionFor :: ProjectAggregate -> Maybe ProjectPhaseId -> (Money, Money, Money)
consumptionFor pa mPhase =
  let relevantOrders =
        [ o
        | o <- Map.elems (paOrders pa)
        , orderStatus o /= OrderCancelled
        , maybe True (\phid -> orderPhase o == Just phid) mPhase
        ]
      committed =
        foldl'
          addMoney
          zeroMoney
          [moneyTimesInt (orderUnitPrice o) (orderQuantity o - orderDeliveredQuantity o) | o <- relevantOrders]
      incurred =
        foldl'
          addMoney
          zeroMoney
          [moneyTimesInt (orderUnitPrice o) (orderDeliveredQuantity o) | o <- relevantOrders]
      budget = case mPhase of
        Just phid -> maybe zeroMoney phaseBudget (Map.lookup phid (paPhases pa))
        Nothing -> projectBudgetTotal (paProject pa)
  in (committed, incurred, budget)

moneyTimesInt :: Money -> Int -> Money
moneyTimesInt m n = mkMoney (unMoney m * fromIntegral n)

-- | 確定額が critical/warn のいずれの閾値を超えているかを判定する。
-- critical 閾値が無い、または超えていない場合は warn のみで判定する。
alertSeverityFor :: Money -> Money -> Maybe Money -> Maybe AlertSeverity
alertSeverityFor total warnAmount criticalAmount
  | maybe False (total >=) criticalAmount = Just AlertCritical
  | total >= warnAmount = Just AlertWarning
  | otherwise = Nothing

-- ── 労務人事ヘルパー (doc/labor_management.md §3) ────────────────────────────

lookupPersonnel :: LaborBook -> PersonnelId -> Either DomainError Personnel
lookupPersonnel lb pid = case Map.lookup pid (personnelRecords lb) of
  Nothing -> Left (PersonnelNotFound pid)
  Just p -> Right p

lookupWorkAssignment :: LaborBook -> WorkAssignmentId -> Either DomainError WorkAssignment
lookupWorkAssignment lb waid = case Map.lookup waid (workAssignments lb) of
  Nothing -> Left (WorkAssignmentNotFound waid)
  Just wa -> Right wa

checkWorkAssignmentModifiable :: WorkAssignmentId -> WorkAssignmentStatus -> Either DomainError ()
checkWorkAssignmentModifiable waid st =
  check
    (st == WorkAssignmentStatusCompleted || st == WorkAssignmentStatusCancelled)
    (WorkAssignmentAlreadyFinalized waid)

{- | 発注先 (`PartnerId`) に対応する稼働中の Personnel を探し、指定日に有効な
契約条件を持つものを返す (doc/labor_management.md §2.1)。複数該当する場合は
最初の1件を返す——運用上は1取引先に対し1Personnelを保つことを前提とする。
-}
findActivePersonnelForVendor :: LaborBook -> PartnerId -> Day -> Maybe PersonnelId
findActivePersonnelForVendor lb vendorPid day =
  case
    [ personnelId p
    | p <- Map.elems (personnelRecords lb)
    , personnelPartnerRef p == Just vendorPid
    , personnelStatus p == PersonnelStatusActive
    , hasActiveContract lb (personnelId p) day
    ]
  of
    (pid : _) -> Just pid
    [] -> Nothing

hasActiveContract :: LaborBook -> PersonnelId -> Day -> Bool
hasActiveContract lb pid day =
  any
    ( \ct ->
        ctPersonnel ct == pid
          && ctEffectiveFrom ct <= day
          && maybe True (>= day) (ctEffectiveTo ct)
    )
    (Map.elems (contractTerms lb))

-- ── 管理会計ヘルパー (doc/management_accounting.md §2) ───────────────────────

lookupKpiThreshold :: ManagementAccountingBook -> KpiThresholdId -> Either DomainError KpiThreshold
lookupKpiThreshold mb ktid = case Map.lookup ktid (kpiThresholds mb) of
  Nothing -> Left (KpiThresholdNotFound ktid)
  Just kt -> Right kt
