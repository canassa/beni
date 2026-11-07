## 2026-10-29 23:34 CET — Ownership v2: a call's DAG result linked once per node (#1252)

**What I did**

- `Calls.linkArgs` now finishes each position of a knot-free result once per node and starting
  snapshot. Before, it walked once per path. `w1 x = ( x, x )` … `w5` went from 603 → 6 467 records
  (w6 past the limit) to 59 / 109 / 191 / 355 / 683.
- With w6 checked, `main`'s `w6 1 == w6 2` hung without spending any charged work.
  `Groups.handWritten` walked the derived `eq`'s evidence as a tree: 2^32 terms. It now visits
  each term once, so `EvidenceDagBuildDepth32` stays in `run/` and checks.
- Opened PR #1261 for S3b slice 1.

**What I learned**

- A hang that ignores a lowered allowance is uncharged work. Here a stack sample found it:
  `tgkill` sent `SIGSEGV` to the busiest thread, and the crash handler printed that thread's stack.
- #1231 was closed, not merged, when its base branch was deleted, so its fix is not on master.
  Check a PR's merge, not just its closed state.
