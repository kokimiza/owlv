module Core.Domain.AccountCode
  ( AccountCode
  , mkAccountCode
  , unAccountCode
  ) where

import Data.Aeson (FromJSON (..), ToJSON (..))
import Data.Text (Text)

import Data.Text qualified as T

newtype AccountCode = AccountCode Text
  deriving (Eq, Ord, Show)

-- | Store as plain text; deserialize via mkAccountCode for validation.
instance ToJSON AccountCode where
  toJSON (AccountCode t) = toJSON t

instance FromJSON AccountCode where
  parseJSON v = do
    t <- parseJSON v
    case mkAccountCode t of
      Right ac -> pure ac
      Left err -> fail (T.unpack err)

mkAccountCode :: Text -> Either Text AccountCode
mkAccountCode t
  | T.null t = Left (T.pack "勘定科目コードは空にできません")
  | otherwise = Right (AccountCode t)

unAccountCode :: AccountCode -> Text
unAccountCode (AccountCode t) = t
