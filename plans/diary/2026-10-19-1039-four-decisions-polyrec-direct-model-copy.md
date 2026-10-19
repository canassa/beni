## 2026-10-19 10:39 CEST — four decisions: polymorphic recursion, browser-direct, the model, the copy cut

**What I did**

I recorded the owner's answers to the four open questions and set the work moving.

1. **Polymorphic recursion (#286): (a), the composed-path fold.** Removing `k` is the point. Under the strict rule, (b) would make `pushArg` a build error forever. A summary-format change is fine.
   - It is specified first, then measured on the differential corpus against master with `k`.
   - The owner wants the recovered count, not "recovers everything".
   - The Lean oracle (#386) follows in parallel and doesn't gate.
2. **browser-direct is retired** (https://github.com/canassa/beni/issues/423), with git history as the reference. The owned slot for driver state is not built; it is noted in the issue as the design for a future platform with driver state. A planning pass is inventorying the fixtures, so that no general coverage is lost.
3. **The cost model replaces T.** T re-tunes after every cut (4 → 25), and its worst generator miss is 918 B. The free-fit model missed twice as often as T on the research apps, so its five coefficients are derived from measured per-piece costs instead. A corpus test reports the choice's residual, so drift is caught.
4. **The copy cut lands, after the +245 B of fixed cost is explained.** A shared copy loop is tens of bytes, so the rest is broken down: the shape interpreter, kept names, and the choice flipping at small N. Items 3 and 4 are measured together, with the N=1 total reported beside the fit. Fixed cost going to about 1.2× tea-inline is to be visible.

**Since the last entry**
- **Merged:**
  - #390 and #398 (S1: no every-binding pass; values at their write);
  - #393 (the level marker, closing #379);
  - #403 (F1 under the marker);
  - #407 (ApiItems' grant, #406);
  - #408, #411 and #415 (#315's R2c, R3 and R2d).
- **Open:** #409 (the bound argument), #421 (records' exclusive contents), and #386 (the Lean oracle).
- #421's read-only review found the record domain unsound for `foreign` types (`Js.Value`) and at the entry. The fix is in progress, and #419 waits behind it.

**What I learned**
- **Read-only reviewers that build programs found unsound acceptances in nearly every ownership PR** (#388, #391, #393, #403, #408, #415, #421). Every slice needs one; @claude's static read caught few of them.
