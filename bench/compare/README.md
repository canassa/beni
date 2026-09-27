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
(no run yet: the first run of the generated benchmark is pending)
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
