# 140 — An in-place oracle, and an identity trap

*Research report, 2026-11-15. Today no build of beni edits a list in place: `core/List`'s writers copy
below 32 elements and build a trie above. So the only oracle for the ownership checker v3
(`--ownership=v3`, `ownership-v3-kernel.md`) was the list sanitiser (`--sanitize-lists`,
`ownership-v2.md` §7.3), and the sanitiser cannot see a fault of identity: a holder that kept a list,
then compares it with `===` to the list after an in-place write, sees one object where the sanitiser's
copy shows two. Issue #2504 is that class, in the `dom` lowering. This report adds a real in-place build,
a trap for identity in the sanitiser, and a rule for `browser-inline`'s keyed rows, then runs every sweep
and the corpus under both oracles.*

---

## 1. Result

- **`--lists-in-place`, hidden and test-only**, edits each list write the checker accepted on its base's
  own array, as `backend.md` §4 (*The representation: a plain array*, *Every platform edits in place*)
  lowers it. The output of such a build is what the program prints where lists are edited in place.
- **The sanitiser traps an identity compare** whose answer an in-place write would change.
- **One fault, in a row of `core/`:** `Js.same` was `unused a, unused a`, so no checker counted an
  identity compare as a read of its operands. v1, v2 and v3 accepted a write of a list that a value kept
  from before the write was then compared with by identity. In place the two are one object. The row is
  now `borrowed a, borrowed a`, and kernel rule 10 says why. Fixture: `run/IdentityAfterWrite`.
- **No sweep and no corpus program shows a fault under either oracle** with the fixed row: §4's table.
- **`browser-inline`'s keyed rows never decide by identity** (`browser-inline.md` §9.2, §9.4, §9.5,
  §9.7, amended). The rows are not built yet (S2), so no code changed. §5 lists every identity compare of
  `browser-inline`, the static site generator and `core/`, each with its verdict.

## 2. The in-place oracle

`--lists-in-place` is a build flag, hidden as `--sanitize-lists` is, and refused with `--release`, with
`--sanitize-lists`, and in a build that does not enforce ownership. It is lowered exactly as the
sanitiser is: each accepted write is a call of the runtime's `list(site, writer, base, …)`, and only an
accepted write is (`Lower.sanitizesAt`). Only the runtime differs: the build writes
`src/js/inplace_runtime.mjs` as `_core/_sanitize.mjs`.

- On a plain array, `set`, `update`, `swap`, `push`, `pop`, `insertAt`, `removeAt` and `append` are what
  §4 lowers them to: a store, a `push`, a `pop`, a `splice`; the array is the answer. Out of range, the
  list itself, as `core/List` answers. The site names the writer.
- On any other form, the writer of `core/List` runs, and its answer is copied into the base: a view is
  never written (§4: its write makes a plain array, and the view keeps its elements); a trie header,
  which the target does not have, takes the answer's fields in place, so every holder of it sees the
  write.

- A write that may park (a writer's suspendable twin, `name$s`, whose callback may wait) is lowered as
  `start(…)` behind the suspension marker and then `settle(base, answer, site)`: the answer can come
  after the fiber resumes, which code after the writer inside `list` would never see.
- An item before a construction's base (`[ x, …xs, y ]`, which is `List.cons x (List.append xs
  [ y ])`) goes in front of the written base (`front`), as §4's *Writes* says, where `List.cons`
  would copy.
- v3 says `List.update` at its call (`call List.update xs`: it has no words, and its write is
  `focus`'s inside core), and the channel left such a line out, so neither oracle wrapped it.
  `Enforce` now names an accepted `List.update` call a writer, and the corpus's site check counts it.

A writer's answer is its base, so an identity compare in an in-place build answers what the target's
answers. The sweeps' runner builds each program a third time with the flag (`run.mjs --mode=both`).
The last three bullets were found by the review of this change (§9); the sanitiser takes the same
`start`/`settle` split, `front` and `List.update` coverage.

What the oracle does not model: records are still spread under `--ownership=v3` (only v1's clean
channel writes them in place), so they are the plain build's. And two forms of today's `core/List` are
not the target's: a view's cached plain copy (`p`) answers the elements from before a write of its
base, and a `List.drop` of a trie is another header over the old storage. Neither oracle sees a stale
read through either. Both go with the trie (`ownership-checker.md` §30.5, O5); #2511 holds them.

## 3. The identity trap

A poisoned list traps where it is read, and `===` reads nothing. So each write in the sanitiser also
links its base to the list it answered, with the site, unless the base is a view (a view is never
written in place). In place, a base and its successors are one object. `Js.same a b` in a module
outside core lowers to the runtime's `same`, which answers `a === b`, and throws where `a` and `b` are
distinct and their last successors are one object: an in-place run would answer `True` where this one
answers `False`. A compare whose answer no in-place write can change answers as `===` does.

Core is not trapped. Its identity compares are §5's; `core/List`'s four answer whether a store would
change a cell, and an in-place run and this one give the same list either way.

With the trap, the probe of §1's fault traps under the sanitiser and prints `one object` in place, where
the plain build prints `two objects`. With the row fixed, all three checkers refuse it
(`list_still_used`).

## 4. The sweeps

Every generator of `bench/ownership-sweeps/` (82 564 programs) and the corpus (`corpus.mjs`, 1 654
programs: `run/`, the `browser/` pages, `browser/inline/`, `browser/prerender/` compared by the pages
the build writes, and `browser/dom/`, `browser/managed/` and `browser/tea/` to list their faults), each
built plain, under the sanitiser with the trap, and in place: most by this change before the review's fixes
(§9), the end of `recursive-levels` and all of `folds-callbacks` by the final build. The faults columns count TRAP, DIFF, IPTRAP and IPDIFF.

| Sweep | Programs | Accepted, same output | Refused | Faults, sanitiser | Faults, in place | Not judged |
|---|---:|---:|---:|---:|---:|---:|
| `aliased-arguments` | 5 160 | 1 183 | 3 977 | 0 | 0 | 0 |
| `answers-beside` | 240 | 77 | 163 | 0 | 0 | 0 |
| `blind` | 9 792 | 1 675 | 8 117 | 0 | 0 | 0 |
| `blind2` | 1 202 | 502 | 700 | 0 | 0 | 0 |
| `blind3` | 417 | 160 | 257 | 0 | 0 | 0 |
| `blind4a` | 160 | 24 | 136 | 0 | 0 | 0 |
| `blind4b` | 6 596 | 1 229 | 5 367 | 0 | 0 | 0 |
| `blind5c` | 226 | 81 | 145 | 0 | 0 | 0 |
| `blind5d` | 1 234 | 456 | 778 | 0 | 0 | 0 |
| `blind6e` | 238 | 90 | 141 | 0 | 0 | 7 |
| `blind7f` | 960 | 404 | 556 | 0 | 0 | 0 |
| `blind8g` | 121 | 21 | 100 | 0 | 0 | 0 |
| `blind9h` | 3 213 | 852 | 2 361 | 0 | 0 | 0 |
| `blind10i` | 474 | 151 | 209 | 0 | 0 | 114 |
| `bounded-walk` | 34 | 5 | 23 | 0 | 0 | 6 |
| `callbacks-keep` | 720 | 108 | 612 | 0 | 0 | 0 |
| `evaluation-order` | 440 | 276 | 164 | 0 | 0 | 0 |
| `folds-callbacks` | 30 300 | 5 392 | 24 908 | 0 | 0 | 0 |
| `function-values` | 1 960 | 304 | 1 656 | 0 | 0 | 0 |
| `handed-back` | 2 592 | 0 | 2 592 | 0 | 0 | 0 |
| `recursive-levels` | 16 131 | 4 140 | 11 991 | 0 | 0 | 0 |
| `wider-functions` | 354 | 144 | 210 | 0 | 0 | 0 |
| corpus `run/` | 1 087 | 757 | 317 | 0 | 0 | 13 |
| corpus `browser/` pages | 2 | 2 | 0 | 0 | 0 | 0 |
| corpus `browser/inline/` | 124 | 121 | 3 | 0 | 0 | 0 |
| corpus `browser/prerender/` | 31 | 31 | 0 | 0 | 0 | 0 |
| corpus `browser/dom/` | 72 | 71 | 1 | 0 | 0 | 0 |
| corpus `browser/managed/` | 54 | 5 | 0 | 0 | 0 | 49 |
| corpus `browser/tea/` | 284 | 257 | 25 | 0 | 0 | 2 |
| **total** | **84 218** | **18 518** | **65 509** | **0** | **0** | **191** |

No program reached a limit. *Not judged* is a program that does not build plain (`PLAINFAIL`: the
generators' `browser-inline` pages that the platform does not compile yet, and three corpus fixtures
whose platform is a test one this runner does not set up), or fails both plain and checked
(`BOTHFAIL`: the corpus's defect fixtures, which exit with an error on purpose, the `managed` pages,
whose driver is not `driver.mjs`, and six `bounded-walk` controls past the run's time).

The first pass found four corpus programs that were not `SAME`, and none is a fault: `ListWalkDeep`
and `TailModConsMerge` passed the run's 20 s, the first in place (the runtime then copied each push
back, quadratic, so it now writes the eight writers natively) and the second under the sanitiser;
`LogDefaultSink` interleaved standard output and standard error differently (the runner now keeps the
streams apart); and `ListSanitiserTrieHolder` is the sanitiser's own expected trap, a test platform
whose words lie (`keep` is `borrowed` and keeps). Judged again with the final runtime and runner,
the first three are `SAME`, and the fourth traps under the sanitiser as its golden says.

The sweeps ran on the change before the review's fixes (§9). Every accepted program whose source has
`update` or an item before a spread (5 652 programs) was judged again on the final build: all `SAME`.
A program refused before is refused after: the fixes changed no verdict but `Js.same`'s, which can only
refuse more.

## 5. Identity compares, with a verdict each

The question of each: can an in-place write change its answer? It can only where both operands may be a
list (or hold one) that a write accepted by the checker edited.

**`browser-inline`** (`platforms/browser-inline/`): no compare of a list or a record that a write may
have edited. The lowering (`zig/inline.zig`) emits `===` and `!==` only on an arm's number
(`taken === 2`), an attribute's string (`getAttribute(…) !== v`) and an option's value against a
literal. The runtime's `Js.same`:

| Where | Compares | Verdict |
|---|---|---|
| `Inline.text` | the node's `textContent` with the string shown | safe: strings |
| `Inline.writeProp`, `Inline.prop` | a DOM property with the value written, `member` with `"value"`, `activeElement` with the element | safe: scalars and DOM nodes |
| `Inline.title` | `document.title` with a string | safe |
| `Inline.take` (`parentNode` with a node), `hiddenArms` (`String(k)` with a comment's data; a comment's parent with a node) | DOM nodes and strings | safe |
| `Inline.state`, `Inline.restore` | an input's type with `"file"`, a control's property with a value the page saved | safe: strings and scalars |
| `Inline.noteOf`, `Inline.callNoted`, `keyedRow` | an event's type and a route's key, strings | safe |
| `Inline.copyIn` | a route function's answer with the model's old value at its field, to copy only an answer that is another object | safe: a record or a scalar, never a list (the rows are of the route's record type). Edited in place the answer is the old object, which already holds it, and copying is skipped; a new object is copied in; either way the field holds the answer's contents |
| `Browser/Navigation` (eight) | URLs' protocol, host, origin and href, a link's target, a mouse button, an error's name | safe: strings and numbers |

**The static site generator** (`browser-inline`'s `Browser.prerender`, the `html` and `node`
platforms): `Html.beni`'s two (`selectionDirection` with `"backward"`, an event flag with `True`),
`node/Rt.beni`'s four (lengths with 0, names and values with `""`), `node/Io.beni`'s three
(`length`, `aborted`, an error's name) and `node/WebSocket.beni`'s five (a socket's `eq` is the host
object's identity, a state, an `errno`, a length, the last text): safe, each compares a scalar, a
string or a host object no beni write can reach. The `ssr` lowering emits no identity compare, and no
platform of the generator has a JavaScript sibling.

**`core/`**: the generated `derived_runtime.mjs` compares lengths and `Order` tags only; `core/Js.js`'s
`same` is `Js.same` handed as a value (none in core or the platforms). `Js.same` in core:

| Where | Compares | Verdict |
|---|---|---|
| `List.cons` (re-consing a pattern's head), `List.reconsed` | the element before a view's offset with the item | safe: if they are one object the wider list holds the item there, in place or not; the answer's elements are the same either way |
| `List.set`, `List.claim`, `List.trieSet` | the element at `i` with the value stored | safe: one object means the store changes no cell; the answer's elements are the same either way |
| `Task` (fourteen) | fibers, schedulers, the waiting sentinel, a stack's boundary marker | safe: runtime objects, never a list a beni write edits |
| `Schema` (twenty-seven) | a value with the decoder's failure mark, `typeof` strings, tags and keys, an `issues` array with the one the run started with | safe: marks and arrays of the runner's own, which no app write reaches |
| `Basics`, `Binary`, `Date`, `Debug`, `String`, `Url` | numbers, strings, flags, characters | safe |

Core is the one package the trap leaves out (§3); every one of its compares is above.

## 6. `browser-inline`'s keyed rows

`browser-inline.md` §9.4 had `sync(L, all)` skip a reused row's `set` when its value was the same object.
In place, a `Dict.update` that edits a value leaves the same object, so identity says "unchanged" exactly
when the write changed it. The rule now: the write set decides. `at(L, κ)` runs κ's `set`;
`sync(L, all)` runs every reused row's `set` when `all`, and none otherwise; `all` is true when a kept
key may hold another value — a `p{…}` write, or a `grow` or `replaced` tag (an `insert` of a key already
there, a union, a new dictionary). `insertAt` is `sync(L, false)` and then `at(L, κ)`. A row keeps its
value only for its `set` and its handlers, never for a compare. Inside `set`, each hole's guard compares a
scalar with what the DOM shows.

## 7. Out of scope

No fault of the `dom` lowering or of `browser-tea` was found. The corpus's `browser/dom/`,
`browser/managed/` and `browser/tea/` pages, and the `browser` and `browser-tea` pages of `blind5d`,
`blind6e`, `blind8g`, `blind9h` and `blind10i`, ran with `platforms/browser/Rt.beni`'s identity
compares behind the trap: none trapped, and none printed another page in place. #2504 (a `For` keeps
its items and keys and compares them by identity) stays open: no accepted program of these sweeps writes
in place a list such a `For` kept. Both are out of this report's scope, and nothing there was changed.

## 8. Reproduce

```sh
node bench/ownership-sweeps/<generator>.mjs <dir>/<name>
node bench/ownership-sweeps/corpus.mjs <dir>/corpus
node bench/ownership-sweeps/run.mjs --beni=zig-out/safe/bin/beni --checker=v3 --mode=both --jobs=16 --tmp=<disk> <dir>/<name>
```

## 9. The review

One adversarial reader read the change before it was pushed. Its findings and what became of them:

1. **v3's `List.update` was never wrapped**, so neither oracle edited it or linked it: v3 says it at the
   call, and the channel kept only `writer`, `construction` and `++` lines. Fixed (§2).
2. **An item before a construction's base** went into a copy, not the base. Fixed: `front` (§2).
3. **A write that may park** answered a continuation to code that expected a list. Fixed: `start` and
   `settle` (§2).
4. **A view's cached copy and a trie's other headers** are not the target's lists. Not fixed here: #2511.
5. **`ownership-checker.md`'s table of trusted words** still said `unused` for `Js.same`. Fixed, with the
   trusted surface's flips for both operands, which `JsWords` now pins.
6. **A pack row of a platform module** holds a plain `===`. Under the sanitiser no pack row is read
   now (v3 builds read none anyway).
7. `run.mjs` called a checked run that timed out while the plain one failed `BOTHFAIL`, and missed a
   plain run that timed out. Fixed.
