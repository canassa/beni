## 2026-10-22 23:37 CEST — A defect in a kept command body

**What I did**

- Rebased #769 three times onto a moving `master` (hash files and the two
  `emit/release/tea/HttpSend*` goldens only, master's side, goldens
  re-blessed). Auto-merge merged it at 21:24 UTC, and it closed #597.
- Added `browser/tea/LogKeptBodyDefect` for #775. An `update` arm makes a
  `Cmd.perform` inside `Log.annotate`. The body does not wait, so it runs
  in no fiber. It logs a line and then throws. The line carries the
  annotation, the page stops (the crash screen in development, the page as
  it was in release), and a later click changes nothing.
- Showed that the page fails without #769's change: with `Hosted.job` and
  `Hosted.later` not calling `Task.keepLogContext`, the line has no
  annotation.

**What I learned**

- A corpus bless writes a `.release-expected` only when the file exists. To
  start one, create it empty and bless.
- In this worktree's shell, `zig` is not on `PATH`; a locked job runs it
  with `nix develop --command`.
- When a kept body with no fiber throws, `inLogContext`'s restore stays a
  finaliser of the `outside` record. The teardown runs it one macrotask
  later, in a fiber of its own, so the old slots are put back. The gap is
  elsewhere (#811, found by the review): that teardown fiber has no slots,
  so a `bracket` release that the body left runs with the default context,
  not the body's.
