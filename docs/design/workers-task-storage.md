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
resources retain the generated native binding types; Runtime retains only the
parked sentinel and the owner-approved defect throw. Dequeue precedes
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

Suspendable work calls stay direct: the compiler creates their continuation
and sink before invoking the callee, then chains the returned value. No work
thunk or protocol invocation sits between recursive callers and callees.
Only the result host call of an in-place `Js.suspending` body receives its
completion; nested synchronous functions and earlier host calls do not.
Capability pruning debt, with the previous assertions in pending scenarios,
is tracked in #1670.

**Owner decisions D1 and D2, 2026-11-02: typed cells and nullable slots.**
`Js.Cell r` is a nominal mutable record, where `r` is a record row. Core and
platform packages may use it; ordinary packages may not name it or its
intrinsics. `Js.cell r` makes a fresh cell, copying an existing record's
fields (a literal is fused into that construction). `Js.cellRead c .field`
reads a field; `Js.cellWrite c value .field` stores a value of that field's
exact type. The selector must be a literal, single-field accessor (the
matching `λr → r.field` is also accepted). No arbitrary callback is run.
`cell` and `ref` are impure factories: their writable identity makes a top-level
polymorphic allocation invalid under checker-v2 §8.4. Js intrinsics require
qualified calls; dot-call dispatch cannot bypass selectors or access fences.
A cell never becomes an immutable record: record copy, record update and
structural comparison reject it. `Js.Ref` keeps its existing representation
and API. Cells remain typed storage for ownership, effects and realms;
a stored callable is charged to the writer. Wire rejects cells.

`Js.Opt a` is an unboxed optional. `Js.none ⊤` is the one private core sentinel; `Js.some x`
is `x`. `Js.optMatch slot missing present` calls `missing ⊤` when the
slot equals the sentinel and otherwise calls `present` with its value. Both callbacks
are sync. `Js.optWithDefault slot fallback` returns the value or fallback.
There is no unchecked extraction operation.

Opt's parameter retains a non-nesting constraint. A direct Opt payload,
including an alias or generic instantiation at one, is refused. Every other
type is admitted, including ⊤ and Js.Value: a foreign host may return undefined
for either, but it cannot forge the private sentinel. Records and lists
containing Opt are accepted. A wrapper used as an Opt payload stays boxed
when release unboxing could expose an empty inner Opt. The private absence
object is emitted once from core; empty fields explicitly store it, and
release hoists and shortens the constant. No Task, Chain, Hosted or Listen
migration belongs to this primitive slice.

The new intrinsics are compiler-owned in every position: a saturated call
is written in place, and a first-class use (except the field-selector
operations) becomes the equivalent typed function. They add no exports to
`Js.js`, whose development bytes therefore stay unchanged for existing
programs. Sibling export coverage excludes exactly these compiler-owned
names in core Js; user and platform foreign declarations keep all four
checks. The literal field-selector operations must be called directly.

A Cell's literal field set is fixed. Release field elimination must not
remove one of its initial fields and then leave stores that add that
property later: that would introduce extra hidden classes. Cell literals
carry a fixed-shape bit in the existing JsIr node flag byte. Copying and
suspension lowering preserve it; field elimination respects it. This does
not prevent the existing replacement of an entirely local object by lets.

First-class constructors are emitted once in core Js's generated module.
Every reference shares that function's identity across modules, and no
sibling is copied for such a use. Saturated calls still inline the operation.

**Owner decision, 2026-11-02:** core-only typed array primitives are approved
for List storage: allocate room, get/set elements, read length, complete a
builder, and wrap/unwrap a List view. Every signature retains the element
type. They are fenced by `resolve/CorePrivate.zig`, add no user surface, and
lower directly to native array operations. List's private builder, base,
offset and view operations use these alongside its existing indexed reads
and writes. No `Js.Buffer` is needed.

The native queueMicrotask, timeout/clearTimeout, optional Node setImmediate,
MessageChannel/MessagePort, Date.now and Math.random operations are generated
from the reviewed native catalogue. Task owns the macrotask FIFO, its lazy
channel and the typed timer canceller in beni. Runtime's sibling retains only
the parked identity and the exact defect throw: Js.throw takes Js.Value, so it
cannot throw a native Error without erasing that handle. No scheduler state or
host scheduling algorithm lives in that sibling.

**Owner decision, 2026-11-02 (replaces Key-only Dynamic):** one checked
existential, Any, serves core and platform machinery. `pack : a → Any` keeps
the real value and its compiler-supplied type identity; `unpack : Any → Maybe a`
returns Just only on an exact identity match. There is no compare constraint.
The compiler carries identity evidence for unconstrained quantifiers through
generic imports, helpers and local functions, only where Any is reached.
Existing constrained identities retain their ordering; quantifier-only slots
use the canonical scheme quantifier order. No method requirement is invented.

Stored-value effect edges retain callback purity, suspension and execution
realms through pack/unpack and generic helpers, without invoking the payload.
A storage type passes callback roles as type parameters: a generic carrier
keeps its comparer, listener, body, tagger and Any payload classes separate.
This avoids joining a dormant payload callback to the comparison function that
never invokes it. Hosted.Key uses Any; Tap/Relay retagging uses Any for event
payloads with no ordering requirement. CorePrivate.zig fences the envelope
from applications; HostFree and Wire refuse it, also through containers.
Schema's reportInput uses the data-only checked reporting conversion; reported
input never uses Any. Any's interface profiles keep distinct callback roles
through generic helpers and imports, including higher-order functions and
records containing callbacks with different suspension behavior.

Schema uses the same Any envelope internally for heterogeneous traversal data;
its reported Issue.input still comes only from the checked data conversion.
Generic schema values retain both endpoint identities. Source builders witness
those identities with empty typed lists, and generated producers derive the
same deterministic identity grammar from checked plan types and supplied
schema arguments. This is private metadata, not a new schema member argument
or public constraint. Compiled workers keep their exact input/output types and
return Maybe at the storage boundary. Generated adapters translate the
specialised traversal's failure marker. Validator reader and constructor
configuration is typed; only statically proven plain data crosses Js.Value.

**Owner decision, 2026-11-02:** Debug uses a borrowed read-only inspection
view, Raw, rather than converting arbitrary values to Js.Value. Raw is
Debug-only, cannot be retained in containers/cells/closures or returned from
formatting helpers, and is neither HostFree nor Wire. Field-name metadata,
kind/tag, fields/elements, length and scalar reads support formatting in
beni. Inspection reads data descriptors and never invokes a getter or a
function it finds; functions print `<function>`. Ancestor views identify
cycles without retaining views in a beni collection.
Inspection retains the existing representation-exposure bits for Debug's
borrowed input, so field names, constructor tags and boxing still match the
formatter's descriptor, also in the corpus's test-only release builds. This
is shape exposure, not a Js.Value conversion or a HostFree exemption.

**Worker event streams (2026-11-02):** the single-consumer stream retains
its payload, failure and `Task.Resume` types in one generic carrier. Its queue
uses the shared `Js.Chain` module. A synchronous typed acknowledgement callback
runs only when a value is handed to a consumer; storing a callable payload or
error never invokes it. The `Storage` carrier and acknowledgement installation
are platform-private.

**Node output and file waits (2026-11-02):** `Node.Program` is an opaque beni
value. `NodeRuntime.run` and `Io` consume it through typed readers; no Program
crosses `Js.Value`. Generated process operations perform output and exit-code
updates. File promises, rejection reasons, directory entries and abort resources
keep their native types. `Io` owns cancellation, directory ordering and the
specific documented error mapping in beni. Unknown rejections are rethrown
unchanged by the generated native operation.

**As built, 2026-11-02:** browser render queues, after-render jobs, waiting
resume capabilities and reentrant update jobs use typed Chain storage.
HTTP progress listeners also keep typed callbacks. HTTP's flight owns typed
native abort, timer and timeout-reason handles; promise results retain the
actual response, text or byte-read type. Native rejection handles remain
opaque through classification and are raised unchanged for unknown failures.
Generated bindings supply URL/Headers/FormData/fetch/response/stream/decoder
operations; the request, cancellation, timeout and progress logic stays beni.

**As built, 2026-11-02:** browser Storage keeps its native area in the generated
`Browser.Host.Storage.Storage` type. Its key accumulator is `List String`.
The generated adapters catch only the documented DOMException classes;
unknown thrown values retain their identity and remain defects.
