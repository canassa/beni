# Syntax

What a beni file looks like where it differs from Elm. The compiler checks every example in this
file, so copy from them.

## Files and modules

- One file is one module. There is no module header. The module name is the file's path below the
  source root: `src/Ui/Card.beni` is the module `Ui.Card` when the root is `src`.
- A declaration is private. `pub` exports it. Put `pub` on a function's annotation, on a `type` and
  on a `type alias`.
- `pub type T = A | B` exports the type and its constructors. `pub opaque type T = A | B` exports
  the name only; the constructors stay in the file.
- Imports come first, one per line. The formatter sorts them. `import M as A` gives an alias.
- `import M exposing (T, A, B, f)` lists each name. List constructors by name beside their type.
  `T(..)` is the error `expected_token`.
- In scope without an import: the types `Int Float Bool Char String List Maybe Result Order`, the
  constructors `True False Just Nothing Ok Err LT EQ GT`, the `Basics` values (`toFloat round floor
  ceiling truncate max min compare not xor negate abs clamp sqrt identity always never` and the
  trigonometry), and the module names `Basics List Maybe Result String Char Debug Int Float Record`
  for qualified use.

```beni
--! A module doc comment stands at the top of the file, before the imports.

import Dict exposing (Dict)
import Set exposing (Set)


--| A doc comment stands before the declaration it documents.
pub type alias Inventory =
    counts : Dict String Int
    tags : Set String


pub opaque type Id
    = Id Int


pub fresh : Int → Id
fresh n = Id n


pub count : Inventory, String → Int
count inv name = Maybe.withDefault (Dict.get inv.counts name) 0
```

## Comments

| Spelling | Is |
|---|---|
| `-- text` | a comment, to the end of the line |
| `--\| text` | a doc comment, for the declaration or record field that follows |
| `--! text` | the module's doc, at the top of the file |

There is no block comment.

## Strings, characters, numbers

- `"text"` is one line. `${expr}` inside it interpolates a `String`, `Int`, `Float`, `Bool` or
  `Char`; the type must be known. A `"` inside an interpolation is an error: bind the inner string
  to a name first.
- Escapes: `\n \r \t \\ \" \$ \' \u{1F600}`.
- A multiline string is a run of lines that start with `\\`. It is raw: no escapes, no
  interpolation. Lines are joined with `\n`.
- `'c'` is a `Char`: one Unicode scalar value.
- `Int` and `Float` are JavaScript doubles. `Int.mod n 2` and `Int.rem n 3` replace `modBy` and
  `remainderBy`. `import Int32` gives exact 32-bit arithmetic that wraps.

```beni
pub greeting : String, Int → String
greeting name count = "${name} has ${count} items"


pub sql : String
sql =
    \\SELECT *
    \\FROM users
```

## Layout

- Indentation is the structure. Four spaces per level. A tab is the error `tab_in_source`.
- The formatter puts a short body on the `=` line, two blank lines between top-level declarations,
  and one blank line between `case` branches.
- Run `beni fmt <path>` on what you write. `beni fmt --check <path>` reports files that differ.

## Blocks

A body written as lines is a block. There is no `let … in`; `let` is the error `let_removed`.

- `x = e` binds a name. An annotation `x : T` can stand on the line before it.
- `x ← f a` binds the rest of the block as the last argument of `f a` (see `calls.md`).
- A line that is an expression is a statement. Its type must be `⊤`. `_ = e` discards a value of
  another type.
- The last line is the block's value. A bind is never last.

```beni
import Ref exposing (Ref)


pub bump : Ref Int → ⊤
bump counter =
    n = Ref.get counter
    if n < 10 then
        Ref.set counter (n + 1)


pub area : Float → Float
area r =
    squared = r * r
    3.14159 * squared
```

## Lambdas

`λx y → e` is the only lambda. `\x -> e` is the error `backslash_lambda_removed`. A lambda's
parameters are irrefutable patterns: a name, `_`, `⊤`, a tuple.

The last argument of a call can be a lambda without parentheses. Its body runs to the end of the
line, or, when it starts on the next line, to the end of that block.

```beni
pub doubled : List Int → List Int
doubled xs = List.map xs λx → x * 2


pub total : List Int → Int
total xs = List.foldl xs 0 λx acc → x + acc
```

## `if` and `case`

- `if c then a else b`. When `a` has type `⊤`, the `else` can be left out: `if c then a`.
- `case e of` lists branches. The formatter writes each body on the line after its pattern.
- A `case` must be exhaustive. Patterns: a constructor with its arguments, a literal, a name, `_`,
  `( a, b )`, `[]`, `[ x ]`, `[ x, …rest ]`, `[ …init, last ]`, `⊤`.

```beni
pub describe : List Int → String
describe xs =
    case xs of
        [] →
            "empty"

        [ x ] →
            "one: ${x}"

        [ x, …rest ] →
            "${x} and ${List.length rest} more"
```

## `⊤` and `⊥`

- `⊤` (U+22A4) is the unit type and its one value: `log : String → ⊤`, `λ⊤ → e`, `f ⊤`.
- `⊥` (U+22A5) is the type with no values. `never : ⊥ → a` uses one.
- `()` is the error `unit_spelling_removed`; `Never` is `never_spelling_removed`.

## The Unicode notation

One spelling per symbol. The ASCII form is the error `ascii_symbol_removed`.

| Write | For Elm's | Code point |
|---|---|---|
| `→` | `->` | U+2192 |
| `←` | `<-` | U+2190 |
| `≠` | `/=` | U+2260 |
| `≤` `≥` | `<=` `>=` | U+2264, U+2265 |
| `▷` | `\|>` | U+25B7 |
| `◁` | `<\|` | U+25C1 |
| `…` | `...` (a spread) | U+2026 |
| `×` | a tuple type `( a, b )` | U+00D7 |
| `λ` | `\` | U+03BB |

`&&`, `||`, `==`, `++`, `+ - * /` stay ASCII. `beni fmt --migrate-unicode <file>` rewrites a file
that still has the ASCII forms. A type `Int × String` is one pair; `a × b × c` is one flat 3-tuple;
`Int, Int → Int` takes two arguments where `Int × Int → Int` takes one pair.

## Records

- A literal: `{ x = 1, y = 2 }`. Access: `p.x`. An accessor function: `.x`.
- An update: `{ p | x = 1 }`. Today the compiler accepts a later use of the old `p`. A rule that
  makes the update consume its base is specified and not built. `{ Record.copy p | x = 1 }` keeps
  a copy of `p` on purpose and compiles today. See `lists.md`, *Ownership*.
- A record alias is written in layout: one field per line, no braces. The formatter writes this
  form. A record type inside another type keeps braces: `List { x : Int, y : Int }`.
- An untouched field keeps its identity across an update, which is what makes a view cheap.

```beni
pub type alias Point =
    x : Int
    y : Int


pub moveRight : Point, Int → Point
moveRight p dx = { p | x = p.x + dx }


pub norm : Point → Int
norm p = abs p.x + abs p.y
```

## Tuples

`( a, b )` builds one; `t.0` and `t.1` read it; `( a, b )` matches it. The type is `Int × String`.
Any arity from 2 up. There is no `Tuple` module.

## `?`

`e?` where `e : Result x a` yields the `a` or returns the `Err` from the enclosing function. Where
`e : Maybe a` it yields the `a` or returns `Nothing`. It binds tighter than every operator and
looser than application: `parse s?` is `(parse s)?`. It returns from the nearest definition with
parameters. Inside a lambda it is the error `question_in_lambda`.

```beni
pub sum : String, String → Result String Int
sum a b =
    x = toInt a?
    y = toInt b?
    Ok (x + y)


toInt : String → Result String Int
toInt s =
    case String.toInt s of
        Just n →
            Ok n

        Nothing →
            Err "not a number: ${s}"
```

## What Elm writes that beni refuses

```beni refused=cons_removed
pub first : List Int → Int
first xs =
    case xs of
        x :: _ →
            x

        [] →
            0
```

```beni refused=ascii_symbol_removed
pub twice : Int -> Int
twice n = n * 2
```

```beni refused=unit_spelling_removed
pub start : () → Int
start () = 0
```

```beni refused=let_removed
pub area : Float → Float
area r =
    let
        squared = r * r
    in
    3.14159 * squared
```

```beni refused=backslash_lambda_removed
pub doubled : List Int → List Int
doubled xs = List.map xs (\x → x * 2)
```

Sources: `docs/design/language.md` §0, §2, §4, §5, §6.3, §6.4, §6.6, §12, Appendix A.
