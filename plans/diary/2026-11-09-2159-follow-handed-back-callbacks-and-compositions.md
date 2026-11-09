## 2026-11-09 21:59 CET — Follow handed-back callbacks and compositions (#2395, #2394)

**What I did**

- #2395: a closure a walked call hands back (`ident f = f`, a record field, a closure the callee returns) was escaped at
  that call by `Closures.handedBack`, so `ident λa → …` and every fold over `comp f g = λx a → g x (f x a)` were refused
  `unknown`. The frame now follows a value that is one of its closures by every arrival through callees' results
  (`FnSite.one`, in `Walk.valueCall` through `settledFn` and in `Eval.labelsOf`), and escapes the closure where such a
  result escapes or is returned (`FnSite.escapedSites`). A known code's answer to a callee still escapes.
- `FedCall.at` now reads a composition's answer through the known codes its labels run (`FedThrough`), with a keeps check
  over every code the run hands `k` to.
- The first review found nothing; my own s6m check found a trap the hand-back escape had hidden: a capture written through
  a label a known code applies, in a code run twice (`two (mk [ 1 ] push1)`, `mk y g = λ⊤ → g y`). The same shape with a
  local closure (`two λ⊤ → f y`) trapped on master too. `CaptureRuns.many` follows an own-parameter write outward and
  refuses it `once` where it reaches a capture of a code run more than once.
- #2394: stopped at a spec decision. Its cause is §2.11.3's own rule ("a returned writer stays refused at the return"),
  not an indexing fault. The recommendation (a carried-writer invariant beside `NeedCarry`) is on the issue.
- Filed #2407: a let-bound lambda handed through a composition to a fold is still refused (its nested virtual call is
  placed at the lambda's own generalised type).

**What I learned**

- The hand-back escape was a catch-all that hid an older hole (a capture written through an applied label). Removing a
  conservative rule needs a sweep of the old refusals, not only of the new acceptances: the s6m lists found it in minutes.
- A composed answer's slots are its inner code's own type's; a `written` filter in the outer coordinates must not be
  carried into them.
