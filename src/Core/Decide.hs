module Core.Decide
  ( decide
  ) where

import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Core.Command (Command (..))
import Core.Domain.Journal
  ( JournalEntry (..)
  , VoucherRef (..)
  , creditTotal
  , debitTotal
  , isCorrectionType
  )
import Core.Error (DomainError (..))
import Core.Event (Event (..))
import Core.State (JournalBook (..))

decide :: JournalBook -> Command -> Either DomainError [Event]
decide book (RecordJournalEntry entry) = do
  checkDuplicate book entry
  checkBalance entry
  checkCorrectionRef entry
  checkVoucherMemo entry
  pure [JournalEntryRecorded entry]

-- ── helpers ────────────────────────────────────────────────────────────────

check :: Bool -> DomainError -> Either DomainError ()
check True  err = Left err
check False _   = Right ()

checkDuplicate :: JournalBook -> JournalEntry -> Either DomainError ()
checkDuplicate book entry =
  check
    (Map.member (entryId entry) (journalEntries book))
    (DuplicateEntryId (entryId entry))

-- | 借貸一致検証 規程§4.1
checkBalance :: JournalEntry -> Either DomainError ()
checkBalance entry =
  let dr = debitTotal  (entryLines entry)
      cr = creditTotal (entryLines entry)
  in check (dr /= cr) (UnbalancedEntry dr cr)

-- | 訂正仕訳は先行仕訳参照ID必須 規程§4.1, §4.4
checkCorrectionRef :: JournalEntry -> Either DomainError ()
checkCorrectionRef entry =
  check
    (isCorrectionType (entryActionType entry) && null (entryPriorRef entry))
    (CorrectionMissingPriorRef (entryActionType entry))

-- | 証憑未着の場合は摘要（根拠・到着予定日）が必須 規程§4.1
checkVoucherMemo :: JournalEntry -> Either DomainError ()
checkVoucherMemo entry = case entryVoucher entry of
  VoucherPending -> check (T.null (entryMemo entry)) PendingVoucherMissingMemo
  VoucherAttached _ -> Right ()
