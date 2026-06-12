-- | Generic command executor — the sandwich pattern.
-- Shell: load events → fold evolve → decide → append new events.
-- UseCases stay pure; all IO is confined here.
module Shell.CommandExecutor
  ( executeCommand
  ) where

import Core.Command (Command)
import Core.Decide (decide)
import Core.Event (Event)
import Core.Evolve (evolve)
import Core.State (initialJournalBook)
import Shell.AppError (AppError, fromDomainError)
import Shell.EventStore (EventStore (..))

executeCommand :: EventStore -> Command -> IO (Either AppError [Event])
executeCommand store cmd = do
  loadResult <- esLoad store
  case loadResult of
    Left err    -> pure (Left err)
    Right events -> do
      let book = foldl' evolve initialJournalBook events
      case decide book cmd of
        Left domErr  -> pure (Left (fromDomainError domErr))
        Right newEvts -> do
          appendResult <- esAppend store newEvts
          case appendResult of
            Left err -> pure (Left err)
            Right () -> pure (Right newEvts)
