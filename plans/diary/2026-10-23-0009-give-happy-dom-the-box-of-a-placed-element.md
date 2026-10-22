## 2026-10-23 00:09 CEST — give happy-dom the box of a placed element

**What I did**

- Chose #558 before #557. #557 can move the pointer extractor into a
  delegated walk, and only #558 lets the gates see the box that the
  extractor subtracts.
- Under happy-dom, the driver's prelude now gives `getBoundingClientRect` a
  box for an element whose inline style has `position: absolute` or
  `fixed` and `left` and `top` in pixels. The box is the one that Chrome
  gives on a page that is not scrolled. Any other element keeps happy-dom's
  box at 0. Documented in `tests/corpus/README.md` and with a dated
  amendment in `boundary.md` §9.8.20 (g).
- Red checks under happy-dom: an extractor with no subtraction, and one
  that reads the box of `target`, each fail `browser/tea/PointerInput` and
  `browser/dom/PointerEvents`. With the old driver, the extractor with no
  subtraction passes.

**What I learned**

- The `pointer` step and the extractor read the same box function. So an
  emulated box changes no transcript of a correct page, and no `.expected`
  file changed.
- `browser/inline/PointerPoint` cannot use the emulation: `browser-inline`
  compiles no `style` attribute yet, so its arena is not placed.
