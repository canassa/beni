## 2026-10-30 19:19 CET — own2: D costs nothing without D

**What I did**

- #1348's review, three fixes in new commits. `Summary.Table.deepRead`
  interned the `D` mark on every call (`internCell` reserves a cell record
  even for a hit), at each `marksAt` step, holder cursor step and graft
  entry, and every read-off built `{R, D}` up front. `Cell.Table` now keeps
  the `R` and `D` mark cells once made, `deepRead` tests membership against
  them and answers `false` at once when no `D` exists, and the graft makes
  `{R, D}` at its first deep read.
- Counts against master on generated programs: a 100-helper shallow chain,
  a 30-level doubling DAG, a 40-field record and their callers, and a
  100-deep field chain (`f100` 349, continuation 337 of 5 120) are equal to
  master's on every declaration. Before the fix each declaration paid +6.
  Over the ownership and run corpus, 903 dumps are byte-identical to
  master's, account lines included; the 39 that differ are exactly the
  dumps where a `D` occurs.
- `BlockRead` answers `Malformed` for a set with `D` and no `R`, with a unit
  test that also reads `{R, D}` back.
- `DeepReadAcrossCall` gains a push of `r.y` followed by a deep read of `r`
  inside the callee: inline (a leaf), through `showAll` (a `D` node) and
  through two helpers, refused `later-use` as in v1. Master v2 accepted the
  two helper cases.

**What I learned**

- An interning call in a reader is a charged record even when the cell
  exists; a reader that must cost nothing on the common path tests a
  cached id.
- `BlockRead.zig` and `Cell.zig` sit at their §5 line targets too.
