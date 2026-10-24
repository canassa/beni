## 2026-10-24 19:50 CEST — Step B: a rest that makes a function

**What I did**

- Built step B of the S1 hand-minify plan (#946) as six extensions of
  `backend.md` §9's *Slice 9 across a call*, amended first: a rest may hold
  a plain arrow (named afresh in each copy; it may not read `x`, and reads an
  alias only through a property); a computed read is a property read; an
  argument that is not an atom is bound first; each copy of the rest is
  bounded by 96 units, not the rest as written; what follows a decided jump
  is not copied and a made value is counted on the copy; `declaredTag` asks
  `unknown_any` of an escaped site only. Slice 9's `c ? A : B` fold takes
  arrows in `R` too.
- The push dispatcher of `browser-inline` now holds the event, snapshot and
  widgets workers' code, with no sentinel: N = 1 −77 / −110 / −88 B, N = 16
  −112 / −100 / −99 B (one-file brotli, seeds 1–3).
- Found and fixed #947: the hoisted release build panicked when a module met
  another module's shared nullary constant before the first one was
  numbered (`browser/tea/PointerSteer`).
- New fixtures `emit/release/app/CaseAcrossClosure` and
  `run/CaseAcrossClosure`; 12 `emit/release` goldens fail on master.

**What I learned**

- The 96-unit bound on the rest was the wall: a dispatcher's rest holds
  every arm, but each constructor's `return` gets one arm after the copy
  decides the tag test. Bounding each copy keeps the bound's purpose.
- The size proxy counted dead statements after a decided `return`; once they
  went, `app/CaseAcrossCall`'s `command` fused as its intent comment says.
- `Spec`'s IR at fuse time still has the schema workers' `c.reject`,
  `c.all` and `d` parameters; facts fold them only in later rounds, so a
  function can fuse in a later pass that failed in an earlier one.
