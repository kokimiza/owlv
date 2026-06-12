-- | 判断ログドメイン型 (§5)
module Core.Domain.JudgmentLog
  ( JudgmentCategory (..)
  , JudgmentLogId (..)
  , JudgmentLog (..)
  ) where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, withText, (.:), (.=))
import Data.Text (Text)
import Data.Time (Day)
import Data.UUID (UUID)
import GHC.Generics (Generic)

import Data.Text qualified as T
import Data.UUID qualified as UUID

import Core.Domain.AccountingPeriod (AccountingPeriodId)

-- | 判断ログ保存が必須となる評価・測定処理の区分 (§5.2)
data JudgmentCategory
  = RevenueRecognition -- 収益認識 (§5.2.1 / IFRS 15)
  | ExpectedCreditLoss -- 期待信用損失 (§5.2.2 / IFRS 9)
  | ForeignExchangeTranslation -- 外貨換算 (§5.2.3 / IAS 21)
  | ImpairmentTest -- 減損判定 (§5.2.4 / IAS 36)
  | FairValueMeasurement -- 公正価値測定 (§5.2.5 / IFRS 13)
  | Provisions -- 引当金 (§5.2.6 / IAS 37)
  | IncomeTax -- 税効果・当期税金 (§5.2.7 / IAS 12)
  | EmployeeBenefit -- 従業員給付 (§5.2.8 / IAS 19)
  | InternallyGeneratedIntangible -- 自己創設無形資産 (§5.2.9 / IAS 38)
  | GoingConcern -- 継続企業の前提 (§5.2.10 / IAS 1)
  deriving (Bounded, Enum, Eq, Generic, Show)

instance ToJSON JudgmentCategory
instance FromJSON JudgmentCategory

newtype JudgmentLogId = JudgmentLogId UUID
  deriving (Eq, Ord, Show)

instance ToJSON JudgmentLogId where
  toJSON (JudgmentLogId u) = toJSON (UUID.toString u)

instance FromJSON JudgmentLogId where
  parseJSON = withText "JudgmentLogId" $ \t ->
    case UUID.fromString (T.unpack t) of
      Just u -> pure (JudgmentLogId u)
      Nothing -> fail ("invalid UUID: " <> T.unpack t)

{- | 判断ログ記録 (§5)

保存期間: 当該会計期間の財務諸表確定後、最低7年間 (§5.3)。
変更統制: 前提条件・見積方法の変更時は変更理由・影響額・重要性判定を必須記録 (§5.4)。
-}
data JudgmentLog = JudgmentLog
  { jlId :: JudgmentLogId
  , jlPeriod :: AccountingPeriodId -- 対象会計期間
  , jlDate :: Day -- 判断実施日
  , jlCategory :: JudgmentCategory
  , jlStandardRef :: Text -- 会計基準引用（例: "IFRS 9 §5.5.14"）
  , jlModel :: Text -- 算定モデルの説明
  , jlAssumptions :: Text -- 前提条件
  , jlSensitivity :: Text -- 感度分析結果
  , jlConclusion :: Text -- 結論・判断内容
  , jlApprover :: Text -- 承認者
  , jlApprovalDate :: Day
  , jlRelatedEntityId :: Maybe Text -- 関連する資産ID・仕訳IDなど（任意）
  }
  deriving (Eq, Show)

instance ToJSON JudgmentLog where
  toJSON l =
    object
      [ "jlId" .= jlId l
      , "jlPeriod" .= jlPeriod l
      , "jlDate" .= jlDate l
      , "jlCategory" .= jlCategory l
      , "jlStandardRef" .= jlStandardRef l
      , "jlModel" .= jlModel l
      , "jlAssumptions" .= jlAssumptions l
      , "jlSensitivity" .= jlSensitivity l
      , "jlConclusion" .= jlConclusion l
      , "jlApprover" .= jlApprover l
      , "jlApprovalDate" .= jlApprovalDate l
      , "jlRelatedEntityId" .= jlRelatedEntityId l
      ]

instance FromJSON JudgmentLog where
  parseJSON = withObject "JudgmentLog" $ \o ->
    JudgmentLog
      <$> o .: "jlId"
      <*> o .: "jlPeriod"
      <*> o .: "jlDate"
      <*> o .: "jlCategory"
      <*> o .: "jlStandardRef"
      <*> o .: "jlModel"
      <*> o .: "jlAssumptions"
      <*> o .: "jlSensitivity"
      <*> o .: "jlConclusion"
      <*> o .: "jlApprover"
      <*> o .: "jlApprovalDate"
      <*> o .: "jlRelatedEntityId"
