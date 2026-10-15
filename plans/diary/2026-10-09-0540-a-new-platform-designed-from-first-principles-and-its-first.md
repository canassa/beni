## 2026-10-09 05:40 CEST — A new platform designed from first principles, and its first slice

**What I did** (as manager; agents in worktrees, PRs reviewed by Claude, adversarial review on soundness)
- Built R2 (controlled inputs by an edited set, live rows 42× → 1.74× vanilla) and R1 (plumbing).
  The owner then withdrew R1's fast paths as patching (+100 B on machinery the target replaces),
  and asked for the target rebuilt from first principles on a separate platform.
- Conduit (RealWorld) is built in beni (`examples/conduit`) and runs in the corpus under an
  owner-granted budget (`.budget` files). Research 62: nested pages make 8 of 9 top-level messages
  replace the model; nested dispatch makes 94–99% of keys bounded.
- The write-set analysis: specified (`write-sets.md`, three adversarial soundness rounds, seven holes
  closed), implemented as `beni dump --stage=writes` (two review rounds, four bugs), the Conduit gate
  90/91. Later: a missed-reads soundness bug found by the S0 stats work (fixed, red-proven), and tag
  reads for `case` scrutiny (soundness review clean, invariant asserted on every corpus program).
- `browser-direct` designed (`browser-direct.md`, five adversarial rounds until no wrong-page
  case remained); the owner took all six questions (no batching, payload read at the event, …).
- S0: the platform skeleton (empty page 399 B, kill criterion 2 passes) and the stats gate
  (kill criterion 1 fires on four of six: scalar-model counting, navigation's `patchAll` share,
  pairs per key, the trie under `++`). Track U (fewer unknown messages) recorded, deferred.

**What I learned**
- "Re-render everything" hides dozens of edge cases; a direct-write design must state each, and
  adversarial review on paper found them before any code: blank remounts, late responses for hidden
  pages, ordering of derived values, non-bubbling events, queued `preventDefault`.
- A green review is not soundness: an implementation bug in the analysis (ignored reads) survived
  five clean reviews and was found by running the analysis on real apps. Run-time nets (verify mode,
  fuzzing) are not optional.
- I misapplied the owner's minifier rule to justify added runtime; that rule is about byte tricks
  only. Runtime is a balance, judged per byte.
- My own partial restore of a fixture (a missing release golden) looked like an old defect for an
  hour; check the obvious before investigating.
