{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE LambdaCase #-}

module Main (main) where

import Control.Applicative ((<$>), (*>), (<*>))
import Control.Monad (void, unless, forever)
import Control.Concurrent
  ( ThreadId
  , forkIO
  , myThreadId
  , threadDelay
  , killThread
  , MVar
  , newMVar
  , readMVar
  , modifyMVar_
  )
import Data.Foldable (traverse_)
import Control.Exception (finally)
import GHC.Generics (Generic)
import Control.Monad.Reader (ask)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Set (union)
import qualified Data.Set as Set
import Network.Socket (SockAddr(..), iNADDR_ANY, PortNumber(..))
import Data.Binary (Binary(..), putWord8, getWord8)
import Control.Error (runMaybeT, hoistMaybe)
import Pipes (Consumer, (>->), runEffect, await, each)
import Pipes.Network.TCP (toSocket, send)
import qualified Pipes.Prelude as P
import Network.Simple.SockAddr (connectFork)
import Pipes.Network.P2P

path1,path2 :: String
path1 = "/tmp/n1.socket"
path2 = "/tmp/n2.socket"

addr1,addr2,addr3,addr4 :: SockAddr
addr1 = SockAddrUnix path1
addr2 = SockAddrUnix path2
addr3 = SockAddrInet 1234 iNADDR_ANY
addr4 = SockAddrInet 1235 iNADDR_ANY

main :: IO ()
main = do
    n1 <- addrExchanger addr1
    n2 <- addrExchanger addr2
    n3 <- addrExchanger addr3
    n4 <- addrExchanger addr4
    t1 <- forkIO $ launch n1 []
    threadDelay 10000
    t2 <- forkIO $ launch n2 [addr1]
    threadDelay 10000
    t3 <- forkIO $ launch n3 [addr1, addr2]
    threadDelay 10000
    launch n4 [addr1] `finally` traverse_ killThread [t1,t2,t3]
  where
    addrExchanger :: SockAddr -> IO (Node AddrMsg)
    addrExchanger addr = do
        ps <- newMVar Map.empty
        node 3741 Nothing (Handlers outgoing
                                   (incoming ps)
                                   (register ps)
                                   (unregister ps)
                                   (handler ps)) addr

outgoing :: (Functor m, MonadIO m) => NodeConnT AddrMsg m (Maybe AddrMsg)
outgoing = runMaybeT $ do
    NodeConn n (Connection addr _) <- ask
    deliver . ME . Addr $ address n
    expect . ME $ Addr addr
    deliver ACK
    expect ACK
    deliver GETADDR
    return . ADDR $ Addr addr

incoming :: (Functor m, MonadIO m)
         => MVar (Map Address ThreadId)
         -> NodeConnT AddrMsg m (Maybe AddrMsg)
incoming peers = runMaybeT $ do
    NodeConn n _ <- ask
    msg <- fetch
    case msg of
         ME addr@(Addr sockaddr) -> do
            ps <- liftIO $ readMVar peers
            if Map.notMember addr ps
            then do deliver . ME . Addr $ address n
                    deliver ACK
                    expect ACK
                    return . ADDR $ Addr sockaddr
            else hoistMaybe Nothing
         _ -> hoistMaybe Nothing

register :: MonadIO m
         => MVar (Map Address ThreadId)
         -> AddrMsg
         -> m ()
register peers (ADDR addr) = liftIO $ do
    tid <- myThreadId
    modifyMVar_ peers $ return . Map.insert addr tid

-- | Assumes the thread has already been killed
unregister :: MonadIO m
           => MVar (Map Address ThreadId)
           -> AddrMsg -> m ()
unregister peers (ADDR addr) =
    liftIO . modifyMVar_ peers $ return . Map.delete addr

handler :: (MonadIO m, MonadCatch m)
        => MVar (Map Address ThreadId)
        -> AddrMsg
        -> Consumer (Either (Relay AddrMsg) AddrMsg) (NodeConnT AddrMsg m) r
handler peers (ADDR addr) = do
    NodeConn n@Node{magic} (Connection _ sock) <- ask
    forever $ await >>= \case
        Right GETADDR -> do
            ps <- liftIO $ Map.delete addr <$> readMVar peers
            runEffect $ each (Map.keys ps)
                    >-> P.map (serialize magic . ADDR)
                    >-> toSocket sock
        Right (ADDR a@(Addr a')) -> do
            ps <- liftIO $ readMVar peers
            unless (Set.null $ Set.fromList [a, addr] `union` Map.keysSet ps)
                   (liftIO . void $ connectFork a'
                                  $ runNodeConn n True a')
        Left (Relay tid' msg) -> do
            tid <- liftIO myThreadId
            unless (tid' == tid)
                   (liftIO . send sock . serialize magic $ msg)
        _ -> return ()

data AddrMsg = GETADDR
             | ADDR Address
             | ME Address
             | ACK
               deriving (Show, Eq, Generic)

instance Binary AddrMsg

newtype Address = Addr SockAddr deriving (Show, Eq, Ord)

instance Binary Address where
    put (Addr (SockAddrInet (PortNum port) host)) =
        putWord8 0 *> put (port, host)
    put (Addr (SockAddrInet6 (PortNum port) flow host scope)) =
        putWord8 1 *> put (port, flow, host, scope)
    put (Addr (SockAddrUnix str)) = putWord8 2 *> put str

    get = getWord8 >>= \case
              0 -> Addr <$> (SockAddrInet <$> PortNum <$> get <*> get)
              1 -> Addr <$> (SockAddrInet6 <$> PortNum
                                           <$> get
                                           <*> get
                                           <*> get
                                           <*> get)
              _ -> Addr <$> SockAddrUnix <$> get
