# Browser sources for WebGPU

This contract supplements WebGPU without importing all of HTML or WebCodecs.
All production implementation is beni over privileged Js operations.

**Handles are the generated native types** (aligned with option C,
2026-11-08; [workers.md](workers.md) §4). `Browser.Source.Input` is an
ordinary union over `Browser.Host.HTMLImageElement`, `ImageBitmap`,
`ImageData`, `HTMLVideoElement`, `VideoFrame`, `HTMLCanvasElement` and
`OffscreenCanvas`: every GPU copy source arm, none dropped. `Browser.Image`
names them `Element`, `Bitmap` and `Data`, `Browser.Video` `Element` and
`Frame`, and `Browser.Canvas` `Canvas`, `OffscreenCanvas` and, for
`ImageBitmapRenderingContext`, `BitmapRenderer` — type aliases, so the same
native identity flows between the modules and into GPU code with no
conversion. The shipped `Browser.Host` modules are the native-bindings
generator's output, byte for byte (`tests/native_bindings.zig`); they carry
no operation, so the realm check of a worker build covers these modules as
it covers any beni over `Js`: acquisition from an element names a Window-only
global and is refused in a worker entry (workers.md §4, *The worker global
allow-list*).

ImageData allocation accepts both rgba-unorm8 and rgba-float16 in either sRGB or
Display-P3. Wrapping a typed view retains the actual native typed view — a
`Binary.Uint8ClampedArray` for rgba-unorm8, a `Binary.Float16Array` for
rgba-float16, any other is `WrongPixelView` — and rejects shared, resizable,
detached or inconsistent pixel storage before construction. Allocation
RangeError is AllocationFailed. The HTML algorithms explicitly rethrow it.
Native origin-clean state remains host owned and cannot be guessed from URLs.

Image element decoding (`Image.decodeElement`; renamed 2026-11-08 so that it
does not clash with webgpu.md §3.2's `decode`, which `bitmap` and
`bitmapFromBytes` provide) waits in a cancellable fiber and classifies only
DOMException EncodingError. Bitmap creation preserves all options and the crop
overload, including negative crop widths/heights. Zero crops and zero resize
sizes are rejected before the host call. InvalidStateError is typed; any other
rejection enters Task.soon's defect path, including a late rejection after
cancellation. A bitmap produced after cancellation is closed immediately.
Closing a bitmap or frame affects all native aliases.

Encoded bytes (webgpu.md §3.2's `ImageInput`) decode with `bitmapFromBytes`:
the source's bytes are copied into a Blob of the given MIME type (so shared
storage is accepted) and handed to createImageBitmap, whose InvalidStateError
is then `DecodeFailed`.

VideoFrame construction takes any image source but ImageData (not a
CanvasImageSource). A timestamp is required except from a video element or a
frame. Every option is checked before the host call; the residual expected
failures are DOMException InvalidStateError (`InvalidSource`), SecurityError
(`Security`), and the TypeError a visible rectangle outside an image or video
element's private coded size raises (`InvalidRectangle`; amended 2026-11-08:
only for those two arms, whose coded size beni cannot read — every other
arm's rectangle is bounds-checked first, so a TypeError there is a defect).
The constructor checks the source before its rectangle, so `frame` does too:
a closed bitmap or frame is `Closed`, and a source with no pixels (a loading
or broken element, an empty canvas) is `InvalidSource`, before any rectangle
check. A frame built from
pixel buffers (VideoFrameBufferInit) is not offered yet (#2250).

Canvas acquisition performs a native element type check. An HTML canvas
dimension reflects as `unsigned long`, whose setter resets a value above
2^31 − 1 to the default, so `create` and `resize` refuse it
(`InvalidDimension`). OffscreenCanvas dimensions are [EnforceRange] unsigned
long long, which throws a TypeError above 2^53 − 1, so `offscreen` and
`resizeOffscreen` refuse those first (amended 2026-11-08).
The offscreen readiness state is ContextValidationRequired; native consuming
operations test its private state.

Source readiness is a point-in-time observation, and cannot prove origin-clean
state or future validity. GPU operations repeat operation-specific checks and
classify host errors after state changes. An `<img>` with no source at all is
`Empty`; one whose source failed is `Broken`.

Bitmaprenderer acquisition and presentation retain native context identity.
Presenting consumes the bitmap. Offscreen snapshot uses the native
transferToImageBitmap operation; a canvas without a context is `NoContext`,
matched by DOMException InvalidStateError. `getContext("bitmaprenderer")` has
no expected exception until a canvas can be handed to another realm (#1299):
a canvas with another kind of context gives null, `ContextUnavailable`.

**Not offered yet: worker transfer** (#1299). Moving or copying a bitmap, a
frame, an OffscreenCanvas, ImageData or binary storage to or from a worker,
and `transferControlToOffscreen` (whose only use is to hand the canvas to
another realm), wait for the native transfer families and shared-name Wire
plans of #1299 (workers.md §5, §9). Until then no placeholder canvas exists,
so a canvas's width and height setters have no expected failure.

Primary algorithms (retrieved 2026-10-30):

- https://html.spec.whatwg.org/multipage/imagebitmap-and-animations.html
- https://html.spec.whatwg.org/multipage/embedded-content.html#dom-img-decode
- https://html.spec.whatwg.org/multipage/canvas.html#the-offscreencanvas-interface
- https://www.w3.org/TR/2026/WD-webcodecs-20261026/#videoframe
- https://webidl.spec.whatwg.org/#es-buffer-source-types
