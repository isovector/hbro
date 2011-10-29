{-# LANGUAGE DoRec #-}
module Hbro.Gui where

-- {{{ Imports
import Hbro.Types

import Control.Monad.Trans(liftIO)

import Graphics.Rendering.Pango.Enums
import Graphics.UI.Gtk.Abstract.Container
import Graphics.UI.Gtk.Abstract.Box
import Graphics.UI.Gtk.Abstract.Widget
import Graphics.UI.Gtk.Builder
import Graphics.UI.Gtk.Display.Label
import Graphics.UI.Gtk.Entry.Editable
import Graphics.UI.Gtk.Entry.Entry
import Graphics.UI.Gtk.General.General
import Graphics.UI.Gtk.Gdk.EventM
import Graphics.UI.Gtk.Layout.HBox
import Graphics.UI.Gtk.Layout.VBox
import Graphics.UI.Gtk.Scrolling.ScrolledWindow
import Graphics.UI.Gtk.WebKit.WebInspector
import Graphics.UI.Gtk.WebKit.WebView
import Graphics.UI.Gtk.Windows.Window

import System.Console.CmdArgs (whenNormal, whenLoud)
import System.Glib.Attributes
import System.Glib.Signals
-- }}}


-- | Load GUI from XML file
loadGUI :: String -> IO GUI
loadGUI xmlPath = do
    whenNormal $ putStr ("Loading GUI from " ++ xmlPath ++ "... ")

-- Load XML
    builder <- builderNew
    builderAddFromFile builder xmlPath

-- Init main web view
    webView <- webViewNew
    set webView [ widgetCanDefault := True ]
    _ <- on webView closeWebView $ mainQuit >> return False

-- Load main window
    window       <- builderGetObject builder castToWindow            "mainWindow"
    windowSetDefault window $ Just webView
    widgetModifyBg window StateNormal (Color 0 0 10000)
    _ <- onDestroy window mainQuit

    scrollWindow <- builderGetObject builder castToScrolledWindow    "webViewParent"
    containerAdd scrollWindow webView 
    scrolledWindowSetPolicy scrollWindow PolicyNever PolicyNever

    promptLabel  <- builderGetObject builder castToLabel             "promptDescription"
    labelSetAttributes promptLabel [
      AttrStyle  {paStart = 0, paEnd = -1, paStyle = StyleItalic},
      AttrWeight {paStart = 0, paEnd = -1, paWeight = WeightBold}
      ]
    
    promptEntry  <- builderGetObject builder castToEntry             "promptEntry"
    statusBox    <- builderGetObject builder castToHBox              "statusBox"

-- Create web inspector's window
    inspector       <- webViewGetInspector webView
    windowBox       <- builderGetObject builder castToVBox           "windowBox"
    inspectorWindow <- initWebInspector inspector windowBox
    
    whenNormal $ putStrLn "Done."
    return $ GUI window inspectorWindow scrollWindow webView promptLabel promptEntry statusBox builder


-- {{{ Web inspector
initWebInspector :: WebInspector -> VBox -> IO (Window)
initWebInspector inspector windowBox = do 
    inspectorWindow <- windowNew
    set inspectorWindow [ windowTitle := "hbro | Web inspector" ]

    _ <- on inspector inspectWebView $ \_ -> do
        webView <- webViewNew
        containerAdd inspectorWindow webView
        return webView
    
    _ <- on inspector showWindow $ do
        widgetShowAll inspectorWindow
        return True

-- TODO: when does this signal happen ?!
    --_ <- on inspector finished $ return ()

-- Attach inspector to browser's main window
    _ <- on inspector attachWindow $ do
        getWebView <- webInspectorGetWebView inspector
        case getWebView of
            Just webView -> do 
                widgetHide inspectorWindow
                containerRemove inspectorWindow webView
                widgetSetSizeRequest webView (-1) 250
                boxPackEnd windowBox webView PackNatural 0
                widgetShow webView
                return True
            _ -> return False

-- Detach inspector in a distinct window
    _ <- on inspector detachWindow $ do
        getWebView <- webInspectorGetWebView inspector
        _ <- case getWebView of
            Just webView -> do
                containerRemove windowBox webView
                containerAdd inspectorWindow webView
                widgetShowAll inspectorWindow
                return True
            _ -> return False
        
        widgetShowAll inspectorWindow
        return True

    return inspectorWindow


-- | Show web inspector for current webpage.
showWebInspector :: Browser -> IO ()
showWebInspector browser = do
    inspector <- webViewGetInspector (mWebView $ mGUI browser)
    webInspectorInspectCoordinates inspector 0 0

-- }}}


-- {{{ Prompt
-- | Show or hide the prompt bar (label + entry).
showPrompt :: Bool -> Browser -> IO ()
showPrompt toShow browser = case toShow of
    False -> do widgetHide (mPromptLabel $ mGUI browser)
                widgetHide (mPromptEntry $ mGUI browser)
    _     -> do widgetShow (mPromptLabel $ mGUI browser)
                widgetShow (mPromptEntry $ mGUI browser)

-- | Show the prompt bar label and default text.
-- As the user validates its entry, the given callback is executed.
prompt :: String -> String -> Bool -> Browser -> (String -> Browser -> IO ()) -> IO ()
prompt label defaultText incremental browser callback = let
        promptLabel = (mPromptLabel $ mGUI browser)
        promptEntry = (mPromptEntry $ mGUI browser)
        webView     = (mWebView     $ mGUI browser)
    in do
    -- Fill prompt
        labelSetText promptLabel label
        entrySetText promptEntry defaultText
        
    -- Focus on prompt
        showPrompt True browser
        widgetGrabFocus promptEntry
        editableSetPosition promptEntry (-1)

    -- Register callback
        case incremental of
            True -> do 
                id1 <- on promptEntry editableChanged $ do
                    text <- entryGetText promptEntry
                    liftIO $ callback text browser
                rec id2 <- on promptEntry keyPressEvent $ do
                    key <- eventKeyName
                    
                    case key of
                        "Return" -> do
                            liftIO $ showPrompt False browser
                            liftIO $ signalDisconnect id1
                            liftIO $ signalDisconnect id2
                            liftIO $ widgetGrabFocus webView
                        "Escape" -> do
                            liftIO $ showPrompt False browser
                            liftIO $ signalDisconnect id1
                            liftIO $ signalDisconnect id2
                            liftIO $ widgetGrabFocus webView
                        _ -> return ()
                    return False
                return ()

            _ -> do
                rec id <- on promptEntry keyPressEvent $ do
                    key  <- eventKeyName
                    text <- liftIO $ entryGetText promptEntry

                    case key of
                        "Return" -> do
                            liftIO $ showPrompt False browser
                            liftIO $ callback text browser
                            liftIO $ signalDisconnect id
                            liftIO $ widgetGrabFocus webView
                        "Escape" -> do
                            liftIO $ showPrompt False browser
                            liftIO $ signalDisconnect id
                            liftIO $ widgetGrabFocus webView
                        _        -> return ()
                    return False

                return ()
-- }}}


-- {{{ Util
-- | Toggle statusbar's visibility
toggleStatusBar :: Browser -> IO ()
toggleStatusBar browser = do
    visibility <- get (mStatusBox $ mGUI browser) widgetVisible
    case visibility of
        False -> widgetShow (mStatusBox $ mGUI browser)
        _     -> widgetHide (mStatusBox $ mGUI browser)


-- | Set the window fullscreen
fullscreen :: Browser -> IO ()
fullscreen   browser = windowFullscreen   (mWindow $ mGUI browser)

-- | Restore the window from fullscreen
unfullscreen :: Browser -> IO ()
unfullscreen browser = windowUnfullscreen (mWindow $ mGUI browser)
-- }}}
