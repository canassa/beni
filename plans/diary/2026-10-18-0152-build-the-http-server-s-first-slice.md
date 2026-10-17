## 2026-10-18 01:52 CEST — Build the HTTP server's first slice

**What I did**

- Built `Http.Server` on the `node` platform to `boundary.md` §9.10: `platforms/node/Http/Server.beni`
  (the fibers, beni over `Task`) and `Server.js` (what needs `node:http`).
- Built the harness: `tests/serve/driver.mjs` starts a build with `preload.mjs` imported first,
  learns the port from file descriptor 3, sends a `.requests` script and prints a transcript the
  port never reaches. `tests/blackbox/serve.zig` and the `.requests` branch of `corpus_test.zig`
  run such a `run/` fixture and record its run hash with the driver, the preload and the script.
- Nine fixtures, one per row of §9.10 (e), two of them crashes the preload injects on a
  `{"fault": …}` step.
- Rebased the spec branch onto master and stacked the slice on it, per the coordinator.

**What I learned**

- `cache_test` assumed that exactly one `node` module is not imported by its program. The count
  now follows the platform's files.
- `zsh` does not split a command kept in a variable, and `=word` is a command lookup: quote both.
- A `git rebase` of a branch based on a newer master onto a branch based on an older one replays
  master's commits; rebase the lower branch onto master first, then `--onto` the top commit.
- Node writes a body on 205 but drops it on 204 and 304; `writeHead` with a flat array writes a
  name given twice twice, where `setHeader` keeps one value.
