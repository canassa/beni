## 2026-10-14 02:11 CEST — answer the fold ownership review

**What I did**

Opened PR #88 and requested @claude review. The review found no definite
soundness bug and identified six points to check. Replaced numeric future-cell
selection with recording callback allocations during shape instantiation;
supplies and projected arrivals do not record allocations. Kept initial
reachability and escape exclusions. Added the optional requirement-list
invariant assertion and removed the unused accumulator parameter.

Added two pure summary-instantiation tests through entryResMode. An init cell
numbered 100001 is supplied to a fold in namespace 200000: a failed condition
stays failed and an owned one stays owned. The focused tests pass. Full native
zorg build gates with Node 24 has 1 295 passing, 15 skipped and exactly the four
known macOS failures. All existing ownership goldens still pass unchanged.

Recorded the Lean sync and a dedicated fold-round-cap corpus fixture in queue
row 85; the cap-specific fixture remains follow-up, not claimed coverage. A
single native ReleaseSafe ownership dump of bench/corpus recorded about 119 ms
summed over ownership events; this is no before/after performance claim. Prepared
answers to every review finding and requested inspection of the changes and the
new corpus fixtures. The PR remains unmerged; LLVM stays excluded by the owner.

**What I learned**

An allocation's role must come from its provenance, not a numeric namespace.
Entry namespaces are much larger than the callback stride. Even there, a supplied
cell must retain its established condition. The namespace tests exercise the
actual entry result-instantiation path as a pure algorithm boundary; the corpus
continues to supply the runtime and rejection regressions.
