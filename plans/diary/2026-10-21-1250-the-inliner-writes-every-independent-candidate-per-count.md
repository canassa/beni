## 2026-10-21 12:50 CEST — the inliner writes every independent candidate per count

**What I did.** Issue #576: `Spec.inlineOnce` wrote one called-once function per count of the
whole program and stopped at 256 a pass (`max_inlines`). Now one count (`inlineBatch`) writes every
candidate no earlier write of the same count touched (a call that stood in a body just copied, or
in a top-level statement a write replaced, waits), a declined call is not asked again while both
its modules keep their version, and `inlineOnce` and `fuseCalls` are bounded by nodes copied
(`copyLimit`, four times the program) instead of a count. `nameRead` walks again only for names
a write dropped. Four new `--self-profile` counters (`spec_inline_scans`, `spec_inlined`,
`spec_inline_waits`, `spec_inline_refusals_kept`) and three `build_test` cases. The skill's API
reference was stale on master (WebSocket landed without `zig build skill-api`); regenerated here.

**What I learned.** `inlineOnce` 39.6 → 15.6 ms at N = 64, 39.7 → 15.2 on `nowd`, 4.2 → 2.7 at
N = 16; whole builds −18, −44 and −2 ms. All 601 functions go in the first count. But the pass
count did not fall on the dashboard: passes 2 and 3 are slice 9's `constructors` refolding a
`return f(…, g(…))` in statements it folded the pass before (#589), so the issue's premise that
the cap is why the program needs three passes held only for the inliner's share. One output moved,
`browser/tea/DefectInFiber` release (+2 raw, −3 brotli): one at a time, a declined `Cmd.batch`
was retried right after the next write in its statement; in a count, `List.map`'s helper is
written into `batch` first, which then reads its parameter five times and is declined. No
`emit/` golden moved and `bench/corpus` stays at 19 280 brotli bytes.
