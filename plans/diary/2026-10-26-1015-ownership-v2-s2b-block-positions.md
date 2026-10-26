## 2026-10-26 10:15 CET — ownership v2 S2b: block positions with read κ

**What I did**

- #1060's third review. The block now writes positions: a node, its position class and its owner's map. They are reached from the owner's values through parts and through `proj`, and each one carries the κ read there. A union carries its stored κ. The reader stores that κ, checks that `proj` makes each projected position, and refuses nodes no constructor makes (sides at two places, a child at a place its step does not reach).
- One Hopcroft refinement (counting union sides) partitions every position of the block. Its decisions depend only on block numbers and signatures, so the numbers are canonical keys. This fixes the cross-knot keys, union-side order, `map(widen x)` against `widen x`, and the ring cost (k = 1 000 under the default allowance).
- The reader moved to `BlockRead.zig` at L12 (Ownership is L13, Enforce L14). Block's target is 1 300 lines and BlockRead's is 800.
- `Cond.isFolded` read a missing label and crashed on an asserted row's `taken` element. It now reads it as folded, which claims less.
- Rebased #1060 onto master after #1057–#1059 merged, retargeted it, and deleted `own2-s2b-core`.

**What I learned**

- A class's meaning is κ as read at positions that `proj` makes, not the stored map. An encoding of stored entries over explicit structure loses entries on nodes that `proj` makes, and it merges nodes whose missing entries mean `lost`.
- Hopcroft's algorithm gives canonical block numbers for free if every tie-break uses block numbers and signatures, never element ids. That removes the need for canonical names of minimal cyclic graphs.
- Merging bisimilar sides of a union makes the reader's constructor absorb it. Reading the written union's κ over its sides and joining it into the side keeps that position exact. The side's other reads can only grow.
