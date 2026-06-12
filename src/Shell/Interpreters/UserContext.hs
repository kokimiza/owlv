module Shell.Interpreters.UserContext
  ( runUserCtxFixed
  , runUserCtxPg
  ) where

import Data.Text (Text)
import Effectful
import Effectful.Dispatch.Dynamic

import Database.PostgreSQL.Simple qualified as PG

import Shell.Effects (UserCtxEff (..))

-- | Fixed user — suitable for tests and single-user TUI sessions.
runUserCtxFixed :: Text -> Eff (UserCtxEff : es) a -> Eff es a
runUserCtxFixed uid = interpret $ \_ -> \case
  GetCurrentUser -> pure uid

{- | PG RLS interpreter: issues SET app.current_user = ? before returning so
row-level security policies see the correct principal.
-}
runUserCtxPg ::
  (IOE :> es) =>
  PG.Connection ->
  Text -> -- SSH-derived username
  Eff (UserCtxEff : es) a ->
  Eff es a
runUserCtxPg conn uid = interpret $ \_ -> \case
  GetCurrentUser -> do
    _ <- liftIO $ PG.execute conn "SET app.current_user = ?" (PG.Only uid)
    pure uid
