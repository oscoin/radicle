-- | This module defines fine-grained monad classes for effects.
--
-- The intent is that any set of primops may wear on their sleaves (i.e.
-- constraints) what effects they do.
{-# LANGUAGE CPP #-}
module Radicle.Internal.Effects.Capabilities where

import           Protolude

import qualified Data.ByteString as BS
import           Data.Text.Prettyprint.Doc (PageWidth)
import           Data.Time
import           System.Console.ANSI (hSupportsANSI)
import           System.Console.Haskeline hiding (catch)
import           System.Exit (ExitCode)
import           System.IO
                 ( BufferMode(LineBuffering)
                 , hClose
                 , hFlush
                 , hGetLine
                 , hIsEOF
                 , hSetBuffering
                 , isEOF
                 )
import           System.Process
                 (CreateProcess, ProcessHandle, createProcess, waitForProcess)
#ifdef ghcjs_HOST_OS
import           GHCJS.DOM.XMLHttpRequest
                 (getResponseText, newXMLHttpRequest, openSimple, send)
#endif

import           Radicle.Internal.Core

class (Monad m) => Stdin m where
    getLineS :: m (Maybe Text)  -- gives Nothing on EOF
instance {-# OVERLAPPABLE #-} Stdin m => Stdin (Lang m) where
    getLineS = lift getLineS
instance Stdin IO where
    getLineS = do
        done <- isEOF
        if done
        then pure Nothing
        else Just <$> getLine
instance (MonadException m) => Stdin (InputT m) where
    getLineS = (fmap.fmap) toS (getInputLine "rad> ")

class (Monad m) => Stdout m where
    putStrS :: Text -> m ()
    -- | Return true if we can output ANSI control characters with
    -- 'putStrS'.
    supportsANSI :: m Bool
instance {-# OVERLAPPABLE #-} Stdout m => Stdout (Lang m) where
    putStrS = lift . putStrS
    supportsANSI = lift supportsANSI
instance Stdout IO where
    putStrS = putStrLn
    supportsANSI = hSupportsANSI stdout
instance (MonadException m, Monad m) => Stdout (InputT m) where
    putStrS = outputStrLn . toS
    supportsANSI = pure True


class (Monad m) => System m where
    systemS
      :: CreateProcess
      -> m (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle)
    waitForProcessS :: ProcessHandle -> m ExitCode
    hPutStrS :: Handle -> Text -> m ()
    -- | hGetLine should return Nothing on EOF.
    hGetLineS :: Handle -> m (Maybe Text)
    hCloseS :: Handle -> m ()
    openFileS :: Text -> IOMode -> m (Either Text Handle)

instance System m => System (Lang m) where
    systemS proc = lift $ systemS proc
    waitForProcessS = lift . waitForProcessS
    hPutStrS a b = lift $ hPutStrS a b
    hGetLineS = lift . hGetLineS
    hCloseS = lift . hCloseS
    openFileS f mode = lift $ openFileS f mode

instance System IO where
    systemS = createProcess
    waitForProcessS = waitForProcess
    hPutStrS h t = hSetBuffering h LineBuffering >> hPutStr h t >> hFlush h
    hGetLineS h = do
        eof <- hIsEOF h
        if eof
            then pure Nothing
            else do
                hSetBuffering h LineBuffering
                Just . toS <$> hGetLine h
    hCloseS = hClose
    openFileS f mode = catch (Right <$> openFile (toS f) mode)
                             (\e -> pure . Left $ show (e :: IOException))

instance System m => System (InputT m) where
    systemS proc = lift $ systemS proc
    waitForProcessS = lift . waitForProcessS
    hPutStrS a b = lift $ hPutStrS a b
    hGetLineS = lift . hGetLineS
    hCloseS = lift . hCloseS
    openFileS f mode = lift $ openFileS f mode

class Monad m => CurrentTime m where
  currentTime :: m UTCTime

instance CurrentTime IO where
  currentTime = getCurrentTime
instance CurrentTime (InputT IO) where
  currentTime = liftIO getCurrentTime
instance CurrentTime m => CurrentTime (Lang m) where
  currentTime = lift currentTime

class (Monad m) => GetEnv m r | m -> r where
    getEnvS :: m (Env r)
instance Monad m => GetEnv (Lang m) Value where
    getEnvS = gets bindingsEnv

class (Monad m) => SetEnv m r | m -> r where
    setEnvS :: Env r -> m ()
instance Monad m => SetEnv (Lang m) Value where
    setEnvS e = modify (\bnds -> bnds {bindingsEnv = e})

class (Monad m) => GetSourceName m where
    getSourceNameS :: m Text
class (Monad m) => HasPageWidth m where
    getPageWidthS :: m PageWidth
class (Monad m) => GetSubs m where
    getSubsS :: m [(Text, Value -> m ())]
class (Monad m) => SetSubs m where
    setSubS :: Text -> (Value -> m ()) -> m ()

class (Monad m) => ReadFile m where
    readFileS :: Text -> m (Either Text Text)  -- ^ Left error or Right contents
#ifdef ghcjs_HOST_OS
instance ReadFile (InputT IO) where
    readFileS = lift . requestFile
      where
        requestFile :: Text -> IO (Either Text Text)
        requestFile filename = do
            req <- newXMLHttpRequest
            openSimple req ("GET" :: Text) filename
            send req
            resp <- getResponseText req
            pure $ case resp of
                Nothing -> Left "no response from server"
                Just v  -> Right v
#else
instance ReadFile (InputT IO) where
    readFileS = lift . readFileS
instance ReadFile IO where
    readFileS fname = (Right . decodeUtf8With lenientDecode <$> BS.readFile (toS fname))
                        `catch` (\(e :: IOException) -> pure (Left (show e)))
#endif
instance {-# OVERLAPPABLE #-} ReadFile m => ReadFile (Lang m) where
    readFileS = lift . readFileS

putStrLnS :: (Stdout m) => Text -> m ()
putStrLnS t = putStrS t >> putStrS "\n"

modifyEnvS :: (GetEnv m r, SetEnv m r) => (Env r -> Env r) -> m ()
modifyEnvS f = getEnvS >>= setEnvS . f
