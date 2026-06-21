module Batch.Env
  ( BatchEnv (..)
  , BatchEffs
  , loadBatchEnv
  , runBatch
  , errorToCode
  ) where

import Effectful
import Effectful.Error.Static

import Core.Domain.Tenant (defaultTenantId)
import Shell.AppError (AppError (..))
import Shell.Effects (AuditLogEff, ClockEff, EventStoreEff, UserCtxEff)
import Shell.EventStore (EventStore, connectDb, forTenant)
import Shell.Interpreters.AuditLog (runAuditLogNoOp)
import Shell.Interpreters.Clock (runClockReal)
import Shell.Interpreters.EventStore (runEventStorePg)
import Shell.Interpreters.UserContext (runUserCtxFixed)

newtype BatchEnv = BatchEnv
  { batchStore :: EventStore
  }

{- | 本番バッチで使うエフェクトスタック。
テスト時はインメモリインタープリタに差し替えて runEff で走らせる。
-}
type BatchEffs =
  '[ EventStoreEff
   , ClockEff
   , UserCtxEff
   , AuditLogEff
   , Error AppError
   , IOE
   ]

{- | Stage 2（doc/tenant_isolation.md §6.6）: 現状は defaultTenantId 1本に
固定。複数Tenantを処理対象にする場合は Tenant一覧を読み、各Tenantごとに
forTenant したハンドルでループする形に拡張する（未実装）。
-}
loadBatchEnv :: IO (Either AppError BatchEnv)
loadBatchEnv = do
  connResult <- connectDb
  case connResult of
    Left err -> pure (Left err)
    Right conn -> fmap BatchEnv <$> forTenant conn defaultTenantId

{- | 本番インタープリタスタックでバッチジョブを走らせる。
UserCtx は "batch" 固定。PG バッチロール整備後は runUserCtxPg に切替。
-}
runBatch :: BatchEnv -> Eff BatchEffs a -> IO (Either AppError a)
runBatch env action = do
  result <-
    runEff
      . runError @AppError
      . runAuditLogNoOp
      . runUserCtxFixed "batch"
      . runClockReal
      . runEventStorePg (batchStore env)
      $ action
  pure $ case result of
    Left (_, err) -> Left err
    Right v -> Right v

{- | AppError を cron が判断できる終了コードに変換する。
0 は成功専用。1–6 はエラー種別。99 は起動失敗（main で直接使用）。
-}
errorToCode :: AppError -> Int
errorToCode (AppDomainError _) = 1
errorToCode (AppInputError _) = 2
errorToCode (AppStorageError _) = 3
errorToCode (AppConnectionError _) = 4
errorToCode (AppNotFound _) = 5
errorToCode AppConcurrencyConflict = 6
