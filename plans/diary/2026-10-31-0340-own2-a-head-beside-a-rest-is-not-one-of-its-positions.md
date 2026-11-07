## 2026-10-31 03:40 CET — own2: a head beside a rest is not one of its positions

**What I did.** Fixed the HIGH finding of #1411's review. When a list pattern matched a
rest, it split the rest's `others` cell and dropped every contents cell at the list's
`[*]` canonical position. That included a head stored beside the rest, so `c` looked
apart from `a`. The stores were a join with `[ a ]`, `List.push rest a`,
`List.set rest 0 a`, `rest ++ [ a ]`, a push onto a rest of a rest, and the literal
`[ a, …rest ]`. `Transfer.splitTargets` now also splits the list when anything other
than the rest's `others` sits at that canonical position (§2.13.3, amended). Fixtures:
`ownership/PatternPositionsStored` and `PatternPositionsStoredImported`, with v1's
goldens. On the PR's earlier head, 5 `go a c` calls in each were accepted. Here all are
refused. The literal case has an entry in `ownership-v2-known.txt`, because v1 accepts it
unsoundly. `headRest [ W b 0, W b 1 ]` is refused at the caller, and the callee is
accepted as v1 accepts it.

**What I learned.**
- A distinct caller of `headRest` is refused by v2 on master as well. It is an
  over-refusal of the summary's granularity, filed as #1415 and left out of the fixture.
- The review's LOW finding, a cost quadratic in pattern or projection depth, is filed as
  #1414.
- `beni check` on a project writes `.beni-cache` beside it. I made one under `tests/`
  by mistake and removed it. Dump goldens from a clean scratch copy.
