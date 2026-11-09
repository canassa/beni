# Binary storage and browser sources

`Binary` is in core. It works on every host that has the native type.

## Storage and views

- `Binary.Buffer` is the native `ArrayBuffer`. `Binary.SharedBuffer` is the native
  `SharedArrayBuffer`. Make them with `allocate` and `shared`. Both are fixed length.
- `Binary.View` has one constructor for each native view: `Int8Array`, `Uint8Array`,
  `Uint8ClampedArray`, `Int16Array`, `Uint16Array`, `Int32Array`, `Uint32Array`,
  `BigInt64Array`, `BigUint64Array`, `Float16Array`, `Float32Array`, `Float64Array`
  and `DataView`. Make a view with `view`, a `Backing` (`Local` or `Shared`), a
  `ViewKind` and a `ByteRange` (`{ byteOffset, byteLength }`, in bytes;
  `byteLength = Nothing` is the rest). `Binary.whole` is all of it. `dataView` makes
  a DataView over all of the storage. `kind` gives the kind of a view.
- `Binary.Source` is `WholeBuffer`, `WholeShared` or `ViewOf`. `sourceInfo` gives its
  byte offset, byte length, element length and if it is shared.
- All offsets, lengths and ranges in errors are bytes.
- A scalar read or write offset is in bytes, from the start of the view. Give
  `Binary.Little` or `Binary.Big` for a value wider than one byte.
- Each function has its own error type with only the failures it can have:
  `AllocationError`, `SharedError`, `ViewError`, `AccessError`, `WriteError`,
  `Float16Error`, `CopyError`, `ListError`, `TransferError`, `WordError`.
- Each operation checks the storage first. Detached storage is `Detached`.
  Resizable or growable storage is `ResizableBacking`, also when it is in bounds
  (`BackingError`, inside the other error types).
- Shared storage is found in every realm, also storage from another realm. On a
  host with the ES2024 `detached` and `growable` properties, this check reads two
  properties and throws nothing.
- `transfer` moves the storage to a new buffer in the same realm. After it, the old
  buffer and all its views are detached. Moving storage to a worker is not available.

```beni platform=node
import Binary
import Node exposing (Program)


main : Program
main =
    case ( Binary.allocate 8, Binary.word64 4294967295 1 ) of
        ( Ok buffer, Ok exact ) →
            Node.print (Debug.toString (bytes buffer exact))
        _ →
            Node.print "setup failed"


bytes : Binary.Buffer, Binary.Word64 → Result Binary.AccessError (List Int)
bytes buffer exact =
    view = Result.mapError (Binary.dataView (Binary.Local buffer)) Binary.AccessBacking?
    Binary.writeWord64 view 0 Binary.Little exact?
    Result.mapError (Binary.toList (Binary.ViewOf view)) Binary.AccessBacking
```

## Exact 64-bit words

`Word64` keeps two exact unsigned 32-bit words. `word64ToInt` and
`word64ToSignedInt` give `Err PrecisionLost` when the `Int` cannot hold the exact
value. Do not write a large decimal `Int` and expect the lost bits to come back.
`readWord64` and `writeWord64` read and write all 64 bits.

## Atomics

`Binary.Atomics.access` runs a native atomic operation on an integer view at an
element index. `BigInt64Array` and `BigUint64Array` take and give `Words`. The other
integer views take and give `Number`; a `Number` outside the view's element range
(for example 300 on a `Uint8Array`) is `Err InvalidValue`. Other views are
`Err InvalidView`. Ordinary
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
  `decodeElement`, `data`, `dataFromView`, `pixels`, `bitmap`, `bitmapFromBytes`, `close`.
- `Browser.Video`: `Element` and `Frame` (VideoFrame). `byId`, `frame`, `clone`,
  `close`, `closed`, `info`.
- `Browser.Canvas`: `Canvas`, `OffscreenCanvas` and `BitmapRenderer`. `byId`,
  `create`, `offscreen`, `resize`, `resizeOffscreen`, `bitmapRenderer`, `present`,
  `snapshot`. A canvas
  dimension above 2^31 − 1 (an offscreen one above 2^53 − 1) is `InvalidDimension`.
- `Browser.Source.Input` has all seven GPU image sources. `Source.info` reads the
  size and the state now; it does not prove that the source stays valid.

`load`, `decodeElement`, `bitmap` and `bitmapFromBytes` wait in a fiber. `bitmapFromBytes` decodes
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
