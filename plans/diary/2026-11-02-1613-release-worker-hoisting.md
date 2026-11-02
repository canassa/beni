## 2026-11-02 16:13 CET — Release worker hoisting

**What I did**

Restored release specialisation and declaration inlining for worker-bearing builds.
Worker target paths now resolve from the final referring artifact; eligible page
and worker entries hoist independently, with worker initializers inside the
bootstrap try/finally after its listeners. Joined release maps include that prefix.
Added nested launch and map/initializer regressions and updated release output
goldens. The no-worker OrdinaryTea golden stays unchanged. Work tracked in #1679.

**What I learned**

Re-enabling Spec exposed #1699: when specialisation removed every read of a case
subject, its effectful initializer could disappear. Keeping the checker-known
effect on subject temporaries preserves worker init and nested cleanup without
changing unrelated pure output. All managed-worker Chrome and release emit cases
passed. The measured pair saves about 3.1 kB on the page and 2.1 kB on the worker
under brotli 11; this delivers the structural release optimisation, not the later
protocol or Task pruning work.
