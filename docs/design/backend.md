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
| `--source-maps` | a `.mjs.map` beside every emitted module (§11.1); `--no-source-maps` writes none | on in dev; refused with `--release` until release maps exist |

*Amended 2026-10-01: development source maps are built (§11.1).* A development build writes a map
beside every module by default; `--source-maps` states that default and `--no-source-maps` turns
it off (both together exit 2). The refusal described next survives for `--release` only:
`--release --source-maps` exits 2 with `beni: --source-maps is not implemented for --release yet; a
release build writes no .map file`, by the same argument, and `--release` alone writes no map. The
two paragraphs below are kept as the record of why.

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
last build wrote* below — is not `.mjs` and is never imported. *Amended 2026-10-01:* nor is a
development build's `<module>.mjs.map` (§11.1), which a debugger reads and nothing imports.) A copied file cannot simply keep its stem, because `out/_core/List.mjs` is already the
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
`boundary.md` §4's checks do. The list is built in module order, which is file-index order (`fast-compiler.md` §10) and
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

### The page shell, `index.html`

*Added 2026-10-01* (Milestone 1's developer loop, `frontend.md` §10). A browser program is a module
graph, and a module graph does nothing until a page loads its entry with `<script type="module">`.
Until now the developer wrote that page by hand; **the platform now declares it**, as it declares
the entry file's name (`boundary.md` §5.2), because which page loads a program is part of the
artifact's shape and differs by platform — `node` has none.

- **The key.** A platform manifest's `"html"` names a template file relative to its package root;
  like every output key it is inherited field by field down the chain (`boundary.md` §9.1), so
  `browser` declares it and `browser-tea` gets it. The **app's** `beni.json` may name its own, relative
  to the manifest's directory (`frontend.md` §10.1), and then it replaces the chain's: that is how a
  project adds a stylesheet, a title or a mount element without a compiler change.
- **The placeholders.** The template is copied byte for byte except that every `{{entry}}` becomes
  the base and the entry file's name — `/_main.mjs` by default, or what the platform's `"entry"` and
  the project's `"base"` say — and every `{{base}}` the base alone. **`{{entry}}` must
  occur at least once**: a page that never loads the program is a build that succeeded and does
  nothing, the silent wrong answer this project refuses, so a template without it is
  `invalid_html_shell`, reported against the template at `1:1` with no excerpt. A template that
  cannot be read is the same code, reported against the manifest that named it. More than one
  occurrence is allowed — it is the author's page.
- **The output.** It is written as `index.html` at the root of `--out`, through `pending` like every
  other output, so rule 2's folding check, the `_manifest.txt` record and stale-file removal all
  apply to it unchanged. **`index.html` needs no `_`**: rule 1 is about names a MODULE can take, and
  every module's output ends in `.mjs`, so no module can reach a `.html` name under any folding.
- **When.** Only for a program build: a `--library` build writes no entry file, so it has nothing
  to load and writes no page. A chain and an app that name no `"html"` write none, so a `node` build's
  tree does not move by a file.
- **Development and `--release` write the same page.** The release entry is still one file with the
  same name, so the page is identical; nothing is inlined. No live-reload script is ever in it — that
  is `beni serve`'s, injected into the HTTP response and never written (`frontend.md` §10.4).
- **Deterministic**: the bytes are a function of the template, the entry name and the base alone.
- **Absolute, from the base** (*amended 2026-10-01, the manager's decision before merge*). The
  entry path is the project's `"build"."base"` (`frontend.md` §10.1) followed by the entry file's
  name, and the base defaults to `/`, so the page loads `/_main.mjs`. An absolute path is what makes
  a single-page app's nested routes work out of the box: `/todos/3`, answered with this page by
  `beni serve`'s fallback or a host's rewrite rule, still loads `/_main.mjs` — a relative
  `./_main.mjs`, the first draft, resolved to `/todos/_main.mjs` and loaded nothing. Routing is next
  on the roadmap and base `/` is the common default (Vite's). An app hosted under a sub-path says so
  once, `"base": "/app/"`; a template may also write `{{base}}` for its own links
  (`{{base}}favicon.ico`). A base must end in `/` — `/app` would make `/app_main.mjs` — and may not
  hold a quote, `<`, `>` or whitespace, which would end the attribute it is written into; anything
  else is an exit-2 line naming the value (`frontend.md` §10.1).

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
| constructor | `{$: tag, a, b}` padded to a uniform shape per type; tag is a string in dev, an integer in release. *Amended 2026-10-01:* an integer only for a type no JavaScript sees, and never `Order` — §9, *Item 4, taken up* |
| record-alias constructor | the **record literal** it builds, as the record row above: `P 1 "a"` for `type alias P = { x : Int, y : String }` is `{x: 1, y: "a"}`, keys in the canonical sorted order and the arguments evaluated in written order, with no tag — the value IS a `{ x : Int, y : String }` (`language.md` §0, Elm's semantics; the owner's decision that a record alias constructor builds the record, `checker-v2.md` §21). Unapplied or partially applied it is the same wrapper any constructor gets, `(a, b) => ({x: a, y: b})`. As a **pattern** (`nameOf (P n _) = n`) it is irrefutable — one constructor — and reads argument `i` as the alias's field `i` in declaration order, `.x` then `.y`, with no test (decided 2026-09-24 under rule 7). An **imported** alias's constructor is the same record, built and read by the field names interface v3's `record_alias` constructor row carries (`checker-v2.md` §14.2): until 2026-09-25 it was `not_implemented`, because interface v2 had no names |
| nullary constructor | the bare tag — or, for a type that also has a constructor with fields, one module-level constant object per constructor (*A nullary constructor is one object*, below; 2026-09-29) |
| tuple | fixed-shape object per arity, no runtime tag |
| list | cons cells (`{$:1, a, b}` / the empty singleton), pending a benchmark of a vector trie. A literal of more than 32 elements is ONE array whose cells `reduceRight` builds (*Emitted JavaScript nests only as deep as the source*, below). *Amended 2026-10-01, the owner's decision (W35):* **a list is array-backed** — a plain JavaScript array, a view, or a 32-way trie with a claimable tail; *Lists are arrays*, below, is the contract, and it replaces this row when `plans/list-arrays.md`'s second slice lands. *Amended 2026-10-01 again (W35, E1tp):* the trie has a claimable **head** as well, so prepending is as cheap as appending (*The claimable head: E1tp*, below) |
| string | native JavaScript string; core's API exposes codepoints where the UTF-16 mismatch would show |
| `Int` | a number |
| `Int32` | **a number too** — an ordinary JavaScript number held in signed 32-bit range by every operation that produces one, with no box and no tag, so `toInt` is the identity and the whole cost of the type is the `\| 0` (ECMA-262's ToInt32) that keeps the invariant true. `mul` is `Math.imul` and `shiftRightZero` is `(x >>> n) \| 0`, because `>>>` answers unsigned. The type exists in beni and not at run time, which is what makes it free; `core/Int32.js` and this row are the contract (`fast-compiler.md` §3.1, `checker.md` Appendix B). *(Amended 2026-10-01: `core/Int32.beni` is, written over `Js` — `plans/core-in-beni.md` — and has no sibling.)* |
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
   *Amended 2026-10-02:* no optimiser took it, and arithmetic is an operator in both builds now —
   *Arithmetic is an operator*, below.

And one thing §4's table is silent on that the emitter had to settle: **where the empty list comes
from.** "cons cells (`{$:1, a, b}` / the empty singleton)" does not say who owns the singleton, and
it cannot be a sibling export because `boundary.md` §4's second check forbids a sibling from
exporting anything that is not a declared `foreign` value. The backend emits `{$:0,a:null,b:null}` inline,
and `core/List.js` and `core/String.js` build the same shape by contract. That contract is the one
piece of the representation that is written down in two places.

Two more rows the table did not state and the backend needed: a **`Char`** is a one-scalar JavaScript string
(§4 says strings are native and core's API exposes code points; a `Char` is the one-character case
of that), and **`()`** is `null` (under `--release`, `null` or `undefined`: *A `()` result is not written*). Neither is contentious; both are recorded because the table did
not say.

**Lists and strings are the two representation questions §14 left open.** The backend ships cons cells and
native strings, which are Elm's answers and the ones pattern matching and interop respectively push
toward. The optimiser benchmarks a 32-way persistent vector trie against cons cells on real idiomatic code, as
open question 2 requires, and records the result here either way.

*Amended 2026-10-01.* The benchmark was taken (research 38 §3–§17, research 46) and the list half
is decided: *Lists are arrays*, below. The empty list then comes from nowhere in particular — it is
`[]` — and the paragraph above about its singleton being written down in two places is withdrawn
with the cons cell; what every file that reads a list shares instead is that subsection's
three-point protocol.

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

### Lists are arrays

*Added 2026-10-01. Specified, not built: it lands in the slices of
[`plans/list-arrays.md`](../../plans/list-arrays.md), and until its second slice does, the cons
cells of the table above are what the compiler emits.* *Built 2026-10-01: the plan's second slice
has landed, so this subsection describes what the compiler emits; its §2's slice-2 note, *As
built*, lists where the build departs from the text below — a building loop's exit is
`List$close`, not `Basics$append`; a spread with items after it binds a `slice`; `eq` and
`compare` do not answer at once for a list against itself; builders are made their final size
(`builder`, `put`, `add`, `done(b, n)`) — and the manager's decision O6: a `++` the checker solved
to lists calls `List.append` (the `a ++ b` row below).* The owner decided on 2026-10-01
([`plans/browser-decisions.md`](../../plans/browser-decisions.md) W35, amended) that beni has **one
sequence type**: `List` becomes array-backed, there is no `Array` and no cons list, `[a, b]`
literals and `x :: rest` patterns stay (the pattern is an O(1) view), programs build at the end with
`push`, and the compiler rule that turns an `x :: rest` walk into an index loop ships with it.
*Amended 2026-10-01 again, the owner (W35's E1tp amendment):* the representation is **E1tp**, E1t
below plus a claimable head (research 46 §11), so `[ x, ...xs ]` is amortised O(1) as `push` is.
*The claimable head: E1tp*, below, says what it adds; where the E1t text of this subsection says
otherwise, an amendment marked *E1tp* beside it wins. This subsection is the normative contract for the representation, for the runtime that `core/List.js`
provides, for the invariants every writer of JavaScript keeps, and for the identities a platform may
rely on. The rest of the contract lives where each part belongs, once:

| What | Where |
|---|---|
| the surface: literals, `::` both ways, `++`, the `core/List` API with each function's cost, identity promises, callbacks | [`language.md`](language.md) §6.8 |
| list patterns: occurrences, tests, bindings, re-consing a match | §7, *List patterns over arrays* |
| tail calls modulo cons onto an array; scalar views of an `x :: rest` walk | §8, *Tail calls modulo cons, onto an array*, and *Scalar views* |
| `For`, `List (Html msg)` holes, class and style lists | §15.5, *`For` over arrays* |
| what a `foreign` sibling receives and returns | [`boundary.md`](boundary.md) §4, *How a sibling sees a `List`* |
| decoders and encoders | [`schema.md`](schema.md) §6, *Lists are arrays* |
| suspending bodies | [`transparent-effects-proposal.md`](transparent-effects-proposal.md) §16.3's amendment of 2026-10-01 |
| the migration, the slices, their tests and measurements | [`plans/list-arrays.md`](../../plans/list-arrays.md) |

The evidence is [research 38](research/38-immutable-array-representations.md) §15–§17 (the adaptive
array, one type against two, array-first code), [research 46](research/46-every-sequence-candidate-on-every-scenario.md)
(every candidate on every scenario in one harness), [research 40](research/40-array-sibling-under-brotli.md)
(how the sibling is written for brotli and for elimination) and
[research 42](research/42-reference-counts-in-javascript.md) (in-place writes, not taken here). The
prototype this contract follows is `bench/arrays/ports/first-tail.js` (the runtime),
`bench/arrays/lists/first-core/List.{beni,js}` (the core) and `bench/arrays/seq/e1t.js`.
*Amended 2026-10-01 (E1tp):* the runtime's prototype is `bench/arrays/ports/first-tail-prepend.js`
(`bench/arrays/seq/e1tp.js` is its candidate module), checked by
`bench/arrays/lists/claim-prepend-test.mjs` (3.04 million checks on old versions, research 46
§11.2); `first-tail.js` stays the record of E1t.

#### The representation: E1t

The representation is the one research 38 §17.2 calls **E1t**: *E1* — §16's adaptive array, a plain
JavaScript array until something writes to it, plus the O(1) view an `x :: rest` pattern makes —
with a claimable **t**ail on its trie. A `List` value is one of three **forms**:

| Form | JavaScript | Which lists have it |
|---|---|---|
| **plain** | a JavaScript array; the elements are `a[0] … a[a.length − 1]` | every list nothing has written: `[]`, a literal, and the result of every operation that builds a fresh sequence — `map`, `filter`, `range`, `initialize`, `slice`, `reverse`, the sorts, `concat`, `::`, `++`, `insertAt`, `removeAt`, a decoder, a sibling — and a list written below the thresholds. *E1tp:* `::` (`[ x, ...xs ]`) only onto a list of fewer than 32 elements |
| **view** | `{ b, o, length, $plain }`: the elements `b[o] … b[b.length − 1]` of a plain array `b` | what an `x :: rest` pattern binds as `rest`, `List.tail`, `List.drop`. Never empty, `o ≥ 1`, `length === b.length − o`: a view is always a **suffix** of its backing array. *E1tp:* only of a plain list or a view; those of a trie are tries |
| **trie** | `{ length, s, r, t, p, $plain }`: the Clojure and Elm 32-way persistent vector — a root `r` whose height is the shift `s` (a multiple of 5), leaves of exactly 32 elements, and a **tail** array `t` holding the last 1 to 32 elements; `p` is the cached plain copy, or `null`. *E1tp:* `{ length, h, hc, T, t, p, $plain }`, with a claimable head `h` and the tree `T = { r, s, off, tc }` at a radix offset (*The claimable head: E1tp*, below) | the result of a single-element write (`set`, `update`, `swap`, `push`, `pop`) to a plain list above its threshold, and every write to a trie. *E1tp:* also a prepend onto a list of 32 or more, and a trie without its first elements (`rest`, `tail`, `drop`) unless only tail elements are left |

**The thresholds.** `push` converts a plain list of **32** elements or more to a trie; `set`,
`update`, `swap` and `pop` convert one longer than **256**. Below them a write is copy-on-write and
the result is plain. The two numbers are research 38 §15.11 and §17.2's, they are constants of
`core/List.js`, and a change to either is a measurement's to make, on research 38 §15's and §17's
scenarios through `bench/arrays`. A read-mostly UI list of up to 256 rows therefore stays plain through `set`, and a list
built by `push` stops copying at 32.

**The representation is not canonical.** The same elements may be any of the three forms, and no
result a beni program can compute depends on which: `==`, `compare`, `Debug.toString`, every
function of `core/List`, every sibling and every platform runtime accept all three. Only speed, and
the identities of *Identity* below, can tell them apart.

#### The claimable head: E1tp

*Added 2026-10-01, the owner's E1tp amendment of W35* (research 46 §11; the prototype is
`bench/arrays/ports/first-tail-prepend.js`). Under E1t, `[ x, ...xs ]` copied `xs`, so Elm-shaped
code that builds at the front — an accumulator then `List.reverse`, `foldr` building a list, a
persistent stack, paths that share their tails, a TEA list that gains rows at the top — was
quadratic: 11–2 500× the cons list at 10 000 elements on research 46 §11.4's table A. **E1tp** gives
the trie a second claimable buffer at its front, after Scala 2.13's `Vector` but without its
per-level prefix arrays: one header shape and a **radix offset**. The plain and view forms, the
thresholds and everything this subsection does not name are E1t's, unchanged.

**The trie.** A header is `{ length, h, hc, T, t, p, $plain }`:

| Field | What it holds |
|---|---|
| `length` | the number of elements, a data field as on the other two forms |
| `h`, `hc` | the **head**: the first `hc` elements, `0 ≤ hc ≤ 32`, stored **reversed** — element `i < hc` is `h[hc − 1 − i]` — so that a prepend is an append to `h`, claimed as `push` claims the tail |
| `T` | the **tree**, `{ r, s, off, tc }`: `tc` elements at radix positions `off … off + tc − 1` of the root `r`, whose shift is `s`; element `j` of the tree is `r[(off + j) >>> s & 31] … [(off + j) & 31]`. `off` and `tc` are multiples of 32, so the tree is whole leaves and only where it starts moves. `T` is an object of its own, shared by every header between two changes to the tree — a prepend or a push that stays in its buffer, a tail inside the head, a `pop` inside the tail — so a list operation allocates a header of seven fields and not the tree |
| `t` | E1t's **tail**: the last `length − hc − tc` elements, 1 to 32, never empty |
| `p`, `$plain` | E1t's: the cached plain copy or `null`, and the protocol's function |

Element `i` is `h[hc − 1 − i]` for `i < hc`, the tree's element `i − hc` for `i < hc + tc`, and
`t[i − hc − tc]` after it: one comparison more than E1t in front of the same O(log₃₂ n) descent and
no size table (research 46 §11.4 table C: `get` 5.1 ns against E1t's 5.3). A trie is never empty,
and `length > hc + tc` always.

**Prepending**, `cons(x, xs)`, which `[ x, ...xs ]` lowers to:

| Onto | Result | Cost |
|---|---|---|
| a trie with `hc < 32` and `h.length === hc` | **the head claim**: `x` is appended to `h` in place and a new header shares `h`, `T` and `t` | O(1) |
| a trie with `hc < 32` and `h[hc] === x` | the slot past this version's head already holds `x` — the version is the tail of one that began with `x` — so a new header with `hc + 1`, nothing written | O(1) | O(1) |
| any other trie with `hc < 32` | a copy of the `hc` head elements this version owns, then `x` | at most 32 |
| a trie with `hc === 32` | the head is reversed into a **fresh** leaf at radix `off − 32` (a path copy), `off` moves left by 32, and the head becomes `[x]`. When `off < 32` the root first **grows left**: a new root holding sixteen `null`s and then the old root, so the old root is child 16 and `off` moves right by sixteen of its spans; an empty tree starts at `off = 512`, mid-root, with room on both sides. `null` fills every gap left of a child, so every node stays a packed array | O(log₃₂ n), once every 32 prepends |
| a plain list or a view of fewer than 32 elements | a fresh plain array, as under E1t | at most 32 |
| a plain list or a view of 32 or more | converted to a trie once — E1t's layout, a fresh empty head, the tree at `off = 0` — and prepended onto; every later prepend onto it or a version made from it is one of the rows above | O(n), once per plain list |
| a view `(b, o)` with `b[o − 1] === x`, tested before the two rows above | **the runtime re-cons**: the view `(b, o − 1)`, or `b` itself when `o = 1`; nothing copied | O(1) |

So a prepend is **amortised O(1) onto the newest version**, a copy of at most 31 elements onto an
older one, and O(n) at most once per plain list it converts.

**Removing a prefix.** `view(xs, k)` of a trie — a pattern's `rest`, `List.tail`, `List.drop` — is
a trie sharing the tree, never a flatten:

- `k ≤ hc`: a header with `hc − k`, sharing `h`, `T` and `t`.
- otherwise `k′ = k − hc` more elements leave the tree's front. With `k′ < tc`, `⌊k′/32⌋` whole
  leaves go by moving `off` right and `tc` down by 32 each, the nodes untouched; then, if
  `k′ mod 32` is not 0, the rest of the new first leaf becomes the head — a reversed **fresh** copy
  of at most 31 — and `off` and `tc` move one leaf more. (The prototype writes `k = 1`; general `k`
  is the same rule, Scala's drop by offset.)
- with `k′ ≥ tc`, only tail elements are left: a fresh plain array of at most 32, or `[]`.

That is O(1) and a copy of at most 31 elements — once every 32 steps of a walk. E1t made the tail
of a trie a view over the trie's cached plain copy, O(1) after an O(n) flatten but O(n) again to
prepend onto, which is exactly what a persistent stack does after a pop (research 46 §11.4,
*undo stack*: 41.3 ms → 429 µs).

**Everything else** is E1t's: `push` claims the tail, whose full array moves into the tree as the
leaf at radix `off + tc`, the root growing right; `pop` shares the tail, or makes the tree's last
leaf the tail, or — with no tree left — returns the head reversed as a fresh plain array, and it
collapses a root left with one live child; `set` copies the head, the tail or the path its index
falls in; `slice` and every bulk operation read through the cached plain copy and return plain
arrays.

**The radix positions are unsigned 32-bit.** The descent uses `>>>`, so every position stays below
2³². Pushes alone would reach it only past 2³² elements, more than a JavaScript array can hold; left
growth centres the old root, so one lineage reaches it after roughly 2²⁹ prepends — some 4 GB of
element references, beyond any browser tab's heap. `core/List.js` states the bound in a comment and
carries no check.

**What it costs and buys** (research 46 §11.4–§11.6, Node, one round at 10 000 elements). Every
Elm-style row that was quadratic under E1t is linear: `x :: acc` then `reverse` 42.1 ms → 547 µs,
kept paths 423 ms → 1.16 ms, `foldr` building a list 55.5 ms → 526 µs, a TEA `Remove` 24.5 ms →
555 µs. Elm-style code still runs at 3–7× the cons list, so building with `push` stays the idiom to
teach. Array-first code costs what it cost under E1t within the batch's noise, except pushes at up
to about 1.3× (the extra indirection of `T`) and the merge sort of sorted input at about 2× (a
header per tail of a trie where E1t made a view over its cached copy; §8's *Scalar views* removes
both). The sibling grows by **429 bytes brotli**, 3 468 → 3 897 on the whole surface.

#### Invariants

Every piece of JavaScript that touches a list — `core/List.js`, the emitted code, a sibling, a
platform runtime, the derived-comparison engine — keeps these. A list is **published** from the
moment any code other than the operation creating it can reach it.

1. **Nothing published is written**, with exactly two exceptions, both invisible to every reader:
   - **The claim.** A trie's tail array `t` may be written at index `c`, this version's tail count
     (`length` minus the offset of its tail), **only when `t.length === c` and `c < 32`**: `push`
     onto the version that owns the end of `t` appends in place and returns a new header sharing
     the array. Every other version sharing `t` reads only its own first `c′ ≤ c` elements, so none
     can see the write. `push` onto any other version copies the at most 31 elements its tail owns
     first — never the whole list — and `pop` returns a header sharing `t`. This is Go's `append`
     made persistent by each version's own length (research 38 §17.2); it needs no analysis, and
     `bench/arrays/lists/claim-test.mjs` checked it 2.39 million times on randomly chosen old
     versions two levels deep.
   - **The cache.** A trie header's `p` is written once, from `null` to a fresh plain array holding
     its elements, the first time a walk, a `$plain()` or a bulk operation needs one. A view may
     cache its own `$plain()` the same way. It is derived data.
   - **The head claim** (*amended 2026-10-01, E1tp*: the exceptions are three). A trie's head array
     `h` may be written at index `hc`, this version's head count, **only when `h.length === hc` and
     `hc < 32`**: a prepend onto the version that owns the end of `h` appends in place and returns a
     new header sharing it. It is the tail claim mirrored, and it is invisible for the same reason:
     every header's `hc` is at most `h.length`, and every other version sharing `h` reads only its
     own first `hc′ ≤ hc` slots. A slot of `h` is therefore written **at most once**, which is what
     makes the prepend that finds `h[hc] === x` already there sound without writing. A prepend onto
     any other version copies at most 31 elements, and a tail inside the head shares `h`.
     `bench/arrays/lists/claim-prepend-test.mjs` checked the two claims together 3.04 million
     times on randomly chosen old versions, through two left growths of the root.
2. **A trie's tail is never a plain list's array, and never a leaf while it can be claimed.**
   Converting a plain list copies it (the tail too, so a claim never writes into an array some
   plain list is). A full tail of 32 moves into the tree as a leaf unchanged, and no version can
   claim it after: a claim needs `c < 32`, and a leaf is 32 long. No leaf and no inner node is
   written after the header that first published it. *Amended 2026-10-01 (E1tp):* **the same holds
   for the head, which is never a leaf at all.** A conversion starts a fresh empty head; a full head
   becomes a leaf only as a reversed *copy*; a head made from the tree's first leaf (removing a
   prefix) is a reversed fresh copy of at most 31. A leaf can become a **tail** — `pop` makes the
   tree's last leaf the tail — and is still never written, because it is 32 long and a claim needs
   `c < 32`. Left growth writes a new root and never the old one.
3. **A view's backing array is plain.** The tail of a trie is a view over its cached plain copy.
   *Amended 2026-10-01 (E1tp):* the tail of a trie is a trie, or a fresh plain array when only
   tail elements are left (*The claimable head: E1tp*); a view is made only of a plain list or a
   view, and its backing array is still plain.
4. **The empty list is plain.** No view and no trie is empty: `view` at the end, `pop` of the last
   element and `slice` to nothing return `[]`.
5. **A builder is owned.** A builder is a plain array one loop writes with `push` and then hands
   over, once, as a plain list, after which it is never written: `core/List`'s core-private
   `Builder` (below) and the destination of §8's tail calls modulo cons. It is used **linearly** —
   every `add` returns the builder, and that result is the only thing the loop uses next — so no
   code other than its loop can see it before the hand-over, and neither §9 item 1's dead-binding
   rule nor its single-use inlining can drop or reorder a write. A resumption of a suspended fiber
   is one-shot (`transparent-effects-proposal.md` §16.1), which is what makes a builder captured by
   a continuation sound; a multi-shot continuation would have to copy it.
6. **Elements are references.** No operation copies, wraps or rebuilds an element: what comes out
   is `===` what went in (research 38 §7's *element identity*).

What these invariants do not permit is the rest of what an array can do in place. In particular a
`set` or `push` whose input is provably unique is still a copy or a new header here; static
in-place writes (research 42's R0) are a later optimisation that would relax invariant 1 only under
a proof, and nothing in this contract depends on them.

#### What a reader of a list may rely on: the protocol

Code that reads a list without being `core/List.js` — a sibling, a platform runtime, the markup
runtime, the derived-comparison engine, `Debug` — may rely on exactly three things, and on no field
name of a view or a trie:

1. **`xs.length`** is the number of elements, in every form.
2. **`Array.isArray(xs)`** is true exactly for the plain form, whose elements are `xs[0 … length − 1]`.
3. Otherwise **`xs.$plain()`** returns a plain array of the elements, which the caller must not
   write. For a trie it is computed once and cached (invariant 1), so a second call on the same
   header is O(1).

The idiom is one line, and every first-party file that reads a list uses it:

```js
const a = Array.isArray(xs) ? xs : xs.$plain();
```

**A value is a list exactly when `Array.isArray(v) || typeof v.$plain === "function"`.** No other
beni value is a JavaScript array (a tuple is `{a, b, …}`, §4), and no record can have a field called
`$plain` (a field name is a lower-case identifier), which is how `Debug.toString` tells a list from
anything else.

`$plain` is a **field** holding one shared function expression — `$plain: TriePlain` in the header
literal, reading `this` — and not a prototype method. `Minify` declines a file that mentions `class`
or holds a top-level expression statement such as `T.prototype.m = …` (§9, *Hand-written JavaScript
under `--release`*), and no file in `core/` may be declined. Property names are never renamed by
§9's passes (a key before `:` and a property after `.` are not bindings), so `length`, `$plain` and
`push` survive every build.

What a sibling may **return** as a list is [`boundary.md`](boundary.md) §4's: a fresh plain array
that nothing else holds and that it never touches again, or a list it was given.

*Amended 2026-10-01 (E1tp):* **the protocol is unchanged, still three points.** A trie header
carries `length` as a data field — as this contract always said; research 46's E1t prototype called
it `n`, which is why §11.2 of that report mentions the change — so `length` and the empty test read
one field on every form. The head, its reversal, the radix offset and the shared tree object are
private to `core/List.js`: no reader sees `off` or `hc`, because `$plain()` returns the elements from
index 0 in order — the head reversed, then the leaves from radix `off`, then the tail cut to this
version's count — and caches the array as E1t's did. Neither claim is a reader's business: only
`core/List.js` writes a head or a tail.

#### The runtime: `core/List.js`

*Amended 2026-10-02, the owner's decision on research 50 §7 (`plans/core-in-beni.md` step 3):*
**the runtime is beni, in `core/List.beni`.** Every row of the table below is a declaration with a
beni body written over `Js` — the view and trie headers are `Js.object` literals with the keys and
key order of this section (one call site per form, so one hidden class per form), their `$plain`
is a `Js.method` held in a top-level value (`backend.md` §4, *`Js.method` is a `function`*), the
claims are the same runtime tests (`b.length === c` before a `push`), and the loops are tail-call
loops (§8). `eq` and `compare` are beni loops over the `where` evidence, so they are no longer
`foreign` and their evidence needs no `sync` covering. What the text below calls "exports of
`core/List.js`" are those declarations; the emitter imports `unsafeGet`, `view`, `base`, `offset`
and `close` from `_core/List.mjs` as before (*The emitter's imports of the core-private exports*).
The sibling `core/List.js` keeps only `length`, `at`, `put`, `identical`, `kept` and `half`, which
the code generator writes in place (*`List.beni`'s loops read and write in place*), for a value of
one; a program ships none of it. Invariants, protocol, identities and costs are unchanged: the
claim sweep (`bench/arrays/lists/claim-prepend-test.mjs core`) runs against the runtime compiled
from `List.beni` (`core-shipped.mjs` builds it), and every `run/` program prints its golden in
both builds.

`List a` stays `pub equatable foreign type List a`: it has no constructors, and the checker is not
touched by any of this. `core/List.js` is the one file that knows the view and trie forms. Its
exports, each a `foreign` of `List.beni`, are the runtime every other part of this contract calls:

| Export | Visibility | What it does | Cost |
|---|---|---|---|
| `cons(h, t)` | `pub` (`::` desugars to it, `language.md` §6) | a fresh plain array `[h, …t]`. *E1tp:* the list `h` then `t` by *The claimable head*'s table: plain only onto fewer than 32 elements; `t`'s wider view, or its backing array, on a runtime re-cons | O(n). *E1tp:* amortised O(1) onto the newest version, at most 31 copied onto an older one, O(n) once per plain list converted |
| `append(xs, ys)` | `pub`; *added 2026-10-01 (E1tp)*: `List.append`, what `[ ...xs, … ]` lowers to (`language.md` §6.8), becomes `foreign` | `xs` when `ys` is empty and `ys` when `xs` is; when `xs` is a trie, or has 32 elements or more while `ys` has fewer than 32, each element of `ys` **pushed** onto `xs` (a plain `xs` converted first, as `push` converts it); otherwise a fresh plain concatenation. *Amended 2026-10-02:* a trie `xs` is concatenated too when `ys` is at least as long (the copy is within twice the elements appended, and a plain result is what a `For` reads without a copy), and `ys` is pushed a leaf at a time — one header, the tail filled as `push` claims it, each further 32 a slice of `ys` — not an element at a time | O(m) amortised when it pushes — so `[ ...xs, x ]` costs what `push xs x` does — and O(n + m) otherwise |
| `length(xs)` | `pub` | `xs.length`; *amended 2026-10-02:* a call is written in place as `xs.length` (*`List.beni`'s loops read and write in place*, below) | O(1) |
| `concat(ls)` | `pub`; *added 2026-10-02*: `List.concat` becomes `foreign` | the one non-empty list itself, `[]` when none is, otherwise a fresh plain array made its final size | O(total) |
| `set(xs, i, v)` | `pub` | the list with element `i` replaced; `xs` itself when `i` is out of range or `v` is `===` the element there | a copy ≤ 256, else O(log₃₂ n) after one conversion |
| `push(xs, v)` | `pub` | the list with `v` added at the end | a copy < 32, else amortised O(1): one header, at most a 31-element tail copy when this version was pushed onto before, and a path copy every 32nd push |
| `pop(xs)` | `pub` | the list without its last element; `xs` when empty | a copy ≤ 256, else O(1) sharing the tail, O(log₃₂ n) every 32nd |
| `slice(xs, from, to)` | `pub` | Elm's `Array.slice`: negative indexes count from the end, both clamped; `xs` itself when the range is all of it; `[]` when `from ≥ to` | O(k) for a result of k, plain |
| `insertAt(xs, i, v)`, `removeAt(xs, i)` | `pub` | insert before `i` (`0 ≤ i ≤ length`), remove at `i`; `xs` when out of range | O(n), plain |
| `swap(xs, i, j)` | `pub` | exchange two elements; `xs` when either is out of range or `i === j` | two `set`s |
| `eq(m0, xs, ys)`, `compare(m0, xs, ys)` | `pub`, `where` evidence first (§4 check 4) | element by element, index loops over all three forms; `xs === ys` is `True`/`EQ` at once; the shorter list is `LT` against a longer one that starts the same | O(n) |
| `unsafeGet(xs, i)` | core-private; the emitter imports it | element `i`, for `0 ≤ i < length`, which the caller guarantees | O(1) plain or view, O(log₃₂ n) trie |
| `view(xs, k)` | core-private; the emitter imports it | the list without its first `k` elements, `0 ≤ k ≤ length`: `xs` when `k = 0`, `[]` when `k = length`, otherwise a view (of a view's backing array, or of a trie's cached plain copy). *E1tp:* of a trie, the trie without its first `k` elements (*Removing a prefix*, above), never a view | O(1), after at most one conversion of a trie per header. *E1tp:* O(1) and at most 31 copied, never a flatten |
| `base(xs)`, `offset(xs)` | core-private; the emitter imports them | the plain array `xs` is a suffix of, and where in it `xs` starts: `(xs, 0)` for plain, `(b, o)` for a view, `(p, 0)` for a trie | O(1) after that conversion |
| `builder(n)`, `add(b, x)`, `done(b)` | core-private, for `List.beni` alone | invariant 5's builder: `[]`, `b.push(x); return b`, `b`. `n` is a size hint the implementation may ignore | O(1) amortised |
| `at(a, i)`, `put(b, i, x)` | core-private, for `List.beni` alone; *added 2026-10-02* | `a[i]` of an array `base` returned, and `b[i] = x; return b` into a builder; the code generator writes both in place (*`List.beni`'s loops read and write in place*, below), and `add` is withdrawn: no loop grows a builder | O(1) |

`core/Basics.js`'s `append` — what `++` lowers to — keeps its string half and gets a new list half,
written against the protocol and not the forms: `ys.length === 0 ? xs : xs.length === 0 ? ys :
plain(xs).concat(plain(ys))`. It is O(n + m) and returns a fresh plain array unless one side is
empty, in which case it returns the other side itself. A sibling cannot import another file (§2),
which is why the list half is written against the protocol rather than calling `core/List.js`.
*Amended 2026-10-01 (E1tp):* that is why `++` stays O(n + m) while `[ ...xs, ...ys ]`, which lowers
to `core/List`'s own `append` (the row above) and so can reach the trie, pushes when it can. The two
spellings make equal lists and differ only in cost; `language.md` §6.8 says so where a programmer
reads it.

`List.beni` holds everything else, written in beni over this first-order surface (research 38
§12.2): every function that takes a callback is a beni loop over `unsafeGet`, so a callback that
suspends parks the loop (`language.md` §6.8, *Callbacks*). `eq` and `compare` stay `foreign` with a
`where` clause as they are today; their evidence is `sync` without being written
(`boundary.md` §4, the `sync` step), because a well-known `eq` or `compare` cannot suspend.

*Amended 2026-10-02:* **`List.beni`'s loops read and write in place.** A loop over `unsafeGet`
and `put` calls two functions every element, and every loop of a program calls the same two, so
their property accesses see every array a program has and go megamorphic: `map2` at 1 000
elements was 3.5× the cons list's. So a loop takes its list's `base` and `offset` once and reads
element `i` as `at a (o + i)`, and the code generator writes the core-private `at`, `put`,
`identical`, `kept` and `half` as the JavaScript they compute — `a[i]`, the statement `b[i] = x;`
then `b`, `x === y`, `s ? o : b`, `n >>> 1` — exactly as it writes `Basics.add` as `+`
(*Arithmetic is an operator*), keyed on the core package, the `List` module and the name. Each
loop then has property accesses of its own, as each cons walk had. `put`'s builder is bound to a
name first when it is not one, since it is read twice; the store runs where the call ran, after
its operands. `List.length xs`, in any module, is `xs.length` by the same rule: every form
answers it (*What a reader of a list may rely on*). The exports stay in `core/List.js`, what a
value of one would be, and `Reach` drops the edge a written-in-place call would add, so a program
ships none of the six. A trie's `base`
is its plain copy, made once per header (invariant 1's cache), where `unsafeGet` descended per
element. `concat` takes no function and so becomes `foreign`: one JavaScript loop copies every
list into an array made its final size, where a beni loop paid a call per list, and `concatMap`
is `concat (map xs func)`.

**The emitter's imports of the core-private exports.** `unsafeGet`, `view`, `base` and `offset` are
not `pub`: a program that could call `unsafeGet` out of range would read `undefined` as a value of
any type, which is exactly what the language promises cannot happen. The emitter imports them as it
imports `List$cons`, from `_core/List.mjs`, which exports them for the emitter although beni code
outside `List.beni` cannot name them; it recognises them by well-known symbol — core package, `List`
module, the symbol — as it recognises `List.cons` (§8) and `Basics.and` (§4), never by spelling.
The lowering records each use as it records a derived comparator's (§9, *Reachability
elimination*), so a program with no list pattern imports none of them and the one hoisted file
(§9) holds none of them.

*Amended 2026-10-02:* the five — `unsafeGet`, `view`, `base`, `offset` and `close` (§8's building
loop's exit) — are exported when they survive **whether `core/List` writes them `foreign` or with a
beni body**: the importing module cannot tell the two apart, and an export kept to `foreign` ones
made a beni body a program that fails to load. For the same reason each counts as a value whose
result is read (*A result nothing reads*): the emitter's calls are in no module's BIR, and a
beni-bodied `close` written without its `return` handed every building loop `undefined`.

*Amended 2026-10-02:* **the five are part of the core contract.** A core package that does not
declare one — only a `--core-root` core can lack it — is refused with `core_contract_violation`
where a module first needs it (once per module and value), and nothing is written: the import by
printed name would otherwise name an export `_core/List.mjs` does not have, and the program would
build with exit 0 and fail to load. A program that never needs the missing value still builds. The
same code replaces `internal` for the two values a comparison reaches for, `Basics.eq` and
`String.compare` (`static-dispatch-spike.md` §8), which are the same failure. *(Amended the same
day: `Basics.eq` is no longer one. The `undetermined` leaf it answered is `===` written in place,
since `Basics.eq` dispatches like `==` — `static-dispatch-spike.md` §3.1, amended — so a comparison
reaches for `String.compare` alone.)*

#### Identity: what an operation returns unchanged

`language.md` §11.12 promises that a value a program does not rebuild keeps its identity, and the
markup runtime skips work on `===` (§15.5, §15.8). For lists that promise is these guarantees, which
research 38 §7 measured for the ports this runtime is built from, and which `core/List` documents as
guarantees on each function:

- **The input itself**, not an equal copy, from: `set`, `update` and `swap` out of range or writing
  the identical value (`===`, not `==`) and `swap xs i i`; `insertAt` and `removeAt` out of range;
  `slice` and `take` covering the whole list, `drop xs 0` and `view xs 0`; `xs ++ []` and
  `[] ++ ys`; `filter` keeping every element; `map` and `indexedMap` when every result is `===` its
  element (one comparison per element — the result built is dropped); `reverse`, `sort`, `sortBy`
  and `sortWith` of fewer than two elements; `pop []`; `concat` and `concatMap` when exactly one
  list is non-empty (that list). The last replaces the cons list's sharing of a tail, which an
  array cannot do: `append` no longer shares its second list, and `concat` no longer shares its
  last non-empty list unless it is the only one.
- **Element identity** always (invariant 6).
- **A view is the same list as another view of the same backing array at the same offset.** Two
  matches of `x :: rest` against one list bind two view objects, and `===` tells them apart where
  the cons list's `rest` was one cell. The markup runtime therefore compares with `same(a, b)` —
  `a === b`, or both views with the same `b` and `o` — on the miss path of every identity check
  that can see a list (§15.5). `language.md` §11.12's amendment of 2026-10-01 states the promise
  this way.
- *Added 2026-10-01 (E1tp):* **a prepend that re-conses a view gives back the wider list.**
  `cons(x, t)` where `t` is a view of `b` at `o` and `b[o − 1] === x` is the view of `b` at
  `o − 1` — the same list as any other view there, by the bullet above — and `b` itself when
  `o = 1`. The trie's version of it, the prepend that finds `x` already past its head, makes a new
  header sharing every array: equal, and not promised to be the same list. §7's re-consing rule,
  which the compiler applies where it sees the pattern, is what gives `===` the list matched in
  every form.
- *Added 2026-10-01 (E1tp):* **the tail of a trie is a new header at each match**, as a view is a
  new view, and the promise above extends to it: two trie headers are the same list when their
  head arrays, head counts, tree objects and tail arrays are each `===` (their lengths then agree).
  Two matches of `[ x, ...rest ]` against one trie make two such headers — `view` shares `h`, `T`
  and `t` and computes `hc` from `k` — **except when `k` exceeds the head count**, where each match
  copies a fresh head from the tree's first leaf: those two are equal and **not** promised to be one
  list. That includes the first tail of every trie whose head is empty, and so of every trie `push`
  made, where E1t's view over the cached plain copy was `same` on every match. `same` gains the
  trie case, so a `For` over the `rest` of an unchanged list skips its rows except in that one
  case, where it walks and reconciles rows whose items are all unchanged. Like its view case, `same` is written in `core/List.js`'s
  terms and is the one comparison outside that file that knows the forms' fields; slice 4 of
  `plans/list-arrays.md` decides whether it becomes a protocol point of its own.

#### What the emitter writes for list syntax

| beni | JavaScript |
|---|---|
| `[]` | `[]`, a fresh empty array at each use. Two `[]`s are not promised to be one value, as the cons list's `{$:0}` was not |
| `[ e1, …, en ]` | the array literal `[e1, …, en]`, the elements evaluated left to right (`language.md` §6, *Evaluation order*). It nests at no length, so `max_cons_elements` and the `reduceRight` form of *Emitted JavaScript nests only as deep as the source* are withdrawn with the cons cell |
| `e :: t` | `List$cons(e, t)`: `e`, then `t`, then an O(n) copy (*E1tp:* the prepend of *The claimable head*, amortised O(1)). **Folded**: `e1 :: … :: ek :: [ l1, … ]` whose innermost tail is a literal is the one literal `[e1, …, ek, l1, …]`, which evaluates in the same order and copies nothing. A `::` that re-conses what a pattern matched is §7's; one that is a step of a tail call modulo cons is §8's |
| `a ++ b` | `Basics$append(a, b)`, unchanged; the list half above. *Amended 2026-10-01, the manager on the owner's delegation (`plans/list-arrays.md` O6), reversible:* a `++` whose result the checker solved to a `List` is `List$append(a, b)` — the dispatch table's `appends`, as `==` on a list reaches `List.eq` — so it costs what `[ ...a, ...b ]` does; one over `appendable` stays `Basics$append` |
| `case` on a list | §7, *List patterns over arrays* |
| an `x :: rest` loop | §8, *Scalar views* |

No list carries a `$` tag, so no list test is a tag test and nothing in §4's constructor rows or
§9.4's padding applies to a list any more.

*Amended 2026-10-01, the owner's list syntax* (`language.md` §6.8, *The list syntax*). **`::` is
gone and the backend never sees a spread.** Lowering has already written a literal with a spread as
calls (`language.md` §8): `[ e, ...t ]` is `List.cons(e, t)` — the `e :: t` row above, folding
included, since `[ e1, …, ek, ...[ l1, … ] ]` is only ever written `[ e1, …, ek, l1, … ]` — and
`[ ...a, b1, … ]` is `List.append(a, [b1, …])`, which the flip implements like `++` (its row above;
a fresh plain array, `a` itself when the rest is empty). So the table stands with each `::` read as
its bracket spelling, and on today's cons cells nothing is emitted that `::` and `++` did not emit
before: the corpus's run outputs, migrated from `::`, are the differential test that it is so.
*Amended 2026-10-01 (E1tp):* the flip implements `List.append` not like `++` but as its own row
of the runtime table above, which pushes when `a` is a trie or `a` is long and the rest short —
so `[ ...xs, x ]` is `List.push xs x` in cost — and is a fresh plain concatenation otherwise. The
emitted calls do not change.

#### `--release`, the hoisted file and the read/write split

- **The list primitives are `pure` `foreign`s** (`boundary.md` §4's rung), so §9 item 1 treats a
  call of one as it treats any pure call: an unused `view` or `unsafeGet` binding is dropped in
  `--release` (the development build does not bind an unread tail in the first place, §7). The
  builder's `add` is declared `pure` too, which is sound only because of invariant 5's linearity;
  `List.beni` is the one place that may call it, and every call's result is the builder its loop
  passes on. A `$root.push(…)` statement that §8 writes is a method call on a local and is never
  dropped.
- **`core/List.js` is hoistable** into §9's one file: no `class`, no top-level expression statement,
  every top-level initialiser inert (literals, arrows, function expressions, objects and arrays of
  them), each export `export const f = (…) =>` with its parameter list written out (`boundary.md`
  §4 check 4). `Minify`'s unit test that no file of `core/` is declined covers it.
- **Readers never name write code** (research 40 §5 and §8's rules). A trie is born only in a writer
  (`set`, `push`, `pop`, `swap`; `update` is `set`), so the trie's write half — path copies, the
  build from a plain array, the tail claim, leaf push and pop — is mentioned by writers alone, and a
  program that imports no writer ships none of it (research 40 measured 452 bytes brotli for a
  read-only program's adaptive sibling against 901 for one that writes). Whether the trie's **read**
  half (the descent `unsafeGet` needs and the flatten `$plain` runs) can go too, through the header's
  own field, is measured in `plans/list-arrays.md`'s last slice; research 40 §5 rule 2 found a hot
  read through an indirection 15–18 % slower, so it is not assumed.
  *Amended 2026-10-01 (E1tp):* **`cons` and `append` are writers now**: a prepend onto 32 elements
  or more is where a trie is born, so the conversion, the head claim, the head-to-leaf placement and
  the root's left growth are mentioned by `cons`, and every program that writes `[ x, ...xs ]` as
  an expression ships the trie's write half, where under E1t only `set`, `push`, `pop` and `swap`
  pulled it in. `view`'s trie branch — the header arithmetic and the reversed copy of a leaf's rest
  into a head — is read-side code and is small. The slice that measures the read/write split
  (`plans/list-arrays.md`'s last) measures a program that only prepends as its own case.
- **Research 40 §8's other rules** apply to the file as written: one walk written once, parameters
  named by role, capitalised top-level names and lower-case locals, every speed-motivated line
  commented with its reason.

#### What is not done

- **No front buffer** (research 38 §17.2's E2): prepending is O(n), and no measured array-first
  program prepends. *Withdrawn 2026-10-01 by the owner's E1tp amendment:* the claimable head is
  that buffer, because Elm-style programs do prepend (research 46 §11).
- *Added 2026-10-01 (E1tp):* **No prefix levels.** Scala 2.13's `Vector` keeps `prefix1 …
  prefixN-1` arrays and running counts per level, one class per depth and a comparison against the
  counts on every read (research 46 §11.1). E1tp keeps one head buffer and moves the radix offset
  instead, so a full head becomes a whole leaf, indexing needs no counts, and there is one header
  shape.
- *Added 2026-10-01 (E1tp):* **No claim on `append`'s plain half or on `++`.** `++` is
  `Basics.append`, a sibling that cannot reach the trie (above), and a concatenation of two long
  plain lists is a fresh plain array, as under E1t; only `core/List`'s `append` pushes, and only
  when it can do so in amortised O(1) per element.
- **No O(log n) `slice`, `concat` or `insertAt`** (funkia's RRB tree, research 46 §9): 2.9× the
  bytes and 1.2–2.5× slower reads everywhere.
- **No conversion functions in beni.** There is no JavaScript-array type in the language to convert
  to; a list crosses the boundary through a sibling or a port, under the protocol.
- **No static in-place writes** (research 42's R0), above.

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

*Amended 2026-10-01:* the two list-literal rows go with the cons cell (*Lists are arrays*, above).
An array literal nests at no length, so every list literal is the "flat already" row, and
`max_cons_elements`, the `reduceRight` step and `run/NestingFlatList`'s claim about cell shapes are
withdrawn when `plans/list-arrays.md`'s second slice lands; the fixture keeps its output.

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
(§7, *The emitted shape*). Mobile engines are unmeasured. A lambda applied on the spot, `(λx -> …) a`, costs a
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
*(Amended 2026-10-02: built — `schema.md` §6, *The specialised path, as specified for S4*, and §16,
*As built — S4*: `src/js/SchemaLower.zig` writes it, and §9's walk has a schema member node.)*

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
pub eq : Box a, Box a → Bool
    where a.eq : a, a → Bool

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

### Arithmetic is an operator

*Added 2026-10-02 (research 47 §6 item 4).* Correction 3 above left arithmetic a call "for the
optimiser", and no optimiser ever took it: `k + 1` was `Basics$add(k, 1)` in both builds, in every
program. **A saturated call of one of the core functions below is the JavaScript expression it
computes**, written by `Lower` in both builds, with no call, no import, and no edge for `Reach`
(`src/js/Operator.zig`), so the declaration ships only where it is passed as a value:

| call | JavaScript | why it is exact |
|---|---|---|
| `Basics.add a b`, `sub`, `mul` (`+`, `-`, `*`) | `a + b`, `a - b`, `a * b` | `number` is `Int` or `Float`, and both are a JavaScript number (§4's table), so the operator is the function's own body whichever the call instantiates. No type is read |
| `Basics.fdiv a b` (`/`) | `a / b` | the sibling's body |
| `Basics.pow a b` (`^`) | `a ** b` | the sibling's body. `**` is right-associative, like `^`, and its left operand may not be a unary expression, so the printer brackets it on its own rule (`JsIr.BinaryOp.leftPrecedence`) |
| `Basics.lt`, `gt`, `le`, `ge` called by name | `a < b`, … | the sibling's body. The comparison OPERATORS were already `<` on a number, through `compare`'s `primitive` answer |
| `Basics.not b` | `!b` | a `Bool` is `true`/`false` (correction 1) |
| `Basics.negate n` (prefix `-`) | `0 - n` | `negate`'s own body. Not `-n`: the two differ at zero, where `-0` is another number (`1 / -0` is `-Infinity`) |
| `Int32.fromInt n` | `n \| 0` | the sibling's body, ToInt32 |
| `Int32.toInt x` | `x` | the identity (the table's `Int32` row) |
| `Int32.toUnsignedInt x` | `x >>> 0` | the sibling's body |
| `Int32.add`, `sub` | `(a + b) \| 0`, `(a - b) \| 0` | the sibling's body |
| `Int32.and`, `or`, `xor`, `shiftLeft`, `shiftRight` | `a & b`, `a \| b`, `a ^ b`, `a << n`, `a >> n` | the sibling's body |
| `Int32.shiftRightZero x n` | `(x >>> n) \| 0` | the sibling's body |

**What stays a call, and why.** `idiv` (`//`), `modBy`, `remainderBy` and `Int32`'s `div`, `rem`
and `mod` answer `0` for a zero divisor where `/` and `%` answer `Infinity` or `NaN`, and a guard
around the operator is a conditional no smaller than the call; `Int32.mul` is `Math.imul`, a host
global the renamer does not know (research 47 §2.3's `global_this` is how one would be written).
The rule is **exact equivalence or nothing**: no call is replaced by an operator that answers
differently for any input the type admits. *Amended 2026-10-02 (`language.md` §12.4; specified,
not built):* `modBy` and `remainderBy` become `Int.mod` and `Int.rem`, and stay calls for the same reason.
*Amended 2026-10-01:* they are beni over `Js` in `core/Int.beni`, with no sibling — the bodies
`modBy` and `remainderBy` had — so a call emits what the old one did, under the new module's
import. *(Amended 2026-10-01: `Int32`'s declarations are
beni over `Js` now, `plans/core-in-beni.md`; the table still writes a saturated call, and the beni
body, the same operator, is what a function passed as a value is.)* *(Amended 2026-10-02: so are
`Basics`' — `add a b = a + b`, `and a b = a && b` — and inside `Basics` the body's `+` is `add`
calling itself by name in tail position. A call this table writes in place calls nothing, so it is
never a self-call to §8's tail-call loop nor a site for the inliner (`Lower.callsOperator`); when it
was taken for one, `add`'s body was an empty `for (;;) {}`. `run/BasicsOperatorsAsValues`.)*

**Evaluation order is the call's**: the operands are evaluated once each, left to right, with the
same pinning a call's arguments get (`orderedExprs`), which is `language.md` §6's *binary
operator* row, unchanged. `&&` and `||` are keyed the same way, so `Reach` now drops the edge to
`Basics.and`/`or` too, which correction 3 wrote in place and still shipped.

**Development output changes, deliberately.** Every `emit/` golden holding arithmetic was
re-blessed with this, and every `run/` and `browser/` program prints what it printed before — the
corpus is the differential test. Keyed on the core package, the module and the value's name, never
on a spelling: a root-package module named `Basics` or `Int32` is an ordinary module. Fixtures:
`emit/OperatorsInPlace` (every row, the brackets `**` needs, and the calls that stay),
`run/OperatorsInPlace` (the answers, `-0` and `**`'s associativity among them).

**Measured** on 2026-10-02 with the three subsections below and §6's and §8's amendments of the
same day, research 47 §6 items 2, 3, 4 and 7 together, over the 302 programs `bench/size.mjs`
builds with both compilers: release **253 304 → 245 685 brotli bytes (−3.0 %)**, 851 500 →
827 785 raw; development 1 465 204 → 1 287 767 brotli (−12.1 %), most of it the imports of
`Basics` that no longer exist. The `bench/ui` app under `--release`: 14 208 → 13 968 raw,
**5 117 → 5 032 brotli**; the empty page is unchanged (980), its bytes being the hand-written
runtime's. Speed, one Chrome batch of five and one of ten on update and select: within noise of
the compiler before on every operation, and below Solid 1 on five of six in the first batch
(update, 1.54 ms against 1.48, with overlapping ranges) and on both in the second.

### A discarded value is a statement

*Added 2026-10-02 (research 47 §6 item 2).* `let _ = e` was `const $t = e;`, which the release
optimiser keeps when `e` may be impure and a development build always keeps. **It is `e` as a
statement**, `Lower.discard`:

- a value that only reads — a name, a literal, a field of one — is **nothing**, since evaluating
  it does nothing (a `Js.set` or `Js.throw` leaves `null` or `undefined` behind, and that is all a
  `let _ =` of one used to bind);
- a conditional `c ? a : b` is **`if (c) { a; } else { b; }`**, each arm discarded in turn, an empty
  arm dropped and `if (!c)` written when only the second is left — `let _ = if c then f x else ()`
  is `if (c) { f(x); }`;
- anything else is the **expression statement** `e;` (bracketed when it would begin with `{`,
  *An arrow body or a statement that would begin with `{`*, above).

Whether `e` may have an effect decides nothing about the shape and everything about what
`--release` does with it, exactly as it did for the `const` (`language.md` §6, *What an optimiser
may assume*): an impure `e` is evaluated in both builds, and a pure one is evaluated by a
development build and dropped whole by the release optimiser, which `Lower` tells through
`Result.pure_discards` as it tells it the bindings to keep through `effect_keep`. A `let` whose
pattern binds names is unchanged.

*Amended 2026-10-02 (`language.md` §12.2; specified, not built).* A block's **statement** — the BIR
`let_stmt` — is emitted exactly as `let _ = e` is, by `Lower.discard`, and `findUnobserved` counts
it among the discarded positions. A block is the `let` it lowers to, and a trailing lambda the
`lambda` it is, so neither reaches the backend as anything new: a program migrated from `let … in`
and parenthesised lambdas emits the bytes it emitted before.

**`Js.throw` in tail position ends its block.** Its value is the `undefined` no `return` can reach,
and `return undefined;` after a `throw` is no longer written.

### A result nothing reads

*Added 2026-10-02 (research 47 §6 item 2).* A function whose result is `()` returned `null`, and
every caller that wrote `let _ = f x` threw it away. **When nothing can read what a function
returns, the printer does not write it**: at the function's END — its last statement, through the
two arms of an `if` and the body of a block — `return e;` is `e;`, or nothing when `e` only reads;
anywhere else in it, `return null;` is `return;`. A `switch` case is not followed (falling off one
runs the next) and neither is a loop.

"Nothing can read" is decided per module over `Bir` by `Lower.findUnobserved`, and it is
deliberately narrow. A declaration qualifies when it is a function of this module (§6's `params` or
`lambda` definition) that is **not exported** — not `pub`, not in the interface, not the entry —
**no dispatch answer names** (a private `eq` is still what `==` calls inside its module), has **no
second body** and **does not suspend** (a suspendable body's return value is the fiber runtime's to
read), takes **no evidence**, and whose **every reference** is the callee of a call in a discarded
position — the right-hand side of a `let _ =`, a branch of a `case` or the body of a `let` in
one — **or** in a tail position of a declaration that itself qualifies, whose result goes where
that one's goes. That last clause is a greatest fixpoint: every candidate starts unread, and a
single read anywhere takes it out, and with it whatever its tail positions call. A reference of
any other kind — a value passed, stored, returned from a closure, exported — is a read.

Nothing about the TYPE is asked, because nothing needs to be: a value nobody reads may be anything,
`null` or not. A development build and a release build print the same decision, and a program
cannot tell: the caller that would have seen `undefined` for `null` does not exist.
Fixture: `emit/DiscardedStatements` (with the statements above), and every `run/` program.

*Amended 2026-10-02.* **A discarded `case` is its tree, each leaf discarded** (`Lower.discardCase`).
The list above covered a conditional that lowers to `c ? a : b`; an `if` or `case` whose arms need
statements of their own lowered to a temporary assigned in every arm, `let $t; if (c) { …; $t =
null; } else { $t = null; }`. It is now the decision tree with no temporary, each leaf's body
discarded in turn by the same rules (a `let` its bindings then its body, a nested `case` its tree),
an arm that only reads leaving nothing — `let _ = if c then (let … in Js.write r x) else ()` is
`if (c) { …; r = x; }`, the hand-written runtime's own shape. A tree that needs a `$c$<d>` block
keeps it and its `break`s. A `case` whose branches may suspend is unchanged, since its join needs
the value. `emit/core/JsRef` and `emit/release/core/JsRef` pin it.

### A `()` result is not written

*Added 2026-10-02 (`plans/browser-decisions.md` R47-3; the owner's list for the runtime's port).*
**Under `--release`, a function whose result is `()` writes no result**: the printer treats it as
*A result nothing reads* treats a function nobody reads — at its end `return e;` is `e;` (or
nothing when `e` only reads), anywhere else `return null;` is `return;` — whoever its callers are,
in this module or not. This amends the representation row above (*`()` is `null`*): **a `()` is
`null` or `undefined`**, and nothing may tell them apart — no pattern tests a `()` (its one
constructor always matches, §7), a derived `eq`/`compare` of `()` reads nothing, and `Debug`'s
printer shows both as `()`. A JavaScript caller handed such a function through `Js.from` or a
lowering reads `undefined` where a development build returns `null`; the hand-written runtimes
discard what they call (`$$root(msg)`), and `boundary.md` §4.2 says a platform may not read it.

**Which functions.** `Lower.unitResult`: a top-level declaration whose annotation is a function
type with the result `()`, and `Lower.unitValued`: a lambda, a `let`-bound lambda or a local
function whose every tail (a `let`'s body, a `case`'s branches) is the literal `()`, a call of a
declaration of the module annotated `… -> ()`, or a `Js.write`, `Js.set` or `Js.throw` — asked of
`Bir`, which is what the lowering has; a tail that is a call of another module's function says no,
since the lowering cannot see its annotation. Never a function that may suspend (the fiber
runtime reads its result) nor one with a second body. A development build is unchanged.

**Measured** (2026-10-02): `emit/release/split/EmptyPage` 946 → 933 brotli (the raw bytes fall 74;
the brotli page moves with what it can no longer share, `return G(…)` against `G(…)`). Fixture:
`emit/release/core/UnitResults` (a `pub` function ending in a `Js.set`, a loop's `return;`, a
handler stored on a node, a local function, and an `Int` function that keeps its `return`).

*Amended 2026-10-02 (`language.md` §12.10; built the same day).* Unit is written `⊤` and the
empty type `⊥`. **Nothing in this section moves**: the BIR of `⊤` is the BIR of `()`, so a `⊤`
is `null` (or `undefined` under the rule above), "the literal `()`" above is the literal `⊤`, and
an `if` without `else` lowers to the `case` its `else ⊤` spelling does, its missing branch the
unit instruction, so its JavaScript is byte-identical. The one visible change is `Debug`'s
printer, which writes the unit value as `⊤` from the enforce step (*`Debug.toString` reads the
argument's type*).

### A `Js.Ref` that does not escape is a `let`

*Added 2026-10-02 (research 47 §6 item 5; `plans/browser-decisions.md` R47-2; `boundary.md` §4.2).*
A `Js.Ref` is a cell, `{ v: x }`, read as `r.v` and written as the statement `r.v = x`. **A ref
binding that does not escape is a plain `let` instead**: `let n = x;`, a read is `n`, a write the
statement `n = x;` whose value is `null`. The two are indistinguishable to a program; the second is
one object and one property access fewer, and is what hand-written JavaScript writes.

**A ref binding** is a `let` binding without parameters, or a top-level declaration without
parameters and without evidence (`Convention`'s `constant`), whose pattern is a name and whose
right-hand side is a saturated call `Js.ref e`. **Its cell positions** are the first argument of a
saturated `Js.read` and the first argument of a saturated `Js.write`. **It does not escape** when:

1. **every reference to its name is in a cell position.** Anything else — an argument of any other
   call, `Js.same` and `Js.from` included; an element of a record, tuple, list or constructor; a
   returned value; the base of a record update; a binding of another name; a placeholder's or
   evidence's capture — is an escape, and the binding is a cell. `Js.ref` passed as a value is the
   sibling's `ref`, which makes a cell, so a `Ref` that arrives through a parameter, a field or
   another module is always a cell and a read of one is always `.v`;
2. **for a top-level one, no other module can name it**: it is not `pub`, not the entry, and no
   dispatch answer names it. Condition 1 is then over the whole module, which is every place its
   name can be written.

That is the whole analysis, because beni is lexically scoped: every reference to a local is in the
function that binds it or in a closure made inside that function. **A closure is not an escape.** A
JavaScript closure captures the `let` binding itself and not its value, so a write through it is
seen by every reader, exactly as a write through a shared cell is — `template`'s cloner reads and
assigns its enclosing `let node`. A suspension needs no rule either (§16.3): its continuation is a
closure, and a tail-call loop re-entered after one starts a new iteration, which evaluates its own
`Js.ref` again as a fresh `let` in a fresh block, as a new cell would be. A binding inside a loop body
is a `let` in the loop's block, one per iteration, for the same reason.

**A read of a `let` cell is not an atom.** `Lower.isAtom` answers no for its name, so wherever an
operand is pinned before a later one hoists a statement (`orderedExprs`, `bindSubject`, a markup
value), a read is pinned as work would be: `f (Js.read r) (Js.write r 2)` is `const $t = r; r = 2;
f($t, null)`, and reads `1`, which is what the cell reads. A `let` binding of a read keeps what it
read (`let seen = Js.read r` is `const seen = r`). Under `--release`, `Opt` folds no binding whose
initialiser reads one (`Lower.Result.mutable`): a module-level one may be written by any function,
and a fold rests on its base not changing between the binding and the use.

**Where the check lives**: `Lower.findRefs`, once per module over `Bir`, before any declaration is
lowered, since a `let` function may read a cell bound after it. Development and release builds make
the same decision. Fixtures: `emit/core/JsRef` (the development shape: a captured `let`, a
module-level `let`, and cells that escape by being returned and passed), `emit/release/core/JsRef`
(the same under `--release`, set beside `platforms/browser/runtime.js`'s `template` and render
queue), `run/JsRef` (a platform module's cells, read, written, captured, passed, returned, and a
read before a write in one call, in both builds).

**Measured** on 2026-10-02, research 47's empty page (`--release`, the one file, brotli 11) with
`tests/platforms/beni-runtime-src/Rt.beni` rewritten to use cells where the hand-written runtime
has `let`s — `template`'s node, the render queue's `queued`, `scheduled` and `phase`, `mount`'s
model and waiting flag, `send` and `queue` moved into the closures that hold them: **1 181 → 1 107**
(the hand-written runtime: 980). The port still passes every `browser/dom/` page under happy-dom,
built both ways.

### `Js.finally` is `try … finally`

*Added 2026-10-02 (`plans/runtime-in-beni.md`, step 3's remainder: the effects host's three guards).*
`Js.finally body cleanup : sync (() -> a), sync (() -> ()) -> a` (`boundary.md` §4.2) is the
statement **`try { body } finally { cleanup }`**, JsIr's `try_stmt` — the one construct that lets a
platform's beni restore its state when what it calls throws (a stack overflow, a host error,
`Debug.todo` in a development build), which is what the hand-written host's latches do.

**The shape.** An argument that is a lambda of one parameter binding nothing (`λ() ->`, `λ_ ->`)
and that cannot suspend is written in place: its body is the block, and no function is made. Any
other argument is evaluated before the `try`, in written order, bound to a `const` unless it is a
name or a literal, and called inside its block — so a call that makes the cleanup runs before the
body, as it would for the sibling's function. Where the value goes decides the rest (`Lower.
finallyTry`):

- **discarded** (`let _ =`, a discarded position): `try { body; } finally { cleanup; }`, the body
  discarded by *A discarded value is a statement*'s rules;
- **in tail position**, in a function that does not loop and outside a join: the body lowered in
  tail position inside the block, so `try { …; return v; } finally { … }` — a `return` inside
  `try` runs the cleanup before it leaves. A function that loops writes the value form and
  returns it: a loop's jump from inside the guard would run the cleanup before the next turn;
- **anywhere else**: `let t; try { …; t = v; } finally { … }` and the value is `t`. A body that
  ends in `Js.throw` assigns nothing.

The cleanup's value is always discarded. `Js.finally` passed as a value is the sibling's function
(`core/Js.js`), which does the same with two calls. For *A result nothing reads* and *A `()`
result is not written*, a `Js.finally` whose body is a lambda is unit-valued when that lambda's
body is (`Lower.unitValued`), and a function's end is followed into a `try`'s guarded block —
never into its cleanup, where a `return` would replace how the body ended, a throw's included —
so `try{…;return}finally{…}` at the end of such a function is `try{…}finally{…}`.

**Neither argument may suspend.** Both parameters are `sync` (`checker-v2.md` §27): a body that
parked would leave the `try` at the park, the cleanup would run then, and the rest of the body
would run later outside the guard — a silent change of meaning, so it is refused at the argument
with `sync_boundary`, as for any `sync` parameter. `Suspend` holds the same line as a fault of the
compiler: a suspension marker inside a `try` is `InsideTry`, reported as `internal`, never split.

**What the passes may not do with it.** The `try` is a wall for code motion: `Opt`'s single-use
fold stops at it (`findUse` walks past nothing but a pure-read `const`, and a `try` evaluates
nothing of its own), so no binding moves into the guard — where a throw would now run the cleanup —
or out of it; each block is a statement list of its own, and a `let`'s temporary is declared before
the `try` and assigned in it. `Spec` walks both blocks: facts 1 and 2 are flow-insensitive, fact 3's
null guards die at the `try` (the cleanup may start after any statement of the body), a function
whose body ends in one is taken as one that may fall through, and `inlineOnce` copies a body
holding one and writes a call found in either block into that block (a callee whose `return` stands
in its guard is written only in `return` position, where its `return`s are the caller's). `Rename`
gives each block a scope of its own; `Print` always braces both. Fixtures:
`emit/release/core/JsFinally`, `run/JsFinally` (the cleanup on a return and on a throw, bound,
discarded, in tail position, nested, at the end of a loop, with arguments that are not lambdas, and
as a value — in both builds), `check/bad/core/FinallySuspends`.

### `Js.catchIf` is `try … catch`

*Added 2026-10-01 (`plans/core-in-beni.md`, step 1: the browser wrappers' catches).*
`Js.catchIf body test handler : sync (() -> a), sync (Value -> Bool), sync (Value -> a) -> a`
(`boundary.md` §4.2) is the statement **`try { body } catch (e) { if (!test) throw e; handler }`**
— JsIr's `try_stmt` with a `catch` clause: `Try` gains a third range and the binding's name, `.none`
when there is no `catch`, and a `try` whose cleanup range is empty and that catches prints no
`finally`. What is thrown is caught only when the test holds of it, and thrown on unchanged
otherwise: `CLAUDE.md` rule 9 is the shape, so no `catch` this compiler writes can swallow what it
did not name.

**The shape** is `Js.finally`'s (`Lower.catchTry`). A body that is a lambda of one parameter binding
nothing is the `try` block; a test or handler that is a lambda of one parameter that cannot suspend
is written in the `catch` block, its parameter the `catch` binding — the test's name when it binds
one, else the handler's, else a fresh one; when both bind a name, the handler's is the test's, and
a parameter that is a pattern binds from it. Any other argument is evaluated before the `try`, in
written order, and called in its block. The value goes where the call's does — discarded, both
blocks discarded; in tail position, both blocks `return`; anywhere else, a `let` both assign — and
an arm that ends in `Js.throw` assigns nothing:

```js
// Url.percentDecode, release
a=>{try{return{$:"Just",a:decodeURIComponent(a)}}catch(b){if(!(b instanceof URIError))throw b;return c}}
```

**The passes**: as for `Js.finally`, the `try` is a wall for code motion and every pass walks the
third block — `Opt` plans it as a list of its own; `Spec` counts and scans its binding as a
declaration (an inlined copy gets a fresh one), walks the block for facts 1–2, kills fact 3's
guards before it and after it (it may begin after any statement of the body) and writes a call
found in it there; `Rename` gives the binding and the block one scope (a `let` of the binding's
spelling in it is an early error); `Print` follows a function's end into the `catch` block as into
the guarded one; `Suspend` refuses a marker in it, and takes a `try` for one that leaves only when
both its body and its `catch` block do (or its cleanup does). `Js.instanceOf` is the
`instance_of` operator, at the relational operators' precedence. Release builds write `URIError`,
`SyntaxError` and `DOMException` bare (`Rename.bare_globals`). Passed as a value, `Js.catchIf` is
the sibling's function, which does the same with three calls. Fixtures: `emit/release/core/JsCatchIf`,
`run/JsCatchIf` (tail, bound, discarded, a throw the test does not hold of passing through an inner
`catchIf` to an outer one that names it, a `DOMException` caught by `name`, two names for the
caught value, arguments that are not lambdas — made first, in order — passed as a value, at the end
of a loop; both builds), `check/bad/core/CatchIfSuspends`. Red first: with the compiler before,
`Js does not expose catchIf`.

### `Js.pure` is its body

*Added 2026-10-01 (`plans/core-in-beni.md`, step 1).* `Js.pure λ() -> body` (`boundary.md`
§4.2) is written as `body` — wherever the call stands, a value, a tail or a discarded position, the
body stands there instead and is lowered as it would be (`Lower.pureBody`); with any other
argument it is a call of it. What it changes is the checker's answer, not a byte: `Js.pure` is
`foreign pure` and its argument a function handed to it, so a declaration whose body is one is
`pure` however many `Js.get`s it makes. `core/String.beni`'s functions are written so; without it
`String.length` would publish `!impure`, and every function that measured a string with it.

### `Js.suspending` is its body

*Added 2026-10-02 (`plans/core-in-beni.md` step 2, K1; research 49 §3.1).* `Js.suspending λ() ->
body` (`boundary.md` §4.2) is lowered as `Js.pure`'s is — wherever the call stands, the body stands
there instead — and is a **suspension point** wherever it is not in tail position: in a value or a
discarded position the body's value is bound to a temporary behind a marker and the rest of the
function becomes its continuation, as for any call whose callee may suspend
(`transparent-effects-proposal.md` §16.3); in tail position it is returned as it is, the caller's
own comparison deciding. With any other argument it is a call of it, which `Js.js` answers with
the argument's value. Fixture: `emit/core/JsSuspending` and its release twin (a park in tail, value
and discarded position).

**`Reach` keeps `Task.andThen` and `Task.isWaiting` whatever kind of declaration they are.** A body
that may suspend adds an edge to the two (§9, `Reach.effectEdges`), whether `Task` declares them
`foreign` or writes them in beni: a program whose own code suspends but that reaches no kernel
function calling `andThen` still needs it.

### `Js.regExp` is a literal

*Added 2026-10-01.* `Js.regExp pattern flags`, both string literals (`boundary.md` §4.2), is a
regular expression literal, JsIr's `regex` node: its whole text, escaped, printed verbatim
(`Lower.regExpLiteral`). The pattern is copied as written but for what a literal cannot hold —
an unescaped `/` is `\/`, a line terminator its escape, an empty pattern `(?:)`, and a backslash
before a line terminator is the terminator's escape — none of which changes what it matches; a
pattern ending in a lone backslash, a non-literal argument or flags beyond `d i m s u v` (each once)
is refused (`internal`). The node is not a constant: each evaluation is a new object, so no pass
folds, compares or copies it as one (`Spec` takes it for an unknown value; `firstUse` for one that
reads nothing). Passed as a value, `Js.regExp` is the sibling's `new RegExp(pattern, flags)`.
Fixture: `run/JsOperators` (a literal made once, one made in place, a `/` and a line feed in the
pattern, a flag, an empty pattern, one built by the sibling), with the operators of `boundary.md`
§4.2's list — each the `JsIr` operator of its name, `typeOf` the `type_of` unary. *(Amended
2026-10-02:* `Js.typeIs v "name"` is `typeof v === "name"`, the `type_of` unary compared with the
literal; a name that is not a string literal is refused
(`internal`). Passed as a value it is the sibling's `typeof v === t`.)

### `Js.development` is the build's mode

*Added 2026-10-01* (`boundary.md` §9.8.10 (c): a crash screen in development builds only).
`Js.development : Bool` (pure) is **`true` in a development build and `false` under `--release`**,
written in place as the literal — the one fact about the build a platform's beni may read, so that
what only a developer needs ships in no release build. A use not in an `if` is the literal; `Js.js`
exports `true` only for check 2. *(Amended 2026-10-02: `Js.development : () -> bool`, called as
`Js.development ()` — `Js` names no core type (`boundary.md` §4.2) and check 1 refuses a
polymorphic `foreign` value — and a `case` on that call drops an arm as one on the value did;
`Js.js` exports a function of one parameter.)*

**An `if` on it keeps one branch, in both passes.** A `case` whose scrutinee is `Js.development`
and one of whose arms has the pattern `True` or `False` — every `if Js.development then … else …`,
and a `case` spelled with those patterns in either order — has a **dropped arm**: `True`'s under
`--release`, `False`'s otherwise (`JsIntrinsic.droppedArm`, the one predicate both passes ask):

- **`Reach`** guards the dropped arm's positions with a constructor no build reaches (`Guards`,
  *A `case` arm on a constructor nothing builds*), so no edge out of it is followed: a declaration
  only that arm names is not in the build;
- **`Lower`** writes the `case` as the taken arm's body alone, with no test (`developmentArm`,
  when the taken arm's pattern binds nothing), and otherwise writes the dropped arm as
  `undefined`, as any arm no value takes — never naming what `Reach` left out.

So a development build writes `() => devOnly()` and a release one `() => "…"`, with `devOnly`
absent. It is an `if`'s condition and nothing more: `if Js.development && x` is an ordinary test,
both of whose branches are kept. Fixtures: `run/JsDevelopment` (a platform module asking in an
`if`, a `case` and a constant, its release build printing its own golden), `emit/core/
JsDevelopment` and `emit/release/core/JsDevelopment` (the two shapes, each without the other
build's declaration).

### `Js.maySuspend` is the body's answer

*Added 2026-10-02* (`boundary.md` §9.8.11 (b): a command whose body cannot suspend runs without a
fiber). `Js.maySuspend : f -> Bool` (pure) is **whether its argument may suspend: the checker's
answer for the argument's class at the call, written in place as `true` or `false` in the body
being written** — the one fact about the effect bits a platform's beni may read, so that a
declaration can do one thing for a function that waits and another for one that does not, and a
program that never passes one of the two ships nothing of the other.

- **The checker** records each call of it with its argument's type (`Effects.probe`), and the
  plan (`EffectPlan`, `transparent-effects-proposal.md` §16.2) reads the argument's class as one
  the lowering reads — beside a call's callee and a function's own arrow. So a scheme class that
  reaches it is *sensitive* and its declaration has two bodies, exactly as one that calls its
  argument does. The answer is `no`, `yes` or `poly`, carried on the call instruction in the
  dispatch table's `body` column (which no reference reads on a `call`); no column, sidecar or
  interface format moves.
- **`Lower`** writes the call as `true` where its answer is `yes`, or `poly` in the suspendable
  body, and `false` otherwise, the argument evaluated for what it does (a reference: nothing).
  **A `case` whose scrutinee is the call and whose arms are `True` and `False`** — every `if
  Js.maySuspend f then … else …` — is written as the taken arm's body alone, as an `if
  Js.development` is (`developmentArm`), and the dropped arm, where something else writes it, as
  `undefined`.
- **`Reach`** guards the arm a body drops (`Guards`): with the answer `no`, `True`'s, and with
  `yes`, `False`'s, behind a constructor no build reaches; with `poly`, `True`'s waits on the
  declaration's suspendable body and `False`'s on its direct one — an edge waiting on the body it
  is in is followed with it, and one waiting on the other body adds only what that body reaches
  itself — and a choice of body inside the `False` arm that is `poly` is never the suspendable
  one. A guard may now be a declaration's body as well as a constructor, and any node reached
  releases the edges that waited on it.
- **A use that always takes its target's suspendable body keeps no direct one** (*added with
  it*, a general change): a reference whose answer is `yes` writes only `<name>$s`, so the plain
  edge to the direct body is not followed. Until now both were kept, the direct one unused.
  Nothing in the `emit/` corpus moved.

Passed as a value, `Js.maySuspend` is the sibling's, which answers `true`: it cannot know what
it is asked about, and a function that may suspend is the safe answer. Fixtures: `run/
JsMaySuspend` (a platform module whose declaration asks, used both ways, through a forwarding
declaration, about a function it names itself, and in a discarded position) and `emit/core/
JsMaySuspend` (only the direct body written, and nothing only the other one names).

### `Js.fingerprint` is its type's identity

*Added 2026-10-02* (`boundary.md` §9.8.3, amended; `static-dispatch-spike.md` §8.6). A saturated
call of `Js.fingerprint x o` is written as **the identity term its site carries** — the last root
of its evidence — evaluated as `identity` terms are everywhere: a string literal when every part is
text, else the parts joined by `+`, a part that is a parameter read by its name (`"core:Maybe.Maybe("
+ $m$1 + ")"`). The arguments are discarded as `Js.maySuspend`'s is, written as statements before
it only when they may do something (a name or a constructor is dropped). No import of `core/Js.js`
follows from it, as from every intrinsic written in place. Passed as a value it is the sibling's
`fingerprint = (compare, type, value, order) => type`, which takes the identity as its hidden
argument like any declaration that has one.

An identity parameter is an ordinary parameter after the evidence (`$m$<n>`); nothing else in this
document changes for it. A declaration whose every call passes one literal has the parameter folded
away under `--release` by whole-program specialisation (§9).

### `Debug.toString` reads the argument's type

*Added 2026-10-02* (specified with `language.md` Appendix B and `checker-v2.md` §32, before the
code). `Debug.toString` used to read a value by its representation alone, and the representation
above does not say enough: a tuple and a record whose fields are `a` and `b` are both `{a, b}`, a
`Char` is a one-scalar string, an all-nullary type's constructor is a bare string, and a `()`
argument is the `null` a padded constructor's missing fields also are. So `( 1, 'c' )` printed
`{ a = 1, b = "c" }`, `LT` printed `"LT"` and `Just ()` printed `Just`. Changing the
representation to say more — a tag on every tuple, a box on every `Char` — would cost every
program at run time for a development aid; the type at the call already says all of it, and the
checker has it.

**What crosses.** The checker gives every `Debug.toString` and `Debug.log` reference whose
printed value's type is more than a bare variable a `debug` row: that type, pre-order, with
named types as `TypeId`s and their arguments (`checker-v2.md` §32). The backend does not read
types (§3); it reads the row, as it reads a `?`'s shape, and the named types' constructors from
their declarations in `Bir`, as `Fields.close` reads a boundary type's.

**What the call becomes.** A saturated call of a reference with a row calls a sibling of the
`pub` value it names, with one leading argument, the type's **descriptor** as a string literal:

```js
Debug$toStringAs("[[\"t\",\"i\",\"c\"],[]]", x)       // Debug.toString ( n, c )
Debug$logAs("[\"s\",[]]", "say", s)                     // Debug.log "say" s
```

`Debug.toString` in value position with a row is the same call over a fresh parameter, `(p) =>
Debug$toStringAs("…", p)`. A reference with no row — under a type variable, or `Debug.toString`
inside `core/Debug` itself — is the plain call, whose own body is `toStringAs` with the
descriptor `["?",[]]`, so reachability keeps the typed sibling whenever the plain one survives
and nothing in §9's walk changes. `toStringAs : Js.Value, a → String` and `logAs : Js.Value,
String, a → a` are `pub` because the emitter imports them by interface, and harmless because no
program outside core and a platform can make a `Js.Value`.

**The descriptor** is one JSON text, `[root, defs]`, written by `src/js/DebugShape.zig`. A type
is `"i"` (an `Int`, or an `Int32`, which is a number too), `"f"` a `Float`, `"s"` a `String`,
`"c"` a `Char`, `"b"` a `Bool`, `"u"` `()`, `"F"` a function, `"x"` a `foreign type`, `"?"`
unknown; `["t", a, …]` a tuple, `["l", a]` a `List`, `["D", k, v]` a `Dict`, `["S", a]` a
`Set`; `{"x": a, …}` a record; `["n", k, a, …]` a `type` applied to its arguments, where `defs[k]`
is its constructors, `{"Tag": [arg, …], …}`, and inside a definition a number is the type's own
parameter. A named type is defined once per descriptor, in first-use order, however often it
recurs, so a recursive type is a finite text; an alias is written as its expansion. Everything is
keyed by declaration and first use, so `--jobs` cannot move a byte.

**What it costs.** Nothing in a program that does not reach `Debug`, and nothing under
`--release`, which refuses a build that does (§9, *`Debug` is refused, not pinned*); the harness's
`--allow-debug` builds the same calls. A development build pays one string per typed call, the
descriptor parsed once per call, and the printer in `core/Debug.beni`.

Fixtures: `run/DebugToStringShapes` (every shape the representation could not tell, at the top
and inside a payload), `run/DebugLogShapes` (`Debug.log`, `Debug.toString` as a value, and the
representation fallback under a type variable), `run/DebugToStringModules` (another module's
recursive, aliased and opaque types, and a `foreign type`), `dispatch/DebugShapes` (the rows), and
`emit/BlockStatement` and `emit/DiscardedStatements`, whose `Debug.log` calls became
`Debug$logAs`.

### `Js.object` is an object literal

*Added 2026-10-02, the owner's decision on research 50 §7* (`boundary.md` §4.2). `Js.object [ (
"k1", v1 ), … ]` is JsIr's `object` node: one `property` per pair, its key the string's bytes as
a property name, in written order (`Lower.objectLiteral`). The values are lowered as a call's
arguments are (`orderedExprs`), so they run in written order and one that must be made first is;
the list, the pairs and the keys exist only as syntax — no array, no tuple and no string is made.
**A key is never renamed**: §9's short names rename bindings, never a property name, and *Item 4,
taken up*'s field renaming renames a beni record's fields by the record's type, which an object
from `Js.object` does not have; so `{length:a,h:b,…,$plain:f}` is what every build writes, and the
one call site of one header form is one hidden class, as the hand-written literal was. The checker
refuses a malformed field list first (`invalid_js_object`); `Lower` still answers `internal` to
one, which no checked module reaches. Passed as a value, it is the sibling's
`Object.fromEntries`-shaped function over the pairs. Fixtures: `emit/core/JsObject` and
`emit/release/core/JsObject` (keys in written order, never renamed, a value that must be made
first, a key that is a record's field name elsewhere in the program), `run/JsObject` (the values'
order, `$plain` read back by name), `check/bad/core/JsObjectKey` (a key that is not a string
literal, one that is no identifier, `__proto__`, a key twice, an argument that is not a list
literal) and `check_test`'s *Js.object's list, pairs and keys mint no edge* (a module `String`
imports writes one, and `dump --stage=graph` shows no edge for its literals).

### `Js.method` is a `function`

*Added 2026-10-02, the owner's decision on research 50 §7* (`boundary.md` §4.2). `Js.method
λself → body` lowers the lambda as an arrow and then makes it a `function` of no parameters whose
first statement is `const self = this` (`Lower.methodFunc`): JsIr's `arrow` with the flavour
`arrow_method`, its body read by every pass as an arrow's, and the leaf `this_lit`, handled
wherever `global_this` is. Both printers write it `function(){…}` with a block body — an arrow's
`this` is not the receiver's — and `--release`'s single-use inlining may write a `self` read once
in the method's own statements as `this`, never one read in a nested arrow, whose statements it does
not enter; an arrow nested in the method reads the receiver through the name. `this_lit` is not an
atom (`Lower.isAtom`), so no argument substitution can carry it into another function.

**An object holding a method is one object** (the specialiser, §9). A method reads and writes its
receiver through `this`, which the points-to pass cannot follow to a site, so:

- an object literal one of whose keys may hold an `arrow_method` function, and an object one is
  written into, **escape**, as does the method's site — no key of it is unread, no call of the
  method is resolved or inlined (`Pts.holdsMethod`);
- **scalar replacement** never splits an object whose key holds one, written in place or the value
  of the top-level `const` it names (`methodValue`), and never one with a key read as a call's
  callee, `x.k(…)`, unless that key's value is an arrow written in place, which cannot read `this`:
  splitting it would call the function with no receiver.

Without them, `run/JsMethod`'s release build dropped the counter's `n` and called the methods
with `this` undefined. Fixtures: `emit/core/JsMethod` and `emit/release/core/JsMethod` (a view's
`$plain` shape, a method that only reads — `this` in place under `--release` — and one whose
receiver an arrow reads), `run/JsMethod` (a method writing its receiver, one read through a nested
arrow, a method making an object with a method of its own, one caching on its receiver; both
builds), `check/bad/core/MethodSuspends` (`sync_boundary`).

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

### A parameter of type `()`

*Added 2026-10-02 (research 47 §6 item 7).* `f () = …` compiled to `($p) => …`: a parameter that
binds nothing, whose argument is always `null`. **A trailing run of parameters whose pattern is
`()` is not written in the JavaScript parameter list** — `f () = …` is `() => …`, `λ() -> …` is
`() => …`, `g x () = …` is `(x) => …` — for a declaration, a `let` function and a lambda alike,
and for a function that loops (§8), whose jump still evaluates such an argument and stores it
nowhere. A `()` before a written parameter stays, because positions do not move.

**A call does not have to know.** Every call still passes what the source wrote, and `null` for a
`()`, and JavaScript ignores an argument its callee does not take — so a caller in another module,
a call through a parameter, the fiber runtime's `f(null)` and a hand-written runtime's `f()` all
reach the same function. Where the callee is a declaration of the same module defined with its
parameters, a trailing `()` literal in the position of an unwritten parameter is not passed:
`f ()` is `f()`. Nothing else changes: an evidence parameter is leading and is never dropped,
and `.length` is read by nothing a program can reach (the derived engine's depth parameter is a
derived function's, never a user function's).

**This is what the boundary needs** (research 47 §6 item 7): a beni function a hand-written runtime
calls with no arguments has no parameters. The other direction is `boundary.md` §4's check 4,
amended the same day: a sibling may leave out a `foreign`'s trailing `()` parameters, and a call
passes `null` for them all the same. Fixture: `emit/UnitParameters`, and `run/ForeignUnitParameters`
for the sibling.

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
| `[]`, `x :: xs` | the two constructors of the list union on the emitter's `{$:0}`/`{$:1}` shape (§4) | `subj.$ === 0` / `=== 1`. *Amended 2026-10-01:* `r.length === k` / `r.length > k` on an array (*List patterns over arrays*, below) |
| `[ a, b, c ]` | **normalised to `a :: b :: c :: []`** before the matrix is built | the cons tests |
| `[ a, b, ...rest ]`, `[ a, ..._ ]` | *Added 2026-10-01:* **normalised to `a :: b :: rest`** and `a :: _`, exactly what `::` was, so a column of these compiles as it always did | the cons tests |
| `[ ...init, z ]`, `[ a, ...m, z ]` | *Added 2026-10-01:* a column holding any pattern with elements **after** its spread is split by length, as `checker.md` §6.6 splits it (*List patterns with elements after the spread*, below) | the cons tests down the spine, and the last cells through `List.length`/`List.drop` |
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
never evaluated: `case Debug.log "m" m of Inc ->` logged nothing in either build. A fan wider than
`max_switch_cases` prints one `switch` per chunk, each reading its discriminant, yet counted once,
so an unbound call ran once per `switch` its value was not found in. Each fan now counts its
printed discriminants: none for one label, one for two, and one per `switch` above. A root read
zero times is written as an expression statement where it is evaluated, not as a `const`: no
binding is written, so §9 item 1 — which drops a dead binding whole, `Debug.log` and all — has
nothing to drop, and the two builds evaluate the same expressions. A name or a field read of one
has nothing to evaluate and is left out. The rule is about the `case`; a `let` pattern that binds
nothing is a binding, and §9 item 1 still drops it in `--release` (`language.md` §6) — when its
right-hand side is pure, since 2026-09-30; one that may be impure is kept (§9 item 1's amendment).
`run/CaseSingleConstructorScrutinee` and `abuse_wide_test.zig`'s development build are the tests.

### List patterns over arrays

*Added 2026-10-01; specified, not built* (§4, *Lists are arrays*; `plans/list-arrays.md`). *Built
2026-10-01 with the plan's second slice, R5 aside (its third): `js/Decision.zig` gained only names
for a `::`'s two columns, `.head` and `.tail`, so the emitter reads a chain of tails as one `(r,
k)`; `emit/ListPatterns` pins the shapes.* **The matrix does not change.** `js/Decision.zig` still reads `[]` and `::` as the two constructors of the
list union and still normalises `[ a, b, c ]` to `a :: b :: c :: []`, and the checker's
exhaustiveness is untouched; a list is still a two-alternative node, so still an `if`. What changes is
the third column of the table above — what `js/Lower.zig` writes for a list occurrence, a list test
and a list binding — because there are no cells to walk.

**An occurrence of a list is a root and a depth.** Specialising `::` on a list occurrence makes two
columns, its head and its tail. The emitter never builds the tail: a list occurrence is written as
**`(r, k)`** — the list `r` without its first `k` elements — where `r` is the scrutinee, or any
occurrence that is itself a list reached some other way (a head whose elements are lists, a tuple
component, a constructor argument), and `k` counts the `::` specialisations between `r` and here.
The head of `(r, k)` is element `k` of `r`.

| Pattern at `(r, k)` | Test | Binding |
|---|---|---|
| `[]` | `r.length === k` | — |
| `h :: t` | `r.length > k` | `h` is `List$unsafeGet(r, k)`; `t` is the occurrence `(r, k + 1)` |
| a variable or `as` naming `(r, k)` | — | `r` when `k = 0`, else `List$view(r, k)` |

The two tests are complementary on every path that reaches `(r, k)`: that path has already found
`(r, k − 1)` to be a `::`, so `r.length ≥ k` there. `r` is bound by `bindSubject` exactly as any
scrutinee is, and each `.length` read counts as a read of it. `[ x, y ]` is therefore
`r.length === 2` with `x` and `y` at indexes 0 and 1, `a :: b :: rest` is `r.length > 1` (after the
`> 0` its first column asked, when the tree asks it) with `rest` the view at 2, and `(x :: xs) :: rest`
makes the head `List$unsafeGet(r, 0)` a root of its own. `classify` of the measurement table above
keeps its four questions on its worst path; each is now a length comparison instead of a tag read
down a chain of cells.

**A tail is bound only on a leaf that reads it**, in both builds. A binding of `(r, k)` for `k ≥ 1`
allocates a view — O(1), but an object — so a leaf whose body never reads a tail variable does not
write its binding. `( x :: xt, y :: yt )` in a `merge` that uses one of the two tails per branch
therefore makes one view per step, not two. (Research 38 §17.2 found the other behaviour turning a
`merge` that holds a trie side unmatched into O(n²) before the trie cached its plain copy; with the
cache it is O(1) either way, and this rule removes the allocation at its source.) Any other pattern
variable is bound at the leaf as before: reading an element allocates nothing. *Amended 2026-10-01
(E1tp):* `List$view` of a trie is a trie header, not a view over its cached copy (§4, *The
claimable head: E1tp*): still O(1), still an allocation — a larger one, and a reversed copy of at
most 31 elements once every 32 steps — so the rule stands and matters more.

**Re-consing what a pattern matched is the list it matched.** In a leaf, an expression `h :: t` in
which `h` is the variable a pattern bound to the head of `(r, k)` and `t` the variable the same
pattern bound to `(r, k + 1)` denotes `(r, k)` itself — values are immutable, so the list whose head
is `h` and whose tail is `t` *is* that suffix of `r`. It is written as `(r, k)`'s binding above
(`r` itself at `k = 0`, so `===` the scrutinee; a view otherwise), not as `List$cons`, and it costs
O(1) where the copy costs O(n). This is research 38 §16.3's **R5**. It is what keeps the Elm-shaped
`pairwise` — `(a, b) :: pairwise (b :: rest)` after matching `a :: b :: rest` — linear, and the
`merge` that re-conses the head it did not take. It is syntactic: both operands are the pattern's
own variables, unapplied and unwrapped. `x :: rest` where `x` came from a different pattern is an
ordinary copy.

*Amended 2026-10-01 (E1tp).* **The runtime now re-conses too**, so this rule is no longer what keeps
those programs linear. `List$cons(h, t)` onto a view whose backing array holds `h` just before it
returns the wider view (or the array), and onto a trie whose head slot past its count holds `h` —
which is what the tail of a trie that began with `h` is — a header sharing every array; everything
else it does is amortised O(1) anyway (§4, *The claimable head: E1tp*). `pairwise` and `merge`
written Elm's way are linear after the flip with or without R5. **R5 stays**, in the third slice as
planned, for what only the compiler can give: the result is `===` the list matched in every form
(the runtime gives an equal view, or on a trie a new header, §4 *Identity*), and nothing is
allocated or called. It is therefore an identity and constant-factor rule, and its fixture is an
identity test (below).

```js
// describe xs =
//     case xs of
//         [] -> "empty"
//         [ x ] -> "one ${x}"
//         x :: y :: rest -> "${x}, ${y} and ${List.length rest} more"
const Main$describe = (xs$1) => {
  if (xs$1.length === 0) {
    return "empty";
  } else {
    if (xs$1.length === 1) {
      const x$2 = List$unsafeGet(xs$1, 0);
      return `one ${x$2}`;
    } else {
      const x$3 = List$unsafeGet(xs$1, 0);
      const y$4 = List$unsafeGet(xs$1, 1);
      const rest$5 = List$view(xs$1, 2);
      return `${x$3}, ${y$4} and ${List$length(rest$5)} more`;
    }
  }
};
```

(Illustrative: which test a node writes first is the tree's choice, §7's *Choosing a column*, and
the printer's; the reads are the contract.)

Fixtures, owed by `plans/list-arrays.md`'s second slice: `emit/ListPatterns` (every row of the table,
`[ x, y ]` against `x :: y :: rest`, a nested list head, an `as` on a sub-list, a leaf that reads no
tail) and every existing `run/Match*` fixture unchanged in output; R5 in the third slice with
`run/ListRecons` (`pairwise` and a re-consing `merge` at 100 000 elements, which exceed the test
budget as O(n²) copies and so are red before it) and `emit/ListRecons`. *Amended 2026-10-01
(E1tp):* `run/ListRecons` is green from the second slice on, because the runtime re-conses and
prepends cheaply; it moves there as a guard (it must exceed the budget against a scratch core
whose `cons` always copies). The third slice's red-first fixture is `run/ListReconsIdentity`:
through the test platform's `refEq` (which is `===`), `[ h, ...t ]` after matching `[ h, ...t ]`
against a view and against a trie prints `copied` before R5 — an equal new view, a new header —
and `same` after, and against a plain list `same` throughout (the runtime hands back the array).

### List patterns with elements after the spread

*Added 2026-10-01, the owner's list syntax* (`language.md` §6.8, *The list syntax*); built on
today's cons cells the same day. A pattern with nothing after its spread is the `::` it replaced —
`[ a, b, ...rest ]` is `a :: b :: rest`, `[ a, ..._ ]` is `a :: _` — and compiles exactly as it did,
so nothing in this section applies to a column that holds only those, `[]` and exact lists, and no
golden of such a `case` moves. A pattern with elements **after** its spread (`[ ...init, last ]`,
`[ a, ...m, z ]`) says something about the end of the list, which a chain of cells cannot reach
without walking, so a column that holds one — at any depth, in any row — is compiled **by length**,
with `checker.md` §6.6's split:

- The column's *L*, *P* and *S* are the checker's, from the rows that reach this node, and its
  alternatives are `exact ℓ` for ℓ < *L* and `at least L`. A row covers the alternatives the
  checker's does, with the same sub-patterns; a wildcard row joins every one.
- **The tree tests the spine**, one two-way list node per cell: at the column's occurrence `o`, `o.$
  === 0` is `exact 0`; under its `::` edge, `o.b.$ === 0` is `exact 1`; and so on down to depth *L*,
  whose `::` edge is `at least L`. Each node is the `if` a list node always was, so a length split
  is a chain of the tests a cons column writes, ending as soon as the rows under an edge are decided.
- **Leading elements** are the spine's heads, `o.a`, `o.b.a`, …, as for `::`. **Trailing
  elements** hang off a new occurrence, *the last S cells of `o`*, emitted as
  `List$drop(o, List$length(o) - S)` — shared cells, no copy — whose heads are the trailing
  elements in order. An occurrence is rebuilt at each read (§7), so every test of a trailing element
  walks the list again: O(n) per read, correct, and the price of asking a cons list about its end.

**Bindings at the leaf** follow the pattern, as every binding does. After the *p* leading items the
walk has reached `t`, the rest of the list. With *s* ≥ 1 items after the spread, trailing item *j*
is bound under `List$drop(t, List$length(t) - s)` walked *j* cells on, and the spread's name is
`List$take(t, List$length(t) - s)`, a copy of the n − p − s cells in between; with *s* = 0 the
spread binds `t` itself, shared, as `x :: rest` did; `..._` binds nothing. The scrutinee is bound to
a name whenever one of the `case`'s patterns has elements after a spread, because these reads name
it more than once.

**The three functions** are `core/List`'s `length`, `drop` and `take`, which the emitter names by
well-known symbol through `coreValue`, as it names `Task.andThen` (§8, *What it owes the fiber
lowering*). §9's reachability gives a declaration whose body holds such a pattern an edge to each,
so a program that never writes one ships none of them on its account.

**After the flip** (§7, *List patterns over arrays*), the same split reads the length directly: an
occurrence `(r, k)` tests `r.length === k + ℓ` for `exact ℓ` and `r.length >= k + L` for `at least
L` — one comparison per alternative instead of a walk — trailing item *j* is
`List$unsafeGet(r, r.length - s + j)`, and the spread binds a view of `r` from `k + p` to
`r.length - s`: O(1) for every form. §4's `view` has only a start today; a view with an end, or a
`slice` until it has one, is `plans/list-arrays.md` slice 2's to choose. *Chosen and built
2026-10-01: `List$slice(r, k + p, r.length - s)`, a copy of the elements the spread covers, O(n −
p − s); a view stays a suffix (invariant 3), and a spread whose name nothing reads binds nothing.
The chain of two-way tests stays — `r.length === k + ℓ` for each `exact ℓ`, the tree asking them
in turn — one comparison each, and no walk.*

Fixtures: `run/ListSpreadPatterns` (every row of `language.md` §6.8's pattern table at its edges —
the empty list, one element, exactly *p* + *s*, one more — nested lists, literal and constructor
items after a spread, a spread bound and ignored) and `emit/ListSpreadPatterns` (the spine chain,
the last-cells occurrence, the bindings, and a `[ x, ...rest ]` column beside it that did not move).

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

*Amended 2026-10-02:* **the right operand of `a || b` or `a && b` in tail position is a tail
position**, since the pair is the `if` a short-circuit is — `if a then True else b`, `if a then b
else False` — keyed, as `Lower.logicalOp` is, on core's `Basics.or` and `and`. When a tail
self-call is reachable through one, the pair is written as the statements `if (a) return true;` (or
`if (!a) return false;`, each through the loop's exit) and then `b` in tail position, a jump where
it reaches the self-call; anywhere else it stays the expression `a || b`. Before, `anyKey k fs i =
… == k || anyKey k fs (i + 1)` was a frame per element and a `RangeError` past some thousands —
the shape `core/Schema.beni` writes its searches in. `run/TailCallLogical` runs three of them a
million deep.

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
| `f = λx -> … f x'` | **yes** | `f x = e` and `f = λx -> e` emit byte-identical JavaScript today, and two spellings of one program must not differ in stack behaviour. The rule is narrow: a `lambda` that is the **entire** body of a parameterless declaration or `let_def` inherits that name; a lambda anywhere else never does |
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
    if n ≤ 0 then acc else build (n - 1) ((λx → x + n) :: acc)
```

Each iteration conses a closure over `n`. Reassign `n` in place and every closure reads the last
value: `build 3 []`, then applying each to `0`, prints `0 0 0` instead of `1 2 3` — measured on Node
24 from both shapes written by hand. The per-iteration `const` fixes it because a `while` body block
gets a fresh declarative environment on every evaluation, so iteration *i*'s closures capture
iteration *i*'s binding. The copies are therefore **unconditional** (*amended 2026-10-02*: unless
the body makes no function at all, *In place, when nothing captures*, below): the answer has to be right for
lambdas, `f a _` placeholders, `<-` continuations and §6's eta-expanded evidence alike, and a
capture analysis that is wrong once is wrong silently.

`<-` is both at once. `let x <- f a in rest` is
`f a (λx -> rest)` (`language.md` §6.7), so when `f` is the enclosing function the **call** is a
tail self-call and loops, while the continuation is a different function and its body is **not** a
tail position of the outer one. The continuation closes over this iteration's parameters, including
over the callback parameter it is replacing — in-place reassignment there does not merely read a
stale value, it builds a closure that calls itself.

### In place, when nothing captures

*Added 2026-10-02 (research 47 §6 item 3), amending "the copies are therefore unconditional"
above.* The copies exist for a closure over this iteration's parameters, and **a body that makes
no function cannot hold one**. The answer the section above refused to trust — a capture analysis
— is not needed, because the question is asked of the JavaScript and not of beni: after the body is
lowered, `Lower.functionOrLoop` walks what it built (`JsIr.Builder.holds`), and **only when it holds
no `arrow` and no `function` declaration at all** — no lambda, no `let` function, no placeholder,
no `<-` continuation, no eta-expanded evidence, no constructor used as a value, captured or not —
and no suspension point (whose re-entry passes the slots), the loop is written in place:

```js
const Main$count = (n$1, acc$2) => {         // count n acc = if n <= 0 then acc
  for (;;) {                                  //              else count (n - 1) (acc + n)
    if (n$1 <= 0) {
      return acc$2;
    } else {
      acc$2 = acc$2 + n$1;
      n$1 = n$1 - 1;
    }
  }
};
```

- **The parameters are the loop's variables.** No `$in$<i>`, no prologue `const`; a jump assigns
  the parameter itself. A parameter whose pattern is not a bare variable keeps its compiler-made
  name and destructures inside the loop as before; one written `_` keeps its `$in$<i>`, which
  nothing reads.
- **The order of the assignments is chosen, and "no temporaries" becomes "few".** The old scheme
  needed none because its arguments read the copies. In place, an argument that reads a
  parameter an earlier assignment rebinds would read the new value, so `tailJump` orders them:
  when **no argument makes a call**, evaluating one before another cannot be observed (`language.md`
  §6, *What an optimiser may assume*, as amended the same day), so each parameter is assigned once
  no argument still to come reads it — `count (n - 1) (acc + n)` is `acc = acc + n; n = n - 1;` —
  and only a cycle, `f b a`, takes a temporary. When some argument makes a call, the arguments are
  evaluated in parameter order, and one that a later argument reads goes through a temporary
  whose assignment moves after the rest. Either way no argument reads a parameter that has
  already been rebound, which is the *self tail
  call* row of `language.md` §6. The jump is written in this form before the walk decides,
  whenever `Bir` shows no lambda and no `let` function in the body; should the walk then find a
  function after all (an eta-expanded evidence argument), the copies stay and the order and
  temporaries are harmless.
- **No label**, in either shape. A `continue` reaches the innermost loop of its own function, a
  `switch` or a labelled block between the jump and the loop does not stop it, and a loop body
  holds no loop of its own (a nested loop is a nested function's). The label stays only where the
  body does hold one, and where a suspension point's re-entry names the loop (§16.3). The
  paragraph above that reserved the label for §7's `switch` was cautious, not necessary.
- **`for (;;)` and not `while (true)`**, for every loop the emitter writes, copies or not: four bytes
  fewer and the same statement.
- **A `continue` that ends the body is not printed**, in either shape: control reaching the end of
  the body goes round again. The printer follows the body's last statement through the arms of an
  `if` and into a block, and never into a `switch` case, where falling off the end runs the next
  case (`Print.markLoopTail`).

A body that does make a function keeps the copies and the `const` prologue, exactly as above,
with its jumps in parameter order and no temporary (`mayGoInPlace` says so before the body is
lowered, from `Bir`; it is a hint, and the walk over the JavaScript still decides) — `emit/TailCallInPlace` pins both shapes side by side, and `run/TailCallClosures` (the
`build n acc` program) still prints `1 2 3`.

**`if (c) { return x; } else { … }` stays as it is.** Research 47 §6 item 3 also asked for
`if (c) return x; …`, §9's `if_return`. It was built in the printer and measured on 2026-10-02:
`bench/size.mjs`'s release total fell 617 brotli bytes of 244 527 (−0.25 %), and the `bench/ui`
app, the browser measurement, grew 5 (5 032 → 5 037). §9's finding stands and it was taken out.

### The exit test is the loop's header

*Added 2026-10-02 (research 50 §5.3), amending "`for (;;)` and not `while (true)`" above and §9,
*Compact statements*, item 6.* A loop whose first statement is an `if` one arm of which leaves it
is printed with that test as its header and the exit after it, **in both builds**:

```js
// before                                          // after
for(;;){if(!(h<d&&h<g))return d===g?"EQ":…;…h++}   while(h<d&&h<g){…h++}return d===g?"EQ":…
```

**Why.** V8 runs the first form measurably slower when the exit's value is computed inside the
loop. Research 50 found it in `List.compare` written in beni, 1.16–1.19× slower than the
hand-written `for(;k<n&&k<m;k++){…}return …`; isolated in Node 24 (one process per variant per
round, alternating, medians of 5, ranges disjoint), at 1 000 elements:

| `compare`'s loop written as | µs | ÷ |
|---|--:|--:|
| `for(;;){if(!(k<n&&k<m))return n===m?"EQ":…;…}` | 2.01 | 1.00 |
| `while(k<n&&k<m){…}return n===m?"EQ":…` | 1.25 | 0.62 |
| `for(;;){if(!(k<n&&k<m))break;…}return n===m?"EQ":…` | 1.26 | 0.62 |
| `for(;;){if(!(k<n&&k<m))return "EQ";…}` (an atom) | 1.25 | 0.62 |
| `for(;;){if(k>=n||k>=m)return n===m?"EQ":…;…}` | 2.02 | 1.00 |

so the cost is the computed exit inside the loop, not the compound test; a loop whose exit is a
name or a literal (`eq`'s `return true`, a sum's `return s`) is at parity either way. Moving every
exit out is the rule, rather than only the computed ones, because it is the robust shape and the
smaller one (below). Research 50's own benchmark, the prototype's beni `List.compare` built before
and after this change (7 processes per side): 0.165 → 0.141 µs at 100 elements, 1.48 → 1.28 at
1 000, 14.9 → 12.5 at 10 000 (0.85×, ranges disjoint), and `compare` of two views 2.28 → 1.49
(0.65×; this row and the next, 3 processes per side); `==`, `slice`, `concat`, `push`,
`[ x, …xs ]`, a walk, `sum` and `drop` within ±2 %.

**The rule** (`Print.whileLoop`). An unlabelled loop whose first statement is an `if` with one arm
an **exit** — a `break` of no label, or a statement that leaves the function on every path and
does nothing else: a `return`, a `throw`, or an `if` each arm of which is one such statement
(`Print.exitTree`) — and whose other statements hold no `break` of their own:

- the header is the test, negated when the exit is the first arm (`!(c)`, or `a!==b` for
  `a===b`) and as written when it is the second (`if(c){…}else return x`, the shape of a source
  `if` whose `else` ends the loop);
- the body is the other arm, then the statements after the `if`;
- the exit follows the loop, unless it is a `break`, or a `return` with nothing to say at the end
  of the function (§9 item 6's case).

It is exact: the loop leaves only through its header — no `break` remains in the body, and a
`continue` re-tests the header as it re-ran the `if` — and the exit then runs where it ran
before, reading the same variables, while it declares nothing and jumps to no loop. A tail
`return` of a function whose result nothing reads (§4) stays inside, since it is not written as a
`return` at all. Under `--release` a body that is one `if` `compactIf` would split is braced so
that it splits: `while(c){if(x)return d;d++}`, not `while(c)if(x)return d;else d++`.

**Size** (`bench/size.mjs`, 373 programs and the browser pages, against the compiler before):
release brotli 463 967 → 463 531 (−436, 92 programs smaller and 55 larger, the largest growth
`bench/corpus` +34), release raw 1 341 792 → 1 337 431, development brotli 2 288 443 → 2 285 541.
Item 6's measured 415-byte cost of the wider rule was a `while` that kept the exit in its first
arm; the two halves of this rule — the exit in either arm and a whole exit tree, so that a
derived `compare` is `while(a.$===b.$){…}return …` with no `!(` — are what turned it into a cut.
Fixtures: `emit/release/core/WhileLoops`, `emit/TailCallLoop`, `emit/TailCallInPlace`,
`emit/DerivedCompareNominal`; every `run/` program, built both ways, is its differential test.

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
pub foldl : List a, b, (a, b → b) → b
foldl xs acc func =
    case xs of
        [] → acc
        x :: rest → foldl rest (func x acc) func

pub foldr : List a, b, (a, b → b) → b
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

*Amended 2026-09-30.* The accumulator loops above are gone from `core/List`: `map`, `map2`–`map5`,
`indexedMap`, `filter`, `filterMap`, `take`, `append`, `concat`, `concatMap`, `intersperse`,
`unzip` and the merge of `sortWith` are written as the plain recursion again, each self-call the
tail of a `::`, which *Tail calls modulo cons* below compiles to one loop that builds front to back.
*Tail calls modulo cons* has the details, the identities kept and the measurement.

### Tail calls modulo cons

*Added 2026-09-30.* The loop above ends the stack overflow of an accumulator. It did not end the
overflow of the list code Elm programmers write most, where the self-call is the **tail of a `::`**
rather than the whole return value:

```elm
mapRec xs f =
    case xs of
        [] → []
        x :: rest → f x :: mapRec rest f
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

*As built, 2026-09-30.* The first version switched the rewrite off in a suspendable body, which
made every `::` step there an ordinary call and its recursion a frame per element on the fast path.
That was harmless while nothing in `core/` had the shape; once `List.map` did (below), `List$map$s`
over 100 000 elements with a callback that may suspend but does not overflowed the stack, where the
accumulator version had been a loop (`run/SuspendListBuildDeep`, red before this paragraph). So a
suspendable body builds too, and the slow path needs no second entry to the loop. The continuation
is `Suspend`'s loop mode unchanged — a copy of the rest of the iteration, which writes its cells into
the captured `$last` and moves it — except that its `continue` becomes

```js
return Task$andThen(F($in$0, …), ($built) => {
  $last.b = $built;
  return $root.b;
});
```

the function re-entered with its slots, building the rest of the list in a destination of its own,
and that list linked in as this one's tail. Capturing the `let` itself rather than its value is
sound here, because the call that allocated `$last` has returned the waiting sentinel and never
runs again: the continuation is the destination's only owner. The fast path stays in the loop,
so a callback that answers at once costs what it costs in the direct body; each park costs one
more root cell and one arrow, and a list whose every element parks holds one linking continuation
per park on the fiber's stack — on the heap, and popped one at a time by the run loop, like any
other continuation (`run/SuspendDeepRecursion`). Resumption is still one-shot, which is what makes
the capture sound. `emit/SuspendShapes`' `fetchAll` pins the shape.

**`core/` as written today does not have this shape**: `map`, `filter`, `filterMap`, `take`,
`append` and `map2`–`map5` are accumulator loops followed by one `reverse` (or `foldr`, which is
`reverse` and `foldl`), and none of them is a cons step. Whether they should be rewritten into it
is measured below and is not part of this change.

*Amended 2026-09-30: `core/` now has this shape.* Every `core/List` function that builds one list
is the recursion Elm writes, its self-call under `::`, and so one loop: `map`, `indexedMap` (a
helper carrying the index, where it was `map2` over a `range` of the `length`), `filter` and
`filterMap` (a dropped element is an ordinary tail call), `take`, `append`, `concat`, `concatMap`
(one pass, where it was `concat` of a `map`), `intersperse` (two cells per step), `map2`–`map5`,
`unzip` (two `map`s), and `sortWith`'s merge. What they kept:

* **Callback order**: a step's head is evaluated before the loop moves on, so every callback sees
  the first element first, as `checker.md` Appendix B states, and a callback that itself builds a
  list finishes it before the outer one moves (`run/ListDirectEdges`, `run/CallbackOrderList`).
* **Identity**, where the old functions shared: `append xs []` is `xs`, and `append` shares its
  second list as the tail. `concat` shares its last non-empty list, as `foldr … append` did, which a
  loop that copies every list it meets would not: it keeps the last non-empty list met *pending*,
  copies it only when another non-empty one arrives, and returns it as the tail at the end.
  `concatMap` does the same with its callback's answers, which is exactly what `concat (map …)`
  shared. The merge returns what is left of one list as the tail, as `reverseAppend` did.
  `filter` keeping everything was a new list and still is (`run/ListIdentity`).
* **Stability and the comparator's calls**: `sortWith` splits with the same slow and fast pointers
  `splitHalf` had, as two functions — `frontHalf`, a cons step building the first ⌊n / 2⌋ elements
  front to back, and `backHalf`, a plain loop returning the rest uncopied — so the halves, the
  merges and every call of `cmp` are what they were. (Counting the list and splitting at `n // 2`
  was tried and dropped: `//` is `Basics.idiv`, a `foreign`, and made every development build that
  sorts ship `Basics.foreign.mjs`, 1.5 kB brotli.)
* **Stack safety** at 100 000 elements for each of them (`run/ListDirectDeep`), and in the
  suspendable body with a callback that may suspend (`run/SuspendListBuildDeep`, above).

**`partition` still accumulates and reverses**: it builds two lists, and a cons step has one
destination. Its accumulators are now loop parameters instead of a pair rebuilt per element. `foldr`
is `reverse` then `foldl` by contract, `range` and `repeat` build back to front already, and the
`Dict` folds walk trees.

### Tail calls modulo cons, onto an array

*Added 2026-10-01; specified, not built* (§4, *Lists are arrays*; `plans/list-arrays.md`'s second
slice). *Built 2026-10-01, with one departure: an exit that is not the literal `[]` is `return
List$close($root, v)`, and a suspended building loop's continuation `($built) => List$close($root,
$built)`. `close` is core-private: it pushes `v`'s elements onto the destination its loop owns and
returns it — or `v` itself when nothing was pushed, as `Basics$append` would — so the result is
plain, nothing is copied twice, and no `Basics` sibling ships for it.* **The rewrite stays**, with a
new destination. It is not made obsolete by arrays: without
it, `f x :: go rest` on an array is a copy of the rest per step *and* a stack frame per element —
O(n²) and an overflow at 100 000, the worst of both representations (research 38 §16.8, candidate
B) — while with it research 46 §0 measured the Elm-shaped `map` and `filter` by hand at 1.4–2.4×
the best candidate on E1t. A stack overflow is a runtime exception the language promises not to
have, so this is still §8's *mandatory*.

*Amended 2026-10-01 (E1tp): decided, the rewrite stays mandatory, for the stack alone.* With a
claimable head the unrewritten `[ f x, ...go rest ]` is no longer quadratic: the recursion returns
the newest version of its result, and each frame's prepend claims its head, amortised O(1). But it
is still one native frame per element, and research 38 §16.4's five shapes overflow Node's stack at
100 000 elements whatever a prepend costs. Cheap prepend changes the rewrite's justification from
"O(n²) and an overflow" to "an overflow", and a runtime exception in a well-typed program is enough.
**The destination stays the builder** below and does not become a chain of prepends: a builder is
one plain array pushed in place, which reads at O(1) with no header afterwards, where building from
the back by prepends would hand the caller a trie. What cheap prepend does simplify is everything
the rewrite does **not** reach — a building recursion through a `let` that combines two results, a
mutual recursion, a `foldr` whose lambda prepends: those are linear now, and deep only as far as
their own recursion is (on `foldr`, a loop, not at all), exactly as on Elm's cons cells.

What a **cons step** is, what **reaches** means, which functions build, the evaluation order, the
evidence parameters, closures, `?`, mutual recursion and *Other constructors* are all unchanged.
Only the destination changes:

- **The destination is one fresh array**, `const $root = [];`, allocated before the loop — a builder
  in §4's sense (invariant 5). `$last` is gone.
- **A cons step pushes its heads**, in order, `$root.push(h)`, each head evaluated in its own
  statement exactly where it was evaluated before, then jumps as §8's tail call does.
- **An exit writes its value after what was pushed**: `return $root;` when the value is the literal
  `[]`, and otherwise `return Basics$append($root, v);` — which is `v` itself when nothing was
  pushed (the recursion's own answer when it took no step) and a fresh plain concatenation
  otherwise. An exit's value is evaluated where it was before, after every head pushed.

```js
const Main$mapRec = ($in$0, f$2) => {
  const $root = [];
  Main$mapRec: while (true) {
    const xs$1 = $in$0;
    if (xs$1.length === 0) {
      return $root;
    } else {
      const x$3 = List$unsafeGet(xs$1, 0);
      const rest$4 = List$view(xs$1, 1);
      $root.push(f$2(x$3));
      $in$0 = rest$4;
      continue Main$mapRec;
    }
  }
};
```

(*Scalar views*, below, removes `rest$4` and the view from this loop.)

**Cost.** One `push` per head — the builder's amortised O(1) — so a building function is O(n + |v|)
over the exit's value `v`, where the cons version shared `v` as its tail in O(1). So `append`'s shape
(`x :: go rest ys`, exiting with `ys`) copies `ys`, which `++` does anyway, and a `merge` copies
the side it returns at the end once. Nothing becomes quadratic.

**Why the mutation is sound** is the cons version's argument unchanged: `$root` is fresh, reachable
only from a local of this call until the `return` hands it over, never written after (§4's
invariants 1 and 5). A head that throws leaves garbage nobody held. §9 item 1 never drops
`$root.push(…)`, a method call on a local.

**In a suspendable body** the fast path stays in the loop as before, and the slow path's
continuation is `($built) => Basics$append($root, $built)`: the function re-entered with its slots
builds the rest of the list in a destination of its own, and the continuation appends it to what
this one pushed — the copy of the rest that `$last.b = $built` avoided, once per park, which is O(n)
per park where the cons version linked in O(1). One-shot resumption is still what makes capturing
`$root` sound (`transparent-effects-proposal.md` §16.3's amendment of 2026-10-01).

**Fixtures.** Every `TailModCons*` fixture, `ListDirect*`, `SuspendListBuildDeep` and
`run/ListIdentity` keep their outputs except `ListIdentity`'s lines for `append`'s and `concat`'s
shared tails, which §4's *Identity* withdraws (`plans/list-arrays.md` records the lines);
`emit/TailModConsLoop`, `emit/release/TailModConsLoop` and `emit/SuspendShapes` are re-recorded to
the shape above.

### A cons step in the bracket spelling

*Added 2026-10-01, the owner's list syntax* (`language.md` §6.8, *The list syntax*). With `::` gone
the owner withdrew the question of keeping tail calls modulo cons "for `::`" (W35, O2), and what
the rewrite now recognises has to be said again. **The rewrite stays, and it retargets to a literal
whose last item is a spread of a self-call**: `[ f x, ...go rest ]`, `[ a, b, ...go rest ]`. That
is the shape Elm programmers write most, it overflows the stack at 100 000 elements without the
rewrite, and a stack overflow in a well-typed program is a runtime exception the language promises
not to have — so this is still §8's *mandatory*, not an optimisation.

It needs no recognition of its own. Lowering writes `[ h1, …, hk, ...t ]` as `List.cons h1 (… (List.cons
hk t))` (`language.md` §8), so **a literal whose last item is a spread is exactly k cons steps**,
and everything above — what a step is, what *reaches* means, evaluation order, evidence, closures,
the suspendable body, the destination on cons cells and on an array — applies unchanged. The
fixtures that pinned `f x :: go rest` pin `[ f x, ...go rest ]`, and their outputs did not move.

What is **not** a cons step, spelled out because the new syntax makes it easy to write:

- **A spread anywhere but last.** `[ ...go rest, x ]` is `List.append (go rest) [ x ]`: the
  self-call is an argument of an ordinary call, so it is a frame per element, and the append copies
  — `go rest ++ [ x ]` as it always was. `[ ...go a, ...go b ]` likewise. A program that builds at
  the end writes an accumulator and `List.push`, which is linear and needs no rewrite.
  *Amended 2026-10-01 (E1tp):* after the flip that `List.append` pushes onto a trie or a long
  list (§4's runtime table), so `[ ...go rest, x ]` is linear in time; it is still a frame per
  element, and still not a step.
- **A spread of anything but the self-call's result**: `[ x, ...rest ]` returned as a value is an
  ordinary returned value, as `x :: rest` was.

### Scalar views

*Added 2026-10-01; specified, not built* (`plans/list-arrays.md`'s third slice). *Built
2026-10-02, with these departures, each reversible:* the rule is not applied in a suspendable body
(its re-entry passes the slots as lists), nor to a slot some `case` matches with an item after the
spread; §7's re-consing rule is built for a scalar slot only — a re-cons of what a pattern on
one matched is the offset it matched at, passed back or built there (and so the very list the
walk was given at the entry offset), while outside a scalar view the runtime's re-cons of
§4's table still stands for it; the entry test when the parameter itself is built is `$s.length - o ===
$v.length ? $v : List$view($s, o)` — a suffix of the base is at the entry offset exactly when it is
as long as the entry list — so no entry offset is kept; and `Reach` keeps `base` and `offset` for
every declaration with a list pattern, as it keeps `unsafeGet` and `view`. This is the rule
the owner's decision names: **an `x :: rest` walk becomes an index loop.** It is research 38 §16.3's
**R3**. Without it each step of a walk allocates a view where a cons list's cells already existed,
3.8–7.9× the cons list on a bare `sum` (research 38 §17.4, research 46 §0's "bare `x :: rest` walk
≈ 10×"); with it the walk is the proven-plain `a[i]` loop research 38 §9 measured at 0.3–0.5× the
cons list, and research 38 §15.11 measured at up to 2.2× faster than a loop over `unsafeGet`.

**When it applies.** To one parameter slot *i* of a function that §8 lowers to a loop, when all of
these hold — each a syntactic test over `Bir`, like every other test in §8:

1. The slot is **carried** (§8's *The emitted shape*): some tail self-call passes something other
   than the parameter itself.
2. **Every tail self-call's argument *i*** — cons steps included — is one of: the parameter itself;
   a variable a list pattern bound to a tail `(p, k)`, `k ≥ 1`, of the parameter `p` (the `rest` of
   `x :: rest`, of `a :: b :: rest`, or an `as` naming a sub-list); or an expression §7's
   re-consing rule turns into such a tail. Each of them is a **suffix of the parameter's value on
   entry to the call**.
3. The parameter is the scrutinee of at least one `case` with a list pattern — which, with 2, is how
   a backend that reads no types knows the slot holds a list.

**What it emits.** The slot becomes an **offset** into a **base** array fixed for the whole call:

- Before the loop, `const $s$<i> = List$base($in$<i>);` and `$in$<i> = List$offset($in$<i>);`. The
  slot `$in$<i>` now carries an integer, and the loop's prologue `const` binds the parameter's
  ordinary name to it, as §8 binds every carried slot — so §8's no-temporaries invariant holds
  unchanged: an argument written against the ordinary names reads this iteration's offset.
- A list occurrence `(p, k)` of §7 becomes `(o + k)` over `$s$<i>`, `o` the offset: the test
  `[]` is `o + k === $s$<i>.length`, `::` is `o + k < $s$<i>.length`, and the head of `(p, k)` is
  `$s$<i>[o + k]` — a bare index, sound because the base is a plain array by `base`'s contract and,
  being published, never changes (§4, invariant 1). This is the one place emitted code indexes an
  array directly.
- A tail self-call's argument *i* is the integer `o + k` (the parameter itself is `o`).
- **Any other read** of the parameter, or of a tail variable of it — an argument to another function,
  a returned value, a closure's capture, a field of a record, an argument to a non-tail self-call, a
  re-entry of a suspendable loop (`transparent-effects-proposal.md` §16.3) — **materialises** it
  there, in O(1): `List$view($s$<i>, o + k)`, except that at the offset the call entered with it is
  the entry value itself (`$v$<i>`, bound before the loop only when some read materialises), so a
  walk that took no step returns the very list it was given (§4, *Identity*). The rule is therefore
  never all or nothing: a loop that returns `rest` at its exit, as `drop` does, keeps the index loop
  and allocates one view at the exit.

```js
// sum xs acc = case xs of
//     [] -> acc
//     x :: rest -> sum rest (acc + x)
const Main$sum = ($in$0, $in$1) => {
  const $s$0 = List$base($in$0);
  $in$0 = List$offset($in$0);
  Main$sum: while (true) {
    const xs$1 = $in$0;
    const acc$2 = $in$1;
    if (xs$1 === $s$0.length) {
      return acc$2;
    } else {
      const x$3 = $s$0[xs$1];
      $in$0 = xs$1 + 1;
      $in$1 = Basics$add(acc$2, x$3);
      continue Main$sum;
    }
  }
};
```

**Why it is sound.** Every value the slot takes is, by condition 2, a suffix of the value it had on
entry, and that value's elements are `base[offset …]` by `base`'s and `offset`'s contract. A suffix
of it is therefore `base[o …]` for the `o` the slot now holds, and the loop reads only indexes it has
just tested to be below `base.length`. `base` of a trie is its cached plain copy (invariant 1's
cache), computed once per call — O(n), which the walk pays anyway. Materialising yields a list equal
to the one the recursive version held, and `===` to it wherever the recursive version held the
entry value.

**It composes.** A building function's slot is scalarised as any other (`map` above then has no
view at all); a `merge` with two list parameters has two bases and two offsets; §7's re-consing
rule applies first, so `pairwise`'s `(a, b) :: pairwise (b :: rest)` passes `o + 1`. A slot whose
arguments come from elsewhere — `go (List.filter f xs)` — is not scalarised, and its walk
allocates one view per step, O(1) each, as §7 says. *Amended 2026-10-01 (E1tp):* over a trie an
unscalarised walk allocates a trie header per step, and a reversed copy of 31 every 32nd, where E1t
allocated a view over the cached copy; research 46 §11.5 item 3 measured the difference at about
2× on the merge sort of sorted input. A scalarised slot does not see it: `base` of a trie is still
its cached plain copy, flattened once per call.

**Fixtures** (third slice): `emit/ListScalarView` and `emit/release/ListScalarView` (the shape: a
walk, a building walk, two slots, a slot taking the parameter itself, a materialised exit, a
closure capture); `run/ListScalarView` (every materialisation point, the entry-value identity
through `refEq`, a trie and a view as the input, `Debug.log` order unchanged); the corpus's
`run/` outputs unchanged.

### Fixtures

Every one of these is `tests/corpus/run/` unless it says otherwise; §12's rule that behaviour is
proved by running still holds, and the shape claim gets exactly one golden.

| Fixture | Intent | Observable |
|---|---|---|
| `TailCallDeep` | **the fail-first one.** A two-parameter accumulator counting to 1 000 000 | `500000500000`; overflows the stack before the fix |
| `TailCallSwap` | argument order: `swap a b n = … swap b a (n - 1)` | `2,1` then `1,2` for odd and even *n*; naive in-place assignment prints `2,2` |
| `TailCallClosures` | the capture hazard: cons a `λx -> x + n` each iteration, then apply each to `0` | `1`, `2`, `3`; in-place reassignment prints `0`, `0`, `0` |
| `TailCallNesting` | a tail call reached through `case` inside `let` inside `if`, and a nested `case` | any deep result, run at a depth that overflows without the loop |
| `TailCallNotTail` | `f n = if n <= 0 then 0 else 1 + f (n - 1)` must NOT loop, and a function with one tail and one non-tail self-call must still be right | small depths, exact answers |
| `TailCallBind` | `let m <- f (n - 1)`: the call loops, the continuation does not | `sumTo 3 λx -> x` is `1` |
| `TailCallEvidence` | a `where`-constrained function looping deep with evidence forwarded, **and** a tail self-call at a different instantiation whose evidence therefore changes | exact counts; the second half is the polymorphic-recursion case above |
| `TailCallLetFunction` | a `let`-bound helper counting to 1 000 000 | as `TailCallDeep` |
| `TailCallLambdaBody` | `f = λn acc -> … f …` counting to 1 000 000 | as `TailCallDeep` |
| `ListFoldDeep` | `List.foldl` over `List.range 1 1000000` and `List.foldr` over a list of 200 000 | the sums; proves the beni folds and `range` all survive |
| `emit/TailCallLoop` | the shape: label, `$in$<i>` slots, the prologue `const`, `continue`, and one loop-invariant parameter keeping its own name | the golden of §12 |
| `TailModConsMap` | *added 2026-09-30, like the rows below it.* **The fail-first one of *Tail calls modulo cons*:** `f x :: mapRec rest f`, and `filterRec` mixing a cons step with a plain tail call, over 100 000 elements | lengths, sums and small results in order; overflowed before |
| `TailModConsTakeWhile`, `TailModConsPairwise`, `TailModConsMerge` | report 38's other overflowing shapes: an exit that closes the built list with `[]`, a self-call whose argument is itself a `::`, and a `merge` with two consing branches and two exits that return the other list | as above; each overflowed at 100 000 |
| `TailModConsBranches` | two cells in one step, a different step in each branch, a `::` whose tail is an `if` with a self-call in each arm, a `let` between `::` and the self-call, a building `let` helper, and one nested in a building function | exact small lists and deep sums |
| `TailModConsEvidence` | a `where`-constrained building function forwarding its evidence, and one whose consing step recurses at a different instantiation | the second prints `0,1,1`; an evidence slot assumed invariant would compare `Box`es as strings |
| `TailModConsOrder` | `Debug.log` in two heads and in the argument, a head that is a `case`, and closures over each step's head | the log order of the recursive version, byte for byte; `10,20,30` |
| `emit/TailModConsLoop`, `emit/release/TailModConsLoop` | the shape: `$root` and `$last` before the loop, one cell per head, the exit's write and `return $root.b`, and a `::` that does not reach a self-call left alone | the goldens of §12 |
| `ListDirectEdges` | *added 2026-09-30 with core's rewrite, like the rows below it.* Every rewritten `List` function at its edges (empty, one element, counts past either end, empty lists at every position of a `concat`), and `Debug.log` order through nested building calls | the old functions' output, recorded before the rewrite |
| `ListDirectDeep` | every rewritten function over 100 000 elements | lengths, first and last elements, sums |
| `ListIdentity/` | through a test platform's `refEq`: the elements passed through, `append`'s two shares, `concat`'s and `concatMap`'s last non-empty list, `sort` of one element | `same` on every line; a `concat` that copies its last list prints `copied` |
| `SuspendListBuildDeep` | `map`, `filter`, `filterMap`, `indexedMap`, `concatMap` and `map2` over 100 000 elements with a callback that may suspend and does not, then with one that parks every thousandth element | the same lists; the fast path overflowed while a suspendable body did not build |
| `emit/SuspendShapes` (`fetchAll`) | a building loop in a suspendable body: the fast path in place, the slow path's `continue` a re-entry linked into `$last.b` | the golden of §12 |

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

*`core/` rewritten, measured 2026-09-30* (`node bench/list/run.mjs --before-rev=<parent>
--sample-ms=50`, Node 24.19, one pinned core, load 10.7–13.8 from other sessions; the median of
three rounds of nine samples, both cores built by one compiler and timed interleaved against the
same input). µs per call, before → after:

| function | n = 1 000 | n = 10 000 | n = 100 000 |
|---|--:|--:|--:|
| `map` | 23.3 → 8.8 (0.38×) | 337 → 85 (0.25×) | 4 687 → 1 304 (0.28×) |
| `filter` (half kept) | 15.2 → 7.6 (0.50×) | 148 → 63 (0.43×) | 1 979 → 817 (0.41×) |
| `filterMap` | 18.6 → 9.5 (0.51×) | 195 → 95 (0.49×) | 2 151 → 1 103 (0.51×) |
| `indexedMap` | 33.4 → 8.6 (0.26×) | 393 → 100 (0.25×) | 10 878 → 2 296 (0.21×) |
| `take` (half) | 11.1 → 4.4 (0.40×) | 108 → 41 (0.38×) | 1 399 → 491 (0.35×) |
| `append` (`ys` of 10) | 31.2 → 8.0 (0.26×) | 330 → 77 (0.23×) | 3 992 → 1 194 (0.30×) |
| `concat` (lists of 10) | 33.3 → 8.0 (0.24×) | 360 → 105 (0.29×) | 7 233 → 2 236 (0.31×) |
| `concatMap` (two each) | 145 → 30 (0.21×) | 1 738 → 324 (0.19×) | 49 319 → 5 600 (0.11×) |
| `map2` | 26.0 → 11.2 (0.43×) | 243 → 104 (0.43×) | 3 662 → 1 410 (0.39×) |
| `map3` | 26.2 → 12.2 (0.46×) | 258 → 116 (0.45×) | 3 935 → 1 542 (0.39×) |
| `map5` | 28.8 → 17.0 (0.59×) | 241 → 141 (0.59×) | 3 045 → 1 487 (0.49×) |
| `partition` | 20.1 → 10.8 (0.54×) | 210 → 119 (0.56×) | 2 518 → 2 022 (0.80×) |
| `unzip` | 21.6 → 11.3 (0.52×) | 234 → 123 (0.53×) | 3 269 → 2 021 (0.62×) |
| `intersperse` | 23.2 → 11.0 (0.47×) | 262 → 134 (0.51×) | 4 633 → 3 116 (0.67×) |
| `sortWith` | 281 → 157 (0.56×) | 3 901 → 2 042 (0.52×) | 63 304 → 31 096 (0.49×) |

Every function is faster at every size, 1.25–9× (`partition`, which still reverses, gains from
dropping the pair per element). A first `partition` that mapped the answers and then selected
each half measured 1.08–1.10× *slower* at 1 000 and 10 000 and was replaced; 100 000-element
samples shorter than 50 ms moved by ±40 % with where a scavenge fell, so they are not quoted.
**Size** (`bench/size.mjs`, 293 programs, the same compiler with each core): the development
total 1 409 664 → 1 410 589 brotli (+0.07 %), the release total 239 627 → 241 453 (+0.76 %): a
building loop is longer than `reverse (foldl …)`. The table benchmark's application, which
uses `filter` and `indexedMap`, went 5 093 → 5 024 brotli in `--release` (14 850 → 14 635 in
development), its `indexedMap` no longer reaching `range`, `length` and `map2`.

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
constant evaluation, sequence joining, comparison and switch rewriting. (*2026-10-02*: `if_return`
was measured again, and stays out — §8, *In place, when nothing captures*. Inlining a function
called from one place is built, for a runtime written in beni — *A function called once is written
where it is called*, below.)

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
   *Amended 2026-10-02:* the `undetermined` term lowers to `===` in place and has no edge;
   `Basics.eq` dispatches like `==` now and is no structural answer (`static-dispatch-spike.md`
   §3.1, amended).
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
800 ms budget. Node identity is input-derived end to end — `Graph.Index` comes from the file index
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

#### A `case` arm on a constructor nothing builds

*Added 2026-10-02.* Declaration granularity keeps everything a surviving body names, including
what it names only inside a `case` arm that can never run because no value of the arm's
constructor is ever built. That is the shape of every interpreter over a closed set of requests:
`Tea.element`'s command table names the fiber runtime in its arm for `Cmd.Perform`, and a program
whose every command is `Cmd.none` builds no `Perform` — yet it shipped the interpreter, the fiber
runtime and `Dict` whole (5 496 brotli against the sandbox's 1 551, `boundary.md` §9.8.9's
measurement). So **a constructor is a node of the graph**, and an edge that occurs inside an arm
is **guarded** by the constructors the arm's pattern names: it is followed once every one of them
is reached, and not before.

- **Building one.** A `ctor` or `ext_ctor` instruction anywhere but at the head of a `pat_ctor` —
  applied, bare, or passed as a function — is an edge to that constructor, guarded like any other
  edge by where it occurs. So a `Cmd.map` that rebuilds a `Perform` inside its `Perform` arm builds
  one only if something else did first.
- **Where an arm's body is.** `Bir` is post-order and `bir/Lower.lowerBranch` lowers a branch's
  pattern, then its body, then appends the `branch`: the body is exactly the instructions after the
  pattern's root up to and including the body's root. Every constructor the pattern names, at any
  depth, guards every edge whose instruction is in that range, and an enclosing arm's guards add to
  an inner one's — an arm is taken only on a value that matches its whole pattern, inside arms that
  were taken. A position keeps the guards of its four innermost guarded arms, which drops
  conditions and never adds one. Leg 3's edges sit at their site's instruction, the markup leg's at
  its root, the effect legs' at theirs. Leg 1's `refs` rows have no position; each is made together
  with a `.top` instruction that leg 2 reads (`Lower.resolveValue`), so a row adds an unguarded
  edge only when no instruction of the declaration names its target — a net under an invariant, not
  a source of edges.
- **Exempt constructors are roots**, reached before the walk: every constructor of a type declared
  in `core` — the compiler writes `Bool`, `List`, `Order`, `Maybe` and `Result` values no
  instruction spells (an `if`, a list literal, a derived `compare`, `?`), and core's siblings build
  them; every constructor of a type that a `foreign`, `foreign type` or vocabulary declaration of
  the build names, and of every type that such a type's constructors or an alias name,
  transitively; and every constructor at all in a `--library` build, whose callers are not in the
  build, or in a build with a `schema` declaration, whose parse will build values no instruction
  spells. None of these is ever a guard.
- **Why that is sound.** A value is built by beni code that spells one of its constructors, by the
  compiler for a core type, or by hand-written JavaScript — a sibling, a runtime — which receives
  and returns values only through signatures: it can build a value of a type its signatures name,
  and of a type variable only what it was handed, since it cannot know the type. The first is the
  graph and the other two are the exemptions. An arm is taken only on a value whose tag is its
  constructor's, so an arm on a constructor nothing reached builds is never taken, and neither is
  anything only it names. `==`, `compare`, `Debug.toString` and the derived functions only read.
- **Lowering.** `Lower` asks the same question: an arm whose pattern names a constructor the walk
  did not reach is lowered with `undefined` for its body — its test and its bindings stay, and it is
  never taken — so the emitted code names nothing elimination dropped. Every edge the walk left
  unfollowed is inside such an arm, its own or an enclosing one, so the wall (`Lower.requireLive`)
  still holds and still checks it. *(Amended 2026-10-02, research 51 §5: **the arm is left out of
  the decision tree** (§7) — no value matches it, so every value matches the same row with or
  without it. A fan whose other constructors are all of that kind then has one alternative and
  tests nothing, and an exhaustive one writes its last live alternative as the `else`, where each
  such arm was a test and a `return undefined`; a `case` every arm of which is such keeps them all.
  `emit/release/app/DeadArms`.)*
- **Cost.** One bitset per module over its constructors, a chain of guards per guarded position,
  and a waiting list per constructor that some edge is blocked on: linear in the edges, times the
  four-deep cap.
- **Tests.** `run/DeadConstructorArm` (a module's value named only in the arm of a constructor no
  code builds is not emitted, the arm's constructor built elsewhere under a guard is, and the
  program prints the same in both builds); `build_test`'s *an element whose commands are all
  `Cmd.none` ships no fiber runtime*; `Reach.zig`'s unit tests for a chain, the cap and a
  constructor waited on.

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
  fixture that pins it. *Amended 2026-09-30: no longer true, and the refusal no longer rests on it.
  Item 1 now keeps every binding that may be impure, `Debug.log` included, so the two builds print
  the same lines; the other two reasons stand.*
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
2026-09-19 on. *Amended 2026-09-30: the fixture stays and its `.release-expected` is deleted. Item
1 keeps a binding that may be impure (below), so under the flag the release build prints the dead
binding's line too, and "a release build behaves exactly as the development build does" now holds
even where only the harness can look.*

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

*Amended 2026-09-30: **zero uses drops a binding only when its right-hand side is pure.*** Effects
ended the premise above: a `foreign` may now be `impure` or `suspends`, and a function that calls one
is inferred so (`transparent-effects-proposal.md` §14), so "asks nothing about the right-hand side"
made a release build skip a named `Task.spawnIn`, or a platform's impure call, that its development
build performs (research 44 §8). The rule is now `language.md` §6's first bullet as amended the same
day, and it is decided by lowering, not guessed by this pass:

- **Lowering lists the bindings to keep** (`Lower.effect_keep`, `Opt.runKeeping`): a `let` value
  binding's `const`, or a `let` pattern's subject temporary, whose BIR right-hand side reaches —
  outside any lambda or `let` function it builds — a `call`, `method_call` or `type_dispatch` whose
  dispatch-table row says **`impure`**, or whose suspension answer is not `no`. Markup is not
  walked and counts as effectful, which costs only the binding of a view nothing reads. The pass
  never drops a listed binding; the suspendable form (`transparent-effects-proposal.md` §16.3,
  `src/js/Suspend.zig`) copies a listed `const` and lists the copy. *Amended 2026-10-02:* **nor
  does it fold one into its use.** A listed binding may be a read whose answer a later call can
  change — `let v = Js.to (Js.get o "v")` before `f (bump o) v`, where `bump` writes `o.v` — and
  the fold of a member chain into the next statement would read it after that statement's earlier
  operands ran: `f(bump(o), o.v)` answered `2` where the program says `1`. Only a read of a beni
  value, which nothing can change, is folded. `run/JsIntrinsics`'s last line.
- **`impure` in the table means *may be***: the callee's rung is `impure` or `suspends`, or it is
  `poly` (it would be, used with something that is), or a `sync` class of the declaration's scheme
  reaches it — a `sync` class cannot suspend, so it never makes a call `poly`, but it can still be
  impure (`transparent-effects-proposal.md` §16.2 as amended 2026-09-30). The table's columns and
  the sidecar's format are unchanged; only which rows say `impure` moved.
- **What stays droppable** is everything else: arithmetic, a pure call, a `foreign pure` (so
  `Node.done` still pins nothing), a lambda, and a reference to a value. `Debug.log` and
  `Debug.todo` are `foreign impure` and are kept like any other impure call — one rule, no special
  case, and `run/ReleaseDeadDebug` no longer needs a `.release-expected`.
- **One known gap, recorded rather than closed**: reading a top-level value with a `where` clause
  and no parameters runs its initialiser at the first use that needs it (`language.md` §6's table).
  A dropped binding whose right-hand side is only such a read moves that first run to the next
  use; it is observable only when the initialiser itself is impure, and the evaluation class that
  would say so is module-local and never published (`transparent-effects-proposal.md` §14.3
  rule 1).

The size cost is the bindings kept, which are exactly the ones a development build evaluates for an
effect: `emit/release/ReleaseDropsPureBinding` shows both halves.

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

*Amended 2026-10-02: a copy of a name* (`Opt.copy`; `plans/runtime-in-beni.md`, *The empty page's
last items*). A binding read more than once was never folded: its initialiser would be evaluated as
many times. One whose initialiser is a **name** evaluates nothing, so it may be: `const f = e` (or a
`let` nothing rebinds) read two or more times, whose initialiser is — after `compress` — a local `e`
bound once in the declaration and rebound by no assignment (writing a property of either is not
rebinding it: the name still holds the same object), not a `Js.Ref`'s `let` (`mutable`), is `e` at
every use, and the binding goes. **Every use must stand in the own expressions of the statements
after it in its list** (`ownUses`, as the single use's scan reads them): the printed `e` then sits
in the scope where the dropped `const f = e` named `e`, so `Rename`, which reads the IR as written,
has kept every name of that scope off `e`'s spelling — a use in a branch, a loop body or a function
could meet a name of an inner scope spelt like `e`, and keeps the copy. It is exact: `e` is in scope
wherever `f` is, holds one value from its binding on, and reading a name does nothing. The copies
come from *A function called once*: `i = unit b cx` written in is `const i' = kind.m(…); const i =
i'`, and the empty page's `let e=c.m(),f=e` is `let e=c.m()`. Measured (release, brotli, the whole
bundle): the empty `browser` page and `Tea.sandbox` 450 → **446**; `bench/size.mjs` −198 over its
368 lines (20 smaller, none larger: the schema programs −1 to −48); the `browser/` pages −34 (7
smaller, none larger); `Tea.element`, effects, `random` and the `bench/ui` app byte-identical.
Fixtures: `emit/release/app/ReleaseCopies` (a copy read where it is bound goes; one read inside a
function stays), `run/ReleaseCopies`, `emit/release/split/EmptyPage`.

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

**Amended 2026-10-02: a spelling is reused in scopes that cannot see each other**
(`Rename.Module.enter`; `plans/runtime-in-beni.md`, step 4). A declaration's locals were one flat
alphabet in emission order, so a function with fifty locals spelt the last of them with two
letters even where twenty of them lived in loop bodies that never meet. The walk now builds the
declaration's scopes — a function's parameters and body as one, a loop's body, a block, a
`switch`'s cases (an `if`'s arms are the scope around them, since the printer may write an arm's
statements into that list: `compactIf`) — and gives each local a home, the innermost scope that
holds its declaration and every use. Scopes are assigned parent first; a scope's names take, in the
order the printer meets them, the lowest ordinals that no global the declaration mentions has and
no name of an enclosing scope that is **used inside this scope** has. A name of an enclosing scope
that is not used inside may be shadowed, which is what a hand minifier does: two loops' bodies, two
closures, and a closure and the function around it share `a`, `b`, `c`… Three rules keep it a
rename and nothing more:

- **A `for…of` head's binding is in scope in its iterable** (`for(let a of a)` reads the new `a`,
  in its dead zone), so the iterable is walked inside the loop's scope.
- **A label may not be declared again inside its own statement**, so every scope opened inside a
  labelled statement counts as using its label.
- **A loop's variable declared just before the loop** may be written in the loop's `for` head by
  the printer (*Compact statements*, below) or left where it is. It is homed in the loop's scope
  but given no spelling of the scope around the loop, nor of the enclosing names that scope uses,
  so either way it collides with nothing.

Assignment is still a function of the input alone (CLAUDE.md rule 5): scopes are numbered in walk
order, and within one the order is the emission order it always was. The safety build's self-check
is per scope now: a scope's ordinals are distinct, and none is the ordinal of an enclosing name it
uses — one mark per name, linear. Measured with step 4 of `plans/runtime-in-beni.md`, where it is
most of the difference between the keyed list written in beni and the hand-written one (its
table: every `browser/` page smaller than before the step). Fixtures: `Rename.zig`'s unit tests (sibling
bodies, a used enclosing name stepped over), `run/NestingElseIf` (nested labelled blocks), every
`browser/` page's release pass (`for(let a of a)` was found there), and every `emit/release/`
golden.

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
  *Amended 2026-10-02: that one goes too* (§9, *Compact statements*, the last list, which gives
  the measurement): a release module, and a scope-hoisted application's one file, is one line with a
  newline at its end.

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
| `run/ReleaseDeadDebug` | a `Debug.log` in a binding nothing reads, beside one in a binding that is read, beside one in a dropped declaration (`run/DceDebugLog`'s other half) | exactly the live lines, in order — pins that the surviving order did not move. *Amended 2026-09-30*: the unread binding's line is now printed by both builds (item 1 keeps a binding that may be impure), and the fixture's `.release-expected` is gone |
| `run/ReleaseKeepsNamedSpawn` | a named, unread `Task.spawnIn`, and one inside a list literal, whose children print through a test platform's `foreign impure` | the children's lines in both builds (2026-09-30) |
| `run/ReleaseKeepsNamedForeign` | unread bindings over an impure `foreign` called directly, inside a pure call's argument, in one branch of an `if`, inside a tuple a pattern takes apart, through an inferred-impure helper, through a callback parameter, and through a `sync` callback parameter | every line in both builds (2026-09-30) |
| `emit/release/ReleaseDropsPureBinding` | unread bindings over arithmetic and over pure calls, beside one over `Task.spawn` | golden: the pure two are gone, the impure one's `const` stays (2026-09-30) |
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

*Amended 2026-10-01: taken up on the owner's order, with the integer tags — *Item 4, taken up*,
below, is what is built. This section stands as its reasoning, except where that one says
otherwise: the checker artifact is back (smaller), and "no record enters a program from
JavaScript" is no longer true.*

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
the hidden `--allow-debug` flag and is a harness-only fact. *(Deleted on 2026-09-30, when item 1
began keeping a binding that may be impure: both builds now print the same lines.)* Item 4 is still declined, on its own
numbers; this paragraph only removes the constraint it would have had to honour.

**The measurement that found the pin, kept.** With every field renamed, **103
of the 107 `run/` programs still print their `.expected` byte for byte**. The four that do not —
`DebugLog`, `EvalOrderLiterals`, `EvalOrderRecordFields`, `QuestionOrder` — each turn a
`{ name = "Ada" }` into `{ a = "Ada" }`. Nothing else notices: `Basics.eq`'s `Object.keys` walk
(`core/Basics.js:93-108`) compares two values of **one** type, which carry one colouring, and
`List.eq`/`List.compare` touch only `.$`/`.a`/`.b`. The record-reaching `foreign` positions are the
closed list `Basics.eq`/`neq`, `List.cons`/`eq`/`compare` and `Debug.log`/`todo`/`toString`, and only
the last two read a field **name**.

There is no per-type answer available: `Debug.log : String, a -> a` is a type variable and the record
can arrive through any number of generic frames, so "which records reach Debug" is not a question the
backend can ask. **The conservative rule needs no decision and is one membership test**: if `core/Debug`'s
`log` or `toString` survives §9's reachability walk — a *foreign binding* node, §9's table — field
renaming is off for the whole build. **The other rule was the owner's, and on 2026-09-19 the owner
took it**: Elm 0.19 refuses `Debug` under `--optimize` and **beni now does too** (*`Debug` is refused,
not pinned*, above). That deletes the pin, exactly as this paragraph said it would — a release build
cannot reach `Debug`, so the membership test has nothing to protect. `run/ReleaseDeadDebug` keeps its
`.release-expected`, now asserted under the hidden `--allow-debug` flag, which makes it a statement
about item 1's zero-use rule and no longer a statement about anything a user can build. *(Until
2026-09-30, when the file was deleted: item 1 keeps an impure binding now.)*

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

#### Item 4, taken up — record fields renamed, and integer constructor tags

*Added 2026-10-01, the owner's order: build item 4 and the integer tags under `--release`.* This
amends the section above in three places and keeps the rest of it: **the unit is still the source
field NAME, whole-program**; scheme (i) is what is built and colouring (ii) stays rejected on its
numbers; every order still sorts on SOURCE text, so this is a print-time substitution. What changed
is the premise *"no record enters a program from JavaScript"*, which the browser runtime written in
beni (`platforms/browser/Rt.beni`, `Browser.beni`, research 47) made false: it builds records with
`Js.from { p = parent, m = marker, … }` and reads them back with `Js.get s "u"`. So a field can be
seen by JavaScript, the set of such fields depends on types, and the checker artifact the section
above withdrew is back, smaller: it carries only what a solved type knows and a declaration does not
(`checker-v2.md` §28).

**Scheme (i), and why it is interference-free by construction.** Every distinct source field name
that is not pinned (below) gets its own short spelling, ranked by how often the build's generated
code names it, ties broken by the name's text. Two different fields never share a spelling, so two
fields that can sit on one object — a record type's fields, an extensible record's row, whatever a
row-polymorphic `getX` is handed — can never collide, and no interference graph is needed to prove
it. One name has one spelling everywhere, so every function that can see an object reads it the
same way, which is what made the name the unit in the first place.

**The alphabet**: `a`–`z`, `A`–`Z`, `_`, then digits from the second character, in `Rename`'s
mixed radix — and no spelling that contains `$` (`core/Debug.js`, the list protocol's `$plain`,
the constructor tag), and no spelling that is the text of a field that keeps its text (below),
because the two could be keys of one record. A spelling MAY be the text of a property that is not
a field — `a`, a tuple's slot, is the commonest: a record holds nothing but its fields, and nothing
that reads a plain property by name is handed a record whose fields it does not name. A reserved
word is a legal property name and is not skipped.

**How a field is told from every other property.** `Lower` writes a record field's key and every
read of one — a literal's keys, a record update's, `.x`, an accessor, a record pattern, a record
alias constructor's keys and its pattern's reads, a derived `eq`/`compare` over a record shape, a
field call `r.f a`, a markup row input's field path and a component's props — as a `JsIr.Name`
whose disambiguator is `Name.field`, a value no counter reaches. A tuple or constructor slot, the
`$` tag, a `Js.get`/`Js.set`/`Js.call` name, a `Js.Ref`'s `v`, `length`, and every name a markup
lowering writes through `beni_markup` are plain names, as before. The development printer spells a
field name by its text alone, so **a development build does not move by a byte**. Whole-program
specialisation keys properties by TEXT (`Spec`'s `props`), and a field-marked name is pooled and
numbered like any plain one, so a body copied into another module names the same property there.

**What is never renamed — the closed list.**

| | why |
|---|---|
| a field of a record type that crosses into JavaScript: the **boundary** | JavaScript reads and writes it by its source name. *Below* |
| a field name the build also writes as a non-field property, anywhere | one text, two meanings: `Js.get o "u"` on a record whose `u` was renamed would read nothing. The collision is found on the final `JsIr`, after specialisation, by one scan of every `member` and `property` node |
| every field of a `--library` build | its consumer is hand-written JavaScript, reading the exported records by name (the section above) |
| every field of a build that reaches `Debug` | `Debug.toString` prints field names. A release build that reaches `Debug` is refused (*`Debug` is refused, not pinned*); under the harness-only `--allow-debug` it is built with renaming off, so `run/`'s release pass still prints its `.expected` |
| a JSON key, a schema's host-object key | never a record field: a schema reads and writes a host value's keys as plain names (`schema.md`), and its generated code builds the beni record with a literal like any other |
| a markup vocabulary's attribute, a markup runtime's object | not a field. A component's props ARE a record, built at the call and read in the component, both generated, so they are renamed consistently |

**The boundary.** A record field is pinned when JavaScript can see it, and JavaScript sees a beni
value only through the two doors the wall has (`boundary.md` §4):

1. **A live `foreign` value's declared annotation** — every field of every record written in it,
   through aliases, and every field in the body of every named type it names, transitively. A
   `foreign` is how a sibling hands beni a record it built (`Dom.box : String -> Result Error
   Box`) and reads one beni built. The backend reads the annotation from the declaration's `Bir`,
   as it already reads a record alias's body.
2. **A use of `Js.from` or `Js.to` in a live declaration** — every field of the type the use was
   INSTANTIATED at, by the same walk. `Js.from { p = parent, m = marker }` pins `p` and `m`;
   `Js.to (Js.get m "n") : { h : Value }` pins `h`. Only the checker knows that type, and this is
   what `checker-v2.md` §28's artifact carries, per declaration, so elimination decides which rows
   count.

**A type variable is opaque at both doors**, which is `boundary.md` §4's parametricity rule: a
sibling handed an `a`, and platform code handed `Js.from x` with `x : a`, may store it and hand it
back, compare it with `===`, and walk it reflectively the way `Basics.eq` does — but never read one
of its fields by name, because which type it is was never its to know. Without the rule the
browser runtime's `Js.from msg` would pin every field of every program's messages. A named type
whose body is reached (`Result Error Box` reaches `Box`, `Error`) contributes its whole body, its
parameters opaque.

**When it runs.** The boundary is closed once per build, in `Emit`, after elimination and before
lowering: seeds from every live declaration's artifact rows and every live `foreign`'s annotation,
then a worklist over named types read from `Types` and the declaring module's `Bir`. It is a
function of the live sets, the artifacts and the declarations, so `--jobs` cannot move it. The
spelling table is made after `optimise`, on the calling thread, in module order: count, sort by
(count descending, text ascending), assign. A short spelling is printed by the printer's `.fixed`
slot when its name is field-marked, exactly where item 2 prints a binding's.

**Integer constructor tags.** Under `--release`, a type whose values JavaScript never sees has
integer tags: constructor `i` of its declaration, counted from 0, is `{$: i, a, b}`, and a type whose
constructors are all nullary is the bare integer. A type keeps its string tags when:

- it is in the closed boundary above — a sibling builds `{$: "Just", a}` and reads `.$ === "Done"`
  (`core/String.js`, `core/Task.js`, `platforms/browser/Http.js`) for exactly the types its
  annotations name; *(amended 2026-10-01: `String` and `Http` are beni over `Js` now
  (`plans/core-in-beni.md`), so a `Maybe` `String.toInt` makes and a `Result` `Http` resumes with
  are built by beni code, and neither is in the boundary on their account — `Http` hands its fiber
  the answer through a type variable, which is opaque at the door)*
- it is core's `Order` or `Bool` — `Order`'s `"LT"`/`"EQ"`/`"GT"` are written by siblings
  (`List.compare`, `String.compare`, `Hosted.compareKeys`) and by every derived `compare`, and `Bool`
  is `true`/`false`;
- the build is a `--library` build or reaches `Debug`, as for fields.

The decision is one bit per type for the whole build, made with the boundary and handed to `Lower`;
every place `Lower` writes a tag — a constructor's object, a nullary constant, a test, a `switch`
case, a markup probe, `isJust` — writes the bit's answer, so no two spellings of one type can meet.
**`compare` on an integer-tagged type needs no `<T>$$order` table**: the tag IS the declaration
index the table maps to, so the lookup is the tag itself and the table is not written — which also
pays the `obj[dynamicString]` the section above recorded against report 12 §5.4.

**A reflective order is a third door** (amended 2026-10-01, before merge). `Hosted.key : k -> Key
where k.compare` hands its sibling a comparable value of a type it cannot know, and `Hosted` orders
keys by what they hold — field names, then tags (`boundary.md` §9.8.3). That order decides which
subscription or command starts first, so it is observable, and respelling a key's fields or
numbering its tags changed it: `browser/tea/KeyOrder` started `Zeta` before `Alpha` under
`--release` and after it in development. So when a live `foreign` takes a bare type variable that
carries `compare`, **every type the build compares is in the boundary**: the type or record fields
of every live derived `compare`, and the parameter types of every live `pub compare`, with their
bodies, as any boundary type. A key's type has `compare` by its `where` clause, so every key type
is among them; a type the build never orders is renamed as before. One case cannot be found that
way — a `pub compare` of a type with parameters and no `where` clause, which compares what its
parameters hold by nothing the build ships — and a build with one renames nothing and numbers no
tag. `List.compare` is not such a `foreign`: its variable is under a `List`, and each element goes
to the evidence. The bench app reaches no key and does not move.

**As built, measured** (2026-10-01, brotli 11, against `master` at the commit before, same
machine). The js-framework-benchmark app (`bench/ui`, `browser-tea --release`): **5 723 → 5 639**
(−84, −1.5 %) — fields alone 5 690, the tags the other 51. `bench/size.mjs`: every program's
release build, summed, 317 139 → **314 441** (−0.85 %); the `browser-tea element` page 1 261 →
1 217, the `effects` page 5 412 → 5 258 (5 253 before keys were ordered alike); the empty pages unchanged at 605, and every development
figure unchanged to the byte. `bench/corpus` is a `--library` build and does not move, by the
rule above. A Chrome batch (n = 5, then n = 10 on three operations, on a machine at load 6–23)
put the app's script medians within noise of the build before: the two operations that read
slower in the first batch (select, append) read level or faster in the second. Against Solid 1's
script medians the release build was ahead on six of nine operations in that batch.

**The self-check**, safety builds: a field-marked name that reaches the release printer has a
spelling or keeps its text, and the table was made from every field the build names — a field the
table never saw would print as its text beside renamed reads of it elsewhere.

**Fixtures**, by intent: `emit/release/` goldens of a record renamed and of a record crossing
`Js.from` kept; `run/` programs with an extensible-record accessor over two record types across two
modules, a record passed through a test platform's `foreign` and read by its sibling, a derived
`compare` whose source order differs from its short-name order asserted through `List.sort`, and a
`Debug.toString` of a record unchanged under the harness's `--allow-debug`; a `dump --stage=dispatch`
golden of the artifact; the whole `run/` and `browser/` corpus's release pass is the differential
test, and the determinism test runs `--release` at `--jobs=1` and `--jobs=8`.

**Field names are decided after specialisation** (*amended 2026-10-02*). Both pins above were
taken from more than the build prints. Whole-program specialisation (*Whole-program
specialisation*, below) rewrites each module's `JsIr` in place and cuts declarations nothing
reaches any more, but the boundary was closed from elimination's live set, before it ran, and the
collision scan read every node of the IR, including those a fold or a cut left unreachable. So a
cast or a `Js.get` the program no longer contains still pinned a field: the fiber runtime's
`newFiber` builds `Js.from { …, scope = … }` and reads `Js.get fiber "scope"`, and on a page that
starts no fiber both are cut, yet `Tea`'s own `scope` field kept its five letters. Two changes:

- **The collision scan walks what the module's statements reach** — every child of every statement,
  each node once, the walk `Spec.peephole` takes — rather than the node array.
- **The boundary's pins are closed a second time after specialisation**, with the declarations it
  cut left out. A live declaration is *gone* when every body lowering wrote for it — its own and,
  when live, its suspendable twin — was a top-level declaration (or an import) before the pass and
  is not after, and **the pass copied nothing out of it into another statement**: slice 5's
  function called once, slice 8's small function or assignment, slice 9's producer
  (`Spec.Stats.copied`; a body reached through a property, whose declaration the pass cannot name,
  marks its whole module instead). A copy carries the cast with it — a small `show item = read
  (Js.from item)` written where each call is still hands `item` to JavaScript — so a declaration
  copied from keeps its rows. A body lowering already wrote into its one caller is not a
  declaration before the pass, so it is never gone, and its caller's rows are its own. Only the
  pins are recomputed: integer tags stay as lowering wrote them, and a type that stops being seen
  keeps its string tags.

What was pinned is a superset of what is pinned now, so no field JavaScript reads is renamed; the
walk and the second closing are functions of the specialised IR, in module order (rule 5).
Measured (release, brotli, the whole bundle, against the build before): the `browser-tea element`
page 1 215 → **1 207** (`scope`, and the counts of fields only cut code named); `bench/size.mjs`'s
total 741 444 → 741 381, 19 lines smaller and 9 larger — the counts that rank the spellings now
count printed names only, which reshuffles which field gets which letter (the effects page +4,
`ApiAndRoutes` +24, `run/SchemaDeclModules` +31; `application` −15, `run/SchemaDeclTagged` −29).
Fixtures: `emit/release/app/SpecFieldNames` (a record only a cut function casts and reads by name is
renamed; one a kept function casts keeps its name) — red against the build before;
`run/SpecializeFieldNames` (the same, and a small function whose cast its copies carry to a sibling
that reads the field by name: red when copies are not counted, the sibling then reading
`undefined`).

#### A type of one constructor with one field is its field

*Added 2026-10-02.* `Duration` is `Duration Int`, `Dict` is `Dict (Tree k v)`, `Cmd` is `Cmd (List
(Item msg))`: a type of one constructor with one field, whose object is an allocation and whose
every read is a `.a`, to carry a number of milliseconds, a tree, a list. **Under `--release`, a
type with integer tags (above) that has exactly one constructor, and that constructor exactly one
field, is represented by its field**: `Duration 5` is `5`, the pattern `(Duration n)` binds `n` to
the value itself, a `case` on it tests nothing, and the constructor used as a function is `x =>
x`. Opaque or not makes no difference; what decides is the integer-tag bit, so everything that
keeps a type's string tags keeps its object:

- **What JavaScript sees keeps its shape.** A type in the boundary — named by a live `foreign`'s
  annotation, or reached by a `Js.from`/`Js.to` instantiation, transitively — is boxed as in
  development, `{$: "Meters", a}`: a sibling reads `.$` and `.a`, and builds the object. A value
  handed through a type variable is opaque (`boundary.md` §4, *What JavaScript may read of a beni
  value*), so its type may be unboxed; JavaScript may store it, hand it back and compare it with
  `===`, none of which reads the object. A type a reflective order compares (`Hosted.key`) is in
  the boundary already.
- **A `--library` build, and a build that reaches `Debug`, unbox nothing**, as they number no tag.
- **Markup.** A selector probe (§15.5) of such a type is the value itself, which is the field the
  probe would have read; nothing else a lowering writes reads a beni constructor.
- **`==` and `compare` mean what they meant.** The derived `eq` and `compare` of such a type are
  its field's, applied to the two values: no tag, no `.a`, and the self-loop a derived function
  takes through its last field is not written (an unboxed value would step to itself; such a type —
  `Never` — has no values). `==` against a constructor (§4, *`==` against a constructor is a tag
  and field test*) is the field test alone, so `Reach` and `Lower` still agree on which sites call a
  derived `eq`. A reflective walk (`Basics.eq`) compares the field where it compared an object
  holding it, and answers the same.
- **Identity** (`CLAUDE.md` rule 8). A record holding such a value holds the field; `{ r | f = x }`
  copies it as it copies every field, so the record is a new object and each untouched field the
  same value, as before. What moves is that two constructions over one field are now one value —
  `Box xs` and `Box xs` are `===` where they were two objects — so a markup hole's reference check
  skips work it used to do, never the reverse, with one exception that costs only work: a `Float`
  field that is `NaN` is not `===` itself, where the object holding it was, so a hole holding one
  patches on every render.

Every place `Lower` writes or reads a constructor answers it (`CtorRep.unboxed`): the value, a
parameter or `case` pattern's field read (`argMember`), a test (`edgeTest`, `coreCtorTest`), a
`switch` discriminant, `==` against a constructor (`ctorTest`), the selector probe, and the
derived `eq` and `compare` (`nominalArrow`). Whole-program specialisation needed nothing: it sees
the field where it saw an object.

**Measured** (2026-10-02; `bench/size.mjs`, release brotli, against the build before): total 749 997
→ **748 721** (−1 276); 76 programs smaller, 10 larger, 363 equal. The largest:
`run/CoreSetRest` 2 726 → 2 635, `run/DictSetEquality` 3 647 → 3 589, `run/UrlParser` 3 649 → 3 597,
`run/DurationArithmetic` 488 → 454, the `browser-tea` effects page 6 222 → **6 162**, random 1 985 →
1 966, navigation 5 658 → 5 635, links 5 347 → 5 327, application 5 733 → 5 716. Larger: the
`element` page 1 199 → 1 210 (+8 raw bytes: `Cmd.items Cmd.none` is specialised to a function of
no parameter in `Cmd` before it is written into `Tea`, which then names a `Cmd` binding `Tea` does
not, and the cross-module rule of *Once the whole program is in view* keeps the call — where
`none.a` had been written in place), and nine programs by at most 14 brotli bytes, each fewer raw
bytes or within 1. A program inserting 200 000 keys into a `Dict`, looking each up, building a
`Set` of 200 001 and summing 200 000 `Duration`s (`node --single-threaded`, the whole process,
three runs each): **2 700 → 2 255 million instructions** (−16.5 %), 0.29 → 0.28 s, peak memory
233 → 225 MB. Fixtures: `emit/release/app/Unboxed` (a value, parameter patterns, a `case`, a
derived `compare`, the constructor as a function, a record and its update) — red against the
build before; `run/UnboxedTypes` (the same and a nested one, `==` against a constructor, a
polymorphic one, `Duration`, `Dict` and `Set`, in both builds); `run/UnboxedAcrossJs` (a type a
`foreign` annotation names and one used at `Js.from` keep `$` and `a` for their sibling, the
program's own handed through a type variable is unboxed and matched after); the whole `run/` and
`browser/` corpus's release pass.

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
  runtime, whose `let i` in one function keeps a `const i` in another. *Amended 2026-10-02*: "the
  file" is the tokens that are written — a unit elimination cut assigns nothing (§9, *Compact
  statements*, the last list). *Amended 2026-10-03*: **a `const` at the file's top level is never
  rewritten**, for speed — §9, *Compact statements*, the 2026-10-03 list, has the measurement.

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

### A function called once is written where it is called

*Added 2026-10-02 (research 47 §6 item 6; `plans/browser-decisions.md` R47-1).* A runtime written
in beni has a helper declaration wherever hand-written JavaScript has a loop or a sequence — `put`
and `putRun`, `run` and `runFrom`, `template` and its parser — each called from one place. **Under
`--release`, a declaration of a module called from exactly one place is written at that place, and
not written at all** (`Lower.findInlines`, `inlineExpr`, `inlineTail`, `inlineLoop`). A
development build is unchanged.

**Which declarations.** A function of the module (`Convention`'s `params` or `lambda`) that is live
(§9's *Roots*), not `pub`, not the entry, named by no dispatch answer, with no evidence, no second
body, nothing in it that may suspend, and no `?` that returns from it; whose every reference in the
module — nothing outside the module can name it — is ONE saturated call with no evidence that cannot
suspend, in another declaration that has no second body, inside a function (a top-level constant's
expression would need a called arrow to hold the statements). A declaration that refers to itself
qualifies only when every such reference is a tail self-call: it is a loop (§8).

**Which calls take it in — R47-3's rule, measured.** A body written in place has to bind every
argument that is not an atom to a `const` of its own, which costs about what dropping the call and
the declaration saves; measured on the `bench/ui` app, taking such calls in grew it by 6 brotli
bytes. So **a call is taken in only when every argument is an atom** of `Bir` — a local, a
declaration, a literal — and, in expression position, only when the body is an expression itself
(neither a `let` nor a `case`, which would need a temporary assigned in each arm). **A loop is the
exception**, at a tail call: its arguments are its variables' first values, bound either way, so it
is taken in unless a variable it reassigns would first be given a name the caller already has (a
copy, where the call is the shorter form). The decision is one predicate (`Lower.tailInline`), asked
by the tail position and by the `case` that decides whether its arms are an expression.

**How it is written.** The call's arguments are evaluated as the call evaluated them — once each, in
order, before the body: each argument that is not an atom is bound to a `const` before the next is
lowered, and that `const` is kept by the release optimiser whenever the argument may have an effect,
whether or not the body reads its parameter (a parameter nothing reads is not an argument nothing
evaluates). A parameter is then the name its argument is — the caller's own, when it is immutable,
or the `const` — and a literal is bound once. The body is then lowered where the call stood, in the caller's
function, with the callee's locals named past every local named so far in that function (their
disambiguator is offset), so two declarations' `x$1` never meet: in tail position its tail positions
return (or jump, when the caller is a loop and the body tail-calls it) for the caller; anywhere else
its value is the call's. **A loop** is written only at a tail call of a function that is not itself
a loop and cannot suspend: its carried parameters become `let`s, the others `const`s or the names
passed, then §8's `for (;;)`, whose exits return for the caller — research 47 §4.3's hand-written
`put`, statement for statement. Anywhere else — a loop called in expression position — the
declaration is written as before. **Every declaration is still lowered where it stands**, in the
emission order, and a candidate's statements are left out afterwards when its call took it in: so
every order lowering discovers — the imports, the hoisted templates, the nullary constants, and
with them the one scope's evaluation order and names — is the one a build that takes nothing in has,
and the rule can decline at any site and cost bytes, never a program. (Lowering candidates last
instead moved those orders and cost 18 brotli bytes on the `element` page for nothing taken in.) A
body holding markup is never taken in: its templates would be hoisted twice.

**What cannot change.** `language.md` §6's order is the call's: arguments before the body, each
once, and the body's `let`s where the call was. `run/InlineOnceOrder` observes that in both builds;
every `run/` and `browser/` fixture's release pass is the differential test.

**Measured** on 2026-10-02: `bench/size.mjs`'s release total 246 993 → **246 933** brotli; the
`bench/ui` app **5 032 → 5 032**, byte for byte (its beni is the TEA layer, whose helpers are called
with expressions); every empty page of `browser` and `browser-tea` unchanged (980, 993, 1 668,
5 165); research 47's empty page with the runtime module (`boundary.md` §9.2) **1 058 → 1 043**,
against the hand-written 980 — `put`, `drop` and `run` are their loops, `template`'s parser still a
function of its own (its call passes expressions). Speed was not measured again: the `bench/ui`
app's bytes did not move. Fixtures: `emit/release/core/InlineOnce` (a loop, an expression, a tail
call, and the four that are not taken in), `emit/release/split/EmptyPage`, `run/InlineOnceOrder`
(red before the argument rule above: an argument whose parameter nothing read lost its effect).

**Once the whole program is in view** (*added 2026-10-02*; the empty page's study, ledger step
18, which priced every runtime function called once at 112 brotli bytes). The rule above runs in
`Lower`, one module at a time, before whole-program specialisation: it cannot take in a `pub`
function, which another module or the markup runtime might call, nor a function whose other calls
specialisation cut, nor a call from another module. So **after the facts** (*Whole-program
specialisation*, below; `Spec.inlineOnce`) the same rule runs again over the program's `JsIr`: a
top-level `const f = (…) => …` whose whole-program name the program mentions exactly once, as the
callee of a call with as many arguments as it has parameters, that no file the pass cannot see
names (`Input.escaping`), is written at that call, and not written at all (the pass's reachability
re-walk drops the declaration). Its locals take new names in the caller, so none meets the
caller's.

- **Arguments are atoms**, R47-3's rule: a literal, or a name nothing assigns. A parameter is its
  argument wherever the body reads it — a literal longer than 5 bytes only where it is read once —
  and one the body assigns is a `let` bound to it first. An argument whose parameter nothing reads
  is not evaluated, which an atom cannot notice. **One more argument moves**: one that makes a value
  and does nothing else (an object, array or function literal of atoms — `inert`), whose parameter
  the body reads once, outside any loop and any function in it, and never assigns — it is made
  where it is read, once, as it was made once before: `Browser.program { … }` is the array it
  returns.
- **Where the call stands** decides what the body may be. In any expression, a body that is one
  `return e` is `e`. A `return f(…)` is the body, whose `return`s return for the caller. A
  `const x = f(…)` or `let x = f(…)` is the body's statements, then `x` bound to what its one
  `return`, its last statement, gives — **at a module's top level too**, which is where a function
  that returns a closure is called once: `const k = template(…)` becomes the cell `let a = null`
  beside `const k = () => …`, the cell a top-level binding of the caller. A call that is a
  statement is the body when it has no `return` but a last one, whose value is kept as a statement
  when it may do something; and, as the function's last statement, a body whose `return`s say
  nothing. Anything else keeps the call.
- **Another module's function** is taken in only when its body names nothing but its own locals,
  properties, and whole-program names a live statement of the caller's module already names — so
  the caller's module needs no import it lacks, in the one scope-hoisted file and in the multi-file
  layout alike.
- **Every table lowering handed the optimiser follows the copy**: a binding kept for its effect, a
  discarded statement, an arrow whose result nothing reads, a `let` another declaration assigns —
  each copy is listed where its original was.

Candidates are tried innermost first — one called from inside another candidate before that one is
written anywhere — so a loop reaches the `return` it can stand after before its caller becomes an
expression. And once the pass is done, a binding lowering kept for what its initialiser might do
is kept no more when the facts folded that initialiser to something that does nothing (a mount
record's `n` read as `null`), so the optimiser drops it unread. Measured (release, brotli, the whole
bundle): the empty `browser` page 657 → **615**, `Tea.sandbox` 662 → **615**, `Tea.element`
1 527 → **1 501**, with effects 5 718 → **5 651**, the `bench/ui` app 5 906 → **5 868**. Fixtures:
`emit/release/app/InlineAfter` (user code: a function called once, twice before
specialisation cut a caller; a record-building helper taken into a `let`), `emit/release/split/
EmptyPage` (`slot`, `parentOf`, `drop` and `template`), `run/InlineAfterOrder` (argument and body
order, a closure's cell, a `let` the body assigns, in both builds).

**Amended 2026-10-02: a loop whose value is bound or discarded** (`Lower.boundLoop`,
`inlineLoop`; `plans/runtime-in-beni.md`, step 4). A loop was written in place only at a tail
call, so a runtime written in beni paid a call wherever hand-written JavaScript has a loop
followed by more of the function — `reconcile`'s inner `while`s, `trimmed`'s six. A candidate loop
(`findInlines`, unchanged) is now written in place at three more positions, in any function, a
loop's body included:

- **`x = loop args`** (a `let` binding of a name): `let x;` before the loop, and each exit writes
  `x = value; break`.
- **`( a, b ) = loop args`** (a tuple pattern of names and `_`), when every exit of the loop is a
  tuple literal of that size: each exit writes the elements, in order, into the names — **no tuple
  is built**. An element bound to `_` is evaluated for its effect.
- **`_ = loop args`**, or a leaf of a `case` whose value is discarded: each exit evaluates its value
  for its effect, then `break`s.

The arguments are evaluated once each, in order, before the loop, as at a tail call; here a
carried argument that is a name is copied into the loop's `let` (the call would be no shorter).
An exit's `break` names the loop's label only when the body holds a `switch` (a bare `break` would
leave the `switch`); a `continue` never needs one, since no jump or exit is ever inside a loop the
body holds — a `Js.each` body is discarded, a bound loop's body is another function's — so a
function loop holding a loop no longer keeps its label either. **When every exit writes `x` from one
variable the loop reassigns in place**, `x` is that variable from there on: the exits' writes
become `v = v`, which the printer writes as nothing, and the binding is never declared — `k =
upTo xs 0` is `let k=0;while(k<n&&…)k++`. Not for a local a `let` function read before the binding
(it already has a name).

Three more `--release` rules of `Lower` came with it, each removing a copy the hand-written runtime
does not make:

- **A `case` whose value a `let` binds writes the binding itself** (`case_into`): `let i;
  if(…){…;i=a}else i=b` where it was a temporary and `const i=$t`. A leaf of a value `case` that
  is — under its `let`s — a `case` of its own writes the outer temporary, where it wrote one of its
  own and the leaf copied it; the same when the tree was first lowered as candidate conditional
  arms (`lowerReadyInto`).
- **A leaf `let … x = e … in x`** writes `x` as an assignment of the `case`'s temporary, which `x`
  then is (`bind_into`): `let e;if(…){e=a.m(…);if(…)a.p(e,…)}else e=…`.
- **A binding of a name nothing reassigns is that name** (`y = Js.to x` is `x`), as a parameter
  passed a name is in `enterInline`; not a `Js.Ref` written as a `let`, not in a suspendable body,
  not a local read before its binding.

Fixtures: `emit/release/core/BoundLoops` (a name a loop's variable becomes, a `for` head, a tuple of
two variables, exits that write a `let`, a loop in a loop) — red against the compiler before the
change, which keeps each call; `run/BoundLoops` (the same shapes and an exit inside a `switch`, an
argument with an effect evaluated once, in both builds); every `browser/` page's release pass. The
measurements are step 4's (`plans/runtime-in-beni.md`).

**Amended 2026-10-02: the calls counted are the reachable program's** (`Lower.findInlines`). The
rule counted every reference in the module, a declaration reachability removed (§9's *Roots*)
included, so a helper whose other callers no build of this program writes was still "called
twice": the fiber kernel's run loop paid a call to `pushBack` in every build because `begin`, a
combinator's, called it too, and `core/Task.beni` carried `takeOn`, a copy for `begin`, to keep the
loop's call the only one. **A reference counts only when it stands in a declaration whose direct
or suspendable body survives.** One exception keeps a decision whole-program specialisation makes
better: a function that is no loop, whose other calls were removed, is **not** written into a
`pub` function. A `pub` function is the one *Once the whole program is in view* writes into
another module's caller, which it does only when the body names nothing of its own module that the
caller's module does not name already — so `List.get` holding `unsafeGet`'s body stayed a call in
`run/BoundLoops` and `run/SpecializeMaybe`, and the `Just` it returns was built on every call,
where before it was a test and a read (*Slice 9*). A loop is not held back: no later pass writes a
loop in place. And `core/List`'s core-private values (`unsafeGet`, `view`, `base`, `offset`,
`close`; §4) are never candidates: the emitter calls them from a list pattern or a scalar view in
any module, a call no `Bir` reference stands for, so the one reference counted is never the only
one — they had kept other callers until this amendment, and `run/TailCallEvidence` and
`run/QuestionPositions` named a `base` that was no longer written when they lost them.

`takeOn` stays (`core/Task.beni`): in a build that reaches no combinator the two spellings now
compile to the same bytes, but in one that does — `begin` and the run loop both live — one shared
`pushBack` would be a function called from both, and the copy keeps each written in place.
Measured on `bench/fiber/Bench.beni` (`--library --release`, instructions per operation,
`node --single-threaded`, three rounds): the shared function was 5 brotli bytes smaller and
`yieldNow` 973 → 978, `forEach` over 16 1 033 → 1 118, `race` 13 704 → 13 739 — never better —
so the copy keeps its place.

Measured (`bench/size.mjs`, release brotli, the whole bundle): total 747 226 → **747 011**; 39
programs smaller, 13 larger, 395 equal, no program's raw bytes larger — every larger brotli figure
is a renaming of equal or fewer bytes (`run/VirtualClockInherited` +31 at equal raw bytes, the
most). The largest wins are the fiber kernel's helpers, called once in a program that reaches no
combinator: `run/ScopeDeferLifo` 4 241 → 4 219, `run/MainParkedForever` 3 194 → 3 176,
`run/VirtualClockNow` 3 712 → 3 694, and the `browser-tea` navigation page 5 841 → 5 823. The
delegated listener of the `browser` runtime now holds its dispatch loop in place
(`emit/release/split/HolesPage` 4 059 → 4 032 raw). Without the exception `run/BoundLoops` grew
1 240 → 1 262 and `run/SpecializeMaybe` 1 684 → 1 696, each building a `Just` per call. Fixtures: `emit/release/app/InlineReachable` (a loop
whose other caller is unreachable written in place, a loop with two live callers kept, `List.get`
not grown) — red against the compiler before the change; `run/InlineReachable` (the loop's
arguments evaluated once, in order, in both builds).

### Whole-program specialisation

*Added 2026-10-02 (research 47 §6 item 8), specified ahead of the build; what is built, and where
the build departs from the text, is the *As built* note at the end of this section. Since
2026-10-02 its analysis is being rebuilt as one combined fixpoint, slice by slice: *The combined
solver*, after this section, is normative for that.* A runtime written in beni is compiled WITH the program (`boundary.md` §9.2's runtime module),
so the compiler sees every call of every runtime function the page makes — which no copied JavaScript
file allows (*Hand-written JavaScript under `--release`* cuts whole exports, never a branch). The
empty page never passes `template` a flag, never mounts a hosted program, never holds a list; this
is how it stops paying for them. Research 47 §5.1's `v3` hand-applied it: the empty page **975 →
772** brotli against the hand-written 980, the only step that makes a beni runtime *smaller* than
the one it replaces (R47-3). The page with the runtime module is at 1 043 today (*A function called
once …*, above); `emit/release/split/EmptyPage` is the golden the slices below move.

**Where.** `--release` application builds, after every module is lowered and before any is printed,
over the whole program's `JsIr` at once — the one scope-hoisted file's pieces, or the multi-file
layout's modules, whose top-level names are whole-program names already (§9 item 2). A `--library`
build does not specialise: its exports' callers are outside it. *(Amended 2026-10-02: a `--library`
build specialises too, over its whole output, with every name a root-package module exports in
`Input.escaping` — §2's surface, `Reach`'s roots for a library — so each is called by code the pass
cannot see: its parameters are ⊤, it is never dropped, and what it returns escapes. Core and the
platform behind the library are specialised to what the library's own code makes of them, as an
application's are. Without it a library build of core written in beni ran as written, where the
hand-written siblings it replaced had been specialised by hand: `bench/schema-library/run.mjs`'s
`--library` build of the schema engine was 5–38 % slower than the JavaScript engine
(`plans/core-in-beni.md`). The `emit/release/` corpus is built `--library`; four of its fixtures
were given inputs a library's caller supplies, so that what each pins — a call binding not folded, a
chain of `if`s, a conditional that is an `if`, a function not written in — is not folded first.)*
A new pass, `src/js/Spec.zig`, run
on the calling thread (the facts are whole-program; the per-module walks that feed them run on the
workers and are merged in module order), producing a plan the printer spends as it spends `Opt`'s —
node replacements, dropped statements, dropped parameters and arguments, dropped properties —
without mutating the IR.

**The facts**, each a lattice value computed to a fixpoint:

1. **Constant arguments.** Per parameter of every top-level function: the one literal (a number, a
   string, `true`, `false`, `null`, `undefined`) every call passes it, or ⊤. The call sites are
   every `call` whose callee is the function's whole-program name; a function whose name appears
   anywhere else — passed as a value, stored, exported, imported by a hand-written file through
   `beni:<Module>`, called by the entry file, handed to a lowering's `cx.call` — has every parameter
   ⊤. An argument that is itself a parameter of a caller takes that parameter's value, so the fact
   propagates down call chains (`mount` → `template`'s `flags`).
2. **Constant variables.** Per module-level or local `let` (a `Js.Ref` written as a `let`, §4): the
   initial value when no reachable statement assigns it, else ⊤. `phase` on the empty page is
   `null` for good, because the one function that assigns it (`setPhase`) is reached only from the
   hosted mount, which fact 3 removes.
3. **Allocation sites.** A flow-insensitive, allocation-site points-to analysis (Andersen-style,
   field-sensitive by property name): an abstract object per object and array literal site, plus
   **⊤-object**, which stands for anything the program did not allocate — a host object
   (`globalThis`, the DOM, `Js.global`), a value a hand-written file returns or passes in, a
   parameter of a function with ⊤ parameters. Values flow through bindings, assignments, arguments
   to parameters, returns to call results, and property writes and reads (`o.p = v` adds `v` to
   `p` of every object `o` may be; `o.p` reads the union). An object that reaches a hand-written
   file, a host call, a computed read or write (`o[k]` with `k` not a literal), a spread or
   `Js.to`'s unchecked side **escapes**: every property of it is read, and may be written with ⊤.
   Two facts come out per non-escaped abstract object `O` and property name `p`:
   - **`p` is never written on `O`**: `O`'s literal has no key `p` and no reachable write reaches it
     — so a read of `p` on a value that may only be such objects is `undefined` (`m.h === undefined`
     on a program description built by `Browser.program`, which has no `h`);
   - **`p` is never read on `O`**: no reachable read of `p` reaches it — so the key goes from the
     literal and a write of `p` to such values goes (its value still evaluated when it may have an
     effect): a slot's `u`, `x`, `y`, `z`, `d` on a page with no list.

**What is rewritten, from the facts.**

- A parameter with a constant is replaced by the constant in its body, and **dropped** from the
  function's parameter list and from every call — the call sites are all known, by fact 1's
  definition. A trailing run first, then any position (arguments are still evaluated, in order, when
  they may have an effect: a literal never does).
- **Constant folding** over what those replacements produce, exact or nothing (§4, *Arithmetic is
  an operator*): arithmetic, bitwise, comparison and `===`/`!==` on literals, `!`, `&&`/`||` with a
  literal left side, `c ? a : b` and `if (c)` with a literal `c`; a folded `if` keeps one arm, a
  folded conditional one branch. Nothing is folded that could throw or that reads a property of ⊤.
- A read fact 3 answers `undefined` is `undefined`, and folds on.
- A key fact 3 says is never read goes from its literal, and so does a write of it.
- **Then reachability again, over the `JsIr`**: a top-level function none of whose references
  survives the folding (`setPhase`, the hosted half of `mount`, a list helper only a dead branch
  called) is not printed, and a hand-written unit only it imported is cut with it (Minify's `cut`,
  re-run with the smaller import set). This walk iterates with the facts until nothing changes: a
  dropped function removes call sites, which can make a parameter constant.

**What must not change**: behaviour, exactly (`language.md` §6, and R47-3's rule is about bytes, not
meaning). Every fact is a may-analysis whose unknowns are ⊤, and every rewrite is licensed by a fact
alone, so a program the analysis cannot see through is printed as it is today. **Field identity
(CLAUDE.md rule 8) is untouched**: no object is copied, merged or split; a dropped key is one no
reachable code can observe. Determinism: the fixpoint visits nodes in module order and IR order,
and its answer is a function of the IR (CLAUDE.md rule 5).

**Build order**, each slice with its golden moved and `bench/ui` held to R47-3: (1) facts 1 and 2
with folding and parameter dropping — `template`'s flags, `phase` (research 47 §5.1 estimates
roughly half of the 203 bytes); (2) the `JsIr` reachability re-walk; (3) fact 3 and its two
rewrites — the hosted mount, the list half of `first`/`last`, a slot's fields. Fixtures: an
`emit/release/split/` golden per fact, a `run/` pair per fact where a host object or a hand-written
file must defeat it (a DOM node's own `h`, an object passed to a sibling), and every `run/` and
`browser/` program's release pass as the differential.

**As built — slice 1** (2026-10-02, `src/js/Spec.zig`, called from `Emit.specialise`). Facts 1 and
2, folding and parameter dropping, for every `--release` application with an entry, user code and
`core/` included. Where it departs from the text above:

- **It rewrites the lowered `JsIr` in place instead of handing the printer a plan.** Folding makes
  literals no module's IR holds and parameter lists shorter than any node's, and both printers
  (the recursive and the work-stack one) would each have to spend every kind of edit. A patch keeps
  every node index — a node's tag and operands change, and new argument lists, parameter lists and
  statement lists are appended to `extra` — so the tables lowering hands the optimiser
  (`effect_keep`, `pure_discards`, `unobserved`, `mutable`) stay valid, and `Opt` then plans over
  the specialised program as over any other. `Opt` and `Rename.collectGlobals` therefore moved out
  of the lowering task into a task of their own (`Task.optimise`) that runs after the pass. Nothing
  reads the unspecialised IR.
- **The iteration is optimistic** (SCCP's): a parameter no call has reached is ⊥, an expression
  reading a ⊥ is ⊥, and a round's facts are swept to their fixpoint (at most 24 sweeps; a round
  that does not converge rewrites nothing, since stopping short would be unsound). A ⊥ at the
  fixpoint is a function no live code calls, and nothing is rewritten from it. Rounds of
  facts-then-rewrite repeat, at most 4, while a round changes anything: round 2 is where a
  module-level constant folded in round 1 (`c = b * 3` to `21`) reaches its readers.
- **A literal replaces a name only where it cannot grow the file**: when it prints in at most 5
  bytes (`0`, `true`, `null`, `"ab"`) or the name is read once. A parameter is dropped exactly when
  its every read is replaced, so a long string passed to a parameter read twice keeps the
  parameter (its value still folds the expressions it decides).
- **A module-level constant's value is its initialiser only when that is a literal node**; a local
  `let` or `const` takes its initialiser's folded value. A constant is read before its declaration
  only in a program that would throw on the read (a dead zone), so substituting it cannot change a
  program that runs.
- **A folded `if` is spliced into its list** only when no name its arm declares is declared twice
  in the declaration (the compiler's positional names `$in$<i>`, `$m$k` can repeat); otherwise the
  arm stays a block. A negative folded number prints bracketed where a unary would (`(-3)**2`).
- *Amended 2026-10-02*: **a statement that is a literal alone is not written.** It is what is
  left when a function written where it is called (*A function called once …*) ends in a value
  that folds to a literal — `return c ? f() : null` with `c` folded false — which `if (x) null;`
  printed; it does nothing. Fixture: `emit/release/app/SpecLiteralStatement`.

Measured: `emit/release/split/EmptyPage` **1 043 → 957** brotli (the hand-written runtime's page
is 980) — `template`'s flags and html folded into `parse`, a slot's constant marker and context;
the `bench/ui` app 6 289 → 6 269; `bench/size.mjs`'s release total 346 292 → 344 386.
Fixtures: `emit/release/app/SpecConstants` (user code: a loop's constant bound, an identity left
by a constant factor, a whole `if` folded by a constant argument and a constant module value),
`run/SpecializeArguments` (two different constants, a function also passed as a value, a
parameter a loop reassigns, `&&`/`||` decided by a constant with a logging right side, `(-3)^2`, a
quoted string), `external_platform_test`'s one file.

**As built — slice 2** (2026-10-02, `Spec.prune`). After each round's rewrite, reachability again,
over the `JsIr` of every module: the roots are every top-level statement but a declaration whose
initialiser is *inert* — a function, a literal, a name, or an object, array or template of those;
a call, a property read (a getter), an operator (`valueOf`) or a spread may do something, and such
a declaration stays whether or not it is read, as `Reach` keeps it — and `Input.escaping`. A
declaration no root reaches is not written; an `import` specifier whose name nothing live reads
goes, and so does an `export` of a declaration that went. The `import` statement itself stays,
empty when every specifier went, because it is an edge of the evaluation order `planHoist` reads.
Cutting the hand-written units needs nothing new: `planHoist` builds each file's `keep` from the
specifiers that are left, and `Minify` cuts to it. The next round's facts then see fewer calls and
assignments. Measured: the `bench/ui` app 6 269 → 6 237, `bench/size.mjs`'s release total 344 386 → 337 506; `EmptyPage` unchanged (nothing on it is
only reached from a folded branch until slice 3). Fixture: `emit/release/app/SpecConstants`'s
`limit` and `String.toUpper`; `emit/release/app/HoistOrder`'s `Mid` now reads `String.length` so
that its three values are not folded away.

**As built — slice 3** (2026-10-02, `Spec.Pts`). Fact 3 as specified, with these choices:

- **A computed read or write does not escape its object**; it is field-insensitive on it: `o[k]`
  reads every property of every object `o` may be (it may return any of their values), and
  `o[k] = v` may write any property with `v` — so no key of such an object is dropped and no read
  of it folds. The text above made it an escape, which would have lost the program description an
  index loop walks (`p(v)`'s `a[b]`) for no reason: nothing unseen reads it. A spread `{...x}`
  reads all of `x` and copies what each of its properties may hold into the new object's.
- **The iteration is optimistic where nothing can be unsound**: a call, read or write through a
  value that holds nothing yet does nothing (at the fixpoint such a value is never an object),
  while a name no module declares — a hand-written import — is `top` from the start. A var whose
  set passes 48 objects is `top`, its objects escaped: the sets stay small. At most 64 sweeps; a
  round that does not converge uses no fact 3.
- **A read folds to `undefined` only through a name or properties of one** (whose evaluation does
  nothing the fold could lose), on objects that are all object literals of the program, none
  escaped, none written under an unknown key, and never for a name `Object.prototype` has
  (`prototype_names`). The fold is fact 2's literal, so it folds on (`m.h === undefined`).
- **A key goes from its literal, and a write of it from the program, only when its value is
  inert** (`inert`); a write whose value may do something keeps the value as a statement.
- **Rounds.** Facts are recomputed each round; a round is repeated only when the program shrank
  in a way the facts can see — a branch, a read or a parameter gone, or `prune` dropping a
  declaration — so a program with nothing to specialise pays one round.
  *Amended 2026-10-02: two more reasons, so the result does not depend on module order.* A
  rewrite patches modules in module order, and two of its decisions read facts the same rewrite
  then changes. **A module-level constant whose initialiser has just become a literal** reaches
  its readers in later statements (they are walked again before they are patched) but not in
  earlier ones, so another round follows when an earlier statement read it. **A read refused by
  the substitution rule's count** — the reads `reads` counted before the rewrite — repeats the
  round when the folds of the expressions around its other reads (`x + 1` written `-2147483647`)
  took enough of them for the rule to allow it. Without these, whether the fold came before the
  refusal decided whether `const c=-2147483648` stayed: `run/Int32Bits` was 782 bytes with the
  project after `core/` and 778 before it, until module numbering stopped depending on where the
  project lives. `build_test`'s *a release build writes a constant where it is read whichever
  module comes first* builds one program with the constant's module named before and after
  `Main`.

Measured: `EmptyPage` 856 → **838** brotli — a slot is `{cx:null,i:null,m:null,p:a}`, its list
fields gone. The program description the runtime reads `h` of is `Browser.program`'s, which is
hand-written on `beni-runtime`, so `m.h === undefined` does not fold on that page (it would with
`program` written in beni). Fixtures: `emit/release/app/SpecFields` (a user record's unread
fields), `run/SpecializeFields` (the same, beside a record `Debug.toString` reads whole, which keeps
every field), `emit/release/split/EmptyPage`.

**The entry's call is a call** (*added 2026-10-02*, `plans/runtime-in-beni.md` step 3). The entry
file is the compiler's own output, and when the runtime module supplies `run` what it does is
known: `run(main)`, once, its result unread. So `run` and `main` no longer escape (`Input.escaping`
lists what the entry reads it cannot say more about — `start`, `flush`, and what the markup runtime
imports); the pass is handed the call instead (`Input.entry`: the callee's and the arguments'
whole-program names), and each fact reads it as the call it is:

- **fact 3** joins `main`'s objects into `run`'s parameter, exactly as a `call` node whose callee is
  `run` and whose argument is the name `main` would — through a callee that is not the program's
  own function, the argument escapes, as at any unknown call;
- **fact 1** keeps both names' parameters ⊤, as before (`main` is a value, never a literal, so the
  call could give `run`'s parameter nothing better), and **`prune`** keeps both as roots.

So a program description made in beni reaches `run` with its fields known: on a page whose `main`
is `Browser.program { … }`, `m.h === undefined` folds to `true`, the hosted branch of `run` goes
and with it the after-render phase (`setPhase`, and `phase` constant `null`). Nothing else changes:
a description made by a hand-written file is ⊤ as before. Fixture: `emit/release/split/EmptyPage`
(no `h`, no phase), and every `browser/` page's release pass as the differential.

**Slice 4 — three more facts** (*added 2026-10-02*; the empty page's study, `bench/minify/
empty-page/`, ledger steps 10, 13 and 15, which priced them at about 190 brotli bytes together on
the hand-written runtime). Each is a small extension of fact 3's allocation sites, and each is
spent by the rewrites slices 1–3 already have.

4. **A field whose every write is one literal.** Per abstract object and property: the join, in
   facts 1–2's lattice, of every value written to it — the object literal's own key, and every
   `o.p = v` whose `o` may be it. A read `x.p` through a name or properties of one (a chain: its
   evaluation does nothing the fold could lose) is that literal when every object `x` may be is a
   program object literal that nothing unseen holds, none written under an unknown key or copied
   from by a spread, and **each one's literal has the key** — the property exists from the moment
   the object does, so a flow-insensitive join is its value at every read. The literal is written
   in place of the read only when it prints in at most 5 bytes, and never as the object of another
   read (`null.parentNode` would say the same thing and nothing shorter); otherwise its value
   still folds what it decides. User code: a record field every construction and every update
   writes the same literal (a configuration flag) folds the branches it decides.
5. **A field that is never `null`.** The lattice gains one value between a literal and ⊤,
   *nonnull*: known to be neither `null` nor `undefined`. It is what an object, array, function,
   template or `new` makes, what any operator but `&&`/`||` gives, a non-nullish literal, the join
   of two such, a name bound to one, a parameter every call passes one, and — joined per property
   as fact 4 joins literals — a read of a field every write gives one. A call's value is the join
   of what the functions it may call return (every `return`, and `undefined` when the body may run
   off its end). **One host fact**: a call of `cloneNode`, `importNode`, `createElement`,
   `createElementNS`, `createTextNode`, `createComment` or `createDocumentFragment` on a value the
   program did not allocate returns a node or throws — the DOM's contract for those seven, which a
   platform's hand-written file (trusted, `boundary.md` §4) is taken to honour. Spent in one place:
   `c ? t : f` whose test compares a read `x.p` with `null` strictly (`===`/`!==`), where `x.p` is
   nonnull, is the branch the comparison takes — when every value `x` may have is an object of the
   program, or when that branch is itself the read `x.p`: then a `null` or primitive `x` behaves as
   before, since the read that throws or gives `undefined` is still the first thing evaluated.
   `first i = if isNull i.s then head i.q else i.s` is `(b)=>b.s` on a page whose instances all
   hold nodes, and `head` goes with its last call.
6. **An object allocated once.** An object literal evaluated at most once — at a module's top
   level, outside any function and any loop — is ONE object. `a === b` (and `!==`) of two chains
   that each may be only that object is `true`; of two chains whose sets of objects are disjoint,
   neither of which may be a host value and at most one a primitive, it is `false`. Both chains
   must read nothing that may throw: every object a chain reads a property of may only be a program
   object literal. So `patch i b` returns at `b === i.b` on a page whose `view` returns one
   module-level block, and its other two arms go.

**What fact 3 learns for these** (`Spec.Pts`). A primitive value is `null`, `undefined` or
`prim` (any other); reading a property of a `null` or `undefined` value throws, so it contributes
nothing to what the read may be — a `head (i.q)` whose `q` is always `null` no longer makes every
read in `head` ⊤. What may be `undefined` is tracked, not assumed away: a read of a key an object's
literal lacks, an index, a missing argument, a `return` with no value and a function that may run
off its end. A site knows whether it is made once (fact 6). And **a guard narrows**: in the branch
of `if (X === null)` (or `!==`, or `==`, either way round) where the chain `X` is not `null` (nor
`undefined`, for `==`), a read of the same chain made before anything that may change what it
reads — a call, a `new`, an assignment, a declaration, a loop's next turn, a read through a host
value — is not `null`: `patch (s.i) b` in `childHtml`'s `else` passes an instance, not the slot's
first `null`. A function in the branch runs later, and sees no guard.

**And two small rewrites the facts feed.** A template whose every substitution is a literal is the
string it makes — when that prints no longer, and a number only when its spelling is how
JavaScript writes it back — so a mount record's `n`, always `null`, makes the error message
`"no element has the id \"null\" …"`. And *Compact statements*' flag test (item 3) counts a
comparison's uses over the nodes the module still writes: a conditional lowering wrote as an `if`
no longer makes `fire`'s `(flags & 1) !== 0` look shared. *Amended 2026-10-02 (ledger step 25)*: and
`x.insertBefore(n, r)` whose reference `r` is `null` — a literal, or a name the facts make one — on
a host value `x`, one the program did not allocate, is `x.appendChild(n)` (`Spec.appendChild`): the
DOM defines appending as inserting before `null`, both return `n`, and `r` cannot notice it is not
evaluated. It rests on fact 5's host contract. It fires where fact 1 makes a reference `null` for
good — `insertText`'s on a page whose text holes all end their element (`dom/Keyed`: `(a,b)=>
a.appendChild(document.createTextNode(b))`) — but not yet in `put`, whose reference is `null` from
`place` and a node from `swap` until fact 6 takes `swap` off the page. Fixture:
`emit/release/app/SpecNodes`; the `browser/` pages' release pass is the differential.

Every fold stays exact or is not made: a read replaced by a literal is one whose object cannot be
`null`, `undefined` or a primitive; a comparison replaced by its value reads nothing that could
throw, or its taken branch reads the same thing first.

*As built* (2026-10-02, `Spec.memberValue`, `propValue`, `callValue`, `identity`,
`nullTestTaken`, `templateValue`; `Pts.safeChain`, `Pts.narrowed`). Fixtures:
`emit/release/app/SpecFacts` (user code: `verbose` and `scale`, which every `Settings` writes
`False` and `3`, fold, and their keys go), `emit/release/app/SpecNodes` (a project with a platform
module: `first`/`last` over instances a host clone fills, the module's one block compared with
itself and a fresh one with it), `run/SpecializeFacts` (each beside what must defeat it —
constructions that disagree, a record update, a record `Debug.toString` reads, a field one
construction leaves `null`, a function called with both blocks, a key no literal has),
`emit/release/app/SpecFields` (`p.x + p.y` is `9`), `emit/release/split/EmptyPage`. The corpus
harness builds an `emit/` project with a `platform/` directory for that platform, as `run/` does.

Measured (release, brotli, the whole bundle, on the one-line output of *Compact statements*' last
list, with `Browser.program` in beni and the entry's call read as one): the empty `browser` page
776 → **657** — the mount record's `n` (fact 4: the body, the messages as strings), a slot's `cx`
and the instance's ends (fact 5: `first` is `(a)=>a.s`, `head`, `tail` and `q` go); `Tea.sandbox`
781 → **662**, `Tea.element` 1 552 → **1 527**, with effects 5 758 → **5 718**, the `bench/ui`
app 5 941 → **5 906**. **Fact 6 does not fire on the page yet**: `patch`'s `b === i.b` compares the
module's one block with an instance's `b`, which `unit` writes right after the kind makes the
instance — but a flow-insensitive analysis sees the instance before that write, where `b` is still
`undefined`.

**Amended 2026-10-02: fact 5 past a guard** (`Spec.guardNames`; `plans/runtime-in-beni.md`, *The
empty page's last items*). Fact 3's guard narrows what an object chain *points to* inside a
branch; fact 5 learns the same of a local's *value* after one. A statement `if (T) …` whose first
arm cannot complete normally — its last statement a `throw`, a `return`, a `break` or a `continue`
— is followed by the rest of its list only when `T` was false. Then every disjunct of `T`'s
top-level `||` chain was evaluated, was false, and did not throw, so a local `X` is *nonnull* for
the rest of that list (and inside what the rest makes, closures included) when some disjunct is
`X == null`, or when some disjunct reads a property of `X` (`X.p`, `X[k]`) where it is evaluated
whenever the disjunct is — not in the right side of an `&&` or `||`, not in a conditional's arms,
not in a function. `X === null` alone proves nothing: `X` may be `undefined`. The local must be
declared once and assigned nowhere in its declaration, so the value the guard saw is the one every
later read sees, and a `function` declared in the rest sees no guard, since it is hoisted above
it. What it buys is what fact 5 already spends: a parameter every call passes such a local is
nonnull (fact 1), and so is a field every write gives it (fact 4's join). On the empty page,
`run`'s `if (d === null || d.$$root !== undefined) throw …` makes the body it hands `mount`
nonnull, so the slot's `p` is: `parentOf`'s `d.p === null ? d.m.parentNode : d.p` is `d.p`, and the
slot's `m`, read by nothing now, goes from its literal. Measured (release, brotli, the whole
bundle): the empty `browser` page and `Tea.sandbox` 480 → **466**, `Tea.element` 1 241 → 1 232,
with effects 5 325 → 5 316, `random` 1 992 → 1 997 (raw −33); 21 of the 52 `browser/` pages
smaller, none larger (−280 in all); the `bench/ui` app and every `run/` program byte-identical.
Fixtures: `emit/release/app/SpecGuards`, `run/SpecializeGuards` (a guard that refuses only
`undefined`, given `null`, keeps the fallback), `emit/release/split/EmptyPage`.

**Amended 2026-10-03: definite initialisation** (`Pts.definiteInit`; the empty page's study,
ledger step 13). Fact 3 learns, per object literal, the keys it lacks that no code can read before
they are written — so a read of one is never the `undefined` of a key not yet there, exactly as
for a key the literal has (*What fact 3 learns*, above). A key `k` is such a key of literal `O`
when:

- `O` is the value of a `return` of a function `F` as it is made (`return {…}`), so the call is
  the only way `O` leaves `F`;
- `F` does not escape and nothing but the program's calls calls it — not the entry file, not a
  `new` — and it has at least one call;
- **every** call that may call `F` (by fact 3's call graph) is the initialiser of a `const x` or
  `let x`, and the statements right after that binding begin with a run of `x.p = v`, one of which
  writes `k`, each `v` before it — and `v` itself — evaluated without running code, throwing or
  reading `x`: a literal, a name other than `x`, or a property read through objects that are all
  the program's own, none escaped (no getter) and none `null` or `undefined`.

Between the call and the write no code runs and nothing but `x` holds the new object, so no read
can see `k` missing. What a site may hold does not depend on these keys — only whether a read may
be `undefined` does — so the call graph that found them is the one they leave: the analysis is run
again with them, up to three times while it finds more. Nothing is rewritten that facts 3–6 did
not already rewrite: they now fire where an object is finished by its caller. On the empty page
`unit`'s `i.t = b.t; i.b = b` makes `t` and `b` keys of the instance the kind's `m` returns, so
fact 6 decides `patch`'s `b === i.b` (`true`): `patch` is `(a)=>a`, its two other arms go, and
with them the kind's `p`; `unit`'s two writes, read by nothing now, go too, the read `b.t` with
them — **a write fact 3 drops keeps its value as a statement only when evaluating it may do
something**, and a read through program objects (`Pts.safeChain`) does nothing. `swap` and `drop`
stay: `place`'s `else` is reached only from a branch that tested `s.i` was `null`, which no fact
sees through a call. Measured (release, brotli, the whole bundle): the empty `browser` page and
`Tea.sandbox` **605 → 557**; `Tea.element`, effects, the `bench/ui` app and every `run/` program
byte-identical. Fixtures: `emit/release/app/SpecInit` (a kind's instance finished by `unit`, and a
literal one of whose two calls writes nothing), `run/SpecializeInit` (the same, and a write whose
value reads the key it writes through a call — red when a call counts as harmless),
`emit/release/split/EmptyPage`.

**Slice 6 — a declaration's object as a constant** (*added 2026-10-03*; the empty page's study,
ledger step 20, *constant propagation through non-escaping literals*). Facts 1, 2 and 4 joined
only literals; a field that always holds `view`, a parameter every call passes the module's one
block, were ⊤ or *nonnull*. The lattice gains a constant kind, **`name`**: the object or function
a top-level declaration makes — a `function`, or a `const` whose initialiser is an arrow, an object
or an array literal, which nothing assigns and which is declared once. A read of such a name is
that constant; two different declarations make two different objects, so `===` of two names is
decided, and a name is never `null`, a primitive or falsy. It flows as the literals do: a
parameter every call passes it (fact 1), a `const` or `let` it initialises (fact 2), a field every
write gives it (fact 4, with fact 4's conditions: read through a chain of program objects that
nothing unseen holds, the key present from the start). And it is spent as they are: the read, the
parameter or the field is written as the name. **Written where the module has it**: a module
names another's declaration only through an `import`, so the name is written only in a module
that already mentions it — or, when the build is one scope-hoisted file (*One scope-hoisted file
under `--release`*), anywhere, every top-level name being one binding of the one scope (Emit asks
whether it will be before specialising; specialisation only shrinks what the hand-written files
must keep, so the answer cannot change). A read `o.f(x)` written `f(x)` loses its receiver, which
nothing emitted reads: no function of the program uses `this`. Measured (release, brotli, the
whole bundle): the empty `browser` page and `Tea.sandbox` 557 → **550** (`a.view(d)` is the
page's `view` called by name, the kind's `m` called through the kind's name), `Tea.element`
1 261 → 1 253, with effects 5 412 → 5 405, the `bench/ui` app 5 723 → 5 700; `bench/size.mjs`'s
release total over `run/` −911 (`WideRecordDerivedEq` −541: its evidence records' fields are
named functions). Fixtures: `emit/release/app/SpecScalars` (`run`'s `shape.measure 3`),
`run/SpecializeScalars` (a field every construction gives one function, and one two give two),
`emit/release/app/OneLine`, `emit/release/split/EmptyPage`.

**Slice 7 — scalar replacement** (*added 2026-10-03*; ledger step 19). A local `const x = {…}` (or
a `let` nothing reassigns) of an object literal of plain keys — no spread, no computed key — whose
every mention in its top-level declaration is `x.k`, read or written by an assignment, for a key
`k` of its literal, and which that declaration declares once, is never made: each key is a
binding, `const` (or `let` when a write reaches it) in the literal's order, so every value is
evaluated once, where and in the order the literal evaluated it, and `x.k` is the binding. A key
never written whose value is an atom — a literal of at most 5 bytes or read once, or a name
nothing assigns and the declaration declares once — is that atom where it is read; a key nothing
reads whose value does nothing goes. Nothing but those reads and writes can see the object, so
nothing can tell; a closure that reads `x.k` reads the binding, which it shares with the function
as it shared the object. A binding lowering kept for its initialiser's effect (`effect_keep`) keeps
each key's binding whose value may have one. It runs after the facts and *A function called once*,
which is where most such objects appear: a record a helper built, now in its caller's `let`.
Measured: `run/` programs' release brotli −185 more in all; every page and the app unchanged (their
objects reach a call). Fixtures: `emit/release/app/SpecScalars` (`area`'s record, and `kept`'s,
passed to a function called twice, made), `run/SpecializeScalars` (a field a closure reads later;
in a loop, a record whose field is the loop's variable, read by closures after the loop — each
sees its turn's value, which a substitution of the reassigned variable would lose),
`emit/release/app/InlineAfter`, `emit/release/app/SpecFields`.

**Slice 8 — a small function, wherever it is called** (*added 2026-10-03*; ledger steps 12 and 17,
`plans/runtime-in-beni.md`'s *Append against Solid 1*). *A function called once* takes a body in
at one call; a function called from many places paid a call at each, an identity included
(`patch` once definite initialisation decides it, `update = λ_ m -> m`, `Html.map`'s tagger
`identity`). Under `--release`, after the facts:

- **Which functions.** A function whose body is one `return e`, where `e` holds no function and no
  `yield`, names nothing but its parameters and whole-program names (not itself), and declares no
  parameter twice: a top-level `const f = (…) => e` nothing assigns, or **the one function a call
  reaches through a property** — `kind.m(…)`, `program.update(m, s)` — when fact 3 says the callee
  may be that one function only, and reading it does nothing (`Pts.safeChain`: no getter, no
  throw). Program functions read no `this`, so the receiver is not missed.
- **Which calls.** Each argument is an *atom* — a literal (of at most 5 bytes, or read once) or a
  name nothing assigns (`atomArgument`: such a name is the same value wherever the body reads it,
  and the body is written where the call was, in the same scope) — or an argument nothing reads
  that does nothing, or **one** argument read exactly once by `e` whose read is the first thing
  `e` evaluates that could do anything, and is evaluated whenever `e` is (`firstUse`: before it
  only names, literals and `===`; never in a branch of `?:`, `&&` or `||`, nor in a function); then
  every other argument must be a name or a literal. So each argument is evaluated once, and in the
  order it was: what an atom's evaluation could not tell moved, and the one argument that does
  something stays first.
- **The size model.** The call is replaced only when `e`, its parameters replaced, prints in no
  more bytes than the call by an estimate (short names one byte, a property its name's length,
  operators their text, brackets and commas) — an identity, a function returning a name, a wrapper
  of another call. A function every call of which is replaced is then unreferenced and goes.

The facts are then asked again (`Spec.grow` sizes their tables to the copied nodes): a constant
now passed, a field of a literal now read, folds — `scale 1 n` written in is `n`, `measure 3` is
`10`. With them, **`x.p = x.p`** on program objects — an identity written in place, `a.i =
patch(a.i, b)` — goes (no getter, no setter, no throw: `safeChain`). The passes — small
functions, functions called once, scalar replacement, then the facts — repeat at most three times
while one finds something. A name a copied body adds to a module is a property name the session's
pool already numbered (`Pts.propId` finds it in the module it came from).

*Amended 2026-10-03.* Once the passes are done, **`x = x`** — a name read and written back, the
model the render loop's `update` leaves as `d = d` — goes from every list (the printer wrote it
as nothing, but it still counted as a use and an assignment, so the binding it named stayed); and
a binding lowering kept for its initialiser, whose initialiser is a read through program objects
(`safeChain`: no getter, no throw), is kept no more, as one the facts folded to an atom is. The
empty page's model, `let e=a.init`, nothing reading it now, goes: 496 → **493**. Neither runs
inside the passes, which would ask the facts again of a program that only lost an assignment.

Measured (release, brotli, the whole bundle): the empty `browser` page and `Tea.sandbox` 550 →
**503** — `first`, `last`, `patch`'s identity and `view`'s block written where they were called,
the program's `update` (the identity of its model) gone from the render loop; `Tea.element`
1 253 → 1 226, with effects 5 405 → 5 384; the `bench/ui` app 5 700 → 5 701 (raw −18); `run/`
programs −1 981 in all (`AliasChainThroughLet`, a chain of 129 aliases, 1 278 → 194). Fixtures:
`emit/release/app/SpecSmall` (an identity, a wrapper whose first argument is a call, one whose
argument is read after its own call and stays, and a function every record's field holds, called
through the field), `run/SpecializeSmall` (the same with `Debug.log` on each argument: the order
is the development build's), `emit/release/app/SpecConstants`, `SpecFacts`, `SpecNodes`,
`SpecInit`, `InlineAfter`, `emit/release/split/EmptyPage`.

*Amended: a function that assigns* (`plans/runtime-in-beni.md`, *The empty page's last items*). A
top-level function whose body is one assignment — `x = e` or `o.p = e`, optionally followed by a
unit function's `return null` — holding no function and no `yield`, naming nothing but its
parameters and whole-program names, and not assigning a parameter, is written as that assignment
at a call **made as a statement** (`f(…);`, its value read by nothing), its parameters the
arguments. Every argument must be an atom (as above), so each is evaluated once and before the
assignment, as in the call; a statement the lowering lists as a pure discard is left alone; and
another module's binding is assigned only in a one-scope build. **It is done at every call or at
none**: only when every mention of the function is such a call does its declaration go, and only
when the calls' growth is smaller than the declaration — the size model's, with `true`, `false`
and `null` priced as their text — is the whole smaller. The browser runtime's `stop` in a release
build is `dead = true`, called from each entry point's guard: on a page with two or three guards
it is written in (the empty page 485 → **480**, 24 of the 56 pages smaller and 4 larger
by 1–23 brotli bytes with fewer raw bytes, −207 in all), on a hosted page with eight it stays.
Fixtures: `emit/release/app/SpecStatements` (`stop` twice and gone, `set n` with a literal,
`bump` called nine times and kept, `raise` stored for the host and kept), `run/SpecializeStatements`
(the same; both builds print the same lines).

*Amended 2026-10-02: a parameter nothing reads* (`plans/runtime-in-beni.md`, *The empty page's
last items*). Fact 1 drops a parameter whose every call passes one literal; a parameter whose value
nothing uses goes the same way whatever it is passed. A parameter of a top-level function every call
of which is seen (fact 1's condition: the name is never used but as a callee, with its arity) goes
from the function and from every call when nothing in the body reads or assigns it and **every
argument for it does nothing** (`effectFree`: an inert expression — a literal, a name, a function,
an object or array of those — or a read through objects the program made that can run no getter and
throw nothing, `Pts.safeChain`); an argument that may do something keeps the parameter, so no
evaluation is lost or moved. A read that stands in the initialiser of a **dead binding** counts as no
read (`deadReads`): a `const` or `let` that nothing reads or assigns, that lowering does not keep
for an effect, and whose initialiser does nothing — `Opt` drops it whole — whose initialiser is then
written `undefined`, so no read of the parameter is left. The pass takes this in every round, but
such a drop asks for no round of its own — what it exposes the next round finds, whichever asks —
since the extra rounds it asked for cost a `--schema-library` release build a third more analyses.
The model binding of `mount` (`let e = a.init`) is dead only once its self-assignment is gone and
its read is released (*Amended 2026-10-03*, above), so when releasing a binding frees a read
through a local, the facts are asked once more after it. On the empty page `mount`'s program
parameter goes, with `run`'s `b.a` argument and the mount record's `a` (`[{}]`). Measured (release,
brotli, the whole bundle): the empty `browser` page and `Tea.sandbox` 466 → **450**, `Tea.element`
1 232 → 1 223, with effects 5 316 → 5 311, `random` 1 997 → 1 962; `bench/size.mjs` −358 over its 367
lines (38 smaller, 17 larger, the largest `run/SchemaDeclModules` +22 with fewer raw bytes, and
`run/UnitSubPattern` +13 and `run/ConstantMethodCall` +11: a call made shorter by its dropped
argument is no longer written in by slice 8's per-call size model); the 52 `browser/` pages −243
(22 smaller, 5 larger by 1–6); the `bench/ui` app byte-identical. Dropping the parameter only in a
last round, after the inlining passes, avoided those two and was measured smaller on fewer programs
(−304 and −67), so it was not taken. **Cost**: `run/SchemaDeclRecords`'s four builds, one a release
build of the whole schema engine, 0.71 → 0.72 s of user time (the least of five; asking `effectFree`
and walking for dead reads is about 45 million instructions of them). Fixtures:
`emit/release/app/SpecUnreadParams` (a parameter passed names and literals goes; one passed a call
stays), `run/SpecializeUnreadParams` (one passed `Debug.log`'s result stays, and the line is logged
where it was), `emit/release/app/OneLine`, `SpecScalars`, `emit/release/split/EmptyPage`.

*Amended 2026-10-02: unused trailing arguments* (`Spec.trimArguments`). A call whose callee is not a
function fact 1 tracks — a call through a property, `kind.m(…)`, or of a function passed as a value
— keeps every parameter of every function it may reach, since a call the pass cannot see may pass
them. But when fact 3 says the callee may be **only functions of the program**, none of them reads
a parameter past position *k* (a name mentioned anywhere in the body counts as a read, so a
shadowing name only keeps an argument), and every argument past *k* does nothing (`effectFree`),
those arguments go: a missing argument is `undefined`, and nothing reads it. It runs once, after
every round and the passes: slice 8 writes a call through a property in only when it passes every
argument, and trimming one first made `emit/release/app/SpecInit`'s kind call stay a call. On the
empty page the kind's `c.m(null, null)` is `c.m()`. Measured against the compiler before it
(release, brotli): the empty `browser` page and `Tea.sandbox` 450 → 450 (raw −9), `Tea.element`
1 223 → 1 222, with effects 5 311 → 5 306, `random` 1 962 → 1 955; `bench/size.mjs` −41 over its
367 lines (23 smaller, 12 larger, none by more than 16); the `browser/` pages −29 (17 smaller, 8
larger by 1–8); the `bench/ui` app byte-identical. Fixtures: `emit/release/app/SpecTrailingArguments`
(a field holding two functions that read one parameter loses the call's second argument; one that
may hold a function reading two keeps both), `run/SpecializeTrailingArguments` (an argument that
logs is kept, and logged where it was), `emit/release/split/EmptyPage`.

**Slice 9 — constructor folding** (*added 2026-10-03*; `plans/runtime-in-beni.md`'s *Append
against Solid 1*: a page that reads a list with `List.get` then `Maybe.withDefault` made a `Just`
per read, most of the cold loop's cost). A value a small function makes, that another small
function or the rest of the caller only *inspects*, is made where it is inspected, so that its
tag test folds and its fields are read where they are written:

- **A producer** is an expression that makes an object a fold can see into: an object literal; a
  *declared object* (a top-level `const` of an object literal — a nullary constructor such as
  `Nothing`); a choice `c ? A : B` of two producers; or a call of a small function (slice 8's,
  whose body may now also be `if (t) return a; return b` and `const v = e; return R` with `v`
  read once, first — the `case` lowering's shapes, read as `t ? a : b` and `R[v := e]`) whose
  body is one. A parameter is **inspected** when the body reads it, and only as the object of a
  property read; a local is when its declaration says so of every mention.
- **`return f(…, P, …)`**, `f` small, inspecting the parameter `P` is passed to, `P` a producer: the
  arguments that are not atoms are bound first, in order, by `const`s (kept by the optimiser when
  they may do something), then `return` `f`'s body.
- **`const x = g(…)`**, `g` a small producer, `x` only inspected: the same, `x` bound to `g`'s
  body.
- **`const x = c ? A : B`, then one statement `R` ending the list**, `x` only inspected, `A` and
  `B` producers, `R` small with no function in it: `if (c) { const x = A; R } else { const x' = B;
  R' }`, `R'` a copy of `R` reading `x'` and declaring names of its own — `R` runs once on either
  path, as it did.
- **`const x = e; return R`**, `x` read once in its declaration, by `R`, first, and not only
  inspected: `return R[x := e]` — the field binding scalar replacement leaves behind.

Then scalar replacement makes `x = {$: "Just", a: v}` its fields, and the facts fold the tag
test: `"Just" === "Just"` is `true`; and **a constructor's tag `$`** read through a chain whose
objects are all object literals of the program with the key — escaped or not — is the literals'
one value when no code of the program writes `$` on them or on anything the pass cannot see: a
beni value is immutable, and a hand-written file writes none (`Spec.tagValue`; `Nothing.$` is
`"Nothing"` though `Nothing` is passed everywhere). `List.get xs i |> Maybe.withDefault ""` is
then `0<=i&&i<xs.length?unsafeGet(xs,i):""`; `case List.head xs of Just x -> x * 2; Nothing -> d`
is `0<xs.length?unsafeGet(xs,0)*2:d`; a read through `List.drop` still makes the view, not the
`Just`. A name a body needs that is a hand-written file's binding is written by the name a module
imports it as, which is one binding of the one scope; the import stays while any module names it.
The passes run small functions, functions called once, then this, then scalar replacement — in
that order, so a function called once is taken in before a binding here makes its argument a
call.

Measured (release, brotli, the whole bundle): the empty `browser` page and `Tea.sandbox` 503 →
**496**, `Tea.element` 1 226 → 1 210, with effects 5 384 → 5 362, the `bench/ui` app 5 701 →
**5 675** — its `pick` is `{let d=N(c,b);return 0<=d&&d<a.length?R(a,d):""}`, no `Just` — and
`run/` programs −671 in all. Fixtures: `emit/release/app/SpecMaybe` (`get` then `withDefault`, a
`case` on `head`, and `drop` then `head`), `run/SpecializeMaybe` (the same with `Debug.log` on the
index and in each arm, a `Maybe` read whole by `Debug.toString` and so made, and a function
choosing among three), `emit/release/split/EmptyPage`, `HolesPage`, `emit/release/app/SpecScalars`,
`SpecSmall`, `SpecNodes`.

**A variable nothing reads** (*amended 2026-10-02*). Fact 3 drops a write of a property no read
reaches; a write of a *variable* nothing reads stayed, and so did the variable: the fiber runtime's
`expired`, set by the teardown's deadline and read only where a finaliser is (`finalising`), was
`let y=false` and `y=true` on every page that runs a fiber and registers no finaliser. Now, in the
rewrite, `x = v` is a dead write — the same as fact 3's, its value still evaluated as a statement
when it may do something (`inert`, `Pts.safeChain`) — when `x` is

- a module-level `let` of the program that no statement reads, by the reads the round's first
  sweep counts (an assignment's target is not a read), and that nothing the pass cannot see reaches
  (`Input.escaping`, the entry's names: `escaped`); or
- a local of the top-level declaration being rewritten that nothing in it reads, closures
  included (`uses`).

A rewrite only takes reads away, so a count of none at the round's start is none after it. With its
writes gone the `let` is referenced by nothing and `prune` drops it, as it drops any declaration
whose initialiser is inert; a local's binding goes by item 1's rule. A `Js.Ref` that does not
escape is such a `let` (§4, *A `Js.Ref` that does not escape is a `let`*). Measured (release,
brotli, the whole bundle, against the build before): the `browser-tea element` page 1 207 →
**1 146** (cells the hosted mount sets and nothing reads, and a flag set around the render's
`try`, with the setter and the parameters that only fed them), effects 5 824 → 5 782, `http` 3 836 → 3 805, `every` 4 403 → 4 351, `random`
1 942 → 1 912, TodoMVC 9 732 → 9 702; `bench/size.mjs`'s lines −639 in all, 42 smaller and none
larger. Fixtures: `emit/release/app/SpecUnreadWrites` (a cell written and read by nothing goes with
its writer; one written with a host call keeps the call; a local cell goes; a cell read back keeps
its writes) — red against the build before; `run/SpecializeUnreadWrites` (the same with
`Debug.log` in the written values: both builds log the same lines in the same order).
`emit/release/core/EmptyIfTest` and `LetRuns` wrote a cell only to show a shape around the write,
and now also read it, so that the write they pin stays.

**A function called where it is made** (*amended 2026-10-02*). Slice 5 writes a function called
once where it is called, with each argument in place of its parameter; when the argument is a
lambda the body calls, what is left is a call of a function where it is made. The fiber runtime's
`callback register = suspend λwake → …` was `f=(b=>{let c=a(b);return typeof c==="function"?c:
null})(d)` in `callback` once `suspend` was written there, on a page whose only waits are
`callback`'s: a wrapper made and called once per wait. Once the passes are done, one sweep of every statement list in a function (the one
*Amended 2026-10-03*'s `x = x` takes) writes such a call, of an ordinary arrow (no default, not a
`function`), as its body, two ways:

- **In an expression**, when the body is one `return e` — slice 8's shape, `smallOf` — and the
  arguments pass slice 8's rule: each an atom, or one read once and first. The call is `e`, its
  parameters the arguments. No size model applies, since the arrow's own text goes with the call,
  and the body may name what the function around it names: it is written where it was made.
- **As statements**, when the call is a `const` or `let`'s initialiser, a `return`'s value or a
  statement of its own, and the body is statements ending in `return e`: `const p = a;` for each
  parameter in order (a `let` when the body assigns it), then the body's statements, then the
  statement with `e` for its value. The arguments are evaluated once and before the body, as the
  call evaluated them; an arrow binds no `this` and no `arguments`, so its body means the same in
  the list. Taken only when nothing in the list can come to mean something else: every parameter
  and every name the body declares at its own level is declared once in the declaration
  (`declCount`) and by no `catch`, no `return` but the last leaves the body, and the body holds no
  label, which the list could already hold. A body of one `return e` is the first way's: as
  statements it is bindings and a block, larger than the call.

A call whose body reads a parameter twice and whose argument is not a name stays: writing the body
would evaluate the argument twice, or move it. Measured (release, brotli, the whole bundle,
against the build before): the `browser-tea http` page 3 805 → 3 801 (raw −21, `callback`'s
wrapper), the Node `sleep` 1 786 → 1 783; `bench/size.mjs`'s lines −149 in all (raw −857), 26
smaller, 4 larger by at most 16 brotli bytes with fewer raw bytes each. Fixtures:
`emit/release/app/SpecCalledWhereMade` (a lambda written in an expression, one written as a
binding's statements, one whose argument is read twice and stays) — red against the build
before; `run/SpecializeCalledWhereMade` (the same with `Debug.log` in the arguments and the
bodies: both builds log the same lines in the same order).

**Measured again over field renaming** (*added 2026-10-03*; *Item 4, taken up* landed while slices
6–9 were built, and moved every baseline). Release, brotli, the whole bundle, `bench/size.mjs`'s
pages and the `bench/ui` app, each slice's compiler in turn:

| | before | definite init | 6–7 | 8 | 9 | self-assignments |
|---|--:|--:|--:|--:|--:|--:|
| empty `browser`, `Tea.sandbox` | 605 | 557 | 550 | 503 | 496 | **493** |
| `Tea.element` | 1 217 | 1 217 | 1 202 | 1 184 | 1 173 | |
| with effects | 5 258 | 5 258 | 5 258 | 5 236 | 5 228 | |
| `bench/ui` app | 5 639 | 5 639 | 5 626 | 5 613 | **5 613** | |

`run/` programs, release brotli summed over those both compilers build: −3 849 (raw −18 585),
122 bytes of it lost by 20 programs, none by more than 43. **Speed**, Node 24 on the list read
(`List.get` then `withDefault`, and `drop` then `head` then `withDefault`, 3 million reads of a
13-word list, the whole process pinned to one core, n = 15, median ms [IQR]): `get` 164.4
[162.2–164.5] → **147.6** [146.8–149.0], with TurboFan off (`--no-opt`, the cold loop's tier)
192.2 → **152.3**; `drop` 188.6 → **170.4**, cold 227.1 → **196.8** — the `Just` is gone from
both, `drop`'s view stays. `bench/ui` in Chromium 153 (`--taskset=8-15`, script medians, the
master build, this one, and Solid 1; load 4–22 from other work on the machine): run1k 4.82 /
4.81 / 5.05 (n = 16), replace1k 10.6 / 10.7 / 12.2 (n = 30), update10th 1.68 / 1.44 / 1.99,
select 1.28 / 1.30 / 1.82 (n = 30), swap 1.67 / 1.15 / 2.22, remove 0.51 / 0.52 / 0.59, create10k
55.9 / 54.8 / 62.1, append1k 5.16 / 4.98 / 5.23, clear 24.5 / 24.3 / 24.9 (n = 20): every
operation within noise of master or ahead, each slower-looking one re-run (replace, select,
clear) to a tie; ahead of Solid 1 on all nine.

**As built — the worklist** (*added 2026-10-01*, `Spec.Pts.fixpoint`, `Spec.sweeps`). The facts are
the ones above, sweep for sweep; what changed is how much of the program a sweep walks. A release
build of a TodoMVC-sized page spent 1.3 of its 3.0 billion instructions here, most of it fact 3
sweeping the whole program about eleven times a round, from scratch every round.

- **A sweep walks only what read something that changed since it was last walked.** Every read of
  a fact records the unit that made it: for fact 3 a var (`view`), a site's escape and unknown-key
  writes (`seeSite`) and a site's list of properties (`seeProps`); for facts 1, 2, 4 and 5 a
  whole-program name's `escaped` and `assigned`, a site's `prop_lat`, `ret_lat` and spread, and a
  parameter (read by its own declaration alone). A change wakes the units that read it. A unit
  nothing woke would read what it read before, make the joins it made before — no-ops — and
  change nothing, so skipping it is exact: each sweep leaves the state a walk of everything
  would, the sweeps are as many (the caps of 64 and 24 mean what they meant), and a fixpoint is
  the same fixpoint. Facts 1, 2, 4 and 5's units are the top-level statements; fact 3's are the
  top-level statements and every function body, a body walked where the walk of what holds it
  reaches it — never alone — when it or a body inside it was woken, so the order of every walk
  is the order of a sweep of everything. **The order is kept on purpose**: fact 3 is not
  order-free. A var that is `top` still gathers `prim`, `null` and `undefined`, and which it
  gathers depends on what transient values it was joined with before it went `top`; the DOM
  node-maker fact and `appendChild` read `prim` beside `top`. Walking units in another order (a
  reversed sweep, a body alone) gave a different, equally sound fixpoint on
  `run/CallbackOrderDict`, so it is not done.
- **A node's value is its unit's last walk's.** `vals` and what they point into live across a
  fixpoint's sweeps, so the sweep of everything after the fixpoint that a whole-program pass
  needs to fill them is not taken. `rewrite` likewise takes a statement's values from its last
  sweep and only counts its names, unless it was left woken at the fixpoint or reads a
  module-level constant this rewrite has already patched (`nameValue` reads the initialiser).
- **What every round asked of the whole program, it asks of what changed.** `namedIn` answers
  every whole-program name at once from one walk of the module, kept while the module's `version`
  stands; inside `rewrite`, which only takes mentions away, a name the walk did not meet is still
  not met, and an identifier of a name being written as that name's own value needs no walk
  when the module has one name for it. `inlineOne`'s mention counts are kept per module the
  same way, and `nameRead` of a whole-program name reads them.
- **Rounds still start from ⊥.** A round's program is the last one rewritten — calls dropped,
  branches gone — so its least fixpoint lies below the last round's facts; starting from those
  would keep what the rewrite made false, and print a different program.
- **Checked.** A safety build computes each fixpoint of a program of at most 1 500 nodes twice —
  every unit walked every sweep, then by the worklist — and stops if any fact, node value or
  sweep count differs.

Measured in millions of instructions of the ReleaseSafe compiler the tests run, a `--release`
build in a fresh project; every output byte for byte as before (the `emit/release/` goldens, every
release run hash, and every `run/` and `browser/` program built by both compilers and compared):

| build | before | after |
|---|--:|--:|
| `browser/tea/TodoMVC` | 2 962 (specialisation 1 302) | **2 087** (about 420) |
| `browser/tea/DirectEvents` | 2 904 | 2 104 |
| `browser/tea/SyncKeyedPolicies` | 2 845 | 2 058 |
| `browser/tea/UrlAddress` | 2 691 | 2 006 |
| `browser/tea/DebouncedSearch` | 2 596 | 1 939 |
| `browser/tea/Policies` | 2 519 | 1 936 |
| `browser/tea/KeySubscription` | 2 418 | 1 888 |
| `browser/tea/LatestTagger` | 2 420 | 1 932 |
| `bench/size.mjs`'s pages: `browser`, `Tea.sandbox`, `Tea.element`, effects, `random` | 979, 1 035, 1 425, 2 187, 1 626 | 970, 1 024, 1 310, 1 810, 1 454 |
| `zig build bench -- --generate=100000` with a `main` reaching every module, `--no-cache` | 49 244 (specialisation 41 177) | **12 611** (about 4 550) |

The 100 000 lines spent 23.7 billion in `rewrite` alone: `namedIn` walked a module once per
name it was asked of, and `inlineOne` counted the whole program once per function it wrote in.

**Added 2026-10-02 — why a later pass is not incremental, and what is cut instead.** A core
written in beni (`plans/core-in-beni.md` step 3) gives the inline passes something to do in
almost every program, and each time they change something the whole of `Spec.run` repeats:
`prune`, a round of facts from ⊥, `rewrite`, and every inline pass again. On `abuse_wide_test`'s
16 400-arm `case` under `--release` with research 50's `List` in beni, the first inline pass
changed one module, `List` (173 nodes, 8 statements), and the second pass that followed cost
about 765 million instructions. Nearly all of it went on re-walking the untouched 16 400-arm
function. The obvious cure is to redo, after the first pass, only the functions the inline
passes changed, with their callers and callees. **That cannot print what a full pass prints:**

- *Facts must be able to fall.* Writing a call in removes a call site, so a parameter that was
  ⊤ may now be a constant. Keeping a clean function's contributions from the last round cannot
  take that back. This is the worklist note's *rounds still start from ⊥*.
- *Facts travel further than callers and callees.* They run down call chains (fact 1), through
  properties and returns (facts 4 and 5) and through fact 3. In the case above, the callback
  that calls the 16 400-arm function is called from `List`'s loop, so that function's argument
  is a fact-3 value of the very code the inline pass changed. Any exact delete-and-recompute
  closure contains it, so even a perfect dirty set saves nothing there.
- *Fact 3 depends on walk order*, as the worklist note shows on `run/CallbackOrderDict`, and
  allocates its sites and variables in walk order. Re-walking a subset, starting from the old
  state, reaches a different, equally sound fixpoint.
- *The rewriting passes read whole-program facts too*: `dropKeys` and `appendChild` read fact
  3, and the inline passes read the small-function table, `assigned` and `decl`. A statement
  whose text did not change can still be rewritten differently.

An exact incremental pass would replay a unit's walk only when every value it reads is
unchanged. That means recording each walk's reads, writes and allocated ids, for fact 3, the
sweeps, `rewrite` and each inline pass. It is a re-architecture with a cost on every build, and
it is not taken. What is taken instead is exact by construction: work that cannot change the
program is not done, on any pass.

- **A statement list the list sweeps cannot act on is left uncopied** (`Spec.listActs`). The
  three sweeps that walk every statement list — scalar replacement, constructor folding and
  `x = x` — copied every list and examined each statement. Each acts only on a `const` or `let`
  (of an object literal, for scalar replacement), a `return` of a call, or an assignment. A list
  holding none of these is now walked through for the lists below it and left as it was, in
  place. `--self-profile`'s `spec_lists_examined` counts the lists still copied, and
  `build_test`'s *list sweeps do not grow* holds it constant between a 64-arm and a 1 024-arm
  `case`.
- **A walk's cost per statement is cut where it was spent doing nothing.** The literals' table
  is sized to the literals the program spells before it is filled, and is probed once per
  literal, by the literal itself, with `KeyMap`'s kind of hash. Before, the key was built in a
  buffer, hashed twice with Wyhash, and the table rehashed itself as it grew. A literal without
  bytes keeps its id apart. Name counting, fact 3's walk and the sweeps' evaluation take an
  expression that is a leaf without their stacks. `rewrite` no longer walks the program for
  calls to cut when no parameter went. None of this changes an id, an order or a fact. On the
  16 400-arm build, one round's sweeps fell from 320 to 158 million instructions, fact 3 from 73
  to 53, `rewrite` from 231 to 159.

Measured with `abuse_wide_test`'s *16 400 literal branches … under `--release`*, in millions of
instructions against the 4 300 budget, test harness included:

| step | master | `List` in beni (research 50's prototype) |
|---|--:|--:|
| before | 3 846 | 4 782 |
| lists left uncopied | 3 702 | 4 526 |
| cheaper walks per statement | 3 456 | **4 139** |

With `List` in beni the case now fits the budget, 161 million under it, with no re-architecture.

Each step's output is byte for byte as before: every file `bench/size.mjs` builds, in both
builds, and every release run hash.

**Amended 2026-10-02 — fact 3 is order-free** (research 52 §3.3 and §4.5, slices 0–2; this
corrects the worklist note's *the order is kept on purpose* and its *Checked* bullet).

- **A value never borrows a var's storage.** A var's set of sites is a sorted slice that is
  never changed in place: a join that adds a site makes a new slice and leaves the old one. A
  walk holds the values of an expression's earlier operands while it evaluates the later ones,
  and a call among those can join a site into the very parameter an earlier operand read; the
  set used to grow in place under the earlier value, which then read shifted memory or, once
  the list moved, freed memory (research 52's E5: four `browser/tea` pages read `0xAAAAAAAA` as
  a site with the passes' cap raised). The unit test *a value read from a var keeps its sites
  when a later join adds one* is the smallest input that reaches it.
- **`top` implies the other three components.** A value is TAJS's product (`Pts.Val`): `top`,
  `prim`, `null`, `undefined` and a set of sites, each joined on its own, and `top` — what the
  program did not make or cannot follow — may be a primitive, `null` or `undefined` too. So a
  read through a value that went `top` (a host value, an escaped object, an unknown key) gives
  at least what the same read gave before it did, where it used to give `top` alone and drop
  the other bits. With that, every transfer function of fact 3 is monotone, and it has one
  least fixpoint whatever order its units are walked in: the bits a `top` var gathered no
  longer depend on what transient values it was joined with first. The two consumers that read
  `prim` beside `top` now ask only that the receiver is no object of the program: the
  node-maker fact (a primitive, `null` or `undefined` receiver has no such method and throws)
  and `appendChild` (both calls throw the same `TypeError` there, as they already did for
  `null`).
- **An escaped site is ⊤.** Which of its properties a read marked, which calls it recorded,
  what it was written under — those depend on how much was walked before it escaped, and no
  fact is read of them (definite initialisation, `neverRead`, `keyUnread` and the call graph
  all refuse an escaped site; its tag is refused through `unknown_props` whichever way a write
  was recorded). They are not facts, and the check below does not compare them.
- **Checked by another order.** A safety build computes each fact-3 fixpoint of a program of at
  most 1 500 nodes twice: walking every unit every sweep with the top-level statements in a
  shuffled order (a fixed seed), then by the worklist in program order; the two must agree on
  every fact, each site taken for the one its node made (the numbering follows the walk).
  That tests rule 5's property itself, and still tests that the worklist skips only walks that
  change nothing. Put back the old `top`, and 18 `run/` and `emit/` programs stop at it. Facts
  1, 2, 4 and 5 keep the worklist-against-every-unit check until they move into the same
  solver.

Every output is byte for byte as before — the `emit/release/` goldens, every release run hash,
and all 411 release builds of research 52's E3 set compared file by file — so nothing in the
corpus depended on the order the bits were gathered in. **`--self-profile`** counts the pass's
work and every cap it hits (`spec_analyses`, `spec_sweeps`, `spec_points_to_runs`,
`spec_points_to_sweeps`, `spec_passes`, and `spec_analyses_declined`,
`spec_points_to_declined`, `spec_rounds_capped`, `spec_passes_capped`, `spec_init_capped`,
`spec_inline_capped`), so that a size regression is traced to the cap behind it;
`build_test`'s *counts a call chain deeper than its sweeps as a declined analysis* pins the
first. `emit/release/app/SpecDeepChain` (24 levels of pass-through: nothing specialised) and
`SpecSelfGuard` (a flag a dead branch hides from itself) pin what rounds cannot do, and move
when the combined solver lands (research 52 §4).

**Amended 2026-10-02 — truthiness, and what follows a jump** (research 52 §3.4, §3.6 and §4.5,
slice 3). Facts 1, 2, 4 and 5 fold a test only when it is a literal; `x || true` was ⊤, though
every value it can take is truthy, and E4 counted the cost: `platforms/browser/Rt.beni`'s
`sameInputs` and `sameInputsBut`, specialised with `b = null`, kept
`if(a===null||true||a.length!==null.length)return false;` and the loop after it on every page
that has rows.

- **The value carries its truthiness** (`Spec.Lat`): ⊥, always truthy, always falsy, or either,
  beside the value and joined on its own — Click's combined lattice for conditions. A literal's
  is its literal's; an object, an array, a function, a `new` and a DOM node-maker's result are
  truthy; `!x` is the opposite of `x`; `typeof x` is truthy; `a || b` is truthy when `a` is
  wherever it ends the operator and `b` is wherever it goes on, `a && b` the other way round; a
  conditional whose test is decided is its taken branch; a call is what its callees return,
  and a field what its writes give. `a || b` whose `a` is always truthy has `a`'s value, exactly.
  A value is a literal only where the expression's evaluation does nothing the literal could
  lose, as before: truthiness never makes one. `yield x` is now ⊤, what the generator is
  resumed with; it was `x`'s value, which a comparison of the two could have folded.
- **The rewrite spends it where what it skips does nothing** (`Spec.effectFreeTest`): a
  literal, a name, a function, a read through the program's own objects (`effectFree`), `===`,
  `!==`, `!` and `typeof` of such, an arithmetic or relational operator on values fact 3 says
  are primitives the program made (no `valueOf` can run), and `&&`, `||` and `?:` whose parts
  that are evaluated are such — `y` in `x || true || y` is never reached and is not asked
  about. `a || b` whose `a` is always truthy is `a`; whose `a` is always falsy and does nothing,
  `b` (and `&&` the other way round). A conditional with such a test is its branch. An `if`
  with a decided test keeps its arm; when the test may do something it stays, as a statement
  before the arm (`T; …arm`), in the `if`'s own node.
- **What follows a statement that cannot complete normally goes** (`Spec.deadTail`): a
  `return`, `throw`, `break` or `continue`, an `if` neither arm of which completes, or an
  unlabelled block that does not — when nothing outside the dead statements, in the top-level
  declaration, declares or names what they declare, so no earlier statement, closure or
  hoisted `function` can reach it. A module's body is left whole. Each list is cut before the
  list around it asks whether its last statement completes, so that question reads the last
  statement only.

Measured (release, brotli, the whole bundle; every `run/` and `browser/` fixture, files and
projects, and the `bench/todomvc` app, 537 builds, compared with the compiler before): 43 builds
change, **42 smaller and one larger**, −1 796 bytes in all. The pages with rows, which hold
research 52's E4 — 27 `browser/tea` pages, the 9 `browser/dom` pages and `bench/todomvc`'s app —
lose 30–69 bytes each (`sameInputs` is `a=>a===null?true:false`, and `sameInputsBut` loses its
index parameter). `run/QuestionOrder` and `run/SchemaDeclTagged` lose a dead `return` and a dead
`switch` after a folded `?` and a derived `compare`; `run/ReleaseFieldsAcrossJs` −65, a derived
`compare` that is `"LT"`, then written in. **The one larger**, `run/DerivedPartTypedLater` +6
(raw +22), is a gap this does not make but now meets: an `if` on the result of an `eq` that is
`()=>true` folds in the first round now, before the inlining passes would have written `true`
in, and leaves `let same = eq()`, which `Opt` drops after this pass — so `prune`, which counts
that read, keeps `eq` (research 52 §8.3, G8: `Spec` and `Opt` disagree on what is dead). Cost,
millions of instructions of the ReleaseSafe compiler, a `--release` build, against the compiler
before: `browser/tea/TodoMVC` 1 354 → 1 360, `bench --generate=100000` as a library 15 078 →
15 072 (within the noise of two runs), `abuse_wide_test`'s 16 400 arms 2 468 → 2 486; peak
memory unchanged. A literal's truthiness is read from its digits (`numberTruth`): converting each
of the 16 400 numbers cost 26 million more. Fixtures: `emit/release/app/SpecTruthiness`
(red before: `score`'s `n < 0 || true` kept its `if` and its dead statements),
`run/SpecializeTruthiness` (a decided test that logs keeps its log, in both builds).

### The combined solver

*Specified 2026-10-02, normative for `src/js/Spec.zig`'s analysis from slice 4 of research 52
§4.5 on; the owner adopted the architecture that day (research 52 §0.3). The review it rests on
is research 52 §8, whose findings G1–G11 this section cites. Nothing here is built yet: where the
code and this section disagree before a slice lands, the code is the old design.* It replaces
*Whole-program specialisation*'s rounds of analyse → rewrite → prune (and the worklist note's
sweeps) with **one optimistic, combined, sparse fixpoint per structural pass, read once by one
rewrite**. The facts are the ones above — constants and truthiness, points-to, fields, returns,
the allocated-once fact, guards, definite initialisation — plus two the rounds approximated by
repetition: which code is executable, and which local binding is live. What the rewrite does
with a fact is unchanged unless a slice below says so.

#### Where it runs

Per structural pass of `Spec.run`, in this order:

1. **Extract** (workers, one task per module): walk the module's `JsIr` once and emit its
   constraints, its cells' local numbering and its statements' name counts (*Extraction*). A
   module whose `Mod.version` did not change since the last extraction keeps its arrays.
2. **Merge** (calling thread): number every module's cells and constraints by prefix sums in
   module order, intern the literals in that order, build the readers index.
3. **Solve** (calling thread): the worklist to its fixpoint (*The worklist*).
4. **Read off** (calling thread): executability, reachability and liveness (*Reading off*).
5. **Rewrite** (workers, one task per module): patch each module from the final facts, which no
   step of the rewrite changes (*The rewrite*).
6. **Structural passes** (calling thread, unchanged): small functions, functions called once,
   constructor folding, scalar replacement, then the `iife` and `self_assign` list modes — moved
   into this loop (research 52 §8.3, G9) — and, when one changed the program, back to step 1, at
   most `max_passes` = 3 times, counted (`spec_passes`, `spec_passes_capped`).

`trimArguments`, `releaseKeeps` and the solve after it disappear into steps 4–5 (G9). The
pipeline around `Spec.run` (`backend.md` §9's *One scope-hoisted file*, `Opt`, `Fields`) is
unchanged.

#### Cells

A **cell** is a `u32`. Every cell holds a value of the product lattice (*Values*); a cell's id
is fixed before solving, by its module's extraction and the prefix sums of the merge, so ids
follow module order and IR order whatever the threads did (rule 5). The kinds, each a dense
range:

| Kind | One per | Replaces |
|---|---|---|
| node | value-producing `JsIr` node of a module (the cell id is the module's base plus the node index) | `Mod.memo`, `Pts.vals` (D1) |
| name | whole-program name (`Input.globals`, and `addGlobal`'s) | `Pts.globals`, `nameValue`'s module-level reads |
| local | local binding: (top-level statement, name) in the order extraction meets them; a parameter is its function's local | `Mod.value`, `Spec.params`, `Pts.locals` (D7) |
| return | function node (arrow, `function`, generator) | `ret_lat`, `Pts.Site.ret` (D2) |
| site | object, array and function node (allocation site) | `Pts.sites`; its facets are columns: `escaped`, `all_read`, `any_written`, `once`, `prog_any`, `odd_caller` |
| field | (site, property id), made when a load or store first reaches it, in a pool; per site a sorted run of (property, cell) found by binary search | `prop_lat`, `Pts.Prop` (D2, D3) |
| exec | function body, and arm: an `if`'s two, a `?:`'s two, a `&&`'s or `||`'s right side, each `case` | — (new, slice 6) |

Values live in **columns indexed by cell**, sized at the merge: `lat: []Lat` (four bytes: state,
truthiness, literal), `pts: []u8` (the four bits `top`, `prim`, `nul`, `undef`), `set: []SetId` and
`done: []SetId` (the site set, and the part of it already propagated), and the `exec` bitset.
A **site set** is an immutable sorted `[]u32` held in a hash-consed set table (content-addressed,
so its id is the same whichever cell made it first); a cell's set is replaced, never grown in
place (G2). Field cells, made during the solve, number in solve order; no answer depends on their
numbering, since every consumer finds one by (site, property).

#### Values

The product of `Spec.Lat` — ⊥ < literal | `name` < *nonnull* < ⊤, with truthiness ⊥ < truthy |
falsy < either beside it (slice 3) — and fact 3's `Pts.Val` — `top`, `prim`, `nul`, `undef` and a
site set capped at `max_sites` = 48, past which it is `top` and its sites escape; `top` implies the
other three bits (slice 2). Each component joins on its own. **Every transfer function is
monotone, component by component**, and is written as a join over what its operands may be:
never "a constant while some fact is still false, something else after". The rule bites where
today's code special-cases: a read `x.p` through objects all of which are the program's own is
⨆ over `x`'s sites of (the field cell, ⊔ `undefined` where the literal lacks `p` and definite
initialisation did not find it) — which is `undefined` exactly while nothing is written, as
`neverWritten` says today, and grows from there — not "`undefined` if never written, else the
field". Each transfer function has a property test over small lattices (research 52 §4.3), and
the safety build's order check (*Determinism*) catches any that slips.

#### Extraction

One walk of a module's `JsIr` per extraction, on a worker, reading nothing but the module and
`Input` (its `global` and `prop` columns): it emits the module's constraints as flat arrays —
`op: []Op` (a `u8`), `exec: []u32` (the exec cell gating it), `a`, `b`, `out: []u32`, `node: []u32` —
with variable-length operands (a call's arguments, an object's keys) in a `u32` pool, and per
top-level statement the names it declares, reads and assigns (the counts `countTop`, `inlineScan`,
`declCount` and `nameUses` each make today, G7), its guards' σ-copies with their kills, its
definite-initialisation candidates, and the literal nodes to intern. The kinds, each a `switch`
arm of the solver:

| Constraint | Meaning | From |
|---|---|---|
| `lit n → c` | the literal | literal nodes |
| `copy a → c` | `c ⊒ a` | a binding's initialiser, an assignment to a name, an argument to a known function's parameter, a `return` to its function's return cell |
| `op a, b → c` | `unary`, `binary`, `templateValue`, `identity` over the operand cells; `&&`/`||` and `?:` with their truthiness rules | operators, conditionals, templates |
| `σ a → c` | `a` narrowed by a guard (not `null`, not `undefined`) while every listed kill is a read through program objects | `Pts.narrowed` with `kill`, `guardNames` (G9) |
| `alloc s → c` | the site, with its literal keys as stores | object, array and function nodes |
| `load o, p → c`; `store o, p ← v`; `loadAll`; `storeAny`; `spread` | fact 3's reads and writes, on every site `o` holds, through the field cells | member reads and writes, computed ones, `for…of`, spreads |
| `call f, args → c` | for every function site in `f`: arguments to parameters, return to `c`, the call recorded as a caller, the body made executable; for anything else: the arguments escape, `c` is ⊤ | calls; the entry file's call (`Input.entry`) |
| `escape v` | `v`'s sites escape | `throw`, a host call's arguments, `Input.escaping`, a value written to ⊤ |
| `branch t → then, else` | an arm is executable when its parent is and `t`'s truthiness allows it | `if`, `?:`, `&&`, `||`; each `case` arm whenever the `switch` is |

The `escaped`, `assigned` and `reads` columns of today's sweeps are extraction facts (they are
syntactic). The literals are interned at the merge, in module order, so their ids do not depend
on the workers.

#### Executability

An exec cell is a bit, false until something makes it true. The roots: every module's top-level
code; every name `Input.escaping` lists and the entry's call; every function whose site escapes
(IPSCCP's rule: address-taken means executable, and its parameters are ⊤). A function body becomes
executable when an executable `call` reaches its site; an arm when its `branch` allows it. **A
constraint whose exec cell is false contributes nothing** — no argument, no write, no allocation,
no escape, no caller (Click's mixed functions). A callee that may be ⊤ (a host value) reaches every
escaped function, which is already executable. Exec bits only become true, and an arm's rule is
monotone in its test's truthiness, so executability is one more monotone component. Until slice 6
every exec cell is true from the start, which is today's analysis: both arms of every `if` and
every body.

#### The worklist

Two queues, rings of `u32` with a bitset of what is queued: changed cells and newly executable
exec cells. A changed cell wakes the constraints that read it: the static readers, a CSR index
(offsets and constraint ids) built at the merge by counting sort, and the dynamic ones a `load`,
`store` or `call` registers on a field cell or a function's parameters as its operand's site set
grows, in a pool of linked `u32` pairs (today's `Pts.deps`). An exec cell becoming true queues the
constraints it gates (a CSR index of its own). **Site sets propagate their difference**: a cell's
`set \ done` is what its `copy` successors and the `load`s, `store`s and `call`s reading it act
on, and `done` becomes `set` once they have (Pereira & Berlin's wave, SVF's `AndersenWaveDiff`);
a `lat` change re-evaluates the reader whole, which is a few instructions. The queues are seeded in
cell order and drained first in, first out; any other fair order reaches the same fixpoint.

**Termination** is the lattice's: a cell's `lat` changes at most 6 times, its bits 4, its set at
most 48 times before it is `top`, an exec bit once. There is no sweep cap and no round cap. A work
budget — 64 evaluations per constraint and cell — is an assertion: a safety build that exceeds it
panics, naming a cell still changing; a release build sets every cell still queued, and every exec
cell, to ⊤ and drains (⊤ is a fixpoint above any other, so the facts stay sound), and counts it
(`spec_budget_hit`). Never "rewrite nothing" (research 52 §2.1, *Stopping early*).

#### Calls with known results

*Decision 3 of research 52, approved by the owner 2026-10-02 with four constraints, built as a
mixed function of the `call` constraint, not as a pass of its own (slice 8a).* When a call's callee
cell holds exactly one function site, that function is **pure by the checker's inference**
(`Input` carries the checker's purity bit per whole-program function, `checker-v2.md` §26), and
every argument cell is a literal, the call is **evaluated**: the function's body is interpreted
with those literals bound, by the folds the facts already make — integers that are safe, booleans,
string concatenation and ASCII comparison, `===`, truthiness; nothing else, so no transcendental
`Math` and no float-to-string, only what the compiler computes exactly as V8 does — following a
call it makes when that call qualifies in turn. The evaluation is **bounded** (a step budget and a
depth, both counted when hit): one that finishes yields a literal; one that runs out, meets an
operation outside the list, or would throw yields nothing, so a call that does not terminate or
that crashes is never hidden. Results are memoised by (function, arguments). A literal so found is
the call cell's value — joined, like every value, so a call whose arguments later stop being
literals is the function's return as before — and the rewrite writes the call as the literal
**only when the literal prints no longer than the call**. Because the call is pure and was
evaluated to completion, an expression around it that folds to a literal may drop it, which keeps
the invariant every fold rests on: a node whose value is a literal does nothing when evaluated.
The parked prototype (`constantCall`, `foldsTo` on the branch `spec-call-results-parked`) is the
reference for the evaluator, not code to merge. Cloning (decision 4) is not part of this.

#### Reading off

After the solve, three read-offs, each a function of the final cells:

- **Executability.** An arm whose exec cell is false is not printed; a function body that is not
  executable belongs to a function nothing live calls (slice 6). The rewrite keeps the arm an
  `if` takes, as `foldList` does today; a test that may do something stays, before it (slice 3's
  `T; …arm`).
- **Reachability** (`prune`, now a read-off): a top-level declaration is live when it is a root
  (a statement whose evaluation may do something, `Input.escaping`, the entry's call) or an
  executable read of a live binding names it.
- **Liveness of bindings**: a local binding is live when an executable read reads it or lowering
  keeps it for its initialiser's effect (`effect_keep`); only a live binding's initialiser
  references anything, and a write to a binding nothing live reads goes (master's `unreadName`).
  This is what `Opt` will conclude, known before `Spec` decides (G8): `deadReads`, `releaseKeeps`
  and `unreadName` go.

#### The rewrite

One rewrite per solve, on the workers, one module per task: every step reads the final cells and
the read-offs, and none writes them, so the order modules or statements are patched in cannot
change the output (G4 — `stale`, `declined`, `folded_reads` and the `now_literal` round go). What
it does is today's: a node whose value is a literal is written as the literal under the
substitution rule (5 bytes, or read once — by the extracted read counts, executable reads only); a
parameter every call passes the same literal, or that nothing reads and no argument for it does
anything, goes with its arguments; a key nothing reads goes from its literal and a write of it
from the program; `appendChild`; trailing arguments nothing reads (`trimArguments`); a test decided
by its truthiness where skipping it loses nothing (`effectFreeTest`, the one purity test the
rewrite asks, G7); what follows a statement that cannot complete. A name written in a module that
lacks it is added to that module only, so the tasks share nothing they write.

#### Determinism

By construction: ids come from extraction and the merge in module order; every transfer function
is monotone, so the fixpoint is the least one whatever order the queues take; the rewrite reads
only final facts. **Checked** in safety builds on programs of at most `max_checked_nodes` = 1 500
nodes: the solve is run twice — first in first out, then last in first out from the reversed
seeding — and every cell's value, every exec bit and every field (by site and property) must agree
(today's shuffled-order check of fact 3, slice 2, extended to every cell). The determinism test
(`--jobs=1` against `--jobs=8`, twice each) covers the workers.

#### Memory

Per node about 60 bytes at most for the life of one structural pass: 13 per cell (`lat`, the bits,
`set`, `done`) for its node cell and its share of the others, 21 per constraint, 8 per reader
edge; site sets hash-consed, so cells that hold the same set hold one copy. Three arenas: the
extraction arrays (kept per module across the passes while its version stands), the solve's
columns and pools (reset after the rewrite), the set table (reset with them). Today every analysis
allocates new per-node arrays into one arena that lives for the whole pass (D4): a `--release`
build of `bench --generate=100000` as a library peaks at 377 MB. Each slice reports peak RSS on
TodoMVC, that build and `abuse_wide_test`, and none may raise it by more than 5%.

#### Building it — research 52 §4.5's slices 4–8

Each slice is gates-green, measured (instructions of the ReleaseSafe compiler and peak RSS on
`browser/tea/TodoMVC`, `bench --generate=100000` as a `--library` release build with its names
migrated, and `abuse_wide_test`'s 16 400 arms; `zig build bench`), and compared build by build with
the compiler before over every `run/` and `browser/` fixture and the `bench/todomvc` app.

4. **Extraction, the merge and the solver, for facts 1, 2, 4, 5, 6 and truthiness, every exec cell
   true; fact 3 still `Pts`, read as input.** In safety builds on programs of at most 1 500 nodes,
   the sweeps run too and must agree with the solver on every node value they computed, every
   parameter, field, return and decided conditional, and the `escaped`, `assigned` and `reads`
   columns; the panic names the node. Byte-identical. Then the sweeps, `checkedSweeps`,
   `count_logs` and `max_sweeps` go, with the check.
5. **Fact 3 into the same cells and constraints**; `prop_lat`, `ret_lat`, `decided_conds` and
   `Pts`' walker go. The same double run against `Pts` (each site taken for the one its node made,
   as slice 2's check does). Byte-identical. `max_pts_sweeps` goes.
6. **Executability, the read-offs and the rewrite once**; rounds go (`max_rounds`), `prune`,
   `deadReads`, `releaseKeeps`, `unreadName` and `trimArguments` become read-offs, and the `iife`
   and `self_assign` modes join the pass loop. `emit/release/app/SpecDeepChain` and
   `SpecSelfGuard` move (research 52's E1 and E2 fold), and so does `run/DerivedPartTypedLater`
   (G8); every other move is listed and justified. `spec_analyses` becomes `spec_solves`.
7. **Definite initialisation as a may-fact** in the solver (research 52 §3.5); `max_init_runs` and
   the restarts go. Byte-identical or smaller.
8. **Calls with known results** (8a, above, approved); **cloning** (8b) only after the owner
   decides, which waits for slice 6's measurements.

### Compact statements

### Compact statements

*Added 2026-10-02 (`plans/browser-decisions.md` R47-3: each step of the runtime's port must print
as the hand-written JavaScript it replaces).* Shapes a release build writes more shortly than the
lowering does, each exact wherever it applies, none in a development build. Each has its golden;
the whole `run/` and `browser/` corpus's release pass is their differential test.

1. **No `else` after an arm that jumps, and no braces around one statement** (`Print.compactIf`).
   When an `if`'s first arm always ends in a jump — its last printed statement is a `return`, a
   `throw`, a `break` or a `continue`, or an `if` both of whose arms do — the second arm is not an
   `else` but the statements after the `if`: `if(d===e)return;d=f;` for
   `if(d===e){return null;}else{d=f;}`. When only the second arm jumps, the test is negated (by
   `negatedTest`: `===` for `!==`, the operand for `!x`) and the arms swap. A body of one statement
   that JavaScript allows there — a `return`, `throw`, `break`, `continue`, expression or
   assignment, or an `if` with no `else` after it — has no braces, and an `else` whose body is an
   `if` is `else if`. What "always jumps" reads is what is PRINTED: a `continue` that ends a loop
   body and a `return` that a function whose result nothing reads writes as its value (*A result
   nothing reads*) are not jumps. An arm is not spliced when it declares a name its declaration
   declares twice (the compiler's positional names can repeat; `Opt.Plan.repeated`), nor out of an
   `if` that is itself an unbraced body, which must stay one statement. Fixture:
   `emit/release/core/CompactIf`.
3. **A flag test is its bits** (`Spec.peephole`, on every release module). In a test position —
   an `if`'s or a conditional's test, the operand of `!`, either side of `&&`/`||` in one —
   `(x & k) !== 0` is `x & k` and `(x & k) === 0` is `!(x & k)`: a bitwise operator's value is an
   integer and never `NaN`, so it is truthy exactly when it is not zero. A comparison node referred
   to from anywhere else keeps its `Bool`. Fixture: `emit/release/core/FlagTests`.
2. **No result where the result is `()`**: §4's *A `()` result is not written*, with its fixture
   `emit/release/core/UnitResults`.
5. **An optional call** (`Print.optionalCall`). Where its value is discarded — an expression
   statement, the end of a function whose result nothing reads, or such a function's concise
   body — `x == null ? <literal> : x(a)` is `x?.(a)`, and `x.m(a)` in its place is `x?.m(a)`
   (tested either way round, and through `!`). `?.` calls exactly when `x` is neither `null` nor
   `undefined`, which is what `==` tests; `===` does not, so a platform writes the test with
   `Js.isNullish`. Fixture: `emit/release/core/StatementShapes`.
8. **A host global is its bare name, and a conditional nothing reads is an `if`.**
   `globalThis.x` is `x` for a host global of `Rename.bare_globals` (`document`, `queueMicrotask`,
   `Error`, …): no ordinal of either namespace ever spells one (`Rename.reserved`), and a
   scope-hoisted build keeps `globalThis.` for one a hand-written file binds at its top level as
   written or through a host `import` (`Emit.bareBlocked`; `import process from "node:process"`
   binds `process`, which is therefore not on the list). A conditional whose value is discarded
   and one of whose branches is a literal or a name is an `if` (`Print.discardedValue`):
   `if(c)f()` for `c?f():null`, and a concise body so shaped is a block, `()=>{if(g)j()}`, which is
   no longer. Fixture: `emit/release/core/StatementShapes`.

4. **A for-each is a `for…of`.** `Js.each xs f` (`boundary.md` §4.2) is the statement
   `for (const x of xs) …` (JsIr's `for_of`): with a lambda of one parameter that cannot suspend,
   the lambda's body, discarded, is the loop's body and its parameter the loop variable —
   `for(const b of a)b()` — and with any other function the loop calls it. Recognising the
   index-loop shape instead was rejected: `for…of` asks the iterator protocol, which an array-like
   without `Symbol.iterator` does not have, so the rewrite is exact only where the program says it
   iterates. And **a function called once in a discarded position is written there**: the one
   call of a function of the module, its arguments atoms, whose value nothing reads (a `let _ =`, a
   discarded lambda body) is its body discarded in turn (`Lower.discard`), statements or not —
   the extension of *A function called once …* that puts the port's `startOne` in `run`'s loop.
   Fixture: `emit/release/core/ForEach`.
6. **A loop whose first statement leaves it is a `while`** (`Print.whileLoop`): an unlabelled
   `for(;;){if(c)<exit>;S}`, `<exit>` a `break` or a `return` that says nothing the end of the
   function does not (the loop ends the function; no value, or one it does not write), and `S`
   one statement, is `while(!c)S`. *Measured*: the wider rule — any `S`, the `return x` written
   after the loop — cost the release corpus 415 brotli bytes (raw −401) against the `for(;;){if(`
   every other loop shares, so it is this narrow. `S` may hold no `break` of its own. Fixture:
   `emit/release/core/WhileLoops`, whose `gather` is research 47's fragment loop,
   `while(a.firstChild!==null)b.appendChild(a.firstChild)`. (*Amended 2026-10-02:* superseded by
   §8, *The exit test is the loop's header*, which writes every such loop as a `while` in both
   builds, the exit moved after it, for speed — and which, with the exit taken from either arm,
   is smaller than this narrow rule, not 415 bytes larger.) The runtime port's `template` is one
   function because `Rt.beni` now writes the parse in the cloner, as the hand-written runtime does
   (its cell rewritten step by step), not because of a compiler rule.
7. **`new`, and an `else if` chain as a value.** `Js.construct c [ … ]` is `new c(…)`
   (`boundary.md` §4.2; JsIr's `new_call`), so an error is `throw new Error(…)`. Under `--release`
   a `case` whose value is wanted may have a nested `case` for an arm and still be a conditional
   (`Lower.condChainPossible`): `c?"a":d?"b":"c"`, not a temporary each arm assigns. Fixture:
   `emit/release/core/ThrowError`.
9. **An `if` with nothing left in either arm, whose test only reads, is nothing**
   (`Print.testReadsOnly`; *added 2026-10-02*). Both builds write such an `if` as its test, as a
   statement; a release build writes nothing when the test is a read (a name, a literal, a field
   of one), `!` of such a test, `===` or `!==` of two reads, or `==` of two reads one of which is
   `null` or `undefined` — none of which converts an operand, so none can run code. It is what a
   guard leaves when specialisation folds away what it guarded: `Rt`'s `stop` in a page that runs
   no fiber (`boundary.md` §9.8.14, the size pass). Fixture: `emit/release/core/EmptyIfTest`.

And under all of them:

- **A block's last statement has no `;`** (`Print.closeBlock`) — a `}` ends a statement as a `;`
  does.
- **An `if` both of whose arms return a value is one `return c?a:b`**, nested for an `else if`
  chain, and as a function's whole body a concise arrow, `(a)=>a<0?"minus":a===0?"zero":"plus"`
  (`Print.returnsBoth`). *Measured*: the release corpus −370 brotli, the port's empty page −13, the
  `bench/ui` app **+16** — from its only two such sites, `(a)=>{if(a.$==="Just")return a.a;return""}`
  among them; brotli shares the long form with the hand-written runtime's `if(…)return`s. Kept for
  the corpus and the port; the app is still below its size before this work.
- **`x = x op e` is `x op= e`** for a name, an arithmetic or bitwise `op`: both read `x`, then
  `e`, then write.
- **`!(a === b)` is `a !== b`** (and the other way round) anywhere (`Spec.peephole`).
- **A `++` of strings is `+`** (`Lower.stringy`): a `++` the checker did not solve to lists, one
  of whose operands is a string literal, an interpolation or another such `++`, is on strings —
  the two operands have one type — and `Basics.append` of two strings is `+`. With no call of it
  left, the hand-written `append`, mostly its list half, is not written. Fixture:
  `emit/release/app/StringAppend`.
- **`x = x` is not written** (`Print.skipped`): a loop assigns every variable it carries, and one
  an iteration passes unchanged is its own value. Fixture: `emit/release/ListScalarView`.
- **Adjacent `let`s join**, as adjacent `const`s do (§9 item 5), and a run of top-level ones keeps
  its newline after each member. Fixture: `emit/release/core/LetRuns`.

Measured on `EmptyPage`: 933 → 924 brotli for the bare globals, → 916 for items 5 and 8; with the
port's `Rt.beni` rewritten for items 5–8 (`isNullish` for the phase, the parse in the cloner, one
guarded `throw new Error`), items 6 and 7 and the shapes above, **884**, against the hand-written
runtime's 978; with `Js.each` for its two index loops and `startOne` written in `run`'s loop, **855**.

*Amended 2026-10-02 (the empty page's study, `bench/minify/empty-page/`, ledger steps 03–06): four
printer and compactor rules that need no whole-program fact, each exact, none in a development
build.*

- **No newline in the emitted half** (`Print.endLine`, `Emit.appendJoined`). §9 item 3 kept one
  after every top-level statement, for stack traces that name a declaration by line; the study
  priced it at 13 brotli bytes of the empty page's 838. Every statement the printer writes ends in
  `;` or a block's `}`, so no newline was ever standing in for a semicolon. The one file joins its
  pieces the same way: an emitted module's trailing newline goes, and a hand-written file's goes
  after a `;` only (its last `}` may end an expression that automatic semicolon insertion ends at
  that newline). The file ends with one newline. A declined runtime's `import{run,…}from…` keeps a
  line of its own, which is how `tests/browser/driver.mjs` finds it.
- **A `const` is written `let`** (`Print`), and a run of adjacent declarations joins whatever their
  keywords (§9 item 5 joined `const`s and `let`s apart). A `const` the compiler writes is assigned
  nowhere, so the one difference — the `TypeError` an assignment would throw — cannot arise, and a
  file of one keyword compresses better than a file of two (research 41; the study's step 03).
  `for (const x of …)` is `for(let x of …)`: a fresh binding per iteration either way.
  *Withdrawn at the top level on 2026-10-03* — it was not free at run time; the paragraph after
  this list.
- **A function's trailing parameters that its body never mentions are not written**
  (`Print.namedParams`): `m:()=>{…}` for a kind whose body reads neither argument, `p=()=>n` for a
  `view` that ignores its model. The caller still passes them — an argument is evaluated whatever
  the callee does with it — and an emitted function has no `arguments`, so the one difference is
  the function's `length`, which no beni program, core file or runtime reads. A mention is any
  identifier of the name in the body, nested functions and assignment targets included, so a
  shadowing binding keeps the parameter; a body past the walk's budget keeps them all. A derived
  comparison's defaulted depth parameter is never touched.
- **`const` → `let` in a hand-written file is decided over the tokens that are written**
  (`Minify.constToLet`, *Hand-written JavaScript under `--release`*): a unit elimination cut is never
  evaluated, so its `i = …` no longer keeps the `const`s of the units that stay. And **the newline
  after a block statement's `}` goes** (`Minify.statementBlocks`): the body of an `if`, `for`,
  `while` or `with` head, of `else`, `try`, `catch (…)`, `finally`, `do`, `switch (…)`, or of a
  function declaration at the start of a statement ends its statement, so the newline after it is
  never automatic semicolon insertion's. An arrow's or a function expression's body is not one:
  `f=()=>{}`, a newline, `g()` is two statements only because of that newline, and keeps it.

The whole `run/` and `browser/` corpus's release pass is the differential test; fixtures
`emit/release/app/OneLine` (user code: one line, `let`, a callback's unread second parameter) and
every `emit/release/` golden, now one line each; `Minify.zig`'s unit tests for a cut unit's
assignment and for each block kind. Measured (release, brotli, the whole bundle): the empty
`browser` page 802 → **776**, `Tea.sandbox` 809 → **781**, `Tea.element` 1 599 → **1 552**, with
effects 5 839 → **5 758**, the `bench/ui` app 5 998 → **5 941**.

**Amended 2026-10-03: a top-level `const` stays `const`** (`Print.topConstRun`,
`Minify.constToLet`; `plans/core-in-beni.md`, the schema engine). The rule above assumed the keyword
costs nothing at run time, and in V8 it does not hold at a module's top level: a module-level
`const` is folded into the code that reads it, while a `let` is loaded from its slot and checked on
every read, because V8 must assume something reassigns it — and a top-level function is read at
every call. A loop calling a two-line top-level function ran **2.5× slower** with the function
written `let` than `const` (Node 24, one process, both modules side by side); inside a function the
keyword changed nothing measurable, a captured `let` included. On `core/Schema`'s engine it was the
failure paths' gap to the hand-written JavaScript: instructions per operation of
`bench/schema-library`'s workloads, all of them warmed first as the bench does, against the
JavaScript engine — parse `wrong_type` 1.026 → **0.999**, `missing_key` 1.029 → **1.019**,
`unknown_key` 1.040 → **0.999**, read `missing_key` 1.072 → **1.000**, every valid path 0.94–1.00.
So the printer writes a top-level run of `const_decl`s `const` and a run of `let_decl`s `let` — a
run is one kind now — and the compactor never rewrites a hand-written file's top-level `const`. A
function's locals keep `let` (written `const` too, the corpus grew 97 brotli bytes more for
nothing). The price is bytes, and the owner's rule is that bytes never buy run time (the
`hand-minify` skill, §1.4):
`bench/size.mjs`'s release total 372 717 → **373 337** brotli (+0.17 %), the largest program +31
(`browser-tea` random, 1 987 → 2 018); the floor 202 → 184, `bench/corpus` 19 670 → 19 661 and
the `bench/ui` app 5 675 → 5 669 (a hand-written runtime's top-level `const` now matches the
emitted code around it). The release file's aliases of a sibling's exports (`Emit`, `const a=say`)
are `const` for the same reason. Fixture: `emit/release/app/TopLevelConst`.

**Amended 2026-10-02: the loops a bound loop prints as** (`Print.breakLoop`, `forHead`,
`assignmentValue`; `plans/runtime-in-beni.md`, step 4). Three printing rules, each for shapes the
loops of *A function called once is written where it is called* produce:

- **`for(;;){if(c)break;…}` is `while(!c){…}`**, and `for(;;){if(c){…}else break;…}` is
  `while(c){…}`: an unlabelled loop whose first statement is an `if` one arm of which is a bare
  `break` and nothing else. Unlike *item 6*'s `return` form, the rest may be any number of
  statements, and may hold other `break`s — in a `while` they leave for the same place. Only loops
  that exit by `break` are touched, so no loop printed before changes.
- **`let i=a;while(c){…;i=e}` is `for(let i=a;c;i=e){…}`** when the loop prints as such a `while`,
  its body makes no function (a `for` head's `let` is one binding per iteration), no `continue` of
  its own that prints would skip the update, the update is an assignment of `i` among the
  assignments the body ends with and none after it reads `i` nor does it read what they write, and
  nothing after the loop reads `i`. The declaration may be a member of a run of declarations if
  the members after it hold literals only; the run is written without it.
- **`x += 1` is `x++`** and `x -= 1` is `x--` (a `+` with a number literal is a number's), and
  **`!(a == b)` is `a != b`** in a test.

Fixtures: `emit/release/core/BoundLoops`, `emit/release/core/WhileLoops`, every `emit/release/`
golden with a counter, and the `run/` and `browser/` release passes.

**Amended 2026-10-01: an arrow of one parameter is `a=>…`** (`Print.arrowParams`;
`plans/core-in-beni.md`, step 1). An arrow whose written parameter list (after *Compact
statements*' trailing-parameter cut) is one name prints it without brackets, as a hand minifier
does — `b=>String(b)`, where it was `(b)=>String(b)`. A `function` declaration, an arrow of no
parameter or of several, and a derived comparison's `$d=0` keep theirs. It came with core's
`String` moving to beni: the hand-written siblings had the short form from `Minify`, so the same
function compiled from beni was two bytes longer. Every `emit/release/` golden with such an arrow
moved; development output does not.

## 10. Chunking

**Release output is chunks; development output is not.** §9.5 of the design doc settles that with
"two build modes, one graph", and chunking is what makes the second half true. A chunk is a file; a
declaration's chunk is decided by which entry points reach it; and **with one entry point and no
`lazy`, a release build is exactly one file**, which is the degenerate case of everything below and
the part of this section worth the most bytes.

*Decided 2026-10-03 by the owner* (the decisions below supersede the PENDING paragraph that
follows and `plans/m3d-plan.md` §6; specification of the open points comes before code):
1. **Two sources of entries.** Static multi-entry — one build, several `main`s, shared code in a
   common chunk — and `lazy`. `boundary.md` §5.3's "ONE entry point and ONE platform" becomes "one
   platform, a set of entry points".
2. **`lazy` is a contextual word on an annotated top-level function**, as `where` is
   (`lazy adminPage : Model → Html Msg`); `lazy` stays usable as a name, and a value cannot be
   `lazy`, because a top-level constant is evaluated at load time, where nothing can suspend.
3. **A call to a `lazy` function may suspend**: no new effect type; the effects inference marks its
   callers and the fiber runtime parks on the dynamic `import()`. So it is callable from commands
   and tasks, not from `view`, which renders a loading state meanwhile.
4. **A failed load is a typed error** (rule 9). The declaration carries its real type; a CALL has
   type `Result LoadError r`, where `r` is the declared result. `LoadError` names each documented
   failure of a dynamic import; anything else crashes.
5. **The chunker is this section** — colouring, the main chunk absorbing every colour with `main`,
   merging by promoting entries, synthesised cross-chunk bindings — with the 4 096-byte / 5%
   thresholds provisional until measured on the first large app.
6. **A `--release --library` build is one file**: packages ship as source, so nobody consumes
   per-module compiled output.
7. **Acceptance is stated in entries**: a two-entry program splits and both entries run, and a
   `lazy` function is loaded and called in a page.
8. **Preloading, two forms.** A platform may write `<link rel="modulepreload">` into the page shell
   for chosen chunks (fetch and compile, not evaluate; none by default). And a core task
   `Lazy.preload f : Task LoadError ⊤` starts the load from the program — after first render, on
   a link's hover — whose argument must be the NAME of a `lazy` declaration, written directly, so
   the chunk is known statically; anything else is a compile error. Evaluating a beni chunk early is
   always safe: its top level is pure constants.

*Emission sketch* (not normative): the body goes to its own chunk; the main chunk holds a stub that,
once the module has arrived, calls it synchronously (one test, no suspension), and otherwise parks
on `import(chunk).then(ok, fail)`, `fail` mapping exactly the documented failures to `LoadError`
and rethrowing the rest. Chunk names are derived from module and declaration (rule 5).

**Open research before the specification:** (a) how Chrome, Firefox and Safari report a failed
`import()` — network failure, a chunk that throws while evaluating, a parse failure — so `LoadError`
names exactly what each documents; (b) whether a failed module fetch is cached in the module map, so
that retrying the same URL fails without refetching — which decides whether `LoadError`'s network
case can be retried and whether a retry needs a different URL.

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
all functions of the file index and source order (CLAUDE.md rule 5), and the colouring's output is a
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

### 11.1 Development maps (specified and built 2026-10-01)

Pulled forward from M5 by `plans/status-2026-10.md` Milestone 1, item 4: beni is a browser language
first, and debugging emitted JavaScript without a map is the first thing a user of `beni serve`
hits. This subsection is the contract for the **development** build; `--release` writes no map yet
(below). Code: `src/js/SourceMap.zig`, the printer's `mark`/`markName` (`src/js/Print.zig`), and
`Emitter.planMap` (`src/js/Emit.zig`).

**One map per emitted module, beside it.** Every `.mjs` a development build lowers from a `.beni`
module — the app's, `_core/`'s and `_platform/`'s alike — gets `<path>.mjs.map` in the same
directory, and the module ends with one line, `//# sourceMappingURL=<basename>.mjs.map`. The URL is
relative, so the output tree is self-contained: `beni serve` serves it as it serves the modules
(`frontend.md` §10.4 already types `.map` as `application/json`), and the tree can be moved or
served under any `"base"`. **Not mapped**, each for a stated reason: a hand-written sibling
(`*.foreign.mjs`) and a lowering's runtime are copied byte for byte, so the file the debugger shows
IS the source and an identity map would add a file and say nothing; the entry file (`_main.mjs`)
and the derived-comparison runtime (`_core/_derived.mjs`) were written by no beni line; the page
shell is HTML. A `.mjs.map` is never an ES module, and §2's "every emitted file is `.mjs`" reads
"every emitted file a host loads"; a map is named for the module beside it and never stands alone.

**The format is Source Map v3** (ECMA-426): `version`, `file` (the module's base name), one entry in
`sources`, the same one in `sourcesContent`, `names`, `mappings`. No `sourceRoot`, no index maps, no
`ignoreList`. Columns on both sides are **UTF-16 code units**, which is what the format counts and
what a browser means by a column; a generated line ends at `\n`, `\r` and U+2028/U+2029, as a
JavaScript engine counts lines.

- **`sources`** names the `.beni` file relative to the map: for a file read from disk, the path
  from the map's directory to it, both made absolute against the working directory and normalised
  lexically (`../src/Main.beni` for `beni build src --out=out`), so Node's `--enable-source-maps`
  prints a path the developer can open; for a file embedded in the compiler (core, an embedded
  platform), `beni:///` and its store path (`beni:///core/List.beni`), a URL that names it
  honestly and that no server is asked for.
- **`sourcesContent`** always carries the module's text. The output tree is what a browser can
  reach — the source tree is not served, and core is not on disk at all — so without it DevTools
  would show an empty file.
- **`names`** gives a binding its beni name where the printed one differs: `Main$twice` is
  `twice`, `n$2` is `n`. A temporary the lowering invented (`$t…`) has none. Two locals printed
  `x$2` and `x$5` are two entries. A **named function's first byte carries its name too** — the
  arrow after `const Main$twice = `, a `function` declaration's keyword — because an engine names a
  stack frame by the mapping at the start of the enclosing function (Node's does exactly that), so
  a crash in `describe` prints `at describe (…/Main.beni:17:13)` and not `at Main$describe`.

**Granularity: every statement and every expression whose `JsIr` node has a position.** `mark` runs
at the start of `statement`, `rawRecursive` and `expand` — the three places a node starts printing
— and records `(generated byte offset, source byte offset)`; a binding's name gets a second mark
at the name. A node the lowering invented (`Node.no_pos`) records nothing and is covered by the
mark before it. Where several nodes start at the same generated byte — a call and its callee, a
binary and its left operand — the **innermost** wins, since it is the token the reader sees first
there (`n * 2` maps to `n`, not to the `*` the binary is positioned on). The encoder drops a
segment that repeats the previous one's source position on the same generated line. What that
gives, by construction rather than by a list: a declaration maps to its name (its `const` and its
name to the definition's name token — `Lower.declarationAs` positions the binding there and the
value at its body); a call maps to its first token; a `case` arm's test maps to the arm's pattern
and its body to the arm's expression; `Debug.todo` and every other call maps to the call, which is
where a thrown error's frame points. **Markup** is lowered by the platform's lowering through the
interface (`boundary.md` §9.4), whose `at` positions each built node at the markup node it came
from: a hole's patch and mount code map to the hole (`{r.maybe}`), a template and its kind to the
element that opens it, and the walk the lowering invents between them to the mark before it.

**Determinism** (rule 5): the map is a function of the printed bytes, the marks (in print order)
and the source; `names` is numbered in first-use order; nothing reads thread timing. The only input
outside the build's arguments is the working directory, and it enters only as the common prefix
the relative URL cancels. That holds while the arguments are relative to it: an absolute one (a
`--platform=/…/page`) does not cancel, and a map names that file by its path from the output
tree, so moving the project relative to it changes the map — correctly, since the path is one the
developer can open. A test that hashes an output tree therefore keeps every disk source inside its
project (the `browser/` harness copies the `page` platform in, `tests/blackbox/browser.zig`).

**Cost**, measured 2026-10-01 on `zig build bench -- --generate=100000` (624 files, 100 159 lines,
one core, ReleaseFast): the `emit` line 34–37 ms without maps; the new `emit+maps` line, which
records the marks and writes every map, 10–14 ms more (≈30%), of which `sourcesContent` is about
2.5 ms and the marks in the printer 2–4 ms. A whole cold `beni build --library` of the same tree:
182 → 208 ms at `--jobs=1`, 61 → 73 ms at `--jobs=8`, the difference including 627 more files
written. Size: 2.54 MB of maps beside 1.63 MB of JavaScript, 2.03 MB of it `sourcesContent`;
mappings average about 6 bytes a segment. A development build is not shipped, so this is disk and
write time, not page weight; `--no-source-maps` drops all of it.

**Tests.** `build_test`'s *a development build maps a crash in a case arm back to the beni line and
column* builds a program whose `case` arm calls `Debug.todo`, decodes `Main.mjs.map` with a VLQ
reader written in the test from the format alone, and pins where named spots of the module map —
the `Debug.todo` call, a call inside an arm, an arm's test, a declaration's name and its arrow,
both carrying `twice` — and then runs the program under Node's `--enable-source-maps` and pins the
crash's frames (`at describe (…Main.beni:17:13)`); it also checks a map beside every module and
none beside a sibling or the entry file. A neighbour pins `--no-source-maps` and the contradiction.
Every `emit/` development golden ends with its module's `//# sourceMappingURL=` line, and the
determinism test byte-compares the maps with everything else. Chrome is not in the gates:
`tests/browser/sourcemap-chrome.mjs <chrome> <out-dir>` (Chrome from `nix develop .#browser`)
serves a browser build, waits for its first uncaught exception over the DevTools protocol, and
resolves each frame through the `sourceMappingURL` Chrome reported in `Debugger.scriptParsed` —
run on 2026-10-01 against a page whose view calls `Debug.todo` from a hole, it printed
`Main$label /Main.mjs:17:41 -> /src/Main.beni:9:13` and `Main$view … -> /src/Main.beni:17:9`, the
frames below them in `beni:///platforms/browser/Rt.beni`, and the sibling's and entry file's
frames `unmapped`. By hand: `beni serve`, open DevTools, and look for the `.beni` files in the
Sources panel under the page's origin (`src/`, where `../src/` lands at the server's root) and
under `beni://`; that half — the panel, breakpoints, stepping — has not been checked by a test.

**The flags.** A development build writes maps unless `--no-source-maps` is given; `--source-maps`
says so explicitly and is accepted; giving both is a usage error (exit 2). `--release` writes none,
and `--release --source-maps` is refused with exit 2 and a one-line message rather than accepted
while writing no `.map` — §2's original reason, kept for the half that is not built.

**Deferred.** (1) **Release maps**: the one scope-hoisted file and the multi-file release layout
need the marks to survive Opt's dropped statements and inlined initialisers, compact printing's
inserted spaces, Rename's short names (whose `names` entry is then the long beni name — the point
of `names` in a minified build) and §9's per-module pieces joined into one file, which is the
"rebased once at join time" above; none of that is built. (2) **Hand-written JavaScript** is
unmapped in development (above) and, under `--release`, compacted by `Minify.zig`, which would then
owe a map of its own. (3) A crash screen (`Rt.crashScreen`, development only) shows the message and
points at the console, where DevTools already applies these maps to the stack; resolving frames on
the screen itself would need a map reader in the runtime and is not built.

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
- **The runtime module** (*added 2026-10-02*; `boundary.md` §9.2's `"module"`). An export the
  module supplies is a declaration of an emitted module: `cx.runtime(name)` answers the name of
  that declaration, imported from the module's file as any other module's value is (`Rt$template`,
  a short name under `--release`), and the build records it as used. A use of a markup primitive
  the module supplies is the same: `Html.text s` is `Rt$text(s)`, never an import of the file's
  `text` (*amended the same day*, `plans/runtime-in-beni.md` step 2). The entry file imports `run`
  and `start` from the module when the module supplies them. The file's `import … from
  "beni:<Module>"` is written three ways: in a development build and a multi-file release build it
  is rewritten, as the file is copied, to import the declarations' emitted names from the module's
  file — `import { Rt$first as first } from "./Rt.mjs";`, the specifier relative to where the file
  is written, the names as the build spells them — listing only the names the kept part of the file
  mentions (all of them in a development build, which keeps the whole file); in a scope-hoisted
  build the statement goes, and every occurrence of a name it imports is spelled as the
  declaration's name in the one scope (§9, *One scope-hoisted file under `--release`*), which is
  the rule a hand-written binding an emitted module imports already follows, run the other way. In
  the one file the module is evaluated before the file. **Reachability** (§9's *Roots*): a build
  roots, besides its own roots, every value the module supplies and every value the
  file imports from it — coarse, before lowering — and then, once every module is lowered and
  under `--release` the file is cut, the module's values the lowerings imported, `run` and `start`
  where the entry file calls them, and the ones the kept part of the file imports; when that set
  reaches less than the first, the build walks again from it and lowers again, so no function of
  the module is written that nothing calls. A development build keeps the whole file, so every name
  it imports from the module is a root there. *Measured* on 2026-10-02, research 47's empty page
  with `tests/platforms/beni-runtime` (the port as its runtime module, the rest of the runtime as
  its file): **1 107 → 1 058** brotli against the same port spliced in ahead of the program, which
  kept every function of the module; the hand-written runtime's page is 980. With §9's *A function
  called once is written where it is called*, 1 043. The rest of the gap is research 47 §6's item 8,
  specialisation (§9, *Whole-program specialisation*), which `emit/release/split/EmptyPage` shows:
  `template`'s flag branches for flags the page never passes, the list half of `first` and `last`,
  and a slot's fields only list code reads. *Amended 2026-10-02:* **a build with no entry file**
  (`--library`) roots the module's `run`, `start` and `flush`, as a development build keeps the
  hand-written file's whole: the page's own entry mounts the exported program with them
  (`import { Rt$run as run } from "./_platform/Rt.mjs"`; `browser_test`'s library page).
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

**Markup with no nodes** (`<></>`, a fragment of nothing) still owns a place on the page, and holds
it with one empty comment, cloned like any markup from a template of its own: `<!>`, no flag.
**Not `document.createComment("")`** (`bench/minify/empty-page` step 22), nor `new Comment()`,
measured and refused on 2026-10-02: a comment made in the page's document is not of the document a
template's content lives in, so each one placed in a cloned instance is adopted into that inert
document and then, with its row, back. Made 50 000 at a time into a fragment of the page, the made
comment is the faster (Chrome 153: a clone 14.1 ms, `new Comment()` 13.6, `createComment` 12.4); on
the table benchmark with one empty fragment per row it is the slower — `run1k` 5.32 ms against
5.51 for `new Comment()` (n = 24, interquartile ranges apart), `append1k` 5.86 against 6.05 — while
`template.content.ownerDocument.createComment("")` ties the clone (5.31 against 5.35). And it buys
bytes only where the page has no other template (the empty page, −45 brotli bytes); beside one it
costs them (`createComment`: +16 on the `bench/ui` app with an empty fragment per row). The test is
`emit/dom/DomTemplates`'s `nothing` and the page `browser/dom/EmptyMarkup`. dom-expressions has no
counterpart: an empty fragment there is an empty array, which `insert` holds no node for.

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
| attribute, fact `url`; an escape the markup section records `url` (*amended 2026-09-29*, `language.md` §11.5) | through the runtime's `safeUrl`; a literal checked by the lowering instead, by the same pattern, and baked into the template — `""` for a script URL — unless its answer turns on a character outside ASCII (*amended 2026-10-02*, research 51 §5) | guarded |
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
- **A row mounts through its patch** (*amended 2026-09-30*, research 39 §13): Solid's row writes
  its dynamic parts with one effect, whose first run is the mount, so the code a label edit runs
  has run a thousand times by the first edit. A `markup` row's `m` and `p` were two functions, and
  the benchmark's *update every 10th* met `p` nearly cold — its warm-up runs it 300 times — and
  lost to Solid 1 by 1.20× though it is ahead when both are warm. Now, where it changes nothing a
  program can observe, `m` clones, walks, and writes only what `p` never writes — an event's
  payload extractor, its flags, `listen`, `$$cx` — and returns the instance with every kept value
  `undefined`, which no beni value is, and `x: undefined`; the row object says so with `w: true`,
  and the runtime's `mountRow` calls `p` on the fresh instance, which then writes every value as a
  change. **Where**: a row compiled in place whose template is cloned rather than imported (no
  custom element: an upgrade could see its attributes arrive in another order), each of whose ops
  is a text placeholder, a style entry, an event, or an attribute that is not constant, `raw`, a
  class or style list, or a `stateful` property — so `p`'s guarded write is what `m` would have
  written — and whose item-only values (§15.5 above, *What reads only the item*) come after every
  other value and every item-only write after every other write, so `p` evaluates the values in
  the order `m` did and writes in the order `m` did (`language.md` §6, §11.11). Any other row keeps
  the two functions. Pinned by `emit/dom/DomRowMount` (a row that mounts through its patch, one
  whose item-only value comes first, and one with a toggle) and `browser/dom/RowMountOrder`, whose
  `Debug.log`s show each row's values in source order at mount, recorded before this change.
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

#### `For` over arrays

*Added 2026-10-01; specified, not built* (§4, *Lists are arrays*). Every loop of the markup
runtimes over a list — `forKeyed`, `forPosition`, `trimmed`, `childList`, `classes`' and `styles`'
walks in `platforms/browser/runtime.js`, and `platforms/node/markup.js`'s — reads it through §4's
protocol and nothing else, which is what `boundary.md` §9.4.3 means by a loop being the runtime's.
The lowering interface, the row kinds, the keying modes, the selector and every amendment above are
unchanged; only how a runtime walks the items changes.

- **The plain form is walked in place.** `const a = Array.isArray(items) ? items : items.$plain();`
  then an index loop over `a`: no cons cells to follow, and `trimmed`'s copy of the rest of the
  items into `xs` is gone — the rest is `a` from the matched start, its length known without a walk.
  An empty list is `a.length === 0`, the `fallback` test.
- **A trie is walked by its cached plain copy** in the second slice of `plans/list-arrays.md`: O(n)
  once per trie header, O(1) for every later render of the same version (§4, invariant 1's cache).
  Research 38 §15.9 measured the copy at 13 µs for 10 000 elements against an 82 µs render walk.
  The fourth slice measures a walk over the trie's **leaves** — its 32-element arrays and its tail,
  in order, with no copy — against it on research 29's harness, and adopts whichever is faster; if
  that is the leaf walk, it is a fourth protocol point that `core/List.js` alone implements
  (`xs.$chunks()`), and the runtime keeps the index loop for plain lists.
  *Amended 2026-10-01 (E1tp): what `$chunks()` returns, if it is adopted.* A trie's elements no
  longer start at a leaf boundary of radix 0: they are a reversed head, the leaves from radix `off`,
  and a tail of which this version owns a prefix. A list of arrays cannot say that without copying
  the head and cutting the tail, so the fourth point returns **ranges**: one flat array
  `[a0, from0, to0, a1, from1, to1, …]`, in element order, each triple meaning `a[from … to − 1]`.
  A trie gives its head as one fresh array reversed (at most 32 elements, the one copy), then
  `(leaf, 0, 32)` for each leaf from radix `off` to `off + tc` — never from 0: the leaves left of
  `off` belong to other versions, or to the prefix a tail dropped — then `(t, 0, count)`, with no
  copy of the tail. A view gives `(b, o, b.length)`, so the view case below needs no copy either.
  The runtime walks the triples with an index loop and never sees `off`, `hc` or a count; the
  measurement of the fourth slice is of this shape.
- **A view is walked over its backing array** from its offset. *Amended 2026-10-01 (E1tp):* through
  the protocol that is `$plain()`, a copy of the suffix that the view caches, until `$chunks()`
  lands; a runtime never reads a view's `b` or `o` to walk it.
- **The key map, keyed reconciliation, rank chains, the ends-first match, the replacement that
  empties the parent, mounting through the patch and the selector are unchanged**: they operate on
  items and keys, never on the list's representation.
- **Identity.** A render is skipped when `items === s.b` and the inputs are the same (above). A
  pattern's tail is a new view object each time the pattern matches (§4, *Identity*), so the
  runtime compares with **`same(a, b)`** — `a === b`, or both views over the same backing array at
  the same offset — wherever it compares an item, an input or a list that may be a list; `same` runs
  only when `===` has already failed, so an unchanged value costs what it costs today. `refEq` in
  the test platform (§15.8) stays `===`, because it tests the promise and not the runtime.
- **Class and style lists** (`language.md` §11.19) that the lowering writes as literals are array
  literals now (`src/js/Lower.zig`'s entries list, built today with `consNode`).

Fixtures (second and fourth slices): `browser/dom/ForForms` (one keyed and one positional `For`
over a list that is plain, then a trie after a `push` past 32, then a view from a pattern; a swap, a
remove and a selection on the trie), `browser/dom/ForViewIdentity` (`<For each={rest}>` of a
`first :: rest` match re-rendered after an unrelated model edit, whose rows log once, not twice —
red without `same`), `browser/dom/ClassListForms`; and the existing `browser/` goldens unchanged.
*Amended 2026-10-01 (E1tp):* `ForForms` also renders a trie with a head — rows added at the top
past 32 — and the `rest` of one, and `ForViewIdentity` a `rest` of a trie whose head is not empty
(`same` by its trie case).

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
  and blocks are outside it, because the runtime reads their fields by name. *Amended 2026-10-01:
  taken up (§9, *Item 4, taken up*), and they are outside it: a lowering writes plain names, and
  only a beni record's fields — a component's props among them — are renamed.*

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

*Added 2026-10-02 (the empty page's study found it missing): an instance whose first or last node
is a list.* `browser/dom/ForAtEnds` switches a hole between components that begin with a `For`, end
with one, are one, have none, and two `Html.map`s of them, with rows and with none, so an instance's
ends are a list's first and last rows, its marker, and a map's markup through a slot with no marker.
Against a copy of the runtime with `head`'s list arm reading the second row, `head` taking an empty
list for a full one, or `tail` reading a marker-less slot's marker, it fails; `tail`'s list arm is
reached by no construct today (a slot with no marker holds a list only inside an element, never at
an instance's end), and a mutant of it survives.

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

*Amended 2026-10-01: the loop with effects* (the owner's W46–W55; `boundary.md` §9.8). What the
bullets above left to the effects work is specified here; nothing above changes for a program built
on `Browser.program`, except that its messages now pass through the same dispatcher.

- **Dispatch.** A program's `send` — `$$root`, a delegated handler's target — is the runtime's
  `dispatch`. It queues the program's render and a flush **before** it runs `update`, so work the
  message starts runs after the flush that shows it; a message sent while a dispatch runs is queued
  page-wide and applied, in order, when that dispatch ends (`boundary.md` §9.8.4 rule 2).
- **A hosted program.** A mount of `Browser.hosted` hands its record's functions the program's
  `Host`, `{ send, after }`. At mount: `settle(host, init(host))`, then the synchronous render. At a
  message: `update(host, msg, model)`. In phase (1) of each flush that renders it: `settle(host,
  model)`, then `view`. The subscription diff lives in `settle`, so it runs once per render.
- **Phase (2)** runs first the resumes of the fibers waiting in `Dom.rendered`, in the order they
  waited, then the after-render work queued before the flush began, first queued first, each
  synchronously. `host.after(f)` queues `f` and a flush. Work queued, or a message sent, during
  phase (2) is the next flush's, which is queued when this one ends.
- **`flush`**, the export and `Browser.flush`, does nothing while a dispatch or a flush runs; the
  flush already queued covers it (W50).
- **`onRendered(resume)`**, which `Dom.rendered` waits on, calls `resume` at once when no flush is
  queued and no after-render work waits, and otherwise at phase (2)'s start; its canceller removes
  it.
- **How `Browser`'s sibling reaches the loop.** `run(program)` first hands every mount's `h` —
  a function of `Browser.js`, carried in the `Program` value — the loop `{ flush, rendered }`, then
  mounts. A sibling may not import another file (§2), so a value is the only way across, and the
  runtime file gains no export.

*As built, 2026-10-01*: `platforms/browser/runtime.js` (the section *The program and its render
loop*), `Browser.js`. The pages are `tests/corpus/browser/tea/` (`AfterRenderFocus`,
`ReentrantSend`, `FlushLatched` and the command and subscription fixtures `boundary.md` §9.8 names).

*Amended 2026-10-02: a page that mounts no hosted program ships none of the hosted loop.* As first
built, the dispatcher, the after-render queue, the waits and `flush`'s guards were the runtime's,
named by `run` and the mount, which every page keeps — so the empty `browser` page grew from 1 219
to 1 541 brotli (`bench/size.mjs`, `--release`) for machinery it never runs. Research 40 §8's rule
2 now holds for the loop: **the runtime keeps only what every page needs**, and everything a hosted
program adds lives in `Browser.js`, reached through the mount `Browser.hosted` makes and so
eliminated with it. The bullets above stand as the behaviour; what moved is where each piece is:

- **The runtime** has the render queue, one microtask flush, `run` and the mount. A plain mount's
  `send` queues its render (and the flush) and then runs `update`, as every `send` now does. `flush`
  renders what is queued and ends with the **after-render phase**, a binding that is null until a
  hosted program mounts. A hosted mount's `h` is called at its mount — not before every mount — with
  the mount node, `flush`, and one function that sets the phase and answers whether a flush is
  queued; it returns the record `run` mounts.
- **`Browser.js`** has the rest. The hosted record's `update` is the dispatcher (the inbox of sends
  made during a dispatch, page-wide); its `view` settles and renders, the first at mount on
  `settle(host, init(host))`; the phase resumes the waits and then runs the after-render work.
  `flush`'s guard is two flags of this file — a dispatch runs, or a hosted program renders or the
  phase runs — which cover every path by which a program's code can reach `Browser.flush`: only
  hosted code can, and it runs in one of those three or in a fiber, which never runs inside a flush.
- **A flush is queued through the mount node's `send`**, with a message no `update` sees: the
  render it queues finds nothing applied since the last and shows what was shown, without calling
  `settle` or `view` — so `host.after` and `onRendered` need no scheduler of their own, and a
  render that follows a real message always settles and renders, as before.

Measured (`bench/size.mjs`'s method, `--release`, brotli): the empty `browser` page 1 541 →
**1 234**, the empty `Tea.sandbox` page 1 551 → **1 239**, the benchmark app 5 354 → **5 059**
(1 219, 1 221 and 5 024 before the host, measured the same way). What the plain page still pays
for the hosted one is the `h` call with its three arguments and the phase binding and its call,
26 bytes, which no restructuring of the runtime alone removes: `run` must hand a hosted mount the
loop, and which mounts are hosted is a fact of the `Program` value, read at run time. (The
compiler knows it statically — whether `Browser.hosted` is reached — but no mechanism lets a build
choose between two `run`s.) Without them the page would
be 1 208; one `throw` in `run` and `!= null` in the listener's context walk bought the rest back.
`build_test`'s *a release page ships the hosted program's loop only when it mounts one* holds it.

*Amended 2026-10-02: the render loop and the mount are written in beni.* `platforms/browser/Rt.beni`
is the platform's runtime module (`boundary.md` §9.2, *A runtime module*;
`plans/runtime-in-beni.md`, step 1): an instance's nodes (`first`, `last`, `put`, `drop`, `swap`),
`template`, `slot`, `unit`, `patch`, `place`, `childHtml`, the render queue, `flush`, `run` and the
mount, each the hand-written function it replaced, statement for statement where beni allows it.
`runtime.js` keeps the rest and imports what it calls from `beni:Rt`. The behaviour above is
unchanged; what a release build gains is that these functions are compiled with the page and
specialised to it (§9), so the empty `browser` page is **838** brotli against the hand-written
978, and the benchmark app 6 084 against 6 139. **The 26 bytes above are still paid**, now for two
reasons a build could remove: `Browser.program`'s mount object is made by `Browser.js`, which the
specialiser cannot see, and the entry file's `run(main)` escapes both `run` and `main` (§9, fact 3).
Written in beni, `program` would lose the `sync` its signature demands of `update` and `view`,
which only a `foreign` signature may write (`language.md` §5.4) — so it stays hand-written; hand
removing the hosted branch and the phase from the page measures **838 → 816**.

*Amended the same day: templates' holes and attributes are written in beni* (`plans/runtime-in-beni.md`,
step 2). `Rt.beni` also holds `childMaybe`, `insertText`, `attr`, `attrNS`, `rawHtml` and the two
markup primitives, `text` and `map` with their kinds — which the module may now supply
(`boundary.md` §9.2, amended). `childList` stays in `runtime.js` beside `forPosition`, whose loop
it shares (moved alone, a page with both paid 43 bytes more brotli), and so does `safeUrl` (`Js`
writes no regular expression literal, and nothing of it specialises). A page that uses the moved
functions is 9–90 bytes brotli smaller; one that does not ships the same JavaScript, byte for
byte but for which short names its declarations are given.

*Amended the same day: `Browser.program` and the events are written in beni* (`plans/runtime-in-beni.md`,
step 3). With `sync` allowed in a platform's ordinary signatures (`transparent-effects-proposal.md`
§15.2 item 1, amended), `Browser.program` is a beni declaration of `Browser.beni` that keeps its
demand on `update` and `view`, and the entry's `run(main)` is read as a call (§9, *The entry's call
is a call*): **the 26 bytes above are gone** from every page whose program is `Browser.program`
(or `Tea.sandbox`, built on it) — `run` has no hosted branch and `flush` no after-render phase —
and the empty `browser` page is **796** brotli. `Rt.beni` also holds the events — `fire`, the
delegated listener, `delegate`, `start`, `listen` and `identity` — and `runtime.js` no longer
exports them. `fire` reads a node's flags without the listener's `?? 0`: an absent flag word is
`undefined`, whose bits are 0 to `&`. `Browser.hosted` and its loop stay in `Browser.js`: every
guard of that loop is a `try … finally` (a message's `update`, a render, the after-render phase),
which beni cannot write, and none of it is on a page a build could specialise further than
`Minify`'s export cut already does.

*Amended 2026-10-02 (`plans/runtime-in-beni.md`, the hosted loop).* **The hosted loop is
`Browser.beni`'s**, written over `Js.finally` (§4, *`Js.finally` is `try … finally`*): `hosted`,
the mount record it makes (`Host` in the JavaScript), the after-render phase, the dispatcher's
inbox, `flush` and `onRendered` are beni declarations, each guard a `Js.finally`, and `Browser.js`
keeps only `mountAt` and `programs`. The protocol with `Rt` is unchanged — the mount is `{ h, n }`,
`h(root, flush, setPhase)` — and so is every behaviour, a throw in `update`, a render or the
after-render phase included (`browser/tea/ThrowRecovers`). What a release build does with it that
it could not with a sibling: the mount record's unread `init` key goes (fact 3), `hosted` is
written into `main` (*Once the whole program is in view*), `flush` and `onRendered` are dropped
by reachability like any declaration, and a unit-valued lambda's `return null`s are not written.
The empty `Tea.element` page is 1 475 → **1 261** brotli, the effects page 5 590 → **5 412**.

*Amended 2026-10-01: a defect stops the page* (the owner's W2; `boundary.md` §9.8.10 (c), which
is normative for the behaviour). The runtime gains one flag, `dead`, and `stop`, which sets it and, in a
development build only (`Js.development`, §4), puts a crash screen above the page. Four entry points
are guarded — `fire` (a handler and the dispatch it starts), `flush` (renders, `settle`, `view`, the
after-render phase), `run` (`init` and the first render) and, through `Task.onDefect`, core's
scheduler — each a `Js.finally` whose body ends by setting a local `ok` and whose cleanup calls `stop`
unless it was set: `let ok = false; try { …; ok = true } finally { if (!ok) stop() }`, nothing
caught. Once `dead`, `fire` calls no handler, a mount's `send` applies no message and `flush` renders
nothing. A hosted mount is handed `stop` as `h`'s fourth argument and gives it to `Task.onDefect`.
`browser/tea/ThrowRecovers`, which pinned recovery, is replaced by `browser/tea/DefectInUpdate`,
`DefectInRender`, `DefectAfterRender`, `DefectInFiber`, `HttpDefect` and `browser/dom/DefectInHandler`,
each with a `.release-expected` that has no screen.

*Amended: `safeUrl` is written in beni* (`plans/runtime-in-beni.md`, step 6). With `Js.regExp`
(§4), `Rt.beni` holds `safeUrl` and its pattern, a top-level regular expression literal made once;
`runtime.js` exports nothing and is kept only because a manifest names a runtime file. A page that
writes a URL attribute calls `Rt$safeUrl`; what it writes is unchanged (`browser/dom/SafeUrl`).

*Amended: `mountAt` and `programs` are written in beni* (`plans/runtime-in-beni.md`, step 6).
Both are declarations of `Browser.beni` — `mountAt` a `.map` that writes each mount again with the
id, `programs` a loop that pushes every mount of every program, the list read by the list protocol
— and `Browser.js` is gone: no platform JavaScript is left but the empty `runtime.js`. A release
build specialises them like the rest (`mountAt (…) "inner"` writes the id into the function).
`browser/tea/MountedPrograms` pins a nested and an empty `programs` and `mountAt` of a hosted
program.

*Amended: no `runtime.js`* (2026-10-02). The manifest's `"runtime"` and `"markup".runtime` are
optional when the runtime module is the whole runtime (`boundary.md` §5.2, §9.2), so the empty file
is deleted and `browser` names only `"markup": { "lowering": "dom", "module": "Rt" }`. A build
writes no `runtime.foreign.mjs`; the entry file imports `run` and `start` from `Rt`'s output, as it
already did, and a release build's one file is unchanged byte for byte.
