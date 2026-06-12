-- | 消込 — JournalEntry の未決済残高と CashTransaction を結合するノード
module Core.Domain.Reconciliation
  ( ReconciliationId (..)
  , ReconciliationItem (..)
  , Reconciliation (..)
  , reconciliationTotal
  ) where

import Data.Aeson (FromJSON (..), ToJSON (..), withText)
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import Data.Time (Day)
import Data.UUID (UUID)
import GHC.Generics (Generic)

import Data.Text qualified as T
import Data.UUID qualified as UUID

import Core.Domain.AccountCode (AccountCode)
import Core.Domain.CashTransaction (CashTransactionId)
import Core.Domain.Journal (JournalEntryId)
import Core.Domain.Money (Money, addMoney, zeroMoney)
import Core.Domain.Organisation (OrganisationId)

newtype ReconciliationId = ReconciliationId UUID
  deriving (Eq, Ord, Show)

instance ToJSON ReconciliationId where
  toJSON (ReconciliationId uuid) = toJSON (UUID.toString uuid)

instance FromJSON ReconciliationId where
  parseJSON = withText "ReconciliationId" $ \t ->
    case UUID.fromString (T.unpack t) of
      Just uuid -> pure (ReconciliationId uuid)
      Nothing -> fail ("invalid ReconciliationId UUID: " <> T.unpack t)

-- | JournalEntry の特定行 (entryId + 科目) への部分消込金額
data ReconciliationItem = ReconciliationItem
  { riEntryId :: JournalEntryId
  , riAccount :: AccountCode
  , riAmount :: Money -- 部分消込対応; > 0 が不変条件
  }
  deriving (Eq, Generic, Show)

instance ToJSON ReconciliationItem
instance FromJSON ReconciliationItem

data Reconciliation = Reconciliation
  { recId :: ReconciliationId
  , recCashId :: CashTransactionId
  , recItems :: NonEmpty ReconciliationItem
  , recDate :: Day
  , recOrg :: OrganisationId
  , recMemo :: Text
  }
  deriving (Eq, Generic, Show)

instance ToJSON Reconciliation
instance FromJSON Reconciliation

-- | 消込明細の合計金額
reconciliationTotal :: Reconciliation -> Money
reconciliationTotal = foldr (addMoney . riAmount) zeroMoney . recItems
