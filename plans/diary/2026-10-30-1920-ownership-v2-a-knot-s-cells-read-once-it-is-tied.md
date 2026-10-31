## 2026-10-30 19:20 CET — Ownership v2: a knot's cells read once it is tied

**What I did.** Fixed the review finding on #1346 (#1335). `BlockRead.unit`
read the raw members' cells by `cellsOf` before it tied the child maps of
the knot's nodes and deltas. A whole recast's cells are its inner's reach,
so `Shape.reach` walked a delta with no child map, missed the override and
kept the short set in its memo. The decoded class held fewer cells. Now the
cells are read after the child maps, and a whole recast over any member is
tied raw too. A `runtime_safety` build checks each member's memoised reach
against a memo-free walk of the tied knot; with the old order, that check
fires on the new test. The reader also refuses a member that names a later
member off a cycle of raw members (`forwardOnCycles`, by
`Shape.Table.cycleWalk`), an order the writer never makes. Two tests: the
reviewer's knot `U = union(leaf, positions(delta(U, …), recast(U)))`,
plain and whole, at `U` and at `P` (bytes, text, cells, reach and κ at ε
and `[*]`; the whole cases fail on the old head), and a hand-written
block with a forward name off a cycle. §3.6 *As built, #1335* says it.
Rebased onto #1348 (the deep-read mark), which took block version 13: this
change is version 14, and the pinned `w2` block hash moves again.

**What I learned.** A memo filled during decode is part of what the block
means. Reading a derived fact before the knot is whole is a silent loss,
not a crash, so it needs an assertion, not only a round trip.
