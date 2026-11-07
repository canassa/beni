## 2026-10-31 12:32 CET — own2: a choice's arms read apart

**What I did.** I fixed #1439, an over-refusal in a call's other-paths walk (`TransferBeside.otherPaths`, `ownership-v2.md` §2.11 item 3, amended in place as *a choice's arms*).

- **The rule.** Where the write's own path meets a `choice` above its first `[*]` or `⟲`, the walk goes on as one route per arm. Each arm is a context of its own (`Ctx`, `armCtx`). Its base is the arm's positions at the rest of the write's path (`want`, and its reach for `unreached`). Its written positions are `frontierAt` from the arm. What is beside the write above the split stays in the enclosing context. A `union` and a `positions` node are never split.
- **The cost.** A context is built once per `(arm, depth)`. An item's context is the innermost arm above it, so no arm combination is ever made. A walk state met in two contexts is read once more in context 0, the whole argument's, which covers every arm (`visit`). So a shared part is read at most twice. On an `else if` chain of D arms the call's other-paths walks cost 1 321 / 2 679 / 5 226 / 10 496 more records at D = 8 / 16 / 32 / 64: linear. The K-wide family and the `T (List T)` towers cost what they did.
- **Verdicts.** Over the ownership, run and core roots (2 045 roots, master against the branch, v2 only), 22 demands change, all from refused to accepted, all in `CycleJoinRankWriter`, `ChoiceArmsApart`, `ChoiceArmsApartImported`, `FoldedBCall` and `FoldedBCallImported`. `FoldedBCall`'s `chosen` is now accepted where v1 refuses it. Each arm holds `k` at one written path only, so that is v1's imprecision. The soundness families (`CallOtherPaths*`, `ApartPaths*`, `ElementsApart*`, `PatternPositions*`, `QuadChildren*`, `TwoCallsApart*`, `FoldedOnePosition*`, `LevelsApart*`, `ParamLeafByNode`) pass.
- **Fixtures.** `ChoiceArmsApart` and `ChoiceArmsApartImported`: `levels`, `nested` and `field` are accepted; `sharedArm`, `nestedShared`, `fieldShared` and `unionTwin` are refused. Both fail on master. A counted build test covers nested choices at depth 8 and 16.
- **Size target.** `TransferBeside.zig` is now 1 043 lines, so its §5 target went from 960 to 1 060, with the reason in `rules_test.zig` and in the §5 row.

**What I learned.**

- `if c then { w = l, a = [] } else { w = [], a = l }` handed to a writer of `.x.w` beside `.x.a` stays refused, with `(approx)`, as v1 refuses it. I did not check why. My guess is that the join makes a record of two choices, which are no longer correlated, so the split never sees a choice there.
- An `else if` chain is superlinear before any call: 14 292 / 35 632 / 100 931 / 324 048 records at D = 8 … 64 on master. The walk of a `π1#Rose.0` write over it is superlinear as well. I opened #1467.
- The gates took 1 min 41 s in a fresh worktree, and 2 min 56 s on the second run, after a change to `rules_test.zig` and the design document only. Both are far over the 10 s in CLAUDE.md.
