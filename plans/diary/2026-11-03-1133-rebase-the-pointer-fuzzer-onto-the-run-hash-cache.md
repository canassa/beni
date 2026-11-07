## 2026-11-03 11:33 CET — rebase the pointer fuzzer onto the run-hash cache

**What I did**

- Rebased #1522 (#527) onto master `9a50f9b1f`, after #904 moved the
  run-hash records out of git. I dropped the commit that only recorded
  hashes. No other commit had a record file, so the rebase had no
  conflict, and the branch's own diff did not change.
- Master's gates fail: #1750 added
  `tests/corpus/run/SanitiserNestedPassOn.run-hash` before #904 merged,
  and the corpus walk refuses a record file (`RecordFileInCorpus`). I
  deleted that one file in a commit of its own.
- Ran `zig build gates -j2` with a `BENI_RUN_HASH_DIR` of its own that
  started empty, because the branch changes `tests/browser/`, which the
  key of CI's run-hash cache hashes. Cold, the gates took 329 s and
  wrote 3 164 digests. The job's memory peak was 3 GB.

**What I learned**

- A merge that lands between another PR's last rebase and its merge
  can bring back a file that the other PR deletes everywhere. Read
  master's CI before a rebase: a red master makes every branch red.
