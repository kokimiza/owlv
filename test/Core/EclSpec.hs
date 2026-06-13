module Core.EclSpec (tests) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Time (Day (..))
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck

import Data.Map.Strict qualified as Map
import Data.UUID qualified as UUID

import Core.Command (Command (..))
import Core.Decide (decide)
import Core.Domain.AccountCode (mkAccountCode)
import Core.Domain.Ecl
import Core.Domain.Money (mkMoney, zeroMoney)
import Core.Error (DomainError (..))
import Core.Event (Event (..))
import Core.Evolve (evolve)
import Core.State (AppBook (..), EclBook (..), initialAppBook)

-- ── Fixtures ──────────────────────────────────────────────────────────────

testDay :: Day
testDay = ModifiedJulianDay 59000

testMeasId :: EclMeasurementId
testMeasId = EclMeasurementId (UUID.fromWords 0 0 0 1)

testMeas :: EclMeasurement
testMeas =
  EclMeasurement
    { eclMeasId = testMeasId
    , eclMeasDate = testDay
    , eclMeasApproach = SimplifiedApproach
    , eclMeasStage = Nothing
    , eclMeasAccount = case mkAccountCode "1100" of Right a -> a; Left _ -> error "unreachable"
    , eclMeasEntryRef = Nothing
    , eclMeasParams = Nothing
    , eclMeasMatrix = Nothing
    , eclMeasAmount = mkMoney 5_000
    , eclMeasInterestBasis = GrossCarryingAmount
    , eclMeasMemo = ""
    }

-- ── Tests ─────────────────────────────────────────────────────────────────

tests :: TestTree
tests =
  testGroup
    "Core.Ecl"
    [ testGroup "computeEcl" eclCalcTests
    , testGroup "computeProvisionMatrixEcl" matrixTests
    , testGroup "decide.RecordEclMeasurement" eclDecideTests
    , testGroup "evolve.EclBook" eclEvolveTests
    ]

-- ── computeEcl (§4.7.9.1) ─────────────────────────────────────────────────

eclCalcTests :: [TestTree]
eclCalcTests =
  [ testCase "ECL = EAD × PD × LGD × DF" $ do
      let params =
            EclParams
              { eclEad = mkMoney 1_000_000
              , eclPd = 0.05
              , eclLgd = 0.40
              , eclDf = 0.98
              , eclPdHorizon = Pd12Month
              }
      -- 1,000,000 × 0.05 × 0.40 × 0.98 = 19,600
      computeEcl params @?= mkMoney 19_600
  , testCase "PD=0 → ECL=0" $ do
      let params = EclParams (mkMoney 1_000_000) 0 0.5 1.0 Pd12Month
      computeEcl params @?= zeroMoney
  , testCase "LGD=0 → ECL=0" $ do
      let params = EclParams (mkMoney 1_000_000) 0.1 0 1.0 Pd12Month
      computeEcl params @?= zeroMoney
  , testProperty "EAD=0 → ECL=0 (任意パラメータ)" $
      \(Positive (pd :: Int)) (Positive (lgd :: Int)) (Positive (df :: Int)) ->
        let params =
              EclParams
                zeroMoney
                (fromIntegral (pd `mod` 100) / 100)
                (fromIntegral (lgd `mod` 100) / 100)
                (fromIntegral (df `mod` 100) / 100)
                Pd12Month
        in computeEcl params == zeroMoney
  , testProperty "ECL は非負" $
      \(Positive (ead :: Int)) (Positive (pd :: Int)) (Positive (lgd :: Int)) (Positive (df :: Int)) ->
        let params =
              EclParams
                (mkMoney (fromIntegral ead))
                (fromIntegral (pd `mod` 100) / 100)
                (fromIntegral (lgd `mod` 100) / 100)
                (fromIntegral (df `mod` 100) / 100)
                Pd12Month
        in computeEcl params >= zeroMoney
  , testProperty "DF=1 のとき割引なし: ECL = EAD × PD × LGD" $
      \(Positive (ead :: Int)) (Positive (pd :: Int)) (Positive (lgd :: Int)) ->
        let ead' = fromIntegral (ead `mod` 1_000_000)
            pd' = fromIntegral (pd `mod` 100) / 100
            lgd' = fromIntegral (lgd `mod` 100) / 100
            params = EclParams (mkMoney ead') pd' lgd' 1.0 Pd12Month
            expected = mkMoney (ead' * pd' * lgd')
        in computeEcl params == expected
  ]

-- ── computeProvisionMatrixEcl (§4.7.6.2) ──────────────────────────────────

matrixTests :: [TestTree]
matrixTests =
  [ testCase "単一バケット: 残高 × 損失率" $ do
      let bucket = ProvisionBucket Current 0.01 (mkMoney 500_000)
          matrix = ProvisionMatrix (bucket :| [])
      computeProvisionMatrixEcl matrix @?= mkMoney 5_000
  , testCase "複数バケット: 合計が正しい" $ do
      let b1 = ProvisionBucket Current 0.01 (mkMoney 1_000_000) -- 10,000
          b2 = ProvisionBucket DaysOverdue1To30 0.03 (mkMoney 200_000) -- 6,000
          b3 = ProvisionBucket DaysOverdue90Plus 0.50 (mkMoney 50_000) -- 25,000
          matrix = ProvisionMatrix (b1 :| [b2, b3])
      computeProvisionMatrixEcl matrix @?= mkMoney 41_000
  , testCase "損失率=0 → ECL=0" $ do
      let bucket = ProvisionBucket Current 0.0 (mkMoney 999_999)
          matrix = ProvisionMatrix (bucket :| [])
      computeProvisionMatrixEcl matrix @?= zeroMoney
  , testProperty "残高=0 → バケット寄与 = 0" $
      \(Positive (rate :: Int)) ->
        let bucket = ProvisionBucket Current (fromIntegral (rate `mod` 100) / 100) zeroMoney
            matrix = ProvisionMatrix (bucket :| [])
        in computeProvisionMatrixEcl matrix == zeroMoney
  , testProperty "ECLは非負" $
      \(Positive (exposure :: Int)) (Positive (lossRate :: Int)) ->
        let bucket =
              ProvisionBucket
                Current
                (fromIntegral (lossRate `mod` 100) / 100)
                (mkMoney (fromIntegral (exposure `mod` 10_000_000)))
            matrix = ProvisionMatrix (bucket :| [])
        in computeProvisionMatrixEcl matrix >= zeroMoney
  ]

-- ── decide.RecordEclMeasurement (§4.7.12) ────────────────────────────────

eclDecideTests :: [TestTree]
eclDecideTests =
  [ testCase "正常な ECL 測定を受理する" $
      decide initialAppBook (RecordEclMeasurement testMeas)
        @?= Right [EclMeasurementRecorded testMeas]
  , testCase "重複IDは DuplicateEclMeasurement" $ do
      let book = evolve initialAppBook (EclMeasurementRecorded testMeas)
      case decide book (RecordEclMeasurement testMeas) of
        Left (DuplicateEclMeasurement _) -> pure ()
        other -> assertFailure ("expected DuplicateEclMeasurement, got: " <> show other)
  , testCase "負の ECL 額は NegativeEclAmount" $ do
      let m = testMeas{eclMeasAmount = mkMoney (-1)}
      case decide initialAppBook (RecordEclMeasurement m) of
        Left (NegativeEclAmount _ _) -> pure ()
        other -> assertFailure ("expected NegativeEclAmount, got: " <> show other)
  , testCase "ゼロ ECL 額は受理する（簡便法で ECL=0 は正常）" $ do
      let m = testMeas{eclMeasId = EclMeasurementId (UUID.fromWords 0 0 0 2), eclMeasAmount = zeroMoney}
      case decide initialAppBook (RecordEclMeasurement m) of
        Right [EclMeasurementRecorded _] -> pure ()
        other -> assertFailure ("expected success, got: " <> show other)
  ]

-- ── evolve.EclBook ────────────────────────────────────────────────────────

eclEvolveTests :: [TestTree]
eclEvolveTests =
  [ testCase "EclMeasurementRecorded: EclBook に登録される" $ do
      let book = evolve initialAppBook (EclMeasurementRecorded testMeas)
      assertBool "meas present" (Map.member testMeasId (eclMeasurements (appEcl book)))
  , testCase "EclMeasurementRecorded: 2件登録でサイズ 2" $ do
      let m2 = testMeas{eclMeasId = EclMeasurementId (UUID.fromWords 0 0 0 2)}
          book = foldl' evolve initialAppBook [EclMeasurementRecorded testMeas, EclMeasurementRecorded m2]
      Map.size (eclMeasurements (appEcl book)) @?= 2
  ]
