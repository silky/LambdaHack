{-# LANGUAGE DeriveGeneric #-}
-- | Basic operations on bounded 2D vectors, with an efficient, but not 1-1
-- and not monotonic @Enum@ instance.
module Game.LambdaHack.Common.Vector
  ( Vector(..), isUnit, isDiagonal, neg, chessDistVector, euclidDistSqVector
  , moves, movesCardinal, movesDiagonal, compassText
  , vicinity, vicinityUnsafe, vicinityCardinal, vicinityCardinalUnsafe
  , squareUnsafeSet
  , shift, shiftBounded, trajectoryToPath, trajectoryToPathBounded
  , vectorToFrom, pathToTrajectory
  , RadianAngle, rotate, towards
#ifdef EXPOSE_INTERNAL
    -- * Internal operations
  , maxVectorDim, _moveTexts, longMoveTexts, normalize, normalizeVector
#endif
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import           Control.DeepSeq
import           Data.Binary
import qualified Data.EnumMap.Strict as EM
import qualified Data.EnumSet as ES
import           Data.Int (Int32)

import GHC.Generics (Generic)

import Game.LambdaHack.Common.Point

-- | 2D vectors in cartesian representation. Coordinates grow to the right
-- and down, so that the (1, 1) vector points to the bottom-right corner
-- of the screen.
data Vector = Vector
  { vx :: X
  , vy :: Y
  }
  deriving (Show, Read, Eq, Ord, Generic)

instance Binary Vector where
  put = put . (fromIntegral :: Int -> Int32) . fromEnum
  get = fmap (toEnum . (fromIntegral :: Int32 -> Int)) get

-- Note that the conversion is not monotonic wrt the natural @Ord@ instance,
-- to keep it in sync with Point.
instance Enum Vector where
  fromEnum (Vector vx vy) = vx + vy * (2 ^ maxLevelDimExponent)
  toEnum n =
    let (y, x) = n `quotRem` (2 ^ maxLevelDimExponent)
        (vx, vy) | x > maxVectorDim = (x - 2 ^ maxLevelDimExponent, y + 1)
                 | x < - maxVectorDim = (x + 2 ^ maxLevelDimExponent, y - 1)
                 | otherwise = (x, y)
    in Vector{..}

instance NFData Vector

-- | Maximal supported vector X and Y coordinates.
maxVectorDim :: Int
{-# INLINE maxVectorDim #-}
maxVectorDim = 2 ^ (maxLevelDimExponent - 1) - 1

-- | Tells if a vector has length 1 in the chessboard metric.
isUnit :: Vector -> Bool
{-# INLINE isUnit #-}
isUnit v = chessDistVector v == 1

-- | Checks whether a unit vector is a diagonal direction,
-- as opposed to cardinal. If the vector is not unit,
-- it checks that the vector is not horizontal nor vertical.
isDiagonal :: Vector -> Bool
{-# INLINE isDiagonal #-}
isDiagonal (Vector x y) = x * y /= 0

-- | Reverse an arbirary vector.
neg :: Vector -> Vector
{-# INLINE neg #-}
neg (Vector vx vy) = Vector (-vx) (-vy)

-- | The lenght of a vector in the chessboard metric,
-- where diagonal moves cost 1.
chessDistVector :: Vector -> Int
{-# INLINE chessDistVector #-}
chessDistVector (Vector x y) = max (abs x) (abs y)

-- | Squared euclidean distance between two vectors.
euclidDistSqVector :: Vector -> Vector -> Int
euclidDistSqVector (Vector x0 y0) (Vector x1 y1) =
  (x1 - x0) ^ (2 :: Int) + (y1 - y0) ^ (2 :: Int)

-- | Vectors of all unit moves in the chessboard metric,
-- clockwise, starting north-west.
moves :: [Vector]
moves =
  map (uncurry Vector)
    [(-1, -1), (0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0)]

-- | Vectors of all cardinal direction unit moves, clockwise, starting north.
movesCardinal :: [Vector]
movesCardinal = map (uncurry Vector) [(0, -1), (1, 0), (0, 1), (-1, 0)]

-- | Vectors of all diagonal direction unit moves, clockwise, starting north.
movesDiagonal :: [Vector]
movesDiagonal = map (uncurry Vector) [(-1, -1), (1, -1), (1, 1), (-1, 1)]

-- | Currently unused.
_moveTexts :: [Text]
_moveTexts = ["NW", "N", "NE", "E", "SE", "S", "SW", "W"]

longMoveTexts :: [Text]
longMoveTexts = [ "northwest", "north", "northeast", "east"
                , "southeast", "south", "southwest", "west" ]

compassText :: Vector -> Text
compassText v = let m = EM.fromList $ zip moves longMoveTexts
                    assFail = error $ "not a unit vector" `showFailure` v
                in EM.findWithDefault assFail v m

-- | All (8 at most) closest neighbours of a point within an area.
vicinity :: X -> Y   -- ^ limit the search to this area
         -> Point    -- ^ position to find neighbours of
         -> [Point]
vicinity lxsize lysize p =
  if inside p (1, 1, lxsize - 2, lysize - 2)
  then vicinityUnsafe p
  else [ res | dxy <- moves
             , let res = shift p dxy
             , inside res (0, 0, lxsize - 1, lysize - 1) ]

vicinityUnsafe :: Point -> [Point]
vicinityUnsafe p = [ shift p dxy | dxy <- moves ]

-- | All (4 at most) cardinal direction neighbours of a point within an area.
vicinityCardinal :: X -> Y   -- ^ limit the search to this area
                 -> Point    -- ^ position to find neighbours of
                 -> [Point]
vicinityCardinal lxsize lysize p =
  [ res | dxy <- movesCardinal
        , let res = shift p dxy
        , inside res (0, 0, lxsize - 1, lysize - 1) ]

vicinityCardinalUnsafe :: Point -> [Point]
vicinityCardinalUnsafe p = [ shift p dxy | dxy <- movesCardinal ]

squareUnsafeSet :: Point -> ES.EnumSet Point
squareUnsafeSet (Point x y) =
  ES.fromDistinctAscList $ map (uncurry Point)
    [ (x - 1, y - 1)
    , (x,     y - 1)
    , (x + 1, y - 1)
    , (x - 1, y)
    , (x,     y)  -- full square, including the origin
    , (x + 1, y)
    , (x - 1, y + 1)
    , (x,     y + 1)
    , (x + 1, y + 1) ]

-- | Translate a point by a vector.
shift :: Point -> Vector -> Point
{-# INLINE shift #-}
shift (Point x0 y0) (Vector x1 y1) = Point (x0 + x1) (y0 + y1)

-- | Translate a point by a vector, but only if the result fits in an area.
shiftBounded :: X -> Y -> Point -> Vector -> Point
shiftBounded lxsize lysize pos v@(Vector xv yv) =
  if inside pos (-xv, -yv, lxsize - xv - 1, lysize - yv - 1)
  then shift pos v
  else pos

-- | A list of points that a list of vectors leads to.
trajectoryToPath :: Point -> [Vector] -> [Point]
trajectoryToPath _ [] = []
trajectoryToPath start (v : vs) = let next = shift start v
                                  in next : trajectoryToPath next vs

-- | A list of points that a list of vectors leads to, bounded by level size.
trajectoryToPathBounded :: X -> Y -> Point -> [Vector] -> [Point]
trajectoryToPathBounded _ _ _ [] = []
trajectoryToPathBounded lxsize lysize start (v : vs) =
  let next = shiftBounded lxsize lysize start v
  in next : trajectoryToPathBounded lxsize lysize next vs

-- | The vector between the second point and the first. We have
--
-- > shift pos1 (pos2 `vectorToFrom` pos1) == pos2
--
-- The arguments are in the same order as in the underlying scalar subtraction.
vectorToFrom :: Point -> Point -> Vector
{-# INLINE vectorToFrom #-}
vectorToFrom (Point x0 y0) (Point x1 y1) = Vector (x0 - x1) (y0 - y1)

-- | A list of vectors between a list of points.
pathToTrajectory :: [Point] -> [Vector]
pathToTrajectory [] = []
pathToTrajectory lp1@(_ : lp2) = zipWith vectorToFrom lp2 lp1

type RadianAngle = Double

-- | Rotate a vector by the given angle (expressed in radians)
-- counterclockwise and return a unit vector approximately in the resulting
-- direction.
rotate :: RadianAngle -> Vector -> Vector
rotate angle (Vector x' y') =
  let x = fromIntegral x'
      y = fromIntegral y'
      -- Minus before the angle comes from our coordinates being
      -- mirrored along the X axis (Y coordinates grow going downwards).
      dx = x * cos (-angle) - y * sin (-angle)
      dy = x * sin (-angle) + y * cos (-angle)
  in normalize dx dy

-- | Given a vector of arbitrary non-zero length, produce a unit vector
-- that points in the same direction (in the chessboard metric).
-- Of several equally good directions it picks one of those that visually
-- (in the euclidean metric) maximally align with the original vector.
normalize :: Double -> Double -> Vector
normalize dx dy =
  assert (dx /= 0 || dy /= 0 `blame` "can't normalize zero" `swith` (dx, dy)) $
  let angle :: Double
      angle = atan (dy / dx) / (pi / 2)
      dxy | angle <= -0.75 && angle >= -1.25 = (0, -1)
          | angle <= -0.25 = (1, -1)
          | angle <= 0.25  = (1, 0)
          | angle <= 0.75  = (1, 1)
          | angle <= 1.25  = (0, 1)
          | otherwise = error $ "impossible angle" `showFailure` (dx, dy, angle)
  in if dx >= 0
     then uncurry Vector dxy
     else neg $ uncurry Vector dxy

normalizeVector :: Vector -> Vector
normalizeVector v@(Vector vx vy) =
  let res = normalize (fromIntegral vx) (fromIntegral vy)
  in assert (not (isUnit v) || v == res
             `blame` "unit vector gets untrivially normalized"
             `swith` (v, res))
     res

-- | Given two distinct positions, determine the direction (a unit vector)
-- in which one should move from the first in order to get closer
-- to the second. Ignores obstacles. Of several equally good directions
-- (in the chessboard metric) it picks one of those that visually
-- (in the euclidean metric) maximally align with the vector between
-- the two points.
towards :: Point -> Point -> Vector
towards pos0 pos1 =
  assert (pos0 /= pos1 `blame` "towards self" `swith` (pos0, pos1))
  $ normalizeVector $ pos1 `vectorToFrom` pos0
