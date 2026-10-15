## 2026-10-15 00:56 CEST — Sync the ownership oracle with the checker

**What I did**

Worked from current origin/master in an isolated worktree. Extended the Lean
checker with branch-local escapes, model/fold container invariants, render/event
slots, carried constructor callbacks and owned-result tagger boundaries. Added
44 verdict fixtures and 204 finite products, with ten new required holes and
concrete final-heap certificate checks. Updated the spec's residual-gap table
and the proof reports, retaining the three existing unproved obligations.

The pinned Lean build, default ownership CI, clean source/kernel audit and
20,000-case falsifier pass. The compiler gates pass apart from the two known
macOS case-folding tests. Reduced two cache-pruning fixtures to the minimum
counts that still test their bounds; their 5,000-file setup exceeded the fixed
macOS CPU fallback even on a focused run. Prepared the changes for PR review.

**What I learned**

Equal interpreter observations do not validate a published certificate. A
record can capture an earlier list position without writing it, leaving the
values equal and a claimed container invariant false. Concrete heap checks
exposed append, focus and canonical fold-input cases. Different canonical
parameter names also do not prove separation: the owned state must carry the
actual aliases into summary inference. Capability distinctions can mask an
old mutant by changing its cache key, so the generator needs a matching-state
probe followed by an operation that observes the missing condition.
