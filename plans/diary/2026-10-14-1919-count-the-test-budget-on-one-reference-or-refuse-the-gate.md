## 2026-10-14 19:19 CEST — count the test budget on one reference, or refuse the gate

**What I did**

Measured why `browser/direct/HttpJson` (4 768 M) and `HttpJsonBody` (4 939 M)
passed their author's macOS gate and fail on Linux (issue #101). Removed the
CPU-time fallback: `build.zig` now holds tests to the budget only on x86-64
Linux with a usable hardware counter, builds every binary there for one
reference CPU (`x86_64_v3+sha`), and makes `gates` refuse to run elsewhere and
refuse `-Dtest-budget`, `-Dtarget`, `-Dcpu` and `-Doptimize`. Added
`tests/blackbox/gates_test.zig` for two refusals. Opened draft PR #104,
blocked by master's two cases, and asked the owner whether a macOS host may
lose the gate (`budget-determinism-q1`).

**What I learned**

CPU time was wrong both ways: `HttpJson` passed at about 0.95 s of CPU even
here, and the driver's cache-pruning tests (282 M, 6.6%) failed on macOS at
1 092 ms. The count also followed the host CPU, because builds were native: a
baseline-CPU build put 8 cases over, not 2, mostly SHA-256 in software in the
run-hash check; `x86_64_v3+sha` counts what a native Zen 2 counts. On one
machine the count is stable to under 1% (run to run, load, core count).
GitHub's hosted x86-64 runners have no PMU (`ENOENT` even as root), the hosted
macOS runner reports `ri_instructions=0`, and upstream Zig 0.17.0 used 15 GB
building beni for aarch64 on the hosted arm64 runner. Valgrind counts are
exact but 7–15% above the hardware count and 40–70 times slower.
