## 2026-10-31 14:12 CET — own2: a part a choice's arms share, walked once

**What I did.** I fixed the review finding on PR #1469 (#1439). The first version gave each arm of a choice a context of its own. Each context held its own base, its own written positions and its own children index, and building each one walked the arm's whole value. So D arms that share a subtree of N nodes cost D·N, and one program that master checks hit `ownership_summary_size`.

- **The walk is now a graph** (`TransferArms.Arms`, a new L10 part). Each item, each read and each state of a read by position is a node. A node is met once, whichever arm reaches it. An edge from a choice to a side that is not a choice starts that side's arm. One pass over the strongly connected components gives each node the arms it runs in. Every node is read with the whole argument's base. At the end, a kept cell stays only where its key belongs to a base in a run that the node is in too.
- **Written positions per run** (`frontierMax`). With a split, routes are counted per leaf arm in one pass, and the sides of a join are edges. A node shared by two arms, with one route in each, is written in both. This keeps `levels` and `nested` accepted.
- **No arm repeats a shared part.** An arm's node above the first `⟲` reads its children at the steps that the whole argument's node lists (`Synthetic`). A `⟲` below a split is re-entered one node at a time (`expandOne`). A read by position goes one state at a time (`readStep`). Small reaches and small child sets are matched by their own keys (`keepReach`, `Beside.keysOf`).
- **Numbers.** On the reviewer's shared tower, the call costs 9 147 / 13 037 / 22 487 records at N = 16, D = 4 / 8 / 16 (the PR had 14 239 / 23 396 / 43 391). At N, D = 128, 64 it costs 293 653 and is checked; the PR stopped at the limit. The walks cost about 240 records an arm more than master's, at every N. Verdicts are the same as the PR head's on all 2 045 roots. A new counted build test fails on the PR head: six more arms cost 26 458 / 46 942 there, ×1.8.

**What I learned.**

- Per-arm route counts were needed. With one global count, a list that two arms share at the written path has two routes, so it is never a written position, and `chosen`'s ⟲ write was refused again. Counting each run separately (the most routes any one arm has) is sound for every node, including nodes above the split.
- The call's records still rise faster than its walks. The difference is the `demands` lane: an accepted call goes on to read its holders, and master's refusal skips that work. It is the same on the PR head, and it is not the walk's cost.
- `TransferBeside` and `TransferArms` call each other. They reach each other's types through `Frame`, never by import. §5's table and its prose say so now.
