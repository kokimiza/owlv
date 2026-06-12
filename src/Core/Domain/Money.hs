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

import Data.Decimal (Decimal)

-- | IFRS monetary amount.  Never use Double — see CLAUDE.md.
newtype Money = Money {unMoney :: Decimal}
  deriving (Eq, Ord, Show)

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
