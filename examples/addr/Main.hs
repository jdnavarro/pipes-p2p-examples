{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
module Main (main) where

import Control.Applicative ((<$>), (*>), (<*>))
import Control.Monad (when)
import Control.Concurrent
  ( ThreadId
  , forkIO
  , threadDelay
  , killThread
  , MVar
  , newMVar
  , readMVar
  )
import Data.Foldable (traverse_)
import Control.Exception (finally)
import GHC.Generics (Generic)
import Control.Monad.Reader (ask)
import Data.Map (Map)
import qualified Data.Map as Map
import Network.Socket (SockAddr(..), iNADDR_ANY, PortNumber(..))
import Data.Binary (Binary(..), putWord8, getWord8)
import Control.Error (runMaybeT, isJust, hoistMaybe)
import Pipes.Network.P2P

path1,path2 :: String
path1 = "/tmp/n1.socket"
path2 = "/tmp/n2.socket"

addr1,addr2,addr3,addr4 :: SockAddr
addr1 = SockAddrUnix path1
addr2 = SockAddrUnix path2
addr3 = SockAddrInet 1234 iNADDR_ANY
addr4 = SockAddrInet 1235 iNADDR_ANY

magicBytes :: Int
magicBytes = 2741

main :: IO ()
main = do
    n1 <- node Nothing magicBytes addr1
    n2 <- node Nothing magicBytes addr2
    n3 <- node Nothing magicBytes addr3
    n4 <- node Nothing magicBytes addr4
    t1 <- forkIO $ launch' n1 []
    threadDelay 10000
    t2 <- forkIO $ launch' n2 [addr1]
    threadDelay 10000
    t3 <- forkIO $ launch' n3 [addr1, addr2]
    threadDelay 10000
    launch' n4 [addr1] `finally` traverse_ killThread [t1,t2,t3]
  where
    launch' n s = do mv <- newMVar Map.empty
                     launch n s outgoing $ incoming mv

outgoing :: (Functor m, MonadIO m) => NodeConnT AddrMsg m Bool
outgoing = fmap isJust . runMaybeT $ do
    NodeConn n _ addr _ <- ask
    deliver . ME . Addr $ address n
    expect . ME $ Addr addr
    deliver ACK
    expect ACK
    deliver GETADDR

incoming :: (Functor m, MonadIO m)
         => MVar (Map Address ThreadId)
         -> NodeConnT AddrMsg m Bool
incoming peers = fmap isJust . runMaybeT $ do
    NodeConn n _ _ _ <- ask
    msg <- fetch
    case msg of
         ME addr@(Addr _) -> do
            ps <- liftIO $ readMVar peers
            when (Map.notMember addr ps) $ do
                deliver . ME . Addr $ address n
                deliver ACK
                expect ACK
         _ -> hoistMaybe Nothing

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
