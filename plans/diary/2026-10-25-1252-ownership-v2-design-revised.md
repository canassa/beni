## 2026-10-25 12:52 CET — Ownership checker v2 design: the second review, verified and folded in

**What I did.** An independent Opus review of PR #1010 (34 findings, 6 blockers) arrived with the owner's order
to verify, not trust. Every finding was checked against the code first: the BIR spread lowering
(`Lower.zig:2563`), the type keys (`TypeKeys.zig:20, 682`), the alias expansion (`Unify.zig:826`), the
missing `refs` edge for method calls (`Bir.zig:307`), the sanitiser flag (`Cli.zig:345`, copy-and-poison in
`Lower.zig:6379`), and the Driver hook. 31 findings were right and fixed in the core (deep directional escape, a
cell trie with persistent reach sets, use kinds, field captures as reads at creation, exact-permutation index
exchange, singleton vs summary cells, per-path κ with the I-κ invariant and O13–O15, closure classes in summaries,
widening onto the place graph, sparse propagation for the entry and feedback fixpoints, a BIR spread fact,
structural place identity, a nominal `Send`); one was partly right (the sanitiser tools: the flag and the
approach exist, the build steps do not); one was wrong and declined with evidence: the per-module Driver hook exists
(`Driver.zig:443` → `Enforce.checkModule` → `Enforce.zig:171` publishes the block into the interface,
`Incremental.zig:300` hands it on). The plan gained S2b and a split S3, S4→S5 sequential, #961 landing on v2 at
S8, 81 implementer-days; Appendix B maps all 46 pending fixtures to slices; the module DAG was renumbered to 13
layers after a script found three same-layer edges.

**What I learned.** (1) "The pass runs after the whole check" was false: read the Driver before believing a
reviewer about the pipeline. (2) A materialised `reach` set is quadratic on a chain of updates, and so is a
reverse index climbed through shared override trees; persistent sets with a last-use skip are the linear answer.
(3) An eager DAG join has the BDD bound; the honest fix is laziness (a `union` node), not a fast-path argument.
(4) A fixpoint over shapes of a recursive type is infinite without widening; the place-graph quotient is the
widening and it is the identity on non-recursive types, so #856's sharing survives. (5) Clean's "one cell twice is
shared" is wrong for summary cells; Sagiv's singleton/summary distinction is what lets `List.map`'s result be
exclusive. (6) `traverseAt`'s "once per index" is an obligation on its inferred callers; pin them, don't assume.
