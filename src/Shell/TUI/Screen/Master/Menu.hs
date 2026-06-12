-- | マスタ管理サブメニュー
module Shell.TUI.Screen.Master.Menu
  ( drawMasterMenu
  , handleMasterMenuEv
  ) where

import Brick (BrickEvent (..), EventM, Widget, str, withAttr)

import Brick qualified as B
import Brick.Widgets.Border qualified as BB
import Brick.Widgets.Border.Style qualified as BBS
import Brick.Widgets.Center qualified as BC
import Graphics.Vty qualified as Vty

import Shell.TUI.Attrs
import Shell.TUI.Types

drawMasterMenu :: Widget Name
drawMasterMenu =
  BC.center $
    B.hLimit 60 $
      B.withBorderStyle BBS.unicodeBold $
        BB.borderWithLabel (withAttr titleAttr (str " マスタ管理 ")) $
          B.padAll 2 $
            B.vBox
              [ withAttr titleAttr (BC.hCenter (str "マスタ選択"))
              , str " "
              , BC.hCenter (str "─────────────────────────────────────────")
              , str " "
              , BC.hCenter (str "[ 1 ]  組織マスタ")
              , str " "
              , BC.hCenter (str "[ 2 ]  取引先マスタ")
              , str " "
              , BC.hCenter (str "[ 3 ]  勘定科目マスタ")
              , str " "
              , BC.hCenter (str "[ 4 ]  補助科目マスタ")
              , str " "
              , BC.hCenter (str "─────────────────────────────────────────")
              , str " "
              , withAttr hintAttr (BC.hCenter (str "[ Esc ] メインメニューへ"))
              ]

handleMasterMenuEv :: BrickEvent Name () -> AppState -> EventM Name AppState ()
handleMasterMenuEv (VtyEvent (Vty.EvKey (Vty.KChar '1') [])) st =
  B.put st{appScreen = ScreenOrgList (initOrgList (appMasters st))}
handleMasterMenuEv (VtyEvent (Vty.EvKey (Vty.KChar '2') [])) st =
  B.put st{appScreen = ScreenPartnerList (initPartnerList (appMasters st))}
handleMasterMenuEv (VtyEvent (Vty.EvKey (Vty.KChar '3') [])) st =
  B.put st{appScreen = ScreenAccountList (initAccountList (appMasters st))}
handleMasterMenuEv (VtyEvent (Vty.EvKey (Vty.KChar '4') [])) st =
  B.put st{appScreen = ScreenSubAccList (initSubAccList (appMasters st))}
handleMasterMenuEv (VtyEvent (Vty.EvKey Vty.KEsc [])) st =
  B.put st{appScreen = ScreenMenu}
handleMasterMenuEv _ _ = pure ()
