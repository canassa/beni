# JavaScript schema measurement harness

This directory measures the schema-library investigation defined by
`PROTOCOL.md`. It is research machinery, not a production dependency. This
investigation changes no production compiler, core, platform or project-build
file: its implementation surface is the benchmark, research report, queue and
diary, plus pinned source-submodule pointers.

Run through the pinned environment:

First initialize the pinned submodules and prepare the source builds. Deno
**2.6.3** must be on PATH (or supplied as `DENO_BIN`) for TypeBox's build; Node,
npm and Zig come from the dev shell. Network installs happen in the source trees
and ignored benchmark staging. See `SOURCES.md` for upstream-lock limitations.

```sh
git submodule update --init --depth 1 references/ajv references/typia references/typebox references/arktype references/fast-json-stringify references/zod references/valibot references/effect
nix develop --command sh -c 'cd bench/schema-libraries && npm run setup'
```

The setup command installs exact harness dependencies, builds the subjects,
wires **source artifacts** into the harness, and regenerates standalone and
Typia output. `npm ci` alone is not the measured installation: it restores
registry implementation files. The runner verifies resolved source entries and
their captured hashes and refuses a mismatched install. A changed build must
have its provenance reviewed, not silently blessed by the timing command.

Typia 15 uses its native `ttsc` transformer; the owner approved this replacement
for the incompatible `ts-patch` route on 2026-09-22. This change and the never-index
diagnostic configuration are documented in `typia/README.md`.

Then run the single-command capture:

```sh
nix develop -c sh -c 'node bench/schema-libraries/run.mjs --preflight > bench/schema-libraries/results.local.json'
nix develop --command sh -c 'caffeinate -i node bench/schema-libraries/run.mjs > bench/schema-libraries/results.json'
```

Redirection is deliberately inside `nix develop`: this repository's shell hook
prints its tool versions to the outer stdout before starting Node. `run.mjs`
itself emits exactly one JSON document. The first command performs correctness
and mutation checks only. The second is
the final, serial measurement command; do not run it while builds, project gates,
or other benchmarks are active. The harness refuses known concurrent Zig/npm/
TypeScript build commands before timing. Progress is written to stderr and stdout is
exactly one JSON document.

`npm run setup` installs the lockfile, builds all eight subject packages from
their pinned submodule sources, wires those source-built artifacts into the
measurement tree, and regenerates the compiled entries. `provenance.json` and
`SOURCES.md` record the exact tags, commits, artifacts and mechanisms; the run
embeds the provenance snapshot alongside read-only CPU, memory, power-source
and low-power-mode evidence. `caffeinate -i` is an external idle-sleep guard;
the harness makes no persistent power-setting changes.

`results.json` is the final capture. `edge-results.json` is a separate,
untimed Node 24 probe of JavaScript `undefined` boundaries. The compressed
`preliminary-results.json.gz` preserves the superseded capture taken before the
flat-only Zod, Valibot and Effect bundle entries were specialized; it is not a
second result matrix and must not be used for reported numbers.

## Measurement shape

`worker.mjs` runs one complete matrix in one fresh process. `run.mjs` starts
three independent groups with three repetitions each, serially. Row order is
rotated deterministically for every process. Each cell calibrates one fixed
batch size, records bounded convergence warmup, then records 35 samples. The
raw calibration, warmup and samples are retained.

Every timed result feeds a shared shallow sink. It observes success/failure,
top-level collection/object size and a small scalar fingerprint only; it never
recursively walks decoded trees or lists. Encoded strings contribute length and
the first and last character codes so character access is observed on equal
terms, not only rope length. This does not time UTF-8 materialization or promise
a particular internal string representation. The common sink is part of every gross
number and is not subtracted separately.

`analysis.mjs` selects the lowest repetition median independently for each
group/cell, preserves all three group orderings, reports pairwise ordering
flips, and subtracts the corresponding JSON floor without clamping negative
results. Encode failures carry the required warning that subtraction of a
successful stringify floor is counterfactual rather than validation-only cost.
The encode JSON floor receives the committed **wire object**, selected before
timing, so its serialized keys and bytes match the valid codec outputs; it does
not include a rename pass. Other encode rows receive program values. On decode,
the floor returns wire shape while codec rows return mapped program shape, so
the shallow sink observes slightly different key names. Net remains a
difference of medians, not a paired removal of identical downstream work. For
invalid encode cases each path receives its committed wire object, but only a
valid encode has an exactly matching successful output payload and bytes;
failure subtraction remains counterfactual.
Any row measured ahead of handwritten is retained and listed for equivalent-work
audit.

Correctness precedes timing. Successful decode values and structurally parsed
encode JSON must match exactly; every native failure needs a nonempty code and
the exact committed path; inputs must not mutate. JSON floor is measured but
explicitly excluded from validation correctness. Missing adapters and unsupported
directions are outcomes, never replaced by another implementation.
JS-only present-`undefined` encode probes are reported separately as
`contract_probes`. Their native outputs and deviations are retained, but they do
not weaken or block the comparable JSON-shaped timing matrix.

Fresh-process startup reports two surfaces explicitly: the all-workload adapter
module separates import, `create` construction/compile, and first call; the
browser-first flat-only entry aligned with bundle size reports import and first
call, with construction marked inapplicable when it happened at module load.
CSP probes use Node's
`--disallow-code-generation-from-strings`. Bundle measurement uses pinned
esbuild, browser ESM, minification and tree shaking over direction-specific,
flat-only entries, recording raw bytes, Brotli quality 11 and the complete input
list from esbuild's metafile.

The final full run took approximately 15 minutes on the recorded Apple Silicon
development machine; runtime will vary. Warmup nonconvergence is retained per
cell rather than silently extending the run or dropping the subject.
