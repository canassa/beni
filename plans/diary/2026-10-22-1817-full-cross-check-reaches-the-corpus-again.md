## 2026-10-22 18:17 CEST — the full cross-check reaches the corpus again (#763)

**What I did.** Bisected #763 with full-cross-check builds of each `src/own`
commit since 7f1135d4b: 7329b19ea packs core, c65cc73ec (#720, the per-path
container guards) panics. Two causes, both from the guards. The `value-cells`
limit counted the guards, which are annotations (`condition_only`) that no
pair of the deep condition reads; the expanded form of core `Schema.shapeOf`
reached 266 and took the pessimistic summary, so its call sites were rejected
where the canonical form accepted them. A normal build hit it too: a record
of 130 parameter lists stored in a list reported `value-cells 262`
(`ownership/ValueCellsGuards`, accepted again). With the count fixed, the
summary cross-check failed on fresh numbers: the canonical run, coarser,
writes a guard the expanded run does not, and every later number moves. The
check now compares an allocation's number by the places it names (one
canonical number must cover every place the expanded one is at) and an
annotation per place. The corpus under the cross-check fails only RecordTree
(#427) and LevelPlacesKinds (#694), as on 7f1135d4b, and every golden matches.

**What I learned.** Ordering the guard cells by path text made the numbering
independent of path interning, but it renumbered 27 goldens and the cross-check
corpus did not need it: the forms disagree on which guards exist, not only on
their order, so the comparison had to change anyway. A fresh number that is
compared as text is only as stable as the order the walk interns paths in.
