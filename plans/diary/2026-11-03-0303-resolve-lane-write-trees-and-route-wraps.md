## 2026-11-03 03:03 CET — Resolve lane: write trees grafted at a parameter, route wraps

**What I did**

- #1714, resolve lane, session 9, on `own2-cost-resolve` (on `own2-integrated` `d4aa38289`). Two steps were pushed. No PR.
- **Wall 1** (`e30662720`). A callee's `writes` are now one tree a parameter, as the reads are; a block encodes them that way (version 18). The new file `Graft.zig` (L8) has four parts:
  - **The stop at a caller's parameter.** The targets are read off the tree: a subtree that writes every object below its slot is one deep target. The targets are grouped into one demand per state, along the frame's positions below `c`. The caller's writes are the callee's tree, grafted.
  - **The callee's `req` moved** onto exact parameter slots.
  - **A literal walked once per (node, value)**, and its plain occurrences asked whole before the walk by routes.
  - **The exact fold of `req`.**
- Three build_tests flipped: the doubling DAG below a parameter, the K-wide type, the doubling literal.
- **Wall 2 rest** (`0c4d3e4fd`). A leaf set has a route-wrap node, so two arms that hold one plain subtree join in one step. "A choice whose arms share a subtree" flipped. build_test went 14 → 10.
- Checks on both steps:
  - Ledger: no verdict moved. Every summary that changed asks at least what it asked (`covsum`).
  - Oracle: 702 probes plus 8 new negative controls, 0 TRAP / 0 DIFF.
  - Cost table: every growth is still 0.
  - wasm and the unit tests pass.
- **Wall 3** (kept judgements, GroupRotate) is not started. I wrote down where the cost is.

**What I learned**

- The spec judged a state on its least route only. That is sound only if `T(c)` lists every slot that anything names, and that includes holders' and operands' conditions, which differ per route. The conditions that the judge gathers name the target, so a representative leaf gives a `req` that says less.
  - Judging a full subtree as one `↓s` target keeps the judgement exact. `T(c)` then only groups lines, and the frame's positions along the tree's steps are enough for that (`pos_index` lookups, no scan).
- The literal walk must not take a step it cannot follow exactly. A first version dropped `⟲`, `⟨Tree⟩` and `◆` steps. That removed whole refused positions: the ledger showed it as `onlyA`, not as `a2r`. **Always read `onlyA`.**
- An allocator mix-up has a delayed effect. `relOfWords` grows a module table, so passing an arena as its `gpa` panicked much later, in `Slots.deinit` ("incorrect alignment").
- Test 2 (one line for the doubling literal) and rows 15/17 (`P w w`, a line a side) are in tension. Rows 15/17 still pass only because their tree has `⟲` steps, so they keep the old path.
- GroupRotate at n = 32: 105 321 records. `Resolve.resolve` is about half of the total: `judge` 57 k, and `Operands.judged` + `finish` 46 k. These are the per-round re-judgements that §2.12's kept judgements would remove.
