-- | 取引先マスタ画面（一覧 + フォーム）
module Shell.TUI.Screen.Master.Partner
  ( drawPartnerList
  , handlePartnerListEv
  , drawPartnerForm
  , handlePartnerFormEv
  ) where

import Brick (BrickEvent (..), EventM, Widget, str, txt, withAttr)
import Control.Monad.IO.Class (liftIO)

import Brick qualified as B
import Brick.Widgets.Border qualified as BB
import Brick.Widgets.Border.Style qualified as BBS
import Brick.Widgets.Center qualified as BC
import Brick.Widgets.Edit qualified as E
import Data.Text qualified as T
import Graphics.Vty qualified as Vty

import Core.Command (Command (..))
import Core.Domain.Partner
  ( Partner (..)
  , PartnerId (..)
  , mkPartnerId
  , showPartnerType
  )
import Shell.AppError (AppError (..))
import Shell.CommandExecutor (executeCommand, loadMasterBook)
import Shell.ErrorCatalog (ErrorCatalog, renderAppError)
import Shell.TUI.Attrs
import Shell.TUI.Helpers
import Shell.TUI.Types

-- ── List screen ───────────────────────────────────────────────────────────────

drawPartnerList :: PartnerListState -> Widget Name
drawPartnerList st =
  B.vBox
    [ B.withBorderStyle BBS.unicodeBold $
        BB.borderWithLabel (withAttr titleAttr (str " 取引先マスタ一覧 ")) $
          B.padLeftRight 1 $
            B.vBox
              [ withAttr labelAttr (str " コード        名称                    区分      有効")
              , BB.hBorder
              , if null (plPartners st)
                  then withAttr hintAttr (BC.hCenter (str "登録データなし"))
                  else B.vBox (zipWith (drawPartnerRow (plSelected st)) [0 ..] (plPartners st))
              ]
    , drawHint "↑/↓:移動  n:新規  Enter:編集  Esc:メニューへ"
    ]

drawPartnerRow :: Int -> Int -> Partner -> Widget Name
drawPartnerRow selected idx p =
  let isSelected = idx == selected
      codeW = B.hLimit 14 (txt (unPartnerId (partnerId p)))
      nameW = B.hLimit 22 (txt (partnerName p))
      typeW = B.hLimit 10 (txt (showPartnerType (partnerType p)))
      actW = str (if partnerActive p then "○" else "×")
      row_ = B.hBox [str " ", codeW, str " ", nameW, str " ", typeW, str " ", actW]
  in if isSelected then withAttr focusedAttr row_ else row_

handlePartnerListEv ::
  BrickEvent Name AppEvent -> PartnerListState -> AppState -> EventM Name AppState ()
handlePartnerListEv (VtyEvent (Vty.EvKey Vty.KEsc [])) _ st =
  B.put st{appScreen = ScreenMasterMenu}
handlePartnerListEv (VtyEvent (Vty.EvKey Vty.KUp [])) ls st =
  B.put st{appScreen = ScreenPartnerList ls{plSelected = max 0 (plSelected ls - 1)}}
handlePartnerListEv (VtyEvent (Vty.EvKey Vty.KDown [])) ls st =
  B.put
    st
      { appScreen = ScreenPartnerList ls{plSelected = min (length (plPartners ls) - 1) (plSelected ls + 1)}
      }
handlePartnerListEv (VtyEvent (Vty.EvKey (Vty.KChar 'n') [])) _ st =
  B.put st{appScreen = ScreenPartnerForm (initPartnerForm Nothing)}
handlePartnerListEv (VtyEvent (Vty.EvKey Vty.KEnter [])) ls st =
  let mp = safeIndex (plPartners ls) (plSelected ls)
  in B.put st{appScreen = ScreenPartnerForm (initPartnerForm mp)}
handlePartnerListEv _ _ _ = pure ()

-- ── Form screen ───────────────────────────────────────────────────────────────

drawPartnerForm :: ErrorCatalog -> PartnerFormState -> Widget Name
drawPartnerForm cat fs =
  B.vBox
    [ B.withBorderStyle BBS.unicodeBold $
        BB.borderWithLabel (withAttr titleAttr (str (if pfIsNew fs then " 取引先登録 " else " 取引先編集 "))) $
          B.padLeftRight 1 $
            B.vBox
              [ row "コード  " $ renderTextEd (pfFocus fs == PFCode) (pfCode fs)
              , row "名称    " $ renderTextEd (pfFocus fs == PFName) (pfName fs)
              , row "区分    " $
                  drawCycleField
                    (pfFocus fs == PFType)
                    (T.unpack (showPartnerType (pfType fs)))
              , row "有効    " $
                  drawCycleField
                    (pfFocus fs == PFActive)
                    (if pfActive fs then "有効" else "無効")
              , BB.hBorder
              , B.hBox
                  [ drawBtn (pfFocus fs == PFSubmit) "  登録  "
                  , str "   "
                  , drawBtn (pfFocus fs == PFCancel) " キャンセル "
                  ]
              ]
    , drawError (fmap (renderAppError cat) (pfError fs))
    , drawHint "Tab:次へ  Shift+Tab:前へ  ←/→:切替  Enter:確定  Esc:一覧へ"
    ]

handlePartnerFormEv ::
  BrickEvent Name AppEvent -> PartnerFormState -> AppState -> EventM Name AppState ()
handlePartnerFormEv (VtyEvent (Vty.EvKey Vty.KEsc [])) _ st =
  B.put st{appScreen = ScreenPartnerList (initPartnerList (appMasters st))}
handlePartnerFormEv (VtyEvent (Vty.EvKey (Vty.KChar '\t') [])) fs st =
  B.put st{appScreen = ScreenPartnerForm fs{pfFocus = cycleR (pfFocus fs)}}
handlePartnerFormEv (VtyEvent (Vty.EvKey Vty.KBackTab [])) fs st =
  B.put st{appScreen = ScreenPartnerForm fs{pfFocus = cycleL (pfFocus fs)}}
handlePartnerFormEv ev fs st = case pfFocus fs of
  PFCode -> do
    (ed, ()) <- B.nestEventM (pfCode fs) (E.handleEditorEvent ev)
    B.put st{appScreen = ScreenPartnerForm fs{pfCode = ed}}
  PFName -> do
    (ed, ()) <- B.nestEventM (pfName fs) (E.handleEditorEvent ev)
    B.put st{appScreen = ScreenPartnerForm fs{pfName = ed}}
  PFType -> handleEnumCycle ev (\v -> fs{pfType = v}) (pfType fs) st ScreenPartnerForm
  PFActive -> handleBoolCycle ev (\v -> fs{pfActive = v}) (pfActive fs) st ScreenPartnerForm
  PFSubmit -> case ev of
    VtyEvent (Vty.EvKey Vty.KEnter []) -> submitPartner fs st
    _ -> pure ()
  PFCancel -> case ev of
    VtyEvent (Vty.EvKey Vty.KEnter []) ->
      B.put st{appScreen = ScreenPartnerList (initPartnerList (appMasters st))}
    _ -> pure ()

submitPartner :: PartnerFormState -> AppState -> EventM Name AppState ()
submitPartner fs st = do
  let codeT = edText (pfCode fs)
  case mkPartnerId codeT of
    Left err -> B.put st{appScreen = ScreenPartnerForm fs{pfError = Just (AppInputError err)}}
    Right pid -> do
      let p =
            Partner
              { partnerId = pid
              , partnerName = edText (pfName fs)
              , partnerType = pfType fs
              , partnerActive = pfActive fs
              }
          cmd = if pfIsNew fs then RegisterPartner p else UpdatePartner p
      result <- liftIO (executeCommand (appStore st) cmd)
      case result of
        Left err -> B.put st{appScreen = ScreenPartnerForm fs{pfError = Just err}}
        Right _ -> do
          mb <- liftIO (loadMasterBook (appStore st))
          let newMasters = either (const (appMasters st)) id mb
          B.put
            st
              { appMasters = newMasters
              , appScreen = ScreenPartnerList (initPartnerList newMasters)
              }

-- ── internal ──────────────────────────────────────────────────────────────────

handleEnumCycle ::
  (Bounded a, Enum a, Eq a) =>
  BrickEvent Name AppEvent -> (a -> s) -> a -> AppState -> (s -> Screen) -> EventM Name AppState ()
handleEnumCycle (VtyEvent (Vty.EvKey Vty.KLeft [])) mk v st wrap =
  B.put st{appScreen = wrap (mk (cycleL v))}
handleEnumCycle (VtyEvent (Vty.EvKey Vty.KRight [])) mk v st wrap =
  B.put st{appScreen = wrap (mk (cycleR v))}
handleEnumCycle (VtyEvent (Vty.EvKey (Vty.KChar ' ') [])) mk v st wrap =
  B.put st{appScreen = wrap (mk (cycleR v))}
handleEnumCycle _ _ _ _ _ = pure ()

handleBoolCycle ::
  BrickEvent Name AppEvent ->
  (Bool -> s) ->
  Bool ->
  AppState ->
  (s -> Screen) ->
  EventM Name AppState ()
handleBoolCycle ev mk v st wrap = handleEnumCycle ev (\b -> mk (b == BTrue)) (if v then BTrue else BFalse) st wrap

data BoolFlag = BFalse | BTrue deriving (Bounded, Enum, Eq)

safeIndex :: [a] -> Int -> Maybe a
safeIndex [] _ = Nothing
safeIndex (x : _) 0 = Just x
safeIndex (_ : xs) n = safeIndex xs (n - 1)
