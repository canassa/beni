## 2026-11-08 13:37 CET — WebGPU buffers, mapping and the queue

**What I did.** Built the buffer half of the WebGPU compute slice (#2240):
`Gpu.Device.createBuffer`/`createMappedBuffer`, `Gpu.Buffer` (map, the
mapping from creation, mapped ranges, `withMapped`, unmap, destroy),
`Gpu.MappedRange` (every width, exact 64-bit words, byte copies),
`Gpu.Queue` (`writeBuffer`, `submit` with one receipt per native submit,
`onSubmittedWorkDone`) and `Gpu.Submission.done`. The engine gained
`checkedMaking` (a made object with state of its own, released when
rejected), `checkedAwait` (a scoped call that answers with a promise, whose
rejection joins the scopes' observations) and pending outcomes for receipts.
The gates' fake host learned buffers and the queue, with faults for every
ledger row; nine new `browser/gpu/` pages. Under `test-webgpu` the native
SwiftShader adapter gives the same transcripts as the fake, except the
growable `SharedArrayBuffer` case, which a page without cross-origin
isolation cannot make (a `.webgpu-expected`).

**What I learned.** `Js.call` and `Js.array` take only list literals, so an
optional native argument is passed as `undefined`, which Web IDL reads as
omitted. A map's generation must change before the native call that ends
it, or a reaction that runs between the two sees a live mapping. A held
host promise in the fake must be marked handled, or its rejection is
unhandled while the fixture holds it. The `--watch` build does not see new
`.beni` files of a platform until it restarts.
