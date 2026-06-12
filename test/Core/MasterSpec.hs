{-# OPTIONS_GHC -Wno-orphans #-}

module Core.MasterSpec (tests) where

import Data.Text (Text)
import Test.Tasty
import Test.Tasty.HUnit

import Data.Map.Strict qualified as Map

import Core.Command (Command (..))
import Core.Decide (decide)
import Core.Domain.AccountCode (mkAccountCode)
import Core.Domain.AccountMaster (AccountCategory (..), AccountMaster (..), SettlementBehavior (..))
import Core.Domain.Journal (DrCr (..))
import Core.Domain.Organisation (Organisation (..), OrganisationId (..))
import Core.Domain.Partner (Partner (..), PartnerId (..), PartnerType (..))
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

-- ── Test tree ────────────────────────────────────────────────────────────────

tests :: TestTree
tests =
  testGroup
    "Core.Master"
    [ testGroup "Organisation" orgTests
    , testGroup "Partner" partnerTests
    , testGroup "AccountMaster" accountTests
    ]

orgTests :: [TestTree]
orgTests =
  [ testCase "register new org succeeds" $ do
      let org = mkOrg "HQ" "本社"
      decide initialAppBook (RegisterOrganisation org)
        @?= Right [OrganisationRegistered org]
  , testCase "duplicate org code is rejected" $ do
      let org = mkOrg "HQ" "本社"
          book = foldl' evolve initialAppBook [OrganisationRegistered org]
      case decide book (RegisterOrganisation org) of
        Left (DuplicateMasterCode "組織" "HQ") -> pure ()
        other -> assertFailure ("expected DuplicateMasterCode, got: " <> show other)
  , testCase "update existing org succeeds" $ do
      let org = mkOrg "HQ" "本社"
          book = foldl' evolve initialAppBook [OrganisationRegistered org]
          org2 = org{orgName = "本社（改）"}
      decide book (UpdateOrganisation org2)
        @?= Right [OrganisationUpdated org2]
  , testCase "update non-existent org is rejected" $ do
      let org = mkOrg "GHOST" "存在しない"
      case decide initialAppBook (UpdateOrganisation org) of
        Left (MasterNotFound "組織" _) -> pure ()
        other -> assertFailure ("expected MasterNotFound, got: " <> show other)
  , testCase "evolve: registered org appears in MasterBook" $ do
      let org = mkOrg "SALES" "営業部"
          book = evolve initialAppBook (OrganisationRegistered org)
      Map.member (OrganisationId "SALES") (masterOrgs (appMasters book))
        @?= True
  ]

partnerTests :: [TestTree]
partnerTests =
  [ testCase "register new partner succeeds" $ do
      let p = mkPartner "C001" "得意先A"
      decide initialAppBook (RegisterPartner p)
        @?= Right [PartnerRegistered p]
  , testCase "duplicate partner code is rejected" $ do
      let p = mkPartner "C001" "得意先A"
          book = foldl' evolve initialAppBook [PartnerRegistered p]
      case decide book (RegisterPartner p) of
        Left (DuplicateMasterCode "取引先" "C001") -> pure ()
        other -> assertFailure ("expected DuplicateMasterCode, got: " <> show other)
  ]

accountTests :: [TestTree]
accountTests =
  [ testCase "register account master succeeds" $ do
      let am = mkAccount "1010" "現金"
      decide initialAppBook (RegisterAccountMaster am)
        @?= Right [AccountMasterRegistered am]
  , testCase "duplicate account code is rejected" $ do
      let am = mkAccount "1010" "現金"
          book = foldl' evolve initialAppBook [AccountMasterRegistered am]
      case decide book (RegisterAccountMaster am) of
        Left (DuplicateMasterCode "勘定科目" "1010") -> pure ()
        other -> assertFailure ("expected DuplicateMasterCode, got: " <> show other)
  , testCase "evolve: account appears in MasterBook" $ do
      let am = mkAccount "2010" "売掛金"
          book = evolve initialAppBook (AccountMasterRegistered am)
      Map.size (masterAccounts (appMasters book)) @?= 1
  ]
