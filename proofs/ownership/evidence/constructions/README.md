# Constructions, views and function-valued results — evidence, 2026-10-15

`../../CONSTRUCTIONS-RESULTS.md` reports what these files measure.

- `ci/`, `long/`: `report.json` (complete counters, per-stream SHA-256 hashes,
  environment fingerprints; `cases` is the count), `evidence.json.gz` (every
  lead's source, demands and paired runtime outcome; `scripts/bridge-evidence.mjs
  case <dir> <id> [original|report]`), `audit.json` and `judgments.json.gz` (both
  Lean interpreters' complete traces for every forward lead, the meaningful-lead
  counts, the 401 historical reverse sources replayed, the original 490 fixed
  programs and the historical v5/enumeration streams pinned).
- `mutants/report.json`: the ten Zig controls on the CI stream, every new
  program and site lead; `mutants/judged.json`: each caught control's new leads
  run in both Lean interpreters.

Both campaigns used one frozen ReleaseSafe compiler from master `dd38d162e`.
The long audit reports one confirmed unsafe original, `v6-17-5271`, pinned by
`tests/pending/check/bad/direct/BridgeCallbackReturnsParameter.beni` and listed in
`scripts/bridge-known-unsafe.json` (a generated id, valid only while generator
v6 and seed 17 are frozen; the audit fails when a pin it judged is no longer
confirmed, so a fixed or moved pin cannot linger); its core is
`regressions/bridge/CallbackReturnsParameter.json`.
