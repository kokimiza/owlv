-- | 原始記録ドメイン型 (§2.1)
module Core.Domain.Journal
  ( JournalActionType (..)
  , isCorrectionType
  , RiskTier (..)
  , DrCr (..)
  , JournalLine (..)
  , VoucherRef (..)
  , JournalEntryId (..)
  , JournalEntry (..)
  , debitTotal
  , creditTotal
  ) where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, withText, (.:), (.:?), (.=))
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import Data.Time (Day)
import Data.UUID (UUID)
import GHC.Generics (Generic)

import Data.Text qualified as T
import Data.UUID qualified as UUID

import Core.Domain.AccountCode (AccountCode)
import Core.Domain.Money (Money, addMoney, zeroMoney)
import Core.Domain.Organisation (OrganisationId)
import Core.Domain.Partner (PartnerId)

-- | 仕訳行為区分 規程§2.1.1
data JournalActionType
  = NewEntry -- 新規起票: first recognition of an economic event
  | Cancellation -- 取消: nullify an existing entry
  | Reversal -- 反対: reverse a balance or period attribution
  | Supplementary -- 追加: correct a shortfall or late-discovered item
  | Reclassification -- 再分類: change display category without altering measurement
  | SwapRefresh -- 洗替: clear and re-evaluate
  | EstimateChange -- 見積変更: IAS 8 prospective estimate change
  deriving (Bounded, Enum, Eq, Generic, Show)

instance ToJSON JournalActionType
instance FromJSON JournalActionType

-- | Correction types require a prior-entry reference (§4.4).
isCorrectionType :: JournalActionType -> Bool
isCorrectionType NewEntry = False
isCorrectionType _ = True

-- | リスク分類 規程§3.2
data RiskTier = Low | Medium | High | Critical
  deriving (Bounded, Enum, Eq, Generic, Ord, Show)

instance ToJSON RiskTier
instance FromJSON RiskTier

-- | 借方 / 貸方
data DrCr = Debit | Credit
  deriving (Bounded, Enum, Eq, Generic, Show)

instance ToJSON DrCr
instance FromJSON DrCr

-- | 仕訳行 (一行)
data JournalLine = JournalLine
  { lineAccount :: AccountCode
  , lineDrCr :: DrCr
  , lineAmount :: Money
  , linePartner :: Maybe PartnerId -- RequiresSettlement 科目では必須; 旧レコードは Nothing
  }
  deriving (Eq, Generic, Show)

-- linePartner は旧レコードに存在しないため手書きインスタンス
instance ToJSON JournalLine where
  toJSON l =
    object $
      [ "lineAccount" .= lineAccount l
      , "lineDrCr" .= lineDrCr l
      , "lineAmount" .= lineAmount l
      ]
        <> ["linePartner" .= pid | Just pid <- [linePartner l]]

instance FromJSON JournalLine where
  parseJSON = withObject "JournalLine" $ \o ->
    JournalLine
      <$> o .: "lineAccount"
      <*> o .: "lineDrCr"
      <*> o .: "lineAmount"
      <*> o .:? "linePartner"

-- | 証憑参照 (§4.1): present or accepted-absent with justification in memo
data VoucherRef
  = VoucherAttached Text -- 証憑参照番号
  | VoucherPending -- 証憑未着 (費用確実・契約条件明確の場合のみ許容)
  deriving (Eq, Show)

instance ToJSON VoucherRef where
  toJSON (VoucherAttached r) = object ["tag" .= ("VoucherAttached" :: Text), "ref" .= r]
  toJSON VoucherPending = object ["tag" .= ("VoucherPending" :: Text)]

instance FromJSON VoucherRef where
  parseJSON = withObject "VoucherRef" $ \o -> do
    tag <- o .: "tag"
    case (tag :: Text) of
      "VoucherAttached" -> VoucherAttached <$> o .: "ref"
      "VoucherPending" -> pure VoucherPending
      _ -> fail ("unknown VoucherRef tag: " <> T.unpack tag)

newtype JournalEntryId = JournalEntryId UUID
  deriving (Eq, Ord, Show)

instance ToJSON JournalEntryId where
  toJSON (JournalEntryId uuid) = toJSON (UUID.toString uuid)

instance FromJSON JournalEntryId where
  parseJSON = withText "JournalEntryId" $ \t ->
    case UUID.fromString (T.unpack t) of
      Just uuid -> pure (JournalEntryId uuid)
      Nothing -> fail ("invalid UUID: " <> T.unpack t)

-- | 仕訳伝票ヘッダ + 明細
data JournalEntry = JournalEntry
  { entryId :: JournalEntryId
  , entryOrg :: OrganisationId -- 入力部門（権限制御の主体）
  , entryDate :: Day -- 取引発生日 (発生主義)
  , entryActionType :: JournalActionType
  , entryRiskTier :: RiskTier
  , entryVoucher :: VoucherRef
  , entryPriorRef :: Maybe JournalEntryId -- 先行仕訳参照ID (訂正時必須)
  , entryMemo :: Text -- 証憑未着時は根拠・到着予定日を記録
  , entryLines :: NonEmpty JournalLine
  }
  deriving (Eq, Generic, Show)

instance ToJSON JournalEntry
instance FromJSON JournalEntry

debitTotal :: NonEmpty JournalLine -> Money
debitTotal = foldr step zeroMoney
 where
  step l acc = if lineDrCr l == Debit then addMoney (lineAmount l) acc else acc

creditTotal :: NonEmpty JournalLine -> Money
creditTotal = foldr step zeroMoney
 where
  step l acc = if lineDrCr l == Credit then addMoney (lineAmount l) acc else acc
