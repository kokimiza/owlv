-- | メインメニュー画面
module Shell.TUI.Screen.Menu
  ( drawMenu
  , handleMenuEv
  ) where

import Brick (BrickEvent (..), EventM, Widget, str, withAttr)
import Control.Monad.IO.Class (liftIO)
import Data.Time (getCurrentTime, utctDay)

import Brick qualified as B
import Brick.Widgets.Border qualified as BB
import Brick.Widgets.Border.Style qualified as BBS
import Brick.Widgets.Center qualified as BC
import Graphics.Vty qualified as Vty

import Shell.TUI.Attrs
import Shell.TUI.Types

drawMenu :: Widget Name
drawMenu =
  BC.center $
    B.hLimit 60 $
      withBorderStyle BBS.unicodeBold $
        BB.borderWithLabel (withAttr titleAttr (str " owlv ")) $
          B.padAll 2 $
            B.vBox
              [ withAttr titleAttr (BC.hCenter (str "IFRS 月次決算確報システム"))
              , str " "
              , BC.hCenter (str "─────────────────────────────────────────")
              , str " "
              , BC.hCenter (str "[ 1 ]  原始記録入力  (仕訳帳 §2.1)")
              , str " "
              , BC.hCenter (str "[ 2 ]  マスタ管理")
              , str " "
              , BC.hCenter (str "[ 3 ]  伝票検索")
              , str " "
              , BC.hCenter (str "─────────────────────────────────────────")
              , str " "
              , withAttr hintAttr (BC.hCenter (str "[ q / Esc ] 終了"))
              ]
 where
  withBorderStyle = B.withBorderStyle

handleMenuEv :: BrickEvent Name AppEvent -> AppState -> EventM Name AppState ()
handleMenuEv (VtyEvent (Vty.EvKey (Vty.KChar '1') [])) st = do
  today <- liftIO (utctDay <$> getCurrentTime)
  B.put st{appScreen = ScreenJournalForm (initJournalForm today)}
handleMenuEv (VtyEvent (Vty.EvKey (Vty.KChar '2') [])) st =
  B.put st{appScreen = ScreenMasterMenu}
handleMenuEv (VtyEvent (Vty.EvKey (Vty.KChar '3') [])) st =
  B.put st{appScreen = ScreenVoucherSearch initVoucherSearch}
handleMenuEv (VtyEvent (Vty.EvKey (Vty.KChar 'q') [])) _ = B.halt
handleMenuEv (VtyEvent (Vty.EvKey Vty.KEsc [])) _ = B.halt
handleMenuEv _ _ = pure ()
