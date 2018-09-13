module Radicle.Internal.Parse where

import           Protolude hiding (try)

import           Data.Char (isAlphaNum, isLetter)
import           Data.List.NonEmpty (NonEmpty((:|)))
import qualified Data.Map as Map
import qualified Data.Text as T
import           GHC.Exts (IsString(..))
import           Text.Megaparsec (ParsecT, State(..), between, choice,
                                  defaultTabWidth, eof, initialPos, manyTill,
                                  runParserT, runParserT', sepBy, try, (<?>))
import qualified Text.Megaparsec as M
import           Text.Megaparsec.Char (char, satisfy, space1)
import qualified Text.Megaparsec.Char.Lexer as L
import qualified Text.Megaparsec.Error as Par

import           Radicle.Internal.Core

-- * The parser

type Parser a = ParsecT Void Text (Reader [Ident]) a
type VParser = Parser Value

spaceConsumer :: Parser ()
spaceConsumer = L.space space1 lineComment blockComment
  where
    lineComment  = L.skipLineComment ";;"
    blockComment = L.skipBlockComment "#|" "|#" -- R6RS


symbol :: Text -> Parser Text
symbol = L.symbol spaceConsumer

lexeme :: Parser a -> Parser a
lexeme = L.lexeme spaceConsumer

inside :: Text -> Text -> Parser a -> Parser a
inside b e = between (symbol b >> spaceConsumer) (spaceConsumer >> symbol e)

parensP :: Parser a -> Parser a
parensP = inside "(" ")"

bracesP :: Parser a -> Parser a
bracesP = inside "{" "}"

stringLiteralP :: VParser
stringLiteralP = lexeme $
    String . toS <$> (char '"' >> manyTill L.charLiteral (char '"'))

boolLiteralP :: VParser
boolLiteralP = lexeme $ Boolean <$> (char '#' >>
        (char 't' >> pure True) <|> (char 'f' >> pure False))

numLiteralP :: VParser
numLiteralP = Number <$> signed L.scientific
  where
    -- We don't allow spaces between the sign and digits so that we can remain
    -- consistent with the general Scheme of things.
    signed p = M.option identity ((identity <$ char '+') <|> (negate <$ char '-')) <*> p

identP :: Parser Ident
identP = lexeme $ do
    l <- satisfy isValidIdentFirst
    r <- many (satisfy isValidIdentRest)
    pure . Ident $ fromString (l:r)

atomOrPrimP :: VParser
atomOrPrimP = do
    i <- identP
    prims <- ask
    pure $ if i `elem` prims then Primop i else Atom i

keywordP :: VParser
keywordP = do
  _ <- char ':'
  kw <- many (satisfy isValidIdentRest)
  pure . Keyword . Ident . fromString $ kw

listP :: VParser
listP = parensP (List <$> valueP `sepBy` spaceConsumer)

dictP :: VParser
dictP = bracesP (Dict . Map.fromList <$> evenItems)
  where
    evenItems = twoItems `sepBy` spaceConsumer
    twoItems = do
      x <- valueP
      spaceConsumer
      y <- valueP
      pure (x,y)

quoteP :: VParser
quoteP = List . ((Primop $ toIdent "quote") :) . pure <$> (char '\'' >> valueP)

valueP :: VParser
valueP = do
  v <- choice
      [ stringLiteralP <?> "string"
      , boolLiteralP <?> "boolean"
      , keywordP <?> "keyword"
      , try numLiteralP <?> "number"
      , atomOrPrimP <?> "identifier"
      , quoteP <?> "quote"
      , listP <?> "list"
      , dictP <?> "dict"
      ]
  spaceConsumer
  pure v

-- * Utilities

-- | Parse and evaluate a Text. Replaces refs with a number representing them.
--
-- Examples:
--
-- >>> import Control.Monad.Identity
-- >>> import Radicle.Internal.Primops
-- >>> runIdentity $ interpret "test" "((lambda (x) x) #t)" pureEnv
-- Right (Boolean True)
--
-- >>> import Control.Monad.Identity
-- >>> runIdentity $ interpret "test" "(#t #f)" pureEnv
-- Left (TypeError "Trying to apply a non-function")
interpret
    :: Monad m
    => Text
    -> Text
    -> Bindings m
    -> m (Either (LangError Value) Value)
interpret sourceName expr bnds = do
    let primopNames = Map.keys (bindingsPrimops bnds)
        parsed = runReader (runParserT (valueP <* eof) (toS sourceName) expr) primopNames
    case parsed of
        Left e  -> pure . Left $ ParseError e
        Right v -> fst <$> runLang bnds (eval v)

-- | Parse and evaluate a Text as multiple expressions.
--
-- Examples:
--
-- >>> import Radicle.Internal.Primops
-- >>> fmap fst <$> runLang pureEnv $ interpretMany "test" "(define id (lambda (x) x))\n(id #t)"
-- Right (Boolean True)
interpretMany :: Monad m => Text -> Text -> Lang m Value
interpretMany sourceName src = do
    primopNames <- gets $ Map.keys . bindingsPrimops
    let parsed = parseValues sourceName src primopNames
    case partitionEithers parsed of
        ([], vs) -> do es <- mapM eval vs
                       case lastMay es of
                         Just e -> pure e
                         _ -> throwError (OtherError "InterpretMany should be called with at least one expression.")
        (e:_, _) -> throwError $ ParseError e

-- | Parse a Text as a series of values.
-- 'sourceName' is used for error reporting. 'prims' are the primop names.
--
-- Note that parsing continues even if one value fails to parse.
parseValues :: Text -> Text -> [Ident] -> [Either (Par.ParseError Char Void) Value]
parseValues sourceName srcCode prims = go $ initial
  where
    initial = State
        { stateInput = T.strip srcCode
        , statePos = initialPos (toS sourceName) :| []
        , stateTokensProcessed = 0
        , stateTabWidth = defaultTabWidth
        }
    go s = let (s', v) = runReader (runParserT' valueP s) prims
           in if T.null (stateInput s') then [v] else v:go s'

-- | Parse a value, using the String as source name, and the identifier list as
-- the primops.
--
-- Examples:
--
-- >>> parse "test" "#t" [] :: Either Text Value
-- Right (Boolean True)
--
-- >>> parse "test" "hi" [toIdent "hi"] :: Either Text Value
-- Right (Primop (Ident {fromIdent = "hi"}))
--
-- >>> parse "test" "hi" [] :: Either Text Value
-- Right (Atom (Ident {fromIdent = "hi"}))
parse :: MonadError Text m => Text -> Text -> [Ident] -> m Value
parse file src ids = do
  let res = runReader (M.runParserT (valueP <* eof) (toS file) src) ids
  case res of
    Left err -> throwError . toS $ M.parseErrorPretty' src err
    Right v  -> pure v

-- ** Valid identifiers
-- These are made top-level so construction of arbitrary instances that matches
-- parsing is easier. Note that additionally an identifier must not be a valid
-- number (in parsing numbers are parsed first).

-- | A predicate which returns true if the character is valid as the first
-- character of an identifier.
isValidIdentFirst :: Char -> Bool
isValidIdentFirst x = x /= ':' && (isLetter x || x `elem` extendedChar)

-- | A predicate which returns true if the character is valid as the second or
-- later character of an identifier.
isValidIdentRest :: Char -> Bool
isValidIdentRest x = isAlphaNum x || x `elem` extendedChar

extendedChar :: [Char]
extendedChar = ['!', '$', '%', '&', '*', '+', '-', '.', '/', ':', '<' , '=', '>'
  , '?', '@', '^', '_', '~']
