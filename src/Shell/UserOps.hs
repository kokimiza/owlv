{- | ユーザー管理のオーケストレーション (.claude/user.md §3)

CLAUDE.md の方針通り、ここは独立した UseCases レイヤーではなく Shell に置く
薄いオーケストレーションである: Core コマンドを発行 → 成功したら OS 同期
(apply→observe→突合) を実行 → 同期結果を Shell が報告コマンドとして発行する。

パスワードハッシュ計算 (副作用) もここで行い、ハッシュ済みの値だけを
Core (SetUserPasswordHash) に渡す (sandwich pattern)。
-}
module Shell.UserOps
  ( createUserWithSync
  , suspendUserWithSync
  , reactivateUserWithSync
  , removeUserWithSync
  , registerSshKeyAsActor
  , setPasswordAsActor
  , resolveSessionUser
  ) where

import Data.Text (Text)

import Data.Map.Strict qualified as Map
import Data.Text qualified as T

import Core.Command (Command (..))
import Core.Domain.User
  ( OsUid (..)
  , Role (Admin)
  , SshPubKey (..)
  , User (..)
  , UserId (..)
  , UserStatus (..)
  , isActiveAdmin
  , mkSshPubKey
  , mkUserId
  )
import Core.Event (Event)
import Core.State (UserBook (..), initialUserBook)
import Shell.AppError (AppError (..))
import Shell.CommandExecutor (executeCommand, loadUserBook)
import Shell.EventStore (EventStore)
import Shell.Interpreters.OsIdentity (getRootAdminUsernameEnv)
import Shell.Interpreters.PasswordHash (hashPassword)
import Shell.Interpreters.UserOsSync
  ( SyncOutcome (..)
  , UserSyncRequest (..)
  , applyAndVerify
  , defaultHelperPath
  )

createUserWithSync ::
  EventStore -> UserId -> UserId -> Text -> Role -> [Text] -> IO (Either AppError [Event])
createUserWithSync store actor target name role scopes =
  runCommandThenSync store (CreateUser actor target name role scopes) target "Active"

suspendUserWithSync :: EventStore -> UserId -> UserId -> IO (Either AppError [Event])
suspendUserWithSync store actor target =
  runCommandThenSync store (SuspendUser actor target) target "Suspended"

reactivateUserWithSync :: EventStore -> UserId -> UserId -> IO (Either AppError [Event])
reactivateUserWithSync store actor target =
  runCommandThenSync store (ReactivateUser actor target) target "Active"

removeUserWithSync :: EventStore -> UserId -> UserId -> IO (Either AppError [Event])
removeUserWithSync store actor target =
  runCommandThenSync store (RemoveUser actor target) target "Removed"

-- | SSH 鍵登録: 本人または Admin。Active なユーザーなら即時に OS 側へ再同期する。
registerSshKeyAsActor ::
  EventStore -> UserId -> UserId -> Text -> IO (Either AppError [Event])
registerSshKeyAsActor store actor target rawKey =
  case mkSshPubKey rawKey of
    Left err -> pure (Left (AppInputError err))
    Right key -> do
      result <- executeCommand store (RegisterUserSshKey actor target key)
      case result of
        Left err -> pure (Left err)
        Right evts -> do
          ub <- loadUserBookOrEmpty store
          syncEvts <- case Map.lookup target (users ub) of
            Just u | userStatus u == Active -> runSyncFor store target "Active"
            _ -> pure []
          pure (Right (evts <> syncEvts))

-- | パスワードのステップアップ確認用ハッシュ設定。OS 同期は発生しない（§2.3: SSH 認証とは無関係）。
setPasswordAsActor :: EventStore -> UserId -> UserId -> Text -> IO (Either AppError [Event])
setPasswordAsActor store actor target plainPw = do
  hash <- hashPassword plainPw
  executeCommand store (SetUserPasswordHash actor target hash)

{- | SSH 確立時のセッション解決 (.claude/user.md §4.1, §7)。

1. OS ログイン名と同名の Active な User が見つかれば、それを身元として認める。
2. 見つからず、かつ Active な Admin が1人もおらず、かつ OS ログイン名が
   root_admin_username（環境変数 OWLV_ROOT_ADMIN_USERNAME 経由）と一致する
   場合に限り、その場で Admin な User を自動生成する（唯一のブートストラップ経路）。
3. それ以外は拒否する。TUI はここで Left を受け取ったら起動せず終了すること
   （OS 側のロック忘れがあってもアプリ側がもう一段の門番になる、§4.1）。

ブートストラップで作成した直後に OS 同期 (owl-user-sync) が失敗した場合、
ユーザーは Pending のまま残り、次回ログイン時はこの関数の (1) で Active
判定に落ちて拒否される。これは「同期成功でしか Active にしない」という
§2.1 の不変条件が正しく機能している証拠であり、バグではない。
-}
resolveSessionUser :: EventStore -> Text -> IO (Either Text (UserId, Role))
resolveSessionUser store osLoginName = case mkUserId osLoginName of
  Left e -> pure (Left e)
  Right uid -> do
    ub <- loadUserBookOrEmpty store
    case Map.lookup uid (users ub) of
      Just u | userStatus u == Active -> pure (Right (uid, userRole u))
      Just u ->
        pure (Left ("このユーザーは現在 " <> T.pack (show (userStatus u)) <> " 状態です: " <> osLoginName))
      Nothing -> do
        mRootAdmin <- getRootAdminUsernameEnv
        let activeAdminCount = length (filter isActiveAdmin (Map.elems (users ub)))
        if activeAdminCount == 0 && mRootAdmin == Just osLoginName
          then do
            result <- createUserWithSync store uid uid osLoginName Admin []
            case result of
              Left err -> pure (Left (T.pack (show err)))
              Right _ -> pure (Right (uid, Admin))
          else pure (Left ("owlv ユーザーが登録されていません: " <> osLoginName))

-- ── internal ──────────────────────────────────────────────────────────────────

runCommandThenSync ::
  EventStore -> Command -> UserId -> Text -> IO (Either AppError [Event])
runCommandThenSync store cmd target desiredStatus = do
  result <- executeCommand store cmd
  case result of
    Left err -> pure (Left err)
    Right evts -> do
      syncEvts <- runSyncFor store target desiredStatus
      pure (Right (evts <> syncEvts))

-- | OS 同期 (apply→observe→突合) を実行し、結果を報告コマンドとして発行する。
runSyncFor :: EventStore -> UserId -> Text -> IO [Event]
runSyncFor store target desiredStatus = do
  ub <- loadUserBookOrEmpty store
  case Map.lookup target (users ub) of
    Nothing -> pure []
    Just u -> do
      let req =
            UserSyncRequest
              { syncUsername = unUserId target
              , syncUid = unOsUid (userOsUid u)
              , syncRole = T.pack (show (userRole u))
              , syncStatus = desiredStatus
              , syncSshKeys =
                  if desiredStatus == "Suspended"
                    then []
                    else map unSshPubKey (userSshPubKeys u)
              }
      outcome <- applyAndVerify defaultHelperPath req
      reportOutcome store target outcome

reportOutcome :: EventStore -> UserId -> SyncOutcome -> IO [Event]
reportOutcome store target outcome = do
  let cmd = case outcome of
        SyncSucceeded -> RecordUserOsSyncSucceeded target
        SyncVerifyMismatch msg -> RecordUserOsSyncFailed target msg
        SyncApplyFailed msg -> RecordUserOsSyncFailed target msg
        SyncToolMissing ->
          RecordUserOsSyncFailed target "owl-user-sync が見つかりません（開発環境または未配置）"
  result <- executeCommand store cmd
  pure (either (const []) id result)

loadUserBookOrEmpty :: EventStore -> IO UserBook
loadUserBookOrEmpty store = either (const initialUserBook) id <$> loadUserBook store
