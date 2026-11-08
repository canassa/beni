## 2026-11-08 17:13 CET — WebGPU frame and surface review fixes

**What I did.** Answered the independent review of the WebGPU canvas PR
(#2269), after merging the runner fix that lets `test-webgpu`'s Chrome draw
into a canvas (#2270) and the render review fixes. A frame that gets the
canvas texture an earlier, failed frame rejected now takes it as its own
(the second frame's view was `ResourceRejected` before); command buffers,
bundles and bind groups hold the frame textures they name and expire with
them (both were submitted and bound before); every `Browser.Canvas.resize`
counts; a configuration refused before the native call or overtaken by an
`unconfigure` leaves the surface as it was; `getConfiguration` returns a
`Result`. The fake host models context kinds and size writes, and the
microtask probe now runs in Chrome too.

**What I learned.** A command buffer's record is made after its encoding
session ends, so what it holds is kept in a table of its own keyed by the
native object. A `perl` replacement with `$1` followed by a digit reads as
a later group: write `${1}`.
