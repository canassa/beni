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

## Review corrections

The empty FIFO now checks count before reading or writing capacity. A fresh
queue and a cleared queue previously returned undefined with exit 0; both now
exit 1 with `Error: an empty FIFO was shifted`. This protects platform callers
as well as the existing core callers that already check emptiness.

Lazy hook installation also sets the program scheduler's phase to stopped
when the bridge was stopped before registration. `ShutdownBeforeFirstFiber`
prints only its synchronous scheduled line, matching the exact base; the
pre-fix PR head wrongly invoked the new fiber's exit callback.

The allocation proof again accepts template chunks and templates whose parts
are inert. `AllocationOnlyTemplate` keeps a shared live Ref factory and an
unknown native string to prevent earlier folding: before the fix the unread
factory/template remains, afterwards it disappears and the program still
prints `dynamicab`. Existing hidden-effect regressions remain green. The
proof skips lowered modules with diagnostics, and a release build of
MarkupRestructured preserves its exact three diagnostics with no output.
The backend amendment now precedes the record-lambda discussion and explicitly
limits the new proof to top-level initializers in pruneOptimised.

Accepted callable-multiplicity precision debt is tracked in #1876.

The two correctness checks increase size. The manager authorized only the
minimum S1 and S5 cap changes: 3565 → 3579 (+14) and 4615 → 4633 (+18).
All other caps stay unchanged. Against a scratch core with the shutdown fix
but without the FIFO guard, the guard costs 13 and 14 brotli bytes respectively;
the phase fix also costs 4 bytes in each program. The previous S1 cap had
3 bytes of slack. A single attempted shared defect handler saved 2/1 bytes
there but worsened S4 compression beyond its cap, so that factoring was
reverted. The guard was never weakened. These cap reasons are recorded next
to the ratchets in budgets.json. The performance table above records the
pre-review measurement; post-review deterministic cost tests are checked
separately. No new full gates were run, as directed by the manager.
