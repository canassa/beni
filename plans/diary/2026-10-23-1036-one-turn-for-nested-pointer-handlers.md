## 2026-10-23 10:36 CEST — one turn for nested pointer handlers

**What I did**

- Took #557 with Solid 2's choice, spec first: `boundary.md` §9.8.20
  (b), (d), (g) and §9.3, and one bullet in `backend.md` §15.11.
  `onPointerDown`, `onPointerMove`, `onPointerUp` and `onPointerCancel`
  are `delegated`. The walk defines the event's `currentTarget` as the
  node whose handler runs, and removes it in a `Js.finally`.
- Gave the `pointer` step `trusted`: a user's mouse move, in Chrome
  through `Input.dispatchMouseEvent`. Chrome dispatches the move at a
  frame, so the step waits for its `mousemove` on the window.
- `browser/dom/PointerNested`: `press` and a trusted move on nested
  handlers, the same events untrusted, and a disabled button. It fails
  without the change in both DOMs (the outer handler sees the new count,
  and the disabled button's handler runs) and passes with it.
- Measured in headless Chrome (`bench/ui/pointer.mjs`): a move costs
  about 1.4 µs more, and a render of 1 000 rows with a pointer handler
  is 1.3 ms faster. Release pages that delegate an event grow by 22 to
  46 bytes brotli, and `examples/steer` by 128.
- Opened #854: `backend.md` has double-encoded UTF-8 in 1131 lines.

**What I learned**

- Chrome and happy-dom keep `currentTarget` as an accessor on
  `Event.prototype`. An own property on the event hides it, and a
  `Reflect.deleteProperty` shows it again.
- `press` already sends a trusted `pointerdown` and `pointerup` in both
  DOMs, so only the move needed a new step.
- A walk change moves the `emit/release/` goldens of every page that
  delegates an event, because a release build carries the runtime.
