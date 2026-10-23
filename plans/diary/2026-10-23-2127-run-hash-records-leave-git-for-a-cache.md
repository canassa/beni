## 2026-10-23 21:27 CEST — Run-hash records leave git for a cache

**What I did**

- Built #881, Cesar's decision on #875: a run-hash record is a cache entry, not an assertion.
  `tests/blackbox/run_hash.zig` keeps the digest and replaces the record lines, the index and
  the recording mode with two calls: `verified` reads `<BENI_RUN_HASH_DIR>/<digest>`, and
  `record` writes that empty file with `createFileAtomic` (an unnamed file in the directory,
  then a rename). Every kind that runs Node — `run/` with all its passes, `browser/` under
  happy-dom with the page and value fuzz, `workers/`, the scenario programs — looks the digest up
  before the run and writes it after the compare passed. A run that fails writes nothing;
  `run_hash_test.zig` proves it with a good and a bad fixture side by side, and eight threads
  that write one digest at once.
- `build.zig` pins `BENI_RUN_HASH_DIR` on every test process, from the environment or
  `~/.cache/beni-run-hashes`; `flake.nix` exports the same default in the dev shells and keeps a
  set value, also an empty one. CI restores the directory from `actions/cache` with the pull
  request's own scope first and master's second, and saves under its own key. The deletion of
  1 219 record files and `tests/blackbox/run-hashes.txt` is one mechanical commit, separate from
  the code, so a rebase takes master's code and deletes the records again.
- The `.fuzz-run-hash` files also opted a `browser/tea/` page into its value-fuzz case. An empty
  `<page>.value-fuzz` marker holds that role until the owner answers on the dashboard. Chrome
  (`test-browser`) keeps "never skips, never records" until the owner answers a second question.
- Measured the gates cold and warm; the numbers are in the pull request.

**What I learned**

- The verdict stays the goldens' when the digest is computed from the golden's bytes before the
  run and written only after the compare passed: after a pass the output equals the golden, so
  the digest on disk is the run's.
- Zig 0.17's `Io.Dir.createFileAtomic` with `.replace = true` and `.make_path = true` is the
  whole atomic write: no temp-file naming, no cleanup, and two processes that write the same
  digest both succeed.
- A blessing run of a `run/` fixture still verifies and records its release pass, because that
  pass compares against the golden the dev pass just wrote. A test that expects "no digest" after
  a bless is wrong by one.
- A "continue your work" broadcast reached the reviewer agent of this task while it had no task,
  and it did the worker's steps in the worker's worktree: commits, three rebases and the
  measurements. Two sessions on one branch must never both write; the one that is behind stands
  down and reads the other's handoff.
- After a reboot the GPG agent has no passphrase, so `git rebase --continue` fails with
  `gpg: signing failed: Timeout` and leaves the pick staged. The rebase keeps `-S` in
  `.git/rebase-merge/gpg_sign_opt`; remove that file, commit the staged pick with
  `git commit --no-gpg-sign -C <pick>`, continue, and re-sign every commit before a push.
- `nix develop` in a worktree whose `flake.nix` changed fetches the whole git input again, two
  minutes or more under load; the store's `zig` binary runs `zig fmt --check` at once.
