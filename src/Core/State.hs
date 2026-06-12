module Core.State
  ( JournalBook (..)
  , initialJournalBook
  , MasterBook (..)
  , initialMasterBook
  , CashBook (..)
  , initialCashBook
  , PeriodsBook (..)
  , initialPeriodsBook
  , AssetBook (..)
  , initialAssetBook
  , EclBook (..)
  , initialEclBook
  , FxBook (..)
  , initialFxBook
  , JudgmentLogBook (..)
  , initialJudgmentLogBook
  , BenefitBook (..)
  , initialBenefitBook
  , TaxBook (..)
  , initialTaxBook
  , AppBook (..)
  , initialAppBook
  ) where

import Data.Map.Strict (Map)
import Data.Set (Set)

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set

import Core.Domain.AccountCode (AccountCode)
import Core.Domain.AccountMaster (AccountMaster)
import Core.Domain.AccountingPeriod (AccountingPeriodId, PeriodStatus)
import Core.Domain.CashTransaction (CashTransaction, CashTransactionId)
import Core.Domain.Ecl (EclMeasurement, EclMeasurementId)
import Core.Domain.EmployeeBenefit (BenefitLiability, BenefitLiabilityId)
import Core.Domain.FixedAsset (ComponentId, FixedAsset, FixedAssetId)
import Core.Domain.FxRate (FxRate, FxRateId)
import Core.Domain.Journal (JournalEntry, JournalEntryId)
import Core.Domain.JudgmentLog (JudgmentLog, JudgmentLogId)
import Core.Domain.Money (Money)
import Core.Domain.OrgPermission (PermScope)
import Core.Domain.Organisation (Organisation, OrganisationId)
import Core.Domain.Partner (Partner, PartnerId)
import Core.Domain.Reconciliation (Reconciliation, ReconciliationId)
import Core.Domain.SubAccount (SubAccount, SubAccountId)
import Core.Domain.Tax (TaxEntry, TaxEntryId)

newtype JournalBook = JournalBook
  { journalEntries :: Map JournalEntryId JournalEntry
  }
  deriving (Eq, Show)

initialJournalBook :: JournalBook
initialJournalBook = JournalBook Map.empty

data MasterBook = MasterBook
  { masterOrgs :: Map OrganisationId Organisation
  , masterPartners :: Map PartnerId Partner
  , masterAccounts :: Map AccountCode AccountMaster
  , masterSubAccounts :: Map SubAccountId SubAccount
  , orgPermissions :: Map OrganisationId (Set PermScope)
  {- ^ 組織ごとの許可スコープ。空セット = 制限なし（全許可）。
  1件でも登録するとホワイトリスト制になる。
  -}
  }
  deriving (Eq, Show)

initialMasterBook :: MasterBook
initialMasterBook =
  MasterBook Map.empty Map.empty Map.empty Map.empty Map.empty

-- | 入出金・消込の読みモデル
data CashBook = CashBook
  { cashTransactions :: Map CashTransactionId CashTransaction
  , reconciliations :: Map ReconciliationId Reconciliation
  , reversedRecs :: Set ReconciliationId
  -- ^ 取消済み消込。decide で重複取消を防ぐ。
  , openItems :: Map (JournalEntryId, AccountCode) Money
  -- ^ RequiresSettlement 科目の未消込残高。消込で減算、取消で復元。
  }
  deriving (Eq, Show)

initialCashBook :: CashBook
initialCashBook = CashBook Map.empty Map.empty Set.empty Map.empty

-- | 会計期間の締切状態
newtype PeriodsBook = PeriodsBook
  { periodStatus :: Map AccountingPeriodId PeriodStatus
  }
  deriving (Eq, Show)

initialPeriodsBook :: PeriodsBook
initialPeriodsBook = PeriodsBook Map.empty

-- | 固定資産台帳の読みモデル (§2.4)
newtype AssetBook = AssetBook
  { fixedAssets :: Map (FixedAssetId, ComponentId) FixedAsset
  }
  deriving (Eq, Show)

initialAssetBook :: AssetBook
initialAssetBook = AssetBook Map.empty

-- | ECL測定記録の読みモデル (§4.7.5〜4.7.12)
newtype EclBook = EclBook
  { eclMeasurements :: Map EclMeasurementId EclMeasurement
  }
  deriving (Eq, Show)

initialEclBook :: EclBook
initialEclBook = EclBook Map.empty

-- | 為替レートの読みモデル (§4.7.13)
newtype FxBook = FxBook
  { fxRates :: Map FxRateId FxRate
  }
  deriving (Eq, Show)

initialFxBook :: FxBook
initialFxBook = FxBook Map.empty

-- | 判断ログの読みモデル (§5)
newtype JudgmentLogBook = JudgmentLogBook
  { judgmentLogs :: Map JudgmentLogId JudgmentLog
  }
  deriving (Eq, Show)

initialJudgmentLogBook :: JudgmentLogBook
initialJudgmentLogBook = JudgmentLogBook Map.empty

-- | 従業員給付負債の読みモデル (§4.7.15)
newtype BenefitBook = BenefitBook
  { benefitLiabilities :: Map BenefitLiabilityId BenefitLiability
  }
  deriving (Eq, Show)

initialBenefitBook :: BenefitBook
initialBenefitBook = BenefitBook Map.empty

-- | 法人所得税の読みモデル (§4.7.16)
newtype TaxBook = TaxBook
  { taxEntries :: Map TaxEntryId TaxEntry
  }
  deriving (Eq, Show)

initialTaxBook :: TaxBook
initialTaxBook = TaxBook Map.empty

data AppBook = AppBook
  { appJournals :: JournalBook
  , appMasters :: MasterBook
  , appCash :: CashBook
  , appPeriods :: PeriodsBook
  , appAssets :: AssetBook
  , appEcl :: EclBook
  , appFx :: FxBook
  , appJudgmentLogs :: JudgmentLogBook
  , appBenefits :: BenefitBook
  , appTax :: TaxBook
  }
  deriving (Eq, Show)

initialAppBook :: AppBook
initialAppBook =
  AppBook
    initialJournalBook
    initialMasterBook
    initialCashBook
    initialPeriodsBook
    initialAssetBook
    initialEclBook
    initialFxBook
    initialJudgmentLogBook
    initialBenefitBook
    initialTaxBook
