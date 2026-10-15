## 2026-09-22 12:09 CEST — Tighten compiled-subject edge contracts

**What I did**

- Corrected the Typia candidate after reviewing its generated strict-object code.
  Enabled the native transform's `finite: true` and `undefined: false` options
  together with TypeScript exact optional properties, then removed the redundant
  custom finite tag and regenerated both matrix and flat proof.
- Typia's key-count fast path only reported the parent when an object contained
  every optional field plus a surplus key. Added a never-valued template index
  signature to the proof types; it accepts no extra value but keeps generated
  `validateEquals` on its native per-key diagnostic path. Verified exact paths
  for ordinary and undefined-valued surplus keys, present optional `undefined`,
  non-finite numbers and the never-prefix itself.
- Corrected CSP metadata after both source inspection and a code-generation-
  disabled process: ArkType selects its jitless evaluator and TypeBox Compile
  selects its interpreted fallback. Recorded the separate Ajv/TypeBox native
  mismatch that a present optional property valued `undefined` is accepted.

**What I learned**

- Typia 15's supported options can meet finite-number and exact optional-presence
  requirements without a hand-written guard. Its generated key-count shortcut is
  nevertheless too lossy for the benchmark's exact fault-path contract; a
  semantically empty dynamic signature is needed to request per-key diagnostics.
- JSON Schema validators commonly treat a known optional property whose value is
  JavaScript `undefined` as absent. That is outside JSON wire data but reachable
  on the encode side, so it is a native contract mismatch to report, not silently
  repair or omit from the evidence.
