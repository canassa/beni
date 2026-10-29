## 2026-10-29 18:12 CET — ownership v2: full preimage for folded call reads

**What I did**

- Replaced `Cond.foldedRead`'s conservative `lost` with `Calls.preimage` (#1159). It keys source
  positions by canonical path. Choices take the maximum, a union's cells count as a set, and
  everything else adds. A symbolic leaf contributes its projections, and a recast or a `⊤` cell
  contributes `⊤`. Cycles are settled by component, and the result is kept in the table by
  `(argument, prefix)`.
- Probes: FoldedBCall and its twins, a value shared at two positions, a choice of depths, a list
  of lists three deep, a knot, a 64-field record read through 8 and 64 paths, and #1157's six.
  Each new rule, removed in turn, fails a probe.

**What I learned**

- A probe that reuses one empty-list leaf at several positions is testing real sharing, not the
  walk. Each position needs its own leaf.
- In a recursive type, a knot reaches every key below it, so a cyclic source stays `lost` until a
  widened image's fold certificate may stand for its cycle. That is an open question.
- `-Dtest-filter=own2` ran for more than ten minutes. Filtering by module (`own2.Calls`,
  `own2.Cond`) takes 2 s.
