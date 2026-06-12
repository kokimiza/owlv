module Core.MaterialitySpec (tests) where

import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck

import Core.Domain.Materiality
import Core.Domain.Money (mkMoney, zeroMoney)

-- ── Tests ─────────────────────────────────────────────────────────────────

tests :: TestTree
tests =
  testGroup
    "Core.Materiality"
    [ testGroup "checkMateriality" matTests
    , testGroup "checkAnyMaterial" anyTests
    , testGroup "isQualitativelyMaterial" qualTests
    ]

thr :: MaterialityThresholds
thr = defaultThresholds

-- ── checkMateriality (§3.1.1) ─────────────────────────────────────────────

matTests :: [TestTree]
matTests =
  [ testCase "税引前利益: 5%超 → Material" $ do
      -- 100 / 1000 = 10% > 5%
      checkMateriality thr (mkMoney 100) (mkMoney 1000) PretaxProfit @?= Material
  , testCase "税引前利益: 4% → Immaterial" $ do
      -- 40 / 1000 = 4% < 5%
      checkMateriality thr (mkMoney 40) (mkMoney 1000) PretaxProfit @?= Immaterial
  , testCase "総資産: 0.5%超 → Material" $ do
      -- 60 / 10000 = 0.6% > 0.5%
      checkMateriality thr (mkMoney 60) (mkMoney 10000) TotalAssets @?= Material
  , testCase "総資産: 0.4% → Immaterial" $ do
      -- 40 / 10000 = 0.4% < 0.5%
      checkMateriality thr (mkMoney 40) (mkMoney 10000) TotalAssets @?= Immaterial
  , testCase "売上高: 0.5% = Material (境界値)" $ do
      -- 50 / 10000 = 0.5%
      checkMateriality thr (mkMoney 50) (mkMoney 10000) Revenue @?= Material
  , testCase "純資産: 1%超 → Material" $ do
      -- 110 / 10000 = 1.1% > 1%
      checkMateriality thr (mkMoney 110) (mkMoney 10000) NetAssets @?= Material
  , testCase "基準値ゼロ → Immaterial (§3.1.1.1 代替指標を別途適用)" $ do
      checkMateriality thr (mkMoney 999) zeroMoney PretaxProfit @?= Immaterial
  , testProperty "ゼロ金額は常に Immaterial" $
      \basisCents ->
        let basis = mkMoney (fromInteger (abs basisCents + 1))
        in checkMateriality thr zeroMoney basis PretaxProfit == Immaterial
  , testProperty "金額が大きいほど Material になりやすい (単調性)" $
      \(Positive small) (Positive large) ->
        let basis = mkMoney 1_000_000
            s = mkMoney (fromInteger small)
            l = mkMoney (fromInteger (small + large))
        in checkMateriality thr s basis PretaxProfit
             `ltOrEq` checkMateriality thr l basis PretaxProfit
  ]
 where
  ltOrEq Immaterial _ = True
  ltOrEq Material Material = True
  ltOrEq Material Immaterial = False

-- ── checkAnyMaterial (§3.1.1) ─────────────────────────────────────────────

anyTests :: [TestTree]
anyTests =
  [ testCase "いずれかが Material → Material" $ do
      let pairs =
            [ (mkMoney 1_000_000, TotalAssets) -- 1/1000000 = 0.0001% → Immaterial
            , (mkMoney 100, PretaxProfit) -- 100/1000 = 10% → Material
            ]
      checkAnyMaterial thr (mkMoney 100) pairs @?= Material
  , testCase "すべて Immaterial → Immaterial" $ do
      let pairs =
            [ (mkMoney 1_000_000, TotalAssets) -- 1/1000000 → Immaterial
            , (mkMoney 100_000, Revenue) -- 1/100000 → Immaterial
            ]
      checkAnyMaterial thr (mkMoney 1) pairs @?= Immaterial
  , testCase "空リスト → Immaterial" $ do
      checkAnyMaterial thr (mkMoney 999_999) [] @?= Immaterial
  ]

-- ── isQualitativelyMaterial (§3.1.2) ──────────────────────────────────────

qualTests :: [TestTree]
qualTests =
  [ testCase "空リスト → False" $ do
      isQualitativelyMaterial [] @?= False
  , testCase "トリガーあり → True" $ do
      isQualitativelyMaterial [RelatedPartyTransaction] @?= True
  , testCase "複数トリガーあり → True" $ do
      isQualitativelyMaterial [AccountingPolicyChange, LegalViolation] @?= True
  ]
