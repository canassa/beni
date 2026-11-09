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

`ViewKind` contains every Web IDL typed array kind plus DataView. `view` takes
a `ByteRange` — `{ byteOffset, byteLength : Maybe Int }`, both in bytes,
`Nothing` for the rest of the storage — so a call site cannot mix bytes and
elements; the offset must be a multiple of the element size and the length a
whole number of elements (`Misaligned`). `whole` is offset 0, the rest, and
`dataView` a DataView over all of the storage. Scalar access offsets are
bytes relative to the view, with explicit little/big endian for multi-byte
values. Every range a failure reports is in bytes: offset, length, bytes
available. Every access validates current detachment and bounds, before
invoking a host operation. Because a `Source` can be built from any native
handle, every operation that takes one checks its backing then:
`sourceInfo`, `toList`, `copy`, `copyInto` and each scalar access. No
detached view can be mistaken for an empty live view.

Shared storage is recognised in a way that works across realms, never by
`instanceof` (the owner's decision, 2026-11-09). ES2024 gives a genuine
ArrayBuffer of any realm a `detached` getter and shared storage a `growable`
one, and neither has the other's, so on a current host two property reads
decide and nothing throws. Only a host with neither, older than ES2024, falls
back to a brand check: the SharedArrayBuffer.prototype `byteLength` getter,
which throws a TypeError for anything else; only that TypeError is caught. A
scalar access does not ask at all: its checks (detachment, fixed backing,
bounds) do not depend on the answer, and a DataView view is used as it is,
with no second DataView or record made per access (2026-11-09;
`run/BinaryAccessCost` counts both).

Every native constructor is named by a literal `Js.global` per view kind, so
a worker build proves each name on its realm's global object (workers.md §4,
*The worker global allow-list*); `browser/dedicated/BinaryInWorker` keeps
`view` and `Wgsl.encode` in a dedicated worker.

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

**Each function's error type names only the failures it can have** (amended
2026-11-08; rule 9, webgpu.md §3.2). Every other host failure is a defect
and is thrown, never typed:

| Type | Constructors | Returned by |
|---|---|---|
| `BackingError` | `Detached`, `ResizableBacking` (checked before any host call) | `backing`, `byteLength`, `dataView`, `sourceInfo`, `toList` |
| `AllocationError` | `InvalidSize bytes` (outside ToIndex), `AllocationFailed bytes` (the constructor's RangeError) | `allocate` |
| `SharedError` | `SharedAllocation AllocationError`, `IsolationRequired` (`crossOriginIsolated` is false), `NoSharedMemory` (no constructor) | `shared` |
| `ViewError` | `ViewBacking`, `ViewOutOfRange offset length available`, `Misaligned value elementSize`, `NoViewConstructor name` (Float16Array absent) | `view` |
| `AccessError` | `AccessBacking`, `OutOfBounds offset length available` | reads, float writes, word access, `copyInto` |
| `WriteError` | `WriteAccess AccessError`, `InvalidValue value minimum maximum` | integer writes |
| `Float16Error` | `Float16Access AccessError`, `NoFloat16` (no DataView Float16 methods) | `readF16`, `writeF16` |
| `CopyError` | `CopyBacking`, `CopyAllocation` | `copy` |
| `ListError` | `NotAByte value`, `ListAllocation` | `fromList` |
| `TransferError` | `TransferBacking`, `NotTransferable` (shared storage, refused first; or the TypeError of storage with a detach key, such as WebAssembly memory), `TransferAllocation bytes` (RangeError), `NoTransfer` (no ArrayBuffer.prototype.transfer) | `transfer` |
| `WordError` | `InvalidWord value minimum maximum`, `PrecisionLost` | `word64` and its conversions |

`word64ToInt`/`word64ToSignedInt` refuse a rounded answer (`PrecisionLost`).
A view constructor has no residual expected failure after these checks.
Detachment is read from ArrayBuffer.prototype.detached; on a host without
that getter, from the one TypeError a zero-length view of a detached buffer
throws. Float reads/writes retain host IEEE behavior, including
NaN/infinity; GPU descriptor numeric validation is a separate concern.

Shared storage is explicit and never portrayed as immutable or implicitly
copied. `Binary.Atomics.access` runs native Atomics on the integer views
(`Int8Array` through `Uint32Array`, `BigInt64Array`, `BigUint64Array`; the
others are `InvalidView`), with checked indices. A Number must be an integer
in the view's element range, as `writeU8` refuses 256 (`InvalidValue`; decided
2026-11-08), and BigInt views take and give exact `Word64` pairs. Ordinary scalar accesses have their
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

Its failures are three types (2026-11-08): `LayoutError` from the layout
constructors, `UniformError` from `uniform`, and `CodecError` from `encode`,
`write` and `decode`, which wraps `Binary.AccessError` and
`Binary.AllocationError`. `uniform` checks member offsets against
RequiredAlignOf(T, uniform), array strides, and the structure-gap rule;
WGSL 12.1 exempts the uniform address space from the `` multiple rule,
so a member's `` is checked only as a power of two at least AlignOf(T).

## 6. Checked regions

**Status: decided 2026-11-09** — the owner took every §8 choice as proposed.
Built: `core/Binary/Region.beni` (fixtures `run/BinaryRegion`,
`check/bad/BinaryRegionReadOnlyWrite`, the region lines of
`run/BinaryNative` and `run/BinaryAccessCost`); `MappedRange.region` and
`readRegion` (`browser/gpu/MappedRegion`); and `Wgsl.encode`, `write` and
`decode` on one region per call (§8, choice 8; `run/BinaryAccessCost` counts
the `detached` reads of a 256-element array: 257 and 772 before, 3 and 2).

§1 makes every scalar access validate the backing again because a `View` or
a `Source` can be built from any native handle. After §1's 2026-11-09 change a
scalar access on a `View` costs three getter reads (`buffer`, `detached`,
`resizable`/`growable`), the view's `byteLength`, the bounds and the value; on
a view that is not a DataView it also makes a DataView. A **region** pays the
facts that cannot change once, when it is made, and keeps the per-access work
to one length read, the bounds and the value.

`core/Binary/Region.beni` adds an opaque type:

```text
pub opaque type Region mode      -- mode is ReadWrite or ReadOnly, a phantom
pub type ReadWrite = ReadWrite   -- (empty marker types; §8 Q2)
pub type ReadOnly = ReadOnly

region   : View → Result BackingError (Region ReadWrite)
readOnly : Region mode → Region ReadOnly
view     : Region mode → View          -- the View it was made from, no copy
byteLength : Region mode → Result AccessError Int   -- Detached when detached
sourceInfo : Region mode → Result AccessError SourceInfo
```

What a region holds and checks:

- **When it is made**: the view's backing is checked as §1 checks it
  (`Detached`, `ResizableBacking`). Resizable and growable backing are refused,
  so the view's byte length can never change again except to 0 by detachment;
  shared storage is decided once and kept (`sourceInfo` of the region reads
  it from there). It holds a DataView over exactly the view's bytes (the view
  itself when it is one) and a Uint8Array over the same bytes, the *probe*.
- **Per access**: read the probe's `byteLength`, check the offset and width
  against it (`offset ≥ 0` and `offset ≤ length − width`: an `Int` is
  integral, and NaN or an infinity fails both), check the value (integer
  writes), call the DataView method. A
  typed array's `byteLength` is 0, with no throw, once its storage is
  detached, so a detached region fails the bounds check before any host call
  can throw. Only on that failure path does the access read `detached`
  (§1's way) and return `Detached` rather than `OutOfBounds`. A detached
  region is therefore never a silent wrong answer and never caught: nothing
  in it throws. Detachment cannot happen between the check and the host call:
  every way storage detaches (`transfer`, a structured-clone transfer, a GPU
  unmap) is a synchronous call on the region's own thread, and shared storage
  never detaches.
- **Errors** name only what can happen after construction:

  | Type | Constructors |
  |---|---|
  | `Region.AccessError` | `Detached`, `OutOfBounds offset length available` |
  | `Region.WriteError` | `WriteAccess Region.AccessError`, `InvalidValue value minimum maximum` |
  | `Region.Float16Error` | `Float16Access Region.AccessError`, `NoFloat16` |

  `ResizableBacking` is not among them: the region refused it when it was made.

Operations, with `Binary`'s names, widths, byte offsets and explicit
`Endian`: `readI8` … `readF64`, `readF16`, `readWord64` take `Region mode`;
`writeI8` … `writeF64`, `writeF16`, `writeWord64` take `Region ReadWrite`. A
`Region ReadOnly` has no write at all, so a read-only mapping cannot be
written by mistake (the check `MappedRange` makes per access today,
`ReadOnlyMapping`, becomes a type).

**Platform code that wraps host objects.** A privileged platform makes a
region from the native view it already adopts: `Gpu.MappedRange` gains

```text
MappedRange.region : Handle.MappedRange → Result InputError (Region ReadWrite)
                                      -- ReadOnlyMapping for a read mapping
MappedRange.readRegion : Handle.MappedRange → Result InputError (Region ReadOnly)
```

which check the mapping's liveness once (`ResourceExpired`) and the mode once.
Ending a mapping detaches its ArrayBuffer (WebGPU `unmap`), so a region kept
past it gets `Detached`, which the range's own functions report as
`ResourceExpired`; a fake host used by tests must detach on unmap the same way
(`tests/platforms/gpu`). `MappedRange`'s existing per-access functions stay.

## 7. Bulk operations

**Status: decided 2026-11-09** (§8); built the same day in `core/Binary.beni`
and `core/Binary/Region.beni` (fixtures `run/BinaryBulk` and the bulk line of
`run/BinaryAccessCost`). Each call checks once — backing (or, on a region,
the backing once per call: a region refused resizable storage, so only
detachment can fail it), the whole byte range, every value — and then runs
at host speed. A call that fails writes nothing: values are validated before
the first byte is written.

On `View` (backing checked per call, as §1) and on `Region` (§6), with the
same names in both modules:

```text
fill      : v, ByteRange, Int → Result WriteError ⊤
            -- every byte of the range set to one byte value (Uint8Array.fill)
copyWithin: v, Int (to), ByteRange (from) → Result AccessError ⊤
            -- overlapping ranges copy as through a temporary (copyWithin)
copyInto  : v, Int, Source → Result AccessError ⊤      -- exists on View (§1)
writeU8s, writeI8s, writeU16s, writeI16s, writeU32s, writeI32s
          : v, Int (offset), Endian, List Int → Result BulkWriteError ⊤
writeF16s : v, Int, Endian, List Float → Result Float16Error ⊤
writeF32s, writeF64s
          : v, Int, Endian, List Float → Result AccessError ⊤
writeWord64s : v, Int, Endian, List Word64 → Result AccessError ⊤
readU8s, readI8s, readU16s, readI16s, readU32s, readI32s
          : v, Int (offset), Int (count), Endian → Result AccessError (List Int)
readF16s  : v, Int, Int, Endian → Result Float16Error (List Float)
readF32s, readF64s
          : v, Int, Int, Endian → Result AccessError (List Float)
readWord64s : v, Int, Int, Endian → Result AccessError (List Word64)

BulkWriteError = BulkAccess AccessError
               | InvalidValueAt Int Int Int Int   -- index, value, minimum, maximum
```

Each module has its own `BulkWriteError` over its own `AccessError`, as it
has its own `WriteError`. The error of a float or word write is that of the
scalar write it repeats: no value can be refused. (`Endian` is left out for
the one-byte forms.) On a region, every write (`fill`, `copyWithin`,
`copyInto`, `write…s`) takes `Region ReadWrite`. Lengths are in elements,
every range a failure reports in bytes, as §1. An integer list with a value
out of range is `InvalidValueAt index value minimum maximum` for the first
such element (§8 Q5). Where the offset is aligned, the host has the typed
array, and the endianness is the host's, the implementation uses that typed
array: one `set` for a write, and for a read one typed array copied by index
into an array made at its length (`Array.from` took eight times as long for a
million floats); otherwise a DataView loop after the single check. Both give the same bytes; the choice is not observable.
A list reaches the host as a plain array (a pattern's `rest` view gives its
own, `backend.md` §4).

## 8. Choices for §6–§7 — decided 2026-11-09

The owner took every choice below as proposed (2026-11-09): a new
`Binary.Region` module; read-only as the phantom mode; the names `Region`,
`region`, `readOnly`; Float16 availability checked per call; a bulk integer
failure names its index (`InvalidValueAt index value minimum maximum` in a
`BulkWriteError`); a `List` in and out; no element-indexed access; `Wgsl`
makes one region per call internally and `Atomics` stays on `View`. The
questions as they were put:

1. **A region type, or change `View`'s scalar functions?** Proposed: a new
   `Binary.Region` module beside them, so no caller changes and a hot loop
   switches by making a region once. The alternative makes every scalar
   function take a region and removes the per-access backing check from
   `Binary` itself (breaking `Wgsl`, `Atomics`, `MappedRange` and every user).
2. **Read-only as a phantom mode** (`Region ReadOnly`/`Region ReadWrite`), or
   two opaque types, or no read-only region (keep `ReadOnlyMapping` per access
   in `MappedRange`).
3. **Names.** `Region` / `region` / `readOnly`; alternatives `Checked`,
   `Cursor`, `Fixed`.
4. **Float16 availability**: checked per call (as now, one `typeof`), or once
   when the region is made (`region` would then need a `Float16Error`-like
   failure only for F16 users; proposed: per call).
5. **Bulk integer failure**: add the index (`InvalidValueAt index value minimum
   maximum`, a new constructor in a new `BulkWriteError`), or reuse
   `InvalidValue` without it.
6. **Bulk shape**: a `List` in and out (proposed; lists are arrays, so one
   `set` call), or a generator `(Int → number)` that avoids building the list,
   or both. The texture's scattered read-modify-write gains nothing from bulk;
   §6 is what serves it.
7. **Element-indexed access** on typed views (`Float32Array` index `i`, host
   byte order) is not proposed: `Binary` keeps byte offsets and explicit
   endianness. Say if it is wanted.
8. **Atomics and Wgsl**: `Binary.Wgsl.write`/`decode` would make one region per
   call internally (no API change); `Binary.Atomics` stays on `View`.
