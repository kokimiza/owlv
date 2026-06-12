-- | 入出金明細 — 銀行口座への入出金という「動かぬ事実」を記録する
module Core.Domain.CashTransaction
  ( CashTransactionId (..)
  , CashTransaction (..)
  ) where

import Data.Aeson (FromJSON (..), ToJSON (..), withText)
import Data.Text (Text)
import Data.Time (Day)
import Data.UUID (UUID)
import GHC.Generics (Generic)

import Data.Text qualified as T
import Data.UUID qualified as UUID

import Core.Domain.AccountCode (AccountCode)
import Core.Domain.Journal (DrCr)
import Core.Domain.Money (Money)
import Core.Domain.Organisation (OrganisationId)
import Core.Domain.Partner (PartnerId)

newtype CashTransactionId = CashTransactionId UUID
  deriving (Eq, Ord, Show)

instance ToJSON CashTransactionId where
  toJSON (CashTransactionId uuid) = toJSON (UUID.toString uuid)

instance FromJSON CashTransactionId where
  parseJSON = withText "CashTransactionId" $ \t ->
    case UUID.fromString (T.unpack t) of
      Just uuid -> pure (CashTransactionId uuid)
      Nothing -> fail ("invalid CashTransactionId UUID: " <> T.unpack t)

-- | 銀行明細一行。ctBankRef が外部システムとの不変接点。
data CashTransaction = CashTransaction
  { ctId :: CashTransactionId
  , ctDate :: Day
  , ctOrg :: OrganisationId
  , ctAccount :: AccountCode -- 預金口座科目
  , ctDrCr :: DrCr
  , ctAmount :: Money
  , ctPartner :: Maybe PartnerId
  , ctBankRef :: Text -- 銀行明細番号（外部キー・不変）
  , ctMemo :: Text
  }
  deriving (Eq, Generic, Show)

instance ToJSON CashTransaction
instance FromJSON CashTransaction
