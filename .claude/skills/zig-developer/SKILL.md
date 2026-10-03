---
name: zig-developer
description: Use when writing, reviewing, debugging, or answering questions about Zig code in beni (an Elm-like language compiled to JavaScript, compiler written in Zig). Provides a Zig 0.16-to-0.17 change summary, an offline 0.16 language reference, and the vendored Zig compiler source for architecture. Check the installed Zig 0.17 standard library for exact APIs rather than relying on memory.
---

# Zig developer for beni

beni is a compiler for an Elm-like language targeting JavaScript, written in Zig.
The design is in [`docs/design/fast-compiler.md`](../../../docs/design/fast-compiler.md);
its evidence base is `docs/design/research/`. Zig breaks API between releases, so
**never answer Zig questions from memory** — look it up:

- **Std library source — THE GOLD STANDARD:** `references/zig/lib/std/`
  (submodule). Not just API docs: it is the reference for how to *write* Zig —
  naming, error handling, allocator threading, comptime usage, doc comments,
  test placement. Before writing any non-trivial module, find an analogous std
  module and mirror its conventions. When an exact signature matters, grep the
  source rather than guessing.
- **Language reference (offline, split by section):** `zig-langref/` (in this
  skill directory) — one Markdown file per top-level section, converted from
  <https://ziglang.org/documentation/0.16.0/>. ~1–20k tokens per file, ~130k
  total. It is now historical: first read [Zig 0.16 → 0.17](zig-0.17-changes.md)
  for version changes, then use the installed 0.17 std for exact APIs. When the
  older language reference helps, pick only the relevant section from its
  `README.md` index; never load the whole thing.
- **Memory/perf doctrine:** `memory-and-performance.md` (in this skill
  directory) — two-allocator discipline, arena `reset(.retain_capacity)`,
  indexes over pointers. Written for a long-running daemon; beni is one (§4 of
  the design doc), so it applies almost directly: long-lived session state
  allocated once, one arena per compilation phase per worker, reset between
  runs, and the hot paths never call the general-purpose allocator.

## The vendored Zig compiler is also an architectural reference

Unusually for this skill: `references/zig/src/` is not just "how to write Zig,"
it is **the design beni is copying**. When implementing an IR, read the
corresponding Zig file first — the design doc cites these by name:

| Topic | Read |
|---|---|
| SoA containers | `lib/std/multi_array_list.zig` |
| Flat AST, u32 indices, `extra_data` | `lib/std/zig/Ast.zig` |
| Zero-allocation tokenizer | `lib/std/zig/tokenizer.zig` |
| LL(k), no-backtrack parser + error recovery | `lib/std/zig/Parse.zig` |
| Interning types/values as `enum(u32)` | `src/InternPool.zig` |
| Per-file cacheable untyped IR (our BIR ≈ ZIR) | `lib/std/zig/Zir.zig`, `src/Zcu/PerThread.zig` |
| Declaration-level incrementality (`AnalUnit`) | `src/Zcu.zig`, `src/InternPool.zig` |
| Typed IR consumed by the backend | `src/Air.zig` |

`references/elm/` is the language reference (Haskell): its parser, constraint
solver and JS backend are what beni's semantics follow. `references/elm-core/`
is the `elm/core` package — the half the compiler repo does not contain, and
the one that matters for M3 and the boundary: `src/Elm/Kernel/*.js` is every
piece of privileged JavaScript Elm ships, including `Scheduler.js`, which is
how `Task` actually runs. See
`docs/design/research/05-elm-roc.md` for the phase-by-phase map.

## beni house rules (see docs/design/fast-compiler.md §5)

These are architectural invariants, not style preferences. Flag violations in review.

- **No pointer inside any IR.** References are `u32` indices into a named array,
  wrapped in `enum(u32)` with sentinel optionals (`none = maxInt(u32)`). This is
  what makes artifacts mmap-able with no fixup pass, nodes trivially copyable,
  and equality an integer compare.
- **Every IR is a `MultiArrayList` of small fixed-size records.** Variable-length
  payloads go in one shared `extra: []u32` sidecar, not in the node.
- **Offsets, never slices, into source text.** A slice is 16 bytes; an offset is 4.
- **No per-node allocation.** One arena per phase, owned by exactly one worker for
  its whole lifetime — prefer a single-thread bump arena over
  `std.heap.ArenaAllocator` on hot paths, to avoid its atomic RMW per allocation.
- **No `HashMap` keyed by a dense id.** Dense ids index parallel arrays. (Roc
  enforces this with a CI lint; we should too.)
- **Intern identifiers at lex time** into `Symbol = enum(u32)`, hashing while
  scanning. Interners are per-worker and merged at one sync point — a single
  global interner mutex measurably serialises parallel parsing.
- **Determinism is a requirement.** Stable, input-derived ids assigned *before*
  any parallel work; results re-keyed before merging, never ordered by
  completion. Two full builds must produce byte-identical output.
- **No global mutable singletons.** Everything hangs off `Session`; the compiler
  is a resident daemon and every structure must survive across edits.
- **The parser is LL(k) with committed choice.** Constant lookahead, no
  backtracking, guaranteed linear parse. Error recovery emits a structurally
  valid placeholder node rather than aborting.
- **Errors never stop the build.** A failed unification poisons a type variable;
  downstream unifications touching it trivially succeed.
- Panics mean bugs. No user input may reach one — every parser gets a
  `std.testing.fuzz` harness.

## Commands

The toolchain is pinned: `flake.nix` + `.envrc` (`use flake`) use Zig **0.17.0**
from `zig-overlay`, with Node 24 and jq from nixpkgs `nixos-26.05`. ZLS is
absent because Zig 0.17's new build protocol does not yet provide what ZLS
needs. Direnv puts Zig on `PATH`; `direnv exec . zig version` should print
`0.17.0`.

**The build graph exists** (M0–M1 shipped: lexer, parser, formatter, BIR lowering;
see `docs/design/frontend.md` for the contract and `git log` for the milestones).
Steps:

```sh
zig build                  # install zig-out/bin/beni
zig build test             # hermetic suite (Debug; add -Doptimize=ReleaseSafe too)
zig build test-blackbox    # spawns the installed binary; runs the corpus walker
zig build bench -- --generate=100000   # ReleaseFast per-phase throughput
zig build fmt-check        # zig fmt --check over src build.zig tests bench
zig build gates            # test, test-blackbox and fmt-check, concurrently
BENI_WRITE_EXPECTED=1 zig build test-blackbox   # bless corpus goldens (BENI_BLESS_ONLY=<substr>)
```

`zig build gates` takes about 10 s; run it whenever you want an answer, and
use `-Dtest-filter=` or `-Dcorpus=` to iterate on one failing test. See
CLAUDE.md's *Building* for `-Dllvm`.

**Submodule vs. toolchain — know which to trust for what.** The vendored
`references/zig` submodule follows master and may differ from the pinned 0.17
toolchain. The bundled language reference describes 0.16. So:

- **Architecture** (how the compiler is structured — the table above): read the
  submodule. That is what it is for, and master is the better reference.
- **API signatures** (what compiles against our toolchain): trust the installed
  std, which `zig env` locates. It prints **ZON, not JSON** — do not pipe it to
  `jq`:

  ```sh
  STD=$(zig env | sed -n 's/.*\.std_dir = "\(.*\)".*/\1/p')
  grep -n "pub fn getEmittedDocs" "$STD/Build/Step/Compile.zig"
  ```

  A signature copied from the submodule or 0.16 langref may not exist in 0.17.

For another toolchain upgrade, update the overlay pin, read the release notes,
fix what breaks, and update this summary and bundled reference as needed.
