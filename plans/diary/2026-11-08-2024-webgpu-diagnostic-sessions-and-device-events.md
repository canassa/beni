## 2026-11-08 20:24 CET — WebGPU diagnostic sessions and device events (S4)

**What I did.** Built #2242 (lane gpu-s4): `Gpu.Diagnostics` (`run`, `nested`, `pushErrorScope`,
`popErrorScope`, `state`, `DiagnosticReport`), the forwarding modules
`Gpu.Diagnostics.{Device,Texture,ComputePipeline,RenderPipeline,Queue,Buffer,Surface,Encode,Batch,Frame}`,
`Gpu.Error.GpuError`, `DiagnosticError` and `DeviceEvent`, `Gpu.Device.eachEvent` and `onEvent`,
and the uncaptured-error listener. The engine's `checkedIn`/`checkedAwaitIn` take a session or
null, so every public run (`Make.shaderModuleIn`, `batchIn`, `frameIn`, `Memory.mapIn`, …) and
its forwarding form share one body. Eighteen fixtures under `tests/corpus/browser/gpu/`;
`webgpu.md` §6.4 has the as-built note, `skills/beni/references/webgpu.md` the rules and the
livelock hazard.

**What I learned.** A throw in a suspendable callback does not run `Task.onExit`'s finaliser at
the throw: the runtime's teardown, one task later, cancels every fiber and runs it then — a
fixture must `advance` the virtual clock to see it. `Buffer.withMapped` written through a
helper that hands the mapping back as `Js.Value` sent the ownership v2 checker over its limit
on `MapLifecycle`; the typed form kept it in budget. A listener added with `addEventListener`
anywhere in a platform needs a P-sync row and a pinned body. Gates launched from a non-login
ssh shell lose `sleep` on the child processes' PATH (`run/ChildProcess*`): use `bash -l`.
