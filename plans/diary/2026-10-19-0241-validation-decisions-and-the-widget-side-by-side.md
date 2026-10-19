## 2026-10-19 02:41 CEST — validation decisions, and one widget side by side

**What I did**

**Merged**
- #380, #379's red fixture.
- #381, #315's R1: `Record.copy`, update bases and `{ r | }`.
- #384 and #387: the shared validator, chosen by a run count. T went from 19 to 4. #387 also closes #368.
- #388, #315's R2a: record cells.

**Opened**
- #390: no write pass covers every binding. It replaces #389, because updating #389 would have needed a force push.
- #391: #315's R2b.
- #393: the level marker, closing #379. Its read-only review found that a call can merge two of the callee's places into one level cell. That is unsound, and it is being fixed.
- #386: the Lean oracle for the marker, kept up to date.

**The owner's decisions, 2026-10-19**
1. **`Maybe` unboxing is parked.** The draft is on branch `spec-maybe-unboxed` (`d81125bff`, `backend.md` §4). It saves about 6 B per `Maybe` field, about 1.5 B per widget. Revisit it when CPU is measured, since its gain there is allocation, not bytes.
2. **The validation cut is the copy version, not adoption.** The field names are kept, the shape has no `make` arrow, and one generic loop copies the object. Adoption would have changed behaviour in four ways: getters, host mutation, extra or inherited keys, and in-place writes into a host object. The estimate is about −6 B per widget.
3. **`Json.trust`: not now.** Validation stays mandatory for S1. S1 is judged on the checked number, with the validation line beside the fit as the cost of the typed edge. Whether the language gets a named unchecked read is a separate language decision, taken later for a real program and not for a cap.
4. **The closure headers wait for #315.**
5. **Big-component stays in S1's criterion.** Same-module view helpers called once from `view` are lifted like pieces. `case` in markup is the eager `when`. The "no markup value" limit narrows to markup held in data or chosen at run time.
6. **The one-string shape is dropped.** It measured +150 B fixed and no saving per widget.

**Measured**
- **Validation, with the compiler-constant stub:** 459 + 29.6 B per widget on master. The reader for each widget's `Model` is 26.4 of that. The earlier 45 included the dispatch arms, which are app code.
- **One widget against tea-inline, on cut 7:** beni-inline is 288 B per widget, tea-inline 173. Of the 115 B gap, about 48 B is owned by planned work. New owners:
  - one pass call per handler, about 27 B;
  - cut 6 re-scoped, so each handler is written at its wiring;
  - small items: a lone number through a template, kept `let`s, the per-widget `init`.

**What I learned**
- **Every PR's read-only reviewer that ran programs found something** the @claude review didn't: #388's escapes, #389's platform-layer program, #390's directory-named platform, and #393's merged places. Two reviews per PR is earning its cost.
- **A validation stub has to remove only validation.** The first stub also removed the dispatch arms and over-counted by about 15 B per widget.
