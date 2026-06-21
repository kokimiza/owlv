{-# LANGUAGE BlockArguments #-}

-- | 勘定科目マスタ画面（一覧 + フォーム）
module Shell.TUI.Screen.Master.AccountCode
  ( drawAccountList
  , handleAccountListEv
  , drawAccountForm
  , handleAccountFormEv
  ) where

import Brick (BrickEvent (..), EventM, Widget, str, txt, withAttr)
import Control.Monad.Except (ExceptT (..), liftEither, runExceptT, withExceptT)
import Control.Monad.IO.Class (liftIO)

import Brick qualified as B
import Brick.Widgets.Border qualified as BB
import Brick.Widgets.Border.Style qualified as BBS
import Brick.Widgets.Center qualified as BC
import Brick.Widgets.Edit qualified as E
import Data.Text qualified as T
import Graphics.Vty qualified as Vty

import Core.Command (Command (..))
import Core.Domain.AccountCode (mkAccountCode, unAccountCode)
import Core.Domain.AccountMaster
  ( AccountMaster (..)
  , defaultNormalBalance
  , showAccountCategory
  )
import Core.Domain.Journal (DrCr (..))
import Shell.AppError (AppError (..))
import Shell.CommandExecutor (executeCommand, loadMasterBook)
import Shell.ErrorCatalog (ErrorCatalog, renderAppError)
import Shell.TUI.Attrs
import Shell.TUI.Helpers
import Shell.TUI.Types

-- ── List screen ───────────────────────────────────────────────────────────────

drawAccountList :: AccountListState -> Widget Name
drawAccountList st =
  B.vBox
    [ B.withBorderStyle BBS.unicodeBold $
        BB.borderWithLabel (withAttr titleAttr (str " 勘定科目マスタ一覧 ")) $
          B.padLeftRight 1 $
            B.vBox
              [ withAttr labelAttr (str " コード   名称                    分類    正常残高  有効")
              , BB.hBorder
              , if null (alAccounts st)
                  then withAttr hintAttr (BC.hCenter (str "登録データなし"))
                  else B.vBox (zipWith (drawAccountRow (alSelected st)) [0 ..] (alAccounts st))
              ]
    , drawHint "↑/↓:移動  n:新規  Enter:編集  Esc:メニューへ"
    ]

drawAccountRow :: Int -> Int -> AccountMaster -> Widget Name
drawAccountRow selected idx am =
  let isSelected = idx == selected
      codeW = B.hLimit 9 (txt (unAccountCode (amCode am)))
      nameW = B.hLimit 22 (txt (amName am))
      catW = B.hLimit 8 (txt (showAccountCategory (amCategory am)))
      balW = B.hLimit 10 (str (if amNormalBalance am == Debit then "借方" else "貸方"))
      actW = str (if amActive am then "○" else "×")
      row_ = B.hBox [str " ", codeW, str " ", nameW, str " ", catW, str " ", balW, str " ", actW]
  in if isSelected then withAttr focusedAttr row_ else row_

handleAccountListEv ::
  BrickEvent Name AppEvent -> AccountListState -> AppState -> EventM Name AppState ()
handleAccountListEv (VtyEvent (Vty.EvKey Vty.KEsc [])) _ st =
  B.put st{appScreen = ScreenMasterMenu}
handleAccountListEv (VtyEvent (Vty.EvKey Vty.KUp [])) ls st =
  B.put st{appScreen = ScreenAccountList ls{alSelected = max 0 (alSelected ls - 1)}}
handleAccountListEv (VtyEvent (Vty.EvKey Vty.KDown [])) ls st =
  B.put
    st
      { appScreen = ScreenAccountList ls{alSelected = min (length (alAccounts ls) - 1) (alSelected ls + 1)}
      }
handleAccountListEv (VtyEvent (Vty.EvKey (Vty.KChar 'n') [])) _ st =
  B.put st{appScreen = ScreenAccountForm (initAccountForm Nothing)}
handleAccountListEv (VtyEvent (Vty.EvKey Vty.KEnter [])) ls st =
  let mam = safeIndex (alAccounts ls) (alSelected ls)
  in B.put st{appScreen = ScreenAccountForm (initAccountForm mam)}
handleAccountListEv _ _ _ = pure ()

-- ── Form screen ───────────────────────────────────────────────────────────────

drawAccountForm :: ErrorCatalog -> AccountFormState -> Widget Name
drawAccountForm cat fs =
  B.vBox
    [ B.withBorderStyle BBS.unicodeBold $
        BB.borderWithLabel (withAttr titleAttr (str (if affIsNew fs then " 勘定科目登録 " else " 勘定科目編集 "))) $
          B.padLeftRight 1 $
            B.vBox
              [ row "コード    " $ renderTextEd (affFocus fs == AFFCode) (affCode fs)
              , row "名称      " $ renderTextEd (affFocus fs == AFFName) (affName fs)
              , row "分類      " $
                  drawCycleField
                    (affFocus fs == AFFCategory)
                    (T.unpack (showAccountCategory (affCategory fs)))
              , row "正常残高  " $
                  drawCycleField
                    (affFocus fs == AFFNormalBal)
                    (if affNormalBal fs == Debit then "借方" else "貸方")
              , row "有効      " $
                  drawCycleField
                    (affFocus fs == AFFActive)
                    (if affActive fs then "有効" else "無効")
              , BB.hBorder
              , B.hBox
                  [ drawBtn (affFocus fs == AFFSubmit) "  登録  "
                  , str "   "
                  , drawBtn (affFocus fs == AFFCancel) " キャンセル "
                  ]
              ]
    , drawError (fmap (renderAppError cat) (affError fs))
    , drawHint "Tab:次へ  Shift+Tab:前へ  ←/→:切替  Enter:確定  Esc:一覧へ"
    ]

handleAccountFormEv ::
  BrickEvent Name AppEvent -> AccountFormState -> AppState -> EventM Name AppState ()
handleAccountFormEv (VtyEvent (Vty.EvKey Vty.KEsc [])) _ st =
  B.put st{appScreen = ScreenAccountList (initAccountList (appMasters st))}
handleAccountFormEv (VtyEvent (Vty.EvKey (Vty.KChar '\t') [])) fs st =
  B.put st{appScreen = ScreenAccountForm fs{affFocus = cycleR (affFocus fs)}}
handleAccountFormEv (VtyEvent (Vty.EvKey Vty.KBackTab [])) fs st =
  B.put st{appScreen = ScreenAccountForm fs{affFocus = cycleL (affFocus fs)}}
handleAccountFormEv ev fs st = case affFocus fs of
  AFFCode -> do
    (ed, ()) <- B.nestEventM (affCode fs) (E.handleEditorEvent ev)
    B.put st{appScreen = ScreenAccountForm fs{affCode = ed}}
  AFFName -> do
    (ed, ()) <- B.nestEventM (affName fs) (E.handleEditorEvent ev)
    B.put st{appScreen = ScreenAccountForm fs{affName = ed}}
  AFFCategory -> case ev of
    VtyEvent (Vty.EvKey Vty.KLeft []) ->
      let cat = cycleL (affCategory fs)
      in B.put
           st{appScreen = ScreenAccountForm fs{affCategory = cat, affNormalBal = defaultNormalBalance cat}}
    VtyEvent (Vty.EvKey Vty.KRight []) ->
      let cat = cycleR (affCategory fs)
      in B.put
           st{appScreen = ScreenAccountForm fs{affCategory = cat, affNormalBal = defaultNormalBalance cat}}
    VtyEvent (Vty.EvKey (Vty.KChar ' ') []) ->
      let cat = cycleR (affCategory fs)
      in B.put
           st{appScreen = ScreenAccountForm fs{affCategory = cat, affNormalBal = defaultNormalBalance cat}}
    _ -> pure ()
  AFFNormalBal -> case ev of
    VtyEvent (Vty.EvKey Vty.KLeft []) -> B.put st{appScreen = ScreenAccountForm fs{affNormalBal = cycleL (affNormalBal fs)}}
    VtyEvent (Vty.EvKey Vty.KRight []) -> B.put st{appScreen = ScreenAccountForm fs{affNormalBal = cycleR (affNormalBal fs)}}
    VtyEvent (Vty.EvKey (Vty.KChar ' ') []) -> B.put st{appScreen = ScreenAccountForm fs{affNormalBal = cycleR (affNormalBal fs)}}
    _ -> pure ()
  AFFActive -> case ev of
    VtyEvent (Vty.EvKey Vty.KLeft []) -> B.put st{appScreen = ScreenAccountForm fs{affActive = not (affActive fs)}}
    VtyEvent (Vty.EvKey Vty.KRight []) -> B.put st{appScreen = ScreenAccountForm fs{affActive = not (affActive fs)}}
    VtyEvent (Vty.EvKey (Vty.KChar ' ') []) -> B.put st{appScreen = ScreenAccountForm fs{affActive = not (affActive fs)}}
    _ -> pure ()
  AFFSubmit -> case ev of
    VtyEvent (Vty.EvKey Vty.KEnter []) -> submitAccount fs st
    _ -> pure ()
  AFFCancel -> case ev of
    VtyEvent (Vty.EvKey Vty.KEnter []) ->
      B.put st{appScreen = ScreenAccountList (initAccountList (appMasters st))}
    _ -> pure ()

submitAccount :: AccountFormState -> AppState -> EventM Name AppState ()
submitAccount fs st =
  runExceptT
    do
      ac <- withExceptT AppInputError (liftEither (mkAccountCode codeT))
      let am =
            AccountMaster
              { amCode = ac
              , amName = edText (affName fs)
              , amCategory = affCategory fs
              , amNormalBalance = affNormalBal fs
              , amSettlement = affSettlement fs
              , amActive = affActive fs
              }
          cmd = if affIsNew fs then RegisterAccountMaster am else UpdateAccountMaster am
      _ <- ExceptT (liftIO (executeCommand (appStore st) cmd))
      mb <- liftIO (loadMasterBook (appStore st))
      pure (either (const (appMasters st)) id mb)
    >>= \case
      Left err -> B.put st{appScreen = ScreenAccountForm fs{affError = Just err}}
      Right newMasters ->
        B.put
          st
            { appMasters = newMasters
            , appScreen = ScreenAccountList (initAccountList newMasters)
            }
 where
  codeT = edText (affCode fs)

safeIndex :: [a] -> Int -> Maybe a
safeIndex [] _ = Nothing
safeIndex (x : _) 0 = Just x
safeIndex (_ : xs) n = safeIndex xs (n - 1)
