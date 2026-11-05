## 2026-11-05 12:57 CET — the browser driver settles with no real-time floor

**What I did**

- Issue #1075. `tests/browser/driver.mjs`'s `settle()` took each turn with
  a real `setTimeout(…, 0)`. A turn is now one task in the queue that
  core's scheduler uses: Node's `setImmediate` under happy-dom, and in
  Chrome a message to a `MessagePort` of the driver's own. The prelude
  takes both from the host before the page runs. The driver does not count
  the driver's own channel.
- Specified the turn first, in `tests/corpus/README.md`: what a turn
  guarantees, and what it does not wait for.
- No transcript changed. Every `browser/` page passed against its golden
  in happy-dom (the corpus) and in Chrome (`test-browser`).
- Measured, at load 9 to 28:
  - BallMachine, two pages in one Node process, by hand: 1.90–2.01 s
    before, 0.85–0.93 s after. CPU time did not change.
  - The `browser/` part of the corpus (fresh run-hash directory):
    88.4 s wall and 655 CPU-s before, 73.9 s and 616 CPU-s after.
  - `test-browser`: 429.7 s wall and 1 350 CPU-s before, 311.8 s and
    1 130 CPU-s after. Its BallMachine case: 19.9 s before, 9.9 s after.

**What I learned**

- Chrome paid the floor more than happy-dom. A nested `setTimeout(…, 0)`
  is held to 4 ms after five levels, and `settle` nests every turn.
- Under happy-dom, the driver's "real" timer was happy-dom's own
  `window.setTimeout`, not Node's. Its zero-delay timers share one Node
  `setTimeout(…, 0)`. So the old turn also ran happy-dom's own zero-delay
  work (`window.postMessage`, `hashchange`, `FileReader`) by accident. No
  fixture depended on it; the README now says that a turn does not wait
  for it.
- Chrome inside a nested `nix develop` did not start: the socket path
  under the nested `TMPDIR` was longer than a Unix socket allows. A short
  `TMPDIR` (`env TMPDIR=… zig build test-browser`) fixed it.
