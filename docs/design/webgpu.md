# WebGPU for beni

**Status: proposal for owner review, 2026-10-29; not adopted or implemented.**
[Issue #1257](https://github.com/canassa/beni/issues/1257) requests research and
API design only. This document proposes the contract; existing browser APIs
and compiler behavior do not change. Evidence: [research](research/webgpu-api-research.md),
[failure ledger](research/webgpu-errors.md), [source pins](research/webgpu/sources.json)
and [complete coverage inventory](research/webgpu/coverage.md).

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
part of the proposed contract and must be visible in the public API docs.

Native-only extensions and non-normative GPUWeb extension documents are outside
this browser contract. New standard revisions require an explicit inventory,
failure-ledger and binding update. Unsupported optional standard functionality
returns a typed availability error; the library never silently changes its
meaning or substitutes another rendering API.

## 2. Placement and layers

Implement `Gpu.*` in the shipped browser platform and reexport through its
browser/TEA/direct page layers where applicable. Core stays platform-independent.
GPU objects are opaque platform-owned handles; ordinary modules never import
`Js` or pass raw JavaScript objects. Implement orchestration, descriptors,
validation, lifetimes and error classification in beni over `Js`, following the
existing Task/Http boundary discipline. New host primitives need the same exact
foreign/type/arity/effect checks as other platform primitives.

| Layer | Purpose | Completeness rule |
|---|---|---|
| `Gpu`, `Gpu.Types`, `Gpu.Flags`, `Gpu.Feature`, `Gpu.Limits`, `Gpu.WgslFeature` | Availability, typed descriptors/scalars/unions/constants, capability negotiation | Entire IDL and standard feature/format tables |
| Resource and command modules | Checked native capabilities with managed state, mapping and encoding | Every inventoried interface/member/overload |
| `Gpu.Batch`, `Gpu.Frame`, `Gpu.Diagnostics` | Scope-safe grouped operations, presentation and explicit diagnostics | Same native operations and typed errors; no hidden capability gap |
| `Gpu.Layout`, `Gpu.Mesh`, `Gpu.Entity`, `Gpu.View` | Optional Elm-inspired convenience API | Lowers to the complete layer, never a second engine |
| Supporting `Binary`, `Browser.Image`, `Browser.Video`, `Browser.Canvas`, worker transfers | Typed binary/source/canvas interoperability | Every native input union arm is constructible; no application FFI |

The last row is **new API work**, not an assertion that those modules exist.
The repository currently lacks general binary/source wrappers. Their delivery
is required before claiming full coverage. Page markup integration belongs to
the browser runtime, not compiler special knowledge of GPU descriptors.
DedicatedWorker entry/transfer integration must be designed in that supporting
work too; an existing Cloudflare `Worker` module is not a browser worker host.
The foundation follows the specification's `Window` and `Worker` exposure, not
only the main window. SharedWorker/ServiceWorker realms that expose the API
must be usable by the same headless modules; missing host capabilities are
typed availability outcomes. DedicatedWorker is the first proposed worker
integration fixture, not an exclusion of the other standard Worker realms.

## 3. Mechanical translation of the whole native API

[coverage.md](research/webgpu/coverage.md) is normative for this proposal's
surface, including empty declarations, inheritance, partial interfaces and all
37 mixin inclusions. Its owner column names where each capability lives. Most
interfaces map directly to `Gpu.<name without GPU>`; shader modules use
`Gpu.Shader`, pass encoders use `Gpu.ComputePass`/`Gpu.RenderPass`, canvas
contexts use `Gpu.Surface`. Constructors of errors/events become typed beni
values, not raw JavaScript constructors. Host errors retain their diagnostic
metadata; synthetic values cannot fabricate GPU failure dispatch.

For each member the translation is deterministic:

1. The receiver is the first argument; remaining arguments stay in native order.
   Functions use saturated n-ary beni types and subject-first dot-call support.
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
   Label access uses `Gpu.Object.label`/`setLabel` over the known handle kinds,
   or equivalent receiver-specific forwarding methods. It is not restricted
   to buffers or only present in development builds.
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
`Result InputError` and conversion helpers. Their accepted domains cover every
value the corresponding Web IDL type accepts after conversion. Integer
constructors require integral values; callers can request the standard's
truncating conversion explicitly. Preserve signed baseVertex/depthBias, not
just unsigned offsets. Finite f32 conversion must check overflow after f32
rounding. Raw buffer bytes may contain NaN or infinities where WGSL permits
those patterns; descriptor numeric checks do not restrict binary payloads.

`Size64` covers Number-representable nonnegative integral values below 2⁶⁴,
including exactly representable values above 2⁵³. The maximum representable
valid Number is 2⁶⁴ − 2048. A convenience constructor from a safe beni integer
is not the only route. Exact u64 query results use `Binary.U64 { high : U32,
low : U32 }` (or an equivalent opaque representation); conversion to Number
returns an error when it loses bits. Do not pass that pair to a native GPUSize64
parameter without proving exact representability. Arithmetic helpers detect
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

### 3.2 Typed intake for every host source

The supporting API must provide typed acquisition, not just types with no
public constructors. The minimum proposed intake is:

```text
Binary.allocate : Size64 → Result Binary.AllocationError Binary.Buffer
Binary.view : Binary.Buffer, ViewKind, ByteRange → Result Binary.ViewError Binary.View
Binary.shared : Size64 → Result Binary.SharedError Binary.SharedBuffer
Binary.u64Words : U32, U32 → Binary.U64

Browser.Image.fromElement : String → Result ImageError Browser.Image.Element
Browser.Image.decode : ImageInput, BitmapOptions → Result ImageError Browser.Image.Bitmap
Browser.Image.data : ImageDataDescriptor, Binary.View → Result ImageError Browser.Image.Data
Browser.Video.fromElement : String → Result VideoError Browser.Video.Element
Browser.Video.frame : VideoFrameSource, VideoFrameInit → Result VideoError Browser.Video.Frame
Browser.Canvas.fromElement : String → Result CanvasError Browser.Canvas.Canvas
Browser.Canvas.offscreen : U32, U32 → Result CanvasError Browser.Canvas.OffscreenCanvas
Browser.Canvas.transfer : Browser.Canvas.Canvas → Result CanvasError Browser.Canvas.OffscreenCanvas
```

`ImageInput` includes decoded source handles and encoded bytes (with MIME where
needed); `VideoFrameSource` includes typed image sources and raw pixel-buffer
descriptors. Full VideoFrame construction metadata and image decoding options
belong to those supporting modules, not an unchecked dictionary argument.
GPU source-sum constructors wrap each resulting handle without exposing its
native object. Typed worker message transfers can also receive Bitmap, Frame,
OffscreenCanvas and transferable binary handles; the source side becomes
detached and all aliases observe that state. Receiving rebinds the wrapper to
the destination realm. Shared buffers are shared explicitly, not transferred.

This scope does not imply full WebCodecs or the entire HTML media API. It does
require all GPU source forms to be usable, along with readiness/close/size and
animation/video-frame scheduling needed for correct GPU use. The error sums
above need individual per-method constructor/decode/transfer contracts before
implementation, under the same no-broad-catch rule. They cannot be implemented
as `Error String`, and none is claimed to exist today.

## 4. Public surface and typical use

The snippets below are **proposed signatures and fragments**, tagged `text`
because they do not name shipped modules. Effects are inferred: this proposal
does not add `Task Error a`, `async` syntax or a new language feature.

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
overlapping mapped range, and unsupported required format/capability. Each
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
   lost/destroyed device. Resolve the owning realm and negotiated capabilities.
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
Gpu.Batch.submit : Batch, Queue, List CommandBuffer → Result InputError ⊤
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

### 6.4 Explicit error-scope diagnostics without an unsafe escape hatch

Native push/pop are available through an explicit **diagnostic session**, not
as uncontrolled global mutations interleaved with automatic wrappers:

```text
Gpu.Diagnostics.run : Device, (DiagnosticSession → a) → Result Error (DiagnosticReport a)
Gpu.Diagnostics.pushErrorScope : DiagnosticSession, ErrorFilter → Result InputError ⊤
Gpu.Diagnostics.popErrorScope : DiagnosticSession → Result DiagnosticError (Maybe GpuError)
```

The session acquires an exclusive, cancellation-safe per-device lease **before**
pushing scopes. Its callback may suspend; only session-associated operations
may access that device until the lease ends. Other operations wait before
entering their native stack section. A sync frame callback never waits for
this lease: `Frame.submit` acquires it before the frame starts. Nested diagnostic
sessions reuse the owner's lease; cross-device lock ordering/cycles must produce
a typed session-state error or be avoided by explicit acquisition ordering.

Session operations issue native calls under the user's diagnostic scopes, so
automatic inner scopes do not steal the errors being inspected. Engine-owned
outer scopes capture any class the user did not capture. Public native scope
semantics (filter nesting and representative selection) remain intact. Popping
an empty user stack returns `ScopeUnderflow`; underflow in the engine's own
outer scopes is a defect. A finalizer pops unclosed scopes, drains their results
and releases the lease on completion, cancellation or defect.

The explicit session forwarding surface is
`Gpu.Diagnostics.<owner>.<member> session …` for every inventoried operation;
the session argument is the lease authority. This includes async pipeline/map
waits and sync encoder calls. Ordinary checked operations are not implicitly
reclassified merely because a fiber happens to hold a session. Session-scoped
native errors remain typed observations even when deliberately requested by the
caller, and no engine-owned inner scope hides them from `popErrorScope`.

Created handles are provisional until the diagnostic session accepts them;
an invalid native diagnostic object can never escape as an accepted resource.
The report holds the callback value only when safe to publish, plus explicit
scope observations. A failed session withholds that value and returns the
observed typed failures. This preserves the ability to test native failure
behavior without giving ordinary code a raw GPU handle or unchecked use route.

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
Gpu.Buffer.getMappedRange : Mapping, Range → Result Error MappedRange
Gpu.Buffer.withMapped :
    Buffer, MapRequest, (Mapping → Result Error a) → Result Error a
Gpu.Buffer.unmap : Buffer → ⊤
Gpu.Buffer.destroy : Buffer → ⊤
Gpu.Texture.destroy : Texture → ⊤
Gpu.QuerySet.destroy : QuerySet → ⊤

Gpu.MappedRange.readBytes : MappedRange, Range → Result InputError Binary.Bytes
Gpu.MappedRange.writeBytes : MappedRange, Offset, Binary.Bytes → Result InputError ⊤
Gpu.MappedRange.readU32 : MappedRange, Offset → Result InputError U32
Gpu.MappedRange.writeF32 : MappedRange, Offset, Float → Result InputError ⊤
```

Mapped ranges access native mapped storage directly through typed reads/writes;
`readBytes` explicitly copies into persistent bytes. Include all numeric views,
bulk copies and exact bit access, not only the representative methods above.
Expose read/write modes, size and mapState. `mappedAtCreation` produces a mapping
handle without pretending `MAP_WRITE` was required. Ranges track overlap,
alignment, mapping generation and read/write permission. Every access validates
the generation, including one saved outside `withMapped`. `unmap`/destroy
detaches all native ranges and invalidates every alias before any subsequent use.

The bracket helper unmaps in a finalizer even if the callback suspends, cancels,
returns an error or defects. Concurrent map requests are refused precisely;
cancelling the fiber waiting for a pending map calls unmap only for that owned
map generation. It cannot cancel a later independent mapping. Native map
promises are still drained. Direct map/unmap remains available for full native
lifetime control. Returned mutable mapped memory never masquerades as an
immutable `List Int` or a transferable general-purpose ArrayBuffer.

The binary layer handles host-shareable WGSL layout explicitly: scalar types,
vec/matrix alignment, struct offsets, member `@align`/`@size`, array stride,
runtime arrays, uniform vs storage constraints and f16 encoding. Raw bytes are
always available. Optional `Gpu.Layout a` supplies typed encoders/decoders and
layout declarations; it cannot infer a correct GPU layout from an arbitrary
beni record without a supplied schema.

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
    → Result Error { value : a, submission : Submission }
Gpu.Frame.getCurrentTexture : Frame → Result InputError Texture
Gpu.Frame.importExternalTexture : Frame, ExternalTextureDescriptor → Result InputError ExternalTexture
Gpu.Frame.encode : Frame, CommandEncoderDescriptor, sync (CommandEncoder → Result InputError a)
    → Result InputError { value : a, commands : CommandBuffer }
Gpu.Frame.submitCommands : Frame, List CommandBuffer → Result InputError ⊤

Gpu.Device.loss : Device → Maybe DeviceLoss
Gpu.Device.awaitLost : Device → DeviceLoss
Gpu.Device.eachEvent : Device, (DeviceEvent → ⊤) → ⊤
Gpu.Device.onEvent : Device, (DeviceEvent → msg) → Sub msg
```

`Frame.submit` obtains any needed device lease before starting the synchronous
callback. It acquires/imports ephemeral sources, issues writes, encodes and
submits in the **same host task**, invokes scope pops, then suspends to deliver
checked completion. It must not yield through the fiber scheduler between
acquisition and submit, including implicit fairness checkpoints. A compile-time
`sync` callback alone is insufficient if the scheduler can still yield there;
the runtime must provide a non-yielding host-turn section. The implementation
must prove this in a real browser. If that primitive is missing, add it rather
than promise frame safety based on microtask timing assumptions.

Explicit submission inside the frame supports multiple command buffers and
submit groups, intervening writes, external textures and query work. `submit`
does not silently issue a second submission. An empty frame is legal; nothing
is fabricated. The outer success confirms validation observations, not display
completion. `Submission` identifies the queue submission boundary and supports
waiting for work done when required, without an unconditional per-frame stall.

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
and compute need no HTML view. DedicatedWorker support uses that realm's GPU
and typed transferables; GPU handles cannot be sent between workers.

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
contracts. A GPU view holds a stable canvas node; it never creates a device or
changes the DOM during a pure `view`. Unmount cancels frame drivers and releases
resources **owned by that view**, not shared devices supplied by the application.
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

## 9. The Elm-inspired rendering layer

Keep Elm's distinction between reusable mesh data, a shader/pipeline, uniforms
(bindings in WebGPU) and an entity. Explicit device setup and typed errors
replace hidden compilation during `view`. No `[glsl| … |]` syntax is copied:
WGSL is the standard source, and static literal/reflection support would be a
separate language proposal.

```text
Gpu.Layout.vertex : VertexLayout a → Result InputError (VertexEncoder a)
Gpu.Mesh.triangles : VertexEncoder a, List (a × a × a) → Result InputError (Mesh a)
Gpu.Mesh.indexedTriangles : VertexEncoder a, List a, IndexData → Result InputError (Mesh a)
Gpu.Mesh.upload : Device, Mesh a → Result Error (UploadedMesh a)
Gpu.Entity.make : RenderPipeline, UploadedMesh a, List BindGroup → Result InputError Entity
Gpu.Entity.withSettings : Entity, EntitySettings → Entity
Gpu.Entity.draw : RenderPass, Entity → Result InputError ⊤
Gpu.View.canvas : List (Html.Attribute msg), SurfaceKey → Html msg
```

These are conveniences, not the foundation's only topology or binding model.
Points/lines/line-strip/triangle-strip, instancing, indirect draws, vertex-less
fullscreen shaders, multiple streams, storage-backed rendering, compute-generated
geometry and all explicit pipelines remain available below. Entities can combine
different mesh/binding types in one pass after their layouts have been checked.
Pipeline-static settings select or cache an appropriate pipeline; they cannot
pretend WebGPU has WebGL's mutable fixed-function state. Viewport/scissor and
other native dynamic state are separate explicit commands.

Reuse uploaded meshes, bindings and pipelines by handle/source identity; avoid
per-render resource creation. A cache key includes device generation, layout,
shader entry/overrides, target formats and every pipeline-static setting.
Do not use structural equality that collapses resource identity, and never reuse
resources across restored devices. Caches expose disposal and bounded retention.
Convenience image loaders preserve the supporting image API's typed load/decode
errors before invoking the same checked GPU upload boundary.

Typical flow, deliberately showing where checked results occur:

```text
initialize config =
    -- Direct Result composition; all failures stay typed.
    adapter ← Gpu.requestAdapter config.adapter
    device ← Gpu.Adapter.requestDevice adapter config.device
    shader ← Gpu.Shader.compile device config.shader
    pipeline ← Gpu.Device.createRenderPipelineAsync device (pipelineFor shader)
    mesh ← Gpu.Mesh.upload device config.mesh
    surface ← Gpu.Surface.fromElement "scene"
    Gpu.Surface.configure surface (canvasFor device config)
    Ok { device, pipeline, mesh, surface }

draw resources =
    Gpu.Frame.submit resources.surface "scene" λframe →
        -- Everything inside this callback is sync; GPU checks finish outside it.
        target ← Gpu.Frame.getCurrentTexture frame
        encoded ← Gpu.Frame.encode frame encoderDefaults λencoder →
            Gpu.RenderPass.with encoder (clearPass target) λpass →
                Gpu.Entity.draw pass (entityFor resources)
        Gpu.Frame.submitCommands frame [ encoded.commands ]
```

The arrow lines are explanatory Result-composition pseudocode, not a proposed
change to beni's existing `let … ← …`/`?` syntax. No example in this document is
claimed to compile before the proposed API exists.

## 10. Verification and delivery plan

No implementation lands before the owner accepts the contract and resolves §11.
Implementation is staged for review, but completeness is claimed only when
the entire inventory and supporting adapters are delivered. Each implementation
slice gets its own issue, checked public API docs, and skill API regeneration
where it adds a shipped surface.

| Stage | Deliverable | Acceptance evidence |
|---|---|---|
| Boundary types and supporting binary/source contracts | Exact descriptors/enums/flags/scalars, binary/source/canvas/worker types, per-adapter imported failure contracts | Generate/compare all IDL entries; conversion/default/null/overload tests; no `Js.Value` in public signatures |
| Checked device/resource engine | Capability negotiation, resource state, all error channels, three-filter scope sections, cancellation and defects | Controlled host fault injection for every ledger row; interleaved fiber/cleanup tests; unexpected-class defects |
| Complete compute and transfers | Pipelines/layouts, buffers/mapping, all copies/writes, command states, queries, immediate data | Native-vs-beni compute/readback differentials, alignment/limit/usage failures and exact u64 round trips |
| Complete rendering and presentation | All graphics state, render bundles/queries, surfaces, all external sources, worker/offscreen path | Real-browser multi-pass/MSAA/depth/stencil/MRT/indirect/media/resize/loss tests; same-task expiry adversaries |
| Ergonomic layer | Typed layouts, meshes/entities, stable canvas, owned frame driver and TEA adapters | Shared-device/unmount/cancellation cases; no resource churn in stable views |
| Completeness and performance audit | Every inventory entry tied to public declaration and behavioral fixture; new standard delta process | CTS-derived boundary cases and native differential harness on available real implementations; measured overhead/output bytes |

The current browser harness commonly disables the GPU and happy-dom is not a
WebGPU implementation. It is useful for canvas mount/unmount and deterministic
wrapper tests, **not evidence of GPU correctness**. Add a separate opt-in
WebGPU browser runner with explicit backend/adapter metadata. Exercise hardware
and software backends where available; distinguish `unsupported`/`skipped`
from `passed`. Do not add a software emulation fallback to the user API merely
to satisfy tests. Cross-browser runs are needed for browser-specific errors and
feature negotiation; no browser/version support matrix is invented by this research.

Use the pinned CTS to select and, where feasible, adapt validation/operation
cases. Running the native CTS alone tests the browser, not beni's conversion,
scope or cancellation logic. For beni run the same scenario natively and through
the wrapper, compare bytes/results and error categories, and preserve labels
and diagnostics without comparing localized message text. GPU OOM/internal
failures need deterministic host injection; do not make hardware OOM a gate.

Required adversarial scenarios include: throw a user TypeError inside the frame;
reject a native promise with an unlisted DOM exception; spoof an error name;
interleave two same-device fibers; resolve scope pops out of order; report both
map rejection and validation; lose the device before/during/after publication;
cancel each wait and every cleanup phase; retain stale mapped/frame/provisional
handles; use a wrong-device resource; mutate source state between prepare/use;
submit a command buffer twice; exercise all null/omitted descriptors; transfer
and close sources; and return diagnostics around non-BMP source characters.

Measure against equivalent direct JavaScript on the same backend: CPU encoding
and submission medians, native scope overhead separately, per-frame allocations,
mapping/transfer copies, initialization/pipeline work, brotli/raw bytes and idle
retention. A validated batch can trade diagnostic granularity for fewer scopes;
it may not disable error handling in release. Existing projects that do not
import Gpu must ship zero GPU runtime, and compute-only projects must not ship
mesh/view/media helpers. No performance claim is made before those measurements.

## 11. Proposed decisions for owner review

1. Adopt full pinned standard coverage, with the explicit observability limit
   in §1. Literal capture of undetectable WGSL faults cannot be guaranteed by
   this host API. Future standard additions require tracked updates.
2. Adopt browser-owned `Gpu.*` direct Result functions, typed descriptors and
   complete WGSL source access, with an optional Elm-inspired layer.
3. Adopt checked completion for resources, sync encode/frame callbacks for
   task-lived sources, provisional shared handle state and explicit batch
   failure semantics. Do not add linear/rank-2 types solely for GPU handles.
4. Adopt the operation-specific ledger and typed `GPUInternalError`/`UnknownLoss`
   distinction; unexpected observations defect. Keep all validation in release.
5. Include typed binary/source/OffscreenCanvas/DedicatedWorker support in the
   completeness scope. Those prerequisites need their own detailed imported-API
   contracts and implementation issues; they are not existing APIs or optional
   debt hidden behind a claim of 100%.
6. Confirm naming and diagnostic-session ergonomics before public signatures
   freeze. The lease-based explicit scope adapter is more complex than only
   automatic scopes but preserves native diagnostic functionality safely.

These are recommendations, not recorded owner decisions. This research PR
closes the research task only; it neither authorizes implementation nor claims
that any of the proposed WebGPU API is already usable.
