module Core.Domain.SubAccount
  ( SubAccountId (..)
  , SubAccount (..)
  , mkSubAccountId
  ) where

import Data.Text (Text)

import Data.Text qualified as T

import Core.Domain.AccountCode (AccountCode)

newtype SubAccountId = SubAccountId {unSubAccountId :: Text}
  deriving (Eq, Ord, Show)

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
  deriving (Eq, Show)
