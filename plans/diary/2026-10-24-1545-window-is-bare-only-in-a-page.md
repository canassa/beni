## 2026-10-24 15:45 CEST — `window` is bare only in a page

**What I did**

- Closed #936 with the owner's decision of 2026-10-24: a platform states that it always runs
  in a page with the new manifest key `"host": "page"` (`boundary.md` §5.2, added; first-found
  down the chain; any other value is a malformed manifest). `browser` and `browser-inline`
  declare it, so every layer over them does; `node`, `cloudflare`, `html` and the test
  platforms do not.
- `Rename.page_globals` (`window`) is now separate from `Rename.bare_globals`. The printer
  writes a page global bare only when `Emit.Platform.page` is set (`backend.md` §9, item 8,
  amended). It also writes `globalThis["x"]`, the index form `Js.global` takes when its name
  arrives as a value, bare on the same terms as `globalThis.x`. This form is what
  `Listen.on "window"` prints once inlined.
- Evidence: the 12 `emit/release/inline` goldens with a push subscription go from
  `f=globalThis.window` to `f=window`, and nothing else changes in them. The new
  `emit/release/core/GlobalWindow` (node) pins `globalThis.window`. All 13 were red with the
  source changes stashed.

**What I learned**

- Before this change, `Js.global "window"` written as a literal already printed as bare
  `window` on every platform under `--release`, node included. The member form went through
  `bareGlobal`. Only the index form missed it. So the non-page half of this change fixes a
  latent `ReferenceError`. No shipped code reached it.
- The same hazard is still there for the other page-only names in `bare_globals`
  (`document`, `localStorage`, `location`, `history`, `HTMLElement`, …): on node they are
  written bare. Nothing in core, node, cloudflare or html reads them today. It is #941. I did not widen this change.
- One more check in `Print.rawRecursive` overflowed the deep-chain unit test's 1 MiB stack,
  even when the check was a `never_inline` call. That frame has no room left. The recursive
  `expression` and `raw` now give a `globalThis[k]` to `run`, whose `expand` holds the check.
- The independent review found that the index form at first made `globalThis["document"]` bare
  on node too. That was new exposure. The index form is bare only on a page chain now.
