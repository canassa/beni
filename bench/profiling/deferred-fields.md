# Deferred field reads after #135 (issue #131)

Measured 2026-10-15 on Apple M2 Pro, 16 GiB, macOS 26.7.1 (25G241),
zorg 0.17.1+zorg.1. All timing binaries are **LLVM ReleaseSafe**
(`-fllvm -fstrip -Osafe`), each built in its own worktree/local cache with
`zorg build beni-fmt-check -Dllvm --verbose`.

| Compiler | Revision |
|---|---|
| Immediately before #126 | `134d24ab96c5b57f1917ed67af3b931a30a16add` |
| Master including merged #135 | `d10749f70a2060230c99cd196d70c15c2666eb9b` |
| This follow-up, including #135 | `b9e227f9aeda9d793c7bed46d627984448d70133` |

The measured master already includes #135 (`dd38d162e`); its subsequent
`d10749f70` update and the final feature-branch merge change documentation only.
Rebuilds produced identical compiler SHA-256 values, retained with the samples.
The recovery column therefore measures the **remaining** net overhead after #135.

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
| Annotated 63k | 47.68 | 62.43 | **34.16** | 191.6% |
| Unannotated 63k | 46.43 | 146.02 | **40.90** | 105.5% |
| Same generated 100k | 67.20 | 68.28 | 67.63 | noisy |
| Updated bench/corpus | 6.47 | 6.58 | 6.89 | noisy |
| 100k plus TaskBoard | 66.56 | 68.02 | 68.50 | noisy |

Recovery is `(master − follow-up) / (master − before)`, calculated from
unrounded medians. Above 100% means the net added cost is gone **and** the
ordinary field-read shortcut saves work that predates #126. It does not mean
that deferral itself costs nothing. The annotated case is 28.4% faster than
before #126; the unannotated case is 11.9% faster. Both beat the requested
"no more than about 10% slower than before #126" target. Versus master the
checking reductions are 45.3% and 72.0% respectively.

Do not infer precise corpus recovery from a sub-millisecond denominator.
The original 100k check ranges overlap: before 60.98–71.40 ms, master 66.91–72.70 ms, follow-up 65.25–75.03 ms.
The other corpus inputs also overlap. Their follow-up medians are
0.6% (original 100k), 6.6% (realistic corpus) and
2.9% (enriched 100k) above pre-#126. These inputs verify broader
throughput rather than establish a precise field-dense recovery fraction.

Whole-process wall medians, including loading and the frontend, milliseconds:

| Input | Before #126 | Master | Follow-up |
|---|---:|---:|---:|
| Annotated 63k | 81.89 | 96.85 | 69.25 |
| Unannotated 63k | 78.93 | 178.39 | 73.51 |
| Same generated 100k | 341.64 | 346.65 | 347.45 |
| Updated bench/corpus | 39.51 | 39.67 | 41.33 |
| 100k plus TaskBoard | 322.82 | 336.13 | 331.24 |

Selected checker phases (independent medians; this partial table does not sum
to total checking), milliseconds:

| Input/compiler | Constrain | Solve | Effects |
|---|---:|---:|---:|
| Annotated, before #126 | 9.89 | 31.85 | 0.84 |
| Annotated, master | 12.29 | 40.75 | 4.00 |
| Annotated, follow-up | 9.97 | 18.21 | 0.91 |
| Unannotated, before #126 | 9.79 | 31.19 | 0.98 |
| Unannotated, master | 12.03 | 124.29 | 4.23 |
| Unannotated, follow-up | 9.92 | 25.04 | 1.11 |

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

Native sampling uses the reviewed checker at `36a879521` and LLVM ReleaseSafe.
The later master update leaves every `src/check` file unchanged; the timing
comparison above was freshly collected on that updated base. The profile binary
disables stripping solely for symbols. `sample PID 5 1 -file OUTPUT`
covers successful complete runs. Inputs use `field-dense.py 32000
[--unannotated]`: 2,016,000 lines and 1,920,000 reads. The extra independent
functions give enough samples for the faster compiler; each function retains
exactly the timing input's 60-read/boundary shape.

| Inclusive final samples | Annotated | Unannotated |
|---|---:|---:|
| Module checker | 1033 | 1347 |
| Rank adjustment | 115 | 91 (6.8%) |
| Owning-boundary assertion, subset | 4 | 5 |
| Ready-queue draining | 6 | 273 (20.3%) |
| Obligation attachment | 0 | 80 (5.9%) |
| Field unification | 86 | 119 (8.8%) |
| Cycle-proof assertion | 65 | 70 |
| Effects | 17 | 20 |

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
On the final follow-up it passes: 7/10 ms, ratio **1.42**. These are the
harness's CPU best-of-three scaling measurements, separate from the LLVM
ReleaseSafe median comparison above. Run it with:

```sh
zorg build test-perf -Dtest-filter='pending field reads scale'
```

The complete self-hosted `zorg build test test-blackbox fmt-check beni-fmt-check`
passes, with filesystem-sensitive temporary files on case-sensitive APFS and
the normal cache restored afterwards. LLVM unit, corpus, ordering, determinism
and formatting checks pass via:

```sh
zorg build test test-blackbox-corpus test-blackbox-ordering \
  test-blackbox-blackbox fmt-check beni-fmt-check -Dllvm
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
receiver fixture pins the same single naming error. A separate cold/warm cache
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
