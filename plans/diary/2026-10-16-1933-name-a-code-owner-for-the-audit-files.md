## 2026-10-16 19:33 CEST — Name a code owner for the audit files

**What I did**

I added `.github/CODEOWNERS`, which names `@canassa` for the files that decide what CI checks.
The files are `Axioms.lean`, `Audit.lean`, `lakefile.toml`, `lean-toolchain` and `scripts/` in `proofs/ownership/`, then `flake.nix`, `flake.lock` and `.github/`.
Cesar decided it on 2026-10-16 (dashboard question `lean-ci-q1`).

**What I learned**

The review of the job `lean` (#254) found that the job runs the audit files of the pull request itself.
A pull request that weakens them passes its own weaker audit, and no CI step can catch that.
The file has no effect until an admin turns on "Require review from Code Owners" in the ruleset on master.
