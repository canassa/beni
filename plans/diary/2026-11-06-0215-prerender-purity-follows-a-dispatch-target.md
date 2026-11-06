## 2026-11-06 02:15 CET — prerender purity follows a dispatch target

**What I did**

- Issue #1247. A prerendered `view` that used `<` on a type whose
  `compare` only calls `Debug.log`, or `x.m` on another module's type
  whose `m` only logs, was refused with `prerender_impure` at the call.
  The purity walk in `src/js/Lower.zig` (`effectOf`) did not read the
  target of the dispatch site.
- Amended `docs/design/prerender.md` §3.1 (dated 2026-11-06). A method
  call or an operator is now answered by the body of the function that
  the dispatch resolves to, when that is a top-level function of the
  module, of an app module or of a platform module. Evidence that the
  call passes stays the effect. Every other target (a field, a derived
  function, a codec, core) stays the effect at the call.
- Added `Dispatch.calleeOf`, the one lookup of a dispatch target. The
  totality proof and the new `dispatchEffect` both read it.
- Fixtures: `browser/prerender/DispatchDebug` (red on master, green on
  head) and `build/bad/prerender/DispatchImpure`, `DispatchEvidence`
  (refused on both; the head names the call inside the target).
- `zig build gates -j2` green.

**What I learned**

- The checker does not answer a derived `==` impure when its row calls
  a field type's impure `eq`. Two effects on master: `--release` drops
  an unread `same = Pair … == …` that logs in development, and a
  prerendered view whose derived `==` reads the clock builds, with the
  build machine's answer in the page. A direct `Meter ==` and
  `List Meter ==` are correct. Opened #2115.
- In a `browser-inline` view, a `let` whose right-hand side may have an
  effect is refused ("NOT IMPLEMENTED YET", `browser-direct.md` §5.4).
  So a fixture keeps an impure comparison inside the markup hole.
- A heavy-run job that waits for a slot compiles the tree as it is when
  it starts, not when it is queued. Do not edit `src/` while a build of
  a "before" binary waits.
