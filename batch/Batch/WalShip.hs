module Batch.WalShip (walShip) where

import Effectful
import Effectful.Error.Static
import System.Exit (ExitCode (..))

import Shell.AppError (AppError)
import Shell.Effects (ClockEff)

{- | WAL アーカイブ転送バッチ。
TODO: implement WAL segment copy to archive storage
-}
walShip ::
  ( ClockEff :> es
  , Error AppError :> es
  , IOE :> es
  ) =>
  Eff es ExitCode
walShip = pure ExitSuccess
