module Core.State
  ( JournalBook (..)
  , initialJournalBook
  , MasterBook (..)
  , initialMasterBook
  , AppBook (..)
  , initialAppBook
  ) where

import Data.Map.Strict (Map)
import Data.Set (Set)

import Data.Map.Strict qualified as Map

import Core.Domain.AccountCode (AccountCode)
import Core.Domain.AccountMaster (AccountMaster)
import Core.Domain.Journal (JournalEntry, JournalEntryId)
import Core.Domain.OrgPermission (PermScope)
import Core.Domain.Organisation (Organisation, OrganisationId)
import Core.Domain.Partner (Partner, PartnerId)
import Core.Domain.SubAccount (SubAccount, SubAccountId)

newtype JournalBook = JournalBook
  { journalEntries :: Map JournalEntryId JournalEntry
  }
  deriving (Eq, Show)

initialJournalBook :: JournalBook
initialJournalBook = JournalBook Map.empty

data MasterBook = MasterBook
  { masterOrgs :: Map OrganisationId Organisation
  , masterPartners :: Map PartnerId Partner
  , masterAccounts :: Map AccountCode AccountMaster
  , masterSubAccounts :: Map SubAccountId SubAccount
  , orgPermissions :: Map OrganisationId (Set PermScope)
  {- ^ 組織ごとの許可スコープ。空セット = 制限なし（全許可）。
  1件でも登録するとホワイトリスト制になる。
  -}
  }
  deriving (Eq, Show)

initialMasterBook :: MasterBook
initialMasterBook =
  MasterBook Map.empty Map.empty Map.empty Map.empty Map.empty

data AppBook = AppBook
  { appJournals :: JournalBook
  , appMasters :: MasterBook
  }
  deriving (Eq, Show)

initialAppBook :: AppBook
initialAppBook = AppBook initialJournalBook initialMasterBook
