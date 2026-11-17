# WebGPU

The `browser` platform has the `Gpu` modules. `browser-tea` re-exports them. They give the
browser's WebGPU API with types. Only the main thread has them now.

## What exists now

- `Gpu`: `available`, `requestAdapter`, `preferredCanvasFormat`, `wgslLanguageFeatures`.
- `Gpu.Adapter`: `features`, `limits`, `info`, `requestDevice`.
- `Gpu.Device`: `features`, `limits`, `adapterInfo`, `queue`, `label`, `setLabel`, `destroy`, `loss`,
  `awaitLost`, and the checked operations `createSampler`, `createBuffer`, `createMappedBuffer`,
  `createTexture`, `createBindGroupLayout`, `createBindGroup`, `createPipelineLayout`, `createShaderModule`,
  `createComputePipeline`, `createComputePipelineAsync`, `createRenderPipeline`,
  `createRenderPipelineAsync` and `createQuerySet`.
- `Gpu.Buffer`: `size`, `usage`, `mapState`, `label`, `setLabel`, `map`, `currentMapping`,
  `getMappedRange`, `withMapped`, `unmap`, `destroy`, and the mapping's `mappingMode`,
  `mappingRange`, `mappingBuffer` and `mappingLive`.
- `Gpu.MappedRange`: reads and writes of mapped memory: `readU8` to `readF64`, `readF16`,
  `readWord64`, the `write` forms, `readBytes` (a copy) and `writeBytes`. `region` and
  `readRegion` give the range as a `Binary.Region` that is checked once; after the mapping
  ends, it gives `Detached`.
- `Gpu.Queue`: `writeBuffer`, `writeTexture`, `submit`, `onSubmittedWorkDone`, `label`, `setLabel`.
- `Gpu.Shader`: `getCompilationInfo`, `compile`, `source`. `Gpu.ComputePipeline`:
  `getBindGroupLayout`. `Gpu.Texture`: snapshots (`dimension` and `textureBindingViewDimension`
  too), `createView` and `destroy`. `Gpu.QuerySet`: snapshots and `destroy`.
- `Gpu.TextureView`, `Gpu.RenderBundle`, `Gpu.Sampler`, `Gpu.BindGroupLayout`, `Gpu.BindGroup`,
  `Gpu.PipelineLayout`, `Gpu.CommandBuffer`: `label`, `setLabel`. Each pass has them too.
- `Gpu.RenderPipeline`: `label`, `setLabel`, `getBindGroupLayout`.
- `Gpu.RenderPass`: the commands of a render pass: `with`, `end`, `setPipeline`,
  `setBindGroup`, `setVertexBuffer`, `setIndexBuffer`, `draw`, `drawIndexed`, `drawIndirect`,
  `drawIndexedIndirect`, `setViewport`, `setScissorRect`, `setBlendConstant`,
  `setStencilReference`, `beginOcclusionQuery`, `endOcclusionQuery`, `executeBundles` and the
  others. `Gpu.RenderBundleEncoder`: the same draw commands and `finish`.
- `Gpu.Encode.run`: encode commands. `Gpu.Encode.bundle`: encode a render bundle.
  `Gpu.CommandEncoder` has `beginRenderPass` and `beginComputePass`. `Gpu.CommandEncoder` and
  `Gpu.ComputePass` have the commands: copies, `clearBuffer`, `resolveQuerySet`, debug groups, `setPipeline`,
  `setBindGroup`, `dispatchWorkgroups`, `setImmediates` and the others.
- `Gpu.Batch`: many synchronous operations, checked together.
- `Gpu.Submission`: `done`, which waits for the work of one submit.
- `Gpu.Types`: one record for each IDL dictionary, one type for each IDL enum, one sum for each
  IDL union. These are generated from the pinned IDL.
- `Gpu.Flags`: the five flag domains. A buffer usage set is not a texture usage set.
- `Gpu.Limits`, `Gpu.Feature`, `Gpu.WgslFeature`: snapshots that the host reports. A limit
  that some browsers do not report yet is `Maybe Int`, and `Gpu.Limits.limit` gives `Maybe Int`.
- `Gpu.Scalar`: `U32`, `I32`, `Size64`, `FiniteF32`, `FiniteF64`.
- `Gpu.Error`: `InitError`, `Error` and their parts.
- `Gpu.Handle`: the handle types, for example `Adapter` and `Device`.

- `Gpu.Surface`: `fromElement`, `fromCanvas`, `fromOffscreen`, `configure`, `unconfigure`,
  `getConfiguration`, `canvas`.
- `Gpu.Frame`: `submit`, `batch`, `getCurrentTexture`, `encode`, `submitCommands`.
- `Gpu.Diagnostics`: `run`, `nested`, `pushErrorScope`, `popErrorScope`, `state` and
  `DiagnosticReport`. `Gpu.Diagnostics.Device`, `.Texture`, `.ComputePipeline`,
  `.RenderPipeline`, `.Queue`, `.Buffer`, `.Surface`, `.Encode`, `.Batch` and `.Frame`: the
  forwarding form of each checked operation, with the session as the first argument.
- `Gpu.Device.eachEvent` and `Gpu.Device.onEvent`: the device's events, `Gpu.Error.DeviceEvent`.
- `Gpu.Queue.copyExternalImageToTexture`, `Gpu.Batch.copyExternalImageToTexture`: copy an image,
  a bitmap, image data, a video, a video frame or a canvas into a texture.
- `Gpu.Batch.importExternalTexture`, `Gpu.Frame.importExternalTexture`: a video element or a video
  frame as an external texture. `Gpu.ExternalTexture`: `label`, `setLabel`.

## Rules

1. **Call an operation through its module, or with `▷`.** A handle has no methods:
   `Gpu.Device.destroy device` or `device ▷ Gpu.Device.destroy`. `device.destroy` is
   `unknown_method`.
2. **A descriptor field that is optional is an `Option`.** `Default` leaves the field out, and the
   browser uses its default. `Value x` sends `x`. Each descriptor has a constructor that takes the
   required fields and sets all other fields to `Default`: `Gpu.Types.deviceDescriptor`. Change a
   field with a record update.
3. **A number in a descriptor is a scalar.** Make it with `Gpu.Scalar.u32`, `size64`, `finiteF32`
   and the others. Each returns `Err` for a value outside the IDL type. A constructor with
   `Truncating` in its name removes the fraction first. A `Size64` is at most 2⁵³ − 1, as
   in the browser. `Gpu.Error.atPath` puts a scalar's error at a descriptor path.
   A color, origin or extent written as a list is a `ColorList`, `Origin2DList`, `Origin3DList`
   or `Extent3DList`: `Gpu.Types.colorList` and the others return `Nothing` for a list whose
   length the browser refuses.
4. **A failure that the standard documents is a value.** `requestAdapter` and `requestDevice`
   return `Result Gpu.Error.InitError`. An adapter gives one device. A second request is
   `AdapterConsumed`. A feature or a limit that the adapter does not support is refused before
   the browser is asked. A limit is never clamped.
5. **A failure that the standard does not document stops the program.** An unknown exception, a
   value outside the pin, or a spoofed error is a defect, not an `Err`.
6. **A checked operation returns only what the device accepted.** `createSampler` returns
   `Result Gpu.Error.Error`: `Validation`, `OutOfMemory` or `Internal` when an error scope reports
   one, `RelatedFailures` when several do, and `DeviceLost` when the device is lost before or
   during the check. While a diagnostic session holds the device, it returns
   `InvalidInput (SessionState DeviceLeased)` at once and does not wait.
7. **A device can be lost.** `Gpu.Device.loss` gives the latched loss. `Gpu.Device.awaitLost`
   waits for it. `Gpu.Device.destroy` latches `Destroyed` immediately. To recover, request a new
   adapter and a new device.
8. **These functions can suspend.** Call them in a fiber: in `browser-tea`, in `Cmd.task`.

## Buffers and mapping

1. **Map a buffer to read or write its memory.** `Gpu.Buffer.map buffer Gpu.Buffer.mapRead` gives a
   `Mapping`. `Gpu.Buffer.getMappedRange` gives a `MappedRange` of it. `Gpu.Buffer.withMapped`
   maps, calls your function, and unmaps after it, also when it returns `Err` or is cancelled.
2. **A mapping ends at `unmap`, at `destroy`, at the next `map`, and when its device is
   destroyed.** After that, the mapping and all its ranges give `ResourceExpired`, also where
   you kept a copy of them.
3. **A buffer made with `mappedAtCreation = Value True` is mapped.** Get its mapping with
   `Gpu.Buffer.currentMapping`, or use `Gpu.Device.createMappedBuffer`. You can write that mapping
   without the `MapWrite` usage. Its size must be a multiple of 4 (`MappedSizeUnaligned`).
4. **Inputs are checked before the browser is called.** A map mode that is not exactly read or
   write, a missing usage, an offset that is not a multiple of 8, a size that is not a multiple
   of 4, a range out of bounds, a second map, overlapping ranges and a write to a read mapping
   each give their own `InvalidInput`.
5. **Mapped memory is little-endian.** Offsets count bytes from the start of the range.
   `readWord64` and `writeWord64` keep all 64 bits: use them for `u64` and `i64` values.
6. **Binary data for the GPU must have a fixed length.** A resizable `ArrayBuffer` or a growable
   `SharedArrayBuffer` gives `ResizableBacking`, also through a view and also when it never
   resized. Detached data gives `DetachedSource`. `Gpu.MappedRange.writeBytes` is a copy in
   CPU memory: it takes any attached storage.
7. **`Gpu.Queue.writeBuffer` counts `dataOffset` and `size` in elements of the data**, as the
   browser does: bytes for an `ArrayBuffer` or a `DataView`, elements for a typed array.
8. **Each `Gpu.Queue.submit` gives one receipt.** `Gpu.Submission.done` waits for the work of that
   submit. An empty list is a submit too. Nothing waits if you do not call `done`.
9. **Some calls run while a diagnostic session holds the device**: `unmap`, `destroy`,
   `currentMapping`, the mapped range reads and writes, and `Gpu.Submission.done`. A checked
   operation (`map`, `createBuffer`, `writeBuffer`, `submit`) returns `DeviceLeased`; use its
   form in `Gpu.Diagnostics.Buffer` or `Gpu.Diagnostics.Queue` (see *Diagnostic sessions*).

## Encoding, compute and rendering

Encoding, batches, compute and render passes are in `references/webgpu-render.md`.

## Canvases and frames

1. **A surface is the WebGPU context of a canvas.** `Gpu.Surface.fromElement "id"`,
   `fromCanvas` and `fromOffscreen` give it. Configure it with `Gpu.Surface.configure`, which
   can suspend. A configuration that failed leaves the surface unconfigured.
2. **Draw in a frame.** `Gpu.Frame.submit surface name body` calls `body` once. In `body`, get
   the texture with `Gpu.Frame.getCurrentTexture`, make resources with the frame's batch
   (`Gpu.Frame.batch`), encode with `Gpu.Frame.encode` and submit with
   `Gpu.Frame.submitCommands`. `body` cannot suspend, and no other fiber runs while it runs.
3. **A frame gives one receipt for each submit.** A frame that submits nothing gives no
   receipt. A frame that fails gives no receipt.
4. **The current texture is for one frame only.** After the frame, after `configure` or
   `unconfigure`, and after each `Browser.Canvas.resize` (also to the same size), the texture,
   its views, and command buffers, bundles and bind groups that use them give
   `ResourceExpired`. Do not keep them.
5. **Set the backing size with `Browser.Canvas.resize`.** It is separate from the CSS size.
6. **Keep the canvas node in the view.** In `browser-tea`, put the `<canvas>` in `view` and draw
   from a command (`Cmd.task`). A render keeps the node, so `fromElement` gives the same
   surface again.
7. **`Gpu.Surface.getConfiguration` returns a `Result`.** A browser without the method gives
   `UnsupportedCapability`. A field the browser does not report is `Default`.

## Images, videos and canvases

Copies of images, videos and canvases into textures, and external textures, are in
`references/webgpu-render.md`.

## Diagnostic sessions

1. **A session gives you the native error scopes.** `Gpu.Diagnostics.run device body` takes
   the device's lease and calls `body` with a `DiagnosticSession`. In `body`,
   `Gpu.Diagnostics.pushErrorScope session filter` pushes a scope and
   `Gpu.Diagnostics.popErrorScope session` pops it and gives the one error it kept, or
   `Nothing`. A pop with no scope of yours open gives `ScopeUnderflow`.
2. **The lease is taken at once or refused.** `run` on a device whose lease is held gives
   `InvalidInput (SessionState DeviceLeased)`. Nothing waits for a lease.
3. **While the lease is held, every ordinary checked operation on that device gives
   `DeviceLeased` at once**: from `body`, from a fiber that `body` starts or joins, and from
   every other fiber. Use the forwarding forms: `Gpu.Diagnostics.Device.createBuffer session
   device descriptor` and the others take the session first, then the usual arguments.
4. **These calls run as usual under a lease**: `destroy`, `unmap` and `unconfigure`; the reads
   of state (`features`, `limits`, `label`, `mapState`, `currentMapping`, `loss`, `queue`,
   `getConfiguration`); `getMappedRange` and the mapped range reads and writes; and the waits
   on earlier work (`Gpu.Submission.done`, `Gpu.Queue.onSubmittedWorkDone`,
   `Gpu.Shader.getCompilationInfo`, a map that started before, `awaitLost`, `eachEvent`,
   `onEvent`).
5. **A forwarding call has no scopes of its own.** The device's errors go to your scopes, or to
   the session's own scopes when no scope of yours takes them. What it makes is provisional:
   the session can use it, and it is accepted only when the session ends and no scope reported
   an error.
6. **The result is a report.** `run` gives `Ok { value, observed }`: `value` is `Nothing` when a
   scope of yours reported an error, and then what the session made is rejected. An error that
   only the session's own scopes caught gives `Err` (`Validation`, `OutOfMemory`, `Internal`),
   and a loss gives `DeviceLost`.
7. **The lease ends when `body` ends**: when it returns, when it is cancelled, and when it
   throws. Scopes that `body` left open are popped then. A session used after that gives
   `SessionEnded`. `Gpu.Diagnostics.nested` opens a session inside a session; while it is open,
   the outer session's calls give `DeviceLeased`.
8. **Do not wait in a session for work that uses the device through ordinary calls.** A fiber
   that retries an ordinary call until it does not get `DeviceLeased` never succeeds while the
   session waits for it, and the session never ends. Send that work through the session, or do
   it after the session.

```beni platform=browser-tea
import Gpu.Diagnostics as Diagnostics
import Gpu.Diagnostics.Device
import Gpu.Error as Error
import Gpu.Handle exposing (Device)
import Gpu.Types as Types


-- Whether the device refuses `descriptor`, seen through a scope of its own.
refuses : Device, Types.SamplerDescriptor → Result Error.Error Bool
refuses device descriptor =
    report = Diagnostics.run device λsession →
        _ = Diagnostics.pushErrorScope session Types.FilterValidation
        _ = Gpu.Diagnostics.Device.createSampler session device descriptor
        Diagnostics.popErrorScope session
    Result.map report λr → not (List.isEmpty r.observed)
```

## Device events

1. **`Gpu.Device.eachEvent device handler` calls `handler` with each event of the device.** It
   returns after the `Lost` event. A listener that starts after the loss gets `Lost` at once.
   Cancel the fiber to stop it.
2. **`Gpu.Device.onEvent device tag` is the same as a subscription** in `browser-tea`.
3. **An `Uncaptured` event is a defect.** The engine runs every call under an error scope, so an
   error that no scope took is a fault in beni or in the browser. The listeners get the event,
   and then the program that made the device stops. Do not use events to find errors: each
   operation returns its own.

## Example

```beni platform=browser-tea
import Cmd exposing (Cmd)
import Gpu
import Gpu.Adapter
import Gpu.Error as Error
import Gpu.Handle exposing (Device)
import Gpu.Limits as Limits
import Gpu.Scalar as Scalar
import Gpu.Types as Types
import Html exposing (Html)
import Sub
import Tea


type Msg
    = Start
    | Got (Result Error.InitError Device)


start : ⊤ → Result Error.InitError Device
start ⊤ =
    adapter = (Gpu.requestAdapter Types.adapterOptions)?
    base = Types.deviceDescriptor
    descriptor =
        case Scalar.size64 4 of
            Ok four →
                { base | requiredLimits = Types.Value [ ( Limits.MaxBindGroups, four ) ] }

            Err _ →
                base
    Gpu.Adapter.requestDevice adapter descriptor


update : Msg, String → String × Cmd Msg
update msg _ =
    case msg of
        Start →
            ( "starting", Cmd.task start Got )

        Got (Ok _) →
            ( "a device", Cmd.none )

        Got (Err Error.ApiUnavailable) →
            ( "no WebGPU here", Cmd.none )

        Got (Err _) →
            ( "no device", Cmd.none )


view : String → Html Msg
view text = <button onClick={Start}>{text}</button>


main : Tea.Program
main =
    Tea.element
        { init = λ⊤ → ( "start", Cmd.none )
        , update = update
        , view = view
        , subscriptions = λ_ → Sub.none
        }
```

## What the standard cannot report

An error scope keeps one error for each scope. A lost device does not report usual errors. A
fault in a running shader can stay unseen. A success means that the checks the operation waited
for reported no failure. It does not mean that the device stays healthy.

Sources: `docs/design/webgpu.md` §2–§5, §6.2, §6.4, §7, §7.1, §8, §8.1, §8.2, §8.3, §10; `docs/design/research/webgpu-errors.md`; the
modules' doc comments.
