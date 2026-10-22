## 2026-10-22 02:45 CEST — preserve construction conditions across recursive folds

**What I did**

Resumed #456 after the owner accepted the additional DictFocus.readLater
callback refusal. The complete program already failed; the callback loses
precision through the same folded Dict tree as grow. Recorded both in #663 and
the dated §16.7 amendment. DictFocusGrow stays in pending with its baseline
acceptance golden, to recover through #294. The owner also authorized the two
core ownership test budgets at 5300M; their assertions remain unchanged.

The implementation attaches list and record separation conditions to the
containing tuple, record or constructor. These conditions travel through the
existing level marker without permanently changing either operand's allocation.
Selecting one operand drops the discarded construction's condition. Explicit
condition-only provenance keeps the annotation out of allocation ownership,
escape, spine and callback-loan checks. Captures, callback supplies and summary
version 19 retain the conditions. Recursive-marker Lean work remains paused;
the amendment states the invariant without claiming a completed proof.

The unchanged baseline accepted all four unsafe routes in ApproximateAliasLevels
and failed its intended refusal golden. The candidate refuses both exact/approx
and approx/approx twins, constructor aliases and helper routes, while accepting
the exclusive-branch and distinct-fresh controls. ConstructorDiscardedAlias
keeps its four accepted demands. The broad differential compared 6288 units:
corpus files/projects, browser-inline, examples, benches, core and platforms,
with ordinary and ownership-everywhere checking. Only the new unsafe fixture
changed a complete program from accepted to rejected. No new crash occurred.
EntryInvariantCommand and the retained ValuePath remain accepted. The remaining
report changes are the authorized Dict debt and rejection reasons within
already-rejected PolyRecShared/PolyRecTuples programs, plus the intended summary
annotations. Only ownership summary goldens are re-recorded for this change.

All work, builds and tests ran in the isolated dagon worktree rebased on
origin/master 776a3930b. A saved baseline binary and the differential results
remain in its ignored zig-out directory. Btrfs metadata pressure prevented Nix
from recreating a development shell reliably; the already-realized shell for
the identical flake and lock supplies the pinned Zig 0.17 and Node 24.19 with
the shared global cache. No Zig command ran on the Mac. The abandoned spike
was preserved separately on wip-occurrence-spike before this implementation.

**What I learned**

Construction conditions need value scope: preserving a fact on an allocation
would incorrectly refuse a write after its aliasing subtree is discarded.
Keeping annotations out of allocation accounting also matters for callbacks.

This session lands only #456. The nested correction, full-type cast marker,
recursive-type fold, per-level exclusivity and cut removal remain separate work.

The ownership-only golden pass found Conduit at 4320M against 4300M. Under
the owner's budget authorization, its corpus grant is 4760M, with removal
tracked by #286 once ownership checking puts the case below 4300M again.
No assertion or verdict was changed for this budget failure.

Run-hash validation encountered the existing HttpServerBadClients abort race
tracked by #515: handlers ran 6 instead of 7. Its expected output is unchanged;
only that failed fixture is retried before the unfiltered gates.
The serial retry passed both development and release runs, recording the same
two existing hashes. All other run-hash cases passed in the full run; no run
hash change remains in the worktree.

The unfiltered self-hosted `zig build gates` passed on dagon. The log is
preserved with the differential evidence under
`~/worktree-evidence/beni-fix-approximate-occurrences/` before worktree cleanup.
