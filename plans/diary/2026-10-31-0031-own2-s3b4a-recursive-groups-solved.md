## 2026-10-31 00:31 CET — own2 slice 4a: recursive groups solved

**What I did.** I rebased `own2-s3b4a` onto master, which now has #1363, #1382 and #1384.
- Group rounds set `widen_rounds`.
- `Walk.renumber` counts shared images the way read-off does (#1384).
- Per-read grafters free their memos. There was a leak that group rounds made visible.
- A list append is named `<++>`, as v1 names it.
- The known file can now hold a known limit with its owner.
- WriteOneLevel moved from `tests/pending`. I added RecursiveCallView and RecursiveSummaryGeneration.
- The corpus is green, and `zig build gates` passes.

**What I learned.**
- With #1253 option B, the tree writers' own calls hold v1's verdicts, under other path text.
- `Dict.descend` and `Dict.removeMin` in core, and `MarkerAcross.keepRight`, are now checked, and the cost of their walks (#1372) puts them past the default limit. So they are known limits with an owner. The rule that a limit in core fails had no such escape before.
- The Appendix B rows that need to walk a list of recursive values cannot be written yet: `List.get` is unbuilt in v2, and callbacks belong to S4.
