## 2026-11-08 16:30 CET — WebGPU canvas surfaces and frames

**What I did.** Built the second half of the WebGPU rendering slice (#2241):
`Gpu.Surface` on a canvas element and on a main-thread `OffscreenCanvas`, its
configuration and read-back, and `Gpu.Frame`, a `Gpu.Batch.run` on the
surface's device whose batch is the frame. A frame lists one receipt per
native submit; its current texture and every view of it expire with the
frame, at a reconfiguration and when the canvas changes size. The fake host
gained a `webgpu` canvas context and an `OffscreenCanvas`, and a microtask
probe that shows no microtask runs inside a frame's callback. A TEA page keeps
its `<canvas>` and draws from a command.

**What I learned.** The non-yielding host-turn section needed no new
primitive: a `sync` callback is emitted with no suspension point and the
engine already runs it inside the device's scope section, one synchronous
call. In `test-webgpu`'s headless Chrome 153 a canvas texture breaks the
device's WebGPU instance: the next `popErrorScope` and `onSubmittedWorkDone`
reject with an `OperationError`, in plain JavaScript too, so those pages are
skipped there (#2267). A browser fixture whose `update` appends to its model
meets the known v1/v2 ownership difference of entry demands and needs its line
in `tests/blackbox/ownership-v2-known.txt`. The JavaScript checker of a
sibling file rejects `class` and `async` syntax: write constructor functions
and promise chains.
