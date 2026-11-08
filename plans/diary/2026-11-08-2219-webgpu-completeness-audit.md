## 2026-11-08 22:19 CET — WebGPU completeness audit: coverage gate, CTS edges, differential harness

**What I did.** Slice S6 of WebGPU (#2244). Rewrote
`docs/design/research/webgpu/coverage.md` so every IDL declaration, member,
overload and applied mixin member has a row bound to public declarations and
a fixture, or to a later slice listed at its top, and added
`tests/gpu_coverage.zig` (in `test-blackbox`, so in the gates) that reads the
pinned IDL through the native-bindings catalogue and fails on a missing,
unknown, unbound or unbacked row; a test breaks rows on purpose. The audit's
gaps were all small and filled: label modules for samplers, bind group
layouts, bind groups, pipeline layouts and command buffers, the device's
label, `setLabel` on passes, a texture's `dimension` and
`textureBindingViewDimension`. Three coverage fixtures reach every member no
page reached; `CtsBoundaries` pins the CTS's map, range, write, immediate and
index edges with outcomes copied from the CTS; `GpuDiff` + `Differential`
compare sixteen seeded buffer-operation sequences between the wrappers and
raw WebGPU. Wrote `webgpu.md` §10.1, the new-revision process, and removed
the research `inventory.py`. Gates green apart from #2086; `test-webgpu` 264
passed, none skipped.

**What I learned.** A gate that checks only that a named fixture exists is
weak; requiring that a fixture of the row names the declaration in its own
code (comments stripped, test-platform modules only for types) catches most
lazy bindings cheaply. The fake host's lax copy rules ran an out-of-bounds
copy at submit and threw inside the page: a differential harness on the fake
needs the fake to model every rule its sequences reach. The beni sibling
checker rejects `async` arrows in a platform's JavaScript (it reads `async`
as an unbound name), so the native half uses promise chains. `rerere` on
this clone sometimes leaves `MERGE_RR.lock` after a commit; committing with
`-c rerere.enabled=false` avoids it.
