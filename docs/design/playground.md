# The playground — beni compiled to WebAssembly, in a page

*Amended 2026-11-04:* the Counter, Print, TodoMVC and Ball machine sample
sources use the accepted ASCII spellings (`language.md` §12.7–§12.10).
Plain formatting preserves them; `fmt --to-unicode` is an optional conversion.


> Test policy, 2026-10-22: per-test instruction limits, grants and reference CPU
> requirements were removed (#740). Each test or corpus case now has a
> 120-second wall-clock hang guard. Older counts and budget references below
> describe historical evidence, not a current gate or an outstanding grant.
> Performance remains the job of `test-perf` and `bench`.


*2026-10-15. The normative design of the playground of issue #128: a web page where you write
beni and see the result on the same page, with no server. The page holds an editor, the beni
compiler compiled to WebAssembly, and the compiled program, which runs beside the editor. The
page is published on GitHub Pages next to the examples of issue #127. Section numbers are never
renumbered (CLAUDE.md rule 2); later changes are dated amendments in place. The single-threaded
path that the WebAssembly compiler needs is specified where the parallelism is specified:
[`fast-compiler.md`](fast-compiler.md) §10, *A build with no threads*.*

---

## 1. The decisions

The owner, Cesar Canassa, opened issue #128 and took its three open questions on 2026-10-15:

| Question | Decision | When |
|---|---|---|
| Which platforms at launch? | **`browser-direct` only**, plus a printing sample on the `node` platform. The starting samples are programs that build for `browser-direct` today (`tests/corpus/browser/direct/` lists them). A `browser-direct` program can fail until the work on that platform lands; the page and §4.3 say which samples work. | 2026-10-15 09:44 UTC |
| Which editor? | **CodeMirror 6**, loaded from a CDN with pinned versions, with a small beni grammar. | 2026-10-15 09:39 UTC |
| Where does it live? | **This repository**, in `playground/`. A `zig build` step writes the static directory, and the site build of issue #127 (PR #121) copies it to `/beni/playground/`. | 2026-10-15 09:39 UTC |

The first answer to the platform question read "browser-tea only — just browser-direct". It
contradicted itself, so it was asked again; the decision above is the second answer.

*Amended 2026-10-15.* After an adversarial review, Jayson Reis took two more decisions on the
dashboard at 12:36 UTC:

| Question | Decision |
|---|---|
| `wasm-playground-q5`: the two `.wasm` gate tests cost a fixed 74% of the budget | **A budget of their own, and `test-playground` in CI on every pull request** (§6). The budget was granted by Cesar on 2026-10-15 (dashboard question `wasm-playground-q7`). |
| `wasm-playground-q6`: the editor's 13 modules from esm.sh run in the shared `canassa.github.io` origin with no integrity check | **Vendor the 13 files** in the repository, each with a checksum, and a script that fetches them again (§4.2). This replaces the "from a CDN" part of the editor decision above; CodeMirror 6 and the pinned versions stay. |

*Amended 2026-11-04 (issue #142):* the editor row of the first table and `wasm-playground-q6` are
superseded. The owner decided to replace CodeMirror with a simple editor written in beni (§10,
first amendment; §10.10). They hold until that editor lands.

The work lands in two pull requests:

1. The WebAssembly target, the single-threaded path with byte-identical output, and a minimal
   page (§2, §3, §5, §6, §7, and §4.1).
2. The full playground: the editor, positioned diagnostics, the tabs, the samples and the
   shareable link (§4.2 to §4.5).

## 2. The compiler in WebAssembly

### 2.1 The target

The compiler is built for **`wasm32-wasi`**, WASI preview 1, on the `generic` CPU model of Zig
0.17: bulk memory, multivalue, mutable globals, non-trapping float-to-int conversion, reference
types and sign extension. Every current browser runs these features. The build pins the model,
so a change of Zig's default does not change the binary.

*Rejected: `wasm32-freestanding` with a small host API.* A WASI build runs the compiler's command
line unchanged: the arguments, the file reads and writes, the two streams and the exit code. A
page compile is therefore a `beni build` command, and the byte-identity claim (§6) compares one
command with the same command. A freestanding build needs a second entry point and a second I/O
layer, and each one is code that only the page runs.

The binary is the same compiler as the native one. `build.zig`'s `compiler` makes it, with the
same embedded `core/`, the same embedded platforms (`embedPlatforms`, with their markup lowerings
compiled in) and the same checked core (`corePack`). The core pack is a byte format of 32-bit
words: its container and every payload write `u32` and `u16` fields with explicit little-endian
`writeInt`, and `frontend/artifact_bytes.zig`'s `widthFor` refuses a field wider than 32 bits at
compile time. So the pack that the host's maker writes is correct on wasm32. A byte comparison
cannot show that alone, because a refused pack makes the compiler check `core/` again and gives
the same bytes; the profile's counters show it, and a gate test asserts them (§6).

*Amended 2026-10-15, after review:* "the same compiler" holds for threads by `fast-compiler.md`
§10, and for the word size because the one order that followed a `usize`, `src/js/Spec.zig`'s
points-to sweeps, now uses 64-bit words on every target (§10, *The word size*). A review of
`src/` for a 32-bit `usize` found no other: no unordered map whose order reaches output is keyed
by a `usize` or a pointer, and every reader of a format widens its bounds to 64 bits
(`src/cache/type_body.zig` since this amendment).

### 2.2 No threads

The compiler checks files and modules in parallel (`fast-compiler.md` §10). A browser gives
WebAssembly threads only through `SharedArrayBuffer`, and a page gets `SharedArrayBuffer` only
when its server sends the `Cross-Origin-Opener-Policy` and `Cross-Origin-Embedder-Policy`
headers. GitHub Pages cannot send them. So the WebAssembly compiler is a **single-threaded
build** (`builtin.single_threaded`, Zig's default for `wasm32-wasi`), and every place that starts
a thread runs its work on the calling thread instead. `fast-compiler.md` §10, *A build with no
threads*, is the contract. The output is byte-identical to the threaded build's.

### 2.3 The stack

A native compiler runs every tree walk on a thread with a 64 MiB stack (`Check.stack_size`). The
single-threaded build has one stack, so the executable's stack is 64 MiB plus 1 MiB for the frames
under the walks (`build.zig`, `no_threads_stack_size`). On WebAssembly this stack is the shadow
stack in linear memory. The linker puts it first in memory, so an overflow traps with "memory
access out of bounds" and does not write over data.

A WebAssembly function also uses the engine's own stack: its locals and its return address are
in the engine's frames, not in linear memory. That stack is about 1 MB in V8 (Chrome and Node),
and a page cannot make it larger. This is the one difference from the native compiler that a
program can see, and §8 gives the limit.

### 2.4 The two streams

`main.zig` writes stdout and stderr as streams, never at a file position. Before, it used a
positional writer, which falls back to a stream only after the host refuses a positional write
with `ESPIPE`. Node's WASI refuses it with `ENOTCAPABLE`, and the writer then fails, so nothing
was printed. A stream is also the correct model on every target: a pipe and a terminal have no
position, and a position overwrote what a shell redirect such as `{ echo a; beni version; } > f`
had already written.

### 2.5 The optimisation mode

The page ships **`ReleaseSmall`**, built by LLVM. See §7.1 for the measurements and the reason.

## 3. The host: `playground/wasi.js`

The page runs the compiler on its own small implementation of WASI preview 1 over a file system
in memory: `playground/wasi.js`, an ES module with no dependency. The page and the tests (§6)
load the same file.

*Rejected: `@bjorn3/browser_wasi_shim` from a CDN.* It works, but then the tests run one host and
the page another, and the compiler's path in the page depends on a CDN. On 2026-10-15 the
compiler imported 34 WASI functions, and a build called about 20 of them, so the shim is small.

The rules:

1. **One instance per compile.** The page compiles the `.wasm` once to a `WebAssembly.Module`
   and makes a new instance, with new memory and a new file system, for each compile. Nothing
   survives from one compile to the next (§9 has the later step).
2. **The project directory is the first preopen**, file descriptor 3, named `.`. Zig's standard
   library takes the first preopen as the working directory on WASI, so `beni build Main.beni`
   finds `Main.beni` and writes `out/`.
3. **Standard input is empty. Standard output and standard error are captured** as bytes. A
   positional read or write on them returns `ESPIPE`, as POSIX does for a pipe.
4. **Every function of WASI preview 1 exists**, so a later Zig that imports one more still
   links. One that has a meaning in memory is implemented: files and directories, reads and
   writes at a position or at the cursor, seeks, `stat`, directory listings, create, rename,
   unlink, remove, truncate, allocate, renumber, the clocks and `random_get`. One that has no
   meaning here (links, sockets, `proc_raise`, `poll_oneoff`) returns `ENOSYS`. Three inputs are
   ignored on purpose: the lookup flags (there are no links to follow), the rights (the shim
   gives every file and path right and checks none), and `fd_advise`'s advice.
   A position or a size past 1 GiB is `EFBIG` or `EINVAL`, so no request of the module makes the
   host allocate an array it cannot have.
5. **An error the shim did not foresee is a defect** (CLAUDE.md rule 9). The functions of the
   shim have no `catch`. A JavaScript exception inside a WASI call goes out of `_start`.
6. **`proc_exit` throws an `Exit` object** with the exit code. `run` catches `Exit` by
   `instanceof`.
7. **Two failures of the module end that compile, and only those two.** A trap
   (`WebAssembly.RuntimeError`: a failed safety check, an overflow of the shadow stack) and an
   exhausted engine stack (§8): V8's and JavaScriptCore's `RangeError` "Maximum call stack size
   exceeded", or SpiderMonkey's `InternalError` "too much recursion" (`isStackExhausted`). No
   other `RangeError` is one of them. `run` returns the failure as the compile's `crash`, with
   what the compiler wrote to stderr before it; the page shows it as a crash of the compiler,
   and the next compile makes a new instance (rule 1), so nothing of the failed one remains.
   Every other exception goes on up: in the page, the worker's `error` listener reports it as a
   defect of the playground.

*Amended 2026-10-15, after review:* rule 4 said that a call with arguments the shim does not
implement returns `ENOSYS`; the shim never did, and the rule now names the inputs it ignores.
Rule 7 caught every `RangeError`, so a `RangeError` of the host would have read as an
exhausted stack; it now matches the engines' stack messages, and rule 4's bound keeps the host
from making one.

## 4. The page

### 4.1 The minimal page (first pull request)

`playground/index.html` with:

- a text area with the source of `Main.beni`;
- a choice of the platform: `browser-direct`, or `node` for a program that prints;
- a compile on each edit, 300 ms after the last keystroke;
- the compiler's diagnostics as text, as `beni build` prints them;
- the running program in a sandboxed `<iframe>` (§5), and for a printing program its output;
- the emitted JavaScript, file by file.

The compiler runs in a Web Worker (`playground/worker.js`), so a compile does not stop the page.
The worker gives no `--out`, so a build writes `out/`, its default, and the worker reads the
emitted files from there.
A compile that starts while another runs waits for it, and only the newest waiting source is
compiled.

### 4.2 The editor (second pull request)

*Amended 2026-11-04 (issue #142):* the owner decided to replace CodeMirror with a simple editor
written in beni (§10, first amendment). §10.10 specifies it. This section describes the editor
until that one lands.

*Amended 2026-10-26, the owner's ball-machine refactor (#1083).* A sample may
contain several source modules. Its index entry lists a `files` map from project
paths to site URLs and an optional `focus` path; the existing `path` form means
one `Main.beni`. Each module has an editable file tab. Selecting a tab preserves
its edits, undo history and diagnostics; it does not compile or restart the
program. Every compile or dump receives the complete project, with
`Main.beni` as the page entry. A diagnostic marks its own module and clicking it opens that file.
The source tabs scroll horizontally when they do not fit.

The ball machine opens on `Control.beni`: four scoped fibers admit, batch,
finish and retry balls, with a semaphore permit acquired at entry and released
at exit. Its sensors, gates, bucket and trapdoor, simulation, drawing and page
wiring are separate modules. The existing controls still resize the semaphore
and choose the batch size; the controller's scope also owns the simulation.

Shared links preserve every source module and the selected file as well as the
platform and CSS. Single-file links retain their existing format. A project
link adds deflated JSON in `files` and its selected path in `focus`; `code`
still holds `Main.beni`. The decoded project requires `Main.beni`, string
contents, and relative module paths (upper-identifier segments, `.beni` suffix),
with no duplicate `Main.beni`. Its total UTF-8 source size, including `Main.beni`,
is at most `maxSource`; malformed projects open the first sample as damaged links do.

CodeMirror 6, every package at a pinned version, with a beni grammar for highlighting:
keywords, comments, strings, numbers, and the Unicode notation (`language.md` §12.7–§12.10). The
diagnostics come from `--diagnostics=json` and show at their positions in the editor.

*As built, 2026-10-15.*

- **The packages.** `index.html`'s import map names 13 modules, each at an exact version
  published before 2026-10-01: `@codemirror/state` 6.7.6, `view` 6.43.13, `language` 6.12.4,
  `commands` 6.11.1, `lint` 6.9.7, `autocomplete` 6.20.3 and `search` 6.7.2; `@lezer/common`
  1.5.3 and `@lezer/highlight` 1.2.5; `@marijn/find-cluster-break` 1.0.4, `crelt` 1.0.7,
  `style-mod` 4.1.4 and `w3c-keyname` 2.2.8. Each module's own imports are bare, so the map is
  the one place a package resolves, and each loads once at the version written there. A second
  copy of `@codemirror/state` breaks CodeMirror.
- **They are files of the site** (*amended 2026-10-15*, Jayson Reis's decision on
  `wasm-playground-q6`; they came from esm.sh until then). The page runs in
  `canassa.github.io`, which every Pages site of its owner shares (§5), so code from a third
  party there could read the other sites' storage; esm.sh rebuilds its output, so an
  `integrity` hash in the import map could not pin it. `playground/vendor/` holds each
  package's own ES module from its npm tarball, unmodified (the editor's first 13 modules,
  1 131 174 bytes, not minified);
  `vendor/SHA256SUMS` names each file's SHA-256, and `vendor/LICENSES.txt` each file's source
  URL and the package's MIT licence, which the site ships. `playground/vendor.sh` fetches them
  again: it checks each tarball against npm's recorded SHA-512, and the same pins give the
  same bytes. A gate test (§6) checks every file against `SHA256SUMS` and the import map against
  the files, and the Chrome test checks that the page asks no other origin for anything.
- **The grammar** is `playground/syntax.js`, a tokenizer for CodeMirror's `StreamLanguage`.
  *Amended 2026-10-15, at Jayson Reis's request:* it is CodeMirror's Elm mode
  (`@codemirror/legacy-modes`, `mode/elm`, vendored) with beni's rules in front of it. The Elm
  mode reads what beni writes as Elm does: names, a name at the start of a line as a
  definition, types and constructors, numbers, character literals, the ASCII operators and the
  brackets. beni's rules take what Elm does not know or reads otherwise: strings with `${…}`
  and escapes, `\\` lines, line and doc comments (beni has no `{-` block comment, so a `{` is
  always a brace), the Unicode notation (`→ ← ≠ ≤ ≥ ▷ ◁ … ×` and `λ` as operators, `⊤` and `⊥`
  as atoms), `True` and `False`, beni's keywords (`pub`, `opaque` and `foreign` are keywords;
  Elm's `module` and `port` are names; `schema` is a keyword before a type name and `where`
  before a `name.method`), `.field`, and markup. The Elm mode calls an operator a keyword and
  a bracket a builtin; the file names them as beni's grammar did before. Markup has the three
  modes of `frontend.md` §9.1: in code, a `<` followed by a letter or `>` opens a tag where an
  operand may start and is a comparison after a token that ends one (§9.3: a name, a literal, a
  closing bracket, `?`, a `/>`, a closing tag's `>`); `</` always closes one. In a tag, names
  are attributes, `--` starts a comment and `{…}` is a hole. Between an element's tags, text
  is text, a `<` before a letter or `>` always opens a tag, and `{…}` is a hole. It
  highlights and decides nothing else: the compiler's diagnostics say what is wrong.
  *Amended 2026-11-04 (§10.7, step 2):* the grammar is `playground/src/Syntax.beni`, with the
  Elm mode's rules translated into it, and a few lines of `editor.js` run it in
  `StreamLanguage`. It names every piece as `syntax.js` and the Elm mode did.
- **The emitted JavaScript** (*added 2026-10-15*, at Jayson Reis's request) is a read-only
  CodeMirror view with CodeMirror's JavaScript grammar (`@codemirror/lang-javascript`, on
  `@lezer/javascript` and `@lezer/lr`, vendored). One highlight style colours both views.
  *Rejected: Prism.js*, which Jayson named "if there is better use it": the editor is
  CodeMirror already (q2), whose own Elm mode and JavaScript grammar give the same result with
  one library, one highlight style and no second highlighter to vendor and keep in step.
- **The vendored files**, after these two: 17 modules, 1 308 650 bytes, not minified.
  *Amended 2026-10-15, issue #143:* the CSS pane (§4.6) adds `@codemirror/lang-css` 6.3.1 and
  `@lezer/css` 1.3.8, both published before 2026-10-01, the same way: 19 modules, 1 344 418
  bytes. `vendor.sh` fetched the 17 earlier files again with the same bytes.
- **Positions.** A span's column counts code points and the editor counts UTF-16 units
  (`playground/positions.js`): `→` is one of each, a character past U+FFFF one column and two
  units. A diagnostic in `Main.beni` is a lint mark with its title and message; every
  diagnostic is also in the list under the editor, and a click on one in `Main.beni` selects
  its span.
- **Tab** indents with four spaces: beni refuses a tab character anywhere (`language.md`
  §2.1).

### 4.3 The samples (second pull request)

A counter, TodoMVC (`bench/todomvc/apps/beni/Sandbox.beni`) and a `run/`-style program that
prints. Each `browser-direct` sample is a program that builds for `browser-direct` today, and
the page says so next to the sample list.

*As built, 2026-10-15.* `playground/samples/index.json` lists each sample's name, platform and
file. The counter and the printing program are `playground/samples/<platform>/*.beni`, under the
format gate. TodoMVC is the `Sandbox` variant of the benchmark, with no storage and no routing:
both need what an opaque-origin frame does not have (`localStorage`, a history of its own).
`zig build playground` copies it into the site as `samples/browser-direct/TodoMVC.beni`, so it
is kept once. The page's note says that `browser-direct` is new and that some programs that build
for `browser-tea` do not build for it yet.

*Amended 2026-10-15, issue #143:* a sample can have a CSS file next to its `.beni`, which opens in
the CSS pane with it (§4.6, *The samples' CSS*).

*Amended 2026-10-26, issue #1041:* a fourth sample, the ball machine of the beni site's flow page,
on `browser-tea`: four fibers run the control program the page shows, a fifth steps the physics,
and `view` draws the machine as one SVG scene. Its `.beni` is the fixture
`tests/corpus/browser/tea/BallMachine/`, which drives the sample itself on the page's
virtual clock, and `zig build playground` copies it into the site as
`samples/browser-tea/BallMachine/`, as it copies TodoMVC; its CSS is
`playground/samples/browser-tea/BallMachine.css`. The machine is dark in both schemes: in the
light one it is a dark panel on a light page (§4.6, *The samples' look*).

*Amended 2026-10-26, the owner's flow-page controls.* The ball machine's
"At once" (1–8) and "Per batch" (1–5) sliders and their current values sit
above the diagram, visible when the preview opens and sticky while it scrolls.
When the batch exceeds capacity, a hint explains that raising "At once" will
let the bucket fill. "Reset the counts" restarts the machine, including its
counters and control fibers, keeping the selected slider values. The previous
command is cancelled with `Cmd.Restart` before its replacement runs. These
controls and their state belong to the beni sample, as on `beni-logo/flow.html`.

*Amended 2026-10-26, the owner's updated flow-page drawing.* The SVG follows
the reference's continuous metal cabinet around the bucket, pipe and check:
inset window and side panels, vents, return-tube clamps, permit sockets,
vertical bucket indicators and a lit exit mouth. Finished balls keep up to
seven frame positions for short fading trails. This is drawing state; it does
not alter collisions, admission, batching, semaphore ownership or retry timing.

*Amended 2026-11-04, issue #1903 (Jayson Reis: "make the samples shareable urls").* Each sample in
`index.json` has an `id`: one or more words of lower-case ASCII letters and digits, joined by
`-`. The ids are `counter`, `todomvc`, `ball-machine` and `fibonacci`. The short link of §4.5
names a sample by its id, and a person can keep such a link for a long time. So **an id never
changes once it ships, and no other sample takes it**, also after its own sample goes. An id is
never `shared`, the value of the sample list's "(shared)" entry. The sample list's values are
the ids. A gate test (§6) checks the ids.

### 4.4 The tabs (second pull request)

The emitted JavaScript, `beni dump --stage=types` and `beni dump --stage=ownership`, each from
the same source as the build.

*As built, 2026-10-15.* A dump is a command of its own on a new instance, run only while its
tab is open: the build runs first for each version of the input, then the open tab's dump.
Every edit and every change of platform makes a new version, and a result of an older version
is dropped. Until the new dump arrives, an open dump of the older version is shown dimmed. A
dump of a program with errors prints what it could, with a line that says the program has
errors. A defect of the playground (an exception the worker did not foresee) is shown and not
run again for the version it failed on; a newer version, from an edit made while it ran, is
compiled. *Amended 2026-10-15, after review:* the page marked the newest version as failed, so
an edit made during the failed run waited for one more edit.

### 4.5 The shareable link (second pull request)

The source, compressed with the browser's `CompressionStream("deflate-raw")` and encoded in
base64url, in the URL fragment. The fragment never goes to the server.

*As built, 2026-10-15* (`playground/share.js`). The fragment is
`#platform=<platform>&code=<base64url>`. **Share** writes it into the address and copies the
address; where the page may not write the clipboard (no clipboard on an insecure page, or no
permission), the status says that the address bar holds the link. A link opens its source and
platform, and stays in the address until a person changes the program: an edit, a change of
platform, or a sample. A fragment whose code is not base64url, not deflate data, not UTF-8, or
longer than 1 MiB once inflated opens the first sample, and the status of its first build says
that the link held no program. Each failure is caught by name around the one call that makes it
(`InvalidCharacterError` from `atob`, `TypeError` from the decompression stream and the fatal
decoder), and the 1 MiB bound cancels the stream with a reason of its own; anything else goes
on up.

*Amended 2026-10-15, issue #143:* the link also holds the CSS pane, as `&css=<base64url>` after
`code` (§4.6, *The link*).

*Amended 2026-11-04, issue #1903: the short link of a sample.* A code link holds every module of
its project, so the link of a large sample is long: the ball machine has nine modules. The site
serves every file of a sample, so a link to an unchanged sample only names it:
`#sample=<id>` (§4.3).

- **The address names the sample.** When the page opens a sample, the address becomes
  `#sample=<id>`, with `history.replaceState`, so the history gets no new entry. The page opens
  a sample when a person chooses one in the list, when it opens with a short link, and when it
  opens with no program (no fragment, a damaged link or an unknown id) and so shows the first
  sample.
- **A short link opens its sample** as the list does: its platform, its modules, its focused
  module and its CSS.
- **An unknown id**, or an empty one, opens the first sample, and the status of its first build
  says that the link names no sample of the playground, as it says for a damaged code link.
- **A change clears the short link**, as it clears a code link: a person's edit of a module or of
  the CSS, and a change of platform.
- **Share.** While the editor holds the sample unchanged, **Share** writes `#sample=<id>` into
  the address and copies it, and the sample list stays on the sample. After a person's change,
  **Share** makes the code link, as before, and the list shows "(shared)". The page keeps the id
  of the unchanged sample in a variable, which a person's change clears; it does not read it
  back from the address, which a person can edit by hand.
- **A fragment with `code` is a code link**, whatever else it holds: `#sample=counter&code=@@@@`
  is a damaged code link, not a short link. So every link made before this amendment opens as it
  did.
- **A short link opens the sample as the site serves it on the day it opens.** When a later
  version of the site changes the sample, the link opens the changed sample. A person who wants
  the exact text in the link makes a code link: an edit, then **Share**.
- **The short link is beni** (§10.8). `playground/src/Share.beni` gives the fragment of a
  sample's short link, and the sample that the page opens for a fragment with no program, with
  the note for the status. It reads a fragment's fields as `URLSearchParams` does. `page.js`
  calls it, and keeps the id of the unchanged sample until the page is beni (§10.7 step 7). The
  code link stays in `share.js` until §10.7 step 3.

### 4.6 The program's CSS

*Added 2026-10-15*, for issue #143 by the owner, Cesar Canassa: a program brings its own CSS, and
each sample has a look of its own.

- **The pane.** The source pane has two tabs, `Main.beni` and `style.css`. Each tab is a
  CodeMirror view, and the page shows one of them. The `style.css` view has CodeMirror's CSS
  grammar (`@codemirror/lang-css`, vendored as §4.2 says), the same highlight style and theme as
  the beni view, and a two-space indent. A click on a diagnostic shows the `Main.beni` tab first.
- **The compiler does not read the CSS.** A build is the same command on the same input as
  before (§4.1), and it writes the same files.
- **The frame.** When the pane holds text, the frame's `srcdoc` holds that text as a JSON string
  in a `<script id="beni-css" type="application/json">` element, with every `<` escaped as the
  files are (§5). `frame.js` adds a `<style>` element with that text at the end of the frame's
  `<head>`, before it imports `_main.mjs`. So the CSS applies before the program mounts. The text
  reaches the frame unchanged: a script sets the element's text, and no HTML parser reads it, so
  a `</style>` in the CSS cannot end the element early. *Rejected: the CSS written into a
  `<style>` element of the `srcdoc`.* Then a `</style` in a comment or a string ends the element,
  and an escape of it changes the CSS.
- **An empty pane gives today's frame.** With no text in the pane, the `srcdoc` has no
  `beni-css` element, and the frame has no `<style>` element. `playground/srcdoc.js` makes the
  `srcdoc`; a gate test (§6) compares what it makes for an empty pane with the document of §5
  before this section, byte for byte, and the Chrome test finds no style sheet in the frame.
- **When the CSS changes.** A person's edit of the CSS restyles the running program and does not
  restart it: the counter keeps its value and TodoMVC its todos. The page sends the pane's text
  to the frame with `postMessage({ beniCss })`, and `frame.js` puts it in its `<style>` element.
  It adds the element if the frame has none, and it removes the element when the pane is empty,
  so an emptied pane gives the frame no style sheet again. The frame takes this message only
  from its parent window, and the sandbox stays as §5 says. A CSS edit makes no new version
  (§4.4): no build, and no dump runs again.

  An edit of the beni source, a change of platform and a sample are as before: a build, and a
  new frame that gets the pane's text in its `srcdoc`. So the CSS reloads with the program on
  every compile. A message that the page sends before a new frame listens is lost. So the frame
  posts `ready` when it listens, and the page sends the text again if it changed after the
  `srcdoc` was made. If the program has errors, the frame keeps the last program that built, and
  a CSS edit restyles that program.

  *Rejected: a build and a new frame for each CSS edit*, the first version of this section. It
  restarted the program, so a person who typed CSS lost the counter's value and the todos.
- **The link.** The fragment is `#platform=<platform>&code=<base64url>&css=<base64url>`. `css` is
  made as `code` is (§4.5), and the fragment has it only when the pane holds text. So a link made
  before this section opens as it did, with an empty pane. A `css` that is not base64url, not
  deflate data, not UTF-8, or longer than 1 MiB once inflated makes the link hold no program, as
  a bad `code` does.
- **The samples' CSS.** `samples/index.json` gives a sample an optional `css`: the path of its
  CSS file, next to its `.beni`. A sample with no `css` opens with an empty pane. The counter and
  TodoMVC have one. The printing sample has none: it draws nothing in the frame, and its output
  is the page's console, which the page's own style sheet styles.
- **The samples' look.** Each sample's CSS gives:
  - a system font stack, so no font comes from another site;
  - text with a contrast of 4.5:1 or more on its background, and large text (24 px, or 18.66 px
    and bold) 3:1 or more, as WCAG 2.2 AA asks, in both schemes;
  - a light and a dark scheme, chosen by `prefers-color-scheme`; the frame's root sets
    `color-scheme` to the same scheme, so the browser's own controls follow it;
  - a layout with no horizontal scroll from a 320 px wide frame up.

  The samples look alike: the counter has TodoMVC's typeface, page colour, card, shadow and
  accent, in both schemes. Their beni source does not change: the CSS uses the elements and
  class names that the programs have.
- **TodoMVC's CSS** is `todomvc-app-css` 2.4.3's `index.css`, by Sindre Sorhus, under CC-BY-4.0.
  That licence allows a copy and a changed copy, with credit, a link to the licence, and a note
  of the changes. `samples/browser-direct/TodoMVC.css` holds the file unmodified between two
  marker comments, after a comment that gives the credit. The playground's changes follow the
  second marker, each with a comment: a dark scheme, a gutter and a shorter heading at phone
  width, and a darker placeholder, because the package's placeholder is 2.85:1 on white. The site
  ships `samples/LICENSES.txt`, as `vendor/LICENSES.txt` does for the editor: the credit, the
  package's tarball and its SHA-512, the list of changes, and the licence's text. The page's note
  links to both files. Each link opens a new tab: the page keeps an edit only in its editor, so
  a click that leaves the page can lose it. A gate test (§6) checks the part between the markers
  against the SHA-256 of the package's `index.css`, and that the page has an `<a>` element for
  each file that opens a new tab.
- **Not built: a list of allowed style sheet URLs** (item 3 of the issue, optional). The frame
  already loads what its CSS names: an `@import url(…)`, a `url(…)` in a property, a `@font-face`
  source. The sandbox does not stop such a load. Only a `Content-Security-Policy` in the frame
  can, and a policy changes the frame of every program, also with an empty pane. So a list of
  allowed `<link>` URLs would restrict nothing, and the sandbox stays as §5 says. A style sheet
  from another site, for example from Google Fonts, goes on the first line of the pane:
  `@import url("https://fonts.googleapis.com/css2?family=Inter&display=swap");`. The Chrome test
  (§6) checks that an `@import` from another origin applies in the frame. A link from someone
  else can therefore make the reader's browser load from another site, but its program already
  can: `browser-direct` has `Http`, and markup has `<img src>`.

## 5. Running the output

The compiled program runs in an `<iframe sandbox="allow-scripts">`, **without
`allow-same-origin`**. All of one user's GitHub Pages sites share one origin,
`canassa.github.io`, so a program with that origin could read and write the storage of every
other site of the user. Without `allow-same-origin` the frame has an opaque origin of its own.

A blob URL that the parent page makes belongs to the parent's origin, and the frame cannot load
it. So the parent writes the emitted files into the frame's `srcdoc`, as JSON in a
`<script type="application/json">` element with every `<` escaped, and the frame's own
bootstrap script (`playground/frame.js`, inlined in the frame's `srcdoc`):

1. makes a blob URL for each module in the frame's own origin, dependencies first, after it
   replaces each relative import specifier with the blob URL of the file it names;
2. replaces `node:process` with a small module whose `stdout.write` sends the text to the parent
   (a printing program on the `node` platform, `platforms/node/runtime.js`). *Amended 2026-11-03*
   (`plans/runtime-in-beni.md` step 15): the `node` platform's runtime is beni over `Js` and
   reads `process` as a global, so the frame defines `globalThis.process` first — `stdout` and
   `stderr` that send to the parent, the `exitCode` setter, a `beforeExit` that never comes, and
   `getBuiltinModule` for `node:fs/promises` — and the two stand-in modules export that object;
3. imports the entry module, `_main.mjs`, which mounts the program on the frame's `<body>`.

The frame sends an uncaught error and an unhandled rejection to the parent from its `error` and
`unhandledrejection` listeners. A listener is not a `catch` (rule 9). beni's own defect screen
shows inside the frame.

*Amended 2026-10-15, after review:* this section said the parent sends the files with
`postMessage`; the code has always written them into `srcdoc`, and the text above now says so.

*Amended 2026-10-15, issue #143:* when the CSS pane holds text, the `srcdoc` also holds it, and
the bootstrap adds it as a `<style>` element before step 3 (§4.6, *The frame*).
`playground/srcdoc.js` makes the `srcdoc`. The bootstrap also takes a new CSS text from its
parent window by `postMessage` and replaces the `<style>` element's text with it (§4.6, *When
the CSS changes*).

A relative specifier is found by the import forms that the compiler writes and that
`boundary.md` §4's checks accept for a sibling: `import … from "./…"`, `export … from "./…"` and
`import "./…"`, each on one line. The emitted module graph has no cycle (a beni import cycle is
an error), so "dependencies first" is always possible; a cycle through hand-written siblings
fails in the frame by name. A dynamic `import("./…")` cannot be rewritten this way: today no
build writes one, and a file with one is refused by name, so code splitting (`backend.md` §10)
will need an import map or another loader here. The `node:process` stand-in gives both the
default export and a named `stdout`.

## 6. Tests: byte identity

Rule 5 says that the single-threaded build and the WebAssembly build write the same bytes as the
native threaded build. Items 1 and 4 prove it; items 2 and 3 test the page itself.

1. **In the gates** (`tests/blackbox/wasm_test.zig`, part of `test-blackbox`):
   - a native **single-threaded** compiler (`zig-out/single/bin/beni`, self-hosted ReleaseSafe,
     the stack of §2.3) against the native threaded one, on projects that reach every place
     where §10's guards are: the per-file pool, resolution, the check DAG, emit, the ownership
     pass and the dumps, and a tree `Parse.max_depth` levels deep, which proves the stack;
   - the **WebAssembly** compiler, run by `tests/wasm/beni.mjs` under Node on
     `playground/wasi.js`, against the native one, on a printing program and on a program with
     diagnostics. The gates build it with the self-hosted backend (`ReleaseSafe`, about 7 s);
     `-Dllvm` builds it with LLVM, as it does the native compiler.
2. **In the gates**, `tests/blackbox/playground_page_test.zig` runs the page's own modules
   under Node (`tests/wasm/page_test.mjs`): the editor's range of a diagnostic the real
   compiler reported after Unicode notation and a character past U+FFFF, the shareable link's
   round trip for both platforms, the grammar's names for comments, strings, keywords,
   notation and markup, and the vendored editor modules against their checksums and the import
   map (§4.2).
3. **Not a gate:** `zig build test-playground-page` drives the site in a headless Chrome
   (`tests/browser/playground.mjs`, `nix develop .#browser`; no network, since the editor's
   modules are files of the site): every request stays on the site, the first sample builds
   and loads in the frame, a click in the frame changes the counter, every sample builds and
   runs, an error is marked on its text in the editor and listed, the Types, Ownership and
   JavaScript tabs show their output, Share after an edit makes a link that opens the edited
   source and platform, and a damaged link opens the first sample.

   *Amended 2026-11-04 (issue #142):* when the beni editor lands (§10.10), item 2's check of the
   vendored modules and item 3's checks that read CodeMirror go with `vendor/`. Every other check
   of items 2 and 3 stays.
4. **Not a gate:** `zig build test-playground` runs the shipped `ReleaseSmall` `.wasm` (§7.1) on
   the hand-picked programs of `tests/blackbox/playground_test.zig` (amended 2026-11-01, below), and
   compares every output file, both streams and the exit code with the native compiler's.

*Amended 2026-10-15, issue #143* (§4.6). Item 2 also checks: the link's round trip with CSS, a
link with no `css` (an empty pane), and a bad `css` (no program); the `srcdoc` for an empty pane,
byte for byte, and a CSS with `</style>` and `</script>` in it, which reaches the frame
unchanged; each sample's files; and TodoMVC's copy of `todomvc-app-css` against the package's
hash, with its notice in `samples/LICENSES.txt`. The vendored-module check covers the two CSS
modules with no change. Item 3 also checks: each styled sample's CSS reaches the frame (a
computed style of a known element), in the light and the dark scheme; each styled sample's text
has the contrast §4.6 gives, in both schemes; no styled sample scrolls sideways in a 320 px wide
frame; the frame of a program with an empty pane has no style sheet; an edit in the CSS pane
reaches the frame and the program keeps its state, an emptied pane removes the style sheet, and
an edit of the source restarts the program with the CSS; the CSS pane highlights CSS; a link restores the source, the CSS and the
platform; and an `@import` from another origin applies in the frame.

*Amended 2026-10-16, issue #171* (§4.6). Item 2 also checks: the page has an `<a>` element, not
a comment, for `vendor/LICENSES.txt` and for `samples/LICENSES.txt`, and each link opens a new
tab; a link with an empty `css=` opens no program, as one with an empty `code=` does; and the
`aria-controls` of each tab names an element of the page, the same one that its data attribute
names. Item 3 also checks: the note's two links open a new tab, and the site serves each file.

*Amended 2026-11-04, issue #1903* (§4.3, §4.5). Item 2 also checks: each sample's id is well
formed, unique and not `shared`, and each of the four ids that shipped still names a sample; and,
on the beni build of `playground/src/` (`page_test.mjs links`), a short link's round trip, the
sample and the note for a fragment with no program, the same answer as `URLSearchParams` gives,
and that a fragment with `code` is not a short link. Item 3 also checks: a
choice in the sample list sets the address to that sample's short link and adds no history
entry; a page opened with `#sample=ball-machine` opens the ball machine, with its modules, its
focused module and its CSS; an unknown id opens the first sample and says so; an edit clears the
short link; and **Share** copies the short link for an unchanged sample and the code link after
an edit.

A test compares every file of the output tree and both streams byte for byte, and the exit code.
It does not compare the persistent cache's directory, `.beni-cache/`, whose keys name the
compiler that wrote them, and it does not compare empty directories. The Node driver writes
back each file a run made or changed and deletes each file a run removed, so the other copy
holds what the run left. No test reads a cache that the compiler with no threads wrote: the
native one shares the threaded one's build id (`fast-compiler.md` §10), so the byte-identity
tests are what keeps their entries the same.

*Why the gates do not run the shipped binary.* The LLVM build of the `.wasm` is about 90 s of
single-threaded compile after each edit under `src/` (§7.1), about nine times the gates' time.
The gates use the self-hosted `.wasm` on two small scenarios and the native
single-threaded compiler on the remaining guarded code. Every test has the same
120-second hang guard. The shipped binary is proven by `test-playground`.

*Amended 2026-10-15, after review.*

- **`test-playground` runs in CI on every pull request**: the `playground` job of `ci.yml`,
  which the `check` guard needs, so a byte of difference blocks a merge.
- **The printing-program test asserts the profile's counters** (`--self-profile`): the `.wasm`
  loaded the embedded checked core (`embedded_modules` as the native compiler's, above 0) and
  checked one module (§2.1).
- **`test-playground` runs the page's own commands**: each `run/`, `browser/direct/` and sample
  program is built as the page builds it (no cache, no source maps, JSON diagnostics), with the
  cache and source maps, and with `--release`; each `check/bad/` program is checked in both
  renderers; the TodoMVC dumps take `--diagnostics=json`. On 2026-10-15 that was 786 programs and
  2 118 commands.
- **The sweep test.** `test-playground` builds six `browser-direct` programs with `--release` and
  `--self-profile` on both compilers and asserts the same `spec_points_to_sweeps`
  (`fast-compiler.md` §10, *The word size*). It failed on the old code (89 against 99 on
  `KeySubscription`) and passes now.

*Amended 2026-11-01, issue #1573.* Item 4 runs a **hand-picked set** of programs, not every
program of the corpus. The whole corpus was about 930 programs and 2 600 commands, each a Node
process that compiles the 13.8 MB module, with the native compiler beside it: 12 minutes of
processor time, and 14 minutes of the `playground` job on a CI runner, the longest job of every
pull request. The owner asked for seconds. Each program in `tests/blackbox/playground_test.zig`'s
list reaches something that a wasm32 build by LLVM at `ReleaseSmall` can write differently: the
page's samples, number text and numeric edges, 32-bit hashing, Unicode text, `Dict` order, a deep
alias chain and deep recursion, the release optimiser, schemas, markup, both browser platforms,
diagnostics, and TodoMVC with its dumps. The sweep test stays as it is. A defect that only one
program of the corpus shows on the shipped binary is no longer found before a merge; the
self-hosted `.wasm` in the gates (item 1) and the native corpus still run.

*Why Node runs the `.wasm` with `--liftoff-only`.* V8 compiles a hot function a second time with
TurboFan, on background threads. For one short compile that costs more than it saves: the
`ReleaseSmall` build of a printing program cost 2.6 billion instructions with tiering and 1.0
billion with Liftoff alone. A page keeps its `WebAssembly.Module`, so it pays the tier-up once.

## 7. Measurements

Measured on 2026-10-15 on an AMD Ryzen 7 3700X (16 threads), Linux, while other builds ran
on the machine. Every time below is a wall-clock time, so it moves with load; the run counts
are given.

### 7.1 Size, and the optimisation mode

Both builds by LLVM, from the same sources. The `ReleaseFast` build keeps its DWARF sections
(42 632 557 bytes); the table gives it without them, as it would ship.

| Build | Raw bytes | gzip -9 | brotli -q 11 | Code section | Data section |
|---|---:|---:|---:|---:|---:|
| `ReleaseSmall` (shipped), first measurement | 8 556 880 | 2 984 174 | 2 146 575 | 4 301 790 | 4 247 601 |
| `ReleaseFast`, no debug sections, first measurement | 13 354 953 | 4 068 454 | 2 708 121 | 9 103 696 | 4 245 381 |
| `ReleaseSmall` (shipped), 2026-10-15 after the review | 8 742 821 | 3 046 882 | 2 185 033 | 4 341 791 | 4 393 553 |

The first two rows are from the first pull request's sources. The size grows with `master`: the
third row is the same build after a merge of `master` and the review's fixes, measured again.

The data section is half of the shipped file: the embedded `core/`, the platforms and the
checked core (§2.1). The module asks for 1 107 pages (69.2 MiB) of initial memory, 1 108 after
the review, most of it the 65 MiB stack of §2.3, and sets no maximum.

Speed in Node 24.19, with one `WebAssembly.Module` and 12 compiles of TodoMVC
(`bench/todomvc/apps/beni/Sandbox.beni`, 298 lines) on new instances, as the page does, two
processes for each build:

| Build | First compile | Compiles 2 to 12 |
|---|---:|---:|
| `ReleaseSmall` | 162 ms, 162 ms | 32 to 54 ms |
| `ReleaseFast` | 230 ms, 223 ms | 26 to 46 ms |

**Decision: `ReleaseSmall`.** It is 21% fewer bytes after brotli, its first compile is faster
(V8 compiles less code), and later compiles are as fast within the noise of these runs.

The LLVM compile of the `ReleaseSmall` `.wasm` took 93 s of CPU on one thread (one
measurement).

### 7.2 Compile time in Chrome

Chrome 153.0.8010.36, headless, the site served from 127.0.0.1, measured by
`bench/playground/chrome.mjs`: three page loads, 10 compiles of TodoMVC in each, each with a
different trailing comment. A compile time is the worker's: a new instance, the build, and the
output read back.

| | Load 1 | Load 2 | Load 3 |
|---|---:|---:|---:|
| Compiler loaded (fetch and `WebAssembly.compile`) | 99 ms | 121 ms | 91 ms |
| First compile (the counter sample) | 173 ms | 201 ms | 183 ms |
| TodoMVC, first compile | 69 ms | 74 ms | 73 ms |
| TodoMVC, median of 10 | 38 ms | 37 ms | 37 ms |
| TodoMVC, fastest of 10 | 34 ms | 34 ms | 33 ms |
| The printing sample | 9 ms | 9 ms | 9 ms |

In each load the counter's frame loaded its program, and the printing sample's frame printed
its 11 lines to the page.

*Measured again on 2026-10-15, after the review*, on the page that ships: the second pull
request's editor, its vendored modules (§4.2) and a merge of `master`. The table above came from
the first pull request's page, whose text area the script drove, and the script no longer ran on
the editor; it now opens each program from a link that `share.js` makes and types as a person
does. Each scenario opens a page of its own, so each first compile includes V8's first tier-up.
Chrome 153.0.8010.36, three runs, 10 TodoMVC compiles in each:

| | Run 1 | Run 2 | Run 3 |
|---|---:|---:|---:|
| Compiler loaded (fetch and `WebAssembly.compile`) | 60 ms | 82 ms | 71 ms |
| Editor on the page, from the start of the navigation | 238 ms | 507 ms | 467 ms |
| First compile (the counter sample) | 173 ms | 165 ms | 168 ms |
| The counter built, from the start of the navigation | 760 ms | 1 011 ms | 979 ms |
| TodoMVC, first compile on its own page | 226 ms | 217 ms | 214 ms |
| TodoMVC, median of 10 (edits typed in the page) | 38 ms | 37 ms | 36 ms |
| TodoMVC, fastest of 10 | 33 ms | 33 ms | 32 ms |
| The printing sample, first compile on its own page | 99 ms | 95 ms | 98 ms |

In each run the printing sample's frame printed its lines.

### 7.3 The cost in the gates

The tests of §6 in `zig build gates`, in instructions (the budget's unit, 4 300 million a
test): the WebAssembly compiler on a printing program, 3 579 million; on the diagnostics,
2 700 million; the native compiler with no threads, 927 to 2 568 million a test. The
self-hosted `.wasm` and the native compiler with no threads each add one compile of the
compiler to the gates, in seconds, on cores the rest of the gates leave free.

*Measured again on 2026-10-15, after the review and a merge of `master`*, each test twice: the
WebAssembly compiler on a printing program 3 676M and 3 681M (it now writes a `--self-profile`
trace too, §6), on the diagnostics 2 670M and 2 743M, both counted on the grant's own meter
(§6); the native compiler with no threads 932M to 2 770M a test, and 2M for the `serve`
refusal.

## 8. Known limits

**The engine's stack bounds the nesting depth.** §2.3: a WebAssembly function's frames are on
V8's stack, about 1 MB, and the page cannot make it larger. A native compiler accepts an
expression `Parse.max_depth` (4096) levels deep and refuses a deeper one with
`nesting_too_deep`. The WebAssembly compiler in a page stops at a smaller depth, with V8's
`RangeError: Maximum call stack size exceeded`, which the page shows as "the compiler ran out of
stack".

Measured in Chrome 153 (§7.2), in the page's worker: a call `f (f (… 1))` 606 levels deep
compiles, and 607 levels run out of stack. *Measured again on 2026-10-15, after the review*, on
the page that ships: 790 levels compile and 791 run out of stack, in three runs of
`bench/playground/chrome.mjs`; the compiler's frames changed with `master` in between. The native compiler builds the same shape 4 000
levels deep (`abuse_test.zig`). Three page loads gave the same depth. A program a person
writes rarely nests a few hundred levels; a long operator chain does, because the parser
nests one level per operator (`x + x + … + x`).

**A program that does not stop holds its frame.** The compiled program runs in the output frame,
not in the worker, and nothing bounds its time. In Chrome the sandboxed frame has a process of
its own (Chrome isolates sandboxed frames; the page tests attach to it as a separate target),
so the page and the editor go on, and the next build replaces the frame. Where a browser keeps
the frame in the page's process, a loop in the program also stops the page. A program that
prints in a loop grows the console only to its last 2 000 pieces of output.

**A module that does not load stops the page.** If a module of the page does not load (the
site lacks a file, or the network failed), the page's own code never runs; a listener in
`index.html` then says in the status which file did not load. Every file the page loads is a
file of the site (§4.2).

**One browser is tested.** Chrome 153 runs every test of §6 and every measurement of §7. Firefox
and Safari are not tested: a module from a `blob:` URL in an opaque-origin frame, and 69.2 MiB
of initial memory per compile, freed when the garbage collector runs, are the parts most likely
to differ there, the second on a phone with little memory.

## 9. Build and deploy

`zig build playground` writes the static site to `zig-out/playground/`: `index.html`, the
JavaScript of §3 to §5, the samples of §4.3, and `beni.wasm` (`ReleaseSmall`, LLVM). Every URL in it is relative, so
the directory works under any path, `/beni/playground/` included. No workflow in this repository
deploys it: the site build of issue #127 runs the step and copies the directory (§1).

**Later.** One instance kept alive between compiles, with the on-disk caches of
`fast-compiler.md` §8 in its memory file system, makes a compile after an edit incremental. It is
not part of either pull request.

*Amended 2026-10-19 (issue #423, the retirement of `browser-direct`):* the page's platforms are
`browser-tea` (a page), `browser-inline` (a page compiled whole, new) and `node` (a program that
prints). The samples that drew in the frame moved with their files to
`playground/samples/browser-tea/`, and `zig build playground` writes TodoMVC there. A shared link
naming `browser-direct` opens on the default platform, as any link naming a platform the page does
not offer does. `zig build test-playground` builds `browser/tea/` pages for `browser-tea` and
`browser/inline/` pages for `browser-inline`, and TodoMVC for `browser-tea`.

## 10. The page's own code in beni

*Specified 2026-11-04, issue #142; not built.* The page's own JavaScript, nine files on `master`
`99355536bc`, becomes beni. This section says which file becomes what, which part of `wasi.js` is
privileged, and which host APIs `core/` and the platforms do not wrap yet. Each gap has its own
issue. The choices that are the owner's are in §10.9; a part that depends on one waits for the
answer.
CLAUDE.md rules 6, 7, 9 and 10 apply to every step: only a platform or `core/` uses `Js`, a gap
is filled inside the wall for every program, each host failure is a typed error or a crash, and a
wall is reported, not worked around.

*Amended 2026-11-04, the owner's decision* (Cesar Canassa, dashboard questions `playground-beni-q3`
and `q4`, 19:00:39 and 19:00:48 UTC): **"replace CodeMirror with a simple editor written in beni
itself"**. CodeMirror leaves the playground. `editor.js`, `syntax.js` and `positions.js` become the
beni editor of §10.10, and `vendor/` goes when that editor replaces CodeMirror. No library then
owns an element of the page, and the page imports no third-party module, so #1881, #1882 and #1893
are closed as not planned. The text below is amended where it named CodeMirror.

### 10.1 What changes, and what stays JavaScript

| File | Lines | Bytes | brotli -q 11 | Becomes |
|---|---:|---:|---:|---|
| `wasi.js` | 750 | 27 722 | 6 413 | beni of the page over a typed WebAssembly module (§10.5) |
| `page.js` | 447 | 16 725 | 4 931 | the page program, a Tea program (§10.2) |
| `syntax.js` | 270 | 9 750 | 2 815 | the beni editor's tokenizer (§10.10) |
| `editor.js` | 152 | 6 592 | 1 996 | the beni editor (§10.10) |
| `frame.js` | 138 | 6 533 | 2 254 | the frame runner, a beni program (§10.3) |
| `share.js` | 155 | 5 987 | 1 915 | beni of the page |
| `worker.js` | 66 | 3 047 | 1 083 | the compiler worker, a beni program (§10.3) |
| `positions.js` | 31 | 1 260 | 554 | part of the beni editor (§10.10) |
| `srcdoc.js` | 21 | 1 022 | 461 | nothing: it goes with `frame.js`, because the frame loads `frame.html` from a URL (§10.3, `q6`) |
| **Total** | **2 030** | **78 638** | **22 422** | |

Measured on 2026-11-04 with Node 24.19's `zlib` at brotli quality 11, one file at a time.

*Amended 2026-11-04 (#1903):* short links for the samples, `#sample=<id>`, change `share.js`,
`page.js` and `samples/index.json` (§4.3, §4.5). The beni `share.js` and `page.js` (§10.7, steps
3 and 7) carry them.

*Amended 2026-11-04, #1903 as built* (Jayson Reis: "write it in beni already to avoid introducing
more js"): the short link needs no host API of §10.6, so it is beni already:
`playground/src/Share.beni` (§4.5, *The short link is beni*). `share.js` gets no new code. Step 3
adds the code link to that module, and step 7 moves the rest of the feature from `page.js` into
the page program: the id of the unchanged sample, and the calls when a sample loads, at **Share**
and when the page opens.

**`vendor/`**, the 19 CodeMirror modules (§4.2), stays until the beni editor lands. Issue #142 kept
it. *Amended 2026-11-04:* it then goes, with `vendor.sh`, `vendor/SHA256SUMS` and
`vendor/LICENSES.txt` (§10.10).

One part stays JavaScript:

- **The load-error listener in `index.html`** (10 lines of code, `index.html:45-54`; §8 *A
  module that does not load*). It runs before any module of the page, and a module that does not
  load cannot report its own failure. It is part of the HTML document, not a module. This is the
  one piece of hand-written JavaScript that this section keeps, and it needs the owner's word
  (rule 10). Without it, a module that does not load leaves the status at "Loading the
  compiler…". *Amended 2026-11-04, the owner's decision* (Cesar Canassa, `playground-beni-q7`,
  19:31:48 UTC): "Keep the listener as the one named JavaScript exception, listening on window
  in the capture phase." It stays as `addEventListener("error", …, true)` on `window`, and it is
  the page's one JavaScript exception.

The import map goes with `vendor/`: it names only the CodeMirror modules (*amended 2026-11-04*;
it stayed, as JSON, before the decision of §10's first amendment).

### 10.2 The platform of the page

Issue #142 names `browser-direct`, after §1's launch decision. The owner retired that platform on
2026-10-19 (#423): "browser-inline (#295) replaces it". It was not renamed. Today
`browser-inline` depends on `html` alone and has no `Http`, `Time`, `Dom` or `core/Task`
(`browser-inline.md` §1). `browser-tea` has them (`platforms/browser-tea/beni.json`).

Which platform the page builds for was the owner's decision (§10.9, `playground-beni-q1`), and
the amendment below records it. Both platforms give `Tea.element`, `Cmd` and `Sub` with the same
signatures (`browser-inline.md` §1), so the page can move to `browser-inline` later with no change
to its update loop.

*Amended 2026-11-04, the owner's decision* (Cesar Canassa, dashboard question
`playground-beni-q1`, 18:48 UTC): **`browser-tea`**. The page is a `Tea.element` program that
uses `Http`, `Time`, `Dom` and `Browser.Navigation` as they are. Only the gaps of §10.6 need new
APIs. The other choice, `browser-inline`, was not taken.

### 10.3 Three programs, in three realms

The page runs code in three realms. Each becomes a beni program:

| Realm | Today | Becomes | Platform |
|---|---|---|---|
| The page | `page.js`, `editor.js`, `syntax.js`, `positions.js`, `share.js`, `srcdoc.js` | a Tea program, `playground/src/` | `browser-tea` (§10.2) |
| The compiler's worker | `worker.js`, `wasi.js` | a dedicated worker program | `Browser.Worker` (#1297, `workers-api.md` §1 on PR #1304) |
| The output frame | `frame.js` | the frame runner | §10.4's platform |

- **The worker.** The workers delivery (#1612) owns how a page opens a worker and how they
  exchange messages. The playground uses that API and adds none of its own. Until #1297 lands,
  `worker.js` stays as it is, and the WASI host in beni (§10.5) runs from it.
- **The frame runner.** The page puts it in the frame's `srcdoc`, as it puts `frame.js` there
  today (§5). It is built with `--release` into one module and inlined as a module script. The
  rest of §5 does not change: the sandbox, the opaque origin, the files as JSON, the CSS of §4.6
  and the messages to the parent.

  *Amended 2026-11-04, the owner's decision* (Cesar Canassa, `playground-beni-q6`, 19:31:35 UTC):
  "Frame from a URL. Post with '\*', check event.source on both sides, never event.origin, and tag
  each run with an id." So the frame has no `srcdoc`, and the owner's rule of 2026-09-29 that
  closed `srcdoc` (`language.md` §11.5) stays as it is:
  - The frame loads `frame.html` from the site, with `sandbox="allow-scripts"` and no
    `allow-same-origin`, so its origin stays opaque (§5). `frame.html` holds the runner.
  - The frame posts `ready` to its parent when it listens. The page then sends the files and the
    CSS pane's text with `postMessage(…, "*")`. The frame makes its blob URLs from them, in its
    own origin, as `frame.js` does now.
  - Each side takes a message only when `event.source` is the window it expects: the page takes
    only its frame's `contentWindow`, and the frame only `parent`. Neither side reads
    `event.origin`, which is `"null"` for a sandboxed frame.
  - Every run has an id, and every message of the run carries it. A message with the id of an
    older run is dropped, so a slow frame of an earlier build cannot write into the console of a
    newer one.
- **The build.** `zig build playground` builds the three programs with the native compiler of the
  same build and writes them into the site, beside `beni.wasm`. The site stays static (§9).
- **The format gate** (`beni-fmt-check`) covers every `.beni` file under `playground/`, as it
  covers the samples now (§4.3).

### 10.4 The playground's own platform

`playground/platform/` is a platform package (`"platform": true`) that ships with the site, not in
the beni binary. It is layered on `browser` (`boundary.md` §9.1, the `"platforms"` key), and the
build names it with `--platform=<dir>` (`boundary.md` §5.3, *How a platform is located*). It has no
Zig, so the beni binary does not change for it.

It holds only what is specific to the site:

- **The frame runner's host parts** (#1894): the runner's `main`, blob URLs in the frame's own
  origin, a dynamic `import` of one, the `process` stand-in of §5 step 2, and the wrapper of
  `console`. The rewrite of import specifiers is ordinary beni over strings.

A host API that every program can use does not go here: it goes to `core/` or to a platform that
ships (§10.6), so that the playground fills a gap for every program, not only for itself (rule 7).
`skills/beni/` does not describe this platform, because no developer builds on it.

*Amended 2026-11-04:* this section also held the CodeMirror binding (#1893) and an adapter that ran
a beni tokenizer in CodeMirror's `StreamLanguage`. The beni editor (§10.10) replaces both, and the
page needs nothing of this platform: only the frame runner uses it. So it is layered on `browser`,
not on `browser-tea`.

### 10.5 The WASI host

Which part of the host is beni of the page, and which part is privileged, was the owner's
decision (§10.9, `playground-beni-q2`).

*Amended 2026-11-04, the owner's decision* (Cesar Canassa, dashboard question
`playground-beni-q2`, 18:51 UTC): **the recommended split**, a typed WebAssembly module and a host
in beni. The module (#1883) wraps only compile, instantiate, memory and traps, each failure a
typed error (rule 9), and every program gets it. The file system in memory and the 46 WASI
functions are ordinary beni in `playground/`. The other choice, a privileged WASI host with one
`run`, was not taken.

The split:

- **Privileged: a typed WebAssembly module** (#1883), next to `Binary` (#1278). It compiles a
  module from bytes, makes an instance with imports that are beni functions, reads the exports
  (a function, or a memory as a `Binary` buffer), calls a function, and lets an import stop the
  instance. Each failure is typed: `CompileError`, `LinkError`, a trap (`RuntimeError`), and the
  engine's stack exhaustion with §3 rule 7's exact messages.
- **Beni of the page: everything else.** The files and directories, the file descriptors, every
  one of the 46 functions of WASI preview 1, `directoryOf`, `filesOf` and `run`.

§3's rules keep their meaning:

1. One instance per compile, and the project directory is the first preopen, fd 3, named `.`.
2. Standard input is empty. The two streams are captured. A positional read or write on them is
   `ESPIPE`.
3. Every function of WASI preview 1 exists. One with no meaning in memory returns `ENOSYS`.
4. A position or a size past 1 GiB is `EFBIG` or `EINVAL`. So every offset and size that the host
   keeps fits in an `Int` exactly.
5. No function of the host catches. An unforeseen failure crashes the compile (rule 9).
6. `proc_exit` stops the instance through the module's stop, not by a thrown object that beni
   catches.
7. A trap and an exhausted engine stack end that compile, and `run` returns them as its `crash`.

**64-bit values.** WASI passes offsets, sizes, rights, cookies and times in nanoseconds as
`i64`. The host takes them as `Binary.U64`, word pairs (`webgpu.md` §3.1), and converts one to an
`Int` only with a check: past the bound of rule 4 it is `EFBIG`, as today. A time is kept as its
word pair, so `path_filestat_set_times` and `fd_filestat_get` give back exactly what the
compiler set.

**The host APIs inside it:** UTF-8 for paths (#1884), random bytes for `random_get` (#1888), and a
monotonic clock for clock id 1 (#1889).

**The tests run the host that the page runs** (§3). `tests/wasm/beni.mjs` (§6 item 1) loads the
beni build of the host, made for `node` by the compiler under test. So the host must use no
API that only a browser has.

### 10.6 The host APIs that `core/` and the platforms do not wrap

Each row is a gap: no module of `core/` or of a platform gives it on `master` `99355536bc`.

| Host API | Where the page uses it | Proposed home | Issue |
|---|---|---|---|
| A Web Worker and its messages | `page.js:40`, `worker.js` | `Browser.Worker` | #1297 (#1612) |
| Bytes, `ArrayBuffer`, `DataView`, 64-bit word pairs | `wasi.js`, `share.js`, `worker.js` | `Binary` | #1278 (`webgpu.md` §3.1) |
| WebAssembly: compile, instantiate, memory, traps | `wasi.js:724-740`, `worker.js:26-33` | `core/`, next to `Binary` | #1883 |
| UTF-8 between `String` and bytes, fatal decode | `share.js:53-90`, `wasi.js:84-87`, `worker.js:17` | `core/`, on `Binary` | #1884 |
| Base64 and base64url (`btoa`, `atob`) | `share.js:67-91` | `core/`, ordinary beni | #1885 |
| `CompressionStream`, `DecompressionStream` | `share.js:98-155` | `browser` and `node` | #1886 |
| A response body as bytes | `worker.js:26-33` | `Http.expectBytes` | #1887 |
| Random bytes (`crypto.getRandomValues`) | `wasi.js:379-384` | `browser` and `node` | #1888 |
| A monotonic clock (`performance.now`) | `wasi.js:376`, `worker.js:27,46` | `core/Clock` | #1889 |
| `sandbox` on `iframe` (*amended 2026-11-04*: `srcdoc` is not needed, §10.3) | `page.js:154-166` | the `html` vocabulary | #1890 |
| Messages between a page and its frame | `page.js:234,296-312`, `frame.js:19,131-133` | `browser` | #1891 |
| The clipboard (`navigator.clipboard.writeText`) | `page.js:415-430` | `browser` | #1892 |
| A scroll into view with `block` and `inline` options | `page.js:327`, the beni editor | `Dom` | #1896 |
| The selection of a text field, in code points | the beni editor (§10.10) | `Html`, `Dom` | #1900 |
| Insert text that the browser's undo keeps (`execCommand("insertText")`) | not needed: `q8` drops `execCommand` (§10.10) | — | none |
| Blob URLs, a dynamic `import`, the `process` stand-in, `console` | `frame.js` | §10.4's platform | #1894 |

`boundary.md` §9.13 lists the failures that each platform row must type.

*Amended 2026-11-04:* three rows left this table with CodeMirror (§10.10), each closed as not
planned: an element whose inside a library owns (#1881), a third-party ES module from beni (#1882)
and the CodeMirror 6 API (#1893). The selection row (#1900) and the conditional `insertText` row
came with the beni editor.

These are wrapped already, and the page uses them as they are:

| Host API | Where the page uses it | Module |
|---|---|---|
| `fetch` of text (the samples, the frame runner) | `page.js:64-68` | `Http.get` with `expectString` |
| A timer (the compile 300 ms after an edit) | `page.js:116-126` | `Time.sleep`, a command with `Cmd.Restart` (`boundary.md` §9.8.2) |
| The URL fragment and `history.replaceState` | `page.js:118,243,413` | `Browser.Navigation.currentUrl`, `replace` |
| `JSON.parse`, `JSON.stringify` | `page.js`, `share.js`, `srcdoc.js` | `Json` |
| `URLSearchParams` (the fragment's fields) | `share.js:18,34` | `Url.percentEncode`, `Url.percentDecode` |
| Code points against UTF-16 units | `positions.js` | `String`, `Char.toCode` |
| Key events with `preventDefault` (Tab, Shift+Tab) | the beni editor | `Html.key`, `Html.shiftKey`, `Html.preventDefault` |
| A `textarea` whose value the program sets, with its caret kept | the beni editor | the `value` attribute (`stateful`), `rows`, `spellcheck` |
| A mark's tooltip | the beni editor | the `title` attribute |
| Wall-clock time (`Date.now`) | `wasi.js:106` | `Clock.now` |

### 10.7 The order of the work

One pull request per gap or per file, smallest first. A file goes when every gap it needs has
landed. After each pull request the page works and every test of §6 passes.

1. `srcdoc.js`: no gap. *Amended 2026-11-04 (`q6`, §10.3):* it does not become beni. The frame
   loads `frame.html` from a URL, so `srcdoc.js` goes with `frame.js` in step 4.
2. `syntax.js`: no gap. It becomes the beni editor's tokenizer (§10.10), with the Elm mode's rules
   in beni too. Until the editor lands, a few lines of `editor.js` run it in CodeMirror's
   `StreamLanguage`: they keep the beni state in the stream's state object and move the stream's
   position. Those lines are JavaScript, and they go with `editor.js` in step 7. The vendored Elm
   mode is then used by nothing.

   *As built, 2026-11-04:* `playground/src/Syntax.beni`. `line` takes a state and one line and
   gives the line's pieces, each a text and a name (`""` for none), and the state after the
   line; the pieces of a line together are the line. The Elm mode's file stays in `vendor/`
   until step 7, because `vendor/LICENSES.txt` holds the MIT notice that its translation
   needs; step 7 moves that notice into the site's other licence file. Checked against
   `syntax.js` with the Elm mode in Node 24.19: the same named pieces on every `.beni` file of
   the repository (4 428 files, 319 194 lines, 1 327 812 pieces) and on 30 000 random lines of
   the grammar's hard cases. It takes about twice as long: 2.9 ms against 1.4 ms for TodoMVC
   (298 lines), and 32 ms against 18 ms for `core/Schema.beni` (4 251 lines). The page loads
   `Syntax.mjs` and four modules of `_core/` from the development library build, 30 821 bytes
   raw and 6 243 at brotli quality 11, in place of `syntax.js` and the Elm mode, 14 071 and
   3 841. A release build of the same would be 10 090 and 3 543 (§10.8, #1901).
3. `share.js`: #1278, #1884, #1885, #1886.
4. `frame.js` and `srcdoc.js`: #1890 (`sandbox` only), #1891, #1894: the frame from a URL, with
   the messages of §10.3's `q6` amendment.
5. `wasi.js`: #1278, #1883, #1884, #1888, #1889.
6. `worker.js`: #1297, #1887, #1889.
7. `page.js`, `editor.js` and `positions.js`, in one pull request: the page program with the beni
   editor (§10.10), and `vendor/` goes. #1890, #1891, #1892, #1896, #1900, and the answer to
   `playground-beni-q5`.

*Amended 2026-11-04*, after the decision of §10's first amendment. `positions.js` was first and
`editor.js` fifth. The beni editor counts code points, as the compiler does, so the conversion of
`positions.js` to UTF-16 units moves into the selection wrapper (#1900). The editor is part of the
page's view, so the editor and the page move in one pull request.

### 10.8 During the move

- **The JavaScript that remains calls the beni that has landed.** A file that is still JavaScript
  imports the beni modules from a development `--library` build of `playground/src/`
  (`backend.md` §2), which keeps the source field names of what it exports (`boundary.md` §4,
  *What JavaScript may read of a beni value*). `zig build playground` writes that build into the
  site. *Amended 2026-11-04:* a `--release --library` build is about a third of the size (§10.7,
  step 2, *As built*), but it renames its exports, so no hand-written file can import them
  (#1901). The library build also writes `_core/Task.mjs` and `_platform/_browser/Rt.mjs`, which
  no module of the page imports and the page never loads.
- **Defects.** In beni, a failure that no wrapper foresaw is a defect of the program
  (`boundary.md` §9.8.14). When `page.js` goes, its `error` and `unhandledrejection` listeners
  (`page.js:33-38`) go with it, and the platform's defect screen shows such a failure. A crash of
  the compiler (§3 rule 7) and a defect of the worker (§4.4) stay values that the page shows.
- **The tests check the beni build.** For a file that becomes beni, the checks of §6 item 2 run
  on its beni build. `tests/blackbox/playground_page_test.zig` builds `playground/src/` with the
  compiler under test, and `tests/wasm/page_test.mjs` imports the result, as the page does. The
  list of checks does not get shorter. The test scripts are tooling, not code of the page, so they
  stay JavaScript. The Chrome test (§6 item 3) does not change, and each pull request that changes
  the page runs it.
- **Measurements, before and after.** Each pull request that moves a file measures, on one
  machine and in one session: the bytes, raw and at brotli quality 11, of each file that the site
  serves except `beni.wasm` and `vendor/` (the baseline is §10.1's table), and the load and
  compile times of §7.2 with `bench/playground/chrome.mjs`. The editor's pull request also counts
  `vendor/`, which it removes (§10.10). A beni page that is slower than the
  JavaScript one is a finding to report, not a reason to keep JavaScript (rule 10).

### 10.9 The owner's decisions

Asked on the dashboard on 2026-11-04. Each part that depends on an answer waits for it.
*Amended 2026-11-04:* `playground-beni-q1` is decided (§10.2): `browser-tea`. `playground-beni-q2`
is decided (§10.5): a typed WebAssembly module and a host in beni. `playground-beni-q3` and `q4`
are decided (§10's first amendment): a simple editor written in beni replaces CodeMirror. That
decision asked one more question, `playground-beni-q5` (§10.10). *Amended 2026-11-04:* every
question of this section is decided. `q5` is withdrawn and `q8` decides undo; `q6`, `q7` and `q8`
are recorded in §10.3, §10.1 and §10.10.

| Question | Options | Recommended |
|---|---|---|
| `playground-beni-q1`: the platform of the page (§10.2) | `browser-tea`; `browser-inline` | `browser-tea`: it has `Http`, `Time` and `Dom` today, and the page can move later. **Decided: `browser-tea`** (Cesar Canassa, 2026-11-04) |
| `playground-beni-q2`: the split of the WASI host (§10.5) | a typed WebAssembly module and a host in beni; a privileged WASI host with one `run` | the WebAssembly module: every program gets WebAssembly. **Decided: the WebAssembly module and a host in beni** (Cesar Canassa, 2026-11-04) |
| `playground-beni-q3`: an element whose inside a library owns (#1881) | a new markup form; static elements by id in `index.html` | the markup form: every widget library needs it. **Decided: neither — "replace CodeMirror with a simple editor written in beni itself"** (Cesar Canassa, 2026-11-04) |
| `playground-beni-q4`: a third-party ES module from beni (#1882) | `Js.module` of a bare specifier that the platform's `beni.json` lists; a sibling `.js` file | `Js.module`: no new JavaScript. **Decided: as `q3`** (Cesar Canassa, 2026-11-04) |
| `playground-beni-q5`: undo and redo in the beni editor (§10.10) | the browser's own undo, with `execCommand("insertText")` for the editor's own insertions; a history that the editor keeps in beni | the browser's undo. **Withdrawn:** its reason was wrong, so `q8` replaces it (§10.10, *Undo*). The owner answered it at 19:31:17 UTC, before he read `q8`: "Browser undo with execCommand("insertText"), as prism-code-editor does"; `q8` decides |
| `playground-beni-q6`: how the frame gets its program (#1890) | a frame loaded from a URL, with the files by `postMessage`; a typed `srcdoc` in `html` | the frame from a URL: the owner's rule that closed `srcdoc` (`language.md` §11.5, 2026-09-29) stays. **Decided: the frame from a URL**, with `"*"`, `event.source` and a run id (Cesar Canassa, 2026-11-04; §10.3) |
| `playground-beni-q7`: the load-error listener of `index.html` (§10.1) | keep its 10 lines of JavaScript; remove it | keep it: no beni module can report a module that does not load. **Decided: keep it, as the one named JavaScript exception, on `window` in the capture phase** (Cesar Canassa, 2026-11-04; §10.1) |
| `playground-beni-q8`: undo and redo in the beni editor, replacing `q5` (§10.10) | a history for each file in beni; the browser's one history for the whole page | the history in beni: it keeps §4.2's per-file undo (amended 2026-10-26). **Decided: a history in beni, one for each file**, with no `execCommand` (Cesar Canassa, 2026-11-04; §10.10) |

### 10.10 The beni editor

*Specified 2026-11-04, after the owner's decision on `playground-beni-q3` and `q4`* (§10's first
amendment). "Simple" is the owner's word. The editor keeps what a person needs to write a program
and to read the compiler's answer. It drops the rest of what CodeMirror gave. It is beni of the
page, on `browser-tea`, and replaces `editor.js`, `syntax.js` and `positions.js`.

**The form.**

- Each editor is a `<textarea>` over a `<pre>` that shows the same text highlighted, with the same
  font, line height and padding. The text of the `textarea` is transparent, and its caret shows.
- The `textarea` grows to its text: `rows` is its count of lines, and it does not wrap
  (`white-space: pre` in `style.css`). So the pane scrolls the `textarea` and the `<pre>`
  together, and no code keeps two scroll positions in step.
- A gutter beside them shows one number for each line.
- Typing, paste, the selection and input methods are the browser's. `onInput` gives the new text
  (`Html.targetValue`). The `value` is the program's (`stateful`), so the caret stays where it is.

**What it keeps.**

| Today | In the beni editor |
|---|---|
| One editor for each source module and one for the CSS pane; a hidden tab keeps its text, undo history and diagnostics (§4.2, amended 2026-10-26) | The same. Each editor is its own keyed `textarea`, hidden and not removed |
| Line numbers | A gutter |
| beni highlighting, §4.2 *The grammar* | Every token class of §4.2, the Elm mode's included: names, a definition at the start of a line, types and constructors, numbers, characters, operators and brackets, strings with `${…}` and escapes, `\\` lines, comments and doc comments, the Unicode notation, `⊤` and `⊥`, keywords, `.field`, and the three modes of markup. All of it is beni (`playground/src/Syntax.beni`). The state goes from line to line, so an edit highlights again from its line only until the state is as it was |
| Diagnostics as lint marks, and the list under the editor | A mark under each diagnostic's span in its own module, with its title and message as the mark's `title`, and the same list. A click on one opens its file, selects its span (#1900) and scrolls it into view (#1896). A column counts code points, as the editor's text does |
| Tab inserts the indent unit | Tab inserts the file's unit (four spaces for beni, two for CSS) at the caret; with a selection over lines it indents each line. Shift+Tab removes one unit from the start of each line of the selection. beni refuses a tab character (`language.md` §2.1) |
| Undo and redo, for each file | A history in beni for each file, as `playground-beni-q8` decided (*Undo*, below) |
| The emitted JavaScript, highlighted, read-only | A read-only `<pre>` with line numbers, highlighted for comments, strings, numbers and keywords by a small beni tokenizer |
| The CSS pane, highlighted | Highlighted for comments, strings, numbers, at-rules and property names by a small beni tokenizer |
| One highlight style, from `style.css` | The same `--syntax-*` colours, in both schemes |

A tab character that a person pastes stays in the text. The compiler's `tab_in_source`
diagnostic marks it, as it marks any other error (`language.md` §2.1).

**Undo.** *Added 2026-11-04.* `playground-beni-q5` recommended the browser's undo, for "each file
keeps its own history". A test in headless Chromium 153 showed that reason to be wrong:

- After `insertText` "a1" in one `textarea` and "b1" in a second, an undo with the first focused
  took back "b1". The browser keeps one history for the whole document, not one for each field.
- After code set a field's value, an undo in that field changed nothing.
- An edit in a hidden field, shown again, was not the one that undo took back.

The runtime does not write a `value` that the field already shows
(`platforms/browser/Rt.beni:1746`), so typing alone keeps the browser's history. But a sample, a
link and any text that the editor inserts itself (Tab, Shift+Tab) clear it, unless the editor
calls `execCommand("insertText")`. That call is deprecated: where a browser answers `false`, the
wrapper's typed error is the answer to the key, and the editor must then set the value itself and
lose the browser's history at that edit. So `playground-beni-q8` replaces `q5`, and recommends a
history in beni: an undo and a redo stack of each file's text and selection, the keys Ctrl+Z,
Ctrl+Shift+Z and Ctrl+Y and their Cmd forms, and the `beforeinput` events `historyUndo` and
`historyRedo`, all handled by the editor, which sets the text and the selection itself. It needs
no deprecated call.

*Amended 2026-11-04, the owner's decision* (Cesar Canassa, `playground-beni-q8`, 19:32:46 UTC):
"History in beni, one per file. Cancel the undo keys and historyUndo/historyRedo beforeinput.
Record text plus selection, group typing, record once per IME composition, cap at about 1 000
entries. Drop execCommand. Add a two-file undo test." So:

- Each file keeps its own undo and redo history in the editor's model. An entry holds the text and
  the selection.
- The editor cancels the undo and redo keys (Ctrl+Z, Ctrl+Shift+Z, Ctrl+Y, and Cmd+Z and
  Cmd+Shift+Z) and the `beforeinput` events whose `inputType` is `historyUndo` or `historyRedo`,
  and applies its own history.
- A run of typing is one entry, not one for each key. An input method's composition records one
  entry, when it ends. A history holds at most about 1 000 entries; the oldest goes first.
- No `execCommand`. Tab and Shift+Tab set the text and the selection from the model.
- This replaces §4.2's undo (CodeMirror's `history` and its keys) only for the beni editor; a
  hidden tab keeps its history, as §4.2's amendment of 2026-10-26 says.

**What it drops**, each the author's reading of "simple", with what it would cost to keep:

- CodeMirror's search panel: the browser's own find searches the text of a `textarea`.
- The match of a bracket: a scan of the tokens around the caret, about 50 lines of beni.
- The closing bracket written as one types: a key handler of about 30 lines, which every undo
  then has to take back too.
- The highlight of the active line: about 10 lines, the caret's line in the gutter.
- The highlight of the matches of the selection: a search of the text on each move of the caret.
- The lint gutter: the marks and the list stay, so the gutter shows only line numbers.
- Several carets: a `textarea` has one selection, so this cannot come back on this form.
- CodeMirror's other keys.

**What goes with CodeMirror:** `vendor/` (19 modules of 1 344 418 bytes; with `SHA256SUMS` and
`LICENSES.txt`, 1 371 215 bytes raw and 294 035 at brotli quality 11, measured on 2026-11-04 one
file at a time), `vendor.sh`, the import map, the page's link to `vendor/LICENSES.txt`, and the
checks of §6 item 2 and item 3 that read the vendored files and their notice. The note keeps its
link to `samples/LICENSES.txt`. The MIT notice of `@codemirror/legacy-modes` moves into
`samples/LICENSES.txt`, or a licence file of its own, because `playground/src/Syntax.beni`
translates the Elm mode's rules (§10.7, step 2, *As built*).

**Tests.** §6 item 2's `syntax` check runs on the beni tokenizer, with its list of lines and names.
The Chrome test (§6 item 3) keeps every check of what the editor does: an error marked on its
text and listed, a click that selects it, Tab, a link that gives back the text, a hidden tab that
keeps its text. It types as a person does, through the DevTools protocol, as now. It drops the
checks of CodeMirror's own parts. *Added 2026-11-04 (`q8`):* a two-file undo test. Edit file A,
edit file B, then press the undo key with A focused: A goes back, and B does not change. A second
part runs the same with the browser's own undo command, which fires `beforeinput` with
`historyUndo`. It runs in the Chrome test (`test-playground-page`). happy-dom does not run it:
a key event there has no default action, so no key press edits a `textarea` or fires
`beforeinput`, and the gates run no page of the playground under happy-dom (§6 item 2 runs
modules under Node).

**Measurements.** The editor's pull request gives the page's bytes with `vendor/`, raw and at
brotli quality 11, before and after; the after bytes hold all the beni of the editor, its three
tokenizers included. It also gives `bench/playground/chrome.mjs`'s `editorReady` and TodoMVC edit
times before and after, and the time from a keystroke to the highlighted text, on TodoMVC
(298 lines) and on a file of 2 000 lines.
