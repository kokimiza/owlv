module Core.ManagementAccountingSpec (tests) where

import Test.Tasty
import Test.Tasty.HUnit

import Data.List (foldl')
import Data.Time (Day, UTCTime (..), fromGregorian, secondsToDiffTime)

import Data.Map.Strict qualified as Map
import Data.UUID qualified as UUID

import Core.Command (Command (..))
import Core.Decide (decide)
import Core.Domain.ExternalOrder (ExpenseNature (..), ExternalOrder (..), ExternalOrderId (..), OrderStatus (..))
import Core.Domain.ManagementAccounting
  ( AlertSeverity (..)
  , BudgetAlert (..)
  , BudgetAlertId (..)
  , KpiMetric (..)
  , KpiScope (..)
  , KpiThreshold (..)
  , KpiThresholdId (..)
  )
import Core.Domain.Money (mkMoney)
import Core.Domain.Organisation (Organisation (..), OrganisationId, mkOrganisationId)
import Core.Domain.Partner (PartnerId (..))
import Core.Domain.Project (Project (..), ProjectId (..), ProjectLifecycle (..), ProjectStatus (..))
import Core.Domain.Tenant (TenantId, mkTenantId)
import Core.Error (DomainError (..))
import Core.Event (Event (..))
import Core.Evolve (evolve)
import Core.State (AppBook (..), ManagementAccountingBook (..), initialAppBook)

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

testNow :: UTCTime
testNow = UTCTime testDay (secondsToDiffTime 0)

testProjectId :: ProjectId
testProjectId = ProjectId (mkUUID 1)

-- | 予算100万円のProject (doc/management_accounting.md のユーザー提示例と同じ規模)。
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

{- | 数量1・単価=合計消化額として発注を作る。委託・検収進行度に関わらず
「約定額(committed)+確定額(incurred) = 単価×数量」は不変
(doc/management_accounting.md §0.2 の committed/incurred 定義より) なので、
合計消化額を直接コントロールできる。
-}
orderWithTotal :: Integer -> ExternalOrder
orderWithTotal total =
  ExternalOrder
    { orderId = testOrderId
    , orderProject = testProjectId
    , orderPhase = Nothing
    , orderVendor = vendorPid
    , orderDescription = "テスト発注"
    , orderNature = ExpenseSubcontractCost
    , orderUnitPrice = mkMoney (fromInteger total)
    , orderQuantity = 1
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
    ]

testThresholdId :: KpiThresholdId
testThresholdId = KpiThresholdId (mkUUID 3)

-- | 予算消化率85%警告/100%重大、Project全体スコープ
-- (ユーザー提示例: 「85%消化で予算アラート」)。
testThreshold :: KpiThreshold
testThreshold =
  KpiThreshold
    { ktId = testThresholdId
    , ktTenant = testTenant
    , ktMetric = KpiBudgetConsumptionRate
    , ktScope = KpiScopeProject testProjectId
    , ktWarnAt = 0.8
    , ktCriticalAt = Just 1.0
    , ktEffectiveFrom = testDay
    , ktRetired = False
    }

bookWithThreshold :: AppBook
bookWithThreshold = evolve baseBook (KpiThresholdSet testThreshold)

testAlertId :: BudgetAlertId
testAlertId = BudgetAlertId (mkUUID 4)

-- ── Test tree ────────────────────────────────────────────────────────────────

tests :: TestTree
tests =
  testGroup
    "Core.ManagementAccounting"
    [ testGroup "SetKpiThreshold" setThresholdTests
    , testGroup "RetireKpiThreshold" retireTests
    , testGroup "EvaluateBudgetConsumption" evaluateTests
    , testGroup "Evolve" evolveTests
    ]

-- ── SetKpiThreshold ──────────────────────────────────────────────────────────

setThresholdTests :: [TestTree]
setThresholdTests =
  [ testCase "新規KpiThresholdの設定は成功する" $
      decide baseBook (SetKpiThreshold testThreshold) @?= Right [KpiThresholdSet testThreshold]
  , testCase "重複したKpiThresholdIdはDuplicateKpiThresholdId" $
      case decide bookWithThreshold (SetKpiThreshold testThreshold) of
        Left (DuplicateKpiThresholdId tid) -> tid @?= testThresholdId
        other -> assertFailure ("expected DuplicateKpiThresholdId, got: " <> show other)
  , testCase "ktWarnAtが非正値ならInvalidKpiThresholdValue" $
      case decide baseBook (SetKpiThreshold testThreshold{ktWarnAt = 0}) of
        Left (InvalidKpiThresholdValue _) -> pure ()
        other -> assertFailure ("expected InvalidKpiThresholdValue, got: " <> show other)
  , testCase "ktCriticalAtがktWarnAt以下ならInvalidKpiThresholdValue" $
      case decide baseBook (SetKpiThreshold testThreshold{ktCriticalAt = Just 0.5}) of
        Left (InvalidKpiThresholdValue _) -> pure ()
        other -> assertFailure ("expected InvalidKpiThresholdValue, got: " <> show other)
  ]

-- ── RetireKpiThreshold ───────────────────────────────────────────────────────

retireTests :: [TestTree]
retireTests =
  [ testCase "有効なKpiThresholdは無効化できる" $
      decide bookWithThreshold (RetireKpiThreshold testThresholdId)
        @?= Right [KpiThresholdRetired testThresholdId]
  , testCase "存在しないKpiThresholdの無効化はKpiThresholdNotFound" $
      case decide baseBook (RetireKpiThreshold testThresholdId) of
        Left (KpiThresholdNotFound tid) -> tid @?= testThresholdId
        other -> assertFailure ("expected KpiThresholdNotFound, got: " <> show other)
  , testCase "既に無効化済みの再無効化はKpiThresholdAlreadyRetired" $
      let retiredBook = evolve bookWithThreshold (KpiThresholdRetired testThresholdId)
      in case decide retiredBook (RetireKpiThreshold testThresholdId) of
           Left (KpiThresholdAlreadyRetired tid) -> tid @?= testThresholdId
           other -> assertFailure ("expected KpiThresholdAlreadyRetired, got: " <> show other)
  ]

-- ── EvaluateBudgetConsumption (doc/management_accounting.md §2.1) ───────────

bookAtConsumption :: Integer -> AppBook
bookAtConsumption total =
  foldl' evolve bookWithThreshold [ExternalOrderPlaced (orderWithTotal total)]

evaluateTests :: [TestTree]
evaluateTests =
  [ testCase "閾値未達ならイベントを発生させない" $
      decide (bookAtConsumption 700000) (EvaluateBudgetConsumption testAlertId testProjectId Nothing testNow (Just testOrderId))
        @?= Right []
  , testCase "warn閾値（80%）以上・critical未満ならAlertWarning" $
      case decide (bookAtConsumption 800000) (EvaluateBudgetConsumption testAlertId testProjectId Nothing testNow (Just testOrderId)) of
        Right [BudgetThresholdBreached alert] -> baSeverity alert @?= AlertWarning
        other -> assertFailure ("expected single AlertWarning BudgetThresholdBreached, got: " <> show other)
  , testCase "critical閾値（100%）以上ならAlertCritical" $
      case decide (bookAtConsumption 1000000) (EvaluateBudgetConsumption testAlertId testProjectId Nothing testNow (Just testOrderId)) of
        Right [BudgetThresholdBreached alert] -> baSeverity alert @?= AlertCritical
        other -> assertFailure ("expected single AlertCritical BudgetThresholdBreached, got: " <> show other)
  , testCase "対象スコープに有効な閾値が無ければイベントを発生させない" $
      decide (foldl' evolve baseBook [ExternalOrderPlaced (orderWithTotal 1000000)])
        (EvaluateBudgetConsumption testAlertId testProjectId Nothing testNow (Just testOrderId))
        @?= Right []
  , testCase "予算がゼロのProjectはゼロ除算を起こさずイベントを発生させない" $
      let zeroBudgetProjectId = ProjectId (mkUUID 9)
          zeroBudgetProject = testProject{projectId = zeroBudgetProjectId, projectBudgetTotal = mkMoney 0}
          zeroBudgetThreshold = testThreshold{ktId = KpiThresholdId (mkUUID 10), ktScope = KpiScopeProject zeroBudgetProjectId}
          orgOnlyBook = evolve initialAppBook (OrganisationRegistered (Organisation testOrg "Org One" Nothing True))
          book = foldl' evolve orgOnlyBook [ProjectOpened zeroBudgetProject, KpiThresholdSet zeroBudgetThreshold]
      in decide book (EvaluateBudgetConsumption testAlertId zeroBudgetProjectId Nothing testNow Nothing)
          @?= Right []
  , testCase "存在しないProjectの評価はProjectNotFound" $
      case decide bookWithThreshold (EvaluateBudgetConsumption testAlertId (ProjectId (mkUUID 999)) Nothing testNow Nothing) of
        Left (ProjectNotFound _) -> pure ()
        other -> assertFailure ("expected ProjectNotFound, got: " <> show other)
  ]

-- ── evolve の状態機械 ────────────────────────────────────────────────────────

evolveTests :: [TestTree]
evolveTests =
  [ testCase "KpiThresholdSet後に閾値が読み取れる" $
      Map.lookup testThresholdId (kpiThresholds (appManagementAccounting bookWithThreshold))
        @?= Just testThreshold
  , testCase "KpiThresholdRetired後にktRetiredがTrueになる" $
      let book = evolve bookWithThreshold (KpiThresholdRetired testThresholdId)
      in fmap ktRetired (Map.lookup testThresholdId (kpiThresholds (appManagementAccounting book)))
          @?= Just True
  , testCase "BudgetThresholdBreached後にアラートが読み取れる" $
      let alert =
            BudgetAlert
              { baId = testAlertId
              , baThreshold = testThresholdId
              , baProject = testProjectId
              , baPhase = Nothing
              , baMetricValue = 0.8
              , baSeverity = AlertWarning
              , baDetectedAt = testNow
              , baCausationOrder = Just testOrderId
              }
          book = evolve bookWithThreshold (BudgetThresholdBreached alert)
      in Map.lookup testAlertId (budgetAlerts (appManagementAccounting book)) @?= Just alert
  ]
