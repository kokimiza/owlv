module Main (main) where

import Shell.EventStore (newInMemoryEventStore)
import Shell.TUI.App (runTUI)

main :: IO ()
main = do
  store <- newInMemoryEventStore
  runTUI store
