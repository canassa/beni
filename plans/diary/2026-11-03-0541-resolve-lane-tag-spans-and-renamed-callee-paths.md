## 2026-11-03 05:41 CET — Resolve lane: tag spans and renamed callee paths

**What I did**

- Step 1 (`3208a27980`): each leaf-set node keeps a span of the choices that filter an element below it. A read-off pass now takes a node once under outer tags that cannot filter it, not only under no tags. The inline chain `x_k = if c then x_{k-1} else [ 1 ]` went from 24 988 / 225 397 / 2 846 209 records to 14 992 / 65 401 / 286 213 at 100 / 400 / 1 600 links. A new build_test pin holds both inline chains to n log n.
- I traced the inline knot chain with `e = x_{k-1}`. It is exponential (×4 per two levels), not quadratic. The cause: `Sweep.walkHolds` keys a holder's walk by `(value, tags)`, and each `x_j` is reached under one tag list per subset of the choices above it.
- Step 2 (`ca49ded506`): where an argument is the caller's parameter whole at the callee parameter's own place, the read-off takes the callee's arrivals at a call slot renamed. The call's separation is the callee's selection renamed. A demand's written path is replayed only when its line is printed (`CallGraft.zig`). `call256` went from 5 293 records (growth 1 195) to 1 649 (growth 0). `shared256` still takes growth 1 033, so the owed test (c) still fails.
- Status, measurements and the touches for the other lanes are on #1714.

**What I learned**

- Grafting the callee's whole `res` node is not exact, even when its arrivals all rename. The callee's tree says things at slots the caller's projection never asks, such as `⊤` at a scalar field. On a recursive result it also grows past the limit, because the projection folds by `⟲` and a node graft does not. Renaming per call slot, exactly what `instAt` reads, is exact.
- A failed graft test must cost nothing that the fallback pays again. Otherwise every call where the test fails gets dearer: a `relOf` before the precheck put `WideFieldConditions.run` +5 632 growth.
- Line targets are tight. `Message.zig` (280), `Ownership.zig` (340) and `Relation.zig` (1 300) had no room, so I moved `Sig` into `Relation` to keep `Eval` within its target.
- Once a path is a reference in the read-off, the next costs are in Distinct (expanding a call leaf for the distinct check) and in Resolve/Later/Liveness (a write target by its steps). Both need targets and entries as `(j', Rel)`, not as leaves at positions.
