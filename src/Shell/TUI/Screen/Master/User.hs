{- | ユーザー管理画面 (.claude/user.md)

一覧 + 新規作成フォーム + SSH 鍵追加フォーム。Admin のみが新規作成・ロール変更・
停止/再開/削除を行える（実際の権限チェックは Core.Decide が担う。ここでの
appCurrentRole 表示制御は UX 上のガードであり、最終的な防御線ではない）。
-}
module Shell.TUI.Screen.Master.User
  ( drawUserList
  , handleUserListEv
  , drawUserForm
  , handleUserFormEv
  , drawUserKeyForm
  , handleUserKeyFormEv
  ) where

import Brick (BrickEvent (..), EventM, Widget, str, txt, withAttr)
import Control.Monad.IO.Class (liftIO)
import Data.Maybe (fromMaybe)

import Brick qualified as B
import Brick.Widgets.Border qualified as BB
import Brick.Widgets.Border.Style qualified as BBS
import Brick.Widgets.Center qualified as BC
import Brick.Widgets.Edit qualified as E
import Data.Text qualified as T
import Graphics.Vty qualified as Vty

import Core.Domain.User
  ( Role (..)
  , User (..)
  , UserId (..)
  , mkUserId
  , roleInTenant
  )
import Shell.AppError (AppError (..))
import Shell.CommandExecutor (loadUserBook)
import Shell.ErrorCatalog (ErrorCatalog, renderAppError)
import Shell.TUI.Attrs
import Shell.TUI.Helpers
import Shell.TUI.Types
import Shell.UserOps
  ( createUserWithSync
  , reactivateUserWithSync
  , registerSshKeyAsActor
  , removeUserWithSync
  , suspendUserWithSync
  )

-- ── List screen ───────────────────────────────────────────────────────────────

drawUserList :: ErrorCatalog -> Role -> UserListState -> Widget Name
drawUserList cat role st =
  B.vBox
    [ B.withBorderStyle BBS.unicodeBold $
        BB.borderWithLabel (withAttr titleAttr (str " ユーザー管理 ")) $
          B.padLeftRight 1 $
            B.vBox
              [ withAttr labelAttr (str " ユーザー名      表示名               ロール       状態")
              , BB.hBorder
              , if null (ulUsers st)
                  then withAttr hintAttr (BC.hCenter (str "登録データなし"))
                  else B.vBox (zipWith (drawUserRow (ulSelected st)) [0 ..] (ulUsers st))
              ]
    , drawError (fmap (renderAppError cat) (ulError st))
    , drawHint (hintFor role)
    ]
 where
  hintFor Admin = "↑/↓:移動  n:新規  k:鍵追加  s:停止  r:再開  x:削除  Esc:メニューへ"
  hintFor _ = "↑/↓:移動  Esc:メニューへ（ユーザー管理は Admin 専用）"

drawUserRow :: Int -> Int -> User -> Widget Name
drawUserRow selected idx u =
  let isSelected = idx == selected
      nameW = B.hLimit 16 (txt (unUserId (userId u)))
      dispW = B.hLimit 20 (txt (userDisplayName u))
      roleW = B.hLimit 12 (str (maybe "-" show (roleInTenant (userHomeTenant u) u)))
      statusW = str (show (userStatus u))
      row_ = B.hBox [str " ", nameW, str " ", dispW, str " ", roleW, str " ", statusW]
  in if isSelected then withAttr focusedAttr row_ else row_

handleUserListEv :: BrickEvent Name AppEvent -> UserListState -> AppState -> EventM Name AppState ()
handleUserListEv (VtyEvent (Vty.EvKey Vty.KEsc [])) _ st =
  B.put st{appScreen = ScreenMasterMenu}
handleUserListEv (VtyEvent (Vty.EvKey Vty.KUp [])) ls st =
  B.put st{appScreen = ScreenUserList ls{ulSelected = max 0 (ulSelected ls - 1)}}
handleUserListEv (VtyEvent (Vty.EvKey Vty.KDown [])) ls st =
  B.put
    st{appScreen = ScreenUserList ls{ulSelected = min (length (ulUsers ls) - 1) (ulSelected ls + 1)}}
handleUserListEv (VtyEvent (Vty.EvKey (Vty.KChar 'n') [])) _ st
  | appCurrentRole st == Admin = B.put st{appScreen = ScreenUserForm initUserForm}
handleUserListEv (VtyEvent (Vty.EvKey (Vty.KChar 'k') [])) ls st
  | appCurrentRole st == Admin = case safeIndex (ulUsers ls) (ulSelected ls) of
      Just u -> B.put st{appScreen = ScreenUserKeyForm u initUserKeyForm}
      Nothing -> pure ()
handleUserListEv (VtyEvent (Vty.EvKey (Vty.KChar 's') [])) ls st
  | appCurrentRole st == Admin = withSelected ls $ \u -> do
      result <- liftIO (suspendUserWithSync (appStore st) (appCurrentUser st) (userId u))
      refreshAfter result st
handleUserListEv (VtyEvent (Vty.EvKey (Vty.KChar 'r') [])) ls st
  | appCurrentRole st == Admin = withSelected ls $ \u -> do
      result <- liftIO (reactivateUserWithSync (appStore st) (appCurrentUser st) (userId u))
      refreshAfter result st
handleUserListEv (VtyEvent (Vty.EvKey (Vty.KChar 'x') [])) ls st
  | appCurrentRole st == Admin = withSelected ls $ \u -> do
      result <- liftIO (removeUserWithSync (appStore st) (appCurrentUser st) (userId u))
      refreshAfter result st
handleUserListEv _ _ _ = pure ()

withSelected ::
  UserListState -> (User -> EventM Name AppState ()) -> EventM Name AppState ()
withSelected ls act = case safeIndex (ulUsers ls) (ulSelected ls) of
  Just u -> act u
  Nothing -> pure ()

refreshAfter :: Either AppError [a] -> AppState -> EventM Name AppState ()
refreshAfter result st = case result of
  Left err -> setListError err st
  Right _ -> do
    ubE <- liftIO (loadUserBook (appStore st))
    case ubE of
      Left err -> setListError err st
      Right ub -> B.put st{appScreen = ScreenUserList (initUserList (appCurrentTenant st) ub)}

setListError :: AppError -> AppState -> EventM Name AppState ()
setListError err st = case appScreen st of
  ScreenUserList ls -> B.put st{appScreen = ScreenUserList ls{ulError = Just err}}
  _ -> pure ()

safeIndex :: [a] -> Int -> Maybe a
safeIndex [] _ = Nothing
safeIndex (x : _) 0 = Just x
safeIndex (_ : xs) n = safeIndex xs (n - 1)

-- ── Create form ────────────────────────────────────────────────────────────────

allRoles :: [Role]
allRoles = [minBound .. maxBound]

drawUserForm :: ErrorCatalog -> UserFormState -> Widget Name
drawUserForm cat fs =
  B.vBox
    [ B.withBorderStyle BBS.unicodeBold $
        BB.borderWithLabel (withAttr titleAttr (str " ユーザー登録 ")) $
          B.padLeftRight 1 $
            B.vBox
              [ row "ユーザー名 " $ renderTextEd (ufFocus fs == UFUsername) (ufUsername fs)
              , withAttr hintAttr (str "             (= OS ユーザー名。英小文字/数字/_/- のみ、後で変更不可)")
              , row "表示名     " $ renderTextEd (ufFocus fs == UFDisplayName) (ufDisplayName fs)
              , row "ロール     " $ drawCycleField (ufFocus fs == UFRole) (show (ufRole fs))
              , BB.hBorder
              , B.hBox
                  [ drawBtn (ufFocus fs == UFSubmit) "  登録  "
                  , str "   "
                  , drawBtn (ufFocus fs == UFCancel) " キャンセル "
                  ]
              ]
    , drawError (fmap (renderAppError cat) (ufError fs))
    , drawHint "Tab:次へ  Shift+Tab:前へ  ←/→:ロール切替  Enter:確定  Esc:一覧へ"
    ]

handleUserFormEv :: BrickEvent Name AppEvent -> UserFormState -> AppState -> EventM Name AppState ()
handleUserFormEv (VtyEvent (Vty.EvKey Vty.KEsc [])) _ st = backToUserList st
handleUserFormEv (VtyEvent (Vty.EvKey (Vty.KChar '\t') [])) fs st =
  B.put st{appScreen = ScreenUserForm fs{ufFocus = cycleR (ufFocus fs)}}
handleUserFormEv (VtyEvent (Vty.EvKey Vty.KBackTab [])) fs st =
  B.put st{appScreen = ScreenUserForm fs{ufFocus = cycleL (ufFocus fs)}}
handleUserFormEv ev fs st = case ufFocus fs of
  UFUsername -> do
    (ed, ()) <- B.nestEventM (ufUsername fs) (E.handleEditorEvent ev)
    B.put st{appScreen = ScreenUserForm fs{ufUsername = ed}}
  UFDisplayName -> do
    (ed, ()) <- B.nestEventM (ufDisplayName fs) (E.handleEditorEvent ev)
    B.put st{appScreen = ScreenUserForm fs{ufDisplayName = ed}}
  UFRole -> case ev of
    VtyEvent (Vty.EvKey Vty.KLeft []) -> B.put st{appScreen = ScreenUserForm fs{ufRole = cycleRole (-1) (ufRole fs)}}
    VtyEvent (Vty.EvKey Vty.KRight []) -> B.put st{appScreen = ScreenUserForm fs{ufRole = cycleRole 1 (ufRole fs)}}
    _ -> pure ()
  UFSubmit -> case ev of
    VtyEvent (Vty.EvKey Vty.KEnter []) -> submitUser fs st
    _ -> pure ()
  UFCancel -> case ev of
    VtyEvent (Vty.EvKey Vty.KEnter []) -> backToUserList st
    _ -> pure ()

cycleRole :: Int -> Role -> Role
cycleRole d r =
  let idx = fromMaybe 0 (lookup r (zip allRoles [0 ..]))
      n = length allRoles
  in allRoles !! (((idx + d) `mod` n + n) `mod` n)

submitUser :: UserFormState -> AppState -> EventM Name AppState ()
submitUser fs st = do
  let nameT = edText (ufUsername fs)
      dispT = edText (ufDisplayName fs)
  case mkUserId nameT of
    Left err -> B.put st{appScreen = ScreenUserForm fs{ufError = Just (AppInputError err)}}
    Right target -> do
      result <-
        liftIO $
          -- 新規Userのホームテナントは作成者（actor）の現在Tenant
          -- (doc/tenant_isolation.md §5.2)。
          createUserWithSync
            (appStore st)
            (appCurrentUser st)
            target
            dispT
            (appCurrentTenant st)
            (ufRole fs)
            []
      case result of
        Left err -> B.put st{appScreen = ScreenUserForm fs{ufError = Just err}}
        Right _ -> backToUserList st

backToUserList :: AppState -> EventM Name AppState ()
backToUserList st = do
  ubE <- liftIO (loadUserBook (appStore st))
  B.put
    st
      { appScreen = ScreenUserList (either (const emptyUserList) (initUserList (appCurrentTenant st)) ubE)
      }
 where
  emptyUserList = UserListState [] 0 Nothing

-- ── SSH key form ────────────────────────────────────────────────────────────────

drawUserKeyForm :: ErrorCatalog -> User -> UserKeyFormState -> Widget Name
drawUserKeyForm _cat u fs =
  B.vBox
    [ B.withBorderStyle BBS.unicodeBold
        $ BB.borderWithLabel
          (withAttr titleAttr (str (" SSH公開鍵追加: " <> T.unpack (unUserId (userId u)) <> " ")))
        $ B.padLeftRight 1
        $ B.vBox
          [ row "公開鍵 " $ renderTextEd True (ukfKey fs)
          , withAttr hintAttr (str "        (command=/environment= 等のオプション付き鍵は拒否されます)")
          , BB.hBorder
          ]
    , drawHint "Enter:登録  Esc:一覧へ"
    ]

handleUserKeyFormEv ::
  BrickEvent Name AppEvent -> User -> UserKeyFormState -> AppState -> EventM Name AppState ()
handleUserKeyFormEv (VtyEvent (Vty.EvKey Vty.KEsc [])) _ _ st = backToUserList st
handleUserKeyFormEv (VtyEvent (Vty.EvKey Vty.KEnter [])) u fs st = do
  let keyT = edText (ukfKey fs)
  result <-
    liftIO $
      registerSshKeyAsActor (appStore st) (appCurrentUser st) (userId u) keyT
  case result of
    Left _err -> backToUserList st -- フォームにエラー欄を持たないため一覧へ戻る（一覧側で再表示は省略）
    Right _ -> backToUserList st
handleUserKeyFormEv ev u fs st = do
  (ed, ()) <- B.nestEventM (ukfKey fs) (E.handleEditorEvent ev)
  B.put st{appScreen = ScreenUserKeyForm u fs{ukfKey = ed}}
