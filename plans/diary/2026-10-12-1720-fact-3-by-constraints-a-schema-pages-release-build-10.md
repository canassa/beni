## 2026-10-12 17:20 CEST — fact 3 by constraints: a schema page's release build −10 %

**What I did.** Profiled `--release` on `browser/tea/ApiItems`, `ApiLogin`, `HttpJson`,
`bench/size-apps/ApiAndRoutes` and `run/SchemaDeclRecords` with an in-process instruction
counter per `Spec` phase. Made fact 3's fixpoint sparse (`Pts.byConstraints`): the first sweep
records every evaluation as a constraint with its inputs, and after it a change wakes only the
constraints that read it, not the function body around them; a guard's death is recorded with the
reads that may kill it. Plus two exact cuts: a round's first sweep of facts 1, 2, 4, 5 counts from
the count record, and `rewriteCalls` walks only modules naming a function that lost a parameter.
`backend.md` §9 amended (dated). Every output byte for byte (519 release builds compared, goldens,
run hashes); the fact-3 safety check run at every size over the whole corpus agreed.

**What I learned.** Schemas are not what blows the page up: it is the `browser-tea`/Task/Http
runtime (~23 000 nodes) analysed eight times (rounds plus capped passes), each fact-3 fixpoint
re-walking units in ~12 sweeps where five in six node evaluations changed nothing. ApiItems's
release build 2 022 → 1 824 M (fact 3 560 → 396 M; ReleaseFast 406 → 359 M); the corpus case is
2.58 G with hashes valid, ~3.8 G of 4.3 with Node. Lowering shares operand nodes (`a.b` in
`a.b.c` and `a.b.d`), so a constraint is an evaluation, not a node. What is left is spread thin:
facts 1, 2, 4, 5 (~290 M), `rewrite` (~200 M), the inlining passes (~220 M). The former can not
safely take the same treatment: `decided_conds` keeps a decision made at an intermediate sweep, so
their result depends on evaluation history — and if a read is nonnull mid-iteration and ⊤ at the
end, `x.p === null ? f : x.p` may fold wrongly; unconfirmed, worth a red fixture. Scratch space:
/tmp is a shared 8 G tmpfs; put work dirs under `zig-out/`.
