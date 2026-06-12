module Core.FixedAssetSpec (tests) where

import Data.Time (Day (..))
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck

import Data.Map.Strict qualified as Map

import Core.Command (Command (..))
import Core.Decide (decide)
import Core.Domain.AccountCode (AccountCode, mkAccountCode)
import Core.Domain.FixedAsset
import Core.Domain.Money (mkMoney, zeroMoney)
import Core.Error (DomainError (..))
import Core.Event (Event (..))
import Core.Evolve (evolve)
import Core.State (AppBook (..), AssetBook (..), initialAppBook)

-- ── Fixtures ──────────────────────────────────────────────────────────────

testDay :: Day
testDay = ModifiedJulianDay 59000

acCode :: AccountCode
acCode = case mkAccountCode "1610" of Right a -> a; Left _ -> error "unreachable"

mkAsset :: FixedAssetId -> ComponentId -> MeasurementModel -> FixedAsset
mkAsset aid cid model =
  FixedAsset
    { faId = aid
    , faComponent = cid
    , faAccount = acCode
    , faCategory = TangibleFixedAsset
    , faCgu = Nothing
    , faAcquisitionDate = testDay
    , faMeasurementModel = model
    , faUsefulLifeMonths = 60
    , faResidualValue = mkMoney 0
    , faDepreciationMethod = StraightLine
    , faGrossAmount = mkMoney 1_000_000
    , faAccumDepreciation = zeroMoney
    , faImpairmentCumulative = zeroMoney
    , faImpairmentReversalCumulative = zeroMoney
    , faRevalSurplusCumulative = zeroMoney
    , faDisposalDate = Nothing
    }

aid1 :: FixedAssetId
aid1 = FixedAssetId "A-001"

cid1 :: ComponentId
cid1 = ComponentId "C-001"

fa1 :: FixedAsset
fa1 = mkAsset aid1 cid1 CostModel

bookWithAsset :: AppBook
bookWithAsset = evolve initialAppBook (FixedAssetRegistered fa1)

-- ── Tests ─────────────────────────────────────────────────────────────────

tests :: TestTree
tests =
  testGroup
    "Core.FixedAsset"
    [ testGroup "carryingAmount" caTests
    , testGroup "decide" decideTests
    , testGroup "evolve" evolveTests
    ]

-- ── carryingAmount ─────────────────────────────────────────────────────────

caTests :: [TestTree]
caTests =
  [ testProperty "新規資産は帳簿価額 = 取得原価" $
      \(Positive gross) ->
        let fa = fa1{faGrossAmount = mkMoney (fromInteger gross)}
        in carryingAmount fa == mkMoney (fromInteger gross)
  , testProperty "償却後の帳簿価額 = 取得原価 - 累計償却額" $
      \(Positive gross) (Positive dep) ->
        let g = fromInteger gross
            d = fromInteger dep
        in d < g ==>
             let fa =
                   fa1
                     { faGrossAmount = mkMoney g
                     , faAccumDepreciation = mkMoney d
                     }
             in carryingAmount fa == mkMoney (g - d)
  , testCase "減損後の帳簿価額は (取得原価 - 償却 - 減損) に等しい" $ do
      let fa =
            fa1
              { faGrossAmount = mkMoney 1_000_000
              , faAccumDepreciation = mkMoney 200_000
              , faImpairmentCumulative = mkMoney 100_000
              }
      carryingAmount fa @?= mkMoney 700_000
  , testCase "戻入後の帳簿価額は戻入分だけ増加する" $ do
      let fa =
            fa1
              { faGrossAmount = mkMoney 1_000_000
              , faImpairmentCumulative = mkMoney 300_000
              , faImpairmentReversalCumulative = mkMoney 100_000
              }
      carryingAmount fa @?= mkMoney 800_000
  ]

-- ── decide ────────────────────────────────────────────────────────────────

decideTests :: [TestTree]
decideTests =
  [ testCase "RegisterFixedAsset: 新規資産を受理する" $ do
      let result = decide initialAppBook (RegisterFixedAsset fa1)
      result @?= Right [FixedAssetRegistered fa1]
  , testCase "RegisterFixedAsset: 重複IDは拒否する" $ do
      let result = decide bookWithAsset (RegisterFixedAsset fa1)
      result @?= Left (DuplicateFixedAsset aid1 cid1)
  , testCase "RegisterFixedAsset: 取得原価ゼロは拒否する" $ do
      let fa = fa1{faGrossAmount = zeroMoney}
      case decide initialAppBook (RegisterFixedAsset fa) of
        Left (EmptyMasterField _) -> pure ()
        other -> assertFailure ("expected EmptyMasterField, got: " <> show other)
  , testCase "RecordDepreciation: 正常な償却を受理する" $ do
      let result = decide bookWithAsset (RecordDepreciation aid1 cid1 testDay (mkMoney 16_667))
      result @?= Right [DepreciationRecorded aid1 cid1 testDay (mkMoney 16_667)]
  , testCase "RecordDepreciation: 存在しない資産は拒否する" $ do
      let ghost = FixedAssetId "GHOST"
      case decide initialAppBook (RecordDepreciation ghost cid1 testDay (mkMoney 100)) of
        Left (FixedAssetNotFound _ _) -> pure ()
        other -> assertFailure ("expected FixedAssetNotFound, got: " <> show other)
  , testCase "RecordDepreciation: 帳簿価額超の償却は拒否する" $ do
      let fa = fa1{faGrossAmount = mkMoney 1_000, faResidualValue = zeroMoney}
          book = evolve initialAppBook (FixedAssetRegistered fa)
          result = decide book (RecordDepreciation aid1 cid1 testDay (mkMoney 2_000))
      case result of
        Left (DepreciationExceedsCarryingAmount _ _ _ _) -> pure ()
        other -> assertFailure ("expected DepreciationExceedsCarryingAmount, got: " <> show other)
  , testCase "RecordImpairment: 減損損失を受理する" $ do
      let result = decide bookWithAsset (RecordImpairment aid1 cid1 testDay (mkMoney 200_000) (mkMoney 800_000))
      result @?= Right [ImpairmentRecognized aid1 cid1 testDay (mkMoney 200_000) (mkMoney 800_000)]
  , testCase "RecordImpairment: 帳簿価額超の減損は拒否する" $ do
      let result = decide bookWithAsset (RecordImpairment aid1 cid1 testDay (mkMoney 2_000_000) (mkMoney 0))
      case result of
        Left (ImpairmentExceedsCarryingAmount _ _ _ _) -> pure ()
        other -> assertFailure ("expected ImpairmentExceedsCarryingAmount, got: " <> show other)
  , testCase "RevaluateAsset: 原価モデルへの再評価は拒否する" $ do
      let result = decide bookWithAsset (RevaluateAsset aid1 cid1 testDay (mkMoney 1_200_000) (mkMoney 200_000))
      result @?= Left (RevaluationNotAllowedForCostModel aid1 cid1)
  , testCase "RevaluateAsset: 再評価モデルへの再評価を受理する" $ do
      let faReval = mkAsset aid1 cid1 RevaluationModel
          book = evolve initialAppBook (FixedAssetRegistered faReval)
          result = decide book (RevaluateAsset aid1 cid1 testDay (mkMoney 1_200_000) (mkMoney 200_000))
      result @?= Right [AssetRevalued aid1 cid1 testDay (mkMoney 1_200_000) (mkMoney 200_000)]
  , testCase "DisposeFixedAsset: 資産の除却を受理する" $ do
      let result = decide bookWithAsset (DisposeFixedAsset aid1 cid1 testDay)
      result @?= Right [FixedAssetDisposed aid1 cid1 testDay]
  , testCase "DisposeFixedAsset: 除却済み資産への操作は拒否する" $ do
      let book = evolve bookWithAsset (FixedAssetDisposed aid1 cid1 testDay)
      case decide book (DisposeFixedAsset aid1 cid1 (ModifiedJulianDay 59001)) of
        Left (FixedAssetAlreadyDisposed _ _) -> pure ()
        other -> assertFailure ("expected FixedAssetAlreadyDisposed, got: " <> show other)
  ]

-- ── evolve ────────────────────────────────────────────────────────────────

evolveTests :: [TestTree]
evolveTests =
  [ testCase "FixedAssetRegistered: 資産台帳に挿入される" $ do
      let book = evolve initialAppBook (FixedAssetRegistered fa1)
      assertBool "asset inserted" (Map.member (aid1, cid1) (fixedAssets (appAssets book)))
  , testCase "DepreciationRecorded: 累計償却額が加算される" $ do
      let book = evolve bookWithAsset (DepreciationRecorded aid1 cid1 testDay (mkMoney 16_667))
          fa = fixedAssets (appAssets book) Map.! (aid1, cid1)
      faAccumDepreciation fa @?= mkMoney 16_667
  , testCase "ImpairmentRecognized: 減損損失累計が加算される" $ do
      let book = evolve bookWithAsset (ImpairmentRecognized aid1 cid1 testDay (mkMoney 100_000) (mkMoney 900_000))
          fa = fixedAssets (appAssets book) Map.! (aid1, cid1)
      faImpairmentCumulative fa @?= mkMoney 100_000
  , testCase "AssetRevalued: 総額更新・累計償却リセット・再評価差額累積" $ do
      let fa0 = (mkAsset aid1 cid1 RevaluationModel){faAccumDepreciation = mkMoney 200_000}
          book =
            evolve
              (evolve initialAppBook (FixedAssetRegistered fa0))
              (AssetRevalued aid1 cid1 testDay (mkMoney 1_200_000) (mkMoney 400_000))
          fa = fixedAssets (appAssets book) Map.! (aid1, cid1)
      faGrossAmount fa @?= mkMoney 1_200_000
      faAccumDepreciation fa @?= zeroMoney
      faRevalSurplusCumulative fa @?= mkMoney 400_000
  , testCase "FixedAssetDisposed: active=False, 除却日が記録される" $ do
      let book = evolve bookWithAsset (FixedAssetDisposed aid1 cid1 testDay)
          fa = fixedAssets (appAssets book) Map.! (aid1, cid1)
      faDisposalDate fa @?= Just testDay
  , testProperty "フォールド決定論: 同一イベント列 → 同一状態" $
      \(n :: Int) ->
        let evts = replicate (abs n `mod` 5) (FixedAssetRegistered fa1)
            book1 = foldl' evolve initialAppBook evts
            book2 = foldl' evolve initialAppBook evts
        in book1 == book2
  ]
