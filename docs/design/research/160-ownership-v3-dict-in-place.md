# 160 — Dictionaries written in place, judged by v3

*Research report, 2026-11-19. Lists and records are written in place under the ownership checker v3
(`ownership-v3-kernel.md`, owner decisions of 2026-10-15 and 2026-11-15). This report brings `Dict` and
`Set` in by report 142's method: the representation first, then the oracle, then the rules and the
checker, then the sweeps and the corpus under every leg. The representation is the owner's decision
(2026-10-17 on #294, amended 2026-10-25 on #298: the index maps a key to its entry) and is not
re-opened here. Kernel §12 holds the rules.*

---

## 1. Result

- **The representation is built** (§3). `core/Dict` is `pub equatable keyed foreign type Dict k v`
  over `core/Dict.js`: `[key, value]` entries in insertion order and a `Map` from each key to its
  entry. `Set` boxes a `Dict t ⊤`. `Dict.empty ⊤` and `Set.empty ⊤` are functions; `copy`, `swap`,
  `insertAt`, `sortBy`, `keyAt` are new; `compare` stays removed. The public writers copy; only a
  write v3 accepts is in place, and only under the oracle (§3.2).
- **The oracle sees dictionaries** (§4). `--sanitize-lists` runs an accepted write on a copy and
  poisons the old header and entries; `--lists-in-place` moves the written storage into the base's
  header. A v3 with its later-read test turned off is caught on every live probe, by a trap under the
  sanitiser and a different output in place; the real v3 refuses them and prints the same in all four
  legs for their dead twins.
- **v3 judges a dictionary as a list of its values** (§5, kernel §12): a `keyed` type is storage of
  kind `list` whose element is the value; the primitives are trusted rows; a key is a position
  (`insert`, `remove`, `valueFor`), which answers #2563's `Dict` side for get-then-insert.
- **No soundness fault** in the `dicts.mjs` sweep (new), the records sweep, the corpus, or either
  review's programs (§7, §8).
- **Verdicts** (§6): no real root has an accepted line refused. The ledger is 309 of 319 (was 296 of
  308). 15 new refusals on real roots are of `Dict` writes v3 judges for the first time: 5 are real
  sharing (`NotesApp`'s history keeps the old notes), the rest precision, in #2570.
- **A cost the brief's rule buys** (§3.3, #2569): with every production write a copy, a fold of
  inserts is O(n²). `run/MarkdownLimits` met the hang guard; `Markdown` now builds its definitions
  once.

## 2. What v3 did with `Dict` before

`core/Dict` was Elm's red-black tree in beni, copied on every write. v3 walked its bodies. A `Dict`
write was never a demand: `insert` built a new path of nodes, so nothing was written in place, and the
walls of reports 154, 158 and 159 were precision walls of reading a value back out of the tree
(`insert` through a type-dispatched helper, `Dict k v` read at an instance, the deep level of
`balance`'s answer). None of them exists in the new representation: there is no tree.

## 3. The representation

### 3.1 From #961, against the decisions

Draft PR #961 (2026-10-24) built the representation on `master` against checker v1. Reused: the
sibling's storage (`entries`, the pair index), `keyAt`, `swap`, `insertAt`, `sortBy` through a private
`permute`, the walk-by-position loops, `Debug.toString`'s reader of the entries, the migrated run
fixtures (`DictInsertionOrder`, `SetInsertionOrder`, `DictBorrowedPermutation`, `DictKeyAt`,
`DictOrderedOps`) and the golden changes that insertion order makes (14 `run/` programs; the
owner's decision changes their output, so "behaviour unchanged" holds of every program whose output
does not depend on a dictionary's order, and of no other). Not reused: #961's unconditional in-place
writers, its v1 rows (`dictRow`) and every v1 change: v1 and v2 are frozen.

### 3.2 Who judges a write

The brief's rule is that no dictionary is written in place without a v3 acceptance. v1 is the checker
a build enforces today, and it knew `Dict` only as the tree's walked bodies. So:

- **The writers copy** (`core/Dict.js`): a new header, entries, pairs and `Map`. The private `put`
  writes in place, into storage the loop that calls it made (`map`, `filter`, `partition`, `union`,
  `fromList`, `singleton`), as `List`'s `Builder` is written; v3 accepts each such write in `core/`.
- **The rows are v3's.** The writers' words (`written`, `stored`, `elementof`, `copyof`) are v2-only
  words, so v1 reads no word on them and sees `foreign` code it does not walk; v2 reads a row over a
  keyed place as a `foreign` with no word (`own2/Keyed.zig`, a 20-line file, since v2's code is
  frozen but its verdicts must not invent a `Dict` write it never judged). The v1/v2 parity list
  (`tests/blackbox/ownership-v2-known.txt`) gains 37 lines for the corpus programs whose verdicts
  moved, each with its reason, and loses the 129 lines (most of them the tree's `#Dict.0#Node` paths) that no longer occur.
- **The oracle legs** route a call v3 accepted (§4).

### 3.3 What the copy costs

The tree's insert was O(log n); a copy is O(n). A fold of one `insert` per item is O(n²) in every
production build. `run/MarkdownLimits` (cmark's many-link-reference input) passed the 120 s guard on
the tree and timed out here, until `Markdown.collect` gathered its definitions in a list and built the
dictionary once with `fromList` (first definition wins: the list goes in reversed). The same shape
remains in `Url.Parser.prepareQuery`, `Http.headersFrom` (#969) and user folds (#2569). It ends when
v3 is the checker a build enforces and an accepted write is in place in production, which is the
representation's target (`backend.md` §4, amended).

### 3.4 The measurement the owner asked for

§9.

## 4. The oracle

`Lower.listWriterAt` names a writer of `Dict` (`insert`, `remove`, `update`, `swap`, `insertAt`,
`sortBy`) and of `Set` (`insert`, `remove`, `swap`, `insertAt`, `sortBy`) under `Input.records_v3`
only. A call the module's channel lists as accepted is `_sanitize$list("`Dict.insert` in M …", writer,
base, …)`. The walked writers (`Dict.update`, `sortBy`, `Set`'s) make a `callsite` demand; v3's
`Enforce.callsCoreWriter` names them to the channel as writers, as it did `List.update`. `sortBy` takes
evidence first, so it is `_sanitize$listAt(site, writer, k, …)` with its base at argument `k`.

- **Sanitiser** (`sanitize_runtime.mjs`): the writer runs on a fresh copy of the header (or the
  `Set`'s box and its header), then every own property of the old header and of a box throws on read,
  the old entries array is poisoned as a list's is, and the base is linked to the answer for `same`.
- **In place** (`inplace_runtime.mjs`): the writer's answer is new storage; the base's header takes
  its `entries` and `index`, and the base is the answer.

**The oracle sees a wrong acceptance.** With `Frame.useReaches` answering "no later read" (a mutant
built in the lane, not committed), six live programs: a `Dict.insert` with the old dictionary's size
read after, a `Set.insert`, a `remove` compared with `==` to its base, a `Dict.update`, a
`Dict.sortBy` and an update whose callback pushes into the value. Each was accepted, and each was
TRAP under the sanitiser and DIFF in place. The real compiler refuses all six (`later-use`, or `supply`
for the callback) and runs their dead twins SAME in all four legs.

## 5. The rules (kernel §12)

1. **A keyed type is a list of its values.** `keyed` (`Ast.OwnTypeWord`, `Bir.OwnKind`) stands before
   a two-parameter `foreign type`; the place graph gives it kind `list` and one element step, the value.
   Keys are `Int` or `String` and hold no cell.
2. **Rows.** Writers `written returned` with `stored`; `copy : borrowed → copyof`; readers `borrowed`,
   `valueFor`/`valueAt : … → elementof v`; `traverseAt : … → taken v` for loops that read each
   position once in order (asserted, pinned in `word-bodies.txt`); `empty : ⊤ → fresh exclusive`.
   The loops that build a dictionary or a list are typed walks by position, not folds over a type
   variable, which read the storage and the values as one location and refused `put` (`supply`).
3. **A key is a position.** `insert`'s key, `remove`'s and `valueFor`'s carry `position` (rule 10):
   `get d k` answers `π1@1[π2]`; `insert d k v` answers `[π3, π1@1[≠π2]]`; `remove d k` answers
   `π1@1[≠π2]`. The last widens rule 10's *A position*, which read the other positions only beside a
   `stored` value: the fact is the same, of the elements that stay. So `update`'s join answers the
   value it took out at no place but the callback's (`update`'s row: `[[*] answer3@0 π1@1[≠π2]]`).
4. **A value inside a dictionary is a cell** at the element location, and a record's slots or a
   list's storage are below it, as in a list (§11). A write of a value taken out of a dictionary is
   judged as a write of a list's element.

## 6. Verdicts before and after

`dump --stage=ownership --ownership=v3 --ownership-everywhere` of all 2 875 roots before and 2 881
after (six fixtures new), compared line by line, `core`'s `Dict` and `Set` modules left out (rewritten):

| Change | Lines | Where |
|---|---:|---|
| absent → accepted | 264 | `Dict` and `Set` writes judged for the first time |
| absent → rejected | 77 | the same; real roots below, the rest test fixtures (`ListPersistence` 16, `CoreDictRest` 8, `FoldAccumulators` 7, …) |
| accepted → absent | 12 | lines that moved (`Markdown` 1271 → 1274, edited fixtures) |
| accepted → rejected | 1 | `ownership/DictValueWritten` 14:15, a fixture: `Dict.size` reads the values (#2570 item 4) |
| rejected → accepted | 1 | |

**Accepted → refused on a real root: 0.** New refusals on real roots, each of a write v3 had never
judged:

- `bench/corpus/NotesApp` 86:29, 107:17, 110:13, 115:19, 118:25: `pushHistory` keeps the old model
  and the notes are written after, so in place the history would change. Real sharing; the fix is
  `Dict.copy`. 261:11 is a fold (#2570 item 3).
- `bench/corpus/DictExtra` 22:5, 55:30, 60:32, 64:15, 167:25 and `FormValidation` 275:13: folds and
  `Dict.update` callbacks (#2570 items 1 and 3).
- `core` `Markdown` 1274:22, `Url.Parser` 289:13: folds; core's writes are not enforced.
- `platforms/browser` `Http` 1047:23: `Dict.update (Js.read all)`, a `Js.ref`'s contents (#969).

**The ledger** (`bench/ownership-v2-review.mjs --checkers=v1,v3 --roots=real`): of the list writes v1
judges, v3 accepts **309 of 319** (was 296 of 308). v1 judges 11 more writes because `Dict`'s
writers are now `foreign` to it; v3 refuses 10 at v1's positions (11 before), and 33 at positions v1
has no line for (18 before; the 15 above).

## 7. Sweeps

`run.mjs --checker=v3 --mode=both` with the lane's ReleaseSafe compiler: plain, the sanitiser, in place,
and `--release` plain and in place.

| Sweep | Programs | SAME | REFUSED | Faults | Other |
|---|---:|---:|---:|---:|---|
| `dicts.mjs` (new) | 4 428 | 463 | 3 965 | 0 | |
| `records.mjs` | 1 876 | 353 | 1 523 | 0 | |
| corpus | 1 803 | 1 257 | 526 | 3 | 12 BOTHFAIL, 4 PLAINFAIL, 1 LIMIT |
| the oracle's probes (§4), real v3 | 19 | 7 | 12 | 0 | |

- **The corpus**: the three are the known `run/ListSanitiserTrieHolder` and `dom`/`tea`
  `ShowAndBranches` (#2504).
- **`dicts.mjs`**: 7 makers (`fromList`, chained `insert`s, a fold of inserts, `map`, one list at
  two keys, a parameter, a top-level value) × 8 holders (the name, an alias, a tuple, a record field,
  `Just`, a list, a closure, a dictionary of dictionaries) × 13 writers (insert of a new and of a
  present key, remove, swap, insertAt, sortBy, update to `Just` and to `Nothing`, update whose
  callback pushes into the value, get then push then insert, a helper, a helper of another module, a
  fold of inserts) × 6 reads, and 60 `Set` programs. **Every `live` twin is refused.** Of the 616
  `dead` twins 463 are SAME in all four legs and 153 refused: 104 of the `top` maker (a top-level
  value, whose write the kernel refuses; the fix is `Dict.copy`), 96 of the `fold` maker (#2570
  item 5), and `updPush`/`getPush` of the other makers (#2570 items 1 and 2), overlapping.

## 8. Reviews

Two fresh adversarial readers (Opus), each told to write programs that v3 accepts whole and that trap or
differ under the four legs.

- **After the oracle and the representation** (about 1 480 programs: dictionaries in every holder and
  user type, every writer, one value at two keys built 21 ways and then written per position, positions
  with literal, aliased, rebound and record-field keys, values taken out by 14 readers and written,
  `merge`, `Set`, `Dict.copy`'s shallowness, the release optimiser's inlining around a write,
  `Task.spawn`): **no fault**. Its precision notes are #2570 items 6 to 11: two fresh inner
  dictionaries in one `fromList` read as one cell, `partition`'s halves read as one storage, a literal
  key is no position, a position lost through `copy`, `filter` and `map`, `merge` into a list
  accumulator refused, `Dict.copy` inside an `update` callback refused.
- **At the end** (about 255 programs and 25 hand probes: `remove`'s position reused across writes at
  one key local, removes in folds and recursion, sharing one level down, every routing form — pipe,
  method, alias, partial application, a writer in a record field — release `Set` boxes, `put`'s
  storage, v2's keyed rule): **no fault**. Three defects, none of which lets a write through:
  `Dict.insert` skipped a store of a value `===` to the one there, so `-0` over `0` kept `0` (fixed,
  `Object.is`; `run/DictInsertNegativeZero`, red before the fix); a stale comment of
  `recordOwnWords3` (fixed); and walked writers called method-style or through a local alias are
  accepted but never routed, so they copy and the oracle cannot test them (#2571). v2 is stricter than
  before, not looser: a list put into or taken out of a dictionary escapes to it.

## 9. The representation measurement

The owner asked for the representation to be measured on big-table against tea-inline, with S2's
bar: every table operation at most 1.2× vanilla, swap at most 1.0×. beni's own big-table cannot be
built yet: it needs S2's keyed `For` lowering (`browser-inline.md` §9), which is not built. So the
measurement is S2's target as the research emitter writes it (`plans/inline-s2/emit/bt-s2.js`,
switches `gdlyvhcwp`: rows in a `Dict` with the pair index, the representation built here), against
the research project's `vanilla` and `tea-inline`, by `plans/inline-s2/tools/bench.mjs` (the research
harness's event timing, script µs, median), big-table N = 1 seed 1, quick mode, 3 rounds, one Chrome,
order reversed each round. The machine had a load of about 10 from other work: indicative, as
`plans/inline-s2/cpu.md` is.

    event                                 vanilla   tea  s2pair  tea/van  s2pair/van
    create 1000 rows                         3577  4271    4499     1.19        1.26
    clear 1000 rows                          3047  2724    2816     0.89        0.92
    replace 1000 rows                        5947  6602    7098     1.11        1.19
    update every 10th row of 10000           1435  3141    3525     2.19        2.46
    select row 3                               32    35      36     1.09        1.13
    select row 2                               30    33      31     1.10        1.02
    swap rows                                  48    72      63     1.50        1.31
    swap rows back                             52    88      60     1.69        1.15
    remove the 4th row                         59    64      58     1.08        0.98
    create 10000 rows                       29788 40258   46663     1.35        1.57
    clear 10000 rows                        28899 28773   28486     1.00        0.99
    append 1000 rows to 10000                3621  4328    4427     1.20        1.22
    serverUpdate of 10 rows                    94   126      96     1.34        1.02
    serverUpdate of 10 rows back               94   128      94     1.36        1.00
    dispatch: whole-state snapshot            871  2052    2260     2.36        2.59
    dispatch: whole-state snapshot (again)    874  1978    2124     2.26        2.43

Against the bar: removal, select, clear and serverUpdate are within it (removal is 0.98×, where the
position index of `cpu.md` was 1.86×); swap is 1.15–1.31× (bar 1.0×), and create, append, update
every tenth and the snapshot are above 1.2×, as tea-inline's own are (1.19–2.36×). Where tea-inline
misses the bar the cost is the architecture's, not the dictionary's; where the target is above
tea-inline (create 10 000, swap is below it) it is the per-row `Map` entry and the pair. A quiet-machine
run by the full method is S2e's (`browser-inline.md` §9.9).

## 10. Timing

`bench/ownership-v2-review.mjs --checkers=v3 --runs=3 --jobs=1 --roots=real`, a load of about 10:

- ReleaseFast LLVM, the lane's compiler: v3 on the 33 real roots **1 548 ms** (572 097 lines, 369k
  lines/s). `platforms/browser` is 693 ms of it, `examples/conduit` 114 ms.
- ReleaseSafe, base and lane, the same machine, both on the lane's sources: on the 30 roots both
  compilers read alike, **7 820 → 7 821 ms**. The base compiler cannot read the lane's `core`,
  `bench/corpus` and `platforms/browser` (`Dict.empty ⊤`, the `keyed` word) and judges nothing there;
  the lane spends 483, 541 and 7 378 ms on them, with 190, 153 and 18 demands.

## 11. Slices

| Slice | What | State |
|---|---|---|
| 1 | the representation, v3's rows, v2's keyed rule, docs | landed |
| 2 | the oracle: `Dict` and `Set` writes routed, walked writers, `listAt` | landed |
| 3 | kernel §12, `remove`'s position, `dicts.mjs` | landed |
| 4 | `Dict.update` with a value-writing callback: a `focus` row (#2570 item 1) | open |
| 5 | get, write, insert at one key; folds of nested lists; `size` reads only the storage (#2570) | open |
| 6 | v3 enforced, so production writes in place (#2569) | open |
| 7 | route method-style and aliased walked writers (#2571) | open |

## 12. Reproduce

```sh
node bench/ownership-sweeps/dicts.mjs <dir>/dicts
node bench/ownership-sweeps/run.mjs --beni=zig-out/safe/bin/beni --checker=v3 --mode=both --jobs=16 --tmp=<disk> <dir>/dicts
TMPDIR=<disk> node bench/ownership-v2-review.mjs --beni=zig-out/safe/bin/beni --checkers=v1,v3 --runs=1 --roots=real
```
