## 2026-11-03 05:46 CET — values lane: jump pointers and DAG walks

**What I did**

- Checked the 10 summaries that `covsum` flags as saying less after the
  identity control. I wrote four sanitiser probes (`cv12-tea1`, `cv12-tea2`,
  `cv12-wp`, `cv12-nested`). Each one has a caller that relies on the old,
  larger claim. The old binary refuses each probe. The new binary accepts
  each one, with the same output under `--sanitize-lists`. The probes are now
  in the oracle. I did not change `covsum`: the new claim is strictly
  smaller, so it is not a set inclusion that `covsum` can check.
- The distinct check's entries keep skew-binary jump pointers (`Jumps.zig`).
  CallChainShare `merge` is 328 / 534 records a call at 10 / 40 (was
  337 / 753). It still fails the bar.
- `projectLevels` meets each (value, place, literal route) once. The shared-DAG
  fold certificate was 2ⁿ and is now about n²: 19 029 records at depth 12,
  was 284 154.
- A literal's plain occurrences are projected by one walk a parameter. The
  doubling DAG of shared values passes (826 records at depth 8, the bar is
  912).
- `Within.lookup` asks each earlier member once. This is a small gain for
  k list fields.
- build_test went from 4 failures to 3. Every summary is byte-identical on
  the 2 196-root ledger after each step.

**What I learned**

- What is left of `merge`/`indep` is inherent to listing leaves: `y_k[*]`
  holds k fresh atoms. Flat cost needs an atom set kept with the value and a
  membership query, which is a representation change.
- What is left of the fold certificate is Σj distinct tag conjunctions, one
  for each start of the else chain. The tags of a chain of choices would have
  to be shared.
- k list fields grows as k³ in several places at once (`callWriteFrom` →
  `project` → `setOf`, `instSel`, `holdsAt`). The cause is k calls × k
  written paths × sets of k slots. The callee's writes are listed path by
  path, not held as one subtree.
- The read-off's "once per node" path (`callNode`) cannot help
  `oneOfHelp`. It needs `acyclicBelow`, and `Result Error a` is recursive.
  Making it work while drafts are live is not enough.
- Files in `own2/` have line targets. Small additions to `Relation`
  (1 300 lines) and `Distinct` (750 lines) need a split first (`Ends.zig`) or
  a shared helper (`projectAll`).
