module Core.LaborSpec (tests) where

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
  )
import Core.Domain.Money (mkMoney)
import Core.Domain.Organisation (Organisation (..), OrganisationId, mkOrganisationId)
import Core.Domain.Partner (PartnerId (..))
import Core.Domain.Personnel
  ( ContractTerm (..)
  , ContractTermId (..)
  , EmploymentType (..)
  , PayBasis (..)
  , Personnel (..)
  , PersonnelId (..)
  , PersonnelStatus (..)
  )
import Core.Domain.Project (Project (..), ProjectId (..), ProjectLifecycle (..), ProjectStatus (..))
import Core.Domain.Tenant (TenantId, mkTenantId)
import Core.Domain.User (UserId (..))
import Core.Domain.WorkAssignment
  ( TimesheetEntry (..)
  , TimesheetEntryId (..)
  , WorkAssignment (..)
  , WorkAssignmentId (..)
  , WorkAssignmentStatus (..)
  )
import Core.Error (DomainError (..))
import Core.Event (Event (..))
import Core.Evolve (evolve)
import Core.State (AppBook (..), LaborBook (..), initialAppBook)

-- ── Helpers ─────────────────────────────────────────────────────────────────

testOrg :: OrganisationId
testOrg = case mkOrganisationId "ORG1" of
  Right o -> o
  Left e -> error ("bad test OrganisationId: " <> show e)

testTenant :: TenantId
testTenant = case mkTenantId "tenant-a" of
  Right t -> t
  Left e -> error ("bad test TenantId: " <> show e)

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

baseBook :: AppBook
baseBook =
  foldl'
    evolve
    initialAppBook
    [ OrganisationRegistered (Organisation testOrg "Org One" Nothing True)
    , ProjectOpened testProject
    , ExternalOrderPlaced testOrder
    ]

testPersonnelId :: PersonnelId
testPersonnelId = PersonnelId (mkUUID 3)

testPersonnel :: Personnel
testPersonnel =
  Personnel
    { personnelId = testPersonnelId
    , personnelName = "A氏"
    , personnelEmploymentType = EmploymentContractor
    , personnelPartnerRef = Just vendorPid
    , personnelUserRef = Nothing
    , personnelStatus = PersonnelStatusActive
    }

bookWithPersonnel :: AppBook
bookWithPersonnel = evolve baseBook (PersonnelRegistered testPersonnel)

testContractTermId :: ContractTermId
testContractTermId = ContractTermId (mkUUID 4)

testContractTerm :: ContractTerm
testContractTerm =
  ContractTerm
    { ctId = testContractTermId
    , ctPersonnel = testPersonnelId
    , ctPayBasis = PayPieceRate (mkMoney 50000)
    , ctEffectiveFrom = fromGregorian 2026 1 1
    , ctEffectiveTo = Nothing
    }

bookWithContract :: AppBook
bookWithContract = evolve bookWithPersonnel (ContractTermRecorded testContractTerm)

testAssignmentId :: WorkAssignmentId
testAssignmentId = WorkAssignmentId (mkUUID 5)

testAssignment :: WorkAssignment
testAssignment =
  WorkAssignment
    { waId = testAssignmentId
    , waPersonnel = testPersonnelId
    , waProject = testProjectId
    , waPhase = Nothing
    , waExternalOrder = Just testOrderId
    , waAssignedDate = testDay
    , waStatus = WorkAssignmentStatusAssigned
    }

bookWithAssignment :: AppBook
bookWithAssignment = evolve bookWithContract (WorkAssignmentCreated testAssignment)

-- ── Test tree ────────────────────────────────────────────────────────────────

tests :: TestTree
tests =
  testGroup
    "Core.Labor"
    [ testGroup "RegisterPersonnel" registerTests
    , testGroup "RecordContractTerm" contractTests
    , testGroup "CreateWorkAssignment" assignmentTests
    , testGroup "RecordTimesheetEntry" timesheetTests
    , testGroup "CompleteWorkAssignment" completeTests
    , testGroup "Personnel status transitions" statusTests
    , testGroup "Evolve" evolveTests
    ]

-- ── RegisterPersonnel ────────────────────────────────────────────────────────

registerTests :: [TestTree]
registerTests =
  [ testCase "新規Personnelの登録は成功する" $
      decide baseBook (RegisterPersonnel testPersonnel) @?= Right [PersonnelRegistered testPersonnel]
  , testCase "重複したPersonnelIdはDuplicatePersonnelId" $
      case decide bookWithPersonnel (RegisterPersonnel testPersonnel) of
        Left (DuplicatePersonnelId pid) -> pid @?= testPersonnelId
        other -> assertFailure ("expected DuplicatePersonnelId, got: " <> show other)
  , testCase "氏名が空ならEmptyMasterField" $
      case decide baseBook (RegisterPersonnel testPersonnel{personnelName = ""}) of
        Left (EmptyMasterField _) -> pure ()
        other -> assertFailure ("expected EmptyMasterField, got: " <> show other)
  ]

-- ── RecordContractTerm ───────────────────────────────────────────────────────

contractTests :: [TestTree]
contractTests =
  [ testCase "登録済みPersonnelへの契約条件記録は成功する" $
      decide bookWithPersonnel (RecordContractTerm testContractTerm)
        @?= Right [ContractTermRecorded testContractTerm]
  , testCase "存在しないPersonnelへの記録はPersonnelNotFound" $
      case decide baseBook (RecordContractTerm testContractTerm) of
        Left (PersonnelNotFound _) -> pure ()
        other -> assertFailure ("expected PersonnelNotFound, got: " <> show other)
  , testCase "重複したContractTermIdはDuplicateContractTermId" $
      case decide bookWithContract (RecordContractTerm testContractTerm) of
        Left (DuplicateContractTermId _) -> pure ()
        other -> assertFailure ("expected DuplicateContractTermId, got: " <> show other)
  ]

-- ── CreateWorkAssignment (doc/labor_management.md §2.1) ──────────────────────

assignmentTests :: [TestTree]
assignmentTests =
  [ testCase "稼働中Personnel・有効な契約条件があれば割当が成立する" $
      case decide
        bookWithContract
        (CreateWorkAssignment testAssignmentId testOrderId testProjectId Nothing vendorPid testDay) of
        Right [WorkAssignmentCreated wa] -> waPersonnel wa @?= testPersonnelId
        other -> assertFailure ("expected single WorkAssignmentCreated, got: " <> show other)
  , testCase "対応するPersonnelが見つからない場合は照合失敗イベントを返す（DomainErrorにしない）" $
      decide
        baseBook
        (CreateWorkAssignment testAssignmentId testOrderId testProjectId Nothing vendorPid testDay)
        @?= Right [PersonnelReconciliationFailed testOrderId "対応する稼働中のPersonnel、または有効な契約条件が見つかりません"]
  , testCase "契約条件の有効期間外であれば照合失敗になる" $
      let expiredTerm = testContractTerm{ctEffectiveTo = Just (fromGregorian 2025 12 31)}
          book = evolve bookWithPersonnel (ContractTermRecorded expiredTerm)
      in case decide
           book
           (CreateWorkAssignment testAssignmentId testOrderId testProjectId Nothing vendorPid testDay) of
           Right [PersonnelReconciliationFailed oid _] -> oid @?= testOrderId
           other -> assertFailure ("expected PersonnelReconciliationFailed, got: " <> show other)
  , testCase "重複したWorkAssignmentIdはDuplicateWorkAssignmentId" $
      case decide
        bookWithAssignment
        (CreateWorkAssignment testAssignmentId testOrderId testProjectId Nothing vendorPid testDay) of
        Left (DuplicateWorkAssignmentId _) -> pure ()
        other -> assertFailure ("expected DuplicateWorkAssignmentId, got: " <> show other)
  ]

-- ── RecordTimesheetEntry ─────────────────────────────────────────────────────

testTimesheetId :: TimesheetEntryId
testTimesheetId = TimesheetEntryId (mkUUID 6)

testRecorder :: UserId
testRecorder = UserId "test-recorder"

testTimesheet :: WorkAssignmentId -> TimesheetEntry
testTimesheet waid =
  TimesheetEntry
    { tsId = testTimesheetId
    , tsAssignment = waid
    , tsDate = testDay
    , tsHours = Just 8
    , tsQuantity = Nothing
    , tsRecordedBy = testRecorder
    }

timesheetTests :: [TestTree]
timesheetTests =
  [ testCase "存在しないWorkAssignmentへの実績記録はWorkAssignmentNotFound" $
      case decide bookWithContract (RecordTimesheetEntry (testTimesheet testAssignmentId)) of
        Left (WorkAssignmentNotFound aid) -> aid @?= testAssignmentId
        other -> assertFailure ("expected WorkAssignmentNotFound, got: " <> show other)
  , testCase "存在する割当への実績記録は成功する" $
      decide bookWithAssignment (RecordTimesheetEntry (testTimesheet testAssignmentId))
        @?= Right [TimesheetEntryRecorded (testTimesheet testAssignmentId)]
  ]

-- ── CompleteWorkAssignment ───────────────────────────────────────────────────

completeTests :: [TestTree]
completeTests =
  [ testCase "Assigned状態の割当は完了させられる" $
      decide bookWithAssignment (CompleteWorkAssignment testAssignmentId testDay)
        @?= Right [WorkAssignmentCompleted testAssignmentId testDay]
  , testCase "既にCompleted済みの再完了はWorkAssignmentAlreadyFinalized" $
      let completedBook = evolve bookWithAssignment (WorkAssignmentCompleted testAssignmentId testDay)
      in case decide completedBook (CompleteWorkAssignment testAssignmentId testDay) of
           Left (WorkAssignmentAlreadyFinalized _) -> pure ()
           other -> assertFailure ("expected WorkAssignmentAlreadyFinalized, got: " <> show other)
  ]

-- ── Personnel status transitions ────────────────────────────────────────────

statusTests :: [TestTree]
statusTests =
  [ testCase "稼働中のPersonnelは停止できる" $
      decide bookWithPersonnel (SuspendPersonnel testPersonnelId)
        @?= Right [PersonnelSuspended testPersonnelId]
  , testCase "離籍済みのPersonnelの再離籍はPersonnelAlreadyDeparted" $
      let departedBook = evolve bookWithPersonnel (PersonnelDeparted testPersonnelId)
      in case decide departedBook (MarkPersonnelDeparted testPersonnelId) of
           Left (PersonnelAlreadyDeparted _) -> pure ()
           other -> assertFailure ("expected PersonnelAlreadyDeparted, got: " <> show other)
  ]

-- ── evolve の状態機械 ────────────────────────────────────────────────────────

evolveTests :: [TestTree]
evolveTests =
  [ testCase "PersonnelRegistered後にPersonnelが読み取れる" $
      Map.lookup testPersonnelId (personnelRecords (appLabor bookWithPersonnel)) @?= Just testPersonnel
  , testCase "WorkAssignmentCreated後に割当が読み取れる" $
      Map.lookup testAssignmentId (workAssignments (appLabor bookWithAssignment)) @?= Just testAssignment
  , testCase "PersonnelSuspended後にステータスが変わる" $
      let book = evolve bookWithPersonnel (PersonnelSuspended testPersonnelId)
      in fmap personnelStatus (Map.lookup testPersonnelId (personnelRecords (appLabor book)))
           @?= Just PersonnelStatusSuspended
  , testCase "PersonnelReconciliationFailed は読みモデルを変更しない" $
      let book = evolve baseBook (PersonnelReconciliationFailed testOrderId "no match")
      in appLabor book @?= appLabor baseBook
  ]
