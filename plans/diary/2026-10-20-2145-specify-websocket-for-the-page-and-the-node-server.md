## 2026-10-20 21:45 CEST — Specify WebSocket for the page and the node server

**What I did**

- Wrote `boundary.md` §9.11: one WebSocket design for `browser`, `browser-tea` and `node`
  (#524, and the WebSocket part of #340). Both platforms get a module `WebSocket` with one
  common surface: `Socket`, `Close`, `read`, `write`, `close`, `buffered`, `protocol` and an
  identity `eq`. The page adds `connect` (the direct form), `listen` (a `Sub.on` listener, no
  fiber), and the commands `send` and `disconnect`. The server adds `Http.Server.listenWith`
  with an `upgrade` handler that answers `accept session` or `refuse response`, and `drain`.
- Specified every failure that the WHATWG standard and Node document, the RFC 6455 rules the
  server enforces (1002, 1003, 1007, 1009), lifetimes, back-pressure, and the test steps.
- Put binary messages in a later slice: beni has no `Bytes` type yet.

**What I learned**

- Node 24.19's `shouldUpgradeCallback` sends a request with another `upgrade` header to the
  `request` event, so only WebSocket upgrades leave the normal handler.
- `server.closeAllConnections()` does not reach an upgraded socket, and `server.close()`'s
  callback waits for it (measured). The platform must keep its own set of WebSocket
  connections.
- A browser may send only 1000 and 3000–4999 in `close`, so the page cannot send the 1003 that
  RFC 6455 gives to data it cannot accept.
- A platform cannot write `equatable`, but its module can give a `foreign type` a `pub eq`. That
  keeps `==` on a model that holds a socket.
