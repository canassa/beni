## 2026-09-28 16:32 CEST — Fast tests, plain commit messages, the history rewritten

**What I did**

- Tests: the black-box suites run a ReleaseSafe beni; stress sweeps were deleted or cut to just
  past the limit they reach; the acceptance matrix and the under-load spinner test were deleted
  in favour of a few hand-picked tests; tests run as sharded processes; `zig build gates` runs
  the three gates in one graph; `-Dquick` (self-hosted backend), `-Dcorpus`,
  `-Dtest-filter` and per-file steps give the testing tiers now written in CLAUDE.md; every
  worktree shares the main checkout's Zig cache; worker pools are sized by the source there is.
  Warm gates went from about 5 minutes to 13–25 s; `zig build test-time-report` measures it.
- Scrubbed internal plan codes from code comments, test names and design documents, and
  rewrote every commit message in the repository (404 commits) to plain, whole-line subjects
  with no trailers, then force-pushed master. Hashes quoted in earlier entries and in plans/
  refer to the history before this rewrite.
- Investigated the cross-language benchmark's Roc figure: fair as measured, but `roc check`
  spends only a third of its time type checking; the README now says so.

**What I learned**

- The gates were bound by total CPU, 40% of it kernel time from thread pools sized to the
  machine instead of the work; one sweep test had asserted nothing for its whole life.
- The owner wants tests that reach specific branches, not matrices; commit messages, comments
  and docs readable without the plans; and agents that climb test tiers instead of re-running
  full suites.
