## 2026-10-30 00:01 CET — Remove the extra WebGPU rendering layer

**What I did**

At the owner’s direction, removed the proposed Mesh/Entity/View rendering
abstraction from the WebGPU design, its delivery stage, its decision request
and the research recommendation. Removed the optional Gpu.Layout module
reference while retaining required binary encoding and WGSL layout semantics.
Kept section 9 reserved so existing section references do not move. Updated
the draft MR description to match. The Elm WebGL comparison remains prior-art
research. The independent review and its findings remain unchanged.

Validated the offline API inventory, local documentation links, stable section
numbers and diff whitespace. No compiler, runtime, test or inventory inputs
changed; the previously recorded full-gate failures remain outstanding.

**What I learned**

Elm’s API is inspiration for the typed WebGPU API’s ergonomics, not a request
for a separate rendering model. The proposal now exposes WebGPU directly.
