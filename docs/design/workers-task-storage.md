# Typed Task storage

Draft for #1295 and #1612, following the owner's 2026-11-01 directive:
build first, optimize later. No generated union or measurement prerequisite.

Task previously erased callbacks and runtime records into `Js.Value` to hide
its manual suspension protocol from effect inference. HostFree forbids that erasure.
Real callback types and summaries must survive, including DOM calls in bodies
whose captures are plain data.

Use **closed unit jobs** capturing their typed values. The scheduler stores
`⊤ → Bool` (False for a stale wake); macro/shutdown work runs as unit jobs.
Separate fiber control from a typed `Exit a` slot captured by its completion
and observer closures. Continuation adapters retain matching input/output
types. Keep the sentinel fast path, iterative resume, child-first cancellation
and LIFO finalizer boundaries. No universal `Value → Value` callback replaces
those types.

Migrate Task scheduler jobs → continuations → finalizers/observers → context
slots and native shims. Renderer queues follow in their own slice. Task families include pending/stack and
fork/begin work; program/custom/macro queues; wait/Resume/Fiber result storage;
cancellers and deferred releases; scheduler run/more/drain/idle/count hooks;
clock sleepers, log sinks and inherited/restored contexts. Their control
registries need typed handles too. A typed queue in an erased record still
loses its type. Generic core Ref, Deferred, Queue, Semaphore, Latch and Schema
callback records must migrate before HostFree covers their consumers.

Later renderer work includes Inline dispatch/undo/listener/event/loader
storage, Rt render/row/event/after-render storage, and Hosted/Browser commands,
subscriptions, sends and messages. DOM handles stay page-only; portable Task,
coordination and matching fetch/socket/timer shims are also worker paths.

The implementation uses typed intrusive chains over `Js.Ref`, typed scheduler
FIFOs and a common control graph. `Fiber a` owns a separate typed result slot;
closed jobs connect it to its matching continuation. Scope releases, waiters,
finalizers, observers, virtual-clock sleepers and log-context installers retain
their types. A native timer returns a typed canceller; native timer and channel
resources stay in the core-private `Js.Runtime` sibling. Dequeue precedes
invocation, preserving FIFO under reentry. Task has no callback or native-value
erasure: its only `Js.Value` is the plain parked sentinel's identity. Other
core containers and renderer queues still need their own migration.

**Owner decision, 2026-11-01:** the core-private typed protocol invocation
intrinsic is approved as a rule-6 extension. It invokes a typed possibly
suspending callback as one synchronous step, returning its value or the parked
sentinel, and retains the callback's real type and summary. It is core-only,
like `Js.suspending`; no user surface or source syntax is added. Ordinary
invocation would suspend the driver before it could inspect the sentinel;
`Js.pure`, `finally` and `suspending` demand sync callbacks and cannot express
this boundary. The compiler and Task use the new intrinsic together.

**Owner decision, 2026-11-01:** hidden typed completion callbacks and a
core-only Task.callback accessor are approved. Only suspendable calls use this
internal CPS convention. Functions that cannot suspend emit byte-identical
output; no user syntax or API is added. The suspension contracts in
`transparent-effects-proposal.md` §16 and `backend.md` record this decision.

No Buffer is needed. The core-only adapter signatures expose real callback
types; their ownership words mark retained callbacks as escaped. A scheduler
retains a closed drain with the same rule. Context record updates copy before
changing an inherited snapshot. The returned wait canceller is explicitly
`sync`, enforcing the existing contract (#1649). Continue correctness checks;
correctness is the Task/effects and browser/tea corpus, then unfiltered gates.
Performance belongs to a later slice.

The typed control graph currently retains its general cleanup paths where the
old raw-record implementation pruned individual capabilities. Optimizing that
graph follows the owner's build-first directive. Tests use the typed host
adapter to identify retained fiber machinery; raw `finalizers`/`children` key
counts no longer describe the representation. Cancellation and cleanup order
remain behavior contracts, including cancellation before a queued child's first line.

V2's ownership parity currently falsely aliases the fresh chain snapshot with
an earlier Ref read (#1664). The reduced fixture and six precise differences
use §7.2's existing known-difference mechanism; default-checker verdicts and
all other parity checks stay enforced. This is follow-up ownership work.
