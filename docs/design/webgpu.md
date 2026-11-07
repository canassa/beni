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
transfer, and typed transfers of bitmaps, video frames and binary backing wait
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
can import.

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

**What static dispatch reaches.** By
[`static-dispatch-spike.md`](static-dispatch-spike.md) §1.2, `x.m a` on a value
of nominal type `T` resolves only to a `pub` value of the module that declares
`T`, and an alias is looked through to what it names. A native handle's
declaring module is `Browser.Host.GPU<Name>`, which has no callable members; an
engine handle's declaring module is `Gpu.Handle`. Neither can hold the
operations: their signatures name `Gpu.Types` descriptors and `Gpu.Error` sums,
and their bodies call the engine, and all three import `Gpu.Handle`. So
**dot-call does not reach GPU operations**: `device.createBuffer desc` is
`unknown_method`. An operation is called qualified, or through the
receiver-first pipe, which §1.2 names as the way to reach a function the
type's module does not own:

```text
buffer = Gpu.Device.createBuffer device desc
buffer = device ▷ Gpu.Device.createBuffer desc
```

Forwarding methods in `Gpu.Handle` were considered and are not specified. They
are possible only for the few operations whose signatures name handles and
scalars alone (`destroy`, `queue`, `label`), so dot-call would work for some
members and not others; one rule is easier to teach than a partial one. No
language or module feature is added to move method ownership. `==` on a GPU
handle is `unknown_method`, as for every other host handle
(`static-dispatch-spike.md` §3.5); an identity `eq` would be a later, separate
decision.

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
named by slice S1.

### 2.3 Realms

All 41 exposure-annotated declarations of the pinned `webgpu.idl` are
`Exposed=(Window, Worker)`, and both `Navigator` and `WorkerNavigator` include
`NavigatorGPU`. Window-only types reach WebGPU only through HTML element arms:
`HTMLCanvasElement`, `HTMLVideoElement` and `HTMLImageElement` in
`GPUCopyExternalImageSource`, the external-texture source and
`GPUCanvasContext.canvas`.

Realm summaries are inferred ([`workers.md`](workers.md) §4, *How access is
proved*); no realm word is written. The engine reaches the host only through
`navigator.gpu`, a literal member read of the `navigator` global, which the
kept-code check allows in every worker realm, and through the native objects
it holds. It never reads `window` or `document`. Window-only operations
(`Gpu.Surface.fromElement`, element source constructors, the element arm of
`Gpu.Surface.canvas`) are separate declarations, so reachability drops them
from an entry that does not call them, and they are never stored in the same
nominal value as a portable callback (§4's conservative nominal join). Any
engine sibling obeys the same kept-code check, its lexical scopes and timers
included ([#2211](https://github.com/canassa/beni/issues/2211)). The headless
modules built by the main-thread slices therefore already carry summaries that
admit worker realms.

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
   Functions use saturated n-ary beni types, subject first. They are called
   qualified or with `▷`; dot-call does not reach them (§2.1).
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
and does not wait** (the owner, 2026-11-08, [#1270](https://github.com/canassa/beni/issues/1270)).
The rule is the same for a call from the session's own callback, from a fiber
the callback spawns or joins, and from an unrelated fiber. `Frame.submit`,
`Batch.run` and `Encode.run` are ordinary operations and follow it.

**No task identity.** The engine does not need to know which fiber calls
(there is no `Task.Identity`; [#1280](https://github.com/canassa/beni/issues/1280)
is closed). The lease is a per-device flag and a lease generation in the
engine's state table (§2.1). The authority to use a leased device is the
`DiagnosticSession` value: a token whose engine record names its device and the
lease generation it was issued under. A forwarding call checks that the
session's device is the target's device and that its generation is the live
one. An ordinary call carries no token, so it is refused.

**Why it cannot deadlock.** Nothing waits for a lease. An ordinary operation
refuses; `run` on a leased device refuses; a forwarding call holds the lease
already. With no wait for a lease there is no wait-for edge for a cycle to
close, also across devices: a session on device A that calls `run` on device B
gets B's lease at once or `DeviceLeased`, so no lock order is needed. The
remaining waits inside a session are GPU outcomes (scope pops, map and
pipeline promises), which the host settles without running beni code.

**Consequence.** During a session, other work on that device is refused, not
delayed. An application that runs a render loop while it diagnoses the same
device routes that work through the session or pauses it; the typed refusal
makes the conflict visible instead of silently serialising it. Making
unrelated fibers wait while the owner's calls are refused would need the engine
to know the calling fiber — a private fiber-scoped slot in core's fiber
runtime, which is a new core primitive and the owner's decision (§11, *Open*).

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

**Destruction and loss.** `Gpu.Device.destroy` is not refused under a lease;
it latches destroyed state as everywhere else (§8). Later forwarding calls in
the session return the device-loss outcome; the finalizer still invokes the
pops and releases the lease. Loss observed during a session does not end it
early.

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

Gpu.MappedRange.readBytes : MappedRange, Range → Result InputError Binary.Bytes
Gpu.MappedRange.writeBytes : MappedRange, Offset, Binary.Bytes → Result InputError ⊤
Gpu.MappedRange.readU32 : MappedRange, Offset → Result InputError U32
Gpu.MappedRange.writeF32 : MappedRange, Offset, Float → Result InputError ⊤
```

Mapped ranges access native mapped storage directly through typed reads/writes;
`readBytes` explicitly copies into persistent bytes. Include all numeric views,
bulk copies and exact bit access, not only the representative methods above.
Expose read/write modes, size and mapState. `mappedAtCreation` produces a mapping
handle without pretending `MAP_WRITE` was required (§7.1). Ranges track overlap,
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
and compute need no HTML view. DedicatedWorker support uses that realm's GPU
and typed transferables; GPU handles cannot be sent between workers. Worker
realms and `OffscreenCanvas` surfaces are the worker slice's, after #1299 (§2,
§10); the main-thread slices build the same modules without them.

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
  observed device loss wins, as for every wait. Nothing waits unless `done`
  is called, so a receipt does not stall a frame.
- `Gpu.Queue.onSubmittedWorkDone` stays the faithful native form: it captures
  at its own call, so it also covers unrelated work submitted before it. Use a
  receipt to wait for one submission.
- A receipt confirms validation observations and offers a completion wait;
  neither is display completion. A failed batch or frame publishes no
  receipts; its native submissions may still have happened (§6.3: a batch is
  not a transaction), and its failure report lists them as issued.

## 9. Reserved

The additional rendering abstraction was removed by the owner on 2026-10-30.
The section number is retained for existing references.

## 10. Verification and delivery plan

The contract is adopted (2026-11-08). Implementation lands in the slices
below, each with its own issue, a pull request, checked public API docs and
`skills/beni/` updated with `zig build skill-api` where it adds a shipped
surface. Delivery is main thread first (§2). Completeness is claimed only when
the entire inventory and the supporting adapters, worker realms included, are
delivered (S6 and the worker slice).

**Build first, optimize later** (the owner, 2026-11-01): S1–S5 carry no
benchmark and no byte budget; measurements belong to the performance slice.
One size fact stays, as a correctness check in every slice: **a program that
does not import `Gpu` ships zero GPU runtime**, so no `emit/` golden of an
existing fixture changes because of this work.

| Slice | Issue | Deliverable | Acceptance evidence |
|---|---|---|---|
| S1 foundation | [#2239](https://github.com/canassa/beni/issues/2239) | Generated `Browser.Host.GPU*` types, `Gpu.Types` and `Gpu.Flags` with the gated staleness check (§2.2); `Gpu.Handle` (§2.1), `Gpu.Scalar`, `Gpu.Error`; availability, adapter, device, `destroy`, loss latch; the checked-operation engine of §6.1 with the state table and the lease flag of §6.4; the `test-webgpu` runner | Generated-vs-IDL comparison of every descriptor, enum, flag and constant; conversion/default/null/overload tests; no `Js.Value` in public signatures; host fault injection for every S1 ledger row; interleaved fiber and cleanup tests; unexpected classes defect; `test-webgpu` reports adapter metadata and `passed`/`unsupported`/`skipped` |
| S2 compute and mapping | [#2240](https://github.com/canassa/beni/issues/2240) | Buffers, `map`/`withMapped`/`currentMapping` and mapped ranges (§7, §7.1), queue writes and receipts (§8.3), shader modules, compute pipelines and layouts, bind groups, command encoders, compute passes, copies, clears, queries, immediate data, `Gpu.Encode` (§6.2) and `Gpu.Batch` (§6.3) for these | Compute results read back and compared with independent expected answers; alignment, limit, usage and fixed-length-backing (§3.1) failures; the two `mappedAtCreation` cases of §7.1; exact u64 round trips |
| S3 render and presentation | [#2241](https://github.com/canassa/beni/issues/2241) | `Gpu.Surface` on a canvas element, configuration, `Gpu.Frame` with §8.2's batch bridge, render pipelines and passes, bundles, occlusion queries, indirect draws, the non-yielding host-turn section, direct and TEA program integration | Multi-pass, MSAA, depth/stencil, MRT and indirect scenes compared by read-back pixels; resize/reconfigure invalidation; same-task expiry adversaries; zero and multiple receipts (§8.3) |
| S4 diagnostics and events | [#2242](https://github.com/canassa/beni/issues/2242) | `Gpu.Diagnostics` (§6.4), its forwarding surface, uncaptured-error telemetry, `eachEvent`, `onEvent`, cancellation (§8.1) | `DeviceLeased` for an ordinary call from the callback, a joined child and an unrelated fiber, each without waiting; nesting; every cancellation and defect phase releases the lease; `ScopeUnderflow`; an escaped native error defects |
| S5 media sources | [#2243](https://github.com/canassa/beni/issues/2243) | External textures and `copyExternalImageToTexture` from every main-thread source arm, with #1278's sources | Every source arm compared by read-back pixels; closed, detached and not-origin-clean sources return their typed errors |
| S6 completeness audit | [#2244](https://github.com/canassa/beni/issues/2244) | Every inventory row tied to a public declaration and a behavioural fixture, or to its later slice; new-standard delta process | A gate fails for a row with neither; CTS-derived boundary cases and the native-vs-beni differential harness in `test-webgpu` |
| Later: workers | after [#1299](https://github.com/canassa/beni/issues/1299) | WebGPU in DedicatedWorker, SharedWorker and ServiceWorker realms; `OffscreenCanvas` transfer and surfaces; worker transfers of bitmaps, frames and binary | Worker entries run the S1–S5 scenarios; transfer detachment and typed transfer errors |
| Later: WGSL | [#1276](https://github.com/canassa/beni/issues/1276) | Built-in WGSL validation and minification | As that issue specifies |
| Later: performance | [#2245](https://github.com/canassa/beni/issues/2245) | Measurements and budgets | Below |

**The WebGPU runner.** The current browser harness commonly disables the GPU,
and happy-dom is not a WebGPU implementation: it is useful for canvas
mount/unmount and deterministic wrapper tests, **not evidence of GPU
correctness**. S1 adds `zig build test-webgpu`, an opt-in runner (not a gate)
in headless Chrome with a real WebGPU adapter. Chrome's software adapter
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
7–9 were taken the same day.

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
   functionality safely. Naming is as written here, with the call form of
   item 7.
7. **Decided 2026-11-08** ([#1281](https://github.com/canassa/beni/issues/1281)).
   The handle types live in one acyclic `Gpu.Handle` module; `Gpu.Types` and the
   operation modules import it; under option C the native handles are generated
   native types (§2.1). The consequence written into §2.1 is that operations are
   called qualified or with `▷`, not with dot-call.
8. **Decided 2026-11-08** ([#1270](https://github.com/canassa/beni/issues/1270)).
   An ordinary checked operation on a device whose diagnostic lease is held
   returns a typed session-state error immediately and does not wait. There is
   no `Task.Identity` ([#1280](https://github.com/canassa/beni/issues/1280)
   closed); the session value is the lease token (§6.4).
9. **Decided 2026-11-08.** Main thread first. WebGPU in workers and
   `OffscreenCanvas` transfer wait for
   [#1299](https://github.com/canassa/beni/issues/1299) and stay in the
   completeness scope as a later slice (§2, §10).

**Open for the owner.** These choices are written into the contract as stated
and await confirmation:

- §6.4 refuses **every** ordinary call on a leased device, not only the
  session owner's, because without task identity the engine cannot tell them
  apart. Letting unrelated fibers wait instead needs a private fiber-scoped
  slot in core's fiber runtime (a new core primitive).
- §2.1 specifies qualified calls and `▷` and no forwarding methods in
  `Gpu.Handle`. A hint on `unknown_method` for a GPU handle, naming the
  operation module, would be a separate compiler improvement.
