{- | テナント（事業者単位）ドメイン型 (doc/tenant_isolation.md)

会計帳簿が分離される事業者単位。`Organisation`（同一Tenant内の部門階層）や
`AccountingPeriod` の親となる境界。1つの `AppBook` フォールドは常に1つの
Tenant の射影であり、`TenantCreated` がそのストリームの先頭イベントになる
(doc/tenant_isolation.md §4)。

`TenantId` の物理的な発行・一意性検証（UUIDv7等）は Shell/Postgres側の責務
であり、ここでは空文字列のみを拒否する。
-}
module Core.Domain.Tenant
  ( TenantId (..)
  , mkTenantId
  , TenantStatus (..)
  , TenantKind (..)
  , Tenant (..)
  , defaultTenantId
  ) where

import Data.Aeson (FromJSON (..), FromJSONKey, ToJSON (..), ToJSONKey)
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import GHC.Generics (Generic)

import Data.Text qualified as T

newtype TenantId = TenantId {unTenantId :: Text}
  deriving (Eq, Ord, Show)

instance ToJSON TenantId where
  toJSON = toJSON . unTenantId

instance FromJSON TenantId where
  parseJSON = fmap TenantId . parseJSON

-- | userTenantRoles :: Map TenantId Role (Core.Domain.User) を JSON 化するために必要。
deriving newtype instance ToJSONKey TenantId

deriving newtype instance FromJSONKey TenantId

mkTenantId :: Text -> Either Text TenantId
mkTenantId t
  | T.null t = Left "テナントコードは空にできません"
  | otherwise = Right (TenantId t)

{- | TenantStatus のコンストラクタは "Tenant" を冠する — `Core.Event` の
TenantCreated/TenantSuspended/TenantArchived（イベント）と名前が衝突しない
ようにするため（doc/tenant_isolation.md §4 の決定: 両者は別の名前空間）。
-}
data TenantStatus = TenantStatusActive | TenantStatusSuspended | TenantStatusArchived
  deriving (Bounded, Enum, Eq, Generic, Show)

instance ToJSON TenantStatus
instance FromJSON TenantStatus

-- | 連結対象の子会社Tenant群を持つ場合は ConsolidationTenant (doc/tenant_isolation.md §4.3)。
data TenantKind
  = StandaloneTenant
  | ConsolidationTenant (NonEmpty TenantId)
  deriving (Eq, Generic, Show)

instance ToJSON TenantKind
instance FromJSON TenantKind

data Tenant = Tenant
  { tenantId :: TenantId
  , tenantName :: Text
  , tenantStatus :: TenantStatus
  , tenantKind :: TenantKind
  }
  deriving (Eq, Generic, Show)

instance ToJSON Tenant
instance FromJSON Tenant

{- | Stage 1（doc/tenant_isolation.md の段階的実装）の暫定値。
EventStore がまだ単一ストリームであり、Shell側にTenant選択UIがないため、
ブートストラップ時の唯一のTenantとして使う。forTenant/identityStore による
物理的なストリーム分離（Stage 2）が入ったら撤去する。
-}

-- Postgres側の tenant_id 列が UUID 型 (doc/tenant_isolation.md §6.1) のため、
-- 妥当な UUID 文字列である必要がある。
defaultTenantId :: TenantId
defaultTenantId = TenantId "00000000-0000-0000-0000-000000000001"
