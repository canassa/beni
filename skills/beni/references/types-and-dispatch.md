# Types and static dispatch

Custom types and aliases are Elm's. What is new: a type has methods, `x.m a` calls one, a `where`
clause constrains a type variable, and `==` and `<` are method calls.

## Declarations

- `type Shape = Circle Float | Dot` declares a custom type. `pub type` exports it with its
  constructors; `pub opaque type` exports the name only.
- `type alias` names a type. A record alias is written in layout: one field per line, no braces.
- A type can take parameters: `type Tree a = Leaf | Node (Tree a) a (Tree a)`.

```beni
pub type Tree a
    = Leaf
    | Node (Tree a) a (Tree a)


pub type alias Named a =
    name : String
    value : a


pub size : Tree a → Int
size tree =
    case tree of
        Leaf →
            0

        Node left _ right →
            size left + 1 + size right
```

## Methods: the module rule

**A type's methods are the `pub` values of the module that declares it.** `x.m a b` calls `m` from
that module with `x` as the first argument: `xs.length` is `List.length xs`, `s.trim` is
`String.trim s`, `d.insert k v` is `Dict.insert d k v`. Nothing is declared to make this work.

- On a record, `x.m` reads the field `m`. On a value of a nominal type it calls the method. A chain
  decides each dot on its own: `xs.reverse.length`.
- `(x.m) a` is an ordinary call of the field's value: the parentheses opt out.
- `M.f x` is a qualified call, not a method call.
- A method you cannot see (private, or in another module) is `unknown_method` or `private_method`.
- An unannotated helper `size xs = xs.length` infers a record parameter. Annotate it, or write
  `List.length xs`.

```beni
pub type Money
    = Cents Int


pub add : Money, Money → Money
add (Cents a) (Cents b) = Cents (a + b)


pub total : List Money → Money
total prices = List.foldl prices (Cents 0) λprice acc → acc.add price
```

## `where` clauses

A top-level annotation can constrain a type variable with the methods a body needs:

```text
largest : List a → Maybe a
    where a.compare : a, a → Order
```

- The clause stands after the type, indented, one constraint per name: `where a.compare : …,
  a.eq : …`. Only a top-level annotation takes one.
- A call site supplies nothing. The compiler resolves the method from the argument's type at
  each call, at compile time.
- An unannotated function infers its constraints, up to 64. Past 64, write the annotation.

## `eq` and `compare`

`==` and `≠` call the receiver type's `eq`; `<`, `≤`, `>` and `≥` call its `compare`. Both
operands have the same type.

- A type that declares no `pub eq` gets one derived from its shape: constructor by constructor,
  field by field, each by its own `eq`. The same for `compare`, in declaration order.
- A module declares `pub eq : T, T → Bool` or `pub compare : T, T → Order` to replace the derived
  one.
- `Dict k v` keys and `Set a` members must be `Int` or `String` (aliases are accepted).
  Any other key type, also a wrapper around `Int` or `String`, is the error `invalid_dict_key`.
  The constraint survives generic functions and module boundaries without comparison evidence.
  Dict and Set have no compare because insertion order is part of their value; enclosing
  shapes cannot derive it either. Your own wrapper may declare its own `pub compare`.
  `List.sort` needs `compare`; `List.member` needs `eq`. A `where` clause carries those
  method requirements through a generic function.
- A function has no `eq`, so a record that holds one cannot be compared.

A `Char` key is refused, also in a type annotation that no code uses:

```beni refused=invalid_dict_key
import Dict exposing (Dict)


pub letters : Dict Char Int
letters = Dict.empty ⊤
```

```beni
pub type Money
    = Cents Int


pub compare : Money, Money → Order
compare (Cents a) (Cents b) = Basics.compare a b


pub largest : List a → Maybe a
    where a.compare : a, a → Order
largest xs = List.foldl xs Nothing λx best →
    case best of
        Nothing →
            Just x

        Just b →
            if x > b then
                Just x
            else
                Just b


pub richest : List Money → Maybe Money
richest prices = largest prices


pub same : Money, Money → Bool
same a b = a == b
```

## Return-type dispatch

Inside a declaration whose annotation has a `where` clause, `a.m x` where `a` is a constrained
type variable and not a value dispatches on the **result** type. It is how a decoder is picked by
what the caller wants. The call site needs an annotation that fixes `a`.

```beni
pub type Count
    = Count Int


pub decode : String → Result String Count
decode s =
    case String.toInt s of
        Just n →
            Ok (Count n)

        Nothing →
            Err "not a count: ${s}"


pub decodeAll : List String → Result String (List a)
    where a.decode : String → Result String a
decodeAll texts =
    case texts of
        [] →
            Ok []

        [ text, …rest ] →
            item = a.decode text?
            items = decodeAll rest?
            Ok [ item, …items ]


pub counts : List String → Result String (List Count)
counts texts = decodeAll texts
```

Sources: `docs/design/language.md` §5.1, §6.3; `docs/design/static-dispatch-spike.md` §1–§4.
