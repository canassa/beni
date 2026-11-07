# Web Workers in the browser platform

**Normative contract, specified 2026-10-30; dedicated-worker support is implemented, and since 2026-11-07 a launch builds with no flag.** Tracking:
[#1290](https://github.com/canassa/beni/issues/1290). The owner decisions of 2026-10-30 below are the implementation contract.
The [research and inventory](research/workers-api-research.md) establish the
baseline. This document owns the compiler/runtime contract, not a claim that
all listed browser features have shipped. No production JavaScript is added:
runtime logic is beni over privileged platform primitives (including Js for
raw data); compiler changes are Zig.

## Owner decisions of 2026-10-30

**Realm checking: option C.** The owner [selected generated native types](https://github.com/canassa/beni/issues/1315#issuecomment-6525030806)
and ordinary inferred realm summaries. §4 is normative. A and B remain only in
[the comparison](research/workers-realm-options.md), not implementation choices.
Measure the Task and renderer callback-typing migration first in #1295.

**Wire: shared names.** The owner [selected one build-wide wire naming assignment](https://github.com/canassa/beni/issues/1305#issuecomment-6525031242).
Proven stable shapes use postMessage directly. Normalize only representations
that cannot cross. Universal per-message codecs are not adopted. Measurements
in #1296 and #1300 validate budgets; they do not reopen the choice.

**Callback contracts: no language change.** The owner [selected protocol rows](https://github.com/canassa/beni/issues/1319#issuecomment-6525031739).
The entryKinds constructor's callbackProtocol and parameter index establish
obligations checked against inferred user summaries by ownership checker v2.
No sync or ownership word is allowed on a record alias field. The complete
[callback contract](workers-callback-contracts.md) defines the rows and diagnostics.

**Service Workers: separate design.** The [owner decision](https://github.com/canassa/beni/issues/1301#issuecomment-6525032904)
assigns registration, update, interception and event lifetime their own design.
Dedicated and Shared workers do not wait for it. Their complete inventoried
surface remains recorded; a Service Worker is not a long-lived ordinary fiber.

**Fatal shutdown may abandon cleanup.** Under the [owner decision](https://github.com/canassa/beni/issues/1302#issuecomment-6525032236),
normal close cooperatively waits for cleanup and never silently terminates.
During defect shutdown, workers still unfinished at the fatal deadline are
abandoned and terminated where the browser grants termination authority. The
private abandonedWorkers report names each one and records the termination
status (§7). This does not claim cleanup ran. Explicit Worker.abort remains the
destructive operation. Browser crash, page discard or process kill cannot
promise finalizers; a missing heartbeat means PeerUnresponsive, not proven death.

**A shared defect stops every attached page.** The same [owner decision](https://github.com/canassa/beni/issues/1302#issuecomment-6525032236)
requires the shared instance and every attached beni page to enter their fatal
path, rendering or logging the defect. Ordinary page shutdown closes only its
own connection; it cannot close another page's scope.

**Proposal transfers remain gated.** The same [owner decision](https://github.com/canassa/beni/issues/1302#issuecomment-6525032236)
requires standard families first. Proposal-only adapters, including #1303, are
inventoried and explicitly unsupported until their specifications define transfer
semantics. Every inventory row remains accounted for; no completeness claim may
silently omit a gated type.

**Landing amendment, 2026-11-06 (Part of #1612):** workers are replayed on master’s
Task. Ordinary programs with no workers must retain master’s emitted bytes. No
core/platform storage redesign is part of this landing.

**Launch amendment, 2026-11-07 ([#1689](https://github.com/canassa/beni/issues/1689), approved
by the owner the same day):** the landing's launch gate is removed. A `build` or `check` that
reaches a worker launch no longer reports `invalid_entry_kind` ("Worker launches are gated…"),
and the hidden `--allow-unchecked-workers` option is gone: it is an unknown option, a usage
error. Nothing the gate deferred is skipped: `check` and `build` both run entry reachability,
finite launch discovery (`worker_entry_not_static`), the Wire check and the realm checks of §4
on every launch, with no flag.

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
values. The entry parameter index and callbackProtocol select the
[decided callback contract](workers-callback-contracts.md). No entry word is
written on the constructor parameter; alias expansion is ordinary typing. Validate arity, generic roles and program argument/result types when
loading the platform; no ad-hoc implicit coercion is added.

The entryKinds record has these required fields; indices are zero-based:

| Field | Checked meaning |
|---|---|
| `programType` | Resolved nominal type-constructor symbol and arity |
| `constructors` | Symbols returning that program type; entry parameter index and callbackProtocol (handlers or machine), checked by ownership checker v2 and the effect checker |
| `launches` | Pairs of function symbol and program argument index; includes pool launch and shared connect as well as direct open |
| `parameters` | Indexed type-role paths: index 0 config (Wire); index 1 local (not Wire); index 2 protocol fields call/reply/stream/error/event/chunk (each Wire). Paths and labels are manifest data, validated after ordinary alias expansion. |
| `realm` | One native execution realm, checked against the host universe |
| `runtime` | Resolved beni module with `run : Program … → ⊤`; impure, non-suspending; starts an owned root fiber and returns; init suspends only within that fiber |

The manifest loader validates symbols against their interfaces, including
constructor result instantiation and launch argument instantiation; inconsistent
roles are invalid_entry_kind. Different serial/concurrent/machine constructors
can target the same nominal program type. Their source implementations and
protocol rows enforce callback contracts against inferred summaries; the compiler checks
the generic entry and callback protocol contracts. Runtime `run` receives the descriptor's
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

**Shared wire names are normative**, by the [owner decision](https://github.com/canassa/beni/issues/1305#issuecomment-6525031242).
Assign wire-visible record fields and constructor tags once for the whole build,
including page and workers. Union their interference constraints deterministically
before per-entry emission. Inlining, DCE and non-wire field naming remain local.
Stable recursive shapes pass directly to postMessage. A representation plan
normalizes only paths that cannot cross, then reconstructs the necessary local
representation at receipt. Do not add a universal encode and decode traversal.

This choice may lengthen names across entries; that cost must be measured against
per-entry and total unique release-byte budgets. It does not permit incompatible
independent entry layouts. Build and protocol fingerprints catch mismatched peers.
The [wire research](research/workers-host-and-wire.md) retains universal canonical
codecs as the compared alternative, **not adopted**. #1296 and #1300 implement
shared names and measure compiler time, bytes and transport latency; they do not
choose between designs after measurement. Existing emission probes establish
representation facts, not performance of the future multi-entry implementation.

## 4. A realm check that covers beni over Js

### Landing amendment, 2026-11-06 — Part of #2120

The owner selected a kept-code check for this landing. After entry reachability
elimination, worker builds refuse retained privileged code that names a page-only
JavaScript global, with `worker_realm_violation`. A computed global name or a
first-class `Js.global` is unproved and refused. Functions reached through
callbacks, records, fibers, erased values and evaluated constants receive the
same check. Dead declarations are not roots. This adds no runtime code and
changes no page output. Generated native bindings remain available; migrating
Task, List or renderer storage is not a prerequisite for this check.

In a worker, a kept `Js.global` of `globalThis`, `self`, `location` or
`navigator` is allowed only as the direct receiver of a literal member read
or call whose member is available in that realm. Other uses are refused:
aliasing, passing the receiver as an argument, storing it, a computed member,
or writing through it. Literal `globalThis`/`self` member chains are checked
by the same rule, including receiver-valued `self`, `globalThis`, `location`
and `navigator` members; returning those handles does not bypass the rule.
For globalThis/self, page-only names are refused (since 2026-11-07, every
name not on the realm's global object: *The worker global allow-list* below).
Animation frame request and cancellation are allowed in dedicated workers, but
not shared or service workers. WorkerLocation permits its readonly URL components and stringifier,
not navigation methods or writes. WorkerNavigator members follow the worker
exposures in the pinned Webref IDL, including its included mixins; Window-only
members and unknown/computed members are refused. Existing direct
`Js.isUndefined (Js.global "window")` existence probes remain runtime probes.
The check introduces no runtime guard or alias/provenance analysis.

The worker runtime does not store its global self as a peer endpoint. Its
child peer has no native field; posting to that missing endpoint calls
self.postMessage directly. Native Worker endpoints retain their existing
postMessage call. No checker exemption is made for the runtime.

The private `Js.entryWindow ⊤` selector is true for Window entries and false
for other concrete entries (`boundary.md` §4.2; `backend.md` §4). It has no
data inputs and is pure. An `if` with the literal `⊤` argument drops its unused branch in
reachability and lowering; a nonliteral unit expression is evaluated normally
for its effects. Unknown entry realms refuse a kept use of this selector; no runtime selector or fallback remains in any entry output.
Http and WebSocket retain `document.baseURI` in a page (including base-element
semantics) and use `location.href` in a worker. Shared sources already have
separate per-entry output copies. Unknown-entry cache facts stay symbolic;
only `--library` output may retain a `typeof document` fallback. Existing
`Js.global` semantics and runtime realm probes are unchanged.

### The worker global allow-list, 2026-11-07 — #2206, #2207

The landing's list of 13 page-only names was a deny-list: every other
Window-only global (`alert`, `parent`, `DOMParser`, `matchMedia`,
`requestIdleCallback`, …) built and threw at run time. The check is now an
allow-list per realm. In a worker build, a kept `Js.global` name, a literal
member of `globalThis` or `self`, and a free name of a kept sibling are
accepted only when the name is on that worker realm's global object.

**The list.** `src/js/WorkerGlobals.zig` is one generated table: each name and
the worker realms (dedicated, shared, service) whose global object has it.
`scripts/worker-globals.mjs` builds it from the pinned Webref IDL 3.86.0
(`research/workers/webref-idl-3.86.0.tgz`, parsed with webidl2 24.5.0) and the
global object of ECMA-262 (2025, §19 and Annex B.2.1) and ECMA-402 (`Intl`).
A name is on a realm's global object when it is an interface object or a
namespace exposed in that realm (`[Exposed]` against the realm's `[Global]`
names; `[LegacyNoInterfaceObject]` excluded), or a non-static member of the
realm's global interface (`DedicatedWorkerGlobalScope`,
`SharedWorkerGlobalScope`, `ServiceWorkerGlobalScope`), of its ancestors
(`WorkerGlobalScope`, `EventTarget`) or of a mixin they include
(`WindowOrWorkerGlobalScope`, `AnimationFrameProvider`, …), member and
partial `[Exposed]` applied. The emitter's own bootstrap global,
`__beniWorkerFingerprint`, is accepted too. The `location` and `navigator`
member lists above are unchanged.

**Dynamic code.** `Function` and `eval` are on every global object, but code
they run is invisible to the check (`workers-api.md` §5), so a kept use is
`worker_realm_violation`. In a kept sibling, so is a timer that may be handed
a string of code (amended 2026-11-07, #2211; *Sibling scopes and timers*
below). A code string reaching dynamic code by another route — a
`constructor` member, or `setTimeout` reached from beni through `Js` — is not
closed by this syntactic check: a computed member of an arbitrary value is
ordinary data access. #2211 tracks it.

**`importScripts`.** A module worker has no usable `importScripts`; a kept
use, bare or as a `globalThis`/`self` member, is
`module_worker_import_scripts` (§6's table).

**Existence probes.** `Js.isUndefined (Js.global "N")` stays a runtime probe
for any name that is not a receiver. One more form is a probe: a local bound
directly to `Js.global "N"`, N absent from the realm, whose every read is the
subject of `Js.isUndefined` or of `Js.typeIs` with a literal type other than
`"undefined"`, or lies in the arm that probe proves N present (`False` for
the first, `True` for the second). The local is then read only where N
exists. Core's macrotask scheduler probes Node's `setImmediate` this way.
A read outside that arm is refused. This is a def-use check of one binding,
not an alias analysis: any other use of the local refuses it.

**Siblings.** Hand-written JavaScript a worker build keeps — the sibling of a
module with a kept `foreign`, cut to the kept exports as `--release` cuts it
(`backend.md` §9) — gets the same rule over the names its surviving code reads
free (`Minify.globalReads`), template substitutions included: a free name, or
a literal `globalThis.N`/`self.N`, must be on the list; `location`/`navigator`
members follow their lists; `typeof N` and a comparison of `N` or
`globalThis.N` with `undefined` are probes; a write `globalThis.N = …` and
`globalThis.M.bind(globalThis)` for M on the list cannot throw and are
accepted (beni code still may not write through a receiver); `Function`, `eval` and
`importScripts` are refused as above; a surviving `import` is refused,
because the imported module is not checked; a file the tokenizer or
elimination cannot read exactly is refused. A name is free when no scope
around the read binds it (*Sibling scopes and timers* below, amended
2026-11-07): a host name bound in one function and read free in another is
seen. A generated native binding's sibling is not read: its realm set is
its binding metadata, proved by the native pass. The alternative — each
sibling export declaring its realm — needs syntax and is the owner's decision;
#2211 records it.

**Sibling scopes and timers** (amended 2026-11-07, #2211). The sibling
reading has scopes; check 3 (`boundary.md` §4) keeps its scope-free reading,
unchanged. Over the tokens `Minify` already structures, a light lexical pass
binds:

- function and arrow parameters, with or without brackets, destructuring
  patterns and defaults included, and `arguments` in a function that is
  not an arrow, all in the function's scope;
- `var` in its function's body, or the module;
- `let`, `const`, `class` and function declarations in their block, or the
  module; a `for` head's declarations in the head and its body;
- a `catch` parameter in its block;
- a named function expression's name, and a class expression's, inside it;
- `import` names in the module.

A concise arrow body ends at the first `,`, `;`, template middle, unmatched
`:`, or line terminator automatic semicolon insertion may act on, at its own
level; a `for` body without braces at the first `;` or such line terminator.
A method's parameters are bound, and its name and a class member's name are
keys, only directly inside an object literal the pass can prove (a `{` after
`=`, `(`, `,`, `[`, `?`, `...`, `return`, or a `:` inside a proved object
literal) or a class body. A module-scope binding counts only when its
declaration survives elimination.

The pass errs one way: where it cannot tell which scope a binding belongs
to — a `function` or `class` that may be an expression, a method in an object
literal it cannot prove, a body cut short at a line terminator — it binds
nothing, and a read of that name is reported as free. A false refusal falls
on platform code, which can be written plainly; a false acceptance would
break the guarantee.

A timer — `setTimeout` or `setInterval`, bare or a literal member of
`globalThis` or `self` — evaluates a string first argument as code, so in a
kept sibling it is accepted only when it is called at once and its first
argument is provably a function: a function expression ending the argument,
an arrow, or a name the scopes bind to a function declaration, a named
function expression, or a declarator whose whole initialiser is a function
or an arrow, which nothing in the file assigns. Anything else — a string, a
template, a parameter, `.call`, `.bind`, an alias, no argument — is
`worker_realm_violation`, as dynamic code; `typeof setTimeout` stays a
probe. Every hand-written file in `core/` and the platforms reads the same
free names as before, and its one timer passes an arrow.

Fixtures: `build/bad/dedicated/RealmJSiblingShadowed`,
`RealmJSiblingTimerString` and `RealmJSiblingTimerParam` (refused),
`browser/dedicated/RealmScopedSafe` (a sibling that binds `document`,
`location` and `self` itself builds and runs).

**Release output.** A release worker writes a host global bare only when it is
on the realm's list (`backend.md` §9 item 8, amended 2026-11-07); otherwise it
keeps `globalThis.N`, which reads `undefined` where a bare N would throw.
Page output does not change.

Fixtures: `build/bad/dedicated/RealmJ*` (each refused access, siblings and
`importScripts` included), `browser/dedicated/RealmProbeSafe` and
`RealmAvailableSafe` (Chrome, development and release),
`emit/release/dedicated/RealmProbe`.

### Evidence and decision

The earlier typed-binding contract selected **C: generated real beni native types with inferred realm
summaries**, [2026-10-30, #1315](https://github.com/canassa/beni/issues/1315#issuecomment-6525030806).
The [census](research/workers-host-and-wire.md) records 556 native sites, 2,130
portable receiver operations and 170 caller-dependent sites. A and B are retained
only in [the comparison](research/workers-realm-options.md). No hidden native-shape
graph or manually trusted wrapper boundary replaces the selected mechanism.

The historical callback-typing census counted 130 erased-callable use sites,
including 41 in core/Task.beni, 11 in the inline renderer and 12 in browser/Rt.
These are historical use counts, not storage rewrite sizes or a landing
requirement to migrate the platform surface. The dated amendment governs raw Js. The inline projection requires
upcasts at 32 native sites. The full pinned IDL input has 346 files, 2,782 blocks
and 11,621 member rows; generated output size still needs measurement.

### Generated bindings and ordinary types

A Zig generator consumes pinned WebIDL exposure, inheritance, includes, member
types, overloads and callback declarations. It emits ordinary nominal opaque beni
types and typed operations, backed by checked binding artifacts. Each artifact
records native identity, type, realm set, effect, precise failure adapter and
direct-lowering recipe. Loading checks these against the pinned native table.
Ordinary packages cannot manufacture artifacts or native handles. No new realm
word is written in user or platform source: public summaries are inferred and
published from ordinary typed calls and the binding metadata.

For example, Document.querySelector returns a nullable Element. Node.textContent
accepts Node; Element.toNode is an explicit identity upcast because beni has no
subtyping. Generated mixin members belong to implementing interfaces. Native
callbacks retain their declared types: an Event parameter does not become a
MouseEvent merely because an event-name String says click. A richer binding
requires pinned event mapping and checked native validation.

Known operations lower directly to host operations. Native objects are their
own representation; there is no wrapper allocation, proxy, runtime type dictionary
or registration table added for typing. Generated packages load by indexed demand.
A versioned intrinsic table covers ECMAScript operations and non-WebIDL host
capabilities, with primary references and fixtures. Exact expected native errors
remain typed adapters; unexpected failures are defects, never broad catches.

### How access is proved

The ordinary type checker knows native identity through nominal types. Calls,
callback effects, static-dispatch evidence, containers, aliases and evaluated
module initializers retain those types and inferred realm summaries. A summary
is the intersection of reachable native operation availability. An entry must
prove its own realm belongs to every reachable operation's allowed set.
§14.5's nominal callback join is conservative: a worker that uses only
the safe field of `type Pair = Pair (⊤ → String) (⊤ → String)` is refused
when the other field is page-only; the corresponding record split is accepted.
Unresolved generic obligations propagate to interfaces and are discharged at
instantiation. An unreachable declaration does not reject an entry; an evaluated
initializer does. Recursive call components use a monotone fixed point.

The landing retains master’s Task and platform storage. Realm inference conservatively treats callable values erased by Js.from as
called in the enclosing declaration, including the work passed to Task.start.
Writes through Ref, Js.Ref, Deferred and Queue attribute stored callable
arrows to the writer. The obligation comes from the resolved callee's
scheme, so qualified calls, dot calls and aliases follow the same rule.
A local cell retains the same rule. A foreign callback dependency belongs to
its nearest enclosing positive arrow; a returned callback receiver keeps the dependency when stored as a
top-level value. These are realm-only edges and do not change purity or
suspension inference.

A foreign input at an unknown type carries a realm-only obligation on that
variable, owned by its nearest enclosing positive arrow. Ordinary schemes
preserve the obligation through generic wrappers and aliases. Interfaces
publish it as a typed dependency path; every instantiation exposes the
callable arrows in the substituted type, including records, nominal payloads
and containers. Further unknowns retain the obligation transitively.
This applies to generic erasure in Task.host and Hosted.host as well as
storage wrappers, cold and warm. It changes neither purity nor suspension.

Platform-private raw host intake follows the existing precise-error adapter contract.
Native identities and callback realm dependencies are preserved by typed bindings
and the inferred realm summaries. This landing does not require a new raw-value
type or a rewrite of Task, List or renderer storage. The landing amendment above
adds the kept-code global check to this optional typed-native mechanism.

Dynamic native selection uses cases over typed operations or a generated typed
selector. An arbitrary String cannot become a native member capability. Dynamic
plain-data access remains available. Reflection and eval cannot manufacture a
native proof; native reflection needs its own generated typed contract.

### Replacing host:page, diagnostics and cost

EntryHost replaces the platform-wide host:page promise. A platform chain
without entryHost has an unknown realm; only operations available in every
known realm are accepted, and a refusal asks the platform to declare entryHost. Each entryKind supplies
its execution realm and the checked reachable graph proves availability. Only
a proven Window lookup may print bare window. Shared chunks must be valid in
every importing realm; otherwise specialize them. Stale host:page manifests
report obsolete_host_promise instead of silently extending page authority.

| Diagnostic | Site and required explanation |
|---|---|
| worker_realm_violation | Native operation or type, entry realm, allowed realms and shortest inferred call or evidence chain |
| module_worker_import_scripts | Kept `importScripts` (bare, as a `globalThis`/`self` member, or in a kept sibling) and the entry realm; use a static import |
| type mismatch | Wrong generated receiver or selector; show expected native type and explicit upcast when applicable |
| unknown symbol | Misspelled generated operation, with the owning interface and suggestion |
| worker_callback_contract_unresolved | Callback parameter and forwarding path whose entry obligation remains unproved |
| entry_runtime_suspends | Runtime run and suspending chain; start an owned root fiber and return |
| invalid_entry_kind | Manifest symbol, parameter index, protocol row or type-role mismatch |
| worker_entry_not_static | Unresolved launch factory and a finite top-level-reference alternative |
| obsolete_host_promise | Stale manifest key and EntryHost replacement |
| worker_message_not_serializable / worker_transfer_alias_live | Message field or moved backing and live aliases; explicit conversion or copy guidance |

Realm summaries use a byte for the fixed native universe and ordinary inferred
callback and evidence obligations. There is no B-style per-declaration host-flow
graph reference. Realm propagation is O(V+E) for a fixed finite mask, removing each
bit once per node. Generated overload lookup uses bounded indexed candidates;
importing one type must not check the entire generated package.

Wire memoizes clone-stability and selective normalization plans per solved
representation node, with one classification byte and interned plan reference.
Protocol fingerprints belong to concrete roots, not every use. Interfaces hash
native binding identity and table revision, ordinary types and realm summaries,
Wire obligations, and entry protocol rows. Reverse users invalidate
when those exported facts change; a body-only change with the same summary does
not invalidate them. Old interface versions are rejected, not guessed.

These are complexity budgets, not measured performance. Maintain >250k LOC/s and
the existing 100k-line build target. Measure cold and warm time, peak memory,
interface size and generated package indexing, separately from generation time.
The emit/release/ goldens must show no byte growth caused solely by native types
or upcasts. #1296 measures shared-name wire plans. A budget failure is a compiler defect to resolve, not
permission to erase types or reopen the selected design silently.

## 5. Wire types and ownership under shared names

`Wire T` is compiler-derived evidence that a value can cross this boundary
with its meaning intact. Unit, booleans, numeric/string primitives, tuples,
records, arrays and tagged unions inherit the judgment from their fields.
Recursive types use a memoized graph. Functions, fibers, scopes, resume tokens,
DOM nodes and raw Js.Value do not acquire it. Opaque native types need their
owning module's native serialization/transfer contract; generic type variables
retain obligations until instantiated. Worker-local state is excluded from
this judgment because it never crosses.

Each Program declaration supplies one normalization plan in both realms,
shared by all of its instantiations. A type-variable position walks its runtime
value to materialize Lists inside records, tagged payloads, tuples and arrays.
An open record row walks only its unknown fields. Known fields retain their
static plans, so clone-stable subgraphs are skipped; normalization preserves
unchanged objects and arrays by identity. This selective walk neither encodes
values into a universal format nor relies on launch-site specialization.
Generic declarations retain their Wire obligations, discharged at concrete
launches; functions and native values are still refused. An unused role whose
value type remains unfixed, such as an error or event role, is accepted.

Shared names determine how Wire evidence lowers without weakening this guarantee.
Under the decided shared-name design, clone-stable records/unions/tuples/
arrays go straight to native structured clone. A recursive shape containing a
non-clone-stable child normalizes only the necessary paths. Today's emitted
list view has a function-valued `$plain`, so direct clone fails; a selective normalization plan must
materialize and rebuild it. Today's emitted Dict is still a plain tree, whereas
the normative ordered Dict design has `{entries,index: Map}`; a native Map
itself survives clone. Do not claim every Dict or nominal wrapper always needs
normalization. The measured representation table and protocol shape evidence decide.

Universal canonical codecs are the compared alternative, not adopted. Shared
names retain same-build and protocol fingerprints and explicit schemas for
external channels. A schema's Encoded remains a typed beni intermediate; a
conversion may suspend during prepare, while native commit is synchronous.
Prepared messages are opaque, not application-manufacturable casts.

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

*Amended 2026-11-07, owner decision (#2129).* The owned `policyName`/`policy`/`trust`
adapter resolves user allow/refusal decisions before the native constructor guard.
An existing default policy not owned by beni returns `ScriptPolicy (PolicyRefused …)`
without invoking it or constructing a worker. Owned native policy identities are
tracked privately; their callbacks are total. The native constructor guard never
runs arbitrary foreign callbacks. This replaces pre-resolving arbitrary defaults:
Chrome proves that a null-refusing default and an empty-string-returning default
produce the same branded empty URL through public `createScriptURL`, while direct
Worker construction rejects only the former. Both foreign defaults must be refused.
[Research §10](research/workers-api-research.md#10-owned-trusted-types-policy-adapter)
owns the algorithm, counterexample and required fixtures.

*Amended 2026-11-07, the owner's decision (#2208).* **An owned policy in the options is used
first.** `open` given `options.policy = Just p` mints the compiled entry's URL with `p` and hands the
constructor that `TrustedScriptURL`, whatever default policy the page has: a branded URL never reaches
a default callback (research §10), so a foreign default is no reason to refuse. The refusal above is
for `options.policy = Nothing` alone. Before this, the foreign-default check ran first, and a page
that needed a default policy to render its markup could open no worker at all; a markup build with
`"trustedTypes": true` (`backend.md` §15.3) needs no default policy, so the CSP
`require-trusted-types-for 'script'; trusted-types <name>` serves both. **`scriptUrl`, `trust`,
`ScriptUrl`, `UrlError` and `NotTrustedScriptUrl` are withdrawn.** `open` loads only the URL the
compiler wrote for the program's entry, and no public function took a `ScriptUrl`, so `trust`'s
`allow` decided nothing that `open` did: a refused URL could still be opened with the same policy.
They return with the first operation that loads a URL a program chooses (`workers-api.md` §1,
*External endpoints*), whose `allow` then gates what it loads. Pinned by
`tests/corpus/browser/managed/PolicyBesideForeignDefault` (Chrome: an owned policy opens a worker
beside a foreign default policy, which is never called) and `PolicyMarkupPage` (Chrome, under the
CSP above: a page whose view is markup renders and opens a worker).

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
return the typed cleanup status for the caller to inspect. At the fatal deadline the decided fatal-stop policy abandons unfinished
cleanup and records every such worker as specified below.
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

The defect report contains `abandonedWorkers : List AbandonedWorker`. Each
entry records entryId (stable build entry identity), instanceId (runtime instance
and generation), kind (Dedicated or Shared), diagnosticName, and termination
status (NativeTerminated, SharedStopRequested or Unreachable). This is private
runtime report data, never an application error or a Task.Exit case. Preserve
the original defect and append shutdown outcomes, deduplicated by instanceId.
The registry bounds live and orphaned workers, so include every unfinished
worker rather than silently truncate the list. Nested reports carry the owning
instance path to avoid conflating workers with the same entry name.

When the existing program fatal-shutdown deadline expires, terminate every unfinished dedicated worker
for which this runtime holds the native Worker handle; mark NativeTerminated
without claiming finalizers ran. The shared runtime broadcasts its defect to
every attached beni page before cancelling its children. Every page stops and
shows or logs its own defect, even if no request was awaiting a reply.

The browser exposes no terminate method for SharedWorker. Its own runtime
coordinator requests global close at the fatal deadline, without joining its
unfinished children, and reports SharedStopRequested. An unreachable or hung
shared instance cannot be forcibly killed from a page; report Unreachable and
stop that page rather than assert native termination. This host capability
limit is tracked in #1302 and #1298. It does not delay the page's fatal shutdown
or authorize continuing after a shared defect. Ordinary page close affects only
its connection and never sends this instance-fatal control operation.

### Private control values

*Added 2026-11-07 (#2203).* A release build names record fields per entry: §3's
one build-wide table covers the Wire roles only, and each projection pins the
fields of its own boundary (`boundary.md` §4, *What JavaScript may read of a beni
value*). A `Js.from` and a `Js.to` at the same type variable are opaque only
inside one entry; across the page and a worker the two sides do not share a
spelling. So a platform-private value that crosses entries is never a beni record
read back through a type-variable cast. It is a frame the sender builds with a
concrete `Js.from` and the receiver reads by key, and every key is either kept
in every build or one of the private worker encoding's prescribed keys
(`src/js/WorkerEncoding.zig`), which both projections encode alike. The Hello
payload is `config` (Wire role 0) plus the two event limits, `eventLimit` and
`byteLimit`, copied from the page's `queuedEvents` and `queuedBytes`. It does not
carry `Options`: the worker reads nothing else from it. The release worker that
read `Options` through a type-variable cast got its own short field names,
found the limits undefined, and accepted every event.

### The page's event queue

*Added 2026-11-07 (#2203).* The page's `events` queue holds `queuedEvents`
items. The worker counts every event it sends against `queuedEvents` and
`queuedBytes`, and the page acknowledges an event only when its reader takes it.
So a conforming peer cannot overfill the page's queue: `emit` returns
`EventQueueFull` first. An Event frame that finds the queue full therefore comes
from a broken peer. It is a defect, through the program's fatal path, never a
dropped event. An Event frame that arrives after the queue ended (Closed, or a
transport failure already delivered to the reader) is ignored, because the
reader has been told the stream ended.

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
clients get separate connection IDs, quotas and scopes. Under normal lifetime
policy the worker closes only after its last connection and root work settle.
Fatal shutdown follows §7 instead: its deadline may abandon unfinished cleanup.
`extendedLifetime` is a request to the browser, not a guarantee.

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

Deferred to #2186: streams would use scoped request IDs with monotonic chunk sequences and finite
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

See [workers-api.md](workers-api.md) for the public signatures. The streaming
[examples](workers-example.md) are deferred to #2186.

*Owner decision, 2026-11-07 (#2129).* Request/response streaming is deferred to
[#2186](https://github.com/canassa/beni/issues/2186). The public Definition has
only init, start and handle; it has no stream callback. No write/cancelStream
operation or Sink is published. WorkerStream remains the existing bounded
unsolicited-event reader used by Worker.events; its old copying-data behavior
is unchanged. The stream protocol above is deferred design, not an implemented
or published API. The prototype and its Chrome fixtures are saved with #2186.

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

The concrete [build planning and entry projection contract](workers-emission.md)
specifies the emitter restructuring before implementation. The
[generic runtime foundation](workers-entry-implementation.md),
[typed callback storage](https://github.com/canassa/beni/issues/1612) and
[native binding generation](workers-native-bindings.md) specify their concrete
implementation boundaries. Progress is tracked
in [the implementation plan](https://github.com/canassa/beni/issues/1612).


| Slice | Depends on | Done |
|---|---|---|
| Entry runtime contract | This design | #1287 generalized to realm runtime table, precise program/arity/effect diagnostics and no markup dependency; dev/release fixtures. |
| Multi-entry emission and bootstrap | Runtime contract | Source-discovered generic entry descriptors, stable IDs, staged defect bootstrap, relative URLs, per-entry roots/maps/collisions and jobs 1/8 output fixtures; never user JS. |
| Realm checking | Multi-entry roots; decided C (#1315) | Generated native types, inferred realm summaries, interface contracts and EntryHost proofs; >250k LOC/s and no-byte-growth release goldens. |
| Shared-name wire plans and ownership moves | Realm check; #1278 | Cross-entry type evidence, decided build-wide names and selective normalization plans, backing alias demands and partial-failure consumption; negative and round-trip corpus. |
| Dedicated runtime and defects | Prior compiler slices; ownership checker v2 | Borrowed worker-local init/state/root scope, distinct call/stream protocol roles, unsolicited events, full machine adapter, precise native errors, bounded ready handshake, requests/exits/Log, cancellation/scopes and page defect routing proven in Chrome. |
| Ports, shared workers and broadcast | Dedicated protocol | All inventoried options/overloads/events, shared initializer election versus configuration-free attach, leases/connection scopes, external schema validation, cross-tab and messageerror fixtures. |
| Native transfer families and atomics | Wire ownership; #1278/#1277 | Every standard type row assigned, implemented and browser-tested or explicit capability refusal; GPU integration, shared memory and typed exact failure coverage. Proposal rows remain explicitly unsupported until their specifications define transfers (#1302). |
| Pools, streams and parity measurements | Dedicated/ports | Fixed/elastic bounds, credit/ack/cancel, keep-alive, no implicit retry of moves, size/latency reports and parity-ledger evidence. |
| Service-worker lifecycle design | Separate design, decided #1301 | Registration/update/event-lifetime/errors and no-DOM realm contract designed separately; this is a research/design slice, not authorization to implement it here. |

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
- Shared-name wire plans and ownership moves: [1296](https://github.com/canassa/beni/issues/1296).
- Dedicated runtime and defects: [1297](https://github.com/canassa/beni/issues/1297).
- Ports, shared workers and broadcast: [1298](https://github.com/canassa/beni/issues/1298).
- Native transfer families and atomics: [1299](https://github.com/canassa/beni/issues/1299).
- Pools, streams and parity measurements: [1300](https://github.com/canassa/beni/issues/1300).
- Service-worker lifecycle design: [1301](https://github.com/canassa/beni/issues/1301).
- Owner lifecycle decisions: [1302](https://github.com/canassa/beni/issues/1302).
- Owner realm-mechanism decision: [1315](https://github.com/canassa/beni/issues/1315).
- Owner wire-layout decision: [1305](https://github.com/canassa/beni/issues/1305).
- Suspending browser commands prerequisite: [1306](https://github.com/canassa/beni/issues/1306).

**Landing corrections, 2026-11-06 (Part of #1612).** Core Schema.Value is
trusted plain JSON data and is clone-stable Wire data in direct and generic
positions. Known List payloads normalize through master's `$plain()` protocol,
including trie headers and active views; ordinary lookalike records stay records.
A null or non-object managed frame defects with `Invalid managed worker frame`
before any property read. Defect reports preserve identifier-like error names,
including digits and `$`, as well as their message, stack and entry metadata.

The dedicated runtime registers realm cleanup through the worker-private
`Task.chainDefect` bridge. It accepts a synchronous callback, installs it before
the existing defect handler, and preserves that prior handler. The function is
impure, stores its callback, and remains fenced to the worker runtime's owning
platform modules; it is not an application Task API. This bridge retains master’s
defect storage and scheduler behavior.

The replay's P-sync inventory pins `Browser.Worker.listen`, `installFatal`
and `runDefinition`. `listen` retains a guarded host listener on its peer and
stops the realm on an escaping defect. `installFatal` installs the private
cleanup bridge and records the first native defect without running application
work. `runDefinition` registers the worker control-frame listeners: these mutate
transport state, enqueue requests or start/resume owned fibers; handlers run
through those fibers. The bodies retain transport callbacks and peer state,
so these pins assert no borrowed or pure ownership shortcut.

The `runDefinition` pin was reread for the 2026-11-06 receiver amendment:
only the stored global-self endpoint was removed. Its owned root, boot call,
control listeners, queue, cancellation and final close retain their previous
behavior and custody. Posting resolves the worker global directly instead.
The existing retention justification remains; no borrowed/pure claim is added.
