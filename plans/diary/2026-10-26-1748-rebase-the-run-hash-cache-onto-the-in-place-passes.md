## 2026-10-26 17:48 CET — Rebase the run-hash cache onto the in-place passes

**What I did**

- Rebased #904 onto `origin/master` fe7af05f1 (265 commits). The code commit
  conflicted in `tests/blackbox/corpus_test.zig`: master restructured the
  in-place passes on the old record API (`Config.in_place: InPlace`, the
  `out-lists` pass through `runOnceCrash`, `builtPage` and `differentialPages`
  for `browser-inline` pages). I ported the structure onto the cache API: every
  pass looks its digest up before Node and records it after the verdict; the
  records sweep (`in_place == .records`, the three records passes) and the lists
  sweep (`.lists`, `out-lists`) look nothing up and record nothing; a
  differential page runs with no digest. 1 127 re-recorded record files took the
  deletion.
- Ran `test-blackbox-run-hash`, `test-blackbox-browser` and the gates on that
  head through `heavy-run`: all exit 0; the gates took 161 s and 2 443 of 2 882
  program runs were misses on the cache (master's 265 commits changed their
  outputs).
- Master moved 17 more commits (9ddae95b4) while the job waited in the queue:
  one record modified, four new. Rebased again; the deletion commit now holds
  1 301 record files and the index. The gates run again on the new head.

**What I learned**

- A record file master ADDS after the branch point does not conflict: the pick
  applies, and the file stays in the tree. After `git rm -q --ignore-unmatch --
  '*.run-hash' '*-run-hash'` on the deletion pick, check the count of staged
  deletions against the previous count: it must grow by the new files. The gate
  check from round 2 (a record file in the corpus fails the walk by name) would
  have caught a missed one, but only in the gates.
- When every conflict of a pick is a deletion, `git rebase --continue` refuses
  ("you have staged changes"); `git commit -q -S -C <pick>` and then the
  continue keeps the pick's message and signature.
- Master's in-place sweeps are the one place a pass runs Node with no digest on
  purpose. Port them by the sweep condition, not by the pass name: a sweep run
  must neither skip a program nor cache it, because its verdict is the sweep's,
  not the ordinary build's.
