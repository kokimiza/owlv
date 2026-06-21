{- | ユーザードメイン型 (doc/user.md)

owlv アプリ内のユーザーマスタ。OS（AP VM）側の SSH アカウントは
これの一方向プロジェクションであり、ここが単一の真実源 (SSoT)。
-}
module Core.Domain.User
  ( UserId (..)
  , mkUserId
  , Role (..)
  , UserStatus (..)
  , SshPubKey (..)
  , mkSshPubKey
  , OsUid (..)
  , firstOsUid
  , User (..)
  , isActiveAdmin
  , roleInTenant
  , visibleInTenant
  ) where

import Data.Aeson (FromJSON (..), ToJSON (..))
import Data.Map.Strict (Map)
import Data.Text (Text)
import GHC.Generics (Generic)

import Data.Map.Strict qualified as Map
import Data.Text qualified as T

import Core.Domain.Tenant (TenantId)

-- | OS ユーザー名そのもの。一度発行したら不変（doc/user.md §2.1）。
newtype UserId = UserId {unUserId :: Text}
  deriving (Eq, Ord, Show)

instance ToJSON UserId where
  toJSON = toJSON . unUserId

instance FromJSON UserId where
  parseJSON = fmap UserId . parseJSON

{- | POSIX ユーザー名制約 (`useradd` が受理する範囲) を満たすことを検証する。
^[a-z_][a-z0-9_-]*$ かつ 31 文字以内。
-}
mkUserId :: Text -> Either Text UserId
mkUserId t
  | T.null t = Left "ユーザー名は空にできません"
  | T.length t > 31 = Left "ユーザー名は31文字以内にしてください"
  | not (validHead (T.head t)) = Left "ユーザー名は英小文字または _ で始めてください"
  | not (T.all validTail t) = Left "ユーザー名に使えるのは英小文字・数字・_・- のみです"
  | otherwise = Right (UserId t)
 where
  validHead c = (c >= 'a' && c <= 'z') || c == '_'
  validTail c = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-'

data Role
  = Operator -- owl-operators 相当: ForceCommand 直行、シェル不可
  | Maintainer -- owl-maintainers 相当: ksh シェル、参照中心
  | Admin -- owlv 内のユーザー管理コマンドを発行できる役割
  deriving (Bounded, Enum, Eq, Generic, Show)

instance ToJSON Role
instance FromJSON Role

data UserStatus
  = Pending -- 作成イベントは記録されたが OS 同期が未完了
  | Active -- OS 同期成功・SSH 可能
  | Suspended -- 一時停止（OS 側ロック済み・鍵削除済み、削除はしない）
  | Removed -- 削除済み（終端状態。復活は新規 UserId で行う）
  deriving (Bounded, Enum, Eq, Generic, Show)

instance ToJSON UserStatus
instance FromJSON UserStatus

-- | authorized_keys に展開する公開鍵（1行・オプション接頭辞なし）。
newtype SshPubKey = SshPubKey {unSshPubKey :: Text}
  deriving (Eq, Ord, Show)

instance ToJSON SshPubKey where
  toJSON = toJSON . unSshPubKey

instance FromJSON SshPubKey where
  parseJSON = fmap SshPubKey . parseJSON

{- | command=/environment=/permitopen=/no-pty 等のオプション接頭辞を拒否する
(doc/user.md §2.1)。鍵タイプ (ssh-ed25519 等) で始まることのみ要求する。
-}
mkSshPubKey :: Text -> Either Text SshPubKey
mkSshPubKey t
  | T.null (T.strip t) = Left "SSH公開鍵は空にできません"
  | not (any (`T.isPrefixOf` stripped) knownKeyTypes) =
      Left "SSH公開鍵にオプション（command= 等）は使えません。鍵タイプから始めてください"
  | otherwise = Right (SshPubKey stripped)
 where
  stripped = T.strip t
  knownKeyTypes = ["ssh-ed25519", "ssh-rsa", "ecdsa-sha2-", "sk-ssh-ed25519@", "ssh-dss"]

-- | OS UID。Core が単調増加カウンタから明示的に割り当てる (doc/user.md §2.1)。
newtype OsUid = OsUid {unOsUid :: Int}
  deriving (Eq, Ord, Show)

instance ToJSON OsUid where
  toJSON = toJSON . unOsUid

instance FromJSON OsUid where
  parseJSON = fmap OsUid . parseJSON

{- | 最初に割り当てる UID。_owlbatch(800) 等の既存システムアカウント帯と衝突しない
帯から開始する。
-}
firstOsUid :: OsUid
firstOsUid = OsUid 2000

{- | userHomeTenant/userTenantRoles (doc/tenant_isolation.md §5.2):
OS実体に1:1対応する User はTenantをまたいで共有されうるため、`Role` は
User全体ではなく (User, Tenant) の組に持たせる。`userTenantRoles` は
常に `userHomeTenant` をキーとして含む（`decide` で不変条件として強制）。
-}
data User = User
  { userId :: UserId
  , userOsUid :: OsUid
  , userDisplayName :: Text
  , userHomeTenant :: TenantId
  , userTenantRoles :: Map TenantId Role
  , userStatus :: UserStatus
  , userScreenScopes :: [Text] -- 画面アクセス制限（Core.Domain.OrgPermission.PermScope の ScreenScope 相当）
  , userPasswordHash :: Maybe Text -- Argon2id ハッシュ。SSH 認証には使わない (§2.3)
  , userSshPubKeys :: [SshPubKey]
  }
  deriving (Eq, Generic, Show)

instance ToJSON User
instance FromJSON User

-- | 指定Tenantにおけるロール。グラントがなければ Nothing。
roleInTenant :: TenantId -> User -> Maybe Role
roleInTenant tid u = Map.lookup tid (userTenantRoles u)

{- | このUserが指定Tenantの利用者から見えてよいか
(doc/tenant_isolation.md §4.2, infra/vm-db/doc/event-store.md「Identity stream の
Tenant単位の絞り込みはアプリ層で行う」)。Identity stream自体は全Tenant共通の
1本のストリームであり、RLSでは絞り込めない（ログイン解決時点ではどのTenantの
利用者かまだ確定していないため）。そのためアプリ層（ここ）で
「閲覧者の現在Tenantに対するグラントを持つUserだけを見せる」を保証する。
-}
visibleInTenant :: TenantId -> User -> Bool
visibleInTenant tid u = Map.member tid (userTenantRoles u)

{- | ホームテナントで Admin かつ Active であることを判定する（Stage 1 の簡略化:
物理的なTenantストリーム分離前は「ホームテナントの管理者か」で代替する。
doc/tenant_isolation.md §5.2 の本来の意味（操作対象Tenantでの権限判定）は
forTenant導入後、現在のTenantIdを明示的に渡す形に置き換える）。
-}
isActiveAdmin :: User -> Bool
isActiveAdmin u =
  userStatus u == Active && roleInTenant (userHomeTenant u) u == Just Admin
