# Browser worker implementation on PR #1304

The owner authorized implementation on the existing PR. Large restructures
required by the decided design are specified first, then implemented. Stop and
notify the owner only for an undecided decision, a change to a decided design,
a rule exception, or an approach that sacrifices a guarantee or budget.

All development runs on Dagon. New code is beni or Zig. Use Zig's development
compiler and independent worktree caches. Scratch and TMPDIR stay under the
agent's owned ~/.cache/beni-agents directory. Agents do focused validation;
the manager reviews source, integrates changes and runs full gates serially.
Every agent cleans its owned worktree, local branch and scratch after its
commits have been retrieved. All accepted code goes to the same PR.

## Work and dependencies

| Work | Tracking | Validation and integration boundary |
|---|---|---|
| Generic runtime metadata independent of markup | #1293 | entryKinds symbol, Program, result and effect checks through check and build; legacy runtime compatibility; no unchecked public launch |
| Typed runtime storage migration | #1295 | Producer and storage census; typed renderer dispatch ABI and behavioral fixtures; specify Task continuations and scheduler before code; retain suspension protocol and exact native failures |
| Native binding generation | #1295 | Pinned WebIDL parser and merged index; deterministic generated nominal types and upcasts; reject malformed input and missing required adapter metadata; integrate through an actual build command |
| Build-wide planning and per-entry projection | #1294 | workers-emission.md; finite static entry discovery, isolated initializers, stable IDs, atomic output and jobs 1/8 fixtures |
| Shared-name wire plans and native backing moves | #1296 | Build-wide field and tag constraints; selective normalization; fingerprints, negative ownership tests and byte goldens |
| Managed runtime and complete APIs | #1297–#1300 | Callback protocol checks in v2; scoped cancellation, cleanup, defect domains, ports, transfer inventory, bounded pools and stream credits; real browser fixtures |

Compiler foundations may be integrated independently when complete and tested.
A public worker launch cannot land until the realm, Wire and ownership proofs
are present. Service Workers have a separate design. Proposal-only transfers
remain explicitly gated. The same PR stays open throughout implementation.

## Session status

The compiler foundation checkpoint d61f2d338 implements strict generic runtime
metadata, the Session-owned validated entry plan, pinned native binding catalogue,
typed Buffer primitive and prerender root correction. Full forced run-hash
recording and full unfiltered gates passed on Dagon; CI passed at f24952283.

Correctness follow-up e9dc0c179 preserves Buffer.make unit-argument evaluation,
including effects, exact defects and suspension, in development and release.
Its before/after regression, full forced run hashes and full gates pass.
Checkpoint ec03f09fc adds internal dynamic-import IR and a Zig-generated static
UI measurement driver. Full gates pass, including unchanged small-stack tests
and new deep-import coverage. This is internal IR, not new Beni syntax.

The typed Inline queue remains unlanded pending performance acceptance. The
frozen candidate passes individual release-byte limits, browser behavior and
focused compiler checks. The complete UI validation requirements and the existing
keyed-renderer prerequisites are recorded in [workers-ui-validation.md](workers-ui-validation.md).
No byte or performance budget is waived. Checkpoint 67f7e61a9 adds scalar
String-class lowering under the existing Html contract; browser behavior,
prerendering, forced run hashes and full gates passed.

Checkpoint eb89c341f preserves partial symbolic continuation metadata and nominal
declaration heads before checker stores expire, with validated private cache rows.
It does not yet check generated continuation bodies. The entry-discovery prototype
remains unlanded: its replacement must use compact summaries and a delta fixed
point rather than multiplying caller contexts. Complete-handler tail-write facts
are being validated separately, including shared-work and path-limit fallback.
The metadata checkpoint passes eight CLI/cache tests, eleven unit/fuzz tests and
full unfiltered gates. The existing optimized 100k-line benchmark records plain
and dispatch medians of 308,254 and 296,972 LOC/s; every candidate run exceeds
250k, with identical source hashes and inference counters. The compact entry
kernel has passed algorithm-level scaling/capture tests; checked-source
integration remains under review. Complete-handler tail facts now pass the
manager full gates and bounded-work regression suite; their integration receipt
is recorded below.

Neither changes production Task or authorizes worker execution. Remaining native
callback consumers, per-entry realm and Wire proofs, and public launching stay
gated. Every further accepted checkpoint stays on PR #1304.

## Complete-handler facts validation

The next compiler foundation retains bounded complete-handler write facts without
changing runtime lowering. A separate probe shares one additional work allowance
across the build; unsupported paths, path limits and exhausted work discard the
partial candidate and retain ordinary joined evidence. Route-bearing programs
remain joined without speculative probe work. Runtime command preparation and
DOM write ordering have not changed.

On the merged master baseline, the full unfiltered gates pass: 307/307 steps,
2058 passed and 17 existing skips. All 90 write-corpus ordinary views match the
baseline. Seventeen supplemental diagnostic expectations follow changed checker
reset sizes; two forced-budget regression inputs preserve their original failure
paths. The default work allowance is unchanged.

Manager-recalculated cost evidence contains 126 successful builds/captures and
36 positive native initialization events. All emitted trees and ordinary writes
and ownership evidence match. Pinned development Debug child-CPU medians change
by +0.16% for Caller, +3.89% for 64 keys and +5.61% for Static50. Independent probe
initialization medians are 143.280, 153.565 and 132.635 microseconds respectively.
Other Dagon users were active; these are descriptive compiler-cost observations,
not optimized throughput or UI acceptance. No budget is waived. The source change
is in backend write analysis, not the checked-type inference benchmark. Complete
handler lowering and UI/runtime performance acceptance remain pending.

Compact entry discovery and private typed entry roots have frozen focused-test
handoffs. They still require independent source review, integration, matching
cost validation and manager full gates before acceptance. Neither enables public
worker execution.
