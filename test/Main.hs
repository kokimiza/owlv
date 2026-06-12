module Main (main) where

import Test.Tasty

import Core.EclSpec qualified
import Core.FixedAssetSpec qualified
import Core.JournalSpec qualified
import Core.MasterSpec qualified
import Core.MaterialitySpec qualified
import Core.SettlementSpec qualified

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
      ]
