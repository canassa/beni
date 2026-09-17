# C1 — the corpus rewritten for static dispatch

**Status:** plan, 2026-09-17, written as part of slice S0 of
[`static-dispatch-spike.md`](static-dispatch-spike.md). It is executed in **S6**, after `compare`
becomes a well-known method, and its output is the **C1 corpus** that every measurement in plan §7
compares against C0.

**Normative spec:** [`../docs/design/static-dispatch-spike.md`](../docs/design/static-dispatch-spike.md).
Where a rewritten form below and that document disagree, the document wins.

**Baseline:** `master` at `f466aac`. Every line number below is that tree's.

---

## 0. What C1 is

C1 is the same programs as C0 — `core/`, `bench/corpus/`, `tests/corpus/` — with the comparator
arguments removed and `Dict.String` / `Dict.Int` gone. It is produced **by hand**, not by a script:
plan §7 M4 and M5 compare the two corpora's emitted JavaScript, so a mechanical rewrite that
changed more than the comparators would poison the numbers. Every golden it touches is re-blessed
**and read** before it is committed.

Three rules govern every edit:

| # | Rule |
|---|---|
| 1 | **Nothing changes except ordering and equality.** Argument order, pipelines, `\|>` chains, names and comments stay as they are, except where a comment describes the comparator convention and is now false. |
| 2 | **A user-supplied ordering stays a value.** `List.sortWith` and any user function that takes an ordering (`bench/corpus/DictExtra.beni:144`) keep their function argument: they order by something that is *not* the type's own order, which is exactly what `sortWith` is for. |
| 3 | **Every comment that explains the comparator convention is rewritten**, not deleted, so the corpus keeps documenting the language it is written in. Ten files carry such a comment — seven rewritten, three deleted with their files (§5). |

## 1. Counts, for plan §7 M8

Counted three ways, because the three answer different questions.

| Measure | C0 | C1 | Where |
|---|---|---|---|
| **call sites passing an ordering function as an argument** to a `Dict`/`Set`/`List` builder | **17** | **0** | §2–§4 |
|  of those in `core/` | 7 | 0 | `Dict/String.beni` ×3, `Dict/Int.beni` ×3, `List.beni:370` |
|  of those in `bench/corpus/` | 4 | 0 | `NotesApp:84`, `DictExtra:47,159`, `FormValidation:204` |
|  of those in `tests/corpus/` | 6 | 0 | `run/Dictionaries:14`, `parse/good/DictCache:17`, `parse/good/LongModule:85,90,285,744` |
| **comparators threaded onward** inside core | 4 in `Set.beni` (`empty:36`, `singleton:44`, `fromList:117`, `map:128` — all `pub`; `Set.beni` has no private helper) and 4 private helper chains in `Dict.beni` (`getHelp:85`, `insertHelp:165`, `removeHelp:227`, `removeHelpEQGT:287`) | 0 | §2.2, §2.3 |
| **declarations taking a comparator parameter** | **15** — `Dict` 7 (`:60,69,85,165,227,287,594`), `Set` 4 (`:36,44,117,128`), `List` 3 (`:387,431,436`), `DictExtra` 1 (`:144`) | **4** | the survivors are `List.sortWith:387`, `mergeWith:431`, `mergeWithHelp:436` and `DictExtra.toSortedList:144` — rule 2. `Dict.comparatorOf:469` is not counted: it *returns* a comparator and takes none |
| `Dict.String` / `Dict.Int` import lines | 7 | 0 | §3 |
| `Dict.String` / `Dict.Int` use sites | 16 lines, 17 occurrences (`DictExtra.beni:108` has two) | 0 | §3 |
| core modules deleted | — | 2 | §2.1 |
| modules in the three trees declaring ≥ 2 nominal types | 21 | 21 | §6 |

The headline for report 19 is **17 ordering arguments → 0, and 15 comparator parameters → 4**, where
the four survivors are the ones that were never the tax: they order by something that is not the
type's own order.

---

## 2. `core/`

### 2.1 Deleted

| File | Why |
|---|---|
| `core/Dict/String.beni` (42 lines) | three wrappers that pass `String.compare`; after the rewrite each is exactly the `Dict` function it wrapped |
| `core/Dict/Int.beni` (38 lines) | the same over `compare` |

`build.zig`'s embedded-core file list is generated from the directory, so the deletion needs no
build edit. The `core/Dict/` directory goes with them.

### 2.2 `core/Dict.beni`

| Line | C0 | C1 |
|---|---|---|
| 41 | `= Dict (k, k -> Order) (Tree k v)` | `= Dict (Tree k v)` |
| 60 | `pub empty : (k, k -> Order) -> Dict k v` | `pub empty : Dict k v` |
| 61–62 | `empty cmp =` / `Dict cmp Leaf` | `empty =` / `Dict Leaf` |
| 69 | `pub singleton : k, v, (k, k -> Order) -> Dict k v` | `pub singleton : k, v -> Dict k v` |
| 70–71 | `singleton key value cmp =` / `Dict cmp (Node Black key value Leaf Leaf)` | `singleton key value =` / `Dict (Node Black key value Leaf Leaf)` |
| 80 | `pub get : Dict k v, k -> Maybe v` | `… where k.compare : k, k -> Order` |
| 81–82 | `get (Dict cmp tree) targetKey =` / `getHelp tree targetKey cmp` | `get (Dict tree) targetKey =` / `getHelp tree targetKey` |
| 85–100 | `getHelp : Tree k v, k, (k, k -> Order) -> Maybe v`; `case cmp targetKey key of`; three recursive calls passing `cmp` | drop the parameter; `case targetKey.compare key of`; drop the argument |
| 106 | `pub member : Dict k v, k -> Bool` | `… where k.compare : k, k -> Order` |
| 149–151 | `pub insert : Dict k v, k, v -> Dict k v`; `insert (Dict cmp tree) key value =`; `Dict cmp (blacken (insertHelp tree key value cmp))` | `… where k.compare : k, k -> Order`; `insert (Dict tree) key value =`; `Dict (blacken (insertHelp tree key value))` |
| 165–182 | `insertHelp : Tree k v, k, v, (k, k -> Order) -> Tree k v`; `case cmp key nKey of`; two recursive calls | drop the parameter; `case key.compare nKey of`; drop the argument |
| 219–221 | `pub remove`; `remove (Dict cmp tree) key =`; `Dict cmp (blacken (removeHelp tree key cmp))` | `… where k.compare : k, k -> Order`; `remove (Dict tree) key =`; `Dict (blacken (removeHelp tree key))` |
| 227–262 | `removeHelp : Tree k v, k, (k, k -> Order) -> Tree k v`; `case cmp targetKey key of`; four recursive calls incl. the bare `cmp` argument on line 262 | drop the parameter; `case targetKey.compare key of`; drop every argument |
| 287–301 | `removeHelpEQGT` — the same shape | the same treatment |
| 393 | `pub update : Dict k v, k, (Maybe v -> Maybe v) -> Dict k v` | `… where k.compare : k, k -> Order` |
| 406, 412, 419 | `pub union`, `pub intersect`, `pub diff` | each `… where k.compare : k, k -> Order` |
| 434–441 | `pub merge : …` | `… where k.compare : k, k -> Order` (it reads the comparator out of the dictionary today) |
| 444–453 | `cmp =` / `comparatorOf leftDict`; `case cmp lKey rKey of` | delete the `let` binding; `case lKey.compare rKey of` |
| 469–471 | `comparatorOf : Dict k v -> k, k -> Order` and its body | **deleted** |
| 478–480 | `pub map`; `map (Dict cmp tree) func =`; `Dict cmp (mapTree tree func)` | annotation unchanged (no comparison); `map (Dict tree) func =`; `Dict (mapTree tree func)` |
| 534–538 | `pub filter`; `filter (Dict cmp tree) isGood =`; `(Dict cmp Leaf)` | `… where k.compare : k, k -> Order`; `filter (Dict tree) isGood =`; `empty` |
| 552–561 | `pub partition`; `partition (Dict cmp tree) isGood =`; `( Dict cmp Leaf, Dict cmp Leaf )` | `… where k.compare : k, k -> Order`; `partition (Dict tree) isGood =`; `( empty, empty )` |
| 594–596 | `pub fromList : List ( k, v ), (k, k -> Order) -> Dict k v`; `fromList assocs cmp =`; `List.foldl assocs (empty cmp) …` | `pub fromList : List ( k, v ) -> Dict k v where k.compare : k, k -> Order`; `fromList assocs =`; `List.foldl assocs empty …` |
| 1–32 (module doc) | eleven lines explaining that the ordering is an argument, plus the `Dict.String`/`Dict.Int` paragraph at 24–25 | rewritten: the ordering is the key type's `compare` method, `where` clauses say so, and the two sugar modules are gone |

### 2.3 `core/Set.beni`

| Line | C0 | C1 |
|---|---|---|
| 36–38 | `pub empty : (t, t -> Order) -> Set t`; `empty cmp =`; `Set (Dict.empty cmp)` | `pub empty : Set t`; `empty =`; `Set Dict.empty` |
| 44–46 | `pub singleton : t, (t, t -> Order) -> Set t`; `singleton value cmp =`; `Set (Dict.singleton value () cmp)` | `pub singleton : t -> Set t`; `singleton value =`; `Set (Dict.singleton value ())` |
| 52, 60, 76 | `pub insert`, `pub remove`, `pub member` | each `… where t.compare : t, t -> Order` |
| 89, 95, 102 | `pub union`, `pub intersect`, `pub diff` | each `… where t.compare : t, t -> Order` |
| 117–119 | `pub fromList : List t, (t, t -> Order) -> Set t`; `fromList list cmp =`; `List.foldl list (empty cmp) …` | `pub fromList : List t -> Set t where t.compare : t, t -> Order`; `fromList list =`; `List.foldl list empty …` |
| 128–130 | `pub map : Set a, (b, b -> Order), (a -> b) -> Set b`; `map set cmp func =`; `fromList (List.map (toList set) func) cmp` | `pub map : Set a, (a -> b) -> Set b where b.compare : b, b -> Order`; `map set func =`; `fromList (List.map (toList set) func)` |
| 152, 161 | `pub filter`, `pub partition` | each `… where t.compare : t, t -> Order` |
| 1–21 (module doc) | the comparator-as-argument explanation, and the `map` sentence about "the ordering comes first and the callback stays last" | rewritten; the `map` sentence goes, since `map` now has one function argument |

### 2.4 `core/List.beni`

| Line | C0 | C1 |
|---|---|---|
| 182 | `pub member : List (equatable a), a -> Bool` | `pub member : List a, a -> Bool where a.eq : a, a -> Bool` |
| 368–370 | `pub sort : List number -> List number`; `sort xs =`; `sortWith xs compare` | `pub sort : List a -> List a where a.compare : a, a -> Order`; `sort xs =`; `sortWith xs (\x y -> x.compare y)` |
| 376–378 | `pub sortBy : List a, (a -> number) -> List a`; `sortBy xs toKey =`; `sortWith xs (\x y -> compare (toKey x) (toKey y))` | `pub sortBy : List a, (a -> b) -> List a where b.compare : b, b -> Order`; body `sortWith xs (\x y -> (toKey x).compare (toKey y))` |
| 387, 431, 436 | `pub sortWith`, `mergeWith`, `mergeWithHelp` | **unchanged** — rule 2 |
| new | — | `pub foreign eq : List a, List a -> Bool where a.eq : a, a -> Bool` and `pub foreign compare : List a, List a -> Order where a.compare : a, a -> Order`, with the doc block the other foreigns have |
| 16–33 (module doc) | "Three declarations here are `foreign`"; the three-flavour sort paragraph | "Five declarations here are `foreign`"; the sort paragraph becomes `sort` for anything with a `compare`, `sortBy` for a key, `sortWith` for an ordering you write |

`core/List.js` gains the two exports of `static-dispatch-spike.md` §9.5, verbatim.

### 2.5 `core/Basics.beni`, `core/String.beni`, `core/Char.beni`

| Change | Detail |
|---|---|
| `core/Basics.beni:58` | `pub equatable foreign type Char` **moves** to `core/Char.beni`, above its first `pub foreign` |
| `core/Basics.beni:68` | `pub equatable foreign type String` **moves** to `core/String.beni`, above `pub foreign length` |
| `core/Basics.beni:15-17` (module doc) | "`<`, `>`, `<=` and `>=` are numbers only; to order anything else, pass an ordering function, or use `String.compare`" becomes the `compare`-method rule |
| `core/String.beni:11-12` (module doc) | drops the sentence pointing at `Dict.String` and `List.sortWith` |
| `core/Char.beni` | gains `import` nothing; the type declaration is the only addition |
| `core/Debug.beni` | **no source change.** `String` is a prelude type (`language.md` Appendix A), so `log:19`, `todo:28` and `toString:37` keep resolving it with no import line. What moves is the conditional prelude edge (`src/resolve/Graph.zig:266-269`): `Debug`'s edge for `String` now points at module `String` rather than at `Basics` |
| `src/bir/prelude.zig:40-48` | `typeModule`: `.String => .String`, `.Char => .Char`; the other rows and the invariant counts (7/10/9/36) are unchanged |
| `src/js/Lower.zig:1360,1363` and `src/check/Check.zig:1074,1077` | the inline mini-core string literals re-declare `pub equatable foreign type Char` and `… String` inside `Basics`; both must move those two lines into their `String`/`Char` literals, or the in-source tests resolve them to the wrong module |
| `tests/corpus/parse/good/ForeignTypes.beni:8`, `tests/corpus/parse/good/ForeignMixed.beni:10` | the only two corpus fixtures that declare a `foreign type String` / `Char`. They are parse-only fixtures in modules of their own, not mini-cores, so **no change is needed**; they are listed so the S2 sweep does not mistake them for core. The `*/core/` fixture directories (`tests/corpus/bir/core/`, `check/good/core/`, `check/bad/core/`) declare neither type — checked, 2026-09-17 |

---

## 3. `bench/corpus/`

Every one of the six affected modules already has `import Dict exposing (Dict)` and, where it needs
it, `import Set exposing (Set)`, so removing a `Dict.String` / `Dict.Int` import never leaves a
module short of a type.

### 3.1 `bench/corpus/JsonCodecs.beni`

| Line | C0 | C1 |
|---|---|---|
| 6 | `import Dict.String` | **deleted** |
| 159 | `(optionalField "notes" (Decode.dict Decode.string) Dict.String.empty)` | `… Dict.empty)` |
| 313 | `Ok (List.foldl orders Dict.String.empty (\order counts -> bump counts (statusKey order)))` | `… List.foldl orders Dict.empty …` |

### 3.2 `bench/corpus/NotesApp.beni`

| Line | C0 | C1 |
|---|---|---|
| 5 | `import Dict.Int` | **deleted** |
| 6 | `import Dict.String` | **deleted** |
| 63 | `{ notes = Dict.Int.empty` | `{ notes = Dict.empty` |
| 84 | `, tags = Set.empty String.compare` | `, tags = Set.empty` |
| 283 | `\|> List.foldl Dict.String.empty countNote` | `\|> List.foldl Dict.empty countNote` |
| 257, 259, 278 | `compare (rank a) (rank b)`, `compare b.updatedAt a.updatedAt`, `compare n2 n1` | **unchanged** — `Basics.compare` called as a function, still legal (§5.6 of the spec) |
| 280 | `String.compare tag1 tag2` | **unchanged**, same reason |
| 264, 285 | `\|> List.sortWith pinnedFirstThenNewest`, `\|> List.sortWith commonestFirst` | **unchanged** — rule 2 |

### 3.3 `bench/corpus/DictExtra.beni`

The densest file: eight `Dict.String.empty` uses, two `Set.empty String.compare`.

| Line | C0 | C1 |
|---|---|---|
| 8 | `import Dict.String` | **deleted** |
| 28 | `List.foldl items Dict.String.empty step` | `List.foldl items Dict.empty step` |
| 47 | `List.foldl items ( Set.empty String.compare, [] ) step` | `List.foldl items ( Set.empty, [] ) step` |
| 54 | `List.foldl items Dict.String.empty (\item counts -> insertWith counts item 1 (+))` | `… Dict.empty …` |
| 73 | `List.foldl pairs Dict.String.empty (\( k, v ) acc -> insertWith acc k v combine)` | `… Dict.empty …` |
| 83 | `Dict.foldl dict Dict.String.empty (\k v acc -> insertWith acc v [ k ] (++))` | `… Dict.empty …` |
| 89 | `Dict.String.empty` (a `foldl` seed on its own line) | `Dict.empty` |
| 102 | `Dict.foldl dict Dict.String.empty (\k v acc -> Dict.insert acc (f k) v)` | `… Dict.empty …` |
| 108 | `( Dict.String.empty, Dict.String.empty )` | `( Dict.empty, Dict.empty )` |
| 159 | `(Set.empty String.compare)` | `Set.empty` |
| 144 | `pub toSortedList : Dict String v, (v, v -> Order) -> List ( String, v )` | **unchanged** — rule 2: an arbitrary ordering of the *values*, not the key type's own |
| 147 | `\|> List.sortWith (\( _, a ) ( _, b ) -> ordering a b)` | **unchanged** |
| 152 | `toSortedList counts (\a b -> compare b a)` | **unchanged** |

### 3.4 `bench/corpus/PrettyPrinter.beni`

| Line | C0 | C1 |
|---|---|---|
| 6 | `import Dict.String` | **deleted** |
| 261 | `(Dict.String.fromList` | `(Dict.fromList` |
| 267 | `, Object (Dict.String.fromList [ ( "name", String "anon" ), ( "email", Null ) ])` | `… Dict.fromList …` |

### 3.5 `bench/corpus/Router.beni`

| Line | C0 | C1 |
|---|---|---|
| 5 | `import Dict.String` | **deleted** |
| 158 | `\|> Dict.String.fromList` | `\|> Dict.fromList` |

### 3.6 `bench/corpus/FormValidation.beni`

| Line | C0 | C1 |
|---|---|---|
| 6 | `import Dict.String` | **deleted** |
| 204 | `Set.fromList [ "BR", "DE", "FR", "GB", "JP", "US" ] String.compare` | `Set.fromList [ "BR", "DE", "FR", "GB", "JP", "US" ]` |
| 291 | `Dict.String.empty` | `Dict.empty` |
| 295 | `Dict.String.empty` | `Dict.empty` |

### 3.7 Untouched

`bench/corpus/Counter.beni`, `Data/Parser.beni`, `ExprParser.beni`, `Ui/View.beni` contain no
comparator and no pre-bound-module reference. `ExprParser.beni:313` uses `Dict.get env name`, which
gains a constraint on `String` at the call and no source change.

---

## 4. `tests/corpus/`

### 4.1 `run/` — behaviour is visible, so these are the load-bearing rewrites

**`tests/corpus/run/Dictionaries.beni`**

| Line | C0 | C1 |
|---|---|---|
| 1–3 | the comment "`Dict` is written in beni over an explicit comparator, which is what dropping `comparable` costs and buys" | rewritten to say that the key type's `compare` method is what orders it |
| 14 | `Dict.empty String.compare` | `Dict.empty` |
| 7 | `import String` | **kept** — `String.fromInt` and `String.join` are still used |

`.expected` is unchanged: the program prints the same six lines.

**`tests/corpus/run/Sorting.beni`**

| Line | C0 | C1 |
|---|---|---|
| 1–3 | "ordering is an argument: `sort` for numbers, `sortBy` for a numeric key … `String.compare` is the replacement for `"a" < "b"`" | rewritten: `sort` for anything with a `compare`, `sortBy` for a key, `sortWith` for an ordering you write; `"a" < "b"` now works |
| 27 | `names (List.sortBy people (\p -> p.age))` | **unchanged**, and now type-checks through the generalised `sortBy` (spec §5.5) |
| 28 | `names (List.sortWith people (\a b -> String.compare a.name b.name))` | **unchanged** — rule 2 |
| 29 | `names (List.sortWith people (\a b -> compare b.age a.age))` | **unchanged** |
| new | — | one line exercising the new capability: `names (List.sortBy people (\p -> p.name))`, sorting by a `String` key |

`.expected` gains one line for the new case.

**`tests/corpus/run/ListFold.beni:18`** and **`tests/corpus/run/PipeFirst.beni:33`** call
`List.sort [ 3, 1, 2 ]`; both are unchanged and now go through `Int`'s `compare`.

**New fixtures**, all under `run/`, so the emitted JavaScript is executed:

| Fixture | What it proves |
|---|---|
| `run/StringOrdering.beni` | `"a" < "b"`, `"b" >= "a"`, `List.sort` of a `List String`, `Dict String v` with no comparator |
| `run/MethodCalls.beni` | a method call on a type declared in the same module, one on an imported type, one through a `where`-constrained generic, one through three nested generics (evidence forwarding) |
| `run/DerivedEquality.beni` | `==` on a record, a tuple, an ADT with padding, an all-nullary type, a nested `Maybe (List Int)`, `NaN /= NaN`, `() == ()` |
| `run/DerivedOrdering.beni` | `compare` on a record (field-name order), a tuple, an ADT (declaration order), an all-nullary type, `List (List Int)` (shorter is `LT`) |
| `run/DecodeInto.beni` | return-type dispatch, S7, two target types |
| `run/EvidenceCapture.beni` | evidence used inside a nested lambda two levels below the declaration that owns it (spec §6.4, §8.1 — `$m$k` is captured lexically, never forwarded) |
| `check/bad/LetConstrainedTwice.beni` | a `let` binding is not generalised over a constrained variable; a second use at another type is `method_constraint_mismatch` (spec §6.4, A.30) |
| `check/bad/UnknownMethodThroughGeneric/` | the two-span rule: primary at the call that created the obligation, secondary at the constraint's origin (spec §10 preamble, §10.1) |
| `check/bad/MissingWhereCaller/` | same rule for `missing_where_constraint`, primary span on the caller not in the callee (spec §10.4; report 18 §2.4) |

### 4.2 `check/args/`

| File | Action |
|---|---|
| `check/args/DictEmptyMissingComparator.beni` + `.diag` | **deleted**. Its whole point is that `Dict.empty` is a one-argument function; after the rewrite `pub blank : Dict Int String` / `Dict.empty` is correct code |
| new `check/args/SetMapMissingCallback.beni` + `.diag` | replaces it, so the arity suite does not shrink: `Set.map s` with the callback missing |
| `check/args/SortByMissingKey.beni` | **unchanged** — `List.sortBy xs` is still one argument short |
| `check/args/DictInsertMissingValue.beni` | **unchanged** |

### 4.3 `check/` goldens that move for a different reason

`String` and `Char` leaving `Basics` (§2.5) changes `Basics`' and `String`'s and `Char`'s
interfaces, so **every `.iface` golden that includes a core module** is re-blessed, as is every
`--stage=raw` golden. The declaration list moves; no type changes.

### 4.4 `parse/` and `fmt/` — parse-only fixtures

These never reach the checker, so a comparator argument in them is only text. They are rewritten
anyway, because the corpus is documentation (rule 3) and because `LongModule.beni` is the
formatter's biggest input.

| File | Line | C0 | C1 |
|---|---|---|---|
| `parse/good/DictCache.beni` | 17 | `{ hits = 0, misses = 0, table = Dict.empty compare }` | `{ hits = 0, misses = 0, table = Dict.empty }` |
| `parse/good/LongModule.beni` | 85 | `{ cards = Dict.empty compare` | `{ cards = Dict.empty` |
| `parse/good/LongModule.beni` | 90 | `, collapsed = Set.empty String.compare` | `, collapsed = Set.empty` |
| `parse/good/LongModule.beni` | 285 | `\|> Dict.fromList compare` | `\|> Dict.fromList` |
| `parse/good/LongModule.beni` | 744 | `\|> Set.fromList String.compare` | `\|> Set.fromList` |
| `parse/good/LongModule.beni` | 376, 643, 751 | `List.sortBy …` | **unchanged** |
| `parse/good/TypeAtoms.beni` | 20 | `Dict.empty` | **unchanged**, and now correct rather than accidental |
| `parse/good/ImportsAllForms.beni` | 15 | `Set.empty` | **unchanged**, same |
| `parse/bad/UnknownModuleAlias.beni` | 5 | `Dict.empty` with no import | **unchanged** — the diagnostic is about the missing import, not the arity |
| `fmt/AlreadyCanonicalModule.beni` / `.expected` | 19 (both on one line) | `{ items = Dict.empty, selected = Set.empty }` | **unchanged** |
| `parse/good/FunctionTypesNested.beni` | 15 | `, order : Int, Int -> Order` | **unchanged** — a record field of function type, the comma-rule fixture |
| `parse/good/OperatorsAll.beni` | 30 | `asPredicates = [ (==), (/=), (<), (>), (<=), (>=) ]` | **unchanged as text**, but it is the fixture that proves `static-dispatch-spike.md` §3.1's operator-as-function rule (A.22): all six lower to lambdas over `method_call`. Its `.ast` golden is unchanged (lowering is what changes); a **new `bir/OperatorsAsFunctions.beni` + `.bir`** asserts the lowered form, and `run/DerivedEquality.beni` uses `(==)` as a value at least once so the behaviour is executed |
| `bir/ResolvePrelude.beni` | 28, 30 | `ordering : Int, Int -> Order`, `case compare a b of` | **unchanged** |

A **new** `parse/good/WhereClauses.beni` and its `.ast` golden carry every form of §2: one
constraint, several, the comma-lookahead case, a constraint whose type has three parameters, and
`List where` (a type variable named `where`). A new `parse/bad/WhereVariableUnbound.beni` and
`parse/bad/DuplicateWhereConstraint.beni` carry §10.6 and §10.7. A new `fmt/WhereUgly.beni` +
`.expected` carries §2.5's one-line and vertical forms.

### 4.5 Goldens regenerated, with the reason

| Golden | Why it moves |
|---|---|
| `parse/good/DictCache.ast` (24–25) | one `ident compare` argument node disappears |
| `parse/good/LongModule.ast` (137–138, 149–150, 583–584, 2088–2089) | four argument nodes disappear |
| `parse/good/TypeAtoms.ast`, `parse/good/ImportsAllForms.ast` | unchanged in content; re-run to confirm |
| `bir/ResolveExposed.bir` (9, 19) | `import_value Dict.empty` keeps its name; the surrounding call loses an operand |
| `bir/ResolvePrelude.bir` (102, 128) | unchanged; `Basics.compare` is still imported by `case compare a b of` |
| every `check/good/**/*.iface`, every `--stage=raw` golden | `where` clauses appear on the constrained values, and `String`/`Char` move module |
| every `run/*.expected` | unchanged except `Sorting.expected` (§4.1) |
| new `dispatch/` kind | `tests/corpus/dispatch/` is created in S3 with its own goldens (spec §7.3) |

The rule from CLAUDE.md applies to every one of them: a re-blessed golden is **read** before it is
committed, and a `.iface` golden that gained a `where` clause is checked against the annotation
that should have produced it.

---

## 5. The prose that becomes false

Ten files explain the comparator convention in a comment. Every one is rewritten or goes with its
file; none is simply deleted, because the corpus is how the language documents itself.

| File | Lines | What it says now | What it must say |
|---|---|---|---|
| `core/Dict.beni` | 1–32 | "the ordering that arranges them is an argument rather than a constraint"; the `Dict.String`/`Dict.Int` paragraph at 24–25; "with the comparison function threaded through the places Elm used `compare`" | the key type's `compare` method orders the dictionary; a `where` clause on each function says so; the threading is gone |
| `core/Set.beni` | 1–21 | the same, plus "where a function takes both an *ordering* and a *callback*, as `map` does, the ordering comes first" | the same, and `map` now takes one function |
| `core/List.beni` | 16–33 | "Three declarations here are `foreign`"; the three-flavour sort paragraph | five foreigns; `sort` needs only a `compare` method |
| `core/Basics.beni` | 15–17 | "`<`, `>`, `<=` and `>=` are numbers only; to order anything else, pass an ordering function, or use `String.compare`" | the four operators call the type's `compare`; `comparable` is still gone, and this is what replaced it |
| `core/Basics.beni` | 19–31 | the `foreign`-by-`foreign` justification list, which includes `eq`/`neq` | unchanged in substance; a line noting that the operators no longer route through them (spec §3.1) |
| `core/String.beni` | 11–12 | "`String.compare` … is what you hand to `Dict.String` or `List.sortWith`" | `String.compare` is `String`'s `compare` method; it is still callable by name |
| `tests/corpus/run/Dictionaries.beni` | 1–3 | "`Dict` is written in beni over an explicit comparator, which is what dropping `comparable` costs and buys" | the key type's `compare` method |
| `tests/corpus/run/Sorting.beni` | 1–3 | "ordering is an argument … `String.compare` is the replacement for `"a" < "b"`" | `"a" < "b"` works |
| `core/Dict/String.beni` | 1–17 | the whole module doc is about the sugar | deleted with the file |
| `core/Dict/Int.beni` | 1–14 | the same | deleted with the file |
| `tests/corpus/check/args/DictEmptyMissingComparator.beni` | 1–3 | "`Dict.empty` is a function of one argument and not a value" | deleted with the fixture |

`docs/design/checker.md` Appendix B's `Dict`/`Set`/`List` lines also become false, and are **not**
edited: the branch's delta lives in `docs/design/static-dispatch-spike.md` §5, per CLAUDE.md rule 1
and the plan's §0 decision that `fast-compiler.md` §3.1 is not touched on the branch.

---

## 6. M8: modules declaring two or more types

This is the input to plan §7's M8 row and to `static-dispatch-spike.md` §11's "module-rule
namespace clash". A **collision** is two types in one module that both want a method of the same
name; the module's `pub` values are one namespace, so only one of them can have it.

Type aliases are excluded: an alias is transparent (`fast-compiler.md` §3.1) and its methods are
its expansion's, so it never competes for a name. Counting aliases too would add 22 more modules
(§6.3) and none of them is a collision.

### 6.1 The 21 modules, with their verdicts

| Module | Types | `pub` values | Collides **today** | Collides **if written in the style the module rule rewards** |
|---|---|---|---|---|
| `core/Basics.beni` | `Int`, `Float`, `Char`, `String`, `Bool`, `Order`, `Never` (7) | 51 | **yes** — `compare` is one name and seven types want it; `eq` likewise | yes, and worse |
| `core/Dict.beni` | `Dict`, `Tree` (priv), `NColor` (priv) (3) | 22 | latent — all 22 are nominally `Tree`'s and `NColor`'s methods too, but neither private type ever receives a dot-call | yes: a `Tree.insert` and a `Dict.insert` cannot coexist |
| `bench/corpus/ExprParser.beni` | `Token`, `Expr`, `Op` (3) | `tokenize`, `parse`, `eval`, `print`, `calculate` (5) | no | **yes** — `print` on `Expr` and a `print` on `Token` are the natural pair |
| `bench/corpus/JsonCodecs.beni` | `Tier`, `Status` (2) | 19 | no — the names are already disambiguated by hand: `tierDecoder`/`statusDecoder`, `encodeTier`/`encodeStatus` | **yes**, and this is the clearest case in the corpus: the module rule's reward is to call both `decoder` and both `encode`, at which point the two types collide |
| `bench/corpus/NotesApp.beni` | `Status`, `Msg` (2) | `init`, `update`, `visibleNotes`, `allTags`, `view` (5) | no | no — `Msg` owns the API, `Status` is a tag |
| `bench/corpus/PrettyPrinter.beni` | `Doc`, `Mode` (priv), `Value` (3) | 17 | no — `render` takes a `Doc`, `printValue` takes a `Value` | **yes** — `render` is what both want |
| `bench/corpus/Router.beni` | `Route`, `Sort`, `SettingsTab` (3) | 9 | no | **yes** — `toUrl` and `title` are what all three want |
| `tests/corpus/bir/ConstructorsLocalVsExposed.beni` | `Shape`, `Order` (2) | none | no | n/a |
| `tests/corpus/bir/InterfaceSkeleton.beni` | `Color`, `Token` (opaque), `Hidden` (priv) (3) | `annotated`, `bare` (2) | no | n/a |
| `tests/corpus/check/good/core/Foreign.beni` | `Handle`, `Opaque a` (2) | `make`, `same` (2) | no | no |
| `tests/corpus/fmt/AlreadyCanonicalTypes.beni` | `Msg`, `Id` (opaque) (2) | `update` (1) | no | n/a |
| `tests/corpus/fmt/LeadingPipeType.beni` | `Msg`, `Shape` (2) | none | no | n/a |
| `tests/corpus/parse/bad/DuplicateConstructor.beni` | `OptionA`, `OptionB` (2) | none | no | n/a |
| `tests/corpus/parse/good/CustomTypes.beni` | `Unit1`, `Bool2`, `Shape`, `Tree a`, `Either a b`, `Wrapped`, `OneLine`, `LeadingBarOneLine` (8) | none | no | the worst case in the corpus by count, and it is a grammar fixture with no values at all |
| `tests/corpus/parse/good/DocComments.beni` | `Shape`, `Id` (opaque) (2) | `greet` (1) | no | n/a |
| `tests/corpus/parse/good/ForeignTypes.beni` | `List a`, `String`, `Table k v` (3) | none | no | n/a |
| `tests/corpus/parse/good/LongModule.beni` | `Column`, `Editing` (priv), `Msg` (3) | 11 | no | no |
| `tests/corpus/parse/good/PreludeNameReuse.beni` | `Maybe a`, `Order`, `Result` (3) | none | no | n/a |
| `tests/corpus/parse/good/TodoUpdate.beni` | `Visibility`, `Msg` (2) | `update` (1) | no | no |
| `tests/corpus/parse/good/Visibility.beni` | `Color`, `Token` (opaque), `Hidden` (priv) (3) | `greeting`, `answer` (2) | no | n/a |
| `tests/corpus/run/Adt.beni` | `Shape`, `Colour` (2) | none | no | n/a |

### 6.2 The headline for report 19

| | Count |
|---|---|
| modules declaring ≥ 2 nominal types | 21 |
| of those, in `core/` | 2 |
| colliding **today** | **1** (`core/Basics.beni`), plus 1 latent (`core/Dict.beni`, both extra types private) |
| colliding **under the style the module rule rewards** | **6** — `core/Basics.beni`, `core/Dict.beni`, `bench/corpus/ExprParser.beni`, `bench/corpus/JsonCodecs.beni`, `bench/corpus/PrettyPrinter.beni`, `bench/corpus/Router.beni`; none in the fixture-only trees, which have almost no `pub` values |
| fixtures with ≥ 2 types and **no** `pub` values, so the question does not arise | 7 |

The one that actually bites is `core/Basics.beni`, and `static-dispatch-spike.md` §3.2's well-known
table plus §5.1's two type moves are what buy it off. That the workaround was needed in the very
first module of the standard library is itself a finding, and report 19 should say so next to Sky
Rose's objection quoted in [`research/18`](../docs/design/research/18-static-dispatch-revisited.md)
§4.3.

### 6.3 Alias-only modules, listed for completeness

These declare two or more `type alias`es and no second nominal type, so the module rule never
reaches them: `bench/corpus/Counter.beni`, `bench/corpus/Data/Parser.beni`,
`bench/corpus/FormValidation.beni`, `bench/corpus/Ui/View.beni`,
`tests/corpus/check/args/UpdateMissingModel.beni`, `tests/corpus/check/args/ViewMissingModel.beni`,
`tests/corpus/check/bad/RecursiveAlias.beni`, `tests/corpus/check/bad/RecursiveAliasChain.beni`,
`tests/corpus/check/depth/AliasChainOk.beni` (510), `tests/corpus/check/depth/AliasChainDeep.beni`
(511), `tests/corpus/fmt/MissingBlankLines.beni`, `tests/corpus/fmt/TypeDeclUgly.beni`,
`tests/corpus/parse/bad/DuplicateType.beni`, `tests/corpus/parse/bad/DuplicateTypeParameter.beni`,
`tests/corpus/parse/bad/UnboundTypeVariable.beni`,
`tests/corpus/parse/good/ExtensibleRecords.beni`,
`tests/corpus/parse/good/FunctionTypesNested.beni`, `tests/corpus/parse/good/JsonDecoder.beni`,
`tests/corpus/parse/good/RecordTypeCommaRule.beni`, `tests/corpus/parse/good/TypeAliasParams.beni`,
`tests/corpus/run/Patterns.beni`, `tests/corpus/run/Records.beni`.

---

## 7. Order of work, and what proves it

S6 is two sessions. The order matters because the corpus must never be half-rewritten across a
commit (CLAUDE.md rule 4).

| Step | Work | Gate |
|---|---|---|
| 1 | `core/Dict.beni`, `core/Set.beni`, `core/List.beni` signatures and bodies (§2.2–§2.4); `core/List.js` gains `eq` and `compare` | `zig build test` — core must check clean before anything else can |
| 2 | delete `core/Dict/String.beni`, `core/Dict/Int.beni`, and the doc paragraphs that name them (§2.1, §5) | `zig build test` |
| 3 | `bench/corpus/` — the six files of §3, in one commit | `zig build bench -- --generate=1000` runs; `beni build` on each |
| 4 | `tests/corpus/run/` — the two rewrites and the five new fixtures of §4.1 | `zig build test-blackbox`; every `.expected` **read**, not just regenerated |
| 5 | `tests/corpus/check/args/` (§4.2), `parse/`, `fmt/` (§4.4), and every golden of §4.5 | all three gates; the determinism test at `--jobs=1` and `--jobs=8` |
| 6 | the prose of §5 | `zig build fmt-check` |
| 7 | capture the C1 side of M1b, M3, M4, M5 R1–R3 and M8 into `plans/static-dispatch-spike-results.md` | the numbers, interleaved with `master` as `bench/README.md` requires |

**Proving the rewrite.** Each of steps 1–5 is proved the way CLAUDE.md rule 3 requires: the new
`run/` fixtures fail before S5/S6 lands and pass after, shown by stashing the slice. The rewritten
fixtures are different — they must produce **byte-identical** output to C0 apart from
`Sorting.expected`'s new line, which is the assertion that C1 is the same programs and not new
ones. Any `.expected` that moves for a reason other than the new `sortBy` line is a bug in the
rewrite, not a golden to bless.
