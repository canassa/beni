## 2026-10-23 03:01 CEST — specialise work wound down: the Amdahl study, and what is parked

**What I did**

- Profiled the whole build again after #791, #797 and #803. At `--jobs=8` N = 64 takes 110 ms and 100k 180 ms, and `specialise` is still the largest serial span: 48 ms and 108 ms.
- Measured fact 3 per kind of constraint (callgrind): about 20 helpers at 0.5–1.7% each, and nothing structural to cut. Values that are only primitive would save at most 0.5%.
- Wrote the Amdahl study on #464. It gives each serial span's wall time, its unit of parallelism, its dependencies and what rule 5 needs. Fact 3 per SCC is not viable: one SCC holds 70% of N = 64's constraints, through the host's callbacks.
- Removed work from the write-set pass: its gamma lists are kept across calls (#824, #826). The pass loses 16% of its instructions, N = 64 1.6%.
- Parked the larger levers on #827: specialise's walks and rewrite per statement, and lowering per declaration, with a design sketch and estimates.

**What I learned**

- `perf record` at a small sample period is throttled by the kernel and gives too few samples to annotate. Callgrind is exact, and `--toggle-collect` restricts it to one pass.
- The TEA programs are one big SCC through the host. That bounds every per-function parallel analysis on them, whatever the pass.
- Allocator round trips inside small, hot helpers were the cheapest win in the write-set pass. Look for those before designing parallelism.
