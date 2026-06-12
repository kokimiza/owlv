-- | エラーメッセージカタログ。
-- 文言テンプレートを Map に保持し、起動時に一度だけロードする。
-- renderDomainError / renderAppError はpureなのでテストが容易。
-- IO 境界はカタログロードの一点（App.hs の初期化）に限定される。
module Shell.ErrorCatalog
  ( ErrorKey (..)
  , ErrorCatalog
  , defaultCatalog
  , renderDomainError
  , renderAppError
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Data.UUID (toText)

import Core.Domain.AccountCode (unAccountCode)
import Core.Domain.Journal (JournalEntryId (..))
import Core.Domain.Money (unMoney)
import Core.Domain.OrgPermission (PermScope (..))
import Core.Domain.Organisation (OrganisationId (..))
import Core.Error (DomainError (..))
import Shell.AppError (AppError (..))

-- | カタログキー — DomainError コンストラクタ + Shell レベルエラーに 1 対 1 対応。
data ErrorKey
  = EKUnbalancedEntry
  | EKCorrectionMissingPriorRef
  | EKPendingVoucherMissingMemo
  | EKDuplicateEntryId
  | EKOrgNotFound
  | EKOrgPermissionDenied
  | EKPermissionAlreadyGranted
  | EKPermissionNotFound
  | EKDuplicateMasterCode
  | EKMasterNotFound
  | EKEmptyMasterField
  | EKStorageError
  | EKConnectionError
  | EKNotFound
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | テンプレート Map。{0}, {1} … をパラメータで置換する。
newtype ErrorCatalog = ErrorCatalog (Map ErrorKey Text)
  deriving (Eq, Show)

-- | デフォルトカタログ（日本語）。
-- 将来は JSON/YAML ファイルからロードするか、UI 設定で差し替える。
defaultCatalog :: ErrorCatalog
defaultCatalog = ErrorCatalog $ Map.fromList
  [ (EKUnbalancedEntry,           "借貸不一致: 借方={0} 貸方={1}")
  , (EKCorrectionMissingPriorRef, "訂正仕訳に先行仕訳参照IDがありません: {0}")
  , (EKPendingVoucherMissingMemo, "証憑未着仕訳に摘要（根拠・到着予定日）が必要です")
  , (EKDuplicateEntryId,          "仕訳IDが重複しています: {0}")
  , (EKOrgNotFound,               "入力部門が存在しません: {0}")
  , (EKOrgPermissionDenied,       "部門 {0} は {1} の権限がありません")
  , (EKPermissionAlreadyGranted,  "部門 {0} には既に {1} の権限があります")
  , (EKPermissionNotFound,        "部門 {0} に {1} の権限はありません")
  , (EKDuplicateMasterCode,       "{0}コードが既に登録済みです: {1}")
  , (EKMasterNotFound,            "{0}が見つかりません: {1}")
  , (EKEmptyMasterField,          "{0}は必須です")
  , (EKStorageError,              "保存エラー: {0}")
  , (EKConnectionError,           "接続エラー: {0}")
  , (EKNotFound,                  "未検出: {0}")
  ]

-- | Pure render: DomainError → Text（カタログ参照）。
renderDomainError :: ErrorCatalog -> DomainError -> Text
renderDomainError cat err =
  let (key, params) = domainErrorKey err
  in applyTemplate cat key params

-- | Pure render: AppError → Text（カタログ参照）。
-- AppInputError は mk* バリデータが生成する簡易文言をそのまま返す。
renderAppError :: ErrorCatalog -> AppError -> Text
renderAppError cat (AppDomainError de)    = renderDomainError cat de
renderAppError _   (AppInputError  t)     = t
renderAppError cat (AppStorageError t)    = applyTemplate cat EKStorageError [t]
renderAppError cat (AppConnectionError t) = applyTemplate cat EKConnectionError [t]
renderAppError cat (AppNotFound t)        = applyTemplate cat EKNotFound [t]

-- ── internals ────────────────────────────────────────────────────────────────

domainErrorKey :: DomainError -> (ErrorKey, [Text])
domainErrorKey (UnbalancedEntry dr cr) =
  (EKUnbalancedEntry, [T.pack (show (unMoney dr)), T.pack (show (unMoney cr))])
domainErrorKey (CorrectionMissingPriorRef at) =
  (EKCorrectionMissingPriorRef, [T.pack (show at)])
domainErrorKey PendingVoucherMissingMemo =
  (EKPendingVoucherMissingMemo, [])
domainErrorKey (DuplicateEntryId (JournalEntryId uuid)) =
  (EKDuplicateEntryId, [toText uuid])
domainErrorKey (OrgNotFound (OrganisationId oid)) =
  (EKOrgNotFound, [oid])
domainErrorKey (OrgPermissionDenied (OrganisationId oid) scope) =
  (EKOrgPermissionDenied, [oid, renderScope scope])
domainErrorKey (PermissionAlreadyGranted (OrganisationId oid) scope) =
  (EKPermissionAlreadyGranted, [oid, renderScope scope])
domainErrorKey (PermissionNotFound (OrganisationId oid) scope) =
  (EKPermissionNotFound, [oid, renderScope scope])
domainErrorKey (DuplicateMasterCode kind code) =
  (EKDuplicateMasterCode, [kind, code])
domainErrorKey (MasterNotFound kind code) =
  (EKMasterNotFound, [kind, code])
domainErrorKey (EmptyMasterField field) =
  (EKEmptyMasterField, [field])

renderScope :: PermScope -> Text
renderScope (AccountScope ac) = "勘定科目[" <> unAccountCode ac <> "]"
renderScope (ScreenScope tag) = "画面[" <> tag <> "]"

applyTemplate :: ErrorCatalog -> ErrorKey -> [Text] -> Text
applyTemplate (ErrorCatalog m) k ps =
  substitute (Map.findWithDefault (T.pack (show k)) k m) ps

-- | {0}, {1} … をパラメータで置換する。
substitute :: Text -> [Text] -> Text
substitute t ps = foldl' replaceOne t (zip [0 :: Int ..] ps)
  where
    replaceOne acc (i, v) = T.replace ("{" <> T.pack (show i) <> "}") v acc
