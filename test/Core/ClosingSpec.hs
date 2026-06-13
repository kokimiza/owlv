module Core.ClosingSpec (tests) where

import Data.Time (Day (..))
import Data.Word (Word32)
import Test.Tasty
import Test.Tasty.HUnit

import Data.Map.Strict qualified as Map
import Data.UUID qualified as UUID

import Core.Command (Command (..))
import Core.Decide (decide)
import Core.Domain.AccountingPeriod (AccountingPeriodId (..))
import Core.Domain.EmployeeBenefit
  ( BenefitLiability (..)
  , BenefitLiabilityId (..)
  , EmployeeBenefitType (..)
  )
import Core.Domain.Money (mkMoney, zeroMoney)
import Core.Domain.Tax
  ( TaxEntry (..)
  , TaxEntryId (..)
  , computeCurrentTax
  )
import Core.Error (DomainError (..))
import Core.Event (Event (..))
import Core.Evolve (evolve)
import Core.State (AppBook (..), BenefitBook (..), TaxBook (..), initialAppBook)

-- ── Fixtures ──────────────────────────────────────────────────────────────────

testDay :: Day
testDay = ModifiedJulianDay 59000

testPeriod :: AccountingPeriodId
testPeriod = AccountingPeriodId 2026 1

mkBId :: Word32 -> BenefitLiabilityId
mkBId n = BenefitLiabilityId (UUID.fromWords 0 0 0 n)

mkTId :: Word32 -> TaxEntryId
mkTId n = TaxEntryId (UUID.fromWords 0 0 0 n)

b1 :: BenefitLiability
b1 =
  BenefitLiability
    { blId = mkBId 1
    , blType = Bonus
    , blPeriod = testPeriod
    , blDate = testDay
    , blLiabilityAmount = mkMoney 500_000
    , blServiceCost = Nothing
    , blInterestCost = Nothing
    , blRemeasurementOci = Nothing
    , blVacationAccrualType = Nothing
    , blDiscountRate = Nothing
    , blMemo = ""
    }

-- | ETR 30%、累計税引前利益 1,000,000、前月累計 200,000
t1 :: TaxEntry
t1 =
  TaxEntry
    { teId = mkTId 1
    , tePeriod = testPeriod
    , teDate = testDay
    , teEstimatedEffectiveTaxRate = 0.30
    , teCumulativePretaxIncome = mkMoney 1_000_000
    , tePriorCumulativeTaxCharge = mkMoney 200_000
    , teCurrentPeriodTaxCharge = mkMoney 100_000
    , teDeferredTaxAsset = zeroMoney
    , teDeferredTaxLiability = zeroMoney
    , teTemporaryDifferences = []
    , teEtrBasis = "前年実績 + 経営計画"
    , teMemo = ""
    }

-- ── Tests ─────────────────────────────────────────────────────────────────────

tests :: TestTree
tests =
  testGroup
    "Core.Closing"
    [ testGroup "BenefitLiability" benefitTests
    , testGroup "TaxEntry" taxTests
    , testGroup "computeCurrentTax" computeTaxTests
    ]

-- ── BenefitLiability (§4.7.15 / IAS 19) ─────────────────────────────────────

benefitTests :: [TestTree]
benefitTests =
  [ testCase "正の給付負債額を受理する" $
      decide initialAppBook (RecordBenefitLiability b1) @?= Right [BenefitLiabilityRecorded b1]
  , testCase "ゼロの給付負債額を受理する（非負条件）" $ do
      let b = b1{blId = mkBId 2, blLiabilityAmount = zeroMoney}
      decide initialAppBook (RecordBenefitLiability b) @?= Right [BenefitLiabilityRecorded b]
  , testCase "負の給付負債額は EmptyMasterField" $ do
      let b = b1{blId = mkBId 3, blLiabilityAmount = mkMoney (-1)}
      case decide initialAppBook (RecordBenefitLiability b) of
        Left (EmptyMasterField _) -> pure ()
        other -> assertFailure ("expected EmptyMasterField, got: " <> show other)
  , testCase "BenefitLiabilityRecorded: BenefitBook に登録される" $ do
      let book = evolve initialAppBook (BenefitLiabilityRecorded b1)
      assertBool "benefit present" (Map.member (blId b1) (benefitLiabilities (appBenefits book)))
  ]

-- ── TaxEntry (§4.7.16 / IAS 12) ──────────────────────────────────────────────

taxTests :: [TestTree]
taxTests =
  [ testCase "ETR=0 を受理する（下限境界値）" $ do
      let t = t1{teId = mkTId 2, teEstimatedEffectiveTaxRate = 0}
      case decide initialAppBook (RecordTaxEntry t) of
        Right [TaxEntryRecorded _] -> pure ()
        other -> assertFailure ("expected success, got: " <> show other)
  , testCase "ETR=1 を受理する（上限境界値）" $ do
      let t = t1{teId = mkTId 3, teEstimatedEffectiveTaxRate = 1}
      case decide initialAppBook (RecordTaxEntry t) of
        Right [TaxEntryRecorded _] -> pure ()
        other -> assertFailure ("expected success, got: " <> show other)
  , testCase "ETR=0.30 を受理する（通常ケース）" $
      decide initialAppBook (RecordTaxEntry t1) @?= Right [TaxEntryRecorded t1]
  , testCase "ETR が負値は EmptyMasterField" $ do
      let t = t1{teId = mkTId 4, teEstimatedEffectiveTaxRate = negate 0.01}
      case decide initialAppBook (RecordTaxEntry t) of
        Left (EmptyMasterField _) -> pure ()
        other -> assertFailure ("expected EmptyMasterField, got: " <> show other)
  , testCase "ETR > 1 は EmptyMasterField" $ do
      let t = t1{teId = mkTId 5, teEstimatedEffectiveTaxRate = 1.01}
      case decide initialAppBook (RecordTaxEntry t) of
        Left (EmptyMasterField _) -> pure ()
        other -> assertFailure ("expected EmptyMasterField, got: " <> show other)
  , testCase "TaxEntryRecorded: TaxBook に登録される" $ do
      let book = evolve initialAppBook (TaxEntryRecorded t1)
      assertBool "tax entry present" (Map.member (teId t1) (taxEntries (appTax book)))
  ]

-- ── computeCurrentTax (§4.7.16.1) ────────────────────────────────────────────

computeTaxTests :: [TestTree]
computeTaxTests =
  [ testCase "当月税金費用 = 累計税引前利益 × ETR - 前月累計" $
      -- 1,000,000 × 0.30 - 200,000 = 100,000
      computeCurrentTax 0.30 (mkMoney 1_000_000) (mkMoney 200_000) @?= mkMoney 100_000
  , testCase "ETR=0 のとき当月計上額はゼロ" $
      computeCurrentTax 0 (mkMoney 1_000_000) zeroMoney @?= zeroMoney
  , testCase "前月累計 = 累計税金のとき当月計上額はゼロ" $
      -- 1,000,000 × 0.30 = 300,000 = 前月累計 → 当月 0
      computeCurrentTax 0.30 (mkMoney 1_000_000) (mkMoney 300_000) @?= zeroMoney
  , testCase "ETR改定による累計補正：繰戻しが発生する場合は負値を返す" $
      -- 300,000 × 0.30 = 90,000、前月累計100,000 → 当月 -10,000
      computeCurrentTax 0.30 (mkMoney 300_000) (mkMoney 100_000) @?= mkMoney (-10_000)
  ]
