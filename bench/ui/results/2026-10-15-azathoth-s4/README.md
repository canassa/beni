# Rendering measurement evidence

Measured source: `e2aed9171507978edef58e1ee8cf601020f538e2`, master after
browser-direct's rendering PR #86 and effects work. This directory is evidence
for research 87; the archived bundles are compiler outputs, not implementations
to maintain or replacements for the benchmark's source.

- `run.sh`: the one serial campaign on azathoth. Install Zorg 0.17.1+zorg.1,
  run `zorg build -Doptimize=ReleaseFast` at the repository root, then execute
  it under `nix develop .#browser -c bash …/run.sh`. It rebuilds and verifies
  every subject, then takes all comparison timings at rate 1, with Chrome on
  cores 2–5,8–11 and the timing harness on 0–1,6–7. The programs, warm-ups,
  interval definitions and conditions are `bench/ui/`'s existing ones.
- `table.json`, `sweeps.json`: all completed comparison observations, counts,
  loads and provenance, without trimming. `sweeps-prefix.json` and
  `sweeps-rest.json` retain the original epochs: the initial sweep run reached
  an unavailable P3 `filtered` page. That incomplete point was stopped;
  after the availability-check fix, all remaining conditions resumed with
  every requested candidate. Completed holes and rows were not rerun.
  `*.log` records that failure and the continuation.
- `merge-sweeps.mjs`: regenerates the merged JSON from the two captured epochs,
  asserts identical machine/compiler/interval settings, complete cell counts and
  every requested candidate at every condition. A new uninterrupted run already
  writes `sweeps.json` directly and does not need this merge.
- `summarise.mjs`: regenerates `timings.md` and prints the sample/load/failure
  inventory. `stream` retains two traced three-second windows, not 24
  untraced clicks; its results are informational.
- `table-sizes.txt`, `sweep-sizes.json`: all candidates' full byte totals;
  Terser 5.51.2, brotli 11, gzip 9. `scaling-sizes.mjs` now includes Solid 2.
- `bundles/`, `maps/`, `*-parts.txt`, `*-coarse.txt`: both beni platforms'
  table and rendering endpoints, with every top-level binding assigned once.
  Regenerate a part report from `bench/ui/` with
  `node size-parts.mjs --file=results/2026-10-15-azathoth-s4/bundles/<name>.mjs --map-file=results/2026-10-15-azathoth-s4/maps/<name>.json`.
  The files are matched snapshots: a new compiler's renamed bindings need a
  new map. Leave-one-out deltas are not additive. Peeling plus the startup/
  stub residue sums to the whole.
- `fixed-paths.json`, `width-paths.json`: the exact constant tick-handler
  bodies and the wide model's one-hole/spread structure. `width-direct.mjs`
  is also archived and mapped for byte analysis.
- `compiler-source.diff`, `compiler.sha256`: empty source delta at measurement
  and the measured ReleaseFast compiler's hash. Final proof/test-only base
  refresh to `6e041631f` changes none of those compiler/platform/app sources.
- `scaling-measured.mjs`: exact sweep harness used by the continuation. The
  final harness strengthens its availability check to use generator support,
  avoiding stale unsupported P3 files; `availability.log` agrees on all 29
  omitted optional pages. No requested candidate is omitted.
- `depth128-writes.txt`, `sources/depth128.source.txt`, `depth-paths.json`:
  the depth widening and the compiled handler's group/property-read counts.
  The dump's module is named `Depth128`; the measured generated module is
  `Main`. Both use the unchanged `apps/scaling/depth.mjs` source generator.
- `app-builds.mjs`, `app-builds.json`: unchanged real-app release builds and
  their complete diagnostics, including the successful reduced TodoMVC
  subjects. These are build results, not app timing or transcript claims.
- `gates.log`, `gates-macos.log`, `chrome.log`: Linux gate, known macOS gate
  failures, and the native Chrome corpus boundary. The Chrome result remains
  red; the navigation diagnostic does not alter it.
- `navigation-probe.mjs`, `*-probe.log`, `*-probe.json`,
  `*-probe-machine.json`: instrumented fuzzer diagnostics, **not timings**,
  run on local macOS Chrome 155 with either platform first. The driver shell
  exits 0 when it writes its JSON report; each JSON's `code: 2` is the actual
  fuzz failure. Both programs leave the application, then another value send
  sees missing hooks on `chrome-error://chromewebdata/`. Reproduce with
  `node …/navigation-probe.mjs --beni=<beni binary> --chrome=<Chrome> --first=tea`
  and `--first=direct`. Only temporary copies of the driver/fuzzer are patched.
- `profile-update.json.gz`, `profile-rendering.json.gz`: lossless complete
  sampling profiles, with uncompressed SHA-256s in `profile-hashes.json`.
  `profile-summary.mjs` reads the compressed or plain JSON and regenerates
  the named-function summaries; idle/native-unattributed time stays separate.
- `profile-rendering.mjs`: all requested candidates at live, helper-row,
  derived, depth and width endpoints, P3 where available; exact warm-up and
  one profiled real click on each of twenty fresh pages. These profiles are
  diagnostic evidence, not replacement timings.
- `profile-update.mjs`: the follow-up sampling investigation of the update
  miss, every candidate rotated in one batch under the exact table warm-up.
  Run after the comparison timings; profiled execution is not another
  comparison timing or a basis for a new ordering.

All timings are azathoth's Chromium 153.0.8010.36 / Node 24.19.0. Part-size
analysis uses those archived Linux outputs under local Node 24.19.0 and the
same Terser version. No application, runtime, budget or target was changed.
