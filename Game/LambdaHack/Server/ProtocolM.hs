-- | The server definitions for the server-client communication protocol.
module Game.LambdaHack.Server.ProtocolM
  ( -- * The communication channels
    CliSerQueue, ChanServer(..)
  , ConnServerDict  -- exposed only to be implemented, not used
    -- * The server-client communication monad
  , MonadServerReadRequest
      ( getsDict  -- exposed only to be implemented, not used
      , modifyDict  -- exposed only to be implemented, not used
      , saveChanServer  -- exposed only to be implemented, not used
      , liftIO  -- exposed only to be implemented, not used
      )
    -- * Protocol
  , putDict, sendUpdate, sendSfx, sendQueryAI, sendQueryUI
    -- * Assorted
  , killAllClients, childrenServer, updateConn
  , saveServer, saveName, tryRestore
#ifdef EXPOSE_INTERNAL
    -- * Internal operations
#endif
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import Control.Concurrent
import Control.Concurrent.Async
import qualified Data.EnumMap.Strict as EM
import Data.Key (mapWithKeyM, mapWithKeyM_)
import System.FilePath
import System.IO.Unsafe (unsafePerformIO)

import Game.LambdaHack.Atomic
import Game.LambdaHack.Client.UI
import Game.LambdaHack.Client.UI.Config
import Game.LambdaHack.Client.UI.SessionUI
import Game.LambdaHack.Common.Actor
import Game.LambdaHack.Common.ClientOptions
import Game.LambdaHack.Common.Faction
import qualified Game.LambdaHack.Common.Kind as Kind
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.MonadStateRead
import Game.LambdaHack.Common.Request
import Game.LambdaHack.Common.Response
import qualified Game.LambdaHack.Common.Save as Save
import Game.LambdaHack.Common.State
import Game.LambdaHack.Common.Thread
import Game.LambdaHack.Content.ModeKind
import Game.LambdaHack.Content.RuleKind
import Game.LambdaHack.Server.DebugM
import Game.LambdaHack.Server.FileM
import Game.LambdaHack.Server.MonadServer hiding (liftIO)
import Game.LambdaHack.Server.State

type CliSerQueue = MVar

writeQueue :: MonadServerReadRequest m
           => Response -> CliSerQueue Response -> m ()
{-# INLINE writeQueue #-}
writeQueue cmd responseS = liftIO $ putMVar responseS cmd

readQueueAI :: MonadServerReadRequest m
            => CliSerQueue RequestAI
            -> m RequestAI
{-# INLINE readQueueAI #-}
readQueueAI requestS = liftIO $ takeMVar requestS

readQueueUI :: MonadServerReadRequest m
            => CliSerQueue RequestUI
            -> m RequestUI
{-# INLINE readQueueUI #-}
readQueueUI requestS = liftIO $ takeMVar requestS

newQueue :: IO (CliSerQueue a)
newQueue = newEmptyMVar

saveServer :: MonadServerReadRequest m => m ()
{-# INLINABLE saveServer #-}
saveServer = do
  s <- getState
  ser <- getServer
  dictAll <- getDict
  toSave <- saveChanServer
  liftIO $ Save.saveToChan toSave (s, ser, dictAll)

saveName :: String
saveName = serverSaveName

tryRestore :: MonadServerReadRequest m
           => Kind.COps -> DebugModeSer
           -> m (Maybe (State, StateServer))
{-# INLINABLE tryRestore #-}
tryRestore Kind.COps{corule} sdebugSer = do
  let bench = sbenchmark $ sdebugCli sdebugSer
  if bench then return Nothing
  else do
    let prefix = ssavePrefixSer sdebugSer
        name = prefix <.> saveName
    res <-
      liftIO $ Save.restoreGame tryCreateDir doesFileExist strictDecodeEOF name
    let stdRuleset = Kind.stdRuleset corule
        cfgUIName = rcfgUIName stdRuleset
        content = rcfgUIDefault stdRuleset
    dataDir <- liftIO $ appDataDir
    liftIO $ tryWriteFile (dataDir </> cfgUIName) content
    return $! res

-- | Connection channel between the server and a single client.
data ChanServer = ChanServer
  { responseS  :: !(CliSerQueue Response)
  , requestAIS :: !(CliSerQueue RequestAI)
  , requestUIS :: !(Maybe (CliSerQueue RequestUI))
  }

-- | Either states or connections to the human-controlled client
-- of a faction and to the AI client for the same faction.
type FrozenClient = ChanServer

-- For multiplayer, the AI client should be separate, as in
-- data FrozenClient = FThread !(Maybe (ChanServer Response RequestUI))
--                             !(ChanServer Response RequestAI)

-- | Connection information for all factions, indexed by faction identifier.
type ConnServerDict = EM.EnumMap FactionId FrozenClient

-- TODO: refactor so that the monad is split in 2 and looks analogously
-- to the Client monads. Restrict the Dict to implementation modules.
-- Then on top of that implement sendQueryAI, etc.
-- For now we call it MonadServerReadRequest
-- though it also has the functionality of MonadServerWriteResponse.

-- | The server monad with the ability to communicate with clients.
class MonadServer m => MonadServerReadRequest m where
  getsDict     :: (ConnServerDict -> a) -> m a
  modifyDict   :: (ConnServerDict -> ConnServerDict) -> m ()
  saveChanServer :: m (Save.ChanSave (State, StateServer, ConnServerDict))
  liftIO       :: IO a -> m a

getDict :: MonadServerReadRequest m => m ConnServerDict
{-# INLINABLE getDict #-}
getDict = getsDict id

putDict :: MonadServerReadRequest m => ConnServerDict -> m ()
{-# INLINABLE putDict #-}
putDict s = modifyDict (const s)

sendUpdate :: MonadServerReadRequest m => FactionId -> UpdAtomic -> m ()
{-# INLINABLE sendUpdate #-}
sendUpdate !fid !cmd = do
  frozenClient <- getsDict $ (EM.! fid)
  let resp = RespUpdAtomic cmd
  debug <- getsServer $ sniffOut . sdebugSer
  when debug $ debugResponse resp
  writeQueue resp $ responseS frozenClient

sendSfx :: MonadServerReadRequest m => FactionId -> SfxAtomic -> m ()
{-# INLINABLE sendSfx #-}
sendSfx !fid !sfx = do
  let resp = RespSfxAtomic sfx
  debug <- getsServer $ sniffOut . sdebugSer
  when debug $ debugResponse resp
  frozenClient <- getsDict $ (EM.! fid)
  case frozenClient of
    ChanServer{requestUIS=Just{}} -> writeQueue resp $ responseS frozenClient
    _ -> return ()

sendQueryAI :: MonadServerReadRequest m => FactionId -> ActorId -> m RequestAI
{-# INLINABLE sendQueryAI #-}
sendQueryAI fid aid = do
  let respAI = RespQueryAI aid
  debug <- getsServer $ sniffOut . sdebugSer
  when debug $ debugResponse respAI
  frozenClient <- getsDict $ (EM.! fid)
  req <- do
    writeQueue respAI $ responseS frozenClient
    readQueueAI $ requestAIS frozenClient
  when debug $ debugRequestAI aid req
  return req

sendQueryUI :: (MonadAtomic m, MonadServerReadRequest m)
            => FactionId -> ActorId -> m RequestUI
{-# INLINABLE sendQueryUI #-}
sendQueryUI fid _aid = do
  let respUI = RespQueryUI
  debug <- getsServer $ sniffOut . sdebugSer
  when debug $ debugResponse respUI
  frozenClient <- getsDict $ (EM.! fid)
  req <- do
    writeQueue respUI $ responseS frozenClient
    readQueueUI $ fromJust $ requestUIS frozenClient
  when debug $ debugRequestUI _aid req
  return req

killAllClients :: (MonadAtomic m, MonadServerReadRequest m) => m ()
{-# INLINABLE killAllClients #-}
killAllClients = do
  d <- getDict
  let sendKill fid _ =
        -- We can't check in sfactionD, because client can be from an old game.
        sendUpdate fid $ UpdKillExit fid
  mapWithKeyM_ sendKill d

-- Global variable for all children threads of the server.
childrenServer :: MVar [Async ()]
{-# NOINLINE childrenServer #-}
childrenServer = unsafePerformIO (newMVar [])

-- | Update connections to the new definition of factions.
-- Connect to clients in old or newly spawned threads
-- that read and write directly to the channels.
updateConn :: (MonadAtomic m, MonadServerReadRequest m)
           => Kind.COps
           -> Config
           -> (Maybe SessionUI -> Kind.COps -> FactionId -> ChanServer
               -> IO ())
           -> m ()
{-# INLINABLE updateConn #-}
updateConn cops sconfig executorClient = do
  -- Prepare connections based on factions.
  oldD <- getDict
  let sess = emptySessionUI sconfig
      mkChanServer :: Faction -> IO ChanServer
      mkChanServer fact = do
        responseS <- newQueue
        requestAIS <- newQueue
        requestUIS <- if fhasUI $ gplayer fact
                      then Just <$> newQueue
                      else return Nothing
        return $! ChanServer{..}
      addConn :: FactionId -> Faction -> IO FrozenClient
      addConn fid fact = case EM.lookup fid oldD of
        Just conns -> return conns  -- share old conns and threads
        Nothing -> mkChanServer fact
  factionD <- getsState sfactionD
  d <- liftIO $ mapWithKeyM addConn factionD
  let newD = d `EM.union` oldD  -- never kill old clients
  putDict newD
  -- Spawn client threads.
  let toSpawn = newD EM.\\ oldD
      forkUI fid connS =
        forkChild childrenServer $ executorClient (Just sess) cops fid connS
      forkAI fid connS =
        forkChild childrenServer $ executorClient Nothing cops fid connS
      forkClient fid conn@ChanServer{requestUIS=Nothing} =
        -- When a connection is reused, clients are not respawned,
        -- even if UI usage changes, but it works OK thanks to UI faction
        -- clients distinguished by positive FactionId numbers.
        forkAI fid conn
      forkClient fid conn =
        forkUI fid conn
  liftIO $ mapWithKeyM_ forkClient toSpawn
