# beni

beni is a compiler for an Elm-like language that emits JavaScript, written in Zig.
It keeps Elm's guarantees and its error quality — no runtime exceptions, immutable
values, effects behind a controlled boundary — while being built from the ground up
for speed: flat data-oriented IRs, per-file parallelism, and a resident daemon for
incremental rebuilds.

The language is Elm 0.19 with a short list of deliberate departures, all of them in
[`language.md`](docs/design/language.md) §0. The largest is that there is no automatic
currying: every call is saturated, function types are n-ary and written `Int, Int -> Int`,
and partial application is written with a `_` placeholder. Arity is therefore part of a
type, so an arity mistake is reported where it is written rather than two arguments later.

**State.** The front end, the type checker and a first JavaScript backend are built and
measured. The daemon and incremental rebuilds are designed but not yet written; so is the
optimiser. [`fast-compiler.md`](docs/design/fast-compiler.md) §13 is the build order and
says where each milestone stands.

## Building

The toolchain (Zig 0.16.0, Node 24) is pinned by `flake.nix`; `direnv allow` puts it on `PATH`.

```sh
zig build                 # install ./zig-out/bin/beni
zig build test            # hermetic unit tests
zig build test-blackbox   # spawns the installed binary against temp projects
zig build bench -- --generate=100000   # per-phase throughput, ReleaseFast
zig build fmt-check       # zig fmt --check over src, build.zig, tests, bench
zig build --list-steps
```

## Design

Everything is specified before it is written, and the specification is normative: where
the code and a document disagree, that is a bug in one of them. See
[`docs/design/`](docs/design/).

| Document | What it settles |
|---|---|
| [`fast-compiler.md`](docs/design/fast-compiler.md) | why the compiler is shaped this way, the throughput budgets, and the build order |
| [`language.md`](docs/design/language.md) | the language: lexical structure, grammar, layout, formatting |
| [`frontend.md`](docs/design/frontend.md) | the implementation contract for lexer, parser, formatter and BIR |
| [`checker.md`](docs/design/checker.md) | the type checker: constraint generation, solving, generalisation, diagnostics |
| [`backend.md`](docs/design/backend.md) | JavaScript emission, pattern matching, dead-code elimination, chunking |
| [`boundary.md`](docs/design/boundary.md) | what `foreign` may do, what a platform package is, and how `main` is reached |

`docs/design/research/` holds the evidence the decisions rest on, and the two effects
proposals plus the review between them are the live design argument about how beni will
perform effects.
