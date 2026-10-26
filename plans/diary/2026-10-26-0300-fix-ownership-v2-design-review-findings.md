## 2026-10-26 03:00 CET — Fix the ownership v2 design review findings

**What I did**

- Answered the adversarial review of #1038 in `docs/design/ownership-v2.md`, rewriting in place.
  §1.2 and §1.3 now state the per-path sharing predicate. §2.5 and §2.7 make region compatibility one
  threshold on a second order of points (`rank₂`). A query reads a demand's path once and runs one
  query per prefix on that step's own lane. §2.8 gains *Holders across a cycle*: anchor chains and
  refinement chains, so a write under `⟲` finds an on-cycle container's holder (`RoseKidsHeld`).
  Supplies are keyed by label. §2.13.3 no longer uses node-keyed κ. §8's S3a row now carries the gate update.
- Reverted the R-5.10.8 sentence on the four List readers. That was the manager's decision, and it left R-5.10.8 unchanged.
- Folded in the coordinator's S2 facts:
  - κ maps are keyed by (node, position class).
  - A κ read joins the stored condition with the one derived at the read's position.
  - Position-level `apart` covers `[(a, b), (b, a)]`.
  - `Cond.deep`, the S1 split record and S2's supply record are described.
  - `Use.atom` is the use occurrence.
  - Two red twins: `CallbackFieldPositions` and `CallbackFieldPositionsBranch`.
- Ran one adversarial verifier on the bounds and the cycle rule, and folded in what it found:
  - the virtual `withDefault` arm pin;
  - refinement chains;
  - deep-only reading of the reverse direction;
  - type-sized holder and callee path words in S_f;
  - per-cell chain costs.

**What I learned**

- One candidate plus an ancestry test still rejects up to case-depth candidates. Only an order of dimension two removes those rejections. The `withDefault` virtual region breaks dimension two unless the inner call joins the f arm.
- Anchoring by canonical path misses refinements, because they hang off the cell they refine. They need a chain keyed by their canonical path.
