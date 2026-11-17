## 2026-11-17 12:22 CET — release as-bound scrutinees on the branch

**What I did.** Took blind round W's release crash under `--lists-in-place` (14 `RIPTRAP`s) and #2547
(round V's plain release that threw on an `as`-bound tuple) on `ownership-v2-design-review`. Both are
one defect: `Spec.liveness` wrote `undefined` over a dead binding's initialiser in place, and
`Lower.bindings` shares that node with the `case`'s tests and the patterns' reads. `master` had fixed
it on 2026-11-15 for #2512 (42490ac7a5, with #2514's inlined-loop slots), which the branch lacked, so
I cherry-picked that commit and its two fixture commits rather than write a second fix of the same
line, and closed #2547 from it. Added `run/ReleaseAsBoundScrutinee` (#2547's shape, variable arms,
`as` one level down, `as` over `…rest`), `run/ReleaseAsListInPlace` with a new corpus leg that builds
every `.sanitize-lists-v3` fixture as a release under `--lists-in-place`, the sweep family
`as-scrutinees.mjs` (82 faults on the base, 0 after), research report 152 and a general rule in
`backend.md` §9 and JsIr's header. All 30 generators, 13 fault folders, the corpus and the 21 blind
programs under the four legs: 88 601 programs, only the three known faults. Gates green.

**What I learned.** JsIr is a tree of statements and a DAG of expressions: a throwaway parent count
over the `run/` corpus found shared `ident`, `member`, `index_get`, `call`, literal and `arrow` nodes,
never a statement. Of the specialiser's 35 in-place writes only `liveness` made a rewrite true at one
parent. Before writing a fix on a long-lived branch, check whether `master` already has it
(`git log origin/master -S`): this one had been fixed two days earlier.
