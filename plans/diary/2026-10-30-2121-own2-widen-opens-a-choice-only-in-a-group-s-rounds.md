## 2026-10-30 21:21 CET — own2: widen opens a choice only in a group's rounds

**What I did.** The re-review of #1363 found two more faults in the knot rule. A knot below the root join
(`growA`'s `A1 xs (B2 [] b)`, a cycle of B inside A's) left the join kept, so the rounds grew without end.
An arm that builds a node once (`wrap`, `ins`) counted as a knot, so the join folded and callers were
refused. The manager decided on a new criterion: opening is needed for termination, not for a finite
value. Widen now opens a union, choice or positions node at a place on a cycle only when
`Shape.Table.widen_rounds` is set. The group's driver sets that flag around its rounds. In a round, the
node opens when any `⟲`'s target is at its path, above it, or below it. With the flag off, widen does what
master does: v2's dump of the 942 ownership and run fixtures is byte-identical to master's. §2.3 *On the
cycle* is rewritten. New fixtures:
- `ownership/WidenChoiceBuiltArm` (`wrap`/`gpw`/`hw`, `ins`/`gpi`/`hi`): the PR's last head refuses 4
  demands; master and v1 accept them.
- A Shape test that `growA`'s rounds settle with the flag. It fails on the last head.
- `pick`'s pin now holds master's exact summary.

On `own2-s3b4a`, with the flag set in `solveGroup`, every group settles: `growA` 3 walks, `loopA` 4,
`fa`/`fb` 7/7, `incAll` 4, `incAll2` 4, `incLeft` 3, `build`/`dup` 3/3. The self-map family settles at
n = 16 as well (4 walks).

**What I learned.** "Is this value a round of its own group?" cannot be read off the shape. A view of the
group's class looks like any other view once it is forced. So the driver must say it. Widen's share of
the self-map grows by about a log factor per node it walks (`widenValue` 50 → 78 records per node from
n = 1 to 16). The nodes it walks grow as n² (59 → 1 079), because each call result is forced as its own
view. `fa`/`fb` are the costly pair: 7 walks, 50k / 75k total, about half of it widen's.
