## 2026-11-06 05:35 CET — one cell for a top-level Ref of a suspending callback

**What I did** (#1662, branch `toplevel-ref-twin-cell`)

- Reproduced #1662 on master `1550a68d61`, in development and in `--release`: the program printed `initial`, not `replaced`. The output had `Main$cellR` and `Main$cellR$s`.
- I made `$s` the same cell by hand. Then the program printed `[object Object]`. So the twin was only half of the defect: `dump --stage=types` said `callIt : ⊤ → String !impure`. The cause is `transparent-effects-proposal.md` §14.3 rule 3: each use of a top-level declaration copies its effect classes fresh. A local `let` has no defect, because rule 4 shares its classes.
- Found two more cases with the same cause. A top-level record `{ cell = Ref.make 0, cb = … }` had two cells (`0`, not `5`). A top-level value whose block does work and then gives a λ ran the block twice (`loads: 2`).
- Asked the owner `toplevel-ref-twin-q1` on the dashboard. It is still open, so the pull request is a draft and builds option A.
- Wrote the spec first: §14.3 rule 3 and §16.2 of the proposal, `checker-v2.md` §26 and §19.1, all dated amendments. The rule: a top-level value whose evaluation class is not `pure` does not generalise its effect classes. This is checker-v2 §8.4's value restriction (#1048) applied to the bits.
- Built it in `src/check/Effects.zig`: `run` solves, takes the fixed values, and solves again with them. `fixClasses` shares every copy of a fixed class. `Class.outs` makes a use's copy flow into a fixed class that the class reaches. `refresh` raises copies of a class whose rung rose late. `EffectPlan` never makes a fixed class sensitive. Moved `summarise` and its walks to `EffectsSummary.zig`, for the 1500-line cap.
- Added `run/TopLevelRefSuspendingCallback`, `run/TopLevelRecordCellOnce` and `run/TopLevelBlockRunsOnce`. All three fail on master in both builds and pass after.
- Opened #2126 for the write from another module, which this does not close (the owner's decision).

**What I learned**

- A twin is not only a question of identity. When the twin read the same cell, the reader still read a wrong rung. Check the reader's rung before you treat a duplicate as the whole defect.
- With fixed classes, the order of the summaries is not enough. A reader solved before the writer kept the old rung at its uses, and a setter that stores `λ⊤ → k ⊤` gave the cell no flow from its callers. Two mutation builds proved that `refresh` and the out-edges are each needed.
- The ownership v2 differential refuses every `Ref.set` into a top-level cell. That is a known difference (the Workers' fixtures have the same lines), so a new fixture with a top-level cell needs lines in `tests/blackbox/ownership-v2-known.txt`.
- The run-hash line of the gates is a cheap test that no output changed: only the 3 new programs ran under Node. Conduit (both builds) and the 23 `page` lines of `bench/size.mjs` were byte-identical to a master build.
