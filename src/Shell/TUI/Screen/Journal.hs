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
import Brick.Widgets.Center qualified as BC
import Brick.Widgets.Edit qualified as E
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Graphics.Vty qualified as Vty

import Core.Domain.AccountCode (mkAccountCode, unAccountCode)
import Core.Domain.AccountMaster (AccountMaster (..), showAccountCategory)
import Core.Domain.Journal (DrCr (..), JournalActionType (..), RiskTier (..))
import Core.Domain.Money (addMoney, unMoney, zeroMoney)
import Core.Domain.Organisation (Organisation (..), OrganisationId (..))
import Core.State (MasterBook (..))
import Shell.ErrorCatalog (ErrorCatalog, renderAppError)
import Shell.TUI.Attrs
import Shell.TUI.Helpers
import Shell.TUI.Submit (dispatchJournalSubmit)
import Shell.TUI.Types

import Core.Domain.Money qualified as M

-- ── Draw ─────────────────────────────────────────────────────────────────────

-- | 仕訳フォームを描画する。モーダルが開いている場合は 2 レイヤーを返す。
drawJournalForm :: ErrorCatalog -> MasterBook -> JournalFormState -> [Widget Name]
drawJournalForm cat masters jf =
  let mainW = drawJournalMain cat masters jf
  in case jfModal jf of
       Nothing -> [mainW]
       Just ms -> [drawJournalModal ms, mainW]

drawJournalMain :: ErrorCatalog -> MasterBook -> JournalFormState -> Widget Name
drawJournalMain cat masters jf =
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
    , if jfLoading jf
        then withAttr hintAttr (str " 処理中...")
        else drawError (fmap (renderAppError cat) (jfError jf))
    , drawHint "Tab:次へ  Shift+Tab:前へ  Space:マスタ参照  ←/→:選択変更  Enter:確定  Esc:メニューへ"
    ]

drawFormFields :: MasterBook -> JournalFormState -> Widget Name
drawFormFields masters jf =
  let orgCode = edText (jfOrg jf)
      orgHint = fromMaybe "" (lookupOrgName masters orgCode)
  in B.vBox
       [ row "入力部門    " $
           B.hBox
             [ renderTextEd (jfFocus jf == FFOrg) (jfOrg jf)
             , withAttr hintAttr (str " [Space:参照] ")
             , withAttr hintAttr (txt orgHint)
             ]
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
  let nameHint = lookupAccountName masters (edText accEd)
  in B.hBox
       [ str (show idx <> ". 科目: ")
       , renderTextEd (cur == fAcc) accEd
       , withAttr hintAttr (str " [Sp] ")
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

-- ── Modal ─────────────────────────────────────────────────────────────────────

drawJournalModal :: ModalState -> Widget Name
drawJournalModal ms =
  BC.centerLayer $
    B.hLimit 62 $
      B.vLimit 22 $
        B.withBorderStyle BBS.unicodeRounded $
          BB.borderWithLabel (withAttr titleAttr (str (modalTitle (msKind ms)))) $
            B.padAll 1 $
              B.vBox
                [ if null (msItems ms)
                    then withAttr hintAttr (BC.hCenter (str "登録データなし"))
                    else B.vBox (zipWith (drawModalItem (msSelected ms)) [0 ..] (msItems ms))
                , BB.hBorder
                , withAttr hintAttr (str "↑/↓:移動  Enter:確定  Esc:閉じる")
                ]

modalTitle :: ModalKind -> String
modalTitle ModalOrg = " 入力部門を選択 "
modalTitle ModalAccount = " 勘定科目を選択 "

drawModalItem :: Int -> Int -> (Text, Text) -> Widget Name
drawModalItem selected idx (code, label) =
  let w = B.hBox [str " ", B.hLimit 14 (txt code), str "  ", txt label]
  in if idx == selected then withAttr focusedAttr w else w

-- ── Event handling ────────────────────────────────────────────────────────────

handleFormEv :: BrickEvent Name AppEvent -> JournalFormState -> AppState -> EventM Name AppState ()
handleFormEv ev jf st = case jfModal jf of
  Just ms -> handleModalEv ev ms jf st
  Nothing -> handleFormEvNormal ev jf st

handleFormEvNormal ::
  BrickEvent Name AppEvent -> JournalFormState -> AppState -> EventM Name AppState ()
handleFormEvNormal (VtyEvent (Vty.EvKey Vty.KEsc [])) _ st =
  B.put st{appScreen = ScreenMenu}
handleFormEvNormal (VtyEvent (Vty.EvKey (Vty.KChar '\t') [])) jf st =
  B.put st{appScreen = ScreenJournalForm jf{jfFocus = nextJFocus (jfVKind jf) (jfFocus jf)}}
handleFormEvNormal (VtyEvent (Vty.EvKey Vty.KBackTab [])) jf st =
  B.put st{appScreen = ScreenJournalForm jf{jfFocus = prevJFocus (jfVKind jf) (jfFocus jf)}}
handleFormEvNormal ev jf st = handleFocusedField ev jf st

-- | モーダルが開いているときのキー処理（他のすべてのキーを飲み込む）
handleModalEv ::
  BrickEvent Name AppEvent -> ModalState -> JournalFormState -> AppState -> EventM Name AppState ()
handleModalEv (VtyEvent (Vty.EvKey Vty.KEsc [])) _ jf st =
  B.put st{appScreen = ScreenJournalForm jf{jfModal = Nothing}}
handleModalEv (VtyEvent (Vty.EvKey Vty.KUp [])) ms jf st =
  B.put
    st{appScreen = ScreenJournalForm jf{jfModal = Just ms{msSelected = max 0 (msSelected ms - 1)}}}
handleModalEv (VtyEvent (Vty.EvKey Vty.KDown [])) ms jf st =
  let lastIdx = max 0 (length (msItems ms) - 1)
  in B.put
       st
         { appScreen =
             ScreenJournalForm jf{jfModal = Just ms{msSelected = min lastIdx (msSelected ms + 1)}}
         }
handleModalEv (VtyEvent (Vty.EvKey Vty.KEnter [])) ms jf st =
  case drop (msSelected ms) (msItems ms) of
    [] -> B.put st{appScreen = ScreenJournalForm jf{jfModal = Nothing}}
    ((code, _) : _) ->
      B.put st{appScreen = ScreenJournalForm (applyModalSelection ms code jf){jfModal = Nothing}}
handleModalEv _ _ _ _ = pure ()

applyModalSelection :: ModalState -> Text -> JournalFormState -> JournalFormState
applyModalSelection ms code jf = case msTarget ms of
  FFOrg -> jf{jfOrg = E.editor (NJournal JNOrg) (Just 1) code}
  FFL1Account -> jf{jfL1Acc = E.editor (NJournal JNL1Account) (Just 1) code}
  FFL2Account -> jf{jfL2Acc = E.editor (NJournal JNL2Account) (Just 1) code}
  _ -> jf

-- | マスタ参照フィールドの Space でモーダルを構築して開く
buildModal :: ModalKind -> FormFocus -> MasterBook -> ModalState
buildModal ModalOrg target mb =
  ModalState
    { msKind = ModalOrg
    , msTarget = target
    , msItems =
        [ (unOrgId (orgId org), orgName org)
        | org <- Map.elems (masterOrgs mb)
        , orgActive org
        ]
    , msSelected = 0
    }
buildModal ModalAccount target mb =
  ModalState
    { msKind = ModalAccount
    , msTarget = target
    , msItems =
        [ (unAccountCode (amCode am), amName am <> "  " <> showAccountCategory (amCategory am))
        | am <- Map.elems (masterAccounts mb)
        , amActive am
        ]
    , msSelected = 0
    }

handleFocusedField ::
  BrickEvent Name AppEvent -> JournalFormState -> AppState -> EventM Name AppState ()
handleFocusedField ev jf st = case jfFocus jf of
  FFOrg -> case ev of
    VtyEvent (Vty.EvKey (Vty.KChar ' ') []) ->
      B.put
        st
          { appScreen =
              ScreenJournalForm jf{jfModal = Just (buildModal ModalOrg FFOrg (appMasters st))}
          }
    _ -> do
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
  FFL1Account -> case ev of
    VtyEvent (Vty.EvKey (Vty.KChar ' ') []) ->
      B.put
        st
          { appScreen =
              ScreenJournalForm
                jf{jfModal = Just (buildModal ModalAccount FFL1Account (appMasters st))}
          }
    _ -> do
      (newEd, ()) <- B.nestEventM (jfL1Acc jf) (E.handleEditorEvent ev)
      B.put st{appScreen = ScreenJournalForm jf{jfL1Acc = newEd}}
  FFL1Amount -> do
    (newEd, ()) <- B.nestEventM (jfL1Amt jf) (E.handleEditorEvent ev)
    B.put st{appScreen = ScreenJournalForm jf{jfL1Amt = newEd}}
  FFL2Account -> case ev of
    VtyEvent (Vty.EvKey (Vty.KChar ' ') []) ->
      B.put
        st
          { appScreen =
              ScreenJournalForm
                jf{jfModal = Just (buildModal ModalAccount FFL2Account (appMasters st))}
          }
    _ -> do
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
  BrickEvent Name AppEvent ->
  (a -> JournalFormState) ->
  a ->
  AppState ->
  EventM Name AppState ()
handleCycle (VtyEvent (Vty.EvKey Vty.KLeft [])) mk v st =
  B.put st{appScreen = ScreenJournalForm (mk (cycleL v))}
handleCycle (VtyEvent (Vty.EvKey Vty.KRight [])) mk v st =
  B.put st{appScreen = ScreenJournalForm (mk (cycleR v))}
handleCycle (VtyEvent (Vty.EvKey (Vty.KChar ' ') [])) mk v st =
  B.put st{appScreen = ScreenJournalForm (mk (cycleR v))}
handleCycle _ _ _ _ = pure ()

handleSubmit :: JournalFormState -> AppState -> EventM Name AppState ()
handleSubmit jf st = do
  liftIO $ dispatchJournalSubmit (appChan st) (appStore st) jf
  B.put st{appScreen = ScreenJournalForm jf{jfLoading = True, jfError = Nothing}}

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
