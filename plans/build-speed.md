# How long building beni takes — measured 2026-10-02

Zig 0.16.0 on a quiet machine (32 cores, load < 0.4). Each cold build used a fresh project cache and
the existing global cache. The edit was a one-line change under `src/`, reverted afterwards.

## Full builds, as `build.zig` is today

| Build | Wall | CPU | Largest process | Peak, all processes |
|---|---|---|---|---|
| Debug, cold | 9.0 s | 19.8 s | 425 MiB | 568 MiB |
| Debug, no-op | 0.3 s | 0.3 s | 55 MiB | 74 MiB |
| Debug, after an edit | 7.6 s | 16.5 s | 424 MiB | 510 MiB |
| ReleaseFast (LLVM), cold | 3 min 29 s | 213 s | 2 371 MiB | 2 557 MiB |
| ReleaseFast (LLVM), after an edit | 3 min 28 s | 210 s | 2 358 MiB | 2 424 MiB |

- An edit costs nearly what a cold build does. Every edit under `src/` changes the compiler build id
  (`build.zig` `compilerBuildId` hashes all of `src/` when the build is configured), so three steps run
  in series: compile the core-pack maker (~2 s), run it (0.24 s), compile beni (3–4 s).
- LLVM runs on one thread (CPU ≈ wall), about 3× the "about 70 s" CLAUDE.md quotes. Not yet
  explained; the maker possibly being a second LLVM compile is the first thing to check
  (`--summary all`).

## Incremental compilation

`build.zig` never turns it on, and Zig 0.16 leaves it off by default.

- `-fincremental` without `--watch`: an edit takes 6.6 s instead of 7.8 s. In 0.16 the incremental
  state lives in the compiler process that `--watch` keeps alive, so separate runs gain little.
- `--watch -fincremental` on a temporary step for a beni without the embedded core pack: first
  build 5.4 s, then **0.11–0.16 s** for a changed function body, a new struct field or a new
  function. Checked by changing the usage text and running the rebuilt binary.
- **It does not work with the real build**:
  1. Zig 0.16's Run step panics (`std/Build/Step/Run.zig:869`, `attempt to use null value`) when it
     runs the maker compiled under `-fincremental`: the compiler does not report the output path.
     Later rounds fail with `manifest_create FileNotFound`. 0.16 has no per-step incremental switch;
     newer Zig (`references/zig`) does.
  2. Under `--watch` the build id goes stale: the configure step that hashes `src/` is not re-run,
     so the binary carries an old id — its cache and embedded pack claim a compiler that no longer
     exists. A correctness problem, not only a speed one.

## Options — waiting for the owner

- **A. A dev-loop step** (`zig build dev --watch -fincremental`): checks core at run time instead of
  embedding the pack, and takes its id by hashing its own executable. ~0.1 s rebuilds for a person
  at a terminal. **Does not help agents**: they run separate one-shot `zig build gates`, and the test
  compiler is unchanged.
- **B. Make the real build incremental-safe**: the maker outside the incremental graph, the build
  id computed during the build. Needs a `fast-compiler.md` §8 change. Helps agents only with a
  long-running watch process per worktree.
- **Narrow the build id** so the pack is keyed on what the checker reads, not all of `src/`: an
  edit to, say, `src/js/` would not rebuild or re-run the maker (−~2.3 s of ~7.8 s on every one-shot
  build, agents included). Also a `fast-compiler.md` §8 change; the risk is a pack that is stale
  because the key misses an input.
- **C. Report the Run-step panic to Zig upstream.**

First step before choosing: measure how a post-edit `zig build gates --summary all` splits between
compiling the test compiler, the unit-test binaries and running the suites.

## Status, 2026-10-03 — incremental parked by the owner

On Zig 0.17 the Run-step panic is gone and `-fincremental --watch` rebuilds beni in ~0.75 s, and
the build id is now made by a build step (`fast-compiler.md` §8, amended), so one-shot builds and
plain `--watch` always carry the right id. `-fincremental --watch` still does not: Zig's build
runner sends a live compiler only "update", never a changed command line, so every generated
module (the id, the checked core pack, the embedded core and platform files) stays the first
build's. Options were an upstream patch, generated files at fixed paths, or no incremental for
beni's compile steps. **The owner stopped the incremental work here**; it is not to be resumed
without the owner.
