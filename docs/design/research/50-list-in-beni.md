# The list runtime in beni: what `core/List.js` needs to move

**Status:** research, 2026-10-02. Not normative. Commissioned as step 3 of
[`plans/core-in-beni.md`](../../../plans/core-in-beni.md): work out what it takes to write
`core/List.js` — the array-backed `List` of [`backend.md`](../backend.md) §4, *Lists are arrays*
(plain arrays, O(1) views, the E1tp trie with a claimable head and tail) — in beni over the `Js`
intrinsics, held to R47-3's bar ([`plans/browser-decisions.md`](../../../plans/browser-decisions.md):
no larger after brotli, no real slowdown, an equivalent shape, measured), and prototype it.

**What was built.** A prototype on the scratch branch `list-in-beni-prototype` (commit `ab729385`,
on `8a33a4e5`, before the Unicode notation; not for merging): all of `core/List.js` rewritten as
beni in `core/List.beni` — the sibling shrinks from 522 lines to 13, the six operations the code
generator already writes in place (`length`, `at`, `put`, `identical`, `kept`, `half`), kept only
for a value of one — plus two new intrinsics and two one-line compiler fixes (§3). The benchmark
scripts are on the branch under `bench/list-in-beni/` (§6). §2 is the per-piece table, §3 the
missing capabilities with proposed spec text, §4 the shape, §5 the measurements, §7 the
decisions. The slice plan is appended to `plans/core-in-beni.md`.

---

## 0. Findings

1. **Every piece of the runtime can be written in beni with the identical emitted shape, given two
   intrinsics `Js` does not have: an object literal whose keys are written as written
   (`Js.object`), and a function that reads `this` (`Js.method`).** Nothing else is missing. No
   class or prototype form is needed — `$plain` is a *field* holding one shared function by the
   contract (`backend.md` §4, *What a reader of a list may rely on*), so a header is an object
   literal — and no getter, no `Js.Ref` field, no integer-typed loop and no way to declare a hidden
   class: one `Js.object` call site is one shape, the cache write is a `Js.set` on a field the
   literal created, the radix arithmetic is `Js.shiftRightZero`/`bitAnd`/`^` written in place, and
   the tail-call loop writes the hand-written `for`/`while` loops (a single-use loop helper is even
   written into its caller as a `while`, as `putLeaf`'s null padding was by hand).
2. **Two defects stand between `List`'s emitter-imported values and a beni body**, both one-line
   fixes in `Lower` (§3.3): `exports` exports a core-private `List` value only when it is `foreign`,
   and the "unobserved result" rule treats a core-private value nothing in its module calls as one
   whose result nobody reads — so `close`, which only emitted code calls, lost its `return` and a
   `run/` program crashed. Both are latent for any core value the emitter calls.
3. **The claims need nothing new.** "Writing in place only when this version owns the array's end"
   is a runtime test (`b.length === c`), not static knowledge, so `Js.call b "push" [ v ]` behind
   that test is the whole claim; `bench/arrays/lists/claim-prepend-test.mjs`'s 3.03 million checks
   on shared old versions pass against the beni-compiled runtime unchanged (§5.1).
4. **Correctness:** with the port, every `run/` program prints its `.expected` in both builds (560 of
   562, the two misses `ReadFileErrors`'s, which miss on master too in this harness), and the
   persistence sweep holds (§5.1).
5. **Speed: parity, but for `compare`.** Steady-state wall time on a quiet core, 7–9 processes per
   side: every operation within noise (0.95–1.05×, ranges overlapping) but `List.compare`, **1.16–
   1.19× slower at 100, 1 000 and 10 000 elements, reproducibly**. The cause is found and is not the
   runtime's: the tail-call loop prints its exit as `for(;;){if(!(k<n&&k<m))return …;…}`, and the
   same function written `for(;k<n&&k<m;k++){…}return …` is at parity, with everything else the same
   (§5.3). That is a code-generation finding for every beni loop of that shape, not a reason to keep
   `compare` in JavaScript.
6. **Size: smaller in total, larger for some programs.** `bench/size.mjs`, release brotli over the
   363 programs and pages: **431 969 → 430 561 (−0.33 %)**, 112 programs smaller, **44 larger by
   1–83 bytes** (`run/NestingFlatList` +83, `SuspendListBuildDeep` +58, `SpecializeFacts` +56,
   `NestingEvidence` +52), the pages −2 / +28 / +11 (`element`, `effects`, `random`). Development
   output 2 150 270 → 1 308 298 brotli (−39 %), `core/List.js` no longer copied whole into every
   development build. R47-3 counts per program, so the bar is **not** met as built (§5.4).
7. **A test budget is the wall to landing it** (rule 10): `abuse_wide_test`'s *16 400 literal
   branches … under `--release`* measures 4 771 million instructions against the 4 300 budget with
   the beni `List` — most likely (not profiled) the release passes working through `List`'s runtime in every program that
   reaches it. The rest of the red gates are goldens a slice re-blesses (§5.5). Nothing of the
   prototype is landed.

---

## 1. Method

The port was done twice. First **tier 1**, with today's compiler and `--core-root`: the pieces
that need nothing new (`eq`, `compare`, `slice`, `insertAt`, `removeAt`, `swap`, `concat`). Then
the **whole runtime**, after adding `Js.object` and fixing `Lower.exports` (prototype 1, the two
`$plain` methods still in the sibling as values), and then `Js.method` (prototype 2, the sibling
down to the in-place operations). Every figure below is prototype 2 against master at `8a33a4e5`
unless it says otherwise, each side built by its own compiler from its own core.

Measured four ways, each run under five minutes:

- **Correctness**: every single-file `tests/corpus/run/` program built and run in both builds
  against its `.expected`; `claim-prepend-test.mjs` against a development build of the beni core
  through an adapter (`bench/list-in-beni/core-compiled.mjs`).
- **Speed**: `bench/list-in-beni/LB2.beni`, one exported function per operation on each form (plain,
  view, a trie built by `push`, a trie built by prepending), built `--library --release`. Each
  side runs in **processes of its own, alternating** (`steady.mjs` under `alt.mjs`: one workload per
  process, 300 ms warm-up, then the median of six 100 ms samples; the figure is the median over the
  processes, the range beside it) — bench/primitives' lesson that two builds in one process measure
  by load order. Node 24.19, Ryzen 9 5950X, `taskset -c 20`. The machine was shared with other
  agents: early runs at load 20–50 had ranges of 10× and are not quoted; the tables are from runs
  at load 2.6–3.2 unless marked.
- **Instructions**: the same workloads counted with `perf_event_open` (`icount.c`), `(I(k) − I(0)) /
  k` per call under `node --single-threaded`. Quoted only where it agrees with wall time: at the
  default k it counted the beni build's extra compile work as per-call cost (+4–20 % that fell to
  +2–3 % at 40× the iterations), which wall time on a quiet core did not see.
- **Size**: `bench/size.mjs` with a `--core-root` pass-through, release brotli per program and page.

**Research 46's harness was not run.** `bench/arrays/all.mjs` builds, but its `bench` step fails at
master in bundling: the `first` program imports `List$base`, `List$offset` and `List$view`, which
the array-first test core it is built against does not export. The `beni` candidate's scenarios are
covered here by `LB2`'s per-form operations; repairing the harness is its own task.

---

## 2. The per-piece table

"Today" is `core/Js.beni` at `8a33a4e5`. "Shape" compares the prototype's release output with
`core/List.js` as `Minify` leaves it.

| Piece of `List.js` | Expressible today? | What was missing | Shape in the prototype |
|---|---|---|---|
| **Trie header** `{length, h, hc, T, t, p, $plain}`, **view** `{b, o, length, p, $plain}`, **tree** `{r, s, off, tc}`, `NoTree` | **No.** A beni record's keys are sorted and renamed under `--release`, `$plain` is not a field name, and a field cannot be written | `Js.object [ ( "key", value ), … ]` (§3.1) | identical: `({length:a,h:b,hc:c,T:d,t:e,p:null,$plain:f})`, one literal per form, so one hidden class per form |
| **`$plain` of a view and of a trie** (`ViewPlain`, `Flat`) | **No.** No function can read `this` | `Js.method λself → …` (§3.2) | `function(){let a=this,b=a.p;if(b===null){…}return b}`; the trie's three copy loops written in place as `for`/`while`, the leaf copy a call |
| **The cache** `p`, written once | yes, once the object is a `Js.object` (`Js.set h "p" b`) | — | identical |
| **Reader dispatch**: `Array.isArray`, `xs.o !== undefined`, `xs.T !== undefined` | yes | — | identical (`Opt` turns `!(x===void 0)` into `x!==void 0`) |
| **`unsafeGet`, `base`, `offset`, `view`, `close`** — the values the code generator imports | yes in beni; **no** in the compiler | `Lower.exports` and the unobserved-result rule (§3.3) | identical; a `--library` build specialises `unsafeGet(xs, 0)` to `d(i)` where the sibling could not be |
| **The descent** `Leaf`, **`Get`**, **`Drop`** | yes | — | identical (`Leaf` is a `for(;;)` over parameters) |
| **Path copies** `PutLeaf`, `PopLeaf`, **`Right`/`Left`** (root growth) | yes | — | identical; `putLeaf`'s padding loop is written into it as `while(c.length<j)c.push(null)` |
| **The claims** (`Claim`: push onto the version that owns the end, share, or copy ≤ 31) | yes: the ownership test is a runtime `b.length === c`, not static knowledge | — | identical |
| **`From`** (plain → trie, level by level), **`TSet`**, **`TPush`**, **`Pushed`**, **`Prepend`**, **`TPop`** | yes | — | identical but `TPop`'s root collapse is a loop of parameters where the sibling reassigned locals (same work) |
| **The surface** `cons`, `append`, `set`, `push`, `pop` | yes, as `Js.pure` bodies | — | identical |
| **`eq`, `compare`** (`where` evidence) | yes, today (tier 1) | — | `eq` identical; `compare` is a loop function of eight parameters, its exit computed inside the loop (§5.3) |
| **`slice`, `insertAt`, `removeAt`, `swap`** | yes, today | — | identical; `slice`'s clamp a helper the specialiser writes in place |
| **`concat`**, its `Put` | yes, today | — | three loops (find the one non-empty list, total, copy) where the sibling had one count loop and a copy; the largest byte growth (§5.4) |
| **`builder`, `done`** | yes | — | identical |
| **`length`, `at`, `put`, `identical`, `kept`, `half`** | not needed | — | written in place by the code generator already (`backend.md` §4); the sibling keeps them only for a value of one, as `Basics` keeps its operators |

**What the task suspected might be missing and is not:** a class or prototype declaration form
(the contract makes `$plain` a field precisely so that `Minify` never sees a `class`, §9 *Hand-written
JavaScript under `--release*`); getters; `Js.Ref` fields on objects (a cell would be `{v}`, an
allocation and an indirection per header — not needed, because a field of a `Js.object` can be
`Js.set`); integer-typed loops (`Int` arithmetic and comparison are operators in place, the
bit operations are `Js`'s); a way to say "this object has a hidden class like X" (one call site of
`Js.object` per form *is* that, as one object literal per form was in the sibling).

---

## 3. The missing capabilities, with proposed spec text

### 3.1 `Js.object` — an object literal with literal keys

**Proposed text, `boundary.md` §4.2 (the `Js` list) and `backend.md` §4 (a new subsection
*`Js.object` is an object literal*):**

> `Js.object [ ( "k1", v1 ), ( "k2", v2 ) ] : Value` is the object literal `{k1: v1, k2: v2}`. The
> argument is a list literal of pair literals, each key a string literal that is an identifier
> (`$` allowed); anything else is refused at the call (a code of its own, not `internal`). Keys are
> written in the order given — never sorted, never renamed in any build — so every object one call
> makes has one shape; the values are evaluated in written order, each of any type (each pair's
> value is a fresh variable, as `Js.from`'s argument is). The list, the pairs and the keys are
> in-place literals (`static-dispatch-spike.md` §6.8, `checker-v2.md` §30): they mint no `List`,
> `String` or tuple edge, so a module below `String` may write one. `pure`: making an object
> changes nothing an observer can see. Passed as a value, `Js.js`'s `object` builds the same object
> from the pairs.

As built in the prototype: `JsIntrinsic.Which.object` with in-place position 0; the checker types
each pair's value against a fresh variable and leaves the key untyped (`objectFields`); the graph's
exemption counts each pair's key string; `Lower.objectLiteral` writes `l.object(…)` with plain
property names. About 90 lines of Zig.

### 3.2 `Js.method` — a function that reads `this`

**Proposed text, `boundary.md` §4.2 and `backend.md` §4 (*`Js.method` is a `function`*):**

> `Js.method : sync (Value → a) → Value`, written with a lambda, `Js.method λself → body`, is
> `function () { const self = this; body }`: a function JavaScript calls as a method, `o.m()`,
> its receiver handed to the lambda. It is printed as a `function` expression and never as an
> arrow, whose `this` is not the receiver's, and always with a block body. It takes no argument
> but its receiver. `sync`: JavaScript calls it and waits for nothing. Its one use is a field of a
> `Js.object` that a reader calls by name, as a list's `$plain` is.

As built: JsIr gains a `this_lit` leaf (handled wherever `global_this` is — 20 sites, all
mechanical) and an `arrow_method` flavour of `arrow`, printed `function(){…}`; `Lower.methodFunc`
lowers the lambda as an arrow and rewrites it to no parameters with `const self = this` first.
`Opt` inlines the single-use `self`, which stays correct because an arrow nested in the method
reads the same `this`.

Without it the prototype kept the two methods in the sibling as values, and met a check-4
wall worth recording: `foreign pure viewPlain : Js.Value` may not be written `export const
viewPlain = function () {…}` (a non-function `foreign` refuses any function literal), only as an
alias of a top-level `const` — which check 4 cannot see through. `Js.method` makes the question moot.

### 3.3 Two `Lower` fixes for core values the emitter calls

Both are one line, both latent today because every such value is `foreign`:

1. **`Lower.exports`** exports `List`'s core-private `unsafeGet`, `view`, `base`, `offset` and
   `close` only when they are `foreign_value`s. A beni body is not exported, and a program importing
   `List$close` fails to load (`SyntaxError: … does not provide an export named 'List$close'`). The
   fix tests `isValue()`, as the `Schema` branch beside it already does.
2. **The unobserved-result rule** (`Lower`'s `unobserved`, *a discarded call is a statement*) marks a
   non-`pub` value whose callers all discard its result. The emitter's calls of `close` are not in
   any BIR, so `close` looked uncalled and was written with no `return`:
   `n$3 === 0 ? v$2 : List$done(…);` — `run/ListRecons` and the `TailModCons*` programs then read
   `undefined.length`. The fix marks the same five names dispatched, as `Schema`'s compiled values
   already are. `backend.md` §4 should say, beside *The emitter's imports of the core-private
   exports*, that those values are exported and observed whether they are `foreign` or beni.

---

## 4. The shape, side by side

From the prototype's `--library --release` build of `LB2` (`esbuild`-formatted), against the
sibling as `Minify` left it:

```js
// header and tree: the sibling's Mk/Tree, and the beni ones
const j=(n,h,hc,T,t)=>({length:n,h,hc,T,t,p:null,$plain:Y});const w=(r,s,off,tc)=>({r,s,off,tc});
da = (a2, b2, c2, d2, e2) => ({ length: a2, h: b2, hc: c2, T: d2, t: e2, p: null, $plain: aa }), fa = (a2, b2, c2, d2) => ({ r: a2, s: b2, off: c2, tc: d2 })
// the claim
const Claim=(b,c,v)=>{if(b.length===c)b.push(v);else if(b[c]!==v)(b=b.slice(0,c)).push(v);return b};
ea = (a2, b2, c2) => { if (a2.length === b2) { a2.push(c2); return a2; } if (a2[b2] === c2) return a2; let d2 = a2.slice(0, b2); d2.push(c2); return d2; }
// a path copy, its padding loop written in place
ga = (a2, b2, c2, d2) => { let e2 = a2 === null ? [] : a2.slice(), f2 = c2 >>> b2 & 31; while (e2.length < f2) e2.push(null); e2[f2] = b2 === 5 ? d2 : ga(f2 < e2.length ? e2[f2] : null, b2 - 5, c2, d2); return e2; }
// push onto a trie
Da = (a2, b2) => { let c2 = a2.length, d2 = a2.hc, e2 = a2.T, f2 = c2 - d2 - e2.tc; return f2 < 32 ? da(c2 + 1, a2.h, d2, e2, ea(a2.t, f2, b2)) : da(c2 + 1, a2.h, d2, ua(e2, a2.t), [b2]); }
// a view's $plain
na = function() { let a2 = this, b2 = a2.p; if (b2 === null) { let c2 = a2.b.slice(a2.o); a2.p = c2; return c2; } return b2; }
```

Field order, literal kind and key spelling are the sibling's, so V8 sees the same three hidden
classes and every reader's inline caches stay as polymorphic as they were (plain, view, trie) and no
more. The differences that are not shape: `isPlain`/`isView`/`isTrie` are one-line functions where
the sibling bound `Array.isArray` to a name and wrote the field tests inline (the specialiser inlines
some, not all); a loop is a function of parameters, not of reassigned locals.

---

## 5. Measurements

### 5.1 Correctness

- `tests/corpus/run/`, every single-file program, development and `--release --allow-debug`: 560
  match their `.expected`, 2 do not — `ReadFileErrors` in both builds, which this harness also
  misses on master too, in both builds (my harness does not reproduce what its corpus case sets up).
- `claim-prepend-test.mjs` against the beni runtime: *3 028 791 checks of random operations on
  shared versions (largest 3 410), 507 of long lineages; all versions intact; forms checked
  plain 1 823 280, view 294 317, trie 911 701* — the same counts the shipped sibling gives.

### 5.2 Speed

Steady state, µs per call, median of 7 processes per side [range], prototype 2 ÷ master, load
2.6–3.2 (the first group at load 10–22, which widened the ranges of the allocating rows):

| workload | n | master | beni runtime | ÷ |
|---|--:|--:|--:|--:|
| flatten a pushed trie (`$plain`) | 1 000 | 11.0 [10.7–11.6] | 11.0 [10.2–11.8] | 1.00 |
| flatten a prepended trie | 1 000 | 14.8 [4.2–16.3] | 13.8 [3.3–31.4] | 0.93 |
| flatten two views (`$plain`) | 1 000 | 16.8 [15.2–39.4] | 17.1 [14.5–31.2] | 1.02 |
| build by `push`, 0 → n | 100 / 1 000 / 10 000 | 2.25 / 14.1 / 160 | 2.25 / 14.3 / 158 | 1.00 / 1.02 / 0.99 |
| build by `[ x, …acc ]`, 0 → n | 100 / 1 000 / 10 000 | 2.68 / 15.0 / 165 | 2.73 / 15.7 / 163 | 1.02 / 1.05 / 0.98 |
| `push` onto a trie | 1 000 | 0.024 [0.021–0.036] | 0.024 [0.021–0.029] | 1.02 |
| `[ 0, …xs ]` onto a trie | 1 000 | 0.031 [0.028–0.035] | 0.032 [0.031–0.036] | 1.02 |
| `pop` of a trie | 1 000 | 0.097 [0.075–0.104] | 0.098 [0.095–0.103] | 1.02 |
| `set` in a trie | 1 000 | 0.227 [0.156–0.953] | 0.228 [0.125–0.616] | 1.00 |
| `set` in a plain list (converts) | 1 000 | 6.80 [3.52–12.2] | 6.25 [2.26–12.4] | 0.92 |
| `[ …xs, 1, 2, 3 ]`, trie / plain | 1 000 | 0.267 / 1.64 | 0.270 / 1.68 | 1.01 / 1.02 |
| `List.get` near the end, trie / prepended | 1 000 | 0.013 / 0.013 | 0.013 / 0.013 | 0.95 / 1.00 |
| every element by `List.get`, trie / view | 1 000 | 9.88 / 6.98 | 9.68 / 7.04 | 0.98 / 1.01 |
| `drop` half, trie / plain | 1 000 | 0.067 / 0.019 | 0.066 / 0.019 | 0.99 / 0.99 |
| `[ x, …rest ]` walk, pushed / prepended trie | 1 000 | 0.578 / 0.575 | 0.580 / 0.574 | 1.00 / 1.00 |
| `List.sum` of a trie | 1 000 | 5.21 | 5.30 | 1.02 |
| `==`, plain | 1 000 | 1.089 | 1.093 | 1.00 |
| **`compare`, plain** | 100 / 1 000 / 10 000 | 0.154 / 1.383 / 13.8 | **0.179 / 1.647 / 16.0** | **1.16 / 1.19 / 1.16** |
| `slice` a quarter | 1 000 | 0.172 | 0.176 | 1.02 |
| `insertAt`, `removeAt` | 1 000 | 1.409 / 0.853 | 1.399 / 0.859 | 0.99 / 1.01 |
| `swap` in a trie | 1 000 | 0.123 | 0.127 | 1.03 |
| `concat` of n/10 lists of 10 | 1 000 | 1.84 | 1.72 | 0.93 |

Ranges overlap in every row but `compare`'s, whose ranges are disjoint at every size and which
reproduced in three runs. Instruction counts at 400 000 iterations agree on parity for the
single-header operations (`push`, `[ x, …xs ]`, `pop`, `get`, `set`, `drop`, `append` onto a trie:
0.98–1.03× of the whole timed call, harness included).

### 5.3 The `compare` gap is a loop shape

Isolated with the prototype's own build (load 2.6–2.9, 7 processes per side, `compare` at 1 000):

| `List.compare` written as | µs | ÷ master |
|---|--:|--:|
| the beni body: `compare` calls `compareFrom`, a loop of eight parameters | 1.649 | 1.19 |
| the same, its loop copied by hand into `compare` (one function, locals) | 1.640 | 1.19 |
| the sibling's JavaScript dropped into the beni core (its own `base`/`offset`) | 1.387 | 1.00 |
| the beni core's `base`/`offset` and the sibling's loop: `for(let k=0;k<n&&k<m;k++){…}return n===m?…` | 1.382 | 1.01 |

So neither the extra function nor the beni `base`/`offset` costs anything; what costs 19 % is the
tail-call loop's printed form, `for(;;){if(!(h<d&&h<g))return d===g?"EQ":d<g?"LT":"GT";…h++}`,
against `for(;h<d&&h<g;h++){…}return …`. `eq`'s loop, whose exit is `if(f>=g)return true`, is at
parity, so the shape that hurts is an exit test of more than one comparison with the exit value
computed inside the loop. The fix belongs to `backend.md` §8's loop printing: a loop whose body
*begins* with `if (!c) return x` prints as `while (c) {…} return x` (or a `for` with the update in
the head, as *Compact statements* already allows), which every beni loop of that shape would get.
It is not measured here beyond `compare`.

### 5.4 Size

`bench/size.mjs`, release brotli, master's compiler and core against prototype 2's:

| | master | beni runtime | |
|---|--:|--:|--:|
| total over 363 programs and pages | 431 969 | **430 561** | −1 408 (−0.33 %) |
| programs and pages smaller / larger by brotli (the rest equal) | | 112 / 44 | |
| the largest growths | | `NestingFlatList` +83, `SuspendListBuildDeep` +58, `SpecializeFacts` +56, `NestingEvidence` +52, `ListSpreadPatterns` +46, `ListScalarView` +45 | |
| the largest cuts | | `bench/corpus` −156, `ReleaseFieldRows` −76, `LibraryArgumentOrder` −73, `StringOrdering` −61, `TailModConsMerge` −56 | |
| pages: empty `browser`, `Tea.sandbox`, `Tea.element`, effects, random | 446, 446, 1 222, 5 306, 1 955 | 446, 446, 1 220, **5 334**, **1 966** | 0, 0, −2, +28, +11 |
| development, gross brotli | 2 150 270 | 1 308 298 | −39 % |
| the floor | 891 | 891 | 0 |

Where the bytes go: the programs that shrink are those that reach a few list functions, which no
longer pull the sibling's shared top-level helpers and gain from specialisation through the runtime
(a `--library` build writes `unsafeGet(xs, 0)` as `d(i)`); the ones that grow reach `concat` (three
loops where the sibling had two) or a `where`-evidence `eq`/`compare` (a loop function each), and
nearly all are smaller *raw* (`NestingEvidence` 3 827 → 3 788 raw, +52 brotli): a beni body's
identifiers are short names that brotli prices differently from the sibling's repeated words, the
same "names only" effect step 1 met.

The two earlier stages, for the slice plan: **tier 1 alone** (today's compiler; `eq`, `compare`,
`slice`, `insertAt`, `removeAt`, `swap`, `concat` in beni, the trie in the sibling) is 431 969 →
432 020 (+51), 26 programs smaller and 16 larger — the beni loops cost what they cost above, and
nothing of the sibling goes away, since the trie still needs `base` and `offset` there. **Prototype
1** (everything but the two `$plain` methods) is 431 072 (−897), 97 smaller and 59 larger. The
methods in beni took off another 511.

### 5.5 The gates

`zig build gates` on the prototype: 1 195 of 1 214 tests pass (4 fail, 15 skipped), and `beni fmt --check` fails. Red: **`abuse_wide_test`'s *a case of
16 400 literal branches builds as switches … and runs under `--release`*, 4 771 million
instructions against the 4 300 budget** — not profiled; the likely cost is the release passes walking `List`'s runtime, now beni, in the
program — and goldens a slice re-blesses or rewrites on purpose: `emit/release/SuspendShapes`
(`d(i,0)` became `d(i)`, the specialiser at work), the graph dump's type edges (`List → Js`),
`build_test`'s *expected out/_core/List.foreign.mjs to exist* (the sibling no longer ships)
and `beni fmt --check` of the prototype's `List.beni`. Per `CLAUDE.md` rule 10 the budget is
the wall: the fix is the specialiser's cost over core, not a `List` kept in JavaScript.

---

## 6. How to re-run

On the branch `list-in-beni-prototype`, scripts in `bench/list-in-beni/` (run from that directory;
`zig cc -O2 -o icount icount.c` first for instruction counts):

```sh
beni build --library --release --platform=node --core-root=<core> --out=<dir> LB2.beni   # each side
node steadyall.mjs <dir-a> <dir-b> 7 1000 compare-plain,push-trie,…    # wall time, alternating processes
node ab.mjs --src=LB2.beni --wl=p.mjs --a-beni=… --a-core=… --b-beni=… --b-core=… \
    --rounds=3 --icount=./icount --sizes=1000 --iters=400000 --only=push-trie,…    # instructions
LIST_DIR=<a development --library build of LB2> node <claim-prepend-test with core-compiled.mjs> core
```

`bench/size.mjs` takes no `--core-root`; the figures above came from a copy that passes one.

---

## 7. Decisions for the owner

1. **Adopt `Js.object` and `Js.method`** (§3.1, §3.2) as `Js` intrinsics. They are the whole of what
   the language lacks for this runtime, and both are generic: any platform runtime that hands
   JavaScript an object of fixed shape or a method has the same need.
2. **Land the two `Lower` fixes** (§3.3) with fixtures, independently of the port: they are defects
   for any core value the emitter calls that is ever written in beni.
3. **The tail-call loop's exit** (§5.3): print an exit-first loop as `while (c) {…} return x`.
   General, measurable on its own, and it removes the one speed gap of the port.
4. **The budget wall** (§5.5) must move before the port lands — the release specialiser's cost on a
   program whose core is mostly beni; it is step 5's *specialise a library build* cost met again,
   now in an application.
5. **R47-3 and the 44 programs that grow** (§5.4): the total is smaller and development output is
   39 % smaller, but the bar is per program. Either the growths are taken to `hand-minify`'s method
   first (`concat`'s three loops, the evidence loops), or the owner accepts a per-program growth of
   at most ~80 bytes against the total, as was weighed for `String.compare` in step 1.

**Decided (the owner, 2026-10-02).** Items 1 and 5 are taken: **`Js.object [ ( "key", v ), … ]`**
(keys in written order, never renamed) and **`Js.method λself → …`** (a function that reads
`this`) are adopted as `Js` intrinsics, with §3.1 and §3.2's text as their contract; and the growth
goes to **`hand-minify` first** — the 44 programs that grew 1–83 bytes are to be brought to equal
or smaller through `hand-minify`'s method on `concat` and the `eq`/`compare` loops and any general
compiler rule that helps, and only growth that remains after a real effort comes back to the owner,
each program listed with its cause. Items 2, 3 and 4 had landed on master before the decision
(`f7b23233`, `b35b0e49`; `e37cb7d7`; `d656e7dc`, `c2d9393f`, which put `abuse_wide`'s release case
at 4 139 million instructions with this `List`). The port proceeds as `plans/core-in-beni.md` step
3's slices.

**Landed (2026-10-02).** The port is on master, with the two intrinsics specified and built, and
`hand-minify`'s pass on the runtime (each walk written once, `concat` recounted, `eq`/`compare`
walking two bases to their ends): release brotli 492 855 → 486 010 over every program and page,
166 smaller and 3 larger (`NestingEvidence` +34, `ListElementEq` +6, `ConsPatterns` +1), every
measured operation within noise, `compare` at 1.01–1.02. `plans/core-in-beni.md` step 3, *Landed:
L2, L3, L6 and L7*, has the ledger, the speed table, the two compiler defects the port found and
the budget wall left.
