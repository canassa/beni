## 2026-10-22 20:27 CEST — the structural passes before the first solve

**What I did**

- Built #781, option 1 of #464. `Spec.structureFirst` runs small functions, functions called once, constructor folding, scalar replacement and `tidy` before the first solve. No fact exists then: `memo` is ⊤, `pts.ok` is false, and a name counts as assigned when any `assign_stmt` names it. N = 64, nowd and the 100k build then solve once. Instructions drop 19.9%, 19.6% and 14.3%, and the output is byte-identical.
- Added the projection to slice 8's copy: `p.k`, where `p`'s argument is an inert object literal, becomes `k`'s value. Keys are compared by property id. It recovers what the second solve's chain read used to fold (`{ step: z => z + 1 }.step(1)` is `2`), and `emit/release/app/ProjectLiteralField` pins it.
- The corpus total is −39 B. 15 programs grow by 349 B in all, in three groups, now #788, #789 and #790.

**What I learned**

- `--self-profile` costs about 100M instructions on the 100k build. I first read that as a 4% regression from the projection, but the projection costs nothing. Count instructions without the profile, and read counters from a second, profiled run.
- A key name JavaScript can see and a beni field name can differ as `JsIr.Name` (tag 0 and tag `field`) and still be one property. Compare by `Pts.propId`.
- The second solve absorbed two things: what the structural pass exposed, and the first rewrite's cascades (keys, bindings and parameters whose last read the rewrite took). Removing it exposes the second kind. Those cascades are #788 and #789.
