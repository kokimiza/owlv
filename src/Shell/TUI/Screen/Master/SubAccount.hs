-- | 補助科目マスタ画面（一覧 + フォーム）
module Shell.TUI.Screen.Master.SubAccount
  ( drawSubAccList
  , handleSubAccListEv
  , drawSubAccForm
  , handleSubAccFormEv
  ) where

import Brick (BrickEvent (..), EventM, Widget, str, txt, withAttr)
import Control.Monad.IO.Class (liftIO)

import Brick qualified as B
import Brick.Widgets.Border qualified as BB
import Brick.Widgets.Border.Style qualified as BBS
import Brick.Widgets.Center qualified as BC
import Brick.Widgets.Edit qualified as E
import Graphics.Vty qualified as Vty

import Core.Command (Command (..))
import Core.Domain.AccountCode (mkAccountCode, unAccountCode)
import Core.Domain.SubAccount
  ( SubAccount (..)
  , SubAccountId (..)
  , mkSubAccountId
  )
import Shell.AppError (AppError (..))
import Shell.CommandExecutor (executeCommand, loadMasterBook)
import Shell.ErrorCatalog (ErrorCatalog, renderAppError)
import Shell.TUI.Attrs
import Shell.TUI.Helpers
import Shell.TUI.Types

-- ── List screen ───────────────────────────────────────────────────────────────

drawSubAccList :: SubAccListState -> Widget Name
drawSubAccList st =
  B.vBox
    [ B.withBorderStyle BBS.unicodeBold $
        BB.borderWithLabel (withAttr titleAttr (str " 補助科目マスタ一覧 ")) $
          B.padLeftRight 1 $
            B.vBox
              [ withAttr labelAttr (str " コード        名称                    親科目    有効")
              , BB.hBorder
              , if null (slSubAccounts st)
                  then withAttr hintAttr (BC.hCenter (str "登録データなし"))
                  else B.vBox (zipWith (drawSubAccRow (slSelected st)) [0 ..] (slSubAccounts st))
              ]
    , drawHint "↑/↓:移動  n:新規  Enter:編集  Esc:メニューへ"
    ]

drawSubAccRow :: Int -> Int -> SubAccount -> Widget Name
drawSubAccRow selected idx sa =
  let isSelected = idx == selected
      codeW = B.hLimit 14 (txt (unSubAccountId (saId sa)))
      nameW = B.hLimit 22 (txt (saName sa))
      parentW = B.hLimit 10 (txt (unAccountCode (saParent sa)))
      actW = str (if saActive sa then "○" else "×")
      row_ = B.hBox [str " ", codeW, str " ", nameW, str " ", parentW, str " ", actW]
  in if isSelected then withAttr focusedAttr row_ else row_

handleSubAccListEv :: BrickEvent Name () -> SubAccListState -> AppState -> EventM Name AppState ()
handleSubAccListEv (VtyEvent (Vty.EvKey Vty.KEsc [])) _ st =
  B.put st{appScreen = ScreenMasterMenu}
handleSubAccListEv (VtyEvent (Vty.EvKey Vty.KUp [])) ls st =
  B.put st{appScreen = ScreenSubAccList ls{slSelected = max 0 (slSelected ls - 1)}}
handleSubAccListEv (VtyEvent (Vty.EvKey Vty.KDown [])) ls st =
  B.put
    st
      { appScreen =
          ScreenSubAccList ls{slSelected = min (length (slSubAccounts ls) - 1) (slSelected ls + 1)}
      }
handleSubAccListEv (VtyEvent (Vty.EvKey (Vty.KChar 'n') [])) _ st =
  B.put st{appScreen = ScreenSubAccForm (initSubAccForm Nothing)}
handleSubAccListEv (VtyEvent (Vty.EvKey Vty.KEnter [])) ls st =
  let msa = safeIndex (slSubAccounts ls) (slSelected ls)
  in B.put st{appScreen = ScreenSubAccForm (initSubAccForm msa)}
handleSubAccListEv _ _ _ = pure ()

-- ── Form screen ───────────────────────────────────────────────────────────────

drawSubAccForm :: ErrorCatalog -> SubAccFormState -> Widget Name
drawSubAccForm cat fs =
  B.vBox
    [ B.withBorderStyle BBS.unicodeBold $
        BB.borderWithLabel (withAttr titleAttr (str (if safIsNew fs then " 補助科目登録 " else " 補助科目編集 "))) $
          B.padLeftRight 1 $
            B.vBox
              [ row "コード    " $ renderTextEd (safFocus fs == SAFCode) (safCode fs)
              , row "名称      " $ renderTextEd (safFocus fs == SAFName) (safName fs)
              , row "親科目    " $ renderTextEd (safFocus fs == SAFParent) (safParent fs)
              , row "有効      " $
                  drawCycleField
                    (safFocus fs == SAFActive)
                    (if safActive fs then "有効" else "無効")
              , BB.hBorder
              , B.hBox
                  [ drawBtn (safFocus fs == SAFSubmit) "  登録  "
                  , str "   "
                  , drawBtn (safFocus fs == SAFCancel) " キャンセル "
                  ]
              ]
    , drawError (fmap (renderAppError cat) (safError fs))
    , drawHint "Tab:次へ  Shift+Tab:前へ  ←/→:切替  Enter:確定  Esc:一覧へ"
    ]

handleSubAccFormEv :: BrickEvent Name () -> SubAccFormState -> AppState -> EventM Name AppState ()
handleSubAccFormEv (VtyEvent (Vty.EvKey Vty.KEsc [])) _ st =
  B.put st{appScreen = ScreenSubAccList (initSubAccList (appMasters st))}
handleSubAccFormEv (VtyEvent (Vty.EvKey (Vty.KChar '\t') [])) fs st =
  B.put st{appScreen = ScreenSubAccForm fs{safFocus = cycleR (safFocus fs)}}
handleSubAccFormEv (VtyEvent (Vty.EvKey Vty.KBackTab [])) fs st =
  B.put st{appScreen = ScreenSubAccForm fs{safFocus = cycleL (safFocus fs)}}
handleSubAccFormEv ev fs st = case safFocus fs of
  SAFCode -> do
    (ed, ()) <- B.nestEventM (safCode fs) (E.handleEditorEvent ev)
    B.put st{appScreen = ScreenSubAccForm fs{safCode = ed}}
  SAFName -> do
    (ed, ()) <- B.nestEventM (safName fs) (E.handleEditorEvent ev)
    B.put st{appScreen = ScreenSubAccForm fs{safName = ed}}
  SAFParent -> do
    (ed, ()) <- B.nestEventM (safParent fs) (E.handleEditorEvent ev)
    B.put st{appScreen = ScreenSubAccForm fs{safParent = ed}}
  SAFActive -> case ev of
    VtyEvent (Vty.EvKey Vty.KLeft []) -> B.put st{appScreen = ScreenSubAccForm fs{safActive = not (safActive fs)}}
    VtyEvent (Vty.EvKey Vty.KRight []) -> B.put st{appScreen = ScreenSubAccForm fs{safActive = not (safActive fs)}}
    VtyEvent (Vty.EvKey (Vty.KChar ' ') []) -> B.put st{appScreen = ScreenSubAccForm fs{safActive = not (safActive fs)}}
    _ -> pure ()
  SAFSubmit -> case ev of
    VtyEvent (Vty.EvKey Vty.KEnter []) -> submitSubAcc fs st
    _ -> pure ()
  SAFCancel -> case ev of
    VtyEvent (Vty.EvKey Vty.KEnter []) ->
      B.put st{appScreen = ScreenSubAccList (initSubAccList (appMasters st))}
    _ -> pure ()

submitSubAcc :: SubAccFormState -> AppState -> EventM Name AppState ()
submitSubAcc fs st = do
  let codeT = edText (safCode fs)
      parentT = edText (safParent fs)
  case (mkSubAccountId codeT, mkAccountCode parentT) of
    (Left err, _) ->
      B.put st{appScreen = ScreenSubAccForm fs{safError = Just (AppInputError err)}}
    (_, Left err) ->
      B.put st{appScreen = ScreenSubAccForm fs{safError = Just (AppInputError err)}}
    (Right sid, Right parentAc) -> do
      let sa =
            SubAccount
              { saId = sid
              , saName = edText (safName fs)
              , saParent = parentAc
              , saActive = safActive fs
              }
          cmd = if safIsNew fs then RegisterSubAccount sa else UpdateSubAccount sa
      result <- liftIO (executeCommand (appStore st) cmd)
      case result of
        Left err -> B.put st{appScreen = ScreenSubAccForm fs{safError = Just err}}
        Right _ -> do
          mb <- liftIO (loadMasterBook (appStore st))
          let newMasters = either (const (appMasters st)) id mb
          B.put
            st
              { appMasters = newMasters
              , appScreen = ScreenSubAccList (initSubAccList newMasters)
              }

safeIndex :: [a] -> Int -> Maybe a
safeIndex [] _ = Nothing
safeIndex (x : _) 0 = Just x
safeIndex (_ : xs) n = safeIndex xs (n - 1)
