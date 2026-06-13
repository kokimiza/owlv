module Batch.VacuumCheck (vacuumCheck) where

import Effectful
import Effectful.Error.Static
import System.Exit (ExitCode (..))

import Shell.AppError (AppError)

{- | PostgreSQL バキューム遅延確認バッチ。
TODO: query pg_stat_user_tables and alert if dead_tuple_ratio exceeds threshold
-}
vacuumCheck ::
  ( Error AppError :> es
  , IOE :> es
  ) =>
  Eff es ExitCode
vacuumCheck = pure ExitSuccess
