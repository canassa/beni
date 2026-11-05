## 2026-11-05 15:52 CET — the node platform runs a program

**What I did** (worker `node-process-spawn`, issue #2015)

- Wrote the contract first: `boundary.md` §9.14 (the API, the environment, the lifetime, the kill
  policy, the error table, Effect v4 parity, the fixtures), and amendments in
  `transparent-effects-proposal.md` §16.5 and §17.1 item 2.
- Added `platforms/node/ChildProcess.beni`, beni over `Js`: `command` gives a `Command` record with
  defaults, `run : Command → Result RunError Output` suspends until the child has exited and its
  pipes have ended. No shell. A non-zero exit and a signal are `Ok` values (`Status`).
- Added eight `run/` fixtures: `ChildProcessRun`, `ChildProcessErrors`, `ChildProcessFaults`,
  `ChildProcessUnknownCode`, `ChildProcessUnknownEvent`, `ChildProcessCancelled`,
  `ChildProcessKillAfter`, `ChildProcessShutdown`. Every child is `/bin/sh` or a name on `PATH`.
- Added `skills/beni/references/child-process.md` and a pointer in `platforms.md`.
- Opened #2023 (standard input) and #2024 (streaming output, a handle) for the debt.
- Asked the owner three questions (`node-process-spawn-q1` to `q3`): the API shape, the
  environment, the kill policy. Jayson took the recommended option of each (15:57 to 15:58 UTC),
  and §9.14 (i) records them.

**What I learned**

- Node's `spawn` reports a failure by two routes. `EACCES`, `EAGAIN`, `EMFILE`, `ENFILE` and
  `ENOENT` come as the child's `error` event; every other code is thrown from the call. A wrapper
  must handle both, by code. After an `error` event, `close` still comes, with a negative code and
  no `exit`. After `EMFILE` and `ENFILE` the child has no pipes (`stdout` is null).
- The `PATH` lookup uses the child's environment, not the parent's. Node passes an environment
  name `A=B` as the variable `A` with the value `B=…`: a silent wrong answer, so beni refuses it.
- `kill` on a child whose start failed, in the same tick, returns `false` and signals nothing
  (measured under `setsid`).
- A child process is the first host resource that outlives its canceller: the release of the
  bracket waits for the `exit` event. A cleanup may park, so `Task.cancel` returns after the
  child is gone. The `SIGKILL` timer is a host timer, so it fires even when a teardown cuts the
  cleanup short.
- The `references/effect` submodule is not checked out in worktrees. The GitHub contents API at the
  pinned commit reads single files without a clone.
- A test platform's sibling `.js` must `import process from "node:process"` to use `process`
  (`boundary.md` §4 check 3).
- A topic file of `skills/beni/references/` stays under 300 lines (`skill_test.zig`). `platforms.md`
  was at 299 on master, so a new platform module gets its own topic file and a pointer.
- Since 2026-11-05 a platform listener (an emitter's `on` or `once`) must be listed in
  `tests/corpus/ownership/p-sync.txt` and pinned in `word-bodies.txt` (`check_test.zig`); the
  pin hash folds the body's whitespace and is SHA-256, so it can be computed by hand.
