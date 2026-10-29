## 2026-10-29 20:12 CET — Ownership v2: `within` re-derived, emitted by W1–W3 and discharged by route

**What I did**

- Replaced §2.12's *Invocation-only folds* with *`within`: emission and discharge*. It adds the
  assumptions A0–A3, W1–W3, the supply join, `within` as a plain κ atom, D1–D4, the proof sketch
  and the five facts that S4's read-off and Calls must compute. It also folds in the attack's
  four amendments: A3 for closures, Dead at each call, D2's fallback only as base plus step, and
  the multiplicity in the certificate.
- In `Fix.zig`, removed the provenance store: the pre-fold pair, the invocation-only bit, the
  conflict state, `foldPair`, `foldInto`, `joinWithin`, `inside`/`under` and the pending copies.
- In their place:
  - `foldWithin` (W1–W3, publishing the certificate with each member's multiplicity);
  - `prefixWithin` as κ substitution;
  - `joinSupply`, `handOff` (A3) and `translate` (Dead);
  - a `within` evaluator over route-tagged cells (`Route`, `Routed`);
  - W2's guard on `diverge`.
- Added witnesses for holes 1–9 and for C.6's three callers, and ported the existing tests. Removed
  each of 27 rules in turn, and each removal fails a witness.
- Opened #1220 for the accepted precision loss.

**What I learned**

- `Cell.Label.folded` is set ad hoc on composite labels. W3's "folded" has to mean that the
  chain holds a fold (`chainFolded`), not the flag on the outer label. A witness had passed only
  because a membership check refused it first. A mutation that should have failed it passed,
  and that showed the problem.
- A mutation run whose log is empty passed everything. The script must report that as "no
  witness", not as a blank line.
