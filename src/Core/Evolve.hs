module Core.Evolve
  ( evolve
  ) where

import qualified Data.Map.Strict as Map
import Core.Domain.Journal (entryId)
import Core.Event (Event (..))
import Core.State (JournalBook (..))

evolve :: JournalBook -> Event -> JournalBook
evolve book (JournalEntryRecorded entry) =
  book{journalEntries = Map.insert (entryId entry) entry (journalEntries book)}
