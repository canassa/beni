# Web Workers in the browser platform

**Normative design, specified 2026-10-30; not implemented.** Tracking:
[#1290](https://github.com/canassa/beni/issues/1290). Unsettled owner decisions
below gate their dependent implementation; recommendations are not decisions.
The [research and inventory](research/workers-api-research.md) establish the
baseline. This document owns the compiler/runtime contract, not a claim that
all listed browser features have shipped. No production JavaScript is added:
runtime logic is beni over privileged `Js`; compiler changes are Zig.

## Open decisions for the owner

**Service Workers.** I recommend a separate design for registration, updates,
fetch interception, persistent storage and event lifetime, retaining their
complete inventoried surface here. They are not ordinary long-lived fibers:
the browser can stop and restart them between events. This recommendation does
not remove WebGPU's Worker exposure or prohibit sharing headless modules.
ServiceWorker entry implementation waits for this decision and its lifecycle
contract; DedicatedWorker and SharedWorker do not.

**Abrupt loss and shutdown deadlines.** I recommend cooperative cancellation
and finalizer completion for normal scoped shutdown, without a deadline that
silently calls `terminate`. An explicit destructive `Worker.abort` reports
`CleanupAbandoned`; it is available for hung/untrusted native work and program
fatal shutdown, not disguised as a successful scope close. A browser crash,
page discard or process kill cannot guarantee finalizers. A missing heartbeat
means `PeerUnresponsive`, not proof of death. Decide whether fatal shutdown's
existing deadline may abandon worker cleanup; normal scope semantics do not
change while this remains open.

**Shared-worker defect domain.** I recommend a defect in shared code stop the
shared instance and every attached beni page, with each page rendering/logging
its own defect. A page's ordinary shutdown closes only its connection scope;
it cannot close other pages' scopes. This preserves the fatal-defect guarantee
without giving an ordinary client the ability to terminate other clients.

**Proposal-only transfer types.** The inventory includes every WebRef
serializable/transferable type, including WICG and editor-only proposals.
I recommend implementing the standard family adapters first, leaving
proposal-only adapters explicitly gated by their owning specification and
availability, rather than claiming universal availability or silently dropping
them. The coverage issue must account for every inventoried row before any
claim of complete transfer support.

## 1. One platform, multiple realms

The owner's one-platform rule is binding. A build selects exactly one platform
chain. The browser chain currently named `browser-inline` is the target;
[#966](https://github.com/canassa/beni/issues/966) retires the older `browser-tea`
and `dom` lowering. Capabilities belong in the browser base that decision
specifies, not in either old renderer. The platform ultimately takes the name
`browser`; do not add a `web-worker` platform or reuse Cloudflare's `Worker`.
Public worker modules are `Browser.Worker`, `Browser.SharedWorker`,
`Browser.MessagePort`, `Browser.BroadcastChannel`, `Browser.WorkerGlobal`,
`Browser.WorkerPool` and `Browser.WorkerStream`. Shared binary/source handles
are `Binary.Buffer`, `Binary.SharedBuffer`, `Binary.View`, `Binary.Source`,
`Browser.Image`, `Browser.Video`, `Browser.Canvas` as coordinated with #1278.
The contracts use qualified `Worker` as shorthand for `Browser.Worker`.

Entry realms are `window`, `dedicated-worker`, `shared-worker`, with
`service-worker` reserved for the separate lifecycle decision. `WorkerLocation`
is read-only URL information, not navigation. Workers have `self`, no `window`
or `document`; no DOM nodes, local/session storage, history or page navigation.
Worker-only availability is not the same as browser feature availability:
realm checking is static; feature/isolation/permission checks remain dynamic.

## 2. Program shape and entry discovery

Worker programs are ordinary top-level values constructed by platform code.
No new general language declaration or application `foreign` is introduced.
The following is a proposed API sketch, not currently compilable beni:

```text
-- Jobs.beni
pub program : Worker.Program Request Reply Failure
program = Worker.program { handle = handle }

handle : Request → Result Failure Reply
-- The body may suspend; program construction may not.

-- page code, after importing Jobs
worker = Worker.open scope Jobs.program options
reply = Worker.call worker request
```

`Worker.program` accepts an `entry` record whose handler is called once per
request in its own scoped fiber. Its three type parameters are closed input,
success and application-error types. Its constructor returns an opaque entry
descriptor, not a runtime closure that the page serializes. `Worker.open`
accepts that descriptor as a typed `Worker.Entry request reply failure` view;
the coercion is compiler-owned and only applies to a statically resolved
program declaration. `Worker.open` suspends through readiness and returns
`Result OpenError (Worker.Handle request reply failure)` owned by `scope`.
`Worker.call` suspends and returns `Result (CallError failure) reply`.
`CallError failure = Application failure | Transport TransportError` separates
application errors from channel failures. Neither contains a defect variant.

The app manifest gains `workers`, an object from logical entry name to
`{ "module": "Jobs", "value": "program", "kind": "dedicated" }`; shared
entries use `"kind": "shared"` and `SharedWorker.program`. This explicit list
is the complete emitted worker set, even when a page reference is unreachable.
Keys are nonempty ASCII letters/digits/underscore/hyphen, case-insensitively
unique. Module/value resolution follows normal package identity; duplicate
references to the same declaration share one entry, with duplicate manifest
aliases refused to keep public identity unambiguous. A page may select among
typed entry descriptors at runtime, but cannot turn an arbitrary URL/closure
into a compiler-checked entry. The native URL constructor remains available
through a separate external endpoint API with a schema-validated protocol;
its code is not asserted to be beni or same-build typed.

A worker's code is reachable from its manifest declaration, not by following
that descriptor's handlers while compiling the page. `main` remains unique
for the page. Worker modules use `program`, so their declarations never count
as additional `main`s. A second ordinary `main` is still `duplicate_main`.
`--library` emits no launchable entries. `check` validates registered workers,
contracts and realm reachability as `build` does; a standalone library check
exports its unresolved realm/codec obligations to consumers.

The optional headless state-machine constructor follows Elm's useful shape:
`init`, `update`, `subscriptions`, without `view`, implemented over the same
scopes and mailbox. It is a library adapter, not Elm ports or a second wire
protocol. No finalizer or handler closes over state in another realm.

## 3. Output, runtime entry and determinism

Development writes the page `_main.mjs`, workers
`_workers/<logical-name>/_main.mjs`, each entry's reachable app modules and
platform wrappers, and `_core/` where a realm-independent emitted module can
be shared safely. Each entry URL is resolved relative to the generated module
that owns the descriptor, using compiler-generated module-relative URL code;
it must work below a hashed `<base>`, nested routes and a relocated output
directory. There is no user-written loader or bundler configuration.
`WorkerOptions.type` is always `module` for beni entries; `name` and
`credentials` (`omit`, `same-origin`, `include`) are exposed. External endpoints
can describe classic scripts; the compiler never emits classic beni workers.
Shared options also retain `extendedLifetime` (default false) and the legacy
string-name overload through a convenience constructor.

A runtime contract independent of `markup.module` is still required by #1287.
The platform declares an `entryRuntimes` table keyed by realm, containing a
program type and a beni module with a `pub run` body. Its checked signature is
`Program … → ⊤`, impure but non-suspending: it creates the root scope, installs
listeners and starts fibers, then returns. Validation uses the instantiated
program type, arity, effect and ownership summaries; the runtime and its
required hooks are DCE roots. The worker runtime needs no markup union,
`start` template table, DOM flush or HTML shell. A page keeps its existing
markup runtime and lifecycle hooks. Missing/ambiguous realm runtimes are
manifest diagnostics before output. Existing file-runtime contracts remain
unchanged; workers never use a hand-written `runtime.js`.

Realm checking includes the runtime root and every module initializer.
Reachability is per entry, including callback/evidence/derived-code edges and
foreign sibling dependencies. Identical bytes may be stored once, but module
state is instantiated separately by each JavaScript realm. Sharing output
paths must not cause an entry to evaluate page-only top-level code. If a source
module mixes such code, emit realm-specific projections under the entry's
reserved subtree; do not ship a union of side-effecting initializers.

Release optimizes each entry's reachable graph independently. Within an entry,
record/tag renaming remains legal; across messages use the canonical codec in
§5, never independent minifiers' field/tag integers. Shared chunks are optional
only when their initialization and realm requirements are identical. No page
bundle contains worker implementation merely to obtain its descriptor. A
release build rejects reachable `Debug` in any entry before writing anything.
Development maps each generated module to its source; release
`--source-maps` maps each entry/chunk and includes worker origin in diagnostics.

Assign entry IDs before parallel work from package identity, sorted logical
name and module/declaration identity. Paths, protocol fingerprints, field
orders and diagnostics must not depend on checkout path, timestamp, process
ID or completion order. Apply the existing ASCII-folded collision check to
**all** entries, modules, chunks and maps before writing. Runtime instance and
request IDs are separate from reproducible build IDs. Determinism fixtures
compare jobs 1/8, twice, across different absolute checkout paths.

## 4. Realm checking and privileged declarations

Realm summaries are a separate constraint from impurity/suspension and
ownership. Each callable/value has the set of realms in which it can run;
composition intersects requirements. A pure helper begins at all realms;
reaching a window-only primitive narrows it. Nominal opaque types carry realm
exposure too, so storing, constructing or invoking a DOM handle in worker code
is rejected even through generic callbacks, static-dispatch evidence, aliases,
closures, records and reexports. Unreachable declaration bodies do not reject
an entry, but an evaluated module initializer does.

Core and platform packages declare boundary exposure in a `realms` manifest
map keyed by fully qualified foreign declaration. Values are explicit realm
sets; `all` means no host realm restriction, not permission to access any
host global. This avoids an unreviewed language syntax extension. Every
host-dependent foreign needs a row; opaque types need both exposure and
clone/transfer metadata. Core math/data primitives are `all`; host dispatch
primitives are privileged implementation machinery. A `Js.global`/`get`/call
chain must inherit a checked platform wrapper declaration's exposure. Dynamic
host-name calls need an explicit audited exposure contract, never default
`all`. A leaf manifest cannot widen a dependency's declared exposure.

For beni platform wrappers, realm declarations in the same map are checked
upper bounds on inferred summaries, not assertions that hide their calls.
Privileged host-dispatch internals are audited against their declared host
operations. Ordinary application modules cannot write this map to grant new
capabilities. Host feature tests do not authorize DOM use in a worker;
compile-time realm-specialized platform branches may narrow a guarded branch
only if the compiler proves the realm predicate. The existing platform-wide
`host: page` optimization becomes entry-specific: no worker projection can
emit bare `window` because it inherited a page platform manifest.

Persist summaries, foreign metadata, descriptor types and codec fingerprints
in interfaces/cache keys; invalidate consumers when any changes. Recursive
call SCCs reach a fixed point, deterministic in module order. Generic
instantiations retain obligations; higher-order callbacks contribute their
requirements at each call. A library cannot erase a restriction by exporting
an unannotated wrapper. `dump` displays entry roots and inferred realm sets.

| Code and reporting site | Required diagnostic content |
|---|---|
| `worker_realm_violation`, first illegal use reachable from the entry | “This worker reaches a Window-only operation.” Name the entry, unavailable operation/type, allowed realms and shortest deterministic call/import-initializer chain; point to the platform boundary declaration. Suggest moving the operation to the page and sending data. |
| `worker_entry_not_static`, offending descriptor expression | “A worker entry must name a registered top-level program.” Name the value and registration fix. |
| `worker_entry_type_mismatch`, registered value | Expected realm program type and actual type, including input/reply/error disagreement. |
| `invalid_worker_entry`, app manifest at 1:1 | Missing module/value, invalid/duplicate name, unsupported kind or duplicate declaration; show exact manifest key. |
| `invalid_entry_runtime`, platform manifest at 1:1 | Realm, module, required export/type/rung and actual value or missing declaration. |
| `missing_realm_contract`, privileged declaration | Name host-dependent primitive/type and missing exposure row. |
| `worker_message_not_serializable`, message/entry type use | Show the shortest field/type path to a function, DOM value, fiber or unregistered opaque resource; name a schema conversion where possible. |
| `worker_transfer_alias_live`, move site | Show moved backing resource, every live alias/view/captured path and later use. Request an explicit copy or moving all ownership, never silently copy. |
| `worker_transfer_not_supported`, transfer/schema annotation | Name the type, required realm or transfer-only/clone-only mismatch. |

## 5. Messages, schemas and ownership

The type-level judgment `Wire T` is derived structurally for unit, booleans,
strings, numeric primitives, tuples, records, finite lists and tagged unions
whose fields satisfy it; recursive definitions use a memoized fixed point.
Functions, fibers, scopes, resume handles, DOM nodes and raw `Js.Value` do not.
Opaque types require the owning privileged module's codec and exposure row.
Unconstrained type variables retain `Wire` obligations in interfaces; they
are not assumed serializable. This is compiler evidence, not a user-defined
method that can claim a closure is safe. A closed program's request, reply
and failure types are checked together at registration and every handle use.

Beni representations are not structured-clone representations. In particular
list views, dictionaries, hidden nominal machinery and release field/tag
renaming require codecs. Encode to a canonical host envelope with ordered
field/tag IDs derived from the type graph, explicit integer/float conventions
and builtin native payload slots. Preserve negative zero, NaN/infinities and
exact binary words; no JSON stringification as a transport. Decode produces
the receiving build's ordinary representation. Same-build endpoints exchange
build/protocol/type fingerprints before admitting messages. External channels
use schema validation and explicit protocol versions; no native `any` escapes.

A schema's `Type` is the application endpoint, `Encoded` its typed beni
intermediate, not the host representation (`schema.md` §1). A wire schema
composes directional conversions with the canonical codec; both success and
failure conversions remain checked. A request carrying a closure can be
accepted only if an explicit conversion removes it and its receiver type
matches the reconstructed type. Arbitrary `Schema` callbacks that suspend run
in a preparation fiber; `postMessage` and the final native encoding/transfer
commit remain synchronous. `send` is impure and accepts an already prepared
wire value, or a codec proven `sync`; `call` may prepare asynchronously.

A transfer annotation on a native-resource field supplies a collector during
encoding. It records the native object and backing identity, never an
arbitrary application-provided host array. Repeated references to one resource
are encoded with one transfer-list entry, preserving alias identity on the
receiver; a transfer-only object omitted from the message graph is refused.
A buffer view transfers its backing buffer and invalidates **all** aliases
and views, not just the selected byte range. An explicit slice/copy is required
to retain bytes locally. `SharedBuffer` is shared, never transferred or
represented as ordinary immutable owned storage.

Transfer is a resource demand in the ownership checker, distinct from a
record edit. It consumes the resource at the native commit attempt and
rejects any live alias in a later expression, branch, callback, fiber, model
or exported value. Preparation holds exclusive ownership until commit or
cancellation. Preparation failures before native commit can return the owned
value explicitly; after commit begins, no error arm promises the original
resources back. A reservation retains privileged cleanup references until
commit settles: on failure it releases/closes every still-local resource using
its owning module's exact native-state predicate, without attempting to close
successfully transferred receiver resources. Cleanup faults follow the defect
path; closed/moved states are idempotent cleanup cases, not broadly swallowed
exceptions. Application aliases remain consumed even if some native resources
never detached. Native transfer steps can partially detach a transfer list
before a later entry fails: conservatively consume the whole attempted list
and mark all wrapper generations invalid, even on `Err`. Dynamic imported
resources still get exact state checks; a static proof does not make a
closed native handle usable. Resource state lives in shared backing metadata,
not per-wrapper copied booleans. A send that transfers succeeds at serialization,
not at delivery; cancellation cannot retract it or restore ownership.

`Binary` owns buffer/view/atomic state; `Browser.Image` owns ImageBitmap and
ImageData; `Browser.Video` owns VideoFrame; `Browser.Canvas` owns offscreen
canvas state. These are #1278's types, not worker-specific replacements.
GPU device/queue/buffer/texture handles have no wire instance. Standard
serializable GPU diagnostics do; OffscreenCanvas must be transferred before
creating its rendering context. All other native wire types are accounted for
in the research's type matrix and transfer-family slice, including transfer
streams, ports and same-agent-cluster restrictions.

## 6. Native API adapters and precise failures

The research §9 native-family failure predicates are also normative for
this design; they are not deferred classifier design. The inventory is the
surface checklist, including inherited members, both
postMessage overloads, options dictionaries and event payloads. Common
EventTarget operations are typed scoped observers: remove on scope close,
`once`/abort semantics retained, without arbitrary native event dispatch
masquerading as a worker result. `MessageEvent` retains origin, lastEventId,
source and transferred ports where applicable. `ErrorEvent` retains message,
filename, line, column and optional error data for the defect reporter.
Unknown event payloads/protocol variants from a compiler-owned peer are
invariant defects; external schema rejection is `ProtocolRejected issues`.

For each catch below, the guard surrounds **only the native operation**, not
preparation, user callbacks or decoding. DOM failures require a native
DOMException with the exact name; ECMAScript failures require the named class.
Unmatched throws/rejections are rethrown into the fatal defect path. Event
failures are checked by event type and lifecycle state, not exception-message
substring matching. The public error names in this section denote closed operation-specific ADT
variants, including preparation/transport errors and the cleanup outcome below.
No `UnknownError`, broad catch or universal promise catch
is permitted. `Js.catchIf` already supplies precise rethrowing; do not invent
a JavaScript helper. Native algorithms and failure anchors are in the research.

| Operation | Exact check and typed outcome |
|---|---|
| `Worker.open` / shared connect, capability check | Constructor absent or module-worker capability unavailable → `UnsupportedWorkerKind`; capability records distinguish dedicated/shared/module. No silent classic fallback. |
| Worker / SharedWorker constructor | DOMException `SyntaxError` → `InvalidScriptUrl`; DOMException `SecurityError` where the host enforces a constructor security restriction → `WorkerSecurityDenied`. Constructor `TypeError` at the Trusted Types sink, with validated option types and wrapper-owned policy → `TrustedScriptUrlRejected`. Never catch TypeError around arbitrary user policy execution. |
| SharedWorker constructor | Standard `SecurityError` for forbidden storage-key access → `SharedStorageDenied`; distinguish by the shared operation's documented predicate rather than inventing a reason from the message. |
| Open before Ready | Native `error` whose interface is Event but not ErrorEvent → `WorkerLoadFailed` with opaque event metadata; readiness deadline → `ReadyDeadlineExceeded`; explicit lifecycle disconnect → `ClosedBeforeReady`. CSP/COEP/CORS/network/MIME/module-fetch errors may be indistinguishable here and are not fictional enum cases. |
| Worker/global/port `postMessage`, `structuredClone` | DOMException `DataCloneError` → operation-specific `WorkerCloneRejected`, `PortCloneRejected`, or `CloneRejected`; field path/resource states collected before the call may refine the reason, but never infer a hidden native reason. |
| OffscreenCanvas native transfer inside postMessage/structuredClone | DOMException `InvalidStateError` from that operation with a canvas transfer present → `CanvasTransferInvalidState`; precheck context mode through the owning wrapper gives `CanvasHasContext`. This native transfer failure is not DataCloneError. |
| Clone/transfer preparation | Known detached backing → `DetachedBuffer`; out-of-bounds resized view → `ViewOutOfBounds`; closed frame/audio/bitmap → `ClosedResource`; locked stream → `StreamLocked`; canvas context already selected → `CanvasHasContext`; self-transfer of sending port → `SendingPortTransferred`; invalid exposed target realm → `TargetRealmUnavailable`. Native residual DataCloneError and the specified OffscreenCanvas InvalidStateError remain typed. |
| Port `start`, `close`; Worker `terminate`; worker-global `close` | Native calls define no expected synchronous exception for valid typed receivers. An unexpected throw is a defect. Managed closed/moved state yields `PortClosed` / `PortMoved` before send; these are beni lifecycle checks, not invented native throws. |
| Any receiving message target | `messageerror` → `MessageDeserializationFailed`, delivered to waiting callers/receive observer and closing the unusable managed channel. This listener is required on both sides, including SharedWorker's port and BroadcastChannel. |
| Broadcast construction/send | Native constructor storage-key `SecurityError` → `BroadcastStorageDenied`; send `InvalidStateError` → `BroadcastClosed`; send `DataCloneError` → `BroadcastCloneRejected`. Broadcast has no transfer list. No delivery acknowledgment is implied. |
| `importScripts` | Module realm makes this unavailable with `module_worker_import_scripts`; classic external code's `SyntaxError`, `NetworkError`, Trusted Types `TypeError` are inventoried, not wrapped into a usable beni module-worker operation. Ordinary static imports replace it. |
| Worker-global animation-frame request | Dedicated-worker support predicate false / native `NotSupportedError` → `AnimationFrameUnavailable`; shared workers do not gain the member. Cancel has no expected native throw. |
| Shared memory/Atomics | Isolation/constructor availability → `SharedMemoryUnavailable`; invalid integer view kind → `AtomicViewKind`; invalid index → `AtomicIndexOutOfBounds`; non-shared wait view → `WaitRequiresShared`; unavailable host blocking permission → `BlockingWaitForbidden`; native wait outcomes map to `Woken`, `NotEqual`, `TimedOut`. Checked wrappers consume documented TypeError/RangeError only at the corresponding validated operation. |
| Protocol liveness | Caller-visible closed connection → `ChannelClosed`; lease deadline → `PeerUnresponsive`; bounded queue refusal → `QueueFull`; externally received schema mismatch → `ProtocolRejected issues`; same-build fingerprint mismatch → `ProtocolVersionMismatch` at handshake, before work runs. |

Trusted Types policy callbacks run outside the constructor exception guard.
The platform accepts an explicit branded script URL produced by a beni policy
that returns typed refusal before entering the host callback. If a host default
policy exists, resolve it before the constructor guard; any callback exception
is a defect, including TypeError. Pass the resulting TrustedScriptURL to the
constructor, so that call cannot execute arbitrary policy code under the
TrustedScriptUrlRejected classifier. With no policy, a validated string's
sink rejection is classified at the native constructor. The native trustedTypes.createPolicy call has a separate guard: its
TypeError becomes TrustedPolicyDenied (duplicate/disallowed name cannot be
distinguished unless independently known); missing trustedTypes becomes
TrustedTypesUnavailable for explicitly requested policies. Its platform-owned
callback is total and returns an already validated string. Explicit foreign
TrustedScriptURL intake requires trustedTypes.isScriptURL validation; failed
validation is NotTrustedScriptUrl. No policy is silently
created to bypass deployment CSP; the platform's typed policy configuration
must work under the site's allowed policy names. The implementation slice
includes typed policy refusal, a policy-thrown TypeError defect and denied
policy creation fixtures.

`SecurityError` at shared construction has the operation-specific shared name;
there is no fabricated distinction between indistinguishable security causes.
Deployment diagnostics can show the URL and advise checking worker-src,
script-src/default-src fallback, module Content-Type, CORS and COEP, but must
label those as possible causes. Any native ErrorEvent, including one with `error == null`, is a program
defect before or after Ready; HTML clears the error object when forwarding
worker exceptions to owners. Test the event interface, never error-object
presence. A generic native Event named error before Ready is WorkerLoadFailed;
unhandled rejection, Defect frame or any error after Ready is fatal. Muted
ErrorEvent metadata remains a defect with limited diagnostics. A host that
does not preserve these standard event distinctions needs an explicit
compatibility finding, not a payload-presence heuristic.

All bytes/URL/source wrappers must document their own acquisition failures;
worker transport adds no blanket classifier to them. Expected serialization
errors cannot arise from ordinary structurally checked immutable data but
remain possible from native resource state, agent-cluster restrictions,
security and browser support. A raw host getter or proxy is never accepted as
a beni wire record. External validation must not invoke untrusted accessors.

## 7. Handshake, requests, exits and defect routing

Each spawned instance installs the parent error/message/messageerror listeners
immediately, before awaiting readiness. A small compiler-generated worker
entry initializes the beni platform bootstrap before loading/evaluating the
user program (dynamic module loading emitted by Zig, not handwritten JS).
The bootstrap installs global error and unhandledrejection reporting before
that evaluation; exceptions outside its reach remain visible through the
parent native Worker error listener. The runtime needs a compiler-supported
bootstrap/import staging contract; static sibling imports alone are too early.
A failed bootstrap fetch remains `WorkerLoadFailed`, honestly opaque.

The transport envelope has protocol/build fingerprint, instance generation,
connection ID, request ID and a discriminated body. Control messages are
Hello, Ready, Request, Reply, Interrupt, Interrupted, Close, Closed, Defect,
Ping, Pong, Chunk, Ack End and TransportFailure. IDs are monotonically allocated within an
instance/connection and never reused while a reply/tombstone can exist;
rollover creates a new generation. Decoder limits cover depth, frame bytes,
queued requests and chunk credits. No unbounded pre-ready buffer.

Ready means error/close/messageerror listeners and handler scopes exist,
protocol/type identities match, and init has completed successfully. `open`
races this event against explicit failure, cancellation and a finite configured
startup deadline. It never waits only on a latch when the worker may already
have failed. Failure or interruption before Ready transitions Starting → Closing. If no
runtime acknowledgment arrives by the finite cleanup-observation deadline,
it transitions to Lost, not Closed. `open`'s failure contains the original
OpenError and `CleanupUnconfirmed` (or `CleanupConfirmed` after Closed), and
returns without waiting forever for an impossible acknowledgment. The runtime
keeps any still-live native handle in a bounded orphan registry owned by the
program, stops admission and requests close; it does not claim finalizers ran
or automatically terminate it. Reaching the orphan bound refuses new opens.
A graceful close whose peer is Lost likewise returns an abnormal cleanup
outcome, never success. An implicit Task.scope finalizer that observes CleanupUnconfirmed enters
the existing fatal defect shutdown path: its return type remains ⊤, and it
cannot complete normally or extend Task.Exit. Explicit open/low-level close
return the typed cleanup status for the caller to inspect. The owner decision governs
whether the program's explicit fatal-stop policy then aborts those handles.
Fixtures must cover deadline/error before Ready followed by no Closed at all.

Request captures its caller's serializable Log annotations, minimum level,
trace/span IDs and parent span, but not sink functions, clocks, random mutable
state or live fiber references. The receiver installs those values in its
handler fiber slots and restores context when the handler ends. Child spans
are local children of the transmitted parent. If logs are forwarded, a
separate typed diagnostic stream preserves origin; Log sinks remain page-local.

Wire Reply is a full encoded exit: Success payload, Failure typed payload,
Interrupt, or Defect report. Success/Failure correspond to
`Done (Ok value)` / `Done (Err error)`; Interrupt corresponds to `Cancelled`.
Defect is a **private runtime control case**, never an extension of public
`Task.Exit` or an `Err`. The parent reports it through its existing program
fatal path, stops intake, cancels its roots and closes all owned worker scopes.
Workers forward defects from unrequested/background fibers too. Nested
workers route defects up their ownership chain. A defect cannot be swallowed
by dropping the awaiting fiber or closing its reply slot.

Defect transport carries only bounded serializable metadata (message, original
stack/source location, entry/realm, span, causal ID). A failure to send this
report is itself reported through the native error path; never serialize an
arbitrary thrown host object. Fatal shutdown preserves the first defect and
logs later cleanup defects separately. In development the page shows its
crash screen; in release it logs and stops. There is no worker-only console
error while the page silently continues.

## 8. Cancellation, scopes and lifecycle

`send` performs synchronous serialization and returns, impure. Native delivery
is a later message task, FIFO for a channel; scheduling between channels is
unspecified. `receive`, `call`, `open`, stream pull and graceful close suspend.
No synchronous RPC, busy waiting, or main-thread `Atomics.wait`.

Each request is a child of its connection scope. Interrupting the waiting
fiber sends Interrupt, latches cancellation on the handler and awaits
Interrupted/terminal Reply **after** child cancellation and finalizers. A reply
that won the race settles once; later replies/interrupts are idempotent via
terminal tombstones. Side effects already performed and transferred bytes
cannot be undone. Unknown current-generation IDs are protocol defects on a
trusted managed channel; stale-generation frames are discarded after closing
the old connection. Cancellation has a reserved control path so a full data
queue/stream credit window cannot block it.

Graceful close stops admitting requests, cancels outstanding handlers, waits
for their cleanup, closes descendants, runs root finalizers, sends Closed,
then calls global `close`. The parent drops ports/listeners after Closed, or
a separately reported lost-peer transition; only Closed proves cleanup.
`terminate` is never the normal scope finalizer. Explicit abort uses the native
operation and marks outstanding requests `CleanupAbandoned`; it is not
graceful cancellation or a successful finalizer guarantee. A native process
crash may supply no exit event: configured heartbeats/deadlines end waits as
unresponsive without asserting that cleanup completed. A timeout cannot force
a synchronous infinite handler to process Interrupt.

When a page stops normally, it executes this shutdown for dedicated workers
and closes its shared connections. Page discard/navigation/OS kill cannot
promise asynchronous finalizers; pagehide/visibility signals are best-effort
notifications, not acknowledgment. Shared connections use renewable leases;
expired leases cancel that client's scope, without deleting other clients.
A suspended page is unresponsive, not proved dead. Shared workers retain the
native origin/storage-partition/name/URL/options identity, with build identity
in the generated URL/name to prevent accidental cross-version reuse. Multiple
clients get separate connection IDs, quotas and scopes; the worker calls
`close` only after its last connection/root work closes under its chosen
lifetime policy. `extendedLifetime` is a request to the browser, no guarantee.

`Task` scheduler state remains module-local in each realm. In browsers it
uses MessageChannel for macrotask yielding and queueMicrotask for drain;
setImmediate is detected for hosts that supply it, not assumed in workers.
A worker-local fiber cannot be joined in another realm. `Handle` represents
a protocol peer, never a cross-thread Fiber.

## 9. Ports, broadcasts, shared memory, pools and streams

MessageChannel creates two dual typed endpoints (`send A / receive B` and
`send B / receive A`) inside a scope. The managed observer attaches listeners
then explicitly starts the port; setting onmessage's implicit start is not
relied on. Native `start` and `close` remain available as lifecycle operations.
Transferring a port moves the endpoint and its protocol role, not its active
local callback/scope. `prepareMove` atomically checks no in-flight requests or listener fibers,
stops local dispatch/removes observers and takes the endpoint's cleanup
registration out of its source scope into a move reservation. Thus ports made
by `channel` can actually move; an attached managed finalizer is rehomed, not
an unconditional refusal. Active request/listener work yields `PortBusy`.
Before native commit, failure/cancellation restores the registration and
listeners if the source scope is open, otherwise closes the endpoint. Once
commit starts the source registration is consumed; the move reservation owns
cleanup of any still-local native endpoint until outcome is known. Queued native messages stay subject to native semantics,
not a fabricated empty queue claim. The receiver adopts the new endpoint into
its own scope before starting it. Transferring a port to itself is refused;
transferring an entangled peer cannot be described as guaranteed delivery.

BroadcastChannel is named and storage-partition scoped. It does not send to
itself, has no transfer list and no total order across senders. A channel name
is not proof of a shared type: explicit schemas validate messages from other
pages/builds. SharedArrayBuffer and same-agent-cluster resources cannot be
assumed deliverable to every broadcast recipient; `messageerror` is surfaced.

Shared memory is an explicit mutable resource outside ordinary beni immutable
values. `Binary` owns fixed/resizable/growable backing and exact integer-view
semantics. `crossOriginIsolated` plus feature checks gate construction/sharing;
SAB is cloned as shared storage only inside the same agent cluster, never
listed for transfer. Atomic load/store/add/sub/and/or/xor/exchange/
compareExchange/isLockFree/notify/wait/waitAsync/pause are inventoried in BCD/ECMAScript; each typed view retains its integer
kind and exact Word64 values. `waitAsync` suspends a fiber; cancellation removes
its continuation and safely ignores the later native resolution (there is no
native cancel-waitAsync promise). Blocking wait is an explicitly worker-only
low-level operation, with its starvation implications documented, not the
implementation of `call` or stream back-pressure.

A fixed pool owns a positive number of dedicated workers, a bounded admission
queue and a positive per-worker concurrency. An elastic pool adds min/max,
idle time and target utilization, all validated for finite/range values.
Selection uses queued-plus-running load with stable round-robin ties; measure
before introducing more machinery. Requests are never replayed after worker
loss unless the user explicitly provides an idempotent retry policy and owns
a replayable copy of inputs. A moved transfer cannot be resent. Pool retirement
waits for idle scope cleanup; shrink does not kill active finalizers. A defect
is fatal to the owning program, not a reason for transparent worker respawn.
Transient open failures may be retried by an explicit policy, within bounds.

Streams use scoped request IDs with monotonic chunk sequences and finite
credits. Ack is sent when the consumer releases/consumes a chunk, not when the
message event merely arrives. Producers suspend when credits run out; End
carries a typed success/failure/interrupt exit, with Defect on the control path. A Reply/Chunk preparation or native send
failure first ends the handler/producer scope, then sends a bounded primitive
TransportFailure frame naming the operation-specific error. This frame carries
no resource transfers or user codecs and settles the caller once. If this
control send fails, the native defect/lost-peer path settles the connection;
it never retries the moved payload or leaves a reply slot silently parked.
Cancel unblocks both producer and consumer and waits for cleanup. Limit bytes
as well as chunk count. Ping/Pong leases monitor otherwise idle channels;
control messages bypass data credit limits but are rate bounded. Native
Readable/Writable/TransformStream transfers use their standard transfer steps,
including locked-state failures; the beni streaming protocol is not falsely
presented as the same native object operation.

## 10. Verification and measurements owed

No implementation or browser performance claim is made by this document.
Every slice lands with black-box fixtures and its diagnostic transcripts.
`zig build gates` proves compiler checks, canonical codec round trips,
ownership rejections, interface invalidation, output shape and deterministic
jobs 1/8 builds, and the Node-executable protocol state machine. Node workers
are not a substitute for browser workers. happy-dom can drive UI/observer
wiring; it cannot prove module-worker loading, CSP/COEP/CORS, agent clusters,
real detachment, SharedWorker sharing, scheduling or termination semantics.

`zig build test-browser` must run real headless Chrome with controlled HTTP
origins, headers and MIME types. Required cases: ready success; error/death
before ready; module import/evaluation defect and post-ready defect reaching
the page; wrong MIME, missing script, CSP worker-src fallback, COEP/CORS,
Trusted Types with and without permitted policy; dedicated and shared module
entries; duplicate shared names/options; multiple clients and one disappearing;
messageerror on every endpoint; FIFO; cancellation/reply races; child/finalizer
order; page shutdown; lease expiry; explicit abort; release crash reporting.
Run positive and negative isolation headers for SAB; main-thread blocking-wait
refusal; all transfer families, invalid state and partial-detachment failure;
all typed array kinds and views sharing backing; worker WebGPU with transferred
OffscreenCanvas and VideoFrame where supported. Unsupported capabilities are
asserted as typed outcomes and recorded as skipped conformance evidence,
never a pass for unavailable behavior. Add Firefox/WebKit runs for cross-engine
claims, especially shared module workers and newer transfer types.

Each diagnostic in §4 and importScripts refusal gets direct and indirect
fixtures, including generic/static-dispatch/closure/reexport and cached-library
paths. Every error row gets an expected native failure and an unanticipated
throw fixture proving the defect escapes; synthetic host fault injection is
supplemental evidence, not a browser conformance result. Protocol properties
are checked independently of the implementation: exactly one terminal exit,
no accepted work after close, bounded queues, no data-credit deadlock on cancel,
no double transfer, no realm escape through dead-code/initializer differences.

Measure raw/minified/brotli bytes for empty page, one worker, two workers,
shared worker and pool, both marginal per-entry bytes and total unique bytes;
list `_core/` sharing and maps separately. Measure cold/warm spawn-to-ready,
round-trip median/p95/p99 (empty, small record, large cloned bytes and moved
bytes), throughput under concurrent load, allocations, main-thread frame
stalls, stream memory at slow consumption and cancellation-to-finalizer latency.
Report machine/browser/version, payload sizes, sample counts and harness;
compare native module-worker baseline and pinned Effect v4 on the same setup.
No target or parity result is invented before measuring. Gates and browser
measurements must not run concurrently with another full suite on Dagon.

## 11. Independently landable implementation order

| Slice | Depends on | Done |
|---|---|---|
| Entry runtime contract | This design | #1287 generalized to realm runtime table, precise program/arity/effect diagnostics and no markup dependency; dev/release fixtures. |
| Multi-entry emission and bootstrap | Runtime contract | Manifest descriptors, canonical IDs, staged defect bootstrap, relative URLs, per-entry roots/maps/collisions and jobs 1/8 output fixtures; never user JS. |
| Realm checking | Multi-entry roots | Exposure metadata, transitive summaries/cache invalidation, initializer and host:page handling, every §4 realm fixture. Worker builds cannot ship without this gate. |
| Wire codecs and ownership moves | Realm check; #1278 | Cross-entry type evidence, canonical release-safe schema codecs, backing alias demands and partial-failure consumption; negative and round-trip corpus. |
| Dedicated runtime and defects | Prior compiler slices | Precise native errors, bounded ready handshake, requests/exits/Log, cancellation/scopes and page defect routing proven in Chrome. |
| Ports, shared workers and broadcast | Dedicated protocol | All inventoried options/overloads/events, shared leases/connection scopes, external schema validation, cross-tab and messageerror fixtures. |
| Native transfer families and atomics | Wire ownership; #1278/#1277 | Every standard type row assigned, implemented and browser-tested or explicit capability refusal; GPU integration, shared memory and typed exact failure coverage. Proposal rows remain visibly gated by owner decision. |
| Pools, streams and parity measurements | Dedicated/ports | Fixed/elastic bounds, credit/ack/cancel, keep-alive, no implicit retry of moves, size/latency reports and parity-ledger evidence. |
| Service-worker lifecycle design | Owner decision | Registration/update/event-lifetime/errors and no-DOM realm contract designed separately; this is a research/design slice, not authorization to implement it here. |

Compiler-foundation PRs may land without exposing worker launching. No public
launch path lands before realm and wire checks are present. Each row has its
own tracking issue; omission or a compiler wall is an issue, not a stub,
handwritten runtime, weakened check or silent fallback. Implementation updates
`skills/beni/` only when the API actually becomes usable; this design must not
teach proposed syntax as shipped syntax.

### Issue links (2026-10-30)

- Entry runtime contract: [1293](https://github.com/canassa/beni/issues/1293).
- Multi-entry emission and bootstrap: [1294](https://github.com/canassa/beni/issues/1294).
- Realm checking: [1295](https://github.com/canassa/beni/issues/1295).
- Wire codecs and ownership moves: [1296](https://github.com/canassa/beni/issues/1296).
- Dedicated runtime and defects: [1297](https://github.com/canassa/beni/issues/1297).
- Ports, shared workers and broadcast: [1298](https://github.com/canassa/beni/issues/1298).
- Native transfer families and atomics: [1299](https://github.com/canassa/beni/issues/1299).
- Pools, streams and parity measurements: [1300](https://github.com/canassa/beni/issues/1300).
- Service-worker lifecycle design: [1301](https://github.com/canassa/beni/issues/1301).
- Owner decisions: [1302](https://github.com/canassa/beni/issues/1302).
