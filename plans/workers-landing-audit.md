# Workers replay audit

| Release brotli bytes | master 1550a68d61 | replay |
|---|---:|---:|
| Empty | 467 | 467 |
| http | 3748 | 3748 |
| TodoMVC | 9075 | 9075 |
| conduit | 48184 | 48184 |
| Worker page addition (initial checkpoint) | — | +4633 |
| Worker download (initial checkpoint) | — | 3621 |

Part of #1612. Worker sizes are the initial paired-page measurements, not
remeasurements of the final fixes. The size target remains follow-up #1679.

The replay keeps master's Task and List representations. HostFree, raw-wrapper,
storage and typed-kernel migrations are excluded. Eight content-conflicted
files were resolved. The later independent fixes retained here cover trie/view
List wire values, Schema.Value provenance, defect names containing digits or
`$`, invalid managed frames and worker-private hooks.

The spike's entry-runtime twin and runtimeRunName APIs do not exist on master.
Its own entry runtime calls run directly; the validator rejects a suspending
runtime while allowing init to suspend inside its owned fiber. DirectWire and
Lifecycle pass Chrome in development and release. Master's resolver has no
core_app category; the worker bridge uses its own private fence instead.

The complete paired audit covers 1130 emit/run fixtures in both modes with
identical flags and output paths. Of 1123 ordinary programs supported by both
compilers, all 1123 release output trees match exactly. Development has 885
exact trees and 238 differences: only Task.mjs.map's embedded Task source text
and its derivative manifest hash change. All other source-map fields match.
There are zero JavaScript differences in either mode and no ordinary build
regressions. The manager approved these 238 honest metadata differences and
required that source maps remain unchanged. Five new replay-only fixtures and
two dedicated-worker fixtures are counted separately, not as ordinary matches.

Evidence is on dagon in ~/worktree-evidence/wd-fiber/workers-landing/:
byte-audit/REPORT.md, summary-final.json, results.json and retained output trees;
SPIKE-EDITS.md; master-pages.jsonl and paired page outputs. Full gates, Chrome
and Workers results are recorded separately before requesting review.

The replay's worker-reference branch copied descriptors on the recursive
`Lower.expr` stack, even when a program had no worker descriptors. In the
self-hosted ReleaseSafe build its frame grew from master's 400 B to 848 B.
Moving that lookup into a non-inlined helper reduces it to 464 B. Both unchanged
4095-term plus-chain tests fail before this factoring and pass afterwards in
development and release; no depth, stack or fixture cap changed.

The existing exact-demand parity inventory adds 50 rows across the worker realm
fixtures: 17 absent-to-accepted rows under #1079 and 33 rows across 17 fixtures
under #2127. A nine-line non-worker reduction reproduces
the storage-demand gap on master: v1 reports no demand and opt-in v2 rejects
the top-level Ref cell. No new exemption mechanism or checker work is included.
The stale copied unchecked summaries are removed only where the actual dump
is empty; the per-file audit is retained in the evidence folder.
