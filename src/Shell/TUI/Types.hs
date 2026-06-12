module Shell.TUI.Types
  ( Name (..)
  , FormFocus (..)
  , nextFocus
  , prevFocus
  , VoucherKind (..)
  , JournalFormState (..)
  , Screen (..)
  , AppState (..)
  , initJournalForm
  ) where

import qualified Brick.Widgets.Edit as E
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (Day, defaultTimeLocale, formatTime)
import Core.Domain.Journal (DrCr (..), JournalActionType (..), RiskTier (..))
import Shell.EventStore (EventStore)

-- ── Widget names ────────────────────────────────────────────────────────────

data Name
  = NDate
  | NVoucherRef
  | NMemo
  | NL1Account | NL1Amount
  | NL2Account | NL2Amount
  deriving (Eq, Ord, Show)

-- ── Focus order (Tab cycle) ─────────────────────────────────────────────────

data FormFocus
  = FFDate
  | FFActionType
  | FFRiskTier
  | FFVoucherKind
  | FFVoucherRef
  | FFMemo
  | FFL1Account | FFL1DrCr | FFL1Amount
  | FFL2Account | FFL2DrCr | FFL2Amount
  | FFSubmit
  | FFCancel
  deriving (Eq, Ord, Show, Enum, Bounded)

nextFocus :: VoucherKind -> FormFocus -> FormFocus
nextFocus vk f
  | f == FFVoucherKind && vk == VKPending = FFMemo   -- skip VRef when pending
  | f == maxBound                          = minBound
  | otherwise                              = succ f

prevFocus :: VoucherKind -> FormFocus -> FormFocus
prevFocus vk f
  | f == FFMemo && vk == VKPending = FFVoucherKind  -- skip VRef when pending
  | f == minBound                   = maxBound
  | otherwise                       = pred f

-- ── Voucher kind ────────────────────────────────────────────────────────────

data VoucherKind = VKAttached | VKPending
  deriving (Eq, Show, Enum, Bounded)

-- ── Journal form state ──────────────────────────────────────────────────────

data JournalFormState = JournalFormState
  { jfFocus    :: FormFocus
  , jfDate     :: E.Editor Text Name
  , jfAction   :: JournalActionType
  , jfRisk     :: RiskTier
  , jfVKind    :: VoucherKind
  , jfVRef     :: E.Editor Text Name
  , jfMemo     :: E.Editor Text Name
  , jfL1Acc    :: E.Editor Text Name
  , jfL1DrCr   :: DrCr
  , jfL1Amt    :: E.Editor Text Name
  , jfL2Acc    :: E.Editor Text Name
  , jfL2DrCr   :: DrCr
  , jfL2Amt    :: E.Editor Text Name
  , jfError    :: Maybe Text
  }

-- ── App screens ─────────────────────────────────────────────────────────────

data Screen
  = ScreenMenu
  | ScreenJournalForm JournalFormState

data AppState = AppState
  { appScreen :: Screen
  , appStore  :: EventStore
  }

-- ── Smart constructors ──────────────────────────────────────────────────────

initJournalForm :: Day -> JournalFormState
initJournalForm today =
  JournalFormState
    { jfFocus  = FFDate
    , jfDate   = ed NDate (formatTime defaultTimeLocale "%Y-%m-%d" today)
    , jfAction = NewEntry
    , jfRisk   = Low
    , jfVKind  = VKAttached
    , jfVRef   = ed NVoucherRef ""
    , jfMemo   = ed NMemo ""
    , jfL1Acc  = ed NL1Account ""
    , jfL1DrCr = Debit
    , jfL1Amt  = ed NL1Amount ""
    , jfL2Acc  = ed NL2Account ""
    , jfL2DrCr = Credit
    , jfL2Amt  = ed NL2Amount ""
    , jfError  = Nothing
    }
  where
    ed n initial = E.editor n (Just 1) (T.pack initial)
