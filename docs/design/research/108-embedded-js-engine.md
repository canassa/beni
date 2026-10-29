# 108 — Which JavaScript engine beni embeds to prerender pages

*2026-10-29. Beni master `cdd26f460`; Zig 0.17.0; Node 24.19.0 (V8 13.6, ICU 78.3, Unicode 17);
QuickJS 2026-06-04; QuickJS-ng 0.17.0; Kiesel `3c95d594` (2026-10-25); x86-64 Linux (NixOS,
glibc 2.44), 32 threads, shared with two other agents' builds. Issue #1162, part of #1160. The
contract is [`prerender.md`](../prerender.md) §5.1, *The engine is embedded in beni; Node is the
step before it*. 105–107 exist or are taken on branches; 108 was free. Scripts, the prototype host
and the programs: [`bench/embedded-engine/`](../../../bench/embedded-engine/).*

The owner, 2026-10-29 (`prerender.md` §10 question 1): a beni build must not need a JavaScript
runtime installed beside it, so the prerender tree runs in an engine compiled into `beni`. Which
engine was left open. This report measures the candidates.

## 0. Answer

**Embed QuickJS-ng 0.17.0.** It builds with `zig build` alone for every target the flake names,
it adds 1.0 MB to a stripped ReleaseFast `beni` (1.7 MB to ReleaseSafe), it loads beni's output
tree through one loader callback, and on everything a page can see it writes what V8 writes: 2²⁰ random doubles printed and parsed
back, the case mapping, `\s`, `trim`, `\d` and `\w` of every code point to U+10FFFF, sort
stability, `JSON.stringify`, and 1 226 runs of the `run/` corpus (every program, development and
release), where the only differences are host APIs that are not ECMAScript and the text of
`JSON.parse`'s error messages. It is clean under Zig's C sanitizer, it builds and runs for
`wasm32-wasi`, and it ships a release a month.

Bellard's QuickJS is equally exact on the same sweeps and **about 25 % faster**, but it traps
under the sanitizer that beni's ReleaseSafe builds give C code (undefined behaviour in its
bytecode optimiser, reached by ordinary emitted code), it does not build for `wasm32-wasi`, and a
stack overflow is an `InternalError` where V8 throws a `RangeError`. Kiesel, the one Zig-native engine, fails: without
Rust's toolchain it has no Unicode case mapping (`"ß".toUpperCase()` is `"ß"`), and it is 14 times
slower than QuickJS. The other engines of the class are out on language level (Duktape,
MicroQuickJS) or toolchain (Hermes, Boa, V8) (§1).

**Three things in §5.1 do not hold as written** (§10), and P5 must answer them:

1. *"The engine runs the emitted code, so the agreement §3 rests on stays true by
   construction."* It is true of ECMAScript and false of the host. `Url.fromString` is
   `Js.pure`, so a pure `view` may call it, and it calls the WHATWG `URL`, which no embeddable
   engine has. The three `Url*` programs of the corpus fail in both QuickJS builds with
   `'URL' is not defined`.
2. *Numbers print the same on every engine.* `Number::toString` does, but `Math.pow` (beni's `^`
   on `Float`), `Math.sin`, `Math.log` and the rest come from whatever libm the engine is linked
   with. The same QuickJS-ng prints 29 lines of a whole-number sweep (`10.0 ^ k`, `k` an integer)
   differently from V8 when linked with musl, and none when linked with glibc; a Debug build of
   it gives other `sin` and `cos` values than its ReleaseFast build. So the page depends on the
   machine and the build that made it, which rule 5 forbids, not only on the engine.
3. *Linking the engine changes the binary.* beni is a static executable with no libc today. An
   engine in C needs libc: on the native Linux target, `link_libc` makes `beni` a dynamically
   linked executable against the build machine's glibc (measured, §4).

| | QuickJS-ng 0.17.0 | QuickJS 2026-06-04 | Kiesel (Zig) | Node 24 |
|---|---|---|---|---|
| `zig build` only, 4 flake targets | yes | yes | no: Unicode needs `cargo` | — |
| `wasm32-wasi` | builds and runs; 706 KB ReleaseSmall | no (`setjmp`) | not tried | — |
| Zig's C sanitizer (ReleaseSafe, Debug) | clean | traps on `Strings` | — | — |
| stripped host binary (static, musl) | 1 126 632 B | 1 052 560 B | 3 747 136 B (CLI, glibc) | — |
| cold compile of `quickjs.c`, `-O2` | 15.4 s | 11.9 s | 142 s (whole engine) | — |
| 2²⁰ doubles, Unicode sweep vs V8 | identical | identical but one line | 3 021 lines differ | reference |
| `run/` corpus, 1 226 runs vs V8 | 26 differ, none in ECMAScript but `JSON.parse` text | 28 differ, same causes | not run | reference |
| one page of 7 504 elements, whole process | 11.6 ms | 9.3 ms | — | 35.1 ms |
| 50 such pages in one instance, per page | 9.0 ms | 6.8 ms | — | 3.4 ms |
| licence, releases | MIT; 11 releases since 2025-10-28 | MIT; 3 since 2025-04-26 | MIT; early-stage | — |

## 1. The candidates

The filter is §5.1's: built from source by `build.zig` with nothing else installed, ES modules
and the language beni emits (arrow functions, `const`, spread, template literals, classes in
`core/` siblings, `async` nowhere a render goes), and exact where a page can see it.

- **QuickJS** (Fabrice Bellard, latest release 2026-06-04) and **QuickJS-ng** (the fork
  maintained by Ben Noordhuis and Saúl Ibarra Corretgé, v0.17.0 of 2026-09-18): one C file of
  about 2 MB each, plus regular expressions, Unicode tables and `dtoa`. Measured in full.
- **Kiesel** (Linus Groh, written in Zig, requires Zig 0.17): measured. It builds with
  `zig build -Denable-intl=false -Denable-temporal=false` in 142 s. With Intl (ICU4X) or Temporal
  it needs `cargo`, which fails the filter. Without them, `"ß".toUpperCase()` is `"ß"` and
  `normalize` throws *Intl support is disabled*; the stress sweep (§6.1) differs from V8 in 3 021
  lines (1 554 upper-case and 1 462 lower-case mappings, the final sigma), its FNV line prints a
  different hash, and it took 75.1 s where QuickJS took 5.4 s and Node 0.7 s. Its own README calls
  it early-stage. Out.
- **MicroQuickJS** (Bellard, 2025): "only supports a subset of JavaScript close to ES5" in a
  stricter mode (its README). beni emits arrow functions and modules. Out, not built.
- **Duktape 2.x**: ES5.1 with a few ES2015 features, no arrow functions, no modules. Out, not
  built.
- **JerryScript**: ES2022 subset with modules, made for microcontrollers; last release v3.0.0 of
  2024-12-18, last push 2025-10-08. Credible on language level, not maintained at QuickJS-ng's
  rate. Not built or measured; it would be the next to try if both QuickJS lines failed.
- **Hermes, Boa, Nova, V8, SpiderMonkey, JavaScriptCore**: C++ with CMake, GN or mach, or Rust
  with `cargo`. Hermes runs no ES modules without a bundler. Out on the filter, not built.

## 2. Method

**The prototype host** (`bench/embedded-engine/src/host.c`, 200 lines, the same file for both
QuickJS lines) is what P5's embedding would be, less the records. It makes a runtime and a
*raw* context and adds only the intrinsics a program needs: base objects, `eval` (the module
compiler), `RegExp`, `JSON`, `Proxy`, `Map`/`Set`, typed arrays, `Promise`, `WeakRef`, and
`String.prototype.normalize` for Bellard's. **No `Date`** unless `--date`, **no `Math.random`**
unless `--random`. A module loader callback reads a module by its resolved name and compiles it;
`node:process` and `node:fs/promises` are synthetic modules. A prelude
(`src/prelude.js`) gives `console`, `queueMicrotask`, `setTimeout`/`setImmediate` on a virtual
clock, and the part of `process` that the `node` platform reads. The host drains the job queue,
runs timers in (time, id) order, and exits with the program's `process.exitCode`, or 1 on an
uncaught throw.

The prerender tree does not exist yet (P1 has not landed), so the programs are `node` platform
programs. A page is the `node` platform's `ssr` lowering, `Node.print (Ssr.render (view model))`,
which is the nearest thing to §4's string form that runs today. Every comparison is byte for
byte on standard output and on the exit code, against `node` on the same files.

```sh
zig build                                   # the beni under test, at zig-out/bin/beni
bench/embedded-engine/run.sh fetch hosts programs stress fidelity corpus timing determinism
bench/embedded-engine/run.sh cross ctime ubsan
```

`run.sh` writes under `WORK` (default `~/.cache/beni-engine-bench`). The size measurement (§4) is
a patch of `build.zig`, not a script, because it changes the compiler; §4 gives it.

## 3. Build

Both QuickJS lines compile with Zig's bundled clang and libc, from a cold local cache, for every
target, with no flags but `-std=gnu11 -funsigned-char -Wno-everything -D_GNU_SOURCE` and a
`CONFIG_VERSION` string:

| target | QuickJS-ng | QuickJS | both, wall |
|---|---|---|---|
| `x86_64-linux-musl`, `aarch64-linux-musl` | ok | ok | 16.7 s, 16.4 s |
| `x86_64-linux-gnu` | ok | ok | 14.8 s |
| `aarch64-macos`, `x86_64-macos` | ok | ok | 14.6 s, 13.8 s |
| `x86_64-windows-gnu` (beni ships none) | ok | ok | 16.5 s |
| `wasm32-wasi` | **ok** | **fails**: `setjmp.h` needs WebAssembly exception handling | 13.2 s |

The four flake systems (`flake.nix`: x86_64/aarch64 Linux and macOS) all build; beni ships no
Windows build. The cost is one large C file: `quickjs.c` takes 11.9 s (Bellard) or 15.4 s (ng) at
`-O2` on one core, 2.8 s or 3.0 s at `-O0`; the other files add under 1.5 s together (`run.sh
ctime`). Zig compiles C files in parallel with the Zig code and caches them by content, so the
cost is paid once per optimisation mode and target, and an edit under `src/` never recompiles
them. On a cold cache it is longer than the self-hosted ReleaseSafe compile of beni the gates use
(about 3 s), so **a cold gate build grows by about 12 s**, and a warm one by nothing.

**The sanitizer.** Zig compiles C with a trapping `-fsanitize=undefined` in Debug and ReleaseSafe,
and beni's tests run a ReleaseSafe beni so that every safety check fires (CLAUDE.md, *Building*).
With it on (less `-fsanitize=function`, whose handler Zig does not link), QuickJS-ng runs the
stress sweep, `Strings`, `Numbers` and the fifty pages, in ReleaseSafe and in Debug, with no
trap (`run.sh ubsan`). Bellard's QuickJS traps as soon as it compiles a `typeof x === "…"`, which
its peephole pass rewrites: *left shift of 168 by 24 places cannot be represented in type 'int'*,
`quickjs.c:35432` in `resolve_labels` (the `M4` macro shifts an opcode into the sign bit). Core's
emitted code tests `typeof` in many places: `Strings` traps in both modes, as does a three-line
test module; the stress sweep, `Numbers` and the pages happen not to reach it. It could
be embedded only with the sanitizer turned off for its files, or with patches beni would carry.

## 4. Size

The size is measured by building beni itself with the engine linked in: a scratch copy of the
tree at `cdd26f460` whose `build.zig` takes `-Dengine=none|qjs|ng` and adds the engine's C files,
`link_libc`, and `src/embed.c` to both the installed compiler and every `compiler(…)` it makes.
`embed.c` is the host with a constructor that runs the module `BENI_ENGINE_PROBE` names before
beni's `main`, so the linker keeps the whole engine and the binary can show it runs
(`BENI_ENGINE_PROBE=t.mjs beni version` printed the probe's line and exited 3, its exit code). Not
committed; it is the first fifteen lines of P5's `build.zig` change.

| installed `beni`, x86-64 Linux, LLVM | no engine | + QuickJS | + QuickJS-ng |
|---|---:|---:|---:|
| ReleaseFast, as built (debug info) | 105 190 664 | 110 427 088 (+5 236 424) | 110 881 936 (+5 691 272) |
| ReleaseFast, `strip` | 25 645 048 | 26 557 200 (**+912 152**) | 26 618 072 (**+973 024**) |
| ReleaseSafe, as built | 81 455 784 | 87 633 744 (+6 177 960) | 88 203 592 (+6 747 808) |
| ReleaseSafe, `strip` | 22 365 288 | 23 959 680 (+1 594 392) | 24 066 816 (+1 701 528) |

The engine's C gets the same flags in both modes, sanitizer off, plus what Zig adds per mode;
why the stripped ReleaseSafe binary grows by 0.6 MB more than the ReleaseFast one was not
traced. The
whole LLVM build took 355–415 s in every column, so the engine's 12–15 s of C, compiled in
parallel, did not show in it.

The engine adds 0.9–1.0 MB to a stripped ReleaseFast binary, about what the static musl host
alone weighs (1 052 560 B for QuickJS, 1 126 632 B for QuickJS-ng, musl included). **With `link_libc` on the
native target, `beni` becomes a dynamically linked executable** against the build machine's glibc
(`file`: *dynamically linked, interpreter /nix/store/…-glibc-2.44-25/lib/ld-linux-x86-64.so.2*);
today it is static and needs no libc. P5 must keep it static on Linux by building for
`*-linux-musl` (both engines build there, §3), or give the engine the few libc functions it needs
from Zig. On macOS, every executable links `libSystem`, so nothing changes there.

**The playground** (`wasm32-wasi`) is built by `compiler(…)` too, and the patch leaves the engine
out by target: `if (target.result.os.tag != .wasi)`. That is all §5.1's "leaves the engine out"
costs. It is also optional: QuickJS-ng built for `wasm32-wasi` at ReleaseSmall is 706 018 B
(235 950 B brotli), and it rendered the page of §8 identical to Node under Node's WASI. In a
browser, though, the page already has an engine, and the playground could run the prerender tree
in it; that is a playground decision, not P5's.

## 5. ES modules

Both QuickJS lines load a module tree through one callback, `JS_SetModuleLoaderFunc(rt,
normalize, loader, opaque)`. The default normaliser resolves `./x.mjs` and `../_core/List.mjs`
against the importing module's name, which is how every emitted import is written; the loader
gets the resolved name and returns `JS_Eval(…, JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY)`
of the source. The source may come from a file or from memory: the loader is the only place that
reads it, so P5 can run the prerender tree straight from the emitter's buffers and never write it
to disk, as §5.1 item 1 has the build do for Node. Two details the host must handle: QuickJS reads
one byte past the source, which must be a NUL (a `#embed` of the prelude without one fails to
parse), and a module's evaluation is a promise whose rejection the host reads with
`JS_PromiseState`.

Every one of the 1 226 corpus builds (§6.3) loaded: entry, `_platform/`, `_core/` and the
program's modules, development and release, with no `SyntaxError` in either engine. That is the
evidence that both support every ES feature beni emits and `core/`'s siblings use; a grep of the
features would be weaker.

## 6. Fidelity against V8

### 6.1 The engine alone (`programs/stress.mjs`)

| sweep | QuickJS-ng | QuickJS |
|---|---|---|
| `String(x)` of 2²⁰ doubles from random bit patterns, FNV-hashed; `Number(String(x))` round trip; `toFixed`/`toPrecision`/`toExponential` of every 64th | identical hash, 0 round-trip failures | same |
| `String` of 600 000 integers and near-integers, past 2⁵³; `1eN` and `4.9eN` for N from −330 to 310 | identical | same |
| `toUpperCase`, `toLowerCase` of every scalar value to U+10FFFF (1 554 and 1 462 that change) | identical | same |
| `/\s/`, `trim`, `/^\d$/u`, `/^\w$/iu`, `\p{L}` against `\p{Alphabetic}`, every scalar value | identical | same |
| final sigma, `isWellFormed`/`toWellFormed`, `split`, `replaceAll` with `$&`, `padStart` | identical | same |
| `JSON.stringify` of control characters, `</script>`, U+2028, a lone surrogate, `-0`, `NaN`; `JSON.parse` of `1e400` and `__proto__`; key order | identical | same |
| `encodeURIComponent`, named groups, `normalize("NFD")` | identical | same |
| sort stability of 2 000 records on 13 keys; string sort; `Map` and `Object.keys` order | identical | same |
| unbounded recursion | `RangeError` | **`InternalError`** (not a `RangeError`) |

4 962 lines; QuickJS-ng differs in none, QuickJS in the last. Both carry Unicode 17.0 tables, the
version of Node 24's ICU 78. When a browser moves to a newer Unicode before the engine does, the
case tables of the new characters differ until the engine follows; the pinned engine version is
then a thing to bump.

### 6.2 beni programs (`programs/Numbers.beni`, `Strings.beni`)

`Numbers` prints, through core, 25 561 lines: `String.fromFloat` of specials (`-0`, `NaN`,
`±Infinity`, `5e-324`, `Number.MAX_VALUE`, `1e21`), 20 000 values across magnitudes from 10⁻³²⁰
to 10³⁰⁰ (made with `10.0 ^ k`), 3 000 decimals, `Int` past 2⁵³ through `fromInt` and
`fromFloat`, 2 000 `Int32` LCG steps (`mul`, `add`, `xor`, `shiftRightZero`, `rotateLeft`),
`String.toFloat` of edge strings, and last, in a block of its own, 500 rows of `sin`, `cos`,
`tan`, `sqrt`, `atan`, `Float.log x 10` and `x ^ 1.37`. `Strings` prints 3 097 lines: every code
point to U+2FFFF whose `String.toUpper`, `toLower`, `Char.toUpper` or `Char.toLower` changes it,
every code point below U+10000 that `trim` removes or `words` splits on, 22 samples through
`toUpper`, `toLower`, `reverse`, `length`, `split ""`, `replace`, `Debug.toString`, `List.sort`,
`sortBy` and `sortWith` on equal keys, `split`, `indexes`, `replace` with `$&` and `$$`,
`toInt` of `-0`, `+12` and Arabic digits, `Debug.toString` of a record with control characters,
`Json.encode` with `</script>`, U+2028, `1e21`, `5e-324` and `9007199254740993`, and a `Dict`'s
order.

- **`Strings`, development and release: identical** in both engines.
- **`Numbers`: identical above the Math block** in both engines linked with glibc. In the block,
  QuickJS differs from V8 in 15 values of 3 500 (`sin` 2, `cos` 3, `atan` 3, `log` 7) and
  QuickJS-ng in 53 (`sin` 14, `cos` 17, `tan` 14, `atan` 3, `log` 7). `sqrt` and `x ^ 1.37`
  agree. §3.3 of `prerender.md` expects this block to differ.
- **The same QuickJS-ng linked with musl** (`x86_64-linux-musl`) differs in **29 lines above the
  block**, all `String.fromFloat (walk i)`, whose value is `base * 10.0 ^ k` with `k` a whole
  number: `1.4257512117142857e+128.0` from V8, `1.425751211714286e+128.0` from musl's `pow`. In the
  block it then agrees with V8 on `atan` and `tan`, and still differs on `sin`, `cos` and `log`.
- **The same QuickJS-ng source built in Debug** (glibc, sanitizer on) gives the Math block of
  Bellard's ReleaseFast build, 15 differences from V8, not the 53 of its own ReleaseFast build: the
  optimisation mode alone changed the results (which implementation each build's calls resolve
  to was not traced).

So the engine's `Math` is whatever libm the link and the optimiser pick, which varies between
machines and between builds of one beni; §6.4 draws the consequence. (The `.0` after an
exponent is a separate defect of `String.fromFloat`, found here: #1164.)

### 6.3 The `run/` corpus

Every `tests/corpus/run/` program that is not a server (613), built twice as the gates build it
(`--platform=node`, and `--release --allow-debug`), run under Node and both hosts with `--date
--random` (the corpus reads the clock; a prerender may not): **1 226 runs, QuickJS-ng differs in
26, QuickJS in 28.** Every difference, by cause:

| cause | programs (×2 builds) | ECMAScript? |
|---|---|---|
| `URL` is not defined: `Url.fromString` and the parser over it | `UrlBasics`, `UrlParser`, `UrlQuery` | no, WHATWG |
| `DOMException` is not defined | `JsCatchIf` (a test platform's foreign) | no, WebIDL |
| `crypto.getRandomValues` | `RandomValue` | no; impure anyway |
| `node:fs/promises` is a stub | `ReadFileDefect`, `ReadFileErrors`, `SuspendReadFile` | no; the host's |
| an unhandled rejection is not fatal in the host, as Node's is; `setImmediate` and `MessageChannel` order on the virtual clock | `SchedulerDefect`, `TaskDefectOnNode`, `MacrotasksPendingTogether` | the host's event loop, not the engine |
| **`JSON.parse`'s error message**, which `Schema` puts in `ParseFailed` | `SchemaJson`, `SchemaComposed`, `SchemaDeclRecords` (QuickJS-ng matches V8 in the last) | the text is implementation-defined |

The first five rows are the host, not the engine, and only the first matters to a page (§10
item 1). The last is page-visible text that every engine words its own way, Firefox and Safari as
well: `Expected property name or '}' in JSON at position 1 (line 1 column 2)` from V8, `expecting
property name` from QuickJS. A bound text heals at the first pass (§3.2 of `prerender.md`); the
value still depends on the engine (#1166).

### 6.4 What this means for the guarantee

What the engine computes from ECMAScript's exact algorithms (number printing and parsing, string
and array operations, regular expressions, Unicode properties, `JSON.stringify`, sort) is
identical to V8 on every input tried. Three things are not exact by the standard, and P5 must pin
each:

- **`Math`'s transcendental functions and `Math.pow`.** The standard leaves them
  implementation-approximated. V8 does not call the host's libm: it compiles its own (fdlibm's
  lineage, in `src/base/ieee754.cc`), which is why Node agrees with neither glibc nor musl here.
  QuickJS calls `sin`, `pow` and the rest from libc. So P5 must compile a fixed implementation of
  every `Math` function into the engine and never take the host's, or a page built on macOS
  differs from one built on Linux (rule 5). Taking V8's own makes the prerendered text equal to
  Chrome's as well, which §3.3 does not require but which costs nothing more. The `Numbers`
  program's last block is the fixture.
- **Engine-worded messages** (`JSON.parse`'s, an error's `message`) reach a page only through core
  code that copies them; #1166.
- **Stack depth.** A recursion that fits in V8's stack may not fit the engine's, and the reverse.
  Both fail the build (`prerender_failed`), so no wrong page is written. The host must set
  `JS_SetMaxStackSize` below the stack of the thread it runs on: a 64 MB limit on an 8 MB thread
  made QuickJS-ng crash with a segmentation fault instead of throwing.

## 7. Determinism and isolation

A raw context offers only ECMAScript's globals (`run.sh stress` prints them): no `Date`, no
`performance`, no timers, no `console`, no `process`, no I/O; `Math.random` is deleted after the
context is made. A program that reaches one fails with a `ReferenceError` or `TypeError` naming
it, which is the build's `prerender_failed`, so a missed impurity cannot write a page that depends
on the clock. The host adds only what the prerender entry declares. Five runs of `Strings`,
`Numbers` and the fifty pages under each engine give one output hash each. The engine is one
runtime on one thread, so `--jobs` cannot reach it; the determinism test still covers the pages,
as §5.4 says. `JS_SetMemoryLimit` and `JS_SetInterruptHandler` give the host a bound on memory and
a way to stop a view that never ends, should beni want one; §3.3 has the build wait, as it does
for any program.

## 8. Speed

`Page.beni` renders a table of 1 000 rows of five elements and a list of 500, **7 504 elements,
157 016 bytes of HTML**, through `Ssr.render`; `Page50.beni` renders fifty such pages (different
rows each) in one program, as one engine instance renders a route list. Medians of 21 whole
processes (7 for fifty pages), release builds:

| | Node 24 | QuickJS | QuickJS-ng |
|---|---:|---:|---:|
| one page, whole process | 35.1 ms | **9.3 ms** | 11.6 ms |
| one page, in process (Node: `import` timed; QuickJS: `--repeat`) | 9.6 ms | 6.4–7.0 ms | 8.3–9.3 ms |
| engine start: runtime, context, prelude | ~25 ms (whole less in process) | 0.15–0.31 ms | 0.15–0.41 ms |
| fifty pages, whole process | 217 ms | 341 ms | 448 ms |
| per page, fifty in one instance | **3.4 ms** | 6.8 ms | 9.0 ms |

The machine was shared with other builds; `run.sh timing` run again later at a load average of 2
gave every figure within 10 % (fifty pages: Node 200 ms, QuickJS 334 ms, QuickJS-ng 418 ms). The
development build of one page: Node 38.1 ms, QuickJS 10.0 ms, QuickJS-ng 11.7 ms. An
interpreter starts in a third of a millisecond and Node in tens, so a site of a few pages
prerenders faster in the engine than by starting Node; V8's JIT wins from about ten pages on and
is twice as fast per page at fifty. A thousand routes of this page would take about 9 s in
QuickJS-ng and 3.4 s in Node. The pages of a site are seldom 7 500 elements each, so that is an
upper bound, and §10 question 4 already has incremental prerendering as the answer if `serve`
finds it slow.

## 9. Licence, maintenance, vendoring

Both QuickJS lines are **MIT** (Bellard and Gordon; QuickJS-ng adds Noordhuis), compatible with
any licence beni takes; the notice must ship with the binary. **QuickJS-ng** released v0.10.1
(2025-05-13), v0.11.0, v0.12.0, v0.12.1, v0.13.0, v0.14.0, v0.15.0, v0.15.1, v0.16.0, v0.16.1,
v0.16.2 and v0.17.0 (2026-09-18), carries its test262 runner and expected-failure list in the
tree, and marks its embedding API (`JS_EXTERN`). **Bellard's** released 2024-01-13, 2025-04-26,
2025-09-13 and 2026-06-04; its GitHub repository took five commits on 2026-10-26, some from
QuickJS-ng's maintainers. Either is alive; QuickJS-ng's cadence suits a dependency that must keep
pace with what browsers ship.

**Vendoring.** beni has no Zig package dependency today (`build.zig.zon` is empty) and
`references/` is evidence, never a build input (its README: "commit the submodule pointer, never
the contents"; a fresh clone does not need it). The engine is a build input, so it should be a
**Zig package pinned by hash**: `build.zig.zon` names the release tarball
(`https://github.com/quickjs-ng/quickjs/archive/refs/tags/v0.17.0.tar.gz`) and its package hash,
and `build.zig` compiles the four C files from `b.dependency(…).path(…)`. Zig fetches it once into
the global cache that every worktree shares (CLAUDE.md, *Zig's two caches*). A patch, if one is
ever needed, is a tag on a beni-owned fork and a new hash, never a local edit. The version, hash
and licence go into `references/README.md`'s manner of record, as P5's row says. A build with no
network then needs the package in the cache first (`zig build --fetch`); CI and the dev shells
have network.

## 10. What contradicts `prerender.md` §5.1

These are reported to the manager; the decision text is not edited.

1. **Not every pure function a render reaches is ECMAScript.** §5.1 says the engine "runs the
   emitted code, so the agreement §3 rests on stays true by construction", and the entry "uses
   nothing an engine that runs ES modules lacks". The entry does not; core does. `Url.fromString`
   (`core/Url.beni:52`) is `Js.pure` and calls `URL.parse` or `new URL`, the WHATWG parser of the
   host. A `view` may call it (it is pure, so `prerender_impure` does not refuse it), and P3's
   routing programs are the programs that will. No embeddable engine has `URL`. P5 must either
   (a) give the engine a WHATWG URL parser that equals the browsers' (a large surface: IDNA,
   percent-encoding sets, host parsing), or (b) write `Url.fromString` in beni over ECMAScript
   only, so the build and the browser run the same code, which is the "by construction" §5.1
   wants, or (c) refuse a prerendered program that reaches it. (b) is the one that keeps §3's
   argument; it is a core change with its own fixture against Chrome. A census of `Js.global`
   in `core/` finds no other non-ECMAScript host API on a pure path today (`Date`, `crypto`,
   timers and `MessageChannel` are on impure ones).
2. **§3.1 item 4's "numbers print by the standard's `Number::toString`, which is exact and the same
   on every engine"** is true and measured (§6.1), but a float a page prints is often computed by
   `^`, which is `Math.pow` and not exact by the standard; in the engine it is the linked libm's
   (§6.2). §3.3 names `Math.pow` "of non-integers"; the measured difference is of integer
   exponents. The answer is §6.4's first item, a fixed math library compiled in.
3. **§5.1's cost bullet** asks for the binary's growth; it should also require that `beni` stays a
   static executable on Linux (§4), which `link_libc` breaks on the native target.

## 11. Recommendation, and what P5's brief must require

Embed **QuickJS-ng**, pinned by Zig package hash at v0.17.0 or the release current when P5
starts. Bellard's QuickJS is the fallback if QuickJS-ng's speed matters more than the sanitizer
and the playground; it would need its UB-trapping files built with `-fno-sanitize=undefined` and a
check that its stack-overflow error is mapped as `prerender_failed` like any throw.

P5's brief must require:

1. **The build.** The four C files compiled by `build.zig` from the pinned package, for every
   compiler `build.zig` makes except `wasm32-wasi`; no step that needs a tool beyond Zig.
   **`beni` stays static on Linux** (`*-linux-musl`, or libc functions supplied from Zig), shown
   by `file` in the PR. Zig's C sanitizer stays on in Debug and ReleaseSafe for the engine's files
   (QuickJS-ng is clean less `-fsanitize=function`), so that a bug in the embedding traps in the
   gates.
2. **The host.** A raw context with only the intrinsics a render needs; no `Date`,
   `Math.random`, timers or I/O; `console.log` for `Debug.log`, written to the build's standard
   error as §5.1 says of Node's streams; the module loader reading the prerender tree from memory;
   `JS_SetMaxStackSize` set below the stack of the thread the engine runs on, with the thread's
   stack size chosen for it; an uncaught throw or a rejected evaluation is `prerender_failed` with
   the engine's message and stack, as Node's standard error is quoted today.
3. **A fixed `Math`.** Every `Math` function the engine exposes is compiled into beni from one
   pinned implementation (preferably V8's own, so the page equals Chrome's), never the host
   libm's; a fixture's page built on Linux and on macOS is byte-identical.
4. **The URL question answered first** (§10 item 1), as its own slice before P5 or inside it:
   `Url.fromString` in beni, or a refusal. Until then a prerendered program that reaches it fails
   in the engine where it ran under Node.
5. **The fixtures §11's P5 row names**, `Numbers` and `Strings` (this report's two programs are a
   start), each page also written by headless Chrome in `test-browser` and compared; plus the
   whole `browser/prerender/` corpus with an empty `PATH`, and the measurement this report could
   not make, the prerender tree itself.
6. **The costs stated**: the binary's growth stripped and not (§4's table is the expectation:
   1.0 MB stripped ReleaseFast, 1.7 MB ReleaseSafe), the cold build's growth (about 12–15 s of
   `quickjs.c` on one core, once per mode), and the time per route against Node's (§8: about 9 ms against 3.4 ms on a 7 500
   element page in one instance, and faster than Node for a site of under ten pages).

## 12. Reproducing

`bench/embedded-engine/run.sh` with the steps of §2; `fetch` checks both tarballs' SHA-256.
`hosts` needs only Zig; `programs` needs a `zig build` of this checkout (`BENI=` to point
elsewhere); `corpus` takes about 20 minutes. Kiesel was built by hand: `git clone --depth 1
https://codeberg.org/kiesel-js/kiesel` at `3c95d594`, then `zig build -Doptimize=ReleaseFast
-Denable-intl=false -Denable-temporal=false`, and `kiesel -m stress.mjs`; Zig's fetch of its
musl dependency failed TLS here, so the tarball was downloaded with `curl` and the
`build.zig.zon` URL pointed at the local file (same hash). The size patch of §4 is
`addEngine` in a scratch copy of `build.zig`, called on the installed compiler and in
`compiler(…)`, with `-Dengine=none|qjs|ng` and `src/embed.c` added to the module's C sources.
