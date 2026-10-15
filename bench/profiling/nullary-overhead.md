# How much of #126's checking overhead does #135 remove?

Measured 2026-10-15 on Apple M2 Pro, 16 GiB, macOS 26.7.1 (25G241),
zorg 0.17.1+zorg.1. All three timing binaries are **LLVM ReleaseSafe**:
the verbose build commands contain `-fllvm -fstrip -Osafe`. Each revision
has its own worktree and local cache. Checks use `--jobs=1 --no-cache`.

| compiler | revision |
|---|---|
| Immediately before #126 | `134d24ab96c5b57f1917ed67af3b931a30a16add`, #126's first parent |
| Current master at measurement start | `2ca55a928` |
| #135 | `310fd78878744dac66fec97513322536401e9042` |

The earlier ReleaseFast, two-way comparison did **not** answer this question.
This comparison supersedes it for claims about recovery of #126's overhead.
The original review's machine and generator were not retained, so its absolute
284 → 401 ms numbers still cannot be reproduced exactly.

## Inputs and method

`bench/field-dense.py` generates 1,000 functions and 60,000 reads in 63,000
lines. The annotated version fixes each receiver to a three-field record.
`--unannotated` replaces only each annotation line with a comment, preserving
line and read counts while leaving receiver types flexible initially. Both
versions infer ordinary record reads and are accepted before #126 as well.

The 100k corpus is the same 644-file, 100,082-line generated input used in the
earlier comparison. The existing `fmt --migrate-names` migration removes its
generator's stale `modBy` spellings before any binary measures it. Its 85
argument-order warnings remain, identical across all three compilers. The
retained JSON fingerprints the actual input bytes and relative file paths.

One triple warms the executable and input pages. Twelve measured triples then
run through all six compiler orders twice. Each compiler reads the **same
absolute input path**. No build, instrumentation or native sampling runs during
timing. Other work on the host is possible. `field-dense-three-way.py` retains
every sample, computes medians, and asserts successful exits and identical
stdout/stderr on every invocation. The results below are sums of the per-module
`check` trace spans, which include constraint generation, solving and subsequent
checker passes. Process wall time and child CPU time are retained separately.

## Results: the fix is partial

Checking time, medians of 12 runs per compiler, milliseconds:

| input | before #126 | master | #135 | master − before | #135 − before | added cost removed |
|---|---:|---:|---:|---:|---:|---:|
| Annotated field file | 50.44 | 76.03 | 65.21 | 25.59 | 14.77 | **42.3%** |
| Unannotated field file | 49.38 | 153.05 | 152.95 | 103.66 | 103.56 | **~0%** |
| Generated 100k corpus | 68.32 | 70.85 | 70.18 | 2.53 | 1.87 | 26.4% arithmetically; noisy |

Recovery is `(master − PR) / (master − before)`, using the unrounded medians.
The annotated file regressed 50.7% on master and is still **29.3% slower than
before #126** with this fix: 57.7% of the added checking cost remains. On the
unannotated file, the PR remains **209.7% slower** than before #126.

The 100k corpus is not a strong recovery signal: its entire master regression
is only 2.53 ms, and check ranges overlap (before 66.13–74.04 ms, master
68.66–72.26 ms, PR 67.95–76.38 ms). Its arithmetic recovery fraction should not
be treated as a precise speedup. It contains only **357 field reads**, versus
60,000 in either synthetic input.

Whole-process wall medians, milliseconds:

| input | before #126 | master | #135 |
|---|---:|---:|---:|
| Annotated field file | 87.51 | 111.90 | 101.62 |
| Unannotated field file | 82.97 | 187.09 | 186.81 |
| Generated 100k corpus | 354.05 | 349.55 | 358.64 |

The corpus's many-file reading cost and host scheduling swamp its small checker
delta; its whole-process numbers do not establish any recovery.

## What remains

Additional, **untimed** counters classify each nullary dot when its method
constraint reaches the solver. The retained `nullary-counts.patch` adds only
diagnostic counters to a separate worktree. These counts were collected with
the self-hosted ReleaseSafe binary, not used in any timing above. Both builds
keep runtime safety enabled. Run its check without `--diagnostics=json`, so
the temporary debug output is not replaced by the JSON diagnostic renderer.

| input | initial record | initial flexible | PR fast path | rows still created |
|---|---:|---:|---:|---:|
| Annotated field file | 60,000 | 0 | 59,000 | 1,000 |
| Unannotated field file | 0 | 60,000 | 0 | 60,000 |
| Generated 100k corpus | 357 | 0 | 83 | 274 |

The remaining 1,000 annotated reads are the first read of each function:
the record has not yet acquired its cycle proof. In the unannotated file,
1,000 boundary defaults make receivers records and wake the other 59,000
reads. They all allocated both a wanted and an obligation before that point.
There are no recursive-frame, budget-edge or nominal receivers in these cases.

Native sampling of the PR, LLVM ReleaseSafe with debug symbols retained solely
for symbolisation, uses 8,000 functions / 504,000 lines for each field shape.
Sampling is at 1 ms, up to 2 seconds or process exit. The timing table uses
the original stripped binaries, not these profiling runs. The profile summary
counts inclusive stacks once per function, excluding repeated recursive frames.

| inclusive stack | annotated | unannotated |
|---|---:|---:|
| Module checker samples | 474 | 1,116 |
| Rank adjustment | 73 (15.4%) | **618 (55.4%)** |
| Rank invariant check (subset of rank adjustment) | 7 (1.5%) | **253 (22.7%)** |
| Obligation attachment | 0 | 33 (3.0%) |
| Ready-queue draining | 6 (1.3%) | 192 (17.2%) |

Thus the deferred rows' **traversal and rank/default bookkeeping**, not only
their allocation, are the important remaining cost. Each local binding creates
a boundary while its receiver still owns the preceding unresolved rows.
Rank adjustment and its safety check walk those owned dependencies repeatedly.
This is not evidence that the invariant checks may be disabled.

The annotated case also retains work before the fast path. `Expr.dotCall`
still creates a one-parameter function type and calls `Generator.called` for
every read; `Effects.call` appends an effect edge and site even when it later
becomes a record read. Phase medians expose the remaining cost:

| input / phase | before #126 | master | #135 |
|---|---:|---:|---:|
| Annotated / constraint generation | 10.53 | 12.86 | 12.93 |
| Annotated / solving | 33.50 | 51.26 | 42.41 |
| Annotated / effects | 0.99 | 4.80 | 4.15 |
| Unannotated / constraint generation | 10.26 | 12.88 | 12.85 |
| Unannotated / solving | 32.81 | 128.97 | 129.01 |
| Unannotated / effects | 1.08 | 4.76 | 4.85 |

The known-record fast path does not remove these generated method types or
effect edges. Ordinary field unification is also still necessary: its presence
in a profile must not all be charged to the regression.

## Can more be removed while keeping results?

**Yes, there are concrete candidates; the current PR has not implemented or
validated them.** The profile does not establish how much faster they will be.

1. Give bare dots their own compact constraint carrying receiver, result, name,
   site and the explicit ambient effect context. Delay construction of the
   method arrow and call-effect edge until resolution actually needs a call.
   A resolved record read can then use ordinary field unification without the
   extra function node, its generalisation work or its effect bookkeeping.
2. For a flexible receiver, retain a deferred dot row but materialise the full
   method wanted/callee site only when it resolves to a non-record requiring
   dispatch. A record/defaulted read need never allocate a method wanted.
   This needs the existing owner-rank dependency, original sequence positions,
   budget charges, cycle/rejection handling and recursive diagnostic provenance.
   It cannot just defer all bookkeeping until the end of a module.
3. Make owned-dependency walks visit actual dependants efficiently and avoid
   redundant traversal of already-settled dependencies. `Walk.eachOwned`'s
   flexible-variable arm currently loops through `owned`'s fixed-width slots;
   `Obligations.successor` returns self for unused, stale or closed slots. An
   iterator can avoid those no-op successors while preserving the order of
   actual edges. Avoiding repeated live-edge walks needs a stronger invariant
   or invalidation scheme, rather than simply skipping the rank check.

**What cannot be removed is the decision's deferral.** Eagerly turning an
unknown receiver into a record would change calls that become nominal later,
including declaration-order cases. Defaults must still precede closing other
wanteds at the owning binding boundary, and resolved methods must still reach
downstream passes as ordinary checked method calls. Any further implementation
needs the same corpus/output-hash, ordering and determinism comparisons.

## Reproduction and retained evidence

Build each pinned revision in its own worktree:

```sh
zorg build beni-fmt-check -Dllvm --verbose
# The measured executable is zig-out/safe-llvm/bin/beni.
```

Prepare one input directory, using the same generated corpus for all binaries:

```sh
zorg build bench -- --generate=100000 --iterations=1
zig-out/safe-llvm/bin/beni fmt --migrate-names .zig-cache/bench-gen
python3 bench/field-dense.py > /tmp/FieldDense.beni
python3 bench/field-dense.py --unannotated > /tmp/UnknownFields.beni
python3 bench/field-dense-three-way.py /path/pre/beni /path/master/beni /path/pr/beni \
  /tmp/FieldDense.beni /tmp/UnknownFields.beni .zig-cache/bench-gen > /tmp/three-way.json
```

For counters, apply `bench/profiling/nullary-counts.patch` to a separate #135
worktree, run `zorg build beni-fmt-check`, then its `zig-out/safe/bin/beni check
--jobs=1 --no-cache INPUT`. Counter slots are total, fast, initial record,
unproved record, flexible, other, recursive, budget edge, proved record,
boundary default, nominal decisions, record decisions. These are diagnostics,
not a proposed compiler change.

For native sampling, replay the PR's final verbose compiler invocation with
`-fno-strip` replacing each `-fstrip`, remove `--listen=-`, and emit a separate
binary. Generate each field shape with `field-dense.py 8000 [--unannotated]`,
start `check --jobs=1 --no-cache INPUT` and run `sample PID 2 1 -file OUTPUT`.

Retained results:

- [All timing samples, medians, input hashes and recovery arithmetic](../results/2026-10-15-nullary-three-way-safe.json)
- [Untimed branch/default counts](../results/2026-10-15-nullary-counts.json)
- [Native inclusive profile counts](../results/2026-10-15-nullary-safe-profile.json)
- [Temporary counter patch](nullary-counts.patch)
