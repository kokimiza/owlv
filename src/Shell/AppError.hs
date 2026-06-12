{- | Shell-layer error type.
構造化データ（型＋パラメータ）のみを運ぶ。文言は Shell.ErrorCatalog が担う。
-}
module Shell.AppError
  ( AppError (..)
  , fromDomainError
  ) where

import Data.Text (Text)

import Core.Error (DomainError)

data AppError
  = AppDomainError DomainError -- Core ドメイン違反（ErrorCatalog で描画）
  | AppInputError Text -- UI 入力パース失敗（mk* バリデータ由来）
  | AppStorageError Text -- DB / シリアライズエラー
  | AppConnectionError Text -- ネットワーク / ファイルエラー
  | AppNotFound Text
  | -- | 楽観ロック競合; executeCommand がリトライ上限超過時に返す
    AppConcurrencyConflict
  deriving (Eq, Show)

fromDomainError :: DomainError -> AppError
fromDomainError = AppDomainError
