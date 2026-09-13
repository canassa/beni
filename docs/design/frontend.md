# Front-end implementation contract (M0 + M1)

**Status:** normative for the code written in M0 and M1. [`fast-compiler.md`](fast-compiler.md)
says *why*; [`language.md`](language.md) says *what the language is*; this document says *what
the code looks like* — the CLI surface the tests drive, the module layout, the shape of each
data structure, and the acceptance criteria per milestone. Anything here that later turns out to
be wrong is changed here first, then in the code.

## 1. CLI surface

`beni` is one binary. Every behaviour reachable in M0/M1 is reachable through it, because the
black-box suite may touch nothing else (see `.claude/skills/write-tests/SKILL.md`).

```
beni check  [options] <path>...                 parse + lower every module; report diagnostics
beni fmt    [options] [--check] [--stdout] <path>...   format in place / verify / print
beni dump   [options] --stage=<tokens|ast|bir> <file>  print one file's IR as text
beni version
beni help
```

Options common to all subcommands:

| Flag | Meaning | Default |
|---|---|---|
| `--diagnostics=text\|json` | diagnostics on stderr as Elm-style prose, or as one JSON array | `text` |
| `--self-profile=<path>` | write a Chrome trace-event JSON file at exit (§6) | off |
| `--jobs=<n>` | worker threads for per-file phases; output is identical for every `n` | logical CPUs |
| `--root=<dir>` | the source root that module names are derived from | see below |
| `--core` | treat the files as the core package: `foreign` declarations are legal (language.md §5.4). Used only to build and test core; never by user projects | off |

Paths: a `<path>` is a `.beni` file or a directory. A directory is walked recursively; every
`.beni` file under it is a module; hidden entries (`.` prefix) are skipped. Files are processed
in **sorted path order** and numbered before any parallel work starts — that file index is the
stable id every later structure is keyed by. Module names come from the path relative to
`--root`; without `--root`, the root is the directory argument for directory paths and the file's
own directory for file paths (so `beni check Main.beni` names the module `Main`).

Exit codes: `0` no errors, `1` at least one `error`-severity diagnostic, `2` usage or I/O
failure (bad flag, unreadable path). `fmt --check` exits `1` if any file would change.

Streams: `stdout` carries the product (dump text, `fmt --stdout` output, nothing for `check`).
`stderr` carries diagnostics and nothing else. Diagnostics are sorted by file path, then start
position, then code — regardless of `--jobs`.

### 1.1 Diagnostics

Module `src/diagnostic.zig` is a named build module `diagnostic` that imports only `std`. Both
the compiler and the black-box suite import it, so a field added, renamed or removed in
production fails the tests at compile time rather than silently.

```zig
pub const Severity = enum { @"error", warning };
pub const Position = struct { line: u32, col: u32 };          // 1-based; col in bytes
pub const Span = struct { file: []const u8, start: Position, end: Position }; // end exclusive
pub const Diagnostic = struct {
    code: Code,            // enum, the snake_case catalogue in language.md §10
    severity: Severity,
    span: Span,
    title: []const u8,     // "TAB CHARACTER" — Elm style
    message: []const u8,   // full prose, may span lines, no trailing newline
};
```

JSON form (`--diagnostics=json`): a single array on stderr, one object per diagnostic, field
names exactly as above, `code` and `severity` as strings. Text form: Elm's layout —

```
-- TAB CHARACTER ----------------------------------------- src/Main.beni:3:5

I found a tab character. Beni does not allow tabs anywhere in a file.

3|     view = 1
       ^
Use spaces for indentation. Inside a string, write \t.
```

Every code has exactly one `title`; the message may include the source excerpt with a caret
line. The renderer runs only when there is something to render.

### 1.2 Dump formats

`beni dump` exists so the parser and lowering have an *output* that tests can assert without
importing internals. Formats are text, deterministic, and pinned by corpus goldens. They carry
no positions (so a formatting change to the input leaves an `.ast` golden unchanged) unless
`--positions` is passed.

- `--stage=tokens`: one token per line, `<line>:<col> <tag> <text>`; comments are listed after
  the tokens under a `-- comments` heading as `<line>:<col> <kind> <text>`.
- `--stage=ast`: an S-expression tree, one node per line, two-space indentation, node tags as
  written in `Ast.Node.Tag`, identifier and literal text inline. Error placeholder nodes print
  as `(error <code>)`.
- `--stage=bir`: one declaration per block, then its instructions, then its interface entry.
  The implementer designs it; it must show every desugaring in `language.md` §8 legibly.

## 2. Repository layout

```
build.zig  build.zig.zon
src/
  main.zig            CLI entry: arg parsing, subcommand dispatch, exit codes
  beni.zig            library root: pub re-exports of every internal module; the hermetic test root
  diagnostic.zig      the public schema (named module)
  Session.zig         owns gpa, options, SourceStore, global InternPool, Profile, worker pool
  SourceStore.zig     file index → path, bytes ([:0]const u8), module name, line-start table
  Arena.zig           single-thread bump allocator (Allocator vtable), reset(.retain_capacity)
  InternPool.zig      Symbol = enum(u32); Local (per worker) + Global (merged, sharded later)
  Profile.zig         --self-profile: per-thread event buffers, counters, JSON writer
  lex/
    Token.zig         Tag, the SoA record, Comment record
    Tokenizer.zig     zero-allocation state machine over [:0]const u8
  parse/
    Ast.zig           Node, Tag, extra, the typed accessor "views"
    Parse.zig         LL(k) recursive descent + Pratt, recovery, layout
  bir/
    Bir.zig           the per-file IR
    Lower.zig         Ast → Bir: scopes, resolution, desugaring, interface skeleton
  fmt/
    Format.zig        Ast + comments + line info → canonical text
  dump/
    tokens.zig ast.zig bir.zig
  render/
    text.zig json.zig diagnostics renderers
tests/
  blackbox/
    world.zig         the harness (§7)
    blackbox_test.zig scenarios
    corpus_test.zig   the corpus walker
  corpus/
    parse/good/*.beni + *.ast        parses clean; AST golden
    parse/bad/*.beni + *.diag        must fail; whole diagnostic list golden (JSON)
    fmt/*.beni + *.expected          formatter output golden; every .expected is a fixed point
    bir/*.beni + *.bir               lowering golden
    regress/                         named after bugs
  fixtures/                         embedded into hermetic tests via addAnonymousImport
bench/
  bench.zig           zig build bench: per-phase throughput over bench/corpus, JSON lines
  gen.zig             deterministic synthetic-corpus generator (100k LOC, realistic shape)
  corpus/             checked-in real-shaped modules (grows forever; the pathological set)
```

Build steps: `zig build` (install `beni`), `zig build test` (hermetic), `zig build test-blackbox`
(spawns the installed binary; depends on install; cwd = repo root), `zig build bench`
(ReleaseFast, runs the harness), `zig build fmt-check` (`zig fmt --check` on `src build.zig
tests bench`). `test` and `test-blackbox` are never folded into one step.

## 3. Data structures

Rules from `fast-compiler.md` §5 apply verbatim: no pointers in any IR, `u32` indices wrapped
in `enum(u32)` with `none = maxInt`, `MultiArrayList` records, one `extra: []u32` sidecar per
IR, offsets not slices, arena per phase per worker, no `HashMap` keyed by a dense id.

### 3.1 Source

`SourceStore` holds, per file index: the path (owned), the module name, the bytes as
`[:0]const u8` (sentinel so the tokenizer needs no bounds check at EOF), and `line_starts:
[]u32` filled in by the tokenizer. Column of offset `o` on line `l` is `o - line_starts[l] + 1`.

### 3.2 Tokens

```zig
pub const Token = struct {
    tag: Tag,          // u8
    start: u32,        // byte offset
    line: u32,         // 0-based line index; column derived via line_starts
    payload: u32,      // Symbol for identifiers/keywords-as-text; 0 otherwise
};
pub const Comment = struct { kind: Kind, start: u32, before_token: u32 };
```

Thirteen bytes per token in four columns. The design doc's five-byte token gains `line`
(indentation is decided per token, §4 of `language.md`, and a binary search per token would cost
more than the column) and `payload` (identifiers are interned while scanning, §5.1 of the design
doc). Length is re-derived from `tag` + `start` by a `slice(source, index)` helper; for
identifiers and qualified names the tokenizer's scanner is re-run from `start`.

### 3.3 Interning

`Symbol = enum(u32) { _ }`. Every identifier-like token (lower, upper, qualified, dot_lower,
dot_index's digits, keywords are not interned) is interned into the worker's `Local` pool while
scanning, hashing bytes as they are consumed (Wyhash or FxHash-style multiply-xor; measured, not
guessed). After the parallel phase, `Global.merge(local) -> []Symbol` returns a remap table and
the worker rewrites its files' `payload` columns and Bir symbol references. Pre-registered
well-known symbols (`main`, core module names, operator function names) have fixed indices in
`Global` so the checker never looks them up.

### 3.4 Arena

`Arena.zig`: chunked bump allocator over `std.heap.page_allocator`, owned by one thread, no
atomics. Implements the `std.mem.Allocator` vtable (alloc/resize/remap/free; free is a no-op,
resize grows in place when last). `reset(.retain_capacity)` keeps the largest chunk. Each worker
owns one; each per-file phase allocates from it; the driver resets it between files only when
the previous file's artifacts have been moved to session-owned storage.

### 3.5 AST

Zig's shape:

```zig
pub const Node = struct { tag: Tag, main_token: TokenIndex, data: Data };
pub const Data = struct { lhs: u32, rhs: u32 };  // meaning per tag; ranges live in extra
pub const Index = enum(u32) { root = 0, _ };
pub const OptionalIndex = enum(u32) { none = std.math.maxInt(u32), _ };
```

The AST is *lossless* together with the token and comment arrays and the line-start table:
every byte of the source is recoverable except that `\r\n` becomes `\n`. Doc comments are in
the comment array with `kind = .doc`; `Lower` and `Format` find the block preceding a
declaration's first token by `before_token`.

Error recovery emits `Tag.error_*` placeholder nodes; the tree is always structurally complete
(every list closed, every `case` has a branch list). `Ast.errors` holds the parse diagnostics in
source order.

Every node kind has a typed accessor (`ast.fullIf(index)`, `ast.fullCase(index)` …) mirroring
`std.zig.Ast.full*` so consumers never decode `Data` by hand.

### 3.6 BIR

Per file, arena-owned until merged. `Bir.zig` defines: a `MultiArrayList(Inst)` with
`Inst = { tag, data }` plus `extra`, declaration ranges, a `locals` table per declaration
(symbol, kind, defining inst), a `refs` list per declaration (top-level symbols referenced — the
DCE graph edges, a byproduct of resolution), the interface skeleton (`pub` values with
annotation presence, `pub` types with constructor lists or `opaque`), the import table (module
symbol, alias symbol, exposed list), and the diagnostics produced by lowering. Nothing in Bir
holds a slice into the source; strings and identifiers are `Symbol`s.

Lowering is one pass over the AST with an explicit scope stack (a flat array of `(symbol,
local_index)` pairs with per-scope marks; lookups scan backwards — scopes are small and this
beats a hash map on every measurement Zig and Roc made).

### 3.7 Formatting

`Format.zig` walks the AST once, printing to a `std.Io.Writer`. Layout decisions ("fits on one
line") use a width measure computed from the AST without printing twice: each node gets a
single-line width or "does not fit" in one bottom-up pass into a side array, and the printer
consults it. Comments and blank-line preservation come from the comment array and token line
numbers. The formatter never reads the source text except through token slices.

## 4. Session and parallelism

`Session` is the one object everything hangs off. In M1 it owns: `gpa`, `options`, the
`SourceStore`, the global `InternPool`, the `Profile`, and a `Workers` set — each with an
`Arena` and a `Local` interner. `session.run(.check | .fmt | .dump)`:

1. Enumerate and sort files; assign file indices. (Serial, deterministic.)
2. Per file, on a worker: read bytes, tokenize, parse, lower (or format). Worker assignment is a
   plain atomic counter; nothing observable depends on which worker took which file.
3. Sync point: merge interners in **worker index order**; remap.
4. Collect diagnostics, sort, render. Write outputs.

`--jobs=1` runs the same code on the calling thread with one worker. The determinism test
runs the corpus at `--jobs=1` and `--jobs=8`, twice each, and byte-compares every stream and
output file.

## 5. Bench harness

`zig build bench [-- --corpus=<dir>] [-- --generate=<lines>]` runs each phase over every file in
the corpus, `n` iterations after warm-up, and prints one JSON line per phase:

```
{"phase":"lex","files":312,"bytes":4194304,"tokens":911223,"ms":41.2,"mb_per_s":101.8,"loc_per_s":2431000}
```

plus a `total` line. `bench/gen.zig` writes a deterministic synthetic project of `n` lines whose
shape matches real code (module/import/type/function ratios taken from `references/elm`'s
own examples: mostly small functions, some large `case`, records, pipelines) so the §2 budget
numbers are stated against something honest. The generated tree is written under the build
cache, never checked in; `bench/corpus/` is the permanent, checked-in pathological set that
starts with a handful of real-shaped modules and every slow file ever found.

## 6. `--self-profile`

Chrome trace-event JSON (`{"traceEvents":[...]}`), viewable in Perfetto/speedscope:

- one `X` (complete) event per phase per file: `name` = `lex|parse|lower|format`, `cat` =
  `phase`, `tid` = worker index, `args.file`, `args.bytes`;
- `X` events for the serial steps: `enumerate`, `merge_interners`, `render`;
- `C` (counter) events at exit: `files`, `bytes`, `tokens`, `nodes`, `insts`, `diagnostics`.

Counters are what the incrementality tests will assert in M4 ("dependents were not
re-checked"), so they exist now. Recording is per-thread into a preallocated buffer; the
serial write happens once at exit. With the flag off, the recording call is a branch on a bool.

## 7. Test harness

`tests/blackbox/world.zig` follows lar's `session.zig` (spawn the real installed binary; a
replacement environment; capture stdout and stderr fully; bounded waits; kill-and-reap on every
exit path) minus sockets, plus a *project*: `World.init(gpa, io)` makes a temp directory;
`world.write("src/Main.beni", source)` creates files; `world.run(&.{"check", "src"})` spawns
`./zig-out/bin/beni` with cwd = the temp dir and returns `{exit_code, stdout, stderr,
diagnostics}` where `diagnostics` is the parsed JSON (the harness always passes
`--diagnostics=json` unless a scenario opts out to test the text renderer);
`world.read("out/x")`, `world.exists(path)`, `world.deinit()` removes the tree. Every scenario
asserts the whole diagnostic list with `expectEqualDeep` against literals.

`tests/blackbox/corpus_test.zig` walks `tests/corpus/` at test time and runs one case per file:
`parse/good` → `dump --stage=ast` equals the `.ast`; `parse/bad` → `check --diagnostics=json`
equals the `.diag` (a `.beni` without `.diag` fails); `fmt` → `fmt --stdout` equals `.expected`
and formatting `.expected` again is a fixed point and parses to the same `.ast`; `bir` → `dump
--stage=bir` equals `.bir`. A fixture under a `core/` subdirectory of its kind (`bir/core/Foreign.beni`) is run with
`--core` (language.md §5.4); the module name is still derived from the file's own directory.
`BENI_WRITE_EXPECTED=1` blesses; the failure message says so; the
value is fully materialised before any golden is written.

## 8. Milestones, acceptance

**M0 — skeleton.** `zig build`, `zig build test`, `zig build test-blackbox`, `zig build bench`,
`zig build fmt-check` all exist and pass. `beni version`, `beni help`, usage errors with exit 2.
`diagnostic` module and both renderers. `Arena`, `InternPool` (Local + Global + merge),
`Token`, `Profile`, `Session` with the worker loop (phases are stubs that read the file).
Harness `World` with a smoke scenario. Corpus walker with an empty corpus. Bench harness that
measures the read phase. Determinism scenario in place. Hermetic tests for Arena, InternPool,
Profile JSON.

**M1a — lexer.** `Tokenizer` per `language.md` §2; every lexical diagnostic; `dump
--stage=tokens`; fuzz test; hermetic tests for every token kind and every error; bench `lex`
line; `Profile` `lex` events. *Measure:* MB/s on the generated 100k-LOC corpus.

**M1b — parser.** `Ast`, `Parse` per `language.md` §3–§4 with layout, recovery, placeholder
nodes, Elm-style messages; `dump --stage=ast`; fuzz test; corpus `parse/good` and `parse/bad`;
bench `parse` line. *Measure:* cold parse of 100k LOC.

**M1c — formatter and BIR (parallel).** `Format` with idempotence and structure-preservation
tests over the whole corpus; `fmt --check`/`--stdout`/in-place. `Lower` per `language.md` §7–§8
with every scoping diagnostic; `dump --stage=bir`; corpus `bir`. *Measure:* formatter round-trips
the corpus unchanged; lower throughput.

**M1d — integration.** Parallel per-file driver measured at `--jobs=1` vs `n`; profile counters;
determinism test green; abuse scenarios (10 MB literal, one-line file, deep nesting, invalid
UTF-8, mixed line endings, unterminated everything at EOF) each producing a diagnostic and never
a panic; pathological files frozen into `bench/corpus/`.

Every milestone ends with: `zig build test`, `zig build test-blackbox`, `zig build fmt-check`
green; a bench run recorded in the commit message; a code review against the house rules.
