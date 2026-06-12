{- | 組織ごとのアクセス権限スコープ。
AccountScope は仕訳で使える勘定科目の制限、ScreenScope は画面アクセスの制限。
権限セットが空のとき＝制限なし（全許可）。
1つでも登録された瞬間にホワイトリスト制に切り替わる。
-}
module Core.Domain.OrgPermission
  ( PermScope (..)
  ) where

import Data.Text (Text)

import Core.Domain.AccountCode (AccountCode)

data PermScope
  = AccountScope AccountCode -- 使用可能な勘定科目
  | ScreenScope Text -- アクセス可能な画面タグ
  deriving (Eq, Ord, Show)
