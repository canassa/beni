## 2026-11-09 01:51 CET — A derived row's positions reach the site's effect

**What I did**

- Fixed #2115. A `==`, `≠` or order operator whose derived row calls an impure `eq` or
  `compare` is now impure at its site.
- In-module: `Module.solveEffects` adds an edge from each answered position of P5's eager row
  to the use's method type.
- Cross-module: the row's bit is published as `Interface.Derived.impure`
  (`iface_bytes` 23 → 24). An importer seeds the use's method type with it.
- Fixtures: `run/DerivedEqImpureField` (seven paths) and
  `build/bad/prerender/DerivedEqImpure`.
- Docs: `checker-v2.md` §26 amendment of 2026-11-09, and the #2115 sentence of
  `prerender.md` §3.1.

**What I learned**

- A derived answer's arguments are only its context entries. A type with no parameters has
  none, so every effect of its row lives in the row's body wanteds, which P5 resolves before
  the effect solve.
- `build/bad/prerender/` builds with `--platform=browser-inline`. A build with
  `--platform=browser-tea` accepts every prerender fixture, so it proves nothing.
