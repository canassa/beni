## 2026-11-03 21:39 CET — the three thin siblings move to beni

**What I did.** #877, `plans/runtime-in-beni.md` step 14, in one pull request: `platforms/html/Html.js`
(`targetValue`, `targetChecked`, `pointer`), `platforms/node/Prerender.js` (`writeRecords`) and
`platforms/node/Io.js` (`startReadDir`) are beni over `Js` in their modules, and the three files are
deleted. Spec first (row 14, step 14, `boundary.md` §9.3 and §9.8.20, `prerender.md`, the effects
proposal). The build found a compiler defect on the way, #1806: a beni payload extractor that is not
`pub` and has a block body was written with no `return`, because `Lower.findUnobserved` saw no read
of it in any BIR — the lowering's listener is its only caller. Every `browser/tea/Pointer*` page failed
with `Cannot read properties of undefined (reading 'x')` in `Html.localX`. Spec in `backend.md` §4
(*A result nothing reads*), the fix marks the vocabulary module's private extractors as read, and
`browser/dom/PrivateViaBlock` is red before (the page shows `"undefined"`) and green after.
`emit/release/app/IoReadDir` pins the listing's shape.

**What I learned.**

- `e` is a prelude value (Euler's number): a parameter named `e` is `SHADOWING`. The siblings'
  parameter `e` became `ev` in beni.
- A one-line beni body is an expression arrow and keeps its value whatever `findUnobserved` says, which
  is why #925's fixtures passed while a block body lost its tail. A fixture for a new kind of
  declaration should have a block body as well as a one-liner.
- A beni-written `via` can be probed outside the corpus: copy `browser/dom/PrivateVia` to scratch,
  build it with `--platform=<copy>/platform` and read the emitted vocabulary module.
- `Entry.name` keeps its name under `--release` because `Js.get entry "name"` reads a host property
  of that text (one text, one spelling); `kind` gets a short name.
- A prerender data program is built by hand as `beni build <site>/data <site>/shared --platform=node`:
  each `"data"."paths"` entry is its own source root, and the site build runs it in development mode.
