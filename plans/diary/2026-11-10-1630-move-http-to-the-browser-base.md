## 2026-11-10 16:30 CET — Move Http to the browser base

**What I did**

- Moved `Http` from `browser` to `browser-base`. The base, `browser` and `browser-inline`
  re-export it.
- Added `browser/prerender/BaseHttp`: a prerendered inline page whose request goes out only
  after the takeover; success, `BadStatus`, `NetworkError` and `Http.send` render as values.
- Added the refusals `BaseHttpInView` and `BaseHttpInInit`.
- One release emit golden (`tea/HttpSendTracked`) moves by +6 raw / +4 brotli. It is held for
  review.

**What I learned**

- A request in `view` or `init` is refused by the checker as `suspending_callback` before the
  prerender check runs, so there is no `prerender_impure` for `Http`.
- Inline builds a message from leaf fields: a `Got String (Result …)` message that `update`
  reads whole is a compiler limit. Let the command turn the answer into one value first.
- The driver's scripted `fetch` (`respond`, `fail`) shows that the prerender build sends no
  request: the first fetch is logged at load.
