## 2026-10-29 19:48 CET — Events.js and browser-inline's Tea.js move to beni

**What I did.** Step 9 of `plans/runtime-in-beni.md`, PR 8 of #877: `Browser.Events.size` is two
`Js.global` reads and the private `hidden` an `===` through `Js.same` on
`document.visibilityState`; `browser-inline`'s `Tea.sandbox` and `Tea.element` take the shape
`document` and `application` already had, a body `unreachable app` that the `inline` lowering
never reaches, so the platform has no sibling left. Spec first: the plan's row 9 and *Step 9*,
`core-in-beni.md` step 4, `browser-inline.md` §10.5, `boundary.md` §9.8.8. The ownership word
list moves two rows from `Tea.js` to `Tea.beni` with the beni bodies' hashes, and `check_test`'s
row filter follows them. `emit/release/tea/WindowSize` pins the two reads in place.

**What I learned.** A `foreign` whose body is never reached still owns a row in
`word-bodies.txt`, keyed by the sibling file: moving it to beni moves the row and its hash, and
the test that filters rows by file name must follow. A sibling can be gone without a byte of
release output moving: `Minify` kept only what a build imported, and `Tea.js`'s exports were never
imported, so only development output trees change, and the bar is the pages that read the
window.
