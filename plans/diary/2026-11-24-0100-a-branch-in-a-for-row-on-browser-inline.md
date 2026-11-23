## 2026-11-24 01:00 CET — A branch in a For row on browser-inline

**What I did.** Compiled a branch in a `For`'s row (#2625's first item) on `browser-inline`: an
`if`, a `case`, or a call of a view helper whose body is one, in a row is a branch region of
the row, chosen and prepared with the row's values at every `set`. The row's `set` now
evaluates only the values its writes read (`rowValuesOf`), since the branch's own value is
markup. Spec `browser-inline.md` §9, *A branch in a row*. Pages `RowBranchCase` and
`RowBranch` (copied from `browser/tea`); `build/bad/inline/RegionInRow` became
`RowBranchBeforeText`; `emit/release/inline/RowBranchCase` (4 236 B raw, 1 759 B brotli).
Sweep 176 → 177.

**What I learned.** The region machinery for arms needed almost nothing to serve rows: rows
already kept region state slots, and the refusal was one flag. A helper whose body is a branch
needs its call entered in the row's `set` before `programBranchChoose`. `TodoMVC` now gets past
its rows and stops at a text hole beside an element. Left for #2637: a named row function, a
row whose top is a branch (with no node), `fallback`, and another module's markup in a row.
