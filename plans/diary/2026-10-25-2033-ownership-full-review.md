## 2026-10-25 20:33 CET — Ownership full review

**What I did**

Verified the independent review's blocker, three majors and fourteen minors against the design, requirements and origin/master c349ed1fc. Revised only the two ownership design documents. Source/import work now has nonfungible, proved baseline lanes; only inferred growth spends the single raiseable 65,536-record allowance. Added loan-store and suspension rules, explicit sequence/cell/failure metadata and slot-operation words, affine once identity, deterministic accounting/failure behavior, missing interfaces and implementation work. Appendix B specifies the new red/green twins for their implementation slices.

The read-only adversarial verifier found an import-credit loophole in an additive allowance, a Ref.modify loan-return obligation, slot-state branch joins, forwarded append write demands and accounting clarifications; all were incorporated. It found no remaining accepted aliasing write or termination/fail-fast wall in the final rules. Mechanical audits map all 260 requirements and 45 existing pending roots, find 0 bad edges among 99 module imports, and recompute 123 implementer-days / 102 critical-path days across 14 slices. Documentation diff checks pass; no compiler behavior changed or compiler tests run. PR #1010 receives the Round 7 finding table; no merge.

**What I learned**

A fungible allowance based on imported summary size can finance exponential wrappers indefinitely. Import-read credit must not pay for new invocation identities. A complete resource proof must count failed and repeated queries as well as output facts, while keeping source-linear work out of the growth limit. Slot barriers also require explicit state/effects and lifetime rules: a returned alias of stored contents is a loan even when the enclosing record is fresh.
