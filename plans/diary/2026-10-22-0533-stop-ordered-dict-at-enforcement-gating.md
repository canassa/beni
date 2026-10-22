## 2026-10-22 05:33 CEST — Stop ordered Dict at enforcement gating

**What I did**

Merged #673, closing #670 with all checks green. The storage/deep extent
amendment and summary block v20 preserve every existing ownership verdict.
The review was answered, and oracle requirements were posted on #316 without
editing Jayson's proof files. Removed the fix worktree and both its branches.

Resumed #294 from its verified evidence archive on dagon. The restored Dict
rows now mark storage writes explicitly. Set.sortBy and the exact #670
reduction passed the core stage. Removed the old Dict tree checker exemptions
and drafted Tea's specified private sorted arrays, with comparison-based
binary search and contiguous prefix cancellation. Added comparison-key
refusals, correct Dict.copy/Set.copy storage diagnostics, borrowed-value
permutation twins and command/subscription lifecycle cases. DictFocusGrow's
acceptance recovered and passed as a normal corpus fixture in the draft.
The targeted insertion-order, permutation, diagnostic and browser cases passed.

Stopped the runtime work under rule 10 at #681. Default Node and browser-tea
builds accept a write the ownership dump rejects; the Node reduction prints
2/2 after changing a still-live old Dict. Both builds refuse with the hidden
ownership-everywhere flag. Enforcement remains gated by the platform's list
setting, including the audit of platform bodies. A normal build passing is
therefore not evidence that Tea's new table has been ownership-audited.

Preserved the complete uncommitted overlay, patch, reductions, logs, README
and verified SHA-256 inventory on dagon at
~/worktree-evidence/beni-ordered-dict-enforcement-stop/. No runtime source was
committed or published. Remaining API migrations, generated skills, goldens,
run hashes and the full runtime gate remain owed. The unrelated stale pending
RED index was filed as #678; no pending or gate assertion was weakened.

Returned this worktree to current origin/master to publish this diary entry.
All builds and edits ran on dagon with the self-hosted compiler. No local Zig,
LLVM, measurements, caps, budget raises, copying fallback or platform manifest
workaround was used. Cleanup follows the diary PR's merge; the shared Zig
cache is retained.

**What I learned**

A correct summary and a rejected ownership report do not protect a platform
whose normal build skips enforcement. The mutable representation cannot land
until that language-level ownership boundary is resolved; a hidden flag is
only diagnostic evidence, not an implementation fix. The old persistent tree
on master does not have the draft's demonstrated wrong result.
