## 2026-10-31 19:05 CET — own2: a written list's own contents

**What I did**

- #1492, fixed. `k [ a ]` with `a = [ 1 ]` was refused `disjoint`. `a` is a `List number`, so at the
  literal's `List Int` element it is a place-only recast, and its projection below is a whole recast
  of the list. That recast's reach holds the list's own cell, so the other-paths walk found the written
  list below itself. The fix is `TransferBeside.ownContents`. At the write's end, for each side that is
  a written position of one route over a built value, it drops that side's own cells which no side's
  parts hold, from everything the walk keeps below the end. A value has no cycle, so this is exact.
  Another position's contents still count, so `elems [ em, [ em ] ]` stays refused.
- Fixtures: `LocalElementContents` and its imported twin. Both fail with master's `src/`, and every
  verdict is v1's. Verdict diff, master v2 against branch v2, over all 2 100 roots: no change. The new
  fixtures add 22 same-verdict demands. The random oracle sweep ran 6 000 programs (locals, literals and
  parameters into `kAll`/`k`/`bumpHead`, `kT`/`pushAllT` over `T a = T (List (T a)) a`, and
  `incAll`/`incLeft` trees). It found 1 423 unsafe programs and 0 unsafe accepts. 294 programs went
  refused→accepted, all in the list family, and none went the other way.
- Opened #1508. `AnsweredAboveElements`' `named` is still refused, now `exclusive`: the call's `xreq`
  reads a recast element approximately (`Calls.zig`).
- #1483, stopped. The root cause is `widen`'s union-find by node id over interned nodes. `Leaf` stood
  at the root and below each first return of `incAll`'s rounds, so their classes were united. A
  prototype that makes a cell-free, part-free node an atom with no class (`settle`) accepts the probe,
  `FoldLevels` 94:23 and `LevelFresh` 46:23 with v1's verdicts, with 0 unsafe in the sweep. But it broke
  four gates: a block round trip (two equal classes intern to one on read), `mPlain`'s κ (now `lost`),
  one more group round (R-7.4's walk count), and #1128's unit test, which only folded through the atom.
  The patch and these findings are on #1483.

**What I learned**

- Interning and union-find by node id don't mix. A shared constant at two paths merges their classes.
  If a knot holds every level, look for a shared atom before you blame the fold.
- My first sweep oracle had a bug that looked like a soundness bug. It took nested `left`/`right`
  flags for root ones, and it reported 4 "unsafe accepts". Read a flagged program by hand before you
  believe the oracle.
