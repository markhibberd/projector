{- | Initial tokeniser pass, preserving all whitespace. -}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module Projector.Html.Syntax.Lexer.Tokenise (
    TokenError (..)
  , renderTokenError
  , tokenise
  , debug
  ) where


import           Control.Monad.Trans.Class (MonadTrans(..))
import           Control.Monad.Trans.State (State, evalState, gets, modify')

import qualified Data.Set as S
import qualified Data.Text as T

import           Projector.Core.Prelude

import           Projector.Html.Data.Position
import           Projector.Html.Syntax.Token

import qualified Text.Megaparsec as P

import           System.IO  (FilePath)


-- -----------------------------------------------------------------------------

newtype TokenError = TokenError {
    unTokenError :: (P.ParseError Char TokenErrorComponent)
  } deriving (Eq, Show)

renderTokenError :: TokenError -> Text
renderTokenError =
  T.pack . P.parseErrorPretty . unTokenError

tokenise :: FilePath -> Text -> Either TokenError [Positioned Token]
tokenise =
  parse' template

debug :: FilePath -> Text -> Either TokenError [(LexerMode, Positioned Token, LexerMode)]
debug =
  parse' templateDebug

parse' :: Parser a -> FilePath -> Text -> Either TokenError a
parse' p file =
  first TokenError . flip evalState defaultLexerState . P.runParserT (p <* P.eof) file

-- -----------------------------------------------------------------------------
-- Parser state - need a stack of modes
newtype LexerState = LexerState {
    unLexerState :: [LexerMode]
  } deriving (Eq, Ord, Show)

defaultLexerState :: LexerState
defaultLexerState =
  LexerState []

peek :: Parser (Maybe LexerMode)
peek =
  lift (gets (head . unLexerState))

push :: LexerMode -> Parser ()
push mo =
  lift . modify' $ \(LexerState mos) ->  LexerState (mo : mos)

pop :: Parser ()
pop =
  lift . modify' $ \(LexerState mos) ->
    case mos of
      (_:xs) ->
        LexerState xs
      [] ->
        LexerState []

satisfyMode :: LexerMode -> Parser a -> Parser a
satisfyMode m p = do
  mmo <- peek
  let err = failWith (ModeMismatch m mmo)
  if (mmo == Just m)
    then p
    else err

debugP :: Parser a -> Parser (LexerMode, a, LexerMode)
debugP p =
  (,,)
    <$> peekFail
    <*> p
    <*> peekFail

peekFail :: Parser LexerMode
peekFail =
  peek >>= maybe (failWith EmptyModeStack) pure

-- -----------------------------------------------------------------------------
-- Megaparsec boilerplate

type Parser= P.ParsecT TokenErrorComponent Text (State LexerState)

data TokenErrorComponent =
    ParseFail [Char]
  | ParseIndentError Ordering P.Pos P.Pos
  | TagMismatch (Text, Range) (Text, Range)
  | ModeMismatch LexerMode (Maybe LexerMode)
  | EmptyModeStack
  deriving (Eq, Ord, Show)

instance P.ErrorComponent TokenErrorComponent where
  representFail =
    ParseFail
  representIndentation =
    ParseIndentError

instance P.ShowErrorComponent TokenErrorComponent where
  showErrorComponent ec =
    case ec of
      ParseFail e ->
        "Internal parser fail:\n  " <> e <>
        "\n  (consider reporting this as a bug)"
      ParseIndentError o p1 p2 ->
        let ror =
              case o of
                LT ->
                  "less than "
                EQ ->
                  "equal to "
                GT ->
                  "greater than "
        in mconcat
             [ "Indentation error:\n  expected "
             , ror
             , show (P.unPos p1)
             , ", got "
             , show (P.unPos p2)
             ]
      TagMismatch (t1, a) (t2, b) ->
        mconcat
          [ "HTML tags are not balanced:\n  Tag '"
          , T.unpack t1
          , "' wrongly closed by '"
          , T.unpack t2 <> "' at "
          , T.unpack (renderRange (a <> b))
          ]
      ModeMismatch _ _ ->
        show ec
      EmptyModeStack ->
        "BUG: the lexer reached the bottom of its mode stack"

failWith :: TokenErrorComponent -> Parser a
failWith err =
  P.failure S.empty S.empty (S.singleton err)


-- -----------------------------------------------------------------------------

template :: Parser [Positioned Token]
template =
  start *> many (withPosition token)

templateDebug :: Parser [(LexerMode, Positioned Token, LexerMode)]
templateDebug =
  start *> many (debugP (withPosition token))

start :: Parser ()
start =
      (P.lookAhead (P.try (typeSigStart)) *> push ExprMode *> push TypeSigMode)
  <|> push ExprMode

token :: Parser Token
token =
      (satisfyMode HtmlMode htmlToken)
  <|> (satisfyMode HtmlCommentMode htmlCommentToken)
  <|> (satisfyMode TagOpenMode tagOpenToken)
  <|> (satisfyMode TagCloseMode tagCloseToken)
  <|> (satisfyMode ExprMode exprToken)
  <|> (satisfyMode ExprCommentMode exprCommentToken)
  <|> (satisfyMode StringMode stringToken)
  <|> (satisfyMode TypeSigMode typeSigToken)


-- -----------------------------------------------------------------------------
-- Type sig mode

typeSigToken :: Parser Token
typeSigToken =
      whitespace
  <|> newline
  <|> typeIdent
  <|> typeLParen
  <|> typeRParen
  <|> typeSig
  <|> typeSigStart
  <|> typeSigSep
  <|> typeSigEnd

typeSigStart :: Parser Token
typeSigStart =
  char '\\' *> pure TypeSigStart

typeIdent :: Parser Token
typeIdent =
  fmap (TypeIdent . T.pack) (some P.alphaNumChar)

typeLParen :: Parser Token
typeLParen =
  char '(' *> pure TypeLParen

typeRParen :: Parser Token
typeRParen =
  char ')' *> pure TypeRParen

typeSig :: Parser Token
typeSig =
  char ':' *> pure TypeSig

typeSigSep :: Parser Token
typeSigSep =
  string "->" *> pure TypeSigSep

typeSigEnd :: Parser Token
typeSigEnd =
  char '=' *> pure TypeSigEnd <* pop


-- -----------------------------------------------------------------------------
-- Html mode

htmlToken :: Parser Token
htmlToken =
      whitespace
  <|> newline
  <|> tagCommentStart
  <|> tagCloseOpen
  <|> tagOpen
  <|> exprCommentStart
  <|> wsExprStart
  <|> textExprStart
  <|> exprStart
  <|> htmlTextExprEnd
  <|> htmlExprEnd
  <|> htmlWsExprEnd
  <|> plainText

tagOpen :: Parser Token
tagOpen =
  char '<' *> pure TagOpen <* push TagOpenMode

tagCloseOpen :: Parser Token
tagCloseOpen =
  string "</" *> pure TagCloseOpen <* push TagCloseMode

plainText :: Parser Token
plainText =
  fmap Plain . escaping $ \p m ->
    -- characters that begin rules at the same level
    p == '\n' || p == ' ' || p == '<' || p == '>' || p == '\\' ||
    p == '{'  || p == '}' || (p == '|' && m == pure '}')

exprStart :: Parser Token
exprStart =
  char '{' *> pure ExprStart <* push ExprMode

htmlExprEnd :: Parser Token
htmlExprEnd =
  char '}' *> pure ExprEnd <* pop <* pop

wsExprStart :: Parser Token
wsExprStart =
  string "{|" *> pure ExprStartWS <* push HtmlMode

htmlWsExprEnd :: Parser Token
htmlWsExprEnd =
  string "|}" *> pure ExprEndWS <* pop

htmlTextExprEnd :: Parser Token
htmlTextExprEnd =
  string "}}" *> pure TextExprStart <* pop <* pop

tagCommentStart :: Parser Token
tagCommentStart =
  string "<!--" *> pure TagCommentStart <* push HtmlCommentMode

-- -----------------------------------------------------------------------------
-- HTML comments - these can't be nested, they halt on the first '-->'

htmlCommentToken :: Parser Token
htmlCommentToken =
      tagCommentEnd
  <|> tagCommentChunk

tagCommentChunk :: Parser Token
tagCommentChunk =
  TagCommentChunk <$> someTill P.anyChar (string "--")

tagCommentEnd :: Parser Token
tagCommentEnd =
  -- We actually break on -- and expect TagClose
  string "--" *> pure TagCommentEnd <* push TagCloseMode

-- -----------------------------------------------------------------------------
-- Tag Open mode (e.g. <a href>)

tagOpenToken :: Parser Token
tagOpenToken =
      whitespace
  <|> newline
  <|> tagEquals
  <|> tagOpenClose
  <|> tagSelfClose
  <|> tagIdent
  <|> tagStringStart
  <|> exprCommentStart
  <|> textExprStart
  <|> exprStart
  <|> wsExprStart


tagIdent :: Parser Token
tagIdent =
  TagIdent . T.pack <$> ((:) <$> P.letterChar <*> many (P.alphaNumChar <|> P.char '-'))

tagEquals :: Parser Token
tagEquals =
  char '=' *> pure TagEquals

tagOpenClose :: Parser Token
tagOpenClose =
  char '>' *> pure TagClose <* pop <* push HtmlMode

tagSelfClose :: Parser Token
tagSelfClose =
  string "/>" *> pure TagSelfClose <* pop

tagStringStart :: Parser Token
tagStringStart =
  char '"' *> pure StringStart <* push StringMode


-- -----------------------------------------------------------------------------
-- Tag Close mode (e.g. </a>)

tagCloseToken :: Parser Token
tagCloseToken =
      whitespace
  <|> newline
  <|> tagCloseClose
  <|> tagIdent
  <|> exprCommentStart

tagCloseClose :: Parser Token
tagCloseClose =
  char '>' *> pure TagClose <* pop <* pop

-- -----------------------------------------------------------------------------
-- Expression tokens

exprToken :: Parser Token
exprToken =
      whitespace
  <|> newline
  <|> exprLParen
  <|> exprRParen
  <|> exprListStart
  <|> exprListSep
  <|> exprListEnd
  <|> exprStringStart
  <|> exprCaseStart
  <|> exprCaseOf
  <|> exprEach
  <|> exprCaseSep
  <|> exprLamStart
  <|> exprArrow
  <|> exprDot
  <|> exprCommentStart
  <|> wsExprStart
  <|> wsExprEnd
  <|> textExprStart
  <|> exprStart
  <|> textExprEnd
  <|> exprEnd
  <|> exprHtmlCommentStart
  <|> exprHtmlStart
  <|> exprHole
  <|> exprConId
  <|> exprVarId


exprLParen :: Parser Token
exprLParen =
  char '(' *> pure ExprLParen

exprRParen :: Parser Token
exprRParen =
  char ')' *> pure ExprRParen

exprListStart :: Parser Token
exprListStart =
  char '[' *> pure ExprListStart

exprListSep :: Parser Token
exprListSep =
  char ',' *> pure ExprListSep

exprListEnd :: Parser Token
exprListEnd =
  char ']' *> pure ExprListEnd

exprStringStart :: Parser Token
exprStringStart =
  char '"' *> pure StringStart <* push StringMode

exprEnd :: Parser Token
exprEnd =
  char '}' *> pure ExprEnd <* pop

exprCaseStart :: Parser Token
exprCaseStart =
  reserved "case" *> pure ExprCaseStart

exprCaseOf :: Parser Token
exprCaseOf =
  reserved "of" *> pure ExprCaseOf

exprCaseSep :: Parser Token
exprCaseSep =
  char ';' *> pure ExprCaseSep

exprEach :: Parser Token
exprEach =
  reserved "each" *> pure ExprEach

exprDot :: Parser Token
exprDot =
  char '.' *> pure ExprDot

exprHole :: Parser Token
exprHole =
  char '_' *> pure ExprHole

exprLamStart :: Parser Token
exprLamStart =
  char '\\' *> pure ExprLamStart

exprArrow :: Parser Token
exprArrow =
  string "->" *> pure ExprArrow

exprCommentStart :: Parser Token
exprCommentStart =
  string "{-" *> pure ExprCommentStart <* push ExprCommentMode

exprConId :: Parser Token
exprConId =
  fmap (ExprConId . T.pack) ((:) <$> P.upperChar <*> many (P.alphaNumChar <|> P.char '_'))

exprVarId :: Parser Token
exprVarId =
  fmap (ExprVarId . T.pack) ((:) <$> P.lowerChar <*> many (P.alphaNumChar <|> P.char '/' <|> P.char '-' <|> P.char '_'))

exprHtmlStart :: Parser Token
exprHtmlStart =
  char '<' *> pure TagOpen <* push TagOpenMode

exprHtmlCommentStart :: Parser Token
exprHtmlCommentStart =
  string "<!--" *> pure TagCommentStart <* push HtmlCommentMode

wsExprEnd :: Parser Token
wsExprEnd =
  string "|}" *> pure ExprEndWS <* pop

textExprStart :: Parser Token
textExprStart =
  string "{{" *> pure TextExprStart <* push ExprMode

textExprEnd :: Parser Token
textExprEnd =
  string "}}" *> pure TextExprEnd <* pop

-- -----------------------------------------------------------------------------
-- Expr comments - unlike HTML, these can be nested {- foo {- bar -} baz -}

exprCommentToken :: Parser Token
exprCommentToken =
      exprCommentEnd
  <|> exprCommentStart
  <|> exprCommentChunk

exprCommentChunk :: Parser Token
exprCommentChunk =
  ExprCommentChunk <$> someTill P.anyChar (string "{-" <|> string "-}")

exprCommentEnd :: Parser Token
exprCommentEnd =
  string "-}" *> pure ExprCommentEnd <* pop


-- -----------------------------------------------------------------------------
-- String mode

stringToken :: Parser Token
stringToken =
      stringChunk
  <|> exprCommentStart
  <|> wsExprStart
  <|> stringTextExprStart
  <|> stringExprStart
  <|> stringEnd

stringEnd :: Parser Token
stringEnd =
  char '"' *> pure StringEnd <* pop

stringTextExprStart :: Parser Token
stringTextExprStart =
  string "{{" *> pure TextExprStart <* push ExprMode

stringExprStart :: Parser Token
stringExprStart =
  char '{' *> pure ExprStart <* push ExprMode

stringChunk :: Parser Token
stringChunk =
  StringChunk <$> stringChunkText

stringChunkText :: Parser Text
stringChunkText =
  escaping $ \p _ ->
    -- characters that begin rules at the same level
    p == '"' || p == '{' || p == '\\'


-- -----------------------------------------------------------------------------
-- General tokens

whitespace :: Parser Token
whitespace =
  (Whitespace . length) <$> some (char ' ')

newline :: Parser Token
newline =
  char '\n' *> pure Newline


-- -----------------------------------------------------------------------------
-- low level parsers

reserved :: [Char] -> Parser ()
reserved s =
  P.try (string s <* P.notFollowedBy P.alphaNumChar)

someTill' :: Parser m -> Parser end -> Parser [m]
someTill' m end =
  P.someTill m (P.lookAhead end)

someTill :: Parser Char -> Parser a -> Parser Text
someTill m end =
  T.pack <$> someTill' m end

escaping' :: Char -> (Char -> Maybe Char -> Bool) -> Parser Char
escaping' echar breaks = do
  c <- P.anyChar
  if c == echar
    then do
      d <- optional P.anyChar
      l <- optional (P.try (P.lookAhead P.anyChar))
      maybe empty (\p -> if breaks p l then pure p else empty) d
    else do
      l <- optional (P.try (P.lookAhead P.anyChar))
      if breaks c l then empty else pure c

escapeChar :: Char
escapeChar =
  '\\'

escaping :: (Char -> Maybe Char -> Bool) -> Parser Text
escaping breaks =
  T.pack <$> some (P.try (escaping' escapeChar breaks))

char :: Char -> Parser ()
char =
  void . P.char

string :: [Char] -> Parser ()
string =
  void . P.string

getPosition :: Parser Position
getPosition =
  fmap posPosition P.getPosition
{-# INLINEABLE getPosition #-}

withPosition :: Parser a -> Parser (Positioned a)
withPosition p = do
  a <- getPosition
  b <- p
  c <- getPosition
  pure (b :@ Range a c)
{-# INLINEABLE withPosition #-}

posPosition :: P.SourcePos -> Position
posPosition (P.SourcePos file line col) =
  Position (fromIntegral (P.unPos line)) (fromIntegral (P.unPos col)) file
{-# INLINEABLE posPosition #-}
