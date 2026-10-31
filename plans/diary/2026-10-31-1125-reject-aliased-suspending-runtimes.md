## 2026-10-31 11:25 CET — reject aliased suspending runtimes

**What I did**

Reproduced the owner's review finding on the accepted runtime foundation: a
runtime annotated through a function alias passes checking despite Task.yieldNow.
The permanent regression failed before the fix with expected exit1, actual0.
Specified alias-transparent effect-site selection before changing the predicate.
Only root0 sites reached through zero or more zero-index alias expansions name
the runtime arrow; structural steps still identify nested values. The existing
suspension rung and unresolved nonsync dependency rules are unchanged.

The focused matrix now rejects direct, local/nested/parameterized/identity and
imported alias forms in cold/warm checks and development/release builds, without
writing an output directory. Warm checks report zero checked modules. Pure and
impure synchronous alias runtimes still run in both output modes while retaining
a suspending callback. Invoking that unresolved callback is rejected. All13
existing/new generic-runtime tests pass on the integration candidate; final
unfiltered gates are required on this isolated correction before its push.

**What I learned**

Nonempty effect paths do not necessarily enter a nested function: alias expansion
is transparent. Independent review confirmed that Walk traverses aliases only
through expansion0, including compressed and substituted aliases. A broader
parameter/result/field match would incorrectly reject stored callbacks. The
separate imported plain-method fast path excludes alias-root schemes, so no
sibling bug was established there. The owner-reported ownership golden/CPU/case
failures have not been attributed to this PR without matching baseline evidence.

Saved the full unaccepted entry integration in owned recovery ref/patch before
isolating this fix on accepted 1b8304b6c; none of its source was discarded.
