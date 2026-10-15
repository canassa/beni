## 2026-10-08 21:05 CEST — Write-set spec: the adversarial review's holes closed

**What I did**
- Amended `docs/design/write-sets.md` in place for PR #18's soundness review (branch
  `write-sets-spec`, not pushed). A1–A6: negation facts only from single-path,
  irrefutable-below patterns; a two-path or refutable pattern contributes none; conflict uses a
  may-prefix order in which `[*]` and `[κ]` coincide and index symbols alias unless both are
  distinct literals; `Same` of a path with `[*]`/`[?]` is never identity and the callback
  element is its own root; an `Alt` carries its scrutinee and anchors to it and to its facts'
  paths. B1–B7: roots unique per function and `inst` descends into closures; non-path bases at
  instantiation; unrecognised programs are `value ρ` and every hole dynamic; the k-cut never
  truncates a `Same`; R3 bakes only a hole that is exactly a path with a string-literal `init`;
  the `[*]`-node conflict clause withdrawn; element sub-writes survive tag joins. C1–C5:
  hash-consed terms, `diff` memoised on `(node, p, Γ)`, a work budget W per summary and per
  key, S on every term, a keyed `Alt` exempt from the width cap (Conduit's `ArticlePage` has
  17 constructors and would have hit the old cliff), I = 4, the "linear" claim replaced by a
  bound. §5.2 now carries the negation lemma, the conflict lemma and the singleton condition;
  §8.3 lists the review's eleven fixtures, one of them a `test-pending-perf` scenario. The gate's
  expected Conduit figure is unchanged (about 100 of 101), re-checked rule by rule in §8.2.
- `zig build gates` green (docs only).

**What I learned**
- Per-component negation on a tuple scrutinee is a disjunction, and a Γ of conjunctive tag
  facts cannot hold it; the only sound negation comes from a pattern that can fail for exactly
  one reason.
- Capping the width of an `Alt` was the wrong knob twice: it bounded no work (chains of `if`s
  nest instead of widening) and it punished exactly the shape nested dispatch needs (a `case`
  on a message with many constructors). Cap the work; let a `case` on a path be as wide as its
  type.
- "Linear in the program" is a claim about inputs that hit no cap; a pass with caps should
  state the bound the caps give and measure the rest.
