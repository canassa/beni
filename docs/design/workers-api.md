# Proposed browser worker API

**Normative proposed signatures, 2026-10-30; not implemented or compiled.**
The [callback protocol](workers-callback-contracts.md) is selected by entryKinds
metadata and checked by ownership checker v2 against inferred user summaries.
The language has no new field annotations. [workers.md](workers.md) owns semantics.
Each code block
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

-- Opaque: Program config state protocol
-- Opaque: Handle protocol
-- Opaque: Ticket error reply; Prepared a; Context event; ConnectionId
-- Opaque: Reply error reply; Command msg; Subscription msg; ScriptUrl
-- Opaque: ExternalProtocol input output; Policy; PolicyName
-- Opaque: ExternalPrepared input output; Concurrency

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
    | PreparedForAnotherEndpoint
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
pub type EmitError = EventQueueFull | EventChannelClosed | EventTargetRequired | EventCloneRejected CloneFailure | EventCanvasTransferInvalidState
pub type TerminalError = TerminalClosed | TerminalPreparationFailed PrepareError

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

-- A type-only grouping: never construct or send a value of this record type.
pub type alias Protocol call reply streamRequest error event chunk =
    call : call
    reply : reply
    stream : streamRequest
    error : error
    event : event
    chunk : chunk

pub type alias Definition config state call reply streamRequest error event chunk =
    init : Context event, config → Result error state
    start : Context event, state → ⊤
    handle : Context event, state, call → Result error reply
    stream : Context event, state, streamRequest, Sink error chunk → Result error ⊤

-- pure; callbacks are deferred entry roots. Both constructors borrow stable state.
pub program : Definition config state call reply streamRequest error event chunk
    → Program config state (Protocol call reply streamRequest error event chunk)
pub concurrent : Concurrency, Definition config state call reply streamRequest error event chunk
    → Program config state (Protocol call reply streamRequest error event chunk)

-- pure
pub concurrency : Int → Result ConfigError Concurrency
pub options : Options
-- suspends; argument 1 is the generic entry edge, config is serialized.
pub open : Scope, Program config state (Protocol call reply streamRequest error event chunk), config, Options
    → Result (OpenError error) (Handle (Protocol call reply streamRequest error event chunk))
-- suspends; caller cancellation interrupts the handler and awaits cleanup.
pub call : Handle (Protocol call reply streamRequest error event chunk), call → Result (CallError error) reply
-- suspends; opens the producer scope, returns once admitted, not after exhaustion.
pub stream : Handle (Protocol call reply streamRequest error event chunk), streamRequest
    → Result (CallError error) (Stream (CallError error) chunk)
-- impure; one consumer per connection, repeated access returns the same stream.
pub events : Handle (Protocol call reply streamRequest error event chunk) → Stream TransportError event
-- impure, synchronous codec/commit path; prepared inputs are consumed.
pub send : Handle (Protocol call reply streamRequest error event chunk), Prepared call
    → Result SendError (Ticket error reply)
-- suspends
pub await : Ticket error reply → Result (CallError error) reply
-- suspends, cancel-and-wait; idempotent terminal outcome.
pub cancel : Ticket error reply → Cleanup
-- suspends
pub close : Handle (Protocol call reply streamRequest error event chunk) → Cleanup
-- impure, explicit destructive native terminate; never a scope finalizer.
pub abort : Handle (Protocol call reply streamRequest error event chunk) → Cleanup

-- impure; preparation without a suspending conversion, takes ownership reservation.
pub prepare : a → Result PrepareError (Prepared a)
-- suspends; explicitly convert a to Encoded, then prepare that typed value.
pub prepareWith : Schema encoded a, a → Result PrepareError (Prepared encoded)
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
-- impure; snapshot IDs; explicit single-target send consumes transfers once.
pub connections : Context event → List ConnectionId
pub emitTo : Context event, ConnectionId, event → Result EmitError ⊤

-- pure, protocol's typed directional schemas validate external peers.
pub externalProtocol : Schema encodedIn input, Schema encodedOut output → ExternalProtocol input output
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
For a dedicated root, emit targets its owning connection. A handler context
targets its own connection. Shared root emit returns EventTargetRequired;
connections/emitTo let it select one live client (a closed target returns
EventChannelClosed). There is no implicit fan-out of an owned event. To publish
to several clients, the application loops over IDs and constructs/copies one
value per send; ownership rejects reusing a transferred backing. Clone-only
immutable events may be reused. Before Ready, each selected target has its
bounded startup queue. A defect during init remains fatal and never becomes that variant.

Definition has ordinary field types. The constructor's handlers protocol row
requires start to be non-suspending and requires start, handle and stream to
borrow root state. These obligations are checked against inferred summaries by
[ownership checker v2](workers-callback-contracts.md).

`start` runs after init and before Ready only until it has installed its
root-scoped children; it must be non-suspending. Long-running pushes use
Task.spawnIn with the supplied scope. All handlers borrow stable root state; cancellation cannot consume or
replace it. Ref updates and machine updates are synchronous atomic steps;
longer transactions use a scoped Semaphore with cancellation-safe release.
Neither constructor may move a root-owned GPU device/model out of state.
Concurrent handlers require the same proof and explicit synchronization for
shared mutable resources. These obligations are checked at program construction,
not a user promise hidden in the runtime.


`Program config state protocol`, `Handle protocol` and `Pool protocol` carry
one type-only protocol record. For example `type alias Jobs = Worker.Protocol
Call Int StreamRequest Error Event Int` is shared by both sides. Ordinary alias
expansion/unification selects its fields; there are no new associated-type
projections or runtime protocol records. The eight parameters of Definition
are spelled out only at generic constructor signatures. A call-only protocol
uses `⊥` for streamRequest and chunk. The library value Worker.noStream
supplies that field without a user callback. No value can be supplied
to Worker.stream, and no runtime WrongRequest branch exists. ExternalProtocol
is a different, value-level pair of schemas for untyped native peers.

Serial program admits one call **or** stream producer until its scope settles.
Concurrent admits independent request scopes up to the configured bound.
Both borrow state; serial admission is ordering, not ownership consumption.
The concurrent constructor takes Concurrency, created by Worker.concurrency.
That pure validator returns NonPositiveLimit "concurrency" for zero or negative
input. Serial program and machine have no bound argument. Pools use the limit
of their supplied Program. They have no override that could contradict it.
Shared initialization fixes the instance limit from its Program descriptor.
The constructor's bound is immutable descriptor data evaluated from the static
program declaration. It is included in the managed build fingerprint. It cannot
be overridden by an opener or a pool.
Shared clients negotiate heartbeatEvery and leaseWithin in Hello, before any
initialization configuration is transferred. The first initializer elects these
two managed policy fields before consuming its configuration. A different requested value returns
IncompatibleInstanceOptions. All its connections then use that heartbeat
cadence and lease duration, while tracking liveness independently.
Native type, credentials and extendedLifetime mismatches prevent attachment
before this handshake. HTML exposes only a generic asynchronous error event;
that is WorkerLoadFailed, with no invented mismatch reason. Name and emitted
URL select native instance identity. Build and protocol differences, including
different constructor descriptors, use ProtocolVersionMismatch if a managed
peer can be reached.
Ready and cleanup observation deadlines and queue limits remain local policies.
For dedicated workers, heartbeat and lease policy is local to their one
connection. The shared root has its constructor's admission bound; no
connection's queue limits can reset it.
Atomic Ref updates and machine updates preserve a valid state at every
cancellation point. A multi-step invariant uses Semaphore and a finalizer.
No concrete use case here requires a consuming constructor: resource replacement
can be an atomic machine update or an explicit resource transaction. It is
removed along with WorkerStateLost, rather than retaining default retirement.

The entry runtime has `run : Program config state protocol → ⊤`, **impure and
non-suspending**. It installs listeners and starts an owned root fiber, then
returns to the host. init and later handlers may suspend inside that fiber;
the realm-local Task scheduler drives their continuations. Ready waits for
init, not for the synchronous run call to return. This is platform runtime
machinery, not an additional public Browser.Worker function.

### External endpoints

External scripts have no compiler proof of identity/types. They can implement
raw message channels or explicitly negotiate the managed protocol; raw mode
must not pretend native postMessage is RPC. The same browser constructor
options, including classic for external scripts, remain expressible.

```text
-- Opaque: External input output
pub type ExternalCleanup = LocalReleased | NativeTerminated
pub type ExternalShutdown = TerminateOnScopeExit
pub type ExternalError = ExternalLoadFailed | ExternalTransport TransportError
pub type alias ExternalOptions =
    worker : NativeOptions
    kind : ScriptKind
    shutdown : ExternalShutdown
-- suspends; native construction/load observation, no invented Ready for raw scripts.
pub openExternal : Scope, ScriptUrl, ExternalProtocol input output, ExternalOptions
    → Result (OpenError ⊥) (External input output)
-- suspends; endpoint input schema runs here, binding plan and generation to token.
pub preparePost : External input output, input
    → Result PrepareError (ExternalPrepared input output)
-- impure; token must belong to this endpoint; no implicit RPC request id.
pub post : External input output, ExternalPrepared input output → Result SendError ⊤
pub discardPost : ExternalPrepared input output → ⊤
-- suspends; validates every received message with the protocol's output schema.
pub receive : External input output → Result ExternalError output
pub receiveMessage : External input output → Result ExternalError (Message output)
-- impure; explicit raw ownership policy: terminate native worker, release listeners.
pub closeExternal : External input output → ExternalCleanup
pub abortExternal : External input output → ExternalCleanup
```

`openExternal` returns after construction/listener attachment; the `suspends`
bound accommodates policy preparation but never promises module evaluation
completed without a peer handshake. Load errors observed later appear on
receive as ExternalLoadFailed. Raw APIs promise native/local ownership only. Dedicated ExternalOptions must
explicitly select TerminateOnScopeExit: closing this raw owner terminates its
native worker and returns NativeTerminated, with no remote-finalizer promise.
This is distinct from managed scope cleanup and its Unconfirmed fatal rule.
The same action runs at raw scope exit; it is not a hidden fallback from managed
close. Shared raw owners close their local port/listeners and return LocalReleased,
without affecting other clients. Managed graceful guarantees require a managed
program/handshake and use the separate Handle API.

ExternalPrepared holds the endpoint generation, input schema identity and its
already encoded wire value. A wrong endpoint consumes/disposes the reservation
and returns PreparedForAnotherEndpoint before native commit. post never reruns
a suspending conversion. receive validates with that endpoint's output schema.
prepareWith is a different, explicit value conversion: its result is Prepared
encoded and can be sent only where encoded is the managed request type; it does
not install an undisclosed decoder in the peer. All preparation tokens are
scope-owned reservations and their discard/abandonment paths release resources.

### Elm-shaped state machine

The machine protocol row requires update, subscriptions, request and stream to
be non-suspending. Update receives the model owned; subscriptions borrows it.
These are [protocol obligations](workers-callback-contracts.md), not field syntax.

```text
pub type alias Machine config model msg call reply streamRequest error event chunk =
    init : Context event, config → Result error (model × Command msg)
    update : Context event, msg, model → model × Command msg
    subscriptions : model → Subscription msg
    request : call, Reply error reply → msg
    stream : streamRequest, Sink error chunk → msg
-- pure; update, request, stream and subscriptions are sync; init may suspend.
pub machine : Machine config model msg call reply streamRequest error event chunk
    → Program config model (Protocol call reply streamRequest error event chunk)
-- pure
pub noStream : Context event, state, ⊥, Sink error ⊥ → Result error ⊤
pub noStreamRequest : ⊥, Sink error ⊥ → msg
pub none : Command msg
pub batch : List (Command msg) → Command msg
pub noSubscriptions : Subscription msg
-- pure; init/subscription updates can launch async work in the worker root scope.
pub perform : ((msg → ⊤) → ⊤) → Command msg
-- pure; callback is deferred and may suspend in its owning request scope.
pub performFor : Reply error reply, ((msg → ⊤) → ⊤) → Command msg
pub performStream : Sink error chunk, ((msg → ⊤) → ⊤) → Command msg
-- pure; installs a root-scoped producer, cancelled/replaced by stable subscription key.
pub subscription : String, (Scope, (msg → ⊤) → ⊤) → Subscription msg
pub subscriptions : List (Subscription msg) → Subscription msg
-- impure; reserve/prepare terminal result; coordinator sends only after cleanup.
pub respond : Reply error reply, Result error reply → Result TerminalError ⊤
pub finish : Sink error chunk, Result error ⊤ → Result TerminalError ⊤
```

## 2. Browser.SharedWorker

Shared state is initialized once per native shared instance. `open` elects
its initializer and supplies configuration; once initialization is claimed,
a further open returns AlreadyInitialized without consuming its configuration
at native commit. `connect` attaches to the same program/name identity without
providing configuration; it waits for claimed init/Ready within readyWithin,
or returns NotInitialized if no initializer has claimed the instance. There is
no generic fingerprint/equality promise for arbitrary Wire/native resources.
Concurrent opens are elected before any configuration transfer is committed.
Disconnect never closes another client's scope.

```text
import Browser.Worker as Worker
import Browser.WorkerStream exposing (Stream)
import Task exposing (Scope)
-- Opaque: Program config state protocol
-- Opaque: Handle protocol
pub type OpenReason error
    = WorkerOpen (Worker.OpenReason error)
    | SharedStorageDenied
    | AlreadyInitialized
    | NotInitialized
    | IncompatibleInstanceOptions
pub type alias OpenError error =
    reason : OpenReason error
    cleanup : Worker.Cleanup
pub type alias Options =
    worker : Worker.Options
    extendedLifetime : Bool
-- pure
pub options : Options
pub program : Worker.Definition config state call reply streamRequest error event chunk
    → Program config state (Worker.Protocol call reply streamRequest error event chunk)
pub concurrent : Worker.Concurrency, Worker.Definition config state call reply streamRequest error event chunk
    → Program config state (Worker.Protocol call reply streamRequest error event chunk)
pub machine : Worker.Machine config model msg call reply streamRequest error event chunk
    → Program config model (Worker.Protocol call reply streamRequest error event chunk)
-- suspends; Window-only launch, same generic program-argument role as Worker.open.
pub open : Scope, Program config state (Worker.Protocol call reply streamRequest error event chunk), config, Options
    → Result (OpenError error) (Handle (Worker.Protocol call reply streamRequest error event chunk))
-- suspends; attach without a configuration payload; same generic program edge.
pub connect : Scope, Program config state (Worker.Protocol call reply streamRequest error event chunk), Options
    → Result (OpenError error) (Handle (Worker.Protocol call reply streamRequest error event chunk))
-- pure; legacy string-name constructor form, defaults all other fields.
pub named : String → Options
-- suspends
pub call : Handle (Worker.Protocol call reply streamRequest error event chunk), call → Result (Worker.CallError error) reply
pub stream : Handle (Worker.Protocol call reply streamRequest error event chunk), streamRequest
    → Result (Worker.CallError error) (Stream (Worker.CallError error) chunk)
pub close : Handle (Worker.Protocol call reply streamRequest error event chunk) → Worker.Cleanup
-- impure
pub events : Handle (Worker.Protocol call reply streamRequest error event chunk) → Stream Worker.TransportError event
pub send : Handle (Worker.Protocol call reply streamRequest error event chunk), Worker.Prepared call
    → Result Worker.SendError (Worker.Ticket error reply)
```

The native port is exposed as a **borrowed** endpoint view (`port` below) so
lifecycle observation remains possible without letting two independent
owners move the runtime's protocol port. A view rejects protocol-data injection;
external shared workers instead use their explicitly declared raw protocol.
No terminate method exists in the standard, so no shared terminate API is
invented. Normal cooperative instance close waits for all client and root
scopes to settle. Fatal shutdown instead follows the deadline exception in
workers.md §7: the coordinator requests native global close without joining
unfinished children and records abandoned workers. A shared defect stops every
attached beni page; ordinary page shutdown closes only its own connection.

```text
import Browser.MessagePort as Port
-- impure, nonmovable observation/lifecycle view; does not grant raw protocol send.
pub port : Handle (Worker.Protocol call reply streamRequest error event chunk) → Port.ManagedView
-- Opaque: External input output
-- suspends; raw semantics as Worker.openExternal, including no invented Ready.
pub openExternal : Scope, Worker.ScriptUrl, Worker.ExternalProtocol input output, Worker.NativeOptions, Bool, Worker.ScriptKind
    → Result (OpenError ⊥) (External input output)
-- impure, borrower of the raw endpoint; same owner as External.
pub externalPort : External input output → Port.Port input output
-- suspends; receive late generic load errors from the shared constructor as well.
pub receive : External input output → Result Worker.ExternalError output
pub receiveMessage : External input output → Result Worker.ExternalError (Worker.Message output)
-- impure; raw ownership covers this port/listeners, no remote scope promise.
pub closeExternal : External input output → Worker.ExternalCleanup
```

Shared program handlers **borrow stable root state**, even with serial
admission; concurrent changes only admission parallelism. They cannot consume
that shared root state across a suspension. Use explicit root-owned Ref or
Semaphore resources for mutable state, or machine's non-suspending update to
replace a model before async commands run. This preserves isolation: cancelling
one client cannot lose a consuming state lease and retire other clients.
There is no consuming-state constructor. Shared init is
instance-owned after election; losing its initiating client does not cancel it
while another connection remains. With no clients, ordinary root cleanup applies.

## 3. Browser.MessagePort

Two endpoints have dual directions. A port returned by a shared connection is
owned by that connection; ordinary type aliases cannot manufacture another
owner. `prepareMove` moves cleanup registration as well as native ownership.

```text
import Browser.Worker as Worker
import Task exposing (Scope)
import Schema
-- Opaque: Port input output; MovedPort input output; ManagedView
-- Opaque: Prepared input output
pub type PortError
    = PortClosed
    | PortMoved
    | PortBusy
    | PreparedForDifferentPort
    | SendingPortTransferred
    | PortCloneRejected Worker.CloneFailure
    | CanvasTransferInvalidState
    | UnsupportedMessageChannel
pub type ReceiveError
    = ReceiveClosed
    | ExternalWorkerLoadFailed
    | MessageDeserializationFailed
    | ProtocolRejected (List Schema.Issue)
-- impure
pub channel : Scope, Worker.ExternalProtocol a b
    → Result PortError (Port a b × Port b a)
pub start : Port input output → Result PortError ⊤
pub post : Port input output, Prepared input output → Result PortError ⊤
pub discard : Prepared input output → ⊤
pub close : Port input output → ⊤
pub prepareMove : Port input output → Result PortError (MovedPort input output)
-- impure; receiver adopts delivered native endpoint into its own scope before start.
pub adopt : Scope, MovedPort input output → Result PortError (Port input output)
-- suspends; run the endpoint input schema before creating a generation-bound token.
pub prepare : Port input output, input → Result Worker.PrepareError (Prepared input output)
-- suspends, no native transport ACK implied.
pub receive : Port input output → Result ReceiveError output
pub receiveMessage : Port input output → Result ReceiveError (Worker.Message output)
-- impure; adopt raw endpoint with declared schemas, no invented peer handshake.
pub receivePort : Scope, Worker.ReceivedPort, Worker.ExternalProtocol a b
    → Result PortError (Port a b)
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
import Schema
-- Opaque: Channel a
pub type OpenError = UnsupportedBroadcast | BroadcastStorageDenied
pub type PostError = PreparationFailed Worker.PrepareError | SendFailed SendError
pub type SendError
    = BroadcastClosed
    | PreparedForDifferentChannel
    | BroadcastCloneRejected Worker.CloneFailure
pub type ReceiveError
    = BroadcastReceiveClosed
    | MessageDeserializationFailed
    | ProtocolRejected (List Schema.Issue)
-- impure
pub open : Scope, String, Schema.Schema encoded a → Result OpenError (Channel a)
pub name : Channel a → String
pub close : Channel a → ⊤
-- suspends; includes arbitrary schema conversion before native commit.
pub post : Channel a, a → Result PostError ⊤
-- suspends
pub receive : Channel a → Result ReceiveError a
pub receiveMessage : Channel a → Result ReceiveError (Worker.Message a)
```

Broadcast requires clone-only Wire evidence. The convenience post runs schema
preparation and reports its Issues separately from native send errors. Callers
that need an impure synchronous send use prepareBroadcast/postPrepared:

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
-- impure; only dedicated/shared expose name; service lifecycle has its own design.
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
pub requestAnimationFrame : Scope, (Float → ⊤) → Result FrameError AnimationFrame
pub cancelAnimationFrame : AnimationFrame → ⊤
-- impure; request shutdown, return to coordinator; never join the caller's own root.
pub close : ⊤ → ⊤
```

WorkerGlobal.close closes admission and signals the outer runtime coordinator.
The invoking fiber returns to its next checkpoint, then is cancelled with the
other root children; the coordinator awaits cleanup and sends Closed before
native close. The caller cannot await its own root or receive Cleanup. The
external owner observes the outcome via Worker.close/connection terminal state.

Other WorkerGlobal functions have worker-realm bounds, except name/close
which accept dedicated/shared only (service lifecycle is not yet defined).
These bounds are generated binding metadata and inferred summaries, not
source-level realm words or new parser syntax. The two animation methods have DedicatedWorker availability in their binding metadata.

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
-- Opaque: Pool protocol
pub type Size = Fixed Int | Elastic { minimum : Int, maximum : Int, idleFor : Duration, utilization : Float }
pub type alias Options =
    size : Size
    queuedRequests : Int
    worker : Worker.Options
pub type OpenError error = InvalidPool Worker.ConfigError | WorkerOpenFailed (Worker.OpenError error)
pub type CallError error = AdmissionClosed | AdmissionFull | RequestFailed (Worker.CallError error)
pub type alias Stats =
    workers : Int
    busy : Int
    queued : Int
-- suspends; configFor receives stable pool-local slot ID, never a global build ID.
pub open : Scope, Worker.Program config state (Worker.Protocol call reply streamRequest error event chunk), (Int → config), Options
    → Result (OpenError error) (Pool (Worker.Protocol call reply streamRequest error event chunk))
pub call : Pool (Worker.Protocol call reply streamRequest error event chunk), call → Result (CallError error) reply
pub stream : Pool (Worker.Protocol call reply streamRequest error event chunk), streamRequest
    → Result (CallError error) (Stream (CallError error) chunk)
pub close : Pool (Worker.Protocol call reply streamRequest error event chunk) → Worker.Cleanup
-- impure
pub stats : Pool (Worker.Protocol call reply streamRequest error event chunk) → Stats
pub events : Pool (Worker.Protocol call reply streamRequest error event chunk) → Stream Worker.TransportError (Int × event)
```

The supplied Program determines each worker's admission bound. Fixed and Elastic
size validation concerns numeric values only, independently of that program. Queue admission has explicit
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
| ServiceWorker/container/registration/global/clients/cache/fetch/extendable events | Decided #1301: separate event-lifetime design; Dedicated and Shared do not wait |
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
cleanup with the caller's explicit input/output schemas. This is raw external
interop: every received message is validated, but no claim about the peer's
expected outgoing type or remote cleanup is made. A standard raw peer needs no
beni handshake. Typed MovedPort adoption, in contrast, preserves a role already
proved at its sender. No cast silently manufactures either proof.
SourceId grants no DOM authority. releaseMessage closes unadopted ports;
receive is the data-only projection, which adopts data-owned resources and
closes ancillary ports before returning. MessageSource/ports aliases share one
backing identity, so a port cannot be adopted twice. Broadcast messages have
no transferred ports. Schema failures close all newly received resources before
returning ProtocolRejected. Event listeners and queued messages are scope-owned,
so dropping a consumer cannot leak native endpoints.

The [complete examples](workers-example.md) include the direct and Elm-shaped
programs and the same page lifecycle. Machine command completion settles an
unanswered token as channel-close after cleanup. respond/finish reserve a
terminal result and transfer its resources to the coordinator; they report
TerminalClosed or TerminalPreparationFailed only, not a later native send
failure. After the command, its child scopes and finalizers complete, the
coordinator commits the reserved send. A preparation/native-send failure uses
TransportFailure/lost-peer settlement; no self-join or early success reply.
Root perform commands belong to init/subscription scope, while performFor and
performStream remain request-scoped. Dispatched command messages retain their
owning context; the serial request completes after its command queue drains.

Port.Prepared and PreparedBroadcast also bind their exact endpoint generation
and schema identity. post/postPrepared reject a token from another endpoint
before native commit with PreparedForDifferentPort/PreparedForDifferentChannel,
consume the attempted token and dispose still-local resources. A same payload
type is not evidence of matching schema encodings. Port.discard and broadcast
discard cancel uncommitted reservations; endpoint scope cleanup owns leftovers.

A call-only API can name its grouped types without inventing a stream request:

```text
pub type alias CallsOnly = Worker.Protocol Call Int ⊥ Error Event ⊥
pub calls : Worker.Program (List Int) Model CallsOnly
calls = Worker.program { init = init, start = start, handle = handle, stream = Worker.noStream }
```

This fragment uses the example's Call, Error, Event and Model names,
not a second protocol value. `Worker.stream handle (Frames 1)` on a CallsOnly
handle is refused with the ordinary type mismatch: expected ⊥, got StreamRequest.


The library implements noStream by eliminating its third argument with never.
It implements noStreamRequest by eliminating its first argument. Both are pure
and satisfy the inferred borrow and sync contracts. Use noStream with program
or concurrent, including SharedWorker. Use noStreamRequest for the stream field
of machine, including SharedWorker.machine. These are ordinary library values;
they introduce no syntax or new language feature. The resulting protocol has
bottom stream request and chunk types, so stream cannot be called with a value.

### Options audit

No managed options field depends on the program constructor or protocol.
Queue counts, durations and byte limits are numeric policy values; their
positivity and lease ordering are genuine runtime validation. An uninhabited
event or stream type does not invalidate those limits. Unused queues allocate
nothing. Credentials, name and policy concern native construction for every
managed Program. Script kind is fixed to Module in the managed API.

Pool size is a discriminated Fixed or Elastic value. Only Elastic carries
idleFor and utilization. Its numeric bounds are validated independently of the
worker protocol. Pool queuedRequests is separate from each connection queue.
Shared extendedLifetime is a native instance option for every Shared Program.
IncompatibleInstanceOptions compares the managed heartbeat and lease durations
listed above, not native constructor options.

Raw dedicated and shared APIs use NativeOptions, specified below, rather than
managed Options. This avoids irrelevant Ready, heartbeat and managed request
queue fields. Raw incoming queues still require bounded event counts and bytes.
ScriptKind distinguishes classic and module explicitly. Credentials are valid
for both; the native classic constructor ignores them by specification, so the
wrapper documents that behavior rather than inventing an InvalidOptions case.
Policy applies to both kinds. TerminateOnScopeExit is the only dedicated raw
shutdown policy and is part of its owner type, not a runtime discriminator.
MessagePort and BroadcastChannel have no options records. WorkerGlobal and
WorkerStream have none either.

The following declarations belong to Browser.Worker:

```text
pub type alias NativeOptions =
    name : String
    credentials : Credentials
    queuedEvents : Int
    queuedBytes : Int
    policy : Maybe Policy
pub nativeOptions : NativeOptions
```

NativeOptions defaults match the corresponding managed fields. Shared raw
openExternal takes Worker.NativeOptions and extendedLifetime as a separate Bool,
then ScriptKind. It does not take managed SharedWorker.Options.


### Fatal shutdown reporting

Normal close remains cooperative and never silently calls terminate. An explicit
Worker.abort reports Abandoned. During defect shutdown, the fatal deadline may
abandon unfinished cleanup under the [owner decision](https://github.com/canassa/beni/issues/1302#issuecomment-6525032236).
The private defect report's abandonedWorkers field names every unfinished worker
by entry and runtime instance identity, with kind, diagnostic name and termination
status as specified in workers.md §7. Abandoned is not Confirmed and does not
claim finalizers ran. CleanupAbandoned remains an abnormal transport outcome;
a defect remains the fatal control path, never an application error result or
an extension of Task.Exit. Shared defects stop every attached beni page.
Proposal-only transfer adapters, including #1303, remain explicitly unsupported
until their specifications define transfer semantics.
