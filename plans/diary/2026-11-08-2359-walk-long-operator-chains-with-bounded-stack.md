## 2026-11-08 23:59 CET — walk long operator chains with bounded stack

**What I did**

- Checked #2090 on master: the shipped playground wasm stops `check` of
  `run/WideArithmetic` with `RangeError`. `test-playground` was green only
  because that program was not in its list.
- Ported the lost constrain fix (a call's left spine on a list of open
  calls) onto master's `constrain/Expr.zig`.
- Made emit's lowering walk every call with frames. `callPlan` is now the one
  prelude for outer and inner calls, so the arithmetic-only walk is gone and
  emitted JavaScript is unchanged.
- Built the shipped wasm with names to find each further pass that recursed
  per term: `reachesProjected`, BIR `lowerExpr` for binary operators, and
  `Solve.solve` on nested conjunctions. Each walks the chain with a fixed or
  heap list now. `solve` keeps each child's `depth`, so §10.2's budget reads
  what it read before.
- Added `run/WideIdiv` (4 095-term `//`), wasm gate tests for both chains,
  and both chains in `test-playground`.

**What I learned**

- After the fix, both chains build on the shipped wasm under
  `node --stack-size=60`, the same floor as a five-line program.
- To name the frames of a wasm `RangeError`, build the playground with
  `.full` debug info for `shipped_wasm` in `build.zig` (local only): the
  trace then shows `beni.wasm.<module>.<fn>`.
- Native thread stacks (64 MiB) hide these walks. Only the wasm compiler on
  V8's stack shows them.
