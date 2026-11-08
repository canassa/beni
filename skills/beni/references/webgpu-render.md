# WebGPU encoding, compute and rendering

Command encoding, batches, compute passes, render pipelines, render passes, render bundles and
occlusion queries of the `Gpu` modules.
Read `references/webgpu.md` first: its rules hold here too.

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
   provisional: the batch can use it at once; other code gets `ResourcePending` until the batch
   is accepted, and `Gpu.Batch.awaitReady` waits for that.
   A failed batch rejects all that it made. A batch is not a transaction: a write it did stays.
6. **The GPU memory is little-endian.** Read a query result with `readWord64`.
7. **A batch fails as a whole.** Its failure is `BatchFailed`: the failure, and which operations
   were issued and which were refused. `Gpu.Batch.segment` names a part of the batch, and a
   device error carries that name.

This module encodes a clear and submits it, then does the same work in a batch:

```beni platform=browser-tea
import Cmd exposing (Cmd)
import Gpu
import Gpu.Adapter
import Gpu.Batch as Batch
import Gpu.CommandEncoder as CommandEncoder
import Gpu.Device
import Gpu.Encode as Encode
import Gpu.Error as Error
import Gpu.Flags as Flags
import Gpu.Handle exposing (Batch, Device)
import Gpu.Queue
import Gpu.Scalar as Scalar
import Gpu.Submission
import Gpu.Types as Types
import Html exposing (Html)
import Sub
import Tea


type Msg
    = Start
    | Done (Result String ⊤)


-- Clear a new buffer on the GPU and wait for the work.
clearOnce : Device → Result Error.Error ⊤
clearOnce device =
    size = (Result.mapError (Scalar.size64 16) λd → Error.InvalidInput (Error.atPath "size" d))?
    buffer =
        Gpu.Device.createBuffer
            device
            (Types.bufferDescriptor size (Flags.buffer [ Flags.CopyDst ]))?
    encoded =
        (Encode.run device Types.commandEncoderDescriptor λencoder →
            CommandEncoder.clearBuffer encoder buffer 0 Nothing
        )?
    receipt = Gpu.Queue.submit (Gpu.Device.queue device) [ encoded.commands ]?
    Gpu.Submission.done receipt


-- The same work as one batch: checked together, accepted together.
clearInBatch : Device, Batch → Result Error.Error ⊤
clearInBatch device b =
    size = (Result.mapError (Scalar.size64 16) λd → Error.InvalidInput (Error.atPath "size" d))?
    buffer = Batch.createBuffer b (Types.bufferDescriptor size (Flags.buffer [ Flags.CopyDst ]))?
    encoded =
        (Batch.encode b Types.commandEncoderDescriptor λencoder →
            CommandEncoder.clearBuffer encoder buffer 0 Nothing
        )?
    _ = Batch.submit b (Gpu.Device.queue device) [ encoded.commands ]?
    Ok ⊤


start : ⊤ → Result String ⊤
start ⊤ =
    case Gpu.requestAdapter Types.adapterOptions of
        Err _ →
            Err "no adapter"

        Ok adapter →
            case Gpu.Adapter.requestDevice adapter Types.deviceDescriptor of
                Err _ →
                    Err "no device"

                Ok device →
                    case ( clearOnce device, Batch.run device "clear" (clearInBatch device _) ) of
                        ( Ok _, Ok _ ) →
                            Ok ⊤

                        _ →
                            Err "the GPU refused the work"


update : Msg, String → String × Cmd Msg
update msg _ =
    case msg of
        Start →
            ( "working", Cmd.task start Done )

        Done (Ok _) →
            ( "done", Cmd.none )

        Done (Err why) →
            ( why, Cmd.none )


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

## Images, videos and canvases

1. **Copy a source into a texture with `Gpu.Queue.copyExternalImageToTexture`.** The source is a
   `Gpu.Types.CopyExternalImageSource`: `Bitmap`, `ImageData`, `ImageElement`, `VideoElement`,
   `VideoFrame`, `CanvasElement` or `OffscreenCanvas`. Get it from `Browser.Image`,
   `Browser.Video` or `Browser.Canvas`. The texture needs the usages `RenderAttachment` and
   `TextureCopyDst`. A video copies its current frame.
2. **Colours change only as you ask.** `flipY`, `origin`, `colorSpace` and `premultipliedAlpha`
   are fields of the two info records. Nothing is flipped for you.
3. **A source that the browser cannot use is refused before the call.** The error is
   `SourceFailed` with `SourceClosed` (a closed bitmap or video frame), `SourceDetached` (image
   data whose storage was transferred), `SourceEmpty` (a canvas of width or height 0, an image
   with no source), `SourceBroken` (an image that failed to load) or `SourceNotReady` (an image
   with no picture yet, a video with no frame yet).
4. **The browser decides the other source failures.** `SourceNotOriginClean`: the source comes
   from another origin without CORS. `ExternalImageCopyRangeRejected`: the copy goes outside the
   source. `SourceUnusable`: the browser refused the source for another reason.
5. **Import an external texture in a batch or a frame.** `Gpu.Batch.importExternalTexture` or
   `Gpu.Frame.importExternalTexture` takes a `VideoElement` or `VideoFrame` source. Bind it with
   `Gpu.Types.ExternalTextureBinding` and read it with a WGSL `texture_external`.
6. **An external texture expires.** A texture of a video element expires when its batch or frame
   ends. A texture of a video frame expires when you close the frame. After that, the texture
   and the bind groups, command buffers and bundles that use it give `ResourceExpired`. Import
   the video again in each frame.

```beni platform=browser-tea
import Browser.Image
import Gpu.Device
import Gpu.Error as Error
import Gpu.Flags as Flags
import Gpu.Handle exposing (Device, Texture)
import Gpu.Queue
import Gpu.Scalar as Scalar
import Gpu.Types as Types


-- Copy `bitmap`, `width` by `height` pixels, into a new texture.
copy : Device, Browser.Image.Bitmap, Int, Int → Result Error.Error Texture
copy device bitmap width height =
    w = Result.mapError (Scalar.u32 width) (λd → Error.InvalidInput (Error.atPath "width" d))?
    h = Result.mapError (Scalar.u32 height) (λd → Error.InvalidInput (Error.atPath "height" d))?
    size =
        Types.Extent3DFields
            { width = w, height = Types.Value h, depthOrArrayLayers = Types.Default }
    usage = Flags.texture [ Flags.RenderAttachment, Flags.TextureCopyDst, Flags.TextureBinding ]
    texture = Gpu.Device.createTexture device (Types.textureDescriptor size Types.Rgba8unorm usage)?
    Gpu.Queue.copyExternalImageToTexture
        (Gpu.Device.queue device)
        (Types.copyExternalImageSourceInfo (Types.Bitmap bitmap))
        (Types.copyExternalImageDestInfo texture)
        size?
    Ok texture
```

Sources: `docs/design/webgpu.md` §4, §6.1–§6.3, §8 (*As built — S5*);
`docs/design/research/webgpu-errors.md` §3, §5, §6; the modules' doc comments.
