## 2026-10-09 01:25 CEST — The direct platform's design: the fourth review's four items

**What I did**
- Revised `docs/design/browser-direct.md` for the fourth review of PR #24: an arm mounted
  earlier in the same dispatch is not visited again and the live nested arms are read after (b)
  (`SwapAndShow`); `swap` has a data guard, `get(xs, κ₁) !== insts[κ₁].it`, so it is idempotent;
  every slot, module-level ones included, is declared `= unset` (`UnitHoles`, a `⊤` hole and a
  `Maybe ⊤` scrutinee under `--release`); verify compares a derived list's elements
  structurally and keeps identity only for `insts[i].it` (`VerifyQuiet` gains a derived list
  of fresh records); a derived value lives in the innermost arm enclosing every reader, else at
  top level. The reviewer finds no further wrong-page or crash case in the per-arm ordering.
- Gates green (docs only).

**What I learned**
- A mount built from the new model and a script written for the old shape are two ways to
  arrive at the same page; running both is the error, and a data guard on every script is the
  cheap half of the fix, skipping fresh arms the other.
- "Declared unset" and "reset to unset" are two rules, and a sentinel chosen for teardown is
  worthless if first mount starts from `undefined`.
