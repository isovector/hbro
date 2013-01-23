{-# LANGUAGE FlexibleContexts, RankNTypes, TemplateHaskell #-}
-- | Designed to be imported as @qualified@.
module Hbro.IPC where

-- {{{ Imports
-- import Hbro.Error
import Hbro.Util

import Control.Lens hiding(Context, Rep)
import Control.Monad hiding(mapM_)
import Control.Monad.Base
-- import Control.Monad.Error hiding(mapM_)
-- import Control.Monad.Writer

import Data.ByteString.Char8 (pack, unpack)
--import Data.Foldable
import Data.Functor
import Data.Map (Map)

-- import Graphics.UI.Gtk.General.General

import Prelude hiding(log, mapM_, read)

import System.FilePath
import System.Posix.Process
-- import System.Posix.Types
-- import System.Process
import System.ZMQ3 as ZMQ hiding(close, init, message, receive, send, socket)
import qualified System.ZMQ3 as ZMQ (init, receive, send, socket)
-- }}}

-- {{{ Types
data IPC = IPC {
    _context  :: Context,
    _receiver :: Socket Rep}

-- | 'MonadReader' for 'IPC'
class IPCReader m where
    readIPC :: Simple Lens IPC a -> m a

makeLenses ''IPC

newtype CommandsMap m = CommandsMap { unwrap :: Map String ([String] -> m String) }
-- }}}

-- | Open a listening socket at given location
init :: (MonadBase IO m) => String -> m IPC
init uri = io $ do
    theContext <- ZMQ.init 1
    socket     <- ZMQ.socket theContext Rep
    bind socket uri
    return $ IPC theContext socket

-- | Return the socket path to use for the given browser's process ID.
getSocketPath :: (Functor m, MonadBase IO m) => FilePath -> m String
getSocketPath socketDir = ((("ipc://" ++ socketDir </> "hbro.") ++) . show) <$> io getProcessID

-- | Send message through given socket
send :: (MonadBase IO m, Sender a) => Socket a -> String -> m ()
send socket payload = io $ ZMQ.send socket [] (pack payload)

-- | Wait for a message to be received from given socket
read :: (MonadBase IO m, Receiver a) => Socket a -> m String
read socket = io $ unpack <$> ZMQ.receive socket

-- | Send a single command to the given socket (which must be 'Rep'), and return the answer
sendCommand :: (MonadBase IO m, IPCReader m) => String -> String -> m String
sendCommand socketURI command = do
    theContext <- readIPC context
    io $ withSocket theContext Req $ \socket -> do
      connect socket socketURI
      send socket command
      read socket

-- | Same as 'sendCommand', but for all running instances of the browser.
{-sendCommandToAll :: (MonadBase IO m, ConfigReader m m, IPCReader m) => String -> m [String]
sendCommandToAll command = do
    dir  <- readConfig socketDir
    getAllProcessIDs >>= mapM ((`sendCommand` command) . (`socketPath` dir))-}
