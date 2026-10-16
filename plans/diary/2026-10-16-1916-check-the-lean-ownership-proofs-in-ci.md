## 2026-10-16 19:16 CEST — Check the Lean ownership proofs in CI

**What I did**

I added the job `lean` to `.github/workflows/ci.yml` (#257), and `check` needs it.
The job runs `lake build`, then `scripts/audit.sh HEAD`, in `nix develop .#ownership`.
The job always runs, because `check` fails on a skipped job.
Its first step reads `git diff HEAD^1 HEAD` on the merge commit of a pull request.
It runs the other steps only when that diff touches the proofs, the flake or the workflow.
On a push to `master`, it always runs them.
The job restores `.lake` from `master` and saves it only on a push to `master`.

I showed each case on CI.
A new `sorry` in `Ownership/LinkedWriteFrame.lean` failed the job: the in-build audit said that `ciProbe` depends on `sorryAx` and is not pinned.
A pull request based on the branch of #257, with one Markdown file, skipped the steps, and `check` passed.
A cold job took 9 to 14 minutes, and a warm job took 7 min 45 s.
I opened #255 and #259.

**What I learned**

Lake decides a rebuild by hashes of the source, the imports, the options and Lean's commit, not by file times.
But the source scan of `Axioms.lean` reads files outside its imports.
So a warm `lake build` replayed the old scan and passed with a new `sorry` in `Triage.lean` (#255).
`scripts/audit.sh` builds a clean export, so the job catches it.
Thus a warm `.lake` makes only `lake build` faster: the audit took 257 to 428 s on every run.
After a revert, the net diff of the pull request is empty, so the job skips its steps.
A warm measurement needs a commit that leaves a change under `proofs/ownership/`.
`lake exe ownership ci` builds the beni compiler with Zorg, so it depends on `src/` and needs another trigger (#259).
Jayson merged #257 before the red run, so I reopened #254 and finished it in #261.
