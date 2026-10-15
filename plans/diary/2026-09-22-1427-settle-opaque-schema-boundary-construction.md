## 2026-09-22 14:27 CEST — Settle opaque schema boundary construction

**What I did**

Recorded the owner's Q6 representation decision in schema.md §5 and A.4:
read/write construction fails when Type contains an opaque target without a
structural description; typeOnly keeps its optional checks, identity if none.
Only Q6's metadata/tooling scope remains open. Corrected CLAUDE's stale claim
that M4 had not started: slices 0–3 have landed. Updated the current scheduling
in the contract, CLAUDE and queue so row 67 may run in parallel with S1, with
both required before S2. Historical decision entries remain intact.

**What I learned**

The opaque boundary decision can be settled independently of JSON Schema and
generators. The numeric-alias fix is a checker task, not a dependency of S1's
frontend work. Relative links, section stability, stale-wording checks and
`git diff --check` passed. This was documentation only; no code, measurements
or compiler gate runs.
