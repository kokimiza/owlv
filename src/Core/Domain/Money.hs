module Core.Domain.Money
  ( Money
  , mkMoney
  , unMoney
  , zeroMoney
  , addMoney
  , subtractMoney
  , negateMoney
  , debitCreditBalance
  ) where

import Data.Aeson (FromJSON (..), ToJSON (..), withText)
import Data.Decimal (Decimal)

import Data.Text qualified as T

-- | IFRS monetary amount.  Never use Double — see CLAUDE.md.
newtype Money = Money {unMoney :: Decimal}
  deriving (Eq, Ord, Show)

-- | Serialize as decimal string, e.g. "1000.00", to preserve exact precision.
instance ToJSON Money where
  toJSON (Money d) = toJSON (show d)

instance FromJSON Money where
  parseJSON = withText "Money" $ \t ->
    case reads (T.unpack t) of
      [(d, "")] -> pure (Money d)
      _ -> fail ("invalid Money: " <> T.unpack t)

mkMoney :: Decimal -> Money
mkMoney = Money

zeroMoney :: Money
zeroMoney = Money 0

addMoney :: Money -> Money -> Money
addMoney (Money a) (Money b) = Money (a + b)

subtractMoney :: Money -> Money -> Money
subtractMoney (Money a) (Money b) = Money (a - b)

negateMoney :: Money -> Money
negateMoney (Money a) = Money (negate a)

-- | Returns (debitTotal - creditTotal); zero means balanced.
debitCreditBalance :: Money -> Money -> Money
debitCreditBalance dr cr = subtractMoney dr cr
