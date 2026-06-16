{- | Append-only event store backed by PostgreSQL, with optimistic concurrency control.

Schema (run once per database, handled by migrate; full design notes in
infra/vm-db/doc/event-store.md):
  CREATE TABLE IF NOT EXISTS events (
    seq          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_id     UUID        NOT NULL DEFAULT uuidv7(),
    event_type   TEXT        NOT NULL,
    payload      JSONB       NOT NULL,
    payload_type TEXT GENERATED ALWAYS AS (payload ->> 'type') VIRTUAL,
    recorded_at  TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT events_type_matches_payload
      CHECK (payload_type IS NULL OR payload_type = event_type)
  );
  CREATE UNIQUE INDEX IF NOT EXISTS events_event_id_key ON events (event_id);
  CREATE INDEX IF NOT EXISTS events_event_type_seq_idx ON events (event_type, seq);
  CREATE INDEX IF NOT EXISTS events_recorded_at_idx ON events (recorded_at);
  CREATE TABLE IF NOT EXISTS stream_version (
    id      INT    PRIMARY KEY,
    version BIGINT NOT NULL DEFAULT 0,
    CONSTRAINT stream_version_singleton CHECK (id = 1)
  );

Connection is configured via libpq environment variables:
  PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD

Optimistic concurrency:
  esLoad returns the current StreamVersion alongside events.
  esAppend takes the expected StreamVersion; if another writer has already
  advanced the version, it returns Left AppConcurrencyConflict without writing.
  CommandExecutor retries the full load→decide→append cycle on conflict.
-}
module Shell.EventStore
  ( StreamVersion (..)
  , EventStore (..)
  , connectAndMigrate
  , pgStore
  , newPostgresEventStore
  ) where

import Control.Exception (SomeException, try)
import Data.Int (Int64)
import Data.Text (Text)

import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as AesonKey
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as T
import Database.PostgreSQL.Simple qualified as PG

import Core.Event (Event)
import Shell.AppError (AppError (..))

-- | ストリームのイベント追記回数。楽観ロックの比較値として使う。
newtype StreamVersion = StreamVersion Int64
  deriving (Eq, Ord, Show)

{- | Interface for the append-only event store.
esLoad returns the current version together with events.
esAppend takes the expected version and returns AppConcurrencyConflict when
another writer has already advanced the stream.
-}
data EventStore = EventStore
  { esLoad :: IO (Either AppError (StreamVersion, [Event]))
  , esAppend :: StreamVersion -> [Event] -> IO (Either AppError ())
  }

{- | Connect to PostgreSQL and run schema migration. Returns the raw connection
so callers can pass it to both pgStore and the effectful interpreters.
-}
connectAndMigrate :: IO (Either AppError PG.Connection)
connectAndMigrate = do
  result <- try @SomeException (PG.connectPostgreSQL "")
  case result of
    Left ex ->
      pure
        ( Left
            ( AppStorageError
                ( T.unlines
                    [ "PostgreSQL 接続失敗"
                    , ""
                    , "接続情報を libpq 環境変数で設定してください:"
                    , "  export PGHOST=localhost"
                    , "  export PGPORT=5432"
                    , "  export PGDATABASE=owlv"
                    , "  export PGUSER=postgres"
                    , "  export PGPASSWORD=..."
                    , ""
                    , "詳細: " <> T.pack (show ex)
                    ]
                )
            )
        )
    Right conn -> do
      migResult <- try @SomeException (migrate conn)
      case migResult of
        Left ex -> pure (Left (AppStorageError (T.pack (show ex))))
        Right () -> pure (Right conn)

-- | Wrap a connection in the record-of-functions interface.
pgStore :: PG.Connection -> EventStore
pgStore = mkPgStore

-- | Convenience: connect, migrate, and build the EventStore record.
newPostgresEventStore :: IO (Either AppError EventStore)
newPostgresEventStore = fmap (fmap mkPgStore) connectAndMigrate

-- ── internal ────────────────────────────────────────────────────────────────

migrate :: PG.Connection -> IO ()
migrate conn = do
  _ <-
    PG.execute_
      conn
      "CREATE TABLE IF NOT EXISTS events \
      \( seq          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY \
      \, event_id     UUID        NOT NULL DEFAULT uuidv7() \
      \, event_type   TEXT        NOT NULL \
      \, payload      JSONB       NOT NULL \
      \, payload_type TEXT GENERATED ALWAYS AS (payload ->> 'type') VIRTUAL \
      \, recorded_at  TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp() \
      \, CONSTRAINT events_type_matches_payload \
      \    CHECK (payload_type IS NULL OR payload_type = event_type) \
      \)"
  _ <-
    PG.execute_
      conn
      "CREATE UNIQUE INDEX IF NOT EXISTS events_event_id_key ON events (event_id)"
  _ <-
    PG.execute_
      conn
      "CREATE INDEX IF NOT EXISTS events_event_type_seq_idx ON events (event_type, seq)"
  _ <-
    PG.execute_
      conn
      "CREATE INDEX IF NOT EXISTS events_recorded_at_idx ON events (recorded_at)"
  _ <-
    PG.execute_
      conn
      "CREATE TABLE IF NOT EXISTS stream_version \
      \( id      INT    PRIMARY KEY \
      \, version BIGINT NOT NULL DEFAULT 0 \
      \, CONSTRAINT stream_version_singleton CHECK (id = 1) \
      \)"
  -- バージョンを既存イベント数で初期化（既に行がある場合は何もしない）
  _ <-
    PG.execute_
      conn
      "INSERT INTO stream_version (id, version) \
      \SELECT 1, COUNT(*) FROM events \
      \ON CONFLICT (id) DO NOTHING"
  pure ()

mkPgStore :: PG.Connection -> EventStore
mkPgStore conn =
  EventStore
    { esLoad = safeIO (loadFromPg conn)
    , esAppend = appendToPg conn
    }

loadFromPg :: PG.Connection -> IO (StreamVersion, [Event])
loadFromPg conn = do
  [PG.Only ver] <-
    PG.query_ conn "SELECT version FROM stream_version WHERE id = 1" :: IO [PG.Only Int64]
  rows <-
    PG.query_ conn "SELECT payload::text FROM events ORDER BY seq ASC" :: IO [PG.Only Text]
  events <- mapM decodeRow rows
  pure (StreamVersion ver, events)
 where
  decodeRow (PG.Only txt) =
    case Aeson.eitherDecodeStrict (BS8.pack (T.unpack txt)) of
      Left err -> fail ("event decode failed: " <> err)
      Right ev -> pure ev

-- | バージョンが一致する場合のみ追記し、version カウンタを進める。
appendToPg :: PG.Connection -> StreamVersion -> [Event] -> IO (Either AppError ())
appendToPg conn (StreamVersion expected) evts = do
  result <- try @SomeException $ PG.withTransaction conn $ do
    -- FOR UPDATE でバージョン行を行ロック → 同時書き込みを直列化
    [PG.Only current] <-
      PG.query_ conn "SELECT version FROM stream_version WHERE id = 1 FOR UPDATE" ::
        IO [PG.Only Int64]
    if current /= expected
      then pure (Left AppConcurrencyConflict)
      else do
        mapM_ insertOne evts
        _ <-
          PG.execute
            conn
            "UPDATE stream_version SET version = version + ? WHERE id = 1"
            (PG.Only (fromIntegral (length evts) :: Int64))
        pure (Right ())
  pure $ case result of
    Left ex -> Left (AppStorageError (T.pack (show ex)))
    Right x -> x
 where
  insertOne ev =
    let payload = T.pack (BS8.unpack (LBS.toStrict (Aeson.encode ev)))
        typ = eventType ev
    in PG.execute
         conn
         "INSERT INTO events (event_type, payload) VALUES (?, ?::jsonb)"
         (typ :: Text, payload :: Text)

eventType :: Event -> Text
eventType ev = case Aeson.toJSON ev of
  Aeson.Object km ->
    case KeyMap.lookup (AesonKey.fromString "type") km of
      Just (Aeson.String t) -> t
      _ -> "Unknown"
  _ -> "Unknown"

-- | Catch any synchronous exception and wrap it as a StorageError.
safeIO :: IO a -> IO (Either AppError a)
safeIO action = do
  result <- try @SomeException action
  pure $ case result of
    Left ex -> Left (AppStorageError (T.pack (show ex)))
    Right v -> Right v
