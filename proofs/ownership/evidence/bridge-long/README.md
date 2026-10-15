# Complete ownership bridge evidence

See [BRIDGE-RESULTS.md](../../BRIDGE-RESULTS.md) for coverage, verdicts and limits.
`evidence.json.gz` stores the complete report, all cases, declaration tables and
source texts, with source/table SHA-256 checks. `report.json` is its small summary.
The `examples/` files are representatives; every case can be extracted with:

```sh
node proofs/ownership/scripts/bridge-evidence.mjs case proofs/ownership/evidence/bridge-long seed-314159-9019 source
```

`stream-coverage.json` verifies the exact exported inputs and recovers per-stream
eligibility and the full verdict matrix. `frontier-summary.json` counts final
reduction-frontier skips. `duplicate-site-audit.json` documents conservative
unknowns for repeated closure-body keys. `validation.json` verifies the bundle.
