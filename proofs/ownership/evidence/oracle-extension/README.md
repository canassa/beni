# Lean oracle extension evidence — 2026-10-15

`../../ORACLE-EXTENSION-RESULTS.md` reports the model boundary and measurements.
The implementation is `c6e206fef`; the unchanged shipping compiler sources are
`bcf28a6ee`. PR #116's initialization contract was read through `5310d3619`;
this branch does not carry its compiler changes.

`ci/` and `long/` contain:

- `report.json`: complete counters, per-stream SHA-256 hashes and environment fingerprints.
- `evidence.json.gz`: every original lead source and verdict/runtime evidence, including site-only leads blocked by another refusal. No persistent-runtime minimum is used in these runs.
- `audit.json`: original-program interpreter judgment counters, frozen compiler check, exact historical enumeration/generator hashes and all 401 historical reverse sources replayed; the full original 490-program fixed prefix is pinned by source, verdict and declaration-table SHA-256.
- `judgments.json.gz`: complete final values, reads and external-reader observations from both Lean interpreters for every original program lead, plus each historical reverse refusal before and after.

The full run has 2,730 retained evidence cases, of which 1,725 are original
program-level leads. Every one of those 1,725 has equal interpreter traces;
all six historical defect-cluster sets have zero surviving accepted originals.
CI's six program leads also agree. These are finite observations, not proofs.
The recorded compilers are frozen per campaign and checked before/after audit.
The bridge uses at most eight workers, one thread per compiler child.

`controls.json` records the corrected 508-program targeted run and all twelve
new hole counts. `hole-witnesses.jsonl.gz` retains each fixed typed core and its
full interpreter outcome; the corrected checker refuses every one and its named
hole accepts a disagreeing execution. The actual fixture constructors and
required-hole table are in `Ownership/Sync.lean` (`Sync.holes`). The source-rule
removal failures and restored results are retained in
`review-*.log.gz`; the source-read and function-valued guard failures were
checked with each fix set aside. `review-tail-before.log.gz` and
`review-tail-restored.log.gz` retain the real-compiler non-tail Result regression
failing before the tail-context fix and passing after it. Initialization
controls remain Lean-only; the shipping bridge skips their entry/private-root
projections. The complete
`ci.log.gz` includes all 23 targeted controls, the seeded controls, fixtures,
enumeration and the normal CI bridge.

`build.log.gz` records the in-build source/axiom/kernel audit (3,258 constants).
`clean-audit.log.gz` records `scripts/audit.sh` over committed `c6e206fef`:
32 parsed sources, 4,720 constants replayed, the same four pinned constants
on the three unproved statements, no swapped attributes and no changed source.
`fixtures.log.gz` retains every fixed verdict and hole result.
`compiler-checks.log.gz` records the macOS constituents: 1,302 passed, 15 skipped
and the two previously documented case-folding failures. `gates.log.gz` records
the exact gate's refusal of this unsupported instruction-counting host. The
hardware-budget gate is still owed on supported x86-64 Linux.

Inspect retained source or judgments from the repository root:

```sh
node proofs/ownership/scripts/bridge-evidence.mjs case \
  proofs/ownership/evidence/oracle-extension/long enum-2-10033 original
python3 - <<'PY'
import gzip, json
path = 'proofs/ownership/evidence/oracle-extension/long/judgments.json.gz'
data = json.loads(gzip.decompress(open(path, 'rb').read()))
print(data['audit'])
print(data['judgments'][0])
PY
```

Use an id present in the corresponding report's compressed evidence; the source
command fails rather than silently choosing another id. To replay a judgment,
write `id<TAB>json(core)` to a file and run the built `triage input.tsv output.jsonl --only`.
Reproduce campaigns with fresh output directories using the report's commands.
`source-sha256.json` pins all 32 Lean source files at the audited implementation.
The later report/evidence commit changes no Lean source. The omitted `cases/`
build directories are ordinary generated artifacts.
