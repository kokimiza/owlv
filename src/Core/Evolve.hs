module Core.Evolve
  ( evolve
  ) where

import Data.List.NonEmpty (toList)

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set

import Core.Domain.AccountMaster (AccountMaster (..), SettlementBehavior (..))
import Core.Domain.CashTransaction (CashTransaction (..))
import Core.Domain.Ecl (EclMeasurement (..))
import Core.Domain.EmployeeBenefit (BenefitLiability (..))
import Core.Domain.FixedAsset (ComponentId, FixedAsset (..), FixedAssetId)
import Core.Domain.FxRate (FxRate (..))
import Core.Domain.Journal (JournalEntry (..), JournalLine (..), entryId)
import Core.Domain.JudgmentLog (JudgmentLog (..))
import Core.Domain.Money (addMoney, subtractMoney, zeroMoney)
import Core.Domain.Organisation (Organisation (..))
import Core.Domain.Partner (Partner (..))
import Core.Domain.Reconciliation (Reconciliation (..), ReconciliationItem (..))
import Core.Domain.SubAccount (SubAccount (..))
import Core.Domain.Tax (TaxEntry (..))
import Core.Domain.User (OsUid (..), User (..), UserId, UserStatus (..))
import Core.Event (Event (..))
import Core.State
  ( AppBook (..)
  , AssetBook (..)
  , BenefitBook (..)
  , CashBook (..)
  , EclBook (..)
  , FxBook (..)
  , JournalBook (..)
  , JudgmentLogBook (..)
  , MasterBook (..)
  , PeriodsBook (..)
  , TaxBook (..)
  , UserBook (..)
  )

import Core.Domain.AccountingPeriod qualified as AP

evolve :: AppBook -> Event -> AppBook
evolve book (JournalEntryRecorded entry) =
  let book1 =
        book
          { appJournals =
              JournalBook
                (Map.insert (entryId entry) entry (journalEntries (appJournals book)))
          }
      masterAccs = masterAccounts (appMasters book)
      -- RequiresSettlement 科目の行だけ OpenItem に追加
      requiresLines =
        [ l
        | l <- toList (entryLines entry)
        , Just am <- [Map.lookup (lineAccount l) masterAccs]
        , amSettlement am == RequiresSettlement
        ]
      newItems =
        Map.fromListWith
          addMoney
          [ ((entryId entry, lineAccount l), lineAmount l)
          | l <- requiresLines
          ]
  in book1
       { appCash =
           (appCash book1)
             { openItems = Map.unionWith addMoney newItems (openItems (appCash book1))
             }
       }
evolve book (OrganisationRegistered org) =
  updateMasters book (\m -> m{masterOrgs = Map.insert (orgId org) org (masterOrgs m)})
evolve book (OrganisationUpdated org) =
  updateMasters book (\m -> m{masterOrgs = Map.insert (orgId org) org (masterOrgs m)})
evolve book (OrgPermissionGranted oid scope) =
  updateMasters book $ \m ->
    m
      { orgPermissions =
          Map.insertWith Set.union oid (Set.singleton scope) (orgPermissions m)
      }
evolve book (OrgPermissionRevoked oid scope) =
  updateMasters book $ \m ->
    let updated = Map.adjust (Set.delete scope) oid (orgPermissions m)
    in m{orgPermissions = updated}
evolve book (PartnerRegistered p) =
  updateMasters book (\m -> m{masterPartners = Map.insert (partnerId p) p (masterPartners m)})
evolve book (PartnerUpdated p) =
  updateMasters book (\m -> m{masterPartners = Map.insert (partnerId p) p (masterPartners m)})
evolve book (AccountMasterRegistered am) =
  updateMasters book (\m -> m{masterAccounts = Map.insert (amCode am) am (masterAccounts m)})
evolve book (AccountMasterUpdated am) =
  updateMasters book (\m -> m{masterAccounts = Map.insert (amCode am) am (masterAccounts m)})
evolve book (SubAccountRegistered sa) =
  updateMasters book (\m -> m{masterSubAccounts = Map.insert (saId sa) sa (masterSubAccounts m)})
evolve book (SubAccountUpdated sa) =
  updateMasters book (\m -> m{masterSubAccounts = Map.insert (saId sa) sa (masterSubAccounts m)})
evolve book (CashTransactionRecorded ct) =
  book
    { appCash =
        (appCash book)
          { cashTransactions = Map.insert (ctId ct) ct (cashTransactions (appCash book))
          }
    }
evolve book (ReconciliationCreated rec) =
  let cb = appCash book
      -- 各消込明細の金額を OpenItem 残高から減算; ゼロになったキーは削除
      updatedItems = foldl' applyItem (openItems cb) (toList (recItems rec))
      applyItem items ri =
        let key = (riEntryId ri, riAccount ri)
            newBal = subtractMoney (Map.findWithDefault zeroMoney key items) (riAmount ri)
        in if newBal == zeroMoney
             then Map.delete key items
             else Map.insert key newBal items
  in book
       { appCash =
           cb
             { reconciliations = Map.insert (recId rec) rec (reconciliations cb)
             , openItems = updatedItems
             }
       }
evolve book (ReconciliationReversed recId _date) =
  case Map.lookup recId (reconciliations (appCash book)) of
    Nothing -> book -- イベントストアの整合性違反; decide で防いでいる
    Just rec ->
      let cb = appCash book
          -- 消込金額を OpenItem へ戻す
          restoredItems = foldl' restoreItem (openItems cb) (toList (recItems rec))
          restoreItem items ri =
            let key = (riEntryId ri, riAccount ri)
            in Map.insertWith addMoney key (riAmount ri) items
      in book
           { appCash =
               cb
                 { reversedRecs = Set.insert recId (reversedRecs cb)
                 , openItems = restoredItems
                 }
           }
evolve book (AccountingPeriodOpened apId) =
  book
    { appPeriods =
        PeriodsBook (Map.insert apId AP.PeriodOpen (periodStatus (appPeriods book)))
    }
evolve book (AccountingPeriodClosed apId) =
  book
    { appPeriods =
        PeriodsBook (Map.insert apId AP.PeriodClosed (periodStatus (appPeriods book)))
    }
-- ── 固定資産台帳 (§2.4) ─────────────────────────────────────────────────────

evolve book (FixedAssetRegistered fa) =
  updateAssets book (Map.insert (faId fa, faComponent fa) fa)
-- \| 累計償却額に加算する。帳簿価額の計算は carryingAmount 関数が担う。
evolve book (DepreciationRecorded assetId compId _day amount) =
  updateAsset book assetId compId $ \fa ->
    fa{faAccumDepreciation = addMoney (faAccumDepreciation fa) amount}
-- \| 規程 2.4.5: 減損損失累計に加算。
evolve book (ImpairmentRecognized assetId compId _day lossAmount _recoverable) =
  updateAsset book assetId compId $ \fa ->
    fa{faImpairmentCumulative = addMoney (faImpairmentCumulative fa) lossAmount}
-- \| 規程 2.4.5 / IAS 36: 戻入累計に加算。
evolve book (ImpairmentReversalRecognized assetId compId _day amount) =
  updateAsset book assetId compId $ \fa ->
    fa{faImpairmentReversalCumulative = addMoney (faImpairmentReversalCumulative fa) amount}
-- \| 再評価モデル: 総額を再評価額に更新し、累計償却額をリセット。差額をOCI累計へ。
evolve book (AssetRevalued assetId compId _day newGross surplus) =
  updateAsset book assetId compId $ \fa ->
    fa
      { faGrossAmount = newGross
      , faAccumDepreciation = zeroMoney
      , faRevalSurplusCumulative = addMoney (faRevalSurplusCumulative fa) surplus
      }
-- \| 除却: active フラグを落とし除却日を記録する。
evolve book (FixedAssetDisposed assetId compId day) =
  updateAsset book assetId compId $ \fa ->
    fa{faDisposalDate = Just day}
-- ── ECL (§4.7.5〜4.7.12) ────────────────────────────────────────────────────

evolve book (EclMeasurementRecorded m) =
  book
    { appEcl =
        EclBook (Map.insert (eclMeasId m) m (eclMeasurements (appEcl book)))
    }
-- ── 為替レート (§4.7.13) ──────────────────────────────────────────────────

evolve book (FxRateRecorded r) =
  book
    { appFx =
        FxBook (Map.insert (fxRateId r) r (fxRates (appFx book)))
    }
-- ── 判断ログ (§5) ───────────────────────────────────────────────────────────

evolve book (JudgmentLogRecorded l) =
  book
    { appJudgmentLogs =
        JudgmentLogBook (Map.insert (jlId l) l (judgmentLogs (appJudgmentLogs book)))
    }
-- ── 従業員給付 (§4.7.15) ─────────────────────────────────────────────────

evolve book (BenefitLiabilityRecorded b) =
  book
    { appBenefits =
        (appBenefits book)
          { benefitLiabilities =
              Map.insert (blId b) b (benefitLiabilities (appBenefits book))
          }
    }
-- ── 法人所得税 (§4.7.16) ─────────────────────────────────────────────────

evolve book (TaxEntryRecorded t) =
  book
    { appTax =
        TaxBook (Map.insert (teId t) t (taxEntries (appTax book)))
    }
-- ── ユーザー管理 (.claude/user.md §2) ───────────────────────────────────────

evolve book (UserCreated uid uidOs name role scopes) =
  updateUsers book $ \ub ->
    ub
      { users =
          Map.insert
            uid
            User
              { userId = uid
              , userOsUid = uidOs
              , userDisplayName = name
              , userRole = role
              , userStatus = Pending
              , userScreenScopes = scopes
              , userPasswordHash = Nothing
              , userSshPubKeys = []
              }
            (users ub)
      , ubNextUid = OsUid (unOsUid uidOs + 1)
      }
evolve book (UserRoleChanged uid role) =
  updateUsers book $ \ub ->
    ub
      { users = Map.adjust (\u -> u{userRole = role}) uid (users ub)
      , ubPendingEscalations = Map.delete uid (ubPendingEscalations ub)
      }
evolve book (UserRoleEscalationProposed proposer target) =
  updateUsers book $ \ub ->
    ub{ubPendingEscalations = Map.insert target proposer (ubPendingEscalations ub)}
evolve book (UserScopeGranted uid scope) =
  updateUser book uid $ \u ->
    u{userScreenScopes = scope : userScreenScopes u}
evolve book (UserScopeRevoked uid scope) =
  updateUser book uid $ \u ->
    u{userScreenScopes = filter (/= scope) (userScreenScopes u)}
evolve book (UserPasswordChanged uid hash) =
  updateUser book uid $ \u -> u{userPasswordHash = Just hash}
evolve book (UserSshKeyRegistered uid key) =
  updateUser book uid $ \u ->
    if key `elem` userSshPubKeys u
      then u
      else u{userSshPubKeys = key : userSshPubKeys u}
evolve book (UserSuspended uid) =
  updateUser book uid $ \u -> u{userStatus = Suspended}
-- \| 再開は Pending に戻す: Active への遷移は OS 同期成功 (UserOsSyncSucceeded) のみが許される (§2.1)。
evolve book (UserReactivated uid) =
  updateUser book uid $ \u -> u{userStatus = Pending}
evolve book (UserRemoved uid) =
  updateUser book uid $ \u -> u{userStatus = Removed}
evolve book (UserOsSyncSucceeded uid) =
  updateUser book uid $ \u -> u{userStatus = Active}
-- \| 失敗・ドリフト・ログイン観測はイベントストア自体が監査証跡。読みモデルの状態は変えない。
evolve book (UserOsSyncFailed _uid _reason) = book
evolve book (UserOsDriftDetected _uid _detail) = book
evolve book (UserLoginObserved _uid _at _srcIp) = book

-- ── helpers ────────────────────────────────────────────────────────────────

updateMasters :: AppBook -> (MasterBook -> MasterBook) -> AppBook
updateMasters book f = book{appMasters = f (appMasters book)}

updateAssets ::
  AppBook ->
  ( Map.Map (FixedAssetId, ComponentId) FixedAsset ->
    Map.Map (FixedAssetId, ComponentId) FixedAsset
  ) ->
  AppBook
updateAssets book f =
  book{appAssets = AssetBook (f (fixedAssets (appAssets book)))}

{- | 固定資産の特定コンポーネントに対して更新関数を適用する。
イベントストアの整合性は decide が保証しているためKeyが存在しない場合は何もしない。
-}
updateAsset :: AppBook -> FixedAssetId -> ComponentId -> (FixedAsset -> FixedAsset) -> AppBook
updateAsset book assetId compId f =
  updateAssets book (Map.adjust f (assetId, compId))

updateUsers :: AppBook -> (UserBook -> UserBook) -> AppBook
updateUsers book f = book{appUsers = f (appUsers book)}

updateUser :: AppBook -> UserId -> (User -> User) -> AppBook
updateUser book uid f =
  updateUsers book (\ub -> ub{users = Map.adjust f uid (users ub)})
