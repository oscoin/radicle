{-# OPTIONS_GHC -fno-warn-orphans #-}
module Radicle.Internal.Effects where

import           Protolude hiding (TypeError)

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

import qualified Radicle.Internal.Doc as Doc
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

replBindings :: forall m. ReplM m => Bindings (PrimFns m)
replBindings = e { bindingsPrimFns = bindingsPrimFns e <> replPrimFns
                 , bindingsEnv = bindingsEnv e <> primFnsEnv pfs }
    where
      e :: Bindings (PrimFns m)
      e = pureEnv
      pfs :: PrimFns m
      pfs = replPrimFns

replPrimFns :: forall m. ReplM m => PrimFns m
replPrimFns = fromList $ Doc.noDocs $ first unsafeToIdent <$>
    [ ("print!", \case
        [x] -> do
            putStrS (renderPrettyDef x)
            pure nil
        xs  -> throwErrorHere $ WrongNumberOfArgs "print!" 1 (length xs))

    , ( "actual-doc"
      , oneArg "actual-doc" $ \case
          Atom i -> do
            d_ <- lookupAtomDoc i
            case d_ of
              Nothing -> do
                putStrS "No docs."
                pure nil
              Just d -> case Doc.toMD d of
                Left e -> do
                  putStrS (show e)
                  pure nil
                Right md -> do
                  putStrS md
                  pure nil
          _ -> throwErrorHere $ TypeError "actual-doc: expects an atom"
      )

    , ("set-env!", \case
        [Atom x, v] -> do
            defineAtom x Nothing v
            pure nil
        [_, _] -> throwErrorHere $ TypeError "Expected atom as first arg"
        xs  -> throwErrorHere $ WrongNumberOfArgs "set-env!" 2 (length xs))

    , ("get-line!", \case
        [] -> String <$> getLineS
        xs -> throwErrorHere $ WrongNumberOfArgs "get-line!" 0 (length xs))

    , ("subscribe-to!", \case
        [x, v] -> do
            e <- gets bindingsEnv
            case (x, v) of
                (Dict m, fn) -> case Map.lookup (Keyword $ unsafeToIdent "getter") m of
                    Nothing -> throwErrorHere
                        $ OtherError "subscribe-to!: Expected ':getter' key"
                    Just g -> forever (protect go)
                      where
                        protect action = do
                            st <- get
                            action `catchError`
                                (\err -> case err of
                                   LangError _ Exit -> throwError err
                                   LangError _ (Impossible _) -> do
                                       putStrS (renderPrettyDef err)
                                       throwError err
                                   _ -> putStrS (renderPrettyDef err) >> put st)
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
      , oneArg "read-file" $ \case
          String filename -> String <$> readFileS filename
          _ -> throwErrorHere $ TypeError "read-file: expects a string"
      )
    , ( "load!"
      , oneArg "load!" $ \case
          String filename -> readFileS filename >>= interpretMany ("[load! " <> filename <> "]")
          _ -> throwErrorHere $ TypeError "load: expects a string"
      )
    , ( "gen-key-pair!"
      , \case
          [curvev] -> do
            curve <- hoistEither . first (toLangError . OtherError) $ fromRad curvev
            (pk, sk) <- generateKeyPair curve
            let pkv = toRad pk
            let skv = toRad sk
            pure . Dict . Map.fromList $
              [ (Keyword (Ident "private-key"), skv)
              , (Keyword (Ident "public-key"), pkv)
              ]
          xs -> throwErrorHere $ WrongNumberOfArgs "gen-key-pair!" 0 (length xs)
      )
    , ( "gen-signature!"
      , \case
          [skv, String msg] -> do
            sk <- hoistEither . first (toLangError . OtherError) $ fromRad skv
            toRad <$> signText sk msg
          _ -> throwErrorHere $ TypeError "gen-signature!: expects a string."
      )
    , ( "uuid!"
      , \case
          [] -> String <$> UUID.uuid
          xs -> throwErrorHere $ WrongNumberOfArgs "uuid!" 0 (length xs)
      )
    ]
