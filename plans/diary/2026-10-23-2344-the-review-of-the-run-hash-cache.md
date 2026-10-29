## 2026-10-23 23:44 CEST — The review of the run-hash cache

**What I did**

- Opened #904 (the run-hash records leave git for a cache of verified digests, #881) after a
  rebase onto master that brought a third in-place pass, `release-stores`, which now uses the
  cache like the others. CI's first run on GitHub proved the `actions/cache` scheme: a miss on
  the new scope, every program ran, the save wrote 190 kB under the pull request's own key.
- Took the independent review's findings. F1 was real: a blessing run rewrote a golden between
  the release pass's two reads of it, so the cache got a digest for a golden no build showed.
  The fix recomputes the digest after the verdict from the bytes the compare used, in `runOnce`,
  `runWorker` and the page loop; the reviewer's page test is red without it and green with it.
  F3 to F7 were docs, a tolerant cache (one warning, then no cache) and the summary line. F2,
  whether the CI key hashes the harness files, is the owner's: `run-hash-cache-q3`.
- Gates on the fix: cold 118 s, red on `run/HttpServerBadClients` (#701, the known flake), which
  wrote nothing; warm 99 s, exactly that one program ran again, passed and wrote its digest.

**What I learned**

- A digest taken from a golden before the run is a promise about a file that another process
  may rewrite before the compare. The only bytes a record may name are the ones the verdict
  compared. The fix is one recompute per passing run, a SHA-256 beside a Node run.
- A red cold run is the cache's own proof: the failed run writes nothing, and the warm run
  after it runs exactly that program and nothing else.
- `createFileAtomic` with `.replace = true` writes a named 16-hex-digit file, not an `O_TMPFILE`
  one; a killed writer leaves it. Say what the code does, not what the API's name suggests.
- `-Dtest-filter` also filters the corpus walker, so every walker-driven test fails under a
  filter (#907). Run those suites whole.
