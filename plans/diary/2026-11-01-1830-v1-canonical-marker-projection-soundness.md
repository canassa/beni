## 2026-11-01 18:30 CET — v1: two canonical-form projection fixes (#1562)

**What I did.** Classified the four verdict disagreements that v1's §16.7
cross-check (`-Downership-full-cross-check`) panics on. Three were v1
unsound accepts in the canonical form, the one v1 reports:

- `LinkedFoldCoverage` and `RefinementFoldMultiplicity` (and twins): a
  projection along `⟨T⟩⁺` dropped an entry whose path reaches a `T` with no
  marker of its own (`Rose [ t ]`'s `t` at `#Rose.0[*]`). `incAll (Rose [ t ])`
  was "accepted fresh", `twoTrees` and `nestOne` read their arguments only,
  and `treeReadAfter` and `takenOneBeside` were accepted (a
  `--sanitize-lists` run traps). `alongMarker` now adds that cell at its own
  `⟨T⟩`.
- `CycleLinkRooting` (and twin): a projection of `⟨T⟩⁺r` along `⟨T⟩⁺` kept only
  `r`, so `innerKids (wrap2 xs)` lost `xs`'s labels, which `wrap2`'s answer
  folds to `⟨Rose⟩⁺#Rose.0`. The fixture's own call is safe, but the same call
  with the wrapped value or `xs` read after was accepted and stale.
  `projEntry` now also keeps the entry whole under `⟨T⟩⁺`.
  New fixture `CycleLinkReadAfter`.

`MutualWritersMutualTypes` is a cross-check artefact: the canonical `param`
accept is safe (every aliasing caller I wrote is refused, by v1 and v2); the
expanded form refuses `element`.

**What I learned.** Keeping the whole entry under the `at` marker too, not
only `⁺`, broke core `Schema.analyse`'s summary cross-check (the expanded run
gained an `E` the canonical one did not); limiting it to `⁺`, which only the
canonical form writes, keeps every check green. With the fix,
`CycleJoinRankWriter`, `FoldSymbolicCall` and `QuadChildren` pass the full
cross-check too; `LevelPlacesKinds` (#694) still does not.
