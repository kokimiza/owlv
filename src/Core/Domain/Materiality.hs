-- | 重要性判定（純粋関数）(§3.1)
module Core.Domain.Materiality
  ( MaterialityBasis (..)
  , QualitativeTrigger (..)
  , MaterialityThresholds (..)
  , defaultThresholds
  , MaterialityResult (..)
  , checkMateriality
  , checkAnyMaterial
  , isQualitativelyMaterial
  ) where

import Data.Decimal (Decimal)
import GHC.Generics (Generic)

import Core.Domain.Money (Money, unMoney)

-- | 金額的重要性の判定指標 (§3.1.1)
data MaterialityBasis
  = PretaxProfit -- 税引前利益: 5%
  | TotalAssets -- 総資産: 0.5%
  | Revenue -- 売上高: 0.5%
  | NetAssets -- 純資産: 1%
  deriving (Bounded, Enum, Eq, Generic, Show)

-- | 質的重要性トリガー (§3.1.2)
data QualitativeTrigger
  = AccountingPolicyChange -- 会計方針の変更
  | RelatedPartyTransaction -- 関連当事者取引
  | LegalViolation -- 法令違反または訴訟
  | ManagementCompensationKPI -- 経営者報酬に影響する指標
  | FinancialCovenantImpact -- 財務制限条項に影響する項目
  | NonRecurringItem -- 非経常的な損益項目
  deriving (Bounded, Enum, Eq, Generic, Show)

-- | 重要性閾値テーブル (§3.1.1)
data MaterialityThresholds = MaterialityThresholds
  { mtPretaxProfitRate :: Decimal -- デフォルト 0.05
  , mtTotalAssetsRate :: Decimal -- デフォルト 0.005
  , mtRevenueRate :: Decimal -- デフォルト 0.005
  , mtNetAssetsRate :: Decimal -- デフォルト 0.01
  }
  deriving (Eq, Generic, Show)

-- | 規程§3.1.1 準拠デフォルト閾値
defaultThresholds :: MaterialityThresholds
defaultThresholds =
  MaterialityThresholds
    { mtPretaxProfitRate = 0.05
    , mtTotalAssetsRate = 0.005
    , mtRevenueRate = 0.005
    , mtNetAssetsRate = 0.01
    }

data MaterialityResult
  = Material -- 重要性あり
  | Immaterial -- 重要性なし
  deriving (Bounded, Enum, Eq, Generic, Show)

{- | 単一基準での重要性判定 (§3.1.1)
amount / basis >= threshold → Material
-}
checkMateriality ::
  MaterialityThresholds ->
  Money -> -- 判定対象金額
  Money -> -- 基準値（税引前利益・総資産等）
  MaterialityBasis ->
  MaterialityResult
checkMateriality thresholds amount basis basisType
  | baseDec == 0 = Immaterial -- 基準値ゼロの場合は代替指標（§3.1.1.1）で別途判定
  | ratio >= threshold = Material
  | otherwise = Immaterial
 where
  amtDec = abs (unMoney amount)
  baseDec = abs (unMoney basis)
  ratio = amtDec / baseDec
  threshold = case basisType of
    PretaxProfit -> mtPretaxProfitRate thresholds
    TotalAssets -> mtTotalAssetsRate thresholds
    Revenue -> mtRevenueRate thresholds
    NetAssets -> mtNetAssetsRate thresholds

{- | 複数指標への重要性判定（最も低い閾値を適用）(§3.1.1)
いずれか1つでも Material であれば Material を返す。
-}
checkAnyMaterial ::
  MaterialityThresholds ->
  Money -> -- 判定対象金額
  [(Money, MaterialityBasis)] -> -- (基準値, 指標) ペアのリスト
  MaterialityResult
checkAnyMaterial _ _ [] = Immaterial
checkAnyMaterial thresholds amount pairs
  | any isMat pairs = Material
  | otherwise = Immaterial
 where
  isMat (basis, basisType) =
    checkMateriality thresholds amount basis basisType == Material

{- | 質的重要性判定 (§3.1.2)
金額にかかわらず重要性ありと判定される事象の存在を確認する。
-}
isQualitativelyMaterial :: [QualitativeTrigger] -> Bool
isQualitativelyMaterial = not . null
