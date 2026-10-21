## 2026-10-22 00:11 CEST — combined solver slice 4: facts 1, 2, 4 and 5 solved

**What I did.** Issue #637. Facts 1, 2, 4 and 5 and truthiness now come from one sparse fixpoint
(`Spec.solve`) over constraints extracted per module (`Extractor`), on the emit workers, with fact
3 read as input. A safety build of a small program runs the sweeps first and panics, naming the
node, on any disagreement; the whole corpus also passed with that check unbounded. Outputs are
byte for byte the same except `emit/release/app/SpecDeepChain` (E1), whose cliff was `max_sweeps`:
it now specialises. To keep anything across analyses I scoped the rewrite's and `prune`'s changes
to their statements and keep extraction per statement. The `backend.md` note is *As built
2026-10-22 — slice 4*, with an *Amended* paragraph on E1 moving now rather than in slice 6.

**What I learned.**
- Slice 4 on its own is slower in the facts step (N = 64: 10.1 → 11.6 ms at one thread), because
  the walk becomes an extraction plus an evaluation and the rewrite still changes the large
  statements every round. The gain is slice 6's, which removes the repeated analyses.
- Peak RSS has three traps: per-worker scratch that keeps the largest module (+13% on TodoMVC at
  32 threads; size threads by work), safety builds touching reserved capacity (0xAA fill), and
  allocations in `Pts.tmp`, which is only emptied when fact 3 solves.
- `check/rules_test`'s scan of `src/js` costs instructions in proportion to `Spec.zig`'s size.
- dagon's /home filled up mid-session; the coordinator freed it.
