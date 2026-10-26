## 2026-10-26 09:25 CET — ownership v2 S2b: block records once, pins by package

**What I did**

- #1060's second review: rebuilt `src/own2/Block.zig`. Every record is now written once and named by its ordinal. Cycles are `group` records whose members are numbered first. Keys come from structure, with partition refinement inside a knot, and the table is a post-order walk from the classes. κ maps are written as their owners' stored entries. A read is charged once against the caller's allowance, and a block's places live in their own `Place.Table.ofBlock` namespace. `Shape.knot` and `Shape.tie` rebuild a knot. §3.6 has an *As built* note, and the §5 target is 1 700.
- #1059's re-review: a pin now counts only under its own package's directory. The readers of a taken result are a fixpoint over BIR refs across core's modules, which adds 66 core pins. The inlined List primitives in `Operator.zig` and `js/Lower.zig` are pinned between markers. `beni help` now describes dump's bir stage.

**What I learned**

- Both review rounds found one defect: the encoder spelled structure out again (sort keys, cells inline, κ numbered while hashing) instead of naming it. A table of records with ordinals, and keys computed once per record, removes the whole class of defect.
- A bisimilar copy of a knot (widen run twice) must be one record, or the order between the copies leaks into the bytes. Moore refinement inside each component, with keys that include the previous round's key, gives canonical keys. It costs a number of rounds bounded by the knot's size.
- Over-approximating taken readers by refs is cheap to compute, but it pins every transitive caller of a fold in core. Platforms are not followed, as the coordinator scoped it.
