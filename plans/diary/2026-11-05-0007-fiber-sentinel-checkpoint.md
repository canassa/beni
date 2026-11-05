# 2026-11-05 — sentinel protocol checkpoint

P6 remains uncommitted while its required size recovery is unmet. The checker
prototype is parked as an evidence patch for #1917, per the owner decision.
Raw user finalizers remain in separate typed work stores; normal hooks remain
in kernel records. No user work is erased into the D3 slot.

Ordinary return values replace hidden completion arguments. Only parked calls
make compiler-written frames. Static remainder helpers prevent exponential
suffix duplication, and bound explicit captures avoid V8 allocating lexical
environments on a non-parking loop. The deterministic allocation delta is zero
for an additional 500,000 non-parking points, versus 72,013,200 B on P5.

The audit caught and rejected two unsuccessful refinements. Copying an outer
mutable binding into a child frame lost shared updates; the shared-reference
fixture caught it and the narrowing was reverted. Giving Frame a callable type
by reading the packed closure before storing it lost ownership capture-flow;
BranchEscapes and RecordUpdateEscapes caught the unsafe new acceptances. Frames
are again stored packed and read only at their invocation endpoint. The whole
ownership corpus then had only its two inherited WordsBrowser mismatches.

Current S1–S5 brotli: 2648/3230/4150/3270/4630 B. No cap changed; S3 remains
183 B above the mandatory original 3967 B. The effects/http/every pages still
miss #1907 recovery. Targeted wake, cancellation, self-halt, frame ordering,
finalizer reuse, shared capture, schema capture, protocol fence, ownership-word
and imported-module cache tests pass. Final report/run evidence is under
~/worktree-evidence/wd-fiber/p6/; full candidate gates have not run.
