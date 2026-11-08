## 2026-11-08 19:19 CET — WebGPU frames on the batch actions

**What I did.** Merged the reviewed compute slice (batch operations as
`Gpu.Make` actions run by a `sync` `perform`, `Result Error` batch
operations, `BatchFailed` reports, cancelled batches that reject what they
made, `WrongDevice` for another device's queue or pipeline) into the render
and frame branches. The render creations became the actions `CreateView`
and `CreateRenderPipeline`, the format checks moved to `Gpu.Formats` to
break a `Make`/`Session` import cycle, and frames now return
`Result Error` like batches. Two fixtures pin what the merge gives frames: a
cancelled frame's buffer was `ResourcePending` before and is
`ResourceRejected` now, and a submit on another device's queue was `Ok`
with one receipt before and is `WrongDevice` now.

**What I learned.** An encoding session's `uses` set from the compute
slice already records everything a command buffer names, so frame expiry
reads it instead of a second list. A reference topic of the skill stays
under 300 lines and `SKILL.md` under 8 000 bytes, so a growing area gets a
reference file of its own.
