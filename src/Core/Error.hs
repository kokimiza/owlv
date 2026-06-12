module Core.Error
  ( DomainError (..)
  ) where

import Core.Domain.Journal (JournalActionType, JournalEntryId)
import Core.Domain.Money (Money)

data DomainError
  = -- | 借貸不一致 (§4.1): debit total ≠ credit total
    UnbalancedEntry Money Money          -- (debitTotal, creditTotal)
  | -- | 訂正仕訳に先行仕訳参照IDがない (§4.1, §4.4)
    CorrectionMissingPriorRef JournalActionType
  | -- | 証憑未着なのに摘要が空 (§4.1)
    PendingVoucherMissingMemo
  | -- | 同一IDの仕訳が既に登録済み
    DuplicateEntryId JournalEntryId
  deriving (Eq, Show)
