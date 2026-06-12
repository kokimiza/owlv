module Core.Domain.Organisation
  ( OrganisationId (..)
  , Organisation (..)
  , mkOrganisationId
  ) where

import Data.Aeson (FromJSON (..), ToJSON (..))
import Data.Text (Text)
import GHC.Generics (Generic)

import Data.Text qualified as T

newtype OrganisationId = OrganisationId {unOrgId :: Text}
  deriving (Eq, Ord, Show)

-- | Store as plain text string.
instance ToJSON OrganisationId where
  toJSON = toJSON . unOrgId

instance FromJSON OrganisationId where
  parseJSON = fmap OrganisationId . parseJSON

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
  deriving (Eq, Generic, Show)

instance ToJSON Organisation
instance FromJSON Organisation
