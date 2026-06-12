-- | Shared widget primitives reused across all screens.
module Shell.TUI.Helpers
  ( row
  , row'
  , renderTextEd
  , drawCycleField
  , drawBtn
  , drawError
  , drawHint
  , cycleL
  , cycleR
  , edText
  ) where

import Brick
  ( Widget
  , str
  , txt
  , withAttr
  )
import Data.Text (Text)

import Brick qualified as B
import Brick.Widgets.Border qualified as BB
import Brick.Widgets.Edit qualified as E
import Data.Text qualified as T

import Shell.TUI.Attrs

-- | Label + widget in a horizontal row, label width fixed at 14.
row :: String -> Widget n -> Widget n
row label w =
  B.hBox
    [ withAttr labelAttr (str (label <> ": "))
    , B.hLimit 30 w
    ]

-- | Label + full-width widget (no hLimit).
row' :: String -> Widget n -> Widget n
row' label w =
  B.hBox [withAttr labelAttr (str (label <> ": ")), w]

renderTextEd :: (Ord n, Show n) => Bool -> E.Editor Text n -> Widget n
renderTextEd focused ed =
  B.hLimit 28 $
    E.renderEditor (txt . T.concat) focused ed

drawCycleField :: Bool -> String -> Widget n
drawCycleField focused label =
  let w = str ("< " <> label <> " >")
  in if focused then withAttr focusedAttr w else w

drawBtn :: Bool -> String -> Widget n
drawBtn focused label =
  let w = B.padLeftRight 1 (str label)
  in if focused then withAttr focusedAttr (BB.border w) else BB.border w

drawError :: Maybe Text -> Widget n
drawError Nothing = str " "
drawError (Just msg) = withAttr errorAttr (txt ("エラー: " <> msg))

drawHint :: String -> Widget n
drawHint = withAttr hintAttr . str

-- | Read all text from a single-line editor.
edText :: E.Editor Text n -> Text
edText = T.intercalate "\n" . E.getEditContents

cycleL :: (Bounded a, Enum a, Eq a) => a -> a
cycleL x = if x == minBound then maxBound else pred x

cycleR :: (Bounded a, Enum a, Eq a) => a -> a
cycleR x = if x == maxBound then minBound else succ x
