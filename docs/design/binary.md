# Binary data and typed WebGPU sources

**Status: implementation contract, 2026-10-30.** Part of #1278 and #1277.
The WebGPU contract is [webgpu.md](webgpu.md); this document owns reusable
binary values and the browser handles that form its host input unions.

## 1. Native values, inside the boundary

`core/Binary.beni` implements binary storage in beni over `Js`. `Buffer`,
`SharedBuffer`, `View` and `Source` are opaque foreign types whose representation
is the corresponding native ArrayBuffer, SharedArrayBuffer, ArrayBufferView,
and AllowSharedBufferSource object. No public operation converts to or accepts
`Js.Value`. A privileged platform can use `Js.from` on a typed handle, or adopt
an already validated host result internally. This preserves native identity;
ordinary modules cannot manufacture a handle or import `Js`.

`Backing = Local Buffer | Shared SharedBuffer` selects storage. `ViewKind`
contains every Web IDL typed array kind plus DataView. View offsets are bytes;
counts are elements, or bytes for DataView. Scalar access offsets are bytes
relative to the view, with explicit little/big endian for multi-byte values.
Every access validates current detachment and bounds, before invoking a host
operation. A native transfer invalidates the original buffer and all aliases;
no detached view can be mistaken for an empty live view.

`bufferSource`, `sharedSource` and `viewSource` make WebGPU-admissible sources.
Both construction and `sourceInfo` reject resizable ArrayBuffer or growable
SharedArrayBuffer backing, even when it has never resized and the current view
is in bounds. WebGPU's AllowShared does not grant AllowResizable (Web IDL
[buffer-source conversions](https://webidl.spec.whatwg.org/#es-buffer-source-types)).

## 2. Numbers and failure predicates

CPU allocation sizes and view indices are nonnegative safe integers, the
ECMAScript ToIndex domain. U32/I32 values are checked in their full exact Number
ranges. `Word64` stores two validated unsigned 32-bit words; it never passes
through an imprecise Number. Native BigInt64/BigUint64 views remain available as
source variants and exact scalar word access preserves all their bits.

A buffer allocation catches only its native RangeError after size validation,
and returns `AllocationFailed bytes`. Missing host constructors/methods return
`Unsupported capability`. Bounds, alignment, invalid integer values, detached
storage and non-fixed backing have named errors. A view constructor has no
residual expected failure after these checks; an unexpected native failure is
a defect. Float reads/writes retain host IEEE behavior, including NaN/infinity;
GPU descriptor numeric validation is a separate concern. Float16 operations and
views detect their particular host method/constructor support explicitly.

Shared storage is explicit and never portrayed as immutable or implicitly
copied. Atomic integer operations use native Atomics with checked kinds and
ranges; ordinary scalar accesses have their native non-atomic semantics.

## 3. Browser source ownership

Browser.Image, Browser.Video and Browser.Canvas provide typed native handles
for every WebGPU copy source arm. They classify the documented failure at each
constructor/load/decode/transfer call, preserve source close/transfer state,
and expose the exact native objects to privileged GPU code without public raw
conversion. Native source readiness, dimensions and origin-clean checks remain
observable at the native GPU operation; wrappers do not invent origin status.
Their detailed source/error contracts are specified alongside implementation.

## 4. Verification

Black-box programs execute actual ArrayBuffer/DataView/typed-array operations,
round-trip bytes and exact 64-bit words, and test all view kinds, numeric/bounds
failures, detachment and fixed backing rejection. Browser tests exercise real
source acquisition/close/transfer and preserve expected-vs-defect behavior.
Mocks and happy-dom do not establish WebGPU or WebCodecs conformance.
