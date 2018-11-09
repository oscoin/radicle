{-# LANGUAGE QuasiQuotes #-}

module RadicleExe (main) where

import           API
import           Control.Monad.Catch (MonadThrow)
import           Data.Scientific (floatingOrInteger)
import qualified Data.Text as T
import           GHC.Exts (fromList)
import           Network.HTTP.Client (defaultManagerSettings, newManager)
import qualified Network.HTTP.Client as HttpClient
import           Options.Applicative
import           Prelude (String)
import           Protolude hiding (TypeError, option)
import           Radicle
import           Servant.Client
import           System.Console.Haskeline (InputT)
import           System.Directory (doesFileExist)

import           Radicle.Internal.Doc (md)
import qualified Radicle.Internal.PrimFns as PrimFns

main :: IO ()
main = do
    opts' <- execParser allOpts
    cfgFile <- case configFile opts' of
        Nothing  -> getConfigFile
        Just cfg -> pure cfg
    cfgSrc <- do
       exists <- doesFileExist cfgFile
       if exists
           then readFile cfgFile
           else die $ "Could not find file: " <> toS cfgFile
    hist <- case histFile opts' of
        Nothing -> getHistoryFile
        Just h  -> pure h
    mgr <- newManager defaultManagerSettings
    repl (Just hist) (toS cfgFile) cfgSrc (bindings mgr)
  where
    allOpts = info (opts <**> helper)
        ( fullDesc
       <> progDesc radDesc
       <> header "The radicle intepreter"
        )

radDesc :: String
radDesc
    = "Interprets a radicle program.\n"
   <> "\n"
   <> "This program can also be used as a REPL by providing a file "
   <> "that defines a REPL. An example is the rad/repl.rad file included "
   <> "in the distribution."

-- * CLI Opts

data Opts = Opts
    { configFile :: Maybe FilePath
    , histFile   :: Maybe FilePath
    }

opts :: Parser Opts
opts = Opts
    <$> argument (optional str)
        ( metavar "FILE"
       <> help
           ( "File to interpret."
          <> "Defaults to $DIR/radicle/config.rad "
          <> "where $DIR is $XDG_CONFIG_HOME (%APPDATA% on Windows "
          <> "if that is set, or else ~/.config."
           )
        )
    <*> optional (strOption
        ( long "histfile"
       <> short 'H'
       <> metavar "FILE"
       <> help
           ( "File used to store the REPL history."
          <> "Defaults to $DIR/radicle/config.rad "
          <> "where $DIR is $XDG_DATA_HOME (%APPDATA% on Windows "
          <> "if that is set, or else ~/.local/share."
           )
        ))

-- * Primops

bindings :: HttpClient.Manager -> Bindings (PrimFns (InputT IO))
bindings mgr = addPrimFns (replPrimFns <> clientPrimFns mgr) pureEnv

clientPrimFns :: HttpClient.Manager -> PrimFns (InputT IO)
clientPrimFns mgr = fromList . PrimFns.allDocs $ [sendPrimop, receivePrimop]
  where
    sendPrimop =
      ( "send!"
      , [md|Given a URL (string) and a value, sends the value `v` to the remote
           chain located at the URL for evaluation.|]
      , \case
         [String url, v] -> do
             res <- liftIO $ runClientM' url mgr (submit v)
             case res of
                 Left e   -> throwErrorHere . OtherError
                           $ "send!: failed:" <> show e
                 Right r  -> pure r
         [_, _] -> throwErrorHere $ TypeError "send!: first argument should be a string"
         xs     -> throwErrorHere $ WrongNumberOfArgs "send!" 2 (length xs)
      )
    receivePrimop =
      ( "receive!"
      , [md|Given a URL (string) and a integral number `n`, queries the remote chain
           for the last `n` inputs that have been evaluated.|]
      , \case
          [String url, Number n] -> do
              case floatingOrInteger n of
                  Left (_ :: Float) -> throwErrorHere . OtherError
                                     $ "receive!: expecting int argument"
                  Right r -> do
                      liftIO (runClientM' url mgr (since r)) >>= \case
                          Left err -> throwErrorHere . OtherError
                                    $ "receive!: request failed:" <> show err
                          Right v' -> pure v'
          [String _, _] -> throwErrorHere $ TypeError "receive!: expecting number as second arg"
          [_, _]        -> throwErrorHere $ TypeError "receive!: expecting string as first arg"
          xs            -> throwErrorHere $ WrongNumberOfArgs "receive!" 2 (length xs)
      )

-- * Client functions

submit :: Value -> ClientM Value
submit = client chainSubmitEndpoint

since :: Int -> ClientM Value
since = client chainSinceEndpoint

runClientM' :: (MonadThrow m, MonadIO m) => Text -> HttpClient.Manager -> ClientM a -> m (Either ServantError a)
runClientM' baseUrl manager endpoint = do
    url <- parseBaseUrl $ T.unpack baseUrl
    liftIO $ runClientM endpoint $ mkClientEnv manager url
