# Web Workers in the browser platform

**Normative design, specified 2026-10-30; not implemented.** Tracking:
[#1290](https://github.com/canassa/beni/issues/1290). Unsettled owner decisions
below gate their dependent implementation; recommendations are not decisions.
The [research and inventory](research/workers-api-research.md) establish the
baseline. This document owns the compiler/runtime contract, not a claim that
all listed browser features have shipped. No production JavaScript is added:
runtime logic is beni over privileged platform primitives (including Js for
raw data); compiler changes are Zig.

## Open decisions for the owner

**Host typing versus hidden provenance — [#1315](https://github.com/canassa/beni/issues/1315).**
I recommend generated real beni native types with ordinary inferred realm
summaries (option C). The [three-way comparison](research/workers-realm-options.md)
prices guarantees, exact census migration, diagnostics, compiler/interface costs
and erased release output against manually authored wrappers (A) and the retained
hidden-provenance mechanism (B). This is not adopted: #1295 waits for the owner.
All options preserve the same public API, precise failures and EntryHost guarantee.

**Wire naming or universal codecs.** This remains open. I recommend shared
wire-visible names inside a build, direct clone for proven stable shapes, and
normalization where required. §3 and the host/wire research price both designs;
#1296 must wait for [owner decision #1305](https://github.com/canassa/beni/issues/1305). No app-manifest registration decision
remains: source discovery is the specified design (§2).

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
`Abandoned`; it is available for hung/untrusted native work and program
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

## 1. One platform, different places to run

A **realm** is a place in which JavaScript runs, with its own global objects
and module state. A page has `document` and `window`. A dedicated worker has
neither, even when its code was compiled with the same browser platform.
Each worker also gets its own fiber scheduler and module-level values.

The platform boundary still answers **which libraries this program may use**.
The realm check answers **where a reachable operation can run**. We need both
now: resolving a DOM module under the browser platform does not make a DOM
operation safe inside a worker. `boundary.md` §5.3's one-platform rule stays;
we replace the unchecked platform-wide `host: page` promise with checked facts
for each entry (§4).

The current target is `browser-inline`, the replacement selected in #966;
capabilities move into its browser base, rather than the old dom/TEA renderer.
The proposed modules and every public signature are in
[workers-api.md](workers-api.md). The existing-module audit remains in
[research §8](research/workers-api-research.md#8-existing-browser-modules-by-realm-source-audit-2026-10-30).
That audit distinguishes today's code from needed migration: for example,
Http and WebSocket currently read `document.baseURI` while preparing URLs.

## 2. Programs and discovering their entries

**There is no app `workers` manifest list and no Program-to-Entry coercion.**
A worker is an ordinary top-level program value, used directly at its launch
call. The generic entry contract below makes that reference an entry edge
instead of pulling the handler implementation into the page's bundle.

The primary program has an `init`, a stateful request handler, a streaming
handler and a root-scoped startup hook. `init` runs inside the worker, once
per worker instance, before Ready. Its `Result` returns the worker-local
state or a typed initialization failure. State may contain a GPU device,
loaded model or WASM instance: **state has no Wire requirement and never
crosses to the page**. Configuration does cross and therefore has one.

The worker root scope owns state and resources acquired by init, so they
outlive individual requests. Every default handler borrows stable state, so
cancelling one request cannot lose a loaded model or GPU device. Mutable
state lives in explicit Ref/Semaphore resources or the machine's model, so
updates have defined ownership. Ref and machine updates are synchronous atomic
steps, so cancellation sees a valid old or new state. A multi-step transaction
uses a scoped semaphore and cancellation-safe finalizer to preserve its invariant.

Serial admission runs one call or stream producer through cleanup before the
next starts, so applications can depend on that ordering. Concurrent admission
allows several borrowed handlers under the configured bound, so shared mutation
requires explicit synchronization. Both contracts are ownership-checked at
program construction, so neither can move root-owned state into a message.
There is no consuming-state constructor: this use case needs stable resources,
and atomic machine updates/resource transactions cover replacement without a
state lease that cancellation can lose. WorkerStateLost is removed.

Calls and streams have separate input types, so a stream request passed to call
is a compile-time type mismatch. A type-only `Worker.Protocol call reply
streamRequest error event chunk` record groups the six message roles. Program
has three parameters (config, local state, protocol), and Handle/Pool have one.
Ordinary record-alias unification selects roles; no associated-type language
feature or runtime protocol value is introduced. `⊥` as streamRequest makes
streaming uncallable for a call-only program. See the API for generic signatures.

The context gives init/handlers the worker scope and a typed event emitter.
Events are worker-initiated progress or pushed results, independent of a call.
Shared root sends name one connection with emitTo; there is no implicit fan-out
of an owned transferable event. Clone-only values can be sent separately.
`events handle` is a bounded stream on the page; `emit` is impure and reports
QueueFull instead of blocking init before the page can receive Ready. Streams
requested by `stream handle request` are separate, credit-controlled response
streams. Neither facility requires raw MessageEvent handling by the app.

Request/response is primary because a GPU/WASM operation usually returns a
result or a stream and its caller owns cancellation. `Worker.machine` is a
full Elm-shaped adapter with init/update/subscriptions and no view. It exposes
the same request/reply/event/stream capabilities. Its typed Reply/Sink tokens
let asynchronous commands answer their particular caller without untyped
message IDs. Both shapes and a complete page/worker example are in the API
contract; the [complete examples](workers-example.md) exercise both against
the same loaded model. Choosing one does not change protocol or error guarantees.

### Generic entry edges, not compiler knowledge of Browser.Worker

The platform declares `entryKinds`, extending the existing manifest-declared
`program` type contract. Each kind names a program type constructor, its
constructor functions, its launch functions and their **program-argument
index**, a realm, and a runtime module. For example, the browser's dedicated
kind names Browser.Worker.Program and Browser.Worker.open; these names are
resolved symbols from data, never hardcoded in the checker. Type-parameter
roles identify worker-local state versus cross-entry configuration/protocol
values. The entry record parameter requires the proposed
[callback contract amendment](workers-callback-contracts.md), gated by
[owner decision #1319](https://github.com/canassa/beni/issues/1319).
The current entry word does not recognize these worker records. Validate arity, generic roles and program argument/result types when
loading the platform; no ad-hoc implicit coercion is added.

The entryKinds record has these required fields; indices are zero-based:

| Field | Checked meaning |
|---|---|
| `programType` | Resolved nominal type-constructor symbol and arity |
| `constructors` | Symbols returning that program type; entry argument index and callbackProtocol (handlers or machine), checked by the proposed callback contract amendment |
| `launches` | Pairs of function symbol and program argument index; includes pool launch and shared connect as well as direct open |
| `parameters` | Indexed type-role paths: index 0 config (Wire); index 1 local (not Wire); index 2 protocol fields call/reply/stream/error/event/chunk (each Wire). Paths and labels are manifest data, validated after ordinary alias expansion. |
| `realm` | One native execution realm, checked against the host universe |
| `runtime` | Resolved beni module with `run : Program … → ⊤`; impure, non-suspending; starts an owned root fiber and returns; init suspends only within that fiber |

The manifest loader validates symbols against their interfaces, including
constructor result instantiation and launch argument instantiation; inconsistent
roles are invalid_entry_kind. Different serial/concurrent/machine constructors
can target the same nominal program type. Their source implementations and
entry ownership annotations enforce callback contracts; the compiler only
knows the generic deferred-entry edge. Runtime `run` receives the descriptor's
worker-local definition and reads configuration through the platform's typed
bootstrap, never a user Js.Value. Ordinary page `program`/runtime remains the
existing contract and supplies the Window entry proof. `--entry` selects a
worker kind by its program type; ambiguity is invalid_entry_kind. Library
interfaces preserve deferred bodies/roots as well as descriptor references;
a URL alone is insufficient to emit a consuming build's worker.
The runtime's run installs transport/error listeners, starts the Task root and
returns; the scheduler drives init/handler continuations inside that root.
The generated entry still calls run(main) synchronously. `entry_runtime_suspends`
rejects a runtime that could suspend at that call; there is no abandoned
continuation. Ready follows successful fiber init. Emit.emitEntryWithModule
already makes a plain call; the runtime contract now agrees with it.
Type-role paths resolve structurally (including aliases) and must select exactly
the declared protocol fields. Missing, duplicate or inconsistent paths yield
invalid_entry_kind. These generic paths are shared by dedicated/shared/pool
launches; the compiler does not know the names call or stream in source APIs.

A launch argument must be a top-level declaration of the declared program
type, or a finite selection of such references through aliases, containers or
ordinary conditional code. Discover that finite set at reachable launch sites.
Opaque runtime factories whose entry set cannot be determined are refused;
a factory may select among known descriptors but cannot synthesize code.
Program construction is non-suspending and captures only static declarations;
per-instance dynamic data travels in the explicit configuration argument.

The discovered declarations root **their own** execution graphs. Their body
and init are not evaluated in the referring realm; its descriptor contains
only a compiler-produced identity, URL, protocol metadata and immutable
admission bound from its constructor. The compiler
checks those deferred bodies in the entry's realm using the manifest roles.
This permits a page to hold a descriptor mentioning worker-local state types
without constructing or reading such a value on the page.

The graph worklist discovers nested launches until no new entry declaration
appears. Runtime paths come from canonical package/module/declaration identity,
not discovery order. A cycle of entries does not recurse the build forever.
No launch means no emitted worker: unused program declarations are eliminated.
External code can be served by compiling the worker declaration as a generic
explicit root with `beni build Module.beni --entry=value`; the selected type
must match one entryKind. This handles standalone deployments without a
second app registration list. `--library` preserves typed descriptor edges in
its interface and defers executable-entry emission to the consuming build.
A second ordinary page main remains `duplicate_main`.

## 3. Output, representations and the open wire-format choice

Development emits `_main.mjs` for the page and
`_workers/<stable-entry-id>/_main.mjs` for each discovered worker. The stable
ID is a collision-checked encoding/digest of package/module/declaration
identity, assigned before parallel work. Every generated pathname, including
maps, participates in the ASCII-folded output collision preflight.

The runtime resolves worker URLs relative to the generated descriptor module,
so nested routes and a hashed base do not change what starts. Each worker is a
module worker. Name and credentials remain options; no classic fallback can
silently try to run ES-module output. The runtime bootstrap installs defect
listeners before evaluating user entry code, using compiler-emitted module
loading. It needs no handwritten loader or markup-runtime export union.

DCE, runtime roots and initialization are checked per entry. Sharing `_core/`
bytes does not share mutable module state between realms, and must not make a
worker evaluate page-only initializers. Mixed modules require entry-specific
projections. Development maps follow each module; release maps follow each
entry/chunk under `--source-maps`. Reachable Debug in any emitted entry rejects
a release build before output.

**Wire representation is an owner decision, not decided by this document.**
The options and measured current representations are in
[the new research](research/workers-host-and-wire.md). I recommend a single
build-wide naming assignment for wire-visible record fields/constructor tags,
with direct structured clone for proven clone-stable data and specialized
normalization only where representation requires it. This avoids putting an
extra encode/decode walk on every simple request, and respects the Solid 2
UI and Effect v4 effects performance bars. It is a recommendation, not a
measured performance win.

The alternative keeps entry-specific names and canonicalizes every message.
It simplifies independent entry layouts and cross-version protocols, but
visits/allocates the payload before and after the browser's own clone. Shared
naming unions the wire-visible interference constraints and may lengthen names
in other entries; it need not disable inlining/DCE or constrain non-wire fields.
Both designs need per-entry/total brotli and send/receive latency measurements
before adoption. Existing emitted code proves representation facts, not the
performance of either unimplemented multi-entry optimizer.

Until the owner decides, both alternatives must preserve the same protocol,
Wire judgment, ownership moves and native failures. Do not implement two public
APIs or quietly adopt universal codecs by leaving contradictory prose below.
The open decision gates the wire/optimizer slice, not the native inventory.

## 4. A realm check that covers beni over Js

### Evidence and choice

The measured scan covers **every** selected host-access primitive occurrence
in browser-inline, browser and core, including nested calls, not just foreign
declarations. The CSV gives a file, line, operation, receiver and member for
each site; [research](research/workers-host-and-wire.md) explains its conservative
value-provenance classifications and exact counts: 556 definite native sites,
2,130 portable receiver operations, and 170 explicitly caller-dependent
callable/raw-value sites. The latter retain obligations, never safe defaults.

| Candidate | What changes | Guarantee and tradeoff |
|---|---|---|
| A: manually authored typed wrappers | Redirect 556 native sites; typed bridges for 130 callable and 40 other mixed sites | Real caller types and realm summaries, but privileged raw wrapper bodies remain audited promises. |
| B: native table plus hidden provenance | Retain 702 native/mixed expressions; explicitly replace 24 dynamic host selectors | Checks raw bodies too, at the cost of a second shape/path inference graph. |
| C: generated real beni native types | Redirect 556 native sites to typed bindings; retain types through 130 callable and 40 other mixed paths | Uses ordinary types/realm summaries; HostFree prevents native/callable erasure. Generated interface/lowering migration is substantial. |

**Recommendation: C; owner decision #1315 gates #1295.** The complete
[comparison](research/workers-realm-options.md) defines each guarantee, cost,
interface/cache change, diagnostic, zero-cost lowering and migration row.
The following subsections retain **option B as a specified alternative**, not
an adopted requirement. Their hidden descriptors and five-byte fixed summary
budget apply to B only. Declaration-local checked bounds, per-entry proofs,
Wire/ownership guarantees and no unchecked public Js.Value apply to every
option; C uses real native types instead of B's hidden flow paths.

### Source syntax and host table

A value/type declaration may carry `realm window`, `realm dedicatedWorker`,
`realm sharedWorker`, `realm worker`, `realm browser` or `realm any` before its
name; a foreign value retains its existing rung immediately after foreign.
`worker` is the worker-realm set, `browser` its union with window, and `any`
adds other supported hosts. Sets are encoded in a stable compiler-owned realm
universe; platform entryKinds select from it but cannot invent Window exposure.
Explicit finite sets use `realm { dedicatedWorker, sharedWorker }`; aliases
expand to those same masks. This is proposed grammar, not yet parsed.

```text
pub realm window document : Js.Value
document = Js.global "document"     -- body is checked, not trusted

pub realm window saved : Js.Value → Js.Value
saved w = Js.get w "localStorage"   -- imposes Window receiver obligation

pub foreign impure realm window focus : Element → ⊤
```

Ordinary declarations
still infer their effect rung. Public host-dependent platform/core declarations
must state their realm bound; pure data declarations may omit it and infer
all realms. Foreign types carry their exposure word on their own declaration.
An annotation is checked against inferred requirements, never used to suppress
a violating operation. This follows the foreign effect-rung precedent.

The compiler's embedded host table is generated in Zig from pinned WebIDL:
Global/Exposed, inheritance/mixins/partials, members, constructors and return/
argument shapes. HTML's named globals and WindowProxy/WorkerGlobalScope roots
are included. A small versioned intrinsic table adds ECMAScript builtins and
host APIs not described by IDL (such as optional setImmediate), with primary
source references and conformance fixtures. Unrecognized globals are not
assumed portable. Platform-private `$beni`/test-hook globals migrate to
module-local state or explicitly typed bootstrap parameters, not a broad
allowlist. New native capabilities require a table/type contract update.

### How access is proved

Each relevant SSA/BIR value carries a hidden shape/provenance descriptor:
plain data with field paths, a native host interface/union, a function with
parameter/result flow, or unresolved host provenance. This is not a runtime
wrapper and is not erased by Js.Value, Js.from, Js.to, a record or a closure.

| Operation | Constraint/check | Why |
|---|---|---|
| Js.global literal | Resolve table root; infer allowed realm set and result shape. `document` means Window Document, not anonymous data. | A wrong annotation cannot legalize a DOM global. |
| Js.get/set/call literal member | Resolve receiver provenance and member's exposure/shape; propagate return values and callback argument shapes. `w.localStorage` restricts even when w was passed in. | Checking global names alone misses indirect access. |
| Js.apply/construct, bound methods and callbacks | Preserve callee/receiver capability obligations and declared result/argument shapes, including events delivered later. | Passing a host method or event through a helper cannot erase its origin. |
| Js.from/to, storage, aliases and generic helpers | Preserve symbolic path constraints through parameters/results, native containers and captured values; instantiate them at callers. | Js.Value is not an escape hatch from the new check. |
| Dynamic member on proven plain data | Permit indexed dictionary/record/array access, propagating the union of possible stored value shapes. | Core's data manipulation is not needlessly forbidden. |
| Dynamic host global/member | Refuse arbitrary String names. Accept finite literal alternatives or a typed HostKey whose constructor is checked against the table for its receiver. | A runtime string cannot prove a native member exists in this realm. |
| Reflection/Object helpers | Table summaries preserve referenced host shapes; unknown reflection yields unresolved provenance, not Data. eval/Function-generated host access has no accepted proof. | Reaching a property through reflection must not bypass the check. |

`Js.hostKey` is a privileged compiler intrinsic with a **literal** member name,
producing `Js.HostKey receiver result`; `Js.getKey/callKey` instantiate its
member obligations. A platform author can build an ADT/case selecting such
keys, but cannot coerce a String to HostKey. The declaration still states its
realm bound and its body is checked. Listen instead receives a typed event
target: `listenWindow`, `listenDocument` and `listenWorker` choose literal roots
and call the common helper. Arbitrary event-name strings are method arguments,
not dynamic host property lookup, so they remain supported.

A helper with an unresolved receiver exports a symbolic obligation, such as
“parameter 0 must have localStorage; result is Storage”. It need not fail
before its callers are known. A reachable entry must discharge every such
obligation. Static-dispatch evidence, higher-order callbacks, aliases, native
container storage and module initializers participate. SCCs reach a monotone
fixed point. Unreachable bodies do not reject an entry; evaluated initializers
do. If an interface hides a native object, its declared native shape/realm must
still cross the boundary. Foreign sibling promises remain privileged, just as
their existing types/effects do; beni-over-Js bodies are checked rather than
accepted as new unchecked promises.

### Replacing host:page, diagnostics and cost

The platform-wide `host: page` key is withdrawn for multi-entry emission.
Each emitter entry receives an `EntryHost` proof produced from its entryKind
and checked reachable graph. The page's proof says Window; a worker's proof
says its exact WorkerGlobalScope. The release printer emits bare `window`
only when the current projection has a Window proof and that native lookup
has a resolved Window root. Shared chunks require the intersection of their
entry proofs; if that does not prove Window, specialize or retain a safe
qualified lookup that is itself valid in every importing realm. Never carry
the old chain promise into a worker projection. Existing platform manifests
drop host:page during migration; stale uses get `obsolete_host_promise` with
that replacement, not silent acceptance.

| Diagnostic | Site and required explanation |
|---|---|
| worker_realm_violation | Offending host operation/type; entry, native member, allowed realms and deterministic shortest call/value-provenance chain. |
| realm_bound_mismatch | Declaration's realm word; inferred body requirement and offending access. |
| dynamic_host_name | Dynamic global/member expression; known receiver shape, why String is insufficient, typed selector or literal-wrapper fix. |
| unresolved_host_provenance | Entry use that cannot discharge a parameter/result obligation; show origin/loss path and required native type annotation. |
| missing_realm_contract | Public host-dependent privileged declaration lacking its source-local word. |
| entry_runtime_suspends | Platform runtime run declaration and suspending call chain; start an owned root fiber and return instead. |
| invalid_entry_kind | Platform manifest; unknown symbol, arity/type-role mismatch, absent runtime or invalid realm. |
| worker_entry_not_static | Launch's program argument; unresolved factory and example of a finite set of top-level program references. |
| obsolete_host_promise | Platform manifest host key; show entryKind/EntryHost replacement. |
| worker_message_not_serializable / worker_transfer_alias_live | Message field/type path or moved backing and every later live alias; explicit conversion/copy guidance. |

For a fixed realm universe, the simple availability summary is a bit mask
(one byte for the present eight-or-fewer contexts), plus a 32-bit interned
host-flow-summary reference per relevant declaration. Serialized interfaces
store the mask and a length-delimited sparse parameter/result/capture-path
summary; zero-host declarations need no flow payload. Reuse the checker's
interned type/path graph and call edges. Do not allocate a map per expression.
The cost is O(V+E) for each finite-mask propagation pass; each bit can be
removed once per node. Host-shape unions/path summaries are the harder cost:
sharing and memoization avoid repeated walks; a bounded widening to unresolved
provenance must emit the diagnostic above and accept an explicit typed wrapper
as a precision recovery, never invent a safe realm. Measure worst-case
higher-order chains and recursive native-container flows, not only tiny code.

Wire checking memoizes one descriptor per solved type/representation node,
with SCC processing for recursive types: O(T+F) traversal for T nodes and F
field/variant edges, plus obligations at generic instantiations. Store one
classification byte and a 32-bit interned plan reference per relevant type;
store a canonical fingerprint once per concrete protocol root, not per use.
Schema conversions add only their reachable directional type/flow edges.
Interface hashes include realm bounds, host-flow summaries, table revision,
Wire plan and entry roles. A body change with the same exported summary does
not invalidate consumers; a changed exposed member/summary invalidates the
reverse dependency closure. Cache old-version rows are rejected, not guessed.

These are representation/complexity budgets, **not measured compiler costs**.
The implementation must retain >250k LOC/s cold per core and the existing
100k-line build target; report absolute time, interface bytes and peak memory
with/without these analyses, cold and cached. The benchmark matrix is in the
research and #1295/#1296; a budget failure is a compiler issue, not permission
to weaken the check. Existing code migration is part of those slices before
worker launching becomes public.

## 5. Wire types and ownership, independent of the naming decision

`Wire T` is compiler-derived evidence that a value can cross this boundary
with its meaning intact. Unit, booleans, numeric/string primitives, tuples,
records, arrays and tagged unions inherit the judgment from their fields.
Recursive types use a memoized graph. Functions, fibers, scopes, resume tokens,
DOM nodes and raw Js.Value do not acquire it. Opaque native types need their
owning module's native serialization/transfer contract; generic type variables
retain obligations until instantiated. Worker-local state is excluded from
this judgment because it never crosses.

The naming decision changes **how** Wire evidence lowers, not this guarantee.
Under the recommended shared-name design, clone-stable records/unions/tuples/
arrays go straight to native structured clone. A recursive shape containing a
non-clone-stable child normalizes only the necessary paths. Today's emitted
list view has a function-valued `$plain`, so direct clone fails; a codec must
materialize/rebuild it. Today's emitted Dict is still a plain tree, whereas
the normative ordered Dict design has `{entries,index: Map}`; a native Map
itself survives clone. Do not claim every Dict or nominal wrapper always needs
a codec. The measured representation table and protocol shape evidence decide.

Under the alternative canonical-codec design, every nontrivial payload is
encoded and decoded independently of internal names. Both choices retain
same-build/protocol fingerprints and explicit schemas for external channels.
A schema's Encoded remains a typed beni intermediate; a conversion may suspend
during prepare, while native send/transfer commit is synchronous. Prepared
messages and HostKey values are opaque, not application-manufacturable casts.

A transfer is an ownership move of the native backing identity. All views,
aliases, model fields, captures and fibers that could later read it must be
absent. A schema annotation fills an identity-deduplicated collector; a view
moves the whole backing buffer, not only its byte range. Explicit copy is the
way to keep bytes locally; shared memory is never silently substituted.

Preparation owns a reservation. Before native commit, cancellation/failure
returns or disposes still-owned inputs by the documented API. Once native
commit starts, the entire attempted list is consumed even on failure, because
an earlier native step may already have detached a resource. Privileged cleanup
references release what remains local; they never revive application aliases
or close receiver-owned resources. This rule protects against partial native
failure, not merely the happy path. Binary/Image/Video/Canvas remain the shared
owning modules from #1278; worker wrappers do not duplicate those handles.

## 6. Native API adapters and precise failures

The [research §9](research/workers-api-research.md#9-prose-defined-serialization-and-exact-native-transfer-checks)
owns the exact native predicates. The following rules explain what the adapter
protects; the table then names each operation's typed outcomes.

- Wrap only the native operation, so user callbacks and decoding defects cannot
  become accidental transport errors.
- Match the specified native exception class and name, so unrelated failures
  cannot be misreported as an expected refusal.
- Rethrow every unmatched failure into fatal shutdown, so a program cannot
  silently continue after an invariant breaks.
- Classify events by interface and lifecycle state, so forwarded ErrorEvent
  defects remain fatal even when the browser removes their error object.
- Preserve MessageEvent metadata and scoped listeners, so callers retain typed
  data/port ownership without leaking subscriptions.
- Reject unknown frames from managed peers as defects, so forged protocol
  success cannot bypass invariants; validate external data into ProtocolRejected.

These are closed operation-specific errors, not UnknownError or message-string
heuristics. Existing Js.catchIf provides precise rethrowing; no handwritten
JavaScript helper is needed. Observer once/abort semantics and all inventory
members remain covered by the API correspondence table.

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

The owned-policy adapter resolves callbacks before the native constructor guard.
This prevents a user callback TypeError from being mistaken for sink rejection.
[Research §10](research/workers-api-research.md#10-owned-trusted-types-policy-adapter)
retains the precise creation/validation/default-policy algorithm and fixtures.

A shared constructor's SecurityError uses its operation-specific name because
the browser does not reliably distinguish all underlying security causes.
Diagnostics may suggest CSP/CORS/COEP/MIME checks, but label them as possible
causes rather than fabricated error variants.

Every ErrorEvent is fatal, before or after Ready, because HTML may clear its
error payload while forwarding it. A generic Event named error before Ready
is WorkerLoadFailed. A generic load error after managed Ready is fatal because
a ready managed program must not turn an unexpected runtime failure into data.
Unhandled rejection and Defect frames always take fatal shutdown. A host that
cannot preserve these event distinctions needs a compatibility finding.

Native resource state, isolation and support can still cause expected failures,
so static Wire proof does not remove runtime state checks. Raw getters/proxies
are not accepted as wire records, so external validation cannot invoke untrusted
accessors. Bytes/URL/source acquisition errors stay in their owning adapters,
so transport does not invent a blanket classifier for unrelated operations.

## 7. Handshake, requests, exits and defect routing

| Rule | Guarantee protected |
|---|---|
| Install listeners before user evaluation | Startup defects reach the owning page |
| Ready only after init, schema identity and scopes | A successful open is usable |
| Bounded ready/cleanup observation; Lost is not Closed | Failed startup cannot hang or falsely promise cleanup |
| Generations and terminal IDs | Late messages cannot settle a different request |
| Full exits, separate fatal control | Cancellation and defects cannot be disguised as success |
| Bounded diagnostic metadata | Reporting a defect does not serialize an arbitrary thrown object |

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
Ping, Pong, Chunk, Ack, End and TransportFailure. IDs are monotonically allocated within an
instance/connection and never reused while a reply/tombstone can exist;
rollover creates a new generation. Decoder limits cover depth, frame bytes,
queued requests and chunk credits. No unbounded pre-ready buffer.

Reply/finish reservations are committed by the outer coordinator only after
their command/request finalizers finish. WorkerGlobal.close similarly signals
that coordinator and returns; a worker fiber never joins its own root.

Ready means error/close/messageerror listeners and handler scopes exist,
protocol/type identities match, and init has completed successfully. `open`
races this event against explicit failure, cancellation and a finite configured
startup deadline. It never waits only on a latch when the worker may already
have failed. Failure or interruption before Ready transitions Starting → Closing. If no
runtime acknowledgment arrives by the finite cleanup-observation deadline,
it transitions to Lost, not Closed. `open`'s failure contains the original
OpenReason and `Unconfirmed loss` (or `Confirmed` after Closed), and
returns without waiting forever for an impossible acknowledgment. The runtime
keeps any still-live native handle in a bounded orphan registry owned by the
program, stops admission and requests close; it does not claim finalizers ran
or automatically terminate it. Reaching the orphan bound refuses new opens.
A graceful close whose peer is Lost likewise returns an abnormal cleanup
outcome, never success. An implicit Task.scope finalizer that observes Unconfirmed enters
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

| Rule | Guarantee protected |
|---|---|
| Cancel waits for terminal cleanup, reserved control lane | Back-pressure cannot deadlock cancellation |
| Close stops admission before cancelling children/root | No accepted work outlives its owner |
| Native abort is explicitly Abandoned | Destruction never claims finalizers ran |
| Heartbeats report unresponsive; navigation is best effort | Absence of a signal is not false proof of cleanup |
| Shared clients have separate scopes and leases | One ordinary client cannot close another's work |
| Scheduler/fibers are realm-local | A handle never pretends to be a joinable remote fiber |

`send` commits a prepared typed message with synchronous serialization and returns, impure. Native delivery
is a later message task, FIFO for a channel; scheduling between channels is
unspecified. `receive`, `call`, `open`, stream pull and managed graceful close suspend.
Raw external ports/worker owners expose native/local shutdown separately; their
explicit raw lifecycle makes no remote-finalizer promise (API §1–§3).
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

When a page stops normally, it executes this shutdown for managed dedicated workers
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

| Rule | Guarantee protected |
|---|---|
| Move port cleanup registration with the endpoint | Sender finalization cannot close receiver-owned resources |
| Validate broadcast messages; never transfer | A shared name cannot forge typed data or move bytes |
| Shared memory uses explicit Binary capabilities | Ordinary immutable values do not acquire data races |
| Bounded pools; no implicit replay of moved requests | Failure cannot duplicate side effects or reuse detached input |
| Ack only after chunk release; separate control budget | Slow consumers bound memory without blocking cancellation |
| TransportFailure after handler cleanup | A failed result send cannot leave its caller parked |

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
its own scope before starting it. Raw external ReceivedPort adoption attaches
explicit schemas and validates each message without a mandatory beni handshake;
only managed endpoints promise managed peer cleanup/type negotiation. Transferring a port to itself is refused;
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
queue. Each Program supplies its admission bound. Only concurrent constructors
take a validated positive Concurrency value; serial and machine constructors
have no bound argument, and pools cannot override it. An elastic pool adds min/max,
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

See [workers-api.md](workers-api.md) for every public signature and
[workers-example.md](workers-example.md) for complete page/worker lifecycles.

## 10. Verification and measurements owed

No implementation or browser performance claim is made by this document.
Every slice lands with black-box fixtures and its diagnostic transcripts.
`zig build gates` proves compiler checks, chosen wire-layout round trips,
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
| Multi-entry emission and bootstrap | Runtime contract | Source-discovered generic entry descriptors, stable IDs, staged defect bootstrap, relative URLs, per-entry roots/maps/collisions and jobs 1/8 output fixtures; never user JS. |
| Realm checking | Multi-entry roots; owner #1315 | Owner-approved realm mechanism, declaration-local bounds, interface/cache contract, exact census migration, initializer/EntryHost proofs, diagnostic and no-byte-growth release fixtures. Worker builds cannot ship without this gate. |
| Wire codecs and ownership moves | Realm check; #1278 | Cross-entry type evidence, owner-selected release-safe representation plans, backing alias demands and partial-failure consumption; negative and round-trip corpus. |
| Dedicated runtime and defects | Prior compiler slices | Borrowed worker-local init/state/root scope, distinct call/stream protocol roles, unsolicited events, full machine adapter, precise native errors, bounded ready handshake, requests/exits/Log, cancellation/scopes and page defect routing proven in Chrome. |
| Ports, shared workers and broadcast | Dedicated protocol | All inventoried options/overloads/events, shared initializer election versus configuration-free attach, leases/connection scopes, external schema validation, cross-tab and messageerror fixtures. |
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
- Owner lifecycle decisions: [1302](https://github.com/canassa/beni/issues/1302).
- Owner realm-mechanism decision: [1315](https://github.com/canassa/beni/issues/1315).
- Owner wire-layout decision: [1305](https://github.com/canassa/beni/issues/1305).
- Suspending browser commands prerequisite: [1306](https://github.com/canassa/beni/issues/1306).
