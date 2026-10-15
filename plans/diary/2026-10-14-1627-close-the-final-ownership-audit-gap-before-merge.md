## 2026-10-14 16:27 CEST — Close the final ownership audit gap before merge

**What I did**

Read the latest PR #65 review after the owner authorized merging. Confirmed in
the pinned Lean parser that term-level unsafe expressions exist, and reproduced
that the previous audit accepted `def termUnsafeProbe : Nat := unsafe 0`.
Rejected the unsafe atom before elaboration and added the failing-before
black-box refusal. Made audit reject unknown arguments, clarified three source
sorries versus four dependent constants and compiled guard evaluation, and
named the keepsep search gap explicitly in the README. The audit executable
build and refusal checks pass. Preparing the committed-head audit and merge;
all ownership search semantics and retained mutant counts are unchanged.

**What I learned**

A command-node restriction cannot enforce the unsafe-expression boundary;
the expression constructor has its own parser and must be checked throughout
the syntax. The root-file exception already uses the full relative path in
addition to the basename, contrary to the review's last nit. The latest review
was an audit inspection, not independent verification of the checker or logs.
||||||| parent of 9b7b7b136 (🧮 distinguish rendered data from event payloads)
