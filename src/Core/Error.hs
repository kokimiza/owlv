module Core.Error
  ( DomainError (..)
  ) where

import Data.Text (Text)

import Core.Domain.Journal (JournalActionType, JournalEntryId)
import Core.Domain.Money (Money)
import Core.Domain.OrgPermission (PermScope)
import Core.Domain.Organisation (OrganisationId)

data DomainError
  = -- | 借貸不一致 (§4.1)
    UnbalancedEntry Money Money
  | -- | 訂正仕訳に先行仕訳参照IDがない (§4.1, §4.4)
    CorrectionMissingPriorRef JournalActionType
  | -- | 証憑未着なのに摘要が空 (§4.1)
    PendingVoucherMissingMemo
  | -- | 同一IDの仕訳が既に登録済み
    DuplicateEntryId JournalEntryId
  | -- | 入力部門が存在しない
    OrgNotFound OrganisationId
  | -- | 入力部門が対象スコープの権限を持たない
    OrgPermissionDenied OrganisationId PermScope
  | -- | 権限付与対象のスコープが既に付与済み
    PermissionAlreadyGranted OrganisationId PermScope
  | -- | 権限剥奪対象のスコープが存在しない
    PermissionNotFound OrganisationId PermScope
  | -- | マスタコードが既に存在する
    DuplicateMasterCode Text Text
  | -- | マスタコードが存在しない（更新時）
    MasterNotFound Text Text
  | -- | 必須フィールドが空
    EmptyMasterField Text
  deriving (Eq, Show)
