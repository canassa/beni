# Binary data and typed WebGPU sources

**Status: implementation contract, 2026-10-30; aligned with option C on
2026-11-08.** Part of #1278 and #1277. The WebGPU contract is
[webgpu.md](webgpu.md); this document owns reusable binary values and the
browser handles that form its host input unions.

## 1. Native values, inside the boundary

`core/Binary.beni` implements binary storage in beni over `Js`. Its handles
are the generated native types of `Browser.Host` ([workers.md](workers.md) §4,
[workers-native-bindings.md](workers-native-bindings.md)), not a family of
their own: `Buffer` is an alias of `Browser.Host.ArrayBuffer.ArrayBuffer`,
`SharedBuffer` of `Browser.Host.SharedArrayBuffer.SharedArrayBuffer`, and each
view constructor carries one of `Browser.Host.<Kind>Array` or
`Browser.Host.DataView`. These are ECMAScript intrinsics, not IDL: the native
catalogue publishes them as intrinsic revision 2, with no operations of their
own, so a typed native operation over them would add a reviewed row and
nothing else. Their realm set is every realm.

A Web IDL typedef or union is an ordinary beni type over native ones
(workers-native-bindings.md, *Deterministic merge and native identity*). So:

- `View` is a tagged union with one constructor per native view —
  `Int8Array`, `Uint8Array`, `Uint8ClampedArray`, `Int16Array`, `Uint16Array`,
  `Int32Array`, `Uint32Array`, `BigInt64Array`, `BigUint64Array`,
  `Float16Array`, `Float32Array`, `Float64Array`, `DataView` — each holding the
  native object itself (ArrayBufferView). `kind` reads its `ViewKind`.
- `Source` is `WholeBuffer Buffer | WholeShared SharedBuffer | ViewOf View`
  (AllowSharedBufferSource), the tagged source webgpu.md §3 asks for: it
  retains the view kind, and `sourceInfo` reads its offset, length and
  shared/non-shared backing.
- `Backing = Local Buffer | Shared SharedBuffer` selects storage for `view`.

No public operation converts to or accepts `Js.Value`. A privileged platform
can use `Js.from` on the native handle inside a constructor, or adopt an
already validated host result with `Js.to` into the constructor that names
its kind; ordinary modules cannot import `Js`. The tag is the one allocation
a view adds; the native object is never copied or wrapped further.

`ViewKind` contains every Web IDL typed array kind plus DataView. View
offsets are bytes; counts are elements, or bytes for DataView. Scalar access
offsets are bytes relative to the view, with explicit little/big endian for
multi-byte values. Every access validates current detachment and bounds,
before invoking a host operation. Because a `Source` can be built from any
native handle, every operation that takes one checks its backing then:
`sourceInfo`, `toList`, `copy`, `copyInto` and each scalar access. No
detached view can be mistaken for an empty live view.

Resizable ArrayBuffer and growable SharedArrayBuffer backing are refused by
every entry point, even when it has never resized and the current view is in
bounds. WebGPU's AllowShared does not grant AllowResizable (Web IDL
[buffer-source conversions](https://webidl.spec.whatwg.org/#es-buffer-source-types)).
`Binary` itself only allocates fixed storage; a host API can hand back the
other kind (#1268).

`transfer` is ArrayBuffer.prototype.transfer in this realm: it moves the
storage to a new fixed buffer of the same length, and the original and every
view of it become detached. **Moving storage to or from a worker is not part
of this module yet**; it waits for the native transfer families of #1299.

## 2. Numbers and failure predicates

CPU allocation sizes and view indices are nonnegative safe integers, the
ECMAScript ToIndex domain. U32/I32 values are checked in their full exact Number
ranges. `Word64` stores two validated unsigned 32-bit words; it never passes
through an imprecise Number. Native BigInt64/BigUint64 views remain available as
source variants and exact scalar word access preserves all their bits.

Each documented failure is its own constructor of `Binary.Error`; every other
host failure is a defect and is thrown, never typed:

| Operation | Expected host failure | Error |
|---|---|---|
| `allocate`, `shared` | RangeError after the size checks (allocation) | `AllocationFailed bytes` |
| `shared` | `crossOriginIsolated` is false | `IsolationRequired` |
| `shared`, `view`, Float16 access | constructor or method absent | `Unsupported name` |
| `transfer` | RangeError (allocation) | `AllocationFailed bytes` |
| `transfer` | TypeError after the detached and shared checks: storage with a detach key, such as WebAssembly memory | `TransferDenied` |
| every operation | detached storage, checked first | `Detached` |
| every operation | resizable or growable storage, checked first | `ResizableBacking` |

Sizes, ranges, alignment and integer values are checked before any host call
(`InvalidSize`, `InvalidRange`, `Misaligned`, `InvalidInteger`), and
`word64ToInt`/`word64ToSignedInt` refuse a rounded answer (`PrecisionLost`).
A view constructor has no residual expected failure after these checks.
Detachment is read from ArrayBuffer.prototype.detached; on a host without
that getter, from the one TypeError a zero-length view of a detached buffer
throws. Float reads/writes retain host IEEE behavior, including
NaN/infinity; GPU descriptor numeric validation is a separate concern.

Shared storage is explicit and never portrayed as immutable or implicitly
copied. `Binary.Atomics.access` runs native Atomics on the integer views
(`Int8Array` through `Uint32Array`, `BigInt64Array`, `BigUint64Array`; the
others are `InvalidView`), with checked indices and integer values; BigInt
views take and give exact `Word64` pairs. Ordinary scalar accesses have their
native non-atomic semantics. `Atomics.wait` and `notify` are not offered:
they need a worker to wait in (#1299).

## 3. Browser source ownership

`Browser.Image`, `Browser.Video` and `Browser.Canvas` provide every WebGPU
copy source arm, as the generated native types `HTMLImageElement`,
`ImageBitmap`, `ImageData`, `HTMLVideoElement`, `VideoFrame`,
`HTMLCanvasElement`, `OffscreenCanvas` and `ImageBitmapRenderingContext` of
`Browser.Host` ([browser-sources.md](browser-sources.md)). They classify the
documented failure at each constructor/load/decode call, preserve close
state, and expose the exact native objects to privileged GPU code without
public raw conversion. Native source readiness, dimensions and origin-clean
checks remain observable at the native GPU operation; wrappers do not invent
origin status.

## 4. Verification

`tests/corpus/run/BinaryStorage` executes actual ArrayBuffer/DataView/typed
array operations on Node: every scalar width in both byte orders, exact
64-bit words, every view kind, overlapping copies, transfer and the
detachment every alias then sees, and each named failure.
`run/BinaryNative` hands Binary storage only a host makes — resizable,
growable and WebAssembly memory — and shows that an undocumented failure is
thrown, not typed. `run/BinaryAtomicWords` and `run/WgslBinaryLayout` cover
§2's atomics and §5. `browser/tea/WebGpuInputs` exercises the sources in
headless Chrome (`zig build test-browser`); happy-dom has none of them.
Mocks and happy-dom do not establish WebGPU or WebCodecs conformance.

## 5. Explicit WGSL layout

Binary.Wgsl implements host-shareable numeric, vector, column-major matrix,
array, runtime-array and structure layouts from WGSL 14.4. It exposes member
offsets and array/matrix strides; callers describe the shader's actual type and
explicit member align/size attributes. It never silently pads an incompatible
shader declaration to another layout. Legacy uniform constraints are validated
separately from standard/storage layout, including the standard-layout language
extension. Bool is not host-shareable, and atomics are integer layouts rather
than vector components. Encoding and decoding use little-endian numeric storage;
raw payload bits remain available through Binary scalar/Word64 access.

The source of the byte formulas and the uniform validation rules is
https://www.w3.org/TR/2026/CRD-WGSL-20261026/#memory-layout . Runtime arrays may
only appear directly or as a structure's final direct member. Encoding a fresh
buffer validates value shapes first and zero-initializes padding; writing into
an existing view does not overwrite inaccessible padding. Checked size arithmetic
refuses CPU sizes beyond ToIndex instead of silently rounding offsets.
