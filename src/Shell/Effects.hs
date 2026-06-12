{-# LANGUAGE TypeFamilies #-}

{- | Effect declarations for the four Shell concerns.

Each effect has two interpreters: a production one (PostgreSQL / system clock
/ SSH user / DB audit table) and a test-friendly one (in-memory IORef / fixed
time / fixed user / collect into IORef). See Shell.Interpreters.* for runners.

The effect stack used by executeCommandEff requires no IOE — all I/O is
mediated through the four effects, so the pure core cannot accidentally
escape through liftIO.
-}
module Shell.Effects
  ( -- * EventStore
    EventStoreEff (..)
  , loadEvents
  , appendEvents

    -- * Clock
  , ClockEff (..)
  , getCurrentTime
  , getToday

    -- * UserContext
  , UserCtxEff (..)
  , getCurrentUser

    -- * AuditLog
  , AuditEntry (..)
  , AuditLogEff (..)
  , logAudit
  ) where

import Data.Text (Text)
import Data.Time (Day, UTCTime, utctDay)
import Effectful
import Effectful.Dispatch.Dynamic

import Core.Event (Event)
import Shell.EventStore (StreamVersion)

-- ── EventStore ───────────────────────────────────────────────────────────────

data EventStoreEff :: Effect where
  EsLoad :: EventStoreEff m (StreamVersion, [Event])
  EsAppend :: StreamVersion -> [Event] -> EventStoreEff m ()

type instance DispatchOf EventStoreEff = Dynamic

loadEvents :: (EventStoreEff :> es) => Eff es (StreamVersion, [Event])
loadEvents = send EsLoad

appendEvents :: (EventStoreEff :> es) => StreamVersion -> [Event] -> Eff es ()
appendEvents ver evts = send (EsAppend ver evts)

-- ── Clock ────────────────────────────────────────────────────────────────────

data ClockEff :: Effect where
  GetCurrentTime :: ClockEff m UTCTime

type instance DispatchOf ClockEff = Dynamic

getCurrentTime :: (ClockEff :> es) => Eff es UTCTime
getCurrentTime = send GetCurrentTime

getToday :: (ClockEff :> es) => Eff es Day
getToday = utctDay <$> getCurrentTime

-- ── UserContext ──────────────────────────────────────────────────────────────

data UserCtxEff :: Effect where
  GetCurrentUser :: UserCtxEff m Text

type instance DispatchOf UserCtxEff = Dynamic

getCurrentUser :: (UserCtxEff :> es) => Eff es Text
getCurrentUser = send GetCurrentUser

-- ── AuditLog ─────────────────────────────────────────────────────────────────

data AuditEntry = AuditEntry
  { auditUser :: Text
  , auditAt :: UTCTime
  , auditEvents :: [Event]
  }
  deriving (Show)

data AuditLogEff :: Effect where
  LogAudit :: AuditEntry -> AuditLogEff m ()

type instance DispatchOf AuditLogEff = Dynamic

logAudit :: (AuditLogEff :> es) => AuditEntry -> Eff es ()
logAudit e = send (LogAudit e)
