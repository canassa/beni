## 2026-10-20 23:18 CEST — the todo server says where it listens

**What I did**

- Made `examples/todo/server` log `listening on http://<host>:<port>` from `Server.address` as soon
  as `Server.listen` answers, an IPv6 host in brackets. Under `Io.run` that is one `logfmt` line
  on standard error. This was the example #358 came from.
- Taught the serve driver's standard-error filter to write a log line's time as
  `timestamp=<time>`, beside the `<address>:<port>` it already wrote, so `run/TodoServer` and
  `todo_example_test.zig` keep one transcript.
- Started the slice fresh from `origin/master` and took over the work I had parked on an older
  base, with the run hashes recorded again.
- Noted in AGENTS.md that core's `Log` has landed.

**What I learned**

- A server fixture's run hash covers the driver's bytes, so a change to the driver gives every
  server fixture a new hash, and changes no transcript but those that print the new text.
- A slice that waits behind others is easiest to carry as one parked commit and a fresh branch
  from `master` once the others merge: `git cherry-pick -n`, then reset the hash files and record
  them again.
