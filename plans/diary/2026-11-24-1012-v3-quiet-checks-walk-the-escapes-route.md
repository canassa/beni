## 2026-11-24 10:12 CET — v3: quiet checks walk the escape's route (#2651)

**What I did**

- Fix lane fix205: the #2651 fix alone on `ownership-v2-design-review`, without master. The merge with
  master waits for the owner on #2657 (v1 refuses four of master's inline pages, because the branch's
  foreign `Dict` hides from v1 that a `Dict String String` holds no list).
- `checkMadeEscaped` re-read a `Js.Value`'s cells whole, at a join's place, where the escape it
  checks read them arm by arm. In a check that counts no work it then built a meeting of two arms
  (`Frame.ctxs`) or a map of two layouts (`Loc.cover`), and the safe build panicked. Master's
  `browser-inline` code reaches it in every build. Now the check walks by the escape's route
  (`madeLeaves`), and a quiet walk tags no context and keeps no `whole_at` copy. Kernel §9.
- `run/JsJoinAtVar` and `run/JsJoinOfList` panic on 9098f84085; the first commit fixes the first,
  the second commit both. Gates green; ledger 309 of 319; `runon.` pages 192, 0 faults. On the
  merged tree: 136 966 sweep programs dump-diffed with 0 changes, 2 553 roots with 0 accepted →
  refused, 0 panics on 719 inline, tea and example programs.

**What I learned**

- A check that reads again what a step read must walk the same route, or it builds what the step
  never built. The first fix closed one effect (contexts); a reviewer found a second (the location
  table); the route was the cause.
