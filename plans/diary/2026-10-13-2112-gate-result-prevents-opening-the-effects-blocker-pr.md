## 2026-10-13 21:12 CEST — gate result prevents opening the effects blocker PR

**What I did**

Ran the full unfiltered `direnv exec . /opt/homebrew/bin/zorg build gates`.
It ended with four failures: two existing stale-output path tests assume a
case-sensitive filesystem (PathAlreadyExists creating Zz.mjs/ZZ.mjs hard links,
and a directory spelling mismatch), and two existing cache-pruning tests exceeded
the macOS 999 ms CPU fallback budget (1 092 and 1 117 ms). Compiler, platform
and black-box harness sources are identical to origin/master. The focused pending
fixture reported its pinned list_may_be_shared; the browser-tea oracle recorded
three successful Node 24 runs. Prepared the blocker PR body, but did not commit,
push or open a PR because the gate is not green. This corrects the preceding
entry's prospective wording about the PR: no PR exists and no review was requested.
The staged changes remain on browser-direct-s5; unrelated untracked work was left
alone. Gate log: /tmp/beni-s5-gates.log.

**What I learned**

This host cannot supply the required green gate with the unchanged test harness:
its case-insensitive APFS and CPU-budget fallback expose two separate test limits.
They need handling before the requested PR workflow can run. The ownership blocker
still prevents shipping the specified effects driver; neither blocker was bypassed.
