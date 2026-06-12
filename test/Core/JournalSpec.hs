{-# OPTIONS_GHC -Wno-orphans #-}

module Core.JournalSpec (tests) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
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
import Core.Domain.Journal
  ( DrCr (..)
  , JournalActionType (..)
  , JournalEntry (..)
  , JournalEntryId (..)
  , JournalLine (..)
  , RiskTier (..)
  , VoucherRef (..)
  )
import Core.Domain.Money (Money, mkMoney)
import Core.Domain.Organisation (Organisation (..), OrganisationId (..))
import Core.Error (DomainError (..))
import Core.Event (Event (..))
import Core.Evolve (evolve)
import Core.State (AppBook (..), JournalBook (..), initialAppBook)

-- ── Arbitrary instances ────────────────────────────────────────────────────

instance Arbitrary Money where
  arbitrary = mkMoney . fromInteger . abs <$> arbitrary

instance Arbitrary AccountCode where
  arbitrary = do
    lead <- elements ['1' .. '9']
    rest <- vectorOf 3 (elements (['0' .. '9'] ++ ['A' .. 'Z']))
    pure (unsafeAccount (T.pack (lead : rest)))
   where
    unsafeAccount t = case mkAccountCode t of
      Right ac -> ac
      Left _ -> error "unreachable"

instance Arbitrary DrCr where
  arbitrary = elements [Debit, Credit]

instance Arbitrary JournalLine where
  arbitrary = JournalLine <$> arbitrary <*> arbitrary <*> arbitrary

instance Arbitrary JournalActionType where
  arbitrary = elements [minBound .. maxBound]

instance Arbitrary RiskTier where
  arbitrary = elements [minBound .. maxBound]

instance Arbitrary VoucherRef where
  arbitrary = frequency [(3, VoucherAttached <$> genRefText), (1, pure VoucherPending)]

instance Arbitrary JournalEntryId where
  arbitrary = do
    ws <- vectorOf 4 (arbitrary :: Gen Word32)
    case ws of
      (w0 : w1 : w2 : w3 : _) -> pure (JournalEntryId (UUID.fromWords w0 w1 w2 w3))
      _ -> error "unreachable"

instance Arbitrary Day where
  arbitrary = ModifiedJulianDay . (59000 +) . abs . (`mod` 3650) <$> arbitrary

instance Arbitrary JournalEntry where
  arbitrary = do
    eid <- arbitrary
    day <- arbitrary
    actionType <- arbitrary
    risk <- arbitrary
    voucher <- arbitrary
    priorRef <- if actionType == NewEntry then pure Nothing else Just <$> arbitrary
    memo <- case voucher of VoucherPending -> genRefText; _ -> pure ""
    ls <- arbitrary
    pure (JournalEntry eid testOrgId day actionType risk voucher priorRef memo ls)

genRefText :: Gen Text
genRefText = T.pack <$> vectorOf 8 (elements (['a' .. 'z'] ++ ['0' .. '9']))

-- ── Test fixtures ──────────────────────────────────────────────────────────

-- | 事前登録済み組織 ID（テスト専用）
testOrgId :: OrganisationId
testOrgId = OrganisationId "TEST"

-- | testOrgId が登録された AppBook（RecordJournalEntry の checkOrgExists を通過させるため）
testBook :: AppBook
testBook = evolve initialAppBook (OrganisationRegistered org)
 where
  org = Organisation testOrgId "テスト部門" Nothing True

-- ── Helpers ────────────────────────────────────────────────────────────────

balancedEntry :: JournalEntryId -> Day -> JournalActionType -> Maybe JournalEntryId -> JournalEntry
balancedEntry eid day act priorRef =
  JournalEntry
    { entryId = eid
    , entryOrg = testOrgId
    , entryDate = day
    , entryActionType = act
    , entryRiskTier = Low
    , entryVoucher = VoucherAttached "REF-001"
    , entryPriorRef = priorRef
    , entryMemo = ""
    , entryLines = line Debit :| [line Credit]
    }
 where
  ac = case mkAccountCode "1010" of Right a -> a; Left _ -> error "unreachable"
  amount = mkMoney 1000
  line dc = JournalLine ac dc amount

-- ── Property: balanced entry ──────────────────────────────────────────────

newtype BalancedEntry = BalancedEntry JournalEntry deriving (Show)

instance Arbitrary BalancedEntry where
  arbitrary = do
    eid <- arbitrary
    day <- arbitrary
    act <- arbitrary
    priorRef <- if act == NewEntry then pure Nothing else Just <$> arbitrary
    amount <- (mkMoney . fromInteger . (+ 1) . abs) <$> arbitrary
    ac1 <- arbitrary
    ac2 <- arbitrary
    voucher <- arbitrary
    memo <- case voucher of VoucherPending -> genRefText; _ -> pure ""
    let ls = JournalLine ac1 Debit amount :| [JournalLine ac2 Credit amount]
    pure (BalancedEntry (JournalEntry eid testOrgId day act Low voucher priorRef memo ls))

-- ── Test tree ──────────────────────────────────────────────────────────────

tests :: TestTree
tests =
  testGroup
    "Core.Journal"
    [ testGroup "decide" decideTests
    , testGroup "evolve" evolveTests
    ]

decideTests :: [TestTree]
decideTests =
  [ testProperty "balanced entry is accepted" $
      \(BalancedEntry e) ->
        case decide testBook (RecordJournalEntry e) of
          Right [JournalEntryRecorded _] -> True
          _ -> False
  , testProperty "unbalanced entry is rejected" $
      \dr cr ->
        dr /= (cr :: Money) ==>
          let ac = case mkAccountCode "1010" of Right a -> a; Left _ -> error "unreachable"
              eid = JournalEntryId (UUID.fromWords 0 0 0 1)
              day = ModifiedJulianDay 59000
              ls = JournalLine ac Debit dr :| [JournalLine ac Credit cr]
              entry = JournalEntry eid testOrgId day NewEntry Low (VoucherAttached "X") Nothing "" ls
          in case decide testBook (RecordJournalEntry entry) of
               Left (UnbalancedEntry _ _) -> True
               _ -> False
  , testProperty "correction without prior ref is rejected" $
      \(BalancedEntry e) ->
        let corrEntry = e{entryActionType = Cancellation, entryPriorRef = Nothing}
        in case decide testBook (RecordJournalEntry corrEntry) of
             Left (CorrectionMissingPriorRef Cancellation) -> True
             _ -> False
  , testCase "pending voucher without memo is rejected" $ do
      let eid = JournalEntryId (UUID.fromWords 0 0 0 2)
          day = ModifiedJulianDay 59001
          ac = case mkAccountCode "2010" of Right a -> a; Left _ -> error "unreachable"
          ls = JournalLine ac Debit (mkMoney 500) :| [JournalLine ac Credit (mkMoney 500)]
          entry = JournalEntry eid testOrgId day NewEntry Low VoucherPending Nothing "" ls
      decide testBook (RecordJournalEntry entry)
        @?= Left PendingVoucherMissingMemo
  , testCase "duplicate entry ID is rejected" $ do
      let e1 =
            balancedEntry (JournalEntryId (UUID.fromWords 1 1 1 1)) (ModifiedJulianDay 59002) NewEntry Nothing
          book = foldl' evolve testBook [JournalEntryRecorded e1]
          e2 = e1
      case decide book (RecordJournalEntry e2) of
        Left (DuplicateEntryId _) -> pure ()
        other -> assertFailure ("expected DuplicateEntryId, got: " <> show other)
  , testCase "unknown org is rejected" $ do
      let eid = JournalEntryId (UUID.fromWords 0 0 0 3)
          day = ModifiedJulianDay 59003
          ac = case mkAccountCode "1010" of Right a -> a; Left _ -> error "unreachable"
          ls = JournalLine ac Debit (mkMoney 100) :| [JournalLine ac Credit (mkMoney 100)]
          entry = JournalEntry eid (OrganisationId "GHOST") day NewEntry Low (VoucherAttached "X") Nothing "" ls
      case decide testBook (RecordJournalEntry entry) of
        Left (OrgNotFound _) -> pure ()
        other -> assertFailure ("expected OrgNotFound, got: " <> show other)
  ]

evolveTests :: [TestTree]
evolveTests =
  [ testProperty "evolve inserts entry into book" $
      \(BalancedEntry e) ->
        let book = evolve testBook (JournalEntryRecorded e)
        in Map.member (entryId e) (journalEntries (appJournals book))
  , testProperty "fold determinism: same events yield same state" $
      \evts ->
        let evts' = map toEvent evts
            book1 = foldl' evolve testBook evts'
            book2 = foldl' evolve testBook evts'
        in book1 == book2
  , testProperty "n unique entries → book size equals n" $
      \(BalancedEntry e1) (BalancedEntry e2) ->
        entryId e1 /= entryId e2 ==>
          let events = [JournalEntryRecorded e1, JournalEntryRecorded e2]
              book = foldl' evolve testBook events
          in Map.size (journalEntries (appJournals book)) == 2
  ]
 where
  toEvent (BalancedEntry e) = JournalEntryRecorded e
