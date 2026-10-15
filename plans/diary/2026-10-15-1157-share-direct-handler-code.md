## 2026-10-15 11:57 CEST — Share direct handler code

**What I did**

Rebased draft PR #98 onto master d9ae082e0, preserving every prior diary entry
in the new one-file-per-entry layout. Profiled all three Conduit messages with
Chrome CPU/compile traces and a separate allocation pass against the exact
previous compiler and tea. Specified and implemented general sharing of
unspecialisable updates and computed root selectors, plus adjacent dispatch
prefixes. Added paired/fuzz and emitted-shape regressions; the original compiler
fails the shape goldens. Re-recorded hashes with `zorg build test-run-hashes`.
Archived all final profiles, served bundles, source maps for attribution, raw
timings, counts, S0 campaign and full report-87 sweeps in research 97's dataset.

The frozen native/LLVM suites have only the two known macOS case-folding
failures; the full direct Chrome corpus passes. The hardware gate refuses this
macOS host as designed and remains owed on supported Linux hardware. No budget
or coverage was weakened. The 79-cell sweep has no slower-side disjoint-IQR
before/after comparison, with original Solid/P3 controls added for the ten
programs whose emitted bytes changed. Prepared the push and fresh Claude review;
the PR remains draft and unmerged.

**What I learned**

V8 lazy compilation charged to the dispatcher explains most of its excess
sampled self time: direct copied the entire tuple update and root selector
into each key. Sharing cuts raw Conduit source by 152,210 bytes and improves
feed/favorite/editor medians from .425/.4075/.450 ms to .340/.340/.3725 ms.
Brotli saves only 262 bytes because copies compress well: direct remains
6,379 bytes above tea, largely in template entries, masks and runtime. All
62 scripted dispatches still match prediction; criterion 7 does not fire.
CPU profiles can contain negative timestamp deltas; reconstructing and stably
sorting timestamps as DevTools does is necessary before clipping intervals.
Sampled allocation and unknown host stacks do not justify an allocation-only
CPU percentage or a zero-GC claim.
