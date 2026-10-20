# Calls

beni has no automatic currying. This file gives the four rules that follow from that, and the
argument order of the library.

## Every call is saturated

- A function with *n* parameters has an n-ary type: `add : Int, Int → Int`. Write all the
  parameters before one arrow.
- A call supplies exactly *n* arguments. Fewer is `too_few_args`, more is `too_many_args`. There
  is no partial application by leaving arguments off.
- An Elm annotation `Int → Int → Int` is a function that returns a function. It does not match a
  two-parameter body (`type_mismatch`, with a hint).

```beni
pub add : Int, Int → Int
add a b = a + b


pub sum3 : Int, Int, Int → Int
sum3 a b c = add (add a b) c
```

```beni refused=too_few_args
add : Int, Int → Int
add a b = a + b


pub increment : Int → Int
increment = add 1
```

## `_` is the placeholder

`f a _ c` is `λx → f a x c`. The placeholder can fill any position, the first included. At most one
`_` per call; two missing arguments are a lambda. The lambda wraps the innermost call: in
`f (g _) b` the placeholder belongs to `g`.

```beni
add : Int, Int → Int
add a b = a + b


pub incrementAll : List Int → List Int
incrementAll xs = List.map xs (add 1 _)


pub halves : List Float → List Float
halves xs = List.map xs λx → x / 2
```

## `▷` and `◁`

- `e ▷ f a b` is `f e a b`: the left operand becomes the **first** argument. The right operand is
  a call or a name. A bare `case`, `if`, lambda, `?` or operator chain there is the error
  `pipe_rhs_not_application`.
- `f a ◁ e` is `f a e`, Elm's `<|`.
- `>>` and `<<` are gone. Name the argument: `λx → g (f x)`.

```beni
import String


pub slug : String → String
slug title =
    title
        ▷ String.trim
        ▷ String.toLower
        ▷ String.words
        ▷ String.join "-"
```

## Subject first, function last

Because a pipe inserts at the first argument, every library function takes the value it is about
first and a callback last. Elm's order is refused with a hint (`type_mismatch`), and a call that
type-checks in Elm's order gets the warning `suspicious_argument_order`.

| beni | Elm |
|---|---|
| `List.map xs f` | `List.map f xs` |
| `List.foldl xs init λx acc → …` | `List.foldl (\x acc -> …) init xs` |
| `List.filter xs p` | `List.filter p xs` |
| `String.split s ","` | `String.split "," s` |
| `String.join parts ", "` | `String.join ", " parts` |
| `Dict.get d key` | `Dict.get key d` |
| `Dict.insert d key value` | `Dict.insert key value d` |
| `Maybe.withDefault m 0` | `Maybe.withDefault 0 m` |
| `Result.andThen r f` | `Result.andThen f r` |
| `Int.mod n 2` | `modBy 2 n` |
| `Int.rem n 3` | `remainderBy 3 n` |
| `Float.log x 10` | `logBase 10 x` |
| `clamp n low high` | `clamp low high n` |
| `Debug.log "label" value` | `Debug.log "label" value` (the same) |

A callback takes the element first: `List.foldl xs 0 λx acc → acc + x`; `List.indexedMap xs λi x → …`.

## A trailing lambda

The last argument of a call can be a lambda without parentheses. When its body starts on the same
line, the body runs to the end of the line, so a pipeline continues on the next line. A lambda that
is not the last argument keeps its parentheses.

```beni
import Dict exposing (Dict)


pub tally : List String → Dict String Int
tally words = List.foldl words Dict.empty λword counts →
    Dict.update counts word λn → Just (Maybe.withDefault n 0 + 1)
```

## `←` binds the rest of the block

`x ← f a b` makes every line after it the body of a lambda, and passes that lambda as the last
argument of `f a b`. It is syntax, nothing else: `f a b (λx → rest)`. Use it for a function that
takes a callback last, such as `Task.scope` or `Task.bracket`. For a `Result` or a `Maybe`, `?` is
shorter.

```beni
import Task exposing (Fiber)


pub both : (⊤ → Int), (⊤ → Int) → Int
both left right =
    scope ← Task.scope
    a = Task.spawn left
    b = Task.spawn right
    Task.join a + Task.join b
```

A bind is never the last line of a block. A `?` after a bind in the same block is an error, because
the rest of the block is a lambda.

## Method calls

`x.m a` calls `m` from the module that declares `x`'s type, with `x` as the first argument:
`xs.length`, `s.trim`, `d.get key`. On a record, `x.m` reads the field `m`. `(x.m) a` is a call of
the field's value. See `types-and-dispatch.md`.

Sources: `docs/design/language.md` §6.5, §6.7, §12.3, §12.4; `docs/design/static-dispatch-spike.md` §1.1.
