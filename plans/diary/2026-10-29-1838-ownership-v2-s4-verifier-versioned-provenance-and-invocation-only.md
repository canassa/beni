## 2026-10-29 18:38 CET — ownership v2 S4-verifier: versioned provenance and the invocation-only bit

**What I did**

- `within`'s provenance is a port: every proof reads it. A conflicting second pair, or a clearing of
  the bit, invalidates the proofs that used it and every instantiated copy, whichever order the
  facts arrive in.
- Added §2.12's invocation-only bit:
  - it is set at the fold, cleared when a label that stops above the pair's parting depth folds in,
    ANDed at joins, and kept by instantiation;
  - `within` accepts a cell inside one of the calls, or the folded label itself only with the bit set.
- Witnesses:
  - refused: `help`'s own `arr`, its folded form, its `prefixWithin` copy, a nested capture answer,
    and a join of a set bit with a cleared one;
  - kept: C.6's mapped fresh callback and NestedTraversalShared.
  - Each new rule, removed in turn, fails a witness.

**What I learned**

- The uniform fold drops exactly the depth that tells a callback call's allocation from the
  callee's own. Only a bit computed at the fold can keep it.
- Two of my mutation checks first broke the build instead of the rule. A mutation that does not
  compile is no evidence; check that each one ran.
