## 2026-10-21 10:57 CEST — WebSocket server: the review fixes

**What I did**

- Answered the bot's and ws-review's findings on #553 (the `node` server WebSocket).
  - A client that leaves while the program decides keeps `Server.js`'s `error` listener until
    the socket is known alive.
  - The log line for a protocol that the client did not offer quotes the protocol.
  - The serve driver reads a refused upgrade's body to its end.
- Added fixtures for the rules that had none:
  - `WebSocketBackPressure`: five pings while more than 1 MiB waits give one pong, for the latest.
  - `WebSocketFaults`: 1009 for two fragments that are over the limit only together; 1002 for a
    64-bit length with its high bit, the control opcode 11, and the close codes 1016 and 2999.
  - `WebSocketNetworkReset`: the preload's new `socket:errno=ENETRESET` gives an error with only
    the number, as on macOS. The connection ends with 1006, and the server goes on.
- Proved each new case red on a copy of the codec without its rule.
- Rebased on master (27 commits) and recorded the run hashes again.

**What I learned**

- `WebSocketLifetime` had a race. `Server.close` and an accept after it each sent 1001 in the same
  tick. Each session logged its end when its client answered, so the two lines came in either
  order. The gates passed three times before it showed: the dev build printed one order, and the
  release build the other. A fixture with two sessions that end from one event needs an order
  that the program makes, not an order that the network gives.
- A ping test needs no real time: an HTTP request that the session answers after its writes puts
  the pings after the writes.
- Node gives an errno that libuv does not name the `code` `Unknown system error -<n>`. So only a
  test of `errno` finds `ENETRESET`.
