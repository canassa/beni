## 2026-10-29 19:01 CET — a crashing test fails at once

**What I did**

- The test runner now uses its own handler for SIGSEGV, SIGILL, SIGBUS and SIGFPE, in place of
  std's. It takes no lock: it writes `FAIL: test crashed (<signal>): <test>` with `write(2)`, kills
  the test's child process groups, and exits 1. The hang guard reports a timeout with `write(2)`
  too (#1197).
- Added runner probes `--crash-probe=segv|overflow|locked` and `--hang-guard-probe=locked`, with
  gates tests. Red-first: with std's handler, `locked` hung until it was killed and the other two
  crashed without naming the test; with the old `print`, the locked hang guard hung too.

**What I learned**

- std's segfault handler prints its stack trace under stderr's lock. A test thread that holds that
  lock leaves the crash handler, and the hang guard waiting to print its timeout, asleep forever.
  That is how a gates run sat for more than ten minutes with all four threads in `futex_wait`.
