# Binary storage and browser sources

`Binary` is in core. It works on every host that has the native type.

## Storage and views

- `Binary.Buffer` is the native `ArrayBuffer`. `Binary.SharedBuffer` is the native
  `SharedArrayBuffer`. Make them with `allocate` and `shared`. Both are fixed length.
- `Binary.View` has one constructor for each native view: `Int8Array`, `Uint8Array`,
  `Uint8ClampedArray`, `Int16Array`, `Uint16Array`, `Int32Array`, `Uint32Array`,
  `BigInt64Array`, `BigUint64Array`, `Float16Array`, `Float32Array`, `Float64Array`
  and `DataView`. Make a view with `view`, a `Backing` (`Local` or `Shared`) and a
  `ViewKind`. `kind` gives the kind of a view.
- `Binary.Source` is `WholeBuffer`, `WholeShared` or `ViewOf`. `sourceInfo` gives its
  byte offset, byte length, element length and if it is shared.
- A view offset is in bytes. A view count is in elements (`Data` counts bytes).
- A scalar read or write offset is in bytes, from the start of the view. Give
  `Binary.Little` or `Binary.Big` for a value wider than one byte.
- Each operation checks the storage first. Detached storage is `Err Detached`.
  Resizable or growable storage is `Err ResizableBacking`, also when it is in bounds.
- `transfer` moves the storage to a new buffer in the same realm. After it, the old
  buffer and all its views are detached. Moving storage to a worker is not available.

```beni platform=node
import Binary
import Node exposing (Program)


main : Program
main =
    case bytes ⊤ of
        Ok values →
            Node.print (Debug.toString values)
        Err error →
            Node.print (Debug.toString error)


bytes : ⊤ → Result Binary.Error (List Int)
bytes ⊤ =
    buffer = Binary.allocate 8?
    view = Binary.view (Binary.Local buffer) Binary.Data 0 Nothing?
    exact = Binary.word64 4294967295 1?
    Binary.writeWord64 view 0 Binary.Little exact?
    Binary.toList (Binary.ViewOf view)
```

## Exact 64-bit words

`Word64` keeps two exact unsigned 32-bit words. `word64ToInt` and
`word64ToSignedInt` give `Err PrecisionLost` when the `Int` cannot hold the exact
value. Do not write a large decimal `Int` and expect the lost bits to come back.
`readWord64` and `writeWord64` read and write all 64 bits.

## Atomics

`Binary.Atomics.access` runs a native atomic operation on an integer view at an
element index. `BigInt64Array` and `BigUint64Array` take and give `Words`. The other
integer views take and give `Number`. Other views are `Err InvalidView`. Ordinary
scalar reads and writes are not atomic.

## WGSL layout

`Binary.Wgsl` describes a host-shareable WGSL layout: scalars, vectors, column-major
matrices, fixed and runtime arrays, and structures with explicit `align` and `size`.
Read `members`, `stride` and `byteSize`; do not guess the padding of a `vec3`.
`uniform` checks the standard or the legacy uniform rules. It does not change the
shader. `encode` and `decode` use little-endian bytes and write zero into padding.

## Browser sources

The browser platforms export `Browser.Image`, `Browser.Video`, `Browser.Canvas` and
`Browser.Source`. Their handles are the native browser objects.

- `Browser.Image`: `Element`, `Bitmap` and `Data` (ImageData). `byId`, `load`,
  `decode`, `data`, `dataFromView`, `pixels`, `bitmap`, `bitmapFromBytes`, `close`.
- `Browser.Video`: `Element` and `Frame` (VideoFrame). `byId`, `frame`, `clone`,
  `close`, `closed`, `info`.
- `Browser.Canvas`: `Canvas`, `OffscreenCanvas` and `BitmapRenderer`. `byId`,
  `create`, `offscreen`, `resize`, `resizeOffscreen`, `bitmapRenderer`, `present`,
  `snapshot`.
- `Browser.Source.Input` has all seven GPU image sources. `Source.info` reads the
  size and the state now; it does not prove that the source stays valid.

`load`, `decode`, `bitmap` and `bitmapFromBytes` wait in a fiber. `bitmapFromBytes` decodes
encoded image bytes (give the MIME type, for example `image/png`). Closing a bitmap or a frame closes it
for all its aliases. `present` uses the bitmap: after it, the bitmap is closed.

## Errors

Each failure that the host documents for an operation is one typed error. An
unexpected host failure stops the program; do not catch it. `Binary.shared` gives
`Err IsolationRequired` in a page that is not cross-origin isolated.

Sources: `docs/design/binary.md` §1–§5; `docs/design/browser-sources.md`;
`docs/design/webgpu.md` §3.1, §3.2; `core/Binary.beni`; `core/Binary/Atomics.beni`;
`core/Binary/Wgsl.beni`; `platforms/browser/Browser/Image.beni`, `Video.beni`,
`Canvas.beni`, `Source.beni`.
