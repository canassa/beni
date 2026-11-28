# 161 — Dictionaries under v3: every call form routed, and shallow reads

*Research report, 2026-11-19. The second `Dict` lane after research report 160: #2571 (oracle
coverage) first, then #2570 (precision). Kernel §12 holds the rules: item 5 (*Lowering*, *Every
form of a call is routed*) and the new item 7 (*A shallow read*). #2569 (v3 enforced in
production) is not in this report.*

---

## 1. Result

- **#2571, closed.** A writer of `Dict`, `Set` or `List` that v3 accepts is routed through the
  oracle in every call form: method-style (`d.update k f`, `d.sortBy f`, `s.insert x`), through a
  local alias (`upd = Dict.update`), handed on as a value (`apply Dict.insert d`), and a `sortBy`
  whose callback parks. No verdict moved.
- **#2570, part.** A new v3 word, `shallow`: a row that reads a dictionary's storage and never a
  value's contents. Items 1, 2 (in a helper) and 4 are won; items 2 (in one frame, inside a
  `case`), 3 and the nested fold are declined, each for a stated reason (§4).
- **Two representation faults fixed** (blind round AK): `Dict.eq` compares keys as the index
  does, and has no identity shortcut (§5).
- **No soundness fault** in the sweeps (§7) or in either review (§8). One oracle fault found by
  the first review (a parking writer handed on as a value) is fixed.
- **Ledger** 309 of 319, row for row as before; v3's refusals at positions with no v1 line
  31 → 27. **Accepted → refused on any root: 0.**
- **Timing** on the real roots: the same (§9).

## 2. #2571: every call form is routed

**The rule** (kernel §12 item 5). What the checker judges is the call of the value the callee
names, not its spelling. So the lowering channel names the call however it names the writer
(`Enforce.coreCallee`): a `method_call` whose dispatch term is the writer, and a `call` through a
chain of locals a `let` binds to it, as `Lower.listWriterOf` already followed for the lowering.
**A writer handed on as a value** writes where the callee runs it; those writes are judged at
the call that hands it (§6 rule 2: the value flows to the callee's contract, a written location
it is handed is a demand of that call, a cell the callee made and reads after is `supply`; a
callee that keeps or loses it puts it in the default location, which refuses a writer, rule 8).
So where that call's line is accepted, the lowering hands `_sanitize$writer(site, value)`
(`Enforce.handsCoreWriter`, `Lower.routeWriterValues`). A writer that takes evidence and may
park is `_sanitize$startAt`, the wait, then `_sanitize$settle` (`Lower.sanitizedWriteAt`, both
runtimes), as a parking list write is.

**Not routed, by design:** a writer value handed to a call that has no line, or kept anywhere
but at a call's argument (no line judged it); and a writer that takes a callback (`update`,
`sortBy`) handed on as a value: its callback may park where the callee runs it, and the value
then answers a `Task`, which a write routed per call cannot settle (the first review's finding,
§8). Each is the plain function, which copies.

**Evidence.**

- `run/DictWriterRouting` (`.sanitize-lists-v3`): every form, nothing read after; SAME in all
  legs. With the routing reverted the corpus fails it: v3 accepts `47:17 Dict.update`, `48:17
  Dict.sortBy`, `52:32 Set.insert` and the parking `56:9 Dict.sortBy`, which the sanitised build
  does not wrap (the site check now counts `Dict` and `Set` writers under v3). Its `applyP
  Dict.sortBy` line, a parking callback writer handed on as a value, trapped in the release
  in-place leg before the first review's fix.
- `run/DictWriterRoutingLive` (`.sanitize-lists-v3-refuses`): each base read after; v3 refuses
  all ten. With v3's later-read test broken (`Frame.useReaches` answering "no", a mutant not
  committed) all ten are accepted, the sanitised build traps and the in-place build prints other
  lines.
- `dicts.mjs` gains the writers `mUpd`, `mSort`, `aUpd`, `aSort`, `vIns`, `vUpd`, `park` and the
  `Set` writers `mIns`, `mSort`, `aIns`, `vIns`: 2 400 programs. Real v3: every live twin refused,
  0 faults. The mutant: 1 436 live twins TRAP (and DIFF in place), every routing form among them.

## 3. #2570: the shallow read

**The fact.** A later read that sees a write is one that observes the written cell's contents
(§5, test 4). Most of `Dict`'s primitives never do: `size` reads the entries array's length,
`has` the index, `keyIndex` and `isIndex` a key or the length (a key holds no cell), and `copy`,
`insert`, `remove`, `swap`, `insertAt`, `permute` and `put` move each value by its reference
(`cloned` copies the pairs, not the values). `insert`'s `Object.is` compare of the value at its
key with the one it stores only decides whether a store of that same reference is skipped:
either branch leaves the handed value at the key.

**The rule** (kernel §12 item 7). The v3 word `shallow` on such a parameter: the row reads the
parameter's storage location and no location below it (`Check.wordedContract`, `shallowParam`).
What the row answers or stores of it is read where the caller reads the answer, as before, so a
value written in place and then answered by `copy`, or kept at another key by `insert`, is read
when the answer is read. Lowering accepts the word once on a parameter, a value, that the words
read (`borrowed` or `written`), in v3's column (`own_shallow_word`, a new reading of
`misplaced_ownership_word`); v1 and v2 read the rows as before. `valueFor`, `valueAt` and
`traverseAt` hand a value out and carry no `shallow`; `List.length` is as shallow and is not
marked here.

**What it wins.**

| #2570 item | Shape | Now |
|---|---|---|
| 1 | `Dict.update d k λm → Maybe.map m λxs → List.push xs 5` | accepted where nothing reads `d` after: `update`'s own `insert` no longer reads the value the callback wrote |
| 2 | get, push the value, insert at its key, in a helper | accepted (`ownership/Toplevel` 51:31 `bump`, refused before) |
| 4 | `Dict.size d` after a push of a value taken out of `d` | accepted (`ownership/DictValueWritten` 14:15, accepted → refused in report 160, accepted again) |

Real roots: `bench/corpus/FormValidation` 275:13 (the fold of `Dict.update`) and 276:17 (its
callback) and `bench/corpus/NotesApp` 107:17 and 110:13 (`editSelected` with a callback that
writes a note's `tags` set, now a parameter demand like 100:13's, which the caller judges) move
from refused to accepted demands.

**Evidence.** `run/DictShallowReads` (`.sanitize-lists-v3`): the three shapes, SAME in all legs;
refused before the change. `run/DictShallowReadsLive` (`.sanitize-lists-v3-refuses`): the old
value read after each write, five refusals; under the mutant (with `shallow`) the sanitised build
traps and the in-place build prints other lines. `dicts.mjs`'s `updPush` dead twins: 32 of 56
SAME (all refused before); the new writer `bumpAt` (the helper form): 32 of 56 dead SAME; every
live twin of both refused, and under the mutant 320 of their live twins TRAP.

## 4. Declined

- **Item 2 in one frame** (`case Dict.get d k of Just xs → Dict.insert d k (List.push xs 5);
  Nothing → d`, then the answer's values read): refused at the push. The `Nothing` arm answers
  `d`, and the joined answer's values are read as held after the write, though the arms are
  alternatives. `List.get` and `List.set` meet the same join (probe in the lane), so it is the
  join's rule, not the dictionary's; the helper form (§3) is accepted.
- **Literal keys** (`Dict.get d 1` then `Dict.insert d 1`, `dicts.mjs`'s `getPush`): a literal is
  no local, so no position (item 8 of the review list, not in this lane's items).
- **Item 3**, folds whose accumulator holds lists of the items (`DictExtra` `groupBy`,
  `invert`, `fromListWith`, `unionWith`: 22:5, 55:30, 60:32, 64:15): the callback answers
  `[ item, …group ]`, which holds an element of the items list at the summary location
  `[*][*]`; a `List a` can hold one cell twice, so the answer can hold one cell at two places,
  and rule 8 asks the whole answer to be the function's own. A rule that asks it only at the
  locations the function or the callee writes is a change of §6 rule 8, not a fact of `Dict`.
- **NotesApp 261:11**, a fold inside a fold's callback (`Set.foldl note.tags counts count`): the
  callback answers what the inner callee handed back, which rule 8 does not read as own.
  `List.foldl` inside `List.foldl` is refused the same way (probe in the lane): not `Dict`'s.
- A walked writer handed on as a value (`applyU Dict.update d`, `dicts.mjs`'s `vUpd`) is refused
  `later-use` where its answer is read: its contract answers its parameter, not a new name of it.

## 5. `Dict.eq` (blind round AK)

`keySame` was `===`, but the index is a `Map` (SameValueZero), so a NaN `Int` key is one key to
`get`, `member` and `fromList` and was no key to `eq`: a dictionary was not equal to its copy,
and two `[ nan ]` sets differed. It is now `a === b || (a !== a && b !== b)`, and `Dict.beni`
says keys are compared as the index identifies them. And `eq` began with `same left right ||`,
so a dictionary holding a Float NaN equalled itself but not its copy; `List.eq` has no shortcut,
and now neither has `Dict.eq` (`same` is gone). `run/DictNanKeyEq` and `run/DictEqNoShortcut`
print what round AK's programs printed differently before (`eq copy: False`, `dict self:
True`). Kernel §12 item 5 also says now that a writer answers its argument itself where nothing
changes (`insert` of the value there, `remove` or `swap` of a missing key), an answer under a new
name as any other.

## 6. Verdicts before and after

`dump --stage=ownership --ownership=v3 --ownership-everywhere` of all 2 886 roots (2 888 after,
two fixtures new) with the base compiler (1eb9d80c2d) and the lane's, on the lane's sources,
compared per demand; `core`'s `Dict` and `Set` modules (reformatted, 34 lines moved) left out:

| Change | Lines | Where |
|---|---:|---|
| accepted → refused | **0** | |
| refused → accepted | 2 | `ownership/DictValueWritten` 14:15, `ownership/Toplevel` 51:31 |
| absent → accepted | 58 | the new fixtures; `FormValidation`, `NotesApp` (§3); callsite demands that replace a refused `value` line (`DictFold`, `DictEdits`, `FoldAccumulators`, `DictFocus`, `tea/DictFold*`) |
| refused → absent | 27 | those `value … supply` lines, now one demand per location |
| absent → refused | 22 | the live fixture; the same fixtures' sharing, now refused at the location that is shared (`FoldAccumulators`' `shared`, `DictTupleFocusSharing`) |
| accepted → absent | 10 | `run/DictWriterRouting`'s lines, moved by its new line |

The base compiler cannot read the lane's `core/Dict.beni` (`shallow`), so the `core` root is
judged by the lane alone.

**The ledger** (`bench/ownership-v2-review.mjs --checkers=v1,v3 --roots=real`): of the 319 list
writes v1 judges, v3 accepts **309** and refuses the same 10, row for row. v3's refusals at
positions with no v1 line: 31 → 27 (FormValidation 275:13 and 276:17, NotesApp 107:17 and
110:13).

## 7. Sweeps

`run.mjs --checker=v3 --mode=both` with the lane's ReleaseSafe compiler: plain, the sanitiser,
in place, and `--release` plain and in place.

| Sweep | Programs | SAME | REFUSED | Faults | Other |
|---|---:|---:|---:|---:|---|
| `dicts.mjs` | 7 164 | 779 | 6 385 | 0 | every live twin refused |
| `records.mjs` | 1 876 | 353 | 1 523 | 0 | |
| corpus | 1 810 | 1 262 | 527 | 3 | 12 BOTHFAIL, 4 PLAINFAIL, 1 LIMIT, 1 TIMEOUT |

The three corpus faults are the known `run/ListSanitiserTrieHolder` and `dom`/`tea`
`ShowAndBranches` (#2504). The TIMEOUT, `run/TailModConsMerge`, is the 20 s limit under a load
of about 12; alone it is SAME in every leg.

## 8. Reviews

Two fresh adversarial readers (Opus), each told to write programs v3 accepts whole that trap or
differ under the four legs.

- **After #2571** (eight batches: writer values kept, returned, stored, called twice, handed to
  `List.map`, `foldl` and `Maybe.map`; pipes, partial application, user methods, aliases;
  parking `sortBy` with a fiber reading the base; NaN keys and values; `-0`): no checker fault.
  **One oracle fault**: a writer that takes a callback, handed on as a value, whose callback
  parks (`applyS Dict.sortBy d`, `applyU Dict.update d`, `Set.sortBy`, `List.update`) was wrapped
  in the synchronous `_sanitize$writer`, which then met a `Task`: the in-place legs trapped, or
  stored the `Task` in the list. Fixed: such a value is not routed (§2), `run/DictWriterRouting`
  holds the case. Precision notes: a writer value stored in a list is refused (by design).
- **At the end**: §8.1, no fault.

### 8.1 The second review

About 110 programs, each checked to be routed in place where it was SAME: a write in place and
then each shallow operation whose answer holds the old value (`copy`, `insert` at another key,
`remove`, `swap`, `insertAt`, `sortBy`), in both orders and one level down (a dictionary of
dictionaries); the old name stored instead of the new; one list at two keys by every route
(refused at the construction, `element`); values aliased in a list, a closure, `values`,
`union` or a copy; records and sets as values; reads that are not shallow (`==`,
`Debug.toString`, `toList`, `filter`, `foldl`, `map`); a fiber that captures the dictionary
across a parked write; `core/Dict.js` read against the claim. **No fault.** Precision notes: a
record taken out of a dictionary and updated is refused where its answer is read, though the
same with `List.head` is accepted (#2572, not `shallow`'s: refused with no `size` read too);
`insertAt` at the key just taken, a `remove` or `copy` before the `insert`, a key in a
record field or a local alias, a get, write and insert in one frame through
`Maybe.withDefault`, a `sortBy` callback that writes its value, and an `update` callback that
reads `Dict.size d` (`disjoint`) are refused. The reviewer once deleted a result file of its own
in its scratch, against the brief's rule.

## 9. Timing

`bench/ownership-v2-review.mjs --checkers=v3 --runs=3 --jobs=1 --roots=real`, ReleaseFast LLVM,
base and lane, a load of about 1 with the second review running: on the 32 roots both read alike,
**1 527.6 → 1 516.8 ms** (the same, within noise). On the `core` root the base compiler reads 18 707
lines and judges no demand (it cannot read `shallow`); the lane reads 22 619 lines and judges 189
demands in 43.7 ms.

## 10. Reproduce

```sh
node bench/ownership-sweeps/dicts.mjs <dir>/dicts
node bench/ownership-sweeps/run.mjs --beni=zig-out/safe/bin/beni --checker=v3 --mode=both --jobs=16 --tmp=<disk> <dir>/dicts
TMPDIR=<disk> node bench/ownership-v2-review.mjs --beni=zig-out/safe/bin/beni --checkers=v1,v3 --runs=1 --roots=real
```
