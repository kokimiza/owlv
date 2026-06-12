module Core.Domain.Partner
  ( PartnerId (..)
  , PartnerType (..)
  , Partner (..)
  , mkPartnerId
  , showPartnerType
  ) where

import Data.Text (Text)

import Data.Text qualified as T

newtype PartnerId = PartnerId {unPartnerId :: Text}
  deriving (Eq, Ord, Show)

mkPartnerId :: Text -> Either Text PartnerId
mkPartnerId t
  | T.null t = Left "取引先コードは空にできません"
  | otherwise = Right (PartnerId t)

data PartnerType = Customer | Vendor | BothTypes
  deriving (Bounded, Enum, Eq, Show)

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
  deriving (Eq, Show)
