## 2026-10-26 03:07 CET — Ownership v2 re-review: per-value κ, type-depth S_f

**What I did**

- Answered the re-review of #1038 in `docs/design/ownership-v2.md`, in place:
  - κ snapshots are now per value. A snapshot travels with its value's shape root and is joined only where values join, so a dead `[ r, r ]` no longer weakens a live `[ r ]`. `DeadDuplicateLive` is pinned in Appendix B as a green twin.
  - The holder and callee path words take L from the atom's own value's place, and S_f is stated as source size × type depth.
  - §2.5 states the adjacent-arms precondition of `rank₂` and the `|>` form of `withDefault`.
  - §7 item 5 cross-checks `rank₂` against the ancestry query.

**What I learned**

- A holder-wide κ map keyed by node is sound under the stored-plus-derived read rule, but it loses precision across unrelated values. Keying κ by value removes that loss and costs no soundness argument.

**Later in the session**

- κ is now keyed `(NodeId, PathId)` within a value, so two positions of one value no longer share a condition. A frame holds `value → KappaId`. `Shape.map` grafts the keys at an instantiation.
- The union read rule is in §2.9.
- A new `positions` node kind (§2.3) separates a positional collection from a `union` of alternatives. A list literal's `[*]` used to be a `join`, so `f a b = [ {a=a}, {a=b} ]` called as `f x x` derived `yes`. The twins are `PositionsRepeatArg` (red) and `BranchSameElement` (green).
