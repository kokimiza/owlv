module Core.TenantSpec (tests) where

import Test.Tasty
import Test.Tasty.HUnit

import Data.Text qualified as T

import Core.Command (Command (..))
import Core.Decide (decide)
import Core.Domain.Tenant
  ( Tenant (..)
  , TenantId
  , TenantKind (..)
  , TenantStatus (..)
  , mkTenantId
  )
import Core.Domain.User (Role (..), UserId, firstOsUid, mkUserId)
import Core.Error (DomainError (..))
import Core.Event (Event (..))
import Core.Evolve (evolve)
import Core.State (AppBook (..), initialAppBook)

-- ── Helpers ─────────────────────────────────────────────────────────────────

mkId :: String -> UserId
mkId s = case mkUserId (T.pack s) of
  Right u -> u
  Left e -> error ("bad test UserId: " <> T.unpack e)

tid :: String -> TenantId
tid s = case mkTenantId (T.pack s) of
  Right t -> t
  Left e -> error ("bad test TenantId: " <> T.unpack e)

admin1 :: UserId
admin1 = mkId "admin1"

tenantA :: TenantId
tenantA = tid "tenant-a"

tenantB :: TenantId
tenantB = tid "tenant-b"

mkTenant :: TenantId -> Tenant
mkTenant t =
  Tenant
    { tenantId = t
    , tenantName = "Tenant A"
    , tenantStatus = TenantStatusActive
    , tenantKind = StandaloneTenant
    }

-- | CreateTenant 済み、かつ admin1 がそのテナントの Active Admin であるブック。
bookWithTenant :: AppBook
bookWithTenant =
  foldl'
    evolve
    initialAppBook
    [ TenantCreated (mkTenant tenantA)
    , UserCreated admin1 firstOsUid "Admin One" tenantA Admin []
    , UserOsSyncSucceeded admin1
    ]

-- ── Test tree ────────────────────────────────────────────────────────────────

tests :: TestTree
tests =
  testGroup
    "Core.Tenant"
    [ testGroup "CreateTenant" createTests
    , testGroup "SuspendTenant" suspendTests
    , testGroup "ArchiveTenant" archiveTests
    , testGroup "Evolve" evolveTests
    ]

-- ── CreateTenant (doc/tenant_isolation.md §4) ────────────────────────────────

createTests :: [TestTree]
createTests =
  [ testCase "未初期化ストリームへの CreateTenant は成功する" $
      decide initialAppBook (CreateTenant (mkTenant tenantA))
        @?= Right [TenantCreated (mkTenant tenantA)]
  , testCase "テナント名が空なら EmptyMasterField" $
      let emptyNamed = (mkTenant tenantA){tenantName = ""}
      in case decide initialAppBook (CreateTenant emptyNamed) of
           Left (EmptyMasterField _) -> pure ()
           other -> assertFailure ("expected EmptyMasterField, got: " <> show other)
  , testCase "既に初期化済みのストリームへの再 CreateTenant は TenantAlreadyInitialized" $
      case decide bookWithTenant (CreateTenant (mkTenant tenantB)) of
        Left TenantAlreadyInitialized -> pure ()
        other -> assertFailure ("expected TenantAlreadyInitialized, got: " <> show other)
  ]

-- ── SuspendTenant ────────────────────────────────────────────────────────────

suspendTests :: [TestTree]
suspendTests =
  [ testCase "未初期化ストリームでの SuspendTenant は TenantNotInitialized" $
      case decide initialAppBook (SuspendTenant admin1 tenantA) of
        Left TenantNotInitialized -> pure ()
        other -> assertFailure ("expected TenantNotInitialized, got: " <> show other)
  , testCase "Active Admin による Suspend は成功する" $
      decide bookWithTenant (SuspendTenant admin1 tenantA) @?= Right [TenantSuspended tenantA]
  , testCase "Admin でない actor による Suspend は ActorNotAuthorized" $
      let nonAdmin = mkId "bob"
          book = foldl' evolve bookWithTenant [UserCreated nonAdmin firstOsUid "Bob" tenantA Operator []]
      in case decide book (SuspendTenant nonAdmin tenantA) of
           Left (ActorNotAuthorized actor) -> actor @?= nonAdmin
           other -> assertFailure ("expected ActorNotAuthorized, got: " <> show other)
  , testCase "別の TenantId を指定すると TenantIdMismatch" $
      case decide bookWithTenant (SuspendTenant admin1 tenantB) of
        Left (TenantIdMismatch expected got) -> (expected, got) @?= (tenantA, tenantB)
        other -> assertFailure ("expected TenantIdMismatch, got: " <> show other)
  , testCase "既に Suspended なテナントへの再 Suspend は TenantAlreadySuspended" $
      let book = foldl' evolve bookWithTenant [TenantSuspended tenantA]
      in case decide book (SuspendTenant admin1 tenantA) of
           Left (TenantAlreadySuspended t) -> t @?= tenantA
           other -> assertFailure ("expected TenantAlreadySuspended, got: " <> show other)
  , testCase "Archived なテナントへの Suspend は TenantAlreadyArchived" $
      let book = foldl' evolve bookWithTenant [TenantArchived tenantA]
      in case decide book (SuspendTenant admin1 tenantA) of
           Left (TenantAlreadyArchived t) -> t @?= tenantA
           other -> assertFailure ("expected TenantAlreadyArchived, got: " <> show other)
  ]

-- ── ArchiveTenant ────────────────────────────────────────────────────────────

archiveTests :: [TestTree]
archiveTests =
  [ testCase "Active Admin による Archive は成功する（Suspended 経由でなくてもよい）" $
      decide bookWithTenant (ArchiveTenant admin1 tenantA) @?= Right [TenantArchived tenantA]
  , testCase "Suspended なテナントからの Archive も成功する" $
      let book = foldl' evolve bookWithTenant [TenantSuspended tenantA]
      in decide book (ArchiveTenant admin1 tenantA) @?= Right [TenantArchived tenantA]
  , testCase "既に Archived なテナントへの再 Archive は TenantAlreadyArchived" $
      let book = foldl' evolve bookWithTenant [TenantArchived tenantA]
      in case decide book (ArchiveTenant admin1 tenantA) of
           Left (TenantAlreadyArchived t) -> t @?= tenantA
           other -> assertFailure ("expected TenantAlreadyArchived, got: " <> show other)
  , testCase "別の TenantId を指定すると TenantIdMismatch" $
      case decide bookWithTenant (ArchiveTenant admin1 tenantB) of
        Left (TenantIdMismatch expected got) -> (expected, got) @?= (tenantA, tenantB)
        other -> assertFailure ("expected TenantIdMismatch, got: " <> show other)
  ]

-- ── evolve の状態機械 ────────────────────────────────────────────────────────

evolveTests :: [TestTree]
evolveTests =
  [ testCase "TenantCreated 直後は Active" $
      let book = evolve initialAppBook (TenantCreated (mkTenant tenantA))
      in fmap tenantStatus (appTenant book) @?= Just TenantStatusActive
  , testCase "TenantSuspended で Suspended になる" $
      let book =
            foldl' evolve initialAppBook [TenantCreated (mkTenant tenantA), TenantSuspended tenantA]
      in fmap tenantStatus (appTenant book) @?= Just TenantStatusSuspended
  , testCase "TenantArchived で Archived になる" $
      let book =
            foldl' evolve initialAppBook [TenantCreated (mkTenant tenantA), TenantArchived tenantA]
      in fmap tenantStatus (appTenant book) @?= Just TenantStatusArchived
  , testCase "fold は順序通りに決定的（同じイベント列は同じ結果を生む）" $
      let evts = [TenantCreated (mkTenant tenantA), TenantSuspended tenantA, TenantArchived tenantA]
          book1 = foldl' evolve initialAppBook evts
          book2 = foldl' evolve initialAppBook evts
      in appTenant book1 @?= appTenant book2
  ]
