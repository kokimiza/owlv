-- | Form-submission pipeline.
-- Uses effectful's Error effect for clean early exit on validation failures.
module Shell.TUI.Submit
  ( submitJournalEntry
  ) where

import Data.Decimal (Decimal)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (Day, defaultTimeLocale, parseTimeM)
import Data.UUID.V4 (nextRandom)
import qualified Brick.Widgets.Edit as E
import qualified Data.List.NonEmpty as NE
import Effectful
import Effectful.Error.Static

import Core.Command (Command (..))
import Core.Domain.AccountCode (mkAccountCode)
import Core.Domain.Journal
  ( DrCr
  , JournalEntry (..)
  , JournalEntryId (..)
  , JournalLine (..)
  , VoucherRef (..)
  )
import Core.Domain.Money (mkMoney)
import Shell.AppError (AppError (..))
import Shell.CommandExecutor (executeCommand)
import Shell.EventStore (EventStore)
import Shell.TUI.Types

-- | Parse, validate, and submit the form to the event store.
submitJournalEntry :: EventStore -> JournalFormState -> IO (Either AppError ())
submitJournalEntry store jf =
  runEff . runErrorNoCallStack @AppError $ do
    entry  <- parseFormData jf
    result <- liftIO (executeCommand store (RecordJournalEntry entry))
    case result of
      Left  err -> throwError err
      Right _   -> pure ()

-- ── parsing ─────────────────────────────────────────────────────────────────

type AppEff es = (IOE :> es, Error AppError :> es)

parseFormData :: AppEff es => JournalFormState -> Eff es JournalEntry
parseFormData jf = do
  uuid  <- liftIO nextRandom
  day   <- parseDay (edText (jfDate jf))
  vref  <- parseVoucher (jfVKind jf) (edText (jfVRef jf))
  line1 <- parseLine (jfL1Acc jf) (jfL1DrCr jf) (jfL1Amt jf)
  line2 <- parseLine (jfL2Acc jf) (jfL2DrCr jf) (jfL2Amt jf)
  pure
    JournalEntry
      { entryId         = JournalEntryId uuid
      , entryDate       = day
      , entryActionType = jfAction jf
      , entryRiskTier   = jfRisk jf
      , entryVoucher    = vref
      , entryPriorRef   = Nothing
      , entryMemo       = edText (jfMemo jf)
      , entryLines      = line1 NE.:| [line2]
      }

parseDay :: Error AppError :> es => Text -> Eff es Day
parseDay t = case parseTimeM True defaultTimeLocale "%Y-%m-%d" (T.unpack t) of
  Nothing -> throwError (DomainValidationError ("日付形式が無効です (YYYY-MM-DD): " <> t))
  Just d  -> pure d

parseVoucher :: Error AppError :> es => VoucherKind -> Text -> Eff es VoucherRef
parseVoucher VKAttached ref
  | T.null ref = throwError (DomainValidationError "証憑番号を入力してください")
  | otherwise  = pure (VoucherAttached ref)
parseVoucher VKPending _ = pure VoucherPending

parseLine
  :: Error AppError :> es
  => E.Editor Text Name -> DrCr -> E.Editor Text Name -> Eff es JournalLine
parseLine accEd dc amtEd = do
  ac  <- either (throwError . DomainValidationError) pure
           (mkAccountCode (edText accEd))
  amt <- parseDecimal (edText amtEd)
  pure (JournalLine ac dc (mkMoney amt))

parseDecimal :: Error AppError :> es => Text -> Eff es Decimal
parseDecimal t = case reads (T.unpack t) of
  [(d, "")] -> pure d
  _         -> throwError (DomainValidationError ("金額が無効です: " <> t))

-- ── helpers ─────────────────────────────────────────────────────────────────

edText :: E.Editor Text Name -> Text
edText = T.intercalate "\n" . E.getEditContents
