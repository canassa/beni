## 2026-10-15 20:04 CEST — Plan the ownership soundness proofs

**What I did**

- Read issue #165, the executable model, and the thesis soundness argument.
- Added `proofs/ownership/PROOF-PLAN.md` with the induction measure, stronger internal contract, fragment, and complete case inventory.
- Added regression witnesses for construction fuel, linked views, and summary observers.
- Opened issues #168, #169, and #170 for the three findings.
- Kept the checker, interpreters, theorem statements, and axiom audit lists unchanged.

**What I learned**

- The proof needs one depth induction with preservation before summary soundness at each depth.
- The current public statements admit counterexamples before the mutual induction starts.
- The call proof needs result descriptions, certificates, observer permissions, and outside-holder framing beyond `CallSound`.
- Distinct canonical names cannot describe every legal read-only alias.
