module Main (main) where

import Data.List (maximumBy)
import Data.Ord (comparing)
import Effectful
import Options.Applicative
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn, stderr)

import Data.Text qualified as T

import Batch.DailyClose (dailyClose)
import Batch.Env (BatchEffs, BatchEnv (..), errorToCode, loadBatchEnvs, runBatch)
import Batch.VacuumCheck (vacuumCheck)
import Batch.WalShip (walShip)
import Core.Domain.Tenant (TenantId, unTenantId)
import Shell.AppError (AppError (..))
import Shell.EventStore (EventStore (esTenant))

data BatchCmd
  = DailyClose
  | WalShip
  | VacuumCheck

parser :: Parser BatchCmd
parser =
  subparser
    ( command "daily-close" (info (pure DailyClose) (progDesc "日次決算クローズ (spec §4)"))
        <> command "wal-ship" (info (pure WalShip) (progDesc "WAL アーカイブ転送"))
        <> command "vacuum-check" (info (pure VacuumCheck) (progDesc "PostgreSQL バキューム遅延確認"))
    )

opts :: ParserInfo BatchCmd
opts =
  info
    (parser <**> helper)
    ( fullDesc
        <> progDesc "owlv バッチコントローラ — ロジック・分岐・エラー処理はすべてここで完結"
        <> header "owlv-batch-center"
    )

{- | doc/tenant_isolation.md §6.6: アクティブな Tenant それぞれに対して
独立に dispatch を実行する。1つの Tenant の失敗が他の Tenant の処理を
止めないよう、全Tenant処理後にまとめて結果を評価する。終了コードは
発生した中で最も重大度の高いもの（cron_batch.md §6 の表の値が大きいほど
重大、ただし 99 が最重大）を採用する。
-}
main :: IO ()
main = do
  cmd <- execParser opts
  envsResult <- loadBatchEnvs
  case envsResult of
    Left err -> do
      hPutStrLn stderr ("起動エラー: " <> renderError err)
      exitWith (ExitFailure 99)
    Right envs -> do
      results <- mapM (runOneTenant cmd) envs
      exitWith (worstExitCode results)

runOneTenant :: BatchCmd -> BatchEnv -> IO ExitCode
runOneTenant cmd env = do
  result <- runBatch env (dispatch cmd)
  case result of
    Left err -> do
      hPutStrLn
        stderr
        ("バッチエラー [tenant=" <> T.unpack (unTenantId (tenantOf env)) <> "]: " <> renderError err)
      pure (ExitFailure (errorToCode err))
    Right ec -> pure ec

tenantOf :: BatchEnv -> TenantId
tenantOf env = esTenant (batchStore env)

{- | 成功 (ExitSuccess) より失敗 (ExitFailure n) を優先し、失敗同士はコードの大きい方を優先する
(cron_batch.md §6: 99 が最重大、6 が最軽微の警告)。
-}
worstExitCode :: [ExitCode] -> ExitCode
worstExitCode [] = ExitSuccess
worstExitCode ecs = maximumBy (comparing rank) ecs
 where
  rank ExitSuccess = (-1)
  rank (ExitFailure n) = n

dispatch :: BatchCmd -> Eff BatchEffs ExitCode
dispatch DailyClose = dailyClose
dispatch WalShip = walShip
dispatch VacuumCheck = vacuumCheck

renderError :: AppError -> String
renderError (AppDomainError e) = "ドメインエラー: " <> show e
renderError (AppInputError msg) = "入力エラー: " <> T.unpack msg
renderError (AppStorageError msg) = "ストレージエラー: " <> T.unpack msg
renderError (AppConnectionError msg) = "接続エラー: " <> T.unpack msg
renderError (AppNotFound msg) = "未検出: " <> T.unpack msg
renderError AppConcurrencyConflict = "楽観ロック競合 (リトライ超過)"
