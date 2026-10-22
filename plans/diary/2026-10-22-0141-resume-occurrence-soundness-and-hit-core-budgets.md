## 2026-10-22 01:41 CEST — resume occurrence soundness and hit core budgets

**What I did**

Took over #286, #456 and #447 from Codex ownership_soundness on the owner's explicit
2026-10-22 instruction. The owner withdrew the two pre-implementation cost-report
holds and authorized specification and implementation, one PR per step. No cost
or output-size report was produced. All edits and builds were on dagon, with the
self-hosted compiler and the shared global cache; no local Zig command ran.

Saved the abandoned beni-occurrence-spike worktree exactly as found to branch
wip-occurrence-spike, commit 3417fee07, and pushed it. This is an explicitly
requested preservation commit, not a validated implementation. It includes the
unfinished condition-only implementation and its five untracked fixture files.
Recorded that preservation and the takeover on GitHub.

Read the two issues and their comments, #447's review and blocked state, the fold
contract and relevant diaries, the preserved prototypes/design proposals and
ApproxLevels/ApproxTree/transport probes. Started the #456 candidate in its own
worktree, beni-fix-approximate-occurrences, from origin/master at 4adbf7bbc.

Copied the pending projected-alias twins and ConstructorDiscardedAlias controls
from beni-poly. The unchanged master binary accepts all four unsafe calls; the
red regression log is zig-out/approximate-before.log. Wrote a dated amendment in
ownership-checker.md before applying the preserved condition-only implementation.
The annotation is scoped to the containing value and transported by the existing
level marker, rather than lowering the aliased allocation's condition permanently.
The marker's global interning cannot carry conditions of unrelated values.

The candidate refuses both twins and the constructor/helper variants. Its fresh
and exclusive-arm controls stay accepted. ConstructorDiscardedAlias retains all
four acceptances, and EntryInvariantCommand's browser-inline demand lines match
the baseline. These direct outputs are preserved under zig-out. A first manual
probe overlapped binary installation and read the previous binary; it was not
used as candidate evidence. The later separately named candidate outputs use the
completed installed compiler.

Stopped on the owner's explicit budget condition: test-blackbox's two core
ownership cases fail OverBudget under their unchanged budgets. The log is
zig-out/approximate-after.log. The new alias fixture also has a summary golden
mismatch; its four unsafe verdicts are now rejections. No unrelated golden was
blessed, no budget changed, no check weakened, and no cap introduced.

The candidate/spec/fixtures remain uncommitted in this worktree, with a patch and
fixture archive in zig-out. No production PR or merge was attempted with red
checks. No work on #447, F2, recursive-only folding, lvl, the permanent refusal or
removing k has started. ValuePath and the full-corpus differential remain unrun;
there is no zero-delta or soundness-complete claim. The Lean work is untouched,
and remains an obligation before a production change lands.

**What I learned**

Value-scoped construction conditions distinguish the required bad/good controls
on current master without reviving the rejected restMayBeEmpty tightening. That
is necessary evidence but not enough: the candidate violates existing core test
budgets. The next correction must retain the intended soundness and precision
while satisfying those budgets; this session does not authorize a budget raise
or weakening the ownership check. The owner-required stop is reported on #456.
