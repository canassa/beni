## 2026-10-11 17:45 CEST — ownership thesis round 5, list decisions (manager)

**What I did.** Correction first: the paragraph above beginning "Later the same session" is mine,
not the Lean entry's author's; my session entry was lost before it was committed, so here it is.
An external read-only review of the ownership thesis, run without the earlier reviews, found a
real soundness hole: `map`/`initialize` granted exclusive contents to fresh callback results
without requiring them to be exclusive inside (`[ cell, cell ]`, now T59). Revised and merged as
PR #44 (151 pages). The owner decided: Change 9 accepted (opaque types publish numbered list
slots); the identity promises kept (O2); prepending is an anti-pattern, so no headroom (O3
withdrawn), `[ …acc, x ]` is the canonical accumulator, `[ x, …acc ]` copies, and a
prepend-in-a-loop warning is planned. An agent started that code slice and the owner stopped it
mid-way; its uncommitted work is in worktree `agent-a7e32047d7f425e81`.

**What I learned.** Every review round finds holes in asserted library rows, never in the core;
more paper revisions don't end that, while the Lean oracle derives the rows and finds such holes in
milliseconds. A Lean core built on `partial def` cannot carry the proofs; the first draft had to be
made total. An implementer brief must order spec before code, and forbid rewriting fixtures that
exist to test the old shape.
