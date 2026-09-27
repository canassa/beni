module Interp (run) where

-- A tokenizer, recursive-descent parser, printer and evaluator for a small
-- expression language: integers, booleans, arithmetic, comparisons,
-- let, let rec, if, one-parameter lambdas and application.

import Prelude

import Data.Char (toCharCode)
import Data.Foldable (foldl)
import Data.Either (Either(..))
import Data.List (List(..), fromFoldable, reverse, (:))
import Data.String.CodeUnits (fromCharArray, singleton, toCharArray)
import Data.Array as Array
import Data.Tuple (Tuple(..))

data Token
  = TInt Int
  | TIdent String
  | TPlus
  | TMinus
  | TStar
  | TSlash
  | TLess
  | TEqEq
  | TEq
  | TLParen
  | TRParen
  | TArrow
  | TLet
  | TRec
  | TIn
  | TIf
  | TThen
  | TElse
  | TFn
  | TTrue
  | TFalse

derive instance eqToken :: Eq Token

data Op
  = Add
  | Sub
  | Mul
  | Div
  | Less
  | Equal

data Expr
  = Num Int
  | BoolLit Boolean
  | Var String
  | BinOp Op Expr Expr
  | Let String Expr Expr
  | LetRec String String Expr Expr
  | If Expr Expr Expr
  | Lambda String Expr
  | Apply Expr Expr

data Value
  = VInt Int
  | VBool Boolean
  | VClosure String Expr (List (Tuple String Value))
  | VRecClosure String String Expr (List (Tuple String Value))

type Env = List (Tuple String Value)

-- TOKENIZER

tokenize :: String -> Either String (List Token)
tokenize source = tokenizeChars (fromFoldable (toCharArray source)) Nil

tokenizeChars :: List Char -> List Token -> Either String (List Token)
tokenizeChars chars acc = case chars of
  Nil -> Right (reverse acc)
  ' ' : rest -> tokenizeChars rest acc
  '\n' : rest -> tokenizeChars rest acc
  '-' : '>' : rest -> tokenizeChars rest (TArrow : acc)
  '=' : '=' : rest -> tokenizeChars rest (TEqEq : acc)
  '+' : rest -> tokenizeChars rest (TPlus : acc)
  '-' : rest -> tokenizeChars rest (TMinus : acc)
  '*' : rest -> tokenizeChars rest (TStar : acc)
  '/' : rest -> tokenizeChars rest (TSlash : acc)
  '<' : rest -> tokenizeChars rest (TLess : acc)
  '=' : rest -> tokenizeChars rest (TEq : acc)
  '(' : rest -> tokenizeChars rest (TLParen : acc)
  ')' : rest -> tokenizeChars rest (TRParen : acc)
  c : _ ->
    if isDigit c then
      let
        Tuple digits remaining = spanChars isDigit chars Nil
      in
        tokenizeChars remaining (TInt (digitsToInt digits) : acc)
    else if isAlpha c then
      let
        Tuple letters remaining = spanChars isAlphaNum chars Nil
      in
        tokenizeChars remaining (keyword (fromCharArray (Array.fromFoldable letters)) : acc)
    else
      Left ("unexpected character " <> singleton c)

isDigit :: Char -> Boolean
isDigit c = c >= '0' && c <= '9'

isAlpha :: Char -> Boolean
isAlpha c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')

isAlphaNum :: Char -> Boolean
isAlphaNum c = isAlpha c || isDigit c

spanChars :: (Char -> Boolean) -> List Char -> List Char -> Tuple (List Char) (List Char)
spanChars predicate chars taken = case chars of
  c : rest ->
    if predicate c then
      spanChars predicate rest (c : taken)
    else
      Tuple (reverse taken) chars
  Nil -> Tuple (reverse taken) Nil

digitsToInt :: List Char -> Int
digitsToInt digits = foldl (\total d -> total * 10 + toCharCode d - 48) 0 digits

keyword :: String -> Token
keyword word = case word of
  "let" -> TLet
  "rec" -> TRec
  "in" -> TIn
  "if" -> TIf
  "then" -> TThen
  "else" -> TElse
  "fn" -> TFn
  "true" -> TTrue
  "false" -> TFalse
  _ -> TIdent word

-- PARSER

parse :: String -> Either String Expr
parse source = case tokenize source of
  Left err -> Left err
  Right tokens -> case parseExpr tokens of
    Left err -> Left err
    Right (Tuple expr Nil) -> Right expr
    Right (Tuple _ (token : _)) -> Left ("unexpected " <> describeToken token <> " after expression")

expect :: Token -> List Token -> Either String (List Token)
expect wanted tokens = case tokens of
  token : rest ->
    if token == wanted then
      Right rest
    else
      Left ("expected " <> describeToken wanted <> " but found " <> describeToken token)
  Nil -> Left ("expected " <> describeToken wanted <> " but reached the end")

parseExpr :: List Token -> Either String (Tuple Expr (List Token))
parseExpr tokens = case tokens of
  TLet : TRec : TIdent name : TEq : TFn : TIdent param : TArrow : rest -> case parseExpr rest of
    Left err -> Left err
    Right (Tuple fnBody afterFn) -> case expect TIn afterFn of
      Left err -> Left err
      Right afterIn -> case parseExpr afterIn of
        Left err -> Left err
        Right (Tuple body afterBody) -> Right (Tuple (LetRec name param fnBody body) afterBody)
  TLet : TIdent name : TEq : rest -> case parseExpr rest of
    Left err -> Left err
    Right (Tuple bound afterBound) -> case expect TIn afterBound of
      Left err -> Left err
      Right afterIn -> case parseExpr afterIn of
        Left err -> Left err
        Right (Tuple body afterBody) -> Right (Tuple (Let name bound body) afterBody)
  TLet : _ -> Left "malformed let"
  TIf : rest -> case parseExpr rest of
    Left err -> Left err
    Right (Tuple cond afterCond) -> case expect TThen afterCond of
      Left err -> Left err
      Right afterThen -> case parseExpr afterThen of
        Left err -> Left err
        Right (Tuple yes afterYes) -> case expect TElse afterYes of
          Left err -> Left err
          Right afterElse -> case parseExpr afterElse of
            Left err -> Left err
            Right (Tuple no afterNo) -> Right (Tuple (If cond yes no) afterNo)
  TFn : TIdent param : TArrow : rest -> case parseExpr rest of
    Left err -> Left err
    Right (Tuple body afterBody) -> Right (Tuple (Lambda param body) afterBody)
  TFn : _ -> Left "malformed fn"
  _ -> parseComparison tokens

parseComparison :: List Token -> Either String (Tuple Expr (List Token))
parseComparison tokens = case parseAdditive tokens of
  Left err -> Left err
  Right (Tuple left rest) -> case rest of
    TLess : afterOp -> case parseAdditive afterOp of
      Left err -> Left err
      Right (Tuple right afterRight) -> Right (Tuple (BinOp Less left right) afterRight)
    TEqEq : afterOp -> case parseAdditive afterOp of
      Left err -> Left err
      Right (Tuple right afterRight) -> Right (Tuple (BinOp Equal left right) afterRight)
    _ -> Right (Tuple left rest)

parseAdditive :: List Token -> Either String (Tuple Expr (List Token))
parseAdditive tokens = case parseTerm tokens of
  Left err -> Left err
  Right (Tuple left rest) -> additiveLoop left rest

additiveLoop :: Expr -> List Token -> Either String (Tuple Expr (List Token))
additiveLoop left tokens = case tokens of
  TPlus : rest -> case parseTerm rest of
    Left err -> Left err
    Right (Tuple right afterRight) -> additiveLoop (BinOp Add left right) afterRight
  TMinus : rest -> case parseTerm rest of
    Left err -> Left err
    Right (Tuple right afterRight) -> additiveLoop (BinOp Sub left right) afterRight
  _ -> Right (Tuple left tokens)

parseTerm :: List Token -> Either String (Tuple Expr (List Token))
parseTerm tokens = case parseCall tokens of
  Left err -> Left err
  Right (Tuple left rest) -> termLoop left rest

termLoop :: Expr -> List Token -> Either String (Tuple Expr (List Token))
termLoop left tokens = case tokens of
  TStar : rest -> case parseCall rest of
    Left err -> Left err
    Right (Tuple right afterRight) -> termLoop (BinOp Mul left right) afterRight
  TSlash : rest -> case parseCall rest of
    Left err -> Left err
    Right (Tuple right afterRight) -> termLoop (BinOp Div left right) afterRight
  _ -> Right (Tuple left tokens)

parseCall :: List Token -> Either String (Tuple Expr (List Token))
parseCall tokens = case parseAtom tokens of
  Left err -> Left err
  Right (Tuple callee rest) -> callLoop callee rest

callLoop :: Expr -> List Token -> Either String (Tuple Expr (List Token))
callLoop callee tokens = case tokens of
  TLParen : rest -> case parseExpr rest of
    Left err -> Left err
    Right (Tuple argument afterArgument) -> case expect TRParen afterArgument of
      Left err -> Left err
      Right afterParen -> callLoop (Apply callee argument) afterParen
  _ -> Right (Tuple callee tokens)

parseAtom :: List Token -> Either String (Tuple Expr (List Token))
parseAtom tokens = case tokens of
  TInt n : rest -> Right (Tuple (Num n) rest)
  TTrue : rest -> Right (Tuple (BoolLit true) rest)
  TFalse : rest -> Right (Tuple (BoolLit false) rest)
  TIdent name : rest -> Right (Tuple (Var name) rest)
  TLParen : rest -> case parseExpr rest of
    Left err -> Left err
    Right (Tuple inner afterInner) -> case expect TRParen afterInner of
      Left err -> Left err
      Right afterParen -> Right (Tuple inner afterParen)
  token : _ -> Left ("unexpected " <> describeToken token)
  Nil -> Left "unexpected end of input"

describeToken :: Token -> String
describeToken token = case token of
  TInt n -> "number " <> show n
  TIdent name -> "name " <> name
  TPlus -> "'+'"
  TMinus -> "'-'"
  TStar -> "'*'"
  TSlash -> "'/'"
  TLess -> "'<'"
  TEqEq -> "'=='"
  TEq -> "'='"
  TLParen -> "'('"
  TRParen -> "')'"
  TArrow -> "'->'"
  TLet -> "'let'"
  TRec -> "'rec'"
  TIn -> "'in'"
  TIf -> "'if'"
  TThen -> "'then'"
  TElse -> "'else'"
  TFn -> "'fn'"
  TTrue -> "'true'"
  TFalse -> "'false'"

-- PRINTER

showExpr :: Expr -> String
showExpr expr = case expr of
  Num n -> show n
  BoolLit true -> "true"
  BoolLit false -> "false"
  Var name -> name
  BinOp op left right -> "(" <> showExpr left <> " " <> opSymbol op <> " " <> showExpr right <> ")"
  Let name bound body -> "let " <> name <> " = " <> showExpr bound <> " in " <> showExpr body
  LetRec name param fnBody body -> "let rec " <> name <> " = fn " <> param <> " -> " <> showExpr fnBody <> " in " <> showExpr body
  If cond yes no -> "if " <> showExpr cond <> " then " <> showExpr yes <> " else " <> showExpr no
  Lambda param body -> "(fn " <> param <> " -> " <> showExpr body <> ")"
  Apply callee argument -> showExpr callee <> "(" <> showExpr argument <> ")"

opSymbol :: Op -> String
opSymbol op = case op of
  Add -> "+"
  Sub -> "-"
  Mul -> "*"
  Div -> "/"
  Less -> "<"
  Equal -> "=="

showValue :: Value -> String
showValue value = case value of
  VInt n -> show n
  VBool true -> "true"
  VBool false -> "false"
  VClosure param _ _ -> "<fn " <> param <> ">"
  VRecClosure name _ _ _ -> "<rec fn " <> name <> ">"

-- EVALUATOR

lookup :: String -> Env -> Either String Value
lookup name env = case env of
  Nil -> Left ("unbound variable " <> name)
  Tuple key value : rest ->
    if key == name then
      Right value
    else
      lookup name rest

eval :: Env -> Expr -> Either String Value
eval env expr = case expr of
  Num n -> Right (VInt n)
  BoolLit b -> Right (VBool b)
  Var name -> lookup name env
  BinOp op left right -> case eval env left of
    Left err -> Left err
    Right leftValue -> case eval env right of
      Left err -> Left err
      Right rightValue -> applyOp op leftValue rightValue
  Let name bound body -> case eval env bound of
    Left err -> Left err
    Right value -> eval (Tuple name value : env) body
  LetRec name param fnBody body -> eval (Tuple name (VRecClosure name param fnBody env) : env) body
  If cond yes no -> case eval env cond of
    Left err -> Left err
    Right (VBool true) -> eval env yes
    Right (VBool false) -> eval env no
    Right other -> Left ("condition is not a boolean: " <> showValue other)
  Lambda param body -> Right (VClosure param body env)
  Apply callee argument -> case eval env callee of
    Left err -> Left err
    Right calleeValue -> case eval env argument of
      Left err -> Left err
      Right argumentValue -> applyFunction calleeValue argumentValue

applyFunction :: Value -> Value -> Either String Value
applyFunction callee argument = case callee of
  VClosure param body closureEnv -> eval (Tuple param argument : closureEnv) body
  VRecClosure name param body closureEnv -> eval (Tuple param argument : Tuple name callee : closureEnv) body
  other -> Left ("not a function: " <> showValue other)

applyOp :: Op -> Value -> Value -> Either String Value
applyOp op left right = case op, left, right of
  Add, VInt a, VInt b -> Right (VInt (a + b))
  Sub, VInt a, VInt b -> Right (VInt (a - b))
  Mul, VInt a, VInt b -> Right (VInt (a * b))
  Div, VInt _, VInt 0 -> Left "division by zero"
  Div, VInt a, VInt b -> Right (VInt (a / b))
  Less, VInt a, VInt b -> Right (VBool (a < b))
  Equal, VInt a, VInt b -> Right (VBool (a == b))
  Equal, VBool a, VBool b -> Right (VBool (a == b))
  _, _, _ -> Left ("type error: " <> showValue left <> " " <> opSymbol op <> " " <> showValue right)

-- DRIVER

programs :: List String
programs = fromFoldable
  [ "1 + 2 * 3"
  , "(1 + 2) * 3 - 4 / 2"
  , "let x = 5 in let y = x * 2 in if x < y then y - x else 0"
  , "let add = fn a -> fn b -> a + b in add(3)(4)"
  , "let twice = fn f -> fn x -> f(f(x)) in twice(fn n -> n * 3)(7)"
  , "let rec fact = fn n -> if n < 2 then 1 else n * fact(n - 1) in fact(10)"
  , "let rec fib = fn n -> if n < 2 then n else fib(n - 1) + fib(n - 2) in fib(15)"
  , "let rec sum = fn n -> if n == 0 then 0 else n + sum(n - 1) in sum(100)"
  , "if 3 == 3 then true == false else false"
  , "10 / (5 - 5)"
  , "unknown + 1"
  , "1 + true"
  , "(1 + 2"
  , "let = 4"
  , "3 # 4"
  , "5(6)"
  ]

runProgram :: String -> String
runProgram source = case parse source of
  Left err -> "parse error: " <> err
  Right expr -> case eval Nil expr of
    Left err -> showExpr expr <> " => error: " <> err
    Right value -> showExpr expr <> " => " <> showValue value

run :: List String
run = map runProgram programs
