module Core.Domain.SubAccount
  ( SubAccountId (..)
  , SubAccount (..)
  , mkSubAccountId
  ) where

import Data.Aeson (FromJSON (..), ToJSON (..))
import Data.Text (Text)
import GHC.Generics (Generic)

import Data.Text qualified as T

import Core.Domain.AccountCode (AccountCode)

newtype SubAccountId = SubAccountId {unSubAccountId :: Text}
  deriving (Eq, Ord, Show)

instance ToJSON SubAccountId where
  toJSON = toJSON . unSubAccountId

instance FromJSON SubAccountId where
  parseJSON = fmap SubAccountId . parseJSON

mkSubAccountId :: Text -> Either Text SubAccountId
mkSubAccountId t
  | T.null t = Left "補助科目コードは空にできません"
  | otherwise = Right (SubAccountId t)

data SubAccount = SubAccount
  { saId :: SubAccountId
  , saName :: Text
  , saParent :: AccountCode
  , saActive :: Bool
  }
  deriving (Eq, Generic, Show)

instance ToJSON SubAccount
instance FromJSON SubAccount
