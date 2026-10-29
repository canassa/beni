## 2026-10-29 19:51 CET — prerender P2b: input before the takeover

**What I did**

- Amended `prerender.md` §6.5 first with the exact shape (#1206): an inline capture script written
  before the unit, listening at the document in the capture phase for the unit's event kinds, and
  removing itself; records hold the event object, so the target is the page's own element; the
  mount takes them once through the global `$beni` (`Inline.caught`), keeps those inside the unit
  it took (so a fresh mount drops them all), notes every listener it wires (`Inline.listen`,
  `onTaken`, `onArmTaken`) and hands each record on last (`Inline.deliver`), control state written
  back, the event never dispatched again.
- Built it in `platforms/browser-inline/` (lowering and runtime). A page with no listener gets no
  script, and a page that does not prerender is byte-identical (`bench/size.mjs --pages-only`
  equal to `master`'s compiler).
- The browser driver runs a prerendered page's inline scripts, and its setup step `early <step>`
  acts before the program loads. Fixtures: `EarlyInput`, `EarlyNone`, `EarlyFresh`.
- Measured: script 294 B raw, 161 B brotli; runtime +270–294 B brotli; the mount is not slower,
  navigation to handlers +0.2–0.8 ms on a loaded machine.

**What I learned**

- happy-dom runs no script element at all, inserted or parsed, and neither DOM runs a script a
  `DOMParser` made. The driver runs the page's inline scripts itself with an indirect `eval`,
  `document.currentScript` defined on the document for the call.
- An event keeps its `target` after its dispatch ends (no shadow DOM), in Chrome and happy-dom, so
  the record can be the event itself and a `via` extractor reads it unchanged.
- `browser-inline` refuses an `update` arm that branches on a `Bool` payload in a written field
  (`log = model.log ++ (if on then …)`): "would need a dispatcher". `EarlyInput` avoids it.
- A worktree-isolated agent cannot run compound shell commands that mention git; plain commands
  and `git archive` into a scratch directory work for a red check against `master`.
