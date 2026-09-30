# Backend implementation contract (M3)

**Status:** normative for M3. [`fast-compiler.md`](fast-compiler.md) §9 says *why* the backend is
shaped this way and §2 what it must measure; [`boundary.md`](boundary.md) says how emitted code
meets JavaScript; [`research/12-js-output-and-chunking.md`](research/12-js-output-and-chunking.md)
is the evidence for every size claim below. This document says what the code looks like.

M3 ends when `beni build` produces JavaScript that runs and the emitted output is measurably close
to what a dedicated minifier would produce. The third condition this line used to carry — a direct
call share high enough to justify keeping currying — is discharged rather than met: §9.3 dropped
currying on 2026-09-14, so the share is 100% by construction (§6).

## 1. Scope and order

The order is not negotiable and one rule sets it: **nothing is optimised before it can be run.**
`boundary.md` §8 puts the Node platform before the optimiser for this reason — the test suite's
second boundary is compiling a program, running it under Node and asserting what it printed, and a
backend that cannot be executed is a backend whose bugs survive a green suite.

- **M3a — emit and run.** *Shipped.* `JsIr`, the printer, codegen for the pure subset, core's
  foreign JavaScript for what that subset uses, a minimal Node platform, and the harness boundary
  that runs emitted code. *Acceptance: a beni program computes something and prints the right
  answer* — `tests/corpus/run/` is 26 programs that do, executed under Node. All 65 of core's
  foreign values are implemented, not only the ones the subset reaches. `?` was the one construct
  of §4's table M3a did not compile, and it said so with a diagnostic rather than emitting
  something wrong.
- **M3b — the whole language.** Tail-call loops, decision trees, interpolation, `?`, tuples, record
  update, `Int32`, everything remaining. *Acceptance: the corpus compiles and runs.* **Four of the
  seven were stale when the list was written** and one is not a backend item at all: interpolation,
  tuples and record update worked in M3a (`plans/m3b-audit.md` measured every row of §4 against the
  code), and tail-call loops (§8), decision trees (§7) and `?` (§4) have landed since. **`Int32` landed on 2026-09-19 and the list is spent.** It was a *language* gap
  and never a codegen one — no type, no `core` module, no paragraph in `language.md` — and what
  built it is `core/Int32.beni` with its sibling, `language.md` §2.5 and Appendix A, and
  `checker.md` Appendix B's signature list. The emitter needed **no change at all**: an `Int32` is
  a number, its operations are ordinary `foreign` calls, and `==`/`<` on one resolve through the
  module rule to the module's own `pub eq`/`pub compare` like any other type's.
- **M3c — the optimiser.** Reachability elimination, reachability-driven inlining, local
  dead-binding elimination, renaming, field ambiguation, compact printing. *Acceptance: §9's size
  and throughput numbers, and §9's size and throughput numbers alone; the direct-call share that used to decide §9.3 is
  discharged, not measured (§6).* **Reachability elimination is built first and is not optional**:
  static dispatch derives eagerly, so an empty program ships 3 159 bytes of `eq`/`compare` that
  nothing calls, and `fast-compiler.md` §13 moved this pass from an optimisation to a prerequisite
  on that evidence. Its own acceptance is separate and exact: the floor's `derived_bytes` is **0**
  for a program that compares nothing (§9).

  **M3c ships in two slices, and the first one is what `--release` means.** The first is §9 items
  **1, 2, 3 and 5** — local dead-binding elimination, short names, compact printing and variable
  joining — together with the flag itself; it is one pass over `JsIr`, one name table and one
  printer boolean, and it stands alone because none of the four needs anything the backend does not
  already have. The second is item **4**, type-directed field ambiguation, which needs an artifact
  §3 says the backend does not receive, plus anything chunk-facing (§10). Sliced that way because
  the first is worth a measured **31% of `bench/corpus`'s compressed bytes** and the second is
  worth report 12's 4% (§9), and because a `--release` that is refused is worse than a `--release`
  that is not yet perfect. The one entry in this bullet's own list that is in neither slice is
  **"reachability-driven inlining"**, which was never a §9 item and has no measurement behind it;
  what §9 now specifies under item 1 is single-use inlining of the temporaries §4, §7 and §8
  generate, which is a different and measured thing.
- **M3d — chunking and `lazy`.** The keyword, entry-set colouring, the merge pass, cross-chunk
  bindings. *Acceptance: a two-route program splits and both routes run.*

  **The two halves have a dependency between them and it is not small.** §10 specifies the chunker;
  the keyword is PENDING an owner decision, because a deferred load is asynchronous, the language is
  synchronous, and `fast-compiler.md` §9.5's type rewrite names a `Task` that
  `transparent-effects-proposal.md` removes. [`plans/m3d-plan.md`](../../plans/m3d-plan.md) §2 is the
  argument, §6 the decisions — including what "route" means on a platform whose only entry point is
  `main`, and whether the chunker ships against multiple entry points before `lazy` exists.

`boundary.md`'s B1 and B2 fold into M3a; B3 through B5 follow M3d.

## 2. CLI surface

```
beni build [options] <entry>...      compile to JavaScript
```

| Flag | Meaning | Default |
|---|---|---|
| `--platform=<name>` | which platform package supplies `main`'s type and the runtime | required |
| `--release` | dead bindings out, short names, compact printing, joined `const`s (§9); **refuses a build that reaches `Debug`**; later chunks (§10), integer tags, maps off | off |
| `--library` | no `main` is required and no entry file is written; every name the root package's modules export is a reachability root (§9) | off |
| `--out=<dir>` | output directory | `out/` |
| `--source-maps` | emit `.map` files | M5; refused today, on in dev and off in release once §11 lands |

**`--source-maps` is refused, not ignored.** It is not implemented — the encoder is M5 (§11) — and a
flag that is accepted while doing nothing makes a user believe they asked for something: a silent,
successful `--source-maps` build sends them looking for a `.map` that was never written, exactly as a
silent `--release` build would have shipped development output. It exits `2` with `frontend.md` §1's
one-line usage message naming the milestone. The defaults in the table above are what M5 will do;
until then the only way to build is without that flag. `--release` was refused on the same argument
and no longer is, because the optimiser's first slice implements it.

**`--release` stopped being refused with the optimiser's first slice, and `--source-maps` did not.** The
refusal was one branch (`src/Cli.zig:362-364`); it went, the `release: bool` already parsed at
`:338-341` reaches `Emit.Options`, and the usage line at `:46` states what the flag does rather than
what it does not. Nothing else about the command changed: `--release` takes no value, composes with
`--library` and `--out` and `--jobs` exactly as `--library` does, and **implies nothing** — in
particular it does not switch elimination on, because elimination is always on (§9), and it does not
switch source maps off, because there are none to switch. `--source-maps` keeps its own refusal at
`:369-371` and keeps it in a `--release` build too, so the pair `--release --source-maps` exits 2 on
the source-map line. The one thing it changes beyond §9's four passes: the entry file's two-line
header comment goes, which is 135 bytes of the floor's 2 009. `dump --stage=…` is untouched for the same reason §9 gives: every stage is
before the backend.

**`--release` does refuse one thing, and it is not a flag: a build that reaches `Debug`** (the
owner's decision, 2026-09-19; the rule and the reasons are §9's *The release optimiser*, under *`Debug`
is refused, not pinned*). It exits `1` with `debug_in_release`, writes nothing to `--out`, and names
the use sites. That is Elm's rule for `--optimize`, and it is what lets this section's "a release
build behaves exactly as the development build does" stand with no exception. It is a refusal of a
PROGRAM and not of a flag, so unlike `--source-maps` it is a diagnostic on stderr and exit `1`
rather than a usage line and exit `2`.

**There is a third hidden flag, `--allow-debug`** (`src/Cli.zig`, alongside `--roundtrip-interfaces`
and `--iface-hash`), absent from the table above and from `beni help` for their reason: it is
diagnostic surface, not product surface. It turns that refusal off and changes nothing else — not
one emitted byte, in either mode. It exists because `Debug.log` is the corpus's only instrument for
observing evaluation order and the `--release` second pass over `run/` is what proved the wide
inliner unsafe (§9 item 1); a refusal with no way past it would silently stop 24 of the 121 fixtures
from being built in release at all. `tests/corpus/build/bad-release/` is the kind that does NOT pass
it. **Development output does not move by one byte** — every `emit/` golden, every
`run/` `.expected` and every `bench/size.mjs` figure in this document is a dev-build figure and stays
one — which is what makes "a golden moved" a finding rather than a blessing for the whole slice.

**`--library` is not in that company**: it lands with §9 and does something the day it lands. It
turns off exactly two things — the REQUIREMENT for a `main` (`missing_main` does not fire, a second
`main` is not a `duplicate_main`, and a `main` that is there is not checked against the platform's
`Program`)
and the entry file — and turns on one, the root rule. A `main` that happens to exist is still
exported and still a root, because §5's export list has the entry declaration in it and §9 roots a
library at its export list; §9's "Roots" says why at length. It is not a second output mode; a
library build emits the same `.mjs` per module as any other.

Development output is **one ESM file per source module**, mirroring the source tree, with readable
names — but not with everything the source declared. Release output is **reachability chunks**. Both
read one declaration graph (§9.1 of the design doc) and **both eliminate against it**: a dev build
and a release build ship the same set of declarations and differ in how those are named, laid out
and grouped into files. Nothing is built twice. §5.3 of `boundary.md` makes a build a pair of entry
point and platform, so a project with a client and a server runs `build` twice.
*Amended 2026-09-30:* until §10's chunks exist, a release APPLICATION is one file, the entry file,
holding every module, sibling and runtime of the program in one module scope (§9, *One scope-hoisted
file under `--release`*); a release `--library` build keeps one `.mjs` per module.

**Elimination is not behind a flag**, and §9 gives the reason: eager derivation makes it the
difference between an empty program shipping 70 kB and shipping 2 kB, and a development build that
ships fifty times what it needs is not a development build anyone would run. What `--library`
changes is the root SET and never whether the pass runs.

A successful build prints **nothing, on either stream**. `frontend.md` §1 gives stdout to the product
and stderr to diagnostics and nothing else; a build's product is the files it wrote, so there is no
stream left for a summary line, and `check` already sets the precedent. How much was written is a
`--self-profile` counter (`emitted_files`, `emitted_bytes`), which is also where the incrementality
tests read "this edit rewrote one file".

File extension is `.mjs`, so nothing depends on a `package.json` the user owns. **That applies to
every file a build writes, the hand-written ones included** — the first backend shipped copying core's siblings
and the platform's runtime out as `.js`, and Node then reparsed each one and warned
`MODULE_TYPELESS_PACKAGE_JSON` on every start, whose own suggested remedy is adding `"type":
"module"` to a `package.json`. That is the dependency this rule exists to avoid, arriving through
the back door. (*Amended 2026-09-28:* the rule is about files that are LOADED; the one
file a build writes that is not a module, `_manifest.txt` — *The output directory holds what the
last build wrote* below — is not `.mjs` and is never imported.) A copied file cannot simply keep its stem, because `out/_core/List.mjs` is already the
generated module, so it takes **`.foreign.mjs`**: it says which half of the module it is, and it
cannot collide — a generated file is named for its module, every segment of a module name is an
upper identifier, so no generated file has two dots in its base name. The `.js` names in `core/` and
`platforms/` on disk are unchanged; `language.md` §5.4 fixes the sibling's NAME and not its
extension, and only the copy is executed.

The rename has one consequence the backend refuses rather than gets wrong: **a sibling may not import
another FILE.** `import { cons } from "./List.js"` is written against a name the copy no longer has,
and rewriting the specifier is not done. A bare specifier — `node:process`, a package — survives the
copy untouched and is what `boundary.md` §4's third check is really about, so nothing that check
blesses is lost today except sharing a helper file between two siblings. The `not_implemented` this
raises **points at the specifier itself, inside the `.js`**, by `boundary.md` §4's *a diagnostic
points at the file whose text is wrong*; it used to land on the first `foreign` declaration of the
module beside it, which is a line nobody would think to look at.

**No `package.json` is written into the output, and that is deliberate.** `.mjs` already makes every
file an ES module whatever any `package.json` says, so one would add nothing — and it would put back
exactly the file the extension was chosen to avoid, inside a directory the user chose (`--out` may
well point at something they own). A build writes only files it named itself.

### The output directory holds what the last build wrote, and nothing it wrote before

*Added 2026-09-28.* Until then a build only ever ADDED to `--out`: build a
`Main` importing `Half` and `Dict`, then a `Main` using neither into the same directory, and
`out/Half.mjs`, `out/_core/Dict.mjs` and their siblings survived beside a program that never
wrote them — stale modules a reader of `out/`, a bundler globbing it, or a deploy copying it
all take for part of the program.

**The rule: after a successful build, the files of `--out` that beni wrote are exactly the files
a build of the same program into an empty directory writes.** A file an earlier build wrote and
this one does not is removed, and so is a directory the removal leaves empty. Nothing else in
`--out` is touched: `--out` may well be a directory the user owns (the `package.json` paragraph
above), and a file beni did not write is never beni's to delete.

**What beni wrote is recorded, not inferred.** Every successful build writes a manifest,
`_manifest.txt`, at the root of `--out` — a reserved name by rule 1 below, and one no platform
`"entry"` can take because an entry name ends in `.mjs`. Its first line is `beni-manifest 1`;
each further line is one file the build wrote, as `<hash> <path>`: the path relative to `--out`
with `/` separators, in write order, and the hash the 64-bit Wyhash of the bytes written, as 16
lower-case hex digits. The manifest itself is not listed and is not counted in `emitted_files`.
A stale file is removed only when **all** of these hold, and is left alone otherwise, silently:

1. the previous manifest lists it, and this build does not write it;
2. its path is relative, `/`-separated, and has no empty, `.` or `..` segment — a manifest is a
   file in a directory anyone can edit, and a line that could name something outside `--out` is
   not acted on;
3. its bytes still hash to what the manifest recorded. A file the user has since edited is
   theirs now, and survives;
4. *(added 2026-09-28)* it is not **the same file** as one this build
   writes. `Ab.mjs` from the last build and `AB.mjs` from this one are one file on APFS and NTFS:
   comparing paths byte for byte read the file just written there, found the old hash whenever
   the bytes agreed (two `--release` modules of identical content do), and deleted it. So a stale
   path equal to a written one under ASCII case folding — the folding rule 2 of the next
   subsection uses — is removed only when the file system reports the two names as two files
   (different inode numbers); if either cannot be stat'd, it stays. On a case-sensitive file
   system they are two, the older one goes, and `--out` still matches a fresh build.

*Amended 2026-09-28.* A manifest must be beni's to be acted on OR
overwritten. `_manifest.txt` is beni's when its first line is `beni-manifest 1` and every
further line is `<16 hex digits> <path>`, the file ending in a newline. A file of that name in
any other shape — the user's own notes, a future version's format, one that cannot be read — is
somebody else's: the build is **refused** with `unknown_output_record`, naming the file, before
the first byte is written, and `--out` is left as it was. (Until the amendment such a file read
as an empty manifest and was silently overwritten.) A well-formed line whose path fails rule 2
is still only skipped, never refused: the manifest is beni's, edited, and the one thing ruled
out is acting on that line. With no manifest at all — the first build into a directory, or a
directory from before this rule — nothing is removed.

*Amended 2026-09-29.* A `_manifest.txt` that exists and **cannot be read** is no longer called
somebody else's: whose it is cannot be told, and `unknown_output_record`'s "does not begin with
`beni-manifest 1`" was a claim nobody could check. The build fails as it does for any file it
cannot read — `beni: cannot read 'out/_manifest.txt': AccessDenied`, exit 2 — still before the
first byte is written, and `--out` is left as it was.

*Amended 2026-09-29: beni writes through no symbolic link.* beni makes no link in `--out`, so one
there is somebody else's, and writing its path writes wherever it points — outside `--out`,
possibly. A dangling `_manifest.txt` link read as no manifest, and the build wrote the manifest
through it; a `_main.mjs` link had the entry file written over its target. Before the first byte
is written, every path the build would write — the manifest and each output — is examined under
`--out` component by component without following links, and the first link on each is refused
with `unknown_output_record`, naming the link (and, for a directory, the file the build would
write inside it). Nothing is written. `--out` itself may be a link: the user named it. A write
that fails names the file that failed: the manifest's is `out/_manifest.txt`, not `out`.

**Deploying `--out`.** `_manifest.txt` is served next to the modules unless the deploy excludes
it; it lists the path and a content hash of every file the build wrote (modules, copied
siblings, the runtime and the entry file), and nothing else. *(Added 2026-09-28.)*

**The order makes an interrupted build safe.** Before the first output byte, the manifest is
rewritten as the old entries followed by the new ones (the union, so a build killed halfway still
lists every file either build may have written). Then the outputs are written, then the stale
files removed, then the manifest rewritten with this build's entries alone.

**A refused build changes nothing** — no output, no removal, no manifest — for the reason the
checks of *The output tree does not depend on the file system's case sensitivity* run before the
first byte: a build that says it failed leaves `--out` exactly as the last successful build left
it.

### The output tree does not depend on the file system's case sensitivity

**A build's output is the same set of files on every file system.** That is the guarantee, and it
is worth stating because it was not true. macOS (APFS) and Windows (NTFS) fold case by default, so
two output paths that differ only by case are ONE file there: whichever is written second wins, and
the build exits `0` having shipped something that throws at load. Until 2026-09-21 the entry file
was `main.mjs` and the conventional entry module `Main.beni` emitted `Main.mjs` beside it — the same
file on a case-insensitive system, the shim written second, so `out/Main.mjs` imported itself and
every program built on a Mac died with `SyntaxError: does not provide an export named 'Main$main'`.
31 of 277 `test-blackbox` cases failed there, all of them that.

Two rules make it unreachable, and both are checks rather than conventions.

**Rule 1 — a reserved output name begins with `_`, which no module path can.** A module is named by
its path with `/` for `.` (`language.md` §5), and every segment must be an upper identifier, which
begins with an ASCII capital letter (`SourceStore.isUpperIdent`). A leading `_` is therefore a
region of the name space no module can reach, under case folding or otherwise — unlike a suffix or
a subdirectory, which only moves the collision. The reserved names are:

| Reserved | What it is | Was |
|---|---|---|
| `_main.mjs` | the entry file (§5, `boundary.md` §5.2), unless the platform declares another name | `main.mjs` |
| `_core/` | the `core` package's directory | `core/` |
| `_platform/` | the platform package's directory, holding its modules, their siblings and its runtime | `platform/` |
| `_manifest.txt` | the list of files the last build wrote (*The output directory holds what the last build wrote*) | — |

All three were reachable before: `Main.beni` lands on `Main.mjs`, a user module `Core.List` on
`Core/List.mjs`, `Platform.Node` on `Platform/Node.mjs`. Only the first had been hit.

Inside `_core/`, a `_` name is the emitter's own for the same reason: `_core/_derived.mjs` is the
derived-comparison runtime (§4, *Derived comparisons do not grow the native stack*), which no core
module file (an upper name) can take.

**A platform MAY declare the entry file's name**, which is `boundary.md` §5.2's *"a platform
declares its output shape … rather than hardcoding one"* finished for the one part of the shape that
was still hardcoded: the manifest's `"entry"` key. A declared name is subject to rule 1 and is
checked when the platform is loaded — one path segment, beginning with `_`, ending in `.mjs`, with
ASCII letters, digits, `_` or `-` between. Anything else is `invalid_entry_file`, reported against
the manifest at `1:1` with no excerpt, the shape `foreign_sibling_missing` uses for a fault that is
about a file rather than a place inside one. **Declaring the name is not on its own the fix**: a
platform that declared `main.mjs` would put the defect straight back, which is why the rule is
enforced and not documented.

**Rule 2 — two output paths equal under case folding is a build error.** It is the backstop for
whatever rule 1 does not reach, and one case is not exotic at all: two modules whose paths differ
only by case — `Json.Decode` and `JSON.Decode` — are two modules on Linux and one file on macOS.
Folding is **simple ASCII lower-casing**, nothing more: every module name segment is an ASCII upper
identifier and the compiler's own reserved names are ASCII, so there is no Unicode case folding to
perform and none is performed.

The check runs over the list of files the build is about to write, **after everything is produced
and before the first byte is written**, so a refused build leaves nothing behind exactly as
`boundary.md` §4's checks do. The list is built in module order, which is sorted-path order and
never completion order (CLAUDE.md rule 5), so the pair reported is the same at every `--jobs`. The
diagnostic is `output_path_collision`; it names both output paths and the two files they came from,
because the fault is in neither one alone.

**It is a check of what is WRITTEN, not of what exists**, and that is the one place it differs from
§4. §5's *Elimination decides what is written, never what is checked* is about a contract on
privileged code, which holds whether or not anything imports it; this is a property of the output
tree, so a module the reachability walk dropped cannot collide with anything, because it is not
there. The guarantee is about the artifact, and the artifact is what survived.

**What this costs to test, and why one fixture cannot exist.** A corpus fixture for rule 2's
headline case would need `Json/Decode.beni` and `JSON/Decode.beni` checked into the repository, and
those are one file on the very systems the rule is for — the repository would not survive a
checkout on a Mac. So the collision is provoked two other ways: a platform whose runtime and whose
sibling land on the same output name (constructible everywhere, because the two SOURCE paths differ
by more than case), and a harness invariant that folds the written-file list after every build the
black-box suite makes. The second is the one that would have caught this defect on Linux, where the
file system hides it, and it costs nothing per case (§12).

## 3. `JsIr` — the second IR

§9.2 settles that there are two IRs and not one: lowering the typed IR straight to a byte buffer was
measured as neutral in Elm and loses the ability to pattern-match on generated structure, which is
what the peephole and specialisation passes need.

`JsIr` is a `MultiArrayList` of fixed-size nodes with one `extra: []u32` sidecar and `enum(u32)`
indices, exactly as every other IR here (§5). It is JavaScript-shaped, not beni-shaped: statements
and expressions, `var`/`const` declarations, function expressions, calls, member access, object and
array literals, `switch`, labelled `while`, `return`, conditional expressions. It carries **source
positions from the start** even while maps are off (§9.6), because retrofitting them touches every
pass.

Names in `JsIr` are `Symbol`s, never strings, so renaming in the optimiser is a table swap rather than a
rewrite.

**The backend still sees no types, and static dispatch did not change that.** `Lower.Input` gains
one field beside `interfaces`: a **dispatch table**, one per module, flat and index-based in the
shape of `Bir.refs`, in which the checker has already written what every method call resolved to,
what evidence every declaration takes, and which functions must be derived. The lowerer reads
targets, never types. → [`static-dispatch-spike.md`](static-dispatch-spike.md) §7, §8.0.

**The elimination graph is not `JsIr`'s.** §9's reachability walk runs over `Bir` and the dispatch
table *before* lowering, so an unreachable declaration never becomes `JsIr` nodes at all and `JsIr`
holds only what survives. That is the opposite of §9 item 1, the local dead-binding pass, which is a
use-count walk over `JsIr` after lowering and removes bindings *inside* a declaration that is being
emitted. Two passes, two IRs, and neither is a fallback for the other. `Lower.Input` gains one more
field for it (§9).

## 4. Codegen, construct by construct

Representation decisions are §9.4's and are not reopened here. What this section fixes is the
mapping.

| beni | JavaScript |
|---|---|
| top-level value | one `const` per declaration, module-qualified name in dev, short name in release |
| function of *n* parameters | one function expression of arity *n*; no arity tag (§6) |
| a pattern in an irrefutable position | a fresh name plus a destructuring statement, **with no test** — a parameter, a `let` pattern and a `<-` bound pattern alike. Correct by construction: `language.md` §7 makes all of them irrefutable, the parser refusing the shapes no type can rescue and `checker.md` §6.6 refusing a constructor whose type has more than one, so a pattern that could fail never reaches lowering. A single-constructor type destructures through whichever shape §9.4 gave it — `{$: "Tag", a, b}`, or the bare tag when its one constructor is nullary |
| saturated call at known arity | direct call `f(a, b)` (§6) |
| record | object literal, keys in a canonical sorted order so one hidden class per record type — the sort moves the **keys** and never an initialiser (below) |
| constructor | `{$: tag, a, b}` padded to a uniform shape per type; tag is a string in dev, an integer in release |
| record-alias constructor | the **record literal** it builds, as the record row above: `P 1 "a"` for `type alias P = { x : Int, y : String }` is `{x: 1, y: "a"}`, keys in the canonical sorted order and the arguments evaluated in written order, with no tag — the value IS a `{ x : Int, y : String }` (`language.md` §0, Elm's semantics; the owner's decision that a record alias constructor builds the record, `checker-v2.md` §21). Unapplied or partially applied it is the same wrapper any constructor gets, `(a, b) => ({x: a, y: b})`. As a **pattern** (`nameOf (P n _) = n`) it is irrefutable — one constructor — and reads argument `i` as the alias's field `i` in declaration order, `.x` then `.y`, with no test (decided 2026-09-24 under rule 7). An **imported** alias's constructor is the same record, built and read by the field names interface v3's `record_alias` constructor row carries (`checker-v2.md` §14.2): until 2026-09-25 it was `not_implemented`, because interface v2 had no names |
| nullary constructor | the bare tag — or, for a type that also has a constructor with fields, one module-level constant object per constructor (*A nullary constructor is one object*, below; 2026-09-29) |
| tuple | fixed-shape object per arity, no runtime tag |
| list | cons cells (`{$:1, a, b}` / the empty singleton), pending a benchmark of a vector trie. A literal of more than 32 elements is ONE array whose cells `reduceRight` builds (*Emitted JavaScript nests only as deep as the source*, below) |
| string | native JavaScript string; core's API exposes codepoints where the UTF-16 mismatch would show |
| `Int` | a number |
| `Int32` | **a number too** — an ordinary JavaScript number held in signed 32-bit range by every operation that produces one, with no box and no tag, so `toInt` is the identity and the whole cost of the type is the `\| 0` (ECMA-262's ToInt32) that keeps the invariant true. `mul` is `Math.imul` and `shiftRightZero` is `(x >>> n) \| 0`, because `>>>` answers unsigned. The type exists in beni and not at run time, which is what makes it free; `core/Int32.js` and this row are the contract (`fast-compiler.md` §3.1, `checker.md` Appendix B) |
| `case` | a decision tree (§7) |
| `if` | conditional expression when both arms are expressions, else `if`/`else` |
| `let` | a VALUE binding is a `const` in the enclosing statement list, in written order; a binding whose right-hand side is a **function** is a `function` declaration, which JavaScript **hoists** — every one of them, not only the mutually recursive ones. The hoisting is what makes mutual recursion between `let` functions work, and `language.md` §7's initialisation rule is stated in terms of it: a value may not read a `const` below it, and may read a `function` anywhere |
| string interpolation | template literal |
| `?` | a test and an early `return` of the failure, in statements, over the subject bound once (below) |
| `foreign` | an `import` from the sibling file, one binding per foreign value (`boundary.md` §4). Its **arity is its annotation's**, carried on the declaration's `params` by lowering (`frontend.md` §3.6): the backend reads targets and never types (§3), so a `foreign` in value position eta-expands over that number like any other target |
| method call, resolved to a declaration | a direct call of that declaration, receiver first: `x.m a` is `M$m(x, a)` |
| method call on a `primitive` target | the JavaScript operator the surface origin names — `===` for `==`, and the `Order` result of `compare` tested in place rather than built |
| return-type dispatch | a direct call of whatever the constrained variable resolved to, or of the evidence parameter standing in for it |
| a declaration that carries constraints | hidden **leading** parameters, one per constraint in canonical order, invisible in beni and fixed at every call site by the checker. A top-level declaration's are `$m$<k>`. **A generalised `let` function binding** (2026-09-27, the owner's decision that a constrained `let` function generalises: `checker-v2.md` §8.4, §13.1) takes them too, named `$l<inst>$<k>` after its `let_def` instruction so an inner binding never shadows an outer name it captures: `function inner($l2$0, a, b)`, or its `const` arrow for a `lambda` right-hand side; each use passes its evidence first, a reference in value position is the eta-expansion over the binding's arity, and a lambda inside reads the names by capture. A `let` value binding never takes evidence (the value restriction) |
| a derived `eq` / `compare` | a generated top-level function per type or per structural shape, emitted sorted by printed name |

The last five are static dispatch's, and
[`static-dispatch-spike.md`](static-dispatch-spike.md) §8 and §9 are the contract: §8 for the four
call shapes and the evidence convention, §9 for the exact JavaScript of every derived function.
Nothing here reopens a representation decision — §9.4's shapes are what derivation walks.

### Corrections to the representation

Three rows of that table did not survive contact with the code. Each is a
decision the implementation had to make and §4 did not:

1. **`Basics.Bool` is JavaScript's `true`/`false`.** §4 has no row for it and its general rule —
   a nullary constructor is the bare tag — would make `True` the string `"True"`, so `if` would
   compare strings and `&&` could not be `&&`. The special case is keyed on core's `Basics.Bool`,
   not on a name, so a user's own `type Bool = True | False` is an ordinary ADT.
2. **"Nullary constructor → the bare tag" and "padded to a uniform shape per type" cannot both
   hold**, and §9.4 states both. For `Maybe`, a bare `"Nothing"` beside `{$:"Just",a}` is exactly
   the shape inconsistency §9.4 measures 11% on Firefox for. The backend splits on the TYPE: a type whose
   constructors are *all* nullary is a bare tag string (`Order` is `"LT"`), and a type with any
   argument-taking constructor pads every constructor (`Nothing` is `{$:"Nothing",a:null}`).
3. **`&&` and `||` are lowered here, not at print time.** §9.4 files the primitive peephole under
   optimisation. For these two it is not one: `language.md` §6.5 desugars them into calls of
   `Basics.and`/`Basics.or`, a call evaluates both arguments, and `Basics.and` is `foreign`
   precisely so that it does not. A saturated call of either becomes `&&`/`||`, and when the right
   side needs statements of its own it becomes the `if`/`else` a short circuit really is.
   Arithmetic and comparison stay calls; that peephole really is the optimiser's (§9).

And one thing §4's table is silent on that the emitter had to settle: **where the empty list comes
from.** "cons cells (`{$:1, a, b}` / the empty singleton)" does not say who owns the singleton, and
it cannot be a sibling export because `boundary.md` §4's second check forbids a sibling from
exporting anything that is not a declared `foreign` value. The backend emits `{$:0,a:null,b:null}` inline,
and `core/List.js` and `core/String.js` build the same shape by contract. That contract is the one
piece of the representation that is written down in two places.

Two more rows the table did not state and the backend needed: a **`Char`** is a one-scalar JavaScript string
(§4 says strings are native and core's API exposes code points; a `Char` is the one-character case
of that), and **`()`** is `null`. Neither is contentious; both are recorded because the table did
not say.

**Lists and strings are the two representation questions §14 left open.** The backend ships cons cells and
native strings, which are Elm's answers and the ones pattern matching and interop respectively push
toward. The optimiser benchmarks a 32-way persistent vector trie against cons cells on real idiomatic code, as
open question 2 requires, and records the result here either way.

### A nullary constructor is one object

*Added 2026-09-29* (research 39 §10.3; decided by the project's manager on the owner's delegation).
Correction 2 above pads every constructor of a type that has any constructor with fields, so
`Nothing` is `{$: "Nothing", a: null}` — and until this amendment that literal was written at every
use, so `Run` in a `view` was a new object on every render. A helper call in a hole is skipped only
when its arguments are identical (`language.md` §11.6), so `button "run" Run` was called on every
render and never skipped, and `language.md` §11.12's identity promise bought nothing for the
commonest message there is. **A padded nullary constructor is now one module-level constant per
constructor, in the development build and under `--release` alike**: every use a module writes —
in value position, as a top-level value, as an argument, as a `==` operand that is not tested in
place, as a message in markup — reads the same `const`, so `Run` is `===` `Run` wherever that
module wrote it. Values are immutable, so sharing one is sound; nothing in beni can tell it from a
fresh one except a platform's reference check, which is the point.

- **Where it lives: the module that uses it**, in the synthesised run beside §9.1's comparators —
  `const <Module>$<Ctor> = {$: "<Ctor>", a: null, …};` for a constructor the module declares, and
  `<Module>$<Declaring$Module>$<Ctor>` for one it imports (`Main$Maybe$Nothing`). The constants are
  written in front of the markup hoists and the rest of the run, so a top-level `none = Nothing`
  reads an initialised `const`. The names cannot collide with a declaration (lower-case), a derived
  function (`$$`) or an import (`<Module>$<value>`), and `--release` renames them with every other
  top-level name (§9 item 2).
- **Written only when used.** Like the comparators the constant is *discovered* while a surviving
  body is lowered (§9), so an eliminated declaration's constructors write nothing, and a module that
  builds no padded nullary constructor does not move by a byte. A pattern, a tag test, `?`, and `==`
  tested in place (below) read the tag and never the constant.
- **Per module, not per program**, and deliberately. One object for the whole program would live in
  the declaring module, which a build would then have to write and import for one constant — a file
  for `core/Maybe` in every program that says `Nothing` — and core's siblings build their own
  `Nothing` anyway (`String.toInt`), so a program-wide identity could not be promised. What the
  render loop needs is narrower and holds: **the same expression yields the same object every time
  it runs**, and a value that is not rebuilt keeps its identity (`language.md` §11.12).
- **Not changed**: an all-nullary type is still its bare tag string, which has identity already;
  `Bool` is still `true`/`false`; the empty list is still built at each use (§4's list row, a
  separate representation); a record alias's constructor still builds its record.

Fixtures: `emit/NullaryConstant` (local and imported constants, a top-level use, uses inside
functions), `run/NullaryIdentity/` (`refEq` through a test platform, dev and `--release`, as §15.8's),
`browser/dom/NullaryHelperSkip` (`button "run" Run` called once, at mount).

### A record literal's keys move; its initialisers do not

The sorted key order above is a **representation** decision and `language.md` §6's *Evaluation
order* is a **semantic** one, and where they meet the semantics wins: `{ zed = p, alpha = q }`
emits `{alpha: …, zed: …}` and runs `p` before `q`. So the emitter sorts a permutation of the
fields, lowers the initialisers in the order they are **written**, and binds one to a `const $t$<n>`
before the object literal whenever leaving it in place would move its evaluation. The first backend sorted the
fields and then lowered each one, which ran them in key order; the fixtures are
`run/EvalOrderRecordFields.beni` and `emit/RecordFieldOrder.js`.

**A temporary is bought only where one is needed**, because an unnecessary one is bytes in every
record literal in the program. Two things can move an evaluation, and an **atom** — a literal, a
name, or the `$t$<n>` a `case` has already assigned — is moved by neither, since re-reading one
repeats no work and shows nothing:

| The literal | What is pinned |
|---|---|
| already in key order, no initialiser hoisting statements | nothing: the initialisers stay inside the object literal, byte for byte as before |
| the sort moves the fields, and **at most one** initialiser is not an atom | nothing: one evaluation cannot be reordered against values that are only read |
| the sort moves the fields, and two or more initialisers are not atoms | every non-atom, to a `const` in written order; the object reads the names |
| some initialiser lowers to **statements** (a `case`, an `?`) | every non-atom written before the last such initialiser — its statements run before the object literal is built, so what is written in front of it has to have run already |

The rule is deliberately conservative: it pins by the *shape* of the lowered value and never asks
whether a particular expression could be observed. The same rule holds wherever an emitted order
can differ from a written one, which is why §7's tree rebuilds occurrences rather than re-evaluating
subjects, and why record **update** needed nothing: a spread moves no initialiser.

### `?` is a test and a `return`, and the statements around it

`language.md` §6.6's `e?` yields the payload of an `Ok`/`Just` and returns the `Err`/`Nothing` from
the enclosing function. It is three pieces of JavaScript, and no `case`:

```js
const $t$1 = String$toInt(text);            // the subject, evaluated exactly once
if ($t$1.$ === "Nothing") return $t$1;      // the failure test, and the early return
…$t$1.a…                                    // the value of the expression
```

| Piece | What it is |
|---|---|
| the subject | evaluated **once** (`language.md` §6) and bound to a `$t$<n>`, because the test and the payload both read it. A subject that is already an atom — a name, a literal — is read twice instead and nothing is bound |
| the test | `<subject>.$ === "<failure tag>"` for §4's padded representation, `<subject> === "<failure tag>"` for a bare tag. The failing constructor is `Nothing` for the `Maybe` shape and `Err` for the `Result` one, and its representation is looked up like any other constructor's, from the declaring module's interface |
| **which shape** | the CHECKER's, carried in the dispatch table (`checker.md` §6.5, `static-dispatch-spike.md` §7.1). The emitter sees no types (§3) and a `?` carries no pattern, so this is the one thing about it the backend cannot work out; a `?` with no row is `internal` and stops the build |
| the failure | **the subject itself, returned unchanged.** Nothing is rebuilt and nothing new is named |
| the value | the payload slot, which is slot 0 — `a` — for `Just` and for `Ok` alike |

**Returning the subject is sound because neither failure carries the type that changed.** `?` takes
a `Result e a` inside a function answering `Result e b`: an `Err` holds an `e` and never an `a`, so
the object that came in is already the object that goes out, and re-wrapping it would allocate a
second one with the same two fields. `Maybe a` to `Maybe b` is the same argument with an empty
hand: §4's padding makes `Nothing` a `{$:"Nothing",a:null}` whatever `a` was. This is also what
keeps §9 honest — the failure path names no declaration, imports nothing and adds no edge, so a
`?` cannot keep anything alive.

**The `return` is the enclosing function's, wherever the statement lands.** `language.md` §6.6 says
a `?` returns from the nearest enclosing *definition with parameters* and makes a lambda in between
`question_in_lambda`, so there is no case where the beni answer and the JavaScript answer could
differ: a `let` definition with parameters is its own emitted `function` (§8's cases table), a
parameterless `let` binding is a `const` in the enclosing one, and a lambda cannot be reached. A
`return` inside §7's labelled block or `switch` leaves the function and not the block — that is
what distinguishes it from a leaf's `break $c$<d>`, which is how a leaf delivers the `case`'s own
value — and inside §8's `while (true)` it leaves the loop with the function.

**Everything written before a `?` must have run before it.** The early `return` is a statement, so
it runs where the statements go, ahead of the expression it was written inside; an expression
written to its left that is still sitting in that expression would run *after* it, or — if the `?`
fails — not at all. This is the record literal's rule above, generalised: **a run of
sub-expressions in written order pins to a `const` every non-atomic value written before the last
one that hoists statements.** It applies to every position that holds more than one written
expression — a call's arguments *together with its callee*, a method call's receiver and
arguments, a constructor's arguments, a list, a tuple, an interpolation's segments, a record
literal's initialisers, a record update's base and fields — and it is the same machinery, so a
`case` in the same position was fixed by the same change. Short-circuit `&&`/`||` need nothing
extra: correction 3 above already gives the right operand its own branch, and statements hoisted
there run only when it does.

Two consequences worth stating, because they are what the emitted shape looks like:

- **In a `case` (§7)**, a `?` in a branch body hoists into *that branch* and nowhere else, so the
  other branch does not run its test; a `?` in the scrutinee hoists before the tree, once. A leaf
  that hoists statements is why the conditional-expression shape is chosen only after the bodies
  are lowered: `a ? b : c` cannot hold a `return`, and the tree falls back to the statement form.
- **In a looping function (§8)**, a `?` in a **tail-call argument** is not in tail position — the
  operand of a `?` never is — so it is evaluated with the other arguments, before any parameter is
  rebound, and its failure returns out of the loop rather than continuing it.

### Emitted JavaScript nests only as deep as the source

*Added 2026-09-25.* Every JavaScript engine parses — and V8 and JavaScriptCore
compile — a nested expression or block by recursion, and gives up with `RangeError` or
`InternalError` past a depth that depends on the construct and the engine. Before this section a
program the compiler accepted could lower to a module no engine would load: a list literal was one
object per element each inside the last, `a + b + …` one `Basics$add` call per term, `++` and `::`
the same, and `&&` printed as `a && (b && …)`. `build` exited 0 and the module threw while it was
being parsed — from about 1 550 levels in Node, 1 290 in Chrome, 860 in the SpiderMonkey shell. The
parser's own budget (`language.md` §10, 4 096 charges a declaration) sits above every one of those
numbers, and does not charge a list's elements at all.

The rule is two halves. **A form the source writes FLAT is emitted flat, however long it is**: its
nesting in JavaScript may not grow with its length. **Nesting the source writes itself is carried
into JavaScript up to a budget the engines can load, and refused by name past it** — which, since
everything flat is flat, is only ever functions and `case`s nested inside one another scores deep.

**What the engines load, measured.** Each figure is the deepest (or widest) the engine loads and
runs, found by a binary search to 1 % over generated modules: `import()` of a `blob:` URL in the
three browsers (headless, Linux x86-64), a `data:` URL in Node, `new Function` in the two shells,
2026-09-25. `≥` is the top of the search. The browser figures are what a page gets; the shells are
the engines alone, and the SpiderMonkey shell runs on a smaller stack than Firefox does.

| Construct, one level | Chrome 153 | Firefox 144 | WebKit (WPE, Safari 605.1.15) | Node 24.19 | SpiderMonkey 140 shell | Bun 1.3.13 (JSC) |
|---|---|---|---|---|---|---|
| call `f(f(…))` | 1 308 | 1 474 | 3 616 | 1 547 | 933 | 2 865 |
| object `{ $: 1, a: 1, b: {…} }` | 1 610 | 1 263 | 3 158 | 1 547 | 860 | 2 920 |
| `x && (x && …)` | 1 006 | 1 437 | 3 323 | 1 510 | 897 | 3 121 |
| alternate `c ? 0 : c ? 0 : …` | ≥ 300 000 | 4 147 | 6 563 | ≥ 300 000 | 2 151 | 6 710 |
| consequent `c ? (c ? … : 0) : 0` | 1 281 | 4 147 | 6 563 | 1 876 | 2 151 | 6 710 |
| `if (c) { return 0; } else { … }` | 644 | 1 931 | 3 964 | 1 519 | 759 | 2 297 |
| `if (c) { … } else if (c) …` | 1 290 | ≥ 300 000 | 35 750 | 3 891 | ≥ 300 000 | 32 234 |
| `switch (k) { case 0: { … } }` | 595 | 726 | 3 707 | 1 024 | 358 | 1 913 |
| `{ … }` | 1 308 | 3 525 | 7 626 | 2 480 | 1 235 | 3 488 |
| `{ let a = 1; … }` | 1 290 | **251** | 7 626 | 2 499 | **251** | — |
| `(() => …)()` | 553 | 497 | 2 151 | 558 | 438 | 1 986 |
| `((x) => …)(1)` | 553 | 411 | 2 151 | 558 | 440 | — |
| `() => { let a = 1; return … }` | 502 | **171** | 2 590 | — | 580 | — |
| flat `x && x && …`, terms | ≥ 300 000 | ≥ 300 000 | 53 620 | ≥ 300 000 | ≥ 300 000 | 53 620 |
| flat `x + x + …`, terms | ≥ 300 000 | ≥ 300 000 | 40 144 | ≥ 300 000 | ≥ 300 000 | 29 304 |
| array literal, elements | ≥ 300 000 | ≥ 300 000 | ≥ 300 000 | ≥ 300 000 | ≥ 300 000 | ≥ 300 000 |
| arguments of one call = parameters | 59 610 | 65 078 | ≥ 70 000 | 59 610 | 65 078 | ≥ 70 000 |
| `case`s of one `switch` | ≥ 300 000 | 65 046 | ≥ 300 000 | ≥ 300 000 | 65 046 | ≥ 300 000 |

Three things in that table decide the design. **There are two limits, not one.** Every engine runs
out of stack, at a depth that depends on the construct; SpiderMonkey also refuses a 252nd nested
scope — braces that declare something, or a function — with "function nested too deeply", in the
shell and in Firefox alike, **whatever stack is left**. In a module a function with a declaring body
reaches it at 171. **The scarcest browser is not one browser**: Chrome for calls, `if` blocks and
`switch`, Firefox for objects, arrows and scopes. **A flat chain is not free in JavaScriptCore**,
which nests `a && b && c` where V8 builds one n-ary node and SpiderMonkey loops; it still loads
53 620 terms. Mobile builds of these engines were not measured, and their stacks may be smaller —
the margins below are the answer to that, not a measurement of it.

**The unit and the budgets** (`JsIr.nesting`, `JsIr.Builder.measure`). A path from a declaration
down to a leaf costs the sum of what each construct on it costs; the unit is a quarter of a nested
call, so that the scarcest browser's call depth, Chrome's 1 290, is 5 160 units, and every weight is
5 160 over the scarcest browser-or-Node depth of its construct, rounded up:

| Weight | Units | Scarcest depth |
|---|---|---|
| call — callee and each argument | 4 | Chrome, 1 290 |
| object literal — each property's value | 5 | Firefox, 1 263 |
| array literal | 4 | — |
| member, index, unary, template hole | 2 | not measured; never deeper than the source |
| binary operand; a left operand only when it is not the same-precedence chain | 6 | Chrome, 1 006 with parentheses |
| left operand of a same-precedence chain, printed without parentheses | 0 | V8 and SpiderMonkey: none |
| conditional test and consequent | 5 | Chrome, 1 281 |
| conditional alternate | 2 | Firefox, 4 147 |
| function body (`=>`, `function`) | 7 | Firefox, 497 as `(() => …)()`, with the call's 4 |
| `if` and its braces | 9 | Chrome, 644 |
| `{ … }` | 4 | Chrome, 1 290 |
| `switch`, before its case's braces | 5 | Chrome, 595 with the braces |
| `while (true) { … }` | 9 | as `if` |
| any other statement | 1 | — |

Every top-level declaration may cost at most **2 048 units** (`nesting.budget`: 512 nested calls,
two and a half times under the browsers' edge and one and a half under the SpiderMonkey shell's)
and nest at most **128 scopes** (`nesting.scope_budget`: half of SpiderMonkey's 251). A function is
one scope and braces that declare something one more.

**The shapes.** Each long form, and what it is now. Every `run/`, `emit/` and `emit/release/` golden
of the corpus was byte-identical; the emitted JavaScript itself moved in two ways, stdout
identical everywhere. `&&`/`||` of three terms or more prints flat at any length (`_core/Char.mjs`'s
`isHexDigit` and `isAlphaNum`), and a list literal past 32 elements is an array (`run/CharOps`,
`CoreCharRest`, `CoreMaybeResultRest`, `CoreNumericExtremes`, `CoreStringRest`, `Int32Bits` and
`ReleaseEverything`); the goldens hold because they are stdout, or the fixture's own module.

| Form | Was | Is |
|---|---|---|
| list literal, up to 32 elements | nested cells | unchanged |
| list literal, 33 or more (`max_cons_elements`) | one nested object per element | `[e1, e2, …].reduceRight(($l, $h) => ({ $: 1, a: $h, b: $l }), { $: 0, a: null, b: null })` |
| `&&` / `\|\|` chain | `a && (b && (c && d))` | `a && b && c && d`, one run |
| `&&` / `\|\|` chain whose operands need statements | `let $t; if (a) { …; $t = b && …; } else { $t = false; }`, one more `if` inside for each such operand | `let $t = a; if ($t) { …b's statements; $t = b; } if ($t) { …; $t = c; }` — one flat `if` per such operand (`if (!$t)` for `\|\|`), the operands without statements riding in the assignment before them |
| a lambda whose body is 128 units tall (`lambda_spill`) | the closure inline, where it is an argument | the closure bound to `const $t$<n>` where it is made, so the call it is an argument of nests none of it |
| derived `==` over a record or payload | `$m$0(…) && $m$1(…) && …`, one run | the same, in runs of 1 024 terms joined as `… && (…) && (…)` (`derived_group`), so JavaScriptCore nests at most 1 024 and the number of runs |
| `+ - * / ++ :: \|> <\|`, nested calls, records, tuples, constructors | one call or object per level | the same until the expression is `nesting.spill` tall (256 units, 51 to 64 levels), then that much is bound to `const $t$<n>` in front of it, and the chain goes on from the name |
| `else if` chain in a function's result, 16 `if`s or more (`chain_min`) | one `if`/`else` inside the last | `if (a) { return …; }` then the next test, one after another |
| `else if` chain in an expression, 16 `if`s or more | one `let $t$<n>` and `if`/`else` inside the last | one `$c$<d>: { … }` block and one temporary: `if (a) { $t = …; break $c$<d>; }`, one after another |
| `if`s each in the `then` branch of the one before, 16 or more, either position | the same, nested the other way | the same, flat, each test negated so that the short `else` is inside and the chain follows: `if (x.$ !== "Just") { return 0; }` |
| evidence for a type nested *n* deep | one closure per level, `(x, y) => List$eq((x, y) => …, x, y)` | a closure 20 levels deep (`evidence_spill`) is bound to a `const` ahead of the call |
| string interpolation, record literal, `case` of literals | flat already | unchanged |

**Why none of this moves an evaluation** (`language.md` §6 is normative). A spilled `const` goes
where a `case` or a `?` in the same position would put its statements — `Lower.expr`'s `out`, the
statement list in front of the expression — so it runs exactly where the value would have been
evaluated, and every caller that holds a run of written-order values already pins the ones written
before a hoist (`orderedExprs`, *`?` is a test and a `return`* above). A branch of a short circuit or
of a `case` has an `out` of its own, so a spill never runs anything the source would not have. A
flat list's elements are an array literal's, evaluated left to right as the nested cells' were, and
its cells are the same `{$, a, b}` in the same key order, so they share the cons cell's hidden class
(§9.4). `&&` and `||` are associative in value and in evaluation — the first falsy (truthy) operand
decides and nothing after it runs — so `a && (b && c)` and `a && b && c` are one program; an operand
that needs statements runs them only inside `if ($t)`, which holds exactly when every operand before
it said so, so nothing runs that the nested form would not have run. A flat `else if` chain works
because every arm leaves — a `return` in tail position, a `break` out of the chain's block in an
expression — so what followed the `else` inside it may follow the `if` instead. An evidence closure
is hoisted only when it is an arrow: making a closure runs nothing, where the evidence applied to a
constant (A.85) is a call and stays where it is. For the same reason a hoist that is nothing but
`const`s of closures — evidence, or a lambda bound where it is made — pins nothing written before it
(`onlyClosures`): the values in front stay inline and still run first. `run/NestingFlatList.beni`, `NestingChains.beni`,
`NestingElseIf.beni`, `NestingEvidence.beni` and `NestingLogicalStatements.beni` log every operand,
and `ViewMap20x30`, `ViewMap40x12` and `ViewMapEvery3` are TEA-style `view`s with a `List.map` lambda
at every level or every third; each was confirmed against its
oracle twin, the same program built by the compiler before this section. `emit/NestingShapes.beni` holds the shapes.

**How the lowering knows.** Cheaply, where it decides, and exactly where it refuses:

- `Lower.expr` keeps a running maximum, `expr_height`, of the expressions lowered inside the one it
  is lowering, and adds the instruction's own weight: one addition per expression, no walk. A
  `let`'s bindings are statements and do not count toward it, and a value that came back an atom
  counts nothing. A lambda's body DOES count: it nests inside whatever the lambda is an argument of
  (a review found a `view` of twenty `List.map`s refused), and once it is
  `lambda_spill` tall the closure is bound where it is made. Evidence keeps its own count, in
  closures.
- A chain is counted by following, from each `case`, the last branch whose body is another `case`
  under any `let`s (`leafCaseDepth`), up to `chain_min`. Of the two branches of each test, the one
  with more nodes follows the `if`.
- `refuseTooDeep` measures each top-level declaration's statements exactly, by one walk over an
  explicit stack (`JsIr.Builder.measure`), and only when the declaration built at least
  `nesting.could_exceed` nodes — 128, fewer than which no statement can be over either budget.

**What is refused, and why a refusal is right there.** A declaration over either budget is
`nesting_too_deep` (`language.md` §10), naming the declaration, both measures and both limits, and
nothing is written. After everything above, only nesting the program writes itself can get there:
120 functions each applied inside the last, a TEA `view` with a `List.map` lambda at every level 65
to 69 levels deep (at 30 and at 12 children a level), or about 150 `case`s or `if`s each inside an
ARGUMENT of a call inside the one before — `f (if b then f (if b then … else 0) else 0)` — where no
branch is left for the next test to follow. Every lambda costs a scope, and one bound where it is
made makes its enclosing body declare something, a second; 128 scopes is what bounds these. CLAUDE.md rule 7 allows a refusal only where the guarantee at stake — no
runtime exception — has no correct emission to keep it, and for these there is none short of a
different compiler: a function scope is how JavaScript closes over its variables, and taking one
out means closure conversion, every captured variable moved into an environment object; a `case`
inside an argument has to be finished before the call it is an argument of, and taking its blocks
out means turning expressions into a jump-threaded statement machine. Either reshapes every
program's output to rescue source nobody writes, and the parser already refuses nesting past 4 096
on the same principle. The budgets sit two and a half times under the scarcest browser, so the
refusal comes well before any engine's edge and not at it. What must never happen, and does not,
is a flat form refused. `abuse_test.zig` holds the edge: 119 nested functions run, 120 are refused.

**The wide form, measured in browsers** (`static-dispatch-spike.md` §9.2, A.87). A function of *n*
parameters called with *n* arguments loads and runs up to 59 610 in Chrome and Node, 65 078 in
Firefox and the SpiderMonkey shell, and past 70 000 in WebKit and Bun. `Convention.max_positional_evidence`
stays at 4 096, fourteen times under the scarcest for ONE call. Under recursion the frames add up
(Node, default stack, a self-recursive arrow with *n* extra parameters): 16
extra parameters recurse 2 928 deep, 256 recurse 237, 1 024 recurse 59 and 4 096 only 13. So a
recursive nominal type whose payload has exactly 4 096 fields — the positional form — overflows
`==` about 13 levels down, where 4 097 fields — the array form — does not. No program the corpus
knows is near it; the caveat is recorded in `static-dispatch-spike.md` §9.2 and A.87. *Since 2026-09-27
neither overflows at any depth (*Derived comparisons do not grow the native stack*, below).*

**Cost.** Emit, ReleaseFast `zig build bench -- --generate=100000`, medians of seven interleaved
runs, four sets: +1.9 %, +0.4 %, and after the review's fixes 52.64 against 51.77 (+1.7 %) and 52.70
against 52.84 (−0.3 %); the review measured +2.9 %. It is noise-bound around +1 %, inside the ±3 %.
The bench program's JavaScript is 4 bytes shorter. Output size (`bench/size.mjs`): `bench/corpus` 128 437 → 128 431 bytes raw, 22 478 → 22 483
brotli, release 15 651 → 15 643 brotli; the `emit/` corpus unchanged; across `run/`, a program with a
long list literal is 500–900 bytes smaller raw and within ±12 bytes brotli, since nested cells
compress very well.

**Known gaps.** A `case` of more than 65 046 literal branches was one `switch` SpiderMonkey refuses;
*closed 2026-09-27:* a fan of more than 16 384 labels is consecutive `switch`es
(§7, *The emitted shape*). Mobile engines are unmeasured. A lambda applied on the spot, `(\x -> …) a`, costs a
function scope where a `let` would cost none; lowering it as the `let` it means would lift the
120-function edge. Evidence nested inside a deep expression is counted by the
exact measure and not by the cheap one, so it can be refused where binding more of it would have
loaded.

**Schema declarations** additionally produce an inspectable description and
ordinary specialised top-level parse/print functions, with both success and
failure paths compiled. [`schema.md`](schema.md) §6 owns their emitted shapes,
static/dynamic boundary, resolved-plan input and independent §9 reachability;
§5 owns the context contract shared with the library interpreter. This is a
specified fork, not implemented code or an effects-runtime decision.

### Derived comparisons do not grow the native stack

*Added 2026-09-27; the owner's decision of 2026-09-26. Reshaped the same
day: tail self-calls loop, forwarders, one shared runtime.* **A derived `eq` or `compare` never
throws on deep data** — unless the recursion runs THROUGH a hand-written method (*What it does not
cover*, below). Until then every derived function ([`static-dispatch-spike.md`](static-dispatch-spike.md)
§9) called the comparison of each position on the native stack, so a comparison was as deep as the
data: under Node's default stack a user linked list `type L = Cons Int L | Nil` threw `RangeError`
on `==` at 8 940 cells and on `<` at 10 000, and a nested record literal at 3 747 of the 4 095
levels the parser accepts. The rule is Elm's (`_Utils_eqHelp`): **recurse on the native stack to a
depth limit, then continue from an explicit stack**, so native stack use is bounded whatever the
data, and the only limit left is the heap. Four shapes make it, from cheapest to dearest.

**1. A tail self-call is a loop.** A position that is the LAST of its constructor and
compares the function's own type with the function's own evidence, unchanged — `Cons Int L`'s `L`,
a tree's right child — does not call: the arm tests what came before it and continues a
`while (true)` around the body with `$x = $x.b; $y = $y.b;`. The same comparisons in the same order,
on no new frame (`Lower.selfLoopParts`). Polymorphic recursion, which changes the evidence, calls.

```js
const M$L$$eq = ($x, $y) => {
  while (true) {
    if ($x.$ !== $y.$) {
      return false;
    }
    switch ($x.$) {
      case "Cons":
        if ($x.a !== $y.a) {
          return false;
        }
        $x = $x.b;
        $y = $y.b;
        continue;
      default:
        return true;
    }
  }
};
```

**2. Leaves are what they always were.** A derived row is a LEAF when nothing it calls can come
back to a derived function (`Lower.leafRows`): a record, tuple or `()` whose every use in the module
hands it only primitive comparators and hand-written methods as evidence, and a nominal type whose
every position is a primitive, a hand-written method, a call of another leaf of the module (at most
16 calls deep), or a tail self-call, which loops. A position that is the type's own parameter,
another module's derived function or `List`'s `eq` is not, because what it runs is decided
elsewhere. A leaf takes no depth: `{ x : Int, y : Int }`, `type Shape = Circle Point Float | …` and
— with the loop — every list-like type are emitted with no parameter, check, twin or runtime import.
A leaf called by another row is called plainly. **A hand-written method counts as flat** even when
it is handed a derived function as evidence, so a type that recurses only THROUGH one is classed a
leaf (below).

**3. The depth.** A derived function that can recurse takes one more parameter after the two values,
`$d = 0`, and hands `$d + w` to every comparison it calls that takes one: its own evidence
(`$m$k(l, r, $d + 1)`), another derived function, and `List`'s `eq` and `compare` — which derived
code calls as the runtime's `listEq` and `listCompare`, loops that hand the depth to every element
unchanged (one frame, not a level). `w` is 1, plus one per 32 of the function's evidence parameters
(counted twice, since a caller pushes them too) and positions (one `const $o$<i>` each in a
`compare`), so a frame of thousands of parameters spends the budget in a few levels
(`derived_weight_per`). An evidence closure around such a callee forwards a third argument,
`(a, b, c) => F(ev, a, b, c)`; a user site and every hand-written caller pass two, and the default
makes that depth 0. `core/List.js` is untouched: a user's own `List.eq` takes no depth.

**The limit** is `derived_depth_limit`, **400** units. A unit costs 300–450 bytes of Node's stack
(a list, a record through `Maybe`, a rose tree through `List`), so 400 of them are 120–180 kB of
Node's 984 kB default; measured as the user recursion a page may already be in when it asks for a
100 000-cell comparison, the comparison costs 3.5–8.3 % of Chrome's stack and 2.2–5.9 % of
Firefox's (the table below).

**A FORWARDER** is a function whose every depth-taking call is in tail position: `Maybe`,
`Result`, a one-field wrapper, a record of one field, `type Rose = Rose Int (List Rose)`. It has no
prologue and no steps. Its tail call checks the limit itself:

```js
const Maybe$Maybe$$eq = ($m$0, $x, $y, $d = 0) => {
  …
    case "Just":
      return $d > 400 ? _derived$deep([$m$0, $x.a, $y.a], $d) : $m$0($x.a, $y.a, $d + 1);
  …
};
```

Past the limit — or given the REQUEST depth, which is past every limit — the call becomes a
request, `[f, args…]`, that the engine makes on its explicit stack; so a chain of forwarders as
deep as a TYPE (`Just (Just (…))` 4 095 deep, 50 wrappers a level) grows the native stack no more
than any other derived function does.

**4. Steps.** A function with a depth-taking call in a non-tail position (a tree's left child, a
record's first field) has a prologue and a twin:

```js
const M$Tree$$eq = ($x, $y, $d = 0) => {
  if ($d > 400) {
    return _derived$deep(M$Tree$$eq$$steps($x, $y), $d);
  }
  while (true) {
    … if (!M$Tree$$eq($x.a, $y.a, $d + 1)) { return false; } …
    $x = $x.c; $y = $y.c; continue;
  }
};
```

The twin, `function* <base>$$steps(…)`, is the same statements with every depth-taking call given
the REQUEST, `2**30`, instead of `$d + w`. A callee given the request that cannot recurse — a
primitive comparator, a hand-written method, a leaf — ignores it and answers; one that can hands
back its steps, unstarted, or a forwarder its request, without comparing anything. A non-tail
position is `$e = f(…, 2**30); if (typeof $e === "object") { $e = yield $e; }` and the test of §9's
shape after it (`if (!$e) return false;`, `if ($e !== "EQ") return $e;`). A tail position is
returned as it is, and a looping arm loops inside the generator too. The twin keeps no `const` per
position — one `$e`, and `compare$char` (§9.1) instead of two bound code points — and takes more
than 16 evidence parameters as one array and calls with more than 16 arguments through `apply`: a
generator saves its whole frame at every `yield`, so a frame of 4 096 registers made every
suspension, and V8's code for it, that big (a 4 096-parameter type, measured: 65 s and a JIT
out-of-memory abort before, 2.4 s after).

**The runtime** is ONE file a build writes, `_core/_derived.mjs` (§2's rule 1: a `_` name in
`_core/`, which no module file can take), iff a module it wrote imports from it — the use-driven
import is what roots it. It is the compiler's own JavaScript (`src/js/derived_runtime.mjs`, a
compact copy under `--release`), exporting `deep`, `listEq` and `listCompare` by fixed names that
importers bind under `_derived$<name>` (`import { deep as _derived$deep } from "./_core/_derived.mjs"`),
as they bind a sibling's, so `--release` renames only the local side:

```js
const request = 2 ** 30;
export const deep = (g, d) => {
  if (d >= request) return g;          // a request: hand it back
  const waiting = [];
  let t = g;
  let v;
  while (true) {
    if (typeof t === "object") {
      if (t.next === undefined) {      // a forwarder's [f, args…]
        const f = t.shift();
        t.push(request);
        t = f.apply(null, t);
        continue;
      }
      const n = t.next(v);             // steps
      v = n.value;
      if (typeof v === "object") {     // yielded: t waits; returned: it answers for t
        if (!n.done) waiting.push(t);
        t = v;
        continue;
      }
    } else {
      v = t;                           // an answer
    }
    if (waiting.length === 0) return v;
    t = waiting.pop();
  }
};
```

What the engine is handed, and what a request answers with, is an answer — a `Bool`, or an `Order`,
a bare tag string, never an object — steps (a generator) or a forwarder's request (an array); so
`typeof` and `next` are the whole protocol. A depth at or past `2**30` is a request, so a forwarder
that adds its weight to it still asks. A returned steps object or request REPLACES its caller on the
explicit stack, so a tail position costs it nothing. The engine holds no state between calls: an
exception from a hand-written method leaves nothing behind.

**Order is exact.** Loops, forwarders and steps make the same calls as the recursive functions of
§9, in the same order, and stop at the same position — the first `False`, the first order that is
not `EQ` — so a `Debug.log` in a hand-written method prints the same lines, in the same order,
below and past the limit (`run/DerivedDeepOrder`; a differential fuzz against the recursive build, below). No
position is deferred: Elm's `_Utils_eqHelp` defers the rest of an `==` and answers `True`
optimistically, which is exact only for a pure structural walk, and an order has no optimistic
answer at all.

**What it does not cover: recursion through a hand-written method.** A hand-written `eq` or
`compare` is a function like any other. It takes no depth and cannot hand back steps, so when a
type's recursion passes THROUGH one, every level is native frames again, and deep data throws:

```elm
-- Box.beni: written by hand
pub eq : Box a, Box a -> Bool
    where a.eq : a, a -> Bool

-- Main.beni
type T = T (Box T) | E    -- `build 100000 E == build 100000 E` throws RangeError
```

Each level is `T$$eq → Box$eq → T$$eq`, and `T` is a leaf (`Box.eq` is flat), so it has no depth
at all. Lifting this needs the hand-written method's cooperation — steps of its own, or a compiler
that writes it — and is not attempted. `abuse_test.zig` pins today's behaviour (100 levels compare,
100 000 throw), so the day it changes the scenario flips with the spec.

**Measured** (library builds before and after the depth limit, one page of `==` and `<` on a user list, a
record nested through `Maybe` and a rose tree through `List`, 2026-09-27; headless Chrome 153,
Firefox 144, WebKit WPE 605.1.15, Node 24.19). The later loops and forwarders change none of the paths past the limit but the
list's, which no longer reaches it:

| | Chrome | Firefox | WebKit | Node |
|---|---|---|---|---|
| before: deepest user-list `==` | 13 468 | 23 598 | ≥ 400 000 | 10 253 |
| before: record through `Maybe`, rose tree through `List`, 10⁵ deep | `RangeError` | `InternalError` | `RangeError` | `RangeError` |
| after: list `==` / `<`, 10⁶ cells | 70 / 43 ms | 287 / 330 ms | 89 / 97 ms | 67 / 47 ms |
| after: list `==` / `<`, 3 × 10⁶ cells | 144 / 131 ms | 574 / 776 ms | 251 / 235 ms | 361 / 141 ms |
| after: record through `Maybe` `==`, 10⁶ | 279 ms | 1 494 ms | 506 ms | 359 ms |
| after: rose tree `<`, 10⁶ | 200 ms | 781 ms | 483 ms | 208 ms |
| after: share of the stack a 10⁵ comparison needs (list, record, rose) | 4.2 / 3.5 / 8.3 % | 2.2 / 4.7 / 5.9 % | noise | noise |

Node also compares two 10⁷-cell lists and two 2 × 10⁶-deep rose trees: the limit is the heap. The
last row is how much less deep a user recursion may already be when it asks for the comparison than
when it asks for a function that returns at once; JavaScriptCore and Node re-tier the probe between
runs, so their figure is noise around zero.

**Cost, run time** (Node 24.19, library builds, each case its own process, the median of nine
processes each reporting the median of nine samples, ns per comparison):

| case | before | depth limit only | as built | as built vs before |
|---|---|---|---|---|
| user list `==`, 8 cells | 40.97 | 44.85 | 18.98 | −54 % |
| user list `<`, 8 cells | 43.16 | 47.87 | 21.36 | −51 % |
| user list `==`, 300 cells | 1 659 | 1 729 | 649 | −61 % |
| tree `==`, depth 4 | 136.8 | 162.1 | 121.0 | −12 % |
| tree `<`, depth 4 | 141.6 | 165.9 | 120.8 | −15 % |
| tree `==`, depth 10 | 10 557 | 12 557 | 9 400 | −11 % |
| `Maybe Tree` `==`, depth 4 | 141.1 | 165.7 | 122.2 | −13 % |
| `Maybe Int` `==` | 3.89 | 3.84 | 3.85 | −1 % |
| rose tree through `List` `==`, depth 6 | 914.7 | 976.0 | 947.0 | +3.5 % |
| `List Point` `==`, 200 | 896.0 | 933.8 | 919.4 | +2.6 % |
| `List Shape` `==`, 200 | 1 804 | 1 760 | 1 762 | −2.3 % |

The loop is what turns a list and a tree's right spine faster than before: no call at all. The
two rows over the baseline are at the noise floor: `List Point`'s emitted code is byte for byte
the baseline's (the element is a leaf, the list `core/List.js`'s), and the same build measured in
other rounds swung by ±3 %; the rose tree is a genuine cycle through `List` and pays the depth
parameter and the forwarder's check, about 0.25 ns a node. Past the limit a level costs a
generator and a `next` — roughly 5–10 times a native call, and only where the native stack would
otherwise have run out.


**Cost, size** (`bench/size.mjs`, 164 programs, before → depth limit only → as built): release brotli 760 628 →
780 672 → 769 250 (+1.1 % on the baseline, −1.5 % on the depth limit alone); development raw +2.6 % and −0.8 %. 144 of
the 164 programs are byte for byte the baseline's (with the depth limit alone: 88): list-like types are leaves again,
`core/List.js` is the baseline's, and a program's derived code reaches the one runtime file only when
something can recurse. `run/Dictionaries` is the baseline's exactly (6 479). What grows with the
program is a twin per function with a non-tail depth-taking call and the runtime file, about
900 bytes under `--release`; `bench/corpus`, a library build that roots every type's methods, is
15 643 → 16 754 → 16 458 release brotli (+5.2 % on the baseline). Emit, ReleaseFast `zig build bench
-- --generate=100000`, seven interleaved pairs against the baseline: median 53.15 → 52.79 ms (−0.7 %).


**Fixtures.** `run/DerivedDeepData` (the exit criterion: two 100 000-cell user lists, `==` and `<`,
equal and unequal; a record nested 10 000 deep through `Maybe`; red before, `RangeError`),
`run/DerivedDeepPaths` (the depth through `List`, through a second type and a tuple, through a
parametric type's own evidence; 100 000 deep; red before), `run/DerivedDeepOrder` (evaluation order
and short-circuiting past the limit, through a hand-written method with `Debug.log`; red before, and
a 5 000-deep variant, which the recursive build survives, prints byte-identical output on both),
`run/DerivedDeepAcrossModules/` (a cycle through another user module's parametric type, 100 000
deep; red before), and three abuse scenarios in `abuse_test.zig`: a recursive type of 4 096
(positional) and one of 4 097 (array) parameters, recursing in their FIRST position so the
comparison does not loop, compared just past the limit — 20 levels, which threw `RangeError` with
a charge of one unit a call, and 5 levels, the first that reaches the engine in the array form;
and the exclusion above (100 levels through a hand-written `Box.eq` compare, 100 000 throw). The
fixtures above already fail when the prologue, a forwarder's check or charge, or an evidence
closure's depth is taken out, so the record literal nested 4 095 deep and the chains of forwarders
nested as deep as a type that used to be scenarios here are not repeated. Every `run/`
fixture is also built and run with `--release`. The emitted shapes are pinned by
`emit/DerivedEqNominal`, `emit/DerivedCompareNominal` and `emit/MatchNested`.

**Compact printing**: under `--release` an `if` with no `else` whose one live statement is
a `return`, `continue`, `break`, `throw`, assignment or expression statement drops its braces,
`if(c)return a;`; never a declaration (no legal `if` body) and never an `if` (a dangling `else`
would change owner). The request prints `2**30`.

### `==` against a constructor is a tag and field test

*Added 2026-09-29* (research 39 §4.2, §7 question 2). `model.selected == Just row.id` called the
derived `Maybe` equality on a `Just` built for the comparison — an allocation and a call per row of
a table on every selection. When one operand of `==` or `/=` is a constructor application of a
`tagged` type (`{$: tag, …}`) and the operator's target is a **derived** `eq` (never a hand-written
one, never a primitive), the emitter writes what the derived function computes, in place: the tag,
then each field in declaration order, `a.$ === "Just" && a.a === id`, and `/=` its negation. Nothing
is built and nothing is called. **It is the derived function's answer exactly**, because a field is
tested in place only where the derived function's own test there is `===`:

- a field whose `eq` resolves to `primitive strict_eq` — through the type's derived row for a type
  of this module, through the constructor's interface argument terms and the published context for
  another module's (`Maybe`, `Result`) — is `a.f === e`;
- a field whose `eq` is itself derived and whose operand is a constructor application is the same
  test, one level down (`x == Just (Just 3)`);
- anything else — a `List` field, a field of a type with a hand-written `eq`, a derived field whose
  operand is not a constructor, a record-alias constructor — keeps the whole comparison as the call.

**Evaluation is unchanged** (`language.md` §6): the operands are evaluated once, in written order,
before any test, and one that is not a read (a name, or a field chain of one) is bound to a `const`
first, so a tag that differs skips no evaluation. The other side is read once per test, which is
why it must be a read. Pinned by `emit/EqAgainstConstructor` (the shape) and
`run/EqAgainstConstructor` (the answers, nested, `Nothing`, both sides, a `List` field, and
`Debug.log` order when the tags agree and when they differ).

*Amended 2026-09-30 (research 41 §3):* **reachability asks the same question, and a site tested in
place is not an edge.** §9's third leg followed every dispatch site's callee, so the derived `eq`
an in-place `==` resolves to — and, for `Maybe`'s, the comparison engine `_core/_derived.mjs` it
imports — shipped although nothing called it: 339 of the benchmark app's 6 195 brotli bytes. The
decision is one function, `src/js/CtorEq.zig`, which `Lower.ctorEquality` and `Reach` both call,
because a disagreement is either dead code shipped or a `ReferenceError` at load. `Edges.declEdges`
takes an optional site filter for it; `Cycles` passes none, since an extra edge there only orders a
declaration earlier. Pinned by `emit/app/DceEqAgainstConstructor` (no `Shape$$eq`, and
`_core/_derived.mjs` not written); `run/EqAgainstConstructor` is the guard that a kept call's
function was kept.

### An arrow body or a statement that would begin with `{`

*Added 2026-09-28.* JavaScript reads a `{` in two positions as a block, not as
an object literal: the first token of an arrow function's concise body, and the first token of an
expression statement. **The printer brackets the whole expression in either position when its
LEFTMOST printed token is an object literal's `{`** — decided by the token, not by the node's kind.
`arrowBody` bracketed a body that WAS an object (`() => ({ a: 1 })`), and nothing else, so
`first n = ( n, 1 ).0` printed `(n$1) => { a: n$1, b: 1 }.a`, a build that exited 0 and a module that
did not load (`SyntaxError`), in both builds. The rule follows the left spine — a callee, a member's
or an index's object, a binary operator's left operand, a conditional's test — through every child
printed without its own bracket, resolving §9 item 1's substitutions at each step, so the answer is
about the bytes written: `(n$1) => ({ a: n$1, b: 1 }.a)`, `() => ({ f: g }.f(x))`,
`() => ({ t: b }.t ? 1 : 2)`, and `() => b * ({ a: 1 }.a + 1)` untouched, its brace already inside
a bracket. The walk is a loop (a derived `eq`'s spine is one `&&` per field). A statement's other
hazard, a leading `function`, cannot arise: `JsIr` has no function expression. Fixtures:
`run/ArrowBodyStartsWithRecord` and `run/ArrowBodyLeftmostBrace` (dev and `--release`), and
`Print.zig`'s two unit tests for the statement position, which no lowering reaches today.

## 5. Module output and linking

Dev: one `.mjs` per module, ESM `import`/`export` between them, names as `Module$name` so a stack
trace is readable; each module's sibling JavaScript beside it as `<Module>.foreign.mjs`, and the
platform's runtime as `_platform/<name>.foreign.mjs` (§2, *The output tree does not depend on the
file system's case sensitivity*, for why the reserved directories begin with `_`). Release: chunks (§10), every surviving declaration emitted into its chunk with a
short name, and the cross-chunk bindings synthesised by the assigner — and with one entry point and
no `lazy`, that is one file. *Amended 2026-09-30: that one file is built — §9, *One scope-hoisted
file under `--release`*, with the siblings and runtimes in it too.*

A platform declares its output shape (`boundary.md` §5.2) — what the artifact looks like and how
`main` is invoked. The emitter is parameterised by it.

**Derived functions are module-local and named by the compiler**: `<Module>$<Type>$eq` for a
nominal type, `<Module>$eq$<shape>` for a structural one, emitted **sorted by printed name text**
rather than in the order the checker asked for them, so a reader can check determinism without
reasoning about discharge order (CLAUDE.md rule 5). Derivation is **eager** — every declared
nominal type ships both, called or not — which is why §9's reachability elimination stopped being
an optimisation and became a prerequisite (`fast-compiler.md` §13). And `Lower.emissionOrder` must
walk the dispatch table's sites **as well as** `bir.refs`: a method call is a reference the file
does not record, and without those edges a constant whose initialiser is a method call on this
module's own type is a temporal-dead-zone throw in a well-typed program.
→ [`static-dispatch-spike.md`](static-dispatch-spike.md) §8.5, §1.4.

### What a module looks like after elimination

§9 decides *what* survives; this is what the file shape does about it. Four consequences, and none
of them is a new mechanism:

- **An unreachable declaration is not lowered, not printed and not exported.** `Lower.exports`
  (`src/js/Lower.zig:637-680`) builds its list from `bir.interface`, the dispatch table's nominal
  `derived` rows and the entry declaration; each of the three is filtered by the surviving set, so
  an export list shrinks to exactly the surviving names it used to hold. It does **not** shrink to
  what someone imports: a `pub` value that survives because something reaches it stays exported
  under its own name, because an export costs the name once and a consumer-driven export list would
  make one module's bytes depend on another's, which is a determinism hazard for nothing.
  *Amended 2026-09-30 (research 41 §3): under `--release` of an application it does.* A release
  module's bytes already depend on every other module's — §9 item 2's whole-program name table —
  so the hazard above is paid already, and the list is cut to the names some file of the build
  imports: another module's `import`, or the entry file's of `main` (`Emit.markImported`, serial
  and after `numberGlobals`, so input-derived at every `--jobs`). An application's output tree is
  the whole program, so an export outside that set is bytes nobody can ask for; an empty list is
  not written. `--library` keeps every export, its public surface (§9's *Roots*), and a
  development build is unchanged. In the same change the release entry file names `run` and
  `start` in one `import` when they are one file's exports (the browser platforms'). Pinned by
  `build_test`'s *a release application exports only what another file imports* and
  `external_platform_test`'s entry-file test.
- **Import lists shrink for free on one leg and need one line on the other.** Cross-module imports
  are already use-driven — `need` / `needDerived` collect them as lowering discovers them
  (`src/js/Lower.zig:743-759`) — so a dropped declaration takes its imports with it and a module
  with no surviving reference to another emits no `import` of it. The **sibling** import is not:
  `importStatements` walks `bir.decls` and imports every `foreign_value` whether used or not
  (`src/js/Lower.zig:688-695`). That loop gains the surviving-set test, so an unreachable `foreign`
  is not imported.
- **A module with nothing reachable is not written at all**, and nothing imports it because imports
  are use-driven. `emitModules` (`src/js/Emit.zig:673-717`) skips producing it. A **sibling file**
  is copied iff the module has a *surviving* `foreign_value`, which replaces `copyAssets`' current
  "declares any `foreign`" test (`src/js/Emit.zig:725-729`). The platform's runtime is still copied
  unconditionally: the entry file imports its `run` (§2), so it is a root by construction.
- **Emission order is unchanged and still correct.** `emissionOrder` (`src/js/Lower.zig:496-538`)
  post-orders `bir.refs` plus the dispatch sites; its outer loop is restricted to surviving
  declarations, and it can reach nothing else, because every edge it walks is also a reachability
  edge. So the survivors come out in the same relative order they have today and the temporal dead
  zone stays closed. The derived pass (`synthesisedValues`, `:1886`) keeps its two sorted runs and
  iterates only surviving rows.
  *Amended 2026-09-25:* "the dispatch sites" includes the bodies of
  the derived rows of this module they name (`Edges.termsEdges` through rows). A constant that
  calls a derived function runs its body, so a value that body names is a dependency: without the
  edge, `main` calling `Main$W$$eq` was emitted above the `Main$key` its body reads, and the
  program threw `ReferenceError` at load. The value-cycle check (`check/Cycles.zig`) reads the same
  edges.

**Elimination decides what is written, never what is checked.** `checkForeignShapes` and
`checkSiblings` run before the entry is even found (`src/js/Emit.zig:145-146`) and keep running over
every module of the graph, reachable or not: `boundary.md` §4's four checks are a contract on
privileged code, not an optimisation, and a sibling that grew an extra export must fail the build
whether or not anything imports it. What *does* go quiet is a **lowering** diagnostic in a
declaration nobody reaches — it is not lowered, so it is not raised. That is deliberate and is the
one behaviour change a user can see: a program whose only use of `?` is in dead code now builds
(§1's `not_implemented`). Code that is not emitted cannot miscompile.

## 6. The calling convention

**There isn't one.** `fast-compiler.md` §9.3 dropped automatic currying on 2026-09-14 and
`language.md` §6.7 specifies the result: every call is saturated, arity is part of the function
type, and function types of different arity do not unify. So a beni application of *n* arguments
emits a JavaScript call of *n* arguments, `f(a, b)`, and there is nothing else to emit.

**What leaves this document.** The arity tag, the `A2`/`F2` adapter, the saturated-call
specialiser, the call-site curry wrapper `((x) => (y) => f(x, y))`, the `Arity.unknown` path, and
the optimiser's obligation to measure the direct-call share. The share is 100% by construction, so there is
no number left to decide anything. Elm pays roughly 49% on Chrome for routing saturated calls
through its adapter; there is no adapter here to route through.

**Why the backend never meets a partial application.** The two ways to write one are both
front-end rewrites that are gone by the time BIR exists (`language.md` §8): `f a _` lowers to a
lambda over the innermost enclosing application, and `e |> f a` lowers to the call `f e a`. A
function-typed value in flight is therefore always a closure of known arity, never a partially
applied thing waiting for more arguments, and a call through a parameter is a call of that
parameter's arity, which the checker knows.

**Static dispatch extends that invariant and does not break it.** Evidence is a function value in
flight, and a piece of evidence that itself takes evidence has a *hidden* arity the receiving
parameter's beni type does not show — so passing it by bare name would be a partial application by
the back door. It is passed **eta-expanded** instead: a closure of exactly the beni arity that
supplies its own evidence inside. Evidence with no evidence of its own is passed by bare name. So
the sentence above still holds as written, with "known arity" meaning the beni arity at every
point. The hidden leading parameters are a *calling convention for a declaration*, fixed by the
checker at every site, and never something the backend has to discover.
→ [`static-dispatch-spike.md`](static-dispatch-spike.md) §8.1, §8.2.

**What this does not remove.** The absence of a runtime library still holds and still matters:
`boundary.md`'s wall means the only hand-written JavaScript in a build is core's siblings, and a
codegen helper would be neither that nor beni. Dropping the adapter makes that easier to keep, not
harder — it was the one helper this section had ever needed.

## 7. Pattern matching

Decision trees, Scott and Ramsey's heuristics, compiled to a native `switch` for multi-way tests on
a constructor tag. Single-use branches inline; multi-use branches are shared through a labelled
block. The checker has already proved exhaustiveness (`checker.md` §6.6), so **the tree needs no
default arm for a well-typed match** and the absence of one is not a latent crash.

Today's lowering is not a tree. `caseExpr` (`src/js/Lower.zig:3573`) walks the branches in source
order and, per branch, builds the whole conjunction of tests that branch needs from the root
(`patternTest`, `:3683`) and then all of its bindings (`bindings`, `:3788`), so every branch
re-tests what the branches above it already disproved. What follows replaces that with one tree over
all branches at once. **§8's loop does not depend on this section and landed first**; what this
section inherits from it is `tailStmts`/`tailCase` (`:1099`, `:1120`), a lowering of an instruction
in tail position straight into a statement list.

### What today's lowering costs, measured

Three programs, compiled with the binary before decision trees. "Tests" counts `===` operands in the emitted
function; "worst path" counts the comparisons one call executes on its slowest input.

| Program | Tests emitted | Distinct | Worst path | `if` nesting | The tree emits |
|---|---|---|---|---|---|
| `describe : Shape, Colour -> String`, 5 rows over a 2-tuple of ADTs | 6 | 4 | 4 | 4 | one 3-label `switch` + 3 `if`s; worst path 2 |
| `classify : List Int -> String`, 5 rows mixing `[]`, `[ 1 ]`, `[ x ]`, `1 :: 2 :: rest`, `x :: y :: rest` | 10 | 6 | 7 | 4 | 5 tests total; worst path 4 |
| `run : List Token, Int -> Int`, 10 rows over a 9-constructor enum inside a cons | 17 | 10 | 17 | 9 | one `if` + one 9-label `switch`; worst path 2 |

The last column was a prediction when this was written and is the **measurement** now
(`tests/corpus/run/Match*.beni` are the three programs). Two of the three landed as predicted; the
`classify` row did not, and the prediction was wrong rather than the tree. Distinguishing `[ 1 ]`
from `[ x ]` from `1 :: 2 :: rest` from `x :: y :: rest` needs four questions of a two-cell list —
is there a first cell, is there a second, is the first `1`, is the second `2` — so four is the
floor for its worst path and no column order reaches three.

In the third, `ts$1.$ === 1` is written **eight** times, and the `case` is the body of a §8 loop, so
that is up to eight comparisons per list element. In the first, the scrutinee is a tuple literal and
the lowering allocates `{ a: shape$1, b: colour$2 }` per call purely to read both fields back out.
Two costs the table cannot show: `day : Int -> String`, five integer literal rows, emits a four-deep
`===` ternary chain where a `switch` is one dispatch; and building
`tests/corpus/run/Dictionaries.beni` writes 69,566 bytes over sixteen `.mjs` files holding 175
`===`, **41 scrutinee temporaries** (`const $t$n = …`, from `bindSubject` at `:3669`, which binds
any non-name scrutinee even when the tree reads it once — every `if` in the language pays this, both
in `emit/TailCallLoop.js` included) and **76 result temporaries** (`let $t$n;`, an assignment per
arm and a `return $t$n`, from a `case` that is a whole function body and could have returned from
each arm).

### The matrix, and what a column is

A `case` of *m* branches is a matrix of *m* rows and one column, the scrutinee; each row carries its
branch's pattern, its body and a binding list. Compilation is Maranget's: pick a column, ask which
constructors occur in it, and for each one **specialise** — keep the rows whose pattern there is
that constructor or a wildcard, replacing the constructor's with its argument sub-patterns in place,
so the column becomes *arity* columns. A column of wildcards everywhere is dropped; a matrix whose
first row is all wildcards is a leaf. Pattern forms are simplified exactly as `check/Exhaustive.zig`
simplifies them, and the vocabulary is deliberately shared with it:

| Form | In the matrix | Emitted test |
|---|---|---|
| `_`, `x` | *anything*; `x` adds a binding of this occurrence | none |
| `p as x` | `p`, plus a binding of this occurrence to `x` | `p`'s |
| constructor | a constructor of the declaring `type`'s union, in declaration order | `ctorRepOf` (`:1278`): `subj` for `.boolean`, `subj` for `.bare_tag`, `subj.$` for `.tagged` |
| tuple, `()` | the sole constructor of a one-constructor union — **always matches**, so it never becomes a test; it expands into *n* columns (0 for `()`) | none |
| record `{ a, b }` | *anything*, with one binding per named field: a record type has no alternatives | none |
| `[]`, `x :: xs` | the two constructors of the list union on the emitter's `{$:0}`/`{$:1}` shape (§4) | `subj.$ === 0` / `=== 1` |
| `[ a, b, c ]` | **normalised to `a :: b :: c :: []`** before the matrix is built | the cons tests |
| `Int`, `Char`, `String` literal | a literal with infinitely many alternatives, so the node always keeps a default edge | `===` against the literal |

The matrix is `js/Decision.zig`, which reads those forms off `Bir` and knows no representation at
all; `js/Lower.zig` turns the tree it returns into the JavaScript of the third column. A literal
edge carries the pattern instruction that spells it and a constructor edge the reference that names
it, which is what the emitter reads `ctorRepOf` from — so the representation is decided in exactly
one place, as it was before.

`-1` is an `Int` literal, and **there are no `Float` patterns and no guards** — `language.md` §3's
`PatAtom` admits `int | char | string-without-interpolation | '-' int` and nothing else — so a
literal node is always a `===` fan-out with a default and never a range test or a side condition.
A `Char` is a one-scalar string (§4), so its test and a `String` literal's are the same `===`.

**The checker leaves nothing behind to reuse.** `check/Exhaustive.zig` is a usefulness analysis over
`Bir` patterns returning diagnostics and no artifact, and it reads no solved type. So the backend
builds its own matrix from `Bir`.

**"The checker proved exhaustiveness" now holds without a hole.** It did not when decision trees
landed: usefulness is exponential (`checker.md` §6.6), and a `case` that exhausted `pattern_budget`
reported **nothing**, so it could reach the backend non-exhaustive, take the default-free last edge
and compute a wrong answer rather than throw — at exit 0, with no diagnostic anywhere. That hole was
reachable at the DEFAULT budget and with no flag: a `case` over about 440 `Int` literals cost more
than the 200 000 steps that were the default then (a later change made a flat table linear and the
default 5 000 000, so that shape costs ~880 now), and one written without its wildcard compiled and
printed the last branch's answer for every unmatched input. It is closed at the checker,
where it belonged: an
undecided `case` is now `pattern_budget_exhausted`, an error, so nothing the backend receives is a
`case` the checker declined to decide. The tree still carries no default arm, and it still needs
none.

### Choosing a column

Among the columns that are **relevant** — those in which at least one row has anything other than a
wildcard — apply these in order and stop at the first that leaves one column:

1. **d, small default** (Scott & Ramsey; Elm's `pickPath` uses it first): fewest rows whose pattern
   in that column is a wildcard. A wildcard row is copied into *every* specialisation, so this is
   the heuristic that directly minimises duplicated rows.
2. **b, small branching**: fewest distinct constructors or literals present.
3. **leftmost**: the lowest column index.

Rule 3 is not a formality: it is what makes the choice **input-derived** (CLAUDE.md rule 5). Column
index is the pattern's structural position, the constructor set at a column is enumerated in the
declaring `type`'s declaration order — `Bir.ctors` or the interface, the source `Exhaustive.zig`
already uses — and nothing here consults a hash map's iteration order or a thread, so `--jobs=1` /
`--jobs=8` covers the section with no new machinery.
*Alternatives rejected: necessity-first (Maranget 2008 §8), a fixpoint per node for a gain Scott &
Ramsey measured as noise against d; and Elm's d-then-b with no positional tie-break, which leaves
the choice to whatever order the constructor set happened to be built in.*

### The emitted shape

**A node with three or more case labels is a `switch`; two or fewer is `if`/`else`.** `JsIr` has
held `switch_stmt` and `switch_case` from the start (`src/js/JsIr.zig:146`) and the printer emits them
(`src/js/Print.zig:302`). At two alternatives there is nothing to dispatch and `if (x.$ === "A")` is
shorter than a `switch` naming the discriminant and adding two labels; at three the `switch` is both
shorter and one dispatch. The threshold is representation-independent, so it survives the optimiser turning
tags into integers and the dense cases into a jump table, and it removes every special case:
**a boolean node and a list node have exactly two alternatives and are therefore always `if`**,
which is why `if` keeps emitting what it emits today.

- The discriminant is `subj` for `.boolean` and `.bare_tag`, `subj.$` for `.tagged`, and the
  scrutinee itself for a literal node. `switch` compares with `===`, which is what every one of
  these tests already is.
- **Each `case` body is a block**, `case "A": { … }`. Two sibling cases may both bind — local
  indices keep the names apart (`localName`, `:1193`) so a redeclaration is impossible today, but a
  `switch`'s cases share one scope and one block per case ends that class of bug for two bytes that
  compress to nothing.
- **Every case body ends in a terminator** — `return`, `continue <label>` or `break` — because
  `switch` falls through. This is not a rule the tree has to remember: the leaf shapes below all
  terminate.
- **The last alternative of an exhaustive constructor fan-out is `default:`**, not `case "C":`, and
  nothing is emitted for the impossible arm — it saves a label and a `throw` per `switch`, and it is
  byte-for-byte what today's chain does when it emits the last branch unconditionally (`:3630`).
  Which one: the one declared **last** in the type among those present at the node, input-derived
  with no tie-break. When the node has a genuine default edge that edge is `default:` and every
  present constructor gets its own `case`; a literal node always has one, since a literal column is
  never exhaustive without a wildcard row. **A wildcard row is not by itself a default edge**: a row
  that is a wildcard in this column is copied into *every* specialisation already, so once the
  alternatives present are all the type has, the default arm is unreachable — it is the impossible
  arm this rule refuses, and emitting it would cost a second copy of whatever the wildcard rows
  decide. So the edge exists only when the present set is *incomplete*, which is Maranget's
  condition and is what makes `( Circle, Red ) | ( Circle, _ ) | …` two `if`s over a two-constructor
  `Colour` rather than two `switch`es. *Alternative rejected:
  `default: throw new Error(…)`, a diagnosis for a state the checker excludes, at a string per
  `switch` in every program.*
- Adjacent `case` labels reaching the same body are **not** merged into `case "A": case "B":` — a
  printer-level win, and the optimiser's.
- *Added 2026-09-27.* **At most 16 384 labels a `switch`**
  (`Lower.max_switch_cases`), four times under the 65 046 SpiderMonkey refuses (§4's table). A
  larger fan is written as consecutive `switch`es over the same discriminant, the `default:` in
  the last: every case body terminates (above), so a value no label of one names falls through
  to the next, and they follow one another, so nothing nests. The tree itself groups a column's
  rows by head in one pass (`Decision.group`), so its construction is linear in the rows at each
  node; before, the key set, the column choice and the specialisation compared every row with
  every other, and a 20 000-branch `case` took 8.9 s to build (0.04 s after).

**Bindings are emitted at the leaf, and an occurrence is a member chain, not a name.** A pattern
variable's occurrence — `subj.a.b` — is fixed by its position in the pattern and is therefore the
same expression on every path that reaches its leaf, which is what lets the leaf own its bindings
even when it is shared. The chain is rebuilt at each use: every value is immutable and every
occurrence is a property read on a `{$, a, b}` object, so re-reading costs and risks nothing, and
the one expression that must be evaluated exactly once is the scrutinee. *Alternative rejected: a
`const $p$k` per tree edge, Maranget's usual presentation — it makes "evaluated once" literal and
costs one live binding per edge that the optimiser's dead-binding pass cannot remove, for a property read V8
already inline-caches.*

Two changes to how the scrutinee itself is bound. **`bindSubject` binds unless the tree reads the
root exactly once**: a two-alternative boolean node reads it once, so `const $t$1 = n$1 <= 0; if
($t$1)` becomes `if (n$1 <= 0)`, and every `if` in the language is a `case` (`language.md` §8), so
that is the 41 scrutinee temporaries above. Exactly once, and not "at most once", because a tree
that reads the root ZERO times — `case f x of _ ->` — would otherwise not evaluate `f x` at all,
and deciding that a beni expression is dead is the optimiser's job and not this one's. The count is
one fan-out per test of that root plus one per `const` its leaves bind, over the branches the tree
actually reaches; a root read once is therefore read on every path, because a tree with any fan-out
over it tests it before any leaf binds it. And **a `case` on a tuple literal starts as an
*n*-column matrix over the tuple's elements**, each bound by `bindSubject` in source order, with no
tuple object built at all. The condition is syntactic — the scrutinee is a `Bir` `tuple` node and
**every** row's pattern is a tuple pattern or a bare `_`; a row binding the tuple as a whole, by
name or by `as`, needs the object and turns the rule off. There is no `case a, b of` syntax, so a
tuple scrutinee *is* how this language writes a multi-column match, and the matrix gets it for free.

*Added 2026-09-29.* **A read is a discriminant the emitter prints or a `const` a leaf binds, and a
scrutinee — or tuple element — that nothing reads is still evaluated, as a statement.** The count
above was of fan-outs, and two kinds of fan-out print a different number of discriminants than
one. A fan with one label, the sole constructor of a one-constructor type (`case e of Inc ->`,
`case e of Box _ _ ->`), prints none, yet counted as the one read, so `e` was left unbound and
never evaluated: `case Debug.log m "m" of Inc ->` logged nothing in either build. A fan wider than
`max_switch_cases` prints one `switch` per chunk, each reading its discriminant, yet counted once,
so an unbound call ran once per `switch` its value was not found in. Each fan now counts its
printed discriminants: none for one label, one for two, and one per `switch` above. A root read
zero times is written as an expression statement where it is evaluated, not as a `const`: no
binding is written, so §9 item 1 — which drops a dead binding whole, `Debug.log` and all — has
nothing to drop, and the two builds evaluate the same expressions. A name or a field read of one
has nothing to evaluate and is left out. The rule is about the `case`; a `let` pattern that binds
nothing is a binding, and §9 item 1 still drops it in `--release` (`language.md` §6).
`run/CaseSingleConstructorScrutinee` and `abuse_wide_test.zig`'s development build are the tests.

### Sharing a leaf reached from two paths

A leaf reached from exactly one path is **inlined** where it is reached. A leaf reached from two or
more is written **once**, and every path reaches it by `break`ing out of a labelled block that ends
immediately before it:

```js
$j$0$4: { <the tree; a path reaching branch 4 emits `break $j$0$4;`> }
<branch 4's bindings>
return <branch 4's body>;              // tail position: no wrapper needed

let $t$1;                              // expression position: one `$c$<d>` wrapper,
$c$0: {                                // and shared leaves nest lowest-index-innermost,
  $j$0$4: {                            // so their bodies read in source order
    $j$0$2: { <the tree> }
    <branch 2>  $t$1 = …; break $c$0;
  }
  <branch 4>  $t$1 = …;
}
```

`$j$<d>$<b>` labels the block whose exit is branch *b*, *d* being the number of enclosing `case`
instructions in the function being lowered; `$c$<d>` wraps an expression-position tree that needs
one. Both are structural, so a golden does not renumber when an unrelated declaration is added above
it, and two cases at one depth are siblings and never nested, so the names cannot collide. The
`break $c$<d>` on the textually last leaf is omitted.

**This composes with §8 by construction, verified by hand on Node 24.19.0.** `break <label>` leaves
a labelled block from inside a `switch` case, and `continue <label>` targets the nearest enclosing
*iteration statement* with that label — a labelled block is not one — so a tail self-call inside a
shared leaf inside a `switch` inside a shared block still reaches the function's `while (true)`.
That is what §8's "the `continue` is labelled, not bare" was reserved for.

*Alternatives rejected. A local arrow per shared leaf, `const $j$4 = (x, y) => …`: it reads better
and it is disqualifying, because `continue <function label>` cannot cross a function boundary, so
§8's loop would silently stop applying to exactly the matches that need it most. Duplicating a
shared leaf below a size threshold: duplication is what a decision tree is exponential in, and the
counted rule — one path inline, two or more shared — is Elm's `Optimize/Case.hs`
`countTargets`/`createChoices`, by report 03 §5.4 (`references/elm` is a submodule pointer and is
not initialised on this machine, so that is the report's reading of it and not mine). And Elm's own
`label: while (true) { … break label; }`, a labelled block wearing a loop's clothes, which would put
a second `while` between a `continue` and §8's.*

### Where the `case` sits

| Position | Leaf shape | Wrapper |
|---|---|---|
| tail (the function body, or through `let`/`case` from it) | `return <expr>;`, or §8's assignments and `continue <label>` for a tail self-call | none needed: both terminate a `switch` case and escape every labelled block |
| expression, and the tree has a `switch` or a shared leaf | `$t$n = <expr>; break $c$<d>;` | `let $t$n;` above one `$c$<d>` block |
| expression, pure `if`/`else` chain | `$t$n = <expr>;` and fall out of the arm | `let $t$n;`, exactly as today (`:3620`) |
| expression, no `switch`, no shared leaf, every leaf one expression and no bindings | the value | a `cond` chain — `a ? b : c`, exactly as today (`:3599`) |

**§8's gate on the statement form is removed.** §8 used `tailStmts` "only inside a function that has
at least one tail self-call, so every existing `emit/` golden stays byte-identical"; the backend now lowers a
`case` in tail position into statements whether or not the function loops, deleting the `let $t$n;`
/ assign / `return $t$n` triple from every function whose body is a `case` — the 76 result
temporaries above. `Maybe.withDefault` becomes

```js
if (maybe$1.$ === "Just") {
  const value$3 = maybe$1.a;
  return value$3;
} else {
  return $default$2;
}
```

— an `if`/`else` and not an `if` with the last arm behind it, because a two-alternative node is
`if`/`else` by the rule above and nothing here special-cases the shape of its second arm; and the
binding is a `const` at the leaf, because that is where §7 puts bindings.

`if` needs nothing of its own: it is a `case` by the time the backend sees it (`language.md` §8), a
two-alternative boolean fan-out, which the ≥3 threshold keeps as the `if`/`else` it is today.

**`?` turned out not to be a `case` at all.** This section predicted it would be "a two-branch
`case` whose first arm returns from the enclosing function", and what it needed from §7 was the
tail-position statement form. What landed is smaller: `Bir` keeps `?` as its own instruction, so
the emitter writes one `if` and one `return` with no tree, no scrutinee binding it does not need
and no branch bodies (§4). Two things this section owns still hold for it, and they are worth
naming here because a leaf is where a reader will look for them: a `?` in a **branch body** hoists
its test and its `return` into that branch, so the other branch never runs them; and a leaf that
hoists any statement at all is why the `cond` chain of the last row is chosen only after the
bodies are lowered — `a ? b : c` cannot hold a `return`.

**Irrefutable patterns keep their own path.** A `let` pattern is irrefutable by grammar
(`language.md` §7) and a function or lambda parameter pattern is *intended* to be. Both are a
one-row matrix with no relevant column, so the tree is one leaf whose output is that leaf's bindings
— byte-identical to what `letBindings` (`:3497`) and `functionOf`'s destructuring prologue (`:745`)
emit today by calling `bindings` directly, and they keep calling it. `language.md` §3's `Definition
:= lower_ident PatAtom* '=' Expr` does in fact admit a *refutable* parameter pattern, nothing
rejects it, and `un (Just n) = n` applied to `Nothing` returns `null` today; that is a front-end or
checker defect and §7 must not be extended to paper over it, because the
tree would have nowhere to send the failing value either.

### What must not change

- **Behaviour.** Every `tests/corpus/run/` fixture stays green with **no `.expected` change**. A
  decision tree computes what a linear chain computes; if a `.expected` moves, the tree is wrong.
- **Determinism.** `--jobs=1` and `--jobs=8`, twice each, byte-identical.
- **Derived `eq` and `compare` are out of scope.** They are emitted by `nominalArrow` /
  `structuralArrow` (`:2186`, `:2090`), which build their own `switch` from the dispatch table and
  never touch a `Bir` pattern (`static-dispatch-spike.md` §9). `emit/Derived*.js` must not move.
- **Five existing `emit/` goldens change, and no sixth.** This bullet said "exactly one" and was
  wrong on its own terms: `emit/TailCallLoop.js` loses two `const $t$n = n$1 <= 0;` temporaries into
  the `if` and the ternary that read them once — and `emit/ConstantMethodCall.js`,
  `emit/EvidenceParameters.js`, `emit/EvidenceValue.js` and `emit/MethodTargets.js` each hold a
  function whose whole body is a `case` over a **one-constructor** type, which is the `let $t$n` /
  assign / `return $t$n` triple this section deletes, not a `case` over a boolean. (`EvidenceValue`
  renumbers two `$p$n` besides, because the module-wide counter behind every compiler-made name no
  longer spends a tag on the temporary that went.) The rest of the corpus is untouched, so a sixth
  that moves is a finding and not a blessing.

### Fixtures

`run/` unless the row says otherwise; §12's rule that behaviour is proved by running still holds.

| Fixture | Intent | Observable |
|---|---|---|
| `MatchNested` | constructors inside constructors, and a tuple scrutinee whose rows overlap — `describe` above | the strings; wrong specialisation picks the wrong arm |
| `MatchRowOrder` | rows that overlap and whose order decides, swapped in a second function. Not "a specific row above a general one", which this row said and the checker refuses as `redundant_pattern`: two rows that overlap where neither shadows the other — `1 :: n :: _` and `n :: 2 :: _` — and which bind the same NAME at different occurrences | the two differ; a tree that loses source order makes them equal, and one that carries a binding down an edge instead of rebuilding it at the leaf gets the right string with the wrong number |
| `MatchLiteralFallthrough` | `Int`, `String` and `Char` literal rows with a `_` fallback, enough of each to cross the `switch` threshold | every literal and one miss per type |
| `MatchSharedLeaf` | a leaf reached from two paths, binding pattern variables, exercised down both | the same answer from both, with the bindings right on each |
| `MatchInLoop` | a `case` inside a §8 tail-recursive loop deep enough to overflow without it, where the `continue` crosses a `switch` **and** a shared leaf's labelled block | the sum at a depth of 1 000 000 (and see below: this one passes before the change too, because §8 landed first) |
| `MatchListDepth` | `[]`, `[ x ]`, `[ 1 ]`, `x :: y :: rest`, `1 :: 2 :: rest` in one match — `classify` above | one line per shape, including the ones the current chain gets right only by luck |
| `MatchRecordsTuples` | records and tuples nested inside constructors, and a tuple scrutinee with a row that binds the whole tuple (so the object *is* built) | the values; proves the tuple rule's off-switch |
| `MatchAsPattern` | `as` at the top of a row, on a nested sub-pattern, and on a shared leaf | the bound whole and the bound part |
| `MatchBigEnum` | a nine-constructor enum inside a cons, in a loop — `run` above | the fold's answer |
| `emit/MatchSwitch` | the shape: one `switch`, blocks per case, the last constructor as `default:`, no `throw` | golden |
| `emit/MatchSharedLeaf` | the shape: `$j$<d>$<b>`, the `break`, the leaf written once | golden |
| `emit/MatchNested` | the shape: no test appears twice on any path, and no tuple object is allocated | golden |

§12's fail-first discipline applies to every `run/` row: each is written so the current chain either
gives a different answer or is pinned by an `emit/` golden that changes.

**What that came to, honestly, and it is not what the paragraph above predicted.** Run against the
binary before decision trees, with every fixture of this table in place, **eight `emit/` goldens fail and no
`run/` fixture does** — the three new ones, and the five §7 knew it would move. Every `run/` row
passes before *and* after, by design and not by accident: a decision tree computes what a linear
chain computes, which is the first line of "what must not change", so a behaviour fixture for this
change guards the rewrite rather than reproducing a defect. That includes `MatchInLoop`, which this
section expected to overflow without the fix and does not: §8's loop landed FIRST, so the `continue`
was already a jump before the tree put a `switch` between it and the `while` — what `MatchInLoop`
proves is that it still is. The fail-first rows are the `emit/` goldens, and `MatchRowOrder` is the
one written to tell a wrong tree from a right one rather than to document a shape — overlapping
rows, source order deciding, and one name bound at two different occurrences. It is the row to read
first when this lowering is next changed.

### Measurement

`bench/size.mjs` and `bench/runtime.mjs` are the instruments, and each claim is a **direction, not a
promise**; both are recorded here whichever way they come out. Compressed size should fall — fewer
tests, fewer temporaries, one mention of a discriminant per fan-out instead of *n*, and `switch` and
`case` are as compressible as tokens get — against shared-leaf labels and rows a wildcard column
duplicates. Runtime should fall on anything that matches in a loop, where the third program above
runs up to eight comparisons per element that a tree never runs. **Emit throughput must not regress
beyond noise** (§13, 85.5 MB/s when first measured): the tree is built per `case` over a matrix of branches ×
columns, the same input the linear chain already walks once per branch, and the exponential case is
the checker's usefulness relation and not this one. If a corpus module's emit time moves, a
heuristic is being recomputed where it should be cached — an implementation bug, not a design cost.

**Measured**, the compiler before decision trees against the one after, on the same corpus both times (80 programs, the fixtures
of the table above included), five iterations of `bench --generate=100000`:

| | before | after | |
|---|---|---|---|
| `bench` emit, wall clock | 53.92 ms | 46.92 ms | −13% |
| `bench` emit, JavaScript written | 3,872,156 B | 3,045,688 B | **−21%** |
| `bench` emit, MB/s | 68.5 | 61.9 | −9.6% |
| `size.mjs` raw, 80 programs | 268,916 B | 268,707 B | −0.1% |
| `size.mjs` gzip | 52,443 B | 50,911 B | −2.9% |
| `size.mjs` brotli | 46,160 B | 45,938 B | −0.5% |
| `size.mjs` floor (core + platform) gzip | 16,880 B | 16,215 B | −3.9% |
| `runtime.mjs --variant=c1`, ns/op | — | — | −12% to −23%, every program, checksums identical |

Two of those read the wrong way round unless the denominators are read with them. **Emit MB/s
falls while emit gets faster**: the metric is output bytes over time, the change removes a fifth of
the output bytes, and the same 100k lines are lowered in 13% less wall clock — 1.92M to 2.21M
lines/s. §13's budget is "> 5 MB/s of JavaScript", which this is 12× over; the throughput this
section told the implementer not to regress is the one per line of input, and it improved. And
**raw size barely moves while compressed size falls**: the block per `switch` case and the labelled
block per shared leaf cost braces that the temporaries and repeated tests paid for elsewhere, and
braces are the cheapest bytes a compressor ever sees. The direction §7 predicted — compressed size
down, runtime down on anything that matches in a loop — holds; the size win is smaller than the
runtime one, and the runtime one is larger than expected because `Dict` and `List` match in every
inner loop `bench/runtime` has.

## 8. Tail calls

Direct self-recursion lowers to `label: while (true)`. **This is mandatory, not an optimisation**:
no JavaScript engine reliably provides tail-call elimination, V8 shipped and reverted it,
SpiderMonkey never shipped it. Node 24 overflows a two-parameter accumulator between 5 000 and
10 000 frames, which is why `bench/runtime/c1/R1DictString.beni:11` builds its key list out of two
small ranges and why `core/List.beni:71,77` said `foreign` until the loop landed. Mutual recursion
remains a real stack frame and ships as a stated limitation (§14 question 5).

`JsIr` has held `while_true`, `break_stmt`, `continue_stmt` and `assign_stmt` from the start
(`src/js/JsIr.zig:141`) and the printer already emits them (`src/js/Print.zig:284`); what tail calls add
is the lowering.

### What a tail call is

Over `Bir`, a **tail position** of a function is its body; every branch body of a `case` in tail
position — which covers `if`, a `case` by the time the backend sees it (`language.md` §8); and the
`in` body of a `let` in tail position. Nothing else is: not an operand, not an argument, not a
`let`'s bound value, not a lambda body, not the left of a `|>` (a pipe is a call before the backend
sees it, §6), not the operand of `?`, and not a `?` itself — it is its own instruction in `Bir`
(§4), its subject has to be tested before anything can be done with it, and what follows the test
is an ordinary expression that may or may not be a tail call of its own. Parentheses do not exist
in `Bir`, so looking through them is free.

A **tail self-call** is a `call` instruction in tail position whose callee is, syntactically, the
reference that names the function being lowered — a `top` for a declaration, a `local` for a
`let`-bound one — with argument count and evidence count equal to that function's own. Both
equalities hold by construction (calls are saturated, `language.md` §6.7, and the checker fixes
evidence at every site) and are still checked: a mismatch emits the ordinary call and no loop,
because a wrong loop is a wrong answer and a missing one is only a deep stack.

The cases, decided:

| Case | Loops? | Why |
|---|---|---|
| `f x acc = … f x' acc'` | yes | the case this exists for |
| `let go i acc = … go i' acc'` | **yes** | a `let_def` with parameters is already its own hoisted `function` (`src/js/Lower.zig:3135`), so the loop is contained; excluding it would leave the language's most natural loop idiom overflowing |
| `f = \x -> … f x'` | **yes** | `f x = e` and `f = \x -> e` emit byte-identical JavaScript today, and two spellings of one program must not differ in stack behaviour. The rule is narrow: a `lambda` that is the **entire** body of a parameterless declaration or `let_def` inherits that name; a lambda anywhere else never does |
| a self-call inside a nested lambda | no | a different function |
| a self-call through an alias, or `f` passed as a value | no | the callee must be the name itself, in callee position |
| the function's name shadowed | can't happen | shadowing is an error (`language.md` §7); `tests/corpus/parse/bad/ShadowingParam.beni` pins exactly a parameter named like a top-level value. The backend needs no scope test |
| a function with both tail and non-tail self-calls | yes | only the tail ones become jumps. `core/Dict.beni:128`'s `sizeHelp (sizeHelp (n + 1) right) left` is this shape in core today |
| a function with no tail self-call | no | its emitted shape is unchanged, byte for byte |

### The emitted shape

A parameter is **carried** when some tail self-call passes it anything other than a reference to
that same parameter. A carried parameter is renamed to `$in$<i>` in the JavaScript parameter list,
*i* being its position counting evidence first; the loop's prologue re-binds it to its ordinary
name with a `const`, one statement per carried slot — joining the run into a single
comma-separated declaration is §9 item 5's variable joining, a printer decision and the optimiser's, not
the loop's. A parameter that is not carried keeps its ordinary name and gets
neither slot nor copy. The test is syntactic and conservative — when in doubt, carried. A parameter
whose pattern is not a bare variable already has a compiler-made name and a destructuring prologue
(`functionOf`, `src/js/Lower.zig:745`); it takes a slot by the same rule, and **its destructuring
statements go inside the loop**, because they read this iteration's value.

```js
const List$foldl = ($in$0, $in$1, func$3) => {
  List$foldl: while (true) {
    const xs$1 = $in$0;
    const acc$2 = $in$1;
    if (xs$1.$ === 0) {
      return acc$2;
    } else {
      const x$4 = xs$1.a;
      const rest$5 = xs$1.b;
      $in$0 = rest$5;
      $in$1 = func$3(x$4, acc$2);
      continue List$foldl;
    }
  }
};
```

```js
const Main$count = ($in$0, $in$1) => {          // count n acc = if n <= 0 then acc
  Main$count: while (true) {                     //              else count (n - 1) (acc + n)
    const n$1 = $in$0;
    const acc$2 = $in$1;
    const $t$1 = n$1 <= 0;
    if ($t$1) { return acc$2; } else {
      $in$0 = Basics$sub(n$1, 1);
      $in$1 = Basics$add(acc$2, n$1);
      continue Main$count;
    }
  }
};
```

**There are no temporaries, and that is the load-bearing invariant.** `$in$<i>` is written in the
assignments and read in the prologue `const` and nowhere else; every argument expression is written
against the ordinary names, which hold this iteration's values and are never assigned. So the
assignments may run in parameter order with no `$temp$` in sight, and an argument swap is right by
construction. Elm reassigns the parameters in place and needs one `$temp$` per argument per call
site to do it; this scheme pays *n* copies once per function and *n* assignments per site against
Elm's 2*n* per site, so it ties at one tail call and wins at two, and the prologue line is the most
compressible kind of text there is (§9). *Alternative rejected: Elm's in-place scheme, fewer
bindings and correct only with a capture analysis — see below.*

Control leaves by `return` or by `continue <label>`; there is no `break` and nothing follows the
loop. The `continue` is **labelled**, not bare, because §7's decision trees put a `switch` and a
shared-branch block between the jump and this one. The label is the function's own emitted name —
`List$foldl`, `go$2` — input-derived, no counter, and it cannot collide because labels are a
separate namespace from bindings. `$in$<i>` is positional for the same reason (CLAUDE.md rule 5),
and two nested loops both using `$in$0` are safe precisely because neither ever reads the other's.
The parameter list keeps its count and order, so `.length` is unchanged and §6's eta-expansion of
evidence still sees the beni arity it expects.

### Closures, and the one way to get this wrong

This is the defect the design above exists to make impossible, and it exits 0.

```elm
build n acc =
    if n <= 0 then acc else build (n - 1) ((\x -> x + n) :: acc)
```

Each iteration conses a closure over `n`. Reassign `n` in place and every closure reads the last
value: `build 3 []`, then applying each to `0`, prints `0 0 0` instead of `1 2 3` — measured on Node
24 from both shapes written by hand. The per-iteration `const` fixes it because a `while` body block
gets a fresh declarative environment on every evaluation, so iteration *i*'s closures capture
iteration *i*'s binding. The copies are therefore **unconditional**: the answer has to be right for
lambdas, `f a _` placeholders, `<-` continuations and §6's eta-expanded evidence alike, and a
capture analysis that is wrong once is wrong silently.

`<-` is both at once. `let x <- f a in rest` is
`f a (\x -> rest)` (`language.md` §6.7), so when `f` is the enclosing function the **call** is a
tail self-call and loops, while the continuation is a different function and its body is **not** a
tail position of the outer one. The continuation closes over this iteration's parameters, including
over the callback parameter it is replacing — in-place reassignment there does not merely read a
stale value, it builds a closure that calls itself.

### Evidence parameters

The hidden leading parameters of §4 and `static-dispatch-spike.md` §8.1 are **ordinary parameters of
the loop**, carried or not by the same syntactic test. In the overwhelming case a self-call forwards
`$m$k` unchanged, so no evidence parameter is carried, none is renamed and none is assigned:
`countEq xs value acc` compiles to `($m$0, $in$1, value$2, $in$3)` with `$m$0` untouched —
the slot numbers count evidence first, so the first beni parameter is `$in$1` and not `$in$0`.

**"Evidence is loop-invariant" is not a rule, though, and stating it as one would be a miscompile.**
Polymorphic recursion is typeable here with an annotation and is accepted today: a `where`-constrained
declaration may call itself in tail position at a different instantiation, and the checker then writes
a *different* evidence expression at that site rather than `$m$k` — verified against the first backend,
where `f : List a, Int -> Int where a.eq` calling `f [ Red, Blue, Red ] (n - 1)` emitted
`Main$f(Main$eq$prim, …)`. The syntactic test catches it: the argument is not a reference to `$m$0`,
so `$m$0` is carried, gets a slot and is reassigned like anything else. A fixture is required.

### What this needs from `case`, and what it does not need from §7

**The loop does not depend on decision trees and must land before them.** What it does need is a
statement form of tail-position lowering, because `continue` cannot appear in a ternary or in an
IIFE and today's lowering produces both: `src/js/Lower.zig`'s `expr` returns an expression, and a
`case` becomes either one `cond` node or a `let $t$n;` above an `if`/`else` chain whose arms assign
it. Neither can hold a jump.

Tail calls add a second entry point beside `expr`: one that lowers an instruction **in tail position**
directly into a statement list, emitting `return <expr>;` for everything that is not a tail
self-call, an `if`/`else` chain with each arm lowered the same way for a `case`, the bindings
followed by the body for a `let`, and the assignments plus `continue <label>` for a tail self-call.
It is used **only inside a function that has at least one tail self-call**, so every existing
`emit/` golden stays byte-identical and `a ? b : c` survives wherever it is still correct. §7 later
replaces the `if`/`else` chain with a tree; the contract this section needs from it is only that a
tail position be reachable as a statement.

### `foldl` and `foldr` leave `foreign`

The two of them are the reason the loop was scheduled where it was
([`research/17-platform-primitives.md`](research/17-platform-primitives.md) §3,
[`transparent-effects-proposal.md`](transparent-effects-proposal.md) §10 item 0): they are the only
`foreign` values in the repository with a function type anywhere in them, and a JavaScript loop
cannot park when its beni callback suspends. **They land in the same commit as the loop** — `core/`
is compiled into the binary, so a beni `foldl` without the loop is a stack bomb in core itself.

```elm
pub foldl : List a, b, (a, b -> b) -> b
foldl xs acc func =
    case xs of
        [] -> acc
        x :: rest -> foldl rest (func x acc) func

pub foldr : List a, b, (a, b -> b) -> b
foldr xs acc func =
    foldl (reverse xs) acc func
```

`foldr` is **reverse then `foldl`**, exact for this argument order, and `reverse` is
`foldl xs [] cons`, so there is no cycle. It costs one extra list of *n* cells per call, which is
not a regression: today's `core/List.js:30` already materialises the whole list into a JavaScript
array to fold it backwards. *Alternative recorded and not taken: Elm's `foldrHelper` (read at
`references/elm-core/src/List.elm:172` by report 17 §3.3; the submodule is not initialised here)
unrolls four elements per frame and falls back past 500, avoiding the allocation for short lists at
twenty-five lines and a magic number. Revisit if `List.map`, built on `foldr`, shows up in a
`bench/runtime` profile.*

`core/List.js` loses exactly the `foldl` and `foldr` exports, which `boundary.md` §4's second check
— the sibling exports exactly the declared names, no more — is what enforces; the other two checks
are unaffected. `core/List.beni`'s header list goes from five `foreign` declarations to three:
`cons` stays (`::` desugars to it), and `eq`/`compare` stay for a reason the loop does not touch,
that `List a` has no constructors for the compiler to walk. **Report 17 §3.4 counted 66 first-order
`foreign` values and exactly two that are not; after the loop landed the count of higher-order `foreign`
values in the repository is zero**, which discharges the first half of
`transparent-effects-proposal.md` §10 item 0 in fact and not only on paper.
*Corrected 2026-09-18: zero in a **signature**, not zero. `List.eq` and `List.compare` are `foreign`
with a `where` clause, so their siblings are JavaScript loops that call a beni function — the evidence
`m0` — and under the effects proposal's lowering that is the same hazard `foldl` was. It harms nothing
today, because a well-known `eq`/`compare` cannot suspend; [`plans/effects-plan.md`](../../plans/effects-plan.md)
§2 carries it.*

**Everything else stays where it is**, and the list is short because most of it needs no source
change at all. These are already beni self tail calls and simply stop overflowing: `List.rangeHelp`
(`core/List.beni:145` — the one `bench/runtime/c1/*` works around), `repeatHelp` (`:128`), `any`
(`:252`, and `all` and `member` through it), `takeHelp` (`:566`), `drop` (`:582`),
`splitHalfHelp` (`:472`), `mergeWithHelp` (`:496`), `Dict.getHelp` (`:92`), `Dict.getMin` (`:314`),
`Dict.sizeHelp` (`:128`, its outer call only). These stay real frames because their self-calls are
not in tail position: `List.sortWith`, `Dict.insertHelp`, `removeHelp`, `removeMin`, `mapTree`,
`foldlTree`, `foldrTree`. And `Basics.and`/`or` are `foreign` for short-circuiting (§4), `String`'s
twenty-two for the native representation, not for this.

*Amended 2026-09-19.* `List.map2`–`map5` were on that second list and are no longer. The others on
it recurse to the depth of a balanced red-black tree or of a merge-sort split, both O(log n), and
measurement found none of them overflowing at 4 000 000 elements; `map2`–`map5` recursed to the
depth of the LIST and overflowed at about 5 700, 4 900, 4 200 and 3 700 elements respectively,
taking `indexedMap` (which is a `map2`) with them. They are now the accumulator loop `map` itself
became — a tail-recursive `mapNHelp` consing onto an accumulator, then one `reverse` — which keeps
the callback order Appendix B of [`checker.md`](checker.md) states, keeps the walk stopping at the
shortest list without calling the callback for the unmatched tail, and adds no traversal `map` does
not already pay. `tests/corpus/run/ListMapNDeep.beni` is the fixture, at a million elements each.

### Tail calls modulo cons

*Added 2026-09-30.* The loop above ends the stack overflow of an accumulator. It did not end the
overflow of the list code Elm programmers write most, where the self-call is the **tail of a `::`**
rather than the whole return value:

```elm
mapRec xs f =
    case xs of
        [] -> []
        x :: rest -> f x :: mapRec rest f
```

[Report 38 §16.4](research/38-immutable-array-representations.md) compiled eight such shapes
with this repository's `beni` and found **five of them overflowing Node's stack at 100 000
elements**: hand-written `map` and `filter`, `takeWhile`, `pairwise` and the `merge` of a merge
sort. A stack overflow is a runtime exception in a well-typed program, which the language promises
not to have, so this is §8's *mandatory* again and not an optimisation. The rewrite is the one
report 38 calls R2: **tail recursion modulo cons**, the list case of what Koka's backend does for
every constructor (Leijen and Lorenzen, *Tail Recursion Modulo Context*, 2023).

**What a step is.** Inside a function lowered by §8, a **cons step** is a call of core's `List.cons`
(what `::` desugars to, `language.md` §6) in tail position whose second argument **reaches** a tail
self-call. "Reaches" is §8's tail-position walk again, one rule longer: the tail positions of an
expression are itself, every branch body of a `case` among them, the `in` body of a `let` among
them, **and the second argument of a cons step among them**. So `a :: b :: go rest` is two steps,
`x :: (if c then go a else go b)` is one step with two jumps under it, and
`x :: (let y = … in y :: go rest)` is two steps with a `let` between. The callee is recognised
by the core package, core's `List` module and the well-known symbol `cons`, exactly as
`Basics.and` is (§4), never by its spelling — a user's own `cons` is an ordinary call. A `::` in
tail position whose tail does **not** reach a self-call is an ordinary returned value, and a `::`
anywhere else — an argument, a `let`'s bound value, `pairwise (b :: rest)` — is an ordinary
expression.

A function with at least one cons step **builds**. One that has only ordinary tail self-calls is
§8's loop byte for byte, and one that has neither is unchanged byte for byte; the gate is the same
single walk `markTails` already makes.

**The emitted shape.** A building function allocates one **root cell** before its loop and keeps a
**last cell** that starts there. A cons step writes one fresh cell per head into the last cell's
tail and moves the last cell along, then jumps exactly as §8's tail call does; every exit of the
loop writes its value into the last cell's tail and returns what the root cell's tail now holds:

```js
const Main$mapRec = ($in$0, f$2) => {
  const $root = { $: 1, a: null, b: null };
  let $last = $root;
  Main$mapRec: while (true) {
    const xs$1 = $in$0;
    if (xs$1.$ === 0) {
      $last.b = { $: 0, a: null, b: null };
      return $root.b;
    } else {
      const x$3 = xs$1.a;
      const rest$4 = xs$1.b;
      $last.b = { $: 1, a: f$2(x$3), b: null };
      $last = $last.b;
      $in$0 = rest$4;
      continue Main$mapRec;
    }
  }
};
```

The list is built **front to back**, so no `reverse` is needed and nothing is allocated that the
result does not keep, except the one root cell per call. `$root` and `$last` are positional names
like `$in$<i>`, with no counter (CLAUDE.md rule 5); a building helper nested in a building function
is its own JavaScript function, and neither reads the other's. The root cell has the cons shape and
key order, so every cell stays one hidden class (§9.4). An exit that is an ordinary tail self-call
writes nothing and jumps, so `filter`'s dropping branch costs what it costs today.

**Why the mutation is sound.** A cell written by a step is fresh, and until the `return` it is
reachable only from `$root` and `$last`, two locals of this call that no beni code can name, no
closure captures and nothing else reads. So no program can observe a cell whose tail is still
`null`, or observe it change: by the time the list escapes, every cell in it is final, and the list
is exactly the immutable value the recursive version builds. The same holds if a head throws (a
`Debug.todo`): the partial list is garbage, and nothing else ever held it.

**Evaluation order is unchanged, and that is the second invariant.** The recursive version
evaluates a step's heads left to right, then the self-call's arguments, then the next step. The
loop does the same: each head is evaluated in its own cell's statement, the cell is linked before
the next head is evaluated, and the arguments are evaluated after the last head, against the
ordinary names, by §8's assignments. A head that needs statements of its own (a `case`) emits them
in its place, after the heads written before it. A `Debug.log` in a head therefore prints in the
same place in both builds (`run/TailModConsOrder`), and §8's no-temporaries invariant is untouched:
the heads read this iteration's `const`s, never a slot.

**What else the rewrite meets.**

* **Evidence parameters** are §8's loop parameters, carried or not by the same syntactic test; a cons
  step's self-call marks them exactly as a plain tail call does, polymorphic recursion included
  (`run/TailModConsEvidence`).
* **Closures** in a head capture this iteration's prologue `const`s, as §8's closures do.
* **The release optimiser** (§9 item 1) never inlines `$root` (its initialiser is an object literal,
  not an atom) and never touches `$last` (a `let`, assigned); `$last.b = …` roots at `$last`, which
  the pass already refuses to fold through. Rename (item 2) treats both as locals.
* **`?`** cannot appear in a building function: its result is a `List`, and `?` needs a function
  whose result is a `Maybe` or a `Result` (§4). So the `return` a `?` writes never skips the root.
* **Mutual recursion** stays out of scope, as for §8's loop.
* **Other constructors.** Only `::` is rewritten. The same destination-passing works for any
  constructor whose field is the self-call (`Node l v (go r)`), and Koka does it; beni's ADTs are
  not lists in `core`'s hot paths and no measured shape needs it, so it is not done.

**What it owes the fiber lowering.** [`plans/effects-plan.md`](../../plans/effects-plan.md) §2.2
finds that a suspendable loop resumes as *an ordinary call of the same function*, because the
parameter list is the loop's whole state. **A building loop's state is the parameter list plus the
destination** — `$root`, and the cell `$last` holds at the suspension point — so its continuation
is not that call: it must close over `$root` and over the *value* of `$last` (bound to a `const`
at the suspension point, never the assigned `let`, for §8's reason), resume a loop that writes into
that cell, and return `$root.b`. That is a second entry to the loop with the destination as two
more parameters. Resumption must be one-shot, as P2 already makes it: a continuation resumed twice
would write the same private cell twice and the first result would change under its holder. If
effects ever resume a continuation more than once, a building function whose steps can suspend
must copy the cells built so far (Koka copies the context in that case) or give up the rewrite.

**`core/` as written today does not have this shape**: `map`, `filter`, `filterMap`, `take`,
`append` and `map2`–`map5` are accumulator loops followed by one `reverse` (or `foldr`, which is
`reverse` and `foldl`), and none of them is a cons step. Whether they should be rewritten into it
is measured below and is not part of this change.

### Fixtures

Every one of these is `tests/corpus/run/` unless it says otherwise; §12's rule that behaviour is
proved by running still holds, and the shape claim gets exactly one golden.

| Fixture | Intent | Observable |
|---|---|---|
| `TailCallDeep` | **the fail-first one.** A two-parameter accumulator counting to 1 000 000 | `500000500000`; overflows the stack before the fix |
| `TailCallSwap` | argument order: `swap a b n = … swap b a (n - 1)` | `2,1` then `1,2` for odd and even *n*; naive in-place assignment prints `2,2` |
| `TailCallClosures` | the capture hazard: cons a `\x -> x + n` each iteration, then apply each to `0` | `1`, `2`, `3`; in-place reassignment prints `0`, `0`, `0` |
| `TailCallNesting` | a tail call reached through `case` inside `let` inside `if`, and a nested `case` | any deep result, run at a depth that overflows without the loop |
| `TailCallNotTail` | `f n = if n <= 0 then 0 else 1 + f (n - 1)` must NOT loop, and a function with one tail and one non-tail self-call must still be right | small depths, exact answers |
| `TailCallBind` | `let m <- f (n - 1)`: the call loops, the continuation does not | `sumTo 3 (\x -> x)` is `1` |
| `TailCallEvidence` | a `where`-constrained function looping deep with evidence forwarded, **and** a tail self-call at a different instantiation whose evidence therefore changes | exact counts; the second half is the polymorphic-recursion case above |
| `TailCallLetFunction` | a `let`-bound helper counting to 1 000 000 | as `TailCallDeep` |
| `TailCallLambdaBody` | `f = \n acc -> … f …` counting to 1 000 000 | as `TailCallDeep` |
| `ListFoldDeep` | `List.foldl` over `List.range 1 1000000` and `List.foldr` over a list of 200 000 | the sums; proves the beni folds and `range` all survive |
| `emit/TailCallLoop` | the shape: label, `$in$<i>` slots, the prologue `const`, `continue`, and one loop-invariant parameter keeping its own name | the golden of §12 |
| `TailModConsMap` | *added 2026-09-30, like the rows below it.* **The fail-first one of *Tail calls modulo cons*:** `f x :: mapRec rest f`, and `filterRec` mixing a cons step with a plain tail call, over 100 000 elements | lengths, sums and small results in order; overflowed before |
| `TailModConsTakeWhile`, `TailModConsPairwise`, `TailModConsMerge` | report 38's other overflowing shapes: an exit that closes the built list with `[]`, a self-call whose argument is itself a `::`, and a `merge` with two consing branches and two exits that return the other list | as above; each overflowed at 100 000 |
| `TailModConsBranches` | two cells in one step, a different step in each branch, a `::` whose tail is an `if` with a self-call in each arm, a `let` between `::` and the self-call, a building `let` helper, and one nested in a building function | exact small lists and deep sums |
| `TailModConsEvidence` | a `where`-constrained building function forwarding its evidence, and one whose consing step recurses at a different instantiation | the second prints `0,1,1`; an evidence slot assumed invariant would compare `Box`es as strings |
| `TailModConsOrder` | `Debug.log` in two heads and in the argument, a head that is a `case`, and closures over each step's head | the log order of the recursive version, byte for byte; `10,20,30` |
| `emit/TailModConsLoop`, `emit/release/TailModConsLoop` | the shape: `$root` and `$last` before the loop, one cell per head, the exit's write and `return $root.b`, and a `::` that does not reach a self-call left alone | the goldens of §12 |

Shadowing needs no new fixture: `tests/corpus/parse/bad/ShadowingParam.beni` already refuses a
parameter named like a top-level value, which is the only way a self-call's name could be captured.

Determinism (CLAUDE.md rule 5) falls out: the label is the declaration's name, the slot names are
parameter positions, and nothing in the loop consults a counter that parallel work could reorder.
The `--jobs=1` / `--jobs=8` comparison covers it with no new machinery.

### Measurement

`bench/runtime.mjs` is the instrument. The visible effect is a follow-up rather than part of the
loop: `bench/runtime/c0/` and `c1/` split their workloads into blocks of 500 because
`List.range 1 2000` is near the stack limit, and once the loop lands those headers and their
`concatMap` scaffolding can go, which makes the R-programs shorter and their `ns_per_op` comparable
to a plain range. **What must not regress is §13's emit throughput** — the loop adds one walk of
each function body's tail positions, O(body), once — and no `run/` or `emit/` fixture that does not
involve a self tail call may change at all.

*Tail calls modulo cons, measured 2026-09-30* (Node 24.19, `--stack-size=4000`, one pinned core,
median of three rounds of nine samples; the two builds are this change and its parent, over the same
beni source). **Size:** no existing `emit/` golden moved. Of the `run/` corpus, only the two programs
that already had the shape changed (`Int32Hash`'s `xorshiftRun` and
`ConstrainedFunctionConstantRoutes`' `clampAll`), and a building function costs about 25–30 brotli
bytes more in `--release` than its recursive version: `Int32Hash` went from 1 088 to 1 117,
the whole `bench/size.mjs` release total from 233 368 to 233 726, the new fixtures included.
**Speed**, the recursive version against the loop, per call:

| shape | n = 1 000 | n = 10 000 | n = 100 000 |
|---|--:|--:|--:|
| `f x :: mapRec rest f` | 15.6 → 5.7 µs (0.37×) | 172 → 48 µs (0.28×) | overflow → 1.21 ms |
| `filterRec` | 7.7 → 3.2 µs (0.41×) | 67 → 34 µs (0.50×) | overflow → 0.32 ms |
| `takeWhile` | 12.2 → 4.5 µs (0.37×) | 123 → 43 µs (0.35×) | overflow → 0.55 ms |
| `pairwise` | 15.3 → 9.8 µs (0.64×) | 262 → 107 µs (0.41×) | overflow → 2.14 ms |
| `merge` of two halves | 13.5 → 7.9 µs (0.59×) | 158 → 80 µs (0.50×) | overflow → 1.32 ms |

The loop is faster at every size that the recursion survives, and it survives every size.
**`core/`, not rewritten:** in the same build, core's accumulator-and-`reverse` functions against
the same function written as a cons step (hand-written in beni, same callback order), per call:
`List.map` 25.0 / 213 µs / 3.05 ms against 5.7 / 48 µs / 1.21 ms (0.23×, 0.23×, 0.40×);
`List.filter` 0.21–0.24×; `List.append` (with `ys` of 10) 0.22–0.23×; `List.take` 0.36–0.41×;
`List.concatMap` 0.14–0.28×, written as one building loop over the current inner list. So once
this rewrite exists, **writing `map`, `filter`, `take`, `append` and `concatMap` directly as cons
steps would make them 2.4–7× faster** and allocate n cells instead of 2n, with no stack cost and no
`foreign` (the effects plan keeps higher-order functions in beni); `filterMap`, `concat` and
`map2`–`map5` have the same accumulator shape and were not measured.
That change is `core/`'s to make and is not part of this one.

## 9. The optimiser, ranked by compressed bytes

Report 12 ranked these by what they are worth **after compression**, which inverts the raw-byte
ranking. Build them in this order:

1. **Local dead-binding elimination** over `JsIr` before printing — one use-count pass, and alone
   worth 66% of the entire compress layer's compressed win.
2. **Short, frequency-ranked names**, emitted directly rather than mangled afterwards. Identifiers
   are 66.8% of unminified bytes.
3. **Whitespace and punctuation**, one boolean on the printer, about 19% of delivered bytes.
4. **Type-directed field ambiguation** — fields that never co-occur on a type share one short name,
   cutting the count of distinct identifiers, which is what the compressor charges for. This needs
   exactly what the checker already built and Elm cannot do it.
5. **Variable joining and conditional lowering**, both printer decisions rather than passes.
6. **Reachability elimination** (§9.1) — a traversal of a graph that already exists.

**Explicitly not built**, because they measured zero or negative after compression: boolean
shortening (`true` → `!0` makes brotli output *larger*), `if_return`, `collapse_vars`, inlining,
constant evaluation, sequence joining, comparison and switch rewriting.

**Emission order matters and is free.** Declarations are emitted in module-grouped reachability
order and names are stable across builds; a size-sorted order costs up to 7% of compressed bytes at
identical raw size.

### Reachability elimination

**Ranked sixth by compressed bytes and built first.** The ranking is right and the order is not a
contradiction: the list measures what each pass is worth *on code that is going to ship*, and this
pass decides what that is. Static dispatch made it a prerequisite rather than a win
(`fast-compiler.md` §13), and the measurement says how far: an empty program emits **188** top-level
declarations of which **2** are reachable from `main`, 47 821 bytes of declarations of which **93**
are reachable, and **22** derived functions of which **none** is. Predicted output after the pass is
about **2.1 kB in 5 files against 70 684 bytes in 19** — and `derived_bytes` exactly 0.
`tests/corpus/run/Dictionaries.beni` keeps 28 of 188 declarations and 14 472 of 48 486 bytes.
Raw figures, method and the approximation's limits are in [`plans/dce-notes.md`](../../plans/dce-notes.md).

#### The unit, and the graph

**The unit is a top-level declaration**, as `boundary.md` §7.1 requires and for the reason it gives:
Elm solved this and then lost it by keying a whole kernel file to one node. There are exactly three
kinds of node, all of them things that occupy bytes in an emitted `.mjs`:

| Node | Identity | Emitted by |
|---|---|---|
| a value declaration | `(Graph.Index, Bir.DeclIndex)` for a `Decl` of kind `.value` with a body | `Lower.declaration` (`src/js/Lower.zig:564`) |
| a foreign binding | `(Graph.Index, Bir.DeclIndex)` for a `Decl` of kind `.foreign_value` | the sibling `import` (`:688-695`) |
| a derived function | `(Graph.Index, Dispatch.Derived index)` | `synthesisedValues` (`:1886`) |

And four things that are **not** nodes, each because it has no separate existence in the output. A
`type`, a `type alias` and a `foreign type` emit nothing (`:571-575`). **A constructor is not a
node**: it is an object literal at its use site, so there is nothing to keep or drop and a
constructor mentioned only in a pattern needs no edge to survive. A **`$$order` table** is not a
node: `orderTable` is reached only for a row whose arrow was built (`:1911`), so it lives and dies
with its `compare`. The three **primitive comparators as values** — `eq$prim`, `compare$prim`,
`compare$char` — are not nodes either: `Lowerer.needs` discovers them during lowering, which now
runs over survivors only, so they are emitted iff a surviving body wanted one.

**The edges.** Out of a value declaration `d` of module `m`:

1. every `Bir.refs` row of `d` whose kind is `top_value` → `(m, ref.a)`. This is the §9.1 byproduct,
   already deduplicated per declaration and in source order, already walked by `emissionOrder`
   (`:524`). **`refs` is not enough on its own, and leg 2's instruction walk reads `.top` as well.**
   `refs` records a reference by the NAME the source wrote, and an operator writes none: `0 - n`
   lowers to `call(import_value Basics.sub, …)` with an `import_value` row, and inside `core/Basics`
   itself `Resolve` rewrites that instruction to a plain `top` while the row stays symbolic — the
   same asymmetry leg 2 is about, one module further in. Reading `refs` alone leaves `Basics.negate`
   naming a `Basics.sub` this pass deleted; six `run/` fixtures fail without it. *(Found in
   implementation; the `refs` walk stays, being the cheaper half, and a duplicate edge costs one
   bitset test.)*
2. every `ext_value` instruction in `bir.insts[d.inst_start .. d.inst_end]` → the declaration behind
   that interface value: `Resolve` has already rewritten the instruction to carry
   `(Graph.Index, Interface.ValueIndex)` (`src/resolve/Resolve.zig:303-309`), and
   `Interface.Provenance.valueDecl` (`src/resolve/Interface.zig:309-313`) turns the second half into
   a `Bir.DeclIndex`. A declaration's instructions are contiguous (`Bir.Decl.inst_start`/`inst_end`,
   the same fact `Dispatch.sitesIn` rests on), so this is a slice walk.
   *Alternative rejected: reading `refs`' `import_value` rows, which are symbolic `(module symbol,
   name symbol)` pairs that `Resolve` never rewrites — re-deriving that lookup in the backend is a
   second copy of resolution, and a copy that drifts drops an edge, and a dropped edge is a
   `ReferenceError`.*
3. every **dispatch site** of `d` — `Dispatch.sitesIn` over `d`'s instructions — its callee term and evidence roots, and, recursively through
   each term's `args` (`checker-v2.md` §13.3), every term nested in one. **These are the edges `Bir` deliberately does not
   have** (`frontend.md` §3.6, `static-dispatch-spike.md` §1.4): a method call's callee is not known
   until the checker runs, and evidence arguments are references that no source line spells. Target
   by target: `top {decl}` → `(m, decl)`; `ext {module, value}` → that module's declaration, through
   the same provenance as leg 2; `derived {index}` → `(m, index)`; `ext_derived {module, type,
   kind}` → that module's `Derived` row for the pair; `param k` (v1's `evidence k`) and `field`
   add no edge, because each is a parameter or a property read.

   **`primitive` and `err` DO add one, and that is a correction to this list.** Both were written
   here as edgeless, "an operator" and "a poisoned table". That holds for `strict_eq`,
   `num_compare` and `char_compare`, which the module synthesises for itself — but `primitive
   string_compare` lowers to a CALL of core's hand-written `String.compare` (`Lower.stringCompare`
   → `Lower.coreValue`; §3.2 and A.26 route it there on purpose, because `<` on JavaScript strings
   is UTF-16 code-unit order and `String.compare` is Unicode scalar order and the two must agree),
   and `err` lowers to a call of `Basics.eq` (`Lower.partEq`'s `err` arm, the position A.66 names).
   Each is a reference to another module's declaration that no `refs` row and no `top`/`ext` target
   records. So: `primitive string_compare` → core `String`'s `compare`; `err` → core `Basics`' `eq`
   (the `err` part is now the `undetermined` term, `checker-v2.md` §13.1, with the same edge).
   Twelve `run/` fixtures fail without the first — every program that puts a `String` in a `Dict` —
   with a `ReferenceError` at load, after a build that exited 0. *(Found in implementation.)*

   **And one site adds none: an `==` or `/=` written as a tag and field test in place** (§4,
   *`==` against a constructor is a tag and field test*, amended 2026-09-30), which calls neither
   its callee nor anything the callee's evidence names. `Reach` asks `CtorEq.inPlace`, the
   decision `Lower` takes, and passes it to `Edges.declEdgesExcept` as a site filter.

Out of a **derived function** row `r` of `m`: every term of `r.body` (`argsAt(r.body)`), recursively, by the
same mapping — that is how a derived `eq` for `type T = T (Maybe U)` reaches `Maybe`'s row and `U`'s.
Out of a **foreign binding**: nothing; its body is in a sibling file this pass does not read.

This is `collectTops` (`:555-562`) widened from `top` to all four target kinds and given a
cross-module leg, so the eta-expanded evidence closures of §6 need no rule of their own: an
eta-expansion is built from a site's targets, and the targets are the edges.

**The three legs are `check/Edges.zig`, shared with `check/Cycles.zig`** (`checker.md` §6.7),
which asks the same question of the same two tables one module at a time. It was written twice
until 2026-09-19, with only a "these two must agree" comment in each header behind it — and the
edge set above had already lost three edges once, to a spec this document corrects in place.
`Edges.zig` lives under `src/check/` because it is a pure function of `Bir` and `Dispatch` and
because `Cycles` may not depend on the backend, where this pass already depends on `check/`. It
yields a declaration's targets as a flat tagged stream — `top d | ext (module, value) | derived r
| ext_derived (module, type, kind) | primitive p | err` — into a buffer this pass owns and
reuses; this pass maps all six onto `Node`s, resolving the cross-module ones against the
provenance and dispatch tables `Cycles` does not have, and `Cycles` keeps `top` alone. A fourth
leg — effects and §10's chunking will each want one — is a tag added once, and the exhaustive
switch in each consumer is then what makes both answer for it. *(Materialising the stream where
the old code appended straight to its node list costs `eliminate` about 0.2 ms on a 633-module
build, 1.0 ms → 1.2 ms, ReleaseFast, min of nine, ABBA; the `emit` phase that contains it does
not move, 27 ms either way.)*

**Where it runs.** A new whole-program pass in `src/js/`, called from `Emit.run` between `findEntry`
and `emitModules` (`src/js/Emit.zig:147`, `:155`), producing one bitset per module over each of the
three node kinds — **two bitsets, not three**: a value declaration and a foreign binding are both
`(Graph.Index, Bir.DeclIndex)` and cannot collide, so the count above is of KINDS and not of sets.
`Lower.Input` gains that per-module pair; nothing else about lowering
changes. It runs **before lowering, not after**, for three reasons: an unreachable declaration is
then never lowered at all, which makes the pass pay for itself in emit time rather than cost
anything; the graph is a function of `Bir` and the dispatch table, both of which M4 can cache per
module, where `JsIr` is the emit unit itself; and §10's colouring wants the same graph, before
anything has been assigned to a file.

**Determinism and parallelism.** Per-module edge lists are built **in parallel**, one job per
module, each writing only its own slot — the same shape as every other per-file phase. *(As landed
they are: each list is a pure function of that module's `Bir` and dispatch table, built on the
emit workers by one `Reach.Builder` per thread and written only into its own slot.)* The
**reachability walk is serial**, because a fixpoint over a whole-program graph is, and it is
nothing: 278 nodes for the null program, O(declarations) at any size, microseconds against §13's
800 ms budget. Node identity is input-derived end to end — `Graph.Index` comes from the sorted path
(CLAUDE.md rule 5), a declaration index is source order, a `Derived` index is the sorted-by-name
order §7.1 of the spike fixes before anything indexes it — and the pass's output is a *set*, so
visit order cannot reach the bytes. `--jobs=1` against `--jobs=8` covers it with no new machinery.

#### Roots

- **`main` of the entry module**, found as it is today (`Emit.findEntry`, `src/js/Emit.zig:541`).
  In an application build it is the **only** root.
- **Whatever the platform calls back into.** Today that is `main` and nothing else: the artifact is
  `_main.mjs` handing `main` to the runtime's `run` export (`:763-781`), and the runtime sibling is
  copied whole, so it needs no root of its own. When ports land (`boundary.md` B3) every port is a
  root and this line grows; nothing else in `boundary.md` §5 imposes a signature the compiler must
  keep alive.
- **`--library`: every name the root package's modules export.** A library has no `main` and its
  callers are not in the build, so its public surface is its root set — which is exactly the export
  list §5 already computes: `pub` values with a body, every nominal `derived` row, **and the entry
  declaration when a module happens to have one**. `--library` also makes `main` optional and writes
  no entry file.

  **That last clause is a correction, and §2's "a `main` that happens to exist is not special" is
  wrong as written.** §5's export list has three sources and the entry declaration is the third; a
  library build roots at the export list, so it roots at all three. What `--library` turns off is
  the REQUIREMENT for a `main` — `missing_main` does not fire, a second one is not a
  `duplicate_main`, and the
  type is not checked against the platform's `Program` — and the entry file. It does not turn off
  finding one. The evidence is this section's own acceptance: `main` is not `pub` in a single
  fixture of the corpus, so a rule that excluded it would take `main` and its `import Node` out of
  every `emit/` golden, against the measured and thrice-stated "0 of 14 change". *(Found in
  implementation.)*

**`pub` means nothing to DCE in an application build, and that is a decision.** A `pub` declaration
that nothing in this program reaches is deleted, in `Main.beni` as much as in `core/List.beni`.
`pub` is a *module* boundary, not a *program* boundary; a whole-program compiler knows the program,
and treating `pub` as a root would pin all of core forever, since every core value is `pub`.
*Alternative rejected: rooting at the entry module's own exports, which would spare the `emit/`
corpus without a flag and cost a user every derived method of every type they happen to declare in
the module they named on the command line — the nominal rows are exported regardless of the type's
`pub` (`src/js/Lower.zig:639-660`), so that rule can never drop one.*

**What a library build cannot do, stated so nobody reports it as a bug.** Measured on
`bench/corpus`: under library roots **48 of 59** derived functions survive and **10 614 of 11 790**
derived bytes, because a `pub` type's `eq` and `compare` are exported and a consumer may call them.
Elimination shrinks a *program*; it barely shrinks a *library*. That is the correct answer and not a
limitation to fix.

#### Purity, and what may be dropped

**An unreachable declaration is dropped entirely, initialiser included, with no exceptions.** The
rule is total because the premise is: a top-level beni value is pure to evaluate.

`language.md` §6, *Evaluation order* is where purity and the licence it buys are now stated for the
language as a whole — what may be dropped, what may not be reordered, and what an inliner may
substitute. This section is that licence spent on top-level declarations.

Establishing that, rather than assuming it. A top-level constant *can* have a call in its
initialiser and one does — `platform/Node.mjs` emits `const Node$done = Node$printLines({$:0,…})`,
a call of a `foreign`. What makes it safe is `boundary.md` §4's two-shape rule and §7.2's reading of
it: a `foreign` is a total pure function over admitted types or an effect *value*, effects are data
until the platform interprets them, and `printLines` returns `{code, out}` having written nothing.
`Debug.log` is the one deliberate violation in the language and it is a **function**, so its effect
happens when it is called and a call is an edge; a `Debug.log` reachable from `main` keeps
everything it names. A platform `Program` is a value like any other. So there is no top-level
initialiser whose evaluation anyone can observe, and dropping one is unobservable by construction —
which is the proof `fast-compiler.md` §9.1 claims over a bundler's `sideEffects: false` guesswork,
written down.

**Sibling modules are the one place ES module semantics could bite, and the rule is: a sibling is
imported iff one of its exports survives.** An unreferenced `import` still *evaluates* the module,
so dropping the import is a semantic change wherever the sibling has top-level effects — and none
does. Checked over all seven siblings in the repository: every top-level statement is an `import`,
an `export`, a `const`/`function` declaration or a comment, and the only module import is
`platforms/node/runtime.js` taking `node:process`. `boundary.md` §4.1's recipe already forbids the
shape that would break this (address by value, marshal to data, no reference held across a
boundary), and §4's check 3 — a sibling's references must be covered by its own imports — is what
keeps a sibling from reaching a host global at load time. If a future platform wants load-time
setup it must put it inside an exported function, and that is a rule of §4.1 and not a new one.

**Sibling-level elimination is out of scope, and here is what it costs.** A sibling is hand-written
JavaScript copied whole, so a file survives entire as soon as one of its exports is reachable.
Measured on `Dictionaries`: two of six sibling files are dropped (2 922 B), and the four that stay
carry **12 925 bytes for six reachable exports out of sixty-one** — roughly as much again as
everything the pass saves on that program. Doing better needs to know which top-level helper in the
sibling is used by which export, and reading that exactly needs a JavaScript parser, which is the
dependency `boundary.md` §4's wall exists to avoid and which check 3 is already deliberately
approximate rather than acquire. Left on the table, deliberately, with the number. *Alternative
rejected: Elm's template dialect, which buys exactly this and is the reason its kernel files are
module-granular in the first place (`boundary.md` §7.1).*

*Amended 2026-09-29: taken up for `--release` only, without a parser. A lexical pass cuts a
hand-written file to the top-level statements its imported exports reach, keeping every statement
it cannot prove inert and declining any file it cannot delimit exactly (*Hand-written JavaScript
under `--release`*, the end of this section). A development build still copies the whole file.*

#### When it runs, and what pins the corpus

**Always on, for every `beni build`.** Not release-only: `--release` is about chunking, renaming and
tags (§2), and answering "eager derivation is not shippable without DCE" for release builds alone
would leave every development build shipping fifty times its own size and every `run/` fixture
exercising a code path release does not. One pass, one behaviour, one set of goldens.

`dump --stage=…` is untouched. Every stage is `tokens`, `ast`, `bir`, `types`, `interface` or
`dispatch` — all of them before the backend — so nothing a dump prints moves, and `bir`'s `refs`
list in particular keeps printing the symbolic `import_value` rows it prints today, because this
pass reads instructions for that leg rather than rewriting `refs` (above).

**The `emit/` corpus builds with `--library`, and that is the whole pin.** Measured over all
fourteen fixtures: with `main` as the only root, **14 of 14 goldens change** and twelve also lose an
import; with the library rule, **0 of 14 change**. The difference is not cosmetic —
`emit/DerivedCompareNominal.js` is 115 lines of which 114 are derived code and one is `main`, and
its intent comment says in so many words that nothing below uses these and they are emitted anyway.
That claim is about eager derivation in the declaring module, it is still true, and a `main`-only
build would delete the evidence for it. So: `tests/corpus/emit/README.md` gains the rule that **an
`emit/` golden is a claim about the shape of a declaration and must not be contingent on something
calling it**, and the harness appends `--library` for the kind (`corpus_test.zig:472`), exactly as
it already appends `--core` for a fixture under `core/` (`:340-345`). Elimination's own `emit/`
goldens, which need an application build, go in a subdirectory the harness does not add the flag
for — `tests/corpus/emit/app/` — by the same per-fixture mechanism.

`run/` fixtures are unaffected in how they are built and **no `.expected` may change**: they assert
what the program printed, and elimination does not change that. A `run/` fixture that moves is
over-elimination, which is the failure this pass has to fear.

#### Incrementality (M4) and chunking (§10)

`fast-compiler.md` §8.2's declaration-level graph and this one are **the same graph**, which is what
§9.1 means by "build once, use three times". Concretely, for M4:

- A module's **edge lists are cacheable per module**, keyed by the cache key §8.1 already defines —
  source bytes, module identity, compiler version, direct imports' interface hashes, and
  `boundary.md` §7.3's sibling content hash. Legs 1 and 2 are a function of that module's `Bir`
  after resolution; leg 3 is a function of its dispatch table, which is a function of its own check.
  Nothing in an edge list names a thread or a completion order.
- What **reruns on every build is the walk**, because reachability is whole-program by definition
  and an edit to one module can make another's declaration dead. It is the cheap half: 278 nodes for
  the null program, O(declarations) at scale, against a re-check that the firewall may skip
  entirely. §8.2's `emit` unit is invalidated by "a change to `decl_val`, or to any representation
  decision it depends on"; **a change to liveness is one more such input**, and a declaration whose
  liveness flipped is an `emit` unit to redo whether or not its own bytes would differ.

Chunking (§10) runs on this graph and not on one of its own: an entry set is a set of roots, a
colour is the set of entries that reach a declaration, and "reaches" is this walk with more than one
seed. Pointer only; §10 is where that lives.

#### Measurement and acceptance

`bench/size.mjs` is the instrument and it needs one change, because DCE breaks one of its
assumptions. The `run/` corpus and the floor are built as they are today and their numbers simply
start meaning what they say. The **synthesised `BenchMain`** does not: `bench/corpus` declares no
`main` and the entry the script writes only imports the modules, so under `main`-only roots the
build keeps **1 declaration of 336** and the benchmark silently stops measuring anything. That path
therefore passes `--library` — `bench/corpus` *is* a library — and its line records which rule it
used. Two meanings also shift and the header comment must say so: the **floor** stops being a shared
tree every program drags in and becomes the minimum a program can ship, so `net_*` is a subtraction
against a minimum rather than against common code; and `gross_*` becomes the number that matters,
since after elimination no two programs ship the same tree.

Acceptance, all five:

1. **`derived_bytes` is 0** on the floor line and on any program that uses no `==` and no `compare`.
2. **Every `run/` fixture's `.expected` is unchanged** and every one still exits 0.
3. **Size is reported through `bench/size.mjs`**, floor and total, both directions recorded whichever
   way they come out — though on the floor there is only one direction available.
4. **Emit throughput within noise or better.** It should be better: emit is 18.7 ms of a 101 ms
   Debug build of `Dictionaries` today and 70 % of the declaration bytes it prints are unreachable.
   If it regresses, an edge list is being rebuilt where it should be built once.
5. **The determinism test is green** at `--jobs=1` and `--jobs=8`, twice each, byte-compared.

#### Fixtures

**Over-elimination is a `ReferenceError` at load or a wrong answer at a call; under-elimination is
only bytes.** Every `run/` row below is therefore a program that crashes or lies if the pass drops
too much, which is why they are `run/` and not goldens (§12).

| Fixture | Intent | Observable |
|---|---|---|
| `emit/app/DceUnusedValue` | a `pub` value and a private helper that nothing reaches, beside one that `main` does | golden: the unreachable pair is gone, the export list and the `import` line shrank with them |
| `emit/app/DceDerived` | two types, one compared with `==` and one not; the compared one's payload is a third type | golden: the unused `$$eq`/`$$compare`/`$$order` are gone and the used one is there **with the payload type's own derived function**, which is the transitive edge |
| `emit/app/DceEvidenceOnly` | a function referenced **only** as an evidence argument — never called by name anywhere | golden: it is still emitted. This is the edge `Bir.refs` does not have; without leg 3 the golden loses it and `run/DceEvidenceDepth` throws |
| `emit/app/DceCtorPattern` | a constructor of a type used only as a `case` pattern, with the type's derived methods unreachable | golden: the match compiles unchanged and the derived methods are gone — pins that a constructor is not a node |
| `emit/app/DceModuleGone` | a two-module fixture whose second module nothing reaches | golden: the entry module has no `import` of it; the harness also asserts `out/<Other>.mjs` was not written |
| `run/DceEvidenceDepth` | evidence passed down through three generic levels, the innermost comparator reached only as a `parts` target | the comparison's answer; a missing nested-`parts` edge is a `ReferenceError` at the innermost call |
| `run/DceOrderTable` | a multi-constructor type whose `compare` is reached only through a generic `List.sortWith`-shaped path | the sorted order in declaration order; dropping the `$$order` table gives `undefined[tag]` and a wrong order, not a crash — the worst failure mode here |
| `run/DceEtaEvidence` | evidence that itself takes evidence, so §6 eta-expands it, reached from nowhere else | the answer; the closure names a function that must have survived |
| `run/DceForeignThroughCore` | a `foreign` reachable only through a core function that is itself reachable only through one user call | the value; a sibling dropped one file too far is a load-time `ReferenceError` |
| `run/DceUnusedFailsNothing` | a module full of `pub` declarations that nothing reaches, beside a `main` that prints | it prints; proves the build does not need what it deleted |
| `run/DceDebugLog` | `Debug.log` in a reachable branch and in an unreachable declaration | exactly one line of log output — pins that the effect follows the edge and not the declaration |

Each is fail-first in the ordinary way: every `emit/app/` golden differs before and after, and every
`run/` row above either throws or prints the wrong thing if the matching edge is missing. The
existing fourteen `emit/` goldens are the regression half — **none of them may move** (`--library`,
measured 0 of 14), and one that does is a finding.

*As landed: the `emit/` corpus had grown to seventeen by the time the pass was written (decision
trees added `MatchNested`, `MatchSharedLeaf` and `MatchSwitch`) and **0 of 17 moved**. Two rows
above read differently from their intent, honestly rather than by construction. `DceEvidenceDepth`'s
three generic levels are numbered into ONE flat site list by §7.2, so what it isolates is leg 3
entire and not the nested-`parts` recursion; `DceEtaEvidence` is the row that isolates the
recursion, every `==` in it being written on a `Maybe` or a record so that the module's own `eq`
sits one level down inside another target's `parts`. And `DceOrderTable` reaches its `compare`
through its own `where`-constrained helpers rather than through `List.sortWith`, which takes a
comparator as an ordinary argument and would have made the edge an ordinary one.*

### The release optimiser — items 1, 2, 3 and 5

**One change, four passes, one flag** (§1). Everything here runs **only under `--release`**; the dev
build is byte-identical to today's. The measurements are
[`plans/release-notes.md`](../../plans/release-notes.md), taken by hand-applying each candidate to
the emitted `.mjs` of the corpus built before the optimiser and re-compressing — and by running every one of
the 100 `run/` programs afterwards to prove the transformed output still prints its `.expected`.

| | dev | release | |
|---|---:|---:|---|
| floor (`Empty`), raw / brotli | 2 147 / 833 | 1 874 / 783 | −6.0% |
| `run/Dictionaries.beni` | 31 495 / 7 008 | 19 971 / 5 847 | **−16.6%** |
| `bench/corpus` (`--library`) | 126 436 / 21 840 | 57 069 / 15 055 | **−31.1%**, raw −55% |

**Why the floor barely moves is the one number to read first.** A sibling is hand-written JavaScript
copied verbatim (§2) and **is never minified — not renamed, not reprinted, not parsed**, because
reading it exactly needs a JavaScript parser and that is the dependency `boundary.md` §4's wall
exists to avoid. It costs **1 643 of the floor's 2 147 bytes (76%)**, **13 773 of `Dictionaries`'
31 495 (44%)** and 14 980 of `bench/corpus`' 126 436 (12%). After the optimiser the generated half of
`Dictionaries` has fallen 17 722 → 6 198 bytes, −65%, and the siblings are **69% of what ships** —
the same answer §9's *Purity* paragraph reached about sibling-level elimination, for the same reason.

*Amended 2026-09-29: a release build now compacts and cuts the siblings — not renamed, and not
parsed, but reprinted from their tokens (*Hand-written JavaScript under `--release`*, the end of
this section). The floor's release build went 1 882 → 621 bytes.*

#### `Debug` is refused, not pinned

**The owner's decision, 2026-09-19, and it is Elm's rule for `--optimize`: a `--release` build that
reaches `Debug` is refused.** Three reasons, and the third is the one that closes the section.

- **`Debug.toString` reflects on the runtime representation** — field names, constructor tags — which
  is exactly the surface a release optimiser must stay free to change. `fast-compiler.md` §9.5 lists
  integer constructor tags as a release feature, and *Item 4* below had to carry the rule "if `Debug`
  survives reachability, renaming is off for the build". Under this decision that pin is unnecessary:
  a release build cannot contain `Debug`, so nothing has to be held back for it.
- **`Debug.log` inside a dead binding is dropped whole** by item 1, which `language.md` §6's *What an
  optimiser may assume* licenses in so many words. That is the one place a release build prints
  something different from a development build, and `tests/corpus/run/ReleaseDeadDebug` is the one
  fixture that pins it.
- **A `Debug.log` or a `Debug.todo` in a shipped build is almost always an accident.** The module's
  own documentation says it is not meant for shipping code; the compiler now says the same thing at
  the one moment the author can act on it.

With the refusal, **"a release build behaves exactly as the development build does" holds without
exception**, which is worth more than the one fixture it costs.

**The rule.** A `--release` build in which any `pub` value of `core/Debug` — `log`, `toString`,
`todo`, which is the whole module — **survives reachability elimination** is refused: exit `1`,
nothing written to `--out`, one diagnostic. It applies to an application build and to `--release
--library` alike, the roots in each case being §9's *Roots* above. A development build is untouched.

**Reachability is the definition of "this build uses it", and nothing softer is.** A `Debug.log` in a
declaration the walk drops — an unused helper, a `pub` value no `main` reaches — does **not** refuse
the build, because the build does not ship it. That answer is already computed, by the pass that
decides what ships, so there is no second notion of "use" to disagree with the first; `Live` after
the walk is read and no graph is re-derived. It is also the honest answer: the thing the rule is
about is whether the optimiser's licence and the shipped program can collide, and an eliminated
declaration is not a shipped program.

**Where it runs:** `Emit.run`, between `eliminate` and `emitModules` — after the walk, so "reaches"
means what shipped; before lowering, so nothing is lowered, nothing is renamed and nothing is
written (`src/js/Emit.zig`, `Emitter.refuseDebug`).

**The diagnostic is `debug_in_release`** (`language.md` §10, appended at the end of the catalogue),
title **DEBUG IN A RELEASE BUILD**, and **it names where**. The `Live` set says *whether*; the
instruction stream says *where* — an `ext_value` instruction naming a `Debug` value inside a live
declaration's contiguous range is a use site with a token of its own, so the region is the reference
and not the declaration. `check/Edges.zig`'s shared walk is then consulted for a live declaration the
instruction scan found nothing in, so a reference through leg 3 (a dispatch target) still refuses the
build; that site has no token and falls back to the declaration's name, which is the documented
second best. **One diagnostic with a list**, the shape `duplicate_main` set, and the list is `-`
lines, which `checker.md` §8.4's wrap leaves alone. The order is modules by `Graph.Index` — sorted
path, never argument or completion order (CLAUDE.md rule 5) — then declarations in source order, then
references in instruction order, and the region of the diagnostic is the first site. **Capped at
five**, with `… and N more.`, so a program full of logs prints a diagnostic and not a wall.

**What it costs the corpus, and what pays for it.** `Debug.log` is the only instrument `run/` has for
observing evaluation order — `EvalOrder*`, `CallbackOrder*`, `QuestionOrder`, `SortByKeyOnce`,
`ReleaseInlineOrder`, 24 of the 121 fixtures — and the `--release` second pass over exactly those is
what proved the wide inliner unsafe (item 1's rejected wider licence; four fixtures broke). So the
refusal has a way past it for the harness and only for the harness: **`--allow-debug`**, hidden, §2.
The `run/` release pass and `emit/release/` pass it **uniformly** — uniformly rather than per
fixture, because a fixture can reach `Debug` through a module it imports and no grep over its own
text would know. `tests/corpus/build/bad-release/` is the kind that does not pass it, and every
fixture there is asserted to build clean without `--release` first, so a fixture that is merely
broken cannot pass for a claim about the flag.

**`run/ReleaseDeadDebug` stays, and what it pins narrows.** Under the flag, a release build still
drops a dead binding's `Debug.log` and a dev build still keeps it, so the fixture and its
`.release-expected` still state item 1's zero-use rule out loud. What they no longer state is
anything a user can see: a build like that is refused. The mechanism is a harness-only fact from
2026-09-19 on.

#### Item 1 — local dead bindings, and the single use that follows them

One pass over `JsIr`, **per function body**, after lowering and before printing. `Reach` decided
which declarations exist; this decides what is left inside one. Two rules, one walk.

**A use count per binding.** Walk a function's statements once, counting `ident` reads of every
`NameIndex` a `const_decl` or `let_decl` introduces in that body, nested functions included — a
closure reading an outer binding is a use. `JsIr` names are `NameIndex`es and two names are equal
exactly when their indices are (`src/js/JsIr.zig:300-330`), so the count is an array indexed by
name and needs no map and no scope stack.

**The array is per TOP-LEVEL DECLARATION and not per module**, and the sentence above was written
as if it were per module, which does not work. `localName` gives every local of ONE declaration a
distinct disambiguator (`src/js/Lower.zig:1255-1271`) and then **restarts**, so `a$2` of `sum` and
`a$2` of `square` are one `NameIndex`; counted module-wide that reads as two declarations and four
uses and every fold in the module is declined. The compiler-made names are positional or
depth-derived and repeat for the same reason (`$m$k` `:447`, `$in$i` `:463`, `$t$n`/`$p$n` through
`fresh` `:365`, `$j$<d>$<b>` and `$c$<d>` `:4494`, `:4503`). The counters are therefore reset per
declaration, by a stamp rather than a `@memset`, which keeps the reset O(1) and the pass linear.

**The substitution is keyed by the USE SITE and not by the name**, for the same reason pointing the
other way, and getting this wrong is a wrong answer rather than a missed byte: with a name-keyed
table `run/MatchRowOrder`'s two functions overwrite each other's `n$2`, and the emitted code reads
`xs$1.a` where it meant `xs$1.b.a` and exits 0. So the plan is one slot per `ident` NODE.

**Zero uses: the binding is dropped WHOLE, initialiser included, whatever the initialiser is.**
`language.md` §6's *What an optimiser may assume* is the licence, in so many words: "a binding whose
value is never used may be dropped whole, everything inside it included, a `Debug.log` among it".
The pass therefore asks nothing about the right-hand side. **A call of a `foreign` is droppable**,
and the reason is not a special case: `boundary.md` §4 confines a `foreign` to a total pure function
over admitted types or an effect *value*, and an effect value is data — `Node.printLines` returns
`{code, out}` having written nothing, and the write happens in `_platform/runtime.foreign.mjs`'s
`run`, which only the entry file reaches. The two values that *can* notice are `Debug.log`, which
writes when called, and `Debug.todo`, which throws when called; both are the violations
`boundary.md` §4 names, and `language.md` §6 spends exactly this licence on them. *Alternative
rejected: a "does the initialiser call a `foreign`?" test, which would pin `Node.done` in every
platform module and is the `sideEffects: false` guesswork §9's purity paragraph exists to replace.*
Measured: **39 raw bytes across the whole corpus, in one declaration** — `bench/corpus`'s
`ExprParser.tokenizeChars`, where a `c :: rest` row binds `rest` and the body reads the list whole.
Nearly worthless today and specified anyway: it is the half that is about correctness rather than
bytes, and §7's leaf bindings are the construct that makes more of them.

**Exactly one use: the binding is inlined**, under a rule that is narrow on purpose.

| Condition | Why |
|---|---|
| the initialiser is an **atom or a member chain** — a name, a literal, or `a.b.c` on one | re-reading one repeats no work and shows nothing (§4's record-literal rule, §7's "an occurrence is a member chain, not a name") |
| the use is in the **same statement list** as the binding | crossing into a nested `if`, `switch` case or block would sink an evaluation into a branch, and crossing out is worse |
| every statement **between** them is another such binding | `language.md` §6: two evaluations that both survive may not be reordered against each other. Nothing that survives is evaluated in between, so nothing is reordered |
| no `assign_stmt` in the body targets the chain's base name | the base may be an `$in$<i>` slot, which §8 reassigns per iteration; a read of it is not a stable read |
| the use is **not inside an `arrow` or `func_decl`** nested below the binding, and not inside a `while_true` the binding sits outside of | a closure or a loop body evaluates its contents a different number of times than the table in `language.md` §6 gives |

That is the whole rule, and it is what §7's and §8's temporaries were shaped for:
`const $t$1 = $p$1.a; return f($m$0, $t$1, k$2);` becomes `return f($m$0, $p$1.a, k$2);`, and
`const key$2 = t$1.b; const value$3 = t$1.c; … return {…b: key$2, c: value$3…};` folds the whole
prologue into the literal.

**This reopens §9's "explicitly not built" list, and the measurement is why.** That list retired
`inlining` and `collapse_vars` on report 12 §2.5, where they were worth −87 and **+60** brotli bytes
on Elm's output. Elm's output had no such temporaries; §7's decision trees, §8's loop prologue and
§4's written-order record temporaries all landed afterwards and all generate them. Measured on the
stack, everything else held equal: **−412 brotli on `bench/corpus` (−2.7%)**, −123 on `Dictionaries`
(−2.1%), −1 856 over all 102 trees; before renaming and compaction it is −4.8% on its own. It is in.
**What stays out is the wider licence**: allowing any initialiser and requiring the use on the very
next statement buys −90 brotli on `bench/corpus` and **loses 15 on `Dictionaries`**, at the cost of
the one condition above that is easy to state and hard to get wrong. So the rule stays "an atom or a
member chain", and `collapse_vars`, constant evaluation and body inlining stay off the list.

**Determinism.** The pass reads only `JsIr`, visits statements in emission order, and its output is
a subset of its input with substitutions at fixed positions; no map is iterated and no counter is
shared. **Cost:** two linear walks of each function body and no sort. **No fixpoint either**, as long
as the rewriting walk runs backwards: a substitution never raises anyone's use count, and a chain —
`const x = p.a; const y = x.b; return f(y);` — collapses in one backward pass because `y` is
resolved before `x` is looked at.

*Amended 2026-09-28.* As built, the pass does not rewrite: it records one
substitution per use site and the printer follows them. It followed a chain for at most 64 steps
and then printed the name it had stopped at — whose binding the pass had dropped — so `let x1 = x0
… x130 = x129 in x130` printed, under `--release`, whatever top-level `Rename` had given that short
name. **Substitutions are path-compressed when they are recorded** (`Opt.compress`): a binding's
initialiser that is itself a substituted name records that substitution's target, so no target is
ever substituted and the printer takes exactly one step per name, whatever the chain's length. The
general rule this states: **no budget in the release optimiser or the printer may run out into
output.** A budget either bounds a search that then declines the optimisation — `chainBase`'s
member-chain depth, the single-use scan's 64 statements — or it is not a budget: `markAssigned`
walks to the root, because its give-up answer was the unsafe "not assigned". The same audit found
`boundary.md` §4's check 1 answering "concrete" when its 64-slot stack filled; it walks
the whole type now.
**Where:** inside `Emit.emitModules`, between `Lower.lower` and `Print.print`
(`src/js/Emit.zig:760-786`), on the `JsIr` the lowering just produced.

#### Item 2 — short names, emitted directly

Identifiers are 66.8% of unminified bytes and qualified globals 26.6% (report 12 §5.2), and this is
the largest single win in the optimiser: **−4 941 brotli on `bench/corpus` alone, −22.6%.** Names in
`JsIr` are `Name` records in one column (`src/js/JsIr.zig:52-54`, `:300-330`) and the printer is the only
thing that turns one into bytes (`src/js/Print.zig:172-192`), so this is a rewrite of that column
and of nothing else — no second traversal, no mangler, no string building on the hot path.

**Two namespaces, and the split is measured, not assumed.**

- **One whole-program namespace for names that cross a file**: every top-level declaration, every
  derived function, every synthesised comparator. They appear in an `import` or `export` specifier
  and the two files must agree, so one table for the build assigns them and both ends read it.
- **One namespace per top-level declaration for its locals**: parameters, `let` `const`s, leaf
  bindings, `$t$n`, `$p$n`, `$in$<i>`, `$m$k`, and the `$j$<d>$<b>` / `$c$<d>` / loop labels. The
  alphabet restarts in every declaration, skipping only the short names the globals *this
  declaration mentions* were given. Labels share the binding namespace rather than getting their own
  — JavaScript keeps them apart, and giving a label the same letter as a binding is legal and one
  table simpler.

Reusing the alphabet per declaration is worth **4 878 brotli bytes** over a single flat namespace
across the corpus. *Alternative rejected: one namespace for the whole program, which is simpler and
measurably worse, because it pushes locals into two-character names for no reason.*

**Assignment is in emission order, not frequency order, and that is a departure from the list
above.** §9 item 2 says "frequency-ranked", after report 12 §5.2, where Closure, dart2js, Scala.js
and Elm all sort by frequency. Measured on our own output, frequency ranking **loses**: 409 338
brotli against 408 538 for emission order over the corpus, 17 086 against 16 899 on `bench/corpus`,
and the same sign inside the full stack. Closure's own source says why — `RenameVars` assigns
same-length names in source order so that *"symbols declared close together are assigned names that
are quite similar. With this heuristic, the output is more compressible"* — and that effect
dominates once a local namespace is small enough that everything gets one character either way.
Emission order also discharges report 12 §5.2's stability obligation for free, where dart2js
over-allocates its pool 3× and hashes into preferred slots to buy the same property.
**What is promised is exactly this:** a name is a function of the declaration's
position in `emissionOrder` (§5) and of the binding's position inside it, both input-derived
(CLAUDE.md rule 5), so `--jobs=1` and `--jobs=8` agree and two builds of one tree agree. What is
**not** promised is that an edit renames nothing else: inserting a declaration shifts the global
names after it. That is the honest guarantee, it is what §10's cross-chunk naming needs, and
buying more is dart2js's 3× pool, which costs bytes for a property no test asserts.

**How the whole-program table is filled when modules are emitted in parallel.** Modules are
lowered and printed on the emit workers, each into a slot of its own, so the table cannot be
filled as a side effect of printing, which is what "emission order" meant while emit was one
thread. A `--release` build therefore runs in three steps: every module is lowered and planned
(item 1) in parallel, and `Rename.collectGlobals` lists the whole-program names it mentions,
once each, in the order the printer will meet them; then, serially and in module order, those
lists are interned into the table — exactly the order the one-thread walk met them in, so every
ordinal is what it was; then every module is renamed and printed in parallel against the table,
which nobody writes any more. A name a lowering invents lives in its module's overlay on the
session's interner (`InternPool.Overlay`) under a symbol no other module shares, so before a list
is interned its names are moved into the session's pool by their text: two modules that name one
derived function spell it the same and must get one short name. The output is byte-identical to
the one-thread walk at every `--jobs`.

**The alphabet** is 54 first characters — `a`–`z`, `A`–`Z`, `$`, `_` — and those 54 plus `0`–`9`
afterwards, ordered so the two sets stay as close as possible (`DefaultNameGenerator`'s reason, quoted
in report 12 §2.2: putting digits first in the non-first set *"would end up balancing the huffman
tree"*). A generated name that is a reserved word is skipped, using `Print.isReservedWord`
(`src/js/Print.zig:584`) plus `eval`/`arguments`, which that list already carries. No global to
avoid: the emitted module references no host global at all — `boundary.md` §4's third check is what
keeps the siblings from reaching one and the generated half never had any.

**What is NOT renamed**, and the list is closed:

| | Why |
|---|---|
| the `imported` half of a sibling specifier — `add` in `import { add as Basics$add } from "./Basics.foreign.mjs"` | it is the sibling's own export name, fixed by `language.md` §5.4 and enforced by `boundary.md` §4's second check. The `local` half moves freely, which is the whole point of the `as` |
| `run` in the entry file | the platform manifest's `runtime` export (`boundary.md` §5.2), read by hand-written JavaScript; `Emit.emitEntry` writes both ends (`src/js/Emit.zig:840-857`) and the `main` side of it is an ordinary global that renames |
| every property name — the `$` tag, the `a`/`b`/`c`… slots, record fields | item 4's territory, and the second slice's. `runtime.foreign.mjs` reads `program.out` and `program.code`, and `Node.foreign.mjs` walks `.$`/`.a`/`.b`, so a field can cross into hand-written code and the rule that decides which is the artifact item 4 is waiting for |
| anything inside a `*.foreign.mjs` | copied verbatim, never parsed. *Amended 2026-09-29: never renamed still; under `--release` compacted and cut to its imported exports by a lexical pass (*Hand-written JavaScript under `--release`*, below)* |

Cross-module agreement needs no new machinery: both the `import` specifier and the `export` list are
built from the same `NameIndex`es the declaration uses (`Lower.exports`, `src/js/Lower.zig:637-680`;
`need`/`needDerived`, `:743-759`), so renaming the column renames both ends. **Emission order and
grouping do not change** — report 12 §2.1 measures up to 7% of gzipped bytes for keeping related
declarations adjacent, at identical raw size, and the optimiser must not spend it.

M5's source maps read the mapping the other way: `addSourceMappingForName` carries the *original*
name in the fifth VLQ field, which is what makes a minified stack trace readable, and the printer
already asks for a name at print time — so §11's "fused into the print pass" is what keeps this
free (report 12 §6.2). Pointer only.

#### Item 3 — compact printing

One boolean on `Print.Printer`, threaded to the places that push whitespace — esbuild does it in 35
branch points and measures it as free at run time (report 12 §6.1). Worth **−1 426 brotli on
`bench/corpus` (−6.5%)** and −24% of raw. What goes:

- `indent` emits nothing (`src/js/Print.zig:162-166`).
- `" = "` → `"="`, `", "` → `","`, `" ? "`/`" : "` → `"?"`/`":"`, `": "` → `":"` in a `property`,
  `" => "` → `"=>"`, `"{ "`/`" }"` → `"{"`/`"}"` in an `object`, and the space either side of a
  `binary`'s operator (`:230-232`, `:439-449`, `:472-475`, `:482-487`).
- `"} else {"` → `"}else{"`; a keyword keeps exactly the space that separates it from what follows —
  `return x`, `const x`, `case 1:`, `typeof x`, `throw x`, `break L`, `continue L`.
- The newline after every statement goes, **except one**: a newline after each top-level statement
  stays. Measured cost: **21 brotli bytes on `bench/corpus`, 40 over the corpus, ~0.1%** — for which
  a stack trace still names a declaration by line and a diff of two builds is readable. Closure
  places newlines in similar contexts for the same reason (report 12 §2.2).

**Two adjacencies must not close up, and they are the whole of the tokenisation risk.** An
identifier, keyword or number followed by another is one token when the space goes, which is what
the keyword rule above is; and `a - -1` closing to `a--1` is a decrement. So the printer keeps one
space between two tokens whose last and first characters are both identifier characters, and between
a `binary` `+`/`-` and a `unary` `+`/`-` that follows it. Nothing else in `BinaryOp.text` or
`UnaryOp.text` (`src/js/JsIr.zig:263-298`) can merge — `typeof ` already carries its own space.

**Built as one guard on one function and not as a rule at each branch point**, because the branch
points are where it gets forgotten: every byte goes through `Printer.push`, which keeps the last
byte emitted and asks `merges` about the join. Then `return x`, `const a`, `case 1:`, `break L` and
`a - -1` are the same rule, and a construct added later cannot miss it. `/` before `/` or `*` rides
along at no cost.

**A token written in several pieces must open ONCE.** A string literal reaches the joiner as its
runs and its escapes, a template as its chunks and its interpolations, a long name as
`Module`, `$`, `base`, `$tag` — and a guard asked per piece sees `n` beside `t` inside `"one\ntwo"`
and puts a space in the middle of the string. `run/StringOps` caught exactly that. So those three
open with the first byte and continue without the guard.

**Semicolons stay, all of them.** Every newline the release printer emits comes immediately after a
`;`, so no newline is ever in a position where ASI could stand in for a semicolon and there is
nothing to elide. Dropping the last semicolon of a block would save one byte per block and
reintroduce the whole question. *Alternative rejected: omitting a semicolon before `}`, which is what
every general minifier does and what obliges it to know that a statement beginning `(`, `[`,
`` ` ``, `+`, `-` or `/` must be prefixed.* The corpus still gets fixtures for the traps, because the
claim being pinned is that the printer never creates one (below).

**Number and string literal forms do not change.** A `number` node is the source spelling verbatim
(`src/js/JsIr.zig:170-174`) and beni's numeric syntax is a subset of JavaScript's, so nothing in the
compiler re-formats a number; turning `1000` into `1e3` would touch a value the front end promised
not to, for a family report 12 measured at noise. Strings keep `Print.quoted`'s escapes (`:527-557`)
and templates `templateChunk` (`:561-577`): picking a quote character by content is worth a byte per
apostrophe and costs a scan.

**Parenthesisation is already minimal and must stay that way.** The printer computes brackets from a
precedence table and carries no `paren` node (`src/js/Print.zig:368-385`, the header at `:20-24`),
bracketing a child strictly below its parent and a left-associative operator's right operand at
`prec + 1`. There is nothing to remove. **Arrow bodies are already concise too**: `arrowBody`
(`:502-520`) prints `(a) => a` when the body is one `return`, and brackets an object literal so the
brace does not read as a block. Neither is item 5's conditional lowering and neither is new work —
they are recorded here so the implementer does not go looking.

*What compact printing must not do: reorder anything, merge adjacent `switch` labels (§7 files that
under "a printer-level win, and the optimiser's" — it is item 5's family and measured with it), or change
which node is printed. It is a whitespace decision and nothing else.*

#### Item 5 — variable joining, and the three rewrites that did not earn their place

All four are printer decisions over statement runs, measured marginally against the rest of the
slice over all 102 trees. Report 12's discipline is to drop anything that does not clearly earn its
bytes after compression, and three of the four do not.

| Rewrite | Δ raw | Δ gzip | Δ brotli | verdict |
|---|---:|---:|---:|---|
| a run of `const_decl`s at one level → `const a=1,b=2;` | −3 024 | −229 | **−274** | **in** |
| `if (c) { return a; } else { return b; }` → `return c?a:b;` | −446 | +30 | **+38** | out |
| `if (c) { x = a; } else { x = b; }` → `x = c?a:b;` | −13 | −10 | −8 | out |
| `if (c) { return a; } return b;` → `return c?a:b;` (`if_return`) | −359 | −4 | **+18** | out |

**Variable joining is in**, and it is what §8 reserved: the loop prologue deliberately emits one
`const` per carried parameter and points here, so `const xs$1 = $in$0; const acc$2 = $in$1;` becomes
`const xs$1=$in$0,acc$2=$in$1;`. The rule: a maximal run of adjacent `const_decl` nodes in one
statement list, each with an initialiser, joins into one. It reorders nothing — the run keeps its
order and a comma declaration evaluates left to right, which is the `let` bindings row of
`language.md` §6 unchanged — and it is a printing decision, so no `JsIr` node moves. A `let_decl`
does not join a `const` run and an uninitialised `let_decl` does not join at all: §7's `let $t$n;`
sits above an `if`/`else` chain and joining it with a later `const` would move a declaration past
the statements between them.

**The module body is a statement list too, and it joins**, which reads at first as a conflict with
item 3's newline after every top-level declaration and is not: the run is printed
`const a=1,\nb=2;`, so the `const ` and the `;` are saved while the line break still falls after
each declaration and a stack trace still names one. Worth 23 brotli bytes on `bench/corpus` over
joining inside bodies alone, which is the whole of the gap between the implementation and the
hand-applied figure above. Evaluation order is unchanged — a comma declaration runs left to right,
exactly as the separate statements did — and so is the temporal dead zone, since the members keep
their order.

**The three conditional rewrites are out.** The return form measures **worse** after compression on
every reading — +38 over the corpus, +18 on `bench/corpus`, +7 on `Dictionaries` — and the reason it
loses here while report 12 §2.5 measured `conditionals` at a small win is §7: a tail-position `case`
now lowers straight into statements, so the arms it would collapse routinely hold a `const` prologue
or a `return` that a ternary cannot take, and what is left is the handful where it fires and costs
entropy. The assign form is indistinguishable from zero — 13 raw bytes — because it **fires three
times in the whole corpus**, §7 having deleted the `let $t$n` / assign / `return $t$n` triple it
used to live in; building a rewrite for three sites is how a printer grows a pass nobody can retire.
`if_return` loses in both measurements, ours at +18 and report 12's at +6, and `booleans`
(`true` → `!0`), `sequences`, `comparisons` and `switches` were never on the list. Merging adjacent
`switch` labels that reach one body (§7's last bullet) is measured with this family and is **not
built**: §7's `default:` rule already removes the case that would fire most.

#### Throughput, and where the four passes sit

Measured today on this machine, `bench -- --generate=100000`, ReleaseFast: emit is **54.15 ms for
633 modules and 3 086 421 bytes of JavaScript — 54.4 MB/s, 1 914 880 lines/s** — inside a **179.6 ms**
cold build of 100 159 lines, against §13's 5 MB/s and 800 ms. The budget for `--release` is that it
**stays above §13's 5 MB/s with a factor of five in hand** — a ceiling of roughly 4× today's emit
time, which is not a real constraint: the dead-binding pass is two linear walks per body, renaming
is one pass to count and one to assign over a column already built, compact printing is strictly
less work than indented printing, and joining is a lookahead of one node. Report 12 §6.1 measured
esbuild's `--minify` as *not slower than plain printing*. **What would breach it is a sort per
function or a fixpoint**, and neither is specified. Read `--self-profile`'s `emitted_bytes` (§2)
rather than `mb_per_s`: §7 records why that metric reads backwards when output shrinks, and here it
shrinks by 55%.

#### Testing

§12 is the rule and this is its release half. **A `run/` fixture is only a behaviour guard if it is
built under `--release` too**, so the whole `run/` corpus gets a second pass: the same fixture, built
with `--release`, run under Node, asserted against the same `.expected`. Not a marked subset — the
failure mode of a minifier is a wrong answer in a program nobody thought to mark, and the corpus is
the asset precisely because nobody has to guess in advance (CLAUDE.md rule 3). **Measured cost:** one
serial pass of all 100 programs is 15.4 s (11.1 s compiler, 4.3 s Node); `zig build test-blackbox` is
67 s wall at about 2.1× parallelism, so the second pass adds roughly **7 s, +11%**. That is the price
and it is worth it.

- **`emit/release/`** is the new golden directory, for shape claims about the optimiser itself, by
  the same per-fixture mechanism `emit/app/` uses for `--library` (`tests/blackbox/corpus_test.zig:193-205`,
  `:531`): a `release: bool` on `Fixture`, set for anything collected under `emit/release/`, appending
  `--release`. Everything under `emit/` keeps `--library` and its dev golden, and **none of the
  seventeen may move**.
- **Determinism** covers `--release`: `tests/blackbox/build_test.zig:292` and `:417` build the same
  project at `--jobs=1` and `--jobs=8` and compare the whole output tree file for file; each gains a
  `--release` pair. The pass-level arguments are above; this is the machinery that proves them.

The fixtures, by intent:

| Fixture | Intent | Observable |
|---|---|---|
| `run/ReleaseDeadDebug` | a `Debug.log` in a binding nothing reads, beside one in a binding that is read, beside one in a dropped declaration (`run/DceDebugLog`'s other half) | exactly the live lines, in order — pins that the dead binding goes whole and that the surviving order did not move |
| `run/ReleaseNameCollision` | locals whose source names are JavaScript reserved words (`new`, `class`, `let`, `eval`); more than 54 locals in one declaration, so the alphabet spills to two characters; two sibling `case` branches binding the same source name; a §8 loop label beside a binding of the same source name; a declaration that mentions enough globals to push its locals past the ones they may not take | the answers; a collision is a `SyntaxError` at load or a silently wrong value |
| `run/ReleaseAsiTraps` | expressions whose printed form starts with `(`, `[`, `` ` ``, `+`, `-` and `/`, in statement position and after a `return`; `a - -1` and `a + +b` in one expression | the values; pins that the printer never needs ASI and never merges two operators |
| `run/ReleaseInlineOrder` | the inliner's own hazard: a binding whose one use is behind a surviving `Debug.log`, one whose use is inside a lambda, one whose use is inside a §8 loop body while the binding is outside it, and one reading an `$in$<i>` slot that the loop reassigns | the printed order and the values; each is a wrong answer if a condition of item 1's table is dropped |
| `run/ReleaseEverything` | one big program using every construct — reuse `bench/corpus`'s `ExprParser` or `Dictionaries` rather than writing a new one | its `.expected`, unchanged |
| the whole existing `EvalOrder*` and `CallbackOrder*` set | the regression half, run again under the flag rather than copied | unchanged `.expected`; an optimiser that reorders two surviving evaluations moves one of them |
| `emit/release/ReleaseNames` | the shape: short names, the sibling specifier's `imported` half untouched, `import`/`export` agreeing across two modules | golden |
| `emit/release/ReleaseCompact` | the shape: one line per top-level declaration, no indentation, every semicolon present, joined `const` run | golden |
| `emit/release/ReleaseInline` | the shape: a leaf prologue folded into the literal that reads it, and a binding read twice NOT folded | golden |

Fail-first is ordinary: every `emit/release/` golden does not exist before the optimiser and every `run/`
row above either throws, prints the wrong thing, or fails to build today (`--release` exits 2). The
`run/` rows that are re-runs of existing fixtures are the regression half, and one that moves is a
finding.

#### Acceptance

§1's optimiser acceptance is §9's size and throughput numbers alone. For this first slice, all five:

1. **`bench/corpus` under `--release` is at or below 15 055 brotli bytes** and `Dictionaries` at or
   below 5 847, against 21 840 and 7 008 today — the hand-applied predictions above. A real
   implementation may beat them (the measurement's renamer is conservative about scope reuse) and
   must not lose to them by more than noise.
2. **Every `run/` fixture passes under `--release` with no `.expected` change**, and every `emit/`
   golden and every `run/` fixture built without the flag is **byte-identical to today**.
3. **Sizes are reported through `bench/size.mjs`**, which gains a `--release` column measured in the
   same run as the dev one — both directions recorded whichever way they come out.
4. **Emit throughput stays above 5 MB/s of JavaScript** (§13) with the margin above; `emitted_bytes`
   is the counter that should fall.
5. **The determinism test is green** at `--jobs=1` and `--jobs=8`, twice each, byte-compared, with
   `--release` in the matrix.

Report 12 §7 item 7's exit criterion is the outer one and is not this slice's: beni's own brotli
within ~10% of beni's output piped through `esbuild --minify`. Neither `esbuild` nor `terser` is in
the flake today, so that comparison wants a pinned binary and is the measurement to run once
`--release` exists.

#### What the second slice owes

**Item 4, type-directed field ambiguation** — two fields that never co-occur on a type share one
short name, shrinking the *alphabet* rather than the lengths, which is the quantity the compressor
charges for (report 12 §2.2, §5.4). Report 12 §5.3 bounds it at **~4% of brotli'd bytes**, from
`terser --mangle-props` on Elm's bundle, and Evan's own 5–10% for Elm's field shortening.

*This paragraph and the two after it are what the first slice expected of item 4, kept because the
expectation is what the measurement had to beat. It did not: **item 4 is specified and declined**
below, under* Item 4 — field ambiguation, specified and then declined*, which also withdraws the
checker artifact and corrects the `program.out` constraint. Read that before acting on this.*

It needs something the backend does not have. §3 is explicit: the backend sees no types, and static
dispatch did not change that — `Lower.Input` carries a *dispatch table* of resolved targets, not
solved types. What item 4 wants is a **per-build field-interference artifact**: for each record field
name, the set of record types it occurs on, so that two names may share a colour iff their type sets
are disjoint. That is a checker product, computed where the record types are, delivered the way the
dispatch table is delivered — flat, index-based, one per module, merged whole-program before
lowering, exactly as `Reach` merges edge lists. Two constraints it must respect and this section
records now rather than discovering later: **a field that a sibling reads by name may not be
renamed at all** (`runtime.foreign.mjs` reads `program.out` and `program.code`; `Node.foreign.mjs`
walks `.$`, `.a`, `.b`), and the `$` tag and the positional `a`/`b`/`c`… slots are the emitter's own
representation (`slotName`, `src/js/Lower.zig:430-437`) and are already one character.

**Integer constructor tags** (§4: "tag is a string in dev, an integer in release") ride with item 4,
because both are a representation change under the flag and both are visible to a sibling —
`core/List.js` and `Node.foreign.mjs` already build and walk `{$:0}`/`{$:1}` by contract (§4's *where
the empty list comes from*), so a `$` that means something different under `--release` is a change to
that contract and needs the same artifact-shaped answer.

**Everything chunk-facing is §10's**, and it inherits two things from this slice rather than
inventing them: the whole-program name table, which is what makes a cross-chunk binding nameable at
all (report 12 §8 item 10 — stable names are what Elm gave up), and §9's graph with more than one
seed. §10 is where that lives. Chunking waits on owner decisions that are not this section's:
[`plans/m3d-plan.md`](../../plans/m3d-plan.md) §6 holds them, §10 marks each as PENDING, and nothing
here unblocks any of them.

#### Item 4 — field ambiguation, specified and then declined

**It is not worth building, and this is the measurement that says so.** Item 4 is worth **0.71% of
brotli on `bench/corpus`, 0.00% on `Dictionaries` and 0.07% over the whole corpus** — against report
12 §5.3's predicted ~4%, which was `terser --mangle-props` on *Elm's* bundle and has now been
measured on beni's. Numbers, method and the rejected variants are
[`plans/release-notes.md`](../../plans/release-notes.md) K–N; the same hand-applied discipline as the
first slice, on the release trees this binary emits today.

| tree (release) | brotli | (i) frequency | (ii) colouring | field bytes / generated bytes |
|---|---:|---:|---:|---:|
| floor (`Empty`) | 789 | 789 | 789 | 0 of 237 |
| `run/Dictionaries.beni` | 5 860 | 5 860 | 5 860 | **0 of 6 063** — it has no record at all |
| `bench/corpus` (`--library`) | 15 017 | **14 910** (−0.71%) | 14 931 (−0.57%) | 495 of 40 613 (**1.2%**) |
| 109 trees, summed | 436 547 | 436 230 (−0.07%) | 436 227 (−0.07%) | — |
| synthetic, 24 records × 10 fields | 6 734 | 5 599 (−16.9%) | **4 999 (−25.8%)** | 10 604 of 18 810 (**56%**) |

**The transformation works; the corpus has nothing for it to do.** The last row is the control: a
generated library of 24 record types with 120 realistic field names, where colouring is worth a
quarter of the delivered bytes. beni's own corpus is ADT-shaped — `Dictionaries` is 6 kB of generated
code containing **not one record literal**, and all 25 files of `bench/corpus` hold 18 distinct field
names in 96 occurrences. **The predictor is the field-name byte share of the generated half**, which
is 1.2% here and 56% there, and the win tracks it almost linearly. *The revisit trigger is a real
program above ~5%*; `bench/size.mjs` is where that number belongs when someone wants it.

**Between the two schemes, take the one with no graph.** (i) gives every distinct field name its own
short name, frequency-ranked, and needs nothing but the name. (ii) is item 4 proper — two names share
a short name iff no record carries both. Over the corpus they tie (436 230 against 436 227) and on
`bench/corpus` (i) **wins by 21 brotli**, because with 18 names and a widest record of 8 the
colouring saves no characters and only scatters the token stream. (ii) pulls ahead only where the
alphabet actually overflows: 600 brotli on the synthetic, where (i) captures 65% of its win. *So if
anyone builds this, build (i); (ii) is rejected with numbers until a program's field share earns it.*

**The unit is the source field NAME, whole-program, and never a (type, field) pair.** One name, one
spelling, everywhere. That single choice disposes of row polymorphism: `getX : { r | x : Float } ->
Float` reads `.x` on every record that has an `x`, and it stays correct without knowing which record
it was handed, because there is only one spelling of `x` in the build. *Alternative rejected: one
spelling per (record type, field), which is what "fields that never co-occur **on a type**" literally
asks for — it needs the equivalence classes of field occurrences joined by unification, those joins
happen inside whichever module unified the rows, and two modules that never meet can both unify with
a third module's open row and pick different spellings. It buys shorter names on a surface that is
1.2% of the bytes, and it is the only version of item 4 that could ever be wrong.*

**The interference graph needs no checker artifact, and §3 stands.** Nodes are field names; an edge
joins two names that appear in one record; colour greedily in descending frequency with the source
text as tie-break (rule 5). The graph is exactly the set of **record-literal key lists already in
`JsIr`**: a beni record is closed (`checker.md` §6.1), a literal names every field, record update
bottoms out at a literal, and **no `foreign` signature in `core/` or `platforms/node` mentions a
record type**, so no record enters a program from JavaScript. Every inhabited record type therefore
has a literal in a whole-program build. *That is the paragraph above this one withdrawn: the
per-build field-interference artifact it asked the checker for is not needed, the backend still sees
no types, and static dispatch's dispatch table remains the only thing `Lower.Input` carries.*

**The alphabet is `a`–`z`, `A`–`Z`, `_`, digits from the second character — and `$` is excluded.**
`core/Debug.js`'s `show` decides "constructor or record" by `typeof value.$ === "string"` and "list
or not" by `value.$ === 0 || value.$ === 1`, so a field spelled `$` changes what a value *is* to a
sibling. **A field may be `a`**: a record is a `$`-free object of fields and a constructor
(`{$:"Tag",a,b,…}`) and a tuple (`{a,b,…}`) are objects of positional slots, and no object is ever
both, so `slotName` (`src/js/Lower.zig:430-437`) costs the field alphabet nothing. Start at `a`.

**What may not be renamed, and the list is closed.**

| | Why |
|---|---|
| `program.out` / `program.code` | **not a record and never were.** `Program` is a `foreign type` (`platforms/node/Node.beni:24`); the object is built in `Node.js` and read in `runtime.js`, and **no generated `.mjs` in any of the 109 trees mentions either name**. The first slice recorded this as item 4's hard constraint; it is not one |
| the `$` tag and the `a`/`b`/`c`… slots | not fields, and already one character |
| a `<T>$$order` key | it is a **constructor tag name**, read dynamically as `M$T$$order[x]` (`Lower.orderTable`, `src/js/Lower.zig:2229-2272`; `orderLookup`, `:2282-2286`). Not item 4's — but it is worth recording that report 12 §5.4's "no `obj[dynamicString]` exists" is **false of today's output**, and the integer-tag item is where that is paid |
| anything inside a `*.foreign.mjs` | copied verbatim, never parsed. *Amended 2026-09-29: never renamed still; under `--release` compacted and cut to its imported exports by a lexical pass (*Hand-written JavaScript under `--release`*, below)* |
| ~~**every field, if `Debug` survives**~~ | below — **withdrawn 2026-09-19**: a release build cannot reach `Debug`, so there is nothing to pin |

**`Debug` was the whole of the pinned set, and the pin is now unnecessary.** The measurement below
stands and is kept, because it is what the pin was reasoned from; what changed on 2026-09-19 is the
other rule, the one this section called the owner's and declined to take. **The owner took it**: a
`--release` build that reaches `Debug` is refused (*`Debug` is refused, not pinned*, above). So the
membership test below is not needed — a release build has no `Debug` in it to notice a renamed field
— and `run/ReleaseDeadDebug`'s `.release-expected` is not deleted but demoted: it is asserted under
the hidden `--allow-debug` flag and is a harness-only fact. Item 4 is still declined, on its own
numbers; this paragraph only removes the constraint it would have had to honour.

**The measurement that found the pin, kept.** With every field renamed, **103
of the 107 `run/` programs still print their `.expected` byte for byte**. The four that do not —
`DebugLog`, `EvalOrderLiterals`, `EvalOrderRecordFields`, `QuestionOrder` — each turn a
`{ name = "Ada" }` into `{ a = "Ada" }`. Nothing else notices: `Basics.eq`'s `Object.keys` walk
(`core/Basics.js:93-108`) compares two values of **one** type, which carry one colouring, and
`List.eq`/`List.compare` touch only `.$`/`.a`/`.b`. The record-reaching `foreign` positions are the
closed list `Basics.eq`/`neq`, `List.cons`/`eq`/`compare` and `Debug.log`/`todo`/`toString`, and only
the last two read a field **name**.

There is no per-type answer available: `Debug.log : a, String -> a` is a type variable and the record
can arrive through any number of generic frames, so "which records reach Debug" is not a question the
backend can ask. **The conservative rule needs no decision and is one membership test**: if `core/Debug`'s
`log` or `toString` survives §9's reachability walk — a *foreign binding* node, §9's table — field
renaming is off for the whole build. **The other rule was the owner's, and on 2026-09-19 the owner
took it**: Elm 0.19 refuses `Debug` under `--optimize` and **beni now does too** (*`Debug` is refused,
not pinned*, above). That deletes the pin, exactly as this paragraph said it would — a release build
cannot reach `Debug`, so the membership test has nothing to protect. `run/ReleaseDeadDebug` keeps its
`.release-expected`, now asserted under the hidden `--allow-debug` flag, which makes it a statement
about item 1's zero-use rule and no longer a statement about anything a user can build.

**Every order stays SOURCE-name order, and that is what makes this a print-time substitution.** Three
places read a record's fields sorted by name and all three keep sorting on the source text:

- the record literal's key permutation (§4). Sorting on the short name is a *different* permutation,
  which changes which initialisers need a `$t$<n>`, which means dev and release would differ in
  evaluation order — the thing §4's rule exists to prevent. Hidden-class stability wants *a*
  consistent order, not a particular one, so nothing is lost.
- the derived `eq`/`compare` of a record shape: one evidence parameter per field, fields in name-text
  order, positional (`static-dispatch-spike.md` §9.2; `src/js/Lower.zig:2351-2360`) — past 4 096
  of them one array `$m`, still indexed in that order (§9.2 *The wide form*, A.87). `compare` is
  lexicographic in that order, so re-sorting on short names would make `<` answer differently in
  release than in dev.
- `Debug.toString` prints in `Object.keys` order, which is insertion order, which is the literal's.

So `Lower` does not move. The two `.fixed` name slots in `Print.zig` that carry a **property** —
`.member` at `:736` and `.property` at `:758`, the third being a sibling's own export name at `:474` —
gain a `.field` role and a table, exactly as item 2 rewrote a column.
**`Lower` must mark which of those nodes are a record's**: the printer cannot tell a field from a
tuple slot, because a tuple is a `$`-free object too (§4). The hand-applied measurement got this
wrong first and `run/Tuples` caught it in one run, which is why it heads the fixture list.

**Separate compilation, `--library`, M4.** A short name is a whole-program decision, like item 2's
global namespace, and a release build is not M4's warm path (§9) — restated, not re-argued.
`--library` is the one place the closed world fails: an exported record type can be inhabited only by
the consumer, so its literal is not in this build and the graph is incomplete, and a `--library`
build's consumer is hand-written JavaScript — a beni consumer recompiles from source — which reads
the fields by name. **`--library` pins every field.** Which means the one tree in this repository with
records worth counting is a library, and the −107 brotli in the table above is what item 4 *would*
deliver there if the rule did not apply. It would deliver **zero**.

**Fixtures, if it is ever built**, by intent: `run/Tuples` and `run/MatchRecordsTuples` unchanged (a
tuple slot is not a field); a record reaching `Debug.log` and `Debug.toString` (identical dev and
release output, or the documented rule applied); a row-polymorphic accessor over two record types
that share only the read field; one field name on two unrelated records; a record of more than 54
fields (alphabet rollover); fields spelled `a`, `b` and `$`; a derived `compare` on a record whose
source-name order differs from its short-name order, asserted through `List.sort`; a record crossing a
module boundary and one crossing into a `Dict` key; the same program under `--library`, asserting
**no** renaming. The self-check, in `Rename.verify`'s spirit: no two properties of one object literal
share a spelling (a linear scan of a property list the printer already holds), every `.field` slot
resolves, and no spelling is `$`. That an access names a field the record has is **not** checkable
here and never will be — the backend has no types, which is §3 and not a gap.

**Acceptance, if it is ever built**: `bench/corpus` at or below **14 910** brotli with the library
rule off and **byte-identical** with it on; every `run/` fixture unchanged under `--release`; emit
throughput within noise of today's **48.08 ms / 61.2 MB/s for 633 modules** (`bench -- --generate=100000`,
ReleaseFast, this machine), which a print-time table lookup cannot move.

### Hand-written JavaScript under `--release`

*Added 2026-09-29.* **Under `--release` a hand-written file — a `foreign` sibling, a platform's
program runtime, its markup runtime — is compacted and cut to the exports the build imports.** A
development build still copies each one byte for byte (§2), and does not move by a byte. This
amends three sentences above: the release slice's "a sibling … is never minified — not renamed, not
reprinted, not parsed", *Sibling-level elimination is out of scope*, and §15.1's "copied whole".

**Why.** The generated half of a browser program had been through items 1–5 and the hand-written
half had not, so it was most of what shipped. Research 39 §0.4 and §5 measured the benchmark app at
**11 697** brotli released against **5 739** when every file was run through terser, and the runtime
file alone at 6 334 of the 11 697, 8 226 of its 22 341 raw bytes comment lines. `bench/size.mjs`'s
`page` line — the empty mounted page — was 7 013 brotli, nearly all of it the runtime.

**The options, measured** on the app of `bench/ui/apps/beni` (`browser-tea`, `--release`, research
29 §12.1's method: every file the page loads, concatenated, brotli 11) and on the empty `browser`
page, both built by `master` at `76a3a0e`. The rows marked ≈ were made by running terser over the
built tree's hand-written files, to price an option before building it.

| | app raw / brotli | empty page raw / brotli |
|---|--:|--:|
| today: copied as written | 39 636 / 12 144 | 24 411 / 7 014 |
| (a) comments and whitespace only ≈ | 20 718 / 6 572 | 11 288 / 3 497 |
| (b) a pre-minified runtime, locals renamed too ≈ | 18 007 / 6 087 | 8 703 / 3 074 |
| (c) unused exports only, comments kept ≈ | 34 249 / 10 576 | 10 451 / 3 411 |
| **(a) + (c), as built** | **15 806 / 5 315** | **3 969 / 1 405** |
| terser over every file, and (c) ≈ | 14 511 / 5 133 | 3 002 / 1 225 |

**(a) and (c) together, both in the compiler, and not (b).** (c) is what the empty page is about —
it imports three of the runtime's twenty-odd exports — and (a) is what the app is about; neither
reaches the other's number alone. (b) — a minified copy of each runtime made when beni is built and
checked against its source by a test — buys the renamed locals, 400–500 brotli more, but only for
the files that ship in the box: a platform package on disk and every `foreign` sibling would still be
copied whole, and no file can be cut to one program's imports ahead of the program. It also puts a
generated twin of `platforms/browser/runtime.js` in the tree to go stale on every edit. As built,
the app is **0.24×** Solid 2's 22 131 brotli (research 39 §0.4) and within 180 bytes of terser, and
the empty page is **1 393**, which is research 36 §4.7's 1 482 for a whole client runtime of this
design, met.

**A lexical pass, not a parser** (`src/js/Minify.zig`). It is a tokenizer — strings, template
literals with their substitutions tokenized, regular expressions, numbers, punctuators by longest
match — and two passes over its tokens. `boundary.md` §4's wall exists so that the compiler never
needs to depend on a JavaScript parser, and this is not one: no tree is built and no statement below
the top level is read.

- **Compaction.** The tokens are printed verbatim, each gap rewritten. A gap that held a line
  terminator — in whitespace or inside a block comment, which ECMAScript counts as one — keeps one
  newline, unless the token before it is a punctuator that cannot end an expression (every one but
  `)`, `]`, `}`, `++`, `--`) or the token after it is one that can neither begin a statement nor a
  class element nor follow a restricted production (`)`, `]`, `}`, `,`, `;`, `.`, `?.`, `:`, `?`,
  `=>` and the binary and assignment operators except `+`, `-`, `/` and `*`). Automatic semicolon
  insertion acts only at a line terminator, so a newline is dropped only where it cannot be acting.
  Any other gap is nothing, or one space where the two tokens would otherwise lex as something else
  (two identifier characters, `+ +`, `a / /re/`, a regular expression's flags, `1 .x`).
- **Elimination.** The file's top-level statements are cut into units: an `import` to its `;`, a
  `const`/`let`/`var` to its `;`, a function declaration to its closing brace, an `export { … };`
  list. A unit survives iff it is a root or a surviving unit mentions a name it declares, where a
  mention is any identifier token that does not follow `.` or `?.` — so a local that shadows a
  top-level name keeps it, the safe direction, and a name used only inside a template substitution is
  seen. The roots are every `import` (it evaluates a module), every unit exporting a name the build
  imports, and every declaration whose initialiser is not known to be inert. Inert is a closed list:
  a literal, a read of a name the file declares (`undefined`, `NaN`, `Infinity` too), an arrow or a
  function expression, an object or array literal of inert values with no spread and no computed key
  (methods and accessors included), `new Set`/`Map`/`WeakMap`/`WeakSet` of nothing or an inert
  array, and `Math.<name>`. §9's *Purity* paragraph is why dropping a whole sibling was already sound;
  this is the same argument one statement at a time.
- **What the build imports**, per file: for a sibling, its module's surviving `foreign`s (the
  module imports exactly those); for the markup runtime, the union of every written module's markup
  imports, which `Lower` now reports (`Result.markup_exports`); for the program runtime, `run` and
  `start`, which the entry file imports, and the markup imports too when it is the same file
  (`boundary.md` §9.2). A test harness that imports some other export of the runtime directly —
  `tests/browser/driver.mjs` reads `flush` — gets it only when the program reaches it; the browser
  runtime's own render loop does, so it survives.

**Refusal, never a guess.** Every question the tokens cannot answer exactly makes the pass decline,
and a declined file is copied as a development build copies it — bytes lost, nothing else. The
tokenizer declines a `/` after `}` (a block's or an object literal's?), after `++`/`--`, or after a
contextual keyword (`of`, `yield`, `await`, `let`, `get`, `set`, `static`, `async`); non-ASCII outside
a literal or a comment; an escaped identifier; a hashbang; anything unterminated or unbalanced. A `/`
after a `)` is a regular expression exactly when that `)` closes an `if`, `while`, `for` or `with`
head, which the tokenizer tracks. Elimination declines a file with any other top-level statement
(an expression, `export default`, a class, a re-export), a declaration with a line terminator at its
own level that might be where automatic semicolon insertion ends it, and a file that mentions
`eval`. **No file in `core/` or `platforms/` is declined**, and a unit test holds that for every one
that ships in the box.

**Checks, identity and determinism.** `boundary.md` §4's four checks read the file on disk, before
any of this, as they did; compaction changes what is written and never what is checked. The output
is a function of the file's bytes and the build's import set, both input-derived, and it is computed
on the calling thread after every module is lowered, so `--jobs` cannot move it (rule 5). No cache
holds emitted bytes (`boundary.md` §7.3's key already covers a sibling's).

**Self-check.** In a safety build `Minify.verify` lexes the output again and panics unless it is
the kept tokens, each spelled as before, with a line terminator in front of every one whose newline
was not shown inert. A random sweep of JavaScript fragments under `zig build fuzz` has that as its
oracle.

**Tests.** Unit tests in `src/js/Minify.zig`, one per hazard: a regular expression against a
division (after an operand, an operator, a keyword, a statement head's `)`, a property named like a
keyword), nested template literals, the newlines automatic semicolon insertion reads (`return`, a
comment holding a line break, `++`, a class field before a generator method), tokens that must stay
apart, every refusal, and elimination's roots. `tests/blackbox/build_test.zig` pins the release bytes
of a small platform's sibling and runtime and runs the program, and pins the development build as
byte-identical; and the corpus's release passes — every `run/` program and every `browser/` page,
each held to its development golden — run every core sibling, the `node` runtime and the `browser`
runtime compacted and cut.

**Measured after**, `bench/size.mjs`: the floor's release build 1 882 / 789 → **621 / 304**; the
empty page 24 407 / 7 013 → **3 965 / 1 393** (`browser`) and 24 510 / 7 033 → **4 068 / 1 420**
(`browser-tea`); `bench/corpus` (`--library`) 96 852 / 24 015 → **83 719 / 19 516**. Renaming a
hand-written file's locals — the 400 bytes between this and terser — would need scope analysis, which
is a parser, and is left.

*Amended 2026-09-30: the locals are renamed after all, without scopes (research 40 §7's A2 and A3,
built and measured in research 41 §4).* Two more passes over the same tokens, after elimination:

- **Renaming (A2).** Every name the file binds — after `let`/`const`/`var`/`function`, in a
  parameter list (an arrow's, a function's, a `catch`'s; each element's identifier and an array
  pattern's), before `=>` — is renamed, **all its occurrences at once**, to a short name
  (`Rename.spell`'s alphabet), most used first, ties by first occurrence. It needs no scope analysis
  because the renaming is **injective onto names no other identifier of the file spells**: every
  use refers after to exactly what it referred to before, and nothing can be captured. A name keeps
  its spelling when it is exported, or named in an `import` or an `export { … }` list (the boundary
  `boundary.md` §4 fixes); when it is a reserved or contextual word or a global a file may read
  unbound (`Sibling.isStandardGlobal`'s list and the hosts' — `document`, `window`, `process`,
  `parent`, … — because check 3 cannot see a global read when the same name is bound elsewhere in
  the file); and when it **ever** stands where a property name can: before `:` (except as a
  ternary's consequent or a `case` value), or, inside a `{` that is not provably a block, as a
  shorthand, a method, a field or a pattern default. A file that mentions `eval`, `with` or `class`
  is renamed not at all. A property after `.` is never a binding and never renamed.
- **Rewriting (A3).** `;` before `}` goes unless it is an empty statement (after a statement head's
  `)`, `else`, `do`, `:`, `{` or `;`); `(x) =>` loses its brackets when the list is one identifier;
  and `const` is `let` **throughout a file whose `const` declarations name nothing the file
  assigns** — any `x = `, compound assignment, `++`/`--`, `for (x of …)` or destructuring assignment
  of the name anywhere, by name and not by scope, so the `TypeError` the only difference would
  throw cannot happen. All or none, because a partial rewrite measured **+9** brotli on the browser
  runtime, whose `let i` in one function keeps a `const i` in another.

Refusal is per name or per file, as before, and costs bytes only. `Minify.verify` holds the output
to the plan's spellings, and `zig build fuzz` runs the sweep with both passes on. Measured on the
benchmark app (research 41 §4): **5 828 → 5 467 brotli** (A2 −355, A3 −32 alone, −361 together);
the empty page 3 919 / 1 390 → **3 267 / 1 296** (`browser`), 4 013 / 1 415 → **3 361 / 1 320**
(`browser-tea`); the floor 619 / 303 → **525 / 279**; every program's release build summed
(`bench/size.mjs`'s `release_gross`) 225 221 → **216 198**, −4.0 %. A development build still copies
each file byte for byte. Tests: `Minify.zig`'s A2/A3 unit tests (every refusal, the empty-statement
cases, an assigned `const` each way), `build_test`'s pinned release bytes of the `hand` platform,
and `run/SiblingFunctionParams`, a `function f(a, b)` helper renamed and run.

### One scope-hoisted file under `--release`

*Added 2026-09-30 (research 41 §5.1, and its addendum §8).* **A `--release` build of an
application writes one file**: the entry file (`_main.mjs`, or the platform's `"entry"`), holding
every emitted module, core, the derived-comparison engine, every sibling, the markup runtime and the
program runtime in one module scope, with no `import` or `export` between them. It is §5's own
sentence — "with one entry point and no `lazy`, that is one file" — reached before §10's colouring,
and it is §10's one-entry case: a chunk is one such file (*What §10 gets from this* below). A
development build and a `--library` build are unchanged, byte for byte: one `.mjs` per module, the
hand-written files beside them. (`--library` keeps its layout because its exports ARE its surface,
§9's *Roots*: a hoisted library needs an export list of the one file, which is §10's.) Measured on
the benchmark app, **5 467 → 5 196 brotli** (11 files → 1; Solid 1's bundle is 4 356).

**The order is ES module evaluation order, exactly.** The files the multi-file layout would write
and their `import` statements form a DAG: an emitted module imports its sibling, the engine, the
markup runtime and other emitted modules; a hand-written file imports only bare specifiers (§2's
rule against a sibling importing a file). ES evaluates that graph depth first from the entry file,
each file after everything it imports, each import in statement order, each file once — post-order.
The one file is that post-order: each piece's body with its `import`s and `export`s removed, then
the entry file's own statements (`start(…)`, `run(main)`). The order is read from the lowered
modules' `import` statements, which are printed in body order, so it is the multi-file build's by
construction, not by argument — which matters, because not every top-level initialiser is inert: a
`Debug.log` in a top-level value runs when the module is evaluated (`--allow-debug`'s corpus pass
observes it), and so does anything a hand-written file keeps as a root. Any other topological order
is not good enough: `run/HoistEvaluationOrder` has `Main` name `Zed` before `Alpha`, both importing
`Mid`, and logs `Mid`, `Zed`, `Alpha`, `Main`; walking imports in the other order is still
topological and prints `Alpha` first (it was, red, before the order was read this way).

**Names: one namespace, §9 item 2's table.** Every top-level name of the one scope is an ordinal of
the whole-program table, which a multi-file release build already fills; the `import`/`export`
pairs between emitted modules simply disappear, because both ends were one `Name` and so one
spelling. What is new is the hand-written files' top-level bindings, which join the table:

- **Numbering.** The emitted modules' names first — module by module in the one file's order, each
  in print order, as a multi-file build numbers them — then each hand-written file's top-level
  bindings, file by file in that order, each file in source order. A binding an emitted module
  imports is spelled as the name the module imports it as (`add` in `Basics.js` IS `Basics$add`'s
  short name), and the whole file renames every occurrence of it to that spelling; a binding nothing
  imports is keyed `$hoist$<file>` and takes the next ordinal. *Measured, research 41 §8: numbering
  every piece in place was 5 264 brotli on the app, emitted names first 5 226, and each file in its
  own order rather than A2's most-used-first 5 196; most-used-first across the whole program, 5 247.*
- **Capture.** Renaming is sound for the reason A2 is (research 40 §7): a file's renaming must be
  injective onto spellings nothing else in the file keeps. So a top-level binding's ordinal may not
  spell any identifier the file writes and does not rename (A2's `taken`: keys, fixed words, globals,
  the names of its `import`s); `Rename.Globals.internAvoiding` skips such an ordinal for that name
  only, and hands it to the next name without the constraint. The file's other names are renamed by
  A2 as before, avoiding its top-level spellings too.
- **Free names.** No ordinal of the table may spell a name some hoisted file may read without binding
  it — an identifier bound nowhere in the file, or a host global of A2's fixed list, not a property
  after `.` or `?.`, and not a key `x:` after `{` or `,` — nor a name a hand-written file keeps as
  written or a host `import` binds (`Rename.Globals.skip`). An emitted file reads no global but
  `undefined`, which the alphabet never spells (§9 item 2).
- **What stays as written.** A top-level binding A2 may never rename (it also stands where a property
  name can, or is a fixed word) keeps its spelling in the one scope; it must then be unique there and
  no other file's free name, and a module that imports it under a short name reads it through
  `let <short>=<binding>;` after the file — a copy, allowed only when the file assigns the binding
  nowhere (by name, A3's rule), since an `import` is a live binding. A second name importing the
  same export is the same alias. Otherwise the file keeps its own module (below).
- **Generated locals** need nothing new: a declaration's locals skip exactly the globals it mentions
  (§9 item 2), and a hand-written file's top-level bindings are mentioned only through the names
  emitted code imports them as.

**Host imports.** A hand-written file's `import` of a `node:` built-in moves to the top of the one
file, once per distinct statement text; a built-in's evaluation is not observable to the program, so
evaluating it first moves nothing anyone can see. Of two files binding one name from different
statements, the later keeps a module of its own, and so does a file whose `import` binds a name
another file reads freely. Any other bare specifier — a package, which may do anything when
evaluated — keeps its file in a module of its own.

**What keeps a module of its own, and what keeps the multi-file layout.** A hand-written file is
*declined* — written as the multi-file layout writes it and imported by the one file with
`import{export as short}from"./path";` — when `Minify.Hoisted.declines` says so: it mentions `eval`,
`with` or `class` (A2 renames nothing there), a top-level declaration destructures a pattern (names
the units do not list), it mentions `import` outside a top-level `import` statement (`import.meta`
and `import()` mean the file they are in), it imports a module other than a `node:` built-in, or one
of the name rules above cannot hold. A declined file is evaluated before the whole of the one file
rather than where it stood, which is invisible only when evaluating it does nothing: every surviving
unit but an `import` must be inert (§9's elimination roots) and every `import` a `node:` built-in.
**When a declined file is not, or when a hand-written file cannot be read exactly at all** (the
tokenizer or elimination refuses it), **the build keeps the multi-file layout**, whole — the release
build of before this section, byte for byte. A refusal costs bytes, never order. No file in `core/`
or `platforms/` is declined, and a unit test holds that for every one that ships in the box and for
the engine.

**The entry file's calls and the runtime's `flush`.** `start(…)` and `run(main)` are written by the
names the runtime's bindings have in the one scope (`run` and `start` as written when the runtime is
declined, imported as `import{run,start}from…` — the form `tests/browser/driver.mjs` looks for).
Nothing else is exported, with one exception: the program runtime's `flush` (§15.11), when its
render loop kept it, is exported from the one file under its own name — it is the page's to call
and not the program's, and a test harness or an embedding page reaches it through the module the
page loads, which is now this one (`tests/browser/driver.mjs` falls back to the entry file itself
when it imports no runtime; `bench/ui/lib/serve.mjs`'s micro pages time the one file's evaluation).
This amends §9 item 2's closed list: in a hoisted build `run` in the entry file and the `imported`
half of a sibling specifier are no longer spelled at all, and a hand-written file's top-level names
ARE renamed.

**What §10 gets from this.** The linker (`Emit.planHoist`, `numberHoisted`, `linkHoisted`) takes the
pieces it joins as a list in evaluation order, and a chunk of §10 is one such list: the colouring
decides which pieces (declarations, once §10's assembly splits modules) a chunk holds, the order
within it is still the evaluation order restricted to them, the names are already whole-program, and
a cross-chunk binding is an `import`/`export` pair the linker writes for a name that crosses — the
same one a declined file gets today. §10's *Where everything else goes* rows for siblings and the
runtime are amended accordingly: they join the chunk that uses them.

**Determinism.** The order is a function of the lowered modules' `import` statements, and the names
of the table filled serially in that order; the hand-written files are read on the calling thread
after lowering. `--jobs=1` and `--jobs=8` write the same bytes (`build_test`'s byte-identical builds
include release applications).

**Tests.** `emit/release/app/HoistOrder` (a golden of the whole one file: a four-module program, core
siblings and the `node` runtime); `run/HoistEvaluationOrder` (cross-module top-level `Debug.log`, red
under a merely topological order); `build_test`'s pinned one file of the `hand` platform, a declined
sibling imported by the one file, a declined sibling that is not inert keeping the multi-file layout,
and an export kept as written reached through an alias; `external_platform_test`'s toy runtime with
`start` and `run`; `Minify.zig`'s unit tests for `hoistable` and `printHoisted` and the fuzz sweep
with `printHoisted` in it. Every `run/` and `browser/` fixture's release pass is now a one-file build
and prints its development golden, under Node, happy-dom and (`zig build test-browser`) Chrome.

**Measured** (research 41 §8): the benchmark app 15 372 / 5 467 → **14 484 / 5 196** raw / brotli,
1.26× Solid 1 → **1.19×**; the floor 525 / 279 → **313 / 203**; the empty page 3 267 / 1 296 →
**2 922 / 1 206** (`browser`) and 3 361 / 1 320 → **2 941 / 1 217** (`browser-tea`); every
program's release build summed (`bench/size.mjs`'s `release_gross`, 276 programs) 864 313 / 257 479
→ **699 082 / 206 309**, −19.9 % brotli.

## 10. Chunking

**Release output is chunks; development output is not.** §9.5 of the design doc settles that with
"two build modes, one graph", and chunking is what makes the second half true. A chunk is a file; a
declaration's chunk is decided by which entry points reach it; and **with one entry point and no
`lazy`, a release build is exactly one file**, which is the degenerate case of everything below and
the part of this section worth the most bytes.

**What is PENDING an owner decision, and nothing here quietly assumes an answer.** The `lazy` marker
is specified in `fast-compiler.md` §9.5 as rewriting a declaration's type to `Task LoadError a`, and
that section's own block quote says the type is gone. A deferred load is asynchronous, this language
is synchronous and has no effect system yet, and there is therefore **no way to express a deferred
value in the language as it stands**. [`plans/m3d-plan.md`](../../plans/m3d-plan.md) §2 is the
argument and §6 the decisions: whether `lazy` is a keyword, a contextual word or neither; whether it
waits for `plans/effects-plan.md`'s E1–E3; whether a build may carry more than one entry point. Until
those are taken, this section specifies the chunker and **not** the trigger. Everywhere below, "an
entry" means a declaration in the seed set, and how a declaration gets there is PENDING.

### The colouring

Entry points are **the entry declarations of the build** — today `main`, and whatever §6's decisions
add. Each node's colour is the set of entries that reach it; nodes sharing a colour share a chunk.
**"Reaches" is §9's walk with more than one seed, over §9's graph** — the colouring adds a lattice,
not a second graph. Declaration granularity is proven in four whole-program compilers and Closure's
four safety guards for it are vacuous in a pure language (report 12 §3.2).

Mechanically it is §9's pass run once per entry and transposed: `Reach.run` already returns two
bitsets per module over input-derived node identities (`src/js/Reach.zig:103-123`), so node *n*'s
colour is the `|E|`-bit vector of which runs marked it, and **§9's liveness is the OR of those bits**
— one machine, both answers, no second walk. Colours are **interned**: dart2js measured 401 deferred
imports producing 2.9 million import-sets and a five-gigabyte heap without it, and GWT and Rollup
found the same late. At `|E| ≤ 64` a `u64` key into a hash map is `ImportSetLattice` at a thousandth
of the code; the trie is what is needed past that, and the cost of the walks is `|E| × O(nodes)`
against a pass §9 measures in microseconds.

**Every colour containing the main entry IS the main chunk.** dart2js's rule and its reason, quoted
in report 12 §3.1: code reachable from `main` is loaded "possibly synchronously", so splitting it out
buys a chunk that is always fetched. One consequence is worth stating because it removes a whole
class of bug: **the main chunk has no outgoing cross-chunk edge.**

**The chunk graph is a DAG by construction.** If `d → e` then every entry reaching `d` reaches `e`,
so `colour(e) ⊇ colour(d)` and a chunk imports only from chunks whose colour is a strict superset.
Rollup's `CIRCULAR_CHUNK`, Scala.js's `maxExcludedHopCount` and its two-of-three "(unproven)" lemmas
(report 12 §3.3) are all repairing a property the colour order gives here for free.

### The merge

A merge pass follows, budgeted by compression rather than by request count: four chunks cost about
6.6% of compressed bytes and sixteen about 18% before any chunk has saved anything (report 12 §2.6).

**Folding a chunk is promoting its entry, never moving its declarations.** Moving them breaks the DAG
property, because relocated code still references colours the destination does not contain and the
repair cascades — which is precisely why *"every fixup demotes the atom to leftovers"* in GWT. So: an
entry whose chunk does not repay a split is **added to the main entry's seed set and the colouring is
re-run**, to a fixpoint, candidates considered in canonical entry order. That is dart2js's
`ImportSetTransition` (report 12 §4.2) used as the merge mechanism, and it cannot produce a cycle.

**The threshold is provisional and says so.** A candidate chunk is kept iff its private content is at
least **4 096 raw bytes and 5% of the program's raw bytes**. Both numbers are inferred from report
12 §2.6's table and dart2js's 1 080-byte empty part, not measured here: report 12's open question 2
— *"the biggest unquantified risk in the chunking plan"* — is that nobody has measured what
declaration-granular colouring produces, and there is still no beni program large enough to say.
Re-derive from `bench/size.mjs` on the first one that is.

### Assembly, and what a chunk file contains

Lowering does not change. A module is lowered to `JsIr` exactly as today and a chunk is assembled
from the result: `JsIr.body` is *"the `import`s first, then one declaration per emitted value, then
one `export`"* (`src/js/JsIr.zig:57-62`), and `import_stmt` and `export_stmt` are their own tags
(`:117`, `:119`), so the assembler **drops them and writes its own**. `Print.print` gains an entry
point that prints a given list of statements into a caller's buffer; it prints `ir.body` today
(`src/js/Print.zig:73-78`).

- **Order within a chunk is module-topological, then `emissionOrder`.** In separate files ESM orders
  the modules; in one file nothing does, and a `const` read before its initialiser is a temporal-dead
  zone `ReferenceError` at load — the failure §9's own `run/` fixtures exist to catch. The module
  graph is acyclic and a cross-module reference only exists along an import edge, so the two orders
  compose. Emission order is otherwise unchanged: report 12 §2.1 measures up to 7% of compressed
  bytes for keeping related declarations adjacent, and §9's namer already spent that.
- **Nothing is renamed by chunk assignment, and that is the whole reason this is cheap.** §9's namer
  puts every name that can cross a file in one whole-program namespace, assigned before any chunk
  exists, so a declaration's name does not depend on where it lands. Rollup pays `deconflictChunk.ts`
  (266 lines) for this and Elm's LCI-plus-renaming is what report 12 §3.3 identifies as *"Elm's actual
  blocker"*. Confirmed on today's dev output too, where names are `Module$name` and already unique.
- **Cross-chunk bindings are synthesised by the assigner, inside the pass.** Closure is the only
  other system doing declaration-granular chunking with an ES-module mode and the combination is
  broken there because it relocates declarations without emitting the bindings
  (closure-compiler#4264, open); esbuild's `computeCrossChunkDependencies` is the model. By the DAG
  property, every such binding is a static `import` from a less-shared chunk into a more-shared one.

### Where everything else goes

| Thing | Chunk | Why |
|---|---|---|
| the main chunk | **`out/_main.mjs`**, with the platform's `run(main)` call last | it is already the file `Emit.emitEntry` writes, so the artifact path does not move — §2's rule 1 renamed it from `out/main.mjs` on 2026-09-21 and chunking inherits the new name, not a second one |
| a colour that is one entry | `out/chunk/<Module>.<name>.mjs` | input-derived and readable: it names the declaration the author marked |
| a colour of two or more | `out/chunk/shared.<i>.mjs`, `i` the colour's index in canonical colour order | input-derived; **no content hash**, so a golden is stable and rule 5 is met by construction |
| a derived `eq` / `compare` | coloured like any other node (`Reach.Kind.derived`) | §9 already makes it a node |
| a `$$order` table | its `compare`'s chunk | *"lives and dies with its `compare`"* (§9); not a node |
| `eq$prim`, `compare$prim`, `compare$char` | emitted per chunk that wants one | discovered by `Lowerer.needs` during lowering, not nodes (§9); three small functions, and duplicating beats a cross-chunk edge |
| an eta-expanded evidence closure | the chunk of the declaration whose site built it | not a node; *"an eta-expansion is built from a site's targets, and the targets are the edges"* (§9) |
| a `*.foreign.mjs` sibling | **its own file, unchunked**, at today's path; every chunk using one of its exports imports it | a sibling is copied whole and never parsed (`boundary.md` §4). ESM evaluates a module once, so duplicate imports cost specifiers and nothing else. Measured cost of not folding siblings into the bundle: 1 215 brotli bytes on `run/Dictionaries`, where the seven siblings are **54% of compressed output** — left on the table deliberately, because separating two siblings' scopes needs a JavaScript parser |
| `_platform/runtime.foreign.mjs` | its own file, imported by the main chunk | *"copied whole, so it needs no root of its own"* (§9) |
| *(amended 2026-09-30)* a sibling, the markup and program runtimes, the derived engine | **in the chunk whose pieces import them**, their top-level names in the whole-program table, unless one must keep a module of its own | the two rows above are superseded for the one-chunk case built in §9, *One scope-hoisted file under `--release`*: a lexical pass renames a hand-written file's top-level names without a parser, so separating two siblings' scopes no longer needs one; a file it declines keeps its own file, as those rows say |
| a `--library` build | **one chunk** | a library's callers are not in the build, so there is no entry set to colour by; §9 already measures that elimination barely shrinks a library |

### Determinism, M4 and M5

**Determinism needs no new machinery.** Entry order, node identity, colour order and chunk names are
all functions of sorted paths and source order (CLAUDE.md rule 5), and the colouring's output is a
*set*. `--jobs=1` against `--jobs=8` covers it exactly as it covers §9, with `--release` in the
matrix.

**M4 and chunking never meet.** Chunking is release-only and release is not the 15 ms warm path, so
"one edit rewrites one small file" (`src/js/Emit.zig:6-10`) remains true of the mode that promises
it. The cacheable unit is what §9 says — per-module edge lists, per-module `JsIr` — and a chunk file
is a concatenation of already-lowered statements. What a release build cannot cache is the name
table: §9 promises only that a name is a function of position in `emissionOrder`, so inserting a
declaration shifts every name after it. That is a stated non-guarantee and not a regression.

**M5 needs nothing new either.** §11's *"per-file chunks rebased once at join time"* is chunk
assembly: mappings are recorded at print time and rebased by the chunk's running line offset, one
`.map` per chunk file.

### Measurement, acceptance and fixtures

**`bench/size.mjs` cannot see chunking today and must be changed first.** `measureTree` concatenates
every `.mjs` under `out/` and compresses the concatenation (`bench/size.mjs:255-279`), so its
headline `brotli_bytes` is *already* the idealised single-file number. It gains **`split_brotli_bytes`
— the sum of per-file brotli — and `files`**, and chunking's win is the distance between them
closing. Measured today on dev builds: `run/Dictionaries` is 20 files, 11 908 brotli summed against
9 290 concatenated (**−22.0%**, −26.5% once module headers go); hello world is 5 files, 1 152 against
835 (**−27.5%**). Those are the numbers the single-chunk case has to reach.

Acceptance:

1. **A release build of a single-entry program writes one `.mjs` plus siblings and the runtime**, and
   its `split_brotli_bytes` equals its `brotli_bytes`.
2. **Every `run/` fixture passes under `--release` with no `.expected` change**, which §9's release
   testing already runs; a chunked build is a third pass over the same corpus, not a new one.
3. **Every `emit/` and dev golden is byte-identical**: chunking is release-only.
4. **The determinism test is green** at `--jobs=1` and `--jobs=8`, twice each, byte-compared, with
   `--release` in the matrix.
5. **Emit throughput stays above §13's 5 MB/s.** Assembly is a copy per statement and an interning
   pass over `|E| × nodes` bits; what would breach it is a fixpoint per declaration, and none is
   specified.

Fixtures, and the failure each one is about. `emit/release/ChunkSingleFile` — one file, no `import`
of a generated module, sibling imports hoisted, `run(main)` last. `emit/release/ChunkOrder` — a
three-module diamond that throws a temporal-dead-zone `ReferenceError` at load if assembly order is
not module-topological; it is `run/`-shaped rather than golden-shaped for the reason §12 gives.
`run/ChunkCrossBinding` and a two-entry `run/` project prove that a shared chunk is imported by both
entries and that both print — **PENDING the multi-entry decision**, which is what gives the colouring
a second seed at all; until then every fixture here exercises the one-colour case, and a pass whose
only test is the degenerate case is a pass that will be wrong the first time it has two.

## 11. Source maps

Fused into the print pass — a mapping recorded at each emit site, never a second traversal —
delta-encoded, per-file chunks rebased once at join time. On by default in dev, off in release.
Positions live in `JsIr` from the start even while maps are off.

## 12. Testing

The boundary that matters is the second one: **compile, run under Node, assert what it printed.**
This is what Elm's deleted suite never had and it is why `boundary.md` puts the Node platform before
the optimiser.

New corpus kinds:

```
tests/corpus/run/<Name>.beni + <Name>.expected     compile, run, stdout must match
tests/corpus/emit/<Name>.beni + <Name>.js          the extracted declaration, for shape claims
```

`run/` is the default for anything about behaviour. `emit/` is for claims running cannot observe —
that a self-recursive function became a loop, that a constructor emits a uniform shape, that a
saturated call emitted a direct call and not an adapter. Goldens are **extracted and normalised, not
whole-file**, which is the discipline Elm's suite lacked and resented.

The one deviation, recorded rather than hidden: an `emit/` golden is the fixture's **own module**
whole — one deliberately tiny module holding nothing but the claim — because one module of one
tiny fixture *is* that extract, with no extractor of its own to get wrong, while core and the
platform stay out of the file (`tests/corpus/emit/README.md`).

A second deviation arrives with §9: **`emit/` builds with `--library`**, so a golden is a claim about
the shape of a declaration and not about whether the fixture's own `main` happens to call it, and
`emit/app/` is the subdirectory that does not — for the goldens whose claim *is* what elimination
removes. Same mechanism as `core/`, which already appends `--core`.

A third arrives with §9's release optimiser, and it is the same mechanism a third time:
**`emit/release/` builds with `--release`**, for shape claims about names, whitespace and inlining.
The behaviour half is bigger and is stated there rather than here — **the whole `run/` corpus is
built and run a second time under `--release`**, not a marked subset, because the failure mode of a
minifier is a wrong answer in a program nobody thought to mark. Measured cost: about 7 seconds of
wall clock, +11% of `zig build test-blackbox`. §9's *Testing* has the fixture list and the number.

A bug that changes emitted shape but not behaviour must not fail a `run/` test; a bug that changes
behaviour must. That is the whole point of preferring it.

§8 lists the fixtures the tail-call loop owes, one row each, with the observable that separates a
right loop from a wrong one. Two of them are worth naming here because they are the pattern the rest
of the backend should copy: the loop's fail-first fixture overflows the stack without the change, and its
closure-capture fixture exits 0 with the wrong answer, which is the failure mode a `run/` fixture
exists to catch and an `emit/` golden cannot.

## 13. Measurement

`bench` gains `emit` (throughput in MB/s of JavaScript) and `build` (the whole cold pipeline).
Sizes are tracked **after compression**: brotli primary, gzip secondary, raw as a diagnostic only.
Zig's standard library has no brotli, so the benchmark shells out to an encoder pinned in the flake.

| What | Target |
|---|---|
| Emit throughput | > 5 MB/s of JavaScript — **measured 85.5 MB/s** when first built (`bench/README.md`) |
| Whole cold build, 100k lines | < 800 ms including core |
| Output size | Elm's TodoMVC at 9KB compressed is the number to beat |
| Own output vs esbuild `--minify` | within ~10%; revisit before M5 if it approaches 1.58× |

That last row is report 12's exit criterion, and it exists because Scala.js built the type-aware half
of this and measured 1.58× for going without a generic minifier. The difference is that Scala.js
never built the generic half at all; if our number approaches theirs, the plan was wrong.

## 14. What M3 does not do

Ports (`boundary.md` B3), the browser platform (B4), `Intl` (B5), the daemon and any caching (M4),
and mutual-recursion trampolining (§14 question 5, a stated limitation).

## 15. Emitted markup

*Specified 2026-09-29; not built.* What a build emits for markup ([`language.md`](language.md) §11):
the compiler's part around a platform's markup lowering, the two lowerings that ship — `dom`, in the
`browser` platform, and `ssr`, in the `node` platform — and the browser runtime's render loop. It is
§15 and not the "new §11" that `plans/browser-platform.md` first named, because §11 is *Source maps*
(rule 2; research 36 §0 item 9a). The lowering interface itself is [`boundary.md`](boundary.md) §9.4;
this section is what is built on it. Every claim about Solid cites
[`research/36`](research/36-solid-jsx-compiler-for-beni.md) (`c/…` is its citation of
`references/dom-expressions/packages/compiler/src/…`, `rt/…` of the runtime) or
[`research/27`](research/27-solid-2-as-built.md).

*Revised 2026-09-29, after the specification review.* The render loop the owner answered in W28 is
specified (§15.11); `child` is three exports, one per hole kind, so nothing is decided by sniffing a
value (§15.3–§15.4); every `Html msg` a program can hold is a block, the markup primitives' included,
and `Html.map` composes handlers through a mount context (§15.3); start data is one object (§15.1);
patches are written as statements, because `JsIr` has no assignment expression (§15.3); rows of any
shape and their inputs (§15.5), `Show` (§15.5), the class and style lists (§15.3, §15.6) and decoded
text (§15.3, §15.6) are compiled; and the differential oracle has a harness (§15.10).

### 15.1 What the compiler emits around a lowering

- **Where.** In `Emit`, per module, inside `Lower`: a surviving declaration is lowered as today, and
  at a `markup` instruction of kind `expression` the lowerer emits the root's values — each a
  `const`, in `language.md` §6's order — and splices in the expression the lowering's `root`
  returns (`boundary.md` §9.4.3). A row's values are emitted where the lowering places them, through
  `cx.rowValues`. The lowering's `module` runs first, once per module with a surviving root, and its
  hoisted declarations are emitted after the module's imports and before its first declaration, in
  the order hoisted. `Opt`, `Rename` and `Print` then run over the whole as they do today (§15.7).
- **The runtime.** The platform's markup runtime is copied as `<its platform dir>/<name>.foreign.mjs`
  (§2, `boundary.md` §9.1) **iff at least one markup root or markup primitive survives**
  reachability — or always, when it is also the program runtime (`boundary.md` §9.2) — and imported
  by each module that uses one of its exports, one binding per export used, exactly as a sibling's. A
  use of a markup primitive is an import of the export of its name, as a `foreign`'s is of its
  sibling's. Like a sibling it is copied whole (§9, *Sibling-level elimination is out of scope*), so it
  should be small; research 36 §4.7 measured a whole client runtime of this design at **1 482 bytes
  brotli**. *Amended 2026-09-29: whole in a development build; under `--release`, like a sibling, it
  is compacted and cut to the exports the build imports (§9, *Hand-written JavaScript under
  `--release`*), and the empty page is 1 393 bytes brotli.*
- **Program start.** The entry file (§5) calls the runtime's `start` export with the build's start
  data before it calls `run`, as `boundary.md` §9.4.5's one shape — an object of sorted keys, each an
  array of sorted, de-duplicated strings: `start({ delegate: ["click", "input"] }); run(Main$main);`.
  A build with no markup, or whose runtime declares no `start`, emits no call, so a program without
  markup does not move by a byte.

### 15.2 Template identity, and names

**A template kind is identified by its site**: the module index and the `markup` instruction's
index, both input-derived before any parallel work (CLAUDE.md rule 5). Never by the markup's text:
`if c then <input /> else <input />` is two kinds, so a branch change remounts and neither input's
focus or value leaks into the other, which is what Solid gets by rebuilding (research 36 §4.5). Never
by a counter shared across workers (research 28 §9.3). A lowering may share one template *string*
between sites of a module — dom-expressions dedupes templates on markup (`c/dom/template.rs:276-304`)
— but never a kind.

Names in development builds are readable and stable: a kind is `<Module>$k<inst>`, a template string
`<Module>$t<n>` with `n` counting distinct strings in hoist order, a row pair `<Module>$r<inst>`.
`--release` renames them with every other top-level name (§9 item 2).

### 15.3 The `dom` lowering

**A port of dom-expressions' client compiler** (the owner's decision, *JSX compiler*), not a new
design. Research 36 §3.7 lists what is ported — `dom/element.rs`, `children.rs`, `template.rs`,
`attrs.rs`, `set_attr.rs`, `events.rs`, `static_template.rs` and the commit half of `dynamics.rs`,
about 3 000 lines of Rust — and what is not: hydration, Babel parity, the reactive wrappers, spread,
refs, `refresh/` and `directives/`. beni's version is smaller than the Rust, because the tree's types
answer exactly what `classify.rs` guesses (research 36 §3.7).

**The emitted shape** (research 36 §4.2): each root site `s` becomes a template kind
`K_s = { m(v, cx) → inst, p(inst, v) }`.

- **`m`** clones the template, runs the walks, writes every hole and attaches the events — Solid's
  output with its effect wrapper off (research 36 §2.2). `cx` is the **mount context**, `null`
  outside any `Html.map` (below), passed to every slot the instance makes.
- **`p`** is one guarded write per dynamic hole, the commit half of Solid's grouped effect with the
  last value kept in an instance field instead of `_p$` (`c/dom/dynamics.rs:150-179`), written as a
  statement: `if (v[3] !== i.h3) { i.h3 = v[3]; i.n3.data = v[3]; }`. `JsIr` has no assignment
  expression and the builder adds none (`boundary.md` §9.4.3), so Solid's `v !== h && (n.data = h =
  v)` is this `if`, which is the same work. **There is no compute half and no signal**: `view`
  re-runs and the check is by reference (W26).
- A root of kind `expression` evaluates to a **block** `{ t: K_s, v: [values] }`; §15.4 is where a
  block goes. **Every `Html msg` value under `dom` is a block**: a root's, and a markup primitive's
  too, whose `t` is a kind the runtime defines (`text`'s, `map`'s). So a slot never asks what a value
  is — it calls `t.m` or `t.p` — and a primitive's value patches and remounts by the same rule as a
  template's.

**The template string.** Static elements, constant attributes and text are baked in; a subtree with
no dynamic part is inlined whole (`c/dom/static_template.rs:11-60`). Text arrives decoded
(`frontend.md` §9.7), so the template re-encodes it for the HTML parser to decode back to the same
characters: `&` → `&amp;` and `<` → `&lt;`, and U+000D as `&#13;`, since the parser's input stream
would turn a raw one into U+000A; an attribute value `&`, `"` and `<` (`c/shared/utils.rs:258-265`).
In an element whose content the parser reads as raw text — `script`, `style`, `xmp`, `iframe`,
`noembed`, `noframes` — nothing is decoded, so text is written as it is, and text that would close
the element early (`</` then its name, in any case) is `markup_restructured`. Solid leaves `&` in dom
text for the browser to decode (`c/dom/children.rs:105`) where its other paths decode at compile time;
decoding once in the compiler is what makes `dom` and `ssr` agree by construction, raw-text elements
included. Quotes are dropped where HTML allows (`c/shared/utils.rs:271-290`); closing tags the parser
would imply are omitted (`c/dom/attrs.rs:510-563`). An element whose vocabulary row says `svg` or
`mathml` and is not the namespace's own root element is wrapped for parsing and unwrapped on clone,
flag `2` (`c/dom/element.rs:476-495`).

**The HTML parser table.** What the HTML parser does with a string — void elements, implied end tags,
table foster-parenting, a `<p>` closed by a block element, `<a>` inside `<a>`, `<form>` inside
`<form>`, raw-text elements — is a **fixed table**, `html`'s `parser_table` (`boundary.md` §9.5;
research 36 question 2, accepted), ported from `c/shared/constants.rs:39-91` and `:267-285` and from
the rules `c/shared/validate.rs` checks with `html5ever`, as a table and not a parser. Markup that the
parser would rebuild differently from the tree is **`markup_restructured`** (`boundary.md` §9.4.7),
naming the element and the rule — Solid refuses the same markup (research 36 §3.4). An element the
table calls void but the vocabulary does not, given children, is the same error, so a vocabulary that
disagrees with the parser cannot emit a wrong template.

**Walks and markers**, unchanged from Solid: a hole's node is reached by `.firstChild`/`.nextSibling`
chains from the most recent walk variable, starting again from `parent.firstChild` under each new
parent (`c/dom/template.rs:413-458`); a walk variable exists only where something needs one
(`c/dom/children.rs:427-535`); **every walk is declared before the first write**
(`c/dom/element.rs:429-431`), which is also what makes §15.7's inlining safe. A slot's marker is the
next static sibling, a `<!>` comment between two text runs or where a parent has several slots, or
nothing when the slot is the parent's only child (`c/dom/children.rs:557-634`). There is no encoded
path, so there is no overflow case (research 36 §3.3). These walks and writes are the node-level host
access `boundary.md` §9.4.4 allows emitted code: on nodes the runtime's cloner returned, and no other
object.

**What each hole compiles to**, decided by the markup section of the checker's record
(`checker-v2.md` §25.7) and the vocabulary row's facts, never by the value at run time. Items are
written in source order, attributes and events interleaved (`language.md` §11.5):

| Hole | `m` | `p` |
|---|---|---|
| text, `string` | a text node, `.data = v` | `if (v !== i.h) { i.h = v; n.data = v; }` |
| text, `number`/`char`/`bool` | the same over `"" + v`, which is what the template literal of a string interpolation writes (§4), so a hole and `"${v}"` agree; `+` and not `String`, since a lowering can name no global (`boundary.md` §9.4.4) | the same, comparing `v` before converting |
| attribute, `string`/`int`/`float` | `setAttribute(name, "" + v)` | guarded |
| attribute, `bool` | present as `""` or absent | guarded |
| attribute, `maybe_string` | absent on `Nothing`, through `cx.maybe` | guarded |
| attribute, fact `property` | `el[prop] = v` | guarded |
| attribute, fact `stateful` | `el[prop] = v` | **compared with the live value**, `if (el[prop] !== v) el[prop] = v;`, so a rejected edit does not stay on screen (research 36 §4.8); no instance field |
| attribute, fact `url`; an escape the markup section records `url` (*amended 2026-09-29*, `language.md` §11.5) | through the runtime's `safeUrl` | guarded |
| attribute, fact `raw` | through the runtime's `rawHtml` | guarded |
| attribute, `svg` namespace prefix (`xlink:href`) | `setAttributeNS` through the runtime | guarded |
| attribute, `class_list`, entries in place | a constant `True` entry baked into the template's `class`, a constant `False` dropped, a dynamic one `el.classList.toggle(name, f)` — Solid's split of a class object literal (`c/shared/attr_plan.rs:824-895`, `c/dom/set_attr.rs:80-101`) — when the literal names are distinct and hold no whitespace; otherwise as the next row | each dynamic entry guarded on its flag |
| attribute, `class_list`, any other list | the runtime's `classes(el, list, null)` | `classes(el, list, prev)` when `list !== prev`: the port of Solid's `className` diff over a cons list (`rt/client.js:333-360`, `:1616-1640`), adding what the new list holds and removing what only the old one held |
| attribute, `style_list`, entries in place | a constant entry baked into the template's `style` (`c/shared/attr_plan.rs:587-685`), a dynamic one `el.style.setProperty(name, v)` (`c/dom/set_attr.rs:52-78`) when the literal names are distinct; otherwise as the next row | each dynamic entry guarded |
| attribute, `style_list`, any other list | the runtime's `styles(el, list, null)` | `styles(el, list, prev)` when `list !== prev`: the port of Solid's `style` diff (`rt/client.js:376-417`) |
| `html` | a slot: `childHtml(slot, v)` | `childHtml(slot, v)`, which patches (§15.4) |
| `maybe_html` | a slot: `childMaybe(slot, cx.maybe(v))` — a block or `null` | the same |
| `list_html` | a slot: `childList(slot, v)` | the same |
| component | the call, then a slot | skipped when every prop `===` its last value (`language.md` §11.8); otherwise the call, then `childHtml` |
| `html` whose value is a helper call, `Hole.call` (*amended 2026-09-29*, §15.4) | the arguments kept in the instance; the call, then a slot | skipped when every argument `===` its last value (`language.md` §11.6); otherwise the call, then `childHtml` |
| `For`, `Show` | §15.5 | §15.5 |

A constant attribute on an element costs nothing at run time; Solid's instrumented mount of 1 000
rows shows `setAttribute: 0` (research 27 §6.2). **One export per hole kind** — `childHtml`,
`childMaybe`, `childList`, never one `child` that inspects its argument — because the kind is known
before any code is emitted (`language.md` §11.6) and a value-sniffing `child` would be the generic
conversion §11.6 refuses, paid on every patch.

**Events** (research 36 §4.6). A **delegated** event is a property write, `el.$$click = h`, and `p`
rewrites it only when the handler value changed (`c/dom/events.rs:60-66`); a payload-form handler's
node also gets, at mount, `el.$$clickX = extractor` (or the runtime's identity when the payload is the
raw event). The runtime's one listener per delegated name walks up from the target to the first node
with a `$$click`, applies the row's `preventDefault` and `stopPropagation`, computes the message —
`X ? h(X(event)) : h` — passes it through the node's map chain (below), and sends it to the program
whose mount root it reaches next (§15.11). A **non-delegated** event attaches, at mount, one stable
listener through the runtime's `listen` that reads the node's current `$$<name>` and then does the
same — the only workable design when handlers are fresh closures that cannot be compared
(`plans/browser-platform.md` §2.3). **Delegated names are registered at program start**, through the
start data (§15.1), not by a module-level `delegateEvents` call (`c/dom/template.rs:267-269`), which
would give a module a load-time effect §9 forbids (research 36 §0 item 9c). In a `--library` build,
which has no program start (`cx.build.library`), each kind's `m` passes its own names to the
runtime's `delegate`, which registers each name once.

**`Html.map`, and the mount context.** `map(h, f)` — the markup primitive — returns a block whose
kind is the runtime's map kind: its `m` makes a context `{ f, up: cx }` and mounts `h` in a slot with
it, and its `p` sets the context's `f` when the function changed and patches `h`. Every event node
mounted with a context that is not `null` gets, at mount, `el.$$cx = cx` (one guarded property write,
`if (cx !== null) el.$$cx = cx;`); the listener, having computed a message on such a node, applies
`for (let c = el.$$cx; c !== null; c = c.up) msg = c.f(msg)` — innermost map first, which is Elm's
order. Because `p` changes `f` in place, a map whose function changed rewrites no handler inside it,
Elm's own trick (its tagger chain, research 24 §1, `VirtualDom.js:772-818`). **Cost**: every kind's `m` takes
the context argument; inside a mapped subtree, one property write per event node at mount and a walk
of the chain per event; outside every map, nothing. `text(s)` — the other primitive — returns a
block of the runtime's text kind, one text node patched as a `string` hole is.

**The `dom` runtime's well-known exports**, declared by the lowering (`boundary.md` §9.4.5) — the
arity is part of the contract and is checked; the file also exports `run` (it is the program
runtime, `boundary.md` §9.2, §15.11) and the `html` primitives `text` (1) and `map` (2):

| Export | Arity | Does |
|---|--:|---|
| `start` | 1 | registers the delegated names of a whole program, from the start data object |
| `delegate` | 1 | the same, idempotently, for a `--library` build's kinds |
| `template` | 2 | `(html, flags)`: a lazy cloner — the first call parses, later calls clone (`rt/client.js:140-158`); pure to create |
| `slot` | 3 | `(parent, marker, cx)`: makes a slot, remembering the mount context its content mounts with |
| `childHtml` | 2 | `(slot, block)`: patches when the block's kind is the slot's, remounts otherwise (§15.4) |
| `childMaybe` | 2 | `(slot, blockOrNull)`: likewise, `null` emptying the slot |
| `childList` | 2 | `(slot, list)`: a cons list of blocks, matched by position (§15.4) |
| `forKeyed` | 5 | `(slot, items, keyOf, row, cx)`: the keyed list (§15.5) |
| `forPosition` | 4 | `(slot, items, row, cx)`: the positional list |
| `show` | 3 | `(slot, key, block)`: the keyed conditional's `Just` (§15.5) |
| `hide` | 2 | `(slot, fallbackOrNull)`: its `Nothing` |
| `classes` | 3 | `(el, list, prev)`: a class list that is not written in place |
| `styles` | 3 | `(el, list, prev)`: a style list likewise |
| `attrNS` | 4 | `(el, namespace, name, value)` |
| `safeUrl` | 1 | a URL, or `""` for a script URL — Elm's rule, which keeps a `view` from injecting script (research 24 §6.3) |
| `rawHtml` | 2 | `(el, markup)`: the `raw` escape hatch |
| `listen` | 3 | `(el, name, flags)`: the stable stub of a non-delegated event |

### 15.4 Blocks: where markup that escapes goes

W29's answer, in Solid's own split (research 36 §0 item 3, §4.2; question 3, accepted). A root whose
value **escapes** — into a `let`, a helper's result, a `case` branch, a list, a record field, a
component's `children`, or a recursive view — evaluates to a block `{ t, v }`, and the slot that
receives it **patches when `t` is the same kind as last render and remounts when it is not**. This is
Solid's `insert` stripped of reactivity, and blockdom's model, which research 29 measured ahead of
Solid 2 on all nine script medians (research 36 §0 item 3: `select` 1.71 against 2.60 ms). It needs
no inlining and no virtual DOM, is sound by construction, and costs one small allocation per
escaping root per render. A branch is two kinds, so an `if` or `case` in a hole is a remount when the
branch changes and a patch when it does not — non-keyed `Show` with no `memo`.

The three slot exports, one per hole kind (§15.3):

| Export | Value | Written |
|---|---|---|
| `childHtml` | a block | the same `t` as the slot holds: `t.p(inst, v)`; otherwise the old nodes are removed and `t.m(v, slot.cx)` mounted |
| `childMaybe` | a block, or `null` for `Nothing` | a block as `childHtml`; `null` empties the slot |
| `childList` | a cons list of blocks | slot *i* receives block *i*, each by `childHtml`'s rule; extra slots removed, missing ones mounted |

A block a markup primitive built is handled by the same rule, since its `t` is a kind like any other
(§15.3): there is no fourth case, and nothing inspects a value to find out what it is.

**What the lowering compiles away.** Where a consumer is visible the block is never built: a `For`
row whose body is markup gets a row pair called directly (§15.5), which is the measured P2 shape.
Every other consumer — `view`'s root included, called by the platform's `Program` — receives blocks.
Research 36 §4.2 lists a component call and an inline `if` as further direct consumers; interface
version 1.0 does not, and whether they pay is what the end-to-end measurement's helper-heavy page will
show (`plans/browser-platform.md`, *Decisions this spec took*). **What it reports**: `--self-profile`
counts `markup_roots`, `markup_block_roots` and `markup_row_roots`, so the share of a program's roots
on the general path is a number (W29's rule-7 mitigation), and `markup_row_whole_inputs`, the rows
whose inputs hold a whole local (`language.md` §11.9), so the rows that re-run on every change to
that local are a number too.

*Amended 2026-09-29: a helper call in a hole is not made when its arguments are the same*
(`language.md` §11.6; research 39 §6.3, the cheaper of its two options). The helper-heavy page did
pay — 30 µs a message against the inline page's 4.3 and the component page's 7.0 — because each of
its 750 helper calls built a block every render and every block was patched. Interface 1.1 marks an
`Html msg` hole whose expression is a call of a top-level function that passes no evidence
(`boundary.md` §9.4.2, `Hole.call`): its callee, which may be named anywhere in the module, and its
arguments, which are values of the root. `dom` compiles such a hole as it compiles a component —
the arguments kept in the instance, and the call made, then placed with `childHtml`, only at mount
or when an argument is not `===` the one kept — so a helper whose arguments did not change costs a
comparison per argument and builds nothing, and neither do the helpers it would have called. The
block is still built when the call is made; inlining a helper's markup into its caller's template
(research 39 §6.3, option 2) stays later work.

*Amended 2026-09-30: a constant argument is neither kept nor compared* (research 41 §5.2). The
benchmark's `view` calls `button "run" "Create 1,000 rows" Run` six times, and the container's
instance kept all eighteen arguments and compared them on every render, though every one is a
literal or a shared nullary constructor and cannot change. Interface 1.4 marks the values that are
the same JavaScript value on every evaluation (`boundary.md` §9.4.6, `Tree.constant`); `dom` keeps
and compares only a helper's or a component's other arguments, and a helper or component whose
arguments are all constant is called at mount and never again — the skip of §11.6 and §11.8,
decided at compile time. Pinned by `emit/dom/DomHelpers`.

### 15.5 `For` and `Show` in the `dom` lowering

`For` is Solid 2's list (research 27 §7.1), with **dom-expressions' `reconcileArrays` without
`$$SLOT`** as the one DOM patcher (`rt/reconcile.js`, udomdiff; research 27 §6.11): a whole-program
compiler gives every node one owning slot, so the ownership tags have no job.

- **Rows by shape** (`boundary.md` §9.4.2, `Row.kind`):
  - `markup` — a **row pair** `r$m(item, i, env, cx) → inst` and `r$p(inst, item, i, env)`, the
    row's values placed inside them with `cx.rowValues`, `env` holding the captures and the inputs;
  - `lambda` — the same pair around a per-row slot: the values placed with `cx.rowValues`, whose
    result, a block, goes to `childHtml`;
  - `function` — the function value called with `cx.call` per row, its block into a per-row slot.
- **A row is skipped** when its item, its position (only if the function reads it) and every input
  are `===` to last render's (`language.md` §11.9) — for a `function` row, the input is the function
  value, so a top-level function's rows skip on the item alone. That is what makes an unchanged row
  cost a few pointer comparisons and no call, and it rests on §15.8. The inputs are the enclosing
  root's values, so they are compared, not recomputed per row: `select` in research 29's benchmark
  changes `model.selected`, every row whose class reads it re-runs, and every other edit to the model
  skips all of them — P3's rung 3 at the row (research 29 §7.2). P3's selector recognition, rung 4,
  is the *selector* bullet below (*amended 2026-09-30*).
- **What reads only the item** (*amended 2026-09-29*, research 39 §4.2 edit 2): a `markup` row's
  `p` runs whenever its item or an input changed, and it recomputed every value and rebuilt every
  handler message — `{ $: "Select", a: item.id }` is never `===` the last one — so a selection
  rewrote two `$click` properties per row. Interface 1.2 says which of a row body's values read
  only the item (`boundary.md` §9.4.2, `Tree.item_only`), and `dom`'s `p` places them with
  `cx.rowValuesApart`: the values that read an input and their writes first, then the item-only ones
  and their writes inside one `if (item !== i.x)`, `i.x` being the item the runtime last showed
  the row with, which it sets after `p` returns. That is P2's split by hand (research 29 §7.1). A
  write goes under the test only when every value it reads is item-only; a `stateful` property,
  which is compared with the page on every patch, a component, a `For` and a `Show` never do.
  Pinned by `emit/dom/DomRowItemOnly` and `browser/dom/RowItemOnly`.
- **A selector** (*amended 2026-09-30*, research 39 §12; `language.md` §11.9): select lost to Solid 1
  by 1.23–1.32× because Solid's `createSelector` notifies the two rows whose selection changed and
  beni ran the `p` of all thousand. The compiler now recognises the row input `language.md` §11.9
  calls a selector and hands it to the lowering as `Row.selector` (interface 1.3, `boundary.md`
  §9.4.6): its position among the inputs, and a **probe**, a value of the enclosing root that
  evaluates nothing — the input itself when its comparisons are `===`, and
  `s.$ === "Just" ? s.a : s` when they are against `Just` — which is the one key the comparison can
  hold for, or, for `Nothing`, a value no key is (a key is a string, number or boolean, and the
  probe is then an object). `dom` puts both on the row object, `g` and `z`. `forKeyed` then compares
  every input but the `g`th as before and keeps last render's probe in the slot: when the items and
  every other input are as last time and the probe changed, it looks the old probe and the new one
  up in the key map it already keeps and patches those rows and their duplicate-key chains, and
  visits no other row; when something else changed too, a row whose item, position and other
  inputs are as last time is patched only when its key is `===` one of the two probes. The key map
  is the list's own — which is why a selector must compare against the list key, and costs nothing
  to maintain; a `Map` treats `NaN` as one key where `===` does not, which patches a row too many and
  never one too few. A row that is not recognised is patched whenever an input changed, as before.
  Pinned by `browser/dom/Selector` (selection moving, an id no row has, duplicate keys, a selection
  and an edit in one render, a helper, a record pattern, `===` and `/=`), `emit/dom/DomSelector`
  and the near misses in `emit/dom/DomSelectorNearMiss`.
- **By key** (`forKeyed`): a map from key to instance; per row, `r$p` or a new `r$m`; the array
  reconciler runs only when the key order moved — the `moved` flag (research 36 §4.4) — so a
  selection change or a label edit never enters it. **Duplicate keys**: rows are matched by the key and
  the item's rank among equal keys, so every item renders once (`language.md` §11.9).
  *Amended 2026-09-29* (research 39 §4.3, §7 question 4): **the key map is kept across a render
  that moves rows.** It was rebuilt on every such render — per row a lookup, a delete or a chain
  step, a duplicate check and an insert into a new `Map` — which is what left swap level with
  Solid 2 and remove 9 % behind it. Now the map, from a key to the first row that has it, lives in
  the slot from render to render; a render stamps each row it keeps, so a surviving row costs one
  lookup and a few field writes, and afterwards drops from the map only the keys whose first row
  went unstamped. **The rank chain is carried across**: the rows after the first that share a key
  are a chain in list order, and a render rebuilds it as it goes — a key's `k`th item takes the old
  chain's `k`th row, a key with more items than rows mounts the rest, and one with fewer leaves the
  rest unstamped, to be removed — so duplicates render exactly as before. The runtime's instance
  fields for this are `kv`, `kc` and `kt`, named apart from every field a kind's instance or a
  runtime kind's already has. Pinned by `browser/dom/KeyedMoves` (a swap and removals with two items
  on one key, a key emptied and added back), which fails against a map that assumes distinct keys
  and against one that keeps a key none of the rows has any more.
  *Amended 2026-09-30* (research 39 §11): **the ends first, as Solid does.** Solid 1's `mapArray` and
  dom-expressions' `reconcileArrays` skip the common start and end of the two lists before they
  build a map, so a remove touches no map and a swap of two rows touches one only for the rows
  between them, and `reconcileArrays` finds the swapped pair at the ends in constant time. `forKeyed`
  did one map lookup and a row's worth of field writes for every row of every render that moved
  one, and remove lost to Solid 1 by 1.7× on it. Now, **when last render's keys were distinct**
  (`s.d`), the list is matched in udomdiff's order before any lookup: the rows whose keys are where
  they were at the start (patched as they are passed, as before, since they do not move); then at
  the end; then, while the two rows at the ends of what is left have changed places, that pair,
  and the start and end again. An item `===` its row's last item has that row's key (keys are pure
  functions of the item), so its key is not computed; otherwise the key is computed once per item.
  Only the rows between the matched ends go through the key map, and the array reconciler runs over
  that range alone, with the node after it as its end. **Duplicate keys still render by rank**: a
  new key found twice — in what is left, or equal to a key matched at an end — hands the render to
  the full pass above, which is why nothing after the start is written until every key left is
  looked up; a row mounted for a new key before the hand-over is its key's first row, which the full
  pass takes. A list that is empty or was goes to the full pass too, for its one fragment or its one
  `textContent`. Pinned by `browser/dom/KeyedEnds` (a remove, an inner and an end swap, an insert and
  a replacement in the middle, a row at an end whose item is new, rows that show their position, a
  function row whose branch changes at an end and in an end pair, and a key copied into the middle
  from each end), whose golden was recorded on the runtime before this change.
  *Amended 2026-09-30* (research 39 §13): **a replacement empties the parent.** When the ends match
  nothing, no two rows changed places at them, and no key in what is left is found in the key map —
  every row is new — and the old rows are everything their parent holds, the parent is emptied with
  one `textContent = ""`, as the full pass empties it for a clear, and the new rows are appended.
  Solid 1's `reconcileArrays` removes the thousand old rows of the benchmark's *replace* one at a
  time and then inserts the new ones; beni did the same, and it was 8.8 ms of a 13 ms render.
  Otherwise the reconciler runs as before, so a row that is kept keeps its node, and a parent with
  other children keeps them. Pinned by `browser/dom/KeyedReplace` (an end swap and a replacement
  that keep a row the reconciler does not move, which keeps the focus; a replacement of every row;
  one that keeps the middle row; in a parent that holds only the list and one that holds more),
  whose golden was recorded on the runtime before this change; a runtime that empties the parent
  when a row is kept, when two rows changed places at the ends, or when the parent holds more than
  the rows fails it. **A list mounted where none was** — the full pass's "one fragment" above — now
  goes straight into the page, row by row before the slot's marker, as Solid 1's `appendNodes`
  does: the fragment moved every node twice, and the benchmark's *create* spent 0.23 ms more of a
  4.4 ms render on it (research 39 §13). What the page shows is the same.
- **By position** (`forPosition`): slot *i* is patched with item *i*.
- **By reference**: `forKeyed` with the item as its own key. Where the checker recorded the item type
  as primitive-`eq`, that is value keying and correct; otherwise it is Solid's default and `unkeyed_for`
  has already said so.
- **`fallback`** is a slot shown while the list is empty.

**`Show`** (`language.md` §11.18) is a slot plus the last key. On `Nothing` (tested with `cx.maybe`)
it calls `hide(slot, fallback)`. On `Just v` it computes the key — `v`, or the key function applied
with `cx.call` — and, unless the body is skipped (the key, `v` and the body's inputs all `===` last
render's), builds the body's block as a row's and calls `show(slot, key, block)`: the runtime
remounts when the key is not `===` the slot's last key or the slot showed the fallback, and otherwise
patches as `childHtml`. A body is always a block in interface version 1.0 — a `Show` is not a list,
so the one allocation per render is not worth a pair.

### 15.6 The `ssr` lowering

The `node` platform's lowering, for server rendering and for `tests/corpus/run/`, where there is no
DOM (research 36 §2.12, §5.5): the same tree, and the same template split, emitted as strings.

- A kind is an array of static strings; a root evaluates to **`{ t: string }`**, the markup type's
  representation under `ssr` — Solid's shape (`rt/server.js:2601`), so a string already rendered is
  never escaped twice.
- **Escaping is by type, at compile time**: a `string` text hole gets `escape(v)`, a number none; an
  `html` hole splices `.t`; an attribute value gets `escapeAttr`, a `url` one (or an escape recorded `url`) `safeUrl` first, a
  `raw` one nothing (and was warned about). A `Bool` attribute is written or omitted, a `Maybe String`
  omitted on `Nothing`. **Text arrives decoded** (`frontend.md` §9.7) and is escaped into the static
  strings exactly as `dom` escapes its template (§15.3), raw-text elements included, so both
  lowerings produce the same characters.
- **Class and style lists** are written as the attribute's text, in entry order: the runtime's
  `classes(list)` joins the names whose flag is `True`, each once, in first-occurrence order;
  `styles(list)` writes `name:value;` for each property's last non-empty value, in first-occurrence
  order; entries in place with constant values are joined at compile time. Both are then escaped as
  any attribute. The page `dom` builds has the same classes and properties; only the order within
  the attribute may differ, which neither means anything nor is observable through the DOM's
  `classList` membership or computed style.
- **The same HTML parser table** as `dom` decides void elements, closing tags and raw-text elements,
  so the string parses into the tree the page would build. It lives in the `html` platform's Zig,
  which both lowerings import (`boundary.md` §9.5), and `markup_restructured` is raised the same way.
- **Events are dropped** (`c/ssr/transform.rs:1754-1760`); **components are called**, never skipped —
  a string is rendered once; **`For`** is a map and a join, `fallback` when empty; **`Show`** renders
  the body for `Just v` and the fallback, or nothing, for `Nothing`.
- **The primitives**: `text(s)` is `{ t: escape(s) }`; `map(h, f)` is `h`, since a string carries no
  handler for `f` to wrap.
- **Well-known exports**: `escape` (1), `escapeAttr` (1), `safeUrl` (1), `list` (2), which renders
  `(items, row)` — a cons list, as every sibling that takes a `List` reads one — and concatenates the
  rows, `classes` (1) and `styles` (1); with the primitives `text` (1) and `map` (2). A render is
  printed by the `node` platform's own `foreign render : Html msg -> String`, which reads `.t` — legal
  because `node` names `ssr` (`boundary.md` §9.3) — so a `run/` fixture prints a view with
  `Node.printLines [ Node.render (view model) ]`.

*As built, 2026-09-29* (`platforms/node/zig/ssr.zig`, `platforms/node/markup.js`,
`platforms/html/zig/parser_table.zig`; `tests/corpus/run/Markup*`, `emit/MarkupSsr`). The list above
holds, with these readings:

- **A kind is hoisted and named by its site**, `<Module>$k<inst>` (§15.2), after the imports: an
  array of the root's static strings, which the root's block concatenates with its values in
  order — or, for a root with no dynamic part, the whole block `{ t: "…" }`, built once. The
  concatenation begins with a string, so a number first is text. A name a declaration of the module
  already has gets a tag instead (`run/MarkupHoistName`).
- **Rows are functions in place.** A `markup` row is `(item, position) => { values; return block }`
  with its values placed by `cx.rowValues`; a `lambda` row returns its body's value; a `function`
  row calls the function. `Show` calls the body with `cx.maybe(when)` under `cx.isJust(when)`, so
  `Just ()` shows its body.
- **`list` takes the fallback as a third argument**, `list(items, row, fallback)` with `null` when
  there is none: telling an empty list from a list whose rows render nothing needs the list's
  representation, which is the runtime's. A `List (Html msg)` hole is `list` with the identity row.
- **`rawText(text, tag)` is a seventh export.** Raw text (`<style>`) is written as it is: text known
  when the view is compiled is `markup_restructured` if it would end the element early, and a text
  hole's value goes through `rawText`, which writes `</` before the element's own name as `<\/` —
  the runtime cannot refuse, and in CSS an escaped `/` is a `/`. Any other child of a raw-text
  element, and anything but text and a text hole in escapable raw text (`<textarea>`, `<title>`), is
  `markup_restructured`.
- **Class and style lists written in place** are joined when compiled only when every entry is a
  constant; with a dynamic entry the rebuilt list goes through `classes` or `styles`, so all three
  forms write the same text. **A style list's property takes its last value, and an empty last value
  removes it** — `language.md` §11.19's "the later wins", which "each property's last non-empty
  value" above misstated for a list whose last entry for a property is empty.
- **A `raw` attribute** (`innerHTML`) is the element's content, written unescaped before its
  children, which is what the page shows after the property write.
- **A `Bool` hole** writes `true` or `false`, as `"${b}"` does (§4); a `Char` is escaped as a string.
- **The parser table** is the standard's rules for what a view writes statically: void elements; raw
  and escapable raw text; a block element closing an open `<p>`; `<a>` in `<a>` and `<form>` in
  `<form>`; a table's, row group's, row's and column group's allowed children and table parts
  outside a table; `li`, `dt`, `dd`, `option` and `optgroup` directly inside their own kind; and
  text straight in a table, which the parser moves out. Each is `markup_restructured`, one per root.
- **`Html.map`** is `map(h, f) => h`, so nested maps render their markup unchanged.
- **A view is printed with `Node.print (Ssr.render (view model))`**: `render` is the `foreign` of
  `node`'s module `Ssr`, not of `Node`, so a program that writes no markup does not check the
  vocabulary (`boundary.md` §9.3, *As built … with the first lowering*).

### 15.7 The release optimiser

Nothing in §9's release slice changes, and three things are stated so that no later pass breaks them:

- **Item 1** may fold a walk declaration into its single use, because its conditions hold by
  construction: a walk is a member chain, and every walk precedes every write in `m`, so nothing
  evaluated in between is reordered (research 36 §6). Pinned by an `emit/release/` golden. **No pass
  may move a DOM read past a DOM write, or either across a runtime call** — `Opt` never reorders two
  surviving evaluations anyway (`language.md` §6), and this names the case.
- **Item 2** renames kinds, templates, row pairs and runtime imports as the top-level names they
  are, and walk variables as locals. **Property names are never renamed** — `$$click`, `$$cx`,
  `.data`, a block's `t` and `v`, an instance's fields — because `Rename` renames bindings and nothing
  else.
- **Item 4**, field ambiguation, is declined (§9); if it is ever taken up, a markup runtime's objects
  and blocks are outside it, because the runtime reads their fields by name.

**Development output of a program without markup does not move by a byte**, as the release slice's
proof required; the `emit/` corpus is what makes it a test.

### 15.8 Field identity, pinned

`language.md` §11.12's promise is what makes `p` correct: `inst.row !== row` means "changed" only
because an untouched value is the same object, and a row's inputs are worth comparing only because
`model.selected` is the same value when `update` did not touch it. Two kinds of fixture pin it, in the
development build and again under `--release`, where an optimiser would break it (W27):

- **Shape**: `emit/` and `emit/release/` goldens of a record update, showing the spread
  `({ ...r, a: x })` in both builds.
- **Behaviour**: a test platform in the corpus, layered on `node`, declares `foreign refEq : a, a ->
  Bool` — a platform may, and only a platform may (rule 6) — so a `run/` fixture can assert
  `refEq model.rows (update (Select 3) model).rows` directly, and fails the moment a pass re-builds an
  untouched field.

### 15.9 Reachability and determinism

- **Vocabulary declarations are not nodes**, apart from primitives: an element, attribute or event
  emits nothing, and a primitive is a declaration like a `foreign`, reachable by its ordinary `refs`
  edges and emitted as an import of the runtime. A root's edges are its value instructions' ordinary
  edges, a component's callee among them; the one edge `Bir` does not have, a payload extractor, is
  the markup leg of `check/Edges.zig` (`checker-v2.md` §25.7). A hoisted declaration is produced only
  by a surviving module's lowering, so it lives and dies with the roots that use it.
- **Determinism**: kind and row names are sites; template-string numbers count in hoist order within
  one module's lowering; start data is sorted; row inputs are in first-use order (`frontend.md`
  §9.7); each module's lowering is one job writing one slot. The `--jobs=1`/`--jobs=8` determinism
  test covers it once markup is in the corpus (`boundary.md` §9.6).

### 15.10 Tests

`run/` through `ssr` is the default for behaviour, from the first slice, because it needs no browser:
text — whitespace collapsing over the Unicode set, a no-break space typed and written `&nbsp;`,
named, bare, numeric and windows-1252 references, `&notit;` — and attribute escaping, the class and
style lists in both forms, `For` in all three modes, `Show` by identity and by key, components and
their children, fragments, `Html.text` and nested `Html.map`, blocks from helpers and branches, and a
view formatted and re-rendered (`frontend.md` §9.6). `emit/` goldens pin `dom`'s shapes against
research 36 §2's examples.

**The differential oracle.** dom-expressions' Babel plugin ships sixteen client fixtures, each an
input `code.js` and the plugin's expected `output.js`
(`references/dom-expressions/packages/babel-plugin-jsx/test/__dom_fixtures__/`: `simpleElements`,
`attributeExpressions`, `textInterpolation`, `fragments`, `SVG` and eleven more), and the Rust
compiler keeps Babel parity with them (research 36 §1, §3.7). The harness:

- **Inputs**: `tests/oracle/dom/<fixture>/Main.beni`, a hand translation of the fixture's JSX into
  beni markup against a test vocabulary layered on `browser`, one beni root per JSX root, in the
  fixture's order. A construct beni does not have (spread, `ref`, directives) is left out and listed.
- **Expected**: `tests/oracle/dom/<fixture>/expected.txt`, extracted once from `output.js` by
  `tests/oracle/extract.mjs` and checked in, so the gate reads no submodule: for each root, the
  template string passed to `_$template` and the walk — the sequence of `firstChild`/`nextSibling`
  steps to each node a write or a slot uses. Re-extracted, by hand, when the pin of
  `references/dom-expressions` moves.
- **Actual**: `zig build test-blackbox` builds each input with `--library --platform=<the test
  platform>` and extracts the same two things from the emitted module, whose shapes are fixed by
  §15.3.
- **Compared**: byte for byte, template strings and walks. A difference that is deliberate — beni
  never dedupes kinds, a `<!>` marker beni places where Solid's reactive `insert` needs none, a
  construct left out — is listed in `tests/oracle/dom/<fixture>/differences.txt` with its reason, and
  the test fails on any difference not listed and on any listed one that no longer occurs, so the
  list cannot outlive what it excuses.

Behaviour in a page — a keyed reorder keeps focus in its row, a branch swap does not carry an input's
value across, a keyed `Show` remounts on a new value and patches on the same one, a controlled input
reverts a rejected edit, a delegated handler listens once for a thousand rows, a message from inside
two `Html.map`s arrives mapped twice, five messages in one task render once — needs the `browser/`
corpus kind the browser plan adds (`plans/browser-platform.md` §3). *As built, 2026-09-29:* the kind
exists (`tests/corpus/README.md`, *`browser/`*): a fixture's page runs under happy-dom in the gates
and in headless Chrome under `zig build test-browser`, driven by a `.steps` script, its golden a
transcript of `document.body` after each step. Its fixtures today are built for a test platform of
plain `foreign` calls; a `dom` fixture is built for `browser` instead, as that section says. **The bar is the owner's**
(CLAUDE.md rule 8): research 29's harness, the benchmark app written in beni markup and compiled by
beni, against Solid 2 re-run in the same batch, judged on per-operation script medians and never on
a geometric mean, plus research 29's static-heavy page and a helper-heavy one.

### 15.11 The `browser` runtime: program, mount and render loop

The owner's W28 answer is Solid 2's loop (`plans/browser-decisions.md`, W28; research 27 §3.1–§3.6).
This is its contract for `browser`, whose one runtime file is both the program runtime and the
markup runtime (`boundary.md` §9.2) — which is what lets a listener reach `send` — and for every
platform layered on it; `browser-tea` adds no JavaScript.

- **The program.** `browser`'s low-level `Program` is data: its constructor, a `foreign` of the
  `Browser` module legal because `browser` names `dom` (`boundary.md` §9.3), returns the record it
  was given — `init`, `update`, `view` and where to mount, whose final form waits on W9 (what `main`
  is in a page; `document.body` until then). `run(program)` is the only code that reads it.
  *Settled 2026-09-29* (by the project's manager on the owner's delegation, reversible;
  `plans/browser-decisions.md`), Elm's rule: **a program is given the node it mounts at, and
  `document.body` is the default.** Two functions of `Browser`, and nothing else moves:
  - `mountAt : Program, String -> Program` — the same program, mounted at the element whose `id` is
    the string. An id and not a node, because beni has no value that is a node, and an id is what a
    page author writes in the HTML the program is placed in.
  - `programs : List Program -> Program` — several programs on one page, one build and one runtime,
    started in list order, so a program may mount at an element an earlier one rendered.

  `main` stays one `Program` (§5.3's one entry point per build): a page of several programs is one
  value. At run time a `Program` is an array of mounts `{ a, n }`, the record and the id or `null`
  for the body; `Browser.program` makes one, `mountAt` rewrites every `n`, `programs` concatenates.
  **A missing element, or one that holds a program already, is a fault of the page**: `run` throws
  before that program renders anything, as Elm's `init` does given no node. A program's element
  must be in the page when the entry module runs, which a module script's deferred execution
  gives any element of the HTML. Two builds on one page are two runtimes, each with its own
  delegated listeners, and are not supported: a page of several programs is one build.
- **Mount.** `run` renders `view(init)` synchronously, mounts its block in a slot at the mount node
  with a `null` context, after the node's children, which it leaves alone, and marks the mount node
  with the program's `send` (`$$root`). A delegated listener walks up from the event's target past
  the handler's node to the nearest `$$root` and sends there, so two programs on one page each
  receive their own messages. *Made precise 2026-09-29*: the search for a handler's program starts
  at the handler node's **parent** — a program renders only inside its mount node, so a mount node's
  own handler belongs to the program around it — and the listener's walk does not stop at the first
  `$$root`: an event inside a program mounted in another's markup bubbles on into the outer
  program's handlers, as the DOM's own bubbling does, until a handler's declaration says
  `stopPropagation`.
- **A message does not render at once.** `send(msg)` runs `update`, stages the new model and, if no
  flush is queued, queues **one microtask flush** — Solid 2's `schedule()`
  (`references/solid/packages/signals/src/core/scheduler.ts:403-411`), which refuses a second until
  the first has run. Five messages in one task are five `update`s and one render. A flush is a single
  bounded microtask, not a microtask loop, which is the distinction research 27 §3.5 draws against
  research 26's starved page.
- **The flush**, in order: (1) if the model is not identical to the last rendered one, `view(model)`
  and `childHtml` on the root slot — the patch pass, every DOM write of the render; (2) the
  **after-render work** queued during the `update`s, first queued first, each synchronous — Solid 2's
  split effect, whose effect half runs after the queue flushed (research 27 §3.2–§3.3). A message
  sent during (2) queues the next flush; it never re-enters this one.
- **Reads before writes.** The patch pass makes no layout-dependent read: it walks nodes
  (`firstChild`, `nextSibling`) and reads `stateful` properties (`value`, `checked`), and neither
  forces layout. Anything that measures or focuses runs in (2), after every write of the flush, so a
  flush cannot interleave a layout read with a write — the pattern research 26 §5.5 measured at
  2 846 ms against 2.5 ms over 3 000 nodes. After-render work is `sync` (research 26 §5.4: a callback
  that suspended resumed a frame late).
- **An explicit synchronous flush** is the runtime's `flush`, which drains now; it is Solid's
  `flush()`, and beni reaches it as a capability of the `Browser` module (`Browser.flush`), a value
  `run` interprets, since only the runtime file can reach the loop. A capability that must see the
  rendered DOM — focus, measuring, scrolling — is likewise a value `run` queues into (2). Both are
  effects and arrive with the effects work (W8); what the loop owes them is specified here so they
  need no new phase, since a library cannot add a phase the kernel lacks (W28).
- **Controlled inputs need no synchronous render.** Elm renders synchronously when a handler used
  `stopPropagation` because its render waits for the next frame and a fast typist outruns it (research
  24 §6.6). A microtask flush runs before the browser dispatches the next input event, so a `stateful`
  property is reconciled with the model — a rejected edit reverted — before the next keystroke is
  processed. `Browser.flush` exists for reading the DOM a message just changed, Solid's use of it, not
  for inputs.
- **Several renders per frame are possible**, as in Solid 2 and unlike Elm's one per frame; the
  browser coalesces the DOM mutations into one paint (research 27 §3.6), and `view` is skipped when
  the model did not change.

*As built, 2026-09-29, for §15.2–§15.5 and §15.11* (`platforms/browser/`: `zig/dom.zig`,
`runtime.js`, `Browser.beni`; `tests/corpus/emit/dom/`, `emit/release/dom/`, `browser/dom/`,
`build/bad/DomMarkupRestructured`, `tests/oracle/`). The sections above hold, with these readings,
each the smallest that let the lowering be written against interface 1.0 unchanged:

- **Everything is hoisted by `root`, and `module` hoists nothing.** A row's values can only be
  placed while the declaration that encloses it is lowered (`cx.rowValues` rebinds that
  declaration's locals), so a kind is built the first time its root is lowered and found again with
  `cx.hoisted` — a root inside a row is lowered once per row function it is placed in, and must not
  make a second kind for its site.
- **Names are all by site.** A template is `<Module>$t<inst>`, not numbered in hoist order: a
  lowering keeps no state, and counting distinct strings needs some. Template strings are not shared
  between sites. Markup with no values is one block, `<Module>$b<inst>`, hoisted, so a slot that is
  handed it again does nothing. A component's children written as markup are a kind of their own,
  `<Module>$k<inst>n<node>`, the node being the component's.
- **A kind reads its values from `v`; a row reads them where it placed them.** A kind is hoisted,
  so everything it needs arrives in `v`, and what cannot be a value — a `For`'s row, a `Show`'s
  body, a component's call — is a function made where the markup is evaluated and passed in `v`
  too. A component is therefore called through that function, and `p` calls it only when a prop
  (its spread and its children included) is not the one it had.
- **A row is made where its list is evaluated**, as `{ m, p, i, f }` for a row compiled in place —
  `m(item, position, cx)` and `p(inst, item, position)` each placing the row's values with
  `cx.rowValues` and reading the enclosing root's locals by closure — or `{ b, i, f }`, `b(item,
  position)` a block, for a `lambda` or `function` row. `i` says whether the row reads its
  position; `f` is the fallback, so it needs no argument of its own. **`forKeyed`'s fifth argument
  and `forPosition`'s fourth are the row's inputs**, an array (or `null`) the runtime compares entry
  by entry once per list, not the mount context, which the slot already holds.
- **A `Show`'s skip is emitted code**: its key, its value and its body's inputs are kept in the
  instance and compared before the body's block is built; `Nothing` resets the key to the slot
  itself, which no key is.
- **Text holes.** One that is its parent's only child is a text node of the template (`<td> `),
  P2's shape, written with `.data`; any other is made at mount before its marker by the runtime's
  `insertText`, dom-expressions' shape with its template unchanged. `.data`, `setAttribute` and a
  property are handed a number or a `Bool` as it is: each converts it as `"${v}"` does.
- **Four exports more than §15.3's table**, all declared by the lowering: `attr(el, name, value)`,
  which writes a `Bool` or `Maybe String` attribute or removes it for `null`; `insertText` above;
  `identity`, the extractor of a handler that takes the event itself; and `flush`, the render loop's,
  which no emitted code calls.
- **Instances.** An instance owns a run of sibling nodes, `s` to `e`, or begins at `q`, a top-level
  slot, when its markup begins with a hole; at the top level every hole has a marker, and a
  template with a top-level hole or several top-level nodes is cloned whole into a fragment (flag
  `4`, beside dom-expressions' `1` and `2`). Flag `1` is set for a custom element, an `is` attribute
  and a lazy `img` or `iframe`, as dom-expressions sets it.
- **Events.** A declaration's `preventDefault` and `stopPropagation` are `$$<name>F` on the node,
  `1` and `2`; a payload handler's extractor `$$<name>X`, imported from the vocabulary module, which
  reachability now keeps (`checker-v2.md` §25.7). The delegated listener runs every handler from the
  target up to the program's mount node, as dom-expressions' does, and stops at one whose
  declaration says `stopPropagation`.
- **What is refused beyond the parser table**: an element whose content a `raw` attribute writes
  and that has children; a marker the parser would read as text, in a raw-text or escapable
  raw-text element. `<noscript>`'s children are not written, as dom-expressions writes none: with
  scripting on the page never shows them. A constant `stateful` property is written through the
  property at mount and checked by `p` like a dynamic one.
- **The program.** `Browser.program { init, update, view }` is the record it is given; `run` mounts
  `view init` into `document.body` (MD30) and marks it with `$$root`. *(Since 2026-09-29 the program
  is an array of mounts and the body is only the default: §15.11, *The program*.)* **A flush renders whenever a
  message was sent since the last one, even when `update` returned the identical model**, which
  corrects §15.11's "`view` is skipped when the model did not change": an edit `update` rejects
  returns the model it was given, and only a render puts the input's value back (§15.10's
  controlled input). The after-render queue is not built: nothing can put work in it until effects
  land.
- **Release.** `Opt` folds a walk into its one use when they are adjacent, which a walk that is the
  base of the next one is (`emit/release/dom/DomRelease`); a walk used after a write stays
  declared.
- **Tests.** `emit/dom/` and `emit/release/dom/` build for `browser`; `browser/dom/` runs pages for
  it, their driver having gained a counted click and a `flush` step; the differential oracle is
  `tests/oracle/` against a vocabulary layered on `browser` (`tests/platforms/oracle`), with the
  markup type `html`'s so that the chain's `html` primitives still type. A delegated click listening
  once for many rows is shown by the emitted shape — a property write per row, one listener
  registered per name — not by a page of a thousand rows, whose transcript would be the whole page.

*As built, 2026-09-29, for `browser-tea`* (`platforms/browser-tea/Tea.beni`, `boundary.md` §9.1's
*As built* note for it). It adds no JavaScript, as this section says: `Tea.sandbox` is beni over
`Browser.program`, and the loop, the mount and the listeners are this runtime's, reached from
`_platform/_browser/`. What its tests are, and what is still owed:

- **In a page** (`tests/corpus/browser/tea/`, built with `--platform=browser-tea`): two instances of
  one component nested with `Html.map`, each message reaching only its own; five messages in one
  task render once, after the task; the runtime's `flush` renders before it returns; and a
  controlled input reconciled before the next keystroke — the driver's `type` step types one
  character per task, into the live `value`, so the second keystroke of `"ab"` arrives as `"Ab"`
  under an `update` that upper-cases; with the flush moved from a microtask to a 30 ms timer the
  fixture fails, the input left showing `"abc"`. The driver now finds the program runtime as the module the entry file imports `run`
  from, since a layered build's is `_platform/_browser/runtime.foreign.mjs`.
- **Without a DOM** (`tests/corpus/run/TeaLoop/`): the same program shape under `node`, the loop
  written in the fixture — each task's messages folded through `update`, one `Ssr.render` per task
  that sent any. The fixture cannot call `Tea.sandbox`: `browser-tea`'s chain names `dom`, and its
  `Browser.program` under `ssr` would be `markup_type_in_foreign` (`boundary.md` §9.3), which is that
  rule working. So it proves the program's half of the loop and `Html.map`'s identity under `ssr`,
  not the runtime's scheduling, which the pages prove.
- **Not built.** Two programs on one page: W9 settles that `main` is a `Program` and a page has no
  exit code, but not where a program mounts, and `run` mounts at `document.body`, so a second
  program's mount replaces the first's `$$root`. Each would receive its own messages by the nearest
  `$$root` as specified once a `Program` carries its mount node; until then there is one per page.
  The after-render queue, and the message sent from after-render work that renders in the next
  flush, wait on effects: nothing can put work in the queue before they land.
  *Built 2026-09-29: two programs on one page*, by `Browser.mountAt` and `Browser.programs` (§15.11,
  *The program*). `tests/corpus/browser/tea/TwoPrograms` mounts one program at the body and a
  second at a `<section>` the first renders: a click on the inner program's button reaches it, and
  bubbling on, the section's and its parent's handlers reach the outer one; a click in the outer
  program reaches it alone. Starting the handler's search at the mount node itself sends the
  section's message to the inner program, and stopping the walk at the first `$$root` loses the
  parent's; the fixture fails either way. A missing element and a doubly used one throw at start,
  and no page fixture states it: an uncaught exception fails a page case rather than being its
  golden (`tests/corpus/README.md`).
- **Bytes.** `bench/size.mjs` prints the empty mounted page per platform: for `browser`, 21 740 raw,
  6 251 brotli in development and 21 309 / 6 178 with `--release`; `browser-tea` one module and 163
  raw bytes more (2026-09-29). The runtime file is almost all of it (20 647 bytes): a sibling is
  copied whole, neither eliminated nor printed compactly by `--release`, which is where W11's
  second half will find its bytes.
