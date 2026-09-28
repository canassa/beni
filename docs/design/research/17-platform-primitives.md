# The platform's primitives, enumerated: are they first-order?

**Status:** research, 2026-09-15. Written to discharge
[`transparent-effects-proposal.md`](../transparent-effects-proposal.md) §10 item 0 and §11 Q8(b),
which say in identical words that **no surface decision should be frozen before this document
exists**. Call that proposal **P2** throughout.

**The question, in P2's own words.** *"For each one: is it first-order, or does it take or return a
function whose bits matter? If all first-order, §3.1's keyword is enough, `sync` stays a declaration
modifier, §8's `sync_boundary` is dropped, and the type grammar is untouched. If even one is
higher-order, the bits belong in the type and §4.1's 'the unifier is unchanged' is withdrawn."*

**Sources.** The repository as it stands on 2026-09-15: every `foreign` in `core/*.beni`,
`core/Dict/*.beni` and `platforms/node/Node.beni`, their sibling JavaScript, `src/check/TypeStore.zig`,
`src/resolve/Interface.zig`, `src/js/JsIr.zig`, `src/js/Sibling.zig`. The vendored `references/elm-core`
read directly — `src/List.elm`, `src/String.elm`, `src/Task.elm`, `src/Process.elm`, `src/Platform.elm`,
`src/Platform/Cmd.elm`, `src/Platform/Sub.elm`, `src/Elm/JsArray.elm` and the kernel files
`Elm/Kernel/List.js`, `Elm/Kernel/String.js`, `Elm/Kernel/Scheduler.js`, `Elm/Kernel/Platform.js`. The
vendored `references/elm` compiler for `compiler/src/Elm/Package.hs` and for the four Elm applications
in `reactor/src/`, which are the only vendored code that *uses* `elm/http`, `elm/browser` and
`elm/html`. **`elm/time`, `elm/http`, `elm/browser`, `elm/html`, `elm/random`, `elm/bytes` and
`elm/file` are not vendored**; §7 says exactly which claims rest on them and are therefore unverified.
Design documents: `boundary.md`, `language.md`, `backend.md`, `checker.md`,
`research/16-fibers-and-concurrency.md`.

---

## 0. The three findings, up front

**1. Two of the 68 foreigns in the repository today are higher-order, and both are removable.**
`core/List.beni:43` and `:49` declare `foldl` and `foldr` as `foreign` over a callback. Elm — the
language this one copies — writes **both of them in Elm** (`references/elm-core/src/List.elm:150`
and `:172`), and beni's own module comment says they are foreign only because "the code generator is
not yet required to turn [a self tail call] into a loop". `src/js/JsIr.zig:137` already reserves the
tag for that loop (`while_true`, *"which M3b fills"*), `backend.md` §8 calls it mandatory, and P2 §7.3
commits to building it. So the surface as it stands forces nothing.

**2. It forces nothing, and it is already wrong.** P2 §2's own headline example —
`List.map ids (\id -> getUser id)` — lowers through `core/List.beni:98`'s `map func xs = foldr … xs`
into `core/List.js`'s `for` loop, which does `out = f(at.a)(out)`. Under P2 §7.1's lowering a
suspending beni function does not block; it **returns a suspension object**. That loop would cons the
suspension object into the output list and return a `List` of them. This is not a hang and not a type
error: it is a well-typed program producing garbage, which is the exact failure class `boundary.md`
§4.1 exists to prevent. The ordering constraint is therefore concrete: **the trampoline lands before
effects do, or the two folds move into beni first, or P2's flagship line miscompiles.**

**3. The projected surface splits in two, and only one half is what P2 §3.1 bet on.** P2's bet is that
*"the foreign surface is the leaves — clock, random, HTTP send, console, timers, DOM reads — and those
are first-order"*. **That half of the bet wins, and wins by more than P2 claims**: direct style plus
suspension turns a whole class of Elm's callback-shaped kernel signatures into first-order pulls
(`Http.expectJson (GotSolution id) decoder` at `references/elm/reactor/src/Deps.elm:443` becomes
`foreign suspends httpSend : Request -> Result HttpError Response`). The other half loses.
Everything the **host** calls back into beni is irreducibly higher-order and its callback's
`suspends` bit is load-bearing — the TEA entry point's `update`/`view`/`subscriptions`, a DOM event
handler, an incoming port's tagger, a `Cmd`'s tagger — and `boundary.md` §5.4 has already committed in
writing to checking exactly that (*"`update` and `view` are `sync`, so neither may perform"*).

§6 states the verdict and prices three branches rather than P2's two.

---

## 1. Reading the question correctly: what "higher-order" means against a JavaScript body

P2 §3.1 asks whether a primitive "takes or returns a function whose bits matter". Before the
enumeration is useful, that has to be sharpened, because against a JavaScript implementation the
answer is not one question but three.

P2 §1's derivation is that **JavaScript cannot suspend a stack**, so a beni function that suspends is
*emitted differently*: P2 §6.1 says a suspending primitive returns "either a value or a suspension",
and P2 §7.1 says a suspending beni function is lowered to closures with join points. A JavaScript
function that calls a beni callback therefore gets back one of two shapes, and whether it copes is a
property of the JavaScript, not of the type.

That gives three kinds of higher-order primitive:

| kind | who calls the callback | what the JavaScript must do | what the type must say |
|---|---|---|---|
| **(i) host-called** | a JavaScript loop, the DOM dispatcher, the VDOM patcher, the runtime's message pump | treat the return as a value | **the callback must not suspend** |
| **(ii) protocol-aware** | the fiber runtime's own JavaScript (P2 §6.1, §6.4) | recognise a suspension and park the fiber | nothing — suspending is the point |
| **(iii) stored, never called from JavaScript** | beni, later | nothing | nothing |

Kind (iii) is the one that looks higher-order and is not a problem: a function inside a data
constructor the host merely carries. Elm's `Random.Generator a = Generator (Seed -> (a, Seed))` is
this shape, and so is any beni-side `Decoder` or `Attribute` whose interpreter is beni.

**Kind (i) is the whole of the question.** Its demand is always in the same direction — `suspends`
must be `false` — because kind (i) exists precisely where JavaScript cannot cope with `true`. It is
never "this callback must suspend" and never a flag *variable*. That is a much smaller thing than P2
§4.1's two-point lattice with variables, and §6 prices it as such.

**Kind (ii) is not free either, but it is not a typing problem.** A protocol-aware primitive has to
accept a thunk that may be emitted in either form, which is P2 §7.6's double-translation question
arriving at the foreign boundary. §7 records it as unsettled.

---

## 2. The current surface, exactly as it is

**68 foreign values and 6 foreign types**, counted on 2026-09-15 across `core/`, `core/Dict/` and
`platforms/node/`. `boundary.md` §4 and §8 say 65 and are **not** stale: 65 is core alone, and the
Node platform's three are the difference. §8's B2 bullet already counts them separately (*"All 65 of
core's foreign values, the Node platform"*). 68 is the repository-wide number and is the one this
document classifies, because a platform's foreigns are exactly what P2 §10 item 0 asks about.

Signatures below are copied verbatim, which means they are still **curried** (`a -> b -> c`) even
though `language.md` §3's grammar now specifies n-ary `A, B -> C` and §5.4's own example is written
n-ary. That gap is P2 §10 item 1 and is not this document's to close; §4's projected signatures are
written n-ary as the brief asks.

### 2.1 The count, by module

| module | values | first-order | higher-order | pure | impure | suspends |
|---|---|---|---|---|---|---|
| `core/Basics.beni` | 35 | 35 | 0 | 35 | 0 | 0 |
| `core/String.beni` | 20 | 20 | 0 | 20 | 0 | 0 |
| `core/Char.beni` | 4 | 4 | 0 | 4 | 0 | 0 |
| `core/Debug.beni` | 3 | 3 | 0 | 2 | 1 | 0 |
| `core/List.beni` | 3 | 1 | **2** | 3 | 0 | 0 |
| `platforms/node/Node.beni` | 3 | 3 | 0 | 3 | 0 | 0 |
| **total** | **68** | **66** | **2** | **67** | **1** | **0** |

`core/Dict.beni`, `core/Dict/String.beni`, `core/Dict/Int.beni`, `core/Set.beni`, `core/Maybe.beni`
and `core/Result.beni` declare no foreigns, and each says so in its module comment.

**Nothing in the repository suspends today.** Not one of the 68 is `suspends` under P2 §3.1's ladder,
which is the honest answer to the second half of P2 §10 item 0 — "it is needed anyway to know how much
of a program gets coloured". Against the current core, the answer is **none of it**.

### 2.2 `core/Basics.beni` — 35 values, all first-order, all `pure`

| signature | order | P2 §3.1 |
|---|---|---|
| `add`, `sub`, `mul`, `pow : number -> number -> number` | first | `pure` |
| `fdiv : Float -> Float -> Float`, `idiv : Int -> Int -> Int` | first | `pure` |
| `eq`, `neq : equatable a -> a -> Bool` | first | `pure` |
| `lt`, `gt`, `le`, `ge : number -> number -> Bool` | first | `pure` |
| `and`, `or : Bool -> Bool -> Bool` | first | `pure` |
| `append : appendable -> appendable -> appendable` | first | `pure` |
| `toFloat : Int -> Float`; `round`, `floor`, `ceiling`, `truncate : Float -> Int` | first | `pure` |
| `modBy`, `remainderBy : Int -> Int -> Int` | first | `pure` |
| `sqrt : Float -> Float`; `logBase, atan2 : Float -> Float -> Float` | first | `pure` |
| `cos`, `sin`, `tan`, `acos`, `asin`, `atan : Float -> Float` | first | `pure` |
| `isNaN`, `isInfinite : Float -> Bool` | first | `pure` |
| `e : Float`, `pi : Float` | first (constants) | `pure` |

`e` and `pi` are the two that are not functions at all, and are the correction `boundary.md` §4
records twice: the shape rule as originally written rejected core, and the enforced rule is "a
function, or a value of a variable-free type". **Neither is higher-order and neither is affected by
anything in this document.**

`and` and `or` deserve a note because they are the one place a first-order signature hides a
non-obvious evaluation property: the module comment says they are foreign because "a beni definition
takes both sides as arguments, so both would be evaluated". Short-circuiting is a *strictness*
property, not an effect bit, and P2's two bits say nothing about it. Under P2 §5's "strict, left to
right, in source order", `a && b` where `b` suspends is a short-circuit whose right operand is a
suspension point that may not be reached. That is a semantics question for P2 §5, not a typing one,
and it is not currently written down anywhere.

### 2.3 `core/String.beni` — 20 values, all first-order, all `pure`

`length : String -> Int`; `slice : Int -> Int -> String -> String`;
`append : String -> String -> String`; `compare : String -> String -> Order`;
`toUpper`, `toLower`, `trim`, `trimLeft`, `trimRight : String -> String`;
`words`, `lines : String -> List String`; `split : String -> String -> List String`;
`indexes : String -> String -> List Int`; `toInt : String -> Maybe Int`;
`fromInt : Int -> String`; `toFloat : String -> Maybe Float`; `fromFloat : Float -> String`;
`fromChar : Char -> String`; `toList : String -> List Char`; `fromList : List Char -> String`.

**This is the most informative row in the whole enumeration**, because Elm's is not the same list.
`references/elm-core/src/String.elm` binds **six higher-order** functions straight to the kernel —
`map : (Char -> Char) -> String -> String` (`:568`), `filter : (Char -> Bool) -> String -> String`
(`:577`), `foldl` (`:586`), `foldr` (`:595`), `any` (`:606`), `all` (`:617`), implemented at
`Elm/Kernel/String.js:37`, `:57`, `:105`, `:190` as JavaScript loops calling `A2(func, …)`. beni
declares none of them foreign: `core/String.beni:365` writes `foldl func acc str = List.foldl func acc (toList str)`
and the other five follow. **beni has already made the choice this document is asking about, five
times over, and in the right direction** — the higher-order function is beni, the foreign under it is
first-order.

### 2.4 `core/Char.beni` — 4 values, all first-order, all `pure`

`toCode : Char -> Int`; `fromCode : Int -> Char`; `toUpper : Char -> Char`; `toLower : Char -> Char`.
Elm has the same four plus `toLocaleUpper`/`toLocaleLower` (`references/elm-core/src/Char.elm:204-257`),
all first-order in both.

### 2.5 `core/Debug.beni` — 3 values, all first-order

| signature | order | P2 §3.1 | note |
|---|---|---|---|
| `log : String -> a -> a` | first | **`impure`** | the only `impure` value in the repository |
| `todo : String -> a` | first | `pure` by the ladder, but it `throw`s | |
| `toString : a -> String` | first | `pure` | reads a value's representation |

`core/Debug.js:35` is the only `console` reference anywhere in `core/` or `platforms/`, confirmed by
grep. `boundary.md` §4 names `log` as "the one deliberate violation" of the two-shape rule, and P2
§3.1's ladder is what finally lets it be *declared* rather than excused: `foreign impure log`.

`todo` is the one value the ladder cannot classify. It is `pure` — it reaches nothing — and it
terminates the program. P2's two bits are `suspends` and `impure`; neither is *totality*, and
`boundary.md` §4.1's fourth rule ("every privileged entry point is wrapped in `try`/`catch`") is a
recipe, not a type. Not a finding against P2, but worth recording: the ladder has three rungs and
`todo` is on none of them.

### 2.6 `core/List.beni` — 3 values, and the two that matter

| signature | order | P2 §3.1 |
|---|---|---|
| `cons : a -> List a -> List a` | first | `pure` |
| `foldl : (a -> b -> b) -> b -> List a -> b` | **higher (kind i)** | `pure` |
| `foldr : (a -> b -> b) -> b -> List a -> b` | **higher (kind i)** | `pure` |

§3 is about these two.

### 2.7 `platforms/node/Node.beni` — 3 values, all first-order, all `pure`

`print : String -> Program`; `printLines : List String -> Program`;
`exitWith : Int -> String -> Program`.

All three are `pure` and that is not a slip. `platforms/node/Node.js` builds `{ code, out }` — plain
data — and `platforms/node/runtime.js` is the only file that touches `process`. This is
`boundary.md` §7.2 working exactly as specified: *"a `foreign` of effect type is pure to evaluate by
construction, and its interpretation happens in the platform"*.

**And it is the first place the enumeration finds an unchecked hole.** `runtime.js` is declared by a
manifest key (`boundary.md` §5: *"`runtime`, the JavaScript file whose `run` export receives `main`'s
value"*), **not by a `foreign` declaration**, so it has no beni type at all. Today that costs nothing,
because a Node `Program` is a record of two scalars. At B4 it costs everything: a browser `Program`
carries `update` and `view`, and `runtime.js` will call them. §5 and §6 return to this.

---

## 3. `List.foldl` and `List.foldr`: what they actually force

### 3.1 The problem stated

A keyword on a declaration cannot express "suspends when its callback does" — P2 §3.1 says so — and
`core/List.js` cannot suspend when its beni callback does:

```js
export const foldl = (f, acc, list) => {
  let out = acc;
  for (let at = list; at.$ === 1; at = at.b) out = f(at.a)(out);
  return out;
};
```

Under P2 §6.1's protocol `f(at.a)(out)` returns *either a value or a suspension*. This loop assigns
whichever it gets to `out`. So a suspending callback does not park the loop and does not fail to
compile; it threads a scheduler object through the accumulator. `foldr` has the same body twice over.

That is kind (i) from §1, and the demand is `sync`.

### 3.2 The blast radius, measured

Because `core/List.beni:100` defines `map func xs = foldr (\x acc -> func x :: acc) [] xs`, the two
foreign folds are the foundation of most of core's higher-order surface. Grepping for uses:

- **`core/List.beni`**: `map`, `filter`, `filterMap` (via `maybeCons`), `reverseAppend` — and
  through them `indexedMap`, `sort`/`sortBy`/`sortWith`'s `reverseAppend`, and anything built on
  `reverse`.
- **`core/String.beni`**: `foldl`, `foldr`, and through them `map`, `filter`, `any`, `all`, `join`
  (`:210` folds with `List.foldl`).
- **`core/Dict.beni`**: `fromList` (`:561`), `merge`'s leftovers pass (`:446`).
- **`core/Set.beni`**: `fromList` (`:105`), and `foldl`/`foldr` via `Dict`'s (which are beni).

Notably **not** affected: `List.sortWith` (`core/List.beni:373`) is a beni merge sort, `List.any`/`all`
(`:186`, `:177`) are direct beni recursion, and `Dict.foldl`/`foldr` (`:473`, `:490`) walk a beni tree.
So the comparator handed to `List.sortWith` is called from beni and needs no constraint — which is the
single cleanest contrast with Elm available, since `Elm/Kernel/List.js:73-87` implements both `sortBy`
and `sortWith` as `Array.prototype.sort` with a JavaScript comparator calling `A2(f, a, b)`. **Elm's
comparator is kind (i); beni's is not, because beni wrote the sort in beni.**

### 3.3 Can they move into beni? Yes, and Elm is the proof

`references/elm-core/src/List.elm:150`:

```elm
foldl : (a -> b -> b) -> b -> List a -> b
foldl func acc list =
  case list of
    [] -> acc
    x :: xs -> foldl func (func x acc) xs
```

That is a self tail call and nothing else. `references/elm-core/src/List.elm:172` gives `foldr` a
recipe too — `foldrHelper` unrolls four elements per frame, carries a depth counter, and at
`ctr > 500` falls back to `foldl fn acc (reverse r4)`, which is exact because
`foldr f acc xs == foldl f acc (reverse xs)` for this argument order. `reverse` is itself
`foldl cons []`. **Elm's kernel contains no fold at all.**

So the two beni foreigns are not a language finding; they are a **backend finding**. What they are
waiting on:

- `backend.md` §8: *"Direct self-recursion lowers to `label: while (true)` with parameters reassigned
  through temporaries. This is mandatory, not an optimisation."*
- `src/js/JsIr.zig:137`: the `while_true` tag exists, documented as *"the tail-call loop of §8, which
  M3b fills"*.
- P2 §7.3: *"A self tail call in a suspendable body becomes a `continue` in the trampoline."*

**Conclusion for P2 §10 item 0's first half: the two higher-order foreigns in the repository do not
force the bits into the type language.** They force an ordering constraint on milestones, stated in
§0 finding 2, and they should be deleted from `core/List.beni` the moment the tail-call loop lands, because leaving
them is a live miscompile the day effects arrive.

### 3.4 Is anything else in the repo this shape?

No. Grepping every `foreign` signature for a parenthesised arrow returns exactly `core/List.beni:43`
and `:49`. The other 66 have no function type anywhere in them, in any position.

---

## 4. The projected surface

What follows is a **proposal**, not a reading: none of these capabilities exists in the repository and
none of these signatures has been compiled. They are written in `language.md` §3's n-ary syntax. The
classification column is P2 §3.1's ladder; the order column is §1's three kinds.

Where Elm has the primitive and the package is vendored, Elm's own signature is cited to a file. Where
the package is **not** vendored (`elm/time`, `elm/http`, `elm/browser`, `elm/html`, `elm/random`,
`elm/bytes`, `elm/file` — their existence confirmed at `references/elm/compiler/src/Elm/Package.hs:208-219`),
the row says so and §7 flags it.

### 4.1 The structural finding first

Elm's callback-shaped signatures exist because **Elm has no way to park a computation**, so every
result comes back through a continuation. beni, after P2, does. That converts an entire class of Elm
kernel signature from higher-order to first-order:

| Elm | beni, after P2 |
|---|---|
| `Task.andThen : (a -> Task x b) -> Task x a -> Task x b` (`Task.elm:209`, kernel) | gone — `let x = f y` |
| `Task.onError : (x -> Task y a) -> Task x a -> Task y a` (`Task.elm:229`, kernel) | gone — `?` and `Result` |
| `Task.attempt : (Result x a -> msg) -> Task x a -> Cmd msg` (`Task.elm:311`) | `Cmd.run : (() -> a), (a -> msg) -> Cmd msg` — still higher-order, see §5 |
| `Http.expectJson : (Result Error a -> msg), Decoder a -> Expect msg` (not vendored; used at `references/elm/reactor/src/Deps.elm:443`) | `foreign suspends httpSend : Request -> Result HttpError Response` — **first-order** |
| `Browser.Dom.focus : String -> Task Error ()` (not vendored; used at `references/elm/reactor/src/Deps.elm:403` as `Dom.blur searchDepsID`) | `foreign suspends focus : String -> Result NotFound ()` — first-order both ways |

**P2 §3.1's bet on the leaves is correct and is understated.** Direct style makes the leaf surface
*more* first-order than Elm's, not merely as first-order.

### 4.2 Time and `Intl` — `boundary.md` §6's first capability

| primitive | order | class | Elm |
|---|---|---|---|
| `foreign impure now : () -> Posix` | first | (—) | `Time.now : Task x Posix`, not vendored |
| `foreign impure here : () -> Zone` | first | (—) | `Time.here : Task x Zone`, not vendored |
| `foreign pure posixToMillis : Posix -> Int` | first | (—) | not vendored |
| `foreign pure millisToPosix : Int -> Posix` | first | (—) | not vendored |
| `foreign pure toParts : Zone, Posix -> Parts` | first | (—) | Elm has `Time.toYear : Zone -> Posix -> Int` and eight siblings; a record is one call instead of nine |
| `foreign pure numberFormat : Locale, NumberOptions -> Result FormatError NumberFormat` | first | (—) | none — Elm has no `Intl` |
| `foreign pure formatNumber : NumberFormat, Float -> String` | first | (—) | none |
| `foreign pure dateTimeFormat : Locale, DateTimeOptions -> Result FormatError DateTimeFormat` | first | (—) | none |
| `foreign pure formatDateTime : DateTimeFormat, Zone, Posix -> String` | first | (—) | none |
| `foreign pure collator : Locale, CollatorOptions -> Result FormatError Collator` | first | (—) | none |
| `foreign pure collate : Collator, String, String -> Order` | first | (—) | none |

**All first-order.** `boundary.md` §6's argument — *"every failure defined by the internationalisation
specification is argument validation, so it moves into smart constructors at zero runtime cost"* — is
what keeps them there. A `Collator` is the interesting case and the one to copy elsewhere: the natural
API is a **comparator function**, which would be kind (iii) at best and force a `List.sortWith` whose
comparator came from JavaScript. Shipping `collate : Collator, String, String -> Order` instead keeps
the value first-order and lets beni's own `sortWith` (§3.2) close over it. **Design rule falling out of
this row: hand out a first-order primitive plus a value, not a function.**

`now` is `impure`, not `suspends`: `Date.now()` returns. P2 §2 uses exactly this example.

### 4.3 Typed arrays and binary data

| primitive | order | class |
|---|---|---|
| `foreign pure byteLength : Bytes -> Int` | first | (—) |
| `foreign pure getUint8 : Bytes, Int -> Maybe Int` (and `getInt16`, `getFloat64`, …) | first | (—) |
| `foreign pure sliceBytes : Bytes, Int, Int -> Bytes` | first | (—) |
| `foreign pure bytesFromList : List Int -> Bytes` | first | (—) |
| `foreign pure encodeUtf8 : String -> Bytes` / `foreign pure decodeUtf8 : Bytes -> Maybe String` | first | (—) |
| `foreign impure allocate : Int -> Bytes` | first | (—) |

**All first-order.** Elm's `elm/bytes` is not vendored; its `Bytes.Decode.Decoder` is a beni-side data
type with `andThen : (a -> Decoder b), Decoder a -> Decoder b`, which under §1's taxonomy is kind
(iii) as long as the *runner* is beni. If a beni `Bytes.Decode.decode` walks the decoder in beni over
first-order accessors, nothing is imposed. If it is a JavaScript walker, every decoder becomes kind
(i). **That is a design choice, not a constraint, and it should be made deliberately.** It is the same
choice §3.2 records beni already making for `String.map`.

### 4.4 `fetch` and streaming

| primitive | order | class |
|---|---|---|
| `foreign suspends httpSend : Request -> Result HttpError Response` | first | (—) |
| `foreign pure requestFrom : Method, Url, List Header, Body -> Request` | first | (—) |
| `foreign pure responseStatus : Response -> Int` / `responseHeaders` / `responseBody` | first | (—) |
| `foreign suspends bodyStream : Response -> Stream` | first | (—) |
| `foreign suspends streamRead : Stream -> Maybe Bytes` | first | (—) |
| `foreign impure streamCancel : Stream -> ()` | first | (—) |

**All first-order, and the streaming row is the one that had to be designed to stay that way.** The
JavaScript shape is push (`ReadableStream`'s reader, or an `ondata` handler); the beni shape is a
**suspending pull**, `streamRead : Stream -> Maybe Bytes`, which is a loop in beni instead of a
callback in JavaScript. A push API — `foreign onChunk : Stream, (Bytes -> ()) -> ()` — would be kind
(i) and would demand `sync` of a handler that obviously wants to suspend (it writes to a file). The
pull shape is available *only because P2 gives the language suspension*, and it is the single largest
ergonomic dividend of the whole proposal that no document currently claims.

`Cmd`-level cancellation of an in-flight `fetch` is `boundary.md` §5.4's business; at the primitive
level it is P2 §6.4's *"a real `AbortController` is minted only at the leaf where a platform primitive
demands one"*, which is internal to `httpSend`'s JavaScript and is not in its beni type.

### 4.5 `localStorage` and structured storage

| primitive | order | class |
|---|---|---|
| `foreign impure localGet : String -> Maybe String` | first | (—) |
| `foreign impure localSet : String, String -> Result QuotaExceeded ()` | first | (—) |
| `foreign impure localRemove : String -> ()` / `localClear : () -> ()` | first | (—) |
| `foreign impure localKeys : () -> List String` | first | (—) |
| `foreign suspends idbGet : Store, Key -> Maybe Value` | first | (—) |
| `foreign suspends idbPut : Store, Key, Value -> Result StorageError ()` | first | (—) |
| `foreign suspends idbOpen : String, Int -> Result StorageError Db` | first | (—) |

**All first-order.** `localStorage` is `impure` and not `suspends` because the Web Storage API is
synchronous — a clean illustration of P2 §2's insistence that the two bits are independent. IndexedDB
is `suspends`. Elm has neither, and `boundary.md` §1 names the reason: *"Also gates `effect module`, so
nobody else can ship a new kind of effect even in pure Elm — which is why `localStorage` has no
package"*.

The IndexedDB upgrade path is the one place a callback is hard to avoid (`onupgradeneeded` runs inside
a browser-controlled transaction). Keeping it first-order means expressing a migration as **data** —
`foreign suspends idbOpen : String, Int, List Migration -> Result StorageError Db` with
`type Migration = CreateStore String | CreateIndex String String | DeleteStore String` — interpreted
by the sibling JavaScript. That is the same "value, not function" rule as §4.2's collator, and it
should be checked against the specification before it is believed.

### 4.6 Web Workers

| primitive | order | class |
|---|---|---|
| `foreign impure workerSpawn : String -> Result SpawnError Worker` | first | (—) |
| `foreign impure workerPost : Worker, Value -> Result CloneError ()` | first | (—) |
| `foreign suspends workerReceive : Worker -> Maybe Value` | first | (—) |
| `foreign impure workerTerminate : Worker -> ()` | first | (—) |

**All first-order, by the same pull-not-push choice as §4.4.** Elm has no equivalent. The honest
caveat is `research/16` §6's last bullet: *"True parallelism is out of scope and was not examined.
`Worker`, `SharedArrayBuffer` and the structured-clone boundary change every row of §5.6 and none of
it was considered; `boundary.md` does not cover them either."* These four signatures are first-order,
and that is the least interesting thing about Workers.

### 4.7 Direct DOM access beyond the virtual DOM

| primitive | order | class |
|---|---|---|
| `foreign suspends focus : String -> Result NotFound ()` | first | (—) |
| `foreign suspends blur : String -> Result NotFound ()` | first | (—) |
| `foreign impure getViewport : () -> Viewport` | first | (—) |
| `foreign impure getElementBox : String -> Result NotFound Box` | first | (—) |
| `foreign impure setViewportOf : String, Float, Float -> Result NotFound ()` | first | (—) |

**All first-order.** Elm's `elm/browser` is not vendored; `references/elm/reactor/src/Deps.elm:403`
shows the call shape (`Task.attempt (\_ -> NoOp) (Dom.blur searchDepsID)`) and confirms that Elm
addresses elements **by id string**, never by handle. beni must do the same for a reason Elm never
wrote down and `boundary.md` §4.1 did: *"Address foreign objects by value; never hold a reference
across an effect boundary."* An `Element` handle that survived a suspension point would be a detached
node, which is precisely the *"well-typed code crashes"* failure `boundary.md` §4.1 was written after.

`focus` is `suspends` rather than `impure` because Elm's is a `Task` that fails on a missing node, and
under P2 there is no `Task`: the failure has to come back as a value, and the platform will want to
run it after the next frame.

### 4.8 Timers

| primitive | order | class | Elm |
|---|---|---|---|
| `foreign suspends sleep : Int -> ()` | first | (—) | `Process.sleep : Float -> Task x ()` (`references/elm-core/src/Process.elm:95`, kernel `Elm.Kernel.Process.sleep`) — first-order |
| `Task.timeout : Int, (() -> a) -> Maybe a` | **higher** | **(ii)** | none — P2 §6.5, `research/16` §5.3 row 7 |
| `foreign impure nextFrame : () -> ()` (i.e. `requestAnimationFrame`) | first | (—) | none in core |

`sleep` is first-order in both languages. `Task.timeout` and every other row of P2 §6.5 is kind (ii)
— see §5.3.

A recurring timer is the interesting row. Elm's is `Time.every : Float -> (Posix -> msg) -> Sub msg`
(not vendored), which is kind (i): the runtime calls the tagger. Under P2 a recurring timer in
non-TEA code is an ordinary beni loop over `sleep`, so the subscription form is needed **only for The
Elm Architecture** — and there it is one of §5's imposed signatures, not a primitive.

### 4.9 Random

| primitive | order | class | Elm |
|---|---|---|---|
| `foreign impure randomSeed : () -> Int` | first | (—) | `Random.independentSeed : Generator Seed`, not vendored |
| `foreign impure randomBytes : Int -> Bytes` (`crypto.getRandomValues`) | first | (—) | none |
| `foreign pure nextInt : Seed -> (Int, Seed)` | first | (—) | P2 §3.1 writes this one as `foreign impure random : Seed -> (Int, Seed)` |

**All first-order.** Elm's `Random.Generator a = Generator (Seed -> (a, Seed))` wraps a function in a
data constructor, which is §1's kind (iii): pure beni, never handed to JavaScript. A generator
combinator library over that type needs no foreign at all beyond the seed source.

One correction to P2 §3.1's own example, worth making because P2 uses it to motivate the second bit:
a **seeded** step `nextInt : Seed -> (Int, Seed)` is `pure`, not `impure` — it is a hash. What is
`impure` is obtaining the first `Seed`. P2 §2's argument ("a random number generator is `impure` and
not `suspends`") survives, but it is about the *seed source*, and if the example stays as written a
reader will conclude that a deterministic PRNG step cannot be memoised.

### 4.10 Console

| primitive | order | class |
|---|---|---|
| `foreign impure log : String, a -> a` (exists, `core/Debug.beni:14`) | first | (—) |
| `foreign impure consoleWrite : Level, String -> ()` | first | (—) |

**All first-order.** This is P2 §2's saturation example — *"in a banking application everything logs,
so a single purity bit is set everywhere and carries no information"* — and the enumeration confirms
that `impure` is cheap to set and `suspends` stays clear.

### 4.11 The DOM event surface

**This is the row that decides the document, together with §5.2.**

| primitive | order | class |
|---|---|---|
| `on : String, (Event -> msg) -> Attribute msg` | **higher** | **(i)** |
| `onWithOptions : String, (Event -> Handling msg) -> Attribute msg` | **higher** | **(i)** |
| `foreign pure eventTargetValue : Event -> Maybe String` (and siblings) | first | (—) |
| `Html.map : (a -> msg), Html a -> Html msg` | **higher** | **(i)** |

Elm's is `Html.Events.on : String -> Decode.Decoder msg -> Attribute msg`, with
`Html.Events.custom : String -> Decoder { message : msg, stopPropagation : Bool, preventDefault : Bool } -> Attribute msg`
— neither vendored; used at `references/elm/reactor/src/Deps.elm:540` (`onClick msg`) and `:894`
(`onInput SChanged`). Elm routes the handler through a `Decoder` rather than a function, which moves
the user's code one step further from the dispatcher but does not remove the demand: *something* beni
runs, synchronously, inside the browser's event dispatch, and the VDOM patcher is the JavaScript that
runs it.

**The demand here is not a convention and cannot be relaxed.** `preventDefault()` and
`stopPropagation()` are effective only during synchronous dispatch; a handler that suspends and
resumes on a later turn has already lost the ability to cancel the event. So a suspending event
handler is not merely a performance problem or a crash — it is a **silent behavioural bug**, the form
of an anchor navigating anyway or a form submitting anyway, with nothing in the emitted code to point
at. `boundary.md` §4.1's `try`/`catch` recipe cannot see it. This is the strongest single argument in
the document for `sync` existing in an argument position.

### 4.12 Ports

`boundary.md` §3.1 and §8's B3. The compiler generates both sides from the declared type, so these are
signatures the **compiler imposes**, not ones a platform author writes.

| shape | order | class |
|---|---|---|
| outgoing `port send : a -> Cmd msg` | first | (—) |
| incoming, Elm's shape: `port receive : (a -> msg) -> Sub msg` | **higher** | **(i)** |
| incoming, direct-style alternative: `foreign suspends portReceive : Port a -> a` | first | (—) |

Elm's incoming port is kind (i) by construction, and the mechanism is visible in the vendored kernel:
`_Platform_incomingPort` (`references/elm-core/src/Elm/Kernel/Platform.js:418`) registers a
`subscribe(callback)` (`:390`) and the host calls `currentSubs[i](value)` (`:382`) from whatever
JavaScript context sent the message.

The direct-style alternative is worth naming because P2 makes it possible for the first time: an
incoming port as a **suspending pull** is first-order, and a beni loop reading it is an ordinary beni
loop. It does not replace the subscription form inside TEA — `update` is still where a `Msg` has to
arrive — but it makes non-TEA programs (the Node platform, a worker) able to use ports without any
kind (i) surface at all. Nothing has designed it; it is a consequence of the enumeration.

### 4.13 Subscriptions

`boundary.md` §5.4 says outright: *"subscriptions are not designed here — `Sub msg` is named in §4 as
an admitted `foreign` shape and nothing more, and a good deal of real cancellation lives in them."*
What the enumeration can say is the shape of the demand, which is uniform:

| shape | order | class |
|---|---|---|
| `Time.every : Int, (Posix -> msg) -> Sub msg` | **higher** | **(i)** |
| `Browser.Events.onKeyDown : (Key -> msg) -> Sub msg` | **higher** | **(i)** |
| `Sub.map : (a -> msg), Sub a -> Sub msg` | **higher** | **(i)** |
| `Sub.batch : List (Sub msg) -> Sub msg` | first | (—) |

Elm's `Platform.Sub.map : (a -> msg) -> Sub a -> Sub msg` and `batch : List (Sub msg) -> Sub msg` are
both kernel (`references/elm-core/src/Platform/Sub.elm:67`, `:84` →
`Elm.Kernel.Platform.map`/`batch`, `Elm/Kernel/Platform.js:198`, `:189`), and `Platform.Cmd`'s are the
same two functions (`references/elm-core/src/Platform/Cmd.elm:68`, `:85`). **Whether beni's are
foreign at all depends on whether a `Cmd`/`Sub` bag is beni data or a host structure, and that has
not been decided.** If the bag is beni data, `map` and `batch` are beni and the taggers inside it
become kind (i) only where the runtime finally applies them — which is one place instead of many.

**Every subscription handler is kind (i)**, for the same reason as §4.11: the runtime's message pump
is JavaScript and it wants a `msg` back now.

### 4.14 Summary of the projected surface

| group | primitives | first-order | higher-order kind (i) | higher-order kind (ii) |
|---|---|---|---|---|
| time and `Intl` (§4.2) | 11 | 11 | 0 | 0 |
| binary (§4.3) | 6 | 6 | 0 | 0 |
| `fetch` and streaming (§4.4) | 6 | 6 | 0 | 0 |
| storage (§4.5) | 7 | 7 | 0 | 0 |
| workers (§4.6) | 4 | 4 | 0 | 0 |
| direct DOM (§4.7) | 5 | 5 | 0 | 0 |
| timers (§4.8) | 2 | 2 | 0 | 0 |
| random (§4.9) | 3 | 3 | 0 | 0 |
| console (§4.10) | 2 | 2 | 0 | 0 |
| DOM events (§4.11) | 4 | 2 | **2** | 0 |
| ports (§4.12) | 2 | 1 | **1** | 0 |
| subscriptions (§4.13) | 4 | 1 | **3** | 0 |
| concurrency (P2 §6.5) | 15 | 4 | 0 | **11** |
| **total** | **71** | **54** | **6** | **11** |

**54 of 71 are first-order. All six kind (i) primitives are in the browser platform**, and all eleven
kind (ii) are the fiber runtime. `Task.timeout` appears in §4.8's table as well but is counted once,
under concurrency.

---

## 5. The imposed signatures

Separately from the primitives: every place a platform **demands something of a function it
receives**. This is what P2 §3.2's `sync` and P2 §8's `sync_boundary` turn on, and what `research/16`
§5.3 row 4 calls a *"live amendment to P2"*.

### 5.1 The table

| # | site | who calls the function | must it constrain the bits? |
|---|---|---|---|
| 1 | `view : model -> Html msg` in the TEA entry record | the VDOM patcher (JavaScript) | **yes — `suspends = false`** |
| 2 | `update : msg, model -> (model, Cmd msg)` | the runtime's message pump | **yes** |
| 3 | `subscriptions : model -> Sub msg` | the runtime, after each update | **yes** |
| 4 | `init : flags -> (model, Cmd msg)` | the runtime, once at startup | **yes**, though it is the one that could be relaxed |
| 5 | a DOM event handler / `Html.Events` decoder (§4.11) | the browser's dispatcher through the patcher | **yes, and hardest** — `preventDefault` needs synchrony |
| 6 | `Html.map`'s and `Sub.map`'s tagger | the patcher / the pump, at dispatch | **yes** |
| 7 | an incoming port's `(a -> msg)` tagger (§4.12) | `_Platform_incomingPort`'s equivalent | **yes** |
| 8 | `Cmd.run : (() -> a), (a -> msg) -> Cmd msg` — the **thunk** | the fiber runtime | **no** — kind (ii), suspending is the point |
| 9 | `Cmd.run`/`Cmd.keyed` — the **tagger** `(a -> msg)` | the runtime, on completion, before dispatch | **yes** |
| 10 | a comparator handed to `List.sortWith` | **beni** (`core/List.beni:373`) | **no** — see §3.2 |
| 11 | a comparator handed to `Dict.empty`/`Set.empty` | beni (`core/Dict.beni:51`) | **no** |
| 12 | a decoder handed into a JSON/bytes walk | beni if the walker is beni; **JavaScript if not** | **depends, and it is a choice — §4.3** |
| 13 | `Task.bracket`'s release `(r -> ())` | the fiber runtime, uninterruptibly | **no under P2 §6.3** — see §5.3 |
| 14 | `Task.spawn`, `Task.race`, `Task.parAll`, `Semaphore.with`, … (P2 §6.5) | the fiber runtime | **no** — kind (ii) |
| 15 | `Task.scope`'s `(Scope -> a)` | the fiber runtime | **no** |

### 5.2 Rows 1–4: the entry point, and why it cannot be hidden

Elm's is the vendored record (`references/elm-core/src/Platform.elm:64-68`):

```elm
worker
  : { init : flags -> ( model, Cmd msg )
    , update : msg -> model -> ( model, Cmd msg )
    , subscriptions : model -> Sub msg
    }
  -> Program flags model msg
```

and it is bound to `Elm.Kernel.Platform.worker`. So **Elm's own entry point is a higher-order kernel
primitive taking a record of three functions**, and `Browser.element`/`Browser.document` (used at
`references/elm/reactor/src/Deps.elm:26` and three other files in `reactor/src/`) add `view` to it.

`boundary.md` §5.4 has already decided what beni demands of them: *"`update` and `view` are `sync`, so
neither may perform, and everything a program performs lives in a thunk handed to the runtime."* That
sentence is a commitment to a check that P2 §3.2, as drafted, **cannot express** — it is an
argument-position requirement, and P2 §3.2 says in terms that a declaration modifier cannot reach one.

There is one escape and it does not work. A platform could make `Program` an ordinary beni opaque
type rather than a `foreign type`, so that the TEA entry point is an ordinary beni function
assembling a record, and no `foreign` is higher-order. **The demand does not go away; it relocates to
`runtime.js`**, which `boundary.md` §5 declares by a manifest key and which has no beni type at all
(§2.7). The check moves from a place where it could be written to a place where it cannot. That is
Branch C in §6, and the honest description of it is that it makes the hole *visible in one file*
rather than *closed*.

And the consequence of not checking is not a hang. Under P2 §7.1 a suspending `view` returns a
**suspension object** instead of `Html`; the patcher diffs it against the previous tree and either
throws inside the host's own code or renders nothing. That is `boundary.md` §4.1's opening complaint —
*"Well-typed code crashes"* — reproduced in the platform beni ships, by beni's own compiler, from
source that type-checks.

### 5.3 Row 13: the one demand the 2026-09-15 decision retired

`research/16` §5.3 row 4 types `bracket` as `Task.bracket : (() -> r), sync (r -> ()), (r -> a) -> a`
and calls `sync` *"load-bearing"* — a release that can suspend can delay a cancellation without bound.
That is stated **under shape N** (native `async`). P2 §6.3 records the reversal: under the fiber
lowering, *"`Task.bracket` pushes its release onto the fiber's `finalizers` and sets an
uninterruptible flag… the runtime removes `bracket`'s demand for a non-suspending argument entirely"*.

**So the enumeration confirms P2 §6.3's claim and confirms its scope.** Every one of P2 §6.5's fifteen
concurrency primitives is kind (ii) and none of them constrains a bit. P2 §6.3 says so itself: *"The
other argument-position demands — `view`, a comparator, a decoder — are not retired by this and remain
§3.2's open case. They are also the only thing that could force the bits into the type language."*
This document's answer to that sentence is: **`view` is not retired, and a comparator and a decoder
are — by beni's own library, not by the runtime.**

### 5.4 Rows 10–12: what beni already did right, and the rule it implies

`core/List.beni:373`'s `sortWith` is a beni merge sort. `core/Dict.beni:51`'s `empty` takes a
comparator that only ever runs in `core/Dict.beni`'s own tree walk. `core/String.beni:365`'s `foldl`
is beni over `List.foldl`. Against Elm, where all three of the corresponding functions are kernel
(`Elm/Kernel/List.js:80`, `:73`; `Elm/Kernel/String.js:105`), beni has already removed three kind (i)
sites.

The rule that falls out and is worth writing into `boundary.md` §4.1's recipe:

> **A function-typed parameter belongs on a beni declaration, not on a `foreign` one.** Where a
> capability is naturally higher-order, the foreign is the first-order operation and the higher-order
> wrapper is beni: a `Collator` value plus `collate`, not a comparator; a suspending `streamRead`,
> not an `onChunk`; a migration list, not an `onupgradeneeded`.

Applying that rule mechanically to §4 removes every kind (i) primitive **except** §4.11's event
handlers and §4.13's subscription taggers, because in both of those the caller is the host and there
is no beni in between. That residue is the answer to P2 §10 item 0.

---

## 6. The verdict, and what each branch costs

### 6.1 The answer

**No, they are not all first-order — and the two halves of P2 §3.1's bet come apart.**

1. **Of the 68 foreigns today, 66 are first-order and 2 are higher-order** (`List.foldl`, `List.foldr`).
   Both are removable, Elm writes both in Elm, and what they are waiting on is `src/js/JsIr.zig:137`'s
   `while_true`. They do not force anything into the type language. They do impose an ordering
   constraint, and until it is met P2 §2's headline example miscompiles (§0 finding 2).
2. **The projected leaf surface is first-order and more so than Elm's** (§4.1, §4.14: 54 of 71). P2
   §3.1's *"the foreign surface is the leaves… and those are first-order"* is correct.
3. **Six projected primitives and seven imposed signatures are not leaves**, and every one of them is
   kind (i): a function the **host** calls back into beni synchronously. `boundary.md` §5.4 has
   already promised to check four of them and P2 §3.2 cannot express the check.
4. Therefore: **§3.1's keyword is enough for the bits on a `foreign` declaration** — nothing needs
   `suspends` *inside* a signature, because kind (ii) is the permissive default. **But `sync` needs an
   argument position, and §8's `sync_boundary` is not droppable.** The bit that must enter the type
   language is **one bit, in one direction, on function-typed parameters only.**

That is neither of P2 §10 item 0's two outcomes. It is narrower than "the bits belong in the type" and
wider than "the type grammar is untouched", and it is narrower in a way that matters: **P2 §4.1's "the
unifier is unchanged" survives, and P2 §4.4's covariant `false ⊑ true` in every position is not
forced by anything in this enumeration.**

### 6.2 Branch A — keyword only, `sync` stays a declaration modifier, `sync_boundary` dropped

**What it costs the compiler:** nothing. `TypeStore`, `Interface`, `Solve`, the grammar and the
formatter are all untouched. This is genuinely the cheap branch and the document should not pretend
otherwise.

**What P2 and `boundary.md` would have to withdraw:**

- `boundary.md` §5.4's first sentence — *"`update` and `view` are `sync`, so neither may perform"* —
  becomes a convention with no mechanism. It should be rewritten to say so, because as written it
  reads as a settled check.
- P2 §8's `sync_boundary` row is deleted rather than deferred, and with it the only diagnostic that
  can point at an argument.
- P2 §6.6's *"When `sync` lands, the author writes it on `update` and `view` and the compiler rejects
  the call"* is withdrawn: a declaration modifier on the user's own `view` *does* work (P2 §3.2's
  first position), so this one survives **for the user's roots** and dies for the platform's demand.
  The distinction is worth keeping sharp: under Branch A a conscientious author can protect their own
  `view`, and the platform cannot require it.
- `boundary.md` §4's check 1 should gain a clause, because the shape rule is the only place a
  higher-order foreign could be refused at all.

**What breaks, concretely:** §5.2's failure — a suspending `view` returns a suspension object to the
patcher. §4.11's failure — a suspending event handler silently loses `preventDefault`. §4.13's — a
suspending subscription tagger returns a suspension where the pump expected a `Msg`. These are the
three milestones after the one that shipped (B3 ports, B4 browser), not distant ones.

### 6.3 Branch B — the bit in the type

Costed against the checker as it stands on 2026-09-15.

| what | where | cost |
|---|---|---|
| `Structure.Func` gains `sync: bool` | `src/check/TypeStore.zig:173` — `pub const Func = struct { param: Var, result: Var }` | **free in size.** `Structure`'s largest payload is already 12 bytes (`App{TypeId, Range}`, `Record{Range, Var}`), so `Func` growing from 8 to 12 changes no layout. |
| the interface term | `src/resolve/Interface.zig:157` — `Term` is three columns `{tag: Tag, lhs: u32, rhs: u32}` and `func` uses **both** operand words | **free**, by a second tag. `Tag` is a separate `u8` column with 9 of 256 values used; `func_sync` costs zero words. A *flagged range* would have cost an `extra` indirection per function term; a constant bit does not. |
| the scheme's quantified list | `Interface.Scheme` + `Quantified.words = 2`, and `Term.@"var"`'s `lhs` indexes that list | **untouched**, because a `sync` demand is a constant written by a platform author, not an inferred variable. This is the cost P2 §4.1's flag *variables* would pay and this finding does not. |
| `checker.md` §6.3's *"nothing else may be added to `Kind`"* | `TypeStore.Kind` is three values with a symmetric `meet` (`TypeStore.zig:114`) | **untouched.** `sync` is a property of a function *structure*, not an ad-hoc constraint on a type *variable*. P2 §10 item 2's amendment is not needed for this bit. |
| unification | `unify(Func, Func)` currently compares `param` and `result` and nothing else | **one case, no new solver.** Take `checker.md` §6.4's existing shape: unifying a `sync` function type against a non-`sync` one records an obligation `(must_not_suspend, var, region)` in the per-rank list and discharges it post-solve exactly as `equatable` is discharged. No directional unify, no variance. |
| subtyping | **the checker has none anywhere today** | **not needed for this bit.** P2 §4.4 wants covariant `false ⊑ true` in every covariant position; that needs a directional unify *and* per-type-constructor variance, which `Structure.App = { type, args }` has no column for. That is a separate want. This enumeration does not force it and should not be used to justify it. |
| grammar | `language.md` §3's `Foreign` and `Type` rules | `Type` gains `'sync'? …` in a parameter position, or `Foreign` gains it. §9's formatter rule and `tests/corpus/fmt/ForeignUgly.beni` grow with it — P2 §10 item 6. |
| `boundary.md` §4 | shape (a) | restate as *"a total pure function over admitted types, whose function-typed parameters are `sync`"* — which turns §5.4's promise into a check and makes §4's third build-time check enforce it. |

**What P2 would have to withdraw under Branch B:** less than §10 item 0 predicted.

- P2 §3.1's sub-decision stands: the keyword on the declaration is enough for `suspends`/`impure`.
- P2 §3.2's *"it is not a different type, and a `sync` function unifies with an ordinary one"* is
  **withdrawn**. It is the sentence `research/16` §5.3 row 4 already flagged, and this enumeration
  finds a second, stronger reason for the same amendment.
- P2 §3.2's *"under a declaration modifier only the user can write it, at their own roots, and the
  platform cannot impose it at all"* stays true and becomes the argument *for* the type position.
- P2 §4.1's *"the unifier is unchanged"* becomes *"the unifier gains one case and no new structure"* —
  narrowed, not withdrawn.
- P2 §8's `sync_boundary` becomes implementable, and is the point.
- P2 §10 item 0's own conclusion — *"If even one is higher-order, the bits belong in the type and
  §4.1's 'the unifier is unchanged' is withdrawn"* — is too strong and should be rewritten. One bit in
  one direction on a parameter is not "the bits", and it does not cost the unifier.

### 6.4 Branch C — forbid higher-order foreigns outright

Worth naming because it is the branch that makes §3.1's keyword *provably* enough. Add a fourth
build-time check to `boundary.md` §4: **a `foreign` declaration's type may contain no function type in
any parameter position.** Then every kind (i) demand must be arranged away by §5.4's rule, and
everything left is §4's first-order surface plus kind (ii), which needs no annotation.

**The cost is that it does not close the hole, it moves it.** §5.2's escape is exactly what the check
forces: `Program` becomes an ordinary beni opaque record, the TEA entry point becomes beni, and
`runtime.js` — declared by a manifest key, with no beni type — is what calls `view`. The demand is
then in a file the compiler does not type at all.

Its one real merit: the hole becomes **singular and visible**. There is exactly one untyped surface
per platform, named by the manifest, rather than a demand scattered across every higher-order
`foreign`. If v1 ships without `sync`, Branch C is the shape that makes the gap auditable instead of
diffuse, and it is compatible with adding Branch B later.

### 6.5 Recommendation

The enumeration supports a two-step position, and it is not the same as either P2 §10 item 0 outcome:

1. **Freeze P2 §3.1's keyword now.** Nothing in 71 projected primitives needs `suspends` or `impure`
   inside a signature. `foreign pure | impure | suspends name : Type` is enough, and the ladder is
   right.
2. **Do not freeze P2 §3.2, and do not drop §8's `sync_boundary`.** The residue is small, precisely
   located (six primitives and seven imposed signatures, all in the browser platform and the ports
   layer), and Branch B's price against the checker as it stands is one bool in a union that has room
   for it, one spare enum tag, and one obligation kind in a list that already carries three. That is
   far below what P2 §10 item 0 budgeted for it.
3. **Delete `core/List.beni`'s `foldl` and `foldr` when `src/js/JsIr.zig`'s `while_true` lands**, and
   write the ordering constraint into `backend.md` §8 so it is not discovered at B4.

---

## 7. What could not be settled

In the style of `research/16` §6: everything below was reasoned about rather than read, and should be
checked before any of it is used to freeze a decision.

- **§4 is a proposal in its entirety.** No browser platform exists, no capability from `boundary.md`
  §6 has been implemented, and **not one signature in §4 has been compiled**. The counts in §4.14 are
  counts of a design, not of code. §2 is the only section of this document that is a reading.
- **`elm/time`, `elm/http`, `elm/browser`, `elm/html`, `elm/random`, `elm/bytes` and `elm/file` are
  not vendored.** Every Elm signature attributed to them in §4 is from memory. What *is* verified is
  that the packages exist (`references/elm/compiler/src/Elm/Package.hs:208-219`) and the four call
  shapes used in `references/elm/reactor/src/Deps.elm` — `Http.post`/`Http.expectJson` (`:435-443`),
  `Browser.document` with its four-field record (`:26-30`), `Dom.blur` under `Task.attempt` (`:403`),
  `onClick`/`onInput` (`:540`, `:894`). Everything else about those packages — `Time.now`'s type,
  `Time.every`'s type, `Html.Events.custom`'s record, `Random.Generator`'s representation — should be
  re-checked against the real packages. **The verdict does not depend on any of them**: it depends on
  `Platform.elm:64-68`, which is vendored, and on §4.11's `preventDefault` argument, which is not an
  Elm fact.
- **`preventDefault`'s synchrony requirement is stated from the DOM specification as I know it, not
  read.** It is the strongest single argument in §4.11 and it rests on an unread source. If a handler
  can in fact cancel an event after yielding, §4.11 weakens to a performance argument and the residue
  in §6.1 loses one of its two members.
- **Whether a kind (ii) foreign can receive a bit-polymorphic thunk at all.** §1's taxonomy assumes
  the fiber runtime's JavaScript can accept a beni thunk emitted either way. If P2 §7.6's double
  translation produces two *calling conventions* rather than two bodies behind one convention, every
  kind (ii) primitive has to accept both or be told which it got — and P2 §7.6 is explicitly open.
  This is the foreign-boundary form of `research/16` §6's *"How §3.7's race interacts with P2 §7.3's
  double translation"*, which that report also left open.
- **The cost of a beni `foldl` was not measured.** §3.3's conclusion — the two foreigns are removable
  — assumes the trampoline makes a beni fold acceptably fast. `backend.md` §8 promises only that
  *direct self-recursion* becomes a loop; a **bit-polymorphic** fold under P2 §7.1's suspendable
  lowering is not the same emitted code, and P2 §7.6 has not decided whether a pure instantiation gets
  its own body. If it does not, every `List.map` in pure code pays Koka's `if (_yielding())` test per
  element, and the case for keeping a JavaScript fold reopens — on performance grounds, with the §0
  finding 2 miscompile still standing against it.
- **Whether `foldr`'s Elm recipe survives CPS.** `references/elm-core/src/List.elm:178-206`'s
  `foldrHelper` unrolls four elements per frame with `fn a (fn b (fn c (fn d res)))` — four **non-tail**
  calls per step. Under a suspendable lowering that is four continuation closures per four elements,
  and the 500-deep counter was tuned for a stack, not for a scheduler. The recipe transfers; the
  constant probably does not.
- **Whether `sync` is checked or inferred.** §5's table assumes *checked*: an argument's already-inferred
  `suspends` flag must be `false` at the demand site. The alternative — the demand propagates backwards
  and *forces* the flag — interacts with P2 §4.3's extraction hazard in a way nothing has worked out,
  and is the difference between "one obligation kind" and "a directional solver".
- **Whether `Cmd` and `Sub` bags are beni data or host structures.** §4.13 and §5.1 row 6 change
  materially depending on the answer. Elm's are kernel (`Elm/Kernel/Platform.js:189`, `:198`); nothing
  requires beni's to be, and `boundary.md` §5.4 explicitly leaves the command type's design to the
  browser package. Until that is decided, the kind (i) count in §4.14 could be three lower or several
  higher.
- **Short-circuiting.** §2.2 notes that `Basics.and`/`or` are foreign *because* they short-circuit,
  and that P2 §5's evaluation-order rule says nothing about a suspension point in a right operand that
  may not be evaluated. Raised, not analysed.
- **`Debug.todo` has no rung on the ladder** (§2.5). Totality is not `impure` and not `suspends`.
  Raised, not analysed.
- **The count is 68 as of 2026-09-15**, from grep over `core/`, `core/Dict/` and `platforms/node/`.
  `boundary.md`'s 65 is core alone and is correct; 68 adds the Node platform's three. If a foreign
  lands between this document and the decision it feeds, the count moves; the classification — 2
  higher-order, both in `List` — is the part that matters and the part to re-check.
- **Nothing in §6.3's cost table was implemented or compiled.** The claim that `Structure.Func`
  growing by a bool is free rests on reading the union's other payloads in `src/check/TypeStore.zig`,
  not on measuring `@sizeOf`. The claim that a second `Term.Tag` is free rests on `Tag` being a
  separate `u8` column in `src/resolve/Interface.zig:148-175`, which it is. Both should be confirmed
  by building before Branch B is budgeted.
