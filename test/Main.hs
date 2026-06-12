module Main (main) where

import Test.Tasty
import qualified Core.JournalSpec

main :: IO ()
main = defaultMain $ testGroup "owlv" [Core.JournalSpec.tests]
