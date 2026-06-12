module Shell.TUI.App (runTUI) where

import Brick
  ( App (..)
  , AttrMap
  , AttrName
  , BrickEvent (..)
  , EventM
  , Widget
  , attrMap
  , attrName
  , defaultMain
  , get
  , halt
  , nestEventM
  , on
  , put
  , str
  , txt
  , withAttr
  , withBorderStyle
  )
import Control.Monad.IO.Class (liftIO)
import qualified Brick as B
import qualified Brick.Widgets.Border as BB
import qualified Brick.Widgets.Border.Style as BBS
import qualified Brick.Widgets.Center as BC
import qualified Brick.Widgets.Edit as E
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (getCurrentTime, utctDay)
import qualified Graphics.Vty as Vty
import Graphics.Vty.Attributes (defAttr)

import Core.Domain.Journal (DrCr (..), JournalActionType (..), RiskTier (..))
import Core.Domain.Money (addMoney, unMoney, zeroMoney)
import qualified Core.Domain.Money
import Shell.AppError (AppError (..))
import Shell.EventStore (EventStore)
import Shell.TUI.Submit (submitJournalEntry)
import Shell.TUI.Types

-- ── Entry point ─────────────────────────────────────────────────────────────

runTUI :: EventStore -> IO ()
runTUI store = do
  let initState = AppState
        { appScreen = ScreenMenu
        , appStore  = store
        }
  _ <- defaultMain owlvApp initState
  pure ()

-- ── Brick App definition ─────────────────────────────────────────────────────

owlvApp :: App AppState () Name
owlvApp =
  App
    { appDraw         = drawUI
    , appChooseCursor = B.showFirstCursor
    , appHandleEvent  = handleEvent
    , appStartEvent   = pure ()
    , appAttrMap      = const owlvAttrMap
    }

-- ── Attributes ───────────────────────────────────────────────────────────────

focusedAttr, labelAttr, titleAttr, errorAttr, hintAttr :: AttrName
focusedAttr = attrName "focused"
labelAttr   = attrName "label"
titleAttr   = attrName "title"
errorAttr   = attrName "error"
hintAttr    = attrName "hint"

owlvAttrMap :: AttrMap
owlvAttrMap =
  attrMap
    defAttr
    [ (focusedAttr, Vty.black `on` Vty.cyan)
    , (labelAttr,   Vty.withStyle defAttr Vty.bold)
    , (titleAttr,   Vty.white `on` Vty.blue)
    , (errorAttr,   Vty.red   `on` Vty.black)
    , (hintAttr,    Vty.withStyle defAttr Vty.dim)
    , (E.editAttr,       defAttr)
    , (E.editFocusedAttr, Vty.black `on` Vty.cyan)
    ]

-- ── Draw ─────────────────────────────────────────────────────────────────────

drawUI :: AppState -> [Widget Name]
drawUI st = case appScreen st of
  ScreenMenu            -> [drawMenu]
  ScreenJournalForm jf  -> [drawJournalForm jf]

-- ── Menu screen ──────────────────────────────────────────────────────────────

drawMenu :: Widget Name
drawMenu =
  BC.center $
    B.hLimit 52 $
      withBorderStyle BBS.unicodeBold $
        BB.borderWithLabel (withAttr titleAttr (str " owlv ")) $
          B.padAll 2 $
            B.vBox
              [ withAttr titleAttr (BC.hCenter (str "IFRS 月次決算確報システム"))
              , str " "
              , BC.hCenter (str "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
              , str " "
              , BC.hCenter (str "[ 1 ]  原始記録入力  (仕訳帳 §2.1)")
              , str " "
              , BC.hCenter (str "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
              , str " "
              , withAttr hintAttr (BC.hCenter (str "[ q ] 終了"))
              ]

-- ── Journal form screen ───────────────────────────────────────────────────────

drawJournalForm :: JournalFormState -> Widget Name
drawJournalForm jf =
  B.vBox
    [ withBorderStyle BBS.unicodeBold $
        BB.borderWithLabel (withAttr titleAttr (str " 原始記録入力 (§2.1) ")) $
          B.padLeftRight 1 $
            B.vBox
              [ drawFormFields jf
              , BB.hBorder
              , drawJournalLines jf
              , BB.hBorder
              , drawTotals jf
              , BB.hBorder
              , drawButtons jf
              ]
    , drawError (jfError jf)
    , withAttr hintAttr $
        str "Tab:次へ  Shift+Tab:前へ  ←/→:選択変更  Enter:確定  Esc:メニューへ"
    ]

-- Fixed fields section
drawFormFields :: JournalFormState -> Widget Name
drawFormFields jf =
  B.vBox
    [ row "取引発生日  " $
        renderTextEd (jfFocus jf == FFDate) (jfDate jf) <+>
        withAttr hintAttr (str " (YYYY-MM-DD)")
    , row "仕訳行為区分" $
        drawCycleField (jfFocus jf == FFActionType) (showAction (jfAction jf))
    , row "リスク分類  " $
        drawCycleField (jfFocus jf == FFRiskTier) (showRisk (jfRisk jf))
    , row "証憑        " $
        drawCycleField (jfFocus jf == FFVoucherKind) (showVKind (jfVKind jf))
        <+> str "  番号: "
        <+> renderTextEd
              (jfFocus jf == FFVoucherRef && jfVKind jf == VKAttached)
              (jfVRef jf)
    , row "摘要        " $
        renderTextEd (jfFocus jf == FFMemo) (jfMemo jf)
    ]

-- Journal lines section
drawJournalLines :: JournalFormState -> Widget Name
drawJournalLines jf =
  B.vBox
    [ B.padTop (B.Pad 0) $
        withAttr labelAttr (str " 仕訳行 (借方 / 貸方)")
    , drawLine 1 (jfFocus jf) FFL1Account FFL1DrCr FFL1Amount
                  (jfL1Acc jf) (jfL1DrCr jf) (jfL1Amt jf)
    , drawLine 2 (jfFocus jf) FFL2Account FFL2DrCr FFL2Amount
                  (jfL2Acc jf) (jfL2DrCr jf) (jfL2Amt jf)
    ]

drawLine
  :: Int -> FormFocus
  -> FormFocus -> FormFocus -> FormFocus
  -> E.Editor Text Name -> DrCr -> E.Editor Text Name
  -> Widget Name
drawLine idx cur fAcc fDC fAmt accEd dc amtEd =
  B.hBox
    [ str (show idx <> ". 科目: ")
    , renderTextEd (cur == fAcc) accEd
    , str "  "
    , drawCycleField (cur == fDC) (showDrCr dc)
    , str "  金額: "
    , renderTextEd (cur == fAmt) amtEd
    ]

drawTotals :: JournalFormState -> Widget Name
drawTotals jf =
  let dr = addMoney (parseMoney (jfL1Amt jf) (jfL1DrCr jf) Debit)
                    (parseMoney (jfL2Amt jf) (jfL2DrCr jf) Debit)
      cr = addMoney (parseMoney (jfL1Amt jf) (jfL1DrCr jf) Credit)
                    (parseMoney (jfL2Amt jf) (jfL2DrCr jf) Credit)
  in B.hBox
       [ str "借方合計: "
       , str (show (unMoney dr))
       , str "   貸方合計: "
       , str (show (unMoney cr))
       ]

drawButtons :: JournalFormState -> Widget Name
drawButtons jf =
  B.hBox
    [ drawBtn (jfFocus jf == FFSubmit) "  登録  "
    , str "   "
    , drawBtn (jfFocus jf == FFCancel) " キャンセル "
    ]

drawError :: Maybe Text -> Widget Name
drawError Nothing    = str " "
drawError (Just msg) = withAttr errorAttr (txt ("エラー: " <> msg))

-- ── Widget helpers ───────────────────────────────────────────────────────────

-- infix alias for hBox pair (avoids import of <+> from brick)
infixl 6 <+>
(<+>) :: Widget n -> Widget n -> Widget n
a <+> b = B.hBox [a, b]

row :: String -> Widget Name -> Widget Name
row label w =
  B.hBox
    [ withAttr labelAttr (str (label <> ": "))
    , B.hLimit 30 w
    ]

renderTextEd :: Bool -> E.Editor Text Name -> Widget Name
renderTextEd focused ed =
  B.hLimit 28 $
    E.renderEditor (txt . T.concat) focused ed

drawCycleField :: Bool -> String -> Widget Name
drawCycleField focused label =
  let w = str ("< " <> label <> " >")
  in if focused then withAttr focusedAttr w else w

drawBtn :: Bool -> String -> Widget Name
drawBtn focused label =
  let w = B.padLeftRight 1 (str label)
  in if focused then withAttr focusedAttr (BB.border w) else BB.border w

-- ── Label helpers ─────────────────────────────────────────────────────────────

showAction :: JournalActionType -> String
showAction NewEntry       = "新規起票"
showAction Cancellation   = "取消"
showAction Reversal       = "反対"
showAction Supplementary  = "追加"
showAction Reclassification = "再分類"
showAction SwapRefresh    = "洗替"
showAction EstimateChange = "見積変更"

showRisk :: RiskTier -> String
showRisk Low      = "Low"
showRisk Medium   = "Medium"
showRisk High     = "High"
showRisk Critical = "Critical"

showVKind :: VoucherKind -> String
showVKind VKAttached = "証憑あり"
showVKind VKPending  = "証憑未着"

showDrCr :: DrCr -> String
showDrCr Debit  = "借方"
showDrCr Credit = "貸方"

parseMoney :: E.Editor Text Name -> DrCr -> DrCr -> Core.Domain.Money.Money
parseMoney ed dc target
  | dc /= target = zeroMoney
  | otherwise = case reads (T.unpack (T.intercalate "\n" (E.getEditContents ed))) of
      [(d, "")] -> Core.Domain.Money.mkMoney d
      _         -> zeroMoney

-- ── Event handling ────────────────────────────────────────────────────────────

handleEvent :: BrickEvent Name () -> EventM Name AppState ()
handleEvent ev = do
  st <- get
  case appScreen st of
    ScreenMenu           -> handleMenuEv ev st
    ScreenJournalForm jf -> handleFormEv ev jf st

-- Menu
handleMenuEv :: BrickEvent Name () -> AppState -> EventM Name AppState ()
handleMenuEv (VtyEvent (Vty.EvKey (Vty.KChar '1') [])) st = do
  today <- liftIO (utctDay <$> getCurrentTime)
  put st{appScreen = ScreenJournalForm (initJournalForm today)}
handleMenuEv (VtyEvent (Vty.EvKey (Vty.KChar 'q') [])) _ = halt
handleMenuEv (VtyEvent (Vty.EvKey Vty.KEsc []))          _ = halt
handleMenuEv _ _ = pure ()

-- Form: navigation + field events
handleFormEv :: BrickEvent Name () -> JournalFormState -> AppState -> EventM Name AppState ()
handleFormEv (VtyEvent (Vty.EvKey Vty.KEsc [])) _ st =
  put st{appScreen = ScreenMenu}
handleFormEv (VtyEvent (Vty.EvKey (Vty.KChar '\t') [])) jf st =
  put st{appScreen = ScreenJournalForm jf{jfFocus = nextFocus (jfVKind jf) (jfFocus jf)}}
handleFormEv (VtyEvent (Vty.EvKey Vty.KBackTab [])) jf st =
  put st{appScreen = ScreenJournalForm jf{jfFocus = prevFocus (jfVKind jf) (jfFocus jf)}}
handleFormEv ev jf st = handleFocusedField ev jf st

handleFocusedField
  :: BrickEvent Name () -> JournalFormState -> AppState -> EventM Name AppState ()
handleFocusedField ev jf st = case jfFocus jf of
  -- Text editors — delegate via nestEventM
  FFDate -> do
    (newEd, ()) <- nestEventM (jfDate jf) (E.handleEditorEvent ev)
    put st{appScreen = ScreenJournalForm jf{jfDate = newEd}}
  FFVoucherRef -> do
    (newEd, ()) <- nestEventM (jfVRef jf) (E.handleEditorEvent ev)
    put st{appScreen = ScreenJournalForm jf{jfVRef = newEd}}
  FFMemo -> do
    (newEd, ()) <- nestEventM (jfMemo jf) (E.handleEditorEvent ev)
    put st{appScreen = ScreenJournalForm jf{jfMemo = newEd}}
  FFL1Account -> do
    (newEd, ()) <- nestEventM (jfL1Acc jf) (E.handleEditorEvent ev)
    put st{appScreen = ScreenJournalForm jf{jfL1Acc = newEd}}
  FFL1Amount -> do
    (newEd, ()) <- nestEventM (jfL1Amt jf) (E.handleEditorEvent ev)
    put st{appScreen = ScreenJournalForm jf{jfL1Amt = newEd}}
  FFL2Account -> do
    (newEd, ()) <- nestEventM (jfL2Acc jf) (E.handleEditorEvent ev)
    put st{appScreen = ScreenJournalForm jf{jfL2Acc = newEd}}
  FFL2Amount -> do
    (newEd, ()) <- nestEventM (jfL2Amt jf) (E.handleEditorEvent ev)
    put st{appScreen = ScreenJournalForm jf{jfL2Amt = newEd}}
  -- Cycle fields — left/right arrows
  FFActionType -> handleCycle ev (\v -> jf{jfAction = v}) (jfAction jf) st
  FFRiskTier   -> handleCycle ev (\v -> jf{jfRisk   = v}) (jfRisk   jf) st
  FFVoucherKind -> handleCycle ev (\v -> jf{jfVKind = v}) (jfVKind  jf) st
  FFL1DrCr -> handleCycle ev (\v -> jf{jfL1DrCr = v}) (jfL1DrCr jf) st
  FFL2DrCr -> handleCycle ev (\v -> jf{jfL2DrCr = v}) (jfL2DrCr jf) st
  -- Buttons
  FFSubmit -> case ev of
    VtyEvent (Vty.EvKey Vty.KEnter []) -> handleSubmit jf st
    _ -> pure ()
  FFCancel -> case ev of
    VtyEvent (Vty.EvKey Vty.KEnter []) -> put st{appScreen = ScreenMenu}
    _ -> pure ()

handleCycle
  :: (Eq a, Enum a, Bounded a)
  => BrickEvent Name () -> (a -> JournalFormState) -> a -> AppState -> EventM Name AppState ()
handleCycle (VtyEvent (Vty.EvKey Vty.KLeft []))  mk v st =
  put st{appScreen = ScreenJournalForm (mk (cycleL v))}
handleCycle (VtyEvent (Vty.EvKey Vty.KRight [])) mk v st =
  put st{appScreen = ScreenJournalForm (mk (cycleR v))}
handleCycle (VtyEvent (Vty.EvKey (Vty.KChar ' ') [])) mk v st =
  put st{appScreen = ScreenJournalForm (mk (cycleR v))}
handleCycle _ _ _ _ = pure ()

handleSubmit :: JournalFormState -> AppState -> EventM Name AppState ()
handleSubmit jf st = do
  result <- liftIO (submitJournalEntry (appStore st) jf)
  case result of
    Right () ->
      put st{appScreen = ScreenMenu}
    Left err ->
      put st{appScreen = ScreenJournalForm jf{jfError = Just (renderErr err)}}

renderErr :: AppError -> Text
renderErr (DomainValidationError t) = t
renderErr (StorageError t)          = "保存エラー: " <> t
renderErr (ConnectionError t)       = "接続エラー: " <> t
renderErr (NotFound t)              = "未検出: " <> t

cycleL :: (Eq a, Enum a, Bounded a) => a -> a
cycleL x = if x == minBound then maxBound else pred x

cycleR :: (Eq a, Enum a, Bounded a) => a -> a
cycleR x = if x == maxBound then minBound else succ x
