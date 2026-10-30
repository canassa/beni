## 2026-10-30 19:18 CET — own2: a derived comparison's use is built once per place (#1331 review, #1349)

**What I did.** The review of #1344 found the memo of `UseBuild` skipped every
place inside a cycle, so a mutually recursive type was rebuilt per path and
hit the accounting invariant at k = 6. I replaced it with Tarjan's walk on
explicit stacks: a strongly connected set is settled when its head is done,
each member becomes the head's deep leaf and is memoised, and `e`/`w`/`any`
are known before any record is allocated. The build runs in growth, not in the
call's baseline lane. The component's place now takes the use its class gives
its parameters (`#Inner.0 W`) instead of a deep `W` over the constructor,
which closes #1349 (`( Inner xs, ys ) == …`, `[ Inner xs ] == []`, a record).
Counted tests: mutual fan-out k = 6 and 12, a syntax tree, a 160-field type and a
doubling DAG with a component at depth 8 (all four fail on the previous head
on the invariant or the summary-size limit). The Rows unit test now has a
component at a sub-place.

**What I learned.** Linear construction was not the whole of it. With the
build linear, a type of n fields that each hold a writing component still costs
about 156n + 16n² in the caller: each writing *path* is a demand of its own,
checked against every other path (`Transfer.call`, `otherPaths`, #1334). A
read-only component is flat (138 records at n = 8, 16, 32, 64). A bound on the
width of the use was the first answer and was wrong: it is a silent precision
merge and it left the #1349 hole open under it. The loud limit stays, and the
wide type and the doubling DAG with a component (2^8 writing paths) wait on
#1334. The hole itself was in the read-off: a deep demand writes `reach(base)`
(§2.8), but `Walk.readOff` marked `W` on the cells of the base node only, so a
fresh container holding a parameter wrote nothing of it. One line there makes
every deep leaf sound (cycles included, at any depth), and an exact cyclic
use was the wrong road: canonical paths of a fan-out ring are exponential and a
six-type syntax tree hit the summary-size limit.
