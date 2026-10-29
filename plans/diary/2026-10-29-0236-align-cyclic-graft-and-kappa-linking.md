## 2026-10-29 02:36 CET — Align cyclic graft and κ linking

**What I did**

Read PR #1131's verification 6485347257, issue #1146 and its PR comment
6485015361. Rebased onto master c709bf771 and resolved the walk-paragraph
conflict in favour of the landed Tarjan/record protocol. Updated the existing
graft contract, plan and regressions: no pending-image reads, no waiting or
retry passes; #1144 is merged and #1143 closed. Kept master's native-recursion
bound for Summary.Table.join/leq.

Specified a knot's κ fold at its first-entry cursor, empty path relative to
that cursor, with direct active-frame lookup and parameter merges at the
current cursor. Child cursors link on unwind; folds reuse incremental summaries
instead of rewalking the root path or all descendants. Added #1146 to the
before-S3b obligations and its counted 4/16/64/256/1,024 chain acceptance,
separating link cost from graft cost. Rewrapped issue-number prose. Mechanical
checks preserve every heading and both complete As built notes verbatim.
Full gates run on dagon; the PR response records the result. This remains a
docs update, not an implementation of #1146.

**What I learned**

The interim deferred-reader solution in the previous entry was superseded by
#1144's final commit: SCC record construction avoids reading pending images
without scheduling waits. Fixing that shape graft does not fix linkArgs: its
route scans and root-relative κ edits can still be quadratic. The snapshot's
own cursor is the right boundary for both the fold and argument κ merge.
