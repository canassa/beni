## 2026-11-24 14:41 CET — host calls refuse peer and program input (#1995)

**What I did**

- Reproduced #1995's first item on master `e72a8bfd80`: a `trailer` response
  header made `writeHead` throw `ERR_HTTP_TRAILER_INVALID`, and the Node server
  ended. `Http.Server` now refuses `trailer` as a header the transport owns:
  500 and one line on standard error, as for `content-length`.
- `WebSocket`: a 64-bit frame length with a high word that is not 0 now stands
  for 2³², which is over every `maxMessage`. No `high * 2³²` product is made.
  This is latent until `Int` arithmetic is checked (#1988), so its corpus case
  passes before and after.
- Browser `Http`: a `stringBody` MIME type that `Headers` cannot hold is
  `BadRequest (InvalidHeader "Content-Type")`. A timeout past 2³¹ − 1 ms is a
  chain of timers, as `Task.sleep`'s is. Before, it fired after 1 ms.
- `Browser.Address.go` clamps the delta to a WebIDL `long`. Before,
  `forward 4294967295` went one entry back in Chrome.
- Fixtures: `run/HttpServerInvalidResponse`, `run/WebSocketFaults`,
  `browser/tea/HttpFailures`, `browser/tea/NavigateCommands`.

**What I learned**

- workerd keeps a `setTimeout` delay past 2³¹ − 1 ms. Miniflare 4.20260518 did
  not fire 2147483648, 4294967296 or 4294967297 ms in 300 ms. So the Worker
  `tick` is not a defect.
- happy-dom neither throws on a non-Latin-1 `Headers` value nor wraps
  `history.go`'s argument. The navigation case shows the fault only in Chrome.
  I ran it there by hand, before and after the fix.
- `beni fmt` reads `Basics.max -2147483648 x` as a subtraction. Write
  `negate 2147483648`.
- A fixture edit that moves lines also moves the keys of
  `tests/blackbox/ownership-v2-known.txt` (`OwnershipV2Differs`). Move the
  keys and keep the reasons.
