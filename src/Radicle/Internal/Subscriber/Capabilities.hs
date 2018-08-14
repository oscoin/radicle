-- | This module defines fine-grained monad classes for effects.
--
-- The intent is that any set of primops may wear on their sleaves (i.e.
-- constraints) what effects they do.
module Radicle.Internal.Subscriber.Capabilities where

import           Control.Monad.State (gets, modify)
import           Control.Monad.Trans
import           Data.Text (Text)
import qualified Data.Text as T
import           Data.Text.Prettyprint.Doc (PageWidth)
import           System.Console.Haskeline

import           Radicle.Internal.Core

class (Monad m) => Stdin m where
    getLineS :: m Text
instance {-# OVERLAPPABLE #-} Stdin m => Stdin (Lang m) where
    getLineS = lift getLineS
instance (MonadException m, Monad m) => Stdin (InputT m) where
    getLineS = getInputLine "rad> " >>= \x -> case x of
        Nothing -> error "curious about why this would happen"
        Just v  -> pure $ T.pack v

class (Monad m) => Stdout m where
    putStrS :: Text -> m ()
instance {-# OVERLAPPABLE #-} Stdout m => Stdout (Lang m) where
    putStrS = lift . putStrS
instance (MonadException m, Monad m) => Stdout (InputT m) where
    putStrS = outputStrLn . T.unpack

class (Monad m) => Exit m where
    exitS :: m ()
instance Exit m => Exit (Lang m) where
    exitS = lift exitS

class (Monad m) => GetEnv m r | m -> r where
    getEnvS :: m (Env r)
instance Monad m => GetEnv (Lang m) Value where
    getEnvS = gets bindingsEnv

class (Monad m) => SetEnv m r | m -> r where
    setEnvS :: Env r -> m ()
instance Monad m => SetEnv (Lang m) Value where
    setEnvS e = modify (\bnds -> bnds {bindingsEnv = e})

class (Monad m) => GetSourceName m where
    getSourceNameS :: m String
class (Monad m) => HasPageWidth m where
    getPageWidthS :: m PageWidth
class (Monad m) => GetSubs m where
    getSubsS :: m [(Text, Value -> m ())]
class (Monad m) => SetSubs m where
    setSubS :: Text -> (Value -> m ()) -> m ()

putStrLnS :: (Stdout m) => Text -> m ()
putStrLnS t = putStrS t >> putStrS "\n"

modifyEnvS :: (GetEnv m r, SetEnv m r) => (Env r -> Env r) -> m ()
modifyEnvS f = getEnvS >>= setEnvS . f
