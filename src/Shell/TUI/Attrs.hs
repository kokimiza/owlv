-- | Shared attribute names and AttrMap for the owlv TUI.
module Shell.TUI.Attrs
  ( focusedAttr
  , labelAttr
  , titleAttr
  , errorAttr
  , hintAttr
  , activeAttr
  , inactiveAttr
  , owlvAttrMap
  ) where

import Brick (AttrMap, AttrName, attrMap, attrName, on)
import Graphics.Vty.Attributes (defAttr)

import Brick.Widgets.Edit qualified as E
import Graphics.Vty qualified as Vty

focusedAttr, labelAttr, titleAttr, errorAttr, hintAttr :: AttrName
activeAttr, inactiveAttr :: AttrName
focusedAttr = attrName "focused"
labelAttr = attrName "label"
titleAttr = attrName "title"
errorAttr = attrName "error"
hintAttr = attrName "hint"
activeAttr = attrName "active"
inactiveAttr = attrName "inactive"

owlvAttrMap :: AttrMap
owlvAttrMap =
  attrMap
    defAttr
    [ (focusedAttr, Vty.black `on` Vty.cyan)
    , (labelAttr, Vty.withStyle defAttr Vty.bold)
    , (titleAttr, Vty.white `on` Vty.blue)
    , (errorAttr, Vty.red `on` Vty.black)
    , (hintAttr, Vty.withStyle defAttr Vty.dim)
    , (activeAttr, Vty.green `on` Vty.black)
    , (inactiveAttr, Vty.withStyle defAttr Vty.dim)
    , (E.editAttr, defAttr)
    , (E.editFocusedAttr, Vty.black `on` Vty.cyan)
    ]
