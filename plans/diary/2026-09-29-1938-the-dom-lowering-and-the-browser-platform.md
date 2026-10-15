## 2026-09-29 19:38 CEST — the dom lowering and the browser platform

**What I did**
- Merged the `browser` platform: the `dom` lowering (`platforms/browser/zig/dom.zig`, ported
  from dom-expressions with file:line citations), its runtime (templates, keyed and positional
  rows, events, the microtask render loop), `emit/dom/` goldens, five page fixtures, and a
  differential oracle comparing templates against dom-expressions' own 16 fixtures
  (`tests/oracle/`). Gates green, `-Dllvm` green, headless Chrome green.
- Measured immutable array representations (report 38) and discussed `core/Array` with the owner:
  keep `List` as the cons list; `Array` is either the hybrid (plain array ≤1024, 32-way trie
  above) or a plain JS array read as `a[i]` with copying updates. Not decided yet.

**What I learned**
- The spec contradicted itself: skipping `view` when `update` returns the same model breaks the
  controlled input that puts back a rejected edit, so a flush renders after every message.
- `html` declares custom elements as `"*-*"`, which the vocabulary rules forbid (one `*`), so
  `<my-widget>` is `unknown_element` today.
- Headless Chrome fires no `focus` events without focus emulation.
