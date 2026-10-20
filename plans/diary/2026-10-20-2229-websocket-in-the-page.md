## 2026-10-20 22:29 CEST — WebSocket in the page

**What I did**

- Built `browser`'s `WebSocket` module (`boundary.md` §9.11 (b)–(d), (j)) in beni over `Js`:
  `connect` (a `Task.bracket`), `listen` (a `Sub.on` listener, no fiber), `read`, `write`,
  `close`, `buffered`, `protocol`, an identity `eq`, and the commands `send` and `disconnect`.
  `browser-tea` re-exports it.
- After the review of #531: an `error` alone ends a connection (WebKit fires no `close` after
  it), a fragment is any `#` in the URL, and `buffered` is 0 after the end.
- Scripted the page's `WebSocket` in the page driver, as `fetch` is, with `socket` steps.
  Four `browser/tea/WebSocket…` fixtures, each also run with fibered listeners.
- Measured: the module costs about 890 bytes over another listener page; one message with a
  new 936-byte state costs about 4.3 µs from the event to the render, what hand-written
  JavaScript costs.
- After ws-review: fixtures for the empty fragment, for a defect while `connect` holds a socket,
  and `WebSocketEquality` for the identity `eq`.

**What I learned**

- The driver's bytes are in every page's run hash, so a change to `driver.mjs` re-records all
  of them (558 files). In a fresh worktree the first full run also meets a cold V8 compile
  cache, about 240M instructions more per page process: TodoPage, the Conduit value fuzz and
  others then go over their budgets. Record the hashes first; the gates after it are green.
- A platform module can check its beni code against a directory copy of the platform chain
  (`beni check --platform=<copy>/browser-tea`) and even build and run pages with it, with no
  rebuild of beni and no wait for the shared lock.
- `String.contains` is subject first: `String.contains href "#"`.
- A benchmark whose payload never changes measures a write the view skips: the first figure,
  3.5 µs, was that. Give each message a new state.
- The standard is not the browsers: WebKit can fire `error` with no `close`, and Chrome alone
  throws `SecurityError` for an insecure socket. A scripted socket that follows the standard
  cannot find either; the driver needs a step for each host behaviour.
