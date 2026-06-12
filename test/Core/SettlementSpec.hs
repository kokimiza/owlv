{-# OPTIONS_GHC -Wno-orphans #-}

module Core.SettlementSpec (tests) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Time (Day (..))
import Data.Word (Word32)
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck

import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.UUID qualified as UUID

import Core.Command (Command (..))
import Core.Decide (decide)
import Core.Domain.AccountCode (AccountCode, mkAccountCode)
import Core.Domain.AccountMaster (AccountCategory (..), AccountMaster (..), SettlementBehavior (..))
import Core.Domain.AccountingPeriod (AccountingPeriodId (..), periodIdOf)
import Core.Domain.CashTransaction (CashTransaction (..), CashTransactionId (..))
import Core.Domain.Journal
  ( DrCr (..)
  , JournalActionType (..)
  , JournalEntry (..)
  , JournalEntryId (..)
  , JournalLine (..)
  , RiskTier (..)
  , VoucherRef (..)
  )
import Core.Domain.Money (mkMoney)
import Core.Domain.Organisation (Organisation (..), OrganisationId (..))
import Core.Domain.Partner (Partner (..), PartnerId (..), PartnerType (..))
import Core.Domain.Reconciliation
  ( Reconciliation (..)
  , ReconciliationId (..)
  , ReconciliationItem (..)
  )
import Core.Error (DomainError (..))
import Core.Event (Event (..))
import Core.Evolve (evolve)
import Core.State (AppBook (..), CashBook (..), PeriodsBook (..), initialAppBook)

import Core.Domain.AccountingPeriod qualified as AP

-- ── Fixtures ─────────────────────────────────────────────────────────────────

testOrgId :: OrganisationId
testOrgId = OrganisationId "TEST"

testPartnerId :: PartnerId
testPartnerId = PartnerId "PARTNER001"

-- | AR科目（RequiresSettlement）
arCode :: AccountCode
arCode = unsafeAc "1100"

-- | 現金科目（SelfContained）
cashCode :: AccountCode
cashCode = unsafeAc "1010"

unsafeAc :: T.Text -> AccountCode
unsafeAc t = case mkAccountCode t of Right ac -> ac; Left _ -> error "unreachable"

mkUUID :: Word32 -> Word32 -> Word32 -> Word32 -> UUID.UUID
mkUUID = UUID.fromWords

-- | 基本的な AppBook: 組織・取引先・AR科目・現金科目登録済み
baseBook :: AppBook
baseBook =
  foldl'
    evolve
    initialAppBook
    [ OrganisationRegistered (Organisation testOrgId "テスト部門" Nothing True)
    , PartnerRegistered (Partner testPartnerId "得意先A" Customer True)
    , AccountMasterRegistered
        (AccountMaster arCode "売掛金" Asset Debit RequiresSettlement True)
    , AccountMasterRegistered
        (AccountMaster cashCode "現金" Asset Debit SelfContained True)
    ]

-- | AR 科目入り仕訳（取引先あり）
arEntry :: JournalEntryId -> Day -> JournalEntry
arEntry eid day =
  JournalEntry
    { entryId = eid
    , entryOrg = testOrgId
    , entryDate = day
    , entryActionType = NewEntry
    , entryRiskTier = Low
    , entryVoucher = VoucherAttached "INV-001"
    , entryPriorRef = Nothing
    , entryMemo = ""
    , entryLines =
        JournalLine arCode Debit (mkMoney 10000) (Just testPartnerId)
          :| [JournalLine cashCode Credit (mkMoney 10000) Nothing]
    }

-- | AR 科目入り仕訳（取引先なし — 不正）
arEntryNoPartner :: JournalEntryId -> Day -> JournalEntry
arEntryNoPartner eid day =
  (arEntry eid day)
    { entryLines =
        JournalLine arCode Debit (mkMoney 10000) Nothing
          :| [JournalLine cashCode Credit (mkMoney 10000) Nothing]
    }

testDay :: Day
testDay = ModifiedJulianDay 59000

bankCtId :: CashTransactionId
bankCtId = CashTransactionId (mkUUID 9 9 9 1)

bankCt :: Day -> CashTransaction
bankCt day =
  CashTransaction
    { ctId = bankCtId
    , ctDate = day
    , ctOrg = testOrgId
    , ctAccount = cashCode
    , ctDrCr = Credit
    , ctAmount = mkMoney 10000
    , ctPartner = Just testPartnerId
    , ctBankRef = "BANK-0001"
    , ctMemo = ""
    }

recId1 :: ReconciliationId
recId1 = ReconciliationId (mkUUID 7 7 7 1)

eid1 :: JournalEntryId
eid1 = JournalEntryId (mkUUID 1 1 1 1)

-- ── Tests ─────────────────────────────────────────────────────────────────────

tests :: TestTree
tests =
  testGroup
    "Core.Settlement"
    [ testGroup "RequiresSettlement" settlementPartnerTests
    , testGroup "AccountingPeriod" periodTests
    , testGroup "CashTransaction" cashTxTests
    , testGroup "Reconciliation" reconciliationTests
    , testGroup "evolve.OpenItems" openItemTests
    ]

-- ── RequiresSettlement ────────────────────────────────────────────────────────

settlementPartnerTests :: [TestTree]
settlementPartnerTests =
  [ testCase "AR line with partner is accepted" $ do
      case decide baseBook (RecordJournalEntry (arEntry eid1 testDay)) of
        Right [JournalEntryRecorded _] -> pure ()
        other -> assertFailure ("expected success, got: " <> show other)
  , testCase "AR line without partner is rejected" $ do
      case decide baseBook (RecordJournalEntry (arEntryNoPartner eid1 testDay)) of
        Left (SettlementAccountMissingPartner ac) | ac == arCode -> pure ()
        other -> assertFailure ("expected SettlementAccountMissingPartner, got: " <> show other)
  , testProperty "SelfContained lines accept Nothing partner" $
      \(w0, w1, w2, w3) ->
        let eid = JournalEntryId (mkUUID w0 w1 w2 w3)
            ls =
              JournalLine cashCode Debit (mkMoney 500) Nothing
                :| [JournalLine cashCode Credit (mkMoney 500) Nothing]
            entry =
              JournalEntry
                eid
                testOrgId
                testDay
                NewEntry
                Low
                (VoucherAttached "X")
                Nothing
                ""
                ls
        in case decide baseBook (RecordJournalEntry entry) of
             Left (SettlementAccountMissingPartner _) -> False
             _ -> True
  ]

-- ── AccountingPeriod ──────────────────────────────────────────────────────────

-- | testDay が属する会計期間（periodIdOf で一致させる）
testPeriodId :: AccountingPeriodId
testPeriodId = periodIdOf testDay

periodTests :: [TestTree]
periodTests =
  [ testCase "open period allows journal entry" $ do
      let book = evolve baseBook (AccountingPeriodOpened testPeriodId)
      case decide book (RecordJournalEntry (arEntry eid1 testDay)) of
        Right _ -> pure ()
        other -> assertFailure ("expected success, got: " <> show other)
  , testCase "closed period rejects journal entry" $ do
      let book =
            foldl'
              evolve
              baseBook
              [AccountingPeriodOpened testPeriodId, AccountingPeriodClosed testPeriodId]
      case decide book (RecordJournalEntry (arEntry eid1 testDay)) of
        Left (Core.Error.PeriodClosed _) -> pure ()
        other -> assertFailure ("expected PeriodClosed, got: " <> show other)
  , testCase "CloseAccountingPeriod on missing period fails" $ do
      let apId = AccountingPeriodId 2099 12
      decide baseBook (CloseAccountingPeriod apId)
        @?= Left (PeriodNotFound apId)
  , testCase "OpenAccountingPeriod twice fails" $ do
      let book = evolve baseBook (AccountingPeriodOpened testPeriodId)
      case decide book (OpenAccountingPeriod testPeriodId) of
        Left (DuplicatePeriod _) -> pure ()
        other -> assertFailure ("expected DuplicatePeriod, got: " <> show other)
  , testProperty "evolve: open→close gives PeriodClosed status" $
      \yr mo ->
        let apId = AccountingPeriodId (abs yr `mod` 9999 + 1) (abs mo `mod` 12 + 1)
            book =
              foldl'
                evolve
                initialAppBook
                [AccountingPeriodOpened apId, AccountingPeriodClosed apId]
        in Map.lookup apId (periodStatus (appPeriods book)) == Just AP.PeriodClosed
  ]

-- ── CashTransaction ───────────────────────────────────────────────────────────

cashTxTests :: [TestTree]
cashTxTests =
  [ testCase "record cash transaction succeeds" $ do
      case decide baseBook (RecordCashTransaction (bankCt testDay)) of
        Right [CashTransactionRecorded _] -> pure ()
        other -> assertFailure ("expected success, got: " <> show other)
  , testCase "duplicate cash transaction id is rejected" $ do
      let book = evolve baseBook (CashTransactionRecorded (bankCt testDay))
      case decide book (RecordCashTransaction (bankCt testDay)) of
        Left (DuplicateCashTransactionId _) -> pure ()
        other -> assertFailure ("expected DuplicateCashTransactionId, got: " <> show other)
  ]

-- ── Reconciliation ────────────────────────────────────────────────────────────

reconciliationTests :: [TestTree]
reconciliationTests =
  [ testCase "valid reconciliation succeeds" $ do
      let book =
            foldl'
              evolve
              baseBook
              [ JournalEntryRecorded (arEntry eid1 testDay)
              , CashTransactionRecorded (bankCt testDay)
              ]
          rec =
            Reconciliation
              recId1
              bankCtId
              (ReconciliationItem eid1 arCode (mkMoney 10000) :| [])
              testDay
              testOrgId
              ""
      case decide book (CreateReconciliation rec) of
        Right [ReconciliationCreated _] -> pure ()
        other -> assertFailure ("expected success, got: " <> show other)
  , testCase "reconciliation exceeding open item is rejected" $ do
      let book =
            foldl'
              evolve
              baseBook
              [ JournalEntryRecorded (arEntry eid1 testDay)
              , CashTransactionRecorded (bankCt testDay)
              ]
          rec =
            Reconciliation
              recId1
              bankCtId
              (ReconciliationItem eid1 arCode (mkMoney 99999) :| [])
              testDay
              testOrgId
              ""
      case decide book (CreateReconciliation rec) of
        Left (ReconciliationExceedsOpenBalance _ _ _) -> pure ()
        other -> assertFailure ("expected ReconciliationExceedsOpenBalance, got: " <> show other)
  , testCase "reversal restores open item" $ do
      let book =
            foldl'
              evolve
              baseBook
              [ JournalEntryRecorded (arEntry eid1 testDay)
              , CashTransactionRecorded (bankCt testDay)
              , ReconciliationCreated
                  ( Reconciliation
                      recId1
                      bankCtId
                      (ReconciliationItem eid1 arCode (mkMoney 10000) :| [])
                      testDay
                      testOrgId
                      ""
                  )
              ]
          key = (eid1, arCode)
      -- 消込後は OpenItem ゼロ
      Map.lookup key (openItems (appCash book)) @?= Nothing
      -- 取消後は復元
      let book2 = evolve book (ReconciliationReversed recId1 testDay)
      Map.lookup key (openItems (appCash book2)) @?= Just (mkMoney 10000)
  , testCase "double reversal is rejected" $ do
      let book =
            foldl'
              evolve
              baseBook
              [ JournalEntryRecorded (arEntry eid1 testDay)
              , CashTransactionRecorded (bankCt testDay)
              , ReconciliationCreated
                  ( Reconciliation
                      recId1
                      bankCtId
                      (ReconciliationItem eid1 arCode (mkMoney 10000) :| [])
                      testDay
                      testOrgId
                      ""
                  )
              , ReconciliationReversed recId1 testDay
              ]
      case decide book (ReverseReconciliation recId1 testDay) of
        Left (ReconciliationAlreadyReversed _) -> pure ()
        other -> assertFailure ("expected ReconciliationAlreadyReversed, got: " <> show other)
  ]

-- ── OpenItems の fold 決定論性 ────────────────────────────────────────────────

openItemTests :: [TestTree]
openItemTests =
  [ testProperty "fold determinism: same events yield same openItems" $
      \(n :: Int) ->
        let cnt = abs n `mod` 5 + 1
            eids = [JournalEntryId (mkUUID 0 0 0 (fromIntegral i)) | i <- [1 .. cnt]]
            days = [ModifiedJulianDay (59000 + fromIntegral i) | i <- [1 .. cnt]]
            evts = concatMap (\(eid, day) -> [JournalEntryRecorded (arEntry eid day)]) (zip eids days)
            book1 = foldl' evolve baseBook evts
            book2 = foldl' evolve baseBook evts
        in openItems (appCash book1) == openItems (appCash book2)
  ]
