## 2026-10-23 10:19 CEST — core's list rows keep their record condition (#420)

**What I did.** Second precision fix of R4 (#315). `List.append`'s asserted row states its
answer's record condition on its own (`rexcl π₁, rexcl π₂, rsep π₁ π₂`), and `recordTwins`
keeps a row's `rxc` when it is not `lost`; `List.copy` and `sliceOf` (so `take`) state
`rexcl π₁`; `++` lowers the base's record condition by a spread variable's elements as by a
temporary's; `List.filter` and `List.reverse` read their argument with `traverseAt`, as `map`
does. 20 rejected record lines go (the TodoMVC, Bike Wars and keyed-row entries), no list line
moves, and `ownership/RecordContentsRows` is new and red on master.

**What I learned.** The list domain's `lost` for `append` and `copy` is about a list that
lives on; for a record that is a holder, which Dead already reads, so the record condition
can be exact where the list's cannot. The remaining `exclusive` lines are each a different
limit: `sortWith` reads elements more than once, a lambda's `cb` result reads as lost in
`rfreshAcross`, an index swap by `indexedMap`, and the schema decoders' issues. With a precise
`filter`, `examples/todo/page`'s refusals now name the real sharing: `save { t | … }` writes a
todo the model still holds.
