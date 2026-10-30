## 2026-10-30 22:45 CET — own2: a group port keeps its unchanged structure

**What I did**

- Built two of the four cost fixes the profiling on #1372 and #1368 asked for, in `Shape`:
  - `map` interns every image that lies on no knot. A node or delta image is open until its parts are
    mapped; one that reaches no open node is looked up in the intern table (`mapAdopt`), and a knot's
    images stay records of their own. A union, choice or positions image is interned as the record it
    was made as, so `positions(x₁, x₂)` that relabel alike is `positions(x, x)`, two edges.
  - `joinAlternatives`, used by `Transfer`'s branch join and `Summary.joinRes`'s choice mode, flattens
    choice members into one set of distinct alternatives. The member with the most arms (`armCount`)
    is kept whole and the others' arms that its DAG already holds are dropped.
- Unit tests in `Shape`: node identity across maps, two edges kept under positions, a knot's images
  never interned (a control), and the flattening join. The first three of the four fail on master's
  `Shape.zig`; the knot control passes there.
- Measured on a scratch copy of `own2-s3b4a` merged with master and with `widen_rounds` set in
  `solveGroup`: GroupFieldShift 67 434 / 483 630 / 6 288 382 → 20 194 / 78 098 / 385 482 records at
  n = 4 / 8 / 16 (27 s → 1.1 s at 16), `mergeSort` 213 096 → 125 352, the self-map at n = 16
  134 542 → 90 141. Recorded the measured model in §8 (about 60 records per DAG element; a choice
  keeps its alternatives, so the class is about n² edges).
- Corpus diff against master (ownership and run, 1 433 v2 dumps): no verdict or summary line
  changes. 366 of 8 636 accounts change, 45 up by at most 15 records and 321 down by at most 54. The
  crossing counters' `base moves` change in six dumps, and `ViewBelowSweep`'s block keeps its
  7 412 bytes under another hash, because two classes' equal results are one node now.
- Stopped on C (a cap of 2 on a positions count) and D (views of one template joined by environment
  in widen's input). Both need a design decision, reported on #1372 and #1368.

**What I learned**

- Flattening every choice member is quadratic on a tower of joins. K's
  `r_k = if c then Rose [r_{k−1}] else r_{k−1}` rebuilt k arms at level k (the limit at 40 levels,
  caught by the build test's quadratic bound). Keeping the largest member whole keeps it linear.
- `eager`'s rebuild must not flatten. A published value's κ is carried node by node
  (`kappaRelabel`), so an entry keyed by a nested choice the rebuild drops is lost:
  `CallOtherPathsSharedLeaf`'s `chosen` lost its `excl π2[*]`. Only joins that set κ by reading the
  members whole may flatten.
- The summary printer's provenance list is a set per distinct node (#1182). `[ x, x ]` already
  prints `x` once and says two through κ. So the printed `fresh1 fresh1 fresh1` was round copies,
  not a multiplicity, and every κ is unchanged.
- C cannot sit in widen as written: widen is the identity on an acyclic value (§2.3, #1363's guard),
  and `mergeSort`'s `List Int` multiset is acyclic. A cap elsewhere must also say where the κ entries
  of the positions nodes it removes go. D changes the source that §2.9's primitive counts: n
  coexisting views become one, unless the primitive reads a view without forcing it (4c's
  hypothesis node).
