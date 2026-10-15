## 2026-09-28 08:44 CEST — R15 fix slices C–H, the compare benchmark committed

**What I did**

- Landed R15-fix-C (alias chains without a silent cap; alias DAG expanded once; every `err`
  reported, enforced in Debug by `assertErrorsReported`), R15-fix-D (CK-126, 143, 145, 147,
  148), R15-fix-E (CK-154, 159, 162, 168; CK-161's message), R15-fix-F (linear resolve and
  lower, parser depth as a max, wide-sum exhaustiveness, `_manifest.txt` for a clean
  `--out`), R15-fix-G (injective aliases for CK-175, alias names kept, cycles before
  mismatches, poisoned payloads) and R15-fix-H (a `--release` miscompile on alias chains past
  128 fixed by path-compressed substitutions; a 64-slot walk in foreign check 1; the manifest's
  case fold and header).
- A read-only adversarial reviewer ran after every pair of slices; each round found something
  (a silent `err`, a phantom-alias I9 break, the release miscompile), which became the next
  slice with red fixtures first.
- Committed the generated cross-language benchmark (`17a42d0`) and its first clean run
  (`60a9558`): CPU ms per unit, beni 6.1, Gleam 22.2, Elm 27.4, TypeScript 39.6, Roc 92.6,
  PureScript 1004. A fairness review found no bias in beni's favour; Roc's compile-time
  evaluation and Elm's 128 MB nursery are disclosed.
- The owner decided CK-161 (dot-call reaches a derived eq/compare) and CK-179 (alias names in
  inferred types: agree or expand). R15-fix-I implements both, plus the residues.

**What I learned**

- Budgets that run out into an answer are the recurring defect class: 1024 in
  `TypeStore.resolved`, 64 in `Printer.resolve` and `Emit.firstTypeVar`, 512 in
  `orderWalk`. The rule now written into checker-v2 §12.2 and backend.md §9: a budget may
  only decline an optimisation or report a diagnostic, never yield a result.
- `7fdf8a2` is a red commit (fixtures promoted one commit before their fix). Every later
  slice was told: red fixtures stay in tests/pending until the commit that fixes them.
- Parallel slices in worktrees need disjoint source directories; the plan documents always
  conflict and always merge by keeping both sides.
