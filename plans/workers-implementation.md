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
It does not yet check generated continuation bodies. The diagnostic entry checkpoint uses compact summaries and a delta fixed point
rather than multiplying caller contexts. Complete-handler tail-write facts retain
shared-work and path-limit fallback; runtime selection is still separate.
The metadata checkpoint passes eight CLI/cache tests, eleven unit/fuzz tests and
full unfiltered gates. The existing optimized 100k-line benchmark records plain
and dispatch medians of 308,254 and 296,972 LOC/s; every candidate run exceeds
250k, with identical source hashes and inference counters. The compact entry kernel and checked-source integration are described below.
Complete-handler tail facts now pass the
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

Compact entry discovery and private typed entry roots have now completed the
independent review, integration and matching cost validation described below.
Neither enables public worker execution.

## Diagnostic entry evidence checkpoint

Retain source-finite templates with symbolic formal/capture ports, source-call
substitution and Program declaration seals. A delta fixed point keeps runtime
bindings alive through late discoveries. Field lookup and metadata indexes,
shared record-update shapes and structural counters avoid caller-context and
source-width cross-products. Source control provenance survives captures and
nested field projection; opaque control remains unproved. Originating Program
initializer evaluation is retained until paired deferral/emission proofs exist.
Ordinary declaration liveness remains conservative.

Private dispatch format17 adds complete selected ordinary declaration schemes,
including private/inferred/polymorphic/aliased Program values, actual quantifiers,
identities, constraints and effects. Preliminary nominal selection does not
replace the full runtime contract. One pre-install coverage gate handles source,
directory, embedded pack and cutoff paths; insufficient embedded evidence retries
validated directory evidence before a source recheck. Pack generation uses a fixed
registered-chain selector union. Public interface bytes are unchanged. Owned role
views retain alias environments and remaining selector words; hidden inspection
preflights availability before any output and reports an explicit internal
failure for missing retained evidence.

Manager integration tests pass:29 real discovery CLI cases,14 typed-root cache
cases and8 existing continuation CLI regressions. Independent review found and
fixed nested materialization-control loss and partial output on missing evidence;
permanent before/after regressions cover both. The integrated source passes full
unfiltered gates:315/315 steps,2152 passed and17 existing skips. The prior isolated
runtime-alias correction a2ab6b6e3 also passes full gates and fixes #1464.

Matched a2ab6b6e3/candidate measurements on Dagon retain420 Debug command rows,
42 excluded warm-cache controls,12 optimized checker rows with4 actual CLI checks,
and64 full cold library builds (16 warmups,48 measured). All processes succeed;
complete emitted trees, inspector graphs, input hashes and inference counters
match. Warm controls report zero source checks and unchanged cache bytes. Ordinary
Debug CPU medians increase0.85–6.28%; candidate-only inspection CPU medians are
162.589–190.074ms across warm/cold selected and packed inputs. Those absolute
Debug costs are not optimized inspection or UI performance claims.

Every optimized candidate checker row exceeds250k LOC/s: plain median305332,
dispatch294135, minimum289971. Every measured candidate100k full cold build is
below800ms, including development/release and default jobs/jobs1; maximum572.061ms.
No samples were retried or dropped and no budget is waived. Source bodies and
public interface bytes remain equal. The real70-entry Debug pack grows2240B
(1680B complete-empty root headers plus560B column tables); its805036B public
interface payload is unchanged. The selected directory cache grows11116→13520B,
including2364B of retained roots in11 rows. These storage costs are explicit.

Discovery remains partial (`discoveryComplete=false`); higher-order/unsupported
transfers remain residuals. C, EntryHost, Wire, ownership, construction effects and
execution are unproved. Private nominal payload layouts, generated-continuation
certification, precise per-entry emission and public launching remain subsequent
work. No source-language change or callback/ownership exception was introduced.
