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

Later milestones add stages to `dump` without changing its shape: `interface`, `raw`, `types`,
`graph` and `dispatch` ([`checker.md`](checker.md) §2). They also add one common flag, `--explain`,
for informational `warning`-severity diagnostics that are otherwise suppressed. **It governs nothing
today**: the one diagnostic it gated, `ambiguous_method_receiver`, is emitted by default since
2026-09-18 ([`static-dispatch-spike.md`](static-dispatch-spike.md) §10 preamble, A.83). The flag is
still parsed and accepted, so nothing that passes it starts failing, and it is where the next
informational diagnostic goes. A warning cannot change an exit code (below) either way.

`build` arrived with M3a and its flags are `backend.md` §2's; the rest of this document is M0/M1's
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
| `--jobs=<n>` | worker threads for per-file phases; output is identical for every `n` | logical CPUs |
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

**The persistent cache** (M4-1; [`fast-compiler.md`](fast-compiler.md) §8 has the key and the
layout). Two flags, on `check` and `build` only:

| Flag | Meaning | Default |
|---|---|---|
| `--cache-dir=<path>` | keep checked modules between runs in this directory | off — there is no default directory in M4-1 |
| `--no-cache` | ignore `--cache-dir` and any default | off |

They are `check`'s and `build`'s and not common options, because `fmt` resolves nothing and `dump`
prints a representation rather than a result — a flag that is accepted and does nothing is the
mistake `--source-maps` is refused to avoid ([`backend.md`](backend.md) §2), so `fmt --cache-dir=x`
and `dump --cache-dir=x` are the ordinary `unknown option` and exit `2`. `--no-cache` exists before
there is a default so that a script written today keeps working the day the default arrives (M4-3).

**A cache never changes an answer and never fails a build.** The directory is created if it is
missing and a failure to create it is `2` with the path named, like `--out`'s; after that, every
per-entry read or write failure — a read-only directory, a full disk, a lost race, a corrupt
file — is silent, and the run produces byte-identical output to one with no cache at all. A stale or
damaged entry is a miss, never a diagnostic: `--self-profile`'s `cache_hits`, `cache_misses` and
`modules_checked` counters are where a cache that is doing nothing says so.

Three more flags are hidden, like `--roundtrip-interfaces` and `--iface-hash`, and for the same
reason — they are diagnostic surface, absent from `beni help` and from [`checker.md`](checker.md)
§2's table. `--cache-build-id=<s>` replaces the compiler build id in the key, so a test can prove
that a compiler change discards the cache. `--cache-keys` makes `check` print one
`<package>:<Module> <32 hex digits>` line per module on stdout, sorted by that key, exactly as
`--iface-hash` prints the record's — it is how an edit-scenario fixture asserts *which* modules a
change reached, with no cache directory involved. `--roundtrip-dispatch` is `--roundtrip-interfaces`'
twin for the dispatch sidecar: every module's table is written, read and re-resolved in place the
moment its check finishes, so every emitted file downstream is built from a table that has been
through the format. **`--roundtrip-frontend`** (M4-2) is the third of that family and the first that
is not the checker's: every file's `Bir`, token spans, line-start table and front-end diagnostics are
written to bytes and read back in place the moment its per-file phase ends and **before anything
downstream reads them**, so every dump, every diagnostic, every dispatch table and every emitted byte
is built from artifacts that have been through the format. It is on `Common` like its two siblings,
because `dump` has to be able to take it: `dump --stage=tokens|ast|bir` is the lossless textual form
of exactly these artifacts and is therefore the identity oracle the round trip is asserted against.
An `ast` dump under the flag is unchanged by construction — the `Ast` is not among the artifacts
(§3.5) — and that is a fact the acceptance matrix asserts rather than assumes. **`--frontend-keys`**
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

`line_starts` is the only thing the lexer leaves in the store, and **it is a cached artifact** (M4-2,
`fast-compiler.md` §8): four reporters turn an offset into a `diagnostic.Position` through it, so a
file whose lexer did not run still needs one. There is no size, mtime or inode column and M4-2 does
not add one — a `stat` fast path is M4-5's, and §8 says why.

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

**Two of the four columns survive `lower`, and only those two are cached** (M4-2,
`fast-compiler.md` §8). `line` is the parser's — layout is decided per token — and `payload` is the
parser's and lowering's; nothing reads either again. `tag` and `start` are read by four sites after
the front end, all of them turning an instruction's `main_token` back into bytes: `Session.tokenSpan`
and `moduleNameOfImport`, `Emit.tokenPosition`, and `js/Lower`'s `token_starts`. So the cached form
is 5 bytes a token in two columns rather than 13 in four, and — the part that matters more than the
size — **it holds no `Symbol`**, because `payload` is the only place a token ever did.

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

**The `Ast` is not cached, and that is a decision and not an omission** (M4-2, `fast-compiler.md`
§8). It is the easiest artifact in the compiler to cache — three flat arrays, no `Symbol`, no fixup
pass (`src/parse/Ast.zig:8-9`) — and **nothing on a `check` or a `build` path reads one after
`lower` returns**. Its three readers are the formatter, `dump --stage=ast`, and the parse phase that
made it, and neither `fmt` nor `dump` takes a cache flag (§1). Caching it would be bytes written on
every cold build and loaded by nothing. M5's LSP is the one consumer that will want a tree back, and
it wants it for the file being edited, which is a miss by construction. The same reasoning excludes
`comments`, whose only readers after lowering are the same two commands.

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

**The Bir has two states and only the first is cacheable** (M4-2, `fast-compiler.md` §8;
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

**Step 2 gains a hit path with M4-2** (`fast-compiler.md` §8), and it is the whole of the slice's
shape: the worker reads the file's bytes, hashes them into the file key, and — if the artifact is on
disk and validates — installs the loaded `Bir`, token spans, line-start table and rendered front-end
diagnostics instead of lexing, parsing and lowering; otherwise it does what it does today and
**writes the artifact from that same worker before moving on**. Reading and writing both stay on the
worker because the per-file phase already does file I/O and is already parallel; the one thing that
may NOT stay there is the string table's re-interning, because `InternPool.Global` is thread-confined
(`src/InternPool.zig:24-26`). So a hit interns into the **worker's own `Local` pool**, and step 3's
existing merge carries it to the global one — the load produces exactly the kind of local numbering
`Global.merge` was written to reconcile, so no rule changes and no new synchronisation appears.
*Rejected: a serial pre-pass that loads every artifact before the workers start, as M4-1's entry
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

M4-2 adds two `X` rows and three counters, and the counters are the load-bearing half. The rows are
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
`./zig-out/bin/beni` with cwd = the temp dir and returns `{exit_code, stdout, stderr,
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
