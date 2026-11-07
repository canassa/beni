# Binary storage and browser sources

`Binary` is core and works on every host with the corresponding native capability.
Its Buffer, SharedBuffer, View and Source handles retain native identity. Use
allocate/shared, then view with a Backing and ViewKind. View offsets are bytes;
view counts are elements (Data counts bytes). Scalar read/write offsets are bytes
relative to that view. Multi-byte values take Binary.Little or Binary.Big.

```beni platform=node
import Binary
import List
import Node exposing (Program)


main : Program
main =
    case bytes ⊤ of
        Ok values → Node.print (String.fromInt (List.length values))
        Err _ → Node.print "binary error"


bytes : ⊤ → Result Binary.Error (List Int)
bytes ⊤ =
    buffer = Binary.allocate 8?
    view = Binary.view (Binary.Local buffer) Binary.Data 0 Nothing?
    exact = Binary.word64 4294967295 4294967295?
    Binary.writeWord64 view 0 Binary.Little exact?
    source = Binary.viewSource view?
    Binary.toList source
```

Word64 stores exact high/low uint32 words. `word64ToInt` succeeds only when its
Number result roundtrips to those exact words; it also accepts exactly representable
values above 2^53. Do not write a large decimal Int and expect lost bits to be
recovered later. GPU timestamps and other 64-bit buffer results can be read as
words directly. `Binary.Atomics` accesses integer typed views atomically, with
Number or exact Words values. Ordinary scalar reads/writes are not atomic.

`Binary.Wgsl` describes explicit host-shareable layouts. It supports scalar,
vector, column-major matrix, fixed/runtime-array and structure codecs, with
explicit member align/size attributes. Inspect members/stride/byteSize rather
than guessing vec3 padding. `uniform` validates the actual declaration's standard
or legacy uniform-variable layout; it does not change the shader declaration or
validate WGSL source text. Raw opaque WGSL buffer contents can use Binary directly.

Browser.Image exposes Element, Bitmap and Data; Browser.Video exposes Element
and Frame; Browser.Canvas exposes Canvas and OffscreenCanvas. Browser.Source.Input
retains all seven GPU image-source alternatives. Load/decode/bitmap operations
wait in fibers and return typed errors. Closing/transferring a bitmap/frame affects
all aliases. Source.info is a snapshot of observable state; OffscreenCanvas has
ContextValidationRequired because dimensions do not prove its private transfer or
context state. GPU operations still perform their native validation.

Source.clone and Source.send use typed packets with Copy or Move attachments.
DOM elements cannot move into workers. Shared backing may be copied/shared but
cannot be moved; ImageData is serialized, and its actual Binary backing can be
moved separately when needed. A moved OffscreenCanvas cannot already have a context.
`Canvas.present` consumes a bitmap without copying pixels; `snapshot` detaches an
offscreen image into a bitmap and requires a context.

All host failures documented by these operations have typed Result errors. An
unexpected native exception or rejection is a defect; do not catch it as an
application error. Binary source intake rejects detached, resizable and growable
backing even when a view's current bounds fit. Shared allocation reports
IsolationRequired in a browser realm without cross-origin isolation.
