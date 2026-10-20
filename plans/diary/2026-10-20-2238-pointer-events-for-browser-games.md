## 2026-10-20 22:38 CEST — pointer events for browser games

**What I did**

- Wrote `boundary.md` §9.8.20: Pointer Events as the one API for the mouse,
  the pen and the touch screen (issue #525). A handler gets an `Html.Pointer`.
  `localX` and `localY` are CSS pixels in the border box of the element that
  has the handler.
- Added the six pointer events and their readers to `platforms/html/`. The
  events are not `delegated`, so `currentTarget` is the handler's element
  under `dom` and under `browser-inline`.
- Added the `.steps` step `pointer`, four page fixtures, and
  `examples/steer`, a dot that follows the mouse or a finger.
- Opened #527 (the page fuzzer sends no pointer events) and #532 (a
  non-`pub` `via` extractor is accepted, and the lowering then hands the raw
  event).

**What I learned**

- The checker accepts a `via` that names a non-`pub` `foreign`, but the
  lowering looks the extractor up in the interface, which holds only `pub`
  values. It then writes `Rt$identity` with no diagnostic. A private
  parameter type (`Dispatched`) keeps a `pub` extractor out of reach of
  programs.
- The release minifier keeps the spelling of a name that stands before `:`
  anywhere in a hand-written file. A key `e` in one export stopped the
  rename of every parameter `e` in `Html.js`. Measure the release file of a
  page that does not use a change, byte for byte.
- happy-dom has no layout: every box is at 0. A step that names its point in
  the box of the handler's element prints the same transcript in both DOMs,
  and only Chrome checks the conversion.
- A `crossing` word on a new platform type must be listed in
  `tests/corpus/ownership/trusted-surface.txt`, with a fixture that names
  the type.
