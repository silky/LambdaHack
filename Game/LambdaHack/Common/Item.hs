{-# LANGUAGE DeriveGeneric, GeneralizedNewtypeDeriving #-}
-- | Weapons, treasure and all the other items in the game.
-- No operation in this module involves the state or any of our custom monads.
module Game.LambdaHack.Common.Item
  ( -- * The @Item@ type
    ItemId, Item(..), seedToAspectsEffects
    -- * Item discovery types
  , ItemKindIx, Discovery, ItemSeed, ItemAspectEffect(..), DiscoAE
  , ItemFull(..), ItemDisco(..), itemNoDisco
    -- * Inventory management types
  , ItemBag, ItemDict, ItemKnown
  ) where

import qualified Control.Monad.State as St
import Data.Binary
import qualified Data.EnumMap.Strict as EM
import Data.Hashable (Hashable)
import qualified Data.Ix as Ix
import Data.Text (Text)
import GHC.Generics (Generic)
import System.Random (mkStdGen)

import Game.LambdaHack.Common.Effect
import Game.LambdaHack.Common.Flavour
import qualified Game.LambdaHack.Common.Kind as Kind
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.Random
import Game.LambdaHack.Content.ItemKind

-- | A unique identifier of an item in the dungeon.
newtype ItemId = ItemId Int
  deriving (Show, Eq, Ord, Enum, Binary)

-- | An index of the kind id of an item. Clients have partial knowledge
-- how these idexes map to kind ids. They gain knowledge by identifying items.
newtype ItemKindIx = ItemKindIx Int
  deriving (Show, Eq, Ord, Enum, Ix.Ix, Hashable, Binary)

-- | The map of item kind indexes to item kind ids.
-- The full map, as known by the server, is a bijection.
type Discovery = EM.EnumMap ItemKindIx (Kind.Id ItemKind)

-- | A seed for rolling aspects and effects of an item
-- Clients have partial knowledge of how item ids map to the seeds.
-- They gain knowledge by identifying items.
newtype ItemSeed = ItemSeed Int
  deriving (Show, Eq, Ord, Enum, Hashable, Binary)

data ItemAspectEffect = ItemAspectEffect
  { jaspects :: ![Aspect Int]  -- ^ the aspects of the item
  , jeffects :: ![Effect Int]  -- ^ the effects when activated
  }
  deriving (Show, Eq, Ord, Generic)

instance Binary ItemAspectEffect

instance Hashable ItemAspectEffect

-- | The map of item ids to item aspects and effects.
-- The full map is known by the server.
type DiscoAE = EM.EnumMap ItemId ItemAspectEffect

data ItemDisco = ItemDisco
  { itemKindId :: Kind.Id ItemKind
  , itemKind   :: ItemKind
  , itemAE     :: Maybe ItemAspectEffect
  }
  deriving Show

data ItemFull = ItemFull
  { itemBase  :: !Item
  , itemK     :: !Int
  , itemDisco :: !(Maybe ItemDisco)
  }
  deriving Show

itemNoDisco :: (Item, Int) -> ItemFull
itemNoDisco (itemBase, itemK) =
  ItemFull {itemBase, itemK, itemDisco=Nothing}

-- | Game items in actor possesion or strewn around the dungeon.
-- The fields @jsymbol@, @jname@ and @jflavour@ make it possible to refer to
-- and draw an unidentified item. Full information about item is available
-- through the @jkindIx@ index as soon as the item is identified.
data Item = Item
  { jkindIx  :: !ItemKindIx    -- ^ index pointing to the kind of the item
  , jlid     :: !LevelId       -- ^ the level on which item was created
  , jsymbol  :: !Char          -- ^ individual map symbol
  , jname    :: !Text          -- ^ individual generic name
  , jflavour :: !Flavour       -- ^ individual flavour
  , jfeature :: ![Feature]     -- ^ public properties
  , jweight  :: !Int           -- ^ weight in grams, obvious enough
  }
  deriving (Show, Eq, Ord, Generic)

instance Hashable Item

instance Binary Item

seedToAspectsEffects :: ItemSeed -> ItemKind -> AbsDepth -> AbsDepth
                     -> ItemAspectEffect
seedToAspectsEffects (ItemSeed itemSeed) kind ldepth totalDepth =
  let castD = castDice ldepth totalDepth
      rollAE = do
        aspects <- mapM (flip aspectTrav castD) (iaspects kind)
        effects <- mapM (flip effectTrav castD) (ieffects kind)
        return (aspects, effects)
      (jaspects, jeffects) = St.evalState rollAE (mkStdGen itemSeed)
  in ItemAspectEffect{..}

type ItemBag = EM.EnumMap ItemId Int

-- | All items in the dungeon (including in actor inventories),
-- indexed by item identifier.
type ItemDict = EM.EnumMap ItemId Item

type ItemKnown = (Item, ItemAspectEffect)
