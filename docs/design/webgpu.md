# WebGPU for beni

**Status: adopted 2026-11-08; not yet implemented.** The owner adopted this
contract with all six §11 recommendations as decisions
([#1277](https://github.com/canassa/beni/issues/1277#issuecomment-6714461181)),
together with the handle layout of §2.1 ([#1281](https://github.com/canassa/beni/issues/1281)),
the typed lease refusal of §6.4 ([#1270](https://github.com/canassa/beni/issues/1270))
and main thread first (§2, §10). The research issue was
[#1257](https://github.com/canassa/beni/issues/1257); the adoption slice is
[#2238](https://github.com/canassa/beni/issues/2238); implementation follows
the slices of §10. Evidence: [research](research/webgpu-api-research.md),
[failure ledger](research/webgpu-errors.md), [source pins](research/webgpu/sources.json),
[complete coverage inventory](research/webgpu/coverage.md) and
[the independent review](research/webgpu-spec-review.md), whose six findings
this revision closes (§3.1, §6.4, §7.1, §8.2, §8.3).

**Owner decision, 2026-10-30:** expose WebGPU directly. Elm WebGL informs API
ergonomics; the additional mesh/entity/view abstraction is removed.

## 1. Goals and the meaning of complete

Expose **all of the pinned browser WebGPU standard**, including graphics,
compute, offscreen rendering, every standard optional feature, every descriptor
member, supported limit, enum value, overload, format, resource, command, query,
canvas operation, WGSL facility and error channel. The baseline is the
[15 September 2026 Candidate Recommendation Draft](https://www.w3.org/TR/2026/CRD-webgpu-20260915/),
checked against editor revision `a1a1e79f35f93ad6db255dc170621ae7e411eba0`;
WGSL is the [26 October 2026 draft](https://www.w3.org/TR/2026/CRD-WGSL-20261026/).
The inventory is the exact API checklist. “Supports WebGPU” cannot mean just
rendering a triangle, or only the intersection of today's browser implementations.

All **documented observable failures** become typed beni results/events.
Unexpected exceptions, rejections, host values and broken wrapper invariants
become defects through the existing program defect path. There is no
`UnknownError String` escape hatch, no silent GPU error, and no generic catch.
Defined `GPUInternalError` and defined device-loss reason `"unknown"` are typed
outcomes, not unrecognized failures.

The standard cannot expose every error hidden by its implementation. Error
scopes report one representative per scope; events may be suppressed; lost
devices suppress ordinary errors; WGSL dynamic errors can be undetectable.
Therefore “all errors” cannot literally mean a complete list of every shader
fault. We guarantee all standard failure **channels** and honest success
semantics, not observations the browser does not provide. This constraint is
part of the contract and must be visible in the public API docs.

Native-only extensions and non-normative GPUWeb extension documents are outside
this browser contract. New standard revisions require an explicit inventory,
failure-ledger and binding update. Unsupported optional standard functionality
returns a typed availability error; the library never silently changes its
meaning or substitutes another rendering API.

## 2. Placement and layers

Implement `Gpu.*` in the shipped browser platform and reexport through its
browser/TEA/direct page layers where applicable. Core stays platform-independent;
the generated native GPU types live with the other generated
`Browser.Host.*` modules in core (§2.1, §2.2). GPU objects are opaque
platform-owned handles; ordinary modules never import `Js` or pass raw
JavaScript objects. Implement orchestration, descriptors, validation, lifetimes
and error classification in beni over `Js`, following the existing Task/Http
boundary discipline. New host primitives need the same exact
foreign/type/arity/effect checks as other platform primitives.

| Layer | Purpose | Completeness rule |
|---|---|---|
| `Gpu.Handle` | The handle types: aliases of the generated native types and the engine's own handles (§2.1) | Every native GPU object interface of the inventory |
| `Gpu`, `Gpu.Types`, `Gpu.Flags`, `Gpu.Feature`, `Gpu.Limits`, `Gpu.WgslFeature`, `Gpu.Scalar`, `Gpu.Error` | Availability, typed descriptors/scalars/unions/constants, capability negotiation, the error sums of §5 | Entire IDL and standard feature/format tables; descriptors, enums and flags are generated (§2.2) |
| Resource and command modules | Checked native capabilities with managed state, mapping and encoding | Every inventoried interface/member/overload |
| `Gpu.Batch`, `Gpu.Frame`, `Gpu.Diagnostics` | Scope-safe grouped operations, presentation and explicit diagnostics | Same native operations and typed errors; no hidden capability gap |
| Supporting `Binary`, `Browser.Image`, `Browser.Video`, `Browser.Canvas`, worker transfers | Typed binary/source/canvas interoperability | Every native input union arm is constructible; no application FFI |

The last row is **new API work**, not an assertion that those modules exist.
Its main-thread part is [#1278](https://github.com/canassa/beni/issues/1278)
(binary storage, WGSL layout codecs and the image, video and canvas sources;
`binary.md` on its branch). Their delivery is required before claiming full
coverage. Page markup integration belongs to the browser runtime, not compiler
special knowledge of GPU descriptors.

**Main thread first** (the owner, 2026-11-08). The slices S1–S6 of §10 build
and test the `Window` realm. WebGPU in a worker realm, `OffscreenCanvas`
transfer (not a main-thread `OffscreenCanvas`, which S3 and S5 cover), and
typed transfers of bitmaps, video frames and binary backing wait
for [#1299](https://github.com/canassa/beni/issues/1299), the native transfer
families of the worker design ([`workers.md`](workers.md)), and form a later
slice of §10. They stay in the completeness scope (§1, §11 item 5): completeness
is claimed only after that slice. The foundation still follows the
specification's `Window` and `Worker` exposure, not only the main window
(§2.3), so the worker slice adds entries, transfers and fixtures, not a
redesign. SharedWorker/ServiceWorker realms that expose the API must be usable
by the same headless modules; missing host capabilities are typed availability
outcomes. DedicatedWorker is the first worker integration fixture, not an
exclusion of the other standard Worker realms.

### 2.1 Handles and module layout (#1281)

*Decided by the owner, 2026-11-08: the handle types live in one acyclic
`Gpu.Handle` module; `Gpu.Types` and the operation modules import it.*

**Native handles are generated native types.** Under the selected option C
([`workers.md`](workers.md) §4, *Generated bindings and ordinary types*;
[`workers-native-bindings.md`](workers-native-bindings.md);
[#1315](https://github.com/canassa/beni/issues/1315)) every WebGPU interface of
the pin has a generated module `Browser.Host.GPU<Name>` that exports
`pub foreign type GPU<Name>`. Its representation is the native object itself:
no wrapper record, proxy or allocation. **For a GPU interface that module holds
the type and nothing else.** No GPU member becomes a reviewed callable row of
`src/native/Operations.zig`: a raw native GPU call returns an invalid object
and sends its validation error to the uncaptured-error event, which would
publish an unchecked handle (§5). The checked engine of §6 is the only route to
a GPU operation, and it calls the host through private code (non-`pub`
`foreign` declarations or `Js`), never through a `pub` value an application
can import. *As built — S1 (2026-11-08):* `browser-tea` re-exports the public `Gpu`
modules only, so a TEA program cannot import `Gpu.Engine` or `Gpu.Native`; a direct
`browser` program can, since a platform cannot keep a module from the program it is the
top of (#2256). Their signatures name `Js.Value`, which such a program cannot make. The
private `Gpu.Memory` (S2a), `Gpu.Make` and `Gpu.Session` (S2b) are in the same position,
accepted as debt under #2256.

**`Gpu.Handle`** imports only core, including those generated modules, and no
`Gpu` module. It declares:

- a transparent alias for every native object handle, named by dropping `GPU`
  with the exceptions of §3: `pub type alias Device = Browser.Host.GPUDevice.GPUDevice`,
  and likewise `Adapter`, `Queue`, `Buffer`, `Texture`, `TextureView`,
  `Sampler`, `ExternalTexture`, `BindGroupLayout`, `PipelineLayout`,
  `BindGroup`, `Shader` (`GPUShaderModule`), `ComputePipeline`,
  `RenderPipeline`, `CommandEncoder`, `CommandBuffer`, `ComputePass`
  (`GPUComputePassEncoder`), `RenderPass` (`GPURenderPassEncoder`),
  `RenderBundleEncoder`, `RenderBundle`, `QuerySet` and `Surface`
  (`GPUCanvasContext`);
- a `pub foreign type` for each handle the engine makes with no native object
  of its own: `Mapping`, `MappedRange`, `Submission`, `Batch`, `Frame` and
  `DiagnosticSession`. Only privileged platform code constructs them; an
  application cannot.

`Gpu.Types` imports `Gpu.Handle` (descriptors name handles: a bind-group entry's
resource, a canvas configuration's device). The engine imports both, and the
operation modules (`Gpu.Device`, `Gpu.Buffer`, …) import all three and may
re-export the aliases for readable signatures. The graph is
`Browser.Host.GPU*` ← `Gpu.Handle` ← `Gpu.Types` ← engine ← operation modules ←
`Gpu`, with no cycle.

**Per-object state lives beside the native object, not on it.** Device
identity, `Provisional`/`Accepted`/`Rejected` status, destroyed state, mapping
generation and encoder state live in an engine-owned side table keyed by native
identity (a `WeakMap` per realm). The engine never writes a property onto a
native object. Every alias of a handle is the same native object, so aliases
share state as §6.3 and §7 require. A native GPU object with no table entry was
not produced by the engine; meeting one is a defect.

**What static dispatch reaches** (the owner, 2026-11-08: every GPU operation is
a qualified call or a `▷` pipe, with no exceptions). By
[`static-dispatch-spike.md`](static-dispatch-spike.md) §1.2, `x.m a` on a value
of nominal type `T` resolves only to a `pub` value of the module that declares
`T`, and an alias is looked through to what it names. No module can hold the
operations as methods:

- **Native handles.** The alias in `Gpu.Handle` is looked through to
  `Browser.Host.GPU<Name>`, so a forwarding method written in `Gpu.Handle`
  can never be reached from a native handle. The declaring module itself
  cannot hold them either: under option C it is generated into core, core
  cannot import the browser platform's engine, and §2.1 keeps those modules
  free of callable GPU rows.
- **Engine handles.** `Gpu.Handle` declares all six, and a module's values are
  one namespace: one value is the method of every type the module declares
  ([`checker-v2.md`](checker-v2.md) §11.3; `static-dispatch-spike.md` §3.3
  step 1). A `destroy` or `label` written there would be one value for
  `Mapping`, `Batch`, `Frame` and the rest, and the types would clash.
  `Gpu.Handle` also cannot import `Gpu.Types`, `Gpu.Error` or the engine
  without a cycle.

So **dot-call does not reach GPU operations**: `device.createBuffer desc` is
`unknown_method`. An operation is called qualified, or through the
receiver-first pipe, which §1.2 names as the way to reach a function the
type's module does not own:

```text
buffer = Gpu.Device.createBuffer device desc
buffer = device ▷ Gpu.Device.createBuffer desc
```

No language or module feature is added to move method ownership. `==` on a GPU
handle is `unknown_method`, as for every other host handle
(`static-dispatch-spike.md` §3.5); an identity `eq` would be a later, separate
decision.

**Every GPU interface, classified.** The pin has 36 interfaces. Each is one
of three kinds:

| Kind | Interfaces | In beni |
|---|---|---|
| **Handle** (22), aliased in `Gpu.Handle` | `GPUAdapter`, `GPUDevice`, `GPUQueue`, `GPUBuffer`, `GPUTexture`, `GPUTextureView`, `GPUSampler`, `GPUExternalTexture`, `GPUBindGroupLayout`, `GPUPipelineLayout`, `GPUBindGroup`, `GPUShaderModule`, `GPUComputePipeline`, `GPURenderPipeline`, `GPUCommandEncoder`, `GPUCommandBuffer`, `GPUComputePassEncoder`, `GPURenderPassEncoder`, `GPURenderBundleEncoder`, `GPURenderBundle`, `GPUQuerySet`, `GPUCanvasContext` | The native object, with state in the side table; operations in `Gpu.<Name>` |
| **Snapshot** (13), an immutable beni value | `GPUAdapterInfo` → `Gpu.Types.AdapterInfo`; `GPUSupportedFeatures` → `Gpu.Feature.Features`; `GPUSupportedLimits` → `Gpu.Limits.Limits`; `WGSLLanguageFeatures` → `Gpu.WgslFeature.WgslFeatures`; `GPUCompilationInfo` and `GPUCompilationMessage` → `Gpu.Shader.CompilationInfo` and its message records; `GPUError`, `GPUValidationError`, `GPUOutOfMemoryError`, `GPUInternalError` and `GPUPipelineError` → the `Gpu.Error` sums of §5; `GPUDeviceLostInfo` → `Gpu.Error.DeviceLoss`; `GPUUncapturedErrorEvent` → `Gpu.Device.DeviceEvent` | Read once by the engine into records and sums with every native field; the native object is never a beni value |
| **Entry point** (1) | `GPU` (`navigator.gpu`) | Engine-internal; its members are the functions of the `Gpu` module |

The generated `Browser.Host` types of snapshot and entry-point interfaces are
used only inside the engine. A snapshot of a readonly setlike
(`GPUSupportedFeatures`, `WGSLLanguageFeatures`) is the total-set adapter of §3.

### 2.2 Generated inputs and their pin

**The IDL of record** is `webgpu.idl` in the `@webref/idl` 3.86.0 archive that
[`research/workers/sources.json`](research/workers/sources.json) pins and the
native-bindings tool already verifies by SHA-256. Checked on 2026-11-08: with
its four-line generated-file comment removed and whitespace collapsed, that
file is token-identical to [the extract](research/webgpu/webgpu.idl) from gpuweb
`a1a1e79f35f93ad6db255dc170621ae7e411eba0` (both normalise to SHA-256
`fda59effe3c6c1cc11cfc2ffe7d3595d4310e460c14388dd1d9c49c58434664b`). The two
pins therefore agree on the API surface. [`research/webgpu/sources.json`](research/webgpu/sources.json)
still pins the prose, WGSL and CTS that the ledger and acceptance tests cite.
Bumping either pin repeats this comparison and updates the inventory, the
ledger and the generated files together (§1). The archive also holds
`webxr-webgpu-binding.idl`; its `XRGPU*` declarations are WebXR's and are
outside this contract (§4, `xrCompatible`).

**One generator.** The existing Zig native-bindings tool (`src/native/`,
`zig build native-bindings`) gains a WebGPU emitter over the dictionary, enum,
typedef, callback and constant-namespace rows it already retains. From
`webgpu.idl` it writes:

- the `Browser.Host.GPU*` type modules of §2.1;
- `Gpu.Types`: one record per dictionary with every inherited member
  (required, `Option a` or `Option (Maybe a)` per §3 item 2), one closed ADT per
  enum with total spelling conversions both ways, one sum per union, and the
  descriptor-to-native conversions that omit every `Default` member;
- `Gpu.Flags`: the five flag domains and the exact values of their constant
  namespaces.

Names follow a versioned map in the generator (`GPUBufferDescriptor` →
`Gpu.Types.BufferDescriptor`, with §3's exceptions); a collision is a generator
error, never a silent rename. Hand-written beni (`Gpu.Scalar`, descriptor
convenience constructors, the engine) never lives in a generated file. There is
no Python and no network access at generation time.

**Staleness is a gate.** The generated files are committed. A test inside
`zig build gates` regenerates them in memory from the pinned archive and fails
when a committed file differs, as `skill-api`'s check does. (The existing check
for the shipped `Browser.Host` modules runs in `test-native-bindings`, outside
the gates; the GPU files need the gated check.) The step that writes them is
`zig build gpu-bindings` (*As built — S1*, 2026-11-08: `tests/gpu_bindings.zig` holds
the staleness check, the census of every declaration and the exposure assertion, and
runs in `test-blackbox`; `src/native/Gpu.zig` holds the name maps, version 1). The
generated `Gpu.Types`, `Gpu.Flags`, `Gpu.Limits` and `Gpu.Native` are held to the
generator, not to `beni fmt` (`tests/fmt-exempt.txt`). Two `Gpu.Types` dictionaries are
not descriptors and are not emitted: `GPUPipelineErrorInit` and
`GPUUncapturedErrorEventInit`, the constructor inits that §3 replaces with pure values.
A snapshot is read member by member: a member missing or of another type — a count that
is not a non-negative integer included (NaN, an infinity, a fraction) — is a defect that
names it, except the members `optional_members` lists, newer than the rest of their
interface or tied to a feature (`maxImmediateSize`, the four per-stage storage limits,
`subgroupMinSize`, `subgroupMaxSize`), which are `Maybe Int`; `Gpu.Limits.limit` is
therefore `Maybe Int`. The sequence arm of `GPUColor`, `GPUOrigin2D`, `GPUOrigin3D` and
`GPUExtent3D` carries an opaque list (`ColorList`, …) that only a constructor checking the
length the host accepts makes, `Nothing` otherwise, so no value of the union throws at
conversion (§3's table).

*As built — S1 (2026-11-08), the engine's waits (§6.4, §8.1):* each request first opens
a channel to its program, a detached fiber of the requester, and classifies its outcome in
the promise's reaction whether or not anyone still waits; an adapter is reserved only when
its request really starts, so a cancel delivered before the wait leaves it free. A defect
carries its context, an `Error` naming the operation and the device with the original as
`cause`. A channel keeps the caller's clock and log context for the one path that must
start a new fiber (core gives no way to keep its scheduler, #2257), and drops a second
defect, whose program the first one stopped.

### 2.3 Realms

All 41 exposure-annotated declarations of the pinned `webgpu.idl` are
`Exposed=(Window, Worker)`, and both `Navigator` and `WorkerNavigator` include
`NavigatorGPU`. Window-only types reach WebGPU only through HTML element arms:
`HTMLCanvasElement`, `HTMLVideoElement` and `HTMLImageElement` in
`GPUCopyExternalImageSource`, the external-texture source and
`GPUCanvasContext.canvas`.

**What is proved, and what is assumed.** Realm summaries are inferred
([`workers.md`](workers.md) §4, *How access is proved*); no realm word is
written. But the engine calls the GPU through private code (non-`pub`
`foreign` declarations or `Js`), not through reviewed callable rows, so no
GPU operation carries an availability seed of its own. The inferred summary
of a GPU operation sees only the engine's global access, `navigator.gpu`, a
literal member read of the `navigator` global that the kept-code check allows
in every worker realm. The engine never reads `window` or `document`. **A GPU
operation is therefore admitted in a worker only because every WebGPU
declaration of the pin is `Exposed=(Window, Worker)`**, not because the realm
check proves it per operation.

The assumption is made a check: **the generator asserts uniform exposure.**
When any declaration of `webgpu.idl` — an interface, a partial interface, a
mixin's including interface or a member with its own `[Exposed]` — is exposed
other than exactly `(Window, Worker)`, generation fails with a diagnostic that
names it and writes no output. Such a member then needs a reviewed availability
seed before the engine may call it. A future Window-only member cannot slip
into a worker build unnoticed.

The Window-only parts reach the engine through other modules whose summaries
are proved: the element arms come from generated HTML element types and the
`Browser.Canvas`, `Browser.Image` and `Browser.Video` intake (§3.2).
Window-only GPU operations (`Gpu.Surface.fromElement`, the element arm of
`Gpu.Surface.canvas`) are separate declarations, so reachability drops them
from an entry that does not call them, and they are never stored in the same
nominal value as a portable callback (§4's conservative nominal join). Any
engine sibling obeys the same kept-code check, its lexical scopes and timers
included ([#2211](https://github.com/canassa/beni/issues/2211)).

## 3. Mechanical translation of the whole native API

[coverage.md](research/webgpu/coverage.md) is normative for this contract's
surface, including empty declarations, inheritance, partial interfaces and all
37 mixin inclusions. Its owner column names the operation module where each capability lives.
Each interface's handle is the alias `Gpu.Handle.<name without GPU>` of its
generated native type, and its operations live in the operation module
`Gpu.<name without GPU>` (§2.1); shader modules use `Gpu.Shader`, pass
encoders use `Gpu.ComputePass`/`Gpu.RenderPass`, canvas contexts use
`Gpu.Surface`. Constructors of errors/events become typed beni
values, not raw JavaScript constructors. Host errors retain their diagnostic
metadata; synthetic values cannot fabricate GPU failure dispatch.

For each member the translation is deterministic:

1. The receiver is the first argument; remaining arguments stay in native order.
   Functions use saturated n-ary beni types with the receiver first, so that
   `▷` reaches them. Every GPU operation is called qualified or with `▷`;
   dot-call is not supported (§2.1).
2. Every descriptor has a typed `Gpu.Types` record with all inherited fields.
   Required fields remain required. Optional fields use `Option a = Default |
   Value a`. `Default` means **omit the property**, preserving the native
   algorithm's default. `Value x` emits it explicitly, even when x equals a
   documented default. Nullable fields use `Maybe a`; optional nullable fields
   use `Option (Maybe a)`. `Nothing` and omission are not conflated.
3. Enums are closed ADTs with a total spelling conversion. All texture and
   vertex formats, blend factors, stencil/depth operations, binding kinds,
   dimensions, aspects and load/store values are included. Future *returned*
   enum values are defects until added. Reported feature-name sets stay
   extensible opaque names, with known named constants for the pinned set.
4. Flag domains are distinct opaque sets: buffer usage, texture usage, shader
   stage, color write and map mode cannot be confused. All five constant
   namespaces and their exact values are represented. All legal combinations
   are expressible; invalid combinations yield typed input or GPU validation
   errors. Map mode has explicit read/write constructors.
5. Web IDL sequences become lists or typed binary views as appropriate.
   Nullable slots stay nullable: color targets/attachments, vertex layouts,
   unbound vertex buffers and bind groups must all be expressible. Records of
   override constants preserve names/IDs and numeric values. A union becomes
   a typed sum; no union arm is dropped for convenience.
6. `undefined` becomes `⊤`, promises become direct functions with an inferred
   suspend effect, and expected failures become `Result Error a`. A native
   non-promise operation can still suspend while checking its GPU scopes.
   Native immutable attributes become total snapshot getters; mutable state
   getters read authoritative shared wrapper/host state without caching lies.
7. Shared mixin methods are available on each including encoder/pipeline type.
   The `setBindGroup` slice overload gets the distinct beni name
   `setBindGroupSlice`; source element offset/length remain explicit.
   Label access is `label`/`setLabel` in each handle's operation module
   (`Gpu.Buffer.label`, …), since beni has no overloading over the handle
   kinds. It is not restricted to buffers or only present in development builds.
8. Native `mapAsync` is `Gpu.Buffer.map`; `getMappedRange` becomes the scoped
   range API in §7. Native `lost`/`onuncapturederror` become lifecycle/event
   APIs in §8. Encoding methods get the non-suspending session form in §6.
   Native push/pop get the managed diagnostic form there. These are explicit
   safety adapters, not omissions. `Gpu.Types` stores their original data.

Exact type translations for special unions:

| Native type | Beni form |
|---|---|
| `GPUBindingResource` | Sampler / Texture / TextureView / Buffer / BufferBinding / ExternalTexture alternatives, exactly as in the pinned typedef |
| Pipeline layout `GPUPipelineLayout or GPUAutoLayoutMode` | `Explicit PipelineLayout` or `Auto` |
| `GPUColor`, origin and extent dictionary/sequence unions | Typed canonical record plus sequence-form constructors preserving the native shape/range checks; ergonomic records cover every valid coordinate value |
| `GPUCopyExternalImageSource` | `Bitmap`, `ImageData`, `ImageElement`, `VideoElement`, `VideoFrame`, `CanvasElement`, `OffscreenCanvas`, each carrying a typed source handle |
| External-texture source | Video element or VideoFrame; both are available independently of image copying |
| `AllowSharedBufferSource` | Tagged typed binary source retaining view kind, offset, length and shared/nonshared backing |
| Canvas `.canvas` | Typed HTMLCanvasElement / OffscreenCanvas sum |
| GPU/pipeline errors and compilation info | ADTs and records with all native diagnostic fields; no raw object leakage |

Capability sets expose total `has`, `values`, `size`, and traversal. Native
readonly setlike iteration/forEach is covered by these adapters; mutation is
not introduced. The inventory's inherited `EventTarget` role becomes the typed
event observer API, with synthetic error/event data for testing/serialization.
No arbitrary event dispatch into a native device is needed to render or compute.

### 3.1 Numeric and binary domains

Do not treat an unbounded beni `Int` as a validated GPUSize32. Provide opaque
`U32`, `I32`, `Size64`, `FiniteF32` and `FiniteF64` scalar constructors with
`Result InputError` and conversion helpers. *Departure, 2026-11-08, pending owner
confirmation:* the constructors return `Result Gpu.Scalar.DomainError`, and
`Gpu.Error.InputError` carries it as `NumericDomain { path, domain : DomainError }`;
`Gpu.Error.atPath : String, DomainError → InputError` makes one. `Gpu.Error` names
`Gpu.Types` (a feature or a format in a failure) and `Gpu.Types` names `Gpu.Scalar`, so
`Gpu.Scalar` cannot name `Gpu.Error` without a module cycle. Their accepted domains cover every
value the corresponding Web IDL type accepts after conversion. Integer
constructors require integral values; callers can request the standard's
truncating conversion explicitly. Preserve signed baseVertex/depthBias, not
just unsigned offsets. Finite f32 conversion must check overflow after f32
rounding. Raw buffer bytes may contain NaN or infinities where WGSL permits
those patterns; descriptor numeric checks do not restrict binary payloads.

*Corrected 2026-11-08* (the earlier text here gave `Size64` integers above 2⁵³, which the
host refuses): `Size64` covers the integers 0 … 2⁵³ − 1. `GPUSize64` is
`[EnforceRange] unsigned long long`, and Web IDL's ConvertToInt with bitLength 64 sets
its upper bound to 2⁵³ − 1 and throws a `TypeError` above it under `[EnforceRange]`
([Web IDL, *ConvertToInt*](https://webidl.spec.whatwg.org/#abstract-opdef-converttoint)).
No GPU parameter or descriptor member takes a larger number: an exact 64-bit value
(a query result) is binary data, `Binary.Word64` (#1284), an opaque pair of exact unsigned
32-bit words (`Binary.word64 high low`, `Binary.words`; amended 2026-11-08, it replaces the
proposed `Binary.U64`), never a `Size64`. Its conversion to Number (`Binary.word64ToInt`)
returns `PrecisionLost` when it loses bits, and converting one to a `Size64` is an error when
it exceeds 2⁵³ − 1. Arithmetic helpers detect
overflow; range checks use subtraction or exact arithmetic, not rounded sums.

The supporting `Binary` module offers ArrayBuffer, DataView and every standard
typed-array view admitted by BufferSource, including shared backing where
allowed. All operations have bounds/detachment/resizing checks. Byte-specific
helpers eliminate element/byte ambiguity; faithful source-view overloads keep
native element offsets. Shared memory obeys host isolation and cannot be made
safe by pretending it is immutable. Provide explicit atomic/shared access
operations, transfer semantics for eligible buffers, and copy helpers. A
GPU-mapped buffer is a different scoped range type and is never transferable.
The pinned Web IDL list is Int8/Int16/Int32, Uint8/Uint8Clamped/Uint16/Uint32,
BigInt64/BigUint64 and Float16/Float32/Float64 arrays, plus DataView. Retain
64-bit integer bit patterns through word pairs/bytes rather than forcing them
into beni's Number-backed `Int`. Feature-detect optional host constructors;
their absence returns `UnsupportedCapability`, not a lossy substitute.

**Fixed-length backing (#1268).** Web IDL refuses a resizable `ArrayBuffer`
or a growable `SharedArrayBuffer` behind a buffer source unless the parameter
carries `[AllowResizable]`, even when the view is in bounds and the buffer has
never been resized ([buffer source types](https://webidl.spec.whatwg.org/#es-buffer-source-types)).
Neither `AllowSharedBufferSource` nor the `Uint32Array` of the `setBindGroup`
slice overload grants it. Every GPU binary input therefore checks its backing
before the native call: resizable or growable backing returns
`InvalidInput (ResizableBacking { path })` (§5), for ordinary and shared
sources and for typed views on either, including backing that has never been
resized. `Binary`'s source constructors refuse the same backing first
(`binary.md` §1 on the `feat/webgpu-inputs` branch, [#1278](https://github.com/canassa/beni/issues/1278));
the GPU check repeats it at the operation, where the path names the
descriptor field or argument. Acceptance: a never-resized resizable
`ArrayBuffer`, a growable `SharedArrayBuffer`, a typed view on each, and the
array of `setBindGroupSlice` each return `ResizableBacking`; the fixed-length
equivalents pass.

### 3.2 Typed intake for every host source

The supporting API must provide typed acquisition, not just types with no
public constructors. The minimum intake is:

```text
Binary.allocate : Int → Result Binary.AllocationError Binary.Buffer
Binary.view : Binary.Backing, ViewKind, Binary.ByteRange → Result Binary.ViewError Binary.View
Binary.shared : Int → Result Binary.SharedError Binary.SharedBuffer
Binary.word64 : Int, Int → Result Binary.WordError Binary.Word64

Browser.Image.byId : String → Result Browser.Image.Error Browser.Image.Element
Browser.Image.bitmap : Browser.Source.Input, Maybe Crop, BitmapOptions → Result Browser.Image.Error Browser.Image.Bitmap
Browser.Image.bitmapFromBytes : Binary.Source, String, Maybe Crop, BitmapOptions → Result Browser.Image.Error Browser.Image.Bitmap
Browser.Image.dataFromView : Binary.View, Int, Maybe Int, Settings → Result Browser.Image.Error Browser.Image.Data
Browser.Video.byId : String → Result Browser.Video.Error Browser.Video.Element
Browser.Video.frame : Browser.Source.Input, FrameOptions → Result Browser.Video.Error Browser.Video.Frame
Browser.Canvas.byId : String → Result Browser.Canvas.Error Browser.Canvas.Canvas
Browser.Canvas.offscreen : Int, Int → Result Browser.Canvas.Error Browser.Canvas.OffscreenCanvas
Browser.Canvas.transfer : Browser.Canvas.Canvas → Result CanvasError Browser.Canvas.OffscreenCanvas
```

**Amended 2026-11-08 (#1278, PR #1284)** to the signatures that were built.
ArrayBuffer sizes are `Int` checked against ToIndex (0 through 2^53 − 1),
not `Size64`: a CPU allocation cannot exceed ToIndex, and `Size64` stays the
type of GPU descriptors. `view` takes a `Backing` (`Local` or `Shared`) and a
`ByteRange` in bytes. Each `Binary` function has its own error type, naming
only its own failures (`binary.md` §2). `word64`/`Word64` replace
`u64Words`/`U64`. Elements are acquired with `byId`; `Image.bitmap` (any
decoded source, with the crop overload) and `Image.bitmapFromBytes` (encoded
bytes with a MIME type) are `ImageInput`'s two arms of the proposed `decode`,
and `Image.decodeElement` decodes an element in place. A VideoFrame built from
raw pixel buffers is #2250. `Canvas.transfer` waits for #1299.

`ImageInput` includes decoded source handles and encoded bytes (with MIME where
needed); `VideoFrameSource` includes typed image sources and raw pixel-buffer
descriptors (the latter is #2250). Full VideoFrame construction metadata and image decoding options
belong to those supporting modules, not an unchecked dictionary argument.
GPU source-sum constructors wrap each resulting handle without exposing its
native object. Typed worker message transfers can also receive Bitmap, Frame,
OffscreenCanvas and transferable binary handles; the source side becomes
detached and all aliases observe that state. Receiving rebinds the wrapper to
the destination realm. Shared buffers are shared explicitly, not transferred.
These transfers are the worker slice's, after #1299 (§2, §10).

This scope does not imply full WebCodecs or the entire HTML media API. It does
require all GPU source forms to be usable, along with readiness/close/size and
animation/video-frame scheduling needed for correct GPU use. The error sums
above need individual per-method constructor/decode/transfer contracts before
implementation, under the same no-broad-catch rule. They cannot be implemented
as `Error String`, and none is claimed to exist today.

## 4. Public surface and typical use

The snippets below are **contract signatures and fragments**, tagged `text`
until their modules ship. Operations are called qualified or with `▷` (§2.1).
Effects are inferred: this contract does not add `Task Error a`, `async`
syntax or a new language feature.

```text
Gpu.available : ⊤ → Availability
Gpu.requestAdapter : AdapterOptions → Result InitError Adapter
Gpu.preferredCanvasFormat : ⊤ → Result InitError TextureFormat
Gpu.wgslLanguageFeatures : ⊤ → Result InitError WgslFeatures

Gpu.Adapter.features : Adapter → Features
Gpu.Adapter.limits : Adapter → Limits
Gpu.Adapter.info : Adapter → AdapterInfo
Gpu.Adapter.requestDevice : Adapter, DeviceDescriptor → Result InitError Device

Gpu.Device.features : Device → Features
Gpu.Device.limits : Device → Limits
Gpu.Device.adapterInfo : Device → AdapterInfo
Gpu.Device.queue : Device → Queue
Gpu.Device.destroy : Device → ⊤

Gpu.Device.createBuffer : Device, BufferDescriptor → Result Error Buffer
Gpu.Device.createTexture : Device, TextureDescriptor → Result Error Texture
Gpu.Texture.createView : Texture, TextureViewDescriptor → Result Error TextureView
Gpu.Device.createSampler : Device, SamplerDescriptor → Result Error Sampler
Gpu.Device.createBindGroupLayout : Device, BindGroupLayoutDescriptor → Result Error BindGroupLayout
Gpu.Device.createBindGroup : Device, BindGroupDescriptor → Result Error BindGroup
Gpu.Device.createPipelineLayout : Device, PipelineLayoutDescriptor → Result Error PipelineLayout
Gpu.Device.createQuerySet : Device, QuerySetDescriptor → Result Error QuerySet

Gpu.Device.createShaderModule : Device, ShaderModuleDescriptor → Result Error Shader
Gpu.Shader.getCompilationInfo : Shader → Result Error CompilationInfo
Gpu.Device.createComputePipeline : Device, ComputePipelineDescriptor → Result Error ComputePipeline
Gpu.Device.createComputePipelineAsync : Device, ComputePipelineDescriptor → Result Error ComputePipeline
Gpu.Device.createRenderPipeline : Device, RenderPipelineDescriptor → Result Error RenderPipeline
Gpu.Device.createRenderPipelineAsync : Device, RenderPipelineDescriptor → Result Error RenderPipeline
```

`createShaderModule` fails for host-reported invalid WGSL; diagnostic messages
are carried with shader errors. Successful modules retain warnings/info and
their original source. `Gpu.Shader.compile` is the convenience form returning
`{ shader, diagnostics }`, while direct creation plus compilation-info access
is the faithful foundation. All native WGSL source is accepted for host
validation, including dynamic source, entry-point omission, override constants,
compilation hints, f16, subgroups, immediate address space and all standard
extensions supported by the host. No reduced shader DSL is the only path.

`AdapterOptions` includes `featureLevel`, `powerPreference`, `forceFallbackAdapter`
and `xrCompatible`. The last is the standard adapter-selection input; supporting
the separate WebXR specification is not implied. `DeviceDescriptor` includes
label, required features, required limits and default queue descriptor. Read
back effective features/limits after creation, including feature dependencies.
Unsupported required limits are errors; never silently clamp them. Adapter info
includes fallback status and subgroup bounds, with privacy-reduced strings
preserved as supplied rather than interpreted as absent capabilities.

Descriptor convenience constructors fill **all optional members with Default**,
then callers can use record updates. For example:

```text
bufferDescriptor : Size64, BufferUsages → BufferDescriptor
textureDescriptor : Extent3D, TextureFormat, TextureUsages → TextureDescriptor
renderPipelineDescriptor : PipelineLayoutMode, VertexState → RenderPipelineDescriptor

desc = Gpu.Types.bufferDescriptor bytes (Gpu.Flags.buffer [ Uniform, CopyDst ])
Gpu.Device.createBuffer device { desc | label = Value "camera", mappedAtCreation = Value False }
```

Complete render descriptors include primitive topology/front/cull/unclipped
depth, strip index format, vertex buffers/attributes, depth/stencil state,
multisampling, fragment targets and blend/color masks. Complete pass descriptors
include nullable/multiple attachments, resolves, 3D depth slices, load/store,
read-only depth/stencil, occlusion sets, timestamp writes and maximum draw count.
Compute descriptors include explicit/auto layouts, stage entry/overrides and
timestamp writes. Pipeline layouts include nullable bind group layouts and
immediate data size. Texture descriptors include binding view dimension and
view formats; view descriptors include usage and swizzle. The inventory's exact
records are authoritative if this overview leaves out a field.

## 5. Error types and publication guarantees

Use operation-specific initialization/input/map errors for common handling and
a shared GPU operation error sum. The concrete type spelling can be refined
before implementation, but these distinctions are required:

```text
InitError
    = InsecureContext
    | ApiUnavailable
    | AdapterUnavailable
    | AdapterConsumed
    | UnsupportedFeatures (List FeatureName)
    | UnsupportedLimits (List LimitMismatch)
    | FeatureRequestRejected RequestDetail
    | DeviceRequestRejected HostMessage
    | InitializationInput InputError
    | InitializationLost DeviceLoss

Error
    = InvalidInput InputError
    | UnsupportedCapability Capability
    | Validation FailureDetail
    | OutOfMemory FailureDetail
    | Internal FailureDetail
    | PipelineValidation PipelineFailure
    | PipelineInternal PipelineFailure
    | DeviceLost DeviceLossReport
    | MapFailed MapError
    | SourceFailed SourceError
    | CanvasFailed CanvasError
    | FormatFeatureRejected FormatFailure
    | HostOperationRejected OperationFailure
    | RelatedFailures FailureSet

MapError
    = MapRejected HostMessage
    | MapAborted
    | MappedAllocationFailed AllocationDetail
    | MappedRangeRejected HostMessage

SourceError
    = SourceNotOriginClean
    | SourceUnusable HostMessage
    | ExternalImageCopyRangeRejected HostMessage

CanvasError
    = CanvasNotFound String
    | WrongElementKind String
    | CanvasContextUnavailable
    | CanvasUnconfigured
    | CanvasConfigurationRejected HostMessage

DeviceLoss = { reason : LossReason, message : String }
LossReason = UnknownLoss | Destroyed
DeviceLossReport = { loss : DeviceLoss, operation : OperationReport }
```

`InputError` is a closed sum for numeric domain/overflow/alignment, source or
dynamic-offset ranges, wrong device, destroyed/expired/rejected/pending resource,
encoder/pass/query/debug stack state, already-submitted command buffer,
overlapping mapped range, unsupported required format/capability, a
mapped-at-creation size that is not a multiple of 4 (`MappedSizeUnaligned`,
§7.1), resizable or growable binary backing (`ResizableBacking`, §3.1), and
session state (`SessionState`: `DeviceLeased`, `SessionEnded`, §6.4, §8.2). Each
variant carries a descriptor path/operation and relevant values. Stable wrapper
preflight details remain separate from opaque native validation messages.
`OperationFailure` is also closed: device-specific documented writeBuffer,
setImmediates and similar rejection cases listed in the ledger. It is not
`{ name : String }` accepting arbitrary errors.

`FailureDetail` contains device ID, operation/segment label, stage
(`Content`, `DeviceValidation`, `Submission`, `Mapping`, `PipelineCreation`),
resource labels and original message. These IDs are runtime diagnostic identities,
not compiler nondeterministic IDs or exposed native objects. Scope results can
only identify the checked operation/segment, not necessarily the individual draw
or the first failing instruction. `FailureSet` is nonempty and nonrecursive:
its entries are leaf failures, so callers can match all observed categories.
The standard's representative-per-scope limitation remains visible.

No failed resource creation publishes an **accepted** handle. Success means:
conversion passed; all observations awaited for this operation reported no
expected failure; no loss had been observed at publication. It never means
the device will remain healthy, that arbitrary shader execution is error-free,
or that work has completed unless the operation explicitly waits for it.

When multiple channels fail, drain them all. Return `DeviceLost` as the main
lifecycle outcome when observed, preserving related failures in its operation
report; otherwise return the one failure or `RelatedFailures`. An unexpected
failure takes the defect path even if a known validation error also occurred.
Do not discard the defect behind an earlier ordinary error. The public result
may include an operation report containing all **observed representatives**;
it must not label that report a complete error list.

## 6. Checked operations, batches and command encoding

### 6.1 One host operation

For a checked operation the engine follows this order:

1. Validate beni inputs and shared handle state. Reject an already-observed
   lost/destroyed device. Refuse a device whose diagnostic lease is held with
   `SessionState DeviceLeased`, never waiting (§6.4). Resolve the owning realm
   and negotiated capabilities.
2. Enter a non-suspending device stack section. Push validation, out-of-memory
   and internal scopes. Record exactly which pushes succeeded.
3. Invoke only the intended native call, with its per-operation synchronous
   classifier. Never include a user callback inside that classifier.
4. In an unconditional finalizer, **invoke** every corresponding pop in reverse
   order before any suspension. Attach both native and pop-promise handlers
   immediately, and preserve all outstanding outcomes. A pop failure in this
   automatic stack is a defect, not `ScopeUnderflow` returned to the user.
5. Leave the stack section. Wait through `Task` for required outcomes, allowing
   independent operations to proceed. GPU timelines associate the operations
   with their scopes even if completion comes out of order. Scope resolution
   does not force `onSubmittedWorkDone` after each call.
6. Combine typed failures, diagnostics and observed loss. Publish accepted
   values only after checked completion. Invalid native handles are never
   treated as successful just because the native call returned an object.

No ordinary callback or fiber yield can interleave a scope stack fragment.
JavaScript run-to-completion protects the fragment; a runtime guard rejects
unexpected reentrant GPU entry before it can corrupt the stack. Operations on
separate devices do not block each other. Same-device scope **waits** do not
need a mutex extending to all promise settlement.

Promise handlers catch only their documented native rejection types. Callback
throws are defects routed through `Task`/the owning program; a throw in a
promise reaction must not become a detached unhandled rejection that continues
the application. Unknown error data preserves the original cause/stack and
operation context for the existing defect display/log/stop contract.

*As built — S1 (2026-11-08).* `Gpu.Engine.checked` is this order for one native call: it
refuses a latched loss (`destroy` latches one at once) and a held lease first, opens a
per-device section whose reentry is a defect, pushes the three scopes inside `Js.finally`,
and in its finaliser invokes every pop that was pushed, in reverse, with both reactions
attached. The fiber then waits for the pops or for the loss, whichever is first; a pop that
settles after the operation went on is drained, and an unexpected one goes to the device's
sentinel, a detached fiber of the program that requested the device. The made object is
recorded `provisional`, then `accepted` or `rejected`, and only an accepted one is
returned. The lease of §6.4 is the record's flag and generation, taken with `tryLease`
(no session API yet). The first operation over it is `Gpu.Device.createSampler`; the
`browser/gpu/Checked*` fixtures cover §10's interleaved fibers, pops out of order, an
unexpected pop beside a validation error, a spoofed error, a throwing call, and a loss
before, during and after publication. *Amended 2026-11-08 (review of S1):* the call is `sync (⊤ → Result
Error V)`, so step 3's classifier is the operation's own: it gives `Ok` with what the call
made, or the precise `Error` of a failure the ledger documents at that call (S2's
`MappedAllocationFailed`, `FormatFeatureRejected`), which joins the scopes' observations.
However the fiber leaves the wait — cancelled, or interrupted before it waited — the
operation is done; an unexpected outcome it kept goes to the device's program then, and
one that settles later goes there too. Each pending pop holds the device's channel to
that program (a detached fiber the request made), which ends once the loss is reported
and no pop is pending (`browser/gpu/Cancelled*`). A pop's defect names its device and operation
(`device 1, createSampler: …`, the original as `cause`), and a cancelled operation's object
is recorded rejected, never left provisional (second review, 2026-11-08).

### 6.2 Synchronous encoding with checked completion

Awaiting each draw is unusable and can expire presentation resources. Provide
a managed encoding callback whose native commands execute without suspension:

```text
Gpu.Encode.run :
    Device, CommandEncoderDescriptor,
    sync (CommandEncoder → Result InputError a)
    → Result Error { value : a, commands : CommandBuffer }

Gpu.ComputePass.with :
    CommandEncoder, ComputePassDescriptor,
    sync (ComputePass → Result InputError a)
    → Result InputError a

Gpu.RenderPass.with :
    CommandEncoder, RenderPassDescriptor,
    sync (RenderPass → Result InputError a)
    → Result InputError a

Gpu.RenderPass.setPipeline : RenderPass, RenderPipeline → Result InputError ⊤
Gpu.RenderPass.setBindGroup : RenderPass, U32, Maybe BindGroup, List U32 → Result InputError ⊤
Gpu.RenderPass.draw : RenderPass, DrawArguments → Result InputError ⊤
Gpu.ComputePass.dispatchWorkgroups : ComputePass, U32, U32, U32 → Result InputError ⊤

Gpu.Queue.submit : Queue, List CommandBuffer → Result Error Submission
Gpu.Queue.onSubmittedWorkDone : Queue → Result Error ⊤
```

All other native encoding commands are present under the inventory translation,
including copies, clear, resolve queries, both binding overloads, immediate
data, debug commands, indirect calls, explicit begin/end and finish, bundles,
viewport/scissor/blend/stencil and occlusion queries. `with` is convenience;
explicit begin/end is available inside a session for native control flow.
Explicit `finish` closes the shared encoder and automatic finalization detects
it; it never finishes twice. The run's final scopes include finish, which can
surface earlier encoder invalidity. Submitting is separately checked.

Inner `Ok` means the command passed **local** checks and was issued, not that
GPU validation succeeded. The outer `Result` is the checked result. Discarding
an inner input error cannot silently continue: a session latches its first local
failure, stops issuing subsequent dependent commands and returns it at the
outer boundary. Failures thrown by application code remain defects.
If an individual native encoding call raises a documented synchronous host
failure, its narrow classifier latches that precise `Error` for the outer result;
the inner call returns `InputError.SessionStopped`. It must not disguise the
native failure as a numeric/input problem or lose it if that inner result is ignored.

### 6.3 Batching resource and queue operations

```text
Gpu.Batch.run : Device, String, sync (Batch → Result InputError a) → Result Error a
Gpu.Batch.createBuffer : Batch, BufferDescriptor → Result InputError Buffer
Gpu.Batch.createTexture : Batch, TextureDescriptor → Result InputError Texture
Gpu.Batch.importExternalTexture : Batch, ExternalTextureDescriptor → Result InputError ExternalTexture
Gpu.Batch.writeBuffer : Batch, Queue, Buffer, WriteBufferSource → Result InputError ⊤
Gpu.Batch.submit : Batch, Queue, List CommandBuffer → Result InputError Submission
```

There is a non-suspending batch form for every native synchronous GPU operation
that may be needed in one turn, including encoders/passes/current canvas texture.
No async pipeline wait or map wait runs inside it; initiate those outside, or
through explicit tickets whose waits occur after the batch. Each batch defines
one or more named scope segments, defaulting to one for the whole batch. Each
segment has three scopes. Requesting finer attribution uses smaller segments
or checked single operations; the engine does not promise per-draw GPU error
attribution inside a shared segment.

Resource handles created inside a batch share runtime status `Provisional batchId`,
then `Accepted` or `Rejected failure`. The same batch may use its provisional
resources before validation, just as native WebGPU permits. Outside that active
batch, early use returns `ResourcePending`; an `awaitReady` helper waits for
settlement. A checked batch result publishes only accepted handles. Alias state
is shared even when a callback stores or sends a provisional handle elsewhere;
no rank-2 types, linear-resource compiler extension or uncheckable “must not
escape” convention is assumed. A failed batch rejects all its newly created
handles conservatively and releases owned abandoned allocations.

A batch is **not a transaction**. Earlier writes/submissions may have happened
before failure. It does not roll back existing resources, canvas configuration,
user side effects or submitted work. Its failure report identifies issued vs
unissued wrapper stages and validation/submission observations. Helpers for
atomic application initialization can publish a new resource bundle only after
success, but cannot claim native rollback.

*As built — S2b (2026-11-08, #2240).* `Gpu.Encode.run` is one checked operation (`encode`):
`createCommandEncoder`, the callback and `finish` run between the device's scopes in one host
turn; `Gpu.CommandEncoder` and `Gpu.ComputePass` hold the commands (`beginComputePass`,
`ComputePass.with`/`end`, `setPipeline`, `setBindGroup`, `setBindGroupSlice`,
`dispatchWorkgroups`, `dispatchWorkgroupsIndirect`, `setImmediates`, the debug commands,
`copyBufferToBuffer` and its offset-free overload `copyBuffer`, the three texture copies,
`clearBuffer`, `resolveQuerySet`, `finish`). A session latches its first refusal or
documented host failure, and the run returns it; the new `InputError` arms are
`EncoderLocked`, `EncoderFinished`, `PassEnded`, `DebugStackEmpty`, `CommandBufferSubmitted`,
`DuplicateCommandBuffer` and `ViewKindRequired`. The ledger's `DynamicOffsetSliceOutOfBounds`
and `ImmediateSourceRange` are `OutOfRange` (and `Misaligned`) at the paths
`dynamicOffsetsData` and `size`, the same arms every other range uses. `Gpu.Batch` has
`run`, `createBuffer`, `createTexture`, `createSampler`, `createBindGroupLayout`,
`createBindGroup`, `createPipelineLayout`, `createShaderModule`, `createComputePipeline`,
`createQuerySet`, `getBindGroupLayout`, `writeBuffer`, `writeTexture`, `encode` and `submit`;
each creation is prepared once (`Gpu.Make`) and runs either as its own checked operation or
inside a batch. A provisional object is usable while the batch that made it runs — a batch is
synchronous, so whatever runs then is that batch's — and `ResourcePending` otherwise. A failed
batch rejects what it made and destroys its buffers, textures and query sets.
`createComputePipelineAsync` is checked like `map`, its promise's `GPUPipelineError` joining
the scopes. *Amended the same day:* compilation info is `Gpu.Shader.CompilationInfo`, beside
the operation that reads it, since `Gpu.Types` is generated from dictionaries and
`GPUCompilationInfo` is an interface. Texture views, render pipelines and passes are S3's.
Fixtures: `browser/gpu/ComputeDoubles` (a shader's answer read back, compared with words
written by hand, under `test-webgpu`), `TextureCopies`, `EncodeSession`, `EncodeValidation`,
`ShadersAndPipelines`, `Batches`, and the defects `PipelineAsyncUnlisted` and
`CompilationInfoRejected`.

*Amended after review, 2026-11-08, by the manager, under the owner's delegation of names.* A
batch operation returns `Result Error a` and the batch's callback `Result Error a`, so a
local failure that is not an input error (a feature a format or a query type needs) surfaces
as itself; `Batch.run`'s failure is `BatchFailed { batch, failure, issued, unissued }`, the
issued and refused operations by name (this section's failure report). `Gpu.Batch.segment`
starts a named scope segment (three scopes each), whose name a scope's failure carries;
`Gpu.Batch.awaitReady` waits until the batch settles. A cancelled run rejects what it made.
In a batch, a pipeline or a queue of another device is `WrongDevice` before any native call.
A prepared operation is a record with a tagged `Action` that a `sync` `perform` switches on,
so the checker proves nothing in the scope section suspends; a record field cannot have a
`sync` function type (#2271). Invalid WGSL is `ShaderRejected { failure, messages }`, the
compiler's messages read before the failure is returned; `CompilationInfo` and
`CompilationMessage` live in `Gpu.Error` (aliased by `Gpu.Shader`), since `Gpu.Error` must
name them and `Gpu.Shader` imports `Gpu.Device`. A rejected asynchronous pipeline's
`PipelineFailure` keeps the entry points asked for. A failure set may hold a refusal
(`ObservedRefusal`) or a missing capability (`ObservedUnsupported`), so an operation's own
refusal and the scopes' observations are both kept. `Queue.submit` refuses a command buffer
using, directly or through a bind group, a resource destroyed (`ResourceDestroyed`) or
mapped (`MappingState`) since it was encoded. `getBindGroupLayout` refuses an index at or
above `maxBindGroups` (`OutOfRange`).

*As built — S3a (2026-11-08, #2241).* Rendering follows the compute half. `Gpu.Texture.createView`
(and `Gpu.Batch.createView`), `Gpu.Device.createRenderPipeline` and `createRenderPipelineAsync` (and
`Gpu.Batch.createRenderPipeline`, `getRenderBindGroupLayout`) are prepared in `Gpu.Make` like every
creation. A format a feature gates — a view format, a color target or depth format, a bundle
encoder's formats — is `UnsupportedCapability` before the native call, and the host's `TypeError`
for one anyway is `FormatFeatureRejected` (ledger §3, §5); a `TypeError` with no gated format is a
defect. `Gpu.CommandEncoder.beginRenderPass` and `Gpu.RenderPass.with` hold the render pass;
`Gpu.RenderPass` has every command of the pass and its mixins (`setPipeline`, `setBindGroup`,
`setBindGroupSlice`, `setImmediates`, `setVertexBuffer`, `setIndexBuffer`, `draw`, `drawIndexed`,
`drawIndirect`, `drawIndexedIndirect`, `setViewport`, `setScissorRect`, `setBlendConstant`,
`setStencilReference`, `beginOcclusionQuery`, `endOcclusionQuery`, `executeBundles`, the debug
commands, `end`). `DrawArguments` and `DrawIndexedArguments` are records of `Gpu.RenderPass` in the
native argument order, made with the native defaults by `vertices` and `indices`; the other
commands keep §3 item 1's positional order. Render bundles are a session like an encoder's:
`Gpu.Encode.bundle : Device, RenderBundleEncoderDescriptor, sync (RenderBundleEncoder → Result
InputError a) → Result Error { value : a, bundle : RenderBundle }` and `Gpu.Batch.encodeBundle`, with
the commands in `Gpu.RenderBundleEncoder` (its `finish` closes it, as `CommandEncoder.finish`
does). The mixins live once, in the private `Gpu.Commands`, which `Gpu.ComputePass` now uses too. An
attachment, resolve target or query set must be usable, and a view is unusable once its texture is
destroyed (`ResourceDestroyed`). Occlusion queries are checked locally: the new `InputError` arms
`QuerySetMissing`, `QueryActive` (also a pass ended, by `end` or by `with`, with a query open),
`QueryInactive` and `QueryReused` (an index begun twice in one pass), and an index past the set is
`OutOfRange` at `queryIndex`. The host does not say which feature-gated format it refused, so
`FormatFailure` names the first and lists every `candidates`; only a native `TypeError` is that
failure, and a same-named object, an `Error` named `TypeError`, a `RangeError` or a
`DOMException` there is a defect (`browser/gpu/FormatHostile*`). Since the batch review the render
creations are `Gpu.Make` actions (`CreateView`, `CreateRenderPipeline`) run by `perform` like the
others, the render batch operations return `Result Error`, a batch checks a texture or a pipeline
it is given against its device with the same check as for a queue (`WrongDevice`), and the format
checks live in `Gpu.Formats`, which `Gpu.Make` and `Gpu.Session` share. `executeBundles` keeps no shadow state, so it has none to clear. Fixtures:
`browser/gpu/RenderScenes` (multi-pass, indirect, depth, stencil, MSAA resolve, MRT, a bundle, a
batch and occlusion, compared under `test-webgpu` with pixels worked out by hand),
`RenderRefusals`, `RenderPipelines`, `RenderFormatRejected`, and the defects
`RenderPipelineUnlisted`, `RenderFormatUnlisted` and `ViewFormatUnlisted`.


### 6.4 Explicit error-scope diagnostics without an unsafe escape hatch

Native push/pop are available through an explicit **diagnostic session**, not
as uncontrolled global mutations interleaved with automatic wrappers:

```text
Gpu.Diagnostics.run : Device, (DiagnosticSession → a) → Result Error (DiagnosticReport a)
Gpu.Diagnostics.nested : DiagnosticSession, (DiagnosticSession → a) → Result Error (DiagnosticReport a)
Gpu.Diagnostics.pushErrorScope : DiagnosticSession, ErrorFilter → Result InputError ⊤
Gpu.Diagnostics.popErrorScope : DiagnosticSession → Result DiagnosticError (Maybe GpuError)
```

**The lease.** A session takes an exclusive per-device lease **before** it
pushes scopes. Taking the lease never waits: when the device's lease is held
already, `run` returns `InvalidInput (SessionState DeviceLeased)` at once.
While the lease is held, the device accepts only calls that present the
session (the forwarding surface below). **An ordinary checked operation on a
leased device returns `InvalidInput (SessionState DeviceLeased)` immediately
and does not wait**. The rule is the same for a call from the session's own
callback, from a fiber the callback spawns or joins, and from an unrelated
fiber (the owner, 2026-11-08: [#1270](https://github.com/canassa/beni/issues/1270)
for the session's owner, extended the same day to every fiber). `Frame.submit`,
`Batch.run` and `Encode.run` are ordinary operations and follow it.

**No task identity.** The engine does not need to know which fiber calls
(there is no `Task.Identity`; [#1280](https://github.com/canassa/beni/issues/1280)
is closed). The lease is a per-device flag and a lease generation in the
engine's state table (§2.1). The authority to use a leased device is the
`DiagnosticSession` value: a token whose engine record names its device and the
lease generation it was issued under. A forwarding call checks that the
session's device is the target's device and that its generation is the live
one. An ordinary call carries no token, so it is refused.

**What the lease refuses.** Exactly the operations that enter §6.1's
scope-stack section: every operation that pushes the engine's scopes around
a native call. These are every checked operation (each `Result Error`
function that creates, writes, copies, encodes, submits, maps or creates a
pipeline), and the batch, encode and frame runs. The exemptions never enter
a scope section, so they are never refused and run at once under a lease:

- **Teardown that returns `⊤`:** `Gpu.Device.destroy`, `Gpu.Buffer.destroy`,
  `Gpu.Texture.destroy`, `Gpu.QuerySet.destroy`, `Gpu.Buffer.unmap` and
  `Gpu.Surface.unconfigure`. The pinned specification gives them no GPU error
  ([ledger](research/webgpu-errors.md) §2–§4 and §6). They latch wrapper state at
  once, so the session's later calls see it. An error the host raises for one
  anyway escapes every scope and is a defect (§8).
- **Reads of state:** snapshot getters (features, limits, adapter info,
  size, usage, `mapState`, `getConfiguration`, `label`), `Gpu.Device.loss`,
  `Gpu.Device.queue`, `Gpu.Buffer.currentMapping`, and `setLabel`. They read or
  write native attributes or engine state and issue no GPU command.
- **Mapped memory:** `getMappedRange` and every `Gpu.MappedRange` read and
  write. They touch CPU memory of an existing mapping. `getMappedRange`'s
  only failure is a synchronous content-timeline `OperationError` (ledger §4),
  not a scoped GPU error.
- **Waits on work issued earlier:** `Gpu.Submission.done`,
  `Gpu.Queue.onSubmittedWorkDone`, `Gpu.Shader.getCompilationInfo`, a pending
  `map`'s wait, `Gpu.Device.awaitLost`, `eachEvent` and `onEvent`. They issue
  no scoped native call. *(Amended 2026-11-08, review of #2289: the queue's
  completion and a module's compilation messages are waits on earlier work
  that push no scopes, so they run under a lease too.)*

**Why it cannot deadlock.** The lease adds no wait: an ordinary operation
refuses, `run` on a leased device refuses, and a forwarding call holds the lease
already. Within one device and across devices, no wait for a lease exists for a
cycle to close, so no lock order is needed. The session's callback can still
wait on other things — `Task.join`, `Task.sleep`, a message, a `Deferred`, a
GPU outcome — and none of these waits is on the lease:

- a fiber it joins that makes an ordinary call on the leased device gets
  `DeviceLeased` at once and goes on, so the lease does not block the join;
- a sleep or a message depends on the clock or on other code, not on GPU state;
- a GPU outcome (scope pop, map, pipeline, completion) is settled by the host
  without running beni code.

**The livelock hazard is the application's.** A session that waits on a fiber
that retries its ordinary call after `DeviceLeased` until it succeeds never
returns: the retry needs the lease to end, and the lease needs the callback to
return. The engine cannot see this cycle, because it runs through application
code (a retry loop, a message the fiber sends only after its GPU call). The
public API documentation of `Gpu.Diagnostics` states the hazard and the rule:
work that a session waits on must not touch the leased device through ordinary
calls; route it through the session, or do it after the session ends.

**Consequence.** During a session, other work on that device is refused, not
delayed. An application that runs a render loop while it diagnoses the same
device routes that work through the session or pauses it; the typed refusal
makes the conflict visible instead of silently serialising it.

**Nesting.** `Gpu.Diagnostics.nested` opens an inner session under the outer
session's lease, with the outer token as authority; its scopes nest inside the
outer session's and it ends before the outer one. `Gpu.Diagnostics.run` called
from inside a session's callback is an ordinary acquisition: on the same device
it refuses, on another device it follows the rule above.

**End of the lease.** The lease ends when the callback returns, fails, defects
or is cancelled. A finalizer pops every unclosed user scope and the engine's
outer scopes, keeps draining their results, and clears the flag in the turn in
which the callback exits. A session used after its lease ended — kept in a
model, or by a child fiber that outlives the callback — returns
`InvalidInput (SessionState SessionEnded)`; the generation check also refuses a
session of an earlier lease on the same device. The lease does not join child
fibers: a child still running when the callback exits gets `SessionEnded` from
its forwarding calls, and its ordinary calls proceed once the lease is gone.

**Destruction and loss.** `Gpu.Device.destroy` is exempt from the lease (above);
it latches destroyed state as everywhere else (§8). Later forwarding calls in
the session return the device-loss outcome; the finalizer still invokes the
pops and releases the lease. Loss observed during a session does not end it
early.

**Outcomes that outlive their caller** (CLAUDE.md rule 9). The engine keeps
draining scope pops after a session or lease ended, and the completion
promises of receipts that nobody waits for (§8.3). Their expected outcomes
are dropped once nobody can receive them. An **unexpected** outcome — a
rejection, an unknown error class, a pop failure in the engine's own scopes —
goes to the defect path, never to a log line or a dropped value. Its owner is
the **program that created the device**: the engine records, in the device's
table entry, the program whose fiber called `requestDevice`, and a defect
from a drained outcome enters that program's defect boundary with the
operation context, even when the issuing fiber or session has ended. Under
`Browser.programs`, that is the one program that requested the device, not
every program on the page.

Session operations issue native calls under the user's diagnostic scopes, so
automatic inner scopes do not steal the errors being inspected. Engine-owned
outer scopes capture any class the user did not capture. Public native scope
semantics (filter nesting and representative selection) remain intact. Popping
an empty user stack returns `ScopeUnderflow`; underflow in the engine's own
outer scopes is a defect.

The explicit session forwarding surface is
`Gpu.Diagnostics.<owner>.<member> session …` for every inventoried operation;
the session argument is the lease authority. This includes async pipeline/map
waits, sync encoder calls, `Gpu.Diagnostics.Batch.run` and
`Gpu.Diagnostics.Frame.submit`; a sync frame callback never waits for a lease,
because the frame holds the session's lease before it starts. An ordinary call
is never treated as a session call because a session happens to be live; it is
refused as above. Session-scoped native errors remain typed observations even
when deliberately requested by the caller, and no engine-owned inner scope
hides them from `popErrorScope`.

Created handles are provisional until the diagnostic session accepts them;
an invalid native diagnostic object can never escape as an accepted resource.
The report holds the callback value only when safe to publish, plus explicit
scope observations. A failed session withholds that value and returns the
observed typed failures. This preserves the ability to test native failure
behavior without giving ordinary code a raw GPU handle or unchecked use route.

*As built — S4 (2026-11-08, #2242), names chosen under the owner's delegation.* The session
is a record of the engine (`Gpu.Engine.openSession`, `closeSession`, `finishSession`), the
`DiagnosticSession` value itself; the device's record keeps the lease flag and generation of S1.
`Gpu.Diagnostics` has `run`, `nested`, `pushErrorScope`, `popErrorScope`, `state : DiagnosticSession
→ Result SessionState ⊤` and `DiagnosticReport a = { value : Maybe a, observed : List GpuError }`;
`Gpu.Error` gains `GpuError = ValidationError HostMessage | OutOfMemoryError HostMessage |
InternalError HostMessage` (what a scope or an `uncapturederror` reports) and `DiagnosticError =
ScopeUnderflow | SessionRefused InputError` (a session that cannot act). The forwarding modules are
`Gpu.Diagnostics.Device` (every checked creation, `createMappedBuffer` included),
`.Texture.createView`, `.ComputePipeline` and `.RenderPipeline` `getBindGroupLayout`,
`.Queue` (`writeBuffer`, `writeTexture`, `submit`, and since S5 `copyExternalImageToTexture`), `.Buffer` (`map`, `withMapped`),
`.Surface.configure`, `.Encode` (`run`, `bundle`), `.Batch.run` and `.Frame.submit`; each takes
the session, then the ordinary form's arguments, and the public operations and their forwarding
forms share one body that takes the session or null (`Gpu.Make.checkedIn`, `shaderModuleIn`, …,
`Gpu.Memory.mapIn`). The commands inside an encoder, a pass, a bundle encoder or a batch need no
forwarding form: they never enter a scope section of their own, and the run that hands them out
holds the session's authority. Five rules made precise here:

- **What a forwarding call returns.** It pushes no scope, so it waits for nothing but its own
  promise (`map`, the asynchronous pipelines): it returns what it made at once, provisional and
  usable by the session's calls (the session is the made object's batch). A session settles what
  it made all together, after every pop of it settled: accepted when no scope of the session —
  the user's and its own — reported an error and no loss was observed, rejected (and released)
  otherwise. A scope keeps one error per filter for every call under it, so the session cannot
  tell which object an error belongs to; it rejects them all, and the report's `value` is
  `Nothing` then. An error only the session's own scopes caught is the run's `Err`, as for a
  checked operation. A batch run under a session hands what it made to the session, and
  `Gpu.Batch.awaitReady` wakes when the session settles; `Gpu.Batch.segment` there only names,
  since the batch has no scopes of its own. A surface configured under a session is configured
  at once, and unconfigured for frames again if the session rejects what it made.
- **Nesting is a lease of the lease.** While a nested session is open, its parent can no more act
  than an ordinary caller: the parent's forwarding calls, pushes, pops and a second `nested` are
  `DeviceLeased`. So the native stack always holds the parent's scopes beneath the nested
  session's, and no wait is added. A parent whose callback ends while a nested session is still
  open (in a fiber the callback started) closes it with itself: the nested session is
  abandoned, what it made rejected, and its pops drained to the device's program. Its own run,
  when its callback returns later, is `InvalidInput (SessionState SessionEnded)` at once; it
  never waits for those pops and never reports a success (`browser/gpu/DiagnosticsNestedAbandoned`,
  both orders).
- **`ScopeUnderflow` is decided by the session's count**, before any native call: the engine
  never pops one of its own scopes for the user. A native rejection of a user pop the count
  allows is therefore a defect, as is a class the scope's filter does not report.
- **The end of the lease.** The session closes in the turn its callback exits on return, and
  on cancellation through `Task.onExit`'s finaliser. **A throw in the callback is the one
  exception to "in the turn the callback exits":** the callback may suspend, and `Js.finally`
  (`try … finally`) holds only `sync` code (`backend.md` §4), so nothing can run at the throw
  without catching it, which rule 9 forbids. The throw is a defect: the program stops at once,
  and the runtime's teardown, one task later, cancels every fiber of it, so the same finaliser
  pops the scopes and frees the lease then. Between the two nothing of that program runs, and the
  device belongs to it (§6.4, *Outcomes that outlive their caller*), so no caller can meet the
  lease still held. `browser/gpu/DiagnosticsCallbackThrows` logs the lease held at the throw, and
  free with no scope open after the teardown. A cancelled session hands an unexpected outcome it
  kept for its run to the device's program (`DiagnosticsCancelledPopDefect`).
- **Events.** `GPUUncapturedErrorEvent` is `Gpu.Error.DeviceEvent` (`Uncaptured GpuError |
  Lost DeviceLoss`), aliased as `Gpu.Device.DeviceEvent`, since the engine sends it and `Gpu.Error`
  is beneath the engine. Every call the engine makes is scoped, so every uncaptured error is the
  defect of §8: its listeners are handed it first, as telemetry, then the device's program stops
  with its class; the host's message differs between browsers and stays on the original, the
  defect's `cause`. `Gpu.Device.onEvent` is a `Sub.listen` keyed by the device's
  identity.

Fixtures (`browser/gpu/`): `DiagnosticsLease` (the three refusals with an order transcript: each
refused with no native call and before a microtask armed just before it ran), `DiagnosticsScopes`,
`DiagnosticsExemptions` (every exemption, from the callback and from an unrelated fiber, and
`destroy` under a lease), `DiagnosticsForwarding` (every forwarding call, accepted and rejected),
`DiagnosticsCancelled` (cancellation in every phase), `DeviceEvents`, `DeviceEventsPage` (TEA), and
the defects `DiagnosticsCallbackThrows`, `DiagnosticsLateDefect`, `DiagnosticsPopRejected`,
`DiagnosticsPopSpoofed`, `DiagnosticsPushThrows`, `DiagnosticsOpenThrows`, `DeviceEventsUncaptured`
and `DeviceEventsSpoofed`.

## 7. Resource identity, memory mapping and lifetime

Every handle stores device identity and shared lifecycle state. Aliases observe
destroy/unmap/finish/submission immediately. Device identity and session state
are runtime checked; ordinary phantom type parameters cannot prove generative
device identity in today's beni. Invalid use is a typed error, not an exception.
Resources have labels and explicit destroy where WebGPU provides it; managed
scope/bracket helpers release owned buffers, textures and query sets. Objects
without native destroy methods drop references when no longer needed.

```text
Gpu.Buffer.map : Buffer, MapRequest → Result Error Mapping
Gpu.Buffer.currentMapping : Buffer → Maybe Mapping
Gpu.Buffer.getMappedRange : Mapping, Range → Result Error MappedRange
Gpu.Buffer.withMapped :
    Buffer, MapRequest, (Mapping → Result Error a) → Result Error a
Gpu.Buffer.unmap : Buffer → ⊤
Gpu.Buffer.destroy : Buffer → ⊤
Gpu.Texture.destroy : Texture → ⊤
Gpu.QuerySet.destroy : QuerySet → ⊤

Gpu.MappedRange.readBytes : MappedRange, Binary.ByteRange → Result ReadError Binary.Buffer
Gpu.MappedRange.writeBytes : MappedRange, Int, Binary.Source → Result InputError ⊤
Gpu.MappedRange.readU32 : MappedRange, Int → Result InputError Int
Gpu.MappedRange.writeF32 : MappedRange, Int, Float → Result InputError ⊤
```

Mapped ranges access native mapped storage directly through typed reads/writes;
`readBytes` explicitly copies into a fresh fixed `Binary.Buffer`, and
`writeBytes` takes any `Binary.Source` (amended 2026-11-08: these were the
unspecified `Binary.Bytes`). Include all numeric views,
bulk copies and exact bit access, not only the representative methods above.
Expose read/write modes, size and mapState. `mappedAtCreation` produces a mapping
handle without pretending `MAP_WRITE` was required (§7.1). Ranges track overlap,
alignment, mapping generation and read/write permission. Every access validates
the generation, including one saved outside `withMapped`. `unmap`/destroy, and
the destruction of the buffer's device, detach all native ranges and invalidates every alias before any subsequent use.

The bracket helper unmaps in a finalizer even if the callback suspends, is
cancelled or returns an error. A defect stops the program that owns the
mapping (§8.1), so nothing of that program runs again, the finalizer included. Concurrent map requests are refused precisely;
cancelling the fiber waiting for a pending map calls unmap only for that owned
map generation. It cannot cancel a later independent mapping. Native map
promises are still drained. Direct map/unmap remains available for full native
lifetime control. Returned mutable mapped memory never masquerades as an
immutable `List Int` or a transferable general-purpose ArrayBuffer.

The binary layer handles host-shareable WGSL layout explicitly: scalar types,
vec/matrix alignment, struct offsets, member `@align`/`@size`, array stride,
runtime arrays, uniform vs storage constraints and f16 encoding. Raw bytes are
always available. Binary encoders/decoders use explicit WGSL layout
descriptions; a GPU layout cannot be inferred from an arbitrary beni record.

### 7.1 Mapped at creation (#1266, #1269)

A buffer created with `mappedAtCreation = Value True` is mapped when it is
created, and native `mapAsync` on it rejects, so `map` cannot produce its
mapping. The producer is an accessor:

```text
Gpu.Buffer.currentMapping : Buffer → Maybe Mapping
Gpu.Device.createMappedBuffer : Device, BufferDescriptor → Result Error { buffer : Buffer, mapping : Mapping }
```

`currentMapping` returns the live mapping of the buffer's current mapping
generation, whether it came from creation or from `map`, and `Nothing` when
the buffer is unmapped or its map is pending. A mapping from creation is
writable, whatever the buffer's usages: `MAP_WRITE` is not required, and its
mode is not reported as if it were. `createMappedBuffer` is the convenience
form: it sets `mappedAtCreation = Value True` and returns both values, and is
defined as `createBuffer` followed by `currentMapping`. The route is the same
everywhere a buffer is created: `Gpu.Batch.createBuffer` and
`Gpu.Diagnostics.Device.createBuffer` return a buffer whose `currentMapping` is
`Just`. Inside its own batch or session the provisional buffer's mapping can be
written at once, as native WebGPU permits even for a buffer that later fails
validation; outside it, use returns `ResourcePending` until the buffer is
accepted. A rejected buffer's mapping is detached with it. `map` on a buffer
that is mapped returns the precise mapped-state input error before any native
call.

**Size preflight (#1269).** When `mappedAtCreation` is `Value True` and the size
is not a multiple of 4, every creation form returns
`InvalidInput (MappedSizeUnaligned { path, size })` before any native call;
the native call would throw `RangeError` before it allocates. Only after this
check passes is a native `RangeError` from `createBuffer` classified as
`MapFailed (MappedAllocationFailed …)` ([ledger](research/webgpu-errors.md)
§3). Acceptance needs two separate fixtures: a size of 6 returns
`MappedSizeUnaligned` with no native call, and an aligned size whose CPU
allocation fails (host fault injection) returns `MappedAllocationFailed`.

*As built — S2a (2026-11-08, #2240).* `Gpu.Device.createBuffer` and `createMappedBuffer`,
`Gpu.Buffer` (`map`, `currentMapping`, `getMappedRange`, `withMapped`, `unmap`, `destroy`, the
snapshot getters and `mappingMode`/`mappingRange`/`mappingBuffer`/`mappingLive`),
`Gpu.MappedRange`, `Gpu.Queue` (`writeBuffer`, `submit`, `onSubmittedWorkDone`) and
`Gpu.Submission.done`. A buffer's record in the engine's table holds its size, usages, latched
map state, destroyed flag and mapping generation; the generation changes with every map
request, unmap and destroy, before the native call, so every alias of a mapping or a range of
an earlier generation reads `ResourceExpired`. `map` is a checked operation whose native call
answers with a promise (`Gpu.Engine.checkedAwait`): the operation waits for the three pops and
the map promise, or for the loss, and a rejection joins the scopes' observations (a map the
device refuses is `RelatedFailures [MapFailed MapRejected, Validation]`). *Amended the same
day by the manager, under the owner's delegation of names (2026-11-08):* `MapRequest` is `{ mode : MapModes, offset : Int, size : Maybe Int }` with `mapRead` and
`mapWrite` for the whole buffer, and `Range` is `{ offset : Int, size : Maybe Int }`; offsets and
sizes are `Int`s checked as `GPUSize64` (`NumericDomain`), not `Size64`, as `Binary` takes its
byte ranges. A mapped range's integer reads give `Int` and its writes take `Int`, as `Binary`'s
do — a payload is raw bits (§3.1), not a descriptor domain — with `InvalidValue` for a value
outside the width; values are little-endian. `readBytes` returns its own `ReadError`, since the copy
allocates on the CPU (ledger §4: a host allocation has its own classifier, outside the GPU
error): `Refused InputError` or `Allocation Binary.AllocationError`; `Gpu.Error.Error` gains
no arm. `writeBytes` is a CPU copy, not a GPU input, so it takes any attached storage,
resizable or growable included (CLAUDE.md rule 7). Destroying a device expires the mappings
of all its buffers first, as `unmap` does. The new
`InputError` arms are `DetachedSource`, `Misaligned`, `OutOfRange`, `InvalidValue`,
`InvalidMapMode`, `MissingBufferUsage`, `MappingState`, `RangeOverlap` and `ReadOnlyMapping`.
`Gpu.Queue.writeBuffer` takes a `WriteBufferSource` (`{ bufferOffset, data, dataOffset, size }`,
`bufferWrite` for the whole data), which is §6.3's `Batch.writeBuffer` argument too.
`withMapped` unmaps in a `Task.onExit` finaliser (above: a defect stops the program). Fixtures: `browser/gpu/BufferRoundTrip` (exact u32 and u64 round trips, read
back natively under `test-webgpu`), `BufferRefusals`, `MapFailures`, `MapLifecycle`,
`Submissions` and the defects `MapUnlisted`, `RangeUnlisted`, `WriteUnlisted`,
`WorkDoneRejected`. `GPUBufferUsage` validity beyond what the engine checks stays the device's
(`Validation`).

## 8. Canvas, media, events, fibers and page integration

```text
Gpu.Surface.fromElement : String → Result Error Surface
Gpu.Surface.fromCanvas : Browser.Canvas.Canvas → Result Error Surface
Gpu.Surface.fromOffscreen : Browser.Canvas.OffscreenCanvas → Result Error Surface
Gpu.Surface.configure : Surface, CanvasConfiguration → Result Error ⊤
Gpu.Surface.unconfigure : Surface → ⊤
Gpu.Surface.getConfiguration : Surface → Maybe CanvasConfiguration
Gpu.Surface.canvas : Surface → CanvasSource

Gpu.Frame.submit :
    Surface, String, sync (Frame → Result InputError a)
    → Result Error { value : a, submissions : List Submission }
Gpu.Frame.batch : Frame → Batch
Gpu.Frame.getCurrentTexture : Frame → Result InputError Texture
Gpu.Frame.importExternalTexture : Frame, ExternalTextureDescriptor → Result InputError ExternalTexture
Gpu.Frame.encode : Frame, CommandEncoderDescriptor, sync (CommandEncoder → Result InputError a)
    → Result InputError { value : a, commands : CommandBuffer }
Gpu.Frame.submitCommands : Frame, List CommandBuffer → Result InputError Submission

Gpu.Device.loss : Device → Maybe DeviceLoss
Gpu.Device.awaitLost : Device → DeviceLoss
Gpu.Device.eachEvent : Device, (DeviceEvent → ⊤) → ⊤
Gpu.Device.onEvent : Device, (DeviceEvent → msg) → Sub msg
```

`Frame.submit` refuses a device whose diagnostic lease is held before it
starts the synchronous callback, and `Gpu.Diagnostics.Frame.submit` runs
under the session's lease (§6.4), so the callback never waits for a lease.
It acquires/imports ephemeral sources, issues writes, encodes and submits in
the **same host task**, invokes scope pops, then suspends to deliver
checked completion. It must not yield through the fiber scheduler between
acquisition and submit, including implicit fairness checkpoints. A compile-time
`sync` callback alone is insufficient if the scheduler can still yield there;
the runtime must provide a non-yielding host-turn section. The implementation
must prove this in a real browser. If that primitive is missing, add it rather
than promise frame safety based on microtask timing assumptions.

Explicit submission inside the frame supports multiple command buffers and
submit groups, intervening writes, external textures and query work; the
frame's batch (§8.2) supplies its synchronous resource operations. `submit`
does not silently issue a second submission. An empty frame is legal and
returns no receipt; nothing is fabricated. The outer success confirms
validation observations, not display completion. Each `Submission` is the
receipt of one native submit and supports waiting for its work when required,
without an unconditional per-frame stall (§8.3).

All standard canvas formats/usages/viewFormats/colorSpace/toneMapping/alphaMode
are exposed, with `getConfiguration` readback for specified support detection.
Canvas backing pixel dimensions are explicit and separate from CSS size and
device pixel ratio. Reconfiguration/unconfigure, resize and presentation
invalidate old current-texture generations; a still-referenced handle is not
a permanent swap-chain texture. Browser presentation timing remains the host's.
Native current texture access is available in Batch/Frame rather than as a
checked standalone call that waits until its frame may already have expired.

Video-element external textures can be reimported each animation/video frame;
native identity reuse is preserved so bind groups may be reused where the host
permits it. VideoFrame imports track explicit source closure. Image copies
expose origin, extent, flipY, colorSpace and premultipliedAlpha without hidden
coordinate flips or conversions inherited from Elm WebGL. Offscreen surfaces
and compute need no HTML view. A main-thread `OffscreenCanvas`
(`Browser.Canvas.offscreen`, §3.2) is a surface in S3 and an image source in
S5. DedicatedWorker support uses that realm's GPU and typed transferables; GPU
handles cannot be sent between workers. Worker realms and `OffscreenCanvas`
**transfer** (`Browser.Canvas.transfer`) are the worker slice's, after #1299
(§2, §10).

`device.lost` is observed from device creation, before the handle is exposed.
Loss latches, wakes pending operations and sends a typed lifecycle event.
Late observers can read the latched loss. Already-destroyed devices fail new
work immediately. There is no automatic retry/recreation: recovering acquires
a **new adapter**, negotiates a new device and rebuilds resources explicitly.
The original adapter is not assumed reusable after consumption/loss.

Uncaptured native GPU errors are decoded into typed telemetry. An error that
escaped the wrapper's mandatory scopes is an internal binding defect and stops
the owning program with the typed observation attached. Unknown classes/reasons
also defect. Optional event delivery is never used as a substitute for scopes.
Observers are fiber-scoped; cancellation removes listeners and retained source
references. Loss is retained independently so no subscriber can miss it merely
because it subscribed late. `eachEvent` is a scoped waiting operation, and
`onEvent` is its TEA subscription adapter, following existing browser conventions.

In a direct browser program, use effects in handlers/owned fibers and return
typed outcomes to the model. In TEA, `Cmd.task`/keyed commands and subscriptions
carry the same effects. `init`, `update` and `view` keep their current sync
contracts. Applications retain a stable canvas node and create resources and
render as effects. Unmount cancels owned fibers and releases their owned resources;
shared devices stay under the application’s explicit lifetime management.
Prerendering emits the canvas/placeholder only; runtime GPU access returns
`ApiUnavailable` outside a GPU host, and prerender views need no GPU operation.

### 8.1 Cancellation and defects

Canceling a wrapper wait does not undo already-submitted work. Native async
pipeline creation has no general abort method; detach the waiter, drain the
native promise, and release abandoned wrapper-owned results when it settles.
Pop all pushed scopes before allowing cancellation to take effect; continue
observing their promises after the caller cancels. No cleanup callback may
swallow an unexpected failure. Mapping and event waits use their specific
cancellers. Destruction is idempotent; destruction order and ownership are
explicit rather than dependent on JavaScript finalization/GC timing.

A defect in a native listener/promise callback enters the owning program's
defect boundary with cause and operation context. Development uses the crash
screen and release logs/stops under the existing contract. A GPU error expected
for that operation stays a value; an application intentionally choosing to
escalate that value is a separate application decision.

### 8.2 Synchronous resource operations inside a frame (#1267)

A frame's callback is synchronous, so it cannot call a checked operation such
as `Gpu.Device.createBindGroup`, which may suspend. **A frame runs in a
batch**, and the frame hands it out:

```text
Gpu.Frame.batch : Frame → Batch
```

Every `Gpu.Batch` operation therefore works inside the frame callback, with
no suspension: it returns `Result InputError` and provisional handles, and the
frame's scopes are popped before the callback's host turn ends. §6.3's rule is
the list: there is a batch form for every native synchronous GPU operation,
among them `createBindGroup`, `createBindGroupLayout`, `createView` (a texture
view), `createSampler`, `createBuffer`, `createTexture`, `createQuerySet`,
`getBindGroupLayout`, `writeBuffer`, `writeTexture`, `encode` (a command
encoder session), `submit` and `destroy`. Async operations (async pipeline
creation, `map`, `Submission.done`) are never batch forms. The frame-only
operations stay on `Frame`, because their results expire with the host task:
`getCurrentTexture` and `importExternalTexture`. `Frame.encode` and
`Frame.submitCommands` are the batch forms on the frame's surface device.
Provisional handles from `Frame.batch` are accepted or rejected with the
frame's result. A `Batch` used after its `Batch.run` or its frame ended
returns `SessionState SessionEnded`.

The type flow for a video frame, with no suspension between import and
submit:

```text
drawVideo : Surface, Scene → Result Error { value : Submission, submissions : List Submission }
drawVideo surface scene =
    Gpu.Frame.submit surface "video" λframe →
        batch = Gpu.Frame.batch frame
        video = (Gpu.Frame.importExternalTexture frame (Gpu.Types.externalTextureDescriptor (Gpu.Types.VideoElement scene.video)))?
        group = (Gpu.Batch.createBindGroup batch { layout = scene.layout, entries = [ { binding = scene.slot, resource = Gpu.Types.ExternalTextureBinding video } ], label = Default })?
        target = (Gpu.Frame.getCurrentTexture frame)?
        view = (Gpu.Batch.createView batch target Gpu.Types.textureViewDescriptor)?
        encoded = (Gpu.Frame.encode frame Gpu.Types.commandEncoderDescriptor λencoder → drawQuad encoder scene group view)?
        Gpu.Frame.submitCommands frame [ encoded.commands ]
```

### 8.3 Submission receipts (#1271)

A `Submission` is the receipt of **exactly one native `GPUQueue.submit` call**
that the engine issued, from `Queue.submit`, `Batch.submit`,
`Frame.submitCommands` or a forwarding form. A submit of an empty command
buffer list is a native call and has a receipt; a call that issues no native
submit has none. Nothing is fabricated.

- `Gpu.Queue.submit` returns one receipt. `Gpu.Batch.submit` returns
  `Result InputError Submission`, published when the batch is accepted.
  `Gpu.Encode.run` submits nothing.
- `Gpu.Frame.submit`'s `submissions` lists the frame's receipts in issue
  order: empty for a frame that submitted nothing, one per native submit
  otherwise.
- **Completion is captured at the submission.** Right after it issues the
  native submit, in the same host turn and before any other beni code can
  submit on that queue, the engine calls the queue's `onSubmittedWorkDone`
  and keeps the promise in the receipt, always draining it. The native promise
  covers all work submitted before its call, so the receipt covers its own
  submission and the earlier ones on the queue, which complete first anyway,
  and never a later submission.
- `Gpu.Submission.done : Submission → Result Error ⊤` waits for that promise;
  observed device loss wins, as for every wait, even for work done before the
  loss (*as built — S2a*: `done` gives `DeviceLost` once the loss is
  observed). Nothing waits unless `done`
  is called, so a receipt does not stall a frame.
- `Gpu.Queue.onSubmittedWorkDone` stays the faithful native form: it captures
  at its own call, so it also covers unrelated work submitted before it. Use a
  receipt to wait for one submission.
- A receipt confirms validation observations and offers a completion wait;
  neither is display completion. A failed batch or frame publishes no
  receipts; its native submissions may still have happened (§6.3: a batch is
  not a transaction), and its failure report lists them as issued.

*As built — S2a (2026-11-08, #2240).* A receipt holds the completion promise in an engine
record that counts as one of the device's pending outcomes, so the device keeps its channel to
the program while it is pending; an unexpected settlement nobody waits for reaches that program
as a defect (`browser/gpu/WorkDoneRejected`). `done` answers at once for work already done,
`DeviceLost` for a loss latched first or while it waits. `Gpu.Queue.submit` refuses a command
buffer of another device before the native call; the other command-buffer checks land with the
encoders (S2b).

*As built — S3b (2026-11-08, #2241).* `Gpu.Surface` has `fromElement`, `fromCanvas`, `fromOffscreen`
(a main-thread `Browser.Canvas.offscreen`), `configure`, `unconfigure`, `getConfiguration` and
`canvas`, whose `CanvasSource` is `Element Browser.Canvas.Canvas | Offscreen
Browser.Canvas.OffscreenCanvas`. `configure` is a checked operation on the configuration's device: a
feature-gated format is `UnsupportedCapability` first, the host's `TypeError` is
`CanvasConfigurationRejected`, and a configuration that failed leaves the surface unconfigured for
frames; a refusal before the native call (a missing feature, a lease, a loss) changes nothing of the
surface, and a configuration that an `unconfigure` or another `configure` overtook while it was
checked does not configure it. `getConfiguration : Surface → Result Error (Maybe
CanvasConfiguration)` reads the host's configuration back, a member the host leaves out as `Default`;
a host without the method is `UnsupportedCapability`, and a usage that is not a set of the pin's bits
is a defect. `Gpu.Frame` has `submit`, `batch`, `getCurrentTexture`, `encode` and `submitCommands`; a
frame is a `Gpu.Batch.run` on the surface's device whose batch is the `Frame`, so §8.2's batch bridge
is the batch itself, and `Frame.submit` refuses an unconfigured surface (`CanvasUnconfigured`) and a
leased device before the callback runs. Every native submit of the frame, through
`submitCommands` or `Gpu.Batch.submit` on the frame's batch, adds its receipt to `submissions` in
issue order. **The non-yielding host-turn section is the scope section itself**: the callback is
`sync`, so it is emitted as plain JavaScript with no suspension point, and the engine runs it inside
the device's scope section, one synchronous call; `browser/gpu/SurfaceFrames`' *checkpoint* shows
that a microtask queued at the start of the callback has not run when it has submitted. A current
texture and every view of it expire (`ResourceExpired`, the engine's `usable`) when its frame ends,
when the surface is configured again or unconfigured, and when its canvas is resized: every
`Browser.Canvas.resize` counts (`resizeCount`), one to the same size or undone at once too, and a
size changed any other way is caught by comparing `width` and `height`. A view keeps the frame mark
of the frame that made it, so a later frame that gets the same native texture (the host gives one a
task) takes the texture as its own but never revives an earlier frame's view. What a frame's texture
is in expires with it: an encoder session records every frame-bound object a command names, and the
command buffer or bundle it finishes holds them, as a bind group holds the frame views it binds; a
held object expired is `ResourceExpired` (`browser/gpu/FrameRetry`, `FrameDependencies`). `importExternalTexture` is S5's (below). Since the batch review a
frame's callback and its operations return `Result Error`, as a batch's do, a failed frame is
`BatchFailed` with the operations it issued and refused, and a cancelled frame rejects what it made
and publishes no receipt (`FrameCancelled`); a submit on another device's queue is `WrongDevice`
(`FrameOtherQueue`). Fixtures:
`SurfaceFrames` (receipts, expiry, resize, reconfiguration, an `OffscreenCanvas`, the checkpoint),
`SurfaceConfiguration` (configuration, its refusals and readback, a lease), `CanvasPage` (a TEA page
with a stable `<canvas>`), and the defects `CurrentTextureUnlisted`, `CurrentTextureSpoofed`, `ConfigureUnlisted` and
`ConfigureSpoofed`. `SurfaceConfiguration`'s *checkpoint* repeats the microtask probe in a frame that
acquires no texture, and its *conflict* shows a canvas keeping its first context kind. All of them run in `test-webgpu`'s
Chrome, which runs Skia and ANGLE on SwiftShader's Vulkan (`--enable-features=Vulkan
--use-vulkan=swiftshader --use-angle=vulkan`): on ANGLE's SwiftShader GL, Chrome composites in
software and has no shared-image backing for a canvas texture, so `getCurrentTexture` lost the
device and the next `popErrorScope` and `onSubmittedWorkDone` rejected with an `OperationError`
(#2267, a host configuration failure, not a ledger row). A direct `Browser.hosted` page is #2268.


*As built — S5 (2026-11-08, #2243), names chosen under the owner's delegation.* **Copies.**
`Gpu.Queue.copyExternalImageToTexture : Queue, CopyExternalImageSourceInfo, CopyExternalImageDestInfo,
Extent3D → Result Error ⊤` is a checked operation, prepared once in `Gpu.Make` (`CopyExternalImage`)
and run three ways: alone, as `Gpu.Batch.copyExternalImageToTexture` (and so in a frame, whose batch
is the frame) and as `Gpu.Diagnostics.Queue.copyExternalImageToTexture`. Before the native call it
checks the destination as every texture argument (`ResourceDestroyed`, `WrongDevice`, a batch on
another device's queue `WrongDevice`) and the source's state. Its classifier takes the ledger's three
native `DOMException`s only (§6): `SecurityError` is `SourceNotOriginClean`, `OperationError`
`ExternalImageCopyRangeRejected`, `InvalidStateError` `SourceUnusable`; anything else, a same-named
plain object included, is a defect. The destination's usage, format and dimension stay the device's
`Validation`. **The source's state is read first.** HTML's *check the usability of the image argument*
reads state a page can read in the same host turn, so the engine refuses what it refuses, before the
native call, with arms added to `SourceError`: `SourceClosed` (a closed bitmap or video frame),
`SourceDetached` (image data whose pixels were detached), `SourceEmpty` (a canvas with a width or a
height of 0, an image element with no source), `SourceBroken` (an image element whose request failed,
or with no natural size) and `SourceNotReady` (an image element still loading, a video element whose
`readyState` is below `HAVE_CURRENT_DATA`). The last two are the cases the host would answer with
the device's validation error instead of a throw (the usability result *bad*); refusing them first gives
the precise cause. Origin-clean state is the host's and is never guessed. **External textures.**
`Gpu.Batch.importExternalTexture : Batch, ExternalTextureDescriptor → Result Error ExternalTexture`
and `Gpu.Frame.importExternalTexture` (the same on the frame's batch) return `Result Error`, as every
batch operation does since the batch review. There is no standalone checked import: a video
element's texture expires with the task that imported it, and a checked operation's result is
published after that task (the reason `getCurrentTexture` has none, §8). The import refuses a closed
frame (`SourceClosed`) and a video with no current frame (`SourceNotReady`) first; its classifier
takes `SecurityError` (`SourceNotOriginClean`) and `InvalidStateError` (`SourceUnusable`) only.
Expiry is the specification's `[[expired]]`, kept in the engine's record (`Engine.expiresExternal`):
a video element's texture expires when its batch's run ends, a video frame's when the frame is closed,
and what holds one — a bind group, a command buffer, a bundle — is `ResourceExpired` with it, by the
same holding rule as a frame's texture. A reimport the host answers with the same object marks it
again, so what held it is usable again, as the specification allows. `Gpu.ExternalTexture` has
`label` and `setLabel`. The commands inside a batch need no forwarding form (§6.4), so an import
under a session is `Gpu.Diagnostics.Batch.run`'s. Fixtures (`browser/gpu/`), every pixel compared under
`test-webgpu` with an 8×8 image whose bytes are written out by hand: `ExternalCopyBitmap` (whole,
`flipY`, a source origin), `ExternalCopyImageData`, `ExternalCopyImage`, `ExternalCopyVideo`,
`ExternalCopyVideoFrame`, `ExternalCopyCanvas`, `ExternalCopyOffscreen`, `ExternalTextureFrame`,
`ExternalTextureVideo` (a batch and a frame); a video is read at the centre of 8×8 blocks within 12
per byte, for its YUV conversion. The refusals: `ExternalSourceClosed`, `ExternalSourceDetached`,
`ExternalSourceEmpty`, `ExternalSourceNotReady`, `ExternalSourceBroken`, `ExternalSourceTainted` (in
Chrome a real cross-origin image, from the driver's `/_media/image.bmp` on `localhost`),
`ExternalCopyRange`, `ExternalCopyRefusals`, `ExternalUnusable` (injected), `ExternalDiagnostics`, and
the defects `ExternalCopyUnlisted`, `ExternalCopySpoofed`, `ExternalImportUnlisted` and
`ExternalImportSpoofed`.


## 9. Reserved

The additional rendering abstraction was removed by the owner on 2026-10-30.
The section number is retained for existing references.

## 10. Verification and delivery plan

The contract is adopted (2026-11-08). Implementation lands in the slices
below, each with its own issue, a pull request, checked public API docs and
`skills/beni/` updated with `zig build skill-api` where it adds a shipped
surface. **Before a slice's public signatures ship, the slice confirms their
names with the owner** (§11 item 6). Delivery is main thread first (§2).
Completeness is claimed only when
the entire inventory and the supporting adapters, worker realms included, are
delivered (S6 and the worker slice).

**Build first, optimize later** (the owner, 2026-11-01): S1–S5 carry no
benchmark and no byte budget; measurements belong to the performance slice.
One size fact stays, as a correctness check in every slice: **a program that
does not import `Gpu` ships zero GPU runtime**, so no `emit/` golden of an
existing fixture changes because of this work.

| Slice | Issue | Deliverable | Acceptance evidence |
|---|---|---|---|
| S1 foundation | [#2239](https://github.com/canassa/beni/issues/2239) | Generated `Browser.Host.GPU*` types, `Gpu.Types` and `Gpu.Flags` with the gated staleness check (§2.2) and the uniform-exposure assertion (§2.3); `Gpu.Handle` (§2.1), `Gpu.Scalar`, `Gpu.Error`; availability, adapter, device, `destroy`, loss latch; the checked-operation engine of §6.1 with the state table and the lease flag of §6.4; the `test-webgpu` runner | Generated-vs-IDL comparison of every descriptor, enum, flag and constant; conversion/default/null/overload tests; no `Js.Value` in public signatures; host fault injection for every S1 ledger row; interleaved fiber and cleanup tests; unexpected classes defect; `test-webgpu` reports adapter metadata and `passed`/`unsupported`/`skipped` |
| S2 compute and mapping | [#2240](https://github.com/canassa/beni/issues/2240) | Buffers, `map`/`withMapped`/`currentMapping` and mapped ranges (§7, §7.1), queue writes and receipts (§8.3), shader modules, compute pipelines and layouts, bind groups, command encoders, compute passes, copies, clears, queries, immediate data, `Gpu.Encode` (§6.2) and `Gpu.Batch` (§6.3) for these | Compute results read back and compared with independent expected answers; alignment, limit, usage and fixed-length-backing (§3.1) failures; the two `mappedAtCreation` cases of §7.1; exact u64 round trips |
| S3 render and presentation | [#2241](https://github.com/canassa/beni/issues/2241) | `Gpu.Surface` on a canvas element and on a main-thread `OffscreenCanvas` (`fromOffscreen`), configuration, `Gpu.Frame` with §8.2's batch bridge, render pipelines and passes, bundles, occlusion queries, indirect draws, the non-yielding host-turn section, direct and TEA program integration | Multi-pass, MSAA, depth/stencil, MRT and indirect scenes compared by read-back pixels; resize/reconfigure invalidation; same-task expiry adversaries; zero and multiple receipts (§8.3) |
| S4 diagnostics and events | [#2242](https://github.com/canassa/beni/issues/2242) | `Gpu.Diagnostics` (§6.4), its forwarding surface, uncaptured-error telemetry, `eachEvent`, `onEvent`, cancellation (§8.1) | `DeviceLeased` for an ordinary call from the callback, a joined child and an unrelated fiber, each without waiting; every exemption of §6.4 (teardown, state reads, mapped memory, waits on earlier work) runs under a lease; a drained outcome's unexpected failure reaches the device's program as a defect; nesting; every cancellation and defect phase releases the lease; `ScopeUnderflow`; an escaped native error defects |
| S5 media sources | [#2243](https://github.com/canassa/beni/issues/2243) | External textures and `copyExternalImageToTexture` from every main-thread source arm, the main-thread `OffscreenCanvas` arm included, with #1278's sources | Every source arm compared by read-back pixels; closed, detached and not-origin-clean sources return their typed errors |
| S6 completeness audit | [#2244](https://github.com/canassa/beni/issues/2244) | Every inventory row tied to a public declaration and a behavioural fixture, or to its later slice; new-standard delta process | A gate fails for a row with neither; CTS-derived boundary cases and the native-vs-beni differential harness in `test-webgpu` |
| Later: workers | after [#1299](https://github.com/canassa/beni/issues/1299) | WebGPU in DedicatedWorker, SharedWorker and ServiceWorker realms; `OffscreenCanvas` transfer and worker surfaces; worker transfers of bitmaps, frames and binary | Worker entries run the S1–S5 scenarios; transfer detachment and typed transfer errors |
| Later: WGSL | [#1276](https://github.com/canassa/beni/issues/1276) | Built-in WGSL validation and minification | As that issue specifies |
| Later: performance | [#2245](https://github.com/canassa/beni/issues/2245) | Measurements and budgets | Below |

**The WebGPU runner.** The current browser harness commonly disables the GPU,
and happy-dom is not a WebGPU implementation: it is useful for canvas
mount/unmount and deterministic wrapper tests, **not evidence of GPU
correctness**. S1 adds `zig build test-webgpu`, an opt-in runner (not a gate)
in headless Chrome with a real WebGPU adapter (the owner, 2026-11-08; whether
CI runs it is a later decision). Chrome's software adapter
(SwiftShader) is allowed: it is the browser's own WebGPU implementation, not a
fallback in beni's API. The runner records backend and adapter metadata and
distinguishes `unsupported`/`skipped` from `passed`. It is a heavy job and takes
the shared lock as `test-browser` does. Do not add a software emulation
fallback to the user API merely to satisfy tests. Cross-browser runs are needed
for browser-specific errors and feature negotiation; no browser/version support
matrix is invented here.

Use the pinned CTS to select and, where feasible, adapt validation/operation
cases. Running the native CTS alone tests the browser, not beni's conversion,
scope or cancellation logic. For beni run the same scenario natively and through
the wrapper, compare bytes/results and error categories, and preserve labels
and diagnostics without comparing localized message text. GPU OOM/internal
failures need deterministic host injection; do not make hardware OOM a gate.

Required adversarial scenarios, each landing with the slice that owns the
operation: throw a user TypeError inside the frame; reject a native promise
with an unlisted DOM exception; spoof an error name; interleave two
same-device fibers; resolve scope pops out of order; report both map rejection
and validation; lose the device before/during/after publication; cancel each
wait and every cleanup phase; retain stale mapped/frame/provisional handles;
use a wrong-device resource; mutate source state between prepare/use; submit a
command buffer twice; exercise all null/omitted descriptors; transfer and close
sources (worker slice); and return diagnostics around non-BMP source
characters.

**The performance slice** (#2245, after S6) measures against equivalent direct
JavaScript on the same backend: CPU encoding and submission medians, native
scope overhead separately, per-frame allocations, mapping/transfer copies,
initialization/pipeline work, brotli/raw bytes and idle retention, and that a
compute-only project ships no canvas or media helpers. A validated batch can
trade diagnostic granularity for fewer scopes; it may not disable error
handling in release. No performance claim is made before those measurements.

## 11. Decisions

*Adopted by the owner on 2026-11-08*
([#1277](https://github.com/canassa/beni/issues/1277#issuecomment-6714461181)).
Items 1–6 were this document's recommendations and are now decisions; items
7–10 were taken the same day.

1. **Decided 2026-11-08.** Full pinned standard coverage, with the explicit
   observability limit in §1. Literal capture of undetectable WGSL faults
   cannot be guaranteed by this host API. Future standard additions require
   tracked updates.
2. **Decided 2026-11-08.** Browser-owned `Gpu.*` direct Result functions, typed
   descriptors and complete WGSL source access.
3. **Decided 2026-11-08.** Checked completion for resources, sync encode/frame
   callbacks for task-lived sources, provisional shared handle state and
   explicit batch failure semantics. No linear/rank-2 types solely for GPU
   handles.
4. **Decided 2026-11-08.** The operation-specific ledger and typed
   `GPUInternalError`/`UnknownLoss` distinction; unexpected observations
   defect. All validation stays in release.
5. **Decided 2026-11-08.** Typed binary/source/OffscreenCanvas/DedicatedWorker
   support is in the completeness scope. Those prerequisites have their own
   imported-API contracts and implementation issues (#1278, #1299); they are not
   existing APIs or optional debt hidden behind a claim of 100%.
6. **Decided 2026-11-08.** The lease-based explicit scope adapter, which is more
   complex than only automatic scopes but preserves native diagnostic
   functionality safely. Naming is not frozen by this document: as
   recommended, each slice confirms the names of its public signatures with
   the owner before they ship (§10).
7. **Decided 2026-11-08** ([#1281](https://github.com/canassa/beni/issues/1281)).
   The handle types live in one acyclic `Gpu.Handle` module; `Gpu.Types` and the
   operation modules import it; under option C the native handles are generated
   native types (§2.1). The same day the owner decided that every GPU operation
   is a qualified call or a `▷` pipe, with no exceptions, and that every handle
   type, the engine-made ones included, stays in `Gpu.Handle`.
8. **Decided 2026-11-08** ([#1270](https://github.com/canassa/beni/issues/1270)).
   D3 as decided: "a same-owner call gets a typed refusal (a session-state
   error) and does not wait. No `Task.Identity`" ([#1280](https://github.com/canassa/beni/issues/1280)
   closed). Later the same day the owner extended it: while a diagnostic
   session holds a device's lease, an ordinary checked operation from **any**
   fiber on that device returns `SessionState DeviceLeased` at once. Nothing
   waits on a lease and no core slot is added. The session value is the lease
   token (§6.4).
9. **Decided 2026-11-08.** Main thread first. WebGPU in workers and
   `OffscreenCanvas` transfer wait for
   [#1299](https://github.com/canassa/beni/issues/1299) and stay in the
   completeness scope as a later slice (§2, §10).

10. **Decided 2026-11-08.** `zig build test-webgpu` is opt-in and not a gate;
    whether CI runs it is decided later (§10).

Nothing in this contract is open for the owner as of 2026-11-08.
