## 2026-10-20 23:17 CEST — WebSocket on the node server

**What I did**

- Built `node`'s `WebSocket` module and `Http.Server.listenWith` (`boundary.md` §9.11 (e)–(i),
  and the amendment's items 14–28): an `upgrade` handler that answers `accept`, `acceptWith` or
  `refuse`, a session per connection with a pull `read`, and the RFC 6455 codec in the sibling
  `WebSocket.js`, with no package.
- Gave the serve driver its own small WebSocket client, with steps for the handshake, text,
  raw frames, pings, closes, counted reads and resets, and the preload a `socket:<code>` fault.
- Nine `run/WebSocket…` fixtures, and the load test of the game's shape: 100 players, 30 ticks a
  second, 3.8% of one core.

**What I learned**

- An upgraded socket is half open: a client's FIN gives only `end`, and the session waits for
  ever unless the platform ends the socket itself.
- Node emits `drain` only after a `write()` that returned `false`; a small write followed by a
  wait for `drain` waits for ever. The callback of the last write is the signal that always
  comes.
- A Linux socket can end with any errno of the two ICMP tables, and libuv names most of them, but
  not `ENETRESET`: match that one by its number.
- A test that must show a hang needs the state that makes it: here a write that Node queues only
  in part, which a client that stops reading produces once the kernel's buffer is full.
