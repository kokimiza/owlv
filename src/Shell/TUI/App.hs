{- | Brick App definition and top-level router.
All drawing and event handling is delegated to Screen/* modules.
-}
module Shell.TUI.App (runTUI) where

import Brick (App (..), BrickEvent, EventM, Widget, defaultMain, get)

import Brick qualified as B

import Core.State (initialMasterBook)
import Shell.ErrorCatalog (defaultCatalog)
import Shell.EventStore (EventStore)
import Shell.TUI.Attrs (owlvAttrMap)
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
import Shell.TUI.Screen.Menu (drawMenu, handleMenuEv)
import Shell.TUI.Types

-- ── Entry point ──────────────────────────────────────────────────────────────

runTUI :: EventStore -> IO ()
runTUI store = do
  let initState =
        AppState
          { appScreen = ScreenMenu
          , appStore = store
          , appMasters = initialMasterBook
          , appCatalog = defaultCatalog -- カタログロードは起動時の一点のみ
          }
  _ <- defaultMain owlvApp initState
  pure ()

-- ── Brick App ────────────────────────────────────────────────────────────────

owlvApp :: App AppState () Name
owlvApp =
  App
    { appDraw = drawUI
    , appChooseCursor = B.showFirstCursor
    , appHandleEvent = handleEvent
    , appStartEvent = pure ()
    , appAttrMap = const owlvAttrMap
    }

-- ── Router: draw ─────────────────────────────────────────────────────────────

drawUI :: AppState -> [Widget Name]
drawUI st = (: []) $ case appScreen st of
  ScreenMenu -> drawMenu
  ScreenMasterMenu -> drawMasterMenu
  ScreenJournalForm jf -> drawJournalForm (appCatalog st) (appMasters st) jf
  ScreenOrgList ls -> drawOrgList ls
  ScreenOrgForm fs -> drawOrgForm (appCatalog st) fs
  ScreenPartnerList ls -> drawPartnerList ls
  ScreenPartnerForm fs -> drawPartnerForm (appCatalog st) fs
  ScreenAccountList ls -> drawAccountList ls
  ScreenAccountForm fs -> drawAccountForm (appCatalog st) fs
  ScreenSubAccList ls -> drawSubAccList ls
  ScreenSubAccForm fs -> drawSubAccForm (appCatalog st) fs

-- ── Router: events ───────────────────────────────────────────────────────────

handleEvent :: BrickEvent Name () -> EventM Name AppState ()
handleEvent ev = do
  st <- get
  case appScreen st of
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
