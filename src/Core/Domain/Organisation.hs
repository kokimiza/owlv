module Core.Domain.Organisation
  ( OrganisationId (..)
  , Organisation (..)
  , mkOrganisationId
  ) where

import Data.Text (Text)

import Data.Text qualified as T

newtype OrganisationId = OrganisationId {unOrgId :: Text}
  deriving (Eq, Ord, Show)

mkOrganisationId :: Text -> Either Text OrganisationId
mkOrganisationId t
  | T.null t = Left "組織コードは空にできません"
  | otherwise = Right (OrganisationId t)

data Organisation = Organisation
  { orgId :: OrganisationId
  , orgName :: Text
  , orgParent :: Maybe OrganisationId -- 上位部署（部→課→係 の階層）
  , orgActive :: Bool
  }
  deriving (Eq, Show)
