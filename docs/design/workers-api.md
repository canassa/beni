# Proposed browser worker API

**Normative proposed signatures, 2026-10-30; not implemented or compiled.**
[workers.md](workers.md) owns semantics and open decisions. Each code block
lists beni declarations using its real n-ary signature syntax. `-- pure`,
`-- impure` and `-- suspends` apply to following signatures until the next rung
comment, and state the required inferred rung; they are not
new function-type syntax. Opaque types below have private platform-owned
constructors, omitted from this public-signature listing. Their names and type
parameters are part of the API, not JavaScript shapes. Imported types are
qualified where clarity requires it. Every generic value crossing an endpoint
has the compiler's implicit Wire obligation; state, Context, Reply, Sink,
Scope and callback types do not cross. No public API takes Js.Value.

## 1. Browser.Worker

A program keeps its state in the worker. `open` takes the program directly:
there is no Entry wrapper or compiler-owned coercion. Program constructors
are registered through the platform's generic entryKinds contract. The
worker root owns initialization resources; request scopes own handlers.

```text
import Duration exposing (Duration)
import Schema exposing (Schema, Issue)
import Task exposing (Scope)
import Browser.WorkerStream exposing (Stream, Sink)

-- Opaque: Program config state request reply error event chunk
-- Opaque: Handle request reply error event chunk
-- Opaque: Ticket error reply; Prepared a; Context event; ConnectionId
-- Opaque: Reply error reply; Command msg; Subscription msg; ScriptUrl
-- Opaque: Protocol input output; Policy; PolicyName

pub type UrlError = InvalidUrl
pub type Credentials = Omit | SameOrigin | Include
pub type ScriptKind = Module | Classic
pub type Cleanup = Confirmed | Unconfirmed Loss | Abandoned
pub type Loss = ReadyExpired | LeaseExpired | ConnectionLost
pub type ConfigError
    = NonPositiveLimit String
    | InvalidDuration String
    | InvalidPoolBounds
    | InvalidUtilization
pub type PolicyError
    = TrustedTypesUnavailable
    | TrustedPolicyDenied
    | NotTrustedScriptUrl
    | PolicyRefused String
    | InvalidPolicyName
pub type CloneFailure
    = DetachedBuffer
    | ViewOutOfBounds
    | ClosedResource
    | StreamLocked
    | CanvasHasContext
    | TargetRealmUnavailable
    | SameAgentClusterRequired
    | SendingPortTransferred
    | PortBusy
    | DataChannelNotTransferable
    | MediaSourceAlreadyAttached
    | TrackDetached
    | TrackHandleNotTransferable
    | NativeCloneRejected
pub type PrepareError
    = InvalidMessage (List Issue)
    | InvalidResource CloneFailure
    | PreparationClosed
pub type SendError
    = WorkerCloneRejected CloneFailure
    | CanvasTransferInvalidState
    | ChannelClosed
    | QueueFull
pub type TransportError
    = SendFailed SendError
    | MessageDeserializationFailed
    | ProtocolVersionMismatch
    | ProtocolRejected (List Issue)
    | PeerUnresponsive
    | PeerClosed
    | CleanupAbandoned
pub type OpenReason error
    = UnsupportedWorkerKind
    | InvalidScriptUrl
    | WorkerSecurityDenied
    | ScriptPolicy PolicyError
    | TrustedScriptUrlRejected
    | WorkerLoadFailed
    | ReadyDeadlineExceeded
    | ClosedBeforeReady
    | InvalidOptions ConfigError
    | InitializationFailed error
    | HandshakeFailed TransportError
pub type alias OpenError error =
    reason : OpenReason error
    cleanup : Cleanup
pub type CallError error
    = Application error
    | PreparationFailed PrepareError
    | Transport TransportError
pub type EmitError = EventQueueFull | EventChannelClosed | EventCloneRejected CloneFailure | EventCanvasTransferInvalidState

pub type alias Options =
    name : String
    credentials : Credentials
    readyWithin : Duration
    cleanupWithin : Duration
    heartbeatEvery : Duration
    leaseWithin : Duration
    queuedRequests : Int
    queuedEvents : Int
    queuedBytes : Int
    policy : Maybe Policy

pub type alias Definition config state request reply error event chunk =
    init : Context event, config → Result error state
    start : sync (Context event, state → ⊤)
    handle : Context event, state, request → state × Result error reply
    stream : Context event, state, request, Sink error chunk → state × Result error ⊤

-- pure; init/start/handle/stream bodies are deferred entry roots, not page calls.
pub program : entry Definition config state request reply error event chunk
    → Program config state request reply error event chunk

pub type alias ConcurrentDefinition config state request reply error event chunk =
    init : Context event, config → Result error state
    start : sync (Context event, state → ⊤)
    handle : Context event, state, request → Result error reply
    stream : Context event, state, request, Sink error chunk → Result error ⊤

-- pure; entry ownership checks require start/handlers to borrow stable state.
pub concurrent : entry ConcurrentDefinition config state request reply error event chunk
    → Program config state request reply error event chunk

-- pure
pub options : Options
-- suspends; argument 1 is the generic entry edge, config is serialized.
pub open : Scope, Program config state request reply error event chunk, config, Options
    → Result (OpenError error) (Handle request reply error event chunk)
-- suspends; caller cancellation interrupts the handler and awaits cleanup.
pub call : Handle request reply error event chunk, request → Result (CallError error) reply
-- suspends; opens the producer scope, returns once admitted, not after exhaustion.
pub stream : Handle request reply error event chunk, request
    → Result (CallError error) (Stream (CallError error) chunk)
-- impure; one consumer per connection, repeated access returns the same stream.
pub events : Handle request reply error event chunk → Stream TransportError event
-- impure, synchronous codec/commit path; prepared inputs are consumed.
pub send : Handle request reply error event chunk, Prepared request
    → Result SendError (Ticket error reply)
-- suspends
pub await : Ticket error reply → Result (CallError error) reply
-- suspends, cancel-and-wait; idempotent terminal outcome.
pub cancel : Ticket error reply → Cleanup
-- suspends
pub close : Handle request reply error event chunk → Cleanup
-- impure, explicit destructive native terminate; never a scope finalizer.
pub abort : Handle request reply error event chunk → Cleanup

-- impure; preparation without a suspending conversion, takes ownership reservation.
pub prepare : a → Result PrepareError (Prepared a)
-- suspends; schema conversion before native commit, Type is a, Encoded is encoded.
pub prepareWith : Schema encoded a, a → Result PrepareError (Prepared a)
-- impure; cancel a reservation and dispose its resources, idempotent.
pub discard : Prepared a → ⊤
pub type CloneError = CloneRejected CloneFailure | CloneCanvasInvalidState
-- impure; local structured clone, with the same attempted-transfer ownership rule.
pub clone : Prepared a → Result CloneError a

-- impure; scope is worker root in init/start and request child in handlers.
pub scope : Context event → Scope
-- impure; Nothing during root init/start, Just per accepted connection handler.
pub connection : Context event → Maybe ConnectionId
-- impure; bounded event queue, never waits for a pre-ready subscriber.
pub emit : Context event, event → Result EmitError ⊤

-- pure, protocol's typed directional schemas validate external peers.
pub protocol : Schema encodedIn input, Schema encodedOut output → Protocol input output
-- impure; precise URL parse; policy execution remains outside native constructor guard.
pub scriptUrl : String → Result UrlError ScriptUrl
-- impure; a platform-owned total callback returns already accepted URLs only.
pub policy : PolicyName → Result PolicyError Policy
-- pure; name syntax validation, not a claim that CSP allows the policy.
pub policyName : String → Result PolicyError PolicyName
-- impure; checks the input URL against a caller's pure allow function before minting.
pub trust : Policy, ScriptUrl, sync (String → Bool) → Result PolicyError ScriptUrl
```

`options` supplies name empty, same-origin credentials, 30 s ready deadline,
5 s cleanup observation, 5 s heartbeat, 30 s lease, 64 queued requests,
64 queued events and 1 MiB queue bytes; these are configurable policy defaults,
not performance claims. Open validates positivity, finite values and lease ≥
heartbeat before acquiring a native worker. No successful close is inferred
from a deadline. A failed init returns InitializationFailed with cleanup status.
For shared root context, emit broadcasts independently to each connection
queue; before the first Ready it uses that connection's bounded startup queue.
A handler context targets its own connection. Partial fan-out never retries
already accepted events; EventQueueFull identifies a refused emission and the
application must not assume all clients received it.
A defect during init remains fatal and never becomes that variant.

`start` runs after init and before Ready only until it has installed its
root-scoped children; it must be non-suspending. Long-running pushes use
Task.spawnIn with the supplied scope. The ownership checker prevents retaining
an alias of state that a serial handler later consumes. Concurrent handlers
may not consume stable state; root-owned mutable resources require explicit
Ref/Semaphore ownership. These obligations are checked at program construction,
not a user promise hidden in the runtime.

### External endpoints

External scripts have no compiler proof of identity/types. They can implement
raw message channels or explicitly negotiate the managed protocol; raw mode
must not pretend native postMessage is RPC. The same browser constructor
options, including classic for external scripts, remain expressible.

```text
-- Opaque: External input output
pub type ExternalError = ExternalLoadFailed | ExternalTransport TransportError
pub type alias ExternalOptions =
    worker : Options
    kind : ScriptKind
-- suspends; native construction/load observation, no invented Ready for raw scripts.
pub openExternal : Scope, ScriptUrl, Protocol input output, ExternalOptions
    → Result (OpenError ⊥) (External input output)
-- impure; no implicit request id or response expected; native send succeeds at serialization.
pub post : External input output, Prepared input → Result SendError ⊤
-- suspends; validates every received message with the protocol's output schema.
pub receive : External input output → Result ExternalError output
pub receiveMessage : External input output → Result ExternalError (Message output)
-- suspends; managed graceful close is unavailable without negotiated peer support.
pub closeExternal : External input output → Cleanup
-- impure; explicitly destructive, same semantics as native terminate.
pub abortExternal : External input output → Cleanup
```

`openExternal` returns after construction/listener attachment; the `suspends`
bound accommodates policy preparation but never promises module evaluation
completed without a peer handshake. Load errors observed later appear on
receive as ExternalLoadFailed. Raw close closes local admission and returns
Unconfirmed ConnectionLost unless a documented external close protocol
acknowledges it. It does not synthesize a successful cleanup acknowledgment.

### Elm-shaped state machine

```text
pub type alias Machine config model msg request reply error event chunk =
    init : Context event, config → Result error (model × Command msg)
    update : sync (Context event, msg, model → model × Command msg)
    subscriptions : sync (model → Subscription msg)
    request : sync (request, Reply error reply → msg)
    stream : sync (request, Sink error chunk → msg)
-- pure; update/request/stream/subscriptions callbacks are sync, init may suspend.
pub machine : entry Machine config model msg request reply error event chunk
    → Program config model request reply error event chunk
-- pure
pub none : Command msg
pub batch : List (Command msg) → Command msg
pub noSubscriptions : Subscription msg
-- pure; callback is deferred and may suspend in its owning request scope.
pub performFor : Reply error reply, ((msg → ⊤) → ⊤) → Command msg
pub performStream : Sink error chunk, ((msg → ⊤) → ⊤) → Command msg
-- pure; installs a root-scoped producer, cancelled/replaced by stable subscription key.
pub subscription : String, (Scope, (msg → ⊤) → ⊤) → Subscription msg
pub subscriptions : List (Subscription msg) → Subscription msg
-- impure; exactly one reply, terminal reuse is a typed failure.
pub respond : Reply error reply, Result error reply → Result SendError ⊤
-- impure; terminal reused Reply yields ChannelClosed; duplicate ids never reach peer.
pub finish : Sink error chunk, Result error ⊤ → Result SendError ⊤
```

## 2. Browser.SharedWorker

Shared state is initialized once per native shared instance. A connection
gets its own request scopes, event queue and IDs. The same program configuration
fingerprint must match the first client; a different configuration returns
ConfigurationMismatch, not an unnoticed reuse of another client's state.
Init is deferred until the first Hello, so a module cannot accidentally use
page data during evaluation. Disconnect never closes another client's scope.

```text
import Browser.Worker as Worker
import Browser.WorkerStream exposing (Stream)
import Task exposing (Scope)
-- Opaque: Program config state request reply error event chunk
-- Opaque: Handle request reply error event chunk
pub type OpenReason error
    = WorkerOpen (Worker.OpenReason error)
    | SharedStorageDenied
    | ConfigurationMismatch
pub type alias OpenError error =
    reason : OpenReason error
    cleanup : Worker.Cleanup
pub type alias Options =
    worker : Worker.Options
    extendedLifetime : Bool
-- pure
pub options : Options
pub program : entry Worker.Definition config state request reply error event chunk
    → Program config state request reply error event chunk
pub concurrent : entry Worker.ConcurrentDefinition config state request reply error event chunk
    → Program config state request reply error event chunk
pub machine : entry Worker.Machine config model msg request reply error event chunk
    → Program config model request reply error event chunk
-- suspends; Window-only launch, same generic program-argument role as Worker.open.
pub open : Scope, Program config state request reply error event chunk, config, Options
    → Result (OpenError error) (Handle request reply error event chunk)
-- pure; legacy string-name constructor form, defaults all other fields.
pub named : String → Options
-- suspends
pub call : Handle request reply error event chunk, request → Result (Worker.CallError error) reply
pub stream : Handle request reply error event chunk, request
    → Result (Worker.CallError error) (Stream (Worker.CallError error) chunk)
pub close : Handle request reply error event chunk → Worker.Cleanup
-- impure
pub events : Handle request reply error event chunk → Stream Worker.TransportError event
pub send : Handle request reply error event chunk, Worker.Prepared request
    → Result Worker.SendError (Worker.Ticket error reply)
```

The native port is exposed as a **borrowed** endpoint view (`port` below) so
lifecycle observation remains possible without letting two independent
owners move the runtime's protocol port. A view rejects protocol-data injection;
external shared workers instead use their explicitly declared raw protocol.
No terminate method exists in the standard, so no shared terminate API is
invented. The shared runtime's global close closes its instance after all
client/root scopes settle, under the owner-approved defect/lifetime policy.

```text
import Browser.MessagePort as Port
-- impure, nonmovable observation/lifecycle view; does not grant raw protocol send.
pub port : Handle request reply error event chunk → Port.ManagedView
-- Opaque: External input output
-- suspends; raw semantics as Worker.openExternal, including no invented Ready.
pub openExternal : Scope, Worker.ScriptUrl, Worker.Protocol input output, Options, Worker.ScriptKind
    → Result (OpenError ⊥) (External input output)
-- impure, borrower of the raw endpoint; same owner as External.
pub externalPort : External input output → Port.Port input output
-- suspends; receive late generic load errors from the shared constructor as well.
pub receive : External input output → Result Worker.ExternalError output
pub receiveMessage : External input output → Result Worker.ExternalError (Worker.Message output)
-- suspends; disconnect only this client; returns Unconfirmed without peer acknowledgment.
pub closeExternal : External input output → Worker.Cleanup
```

## 3. Browser.MessagePort

Two endpoints have dual directions. A port returned by a shared connection is
owned by that connection; ordinary type aliases cannot manufacture another
owner. `prepareMove` moves cleanup registration as well as native ownership.

```text
import Browser.Worker as Worker
import Task exposing (Scope)
-- Opaque: Port input output; MovedPort input output; ManagedView
pub type PortError
    = PortClosed
    | PortMoved
    | PortBusy
    | SendingPortTransferred
    | PortCloneRejected Worker.CloneFailure
    | CanvasTransferInvalidState
    | UnsupportedMessageChannel
pub type ReceiveError
    = ReceiveClosed
    | ExternalWorkerLoadFailed
    | ReceiveDeadlineExceeded
    | MessageDeserializationFailed
    | ProtocolRejected (List Schema.Issue)
-- impure
pub channel : Scope, Worker.Protocol a b
    → Result PortError (Port a b × Port b a)
pub start : Port input output → Result PortError ⊤
pub post : Port input output, Worker.Prepared input → Result PortError ⊤
pub close : Port input output → ⊤
pub prepareMove : Port input output → Result PortError (MovedPort input output)
-- impure; receiver adopts delivered native endpoint into its own scope before start.
pub adopt : Scope, MovedPort input output → Result PortError (Port input output)
-- suspends, no native transport ACK implied.
pub receive : Port input output → Result ReceiveError output
pub receiveMessage : Port input output → Result ReceiveError (Worker.Message output)
-- suspends; validate protocol handshake before exposing a typed endpoint.
pub receivePort : Scope, Worker.ReceivedPort, Worker.Protocol a b
    → Result ReceiveError (Port a b)
-- impure; enables managed observer delivery; closing view delegates to managed close request.
pub startManaged : ManagedView → ⊤
-- suspends, cooperatively closes owning managed connection, not arbitrary native terminate.
pub closeManaged : ManagedView → Worker.Cleanup
```

A shared external port receives ExternalWorkerLoadFailed if its owning
SharedWorker raises a generic load event; ErrorEvent remains fatal regardless
of whether its error payload is null.

A MovedPort can occur in a prepared message and has transfer-only Wire evidence.
It is not an already-transferred usable sender endpoint. `adopt` on the sender
before commit cancels the reservation and rehomes it; after commit that value
has been consumed. The receiver's decoded MovedPort is fresh and must be adopted
once. Ownership forbids a second adoption. Raw `close` is the native immediate
port operation, not the managed scope guarantee; callers choosing it abandon
raw-peer delivery and receive ReceiveClosed.

## 4. Browser.BroadcastChannel

A name is not proof that all senders share types. Protocol schemas therefore
validate every message, including another version of the same application.
The native API cannot transfer resources or acknowledge delivery.

```text
import Browser.Worker as Worker
import Task exposing (Scope)
-- Opaque: Channel a
pub type OpenError = UnsupportedBroadcast | BroadcastStorageDenied
pub type SendError
    = BroadcastClosed
    | BroadcastCloneRejected Worker.CloneFailure
pub type ReceiveError
    = BroadcastReceiveClosed
    | MessageDeserializationFailed
    | ProtocolRejected (List Schema.Issue)
-- impure
pub open : Scope, String, Schema.Schema encoded a → Result OpenError (Channel a)
pub name : Channel a → String
pub post : Channel a, a → Result SendError ⊤
pub close : Channel a → ⊤
-- suspends
pub receive : Channel a → Result ReceiveError a
pub receiveMessage : Channel a → Result ReceiveError (Worker.Message a)
```

Broadcast post requires a synchronous schema direction and clone-only Wire
evidence. A suspending schema uses a separate `prepareBroadcast`/`postPrepared`
pair, preserving the no-transfer restriction as its own opaque type:

```text
-- Opaque: PreparedBroadcast a
-- suspends
pub prepareBroadcast : Channel a, a → Result Worker.PrepareError (PreparedBroadcast a)
-- impure
pub postPrepared : Channel a, PreparedBroadcast a → Result SendError ⊤
pub discard : PreparedBroadcast a → ⊤
```

## 5. Browser.WorkerGlobal

These operations read worker-global state rather than a page. Typed snapshots
make WorkerLocation useful without accidentally granting navigation methods.
Fatal error/rejection handling is installed by the runtime, not exposed as a
way to catch and continue a defect. Normal connectivity/language events are
public scoped observers.

```text
import Duration exposing (Duration)
import Task exposing (Scope)
import Browser.Worker as Worker
-- Opaque: Listener; AnimationFrame
pub type Realm = Dedicated | Shared | Service
pub type alias Location =
    href : String
    origin : String
    protocol : String
    host : String
    hostname : String
    port : String
    pathname : String
    search : String
    hash : String
pub type alias Navigator =
    appCodeName : String
    appName : String
    appVersion : String
    platform : String
    product : String
    userAgent : String
    language : String
    languages : List String
    onLine : Bool
    hardwareConcurrency : Int
pub type FrameError = AnimationFrameUnavailable
-- impure; only dedicated/shared expose name; service lifecycle remains owner-gated.
pub realm : ⊤ → Realm
pub name : ⊤ → String
pub location : ⊤ → Location
pub navigator : ⊤ → Navigator
pub origin : ⊤ → String
pub isSecureContext : ⊤ → Bool
pub crossOriginIsolated : ⊤ → Bool
pub onLanguageChange : Scope, (List String → ⊤) → Listener
pub onConnectivityChange : Scope, (Bool → ⊤) → Listener
pub unlisten : Listener → ⊤
pub realm dedicatedWorker requestAnimationFrame : Scope, (Float → ⊤) → Result FrameError AnimationFrame
pub realm dedicatedWorker cancelAnimationFrame : AnimationFrame → ⊤
-- suspends; stops admission and cleans all owned root work before native close.
pub close : ⊤ → Worker.Cleanup
```

Other WorkerGlobal functions have `realm worker` bounds, except name/close
which accept dedicated/shared only (service lifecycle is not yet defined).
The parser admits explicit finite sets, `realm { dedicatedWorker, sharedWorker }`,
for this bound. Dedicated-worker animation methods are annotated above.

WindowOrWorkerGlobalScope's timers/queueMicrotask use existing Task/Clock and
platform scheduling contracts, base64 belongs to the typed binary codec surface in #1278,
createImageBitmap uses Browser.Image, structuredClone uses the Worker prepare/
clone adapter in Browser.Worker. These are shared APIs, not worker duplicates. Origin,
secure-context and isolation are included above. `self` supplies the context
internally; no raw global object is public. `importScripts` has no valid
public module-worker form and is diagnosed at compile time. Dynamic code
execution is not an escape from realm checking.

## 6. Browser.WorkerPool

A pool owns its workers. It does not replay moved requests after failure.
Serial programs admit at most one running handler per worker; concurrent
programs permit the configured per-worker limit after the state-borrow check.
Queued admissions and active requests have separate bounds.

```text
import Browser.Worker as Worker
import Browser.WorkerStream exposing (Stream)
import Duration exposing (Duration)
import Task exposing (Scope)
-- Opaque: Pool request reply error event chunk
pub type Size = Fixed Int | Elastic { minimum : Int, maximum : Int, idleFor : Duration, utilization : Float }
pub type alias Options =
    size : Size
    perWorkerConcurrency : Int
    queuedRequests : Int
    worker : Worker.Options
pub type OpenError error = InvalidPool Worker.ConfigError | WorkerOpenFailed (Worker.OpenError error)
pub type CallError error = AdmissionClosed | AdmissionFull | RequestFailed (Worker.CallError error)
pub type alias Stats =
    workers : Int
    busy : Int
    queued : Int
-- suspends; configFor receives stable pool-local slot ID, never a global build ID.
pub open : Scope, Worker.Program config state request reply error event chunk, (Int → config), Options
    → Result (OpenError error) (Pool request reply error event chunk)
pub call : Pool request reply error event chunk, request → Result (CallError error) reply
pub stream : Pool request reply error event chunk, request
    → Result (CallError error) (Stream (CallError error) chunk)
pub close : Pool request reply error event chunk → Worker.Cleanup
-- impure
pub stats : Pool request reply error event chunk → Stats
pub events : Pool request reply error event chunk → Stream Worker.TransportError (Int × event)
```

A serial program with perWorkerConcurrency > 1 is InvalidPool, not silent
serialization under an advertised concurrency. Queue admission has explicit
failure rather than unbounded retained transferred buffers. Elastic shrink
awaits idle scope cleanup and never kills active finalizers. Configuration
functions and returned config have normal effects/Wire constraints; generation
runs in the opener fiber and may suspend before starting its worker.

## 7. Browser.WorkerStream

Streams carry data until End and have exactly one consumer. Credits count
bytes as well as chunks. Pull acknowledges the prior chunk only when the
consumer explicitly releases it, so receipt alone cannot defeat back-pressure.

```text
import Browser.Worker as Worker
-- Opaque: Stream error a; Sink error a; Chunk a
pub type WriteError = SinkClosed | ConsumerCancelled | ChunkTooLarge | ChunkSendFailed Worker.SendError
pub type ReadError error = Failed error | StreamClosed | StreamUnresponsive
pub type Step a = Item (Chunk a) | End
-- suspends
pub next : Stream error a → Result (ReadError error) (Step a)
pub write : Sink error a, a → Result WriteError ⊤
pub cancel : Stream error a → Worker.Cleanup
-- impure
pub value : Chunk a → a
pub release : Chunk a → ⊤
pub take : Chunk a → a
-- suspends; body consumes a borrowed value; release occurs even on cancellation.
pub forEach : Stream error a, (a → ⊤) → Result (ReadError error) ⊤
```

A Chunk is a scoped ownership token. `value` borrows; `release` consumes it.
For transferable values the consumer may instead move the value out once:
`take` consumes the chunk and acknowledges it, making
the consumer the new owner. A second release/take is a compile-time ownership
failure. `forEach` scopes each borrowed value and releases it in a finalizer.
Write validates size/state before native commit and consumes attempted
transfers according to workers §5. Cancel carries the existing interrupt
protocol; it cannot restore moved bytes.

## 8. Inventory-to-API correspondence

The full pinned member inventory is retained unchanged. This table assigns
every family in research §1 and each protocol extension to a public operation
or a reason it is internal; native type-specific failures remain research §9.

| Inventory row | Public form / reason for no public native spelling |
|---|---|
| Worker constructor + WorkerOptions | Worker.open/options; external open accepts ScriptKind; beni kind fixed Module protects emitted ES modules |
| Worker terminate | Worker.abort, explicitly Abandoned rather than successful graceful close |
| Worker postMessage overloads | Worker.send/post/prepare; collector represents both transfer overloads without arbitrary host lists |
| SharedWorker constructor/string/options/extendedLifetime/port | SharedWorker.open/named/options/port/openExternal/externalPort; raw port remains usable only under declared raw schema |
| SharedWorker error, Worker error | Fatal ErrorEvent or typed generic load event through OpenError/ExternalError; no public catch-and-continue handler |
| WorkerGlobalScope self/location/navigator | Context + WorkerGlobal snapshots; no exposed Js.Value |
| WorkerGlobalScope language/online/offline events | WorkerGlobal.onLanguageChange/onConnectivityChange/unlisten |
| WorkerGlobalScope error/unhandledrejection/rejectionhandled | Runtime fatal report/housekeeping; raw promises are not public beni values |
| Dedicated scope name/postMessage/close/message/messageerror | WorkerGlobal.name/close and Context.emit, return values/stream sinks; callers use handle events/await; messageerror typed at every receiver |
| Shared scope name/close/connect | WorkerGlobal.name/close and SharedWorker per-connection accept runtime; exposing an untyped connect callback would bypass protocol validation |
| WorkerLocation all readonly attributes/stringifier | WorkerGlobal.Location including href; no navigation APIs added |
| WorkerNavigator ID/language/online/concurrency mixins | WorkerGlobal.Navigator fields; other partials retain their owning module APIs and exposure checks |
| WindowOrWorkerGlobalScope origin/secure/isolation | WorkerGlobal.origin/isSecureContext/crossOriginIsolated |
| reportError | Existing fatal defect mechanism, never a new recoverable worker error |
| timers/queueMicrotask | Task.sleep/spawn/Clock and platform scheduler; string timers are invalid beni callbacks |
| btoa/atob/createImageBitmap | Owning base64/image APIs with exact failures, no worker-only duplicate wrappers |
| structuredClone/StructuredSerializeOptions | Worker.clone/prepare; typed collector handles native transfers |
| MessageChannel constructor/port1/port2 | MessagePort.channel returns both dual endpoints |
| MessagePort post/start/close/transfer/message/messageerror | post/start/close/prepareMove/adopt/receive; exact native lifecycle preserved |
| Broadcast constructor/name/post/close/message/messageerror | open/name/post/close/receive; preparation has separate clone-only token |
| EventTarget add/remove/once/abort + Event/MessageEvent payloads | Managed observers are scoped and raw receive exposes typed payload metadata through the Message wrapper specified below; no synthetic event can fabricate a successful request |
| Event/ErrorEvent/PromiseRejectionEvent constructors | Native-event fabrication has no worker protocol capability; typed synthetic test data, not native dispatch, exercises handlers |
| ServiceWorker/container/registration/global/clients/cache/fetch/extendable events | Owner decision #1301; inventoried fully, separate event-lifetime API design before implementation |
| Every serializable/transferable family including Wasm | Wire/prepare/clone + native owning module contracts; not seven duplicated constructor families |
| Atomics/SAB | Binary typed atomic/shared APIs, same realm/ownership judgments; no synchronous worker RPC |
| Pools and streaming | WorkerPool and WorkerStream signatures above, additional managed protocol rather than fake native methods |

Raw receiving APIs retain MessageEvent metadata through the signatures above.
The following declarations belong to Browser.Worker:

```text
-- Opaque: ReceivedPort; SourceId; Message a
pub type MessageSource
    = NoSource
    | PortSource ReceivedPort
    | WindowSource SourceId
    | ServiceSource SourceId
-- impure; access borrows from a scoped message, never duplicates port ownership.
pub messageData : Message a → a
pub messageOrigin : Message a → String
pub messageLastEventId : Message a → String
pub messageSource : Message a → MessageSource
pub messagePorts : Message a → List ReceivedPort
pub releaseMessage : Message a → ⊤
```

A Message is an owned token registered in its receiver's scope. Its fields are
borrowed until release; receivePort consumes a ReceivedPort and rehomes its
cleanup after schema/protocol negotiation (a bounded handshake returning
ReceiveDeadlineExceeded at the default ready deadline, ReceiveClosed on closed peer). Merely casting a port cannot establish its role.
SourceId grants no DOM authority. releaseMessage closes unadopted ports;
receive is the data-only projection, which adopts data-owned resources and
closes ancillary ports before returning. MessageSource/ports aliases share one
backing identity, so a port cannot be adopted twice. Broadcast messages have
no transferred ports. Schema failures close all newly received resources before
returning ProtocolRejected. Event listeners and queued messages are scope-owned,
so dropping a consumer cannot leak native endpoints.

The [complete examples](workers-example.md) include the direct and Elm-shaped
programs and the same page lifecycle. Machine command completion settles an
unanswered token as channel-close after cleanup; token send failure is reported
through the existing TransportFailure/lost-peer path, not silently dropped.
