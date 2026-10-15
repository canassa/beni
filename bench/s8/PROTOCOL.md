# Fixed measurement plan

Recorded before timing on 2026-10-15. Source: master 6c327a9f1.
No compiler, core, platform or application edits. No selective retries or added
samples after observing results. Build failures are findings. About two hours
of measurement-host time; stop with incomplete cells explicit if exhausted.

- Official js-framework-benchmark: four rounds, five samples per candidate and
  benchmark per round; vanilla, Solid, beni-tea, beni-direct rotated by round.
  Retain the upstream report for every round; pool all observations for the
  per-operation table. Official throttles remain; short throttled script
  medians are descriptive only, never the parity verdict.
- Unthrottled bench/ui table: 20 fresh pages per operation/candidate.
- All research 87 sweeps, full grid: vanilla, Solid 1, Solid 2, tea release,
  direct release, P3 wherever its generator exists. Two fresh pages/cell,
  five warm-up clicks then twelve measured clicks/page: 24 observations
  clustered in two pages. Stream: two three-second windows, informational.
- Criterion 6: 20 fresh pages per variant/platform/operation/size; sandbox,
  routing/no-edit, vanilla; add, toggle, clear; 100 and 1,000 todos. Untraced,
  rate 1. Existing setup/six toggle warm-ups outside timing.
- Conduit: 20 fresh pages per platform/message/mode; feed, favorite, editor
  input. Untraced is primary; the existing separate traced pass is diagnostic.
- Full TodoMVC: 20 fresh pages/platform/message; add, toggle, clear at 100
  todos (routing, editing, persistence included). Sternhalma: 20 fresh pages
  per platform/message; choose two players, new game. Native CDP input,
  untraced, rate 1. No synthetic drag timing is passed off as native input.
- Bike Wars: attempt clean production release on both platforms. If direct
  cannot build, retain errors, do not time a replacement application.
- Real application bytes: clean release, no external minifier, brotli 11
  with size hint, app/core/runtime split using release source maps; source-map
  build must match executable bytes. Ordered stubs account compression, not
  independent downloads. Also retain leave-one-out core for criterion 5.
- S0 statistics, Conduit predicted/actual visits, floor, gate and Chrome
  correctness checks outside timing. Existing V3 campaign debt is reported,
  never silently discharged by corpus passes.

CPU affinity: harness 0–1,6–7; Chrome 2–5,8–11. Existing governor retained.
The Chrome wrapper pins every Chrome child, including those of official JFB,
without moving the Node harness onto the browser cores. Full provenance and
load go in results/machine.txt and per-sample artifacts.

## Runner semantics discovered before select results

The upstream `--count=5` retains ten additional runs for select per round:
select therefore has 60 retained observations, the other CPU operations 20.
This was found in runner source before any select result was inspected. Native
select behavior is retained, not an extension chosen from measured values.
The original estimate also underestimated memory: each five-sample memory
cell costs about 80–90 seconds. The owner was asked whether to finish the
fixed batch (projecting roughly 2¾ hours total) or stop near two hours with
incomplete cells explicit. No sample count is increased in either case.

## Budget cap, decided before comparative results were inspected

At 13:59 CEST, with round 0 still on its third candidate, cap JFB at **two
complete rotated rounds**: 10 ordinary CPU observations, 30 select observations,
10 memory observations per cell (size follows the native runner). Retain all
other announced counts. This applies to every candidate and operation alike;
no measured cell or observation is dropped. It leaves time for every requested
scenario within approximately two hours. The initial four-round plan above
remains recorded as a planning error, not rewritten as what was promised.

The original shell had already parsed its four-round loop. Its parent shell
was paused while round 0's child continued normally, then removed only after
round 0's meta.json confirmed completion. `time.sh --after-round-0` continues
with round 1 and all remaining scenarios. No Chrome or running benchmark was
interrupted by this scheduling change. The final `time.sh` reproduces the two
retained rounds from scratch.

## Build-barrier correction and clean plan

At about 14:14 CEST, the first completed JFB report exposed a compiler SHA
mismatch with the initial machine capture. Preparation had begun before the
compiler build completed; the direct table's actual bytes differed. All JFB
timings from that setup epoch are invalid, including its completed cells.
They are preserved under results/invalid-build-race and excluded wholesale.
The owner was told immediately. No UI sweep or app timing had run yet.

The completed compiler (af3e0494dbad405fd55ef5abe87127040d31468d27e6566d8a49854b8c37b0d9)
is frozen at zig-out/beni-s8-frozen. Every benchmark candidate is rebuilt.
Before the clean first timing, artifacts.mjs records the compiler and prepared
JavaScript hashes and checks the UI table against an independently built copy.
The same manifest is checked again after timing.

To honor the approximate total budget, the **clean fixed counts** are:

- JFB: **one batch, five observations per ordinary CPU and memory cell,
  fifteen per select cell** (upstream's extra ten), native single size sample.
  All four candidates rotate at each of the thirteen CPU/memory/size operations.
  The official report is retained. This smaller native-report sample is a
  limitation; its short throttled script values are never the parity verdict.
- Unthrottled bench/ui table: **20 fresh pages/cell**, unchanged.
- All research-87 sweeps: **two pages × twelve measured clicks/cell**, five
  warm-ups/page; stream two three-second windows, unchanged.
- Criterion 6 and full-app native messages: **20 fresh pages/cell**, unchanged.
  Conduit additionally retains the existing separate 20-page traced diagnostic.

These counts are fixed before clean results. Nothing is extended or selectively
repeated. Valid application bytes and Conduit counts already identify the
completed compiler and remain valid; only the contaminated comparison epoch
is discarded. The initial larger plans above are retained as history, not
rewritten to conceal the scheduling/setup errors.

## Owner confirms full counts

At about 14:22 CEST, while the clean first JFB round was running and before
its comparative report was inspected, the owner answered **“Finish the fixed
batch”** to the question about preserving the original counts versus stopping
near two hours. This supersedes the time cap and smaller clean JFB plan above.

The final plan restores the **original four rounds × five ordinary CPU/memory
observations**, with upstream select's **four × fifteen**. No valid sample is
rerun: the clean first round becomes round 0, followed by three rounds on the
same frozen artifacts. Candidate order rotates per operation and its starting
candidate rotates per round. All other originally announced counts remain.
The clean first round's scheduling parent is held until its native report is
complete, then the continuation runs the remaining three rounds and every
remaining scenario. No running benchmark is interrupted by this scheduling
change. No counts are increased beyond those announced before the initial
campaign; the owner's reply restores them after the global setup invalidation.

## Conduit order correction before its timing

The existing Conduit harness rotates then reverses odd rounds. With three
candidates that balances order; with two, the reversal cancels the rotation
and tea always runs first. Before any Conduit timing in this campaign, the
harness is corrected to reverse only when there are more than two candidates.
Its two-platform run now alternates order, with ten fresh pages in each position
per operation/mode/candidate. Raw records retain the actual position and the
campaign audit checks that balance. Counts and timed code are unchanged.

## Full-app setup wait, before its first timed message

At 17:15 CEST, the new full-app harness was waiting for real animation frames
after the corpus prelude had replaced them with its virtual frame queue. No
`apps-timing.json` existed. A live CDP observation retained in
`results/apps-setup-stall.json` confirms one queued virtual frame, 100 seeded
todos, and **no installed timing listener**. The process was stopped, together
with its own Chrome. The older unrelated idle Chrome was left alone.

The setup now calls the fixture's `settle` instead of awaiting virtual frames.
The complete ten-cell full-app grid starts with the original twenty fresh
pages per cell. No timed full-app observation was rerun, dropped or retained
from the stalled setup. JFB, table, sweeps, criterion-6 Todo and Conduit are
already complete and are not repeated. `apps-and-post.log` records this final
continuation through artifact verification and the post-timing checks.
