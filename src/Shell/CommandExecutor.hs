{-# LANGUAGE BlockArguments #-}

{- | Generic command executor — the sandwich pattern with optimistic retry.
Shell: load events → fold evolve → decide → append new events.
楽観ロック競合が発生した場合は load からやり直し、最大 maxRetries 回試みる。
Orchestration here stays a thin wrapper around pure Core calls; all IO is confined here.

executeCommand is written against ExceptT AppError IO so that error short-circuiting
reads top-to-bottom instead of as nested case-of-case: each step is either an IO
action that already returns Either AppError a (lifted via ExceptT), or a pure
Either DomainError a from decide (lifted via liftEither . first fromDomainError).
The single remaining case match is the one genuine branch point — whether to
retry on AppConcurrencyConflict — everything else falls straight through.

executeCommandEff is the effect-based variant: no IOE in its constraint because
all I/O is mediated through the four Shell effects. Run it with the interpreters
in Shell.Interpreters.* and close with runEff.
-}
module Shell.CommandExecutor
  ( executeCommand
  , loadMasterBook
  , loadJournalBook
  , loadUserBook
  , executeCommandEff
  , loadMasterBookEff
  , loadJournalBookEff
  ) where

import Control.Monad.Except (ExceptT (..), liftEither, runExceptT)
import Data.Bifunctor (first)
import Effectful
import Effectful.Error.Static

import Control.Monad.Except qualified as Exc

import Core.Command (Command)
import Core.Decide (decide)
import Core.Event (Event)
import Core.Evolve (evolve)
import Core.State (AppBook (..), JournalBook, MasterBook, UserBook, initialAppBook)
import Shell.AppError (AppError (..), fromDomainError)
import Shell.Effects
  ( AuditEntry (..)
  , AuditLogEff
  , ClockEff
  , EventStoreEff
  , UserCtxEff
  , appendEvents
  , currentTenant
  , getCurrentTime
  , getCurrentUser
  , loadEvents
  , logAudit
  )
import Shell.EventClassification (isIdentityEvent)
import Shell.EventStore (EventStore (..))

-- | 楽観ロック競合時の最大リトライ回数。
maxRetries :: Int
maxRetries = 3

executeCommand :: EventStore -> Command -> IO (Either AppError [Event])
executeCommand store cmd = runExceptT (go maxRetries)
 where
  go :: Int -> ExceptT AppError IO [Event]
  go 0 = Exc.throwError AppConcurrencyConflict
  go n = do
    (version, events) <- ExceptT (esLoad store)
    let book = foldl' evolve initialAppBook events
    newEvts <- liftEither (first fromDomainError (decide book cmd))
    appendResult <- ExceptT (Right <$> esAppend store version newEvts)
    case appendResult of
      -- 競合 → 最新状態を再ロードして decide からやり直す
      Left AppConcurrencyConflict -> go (n - 1)
      Left err -> Exc.throwError err
      Right () -> pure newEvts

{- | Replay all events and project the given view. The three loadXBook
functions below are this applied to a field accessor — kept as a single
fold-and-project so they can't drift out of sync with each other.
-}
loadProjection :: EventStore -> (AppBook -> a) -> IO (Either AppError a)
loadProjection store project = runExceptT do
  (_, events) <- ExceptT (esLoad store)
  pure (project (foldl' evolve initialAppBook events))

{- | Rebuild the MasterBook read-model by replaying all events.
Call after any successful master command to refresh the TUI cache.
-}
loadMasterBook :: EventStore -> IO (Either AppError MasterBook)
loadMasterBook store = loadProjection store appMasters

-- | Rebuild the JournalBook read-model by replaying all events.
loadJournalBook :: EventStore -> IO (Either AppError JournalBook)
loadJournalBook store = loadProjection store appJournals

-- | Rebuild the UserBook read-model by replaying all events (.claude/user.md §2).
loadUserBook :: EventStore -> IO (Either AppError UserBook)
loadUserBook store = loadProjection store appUsers

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
    newEvts <- either (throwError . fromDomainError) pure (decide book cmd)
    appendResult <- tryError (appendEvents version newEvts)
    case appendResult of
      Left (_, AppConcurrencyConflict) -> go (n - 1)
      Left (_, err) -> throwError err
      Right () -> do
        now <- getCurrentTime
        user <- getCurrentUser
        tid <- currentTenant
        -- Identity stream のみのコマンド（ユーザー管理等）は対象Tenantを持たない
        -- (doc/tenant_isolation.md §5.5)。
        let auditedTenant = if all isIdentityEvent newEvts then Nothing else Just tid
        logAudit (AuditEntry user now newEvts auditedTenant)
        pure newEvts

loadProjectionEff :: (Error AppError :> es, EventStoreEff :> es) => (AppBook -> a) -> Eff es a
loadProjectionEff project = do
  (_, evts) <- loadEvents
  pure (project (foldl' evolve initialAppBook evts))

loadMasterBookEff :: (Error AppError :> es, EventStoreEff :> es) => Eff es MasterBook
loadMasterBookEff = loadProjectionEff appMasters

loadJournalBookEff :: (Error AppError :> es, EventStoreEff :> es) => Eff es JournalBook
loadJournalBookEff = loadProjectionEff appJournals
