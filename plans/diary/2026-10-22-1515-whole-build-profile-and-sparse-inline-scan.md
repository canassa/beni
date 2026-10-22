## 2026-10-22 15:15 CEST — whole-build profile and a sparse inline scan

**What I did**

- Profiled the whole N = 64 and `nowd` builds on master after #717 and #727, every phase, at `--jobs=1` and `--jobs=8`, and posted the table on #464. `specialise` ranks first: 51% of N = 64's instructions, and all of it serial. Fact 3 is about a quarter of the build: 22.7% in the first solve and 14.6% in the second (rounds, inclusive).
- Fixed the first cause I found (#742). `inlineScan` kept per module three columns as long as the whole program's names, and so it paid that length for every module it counted again. It now keeps one entry per name the module holds. The 100k `--library` build takes 4.1% fewer instructions, N = 64 0.25% fewer, and the output is the same everywhere.

**What I learned**

- `perf report` with call graphs on the 80 MB ReleaseFast binary hangs for 15 minutes or more because it resolves inline frames. `--no-inline -g none` with `--children` returns in seconds. `perf script -F ip,sym --no-inline` piped to a short Perl script gives the cost under each child of a function. The return address of a caller frame tells two calls apart, which is how the two solves were split.
- The `writes` phase in `--self-profile` is the write-set analysis, not file output. File output costs nothing measurable.
- dagon's load stayed at 40–90 for most of the afternoon, so the milliseconds are only good for ratios. Instruction counts are the measure to trust.
