module Core.Event
  ( Event (..)
  ) where

import Core.Domain.Journal (JournalEntry)

data Event
  = JournalEntryRecorded JournalEntry
  deriving (Eq, Show)
