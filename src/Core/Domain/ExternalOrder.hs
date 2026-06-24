{- | 外部発注・単発取引ドメイン型 (doc/project_management.md §1.3, §1.4, §6)

`ExpenseNature`/`RevenueNature` が商品マスタの代替である —— 勘定科目分類と
同オーダーの有限個数に留め、無尽蔵に増える固有名詞をここに持ち込まない
(doc/project_management.md §0.2)。発注先・取引先そのもの (`PartnerId`) は
既存 `Core.Domain.Partner` を再利用する。
-}
module Core.Domain.ExternalOrder
  ( ExpenseNature (..)
  , RevenueNature (..)
  , OrderStatus (..)
  , ExternalOrderId (..)
  , ExternalOrder (..)
  , SingleTransactionId (..)
  , SingleTransaction (..)
  ) where

import Data.Aeson
  ( FromJSON (..)
  , ToJSON (..)
  , object
  , withObject
  , withText
  , (.:)
  , (.=)
  )
import Data.Text (Text)
import Data.Time (Day)
import Data.UUID (UUID)
import GHC.Generics (Generic)

import Data.Text qualified as T
import Data.UUID qualified as UUID

import Core.Domain.Money (Money)
import Core.Domain.Partner (PartnerId)
import Core.Domain.Project (ProjectId, ProjectPhaseId)

{- | 費用の性質分類 (doc/project_management.md §1.4)。商品マスタの代替——
列挙子の個数は勘定科目分類と同オーダーに留め、無尽蔵に増えない。
`ExpenseOther` が頻発する場合は列挙子を追加するガバナンスを別途定める
(doc/project_management.md §8 残課題)。
-}
data ExpenseNature
  = ExpenseSubcontractCost -- ^ 外注費
  | ExpenseMaterialCost -- ^ 材料費
  | ExpenseLaborCost -- ^ 労務費（doc/labor_management.md 起因）
  | ExpenseTravel -- ^ 旅費交通費
  | ExpenseLicenseFee -- ^ ライセンス・権利使用料
  | ExpenseConsumables -- ^ 消耗品費
  | ExpenseOther Text -- ^ 上記に当たらない場合の説明書き
  deriving (Eq, Show)

instance ToJSON ExpenseNature where
  toJSON ExpenseSubcontractCost = object ["tag" .= ("ExpenseSubcontractCost" :: Text)]
  toJSON ExpenseMaterialCost = object ["tag" .= ("ExpenseMaterialCost" :: Text)]
  toJSON ExpenseLaborCost = object ["tag" .= ("ExpenseLaborCost" :: Text)]
  toJSON ExpenseTravel = object ["tag" .= ("ExpenseTravel" :: Text)]
  toJSON ExpenseLicenseFee = object ["tag" .= ("ExpenseLicenseFee" :: Text)]
  toJSON ExpenseConsumables = object ["tag" .= ("ExpenseConsumables" :: Text)]
  toJSON (ExpenseOther detail) =
    object ["tag" .= ("ExpenseOther" :: Text), "detail" .= detail]

instance FromJSON ExpenseNature where
  parseJSON = withObject "ExpenseNature" $ \o -> do
    tag <- o .: "tag"
    case (tag :: Text) of
      "ExpenseSubcontractCost" -> pure ExpenseSubcontractCost
      "ExpenseMaterialCost" -> pure ExpenseMaterialCost
      "ExpenseLaborCost" -> pure ExpenseLaborCost
      "ExpenseTravel" -> pure ExpenseTravel
      "ExpenseLicenseFee" -> pure ExpenseLicenseFee
      "ExpenseConsumables" -> pure ExpenseConsumables
      "ExpenseOther" -> ExpenseOther <$> o .: "detail"
      _ -> fail ("unknown ExpenseNature tag: " <> T.unpack tag)

-- | 収益の性質分類 (doc/project_management.md §1.4)
data RevenueNature
  = RevenueGoodsSale -- ^ グッズ販売等の有形即時売上
  | RevenueLicenseSettlement -- ^ ライセンス決済等の無形即時売上
  | RevenueLongTermContract -- ^ 進行基準 (IFRS 15) に基づく長期契約売上
  deriving (Bounded, Enum, Eq, Generic, Show)

instance ToJSON RevenueNature
instance FromJSON RevenueNature

-- | 発注の状態 (doc/project_management.md §1.3)
data OrderStatus
  = OrderPlaced
  | OrderPartiallyDelivered
  | OrderDelivered
  | OrderCancelled
  deriving (Bounded, Enum, Eq, Generic, Show)

instance ToJSON OrderStatus
instance FromJSON OrderStatus

newtype ExternalOrderId = ExternalOrderId UUID
  deriving (Eq, Ord, Show)

instance ToJSON ExternalOrderId where
  toJSON (ExternalOrderId u) = toJSON (UUID.toString u)

instance FromJSON ExternalOrderId where
  parseJSON = withText "ExternalOrderId" $ \t ->
    case UUID.fromString (T.unpack t) of
      Just u -> pure (ExternalOrderId u)
      Nothing -> fail ("invalid UUID: " <> T.unpack t)

{- | 外部発注 (doc/project_management.md §1.3)。ユーザー提示例の核心
（「外部A氏に背景5枚を発注、単価5万」）。`orderQuantity`/`orderDeliveredQuantity`
は部分検収 (`OrderPartiallyDelivered`) を表現するために分けて持つ。
-}
data ExternalOrder = ExternalOrder
  { orderId :: ExternalOrderId
  , orderProject :: ProjectId
  , orderPhase :: Maybe ProjectPhaseId
  , orderVendor :: PartnerId
  , orderDescription :: Text
  -- ^ 「背景5枚」等。自由記述（商品マスタの代替にしない）
  , orderNature :: ExpenseNature
  , orderUnitPrice :: Money
  , orderQuantity :: Int
  , orderDeliveredQuantity :: Int
  , orderDate :: Day
  , orderExpectedDate :: Maybe Day
  , orderStatus :: OrderStatus
  }
  deriving (Eq, Generic, Show)

instance ToJSON ExternalOrder
instance FromJSON ExternalOrder

newtype SingleTransactionId = SingleTransactionId UUID
  deriving (Eq, Ord, Show)

instance ToJSON SingleTransactionId where
  toJSON (SingleTransactionId u) = toJSON (UUID.toString u)

instance FromJSON SingleTransactionId where
  parseJSON = withText "SingleTransactionId" $ \t ->
    case UUID.fromString (T.unpack t) of
      Just u -> pure (SingleTransactionId u)
      Nothing -> fail ("invalid UUID: " <> T.unpack t)

{- | 即時単発取引 (doc/project_management.md §6)。グッズ販売・ライセンス決済等、
商品マスタを介さずに極小のワークフロー (`Project`、自動的に開いて閉じる) として
処理される取引。
-}
data SingleTransaction = SingleTransaction
  { stxId :: SingleTransactionId
  , stxProject :: ProjectId
  , stxDescription :: Text
  , stxNature :: RevenueNature
  , stxCounterparty :: Maybe PartnerId
  , stxAmount :: Money
  , stxDate :: Day
  , stxTaxTreatment :: Text
  -- ^ 消費税区分等の自由記述。専用の型は将来 Core.Domain.Tax 拡張時に検討する
  -- (doc/management_accounting.md §6 残課題)。
  }
  deriving (Eq, Generic, Show)

instance ToJSON SingleTransaction
instance FromJSON SingleTransaction
