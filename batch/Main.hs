module Main (main) where

import Effectful
import Options.Applicative
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn, stderr)

import Data.Text qualified as T

import Batch.DailyClose (dailyClose)
import Batch.Env (BatchEffs, errorToCode, loadBatchEnv, runBatch)
import Batch.VacuumCheck (vacuumCheck)
import Batch.WalShip (walShip)
import Shell.AppError (AppError (..))

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

main :: IO ()
main = do
  cmd <- execParser opts
  envResult <- loadBatchEnv
  case envResult of
    Left err -> do
      hPutStrLn stderr ("起動エラー: " <> renderError err)
      exitWith (ExitFailure 99)
    Right env -> do
      result <- runBatch env (dispatch cmd)
      case result of
        Left err -> do
          hPutStrLn stderr ("バッチエラー: " <> renderError err)
          exitWith (ExitFailure (errorToCode err))
        Right ec -> exitWith ec

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
