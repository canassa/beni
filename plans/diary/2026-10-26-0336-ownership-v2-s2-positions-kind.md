## 2026-10-26 03:36 CET — Ownership v2 S2: the positions kind and the multiset read

**What I did.** #1036's re-review found that a `union` is not always
alternatives: a literal's `[*]` was `Shape.join` of its elements, and
`Shape.map` builds a union without canonicalising, so `f a b = [ { a = a },
{ a = b } ]` at `f x x` read `[*].a` as `union(leaf{x}, leaf{x})` whose
cell set has one `x` — `yes` where the value holds `x` twice. Built the
manager's principled fix: two operations, two node kinds. `join`/`union`
stays alternatives; `Shape.collect` builds a `positions` node for a
literal's or a spread's elements, never deduplicated. `proj`, `map`,
`reach` and `widen` keep the kind; `Cond` reads a positions node over the
multiset of its sides' cells (`Radix.intersection`, one descent per
node). Twins: PositionsRepeatArg refused, BranchSameElement accepted, the
multiset order-insensitive, a repeat across a union side, a depth-1000
chain linear, the Rose fold reading `lost` with `F(x) ⊑ x` in one step.
Rebased both branches onto master with #1038 merged (the design text wins
every conflict in `ownership-v2.md`); full gates green.

**What I learned.** The set-vs-multiset distinction cannot live in a set
of cells: it needs a node kind, and every structural operation must carry
it or the multiplicity silently drops at the first projection. Three
places where the merged text and the code now differ, to settle with the
manager rather than bend either: `leq` is γ-inclusion and kind-blind
here (κ carries the multiplicity through `kappaLeq`), while §2.3 asks for
a structural union rule and a charged multiset matching; `widen` keeps a
union or positions member as an un-expanded side of the class image, so
no `positions(self, self)` and no folded bit ever arise — the fold reads
`lost` through the image node, which is the guarantee FoldedPositionsLost
wants; and `cellsAt` returns a set, the multiset being the read's. The
Cond file sits at 997 of 1 000 lines: the next feature there moves text.
