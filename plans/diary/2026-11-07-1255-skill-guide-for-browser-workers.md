## 2026-11-07 12:55 CET — skill guide for browser workers

**What I did.** Added skills/beni/references/workers.md (program, open, call, send and await,
cancel, close, abort, the errors, the unconfirmed-cleanup rule, defects) and worker-messages.md
(options and defaults, limits, events and WorkerStream, the wire types, the realm rule, Http and
WebSocket in a worker, Trusted Types policies), and named both in SKILL.md (#2204). The code is
based on the passing worker probes of 2026-11-07.

**What I learned.** skill_test runs `beni check` with no flags, and any call of `Worker.open`
is refused there while launches are gated, so the guide shows `open` in a text fragment and
keeps the checked modules to code that takes a Handle. `beni check` does not report
`worker_realm_violation` even with the gate open; only `beni build` does. A topic file must
stay under 300 lines and SKILL.md under 8 000 bytes, so the guide is two files.
