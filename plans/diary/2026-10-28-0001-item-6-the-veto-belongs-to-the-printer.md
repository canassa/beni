## 2026-10-28 00:01 CET — item 6: the hand-written veto belongs to the printer

**What I did.** Corrected the review fix of #1127. Excluding every non-local, non-top-level callee
threw out another beni module's export with the siblings: under `--release` those are qualified names
the join hoists into one file, and `Opt` runs per module before it, so `Hosted.key`'s comparer
forwarded to `String.compare` and the closure #1111 exists to remove came back on #1116's restack.
Now `Opt` accepts a qualified beni export again, `Emit.markHandWritten` records the names the build
imports from a hand-written file (a specifier whose imported name is not its local one: a sibling's
export, the platform's runtime) on every release path, and `Print.resolve` leaves an arrow whose
recorded callee is one as the arrow it is. The spec says it in those words. Gates at `-j4` green as their own job (2 min 29 s, 5.7 GB peak).

**What I learned.**
- Decide a rule where its facts are known. "Is this name a sibling's?" is a fact of the join, not of
  one module's IR, so the veto that needs it lives in the printer, which runs at the join, and `Opt`
  records the reduction as if every callee were emitted code.
- A rule change on a base branch is a change to every branch above it: the restacked #1116 golden was
  the test that found the over-exclusion, before any review did. Re-bless the stack's goldens and
  read every one as a finding, not as churn.
