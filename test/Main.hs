module Main (main) where

import Test.Tasty

import Core.ClosingSpec qualified
import Core.EclSpec qualified
import Core.FixedAssetSpec qualified
import Core.FxRateSpec qualified
import Core.JournalSpec qualified
import Core.JudgmentLogSpec qualified
import Core.MasterSpec qualified
import Core.MaterialitySpec qualified
import Core.SettlementSpec qualified
import Core.TenantSpec qualified
import Core.UserSpec qualified

main :: IO ()
main =
  defaultMain $
    testGroup
      "owlv"
      [ Core.JournalSpec.tests
      , Core.MasterSpec.tests
      , Core.SettlementSpec.tests
      , Core.FixedAssetSpec.tests
      , Core.EclSpec.tests
      , Core.MaterialitySpec.tests
      , Core.FxRateSpec.tests
      , Core.JudgmentLogSpec.tests
      , Core.ClosingSpec.tests
      , Core.UserSpec.tests
      , Core.TenantSpec.tests
      ]
