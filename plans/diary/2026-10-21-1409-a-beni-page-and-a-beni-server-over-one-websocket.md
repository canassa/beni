## 2026-10-21 14:09 CEST — A beni page and a beni server over one WebSocket

**What I did**

- Built slice (d) of `boundary.md` §9.11, #524's demonstration, and specified it first in a dated
  amendment to (l).
  - `examples/chat/` has a shared protocol module, a `node` server with an `origin` check, and a
    `browser-tea` page that connects again after a wait.
  - The page driver has `--server=127.0.0.1:<port>`: it opens the page from the program's port and
    gives it a real `WebSocket`. Its new step `socket <n> wait` waits for that socket in real time.
  - The serve driver has `page`, `page-wait` and `page-end` steps. They run the page beside the
    driver's own clients, in the order of the script.
  - `tests/blackbox/chat_example_test.zig` builds both programs as the README says and runs them
    together.
- Took #571 in the same branch, because it changes the same driver: a scripted `open` that no host
  allows now fails the step. Two tests in `browser_test.zig` pin it.
- Recorded the two owner decisions (`ws-q1`, `ws-q3`, both as recommended) in the amendment.

**What I learned**

- Node's own `WebSocket` (undici) cannot run in a page under the page driver. It calls `unref` on
  what `setTimeout` returns, and the page's virtual clock returns a number, as a browser's does.
  The connection fails before it opens, with no exception the page sees. `NODE_DEBUG=undici`
  showed the cause in one run. happy-dom's own `WebSocket` (it wraps the `ws` library) works.
- `-Dtest-filter` also filters the corpus walker that a `browser_test.zig` case starts, because
  the walker is a Zig test binary too. Such a case then runs no page, and its result means
  nothing. Run `browser_test` without a filter.
- A wait for "open" must look at an `open` event, not at `readyState >= 1`, because a socket that
  failed is `CLOSED`, which is 3.
- `master` can be red after two green pull requests merge: the skill's generated API reference did
  not know the WebSocket modules until `110cd10bd`. Rebase before a long job.
