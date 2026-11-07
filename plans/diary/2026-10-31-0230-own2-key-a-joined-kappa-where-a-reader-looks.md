## 2026-10-31 02:30 CET — own2: key a joined κ where a reader looks

**What I did**

- I fixed #1399. In `.alternatives` mode, `Cond.propagate` keys the joined κ at `proj(joined, q)`. Below a choice or union, that node is a new DAG, and no part of the value names it. A call's view expands a choice into the choice of its arms' views, so a caller meets the arms' nodes and never this one. `map` and the printer meet the arms' nodes too. `Transfer`'s branch join was correct only because it merges the arms' snapshots first. `Summary.joinRes` starts from nothing, so a group port's `shared` was not visible to callers.
- The fix is `Cond.leafEntries`. At each joined DAG node, every node of the DAG below it that a member holds is keyed with what the members store at their own positions. A built node with no entry gives `lost`, and a recast gives the member's read. A `runtime_safety` check (uncharged) asserts the keying at the end of each join. The rule is specified as §2.9 *Keyed where a reader looks*, with a pointer from §2.11 *κ at a view*. The `Cond.zig` line target goes from 4 260 to 4 400.
- I added two unit tests in `Calls.zig`: a single-arm choice and an interned union below a choice, each read through `apply`. Both fail on master's `src/`.
- Master is not affected by any program. Outside unit tests, only a group's rounds build a class join. The non-recursive repros the brief suggested all go through the branch join, which v2 already refuses.
- Corpus, `ownership/` and `run/` dumped with `--ownership=v2`, 977 cases: on master, no verdict line and no summary line changes. Records go up 1.7% in total and at most 12.7% in one walk (`levelThree`). On 4a with the fix: `GroupJoinShared` gives v1's verdicts (20:26 and 43:26 refused), and no other verdict changes. Records go up 4.5% in total, `MarkerAcross.incAll` growth goes from 8 842 to 15 924, and `incLeft` from 10 312 to 18 739. A few summaries print a `{lost}` fewer because arms now keep their members' entries. `RecordContentsReturned.dupRec` now prints `shared` where it printed a stronger `apart`.

**What I learned**

- I first also keyed a DAG leaf that no member holds (an image `widen` made, a set leaf `join` merged) with the joined κ. That made 4a's `incAll` family diverge. `kappaLeq` projects the port along each round's frontier and reaches a node that no `propagate` frame walked. The round stores `lost` on its image leaf, the port's corresponding leaf derives something stronger, and the rounds never settle. I left those nodes as they read and opened #1406 for the case where their derivation may be stronger than the join.
- `zig build gates` took about 95–107 s in a fresh worktree, not the 10 s that CLAUDE.md quotes.
