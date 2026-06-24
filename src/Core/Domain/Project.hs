{- | プロジェクト管理ドメイン型 (doc/project_management.md)

owlv の4機能領域のうち、唯一の事実の発生源 (doc/project_management.md §0.1
「単一発生源・多重確定」)。`Project` は商品マスタの代替であり、固有名詞
(`projectName`) を正規化・コード化しない —— マスタ管理コストを生むため
(doc/project_management.md §0.2)。

`ProjectStatus`/`ProjectLifecycle` のコンストラクタは型名を冠する —
`Core.Domain.Tenant.TenantStatus` と同じ理由（`Core.Event` の
`ProjectOpened`/`ProjectClosed` 等のイベント名と衝突しないようにするため）。
-}
module Core.Domain.Project
  ( ProjectId (..)
  , ProjectLifecycle (..)
  , ProjectStatus (..)
  , Project (..)
  , ProjectPhaseId (..)
  , ProjectPhase (..)
  ) where

import Data.Aeson (FromJSON (..), ToJSON (..), withText)
import Data.Text (Text)
import Data.Time (Day)
import Data.UUID (UUID)
import GHC.Generics (Generic)

import Data.Text qualified as T
import Data.UUID qualified as UUID

import Core.Domain.Money (Money)
import Core.Domain.Organisation (OrganisationId)
import Core.Domain.Partner (PartnerId)
import Core.Domain.Tenant (TenantId)

newtype ProjectId = ProjectId UUID
  deriving (Eq, Ord, Show)

instance ToJSON ProjectId where
  toJSON (ProjectId u) = toJSON (UUID.toString u)

instance FromJSON ProjectId where
  parseJSON = withText "ProjectId" $ \t ->
    case UUID.fromString (T.unpack t) of
      Just u -> pure (ProjectId u)
      Nothing -> fail ("invalid UUID: " <> T.unpack t)

-- | doc/project_management.md §1.1
data ProjectLifecycle
  = -- | アニメ制作・建設工事等。複数会計期間にわたる
    ProjectLifecycleLongRunning
  | -- | グッズ販売・ライセンス決済等。即時に開いて閉じる (§6)
    ProjectLifecycleSingleTransaction
  deriving (Bounded, Enum, Eq, Generic, Show)

instance ToJSON ProjectLifecycle
instance FromJSON ProjectLifecycle

data ProjectStatus
  = ProjectStatusOpen
  | ProjectStatusInProgress
  | ProjectStatusClosed
  | ProjectStatusCancelled
  deriving (Bounded, Enum, Eq, Generic, Show)

instance ToJSON ProjectStatus
instance FromJSON ProjectStatus

-- | doc/project_management.md §1.1
data Project = Project
  { projectId :: ProjectId
  , projectTenant :: TenantId
  , projectOrg :: OrganisationId
  , projectName :: Text
  -- ^ 自由記述。マスタ化しない (doc/project_management.md §0.2)。
  , projectLifecycle :: ProjectLifecycle
  , projectStatus :: ProjectStatus
  , projectCustomer :: Maybe PartnerId
  , projectBudgetTotal :: Money
  , projectOpenedDate :: Day
  , projectExpectedEndDate :: Maybe Day
  }
  deriving (Eq, Generic, Show)

instance ToJSON Project
instance FromJSON Project

newtype ProjectPhaseId = ProjectPhaseId UUID
  deriving (Eq, Ord, Show)

instance ToJSON ProjectPhaseId where
  toJSON (ProjectPhaseId u) = toJSON (UUID.toString u)

instance FromJSON ProjectPhaseId where
  parseJSON = withText "ProjectPhaseId" $ \t ->
    case UUID.fromString (T.unpack t) of
      Just u -> pure (ProjectPhaseId u)
      Nothing -> fail ("invalid UUID: " <> T.unpack t)

-- | doc/project_management.md §1.2: 工程・話数単位の予算内訳
data ProjectPhase = ProjectPhase
  { phaseId :: ProjectPhaseId
  , phaseProject :: ProjectId
  , phaseName :: Text
  , phaseBudget :: Money
  , phaseStatus :: ProjectStatus
  }
  deriving (Eq, Generic, Show)

instance ToJSON ProjectPhase
instance FromJSON ProjectPhase
