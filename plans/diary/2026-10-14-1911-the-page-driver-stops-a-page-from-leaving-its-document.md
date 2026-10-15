## 2026-10-14 19:11 CEST — the page driver stops a page from leaving its document

**What I did**

Fixed issue #102: `browser/direct/NavigateCommands` and `Router` failed their
value fuzz in Chrome with `TypeError: Cannot read properties of undefined`.
A trace showed the cause. The fuzzer sent `Load "<b>"` and `ClickedLink
(External "😀")`, the page's `location.assign` succeeded, and Chrome loaded
`chrome-error://chromewebdata/`, a document without the fuzzer's globals.
happy-dom loads nothing, but its fallback rewrote `location.href`, so the
gates passed. The driver now stops every navigation to another document and
logs `(the host leaves the page for "<url>")`: in Chrome at the Navigation
API's `navigate` event, plus `Page.resetNavigationHistory` so no traversal
reaches the target's `about:blank`; in happy-dom with
`disableFallbackToSetURL` and a wrapper on `Location`'s `href` and `reload`.
The README states the rule. `NavigateCommands` gained a successful load; with
the old driver it fails in both DOMs. Every `browser/` run hash was recorded
again. The gates fail only on #101's two budget cases.

**What I learned**

In Chrome 153 the `navigate` event cancels `assign`, `replace`, `reload`, an
`href` write, a form submission and `window.open(…, "_self")` at once, but not
a cross-document traversal; a target opened at `about:blank` keeps that entry
until `Page.resetNavigationHistory`. happy-dom's form submission bypasses
`Location`, so it is a listed DOM difference. `browser/direct/SettlesManyFibers`
fails in Chrome with and without this change (fibers not all settled after a
2 000-fiber click) under a loaded machine; it is not this defect.
