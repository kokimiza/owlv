module Core.Command
  ( Command (..)
  ) where

import Core.Domain.Journal (JournalEntry)

data Command
  = RecordJournalEntry JournalEntry
  deriving (Eq, Show)
