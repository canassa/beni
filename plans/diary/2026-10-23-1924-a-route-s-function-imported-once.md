## 2026-10-23 19:24 CEST — a route's function imported once (#897)

**What I did.** While working on #896 I built S1's `unique-components` programs in development
mode and found that master's `Main.mjs` would not load at N ≥ 16:
`import { …, Widget$W1$replace, Widget$W1$replace, … }`, a SyntaxError. A route's row
(`Lower.routeRowConst`) asks for the widget's `replace` by its base name. The ordinary call asks for
it by its interface row. `needName` keeps both, and `importsFor` wrote one specifier per entry. It now
writes one per name. New page `browser/inline/PartialRoutes`, where `W1` is routed and `W2` is not.
It failed to load in development before the fix.

**What I learned.** Release output hoists every module into one file and has no imports, so a defect
in development imports is invisible to S1's measurements and to every `emit/release` golden. Only a
page fixture, which builds both modes, catches it. It appears only when one program has a route and a
non-route call of the same function, which none of #895's pages had.
