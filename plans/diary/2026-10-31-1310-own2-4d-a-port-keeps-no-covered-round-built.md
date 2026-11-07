## 2026-10-31 13:10 CET — own2 4d: a port keeps no covered round (built)

**What I did**

- Built §2.3 *A port keeps no round that its last round covers*, option (a), in `Summary.join`
  (#1470). A class join in `choice` mode takes the other side's `res` and κ when one side is under the
  other. Otherwise it drops each covered arm of a side's top choice, `a`'s first, then `b`'s against
  what is left of `a`. The `leq` work is charged. An entry at a removed choice node is joined into the
  entries of the arms below it.
- Measured (self-hosted Debug): `mergeSort` from a limit to 36 853 records in 3 walks, growth 0.
  `rose` 16 644 → 10 085. `descend` 437 829 → 178 999. The corpus's records went from 6 415 320 to
  6 040 556 (−5.8 %). The only verdict change is `mergeSort`. Removed its known limit and added a
  known entry for the second accumulator that v2 finds in `split`.
- Checked the stop rule with a scratch build that walks every member again against the final ports
  (1 652 walks, 0 mismatches). The same check fails 283 walks when the read check is removed. The
  full cross-check over the ownership corpus fails only v1's five panics, as on master.
- Added a counted test for `mergeSort`. It fails on master with a limit.
- Filed #1472: nine `res` paths read weaker, among them core's `Result.combine` and `partition`. A
  caller that edits an element of `combine`'s result is refused.

**What I learned**

- Almost all of the gain is rule 1, taking the round when the port is under it. With rule 1 replaced
  by the full join, the arm drop alone saves nothing and `mergeSort` stays a limit.
- Rule 1 is where precision goes. The new port equals master's under `Shape.leq` and `kappaLeq`, in
  both modes. But the tail call's delivery over it reads `lost` where master's reads `excl`. So `F` is
  not invariant over `leq`-equal ports, and a `lost` in the port stays.
- The summary text alone does not show a precision loss well. A per-path read (`lost` if any
  alternative is `lost`) compared before and after found the nine weaker paths among 138 changed
  summaries.
- `std.process.hasEnvVarConstant` is gone in Zig 0.17. For scratch variants, a comptime constant and
  one build prefix per variant is quicker than finding the new environment API.
