## 2026-10-26 02:12 CET — Align ownership design with implementation

**What I did**

Read the complete review/reply history on #1026, #1027, #1030, #1032, #1036
and #1037, the associated issues and the owner's October 26 decisions. Rewrote
the normative ownership design in place: constructor-template adapters,
traversal provenance, cyclic overlap, immutable per-path κ, cell use marks,
functional summaries, label-keyed supplies, canonical blocks and pre-work
accounting. Moved the sanitiser's specified limits into verification, removed
settled forks and stale implementation notes, and assigned the remaining adapters,
holder index and κ transport to their slices. Requirements name the pinned
sortWith row and conservative fold-element condition. No compiler code changed.

A separate read-only verifier attacked contradictions, soundness and accounting.
Its findings corrected the κ lattice inequality, folded-duplicate causes,
cross-path sharing and the liveness prefix-query accounting boundary. Final
verdict: no remaining blocking finding; no accepted aliasing write found.

Validation on dagon: `flock /tmp/beni-codex-gates.lock zig build gates` exited 0;
`git diff --check` passed. Mechanical audit: 260/260 requirement ids, all 45 pending
fixture roots (47 sources), unchanged section numbers, 24 production modules on
14 layers with 103 import edges and zero bad edges. The reference plan remains
131 implementer-days/110 critical-path days, explicitly not a calibrated calendar
forecast. The uncommitted direction report is
`~/.cache/beni-agents/own2-direction/report.md`; evidence and verifier output are
under `~/.cache/beni-agents/own2-update/`.

**What I learned**

Interned shape identity cannot own mutable proof state. A value needs an immutable
κ interpretation, including during joins, projections and callback substitution.
The `single` bit and entry mark express one traversal certificate, whose ordinary
calls, recursion, grafting and import transitions must agree. Per-path exclusivity
does not excuse checking an alias through a different sibling path. Likewise,
source-sized lane proofs must describe the actual liveness query kernel: one
contiguous range is bounded; repeated prefixes, intervals and candidates need
separate accounted work. Integration proofs and measured growth headroom remain
implementation obligations, not consequences of green foundation unit tests.
