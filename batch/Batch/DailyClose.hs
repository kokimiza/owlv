module Batch.DailyClose (dailyClose) where

import Effectful
import Effectful.Error.Static
import System.Exit (ExitCode (..))

import Shell.AppError (AppError)
import Shell.Effects (AuditLogEff, ClockEff, EventStoreEff, UserCtxEff)

{- | 日次決算クローズバッチ。spec §4 の九フェーズクローズパイプラインを実行する。
TODO: implement §4 nine-phase closing pipeline
-}
dailyClose ::
  ( AuditLogEff :> es
  , ClockEff :> es
  , Error AppError :> es
  , EventStoreEff :> es
  , UserCtxEff :> es
  ) =>
  Eff es ExitCode
dailyClose = pure ExitSuccess
