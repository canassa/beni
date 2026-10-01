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
beni build  [options] --platform=<name> <path>...      compile to JavaScript (backend.md §2)
beni check  [options] [--platform=<name>] <path>...    parse + lower every module; report diagnostics
beni fmt    [options] [--check] [--stdout] <path>...   format in place / verify / print
beni dump   [options] --stage=<tokens|ast|bir> <file>  print one file's IR as text
beni version
beni help
```

*Amended 2026-10-01:* three commands for the developer loop — `beni new <dir>`, `beni build
--watch` and `beni serve` — and a project file whose `"build"` key supplies `build`'s `--platform`,
paths and `--out` when the command line does not. They are §10's.

Later milestones add stages to `dump` without changing its shape: `interface`, `raw`, `types`,
`graph` and `dispatch` ([`checker.md`](checker.md) §2). They also add one common flag, `--explain`,
for informational `warning`-severity diagnostics that are otherwise suppressed. **It governs nothing
today**: the one diagnostic it gated, `ambiguous_method_receiver`, is emitted by default since
2026-09-18 ([`static-dispatch-spike.md`](static-dispatch-spike.md) §10 preamble, A.83). The flag is
still parsed and accepted, so nothing that passes it starts failing, and it is where the next
informational diagnostic goes. A warning cannot change an exit code (below) either way.

`build` arrived with the backend and its flags are `backend.md` §2's; the rest of this document is M0/M1's
and the common options below apply to it too. Its product on stdout is one summary line naming what
was written; everything else it has to say is a diagnostic.

**`--platform=<name>` is not `build`'s alone.** `check` takes it, and so does `dump` for the stages
that resolve imports (`interface`, `raw`, `types`, `graph`, `dispatch`), with exactly `build`'s
resolution — an embedded platform's name or a directory holding one ([`boundary.md`](boundary.md)
§5.3), the same `2` on an unknown one, the same privileges for the package's own modules. Without
it the platform package is not enumerated at all, so **every real program is unloadable by the one
command whose whole job is "just type-check it"**: `main : Program` names a platform module, and an
editor, a pre-commit hook, CI, M4's daemon and M5's LSP all run `check` rather than `build`. It is
**not required** the way `build` requires it — a library, a single module, or anything that imports
only core must stay checkable with no flag, and demanding one would make `check` unusable on the
inputs that need no platform — so the flag is optional everywhere but `build`, and the cost of
leaving it off is an honest `unknown_module`. `fmt` does not take it: formatting is per file and
resolves nothing — and it derives no module name either, so `beni fmt notes.beni` formats a file
whose path names no module, while `beni check` on that same file still says `invalid_module_path`.

*Added 2026-10-01:* `fmt` has one hidden flag, **`--migrate-cons`**, which writes every `::` chain of
a file in the list syntax (`language.md` §6.8) instead of formatting it — an edit that keeps the
file's own layout, applied to files whose only syntax errors are `cons_removed`, which it does not
report. It is `Format.migrateCons`, and it is how the repository moved off `::`.

*Added 2026-10-02:* a second hidden flag, **`--migrate-let-blanks`**, deletes the blank lines between
consecutive `let` bindings that are each one line — the old style's blank line between every
binding, which reads oddly once a short body sits on its `=` line (`language.md` §9). Like
`--migrate-cons` it is an edit, not a formatting: nothing else in the file moves. A binding is one
line when its source span holds no line break (a comment ending its last line does not count); a
gap that holds a comment line is kept whole, and a blank line next to a multi-line binding stays,
because it separates a block. Nested `let`s are reached, one run is the fixed point, and a file
with a syntax error is left alone. It is `Format.migrateLetBlanks`, a one-time cleanup: the
formatter's rule — at most one blank line between bindings, kept if present — is unchanged. The
two flags are mutually exclusive. *Retired 2026-10-02* with `let` itself (§11.2): a file that holds
a `let` has a syntax error now, so the flag had nothing left to read, and it is gone.

*Added 2026-10-02 (specified, not built):* four more hidden flags carry the syntax batch
(`language.md` §12) — **`--migrate-lambda`** and **`--migrate-names`**, edits like `--migrate-cons`,
and **`--migrate-let`** and **`--migrate-trailing-lambda`**, which reformat the whole file and so
run only on files the `beni fmt --check` gate holds canonical. §11.4–§11.5 are their contract; all
six flags are mutually exclusive. And `beni fmt --check` over the repository joins `zig build
gates` (§11.6).

*Added 2026-10-01 (specified, not built):* one more hidden flag, **`--migrate-unicode`**, an edit
that writes the Unicode notation (`language.md` §12.7–§12.8) — every ASCII arrow, comparison,
pipe and spread as its symbol, every parenthesised tuple type with `×`. §11.8 is its contract; it
is mutually exclusive with the others.

That `unknown_module` (and `unknown_module_alias`, for the qualified uses that follow it) gains a
closing paragraph naming the flag **when, and only when, the module it could not find is a module of
a platform that ships in the binary and no `--platform` was given**. The hint can be honest about
nothing else: a platform given as a directory is not known until it is named, so a missing `Html`
gets today's message and not a guess.

`check --platform=<name>` runs everything `build` runs before a byte is emitted — the check phases,
and then `boundary.md` §4's four sibling checks, which need no output directory and read the same
embedded assets the build reads. A `foreign_arity_mismatch` is exactly what a pre-commit check
exists to catch, and a `check` that passed where the `build` behind it fails is the asymmetry this
flag removes. What it does **not** run is the entry-point search: `missing_main`, `duplicate_main`
and `main_not_program` belong to `build`, because a build is a pair of ONE entry point and
ONE platform (`boundary.md` §5.3) while `check` is given whatever paths it is given — one module of
a project, or a repository holding a client and a server with a `main` each. `checker.md` §1 puts
`main`'s type outside the checker for the same reason.

Options common to all subcommands:

| Flag | Meaning | Default |
|---|---|---|
| `--diagnostics=text\|json` | diagnostics on stderr as Elm-style prose, or as one JSON array | `text` |
| `--self-profile=<path>` | write a Chrome trace-event JSON file at exit (§6) | off |
| `--jobs=<n>` | worker threads for per-file phases and checking; output is identical for every `n` | logical CPUs, as a ceiling: with no `--jobs` a run spawns a worker per 256 KiB of source and a checker per 16 Ki tokens, so a small project runs on one of each |
| `--root=<dir>` | the source root that module names are derived from | see below |
| `--core` | treat the files as the core package: `foreign` declarations are legal (language.md §5.4). Used only to build and test core; never by user projects | off |

Paths: a `<path>` is a `.beni` file or a directory. A directory is walked recursively; every
`.beni` file under it is a module; hidden entries (`.` prefix) are skipped. Files are processed
in **sorted path order** and numbered before any parallel work starts — that file index is the
stable id every later structure is keyed by. Module names come from the path relative to
`--root`; without `--root`, the root is the directory argument for directory paths and the file's
own directory for file paths (so `beni check Main.beni` names the module `Main`).

Every path — the arguments, `--root`, and everything the walk builds under them — is normalised
**lexically** before anything is sorted or numbered: empty and `.` segments are dropped and a
trailing slash is trimmed, so `.`, `./`, `.//` and `./.` are the same directory and `./Aa.beni`
under the root `.` is the module `Aa`. Nothing else moves: `..` is never resolved (`a/../b` is not
`b` when `a` is a symlink) and no path is ever made absolute, because a diagnostic must name the
file the way the user typed it. A `..` that survives into the part BELOW the source root is not a
module name and the file is `invalid_module_path`, like any other segment that is not an upper
identifier. Normalising before the sort is what makes `beni check .` and `beni check "$PWD"` the
same build: same modules, same order, byte-identical emitted output and `--iface-hash`.

Exit codes: `0` no errors, `1` at least one `error`-severity diagnostic, `2` usage or I/O
failure (bad flag, unreadable path). `fmt --check` exits `1` if any file would change. The rule is
the binary's and has no per-subcommand exception: **`dump` exits `1` when it printed an `error`**,
and still prints the dump it has — a tree with placeholders in it is what error recovery is for,
and that file is exactly the one someone runs `dump` on.

A `fmt` that rewrites a file in place keeps everything about it that is not its contents. The mode
is preserved. A symlink is **followed**: the link stays a link and the file it names is the one
rewritten, in that file's own directory. A file the process cannot write — a `0444` module, or one
in a directory it cannot write — is **refused**, with `beni: cannot write '<path>'` and exit `2`
(an I/O failure), and keeps every byte; the other files of the same run are still formatted. Two
things do not survive, both accepted: ownership, which no unprivileged rename carries, and a hard
link, whose other names keep the old contents — the write is a temporary file renamed into place,
which is what makes a crash mid-format leave either the old bytes or the new ones and never half
a module.

Streams: `stdout` carries the product (dump text, `fmt --stdout` output, nothing for `check`).
`stderr` carries diagnostics and nothing else. Diagnostics are sorted by file path, then start
position, then code — regardless of `--jobs`.

**The persistent cache** ([`fast-compiler.md`](fast-compiler.md) §8 has the key and the
layout). Two flags, on `check` and `build` only:

| Flag | Meaning | Default |
|---|---|---|
| `--cache-dir=<path>` | keep checked modules between runs in this directory | **`.beni-cache/` in the working directory, since the firewall cutoff** |
| `--no-cache` | read and write no cache at all | off |

They are `check`'s and `build`'s and not common options, because `fmt` resolves nothing and `dump`
prints a representation rather than a result — a flag that is accepted and does nothing is the
mistake `--source-maps` is refused to avoid ([`backend.md`](backend.md) §2), so `fmt --cache-dir=x`
and `dump --cache-dir=x` are the ordinary `unknown option` and exit `2`, and neither command creates
a cache directory either. `--no-cache` existed before there was a default so that a script written
then keeps working now.

*Corrected 2026-09-19 with the firewall cutoff: the cache is ON by default.* The condition
[`fast-compiler.md`](fast-compiler.md) §8 set was that a cache on by default must be right about
every input and that the harness is what establishes it, and that harness is
`tests/blackbox/cutoff_test.zig` plus `bench/cutoff.sh`. **Where:** `.beni-cache/` in the working
directory, created on demand. *Rejected: XDG* — a user-wide directory needs a garbage collector and
a size cap, and there is neither yet. *Rejected: beside `beni.json`* — `check` may run with no manifest,
so the rule would have two cases. The key holds no path, so one project checked from two working
directories gets two directories of identical entries: correct, duplicated, and the cheap failure.
**How a user clears it:** `rm -rf .beni-cache`, which is always safe because every entry is
content-addressed; there is no `beni clean` and no garbage collection (both the daemon's, with the size
cap). **`.gitignore` it** — a cache is machine-local by policy and is never committed.

**A cache never changes an answer and never fails a build.** A directory the user NAMED is created
if it is missing and a failure to create it is `2` with the path named, like `--out`'s: a person who
wrote the flag meant it, and a typo that silently produced slow builds would be worse than an error.
The DEFAULT directory degrades silently instead — a read-only checkout, a sandbox or a full disk
gives a run byte-identical to `--no-cache`, exit code included, with nothing on either stream,
because stderr is byte-compared across the whole corpus (§10) and even a one-line note would be a
diagnostic in every golden. After that, every per-entry read or write failure — a lost race, a
corrupt file — is silent either way. A stale or damaged entry is a miss, never a diagnostic:
`--self-profile`'s `cache_hits`, `cache_misses` and `modules_checked` counters are where a cache that
is doing nothing says so.

Three more flags are hidden, like `--roundtrip-interfaces` and `--iface-hash`, and for the same
reason — they are diagnostic surface, absent from `beni help` and from [`checker.md`](checker.md)
§2's table. `--cache-build-id=<s>` replaces the compiler build id in the key, so a test can prove
that a compiler change discards the cache. `--cache-keys` makes `check` print one
`<package>:<Module> <32 hex digits>` line per module on stdout, sorted by that key, exactly as
`--iface-hash` prints the record's — it is how an edit-scenario fixture asserts *which* modules a
change reached, with no cache directory involved. `--roundtrip-dispatch` is `--roundtrip-interfaces`'
twin for the dispatch sidecar: every module's table is written, read and re-resolved in place the
moment its check finishes, so every emitted file downstream is built from a table that has been
through the format. **`--roundtrip-frontend`** is the third of that family and the first that
is not the checker's: every file's `Bir`, token spans, line-start table and front-end diagnostics are
written to bytes and read back in place the moment its per-file phase ends and **before anything
downstream reads them**, so every dump, every diagnostic, every dispatch table and every emitted byte
is built from artifacts that have been through the format. It is on `Common` like its two siblings,
because `dump` has to be able to take it: `dump --stage=bir` is the lossless textual form of the
`Bir`, and a `check` diagnostic's position reads the token starts and the line-start table, so the
two are the identity oracle the round trip is asserted against (`frontend_test.zig`, on sources
chosen so that every section is non-empty). The round trip runs where lowering ends, so `dump
--stage=tokens|ast` and `fmt`, which stop before it, are unchanged by construction. **`--frontend-keys`**
is hidden too and is `--cache-keys`' twin: one `<path> <32 hex digits>` line per file on stdout,
sorted by path, so an edit-scenario fixture can assert that a leaf's body edit moved that leaf's file
key and no other — the claim the whole slice rests on — with no cache directory involved.

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
  The implementer designs it; it must show every desugaring in `language.md` §8 legibly. Static
  dispatch put two instruction tags into that dump, `method_call` and `type_dispatch`, and a
  `method_call` **prints the operator it was written as** — `%4 = method_call %2 .eq [%3] (==)` —
  so a golden distinguishes `a == b` from `a.eq b`, which are not the same constraint.
  → [`static-dispatch-spike.md`](static-dispatch-spike.md) §1.3, §1.4.
- *Markup (2026-09-29; the tokens are built, the rest not)* adds eight token tags to `tokens` — a
  `markup_text`'s bytes printed quoted and escaped, since a run may span lines — the markup and vocabulary
  node tags to `ast`, and the `markup` instruction with its tree and the vocabulary declarations to
  `bir` (§9.2, §9.4, §9.7).

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
*Amended 2026-10-01 (§11.8, specified, not built):* from the Unicode teach step it is one plus
the number of code points in `source[line_starts[l]..o]` — the bytes that are not UTF-8
continuation bytes (`10xxxxxx`) — so a symbol is one column; `line_starts` does not change.

`line_starts` is the only thing the lexer leaves in the store, and **it is a cached artifact**
(`fast-compiler.md` §8): four reporters turn an offset into a `diagnostic.Position` through it, so a
file whose lexer did not run still needs one. There is no size, mtime or inode column and the front-end cache does
not add one — a `stat` fast path is the daemon's, and §8 says why.

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

**Two of the four columns survive `lower`, and only those two are cached**
(`fast-compiler.md` §8). `line` is the parser's — layout is decided per token — and `payload` is the
parser's and lowering's; nothing reads either again. `tag` and `start` are read by four sites after
the front end, all of them turning an instruction's `main_token` back into bytes: `Session.tokenSpan`
and `moduleNameOfImport`, `Emit.tokenPosition`, and `js/Lower`'s `token_starts`. So the cached form
is 5 bytes a token in two columns rather than 13 in four, and — the part that matters more than the
size — **it holds no `Symbol`**, because `payload` is the only place a token ever did.

A cache hit keeps that form in memory too: the file's tokens are a `Token.SpanList` of `tag` and
`start`, each loaded with one copy, and the lexer's four-column list stays empty. Every reader after
the front end goes through `Artifacts.spans`, which answers from whichever list the file has; only
the parser, lowering, the formatter and the token and AST dumps read the full list, and none of them
runs on a hit. *Rejected: re-inflating the cached columns to four, with `line` and `payload` zeroed —
measured on the 100k corpus's warm `check`, it cost about 1 650 page faults and 7 MB of peak RSS for
two columns nothing read.*

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

**The `Ast` is not cached, and that is a decision and not an omission** (`fast-compiler.md`
§8). It is the easiest artifact in the compiler to cache — three flat arrays, no `Symbol`, no fixup
pass (`src/parse/Ast.zig:8-9`) — and **nothing on a `check` or a `build` path reads one after
`lower` returns**. Its three readers are the formatter, `dump --stage=ast`, and the parse phase that
made it, and neither `fmt` nor `dump` takes a cache flag (§1). Caching it would be bytes written on
every cold build and loaded by nothing. M5's LSP is the one consumer that will want a tree back, and
it wants it for the file being edited, which is a miss by construction. The same reasoning excludes
`comments`, whose only readers after lowering are the same two commands.

*Amended 2026-10-01* (`language.md` §6.8, *The list syntax*). Two node kinds: **`spread`**, an item
of a `list` (`main_token` the `...`, `lhs` the operand expression), and **`pat_spread`**, an item of
a `pat_list` (`main_token` the `...`, `lhs` a `pat_var` or `pat_wild`). `dump --stage=ast` prints
them as `(spread …)` and `(pat_spread …)`. The `cons` and `pat_cons` kinds stay, as what the parser
builds for a `::` it has reported as `cons_removed`, so that recovery keeps the tree whole.

*Amended 2026-10-02* (`language.md` §12): two node kinds, **`block`** and **`stmt`**, and the `let`
kind kept only for a `let_removed` form — §11.3.

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
*Amended 2026-09-27:* a `let` binds all its names before any body is
lowered, so a block of n bindings made every lookup and every shadowing check a scan of n, and
lowering it quadratic (0.45 s at 20 000 chained bindings, ReleaseFast; 1.9 s at 40 000). Past 64
entries the stack is indexed by name (`Lower.scope_index`, each entry chained to the one of its
name it shadows) until it shrinks back to 32; below that it is still scanned. §7's initialisation
check reads each binding's own edges and resets only what it set, and a `let_def`'s local is
recorded where phase 1 binds it. The Bir is byte-identical; a `perf_test.zig` scenario holds it
linear.

**The list syntax added one instruction tag and removed one** (2026-10-01, `language.md` §6.8, §8).
`pat_spread` — `lhs` the `pat_var` or `pat_wild` it binds — is an item of a `pat_list`, at most one
per list, and `dump --stage=bir` prints it as `pat_spread ...%n`, one of its list's items. `pat_cons` is gone: a `::`
pattern is refused by the parser and lowers to `error`, as does a `::` expression. A list
**expression** with a spread adds no tag; it lowers to the `List.cons`/`List.append` calls of
`language.md` §8, each stamped with its spread's `...` token. The frontend artifact's format version
moves to 11 for the new token use, node kinds, instruction tag and codes, and to 12 when
`pat_cons` left the tag set.

**Blocks add one instruction tag** (2026-10-02, `language.md` §12.2): `let_stmt`, a statement of a
block, in its `let`'s range in written order; a block is otherwise the `let` instruction. §11.3.

**Static dispatch added two instruction tags and one declaration field, and removed a `refs` edge.**
`method_call` and `type_dispatch` join the tag set; a declaration stores its `where` clause as a
range of `(variable, method, type)` triples beside its annotation. What it did **not** add is a
`refs` edge for a method call: `refs` is a pure function of the file and the reference a method call
becomes is not known until the checker runs, so the checker's dispatch table carries those edges and
two consumers — emission order and the future DCE — must read both.
→ [`static-dispatch-spike.md`](static-dispatch-spike.md) §1.4, §2.4.

**A declaration's `params` is its arity, and a `foreign` has no definition to count.** For a value
with a body, `params` is the length of the definition's parameter list. A `foreign` has an
annotation and no definition, so its `params` is the number of parameters the **annotation**
declares — *n* for `T1, …, Tn -> R`, and 0 for an annotation that is not a function type, which is
a `foreign` bound to a value rather than to a function. That is the same number
[`boundary.md`](boundary.md) §4's check 4 measures the sibling export against, and check 4 reads it
back off `params` rather than recomputing it, so the two cannot drift. Leaving it at 0 was a
miscompile and not a cosmetic gap: every reader of `params` then takes a `foreign` function for a
nullary value, and the backend eta-expanded a constrained `foreign` used in value position inside
its own module to `() => List$eq(m0)` — a nullary closure where a binary method was promised
([`static-dispatch-spike.md`](static-dispatch-spike.md) §8.2).

**The Bir has two states and only the first is cacheable** (`fast-compiler.md` §8;
`plans/m4-plan.md` §2.3). `Resolve` rewrites every `import_value`/`import_ctor`/`qualified`/
`qualified_ctor`/`type_import`/`type_qualified` instruction **in place** into `ext_value`/`ext_ctor`/
`ext_type`/`top`/`ctor`/`type_top`/`error`, so one array is a function of one file's text before it
runs and graph-relative after. **The PRE-resolve form is what goes to disk**, and `Resolve` runs over
a loaded Bir exactly as over a lowered one — 3.5 ms across 634 modules *(measured)*, the cheap half.
Writing the post-resolve form would put a `Graph.Index` in a cache, which is the one thing a cache
may not hold.

Two more things the on-disk form settles, both already true of the structure. **The `symbols` column
becomes offsets into a `strings` blob and is re-interned on load** — which is what the single-column
design exists for: `applyRemap` (`src/bir/Bir.zig:738-740`) is the loop that rewrites it and is
unchanged; only where the remap table comes from changes. And **`Lower.Options` is part of the file
key**: `{core, platform, module_name}` are inputs to lowering, so the key carries the two permission
bits and the dotted module name beside the source hash. Nothing else on the command line reaches
lowering — `--pattern-budget` and the informational switch do not — which is why the file key is
strictly narrower than the module key of `fast-compiler.md` §8.

### 3.7 Formatting

`Format.zig` walks the AST once, printing to a `std.Io.Writer`. Layout decisions ("fits on one
line") use a width measure computed from the AST without printing twice: each node gets a
single-line width or "does not fit" in one bottom-up pass into a side array, and the printer
consults it. Comments and blank-line preservation come from the comment array and token line
numbers. The formatter never reads the source text except through token slices.

A `where` clause (`language.md` §3) is the one construct whose layout does not follow the
never-join-lines rule: it is **always** on continuation lines, however short, because there is no
one-line form. `language.md` §9 states the shape and
[`static-dispatch-spike.md`](static-dispatch-spike.md) §2.5 the reasoning.

*Amended 2026-10-02* (`language.md` §9, the row "annotation, `=`"): a definition's body — top-level,
`let` definition or `let` pattern — goes on the `=` line when its recorded width fits there and no
comment comes between `=` and its first token; otherwise on the next line indented 4. No new
measure is needed: a body's width already covers only the body's own tokens, is "does not fit" for
`if`, `case`, `let`, a multiline string, a comment inside, and every break the author wrote between
the elements of a construct inside it — so the break directly after `=`, which lies outside the
body, is never one the width records, and never keeps the body below. The decision depends only on
the width and the column of `=`, both the same when the output is formatted again, which keeps the
formatter idempotent.

*Amended 2026-10-02* (`language.md` §12.5): a one-line `if`, hanging last arguments, trailing
lambdas, blocks, the blank line after a standalone comment and the aligned first parameter — what
each changes in the measure is §11.7.

Declaration record bodies and tagged schema variants use the layout sugar in
`language.md` §3–§4/§9 and `schema.md` §2/A.5: both input spellings must have
byte-identical AST/BIR dumps; formatting always selects layout where available.

## 4. Session and parallelism

`Session` is the one object everything hangs off. In M1 it owns: `gpa`, `options`, the
`SourceStore`, the global `InternPool`, the `Profile`, and a `Workers` set — each with an
`Arena` and a `Local` interner. `session.run(.check | .fmt | .dump)`:

1. Enumerate and sort files; assign file indices. (Serial, deterministic.)
2. Per file, on a worker: read bytes, tokenize, parse, lower (or format). Worker assignment is a
   plain atomic counter; nothing observable depends on which worker took which file.
3. Sync point: merge interners in **file order** — each file's tokens, then its Bir's symbols,
   interned into the global pool on first sight, and whatever no file references after them by
   text — then remap. A symbol's global id is therefore a function of the input alone (since
   2026-09-24; it was worker index order, which let the `next_file` race number symbols).
4. Collect diagnostics, sort, render. Write outputs.

`--jobs=1` runs the same code on the calling thread with one worker. The determinism test
runs the corpus at `--jobs=1` and `--jobs=8`, twice each, and byte-compares every stream and
output file.

**Step 2 gains a hit path with the front-end artifacts** (`fast-compiler.md` §8), and it is the whole of their
shape: the worker reads the file's bytes, hashes them into the file key, and — if the artifact is on
disk and validates — installs the loaded `Bir`, token spans, line-start table and rendered front-end
diagnostics instead of lexing, parsing and lowering; otherwise it does what it does today and
**writes the artifact from that same worker before moving on**. Reading and writing both stay on the
worker because the per-file phase already does file I/O and is already parallel; the one thing that
may NOT stay there is the string table's re-interning, because `InternPool.Global` is thread-confined
(`src/InternPool.zig:24-26`). So a hit interns into the **worker's own `Local` pool**, and step 3's
existing merge carries it to the global one — the load produces exactly the kind of local numbering
`Global.merge` was written to reconcile, so no rule changes and no new synchronisation appears.
*Rejected: a serial pre-pass that loads every artifact before the workers start, as the persistent cache's entry
reads do — that pass exists because the entry's re-intern must `getOrPut` into `Global`, and a
per-file artifact has a `Local` to hand where the entry does not.* Step 4 is unchanged: a replayed
diagnostic is appended to the worker's list in file order like any other, so the collect-and-sort is
blind to which run produced it.

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
starts with a handful of real-shaped modules and every slow file ever found. *(Amended 2026-09-29,
not built:* `--phases=<phase>[,<phase>…]` stops the harness after the phases named, so an input only
the lexer can read yet is measured without the later phases refusing it — markup's `bench/markup/`,
§9.3.)*

## 6. `--self-profile`

Chrome trace-event JSON (`{"traceEvents":[...]}`), viewable in Perfetto/speedscope:

- one `X` (complete) event per phase per file: `name` = `lex|parse|lower|format`, `cat` =
  `phase`, `tid` = worker index, `args.file`, `args.bytes`;
- `X` events for the serial steps: `enumerate`, `merge_interners`, `render`;
- `C` (counter) events at exit: `files`, `bytes`, `tokens`, `nodes`, `insts`, `diagnostics`.

Counters are what the incrementality tests will assert in M4 ("dependents were not
re-checked"), so they exist now. Recording is per-thread into a preallocated buffer; the
serial write happens once at exit. With the flag off, the recording call is a branch on a bool.

The front-end artifacts add two `X` rows and three counters, and the counters are the load-bearing half. The rows are
`frontend_load` and `frontend_store`, per file, on the worker, so a trace shows the hit path where
the `lex`/`parse`/`lower` rows used to be. The counters are **`files_lexed`, `files_parsed` and
`files_lowered`**, and the acceptance test of the whole slice is that a warm run reports **0** for
all three: a phase that did not run is otherwise indistinguishable from a phase that ran fast, and
`fast-compiler.md` §12's rule is that a cost which does not appear in the trace defeats the
instrument — its converse is that a saving which does not appear in a counter is a timing and not a
fact.

## 7. Test harness

`tests/blackbox/world.zig` follows lar's `session.zig` (spawn the real installed binary; a
replacement environment; capture stdout and stderr fully; bounded waits; kill-and-reap on every
exit path) minus sockets, plus a *project*: `World.init(gpa, io)` makes a temp directory;
`world.write("src/Main.beni", source)` creates files; `world.run(&.{"check", "src"})` spawns
the binary under test (`BENI_EXE`: the ReleaseSafe `zig-out/safe/bin/beni` for every suite but
the timing ones) with cwd = the temp dir and returns `{exit_code, stdout, stderr,
diagnostics}` where `diagnostics` is the parsed JSON (the harness always passes
`--diagnostics=json` unless a scenario opts out to test the text renderer);
`world.read("out/x")`, `world.exists(path)`, `world.deinit()` removes the tree. Every scenario
asserts the whole diagnostic list with `expectEqualDeep` against literals.

`tests/blackbox/corpus_test.zig` walks `tests/corpus/` at test time and runs one case per file:
`parse/good` → `dump --stage=ast` equals the `.ast`; `parse/bad` → `check --diagnostics=json`
equals the `.diag` (a `.beni` without `.diag` fails); `fmt` → `fmt --stdout` equals `.expected`
and formatting `.expected` again is a fixed point and parses to the same `.ast`; `bir` → `dump
--stage=bir` equals `.bir`; `check/good` → `check` is clean and `dump --stage=interface` equals
the `.iface`; `check/bad` and `check/args` → `check --diagnostics=json` equals the `.diag`
(checker.md §3; `check/args` is the arity suite of §8.3, kept apart so its size and
pass rate are visible on their own); `dispatch` → `dump --stage=dispatch` equals the `.dispatch`. A fixture under a `core/` subdirectory of its kind (`bir/core/Foreign.beni`) is run with
`--core` (language.md §5.4); the module name is still derived from the file's own directory.
`BENI_WRITE_EXPECTED=1` blesses; the failure message says so; the
value is fully materialised before any golden is written.

`tests/blackbox/docs_test.zig` is the doc-example gate for `core/`: it extracts every
`--|     <expr> == <value>` from `core/*.beni`, appends each one verbatim to a temp copy of its
own module, and builds and runs that core, so an example that stops compiling or stops being true
fails the suite. `checker.md` Appendix B is the contract — the recognised form, the in-module
scope, and the rule that a skip needs a reason and dies with the line it excused.

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

## 9. Markup in the front end

*Specified 2026-09-29. The lexer's part (§9.1–§9.3) is built; the parser, the formatter and
lowering are not, so until they are the parser reports each markup expression as one
`not_implemented` at its `<` and skips it (§9.3's as-built note).* [`language.md`](language.md) §11 is what markup means; this
section is what the lexer, the parser, the formatter and lowering do with it. It follows research
36 §6's mapping onto the pipeline. One recommendation of research 28 does not survive: with **bare
text** (W30) the lexer cannot stay mode-free (research 28 §3.1), so it gains a mode stack — the
generalisation of the `string`/`interp` modes it already has (`src/lex/Tokenizer.zig:57-80`), not a
second lexer.

*Revised 2026-09-29, after the specification review.* The lexer's rules for a `<` in text, a spread
after whitespace and a comment in a hole are stated (§9.1); its measurement is a lexer-only input
(§9.3); `pub markup` and `Show` join the parser (§9.4); lowering decodes character references and
owns the table (§9.7), records constants, list entries, rows of any shape and their inputs (§9.7);
and the vocabulary module's own markup gets no edge to itself (§9.8).

### 9.1 The lexer's mode stack

`Tokenizer.mode` becomes the top of a small **stack** of `{ mode, depth }` entries, bottom entry
`normal`. The three existing modes keep their meaning; four are added:

| Mode | Entered by | Lexes | Left by |
|---|---|---|---|
| `tag` | a markup `<` (§9.3) | the tag name, then attributes: `markup_attr`, `=`, a string (string mode pushed over it), `{` (pushes `hole`), `--` comments, whitespace and newlines | `>` (`markup_gt`: replaced by `children`) or `/>` (`markup_self_close`: popped) |
| `children` | an opening tag's `>`, or `<>` | text runs (`markup_text`), `{` (pushes `hole`), a markup `<` (pushes `tag`), `</` (`markup_close_open`: replaced by `close`) | through `close` |
| `close` | `</` | the closing name, if any, then `>` | `markup_gt`: `close` and the `children` below it are popped |
| `hole` | `{` in `tag` or `children` | exactly as `normal`, counting `{` and `}`; in a hole opened in `tag` mode, `...` as its first token (below) | the `}` that brings its depth to 0 (`r_brace`), popped |

**The stack is what a `normal` or `hole` context sees as "the lexer is in expression position"**, and
nothing else about ordinary code changes: outside markup the stack is one entry and every token is
lexed exactly as today. A `"` in `tag` mode or in a hole pushes `string` over whatever is on top, so
an attribute string or a string inside a hole is §2.6's string, interpolation included; §2.6's rule
that a `"` inside an interpolation is an error is untouched, and so markup inside `${…}` never
arises (`language.md` §11.2).

**A spread is `{`, then `...` as the hole's first token**, whatever whitespace, newlines or comments
come between them: `{...x}`, `{ ...x }` and a `{` whose `...` is on the next line all lex as `l_brace`,
`ellipsis`, the expression, `r_brace`. Only the first token of a hole opened in `tag` mode can be an
`ellipsis`; `...` anywhere else — later in the hole, in a `children` hole, in ordinary code — lexes exactly as
it does today, as an error. Whether a spread is allowed
where it stands is lowering's (`spread_on_element`, `spread_not_first`, §9.7), not the lexer's.

*Amended 2026-10-01* (`language.md` §2.2, §6.8): **`...` is `ellipsis` in every mode that lexes
code** — `normal`, `interp` and `hole` alike, at any depth — because a list spread (`[ ...xs ]`) is
ordinary code. The paragraph above still describes the one place a *markup* spread is recognised
(the parser's `'{' ellipsis Expr '}'` in an opening tag), but the lexer no longer decides it: a
`...` in a `children` hole or later in a tag's hole is the same token, and the parser reports it
where no list surrounds it.

**A comment in a hole runs to the end of the line**, as every comment does (`language.md` §2.3), `}`
included. So `{-- note}` leaves the hole open, and the lexer does nothing special about it: the
comment goes into the `comments` array like any other (`language.md` §2.3), and when the parser
reports the hole's `unclosed_delimiter` it finds there a comment beginning on the `{`'s line and says
so, showing the two-line spelling (§9.5).

**Any other byte in `tag` or `close` mode** — a `<`, a digit, a stray `)` — is one `markup_stray`
token with `unexpected_token`, and lexing continues in the same mode, so the parser's recovery for an
opening tag whose `>` never comes (§9.5) sees one bad token and not a cascade. The token never runs
past the tag's own syntax: it stops before the first `>`, `/`, `{`, `}`, `"`, `=` or whitespace after
its first byte, so `<a \> b</a>` and `<a it's>t</a>` each have one stray and a tag that ends at its `>`.
*Amended 2026-09-29, after the lexer's review: a stray was an `invalid` token as long as the `invalid`
its first byte starts, so a `\` took the `>` after it and a `'` the rest of the line. It is a kind of its
own, and not an `invalid`, because an `invalid` is re-derived from its first byte alone, which cannot
tell that it stood in a tag.*

**Column 1 ends every markup mode.** In `tag`, `children`, `close`, or a `hole` that has markup
below it, a newline followed by a non-space byte at column 1 pops the stack back to its bottom
`normal` entry, and that byte is lexed as the start of a declaration. It is `language.md` §4 rule 6
("brackets do not suspend layout") stated in the lexer, and it is what keeps an unclosed element from
swallowing the rest of the file as text: the parser then sees a declaration where a child was
expected and reports `unclosed_element` at the opener (§9.5). Nothing valid is lost, because a byte at
column 1 always begins a declaration — **except a `--` comment in `tag` or `hole` mode**, which does not
end markup: a comment is not a token, so layout does not see it, and there it is a comment. Between tags
`--` is text and in a closing tag two stray bytes, so in `children` and `close` mode a column-1 `--`
ends markup like any other byte. *Amended 2026-09-29, after the lexer's review: the sentence before the
exception was false for comments, and a column-1 comment inside a tag or a hole ended the markup and
lexed the rest of the tag as code.*

**The stack is bounded**: at 4 096 entries a further push is `nesting_too_deep`, reported by the
lexer at the offending byte, and the construct is lexed from there as if the push had happened
without growing the stack past the limit, so the token stream stays well-formed. The stack is
per-file scratch owned by the tokenizer, reset per file, allocated once per worker.
*Superseded 2026-09-29, after the parser's review: lexed "as if the push had happened" without the
entry it replaced, a closer popped an entry its opener never pushed, and markup nested past the
bound through holes — an element and a hole a level — lexed its closers in the wrong modes, a cascade
of `unclosed_element` and `expected_token` behind the one report. The stack now holds 4 096 entries
in the tokenizer's frame and spills past them to the heap, so every token is the one the source
spells, and the lexer reports nothing: the parser's depth guard, which counts every element and
hole (§9.4), is the one bound, and its `nesting_too_deep` at a `<` is worded for markup. Its recovery
skips the too-deep part to the `}` or the end of the block that closes it, so one mistake is one
message.*

**Text runs.** In `children`, a `markup_text` token is every byte from the current position up to
the next `<`, `{`, `>`, `}`, column-1 break or end of file, and it is emitted only when non-empty —
whitespace included, because whether whitespace is significant is decided by lowering (§9.7), not
here. Three bytes stop a run and are not a token of their own, each an `invalid` token with
`unexpected_token` whose message gives the hole that writes it, and the text resumes after them
(`language.md` §11.4): `>` (`{">"}`), `}` (`{"}"}`), and a `<` whose next byte is not an ASCII letter,
`/` or `>` (`{"<"}`) — `a < b` in text, or a `<` at the end of the file. A tab is `tab_in_source`,
another control character `invalid_character` and a non-UTF-8 byte `invalid_utf8`, as everywhere;
`--` is text; a character reference is text here and is decoded by lowering (§9.7).

### 9.2 Token kinds

Nine kinds are added to `Token.Tag` (eight when first specified; `markup_stray` joined them after
the lexer's review, 2026-09-29, §9.1). **Every one can be re-derived from its tag and start alone**,
because each has a scanner of its own that stops at a fixed set of bytes — which is what keeps
§3.2's two-column cached form (`tag`, `start`) sufficient with no mode column: `slice` picks the
scanner by the tag, as it does today.

| Tag | Spelling | Scanner stops at |
|---|---|---|
| `markup_open` | the `<` that opens a tag or fragment | one byte |
| `markup_close_open` | `</` | two bytes |
| `markup_gt` | the `>` that ends an opening or closing tag, or `<>`'s `>` | one byte |
| `markup_self_close` | `/>` | two bytes |
| `markup_name` | a tag name: `[a-z][A-Za-z0-9-]*`, or `Upper(.Upper)*(.lower)?` | the first byte outside the name |
| `markup_attr` | an attribute name: `[A-Za-z][A-Za-z0-9_-]*` with `:` allowed after the first byte | the first byte outside the name |
| `markup_text` | a text run | `<`, `{`, `>`, `}`, a newline followed by a non-space at column 1, end of file |
| `ellipsis` | `...` as the first token of a hole opened in `tag` mode (§9.1) | three bytes |
| `markup_stray` | a byte an opening or closing tag cannot hold (§9.1) | where the `invalid` its first byte starts would end, or before the first `>`, `/`, `{`, `}`, `"`, `=` or whitespace after it, whichever is first |

`markup_name` and `markup_attr` are interned while scanned, like identifiers (§3.3), so `payload`
holds their `Symbol`. **Keywords are not recognised inside a tag**: `type`, `as` and `for` are
`markup_attr`s there. `For` and `Show` are `markup_name`s like any capitalised tag; the parser, not
the lexer, knows them (§9.4).

A new tag set is a change to the front-end artifact's bytes, so the artifact's `format_version`
moves (4 → 5, then 5 → 6 for `markup_stray`, then 6 → 7 for §9.7's `Bir` and its `uses_markup`
bit, `src/frontend/artifact_bytes.zig`), and every older artifact is a miss; the compiler build
id already moves with the change.

### 9.3 When `<` opens markup

`language.md` §11.2's rule, as the lexer applies it. The tokenizer keeps the tag of the **previous
significant token** (comments are not tokens, so they are invisible to it). In `normal` or `hole`
mode, a `<` is a `markup_open` when **both** hold:

1. the byte after it is an ASCII letter or `>`; and
2. the previous token **cannot end an operand** — it is not one of: `lower_ident`, `upper_ident`,
   `qualified_lower`, `qualified_upper`, `dot_lower`, `dot_index`, `int`, `float`, `char`, `str_end`,
   `multiline_line`, `r_paren`, `r_bracket`, `r_brace`, `underscore`, `question`, `markup_self_close`,
   the `markup_gt` that ends a closing tag, or `invalid` (conservatively: an `invalid` token might
   have been an operand, and reading the `<` as markup would cascade).

Otherwise the ordinary longest-match rules apply unchanged (`<=`, `<-`, `<|`, `<`), so every program
that lexes today lexes to the same tokens. *Amended 2026-10-02* (`language.md` §12.2): condition 2
holds also when the `<` is the first significant token on its line, so a block's markup value opens
after a binding that ends in an operand (§11.1). In `children` mode a `<` followed by a letter or `>` is
always `markup_open`, `</` always `markup_close_open`, and any other `<` the error of §9.1. The first
rule costs ordinary code one test at each `<`, of a byte already in cache.

**The measurement this owes** (`fast-compiler.md` §2's budget) has two halves. `zig build bench` on
today's markup-free corpus must not regress. And the modes' own cost is measured on a **lexer-only
input**, `bench/markup/`, a checked-in directory of markup-heavy modules (a benchmark table's view,
a form, a page of mostly static markup, a deep tree), which `zig build bench -- --corpus=bench/markup
--phases=lex` runs through the lexer alone — `--phases` is the new option that stops the harness
after the phases named, because nothing past the lexer can read markup until the parser does, and
nothing past the checker until a lowering exists. The input moves up the pipeline with the slices
(`--phases=lex,parse` once the parser reads markup, every phase once markup builds under the `node`
platform), and joins `bench/corpus/` only then; until it does, `bench/corpus/` stays buildable end
to end, which it must, because `--library` builds of it are the size benchmark (`backend.md` §9).

*As built, 2026-09-29* (`src/lex/Tokenizer.zig`). Where §9.1–§9.2 left a choice, the lexer takes
the smallest reading, and these are they:

- **`</` replaces `children` with `close`, and the closing `>` pops that one entry.** §9.1's table
  says both "replaced by `close`" and "`close` and the `children` below it are popped"; the two
  cannot both hold, and the result — the entry under the element is on top again — is the same.
- **`close` mode** skips spaces and newlines, and reads any run of name bytes as a `markup_name`
  (the parser, not the lexer, judges a second name); a `--` there is two stray bytes, not a comment.
- **A stray byte in `tag` or `close` mode** is one token as long as the `invalid` that byte always
  starts (`invalidEnd`), capped as §9.1 says: `12` is one token, not two, and a `'` runs as a
  character literal would until the tag's own syntax stops it. Its code is `unexpected_token` for printable ASCII; a tab, a bare `\r`, a control
  byte and non-ASCII keep the codes they have everywhere (`tab_in_source`, `bare_carriage_return`,
  `invalid_character`, `invalid_utf8`). The message is chosen by where the byte stood, which the
  diagnostic carries: in text a `<`, `>` or `}` gives the hole that writes it (`{"}"}`); in an opening
  tag every stray, a `<` or a `}` included, names the tag's parts; in a closing tag it says a closing
  tag holds only a name. *Amended 2026-09-29, after the lexer's review: the message was chosen from the
  byte alone, so a `<` or a `}` inside a tag was told about the text between tags.*
- **A text run is raw, like a comment**: a tab, a control byte, a bare `\r` or malformed UTF-8
  inside it is reported and the run stays one token, so a `markup_text` is never split and its end
  is §9.2's stop set exactly. The **newline before a column-1 break is the run's last byte**, and a
  column-1 break is any byte but a space, a line terminator or the end of the file — so a blank line
  inside an element does not end it.
- **In `tag` mode `=` is always the one-byte `equal`**; `==` is two of them.
- **The start of the file** counts as a token that cannot end an operand, so a file may begin with
  markup (the parser then reports a declaration where one was expected).
- **The stack** is a fixed array in `tokenize`'s frame, so it is neither allocated nor reset: it is
  per-file by construction. A string and its `${…}` take no entry — strings never nest (§2.6), so
  the entry under one waits in a slot of its own — and the bound therefore counts markup entries
  and the bottom `normal` one. At the bound, `nesting_too_deep` is reported **once per
  file**, at the first push that does not fit, and the pushed mode replaces the top; a later pop
  below the bottom stays at the bottom `normal` entry. *Superseded 2026-09-29 (§9.1): past the
  frame's 4 096 entries the stack spills to a list the tokenizer allocates only then and frees at
  the end of the file, and the lexer reports no `nesting_too_deep`.*
- **Until §9.4 is built**, `markup_open` in `parseAtom` reports `not_implemented` at the `<` and
  skips to the end of the outermost element — counting `markup_open` against `/>` and a closing
  tag's `>` — or to a column-1 token, and returns an error placeholder; the lexer's own diagnostics
  inside the markup are reported as always. *Superseded 2026-09-29: §9.4 is built, and the parser
  reads markup; nothing skips it.*
- **`dump --stage=tokens`** prints a `markup_text`'s bytes in double quotes with `"`, `\`, `\n`,
  `\r`, `\t` and other control bytes escaped, since a run may span lines (§1.2).

### 9.4 Parser productions

```
parseAtom       markup_open                       → parseMarkup
parseMarkup     markup_open (markup_name | ε) …   → element, fragment, For or Show
parseOpening    { markup_attr ['=' AttrValue] | string '=' AttrValue | '{' ellipsis Expr '}' }
                (markup_gt Children | markup_self_close)
parseChildren   { markup_text | '{' [Expr] '}' | parseMarkup } markup_close_open [markup_name] markup_gt
AttrValue       string | '{' Expr '}'
```

- **`markup_open` joins `parseAtom`'s switch and not `canStartAtom`** (`src/parse/Parse.zig:1956`):
  the lexer never produces it after an operand (§9.3), so argument position cannot meet one, and
  admitting it there would be a rule with nothing to apply to. The negation arm does not admit it:
  `-<b />` is `unexpected_token`, because markup is not a number.
- **A closing tag's name is compared by symbol** with the opener's; a fragment's closer has none.
- **`For` and `Show`** are recognised by the tag's symbol and parsed as an element is; their node
  tags differ (below) so that lowering can hold them to their own attributes and children
  (`language.md` §11.9, §11.18). Nothing about their syntax is special.
- **Layout**: every markup token obeys `language.md` §4 rule 2 — its column is greater than the
  enclosing block's indent — exactly as a bracket's contents do (rule 6). A text token's column is
  that of its first byte, so a text run may continue onto lines at any column right of column 1.
- **Depth**: an element is one nesting level for `language.md` §10's 4 096-level limit; a view nested
  20 deep costs 20.
- **Vocabulary declarations**: after `pub`, the words `element`, `attribute` or `event` followed by a
  string, or `markup` followed by a `lower_ident` and `:`, begin a `VocabDecl` (`language.md`
  §11.14) — at most three tokens of lookahead past `pub`, where a `Definition` would have its name
  and then parameters or `:`. Facts are `lower_ident`s (with their string arguments, or `via`'s
  name) up to `:` or the end of the declaration; a word that is no fact of the form is
  `unexpected_token`, naming the ones that are.

**AST node tags** (§3.5): `markup_element`, `markup_fragment`, `markup_for`, `markup_show`,
`markup_attr`, `markup_attr_escape` (the quoted name), `markup_spread`, `markup_text`, `markup_hole`,
`markup_empty_hole`, and `vocab_element`, `vocab_attribute`, `vocab_event`, `vocab_markup` for the
declarations, each with a typed accessor (`ast.fullMarkupElement(index)`, …). `dump --stage=ast`
prints them as S-expressions like every node:
`(markup_element div (markup_attr class (str "a")) (markup_text "Hello ") (markup_hole (ident name)))`.
Text is printed as written, before §9.7's trimming and decoding, since the AST is lossless.

### 9.5 Recovery

`frontend.md` §3.5's rule holds: the tree is always structurally complete.

| Situation | Diagnostic | Recovery |
|---|---|---|
| an element with no closing tag before end of file, a column-1 break, or an outer element's closer | `unclosed_element`, at the opening `<`, naming the tag and the column the closer was needed at, as `unclosed_delimiter` does | the element is closed there |
| `<div>…</span>` | `mismatched_closing_tag`, naming both | **accepted as the closer**, so one mistake is one message |
| an opening tag whose `>` never comes | `expected_token` | the tag ends at the first token that cannot continue it |
| `>`, `}` or a `<` not starting a tag, in text | `unexpected_token` (from the lexer, §9.1), with the hole that writes it | skipped |
| a hole left open by a comment, `{-- note}` | `unclosed_delimiter` at the `{`, whose message says the comment ran to the end of the line and shows `{-- note` with `}` on the next line | the hole is closed where the enclosing element's recovery closes it |
| a hole whose expression stops before its `}`, `{λr, i -> …}` (*added 2026-09-29*) | the expression's own error, once | the rest of the hole is skipped to its `}`, which closes it; read as the markup around the hole, it ended every element open around it with an `unclosed_element` each |
| `f <div />` | `element_as_argument` — when a comparison's `<` abuts a following name and the parse of its right operand fails at `/>`, `>` or an `=` right after that name, the parser reports this instead of the generic error, saying to parenthesise | the comparison's placeholder, as today |
| `<-div>` | `unexpected_token` whose message says a tag name cannot begin with `-`, since `<-` lexes as one token (research 28 §3.5) | as today |
| an unknown fact in a vocabulary declaration | `unexpected_token` | the fact is skipped |

*As built, 2026-09-29* (`src/parse/Parse.zig`, `src/dump/ast.zig`). Where §9.4–§9.5 left a choice,
the parser takes the smallest reading, and these are they:

- **The AST dump** prints a braced attribute value with the marker `braced` after the name,
  `(markup_attr id braced (field_access …))`, and a quoted one as its `string` node, so `a="x"` and
  `a={"x"}` — which §11.5 treats differently — do not print alike. A self-closing tag and one closed
  at once are the same node. `markup_for` and `markup_show` print as `markup_element` does, under
  their own tag. A vocabulary declaration prints its name, its facts as words with their string
  arguments, and its annotation. The accessors are three, one per shape: `fullMarkup` for the four
  element-like tags, `fullMarkupAttr` for an attribute or an escape, and `fullVocab`.
- **A component's attribute must be a field name** — a lower-case letter, then letters, digits and
  `_` — or it is `unexpected_token` naming the component, since `language.md` §11.8 makes each one a
  field of the record it takes; a quoted name (`"aria-label"=…`) on a component is refused the same
  way. The parser can tell, because a component is an upper-case name.
- **A `{` in an opening tag without `...`** is `expected_token` asking for `...`, and the braces are
  read as a spread's; a `{...e}` on an element is parsed and left to lowering's `spread_on_element`.
- **`unclosed_element`** spans the `<` and the name. It has three wordings: at the end of the file;
  at a token on or left of the enclosing block's column, naming that column as
  `unclosed_delimiter` does; and at an outer element's closing tag, quoting it. In the last case the
  lexer, which does not match names, still counts the elements closed early as open, and reads what
  follows the outermost one as their children; the parser skips those tokens without a second
  diagnostic, so one mistake is one message.
- **`element_as_argument`** is decided by lookahead, not by a failed parse: after an operand, a `<`
  followed with no space by a name, then any attribute names, then `/>`, `>` or `=`. The comparison
  gets the error placeholder as its right operand, and the parser recovers as after any other
  expression error.
- **`nesting_too_deep`** the lexer already reported at a `<` is not reported again by the parser at
  the same `<`, and a `markup_stray` token is skipped like an `invalid` one, its diagnostic the
  lexer's. *Amended 2026-09-29 (§9.1): the lexer no longer reports nesting; the parser's
  `nesting_too_deep` at a `<` is worded for markup, counting its elements and holes.*
- **One mistake, one message, in its own words** (*added 2026-09-29, after the parser's review*).
  A `{` without `...` in an element's tag is only lowering's `spread_on_element`, the parser asking
  for `...` in a component's tag alone. A second element after `</p>` or `/>`, `<p>a</p><p>b</p>`, is
  `unexpected_token` saying siblings need a fragment, not `element_as_argument`. A `</` read as code —
  `<`, then an abutting `/` — is a closing tag: inside a hole it ends the hole's expression and is
  `unclosed_delimiter` at the `{`, quoting the tag, with recovery past the declaration; outside every
  hole it is `unexpected_token` over the whole tag, a closing tag with no element open, skipped.
- **An element's attributes and children are siblings** (`Parse.Siblings`), as a `let`'s bindings
  are: the field-access chains of its holes charge the declaration's depth as the deepest of them,
  not their sum, so a flat page of thousands of `{x.r}` holes is not "nested" past the bound.
- **`-<b />`** is `unexpected_token` with its own wording (negation takes a number), and **`<-div>`**
  is `unexpected_token` whose message says `<-` is the bind's arrow, when `<-` is followed by a name
  where an expression should start.
- **A hole's `}` inside a comment** (`{-- note}`) is `unclosed_delimiter` at the `{` with the
  wording of the table above, when the comment after the `{` holds a `}`.
- **Vocabulary facts** are kept in the AST as a token range and checked against their form's words
  there; an unknown word is `unexpected_token` naming the words there are, and is skipped with its
  arguments. A vocabulary declaration is only recognised after `pub`.

### 9.6 The formatter

`Format.zig` implements `language.md` §11.15 with the two mechanisms it already has: the width measure
of §3.7, one bottom-up pass into the side array, and token line numbers for the author's breaks.
What is new is one fact per gap between two children — **does the whitespace run there contain a
newline, and is it empty** — read from the `markup_text` token that holds it (or from the absence of
one), with *whitespace* meaning `language.md` §11.4's Unicode set, and never changed: the printer
emits a newline where the gap had one and a single space where it had whitespace and no newline.
Text continuation lines are re-indented and their trailing whitespace dropped; the bytes of a line are
printed as written, character references included. A hole holding only a comment is printed with its
`}` on the next line, so formatting cannot produce `{-- note}`.

**Two tests beyond idempotence and structure preservation**: `fmt/` goldens where text whitespace
must not move (children on one line past 100 columns; a space between two elements; a text line with
two spaces between words; a line whose only whitespace is a no-break space), and one `run/` fixture
that renders a view through the `ssr` lowering before and after `beni fmt` and compares the two
strings — the black-box form of "the formatter never changes what a page says".

*As built, 2026-09-29* (`src/fmt/Format.zig`). The `run/` fixture waits for the `ssr` lowering;
until then the `fmt/` harness checks the same promise one stage earlier: it compares the AST with
every text run cut out, and, for a file with markup, the `dump --stage=bir` page before and after
formatting, which holds each text run after §11.4's two steps. Where §9.6 and `language.md` §11.15
left a choice:

- **Only the gaps between two children are fixed.** The edges — between the opening tag and the
  first child, and between the last child and the closing tag — may gain a line break where they
  had none when the element is printed vertically, since the page shows neither; a space the page
  shows before the closing tag stays on the line.
- **An element written on one line stays on one line when it follows something on its line** — a
  sibling it may not be parted from, `λx ->`, an attribute's `=` — whatever its width, since
  breaking it there moves only its own edges. An element the author broke is printed vertically.
  *Amended 2026-09-29, after the formatter's review:* such an element is printed **whole** on the
  line, every hole, lambda and child in it included. A break inside it made it an element the
  author broke on the next run, so formatting was not a fixed point, and a row of them broke at a
  column that grew with each sibling, so the output grew as the square of the input. A broken
  element that follows a sibling on its line hangs its children and closing tag off the
  children's column, not its own, for the second reason.
- **No break that cannot shorten a line.** An opening tag with no attributes keeps its `>` on
  its line, and a hole or a braced attribute value holding only a literal, a name, an access
  chain on one, or markup written on one line keeps its `}` on its line, whatever the column.
- **A text run's trailing whitespace** is dropped at the end of a line when a later line of the same
  run shows text, and kept on the run's last line of text, where Solid's `trim_jsx_text` keeps it as
  a space. At most one blank line is kept inside a run and between children.
- **A hole that does not fit** continues its expression four columns right of the `{`, and its `}`
  closes on a line of its own under the `{`, as a hole holding only a comment always does
  (`{ -- note` then `}`).
- **A vocabulary declaration** prints on one line, its facts in source order.

### 9.7 BIR

**Markup lowers to a dedicated instruction, not to calls** (W32; research 36 §6 withdraws research
28's desugaring). A markup expression that is not the direct child of another element — the root of
a `view`, a branch's body, an attribute's or a hole's own markup, the body of a row or `Show`
lambda — is one `markup` instruction, and its instruction index is the **site** that identifies its
template everywhere downstream (`backend.md` §15.2). The instruction points at a tree in a per-file
side table:

| Node | Holds |
|---|---|
| `element` | the tag's markup name (a `Symbol`), its **items** — attributes, escapes and events in one list, in source order (`language.md` §11.5) — and its children |
| `fragment` | its children |
| `text` | the text **after `language.md` §11.4's two steps**, trimmed then decoded, interned; a run that trims to nothing is no node |
| `attr` | the name, and one of: a **constant** (below); the instruction computing the value; or **entries**, for a class or style list written in place |
| `attr_escape` | the quoted name and its value, as `attr` |
| `hole` | the instruction computing the value; an empty hole is no node |
| `component` | the callee (an ordinary reference instruction, resolved as a qualified name is by `language.md` §6.2 and §8 step 1: `qualified(TodoItem, view)` or `qualified(Card, header)`), the props as `(field symbol, value)` in source order, the spread's instruction if any, and the children in the form `language.md` §11.8 gives them |
| `for` | the `each`, `keyed` and `fallback` values, the keying mode lowering can see (`key` function, literal `True`, literal `False`, absent), and the **row** (below) |
| `show` | the `when`, `keyed` and `fallback` values, the keying mode (`key` function, literal `True`), and the **row** of its body |

**A constant** is `language.md` §11.5's: a quoted value without interpolation, stored as its text
after character references are decoded; a bare name, stored as `True`; or a hole holding only a
number literal (its spelling, with a leading `-` when negated), a string literal without
interpolation (its text, not decoded — a hole's string never is), or the prelude's `True` or `False`,
known as such because the name resolved to `import_ctor(Basics, …)`. A hole holding a constant still
lowers its instruction, which the checker types like any other; the node records that the value is
known, for a lowering to write into a template. **A quoted value with interpolation** is an
ordinary `interp` instruction whose literal chunks are decoded here, before they reach the
instruction, so a reference never spans an interpolation.

**Entries** are recorded when an attribute's value is a list literal of two-element tuple literals
whose first elements are string literals without interpolation: `class={[ ( "row", True ),
( "danger", sel ) ]}`. Each entry holds its name's text and its second element as a constant (`True`,
`False`, a string literal without interpolation) or the instruction computing it. The list still
lowers to its ordinary instructions, in source order, and the checker types the whole list as it
would anywhere; entries are what a lowering compiles away (`language.md` §11.19). The shape is read
without knowing the attribute: lowering cannot know which attributes take lists, and entries on an
attribute that takes none meet the checker's `type_mismatch` exactly as the list would.

**A row** is what `For` renders per item and `Show` renders for its value. It records the row
function's instruction and its **shape**:

| Shape | When | Also recorded |
|---|---|---|
| `markup` | the function is a lambda — written, or made by a placeholder or an accessor (`language.md` §8) — whose body, after peeling any `let … in`, is a markup expression | the peeled `let` bindings, lowered in order before the markup's values; the lambda's parameters; its **captures** and **inputs** |
| `lambda` | any other lambda | its parameters, captures and inputs; its body is one value |
| `function` | anything else | nothing: the value is called per item, and is its own input |

The **captures** of a lambda are the locals of the enclosing declaration its body uses, in first-use
order: what a compiled row must be handed to run. Its **inputs** are `language.md` §11.9's: per
captured local, the field paths through which the body reads it — a maximal chain of field accesses
and tuple indices, `model.selected` or `model.theme.dark`, at most four links long, a longer chain
cut to its first four — or the local itself when some use is anything else. A use as argument *i* of
a call whose callee is a top-level function of this file contributes that function's **summary** for
parameter *i*, prefixed by the argument's own path: the set of paths through which that function's
body reads the parameter, computed by the same rule over its body — a record pattern
`{ selected }` in the parameter is the path `selected`, any other pattern is a whole use — with
calls between the file's functions iterated to a fixpoint from the empty set, which terminates
because the path sets are finite and only grow. A path that has a prefix among the inputs is
dropped, and the inputs are kept in first-use order. Summaries are computed on demand, only for
functions a row's capture reaches, and memoised per file, so a file without markup pays nothing.
Every part of this is a function of the file's bytes, which is why lowering, and not the checker or
the backend, owns it.

**The value instructions of a tree lie inside its declaration's instruction range in source order**
— items, then children, element by element, depth first — which is `language.md` §11.11's
evaluation order, so every existing pass that walks a declaration's instructions (resolution, `refs`,
`Dispatch.sitesIn`) sees them exactly as it sees any other expression, and nothing about the checker's
or the backend's walks has to learn a second order. A nested child element contributes no instruction
of its own; markup inside a hole or an attribute value, or as a row's body, is its own `markup`
instruction, nested where the value is.

**What lowering resolves and what it cannot.** A component's callee is an ordinary name and resolves
as one — it is an edge in `refs`. An element's or attribute's name cannot be resolved per file: it
lives in the platform's vocabulary module, which is another module and not even named by the file.
So names stay symbols, and a file that contains markup records **`uses_markup`**, one bit on the
file's `Bir`; the module graph turns that bit into an edge (§9.8), and the checker resolves the names
against the vocabulary's interface (`checker-v2.md` §25.2). Everything else about the tree is a
function of the file's bytes, so the `Bir` stays one (§3.6) and remains cacheable in its pre-resolve
form.

**Character references are decoded here**, and the table is the compiler's: `src/markup/entities.zig`,
generated at build time from a pinned copy of WHATWG's `entities.json` (`src/markup/entities.json`,
the file `htmlize` 1.1.0 embeds for Solid's compiler) into a sorted name table searched for the
longest match, beside the numeric rules of `language.md` §11.4. It is here and not in a platform
because it is the language's text syntax (`language.md` §11.1): putting it in a lowering would make
what a view says depend on which lowering compiles it, and every lowering — `dom`, `ssr`, a third
party's — would have to carry the same 2 231 names and agree on them. Decoded in lowering, the text
a lowering receives is already the text the page shows, so the `dom` and `ssr` results are the same
characters by construction, and a lowering has nothing to decode. The table is part of `src/`, so the
compiler build id covers it (`fast-compiler.md` §8). **Its test is htmlize's own**: the named, bare,
longest-match, numeric and windows-1252 vectors of `htmlize` 1.1.0's `src/unescape/internal.rs`
tests, ported as hermetic tests of the decoder, plus `run/` fixtures through `ssr` for text and for an
attribute.

**Lowering's diagnostics**: `duplicate_attribute`; `invalid_attribute_name` (*added 2026-09-29*); `spread_on_element`, `spread_not_first`;
`invalid_form_children` (a `For` or `Show` whose children are not one hole); `unknown_form_attribute`
(an attribute `For` or `Show` does not take, with "did you mean" over the ones it does) and
`missing_form_attribute` (`each` for `For`, `when` and `keyed` for `Show`); `invalid_keyed`, read
from the value's shape: a quoted value, a constant other than `True` and `False`, or `False` on
`Show` — any other expression is taken as a key function and typed as one, so a value that is not a
function is the checker's `type_mismatch` at `keyed` (`checker-v2.md` §25.4); and `vocabulary_outside_platform` for a vocabulary declaration outside a platform package,
beside `foreign_outside_platform` and on the same permission bit (§3.6's `Lower.Options`).

**Vocabulary declarations** are four new declaration kinds, each with its name (an interned string,
or for `markup` a symbol), its facts and, for attributes, events and primitives, its annotation; the
interface skeleton lists them beside the module's other `pub` names, and `dump --stage=bir` prints
them and every markup tree, rows' shapes, captures and inputs included. The `Bir`'s format moves with
the artifact's (§9.2).

*As built, 2026-09-29* (`src/bir/Lower.zig`, `src/bir/Bir.zig`, `src/markup/`). Where §9.7 left a
choice, lowering takes the smallest reading, and these are they:

- **Storage.** A text node's decoded text is interned, as a `Symbol`; a constant's text and an
  entry's name live in the `Bir`'s string bytes. The tree's records sit in `extra` and are read
  positionally, like every other record there. `uses_markup` travels in the artifact as a section of
  its own, `bir_flags` (bit 0; any other bit set is a malformed artifact), which is the 6 → 7 move of
  §9.2.
- **A `\r`** is removed from a text run before §11.4's first step. The lexer admits one only before a
  `\n` (a bare one is `bare_carriage_return`), so this is the CRLF file reading as its LF twin, which
  is what Solid's reader does.
- **A quoted value without interpolation lowers to no instruction**: it is a constant and nothing
  else; the checker will type it as the string it is.
- **A `For` or `Show`'s children are one hole, whitespace aside**: text that trims to nothing
  between them is not a child, so the hole may sit on a line of its own.
- **A form's `each`, `when` and `fallback`** are ordinary values whatever their spelling: a bare
  name is the prelude's `True`, a quoted value its decoded string. `keyed` is read by shape as the
  paragraph above says; bare `keyed` is `True`.
- **A component's callee**: `<Card>` and `<Ui.Card>` resolve to that module's `view`, `<Card.header>`
  to the member; a module name that is no import is `unknown_module_alias`, worded for a component.
- **`dump --stage=bir`** prints text and constants in double quotes with `"`, `\`, `\n`, `\r`, `\t`,
  other control bytes and `language.md` §11.4's non-ASCII whitespace escaped (`\u{a0}`), so a decoded
  `&nbsp;` is visible.
- **Vocabulary declarations** keep their facts as records in the declaration's parameter range. They
  are **not yet in the interface skeleton**: nothing can read them until the checker resolves
  markup against a vocabulary (`checker-v2.md` §25.2), and listing names nothing can type would be
  an interface change with no reader.
- **The stop before checking.** Until the checker reads markup, a module whose `Bir` says
  `uses_markup` is reported once, `no_markup_vocabulary` at its first markup instruction in source
  order, and every `markup` instruction types as the error type, so nothing cascades from it; a
  vocabulary declaration is `not_implemented` at its name. Both are errors, so no build of either
  reaches the emitter. `no_markup_vocabulary` is §9.8's diagnostic for a build without a
  vocabulary, which is every build today: no platform declares one yet.

### 9.8 The vocabulary edge

A module whose `Bir` says `uses_markup` depends on the vocabulary module its platform's manifest
names (`boundary.md` §9.2) as surely as on anything it imports, so **the graph adds that module as a
direct import** of every such module, before `graph.order` is computed and for every purpose an
import serves: ordering, the cache key's import terms (`fast-compiler.md` §8), the dependency digest
and the firewall cutoff. It is added by the graph phase and never written into the `Bir`, which does
not know the platform. With no platform, or a platform that declares no vocabulary, there is no edge
and the checker reports `no_markup_vocabulary` at the module's first markup instruction.

**The vocabulary module itself gets no edge**: its markup resolves against its own declarations,
which the checker reads before any of the module's values (`checker-v2.md` §25.2). A module the
vocabulary module imports, directly or not, that writes markup closes a cycle through the edge; that
is `import_cycle`, reported as the graph reports every cycle, and its message names the edge as "uses
markup, so depends on the vocabulary module" so the cycle is legible.

*As built, 2026-09-29* (`src/resolve/Graph.zig`, `src/resolve/Interface.zig`). Two bullets of
§9.7's *As built* are superseded: **vocabulary declarations are in the interface skeleton** — a
markup primitive as a value flagged `markup`, the other three as rows of their own tables, which the
checker completes or drops (`checker-v2.md` §25.8) — and **the stop before checking** now says
`not_implemented` at the first markup root when the build has a vocabulary and `no_markup_vocabulary`
only when it has none; a vocabulary declaration is checked rather than `not_implemented`. The edge
itself, where this section left a choice:

- It is added only when the chain's `"vocabulary"` and `"type"` both resolve (`boundary.md` §9.2);
  otherwise there is no edge and the module's markup is `no_markup_vocabulary`.
- A module that imports the vocabulary module AND writes markup has one edge, the import; only an
  edge that exists because of markup is named in a cycle's message.
- A cycle through the edge is reported, like every cycle, on its lexically first module, at the
  import of the next module or, when that step is the markup edge, at the module's first markup root.

## 10. The developer loop: `new`, `build --watch`, `serve`

*Added 2026-10-01* — Milestone 1's *developer loop v0* (`plans/status-2026-10.md` §6). Four pieces,
each small, and none of them the daemon: `fast-compiler.md` §4's resident process, its socket, its
`inotify`/`FSEvents` watching and its cancellation are still M4's, and the daemon's open decisions
(`plans/queue.md`, the M4 rows) are untouched by this section. What is here is the loop a person
needs on the first day — make a project, build it on every save, open it in a browser — built from
pieces that already exist: the one-shot build, the on-disk cache that makes a rebuild warm
(`fast-compiler.md` §8), and the page shell the platform declares (`backend.md` §2, *The page
shell*).

```
beni new    [--platform=browser-tea|node] <dir>
beni build  [options] [--watch [--poll-interval=<ms>]] [--platform=<name>] [<path>...]
beni serve  [build options] [--port=<n>] [--host=<address>] [--no-reload] [--poll-interval=<ms>] [<path>...]
```

### 10.1 The project file

A project's `beni.json` — the app package's manifest, read from `--root` or the working directory,
the one `Session` already reads for `"platform": true` (`boundary.md` §2) — may carry the build's
defaults, so that inside a project `beni build` and `beni serve` need no arguments at all:

```json
{
  "name": "counter",
  "build": { "platform": "browser-tea", "paths": ["src"], "out": "out" }
}
```

| Key | Is | Default when absent |
|---|---|---|
| `"build"."platform"` | what `--platform` would say | none: `build needs --platform=<name>`, exit 2, as before |
| `"build"."paths"` | the `<path>...` arguments, as written | none: `build needs at least one path`, exit 2, as before |
| `"build"."out"` | what `--out` would say | `out` |
| `"build"."base"` | the URL path `--out` is served under: what the page shell writes before the entry file (`{{entry}}`) and for `{{base}}`, and what `serve` takes off a request's path (*amended 2026-10-01*). It ends in `/` and holds no quote, `<`, `>` or whitespace, or it is `beni: beni.json's "build" "base" must be a URL path ending in '/', not '<value>'`, exit 2. It has no flag | `/` |
| `"html"` | the page shell, a file relative to the manifest's directory, in the platform's place (`backend.md` §2, *The page shell*) | the platform chain's |

**The command line wins, field by field**: a `--platform`, a positional path or an `--out` replaces
the manifest's value and nothing else. A manifest with no `"build"` — every manifest before this
section — changes nothing, and with no manifest at all every message and exit code is what it was.
The defaults are `build`'s and `serve`'s; `check` keeps requiring its paths, because what `check` is
handed is not always one program (§1). For `build` and `serve`, a `beni.json` that is not JSON, or
whose known keys have the wrong JSON type — a `"build"` that is not an object, a `"paths"` that is
not a list of strings — is the platform manifest's failure, `beni: cannot read '<root>/beni.json':
it is not a JSON object`, exit 2, before any source is read (a key `"build"` does not know is
ignored, as every manifest ignores one). Until now `build` silently ignored a malformed app manifest,
which would now mean silently ignoring the platform the project names. *Why a key and not a convention*: a
build is a pair of entry point and platform (`boundary.md` §5.3), so the platform is information the
compiler cannot guess, and `"build"` is the one place a project states it once.

### 10.2 `beni new <dir>`

Writes a project that builds and runs, and nothing else: `<dir>/beni.json` (§10.1, `"build"` filled
in), `<dir>/src/Main.beni` and `<dir>/.gitignore` (`out/` and `.beni-cache/`, the two directories a
build makes). `--platform=browser-tea`, the default, writes a `Tea.sandbox` counter; `--platform=node`
writes a program that prints a line. Any other value is `beni: new has templates for browser-tea and
node, not '<name>'`, exit 2 — the template list is the compiler's, and a platform package does not
contribute one yet. The project's name in `beni.json` is the last segment of `<dir>`.

It **refuses a directory that exists and is not empty** (`beni: '<dir>' is not empty; beni new
writes only into a new or empty directory`, exit 2, nothing written), creates missing parents, and
on success prints the next two commands on stdout. The templates are formatted (`beni fmt --check`
passes on them) and check clean; a black-box test builds both, runs the node one, and asserts it.

### 10.3 `beni build --watch`

Build, then keep building: after the first build, the inputs are polled every `--poll-interval`
milliseconds (default 200, at least 1), and a change is followed by one more poll that must see the
same state — the debounce, so an editor's save-then-touch or a `git checkout` of many files is one
rebuild and not several — and then a rebuild. Polling and not `inotify`, on purpose: it is portable,
needs no dependency, costs a `stat` per input file per interval, and is the daemon's to replace.

**What is watched**: every file ending in `.beni`, `.js`, `.json`, `.html` or `.css` under the
build's `<path>`s and, for a platform read from a directory, under every package of its chain; and
the files with those endings directly in the project root (`--root`, else the working directory),
which is where `beni.json` and an app's page shell usually sit. A hidden entry (a `.` prefix) is skipped as enumeration skips it,
and **the `--out` directory is never watched**, or a build's own output would trigger the next build.
The state is each file's path, size and modification time; a file added or
removed is a change. (*As built*: one 64-bit digest, the wrapping sum of a hash per file plus the
count, so the walk's order does not matter and nothing is kept between polls.) `beni.json`'s
`"build"` is read once, when the command starts — it decides what is watched — while its `"html"` is
read by every build, so an edit to the page shell is picked up and an edit to the defaults needs a
restart.

**What it prints.** Every build prints exactly what a one-shot build prints — diagnostics on stderr
in the chosen `--diagnostics` form, one render per build — followed by **one status line on stdout**:
`beni: built in <n> ms` or `beni: build failed; waiting for changes`. The one-shot build's "a
successful build prints nothing" (`backend.md` §2) is about a command whose exit code is its answer;
a watch never exits on its own, so the line is the answer, and it goes to stdout because stdout is
the product's stream and stderr stays diagnostics only. A failed build writes nothing, as always, so
the output directory keeps the last good build — which is what a browser pointed at it should see.

**How it ends.** On SIGINT (Ctrl-C) or SIGTERM: a build in progress finishes, nothing new starts, and
the process exits `0` — the user asked it to stop, and nothing failed. A second signal is not caught,
so a hung build can still be killed. A usage error (exit 2) is refused before the first build, and
an exit-2 failure **of the first build** — an unknown platform, an unwritable `--out` — ends the watch
with that exit code, because a loop that can only ever print the same failure is not watching
anything. After a first build that got as far as diagnostics, every failure is a status line and the
watch goes on.

`--poll-interval` is accepted only with `--watch` (and by `serve`), for the `--source-maps` rule: a
flag that does nothing is refused, `beni: --poll-interval needs --watch`.

### 10.4 `beni serve`

`build --watch` and a static HTTP server for the output directory in one process: the server answers
from `--out` while the watch rebuilds it. *Amended 2026-10-01:* a development build writes a
`.mjs.map` beside every module (`backend.md` §11.1) with the `.beni` text inside it, so serving
`--out` is all a browser's debugger needs; `--no-source-maps` is one of the `build` flags `serve`
takes. It takes every `build` flag, `--watch` implied, and:

| Flag | Meaning | Default |
|---|---|---|
| `--port=<n>` | TCP port; `0` asks the system for a free one | `8000` |
| `--host=<address>` | the IPv4 or IPv6 address to listen on | `127.0.0.1` — a development server is not exposed to the network unless asked |
| `--no-reload` | do not inject the live-reload script | reload on |
| `--poll-interval=<ms>` | as `build --watch`'s | `200` |

Once listening it prints `beni: serving <out>/ at http://<host>:<port>/` on stdout, the actual port
when `0` was asked for, before the first build's status line. A port it cannot take is
`beni: cannot listen on <host>:<port>: <error>`, exit 2, before anything is built.

**What it serves.** `GET` and `HEAD`; any other method is `405`. The request target's query string is
dropped and `%XX` escapes decoded; a target that is not absolute, or that holds a `..`, `.` or empty
segment after decoding, a NUL or a backslash, is `400` — the server never answers from outside
`--out`. `/` and a directory are their `index.html`. A file that exists is served with its MIME type
and `cache-control: no-store`: `.html` `text/html`, `.mjs` and `.js` `text/javascript`, `.css`
`text/css`, `.json` and `.map` `application/json`, `.txt` `text/plain` (those five with `charset=utf-8`),
`.svg` `image/svg+xml`, `.png`, `.jpg`/`.jpeg`, `.gif`, `.webp`, `.ico`, `.wasm`, `.woff2`, and
`application/octet-stream` otherwise. **A path that names no file and whose last segment has no `.`
is answered with `index.html`, status 200** — the single-page-application fallback, so a client-side
route survives a reload — a nested one too, since the page names its entry by an absolute path
(`backend.md` §2's *The page shell*); a missing path with an extension is `404`, because a missing
`.mjs` answered with HTML is a confusing failure in the browser's console instead of a plain one.
When the project's `"base"` is an absolute path other than `/`, a request path under it has it
taken off first, so `/app/_main.mjs` is `<out>/_main.mjs` and the page behaves as it will when
deployed under `/app/`; a path outside it is served as it is.

**Live reload is the server's, never the build's.** Every `text/html` response gets one inline
`<script type="module">` inserted before its last `</body>` (appended when there is none) that polls
`/_beni/build` and reloads the page when the number there changes; `/_beni/build` answers the count
of successful builds since the server started. The script exists only in the HTTP response: **no
file `beni build` or `beni serve` writes carries it**, development or `--release`, which is what
keeps the release output and every `emit/` golden free of it by construction. `/_beni/` is the
server's own namespace, and no file the build writes can be there — no emitted path begins with
`_beni` (`backend.md` §2, rule 1's reserved names are `_main.mjs`, `_core/`, `_platform/`,
`_manifest.txt` and the platform's entry). A failed build does not move the count, so a page keeps
showing the last good build while the errors are on the terminal.

It ends as `--watch` does; open connections are dropped. It is a development server: one thread per
connection, no TLS, no compression, no range requests, and it is not meant to face a network.

## 11. Blocks, `λ` and trailing lambdas in the front end

*Added 2026-10-02; specified, not built.* How the lexer, parser, AST, BIR, formatter and the
migrations build [`language.md`](language.md) §12. The language section is the contract for what a
program means; this one is the contract for the pieces, and for the order the repository moves in
([`plans/syntax-batch.md`](../../plans/syntax-batch.md) sizes the slices).

### 11.1 The lexer

- **`λ`** is the tag `lambda`, one token of two bytes, recognised where the ASCII-only check would
  otherwise report `invalid_character` (`language.md` §2.4, §12.1). `dump --stage=tokens` prints it
  as `lambda`. Nothing else in the token SoA changes (§3.2).
- **`\`** keeps the tag `backslash`, which is now lexed only to be refused; the multiline-string
  lookahead is unchanged (`language.md` §2.7).
- **Markup at the start of a line** is §9.3's third condition: a `<` is `markup_open` when the byte
  after it is an ASCII letter or `>` and **either** the previous significant token cannot end an
  operand **or** the `<` is the first significant token on its line (its line differs from the
  previous token's). The tokenizer already holds the previous token's line, so the test costs a
  comparison. `language.md` §12.2 says why it cannot change the meaning of canonical code.

### 11.2 The parser

**A body.** Every position `language.md` §12.2's openers table names is parsed by one function,
`parseBody`: when the next token's line is greater than the opener's and it is the first token of
its line, it parses a block, and otherwise an expression exactly as `parseExpr` does today. A block
is a node of its own only when it has more than one item; a one-item block whose item is an
expression is that expression's node, so every program without `let` parses to the AST it parses to
now.

**A block** sets its column *C* from its first token and parses items while the next token is at
column *C* and can start an expression (`language.md` §12.2, B2). The parser's `indent` (a token
belongs when its column is greater, `language.md` §4) is *C* inside an item, with one addition
carried in a second field, `block_col`: a token at exactly `block_col` also belongs when it cannot
start an expression (B3), and a `multiline_line` belongs when the previous token is a
`multiline_line` on the line above. `block_col` is saved and restored with `indent` by
`startBlock`/`endBlock`, so a construct nested inside an item — a `case`'s branches, a binding's
body — sees only its own. A token at a column below *C* ends the block (B4).

**An item's kind** is read from its first line before it is parsed (`language.md` §12.2): scan the
tokens on the item's first line, tracking depth over `( [ {`, interpolation and markup tags, for a
depth-0 `equal` or `arrow_left`, or a leading `lower_ident colon`. The scan is bounded by the line,
so a block costs one extra pass over its head lines. A binding is parsed by today's
`parseLetBinding` with its body through `parseBody`; an expression by `parseExpr`, and becomes a
`stmt` node unless it is the last item. A last item that is not an expression is
`block_ends_in_binding`, reported at it, and the block's value becomes an error node so the tree
stays whole.

**A parenthesised block** is a `(` whose next token begins a later line: the items are a block,
then `expectToken(.r_paren)`; a `,` there is `unexpected_token` (B6).

**A trailing lambda.** `parseApp` stops at a `lambda` token today (a block form is not an
argument); it now parses one as the last argument and stops. The lambda's body is `parseBody`: a
block when it begins a later line, and otherwise an expression parsed with `indent` set to *L*, the
column of the first token of the `λ`'s line (`language.md` §12.3), so a continuation line at a
column not greater than *L* ends it.

**The removed forms.** A `backslash` where an expression starts is reported as
`backslash_lambda_removed` and parsed as a lambda; a `keyword_let` as `let_removed`, then parsed by
today's `parseLet`, whose node stays in the AST for exactly this. Neither recovery skips a token, so
the rest of the file parses and lowers as it did. Under the migration flags (§11.4, §11.5) the
parser takes an option that accepts each form silently instead; nothing else sets it.

*As built, blocks (2026-10-02).* `parseBody`, `parseBlock` and `itemIsBinding` in
`src/parse/Parse.zig`; `inBlock` reads `block_col` as above, and `startBlock` clears it. Five
choices the text above left open:

- **A body at its item's own column.** Before blocks two bodies were written at the column of the
  item they belong to: a `let`'s body under `let`, and the body of a `<| λx ->` lambda continued at
  its line's indentation (`language.md` §9). Neither may open a block (B1) and neither may begin the
  next item, so for those two openers — `in` and a lambda's `->` — `parseBody` reads such a body as
  the one expression it was, its first token exempt from the column check as a block's head is.
  Every other opener refuses it: the line begins the next item and the opener has no body
  (`parse/bad/BlockShapes`). The formatter writes a `<| λx ->` body that is a block 4 further in.
- **An operator before the `=`.** A binding's head is a pattern, or a name and parameters, and
  neither holds an operator, so the item scan reads a line on which an operator comes before any
  depth-0 `=` as an expression: `f <input value="x" />` — whose `<` follows an operand and is a
  comparison — stays the markup argument `element_as_argument` names, not a binding.
- **Markup.** Between an element's `<` and its closing `>`, outside its holes, no token begins an
  item (`in_markup`): a child element or hole at the block's column is still the element's.
- **Depth.** A block costs no nesting level of its own; an expression item is charged by
  `parseExpr`, and a binding item by the block, since a binding's body may be a block whose first
  item is a binding again with no `parseExpr` between them.
- **The formatter** prints blocks from the slice that parses them, since every fixture that holds
  one is held to `beni fmt --check` (§11.6).

*As built, statements and `--migrate-let` (2026-10-02).* `let_stmt` keeps its expression in
**`rhs`**, where every other binding of a `let` keeps its value, so the passes that walk a `let`'s
bindings read it in one place; its `lhs` is the statement's last token (the AST `stmt` carries it
in its `rhs`), which `Session` needs to span `statement_not_unit` over the whole statement and to
quote it in the message's two fixes — the checker has no source, so it writes a marker the session
replaces. `--migrate-let` is `Format.formatWith` with `migrate_let` set: a body after an opener
prints its `let` as items (`blockItems`), flattening a `let` that is the body of another or the
value of a block; a `let` anywhere else is a parenthesised block (`letParenthesised`), reusing
`( let … )`'s parentheses, and is an ordinary operand of the operator chain it is in. Comments
before `let` and `in` stay where they were, and one on the `in` line goes above the value. Its
output is a fixed point of plain `beni fmt` (the black-box test runs both).

*As built, `let` refused (2026-10-02).* `parseLet` reports `let_removed` at the `let` before it
parses anything inside, so no damper can swallow it, and parses on. The message is the block the
`let` becomes, read from the source when it is rendered: the item's `head` spans the bindings and
the body, and its `required_col` — which no layout rule uses for this code — holds the offset of
the `in` between them; each part is moved to one column and indented 4 (`writeBlockLines`). The
formatter prints a `let` only under `--migrate-let`, which accepts a file whose only syntax errors
are `let_removed` and does not report them, as `--migrate-lambda` does for `\`. The parser's
`.continues` body (above) is kept for the `let`'s body, so a refused `let` still parses as it did.

*As built, trailing lambdas (2026-10-02).* `parseArgs` takes a `λ` (or a refused `\`) as the last
argument through `parseTrailingLambda` and stops. *L* is the column of the first token whose line is
the `λ`'s, but never less than the enclosing `indent` — a hole or a construct whose head is on the
same line keeps its own bound. A body that begins on a later line than the `->` is
`parseBody(.opens)`, so the `.continues` exemption above belongs to a `<| λx ->` lambda only; a
body on the `->` line is `parseExpr` with `indent` at *L* and `block_col` cleared, as `startBlock`
clears it, so a `|>` at the enclosing item's column ends the body as one at *L* does. A token that
can start an argument and still belongs to the application after the lambda — one on a later line
at or left of *L*, right of the enclosing block — is `unexpected_token` with the construct
`argument_after_lambda`, whose message shows the parenthesised form; the call is parsed on, so the
tree stays whole (`parse/bad/ArgumentAfterLambda`). The message for an `if` or `case` as a bare
argument no longer names the lambda.

### 11.3 AST, BIR and versions

- AST (§3.5): **`block`** (`main_token` its first item's first token; `lhs` an extra `SubRange` of
  the items before the value; `rhs` the value), whose items are the existing `let_def`,
  `let_pattern`, `let_annotation` and `let_bind` nodes and the new **`stmt`** (`lhs` the
  expression). A parenthesised block is a `paren` around a `block`. `dump --stage=ast` prints
  `(block …)` and `(stmt …)`. The `let` node kind stays, built only for a `let_removed` form, as
  `cons` stays for `cons_removed`.
- BIR (§3.6): one tag, **`let_stmt`** (`lhs` the expression), an item of a `let`'s range in written
  order. `dump --stage=bir` prints it as `let_stmt %n`. Lowering a `block` is lowering a `let` whose
  body is the block's value; nothing else in `Lower` changes. A trailing lambda is the `lambda` it
  always was.
- The frontend artifact's format version moves for the new token tag, node kinds and instruction
  tag, and the cache entry's with it (`fast-compiler.md` §8): an artifact cached before cannot be
  read as one after.

### 11.4 `--migrate-lambda` and `--migrate-names`: edits

Both are hidden `fmt` flags in the family of `--migrate-cons` (§1): **edits** that keep the file's
own layout and touch only the tokens they rewrite, so they may run on every `.beni` file in the
repository, the deliberately unformatted ones included. Each is mutually exclusive with the other
migration flags, reaches its fixed point in one run, re-parses its output, and leaves untouched —
naming it — a file whose output does not parse cleanly.

- **`--migrate-lambda`** replaces every `backslash` token that begins a lambda with `λ`. It moves no
  line, so the only layout it can disturb is `language.md` §12.1's *columns* row — a `case` whose
  first branch follows a lambda on the `of` line — which the re-parse catches.
- **`--migrate-names`** runs lowering's per-file name resolution (a pure function of the file,
  `language.md` §6.2) to find every reference to `Basics.modBy`, `Basics.remainderBy` and
  `Basics.logBase` — unqualified, qualified, exposed, or as a method — and rewrites it to `Int.mod`,
  `Int.rem` or `Float.log` (a method call `n.modBy 2` to `Int.mod n 2`, there being no method
  form since the types stay in `Basics`, `language.md` §12.4 as amended 2026-10-01; an `exposing` entry is
  dropped, and an emptied `exposing` list with it). It swaps the two arguments of every call of
  `Debug.log` written with two argument atoms (a parenthesised expression and `_` are atoms), and
  names every other use — a pipeline into `Debug.log`, a call with one argument — for a hand edit.
  Because `Debug.log` keeps its name, its core change and this rewrite land in one commit (§11.7).

*As built, `--migrate-lambda` (2026-10-02):* `Format.migrateLambda` rewrites the head token of
every `lambda` node that is a `backslash`, so a multiline string's `\\` and an escape, which are
other tokens, cannot be reached. It lexes and parses its output again; when that fails, the file is
written unchanged and reported with the re-parse's first diagnostic code at its line, under a
message that names the flag and the column shift. `\` is refused since the repository moved
(2026-10-02): the parser reports `backslash_lambda_removed` from `parseLambda`, its message the
head from the first parameter to `->` written after `λ` on one line, and goes on; the flag
accepts a file whose only syntax errors are that code and does not report them, as
`--migrate-cons` does for `cons_removed` (an error filter, not a parser option). The formatter
therefore only ever prints `λ`.

*As built, `--migrate-names` without its `Debug.log` half (2026-10-01):* `Format.migrateNames`
reads the file's own names, which is all lowering's resolution of them is: an `ident` whose token
is a removed name is `Basics`'s when the file has no other token of that name — no declaration,
binding, record field or other module's `exposing` entry — and a file that has one is left alone
and named, since its unqualified uses may be its own. A qualified name is rewritten when its alias
is one `Basics` has in the file (`Basics` itself unless another import took that alias, and any
`import Basics as B`); a file where `Int` or `Float` is another module's alias is left alone. A
method `x.modBy k` becomes `Int.mod x k` when it is called with one argument, and is named for a
hand edit otherwise; a `.modBy` accessor is a record field's and is never touched. An emptied
`exposing` list goes with its keyword. The output is parsed again, as `--migrate-lambda`'s is. The
removed names are one table, `prelude.removed`, which `name_removed` reads too.

*As built, the `Debug.log` half (2026-10-01):* a call of `Debug.log` — through `Debug` or any
alias `import Debug as D` gives it — with two arguments, the second a string literal and the first
not, has the two exchanged, the bytes between them kept; a call whose first argument is the literal
is already label first and is left, so the flag can be run again on a merged file and never turns a
call back. Every other use is named in a warning for a hand edit: a pipeline into `Debug.log`, one
argument, two string literals, or none (a label held in a variable, `Debug.log v label`). The
repository's 49 such uses were turned round by hand in the same commit. A call inside another
call's rewritten argument is copied as written and taken by a second run.

### 11.5 `--migrate-let` and `--migrate-trailing-lambda`: reformats

These two cannot be edits: a block's layout is not `let`'s, and a parenthesis dropped from a lambda
moves where its body ends. Each **parses with the old form accepted and prints the whole file with
the formatter**, so it is run only on files the `beni fmt --check` gate already holds canonical
(§11.6), where printing changes nothing but the construct migrated. A fixture outside the gate — a
`fmt/` input, a `parse/` fixture that pins a layout — is migrated by hand, and the slice that runs
the flag lists them.

- **`--migrate-let`** prints each `let … in e` as a block: the bindings, then `e`. A `let` that is
  the value of a block, or the body of another `let`, is flattened into the enclosing block — safe,
  because the inner names were not in scope above them, the items keep their written order, and the
  binding groups are recomputed by dependency, not by nesting (`checker-v2.md` §6). A `let` in a
  position no opener heads (`language.md` §12.2) becomes a parenthesised block, and `( let … )`
  reuses its parentheses. A comment attached to `in` moves above the value line.
- **`--migrate-trailing-lambda`** prints with `language.md` §12.5's *trailing lambdas* rule turned
  on: the parentheses of a last-argument lambda dropped where no operator or `?` follows, and
  `f <| λx ->` written `f λx ->`. The rule becomes the formatter's own in the slice after the
  migration, when the gate already holds every file in that form.

*As built, trailing lambdas in the formatter (2026-10-02).* `Printer.trailingPlan` decides, for an
application whose last argument is a lambda, how it prints; the gaps the rules above left are
closed so that the formatter never writes a lambda without parentheses that would read
differently:

- **What may follow a bare lambda.** "No operator or `?` follows" is read over lines, not on the
  `)`'s line only: an operator on a later line that begins a line right of the `λ`'s line would
  continue the body too (§12.3). A pre-pass records, for each such application, the operator or
  `?` that follows it (`tail_op`); `chain` records, before printing an operand, where each of its
  operators lands (`op_place`). The lambda is bare when nothing follows, or when the operator
  begins a line at or left of the line the `λ` is printed on — a later stage of a vertical
  pipeline. The first operand of a broken chain, any operand of a one-line chain but the last, and
  the operand of `?` keep their parentheses, and a lambda written bare in one of those places — the
  parser reads `f λx -> x` / `|> g` at an item's column that way — is printed in parentheses
  (`fmt/TrailingLambdaLayout`). So *"the lambda ends its line"* of `language.md` §12.5 is read as
  "nothing that would continue its body follows it": a closing bracket or a comma may, as in
  §12.6's `List.length (List.filter model.todos λt -> not t.done)`.
- **Layout.** One line when the application fits with the lambda bare; else the callee and the
  other arguments on one line whatever breaks the source had, when they fit (the `λparams ->`
  head is not counted, as a pattern is never broken), `λparams ->` ending it and the body below
  when it does not fit after the `->`; else one argument per line. A definition or binding keeps
  that head line on its `=` line when the head and `λparams ->` fit there (`rhs`). The body joins
  the `->` line whenever it fits, which is what makes a first run's output a fixed point. The
  measure (§3.7) agrees: an application whose last argument is printed as a bare lambda is not
  pinned vertical by the source's breaks between its arguments, and one whose parentheses are
  dropped wherever it lands — nothing follows it — is measured without them, so an enclosing
  group decides on the width the second run will see.
- **What is left as written.** A parenthesised lambda with a comment on either parenthesis or
  between its `λ` and its `->`, and
  `f a <| λx ->` when the left of `<|` is not a call without `_`, a name or an accessor, or a
  comment sits at the `<|`, or the `<|` is not the chain's only one (`g <| f a <| λx ->`): those
  keep their spelling.
- **Structure.** Parentheses dropped or added and a `<|` written as an application are the one
  difference between the AST before and after; the formatter's tests and the `fmt/` corpus compare
  the dumps with that spelling undone (`withoutLambdaSpelling`), and the BIR, which lowers `paren`
  and `<|` to nothing, does not differ at all.

*As built, the rule enforced (2026-10-02).* After the repository moved (the mechanical commit
named `--migrate-trailing-lambda`), the rule is the formatter's own: plain `beni fmt` drops the
parentheses and writes `f a <| λx ->` as a trailing lambda, and the flag stays, hidden, as a
synonym of plain `fmt`, so a branch can still be migrated with the flag its commit names. A
`<| λx ->` the formatter cannot write as a trailing lambda keeps `language.md` §9's flat form.

### 11.6 The `beni fmt --check` gate

`build.zig` gains the step **`beni-fmt-check`**, part of `gates`. It walks `core/`, `platforms/`,
`bench/`, `tests/corpus/` and `tests/platforms/` in sorted path order for `.beni` files, drops those
`tests/fmt-exempt.txt` matches (`language.md` §12.5), and runs the gates' ReleaseSafe beni as
`beni fmt --check` over the rest, in chunks small enough for the instruction budget. A file that is
not canonical, or does not parse, fails the step with its path; so does an exemption entry naming a
single file that does not exist or is canonical. The exemption list is one glob per line (`**` and
`*`, matched against the repository-relative path), then `--` and a reason; blank lines and lines
that begin `--` are ignored. `zig build beni-fmt-check` runs the step alone.

### 11.7 The formatter, and the order of work

§3.7's measure carries `language.md` §12.5's rules with two changes to what it records: an `if`'s
width is no longer "does not fit" by kind — it is the sum of its parts when each has a one-line form
and the source put no line break inside it — and a block is always "does not fit". A hanging
application is decided from the widths of its callee and its arguments but the last, all of which
the measure already has; the source breaks between those arguments are read and ignored, the one
place the printer does not honour them. The blank line after a standalone comment is read from the
comment array and the token lines, as blank lines between bindings are. The aligned first parameter
is a constant in the type printer. Each rule is decided from the AST, the widths and the comment
array alone, so the printer stays idempotent.

**The order the repository moves in** is the same for every piece, and it is what keeps `zig build
gates` green at every commit: **teach** (the compiler accepts the new form, and still the old one),
**migrate** (a mechanical commit that runs the flag and does nothing else), **enforce** (the old
form is refused, or the formatter prints only the new one). The one exception is `Debug.log`, whose
order changes under an unchanged name, so its core change and its `--migrate-names` rewrite are one
commit, whose diff outside `core/Debug.beni` is mechanical.

### 11.8 Unicode notation in the front end

*Added 2026-10-01; specified, not built.* How the lexer, parser, formatter and `beni fmt
--migrate-unicode` build [`language.md`](language.md) §12.7–§12.9, in the order
[`plans/syntax-batch.md`](../../plans/syntax-batch.md) slices 18–20 give.

**The lexer.**

- **Tags.** Nine new tags — `arrow`, `arrow_left`, `op_ne`, `op_le`, `op_ge`, `op_pipe_right`,
  `op_pipe_left`, `ellipsis` and `times` — for the symbols, and the ASCII spellings' tags renamed
  `ascii_arrow`, `ascii_arrow_left`, `ascii_ne`, `ascii_le`, `ascii_ge`, `ascii_pipe_right`,
  `ascii_pipe_left` and `ascii_ellipsis` (`language.md` §12.7 *tokens*). Two tags and not one,
  because a token's length is re-derived from its tag (§3.2). Each `ascii_*` operator tag sits in
  the binary-operator range beside its symbol, so the parser's binding-power table has one row per
  pair. `dump --stage=tokens` prints the tag names; its goldens move in the teach slice.
- **Recognition.** The ASCII-only check that already admits `CE BB` as `lambda` (§11.1) admits the
  nine sequences of `language.md` §12.7's table — eight begin `E2`, `×` is `C3 97` — by a
  switch on the lead byte and an exact match of the next one or two. Strings, characters, multiline
  strings, comments and markup text are scanned by their own states and never reach that check,
  which is what keeps the symbols out of them.
- **Lookalikes.** A sequence in §12.7's lookalike table is reported as `invalid_character` with the
  intended symbol in the message, and lexed as one token of a tenth new tag, **`lookalike`**,
  whose payload is the intended symbol's tag and whose length is re-derived from the UTF-8 sequence
  at `start`, as an identifier's is. The parser reads a `lookalike` as its payload's tag, so the
  parse goes on as though the symbol had been written. `!=` is one `lookalike` (payload `op_ne`,
  length 2); `−` and `－` carry `op_minus`. A fullwidth form is plain `invalid_character` with the
  ASCII character named and no token, as today. `=>` and a `*` in a type are the parser's, as
  messages of the codes they already raise.
- **Columns.** A diagnostic's column, its excerpt's underline (`src/render/text.zig`) and the
  parser's layout comparisons count code points (§3.1). A token that begins its line follows ASCII
  indentation, so its column is still `o - line_starts[l] + 1` and costs nothing; only a column
  taken mid-line — a diagnostic, and the `case` whose first branch shares the `of` line — counts
  the non-continuation bytes before it.

**The parser.** Every site that matches `arrow`, `arrow_left`, `ellipsis` or one of the six
operators matches the pair, through one helper that maps an `ascii_*` tag to its symbol's, so
until slice 20 the two spellings parse identically and build identical nodes. The type parser
gains `Product` (`language.md` §12.8): after a `TypeApp`, a `times` continues a product whose
operands are `TypeApp`s, flat, and a parenthesised type is an operand that is never flattened. A
product is the existing node **`type_tuple`**, its `main_token` the first `times`; the
parenthesised form keeps building `type_tuple` with its `(` as `main_token`, so the AST and BIR
dumps of `Int × String` and `( Int, String )` are byte-identical (the teach slice's fixture says
so) and the formatter can tell the two spellings apart by the tag of `main_token`. The dumps
name an operator by its symbol whichever tag was read (`language.md` §12.7), so the `ast` and `bir`
goldens that print `/=`, `<=`, `>=`, `|>` or `<|` move in slice 18, and only there. From slice 20
the helper reports `ascii_symbol_removed` once per `ascii_*` token it consumes, and the tuple type
`tuple_type_removed` at its `(`, its message the product built from the node's own children; both
parse on. The frontend artifact's format version moves in slice 18 for the new tags and in slice
20 for the two codes (`fast-compiler.md` §8), the cache entry's with it.

**The formatter** prints each token from its tag, so it keeps the spelling it read for free until
slice 20 removes the ASCII; a `type_tuple` whose `main_token` is `(` prints as it did, one whose
`main_token` is `times` as a product (`language.md` §12.9). §3.7's measure counts a token's code
points, not its bytes — one more pass over the token's bytes, which the measure already slices —
and the printer's `curCol` with it.

**`--migrate-unicode`** is an edit in the family of §11.4: it keeps the file's own layout, may run
on every `.beni` file including the deliberately unformatted ones, reaches its fixed point in one
run, accepts a file whose only syntax errors are `ascii_symbol_removed` and `tuple_type_removed`
(an error filter, as `--migrate-lambda` has), re-parses its output and leaves untouched — naming
it with the re-parse's first diagnostic — a file that no longer parses.

- **Tokens.** Every `ascii_*` token is replaced by its symbol and nothing else on the line moves.
  It reaches only tokens, so a string, character, multiline string, comment, doc comment, markup
  text or quoted attribute value is never touched, and the code in an interpolation hole, a markup
  hole and an attribute's `{…}` value is. A `<-` outside a bind (`x <-1`, meant as `x < -1`) is a
  syntax error today, so a file holding one is left alone and named.
- **Tuple types.** Every `type_tuple` whose `main_token` is `(` is written as its element types
  joined by ` × `, each element's own text kept (rewritten recursively, innermost first), and
  wrapped in parentheses exactly where a product must be an atom — a type-application argument,
  a constructor's payload, an operand of an enclosing product — and nowhere else. A tuple type the
  author wrote across lines is written on its first line, which is safe because a type holds no
  layout; one that holds a comment is left and named for a hand edit.
- **Columns** shift on a rewritten line (`->` is two columns, `→` one; a tuple type shrinks), and
  layout compares only line-start columns but for the `case` of §12.1, which the re-parse catches.
- The slice that runs it then runs plain `beni fmt` over the gate's scope, for a joined tuple type
  that now passes 100 columns; it is the one way the flag's output can fail the gate.

**What the flag does not rewrite**, and slice 19 rewrites by a reviewed script in the same
commit: core's doc comments (`--|` examples, which the docs test compiles), code in Zig test
sources and generators, and the normative examples of `docs/design/`. The compiler's own message
texts and the type renderer switch in slice 20, with the removal codes (`language.md` §12.9). Prose that names the ASCII spelling on purpose — this section, the removal
messages, `language.md` §12.7's tables — is not rewritten.
