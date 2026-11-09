## 2026-11-09 20:56 CET — read a join's level paths below it (#2354)

**What I did.** Lane s6w closed #2354, the last class-A hole of the `⟲` audit. The minimised
reproducer is a four-head family (`A0`/`A3`/`A2`/`A1`, `A30 (A0 (List a))`) where a walker `w0`
writes every list below `#A03.0#A32.0#A20.0#A01.0#A11.0#A12.0⟲#L2.0`. That `⟲` is a join: `A1`
returned above `A2`'s first return, so `A2`'s levels there are several paths. `hg` says `k` at one
of them, `#A03.0#A32.0#A20.0⟲#A03.0#A32.0#L2.0`. The deep read is held whole as the symbol `↓p`
with the join's own words (a list at the payload absorbs every step, so `Subtree.below` never
writes the slots out), and `BelowAnchors.of` read `p` and its folds by their words, never a join's
level paths. `Subtree.anchors` did. Now `BelowAnchors.of` takes every name of `p` and of each
fold above it, and the folds of each name of `p` that no anchor already covers. Fixtures
`run/SanitiserFamilyJoinBelow` and its twin, mutation `below_join_one_name`, §2.1 amendment, O6 row.

**What I learned.** The issue's reading (`hg`'s keys at a join `#1.0#0.0#1.0⟲`) was off: that
`⟲` is a sealed first return's fold, one level path. The join was on the walker's side, in the
symbol. The regular twin was refused only because few places below a list of `Int` hold objects,
so `below` wrote the slots out by `canon`. Taking `LevelTargets.of` again on a level path that a
fold already covers read high folds whole and pushed three generated programs from SAME to LIMIT
(`rn` 30k → 153k); since `LevelTargets.of` closes over its folds, skipping covered names costs
nothing and they are SAME again. Reviewer: `expandLevels` is not idempotent (#2404); the folds'
level-path loop has no pin (#2405).
