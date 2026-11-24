## 2026-11-24 02:41 CET — a release call that writes inside its callee is kept

**What I did**

- #2642. Under `--release` on `browser-inline`, `( said model "later", Cmd.perform … )` lost
  the call of `said`, which writes the model in place. The platform keeps the model object
  (`programModelKept`), so it reads nothing back from the pair. Scalar replacement
  (`Spec.scalarReplace`) split the pair into one binding per slot. `Opt` then dropped the
  model's slot, which nothing read, as a pure value.
- A `call` node now has a `stores` bit, beside `host`. `Lower` sets it when the ownership table
  has an accepted demand at the call (a callee that writes a record argument). `holdsStore`
  answers true for it, so `Opt` never drops it and moves it past names and literals alone.
  `Spec` copies keep the bit, and `pureCall` refuses it.
- The reviewer broke the first version with `apply f m s = f m s`: `Spec.inlineSmallAt`
  copied `f(m, s)` with `said` in `f`'s place, and that call had no demand of its own. A call
  whose function is not known where it is written (a parameter, a pattern's variable, a field,
  an evidence parameter) is now marked too, in every module.
- Page `browser/inline/ReleaseCalleeWrite`: nine shapes, every one lost its write in release
  before the fix. Golden `emit/release/inline/ReleaseCalleeWrite`. Spec: `ownership-checker.md`
  §31.10, amended 2026-11-24; `backend.md` §9 item 1.

**What I learned**

- Value semantics alone cannot see the drop: every later read of the old version is hoisted
  before the call. Only a lowering that keeps the object across the write sees it. Under
  `--ownership=v2` and `v3` the platform stores the model back, so the page is right there.
- Sizes over `bench/size.mjs` (1 134 programs): release gross brotli 2 071 222 → 2 071 261
  (+39 B), six programs grow by 1 to 23 B, empty pages unchanged, development unchanged.
