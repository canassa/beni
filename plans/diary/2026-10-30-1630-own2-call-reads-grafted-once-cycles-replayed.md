## 2026-10-30 16:30 CET — own2: a call's reads grafted once, its ⟲ replayed

**What I did**

- Answered the review of #1329 with two more commits.
  - **The `⟲` bug.** `compose` hung a callee's `⟲` under the argument's own path with `Place.extend`. When the caller's cycle starts above the argument, that path is one no demand queries. Example: `viaT t = case t of T r → readKid r` gave `π1#T.0⟲.v`, not the inline `π1⟲#T.0.v`. The `⟲` is now replayed through `extend` around the caller's cycles (`Graft.levels`: a walk of the canonical paths of the place's strongly connected component). A fold of a plain step into a `⟲` above the path becomes a jump, installed afterwards from the root. Fixture: `ownership/CallFieldStepCycles`, one recursive type and a mutual pair. On master both pushes are accepted; v1 refuses both, and so does the fix.
  - **The cost.** The read-off now grafts the pair (callee use node, caller node) once, memoised by `(callee node, caller node, place)` when there is no jump, and puts the result with one path copy. A read-only, acyclic callee use at its own place is taken over whole: one node over the callee's children. `Calls.marked` listed every path of a callee's use at each call. It now walks only the subtrees with an `E` when the parameter has no `W`, because the touched paths are read only beside a write.
- Counts, last declaration's records (master, then the previous head, then now):
  - Wrapper chain: f10 47 / 125, f100 47 / 16,197 / 845, f200 47 / 62,347 / 1,645.
  - Doubling tuple DAG: d6 83 / 3,253 / 160; d12 83 / past `ownership_summary_size` / 244.
  - 160-field wrapper: 207 / 2,808 / 60.
- Pinned by three counted build tests. All three fail on the previous head.
- Verdicts over the ownership and `run/` corpus: unchanged from the previous head. Only the PR's fixtures differ from master.
- #1330 (a construction or an inline call result as the argument) is a different mechanism, left for a follow-up. `Transfer.consume` emits a use only for an operand that reads a local, so a temporary argument has no `call` use for the read-off to compose.

**What I learned**

- After the graft was linear, the DAG still doubled per level. The cause was `Calls.marked`'s per-path walk at every call, which composed reads now feed. A counter in the hot function separated the two in one run.
- A counted test must refuse a `limit` line. Past the limit a class is unbuilt and its account is small, so the old head passed the DAG ratio until the helper checked for it.
- `zig build test-blackbox-corpus -Dcorpus=X` takes about 1 s. `test-blackbox -Dcorpus=X` runs every black-box suite (about 70 s).
