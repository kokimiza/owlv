module Core.Command
  ( Command (..)
  ) where

import Core.Domain.AccountMaster (AccountMaster)
import Core.Domain.Journal (JournalEntry)
import Core.Domain.OrgPermission (PermScope)
import Core.Domain.Organisation (Organisation, OrganisationId)
import Core.Domain.Partner (Partner)
import Core.Domain.SubAccount (SubAccount)

data Command
  = RecordJournalEntry JournalEntry
  | RegisterOrganisation Organisation
  | UpdateOrganisation Organisation
  | GrantOrgPermission OrganisationId PermScope
  | RevokeOrgPermission OrganisationId PermScope
  | RegisterPartner Partner
  | UpdatePartner Partner
  | RegisterAccountMaster AccountMaster
  | UpdateAccountMaster AccountMaster
  | RegisterSubAccount SubAccount
  | UpdateSubAccount SubAccount
  deriving (Eq, Show)
