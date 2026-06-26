{- | 労務人事ドメイン型 (doc/labor_management.md)

`Personnel`（雇用・契約上の実体）は `Core.Domain.User`（システムへのログイン
主体）とは完全に独立したドメインである (doc/labor_management.md §0.1)。
両者がたまたま同一人物を指す場合は `personnelUserRef` という弱い参照で
表現し、構造的な依存は持たせない。
-}
module Core.Domain.Personnel
  ( EmploymentType (..)
  , PersonnelStatus (..)
  , PersonnelId (..)
  , Personnel (..)
  , PayBasis (..)
  , ContractTermId (..)
  , ContractTerm (..)
  ) where

import Data.Aeson
  ( FromJSON (..)
  , ToJSON (..)
  , object
  , withObject
  , withText
  , (.:)
  , (.=)
  )
import Data.Decimal (Decimal)
import Data.Text (Text)
import Data.Time (Day)
import Data.UUID (UUID)
import GHC.Generics (Generic)

import Data.Text qualified as T
import Data.UUID qualified as UUID

import Core.Domain.Money (Money)
import Core.Domain.Partner (PartnerId)
import Core.Domain.User (UserId)

-- | doc/labor_management.md §1.1
data EmploymentType
  = -- | 正社員 (IAS19、既存 Core.Domain.EmployeeBenefit と直結)
    EmploymentFullTime
  | -- | 契約社員
    EmploymentFixedTerm
  | -- | 業務委託・外注（個人）
    EmploymentContractor
  | -- | 外注（法人）
    EmploymentCorporateVendor
  deriving (Bounded, Enum, Eq, Generic, Show)

instance ToJSON EmploymentType
instance FromJSON EmploymentType

{- | コンストラクタは型名を冠する — `Core.Domain.User.UserStatus` の
`Active`/`Suspended` と衝突しないようにするため。
-}
data PersonnelStatus
  = PersonnelStatusActive
  | PersonnelStatusSuspended
  | PersonnelStatusDeparted
  deriving (Bounded, Enum, Eq, Generic, Show)

instance ToJSON PersonnelStatus
instance FromJSON PersonnelStatus

newtype PersonnelId = PersonnelId UUID
  deriving (Eq, Ord, Show)

instance ToJSON PersonnelId where
  toJSON (PersonnelId u) = toJSON (UUID.toString u)

instance FromJSON PersonnelId where
  parseJSON = withText "PersonnelId" $ \t ->
    case UUID.fromString (T.unpack t) of
      Just u -> pure (PersonnelId u)
      Nothing -> fail ("invalid UUID: " <> T.unpack t)

-- | doc/labor_management.md §1.1
data Personnel = Personnel
  { personnelId :: PersonnelId
  , personnelName :: Text
  , personnelEmploymentType :: EmploymentType
  , personnelPartnerRef :: Maybe PartnerId
  {- ^ `EmploymentContractor`/`EmploymentCorporateVendor` の場合、
  既存 Core.Domain.Partner への参照
  -}
  , personnelUserRef :: Maybe UserId
  -- ^ §0.1 の弱い関連。owlv にログインする人物の場合のみ Just
  , personnelStatus :: PersonnelStatus
  }
  deriving (Eq, Generic, Show)

instance ToJSON Personnel
instance FromJSON Personnel

-- | doc/labor_management.md §1.2
data PayBasis
  = PayMonthlySalary Money
  | PayDailyRate Money
  | -- | 件当たり（背景1枚いくら、等）
    PayPieceRate Money
  | -- | 売上分配率（0以上1以下、ライセンス収益の分配等）
    PayRevenueShare Decimal
  deriving (Eq, Show)

instance ToJSON PayBasis where
  toJSON (PayMonthlySalary m) = object ["tag" .= ("PayMonthlySalary" :: Text), "amount" .= m]
  toJSON (PayDailyRate m) = object ["tag" .= ("PayDailyRate" :: Text), "amount" .= m]
  toJSON (PayPieceRate m) = object ["tag" .= ("PayPieceRate" :: Text), "amount" .= m]
  toJSON (PayRevenueShare r) =
    object ["tag" .= ("PayRevenueShare" :: Text), "rate" .= show r]

instance FromJSON PayBasis where
  parseJSON = withObject "PayBasis" $ \o -> do
    tag <- o .: "tag"
    case (tag :: Text) of
      "PayMonthlySalary" -> PayMonthlySalary <$> o .: "amount"
      "PayDailyRate" -> PayDailyRate <$> o .: "amount"
      "PayPieceRate" -> PayPieceRate <$> o .: "amount"
      "PayRevenueShare" -> do
        rStr <- o .: "rate"
        case reads (T.unpack rStr) of
          [(d, "")] -> pure (PayRevenueShare d)
          _ -> fail ("invalid Decimal (PayRevenueShare rate): " <> T.unpack rStr)
      _ -> fail ("unknown PayBasis tag: " <> T.unpack tag)

newtype ContractTermId = ContractTermId UUID
  deriving (Eq, Ord, Show)

instance ToJSON ContractTermId where
  toJSON (ContractTermId u) = toJSON (UUID.toString u)

instance FromJSON ContractTermId where
  parseJSON = withText "ContractTermId" $ \t ->
    case UUID.fromString (T.unpack t) of
      Just u -> pure (ContractTermId u)
      Nothing -> fail ("invalid UUID: " <> T.unpack t)

{- | 契約条件 (doc/labor_management.md §1.2)。履行期間ごとに新しい
`ContractTerm` を追記する（書き換えない） — 仕訳行為区分と同じ
「事実は追記、書き換えではない」原則をここにも適用する。
-}
data ContractTerm = ContractTerm
  { ctId :: ContractTermId
  , ctPersonnel :: PersonnelId
  , ctPayBasis :: PayBasis
  , ctEffectiveFrom :: Day
  , ctEffectiveTo :: Maybe Day
  }
  deriving (Eq, Generic, Show)

instance ToJSON ContractTerm
instance FromJSON ContractTerm
