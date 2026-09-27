// A tokenizer, recursive-descent parser, printer and evaluator for a small
// expression language: integers, booleans, arithmetic, comparisons,
// let, let rec, if, one-parameter lambdas and application.

import gleam/int
import gleam/list
import gleam/string

type Token {
  TInt(Int)
  TIdent(String)
  TPlus
  TMinus
  TStar
  TSlash
  TLess
  TEqEq
  TEq
  TLParen
  TRParen
  TArrow
  TLet
  TRec
  TIn
  TIf
  TThen
  TElse
  TFn
  TTrue
  TFalse
}

type Op {
  Add
  Sub
  Mul
  Div
  Less
  Equal
}

type Expr {
  Num(Int)
  BoolLit(Bool)
  Var(String)
  BinOp(Op, Expr, Expr)
  Let(String, Expr, Expr)
  LetRec(String, String, Expr, Expr)
  If(Expr, Expr, Expr)
  Lambda(String, Expr)
  Apply(Expr, Expr)
}

type Value {
  VInt(Int)
  VBool(Bool)
  VClosure(String, Expr, List(#(String, Value)))
  VRecClosure(String, String, Expr, List(#(String, Value)))
}

type Env =
  List(#(String, Value))

// TOKENIZER

fn tokenize(source: String) -> Result(List(Token), String) {
  tokenize_chars(string.to_graphemes(source), [])
}

fn tokenize_chars(
  chars: List(String),
  acc: List(Token),
) -> Result(List(Token), String) {
  case chars {
    [] -> Ok(list.reverse(acc))
    [" ", ..rest] -> tokenize_chars(rest, acc)
    ["\n", ..rest] -> tokenize_chars(rest, acc)
    ["-", ">", ..rest] -> tokenize_chars(rest, [TArrow, ..acc])
    ["=", "=", ..rest] -> tokenize_chars(rest, [TEqEq, ..acc])
    ["+", ..rest] -> tokenize_chars(rest, [TPlus, ..acc])
    ["-", ..rest] -> tokenize_chars(rest, [TMinus, ..acc])
    ["*", ..rest] -> tokenize_chars(rest, [TStar, ..acc])
    ["/", ..rest] -> tokenize_chars(rest, [TSlash, ..acc])
    ["<", ..rest] -> tokenize_chars(rest, [TLess, ..acc])
    ["=", ..rest] -> tokenize_chars(rest, [TEq, ..acc])
    ["(", ..rest] -> tokenize_chars(rest, [TLParen, ..acc])
    [")", ..rest] -> tokenize_chars(rest, [TRParen, ..acc])
    [c, ..] ->
      case is_digit(c), is_alpha(c) {
        True, _ -> {
          let #(digits, remaining) = span_chars(is_digit, chars, [])
          tokenize_chars(remaining, [TInt(digits_to_int(digits)), ..acc])
        }
        _, True -> {
          let #(letters, remaining) = span_chars(is_alpha_num, chars, [])
          tokenize_chars(remaining, [keyword(string.concat(letters)), ..acc])
        }
        _, _ -> Error("unexpected character " <> c)
      }
  }
}

fn is_digit(c: String) -> Bool {
  string.contains("0123456789", c)
}

fn is_alpha(c: String) -> Bool {
  string.contains("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ", c)
}

fn is_alpha_num(c: String) -> Bool {
  is_alpha(c) || is_digit(c)
}

fn span_chars(
  predicate: fn(String) -> Bool,
  chars: List(String),
  taken: List(String),
) -> #(List(String), List(String)) {
  case chars {
    [c, ..rest] ->
      case predicate(c) {
        True -> span_chars(predicate, rest, [c, ..taken])
        False -> #(list.reverse(taken), chars)
      }
    [] -> #(list.reverse(taken), [])
  }
}

fn digits_to_int(digits: List(String)) -> Int {
  list.fold(digits, 0, fn(total, d) {
    case int.parse(d) {
      Ok(n) -> total * 10 + n
      Error(_) -> total
    }
  })
}

fn keyword(word: String) -> Token {
  case word {
    "let" -> TLet
    "rec" -> TRec
    "in" -> TIn
    "if" -> TIf
    "then" -> TThen
    "else" -> TElse
    "fn" -> TFn
    "true" -> TTrue
    "false" -> TFalse
    _ -> TIdent(word)
  }
}

// PARSER

fn parse(source: String) -> Result(Expr, String) {
  case tokenize(source) {
    Error(err) -> Error(err)
    Ok(tokens) ->
      case parse_expr(tokens) {
        Error(err) -> Error(err)
        Ok(#(expr, [])) -> Ok(expr)
        Ok(#(_, [token, ..])) ->
          Error("unexpected " <> describe_token(token) <> " after expression")
      }
  }
}

fn expect(wanted: Token, tokens: List(Token)) -> Result(List(Token), String) {
  case tokens {
    [token, ..rest] ->
      case token == wanted {
        True -> Ok(rest)
        False ->
          Error(
            "expected "
            <> describe_token(wanted)
            <> " but found "
            <> describe_token(token),
          )
      }
    [] -> Error("expected " <> describe_token(wanted) <> " but reached the end")
  }
}

fn parse_expr(tokens: List(Token)) -> Result(#(Expr, List(Token)), String) {
  case tokens {
    [TLet, TRec, TIdent(name), TEq, TFn, TIdent(param), TArrow, ..rest] ->
      case parse_expr(rest) {
        Error(err) -> Error(err)
        Ok(#(fn_body, after_fn)) ->
          case expect(TIn, after_fn) {
            Error(err) -> Error(err)
            Ok(after_in) ->
              case parse_expr(after_in) {
                Error(err) -> Error(err)
                Ok(#(body, after_body)) ->
                  Ok(#(LetRec(name, param, fn_body, body), after_body))
              }
          }
      }
    [TLet, TIdent(name), TEq, ..rest] ->
      case parse_expr(rest) {
        Error(err) -> Error(err)
        Ok(#(bound, after_bound)) ->
          case expect(TIn, after_bound) {
            Error(err) -> Error(err)
            Ok(after_in) ->
              case parse_expr(after_in) {
                Error(err) -> Error(err)
                Ok(#(body, after_body)) ->
                  Ok(#(Let(name, bound, body), after_body))
              }
          }
      }
    [TLet, ..] -> Error("malformed let")
    [TIf, ..rest] ->
      case parse_expr(rest) {
        Error(err) -> Error(err)
        Ok(#(cond, after_cond)) ->
          case expect(TThen, after_cond) {
            Error(err) -> Error(err)
            Ok(after_then) ->
              case parse_expr(after_then) {
                Error(err) -> Error(err)
                Ok(#(yes, after_yes)) ->
                  case expect(TElse, after_yes) {
                    Error(err) -> Error(err)
                    Ok(after_else) ->
                      case parse_expr(after_else) {
                        Error(err) -> Error(err)
                        Ok(#(no, after_no)) ->
                          Ok(#(If(cond, yes, no), after_no))
                      }
                  }
              }
          }
      }
    [TFn, TIdent(param), TArrow, ..rest] ->
      case parse_expr(rest) {
        Error(err) -> Error(err)
        Ok(#(body, after_body)) -> Ok(#(Lambda(param, body), after_body))
      }
    [TFn, ..] -> Error("malformed fn")
    _ -> parse_comparison(tokens)
  }
}

fn parse_comparison(
  tokens: List(Token),
) -> Result(#(Expr, List(Token)), String) {
  case parse_additive(tokens) {
    Error(err) -> Error(err)
    Ok(#(left, rest)) ->
      case rest {
        [TLess, ..after_op] ->
          case parse_additive(after_op) {
            Error(err) -> Error(err)
            Ok(#(right, after_right)) ->
              Ok(#(BinOp(Less, left, right), after_right))
          }
        [TEqEq, ..after_op] ->
          case parse_additive(after_op) {
            Error(err) -> Error(err)
            Ok(#(right, after_right)) ->
              Ok(#(BinOp(Equal, left, right), after_right))
          }
        _ -> Ok(#(left, rest))
      }
  }
}

fn parse_additive(tokens: List(Token)) -> Result(#(Expr, List(Token)), String) {
  case parse_term(tokens) {
    Error(err) -> Error(err)
    Ok(#(left, rest)) -> additive_loop(left, rest)
  }
}

fn additive_loop(
  left: Expr,
  tokens: List(Token),
) -> Result(#(Expr, List(Token)), String) {
  case tokens {
    [TPlus, ..rest] ->
      case parse_term(rest) {
        Error(err) -> Error(err)
        Ok(#(right, after_right)) ->
          additive_loop(BinOp(Add, left, right), after_right)
      }
    [TMinus, ..rest] ->
      case parse_term(rest) {
        Error(err) -> Error(err)
        Ok(#(right, after_right)) ->
          additive_loop(BinOp(Sub, left, right), after_right)
      }
    _ -> Ok(#(left, tokens))
  }
}

fn parse_term(tokens: List(Token)) -> Result(#(Expr, List(Token)), String) {
  case parse_call(tokens) {
    Error(err) -> Error(err)
    Ok(#(left, rest)) -> term_loop(left, rest)
  }
}

fn term_loop(
  left: Expr,
  tokens: List(Token),
) -> Result(#(Expr, List(Token)), String) {
  case tokens {
    [TStar, ..rest] ->
      case parse_call(rest) {
        Error(err) -> Error(err)
        Ok(#(right, after_right)) ->
          term_loop(BinOp(Mul, left, right), after_right)
      }
    [TSlash, ..rest] ->
      case parse_call(rest) {
        Error(err) -> Error(err)
        Ok(#(right, after_right)) ->
          term_loop(BinOp(Div, left, right), after_right)
      }
    _ -> Ok(#(left, tokens))
  }
}

fn parse_call(tokens: List(Token)) -> Result(#(Expr, List(Token)), String) {
  case parse_atom(tokens) {
    Error(err) -> Error(err)
    Ok(#(callee, rest)) -> call_loop(callee, rest)
  }
}

fn call_loop(
  callee: Expr,
  tokens: List(Token),
) -> Result(#(Expr, List(Token)), String) {
  case tokens {
    [TLParen, ..rest] ->
      case parse_expr(rest) {
        Error(err) -> Error(err)
        Ok(#(argument, after_argument)) ->
          case expect(TRParen, after_argument) {
            Error(err) -> Error(err)
            Ok(after_paren) -> call_loop(Apply(callee, argument), after_paren)
          }
      }
    _ -> Ok(#(callee, tokens))
  }
}

fn parse_atom(tokens: List(Token)) -> Result(#(Expr, List(Token)), String) {
  case tokens {
    [TInt(n), ..rest] -> Ok(#(Num(n), rest))
    [TTrue, ..rest] -> Ok(#(BoolLit(True), rest))
    [TFalse, ..rest] -> Ok(#(BoolLit(False), rest))
    [TIdent(name), ..rest] -> Ok(#(Var(name), rest))
    [TLParen, ..rest] ->
      case parse_expr(rest) {
        Error(err) -> Error(err)
        Ok(#(inner, after_inner)) ->
          case expect(TRParen, after_inner) {
            Error(err) -> Error(err)
            Ok(after_paren) -> Ok(#(inner, after_paren))
          }
      }
    [token, ..] -> Error("unexpected " <> describe_token(token))
    [] -> Error("unexpected end of input")
  }
}

fn describe_token(token: Token) -> String {
  case token {
    TInt(n) -> "number " <> int.to_string(n)
    TIdent(name) -> "name " <> name
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
  }
}

// PRINTER

fn show_expr(expr: Expr) -> String {
  case expr {
    Num(n) -> int.to_string(n)
    BoolLit(True) -> "true"
    BoolLit(False) -> "false"
    Var(name) -> name
    BinOp(op, left, right) ->
      "("
      <> show_expr(left)
      <> " "
      <> op_symbol(op)
      <> " "
      <> show_expr(right)
      <> ")"
    Let(name, bound, body) ->
      "let " <> name <> " = " <> show_expr(bound) <> " in " <> show_expr(body)
    LetRec(name, param, fn_body, body) ->
      "let rec "
      <> name
      <> " = fn "
      <> param
      <> " -> "
      <> show_expr(fn_body)
      <> " in "
      <> show_expr(body)
    If(cond, yes, no) ->
      "if "
      <> show_expr(cond)
      <> " then "
      <> show_expr(yes)
      <> " else "
      <> show_expr(no)
    Lambda(param, body) -> "(fn " <> param <> " -> " <> show_expr(body) <> ")"
    Apply(callee, argument) ->
      show_expr(callee) <> "(" <> show_expr(argument) <> ")"
  }
}

fn op_symbol(op: Op) -> String {
  case op {
    Add -> "+"
    Sub -> "-"
    Mul -> "*"
    Div -> "/"
    Less -> "<"
    Equal -> "=="
  }
}

fn show_value(value: Value) -> String {
  case value {
    VInt(n) -> int.to_string(n)
    VBool(True) -> "true"
    VBool(False) -> "false"
    VClosure(param, _, _) -> "<fn " <> param <> ">"
    VRecClosure(name, _, _, _) -> "<rec fn " <> name <> ">"
  }
}

// EVALUATOR

fn lookup(name: String, env: Env) -> Result(Value, String) {
  case env {
    [] -> Error("unbound variable " <> name)
    [#(key, value), ..rest] ->
      case key == name {
        True -> Ok(value)
        False -> lookup(name, rest)
      }
  }
}

fn eval(env: Env, expr: Expr) -> Result(Value, String) {
  case expr {
    Num(n) -> Ok(VInt(n))
    BoolLit(b) -> Ok(VBool(b))
    Var(name) -> lookup(name, env)
    BinOp(op, left, right) ->
      case eval(env, left) {
        Error(err) -> Error(err)
        Ok(left_value) ->
          case eval(env, right) {
            Error(err) -> Error(err)
            Ok(right_value) -> apply_op(op, left_value, right_value)
          }
      }
    Let(name, bound, body) ->
      case eval(env, bound) {
        Error(err) -> Error(err)
        Ok(value) -> eval([#(name, value), ..env], body)
      }
    LetRec(name, param, fn_body, body) ->
      eval([#(name, VRecClosure(name, param, fn_body, env)), ..env], body)
    If(cond, yes, no) ->
      case eval(env, cond) {
        Error(err) -> Error(err)
        Ok(VBool(True)) -> eval(env, yes)
        Ok(VBool(False)) -> eval(env, no)
        Ok(other) -> Error("condition is not a boolean: " <> show_value(other))
      }
    Lambda(param, body) -> Ok(VClosure(param, body, env))
    Apply(callee, argument) ->
      case eval(env, callee) {
        Error(err) -> Error(err)
        Ok(callee_value) ->
          case eval(env, argument) {
            Error(err) -> Error(err)
            Ok(argument_value) -> apply_function(callee_value, argument_value)
          }
      }
  }
}

fn apply_function(callee: Value, argument: Value) -> Result(Value, String) {
  case callee {
    VClosure(param, body, closure_env) ->
      eval([#(param, argument), ..closure_env], body)
    VRecClosure(name, param, body, closure_env) ->
      eval([#(param, argument), #(name, callee), ..closure_env], body)
    other -> Error("not a function: " <> show_value(other))
  }
}

fn apply_op(op: Op, left: Value, right: Value) -> Result(Value, String) {
  case op, left, right {
    Add, VInt(a), VInt(b) -> Ok(VInt(a + b))
    Sub, VInt(a), VInt(b) -> Ok(VInt(a - b))
    Mul, VInt(a), VInt(b) -> Ok(VInt(a * b))
    Div, VInt(_), VInt(0) -> Error("division by zero")
    Div, VInt(a), VInt(b) -> Ok(VInt(a / b))
    Less, VInt(a), VInt(b) -> Ok(VBool(a < b))
    Equal, VInt(a), VInt(b) -> Ok(VBool(a == b))
    Equal, VBool(a), VBool(b) -> Ok(VBool(a == b))
    _, _, _ ->
      Error(
        "type error: "
        <> show_value(left)
        <> " "
        <> op_symbol(op)
        <> " "
        <> show_value(right),
      )
  }
}

// DRIVER

fn programs() -> List(String) {
  [
    "1 + 2 * 3",
    "(1 + 2) * 3 - 4 / 2",
    "let x = 5 in let y = x * 2 in if x < y then y - x else 0",
    "let add = fn a -> fn b -> a + b in add(3)(4)",
    "let twice = fn f -> fn x -> f(f(x)) in twice(fn n -> n * 3)(7)",
    "let rec fact = fn n -> if n < 2 then 1 else n * fact(n - 1) in fact(10)",
    "let rec fib = fn n -> if n < 2 then n else fib(n - 1) + fib(n - 2) in fib(15)",
    "let rec sum = fn n -> if n == 0 then 0 else n + sum(n - 1) in sum(100)",
    "if 3 == 3 then true == false else false",
    "10 / (5 - 5)",
    "unknown + 1",
    "1 + true",
    "(1 + 2",
    "let = 4",
    "3 # 4",
    "5(6)",
  ]
}

fn run_program(source: String) -> String {
  case parse(source) {
    Error(err) -> "parse error: " <> err
    Ok(expr) ->
      case eval([], expr) {
        Error(err) -> show_expr(expr) <> " => error: " <> err
        Ok(value) -> show_expr(expr) <> " => " <> show_value(value)
      }
  }
}

pub fn run() -> List(String) {
  list.map(programs(), run_program)
}
