module Shell.Interpreters.EventStore
  ( runEventStorePg
  ) where

import Effectful
import Effectful.Dispatch.Dynamic
import Effectful.Error.Static

import Shell.AppError (AppError)
import Shell.Effects (EventStoreEff (..))
import Shell.EventStore (EventStore (..))

runEventStorePg ::
  (Error AppError :> es, IOE :> es) =>
  EventStore ->
  Eff (EventStoreEff : es) a ->
  Eff es a
runEventStorePg store = interpret $ \_ -> \case
  EsLoad -> liftIO (esLoad store) >>= either throwError pure
  EsAppend ver evts -> liftIO (esAppend store ver evts) >>= either throwError pure
