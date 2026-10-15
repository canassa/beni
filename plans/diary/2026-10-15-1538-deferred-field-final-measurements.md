## 2026-10-15 15:38 CEST — final deferred-field measurements

### What I did

Refreshed every three-way median after the review's mutation-site assertions
and the callback benchmark correction. The measured compiler sources are
36a879521; all three compilers are LLVM ReleaseSafe on the same M2 Pro, paths
and --jobs=1 --no-cache inputs. Twelve measured runs per compiler follow one
warm-up triple, with all six execution orders twice. No builds, verification
runs or native sampling overlapped timing. The old samples remain in git history.

Updated the report, retained JSON, source hashes and complete native profiles.
The updated TaskBoard has 34 unannotated callbacks, all 40 accesses initially
flexible. The realistic corpus has 19 files/3,779 lines, and the enriched 100k
has 645 files/100,210 lines. Existing prepend/argument-order warnings remain
byte-identical; neither corpus gains diagnostics.

### What I learned

Checking medians in before/master/follow-up order:
- Annotated 63k: 46.91 / 69.94 / 33.56 ms.
- Unannotated 63k: 45.75 / 145.05 / 40.10 ms.
- Original 100k: 66.21 / 68.34 / 67.53 ms.
- Updated realistic corpus: 6.29 / 7.04 / 6.75 ms.
- 100k plus TaskBoard: 67.48 / 67.92 / 68.77 ms.

Both synthetic files beat the pre-#126 baseline. Corpus ranges overlap; the
report states their small median increases rather than claiming precise recovery.
The final unannotated profile has 91/1,347 checker samples in rank adjustment
(6.8%); mutation assertions are included in attachment/lowering work. Remaining
row attachment/draining cannot be removed by assuming a record early.

The standalone dump evidence is 109 successful, unique invocations, all exit 0,
with identical streams. Context-dependent core/markup fixtures are verified by
the corpus harness with their proper context. Full self-hosted checks, LLVM
unit/corpus/ordering/determinism/formatting, the scaling test, and cold/warm
late-dispatch replay pass. Every existing golden and recorded output hash stays
unchanged. The Linux instruction-budget gate remains owed. The PR is unmerged.
