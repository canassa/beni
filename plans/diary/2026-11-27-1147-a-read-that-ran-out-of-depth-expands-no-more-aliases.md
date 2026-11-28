## 2026-11-27 11:47 CET — a read that ran out of depth expands no more aliases

**What I did**

- Reproduced issue #2124 on master `a46fc93170`. The diamond `A{i} a =
  A{i-1} (A{i-1} a)` checks in 0.1 s at 260 levels and does not end in 20 s
  at 300 levels. That is true for a private constructor that nothing calls,
  for a public constructor and for an annotation.
- Found the exact cost. The body of an inner application is two reader
  levels below its alias, and the body of an outer one is one level below.
  So a path of the diamond fits only after `2n − 510` outer steps. An
  expansion that ran out of depth is not shared by its shown arguments, so
  each level above that point expands its body two times: about
  `2^(2n − 510)` expansions.
- Wrote the rule first (`checker-v2.md` §7.4, *Amended 2026-11-27*): after
  a read runs out of depth, it expands no alias. The fix is one condition
  in `Types.Builder.apply`: with `too_deep` set, an alias gets an `err`
  expansion, the variable a shallow read makes. The arity test, the
  key-kind checks and the two memo entries come first and do not change.
- Compared master with the fix on 28 forms at 8 depths from 250 to 262
  (exit code, JSON diagnostics, `dump --stage=interface`, `dump
  --stage=types`). 179 of the 224 runs are equal byte for byte. The other
  45 lose exactly one mismatch against an alias that the reader met after
  it ran out of depth. No run has a different `nesting_too_deep`. At 300
  and 600 levels each form ends.
- Added `check/bad/AliasDiamondTooDeep` and
  `check/good/AliasDiamondTooDeepUnused`, both 300 levels deep. With the
  condition set back, both give "test timed out". Added the `test-perf`
  scenario "checking a diamond of aliases deeper than the reader's bound is
  linear in its depth": 31.0 M / 35.7 M instructions at 300 / 600 levels.
- Opened #2716: a diamond over an alias whose body has a key-kind issue is
  exponential too (16 levels take 9 s in Debug). It is the other half of
  the same "not clean" rule, and this change does not touch it.
- Opened #2721: an importer of a value whose type is an alias DAG with
  different arguments (`D{i} a = D{i-1} a × D{i-1} (List a)`) checks in
  about 2^n, and `dump --stage=interface` does too. The declaring module
  checks in linear time. It is on master, and this change does not touch
  it.
- Asked the owner one question on the dashboard: keep the readable part of
  a too-deep type (this change), or make the whole type an error.

**What I learned**

- The issue proposed to drop a too-deep read "as a whole". But the readable
  part of such a type is in use today: `f : A260 Int → Int` with the body
  `"s"` gives `nesting_too_deep` and a type mismatch. A stop at the top of
  `Builder.read` removes those messages. A stop at the expansion point
  keeps them. Probe what a poisoned value feeds before you choose where to
  stop.
- `too_deep` is a flag of one `Builder` object, and `aliasBody` makes a new
  builder for each body. The flag reaches the caller only when the body
  returns. That is enough for the stop, because a reader on the stack runs
  again only after its body returned.
- The exact memo entry (the alias and the roots of all its arguments) is
  made for an expansion that is not clean too. Only the entry by shown
  arguments needs a clean expansion. So a DAG of nullary aliases or of
  tuples was never exponential past the bound, and the diamond with a new
  root at each level was.
- `beni dump` does not take `--no-cache`. My first comparison of the
  interface dumps compared two usage errors (exit 2) and said "equal".
  Check the exit code of each command of a differential check, not only
  the bytes.
- A corpus fixture cannot show a hang by a golden. The proof is the hang
  guard: "test timed out" names the fixture.
