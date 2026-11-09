## 2026-11-09 05:02 CET — the browser driver pins performance.now

**What I did**

- Issue #1930. The browser driver (`tests/browser/driver.mjs`) made `Date.now`, the timers and
  the frames virtual, but not `performance.now`. `Clock.elapsed` reads `performance.now()` outside
  `Clock.run`, so a page read the host's real clock.
- The prelude now defines `now` as an own property of `performance` that reads the page's virtual
  clock, in happy-dom and in Chrome. A happy-dom page's `close` deletes it again.
- `click-wait` used `performance.now()` for its real 5 s deadline. It now uses
  `clock.realNow`, the host's reading that the prelude keeps before the pin.
- New page `tests/corpus/browser/tea/ClockElapsedAdvance`: it reads `Clock.elapsed`, advances
  250 ms, and reads again. Before the fix it read 123 ms and then 124 ms; after, 0 ms and 250 ms,
  in happy-dom and in Chrome. `tests/corpus/README.md` names the pin.

**What I learned**

- Under happy-dom every page shares Node's global object, and the window's `performance` is
  Node's own object. A pin on it is a pin for the driver too, so the driver must keep the real
  reading for its own deadlines and the page's `close` must remove the pin.
- A first version of the fixture appended to a list in a record update
  (`[ …m.readings, x ]`). The ownership v1/v2 parity check then failed (`accepted :: absent`). The
  fixture is not about ownership, so it uses two fields instead.
