-- | 原始記録入力画面 (§2.1)
module Shell.TUI.Screen.Journal
  ( drawJournalForm
  , handleFormEv
  ) where

import Brick
  ( BrickEvent (..)
  , EventM
  , Widget
  , str
  , txt
  , withAttr
  )
import Control.Monad.IO.Class (liftIO)
import Data.Maybe (fromMaybe)
import Data.Text (Text)

import Brick qualified as B
import Brick.Widgets.Border qualified as BB
import Brick.Widgets.Border.Style qualified as BBS
import Brick.Widgets.Edit qualified as E
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Graphics.Vty qualified as Vty

import Core.Domain.AccountCode (mkAccountCode)
import Core.Domain.AccountMaster (AccountMaster (..))
import Core.Domain.Journal (DrCr (..), JournalActionType (..), RiskTier (..))
import Core.Domain.Money (addMoney, unMoney, zeroMoney)
import Core.Domain.Organisation (Organisation (..), OrganisationId (..))
import Core.State (MasterBook (..))
import Shell.ErrorCatalog (ErrorCatalog, renderAppError)
import Shell.TUI.Attrs
import Shell.TUI.Helpers
import Shell.TUI.Submit (submitJournalEntry)
import Shell.TUI.Types

import Core.Domain.Money qualified as M

-- ── Draw ─────────────────────────────────────────────────────────────────────

drawJournalForm :: ErrorCatalog -> MasterBook -> JournalFormState -> Widget Name
drawJournalForm cat masters jf =
  B.vBox
    [ B.withBorderStyle BBS.unicodeBold $
        BB.borderWithLabel (withAttr titleAttr (str " 原始記録入力 (§2.1) ")) $
          B.padLeftRight 1 $
            B.vBox
              [ drawFormFields masters jf
              , BB.hBorder
              , drawJournalLines masters jf
              , BB.hBorder
              , drawTotals jf
              , BB.hBorder
              , drawButtons jf
              ]
    , drawError (fmap (renderAppError cat) (jfError jf))
    , drawHint "Tab:次へ  Shift+Tab:前へ  ←/→:選択変更  Enter:確定  Esc:メニューへ"
    ]

drawFormFields :: MasterBook -> JournalFormState -> Widget Name
drawFormFields masters jf =
  let orgCode = edText (jfOrg jf)
      orgHint = fromMaybe "" (lookupOrgName masters orgCode)
  in B.vBox
       [ row "入力部門    " $
           renderTextEd (jfFocus jf == FFOrg) (jfOrg jf)
             `hcat` str " "
             `hcat` withAttr hintAttr (txt orgHint)
       , row "取引発生日  " $
           renderTextEd (jfFocus jf == FFDate) (jfDate jf)
             `hcat` withAttr hintAttr (str " (YYYY-MM-DD)")
       , row "仕訳行為区分" $
           drawCycleField (jfFocus jf == FFActionType) (showAction (jfAction jf))
       , row "リスク分類  " $
           drawCycleField (jfFocus jf == FFRiskTier) (showRisk (jfRisk jf))
       , row "証憑        " $
           drawCycleField (jfFocus jf == FFVoucherKind) (showVKind (jfVKind jf))
             `hcat` str "  番号: "
             `hcat` renderTextEd
               (jfFocus jf == FFVoucherRef && jfVKind jf == VKAttached)
               (jfVRef jf)
       , row "摘要        " $
           renderTextEd (jfFocus jf == FFMemo) (jfMemo jf)
       ]

drawJournalLines :: MasterBook -> JournalFormState -> Widget Name
drawJournalLines masters jf =
  B.vBox
    [ withAttr labelAttr (str " 仕訳行 (借方 / 貸方)")
    , drawLine
        masters
        1
        (jfFocus jf)
        FFL1Account
        FFL1DrCr
        FFL1Amount
        (jfL1Acc jf)
        (jfL1DrCr jf)
        (jfL1Amt jf)
    , drawLine
        masters
        2
        (jfFocus jf)
        FFL2Account
        FFL2DrCr
        FFL2Amount
        (jfL2Acc jf)
        (jfL2DrCr jf)
        (jfL2Amt jf)
    ]

drawLine ::
  MasterBook ->
  Int ->
  FormFocus ->
  FormFocus ->
  FormFocus ->
  FormFocus ->
  E.Editor Text Name ->
  DrCr ->
  E.Editor Text Name ->
  Widget Name
drawLine masters idx cur fAcc fDC fAmt accEd dc amtEd =
  let accText = edText accEd
      nameHint = lookupAccountName masters accText
  in B.hBox
       [ str (show idx <> ". 科目: ")
       , renderTextEd (cur == fAcc) accEd
       , str " "
       , withAttr hintAttr (txt (fromMaybe "　　　　　　　　" nameHint))
       , str "  "
       , drawCycleField (cur == fDC) (showDrCr dc)
       , str "  金額: "
       , renderTextEd (cur == fAmt) amtEd
       ]

lookupAccountName :: MasterBook -> Text -> Maybe Text
lookupAccountName masters code =
  case mkAccountCode code of
    Right ac -> fmap amName (Map.lookup ac (masterAccounts masters))
    Left _ -> Nothing

lookupOrgName :: MasterBook -> Text -> Maybe Text
lookupOrgName masters code =
  fmap orgName (Map.lookup (OrganisationId code) (masterOrgs masters))

drawTotals :: JournalFormState -> Widget Name
drawTotals jf =
  let dr =
        addMoney
          (parseMoney (jfL1Amt jf) (jfL1DrCr jf) Debit)
          (parseMoney (jfL2Amt jf) (jfL2DrCr jf) Debit)
      cr =
        addMoney
          (parseMoney (jfL1Amt jf) (jfL1DrCr jf) Credit)
          (parseMoney (jfL2Amt jf) (jfL2DrCr jf) Credit)
      balanced = dr == cr && dr /= zeroMoney
  in B.hBox
       [ str "借方合計: "
       , str (show (unMoney dr))
       , str "   貸方合計: "
       , str (show (unMoney cr))
       , str "   "
       , if balanced
           then withAttr activeAttr (str "[ 借貸一致 ]")
           else withAttr inactiveAttr (str "[ 確認中… ]")
       ]

drawButtons :: JournalFormState -> Widget Name
drawButtons jf =
  B.hBox
    [ drawBtn (jfFocus jf == FFSubmit) "  登録  "
    , str "   "
    , drawBtn (jfFocus jf == FFCancel) " キャンセル "
    ]

-- ── Event handling ────────────────────────────────────────────────────────────

handleFormEv :: BrickEvent Name () -> JournalFormState -> AppState -> EventM Name AppState ()
handleFormEv (VtyEvent (Vty.EvKey Vty.KEsc [])) _ st =
  B.put st{appScreen = ScreenMenu}
handleFormEv (VtyEvent (Vty.EvKey (Vty.KChar '\t') [])) jf st =
  B.put st{appScreen = ScreenJournalForm jf{jfFocus = nextJFocus (jfVKind jf) (jfFocus jf)}}
handleFormEv (VtyEvent (Vty.EvKey Vty.KBackTab [])) jf st =
  B.put st{appScreen = ScreenJournalForm jf{jfFocus = prevJFocus (jfVKind jf) (jfFocus jf)}}
handleFormEv ev jf st = handleFocusedField ev jf st

handleFocusedField ::
  BrickEvent Name () -> JournalFormState -> AppState -> EventM Name AppState ()
handleFocusedField ev jf st = case jfFocus jf of
  FFOrg -> do
    (newEd, ()) <- B.nestEventM (jfOrg jf) (E.handleEditorEvent ev)
    B.put st{appScreen = ScreenJournalForm jf{jfOrg = newEd}}
  FFDate -> do
    (newEd, ()) <- B.nestEventM (jfDate jf) (E.handleEditorEvent ev)
    B.put st{appScreen = ScreenJournalForm jf{jfDate = newEd}}
  FFVoucherRef -> do
    (newEd, ()) <- B.nestEventM (jfVRef jf) (E.handleEditorEvent ev)
    B.put st{appScreen = ScreenJournalForm jf{jfVRef = newEd}}
  FFMemo -> do
    (newEd, ()) <- B.nestEventM (jfMemo jf) (E.handleEditorEvent ev)
    B.put st{appScreen = ScreenJournalForm jf{jfMemo = newEd}}
  FFL1Account -> do
    (newEd, ()) <- B.nestEventM (jfL1Acc jf) (E.handleEditorEvent ev)
    B.put st{appScreen = ScreenJournalForm jf{jfL1Acc = newEd}}
  FFL1Amount -> do
    (newEd, ()) <- B.nestEventM (jfL1Amt jf) (E.handleEditorEvent ev)
    B.put st{appScreen = ScreenJournalForm jf{jfL1Amt = newEd}}
  FFL2Account -> do
    (newEd, ()) <- B.nestEventM (jfL2Acc jf) (E.handleEditorEvent ev)
    B.put st{appScreen = ScreenJournalForm jf{jfL2Acc = newEd}}
  FFL2Amount -> do
    (newEd, ()) <- B.nestEventM (jfL2Amt jf) (E.handleEditorEvent ev)
    B.put st{appScreen = ScreenJournalForm jf{jfL2Amt = newEd}}
  FFActionType -> handleCycle ev (\v -> jf{jfAction = v}) (jfAction jf) st
  FFRiskTier -> handleCycle ev (\v -> jf{jfRisk = v}) (jfRisk jf) st
  FFVoucherKind -> handleCycle ev (\v -> jf{jfVKind = v}) (jfVKind jf) st
  FFL1DrCr -> handleCycle ev (\v -> jf{jfL1DrCr = v}) (jfL1DrCr jf) st
  FFL2DrCr -> handleCycle ev (\v -> jf{jfL2DrCr = v}) (jfL2DrCr jf) st
  FFSubmit -> case ev of
    VtyEvent (Vty.EvKey Vty.KEnter []) -> handleSubmit jf st
    _ -> pure ()
  FFCancel -> case ev of
    VtyEvent (Vty.EvKey Vty.KEnter []) -> B.put st{appScreen = ScreenMenu}
    _ -> pure ()

handleCycle ::
  (Bounded a, Enum a, Eq a) =>
  BrickEvent Name () -> (a -> JournalFormState) -> a -> AppState -> EventM Name AppState ()
handleCycle (VtyEvent (Vty.EvKey Vty.KLeft [])) mk v st =
  B.put st{appScreen = ScreenJournalForm (mk (cycleL v))}
handleCycle (VtyEvent (Vty.EvKey Vty.KRight [])) mk v st =
  B.put st{appScreen = ScreenJournalForm (mk (cycleR v))}
handleCycle (VtyEvent (Vty.EvKey (Vty.KChar ' ') [])) mk v st =
  B.put st{appScreen = ScreenJournalForm (mk (cycleR v))}
handleCycle _ _ _ _ = pure ()

handleSubmit :: JournalFormState -> AppState -> EventM Name AppState ()
handleSubmit jf st = do
  result <- liftIO (submitJournalEntry (appStore st) jf)
  case result of
    Right () -> B.put st{appScreen = ScreenMenu}
    Left err -> B.put st{appScreen = ScreenJournalForm jf{jfError = Just err}}

-- ── Label helpers ─────────────────────────────────────────────────────────────

showAction :: JournalActionType -> String
showAction NewEntry = "新規起票"
showAction Cancellation = "取消"
showAction Reversal = "反対"
showAction Supplementary = "追加"
showAction Reclassification = "再分類"
showAction SwapRefresh = "洗替"
showAction EstimateChange = "見積変更"

showRisk :: RiskTier -> String
showRisk Low = "Low"
showRisk Medium = "Medium"
showRisk High = "High"
showRisk Critical = "Critical"

showVKind :: VoucherKind -> String
showVKind VKAttached = "証憑あり"
showVKind VKPending = "証憑未着"

showDrCr :: DrCr -> String
showDrCr Debit = "借方"
showDrCr Credit = "貸方"

parseMoney :: E.Editor Text Name -> DrCr -> DrCr -> M.Money
parseMoney ed dc target
  | dc /= target = zeroMoney
  | otherwise = case reads (T.unpack (edText ed)) of
      [(d, "")] -> M.mkMoney d
      _ -> zeroMoney

-- | Horizontal concatenation helper
hcat :: Widget n -> Widget n -> Widget n
hcat a b = B.hBox [a, b]
