-- | 固定資産台帳ドメイン型 (§2.4)
module Core.Domain.FixedAsset
  ( FixedAssetId (..)
  , ComponentId (..)
  , CguId (..)
  , MeasurementModel (..)
  , DepreciationMethod (..)
  , AssetCategory (..)
  , FixedAsset (..)
  , carryingAmount
  , netImpairment
  ) where

import Data.Aeson (FromJSON (..), ToJSON (..))
import Data.Text (Text)
import Data.Time (Day)
import GHC.Generics (Generic)

import Core.Domain.AccountCode (AccountCode)
import Core.Domain.Money (Money, subtractMoney)

newtype FixedAssetId = FixedAssetId {unFixedAssetId :: Text}
  deriving (Eq, Generic, Ord, Show)

instance ToJSON FixedAssetId
instance FromJSON FixedAssetId

newtype ComponentId = ComponentId {unComponentId :: Text}
  deriving (Eq, Generic, Ord, Show)

instance ToJSON ComponentId
instance FromJSON ComponentId

-- | 資金生成単位識別子 (§2.4.5)
newtype CguId = CguId {unCguId :: Text}
  deriving (Eq, Generic, Ord, Show)

instance ToJSON CguId
instance FromJSON CguId

-- | 測定モデル (§2.4.3)
data MeasurementModel = CostModel | RevaluationModel
  deriving (Bounded, Enum, Eq, Generic, Show)

instance ToJSON MeasurementModel
instance FromJSON MeasurementModel

-- | 償却方法 (§2.4.4)
data DepreciationMethod
  = StraightLine -- 定額法
  | DecliningBalance -- 定率法
  | UnitsOfProduction -- 生産高比例法
  deriving (Bounded, Enum, Eq, Generic, Show)

instance ToJSON DepreciationMethod
instance FromJSON DepreciationMethod

-- | 資産区分 (§2.4.2)
data AssetCategory
  = TangibleFixedAsset -- 有形固定資産 (IAS 16)
  | IntangibleAsset -- 無形資産 (IAS 38)
  | RightOfUseAsset -- 使用権資産 (IFRS 16)
  | ConstructionInProgress -- 建設仮勘定
  deriving (Bounded, Enum, Eq, Generic, Show)

instance ToJSON AssetCategory
instance FromJSON AssetCategory

{- | 固定資産台帳レコード (§2.4.4)

帳簿価額の形成:
  carryingAmount = faGrossAmount - faAccumDepreciation - faImpairmentCumulative + faImpairmentReversalCumulative

再評価モデル採用時、RevaluateAsset イベントで faGrossAmount を再評価額へ更新し
faAccumDepreciation をリセットする。再評価差額は faRevalSurplusCumulative へ累積する。
-}
data FixedAsset = FixedAsset
  { faId :: FixedAssetId
  , faComponent :: ComponentId
  , faAccount :: AccountCode
  , faCategory :: AssetCategory
  , faCgu :: Maybe CguId -- 資金生成単位 (§2.4.5)
  , faAcquisitionDate :: Day
  , faMeasurementModel :: MeasurementModel
  , faUsefulLifeMonths :: Int -- 耐用年数（月数）。0 = 耐用年数非確定
  , faResidualValue :: Money -- 残存価額
  , faDepreciationMethod :: DepreciationMethod
  , -- 事後測定累計値 (§2.4.4)
    faGrossAmount :: Money -- 取得原価または最新再評価額
  , faAccumDepreciation :: Money -- 累計償却額（正値）
  , faImpairmentCumulative :: Money -- 減損損失累計（正値）
  , faImpairmentReversalCumulative :: Money -- 減損戻入累計（正値）
  , faRevalSurplusCumulative :: Money -- 再評価差額累計（OCI）
  , faDisposalDate :: Maybe Day
  }
  deriving (Eq, Generic, Show)

instance ToJSON FixedAsset
instance FromJSON FixedAsset

-- | 純減損額 = 減損損失累計 - 戻入累計
netImpairment :: FixedAsset -> Money
netImpairment fa =
  subtractMoney (faImpairmentCumulative fa) (faImpairmentReversalCumulative fa)

{- | 帳簿価額の算定 (§2.3.2, §4.7.3)
規程 2.3.2: 取得原価 - 累計償却 - 純減損
-}
carryingAmount :: FixedAsset -> Money
carryingAmount fa =
  let afterDeprec = subtractMoney (faGrossAmount fa) (faAccumDepreciation fa)
  in subtractMoney afterDeprec (netImpairment fa)

-- 帳簿価額が 0 を下回らないこと、残存価額を下回る償却をしないことは Decide で保証する。
