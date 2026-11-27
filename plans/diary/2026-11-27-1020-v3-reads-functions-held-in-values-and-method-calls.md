## 2026-11-27 10:20 CET — v3 reads functions held in values, answered closures and method calls

**What I did**

- Kernel §6 rule 2 gets four paragraphs (#2657): *A function held in a value*, *What the holder
  hands back*, *A function a body answers*, *A field called as a method*.
- A call of a function read below a parameter or a capture (a list element, a field) stays unknown
  code, but its answer is `held(i, e)`, which the caller reads off the functions its argument holds
  there (a list literal's elements, a construction's parts). A fold callback that answers what such
  a function answers asks the caller that the answer be its own (`Fn.ans_own`).
- A body whose result is a function names the closures it answers (`Contract.answers`), and a
  caller rebuilds them over its arguments; a group round of no answer runs no code (`neverVal`).
- `r.f a` is `r.f(a)` in JavaScript, so `r` is `this`. Where every function at `r.f` is beni code
  the record is no operand; below a parameter the caller decides (`Fn.receiver`), and at an entry
  the model's functions must be produced as beni code (`Contract.fn_known`). The lowering is not
  changed.
- Accepted now: `FunctionElements`, `ReturnedValidator`, `ModelCallback`. No other page of
  `browser/inline` moved. Three live pins and one check test refuse more of their unsafe writes.
- The adversarial reviewer found two fault classes, fixed with fixtures
  (`run/HeldAnswerStoredInRefLive`, `browser/inline/WordedForeignModelMethodLive`): a held function
  that keeps the new list it answers in a cell, and a worded platform foreign called as a method.

**What I learned**

- Every function that goes into a value met the `top` use there, so a held function needs no
  judgment of its own at the caller, only its answer. What its run stores is not judged anywhere,
  so its new cell is the caller's only where `freshOwn` holds.
- `jsCode` is false for a worded foreign. A rule about "beni code" must ask the declaration's kind.
- A group's rounds need a bottom for "answers no function" that is not "no fact", or the first
  round's unknown answer stays for ever.
