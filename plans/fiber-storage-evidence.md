# Fiber storage and core queues — 2026-11-04

Issues: #1719, #1857, #1858. Base: `46ea0f6676`. Dagon, pinned Node
24.19.0. Evidence: `~/worktree-evidence/wd-fiber/`.

The original review report's harness runs 50k and 100k fibers, three
repetitions per population. Parked storage is the slope of median retained
heaps; spawn+join is the median warmed `sj1` time at 100k. The loop and
sequence timings use the report's `benchx` harness. Raw JSON is retained.

| Measurement | Base | Candidate |
|---|---:|---:|
| Bytes per parked fiber | 2047.94 | 1698.44 |
| ns per spawn+join | 3374.04 | 745.37 |
| ns per non-parking point, loop | 10.69 | 10.66 |
| ns per non-parking point, sequence | 15.82 | 15.82 |
| Combined spawn/yield/cancel program, brotli bytes | 6286 | 6346 |
| Empty browser page, brotli bytes | 792 | 765 |
| Empty browser page with scratch hook patch | 792 | 750 |
| No-command TEA element with scratch hook patch | 4543 | 1485 |

The combined harness grows 60 brotli bytes (0.95%). It exercises cancellation
and yielding as well as spawn+join, retaining circular capacity growth/copy
and lazy hook plumbing alongside the remaining removable Chain queues. The
ring avoids per-job links but needs more shared code. A quick review found
no clean source simplification; the manager approved publishing this explicit
trade-off rather than adding a size workaround. The kernel changes follow
separately. Non-parking allocation remains 208 bytes per point, the inherited
ratchet rather than the zero-allocation target; the protocol slice owns it.

Every existing deterministic fiber-cost and compressed-size budget passes
unchanged. The five individually reviewed emit goldens shrink in raw bytes;
four shrink after brotli and Queue stays equal:

| Golden | Base brotli | Candidate brotli | Raw change |
|---|---:|---:|---:|
| FiberS1Start | 3565 | 3562 | −316 |
| FiberS2SpawnJoin | 3809 | 3782 | −261 |
| FiberS3ScopeFinalizer | 3967 | 3935 | −434 |
| FiberS4Cancel | 3828 | 3810 | −277 |
| FiberS5Queue | 4615 | 4615 | −214 |

Candidate gates ran once, with inherited failures compared to the supplied
exact-base `wd-escape/base-gates.log`. Added failures were shape expectations:
imports/cutoffs for Js.Fifo and Js.TaskHooks, the smaller runtime output tree,
five removed unused runtime guards, ownership paths and the five emit goldens.
Targeted reruns pass. The two new modules add two cutoff modules and fourteen
graph lines; the development browser tree removes eager Immediate,
MessageChannel/Port and List imports and adds Fifo/TaskHooks.

Every ownership-report mismatch has the same verdicts and counts as the exact
base, including accepted once counts (`ownership-vs-base.txt`). NestedLambdaSend
changes its callback summary from at-most-once to many: aggregate mutable Cell
storage conservatively merges callable provenance previously separated across
Refs. Sends, rejection locations, owned/borrowed payloads and all accepted
entries stay identical. Existing RecordCapture/WordsBrowser discrepancies
already occur in the base log and their goldens were not changed here.

The hidden-effect allocation fixture executes both a fresh factory's native
stdout effect and an effectful argument. An unread, genuinely allocation-only
Ref factory disappears. The array-store capture-flip fixture requires escaped
payload retention and rejects an unsound borrowed-word mutation.

The browser hook patch is saved as `browser-hooks.patch` in evidence and was
measured in a scratch copy of the platform chain. No DOM-lane file is included
in this change. The manager applies that patch after the DOM family merges.
