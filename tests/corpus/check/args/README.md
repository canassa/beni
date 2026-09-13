# `check/args` — the missing-argument suite

`fast-compiler.md` §9.3 keeps currying **on the condition** that a localised
`TOO FEW ARGS` diagnostic lands convincingly on real mistakes. That is the
only mitigation the decision rests on, so it is proven here rather than
assumed, and it gets a corpus kind of its own so its size and its pass rate
are visible on their own rather than buried in `check/bad`.

Every fixture is a mistake someone actually makes:

* forgetting the model in an `update`/`view` call (the TEA papercut),
* a `|>` pipeline whose last stage still needs its subject,
* `List.map f` handed onward where the list was wanted,
* a partially applied constructor standing where a value is,
* a lambda with too few parameters given to `foldl`,
* an argument order swap that only shows up as the wrong thing in the first
  position,
* a record accessor where a function of two arguments was needed,
* `Dict`/`Set` constructors whose explicit comparator (fast-compiler.md §3.1
  point 4) was left out,
* the mirrors: one argument too many, and a value applied as a function.

Each `.beni` carries its intent in a comment and each `.diag` is the WHOLE
diagnostic — code, severity, span, title and prose. A fixture without a
`.diag` is a failure, not a pass (the Elm gap, mechanically closed).

The review of these messages, fixture by fixture, is what §9.3's revisit
decision is made against.
