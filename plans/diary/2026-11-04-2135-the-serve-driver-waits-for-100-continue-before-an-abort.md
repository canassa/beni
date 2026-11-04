## 2026-11-04 21:35 CET — The serve driver waits for 100 Continue before an abort

**What I did**

- I made `run/HttpServerBadClients` deterministic (#1661). The `abort` step of
  `tests/serve/driver.mjs` now sends `expect: 100-continue`. It destroys the
  request when the server answers `100 Continue`. The golden did not change.
- The text of the change is the same as on the `workers` branch. #1615 put it
  there on 2026-11-02, but #1615's base is `workers`, so the fix did not reach
  master and #1661 stayed open. #1616 takes `workers` to master and is still
  open.
- I measured under load: 16 loops at the same time, 1 280 runs of the
  fixture's two builds. Master's driver failed 111 times, each with
  `handlers ran: 6`. The fixed driver failed 0 times.
- I checked the other `run/` fixtures that cut a client. `HttpServerOwnerEnds`,
  `WebSocketLifetime` and `WebSocketNetworkFault` do not share the race, so I
  did not change them.

**What I learned**

- The aborted request was never lost. A traced copy of the fixture shows the
  real defect: the order between two connections. On master, `/release` often
  starts before `/slow`, even with no load. The reason is that `/release` uses
  the keep-alive connection, which is open already, and `/slow` needs a new
  connection. Under load `/stop` can start before `/slow` too, and then the
  count is 6. In 640 traced runs under load, 42 had the order `/release`,
  `/stop`, `/slow`, and each of them counted 6. With the fix, all 640 had one
  order: `/slow`, `/release`, `/stop`.
- `100 Continue` is an event from the server. Node writes it just before it
  emits `request`, and the request's `end` comes in the same turn. So the
  client can only send the next request after the server queued `/slow`.
- An issue that a pull request into a feature branch "fixes" stays open, and
  master keeps the defect until the feature branch merges. Check the base of
  the pull request that an issue names.
