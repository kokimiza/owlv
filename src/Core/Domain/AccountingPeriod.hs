-- | 会計期間 — 締切制御の単位。JournalEntry の発生日はオープン期間のみ許容される。
module Core.Domain.AccountingPeriod
  ( AccountingPeriodId (..)
  , PeriodStatus (..)
  , AccountingPeriod (..)
  , periodIdOf
  ) where

import Data.Aeson (FromJSON (..), ToJSON (..))
import Data.Time (Day, toGregorian)
import GHC.Generics (Generic)

-- | 年月を自然キーとして持つ期間識別子
data AccountingPeriodId = AccountingPeriodId
  { apYear :: Int
  , apMonth :: Int -- 1..12
  }
  deriving (Eq, Generic, Ord, Show)

instance ToJSON AccountingPeriodId
instance FromJSON AccountingPeriodId

data PeriodStatus = PeriodOpen | PeriodClosed
  deriving (Bounded, Enum, Eq, Generic, Show)

instance ToJSON PeriodStatus
instance FromJSON PeriodStatus

data AccountingPeriod = AccountingPeriod
  { apId :: AccountingPeriodId
  , apStatus :: PeriodStatus
  }
  deriving (Eq, Generic, Show)

instance ToJSON AccountingPeriod
instance FromJSON AccountingPeriod

-- | Day から AccountingPeriodId を導出する
periodIdOf :: Day -> AccountingPeriodId
periodIdOf day =
  let (yr, mo, _) = toGregorian day
  in AccountingPeriodId (fromIntegral yr) mo
