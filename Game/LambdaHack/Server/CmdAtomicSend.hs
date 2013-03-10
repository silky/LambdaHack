{-# LANGUAGE OverloadedStrings, RankNTypes #-}
-- | Sending atomic commands to clients and executing them on the server.
module Game.LambdaHack.Server.CmdAtomicSend
  ( atomicSendSem
  ) where

import Control.Monad
import qualified Data.EnumMap.Strict as EM
import qualified Data.EnumSet as ES
import Data.Maybe
import Data.Text (Text)

import Game.LambdaHack.Action
import Game.LambdaHack.Actor
import Game.LambdaHack.ActorState
import Game.LambdaHack.CmdAtomic
import Game.LambdaHack.CmdAtomicSem
import Game.LambdaHack.CmdCli
import Game.LambdaHack.Faction
import qualified Game.LambdaHack.Kind as Kind
import Game.LambdaHack.Level
import Game.LambdaHack.Perception
import Game.LambdaHack.Server.Action
import Game.LambdaHack.Server.State
import Game.LambdaHack.State
import Game.LambdaHack.Utils.Assert

-- All functions here that take an atomic action are executed
-- in the state just before the action is executed.

-- Determines is a command resets FOV. @Nothing@ means it always does.
-- A list of faction means it does for each of the factions.
resetsFovAtomic :: MonadActionRO m => CmdAtomic -> m (Maybe [FactionId])
resetsFovAtomic cmd = case cmd of
  CreateActorA _ body _ -> return $ Just [bfaction body]
  DestroyActorA _ _ _ -> return $ Just []  -- FOV kept a bit to see aftermath
  CreateItemA _ _ _ _ -> return $ Just []  -- unless shines
  DestroyItemA _ _ _ _ -> return $ Just []  -- ditto
  MoveActorA aid _ _ -> fmap Just $ fidOfAid aid  -- assumption: has no light
-- TODO: MoveActorCarryingLIghtA _ _ _ -> return Nothing
  DisplaceActorA source target -> do
    sfid <- fidOfAid source
    tfid <- fidOfAid target
    if source == target
      then return $ Just []
      else return $ Just $ sfid ++ tfid
  DominateActorA _ fromFid toFid -> return $ Just [fromFid, toFid]
  MoveItemA _ _ _ _ -> return $ Just []  -- unless shiny
  AlterTileA _ _ _ _ -> return Nothing  -- even if pos not visible initially
  _ -> return $ Just []

fidOfAid :: MonadActionRO m => ActorId -> m [FactionId]
fidOfAid aid = getsState $ (: []) . bfaction . getActorBody aid

-- | Decompose an atomic action. The original action is visible
-- if it's positions are visible both before and after the action
-- (in between the FOV might have changed). The decomposed actions
-- are only tested vs the FOV after the action and they give reduced
-- information that still modifies client's state to match the server state
-- wrt the current FOV and the subset of @posCmdAtomic@ that is visible.
-- The original actions give more information not only due to spanning
-- potentially more positions than those visible. E.g., @MoveActorA@
-- informs about the continued existence of the actor between
-- moves, v.s., popping out of existence and then back in.
breakCmdAtomic :: MonadActionRO m => CmdAtomic -> m [CmdAtomic]
breakCmdAtomic cmd = case cmd of
  MoveActorA aid _ toP -> do
    b <- getsState $ getActorBody aid
    ais <- getsState $ getActorItem aid
    return [LoseActorA aid b ais, SpotActorA aid b {bpos = toP} ais]
  DisplaceActorA source target -> do
    sb <- getsState $ getActorBody source
    sais <- getsState $ getActorItem source
    tb <- getsState $ getActorBody target
    tais <- getsState $ getActorItem target
    return [ LoseActorA source sb sais
           , SpotActorA source sb {bpos = bpos tb} sais
           , LoseActorA target tb tais
           , SpotActorA target tb {bpos = bpos sb} tais
           ]
  MoveItemA iid k c1 c2 -> do
    item <- getsState $ getItemBody iid
    return [LoseItemA iid item k c1, SpotItemA iid item k c2]
  _ -> return [cmd]

loudCmdAtomic :: MonadActionRO m => CmdAtomic -> m Bool
loudCmdAtomic cmd = case cmd of
  DestroyActorA _ body _ -> return $ not $ bproj body
  AlterTileA{} -> return True
  _ -> return False

seenAtomicCli :: Bool -> FactionId -> Perception -> PosAtomic -> Bool
seenAtomicCli knowEvents fid per posAtomic =
  case posAtomic of
    PosLevel _ ps -> knowEvents || all (`ES.member` totalVisible per) ps
    PosOnly fid2 -> fid == fid2
    PosAndSer fid2 -> fid == fid2
    PosAll -> True
    PosNone -> assert `failure` fid

seenAtomicSer :: PosAtomic -> Bool
seenAtomicSer posAtomic =
  case posAtomic of
    PosOnly _ -> False
    PosNone -> assert `failure` ("PosNone considered for the server" :: Text)
    _ -> True

atomicServerSem :: MonadAction m => PosAtomic -> Atomic -> m ()
atomicServerSem posAtomic atomic =
  when (seenAtomicSer posAtomic) $
    case atomic of
      CmdAtomic cmd -> cmdAtomicSem cmd
      SfxAtomic _ -> return ()

-- | Send an atomic action to all clients that can see it.
atomicSendSem :: (MonadAction m, MonadServerConn m) => Atomic -> m ()
atomicSendSem atomic = do
  -- Gather data from the old state.
  sOld <- getState
  persOld <- getsServer sper
  (ps, resets, atomicBroken, psBroken, psLoud) <-
    case atomic of
      CmdAtomic cmd -> do
        ps <- posCmdAtomic cmd
        resets <- resetsFovAtomic cmd
        atomicBroken <- breakCmdAtomic cmd
        psBroken <- mapM posCmdAtomic atomicBroken
        psLoud <- mapM loudCmdAtomic atomicBroken
        return (ps, resets, atomicBroken, psBroken, psLoud)
      SfxAtomic sfx -> do
        ps <- posSfxAtomic sfx
        return (ps, Just [], [], [], [])
  let atomicPsBroken = zip3 atomicBroken psBroken psLoud
  -- TODO: assert also that the sum of psBroken is equal to ps
  -- TODO: with deep equality these assertions can be expensive. Optimize.
  assert (case ps of
            PosLevel{} -> True
            _ -> resets == Just []
                 && (null atomicBroken
                     || fmap CmdAtomic atomicBroken == [atomic])) skip
  -- Perform the action on the server.
  atomicServerSem ps atomic
  -- Send some actions to the clients, one faction at a time.
  knowEvents <- getsServer $ sknowEvents . sdebugSer
  let sendA fid cmd = do
        sendUpdateUI fid $ CmdAtomicUI cmd
        sendUpdateAI fid $ CmdAtomicAI cmd
      sendUpdate fid (CmdAtomic cmd) = sendA fid cmd
      sendUpdate fid (SfxAtomic sfx) = sendUpdateUI fid $ SfxAtomicUI sfx
      breakSend fid perNew = do
        let send2 (atomic2, ps2, loud2) =
              if seenAtomicCli knowEvents fid perNew ps2
                then sendUpdate fid $ CmdAtomic atomic2
                else when loud2 $
                       sendUpdate fid
                       $ SfxAtomic $ BroadcastD "You hear some noises."
        mapM_ send2 atomicPsBroken
      anySend fid perOld perNew = do
        let startSeen = seenAtomicCli knowEvents fid perOld ps
            endSeen = seenAtomicCli knowEvents fid perNew ps
        if startSeen && endSeen
          then sendUpdate fid atomic
          else breakSend fid perNew
      send fid = case ps of
        PosLevel arena _ -> do
          let perOld = persOld EM.! fid EM.! arena
              resetsFid = maybe True (fid `elem`) resets
          if resetsFid then do
            resetFidPerception fid arena
            perNew <- getPerFid fid arena
            let inPer = diffPer perNew perOld
                inPA = perActor inPer
                outPer = diffPer perOld perNew
                outPA = perActor outPer
            if EM.null outPA && EM.null inPA
              then anySend fid perOld perOld
              else do
                sendA fid $ PerceptionA arena outPA inPA
                mapM_ (sendA fid) $ atomicRemember arena inPer sOld
                anySend fid perOld perNew
          else anySend fid perOld perOld
        -- In the following cases, from the assertion above,
        -- @resets@ is false here and broken atomic has the same ps.
        PosOnly fid2 -> when (fid == fid2) $ sendUpdate fid atomic
        PosAndSer fid2 -> when (fid == fid2) $ sendUpdate fid atomic
        PosAll -> sendUpdate fid atomic
        PosNone -> assert `failure` (atomic, fid)
  faction <- getsState sfaction
  mapM_ send $ EM.keys faction

atomicRemember :: LevelId -> Perception -> State -> [CmdAtomic]
atomicRemember lid inPer s =
  let inFov = ES.elems $ totalVisible inPer
      lvl = sdungeon s EM.! lid
      pMaybe p = maybe Nothing (\x -> Just (p, x))
      inFloor = mapMaybe (\p -> pMaybe p $ EM.lookup p (lfloor lvl)) inFov
      fItem p (iid, k) = SpotItemA iid (getItemBody iid s) k (CFloor lid p)
      fBag (p, bag) = map (fItem p) $ EM.assocs bag
      inItem = concatMap fBag inFloor
      -- No @outItem@, for items that became out of sight. The client will
      -- create these atomic actions based on @outPer@, if required.
      -- Any client that remembers out of sight items, OTOH,
      -- will create atomic actions that forget remembered items
      -- that are revealed not to be there any more (no @SpotItemA@ for them).
      inPrio = mapMaybe (\p -> posToActor p lid s) inFov
      fActor aid = SpotActorA aid (getActorBody aid s) (getActorItem aid s)
      inActor = map fActor inPrio
      -- No @outActor@, for the same reason as with @outItem@.
      inTileMap = map (\p -> (p, ltile lvl Kind.! p)) inFov
      -- No @outTlie@, for the same reason as above.
      atomicTile = if null inTileMap then [] else [SpotTileA lid inTileMap]
  in inItem ++ inActor ++ atomicTile
