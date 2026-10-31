## 2026-10-31 05:13 CET — own2 slice 4a: blockers landed, group fixtures green

**What I did.**
- I rebased `own2-s3b4a` onto master, which now has #1408, #1397, #1403, #1407, #1424 and the rest. I resolved every conflict by hand: the known file kept both sides, master's own grafter deinit replaced mine, and I set line targets for Summary.zig and Ownership.zig.
- `GroupJoinShared` and `GroupSplitXreq` moved into the corpus with v1's verdicts. I added the imported twin `GroupJoinSharedImported` (`Builds.h3`/`Main.r3`).
- I dropped the stale known entries: core List 1212:38 and `ListPrependDeep` 81:9. The `RefUpdateAcrossFibers` lines became v2's `Ref.set` writer row.
- The tree writers now also write their `#Node.0` paths, with the same verdicts as v1, so those lines are path-text entries.
- The corpus is green, and `zig build gates` passes.

**What I learned.** `--ownership-both` changes since #1402 turned up no golden changes beyond line order. A `.v2.ownership` golden is not rewritten by blessing; regenerate it from the dump.
