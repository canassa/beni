# bench/compare — cold type-checking against Elm, Gleam, Roc and PureScript

The same three programs are written idiomatically in five languages. Each is
copied N times as separate modules, and each tool's check-only command is
timed with every cache cleared. The fitted **slope** is the cost of one more
copy of the program, and the **intercept** is the fixed cost of starting the
tool and loading its standard library. The slope is the number to compare.
The intercept mostly measures process startup and how each tool loads its
dependencies.

## Results (2026-09-27)

The machine had an AMD Ryzen 9 5950X (16 cores, `nproc` = 32), Linux
6.12.110 on NixOS, and 32 GB of RAM. Every run was pinned to one core with
`taskset -c 2`, used each tool's single-thread switch, ran offline, and had
cold caches. Each cell is the median of 7 runs, in milliseconds, and N is
the number of copies. The raw samples are in `results/`.

| language | N=1 | N=2 | N=4 | N=8 | N=16 | N=32 | **slope ms/copy** | slope, fit on min | intercept ms | R² | ms / 1k tokens |
|---|---|---|---|---|---|---|---|---|---|---|---|
| **beni** | 11.7 | 14.8 | 21.5 | 34.7 | 60.2 | 111.3 | **3.21** | 3.16 | 8.6 | 1.0000 | **0.53** |
| Gleam | 22.7 | 34.5 | 59.0 | 108.7 | 207.6 | 405.5 | **12.36** | 12.15 | 9.9 | 1.0000 | 1.33 |
| Elm | 60.6 | 86.7 | 134.5 | 184.7 | 295.4 | 506.0 | **14.01** | 13.95 | 64.2 | 0.9949 | 2.30 |
| Roc | 63.3 | 87.3 | 132.8 | 243.6 | 410.0 | 812.0 | **24.02** | 22.62 | 39.3 | 0.9991 | 3.01 |
| PureScript | 1670 | 2861 | 5244 | 10099 | 19794 | 38854 | **1200.7** | 1066.5 | 479.6 | 1.0000 | 191.6 |

Size of one copy (three modules):

| language | tokens | non-blank non-comment lines |
|---|---|---|
| beni | 6072 | 1192 |
| Elm | 6101 | 1152 |
| Gleam | 9280 | 1467 |
| Roc | 7987 | 895 |
| PureScript | 6266 | 848 |

The runs were `results/2026-09-27-single.json` (all five languages) and
`results/2026-09-27-single-repeat.json` (the four fast languages, run straight afterwards). Between the two runs,
`elm/src/Interp.elm` and `roc/Data.roc` received formatter-only changes:
elm-format added three redundant pairs of pattern parentheses, and
`roc format` moved one line break. The first table was measured before
those changes, the repeat after them.

**Reading it.** One more copy of the three programs costs beni 3.2 ms on one
core, which is 0.53 ms per 1 000 tokens, or about 1.9 M tokens/s and 370k
non-blank lines/s. Against the others:

| | Gleam | Elm | Roc | PureScript |
|---|---|---|---|---|
| per copy | 3.9× | 4.4× | 7.5× | 370× |
| per token | 2.5× | 4.3× | 5.7× | 360× |

Gleam's ports have 50% more tokens, from its call syntax and `case`-for-`if`,
which is why its per-token figure is closer. beni's intercept is also the
smallest, even though the embedded `core/` and the node platform are checked
on every run. Elm's intercept (64 ms) is its fixed cost of startup, dependency
verification and loading elm/core's artifacts. It was not broken down
further.

**Repeatability.** The repeat run came out 5–13% slower for every language
at once: slopes of 3.62 (beni), 13.80 (Gleam), 15.47 (Elm) and 25.15 (Roc)
ms/copy. The machine was loaded (see Caveats), but the ratios held: Gleam
3.8×, Elm 4.3×, Roc 6.9×. Trust the ratios to about ±10%. The absolute
numbers depend on load.

### All cores (`--multi`): indicative only

Each tool used its default parallelism, with no taskset: beni with
`--jobs` defaulting to 32, Elm and purs with GHC's `-N`, and Roc with its
default thread count. This run happened while load averages were 23–45 on
32 threads, so it is noisy (Elm's R² is 0.91). It is kept in
`results/2026-09-27-multi.json` for the shape, not the numbers:

| language | N=1 | N=32 | slope ms/copy | slope, fit on min | intercept ms |
|---|---|---|---|---|---|
| beni | 22.6 | 69.3 | 1.50 | 0.64 | 21.5 |
| Roc | 68.8 | 293.8 | 7.11 | 5.15 | 61.7 |
| Elm | 231.5 | 419.2 | 7.32 | 5.12 | 185.1 |
| Gleam | 45.9 | 688.8 | 20.64 | 14.98 | 27.4 |
| PureScript | 1801 | 14612 | 412.3 | 306.8 | 834.3 |

beni, Elm, Roc and purs parallelise across modules. Gleam checks serially here, so it
only slowed under the load. Starting 32 worker threads costs beni about
13 ms, and Elm's GHC runtime about 120 ms, of fixed overhead.

## The programs

Each program is pure logic. There is no UI, HTML or I/O, and each uses only
List, Maybe/Option and String functions that every language ships. One
*copy* is the three modules together.

| module | what it does |
|---|---|
| `Interp` | tokenizer over a char list, recursive-descent parser (`let`, `let rec`, `if`, `fn`, application, 3 precedence levels), printer, and an environment-passing evaluator with closures. It runs 16 programs, including error cases. |
| `Tree` | left-leaning red-black tree keyed by `Int` (elm/core's `Dict` algorithm): insert, remove with `moveRedLeft`/`moveRedRight`, lookup, two folds, map, filter, union, height, and an invariant checker. |
| `Data` | a 20-row employee table built from records of records: nested record updates, `filter`/`map`/`sortWith`/`take` pipelines, group-by via association lists, per-group summaries, skill counts and per-country totals. |

The logic is the same everywhere, and every port prints the same 43 lines
(`--verify` checks this). The code follows each language's own idiom.

- **beni** is subject-first, with n-ary types (`Tree v, Int, v -> Tree v`),
  `giveRaise _ 10` instead of currying, and `beni fmt` layout. It uses no
  beni-only features: no `?`, no `<-`, no interpolation, no `where`, no
  dot-calls, no `Dict`. `==` and `<` are only used on `Int`, `String` and
  derived-equality types, as in Elm.
- **Elm** is formatted with elm-format 0.8.8.
- **Gleam** is formatted with `gleam format`. It uses `case` where the others
  use `if`, and `string.to_graphemes` where the others use a char list.
- **Roc** uses the 0-alpha4 syntax (`|x|`, `f(a, b)`, snake_case). It
  keeps `when … is`, uses `List U8` for chars, and uses string
  interpolation, because Roc has no `++`. `roc format` crashes on `Tree.roc`
  (an `as` pattern), so that file is hand-formatted.
- **PureScript** uses `Data.List` with `:` patterns, `derive instance Eq
  Token`, and nested record update syntax.
- In every language, the `Result` chains in the parser are nested `case`
  expressions. The ports avoid `andThen`, Gleam's `use` and Roc's `?`, so the
  checkers see the same shape everywhere.
- Tree keys are `Int` in every port. That keeps the ports away from type
  classes, abilities and `where` clauses.

## Method

```sh
node gen.mjs <lang> <N> <dir>        # one N-copy project
node run.mjs --verify                # every port builds, runs, prints the same lines, N=2 prints them twice
node run.mjs                         # the table: N = 1,2,4,8,16,32, 7 runs per point
node run.mjs --multi                 # the same with each tool's default parallelism
```

`run.mjs` reads the tools from `BENI` (defaulting to `../../zig-out/bin/beni`),
`ELM`, `GLEAM`, `ROC`, `PURS` and `NODE`, and otherwise takes them from
`PATH`. Every tool came from nixpkgs:

```sh
nix shell nixpkgs#elmPackages.elm nixpkgs#gleam nixpkgs#roc nixpkgs#purescript nixpkgs#nodejs
```

The dependencies are fetched once and never during a timed run. For Gleam,
run `gleam deps download` in `gleam/`. For PureScript, run `spago build` in
`purescript/`, which fills `.spago/` (use `nixpkgs#spago`, the legacy 0.21
spago). The first `elm make` fills `~/.elm`. Roc's check needs nothing;
`--verify` downloads basic-cli 0.20.0 to run the Roc app.

**Scaling.** Copy k is the three modules renamed `App<k>Interp`, `App<k>Tree`
and `App<k>Data` (for Gleam, `app<k>_interp` and so on). These are separate
files and never one pasted module. A generated `Main` imports every copy and
concatenates their results.

**Cold.** Before every timed run, the runner deletes each tool's own caches:

| tool | timed command | cleared before each run | kept |
|---|---|---|---|
| beni | `beni check --no-cache --jobs=1 --platform=node .` | `.beni-cache/` (and `--no-cache` never reads or writes one) | nothing. `core/` is embedded in the binary and checked on every run. |
| Elm | `elm make src/Main.elm --output=/dev/null +RTS -N1 -RTS` | all of `elm-stuff/` | `~/.elm` (downloaded, precompiled elm/core and elm/json) |
| Gleam | `gleam check` | `build/dev/javascript/compare/` (the project's artefacts) | the precompiled gleam_stdlib artefacts |
| Roc | `roc check --max-threads 1 Main.roc` | nothing: `roc check` keeps no cache | builtins inside the binary |
| PureScript | `purs compile '<deps>/**/*.purs' 'src/**/*.purs' -o output +RTS -N1 -RTS` | `output/`, then the untimed restore of a deps-only `output/` | the dependencies' compiled output. purs still re-parses all 244 dependency modules on each run to build its graph. |

**Single core.** Every command runs under `taskset -c 2`, alongside the
tool's own switch where it has one. beni takes `--jobs=1`. Roc takes
`--max-threads 1`. Elm and purs take `+RTS -N1`, since both are GHC
programs. Gleam has no switch, so taskset alone limits it. `--multi` drops
all of this.

**Offline.** Every timed run is wrapped in `unshare -rn`, which gives it an
empty network namespace. Without it, `elm make` with no `elm-stuff/` asks
package.elm-lang.org for registry updates. That request cost about 600 ms
of a 860 ms run here, and none of it is checking.

**Statistics.** Every project is generated and set up first, and then run
once untimed to warm the page cache. The samples are then taken round-robin,
so sample i of every (language, N) point is taken before any sample i+1.
Background load then falls on every language alike. Each point is the median
of 7 runs, and the slope and intercept are an ordinary least-squares fit
over the six medians. Wall time comes from Node's `performance.now()` around
`spawnSync`, so process spawn is included, and it is the same for everyone.

**Size of a copy.** A consistent AST-node count across five compilers was not
available, so there are two proxies, both counted by `gen.mjs` with the same
rules for every language. *tokens* are lexical tokens after comments are
removed: a literal, a word, a run of operator characters, or one
bracket/comma. *lines* are non-blank, non-comment lines. Tokens are the
fairer proxy. Line counts follow each formatter (`gleam format` puts the
20-row table on 200 lines, while Roc keeps long lines), so ms/1k lines is
shown only for completeness.

## Versions

All tools came from nixpkgs-unstable (26.11 pre) on 2026-09-27.

| tool | version | dependencies used |
|---|---|---|
| beni | `beni 0.1.0-m1`, built from `3e924cc` plus 35 uncommitted paths, ReleaseFast, Zig 0.16.0 | embedded `core/`, `platforms/node` |
| Elm | 0.19.2 (`elmPackages.elm`) | elm/core 1.0.5, elm/json 1.1.3 (json is needed only for the port) |
| Gleam | 1.18.1, JavaScript target | gleam_stdlib 1.0.5 |
| Roc | 0-alpha4 (`roc`, the Rust compiler; `roc version` prints "built from source") | builtins; basic-cli 0.20.0 only to run `--verify` |
| PureScript | purs 0.15.15, dependencies fetched with spago-legacy 0.21.1 | package set psc-0.15.15-20260912: prelude, lists, strings, arrays, either, maybe, tuples, foldable-traversable, console, effect (244 modules in total) |
| Node | 24.19.0 | runs the runner and `--verify` |

## Caveats

- **What each tool does beyond checking.** The timed commands are not equal.
  - `beni check` parses, lowers, resolves, infers and checks
    exhaustiveness, and writes nothing.
  - `gleam check` also writes its cache artefacts.
  - `roc check` writes nothing.
  - Elm has no check-only mode. With `--output=/dev/null` it skips JS
    generation: writing `out.js` instead cost 13% more at N=32 (0.61 s
    against 0.54 s). It still builds and writes the optimized per-module
    `.elmi`/`.elmo` artifacts.
  - `purs compile` generates JavaScript, externs and corefn for every
    project module. Its time includes codegen and re-parsing 244 dependency
    modules.
- **PureScript's exhaustivity checker is the outlier.** The first
  `spago build` warned "An exhaustivity check was abandoned due to too many
  possible cases" in `Interp.parseExpr`, whose nested `:` patterns match 7
  tokens deep. `Interp` alone takes about 1.2 s of the ~1.7 s per copy. The
  other ports use the same patterns, so this is a real, idiomatic cost, but
  it is concentrated in one function.
- **Name repetition flatters the interners.** Copies differ only in their
  module names. Every identifier, string and field name appears N times, so
  string interning, hash tables and the CPU's caches see the same keys again
  and again. That favours any design that interns identifiers (beni's intern
  pool especially), and real code of the same size would intern N times as
  many distinct strings. The *slope* is the right number to compare, but it
  is an optimistic figure for every tool.
- **What differs in Main.** beni's `Main` imports the `node` platform
  (`--platform=node`, the same way `build` loads it). Elm's is a `port
  module` using `Platform.worker`. Gleam's imports `gleam/io`. Roc's is a
  plain module, since checking an app would also check the basic-cli
  platform. PureScript's imports `Effect.Console`. All of this is in the
  intercept.
- **Machine noise.** Another agent was running beni's test suites on the
  same machine throughout, with 1-minute load averages of 1–27 on 32 threads during the single-core runs and 23–45 during `--multi`.
  Pinning, interleaving and medians absorb most of that, but a single
  number is good to a few percent at best. R² is shown so a bad fit is
  visible.
- **Roc is a moving target.** alpha4 is the Rust compiler. Roc's rewrite in
  Zig is a different checker and is not measured here.
- **The beni tree was mid-change.** It was built from commit `3e924cc` with
  35 uncommitted paths in `git status --short`, a checker rewrite in
  progress by another agent, using
  `zig build -Doptimize=ReleaseFast`.
