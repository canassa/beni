## 2026-11-02 15:56 CET — Run Chrome fixtures in CI

**What I did**

Added a separate Chrome job to ci.yml, with a PR path filter for the
browser platform, JavaScript backend, and Task's core dependencies.
Pushes to master and the nightly schedule run the whole browser corpus;
manual dispatch selects full or managed. A missing managed corpus skips
with a notice before installing Nix or Chromium. The aggregate check
accepts only this job being skipped. Reused the Nix installer, profile
roots and Zig caches, with a short Chrome temporary directory.

**What I learned**

The managed corpus has not landed on master yet, so applying an unmatched
-Dcorpus there would fail. The path decision must belong to a job rather
than the workflow: unrelated pull requests still need the existing
required check. The Chrome test command's build summary reports the
corpus run duration separately from its compilation dependencies.
