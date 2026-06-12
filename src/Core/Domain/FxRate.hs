-- | 外貨換算ドメイン型 (§4.7.13)
module Core.Domain.FxRate
  ( CurrencyCode (..)
  , ExchangeRateType (..)
  , MonetaryClassification (..)
  , FxRateId (..)
  , FxRate (..)
  ) where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, withText, (.:), (.=))
import Data.Decimal (Decimal)
import Data.Text (Text)
import Data.Time (Day)
import Data.UUID (UUID)
import GHC.Generics (Generic)

import Data.Text qualified as T
import Data.UUID qualified as UUID

-- | ISO 4217 通貨コード (3文字)
newtype CurrencyCode = CurrencyCode {unCurrencyCode :: Text}
  deriving (Eq, Generic, Ord, Show)

instance ToJSON CurrencyCode
instance FromJSON CurrencyCode

-- | 為替レート区分 (§4.7.13.6)
data ExchangeRateType
  = SpotRate -- 直物レート（SR）: 取引発生時
  | ClosingRate -- 期末日レート（CR）: 貨幣性項目評価替え
  | HistoricalRate -- 取引日レート（HR）: 非貨幣性項目（原価測定）
  | AverageRate -- 平均レート（AR）: 損益項目の換算（簡便法）
  deriving (Bounded, Enum, Eq, Generic, Show)

instance ToJSON ExchangeRateType
instance FromJSON ExchangeRateType

-- | 貨幣性・非貨幣性区分 (§4.7.13.4)
data MonetaryClassification
  = Monetary -- 貨幣性項目: 期末日レートで換算
  | NonMonetary -- 非貨幣性項目: 測定基礎により適用レートが異なる
  deriving (Bounded, Enum, Eq, Generic, Show)

instance ToJSON MonetaryClassification
instance FromJSON MonetaryClassification

newtype FxRateId = FxRateId UUID
  deriving (Eq, Ord, Show)

instance ToJSON FxRateId where
  toJSON (FxRateId u) = toJSON (UUID.toString u)

instance FromJSON FxRateId where
  parseJSON = withText "FxRateId" $ \t ->
    case UUID.fromString (T.unpack t) of
      Just u -> pure (FxRateId u)
      Nothing -> fail ("invalid UUID: " <> T.unpack t)

{- | 為替レート記録 (§4.7.13.6, §7.1.2)

再現性要件（§7.1.2）: 取得元・取得日時を必須属性として保持する。
-}
data FxRate = FxRate
  { fxRateId :: FxRateId
  , fxBaseCurrency :: CurrencyCode -- 換算元通貨（外貨）
  , fxQuoteCurrency :: CurrencyCode -- 換算先通貨（機能通貨）
  , fxRate :: Decimal -- 1外貨単位 = fxRate 機能通貨
  , fxRateType :: ExchangeRateType
  , fxRateDate :: Day -- 適用日
  , fxRateSource :: Text -- 取得元（§7.1.2 パラメータ保存要件）
  , fxRateMemo :: Text
  }
  deriving (Eq, Show)

instance ToJSON FxRate where
  toJSON r =
    object
      [ "fxRateId" .= fxRateId r
      , "fxBaseCurrency" .= fxBaseCurrency r
      , "fxQuoteCurrency" .= fxQuoteCurrency r
      , "fxRate" .= show (fxRate r) -- Decimal は文字列でシリアライズして精度を保持
      , "fxRateType" .= fxRateType r
      , "fxRateDate" .= fxRateDate r
      , "fxRateSource" .= fxRateSource r
      , "fxRateMemo" .= fxRateMemo r
      ]

instance FromJSON FxRate where
  parseJSON = withObject "FxRate" $ \o -> do
    rStr <- o .: "fxRate"
    rate <- case reads (T.unpack rStr) of
      [(d, "")] -> pure d
      _ -> fail ("invalid Decimal: " <> T.unpack rStr)
    FxRate
      <$> o .: "fxRateId"
      <*> o .: "fxBaseCurrency"
      <*> o .: "fxQuoteCurrency"
      <*> pure rate
      <*> o .: "fxRateType"
      <*> o .: "fxRateDate"
      <*> o .: "fxRateSource"
      <*> o .: "fxRateMemo"
