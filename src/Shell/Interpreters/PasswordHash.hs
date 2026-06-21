{- | Argon2id パスワードハッシュ (doc/user.md §2.3)

owlv の userPasswordHash は SSH 認証の代替ではなく、アプリ内のステップアップ
確認専用 (画面承認直前の再入力等)。ハッシュ計算は副作用なので Shell が
ここで事前に計算し、ハッシュ済みの値だけを Core (SetUserPasswordHash) に渡す
(sandwich pattern)。

crypton の Crypto.KDF.Argon2 は libargon2 リファレンス実装を同梱ビルドするため
外部Cライブラリの事前インストールは不要 (doc/user.md §2.3 脚注)。
-}
module Shell.Interpreters.PasswordHash
  ( hashPassword
  , verifyPassword
  ) where

import Crypto.Error (CryptoFailable (..))
import Crypto.Random.Entropy (getEntropy)
import Data.ByteArray.Encoding (Base (Base64), convertFromBase, convertToBase)
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8, encodeUtf8)

import Crypto.KDF.Argon2 qualified as Argon2
import Data.ByteArray qualified as BA
import Data.Text qualified as T

argon2Options :: Argon2.Options
argon2Options =
  Argon2.Options
    { Argon2.iterations = 3
    , Argon2.memory = 64 * 1024 -- KiB = 64 MiB
    , Argon2.parallelism = 1
    , Argon2.variant = Argon2.Argon2id
    , Argon2.version = Argon2.Version13
    }

hashOutLen :: Int
hashOutLen = 32

saltLen :: Int
saltLen = 16

-- | 保存形式: "argon2id$<base64 salt>$<base64 hash>"
hashPassword :: Text -> IO Text
hashPassword pw = do
  salt <- getEntropy saltLen :: IO ByteString
  let pwBytes = encodeUtf8 pw :: ByteString
  case Argon2.hash argon2Options pwBytes salt hashOutLen :: CryptoFailable ByteString of
    -- saltLen/hashOutLen は上記の固定値で常に有効範囲内のため到達しない分岐。
    CryptoFailed e -> ioError (userError ("argon2 hash failed: " <> show e))
    CryptoPassed h -> pure ("argon2id$" <> b64 salt <> "$" <> b64 h)

{- | 保存済みハッシュと平文を比較する。フォーマット不正・アルゴリズム不一致は
すべて False（認証拒否）として扱う。比較は固定時間（タイミング攻撃対策）。
-}
verifyPassword :: Text -> Text -> Bool
verifyPassword stored pw = case T.splitOn "$" stored of
  ["argon2id", saltB64, hashB64] ->
    case (unb64 saltB64, unb64 hashB64) of
      (Right salt, Right expected) ->
        let pwBytes = encodeUtf8 pw :: ByteString
            outLen = BA.length (expected :: ByteString)
        in case Argon2.hash argon2Options pwBytes salt outLen :: CryptoFailable ByteString of
             CryptoPassed actual -> BA.constEq actual expected
             CryptoFailed _ -> False
      _ -> False
  _ -> False

b64 :: ByteString -> Text
b64 = decodeUtf8 . convertToBase Base64

unb64 :: Text -> Either String ByteString
unb64 = convertFromBase Base64 . encodeUtf8
