## 2026-11-01 05:24 CET — Rebase the run-hash cache onto the prerender pages

**What I did**

- Rebased #904 onto master 7d15d67c7 from the remote head bccd8022a (Jayson's
  rebase of 2026-10-30), not from my older local branch: 97 modify/delete
  conflicts and 14 new record files, all deleted, 1 373 files in the deletion
  commit; no other conflict. Checked that the branch's own diff is the same
  before and after the rebase outside the re-recorded index.
- Found that master's prerender pages, ported to the cache on 2026-10-30,
  looked each digest up and never recorded it: a passing prerendered page ran
  on every gate run. Fixed by recording the compared transcript, as `runPage`
  does.
- Gates `-j2` through the queue: cold 568 s wall / 1 876 s CPU (3 111 of
  3 159 ran after master's 275 commits), warm 327 s / 1 205 s CPU, peak memory
  of the scope 5 421 MiB. The `-j4` gates die at heavy-run's 10 GB cap now.

**What I learned**

- A port to the cache API is two halves: the lookup before Node and the
  record after the verdict. A port that does the first half only is green,
  counts every run as stale, and never gets cheaper. Grep for
  `run_hash.record` beside every `checkedPlan` or `verified` call after a
  rebase.
- Read a scope's peak memory from the `0::` line of `/proc/self/cgroup`;
  the `net_cls` line comes first and names the root.
- When someone else pushed to the branch, start from their head and compare
  the branch's own diff before and after: it must be identical outside the
  files master re-recorded.
