## 2026-11-01 18:52 CET — integrate owned entry proof inputs

**What I did**

Integrated the frozen ordinary solved-provenance and anchored-role producer
patches on the accepted native constructor checkpoint a98cb76c4. Preserved both
native preparation and requested graph capture, both preflight checks and every
existing native emission test. The output order is existing entry/realm data,
solved provenance, then role evidence. Shared test readers validate both new
sections before comparing the complete old prefix. Two protocol controls pass.

Copied and independently hashed both source handoffs and every pinned evidence
payload. Reconstructed exact component trees 55b48f33 and 6516c3a7. Independently
replayed the role component: nine standalone checks and 32 CLI cases passed.
The solved component's main 13 checks and seven infrastructure checks passed;
its handoff wrapper failures were retained separately. Correcting a standard
runner argument does not change the source or binary. The wrapper also used
a unit CPU budget for blackboxes; the normal build recipe remains authoritative.
The full integrated gate is the acceptance check for the combined code.

Reviewed and required actual before/after repairs for role query pairing,
original binding/status linkage, callable/constructor tag domains and omitted
status-row accounting. The solved writer now rejects missing requested metadata
before emitting the old prefix. All remain diagnostic inputs; no whole-entry,
invocation, HostFree, Wire or owning-storage certificate is introduced.

**What I learned**

Ordinary source inventories distinguish allocated descriptors, representatives,
structural edges, roots and formal words. Their construction cost is explicit;
it does not establish the later canonical classification bound. Matched costs
need separate ordinary upstream and inspection-foundation references, and final
candidate source/binary pins before any measurements.
