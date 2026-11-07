## 2026-11-07 12:51 CET — release workers honour the event limits (#2203)

**What I did**

- Found why a `--release` worker ignored `queuedEvents`/`queuedBytes`. The page
  sent the whole `Options` record in the Hello payload. The page pins its fields,
  because `newPeer` hands `Options` to a concrete `Js.from`. The worker read it back
  through `guest : V → a`, a `Js.to` at a type variable, which `boundary.md` §4
  treats as opaque. So the worker's projection gave `Options` its own short names
  (`h.b`, `h.a`), the limits were `undefined`, and no limit check fired.
- Fixed it in `Browser/Worker.beni`: the Hello payload is now `config` plus
  `eventLimit` and `byteLimit`, two keys the private worker encoding prescribes for
  both projections. The worker reads them by key. `serve` loses its unused
  `Options` parameter.
- On the page, an Event frame that finds the queue full is now the defect
  "Worker event exceeded the page event queue", not a dropped event. An Event after
  the queue ended is still ignored, because the reader has been told.
- Specified both in `workers.md` §7 (*Private control values*, *The page's event
  queue*).
- Fixtures `browser/managed/EventLimits` (custom limits 5 / 4096) and
  `browser/managed/EventQueue` (the issue's data fixture, default limits). Both
  failed in release before the fix and pass in development and release after it.
  With the handshake fix removed and the drop fix kept, `EventLimits` crashes with
  the new defect instead of printing a wrong answer.

**What I learned**

- Release field pins are per entry. §3's build-wide table covers only Wire roles.
  A platform-private value that crosses page and worker must travel as a keyed
  frame, never as a beni record read back through a type-variable cast.
- The audit of the other frames found no other crossing of this kind. Headers are
  concrete `Js.from` records read by key. Payloads are Wire roles, primitives, or
  `{code}`/`{message, stack}` records read by key.
