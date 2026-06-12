module Core.Domain.Partner
  ( PartnerId (..)
  , PartnerType (..)
  , Partner (..)
  , mkPartnerId
  , showPartnerType
  ) where

import Data.Aeson (FromJSON (..), ToJSON (..))
import Data.Text (Text)
import GHC.Generics (Generic)

import Data.Text qualified as T

newtype PartnerId = PartnerId {unPartnerId :: Text}
  deriving (Eq, Ord, Show)

instance ToJSON PartnerId where
  toJSON = toJSON . unPartnerId

instance FromJSON PartnerId where
  parseJSON = fmap PartnerId . parseJSON

mkPartnerId :: Text -> Either Text PartnerId
mkPartnerId t
  | T.null t = Left "取引先コードは空にできません"
  | otherwise = Right (PartnerId t)

data PartnerType = Customer | Vendor | BothTypes
  deriving (Bounded, Enum, Eq, Generic, Show)

instance ToJSON PartnerType
instance FromJSON PartnerType

showPartnerType :: PartnerType -> Text
showPartnerType Customer = "得意先"
showPartnerType Vendor = "仕入先"
showPartnerType BothTypes = "両方"

data Partner = Partner
  { partnerId :: PartnerId
  , partnerName :: Text
  , partnerType :: PartnerType
  , partnerActive :: Bool
  }
  deriving (Eq, Generic, Show)

instance ToJSON Partner
instance FromJSON Partner
