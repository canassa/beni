## 2026-09-27 — R10: incrementality under v2

**What I did**

- Every cache, cutoff, matrix and digest scenario now runs under v2 too (whole files in
  `test-v2`); the cutoff table pins re-checked/cut-off counts, identical under both checkers.
  New scenarios: adv's k1–k8 cache probes, and four edits that move a dependency's derived
  context (a function payload, a `where` on a payload's `eq`, `pub`↔private, a schema `via`
  target), each warm build byte-identical to a cold one. A new `derived_context_runs` counter
  proves I10: a cache hit runs no fixpoint.
- v2's cache path needed no fix. CK-107 fixed (`dispatch_bytes` writer quadratic in types).
  New CK-132, v1 only: a private `eq` added moves no hash, so v1's warm check misses a
  `private_method` its cold check reports; frozen, gone at R12.
- Committed on my own gate run without a separate review: tests plus one byte-preserving fix.
