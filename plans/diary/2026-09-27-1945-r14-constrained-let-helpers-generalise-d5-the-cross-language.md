## 2026-09-27 — R14: constrained `let` helpers generalise (D5); the cross-language comparison

**What I did**

- D5 landed: a `let` function binding generalises over the requirements everything it reaches
  owns, and takes evidence parameters (`$l<inst>$<k>`, the `lets` column of the dispatch table),
  so `let same a b = a == b` works at two types, also inside lambdas and branches. Kept
  monomorphic: a `let` whose variables carry only dot-calls' own requirements (the owner's
  2026-09-26 decision), value and pattern bindings (a value restriction I confirmed: it keeps
  `let` bindings evaluated once), and a helper over the 64-requirement cap (held with a hint,
  never refused). CK-02's outer-receiver program stays refused. The review found both rules
  wrong in the first cut (lets below a lambda never generalised; over-cap helpers refused);
  fixed with fixtures.
- `bench/compare/` (`f38eb30`): three pure-logic programs ported to beni, Elm, Gleam, Roc and
  PureScript, duplicated into N modules, checked cold on one core; cost per copy: beni 3.2 ms,
  Gleam 12.4, Elm 14.0, Roc 24.0, PureScript ~1 200 (its exhaustiveness checker on one deep
  pattern). Per token: Gleam 2.5×, Elm 4.3×, Roc 5.7× beni's time.
- My mistake: that commit first swept in two of R14's staged fixture moves; I redid it within a
  minute with `git commit -- bench/compare`. Use path-limited commits while an agent has staged
  work.
