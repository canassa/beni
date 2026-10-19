## 2026-10-19 16:04 UTC — Compiler latency takes priority

## What I did

The owner made the latency requirement explicit: beni must compile in milliseconds; a three-minute application build is a serious defect. Root paused new retirement and #470 implementation and assigned all three Codex implementers to #464 diagnosis and an exact correction. This is application compilation by ReleaseFast beni, distinct from Zig building the compiler itself. Neither memory savings nor incomplete bounded runs satisfy this requirement.

Frozen uncommitted word-storage prototype Fast binary 79435faff6ed3c1181306a5ca0a4990697582e21cb08c8b0fc37fb3500351bc4 checks the unchanged N64 research app in 42ms and builds development output in 82ms. Release optimization exceeded an external 180-second stop at 1.7GiB. Those runs isolate a release-optimizer cliff; they are not completed release measurements. A reduced single-module program without schemas also reproduces superlinear release work. No production flags, schema thresholds, inputs, budgets, precision or limits are changed to obtain a result.

An isolated correction marks object-spread reads and dependencies without constructing the unused union of all source fields. Root inspected the shared implementation: both paths retain seeSite, seeProps, all_read, and every property/.any view in order; destination copying is unchanged. A real corpus fixture fails the original 4300M instruction budget at 4401M and passes after the correction with the original emitted golden. Dependency tests compare exact records and wakeups. Matched Safe output trees are byte-identical. N16 falls from 55,720.5M to 35,074.1M instructions, with an observed 5702ms to 4113ms wall time: still far from the required latency. Full gates, a frozen Fast measurement and GitHub review are owed before this correction can merge.

Exact before/after diagnostic counters show the same graph, dependencies, joins and fixpoint rounds. N16 discarded union scanning falls 481.3M to 7.53M steps, but seven million property visits and twelve million dependency registrations remain. A residual Safe profile points to repeated already-contained site insertion searches. Agents are attributing that remaining work and proposing exact algorithm improvements; no new abstract domain or weakened analysis is authorized. #464 stays open. S1 fits and both required byte-identity measurements remain blocked and unclaimed; the last completed fit numbers above are unchanged. Lean remains paused.

## What I learned

Removing unused aggregate work preserves semantics but does not establish acceptable scaling. Track actual application compile latency separately from Zig compiler construction, and continue attribution until the remaining repeated work is explained. No new completed S1 fit is available.
