module Core.JudgmentLogSpec (tests) where

import Data.Time (Day (..))
import Data.Word (Word32)
import Test.Tasty
import Test.Tasty.HUnit

import Data.Map.Strict qualified as Map
import Data.UUID qualified as UUID

import Core.Command (Command (..))
import Core.Decide (decide)
import Core.Domain.AccountingPeriod (AccountingPeriodId (..))
import Core.Domain.JudgmentLog
  ( JudgmentCategory (..)
  , JudgmentLog (..)
  , JudgmentLogId (..)
  )
import Core.Error (DomainError (..))
import Core.Event (Event (..))
import Core.Evolve (evolve)
import Core.State (AppBook (..), JudgmentLogBook (..), initialAppBook)

-- ── Fixtures ──────────────────────────────────────────────────────────────────

testDay :: Day
testDay = ModifiedJulianDay 59000

testPeriod :: AccountingPeriodId
testPeriod = AccountingPeriodId 2026 1

mkId :: Word32 -> JudgmentLogId
mkId n = JudgmentLogId (UUID.fromWords 0 0 0 n)

-- | 有効な判断ログ（簡便法 ECL）
l1 :: JudgmentLog
l1 =
  JudgmentLog
    { jlId = mkId 1
    , jlPeriod = testPeriod
    , jlDate = testDay
    , jlCategory = ExpectedCreditLoss
    , jlStandardRef = "IFRS 9 §5.5.14"
    , jlModel = "簡便法引当マトリクス"
    , jlAssumptions = "滞留日数区分に基づく損失率を適用"
    , jlSensitivity = "PD +10% → ECL +8%"
    , jlConclusion = "ECL = ¥5,000"
    , jlApprover = "CFO 田中太郎"
    , jlApprovalDate = testDay
    , jlRelatedEntityId = Nothing
    }

-- ── Tests ─────────────────────────────────────────────────────────────────────

tests :: TestTree
tests =
  testGroup
    "Core.JudgmentLog"
    [ testGroup "decide" decideTests
    , testGroup "evolve" evolveTests
    ]

-- ── decide ────────────────────────────────────────────────────────────────────

decideTests :: [TestTree]
decideTests =
  [ testCase "有効な判断ログを受理する" $
      decide initialAppBook (RecordJudgmentLog l1) @?= Right [JudgmentLogRecorded l1]
  , testCase "重複IDは DuplicateJudgmentLog" $ do
      let book = evolve initialAppBook (JudgmentLogRecorded l1)
      case decide book (RecordJudgmentLog l1) of
        Left (DuplicateJudgmentLog _) -> pure ()
        other -> assertFailure ("expected DuplicateJudgmentLog, got: " <> show other)
  , testCase "会計基準引用が空は EmptyMasterField" $ do
      let l = l1{jlId = mkId 2, jlStandardRef = ""}
      case decide initialAppBook (RecordJudgmentLog l) of
        Left (EmptyMasterField _) -> pure ()
        other -> assertFailure ("expected EmptyMasterField, got: " <> show other)
  , testCase "算定モデルが空は EmptyMasterField" $ do
      let l = l1{jlId = mkId 3, jlModel = ""}
      case decide initialAppBook (RecordJudgmentLog l) of
        Left (EmptyMasterField _) -> pure ()
        other -> assertFailure ("expected EmptyMasterField, got: " <> show other)
  , testCase "承認者が空は EmptyMasterField" $ do
      let l = l1{jlId = mkId 4, jlApprover = ""}
      case decide initialAppBook (RecordJudgmentLog l) of
        Left (EmptyMasterField _) -> pure ()
        other -> assertFailure ("expected EmptyMasterField, got: " <> show other)
  ]

-- ── evolve ────────────────────────────────────────────────────────────────────

evolveTests :: [TestTree]
evolveTests =
  [ testCase "JudgmentLogRecorded: JudgmentLogBook に登録される" $ do
      let book = evolve initialAppBook (JudgmentLogRecorded l1)
      assertBool "log present" (Map.member (jlId l1) (judgmentLogs (appJudgmentLogs book)))
  , testCase "JudgmentLogRecorded: 2件登録でサイズ 2" $ do
      let l2 = l1{jlId = mkId 2, jlCategory = ImpairmentTest}
          book = foldl' evolve initialAppBook [JudgmentLogRecorded l1, JudgmentLogRecorded l2]
      Map.size (judgmentLogs (appJudgmentLogs book)) @?= 2
  ]
