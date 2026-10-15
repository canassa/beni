## 2026-10-15 15:03 CEST — Conduit byte review

**What I did**

Answered PR #138's requested Claude review with stronger headline parity caveats,
explicit dependency-surface accounting and per-build source-map coverage. Added
information-preserving matrix encodings, frozen protocol assertions, an independent
selection-helper attribution check, archive-only probe replay and clean reference
output builds. Verified all 26 responses still match after a clean rebuild, and
probe replay succeeds while the Solid reference dependencies are temporarily absent.
The automatic review found no issues and the initial CI and Pages builds passed.

**What I learned**

Sparse key-index lists preserve all 331 × 97 mask bits but save only 106 B in the
whole bundle; inverted source lists add 258 B. This withdraws the earlier 1–3 kB
hypothesis as a saving forecast. The report now exposes a 2,600 B gross deletion
budget before replacement and a conditional 0–2 kB successful-design planning
envelope, explicitly allowing failure or growth. Ninety bytes from prologue
deletion is not a mathematical bound on a different encoding. Source-map coverage
also shows why stock vanilla's runtime/app split is especially approximate.
