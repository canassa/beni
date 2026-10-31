## 2026-10-31 11:20 CET — κ transport: the review's fixes (#1459)

**What I did**

- **HIGH: a join's κ was lost after two calls.** `Calls.apply` relabels the entry on a joined DAG node `D` onto `view(D, E)`, which no part of the caller's value names, so the caller's read-off dropped it. A call's view now has its template's origins, viewed under its environment (`Shape.originHead`). A caller's projection of a view records its origin, and `Cond.projectedImage` follows views.
  - Pinned by `build_test.zig`: the summaries of one and two wrappers equal the joined function's, same-module and imported.
  - Pinned by `o/WrapperJoinShared` and `o/WrapperJoinSharedImported`: the refusals through each wrapper.
- **A block that a limit stops is said:** `limit block: …`, counted among the module's limits, and an `ownership_limit` error under enforcement (#1450).
  - It exposed a block that master already dropped silently: 480 written fields, past the codec's bound. The test now pins that line, and #1461 owns the defect.
  - I found no cheap trigger for a test. K's block reaches the limit only at 300 levels, which takes 10 s.
- **Block bytes.** The block writes no join entry that its sides imply (`Cond.joinImplied`; the reads are the writer's baseline). K's block is master's byte for byte again.
- **The printer** reads the outermost join on its way (`kappaOf`), so joins nested in it count too.
- **The view-origin fix cost `run/DerivedDeepPaths`' `rose` the allowance** (175 376 records in 3 walks). `propagate` now stores no entry its sides imply when its members are the joined node's own sides, but only for a class join or a join with a call's view among its members. `rose` costs 47 498 in 2; master is 72 701 in 4.

**What I learned**

- Skipping the implied entries in every join made K superlinear (343 210 records at 160, about 7.3 M at 1 000). Without its entry, every read of a member's DAG walks deeper. So the skip is kept to the joins whose entry a call carries on.
- An importer of K still pays about 7 % over master (132 299 against 123 730 at 40 levels), and its limit comes at 42 levels instead of 45. The cause is the view's projection of its template: `proj(view(C, E), s) = view(proj(C, s), E)` expands leaves anew. Turning it off brings the cost back to master's, but callers then miss the class's entry on `D`.
- The full cross-check shows the same picture as before: master's five v1 panics, plus `MarkerAcross.keepRight` (#1458).
