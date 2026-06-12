-- | EventStore abstraction.
--
-- Designed for a *local* PostgreSQL instance (same host as the app).
-- For now the only concrete implementation is in-memory (IORef).
-- The Postgres implementation is stubbed; it will be wired once the
-- local PG server is running — connect logic goes in newPostgresEventStore.
module Shell.EventStore
  ( EventStore (..)
  , newInMemoryEventStore
  -- , newPostgresEventStore  -- uncomment when PG is configured
  ) where

import Control.Exception (SomeException, try)
import Data.IORef
import qualified Data.Text as T
import Core.Event (Event)
import Shell.AppError (AppError (..))

-- | Interface for the append-only event store.
-- Both fields return IO (Either AppError _) — no exceptions escape.
data EventStore = EventStore
  { esLoad   :: IO (Either AppError [Event])
  , esAppend :: [Event] -> IO (Either AppError ())
  }

-- | In-memory implementation backed by IORef.
-- Suitable for tests and early development.
newInMemoryEventStore :: IO EventStore
newInMemoryEventStore = do
  ref <- newIORef []
  pure
    EventStore
      { esLoad   = safeIO (readIORef ref)
      , esAppend = \evts -> safeIO (modifyIORef' ref (<> evts))
      }

-- ── helpers ────────────────────────────────────────────────────────────────

-- | Catch any synchronous exception and wrap it as a StorageError.
safeIO :: IO a -> IO (Either AppError a)
safeIO action = do
  result <- try @SomeException action
  pure $ case result of
    Left  ex -> Left (StorageError (T.pack (show ex)))
    Right v  -> Right v

-- ── PostgreSQL stub ─────────────────────────────────────────────────────────
-- Future: connect to local PostgreSQL (not remote).
-- Schema: a single `events` table:
--   (seq BIGSERIAL, event_type TEXT, payload JSONB, recorded_at TIMESTAMPTZ)
-- All inserts are append-only; UPDATE / DELETE on this table are forbidden.
--
-- newPostgresEventStore :: ByteString -> IO (Either AppError EventStore)
-- newPostgresEventStore connStr = do
--   result <- try @SomeException (PG.connectPostgreSQL connStr)
--   case result of
--     Left  ex   -> pure (Left (ConnectionError (T.pack (show ex))))
--     Right conn -> pure (Right (pgStore conn))
--
-- pgStore :: PG.Connection -> EventStore
-- pgStore conn = EventStore
--   { esLoad   = safeIO (loadFromPg conn)
--   , esAppend = \evts -> safeIO (appendToPg conn evts)
--   }
