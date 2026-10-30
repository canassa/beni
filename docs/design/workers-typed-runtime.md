# Typed callback storage for worker realms

Specified 2026-10-30 for workers.md §4 and #1295. This implements the selected
native-type design. Native handles and callbacks must retain ordinary types;
there is no runtime-wide Js.Value exemption. This document changes runtime
implementation structure, not source grammar or the fatal and suspension
contracts. Implementation status is recorded below as each bounded slice lands.

## 1. Audited baseline

At revision 128902faf, the retained census identifies 130 mixed callable use
sites: Task 41; Inline 11; Rt 12; Hosted 15; Browser 10; Schema 28; WebSocket 5;
Listen 3; Http 2; Browser.Events 1; inline Browser 1; Log 1. These are apply or
construct expressions, not callback producers or storage declarations.

Task has 3,532 source lines. Its own architecture comment at lines 33–40 says
all callbacks and records are Js.Value specifically to hide their calls from
ordinary effect inference. Its host and guest helpers erase arbitrary a at
lines 92–98. The following storage families were traced from producers to uses:

| Storage | Producer | Consumer and required type |
|---|---|---|
| pending.ks and fiber.stack | andThen pushes a continuation; fork pushes work and finish | loop pops a continuation; its input and result types can differ |
| queue and scheduler.queue | schedule and scheduleOn append task and three arguments | drainFrom and drainFromS invoke heterogeneous jobs |
| portTasks | macrotask appends host work | MessageChannel callback invokes a closed unit job |
| turn, defect, whenDone | onTurn, onDefect and shutdown callbacks | synchronous unit callbacks with their actual arguments retained |
| finalizers and releases | bracket, scope and onShutdown register work | cancellation and shutdown invoke typed cleanup jobs |
| observers and wait records | await and observe install resumptions | completion resumes the matching value type once |
| slots and outcomes | spawn inherits slots and a fiber completes | typed Fiber a retains Exit a; context slots retain their owning type |

The 13 top-level Js.Ref V declarations in Task are pending, current, outside,
port, turn, defect, cleaning, soonRunning, deferral, culprit, whenDone,
deadlineTimer and started. This is a lexical declaration count, not 13 callback
cells: several hold native resources or whole runtime graphs. Embedded records,
arrays and dynamically named fields add storage not counted by that figure.

Inline has 1,308 lines. queue stores raw function and argument pairs; undo
stores cleanup callbacks; heard retains listener maps; early retains native
events; entries retains data-loading callbacks. The made field holds a DOM
query cache. Its six Js.Ref V annotations include that record field.
Rt has 2,334 lines and six Js.Ref V annotations: queued, phase, screenLine,
screenReport, parked and afterRender. The generic mount, row and key helpers
also retain callbacks in slot records. These are storage audit findings, not
an estimate of migration edits.

## 2. Inline dispatch queue

The first bounded implementation replaces Inline's function and value pairs
with a homogeneous queue of closed unit callbacks. Each callback captures its
actual typed receiver function and value. This creates one additional closure
for each queued send compared with the old function and value slots. That is a
real allocation cost of the migration and must be reported, not described as
allocation-neutral merely because the buffer itself has no wrapper. No callback is converted to Js.Value
to enter this queue. Ordinary inferred callback obligations therefore remain
visible through the closure and the queue element type.

The platform runtime ABI becomes:

```text
pub send : sync (a → ⊤), a → ⊤
pub sendVia : sync (a → ⊤), event, sync (event → a) → ⊤
```

sendVia executes the extractor inside the dispatch guard before enqueueing the
closed callback. A reader that throws still stops the page. A nested send is
queued in FIFO order; no callback runs reentrantly. The outer dispatch drains
batches until no queued work remains. A callback that stops the page prevents
all subsequent callbacks from running. The existing finally guard restores the
running flag and records a defect when program code throws.

The queue uses a typed portable mutable buffer, exposed only to core and
platform code as Js.Buffer.Buffer a. Its primitive operations are:

```text
pub foreign impure make : ⊤ → Buffer a
pub foreign impure push : Buffer a, a → ⊤
pub foreign impure length : Buffer a → Int
pub foreign impure forEach : Buffer a, sync (a → ⊤) → ⊤
pub foreign impure forEachWhile : Buffer a, sync (a → Bool) → ⊤
```

The buffer's native representation is the array itself. Zig lowers these calls
to an empty array, native push, length and for-of, preserving the element type.
The callbacks are synchronous and invoked in FIFO order; callback defects propagate.
forEachWhile stops when its callback returns False. The dispatch drain uses this
operation so a stopped page does not walk all remaining queued thunks.
Only private mutable buffers are accepted, so indexing an arbitrary native array
or accessing an unchecked element is not exposed. A detached batch is walked
before newly queued work. Queue admission and resource exhaustion retain their
own existing runtime policy; this primitive adds no recoverable native failure
that the queue previously hid.

A Zig build tool constructs the complete fallback sibling with JsIr and Print.
It contains actual exports and arities, so existing foreign sibling coverage,
arity and import validation remain unchanged, including first-class uses. The
generated asset is included in coreDirectory, coreCopy and embedCore, hence in
the checked core, compiler build identity and variant-core inputs. No handwritten
JavaScript file or compiler-only foreign exemption is introduced. A Js.Buffer
import receives the same core and platform privilege check as core Js, keyed
on its actual core module identity. Ordinary application modules named Js.Buffer
remain ordinary application modules.

This buffer avoids two measured proof failures: List.push after Js.Ref.read
reports list_shared because the read cannot establish exclusive list ownership;
Ref.update under the current core-pack pass reports the callback argument
borrowed. Copying the growing queue would weaken the required complexity, so
neither a List.copy workaround nor a frozen-v1 exception is used. Native push
retains amortized constant append, and the typed buffer adds no node wrapper.

The direct and via distinction propagates to on, onArm, onTaken and onArmTaken;
each gets a separate Via entry point. The inline lowering selects it using the
already-known extractor presence. commands keeps Cmd msg and its actual msg
callback typed. Listen calls sendVia with its typed callback and extractor.
Compiler-generated zero-payload sends supply unit explicitly where the source
runtime requires an argument. Runtime arities and emit goldens change together.

The program mount and native listener registration are separately audited
boundaries. Their existing raw representation is not evidence that C has been
implemented. Native callback shims must migrate to the generated typed native
operations before the C gate can permit worker launching. This first slice does
not add a fallback that casts a callback to Value when type checking fails.

## 3. Task migration and suspension compatibility

Preserve the current contract: direct successful calls return their value;
parking returns the unique sentinel; continuations unwind inner first; resuming
runs one continuation at a time; cancellation and cleanup retain current order.
Task.andThen and Task.isWaiting are compiler protocol operations, not permission
for arbitrary source values to erase their type. The sentinel is runtime control,
not an a supplied by an application.

Migrate closed scheduler jobs first. A queue job has type ⊤ → Bool; it captures
its fiber, resume value and wait token at their real types. Macrotask work has
type ⊤ → ⊤. Scheduler hooks, finalizers and observers likewise retain their
actual callback types. Fiber control state is separated from its typed Exit a
slot; a completion callback captures the typed slot instead of storing an
unconstrained payload in a common raw record.

The heterogeneous continuation stack requires compiler cooperation. It cannot
be represented by replacing a→b with Value→Value. Lowering knows the continuation
and argument types at each suspension point. Generate a closed union of the
reachable continuation closures and typed resume slots for each emitted entry;
its constructors and executors are ordinary typed generated declarations. Keep
callbacks inside those closures, not in Value fields. The compiler validates
producer and consumer pairing and preserves the sentinel fast path. Generic
source declarations retain symbolic obligations until instantiated; a shared
chunk can contain only variants valid for every importing entry.

This generated closure-union work must be implemented and verified as a complete
compiler and runtime slice before changing Task's pending or stack fields.
No new existential or higher-rank source type is introduced. If the implementation
cannot construct and check this pairing using the selected ordinary-type
contract, report that unresolved choice before changing the suspension contract.
A raw universal callback, unchecked downcast or blanket trusted runtime exemption
is not an accepted intermediate representation under C.

After typed continuation storage, migrate scope finalizers and observers, then
context slots and every remaining native callback shim. HostFree can reject the
remaining callback erasures only after these consumers and their producers have
moved together. Public worker launch remains gated throughout this sequence.

## 4. Measurement and fixtures

Use the development compiler built by zig build. Compile the same source corpus
with the baseline and changed runtime in development and release output modes;
this does not require a release-mode compiler. Record raw emitted bytes and
Brotli bytes with identical options, plus the complete observed behavior.
Generation or queue mechanics may change source structure; native type identity
and upcasts themselves must not add boxes, proxies or registration tables.
Do not claim a byte or throughput result without the measured artifacts.

For Inline, cover deep queued commands, FIFO messages that enqueue more messages,
reader evaluation before a queue drains, stopping during a drain and a reader
or callback defect. Existing DispatchDeepKey, ReadDuringDispatch and
StopMidDispatch are acceptance fixtures. Add a focused mixed-type callback
fixture so a typed queue cannot accidentally unify unrelated argument types.
Check normal and release transcripts. Inspect the emitted queue to ensure no
callback enters it via Js.from or Js.apply.

For Task, cover immediate and parked results of distinct types, nested waits,
independent schedulers, stale resumes, interruption, finalizer order, cleanup
failure and fatal deadlines. Pair before-and-after behavior with release goldens
for the direct path and suspension path. The full >250k LOC/s and runtime parity
measurements belong to the integrated implementation and run without concurrent
full gates on Dagon. Site counts and source line counts are not throughput or
allocation measurements.
