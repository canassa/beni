## 2026-09-22 01:19 CEST — Schema prototype with Sol implementation agents

**What I did**

- Wrote the bounded prototype plan before implementation and launched three Sol
  agents for the library, scenarios/effects analysis, and portable boundary/runner.
  Kept production compiler, core and grammar untouched.
- Managed integration and independently reviewed the source. Found and had the
  agents correct nested refinement bypasses, first-error aggregation, unknown-key
  handling and missing depth checks, with executable regression cases.
- Independently ran 50 exact assertions through development/release at jobs 1/8
  under Node 24 and Chrome 153, two whole-diagnostic negative fixtures, output
  determinism and Beni formatting. All passed. The full project test, blackbox
  and formatting gates also passed under the pinned dev shell.
- Captured full results and wrote report 33: release test application 59,394 raw
  bytes / 14,207 concatenated Brotli; the small decode/encode browser batch had
  a 1.2 ms median in both modes. No Effect performance parity claim. No commits.

**What I learned**

- Two explicit endpoints make fallible flip and projections implementable without
  guessing program structure from the wire description. Explicit list schema
  arguments preserve two wire forms for one program type; recursive payload
  conversion and separate presence/nullability work in ordinary Beni.
- A whole-record transformation cannot run after failed structural parsing—also
  true in Effect. Independent field transforms therefore need field-level schema
  composition if their errors must be collected together. The prototype records
  that limit rather than claiming a false parity result.
- Stored synchronous functions in transparent aliases do not settle directional
  effects through an opaque nominal schema. Eager first-error evaluation and
  repeated validation also need a production design, not merely more signatures.
- The actual mixed-union representation boxes Wire.Null in both output modes;
  checking emitted behavior resolved a misleading simplified representation rule.
