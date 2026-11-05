## 2026-11-05 04:44 CET — Finish the slot-domain branch for its pull request

**What I did**

- Took `own2-final` to `own2-slot-pr` and rebased it onto master twice: 29 commits, then 102. I used `--rebase-merges` with an exec step. That step set each commit's tree back to the original commit's for every file master never touched. The two join merges had hand edits (`PlaceIdentity.zig`, `Routed.zig`, …), and a plain re-merge loses them. A first linear rebase showed that. Master moved `.run-hash` records into a cache outside git, so the branch's 43 record files went too. So did master's stray `SanitiserNestedPassOn.run-hash`.
- Folded in both hole lanes (`own2-holes-r2`, `own2-holes-r3`). I reverted their raised line targets by splitting files along seams they already had: `LabelChain` and `Outward` out of `Eval`/`ReadOff`, `FedCall` out of `Fed`, `WalkContext` out of `Walk`, `Codes` out of `Groups`, `Verdicts` into `Kept`. All 2 227 roots dumped byte-identically across the split.
- Found and fixed #1772 while regenerating the known list. A callee's result arrival at an argument closure (`Task.keepLogContext`) dropped the closure's captures. So `Hosted.later`'s body escaped without them: the page logged `1,2,3` where the copy logs `0,1,2`. A returned closure also let the list it reads be pushed in place (`run/SanitiserCapturedHeld`). The first fix asked `valueAt` per arrival. `valueAt` makes values, and `removeMin` rose 44%. The final form (`Captures`, through `Relation.Eval.routed`) makes nothing, and the cost table is unchanged.
- Regenerated `ownership-v2-known.txt` with a generator. It fails on any v2-accept of a v1 refusal that does not name where v2 refuses instead. Re-blessed the `.v2.unchecked` goldens (core: 45 `(row)` lines, no limit). Gates and `gates -Dllvm` are green. Made one ReleaseFast measurement: 31.0 s against master's 31.3 s over 2 255 roots, with 2 limit lines against 7. The PR body is drafted in `~/.cache/beni-agents/slot-build/pr/body.md`; the PR is not opened.

**What I learned**

- A known-list row where v2 is `absent` licenses nothing: the emitter edits in place only at an accepted demand. Only rows where v2 *accepts* need proof. Auditing them showed that 62 such rows from earlier lanes have no per-row probe (#1949). The bar is not met there yet.
- `bench/ownership-everywhere.mjs --diff` reports a known limit line as "no longer occurs" when its root is outside the bench roots. A generator that drops stale rows must keep limit lines.
- `BENI_BLESS_ONLY` filters fixture paths, not golden names. Bless one fixture at a time with `-Dcorpus`.
- The Zig 0.17 compiler SEGV'd three times in three different steps, and each passed on retry (#1948).
