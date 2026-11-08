# WebGPU

The `browser` platform has the `Gpu` modules. `browser-tea` re-exports them. They give the
browser's WebGPU API with types. Only the main thread has them now.

## What exists now

- `Gpu`: `available`, `requestAdapter`, `preferredCanvasFormat`, `wgslLanguageFeatures`.
- `Gpu.Adapter`: `features`, `limits`, `info`, `requestDevice`.
- `Gpu.Device`: `features`, `limits`, `adapterInfo`, `queue`, `destroy`, `loss`, `awaitLost`, and the
  first checked operation, `createSampler`.
- `Gpu.Types`: one record for each IDL dictionary, one type for each IDL enum, one sum for each
  IDL union. These are generated from the pinned IDL.
- `Gpu.Flags`: the five flag domains. A buffer usage set is not a texture usage set.
- `Gpu.Limits`, `Gpu.Feature`, `Gpu.WgslFeature`: snapshots that the host reports. A limit
  that some browsers do not report yet is `Maybe Int`, and `Gpu.Limits.limit` gives `Maybe Int`.
- `Gpu.Scalar`: `U32`, `I32`, `Size64`, `FiniteF32`, `FiniteF64`.
- `Gpu.Error`: `InitError`, `Error` and their parts.
- `Gpu.Handle`: the handle types, for example `Adapter` and `Device`.

Buffers, textures, shaders, pipelines, passes and canvases come in later releases.

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

Sources: `docs/design/webgpu.md` §2–§5, §8, §10; `docs/design/research/webgpu-errors.md`; the
modules' doc comments.
