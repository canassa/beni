## 2026-10-14 17:41 CEST — complete the Conduit ownership review

**What I did**

Rebased the ownership branch onto current master, preserving both append-only
diaries. Answered the second review: crossing callback results are identified
with tracked, so functions, bare type variables and open records retain need.
An invalid forwarded callback index fails closed; the deliberate unseen
protocol merge and recursive capture expansion are documented. Added a
generic identity-over-borrowed-list refusal, bringing the rejected twins to
fifteen. All existing ownership-corpus demand verdicts remain unchanged.
The final native zorg gates report 1,297 passing tests, 15 skips and only the
two authorized case-folding failures; both driver CPU-budget tests pass.
The browser/direct pending audit matches all 15 signatures. No LLVM was used.
Prepared the final push and response to every review finding; the PR remains
unmerged.

**What I learned**

The older holdsList predicate deliberately excludes function values; it cannot
justify dropping callback-result obligations on captured functions. The final
gates also exposed a separate report smoke test using 1,012–1,081 ms against
the macOS fallback's 999 ms budget. Its existing empty parse fixture preserves
one compiler call and every report assertion, and passes the complete gate.
No budget was raised and no baseline test was edited. Conduit's three scripts
still stop on document-helper lowering, while the full original application
ownership check accepts all 26 demands. HttpFailures retains the distinct
work-slot-inside-traversal limit; application sources remain unchanged.
