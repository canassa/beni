## 2026-10-29 23:56 CET — Review the WebGPU proposal against the spec

**What I did**

At the owner’s explicit request, assigned an independent agent to review the
proposal at 5678c99ce against the pinned WebGPU/WGSL specifications and imported
Web IDL rules. Recorded the detailed review in
`docs/design/research/webgpu-spec-review.md` and tracked its four actionable
findings and two open contracts separately as #1266–#1271. The proposal is
unchanged. The reviewer reproduced the IDL extraction/comparison, all 18 source
hashes and the offline inventory check; it found no native declaration omission.
No browser, CTS or performance run was claimed. Existing full-gate failures
from the original proposal session remain recorded in the draft PR; no production
or test input changed during this review.

**What I learned**

A complete native inventory does not prove that safe adapters preserve every
capability. The declared API needs a public mapping producer for mappedAtCreation
and a synchronous Frame resource/Batch bridge for new external-texture bindings.
The failure ledger should explicitly distinguish mapped size alignment from
allocation RangeError and require fixed-length backing for GPU binary sources.
Diagnostic lease reentrancy and zero/multiple-submit receipt semantics are open
contracts, not proven spec contradictions.
