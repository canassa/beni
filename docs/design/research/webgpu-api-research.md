# WebGPU: complete coverage and a precise failure boundary

**Research, 2026-10-29; [#1257](https://github.com/canassa/beni/issues/1257).**
The owner asks for an API inspired by Elm WebGL, covering all of WebGPU, with
documented failures returned as typed errors and unrecognized failures treated
as beni defects. No runtime is implemented here. The proposed contract is
[webgpu.md](../webgpu.md); the [source collection](webgpu/README.md) contains
pins, hashes, extracted IDL and the complete coverage checklist.

## 1. What was inspected

The primary API source is the [WebGPU specification](https://www.w3.org/TR/2026/CRD-webgpu-20260915/),
including initialization, optional capabilities, every resource and encoding
interface, copies, canvas integration, errors, feature definitions, format tables,
and its WebIDL index. The [editor source](https://github.com/gpuweb/gpuweb/blob/a1a1e79f35f93ad6db255dc170621ae7e411eba0/spec/index.bs)
and [copy section](https://github.com/gpuweb/gpuweb/blob/a1a1e79f35f93ad6db255dc170621ae7e411eba0/spec/sections/copies.bs)
were read directly. Comparing IDL declarations against the published HTML found
the same members and values, with feature enum ordering different. These are
not assumed to be identical prose revisions.

The source includes **36 interfaces, 7 mixins, 3 partial interface blocks,
62 dictionaries, 34 enums, 5 constant namespaces and 25 typedefs**, plus 37
`includes` declarations. These counts describe source constructs, not browser
availability or completed wrappers. The generated [inventory](webgpu/coverage.md)
retains empty marker interfaces, inherited members, both `setBindGroup`
overloads, all optional members and nullable slots.

Shader research used [WGSL](https://www.w3.org/TR/2026/CRD-WGSL-20261026/),
especially lifecycle/errors, directives/extensions, scalar and buffer types,
host-shareable layout, uniformity, builtins and memory behavior. Host failure
research follows the imported [Web IDL conversions](https://webidl.spec.whatwg.org/#js-type-mapping)
and HTML's [image usability algorithm](https://html.spec.whatwg.org/multipage/canvas.html#check-the-usability-of-the-image-argument).
Those imported algorithms are necessary: searching only for `throw` in WebGPU
misses documented failures.

Elm inspection covers the actual [WebGL module](https://github.com/elm-explorations/webgl/blob/a9a483b8d29205b1544e736607d72fe931f58958/src/WebGL.elm),
[texture module](https://github.com/elm-explorations/webgl/blob/a9a483b8d29205b1544e736607d72fe931f58958/src/WebGL/Texture.elm),
[rendering kernel](https://github.com/elm-explorations/webgl/blob/a9a483b8d29205b1544e736607d72fe931f58958/src/Elm/Kernel/WebGL.js)
and [texture kernel](https://github.com/elm-explorations/webgl/blob/a9a483b8d29205b1544e736607d72fe931f58958/src/Elm/Kernel/Texture.js)
at release 1.1.3. The [WebGPU CTS](https://gpuweb.github.io/cts/) supplies the
conformance model; its [error-scope cases](https://github.com/gpuweb/cts/blob/d116bcccd1833369fa3715a6df503c0dd9b0d7fa/src/webgpu/api/validation/error_scope.spec.ts)
and [capability tables](https://github.com/gpuweb/cts/blob/d116bcccd1833369fa3715a6df503c0dd9b0d7fa/src/webgpu/capability_info.ts)
were inspected as independent implementation-oriented evidence. No CTS execution
or browser experiment was performed in this research task.

## 2. What Elm gets right, and what cannot be copied

Elm separates immutable `Mesh attributes`, typed `Shader attributes uniforms
varyings`, an existential `Entity`, render settings, and `toHtml`/`toHtmlWith`.
A draw is described as data. Callers retain a mesh rather than regenerate it
in `view`; the kernel caches mesh buffers and shader programs by identity.
`entityWith` isolates depth, blending, stencil and other render settings.
The `[glsl| … |]` literal is compiler support: typing shader interfaces is not
an ordinary Elm library trick. This is the inspiration for beni's optional
typed mesh/layout and entity layer, not a reason to require GLSL or new beni
syntax in the first implementation.

Elm's texture loader returns `Task Error Texture`, with `LoadError` and
`SizeError width height`; filtering/wrapping options are typed, including
phantom types distinguishing magnification and minification filters. The
kernel's size rule reflects WebGL's non-power-of-two constraints. WebGPU has
different texture rules, formats, usages and feature gates: those constraints
must come from WebGPU, not from this Elm API.

The rendering kernel throws strings for shader compilation and program linking
failures. It also has a canvas fallback when context creation fails. Neither
behavior meets beni's requested error contract. Shader diagnostics, pipeline
failures, unsupported APIs, context selection failures and device loss must be
values at a defined boundary, not console output, thrown strings, or a blank
canvas. Elm's API also does not expose WebGPU's compute, storage buffers,
bind-group layouts, command buffers, indirect calls, queries, explicit copies,
mapping or resource lifetimes. A mesh/entity-only API cannot be complete.

## 3. The programming model that determines the API

WebGPU has separate **content**, **device** and **queue** timelines. A method
returning a JavaScript object is not proof that the internal GPU object is
valid. Invalid objects can contaminate later commands. Error scope completion
observes validation; queue completion observes submitted work. Neither is a
general proof that an arbitrary shader computed the intended answer.
[WebGPU §3.2–§3.4](https://gpuweb.github.io/gpuweb/#asynchrony) owns this distinction.

The normal path is adapter selection → negotiated device → resources and
layouts → shaders and pipelines → encoding → queue submission. Buffers need
explicit usages and optional mapping; textures need dimensions, mip levels,
sample counts, views and format capabilities. Render and compute passes share
binding/debug commands but have different valid states. Render bundles are
reusable encoded rendering, while command buffers are single-submit. Submit
validation must account for resource destruction and buffer mapping at submit
time, not only at encode time.

Compatibility mode is in this baseline. `featureLevel` selects the requested
adapter level, and `core-features-and-limits` determines whether core restrictions
apply on the device. Adapter limits are capabilities, while the **negotiated
device limits** are the validation contract. Alignment limits have the reverse
ordering of maximum limits. Optional feature dependencies are also normative;
requesting an advanced feature can enable prerequisites. A wrapper must not
assume `device.features` equals just the application's list.
[WebGPU §3.6 and §4](https://gpuweb.github.io/gpuweb/#optional-capabilities).

The complete API includes 25 feature names, 36 limit attributes, transient
attachments, texture view usage and swizzle, immediate data and layout size,
subgroup features, texture-format tiers, compressed 3D textures and all WGSL
capabilities in the pinned language. Some browsers may not expose every item.
The wrapper needs runtime detection of methods, enum values where necessary,
and dictionary members with their specified detection mechanisms; unknown
dictionary members can be silently ignored by Web IDL. Native calls alone
cannot prove that an optional requested behavior took effect.
[WebGPU feature detection](https://gpuweb.github.io/gpuweb/#feature-detection).

Extension documents outside the specification are explicitly non-normative.
The current WebGPU text says conforming implementations must not expose their
functionality until integrated. “100%” therefore means the complete pinned
standard, including optional standard features, not every future proposal,
Dawn/wgpu native extension, or vendor experiment.
[WebGPU §3.8](https://gpuweb.github.io/gpuweb/#extension-documents).

## 4. Failure channels and what each can tell us

| Channel | What can be detected | Consequence for beni |
|---|---|---|
| API absence / null adapter / null context | Availability, secure context, inability to select an adapter/context | Typed availability errors; a null adapter does not reveal why selection failed |
| Web IDL conversion and feature checks | Wrong numeric domain, nonfinite restricted floats, invalid enum/sequence shape, disabled enum/format | Typed constructors and preflight before host invocation; no global `TypeError` catch |
| Documented synchronous exceptions | Mapping ranges, buffer allocation, source ranges, external-image security/usability, canvas state | Per-operation classifier, retaining the documented exception's actual information |
| Promise rejection | Device request, mapping, async pipeline creation, empty error scope | Per-operation rejection allowlist, never a blanket rejection handler |
| GPU error scope | `GPUValidationError`, `GPUOutOfMemoryError`, `GPUInternalError` | Exact variants plus operation/segment metadata; complete validation remains the host's job |
| Compilation info | Error/warning/info messages with source coordinates | Typed diagnostics; warnings survive successful compilation |
| `device.lost` | Documented `unknown` or `destroyed` reason and message | Persistent lifecycle state and typed notification; recovery reacquires an adapter |
| `uncapturederror` | Optional/throttled telemetry for errors outside scopes | Typed event and defect for a wrapper-owned scope escape; never the primary detection mechanism |
| Any other throw/rejection/error variant | Wrapper, runtime or host contract defect | Preserve cause and enter beni's defect path; never `UnknownError` in `Result` |

This table is a channel map. The [error ledger](webgpu-errors.md) specifies the
individual operations and predicates. GPU validation errors intentionally have
only a class and human-readable, possibly localized message; parsing strings
to invent `BufferTooSmall` or `BindingMismatch` would be unsound. Stable local
preflight findings may carry that detail, but opaque host validation must stay
an honest `Validation` value. `GPUInternalError` is a defined GPU failure;
its name does not make it an unexpected beni defect.
[WebGPU errors](https://gpuweb.github.io/gpuweb/#errors-and-debugging).

### 4.1 Scopes are device-global, not fiber-local

Push/pop operate on a per-device stack. Suspending between pushes and pops lets
unrelated fibers interleave their stacks. An async mutex around everything can
prevent that, but also serializes pipelines/resources unnecessarily, and a
single-filter scope misses the other two classes. A managed operation must push
all three filters, issue its host calls, **invoke all pops synchronously in
reverse order**, and only then wait for the returned promises. No user callback,
fiber yield or cancellation point may divide that critical section.

The async pipeline methods report their failures through `GPUPipelineError`
instead of dispatching the usual GPU errors. Their promise belongs to that
operation; it is not evidence that scopes around arbitrary later async work
will capture it. Mapping can have both a rejected promise and a GPU validation
error. Both channels must be drained and associated with the same call.
[Pipeline creation](https://gpuweb.github.io/gpuweb/#async-pipeline-creation)
and [error scopes](https://gpuweb.github.io/gpuweb/#error-scopes).

### 4.2 Literal “every error” has a specification limit

`popErrorScope` resolves to **any one** error seen by that scope, not a complete
list and not necessarily the first. `uncapturederror` delivery can be throttled
or omitted. After device loss, scopes return null and many operations appear
to succeed; the loss promise reports the lifecycle change. A wrapper cannot
reconstruct errors the browser did not report.

WGSL also defines dynamic errors, such as some shader data races, that may be
undetectable. Their consequences are bounded by WGSL's memory rules, but they
need not produce a host error. A complete WGSL API cannot promise a typed error
for each such event. CPU process termination or a browser/GPU crash that leaves
no callback has the same observability boundary.
[WGSL §2.2](https://www.w3.org/TR/2026/CRD-WGSL-20261026/#errors).

The proposal therefore guarantees: expose every specified capability; detect
every documented observable failure channel; return each reported expected
failure precisely; never turn a suppressed error into fabricated success about
GPU execution; treat an unrecognized observation as a defect. It explicitly
does not claim to enumerate every hidden error or validate the semantics of
arbitrary WGSL. If the requirement literally includes undetectable shader
errors, full WGSL support and that requirement cannot both be satisfied by a
WebGPU wrapper. This is a specification constraint, not an implementation shortcut.

## 5. Details that would otherwise become holes

**External images.** `copyExternalImageToTexture` accepts seven source kinds:
ImageBitmap, ImageData, HTMLImageElement, HTMLVideoElement, VideoFrame,
HTMLCanvasElement and OffscreenCanvas. `importExternalTexture` accepts video
elements and VideoFrames. Security errors originate in origin-clean checks;
the imported HTML algorithm can throw `InvalidStateError` for broken images,
zero-size canvases or detached bitmaps/frames. A not-yet-ready video can instead
produce GPU validation. Workers cannot use Window-only element types, but can
use transferable images/frames and OffscreenCanvas.
[Copy definitions](https://gpuweb.github.io/gpuweb/#dom-gpuqueue-copyexternalimagetotexture).

**Frame lifetime.** A video-element external texture expires by an automatic
expiry task; VideoFrame imports expire when their source is closed. Current
canvas textures are invalidated by presentation, resizing and reconfiguration.
Awaiting validation before submitting a just-acquired canvas/video texture can
cross the task boundary that makes it unusable. Acquire/import, encode and
submit must be possible in one synchronous host turn, with checked completion
afterward. A persistent user texture may still be rendered offscreen and copied.
[External textures](https://gpuweb.github.io/gpuweb/#gpuexternaltexture)
and [canvas integration](https://gpuweb.github.io/gpuweb/#canvas-context).

**Bytes and integer precision.** The repo has `Int32` but no general Bytes,
typed-array, VideoFrame, ImageBitmap or OffscreenCanvas API. Returning arbitrary
JavaScript values would violate the boundary. These typed supporting handles
are part of WebGPU delivery, not deferred to application FFI. Binary transfers
need byte offsets distinct from typed-array element offsets, shared-memory
variants, detachment checks and scoped mapped memory. Query results are 64-bit
integers; a JavaScript-number conversion loses bits above 2⁵³. Preserve raw
bytes and expose exact two-word unsigned values. GPUSize64 inputs remain the
Web IDL Number domain; a wrapper must not silently round a larger exact integer.

**WGSL layout.** A generic beni record is not a GPU struct. Vec3 alignment,
matrix columns, array stride, runtime arrays, uniform-specific constraints,
f16 and explicit member size/alignment must have typed byte encoders or raw
byte access. Dynamic WGSL and explicit layouts remain available so the
convenience layer never becomes a gate on language features.
[WGSL memory layout](https://www.w3.org/TR/2026/CRD-WGSL-20261026/#memory-layouts).

**Diagnostics.** WebGPU line/column values are one-based while offsets/lengths
are zero-based UTF-16 code units; beni uses code-point columns. Keep the original
positions and expose a conversion with the original source. “0” can mean an
unavailable location. Do not present unconverted UTF-16 positions as beni columns.
[Compilation messages](https://gpuweb.github.io/gpuweb/#gpucompilationmessage).

**No completion invention.** `onSubmittedWorkDone` in the inspected baseline
has no specified ordinary rejection path; a rejection is a defect, not a made-up
`QueueFailed`. Device loss is separately observed. Cancellation does not undo
queue submissions or native async pipeline compilation; a canceled wrapper
still drains outstanding promises and releases abandoned owned resources.

## 6. Fit with beni and resulting recommendation

Ship browser-owned `Gpu.*` modules, available through the shipped browser
platform layers, with ordinary direct `Result` functions and inferred effects.
Use `Task` for waiting/cancellation/finalization. Keep implementation in beni
over `Js`, with typed foreign handles where necessary and only the minimum
host primitives. There is no reason for the compiler to know render pipelines
or for ordinary modules to import `Js`. UI views remain pure; resource creation
and rendering execute as effects, and TEA users send typed outcomes from commands.
This follows [boundary.md](../boundary.md) §4/§9 and its precise-error rule.

The complete layer mirrors WebGPU with typed descriptors and safe lifetimes.
On top, an optional Elm-inspired layer provides reusable typed meshes,
layouts, entities and a managed canvas. It lowers to the same checked engine;
compute and expert rendering use the foundation directly. Do not add a second
WebGPU implementation or a separate shader language to make the first triangle
convenient. Static WGSL checking and shader-derived beni interfaces are useful
later work, not prerequisites for full host API coverage.

The decision to adopt the proposed API remains the owner's. Measurements are
owed during implementation: scope overhead, per-frame allocation, native vs
beni encode cost, transfer copies, startup, and output bytes. None has been
measured or used here to claim performance parity.
