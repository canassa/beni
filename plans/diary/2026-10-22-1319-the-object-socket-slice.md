## 2026-10-22 13:19 CEST — the object's WebSocket

**What I did.** Built the server WebSocket of a Durable Object for the `cloudflare` platform
(`boundary.md` §9.12 (g), as built): the handle operations §9.11 shares, `id`, `tags`,
`attach` and `attachment` in the attachment envelope, `Object.accept`, `acceptWith` and
`autoReply`, the three socket events of the mailbox, and the binary-frame rule. The workers
driver drives a client through Miniflare's own (`dispatchFetch` with `upgrade: websocket`), with
the steps `socket`, `send`, `close` and `receive`. One fixture, `workers/ObjectSocket`.

**What I learned.**
- `ctx.getTags(ws)` needs the object's state, which a `Socket` does not carry; the tags go into
  the attachment at `accept`, with the id and the protocol, and read back from there.
- The `sec-websocket-accept` header answers Miniflare's random client key, so a transcript must
  show it as present and not by value.
- A `write` right after the object's own `close` is `Err NotOpen`: the socket is closing. A
  fixture that waits for an answer there waits the full step limit for nothing.
