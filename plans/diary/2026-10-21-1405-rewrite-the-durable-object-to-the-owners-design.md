## 2026-10-21 14:05 CEST — rewrite the Durable Object to the owner's design

**What I did**

- Rewrote `boundary.md` §9.12 (e) and (f) to Cesar's design for `cf-workers-q2` and `q5` (his comment on PR #533): handlers are ordinary beni functions with no `sync` marker; one mailbox per object, one event at a time, the state passed from one to the next; a call-chain id turns a cycle into `Err Cycle`; spawn then `send` for slow work; one fiber runtime per object through `Task.withScheduler`, with its own scope and a host timer while a fiber is live; a defect closes the scope, then aborts; the survival table; The Elm Architecture as an optional layer; the ownership row owned, like `update`.
- Made `Answer` opaque with `respond`, `forward` and `serve`, whose signatures carry the `sync` mark, because the marker is legal only in a top-level or `foreign` signature.
- Recorded q2, q5, q6, ws-q1 and ws-q3 in §9.12 (l); no question of the section is open.
- Opened #593, #594 and #595 for the three probe facts, and #596 for `Task.withScheduler` in `core/Task.beni`.

**What I learned**

- `sync (…)` inside a `type alias` parses as a type variable named `sync`: the mark belongs on a top-level signature, so a value that must carry it is built by a function, not a constructor.
- A strict mailbox per object needs a cycle rule: Orleans and Restate both document the deadlock, and a call-chain id makes it a typed error.
- Hibernation and a parked fiber cannot meet if a live fiber holds a host timer; the price is that a handler that waits keeps the object awake.
