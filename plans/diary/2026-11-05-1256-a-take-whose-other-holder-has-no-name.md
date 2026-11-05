## 2026-11-05 12:56 CET — A take whose other holder has no name

**What I did.** Answered the adversarial review of #1980, which found five ways an owned take trapped where master refused. Fixed all five regressions and pinned them in `run/RefTakeUnseenHolder`. A take is now owned only for contents of one object, and §2.13.7's soundness argument is rewritten. Filed #1984 for the two-slot hole, which traps on master too.

**What I learned.**
- My first soundness argument in §2.13.7 was wrong in three places, and my own 23 probes passed anyway. The reviewer's 228 probes found the holes in about 16 minutes, so the sanitiser needs someone else's programs.
- Giving a value more trust exposes holes that a pessimistic `⊤` used to hide: three of the five findings were master defects. A precision gain needs its own hole hunt, not only its own red twins.
- With no slot state the honest rule is narrow: one object cannot alias itself. That keeps the workers' `Ref (Maybe buffer)` take, and `Ref (List (List Int))` waits for the `contents` relation.
- `Ref.make Nothing` then a take: a helper's `take` looks sound in the helper, and only the caller's empty view is wrong. An empty position behind a `◆` has to be unknown, not nothing.
- A `Slots` set may be symbolic. Use `elems` with `isNot`, as `paramEffects` does; `items` asserts, and only the ledger's corpus roots showed it.
