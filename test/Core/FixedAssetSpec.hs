module Core.FixedAssetSpec (tests) where

import Data.Time (Day (..))
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck

import Data.Map.Strict qualified as Map

import Core.Command (Command (..))
import Core.Decide (decide)
import Core.Domain.AccountCode (AccountCode, mkAccountCode)
import Core.Domain.AccountingPeriod (periodIdOf)
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

-- | 除却済み資産を持つ AppBook
disposedBook :: AppBook
disposedBook = evolve bookWithAsset (FixedAssetDisposed aid1 cid1 testDay)

-- | 減損認識済み資産を持つ AppBook (累計減損 200,000)
impairedBook :: AppBook
impairedBook = evolve bookWithAsset (ImpairmentRecognized aid1 cid1 testDay (mkMoney 200_000) (mkMoney 800_000))

-- | クローズ済み期間を持つ AppBook (bookWithAsset ベース)
closedBook :: AppBook
closedBook =
  let pid = periodIdOf testDay
  in foldl' evolve bookWithAsset [AccountingPeriodOpened pid, AccountingPeriodClosed pid]

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
  , testCase "減損後の帳簿価額は (取得原価 - 償却 - 減損)" $ do
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
  [ -- RegisterFixedAsset
    testCase "RegisterFixedAsset: 新規資産を受理する" $
      decide initialAppBook (RegisterFixedAsset fa1) @?= Right [FixedAssetRegistered fa1]
  , testCase "RegisterFixedAsset: 重複IDは DuplicateFixedAsset" $
      decide bookWithAsset (RegisterFixedAsset fa1) @?= Left (DuplicateFixedAsset aid1 cid1)
  , testCase "RegisterFixedAsset: 取得原価ゼロは EmptyMasterField" $ do
      let fa = fa1{faGrossAmount = zeroMoney}
      case decide initialAppBook (RegisterFixedAsset fa) of
        Left (EmptyMasterField _) -> pure ()
        other -> assertFailure ("expected EmptyMasterField, got: " <> show other)
  , testCase "RegisterFixedAsset: 空の資産IDは EmptyMasterField" $ do
      let fa = fa1{faId = FixedAssetId ""}
      case decide initialAppBook (RegisterFixedAsset fa) of
        Left (EmptyMasterField _) -> pure ()
        other -> assertFailure ("expected EmptyMasterField, got: " <> show other)
  , testCase "RegisterFixedAsset: 空のコンポーネントIDは EmptyMasterField" $ do
      let fa = fa1{faComponent = ComponentId ""}
      case decide initialAppBook (RegisterFixedAsset fa) of
        Left (EmptyMasterField _) -> pure ()
        other -> assertFailure ("expected EmptyMasterField, got: " <> show other)
  , -- RecordDepreciation
    testCase "RecordDepreciation: 正常な償却を受理する" $
      decide bookWithAsset (RecordDepreciation aid1 cid1 testDay (mkMoney 16_667))
        @?= Right [DepreciationRecorded aid1 cid1 testDay (mkMoney 16_667)]
  , testCase "RecordDepreciation: 存在しない資産は FixedAssetNotFound" $ do
      case decide initialAppBook (RecordDepreciation (FixedAssetId "GHOST") cid1 testDay (mkMoney 100)) of
        Left (FixedAssetNotFound _ _) -> pure ()
        other -> assertFailure ("expected FixedAssetNotFound, got: " <> show other)
  , testCase "RecordDepreciation: 帳簿価額超の償却は DepreciationExceedsCarryingAmount" $ do
      let fa = fa1{faGrossAmount = mkMoney 1_000, faResidualValue = zeroMoney}
          book = evolve initialAppBook (FixedAssetRegistered fa)
      case decide book (RecordDepreciation aid1 cid1 testDay (mkMoney 2_000)) of
        Left (DepreciationExceedsCarryingAmount _ _ _ _) -> pure ()
        other -> assertFailure ("expected DepreciationExceedsCarryingAmount, got: " <> show other)
  , testCase "RecordDepreciation: 償却額ゼロは EmptyMasterField" $ do
      case decide bookWithAsset (RecordDepreciation aid1 cid1 testDay zeroMoney) of
        Left (EmptyMasterField _) -> pure ()
        other -> assertFailure ("expected EmptyMasterField, got: " <> show other)
  , testCase "RecordDepreciation: クローズ済み期間は PeriodClosed" $ do
      case decide closedBook (RecordDepreciation aid1 cid1 testDay (mkMoney 100)) of
        Left (PeriodClosed _) -> pure ()
        other -> assertFailure ("expected PeriodClosed, got: " <> show other)
  , testCase "RecordDepreciation: 除却済み資産は FixedAssetAlreadyDisposed" $ do
      case decide disposedBook (RecordDepreciation aid1 cid1 testDay (mkMoney 100)) of
        Left (FixedAssetAlreadyDisposed _ _) -> pure ()
        other -> assertFailure ("expected FixedAssetAlreadyDisposed, got: " <> show other)
  , -- RecordImpairment
    testCase "RecordImpairment: 減損損失を受理する" $
      decide bookWithAsset (RecordImpairment aid1 cid1 testDay (mkMoney 200_000) (mkMoney 800_000))
        @?= Right [ImpairmentRecognized aid1 cid1 testDay (mkMoney 200_000) (mkMoney 800_000)]
  , testCase "RecordImpairment: 帳簿価額超の減損は ImpairmentExceedsCarryingAmount" $ do
      case decide bookWithAsset (RecordImpairment aid1 cid1 testDay (mkMoney 2_000_000) (mkMoney 0)) of
        Left (ImpairmentExceedsCarryingAmount _ _ _ _) -> pure ()
        other -> assertFailure ("expected ImpairmentExceedsCarryingAmount, got: " <> show other)
  , testCase "RecordImpairment: 減損額ゼロは EmptyMasterField" $ do
      case decide bookWithAsset (RecordImpairment aid1 cid1 testDay zeroMoney (mkMoney 1_000_000)) of
        Left (EmptyMasterField _) -> pure ()
        other -> assertFailure ("expected EmptyMasterField, got: " <> show other)
  , testCase "RecordImpairment: クローズ済み期間は PeriodClosed" $ do
      case decide closedBook (RecordImpairment aid1 cid1 testDay (mkMoney 100_000) (mkMoney 900_000)) of
        Left (PeriodClosed _) -> pure ()
        other -> assertFailure ("expected PeriodClosed, got: " <> show other)
  , testCase "RecordImpairment: 除却済み資産は FixedAssetAlreadyDisposed" $ do
      case decide disposedBook (RecordImpairment aid1 cid1 testDay (mkMoney 100_000) (mkMoney 900_000)) of
        Left (FixedAssetAlreadyDisposed _ _) -> pure ()
        other -> assertFailure ("expected FixedAssetAlreadyDisposed, got: " <> show other)
  , -- RecordImpairmentReversal
    testCase "RecordImpairmentReversal: 正常な戻入を受理する" $
      -- 累計減損 200,000 のうち 100,000 を戻入
      decide impairedBook (RecordImpairmentReversal aid1 cid1 testDay (mkMoney 100_000))
        @?= Right [ImpairmentReversalRecognized aid1 cid1 testDay (mkMoney 100_000)]
  , testCase "RecordImpairmentReversal: 累計減損超の戻入は ImpairmentReversalExceedsCumulative" $ do
      -- 累計減損 200,000 に対して 300,000 の戻入は不可
      case decide impairedBook (RecordImpairmentReversal aid1 cid1 testDay (mkMoney 300_000)) of
        Left (ImpairmentReversalExceedsCumulative _ _ _ _) -> pure ()
        other -> assertFailure ("expected ImpairmentReversalExceedsCumulative, got: " <> show other)
  , testCase "RecordImpairmentReversal: 戻入額ゼロは EmptyMasterField" $ do
      case decide impairedBook (RecordImpairmentReversal aid1 cid1 testDay zeroMoney) of
        Left (EmptyMasterField _) -> pure ()
        other -> assertFailure ("expected EmptyMasterField, got: " <> show other)
  , testCase "RecordImpairmentReversal: クローズ済み期間は PeriodClosed" $ do
      let pid = periodIdOf testDay
          book = foldl' evolve impairedBook [AccountingPeriodOpened pid, AccountingPeriodClosed pid]
      case decide book (RecordImpairmentReversal aid1 cid1 testDay (mkMoney 50_000)) of
        Left (PeriodClosed _) -> pure ()
        other -> assertFailure ("expected PeriodClosed, got: " <> show other)
  , testCase "RecordImpairmentReversal: 除却済み資産は FixedAssetAlreadyDisposed" $ do
      case decide disposedBook (RecordImpairmentReversal aid1 cid1 testDay (mkMoney 50_000)) of
        Left (FixedAssetAlreadyDisposed _ _) -> pure ()
        other -> assertFailure ("expected FixedAssetAlreadyDisposed, got: " <> show other)
  , -- RevaluateAsset
    testCase "RevaluateAsset: 原価モデルへの再評価は拒否する" $
      decide bookWithAsset (RevaluateAsset aid1 cid1 testDay (mkMoney 1_200_000) (mkMoney 200_000))
        @?= Left (RevaluationNotAllowedForCostModel aid1 cid1)
  , testCase "RevaluateAsset: 再評価モデルへの再評価を受理する" $ do
      let faReval = mkAsset aid1 cid1 RevaluationModel
          book = evolve initialAppBook (FixedAssetRegistered faReval)
      decide book (RevaluateAsset aid1 cid1 testDay (mkMoney 1_200_000) (mkMoney 200_000))
        @?= Right [AssetRevalued aid1 cid1 testDay (mkMoney 1_200_000) (mkMoney 200_000)]
  , testCase "RevaluateAsset: 再評価後総額ゼロは EmptyMasterField" $ do
      let faReval = mkAsset aid1 cid1 RevaluationModel
          book = evolve initialAppBook (FixedAssetRegistered faReval)
      case decide book (RevaluateAsset aid1 cid1 testDay zeroMoney (mkMoney 0)) of
        Left (EmptyMasterField _) -> pure ()
        other -> assertFailure ("expected EmptyMasterField, got: " <> show other)
  , testCase "RevaluateAsset: クローズ済み期間は PeriodClosed" $ do
      let faReval = mkAsset aid1 cid1 RevaluationModel
          pid = periodIdOf testDay
          book =
            foldl'
              evolve
              initialAppBook
              [ FixedAssetRegistered faReval
              , AccountingPeriodOpened pid
              , AccountingPeriodClosed pid
              ]
      case decide book (RevaluateAsset aid1 cid1 testDay (mkMoney 1_200_000) (mkMoney 200_000)) of
        Left (PeriodClosed _) -> pure ()
        other -> assertFailure ("expected PeriodClosed, got: " <> show other)
  , testCase "RevaluateAsset: 除却済み資産は FixedAssetAlreadyDisposed" $ do
      let faReval = mkAsset aid1 cid1 RevaluationModel
          book = foldl' evolve initialAppBook [FixedAssetRegistered faReval, FixedAssetDisposed aid1 cid1 testDay]
      case decide book (RevaluateAsset aid1 cid1 testDay (mkMoney 1_200_000) (mkMoney 200_000)) of
        Left (FixedAssetAlreadyDisposed _ _) -> pure ()
        other -> assertFailure ("expected FixedAssetAlreadyDisposed, got: " <> show other)
  , -- DisposeFixedAsset
    testCase "DisposeFixedAsset: 除却を受理する" $
      decide bookWithAsset (DisposeFixedAsset aid1 cid1 testDay)
        @?= Right [FixedAssetDisposed aid1 cid1 testDay]
  , testCase "DisposeFixedAsset: 存在しない資産は FixedAssetNotFound" $ do
      case decide initialAppBook (DisposeFixedAsset aid1 cid1 testDay) of
        Left (FixedAssetNotFound _ _) -> pure ()
        other -> assertFailure ("expected FixedAssetNotFound, got: " <> show other)
  , testCase "DisposeFixedAsset: 除却済み資産は FixedAssetAlreadyDisposed" $ do
      case decide disposedBook (DisposeFixedAsset aid1 cid1 (ModifiedJulianDay 59001)) of
        Left (FixedAssetAlreadyDisposed _ _) -> pure ()
        other -> assertFailure ("expected FixedAssetAlreadyDisposed, got: " <> show other)
  , testCase "DisposeFixedAsset: クローズ済み期間は PeriodClosed" $ do
      case decide closedBook (DisposeFixedAsset aid1 cid1 testDay) of
        Left (PeriodClosed _) -> pure ()
        other -> assertFailure ("expected PeriodClosed, got: " <> show other)
  ]

-- ── evolve ────────────────────────────────────────────────────────────────

evolveTests :: [TestTree]
evolveTests =
  [ testCase "FixedAssetRegistered: 資産台帳に挿入される" $
      assertBool "asset inserted" (Map.member (aid1, cid1) (fixedAssets (appAssets bookWithAsset)))
  , testCase "DepreciationRecorded: 累計償却額が加算される" $ do
      let book = evolve bookWithAsset (DepreciationRecorded aid1 cid1 testDay (mkMoney 16_667))
          fa = fixedAssets (appAssets book) Map.! (aid1, cid1)
      faAccumDepreciation fa @?= mkMoney 16_667
  , testCase "DepreciationRecorded: 2回の償却で累積される" $ do
      let book =
            foldl'
              evolve
              bookWithAsset
              [ DepreciationRecorded aid1 cid1 testDay (mkMoney 10_000)
              , DepreciationRecorded aid1 cid1 (ModifiedJulianDay 59030) (mkMoney 5_000)
              ]
          fa = fixedAssets (appAssets book) Map.! (aid1, cid1)
      faAccumDepreciation fa @?= mkMoney 15_000
  , testCase "ImpairmentRecognized: 減損損失累計が加算される" $ do
      let fa = fixedAssets (appAssets impairedBook) Map.! (aid1, cid1)
      faImpairmentCumulative fa @?= mkMoney 200_000
  , testCase "ImpairmentReversalRecognized: 戻入累計が加算される" $ do
      let book = evolve impairedBook (ImpairmentReversalRecognized aid1 cid1 testDay (mkMoney 50_000))
          fa = fixedAssets (appAssets book) Map.! (aid1, cid1)
      faImpairmentReversalCumulative fa @?= mkMoney 50_000
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
  , testCase "FixedAssetDisposed: 除却日が記録される" $ do
      let fa = fixedAssets (appAssets disposedBook) Map.! (aid1, cid1)
      faDisposalDate fa @?= Just testDay
  , testProperty "フォールド決定論: 同一イベント列 → 同一状態" $
      \(n :: Int) ->
        let evts = replicate (abs n `mod` 5) (FixedAssetRegistered fa1)
            book1 = foldl' evolve initialAppBook evts
            book2 = foldl' evolve initialAppBook evts
        in book1 == book2
  ]
