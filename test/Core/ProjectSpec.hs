module Core.ProjectSpec (tests) where

import Data.List (foldl')
import Data.Time (Day, fromGregorian)
import Test.Tasty
import Test.Tasty.HUnit

import Data.Map.Strict qualified as Map
import Data.UUID qualified as UUID

import Core.Command (Command (..))
import Core.Decide (decide)
import Core.Domain.ExternalOrder
  ( ExpenseNature (..)
  , ExternalOrder (..)
  , ExternalOrderId (..)
  , OrderStatus (..)
  , RevenueNature (..)
  , SingleTransaction (..)
  , SingleTransactionId (..)
  )
import Core.Domain.Money (mkMoney, zeroMoney)
import Core.Domain.Organisation (Organisation (..), OrganisationId, mkOrganisationId)
import Core.Domain.Partner (PartnerId (..))
import Core.Domain.Project
  ( Project (..)
  , ProjectId (..)
  , ProjectLifecycle (..)
  , ProjectPhase (..)
  , ProjectPhaseId (..)
  , ProjectStatus (..)
  )
import Core.Domain.Tenant (TenantId, mkTenantId)
import Core.Error (DomainError (..))
import Core.Event (Event (..))
import Core.Evolve (evolve)
import Core.State (AppBook (..), ProjectAggregate (..), ProjectBook (..), initialAppBook)

-- ── Helpers ─────────────────────────────────────────────────────────────────

testOrg :: OrganisationId
testOrg = case mkOrganisationId "ORG1" of
  Right o -> o
  Left e -> error ("bad test OrganisationId: " <> show e)

testTenant :: TenantId
testTenant = case mkTenantId "tenant-a" of
  Right t -> t
  Left e -> error ("bad test TenantId: " <> show e)

bookWithOrg :: AppBook
bookWithOrg =
  evolve initialAppBook (OrganisationRegistered (Organisation testOrg "Org One" Nothing True))

mkUUID :: Int -> UUID.UUID
mkUUID n = UUID.fromWords (fromIntegral n) 0 0 0

testDay :: Day
testDay = fromGregorian 2026 6 24

testProjectId :: ProjectId
testProjectId = ProjectId (mkUUID 1)

testProject :: Project
testProject =
  Project
    { projectId = testProjectId
    , projectTenant = testTenant
    , projectOrg = testOrg
    , projectName = "アニメ制作プロジェクト"
    , projectLifecycle = ProjectLifecycleLongRunning
    , projectStatus = ProjectStatusOpen
    , projectCustomer = Nothing
    , projectBudgetTotal = mkMoney 1000000
    , projectOpenedDate = testDay
    , projectExpectedEndDate = Nothing
    }

bookWithProject :: AppBook
bookWithProject = foldl' evolve bookWithOrg [ProjectOpened testProject]

vendorPid :: PartnerId
vendorPid = PartnerId "VENDOR1"

testOrderId :: ExternalOrderId
testOrderId = ExternalOrderId (mkUUID 2)

testOrder :: ExternalOrder
testOrder =
  ExternalOrder
    { orderId = testOrderId
    , orderProject = testProjectId
    , orderPhase = Nothing
    , orderVendor = vendorPid
    , orderDescription = "背景5枚"
    , orderNature = ExpenseSubcontractCost
    , orderUnitPrice = mkMoney 50000
    , orderQuantity = 5
    , orderDeliveredQuantity = 0
    , orderDate = testDay
    , orderExpectedDate = Nothing
    , orderStatus = OrderPlaced
    }

bookWithOrder :: AppBook
bookWithOrder = foldl' evolve bookWithProject [ExternalOrderPlaced testOrder]

testPhase :: ProjectPhase
testPhase =
  ProjectPhase
    { phaseId = ProjectPhaseId (mkUUID 3)
    , phaseProject = testProjectId
    , phaseName = "第1話"
    , phaseBudget = mkMoney 500000
    , phaseStatus = ProjectStatusOpen
    }

-- ── Test tree ────────────────────────────────────────────────────────────────

tests :: TestTree
tests =
  testGroup
    "Core.Project"
    [ testGroup "OpenProject" openTests
    , testGroup "AddProjectPhase" phaseTests
    , testGroup "PlaceExternalOrder" orderTests
    , testGroup "ConfirmExternalOrderDelivery" deliveryTests
    , testGroup "CancelExternalOrder" cancelTests
    , testGroup "RecordSingleTransaction" singleTxTests
    , testGroup "CloseProject" closeTests
    , testGroup "Evolve" evolveTests
    ]

-- ── OpenProject ──────────────────────────────────────────────────────────────

openTests :: [TestTree]
openTests =
  [ testCase "未登録Projectの新規Openは成功する" $
      decide bookWithOrg (OpenProject testProject) @?= Right [ProjectOpened testProject]
  , testCase "同一IDの再Openは DuplicateProjectId" $
      case decide bookWithProject (OpenProject testProject) of
        Left (DuplicateProjectId pid) -> pid @?= testProjectId
        other -> assertFailure ("expected DuplicateProjectId, got: " <> show other)
  , testCase "プロジェクト名が空ならEmptyMasterField" $
      case decide bookWithOrg (OpenProject testProject{projectName = ""}) of
        Left (EmptyMasterField _) -> pure ()
        other -> assertFailure ("expected EmptyMasterField, got: " <> show other)
  ]

-- ── AddProjectPhase ──────────────────────────────────────────────────────────

phaseTests :: [TestTree]
phaseTests =
  [ testCase "予算内のPhase追加は成功する" $
      decide bookWithProject (AddProjectPhase testPhase) @?= Right [ProjectPhaseAdded testPhase]
  , testCase "Project予算を超えるPhase追加はPhaseBudgetExceedsProjectBudget" $
      let bigPhase = testPhase{phaseBudget = mkMoney 2000000}
      in case decide bookWithProject (AddProjectPhase bigPhase) of
           Left (PhaseBudgetExceedsProjectBudget pid _ _) -> pid @?= testProjectId
           other -> assertFailure ("expected PhaseBudgetExceedsProjectBudget, got: " <> show other)
  , testCase "存在しないProjectへのPhase追加はProjectNotFound" $
      case decide bookWithOrg (AddProjectPhase testPhase) of
        Left (ProjectNotFound _) -> pure ()
        other -> assertFailure ("expected ProjectNotFound, got: " <> show other)
  ]

-- ── PlaceExternalOrder ───────────────────────────────────────────────────────

orderTests :: [TestTree]
orderTests =
  [ testCase "Open状態のProjectへの発注は成功する" $
      decide bookWithProject (PlaceExternalOrder testOrder) @?= Right [ExternalOrderPlaced testOrder]
  , testCase "Closed状態のProjectへの発注はProjectNotOpenForOrders" $
      let closedBook = foldl' evolve bookWithProject [ProjectClosed testProjectId testDay]
      in case decide closedBook (PlaceExternalOrder testOrder) of
           Left (ProjectNotOpenForOrders _) -> pure ()
           other -> assertFailure ("expected ProjectNotOpenForOrders, got: " <> show other)
  , testCase "重複した発注IDはDuplicateExternalOrderId" $
      case decide bookWithOrder (PlaceExternalOrder testOrder) of
        Left (DuplicateExternalOrderId _) -> pure ()
        other -> assertFailure ("expected DuplicateExternalOrderId, got: " <> show other)
  ]

-- ── ConfirmExternalOrderDelivery ─────────────────────────────────────────────

deliveryTests :: [TestTree]
deliveryTests =
  [ testCase "数量内の検収確認は成功する" $
      decide bookWithOrder (ConfirmExternalOrderDelivery testOrderId testDay 3)
        @?= Right [ExternalOrderDeliveryConfirmed testOrderId testDay 3]
  , testCase "発注数量を超える検収はDeliveredQuantityExceedsOrder" $
      case decide bookWithOrder (ConfirmExternalOrderDelivery testOrderId testDay 10) of
        Left (DeliveredQuantityExceedsOrder oid expectedQty attemptedQty) -> do
          oid @?= testOrderId
          expectedQty @?= 5
          attemptedQty @?= 10
        other -> assertFailure ("expected DeliveredQuantityExceedsOrder, got: " <> show other)
  , testCase "Cancelled済みの発注への検収はExternalOrderAlreadyFinalized" $
      let cancelledBook = foldl' evolve bookWithOrder [ExternalOrderCancelled testOrderId "test"]
      in case decide cancelledBook (ConfirmExternalOrderDelivery testOrderId testDay 1) of
           Left (ExternalOrderAlreadyFinalized _) -> pure ()
           other -> assertFailure ("expected ExternalOrderAlreadyFinalized, got: " <> show other)
  ]

-- ── CancelExternalOrder ──────────────────────────────────────────────────────

cancelTests :: [TestTree]
cancelTests =
  [ testCase "Placed状態の発注はキャンセルできる" $
      decide bookWithOrder (CancelExternalOrder testOrderId "予算超過")
        @?= Right [ExternalOrderCancelled testOrderId "予算超過"]
  , testCase "理由が空ならEmptyMasterField" $
      case decide bookWithOrder (CancelExternalOrder testOrderId "") of
        Left (EmptyMasterField _) -> pure ()
        other -> assertFailure ("expected EmptyMasterField, got: " <> show other)
  ]

-- ── RecordSingleTransaction (doc/project_management.md §6) ──────────────────

testStx :: SingleTransaction
testStx =
  SingleTransaction
    { stxId = SingleTransactionId (mkUUID 9)
    , stxProject = ProjectId (mkUUID 99)
    , stxDescription = "グッズ販売"
    , stxNature = RevenueGoodsSale
    , stxCounterparty = Nothing
    , stxAmount = mkMoney 3000
    , stxDate = testDay
    , stxTaxTreatment = "課税"
    }

singleTxTests :: [TestTree]
singleTxTests =
  [ testCase "新規Projectを暗黙に開いて即座に閉じる3イベントを生成する" $
      decide bookWithOrg (RecordSingleTransaction testStx testOrg testTenant)
        @?= Right
          [ ProjectOpened
              Project
                { projectId = stxProject testStx
                , projectTenant = testTenant
                , projectOrg = testOrg
                , projectName = "グッズ販売"
                , projectLifecycle = ProjectLifecycleSingleTransaction
                , projectStatus = ProjectStatusOpen
                , projectCustomer = Nothing
                , projectBudgetTotal = zeroMoney
                , projectOpenedDate = testDay
                , projectExpectedEndDate = Nothing
                }
          , SingleTransactionRecorded testStx
          , ProjectClosed (stxProject testStx) testDay
          ]
  , testCase "既存ProjectIdを再利用するとDuplicateSingleTransactionProject" $
      let dup = testStx{stxProject = testProjectId}
      in case decide bookWithProject (RecordSingleTransaction dup testOrg testTenant) of
           Left (DuplicateSingleTransactionProject pid) -> pid @?= testProjectId
           other -> assertFailure ("expected DuplicateSingleTransactionProject, got: " <> show other)
  ]

-- ── CloseProject ─────────────────────────────────────────────────────────────

closeTests :: [TestTree]
closeTests =
  [ testCase "Open状態のProjectは閉じられる" $
      decide bookWithProject (CloseProject testProjectId testDay)
        @?= Right [ProjectClosed testProjectId testDay]
  , testCase "既にClosed済みの再Closeは ProjectAlreadyClosed" $
      let closedBook = foldl' evolve bookWithProject [ProjectClosed testProjectId testDay]
      in case decide closedBook (CloseProject testProjectId testDay) of
           Left (ProjectAlreadyClosed _) -> pure ()
           other -> assertFailure ("expected ProjectAlreadyClosed, got: " <> show other)
  ]

-- ── evolve の状態機械 ────────────────────────────────────────────────────────

lookupProjectAgg :: AppBook -> ProjectId -> Maybe ProjectAggregate
lookupProjectAgg book pid = Map.lookup pid (projects (appProjects book))

evolveTests :: [TestTree]
evolveTests =
  [ testCase "ProjectOpened後にProject集約が読み取れる" $
      fmap paProject (lookupProjectAgg bookWithProject testProjectId) @?= Just testProject
  , testCase "ExternalOrderDeliveryConfirmed後に検収数量・状態が更新される" $
      let book = foldl' evolve bookWithOrder [ExternalOrderDeliveryConfirmed testOrderId testDay 3]
          order = Map.lookup testOrderId . paOrders =<< lookupProjectAgg book testProjectId
      in fmap (\o -> (orderDeliveredQuantity o, orderStatus o)) order
           @?= Just (3, OrderPartiallyDelivered)
  , testCase "全数検収完了でOrderDeliveredになる" $
      let book = foldl' evolve bookWithOrder [ExternalOrderDeliveryConfirmed testOrderId testDay 5]
          order = Map.lookup testOrderId . paOrders =<< lookupProjectAgg book testProjectId
      in fmap orderStatus order @?= Just OrderDelivered
  , testCase "ProjectClosed後にステータスがClosedになる" $
      let book = evolve bookWithProject (ProjectClosed testProjectId testDay)
      in fmap (projectStatus . paProject) (lookupProjectAgg book testProjectId)
           @?= Just ProjectStatusClosed
  , testCase "fold は順序通りに決定的（同じイベント列は同じ結果を生む）" $
      let evts =
            [ ProjectOpened testProject
            , ExternalOrderPlaced testOrder
            , ExternalOrderDeliveryConfirmed testOrderId testDay 2
            ]
          b1 = foldl' evolve bookWithOrg evts
          b2 = foldl' evolve bookWithOrg evts
      in appProjects b1 @?= appProjects b2
  ]
