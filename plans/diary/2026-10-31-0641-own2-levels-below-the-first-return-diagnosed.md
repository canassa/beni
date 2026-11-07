## 2026-10-31 06:41 CET — own2: the levels below the first return, diagnosed

**What I did.** I took the rest of #1253: the fresh literals that v2 refuses below
the first return. These are `incT (T [ T [ T [] ] ])`, the distinct twins of 4a's
plan fixtures from #1436, and `LevelRecursiveUpdates` 64:5. The brief gave two
approaches: no fold for an acyclic value, or per-level keys under `⟲`. I traced
the refusal before I wrote any spec. Neither approach touches its cause, so I
stopped after the diagnosis, as the brief says to do when the choice is a design
choice. The probe is on branch `own2-levels-apart-probe`, which is not for merge.

**What I learned.**

- **The literal is not folded.** `positionsAt` walks the built value exactly. For
  `three`, the write's base is the one innermost `[]`. Folding the value differently
  cannot change the verdict.
- **Cause 1: one position has two names on a cycle of two places.** In
  `T = T (List T)`, the lists below the second level are `#T.0[*]⟲#T.0` when the path
  is built step by step. A callee's `⟲` re-rooted at a first return (`incTs`'s
  `[*]#T.0⟲` under `incT`'s `#T.0`) is `extend`'s direct `⟲`, so it is
  `#T.0[*]#T.0⟲` instead. `incT`'s summary has both names (`RW` under one, `R`
  under the other). A probe that re-roots a direct `⟲` through `levelsOf`, when
  `levelsOf` gives one path, makes the summary canonical. That probe alone gives 4
  of the 14 refused positions v1's verdict (CycleJoinRank 36:16 and 40:16,
  FoldSymbolicCall 46:12 and 63:12). Alias's level rule still refuses a held `deep` beside
  the write, so the two names do not open a hole: `( deep, incT t )` is refused
  `alias`. For `B (List B) (List B)`, `levelsOf` gives two paths. A projection would
  then have to make two cells, a change to the `Cell`/`Shape` API.
- **Cause 2: §2.11 item 3's other paths name a position by its node.**
  `keepBeside` keeps the deep reach of every value beside the write. The level's
  own list (`#T.0[*]#T.0`) is an off child of the spine's `#T.0[*]`. Its reach
  holds the written lists, because those lie *below* it by position, though not
  by path prefix. Below a first return, the canonical path pops back to `q⟲`, so
  the spine never passes through that list. A probe that adds a skip of a re-arrival by
  use node gives 9 of the 14 positions v1's verdict. FoldedBCall 66:5 and its
  imported twin (two routes) still differ, and so do FoldedPreimageCall 137:5,
  FoldSymbolicCall 107:5 and 64:5. It also opens three holes
  (`CallOtherPathsKeys` 16:5, `CallOtherPaths` 123:5, `LevelPlacesCall` 44:5).
  It refuses six calls that v2 accepts now: the walkers' own `incTs`/`incRoses`
  calls in five fixtures, and `RoseKidsHeld` 42:21.
  Use nodes are hash-consed, so `{ x = l, z = l }` has one node at `.x` and `.z`.
  The written position must be told by its canonical path. That means a
  path-aware reach for an off value whose positions contain the write's, which
  costs paths in the call's walk (#1325 made the walk by node). Paths can be
  dropped below a place on no cycle, since a fold climbs only through its cycle.
  This keeps doubling types linear.
- **`LevelRecursiveUpdates` 64:5 is a different case.** It is the case that
  #1382's option C was for. `incLeft` answers the right subtrees below `l` at
  `π1#Node.0⟲` and writes the left spine's lists at `π1#Node.0⟲#Node.1`, so the
  callee's summary itself folds them. Only a key per last step (C, K² and
  rejected) separates them. A rule at the caller cannot.
- The K-wide counted build test still passes with the canonical `⟲` probe.

The options, their numbers and a recommendation are in the report on #1253.
