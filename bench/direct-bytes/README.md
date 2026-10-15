# Direct bundle anatomy

[Research 98](../../docs/design/research/98-direct-bytes.md) owns the conclusions,
method, limits and reproduction commands. Run scripts from the repository root.
No compiler changes are needed. The scripts use the UI benchmark's installed,
pinned Acorn and source-map dependencies (`npm ci` in `bench/ui/apps/solid1`).

`measure.mjs` builds six unchanged release programs, checks that release source
maps leave executable bytes identical, and measures each source removal alone
and in a fixed cumulative order. Removals are non-executable attribution probes.
It also writes the original bundles and the path/mask-spelling trials.

`prototypes.mjs` reconstructs four further encodings from each archived baseline,
syntax checks them, and writes their independent compression ledger. Group
records deliberately retain dead zero stubs; literal plans retain an unused
shared builder when present. No external minifier or unrelated DCE is credited.

`audit.mjs` independently replays a reversed attribution order and checks every
rewritten path literal and mask read against its protocol position. Its JSON
lists all literal spans and classifications. `intervals.mjs` computes descriptive
paired-round bootstrap intervals from the two archived application timing batches.

`verify.mjs` runs all eight executable variants through five page scripts,
comparing complete driver transcripts. It never executes removal ablations.
It does not substitute for the development visit oracle or full value fuzz.

`speed.mjs` measures two mask kernels and two dictionary-lookup kernels in
Chrome. Its raw observations concern warmed kernels, not application latency.
`timing.mjs` reconstructs the Conduit tea/original-direct/short-ID comparison
from the archive (pass `inline-group-records` for that prototype) and invokes the existing fresh-page CDP harness. Both record
raw observations; the latter also records hashes, host load and transcript checks.

`results/*.mjs.gz` are lossless archived JavaScript, with gzip only as a storage
envelope. The delivery gzip-9/brotli-11 figures come from compressing the unzipped
bytes. `measurements.json` identifies the compiler/base and stores declaration
names/spans, hashes, raw/gzip/brotli baselines and both kinds of attribution.
`prototypes.json`, `verification.json`, `speed.json`, `path-timing.json` and `group-timing.json`
retain the additional measurements. Each encoding is applied to the baseline
alone, except the explicitly labelled paths-and-zeroes composition experiment.
