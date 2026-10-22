## 2026-10-22 03:35 CEST — Finish representative prefix correction

**What I did**

Redid #447 on current master after #456 landed as #665. A same-cell exact
prefix pair now needs a separation check when the shorter path names several
places, including through a list element, a recursive marker, the Dict tree or
⋆. Updated the function comment and §16.7 to state all three exemptions and
withdraw the disproved approximate-copy assumption. Retained #456's scoped
construction conditions and its positive and negative controls; the paused
restMayBeEmpty tightening stays excluded. Restored the resolved finding's
ledger entry with its current corpus fixture and #665 resolution.

Added RepresentativePrefix and proved its summary golden fails with the fix
set aside and passes after restoration. Retained OneListTwoLevels and updated
PolyRecCps's two callback-supply summaries. The ownership corpus passes within
existing budgets. A correctness-only differential checks 6,296 ordinary and
ownership-everywhere units: zero changed demand verdicts, newly rejected
programs or new crashes; six variant summaries change. ValuePath,
EntryInvariantCommand and ConstructorDiscardedAlias retain their acceptances.

All builds run on dagon with the pinned self-hosted Zig backend. No cost or
size study, cap, weakened check, budget raise or Lean implementation is included.
The unfiltered landing gate is zig build gates, logged with the red evidence
and differential in ~/worktree-evidence/beni-fix-nested-447/. This entry travels
with #447; the final gate, review answer, merge and worktree cleanup complete
this session. The shared ~/.cache/zig-beni cache is preserved.

**What I learned**

#456 already rejects the original viaParam counterexample, so replaying its
old golden is not fresh red evidence: annotation changes alone make it differ.
The focused recursive callback supply exposes the prefix rule's remaining
lost-to-shared summary change. Approximation is not an occurrence proof;
coexisting operands are separated by their containing construction's condition,
which can be discarded with that construction without poisoning either operand.
