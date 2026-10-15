# Deferred field reads after #135 (issue #131)

Measured 2026-10-15 on Apple M2 Pro, 16 GiB, macOS 26.7.1 (25G241),
zorg 0.17.1+zorg.1. All timing binaries are **LLVM ReleaseSafe**
(`-fllvm -fstrip -Osafe`), each built in its own worktree/local cache with
`zorg build beni-fmt-check -Dllvm --verbose`.

| Compiler | Revision |
|---|---|
| Immediately before #126 | `134d24ab96c5b57f1917ed67af3b931a30a16add` |
| Current master at measurement start | `2c4e2aee0a5be57606da36ee7c667ca46c6de427` |
| This follow-up, including #135 | `9a6efe69685230ad7af9cee649352e50dd9f71d3` |

## Identical inputs and method

The two 63,000-line files are unchanged from #135's retained comparison.
`bench/field-dense.py` generates 1,000 independent functions, each with 60
field reads; `--unannotated` replaces the annotation with a comment, leaving
receivers initially unknown. Both versions are valid before #126.

The generated 100k input is also unchanged: 644 files, 100,082 lines, with
its obsolete names already migrated, and 85 identical argument-order warnings.
Two extra inputs check the new realistic workload: the updated `bench/corpus`
(19 files, 3,795 lines), and the same generated input plus its new
`TaskBoard.beni` (645 files, 100,226 lines). TaskBoard contains 34 unannotated
`List.map`/`List.filter` callbacks over records; both new inputs check cleanly,
including before #126. The enriched input is formed by copying TaskBoard into
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
| Annotated 63k | 48.85 | 72.14 | **34.87** | **160.1%** |
| Unannotated 63k | 48.31 | 151.48 | **43.12** | **105.0%** |
| Same generated 100k | 67.66 | 68.56 | 67.68 | noisy |
| Updated bench/corpus | 6.44 | 6.78 | 6.54 | noisy |
| 100k plus TaskBoard | 67.01 | 66.75 | 68.74 | no master regression signal |

Recovery is `(master − follow-up) / (master − before)`, calculated from
unrounded medians. Above 100% means the net added cost is gone **and** the
ordinary field-read shortcut saves work that predates #126. It does not mean
that deferral itself costs nothing. The annotated case is 28.6% faster than
before #126; the unannotated case is 10.7% faster. Both beat the requested
"no more than about 10% slower than before #126" target. Versus master the
checking reductions are 51.7% and 71.5% respectively.

Do not infer precise corpus recovery from a sub-millisecond denominator.
The original 100k check ranges overlap: before 63.80–74.81 ms, master
65.01–72.63 ms, follow-up 65.76–69.67 ms. The other corpus inputs also overlap;
the enriched corpus is 2.6% above pre-#126 at its median, with no established
master regression to recover. These inputs verify broader throughput rather
than establish the field-dense recovery claim.

Whole-process wall medians, including loading and the frontend, milliseconds:

| Input | Before #126 | Master | Follow-up |
|---|---:|---:|---:|
| Annotated 63k | 84.00 | 106.96 | 68.77 |
| Unannotated 63k | 82.30 | 186.94 | 77.01 |
| Same generated 100k | 352.79 | 350.81 | 348.00 |
| Updated bench/corpus | 39.50 | 39.05 | 40.96 |
| 100k plus TaskBoard | 350.33 | 336.61 | 347.08 |

Selected checker phases (independent medians; this partial table does not sum
to total checking), milliseconds:

| Input/compiler | Constrain | Solve | Effects |
|---|---:|---:|---:|
| Annotated, before #126 | 10.18 | 32.70 | 0.85 |
| Annotated, master | 12.52 | 49.59 | 4.15 |
| Annotated, follow-up | 10.18 | 18.82 | 0.90 |
| Unannotated, before #126 | 10.28 | 32.30 | 1.07 |
| Unannotated, master | 12.63 | 128.49 | 4.54 |
| Unannotated, follow-up | 10.69 | 26.26 | 1.20 |

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
be quantified there. Its own boundary still walks it and checks the invariant.
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

Final native sampling uses the same follow-up sources and LLVM ReleaseSafe,
with stripping disabled solely for symbols. `sample PID 5 1 -file OUTPUT`
covers successful complete runs. Inputs use `field-dense.py 32000
[--unannotated]`: 2,016,000 lines and 1,920,000 reads. The extra independent
functions give enough samples for the faster compiler; each function retains
exactly the timing input's 60-read/boundary shape.

| Inclusive final samples | Annotated | Unannotated |
|---|---:|---:|
| Module checker | 1,101 | 1,452 |
| Rank adjustment | 133 | **115 (7.9%)** |
| Rank invariant assertion, subset | 7 | **6** |
| Ready-queue draining | 9 | 284 (19.6%) |
| Obligation attachment | 0 | 92 (6.3%) |
| Field unification | 91 | 124 (8.5%) |
| Cycle-proof assertion | 58 | 60 |
| Effects | 21 | 23 |

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
from 4,000 to 8,000. With the test copied to current master, the **actual
ReleaseFast test fails**: 140/536 ms child CPU, ratio **3.82**, above 2.5.
On the final follow-up it passes: 7/9 ms, ratio **1.28**. These are the
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

All 118 direct before/after dump comparisons match (interface/dispatch fixtures,
plus types/interface/dispatch/raw dumps on both synthetic files and both original
corpora). The 467 development, 467 release and 1,469 browser recorded output
hashes all match, with no stale hashes. No existing golden or run hash changes.
The Linux instruction-budget gate remains owed before merge: this Mac cannot
count it. #135 and the follow-up remain unmerged.

- [Every timing sample, input fingerprint and recovery calculation](../results/2026-10-15-deferred-fields-three-way-safe.json)
- [Final native profile counts and sample fingerprints](../results/2026-10-15-deferred-fields-profile.json)
