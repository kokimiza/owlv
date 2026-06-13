{-# OPTIONS_GHC -Wno-orphans #-}

module Core.MasterSpec (tests) where

import Data.Text (Text)
import Test.Tasty
import Test.Tasty.HUnit

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set

import Core.Command (Command (..))
import Core.Decide (decide)
import Core.Domain.AccountCode (mkAccountCode)
import Core.Domain.AccountMaster (AccountCategory (..), AccountMaster (..), SettlementBehavior (..))
import Core.Domain.Journal (DrCr (..))
import Core.Domain.OrgPermission (PermScope (..))
import Core.Domain.Organisation (Organisation (..), OrganisationId (..))
import Core.Domain.Partner (Partner (..), PartnerId (..), PartnerType (..))
import Core.Domain.SubAccount (SubAccount (..), SubAccountId (..))
import Core.Error (DomainError (..))
import Core.Event (Event (..))
import Core.Evolve (evolve)
import Core.State (AppBook (..), MasterBook (..), initialAppBook)

-- ── Helpers ─────────────────────────────────────────────────────────────────

mkOrg :: Text -> Text -> Organisation
mkOrg code name = Organisation (OrganisationId code) name Nothing True

mkPartner :: Text -> Text -> Partner
mkPartner code name = Partner (PartnerId code) name Customer True

mkAccount :: Text -> Text -> AccountMaster
mkAccount code name =
  case mkAccountCode code of
    Right ac -> AccountMaster ac name Asset Debit SelfContained True
    Left _ -> error "bad account code in test"

mkSubAcc :: Text -> Text -> SubAccount
mkSubAcc sid name =
  let ac = case mkAccountCode "1010" of Right a -> a; Left _ -> error "bad account code"
  in SubAccount (SubAccountId sid) name ac True

-- ── Test tree ────────────────────────────────────────────────────────────────

tests :: TestTree
tests =
  testGroup
    "Core.Master"
    [ testGroup "Organisation" orgTests
    , testGroup "Partner" partnerTests
    , testGroup "AccountMaster" accountTests
    , testGroup "SubAccount" subAccountTests
    , testGroup "OrgPermission" permissionTests
    ]

-- ── Organisation ──────────────────────────────────────────────────────────────

orgTests :: [TestTree]
orgTests =
  [ testCase "新規組織の登録が成功する" $ do
      let org = mkOrg "HQ" "本社"
      decide initialAppBook (RegisterOrganisation org) @?= Right [OrganisationRegistered org]
  , testCase "重複コードは DuplicateMasterCode" $ do
      let org = mkOrg "HQ" "本社"
          book = foldl' evolve initialAppBook [OrganisationRegistered org]
      case decide book (RegisterOrganisation org) of
        Left (DuplicateMasterCode "組織" "HQ") -> pure ()
        other -> assertFailure ("expected DuplicateMasterCode, got: " <> show other)
  , testCase "登録: 空の組織コードは EmptyMasterField" $ do
      let org = mkOrg "" "本社"
      case decide initialAppBook (RegisterOrganisation org) of
        Left (EmptyMasterField _) -> pure ()
        other -> assertFailure ("expected EmptyMasterField, got: " <> show other)
  , testCase "登録: 空の組織名称は EmptyMasterField" $ do
      let org = mkOrg "HQ" ""
      case decide initialAppBook (RegisterOrganisation org) of
        Left (EmptyMasterField _) -> pure ()
        other -> assertFailure ("expected EmptyMasterField, got: " <> show other)
  , testCase "既存組織の更新が成功する" $ do
      let org = mkOrg "HQ" "本社"
          book = foldl' evolve initialAppBook [OrganisationRegistered org]
          org2 = org{orgName = "本社（改）"}
      decide book (UpdateOrganisation org2) @?= Right [OrganisationUpdated org2]
  , testCase "存在しない組織の更新は MasterNotFound" $ do
      let org = mkOrg "GHOST" "存在しない"
      case decide initialAppBook (UpdateOrganisation org) of
        Left (MasterNotFound "組織" _) -> pure ()
        other -> assertFailure ("expected MasterNotFound, got: " <> show other)
  , testCase "更新: 空の組織名称は EmptyMasterField" $ do
      let org = mkOrg "HQ" "本社"
          book = foldl' evolve initialAppBook [OrganisationRegistered org]
          org2 = org{orgName = ""}
      case decide book (UpdateOrganisation org2) of
        Left (EmptyMasterField _) -> pure ()
        other -> assertFailure ("expected EmptyMasterField, got: " <> show other)
  , testCase "evolve: 登録済み組織が MasterBook に存在する" $ do
      let org = mkOrg "SALES" "営業部"
          book = evolve initialAppBook (OrganisationRegistered org)
      Map.member (OrganisationId "SALES") (masterOrgs (appMasters book)) @?= True
  , testCase "evolve: 更新済み組織が上書きされる" $ do
      let org = mkOrg "HQ" "本社"
          org2 = org{orgName = "本社（改）"}
          book = foldl' evolve initialAppBook [OrganisationRegistered org, OrganisationUpdated org2]
      Map.lookup (OrganisationId "HQ") (masterOrgs (appMasters book))
        @?= Just org2
  ]

-- ── Partner ───────────────────────────────────────────────────────────────────

partnerTests :: [TestTree]
partnerTests =
  [ testCase "新規取引先の登録が成功する" $ do
      let p = mkPartner "C001" "得意先A"
      decide initialAppBook (RegisterPartner p) @?= Right [PartnerRegistered p]
  , testCase "重複コードは DuplicateMasterCode" $ do
      let p = mkPartner "C001" "得意先A"
          book = foldl' evolve initialAppBook [PartnerRegistered p]
      case decide book (RegisterPartner p) of
        Left (DuplicateMasterCode "取引先" "C001") -> pure ()
        other -> assertFailure ("expected DuplicateMasterCode, got: " <> show other)
  , testCase "登録: 空の取引先コードは EmptyMasterField" $ do
      let p = mkPartner "" "得意先A"
      case decide initialAppBook (RegisterPartner p) of
        Left (EmptyMasterField _) -> pure ()
        other -> assertFailure ("expected EmptyMasterField, got: " <> show other)
  , testCase "登録: 空の取引先名称は EmptyMasterField" $ do
      let p = mkPartner "C001" ""
      case decide initialAppBook (RegisterPartner p) of
        Left (EmptyMasterField _) -> pure ()
        other -> assertFailure ("expected EmptyMasterField, got: " <> show other)
  , testCase "既存取引先の更新が成功する" $ do
      let p = mkPartner "C001" "得意先A"
          book = foldl' evolve initialAppBook [PartnerRegistered p]
          p2 = p{partnerName = "得意先A（改）"}
      decide book (UpdatePartner p2) @?= Right [PartnerUpdated p2]
  , testCase "存在しない取引先の更新は MasterNotFound" $ do
      let p = mkPartner "GHOST" "存在しない"
      case decide initialAppBook (UpdatePartner p) of
        Left (MasterNotFound "取引先" _) -> pure ()
        other -> assertFailure ("expected MasterNotFound, got: " <> show other)
  , testCase "更新: 空の取引先名称は EmptyMasterField" $ do
      let p = mkPartner "C001" "得意先A"
          book = foldl' evolve initialAppBook [PartnerRegistered p]
          p2 = p{partnerName = ""}
      case decide book (UpdatePartner p2) of
        Left (EmptyMasterField _) -> pure ()
        other -> assertFailure ("expected EmptyMasterField, got: " <> show other)
  , testCase "evolve: 更新済み取引先が上書きされる" $ do
      let p = mkPartner "C001" "得意先A"
          p2 = p{partnerName = "得意先A（改）"}
          book = foldl' evolve initialAppBook [PartnerRegistered p, PartnerUpdated p2]
      Map.lookup (PartnerId "C001") (masterPartners (appMasters book)) @?= Just p2
  ]

-- ── AccountMaster ─────────────────────────────────────────────────────────────

accountTests :: [TestTree]
accountTests =
  [ testCase "新規勘定科目の登録が成功する" $ do
      let am = mkAccount "1010" "現金"
      decide initialAppBook (RegisterAccountMaster am) @?= Right [AccountMasterRegistered am]
  , testCase "重複コードは DuplicateMasterCode" $ do
      let am = mkAccount "1010" "現金"
          book = foldl' evolve initialAppBook [AccountMasterRegistered am]
      case decide book (RegisterAccountMaster am) of
        Left (DuplicateMasterCode "勘定科目" "1010") -> pure ()
        other -> assertFailure ("expected DuplicateMasterCode, got: " <> show other)
  , testCase "登録: 空の科目名称は EmptyMasterField" $ do
      let am = mkAccount "1010" ""
      case decide initialAppBook (RegisterAccountMaster am) of
        Left (EmptyMasterField _) -> pure ()
        other -> assertFailure ("expected EmptyMasterField, got: " <> show other)
  , testCase "既存科目の更新が成功する" $ do
      let am = mkAccount "1010" "現金"
          book = foldl' evolve initialAppBook [AccountMasterRegistered am]
          am2 = am{amName = "現金・預金"}
      decide book (UpdateAccountMaster am2) @?= Right [AccountMasterUpdated am2]
  , testCase "存在しない科目の更新は MasterNotFound" $ do
      let am = mkAccount "9999" "存在しない"
      case decide initialAppBook (UpdateAccountMaster am) of
        Left (MasterNotFound "勘定科目" _) -> pure ()
        other -> assertFailure ("expected MasterNotFound, got: " <> show other)
  , testCase "更新: 空の科目名称は EmptyMasterField" $ do
      let am = mkAccount "1010" "現金"
          book = foldl' evolve initialAppBook [AccountMasterRegistered am]
          am2 = am{amName = ""}
      case decide book (UpdateAccountMaster am2) of
        Left (EmptyMasterField _) -> pure ()
        other -> assertFailure ("expected EmptyMasterField, got: " <> show other)
  , testCase "evolve: 登録済み科目が MasterBook に存在する" $ do
      let am = mkAccount "2010" "売掛金"
          book = evolve initialAppBook (AccountMasterRegistered am)
      Map.size (masterAccounts (appMasters book)) @?= 1
  , testCase "evolve: 更新済み科目が上書きされる" $ do
      let am = mkAccount "1010" "現金"
          am2 = am{amName = "現金・預金"}
          book = foldl' evolve initialAppBook [AccountMasterRegistered am, AccountMasterUpdated am2]
          ac = case mkAccountCode "1010" of Right a -> a; Left _ -> error "unreachable"
      (amName <$> Map.lookup ac (masterAccounts (appMasters book))) @?= Just "現金・預金"
  ]

-- ── SubAccount ────────────────────────────────────────────────────────────────

subAccountTests :: [TestTree]
subAccountTests =
  [ testCase "新規補助科目の登録が成功する" $ do
      let sa = mkSubAcc "SA-001" "現金（小口）"
      decide initialAppBook (RegisterSubAccount sa) @?= Right [SubAccountRegistered sa]
  , testCase "重複コードは DuplicateMasterCode" $ do
      let sa = mkSubAcc "SA-001" "現金（小口）"
          book = foldl' evolve initialAppBook [SubAccountRegistered sa]
      case decide book (RegisterSubAccount sa) of
        Left (DuplicateMasterCode "補助科目" "SA-001") -> pure ()
        other -> assertFailure ("expected DuplicateMasterCode, got: " <> show other)
  , testCase "登録: 空の補助科目コードは EmptyMasterField" $ do
      let sa = mkSubAcc "" "現金（小口）"
      case decide initialAppBook (RegisterSubAccount sa) of
        Left (EmptyMasterField _) -> pure ()
        other -> assertFailure ("expected EmptyMasterField, got: " <> show other)
  , testCase "登録: 空の補助科目名称は EmptyMasterField" $ do
      let sa = mkSubAcc "SA-001" ""
      case decide initialAppBook (RegisterSubAccount sa) of
        Left (EmptyMasterField _) -> pure ()
        other -> assertFailure ("expected EmptyMasterField, got: " <> show other)
  , testCase "既存補助科目の更新が成功する" $ do
      let sa = mkSubAcc "SA-001" "現金（小口）"
          book = foldl' evolve initialAppBook [SubAccountRegistered sa]
          sa2 = sa{saName = "現金（小口）改"}
      decide book (UpdateSubAccount sa2) @?= Right [SubAccountUpdated sa2]
  , testCase "存在しない補助科目の更新は MasterNotFound" $ do
      let sa = mkSubAcc "GHOST" "存在しない"
      case decide initialAppBook (UpdateSubAccount sa) of
        Left (MasterNotFound "補助科目" _) -> pure ()
        other -> assertFailure ("expected MasterNotFound, got: " <> show other)
  , testCase "更新: 空の補助科目名称は EmptyMasterField" $ do
      let sa = mkSubAcc "SA-001" "現金（小口）"
          book = foldl' evolve initialAppBook [SubAccountRegistered sa]
          sa2 = sa{saName = ""}
      case decide book (UpdateSubAccount sa2) of
        Left (EmptyMasterField _) -> pure ()
        other -> assertFailure ("expected EmptyMasterField, got: " <> show other)
  , testCase "evolve: SubAccountRegistered が masterSubAccounts に登録される" $ do
      let sa = mkSubAcc "SA-001" "現金（小口）"
          book = evolve initialAppBook (SubAccountRegistered sa)
      Map.member (SubAccountId "SA-001") (masterSubAccounts (appMasters book)) @?= True
  , testCase "evolve: SubAccountUpdated が上書きされる" $ do
      let sa = mkSubAcc "SA-001" "現金（小口）"
          sa2 = sa{saName = "現金（小口）改"}
          book = foldl' evolve initialAppBook [SubAccountRegistered sa, SubAccountUpdated sa2]
      (saName <$> Map.lookup (SubAccountId "SA-001") (masterSubAccounts (appMasters book)))
        @?= Just "現金（小口）改"
  ]

-- ── OrgPermission ─────────────────────────────────────────────────────────────

permissionTests :: [TestTree]
permissionTests =
  let org = mkOrg "HQ" "本社"
      oid = OrganisationId "HQ"
      orgBook = evolve initialAppBook (OrganisationRegistered org)
      ac = case mkAccountCode "1010" of Right a -> a; Left _ -> error "unreachable"
      scope = AccountScope ac
  in [ testCase "GrantOrgPermission: 権限付与が成功する" $ do
         decide orgBook (GrantOrgPermission oid scope)
           @?= Right [OrgPermissionGranted oid scope]
     , testCase "GrantOrgPermission: 組織が存在しない場合 MasterNotFound" $ do
         case decide initialAppBook (GrantOrgPermission oid scope) of
           Left (MasterNotFound "組織" _) -> pure ()
           other -> assertFailure ("expected MasterNotFound, got: " <> show other)
     , testCase "GrantOrgPermission: 既に付与済みは PermissionAlreadyGranted" $ do
         let book = evolve orgBook (OrgPermissionGranted oid scope)
         case decide book (GrantOrgPermission oid scope) of
           Left (PermissionAlreadyGranted _ _) -> pure ()
           other -> assertFailure ("expected PermissionAlreadyGranted, got: " <> show other)
     , testCase "RevokeOrgPermission: 権限取消が成功する" $ do
         let book = evolve orgBook (OrgPermissionGranted oid scope)
         decide book (RevokeOrgPermission oid scope)
           @?= Right [OrgPermissionRevoked oid scope]
     , testCase "RevokeOrgPermission: 組織が存在しない場合 MasterNotFound" $ do
         case decide initialAppBook (RevokeOrgPermission oid scope) of
           Left (MasterNotFound "組織" _) -> pure ()
           other -> assertFailure ("expected MasterNotFound, got: " <> show other)
     , testCase "RevokeOrgPermission: 未付与の権限取消は PermissionNotFound" $ do
         case decide orgBook (RevokeOrgPermission oid scope) of
           Left (PermissionNotFound _ _) -> pure ()
           other -> assertFailure ("expected PermissionNotFound, got: " <> show other)
     , testCase "evolve: OrgPermissionGranted がセットに追加される" $ do
         let book = evolve orgBook (OrgPermissionGranted oid scope)
         Set.member scope (Map.findWithDefault Set.empty oid (orgPermissions (appMasters book)))
           @?= True
     , testCase "evolve: OrgPermissionRevoked がセットから除去される" $ do
         let book = foldl' evolve orgBook [OrgPermissionGranted oid scope, OrgPermissionRevoked oid scope]
         Set.member scope (Map.findWithDefault Set.empty oid (orgPermissions (appMasters book)))
           @?= False
     , testCase "evolve: 付与→取消後は空セット（制限なし）になる" $ do
         let book = foldl' evolve orgBook [OrgPermissionGranted oid scope, OrgPermissionRevoked oid scope]
         Set.null (Map.findWithDefault Set.empty oid (orgPermissions (appMasters book)))
           @?= True
     ]
