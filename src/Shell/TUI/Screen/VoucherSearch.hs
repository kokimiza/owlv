-- | 伝票検索画面（検索フォーム / 結果一覧 / 詳細）
module Shell.TUI.Screen.VoucherSearch
  ( drawVoucherSearch
  , handleVoucherSearchEv
  , drawVoucherResult
  , handleVoucherResultEv
  , drawVoucherDetail
  , handleVoucherDetailEv
  ) where

import Brick (BrickEvent (..), EventM, Widget, str, txt, withAttr)
import Control.Monad.IO.Class (liftIO)
import Data.List (sortBy)
import Data.List.NonEmpty (toList)
import Data.Maybe (fromMaybe)
import Data.Ord (Down (..), comparing)
import Data.Text (Text)
import Data.Time (Day)
import Data.Time.Format (defaultTimeLocale, formatTime, parseTimeM)

import Brick qualified as B
import Brick.Widgets.Border qualified as BB
import Brick.Widgets.Border.Style qualified as BBS
import Brick.Widgets.Center qualified as BC
import Brick.Widgets.Edit qualified as E
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.UUID qualified as UUID
import Graphics.Vty qualified as Vty

import Core.Domain.AccountCode (unAccountCode)
import Core.Domain.AccountMaster (AccountMaster (..), showAccountCategory)
import Core.Domain.Journal
  ( DrCr (..)
  , JournalActionType (..)
  , JournalEntry (..)
  , JournalEntryId (..)
  , JournalLine (..)
  , RiskTier (..)
  , VoucherRef (..)
  , creditTotal
  , debitTotal
  )
import Core.Domain.Money (unMoney)
import Core.Domain.Organisation (Organisation (..), OrganisationId (..))
import Core.State (JournalBook (..), MasterBook (..))
import Shell.AppError (AppError (..))
import Shell.CommandExecutor (loadJournalBook)
import Shell.ErrorCatalog (ErrorCatalog, renderAppError)
import Shell.TUI.Attrs
import Shell.TUI.Helpers
import Shell.TUI.Types

-- ── Search form ───────────────────────────────────────────────────────────────

drawVoucherSearch :: ErrorCatalog -> VoucherSearchState -> Widget Name
drawVoucherSearch cat vs =
  BC.center $
    B.hLimit 72 $
      B.vBox
        [ B.withBorderStyle BBS.unicodeBold $
            BB.borderWithLabel (withAttr titleAttr (str " 伝票検索 ")) $
              B.padAll 1 $
                B.vBox
                  [ row "開始日    " $
                      renderTextEd (vsFocus vs == VSFDateFrom) (vsDateFrom vs)
                        `hcat` withAttr hintAttr (str "  (YYYY-MM-DD, 空=全期間)")
                  , row "終了日    " $
                      renderTextEd (vsFocus vs == VSFDateTo) (vsDateTo vs)
                        `hcat` withAttr hintAttr (str "  (YYYY-MM-DD, 空=上限なし)")
                  , row "入力部門  " $
                      renderTextEd (vsFocus vs == VSFOrg) (vsOrg vs)
                        `hcat` withAttr hintAttr (str "  (空=全部門)")
                  , row "摘要KW    " $
                      renderTextEd (vsFocus vs == VSFMemo) (vsMemo vs)
                        `hcat` withAttr hintAttr (str "  (部分一致, 空=全件)")
                  , BB.hBorder
                  , B.hBox
                      [ drawBtn (vsFocus vs == VSFSearch) "  検索  "
                      , str "   "
                      , drawBtn (vsFocus vs == VSFCancel) " キャンセル "
                      ]
                  ]
        , drawError (fmap (renderAppError cat) (vsError vs))
        , drawHint "Tab:次へ  Shift+Tab:前へ  Enter:実行  Esc:メニューへ"
        ]

handleVoucherSearchEv ::
  BrickEvent Name AppEvent -> VoucherSearchState -> AppState -> EventM Name AppState ()
handleVoucherSearchEv (VtyEvent (Vty.EvKey Vty.KEsc [])) _ st =
  B.put st{appScreen = ScreenMenu}
handleVoucherSearchEv (VtyEvent (Vty.EvKey (Vty.KChar '\t') [])) vs st =
  B.put st{appScreen = ScreenVoucherSearch vs{vsFocus = cycleR (vsFocus vs)}}
handleVoucherSearchEv (VtyEvent (Vty.EvKey Vty.KBackTab [])) vs st =
  B.put st{appScreen = ScreenVoucherSearch vs{vsFocus = cycleL (vsFocus vs)}}
handleVoucherSearchEv ev vs st = case vsFocus vs of
  VSFDateFrom -> do
    (ed, ()) <- B.nestEventM (vsDateFrom vs) (E.handleEditorEvent ev)
    B.put st{appScreen = ScreenVoucherSearch vs{vsDateFrom = ed}}
  VSFDateTo -> do
    (ed, ()) <- B.nestEventM (vsDateTo vs) (E.handleEditorEvent ev)
    B.put st{appScreen = ScreenVoucherSearch vs{vsDateTo = ed}}
  VSFOrg -> do
    (ed, ()) <- B.nestEventM (vsOrg vs) (E.handleEditorEvent ev)
    B.put st{appScreen = ScreenVoucherSearch vs{vsOrg = ed}}
  VSFMemo -> do
    (ed, ()) <- B.nestEventM (vsMemo vs) (E.handleEditorEvent ev)
    B.put st{appScreen = ScreenVoucherSearch vs{vsMemo = ed}}
  VSFSearch -> case ev of
    VtyEvent (Vty.EvKey Vty.KEnter []) -> executeSearch vs st
    _ -> pure ()
  VSFCancel -> case ev of
    VtyEvent (Vty.EvKey Vty.KEnter []) -> B.put st{appScreen = ScreenMenu}
    _ -> pure ()

executeSearch :: VoucherSearchState -> AppState -> EventM Name AppState ()
executeSearch vs st = do
  jbResult <- liftIO (loadJournalBook (appStore st))
  case jbResult of
    Left err -> B.put st{appScreen = ScreenVoucherSearch vs{vsError = Just err}}
    Right jb ->
      case runSearch
        (edText (vsDateFrom vs))
        (edText (vsDateTo vs))
        (edText (vsOrg vs))
        (edText (vsMemo vs))
        jb of
        Left err -> B.put st{appScreen = ScreenVoucherSearch vs{vsError = Just err}}
        Right entries ->
          let sorted = sortBy (comparing (Down . entryDate)) entries
          in B.put st{appScreen = ScreenVoucherResult (initVoucherResult sorted)}

runSearch :: Text -> Text -> Text -> Text -> JournalBook -> Either AppError [JournalEntry]
runSearch dateFromT dateToT orgT memoT jb = do
  mFrom <- parseOptDay dateFromT
  mTo <- parseOptDay dateToT
  let mOrg = if T.null (T.strip orgT) then Nothing else Just (OrganisationId (T.strip orgT))
      mKw = if T.null (T.strip memoT) then Nothing else Just (T.toCaseFold (T.strip memoT))
  Right (filter (matchEntry mFrom mTo mOrg mKw) (Map.elems (journalEntries jb)))

parseOptDay :: Text -> Either AppError (Maybe Day)
parseOptDay t
  | T.null (T.strip t) = Right Nothing
  | otherwise =
      case parseTimeM True defaultTimeLocale "%Y-%m-%d" (T.unpack (T.strip t)) of
        Just d -> Right (Just d)
        Nothing ->
          Left (AppInputError ("日付形式エラー: " <> T.strip t <> "  (YYYY-MM-DD で入力)"))

matchEntry ::
  Maybe Day -> Maybe Day -> Maybe OrganisationId -> Maybe Text -> JournalEntry -> Bool
matchEntry mFrom mTo mOrg mKw e =
  maybe True (\d -> entryDate e >= d) mFrom
    && maybe True (\d -> entryDate e <= d) mTo
    && maybe True (\o -> entryOrg e == o) mOrg
    && maybe True (\kw -> kw `T.isInfixOf` T.toCaseFold (entryMemo e)) mKw

-- ── Result list ───────────────────────────────────────────────────────────────

drawVoucherResult :: MasterBook -> VoucherResultState -> Widget Name
drawVoucherResult mb vr =
  B.vBox
    [ B.withBorderStyle BBS.unicodeBold
        $ BB.borderWithLabel
          (withAttr titleAttr (str (" 検索結果  " <> show (length (vrEntries vr)) <> " 件 ")))
        $ B.padLeftRight 1
        $ B.vBox
          [ withAttr
              labelAttr
              (str " 日付         入力部門        行為区分    摘要                借方合計")
          , BB.hBorder
          , if null (vrEntries vr)
              then withAttr hintAttr (BC.hCenter (str "該当する仕訳がありません"))
              else B.vBox (zipWith (drawResultRow mb (vrSelected vr)) [0 ..] (vrEntries vr))
          ]
    , drawHint "↑/↓:移動  Enter:詳細  Esc:検索へ戻る"
    ]

drawResultRow :: MasterBook -> Int -> Int -> JournalEntry -> Widget Name
drawResultRow mb selected idx e =
  let dateW = str (formatTime defaultTimeLocale "%Y-%m-%d" (entryDate e))
      orgW = B.hLimit 16 (txt (resolveOrg mb (entryOrg e)))
      actW = B.hLimit 12 (str (showAction (entryActionType e)))
      memoW = B.hLimit 20 (txt (entryMemo e))
      amtW = str (show (unMoney (debitTotal (entryLines e))))
      row_ = B.hBox [str " ", dateW, str "  ", orgW, str "  ", actW, str "  ", memoW, str "  ", amtW]
  in if idx == selected then withAttr focusedAttr row_ else row_

handleVoucherResultEv ::
  BrickEvent Name AppEvent -> VoucherResultState -> AppState -> EventM Name AppState ()
handleVoucherResultEv (VtyEvent (Vty.EvKey Vty.KEsc [])) _ st =
  B.put st{appScreen = ScreenVoucherSearch initVoucherSearch}
handleVoucherResultEv (VtyEvent (Vty.EvKey Vty.KUp [])) vr st =
  B.put st{appScreen = ScreenVoucherResult vr{vrSelected = max 0 (vrSelected vr - 1)}}
handleVoucherResultEv (VtyEvent (Vty.EvKey Vty.KDown [])) vr st =
  let lastIdx = max 0 (length (vrEntries vr) - 1)
  in B.put st{appScreen = ScreenVoucherResult vr{vrSelected = min lastIdx (vrSelected vr + 1)}}
handleVoucherResultEv (VtyEvent (Vty.EvKey Vty.KEnter [])) vr st =
  case drop (vrSelected vr) (vrEntries vr) of
    [] -> pure ()
    (e : _) -> B.put st{appScreen = ScreenVoucherDetail e vr}
handleVoucherResultEv _ _ _ = pure ()

-- ── Detail view ───────────────────────────────────────────────────────────────

drawVoucherDetail :: MasterBook -> JournalEntry -> Widget Name
drawVoucherDetail mb e =
  B.vBox
    [ B.withBorderStyle BBS.unicodeBold $
        BB.borderWithLabel (withAttr titleAttr (str " 仕訳詳細 ")) $
          B.padAll 1 $
            B.vBox
              [ row "伝票 ID   " (str (shortId (entryId e)))
              , row "日付      " (str (formatTime defaultTimeLocale "%Y-%m-%d" (entryDate e)))
              , row "入力部門  " (txt (resolveOrg mb (entryOrg e)))
              , row "行為区分  " (str (showAction (entryActionType e)))
              , row "リスク    " (str (showRisk (entryRiskTier e)))
              , row "証憑      " (str (showVoucherRef (entryVoucher e)))
              , row "摘要      " (txt (entryMemo e))
              , BB.hBorder
              , withAttr labelAttr (str "仕訳明細")
              , B.vBox (zipWith (drawDetailLine mb) [1 ..] (toList (entryLines e)))
              , BB.hBorder
              , B.hBox
                  [ str "借方合計: "
                  , str (show (unMoney (debitTotal (entryLines e))))
                  , str "   貸方合計: "
                  , str (show (unMoney (creditTotal (entryLines e))))
                  ]
              ]
    , drawHint "Esc:一覧へ戻る"
    ]

drawDetailLine :: MasterBook -> Int -> JournalLine -> Widget Name
drawDetailLine mb idx ln =
  let code = unAccountCode (lineAccount ln)
      mAm = Map.lookup (lineAccount ln) (masterAccounts mb)
      name = maybe "" amName mAm
      cat = maybe "" (showAccountCategory . amCategory) mAm
      acW = B.hLimit 28 (txt (code <> "  " <> name <> "  " <> cat))
      dcW = B.hLimit 6 (str (showDrCr (lineDrCr ln)))
      amtW = str (show (unMoney (lineAmount ln)))
  in B.hBox [str (" " <> show idx <> ".  "), acW, str "  ", dcW, str "  ", amtW]

handleVoucherDetailEv ::
  BrickEvent Name AppEvent ->
  JournalEntry ->
  VoucherResultState ->
  AppState ->
  EventM Name AppState ()
handleVoucherDetailEv (VtyEvent (Vty.EvKey Vty.KEsc [])) _ vr st =
  B.put st{appScreen = ScreenVoucherResult vr}
handleVoucherDetailEv _ _ _ _ = pure ()

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

showDrCr :: DrCr -> String
showDrCr Debit = "借方"
showDrCr Credit = "貸方"

showVoucherRef :: VoucherRef -> String
showVoucherRef (VoucherAttached r) = T.unpack r
showVoucherRef VoucherPending = "証憑未着"

shortId :: JournalEntryId -> String
shortId (JournalEntryId uuid) = UUID.toString uuid

resolveOrg :: MasterBook -> OrganisationId -> Text
resolveOrg mb oid =
  fromMaybe (unOrgId oid) (fmap orgName (Map.lookup oid (masterOrgs mb)))

hcat :: Widget n -> Widget n -> Widget n
hcat a b = B.hBox [a, b]
