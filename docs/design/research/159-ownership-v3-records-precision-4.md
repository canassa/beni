# 159 — Ownership v3: records precision, round 4

*Research report, 2026-11-18. The fourth lane of the records precision round of the checker v3
(`--ownership=v3`, `src/own3/`): the walls research report 158 located, turned into wins. Issues #2563,
#2564, #2532 (item 2) and #2550 (item 1). It revises kernel (`ownership-v3-kernel.md`) §4.4, §6 rules 10 and
13, §8 and §9. The second review's fault is §5's, fixed (§9).*

---

## 1. Result

| Issue | Rule | Won | Left |
|---|---|---|---|
| #2563, get then set | a v3-only word `position` on `List.unsafeGet` and `List.set`; a caller reads such sources at the two positions of a match of the list and the index local (§2) | Sternhalma `Main` 114:13 (and its corpus page); `getset` dead twins `same`, `fold`, `back` | `Dict` rows (§2.3); Sternhalma 101:5 (another wall) |
| #2564, the first via | an atom records the last root it was read through too; a linear root tells two of its entries apart (§3) | a red-black tree of a user's own type built by `insert`: `rb` dead twins `distinct`, `param`, `replace` | `core/`'s `Dict` read at an instance (`Dict Int R`): the call map reads its deep level as `Loc.all` (§3.2) |
| #2532 item 2, budgets | five loops that cost a whole layout at each location of a result look up instead (§4) | **real ledger 294 → 296**: `Gpu.Make` 889:15 and 1094:7, and `Gpu.Device` 167:34 | a contract that says "these sources at every location" once |
| #2550 item 1, field swap | the entry rule asks "at no other location" of one value of `update`'s answer at a time (§5) | the blind round's `arms` family: 58 refused → 0 (200 `SAME`); `entry` dead twins `swap`, `rotate`, `swapnested` | `swaprow` (a row helper); the other items of #2550 |
| #2546, #2518 | not built (§6) | — | — |

- **Real-writes ledger** (`ownership-v2-review.mjs --checkers=v1,v3 --roots=real`): **294 → 296 of 308**, row for row;
  the two rows are `platforms/browser` `Gpu.Make` 889:15 `construction targets` and 1094:7 `construction vertex`,
  which had no line (the module passed its budget). v3 refusals at positions v1 has no line for: 18 before and after.
- **Verdicts on every ownership root** (§7): refused → accepted 2 lines (Sternhalma's `value <call List.foldl>`
  at 114:13, in two roots, now absent), absent → accepted 3; **accepted → refused 0**.
- **Sweeps** (§8): 90 320 programs under the four legs, the three known faults only.
- **Reviews** (§9): the first found no fault; the second found one in §5 (a consumer's kept location taken away
  after the taking away), fixed with a fixture (`browser/tea/EntrySwapKept`).
- **Timing** (§10): `platforms/browser` takes longer, as its `Gpu` modules are now walked to the end.
- The straight-line chains of writes the blind reader of report 158 added to #2534 are not made linear here.

## 2. A position (#2563)

### 2.1 The word

`List.get l i` … `List.set l i v` replaces the element that the `get` read, and no word said so: `set :
written returned List a, borrowed Int, stored a → List a` is as true of `insertAt`. Kernel rule 11 forbids
reading `List.set` by its name, and `Ast.OwnWord` is `enum(u5)` and full. So the word is new, and only v3
reads it: `Ast.OwnWord3` (`position`), kept in a BIR column of its own (`Bir.Decl.own3_start`,
`Bir.ownSlotsV3`); the signature's other words stay in v1's or v2's column, which read the row as before.
Lowering accepts `position` on one value parameter after the first, in a signature whose first parameter the
words read as a list (`elementof` result, or `written returned` beside a `stored` parameter); elsewhere it is
`misplaced_ownership_word` (`own_position_word`). Frontend artifact format 31.

`core/List.beni`: `unsafeGet : borrowed List a, borrowed position Int → elementof a` and `set : written
returned List a, borrowed position Int, stored a → List a` (re-justified in `ownership-checker.md` §24.8;
`word-bodies.txt` updated). `focus` needs none: its `taken` element and its callback's stored answer are
alternatives already, and `List.update` with a copying callback is accepted on the base.

### 2.2 The rule (kernel §6 rule 10, *A position*)

A row marks its parameter 0's element sources (`Src.p`: `π1@1[π2]` at the position, `π1@1[≠π2]` at the others).
A caller reads them at a **match** (`Frame.posKey`) of the list and the index local, as report 154's list
patterns: one match for each `(root, path, position, local)` of a frame, where the root holds each cell once
(a parameter, or a `linear` root the frame made with no `twice` entry), the list's location names one value,
and the index is a local the frame bound. Two calls of one match name one array at one index, which no
accepted write can change between them (the second call reads it). A walked body publishes the mark where the
list is one of its parameters whole and the index another's local (`posSrc`), so `List.get`'s answer is
`#Just.0 π1@1[π2]`. At a call whose contract holds a parameter only at its storage and its other positions
(`positionedParam`), the arguments are tested with the argument's elements at the other positions
(`argsApartAt`): `set`'s stored copy may hold the replaced element's parts.

Fixtures: `run/ListGetSetPosition` (refused on the base: the fold `supply`, `element`; `SAME` in every leg) and
`run/ListGetSetShared` (a copy put at another index, and into another list: refused).

### 2.3 Not covered

A `Dict` has no such row: its `get` and `insert` are walked bodies over a tree, and `insert` writes nothing in
place, so no `written returned` row describes it. A read by `set` of its list is a flag of the whole location,
so an element written in place between the `get` and the `set` is still refused. An index computed again
(`i + 0`) or bound again (`k = i`) names no match. Sternhalma's other fold (101:5) answers `setOccupant`'s
board over a `List.filter` of the board's own cells: the arguments are not apart, a wall of its own.

## 3. Two readings through a later root (#2564)

### 3.1 The rule (kernel §4.4)

`Atom.via` is the first root an atom was read through. `balance`'s answer holds the recursive `insert`'s answer
at two of its entries, one in each arm; its claim (`linear`) says those entries hold two cells, but the atoms
copied there name the first root at one entry, so they were one cell and the tree's deep level was `twice`. An
atom now also records the last root and entry (`via2`, `via2_e`, set by `copyAtoms`), and two readings through
two entries of one linear root are two cells (`via2Apart`, read by `viaApart`). The linear-time duplicate test
keys its tables by the first root; where an atom it finds is apart from the one tested by the later root, it
compares each atom of the group (`TablesShare.all`). Safe builds test every set of at most 64 atoms by tables
with no pairs (`checkShare`), so that path runs, and agrees, on every small set.

Fixtures: `run/TreeInsertRebalanced` (refused on the base, `disjoint` and `element`; `SAME`) and
`run/TreeInsertShared` (one record inserted at two keys: refused). `core/`'s `insertHelp` is no longer `twice`
at its deep level.

### 3.2 Left: `core/`'s `Dict` at an instance

A caller reads `Dict k v`'s answer at `Dict Int R`, and the call map reads a deep level that the signature
reads through type variables as `Loc.all` (§4.1, `cycleWider`): the caller's type argument could name the
container again, and one deep location of the caller could hold cells that the signature names at two entries.
So every value of such a dictionary is at both levels of the caller's reading, and a write of one is refused
(report 158's `dict.*` family: unchanged). The fix is a cover that pairs the deep levels by label path where the
caller's type arguments do not reach the cycle's head; it is a change to `Loc.cover`, not attempted here.

## 4. Budgets (#2532 item 2)

`Gpu.Make.checkedIn`'s `Result Error.Error V` has 711 locations, each holding every location of its parameters
(the answer of unknown code). Sampled stacks (a stack every 20 000 units) put its units, and then those of
`checked`, which calls it, in five loops that cost a whole layout or a whole value at each location
(kernel §8, *The result is read once for each of its locations, and costs what it reads*):

| Loop | Now |
|---|---|
| `finish` walked an `unknown` arm's leaves again for each location | `Frame.finished`, `whole_at`: once after the walk |
| `leavesSet` scanned the call map for one location | `coverHits`, the map read the other way, once for each pair of layouts |
| `ownAnswer` scanned the map for each answer location | `coverHits` |
| `expandSrcs` read an argument's atoms at a parameter entry for each result location | `argLeavesKept`: once for the call's result (`paired_gen`) |
| `slotHeld` scanned the argument's layout for each slot | `SlotIndex`, once for each layout in a frame; safe builds compare with the scan |

The answers are the scans'. `checkedIn` 2.5 M (its budget) → 1.1 M; `checked` 1.54 M → 0.84 M of 1.4 M. `Gpu.Make`
is judged and its two writes are accepted. `Gpu.Batch.inBatch`, `Gpu.Device.made`, `Gpu.Shader.compile` and
`tests/platforms/gpu`'s `readAt` pass theirs too; four declarations of `Gpu.Device` and `Gpu.Diagnostics` now
reach theirs, because the modules before them are walked, and their contracts read, where they were not.
No verdict of any ownership root moves but the three it gains.

## 5. One value of the answer at a time, in the entry (#2550 item 1)

`paramOwn` (kernel §6 rule 13) asked that a model location be answered at no other location of `update`'s answer,
across all its arms. A field swap in one arm (`{ m | w = m.w2, w2 = m.w }`) and a write of `w` in another took
`w` out of `own`, and every later write of it was refused. A run answers one value of the join, and where the
contract is not `nonlinear` (§4.4, *One value of a join at a time*) no cell of a parameter is at two locations of
any one of them. So the test is skipped where the contract says so; where it can be, every other location that
holds it is another holder, as before.

Fixtures: `browser/tea/EntrySwapArms` (refused on the base, `unknown`; accepted, the page `SAME`) and
`browser/tea/EntrySwapShared` (an arm that answers `w` at both places: refused). The second review found
that the locations a consumer keeps were taken out of `own` after the taking away, so a location `update`
answers from a kept one stayed `own`; the old test had hidden it. They are taken away first now
(`browser/tea/EntrySwapKept`, §9).

## 6. Not built

- **#2546**, chained row-polymorphic setters: the answer of `setf0 r0` is read at the call's own place, the
  instance of `{ r | f0 : Int }`, whose layout has one wide entry for the row; `setf1`'s write of `f1` is then
  the whole row, and a later read of `r2.l` reaches it. The fix is in the place of a call whose row is
  resolved (the adapter of `own2` that v3 calls), which v2 shares.
- **#2550**, the other items; **#2518**: not reached. The blind round's `long` family (`List.foldl` over a
  state record) is refused for a real share (`Record.copy cur` keeps `cur.l` at two places), so its refusal
  needs a finer `answerOwn`, not a fix.
- The remaining real rows: the entry rows of Conduit and `todo/page` take `model.todos` from the message, which
  rule 13 never makes `own`; `FormValidation` calls validators taken out of a list (function values in a
  container are code with no contract); `Tea` 506:5 and `FormValidation`'s `Dict.update` are walls of their own.

## 7. Verdicts on every ownership root

`dump --stage=ownership --ownership=v3 --ownership-everywhere` of all 2 868 roots of the base and the 2 874 of the
last commit (six new fixtures), compared line by line (`core` dumped from the base's own `core/`):

| Root | Change | Rule |
|---|---|---|
| `examples/sternhalma`, `browser/tea/Sternhalma` `Main` 114:13 `value <call List.foldl>` | refused → absent | §2 |
| `platforms/browser` `Gpu.Make` 889:15, 1094:7; `Gpu.Device` 167:34 | absent → accepted | §4 |

**Accepted → refused: 0.** The via rule (§3) and the entry rule (§5) change no root but their fixtures.

## 8. Sweeps

`run.mjs --checker=v3 --mode=both` with the ReleaseSafe compiler of the lane: every generator of the folder,
the fault folders, `harvest-v2-records` and the corpus. The families from `precision-159` to `blind4a` ran on
the compiler before the entry fix of §9 (which only refuses more), the rest on the last commit.

| Sweep | Programs | SAME | REFUSED | LIMIT | Faults | Other |
|---|---:|---:|---:|---:|---:|---|
| `corpus` | 1 797 | 1 253 | 523 | 1 | 3 | 12 BOTHFAIL, 4 PLAINFAIL, 1 TIMEOUT |
| `folds-callbacks` | 30 300 | 5 669 | 24 631 | 0 | 0 | |
| `recursive-levels` | 16 131 | 3 869 | 12 262 | 0 | 0 | |
| `blind` | 9 792 | 1 683 | 8 109 | 0 | 0 | |
| `blind4b` | 6 596 | 1 350 | 5 244 | 2 | 0 | |
| `aliased-arguments` | 5 160 | 1 270 | 3 890 | 0 | 0 | |
| `precision-159` (`getset`, `rb`, `entry`) | 47 | 11 | 36 | 0 | 0 | every `live` refused |
| 44 other sweeps and fault folders | 20 497 | 5 222 | 15 114 | 14 | 0 | 123 PLAINFAIL, 24 TIMEOUT |
| **all** | **90 320** | 20 327 | 69 809 | 17 | **3** | 12 BOTHFAIL, 127 PLAINFAIL, 25 TIMEOUT |
| the blind round's `arms` (#2550) | 200 | 200 | 0 | 0 | 0 | 58 refused on the base |
| the second review's programs, on the fix | 357 | 70 | 284 | 0 | 0 | 3 PLAINFAIL |

The three are the known `run/ListSanitiserTrieHolder` and `dom`/`tea` `ShowAndBranches` (#2504). Against report
158, `blind4b` and `blind` give the same rows; `precision-159`'s dead twins won on this lane: `getset.same`,
`.fold`, `.back`; `rb.distinct`, `.param`, `.replace`; `entry.swap`, `.rotate`, `.swapnested` (each refused on the
base).

## 9. Reviews

Two fresh adversarial readers (Opus), each told to write programs that the new rules accept and that trap or
differ under the four legs.

- **After §2 and §3** (about 470 programs: get then set with lists that hide a duplicate in 30 ways, views,
  helpers that shift the index, sets between, folds; red-black trees with values at two keys, 75 mutants of
  `insert`/`balance`, chains of 8 to 150 keys): **no fault**. Every unsafe twin refused; 14 safe programs newly
  `SAME`. It noted that nothing seen from outside shows the duplicate test's `.all` path ran; safe builds test
  every set of at most 64 atoms by tables alone (`checkShare`), so that path runs, and agrees, on every small set.
- **At the end** (about 350 programs of its own, and a comparison of verdict lines between the compilers before
  and after §4 and §5 over 1 564 programs): **one fault, in §5**, fixed. The entry rule took the model
  locations a consumer keeps out of `own` after the taking away, so a location that `update` answers from a kept
  one stayed `own`; the cross-arm test of "no other location" had hidden it. `Keep model.w` in a message of
  `view`, `Swap`, then a write of `w2` in place: `TRAP` (records and lists, a swap or a plain move). Fixed by
  reading the consumers first (kernel §6 rule 13, *What a consumer keeps is taken away before the taking away*);
  fixture `browser/tea/EntrySwapKept` (accepted and trapping with the entry fix reverted; refused now). Its 357
  programs rerun on the fix: no fault (the three fault programs refused). It found nothing against §4: the only
  verdict differences between the compilers before and after §4 are §5's entry lines, and the safe-build checks
  of `coverHits` and `slotHeld` did not fire. It also noted that a `REFUSED` verdict stops the oracle, so an
  unsound acceptance beside a refusal in one program is seen only by a comparison of verdict lines.

## 10. Timing

`bench/ownership-v2-review.mjs --checkers=v3 --runs=3 --jobs=1 --roots=real`, ReleaseFast LLVM compilers of the base
and of the lane (before the entry fix, which changes one loop's order). **The machine ran a sweep at 24 jobs at
the same time**, so the absolute figures are about 2.4 times report 158's; the two runs are comparable with each
other only. v3 on the 33 real roots, `core` left out (the base cannot parse the lane's `core/` there): **3 151.8 →
3 885.1 ms**. All of it is `platforms/browser`, **1 123.1 → 1 820.2 ms**: `Gpu.Batch`, `Gpu.Make`, `Gpu.Device` and
`Gpu.Shader` are now walked to the end where a budget stopped each, and the modules after them read their
contracts. Every other root is within ±40 ms (Conduit 311.5 → 274.6). A walk past a budget does none of this
work, so the cost is of the modules judged, not of the rules.

## 11. Reproduce

```sh
node bench/ownership-sweeps/precision-159.mjs <dir>/p159
node bench/ownership-sweeps/run.mjs --beni=zig-out/safe/bin/beni --checker=v3 --mode=both --jobs=20 --tmp=<disk> <dir>/p159
TMPDIR=<disk> node bench/ownership-v2-review.mjs --beni=zig-out/safe/bin/beni --checkers=v1,v3 --runs=1 --roots=real
zig build test-blackbox-corpus -Dcorpus=ListGetSet   # and TreeInsert, EntrySwap
```
