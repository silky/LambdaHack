{-# LANGUAGE GeneralizedNewtypeDeriving #-}
-- | Server types and operations for items that don't involve server state
-- nor our custom monads.
module Game.LambdaHack.Server.ItemRev
  ( ItemRev, buildItem, newItem
    -- * Item discovery types
  , DiscoRev, serverDiscos, ItemSeedDict
    -- * The @FlavourMap@ type
  , FlavourMap, emptyFlavourMap, dungeonFlavourMap
  ) where

import Control.Exception.Assert.Sugar
import Control.Monad
import Data.Binary
import qualified Data.EnumMap.Strict as EM
import qualified Data.HashMap.Strict as HM
import qualified Data.Ix as Ix
import Data.List
import qualified Data.Set as S
import Data.Text (Text)

import Game.LambdaHack.Common.Flavour
import Game.LambdaHack.Common.Frequency
import Game.LambdaHack.Common.Item
import qualified Game.LambdaHack.Common.Kind as Kind
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.Msg
import Game.LambdaHack.Common.Random
import Game.LambdaHack.Content.ItemKind

-- | The reverse map to @Discovery@, needed for item creation.
type DiscoRev = EM.EnumMap (Kind.Id ItemKind) ItemKindIx

-- | The map of item ids to item seeds.
-- The full map is known by the server.
type ItemSeedDict = EM.EnumMap ItemId ItemSeed

serverDiscos :: Kind.Ops ItemKind -> Rnd (Discovery, DiscoRev)
serverDiscos Kind.Ops{obounds, ofoldrWithKey} = do
  let ixs = map toEnum $ take (Ix.rangeSize obounds) [0..]
      shuffle :: Eq a => [a] -> Rnd [a]
      shuffle [] = return []
      shuffle l = do
        x <- oneOf l
        fmap (x :) $ shuffle (delete x l)
  shuffled <- shuffle ixs
  let f ik _ (ikMap, ikRev, ix : rest) =
        (EM.insert ix ik ikMap, EM.insert ik ix ikRev, rest)
      f ik  _ (ikMap, _, []) =
        assert `failure` "too short ixs" `twith` (ik, ikMap)
      (discoS, discoRev, _) =
        ofoldrWithKey f (EM.empty, EM.empty, shuffled)
  return (discoS, discoRev)

-- | Build an item with the given stats.
buildItem :: FlavourMap -> DiscoRev -> Kind.Id ItemKind -> ItemKind -> LevelId
          -> Item
buildItem (FlavourMap flavour) discoRev ikChosen kind jlid =
  let jkindIx  = discoRev EM.! ikChosen
      jsymbol  = isymbol kind
      jname    = iname kind
      jflavour =
        case iflavour kind of
          [fl] -> fl
          _ -> flavour EM.! ikChosen
      jfeature = ifeature kind
      jweight = iweight kind
  in Item{..}

-- | Generate an item based on level.
newItem :: Kind.COps -> FlavourMap -> DiscoRev
        -> Frequency Text -> LevelId -> AbsDepth -> AbsDepth
        -> Rnd (Maybe (ItemKnown, ItemFull, ItemSeed, Int))
newItem _ _ _ itemFreq _ _ _ | nullFreq itemFreq = return Nothing
newItem cops@Kind.COps{coitem=Kind.Ops{ofoldrGroup}}
        flavour discoRev itemFreq jlid
        ldepth@(AbsDepth ld) totalDepth@(AbsDepth depth) = do
  itemGroup <- frequency itemFreq
  let findInterval _ x1y1 [] = (x1y1, (depth + 1, 0))
      findInterval point x1y1 ((x, y) : rest) =
        assert (0 < x && x < depth + 1 `blame` (itemGroup, x, depth + 1))
        $ if point <= x
          then (x1y1, (x, y))
          else findInterval point (x, y) rest
      linearInterpolation point dataset =
        -- We assume @dataset@ is sorted and between 0 and @depth + 1@.
        let ((x1, y1), (x2, y2)) = findInterval point (0, 0) dataset
        in y1 + (y2 - y1) * (point - x1) `divUp` (x2 - x1)
      f p ik kind acc =
        let rarity = linearInterpolation ld (irarity kind)
        in (p * rarity, (ik, kind)) : acc
      freqDepth = ofoldrGroup itemGroup f []
      freq = toFreq ("newItem ('" <> itemGroup <> "',"
                               <+> tshow ld <> ")") freqDepth
  if nullFreq freq then
    let zeroedFreq = setFreq itemFreq itemGroup 0
    in newItem cops flavour discoRev zeroedFreq jlid ldepth totalDepth
  else do
    (itemKindId, itemKind) <- frequency freq
    itemN <- castDice ldepth totalDepth (icount itemKind)
    seed <- fmap toEnum random
    let itemBase = buildItem flavour discoRev itemKindId itemKind jlid
        itemK = max 1 itemN
        iae = seedToAspectsEffects seed itemKind ldepth totalDepth
        itemFull = ItemFull {itemBase, itemK, itemDisco = Just itemDisco}
        itemDisco = ItemDisco {itemKindId, itemKind, itemAE = Just iae}
    return $ Just ( (itemBase, iae)
                  , itemFull
                  , seed
                  , itemK )

-- | Flavours assigned by the server to item kinds, in this particular game.
newtype FlavourMap = FlavourMap (EM.EnumMap (Kind.Id ItemKind) Flavour)
  deriving (Show, Binary)

emptyFlavourMap :: FlavourMap
emptyFlavourMap = FlavourMap EM.empty

-- | Assigns flavours to item kinds. Assures no flavor is repeated,
-- except for items with only one permitted flavour.
rollFlavourMap :: S.Set Flavour -> Kind.Id ItemKind -> ItemKind
               -> Rnd ( EM.EnumMap (Kind.Id ItemKind) Flavour
                      , EM.EnumMap Char (S.Set Flavour) )
               -> Rnd ( EM.EnumMap (Kind.Id ItemKind) Flavour
                      , EM.EnumMap Char (S.Set Flavour) )
rollFlavourMap fullFlavSet key ik rnd =
  let flavours = iflavour ik
  in if length flavours == 1
     then rnd
     else do
       (assocs, availableMap) <- rnd
       let available = EM.findWithDefault fullFlavSet (isymbol ik) availableMap
           proper = S.fromList flavours `S.intersection` available
       assert (not (S.null proper)
               `blame` "not enough flavours for items"
               `twith` (flavours, available, ik, availableMap)) $ do
         flavour <- oneOf (S.toList proper)
         let availableReduced = S.delete flavour available
         return ( EM.insert key flavour assocs
                , EM.insert (isymbol ik) availableReduced availableMap)

-- | Randomly chooses flavour for all item kinds for this game.
dungeonFlavourMap :: Kind.Ops ItemKind -> Rnd FlavourMap
dungeonFlavourMap Kind.Ops{ofoldrWithKey} =
  liftM (FlavourMap . fst) $
    ofoldrWithKey (rollFlavourMap (S.fromList stdFlav))
                  (return (EM.empty, EM.empty))

-- | Reverse item map, for item creation, to keep items and item identifiers
-- in bijection.
type ItemRev = HM.HashMap ItemKnown ItemId
