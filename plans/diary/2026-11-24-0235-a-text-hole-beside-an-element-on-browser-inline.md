## 2026-11-24 02:35 CET — A text hole beside an element on browser-inline

**What I did.** Compiled a text hole beside an element on `browser-inline` (#2650): an element
whose children mix elements with texts and text holes keeps each text a node of its own, made at
the mount with the row's `rowText` before the element after it, and a hole's node is written by
`text` in its own group. Spec `browser-inline.md` §8.2, *A text hole*, amended 2026-11-24, and
§8.7; `prerender.md` §6.3. Page `browser/inline/TextBesideElement`; `TodoMVC` and
`TodoRouting` copied from `browser/tea` (TodoRouting's transcript is tea's byte for byte;
TodoMVC's but for the empty comment tea keeps where a row's editor region shows `<></>`);
`emit/release/inline/TextBesideElement`; `build/bad/inline/TextBesideElement` moved to
`build/bad/prerender/`. Sweep of the 357 tea + dom pages on `browser-inline`: 192 → 194.
TodoMVC `--release`, every `.mjs` concatenated, brotli 11: `browser-tea` 9 089 B,
`browser-inline` 4 472 B (raw 24 443 / 12 452).

**What I learned.** The row path already had the whole design; the page needed a list of text
nodes made at the mount, one field on a write, and the anchors counted as referred elements.
Making the texts before any region or `For` state keeps source order for free. A reviewer must
run the page driver with `--parser=tests/browser/parse5.mjs` as the harness does, or happy-dom's
own parser misreads unquoted attributes. TodoMVC's inline bytes are 226 B over the S6 bar
(< 4 246 B).
