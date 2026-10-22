## 2026-10-22 15:10 CEST — hand the proof audit's build to the checkout

**What I did**

- The owner asked for a faster CI job `lean (ownership proofs)`, committed to master directly (#738).
- `lake-manifest.json` has no packages and Lean's libraries come from the Nix store, so all of the time is the package's own modules. On PR #580's run (20 min) the audit took 710 s and the checkout's `lake build` 480 s: the same sources built twice, the second time from master's cache, which misses when a pull request changes a base module.
- `scripts/audit.sh` takes an optional second argument. After every check passed, it moves the export's `.lake` there. The job passes the checkout's `.lake`, and drops the restore and save of master's Lake cache. The audit stays cold and first, and never reads a `.lake` it did not build. Commit 9b7a9549f.
- Local check: after the handoff, `lake build` in the checkout took 1 s and replayed every module and `Axioms`; a changed `Main.lean` was built again.
- Master run 39782408151: audit 776 s, `lake build` 1 s, job 13 min 49 s, green. A pull request now pays the audit only, about 8 minutes less than before.

**What I learned**

- On master the audit alone takes 404 to 776 s across runs of the same proofs: runner noise is larger than any change here.
- The audit replays every constant through the kernel twice, sequentially: once in the build of `Axioms` (211 s on run 39773374078) and once in `audit env` after it. Merging or parallelising those replays would cut minutes, but it changes `Axioms.lean` and `Audit.lean`, so I did not touch it; it is a question for the owner and the owner of the proofs.
- `lake build` also compiles every module to native code for the `ownership` executable; that is a default target, so the job keeps it.
