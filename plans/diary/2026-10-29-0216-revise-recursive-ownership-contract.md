## 2026-10-29 02:16 CET — Revise the recursive ownership contract

**What I did**

Rebased docs PR #1131 onto master `5d02c7d81` on dagon, resolving the design
conflicts around the now-landed widening and read fixes. Read review
6430785096 in full, then #1144 and its review 6484771597. Revised the existing
sections around one preimage-multiset operation used at folds, calls, read-off,
printing and blocks. Specified the expression, per-class/cell aggregate and
multiplicity domain, mode-aware merge keys, shared-subtree charging, argument
aggregate reuse and per-dependency settled generations. Added the B-shaped call
counterexample and positive controls, call-built counted towers, and the
transitive pending-knot reader/waiter protocol. Added a separate recursive-proof
verifier feasibility slice before S3b. Restored the Block owner-list correction
and the missing matrix verdict pairs. Added a requirements cross-reference.

Kept all section headings and both complete As built notes unchanged, checked
mechanically against the original PR and rebased master. The earlier diary's
day estimates are withdrawn; the revised plan contains no duration allocations.
#1104 remains an open owner decision. This is a documentation revision, not a
claim that the new primitive, verifier or acceptance fixtures are implemented.
Validation uses the full gates on dagon; the PR response records the result.

**What I learned**

The same lost-preimage defect can appear at a call even when the argument has
never been widened: two constructor branches can reach one list at paths that
a folded callee writes as one class. A per-path deep read does not compare them.
Likewise, graft safety is about every record an operation reads, not just its
direct inputs: a same-base delta join can inspect an untied override child.
Whole-list deferred rescans conceal quadratic work; dependency waiters retain
progress and charge it explicitly.
