## 2026-10-25 15:11 CET — Ownership callback bound review

**What I did**

Reviewed PR #1010's round-five findings against the design, the requirements on origin/master,
the frozen ownership implementation and the vendored Morphic solver. Worked on dagon in the
requested own2-design worktree, starting at 298b414f1. Changed only the design and this entry.

Removed the contradictory ordinary-label fold trigger while retaining the intended per-occurrence
identity rule and uniform summary/recursive fold. Specified one shared actual result template with
lazy invocation-and-supply views; captures keep identity. Clarified unknown record-parameter callbacks
without erasing a known class. Added wrapper, wide tuple/record, union-composition and carried-lambda
recursion cases to the proof and performance obligations. Preserved every numbered section and the
existing Appendix B fixture map; Appendix A still covers every requirement id it covered before.

Launched an independent read-only adversarial verifier and folded its findings into the text.
It found no newly accepted duplicate among twice, once/dup, h/k, pair, List.map's fresh/shared/
identity/writing cases or twoAt. It did not certify the complexity or termination bound.
The design now explicitly blocks implementation on that proof; 83 implementer-days remains a
conditional baseline, excluding the unestimated redesign.

Checked the counting arguments with a standalone representation probe in
~/.cache/beni-agents/own2-design/round5-bound-probe.py, and ran document structure/coverage checks
and git diff --check. These are not compiler performance measurements. No compiler code or fixtures
changed, so compiler gates were not run. Prepared an honest Round 5 PR-body block and preserved
this revision as a local commit. No push or merge: the owner's clean-verifier prerequisite is unmet.
The worktree is removed after committing; the local branch is retained.

**What I learned**

Interning (instruction, callee-label) pairs leaves 2^(k+1) distinct labels in wk and
2^(k+2)-2 interner records through wk. An unevaluated whole-summary application can share
the wrapper graph in O(k), but query, supply and serialization bounds do not follow.

Shared actual templates remove eager N×M copies. They do not prevent N×M distinct descendant
contexts or pair comparisons. Memoisation is not a proof that there are few distinct keys.
Tuple roots have no cell, so checking only epsilon cannot prove descendant separation.
A callback returning a capture must retain the captured object's identity across labels.

Sparse SCC traversal also does not make set union constant-cost: independently built overlapping
sets can require linear inspection while adding zero cells. Carried lambdas can route recursion
through an otherwise non-recursive wrapper, so a finite invocation-context construction is still
owed. These are reasons to report the wall under CLAUDE.md rule 10, not to fold precision away
or describe the design as implementation-ready.
