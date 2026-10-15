## 2026-10-11 15:54 CEST — executable ownership core and a retained finding

**What I did.** Built `proofs/ownership/` from `origin/master`: a Lean 4.29.1
Lake project supplied by a Nix shell, separate value and heap interpreters,
per-path ownership inference, and ordinary map/initialize/foldl declarations
over traversal, focus, builder and close. After those ran, delegated the
sharing generator and thesis-fixture audit to Sol as requested. The old builder
rule rediscovered internally shared callback results and produced shrunk,
executable regressions. Proved the concrete builder/close footprint contract
with no Mathlib or `sorry`. Stopped further exploration and proofs when the audit
found traversal dropping callback escape facts. Preserved its expected-reject
fixture and documented the unfinished coverage and proof obligations. The thesis
and production compiler are unchanged; the PR is a draft, not a soundness claim.

**What I learned.** Freshness and path multiplicity must remain separate:
`[cell, cell]` has a fresh outer root and a duplicated inner footprint. The
exclusive-element premise closes that negative control, but deriving a library
summary still needs every effect of its callback, including escapes independent
of its result. A trace oracle cannot detect an escape-demand failure if the
abstract permanent-holder marker has no observable global-read semantics; fixed
verdict tests expose that gap. The first missing invariant is in the executable
core itself, so proving the top-level theorem would be premature.
