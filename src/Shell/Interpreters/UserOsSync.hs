{-# LANGUAGE BlockArguments #-}

{- | AP VM の OS アカウントへの一方向プロジェクション (doc/user.md §3)

owlv-app から doas 経由で /usr/local/sbin/owl-user-sync (単一の許可コマンド)
だけを呼ぶ。"スクリプトの自己申告だけで成功を確定しない" 方針のため、apply の
あとに必ず observe（読み取り専用の生の事実報告）を取り、望ましい状態との
突合はこの Haskell モジュール側で行う。

owl-user-sync が見つからない環境（macOS 開発機等）では SyncToolMissing を返す。
これは「成功した」という偽の確定を避けるための安全側のフォールバックであり、
TUI は Pending のまま留め置く。

applyAndVerify は ExceptT SyncOutcome IO で書かれている: runDoas が doas の
失敗を即座に SyncOutcome として投げるので、成功系だけが縦に並ぶ。
最後に Either SyncOutcome SyncOutcome を `either id id` で1つの SyncOutcome
へ畳むだけで、呼び出し元には常に総合判定の値だけが返る。
-}
module Shell.Interpreters.UserOsSync
  ( DesiredOsStatus (..)
  , UserSyncRequest (..)
  , SyncOutcome (..)
  , ObservedState (..)
  , applyAndVerify
  , defaultHelperPath
  ) where

import Control.Monad.Except (ExceptT (..), runExceptT, throwError)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (FromJSON (..), ToJSON (..), decode, encode, object, withObject, (.:), (.=))
import Data.List (sort)
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8)
import System.Exit (ExitCode (..))
import System.IO.Error (catchIOError)
import System.Process (readProcessWithExitCode)

import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Lazy.Char8 qualified as BLC
import Data.Text qualified as T

-- | owl-user-sync に同期させたい状態。文字列比較ではなく型で区別する。
data DesiredOsStatus = OsActive | OsSuspended | OsRemoved
  deriving (Eq, Show)

renderDesiredStatus :: DesiredOsStatus -> Text
renderDesiredStatus OsActive = "Active"
renderDesiredStatus OsSuspended = "Suspended"
renderDesiredStatus OsRemoved = "Removed"

-- | owl-user-sync に渡す望ましい状態。
data UserSyncRequest = UserSyncRequest
  { syncUsername :: Text
  , syncUid :: Int
  , syncRole :: Text -- "Operator" | "Maintainer" | "Admin"
  , syncStatus :: DesiredOsStatus
  , syncSshKeys :: [Text]
  }
  deriving (Eq, Show)

instance ToJSON UserSyncRequest where
  toJSON r =
    object
      [ "username" .= syncUsername r
      , "uid" .= syncUid r
      , "role" .= syncRole r
      , "status" .= renderDesiredStatus (syncStatus r)
      , "ssh_keys" .= syncSshKeys r
      ]

-- | owl-user-sync --observe <username> が報告する生の事実。
data ObservedState = ObservedState
  { obsExists :: Bool
  , obsUid :: Maybe Int
  , obsShell :: Maybe Text
  , obsGroups :: [Text]
  , obsSshKeys :: [Text]
  }
  deriving (Eq, Show)

instance FromJSON ObservedState where
  parseJSON = withObject "ObservedState" $ \o ->
    ObservedState
      <$> o .: "exists"
      <*> o .: "uid"
      <*> o .: "shell"
      <*> o .: "groups"
      <*> o .: "ssh_keys"

data SyncOutcome
  = SyncSucceeded
  | SyncVerifyMismatch Text -- apply 自体は exit 0 だったが observe の事実と望ましい状態が不一致
  | SyncApplyFailed Text -- apply/observe が非ゼロ終了
  | SyncToolMissing -- doas / owl-user-sync が見つからない（開発環境など）
  deriving (Eq, Show)

defaultHelperPath :: FilePath
defaultHelperPath = "/usr/local/sbin/owl-user-sync"

{- | apply → observe → 突合 を1回で行う。
"スクリプトが成功と言った" だけでは確定せず、observe で得た生の事実を
Haskell 側で desired state と比較してから SyncSucceeded を返す。
-}
applyAndVerify :: FilePath -> UserSyncRequest -> IO SyncOutcome
applyAndVerify helperPath req =
  either id id <$> runExceptT do
    _ <- runDoas helperPath ["--apply", toJsonArg req]
    out <- runDoas helperPath ["--observe", T.unpack (syncUsername req)]
    case decode (BL.fromStrict (encodeUtf8 out)) of
      Nothing -> throwError (SyncVerifyMismatch "observe の出力をパースできません")
      Just obs -> pure (compareState req obs)

-- | Haskell 側で行う独立した突合（owl-user-sync の判定結果は使わない）。
compareState :: UserSyncRequest -> ObservedState -> SyncOutcome
compareState req obs
  | OsRemoved <- syncStatus req =
      if obsExists obs
        then SyncVerifyMismatch "Removed 指示後も OS アカウントが存在する"
        else SyncSucceeded
  | not (obsExists obs) = SyncVerifyMismatch "apply 後も OS アカウントが存在しない"
  | obsUid obs /= Just (syncUid req) = SyncVerifyMismatch "UID が一致しない"
  | OsActive <- syncStatus req
  , sort' (obsSshKeys obs) /= sort' (syncSshKeys req) =
      SyncVerifyMismatch "authorized_keys が一致しない"
  | OsSuspended <- syncStatus req
  , not (null (obsSshKeys obs)) =
      SyncVerifyMismatch "Suspended なのに authorized_keys が空になっていない"
  | otherwise = SyncSucceeded
 where
  sort' = T.intercalate "," . sort

-- ── internal: doas 呼び出し ──────────────────────────────────────────────────

{- | doas を1回呼ぶ。失敗は (ProcessError 等の中間型を介さず) 直接 SyncOutcome
として投げる — apply/observe どちらの呼び出し元でも同じマッピングになる。
-}
runDoas :: FilePath -> [String] -> ExceptT SyncOutcome IO Text
runDoas helperPath args = do
  result <- liftIO (tryIOError (readProcessWithExitCode "doas" (helperPath : args) ""))
  case result of
    Left _ -> throwError SyncToolMissing
    Right (ExitSuccess, out, _err) -> pure (T.pack out)
    Right (ExitFailure _, out, err) -> throwError (SyncApplyFailed (T.pack out <> T.pack err))

toJsonArg :: UserSyncRequest -> String
toJsonArg = BLC.unpack . encode

tryIOError :: IO a -> IO (Either IOError a)
tryIOError act = (Right <$> act) `catchIOError` (pure . Left)
