# Lists

`List a` is beni's one sequence type. It is a JavaScript array. There is no `Array` module and no
cons list.

## The syntax

- A literal: `[ 1, 2, 3 ]`. The formatter writes a space inside the brackets.
- A spread builds a list from others: `[ x, …xs ]`, `[ …xs, x ]`, `[ …a, …b ]`, `[ a, …mid, z ]`.
- A pattern: `[]`, `[ x ]`, `[ x, y ]`, `[ x, …rest ]`, `[ …init, last ]`, `[ first, …middle, last ]`.
- `::` is gone, as an operator, a pattern and `(::)`: the error `cons_removed`. `List.cons x xs` is
  `[ x, …xs ]` as a function.
- `xs ++ ys` on two lists is `List.append xs ys`.

```beni
pub pairs : List Int → List (Int × Int)
pairs xs =
    case xs of
        [ a, b, …rest ] →
            [ ( a, b ), …pairs rest ]

        _ →
            []


pub lastOr : List Int, Int → Int
lastOr xs default =
    case xs of
        [ …_, last ] →
            last

        [] →
            default
```

## What each operation costs

A list grows at its **end**. *n* is the list's length.

| Operation | Cost |
|---|---|
| `List.length xs`, `List.isEmpty xs` | O(1) |
| `List.get xs i`, `List.head xs`, `List.last xs` | O(1) |
| a pattern's `rest`, `List.tail xs`, `List.drop xs k` | O(1), a read-only view |
| `List.push xs x`, `[ …xs, x ]` | amortised O(1) |
| `[ x, …xs ]`, `List.cons x xs` | O(n), a copy |
| `List.set xs i x`, `List.update xs i f` | O(1) in place, else O(n) |
| `List.map`, `List.filter`, `List.reverse`, the sorts | O(n) or O(n log n), a fresh list |

A loop that puts elements in front of its accumulator gets the warning `prepend_in_loop`: push at
the end instead, and reverse once if the order matters.

```beni
pub squares : Int → List Int
squares n = List.map (List.range 1 n) λi → i * i


pub evens : List Int → List Int
evens xs = List.filter xs λx → Int.mod x 2 == 0


pub countdown : Int → List Int
countdown n = loop n [] λacc → acc


loop : Int, List Int, (List Int → List Int) → List Int
loop n acc k =
    if n == 0 then
        k acc
    else
        loop (n - 1) (List.push acc n) k
```

## The functions you reach for

All take the list first and a callback last (`calls.md`). The callback takes the element first.

| Function | Type |
|---|---|
| `List.map` | `List a, (a → b) → List b` |
| `List.indexedMap` | `List a, (Int, a → b) → List b` |
| `List.filter`, `List.filterMap` | `List a, (a → Bool) → List a`; `List a, (a → Maybe b) → List b` |
| `List.foldl`, `List.foldr` | `List a, b, (a, b → b) → b` |
| `List.any`, `List.all` | `List a, (a → Bool) → Bool` |
| `List.member` | `List a, a → Bool`, by the element type's `eq` |
| `List.sort`, `List.sortBy` | by the element type's `compare`; `List a, (a → b) → List a` |
| `List.get`, `List.set`, `List.update` | `List a, Int → Maybe a`; `List a, Int, a → List a`; `List a, Int, (a → a) → List a` |
| `List.push`, `List.pop` | `List a, a → List a`; `List a → List a` |
| `List.insertAt`, `List.removeAt` | `List a, Int, a → List a`; `List a, Int → List a` |
| `List.take`, `List.drop`, `List.slice` | `List a, Int → List a`; `List a, Int, Int → List a` |
| `List.range`, `List.repeat` | `Int, Int → List Int`; `a, Int → List a` |
| `List.sum`, `List.maximum`, `List.concat`, `List.reverse`, `List.partition`, `List.unzip` | as in Elm, subject first |

`api-core.md` has the whole module.

## Ownership

A write — `List.push`, `List.set`, `[ …xs, x ]` — edits the array in place when the compiler can
prove that nothing reads the old list afterwards. The ownership checker proves it per platform:

- On `browser-inline`, every write it accepts is edited in place. A write to a list that is read
  again later is the error `list_still_used` (title LIST CHANGED WHILE STILL IN USE). A write to a
  top-level list is `top_level_list_changed`. The fix is `List.copy xs` at the point where the old
  list must stay: the copy is written, the original is kept.
- On `node`, `browser` and `browser-tea`, a write that the checker cannot prove safe copies.

The same program checks on every platform when it copies where it keeps an old version. Keeping
every version of a list (an undo stack, a history) costs O(n) per version; keep the edits instead,
or copy on purpose.

```beni platform=browser-inline
pub snapshot : List Int → List Int × List Int
snapshot xs =
    before = List.copy xs
    ( before, List.push xs 0 )
```

```beni platform=browser-inline refused=list_still_used
pub snapshot : List Int → List Int × List Int
snapshot xs =
    after = List.push xs 0
    ( xs, after )
```

## Dict and Set

`Dict k v` and `Set t` keep insertion order. `keys`, `values`, `toList` and the folds use that
order. Insert of a key that is there already keeps its position; remove and insert again puts it
at the end. Equality includes order: `Dict.fromList [ ( 1, "a" ), ( 2, "b" ) ]` is not equal to
`Dict.fromList [ ( 2, "b" ), ( 1, "a" ) ]`. Sort explicitly when you need key order:
`Dict.sortBy d λk _ → k`. `Dict.swap` and `Dict.insertAt` change positions; `Dict.keyAt d i` is
the key at position `i`, or `Nothing`. `Dict.empty ⊤` and `Set.empty ⊤` make new storage per call.

`insert`, `remove`, `update`, `swap`, `insertAt` and `sortBy` edit the collection in place. The
ownership checker applies the same rules as for a list. The fix for a write to a collection that
is read again is `Dict.copy d` or `Set.copy s`. A copy is shallow: the values stay shared.

```beni platform=browser-inline
import Dict exposing (Dict)


pub keep : Dict Int String → Dict Int String × Dict Int String
keep d =
    before = Dict.copy d
    ( before, Dict.insert d 1 "one" )
```

A record update `{ p | x = 1 }` is checked where list writes are. A later read of a field of the
old `p` is accepted: the compiler reads the old value first. A later use of the old `p` whole is
the error `record_still_used`. An update of a top-level record is `top_level_record_changed`. An
update the checker cannot prove safe is `record_may_be_shared`. The fix is
`{ Record.copy p | x = 1 }`.

```beni platform=browser-inline
type alias Point =
    x : Int
    y : Int


pub moved : Point → Int
moved p =
    q = { p | x = 1 }
    q.x + p.x
```

```beni platform=browser-inline refused=record_still_used
type alias Point =
    x : Int
    y : Int


pub both : Point → Point × Point
both p = ( { p | x = 1 }, p )
```

```beni platform=browser-inline
type alias Point =
    x : Int
    y : Int


pub both : Point → Point × Point
both p = ( { Record.copy p | x = 1 }, p )
```

## Recursive values

The checker keeps one place for all the levels of one part of a recursive value. For a `Tree`,
the lists of the left subtree are one place, the left child's own list included. The checker
cannot show that two levels of that part hold different lists. A write to a list of one level,
while a list of another level of the same part is read later, is the error `list_may_be_shared`.
The error occurs also when the two lists are different. This is the one case where the checker
refuses a safe program.

Here `alternate` puts `a` at the root and two levels down, and `b` between. `grown` changes the
root's list and reads the left child's list. That is safe, but it is refused:

```beni platform=browser-inline refused=list_may_be_shared
type Tree
    = Leaf
    | Node Tree (List Int) Tree


alternate : List Int, List Int → Tree
alternate a b = Node (Node (Node Leaf a Leaf) b Leaf) a Leaf


pub grown : List Int, List Int → Int
grown a b =
    case alternate a b of
        Node l xs _ →
            case l of
                Node _ ys _ →
                    List.length (List.push xs 1) + List.length ys

                Leaf →
                    0

        Leaf →
            0
```

The fix is a copy where the list is put into the value, so that no two levels hold the same list.
A copy at the write (`List.push (List.copy xs) 1`) also works. Copy a record field with
`Record.copy`.

```beni platform=browser-inline
type Tree
    = Leaf
    | Node Tree (List Int) Tree


alternate : List Int, List Int → Tree
alternate a b = Node (Node (Node Leaf (List.copy a) Leaf) b Leaf) a Leaf


pub grown : List Int, List Int → Int
grown a b =
    case alternate a b of
        Node l xs _ →
            case l of
                Node _ ys _ →
                    List.length (List.push xs 1) + List.length ys

                Leaf →
                    0

        Leaf →
            0
```

Sources: `docs/design/language.md` §6.8; `docs/design/ownership-checker.md` §16.7, §31.

## Identity

`List.map`, `List.filter` and the other readers return a fresh list, never the one they were given.
A record update keeps the identity of every field it does not name, so a view that compares a list
field by identity sees no change when the list did not change.

Sources: `docs/design/language.md` §6.8; `docs/design/backend.md` §4; `docs/design/ownership-checker.md` §30.

## Kept values and storage writes

A swap changes the list's slots and order. It does not change the values in
those slots. A callback can keep a borrowed element while the containing list
is reordered. The containing list must still be owned for the swap. A callback
that keeps the list itself prevents the swap. A later write to a kept element
requires ownership of that element.

Source: `ownership-checker.md` §16.4 and §32, amendment of 2026-10-22.

## Fold accumulators with shared keys

A fold can update a fresh value list in a table entry that also holds a shared
key. The checker checks each written path. A shared key at tuple field `.0`
does not prevent an update to a separate list at `.1`. If the key and value
are the same list, the update is refused. A later write to a key must also
pass the ownership check.

Source: `ownership-checker.md` §16.4, fold amendment of 2026-10-22.

## Program entry records

Core and platform packages can put `entry` before a written-out callback record
parameter. Other packages cannot use this ownership word. The allowed fields
are `init`, `update`, `settle`, `view`, `subscriptions`, `onUrlRequest`, and
`onUrlChange`. A different field or a record alias causes
`misplaced_ownership_word`.

Every entry record uses the same ownership row on every platform. The
renderer and the list setting do not change the row.

`Browser.hosted` gives the current state to `update` and `settle` with ownership.
It installs each result. It calls `settle` before `view`. A list kept by a view
handler, a command, or a Host callback cannot be written through the state.
The Host argument crosses the runtime boundary; it does not supply an owned
state value.

Source: `ownership-checker.md` §20.2–§20.6, §24.2–§24.4, and §30.3.
