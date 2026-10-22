## 2026-10-22 12:49 CEST — the Durable Object slice

**What I did.** Built `Worker.Object` and `Worker.Storage` for the `cloudflare` platform
(`boundary.md` §9.12 (e), (f), (h), (k), as built): one mailbox and one consumer fiber per
instance under its own scheduler, `restore` at each start, the typed protocol with `post`,
`ask`, `reply` and `replySchema`, the call-chain id through `stub.fetch`, the holders rule
for `NoReply`, the timer and the alarm, the defect's teardown and abort, and the key-value
store through schemas. Five `workers/` fixtures: `ObjectCounter`, `ObjectAsk`,
`ObjectHolders`, `ObjectIsolation`, `ObjectStorage`. Two test hooks on an object,
`/__beni/tick` and `/__beni/alarm`, so the transcript depends on the steps alone. Asked the
owner how `tick` is checked to be sync (`cf-workers-q9`). Answered round 2 of #705 and its
round 3 approval meanwhile.

**What I learned.**
- A function read back through `Js.to` is called in its sync form: a handler that waits then
  returns the park sentinel, and the caller reads `.a` of it. The typed values must be threaded
  from where their effects are known (`define`) to the call. The same held for `Js.maySuspend`
  on a record field, which answers in `define`'s twin, not for the field.
- The mailbox's consumer must be woken after a hook event too; a wake only at the end of one
  branch left the hook requests unanswered for 5 s.
- A tagged-union protocol of ten variants put the release case at 4 441M instructions, over
  the 4 300M budget; a record protocol with an `op` field is a fraction of it. Split and
  shrink the fixture, never the budget.
- The `Reply` an `ask` is making has no instance yet; only one parsed in this instance names a
  pending request here, so only that one is `Unprintable` for another stub.
