## 2026-10-31 09:31 CET — own2 5f: a use below a parameter's leaf, by node

**What I did.** I built #1412 with the manager's option 1, *expand after the walk*. The spec is
its own commit, in §2.11 item 3 (*One demand per state below a parameter's leaf*), and §8's 5f row
has the as-built note.

- **The stop.** `Calls.Routes.stops`: a write route whose value becomes an exact, unrefined leaf of
  the caller's own parameter, through an exact prefix, is returned once as a `stop`. `Transfer.call`
  records it as a `Group`, with a `CallSnap` of the call (point, callee, argument instructions,
  `xreq`, the slot).
- **The expansion.** `Transfer.Frame.expandGroups` runs after the walk and the liveness index,
  before `Demands.resolve`. It walks each group's use as `Routes` would. A route merges by state
  (use node, deepest trie node passed, class, `sig`, place) from the first node where its path is no
  summary path and every route below to a `W` takes plain steps (`Transfer.Plain`). The demands go
  to the group's slot, and the call's `xreq` goes on its first demand.
- **The class.** `Walk.GraftWrites` grafts each group's `W` and `S` marks at the leaf's path along
  plain steps, by node.
- **Tests.** `ParamLeafByNode` (merged in `alone`, `deep`, `t1`, `t2`; kept apart in `held`,
  `kept`, `other`, #1412's own `t1 p.0` refused), and two counted build tests: the doubling DAG over
  a parameter at depth 8 / 10 / 12, and a K-wide `T` at K = 8 / 16 / 32. Both fail on master.

**What I learned.**

- **Merging below `⟲` or `[*]` is not sound with one witness.** At a summary path, a write owes
  `excl` of its base's canonical cell, and that cell is one per route. One demand would publish one
  atom, so those routes stay per route (#1453). That is also why #1357's precise comparison use does
  not fit yet.
- **Later call uses and escapes** are interferers whose reading below the leaf is a use DAG, not a
  path. For now a later call use keeps the group's routes apart, and escapes stay per route (#1454).
- **A place defect hid behind the per-path cost.** Two place builds could share a cycle component
  id. A tuple and its `List Int` were then one cycle, so `Exits` walked a call use by path, and the
  doubling caller stayed exponential in the resolver after its demands were merged (#1452, fixed
  here; the corpus dump did not move).
- **Forcing more reach changes a read-off.** Reading the reach of every holder before the resolver
  changed core's `concatFrom` `res` from `{apart …}` to `{lost}`. Only holders live at a group's
  call can hold against its demand, so I read only those, and the diff is clean. The cause is
  #1455.
- **The whole-corpus v2 dump diff** (2 039 roots, the diff's own roots, every line except accounts)
  shows no change. The demand lines are in that diff, so no corpus route was merged away; only the
  new fixture shows merged demands.
- **Cost.** At depth 8, `caller w = t_n w` was `ownership_summary_size` and is now 852 records. At
  depth 12 it is 1 228. `t8`'s own frame goes from 75 668 to 1 398 records. The K-wide caller goes
  from K + 1 demands to 2, and from 4 572 to 1 613 records at K = 32. `wall` (the write-many-fields
  family) costs about 22 % more in its own frame (62 477 → 76 062 records at 256 fields), because each of its writes is a group. Its caller
  costs a third of what it did (24 858 → 8 579).
- **Slow.** `zig build gates` took 2 minutes in a fresh worktree after an edit under `src/own2/`.
