## 2026-11-03 04:02 CET — own2: List.update's callback label, and the fold walls

**What I did**
- #1752: `focus`'s `once taken stored` callback row is read as a label (called once, supplied `π1[*]`, answer at
  `[*]`). Each write at `s` relies at the caller on `π1{[*]*~, [*]·s}`; a mark in the label's origin keeps that
  through a pass. Five of lane 7's eleven accepted→refused positions are accepted again. `Rows`' environment
  moved to `RowEnv` (L5) to stay in the size target. Fixtures `run/SanitiserListUpdate`, `…Shared`.
- #1753 (found on the way): a nested virtual call's write panicked on the walked-call index. Fixed, pinned by
  `run/SanitiserNestedCallbackWrite`.
- #1713 fold groups: a sound `Fed` rule for (a)/(d) gains five positions but pushes `SubscriptionTapFold`
  `build` over its limit; not landed (`slot-build/p8/fed-other-arg.patch`). (b)/(c) diagnosed to
  `Entries.atomTwice` in `Distinct` (other lanes' files). Schema-member reasoning posted. #1756 filed.

**What I learned**
- Each part of the `taken` rule was needed. With no condition, `[ a, a ]` gave a stale read. With the
  condition but no mark, a helper that passed the callback on gave one. With `[*]*` plain, rows that share
  a key were refused.
- Seeing a callee's write moves its refusal to the callers, and the a2r count by demand text rises (279 →
  330). The program-level verdicts are mostly unchanged: v1 refuses the same programs at the callback.
- A declaration at 99.96 % of its growth allowance turns any precision gain into a new limit line. Check the
  `account` lines of the roots the change touches before measuring the gain.
