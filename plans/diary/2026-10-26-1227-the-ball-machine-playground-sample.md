## 2026-10-26 12:27 CET — The ball machine as a playground sample

**What I did.** Issue #1041: the flow page's ball machine as a `browser-tea` playground
sample, `tests/corpus/browser/tea/BallMachine.beni` (+ `playground/samples/browser-tea/
BallMachine.css`), copied into the site by `zig build playground` as TodoMVC is. The control
program is the page's — `admit`, `batch`, `finish` and `retry` over `Task.forever`,
`Semaphore.acquire`/`release`, `Task.sleep`, a `Queue` per sensor — with a fifth fiber that
steps `flow.js`'s physics in a `Ref` on `Browser.Events.eachAnimationFrameDelta` and sends a
picture to `update`. `view` is one SVG scene: gradients in `<defs>`, shadows as filters on
fixed parts and on the balls' one group, dashes as `stroke-dasharray`, the pipe's light in a
`<clipPath>`, the air and the light animated by CSS. With `?debug` the machine logs each ball
let in, each drop and each retry; the fixture runs the sample itself on the virtual clock with
that, and its golden is the evidence for the three rules: never more than "At once", drops at
size or after exactly 500 ms, retries of 200 ms then 400 ms. Gates, `test-playground` and
`test-playground-page` green; looked at in headless Chrome beside the real flow page.

**What I learned.**
- `browser-inline` cannot run this: its `Cmd.perform` refuses a body that may suspend, so
  there are no fibers there yet.
- The page's own `main` would stop at once in beni: `Task.scope` cancels its fibers when the
  body returns, so the sample ends the body with `Task.never ⊤`.
- A sample cannot be imported by a wrapper fixture: two `main`s are `duplicate_main`. The
  fixture had to be the sample, and a debug log the instrument.
- Most of a frame-heavy browser fixture is the driver's real `setTimeout(0)` per settle
  (#1075): 0.87 s a page, 0.39 s with `setImmediate`.
- The html vocabulary has no `dx`/`dy` on `<feOffset>` and no `<feDropShadow>` (#1074).
