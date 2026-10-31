## 2026-10-31 14:58 CET — validate private nominal payload layouts

**What I did**

Integrated the reviewed nominal-layout foundation onto accepted a4c75f36c, preserving
its early/escaping-error/dependency-taint evidence boundary. The shared cleanup now
owns nominal layouts with heads, continuations and typed roots. Publication uses
final declaring parameter Vars; all local constructors, private/unused types and
phantom/kind slots survive in ordinary private Interface schemes. Native/schema
rows explicitly retain unavailable contracts. Private dispatch advances17→18.
Shared constructor reading preserves public bytes and the existing public depth
policy; private written types use the iterative reader.

Kept original191fbe/correctedefe71ae/integrated2f9e freezes immutable. Parent
integration corrected the remaining declaration-head cache test's format18 column
offset. All11 nominal,14 typed-root,8 continuation and37 platform cases pass.
The pre-reporting-correction full tree passed318 steps,2167 tests,17 existing
skips. Final exact-tree unfiltered gates are required again after this receipt;
the run is retained as nominal-independent-review/manager-final-gates.log and the
commit validation records its result.

The real normal benchmark exposed a missing reporting mirror for9 new counters.
Added those fields only, with design specified first. Timing/Session options,
iterations, input generation, optimization and backend remain unchanged. Optional
nominal observations stay0 when profiling is disabled; actual work is measured
separately in profiled controls. CLI source/build identity is unchanged by bench
or prose. Final integrated patch13787673f34bc402545ec7dbec6a491cd98de4175a73d1bc654ff5d6ffbf8220.

Independently validated480 Debug rows (384 measured/96 warmups),60 controls,
12 normal optimized checker rows,4 actual semantic CLI checks and64 full cold
100k-line build trees (48 measured/16 warmups). Rehashed actual outputs, generated
source, cache public sections and binaries; checked named matrix counts, warm
source0, successful exits and exact stdout/generator receipts. Parent verification:
workers-implementation/scratch/nominal-independent-review/manager-cost-verification.json.
Raw SHA256 Debug9a3b61934f56736d9b59786018cadede27d7a25d16e21e411f2fec5635c0501f;
checker e8c8cc2f96bee7c9e70771a3c4b2bf50f172e5785754e5919ce059956431f660;
full-build fb2f97e67dd050797e2b41b51345648efa0c99002cc27270f4a2640f37949581.
Routine work used Zig development0.17 self-hosted Debug; normal LLVM ReleaseFast
was used only for existing optimized budgets. Other agent builds/drivers paused
for measurements; external ordinary compiler activity/load/affinity are recorded,
without a global-idle claim. No full suite/browser measurement overlapped.

**What I learned**

Every candidate checker row exceeds250kLOC/s (minimum284653; plain median300015
vs303114 baseline, dispatch286013 vs290329). Every measured candidate100k build
is below800ms:149.353011–575.796895ms, development/release and default/jobs1.
No sample, source case, counter or budget was dropped or waived.

Private all-local metadata has real costs. Debug CPU medians rise2.16–17.37%
across16 configurations; the largest is the32-unused-module cold check. This is
not speed parity. Peak-RSS median changes range−0.98% to+2.18%, highest candidate
median154180KiB. Actual70-entry embedded pack grows54004B =53444B nominal layouts
plus560B column tables;805036 public bytes remain identical. Directory public
sections and all compared emitted trees are identical; warm cache bytes stay
unchanged. Inspection output is intentionally extended after its exact old prefix.

The accepted baseline's first normal benchmark compilation crashed inside stripped
Zig/LLVM (SEGV address0x26e); the unchanged retry succeeded. Failure/core hash/GDB
receipts remain separate from measurements. No backend, flags, limits or source
workaround was used. The first parent validation assumed empty benchmark stderr;
corrected it to validate the exact expected generator receipt, preserving that
failed bookkeeping attempt. No measured compiler invocation failed.

The inherited identity-alias composition slowdown has independent baseline proof
and issue#1475; it is not claimed as fixed or introduced by this slice. No new
source cap is added. Public worker launching, cross-artifact substitution, Wire,
C/native adapters and continuation-body/ownership certification remain gated.
The separate queue/tail composition and its issue#1476 fix are not this checkpoint.
