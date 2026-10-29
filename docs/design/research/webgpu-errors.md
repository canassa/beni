# WebGPU failure ledger

**Proposed binding contract, researched 2026-10-29.** Read with
[webgpu.md](../webgpu.md) §5–§8. Sources are pinned in
[sources.json](webgpu/sources.json); the [full IDL](webgpu/webgpu.idl) includes
all operations and conversion domains. This ledger covers the pinned standard,
not arbitrary errors that a future browser might add.

## 1. Classification rules

A classifier is attached to **one native call or one native promise**, after
beni has converted its inputs. It never surrounds application code, descriptor
construction, callbacks, unrelated conversions or an entire frame. A known
class is necessary but not sufficient: it must be documented for that operation
at that phase. Synchronous Web IDL failures and promise-returning operations'
IDL rejections are both considered.

Use the realm's genuine native class/prototype checks for GPU errors and
pipeline errors. For DOM exceptions require a native DOMException and its
documented `name`. Platform handles originate in the owning realm; a moved
source is rewrapped in the destination realm. A plain object with a matching
`name` is not a native failure. Do not rely on `constructor.name`, English
message matching, or an exception name alone where a stronger check exists.

Preflight validates finite/integer numeric ranges, flags and known feature
gates; it uses current negotiated device capabilities. Closed enums and typed
descriptors prevent unrepresentable argument shapes. The wrapper should not
catch a host `TypeError` for a shape its converter guarantees: that is a defect
in conversion or the host. A residual documented feature/IDL failure can be a
typed error only where the ledger explicitly retains that path. Promise
rejections are classified separately from errors thrown by success callbacks.

All rows inherit the shared rules below:

| Source | Detection / returned value |
|---|---|
| Preflight numeric failure | `InvalidInput (NumericDomain path expected actual)`; no host call |
| Unsupported required native member/feature | `UnsupportedCapability capability`; do not let an absent method become a caught `TypeError` |
| Invalid/expired handle, wrong device, invalid wrapper state | Specific `InvalidInput` variant before native use; shared alias state is authoritative for wrapper actions |
| `GPUValidationError` from a scope | `Validation { boundary, message }`; no parsing the localized message |
| `GPUOutOfMemoryError` from a scope | `OutOfMemory { boundary, message }` |
| `GPUInternalError` from a scope | `Internal { boundary, message }`, a known failure class |
| Known device loss observation | `DeviceLost { reason = UnknownLoss or Destroyed, message }` and a latched lifecycle event |
| Other subtype/enum value, throw or rejection | Defect preserving cause, operation and labels; never a generic typed fallback |

Every operation that can generate a GPU error is scoped, including errors
deferred to encoder `finish` or queue `submit`. Empty marker interfaces,
immutable getters and debug labels still appear in coverage; their absence of
a GPU-error algorithm does not permit swallowing exceptions from them.

## 2. Initialization and feature negotiation

| Native API / source | Documented observation and exact policy |
|---|---|
| `navigator.gpu` / worker equivalent | Check secure context and member availability. `InsecureContext` or `ApiUnavailable`. Never construct a reference to a missing global |
| `GPU.requestAdapter` | Null → `AdapterUnavailable` without invented cause. Validate requested feature level and options. No normal native rejection is specified after conversion in this baseline; a non-IDL rejection is a defect |
| `GPU.getPreferredCanvasFormat`, WGSL feature set | Valid value/snapshot. Unknown returned enum → defect. Unknown *feature names in an extensible reported set* stay names; querying a name is total |
| `GPUAdapter.requestDevice`: required features | Preflight unsupported/unknown feature names → `UnsupportedFeatures names`. A native `TypeError` rejection at this call is documented for feature refusal; retain `FeatureRequestRejected { requested, message }` if it cannot be more narrowly attributed. Do not catch other `TypeError`s in application initialization |
| `GPUAdapter.requestDevice`: required limits / consumed adapter | Track adapter consumption and concurrent request reservation, validate known names and the correct better/worse direction plus alignment powers of two. Known failures → `AdapterConsumed` or `UnsupportedLimits details`. Native DOM `OperationError` → `DeviceRequestRejected message` when exact reason is not observable. Failed requests release reservation; successful requests consume the adapter |
| `requestDevice` resolves an already-lost device | Install loss handling before exposing the handle; observe the loss state. The resolved value alone is not healthy-device proof. If loss has not yet been delivered, the device remains subject to later notification |
| `GPUDevice.destroy` | Intentional, idempotent teardown; latch wrapper destroyed state immediately, wake waiters, retain later `lost` reason. No normal native exception |

Sources: WebGPU [initialization](https://gpuweb.github.io/gpuweb/#initialization),
[optional capabilities](https://gpuweb.github.io/gpuweb/#optional-capabilities)
and [feature detection](https://gpuweb.github.io/gpuweb/#feature-detection).
Unknown dictionary members may be ignored by a browser. Optional canvas members
therefore use their specified `getConfiguration` detection; method presence
and GPU/WGSL features use their own specified checks.

## 3. Resources, shaders and pipelines

| Native API | Documented observation and policy beyond shared rules |
|---|---|
| `createBuffer` | Descriptor preflight plus GPU validation/OOM scopes. With `mappedAtCreation`, native `RangeError` for the CPU-side mapped allocation → `MappedAllocationFailed { bytes, message }`. It is not a `GPUOutOfMemoryError` |
| `createTexture`, `Texture.createView` | Validate enum/format feature requirements before native call; GPU validation/OOM as specified. Feature-gated format checks can throw `TypeError`; map only the native format-check path documented for that call, to `FormatFeatureRejected { format, required, message }`. A failure despite fully verified feature conversion with no remaining documented condition is a defect |
| `createSampler`, `createBindGroupLayout`, `createBindGroup`, `createPipelineLayout`, `createQuerySet` | Typed descriptors, resource/device checks, full relevant GPU scopes. Layout alternatives and binding resource unions are typed. No invented DOM exception paths |
| `createShaderModule` | GPU validation scope reports invalid WGSL/module requirements. `getCompilationInfo` messages are returned too; no error strings are thrown to the application. Hints and auto/explicit pipeline layouts retain their full descriptor fields |
| `ShaderModule.getCompilationInfo` | Resolve to all reported messages, preserving type, message, lineNum, linePos, offset, length. No ordinary rejection is specified. A rejection is a defect |
| `createComputePipeline`, `createRenderPipeline` | Native synchronous creation has GPU validation/internal failure paths, plus content-timeline feature checks where specified. Beni's checked return waits for scope results, so it may suspend despite the native method being synchronous |
| `createComputePipelineAsync`, `createRenderPipelineAsync` | Native `GPUPipelineError` with reason `validation` → `PipelineValidation`; reason `internal` → `PipelineInternal`. Retain native message and requested entry points. Unknown reason/class → defect. Pipeline validation failures are captured by these promises rather than usual GPU error dispatch. Feature/IDL conversion paths remain per-operation. A resolved pipeline on a lost device is subject to the latched loss contract |
| Pipeline `getBindGroupLayout` | Bounds and device checks; GPU validation scope. A returned invalid layout never becomes a checked usable handle |
| Resource getters, `label`, buffer/texture/query destruction | Read typed snapshots or mutate shared lifecycle state. Destroy/unmap may invalidate queued uses; later wrapper calls see the state. No generic exception mapping |

Sources: WebGPU [buffers](https://gpuweb.github.io/gpuweb/#buffers),
[textures](https://gpuweb.github.io/gpuweb/#textures),
[shaders](https://gpuweb.github.io/gpuweb/#shader-modules) and
[pipelines](https://gpuweb.github.io/gpuweb/#pipelines).

## 4. Mapping and binary sources

| Native API | Documented observation and policy beyond shared rules |
|---|---|
| `Buffer.mapAsync` | Validate map mode (read or write), state, usages, 8-byte offset and 4-byte size alignment, bounds. A DOM `OperationError` rejection → `MapRejected message` if a more precise preflight error was unavailable; also drain the GPU scope. DOM `AbortError` → `MapAborted` unless observed device loss supplies the precise loss cause. CPU backing allocation's native `RangeError` rejection → `MappedAllocationFailed`. Cancellation caused by the waiting beni fiber stays fiber cancellation, with native promise drainage |
| `Buffer.getMappedRange` | Preflight active mapping, bounds/alignment, overlap with active ranges. DOM `OperationError` at exactly this call → `MappedRangeRejected message`. This call does **not** allocate new backing storage: do not invent an allocation `RangeError` path |
| `Buffer.unmap` / `destroy` while map pending | Pending native map rejects with `AbortError`; mark shared wrapper state before native call. Every alias and range is invalidated. Idempotent cleanup; no use after detachment |
| Use of mapped ArrayBuffer outside allowed access | WebGPU forbids transfer/detach operations except unmap, causing `TypeError`. The public mapped-range API offers neither operation. Its occurrence inside a wrapper is a defect, not a normal range error |
| `AllowSharedBufferSource` conversion | Preserve the actual source variant, element type, view offset and byte length. Detached/resized/out-of-bounds views have typed preflight errors. Shared backing requires typed shared handles and applicable host isolation; no raw JS escape. Unexpected converter failure → defect |
| Safe CPU binary encoders | Return explicit range/value/size errors; preserve f16/f32/integer bit patterns and raw bytes. Any new host allocation primitive has its own narrowly documented allocation classifier, outside the GPU-error classifier |

Source: WebGPU [buffer mapping](https://gpuweb.github.io/gpuweb/#buffer-mapping)
and [Web IDL buffer sources](https://webidl.spec.whatwg.org/#BufferSource).
The binary-source adapters must enumerate the concrete view kinds and their
imported algorithms during implementation; each adapter is a shipping prerequisite.

## 5. Encoders, passes, queue and queries

| Native API | Documented observation and policy beyond shared rules |
|---|---|
| `createCommandEncoder`, `beginComputePass`, `beginRenderPass`, `createRenderBundleEncoder` | Check lifecycle and descriptors, including feature-gated attachment formats. Scope the native calls. Encoder state belongs to shared runtime state, not unchecked phantom types |
| `setBindGroup` sequence overload | Check binding/device and dynamic offset domains; GPU validation remains authoritative |
| `setBindGroup` typed-array slice overload | Native `RangeError` if start + length exceeds the array; preflight → `DynamicOffsetSliceOutOfBounds`. Retain only this native call's documented residual `RangeError` mapping, never array allocation/user callback errors |
| `setImmediates` | Source element/byte ranges and multiple-of-four content size → `ImmediateSourceRange` preflight; documented native DOM `OperationError` at this call → `ImmediateWriteRejected message`. GPU range alignment/layout/capability validation is scoped |
| Set pipeline/index/vertex buffers, viewport/scissor/blend/stencil, direct/indexed/indirect draws, dispatches | Typed finite/range values and lifecycle checks. All GPU validation captured for the encoding segment, including usage-scope conflicts, limits, indirect alignment and missing state. Debug groups/markers are also covered |
| Copy buffer/texture commands; `clearBuffer`; `resolveQuerySet` | Typed source/destination/ranges/layouts; GPU validation and resource-state checks. Row alignment rules are per operation: encoder buffer-texture copies require 256-byte row alignment where specified; queue writes do not inherit that blanket rule |
| Occlusion begin/end; timestamp writes in pass descriptors | Feature/query index/state preflight and host validation. No invented `writeTimestamp` method: it is not in the pinned IDL. Exact query results remain u64 bytes/two-word values |
| Pass `end`, bundle/command `finish` | Capture deferred validation too. Failed encoder state invalidates produced wrapper handles, even if a native object was returned. Debug stacks and active queries must close correctly |
| `executeBundles` | Native behavior clears pipeline, binding, immediate and vertex/index state after execution. Wrapper shadow state must clear it too; it is not restored |
| `Queue.submit` | Check duplicates, single-use command buffers, mapped/destroyed resources and device identity; native submit validation is scoped. A successful encode is not a successful submit. Failure does not imply rollback of preceding writes or other submitted buffers |
| `Queue.writeBuffer` | Source content range and byte length multiple of four preflight. Documented DOM `OperationError` → `BufferWriteSourceRejected message`; destination availability/usage/alignment/bounds produce GPU validation. Preserve typed-array element-offset semantics |
| `Queue.writeTexture` | Correct copy/source layouts, extents, usages, texel blocks and feature rules; GPU errors scoped. No generic `OperationError` branch copied from writeBuffer |
| `Queue.onSubmittedWorkDone` | Completion of prior queue work, not general semantic correctness. No normal rejection in this baseline; rejection → defect. Known device loss separately wins a pending wrapper wait |

Sources: WebGPU [command encoding](https://gpuweb.github.io/gpuweb/#command-encoding),
[programmable passes](https://gpuweb.github.io/gpuweb/#programmable-passes),
[queue](https://gpuweb.github.io/gpuweb/#gpuqueue) and
[queries](https://gpuweb.github.io/gpuweb/#queries).

## 6. External images, canvas and workers

| Native API | Documented observation and policy beyond shared rules |
|---|---|
| `importExternalTexture` | Native DOM `SecurityError` → `SourceNotOriginClean`. Imported HTML usability DOM `InvalidStateError` → `SourceUnusable message`. A bad-but-nonthrowing usability result instead generates GPU validation. Video-element imports are task-lived; frame imports follow source-close lifetime |
| `copyExternalImageToTexture` | `SecurityError` → `SourceNotOriginClean`; source/copy bounds DOM `OperationError` → `ExternalImageCopyRangeRejected message`; imported HTML usability `InvalidStateError` → `SourceUnusable message`; remaining device-side restrictions → scoped GPU validation. These predicates apply only to this native call |
| HTML canvas `getContext("webgpu")` | Typed element lookup and kind checks; null → `CanvasContextUnavailable` (including an incompatible existing context). No invented reason for null. Fixed valid context identifier removes string conversion uncertainty |
| Canvas `configure` | Feature-gated format, supported canvas format, forbidden transient usage and typed descriptor checks. The specified native `TypeError` paths → `CanvasConfigurationRejected message` when not settled preflight; device-timeline texture validation also scoped. Do not claim a failing configure rolled back its configuration side effects |
| Canvas `getCurrentTexture` | Unconfigured context DOM `InvalidStateError` → `CanvasUnconfigured`; native texture creation can generate GPU validation/OOM. Acquire/encode/submit synchronously in a managed frame, then wait |
| Canvas `unconfigure`, `getConfiguration`, `.canvas` | Preserve nullable configuration and actual canvas kind. Invalidate outstanding frame generations on unconfigure/reconfigure/resize/presentation; no invented ordinary exception paths |
| Supporting OffscreenCanvas construction and transfer | New supporting API must classify constructor/conversion failures and `transferControlToOffscreen` DOM `InvalidStateError` individually. Canvas size changes and typed worker transfer must invalidate source handles; GPU objects themselves are not transferable. This is supporting API work, not an additional GPU method |
| Supporting image/video handles and transfers | All seven standard copy-source variants and both external-texture variants must be constructible through typed browser APIs. Loading, decoding, source-close and structured-clone failures belong to their specific host wrappers, and must be specified/tested there before the integration ships |

Sources: [external texture import](https://gpuweb.github.io/gpuweb/#dom-gpudevice-importexternaltexture),
[external image copy](https://gpuweb.github.io/gpuweb/#dom-gpuqueue-copyexternalimagetotexture),
[canvas](https://gpuweb.github.io/gpuweb/#gpucanvascontext),
[HTML image sources](https://html.spec.whatwg.org/multipage/canvas.html#image-sources-for-2d-rendering-contexts),
and [OffscreenCanvas](https://html.spec.whatwg.org/multipage/canvas.html#the-offscreencanvas-interface).

## 7. Scopes, lifecycle and deliberately unexpected paths

| Native API / observation | Policy |
|---|---|
| `pushErrorScope` | Closed filter enum; called inside a non-suspending stack section. Unexpected throw → defect; balance every successfully pushed scope in a finalizer |
| `popErrorScope` | Null is no reported GPU error, not proof of no device loss. A native DOM `OperationError` for an empty *explicit managed diagnostic stack* → `ScopeUnderflow`. Underflow in an automatic wrapper-owned scope is a beni defect, because user code cannot unbalance that stack |
| Scope returns GPU error | Match exact known class; retain representative for that filter/segment. Do not claim every error or first failing instruction is known |
| Scope promise rejects unexpectedly | Defect. Drain the other scope promises without replacing the original defect |
| `device.lost` | Promise resolves once, with known enum reason. Defined reason `unknown` → `UnknownLoss`; a new string → defect. Unexpected rejection → defect |
| `uncapturederror` | Decode to the typed device event. If a wrapper-owned operation escaped its required scopes, report a defect with the decoded error. Do not present optional event delivery as guaranteed detection |
| Synthetic error/event constructors | Pure beni error/event values provide construction and serialization. Constructing an error does not dispatch it to the GPU; test injection stays internal. Native DOM inherited properties needed for diagnostics remain metadata, not application FFI |
| Any failure in an application callback | Let it reach the normal beni defect boundary. The GPU host classifier must not relabel it, even if it is a `TypeError` or DOM exception |

Source: WebGPU [errors and debugging](https://gpuweb.github.io/gpuweb/#errors-and-debugging).
The implementation acceptance rule is operation × phase × documented class,
plus a hostile test with a same-named fake and an unexpected native class for
every classifier. A blanket `catch`, blanket `.catch`, or `UnknownError` result
fails review even if all ordinary rendering examples pass.
