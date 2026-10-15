## 2026-09-25 — harness: the test steps run in two minutes, not thirteen

**What I did**

- The owner asked why slices took two hours; I timed the suites. The review loop is half of it,
  but every run of the gates plus `test-pending` cost about 13 minutes, run 3–4 times per slice.
  A harness slice, approved by the owner:
  - `test-pending` keeps the pending fixtures and the Debug-only scenarios (CK-82's red is a Debug
    panic); the timing scenarios moved to `test-pending-perf`, which runs a ReleaseFast compiler
    (`zig-out/perf/bin/beni`, `BENI_EXE`) on sizes recalibrated for CPU time. Each is still red,
    and CK-40/CK-41 read green with their known fixes applied in a scratch worktree.
    `plans/checker-rewrite.md` §1 lists the slices that must run the perf step.
  - `corpus_test` runs as five parallel parts (parse, check, build, run dev, run release), each
    kind assigned by an exhaustive switch; `abuse_test`'s wide-input tests split out. 743
    fixtures before and after; one broken golden per kind (17) still fails the gate with every
    harness variable exported to a hostile value.
- My run on an idle machine: `test` 17 s, `test-blackbox` 98 s (was 307 s loaded, 156 s idle),
  `fmt-check` 0.2 s, `test-pending` 33 s (was 10–12 min), `test-pending-perf` 23 s. 76 RED, 0
  GREEN.
- Open, for R3: where a timing scenario goes once its bug is fixed (the old "move into
  `abuse_test`" would run ReleaseFast-sized scenarios on Debug).

**What I learned**

- The expensive tests were the ones proving the old code is slow: cubic schema settling at 800
  schemas in a Debug build, six times over. Measuring the thing you are fixing on the build the
  budget is about (ReleaseFast) cut them from 11 minutes to 23 seconds.
