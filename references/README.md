# References

Vendored sources kept as primary evidence, one git submodule each, pinned and
shallow. Commit the submodule pointer, never the contents. `talks/` is the one
directory of plain files; its own README has the convention.

## Whole-program optimisers (added 2026-10-02)

These were added for research 52, *the release optimiser against the state of
the art*. They are the production implementations it audits `src/js/Spec.zig`
against. Four are large, so they were cloned shallow and **sparse**: only the
directories below are checked out. A fresh clone of beni gets full checkouts
unless you set the same paths:

```sh
git submodule update --init --depth 1 --filter=blob:none references/<name>
git -C references/<name> sparse-checkout set <paths below>
```

| Submodule | Pinned at | Sparse paths | Read for |
|---|---|---|---|
| `llvm-project` | `b05bc1f7` (2026-10-02) | `llvm/lib/Transforms/{IPO,Scalar,Utils}`, `llvm/include/llvm/Transforms/{IPO,Scalar,Utils}`, `llvm/lib/Passes` | IPSCCP and `SCCPSolver`, FunctionSpecialization, the Attributor, SROA, GlobalOpt, the pass pipeline |
| `closure-compiler` | `e2e99ba9` (2026-10-01) | `src/com/google/javascript/jscomp` | `PhaseOptimizer`'s loop, OptimizeCalls/OptimizeParameters, InlineFunctions, RemoveUnusedCode, property disambiguation |
| `graal` | `bcdab016` (2026-10-02) | `compiler/src/jdk.graal.compiler/src/jdk/graal/compiler/{virtual,nodes/virtual}` | partial escape analysis and scalar replacement |
| `ghc` | `c35096f5` (2026-10-01) | `compiler/GHC/Core/Opt` | the simplifier, occurrence analysis, SpecConstr, demand/CPR and worker/wrapper |
| `mlton` | `936011ca` (2026-09-30) | (full, 62 MB) | the SSA pass list, ConstantPropagation, Useless, RemoveUnused, Contify, flattening |
| `egg` | `73975c98` (2026-09-28) | (full, under 1 MB) | equality saturation's runner and its limits |
