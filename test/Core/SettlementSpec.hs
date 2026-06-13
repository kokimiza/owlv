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

arCode :: AccountCode
arCode = unsafeAc "1100"

cashCode :: AccountCode
cashCode = unsafeAc "1010"

unsafeAc :: T.Text -> AccountCode
unsafeAc t = case mkAccountCode t of Right ac -> ac; Left _ -> error "unreachable"

mkUUID :: Word32 -> Word32 -> Word32 -> Word32 -> UUID.UUID
mkUUID = UUID.fromWords

-- | 組織・取引先・AR科目・現金科目登録済み AppBook
baseBook :: AppBook
baseBook =
  foldl'
    evolve
    initialAppBook
    [ OrganisationRegistered (Organisation testOrgId "テスト部門" Nothing True)
    , PartnerRegistered (Partner testPartnerId "得意先A" Customer True)
    , AccountMasterRegistered (AccountMaster arCode "売掛金" Asset Debit RequiresSettlement True)
    , AccountMasterRegistered (AccountMaster cashCode "現金" Asset Debit SelfContained True)
    ]

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

arEntryNoPartner :: JournalEntryId -> Day -> JournalEntry
arEntryNoPartner eid day =
  (arEntry eid day)
    { entryLines =
        JournalLine arCode Debit (mkMoney 10000) Nothing
          :| [JournalLine cashCode Credit (mkMoney 10000) Nothing]
    }

testDay :: Day
testDay = ModifiedJulianDay 59000

testPeriodId :: AccountingPeriodId
testPeriodId = periodIdOf testDay

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

-- | 完全消込（recTotal = ctAmount = 10,000）
validRec :: Reconciliation
validRec =
  Reconciliation
    recId1
    bankCtId
    (ReconciliationItem eid1 arCode (mkMoney 10000) :| [])
    testDay
    testOrgId
    ""

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
  [ testCase "AR 行に取引先あり → 受理する" $ do
      case decide baseBook (RecordJournalEntry (arEntry eid1 testDay)) of
        Right [JournalEntryRecorded _] -> pure ()
        other -> assertFailure ("expected success, got: " <> show other)
  , testCase "AR 行に取引先なし → SettlementAccountMissingPartner" $ do
      case decide baseBook (RecordJournalEntry (arEntryNoPartner eid1 testDay)) of
        Left (SettlementAccountMissingPartner ac) | ac == arCode -> pure ()
        other -> assertFailure ("expected SettlementAccountMissingPartner, got: " <> show other)
  , testProperty "SelfContained 行は取引先なしを許容する" $
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

periodTests :: [TestTree]
periodTests =
  [ testCase "オープン期間は仕訳を許容する" $ do
      let book = evolve baseBook (AccountingPeriodOpened testPeriodId)
      case decide book (RecordJournalEntry (arEntry eid1 testDay)) of
        Right _ -> pure ()
        other -> assertFailure ("expected success, got: " <> show other)
  , testCase "クローズ済み期間は仕訳を拒否する" $ do
      let book =
            foldl'
              evolve
              baseBook
              [AccountingPeriodOpened testPeriodId, AccountingPeriodClosed testPeriodId]
      case decide book (RecordJournalEntry (arEntry eid1 testDay)) of
        Left (Core.Error.PeriodClosed _) -> pure ()
        other -> assertFailure ("expected PeriodClosed, got: " <> show other)
  , testCase "CloseAccountingPeriod: オープン期間のクローズが成功する" $ do
      let book = evolve baseBook (AccountingPeriodOpened testPeriodId)
      case decide book (CloseAccountingPeriod testPeriodId) of
        Right [AccountingPeriodClosed _] -> pure ()
        other -> assertFailure ("expected success, got: " <> show other)
  , testCase "CloseAccountingPeriod: 既クローズは PeriodAlreadyClosed" $ do
      let book =
            foldl'
              evolve
              baseBook
              [AccountingPeriodOpened testPeriodId, AccountingPeriodClosed testPeriodId]
      case decide book (CloseAccountingPeriod testPeriodId) of
        Left (PeriodAlreadyClosed _) -> pure ()
        other -> assertFailure ("expected PeriodAlreadyClosed, got: " <> show other)
  , testCase "CloseAccountingPeriod: 未登録期間は PeriodNotFound" $
      decide baseBook (CloseAccountingPeriod (AccountingPeriodId 2099 12))
        @?= Left (PeriodNotFound (AccountingPeriodId 2099 12))
  , testCase "OpenAccountingPeriod: 同期間を二重オープンは DuplicatePeriod" $ do
      let book = evolve baseBook (AccountingPeriodOpened testPeriodId)
      case decide book (OpenAccountingPeriod testPeriodId) of
        Left (DuplicatePeriod _) -> pure ()
        other -> assertFailure ("expected DuplicatePeriod, got: " <> show other)
  , testCase "OpenAccountingPeriod: クローズ済み期間の再オープンが成功する" $ do
      let book =
            foldl'
              evolve
              baseBook
              [AccountingPeriodOpened testPeriodId, AccountingPeriodClosed testPeriodId]
      case decide book (OpenAccountingPeriod testPeriodId) of
        Right [AccountingPeriodOpened _] -> pure ()
        other -> assertFailure ("expected success, got: " <> show other)
  , testProperty "evolve: オープン→クローズで PeriodClosed ステータスになる" $
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
  [ testCase "入出金の登録が成功する" $ do
      case decide baseBook (RecordCashTransaction (bankCt testDay)) of
        Right [CashTransactionRecorded _] -> pure ()
        other -> assertFailure ("expected success, got: " <> show other)
  , testCase "重複IDは DuplicateCashTransactionId" $ do
      let book = evolve baseBook (CashTransactionRecorded (bankCt testDay))
      case decide book (RecordCashTransaction (bankCt testDay)) of
        Left (DuplicateCashTransactionId _) -> pure ()
        other -> assertFailure ("expected DuplicateCashTransactionId, got: " <> show other)
  , testCase "クローズ済み期間への登録は PeriodClosed" $ do
      let book =
            foldl'
              evolve
              baseBook
              [AccountingPeriodOpened testPeriodId, AccountingPeriodClosed testPeriodId]
      case decide book (RecordCashTransaction (bankCt testDay)) of
        Left (Core.Error.PeriodClosed _) -> pure ()
        other -> assertFailure ("expected PeriodClosed, got: " <> show other)
  , testCase "存在しない組織への登録は OrgNotFound" $ do
      let ct = (bankCt testDay){ctOrg = OrganisationId "GHOST"}
      case decide baseBook (RecordCashTransaction ct) of
        Left (OrgNotFound _) -> pure ()
        other -> assertFailure ("expected OrgNotFound, got: " <> show other)
  ]

-- ── Reconciliation ────────────────────────────────────────────────────────────

reconciliationTests :: [TestTree]
reconciliationTests =
  [ testCase "有効な消込が成功する" $ do
      let book =
            foldl'
              evolve
              baseBook
              [JournalEntryRecorded (arEntry eid1 testDay), CashTransactionRecorded (bankCt testDay)]
      case decide book (CreateReconciliation validRec) of
        Right [ReconciliationCreated _] -> pure ()
        other -> assertFailure ("expected success, got: " <> show other)
  , testCase "重複消込IDは DuplicateReconciliationId" $ do
      let book =
            foldl'
              evolve
              baseBook
              [ JournalEntryRecorded (arEntry eid1 testDay)
              , CashTransactionRecorded (bankCt testDay)
              , ReconciliationCreated validRec
              ]
      case decide book (CreateReconciliation validRec) of
        Left (DuplicateReconciliationId _) -> pure ()
        other -> assertFailure ("expected DuplicateReconciliationId, got: " <> show other)
  , testCase "存在しない入出金の消込は CashTransactionNotFound" $ do
      let ghostCtId = CashTransactionId (mkUUID 8 8 8 8)
          rec =
            Reconciliation
              recId1
              ghostCtId
              (ReconciliationItem eid1 arCode (mkMoney 10000) :| [])
              testDay
              testOrgId
              ""
      case decide baseBook (CreateReconciliation rec) of
        Left (CashTransactionNotFound _) -> pure ()
        other -> assertFailure ("expected CashTransactionNotFound, got: " <> show other)
  , testCase "オープン項目が存在しない消込は OpenItemNotFound" $ do
      -- CT は存在するが仕訳なし → オープン項目なし
      let book = evolve baseBook (CashTransactionRecorded (bankCt testDay))
          rec =
            Reconciliation
              recId1
              bankCtId
              (ReconciliationItem eid1 arCode (mkMoney 10000) :| [])
              testDay
              testOrgId
              ""
      case decide book (CreateReconciliation rec) of
        Left (OpenItemNotFound _ _) -> pure ()
        other -> assertFailure ("expected OpenItemNotFound, got: " <> show other)
  , testCase "消込合計が入出金額と不一致は ReconciliationAmountMismatch" $ do
      let book =
            foldl'
              evolve
              baseBook
              [JournalEntryRecorded (arEntry eid1 testDay), CashTransactionRecorded (bankCt testDay)]
          -- ctAmount=10000、消込合計=5000 → 不一致
          rec =
            Reconciliation
              recId1
              bankCtId
              (ReconciliationItem eid1 arCode (mkMoney 5000) :| [])
              testDay
              testOrgId
              ""
      case decide book (CreateReconciliation rec) of
        Left (ReconciliationAmountMismatch _ _) -> pure ()
        other -> assertFailure ("expected ReconciliationAmountMismatch, got: " <> show other)
  , testCase "オープン項目超過の消込は ReconciliationExceedsOpenBalance" $ do
      let book =
            foldl'
              evolve
              baseBook
              [JournalEntryRecorded (arEntry eid1 testDay), CashTransactionRecorded (bankCt testDay)]
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
  , testCase "消込取消でオープン項目が復元される" $ do
      let book =
            foldl'
              evolve
              baseBook
              [ JournalEntryRecorded (arEntry eid1 testDay)
              , CashTransactionRecorded (bankCt testDay)
              , ReconciliationCreated validRec
              ]
          key = (eid1, arCode)
      Map.lookup key (openItems (appCash book)) @?= Nothing
      let book2 = evolve book (ReconciliationReversed recId1 testDay)
      Map.lookup key (openItems (appCash book2)) @?= Just (mkMoney 10000)
  , testCase "二重取消は ReconciliationAlreadyReversed" $ do
      let book =
            foldl'
              evolve
              baseBook
              [ JournalEntryRecorded (arEntry eid1 testDay)
              , CashTransactionRecorded (bankCt testDay)
              , ReconciliationCreated validRec
              , ReconciliationReversed recId1 testDay
              ]
      case decide book (ReverseReconciliation recId1 testDay) of
        Left (ReconciliationAlreadyReversed _) -> pure ()
        other -> assertFailure ("expected ReconciliationAlreadyReversed, got: " <> show other)
  , testCase "存在しない消込の取消は ReconciliationNotFound" $ do
      case decide baseBook (ReverseReconciliation recId1 testDay) of
        Left (ReconciliationNotFound _) -> pure ()
        other -> assertFailure ("expected ReconciliationNotFound, got: " <> show other)
  , testCase "クローズ済み期間の取消は PeriodClosed" $ do
      let book =
            foldl'
              evolve
              baseBook
              [ JournalEntryRecorded (arEntry eid1 testDay)
              , CashTransactionRecorded (bankCt testDay)
              , ReconciliationCreated validRec
              , AccountingPeriodOpened testPeriodId
              , AccountingPeriodClosed testPeriodId
              ]
      case decide book (ReverseReconciliation recId1 testDay) of
        Left (Core.Error.PeriodClosed _) -> pure ()
        other -> assertFailure ("expected PeriodClosed, got: " <> show other)
  ]

-- ── OpenItems の fold 決定論性 ────────────────────────────────────────────────

openItemTests :: [TestTree]
openItemTests =
  [ testProperty "フォールド決定論: 同一イベント列 → 同一 openItems" $
      \(n :: Int) ->
        let cnt = abs n `mod` 5 + 1
            eids = [JournalEntryId (mkUUID 0 0 0 (fromIntegral i)) | i <- [1 .. cnt]]
            days = [ModifiedJulianDay (59000 + fromIntegral i) | i <- [1 .. cnt]]
            evts = concatMap (\(eid, day) -> [JournalEntryRecorded (arEntry eid day)]) (zip eids days)
            book1 = foldl' evolve baseBook evts
            book2 = foldl' evolve baseBook evts
        in openItems (appCash book1) == openItems (appCash book2)
  ]
