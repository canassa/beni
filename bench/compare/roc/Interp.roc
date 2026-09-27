module [run]

# A tokenizer, recursive-descent parser, printer and evaluator for a small
# expression language: integers, booleans, arithmetic, comparisons,
# let, let rec, if, one-parameter lambdas and application.

Token : [
    TInt I64,
    TIdent Str,
    TPlus,
    TMinus,
    TStar,
    TSlash,
    TLess,
    TEqEq,
    TEq,
    TLParen,
    TRParen,
    TArrow,
    TLet,
    TRec,
    TIn,
    TIf,
    TThen,
    TElse,
    TFn,
    TTrue,
    TFalse,
]

Op : [Add, Sub, Mul, Div, Less, Equal]

Expr : [
    Num I64,
    BoolLit Bool,
    Var Str,
    BinOp Op Expr Expr,
    Let Str Expr Expr,
    LetRec Str Str Expr Expr,
    If Expr Expr Expr,
    Lambda Str Expr,
    Apply Expr Expr,
]

Value : [
    VInt I64,
    VBool Bool,
    VClosure Str Expr (List (Str, Value)),
    VRecClosure Str Str Expr (List (Str, Value)),
]

Env : List (Str, Value)

# TOKENIZER

tokenize : Str -> Result (List Token) Str
tokenize = |source|
    tokenize_chars(Str.to_utf8(source), [])

tokenize_chars : List U8, List Token -> Result (List Token) Str
tokenize_chars = |chars, acc|
    when chars is
        [] -> Ok(List.reverse(acc))
        [' ', .. as rest] -> tokenize_chars(rest, acc)
        ['\n', .. as rest] -> tokenize_chars(rest, acc)
        ['-', '>', .. as rest] -> tokenize_chars(rest, List.prepend(acc, TArrow))
        ['=', '=', .. as rest] -> tokenize_chars(rest, List.prepend(acc, TEqEq))
        ['+', .. as rest] -> tokenize_chars(rest, List.prepend(acc, TPlus))
        ['-', .. as rest] -> tokenize_chars(rest, List.prepend(acc, TMinus))
        ['*', .. as rest] -> tokenize_chars(rest, List.prepend(acc, TStar))
        ['/', .. as rest] -> tokenize_chars(rest, List.prepend(acc, TSlash))
        ['<', .. as rest] -> tokenize_chars(rest, List.prepend(acc, TLess))
        ['=', .. as rest] -> tokenize_chars(rest, List.prepend(acc, TEq))
        ['(', .. as rest] -> tokenize_chars(rest, List.prepend(acc, TLParen))
        [')', .. as rest] -> tokenize_chars(rest, List.prepend(acc, TRParen))
        [c, ..] ->
            if is_digit(c) then
                (digits, remaining) = span_chars(is_digit, chars, [])
                tokenize_chars(remaining, List.prepend(acc, TInt(digits_to_int(digits))))
            else if is_alpha(c) then
                (letters, remaining) = span_chars(is_alpha_num, chars, [])
                tokenize_chars(remaining, List.prepend(acc, keyword(Str.from_utf8_lossy(letters))))
            else
                Err("unexpected character ${Str.from_utf8_lossy([c])}")

is_digit : U8 -> Bool
is_digit = |c| c >= '0' and c <= '9'

is_alpha : U8 -> Bool
is_alpha = |c| (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')

is_alpha_num : U8 -> Bool
is_alpha_num = |c| is_alpha(c) or is_digit(c)

span_chars : (U8 -> Bool), List U8, List U8 -> (List U8, List U8)
span_chars = |predicate, chars, taken|
    when chars is
        [c, .. as rest] ->
            if predicate(c) then
                span_chars(predicate, rest, List.prepend(taken, c))
            else
                (List.reverse(taken), chars)

        [] -> (List.reverse(taken), [])

digits_to_int : List U8 -> I64
digits_to_int = |digits|
    List.walk(digits, 0, |total, d| total * 10 + Num.to_i64(d) - 48)

keyword : Str -> Token
keyword = |word|
    when word is
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

# PARSER

parse : Str -> Result Expr Str
parse = |source|
    when tokenize(source) is
        Err(err) -> Err(err)
        Ok(tokens) ->
            when parse_expr(tokens) is
                Err(err) -> Err(err)
                Ok((expr, [])) -> Ok(expr)
                Ok((_, [token, ..])) -> Err("unexpected ${describe_token(token)} after expression")

expect_token : Token, List Token -> Result (List Token) Str
expect_token = |wanted, tokens|
    when tokens is
        [token, .. as rest] ->
            if token == wanted then
                Ok(rest)
            else
                Err("expected ${describe_token(wanted)} but found ${describe_token(token)}")

        [] -> Err("expected ${describe_token(wanted)} but reached the end")

parse_expr : List Token -> Result (Expr, List Token) Str
parse_expr = |tokens|
    when tokens is
        [TLet, TRec, TIdent(name), TEq, TFn, TIdent(param), TArrow, .. as rest] ->
            when parse_expr(rest) is
                Err(err) -> Err(err)
                Ok((fn_body, after_fn)) ->
                    when expect_token(TIn, after_fn) is
                        Err(err) -> Err(err)
                        Ok(after_in) ->
                            when parse_expr(after_in) is
                                Err(err) -> Err(err)
                                Ok((body, after_body)) -> Ok((LetRec(name, param, fn_body, body), after_body))

        [TLet, TIdent(name), TEq, .. as rest] ->
            when parse_expr(rest) is
                Err(err) -> Err(err)
                Ok((bound, after_bound)) ->
                    when expect_token(TIn, after_bound) is
                        Err(err) -> Err(err)
                        Ok(after_in) ->
                            when parse_expr(after_in) is
                                Err(err) -> Err(err)
                                Ok((body, after_body)) -> Ok((Let(name, bound, body), after_body))

        [TLet, ..] -> Err("malformed let")
        [TIf, .. as rest] ->
            when parse_expr(rest) is
                Err(err) -> Err(err)
                Ok((cond, after_cond)) ->
                    when expect_token(TThen, after_cond) is
                        Err(err) -> Err(err)
                        Ok(after_then) ->
                            when parse_expr(after_then) is
                                Err(err) -> Err(err)
                                Ok((yes, after_yes)) ->
                                    when expect_token(TElse, after_yes) is
                                        Err(err) -> Err(err)
                                        Ok(after_else) ->
                                            when parse_expr(after_else) is
                                                Err(err) -> Err(err)
                                                Ok((no, after_no)) -> Ok((If(cond, yes, no), after_no))

        [TFn, TIdent(param), TArrow, .. as rest] ->
            when parse_expr(rest) is
                Err(err) -> Err(err)
                Ok((body, after_body)) -> Ok((Lambda(param, body), after_body))

        [TFn, ..] -> Err("malformed fn")
        _ -> parse_comparison(tokens)

parse_comparison : List Token -> Result (Expr, List Token) Str
parse_comparison = |tokens|
    when parse_additive(tokens) is
        Err(err) -> Err(err)
        Ok((left, rest)) ->
            when rest is
                [TLess, .. as after_op] ->
                    when parse_additive(after_op) is
                        Err(err) -> Err(err)
                        Ok((right, after_right)) -> Ok((BinOp(Less, left, right), after_right))

                [TEqEq, .. as after_op] ->
                    when parse_additive(after_op) is
                        Err(err) -> Err(err)
                        Ok((right, after_right)) -> Ok((BinOp(Equal, left, right), after_right))

                _ -> Ok((left, rest))

parse_additive : List Token -> Result (Expr, List Token) Str
parse_additive = |tokens|
    when parse_term(tokens) is
        Err(err) -> Err(err)
        Ok((left, rest)) -> additive_loop(left, rest)

additive_loop : Expr, List Token -> Result (Expr, List Token) Str
additive_loop = |left, tokens|
    when tokens is
        [TPlus, .. as rest] ->
            when parse_term(rest) is
                Err(err) -> Err(err)
                Ok((right, after_right)) -> additive_loop(BinOp(Add, left, right), after_right)

        [TMinus, .. as rest] ->
            when parse_term(rest) is
                Err(err) -> Err(err)
                Ok((right, after_right)) -> additive_loop(BinOp(Sub, left, right), after_right)

        _ -> Ok((left, tokens))

parse_term : List Token -> Result (Expr, List Token) Str
parse_term = |tokens|
    when parse_call(tokens) is
        Err(err) -> Err(err)
        Ok((left, rest)) -> term_loop(left, rest)

term_loop : Expr, List Token -> Result (Expr, List Token) Str
term_loop = |left, tokens|
    when tokens is
        [TStar, .. as rest] ->
            when parse_call(rest) is
                Err(err) -> Err(err)
                Ok((right, after_right)) -> term_loop(BinOp(Mul, left, right), after_right)

        [TSlash, .. as rest] ->
            when parse_call(rest) is
                Err(err) -> Err(err)
                Ok((right, after_right)) -> term_loop(BinOp(Div, left, right), after_right)

        _ -> Ok((left, tokens))

parse_call : List Token -> Result (Expr, List Token) Str
parse_call = |tokens|
    when parse_atom(tokens) is
        Err(err) -> Err(err)
        Ok((callee, rest)) -> call_loop(callee, rest)

call_loop : Expr, List Token -> Result (Expr, List Token) Str
call_loop = |callee, tokens|
    when tokens is
        [TLParen, .. as rest] ->
            when parse_expr(rest) is
                Err(err) -> Err(err)
                Ok((argument, after_argument)) ->
                    when expect_token(TRParen, after_argument) is
                        Err(err) -> Err(err)
                        Ok(after_paren) -> call_loop(Apply(callee, argument), after_paren)

        _ -> Ok((callee, tokens))

parse_atom : List Token -> Result (Expr, List Token) Str
parse_atom = |tokens|
    when tokens is
        [TInt(n), .. as rest] -> Ok((Num(n), rest))
        [TTrue, .. as rest] -> Ok((BoolLit(Bool.true), rest))
        [TFalse, .. as rest] -> Ok((BoolLit(Bool.false), rest))
        [TIdent(name), .. as rest] -> Ok((Var(name), rest))
        [TLParen, .. as rest] ->
            when parse_expr(rest) is
                Err(err) -> Err(err)
                Ok((inner, after_inner)) ->
                    when expect_token(TRParen, after_inner) is
                        Err(err) -> Err(err)
                        Ok(after_paren) -> Ok((inner, after_paren))

        [token, ..] -> Err("unexpected ${describe_token(token)}")
        [] -> Err("unexpected end of input")

describe_token : Token -> Str
describe_token = |token|
    when token is
        TInt(n) -> "number ${Num.to_str(n)}"
        TIdent(name) -> "name ${name}"
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

# PRINTER

show_expr : Expr -> Str
show_expr = |expr|
    when expr is
        Num(n) -> Num.to_str(n)
        BoolLit(b) -> if b then "true" else "false"
        Var(name) -> name
        BinOp(op, left, right) -> "(${show_expr(left)} ${op_symbol(op)} ${show_expr(right)})"
        Let(name, bound, body) -> "let ${name} = ${show_expr(bound)} in ${show_expr(body)}"
        LetRec(name, param, fn_body, body) -> "let rec ${name} = fn ${param} -> ${show_expr(fn_body)} in ${show_expr(body)}"
        If(cond, yes, no) -> "if ${show_expr(cond)} then ${show_expr(yes)} else ${show_expr(no)}"
        Lambda(param, body) -> "(fn ${param} -> ${show_expr(body)})"
        Apply(callee, argument) -> "${show_expr(callee)}(${show_expr(argument)})"

op_symbol : Op -> Str
op_symbol = |op|
    when op is
        Add -> "+"
        Sub -> "-"
        Mul -> "*"
        Div -> "/"
        Less -> "<"
        Equal -> "=="

show_value : Value -> Str
show_value = |value|
    when value is
        VInt(n) -> Num.to_str(n)
        VBool(b) -> if b then "true" else "false"
        VClosure(param, _, _) -> "<fn ${param}>"
        VRecClosure(name, _, _, _) -> "<rec fn ${name}>"

# EVALUATOR

lookup : Str, Env -> Result Value Str
lookup = |name, env|
    when env is
        [] -> Err("unbound variable ${name}")
        [(key, value), .. as rest] ->
            if key == name then
                Ok(value)
            else
                lookup(name, rest)

eval : Env, Expr -> Result Value Str
eval = |env, expr|
    when expr is
        Num(n) -> Ok(VInt(n))
        BoolLit(b) -> Ok(VBool(b))
        Var(name) -> lookup(name, env)
        BinOp(op, left, right) ->
            when eval(env, left) is
                Err(err) -> Err(err)
                Ok(left_value) ->
                    when eval(env, right) is
                        Err(err) -> Err(err)
                        Ok(right_value) -> apply_op(op, left_value, right_value)

        Let(name, bound, body) ->
            when eval(env, bound) is
                Err(err) -> Err(err)
                Ok(value) -> eval(List.prepend(env, (name, value)), body)

        LetRec(name, param, fn_body, body) ->
            eval(List.prepend(env, (name, VRecClosure(name, param, fn_body, env))), body)

        If(cond, yes, no) ->
            when eval(env, cond) is
                Err(err) -> Err(err)
                Ok(VBool(b)) -> if b then eval(env, yes) else eval(env, no)
                Ok(other) -> Err("condition is not a boolean: ${show_value(other)}")

        Lambda(param, body) -> Ok(VClosure(param, body, env))
        Apply(callee, argument) ->
            when eval(env, callee) is
                Err(err) -> Err(err)
                Ok(callee_value) ->
                    when eval(env, argument) is
                        Err(err) -> Err(err)
                        Ok(argument_value) -> apply_function(callee_value, argument_value)

apply_function : Value, Value -> Result Value Str
apply_function = |callee, argument|
    when callee is
        VClosure(param, body, closure_env) ->
            eval(List.prepend(closure_env, (param, argument)), body)

        VRecClosure(name, param, body, closure_env) ->
            eval(List.concat([(param, argument), (name, callee)], closure_env), body)

        other -> Err("not a function: ${show_value(other)}")

apply_op : Op, Value, Value -> Result Value Str
apply_op = |op, left, right|
    when (op, left, right) is
        (Add, VInt(a), VInt(b)) -> Ok(VInt(a + b))
        (Sub, VInt(a), VInt(b)) -> Ok(VInt(a - b))
        (Mul, VInt(a), VInt(b)) -> Ok(VInt(a * b))
        (Div, VInt(_), VInt(0)) -> Err("division by zero")
        (Div, VInt(a), VInt(b)) -> Ok(VInt(a // b))
        (Less, VInt(a), VInt(b)) -> Ok(VBool(a < b))
        (Equal, VInt(a), VInt(b)) -> Ok(VBool(a == b))
        (Equal, VBool(a), VBool(b)) -> Ok(VBool(a == b))
        _ -> Err("type error: ${show_value(left)} ${op_symbol(op)} ${show_value(right)}")

# DRIVER

programs : List Str
programs = [
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

run_program : Str -> Str
run_program = |source|
    when parse(source) is
        Err(err) -> "parse error: ${err}"
        Ok(expr) ->
            when eval([], expr) is
                Err(err) -> "${show_expr(expr)} => error: ${err}"
                Ok(value) -> "${show_expr(expr)} => ${show_value(value)}"

run : List Str
run = List.map(programs, run_program)
