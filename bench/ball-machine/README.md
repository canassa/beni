# Ball-machine browser benchmark — 2026-10-26

The measured drawing has since been applied. See [applied verification](APPLIED.md).

The current drawing is limited by SVG filter rendering on this machine. Replacing
dynamic blur/shadow filters with gradient halos approximately doubles animation
cadence, while keeping the actual beni physics, semaphore program and cabinet
shadows. This is a **benchmark-only drawing prototype**, with a softer appearance;
the playground sample is unchanged. Tracking: [#1092](https://github.com/canassa/beni/issues/1092).

## Repeated measurements

Values are medians of three independent trials, with trial ranges in parentheses.
Batch size is three. These are requestAnimationFrame callbacks per second,
observed in GPU-enabled headless Chrome, rather than a count of presented GPU
frames. Timing runs have no CPU/allocation profiler or tracing enabled.

| Settings | Current dev | Current release | Gradient prototype |
|---|---:|---:|---:|
| 4 permits, 14–16 balls typical | 32.50 (32.00–32.60) fps | 32.50 (32.10–32.80) fps | 60.00 (59.99–60.09) fps |
| 8 permits, 18–22 balls | 25.87 (25.75–25.87) fps | 26.00 (25.99–26.25) fps | 59.99 (59.99–59.99) fps |

The default trial uses five seconds of warm-up and ten seconds of measurement;
the eight-permit trial uses four and eight seconds respectively. Order is reversed
on alternating trials. At four permits the median trial's 95th-percentile frame
interval falls from 33.34 ms to 16.67 ms; at eight, from 50.00 to 16.67 ms.
The prototype has zero intervals over 25 ms in all six repeated trials.

| Default settings, per callback | Dev | Release | Prototype |
|---|---:|---:|---:|
| Main-thread task time | 0.976 ms | 0.949 ms | 0.855 ms |
| Script time (part of task time) | 0.342 ms | 0.322 ms | 0.302 ms |

These times come from CDP Performance.getMetrics deltas divided by callback
count. They exclude GPU work and are not a complete rendering-cost measurement.

Two single-trial checks support the repeated result:

| Check, four permits | Dev | Release | Prototype |
|---|---:|---:|---:|
| Visible Chrome, 1280×800 DPR 1 | 31.74 fps | — | 62.12 fps |
| Narrow viewport, 390×900 DPR 2 | 37.12 fps | 37.12 fps | 59.99 fps |

The narrow viewport still runs on the M2 Pro: it is **not a phone benchmark**.
Visible Chrome has variable display cadence (prototype p95 interval 24.99 ms),
so its single run is confirmation of direction, not a precise refresh-rate claim.

## What causes the slowdown

An initial eight-permit A/B run, three seconds warm-up and eight seconds timed:

| Drawing experiment | fps |
|---|---:|
| Current drawing | 27.00 |
| Disable all SVG filters | 60.00 |
| Disable animated dashed strokes only | 27.62 |
| Hide the SVG, keep simulation running | 60.00 |

Separate single-trial diagnostics removed individual filter families: no glow
48.62 fps, no static shadows 35.37, no ball shadows 34.12. Reducing glow blur from
three to one only reached 28.12; replacing the static cabinet group with an SVG
image also reached 28.12. These pilot runs establish priorities; their timings
are not as strong as the repeated comparisons above.

The prototype removes `#glow` from dynamic gates, chips and rings, removes the
conditional `#glow`/`#ballShadow` on moving ball bodies, and adds a radial-gradient
halo plus a translucent token ring. It keeps `#shadow` and `#rodShadow` on the
cabinet. It is compiled from a modified copy of **View.beni**, not a JavaScript
replacement of the simulation. The build script contains the exact transformation.

Filter A/B results implicate browser rendering. The captured trace does not
isolate GPU/raster threads sufficiently to assign the cost to a specific hardware
unit. Low main-thread CPU time alone would not establish that diagnosis.

## CPU and allocation hot spots

An eight-second development CPU profile at eight permits samples every 100 µs.
It records 214 animation callbacks. Inclusive costs below overlap; do not sum
parent and child rows.

| Sampled stack | Total | Per animation callback |
|---|---:|---:|
| Physics.step | 43.27 ms | 0.202 ms |
| Runtime render | 48.16 ms | 0.225 ms |
| Trail patch (inside render) | 16.13 ms | 0.075 ms |
| Ball patch (inside render) | 10.01 ms | 0.047 ms |

Physics takes six substeps per animation callback. Its hot path is
[`substep`](../../tests/corpus/browser/tea/BallMachine/Physics.beni), especially
`move`, `hitWall`, the all-pairs `collide`/`bump`, and their List.map/foldl loops.
The generated dev Physics.mjs has step at line 285, substep 246, move 102,
hitWall 151 and collide 183. Generated View.mjs has the trail patch at 713,
ball patch at 781, and root patch at 996. Use the recorded source maps for the
original beni source. The CPU profiler's large `(program)` bucket is native or
unattributed work, not evidence that a particular JS function is slow.

A separate ten-second allocation sampling run (32 KiB sampling, including
objects collected during the run) estimates **61.0 MB allocated, 6.1 MB/s**.
Physics.step accounts for 55.6 MB, **91.1%**; runtime flush accounts for 4.72 MB,
7.7%. Self-allocation includes move 15.5 MB, Array.push 8.08 MB and Array.slice
4.46 MB. These estimates describe churn, not retained memory or a leak.

In a separate eight-second timeline, 34 minor GCs total 7.11 ms, and one major
GC takes 1.51 ms: about 0.11% of wall time combined. GC is not the observed frame
rate limiter in this workload. Long-term memory stability was not measured.

## Ways to make it lighter, in priority order

1. **Use gradient halos in place of dynamic SVG filters.** This is the measured
   animation win. The prototype needs visual review before adoption: its halo
   and token ring approximate the reference rather than reproducing every blur.
   Implementation follow-up: [#1095](https://github.com/canassa/beni/issues/1095).
2. **Ship the release build.** Across all imported JavaScript modules, development
   output is 241,783 bytes raw / 52,412 brotli; release is 77,154 / 22,840 bytes.
   That saves 56.4% of compressed JS. It makes delivery lighter, with essentially
   unchanged animation cadence. Sizes exclude maps, HTML and CSS; each module
   is compressed independently at brotli quality 11.
3. **Reduce physics churn if CPU or battery becomes a problem.** Inspect record
   spreads and accumulating List.push calls in the six substeps. Hoisting the
   solid-wall selection within a frame may help, but gate state can change
   between substeps, so preserve that behavior. Stage-aware collision candidates
   could reduce all-pairs work for larger populations. These are hypotheses,
   not measured improvements. Do not reduce substeps without checking collisions.
4. **Consider trail patch allocations next.** Trails are bounded to seven points;
   profile before redesigning this small part of render. No evidence here calls
   for replacing SVG, TEA or the semaphore program.

## Reproduction and artifacts

Machine: Apple M2 Pro, 12 cores, 16 GiB RAM, arm64 macOS. Chrome
156.0.8078.48, ANGLE Metal on Apple M2 Pro, GraphiteDawnMetal; Node 24.19.0.
Source revision `fe7af05f1909ce05732801dbe086ece18d91d187`; compiler
`beni 0.1.0-m1 802be55e4ad5d8abb2642835ead351ca`. The fixed initial seed is
20261026. Original simulation code is copied from the nine BallMachine modules;
only RNG initialization changes in the baseline. The clock, RAF, fibers,
semaphores and physics all run normally. The harness loads the generated ES
modules directly in a fresh page, without the playground/editor/WASM compiler.

```sh
# Use Zorg on this ARM machine; never invoke Zig here.
zorg build -Dllvm
node bench/ball-machine/build.mjs --beni=zig-out/bin/beni
node bench/ball-machine/run.mjs --variants=dev,release,gradient --seconds=10 --warmup=5 --repeats=3 --label=confirmed
node bench/ball-machine/run.mjs --variants=dev,release,gradient --at-once=8 --seconds=8 --warmup=4 --repeats=3 --label=confirmed
node bench/ball-machine/run.mjs --mode=cpu --variants=dev --at-once=8 --seconds=8 --warmup=3 --repeats=1
node bench/ball-machine/run.mjs --mode=alloc --variants=dev --at-once=8 --seconds=10 --warmup=3 --repeats=1
node bench/ball-machine/run.mjs --mode=trace --variants=dev,no-filters --at-once=8 --seconds=8 --warmup=3 --repeats=1
```

Add `--headful=true` for visible Chrome; `--width=390 --height=900 --dpr=2` for
the narrow viewport. `--chrome=/path/to/chrome` supports other installations.
`--screenshots=true` captures the page after timing. Build and runner accept
`--out=...`; the runner accepts `--build=...` to select a different build root.
Default build input is `zig-out/safe-llvm/bin/beni`, the binary used for this run.

The current sample already includes the gradient drawing, so `dev` and
`gradient` now match (`gradientChanged=false` in built.json). To repeat the
historical drawing comparison with a current compiler, extract its source first
and use a fresh output directory:

```sh
mkdir -p zig-out/ball-machine-baseline
git archive fe7af05f1909ce05732801dbe086ece18d91d187 tests/corpus/browser/tea/BallMachine | tar -x -C zig-out/ball-machine-baseline
node bench/ball-machine/build.mjs --source=zig-out/ball-machine-baseline/tests/corpus/browser/tea/BallMachine --out=zig-out/ball-machine-comparison
node bench/ball-machine/run.mjs --build=zig-out/ball-machine-comparison --variants=dev,gradient --at-once=8
```

This compares drawings using the compiler supplied to the builder. Reproducing
the historical emitted bytes also requires the recorded compiler revision.

Raw measurements, CPU/allocation profiles, traces, build metadata, size counts
and file hashes are preserved under [`results/2026-10-26/`](results/2026-10-26/).
Decompress `.cpuprofile.gz` for Chrome DevTools Performance, `.heapprofile.gz` for
Memory's allocation profile loader, and `.trace.json.gz` for the Performance
trace loader. JSON files contain versions, flags, settings and metric deltas;
the confirmed and viewport runs also retain every observed frame interval.
`built.json`'s historical `bytes` counts only root modules; use `sizes.json` for
complete payload sizes. New builds calculate the complete payload automatically.

Generated JS, maps, modified source copies and screenshots stay in
`zig-out/bench/ball-machine/`. The static pages can be served with
`python3 -m http.server --directory zig-out/bench/ball-machine 8002` and opened
at `/dev/`, `/release/` or `/gradient/`.

Limitations: this is one laptop and browser, not a cross-device result. It was
not an isolated machine. Timers and RAF are real, so a fixed seed does not replay
an identical trajectory at different frame rates. Machine.frame clamps physics
dt to 1/30 second, so missed frames can also slow simulated time relative to the
wall-clock timers used by the control fibers. Ball counts are recorded to
check workload similarity. The common observer adds a RAF callback, and a DOM
ball count is sampled twice per second. GC is requested before and after timing,
not within it. Profiling overhead affects profile runs, so their timing is not
used for the repeated FPS table. No throughput-equivalence or battery-life claim
is made, and no production simulation code was changed.
