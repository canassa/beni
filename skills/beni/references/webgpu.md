# WebGPU

The `browser` platform has the `Gpu` modules. `browser-tea` re-exports them. They give the
browser's WebGPU API with types. Only the main thread has them now.

## What exists now

- `Gpu`: `available`, `requestAdapter`, `preferredCanvasFormat`, `wgslLanguageFeatures`.
- `Gpu.Adapter`: `features`, `limits`, `info`, `requestDevice`.
- `Gpu.Device`: `features`, `limits`, `adapterInfo`, `queue`, `destroy`, `loss`, `awaitLost`, and the
  checked operations `createSampler`, `createBuffer`, `createMappedBuffer`, `createTexture`,
  `createBindGroupLayout`, `createBindGroup`, `createPipelineLayout`, `createShaderModule`,
  `createComputePipeline`, `createComputePipelineAsync`, `createRenderPipeline`,
  `createRenderPipelineAsync` and `createQuerySet`.
- `Gpu.Buffer`: `size`, `usage`, `mapState`, `label`, `setLabel`, `map`, `currentMapping`,
  `getMappedRange`, `withMapped`, `unmap`, `destroy`, and the mapping's `mappingMode`,
  `mappingRange`, `mappingBuffer` and `mappingLive`.
- `Gpu.MappedRange`: reads and writes of mapped memory: `readU8` to `readF64`, `readF16`,
  `readWord64`, the `write` forms, `readBytes` (a copy) and `writeBytes`.
- `Gpu.Queue`: `writeBuffer`, `writeTexture`, `submit`, `onSubmittedWorkDone`, `label`, `setLabel`.
- `Gpu.Shader`: `getCompilationInfo`, `compile`, `source`. `Gpu.ComputePipeline`:
  `getBindGroupLayout`. `Gpu.Texture`: snapshots, `createView` and `destroy`. `Gpu.QuerySet`:
  snapshots and `destroy`. `Gpu.TextureView`, `Gpu.RenderBundle`: `label`, `setLabel`.
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
2. **A mapping ends at `unmap`, at `destroy` and at the next `map`.** After that, the mapping and
   all its ranges give `ResourceExpired`, also where you kept a copy of them.
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
   resized. Detached data gives `DetachedSource`.
7. **`Gpu.Queue.writeBuffer` counts `dataOffset` and `size` in elements of the data**, as the
   browser does: bytes for an `ArrayBuffer` or a `DataView`, elements for a typed array.
8. **Each `Gpu.Queue.submit` gives one receipt.** `Gpu.Submission.done` waits for the work of that
   submit. An empty list is a submit too. Nothing waits if you do not call `done`.
9. **Some calls run while a diagnostic session holds the device**: `unmap`, `destroy`,
   `currentMapping`, the mapped range reads and writes, and `Gpu.Submission.done`. A checked
   operation (`map`, `createBuffer`, `writeBuffer`, `submit`) returns `DeviceLeased`.

## Compute

1. **Encode in one callback.** `Gpu.Encode.run device descriptor λencoder → …` gives the
   callback a `CommandEncoder`. The callback cannot suspend. Use `Gpu.ComputePass.with` for a
   pass. The result has your value and the `CommandBuffer`. Submit it with `Gpu.Queue.submit`.
2. **An `Ok` from a command means it was issued, not that the device accepted it.** The
   `Result` of `Encode.run` tells you that.
3. **The first refusal stops the session.** Later commands give `SessionStopped`. `Encode.run`
   returns the first refusal, also when your callback ignored it.
4. **A command buffer is used once.** A second submit gives `CommandBufferSubmitted`.
5. **`Gpu.Batch.run` checks many synchronous operations together.** What the batch makes is
   provisional: the batch can use it at once; other code gets it after the batch is accepted.
   A failed batch rejects all that it made. A batch is not a transaction: a write it did stays.
6. **The GPU memory is little-endian.** Read a query result with `readWord64`.

## Rendering

1. **A render pass is a callback too.** `Gpu.RenderPass.with encoder descriptor body` begins
   the pass, calls `body` and ends the pass. Write `body` as a named function: a `?` cannot be
   in a lambda. While the pass is open, an encoder command gives `EncoderLocked`. After `end`, a
   pass command gives `PassEnded`.
2. **`draw` takes a record.** `Gpu.RenderPass.vertices count` and `Gpu.RenderPass.indices count`
   give the arguments with the browser's defaults. Change a field with a record update:
   `{ (Gpu.RenderPass.vertices six) | instanceCount = two }`.
3. **An attachment must be usable.** A view of a destroyed texture gives `ResourceDestroyed`, and
   a view of another device gives `WrongDevice`.
4. **An occlusion query needs a query set in the pass descriptor.** Without one,
   `beginOcclusionQuery` gives `QuerySetMissing`. A second begin gives `QueryActive`. An end with
   no open query gives `QueryInactive`.
5. **`executeBundles` clears the pass state.** After it, set the pipeline, the bind groups and
   the buffers again before the next draw.
6. **A format that needs a feature is checked first.** A pipeline, a view or a bundle encoder
   that names such a format on a device without the feature gives `UnsupportedCapability`.
7. **A batch can make render resources.** `Gpu.Batch.createView`, `createRenderPipeline`,
   `getRenderBindGroupLayout` and `encodeBundle` are the batch forms.
8. **An occlusion query ends before its pass.** A pass that ends with an open query gives
   `QueryActive`. An index used a second time in one pass gives `QueryReused`.

```beni platform=browser-tea
import Gpu.Device
import Gpu.Encode as Encode
import Gpu.Error as Error exposing (InputError)
import Gpu.Handle exposing (CommandBuffer, Device, RenderPass, RenderPipeline, TextureView)
import Gpu.RenderPass as RenderPass
import Gpu.Scalar as Scalar
import Gpu.Types as Types


wgsl : String
wgsl =
    "@vertex fn vs(@builtin(vertex_index) v : u32) -> @builtin(position) vec4f {\n"
        ++ "    return vec4f(f32(v % 2u), f32(v / 2u), 0.0, 1.0);\n"
        ++ "}\n"
        ++ "@fragment fn fs() -> @location(0) vec4f { return vec4f(1.0, 0.0, 0.0, 1.0); }"


pipeline : Device → Result Error.Error RenderPipeline
pipeline device =
    module = (Gpu.Device.createShaderModule device (Types.shaderModuleDescriptor wgsl))?
    base = Types.renderPipelineDescriptor Types.Auto (Types.vertexState module)
    fragment = Types.fragmentState module [ Just (Types.colorTargetState Types.Rgba8unorm) ]
    Gpu.Device.createRenderPipeline device { base | fragment = Types.Value fragment }


triangle : RenderPipeline, RenderPass → Result InputError ⊤
triangle p pass =
    RenderPass.setPipeline pass p?
    three = Result.mapError (Scalar.u32 3) (Error.atPath "vertexCount" _)?
    RenderPass.draw pass (RenderPass.vertices three)


draw : Device, TextureView → Result Error.Error CommandBuffer
draw device target =
    p = pipeline device?
    color =
        Types.renderPassColorAttachment (Types.AttachmentTextureView target) Types.Clear Types.Store
    pass = Types.renderPassDescriptor [ Just color ]
    encoded =
        (Encode.run device Types.commandEncoderDescriptor λencoder →
            RenderPass.with encoder pass (triangle p _)
        )?
    Ok encoded.commands
```

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

Sources: `docs/design/webgpu.md` §2–§5, §6.2, §7, §7.1, §8, §8.2, §8.3, §10; `docs/design/research/webgpu-errors.md`; the
modules' doc comments.
