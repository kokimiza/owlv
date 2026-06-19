module Main (main) where

import Data.Text (Text)
import System.Exit (die)

import Data.Text qualified as T

import Shell.AppError (AppError (..))
import Shell.EventStore (connectAndMigrate, pgStore)
import Shell.Interpreters.OsIdentity (getOsLoginName)
import Shell.TUI.App (runTUI)
import Shell.UserOps (resolveSessionUser)

{- | (.claude/user.md §4.1) SSH 経由で確立した OS ログイン名を owlv の User
射影と照合してから TUI を起動する。ロック忘れ等で OS 側を抜けてしまった
ユーザーがいても、ここがもう一段の門番になる。
-}
main :: IO ()
main = do
  result <- connectAndMigrate
  case result of
    Left err -> die (T.unpack (errorMessage err))
    Right conn -> do
      osUser <- getOsLoginName
      session <- resolveSessionUser (pgStore conn) osUser
      case session of
        Left msg -> die (T.unpack ("アクセス拒否: " <> msg))
        Right (uid, role) -> runTUI conn uid role

errorMessage :: AppError -> Text
errorMessage (AppStorageError msg) = msg
errorMessage (AppDomainError de) = "ドメインエラー: " <> T.pack (show de)
errorMessage (AppInputError msg) = "入���エラー: " <> msg
errorMessage err = "起動エラー: " <> T.pack (show err)
