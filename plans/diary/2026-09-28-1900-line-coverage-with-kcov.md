## 2026-09-28 19:00 CEST — line coverage with kcov

**What I did**
- Added `zig build coverage` (not a gate), from the `nix develop .#coverage`
  shell that adds kcov. A child `zig build coverage-run` builds an LLVM
  ReleaseSafe beni that keeps its debug info, points every black-box suite's
  `BENI_EXE` at a small Zig wrapper (`tests/coverage_wrapper.zig`) that
  replaces itself with `kcov --collect-only … <beni> args…`, and runs the
  unit tests (LLVM, same mode) under kcov directly. `tests/coverage.zig`
  merges the per-process directories in parallel batches with
  `kcov --merge`, even when a test failed, and writes
  `zig-out/coverage/` plus `summary.md` (total, per directory, per file),
  leaving the tests' own lines (`*_test.zig`, `test` blocks) out of the
  figures. `-Dcorpus` and `-Dtest-filter` narrow it.
- The harness's time limits scale with `BENI_TIMEOUT_SCALE` (pinned empty
  in the gates, 20 under coverage): two abuse tests with 3 s limits failed
  under kcov before it.
- First full run: 94.1% of 23 718 counted lines; 11 min wall, 9 100 CPU-s,
  3 214 processes, quiet machine.

**What I learned**
- kcov (elfutils) reads no line table from the self-hosted backend's output
  for beni, though it reads a two-file hello; an LLVM Debug build marks an
  untaken `if` body as run (the jump that skips it carries the body's
  line); LLVM ReleaseSafe was accurate on the spot checks, counts fewer
  lines (folded code is in neither count) and runs about fifteen times
  faster under kcov than LLVM Debug.
- The black-box harness gives the compiler an empty environment, so the
  wrapper carries every path baked in at build time.
