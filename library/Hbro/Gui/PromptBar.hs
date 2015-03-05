{-# LANGUAGE ConstraintKinds    #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleContexts   #-}
{-# LANGUAGE NoImplicitPrelude  #-}
{-# LANGUAGE TemplateHaskell    #-}
{-# LANGUAGE TypeFamilies       #-}
-- | Designed to be imported as @qualified@.
module Hbro.Gui.PromptBar (
-- * Types
      PromptBar
    , PromptBarTag(..)
    , PromptBarReader
    , boxL
    , closedL
    , getPromptBar
    , buildFrom
    , labelName
    , entryName
    , boxName
-- * Functions
    , initialize
    , close
    , Hbro.Gui.PromptBar.clean
-- * Prompts
    , prompt
    , uriPrompt
    , iprompt
    , getPromptValue
-- * Monadic versions
    , promptM
    , uriPromptM
    , ipromptM
    , getPromptValueM
) where

-- {{{ Imports
import           Hbro.Attributes
import           Hbro.Error
import           Hbro.Event
import           Hbro.Gdk.KeyVal
import           Hbro.Gui.Builder
import           Hbro.Logger                     hiding (initialize)
import           Hbro.Prelude                    hiding (on)

import           Control.Concurrent.Async.Lifted
import           Control.Lens.Getter
import           Control.Lens.TH

import           Graphics.Rendering.Pango.Enums
import           Graphics.UI.Gtk.Abstract.Widget
import qualified Graphics.UI.Gtk.Builder         as Gtk
import           Graphics.UI.Gtk.Display.Label
import           Graphics.UI.Gtk.Entry.Editable
import           Graphics.UI.Gtk.Entry.Entry
import           Graphics.UI.Gtk.Gdk.EventM      as Gdk
import           Graphics.UI.Gtk.Layout.HBox

import           Network.URI.Extended

import           System.Glib.Signals             hiding (Signal)
-- }}}

-- {{{ Types
data Closed = Closed deriving(Show)
instance Event Closed

data Changed   = Changed deriving(Show)
instance Event Changed where
  type Input Changed = Text

-- | No exported constructor, please use 'buildFrom'
declareLenses [d|
  data PromptBar = PromptBar
    { boxL         :: HBox
    , descriptionL :: Label
    , entryL       :: Entry
    , changedL     :: Signal Changed
    , closedL      :: Signal Closed
    , validatedL   :: TMVar Text
    }
  |]

data PromptBarTag = PromptBarTag
type PromptBarReader m = MonadReader PromptBarTag PromptBar m

getPromptBar :: (PromptBarReader m) => m PromptBar
getPromptBar = read PromptBarTag
-- }}}

-- | A 'PromptBar' can be built from an XML file.
buildFrom :: (BaseIO m, Applicative m) => Gtk.Builder -> m PromptBar
buildFrom builder = do
    validation  <- io newEmptyTMVarIO
    entry       <- getWidget builder entryName
    closeSignal <- newSignal Closed

    promptBar <- PromptBar <$> getWidget builder boxName
                           <*> getWidget builder labelName
                           <*> pure entry
                           <*> newSignal Changed
                           <*> pure closeSignal
                           <*> pure validation

    onEntryChanged entry $ emit (promptBar^.changedL)
    onEntryCanceled entry . async $ close promptBar
    onEntryValidated entry $ \value -> atomically $ tryTakeTMVar validation >> putTMVar validation value

    return promptBar


-- | Widget name used in the XML file that describes the UI
labelName, entryName, boxName :: Text
labelName = "promptDescription"
entryName = "promptEntry"
boxName   = "promptBox"

-- | Error message
promptInterrupted :: Text
promptInterrupted = "Prompt interrupted."

initialize :: (MonadIO m) => PromptBar -> m PromptBar
initialize =
    withM_ descriptionL (gAsync . (`labelSetAttributes` [allItalic, allBold]))
    >=> withM_ descriptionL (gAsync . (`labelSetAttributes` [AttrForeground {paStart = 0, paEnd = -1, paColor = gray}]))
    >=> withM_ entryL (gAsync . (\e -> widgetModifyBase e StateNormal black))
    >=> withM_ entryL (gAsync . (\e -> widgetModifyText e StateNormal gray))


open :: (MonadIO m) => Text -> Text -> PromptBar -> m PromptBar
open description defaultText =
    withM_ descriptionL (gAsync . (`labelSetText` description))
        >=> withM_ entryL (gAsync . (`entrySetText` defaultText))
        >=> withM_ boxL (gAsync . widgetShow)
        >=> withM_ entryL (gAsync . widgetGrabFocus)
        >=> withM_ entryL (gAsync . (`editableSetPosition` (-1)))

close :: (ControlIO m) => PromptBar -> m PromptBar
close promptBar = do
  runFailT $ do
    guard =<< get (promptBar^.boxL) widgetVisible
    emit (promptBar^.closedL) ()
    gAsync . widgetHide $ promptBar^.boxL
    void $ clean promptBar
  return promptBar

-- | Close prompt, that is: clean its content, signals and callbacks
clean :: (ControlIO m) => PromptBar -> m PromptBar
clean = withM_ entryL (gAsync . (`widgetRestoreText` StateNormal))
    >=> withM_ entryL (gAsync . (\e -> widgetModifyText e StateNormal gray))
    >=> withM_ validatedL (void . atomically . tryTakeTMVar)


-- {{{ Prompts
-- | Open prompt bar with given description and default value,
-- register a callback to trigger when value is changed, and another one when value is validated.
prompt :: (ControlIO m, MonadError Text m)
        => Text             -- ^ Prompt description
        -> Text             -- ^ Pre-fill value
        -> PromptBar
        -> m Text
prompt description startValue promptBar = do
    clean promptBar
    open description startValue promptBar

    cancelation <- listenTo (promptBar^.closedL)
    validation  <- io . async . atomically . takeTMVar $ promptBar^.validatedL

    result <- io $ waitEitherCancel cancelation validation
    close promptBar
    either (const $ throwError promptInterrupted) return result

promptM :: (ControlIO m, MonadError Text m, PromptBarReader m) => Text -> Text -> m Text
promptM a b = prompt a b =<< read PromptBarTag


iprompt :: (ControlIO m, MonadError Text m)
        => Text
        -> Text
        -> (Text -> m ())
        -> PromptBar
        -> m ()
iprompt description startValue f promptBar = do
    clean promptBar

    update <- addHook (promptBar^.changedL) f
    open description startValue promptBar

    io . wait =<< listenTo (promptBar^.closedL)
    close promptBar
    cancel update

ipromptM :: (ControlIO m, MonadError Text m, PromptBarReader m) => Text -> Text -> (Text -> m ()) -> m ()
ipromptM a b c = iprompt a b c =<< read PromptBarTag


-- | Same as 'prompt' for URI values
uriPrompt :: (ControlIO m, MonadError Text m)
          => Text
          -> Text
          -> PromptBar
          -> m URI
uriPrompt description startValue promptBar = do
    clean promptBar

    update <- addHook (promptBar^.changedL) $ checkURI promptBar
    open description startValue promptBar

    validation  <- io . async . atomically . takeTMVar $ promptBar^.validatedL
    cancelation <- listenTo (promptBar^.closedL)

    result <- io $ waitEitherCancel cancelation validation
    close promptBar
    cancel update
    let resultM = either (const $ throwError promptInterrupted) return result

    parseURIReferenceM =<< resultM

uriPromptM :: (ControlIO m, MonadError Text m, PromptBarReader m) => Text -> Text -> m URI
uriPromptM a b = uriPrompt a b =<< read PromptBarTag


checkURI :: (MonadIO m) => PromptBar -> Text -> m ()
checkURI promptBar v = do
    debugM $ "Is URI ? " ++ tshow (isURIReference $ unpack v)
    gAsync $ widgetModifyText (promptBar^.entryL) StateNormal (green <| isURIReference (unpack v) |> red)


getPromptValue :: (MonadIO m) => PromptBar -> m Text
getPromptValue = gSync . entryGetText . view entryL

getPromptValueM :: (MonadIO m, PromptBarReader m) => m Text
getPromptValueM = getPromptValue =<< read PromptBarTag


onEntryCanceled :: (MonadIO m, EntryClass t) => t -> IO a -> m (ConnectId t)
onEntryCanceled entry f = gSync . on entry keyPressEvent $ do
    key <- KeyVal <$> eventKeyVal
    io . when (key == _Escape) $ do
        value <- entryGetText entry
        debugM $ "Entry cancelled with value: " ++ value
        void f
    return False

onEntryChanged :: (MonadIO m, EditableClass t, EntryClass t) => t -> (Text -> IO ()) -> m (ConnectId t)
onEntryChanged entry f = gSync . on entry editableChanged $ do
    value <- entryGetText entry
    debugM $ "Entry value changed to: " ++ value
    f value

onEntryValidated :: (MonadIO m, EntryClass t) => t -> (Text -> IO ()) -> m (ConnectId t)
onEntryValidated entry f = gSync . on entry entryActivated $ do
    value <- entryGetText entry
    debugM $ "Entry validated with value: " ++ value
    f value