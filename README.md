# beni

beni is a compiler for an Elm-like language that emits JavaScript, written in Zig.
It keeps Elm's semantics and error quality while being built from the ground up for
speed: flat data-oriented IRs, per-file parallelism, and a resident daemon that rebuilds incrementally.

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

Everything is specified before it is written: see [`docs/design/`](docs/design/) —
[`fast-compiler.md`](docs/design/fast-compiler.md) (why), [`language.md`](docs/design/language.md) (what),
[`frontend.md`](docs/design/frontend.md) (the implementation contract for the front end).
