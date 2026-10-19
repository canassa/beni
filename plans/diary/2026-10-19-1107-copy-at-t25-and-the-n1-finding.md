## 2026-10-19 11:07 CEST — the copy cut at T = 25, and the N=1 finding

**What I did**

I recorded the owner's decisions.
- **The copy cut lands with T = 25.** The copy loop's fixed overhead on the shape path is real, as the N=64 and N=256 rows show. The per-program choice keeps it off small N: that is the two-lowering decision doing its job. At N=1 the copy's output is byte-identical to master's. The earlier "+245 B fixed" was a line fitted across the switch from workers to shapes.
- **No cost model.** The model built from separately measured pieces missed 19 of 57 research apps, because brotli doesn't add up isolated pieces. The free fit missed twice as often as T. So: T, plus a residual test that re-measures the choice on a fixed set and fails when T stops being the crossover. It runs on validator and codegen changes.
- **The N=1 finding.** 1 759 B against tea-inline's 1 326 (1.33×). Validation is about 460 B of it, so the whole gap at one widget is a reader whose error is never read. Before any cut, the ~460 B is broken down into the `Event` dispatch, the `Snapshot` reader, error construction and the helpers: fixed scaffolding against what scales with the model.
- **The polymorphic-recursion fold is approved.** The composed-path spike has 0 changed verdicts over 1 309 units, against master with `k`. It is built, rebased and re-measured, and `k` is removed in its own PR.
- **`browser-direct.md`:** the sections live code cites move verbatim into `backend.md`, `write-sets.md`, `boundary.md` and `ownership-checker.md` §30, with the citations updated in the same commit as each move. The rest is marked retired.

**What I learned**
- **A fitted intercept across a lowering switch is not a fixed cost.** Report totals per size beside any fit whose program changes shape along the range.
