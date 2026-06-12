-- | 勘定科目マスタ (§2.1 — 勘定科目体系)
module Core.Domain.AccountMaster
  ( AccountCategory (..)
  , SettlementBehavior (..)
  , AccountMaster (..)
  , defaultNormalBalance
  , showAccountCategory
  ) where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.!=), (.:), (.:?), (.=))
import Data.Text (Text)
import GHC.Generics (Generic)

import Core.Domain.AccountCode (AccountCode)
import Core.Domain.Journal (DrCr (..))

-- | 勘定科目の大区分
data AccountCategory
  = Asset -- 資産
  | Liability -- 負債
  | Equity -- 純資産
  | Revenue -- 収益
  | Expense -- 費用
  deriving (Bounded, Enum, Eq, Generic, Show)

instance ToJSON AccountCategory
instance FromJSON AccountCategory

showAccountCategory :: AccountCategory -> Text
showAccountCategory Asset = "資産"
showAccountCategory Liability = "負債"
showAccountCategory Equity = "純資産"
showAccountCategory Revenue = "収益"
showAccountCategory Expense = "費用"

-- | 正常残高: 資産・費用は借方、それ以外は貸方
defaultNormalBalance :: AccountCategory -> DrCr
defaultNormalBalance Asset = Debit
defaultNormalBalance Expense = Debit
defaultNormalBalance _ = Credit

-- | 決済特性: RequiresSettlement は消込が完了するまで OpenItem として残高を保持する
data SettlementBehavior
  = SelfContained -- 費用・損益でその場で完結
  | RequiresSettlement -- 売掛金・買掛金等: Reconciliation が来るまで OpenItem を保持
  deriving (Bounded, Enum, Eq, Generic, Show)

instance ToJSON SettlementBehavior
instance FromJSON SettlementBehavior

data AccountMaster = AccountMaster
  { amCode :: AccountCode
  , amName :: Text
  , amCategory :: AccountCategory
  , amNormalBalance :: DrCr
  , amSettlement :: SettlementBehavior
  , amActive :: Bool
  }
  deriving (Eq, Generic, Show)

instance ToJSON AccountMaster where
  toJSON am =
    object
      [ "amCode" .= amCode am
      , "amName" .= amName am
      , "amCategory" .= amCategory am
      , "amNormalBalance" .= amNormalBalance am
      , "amSettlement" .= amSettlement am
      , "amActive" .= amActive am
      ]

-- 旧レコードに amSettlement がない場合は SelfContained を補完する
instance FromJSON AccountMaster where
  parseJSON = withObject "AccountMaster" $ \o ->
    AccountMaster
      <$> o .: "amCode"
      <*> o .: "amName"
      <*> o .: "amCategory"
      <*> o .: "amNormalBalance"
      <*> (o .:? "amSettlement" .!= SelfContained)
      <*> o .: "amActive"
