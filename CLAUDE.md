# beni

A compiler for an Elm-like language that emits JavaScript, written in Zig. It
keeps Elm's guarantees and error quality while being built for speed: flat
data-oriented IRs, per-file parallelism, and a resident daemon for incremental
rebuilds.

## Details about the project

- **Language**: Elm 0.19 minus a short list of deliberate departures, all in
  [`language.md`](docs/design/language.md) §0. The largest is that there is **no
  automatic currying**: every call is saturated, function types are n-ary and
  written `Int, Int -> Int`, and partial application is written `f a _`.
- **Target**: modern JavaScript, ES modules. `Int` is a double.
- **Compiler**: Zig 0.16, pinned with Node 24 by `flake.nix`; `direnv allow`
  puts both on `PATH`.
- **Budgets**: >250k LOC/s cold per core for checking, an 800 ms cold build for
  100k lines ([`fast-compiler.md`](docs/design/fast-compiler.md) §2).

## M0–M2 — complete

Token SoA, arenas, intern pool, benchmark harness and the determinism test; the
lexer, LL(k) parser with error recovery, BIR lowering and the formatter, all
parallel per file; then packages, the module graph, interfaces, the type store,
constrain/solve, exhaustiveness and DAG-parallel module checking.

## M3 — in progress

M3a emits JavaScript that runs, against the Node platform. Still to come: the
tail-call loop, decision trees for pattern matching, reachability-driven dead
code elimination, and chunking. [`backend.md`](docs/design/backend.md) is the
contract, [`fast-compiler.md`](docs/design/fast-compiler.md) §13 the build order.

**In flight across M3**: the no-currying change, sliced. Landed so far are the
removal of `>>`/`<<`, the `_` placeholder, the `let x <- e` bind, n-ary
function types through the parser, BIR and checker, and `core/` rewritten
subject-first with `|>` flipped to pipe-first. Still to come are saturated
calls in the backend.

M4 is the daemon and incrementality; M5 is source maps, code splitting and LSP.
Neither has started.

## Effects, and why they are blocked

[`transparent-effects-proposal.md`](docs/design/transparent-effects-proposal.md)
is the live design argument: two inferred bits per function, a fiber runtime, no
surface syntax. It cannot start until the no-currying change lands, because
effect flags have nowhere to live on a curried `{param, result}` chain.
[`research/17-platform-primitives.md`](docs/design/research/17-platform-primitives.md)
discharges its §10 item 0. A second constraint found there: the tail-call loop
must land **before** effects, because it is what lets `List.foldl`/`foldr` leave
`foreign`, and until they do the proposal's own headline example miscompiles.

## Building

```sh
zig build                 # install ./zig-out/bin/beni
zig build test            # hermetic unit tests
zig build test-blackbox   # spawns the installed binary against temp projects
zig build bench -- --generate=100000   # per-phase throughput, ReleaseFast
zig build fmt-check       # zig fmt --check over src, build.zig, tests, bench
zig build --list-steps
```

`beni dump --stage=tokens|ast|bir|types|interface` is the window into every
phase, and the dumps are corpus-tested, so they are outputs rather than
internals.

## The critical rules

### 1. The design documents are normative — specify before writing

`docs/design/` is not commentary. Where the code and a document disagree, that
is a bug in one of them, and the document usually wins. Every milestone here was
specified before it was written, and the one time that discipline slipped — the
2026-09-14 no-currying decision left in `fast-compiler.md` as a "pending spec
change" — nothing downstream of it could be implemented at all.

Read the contract for a phase before its code:
[`frontend.md`](docs/design/frontend.md),
[`checker.md`](docs/design/checker.md),
[`backend.md`](docs/design/backend.md),
[`boundary.md`](docs/design/boundary.md).

### 2. Never renumber a section in `docs/design/`

Hundreds of `§N` cross-references point into those documents from Zig source
comments, from corpus fixture intent comments, and from each other. Move text
between sections if you must; leave the numbering alone.

### 3. Tests are black-box, and they are the asset

The binary is a closed box driven by source files on disk and flags; its outputs
are emitted JavaScript, diagnostics and exit codes. **Every defect gets a fixture
under `tests/corpus/` that fails before the fix and passes after** — prove it by
stashing the fix. Prefer `tests/corpus/run/`, which executes the emitted
JavaScript, whenever behaviour is visible at runtime. In-source Zig tests are a
supplement and never the coverage.

A fully green `zig build test` has repeatedly coexisted with real defects that
only a corpus fixture or a read-only review caught. Treat a green suite as the
floor, not the evidence.

### 4. Three gates, and they pass on `master`

```sh
zig build test && zig build test-blackbox && zig build fmt-check
```

All three pass today, so a failure is yours. Never commit red or unformatted
code, and never commit a slice that is half-landed.

### 5. Determinism is a requirement, not an aspiration

Ids are input-derived and assigned **before** any parallel work starts — module
index comes from sorted path, never completion order. The determinism test runs
the corpus at `--jobs=1` and `--jobs=8`, twice each, and byte-compares every
stream and output file. Anything that makes output depend on thread timing is a
bug, not a trade-off ([`fast-compiler.md`](docs/design/fast-compiler.md) §10).

### 6. `foreign` is privileged, and `core/` is embedded

Only platform packages may write `foreign`, and `core/` is compiled into the
binary. A `foreign` value binds to a sibling `.js` file by name, one export per
declaration, and three build-time checks enforce the shape
([`boundary.md`](docs/design/boundary.md) §4). Do not widen that surface to make
something convenient.

## Operational

### Captain's log — `plans/diary.md` (APPEND AFTER EVERY SESSION)

`plans/diary.md` is an **append-only** captain's log of all work on this repo.
**At the end of any session where you did real work, append an entry** —
heading `## YYYY-MM-DD HH:MM TZ — <short title>` (get the real timestamp with
`date`), then **What I did** and **What I learned**. Newest entries at the
**bottom**; never edit or delete a prior entry (correct a past statement in a
*new* entry). **Do this proactively — do NOT wait to be asked.**

### Skills

`zig-developer` for any Zig syntax, stdlib or build-system question — Zig's API
churns between releases, so do not answer from memory. `write-tests` for the
testing discipline above. `commit` for the repo's commit format. `roc-zulip` for
primary-source evidence on how Roc's compiler works and why.

### References

`references/` holds large vendored submodules: the Zig compiler and std (the
gold standard for both idiomatic Zig and the data-oriented architecture beni
copies) and `elm-core`. Commit the submodule *pointer*, never vendored contents.
