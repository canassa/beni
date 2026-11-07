## 2026-10-31 19:30 CET — own2 4e: stable images built

**What I did**

- Built §2.3's stable images in a new file, `Stable.zig` (layer 2, given the shape table as
  `anytype`). `map`'s closed knots and `widen`'s emitted knots are interned by a canonical form
  (partition refinement, then a depth-first key), with `fold_cond` in the key.
- Added the checks. `moveHolds` asserts the move's precondition under `runtime_safety`. Under
  `-Downership-full-cross-check`, `widenValue` and read-off run again with nothing moved and compare
  κ. Mutated builds fire both checks: a shifted move fires on `rose` and the quadtree, and a move
  onto the source fires on `mPlain`.
- Added unit tests in `Shape.zig` and a counted test for the `N [n] [n] t t` accumulator (5 → 4
  walks).
- Measured on the 2 107 corpus roots: no verdict, condition or summary change, 18 blocks change,
  −0.64 %. On 400 random programs: no verdict change and no change in any set of conditions, −9 %.

**What I learned**

- Two rules the prototype did not have are needed:
  - No move may target a node of the widening's own source. `propagate` links a position whose node
    is its member's node, and `mPlain` read `lost` without the rule.
  - A target may have bases and projection origins, as any shared node does. Refusing them blocked
    the moves that matter.
- Interning `widen`'s acyclic output is not exact on the newest master. Rule 3's walks compare parts
  by id, and `PushedTwiceLevels.g` was accepted. Knots alone were exact, so only knots are kept. The
  prototype's 29.5 % on the sweep, and its 315k accumulator, came mostly from the unsafe moves.
- The two lemma cases the spec left to a check are provable. A key names its external references by
  id, so a graph never takes the key of a node it reaches. `apartImage` reads cells only.
- A green `zig build gates` did not catch the `PushedTwiceLevels` regression, because the fixture's
  known entry matches v1. Only the corpus verdict diff saw it.
