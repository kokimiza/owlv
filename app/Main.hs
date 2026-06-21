module Main (main) where

import Data.Text (Text)
import System.Exit (die)

import Data.Text qualified as T

import Core.Domain.Tenant (defaultTenantId)
import Shell.AppError (AppError (..))
import Shell.EventStore (connectDb, forTenant)
import Shell.Interpreters.OsIdentity (getOsLoginName)
import Shell.TUI.App (runTUI)
import Shell.UserOps (resolveSessionUser)

{- | (.claude/user.md §4.1) SSH 経由で確立した OS ログイン名を owlv の User
射影と照合してから TUI を起動する。ロック忘れ等で OS 側を抜けてしまった
ユーザーがいても、ここがもう一段の門番になる。

Stage 1（doc/tenant_isolation.md §5.1）: Tenant選択UIがまだないため
defaultTenantId に固定で `forTenant` する。スキーマのマイグレーションは
ここでは行わない — `infra/vm-db/schema.sql` を owl_migrator で別途適用
済みであることを前提にする (doc/tenant_isolation.md §6.4)。
-}
main :: IO ()
main = do
  connResult <- connectDb
  case connResult of
    Left err -> die (T.unpack (errorMessage err))
    Right conn -> do
      storeResult <- forTenant conn defaultTenantId
      case storeResult of
        Left err -> die (T.unpack (errorMessage err))
        Right store -> do
          osUser <- getOsLoginName
          session <- resolveSessionUser store osUser
          case session of
            Left msg -> die (T.unpack ("アクセス拒否: " <> msg))
            Right (uid, role) -> runTUI conn store uid role

errorMessage :: AppError -> Text
errorMessage (AppStorageError msg) = msg
errorMessage (AppDomainError de) = "ドメインエラー: " <> T.pack (show de)
errorMessage (AppInputError msg) = "入���エラー: " <> msg
errorMessage err = "起動エラー: " <> T.pack (show err)
