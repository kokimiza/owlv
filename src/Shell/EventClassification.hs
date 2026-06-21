{- | Identity stream と Tenant stream の判別 (doc/tenant_isolation.md §4)。

すべてのコンストラクタを網羅的に列挙する（ワイルドカードを使わない）。これにより
新しい `Core.Event` コンストラクタを追加した際、ここに分類を追記し忘れると
-Wincomplete-patterns（CI では -Werror）がビルドを止める。Postgres 側で
`event_type` の名前リストを CHECK 制約として持つ案は運用ドリフトの懸念から
doc/tenant_isolation.md §6.2 で採らない方針にした — その代わりに、GHC の
網羅性検査をドリフト検知の仕組みとして使う。
-}
module Shell.EventClassification
  ( isIdentityEvent
  ) where

import Core.Event (Event (..))

{- | Identity stream（Userレジストリ、全社共通）に属するイベントなら True。
False なら Tenant streamに属する（Tenant自身のライフサイクルイベント含む）。
-}
isIdentityEvent :: Event -> Bool
isIdentityEvent (JournalEntryRecorded _) = False
isIdentityEvent (OrganisationRegistered _) = False
isIdentityEvent (OrganisationUpdated _) = False
isIdentityEvent (OrgPermissionGranted _ _) = False
isIdentityEvent (OrgPermissionRevoked _ _) = False
isIdentityEvent (PartnerRegistered _) = False
isIdentityEvent (PartnerUpdated _) = False
isIdentityEvent (AccountMasterRegistered _) = False
isIdentityEvent (AccountMasterUpdated _) = False
isIdentityEvent (SubAccountRegistered _) = False
isIdentityEvent (SubAccountUpdated _) = False
isIdentityEvent (CashTransactionRecorded _) = False
isIdentityEvent (ReconciliationCreated _) = False
isIdentityEvent (ReconciliationReversed _ _) = False
isIdentityEvent (AccountingPeriodOpened _) = False
isIdentityEvent (AccountingPeriodClosed _) = False
isIdentityEvent (FixedAssetRegistered _) = False
isIdentityEvent (DepreciationRecorded _ _ _ _) = False
isIdentityEvent (ImpairmentRecognized _ _ _ _ _) = False
isIdentityEvent (ImpairmentReversalRecognized _ _ _ _) = False
isIdentityEvent (AssetRevalued _ _ _ _ _) = False
isIdentityEvent (FixedAssetDisposed _ _ _) = False
isIdentityEvent (EclMeasurementRecorded _) = False
isIdentityEvent (FxRateRecorded _) = False
isIdentityEvent (JudgmentLogRecorded _) = False
isIdentityEvent (BenefitLiabilityRecorded _) = False
isIdentityEvent (TaxEntryRecorded _) = False
-- テナント自身のライフサイクルは「対象テナント自身のストリームの先頭イベント」
-- として記録する (doc/tenant_isolation.md §4) — Identity streamではない。
isIdentityEvent (TenantCreated _) = False
isIdentityEvent (TenantSuspended _) = False
isIdentityEvent (TenantArchived _) = False
-- ユーザー管理 — OS実体に1:1対応するため全社共通の Identity streamに属する (§4.1)。
isIdentityEvent (UserCreated _ _ _ _ _ _) = True
isIdentityEvent (UserRoleChanged _ _) = True
isIdentityEvent (UserRoleEscalationProposed _ _) = True
isIdentityEvent (UserTenantAccessGranted _ _ _) = True
isIdentityEvent (UserTenantAccessRevoked _ _) = True
isIdentityEvent (UserScopeGranted _ _) = True
isIdentityEvent (UserScopeRevoked _ _) = True
isIdentityEvent (UserPasswordChanged _ _) = True
isIdentityEvent (UserSshKeyRegistered _ _) = True
isIdentityEvent (UserSuspended _) = True
isIdentityEvent (UserReactivated _) = True
isIdentityEvent (UserRemoved _) = True
isIdentityEvent (UserOsSyncSucceeded _) = True
isIdentityEvent (UserOsSyncFailed _ _) = True
isIdentityEvent (UserOsDriftDetected _ _) = True
isIdentityEvent (UserLoginObserved _ _ _) = True
