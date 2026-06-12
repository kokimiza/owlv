module Core.Event
  ( Event (..)
  ) where

import Core.Domain.AccountMaster (AccountMaster)
import Core.Domain.Journal (JournalEntry)
import Core.Domain.OrgPermission (PermScope)
import Core.Domain.Organisation (Organisation, OrganisationId)
import Core.Domain.Partner (Partner)
import Core.Domain.SubAccount (SubAccount)

data Event
  = JournalEntryRecorded JournalEntry
  | OrganisationRegistered Organisation
  | OrganisationUpdated Organisation
  | OrgPermissionGranted OrganisationId PermScope
  | OrgPermissionRevoked OrganisationId PermScope
  | PartnerRegistered Partner
  | PartnerUpdated Partner
  | AccountMasterRegistered AccountMaster
  | AccountMasterUpdated AccountMaster
  | SubAccountRegistered SubAccount
  | SubAccountUpdated SubAccount
  deriving (Eq, Show)
