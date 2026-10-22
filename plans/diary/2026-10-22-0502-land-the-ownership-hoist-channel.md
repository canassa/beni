## 2026-10-22 05:02 CEST — Land the ownership hoist channel

**What I did**

Merged [#677](https://github.com/canassa/beni/pull/677), part of [#315](https://github.com/canassa/beni/issues/315): the ownership checker's accepted record demands, read identities, exact source paths, placements and captures now reach lowering through a module-local table. Cache-entry format 13 carries table format 1, including in the checked core. Report-only tables cannot authorise stores; the lowering's guard requires a clean module and an accepted demand. Record updates still emit spreads. The dated specification amendment precedes the implementation.

Pinned the channel with a red-first ownership fixture, cache corruption and warm-loading tests, and all five record mutation controls, including wrong placement. Recorded 30 generated answers at seed 315 and compared them with the pre-channel spread compiler. The generated research-page transcripts stay unchanged. The generator formats its output so regeneration preserves source positions and hashes.

Kept master's new write extents when rebasing, with its updated summary goldens. Builds, hash recording and full gates ran on dagon, with no LLVM builds there, measurements, weakened checks, new caps, budget raises or Lean changes. All required CI checks passed, including the wasm/native comparison. Answered the review's diary note with the owner's requested order: merge, then this entry.

**What I learned**

A callee can write a field whose name is absent from the caller's BIR symbols, so the channel owns a field-name blob. A nullary method call is still a field access in frontend BIR when a cache entry is validated: its cached dispatch site must establish that it is a call before the rewrite is replayed. The cache regression failed on a warm rebuild before that fix.

The channel can land independently of #286 because it enables no stores. Enforcement, eager loads, stores, the optimiser barrier and sanitiser remain the later slices' work.
