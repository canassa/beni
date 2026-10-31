## 2026-10-30 22:05 CET — own2: the cycle child, three prototypes and the linearity choice

**What I did.** Took #1253 item 1 (a canonical `⟲` folds the recursive children, so `l` and `r` of
`Node l xs r` are both `π1⟲`). Built three versions of the canonical-path rule in `Place.extend`, each with the
unit and corpus tests adapted, and measured each against v1, against master, and on a scratch of S3b slice 4a
(#1354) with master merged. No PR: the measurements turned it into the owner's choice, which the brief says to
report, not build. The last version is on the branch `own2-cycle-child` as a reference.

1. **`⟲` keyed by the route's first step** (`π1#Node.0⟲`). `both` and `UnusedSubtree` 36:5 match v1. A tree
   writer through real calls does not: `pushKids t = Node (pushRoot l) xs (pushRoot r)` over distinct lists is
   refused, because `π1#Node.0⟲` is `l` and every subtree of `l`, so the returned `l.l` holds `l`'s written
   list. That is `incAll`'s shape, so MarkerAcross could not reach v1.
2. **The first return stays a plain path** (v1's `P s₀` exact, its marker only below): `π1#Node.0` is `l`,
   `π1#Node.0⟲` the levels below it, printed as v1's `#Node.0⟨Tree⟩#Node.1`. Matches v1 on `both`,
   `UnusedSubtree` 36:5, `SiblingSubtrees` (same-module, mutual, imported, with the shared-list twins
   refused) and, on 4a, every tree writer's own recursive call (MarkerAcross 18:19/18:47,
   LevelRecursiveUpdates 15:19, 15:47, 26:19, 26:34, 37:19). Left: LevelRecursiveUpdates 64:5 (`incLeft` over
   distinct lists; the returned right subtrees below `l` fold with `l.l`). Widen must open a union at a first
   return as at a `⟲`, or a group nests its rounds under it; groups settle one round later.
3. **Plus a `⟲` keyed by the last step back** (v1's `#Node.0⟨Tree⟩#Node.2`): closes 64:5.

**What I learned.**

- The canonical-path closure of a type, which `hits`, `levelsOf` and the graft's levels walk, is linear on
  master and quadratic with 2: for `T = N T×K (List Int)` 20/36/68 edges at K = 8/16/32 on master against
  170/594/2 210; through a `Maybe` 22/38/70 paths against 187/627/2 275. Each of K first returns has its own
  K recursive steps. 3 is K² in paths for any K-wide type.
- On 4a + master, 2 raises `incAll` from 14 199 to 40 896 records (continuation 28 672 of 28 672) and `incLeft`
  from 9 517 to 61 714, and `MarkerAcross.keepRight` stops at `ownership_summary_size`; 3 takes `incAll`
  past its allowance. The demands per path multiply (638 → 1 174 for `incAll`).
- 4a's solver must set `Shape.widen_rounds`, or #1363's opening never applies in its rounds.
- Comparing verdicts by position with `sort -u` hides a position where v2 has both an accepted and a refused
  line; the per-demand known file is the real check.

**Question for the owner (#1253):** keep child precision (2) at a type-closure cost quadratic in a type's
recursive width, or hold the linear bar and accept the folded children? Recommendation in the issue comment.
