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
words, so the pack that the host's maker writes is correct on wasm32 (§6 proves it).

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
the page another, and the compiler's path in the page depends on a CDN. The compiler imports 34
WASI functions, about 20 of which a build calls, so the shim is small.

The rules:

1. **One instance per compile.** The page compiles the `.wasm` once to a `WebAssembly.Module`
   and makes a new instance, with new memory and a new file system, for each compile. Nothing
   survives from one compile to the next (§9 has the later step).
2. **The project directory is the first preopen**, file descriptor 3, named `.`. Zig's standard
   library takes the first preopen as the working directory on WASI, so `beni build Main.beni`
   finds `Main.beni` and writes `out/`.
3. **Standard input is empty. Standard output and standard error are captured** as bytes. A
   positional read or write on them returns `ESPIPE`, as POSIX does for a pipe.
4. **Every function the module imports exists.** One that the compiler needs and that has a
   meaning in memory is implemented: files and directories, reads and writes at a position or at
   the cursor, seeks, `stat`, directory listings, create, rename, unlink, remove, truncate, the
   clocks and `random_get`. One that has no meaning here (links, `poll_oneoff`) returns
   `ENOSYS`, and so does a call with arguments the shim does not implement.
5. **An error the shim did not foresee is a defect** (CLAUDE.md rule 9). The functions of the
   shim have no `catch`. A JavaScript exception inside a WASI call goes out of `_start`.
6. **`proc_exit` throws an `Exit` object** with the exit code. `run` catches `Exit` by
   `instanceof`.
7. **Two failures of the module end that compile, and only those two.** A trap
   (`WebAssembly.RuntimeError`: a failed safety check, an overflow of the shadow stack) and an
   exhausted engine stack (`RangeError`, §8). `run` catches each by `instanceof` and returns it
   as the compile's `crash`, with what the compiler wrote to stderr before it; the page shows
   it as a crash of the compiler, and the next compile makes a new instance (rule 1), so
   nothing of the failed one remains. Every other exception goes on up: in the page, the
   worker's `error` listener reports it as a defect of the playground.

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
A compile that starts while another runs waits for it, and only the newest waiting source is
compiled.

### 4.2 The editor (second pull request)

CodeMirror 6 from a CDN, every package at a pinned version, with a beni grammar for highlighting:
keywords, comments, strings, numbers, and the Unicode notation (`language.md` §12.7–§12.10). The
diagnostics come from `--diagnostics=json` and show at their positions in the editor.

### 4.3 The samples (second pull request)

A counter, TodoMVC (`bench/todomvc/apps/beni/Sandbox.beni`) and a `run/`-style program that
prints. Each `browser-direct` sample is a program that builds for `browser-direct` today, and
the page says so next to the sample list.

### 4.4 The tabs (second pull request)

The emitted JavaScript, `beni dump --stage=types` and `beni dump --stage=ownership`, each from
the same source as the build.

### 4.5 The shareable link (second pull request)

The source, compressed with the browser's `CompressionStream("deflate-raw")` and encoded in
base64url, in the URL fragment. The fragment never goes to the server.

## 5. Running the output

The compiled program runs in an `<iframe sandbox="allow-scripts">`, **without
`allow-same-origin`**. All of one user's GitHub Pages sites share one origin,
`canassa.github.io`, so a program with that origin could read and write the storage of every
other site of the user. Without `allow-same-origin` the frame has an opaque origin of its own.

A blob URL that the parent page makes belongs to the parent's origin, and the frame cannot load
it. So the parent sends the emitted files to the frame with `postMessage`, and the frame's own
bootstrap script (`playground/frame.js`, inlined in the frame's `srcdoc`):

1. makes a blob URL for each module in the frame's own origin, dependencies first, after it
   replaces each relative import specifier with the blob URL of the file it names;
2. replaces `node:process` with a small module whose `stdout.write` sends the text to the parent
   (a printing program on the `node` platform, `platforms/node/runtime.js`);
3. imports the entry module, `_main.mjs`, which mounts the program on the frame's `<body>`.

The frame sends an uncaught error and an unhandled rejection to the parent from its `error` and
`unhandledrejection` listeners. A listener is not a `catch` (rule 9). beni's own defect screen
shows inside the frame.

A relative specifier is found by the import forms that the compiler writes and that
`boundary.md` §4's checks accept for a sibling: `import … from "./…"`, `export … from "./…"` and
`import "./…"`. The emitted module graph has no cycle (a beni import cycle is an error), so
"dependencies first" is always possible.

## 6. Tests: byte identity

Rule 5 says that the single-threaded build and the WebAssembly build write the same bytes as the
native threaded build. Two kinds of test prove it.

1. **In the gates** (`tests/blackbox/wasm_test.zig`, part of `test-blackbox`):
   - a native **single-threaded** compiler (`zig-out/single/bin/beni`, self-hosted ReleaseSafe,
     the stack of §2.3) against the native threaded one, on projects that reach every place
     where §10's guards are: the per-file pool, resolution, the check DAG, emit, the ownership
     pass and the dumps, and a tree `Parse.max_depth` levels deep, which proves the stack;
   - the **WebAssembly** compiler, run by `tests/wasm/beni.mjs` under Node on
     `playground/wasi.js`, against the native one, on a printing program and on a program with
     diagnostics. The gates build it with the self-hosted backend (`ReleaseSafe`, about 7 s);
     `-Dllvm` builds it with LLVM, as it does the native compiler.
2. **Not a gate:** `zig build test-playground` runs the shipped `ReleaseSmall` `.wasm` (§7.1) on
   every program of `tests/corpus/run/` and `tests/corpus/browser/direct/`, and on TodoMVC, and
   compares every output file, both streams and the exit code with the native compiler's.

A test compares every file of the output tree and both streams byte for byte, and the exit code.

*Why the gates do not run the shipped binary.* The LLVM build of the `.wasm` is about 90 s of
single-threaded compile after each edit under `src/` (§7.1), about nine times the gates' time.
The self-hosted build compiles in about 7 s, but its code is slow: under Node it spends about 3
billion instructions on a printing program and 5 to 7 billion on a `browser-direct` page, and the
budget of a test is 4.3 billion. So the gates run the self-hosted `.wasm` on the programs that fit
the budget, and the native single-threaded compiler on everything else, because it runs the same
guarded code at native speed. The shipped binary is proven by `test-playground`.

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
| `ReleaseSmall` (shipped) | 8 556 880 | 2 984 174 | 2 146 575 | 4 301 790 | 4 247 601 |
| `ReleaseFast`, no debug sections | 13 354 953 | 4 068 454 | 2 708 121 | 9 103 696 | 4 245 381 |

The data section is half of the shipped file: the embedded `core/`, the platforms and the
checked core (§2.1).

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

### 7.3 The cost in the gates

The tests of §6 in `zig build gates`, in instructions (the budget's unit, 4 300 million a
test): the WebAssembly compiler on a printing program, 3 579 million; on the diagnostics,
2 700 million; the native compiler with no threads, 927 to 2 568 million a test. The
self-hosted `.wasm` and the native compiler with no threads each add one compile of the
compiler to the gates, in seconds, on cores the rest of the gates leave free.

## 8. Known limits

**The engine's stack bounds the nesting depth.** §2.3: a WebAssembly function's frames are on
V8's stack, about 1 MB, and the page cannot make it larger. A native compiler accepts an
expression `Parse.max_depth` (4096) levels deep and refuses a deeper one with
`nesting_too_deep`. The WebAssembly compiler in a page stops at a smaller depth, with V8's
`RangeError: Maximum call stack size exceeded`, which the page shows as "the compiler ran out of
stack".

Measured in Chrome 153 (§7.2), in the page's worker: a call `f (f (… 1))` 606 levels deep
compiles, and 607 levels run out of stack. The native compiler builds the same shape 4 000
levels deep (`abuse_test.zig`). Three page loads gave the same depth. A program a person
writes rarely nests a few hundred levels; a long operator chain does, because the parser
nests one level per operator (`x + x + … + x`).

## 9. Build and deploy

`zig build playground` writes the static site to `zig-out/playground/`: `index.html`, the
JavaScript of §3 to §5, and `beni.wasm` (`ReleaseSmall`, LLVM). Every URL in it is relative, so
the directory works under any path, `/beni/playground/` included. No workflow in this repository
deploys it: the site build of issue #127 runs the step and copies the directory (§1).

**Later.** One instance kept alive between compiles, with the on-disk caches of
`fast-compiler.md` §8 in its memory file system, makes a compile after an edit incremental. It is
not part of either pull request.
