{-# OPTIONS_GHC -fno-warn-orphans #-}

module Radicle.Internal.Effects where

import           Protolude hiding (TypeError, toList)

import qualified Data.Map as Map
import qualified Data.Text as T
import           Data.Text.Prettyprint.Doc (pretty)
import           Data.Text.Prettyprint.Doc.Render.Terminal (putDoc)
import           GHC.Exts (IsList(..))
import           System.Console.Haskeline
                 ( CompletionFunc
                 , InputT
                 , completeWord
                 , defaultSettings
                 , historyFile
                 , runInputT
                 , setComplete
                 , simpleCompletion
                 )

import           Radicle.Internal.Core
import           Radicle.Internal.Crypto
import           Radicle.Internal.Effects.Capabilities
import           Radicle.Internal.Interpret
import           Radicle.Internal.Pretty
import           Radicle.Internal.PrimFns
import qualified Radicle.Internal.UUID as UUID


type ReplM m =
    ( Monad m, Stdout (Lang m), Stdin (Lang m)
    , MonadRandom m, UUID.MonadUUID m
    , ReadFile (Lang m)
    , GetEnv (Lang m) Value
    , SetEnv (Lang m) Value )

instance MonadRandom (InputT IO) where
    getRandomBytes = liftIO . getRandomBytes
instance MonadRandom m => MonadRandom (LangT (Bindings (PrimFns m)) m) where
    getRandomBytes = lift . getRandomBytes

instance UUID.MonadUUID (InputT IO) where
    uuid = liftIO UUID.uuid
instance UUID.MonadUUID m => UUID.MonadUUID (LangT (Bindings (PrimFns m)) m) where
    uuid = lift UUID.uuid

repl :: Maybe FilePath -> Text -> Text -> Bindings (PrimFns (InputT IO)) -> IO ()
repl histFile preFileName preCode bindings = do
    let settings = setComplete completion
                 $ defaultSettings { historyFile = histFile }
    r <- runInputT settings
        $ fmap fst $ runLang bindings
        $ void $ interpretMany preFileName preCode
    case r of
        Left (LangError _ Exit) -> pure ()
        Left e                  -> putDoc $ pretty e
        Right ()                -> pure ()

completion :: Monad m => CompletionFunc m
completion = completeWord Nothing ['(', ')', ' ', '\n'] go
  where
    -- Any type for first param will do
    bnds :: Bindings (PrimFns (InputT IO))
    bnds = replBindings

    go s = pure $ fmap simpleCompletion
         $ filter (s `isPrefixOf`)
         $ fmap (T.unpack . fromIdent)
         $ (Map.keys . fromEnv $ bindingsEnv bnds)
        <> Map.keys (getPrimFns $ bindingsPrimFns bnds)

replBindings :: ReplM m => Bindings (PrimFns m)
replBindings = addPrimFns replPrimFns pureEnv

replPrimFns :: ReplM m => PrimFns m
replPrimFns = fromList $ allDocs $
    [ ("print!"
      , "Pretty-prints a value."
      , \case
        [x] -> do
            putStrS (renderPrettyDef x)
            pure nil
        xs  -> throwErrorHere $ WrongNumberOfArgs "print!" 1 (length xs))

    , ( "doc!"
      , "Prints the documentation attached to a value and returns `()`. To retrieve\
        \ the docstring as a value use `doc` instead."
      , oneArg "doc!" $ \case
          Atom i -> do
            d <- lookupAtomDoc i
            putStrS $ fromMaybe "No docs." d
            pure nil
          _ -> throwErrorHere $ TypeError "doc!: expects an atom"
      )

    , ( "apropos!"
      , "Prints documentation for all documented variables in scope."
      , \case
          [] -> do
            env <- gets bindingsEnv
            let docs = [ i <> "\n" <> doc | (Ident i, Just doc, _) <- toList env ]
            putStrS (T.intercalate "\n\n" docs)
            pure nil
          xs -> throwErrorHere $ WrongNumberOfArgs "apropos!" 0 (length xs)
      )

    , ( "set-env!"
      , "Given an atom `x` and a value `v`, sets the value associated to `x` in\
        \ the current environemtn to be `v`. Doesn't evaluate `v`."
      , \case
        [Atom x, v] -> do
            defineAtom x Nothing v
            pure nil
        [_, _] -> throwErrorHere $ TypeError "Expected atom as first arg"
        xs  -> throwErrorHere $ WrongNumberOfArgs "set-env!" 2 (length xs))

    , ( "get-line!"
      , "Reads a single line of input and returns it as a string."
      , \case
          [] -> maybe nil toRad <$> getLineS
          xs -> throwErrorHere $ WrongNumberOfArgs "get-line!" 0 (length xs)
      )

    , ("subscribe-to!"
      , "Expects a dict `s` (representing a subscription) and a function `f`. The dict\
        \ `s` should have a function `getter` at the key `:getter`. This function is called\
        \ repeatedly (with no arguments), its result is then evaluated and passed to `f`."
      , \case
        [x, v] -> do
            e <- gets bindingsEnv
            case (x, v) of
                (Dict m, fn) -> case Map.lookup (Keyword $ unsafeToIdent "getter") m of
                    Nothing -> throwErrorHere
                        $ OtherError "subscribe-to!: Expected ':getter' key"
                    Just g -> loop go
                      where
                        loop action = do
                            st <- get
                            join $ (action >> pure (loop action)) `catchError`
                                (\err -> case err of
                                   LangError _ Exit -> pure (pure nil)
                                   LangError _ (Impossible _) -> do
                                       putStrS (renderPrettyDef err)
                                       throwError err
                                   _ -> do
                                       putStrS (renderPrettyDef err)
                                       put st
                                       pure (loop action))
                        go = do
                            -- We need to evaluate the getter in the original
                            -- environment in which it was defined, but the
                            -- /result/ of the getter is then evaluated in the
                            -- current environment.
                            line <- eval =<< (g $$ [])
                            -- Similarly, the application of the subscriber
                            -- function is evaluated in the original
                            -- environment.
                            void $ withEnv (const e) (fn $$ [quote line])
                _  -> throwErrorHere $ TypeError "subscribe-to!: Expected dict"
        xs  -> throwErrorHere $ WrongNumberOfArgs "subscribe-to!" 2 (length xs))
    , ( "read-file!"
      , "Reads the contents of a file and returns it as a string."
      , oneArg "read-file" $ \case
          String filename -> readFileS filename >>= \case
              Left err -> throwErrorHere . OtherError $ "Error reading file: " <> err
              Right text -> pure $ String text
          _ -> throwErrorHere $ TypeError "read-file: expects a string"
      )
    , ( "load!"
      , "Evaluates the contents of a file. Each seperate radicle expression is\
        \ `eval`uated according to the current definition of `eval`."
      , oneArg "load!" $ \case
          String filename -> readFileS filename >>= \case
              Left err -> throwErrorHere . OtherError $ "Error reading file: " <> err
              Right text -> interpretMany ("[load! " <> filename <> "]") text
          _ -> throwErrorHere $ TypeError "load: expects a string"
      )
    , ( "gen-key-pair!"
      , "Given an elliptic curve, generates a cryptographic key-pair. Use\
        \ `default-ecc-curve` for a default value for the elliptic curve."
      , oneArg "gen-key-pair!" $ \case
          curvev -> do
            curve <- hoistEither . first (toLangError . OtherError) $ fromRad curvev
            (pk, sk) <- generateKeyPair curve
            let pkv = toRad pk
            let skv = toRad sk
            pure . Dict . Map.fromList $
              [ (Keyword (Ident "private-key"), skv)
              , (Keyword (Ident "public-key"), pkv)
              ]
      )
    , ( "gen-signature!"
      , "Given a private key and a message (a string), generates a cryptographic\
        \ signature for the message."
      , \case
          [skv, String msg] -> do
            sk <- hoistEither . first (toLangError . OtherError) $ fromRad skv
            toRad <$> signText sk msg
          _ -> throwErrorHere $ TypeError "gen-signature!: expects a string."
      )
    , ( "uuid!"
      , "Generates a random UUID."
      , \case
          [] -> String <$> UUID.uuid
          xs -> throwErrorHere $ WrongNumberOfArgs "uuid!" 0 (length xs)
      )
    , ( "exit!"
      , "Exit the interpreter immediately."
      , \case
          [] -> throwErrorHere Exit
          xs -> throwErrorHere $ WrongNumberOfArgs "exit!" 0 (length xs)
      )
    ]
