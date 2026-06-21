{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE BlockArguments #-}

module Main (main) where

import Control.Monad.Except
import Control.Monad.IO.Class (liftIO)
import Data.Text (Text)
import System.Exit (die)

import Data.Text qualified as T

import Core.Domain.Tenant (defaultTenantId)
import Shell.AppError (AppError (..))
import Shell.EventStore (connectDb, forTenant)
import Shell.Interpreters.OsIdentity (getOsLoginName)
import Shell.TUI.App (runTUI)
import Shell.UserOps (resolveSessionUser)

{- | (doc/user.md §4.1) SSH 経由で確立した OS ログイン名を owlv の User
射影と照合してから TUI を起動する。ロック忘れ等で OS 側を抜けてしまった
ユーザーがいても、ここがもう一段の門番になる。
-}
main :: IO ()
main = do
  result <- runExceptT do
    -- 1. DB接続 (IO (Either AppError Connection))
    conn <- ExceptT connectDb

    -- 2. テナント解決 (IO (Either AppError EventStore))
    store <- ExceptT $ forTenant conn defaultTenantId

    -- 3. OSユーザ名取得、セッション解決 (IO (Either Text (UserId, Role, Tenant)))
    --    ※ここだけエラーが Text なので withExceptT で AppInputError 等に包む
    osUser <- liftIO getOsLoginName
    (uid, role, tenant) <-
      withExceptT AppInputError $ ExceptT $ resolveSessionUser store osUser

    -- すべて成功したら、必要なコンテキストを返してブロックを抜ける
    pure (conn, store, uid, role, tenant)

  case result of
    Left err -> die (T.unpack (errorMessage err))
    Right (conn, store, uid, role, tenant) -> runTUI conn store uid role tenant

errorMessage :: AppError -> Text
errorMessage (AppStorageError msg) = msg
errorMessage (AppDomainError de) = "ドメインエラー: " <> T.pack (show de)
errorMessage (AppInputError msg) = "アクセス拒否/入力エラー: " <> msg
errorMessage err = "起動エラー: " <> T.pack (show err)
