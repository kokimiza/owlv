-- | 組織マスタ画面（一覧 + フォーム）
module Shell.TUI.Screen.Master.Organisation
  ( drawOrgList
  , handleOrgListEv
  , drawOrgForm
  , handleOrgFormEv
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
import Core.Domain.Organisation
  ( Organisation (..)
  , OrganisationId (..)
  , mkOrganisationId
  )
import Shell.AppError (AppError (..))
import Shell.CommandExecutor (executeCommand, loadMasterBook)
import Shell.ErrorCatalog (ErrorCatalog, renderAppError)
import Shell.TUI.Attrs
import Shell.TUI.Helpers
import Shell.TUI.Types

-- ── List screen ───────────────────────────────────────────────────────────────

drawOrgList :: OrgListState -> Widget Name
drawOrgList st =
  B.vBox
    [ B.withBorderStyle BBS.unicodeBold $
        BB.borderWithLabel (withAttr titleAttr (str " 組織マスタ一覧 ")) $
          B.padLeftRight 1 $
            B.vBox
              [ withAttr labelAttr (str " コード        名称                        有効")
              , BB.hBorder
              , if null (olOrgs st)
                  then withAttr hintAttr (BC.hCenter (str "登録データなし"))
                  else B.vBox (zipWith (drawOrgRow (olSelected st)) [0 ..] (olOrgs st))
              ]
    , drawHint "↑/↓:移動  n:新規  Enter:編集  Esc:メニューへ"
    ]

drawOrgRow :: Int -> Int -> Organisation -> Widget Name
drawOrgRow selected idx org =
  let isSelected = idx == selected
      codeW = B.hLimit 14 (txt (unOrgId (orgId org)))
      nameW = B.hLimit 26 (txt (orgName org))
      actW = str (if orgActive org then "○" else "×")
      row_ = B.hBox [str " ", codeW, str " ", nameW, str " ", actW]
  in if isSelected then withAttr focusedAttr row_ else row_

handleOrgListEv :: BrickEvent Name AppEvent -> OrgListState -> AppState -> EventM Name AppState ()
handleOrgListEv (VtyEvent (Vty.EvKey Vty.KEsc [])) _ st =
  B.put st{appScreen = ScreenMasterMenu}
handleOrgListEv (VtyEvent (Vty.EvKey Vty.KUp [])) ls st =
  B.put st{appScreen = ScreenOrgList ls{olSelected = max 0 (olSelected ls - 1)}}
handleOrgListEv (VtyEvent (Vty.EvKey Vty.KDown [])) ls st =
  B.put
    st{appScreen = ScreenOrgList ls{olSelected = min (length (olOrgs ls) - 1) (olSelected ls + 1)}}
handleOrgListEv (VtyEvent (Vty.EvKey (Vty.KChar 'n') [])) _ st =
  B.put st{appScreen = ScreenOrgForm (initOrgForm Nothing)}
handleOrgListEv (VtyEvent (Vty.EvKey Vty.KEnter [])) ls st =
  let mOrg = safeIndex (olOrgs ls) (olSelected ls)
  in B.put st{appScreen = ScreenOrgForm (initOrgForm mOrg)}
handleOrgListEv _ _ _ = pure ()

-- ── Form screen ───────────────────────────────────────────────────────────────

drawOrgForm :: ErrorCatalog -> OrgFormState -> Widget Name
drawOrgForm cat fs =
  B.vBox
    [ B.withBorderStyle BBS.unicodeBold $
        BB.borderWithLabel (withAttr titleAttr (str (if ofIsNew fs then " 組織登録 " else " 組織編集 "))) $
          B.padLeftRight 1 $
            B.vBox
              [ row "コード    " $ renderTextEd (ofFocus fs == OFCode) (ofCode fs)
              , row "名称      " $ renderTextEd (ofFocus fs == OFName) (ofName fs)
              , row "上位部署  " $
                  B.hBox
                    [ renderTextEd (ofFocus fs == OFParent) (ofParent fs)
                    , withAttr hintAttr (str " (空欄=なし)")
                    ]
              , row "有効      " $
                  drawCycleField
                    (ofFocus fs == OFActive)
                    (if ofActive fs then "有効" else "無効")
              , BB.hBorder
              , B.hBox
                  [ drawBtn (ofFocus fs == OFSubmit) "  登録  "
                  , str "   "
                  , drawBtn (ofFocus fs == OFCancel) " キャンセル "
                  ]
              ]
    , drawError (fmap (renderAppError cat) (ofError fs))
    , drawHint "Tab:次へ  Shift+Tab:前へ  ←/→:切替  Enter:確定  Esc:一覧へ"
    ]

handleOrgFormEv :: BrickEvent Name AppEvent -> OrgFormState -> AppState -> EventM Name AppState ()
handleOrgFormEv (VtyEvent (Vty.EvKey Vty.KEsc [])) _ st =
  B.put st{appScreen = ScreenOrgList (initOrgList (appMasters st))}
handleOrgFormEv (VtyEvent (Vty.EvKey (Vty.KChar '\t') [])) fs st =
  B.put st{appScreen = ScreenOrgForm fs{ofFocus = cycleR (ofFocus fs)}}
handleOrgFormEv (VtyEvent (Vty.EvKey Vty.KBackTab [])) fs st =
  B.put st{appScreen = ScreenOrgForm fs{ofFocus = cycleL (ofFocus fs)}}
handleOrgFormEv ev fs st = case ofFocus fs of
  OFCode -> do
    (ed, ()) <- B.nestEventM (ofCode fs) (E.handleEditorEvent ev)
    B.put st{appScreen = ScreenOrgForm fs{ofCode = ed}}
  OFName -> do
    (ed, ()) <- B.nestEventM (ofName fs) (E.handleEditorEvent ev)
    B.put st{appScreen = ScreenOrgForm fs{ofName = ed}}
  OFParent -> do
    (ed, ()) <- B.nestEventM (ofParent fs) (E.handleEditorEvent ev)
    B.put st{appScreen = ScreenOrgForm fs{ofParent = ed}}
  OFActive -> case ev of
    VtyEvent (Vty.EvKey Vty.KLeft []) -> B.put st{appScreen = ScreenOrgForm fs{ofActive = not (ofActive fs)}}
    VtyEvent (Vty.EvKey Vty.KRight []) -> B.put st{appScreen = ScreenOrgForm fs{ofActive = not (ofActive fs)}}
    VtyEvent (Vty.EvKey (Vty.KChar ' ') []) -> B.put st{appScreen = ScreenOrgForm fs{ofActive = not (ofActive fs)}}
    _ -> pure ()
  OFSubmit -> case ev of
    VtyEvent (Vty.EvKey Vty.KEnter []) -> submitOrg fs st
    _ -> pure ()
  OFCancel -> case ev of
    VtyEvent (Vty.EvKey Vty.KEnter []) ->
      B.put st{appScreen = ScreenOrgList (initOrgList (appMasters st))}
    _ -> pure ()

submitOrg :: OrgFormState -> AppState -> EventM Name AppState ()
submitOrg fs st = do
  let codeT = edText (ofCode fs)
      nameT = edText (ofName fs)
      parentT = edText (ofParent fs)
  case mkOrganisationId codeT of
    Left err -> B.put st{appScreen = ScreenOrgForm fs{ofError = Just (AppInputError err)}}
    Right oid -> do
      let parent =
            if T.null parentT
              then Nothing
              else case mkOrganisationId parentT of
                Right pid -> Just pid
                Left _ -> Nothing
          org =
            Organisation
              { orgId = oid
              , orgName = nameT
              , orgParent = parent
              , orgActive = ofActive fs
              }
          cmd = if ofIsNew fs then RegisterOrganisation org else UpdateOrganisation org
      result <- liftIO (executeCommand (appStore st) cmd)
      case result of
        Left err -> B.put st{appScreen = ScreenOrgForm fs{ofError = Just err}}
        Right _ -> do
          mb <- liftIO (loadMasterBook (appStore st))
          let newMasters = either (const (appMasters st)) id mb
          B.put
            st
              { appMasters = newMasters
              , appScreen = ScreenOrgList (initOrgList newMasters)
              }

-- ── internal ──────────────────────────────────────────────────────────────────

safeIndex :: [a] -> Int -> Maybe a
safeIndex [] _ = Nothing
safeIndex (x : _) 0 = Just x
safeIndex (_ : xs) n = safeIndex xs (n - 1)
