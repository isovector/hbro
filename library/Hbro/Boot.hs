{-# LANGUAGE ConstraintKinds   #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE NoImplicitPrelude #-}
module Hbro.Boot (Settings(..), hbro) where

-- {{{ Imports
import           Hbro.Config                     as Config
import           Hbro.Core                       as Core
import           Hbro.Defaults
import           Hbro.Dyre                       as Dyre
import           Hbro.Error
import           Hbro.Event
import           Hbro.Gui                        as Gui
import           Hbro.Gui.Builder
import           Hbro.Gui.MainView
import           Hbro.Gui.NotificationBar        (NotifBarTag (..))
import           Hbro.Gui.PromptBar              (PromptBarTag (..))
import           Hbro.Gui.StatusBar
import           Hbro.IPC                        as IPC (CommandMap,
                                                         bindCommands)
import           Hbro.Keys                       as Keys
import           Hbro.Logger                     as Logger
import           Hbro.Options                    as Options
import           Hbro.Prelude

import           Control.Concurrent.Async.Lifted
import           Control.Lens                    hiding ((<|), (??), (|>))

import           Data.Version                    hiding (Version)

import           Filesystem

import           Graphics.UI.Gtk.General.General as Gtk

import           Network.URI.Extended

import           Paths_hbro                      (version)

import           System.Posix.Process
import           System.Posix.Signals
import qualified System.ZMQ4                     as ZMQ (version)
-- }}}

-- {{{ Imports
data Settings = Settings
    { configuration :: Config
    , commandMap    :: OmniReader m => CommandMap m
    , keyMap        :: OmniReader m => KeyMap m
    , startUpHook   :: OmniReader m => m ()
    }

instance Default Settings where
  def = Settings
          { configuration     = def
          , commandMap        = defaultCommandMap
          , keyMap            = defaultKeyMap
          , startUpHook       = debugM "No start-up hook defined"
          }
-- }}}

-- | Main function to call in the configuration file (cf file @Hbro/Main.hs@).
hbro :: Settings -> IO ()
hbro settings = do
    options <- parseOptions
    case options of
        Left Rebuild -> Dyre.recompile >>= mapM_ infoM
        Left Version -> do
            (a, b, c) <- ZMQ.version
            putStrLn $ "hbro: v" ++ pack (showVersion version)
            putStrLn $ "0MQ library: v" ++ intercalate "." (map tshow [a, b, c])
        Right runOptions -> Dyre.wrap (runOptions^.dyreModeL)
                                      (withAsyncBound guiThread . mainThread)
                                      (settings, runOptions)

-- | Gtk main loop thread.
guiThread :: IO ()
guiThread = do
    async $ do
        installHandler sigINT  (Catch onInterrupt) Nothing
        installHandler sigTERM (Catch onInterrupt) Nothing
    initGUI >> mainGUI
    debugM "GUI thread correctly exited."
  where onInterrupt  = logInterrupt >> postGUIAsync mainQuit
        logInterrupt = infoM "Received interrupt signal."


mainThread :: (Settings, CliOptions) -> Async () -> IO ()
mainThread (settings, options) uiThread = do
  void . runErrorT . logErrors $ do
    Logger.initialize $ options^.logLevelL

    uiFiles <- getUIFiles options
    (builder, mainView, promptBar, statusBar, notifBar) <- asum $ map Gui.initialize uiFiles

    socketURI <- getSocketURI options
    keySignal <- newSignal KeyMapPressed

    withConfig (configuration settings)
      . withMainView mainView
      . withStatusBar statusBar
      . runReaderT PromptBarTag promptBar
      . runReaderT NotifBarTag notifBar
      . withBuilder builder
      . runReaderT KeySignalTag keySignal
      . withAsync (bindCommands socketURI (commandMap settings)) . const $ do
        bindKeys (mainView^.keyPressedHookL) keySignal (keyMap settings)

        setDefaultHook (mainView^.downloadHookL) defaultDownloadHook
        setDefaultHook (mainView^.linkClickedHookL) defaultLinkClickedHook
        setDefaultHook (mainView^.loadRequestedHookL) defaultLoadRequestedHook
        setDefaultHook (mainView^.newWindowHookL) defaultNewWindowHook
        setDefaultHook (mainView^.titleChangedHookL) defaultTitleChangedHook

        startUpHook settings

        debugM . ("Start-up configuration: \n" ++) . describe =<< Config.get id

        maybe goHome (load <=< getStartURI) (options^.startURIL)
        io $ wait uiThread

  debugM "All threads correctly exited."


-- | Return the list of available UI files (from configuration and package)
getUIFiles :: (MonadIO m, Functor m) => CliOptions -> m [FilePath]
getUIFiles options = do
    fileFromConfig  <- getAppConfigDirectory "hbro" >/> "ui.xml"
    fileFromPackage <- getDataFileName "examples/ui.xml"
    return $ catMaybes [options^.uiFileL, Just fileFromConfig, Just fileFromPackage]

-- | Return socket URI used by this instance
getSocketURI :: (MonadIO m, Functor m) => CliOptions -> m Text
getSocketURI options = maybe getDefaultSocketURI (return . normalize) $ options^.socketPathL
  where
    normalize = ("ipc://" ++) . fpToText
    getDefaultSocketURI = do
      dir <- fpToText <$> io (getAppCacheDirectory "hbro")
      pid <- io getProcessID
      return $ "ipc://" ++ dir ++ "/hbro." ++ tshow pid

-- | Parse URI passed in commandline, check whether it is a file path or an internet URI
-- and return the corresponding normalized URI (that is: prefixed with "file://" or "http://")
getStartURI :: (MonadIO m, MonadError Text m) => URI -> m URI
getStartURI uri = do
    fileURI    <- io . isFile . fpFromText $ tshow uri
    workingDir <- io getWorkingDirectory

    parseURIReferenceM ("file://" ++ fpToText workingDir ++ "/" ++ tshow uri) <| fileURI |> return uri
    -- maybe abort return =<< logErrors (parseURIReference fileURI')