## 2026-10-13 23:33 CEST — ownership proofs for direct browser lists

**What I did**

Started ownership-browser-direct from freshly fetched origin/master; fetched the
browser-direct-s5 reproduction without moving its unfinished effects implementation.
Specified two checker refinements as dated ownership-contract amendments. Escape
checks now ignore mutually exclusive earlier arms, while summaries still join all
escapes. The model entry solves fresh update-result conditions as an inductive must
invariant instead of letting an uninitialised result poison its own preservation
condition. Bumped ownership blocks to version 2 to invalidate the old rules.

Promoted ValuePath from pending and imported/promoted the tap reproduction from the
S5 branch. Added accepted pages and rejected twins for fiber/queued escapes, child
lists duplicated at init and by update, and dictionary tap lists shared at two keys
and in an old snapshot. The dictionary helper preserves its borrowed tap container
with an explicit shallow copy; tap and tagger identities remain intact. Dict.update
alone was investigated: the complete driver still could not prove its deep
exclusivity requirement over opaque keys/taps, so no such assertion was added.

Verified all previous ownership goldens unchanged. The copied complete driver failed
at three sites before the changes, only want after the branch refinement, and none
with the borrowed-container fix. Stashing the two checker files proved ConcurrentJobs
and ValuePath fail before the checker fixes; both now pass their browser-tea/direct
pages and value fuzz. Full run-hash recording updated corpus records, but the step
ended at the two known macOS case-folding failures. Full gates and LLVM validation
follow; the owner's four known macOS failures are left untouched.

**What I learned**

A sibling arm's escape is not a holder in the arm that writes, but its summary must
remain escaped for callers that cannot choose an arm. Recursive list exclusivity
is a preservation invariant and must start future fresh allocations optimistically,
then monotonically lower their conditions; unknown and escaped inputs cannot inherit
that proof. A borrowed dictionary value is a different issue: the generic helper
permits aliased entries and retained old dictionaries, so intentional persistence
requires a new outer tap list. The accepted alias twin observes 2:1:1 for the changed
entry, untouched entry and old dictionary; the uncopied twin remains rejected.
