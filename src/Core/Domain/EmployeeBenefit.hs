-- | 従業員給付ドメイン型 (§4.7.15 / IAS 19)
module Core.Domain.EmployeeBenefit
  ( EmployeeBenefitType (..)
  , VacationAccrualType (..)
  , BenefitLiabilityId (..)
  , BenefitLiability (..)
  ) where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, withText, (.:), (.=))
import Data.Text (Text)
import Data.Time (Day)
import Data.UUID (UUID)
import GHC.Generics (Generic)

import Data.Text qualified as T
import Data.UUID qualified as UUID

import Core.Domain.AccountingPeriod (AccountingPeriodId)
import Core.Domain.Money (Money)

-- | 従業員給付の種別 (§4.7.15)
data EmployeeBenefitType
  = Bonus -- 賞与 (§4.7.15.1)
  | AccruedVacation -- 有給休暇債務 (§4.7.15.1)
  | DefinedContribution -- 確定拠出制度 (§4.7.15.2)
  | DefinedBenefit -- 確定給付制度 (§4.7.15.2)
  | TerminationBenefit -- 解雇給付 (§4.7.15.3)
  deriving (Bounded, Enum, Eq, Generic, Show)

instance ToJSON EmployeeBenefitType
instance FromJSON EmployeeBenefitType

-- | 有給休暇の累積型/非累積型区分 (§4.7.15.1)
data VacationAccrualType
  = Accumulating -- 累積型: 未消化分が翌期繰越 → 債務計上必須
  | NonAccumulating -- 非累積型: 取得時に費用認識、債務計上なし
  deriving (Bounded, Enum, Eq, Generic, Show)

instance ToJSON VacationAccrualType
instance FromJSON VacationAccrualType

newtype BenefitLiabilityId = BenefitLiabilityId UUID
  deriving (Eq, Ord, Show)

instance ToJSON BenefitLiabilityId where
  toJSON (BenefitLiabilityId u) = toJSON (UUID.toString u)

instance FromJSON BenefitLiabilityId where
  parseJSON = withText "BenefitLiabilityId" $ \t ->
    case UUID.fromString (T.unpack t) of
      Just u -> pure (BenefitLiabilityId u)
      Nothing -> fail ("invalid UUID: " <> T.unpack t)

{- | 従業員給付負債記録 (§4.7.15)

賞与: 勤務提供期間に応じて月次で未払計上 (§4.7.15.1)。
確定給付: 数理計算（PUC法）に基づくロールフォワードを月次反映 (§4.7.15.2)。
再測定差異（数理計算上の差異等）はOCIに認識し純損益に振り替えない (§4.7.15.2)。
-}
data BenefitLiability = BenefitLiability
  { blId :: BenefitLiabilityId
  , blType :: EmployeeBenefitType
  , blPeriod :: AccountingPeriodId -- 帰属会計期間
  , blDate :: Day -- 測定日
  , blLiabilityAmount :: Money -- 負債計上額
  , blServiceCost :: Maybe Money -- 当期勤務費用（確定給付）
  , blInterestCost :: Maybe Money -- 利息費用（確定給付）
  , blRemeasurementOci :: Maybe Money -- 再測定差異（OCI; 確定給付）(§4.7.15.2)
  , blVacationAccrualType :: Maybe VacationAccrualType -- 有給の場合
  , blDiscountRate :: Maybe Text -- 割引率（確定給付）。Decimal文字列として保存
  , blMemo :: Text
  }
  deriving (Eq, Show)

instance ToJSON BenefitLiability where
  toJSON b =
    object
      [ "blId" .= blId b
      , "blType" .= blType b
      , "blPeriod" .= blPeriod b
      , "blDate" .= blDate b
      , "blLiabilityAmount" .= blLiabilityAmount b
      , "blServiceCost" .= blServiceCost b
      , "blInterestCost" .= blInterestCost b
      , "blRemeasurementOci" .= blRemeasurementOci b
      , "blVacationAccrualType" .= blVacationAccrualType b
      , "blDiscountRate" .= blDiscountRate b
      , "blMemo" .= blMemo b
      ]

instance FromJSON BenefitLiability where
  parseJSON = withObject "BenefitLiability" $ \o ->
    BenefitLiability
      <$> o .: "blId"
      <*> o .: "blType"
      <*> o .: "blPeriod"
      <*> o .: "blDate"
      <*> o .: "blLiabilityAmount"
      <*> o .: "blServiceCost"
      <*> o .: "blInterestCost"
      <*> o .: "blRemeasurementOci"
      <*> o .: "blVacationAccrualType"
      <*> o .: "blDiscountRate"
      <*> o .: "blMemo"
