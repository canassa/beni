## 2026-11-08 15:22 CET — WebGPU compute, encoding and batches

**What I did.** Built the compute half of the WebGPU compute slice (#2240)
on top of the buffer half: shader modules and their compilation messages,
compute pipelines (synchronous and asynchronous), bind group and pipeline
layouts, bind groups, textures and query sets, `Gpu.Encode.run` with the
encoder and compute-pass commands (every copy, clears, query resolves,
immediate data, debug groups), `Gpu.Batch`, and `Gpu.Queue.writeTexture`.
Each creation is prepared once in a private `Gpu.Make` and runs as its own
checked operation or inside a batch; a private `Gpu.Session` holds the
encoding session that latches its first failure. Under `test-webgpu` a
compute shader's answer and a texture round trip match words written out
by hand; all 82 `browser/gpu/` runs pass natively.

**What I learned.** A record field cannot hold a `sync` function type, so a
prepared operation keeps its functions as `Js` values and calls them with
`Js.apply`. A provisional object needs no batch token to be usable inside
its batch: a batch is synchronous, so a live batch is the only code that can
be running. `git stash` is shared by every worktree of the clone, and a pop
that conflicts leaves the untracked files in the stash's third parent. The
ownership checker v2 disagrees with v1 on a `Ref` captured by a GPU
callback in a fixture, so the fixtures keep their notes in the test host
instead.
