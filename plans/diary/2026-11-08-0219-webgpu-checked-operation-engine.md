## 2026-11-08 02:19 CET — WebGPU: the checked-operation engine

**What I did.** The second half of WebGPU's foundation (#2239, `docs/design/webgpu.md` §6.1 and
the lease flag of §6.4). `Gpu.Engine.checked` makes one native call between the device's
validation, out-of-memory and internal scopes: it refuses a latched loss and a held lease
first, without waiting; opens a per-device section whose reentry is a defect; pushes the
scopes inside `Js.finally` and pops every pushed one in its finaliser, in reverse, before
anything can suspend; then waits for the pops or the device's loss. A made object is
recorded provisional, then accepted or rejected, and only an accepted one is returned. A
pop that rejects, or reports a class its filter does not, is a defect even beside an
expected failure; one that settles after the operation went on reaches the device's
sentinel. `Gpu.Device.createSampler` is the first operation over it.

The fake host gained error scopes, two sampler rules and the three error classes; the test
platform can hold pops and release them in reverse, fault each filter, make the call throw,
count native calls and take the lease. Six `browser/gpu/Checked*` fixtures: 32 pages, the
same goldens in happy-dom and in Chrome on SwiftShader, where the invalid samplers are the
device's own validation errors.

**What I learned.** A loss latched by a promise reaction is not visible after a
`Task.yieldNow`: the scheduler's queue can drain before the microtask runs, so a fixture
waits with `awaitLost` instead. The fault that replaces a pop's answer must still make the
host's pop, or a native stack would stay unbalanced.
