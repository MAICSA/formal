{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE OverlappingInstances #-}
{-# LANGUAGE FlexibleContexts #-}


module Main where

import Text.InterpolatedString.Perl6

import Control.Applicative
import Control.Monad.Identity
import Control.Monad.State hiding (lift)

import System.IO
import System.Environment

import Text.Parsec hiding ((<|>), State, many, spaces, parse)
import Text.Parsec.Indent
import Text.Pandoc

import qualified Data.Map as M
import qualified Data.List as L
import qualified Data.Set as S

import Data.Char (ord, isAscii)
import Data.String.Utils


-- Structure & comments
--------------------------------------------------------------------------------
-- ...

type Parser a = ParsecT String () (StateT SourcePos Identity) a

parse :: Parser a -> SourceName -> String -> Either ParseError a
parse parser sname input = runIndent sname $ runParserT parser () sname input

whitespace :: Parser String
whitespace = many $ oneOf "\t "

in_block :: Parser ()
in_block = do pos <- getPosition
              s <- get
              if (sourceColumn pos) < (sourceColumn s) 
                then parserFail "not indented" 
                else do put $ setSourceLine s (sourceLine pos)
                        return ()

spaces :: Parser ()
spaces = try emptyline `manyTill` try line_start >> return ()

    where emptyline = whitespace >> newline
          line_start = whitespace >> notFollowedBy newline >> in_block

comment :: Parser String
comment = try (whitespace >> newline >> return "\n") <|> comment'

    where comment' = do x <- anyChar `manyTill` newline
                        case x of 
                          (' ':' ':' ':' ':_) -> return (x ++ "\n")
                          _ -> return "\n"

sep_with :: Show a => String -> [a] -> String
sep_with x = concat . L.intersperse x . fmap show



-- Patterns
--------------------------------------------------------------------------------
-- ...


-- data Pattern = VarPattern String
--              | LiteralPattern Literal
--              | AliasPattern
--              deriving (Show)

-- pattern :: Parser Pattern
-- pattern = undefined


-- -- Expressions
-- --------------------------------------------------------------------------------
-- -- ...

-- data Expression = ApplyExpression Expression [Expression]
--                 | LiteralExpression Literal
--                 | SymbolExpression String
--                 | JSExpression JExpr
--                 deriving (Show)

-- expression :: Parser Expression
-- expression = undefined

-- -- Literals
-- --------------------------------------------------------------------------------
-- -- Literals in Sonnet are limited to strings and numbers - 

-- -- 
-- data Literal = StringLiteral String | NumLiteral Int | JSON (M.Map String Expression) | List [Expression] 

-- instance Show Literal where
--    show (JSON x)  = show x
--    show (List x)  = show x

-- -- ValueLiterals 


-- literal :: Parser Literal
-- literal = try num <|> str
--     where num = NumLiteral . read <$> many digit
--           str = StringLiteral <$> (char '"' >> (anyChar `manyTill` char '"'))

-- -- JSON Literals


-- json_literal :: Parser Literal
-- json_literal = JSON . M.fromList <$> (string "{" *> spaces *> pairs <* spaces <* string "}")

--     where pairs = key_value `sepEndBy` try (comma <|> not_comma)

--           not_comma = whitespace >> newline >> spaces >> notFollowedBy (string "}")

--           comma = spaces >> string "," >> spaces

--           key_value = do key <- many (alphaNum <|> oneOf "_")
--                          spaces
--                          string "="
--                          spaces
--                          value <- expression
--                          return (key, value)

-- -- ListLiterals

-- list_literal :: Parser Literal
-- list_literal = undefined



-- Parsing 
--------------------------------------------------------------------------------
-- A Sonnet program is represented by a set of statements

data Statement = TypeStatement TypeDefinition UnionType
               | DefinitionStatement String [Axiom]
              --- | ExpressionStatement Expression

instance Show Statement where
    show (TypeStatement t c)        = [qq|type $t = $c|]
    show (DefinitionStatement s as) = [qq|$s {sep_with "" as}|]

newtype Program = Program [Statement]

instance Show Program where
     show (Program ss) = sep_with "\n" ss

sonnetParser :: Parser Program
sonnetParser  = Program . concat <$> many (many (string "\n") >> statement) <* eof

    where statement = whitespace >> withPos statement' <* many newline
          statement' = try type_statement <|> definition_statement


-- Statements
--------------------------------------------------------------------------------
-- A Statement may be a definition, which is a list of axioms associated with a
-- symbol

data Axiom = TypeAxiom UnionType
         --  | EqualityAxiom [Pattern] Expression

instance Show Axiom where
    show (TypeAxiom x) = ": " ++ show x
    show _ = undefined

definition_statement :: Parser [Statement]
definition_statement = do whitespace
                          name <- type_var
                          spaces
                          string ":"
                          spaces
                          sig <- withPos type_axiom_signature
                          whitespace
                          return $ [DefinitionStatement name (TypeAxiom sig : [])]

-- equality_axiom :: Parser Axiom
-- equality_axiom = do string "|" 
--                     whitespace
--                     patterns <- pattern `sepBy` whitespace
--                     string "="
--                     spaces
--                     ex <- expression
--                     return $ EqualityAxiom patterns ex

-- A Statement may also be a type definition, which defines a set of values to
-- a type symbol

data TypeDefinition = TypeDefinition String [String]

instance Show TypeDefinition where
    show (TypeDefinition name vars) = concat . L.intersperse " " $ name : vars

type_statement :: Parser [Statement]
type_statement  = do whitespace
                     string "type "
                     whitespace
                     def <- type_definition
                     whitespace 
                     string "="
                     spaces
                     sig <- withPos type_definition_signature
                     whitespace
                     return $ [TypeStatement def sig]

type_definition :: Parser TypeDefinition
type_definition = do name <- (:) <$> upper <*> many alphaNum
                     vars <- try $ do many1 $ oneOf "\t "
                                      let var = (:) <$> lower <*> many alphaNum
                                      var `sepEndBy` whitespace
                             <|> return []
                     return $ TypeDefinition name vars 




-- Type Signatures
--------------------------------------------------------------------------------
-- This is what a type signature looks like 

data UnionType = UnionType (S.Set ComplexType)
               deriving (Ord, Eq)

data ComplexType = PolymorphicType SimpleType [UnionType]
                 | JSONType (M.Map String UnionType)
                 | NamedType String UnionType
                 | FunctionType UnionType UnionType
                 | SimpleType SimpleType
                 deriving (Eq, Ord)

data SimpleType = SymbolType String | VariableType String deriving (Ord, Eq)




instance Show UnionType where 
    show (UnionType xs)        = [qq|{sep_with " | " $ S.toList xs}|]
    
instance Show ComplexType where
    show (SimpleType y)        = [qq|$y|]
    show (PolymorphicType x y) = [qq|($x {sep_with " " y})|]
    show (NamedType name t)    = [qq|$name of $t|]
    show (JSONType m)          = [qq|\{ {g m} \}|] 
        where g = concat . L.intersperse ", " . fmap (\(x, y) -> [qq|$x: $y|]) . M.toAscList

    show (FunctionType g@(UnionType (S.toList -> ((FunctionType _ _):[]))) h) = [qq|($g -> $h)|]
    show (FunctionType g h) = [qq|$g -> $h|]

instance Show SimpleType where
    show (SymbolType x)   = x
    show (VariableType x) = x


type_axiom_signature :: Parser UnionType
type_axiom_signature =  (try nested_union_type <|> (UnionType . S.fromList . (:[]) <$> (try function_type <|> inner_type))) <* whitespace

type_definition_signature :: Parser UnionType
type_definition_signature = UnionType . S.fromList <$> (try function_type <|> inner_type) `sepBy1` type_sep <* whitespace

-- Type combinators
inner_type :: Parser ComplexType
inner_type        = nested_function <|> record_type <|> try named_type <|> try poly_type <|> var_type <|> symbol_type

nested_function :: Parser ComplexType
nested_function   = indentPairs "(" (try function_type <|> inner_type) ")"

nested_union_type :: Parser UnionType
nested_union_type = indentPairs "(" type_definition_signature ")"

-- Types
function_type :: Parser ComplexType
function_type = do x <- try nested_union_type <|> (lift inner_type)
                   spaces
                   (string "->" <|> string "→")
                   spaces
                   y <- (lift $ try function_type) <|> try nested_union_type <|> (lift inner_type)
                   return $ FunctionType x y

poly_type :: Parser ComplexType
poly_type = do name <- (SymbolType <$> type_name) <|> (VariableType <$> type_var)
               oneOf "\t "
               whitespace
               let type_vars = nested_union_type <|> (lift (record_type <|> var_type <|> symbol_type))
               vars <- type_vars `sepEndBy1` whitespace
               return $ PolymorphicType name vars

named_type :: Parser ComplexType
named_type = do name <- type_var
                whitespace
                string "of"
                spaces 
                NamedType name <$> (try nested_union_type <|> (lift inner_type))

record_type :: Parser ComplexType
record_type = (JSONType . M.fromList) <$> indentPairs "{" pairs "}"
                
symbol_type :: Parser ComplexType
symbol_type = SimpleType . SymbolType <$> type_name

var_type :: Parser ComplexType
var_type    = SimpleType . VariableType <$> type_var

type_name :: Parser String
type_name = (:) <$> upper <*> many alphaNum  

type_var :: Parser String
type_var = (:) <$> lower <*> many alphaNum  

-- Utilities

type_sep    :: Parser Char
indentPairs :: String -> Parser a -> String -> Parser a
pairs       :: Parser [(String, UnionType)]
not_comma   :: Parser ()
comma       :: Parser ()
lift        :: Parser ComplexType -> Parser UnionType
key_value   :: Parser (String, UnionType)

type_sep          = try (spaces *> char '|' <* whitespace)
indentPairs a p b = string a *> spaces *> withPos p <* spaces <* string b
pairs             = key_value `sepEndBy` try (comma <|> not_comma)
not_comma         = whitespace >> newline >> spaces >> notFollowedBy (string "}")
comma             = spaces >> string "," >> spaces
key_value         = (,) <$> many (alphaNum <|> oneOf "_") <* spaces <* string ":" <* spaces <*> type_definition_signature
lift              = fmap $ UnionType . S.fromList . (:[])


          

--------------------------------------------------------------------------------
--
-- Main

toEntities :: String -> String
toEntities [] = ""
toEntities (c:cs) | isAscii c = c : toEntities cs
                  | otherwise = [qq|&#{ord c};{toEntities cs}|]

toHTML :: String -> String
toHTML = toEntities . writeHtmlString defaultWriterOptions . readMarkdown defaultParserState

main :: IO ()
main  = do RunConfig (file:_) output _ <- parseArgs <$> getArgs
           hFile  <- openFile file ReadMode
           src <- (\ x -> x ++ "\n") <$> hGetContents hFile
           writeFile (output ++ ".html") $ toHTML (wrap_html output src)
           putStrLn $ concat $ take 80 $ repeat "-"
           case parse ((comment <|> return "\n") `manyTill` eof) "Cleaning comments" src of
             Left ex -> putStrLn (show ex)
             Right src' -> do case parse sonnetParser "Parsing" (concat src') of
                                Left ex -> do putStrLn $ show ex
                                Right x -> do putStrLn $ show x
                                              putStrLn $ "success"

data RunMode   = Compile | JustTypeCheck
data RunConfig = RunConfig [String] String RunMode

parseArgs :: [String] -> RunConfig
parseArgs = fst . runState argsParser

  where argsParser = do args <- get
                        case args of
                          []     -> return $ RunConfig [] "default" Compile
                          (x:xs) -> do put xs
                                       case x of
                                         "-t"    -> do RunConfig a b _ <- argsParser
                                                       return $ RunConfig (x:a) b JustTypeCheck
                                         "-o"    -> do (name:ys) <- get
                                                       put ys
                                                       RunConfig a _ c <- argsParser
                                                       return $ RunConfig (x:a) name c
                                         ('-':_) -> do error "Could not parse options"
                                         z       -> do RunConfig a _ c <- argsParser
                                                       let b = last $ split "/" $ head $ split "." z
                                                       return $ RunConfig (x:a) b c


-- Docs

wrap_html :: String -> String -> String
wrap_html name body = [qq|

   <!DOCTYPE HTML PUBLIC '-//W3C//DTD HTML 4.01 Transitional//EN' 'http://www.w3.org/TR/html4/loose.dtd'>
   <html>
   <head>
   <title>$name</title>
   <link rel='stylesheet' type='text/css' href='lib/js/jasmine-1.0.1/jasmine.css'>
   <script type='text/javascript' src='lib/js/jasmine-1.0.1/jasmine.js'></script>
   <script type='text/javascript' src='lib/js/jasmine-1.0.1/jasmine-html.js'></script>
   <script type='text/javascript' src='lib/js/zepto.js'></script>
   <script type='text/javascript' src='$name.js'></script>
   <script type='text/javascript' src='$name.spec.js'></script>
   <link href='http://kevinburke.bitbucket.org/markdowncss/markdown.css' rel='stylesheet'></link>
   <link href='lib/js/prettify.css' type='text/css' rel='stylesheet' />
   <script type='text/javascript' src='lib/js/prettify.js'></script>
   <script type='text/javascript' src='lib/js/lang-hs.js'></script>
   <script type='text/javascript' src='lib/js/jquery.js'></script>
   <style>ul\{padding-left:40px;\}</style>
   </head>
   <body>
   <div style='margin: 0 0 50px 0'>$body</div>
   <script type='text/javascript'>
   jasmine.getEnv().addReporter(new jasmine.TrivialReporter());
   jasmine.getEnv().execute();
   </script>
   <script type='text/javascript'>$('code').addClass('prettyprint lang-hs');
   prettyPrint()
   </script>
   </body>
   </html>

|]
