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

Canvases come in a later release.

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
   operation (`map`, `createBuffer`, `writeBuffer`, `submit`) returns `DeviceLeased`.

## Encoding, compute and rendering

Encoding, batches, compute and render passes are in `references/webgpu-render.md`.

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

Sources: `docs/design/webgpu.md` §2–§5, §6.2, §7, §7.1, §8, §8.3, §10; `docs/design/research/webgpu-errors.md`; the
modules' doc comments.
