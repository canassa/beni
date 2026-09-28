# bench/compare — cold type-checking against Elm, Gleam, Roc, PureScript and TypeScript

One Zig generator writes the same program in six languages, and each
language's check-only command is timed with every cache cleared, on one core.
The contract is [`docs/design/compare-bench.md`](../../docs/design/compare-bench.md);
this page is its summary, the latest numbers, and the caveats that go with
them.

## Method, in short

- **The program** is generated (`gen/`), never written by hand, and never
  committed: `bench/compare/work/` holds it. It is built as a typed tree and
  re-checked by an independent oracle (a small Hindley–Milner, exhaustiveness
  by usefulness) before any language sees it, then printed by one printer per
  language. It uses only what all five ML-family languages have (§2.1), and
  every compiler must accept it with no error and no warning (§11).
- **Eight families** of modules each stress one part of type checking
  (§4): long unannotated `inference` chains, generic functions at many
  instantiations (`polymorphism`), wide exhaustive `patterns`, expression
  `depth`, large mutually recursive groups (`recursion`), many types and
  fields (`data`), a deep graph of qualified `imports`, and an `everyday`
  mix. A *unit* is one module of a family, about 1 500 tree nodes.
- **Size** is k units of each family, at k ∈ {1, 2, 4, 8, 16}. The fitted
  **slope** is the cost of one more unit; the intercept is start-up and the
  standard library. Slopes are also given **per 1 000 tree nodes**, which is
  the same count in every language by construction (§5.3).
- **Two modes** (§6): *annotated*, every top-level function has a signature
  (the headline), and *inferred*, none has except the entry points.
- **Protocol** (§10): cold, offline (`unshare -rn`), one core (`taskset` plus
  each tool's own switch), one untimed warm-up that doubles as the acceptance
  check, rounds interleaved in a seeded random order, the median of 7 samples
  per point, and an OLS fit over the medians. The headline is **CPU time**,
  user + sys from `wait4`'s rusage for the compiler and the children it
  reaped; wall time is recorded beside it. The sizes are spaced geometrically,
  so the fit is weighted towards size 16, the point furthest from the mean
  size: the slope is mostly the step from 8 to 16 units.

```sh
nix develop .#compare                      # the compilers under test (§8)
zig build compare -- --prepare             # fetch dependencies, build Roc (once, online)
zig build compare-smoke                    # size 1, both modes: acceptance only
zig build compare                          # the full run: results/<date>.json and the tables below
zig build compare -- --quick --langs=beni,elm,gleam,roc,typescript
zig build compare-gen -- --seed=0x1 --size=2 --annotate=0 --langs=roc
```

## Results

<!-- compare:results:begin -->
Run `2026-09-27`: seed 0xBE11C0DE, sizes 1 2 4 8 16, 7 runs per point, CPU 2 pinned, load 2.0→2.3 (1-min average), offline. The generator is `sha256:1d2871b0b884`; the raw samples are in `results/2026-09-27.json`. Times are **CPU time** (user + sys of the compiler and its children, from `wait4`); wall time is recorded beside it.

**Total** (every family, one unit of each): the slope is CPU milliseconds per added unit, the cost of 8 more modules.

| language | annotated ms/unit | ms/1k nodes | × beni | R² | wall ms/unit | inferred ms/unit | ms/1k nodes | × beni | R² | wall ms/unit |
|---|---|---|---|---|---|---|---|---|---|---|
| beni | 6.07 | 0.736 | 1.0× | 0.9971 | 6.12 | 6.56 | 0.795 | 1.0× | 0.9833 | 6.61 |
| Elm | 27.40 | 3.323 | 4.5× | 0.9987 | 28.10 | 30.15 | 3.656 | 4.6× | 0.9960 | 31.27 |
| Gleam | 22.22 | 2.694 | 3.7× | 0.9985 | 22.59 | 20.73 | 2.514 | 3.2× | 0.9993 | 21.18 |
| Roc² | 92.57 | 11.226 | 15.2× | 0.9989 | 93.68 | 89.08 | 10.803 | 13.6× | 0.9971 | 90.11 |
| PureScript | 1003.58 | 121.701 | 165.3× | 0.9979 | 1013.10 | 942.50 | 114.294 | 143.8× | 0.9993 | 949.31 |
| TypeScript¹ | 39.61 | 4.803 | 6.5× | 0.9999 | 39.85 | 39.47 | 4.787 | 6.0× | 0.9982 | 39.70 |

² Roc's `check` also lowers and evaluates constants at compile time (compare-bench.md §9). Less its own `--timings` figure for *Shared Lowering and Compile-Time Evaluation* (measured once per point, in the warm-up), Roc's total slope is 79.53 ms/unit annotated (14% of it) and 78.72 ms/unit inferred (12% of it). This side figure subtracts a phase time Roc reports itself; the headline stays the whole `check`.

**Per family, annotated mode**, CPU ms per 1 000 nodes (slope over the family's own projects; additivity is Σ families / total):

| family | beni | Elm | Gleam | Roc | PureScript | TypeScript¹ |
|---|---|---|---|---|---|---|
| inference | 0.757 | 7.159 | 2.583 | 11.913 | 104.116 | 3.733 |
| polymorphism | 0.716 | 7.538 | 2.383 | 9.131 | 138.410 | 6.793 |
| patterns | 0.670 | 6.689 | 2.229 | 12.718 | 102.414 | 3.594 |
| depth | 0.597 | 5.146 | 2.024 | 6.023 | 167.638 | 3.866 |
| recursion | 0.642 | 6.830 | 2.774 | 13.458 | 112.221 | 4.390 |
| data | 0.606 | 5.099 | 2.773 | 12.599 | 79.654 | 3.807 |
| imports | 0.913 | 7.874 | 3.702 | 17.448 | 77.656 | 8.564 |
| everyday | 0.802 | 7.691 | 2.973 | 9.980 | 114.154 | 7.230 |
| total | 0.736 | 3.323 | 2.694 | 11.226 | 121.701 | 4.803 |
| additivity | 0.93 | 1.97 | 0.96 | 1.02 | 0.93 | 0.99 |

**Per family, inferred mode**, CPU ms per 1 000 nodes (slope over the family's own projects; additivity is Σ families / total):

| family | beni | Elm | Gleam | Roc | PureScript | TypeScript¹ |
|---|---|---|---|---|---|---|
| inference | 0.501 | 6.655 | 2.433 | 10.712 | 115.669 | 3.615 |
| polymorphism | 0.526 | 7.332 | 2.344 | 7.767 | 97.237 | 5.382 |
| patterns | 0.695 | 7.056 | 2.052 | 12.227 | 92.609 | 3.659 |
| depth | 0.546 | 5.072 | 1.814 | 6.608 | 166.126 | 3.675 |
| recursion | 0.567 | 6.271 | 2.647 | 14.575 | 133.800 | 4.821 |
| data | 0.607 | 5.331 | 2.560 | 12.637 | 86.265 | 3.569 |
| imports | 0.878 | 8.559 | 3.157 | 15.189 | 115.966 | 7.354 |
| everyday | 0.612 | 8.014 | 2.693 | 9.401 | 110.871 | 7.250 |
| total | 0.795 | 3.656 | 2.514 | 10.803 | 114.294 | 4.787 |
| additivity | 0.76 | 1.79 | 0.95 | 1.03 | 1.00 | 0.95 |

¹ TypeScript checks a different kind of program in its own idiom: structural assignability, no `Int`/`Float` split, parameters always annotated, and more annotations in the inferred mode than any other language (compare-bench.md §2.6, §6.3).

Signatures and typed binders written in the inferred mode, total project at size 16: 144 in beni, Elm, Gleam and Roc (Base and the entry points); PureScript needed none beyond them at this seed (the signatures and binder types of compare-bench.md §19 V10 are written only where its classes would be ambiguous, and are counted when they are); 7444 annotation sites in TypeScript (§6.3).

**Flagged (§10.6):** beni's additivity in the inferred mode is 0.76, outside 0.8–1.2: its family slopes do not sum to its total slope.

**Flagged (§10.6):** Elm's additivity in the annotated mode is 1.97, outside 0.8–1.2: its family slopes do not sum to its total slope. The cause is Elm's own runtime options (see *Caveats*): its per-family slopes are inflated by nursery first-touch faults, and its total row is unaffected.

**Flagged (§10.6):** Elm's additivity in the inferred mode is 1.79, outside 0.8–1.2: its family slopes do not sum to its total slope. The cause is Elm's own runtime options (see *Caveats*): its per-family slopes are inflated by nursery first-touch faults, and its total row is unaffected.

<!-- compare:results:end -->

## Versions and commands

| tool | how it is pinned | timed command (§9) |
|---|---|---|
| beni | this repository, ReleaseFast, built by `zig build compare` | `beni check --no-cache --jobs=1 --platform=node .` |
| Elm 0.19.2 | `nixpkgs-compare` (`flake.lock`) | `elm make src/Main.elm --output=/dev/null +RTS -N1 -RTS` |
| Gleam 1.18.1 | `nixpkgs-compare` | `gleam check` |
| Roc, the Zig compiler | `roc-lang/roc` at the commit pinned in `gen/main.zig`, built by `--prepare` | `roc check --no-cache --jobs=1 Main.roc` |
| PureScript 0.15.15 | `nixpkgs-compare`, packages via spago-legacy 0.21 | `purs compile … --codegen corefn +RTS -N1 -RTS` |
| TypeScript 7.0.2 | `nixpkgs-compare` (the Go compiler) | `GOMAXPROCS=1 tsc -p . --singleThreaded` |

Every results file records the exact versions, the `nixpkgs-compare` revision,
the Roc commit, the generator hash and the beni commit.

## Caveats (§10.7)

- **What each command does beyond checking.** beni and Roc write nothing.
  Elm writes `.elmi`/`.elmo` per module. Gleam writes its cache artefacts.
  PureScript writes CoreFn and externs, and re-parses every dependency
  module on every run. TypeScript parses and binds `lib.es5.d.ts`.
- **Gleam has no `if`**, so a two-way `case` on `Bool` stands in for it.
- **PureScript** resolves `Semigroup`, `Eq`, `Ord` and `HeytingAlgebra`
  instances where the others apply fixed operators. In the inferred mode it
  can need a signature on a recursive group whose type is class-constrained,
  or a type on a lambda whose constrained type nothing determines (§19 V10).
  The printer writes those only where a second inference run finds them, and
  counts them as annotations; the results say how many the published seed
  needed, which may be none.
- **Roc** (§2.5) is the new compiler written in Zig, measured at a pinned
  commit of `main`: its operators are static dispatch, its types nominal, and
  its constructors qualified through their type. It folds constant
  expressions at compile time and warns on a numeric literal whose type it has
  to default, so the generator keeps conditions and calls to generated
  functions tied to run-time values, and the Roc printer writes a type suffix
  (`37.I64`) on literals the checker might default (§19 V2).
- **Roc's `check` also evaluates constants.** Besides parsing and checking,
  it runs *Shared Lowering and Compile-Time Evaluation*: monotype
  specialisation, ARC, native code generation for the constants, and running
  that code. A review measured it at about 14–17% of Roc's slope with
  `roc check --timings`. The headline keeps the whole `check`, as for every
  language; a side figure subtracts Roc's own `--timings` number for that
  phase, measured once per point in the warm-up.
- **Elm's runtime options inflate its per-family slopes.** The `elm` binary is
  linked with `-with-rtsopts "-N -qg -A128m"`: a 128 MB allocation area. A
  single-family project allocates less than that, so every run pays the
  first-touch page faults of a fresh nursery that a larger project amortises.
  With `+RTS -A4m` a review measured the inference slope fall from about 6 to
  2.7 ms per unit while the total slope stayed at about 29. That is why Elm's
  additivity is near 2: its per-family figures are upper bounds, and its total
  row is unaffected. The timed command keeps Elm's own defaults.- **Elm** does not generalise an unannotated mutually recursive group, so
  outside its group a generic member of one is used at one type only, in every
  language (§6.2, §19 V9).
- **TypeScript**¹ checks a different kind of program in its own idiom:
  structural assignability, no `Int`/`Float` split, parameters always
  annotated, explicit type arguments where inference from arguments cannot
  work, pairs built by a generic helper, and immediately invoked arrows for a
  non-tail `case` or `let` (§2.6). In the inferred mode it still writes every
  parameter type and every recursive function's return type (§6.3), so its
  two modes differ less than the others'.
- **The machine is shared.** Interleaving, pinning and medians absorb most
  background load; the load averages at the start and the end are printed
  with every table, and R² shows a bad fit.

## History: the hand-written ports (2026-09-27, `f38eb30`)

Before the generator, this directory held three hand-written programs (an
interpreter, a red-black tree and a data pipeline) ported to five languages
and copied N times. Their results stay in `results/2026-09-27-single.json`,
`-single-repeat.json` and `-multi.json`. On that method one more copy cost
beni 3.2 ms against Gleam 3.9×, Elm 4.4×, Roc alpha4 7.5× and PureScript
370×. **It is a different method and cannot be compared with the tables
above**: the ports repeated every name N times, could not be shown to be the
same program, and measured the Rust Roc compiler.
