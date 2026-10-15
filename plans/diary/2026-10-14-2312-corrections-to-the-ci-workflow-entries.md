## 2026-10-14 23:12 CEST — corrections to the CI workflow entries

**What I did**

Corrected my two entries above, after a second review of PR #107.
- The entry headed 19:32 says that the PR describes how to add a
  self-hosted `gates` job later. The PR no longer describes a self-hosted
  job, because the owner removed that part.
- That entry and the workflow comment say that `perf_event_open` gives
  ENOENT, also as root. The full result on a hosted runner: EACCES at
  `perf_event_paranoid` = 4, ENOENT at -1, also as root.
- The stamp 19:32 CEST of that entry is wrong for its text. 19:32 is when
  I wrote its first version, about the self-hosted job (commit at 19:33
  CEST). The decision changed at 19:34–19:36 CEST (17:34–17:36 UTC). I
  then rewrote the entry, and its text dates from the commit at 19:40 CEST.

**What I learned**

A diary entry that I rewrite after a decision changes needs the time of
the rewrite. Otherwise it describes events that come after its own heading.
