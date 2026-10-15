## 2026-10-14 19:32 CEST — run the gate tests in CI on a hosted runner

**What I did**

Added `.github/workflows/ci.yml`. On every pull request and every push to
master, it runs `zig build test test-blackbox fmt-check beni-fmt-check
-Dtest-budget=0` on `ubuntu-latest`, through `nix develop`. It has read-only
permissions and no secret, and it caches the Nix store and the Zig caches.
CI does not enforce the test budget, by the owner's decision: the budget
stays a local gate on x86-64 Linux. First the owner chose a self-hosted
runner, and I built and measured that job. Then the owner replaced the
decision; the PR describes how to add the self-hosted `gates` job later.
On a hosted runner, a cold gate run took 5 min 39 s, with a test step of
4 min 51 s; with the Zig cache, the test step took 2 min 30 s to 3 min 9 s.
On this host, the cold gates took 145 s, and 54 s after a one-line edit.

**What I learned**

A hosted x86-64 runner cannot hold the budget. It has no hardware
instruction counter, and `perf_event_open` gives ENOENT also as root. Its
CPU-time fallback of 999 ms failed 55, 56 and 3 tests and cases of one
master commit on three runs. The run with 3 failures passed both #101
cases, which the instruction count fails. The Nix store cache gives no
time gain on a hosted runner, but it stops each run from downloading Zig
from ziglang.org. Its action saves only after a green job, unless the
`save` sub-action runs as its own step. The Zig cache of one cold build is
1.6 GiB, or 273 MiB compressed.
