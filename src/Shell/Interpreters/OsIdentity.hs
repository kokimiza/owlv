{- | SSH 経由で確立した OS ログイン名の取得 (doc/user.md §4.1)

owl-session (ForceCommand ラッパー、infra/vm-ap/setup.sh) は接続してきた本人
ではなく専用サービスアカウント owl-app として owlv を起動する
(doas -u owl-app; doc/user.md §3.2 のゼロ権限委譲)。そのため実行中の
プロセスの実ユーザーは常に owl-app であり、getLoginName は使えない。
本人の OS ユーザー名は owl-session が doas 越しに渡す環境変数
OWLV_SSH_USER から取得する。これが無い場合（コンソールでの直接実行など）は
getLoginName にフォールバックする。
-}
module Shell.Interpreters.OsIdentity
  ( getOsLoginName
  , getRootAdminUsernameEnv
  ) where

import Control.Applicative ((<|>))
import Data.Text (Text)
import System.Environment (lookupEnv)
import System.Posix.User (getLoginName)

import Data.Text qualified as T

getOsLoginName :: IO Text
getOsLoginName = do
  mSshUser <- lookupEnv "OWLV_SSH_USER"
  mUser <- lookupEnv "USER"
  mLogName <- lookupEnv "LOGNAME"
  case mSshUser <|> mUser <|> mLogName of
    Just u -> pure (T.pack u)
    Nothing -> T.pack <$> getLoginName

{- | doc/user.md §7: provision.sh が owl-config.toml の [user] root_admin_username を
OWLV_ROOT_ADMIN_USERNAME として owl-session の環境に注入する想定（infra 側の対応作業）。
未設定ならブートストラップ経路は常に無効。
-}
getRootAdminUsernameEnv :: IO (Maybe Text)
getRootAdminUsernameEnv = fmap T.pack <$> lookupEnv "OWLV_ROOT_ADMIN_USERNAME"
