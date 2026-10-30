# Browser workers: inventory and design evidence

Research date: **2026-10-30**. Contract: [workers.md](../workers.md).
Beni source baseline `4215e996f`; this report is research, not implemented API
coverage. Specifications are living documents: anchors below identify the
algorithms reviewed, and [sources.json](workers/sources.json) pins the exact
WebRef IDL and MDN BCD package versions and SHA-256 digests used for inventory.
IDL is an index into primary specifications, not a substitute for their prose.
The later [host/layout audit](workers-host-and-wire.md) adds a beni compiler
probe and complete candidate host-access census. No browser probe was performed for this design; measurements remain
explicit implementation gates. Tooling fetched sources on Dagon only.

## 1. Inventory method and scope

The [IDL extract](workers/worker-surface.idl) contains 102 declaration/inclusion
blocks for worker, channel, global, event and ServiceWorker interfaces and
related dictionaries, including partial declarations from other specs.
It preserves inherited interfaces, mixins, overloads, attributes and defaults.
The extraction selected named interface/dictionary/enum blocks plus their
`includes` statements from every `.idl` file in `@webref/idl` 3.86.0. Thus it
also records proposals; a declaration is not a claim of standard adoption.
The [native type matrix](workers/structured-types.md) is **all 46 matching
rows** in that corpus whose interface extended attributes include Serializable
or Transferable (45 distinct names; FileSystemHandle appears in two specs).
ECMAScript builtins and prose-defined WebAssembly serialization are inventoried
separately (§2/§9); the IDL scan alone is not the full structured-clone surface.

The [compatibility table](workers/compatibility.md) and full selected
[BCD records](workers/compat.json), version 8.1.7, retain member-level status,
version ranges, flags, notes and mobile records. No code supports a feature
merely because its constructor name exists. BCD has nonstandard features too:
`includeUserActivation` and `sameSiteCookies`, for example, are compatibility
evidence, not additions to StructuredSerializeOptions/SharedWorkerOptions
in the pinned HTML IDL. New standardized members require inventory amendments.
Missing BCD rows mean **unrecorded**, not unsupported. Read `standard_track`
and `experimental` in each `__compat.status`; do not flatten them into a
single “all browsers” statement. WebRef and BCD licenses remain those of their
upstream packages (W3C document/software terms for source IDL, CC0 for BCD).

### Worker and channel surface, with ownership of every family

| Standard interface/member family | Beni adapter and exact scope | Primary algorithm |
|---|---|---|
| Worker constructor; options name/type/credentials; terminate; both postMessage overloads; AbstractWorker.onerror; MessageEventTarget message/messageerror | Browser.Worker; module entries and separately schema-checked external endpoints; abort explicitly destructive | [Worker interface](https://html.spec.whatwg.org/multipage/workers.html#dedicated-workers-and-the-worker-interface), [run a worker](https://html.spec.whatwg.org/multipage/workers.html#run-a-worker) |
| SharedWorker constructor (string name or options), readonly port; SharedWorkerOptions inherited fields and extendedLifetime; error | Browser.SharedWorker; Window-only construction, per-connection leases, managed ports, no native terminate method | [SharedWorker](https://html.spec.whatwg.org/multipage/workers.html#shared-workers-and-the-sharedworker-interface) |
| WorkerGlobalScope self/location/navigator/importScripts; error/languagechange/offline/online/rejectionhandled/unhandledrejection | Browser.WorkerGlobal; identity/read-only snapshots/scoped events; importScripts statically refused in module entries | [common scope](https://html.spec.whatwg.org/multipage/workers.html#the-workerglobalscope-common-interface), [importScripts](https://html.spec.whatwg.org/multipage/workers.html#importing-scripts-and-libraries) |
| DedicatedWorkerGlobalScope name, both postMessage overloads, close, message/messageerror; AnimationFrameProvider request/cancel | Worker runner; close after scope cleanup; animation-frame availability separate from realm | [dedicated scope](https://html.spec.whatwg.org/multipage/workers.html#dedicated-workers-and-the-dedicatedworkerglobalscope-interface), [animation frames](https://html.spec.whatwg.org/multipage/imagebitmap-and-animations.html#animation-frames) |
| SharedWorkerGlobalScope name, close, connect | Shared runner; accept all ports in connect, each its own scoped connection | [shared scope](https://html.spec.whatwg.org/multipage/workers.html#shared-workers-and-the-sharedworkerglobalscope-interface) |
| WorkerLocation href/stringifier, origin, protocol, host, hostname, port, pathname, search, hash | Typed read-only location record, no assign/replace/reload | [WorkerLocation](https://html.spec.whatwg.org/multipage/workers.html#worker-locations) |
| WorkerNavigator NavigatorID appCodeName/appName/appVersion/platform/product/userAgent; language/languages; onLine; hardwareConcurrency | WorkerGlobal navigator snapshots; no promise that reported concurrency is the physical CPU count | [WorkerNavigator](https://html.spec.whatwg.org/multipage/workers.html#the-workernavigator-object), [concurrency](https://html.spec.whatwg.org/multipage/workers.html#navigatorconcurrenthardware) |
| WindowOrWorkerGlobalScope origin/isSecureContext/crossOriginIsolated; reportError; btoa/atob; set/clearTimeout/set/clearInterval; queueMicrotask; createImageBitmap overloads; structuredClone | Existing/shared capability modules; callbacks only, no string timers/eval; worker transport uses these contracts without redefining base64/image errors | [shared globals](https://html.spec.whatwg.org/multipage/webappapis.html#windoworworkerglobalscope), [timers](https://html.spec.whatwg.org/multipage/timers-and-user-prompts.html#timers), [bitmap creation](https://html.spec.whatwg.org/multipage/imagebitmap-and-animations.html#dom-createimagebitmap) |
| Additional WorkerGlobalScope/WorkerNavigator partials and mixins in extracted IDL | Exposure registry must retain each: performance, fetch, crypto, caches, storage, locks, permissions, GPU, scheduler and other spec-owned APIs; existing module contracts own their operations | [IDL extract](workers/worker-surface.idl); spec filename precedes every partial |
| MessageChannel constructor, port1/port2 | Browser.MessagePort.channel, dual typed roles | [MessageChannel](https://html.spec.whatwg.org/multipage/web-messaging.html#message-channels) |
| MessagePort postMessage overloads, start, close, transfer steps, message/messageerror | Scoped endpoint; typed port role moves; start only after listeners; close is no delivery acknowledgment | [ports](https://html.spec.whatwg.org/multipage/web-messaging.html#message-ports), [posting](https://html.spec.whatwg.org/multipage/web-messaging.html#dom-messageport-postmessage) |
| StructuredSerializeOptions.transfer sequence | Schema/native-resource collector, identity-deduplicated transfer list; no arbitrary host objects | [serialize with transfer](https://html.spec.whatwg.org/multipage/structured-data.html#structuredserializewithtransfer) |
| BroadcastChannel constructor/name/postMessage/close/message/messageerror | Typed external schema channel, storage partition, no transfers, no own echo or global ordering | [broadcasting](https://html.spec.whatwg.org/multipage/web-messaging.html#broadcasting-to-other-browsing-contexts) |
| EventTarget add/remove listeners and dispatch; Event and MessageEvent/ErrorEvent/PromiseRejectionEvent constructors/data/init | Scoped typed observers and synthetic typed data for tests; native dispatch does not fabricate successful transport. Preserve message data/origin/lastEventId/source/ports and error filename/line/column/error | [EventTarget](https://dom.spec.whatwg.org/#interface-eventtarget), [MessageEvent](https://html.spec.whatwg.org/multipage/comms.html#the-messageevent-interface), [runtime errors](https://html.spec.whatwg.org/multipage/workers.html#runtime-script-errors-2) |

The worker integration does not claim to implement every API merely exposed
on WorkerNavigator: e.g. serial, USB, WebTransport and geolocation retain their
own acquisition/permission contracts. Exposure and wire support for their
native results cannot be inferred from the existence of `Worker`. The
transfer-family issue must include usable typed acquisition/adoption from the
owning module, rather than unusable opaque type declarations.

### Service Workers: inventoried, separate design decided

The [Service Worker specification](https://w3c.github.io/ServiceWorker/)
is an editor's draft with a separate event-driven lifetime model.
[ServiceWorker](https://w3c.github.io/ServiceWorker/#serviceworker-interface)
contains scriptURL, state, statechange and postMessage overloads.
[ServiceWorkerContainer](https://w3c.github.io/ServiceWorker/#serviceworkercontainer-interface)
contains controller, ready, register, getRegistration(s), startMessages,
controllerchange/message/messageerror; RegistrationOptions covers scope,
script type and updateViaCache. [ServiceWorkerRegistration](https://w3c.github.io/ServiceWorker/#serviceworkerregistration-interface)
contains installing/waiting/active, navigationPreload, scope, updateViaCache,
update, unregister and updatefound, plus inventoried partials.
[ServiceWorkerGlobalScope](https://w3c.github.io/ServiceWorker/#serviceworkerglobalscope-interface)
adds clients, registration, serviceWorker, skipWaiting, install/activate/fetch/
message/messageerror; ExtendableEvent.waitUntil controls lifetime, FetchEvent
respondWith/request/client IDs/preloadResponse/handled control interception.
Clients matchAll/get/openWindow/claim; Client id/type/url/frameType/postMessage;
WindowClient visibilityState/focused/focus/navigate; Cache/CacheStorage and
NavigationPreloadManager complete the related surface in the extract.

Registration/update has specific TypeError URL/scheme/origin/trusted-type and
script-response constraints, SecurityError scope/storage constraints and
asynchronous script-load failures; client navigation/openWindow has activation,
origin and invalid-state constraints. `waitUntil`/`respondWith` have dispatch
state requirements (`InvalidStateError`) and rejected promises affect lifecycle,
not an ordinary task Result. Those must receive a separate operation-level
failure design before implementation; this document does **not** invent a
shared-worker-style scope for them. BCD records their support independently.
The [owner decided a separate design](https://github.com/canassa/beni/issues/1301#issuecomment-6525032904).
Dedicated and Shared workers do not wait for it; the inventory remains complete.

## 2. Structured values and transfers

HTML's [serialization algorithm](https://html.spec.whatwg.org/multipage/structured-data.html#structuredserializeinternal)
handles undefined/null/Boolean/String/Number/BigInt and boxed counterparts,
Date, RegExp, ArrayBuffer/SharedArrayBuffer (including resizable/growable
forms), typed arrays/DataView, Map, Set, Error families, Array and ordinary
objects. Symbols, callable values, proxies, promises and weak collections are
not wire data. Accessors/descriptors/prototypes are not a beni serialization
contract. Cyclic/shared references in a supported host graph use its memory
map; a beni codec must preserve supported alias identity rather than serialize
a hidden representation accidentally. Typed views are serializable, **not**
transferable: the backing ArrayBuffer is the transfer. Error stack/cause and
AggregateError support need version-specific evidence; arbitrary host Error
objects are not our defect protocol. Canonical bounded defect data is.

The [Web IDL exception definitions](https://webidl.spec.whatwg.org/#idl-DOMException)
and [HTML Serializable/Transferable extended attributes](https://html.spec.whatwg.org/multipage/structured-data.html#serializable-objects)
are different from “all JS objects can be cloned.” HTML owns these extended
attributes; Web IDL supplies exposure/type/conversion mechanics. Deserialize
checks target interface exposure and agent-cluster identity. A type being
serializable in Window does not make it receivable in a worker.

| Native family (every matrix name is covered here) | Clone/move behavior and invalidation | Specification anchor / owning wrapper |
|---|---|---|
| ArrayBuffer; all integer/float/bigint typed views; DataView | Buffer copy or move; move detaches backing and all views. Resizable/OOB/detached states are explicit; backing transfer can invalidate bytes outside the submitted view | [HTML serialization](https://html.spec.whatwg.org/multipage/structured-data.html#structuredserializeinternal), [ECMAScript ArrayBuffer](https://tc39.es/ecma262/multipage/structured-data.html#sec-arraybuffer-objects); Binary |
| SharedArrayBuffer | Shared memory, never a transfer-list element; same-agent-cluster and cross-origin isolation restrictions; growability separate from bounds | [agent clusters](https://html.spec.whatwg.org/multipage/structured-data.html#restricting-to-the-same-agent-cluster), [SAB](https://tc39.es/ecma262/multipage/structured-data.html#sec-sharedarraybuffer-objects); Binary |
| Blob, File, FileList | Serializable, not transferable; immutable bytes and file metadata retained; FileList items recursive | [File API](https://w3c.github.io/FileAPI/#blob-section), [File](https://w3c.github.io/FileAPI/#file-section), [FileList](https://w3c.github.io/FileAPI/#filelist-section); typed file sources |
| ImageData | Serializable pixel metadata/data; moving its underlying buffer is a separate backing move | [ImageData](https://html.spec.whatwg.org/multipage/canvas.html#pixel-manipulation); Browser.Image |
| ImageBitmap | Serializable and transferable; closed/detached/origin-unclean bitmap failure; sender loses bitmap on transfer | [ImageBitmap](https://html.spec.whatwg.org/multipage/imagebitmap-and-animations.html#imagebitmap); Browser.Image |
| OffscreenCanvas | Transfer-only; context mode must still be none; transfer detaches sender's canvas | [OffscreenCanvas](https://html.spec.whatwg.org/multipage/canvas.html#the-offscreencanvas-interface); Browser.Canvas |
| MessagePort | Transfer-only; endpoint is shipped, local ownership ends; queue/entanglement transfer and self-port checks | [port transfer](https://html.spec.whatwg.org/multipage/web-messaging.html#message-ports); Browser.MessagePort |
| ReadableStream, WritableStream, TransformStream | Transfer-only; locked sides rejected; transport entangles forwarding ports and locks sender sides. Not buffer-style byte detachment | [Streams transfer](https://streams.spec.whatwg.org/#transferrable-streams); typed stream module |
| AudioData, VideoFrame | Serializable and transferable; closed/detached resource rejected, transfer closes sender-side resource; backing resource reference handling follows native algorithm | [AudioData](https://w3c.github.io/webcodecs/#audiodata-interface), [VideoFrame](https://w3c.github.io/webcodecs/#videoframe-interface); Browser.Video/media |
| EncodedAudioChunk, EncodedVideoChunk | Serializable, not transferable as chunk objects; encoded bytes/timing retained | [encoded chunks](https://w3c.github.io/webcodecs/#encodedaudiochunk); media module |
| DOMPoint/DOMPointReadOnly, DOMRect/DOMRectReadOnly, DOMMatrix/DOMMatrixReadOnly, DOMQuad | Serializable numeric geometry; not DOM Nodes and valid in workers | [geometry serialization](https://drafts.csswg.org/geometry-1/#structured-serialization); geometry values |
| DOMException, QuotaExceededError | Serializable named diagnostic values with their specified extra fields; not a catch-all error conversion | [DOMException](https://webidl.spec.whatwg.org/#idl-DOMException), [QuotaExceededError](https://webidl.spec.whatwg.org/#quotaexceedederror); boundary diagnostics |
| CryptoKey | Serializable native key material/algorithm/usages according to native rules; not transfer; no new key-export privilege | [CryptoKey](https://w3c.github.io/webcrypto/#cryptokey-interface); crypto module |
| FileSystemHandle/FileSystemFileHandle/FileSystemDirectoryHandle | Serializable, retains origin/locator constraints; receiver origin/storage checks, permissions not magically granted | [FileSystemHandle](https://fs.spec.whatwg.org/#filesystemhandle), [access extension](https://wicg.github.io/file-system-access/#api-filesystemhandle); file-system module |
| GPUCompilationMessage, GPUCompilationInfo, GPUPipelineError | Serializable diagnostics; device/queue/buffer/texture/shader handles absent intentionally | [WebGPU errors](https://gpuweb.github.io/gpuweb/#errors-and-debugging); Gpu diagnostics, #1277 |
| RTCCertificate | Serializable but Window-only exposure; reject worker-target use, not globally all cloning | [certificate](https://w3c.github.io/webrtc-pc/#rtccertificate-interface); RTC module |
| RTCDataChannel | Transfer-only, current specification transfer eligibility/state and sender detachment must be enforced; Window/DedicatedWorker only | [data channel](https://w3c.github.io/webrtc-pc/#transfering-a-data-channel); RTC module |
| RTCEncodedAudioFrame, RTCEncodedVideoFrame | Serializable encoded media frames; restrictions in native transform serialization remain operative | [encoded transform](https://w3c.github.io/webrtc-encoded-transform/#rtcencodedvideoframe); RTC module |
| MediaSourceHandle | Transfer-only; attachment/serialization state and destination restrictions, not a freely duplicable media source | [MediaSourceHandle](https://w3c.github.io/media-source/#mediasourcehandle); media module |
| WebTransportSendStream, WebTransportReceiveStream, WebTransportDatagramsWritable | Transferable typed stream subclasses; owning standard's restrictions plus stream locks and transferred sender state | [WebTransport](https://w3c.github.io/webtransport/#webtransportsendstream); transport module |
| WebTransportError | Serializable stream/session error details; not an unknown worker error | [error](https://w3c.github.io/webtransport/#webtransporterror); transport module |
| CropTarget, RestrictionTarget | Serializable opaque capture targets, not DOM element transport | [CropTarget](https://w3c.github.io/mediacapture-region/#crop-target), [RestrictionTarget](https://screen-share.github.io/element-capture/#restriction-target); proposal gate |
| FencedFrameConfig | Serializable, Window-only exposure; cannot be a worker payload | [config](https://wicg.github.io/fenced-frame/#fencedframeconfig); proposal gate |
| MediaStreamTrack, MediaStreamTrackHandle | Transferable in respective extension drafts; distinct APIs, not aliases for VideoFrame; source state/track eligibility remain native preconditions | [track extension](https://w3c.github.io/mediacapture-extensions/#mediastreamtrack-extensions), [track handle](https://w3c.github.io/mediacapture-transform/#mediastreamtrackhandle); proposal gate |
| MIDIAccess | Transferable in current editor draft; secure-context/permission and native state constraints retained | [MIDIAccess](https://webaudio.github.io/web-midi-api/#MIDIAccess); proposal gate |

The native type inventory is deliberately wider than the first dedicated
worker example. The implementation coverage issue must expand each family
into its exact acquisition/serialize/deserialize/transfer steps and fixtures;
no unsupported family is silently omitted or replaced with raw `Js.Value`.
A native serialization/transfer step's `DataCloneError` or documented
OffscreenCanvas `InvalidStateError` is recognized only at that operation, with its owning type/path included. Runtime checks distinguish
observable preconditions; opaque native reasons stay `CloneRejected`, never
“unknown error.” Host algorithm evolution requires revisiting the pinned row.

### Shared memory and atomic operations

[ECMAScript Atomics](https://tc39.es/ecma262/multipage/structured-data.html#sec-atomics-object)
includes add/and/compareExchange/exchange/isLockFree/load/notify/or/store/sub/
wait/waitAsync/xor and pause. `ValidateIntegerTypedArray`/`ValidateAtomicAccess`
determine type and bounds errors. Waitable arrays are Int32Array/BigInt64Array
with shared backing; wait also checks `AgentCanSuspend`. Blocking wait throws
TypeError on the page. Range/type conversion errors need exact bounded index
and Word64 adapters, not a broad try around arbitrary operations.
`pause` has its own optional nonnegative integral hint checks and must not
be confused with yielding the fiber scheduler. `waitAsync` resolves to native
ok/not-equal/timed-out outcomes; it can return an immediate outcome rather than
a promise. Notification does not transfer ownership of shared bytes.

The [cross-origin isolation model](https://html.spec.whatwg.org/multipage/webappapis.html#concept-settings-object-cross-origin-isolated-capability)
and [agent-cluster check](https://html.spec.whatwg.org/multipage/structured-data.html#structureddeserializewithtransfer)
are separate from constructor availability. Set COOP/COEP appropriately and
check `crossOriginIsolated`; storage partitioning can still prevent sharing
with the intended peer. A page cannot use Atomics.wait as a synchronous bridge.

## 3. Failure evidence and observability

| Operation and stage | Algorithm predicate / observable signal | Contract consequence |
|---|---|---|
| Worker constructor URL | [constructor](https://html.spec.whatwg.org/multipage/workers.html#dom-worker): URL parser fails → DOMException SyntaxError | InvalidScriptUrl, not ECMAScript SyntaxError |
| Worker/SharedWorker script URL sink | [Trusted Types compliant string](https://w3c.github.io/trusted-types/dist/spec/#get-trusted-type-compliant-string): rejected trusted sink → TypeError; default policy can itself throw | Wrapper validates types, controls policy execution scope and does not swallow arbitrary policy exceptions |
| SharedWorker construction | [constructor](https://html.spec.whatwg.org/multipage/workers.html#dom-sharedworker): obtaining storage key can fail → SecurityError | SharedStorageDenied; origin/storage partition is not guessed from a message string |
| Worker module loading | [run a worker](https://html.spec.whatwg.org/multipage/workers.html#run-a-worker), [module worker fetching](https://html.spec.whatwg.org/multipage/webappapis.html#fetch-a-module-worker-script-tree) and [CSP worker-src](https://w3c.github.io/webappsec-csp/#directive-worker-src): failure is dispatched as error; no guaranteed reason code | WorkerLoadFailed is specific to this observed channel; CSP/COEP/network/MIME are documented possible causes, not separately knowable typed variants |
| Shared options mismatch | HTML shared constructor/worker manager compares type, credentials, extendedLifetime for existing URL/name | Error event, not promised synchronous exception or distinct reason |
| Runtime script failure | [runtime errors](https://html.spec.whatwg.org/multipage/workers.html#runtime-script-errors-2) reports through scope/owners; bootstrap defect envelope adds context | Fatal defect reaches every owning page; ErrorEvent.error is cleared when forwarded, so classify ErrorEvent interface rather than error payload presence |
| Serialize ordinary/native values | [StructuredSerializeInternal](https://html.spec.whatwg.org/multipage/structured-data.html#structuredserializeinternal): uncloneable/detached/OOB/forbidden shared or native state → DataCloneError; recursive property access can throw | Canonical data rejects accessors/functions; precise native catch only, unanticipated exceptions defect |
| Transfer list validation | [StructuredSerializeWithTransfer](https://html.spec.whatwg.org/multipage/structured-data.html#structuredserializewithtransfer): invalid transferable/SAB/duplicate/already-detached/own steps → their specified exception (OffscreenCanvas: InvalidStateError) | Compiler collector prevents type/duplicate errors; all attempted resources consumed once native transfer begins, including partial failure |
| Port self-transfer | [postMessage steps](https://html.spec.whatwg.org/multipage/web-messaging.html#dom-messageport-postmessage): sending port in transfer list → DataCloneError; shipping target peer can disconnect delivery | Reject self; never equate successful serialization with received message |
| Receive | [StructuredDeserializeWithTransfer](https://html.spec.whatwg.org/multipage/structured-data.html#structureddeserializewithtransfer): wrong agent cluster/exposure or native deserialize failure; posting steps dispatch messageerror | Receiver listener mandatory; no inference that the sender already knows failure |
| Broadcast constructor | [BroadcastChannel](https://html.spec.whatwg.org/multipage/web-messaging.html#dom-broadcastchannel): storage-key failure → SecurityError | BroadcastStorageDenied |
| Broadcast send | [postMessage](https://html.spec.whatwg.org/multipage/web-messaging.html#dom-broadcastchannel-postmessage): ineligible context returns; closed flag → InvalidStateError; serialization → DataCloneError | BroadcastClosed/CloneRejected; cannot guarantee any recipient |
| Port start/close; terminate; worker close | Native valid receiver algorithms specify no ordinary exception | No fabricated Result variants for native errors; managed moved/closed checks separate |
| importScripts | [import scripts](https://html.spec.whatwg.org/multipage/workers.html#importing-scripts-and-libraries): module worker TypeError; parse SyntaxError; fetch/MIME NetworkError; execution exceptions propagate | No importScripts in emitted module-worker programs; inventory not a silent missing runtime wrapper |
| Dedicated rAF | [requestAnimationFrame](https://html.spec.whatwg.org/multipage/imagebitmap-and-animations.html#dom-animationframeprovider-requestanimationframe): unsupported provider → NotSupportedError | Typed AnimationFrameUnavailable; shared workers do not expose it |

There is no native universal worker “exit” event or infallible process death
detector. An `error`/`messageerror` listener and readiness deadline prevent the
known early-death hang. Heartbeat timeouts only prove missing replies, including
background freezing. Browser process termination can skip all finalizers.
A design that promises otherwise would violate the no-silent-wrong-answer rule.

Inherited global helpers have their own precise failures: btoa/atob use
InvalidCharacterError for invalid input; createImageBitmap has its source,
size/source-specific RangeError/InvalidStateError and other documented rejection checks in the image contract. Timers accept typed
callbacks, preventing TrustedScript/string-evaluation errors. This worker
contract composes the existing wrappers instead of broadly catching their
failures. The transfer-family issue must validate each owning wrapper's
coverage before calling worker support complete.

## 4. Compatibility findings

The complete member records, including Android/iOS, are retained in the BCD
snapshot. Selected desktop results show why feature detection and real tests
remain required:

| Capability | Chrome | Firefox | Safari | Qualification |
|---|---|---|---|---|
| Dedicated module workers | 80 | 114 | 15 | BCD includes Safari notes; older Worker support does not imply module support |
| Shared module workers | 80 | 114 | 15 | Parent SharedWorker availability/notes also apply; Chrome Android is not inferred from desktop |
| SharedWorker extendedLifetime | 148 | unsupported | unsupported | New standard option; do not treat silently ignored option as a guarantee |
| MessagePort messageerror | 60 | 57 | 16.4 | Required listener even where browser support is incomplete |
| Worker messageerror | unsupported | 57 | 16.4 | Native Worker path differs from MessagePort; protocol deadlines/failure accounting still needed |
| BroadcastChannel | 54 | 38 | 15.4 | Storage partition/origin conditions still apply |
| Atomics.waitAsync | 90 (earlier partial) | 145 | 16.4 | Immediate result and async result both required |
| Atomics.pause | 133 | 137 | 18.4 | This is not Task.yield |
| AudioData | 94 | 130 | 26 | Exposure includes DedicatedWorker, not every Worker realm |

Use underlying records for removals, prefixed implementations and limitations.
A BCD statement is not a conformance run. No Chromium result proves Firefox,
WebKit, mobile sharing policy, optional WebGPU support or proposal transfer APIs.

## 5. Repository evidence and necessary compiler work

| Evidence at 4215e996f | Finding |
|---|---|
| `platforms/browser-inline/beni.json`; #966 | Browser.Program and Inline module runtime, layering on html; old capability modules have not all moved. Design targets the replacement, not browser-tea. |
| `boundary.md` §5.3; `Emit.findEntry` | One ordinary main today; explicit workers manifest must add roots without allowing ambiguous mains. |
| `src/platform.zig:452–459` | `load` accepts a module runtime only with markup lowering plus markup module. General entry runtime still needed under one platform. |
| `src/js/Emit.zig:2333` `takeSupplied`; `:8349` `emitEntryWithModule` | Runtime hooks/rooting tied to markup; entry statically imports runtime and main then calls run. Static import evaluation precedes run, so user initializer defects need staged bootstrap support. |
| `src/js/Emit.zig:9046` | Runtime-module exports are separately constrained; do not accidentally redesign Cloudflare named exports as part of workers. |
| `core/Js.beni:215–230` | catchIf checks expected exceptions and rethrows; sufficient for precise synchronous API wrappers, no new broad error shim needed. |
| `core/Task.beni:245–286` | setImmediate is feature detected; otherwise MessageChannel macrotasks; queueMicrotask drains. The prompt's “all exist in workers” premise is false for setImmediate. No worker scheduler rewrite justified. |
| `core/Task.beni:371`, `:553`, log-context slot near `:412` | Fatal root shutdown and fiber-local log context exist; worker routing and context codec must extend them without transporting fibers. |
| `backend.md` §9 Roots, §11 maps; `boundary.md` host:page amendment | Per-entry reachability/maps and entry-specific host assumptions are required; sharing source files does not authorize evaluating window initializers in workers. |
| `schema.md` §1, §13 | Encoded is typed beni, not host data; conversions may suspend. Transfer collector must not run native commit after an arbitrary suspension while ownership is lost. |
| `ownership-checker.md` §23, §30–31 | Existing owned sends/in-place demands do not yet specify native detachment, whole backing identity or partial transfer failure. New resource demand contract required. |
| #1278 working contract `docs/design/binary.md` on feat/webgpu-inputs | Names are Binary.Buffer/SharedBuffer/View/Source and Browser.Image/Video/Canvas; fixed backing distinct from bounds; alias invalidation already required. Workers must reuse them. This is unmerged coordination evidence, not baseline implementation. |

The exact code limits above are compiler issues in the implementation slices,
not an excuse to write JavaScript. No probe is needed to establish a manifest
branch or native normative algorithm. Browser behavior not settled by those
algorithms remains a browser test obligation, not a measurement claim.

## 6. Prior art read and decisions retained

Effect checkout observed on Dagon:
`3d59ae6d5f9ff3e52cb6ed4a9f325320580218d5` (read the actual checkout rather than
assuming the historical rc.116 pin still described every file).
`packages/effect/src/unstable/workers/Worker.ts:168–240` buffers until ready,
races ready against fiber-set failure, and sends with a broad `Effect.try`.
Keep the race/scoped ownership, reject the broad send-error mapping.
`WorkerError.ts:80` defines WorkerUnknownError: rejected, an unanticipated
exception is a fatal defect. `Transferable.ts` supplies a schema-time collector:
keep it, adding compiler ownership evidence and native backing identity.
`WorkerRunner.ts` separates request and close frames.

`packages/platform/browser/src/BrowserWorker.ts` attaches message/error,
starts ports, and sends close from its finalizer without terminate. It omits
messageerror on the parent side: our inventory requires it.
`BrowserWorkerRunner.ts` attaches messageerror, gives each connection a scope,
closes one client separately and calls self.close on finalization: useful
lifecycle shape, but arbitrary runtime faults must reach the page, not just log.
`unstable/rpc/RpcMessage.ts` defines encoded request, Ack, Interrupt, Ping,
terminal exits and defects; `RpcClient.makeProtocolWorker` and `RpcWorker.ts`
connect the transport to RPC. Retain cancellation, full encoded exit,
trace context, stream Ack/back-pressure and keep-alive. Pools are scoped
library policy over this transport, not a platform-owned worker-spawning
callback that delegates output paths to a bundler.

Elm's `references/elm-core/src/Platform.elm` exposes worker as
init/update/subscriptions without a view. Retain that possible library program
shape. Do not retain hand-written port glue or runtime-only port type checks:
beni's platform boundary and compiler-owned entries make them unnecessary.

## 7. Refresh and coverage discipline

To refresh: obtain exact npm package tarballs in sources.json, verify SHA-256,
extract IDL declaration/inclusion blocks for names in worker-surface.idl,
scan all IDL interface attribute lists for Serializable/Transferable, and
compare the resulting names/exposure flags. Regenerate compatibility records
from BCD `api` for inventoried interfaces plus Worker/global/channel/service
families and `javascript.builtins` ArrayBuffer/SharedArrayBuffer/Atomics/
DataView/TypedArray. Retain all support notes and status. Diff before accepting
new standard rows. The package pins make this independent of future npm latest.

Implementation evidence must add implemented/tested/unsupported/not-yet rows,
linked to corpus/native-browser fixtures; neither this generated inventory nor
an opaque type with no acquisition path counts as implementation. Research 48
has new worker parity rows, initially **specified, missing**, not “have.”

## 8. Existing browser modules by realm (source audit, 2026-10-30)

“Adapt” means a planned capability extraction, **not** an assertion the current
module already runs in a worker. Realm checking is declaration/reachability
based; a mixed module is never granted Window access because some helper is
pure. W = Window, D = DedicatedWorker, S = SharedWorker.

| Current module / operation | W | D | S | Observed dependency and required treatment |
|---|---|---|---|---|
| browser-inline Browser, Tea program/view/mount/navigation constructors | yes | no | no | Page Program/Html/Navigation runtime; worker Program is separate entry API |
| Inline and legacy Rt rendering/lifecycle | yes | no | no | Inline:112/171/244, Rt:130/148 read document; realm roots must include runtime |
| Html vocabulary / rendered nodes | yes | no | no | No DOM construction/node type in worker; pure data helpers independently inferred |
| Dom find/focus/fullscreen/user activation | yes | no | no | Dom:105/131/149 document, :184 navigator.userActivation |
| Browser.Events key/pointer/resize/visibility/page listeners | yes | no | no | Listen target window/document; do not reinterpret as worker-global events |
| Browser.Events animation frame | yes | adapt | no | :213 native requestAnimationFrame; D has conditional support with NotSupportedError |
| Browser.Navigation push/replace/back/forward/load/reload | yes | no | no | history, location.assign/reload, HTMLAnchorElement, window dispatch |
| Browser.Navigation currentUrl pure result adaptation | yes | adapt | adapt | :58 reads location.href, available on WorkerLocation; expose through WorkerGlobal, no navigation authority |
| Storage local/session operations | yes | no | no | Storage:124/127 localStorage/sessionStorage; worker storage APIs are different capabilities |
| Http request/URL preparation | yes | adapt | adapt | Native fetch/Headers/AbortController/FormData usable; Http:593 requires document.baseURI today. Worker adapter uses its own URL base and worker scope, not document |
| WebSocket URL preparation/session | yes | adapt | adapt | WebSocket:280 uses document.baseURI today; native WebSocket/TextEncoder worker exposure does not repair that automatically |
| Time sleep/duration/clock | yes | adapt | adapt | Clock/Task are portable; Sub/Browser subscription host must be separated |
| Random seed/data helpers | yes | adapt | adapt | :81 crypto.getRandomValues and Uint32Array available subject to capability; Cmd host path separate |
| Cmd/Sub data constructors, pure mapping/batching | yes | inferred | inferred | Closure/host requirements propagate; descriptors alone do not authorize page execution |
| Cmd/Sub execution and Hosted page integration | yes | adapt | adapt | Hosted:375 document; page Host cannot be transported. Worker scopes provide their own executor |
| Listen | yes | inferred | inferred | Dynamic Js.global target (:24/:34, inline :17); literal target and callback realm must be constrained, not broad all-realms annotation |
| Core Task/Clock/Duration/Log/math/collections | yes | yes | yes | Realm-local scheduler and context; host-dependent services get explicit exposure rows, sinks never transported |

The `browser-inline` manifest currently layers on html and reexports only its
listed modules; this table does not pretend the legacy capability modules are
all already resolved through that chain. #966's capability migration and the
realm slice must make the adapted operations available with their own checked
roots, retaining legacy correctness until retirement.

## 9. Prose-defined serialization and exact native transfer checks

Web IDL scanning alone is insufficient. The
[WebAssembly Web API §3](https://webassembly.github.io/spec/web-api/#serialization)
adds Serializable and same-agent-cluster behavior to **WebAssembly.Module**
in prose. It is cloneable (not transferable), rejects forStorage, and cannot
cross agent clusters. WebAssembly.Instance/Table/ordinary Memory are not made
wire types by that rule; shared Memory belongs to the separately versioned
threads integration and must not be inferred from a cloneable shared buffer.
Add this explicit prose row to implementation coverage alongside the 46 IDL
rows and ECMAScript builtins. This is a typed Wasm module capability, not an
application escape hatch to Js.Value.

The native per-type failure predicates below supplement §3's generic
structured serialization checks. They are required classifier/fixture rows,
not left to a future broad send catch:

| Native step | Predicate / exception | Typed transport meaning |
|---|---|---|
| OffscreenCanvas transfer | context mode != none → DOMException InvalidStateError | CanvasHasContext precheck; CanvasTransferInvalidState native residual |
| ImageBitmap serialization/transfer | origin-clean flag unset → DataCloneError; detached generic check | BitmapCloneRejected (origin status only refined when observable); ClosedResource for tracked closed state |
| AudioData/VideoFrame serialization/transfer | detached resource or serialization for storage → DataCloneError; transfer closes source | ClosedResource precheck or MediaCloneRejected native residual; storage mode never used by messaging |
| EncodedAudioChunk/EncodedVideoChunk serialization | forStorage true → DataCloneError | Storage encoding unsupported for this codec; ordinary messaging uses false |
| Readable/Writable/TransformStream transfer | relevant readable/writable side locked → DataCloneError | StreamLocked precheck or StreamTransferRejected native residual |
| WebTransport stream subclasses | use corresponding Streams transfer steps | Same lock predicates and errors, no blanket WebTransport catch |
| RTCDataChannel transfer | [[IsTransferable]] false → DataCloneError; sending first makes it ineligible; source closes on move | DataChannelNotTransferable precheck where wrapper tracks it; DataChannelTransferRejected residual |
| MediaSourceHandle transfer | ever assigned as srcObject → DataCloneError; same-agent-cluster restrictions | MediaSourceAlreadyAttached when tracked, MediaSourceTransferRejected otherwise |
| MediaStreamTrack transfer draft | [[IsDetached]] true → DataCloneError; target agent cluster must match | TrackDetached / TrackTransferRejected; source becomes ended and detached |
| MediaStreamTrackHandle transfer draft | [[transferable]] false → DataCloneError | TrackHandleNotTransferable / TrackHandleTransferRejected; source track handle cleared |
| RTCEncodedAudioFrame/RTCEncodedVideoFrame serialization | forStorage true → DataCloneError; data subserialization can fail | RtcFrameCloneRejected, preserving child failure path; messaging uses false |
| FileSystemHandle deserialize | serialized origin must match target origin → DataCloneError | Receiver MessageDeserializationFailed; sender cannot invent successful recipient access |
| WebAssembly.Module serialize/deserialize | forStorage or agent-cluster mismatch → DataCloneError | WasmModuleCloneRejected / receive MessageDeserializationFailed |
| Remaining geometry/blob/file/image-data/crypto/diagnostic/capture-target families | Their specified slot-copy/subserialization steps plus generic exposure/security/cluster checks; no invented additional catch class | Operation-specific CloneRejected with family/path; recursively named child errors |

MIDIAccess's current draft marks Transferable in IDL but does not provide a
complete transfer-steps contract in the fetched editor text. Its proposal row
must remain gated and be resolved with upstream evidence before implementation;
an IDL attribute alone cannot justify invented detachment/error semantics.
No generic fallback is authorized. The implementation inventory [research issue #1303](https://github.com/canassa/beni/issues/1303)
owns closing this specification gap before that adapter can be claimed complete.

BCD records WebAssembly.Module availability but has no separate serialization
subfeature in the pinned data. Clone-specific compatibility is **unrecorded**,
not inferred from constructor availability; the browser conformance matrix
must test it. [Primary-source hashes](workers/spec-sources.json) record the
pages consulted and their retrieval date; generated ReSpec anchors may require
client rendering, as identified in that receipt.

## 10. Owned Trusted Types policy adapter

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
