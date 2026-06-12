-- | 勘定科目マスタ (§2.1 — 勘定科目体系)
module Core.Domain.AccountMaster
  ( AccountCategory (..)
  , AccountMaster (..)
  , defaultNormalBalance
  , showAccountCategory
  ) where

import Data.Text (Text)

import Core.Domain.AccountCode (AccountCode)
import Core.Domain.Journal (DrCr (..))

-- | 勘定科目の大区分
data AccountCategory
  = Asset -- 資産
  | Liability -- 負債
  | Equity -- 純資産
  | Revenue -- 収益
  | Expense -- 費用
  deriving (Bounded, Enum, Eq, Show)

showAccountCategory :: AccountCategory -> Text
showAccountCategory Asset = "資産"
showAccountCategory Liability = "負債"
showAccountCategory Equity = "純資産"
showAccountCategory Revenue = "収益"
showAccountCategory Expense = "費用"

-- | 正常残高: 資産・費用は借方、それ以外は貸方
defaultNormalBalance :: AccountCategory -> DrCr
defaultNormalBalance Asset = Debit
defaultNormalBalance Expense = Debit
defaultNormalBalance _ = Credit

data AccountMaster = AccountMaster
  { amCode :: AccountCode
  , amName :: Text
  , amCategory :: AccountCategory
  , amNormalBalance :: DrCr
  , amActive :: Bool
  }
  deriving (Eq, Show)
