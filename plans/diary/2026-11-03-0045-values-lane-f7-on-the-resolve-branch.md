## 2026-11-03 00:45 CET — Values lane: F7 on the resolve branch, two walls left

**What I did**
- #1714, values lane, session 7. I compared the #1740 fix with #1716's (`ba15b662e`, soundness lineage). They are the same hole: an open call answer described at its top slot only. The one-line widen in `describeItem` is identical in both.
- I ported #1716's `Held.zig` onto F4's trees. A draft entry here holds one arrival, so `atoms` reads `wide` entries and their `a`. A committed `base` tree is not read. That skips less and says nothing less. I also added the §2.10 amendment and the fixture `run/SanitiserPartitionHolds`.
- I did not cherry-pick the `Entries.zig` split. `own2-cost-resolve` is now rebased on `51421cbf1` and holds it, so I rebuilt the values work on that branch instead (`own2-cost-values-f7r`): the widen, F7, the old diary entry, `Held`. F7 conflicted with `PlaceBelow.zig`. `Subtree.below` now reads `Place.objectsBelow`. `PlaceBelow.slotsBelow` stays for `Descent`.
- I fixed the manager's two extra items. `Forest.text` now uses the caller's allocator, not `smp_allocator`; `test-blackbox-wasm` failed before the fix and passes after it. Test 20's `w12` is now a 128 × 128 record product, so the limit stops it again.

**Bar at `7a7dcc99a`, against `own2-cost-resolve` `942438204`**
- `Schema.shapeOf`: 272 813, growth 0. Without either change on that base it is 273 765. On the values base with `Held` it is 258 003, under its 265 082 row. No limit line is new.
- build_test: 16 failures, against 18 on base. Three now pass: test 20, the K-wide test, and the mutually recursive derived comparison. One new failure: "reads two positions of one image over k list fields". F7 makes k = 4 cheaper (63 437 records, base 76 782), while k = 8 and k = 16 are unchanged (319 069, 2.22 M). So the 4.5× ceiling now sees base's own growth from 4 to 8: 5.03×. Base's own step from 8 to 16 is already 6.9×. Without F7 the ratio is 4.20.
- The R-7.4 ring floor holds on this base without a change: 4 297 / 2 647 = 1.62.
- Ledger (2 182 roots): versus resolve base, versus `own2-cost-values` and versus master's v2, the only accepted→refused is `SanitiserFoldAnswerWide`'s own push. That push is proven unsound. The two others versus master are on base too. The limit lines are the same as base's.
- Summaries: 934 differ and none says less. 909 are covered mechanically. The other 25 are `⟲` paths under F7's one deep entry; two top-slot arrivals at constructor fields that hold no object, now said below them; and one ledger UTF-8 artefact.
- Oracle: 730 probes, the same results as base. The only change is `z-FoldCbWideBase`, which traps on base and is now refused. The only TRAP is `F-RecMapOnce` (#1721).
- Cost table: `Schema.shapesOf` growth went from 3 985 to 5 622. The widen causes this (6 247 without F7). `Dict.descend` went from 23 196 to 37 216 records, and its rounds from 3 to 5, with growth 0. F7 causes this.
- I did not fast-forward `own2-cost-values`, because the bar is not green.

**What I learned**
- A ratio test over a few sizes breaks both ways when one size gets cheaper: the ring floor did on the values base, and the k-list ceiling does here. That says nothing about the change itself. The fix is a size choice the manager decides, not a new bound.
- When two lanes share a base, rebase onto the other lane's branch. Do not cherry-pick its split: the split sat on 14 commits.
