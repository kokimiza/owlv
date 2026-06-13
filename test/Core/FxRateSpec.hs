module Core.FxRateSpec (tests) where

import Data.Time (Day (..))
import Data.Word (Word32)
import Test.Tasty
import Test.Tasty.HUnit

import Data.Map.Strict qualified as Map
import Data.UUID qualified as UUID

import Core.Command (Command (..))
import Core.Decide (decide)
import Core.Domain.FxRate
  ( CurrencyCode (..)
  , ExchangeRateType (..)
  , FxRate (..)
  , FxRateId (..)
  )
import Core.Error (DomainError (..))
import Core.Event (Event (..))
import Core.Evolve (evolve)
import Core.State (AppBook (..), FxBook (..), initialAppBook)

-- ── Fixtures ──────────────────────────────────────────────────────────────────

testDay :: Day
testDay = ModifiedJulianDay 59000

mkId :: Word32 -> FxRateId
mkId n = FxRateId (UUID.fromWords 0 0 0 n)

usd :: CurrencyCode
usd = CurrencyCode "USD"

jpy :: CurrencyCode
jpy = CurrencyCode "JPY"

-- | 有効な USD/JPY 基本レート
r1 :: FxRate
r1 =
  FxRate
    { fxRateId = mkId 1
    , fxBaseCurrency = usd
    , fxQuoteCurrency = jpy
    , fxRate = 150
    , fxRateType = ClosingRate
    , fxRateDate = testDay
    , fxRateSource = "Reuters"
    , fxRateMemo = ""
    }

-- ── Tests ─────────────────────────────────────────────────────────────────────

tests :: TestTree
tests =
  testGroup
    "Core.FxRate"
    [ testGroup "decide" decideTests
    , testGroup "evolve" evolveTests
    ]

-- ── decide ────────────────────────────────────────────────────────────────────

decideTests :: [TestTree]
decideTests =
  [ testCase "有効な為替レートを受理する" $
      decide initialAppBook (RecordFxRate r1) @?= Right [FxRateRecorded r1]
  , testCase "重複IDは DuplicateFxRate" $ do
      let book = evolve initialAppBook (FxRateRecorded r1)
      case decide book (RecordFxRate r1) of
        Left (DuplicateFxRate _) -> pure ()
        other -> assertFailure ("expected DuplicateFxRate, got: " <> show other)
  , testCase "換算元通貨コードが空は EmptyMasterField" $ do
      let r = r1{fxRateId = mkId 2, fxBaseCurrency = CurrencyCode ""}
      case decide initialAppBook (RecordFxRate r) of
        Left (EmptyMasterField _) -> pure ()
        other -> assertFailure ("expected EmptyMasterField, got: " <> show other)
  , testCase "換算先通貨コードが空は EmptyMasterField" $ do
      let r = r1{fxRateId = mkId 3, fxQuoteCurrency = CurrencyCode ""}
      case decide initialAppBook (RecordFxRate r) of
        Left (EmptyMasterField _) -> pure ()
        other -> assertFailure ("expected EmptyMasterField, got: " <> show other)
  , testCase "換算元通貨が2文字は InvalidCurrencyCode" $ do
      let r = r1{fxRateId = mkId 4, fxBaseCurrency = CurrencyCode "US"}
      case decide initialAppBook (RecordFxRate r) of
        Left (InvalidCurrencyCode "US") -> pure ()
        other -> assertFailure ("expected InvalidCurrencyCode \"US\", got: " <> show other)
  , testCase "換算先通貨が4文字は InvalidCurrencyCode" $ do
      let r = r1{fxRateId = mkId 5, fxQuoteCurrency = CurrencyCode "JPYY"}
      case decide initialAppBook (RecordFxRate r) of
        Left (InvalidCurrencyCode "JPYY") -> pure ()
        other -> assertFailure ("expected InvalidCurrencyCode \"JPYY\", got: " <> show other)
  , testCase "為替レートがゼロは NonPositiveFxRate" $ do
      let r = r1{fxRateId = mkId 6, fxRate = 0}
      case decide initialAppBook (RecordFxRate r) of
        Left (NonPositiveFxRate _) -> pure ()
        other -> assertFailure ("expected NonPositiveFxRate, got: " <> show other)
  , testCase "為替レートが負値は NonPositiveFxRate" $ do
      let r = r1{fxRateId = mkId 7, fxRate = negate 1}
      case decide initialAppBook (RecordFxRate r) of
        Left (NonPositiveFxRate _) -> pure ()
        other -> assertFailure ("expected NonPositiveFxRate, got: " <> show other)
  ]

-- ── evolve ────────────────────────────────────────────────────────────────────

evolveTests :: [TestTree]
evolveTests =
  [ testCase "FxRateRecorded: FxBook に登録される" $ do
      let book = evolve initialAppBook (FxRateRecorded r1)
      assertBool "rate present" (Map.member (fxRateId r1) (fxRates (appFx book)))
  , testCase "FxRateRecorded: 2件登録でサイズ 2" $ do
      let r2 = r1{fxRateId = mkId 2, fxBaseCurrency = CurrencyCode "EUR"}
          book = foldl' evolve initialAppBook [FxRateRecorded r1, FxRateRecorded r2]
      Map.size (fxRates (appFx book)) @?= 2
  ]
