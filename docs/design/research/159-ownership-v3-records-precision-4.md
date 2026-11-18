# 159 — Ownership v3: records precision, round 4

*Research report, 2026-11-18. The fourth lane of the records precision round of the checker v3
(`--ownership=v3`, `src/own3/`): the walls research report 158 located, turned into wins. Issues #2563,
#2564, #2532 (item 2) and #2550 (item 1). It revises kernel (`ownership-v3-kernel.md`) §4.4, §6 rules 10 and
13, §8 and §9.*

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
- **Sweeps** (§8), **reviews** (§9), **timing** (§10).

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
`browser/tea/EntrySwapShared` (an arm that answers `w` at both places: refused).

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

SWEEPS

## 9. Reviews

REVIEWS

## 10. Timing

TIMING

## 11. Reproduce

```sh
node bench/ownership-sweeps/precision-159.mjs <dir>/p159
node bench/ownership-sweeps/run.mjs --beni=zig-out/safe/bin/beni --checker=v3 --mode=both --jobs=20 --tmp=<disk> <dir>/p159
TMPDIR=<disk> node bench/ownership-v2-review.mjs --beni=zig-out/safe/bin/beni --checkers=v1,v3 --runs=1 --roots=real
zig build test-blackbox-corpus -Dcorpus=ListGetSet   # and TreeInsert, EntrySwap
```
