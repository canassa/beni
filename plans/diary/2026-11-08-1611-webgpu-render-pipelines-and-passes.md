## 2026-11-08 16:11 CET — WebGPU render pipelines and passes

**What I did.** Built the first half of the WebGPU rendering slice (#2241,
S3a) on top of the compute slice: texture views, render pipelines (sync and
async), render passes with every attachment form, render bundles, occlusion
queries and indirect draws, with their `Gpu.Batch` and `Gpu.Encode` forms.
The binding, debug and render mixins live once in a private `Gpu.Commands`
that compute passes, render passes and bundle encoders share. Under
`test-webgpu`, multi-pass, indirect, depth, stencil, 4× MSAA resolve, MRT,
bundle, batch and occlusion scenes give exactly the pixels worked out by hand
from the rectangles the shader draws; the MSAA edge pixel resolves to half
red, as two of the four standard sample positions predict.

**What I learned.** A `?` cannot stand inside a lambda, and user code cannot
write `sync`, so a fixture's encoding callbacks are named functions applied
with `_`. A vertex-only render pipeline with no depth state is invalid in
Chrome. The platform's module list is fixed when the watcher starts: a new
`.beni` file under `platforms/` needs a watcher restart before the build sees
it. `test-webgpu` blesses a `.webgpu-expected` only when the file exists, so
create it empty first.
