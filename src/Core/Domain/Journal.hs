-- | 原始記録ドメイン型 (§2.1)
module Core.Domain.Journal
  ( JournalActionType (..)
  , isCorrectionType
  , RiskTier (..)
  , DrCr (..)
  , JournalLine (..)
  , VoucherRef (..)
  , JournalEntryId (..)
  , JournalEntry (..)
  , debitTotal
  , creditTotal
  ) where

import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import Data.Time (Day)
import Data.UUID (UUID)

import Core.Domain.AccountCode (AccountCode)
import Core.Domain.Money (Money, addMoney, zeroMoney)
import Core.Domain.Organisation (OrganisationId)

-- | 仕訳行為区分 規程§2.1.1
data JournalActionType
  = NewEntry -- 新規起票: first recognition of an economic event
  | Cancellation -- 取消: nullify an existing entry
  | Reversal -- 反対: reverse a balance or period attribution
  | Supplementary -- 追加: correct a shortfall or late-discovered item
  | Reclassification -- 再分類: change display category without altering measurement
  | SwapRefresh -- 洗替: clear and re-evaluate
  | EstimateChange -- 見積変更: IAS 8 prospective estimate change
  deriving (Bounded, Enum, Eq, Show)

-- | Correction types require a prior-entry reference (§4.4).
isCorrectionType :: JournalActionType -> Bool
isCorrectionType NewEntry = False
isCorrectionType _ = True

-- | リスク分類 規程§3.2
data RiskTier = Low | Medium | High | Critical
  deriving (Bounded, Enum, Eq, Ord, Show)

-- | 借方 / 貸方
data DrCr = Debit | Credit
  deriving (Bounded, Enum, Eq, Show)

-- | 仕訳行 (一行)
data JournalLine = JournalLine
  { lineAccount :: AccountCode
  , lineDrCr :: DrCr
  , lineAmount :: Money
  }
  deriving (Eq, Show)

-- | 証憑参照 (§4.1): present or accepted-absent with justification in memo
data VoucherRef
  = VoucherAttached Text -- 証憑参照番号
  | VoucherPending -- 証憑未着 (費用確実・契約条件明確の場合のみ許容)
  deriving (Eq, Show)

newtype JournalEntryId = JournalEntryId UUID
  deriving (Eq, Ord, Show)

-- | 仕訳伝票ヘッダ + 明細
data JournalEntry = JournalEntry
  { entryId :: JournalEntryId
  , entryOrg :: OrganisationId -- 入力部門（権限制御の主体）
  , entryDate :: Day -- 取引発生日 (発生主義)
  , entryActionType :: JournalActionType
  , entryRiskTier :: RiskTier
  , entryVoucher :: VoucherRef
  , entryPriorRef :: Maybe JournalEntryId -- 先行仕訳参照ID (訂正時必須)
  , entryMemo :: Text -- 証憑未着時は根拠・到着予定日を記録
  , entryLines :: NonEmpty JournalLine
  }
  deriving (Eq, Show)

debitTotal :: NonEmpty JournalLine -> Money
debitTotal = foldr step zeroMoney
 where
  step l acc = if lineDrCr l == Debit then addMoney (lineAmount l) acc else acc

creditTotal :: NonEmpty JournalLine -> Money
creditTotal = foldr step zeroMoney
 where
  step l acc = if lineDrCr l == Credit then addMoney (lineAmount l) acc else acc
