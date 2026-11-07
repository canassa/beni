## 2026-11-03 01:00 CET — Resolve lane: one walk for a call's paths

**What I did**
- Rebased the resolve lane onto `own2-cost-values` `1fbb8935d` (the two cost lineages are one now), and built step 2 of #1714: `Paths.zig` (L8), one walk of an argument along all of a call's paths into it. `Distinct.instSel` uses it for one parameter's occurrences and `Eval.callEffects` for one argument's writes. Every layer from `Walk`/`Distinct` up moved one place.
- `chainCallCold` 626 / 1 042 / 1 833 → 246 / 278 / 301 records at D = 8 / 16 / 32; "call over a chain of nested choices" flips (build_test 16 → 15). The ledger, summaries, oracle (695 deduplicated probe dirs) and cost table are unchanged.
- Measured steps 1, 3 and 4 and reported why each needs a design change first (#1714).

**What I learned**
- `t_n`'s `req` is a flat selection of 2ⁿ occurrences. A call instantiates it before any demand can be judged, so "one demand per tree node" cannot make the doubling tests linear on its own. An exact fold of stored selections (a slot all of whose objects below are selected plain is one deep occurrence) would make it n + 1.
- The chain call's cost was not quadratic. It was linear with a large constant: every occurrence and every write walked the 32 arms again and made each arm's tags again. Sharing the walk was enough.
- GroupRotate's rounds are 97 % `Resolve.resolve`. Keeping verdicts across rounds needs dependencies inside a judgement (relies, later uses' footprints, escapes), because the group's own draft changes every round.
- The probe sets in `slot-build` hold about 12 000 directories, but only 695 distinct programs. Deduplicating by source makes the oracle run in 8 s.
