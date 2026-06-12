-- | 法人所得税ドメイン型 (§4.7.16 / IAS 12)
module Core.Domain.Tax
  ( TaxEntryId (..)
  , TemporaryDifferenceType (..)
  , TemporaryDifference (..)
  , TaxEntry (..)
  , computeCurrentTax
  ) where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, withText, (.:), (.=))
import Data.Decimal (Decimal)
import Data.Text (Text)
import Data.Time (Day)
import Data.UUID (UUID)
import GHC.Generics (Generic)

import Data.Text qualified as T
import Data.UUID qualified as UUID

import Core.Domain.AccountingPeriod (AccountingPeriodId)
import Core.Domain.Money (Money, mkMoney, unMoney)

newtype TaxEntryId = TaxEntryId UUID
  deriving (Eq, Ord, Show)

instance ToJSON TaxEntryId where
  toJSON (TaxEntryId u) = toJSON (UUID.toString u)

instance FromJSON TaxEntryId where
  parseJSON = withText "TaxEntryId" $ \t ->
    case UUID.fromString (T.unpack t) of
      Just u -> pure (TaxEntryId u)
      Nothing -> fail ("invalid UUID: " <> T.unpack t)

-- | 一時差異の種別 (§4.7.16.2)
data TemporaryDifferenceType
  = TaxableDifference -- 加算一時差異 → 繰延税金負債
  | DeductibleDifference -- 減算一時差異 → 繰延税金資産
  deriving (Bounded, Enum, Eq, Generic, Show)

instance ToJSON TemporaryDifferenceType
instance FromJSON TemporaryDifferenceType

-- | 一時差異 (§4.7.16.2)
data TemporaryDifference = TemporaryDifference
  { tdType :: TemporaryDifferenceType
  , tdDescription :: Text -- 差異の内容（例: 「減価償却超過額」）
  , tdAmount :: Money -- 差異金額
  , tdApplicableTaxRate :: Decimal -- 適用税率（報告日現在実質的制定済みの税率）
  }
  deriving (Eq, Generic, Show)

instance ToJSON TemporaryDifference where
  toJSON td =
    object
      [ "tdType" .= tdType td
      , "tdDescription" .= tdDescription td
      , "tdAmount" .= tdAmount td
      , "tdApplicableTaxRate" .= show (tdApplicableTaxRate td)
      ]

instance FromJSON TemporaryDifference where
  parseJSON = withObject "TemporaryDifference" $ \o -> do
    rStr <- o .: "tdApplicableTaxRate"
    rate <- case reads (T.unpack rStr) of
      [(d, "")] -> pure d
      _ -> fail ("invalid Decimal (tax rate): " <> T.unpack rStr)
    TemporaryDifference
      <$> o .: "tdType"
      <*> o .: "tdDescription"
      <*> o .: "tdAmount"
      <*> pure rate

{- | 法人所得税計上記録 (§4.7.16)

月次: 年間見積実効税率法（ETR法）を原則とする (§4.7.16.1)。
  当月税金費用 = 月次累計税引前利益 × ETR - 前月までの計上累計
ETR改定時: 改定月において累計補正として反映する (§4.7.16.1)。
繰延税金: 一時差異 × 適用税率で算定 (§4.7.16.2)。
-}
data TaxEntry = TaxEntry
  { teId :: TaxEntryId
  , tePeriod :: AccountingPeriodId
  , teDate :: Day
  , teEstimatedEffectiveTaxRate :: Decimal -- 年間見積実効税率（ETR）
  , teCumulativePretaxIncome :: Money -- 月次累計税引前利益
  , tePriorCumulativeTaxCharge :: Money -- 前月までの当期税金計上累計
  , teCurrentPeriodTaxCharge :: Money -- 当月計上額 = 累計税金 - 前月累計
  , teDeferredTaxAsset :: Money -- 繰延税金資産（総額）
  , teDeferredTaxLiability :: Money -- 繰延税金負債（総額）
  , teTemporaryDifferences :: [TemporaryDifference]
  , teEtrBasis :: Text -- ETR算定根拠（§5.2.7 判断ログ必須）
  , teMemo :: Text
  }
  deriving (Eq, Show)

instance ToJSON TaxEntry where
  toJSON e =
    object
      [ "teId" .= teId e
      , "tePeriod" .= tePeriod e
      , "teDate" .= teDate e
      , "teEstimatedEffectiveTaxRate" .= show (teEstimatedEffectiveTaxRate e)
      , "teCumulativePretaxIncome" .= teCumulativePretaxIncome e
      , "tePriorCumulativeTaxCharge" .= tePriorCumulativeTaxCharge e
      , "teCurrentPeriodTaxCharge" .= teCurrentPeriodTaxCharge e
      , "teDeferredTaxAsset" .= teDeferredTaxAsset e
      , "teDeferredTaxLiability" .= teDeferredTaxLiability e
      , "teTemporaryDifferences" .= teTemporaryDifferences e
      , "teEtrBasis" .= teEtrBasis e
      , "teMemo" .= teMemo e
      ]

instance FromJSON TaxEntry where
  parseJSON = withObject "TaxEntry" $ \o -> do
    etrStr <- o .: "teEstimatedEffectiveTaxRate"
    etr <- case reads (T.unpack etrStr) of
      [(d, "")] -> pure d
      _ -> fail ("invalid Decimal (ETR): " <> T.unpack etrStr)
    TaxEntry
      <$> o .: "teId"
      <*> o .: "tePeriod"
      <*> o .: "teDate"
      <*> pure etr
      <*> o .: "teCumulativePretaxIncome"
      <*> o .: "tePriorCumulativeTaxCharge"
      <*> o .: "teCurrentPeriodTaxCharge"
      <*> o .: "teDeferredTaxAsset"
      <*> o .: "teDeferredTaxLiability"
      <*> o .: "teTemporaryDifferences"
      <*> o .: "teEtrBasis"
      <*> o .: "teMemo"

{- | 当期税金費用（月次）の算定 (§4.7.16.1)
当月計上額 = 累計税引前利益 × ETR - 前月までの計上累計
-}
computeCurrentTax :: Decimal -> Money -> Money -> Money
computeCurrentTax etr cumulativePretax priorCumulative =
  let cumulativeTax = mkMoney (unMoney cumulativePretax * etr)
      currentCharge = mkMoney (unMoney cumulativeTax - unMoney priorCumulative)
  in currentCharge
