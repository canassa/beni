## 2026-10-29 23:34 CET — Design the complete WebGPU boundary

**What I did**

Researched WebGPU and WGSL from dated standards and pinned GPUWeb source,
Elm WebGL 1.1.3 including its kernels, Web IDL, HTML image usability and the
WebGPU CTS. Added the browser API proposal, prior-art investigation, an
operation-specific failure ledger, source URLs/hashes, licensed IDL extract
and an offline-generated coverage inventory. The proposal is explicitly not
adopted or implemented. Research tracked by #1257 on `design/webgpu-api`, in
an isolated worktree from origin/master `27d49725d`.

Verified all 18 recorded download digests, exact source-to-IDL extraction,
complete inventory regeneration and local document links. Compared published
and editor IDL sets (same members/values, feature ordering differs). Ran the
required unfiltered gates with `nix develop .#ownership -c zorg build gates`
on arm64 macOS: 1879/1941 tests passed, 16 skipped, 46 failed. Failures are in
unchanged code: known ownership output differences #1085, case-folding tests
#90, ownership CPU-budget overruns recorded as #1260, and the existing
303-line prerender skill topic recorded as #1259. No goldens, limits or code
were changed to pass them. Publish the research as a draft PR with the gate
findings disclosed; it is not ready to merge on this local validation.

**What I learned**

A WebGPU wrapper needs scopes, native exception/rejection allowlists,
compilation diagnostics and persistent device-loss state together. A scope
returns only a representative error, and WGSL dynamic errors can be
undetectable; a complete API cannot promise observations the browser does
not provide. Defined GPUInternalError and loss reason "unknown" are typed
outcomes, while an unrecognized observation must be a beni defect. Canvas
and video textures require acquire/import, encode and submit in one host
turn, with validation afterward. Complete support also requires typed binary
views, exact 64-bit query data, all external image sources and worker/offscreen
access; a mesh/entity API alone does not cover it.
