## 2026-11-02 18:11 CET — Check mixed worker Wire entries

**What I did**

Rebased stable-Wire omission onto the release-hoisting change. Kept both sets of
emission documentation and tests when resolving the rebase conflicts. Added one
page that holds two workers: a clone-stable recursive tree protocol with records
and unions, and a protocol carrying List views. Chrome exercises config, replies,
events and cleanup in development and release.

The emission test identifies each worker from its emitted descriptor. It checks
that the page and List worker retain the interpreter, the stable worker omits
it, and only the List descriptor has runtime plan data. Keyed plan omission to
the resolved embedded Browser.WorkerRuntime rather than a Program type spelling.
Re-measured the original paired pages against the rebased baseline.

**What I learned**

The master controls for the memory investigation both pass with the default
Node heap. The earlier identical-output comparisons used workers as their
baseline; they did not establish a master memory requirement. Posted the control
results on the issue. The workers-branch memory regression still needs its
post-HostFree default-heap check before the feature reaches master.
