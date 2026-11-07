## 2026-11-03 03:13 CET — Resolve lane: #1748 in Routed, and lines that name every route

**What I did**

- I cherry-picked the values lane's #1748 fix (`614f3bda7`). Its build test still failed on `own2-cost-resolve`.
- I fixed the same bug in `Routed.zig`: the route-set walk's whole read of a value gave both copies of a `many` leaf one route. The test passes now.
  - The ledger moves no verdict.
  - Nine summaries now say `nondup no`. In each, one object sits at two places in the result.
- A grouped write demand's line now names every route it covers (the manager's decision): a state's further targets, and a literal's second routes into one `(node, value)`. The number of names is linear (n + 1 for a doubling literal of depth n).
- `meetRun` is not pushed yet, so I did not wire it. Wall 3 is not started.

**What I learned**

- A fix in `Eval.project` does not cover `Routed`: a selection's walk reads leaf sets through `Routed.emit`. Any rule about how a projection names a leaf's copies must hold in both places.
- A demand's text data must live as long as the lines do. `Groups` keeps the lines in the walk arena, and the evaluation arena is freed before the lines are printed. A slice in the evaluation arena showed up as `0xAAAAAAAA` PathIds in `Message.pathText`.
