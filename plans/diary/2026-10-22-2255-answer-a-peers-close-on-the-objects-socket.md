## 2026-10-22 22:55 UTC — answer a peer's close on the object's socket

**What I did**

- Snake Arena found that a client's close 1000 to a Durable Object's socket gets no close reply
  (#724). Probed the pinned workerd 1.20260518.1 under Miniflare with a plain Durable Object:
  under the default flags the runtime does not answer a hibernatable socket's close frame.
  `readyState` is CLOSING in `webSocketClose`, the client waits, and the beni `close` guard on
  OPEN did nothing from `closed`. A `ws.close(code, reason)` in the handler completes the
  handshake in a millisecond; 1005 (no code) and 1006 throw `InvalidAccessError`, a bare
  `close()` answers 1005; a second close is silently accepted; after the object's own close the
  state is CLOSED. Naming `web_socket_auto_reply_to_close` refuses to start the runtime.
- Fixture first: `workers/ObjectSocket` gets a receive after the client's close 4002 and an idle
  socket closed with no code; `closed` calls `close` again. Without the fix both receive steps
  print `(nothing arrived)`.
- The platform answers the peer's frame in `webSocketClose` before `closed` (`Object.beni`,
  `answerClose`), echoing the code, or a bare close for 1004, 1005, 1006 and 1015. §9.12 (g)
  carries the dated amendment; the skill names it. No compatibility flag is set.
- #771's three nits: the README says a missed `until` line fails the run, the driver names it
  on standard error and sets `process.exitCode` instead of exiting.

**What I learned**

- Cloudflare's documented auto reply to a close frame does not hold for hibernatable sockets on
  this workerd. Measure the pinned runtime; the documentation names the contract, not the build.
- A dropped socket (1006) is also CLOSING in the handler, so a guard on the code, not only on
  the state, is what keeps the host from throwing.
