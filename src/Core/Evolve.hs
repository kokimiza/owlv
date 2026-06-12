module Core.Evolve
  ( evolve
  ) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set

import Core.Domain.AccountMaster (AccountMaster (..))
import Core.Domain.Journal (entryId)
import Core.Domain.Organisation (Organisation (..))
import Core.Domain.Partner (Partner (..))
import Core.Domain.SubAccount (SubAccount (..))
import Core.Event (Event (..))
import Core.State (AppBook (..), JournalBook (..), MasterBook (..))

evolve :: AppBook -> Event -> AppBook
evolve book (JournalEntryRecorded entry) =
  book
    { appJournals =
        JournalBook
          (Map.insert (entryId entry) entry (journalEntries (appJournals book)))
    }
evolve book (OrganisationRegistered org) =
  updateMasters book (\m -> m{masterOrgs = Map.insert (orgId org) org (masterOrgs m)})
evolve book (OrganisationUpdated org) =
  updateMasters book (\m -> m{masterOrgs = Map.insert (orgId org) org (masterOrgs m)})
evolve book (OrgPermissionGranted oid scope) =
  updateMasters book $ \m ->
    m
      { orgPermissions =
          Map.insertWith Set.union oid (Set.singleton scope) (orgPermissions m)
      }
evolve book (OrgPermissionRevoked oid scope) =
  updateMasters book $ \m ->
    let updated = Map.adjust (Set.delete scope) oid (orgPermissions m)
    in m{orgPermissions = updated}
evolve book (PartnerRegistered p) =
  updateMasters book (\m -> m{masterPartners = Map.insert (partnerId p) p (masterPartners m)})
evolve book (PartnerUpdated p) =
  updateMasters book (\m -> m{masterPartners = Map.insert (partnerId p) p (masterPartners m)})
evolve book (AccountMasterRegistered am) =
  updateMasters book (\m -> m{masterAccounts = Map.insert (amCode am) am (masterAccounts m)})
evolve book (AccountMasterUpdated am) =
  updateMasters book (\m -> m{masterAccounts = Map.insert (amCode am) am (masterAccounts m)})
evolve book (SubAccountRegistered sa) =
  updateMasters book (\m -> m{masterSubAccounts = Map.insert (saId sa) sa (masterSubAccounts m)})
evolve book (SubAccountUpdated sa) =
  updateMasters book (\m -> m{masterSubAccounts = Map.insert (saId sa) sa (masterSubAccounts m)})

updateMasters :: AppBook -> (MasterBook -> MasterBook) -> AppBook
updateMasters book f = book{appMasters = f (appMasters book)}
