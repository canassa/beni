# Browser sources for WebGPU

This contract supplements WebGPU without importing all of HTML or WebCodecs.
All production implementation is beni over privileged Js operations. The handles
in Browser.Source erase to native identities; Image, Video and Canvas expose
aliases so their constructors can accept each other without circular imports.
Every GPU union alternative remains distinct and available.

ImageData allocation accepts both rgba-unorm8 and rgba-float16 in either sRGB or
Display-P3. Wrapping a typed view retains the actual native typed view and
rejects shared, resizable, detached, mismatched-type or inconsistent pixel
storage before construction. Allocation RangeError is AllocationFailed. The
HTML algorithms explicitly rethrow it. Native origin-clean state remains host
owned and cannot be guessed from URLs.

Image element decoding waits in a cancellable fiber and classifies only
DOMException EncodingError. Bitmap creation preserves all options and the crop
overload, including negative crop widths/heights. Zero crops and zero resize
sizes are rejected before the host call. InvalidStateError is typed; any other
rejection enters Task.soon's defect path, including a late rejection after
cancellation. A bitmap produced after cancellation is closed immediately.
Closing a bitmap or frame affects all native aliases.

Canvas acquisition performs a native element type check. HTML canvas dimensions
are unsigned long; OffscreenCanvas dimensions use EnforceRange unsigned long
long, whose representable Number values must not be narrowed to uint32.
TransferControlToOffscreen InvalidStateError means AlreadyControlled. Width or
height setters on an HTML placeholder have the same typed failure. Offscreen
dimension setters do not prove liveness, and can still be changed after transfer.
The offscreen readiness state is ContextValidationRequired; native consuming
operations test its private state. An offscreen
canvas transferred into another realm has a separate native handle; sender
aliases are invalidated together. Dedicated/browser workers must use browser
realm adapters, never the Cloudflare Worker host.

Source readiness is a point-in-time observation, and cannot prove origin-clean
state or future validity. GPU operations repeat operation-specific checks and
classify host errors after state changes.

Primary algorithms (retrieved 2026-10-30):

- https://html.spec.whatwg.org/multipage/imagebitmap-and-animations.html
- https://html.spec.whatwg.org/multipage/embedded-content.html#dom-img-decode
- https://html.spec.whatwg.org/multipage/canvas.html#the-offscreencanvas-interface
- https://www.w3.org/TR/2026/WD-webcodecs-20261026/#videoframe
- https://webidl.spec.whatwg.org/#es-buffer-source-types

Bitmaprenderer acquisition and presentation retain native context identity. Presenting consumes the bitmap. Offscreen snapshot uses the native transferToImageBitmap operation; a missing context or detached canvas is NoContextOrDetached, matched by DOMException InvalidStateError.
