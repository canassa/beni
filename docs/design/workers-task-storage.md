# Typed Task storage

Draft for #1295 and #1612, following the owner's 2026-11-01 directive:
build first, optimize later. This replaces the earlier proposed generated
continuation union. It adds no measurement prerequisite.

Task currently erases callbacks and whole runtime records into `Js.Value` to
keep its manual suspension protocol out of effect inference. HostFree forbids
that erasure. A callback's real type and inferred callable summary must survive
even when its captures are plain and only its body calls the DOM.

Use **closed unit jobs**, with typed values captured by their closures. The
scheduler stores `⊤ → Bool` (False for a stale wake); macro/shutdown queues store
`⊤ → ⊤`. Keep common fiber control separate from a typed `Exit a` result slot;
completion and observer closures capture that slot instead of putting an
arbitrary value in the control record. Continuation adapters must likewise
retain the matching input/output types. Keep the unique sentinel fast path,
iterative resumption, child-first cancellation and LIFO finalizer boundaries.
Do not substitute a universal `Value → Value` callback or generated union.

Storage to migrate: Task pending/continuation stacks and fork/begin work;
program/custom-scheduler/macro queues; wait records and Resume/Fiber outcomes;
observers, cancellers, finalizers, deferred releases and shutdown hooks;
scheduler run/more/drain/idle/count callbacks; clock sleepers, log sinks and
inherited/restored context slots. Their control registries must be typed too:
a typed queue inside an erased record still loses its type. Generic core Ref,
Deferred, Queue, Semaphore, Latch and Schema callback records also need typed
representations before HostFree can cover their consumers.

Order: scheduler jobs → continuations → finalizers/observers → context slots →
renderer queues → native shims. The later renderer work includes Inline's
dispatch/undo/listener/event/loader storage, Rt's render/row/event/after-render
storage, and Hosted/Browser command, subscription, send and message storage.
DOM handles stay page-only; portable Task and coordination storage is also on
the worker path. Http/socket/timer/native callback shims retain their host types.

The first implementation replaces the program queue with a typed linked FIFO
using existing `Js.Ref`, so it needs no `Js.Buffer` or foreign widening. A job
is removed before invocation, and reentrant enqueue preserves FIFO order.
Custom schedulers and continuation/value storage still need migration; this
first change alone does not make Task HostFree-complete.

No language change is chosen. One possible owner decision is a typed protocol
invocation operation: ordinary invocation propagates the callback's suspension
to the drain, whereas Task must consume its sentinel itself. If existing
compiler operations cannot express that boundary while retaining callable
summaries, request the exact rule-6 extension with a reduced example. Likewise,
request a private mutable typed Buffer only if the implementation needs one;
retain element types and explain its aliasing contract. Keep building until
such a concrete decision is necessary. Correctness comes from the Task/effects
and browser/tea behavior corpus and the final unfiltered gates.
