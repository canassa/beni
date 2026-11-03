## 2026-11-03 01:10 CET — own2: integrated the cost and soundness lineages

**What I did**
- Made `own2-integrated` from `own2-cost-values` (1fbb8935d). I replayed the soundness lineage on it in order: core blocks, #1721, #1723, arrival order, #1727, #1729, #1734, #1736. Then I added the resolve lane's `Paths.zig` commit (e1d884b73).
- Where both lineages fixed the same hole (#1716/#1740 `Held`, #1737 label numbers), I kept the cost lineage's tree implementation and every fixture. The precision-5 and #1737 commits became empty and were skipped.
- Ported to trees: the label-count rule, now in `ReadOff`; the cell-capture `once` exemption, also in `ReadOff`; the cell rows (`Rows.identityInto` on `Draft.Res`); and `Cells.supply` and `Cells.shared`, which now read `Forest` entries. The `behindCell` barrier moved into the descent's `each`. Cells is at L8 and Paths at L8, and the table has 46 files.
- The pack maker now runs v2 over core. It showed a leak on the cost lineage: Resolve's `req` was grown on both the gpa and the arena. Fixed. Five lines in `Groups`, one in `Relation` and one in `Eval` went over their targets. I joined comments to bring them back. No target was raised. The two increments that the soundness commits added themselves (Walk +10, Eval +40) were carried over.
- `SanitiserPartitionHolds` now refuses with `list_still_used`, the soundness side's golden, because `Dict.partition` is now read.

**What I learned**
- build_test has 15 failures. They are the cost lineage's known 16 minus the nested-choice chain test, which `Paths` fixed. Unit tests, check_test, wasm and fmt pass. The corpus failures equal fiber-rows', apart from the limits that went away.
- Ledger against master's v2: only the two known accepted→refused rows. Against both lineages, one new accepted→refused row, ValuePath 81:30. It is a cost-lineage precision loss that core blocks expose (#1742).
- Oracle over 711 distinct probes: 0 TRAP, 0 DIFF. `F-RecMapOnce` is refused. The cost table equals the cost lineage's.
