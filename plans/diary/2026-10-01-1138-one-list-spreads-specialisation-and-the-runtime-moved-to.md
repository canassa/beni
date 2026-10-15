## 2026-10-01 11:38 CEST — one List, spreads, specialisation, and the runtime moved to beni

**What I did**
- Sequences: measured every candidate in one batch (research 46); the owner chose one
  array-backed `List` (E1tp, with a claimable head and tail), `::` replaced by bracket and
  spread syntax, `++` routed to `List.append`. Core List rewritten, scalar views for
  `[ x, ...rest ]` walks, append and filter brought back to or under the cons list's speed.
- Compiler: arithmetic as operators, statements for discarded values, in-place loops,
  `Js` intrinsics with `Js.Ref`, `Js.each`, `Js.construct`, `Js.setAt`, `Js.finally`;
  runtime modules in beni; whole-program specialisation (constant arguments, constant lets,
  never-read fields, one-literal and never-null fields, an inliner after the facts); scope-aware
  name reuse; `sync` in platform signatures.
- Runtime: slot/mount, holes, events, `Browser.program`, keyed lists, class/style and the
  effects host loop moved from runtime.js to beni, each step no larger and no slower. Empty page
  978 → 605 brotli; table app 6 139 → 5 723; beni leads Solid 1 on all nine operations.
- A hand-minify skill and a study that took the empty page to 157 bytes by hand; its ledger is
  the compiler's to-do list (escape analysis, constant propagation through objects).

**What I learned**
- Benchmarking array types on cons-shaped code was the wrong question; the owner's "change the
  code, not the data structure" changed the outcome.
- Unique short names can make code larger after brotli: the beni list code was 469 raw bytes
  smaller and 150–220 brotli bytes larger until names were reused across scopes.
- A faster primitive in isolation (`createComment`) can be slower in context (document adoption
  of cloned rows); measure in the page.
- Long benchmark sweeps waste the owner's time; every run now has a 5-minute budget.
