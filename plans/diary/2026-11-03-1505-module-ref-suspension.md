# Module-level callback cells lose suspension

Review item7 permits a tracked inherited finding with a pending executable.
Issue #1788 records a module `Js.Ref (⊤ → Int)` initialized with a synchronous
callback, then written with one that yields, writes42 and returns42. Its caller
receives the suspension token and continues before the write: `[object Object]/0`.
The correct result is `42/42`.

The same source reproduces twice in development and release on exact original
workers b688a8ffd2, and twice in both modes on the hostfree lane's compiler based
on9371b2767f with unrelated Schema experiments. A one-line oracle twin calls the
same callback directly and prints `42/42` twice in both modes on the base. These
are tiny targeted programs on CPU0; no stress workload or raised heap is used.

`tests/pending/run/core/ModuleRefSuspends.beni` preserves the correct expected
output. The existing pending corpus runner reports its exact registered
`dev: exit=0 stdout-differs` reason twice. CK-318 documents the finding. The
underlying effect propagation is deliberately left open under the review's
fix-or-issue-and-fixture option; HostFree storage needs that propagation too.

Evidence: `~/worktree-evidence/hostfree-review1/module-ref/`. Full gates remain
for the completed hostfree PR, under the manager's shared-lock protocol.
