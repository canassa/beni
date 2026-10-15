## 2026-09-19 22:39 CEST — the owner answers services; the five effects questions are closed

**What I did**

- Recorded **A7, services**, as the owner decided it: records of functions and
  `where` clauses now; three fixed per-fiber slots (clock, scheduler, log
  context) with the runtime, not a general service locator; the "everything
  provided at the entry point" proof conceded in writing.
- Folded all five answers (A1, A5, A6, A7, A8, and A2/A3/A10/A11 with them)
  into `plans/effects-spike.md` §0.1 and its pending table, a block at the top
  of `plans/effects-decisions.md`, the queue and `plans/resume.md`. No agent
  was started; implementation stays parked.

**What I learned**

- The fold was cheap because the plan had been written with a PENDING table
  that named, per decision, the default assumed and the slices that change.
  A1 was answered differently from the default, and the table said exactly
  what that touches: S9 shrinks to `Exit` plus the crash reporter.
