## 2026-11-03 04:59 CET — Values lane: the identity control, flat call chains, meetRun

**What I did** (#1714, branch `own2-cost-values`, no PR)
- I rebased onto the resolve lane (`own2-cost-resolve`). Together the two lanes put three files over their line targets, so I split `Chains`, `BelowSize` and `Put` out of them; `ReadOff` moves to L12.
- **The identity control.** A settled callee whose result tree is `ε… π_j·ε` and that does not write `π_j` now answers the argument's value at the walk. The size gate on the open node is withdrawn.
  - The open node is cheap now. A below key projects the argument at each slot. A parameter's whole subtree is one open item. `Normal.zig` drops the arrivals that an open one above them already says.
  - `wrap (ident r)`: +103 → +4 records a call. `Dict.descend`: 26 448 → 24 895.
- **Call chains.** The `onChain` walk now runs only for a leaf that some entry has. The distinct check reads a chain of single-leaf calls to its end (`endOf`). CallChainShare `step` and `shared` are flat.
- **`MeetRun.zig`**, wired into `Descent.holdsAt`. A `Place.slotsAtLeast` column replaces `Canon.manyPlaces`: `described*` 254 → 244.
- build_test: 10 → 4 failures. No verdict moved anywhere.

**What I learned**
- The `covsum` uncovered rows that the identity control causes are exact answers, not losses. A generic identity's deep `π1ε*` used to put every object of the argument at the top slot. Switching off only the substitution brings the uncovered rows to 0: that is how to prove where they come from.
- Do not shorten the chain inside the instantiation (`instAt`/`feed`). Resolution reads a call leaf's root, and doing so refused 8 demands. The same shortcut inside the distinct check is safe, but only for one entry of one object.
- My own earlier fix (`onChain`) was the main quadratic in the call chains. Profile the head before believing an earlier diagnosis: `meetRun` was no longer the wall for k list fields.
- In a safe build, `ArrayList.pop` poisons the popped memory, so never read popped items through `items.ptr`.
- The profiling worktree must copy untracked new files. Otherwise it builds stale code and gives no error.

**Open:** CallChainShare `merge`/`indep` (`Rounds.before` walks are chain-deep), the fold certificate, the doubling DAG, `oneOfHelp` (keyed read-off in the group's rounds), and 1 record of `described*`.
