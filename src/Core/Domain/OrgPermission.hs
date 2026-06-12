{- | 組織ごとのアクセス権限スコープ。
AccountScope は仕訳で使える勘定科目の制限、ScreenScope は画面アクセスの制限。
権限セットが空のとき＝制限なし（全許可）。
1つでも登録された瞬間にホワイトリスト制に切り替わる。
-}
module Core.Domain.OrgPermission
  ( PermScope (..)
  ) where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.=))
import Data.Text (Text)

import Data.Text qualified as T

import Core.Domain.AccountCode (AccountCode)

data PermScope
  = AccountScope AccountCode -- 使用可能な勘定科目
  | ScreenScope Text -- アクセス可能な画面タグ
  deriving (Eq, Ord, Show)

instance ToJSON PermScope where
  toJSON (AccountScope ac) = object ["tag" .= ("AccountScope" :: Text), "code" .= ac]
  toJSON (ScreenScope s) = object ["tag" .= ("ScreenScope" :: Text), "screen" .= s]

instance FromJSON PermScope where
  parseJSON = withObject "PermScope" $ \o -> do
    tag <- o .: "tag"
    case (tag :: Text) of
      "AccountScope" -> AccountScope <$> o .: "code"
      "ScreenScope" -> ScreenScope <$> o .: "screen"
      _ -> fail ("unknown PermScope tag: " <> T.unpack tag)
