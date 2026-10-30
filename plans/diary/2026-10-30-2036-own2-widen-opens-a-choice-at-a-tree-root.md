## 2026-10-30 20:36 CET — own2: widen opens a choice at a tree's root

**What I did.** I fixed #1360. `Shape.widenFold` opened a `union`, `choice` or `positions` node only at a
`⟲` step. A branch join at the root of a recursive value is at the root's path, not at a `⟲`, so the walk
kept it whole and never saw the re-entries in its arms. Now a node is also opened at a path whose place
lies on a cycle of the place graph (`Place.onCycle`). The walk returns the identity when it met no `⟲`, so a
value with no re-entry is unchanged. §2.3 has the rule in place (*On the cycle*), with its precision
limits. Fixtures: three Shape unit tests (a choice at the root, a nested choice, a choice in a union; one
node per canonical path, `leq` after one more round, idempotence) and an identity control; a Cond test
that the opened arms keep their maximum (a union's sides sum); `ownership/WidenChoiceRoot` with its v2
summary pinned in `build_test.zig`. All but the control fail on master.

On `own2-s3b4a` with this change, the four groups settle: `MarkerAcross.incAll` and
`LevelRecursiveUpdates.incAll`/`incAll2` in 4 walks, `incLeft` in 3, `LevelFresh.build`/`dup` and
`FoldLevels.build` in 3. Over the ownership and run corpus, two v2 summaries change and no verdict does.

**What I learned.** A node kept whole hides everything under it from widen, because it has no explicit
edges. The same is true of a choice at a place *above* a cycle (`{ t : Tree }`): it stays unfolded. That
is #1362, and it is a design choice. With the groups settling, 4a shows a new parity gap: v2 refuses
`LevelFresh.pushRoot` and `FoldLevels.pushRoot`, which v1 accepts. The cause is that widen keys a `⟲` to
its ancestor's class, so the root level's list and every subtree's are one class. The opened choice is not
the cause.
