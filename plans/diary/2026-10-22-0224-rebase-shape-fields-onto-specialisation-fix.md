## 2026-10-22 02:24 CEST — Rebase shape fields onto specialisation fix

**What I did**

Rebased #653's fix-shape-field-names branch onto origin/master 776a3930b,
which fixes #658, and pushed the rebased commit 5999496b4 to draft PR #659.
Git initially failed with No space left on device; removing only this
worktree's disposable .zig-cache allowed the rebase. The focused regression
then failed before compilation because Zig could not write its dependencies
cache (NoSpaceLeft). Asked the owner to free Btrfs metadata on dagon and
recorded the infrastructure blocker on the PR. No tests or checks were
weakened. Golden generation, run hashes and full gates still remain.

**What I learned**

The filesystem reports about 170 GiB of free data space, but its metadata
allocation is nearly full and there is no unallocated device space. Ordinary
cache and git-ref writes are failing. The remote push succeeded, while its
local remote-tracking ref update failed; refresh that ref after space is
restored. The existing cached flake shell opens without importing another
worktree snapshot, and has the pinned Zig 0.17 and Node 24.19 environment.
