module Shell.Interpreters.Clock
  ( runClockReal
  , runClockFixed
  ) where

import Data.Time (UTCTime)
import Effectful
import Effectful.Dispatch.Dynamic

import Data.Time qualified as Time

import Shell.Effects (ClockEff (..))

-- | Real clock backed by system time.
runClockReal :: (IOE :> es) => Eff (ClockEff : es) a -> Eff es a
runClockReal = interpret $ \_ -> \case
  GetCurrentTime -> liftIO Time.getCurrentTime

-- | Fixed clock for deterministic tests.
runClockFixed :: UTCTime -> Eff (ClockEff : es) a -> Eff es a
runClockFixed t = interpret $ \_ -> \case
  GetCurrentTime -> pure t
