## 2026-10-20 02:25 CEST — points-to counters and the copy-edge repairs (#486, #487)

**What I did**

Slices 0 and 1 of `plans/type-directed-points-to.md`, on dagon, as two stacked PRs.

Slice 0 (#486): four `--self-profile` counters for fact 3 — `spec_pts_max_set` (a maximum,
through a new `Profile.maxCounter`), `spec_pts_set_words`, `spec_pts_edges`,
`spec_pts_load_cells` — counted over every fixpoint but a safety build's reference, so a
ReleaseSafe and a ReleaseFast build count the same. The hidden `--points-to-largest` keeps
each var's origin (only under the flag) and prints the var that held the most sites and, a
line per file, the source lines its sites were made on. Output byte-identical on every
measured project and in the gates.

Slice 1 (#487): `Load.done` is the union of what every evaluation saw; `load` links nothing
and makes no `Prop` on an escaped site; `edge_set` holds only the edges between two lists
longer than 8 (`indexEdge`); `summaryOf`, `linkSummaries` (a queue, as `drain`),
`setUnknown`, `setAnyWritten` and also `summaryProp` are walks over a shared stack, not
recursion. A small-stack unit test of a 10 000-copy chain (segfaults on the base, passes
after) and `emit/release/inline/SpreadEscapes` (1 337–1 434 nodes, so the shuffled-order
check runs; it reaches a summary site escaping, a load of an escaped site and a shrinking
`done`), golden blessed with the base compiler.

**What I learned**

- The merge left in the no-`withDefault` dashboard is `Main.step`'s return (and the `model`
  that `update` hands back): 415 sites, every one a `Main.Model` record — the 64 arms' record
  updates multiplied by each inlined widget `update`'s arms, `replaced`'s 64 arms, `pushed`'s
  two and `init`'s record. One type, so slice 4's declared-type filter will not split it.
- `summaryProp` recursed along summary links too; the plan's list missed it, and with the
  other walks made iterative the chain test reaches it.
- Slice 1 took N=64 from 7.6 s to 6.9 s (edges 31.3M → 27.1M) but left nowd at 1.33 s:
  `copy`/`hasEdge` under stale `done` was not what nowd spends its time on; `joinNow`,
  `enqueue`, `difference` and `EdgeKey` puts between long lists are.
