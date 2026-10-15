## 2026-10-15 15:03 CEST — deferred field measurements

### What I did

Measured three LLVM ReleaseSafe compilers on identical absolute input paths,
--jobs=1 and --no-cache: before #126 (134d24ab9), current master (2c4e2aee0),
and the follow-up (9a6efe696). After warming, ran all six compiler orders twice
and retained twelve samples per compiler and input. No builds, native sampling
or test suites ran during timing. Every exit and output stream matched.

Retained raw samples, input and source fingerprints, phases and arithmetic in
bench/results, with the full report at bench/profiling/deferred-fields.md.
Added original 100k, updated real corpus, and 100k plus TaskBoard measurements.
Native final profiles cover complete successful runs on 32,000 independent
functions; their counts are qualitative, not an exact division of 63k timings.

### What I learned

Annotated checking: 48.85 / 72.14 / 34.87 ms before/master/follow-up.
Unannotated checking: 48.31 / 151.48 / 43.12 ms. Both beat the pre-#126 baseline;
recovery above 100% includes making pre-existing record unification cheaper.
Original 100k checking is 67.66 / 68.56 / 67.68 ms, with overlapping ranges.
The enriched corpus's median is 2.6% over pre-#126, also with overlapping ranges.

The final unannotated profile puts rank adjustment at 115/1,452 checker samples
(7.9%), including six invariant-assertion samples. Remaining deferred-row work
includes attachment and draining. Its decision cannot be made eagerly without
changing which programs check. Queue/effect-slot compaction remain unmeasured
opportunities; neither is needed to reach the requested target.
