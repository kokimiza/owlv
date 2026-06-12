module Main (main) where

import Data.Text (Text)
import System.Exit (die)

import Data.Text qualified as T

import Shell.AppError (AppError (..))
import Shell.EventStore (connectAndMigrate)
import Shell.TUI.App (runTUI)

main :: IO ()
main = do
  result <- connectAndMigrate
  case result of
    Left err -> die (T.unpack (errorMessage err))
    Right conn -> runTUI conn

errorMessage :: AppError -> Text
errorMessage (AppStorageError msg) = msg
errorMessage (AppDomainError de) = "ドメインエラー: " <> T.pack (show de)
errorMessage (AppInputError msg) = "入���エラー: " <> msg
errorMessage err = "起動エラー: " <> T.pack (show err)
