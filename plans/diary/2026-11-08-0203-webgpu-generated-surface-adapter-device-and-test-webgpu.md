## 2026-11-08 02:03 CET — WebGPU: generated surface, adapter, device and test-webgpu

**What I did.** The first half of WebGPU's foundation (#2239, `docs/design/webgpu.md` §10 S1).
The native-bindings tool gained a WebGPU emitter (`src/native/Gpu.zig`, `zig build gpu-bindings`):
from `webgpu.idl` in the pinned @webref/idl archive it writes the 36 `Browser.Host.GPU*` type
modules and the seven host types GPU dictionaries name into core, and `Gpu.Types`, `Gpu.Flags`,
`Gpu.Limits` and the engine's `Gpu.Native` into the browser platform. It fails when a WebGPU
declaration is exposed other than `(Window, Worker)`. `tests/gpu_bindings.zig` runs in
`test-blackbox`: the committed files against the generator, the census of every dictionary,
enum, constant and union, the exposure assertion, and no `Js` in a public signature. By hand:
`Gpu.Handle`, `Gpu.Scalar`, `Gpu.Error`, `Gpu.Feature`, `Gpu.WgslFeature`, the engine
(`Gpu.Engine`: the `WeakMap` state table, promise waits, the loss latch, a per-device sentinel
fiber for defects nobody waits for), and `Gpu`, `Gpu.Adapter`, `Gpu.Device`. `browser-tea`
re-exports the public ones.

Ten `browser/gpu/` fixtures run on a test platform, `tests/platforms/gpu`, whose host is a fake
`navigator.gpu` in the gates and Chrome's own under the new `zig build test-webgpu`. Every fault
the S1 ledger rows name is injected by wrapping the host's method; the defects (an undocumented
rejection, a spoofed `OperationError`, an unlisted `DOMException`, a loss reason outside the pin,
a rejected `lost`) stop the page. The same goldens pass in happy-dom and in Chrome 153 on
SwiftShader: 20 of 20 pages.

**What I learned.** dagon's Chromium gives a real WebGPU adapter with `--enable-unsafe-webgpu
--use-webgpu-adapter=swiftshader`; the profile's socket path must stay short, so `TMPDIR` goes
through a symlink. A native WebGPU promise settles in real time, which the driver's `settle`
never waited for: under `--webgpu` the prelude counts the pending ones. A scalar constructor
cannot return `Gpu.Error.InputError` as §3.1 says, because `Gpu.Error` names `Gpu.Types` and
`Gpu.Types` names `Gpu.Scalar`; it returns `Gpu.Scalar.DomainError`, an owner question.
Sibling JavaScript may not use class bodies or bare globals (check 3 reads them as unbound
names). The generated beni is not held to `beni fmt`: matching its width rules from a
generator is fragile.
