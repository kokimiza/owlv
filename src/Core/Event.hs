module Core.Event
  ( Event (..)
  ) where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.=))
import Data.Text (Text)
import Data.Time (Day)

import Core.Domain.AccountMaster (AccountMaster)
import Core.Domain.AccountingPeriod (AccountingPeriodId)
import Core.Domain.CashTransaction (CashTransaction)
import Core.Domain.Ecl (EclMeasurement)
import Core.Domain.EmployeeBenefit (BenefitLiability)
import Core.Domain.FixedAsset (ComponentId, FixedAsset, FixedAssetId)
import Core.Domain.FxRate (FxRate)
import Core.Domain.Journal (JournalEntry)
import Core.Domain.JudgmentLog (JudgmentLog)
import Core.Domain.Money (Money)
import Core.Domain.OrgPermission (PermScope)
import Core.Domain.Organisation (Organisation, OrganisationId)
import Core.Domain.Partner (Partner)
import Core.Domain.Reconciliation (Reconciliation, ReconciliationId)
import Core.Domain.SubAccount (SubAccount)
import Core.Domain.Tax (TaxEntry)

data Event
  = JournalEntryRecorded JournalEntry
  | OrganisationRegistered Organisation
  | OrganisationUpdated Organisation
  | OrgPermissionGranted OrganisationId PermScope
  | OrgPermissionRevoked OrganisationId PermScope
  | PartnerRegistered Partner
  | PartnerUpdated Partner
  | AccountMasterRegistered AccountMaster
  | AccountMasterUpdated AccountMaster
  | SubAccountRegistered SubAccount
  | SubAccountUpdated SubAccount
  | -- 入出金・消込・期間
    CashTransactionRecorded CashTransaction
  | ReconciliationCreated Reconciliation
  | -- | 取消日（監査証跡）
    ReconciliationReversed ReconciliationId Day
  | AccountingPeriodOpened AccountingPeriodId
  | AccountingPeriodClosed AccountingPeriodId
  | -- 固定資産台帳 (§2.4) ─────────────────────────────────────────────────
    FixedAssetRegistered FixedAsset
  | -- | 減価償却記録 (日付, 償却額)
    DepreciationRecorded FixedAssetId ComponentId Day Money
  | -- | 減損認識 (日付, 減損損失額, 回収可能価額)
    ImpairmentRecognized FixedAssetId ComponentId Day Money Money
  | -- | 減損戻入 (日付, 戻入額)
    ImpairmentReversalRecognized FixedAssetId ComponentId Day Money
  | -- | 再評価 (日付, 再評価後総額, 再評価差額)
    AssetRevalued FixedAssetId ComponentId Day Money Money
  | -- | 除却
    FixedAssetDisposed FixedAssetId ComponentId Day
  | -- 期待信用損失 (§4.7.5〜4.7.12) ─────────────────────────────────────
    EclMeasurementRecorded EclMeasurement
  | -- 為替レート (§4.7.13) ─────────────────────────────────────────────
    FxRateRecorded FxRate
  | -- 判断ログ (§5) ────────────────────────────────────────────────────
    JudgmentLogRecorded JudgmentLog
  | -- 従業員給付 (§4.7.15) ─────────────────────────────────────────────
    BenefitLiabilityRecorded BenefitLiability
  | -- 法人所得税 (§4.7.16) ─────────────────────────────────────────────
    TaxEntryRecorded TaxEntry
  deriving (Eq, Show)

instance ToJSON Event where
  toJSON (JournalEntryRecorded e) =
    object ["type" .= ("JournalEntryRecorded" :: Text), "data" .= e]
  toJSON (OrganisationRegistered o) =
    object ["type" .= ("OrganisationRegistered" :: Text), "data" .= o]
  toJSON (OrganisationUpdated o) =
    object ["type" .= ("OrganisationUpdated" :: Text), "data" .= o]
  toJSON (OrgPermissionGranted oid ps) =
    object ["type" .= ("OrgPermissionGranted" :: Text), "org" .= oid, "scope" .= ps]
  toJSON (OrgPermissionRevoked oid ps) =
    object ["type" .= ("OrgPermissionRevoked" :: Text), "org" .= oid, "scope" .= ps]
  toJSON (PartnerRegistered p) =
    object ["type" .= ("PartnerRegistered" :: Text), "data" .= p]
  toJSON (PartnerUpdated p) =
    object ["type" .= ("PartnerUpdated" :: Text), "data" .= p]
  toJSON (AccountMasterRegistered am) =
    object ["type" .= ("AccountMasterRegistered" :: Text), "data" .= am]
  toJSON (AccountMasterUpdated am) =
    object ["type" .= ("AccountMasterUpdated" :: Text), "data" .= am]
  toJSON (SubAccountRegistered sa) =
    object ["type" .= ("SubAccountRegistered" :: Text), "data" .= sa]
  toJSON (SubAccountUpdated sa) =
    object ["type" .= ("SubAccountUpdated" :: Text), "data" .= sa]
  toJSON (CashTransactionRecorded ct) =
    object ["type" .= ("CashTransactionRecorded" :: Text), "data" .= ct]
  toJSON (ReconciliationCreated rec) =
    object ["type" .= ("ReconciliationCreated" :: Text), "data" .= rec]
  toJSON (ReconciliationReversed recId date) =
    object ["type" .= ("ReconciliationReversed" :: Text), "id" .= recId, "date" .= date]
  toJSON (AccountingPeriodOpened apId) =
    object ["type" .= ("AccountingPeriodOpened" :: Text), "data" .= apId]
  toJSON (AccountingPeriodClosed apId) =
    object ["type" .= ("AccountingPeriodClosed" :: Text), "data" .= apId]
  -- 固定資産
  toJSON (FixedAssetRegistered fa) =
    object ["type" .= ("FixedAssetRegistered" :: Text), "data" .= fa]
  toJSON (DepreciationRecorded assetId compId day amount) =
    object
      [ "type" .= ("DepreciationRecorded" :: Text)
      , "assetId" .= assetId
      , "compId" .= compId
      , "date" .= day
      , "amount" .= amount
      ]
  toJSON (ImpairmentRecognized assetId compId day loss recoverable) =
    object
      [ "type" .= ("ImpairmentRecognized" :: Text)
      , "assetId" .= assetId
      , "compId" .= compId
      , "date" .= day
      , "loss" .= loss
      , "recoverable" .= recoverable
      ]
  toJSON (ImpairmentReversalRecognized assetId compId day amount) =
    object
      [ "type" .= ("ImpairmentReversalRecognized" :: Text)
      , "assetId" .= assetId
      , "compId" .= compId
      , "date" .= day
      , "amount" .= amount
      ]
  toJSON (AssetRevalued assetId compId day newGross surplus) =
    object
      [ "type" .= ("AssetRevalued" :: Text)
      , "assetId" .= assetId
      , "compId" .= compId
      , "date" .= day
      , "newGross" .= newGross
      , "surplus" .= surplus
      ]
  toJSON (FixedAssetDisposed assetId compId day) =
    object
      [ "type" .= ("FixedAssetDisposed" :: Text)
      , "assetId" .= assetId
      , "compId" .= compId
      , "date" .= day
      ]
  -- ECL
  toJSON (EclMeasurementRecorded m) =
    object ["type" .= ("EclMeasurementRecorded" :: Text), "data" .= m]
  -- FX
  toJSON (FxRateRecorded r) =
    object ["type" .= ("FxRateRecorded" :: Text), "data" .= r]
  -- 判断ログ
  toJSON (JudgmentLogRecorded l) =
    object ["type" .= ("JudgmentLogRecorded" :: Text), "data" .= l]
  -- 従業員給付
  toJSON (BenefitLiabilityRecorded b) =
    object ["type" .= ("BenefitLiabilityRecorded" :: Text), "data" .= b]
  -- 法人所得税
  toJSON (TaxEntryRecorded t) =
    object ["type" .= ("TaxEntryRecorded" :: Text), "data" .= t]

instance FromJSON Event where
  parseJSON = withObject "Event" $ \o -> do
    typ <- o .: "type"
    case (typ :: Text) of
      "JournalEntryRecorded" -> JournalEntryRecorded <$> o .: "data"
      "OrganisationRegistered" -> OrganisationRegistered <$> o .: "data"
      "OrganisationUpdated" -> OrganisationUpdated <$> o .: "data"
      "OrgPermissionGranted" -> OrgPermissionGranted <$> o .: "org" <*> o .: "scope"
      "OrgPermissionRevoked" -> OrgPermissionRevoked <$> o .: "org" <*> o .: "scope"
      "PartnerRegistered" -> PartnerRegistered <$> o .: "data"
      "PartnerUpdated" -> PartnerUpdated <$> o .: "data"
      "AccountMasterRegistered" -> AccountMasterRegistered <$> o .: "data"
      "AccountMasterUpdated" -> AccountMasterUpdated <$> o .: "data"
      "SubAccountRegistered" -> SubAccountRegistered <$> o .: "data"
      "SubAccountUpdated" -> SubAccountUpdated <$> o .: "data"
      "CashTransactionRecorded" -> CashTransactionRecorded <$> o .: "data"
      "ReconciliationCreated" -> ReconciliationCreated <$> o .: "data"
      "ReconciliationReversed" -> ReconciliationReversed <$> o .: "id" <*> o .: "date"
      "AccountingPeriodOpened" -> AccountingPeriodOpened <$> o .: "data"
      "AccountingPeriodClosed" -> AccountingPeriodClosed <$> o .: "data"
      -- 固定資産
      "FixedAssetRegistered" -> FixedAssetRegistered <$> o .: "data"
      "DepreciationRecorded" ->
        DepreciationRecorded
          <$> o .: "assetId"
          <*> o .: "compId"
          <*> o .: "date"
          <*> o .: "amount"
      "ImpairmentRecognized" ->
        ImpairmentRecognized
          <$> o .: "assetId"
          <*> o .: "compId"
          <*> o .: "date"
          <*> o .: "loss"
          <*> o .: "recoverable"
      "ImpairmentReversalRecognized" ->
        ImpairmentReversalRecognized
          <$> o .: "assetId"
          <*> o .: "compId"
          <*> o .: "date"
          <*> o .: "amount"
      "AssetRevalued" ->
        AssetRevalued
          <$> o .: "assetId"
          <*> o .: "compId"
          <*> o .: "date"
          <*> o .: "newGross"
          <*> o .: "surplus"
      "FixedAssetDisposed" ->
        FixedAssetDisposed
          <$> o .: "assetId"
          <*> o .: "compId"
          <*> o .: "date"
      -- ECL
      "EclMeasurementRecorded" -> EclMeasurementRecorded <$> o .: "data"
      -- FX
      "FxRateRecorded" -> FxRateRecorded <$> o .: "data"
      -- 判断ログ
      "JudgmentLogRecorded" -> JudgmentLogRecorded <$> o .: "data"
      -- 従業員給付
      "BenefitLiabilityRecorded" -> BenefitLiabilityRecorded <$> o .: "data"
      -- 法人所得税
      "TaxEntryRecorded" -> TaxEntryRecorded <$> o .: "data"
      _ -> fail ("unknown Event type: " <> show typ)
