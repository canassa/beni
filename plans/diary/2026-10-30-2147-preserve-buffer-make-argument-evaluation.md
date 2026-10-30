## 2026-10-30 21:47 CET — Preserve Buffer.make argument evaluation

**What I did**

Prepared an isolated #1377 fix from the validated foundation checkpoint on
PR #1304. Direct Buffer.make lowering now runs its ignored unit argument through
normal discard lowering before allocating. The regression covers direct and
first-class calls, helper effects, exact thrown-defect identity and a real wait.
Focused development/release executions agree with an independently written full
transcript. The new corpus ownership record is the unchanged Io.run lambda
not-built row, confirmed byte-for-byte before/after; it adds no checker exemption.
Full gates and the code commit remain with the manager.

**What I learned**

Materialising an expression is not equivalent to evaluating it: the discarded
intrinsic operand can still be a call expression whose effect needs a statement.
Suspension markers happened to survive while ordinary effects disappeared, and
release optimization retained the throw that development dropped. Both output
modes therefore need the same complete regression, rather than an assertion
that merely checks the buffer is empty.
