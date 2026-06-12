module Core.Decide
  ( decide
  ) where

import Data.List.NonEmpty (toList)

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T

import Core.Command (Command (..))
import Core.Domain.AccountCode (AccountCode, unAccountCode)
import Core.Domain.AccountMaster (AccountMaster (..))
import Core.Domain.Journal
  ( JournalEntry (..)
  , JournalLine (..)
  , VoucherRef (..)
  , creditTotal
  , debitTotal
  , isCorrectionType
  )
import Core.Domain.OrgPermission (PermScope (..))
import Core.Domain.Organisation (Organisation (..), OrganisationId (..))
import Core.Domain.Partner (Partner (..), PartnerId (..))
import Core.Domain.SubAccount (SubAccount (..), SubAccountId (..))
import Core.Error (DomainError (..))
import Core.Event (Event (..))
import Core.State (AppBook (..), JournalBook (..), MasterBook (..))

decide :: AppBook -> Command -> Either DomainError [Event]
decide book (RecordJournalEntry entry) = do
  checkDuplicate (appJournals book) entry
  checkBalance entry
  checkCorrectionRef entry
  checkVoucherMemo entry
  checkOrgExists (appMasters book) (entryOrg entry)
  mapM_
    (checkOrgAccountPerm (appMasters book) (entryOrg entry) . lineAccount)
    (toList (entryLines entry))
  pure [JournalEntryRecorded entry]
decide book (RegisterOrganisation org) = do
  let m = masterOrgs (appMasters book)
      oid = unOrgId (orgId org)
  checkNonEmpty "組織コード" oid
  checkNonEmpty "組織名称" (orgName org)
  check (Map.member (orgId org) m) (DuplicateMasterCode "組織" oid)
  pure [OrganisationRegistered org]
decide book (UpdateOrganisation org) = do
  let m = masterOrgs (appMasters book)
      oid = unOrgId (orgId org)
  checkNonEmpty "組織名称" (orgName org)
  check (Map.notMember (orgId org) m) (MasterNotFound "組織" oid)
  pure [OrganisationUpdated org]
decide book (GrantOrgPermission oid scope) = do
  let m = masterOrgs (appMasters book)
      perms = Map.findWithDefault Set.empty oid (orgPermissions (appMasters book))
  check (Map.notMember oid m) (MasterNotFound "組織" (unOrgId oid))
  check (Set.member scope perms) (PermissionAlreadyGranted oid scope)
  pure [OrgPermissionGranted oid scope]
decide book (RevokeOrgPermission oid scope) = do
  let m = masterOrgs (appMasters book)
      perms = Map.findWithDefault Set.empty oid (orgPermissions (appMasters book))
  check (Map.notMember oid m) (MasterNotFound "組織" (unOrgId oid))
  check (Set.notMember scope perms) (PermissionNotFound oid scope)
  pure [OrgPermissionRevoked oid scope]
decide book (RegisterPartner p) = do
  let m = masterPartners (appMasters book)
      pid = unPartnerId (partnerId p)
  checkNonEmpty "取引先コード" pid
  checkNonEmpty "取引先名称" (partnerName p)
  check (Map.member (partnerId p) m) (DuplicateMasterCode "取引先" pid)
  pure [PartnerRegistered p]
decide book (UpdatePartner p) = do
  let m = masterPartners (appMasters book)
      pid = unPartnerId (partnerId p)
  checkNonEmpty "取引先名称" (partnerName p)
  check (Map.notMember (partnerId p) m) (MasterNotFound "取引先" pid)
  pure [PartnerUpdated p]
decide book (RegisterAccountMaster am) = do
  let m = masterAccounts (appMasters book)
      code = unAccountCode (amCode am)
  checkNonEmpty "勘定科目コード" code
  checkNonEmpty "勘定科目名称" (amName am)
  check (Map.member (amCode am) m) (DuplicateMasterCode "勘定科目" code)
  pure [AccountMasterRegistered am]
decide book (UpdateAccountMaster am) = do
  let m = masterAccounts (appMasters book)
      code = unAccountCode (amCode am)
  checkNonEmpty "勘定科目名称" (amName am)
  check (Map.notMember (amCode am) m) (MasterNotFound "勘定科目" code)
  pure [AccountMasterUpdated am]
decide book (RegisterSubAccount sa) = do
  let m = masterSubAccounts (appMasters book)
      sid = unSubAccountId (saId sa)
  checkNonEmpty "補助科目コード" sid
  checkNonEmpty "補助科目名称" (saName sa)
  check (Map.member (saId sa) m) (DuplicateMasterCode "補助科目" sid)
  pure [SubAccountRegistered sa]
decide book (UpdateSubAccount sa) = do
  let m = masterSubAccounts (appMasters book)
      sid = unSubAccountId (saId sa)
  checkNonEmpty "補助科目名称" (saName sa)
  check (Map.notMember (saId sa) m) (MasterNotFound "補助科目" sid)
  pure [SubAccountUpdated sa]

-- ── helpers ────────────────────────────────────────────────────────────────

check :: Bool -> DomainError -> Either DomainError ()
check True err = Left err
check False _ = Right ()

checkDuplicate :: JournalBook -> JournalEntry -> Either DomainError ()
checkDuplicate book entry =
  check
    (Map.member (entryId entry) (journalEntries book))
    (DuplicateEntryId (entryId entry))

-- | 借貸一致検証 規程§4.1
checkBalance :: JournalEntry -> Either DomainError ()
checkBalance entry =
  let dr = debitTotal (entryLines entry)
      cr = creditTotal (entryLines entry)
  in check (dr /= cr) (UnbalancedEntry dr cr)

-- | 訂正仕訳は先行仕訳参照ID必須 規程§4.1, §4.4
checkCorrectionRef :: JournalEntry -> Either DomainError ()
checkCorrectionRef entry =
  check
    (isCorrectionType (entryActionType entry) && null (entryPriorRef entry))
    (CorrectionMissingPriorRef (entryActionType entry))

-- | 証憑未着の場合は摘要（根拠・到着予定日）が必須 規程§4.1
checkVoucherMemo :: JournalEntry -> Either DomainError ()
checkVoucherMemo entry = case entryVoucher entry of
  VoucherPending -> check (T.null (entryMemo entry)) PendingVoucherMissingMemo
  VoucherAttached _ -> Right ()

-- | 入力部門がマスタに存在するか
checkOrgExists :: MasterBook -> OrganisationId -> Either DomainError ()
checkOrgExists mb oid =
  check (Map.notMember oid (masterOrgs mb)) (OrgNotFound oid)

-- | 入力部門が当該科目の使用権限を持つか (空セット=全許可)
checkOrgAccountPerm :: MasterBook -> OrganisationId -> AccountCode -> Either DomainError ()
checkOrgAccountPerm mb oid ac =
  let perms = Map.findWithDefault Set.empty oid (orgPermissions mb)
  in if Set.null perms
       then Right ()
       else
         check
           (Set.notMember (AccountScope ac) perms)
           (OrgPermissionDenied oid (AccountScope ac))

checkNonEmpty :: T.Text -> T.Text -> Either DomainError ()
checkNonEmpty field val = check (T.null val) (EmptyMasterField field)
