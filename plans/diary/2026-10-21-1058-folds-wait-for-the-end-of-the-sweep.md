## 2026-10-21 10:58 CEST — folds wait for the end of the sweep

**What I did.** Took up #565 (points-to: `top` before site batches, and lazy
summaries). Re-measured its premise on master with an instrumented ReleaseFast
build (not committed) that prints, per fact-3 run, the edges, which of them end
in a summary whose owner is `top`, and whether each edge into a dead summary was
made in the same drain as the `top` that killed it. Both of the issue's rules
already hold: `top` first since #563 (one batch per var, `joinNow` takes `top`
first) and demand-driven properties since #500 (`demands`). What was left: on
N=64, runs 5 and 6 still make 247k of 361k edges, 85–87% into summaries whose
owner ends `top`, but the dead ones were filled a drain or more before the
`top` came (3 per run in the same drain). So `joinNow` now queues its folds and
`foldWaiting` folds them at the end of the sweep, inside one drain. N=64 edges
361k → 285k, `specialise` 275 → 249 ms; nowd 152k → 132k; N=16 unchanged;
outputs and run hashes byte for byte. Unit tests for both rules; the eight
older summary tests now settle folds (`settle`) before reading a summary.

**What I learned.** The first prototype drained after each deferred fold,
outside a drain, and each copy edge's join became its own batch: +1–2% on the
inline corpus cases, while the dashboards got faster. Folding the whole queue
under `draining = true`, as the fold inside `joinNow` was, then one drain,
made the corpus cases 0.3–0.6% cheaper instead. Deferring `feedSummary`'s
folds as well tripled the first runs' edges: keep those immediate. The 53–66k
edges per run into live, escaped summaries of uncapped `top` owners carry
facts (sites beside `top`) and cannot be skipped by order or laziness.
