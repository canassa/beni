## 2026-10-22 01:58 CEST — authorized core budgets and DictFocus refusal

**What I did**

Resumed #456 on the owner's explicit authorization to increase the instruction
budgets. The two affected core ownership tests now use 5 300M each, based on the
previous failures plus about 10%. Assertions are unchanged. The grant is recorded
in CLAUDE.md, the test constants, the dated ownership-checker.md amendment and
#456; #514 remains the reduction/removal condition. This entry supersedes the
budget stop in the earlier entry; that entry is not edited.

Ran the ownership corpus on the candidate. Seventy-seven summary goldens differ;
extracting the expected and actual demand lines found four fixture groups with
line changes. SplitCap's new refusal was an implementation defect: a value-scoped
condition annotation was counted as an extra mutable allocation in a callback
supply. Separated its condition transport from the ownership probes and allocation
count. The focused SplitCap run now has zero changed verdicts, including its
already-refused nine-cell case. No golden for this existing fixture was blessed.

Also corrected the raw spine query for an annotation: a condition has no array
spine, so contributes the trivial spine condition. Its deep-sharing condition is
retained. Callback supply composition now transports the annotation's list and
record conditions, and annotations do not become callback allocations.

DictFocus still has two changed demand verdicts after those corrections. In
particular its safe grow function builds a dictionary with two distinct fresh
lists, then edits one through Dict.update and Maybe.map. The baseline accepts the
Maybe.map callback at 24:26; the candidate refuses it exclusive. ReadLater's
callback at 49:34 changes too. The complete-program readLater case was already
refused; grow is the decisive new false refusal. The new construction annotations
in Dict.insert's folded tree result publish lost deep conditions. Treating
annotations as having no array spine did not recover this dictionary precision.

Stopped at the owner's remaining explicit condition: a safe refusal is reported,
not blessed and not fixed by weakening the sharing check. No Dict exemption,
copying fallback or new cap was added. The original four projected-alias unsafe
calls are still refused and ConstructorDiscardedAlias still has four accepted
demands in the latest completed binary. No full-corpus zero-delta or green-gate
claim is made. No production PR or red implementation commit was made; #447 and
all later steps remain unstarted.

All work, the candidate patch, fixture/diary archive and logs remain in dagon's
beni-fix-approximate-occurrences worktree. The two affected core tests are checked
separately under the new grants; their result is recorded on #456. No size or cost
report was produced. The abandoned spike remains safely pushed as 3417fee07 on
wip-occurrence-spike. The Lean work remains untouched and no proof claim is made.

**What I learned**

An annotation must remain distinct from a mutable allocation through every query,
including supplies and raw spine queries, not only through its serialization and
separation rules. Correcting those distinctions preserves SplitCap, but does not
by itself preserve the precision of core Dict's existing merged tree fold. That
remaining false refusal prevents landing this candidate under the agreed bar.
