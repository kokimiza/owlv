module Core.Event
  ( Event (..)
  ) where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.=))
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
import Core.Domain.ManagementAccounting (BudgetAlert, KpiThreshold, KpiThresholdId)
import Core.Domain.Money (Money)
import Core.Domain.OrgPermission (PermScope)
import Core.Domain.Organisation (Organisation, OrganisationId)
import Core.Domain.Partner (Partner)
import Core.Domain.Personnel (ContractTerm, Personnel, PersonnelId)
import Core.Domain.Project (Project, ProjectId, ProjectPhase)
import Core.Domain.Reconciliation (Reconciliation, ReconciliationId)
import Core.Domain.SubAccount (SubAccount)
import Core.Domain.Tax (TaxEntry)
import Core.Domain.Tenant (Tenant, TenantId)
import Core.Domain.User (OsUid, Role, SshPubKey, UserId)
import Core.Domain.WorkAssignment (TimesheetEntry, WorkAssignment, WorkAssignmentId)

data Event
  = JournalEntryRecorded JournalEntry
  | OrganisationRegistered Organisation
  | OrganisationUpdated Organisation
  | OrgPermissionGranted OrganisationId PermScope
  | OrgPermissionRevoked OrganisationId PermScope
  | PartnerRegistered Partner
  | PartnerUpdated Partner
  | AccountMasterRegistered AccountMaster
  | AccountMasterUpdated AccountMaster
  | SubAccountRegistered SubAccount
  | SubAccountUpdated SubAccount
  | -- 入出金・消込・期間
    CashTransactionRecorded CashTransaction
  | ReconciliationCreated Reconciliation
  | -- | 取消日（監査証跡）
    ReconciliationReversed ReconciliationId Day
  | AccountingPeriodOpened AccountingPeriodId
  | AccountingPeriodClosed AccountingPeriodId
  | -- 固定資産台帳 (§2.4) ─────────────────────────────────────────────────
    FixedAssetRegistered FixedAsset
  | -- | 減価償却記録 (日付, 償却額)
    DepreciationRecorded FixedAssetId ComponentId Day Money
  | -- | 減損認識 (日付, 減損損失額, 回収可能価額)
    ImpairmentRecognized FixedAssetId ComponentId Day Money Money
  | -- | 減損戻入 (日付, 戻入額)
    ImpairmentReversalRecognized FixedAssetId ComponentId Day Money
  | -- | 再評価 (日付, 再評価後総額, 再評価差額)
    AssetRevalued FixedAssetId ComponentId Day Money Money
  | -- | 除却
    FixedAssetDisposed FixedAssetId ComponentId Day
  | -- 期待信用損失 (§4.7.5〜4.7.12) ─────────────────────────────────────
    EclMeasurementRecorded EclMeasurement
  | -- 為替レート (§4.7.13) ─────────────────────────────────────────────
    FxRateRecorded FxRate
  | -- 判断ログ (§5) ────────────────────────────────────────────────────
    JudgmentLogRecorded JudgmentLog
  | -- 従業員給付 (§4.7.15) ─────────────────────────────────────────────
    BenefitLiabilityRecorded BenefitLiability
  | -- 法人所得税 (§4.7.16) ─────────────────────────────────────────────
    TaxEntryRecorded TaxEntry
  | -- テナント管理 (doc/tenant_isolation.md §4) ─────────────────────────────
    TenantCreated Tenant
  | TenantSuspended TenantId
  | TenantArchived TenantId
  | -- ユーザー管理 (doc/user.md §2) ────────────────────────────────────
    UserCreated UserId OsUid Text TenantId Role [Text]
  | UserRoleChanged UserId Role
  | UserRoleEscalationProposed
      -- | 提案者
      UserId
      -- | 対象
      UserId
  | -- | doc/tenant_isolation.md §5.2: ホームテナント以外への横断アクセス付与
    UserTenantAccessGranted UserId TenantId Role
  | UserTenantAccessRevoked UserId TenantId
  | UserScopeGranted UserId Text
  | UserScopeRevoked UserId Text
  | UserPasswordChanged UserId Text
  | UserSshKeyRegistered UserId SshPubKey
  | UserSuspended UserId
  | UserReactivated UserId
  | UserRemoved UserId
  | UserOsSyncSucceeded UserId
  | UserOsSyncFailed UserId Text
  | UserOsDriftDetected UserId Text
  | UserLoginObserved UserId UTCTime (Maybe Text)
  | -- プロジェクト管理 (doc/project_management.md §2) ──────────────────────
    ProjectOpened Project
  | ProjectPhaseAdded ProjectPhase
  | ProjectBudgetRevised ProjectId Money Text
  | -- | ユーザー提示例の核心: 「外部A氏に背景5枚を発注、単価5万」
    ExternalOrderPlaced ExternalOrder
  | ExternalOrderDeliveryConfirmed ExternalOrderId Day Int
  | ExternalOrderCancelled ExternalOrderId Text
  | SingleTransactionRecorded SingleTransaction
  | ProjectClosed ProjectId Day
  | -- 労務人事 (doc/labor_management.md §3) ────────────────────────────────
    PersonnelRegistered Personnel
  | ContractTermRecorded ContractTerm
  | WorkAssignmentCreated WorkAssignment
  | -- | doc/labor_management.md §2.1: 照合失敗。握り潰さず財務会計の保留判断対象にもなる
    PersonnelReconciliationFailed ExternalOrderId Text
  | TimesheetEntryRecorded TimesheetEntry
  | WorkAssignmentCompleted WorkAssignmentId Day
  | PersonnelSuspended PersonnelId
  | PersonnelReactivated PersonnelId
  | PersonnelDeparted PersonnelId
  | -- 管理会計 (doc/management_accounting.md §2) ────────────────────────────
    KpiThresholdSet KpiThreshold
  | KpiThresholdRetired KpiThresholdId
  | -- | 管理会計モジュールが Event Store に書き込む唯一のイベント (doc/management_accounting.md §2)
    BudgetThresholdBreached BudgetAlert
  deriving (Eq, Show)

instance ToJSON Event where
  toJSON (JournalEntryRecorded e) =
    object ["type" .= ("JournalEntryRecorded" :: Text), "data" .= e]
  toJSON (OrganisationRegistered o) =
    object ["type" .= ("OrganisationRegistered" :: Text), "data" .= o]
  toJSON (OrganisationUpdated o) =
    object ["type" .= ("OrganisationUpdated" :: Text), "data" .= o]
  toJSON (OrgPermissionGranted oid ps) =
    object ["type" .= ("OrgPermissionGranted" :: Text), "org" .= oid, "scope" .= ps]
  toJSON (OrgPermissionRevoked oid ps) =
    object ["type" .= ("OrgPermissionRevoked" :: Text), "org" .= oid, "scope" .= ps]
  toJSON (PartnerRegistered p) =
    object ["type" .= ("PartnerRegistered" :: Text), "data" .= p]
  toJSON (PartnerUpdated p) =
    object ["type" .= ("PartnerUpdated" :: Text), "data" .= p]
  toJSON (AccountMasterRegistered am) =
    object ["type" .= ("AccountMasterRegistered" :: Text), "data" .= am]
  toJSON (AccountMasterUpdated am) =
    object ["type" .= ("AccountMasterUpdated" :: Text), "data" .= am]
  toJSON (SubAccountRegistered sa) =
    object ["type" .= ("SubAccountRegistered" :: Text), "data" .= sa]
  toJSON (SubAccountUpdated sa) =
    object ["type" .= ("SubAccountUpdated" :: Text), "data" .= sa]
  toJSON (CashTransactionRecorded ct) =
    object ["type" .= ("CashTransactionRecorded" :: Text), "data" .= ct]
  toJSON (ReconciliationCreated rec) =
    object ["type" .= ("ReconciliationCreated" :: Text), "data" .= rec]
  toJSON (ReconciliationReversed recId date) =
    object ["type" .= ("ReconciliationReversed" :: Text), "id" .= recId, "date" .= date]
  toJSON (AccountingPeriodOpened apId) =
    object ["type" .= ("AccountingPeriodOpened" :: Text), "data" .= apId]
  toJSON (AccountingPeriodClosed apId) =
    object ["type" .= ("AccountingPeriodClosed" :: Text), "data" .= apId]
  -- 固定資産
  toJSON (FixedAssetRegistered fa) =
    object ["type" .= ("FixedAssetRegistered" :: Text), "data" .= fa]
  toJSON (DepreciationRecorded assetId compId day amount) =
    object
      [ "type" .= ("DepreciationRecorded" :: Text)
      , "assetId" .= assetId
      , "compId" .= compId
      , "date" .= day
      , "amount" .= amount
      ]
  toJSON (ImpairmentRecognized assetId compId day loss recoverable) =
    object
      [ "type" .= ("ImpairmentRecognized" :: Text)
      , "assetId" .= assetId
      , "compId" .= compId
      , "date" .= day
      , "loss" .= loss
      , "recoverable" .= recoverable
      ]
  toJSON (ImpairmentReversalRecognized assetId compId day amount) =
    object
      [ "type" .= ("ImpairmentReversalRecognized" :: Text)
      , "assetId" .= assetId
      , "compId" .= compId
      , "date" .= day
      , "amount" .= amount
      ]
  toJSON (AssetRevalued assetId compId day newGross surplus) =
    object
      [ "type" .= ("AssetRevalued" :: Text)
      , "assetId" .= assetId
      , "compId" .= compId
      , "date" .= day
      , "newGross" .= newGross
      , "surplus" .= surplus
      ]
  toJSON (FixedAssetDisposed assetId compId day) =
    object
      [ "type" .= ("FixedAssetDisposed" :: Text)
      , "assetId" .= assetId
      , "compId" .= compId
      , "date" .= day
      ]
  -- ECL
  toJSON (EclMeasurementRecorded m) =
    object ["type" .= ("EclMeasurementRecorded" :: Text), "data" .= m]
  -- FX
  toJSON (FxRateRecorded r) =
    object ["type" .= ("FxRateRecorded" :: Text), "data" .= r]
  -- 判断ログ
  toJSON (JudgmentLogRecorded l) =
    object ["type" .= ("JudgmentLogRecorded" :: Text), "data" .= l]
  -- 従業員給付
  toJSON (BenefitLiabilityRecorded b) =
    object ["type" .= ("BenefitLiabilityRecorded" :: Text), "data" .= b]
  -- 法人所得税
  toJSON (TaxEntryRecorded t) =
    object ["type" .= ("TaxEntryRecorded" :: Text), "data" .= t]
  -- テナント管理
  toJSON (TenantCreated t) =
    object ["type" .= ("TenantCreated" :: Text), "data" .= t]
  toJSON (TenantSuspended tid) =
    object ["type" .= ("TenantSuspended" :: Text), "tenantId" .= tid]
  toJSON (TenantArchived tid) =
    object ["type" .= ("TenantArchived" :: Text), "tenantId" .= tid]
  -- ユーザー管理
  toJSON (UserCreated uid uidOs name homeTenant role scopes) =
    object
      [ "type" .= ("UserCreated" :: Text)
      , "userId" .= uid
      , "osUid" .= uidOs
      , "name" .= name
      , "homeTenant" .= homeTenant
      , "role" .= role
      , "scopes" .= scopes
      ]
  toJSON (UserRoleChanged uid role) =
    object ["type" .= ("UserRoleChanged" :: Text), "userId" .= uid, "role" .= role]
  toJSON (UserRoleEscalationProposed proposer target) =
    object
      [ "type" .= ("UserRoleEscalationProposed" :: Text)
      , "proposer" .= proposer
      , "target" .= target
      ]
  toJSON (UserTenantAccessGranted uid tid role) =
    object
      [ "type" .= ("UserTenantAccessGranted" :: Text)
      , "userId" .= uid
      , "tenantId" .= tid
      , "role" .= role
      ]
  toJSON (UserTenantAccessRevoked uid tid) =
    object
      [ "type" .= ("UserTenantAccessRevoked" :: Text)
      , "userId" .= uid
      , "tenantId" .= tid
      ]
  toJSON (UserScopeGranted uid scope) =
    object ["type" .= ("UserScopeGranted" :: Text), "userId" .= uid, "scope" .= scope]
  toJSON (UserScopeRevoked uid scope) =
    object ["type" .= ("UserScopeRevoked" :: Text), "userId" .= uid, "scope" .= scope]
  toJSON (UserPasswordChanged uid hash) =
    object ["type" .= ("UserPasswordChanged" :: Text), "userId" .= uid, "hash" .= hash]
  toJSON (UserSshKeyRegistered uid key) =
    object ["type" .= ("UserSshKeyRegistered" :: Text), "userId" .= uid, "key" .= key]
  toJSON (UserSuspended uid) =
    object ["type" .= ("UserSuspended" :: Text), "userId" .= uid]
  toJSON (UserReactivated uid) =
    object ["type" .= ("UserReactivated" :: Text), "userId" .= uid]
  toJSON (UserRemoved uid) =
    object ["type" .= ("UserRemoved" :: Text), "userId" .= uid]
  toJSON (UserOsSyncSucceeded uid) =
    object ["type" .= ("UserOsSyncSucceeded" :: Text), "userId" .= uid]
  toJSON (UserOsSyncFailed uid reason) =
    object ["type" .= ("UserOsSyncFailed" :: Text), "userId" .= uid, "reason" .= reason]
  toJSON (UserOsDriftDetected uid detail) =
    object ["type" .= ("UserOsDriftDetected" :: Text), "userId" .= uid, "detail" .= detail]
  toJSON (UserLoginObserved uid at srcIp) =
    object
      [ "type" .= ("UserLoginObserved" :: Text)
      , "userId" .= uid
      , "at" .= at
      , "srcIp" .= srcIp
      ]
  -- プロジェクト管理
  toJSON (ProjectOpened p) =
    object ["type" .= ("ProjectOpened" :: Text), "data" .= p]
  toJSON (ProjectPhaseAdded ph) =
    object ["type" .= ("ProjectPhaseAdded" :: Text), "data" .= ph]
  toJSON (ProjectBudgetRevised pid newTotal reason) =
    object
      [ "type" .= ("ProjectBudgetRevised" :: Text)
      , "projectId" .= pid
      , "newTotal" .= newTotal
      , "reason" .= reason
      ]
  toJSON (ExternalOrderPlaced o) =
    object ["type" .= ("ExternalOrderPlaced" :: Text), "data" .= o]
  toJSON (ExternalOrderDeliveryConfirmed oid day qty) =
    object
      [ "type" .= ("ExternalOrderDeliveryConfirmed" :: Text)
      , "orderId" .= oid
      , "date" .= day
      , "quantity" .= qty
      ]
  toJSON (ExternalOrderCancelled oid reason) =
    object
      [ "type" .= ("ExternalOrderCancelled" :: Text)
      , "orderId" .= oid
      , "reason" .= reason
      ]
  toJSON (SingleTransactionRecorded stx) =
    object ["type" .= ("SingleTransactionRecorded" :: Text), "data" .= stx]
  toJSON (ProjectClosed pid day) =
    object ["type" .= ("ProjectClosed" :: Text), "projectId" .= pid, "date" .= day]
  -- 労務人事
  toJSON (PersonnelRegistered p) =
    object ["type" .= ("PersonnelRegistered" :: Text), "data" .= p]
  toJSON (ContractTermRecorded ct) =
    object ["type" .= ("ContractTermRecorded" :: Text), "data" .= ct]
  toJSON (WorkAssignmentCreated wa) =
    object ["type" .= ("WorkAssignmentCreated" :: Text), "data" .= wa]
  toJSON (PersonnelReconciliationFailed oid reason) =
    object
      [ "type" .= ("PersonnelReconciliationFailed" :: Text)
      , "orderId" .= oid
      , "reason" .= reason
      ]
  toJSON (TimesheetEntryRecorded e) =
    object ["type" .= ("TimesheetEntryRecorded" :: Text), "data" .= e]
  toJSON (WorkAssignmentCompleted waid day) =
    object
      [ "type" .= ("WorkAssignmentCompleted" :: Text)
      , "assignmentId" .= waid
      , "date" .= day
      ]
  toJSON (PersonnelSuspended pid) =
    object ["type" .= ("PersonnelSuspended" :: Text), "personnelId" .= pid]
  toJSON (PersonnelReactivated pid) =
    object ["type" .= ("PersonnelReactivated" :: Text), "personnelId" .= pid]
  toJSON (PersonnelDeparted pid) =
    object ["type" .= ("PersonnelDeparted" :: Text), "personnelId" .= pid]
  -- 管理会計
  toJSON (KpiThresholdSet kt) =
    object ["type" .= ("KpiThresholdSet" :: Text), "data" .= kt]
  toJSON (KpiThresholdRetired ktid) =
    object ["type" .= ("KpiThresholdRetired" :: Text), "thresholdId" .= ktid]
  toJSON (BudgetThresholdBreached alert) =
    object ["type" .= ("BudgetThresholdBreached" :: Text), "data" .= alert]

instance FromJSON Event where
  parseJSON = withObject "Event" $ \o -> do
    typ <- o .: "type"
    case (typ :: Text) of
      "JournalEntryRecorded" -> JournalEntryRecorded <$> o .: "data"
      "OrganisationRegistered" -> OrganisationRegistered <$> o .: "data"
      "OrganisationUpdated" -> OrganisationUpdated <$> o .: "data"
      "OrgPermissionGranted" -> OrgPermissionGranted <$> o .: "org" <*> o .: "scope"
      "OrgPermissionRevoked" -> OrgPermissionRevoked <$> o .: "org" <*> o .: "scope"
      "PartnerRegistered" -> PartnerRegistered <$> o .: "data"
      "PartnerUpdated" -> PartnerUpdated <$> o .: "data"
      "AccountMasterRegistered" -> AccountMasterRegistered <$> o .: "data"
      "AccountMasterUpdated" -> AccountMasterUpdated <$> o .: "data"
      "SubAccountRegistered" -> SubAccountRegistered <$> o .: "data"
      "SubAccountUpdated" -> SubAccountUpdated <$> o .: "data"
      "CashTransactionRecorded" -> CashTransactionRecorded <$> o .: "data"
      "ReconciliationCreated" -> ReconciliationCreated <$> o .: "data"
      "ReconciliationReversed" -> ReconciliationReversed <$> o .: "id" <*> o .: "date"
      "AccountingPeriodOpened" -> AccountingPeriodOpened <$> o .: "data"
      "AccountingPeriodClosed" -> AccountingPeriodClosed <$> o .: "data"
      -- 固定資産
      "FixedAssetRegistered" -> FixedAssetRegistered <$> o .: "data"
      "DepreciationRecorded" ->
        DepreciationRecorded
          <$> o .: "assetId"
          <*> o .: "compId"
          <*> o .: "date"
          <*> o .: "amount"
      "ImpairmentRecognized" ->
        ImpairmentRecognized
          <$> o .: "assetId"
          <*> o .: "compId"
          <*> o .: "date"
          <*> o .: "loss"
          <*> o .: "recoverable"
      "ImpairmentReversalRecognized" ->
        ImpairmentReversalRecognized
          <$> o .: "assetId"
          <*> o .: "compId"
          <*> o .: "date"
          <*> o .: "amount"
      "AssetRevalued" ->
        AssetRevalued
          <$> o .: "assetId"
          <*> o .: "compId"
          <*> o .: "date"
          <*> o .: "newGross"
          <*> o .: "surplus"
      "FixedAssetDisposed" ->
        FixedAssetDisposed
          <$> o .: "assetId"
          <*> o .: "compId"
          <*> o .: "date"
      -- ECL
      "EclMeasurementRecorded" -> EclMeasurementRecorded <$> o .: "data"
      -- FX
      "FxRateRecorded" -> FxRateRecorded <$> o .: "data"
      -- 判断ログ
      "JudgmentLogRecorded" -> JudgmentLogRecorded <$> o .: "data"
      -- 従業員給付
      "BenefitLiabilityRecorded" -> BenefitLiabilityRecorded <$> o .: "data"
      -- 法人所得税
      "TaxEntryRecorded" -> TaxEntryRecorded <$> o .: "data"
      -- テナント管理
      "TenantCreated" -> TenantCreated <$> o .: "data"
      "TenantSuspended" -> TenantSuspended <$> o .: "tenantId"
      "TenantArchived" -> TenantArchived <$> o .: "tenantId"
      -- ユーザー管理
      "UserCreated" ->
        UserCreated
          <$> o .: "userId"
          <*> o .: "osUid"
          <*> o .: "name"
          <*> o .: "homeTenant"
          <*> o .: "role"
          <*> o .: "scopes"
      "UserRoleChanged" -> UserRoleChanged <$> o .: "userId" <*> o .: "role"
      "UserRoleEscalationProposed" ->
        UserRoleEscalationProposed <$> o .: "proposer" <*> o .: "target"
      "UserTenantAccessGranted" ->
        UserTenantAccessGranted <$> o .: "userId" <*> o .: "tenantId" <*> o .: "role"
      "UserTenantAccessRevoked" ->
        UserTenantAccessRevoked <$> o .: "userId" <*> o .: "tenantId"
      "UserScopeGranted" -> UserScopeGranted <$> o .: "userId" <*> o .: "scope"
      "UserScopeRevoked" -> UserScopeRevoked <$> o .: "userId" <*> o .: "scope"
      "UserPasswordChanged" -> UserPasswordChanged <$> o .: "userId" <*> o .: "hash"
      "UserSshKeyRegistered" -> UserSshKeyRegistered <$> o .: "userId" <*> o .: "key"
      "UserSuspended" -> UserSuspended <$> o .: "userId"
      "UserReactivated" -> UserReactivated <$> o .: "userId"
      "UserRemoved" -> UserRemoved <$> o .: "userId"
      "UserOsSyncSucceeded" -> UserOsSyncSucceeded <$> o .: "userId"
      "UserOsSyncFailed" -> UserOsSyncFailed <$> o .: "userId" <*> o .: "reason"
      "UserOsDriftDetected" -> UserOsDriftDetected <$> o .: "userId" <*> o .: "detail"
      "UserLoginObserved" ->
        UserLoginObserved <$> o .: "userId" <*> o .: "at" <*> o .: "srcIp"
      -- プロジェクト管理
      "ProjectOpened" -> ProjectOpened <$> o .: "data"
      "ProjectPhaseAdded" -> ProjectPhaseAdded <$> o .: "data"
      "ProjectBudgetRevised" ->
        ProjectBudgetRevised <$> o .: "projectId" <*> o .: "newTotal" <*> o .: "reason"
      "ExternalOrderPlaced" -> ExternalOrderPlaced <$> o .: "data"
      "ExternalOrderDeliveryConfirmed" ->
        ExternalOrderDeliveryConfirmed
          <$> o .: "orderId"
          <*> o .: "date"
          <*> o .: "quantity"
      "ExternalOrderCancelled" ->
        ExternalOrderCancelled <$> o .: "orderId" <*> o .: "reason"
      "SingleTransactionRecorded" -> SingleTransactionRecorded <$> o .: "data"
      "ProjectClosed" -> ProjectClosed <$> o .: "projectId" <*> o .: "date"
      -- 労務人事
      "PersonnelRegistered" -> PersonnelRegistered <$> o .: "data"
      "ContractTermRecorded" -> ContractTermRecorded <$> o .: "data"
      "WorkAssignmentCreated" -> WorkAssignmentCreated <$> o .: "data"
      "PersonnelReconciliationFailed" ->
        PersonnelReconciliationFailed <$> o .: "orderId" <*> o .: "reason"
      "TimesheetEntryRecorded" -> TimesheetEntryRecorded <$> o .: "data"
      "WorkAssignmentCompleted" ->
        WorkAssignmentCompleted <$> o .: "assignmentId" <*> o .: "date"
      "PersonnelSuspended" -> PersonnelSuspended <$> o .: "personnelId"
      "PersonnelReactivated" -> PersonnelReactivated <$> o .: "personnelId"
      "PersonnelDeparted" -> PersonnelDeparted <$> o .: "personnelId"
      -- 管理会計
      "KpiThresholdSet" -> KpiThresholdSet <$> o .: "data"
      "KpiThresholdRetired" -> KpiThresholdRetired <$> o .: "thresholdId"
      "BudgetThresholdBreached" -> BudgetThresholdBreached <$> o .: "data"
      _ -> fail ("unknown Event type: " <> show typ)
