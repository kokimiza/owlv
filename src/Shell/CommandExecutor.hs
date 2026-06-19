{- | Generic command executor — the sandwich pattern with optimistic retry.
Shell: load events → fold evolve → decide → append new events.
楽観ロック競合が発生した場合は load からやり直し、最大 maxRetries 回試みる。
Orchestration here stays a thin wrapper around pure Core calls; all IO is confined here.

executeCommandEff is the effect-based variant: no IOE in its constraint because
all I/O is mediated through the four Shell effects. Run it with the interpreters
in Shell.Interpreters.* and close with runEff.
-}
module Shell.CommandExecutor
  ( executeCommand
  , loadMasterBook
  , loadJournalBook
  , executeCommandEff
  , loadMasterBookEff
  , loadJournalBookEff
  ) where

import Effectful
import Effectful.Error.Static

import Core.Command (Command)
import Core.Decide (decide)
import Core.Event (Event)
import Core.Evolve (evolve)
import Core.State (AppBook (..), JournalBook, MasterBook, initialAppBook)
import Shell.AppError (AppError (..), fromDomainError)
import Shell.Effects
  ( AuditEntry (..)
  , AuditLogEff
  , ClockEff
  , EventStoreEff
  , UserCtxEff
  , appendEvents
  , getCurrentTime
  , getCurrentUser
  , loadEvents
  , logAudit
  )
import Shell.EventStore (EventStore (..))

-- | 楽観ロック競合時の最大リトライ回数。
maxRetries :: Int
maxRetries = 3

executeCommand :: EventStore -> Command -> IO (Either AppError [Event])
executeCommand store cmd = go maxRetries
 where
  go 0 = pure (Left AppConcurrencyConflict)
  go n = do
    loadResult <- esLoad store
    case loadResult of
      Left err -> pure (Left err)
      Right (version, events) -> do
        let book = foldl' evolve initialAppBook events
        case decide book cmd of
          Left domErr -> pure (Left (fromDomainError domErr))
          Right newEvts -> do
            appendResult <- esAppend store version newEvts
            case appendResult of
              -- 競合 → 最新状態を再ロードして decide からやり直す
              Left AppConcurrencyConflict -> go (n - 1)
              Left err -> pure (Left err)
              Right () -> pure (Right newEvts)

{- | Rebuild the MasterBook read-model by replaying all events.
Call after any successful master command to refresh the TUI cache.
-}
loadMasterBook :: EventStore -> IO (Either AppError MasterBook)
loadMasterBook store = do
  result <- esLoad store
  case result of
    Left err -> pure (Left err)
    Right (_, events) -> pure (Right (appMasters (foldl' evolve initialAppBook events)))

-- | Rebuild the JournalBook read-model by replaying all events.
loadJournalBook :: EventStore -> IO (Either AppError JournalBook)
loadJournalBook store = do
  result <- esLoad store
  case result of
    Left err -> pure (Left err)
    Right (_, events) -> pure (Right (appJournals (foldl' evolve initialAppBook events)))

-- ── Effect-based variants ─────────────────────────────────────────────────────

{- | Effect-based command executor. No IOE in the constraint: all I/O is
mediated through EventStoreEff / ClockEff / UserCtxEff / AuditLogEff so the
core decision logic cannot accidentally perform arbitrary IO.
-}
executeCommandEff ::
  ( AuditLogEff :> es
  , ClockEff :> es
  , Error AppError :> es
  , EventStoreEff :> es
  , UserCtxEff :> es
  ) =>
  Command -> Eff es [Event]
executeCommandEff cmd = go maxRetries
 where
  go 0 = throwError AppConcurrencyConflict
  go n = do
    (version, events) <- loadEvents
    let book = foldl' evolve initialAppBook events
    case decide book cmd of
      Left domErr -> throwError (fromDomainError domErr)
      Right newEvts -> do
        appendResult <- tryError (appendEvents version newEvts)
        case appendResult of
          Left (_, AppConcurrencyConflict) -> go (n - 1)
          Left (_, err) -> throwError err
          Right () -> do
            now <- getCurrentTime
            user <- getCurrentUser
            logAudit (AuditEntry user now newEvts)
            pure newEvts

loadMasterBookEff ::
  (Error AppError :> es, EventStoreEff :> es) =>
  Eff es MasterBook
loadMasterBookEff = do
  (_, evts) <- loadEvents
  pure (appMasters (foldl' evolve initialAppBook evts))

loadJournalBookEff ::
  (Error AppError :> es, EventStoreEff :> es) =>
  Eff es JournalBook
loadJournalBookEff = do
  (_, evts) <- loadEvents
  pure (appJournals (foldl' evolve initialAppBook evts))
