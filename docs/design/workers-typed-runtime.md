# Typed callback storage for worker realms

Specified 2026-10-30 for workers.md §4 and #1295. This specifies the selected
native-type design. Native handles and callbacks must retain ordinary types;
there is no runtime-wide Js.Value exemption. This document changes runtime
implementation structure, not source grammar or the fatal and suspension
contracts. Implementation status is recorded below as each bounded slice
lands. The first foundation checkpoint includes the typed Buffer primitive; the Inline queue
candidate remains unlanded pending performance validation.

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
allocation-neutral merely because the buffer itself has no wrapper. The always
initialized typed queue also makes one initial empty array and one replacement
empty array per detached batch; stop and defect reset it to an empty array.
The old nullable queue allocated its array only when nested work arrived. These
are additional queue-mechanics costs to include in the remaining parity work. No callback is converted to Js.Value
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
The unit argument to make is evaluated exactly once before allocation, including
its effects, defects and suspension. Ignoring its result does not permit dropping
the expression; intrinsic and first-class calls follow the same evaluation rule.
The callbacks are synchronous and invoked in FIFO order; callback defects propagate.
forEachWhile stops immediately when its callback returns False; no unvisited
element is passed to the callback. The dispatch drain uses this
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

A global queue denotes a realm-local runtime instance. Inferred realm-summary
seeds come only from writes reachable in that entry's execution graph. Do not
merge Window callback seeds into a worker's queue merely because both entries
reuse the same checked runtime declaration. Preserve symbolic callback storage
obligations in interfaces and instantiate them per entry, as workers-emission.md
specifies for globals, initializers and native binding dependencies.

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

## 5. First focused implementation checkpoint

The independently landable foundation checkpoint implements the typed Buffer
primitive, its generated sibling and core-override/authority checks, alongside
generic runtime metadata, the Session entry plan and the native catalogue. The
manager source review, full run-hash recording and full unfiltered gates passed
for foundation code commit d61f2d338.

The typed Inline queue and direct/via callback ABI are a reviewed candidate,
not included in this checkpoint. Existing Inline source, its generated ABI and
inline run hashes remain unchanged. The candidate passed the behavioral checks
recorded below but remains under performance validation; its mixed-type fixture
is held with that candidate. Normative queue and Task migration requirements
above are unchanged. Task continuation storage and remaining native callback
shims are not migrated. Public worker launch remains gated on the full C proof
and Wire implementation; no budget is waived.

Focused validation of the held queue candidate and the Buffer foundation used
the Zig development compiler, not a release-mode compiler. It passed the entire browser/inline corpus, the typed buffer corpus
in development and release output modes, and four separate black-box tests
for core override assets, module authority and ordinary custom Core.Js names.
The integrated browser/inline corpus also passed in real Chromium. The
4,096-message mixed Int and String fixture preserves FIFO, values and trailing-message order on two runs.
ReadDuringDispatch and StopMidDispatch retain their existing transcripts.
The emitted applyBatch uses a native for-of with a break after the stop guard.

The generated sibling's first-class forEachWhile fallback is exercised by the
earlyWith helper: it calls exactly three values and stops before the fourth.
A nonliteral callback-factory fixture also verifies array selection happens
before callback creation. Mutable length snapshots remain 0, 1 and 2 across
pushes. Direct, forwarded and while callbacks that suspend are refused with
complete sync_boundary diagnostics. The buffer remains inaccessible to ordinary
applications, while a separately resolved application Js.Buffer module works.

Generated sibling lookup was checked with a warm and cold cache. A missing
physical asset uses the generated implementation. An empty physical file wins
and receives the existing five foreign-export diagnostics. A dangling physical
symlink also wins and receives the existing missing-sibling diagnostic; it must
not be mistaken for absence. The symlink test failed before the no-follow stat
fix and passed after it. Failed builds write no entry output. The intrinsic
lookup separately excludes Buffer-only implementation names from Core.Js, so a
custom core ordinary makeBuffer function retains its ordinary meaning (#1339).

For the held queue candidate, the baseline 128902faf Debug compiler and the
changed Debug compiler produced these DispatchDeepKey release-output sizes.
These measurements describe the candidate, not code in the foundation checkpoint. The measurement concatenates the
sorted emitted .mjs files, excluding maps and HTML, and applies Brotli 1.2.0 at
quality 11 with identical options:

| Release output | Baseline | Typed queue | Difference |
|---|---:|---:|---:|
| Raw JavaScript bytes | 2,312 | 2,322 | +10 |
| Brotli bytes | 827 | 817 | −10 |

The changed compiler build identity was 12532ea7398a70b1e2ba045c40899980.
This small output comparison is not a throughput, allocation or parity result.
The additional closed thunk per nested send and the changed empty-buffer
allocation policy remain explicit runtime costs. No performance budget is
waived, and this does not claim that typed callback storage alone proves realms.
The typed primitive emit golden independently pins the direct array operations
and early break, with no type box, proxy or registration table.

## Checked generated body prerequisite

[workers-checked-control-bodies.md](workers-checked-control-bodies.md) specifies
the next actual source-body producer/ordinary-checker milestone. Typed signatures
or current Ref wrappers alone do not certify callback storage, ownership or the
sentinel ABI; production migration remains gated by section 3 above.
