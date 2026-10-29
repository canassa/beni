# WebGPU source collection

Research date: 2026-10-29. Tracking: [#1257](https://github.com/canassa/beni/issues/1257).
This directory is evidence for [the API proposal](../../webgpu.md), not an implementation.

Read [the investigation](../webgpu-api-research.md), then the proposal. The
[coverage inventory](coverage.md) lists every interface member, overload,
dictionary field, enum value, constant namespace, typedef and mixin inclusion.
[webgpu.idl](webgpu.idl) preserves their exact signatures and defaults.

## Sources and reproducibility

[sources.json](sources.json) records source URLs, immutable Git revisions where
available, byte counts and SHA-256 digests. Large specifications are linked and
hashed rather than copied into the repository. The only vendored specification
extract is the IDL, under the accompanying [W3C license](LICENSE-W3C.md).
Elm source was read at release 1.1.3, resolved to its commit, not a moving branch.
CTS source is likewise pinned to a commit. WHATWG living standards are dated
downloads with hashes; their URLs can change content later. The hash identifies
what was read, not a promise that a later download will match.

The API baseline is the [15 September 2026 WebGPU Candidate Recommendation
Draft](https://www.w3.org/TR/2026/CRD-webgpu-20260915/). The editor source inspected
is [`a1a1e79f35f93ad6db255dc170621ae7e411eba0`](https://github.com/gpuweb/gpuweb/tree/a1a1e79f35f93ad6db255dc170621ae7e411eba0),
dated 27 October 2026 in the rendered draft. Its IDL declaration/member/value
sets match the published draft; the order of `GPUFeatureName` entries differs.
This comparison covers IDL, not equality of all prose algorithms. WGSL's dated
published baseline is [26 October 2026](https://www.w3.org/TR/2026/CRD-WGSL-20261026/).

To reproduce the IDL extract, download `spec/index.bs` and
`spec/sections/copies.bs` at the recorded revision. Replace the `class=include`
block for `sections/copies.bs` with its contents. Concatenate the bodies of
every `<script type=idl>` in document order, separated by two newlines. The
privacy/security include has no IDL. Prepend the three-line provenance header
in the committed extract. No WebGPU IDL file exists at `spec/webgpu.idl` in
this revision: the authoritative declarations are inline in the specification.

From this directory:

```sh
python3 inventory.py --check  # offline: every pinned declaration is accounted for
python3 inventory.py         # regenerate coverage.md after a reviewed IDL update
```

The parser accepts only the declaration forms in this snapshot and rejects
unconsumed text. It is a research audit, not a general WebIDL compiler and not
evidence that any runtime behavior passes. In particular, it cannot prove that
the proposed beni modules implement an entry; the implementation must add that
independent comparison before claiming completeness.

## Reading map

| Question | Primary source |
|---|---|
| Which API exists? | WebGPU §3–§22; full IDL index; `spec/index.bs` and `spec/sections/copies.bs` |
| Which failures are observable? | WebGPU §3.2, §5.2, §9, §10, §19, §21, §22; imported Web IDL and HTML algorithms |
| Which language can run on the GPU? | WGSL §2 errors/lifecycle; §4 directives; §14 memory layout; whole WGSL grammar and builtins |
| How should a functional rendering API feel? | Elm WebGL 1.1.3 `WebGL.elm`, `Texture.elm`, and their kernel implementations |
| How are edge cases tested? | gpuweb/cts error-scope tests, capability tables, validation/operation/shader test trees |
| Which local constraints apply? | beni `boundary.md`, `transparent-effects-proposal.md`, browser/TEA APIs, `core/Task.beni`, `core/Js.beni` |

No browser support/version claim, runtime benchmark, or working WebGPU binding
is asserted by this collection. Browser availability must be detected at run time.
