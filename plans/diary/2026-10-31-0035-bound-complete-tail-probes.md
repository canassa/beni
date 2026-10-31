## 2026-10-31 00:35 CET — Bound complete tail probes

### What I did

Addressed the manager's independent review of the unlanded #894 facts foundation.
Specified distinct probe aborts, setup charging, early viable-branch bounds, and
unresolved evidence fallback before implementing the corrections. A saturated
work budget now aborts the entire candidate tree through ordinary WorkCap
recovery, publishing joined fallback for every eligible key of that candidate.
Gamma copying/merging/sorting, pattern walks and frame setup consume charged work;
raw source visits remain separate. The path bound stops candidate collection
before an additional viable branch can grow the frontier. Unknown type/method
evidence uses one fallback; closed primitive/derived comparisons and existing
static core abstraction rows remain explicit cases.

The distinct abort exposed summary's success-only restoration of context and
depth. Scoped defer now restores both on every return. Budget40 exercises that
error path without a panic. No runtime lowering, markup interface or source
language change was made.

Added 64-message, 128/512-arm scalar-case, generic-evidence, known-core, and late
shared-budget fixtures. All twelve focused closed-box fixtures pass. Before the
fix the 64-key fixture at W2000 reported 2056 visits; after the fix it stops at
charged work2000. Both wide scalar cases stop after 66 viable tail candidates
(one outer message plus 65 wide arms), with explicit path-limit fallback. The
late shared budget discards earlier complete candidate tails too. Ordinary write
and ownership evidence remain identical to the accepted source baseline, and
all twelve complete development/release output tree comparisons pass.

### What I learned

Ordinary precision-loss recovery must not swallow an optimization's global
exhaustion. A visit counter alone misses pattern/gamma setup and constructor
initialization. Independent Writes.init costs O(modules + declarations +
constructors) outside abstract work and must be measured separately. Timing is
deferred until the manager releases its serial measurement window; no throughput
or UI performance claim follows from these functional counters. Basics.eq is an
existing Core.row atom, so it is not a test of unresolved dispatch evidence.
