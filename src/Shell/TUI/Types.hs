{- | All TUI-layer types: widget names, screen states, AppState.
Kept in one module so Screen/* can cross-reference without circular imports.
-}
module Shell.TUI.Types
  ( -- * Widget name hierarchy
    Name (..)
  , JName (..)
  , MName (..)
  , VName (..)
  , MasterKind (..)

    -- * Journal form
  , FormFocus (..)
  , nextJFocus
  , prevJFocus
  , VoucherKind (..)
  , ModalKind (..)
  , ModalState (..)
  , FieldInputMode (..)
  , jfInputMode
  , JournalFormState (..)
  , initJournalForm

    -- * Voucher search
  , VSFocus (..)
  , VoucherSearchState (..)
  , VoucherResultState (..)
  , initVoucherSearch
  , initVoucherResult

    -- * Organisation master
  , OrgFocus (..)
  , OrgFormState (..)
  , OrgListState (..)
  , initOrgForm
  , initOrgList

    -- * Partner master
  , PartnerFocus (..)
  , PartnerFormState (..)
  , PartnerListState (..)
  , initPartnerForm
  , initPartnerList

    -- * Account master
  , AccountFocus (..)
  , AccountFormState (..)
  , AccountListState (..)
  , initAccountForm
  , initAccountList

    -- * SubAccount master
  , SubAccFocus (..)
  , SubAccFormState (..)
  , SubAccListState (..)
  , initSubAccForm
  , initSubAccList

    -- * User master (.claude/user.md)
  , UserFocus (..)
  , UserFormState (..)
  , UserListState (..)
  , UserKeyFormState (..)
  , initUserForm
  , initUserList
  , initUserKeyForm

    -- * Top-level
  , AppEvent (..)
  , Screen (..)
  , AppState (..)
  ) where

import Brick.BChan (BChan)
import Data.Text (Text)
import Data.Time (Day, defaultTimeLocale, formatTime)

import Brick.Widgets.Edit qualified as E
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Database.PostgreSQL.Simple qualified as PG

import Core.Domain.AccountCode (unAccountCode)
import Core.Domain.AccountMaster
  ( AccountCategory (..)
  , AccountMaster (..)
  , SettlementBehavior (..)
  , defaultNormalBalance
  )
import Core.Domain.Journal (DrCr (..), JournalActionType (..), JournalEntry, RiskTier (..))
import Core.Domain.Organisation (Organisation (..), OrganisationId (..))
import Core.Domain.Partner (Partner (..), PartnerId (..), PartnerType (..))
import Core.Domain.SubAccount (SubAccount (..), SubAccountId (..))
import Core.Domain.User (Role (..), User (..), UserId)
import Core.Event (Event)
import Core.State (MasterBook (..), UserBook (..))
import Shell.AppError (AppError)
import Shell.ErrorCatalog (ErrorCatalog)
import Shell.EventStore (EventStore)

-- ── Widget name hierarchy ────────────────────────────────────────────────────

data MasterKind = MKOrg | MKPartner | MKAccount | MKSubAccount | MKUser
  deriving (Eq, Ord, Show)

newtype MName = MNField Int
  deriving (Eq, Ord, Show)

data JName
  = JNOrg
  | JNDate
  | JNVoucherRef
  | JNMemo
  | JNL1Account
  | JNL1Amount
  | JNL2Account
  | JNL2Amount
  deriving (Eq, Ord, Show)

data VName = VNDateFrom | VNDateTo | VNOrg | VNMemo
  deriving (Eq, Ord, Show)

data Name
  = NJournal JName
  | NMaster MasterKind MName
  | NVoucher VName
  deriving (Eq, Ord, Show)

-- ── Journal form ─────────────────────────────────────────────────────────────

data VoucherKind = VKAttached | VKPending
  deriving (Bounded, Enum, Eq, Show)

-- | どのマスタ参照モーダルを開くか
data ModalKind = ModalOrg | ModalAccount
  deriving (Eq, Show)

-- | フローティングリスト（マスタ参照モーダル）の状態
data ModalState = ModalState
  { msKind :: ModalKind
  , msTarget :: FormFocus -- 確定時に書き込むフィールド
  , msItems :: [(Text, Text)] -- (コード, 表示名)
  , msSelected :: Int
  }
  deriving (Eq, Show)

-- | フィールドごとの入力モード（あらかじめ定義）
data FieldInputMode
  = FreeInput -- テキスト自由入力
  | MasterRef ModalKind -- Space でマスタ参照モーダルを起動
  | CycleField -- ←/→ で択一サイクル

-- | 仕訳フォーム各フィールドの入力モード定義
jfInputMode :: FormFocus -> FieldInputMode
jfInputMode FFOrg = MasterRef ModalOrg
jfInputMode FFL1Account = MasterRef ModalAccount
jfInputMode FFL2Account = MasterRef ModalAccount
jfInputMode FFActionType = CycleField
jfInputMode FFRiskTier = CycleField
jfInputMode FFVoucherKind = CycleField
jfInputMode FFL1DrCr = CycleField
jfInputMode FFL2DrCr = CycleField
jfInputMode _ = FreeInput

data FormFocus
  = FFOrg
  | FFDate
  | FFActionType
  | FFRiskTier
  | FFVoucherKind
  | FFVoucherRef
  | FFMemo
  | FFL1Account
  | FFL1DrCr
  | FFL1Amount
  | FFL2Account
  | FFL2DrCr
  | FFL2Amount
  | FFSubmit
  | FFCancel
  deriving (Bounded, Enum, Eq, Ord, Show)

nextJFocus :: VoucherKind -> FormFocus -> FormFocus
nextJFocus vk f
  | f == FFVoucherKind && vk == VKPending = FFMemo
  | f == maxBound = minBound
  | otherwise = succ f

prevJFocus :: VoucherKind -> FormFocus -> FormFocus
prevJFocus vk f
  | f == FFMemo && vk == VKPending = FFVoucherKind
  | f == minBound = maxBound
  | otherwise = pred f

data JournalFormState = JournalFormState
  { jfFocus :: FormFocus
  , jfOrg :: E.Editor Text Name -- 入力部門コード
  , jfDate :: E.Editor Text Name
  , jfAction :: JournalActionType
  , jfRisk :: RiskTier
  , jfVKind :: VoucherKind
  , jfVRef :: E.Editor Text Name
  , jfMemo :: E.Editor Text Name
  , jfL1Acc :: E.Editor Text Name
  , jfL1DrCr :: DrCr
  , jfL1Amt :: E.Editor Text Name
  , jfL2Acc :: E.Editor Text Name
  , jfL2DrCr :: DrCr
  , jfL2Amt :: E.Editor Text Name
  , jfError :: Maybe AppError
  , jfModal :: Maybe ModalState -- フローティングリスト（Nothing = 非表示）
  , jfLoading :: Bool -- True while async command is in flight
  }

initJournalForm :: Day -> JournalFormState
initJournalForm today =
  JournalFormState
    { jfFocus = FFOrg
    , jfOrg = ed (NJournal JNOrg) ""
    , jfDate = ed (NJournal JNDate) (formatTime defaultTimeLocale "%Y-%m-%d" today)
    , jfAction = NewEntry
    , jfRisk = Low
    , jfVKind = VKAttached
    , jfVRef = ed (NJournal JNVoucherRef) ""
    , jfMemo = ed (NJournal JNMemo) ""
    , jfL1Acc = ed (NJournal JNL1Account) ""
    , jfL1DrCr = Debit
    , jfL1Amt = ed (NJournal JNL1Amount) ""
    , jfL2Acc = ed (NJournal JNL2Account) ""
    , jfL2DrCr = Credit
    , jfL2Amt = ed (NJournal JNL2Amount) ""
    , jfError = Nothing
    , jfModal = Nothing
    , jfLoading = False
    }
 where
  ed n s = E.editor n (Just 1) (T.pack s)

-- ── Organisation master ──────────────────────────────────────────────────────

data OrgFocus = OFCode | OFName | OFParent | OFActive | OFSubmit | OFCancel
  deriving (Bounded, Enum, Eq, Ord, Show)

data OrgFormState = OrgFormState
  { ofFocus :: OrgFocus
  , ofCode :: E.Editor Text Name
  , ofName :: E.Editor Text Name
  , ofParent :: E.Editor Text Name -- 上位部署コード（空欄=なし）
  , ofActive :: Bool
  , ofError :: Maybe AppError
  , ofIsNew :: Bool
  }

initOrgForm :: Maybe Organisation -> OrgFormState
initOrgForm Nothing =
  OrgFormState
    { ofFocus = OFCode
    , ofCode = mEd MKOrg 0 ""
    , ofName = mEd MKOrg 1 ""
    , ofParent = mEd MKOrg 2 ""
    , ofActive = True
    , ofError = Nothing
    , ofIsNew = True
    }
initOrgForm (Just org) =
  OrgFormState
    { ofFocus = OFName
    , ofCode = mEd MKOrg 0 (T.unpack (unOrgId (orgId org)))
    , ofName = mEd MKOrg 1 (T.unpack (orgName org))
    , ofParent = mEd MKOrg 2 (maybe "" (T.unpack . unOrgId) (orgParent org))
    , ofActive = orgActive org
    , ofError = Nothing
    , ofIsNew = False
    }

data OrgListState = OrgListState
  { olOrgs :: [Organisation]
  , olSelected :: Int
  }

initOrgList :: MasterBook -> OrgListState
initOrgList mb =
  OrgListState
    { olOrgs = map snd (Map.toAscList (masterOrgs mb))
    , olSelected = 0
    }

-- ── Partner master ───────────────────────────────────────────────────────────

data PartnerFocus = PFCode | PFName | PFType | PFActive | PFSubmit | PFCancel
  deriving (Bounded, Enum, Eq, Ord, Show)

data PartnerFormState = PartnerFormState
  { pfFocus :: PartnerFocus
  , pfCode :: E.Editor Text Name
  , pfName :: E.Editor Text Name
  , pfType :: PartnerType
  , pfActive :: Bool
  , pfError :: Maybe AppError
  , pfIsNew :: Bool
  }

initPartnerForm :: Maybe Partner -> PartnerFormState
initPartnerForm Nothing =
  PartnerFormState
    { pfFocus = PFCode
    , pfCode = mEd MKPartner 0 ""
    , pfName = mEd MKPartner 1 ""
    , pfType = Customer
    , pfActive = True
    , pfError = Nothing
    , pfIsNew = True
    }
initPartnerForm (Just p) =
  PartnerFormState
    { pfFocus = PFName
    , pfCode = mEd MKPartner 0 (T.unpack (unPartnerId (partnerId p)))
    , pfName = mEd MKPartner 1 (T.unpack (partnerName p))
    , pfType = partnerType p
    , pfActive = partnerActive p
    , pfError = Nothing
    , pfIsNew = False
    }

data PartnerListState = PartnerListState
  { plPartners :: [Partner]
  , plSelected :: Int
  }

initPartnerList :: MasterBook -> PartnerListState
initPartnerList mb =
  PartnerListState
    { plPartners = map snd (Map.toAscList (masterPartners mb))
    , plSelected = 0
    }

-- ── Account master ───────────────────────────────────────────────────────────

data AccountFocus
  = AFFCode
  | AFFName
  | AFFCategory
  | AFFNormalBal
  | AFFActive
  | AFFSubmit
  | AFFCancel
  deriving (Bounded, Enum, Eq, Ord, Show)

data AccountFormState = AccountFormState
  { affFocus :: AccountFocus
  , affCode :: E.Editor Text Name
  , affName :: E.Editor Text Name
  , affCategory :: AccountCategory
  , affNormalBal :: DrCr
  , affSettlement :: SettlementBehavior
  , affActive :: Bool
  , affError :: Maybe AppError
  , affIsNew :: Bool
  }

initAccountForm :: Maybe AccountMaster -> AccountFormState
initAccountForm Nothing =
  AccountFormState
    { affFocus = AFFCode
    , affCode = mEd MKAccount 0 ""
    , affName = mEd MKAccount 1 ""
    , affCategory = Asset
    , affNormalBal = defaultNormalBalance Asset
    , affSettlement = SelfContained
    , affActive = True
    , affError = Nothing
    , affIsNew = True
    }
initAccountForm (Just am) =
  AccountFormState
    { affFocus = AFFName
    , affCode = mEd MKAccount 0 (T.unpack (unAccountCode (amCode am)))
    , affName = mEd MKAccount 1 (T.unpack (amName am))
    , affCategory = amCategory am
    , affNormalBal = amNormalBalance am
    , affSettlement = amSettlement am
    , affActive = amActive am
    , affError = Nothing
    , affIsNew = False
    }

data AccountListState = AccountListState
  { alAccounts :: [AccountMaster]
  , alSelected :: Int
  }

initAccountList :: MasterBook -> AccountListState
initAccountList mb =
  AccountListState
    { alAccounts = map snd (Map.toAscList (masterAccounts mb))
    , alSelected = 0
    }

-- ── Voucher search ───────────────────────────────────────────────────────────

data VSFocus
  = VSFDateFrom
  | VSFDateTo
  | VSFOrg
  | VSFMemo
  | VSFSearch
  | VSFCancel
  deriving (Bounded, Enum, Eq, Ord, Show)

data VoucherSearchState = VoucherSearchState
  { vsDateFrom :: E.Editor Text Name -- 開始日 (空 = 上限なし)
  , vsDateTo :: E.Editor Text Name -- 終了日 (空 = 上限なし)
  , vsOrg :: E.Editor Text Name -- 入力部門コード (空 = 全部門)
  , vsMemo :: E.Editor Text Name -- 摘要キーワード (空 = 全件)
  , vsFocus :: VSFocus
  , vsError :: Maybe AppError
  }

data VoucherResultState = VoucherResultState
  { vrEntries :: [JournalEntry] -- 日付降順ソート済み
  , vrSelected :: Int
  }

initVoucherSearch :: VoucherSearchState
initVoucherSearch =
  VoucherSearchState
    { vsDateFrom = E.editor (NVoucher VNDateFrom) (Just 1) ""
    , vsDateTo = E.editor (NVoucher VNDateTo) (Just 1) ""
    , vsOrg = E.editor (NVoucher VNOrg) (Just 1) ""
    , vsMemo = E.editor (NVoucher VNMemo) (Just 1) ""
    , vsFocus = VSFDateFrom
    , vsError = Nothing
    }

initVoucherResult :: [JournalEntry] -> VoucherResultState
initVoucherResult entries = VoucherResultState{vrEntries = entries, vrSelected = 0}

-- ── SubAccount master ────────────────────────────────────────────────────────

data SubAccFocus = SAFCode | SAFName | SAFParent | SAFActive | SAFSubmit | SAFCancel
  deriving (Bounded, Enum, Eq, Ord, Show)

data SubAccFormState = SubAccFormState
  { safFocus :: SubAccFocus
  , safCode :: E.Editor Text Name
  , safName :: E.Editor Text Name
  , safParent :: E.Editor Text Name
  , safActive :: Bool
  , safError :: Maybe AppError
  , safIsNew :: Bool
  }

initSubAccForm :: Maybe SubAccount -> SubAccFormState
initSubAccForm Nothing =
  SubAccFormState
    { safFocus = SAFCode
    , safCode = mEd MKSubAccount 0 ""
    , safName = mEd MKSubAccount 1 ""
    , safParent = mEd MKSubAccount 2 ""
    , safActive = True
    , safError = Nothing
    , safIsNew = True
    }
initSubAccForm (Just sa) =
  SubAccFormState
    { safFocus = SAFName
    , safCode = mEd MKSubAccount 0 (T.unpack (unSubAccountId (saId sa)))
    , safName = mEd MKSubAccount 1 (T.unpack (saName sa))
    , safParent = mEd MKSubAccount 2 (T.unpack (unAccountCode (saParent sa)))
    , safActive = saActive sa
    , safError = Nothing
    , safIsNew = False
    }

data SubAccListState = SubAccListState
  { slSubAccounts :: [SubAccount]
  , slSelected :: Int
  }

initSubAccList :: MasterBook -> SubAccListState
initSubAccList mb =
  SubAccListState
    { slSubAccounts = map snd (Map.toAscList (masterSubAccounts mb))
    , slSelected = 0
    }

-- ── User master (.claude/user.md) ───────────────────────────────────────────

data UserFocus = UFUsername | UFDisplayName | UFRole | UFSubmit | UFCancel
  deriving (Bounded, Enum, Eq, Ord, Show)

-- | 新規作成のみ（UserId は不変のため編集不可、.claude/user.md §2.1）。
data UserFormState = UserFormState
  { ufFocus :: UserFocus
  , ufUsername :: E.Editor Text Name
  , ufDisplayName :: E.Editor Text Name
  , ufRole :: Role
  , ufError :: Maybe AppError
  }

initUserForm :: UserFormState
initUserForm =
  UserFormState
    { ufFocus = UFUsername
    , ufUsername = mEd MKUser 0 ""
    , ufDisplayName = mEd MKUser 1 ""
    , ufRole = Operator
    , ufError = Nothing
    }

data UserListState = UserListState
  { ulUsers :: [User]
  , ulSelected :: Int
  , ulError :: Maybe AppError
  }

initUserList :: UserBook -> UserListState
initUserList ub =
  UserListState
    { ulUsers = map snd (Map.toAscList (users ub))
    , ulSelected = 0
    , ulError = Nothing
    }

-- | 選択中ユーザーへの SSH 公開鍵追加フォーム（単一フィールド）。
newtype UserKeyFormState = UserKeyFormState
  { ukfKey :: E.Editor Text Name
  }

initUserKeyForm :: UserKeyFormState
initUserKeyForm = UserKeyFormState{ukfKey = mEd MKUser 2 ""}

-- ── Async app events ─────────────────────────────────────────────────────────

-- | Events produced by worker threads and delivered to brick via BChan.
data AppEvent
  = CommandFinished (Either AppError [Event])
  | MastersLoaded (Either AppError MasterBook)

-- ── Top-level screen + AppState ──────────────────────────────────────────────

data Screen
  = ScreenLoading
  | ScreenMenu
  | ScreenMasterMenu
  | ScreenJournalForm JournalFormState
  | ScreenOrgList OrgListState
  | ScreenOrgForm OrgFormState
  | ScreenPartnerList PartnerListState
  | ScreenPartnerForm PartnerFormState
  | ScreenAccountList AccountListState
  | ScreenAccountForm AccountFormState
  | ScreenSubAccList SubAccListState
  | ScreenSubAccForm SubAccFormState
  | ScreenUserList UserListState
  | ScreenUserForm UserFormState
  | ScreenUserKeyForm User UserKeyFormState
  | ScreenVoucherSearch VoucherSearchState
  | ScreenVoucherResult VoucherResultState
  | ScreenVoucherDetail JournalEntry VoucherResultState

data AppState = AppState
  { appScreen :: Screen
  , appStore :: EventStore -- synchronous handlers (master CRUD)
  , appConn :: PG.Connection -- effectful interpreters
  , appChan :: BChan AppEvent -- worker → brick event channel
  , appMasters :: MasterBook
  , appCatalog :: ErrorCatalog
  , appCurrentUser :: UserId -- .claude/user.md §4.1: SSH 確立時に解決済みの actor
  , appCurrentRole :: Role -- ユーザー管理画面の表示制御（Admin のみ）に使う
  }

-- ── internal helpers ─────────────────────────────────────────────────────────

mEd :: MasterKind -> Int -> String -> E.Editor Text Name
mEd kind idx s = E.editor (NMaster kind (MNField idx)) (Just 1) (T.pack s)
