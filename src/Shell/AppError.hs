-- | Shell-layer error type.  All IO in Shell returns IO (Either AppError a)
-- — exceptions never propagate past this boundary.
module Shell.AppError
  ( AppError (..)
  , fromDomainError
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.UUID (toText)
import Core.Domain.Journal (JournalEntryId (..))
import Core.Domain.Money (unMoney)
import Core.Error (DomainError (..))

data AppError
  = DomainValidationError Text
  | StorageError Text        -- serialize / deserialize / constraint failure
  | ConnectionError Text     -- cannot reach the database
  | NotFound Text
  deriving (Eq, Show)

fromDomainError :: DomainError -> AppError
fromDomainError (UnbalancedEntry dr cr) =
  DomainValidationError $
    T.pack "借貸不一致: 借方="
    <> T.pack (show (unMoney dr))
    <> T.pack " 貸方="
    <> T.pack (show (unMoney cr))
fromDomainError (CorrectionMissingPriorRef at) =
  DomainValidationError $
    T.pack "訂正仕訳に先行仕訳参照IDがありません: "
    <> T.pack (show at)
fromDomainError PendingVoucherMissingMemo =
  DomainValidationError (T.pack "証憑未着仕訳に摘要（根拠・到着予定日）が必要です")
fromDomainError (DuplicateEntryId (JournalEntryId uuid)) =
  DomainValidationError $
    T.pack "仕訳IDが重複しています: " <> toText uuid
