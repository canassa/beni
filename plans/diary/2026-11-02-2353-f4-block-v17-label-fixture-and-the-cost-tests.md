## 2026-11-02 23:53 CET — F4: block v17, the label fixture and the cost tests (work in progress)

**What I did**
- #1714, values lane, F4, on `own2-cost-values-f4-wip` (five commits on `6f696d80a`).
- #1737: a probe shows the misnamed label lets an unsafe write through. `keepThenHand f g xs = ( f xs, g xs )` with a fresh `f` and a `g` that hands its argument back: the base accepts `List.push` on the second part, and the sanitised run traps. Pinned as `run/SanitiserCallbackLabels` (`.sanitize-lists-v2-refuses`). It fails on `7e7874ab3` and passes on the branch. On the base, the fix is one move in `Contract.Table.commit`: renumber `d.res` before it is put. I checked that move on the base and wrote it on #1737.
- Block v17: each contract writes one node table in post-order (`Contract.Table.postOrder`, an explicit stack). Each field is the index of a root. The reader re-interns each node. The re-encoding check did not change. An imported `w9` no longer lists 2^256 paths. `Block.zig` is at its target of 380 lines.
- I replaced the cost generators of the near-limit tests. They now use `recordProduct`: m list fields, n copies, each copy with one field fresh, all joined at one list's elements. This is m·n work whatever is shared. At 88 × 88 it costs 76 351 growth records (the old one cost 77 031). The imported eq test puts the product inside `eq`, over a 128-field record in `Key`. The #1360 test reads `π1#1.2 = π1#1.0`, which is the same set of reads. The imported doubling test compares the importer's summary with the summary of its twin in the same module.
- Spec: *as built* notes in §2.10, §3.5, §3.6 and §5.

**What I learned**
- The `node` harness reads a child's stdout chunk by chunk. A `…` split across two chunks becomes `��` in a ledger file. One "summary diff" (`RecordExtChain.f64`) was this artifact.
- The else-if chain call (1 960 / 3 704 / 7 152) is the same on the base. Nearly all of it is under `Eval.finishDemands`. Three quarters of it is `Distinct.instSel`, which projects the callee's selection over the D arms. That code belongs to the resolve lane. The fix is per-node instantiation through the chain's tag routes, in `Distinct`.
- Writes, escapes and kept as trees save storage only, as long as `callWrite` makes one demand for each written slot. The cost tests for writes (doubling DAG below a parameter, K-wide) need demands for each node. That is resolve-lane work.
- Bar, measured: build_test 53 → 47 failing, none new. Ledger against `cv3/ledger/s1b`: 0 a2r, 0 r2a, 11 limit lines fewer, none new. The semantic summary diffs are the same set as the last WIP. Cost table: growth 0 on every row; `Schema.shapeOf` 256 826. Oracle: 673 unique probes from every listed directory. The refusal sites are the same as the base's. The only TRAP is `F-RecMapOnce` (#1721), as on the base. In the ownership corpus, the only failure is `WideModelArms`, as on the base.

**Not done:** writes, escapes and kept as trees; the else-if chain call; F7. `own2-cost-values` is not fast-forwarded.
