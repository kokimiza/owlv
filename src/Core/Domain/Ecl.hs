-- | 期待信用損失ドメイン型および純粋算定関数 (§4.7.5〜4.7.12)
module Core.Domain.Ecl
  ( -- * アプローチ判定
    EclApproach (..)
  , EclStage (..)

    -- * 算定パラメータ
  , PdHorizon (..)
  , EclParams (..)

    -- * 簡便法：引当マトリクス
  , AgeBand (..)
  , ProvisionBucket (..)
  , ProvisionMatrix (..)

    -- * 測定記録
  , EclMeasurementId (..)
  , InterestBasis (..)
  , EclMeasurement (..)

    -- * 純粋算定
  , computeEcl
  , computeProvisionMatrixEcl
  ) where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, withText, (.:), (.=))
import Data.Decimal (Decimal)
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import Data.Time (Day)
import Data.UUID (UUID)
import GHC.Generics (Generic)

import Data.List.NonEmpty qualified as NE
import Data.Text qualified as T
import Data.UUID qualified as UUID

import Core.Domain.AccountCode (AccountCode)
import Core.Domain.Journal (JournalEntryId)
import Core.Domain.Money (Money, addMoney, mkMoney, unMoney, zeroMoney)

-- | 適用アプローチ判定 (§4.7.5)
data EclApproach
  = SimplifiedApproach -- 簡便法: 営業債権・契約資産（重要な金融要素なし）は強制適用
  | GeneralApproach -- 一般アプローチ: 貸付金・債券等
  | POCIApproach -- 購入・組成した信用減損金融資産 (§4.7.10)
  deriving (Bounded, Enum, Eq, Generic, Show)

instance ToJSON EclApproach
instance FromJSON EclApproach

-- | ステージ分類 (§4.7.7)。簡便法は常に全期間ECLのため LifetimeOnly として扱う。
data EclStage
  = Stage1 -- 信用リスク正常: 12ヶ月ECL
  | Stage2 -- 信用リスク著しく増大: 全期間ECL
  | Stage3 -- 信用減損: 全期間ECL、利息計算基礎が償却原価へ
  deriving (Bounded, Enum, Eq, Generic, Show)

instance ToJSON EclStage
instance FromJSON EclStage

-- | デフォルト確率の評価期間
data PdHorizon = Pd12Month | PdLifetime
  deriving (Bounded, Enum, Eq, Generic, Show)

instance ToJSON PdHorizon
instance FromJSON PdHorizon

{- | ECL算定パラメータ (§4.7.9.1)

ECL = EAD × PD × LGD × DF
規程 4.7.9.2: 割引率はステージにかかわらず当初実効金利（EIR）を使用。
POCI 資産のみ信用調整済み EIR を適用。
-}
data EclParams = EclParams
  { eclEad :: Money -- Exposure at Default
  , eclPd :: Decimal -- Default Probability (0.0〜1.0)
  , eclLgd :: Decimal -- Loss Given Default (0.0〜1.0)
  , eclDf :: Decimal -- Discount Factor (0.0〜1.0); 1.0 = 割引なし
  , eclPdHorizon :: PdHorizon
  }
  deriving (Eq, Generic, Show)

-- Decimal は aeson インスタンスを持たないため文字列でシリアライズする。
instance ToJSON EclParams where
  toJSON p =
    object
      [ "eclEad" .= eclEad p
      , "eclPd" .= show (eclPd p)
      , "eclLgd" .= show (eclLgd p)
      , "eclDf" .= show (eclDf p)
      , "eclPdHorizon" .= eclPdHorizon p
      ]

instance FromJSON EclParams where
  parseJSON = withObject "EclParams" $ \o -> do
    pd' <- parseDecimalField =<< o .: "eclPd"
    lgd' <- parseDecimalField =<< o .: "eclLgd"
    df' <- parseDecimalField =<< o .: "eclDf"
    EclParams
      <$> o .: "eclEad"
      <*> pure pd'
      <*> pure lgd'
      <*> pure df'
      <*> o .: "eclPdHorizon"

-- | Decimal を文字列から解析する共通ヘルパー
parseDecimalField :: (MonadFail m) => Text -> m Decimal
parseDecimalField t =
  case reads (T.unpack t) of
    [(d, "")] -> pure d
    _ -> fail ("invalid Decimal: " <> T.unpack t)

-- | 引当マトリクスの年齢区分 (§4.7.6.2)
data AgeBand
  = Current -- 期日内
  | DaysOverdue1To30 -- 30日以内
  | DaysOverdue31To60 -- 31〜60日
  | DaysOverdue61To90 -- 61〜90日
  | DaysOverdue90Plus -- 90日超
  deriving (Bounded, Enum, Eq, Generic, Ord, Show)

instance ToJSON AgeBand
instance FromJSON AgeBand

-- | 引当マトリクスの1バケット
data ProvisionBucket = ProvisionBucket
  { pbBand :: AgeBand
  , pbLossRate :: Decimal -- 損失率 (0.0〜1.0); 将来予測調整後
  , pbExposure :: Money -- 当該年齢区分の債権残高
  }
  deriving (Eq, Generic, Show)

instance ToJSON ProvisionBucket where
  toJSON b =
    object
      [ "pbBand" .= pbBand b
      , "pbLossRate" .= show (pbLossRate b)
      , "pbExposure" .= pbExposure b
      ]

instance FromJSON ProvisionBucket where
  parseJSON = withObject "ProvisionBucket" $ \o -> do
    lr <- parseDecimalField =<< o .: "pbLossRate"
    ProvisionBucket
      <$> o .: "pbBand"
      <*> pure lr
      <*> o .: "pbExposure"

-- | 引当マトリクス全体 (§4.7.6.2)
newtype ProvisionMatrix = ProvisionMatrix
  { pmBuckets :: NonEmpty ProvisionBucket
  }
  deriving (Eq, Show)

instance ToJSON ProvisionMatrix where
  toJSON (ProvisionMatrix bs) = toJSON (NE.toList bs)

instance FromJSON ProvisionMatrix where
  parseJSON v = do
    bs <- parseJSON v
    case NE.nonEmpty bs of
      Nothing -> fail "ProvisionMatrix: empty bucket list"
      Just ne -> pure (ProvisionMatrix ne)

newtype EclMeasurementId = EclMeasurementId UUID
  deriving (Eq, Ord, Show)

instance ToJSON EclMeasurementId where
  toJSON (EclMeasurementId u) = toJSON (UUID.toString u)

instance FromJSON EclMeasurementId where
  parseJSON = withText "EclMeasurementId" $ \t ->
    case UUID.fromString (T.unpack t) of
      Just u -> pure (EclMeasurementId u)
      Nothing -> fail ("invalid UUID: " <> T.unpack t)

-- | 利息収益の計算基礎 (§4.7.9.3)
data InterestBasis
  = GrossCarryingAmount -- Stage 1/2: 総額帳簿価額
  | AmortisedCost -- Stage 3 / POCI: 償却原価
  deriving (Bounded, Enum, Eq, Generic, Show)

instance ToJSON InterestBasis
instance FromJSON InterestBasis

-- | ECL測定記録 (§4.7.12)
data EclMeasurement = EclMeasurement
  { eclMeasId :: EclMeasurementId
  , eclMeasDate :: Day
  , eclMeasApproach :: EclApproach
  , eclMeasStage :: Maybe EclStage -- Nothing = 簡便法またはPOCI（ステージ分類なし）
  , eclMeasAccount :: AccountCode
  , eclMeasEntryRef :: Maybe JournalEntryId -- 対応する仕訳伝票（任意）
  , eclMeasParams :: Maybe EclParams -- 一般アプローチ時に保存
  , eclMeasMatrix :: Maybe ProvisionMatrix -- 簡便法時に保存
  , eclMeasAmount :: Money -- 算定されたECL額
  , eclMeasInterestBasis :: InterestBasis -- 利息収益計算基礎 (§4.7.9.3)
  , eclMeasMemo :: Text
  }
  deriving (Eq, Show)

instance ToJSON EclMeasurement where
  toJSON m =
    object
      [ "eclMeasId" .= eclMeasId m
      , "eclMeasDate" .= eclMeasDate m
      , "eclMeasApproach" .= eclMeasApproach m
      , "eclMeasStage" .= eclMeasStage m
      , "eclMeasAccount" .= eclMeasAccount m
      , "eclMeasEntryRef" .= eclMeasEntryRef m
      , "eclMeasParams" .= eclMeasParams m
      , "eclMeasMatrix" .= eclMeasMatrix m
      , "eclMeasAmount" .= eclMeasAmount m
      , "eclMeasInterestBasis" .= eclMeasInterestBasis m
      , "eclMeasMemo" .= eclMeasMemo m
      ]

instance FromJSON EclMeasurement where
  parseJSON = withObject "EclMeasurement" $ \o ->
    EclMeasurement
      <$> o .: "eclMeasId"
      <*> o .: "eclMeasDate"
      <*> o .: "eclMeasApproach"
      <*> o .: "eclMeasStage"
      <*> o .: "eclMeasAccount"
      <*> o .: "eclMeasEntryRef"
      <*> o .: "eclMeasParams"
      <*> o .: "eclMeasMatrix"
      <*> o .: "eclMeasAmount"
      <*> o .: "eclMeasInterestBasis"
      <*> o .: "eclMeasMemo"

{- | ECL純粋算定 (§4.7.9.1)
ECL = EAD × PD × LGD × DF
規程 4.7.9.2: 割引率はステージにかかわらず当初EIR（本関数の呼び出し元でDF算定済みと想定）。
-}
computeEcl :: EclParams -> Money
computeEcl p =
  let raw = unMoney (eclEad p) * eclPd p * eclLgd p * eclDf p
  in mkMoney raw

{- | 簡便法：引当マトリクスによる全期間ECL算定 (§4.7.6.2)
各バケットの残高 × 損失率の合計を返す。
-}
computeProvisionMatrixEcl :: ProvisionMatrix -> Money
computeProvisionMatrixEcl (ProvisionMatrix buckets) =
  foldr step zeroMoney buckets
 where
  step b acc =
    let bucketEcl = mkMoney (unMoney (pbExposure b) * pbLossRate b)
    in addMoney bucketEcl acc
