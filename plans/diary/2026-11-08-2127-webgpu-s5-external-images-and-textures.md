## 2026-11-08 21:27 CET — WebGPU S5: external images and external textures

**What I did.** Built S5 of `docs/design/webgpu.md` (#2243) on top of S4's branch:
`Gpu.Queue.copyExternalImageToTexture` with its batch and diagnostics forms,
`Gpu.Batch.importExternalTexture` and `Gpu.Frame.importExternalTexture`, `Gpu.ExternalTexture`,
five new `SourceError` arms for the source states HTML's usability check reads, and the
specification's `[[expired]]` for external textures in the engine's record. Twenty-three
`browser/gpu/External*` fixtures: every copy-source arm and both import arms compared by
read-back pixels in Chrome (all exact except video, within 12), every ledger §6 row, the
refusals, and four defects. The test host gained image and video elements, fakes of the media
classes happy-dom lacks, and the driver a `/_media/image.bmp` route so a real cross-origin
image taints in Chrome.

**What I learned.** A video's chroma is subsampled, so an 8×8 video blurs every quadrant edge:
the fixtures show each pixel as an 8×8 block and read block centres. The driver's step settle
does not wait for image or video loads; the test host counts them as pending, as the driver
counts a native WebGPU promise. A `_` partial application evaluates its arguments when it is
called, so a suspending argument inside a `sync` batch callback is refused — bind it first.
