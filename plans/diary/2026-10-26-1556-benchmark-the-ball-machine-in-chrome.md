## 2026-10-26 15:56 CET — Benchmark the ball machine in Chrome

**What I did**

Completed the preceding playground PR #1090 merge, then benchmarked the actual
emitted ball-machine ES modules directly in Chrome on this M2 Pro (#1092).
Added a fixed-seed build harness, CDP timing/CPU/allocation/trace runner, preserved
compressed raw measurements/profiles and source/output hashes, and a report in
bench/ball-machine/README.md. Generated JS, source maps, screenshots and a complete
standalone generated-code/source archive are in zig-out/bench/ball-machine/.

Measured development, release and a benchmark-only gradient-halo drawing with
three counterbalanced timing repetitions at four and eight permits. Checked the
direction again in visible Chrome and a narrow viewport. Captured CPU,
allocation and timeline profiles separately from timing. Created #1095 for
applying the measured drawing improvement with visual review. No production
simulation or compiler code changed; the user asked for a benchmark.

**What I learned**

SVG filters dominate the measured animation limitation: at default four permits,
median cadence is 32.50 fps in development and release, and 60.00 with gradient
halos replacing dynamic blur/shadow filters while preserving cabinet shadows.
At eight permits it is 25.87, 26.00 and 59.99. Disabling dashed animations,
shrinking the blur kernel, or caching the cabinet alone does not recover 60 fps.
Visible Chrome confirms the direction (31.74 versus 62.12, one trial).

Physics costs about 0.20 ms per observed frame in the CPU profile. Allocation
sampling estimates 6.1 MB/s, 91.1% in physics; traced GC costs about 0.11% wall
time. Release cuts complete imported JS from 52,412 to 22,840 brotli bytes
without improving cadence. Allocation work is a later CPU/battery hypothesis,
not the demonstrated frame-rate fix. The six substeps, semaphore tasks and
control logic stay intact. Physics clamps dt to 1/30 second, so real-clock
comparisons are not exact trajectory replays across different frame rates.

Builds, syntax checks, recorded source/output hash verification and all browser
benchmark runs succeed. The full Zorg gate still encounters the previously
tracked macOS ownership golden differences (#1085) and case-folding filesystem
failures (#90). Benchmark work remains local on bench-ball-machine; no commit or
PR bypasses that gate. See zig-out/ball-machine-benchmark-gates.log.
