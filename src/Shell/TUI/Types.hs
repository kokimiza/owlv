{- | All TUI-layer types: widget names, screen states, AppState.
Kept in one module so Screen/* can cross-reference without circular imports.
-}
module Shell.TUI.Types
  ( -- * Widget name hierarchy
    Name (..)
  , JName (..)
  , MName (..)
  , MasterKind (..)

    -- * Journal form
  , FormFocus (..)
  , nextJFocus
  , prevJFocus
  , VoucherKind (..)
  , JournalFormState (..)
  , initJournalForm

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

    -- * Top-level
  , Screen (..)
  , AppState (..)
  ) where

import Data.Text (Text)
import Data.Time (Day, defaultTimeLocale, formatTime)

import Brick.Widgets.Edit qualified as E
import Data.Map.Strict qualified as Map
import Data.Text qualified as T

import Core.Domain.AccountCode (unAccountCode)
import Core.Domain.AccountMaster
  ( AccountCategory (..)
  , AccountMaster (..)
  , defaultNormalBalance
  )
import Core.Domain.Journal (DrCr (..), JournalActionType (..), RiskTier (..))
import Core.Domain.Organisation (Organisation (..), OrganisationId (..))
import Core.Domain.Partner (Partner (..), PartnerId (..), PartnerType (..))
import Core.Domain.SubAccount (SubAccount (..), SubAccountId (..))
import Core.State (MasterBook (..))
import Shell.AppError (AppError)
import Shell.ErrorCatalog (ErrorCatalog)
import Shell.EventStore (EventStore)

-- ── Widget name hierarchy ────────────────────────────────────────────────────

data MasterKind = MKOrg | MKPartner | MKAccount | MKSubAccount
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

data Name
  = NJournal JName
  | NMaster MasterKind MName
  deriving (Eq, Ord, Show)

-- ── Journal form ─────────────────────────────────────────────────────────────

data VoucherKind = VKAttached | VKPending
  deriving (Bounded, Enum, Eq, Show)

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

-- ── Top-level screen + AppState ──────────────────────────────────────────────

data Screen
  = ScreenMenu
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

data AppState = AppState
  { appScreen :: Screen
  , appStore :: EventStore
  , appMasters :: MasterBook
  , appCatalog :: ErrorCatalog -- 起動時に一度だけロードする文言カタログ
  }

-- ── internal helpers ─────────────────────────────────────────────────────────

mEd :: MasterKind -> Int -> String -> E.Editor Text Name
mEd kind idx s = E.editor (NMaster kind (MNField idx)) (Just 1) (T.pack s)
