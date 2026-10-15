## 2026-10-15 12:35 CEST — Extend the ownership oracle

**What I did**

Extended `proofs/ownership/` with typed Result elimination and definition-local
question lowering, recursive Chain payloads and consumers, and initialization
transfer with retained callback environments. Added eleven required holes for
these rules and PR #124's six existing corrections. Every hole is caught by a
fixed typed interpreter disagreement and the independent targeted product.
The final set has 167 verdict fixtures and 472 targeted programs; all 22 targeted
controls pass. Updated the normative gap list without claiming renderer, opaque
encoding or arbitrary mutually recursive type support.

The CI bridge has 915 inputs, 462 value checks, 6 forward / 8 reverse leads and
zero confirmed unsafe originals. The full bridge has 116,605 inputs, 43,180 value
checks, 1,725 forward / 401 reverse leads and zero confirmed unsafe originals.
All historical enumeration/generator hashes match. All 401 historical reverse
refusals are unchanged. Retained compressed sources, complete interpreter traces,
per-control counters and replayable hole cores in `evidence/oracle-extension/`.

Both the in-build audit (3,253 constants) and independent clean-checkout audit
(32 sources, 4,709 constants) pass with the existing three unproved statements.
Local compiler constituents: 1,302 passed, 15 skipped and the two documented
macOS case-folding failures. Hosted Linux tests pass without hardware budgets;
the reference hardware-budget gate remains owed on supported x86-64 Linux.
PR #132 is open and unmerged. The automatic review found no issues; the explicit
`@claude review` follows the evidence push.

**What I learned**

The six shipping corrections already had corresponding Lean protections, so
independent holes add sensitivity without changing the historical seeded stream.
The 149 added fixed programs contribute 114 translated agreements and 35 counted
skips. A private initializer's transfer authority must be consumed at entry: a
nested entry must not clear a later publication using an old permission. A
recursive question also needs bottom propagation while its optimistic summary
is being solved. Neither finite campaigns nor an agreeing persistent JavaScript
runtime establish a proof of in-place safety.
