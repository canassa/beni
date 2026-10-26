## 2026-10-26 14:31 CET — Publish the ball machine playground refactor

**What I did**

The owner explicitly requested a PR and merge after the prior local verification
and reported macOS gate blockers. Committed the project Types dump separately
from the multi-file ball sample and visible controls, then rebased onto the latest
master. The only conflict was the old single-file BallMachine run hash, updated
upstream and removed by the project conversion; retained the project layout and
scheduled its hashes to be regenerated against the new core.

The required Linux CI gate and automated review will validate the published head
before merge. The local platform failures stay tracked as #90 and #1085; this
work changes no unrelated tests or ownership goldens to bypass them. User scratch
files and untracked benchmark directories remain outside the commits. All local
compiler commands use Zorg.

**What I learned**

Master advanced with ownership result selectors and new core words during the
local work, including a new BallMachine run hash. That requires fresh project
hashes even though the control program and drawing did not conflict. The latest
master has green Linux CI; the master ruleset requires the aggregate check job.
