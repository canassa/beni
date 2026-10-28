## 2026-10-28 23:12 CET — folds, ⊤ holders and explicit stacks

**What I did**

- #1125 (merged): reviews found two soundness gaps in opening a collection on widen's cycle.
  - A leaf-only class's `lost` was skipped as redundant, so a block read `yes` after a round trip.
  - Folds that opened nothing had no cross-member check.
  - Fixes: the stored snapshot is now the one source (`kappaOf` reads no `widen` evidence beside it), and every fold reads its class as a multiset.
- #1102 (PR #1132): a crossing row carries its `returned`/`aliased` parameters as recasts, and a value built at a type-variable place carries its parts. A `⊤` holder counts only for what reached it, or for what escaped. The new `TopHolders` fixture matches v1.
- #1129 (PR #1133): `relabelAt` keeps a fold's observed steps.
- #1130 (PR stacked on #1133): `kappaAt`, `kappaRelabel`, `kappaMerge`'s pairs, `graft` and `linkArgs` use heap stacks. Tests run 30 000 levels deep on a 1 MiB thread.

**What I learned**

- A side table read beside the snapshot (`fold_dups`) is a second source of truth, and a block cannot carry it. Store the condition, not the evidence for it.
- `Js.array`'s literal argument has a type-variable place, so a literal there was a bare `⊤`. That is where the over-broad `⊤` rule came from.
- At the `path_steps` limit the old recursion survives Linux's 16 MiB stack. Only a small stack (wasm's) shows the overflow, so the test runs on a 1 MiB thread.
