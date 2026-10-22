# Deferred field reads after #135 (issue #131)

> Test policy, 2026-10-22: per-test instruction limits, grants and reference CPU
> requirements were removed (#740). Each test or corpus case now has a
> 120-second wall-clock hang guard. Older counts and budget references below
> describe historical evidence, not a current gate or an outstanding grant.
> Performance remains the job of `test-perf` and `bench`.


Measured 2026-10-15 on Apple M2 Pro, 16 GiB, macOS 26.7.1 (25G241),
zorg 0.17.1+zorg.1. All timing binaries are **LLVM ReleaseSafe**
(`-fllvm -fstrip -Osafe`), each built in its own worktree/local cache with
`zorg build beni-fmt-check -Dllvm --verbose`.

| Compiler | Revision |
|---|---|
| Immediately before #126 | `134d24ab96c5b57f1917ed67af3b931a30a16add` |
| Master including merged #135 | `d10749f70a2060230c99cd196d70c15c2666eb9b` |
| This follow-up, including #135 | `bf6ccdde4a33ce25262a61a169a34a574cd48c7e` |

The measured master includes #135 and the subsequent documentation update.
All three binaries were rebuilt in their own worktrees; source and binary
fingerprints are retained with these final samples. The recovery column
measures the **remaining** net overhead after #135.

## Identical inputs and method

The two 63,000-line files are unchanged from #135's retained comparison.
`bench/field-dense.py` generates 1,000 independent functions, each with 60
field reads; `--unannotated` replaces the annotation with a comment, leaving
receivers initially unknown. Both versions are valid before #126.

The generated 100k input is also unchanged: 644 files, 100,082 lines, with
its obsolete names already migrated, and 85 identical argument-order warnings.
Two extra inputs check the new realistic workload: the updated `bench/corpus`
(19 files, 3,779 lines), and the same generated input plus its new
`TaskBoard.beni` (645 files, 100,210 lines). TaskBoard contains 34 unannotated
`List.map`/`List.filter` callbacks over records. Its helpers infer their rows
before a typed summary uses them, so the callbacks actually start unknown.
An [untimed isolated counter](../results/2026-10-15-deferred-field-receivers.json)
confirms all 40 field accesses enter with flex receivers; the original annotated
version entered all 40 as structures. The counter patch is retained and is
never used for timing. The realistic corpus's existing prepend warnings and the
generated corpus's argument-order warnings remain byte-identical across builds;
there are no new diagnostics, including before #126. The enriched input is formed by copying TaskBoard into
the generated project root, alongside `Gen/`.

`bench/field-dense-three-way.py PRE MASTER PR INPUT...` runs one warm-up triple,
then 12 measured triples covering all six execution orders twice. Every run
uses the same absolute input path, `--jobs=1 --no-cache --diagnostics=json`,
and a self-profile trace. Successful exits and both output streams are compared
byte for byte on every invocation. No compiler builds, test suites or native
sampling run during timing; other host work is possible. The JSON retains all
samples, fingerprints, source hashes and arithmetic.

## Results

Medians of 12 runs per compiler, total checking spans, milliseconds:

| Input | Before #126 | Master | Follow-up | Added cost removed |
|---|---:|---:|---:|---:|
| Annotated 63k | 49.64 | 64.51 | **35.55** | 194.8% |
| Unannotated 63k | 47.81 | 147.50 | **42.60** | 105.2% |
| Same generated 100k | 67.87 | 69.94 | 69.02 | noisy |
| Updated bench/corpus | 7.35 | 8.36 | 8.17 | noisy |
| 100k plus TaskBoard | 67.77 | 69.06 | 69.41 | noisy |

Recovery is `(master − follow-up) / (master − before)`, calculated from
unrounded medians. Above 100% means the net added cost is gone **and** the
ordinary field-read shortcut saves work that predates #126. It does not mean
that deferral itself costs nothing. The annotated case is 28.4% faster than
before #126; the unannotated case is 10.9% faster. Both beat the requested
"no more than about 10% slower than before #126" target. Versus master the
checking reductions are 44.9% and 71.1% respectively.

Do not infer precise corpus recovery from a small denominator.
The original 100k check ranges overlap: before 64.95–73.68 ms, master 66.35–75.55 ms, follow-up 66.74–77.31 ms.
The other corpus inputs also overlap. Their follow-up medians are
1.7% (original 100k), 11.2% (realistic corpus) and
2.4% (enriched 100k) above pre-#126. These inputs verify broader
throughput rather than establish a precise field-dense recovery fraction.

Whole-process wall medians, including loading and the frontend, milliseconds:

| Input | Before #126 | Master | Follow-up |
|---|---:|---:|---:|
| Annotated 63k | 85.22 | 101.73 | 70.46 |
| Unannotated 63k | 80.89 | 180.92 | 75.46 |
| Same generated 100k | 348.88 | 352.39 | 345.47 |
| Updated bench/corpus | 47.37 | 47.18 | 49.41 |
| 100k plus TaskBoard | 355.17 | 353.94 | 356.68 |

Selected checker phases (independent medians; this partial table does not sum
to total checking), milliseconds:

| Input/compiler | Constrain | Solve | Effects |
|---|---:|---:|---:|
| Annotated, before #126 | 10.32 | 33.27 | 0.96 |
| Annotated, master | 12.98 | 41.92 | 4.06 |
| Annotated, follow-up | 10.48 | 19.01 | 0.92 |
| Unannotated, before #126 | 10.08 | 32.21 | 1.04 |
| Unannotated, master | 12.22 | 125.74 | 4.31 |
| Unannotated, follow-up | 10.52 | 25.97 | 1.22 |

## What changed and why it preserves results

Bare dots no longer eagerly construct method arrows or method wanteds.
An initially flexible receiver keeps an obligation whose dependant is the
result. It still waits for binding or the **same owner-rank boundary default**;
it never eagerly assumes a record. Non-record resolution materialises the
ordinary method path with the original sequence, frame and declaration.
Recursive frames and cycle/rejection/budget cases retain the ordinary path.

Effect positions are reserved during generation, so a late method retains the
same position relative to other call sites. Record reads leave an inert sentinel
which effect solving and planning skip. Real self-edges retain their original
behaviour. This removes the extra method function classes from ordinary reads.

Owned walks enumerate actual live dependants rather than three slots per row,
including self placeholders. Rank adjustment treats a non-generalised escaped
flex/rigid root as settled at a younger boundary: I15 already lowered its owned
closure on attachment and every strict rank drop, and none of that closure can
be quantified there. New/strictly lowered dependency roots are asserted at attachment and merge in
safe builds, before a younger boundary could quantify them. These check root
postconditions, not an independent proof of the whole closure; the construction
invariant through `lowerTo` remains the basis of the shortcut. This checks only the changed
edges rather than rescanning the growing set. Its own boundary still walks it
and checks the invariant.
Structural roots retain ordinary rank adjustment. This removes repeated walks
of the outer receiver's growing pending set at every local binding.

Finally, an existing dependency-free leaf field on a **direct record**, read
into a plain unconstrained flex, can unify directly without constructing a
temporary required record and extension. Both nodes are leaves, or the field is
a nullary nominal application, so this cannot fail or form a cycle. Aliases and
all other shapes use full record unification. The corpus caught alias diagnostic
spelling changes in an initial broader version; the final restriction preserves
them, with no golden changes.

## Profiles and remaining work

The #135 analysis found rank adjustment at 618/1,116 checker samples (55.4%),
including its invariant check at 253/1,116, on the 504k-line unannotated input.
The [retained earlier report](nullary-overhead.md) also cross-checks the actual
63k timing input. This motivated the dependency-walk change.

Native sampling uses the final checker at `bf6ccdde4` and LLVM ReleaseSafe.
The profile binary disables stripping solely for symbols. `sample PID 5 1 -file OUTPUT`
covers successful complete runs. Inputs use `field-dense.py 32000
[--unannotated]`: 2,016,000 lines and 1,920,000 reads. The extra independent
functions give enough samples for the faster compiler; each function retains
exactly the timing input's 60-read/boundary shape.

| Inclusive final samples | Annotated | Unannotated |
|---|---:|---:|
| Module checker | 1252 | 1328 |
| Rank adjustment | 132 | 98 (7.4%) |
| Owning-boundary assertion, subset | 6 | 4 |
| Ready-queue draining | 8 | 258 (19.4%) |
| Obligation attachment | 0 | 86 (6.5%) |
| Field unification | 105 | 97 (7.3%) |
| Cycle-proof assertion | 75 | 64 |
| Effects | 18 | 20 |

The mutation-site safety assertions are included in attachment/lowering work;
the assertion row lists only the full owning-boundary check.

These are qualitative inclusive stack counts, not an exact allocation of the
63k timing regression; before and after profile sizes differ and small counts
are especially imprecise. The medians above establish recovery. The remaining
unknown-receiver work is chiefly the real obligation's attachment and draining;
ordinary type checking and field unification still cost time too.

Further reductions could compact the pending/default queue or avoid more reserved
effect-site storage, provided the same dependencies and creation order remain.
Those are unimplemented opportunities, not measured wins. The receiver's deferred
decision cannot be removed: it may still become nominal, and eager record
assumption changes accepted programs. There is no remaining net synthetic
regression to justify weakening that guarantee.

## Regression evidence and validation

The new black-box `test-perf` scenario doubles reads on one unknown receiver
from 4,000 to 8,000. With the test copied to the earlier master baseline `2c4e2aee0`, the **actual
ReleaseFast test fails**: 140/536 ms child CPU, ratio **3.82**, above 2.5.
On the final follow-up it passes: 9/12 ms, ratio **1.33**. These are the
harness's CPU best-of-three scaling measurements, separate from the LLVM
ReleaseSafe median comparison above. Run it with:

```sh
zorg build test-perf -Dtest-filter='pending field reads scale'
```

The complete self-hosted `zorg build test test-blackbox fmt-check beni-fmt-check`
passes, with filesystem-sensitive temporary files on case-sensitive APFS and
the normal cache restored afterwards. The complete LLVM run passes too:

```sh
zorg build test test-blackbox fmt-check beni-fmt-check -Dllvm
```

All **109 successful unique** direct before/after dump requests match, retained
with command arguments, exit codes and stream fingerprints. The verifier requires
exit 0 and nonempty output. It covers standalone interface/dispatch fixtures,
all project interface/dispatch/raw dumps and selected module type dumps; contextual
core/markup fixtures remain covered by the complete corpus harness with their
proper privileged/platform setup. `dump` has no `--no-cache`, and `types` needs a
file: matching usage errors or missing-context diagnostics are excluded.

The added reverse-resolution diagnostic and late-dispatch fixtures force the
second receiver to become concrete first inside a deeper nested binding. Their
new goldens come from the #135 compiler and match the follow-up. A poisoned
receiver fixture pins the same single naming error. A final alias probe found
and fixed a numeric well-known-method bridge ordering regression: `(wrap 1).eq`
and `.compare` must bridge before retrying a flexible receiver at a
non-defaulting boundary. The new `NullaryNumericAlias` fixture and retained
[before/fixed comparison](../results/2026-10-15-numeric-alias-compatibility.json)
prove the previous reviewed implementation aborts while master and the final code emit
the same `too_few_args` diagnostics. A separate cold/warm cache
replay at jobs 1/8 under both compilers emits identical files and returns 14 in
Node on all four runs. The replay JSON retains each file's fingerprint.

The 467 development, 467 release and 1,469 previously verified browser hashes
match. Six newly promoted Bike Wars runs have stale records on this host on
unmodified master too. Independent re-recording on master and the PR verifies
the same runtime transcripts and produces identical hashes for all six. The
tracked hashes were restored: no existing golden or hash update is retained.
The Linux instruction-budget gate remains owed before merge: this Mac cannot
count it. #135 has since been merged by the owner; this follow-up remains unmerged.

- [Every timing sample, input fingerprint and recovery calculation](../results/2026-10-15-deferred-fields-three-way-safe.json)
- [Reviewed checker profile counts and sample fingerprints](../results/2026-10-15-deferred-fields-profile.json)

- [Successful dump comparisons](../results/2026-10-15-deferred-fields-dumps.json)
- [Late dispatch/cache replay](../results/2026-10-15-deferred-late-replay.json)
- [Untimed callback receiver counts](../results/2026-10-15-deferred-field-receivers.json)

The final optional review question is measured too: both late-dot sites are
created at rank 2; site 9 resolves first at rank 3, then site 7 at rank 2, with
owner rank 1 throughout. The isolated frame-counter patch and trace are retained.

- [Nested decision-frame counter](../results/2026-10-15-deferred-field-frames.json)
- [Bike Wars master/PR output comparison](../results/2026-10-15-bikewars-baseline-comparison.json)
