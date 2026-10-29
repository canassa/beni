## 2026-10-29 17:23 CET — ownership v2 S4-verifier spike

**What I did**

- Built `src/own2/Fix.zig`'s proof half (#1180): `Fix.Prover`. It works on a finite obligation
  graph over settled may-facts. Goals are decided by component with an explicit-stack Tarjan. A
  recursive component's base is read with no assumption and its step under the members as the
  explicit assumption. A component with no base is `waiting`. Settled generations use per-port
  versions and reverse reader and user edges, and a solve publishes all of its answers or none.
- Evaluators over the existing algebra: `gen`, `inv`, `within` and `apartCalls`. With them,
  traversal `Marks` with the crossing rules and a validating word codec, `within` provenance
  (`foldPair`), keyed closure `Families`, once-token `Uses`, and `diverge`.
- Wrote 13 witnesses for §8's S4-verifier row, with test equations and no walker inference: every
  C.11 red twin, FeedbackPrevTwice and its safe twin, FoldCallbackIdentity,
  RefinementFeedbackTwice, JoinedClosurePorts, CallFeedbackGeneration, GrowFresh, GrowAlias and
  RecursiveClassGrowth, late weakening, a mid-solve version change, failure rollback, and counted
  work. Each of 13 mutations, one rule removed each, fails a witness.
- Recorded the verdict in `ownership-v2.md` §8 (*S4-verifier: as built and verdict*), and
  updated §2.12, §5, §9 and C.9 in place.

**What I learned**

- Verdict: feasible, guarantees kept, and the work is linear: 11 growth records per goal at
  10 / 100 / 1,000 goals. A change invalidates only its dependents.
- Soundness tightening: generativity separates two invocations only when neither runs inside the
  other. A callback that re-enters its caller breaks this, so two callback labels need diverging
  chains before `gen` or `within` separates them.
- The rollback witness found that publication could stop part way through a solve. It now
  reserves everything first.
- Gap 3's narrowed rule cannot be stated in the existing algebra: it is an atom over the incoming
  accumulator and the current supply. `lost` stays, and FeedbackPrevTwice's safe twin is refused
  approximately.
