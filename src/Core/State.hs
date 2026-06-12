module Core.State
  ( JournalBook (..)
  , initialJournalBook
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Core.Domain.Journal (JournalEntry, JournalEntryId)

newtype JournalBook = JournalBook
  { journalEntries :: Map JournalEntryId JournalEntry
  }
  deriving (Eq, Show)

initialJournalBook :: JournalBook
initialJournalBook = JournalBook Map.empty
