module Shell.Interpreters.AuditLog
  ( runAuditLogNoOp
  , runAuditLogCollect
  ) where

import Data.IORef
import Effectful
import Effectful.Dispatch.Dynamic

import Shell.Effects (AuditEntry, AuditLogEff (..))

{- | Silently discards all audit entries. Use in production until a target
table is provisioned, and in tests that do not inspect audit output.
-}
runAuditLogNoOp :: Eff (AuditLogEff : es) a -> Eff es a
runAuditLogNoOp = interpret $ \_ -> \case
  LogAudit _ -> pure ()

{- | Accumulates entries in an IORef list (most-recent first).
Use in tests to assert that specific commands were logged.
-}
runAuditLogCollect ::
  (IOE :> es) =>
  IORef [AuditEntry] ->
  Eff (AuditLogEff : es) a ->
  Eff es a
runAuditLogCollect ref = interpret $ \_ -> \case
  LogAudit entry -> liftIO $ modifyIORef' ref (entry :)
