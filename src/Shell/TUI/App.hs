{- | Brick App definition and top-level router.
All drawing and event handling is delegated to Screen/* modules.
-}
module Shell.TUI.App (runTUI) where

import Brick (App (..), BrickEvent (..), EventM, Widget, get, put, str, withAttr)
import Brick.BChan (newBChan, writeBChan)
import Control.Concurrent (forkIO)
import Control.Monad (void)
import Control.Monad.IO.Class (liftIO)
import Graphics.Vty.CrossPlatform (mkVty)

import Brick qualified as B
import Brick.Widgets.Border qualified as BB
import Brick.Widgets.Border.Style qualified as BBS
import Brick.Widgets.Center qualified as BC
import Database.PostgreSQL.Simple qualified as PG
import Graphics.Vty qualified as V

import Core.Domain.User (Role, UserId)
import Core.State (initialMasterBook)
import Shell.CommandExecutor (loadMasterBook)
import Shell.ErrorCatalog (defaultCatalog)
import Shell.EventStore (EventStore)
import Shell.TUI.Attrs (hintAttr, owlvAttrMap, titleAttr)
import Shell.TUI.Screen.Journal (drawJournalForm, handleFormEv)
import Shell.TUI.Screen.Master.AccountCode
  ( drawAccountForm
  , drawAccountList
  , handleAccountFormEv
  , handleAccountListEv
  )
import Shell.TUI.Screen.Master.Menu (drawMasterMenu, handleMasterMenuEv)
import Shell.TUI.Screen.Master.Organisation
  ( drawOrgForm
  , drawOrgList
  , handleOrgFormEv
  , handleOrgListEv
  )
import Shell.TUI.Screen.Master.Partner
  ( drawPartnerForm
  , drawPartnerList
  , handlePartnerFormEv
  , handlePartnerListEv
  )
import Shell.TUI.Screen.Master.SubAccount
  ( drawSubAccForm
  , drawSubAccList
  , handleSubAccFormEv
  , handleSubAccListEv
  )
import Shell.TUI.Screen.Master.User
  ( drawUserForm
  , drawUserKeyForm
  , drawUserList
  , handleUserFormEv
  , handleUserKeyFormEv
  , handleUserListEv
  )
import Shell.TUI.Screen.Menu (drawMenu, handleMenuEv)
import Shell.TUI.Screen.VoucherSearch
  ( drawVoucherDetail
  , drawVoucherResult
  , drawVoucherSearch
  , handleVoucherDetailEv
  , handleVoucherResultEv
  , handleVoucherSearchEv
  )
import Shell.TUI.Types

-- ── Entry point ──────────────────────────────────────────────────────────────

runTUI :: PG.Connection -> EventStore -> UserId -> Role -> IO ()
runTUI conn store currentUser currentRole = do
  chan <- newBChan 16
  let initState =
        AppState
          { appScreen = ScreenLoading
          , appStore = store
          , appConn = conn
          , appChan = chan
          , appMasters = initialMasterBook
          , appCatalog = defaultCatalog
          , appCurrentUser = currentUser
          , appCurrentRole = currentRole
          }
  initialVty <- mkVty V.defaultConfig
  void $ B.customMain initialVty (mkVty V.defaultConfig) (Just chan) owlvApp initState

-- ── Brick App ────────────────────────────────────────────────────────────────

owlvApp :: App AppState AppEvent Name
owlvApp =
  App
    { appDraw = drawUI
    , appChooseCursor = B.showFirstCursor
    , appHandleEvent = handleEvent
    , appStartEvent = startLoading
    , appAttrMap = const owlvAttrMap
    }

{- | 起動直後: ローディング画面のまま PG フェッチをワーカースレッドに投げる。
完了時に MastersLoaded が BChan 経由で届き handleEvent がメニューへ遷移する。
-}
startLoading :: EventM Name AppState ()
startLoading = do
  st <- get
  liftIO $ void $ forkIO $ do
    result <- loadMasterBook (appStore st)
    writeBChan (appChan st) (MastersLoaded result)

-- ── Loading screen ───────────────────────────────────────────────────────────

drawLoadingScreen :: Widget Name
drawLoadingScreen =
  BC.center $
    B.hLimit 50 $
      B.withBorderStyle BBS.unicodeBold $
        BB.borderWithLabel (withAttr titleAttr (str " owlv ")) $
          B.padAll 2 $
            B.vBox
              [ BC.hCenter (withAttr titleAttr (str "IFRS 月次決算確報システム"))
              , str " "
              , BC.hCenter (withAttr hintAttr (str "データ読み込み中..."))
              ]

-- ── Router: draw ─────────────────────────────────────────────────────────────

drawUI :: AppState -> [Widget Name]
drawUI st = case appScreen st of
  ScreenLoading -> [drawLoadingScreen]
  ScreenMenu -> [drawMenu]
  ScreenMasterMenu -> [drawMasterMenu (appCurrentRole st)]
  ScreenJournalForm jf -> drawJournalForm (appCatalog st) (appMasters st) jf
  ScreenOrgList ls -> [drawOrgList ls]
  ScreenOrgForm fs -> [drawOrgForm (appCatalog st) fs]
  ScreenPartnerList ls -> [drawPartnerList ls]
  ScreenPartnerForm fs -> [drawPartnerForm (appCatalog st) fs]
  ScreenAccountList ls -> [drawAccountList ls]
  ScreenAccountForm fs -> [drawAccountForm (appCatalog st) fs]
  ScreenSubAccList ls -> [drawSubAccList ls]
  ScreenSubAccForm fs -> [drawSubAccForm (appCatalog st) fs]
  ScreenUserList ls -> [drawUserList (appCatalog st) (appCurrentRole st) ls]
  ScreenUserForm fs -> [drawUserForm (appCatalog st) fs]
  ScreenUserKeyForm u fs -> [drawUserKeyForm (appCatalog st) u fs]
  ScreenVoucherSearch vs -> [drawVoucherSearch (appCatalog st) vs]
  ScreenVoucherResult vr -> [drawVoucherResult (appMasters st) vr]
  ScreenVoucherDetail e _vr -> [drawVoucherDetail (appMasters st) e]

-- ── Router: events ───────────────────────────────────────────────────────────

handleEvent :: BrickEvent Name AppEvent -> EventM Name AppState ()
handleEvent (AppEvent (MastersLoaded result)) = do
  st <- get
  let mb = either (const (appMasters st)) id result
  put st{appMasters = mb, appScreen = ScreenMenu}
handleEvent (AppEvent (CommandFinished result)) = do
  st <- get
  case (appScreen st, result) of
    (ScreenJournalForm jf, Left err) ->
      put st{appScreen = ScreenJournalForm jf{jfLoading = False, jfError = Just err}}
    (ScreenJournalForm _, Right _) ->
      put st{appScreen = ScreenMenu}
    _ -> pure ()
handleEvent ev = do
  st <- get
  case appScreen st of
    ScreenLoading -> pure ()
    ScreenMenu -> handleMenuEv ev st
    ScreenMasterMenu -> handleMasterMenuEv ev st
    ScreenJournalForm jf -> handleFormEv ev jf st
    ScreenOrgList ls -> handleOrgListEv ev ls st
    ScreenOrgForm fs -> handleOrgFormEv ev fs st
    ScreenPartnerList ls -> handlePartnerListEv ev ls st
    ScreenPartnerForm fs -> handlePartnerFormEv ev fs st
    ScreenAccountList ls -> handleAccountListEv ev ls st
    ScreenAccountForm fs -> handleAccountFormEv ev fs st
    ScreenSubAccList ls -> handleSubAccListEv ev ls st
    ScreenSubAccForm fs -> handleSubAccFormEv ev fs st
    ScreenUserList ls -> handleUserListEv ev ls st
    ScreenUserForm fs -> handleUserFormEv ev fs st
    ScreenUserKeyForm u fs -> handleUserKeyFormEv ev u fs st
    ScreenVoucherSearch vs -> handleVoucherSearchEv ev vs st
    ScreenVoucherResult vr -> handleVoucherResultEv ev vr st
    ScreenVoucherDetail e vr -> handleVoucherDetailEv ev e vr st
