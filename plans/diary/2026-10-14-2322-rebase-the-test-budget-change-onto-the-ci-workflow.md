## 2026-10-14 23:22 CEST — rebase the test budget change onto the CI workflow

**What I did**

Rebased PR #104 onto master e2aed9171, which holds PR #107's
`.github/workflows/ci.yml`. Only `plans/diary.md` conflicted: master's
entries first, mine after. The CI job runs `zig build test test-blackbox
fmt-check beni-fmt-check -Dtest-budget=0` on `ubuntu-latest`, which this PR
allows on a host that cannot count. No run hash changed.

**What I learned**

The pin does not depend on the counter. `ubuntu-latest` (an EPYC 7763) has
the reference's features and no PMU, so the CI job builds for
`x86_64_v3+sha` and holds no test to the budget. Only another OS, another
architecture or a CPU without the features gets the host's CPU.
