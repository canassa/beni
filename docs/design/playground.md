# The playground — beni compiled to WebAssembly, in a page

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
   (a printing program on the `node` platform, `platforms/node/runtime.js`);
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
4. **Not a gate:** `zig build test-playground` runs the shipped `ReleaseSmall` `.wasm` (§7.1) on
   every program of `tests/corpus/run/` and `tests/corpus/browser/direct/`, and on TodoMVC, and
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

A test compares every file of the output tree and both streams byte for byte, and the exit code.
It does not compare the persistent cache's directory, `.beni-cache/`, whose keys name the
compiler that wrote them, and it does not compare empty directories. The Node driver writes
back each file a run made or changed and deletes each file a run removed, so the other copy
holds what the run left. No test reads a cache that the compiler with no threads wrote: the
native one shares the threaded one's build id (`fast-compiler.md` §10), so the byte-identity
tests are what keeps their entries the same.

*Why the gates do not run the shipped binary.* The LLVM build of the `.wasm` is about 90 s of
single-threaded compile after each edit under `src/` (§7.1), about nine times the gates' time.
The self-hosted build compiles in about 7 s, but its code is slow: under Node it spends about 3
billion instructions on a printing program and 5 to 7 billion on a `browser-direct` page, and the
budget of a test is 4.3 billion. So the gates run the self-hosted `.wasm` on the programs that fit
the budget, and the native single-threaded compiler on everything else, because it runs the same
guarded code at native speed. The shipped binary is proven by `test-playground`.

*Amended 2026-10-15, after review.*

- **The two `.wasm` gate tests have a budget of their own**, 6 000M (`wasm_test.zig`'s
  `wasm_budget_millions`). Most of their cost is fixed: Node, V8's compile of the self-hosted
  build's 18 MB code section, and that build's start on the embedded core and platforms. A
  one-line program costs 92% of what `run/Adt` costs, so no smaller input reduces it, and under
  the gates' 4 300M the margin was 17%. Jayson Reis decided the grant on 2026-10-15 (dashboard
  question `wasm-playground-q5`), with `test-playground` in CI; the budget was granted by Cesar on 2026-10-15 (dashboard question `wasm-playground-q7`).
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
