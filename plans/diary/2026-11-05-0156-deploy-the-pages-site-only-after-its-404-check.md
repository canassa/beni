## 2026-11-05 01:56 CET — Deploy the Pages site only after its 404 check

**What I did**

Cesar answered the placement question of #244 on 2026-11-05: the site check stays a step in the `browser` job of `ci.yml`, with one output of `browser-plan` and one `if:` per step, the job gets a fixed name, and on master the Pages deploy needs this job. The outputs and the `if:` per step were in #1920 already. The job is now `Chrome`. A job cannot need a job of another workflow, so `pages.yml` is now `on: workflow_call` and builds the site only. `ci.yml` calls it as the job `pages`, which `check` needs too. On a push to master, `pages-head` compares the commit with master's head when `pages` and `browser` passed and the site check step succeeded. Then `deploy-pages` deploys. A throwaway draft pull request (#1939, on the branch of #1920) showed the three cases, one push each: a doc-only change skips `Chrome`, an examples-only change runs only the 404 check, and a browser runtime change selects the corpus too. A dispatch run with the full corpus showed both steps in one job.

**What I learned**

- A skipped job shows its `name:` as written, `${{ }}` included. A job name with an expression is only readable on a job that runs.
- On master, each push has a run of its own. The Chrome jobs of two quick pushes can end in either order, and a concurrency group serializes the deploys but does not order them. The comparison with master's head prevents an older site after a newer one. The comparison is in a job with no environment, because a job with `environment:` writes a deployment even when its deploy step is skipped.
- The base of a throwaway pull request can be the branch under test. Then the plan's `git diff HEAD^1 HEAD` holds only the case's change. A pull request whose base is not master runs the full Lean audit, so cancel its run when the case has run.
- No pull request to master can run the Chrome corpus today: `tests/corpus/browser/managed` is only on `workers-hostfree`.
