module Client where

import           API
import           Data.Scientific (floatingOrInteger)
import           GHC.Exts (fromList)
import           Network.HTTP.Client (defaultManagerSettings, newManager)
import           Options.Applicative
import           Protolude hiding (TypeError, option)
import           Radicle
import           Servant.API ((:<|>)(..))
import           Servant.Client
import           System.Console.Haskeline (InputT)

main :: IO ()
main = do
    opts' <- execParser allOpts
    cfgFile <- case configFile opts' of
        Nothing  -> getConfig
        Just cfg -> pure cfg
    cfgSrc <- readFile cfgFile
    hist <- case histFile opts' of
        Nothing -> getHistory
        Just h  -> pure h
    mgr <- newManager defaultManagerSettings
    let cEnv = mkClientEnv mgr (serverURL opts')
    repl (Just hist) (toS cfgFile) cfgSrc (bindings cEnv)
  where
    allOpts = info (opts <**> helper)
        ( fullDesc
       <> progDesc "Run the radicle REPL"
       <> header "rad - The radicle REPL"
        )

-- * CLI Opts

data Opts = Opts
    { configFile :: Maybe FilePath
    , serverURL  :: BaseUrl
    , histFile   :: Maybe FilePath
    }

opts :: Parser Opts
opts = Opts
    <$> optional (strOption
        ( long "config"
       <> metavar "FILE"
       <> help "rad configuration file"
        ))
    <*> option (str >>= parseBaseUrl')
        ( long "url"
       <> metavar "URL"
       <> help "URL of server"
        )
    <*> optional (strOption
        ( long "histfile"
       <> metavar "FILE"
       <> help "repl history file"
        ))
  where
    parseBaseUrl' x = case parseBaseUrl x of
        Nothing -> readerError "can't parse URL"
        Just v  -> pure v

-- * Primops

bindings :: ClientEnv -> Bindings (Primops (InputT IO))
bindings cEnv = e { bindingsPrimops = bindingsPrimops e <> primops cEnv }
    where
      e :: Bindings (Primops (InputT IO))
      e = pureEnv

primops :: ClientEnv -> Primops (InputT IO)
primops cEnv = Primops (fromList [sendPrimop, receivePrimop]) <> replPrimops
  where
    sendPrimop =
      ( unsafeToIdent "send!"
      , evalArgs $ \case
         [String name, v] -> do
             res <- liftIO $ runClientM (submit $ List $ [String name, v]) cEnv
             case res of
                 Left e   -> throwErrorHere . OtherError
                           $ "send!: failed:" <> show e
                 Right () -> pure $ List []
         [_, _] -> throwErrorHere $ TypeError "send!: first argument should be a string"
         xs     -> throwErrorHere $ WrongNumberOfArgs "send!" 2 (length xs)
      )
    receivePrimop =
      ( unsafeToIdent "receive!"
      , evalArgs $ \case
          [String name, Number n] -> do
              case floatingOrInteger n of
                  Left (_ :: Float) -> throwErrorHere . OtherError
                                     $ "receive!: expecting int argument"
                  Right r -> do
                      liftIO (runClientM (since name r) cEnv) >>= \case
                          Left err -> throwErrorHere . OtherError
                                    $ "receive!: request failed:" <> show err
                          Right v' -> pure $ List v'
          [String _, _] -> throwErrorHere $ TypeError "receive!: expecting number as second arg"
          [_, _]        -> throwErrorHere $ TypeError "receive!: expecting string as first arg"
          xs            -> throwErrorHere $ WrongNumberOfArgs "receive!" 2 (length xs)
      )

-- * Helpers

identV :: Text -> Value
identV = Keyword . unsafeToIdent

-- * Client functions

submit :: Value -> ClientM ()
since :: Text -> Int -> ClientM [Value]
submit :<|> since :<|> _ = client api
