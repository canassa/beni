## 2026-10-31 03:14 CET — own2: a pattern's positions keep their split

**What I did.** Fixed #1390, two over-refusals of v2 where v1 accepts with `xreq excl π1`.
- *Parts* (`ownership-v2.md` §2.2). A projection of a refinement is now `part r·q`: a symbolic
  cell anchored at the position, with `q` a canonical path from the position's place. So
  `[ W a _, W c _ ]` gives `a` and `c` two cells below two sides of one split, not the one cell
  `π1[*]#W.0`. The tuple and record variants are the same. `Cell.alias` compares two chains
  from their deepest common cell, and it climbs both to equal depth first, so the fixed
  64-deep chain stack is gone.
- *A match on a rest* (§2.13.3). Where the matched value's `[*]` holds `others(c·ι)`, the
  inner pattern splits that `others` cell instead of `c` again. The new refinements carry
  `Cell.positions_bit`, which says that they add no step to the canonical position. A place
  comparison did not work: a cast puts a cell at a place that is not its own (CastCallHolds).
- Fixtures `ownership/PatternPositions` and `PatternPositionsImported`, with v1's goldens.
  They cover the constructor, tuple and record parts, the nested and two-level rests, a head
  beside a call on the rest (#1409's non-recursive shape), and the refused twins: one
  position twice, a box shared by a constructor, a tuple or a record, and two crossed lists
  of a record. On master's `src/` both fixtures fail, with 15 and 16 differing verdicts.
- `twoMatches` (two matches of one rest, which can take one position) is refused by v2 and
  accepted by v1, which is unsound there. It has an entry in `ownership-v2-known.txt`.

**What I learned.**
- The parts made `build_test`'s flat-per-position test fail. With
  `[ List.push p1 1, … ]`, each position now brought its `part(eᵢ)·[*]` into the literal's
  `apart`, and both `Cond.aggAdd` and `sameBasePairs` paired those parts across positions,
  so the cost grew as n². The fix, in `Cond.splitKey`, `sameRun`, `sameAnchor` and
  `covered`, has three parts. A part runs with its anchor's split. A part below another
  arrival is left out. Two cells of one anchor make no same-base pair, as two symbolic cells
  make none. My first version gave the left-out part `lost`, and the random-aggregate
  differential in Cond's tests caught that. A split's sides can answer `shared`, and
  `shared` outranks `lost`, so only parts can be covered, never refinements. The
  per-position cost now grows 8% from n = 10 to 80, and master's grows 7%.
- The ViewBelow goldens now name the holder `r` or `r[*]#M.0`, where they named `r[*]`. The
  rest now acts as the list does in the flat case, which names `kids`.
- The gates took 1 min 30 s each time, not the ~10 s that CLAUDE.md gives. A Debug dump of
  the 1 015 ownership/run/core roots takes about 30 s with 8 jobs.
