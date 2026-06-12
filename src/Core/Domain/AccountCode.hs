module Core.Domain.AccountCode
  ( AccountCode
  , mkAccountCode
  , unAccountCode
  ) where

import Data.Text (Text)
import qualified Data.Text as T

newtype AccountCode = AccountCode Text
  deriving (Eq, Ord, Show)

mkAccountCode :: Text -> Either Text AccountCode
mkAccountCode t
  | T.null t  = Left (T.pack "勘定科目コードは空にできません")
  | otherwise = Right (AccountCode t)

unAccountCode :: AccountCode -> Text
unAccountCode (AccountCode t) = t
