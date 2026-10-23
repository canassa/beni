## 2026-10-23 02:43 CEST — Complete the full cast review

**What I did**

Completed the review follow-up for #748, Part of #286, with the existing
path cut retained. The owner selected deferring its removal to (c), after
(a), (d) lvl and (e). Opened #820 for the missing recursive native-schema
constructor fold exposed by the preserved uncut experiment, included the
reduced SchemaCtorCached case, and linked it from #748 and #286.

Replaced the exact error-type fallback with conservative unknown keys and
read native schema callback endpoint types from their immutable plans.
SchemaCastSlot covers generic converted Type/Encoded endpoints: fresh
outer and separate-field writes pass; retained-value twins fail. Conflicting
substitutions now join to absorbing unknown, and closed substitutions do
not count as growth. Portable variable ordinals retain the documented
seed invariant, with a changed-consumer cache regression.

A returned-function probe exposed growing carried signatures. They now
carry their own first/later crossing bit. Capture environments retain their
analysis coordinates through host views. Distinct complete type keys keep
the physical selector prefix justified by both views, with incompatible
remainders retained approximately below it. GrowingReturnedFunction accepts
the fresh outer write, refuses the captured-list write and keeps its
unknown-call twin refused; GrowingFunctionSlot checks convergence of
recursive callback-slot coordinates. All three new corpus fixtures are
cached as well as checked fresh.

The final soundness audit found that a single uncertain view and a spatial
repeated read needed separate modes. A red tuple-path unit demonstrated a
missing inner root holder. Repeated reads now always scan every matching
boundary, while only a single view may retain its justified prefix. The
reduced unit and the incompatible-holder unit pass. Structural constants
also avoid an unnecessary nominal-table lookup, correcting the unit crash
caught by the first gate. Every spec clarification was a dated amendment
before its implementation; none renumbers the existing contract.

Rebased onto master c79840a7c and integrated its lazy summary directory and
path reader with the full cast DAG. Format 32 invalidates the earlier
layouts and semantics. The lazy scanner and decoder both retain wildcard
scope words and resolve cast keys from their own block table.

**Validation**

All builds and tests ran on dagon in the flake shell with the self-hosted
compiler. The final unfiltered gate passed under /tmp/beni-gates.lock.
Core and every platform have no rejected or pending line under the full
condition/canonical cross-check. The ownership/core corpus and the
changed-consumer cache regression pass the same cross-check. The complete
ownership corpus passes, and comparison of every changed existing snapshot
confirms unchanged accepted/refused verdicts, including FullCast. The earlier
locked run-hash refresh passed; this follow-up changes no runtime, emitter,
core source or run output. No local Zig, LLVM builds, measurements, added
caps, weakened assertions or raised limits.

Answered both detailed reviews, including the ordinal invariant, physical
trailing casts, folded occurrence conditions, conflict joins and slot-path
coordinates. The PR records the deliberate retirement of the old width
refusal in favor of the complete indexed check; it does not claim that
retired limit still fires.

**What I learned**

Type uncertainty does not imply another physical level. A common selector
prefix can remain meaningful across different complete types without proving
type equality. A repeated-type read has the broader denotation: every matching
boundary, including an inner one that reaches the read root. Sharing that
shortcut would have omitted a holder; preserving this distinction is part
of soundness, not merely precision.

All scratch work now uses zig-out/scratch with TMPDIR set there. Moved the
session's old /tmp files into that directory; only the shared gate lock is
used in /tmp. The uncut source and evidence remain preserved outside the
worktree for #820. No work on the owner's next steps is included here.
