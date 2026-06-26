{- | 管理会計ドメイン型 (doc/management_accounting.md)

`KpiThreshold` は財務報告の重要性基準 `Core.Domain.Materiality` とは独立
である (doc/management_accounting.md §0.1) —— 目的の異なる2つの「閾値」
概念を1つの型に統合しない。
-}
module Core.Domain.ManagementAccounting
  ( KpiMetric (..)
  , KpiScope (..)
  , KpiThresholdId (..)
  , KpiThreshold (..)
  , AlertSeverity (..)
  , BudgetAlertId (..)
  , BudgetAlert (..)
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
import Data.Time (Day, UTCTime)
import Data.UUID (UUID)
import GHC.Generics (Generic)

import Data.Text qualified as T
import Data.UUID qualified as UUID

import Core.Domain.ExternalOrder (ExternalOrderId)
import Core.Domain.Project (ProjectId, ProjectPhaseId)
import Core.Domain.Tenant (TenantId)

-- | doc/management_accounting.md §1.2
data KpiMetric
  = -- | 予算消化率（ユーザー提示例: 85%で警告）
    KpiBudgetConsumptionRate
  | -- | 予定工程に対する遅延率
    KpiScheduleVariance
  | -- | Project 単位の粗利率
    KpiGrossMarginRate
  deriving (Bounded, Enum, Eq, Generic, Show)

instance ToJSON KpiMetric
instance FromJSON KpiMetric

-- | doc/management_accounting.md §1.2
data KpiScope
  = KpiScopeProject ProjectId
  | KpiScopePhase ProjectPhaseId
  deriving (Eq, Show)

instance ToJSON KpiScope where
  toJSON (KpiScopeProject pid) = object ["tag" .= ("KpiScopeProject" :: Text), "project" .= pid]
  toJSON (KpiScopePhase phid) = object ["tag" .= ("KpiScopePhase" :: Text), "phase" .= phid]

instance FromJSON KpiScope where
  parseJSON = withObject "KpiScope" $ \o -> do
    tag <- o .: "tag"
    case (tag :: Text) of
      "KpiScopeProject" -> KpiScopeProject <$> o .: "project"
      "KpiScopePhase" -> KpiScopePhase <$> o .: "phase"
      _ -> fail ("unknown KpiScope tag: " <> T.unpack tag)

newtype KpiThresholdId = KpiThresholdId UUID
  deriving (Eq, Ord, Show)

instance ToJSON KpiThresholdId where
  toJSON (KpiThresholdId u) = toJSON (UUID.toString u)

instance FromJSON KpiThresholdId where
  parseJSON = withText "KpiThresholdId" $ \t ->
    case UUID.fromString (T.unpack t) of
      Just u -> pure (KpiThresholdId u)
      Nothing -> fail ("invalid UUID: " <> T.unpack t)

{- | KPI閾値設定 (doc/management_accounting.md §1.2)。「いつ・誰が・どの
基準でアラートを設定したか」を判断ログ統制と同じ思想で追跡可能にするため、
設定自体を `decide`/`evolve` を経た Core の事実として記録する。
-}
data KpiThreshold = KpiThreshold
  { ktId :: KpiThresholdId
  , ktTenant :: TenantId
  , ktMetric :: KpiMetric
  , ktScope :: KpiScope
  , ktWarnAt :: Decimal
  -- ^ 例: 0.85
  , ktCriticalAt :: Maybe Decimal
  -- ^ 例: 1.00（予算超過そのもの）
  , ktEffectiveFrom :: Day
  , ktRetired :: Bool
  -- ^ doc/management_accounting.md §2: 削除ではなく無効化フラグの追記
  }
  deriving (Eq, Show)

instance ToJSON KpiThreshold where
  toJSON t =
    object
      [ "ktId" .= ktId t
      , "ktTenant" .= ktTenant t
      , "ktMetric" .= ktMetric t
      , "ktScope" .= ktScope t
      , "ktWarnAt" .= show (ktWarnAt t)
      , "ktCriticalAt" .= fmap show (ktCriticalAt t)
      , "ktEffectiveFrom" .= ktEffectiveFrom t
      , "ktRetired" .= ktRetired t
      ]

instance FromJSON KpiThreshold where
  parseJSON = withObject "KpiThreshold" $ \o -> do
    warnStr <- o .: "ktWarnAt"
    warnAt <- parseDecimal "ktWarnAt" warnStr
    criticalStr <- o .: "ktCriticalAt"
    criticalAt <- traverse (parseDecimal "ktCriticalAt") criticalStr
    KpiThreshold
      <$> o .: "ktId"
      <*> o .: "ktTenant"
      <*> o .: "ktMetric"
      <*> o .: "ktScope"
      <*> pure warnAt
      <*> pure criticalAt
      <*> o .: "ktEffectiveFrom"
      <*> o .: "ktRetired"

parseDecimal :: (Monad m) => String -> Text -> m Decimal
parseDecimal field s = case reads (T.unpack s) of
  [(d, "")] -> pure d
  _ -> fail ("invalid Decimal (" <> field <> "): " <> T.unpack s)

-- | コンストラクタは型名を冠する（他の Bool 風2値列挙との衝突回避の一貫方針）。
data AlertSeverity = AlertWarning | AlertCritical
  deriving (Bounded, Enum, Eq, Generic, Show)

instance ToJSON AlertSeverity
instance FromJSON AlertSeverity

newtype BudgetAlertId = BudgetAlertId UUID
  deriving (Eq, Ord, Show)

instance ToJSON BudgetAlertId where
  toJSON (BudgetAlertId u) = toJSON (UUID.toString u)

instance FromJSON BudgetAlertId where
  parseJSON = withText "BudgetAlertId" $ \t ->
    case UUID.fromString (T.unpack t) of
      Just u -> pure (BudgetAlertId u)
      Nothing -> fail ("invalid UUID: " <> T.unpack t)

{- | 発行されたアラートの記録 (doc/management_accounting.md §1.3)。
`baCausationOrder` は起因となった `ExternalOrder` への参照——
「なぜこのアラートが出たか」を遡れるようにする因果保持
(doc/project_management.md §5.3 と同じ発想)。
-}
data BudgetAlert = BudgetAlert
  { baId :: BudgetAlertId
  , baThreshold :: KpiThresholdId
  , baProject :: ProjectId
  , baPhase :: Maybe ProjectPhaseId
  , baMetricValue :: Decimal
  , baSeverity :: AlertSeverity
  , baDetectedAt :: UTCTime
  , baCausationOrder :: Maybe ExternalOrderId
  }
  deriving (Eq, Show)

instance ToJSON BudgetAlert where
  toJSON a =
    object
      [ "baId" .= baId a
      , "baThreshold" .= baThreshold a
      , "baProject" .= baProject a
      , "baPhase" .= baPhase a
      , "baMetricValue" .= show (baMetricValue a)
      , "baSeverity" .= baSeverity a
      , "baDetectedAt" .= baDetectedAt a
      , "baCausationOrder" .= baCausationOrder a
      ]

instance FromJSON BudgetAlert where
  parseJSON = withObject "BudgetAlert" $ \o -> do
    valueStr <- o .: "baMetricValue"
    value <- parseDecimal "baMetricValue" valueStr
    BudgetAlert
      <$> o .: "baId"
      <*> o .: "baThreshold"
      <*> o .: "baProject"
      <*> o .: "baPhase"
      <*> pure value
      <*> o .: "baSeverity"
      <*> o .: "baDetectedAt"
      <*> o .: "baCausationOrder"
