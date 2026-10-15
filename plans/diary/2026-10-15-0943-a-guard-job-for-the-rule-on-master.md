## 2026-10-15 09:43 CEST — a guard job for the rule on master

**What I did**

Added the job `check` to `.github/workflows/ci.yml`. It needs `tests`,
runs with `if: always()` and `contents: read`, and fails unless every
needed job succeeded. The rule on master can require this one status,
so a new CI job joins the rule with one line in `needs:`. The other
workflows stay unbound. Read the settings with `gh api`: master has no
branch protection and no ruleset, and auto-merge is off. Only the owner
can change them, so the PR lists them.

**What I learned**

GitHub counts a skipped job as a passed required check. Thus a guard
without `if: always()` lets a pull request merge after a failed job, and
`if: ${{ !cancelled() }}` lets it merge after a cancelled run. On a
cancel, GitHub keeps every job whose `if` is true, so the guard of a
cancelled run still runs and fails. `needs:` sees only the jobs of one
workflow; another workflow joins through `on: workflow_call` and a job
in `ci.yml` that calls it with `uses:`.

PR #119 showed the cancel: the older run's `tests` was cancelled, and
its `check` ran and failed in 2 s. The automatic review stopped after
two or three turns and posted nothing, so I asked `@claude` for a pass.
It found no defect. On its advice, the comment now says two more
things. A called workflow sees its caller's event, so `claude.yml`
cannot join. A `paths:` filter on the CI trigger leaves a skipped pull
request waiting for `check` forever.

The adversarial review found the guard correct and the PR in conflict
with master in this file. I rebased on `ac65b18ce`, put my entries after
the newest one, and cut the guard comment from 28 to 16 lines. The new
comment also says that no other job may be named `check`, and that a
timed-out `tests` reads `cancelled`. `direnv exec` refused the
`.envrc` of this worktree, so I ran `zig build gates` through
`nix develop --command`. The *Troubleshooting required status checks*
table of the GitHub docs names both cases: a job skipped after a failed
dependency does not block a merge, and a workflow skipped by a filter
leaves its check pending.
