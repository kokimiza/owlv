module Main (main) where

import Test.Tasty

import Core.JournalSpec qualified
import Core.MasterSpec qualified

main :: IO ()
main =
  defaultMain $
    testGroup
      "owlv"
      [ Core.JournalSpec.tests
      , Core.MasterSpec.tests
      ]
