## 2026-10-24 00:29 CEST — roots through one table, and slices inside the model record

**What I did.** Two items of #916, from `plans/s1-output-comparison-2026-10-23.md` §4.
- **The wiring table.** Roots side by side in placement order, whose factories take no handler
  and fill their own rows, are one run. The mount writes one row `[factory, holder…]` per root
  and one call of the runtime's new `roots(rows, elements, from, table, at)`. When the roots are
  element children of one parent, in order, `elements` is the parent's `children`, and no
  `part(E[n])` lookup is written for them. Otherwise it is an array of the roots' top elements.
  A root that takes a handler, or fills no row, is called by name and ends the run. New page and
  golden: `RootRuns` (two children runs, one from the fourth child, and a run read by place).
  Spec: `browser-inline.md` §8.4, amended 2026-10-24.
- **Slice literals.** `init`'s record pins each slice to a `const`, because the record's keys are
  sorted. Opt's `pureValue` now takes an object literal with plain keys and an array literal, so
  each pinned literal moves into the record. Spec: `backend.md` §9 item 1, amended 2026-10-24.

S1 seed 1, one-file brotli of my builds (not the manager's fit), against master `da237ef10`:
64→256 slope 187.8 → 180.7, 16→64 223.0 → 212.9; N = 1 1 617 → 1 621 (+4: the model's copy
`d={…},f=d` became `f={…}`, 4 B fewer raw, and brotli prices the new names higher). The release
goldens the Opt change moved fell by 985 B in total; `CounterLocal` grew 6, `ReaderBeforeWriter` 5
and `ArmSingle` 1. `./rr check` passed 24/24.

**What I learned.** The comparison's hand edit used the dashboard's children, and that is
2 B per widget better than an index per row. But one root with no row ended the run at n256, and
the run after it fell back to indexes. A start offset into `children` fixed that. A runtime
function written in beni over `Js` cannot spread arguments without `Function.prototype.apply`, so
`roots` is `a[0].apply(null,[part(el)].concat(a.slice(1),[row,table]))`. When Opt inlines it
into its one call, the constant offsets print as `0+d`. `pureValue` treated a fresh object as
impure only because no case named it.
