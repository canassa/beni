## 2026-10-30 00:07 CET — Ownership v2 S3b slice 1: review fixes (#1261)

**What I did**

- Rule (c) owes `excl` only with evidence that the two paths are distinct positions: both are
  read through a leaf (`readThroughLeaf`). `viaFirst`, a built record holding one head twice, is
  refused again (`CallOtherPathsCopies`). The precision this costs is #1272.
- The cold run keeps the warm run's verdicts. A callee that the warm run stopped at a limit, or
  left unbuilt, is not walked cold. Callees are found through dot calls too.
- Each cold run's tables are a pool of exactly its callees' walks, reused along a chain. A
  100-declaration chain now dumps in 0.68 s and a 300-declaration one in 1.83 s; the reviewer
  measured 13 s and 117 s.

**What I learned**

- "Two paths fold onto one summary cell" holds for projections of one symbolic value, but not
  for a built value that holds the same cell twice. The second is aliasing, not distinct
  positions.
