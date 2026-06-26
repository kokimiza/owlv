{- | 稼働割当・稼働実績ドメイン型 (doc/labor_management.md §1.3, §1.4)

`WorkAssignment` は Project の `ExternalOrderPlaced` を労務人事モジュールが
購読した結果として生成される（または人間が直接作成する）。労務人事モジュール
は Project の状態を書き換えない (doc/labor_management.md §2.2) —— 循環参照を
構造的に排除し、§0.1 の「単一発生源」を保つ。
-}
module Core.Domain.WorkAssignment
  ( WorkAssignmentStatus (..)
  , WorkAssignmentId (..)
  , WorkAssignment (..)
  , TimesheetEntryId (..)
  , TimesheetEntry (..)
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
import Data.Time (Day)
import Data.UUID (UUID)
import GHC.Generics (Generic)

import Data.Text qualified as T
import Data.UUID qualified as UUID

import Core.Domain.ExternalOrder (ExternalOrderId)
import Core.Domain.Personnel (PersonnelId)
import Core.Domain.Project (ProjectId, ProjectPhaseId)
import Core.Domain.User (UserId)

{- | コンストラクタは型名を冠する (doc/project_management.md の ProjectStatus
/ doc/labor_management.md の PersonnelStatus と同じ理由)。
-}
data WorkAssignmentStatus
  = WorkAssignmentStatusAssigned
  | WorkAssignmentStatusInProgress
  | WorkAssignmentStatusCompleted
  | WorkAssignmentStatusCancelled
  deriving (Bounded, Enum, Eq, Generic, Show)

instance ToJSON WorkAssignmentStatus
instance FromJSON WorkAssignmentStatus

newtype WorkAssignmentId = WorkAssignmentId UUID
  deriving (Eq, Ord, Show)

instance ToJSON WorkAssignmentId where
  toJSON (WorkAssignmentId u) = toJSON (UUID.toString u)

instance FromJSON WorkAssignmentId where
  parseJSON = withText "WorkAssignmentId" $ \t ->
    case UUID.fromString (T.unpack t) of
      Just u -> pure (WorkAssignmentId u)
      Nothing -> fail ("invalid UUID: " <> T.unpack t)

-- | doc/labor_management.md §1.3
data WorkAssignment = WorkAssignment
  { waId :: WorkAssignmentId
  , waPersonnel :: PersonnelId
  , waProject :: ProjectId
  , waPhase :: Maybe ProjectPhaseId
  , waExternalOrder :: Maybe ExternalOrderId
  -- ^ doc/labor_management.md §2.1: ExternalOrderPlaced から自動生成される場合
  , waAssignedDate :: Day
  , waStatus :: WorkAssignmentStatus
  }
  deriving (Eq, Generic, Show)

instance ToJSON WorkAssignment
instance FromJSON WorkAssignment

newtype TimesheetEntryId = TimesheetEntryId UUID
  deriving (Eq, Ord, Show)

instance ToJSON TimesheetEntryId where
  toJSON (TimesheetEntryId u) = toJSON (UUID.toString u)

instance FromJSON TimesheetEntryId where
  parseJSON = withText "TimesheetEntryId" $ \t ->
    case UUID.fromString (T.unpack t) of
      Just u -> pure (TimesheetEntryId u)
      Nothing -> fail ("invalid UUID: " <> T.unpack t)

{- | 稼働実績 (doc/labor_management.md §1.4)。`PayBasis` が `PayPieceRate` 等の
場合は必須ではない —— `ExternalOrder` の検収確認がそのまま完了の事実になる
ケースが多く、重複入力を強制しない。
-}
data TimesheetEntry = TimesheetEntry
  { tsId :: TimesheetEntryId
  , tsAssignment :: WorkAssignmentId
  , tsDate :: Day
  , tsHours :: Maybe Decimal
  , tsQuantity :: Maybe Int
  , tsRecordedBy :: UserId
  }
  deriving (Eq, Generic, Show)

instance ToJSON TimesheetEntry where
  toJSON e =
    object
      [ "tsId" .= tsId e
      , "tsAssignment" .= tsAssignment e
      , "tsDate" .= tsDate e
      , "tsHours" .= fmap show (tsHours e)
      , "tsQuantity" .= tsQuantity e
      , "tsRecordedBy" .= tsRecordedBy e
      ]

instance FromJSON TimesheetEntry where
  parseJSON = withObject "TimesheetEntry" $ \o -> do
    hoursStr <- o .: "tsHours"
    hours <- case hoursStr of
      Nothing -> pure Nothing
      Just s -> case reads (T.unpack s) of
        [(d, "")] -> pure (Just d)
        _ -> fail ("invalid Decimal (tsHours): " <> T.unpack s)
    TimesheetEntry
      <$> o .: "tsId"
      <*> o .: "tsAssignment"
      <*> o .: "tsDate"
      <*> pure hours
      <*> o .: "tsQuantity"
      <*> o .: "tsRecordedBy"
