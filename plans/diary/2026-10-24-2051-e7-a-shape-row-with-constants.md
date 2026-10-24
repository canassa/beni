## 2026-10-24 20:51 CEST — E7: a shape row with constants

**What I did**

- After the step-B entry: an independent review of #948 found two real
  bugs. A computed write into a fused site's binding was accepted, and a
  bound argument's effect was dropped (`run/CaseAcrossArgEffect`). Both are
  fixed, and the PR is merged.
- Built E7 (#946) as `browser-inline.md` §8.4's amendment. A route's
  `case Json.decodeValue x of Ok new → { … }; Err _ → old`, whose record
  is `new`'s same-named fields and constants, holds the run's shape and a
  record of the constants. The `…ShapedConst` loaders write them with
  `Object.assign(old, next, constants)`. Writes recognises the form,
  `Emit.caseRowFits` checks the codec's fields and the constants' kinds,
  and Lower writes the constants in the program's module.
- S1, one-file brotli, seeds 1–3: N = 64 −141 / −160 / −188 B, N = 256
  −814 / −470 / −940 B. N = 1 and N = 16 are unchanged.
- New fixtures `emit/release/inline/ShapeConstants` and
  `browser/inline/ShapeConstants`. The expected transcript came from the
  compiler before the change.

**What I learned**

- A dev build prints all of `Inline.beni`. A new `pub` loader therefore
  changes the run hash of every `browser/inline` page, and
  `references/api-browser-inline.md` must be regenerated.
- A constant can be written in the program's module only when its value
  can be named there. Literals and other modules' nullary constructors
  can (`putNullary` with an interface index). The function module's own
  constructors are not taken, because a BIR constructor index is not an
  interface index.
