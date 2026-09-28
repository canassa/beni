# Owning the whole output pipeline: compressed size, minification, and chunks

**Commissioned by** the decision that beni is a full-stack solution — `beni build` produces
deployable JavaScript with no external bundler and no external minifier — and by the two questions
`fast-compiler.md` §9.5 defers to this report: whether chunk assignment happens at *declaration*
granularity, and what the **language-level trigger** for a split is.

**The objective function is compressed size**, brotli primary and gzip secondary, with raw bytes kept
only as a diagnostic. That is not a stylistic preference: §2 shows the raw ranking of transformations
*inverting* against the compressed ranking twice, two transforms with **opposite signs** under gzip
and brotli, and an 18% swing in compressed size from a change that leaves the raw byte count exactly
constant. A size target stated in raw bytes is an actively misleading objective.

**This report extends [`03-js-codegen.md`](03-js-codegen.md).** Where it contradicts it, §7 says so.
03 §6 recommended the Elm split — compiler does field-name shortening, Terser does the rest. That
recommendation is void; this replaces it.

**Sources.** Compiler source read directly (Closure Compiler, dart2js, esbuild, Rollup, webpack,
Scala.js, GWT, js_of_ocaml, PureScript, GHC's JS backend, and the vendored `references/elm` at
`1bd5b36`); primary documentation, RFCs, issue threads and release announcements; two papers; and
**original measurements run for this report**, because the figure everyone quotes — Elm's TodoMVC
122KB → 24KB → 9KB — is one end-to-end number that says nothing about which transformation earned
which byte, and nobody has published the decomposition.

---

## 0. Method

**Machine:** Intel N100, 4 cores, 16 GB, Linux 7.2 — the same machine as `bench/README.md`, and a
slow one; read ratios, not absolutes. **Date:** 2026-09-13.
**Tools:** terser 5.x, esbuild (npm current), `google-closure-compiler` (npm), Node 24 `zlib`.
**Corpus:** `elm.js` from <https://evancz.github.io/elm-todomvc/> — 206,002 bytes, 896 top-level
declarations. Elm 0.18-era codegen: one IIFE, `F2`/`A2` adapters, `_pkg$Module$name` globals — the
output shape §9.4 specifies for beni — and *unoptimised*, which makes it a usable baseline for
measuring field renaming. Unless stated, gzip is `-9`, brotli quality 11 window 22.

**This is one project, one workload.** Every measurement is a single-project measurement, not a
benchmark suite. The *signs and orderings* are the findings; magnitudes are indicative.

| Variant | raw | gzip-9 | brotli-11 | wall |
|---|---:|---:|---:|---:|
| unminified | 206,002 | 38,738 | 32,609 | — |
| terser, whitespace only | 161,229 | 30,232 | 26,431 | — |
| terser `-m` (whitespace + rename) | 83,372 | 22,563 | 19,841 | — |
| terser `-m toplevel=true` | 83,372 | 22,564 | 19,841 | — |
| terser `-c` with Elm's purity flags (no rename) | 95,641 | 21,229 | 19,207 | — |
| terser `-c -m`, stock defaults | 68,145 | 19,627 | 17,508 | ~810 ms |
| **Elm's documented recipe** | **53,585** | **16,683** | **14,980** | ~860–1,110 ms |
| …`-c passes=3` | 52,824 | 16,471 | 14,776 | — |
| …plus `--mangle-props` (unsafe; upper bound) | 49,064 | 16,181 | 14,398 | — |
| Closure `WHITESPACE_ONLY` | 161,249 | 30,851 | 27,037 | 451 ms |
| Closure `SIMPLE` | 66,255 | 19,827 | 17,722 | 1,843 ms |
| **Closure `ADVANCED`** | **60,220** | **19,187** | **16,981** | **3,366 ms** |
| esbuild `--minify` | 78,435 | 23,192 | 20,597 | 21–34 ms |
| esbuild `--minify-whitespace` | 159,902 | 29,936 | 26,165 | — |
| esbuild `--minify-identifiers` | 162,288 | 28,834 | 24,787 | — |

**Terser with Elm's purity flags beats Closure ADVANCED** — 14,980 vs 16,981 brotli (−12%) at **50×
less wall time**. ADVANCED really did its signature trick here (`.ctor`→`.h`, `._0`→`.i`,
`.editing`→`.S`) and still lost, because without externs and type annotations it must stay
conservative: it reported "43.2% typed" and 31 warnings, and left `.completed` alone because that
field is also reached through a string key. Its output is almost certainly broken, so a *correct*
run would be larger and the gap is understated. **The lesson is not that Closure is bad; it is that
domain knowledge given to a simple minifier beat a sophisticated minifier without it.** beni holds
all the domain knowledge and never has to re-explain it across a tool boundary.

---

## 1. Who owns the whole pipeline

| Compiler | Output unit | DCE granularity | In-compiler minification | Source maps | Chunks |
|---|---|---|---|---|---|
| **Closure ADVANCED** | one bundle, or declared chunks | statement / declaration, whole-program | everything: var + **property** renaming, DCE, inlining, folding | yes | **yes**, `--chunk` + cross-chunk motion |
| **dart2js** | one bundle per entry + **output units** | **element (declaration)** | `--minify`, own renamer | yes | **yes**, `deferred as` |
| **Scala.js linker** | one file, or ESM modules | class / method, whole-program | **own property-name compressor** (1.16+); no whitespace mode | yes | **yes**, `ModuleSplitStyle` + `js.dynamicImport` |
| **Kotlin/JS IR** | per-module (default) or per-file | properties, functions, classes | **member-name minification on by default in production** | yes | per-module output only |
| **GWT** | one bundle + fragments | **field / method / type** | obfuscated/pretty/detailed name modes | yes | **yes**, `GWT.runAsync()` |
| **J2CL, ClojureScript** | delegate to Closure | (Closure's) | none of their own | yes | **yes** (`:modules`) |
| **js_of_ocaml** | one file, from bytecode | whole-program, **on by default** | **all of it, minified by default**; no external minifier | `--sourcemap` | no |
| **Haxe** | one `.js` | **class + field** (`-dce std\|full\|no`) | none | yes | no |
| **GHC JS backend** | `jsexe/`, concatenated | **STG binding group ("block")** | partial: link-time `h$$` renaming only | **none** | GHCJS's base bundles, never ported |
| **Idris 2** | one `.js` | whole-program | **`--directive minimal` obfuscates toplevel names** | not found | no |
| **Elm** | one IIFE | **top-level declaration** | **record fields only** | **none at all** | **none** |
| **Gleam** | one `.mjs` per module | **per definition, since v1.12** | none ("pretty printed") | not found | no |
| **PureScript** | one ESM file per module | **intra-module only** | none | opt-in | no |
| **ReScript / Melange** | one JS per source file | **intra-module only** | none | experimental | no |
| **Fable** | one `.fs.js` per `.fs` | none | none | `--sourceMaps` | no |
| **Roc** | **no JS target, by design** | — | — | — | — |

**The dividing line is not language family or age — it is whether the compiler already sees the whole
program.** Every compiler that owns the pipeline computes whole-program reachability; every one that
delegates emits per-module files and hands linking downstream. **beni computes whole-program
reachability (§9.1), so it is already on the owning side of the line whether or not it builds a
minifier.**

**The movement is toward owning it.** PureScript is the one clear move the other way, and its stated
reasons are about maintenance, not principle: `purs bundle` was *"slow, buggy, and difficult to work
on — a high risk, low reward part of the compiler"*
([proposal #4226](https://github.com/purescript/purescript/issues/4226)) and *"was already broken in
a couple of ways, didn't do a great job on bundle size, and was basically unmaintained"*
([0.15 migration guide](https://github.com/purescript/documentation/blob/master/migration-guides/0.15-Migration-Guide.md)).
Measured on the Halogen template: **259 Kb** (`purs bundle`) → **110 Kb** (+esbuild) → **82 Kb**
(0.15 + esbuild). Scala.js moved the opposite way and more decisively: 1.16.0 added its own
type-aware minifier, and 1.21.0 **disabled Google Closure by default in all configurations and
deprecated it** ([RFC #5244](https://github.com/scala-js/scala-js/issues/5244)) — *"GCC, as we call
it, has never added support for ECMAScript modules the way we need it to"*, and *"we are currently
stuck on an old version of GCC, from 2022."*

**That ESM point is load-bearing and is an independent argument for the full-stack decision.** §9.5
commits to ESM. Closure ADVANCED does not support ESM as an emitter needs, and Terser's `--mangle`
leaves ESM top-level names alone by default. Verified directly: `terser -m` and
`terser -m toplevel=true` produce **byte-identical** output on Elm's bundle, because inside an IIFE
there are no top-level names to mangle. **Elm's delegation works *because* of the IIFE. An
ESM-emitting compiler has no external advanced optimiser to fall back on.**

**Elm's split is principled, and worth restating precisely because it is the one beni is undoing.**
`addGlobal` (`Generate/JavaScript.hs`) is a DFS from `Opt.Global home "main"` emitting one `var` per
reached node — Evan's own term is *"function-level dead code elimination"*, and his stated reason it
beats bundlers is that *"tree shaking generally works with a granularity of modules (not
functions)"*, possible because *"Elm functions cannot be redefined or removed at runtime"*. But
`fromGlobal` (`Generate/JavaScript/Name.hs:59-61`) emits `author$project$Module$name` verbatim —
**top-level names are never shortened, even under `--optimize`.** Only record fields are
(`Generate/Mode.hs:44-62`, frequency-ordered, *"5% to 10% reduction in asset size"*). The compiler
does what a JS minifier *cannot*; terser does what it can.

**js_of_ocaml is the existence proof for the plan.** No external minifier anywhere in its dependency
graph, and `compiler/lib/config.ml` ships `pretty = false`, `deadcode = true`,
`globaldeadcode = true`, `shortvar = true`, `compact = true`, `inline = true`, `staticeval = true`
— minified by default, `--pretty` as the opt-out, with its own `Alphabet.javascript` name generator.
It gets there by consuming *bytecode*, which is what buys the whole-program view. §6 gives its size.

**Google states the precondition for owning the pipeline better than anyone.** On archiving Closure
Library ([closure-library#1214](https://github.com/google/closure-library/issues/1214)): *"We still
believe that Closure Compiler is the best advanced optimizer in terms of minified size, **as long as
it can assume that all input code meets its strict requirements**."* Its README says what happens
otherwise, and this is the sentence beni's position rests on: *"Closure Compiler is **not suitable
for arbitrary JavaScript**"*, and it will *"rename `propName` to something shorter, **without
noticing this problem, resulting in broken output JS code**"*, or *"**fail to recognize the problem
and simply generate broken JS without warning**."* **A language compiler is precisely a machine for
guaranteeing those requirements**, which is why the same optimisations that are reckless in a
bundler are routine in a compiler.

**One idea from J2CL worth carrying into M4.** J2CL kept whole-program reachability but **moved it
out of the compiler**: the transpiler emits a per-library `LibraryInfo` call-graph proto, and a
separate cacheable build step runs `RapidTypeAnalyser` over those summaries to produce the
unused-code list. Closure's hidden `--typed_ast_output_file` serialisation is the same move. **Feed
whole-program analysis compact per-library summaries rather than ASTs, and it stays cacheable and
parallel** — which is exactly what §8.1's interface firewall already does for checking, and what
§9.1's declaration graph should do for emission. (The OSS build stubs this out, so its measured
contribution is unverifiable.)

---

## 2. Compressed size is the objective function

### 2.1 The raw-byte ranking is wrong, measurably and repeatedly

| Pair | raw winner | compressed winner |
|---|---|---|
| esbuild whitespace-only (159,902) vs identifiers-only (162,288) | whitespace, by 2,386 B | **identifiers**, by 1,102 B gzip / 1,378 B brotli |
| terser `-m` (83,372) vs terser `-c` (95,641) | renaming, by **12,269 B** | **compression**, by 1,334 B gzip |

The second is the striking one: renaming saves twelve thousand more raw bytes than the compress pass
and still ends up 1,334 bytes larger after gzip.

The cleanest demonstration available is stronger still: **reordering declarations changes compressed
size by up to 18% with the raw byte count held exactly constant.** Re-emitting the 896 top-level
declarations of the unminified bundle in a different order — identical byte multiset, 206,002 bytes
in every case:

| Order | raw | gzip | brotli |
|---|---:|---:|---:|
| original (module-grouped) | 206,002 | 38,727 | 32,609 |
| sorted by declaration size (valid JS) | 206,002 | 41,490 **(+7.1%)** | 34,172 (+4.8%) |
| shuffled (text experiment; not valid JS) | 206,002 | 45,703 **(+18.0%)** | 35,387 (+8.5%) |

Raw size cannot see this at all. **Emission order is a free, printer-level decision worth several
percent of delivered bytes**, and the rule is "keep related declarations adjacent" — which
module-grouped reachability order already does and a global size- or name-sort destroys.

### 2.2 Closure optimises for compressed size, and says so in its source

The belief is correct, it is not folklore, and there are named mechanisms.

`AliasStrings.java` is a pass Closure keeps **disabled**:

> "Turning on this pass usually hurts code size after gzip… **gzip actually prefers that strings are
> not aliased — it compresses N string literals better than 1 string literal and N+1 short variable
> names.**"

`DisambiguateProperties` and `AmbiguateProperties` ship as a *pair* because the first breaks what the
second fixes ([Closure Tools blog, *A Property By Any Other Name, Part 3*](http://closuretools.blogspot.com/2011/01/property-by-any-other-name-part-3.html)):

> "Disambiguate properties allows us to rename some properties that are in the externs file, but **it
> creates a new problem: there are more unique properties, which makes the gzipped code bigger. To
> solve this problem, we use ambiguateProperties to minify the number of unique properties.**"

The [FAQ](https://github.com/google/closure-compiler/wiki/FAQ) states the policy: *"Most people
compare code size by looking at two uncompressed JavaScript files. But that's a misleading way to
look at code size… **Closure Compiler assumes that you are using gzip compression.**"* And
`PerformanceTracker.java` measures each pass *"before and after gzip"*, with post-gzip the default.

Name generation is tuned for the Huffman stage. `DefaultNameGenerator.java`: *"It is important that
the ordering of FIRST_CHAR is as close to NONFIRST_CHAR as possible… If we picked numbers first in
NONFIRST_CHAR, **we would end up balancing the huffman tree and result is bad compression.**"*
`RenameVars.java` assigns same-length names in source order so *"symbols declared close together are
assigned names that are quite similar. With this heuristic, **the output is more compressible**."*
`CodePrinter.java` places newlines in similar contexts *"so that gzip can encode them for 'free'"*.
esbuild does the same from the character-histogram side (`CharFreq`/`ShuffleByCharFreq`,
[`internal/ast/ast.go:722-827`](https://github.com/evanw/esbuild/blob/main/internal/ast/ast.go#L722-L827)),
though its changelog calls it *"a very slight win."* **All three major minifiers independently shape
name generation around the compressor.**

**The model is entropy, not length.** What costs compressed bytes is the *number of distinct
identifiers*. This gives beni a technique Elm does not have: `AmbiguateProperties` is greedy graph
colouring over a type-interference graph — register allocation for field names — and its Javadoc
says *"Properties are considered unrelated if they are never referenced from the same color… **thus
this pass is only effective if type checking is enabled.**"* Elm gives every distinct field its own
short name. beni knows every record type, so **two fields that never occur on the same type can share
one short name**, shrinking the *alphabet* rather than the *lengths*.

### 2.3 The sliding window: confirmed on mechanism, far smaller in effect

The window facts are exactly as supposed. DEFLATE's window is 32 KB; brotli's is `(1 << WBITS) - 16`
for `WBITS` in 10..24, so 1 KiB−16 B up to 16 MiB−16 B ([RFC 7932 §2, §9.1](https://www.rfc-editor.org/rfc/rfc7932)).
Node's encoder defaults to `BROTLI_DEFAULT_WINDOW = 22` (4 MiB).

Measured — an 8 KB block of real minified JS repeated after a gap of real JS filler, cost of the
**second copy**:

| gap | gzip-9 | brotli `lgwin=16` (64 KB) | brotli `lgwin=22` (4 MB) |
|---:|---:|---:|---:|
| 1 KB | 106 B | 8 B | 7 B |
| 16 KB | 114 B | 7 B | 7 B |
| **24 KB** | **1,980 B** | 11 B | 11 B |
| 40 KB | 2,104 B | 0 B | 0 B |
| **64 KB** | 2,040 B | **1,879 B** | 5 B |
| 512 KB | 2,021 B | 2,020 B | **11 B** |

Both compressors fall off a cliff *exactly* at their window — gzip between a 16 KB and 24 KB gap,
since the block is 8 KB and 8+24 = 32 KB — and brotli at its default never does: **11 bytes to encode
a duplicate 8 KB block half a megabyte away, against gzip's 2,021.** A ~180× difference.

**But the inference does not survive contact with a real bundle, and this is the important part.**
How much of a real bundle's compression comes from matches beyond gzip's reach:

| File | raw | gzip-9 | br lg14 (16 KB) | br lg16 (64 KB) | br lg18 (256 KB) | br lg22 (4 MB) |
|---|---:|---:|---:|---:|---:|---:|
| `app.js` | 206,002 | 38,727 | 34,363 | 33,072 | **32,609** | **32,609** |
| `s4_full.js` (minified) | 53,585 | 16,685 | 15,087 | **14,980** | 14,980 | 14,980 |

Beyond a 16 KB window the extra reach is worth **5.1%** on the 206 KB bundle and **0.7%** on the
53 KB minified one, and past 256 KB exactly **zero**, because the file is smaller than the window.
Meanwhile brotli beats gzip by 15.8% on the same file. **The window explains a minority of the
gzip/brotli gap; most of it is brotli's entropy and context modelling.**

**Verdict on the crux: whole-program naming consistency does pay under gzip.** Its mechanism is not
long-range LZ77 matching of the name — a one-character name recurs constantly at short range — but
**entropy: fewer distinct symbols means cheaper Huffman codes**, a whole-stream property with no
window dependence, and the mechanism Closure documents in §2.2. The claim that beni's biggest
advantage "largely does not pay under gzip" is **refuted**: the window-dependent component is
0.7–5.1% on realistic bundle sizes, not the bulk of it.

### 2.4 Brotli's static dictionary: real, but not the reason, and the folklore did not reproduce

RFC 7932 Appendix A defines a 122,784-byte `DICT` array; secondary sources describe 13,504 words
across six languages plus common HTML and JavaScript phrases, each with 121 transforms. **The RFC
itself states neither the word count nor the source corpus** — that could not be sourced from the
primary document.

More importantly, **the practical claim did not reproduce.** Marginal cost of a single occurrence
above an empty stream:

| token | length | brotli Δ | gzip Δ |
|---|---:|---:|---:|
| `true` | 4 | 7 | 4 |
| `null` | 4 | 7 | 4 |
| `aaaa` (non-word) | 4 | **7** | 4 |
| `function` | 8 | 9 | 8 |
| `prototype` | 9 | 9 | 9 |
| `!0` | 2 | 5 | 2 |

A dictionary word costs the same as an arbitrary string of the same length. **At single occurrence
there is no measurable dictionary advantage**, and a brotli co-author says as much — Jyrki
Alakuijala, [HN 27163981](https://news.ycombinator.com/item?id=27163981): *"Static dictionary is not
why Brotli reaches excellent compression density. Much of it comes from the more advanced context
modeling and in general more dynamic entropy modeling."*

**What *is* real is the token-convention effect under repetition**, and it is the sharpest place the
two compressors choose differently:

| content | raw | gzip | brotli |
|---|---:|---:|---:|
| `var x=true,y=false;` × 20 | 380 | 44 | **31** |
| `var x=!0,y=!1;` × 20 | 280 | **38** | 36 |
| `var x=undefined;` × 20 | 320 | 41 | **28** |
| `var x=void 0;` × 20 | 260 | **36** | 34 |

**The `booleans` transform — `true`→`!0`, the most recognisable minifier signature there is — makes
the file smaller under gzip and larger under brotli.** And the dictionary matters most where there
is no learned history, i.e. small outputs: brotli's margin over gzip on prefixes of the minified
bundle is 13.9% at 1 KB and 15.3% at 2 KB, settling to ~10% at 32 KB and above. **So it does argue
differently for a small chunk than for a large bundle — confirmed.**

### 2.5 Where gzip and brotli disagree in sign

One Terser compress option at a time on top of `terser -m` (baseline 83,372 / 22,585 / 19,841):

| option | Δ raw | Δ gzip | Δ brotli |
|---|---:|---:|---:|
| `unused` | −10,082 | **−2,120** | **−1,660** |
| `join_vars` | −3,615 | −339 | −149 |
| `conditionals` | −1,601 | −127 | −71 |
| `booleans` | −685 | −106 | −81 |
| `evaluate` | −503 | −99 | −42 |
| `inline` | −489 | −87 | −59 |
| `reduce_vars` | −458 | −86 | −81 |
| `comparisons` | −497 | −86 | −12 |
| `if_return` | −601 | −51 | **+6 (worse)** |
| `sequences` | −351 | −12 | −52 |
| `collapse_vars` | −480 | −25 | **+60 (worse)** |

**Two transforms have opposite signs between the compressors: `if_return` and `collapse_vars` both
shrink gzip and grow brotli.** From the other direction on the full recipe, disabling `inline` costs
254 raw bytes and *saves* 3 gzip and 4 brotli — the "inlining duplicates bodies" hypothesis,
confirmed in sign; disabling `sequences` costs 36 raw and saves 23 gzip and 31 brotli.

**The magnitudes are tiny — 6 to 60 bytes on a 15 KB artifact, under 0.4%. Do not build a policy on
them.** The disagreements that matter are the large ones: `booleans` (§2.4) and chunk granularity
(§2.6). Under a brotli-primary objective, `booleans`, `if_return`, `collapse_vars` and `sequences`
should simply not be implemented — convenient, since §5.1 shows they are worth almost nothing anyway.

### 2.6 Splitting costs more under brotli than under gzip

Summed compressed size of N equal chunks against one whole file — `app.js`, 206,002 bytes:

| chunks | Σ gzip | vs whole | Σ brotli | vs whole | brotli's margin |
|---:|---:|---:|---:|---:|---:|
| 1 | 38,727 | — | 32,609 | — | 15.8% |
| 2 | 39,142 | +1.1% | 33,593 | **+3.0%** | 14.2% |
| 4 | 39,858 | +2.9% | 34,745 | **+6.6%** | 12.8% |
| 8 | 41,270 | +6.6% | 36,005 | +10.4% | 12.8% |
| 16 | 44,158 | +14.0% | 38,534 | +18.2% | 12.7% |
| 32 | 48,056 | +24.1% | 41,920 | +28.6% | 12.8% |

**Confirmed: splitting costs roughly twice as much, relatively, under brotli as gzip suggests at low
chunk counts** (+6.6% vs +2.9% at four chunks), because brotli had more cross-file redundancy to
lose. Brotli still wins absolutely at every count, but its margin erodes from 15.8% to ~12.8%. On the
smaller minified bundle the penalties are steeper (+8.5% brotli at four chunks, +22% at sixteen), and
a **boundary-aligned split** — cutting at statement boundaries rather than arbitrary byte offsets —
reproduces the figures to within 0.2%, so this is a compression-window effect, not broken tokens.

**And it has been measured independently, at file granularity, on a production site.** Khan Academy,
[Craig Silverstein, 23 Nov 2015](https://blog.khanacademy.org/forgo-js-packaging-not-so-fast/),
comparing 28 bundled files against the same code as 296 individual files:

| | bundled (28 files) | individual (296 files) |
|---|---:|---:|
| uncompressed | 2,421,176 B | 2,282,839 B (**−5.7%**) |
| compressed | 646,806 B | **662,754 B (+2.5%)** |

Finer granularity *reduced* uncompressed bytes and *increased* shipped bytes. Their conclusion:
*"JavaScript packaging is here to stay."* **This is the cleanest published corroboration that the
chunk-count penalty is real, and it bites at file granularity — declaration granularity is strictly
worse.**

### 2.7 How beni should measure this

1. **Report brotli as the headline, gzip as secondary, raw as a diagnostic only** — and never set a
   target in raw bytes.
2. **State the compressor settings, because the defaults are not what you think.** nginx's
   `ngx_brotli` defaults are **`brotli_comp_level 6`** and **`brotli_window 512k`**
   ([ngx_brotli](https://nginx.googlesource.com/ngx_brotli/)) — not quality 11, not 16 MB. At those
   settings brotli's advantage over gzip on `app.js` collapses from **15.8% to 6.0%** (36,694 vs
   39,055). Meanwhile `lgwin=19` (512 KB) and `lgwin=22` give **byte-identical** results on every
   file here, because all are under 512 KB. **For any bundle under 512 KB the window question is
   moot in deployment; the quality setting dominates.** Track two columns: `brotli -q 11` as the
   achievable floor and `brotli -q 6 -w 512k` as the realistic deployment number.
3. **Corpus:** `bench/gen.zig --generate=100000` output once M3 emits, plus one real application,
   plus Elm's TodoMVC compiled by both compilers as the cross-compiler comparison. The size target is
   **9,148 gzipped bytes**, from the [Elm guide's asset-size page](https://guide.elm-lang.org/optimization/asset_size)
   — *not* `hints/optimize.md`, which 03 §6 cited and which contains no such figures (verified
   against `references/elm` at `1bd5b36`).
4. **Tooling.** Zig's std has `flate`, `lzma`, `lzma2`, `xz` and `zstd` and **no brotli** — confirmed
   in the vendored `references/zig/lib/std/compress/`. For the *benchmark*, shell out to the system
   `brotli` binary and pin it in the flake: two lines, and the encoder stays out of beni. For
   *emitting* pre-compressed artifacts the cost is materially higher — a brotli encoder is a large
   piece of code and the 122,784-byte static dictionary must be embedded verbatim to be conformant.
   **Recommendation: pin the binary for benchmarking; do not emit compressed files.** Every static
   host and CDN already compresses, `flate` in std covers gzip if a fallback is ever wanted, and the
   one genuine argument for emitting — that offline `-q 11` beats a server's on-the-fly `-q 6`, worth
   the 6.0%→15.8% gap above — is better served by a documented one-line post-build command than by
   vendoring an encoder into the compiler.

---

## 3. Chunking: how boundaries are computed

### 3.1 One algorithm, four times

Four projects converged on **entry-set colouring**: give every unit of code the *set of entry points
that can reach it*; units with the same set go in the same chunk. Correct by construction, and chunk
count is bounded by the number of distinct reachability sets.

| System | Unit | Representation | Source |
|---|---|---|---|
| **esbuild** | file | `entryBits`, a plain `[]byte` bitset; `String()` is the map key | `internal/linker/linker.go`, `computeChunks` |
| **Rollup** | module | reachability is `Set<number>`; the **chunk signature** and the second-level *atom* sets are `BigInt` | [`chunkAssignment.ts`](https://github.com/rollup/rollup/blob/master/src/utils/chunkAssignment.ts), 1,018 lines |
| **dart2js** | **element (declaration)** | `ImportSet`, an interned trie in canonical import order | [`deferred_load.dart`](https://github.com/dart-lang/sdk/blob/main/pkg/compiler/lib/src/deferred_load/deferred_load.dart) |
| **Scala.js** | class | minimal prefixes of dynamic-import paths, hashed to a module ID | [`modulesplitter/Tagger.scala`](https://github.com/scala-js/scala-js/tree/main/linker/shared/src/main/scala/org/scalajs/linker/frontend/modulesplitter), 341 of 1,184 lines |

Rollup's header states it plainly: *"first starts from each static or dynamic entry point and then
assigns that entry point to all modules than can be reached via static imports… Then we group all
modules with the same dependent entry points into chunks as those modules will always be loaded
together."*

dart2js gives the two sentences beni needs. On the main chunk:

> "The main output unit contains any code accessed directly from `main`. Such code may be accessed by
> deferred imports too, but because it is accessed from the main entrypoint of the program,
> **possibly synchronously**, we do not split out the code or defer it."

And on the exponential objection, directly:

> "**In theory, there could be an exponential number of output units: one per subset of deferred
> imports in the program. In practice, large apps do have a large number of output units, but the
> result is not exponential.** This is both because not all deferred imports have code in common and
> because many deferred imports end up having the same code in common."

Its scaling trick is hash-consing the colour, and it says why: *"many of such sets had the same
imports… This led us to design the `ImportSet` abstraction: a representation of import-sets that
guarantees that each import-set has a canonical representation."* The honest caveat is in the same
comment — *"Simple operations, like adding an import to an import-set, are now worse-case linear"* —
which is why the algorithm was restructured into a two-tier worklist doing bulk DFS updates that
stop at merge points.

**The representation choice is not cosmetic.** Rollup's naive Set-based version of its
already-loaded optimisation was O(entries × dynamic imports × modules); [PR #4862](https://github.com/rollup/rollup/pull/4862)
replaced it with BigInt masks and took a real Vite build (1 static + **1,450 dynamic entries**,
~10,000 modules) from **over two hours to ~600 ms** for the chunking step, with the same 1,742
chunks.

**Webpack is the odd one out and should not be copied.** `SplitChunksPlugin` is a size-and-request
budget heuristic over chunks that already exist, and its default `chunks: "async"` only regroups
chunks created by `import()`. It will duplicate a module into several chunks; the bitset family
cannot duplicate at all. Rolldown's design doc states the trade: webpack *"accepts code duplication
as acceptable when reducing HTTP requests"*, while the colouring family gives a *"zero duplication
guarantee"* and *"deterministic output"* but *"can produce many small chunks."* Measured, from
Rolldown's [RFC on small common chunks](https://github.com/rolldown/rolldown/discussions/10693):
GitLab saw **143–305 initial JS requests** on Vite/Rolldown against **7–24** on Rspack. (That figure
is the RFC's claim; the linked GitLab issue does not contain the table.)

### 3.2 (a) Declaration granularity: yes — four systems, all whole-program compilers

| System | Unit | How the boundary is computed |
|---|---|---|
| Closure `CrossChunkCodeMotion` | top-level statement, grouped per global symbol | move to `getSmallestCoveringSubtree` of all chunks holding immovable references |
| Closure `CrossChunkMethodMotion` | prototype method | same, plus a stub left behind |
| **dart2js** output units | class / member / field / constant | interned `ImportSet` colouring |
| **GWT** exclusive fragments | field / method / declared type | `Live(all) − Live(initial ∪ every other split point)` |
| Doloto (FSE 2008) | **function** | profile-guided temporal clustering |

**What they have in common is the precondition: every one owns its whole program and can prove
side-effect-freedom. No JS bundler can — it must guess (`sideEffects: false`, `/*#__PURE__*/`).**
That precondition is exactly what §9.1 claims for beni.

Closure's [`CrossChunkCodeMotion.java`](https://github.com/google/closure-compiler/blob/master/src/com/google/javascript/jscomp/CrossChunkCodeMotion.java)
(806 lines) is the most instructive, because its guard list enumerates what makes declaration-granular
motion dangerous in JavaScript:

1. **"Statements that do not declare global variables are assumed to exist for their side-effects and
   are considered immovable."**
2. A reference from a non-declaration statement **anchors** the variable to that chunk.
3. Symbols are grouped into `GlobalSymbolCycle`s by SCC and processed in reverse-dependency order,
   *"so statements for GlobalSymbol X will only be moved after all statements that refer to X have
   already been moved"* — a topological sweep, not a fixpoint.
4. `x instanceof Foo` needs only *declaration*, not *initialisation*, so counting it as a real
   reference would block most useful motion. Closure instead rewrites the site: *"Wrap `foo
   instanceof Bar` in `('function' == typeof Bar && foo instanceof Bar)`"*.

**All four are vacuous in beni.** (1) and (2) are about top-level side effects, which a pure language
does not have. (3) is about observable initialisation order, which it also does not have. (4) is
about dynamic type tests, which beni does not emit. **Closure spent 806 lines mostly proving that
moving code was safe; beni gets that proof from the type system.**

Two more data points that declaration granularity is normal in *compilers* and rare only in
*bundlers*: Haxe's `-dce full` eliminates at class and field level and then drops emptied classes
([manual](https://haxe.org/manual/cr-dce.html)), with the familiar caveat *"may fail when dynamic or
reflection is involved"*; and GHC's JS backend links at **STG binding-group granularity** — Luite
Stegeman: blocks *"are the smallest units of code that can be linked."*

### 3.3 What actually breaks — economics and load order, not the algorithm

**Compression, first and largest.** §2.6: four chunks cost ~6.6% of brotli'd bytes and sixteen ~18%
before any chunk has saved anything, corroborated by Khan Academy's +2.5% at file granularity.

**Initialisation order — and note this already breaks at *module* granularity.** esbuild
[#399](https://github.com/evanw/esbuild/issues/399) (still open, and in its docs): hoisting a shared
module into its own chunk places it *before* the entry-specific init it depends on. Rolldown
[#7473](https://github.com/rolldown/rolldown/issues/7473): `ReferenceError: Cannot access 'create'
before initialization` in production, on a site with **575 chunks**. Rollup emits `CIRCULAR_CHUNK`
because a bad grouping can make the *chunk* graph cyclic when the module graph is not. GWT pays with
a whole repair pass whose own javadoc concedes *"in some cases actual dependencies **differ** between
Java AST and the final JavaScript output"* — and **every fixup demotes the atom to leftovers**, so
correctness repair directly inflates the shared chunk. **A pure language with no top-level effects
has no initialisation order to violate, which removes the single most common failure in this list.**

**Declaration-granular motion assumes one shared global scope — and ESM does not give you one. This
is the sharpest conflict in the whole report, because §9.5 commits beni to both.** Closure is the
only system that does declaration-granular chunking *and* has an ESM output mode, and the two do not
work together. [closure-compiler#4264](https://github.com/google/closure-compiler/issues/4264),
**still open**: cross-chunk motion relocates a function that assigns a variable owned by another
chunk, and the compiler emits an assignment to an imported binding — `Imported symbol "a" in chunk
"other.js" cannot be assigned (defined in "base.js")`. **Code is relocated without synthesising the
matching export/import.** (Not solely `CrossChunkCodeMotion`'s fault: the same issue names
`earlyInlineVariables` collapsing an object into a plain variable that then gets referenced across
chunks, absent `@nocollapse`/`@noinline`.) A sibling failure,
[#3752](https://github.com/google/closure-compiler/issues/3752), is a `const` left behind when the
class closing over it moved deeper — it works with `var` and breaks with `const`. That issue is
closed with no merged fix visible on it, and the wiki carries the limitation: chunks *"are intended
to be loaded as scripts, not JS modules. If you load them as JS modules, you may have problems with
some global variables not being available when you expect them to be."* (Whether the doc change was
the *resolution* of #3752 could not be confirmed; the two facts are reported separately.)
**beni must synthesise cross-chunk `import`/`export` bindings as part of chunk assignment, not after
it** — esbuild's `computeCrossChunkDependencies` is the model, and it is a real pass (it records
`Symbol.ChunkIndex` per top-level declaration and rewrites out-of-chunk uses into real ESM imports),
not an afterthought. Budget it alongside the assigner.

**Cycles introduced by the grouping itself.** Scala.js needed an extra tag (`maxExcludedHopCount`)
and a written acyclicity proof to keep `SmallModulesFor` from creating `a' ↔ c` cycles — and two of
that proof's three lemmas are marked "(unproven)" by its own authors. Rollup's
`getAdditionalSizeAfterMerge` returns `Infinity` if a merge would create one.

**Chunk-count explosion — and every system that shipped grew a re-coarsening pass to undo its own
precision.** Rollup `experimentalMinChunkSize`, GWT `-XfragmentCount`, Scala.js `FewestModules` *as
the default*, Rolldown's chunk optimiser, and Qwik's Insights product — Qwik emits one chunk per `$()`
symbol and its own docs concede *"The client will have to make many requests to load all of the
chunks, often leading to undesirable waterfall requests… The optimal solution is somewhere in the
middle."* **The colouring is the correct part; the merge pass is the necessary heuristic part, and
beni needs both.** dart2js quantifies the tax it is undoing: on one app, of 370 emitted parts,
**53 were completely empty**, and *"the overhead of an empty part is currently 1080 bytes"*
([sdk#29572](https://github.com/dart-lang/sdk/issues/29572)); a later survey
([sdk#52870](https://github.com/dart-lang/sdk/issues/52870), open) lists part files holding a single
enum value and *"~500"* holding one type-literal constant.

**The counter-evidence, and it is the strongest argument *for* declaration granularity.** dart2wasm
moved from **library** to **static-element** granularity in Dec 2025 and *"shrinks essentials main
module by 13% (−1.4 MB)"*, with a follow-up that stops dragging in every instance member when a class
is enqueued saving *"around 730 KB (−7.7%)"*. That is the same granularity step beni is proposing,
measured, on a real application, in the right direction — and it is the only such number this report
found. Set against §2.6's ~6.6% compression tax at four chunks, **declaration granularity plausibly
pays, but only if the merge pass keeps the chunk count low.**

**GWT's leftovers problem is the warning for a single shared chunk.** Every exclusive fragment has
leftovers as a hard prerequisite, and `getCommonAncestorFragmentId` returns leftovers for *any* two
exclusive fragments. [gwt#6611](https://github.com/gwtproject/gwt/issues/6611) — leftovers *"can
become rather large"* — was never fixed, and Lex Spoon's own comment says why: *"it makes sense in
principle to have more than one leftovers fragment. **It's simply devilish to come up with a precise
splitting algorithm that does so.**"* Sixteen years on, GWT still has exactly one.

**Compile time and memory are the best-documented costs, and all three systems blew up before they
were fixed.** GWT's exclusivity computation is F² whole-program traversals —
[gwt#10395](https://github.com/gwtproject/gwt/issues/10395) (open, community-reported): *"with 122
split points that is ~15,000 traversals… **CodeSplitter is 181s of an 11-minute compile**"*. Rollup's
pre-BigInt chunk assignment took **over two hours** on 1,450 dynamic entries
([PR #4862](https://github.com/rollup/rollup/pull/4862)). dart2js on a real app with **401 deferred
libraries** produced 5,682 output units, 2.9M `ImportSet` instances and **~5 GB of heap**
([sdk#41925](https://github.com/dart-lang/sdk/issues/41925)) before the `_previous` back-pointer
representation fixed it; a later commit notes *"most `ImportSet._transition` maps have one entry"*
and switching to a small-map representation *"reduces the memory footprint of the ImportSets by 70%"*.
Scala.js still OOMs at a **10 GB** heap on ~128 `js.dynamicImport` sites
([scala-js#4985](https://github.com/scala-js/scala-js/issues/4985), open), *"about 98% of it from
`Tagger#allPaths`"*, with the maintainer's own verdict: *"this is almost certainly an algorithmic
issue in the FewestModules analyzer (this is what happens if you build an algorithm yourself)."* The
uncontradicted diagnosis is that its DFS traversal order searches for shortest paths depth-first;
**a breadth-first order would fix it, and that is worth knowing before writing the pass.**

**beni's §2 budget makes this a live risk, and the mitigations are known in advance:** hash-cons the
colour (dart2js), keep set operations on interned identity comparisons, bulk-update with a two-tier
worklist, and do not walk a path lattice depth-first.

**Cross-chunk names must be stable — and this, not purity, is Elm's actual blocker.** Mario Rogic:
Elm's *"DCE is actually not DCE at all, it's LCI (live code inclusion)"* — it pulls in what `main`
reaches *while simultaneously renaming symbols*, so *"each code split segment would have a unique
'fingerprint' of obfuscation"*
([gist](https://gist.github.com/supermario/629b4135657df19e6f4ff18bfcbbeb72)). Rollup pays for this
with `deconflictChunk.ts` (266 lines). **This is an implementation choice about name assignment, not
a property of TEA or of purity**, and beni avoids it by assigning cross-chunk-visible names from a
stable whole-program table.

**And chunking may not pay at all at small sizes.** Attributing every byte of the unminified bundle
to its owning declaration:

| Origin | bytes | share |
|---|---:|---:|
| hand-written kernel/native JS (scheduler, virtual-dom, `Native_*`) | 93,786 | 45.5% |
| `core` | 57,923 | 28.1% |
| `html` | 26,258 | 12.7% |
| **the application's own code** | **21,338** | **10.4%** |
| `virtual_dom` | 1,818 | 0.9% |

**90% is runtime plus library, reachable from every route, and no chunker can split it.** The ratio
inverts as application code grows, but the expectation stands: chunking is a large-application
feature, and a small application must not pay a manifest — or §2.6's compression penalty — for it.

### 3.4 There is no theory here, and that is worth knowing

**No paper proves code splitting NP-hard, and no paper formulates it as an optimisation problem with
an objective function.** The strongest assertion in the whole ecosystem is a *deleted code comment*
in GWT 2.5.1's `CodeSplitter2.java`: *"We haves pinned down that fragment partition is an
NP-Complete problem that maps right to weight graph partitioning"* — no reduction given, class
removed in 2.6.0. GWT's algorithm was never published: Spoon reports the paper was rejected twice,
one reviewer saying *"it can't be done, because you can't do static analysis on JavaScript"* and
another that *"it's trivially easy."*

The one real system paper is **Doloto** (Livshits & Kıcıman, FSE 2008,
[doi:10.1145/1453101.1453151](https://doi.org/10.1145/1453101.1453151)) — **function-granularity,
profile-guided, threshold-based temporal clustering**, explicitly file-agnostic. Measured initial
download reduction: Chi game 45%, BunnyHunt 55%, Live.com 46%, Live Maps 45%, Google Spreadsheets 38%
(39–46% gzipped), producing 126–153 clusters, with the paper's own caveat that *"the number of
clusters is quite sensitive to the threshold selection"* and that background prefetch of the
remainder cost **30–63% extra time**. The modern descendant is Turcotte, Gokhale & Tip, *"Increasing
the Responsiveness of Web Applications by Introducing Lazy Loading"* (ASE 2023,
[doi:10.1109/ASE56229.2023.00192](https://doi.org/10.1109/ASE56229.2023.00192)): initial size
**−36.2%**, load time −29.7% on ten apps, splitting at npm-package granularity, emitting
*suggestions* because the analysis is unsound. **beni's analysis is sound, which is the whole
difference.**

---

## 4. (b) The language-level trigger — the hard question

### 4.1 A trigger can live in exactly three places

| | Where it lives | Examples |
|---|---|---|
| **A** | **an expression** evaluating to a pending value | JS `import()`, Scala.js `js.dynamicImport`, GWT `GWT.runAsync` |
| **B** | **a declaration** — a marker on an import, function or route | Dart `deferred as`, Leptos `#[lazy]`, PureScript's proposed `lazy import` |
| **C** | **outside the source** — build config or file layout | Closure `--chunk`, webpack entries, SvelteKit's route tree |

beni has lost only **A**, and only because it has no `import()`.

### 4.2 C alone cannot create laziness

The tempting answer — declare chunks in build config, no language change — is refuted by the tools
that offer it. webpack's `splitChunks` defaults to regrouping only chunks that exist *because someone
wrote `import()`*. Rollup's `manualChunks` assigns modules to chunks and makes nothing lazy. Closure's
`--chunk <name>:<num-js-files>[:[<dep>,...]]` assigns membership by *counting source files off the
`--js` list in order* — positional, out-of-band, and purely a partition of eagerly-loaded code. These,
webpack multi-`entry` and GHCJS's base bundles are all **multiple eager entry points**: several
programs sharing code, not laziness within one.

The route-table hypothesis fails the same way. Angular's declarative-looking table is
`{ path: 'items', loadChildren: () => import('./items/items.module') }`. Next.js offers exactly
`next/dynamic` and `React.lazy()`, both source-level. SvelteKit's per-route splitting from the
`+page.svelte` tree is closest to a zero-marker trigger — and the framework *generates the `import()`
for you*. **No system splits from a route table with no dynamic import anywhere; the frameworks write
the marker on the developer's behalf.** That remains available to beni, but as codegen, not semantics.

dart2js's constraint files are the one genuine C-level mechanism with teeth, and note what they do:
`ImportSetTransition` lets you declare "if import X is loaded, treat Y as loaded too", run to a
fixpoint. **That is manual *coarsening* of a partition the language already created — the analogue of
`manualChunks`, not a trigger.**

### 4.3 The cost everyone else pays, and why beni has already paid it

Every shipped trigger changes a type at the boundary: Dart a `Future`, Scala.js a `js.Promise`, GWT a
callback, Leptos sync→async (*"In both cases, the final function will be async and must be called as
such"* — [`#[lazy]` docs](https://docs.rs/leptos_macro/latest/leptos_macro/attr.lazy.html)). TC39's
[`import defer` proposal](https://github.com/tc39/proposal-defer-import-eval) states why that hurts:
dynamic `import()` *"forces all functions and their callers into an asynchronous programming model,
without necessarily reflecting the real intention of the program."*

**This is the finding that should shape beni's answer. Asyncification is the universal cost of code
splitting, and beni has already paid it.** In a language whose effects are values interpreted by a
platform (§3.1), everything effectful is already a `Task`/`Cmd`; a value arriving through a `Task`
colours nothing that was not already coloured. The function-colouring objection that dominates Dart,
Scala.js and Leptos does not apply here.

The flip side is the binding constraint, and it is dart2js's rule: **anything reachable from a pure
position cannot be deferred.** `view : Model -> Html Msg` cannot await. beni's split boundary must
coincide with a boundary the effect system already recognises — a real restriction, and a precise one.

### 4.4 Three further constraints from the precedents

**Granularity is the compiler's to choose, not the programmer's.** Scala.js is blunt: *"Scala.js only
splits into modules along class boundaries. Therefore, do not put the heavy feature implementation in
another method of `MyApp`, that is called from the `js.dynamicImport` block"*
([module docs](https://www.scala-js.org/doc/project/module.html)). The marker says where a boundary
*may* fall; the compiler's own unit of code decides where it *does*. beni's unit is the top-level
declaration — finer than any precedent, which makes marker placement less fragile than Scala.js's.

**Split points are fragile under whole-program reachability, and the failure is silent.** GWT: *"there
will be a stray reference to that subsystem somewhere reachable without going through a split point.
That reference can be enough to pull much of the subsystem into the initial download."* Its issue
tracker is a catalogue of whole-program optimisation defeating the splitter — devirtualisation and
inlining pulling a callback body into the initial fragment ([#3457](https://github.com/gwtproject/gwt/issues/3457));
a superclass method calling an abstract method making all subclasses live so nothing is exclusive
([#4412](https://github.com/gwtproject/gwt/issues/4412)); splitting working under `-draftCompile` and
collapsing without it ([#8486](https://github.com/gwtproject/gwt/issues/8486)). **beni needs GWT's
leftovers concept and, more importantly, a diagnostic naming the stray reference**: "`Admin.Dashboard.render`
is reachable from `view`, so it cannot be deferred" is the difference between a usable feature and a
silent one. Note that §9.3's saturated-call specialization is exactly the kind of whole-program pass
that defeated GWT's splitter — the interaction must be designed, not discovered.

**Types need not be deferred, and the boundary needs no runtime check.** Dart's restrictions —
*"A deferred library's constants aren't constants in the importing file"* and *"You can't use types
from a deferred library in the importing file"* — are attributed by the Dart team itself, in
[language issue #1149](https://github.com/dart-lang/language/issues/1149), to Dart 1.0 lacking
inference and to implementations that coupled types and classes; they now favour allowing deferred
type references. **beni erases types entirely, so a beni split can be fully type-transparent: only
values need deferring.** (The constant restriction is real and beni must decide what a deferred value
means to its folder.)

**Decide it up front, though, because dart2js shipped this wrong and had to retrofit.** Its output
units are computed over five node kinds, two of which are the same class: `ClassEntityData` (the
body) and **`ClassTypeEntityData` (the runtime type, partitioned separately)** — so a class body can
be tree-shaken while its type survives in another unit. That split was added after
[sdk#35311](https://github.com/dart-lang/sdk/issues/35311) found Dart 2 inference synthesising
deferred types users cannot write, which dart2js had been deferring **unsoundly**; DDC and the Dart
VM still couple the two and cannot do it. beni's erasure makes the question vanish — a real, free
advantage over the closest precedent, worth stating in §9.5 rather than leaving implicit.

And the type-safe-dynamic-loading literature — Alice ML's `Package.unpack`
(*"If the signature doesn't match the type of the module stored then a runtime exception occurs"*),
Clean's Dynamics, OCaml's `Dynlink` (*"No facilities are provided to access value names defined by
the unit"*, forcing self-registration into mutable tables, which a pure language cannot do) — all pay
a dynamic check because the loaded code is *unknown at compile time*. **beni's chunks come from the
same compiler in the same build, so the type is known statically. beni's case is strictly easier than
every prior art here.**

### 4.5 Four candidate designs, ranked

**1 — `lazy` on a declaration, rewriting its type into the effect language.** *Recommended.*

```
lazy adminDashboard : Model -> Html Msg      -- as declared
-- as seen by every importer:  Task LoadError (Model -> Html Msg)
```

*Precedent:* the strongest available. Leptos ships exactly this (`#[lazy]` plus `cargo leptos build
--split`), and a Roc contributor named Leptos-style annotation as Roc's likely path for this exact
problem ([Roc Zulip, 2026-08-27](https://roc.zulipchat.com/#narrow/channel/304902-show-and-tell/topic/Joy.20web.20platform!/near/619570171):
*"for Rust/Roc it is not a language feature… Leptos has pulled off WASM binary splitting… it is using
macros which insert special annotations"*). *Cost:* the declared type and the use type differ — a real
readability hazard needing good diagnostics. *Why it wins:* one keyword; no module-as-value notion;
the split point is a declaration, already beni's DCE unit; sound with no runtime check.

**2 — Deferred import declaration plus load-as-effect.** Dart's design with the trigger moved into the
effect language: `import Admin.Dashboard deferred as Dashboard`, then `Task.load Dashboard`.
*Precedent:* Dart (shipped, whole-program) and PureScript's proposed-never-implemented `lazy import`.
*Cost:* needs a module-as-value notion at the boundary that `language.md` §5 gives no room for —
strictly more language surface than candidate 1 for the same power.

**3 — Split at the route boundary, declared in a route table.** *Recommended as sugar over 1, not
instead of it.* Leptos's `#[lazy_route]` is the real analogue, and its documented reason to exist is
worth copying: it splits a route's `view()` from its `data()` so they load concurrently, "to prevent a
waterfall, in which you wait for the lazy view to load, then begin loading data". The router already
returns effects, so the async is free, and routes are where a TEA-shaped application's splits are.

**4 — First-class deferred code values, `LazyRef a` passed as data.** *Reject.* **The one candidate
with no working precedent in any language.** Unison considered lazy dependency shipping — *"If doing
this lazily, could spare sending definitions for code paths not used during this particular
execution"* — and the reply was *"Sounds super fragile."* It also maximally triggers GWT's
stray-reference failure: a `LazyRef` passed as data is precisely how you create a reference the
reachability analysis cannot see through.

**Recommendation: candidate 1, with candidate 3 as sugar.** One keyword, one type rewrite,
declaration granularity matching the DCE graph, no runtime check, no module values — and the
asyncification cost already paid by the effects model.

### 4.6 Elm, for the record

Elm has no code splitting and the official advice is not to want it
([Elm guide](https://guide.elm-lang.org/optimization/asset_size)); `roadmap.md` in `references/elm`
does not mention it. Evan's stated reason is that the design question is open, not that it is
impossible: *"Do you cut along packages? Modules? Functions? How do you draw those lines? For fastest
first load? For caching that makes all subsequent loads faster?"*, with *"instead of designing purely
on instinct, we will first gather information"* and no timeline. **The mechanical obstacle is
LCI-plus-renaming (§3.3), not TEA and not purity** — nobody has shown that The Elm Architecture
semantically resists splitting, so the precedent's silence is not evidence against candidate 1.

---

## 5. Minification without a minifier: what we must build

### 5.1 The transformations, ranked by compressed bytes

From §2.5, under a brotli objective:

1. **`unused` — 1,660 brotli bytes, 66% of the entire compress layer's win**, more than every other
   transform combined. Elm had already done top-level DCE here, so what `unused` finds is *local*
   dead bindings — codegen temporaries. beni's §9.1 graph handles the top-level half with proof; the
   local half is a use-count pass over `JsIr` before printing, and it is the single highest-value
   compress transform there is.
2. **`join_vars` (−149) and `conditionals` (−71)** — and both are **printer decisions, not optimiser
   passes**: emit one `var` with a comma list, and lower a two-armed conditional whose arms are
   expressions to `?:` rather than `if`/`else`. Free.
3. **Everything else is ≈0, and four are negative under brotli.** `booleans` is the most famous
   minifier trick in existence and §2.4 shows it makes brotli output *larger*; `if_return` and
   `collapse_vars` are outright negative. Terser ships **58 compress options** across a 6,536-line
   `lib/compress/`; on ML-family compiler output, three do all the work.

Layer by layer, with the compressed number as the objective:

| Layer | raw | brotli | Δ brotli |
|---|---:|---:|---:|
| unminified | 206,002 | 32,609 | — |
| + whitespace/punctuation | 161,229 | 26,431 | −18.9% |
| + short identifiers | 83,372 | 19,841 | −24.9% |
| + the three compress transforms worth having | 53,585 | 14,980 | −24.5% |

**No layer dominates: skipping any one costs about a quarter of the delivered bytes.** And
minification is *not* subsumed by compression — brotli alone takes 206 KB to 32.6 KB, minifying first
takes it to 15.0 KB, so minification is worth **54% of the delivered payload**.

### 5.2 Where the bytes are, and what beni should emit

Of the unminified file: **identifiers are 137,629 bytes (66.8%)**, of which package-qualified globals
are **54,771 (26.6%)**; whitespace is 40,100 (19.5%).

**beni should never emit long qualified names in release mode.** Elm emits them because it delegates;
a compiler that owns the pipeline assigns short names directly from the whole-program declaration
table and captures most of that 26.6% with no renaming pass at all. Rank them by usage frequency —
Elm already does this for record fields (`Generate/Mode.hs:44-62`) and beni inherits the same counters
from §9.1 for free. Then order the alphabet for the compressor (§2.2): ~100 lines, and beni can
compute the histogram over its **own output** rather than approximating from input as esbuild must.
Percent-level; do not over-prioritise. The larger prize is §2.2's **ambiguation**.

**Frequency ordering is near-universal, and the two holdouts are leaving bytes on the table.** Closure
(`frequencyComparator`, descending), dart2js, Scala.js (`comparingInt(_.occurrences).reversed`) and Elm
all sort by frequency; **GWT allocates sequentially per scope and Kotlin/JS's `MinimizedNameGenerator`
is literally `index++`**, first-come-first-served.

**But frequency ordering fights §10's determinism requirement, and dart2js is the only project that
solved it.** `naiveFrequencyAssignment` is documented in dart2js's own source as *unstable* — "small
changes in the input cause large changes in the output" — so it ships `semistableFrequencyAssignment`,
which **over-allocates the name pool 3× and places each item in a hash-derived "preferred slot"**,
deliberately trading bytes for output stability. Closure reaches the same goal differently, with
`--variable_map_input_file` / `--property_map_input_file` feeding the previous build's assignment back
in, and `RenameVars` assigns same-length names in source order so *"symbols declared close together
are assigned names that are quite similar"* (§2.2). beni needs one of these: §10 makes byte-identical
output across two runs a hard requirement, and §3.3 makes stable cross-chunk names a precondition for
chunking at all. **Frequency-ranked naming is not free; it comes with a stability obligation.**

### 5.3 Property/field renaming: measured, and smaller than advertised

`terser --mangle-props` on top of the full recipe: 53,585 → 49,064 raw (−8.4%), 14,980 → 14,398
brotli (−3.9%). **An upper bound, and the output is almost certainly broken** — blanket property
mangling is unsafe, which is why Terser keeps it off — but it bounds the prize. Whole-program field
renaming, the one transformation §9.5 always reserved for beni, is worth roughly **4% of brotli'd
bytes** here, consistent with Evan's own *"5% to 10%"* for Elm.

Scala.js calibrates the other end. Its 1.16.0 minifier *"compresses all **property** names (fields
and methods) of Scala classes"*, assigning *"shorter names to the most frequent ones"* — Elm's
algorithm — and moved Scala.js from *"several **times** bigger than the Closure output"* to *"around
15% bigger than Closure"* ([announcement](https://www.scala-js.org/news/2024/03/19/announcing-scalajs-1.16.0/)).
Far bigger than 4%, because Scala classes have vastly more distinct member names than an Elm-style
record surface. **Expect beni nearer Elm's 4–10% than Scala.js's several-fold.**

### 5.4 What a compiler that owns types gets for free

Measured: Terser with stock defaults reaches 17,508 brotli; with Elm's purity-derived flags, 14,980.
**Purity knowledge alone is worth 14% of delivered bytes** — handed over as a command-line string
because Terser cannot verify any of it.

| beni knows | what it enables | JS minifier's fallback |
|---|---|---|
| every expression is pure | unconditional DCE, reordering, dedup | `/*#__PURE__*/`, `sideEffects: false` guesses |
| every field access site | safe property renaming, and **ambiguation** | off by default; `--mangle-props` breaks code |
| no `obj[dynamicString]` exists | the above, unconditionally | must assume dynamic access |
| every call site's arity | direct n-ary calls, no `A2` adapter (§9.3) | none |
| a `case` is exhaustive (the checker's exhaustiveness pass) | drop the default branch and its throw | none |
| a value is an unboxed `Int` | `===` with no `typeof` guard | none |
| constants across module boundaries | whole-program constant propagation | blocked unless bundled |

Closure's `PureFunctionIdentifier` shows the gap from the other side — it is **name-based, not
call-graph-based**: *"Functions are not tracked individually but rather in aggregate by their name…
**it's impossible to determine exactly which function named 'foo' is being called at a particular
site.**"* beni has a resolved call graph and a pure language, so it gets per-callee purity exactly.

**But do not over-claim for types specifically.** Closure's own FAQ: *"Do I need to write type
annotations to take advantage of Advanced Optimizations? **No, but it helps.** Many of the advanced
optimizations don't really use type information at all. **The big wins in advanced optimizations come
from externs and exports.**"* The dominant advantage is **the closed world**, not the type system —
and the closed world is exactly what §9.1's graph already is.

### 5.5 The honest counter-evidence

Scala.js's `StandardConfig.minify` documentation:

> "The focus is on optimizations that general-purpose JavaScript minifiers cannot do on their own.
> For the best results, we expect the Scala.js minifier to be used **in conjunction with** a
> general-purpose JavaScript minifier."

Its `minify` enables a 287-line `NameCompressor` and some short-name choices; its `JSTreePrinter` has
**no whitespace-minify mode at all** (`IndentStep = 2` is unconditional). A user measurement on
[RFC #5244](https://github.com/scala-js/scala-js/issues/5244) with Closure disabled: **515 KB →
1714 KB uncompressed (3.32×); brotli −11: 115 KB → 182 KB (1.58×)**.

Two readings, both true. Against beni: a mature type-aware compiler minifier still expects a
downstream generic minifier, and going without cost 1.58× brotli. For beni: **Scala.js never built the
generic half** — no whitespace mode, no local mangling — so 1.58× measures the *absence* of that
layer, not the futility of building it. §5.1 says that layer is whitespace plus three transforms on
ML-family output, and §6 shows js_of_ocaml owns the whole thing in ~3,450 lines.

---

## 6. What it costs to build

All counts are `wc -l` on pinned checkouts. For calibration, **beni today is 32,714 lines of Zig** —
checker 9,185, parser 5,339, BIR 4,537, formatter 3,132, lexer 2,569.

| Component | Size | Anchor |
|---|---:|---|
| JS printer, whole thing | 5,025 | esbuild `internal/js_printer/js_printer.go` |
| …its whitespace-minify mode | **35 branch points**, 0 new files | 35 `MinifyWhitespace` sites in that file |
| …js_of_ocaml's equivalent | 2,322 + 276 | `js_output.ml` + `pretty_print.ml` (`PP.compact`) |
| Renamer with scope slots and collisions | **662** | esbuild `internal/renamer/renamer.go` (4 renamers, one interface) |
| …Closure's | 567 | `RenameVars.java` |
| …js_of_ocaml's short-name allocator | **212** | `js_assign.ml`, the `Min` graph-colouring strategy |
| …oxc's whole mangler crate | 1,336 / 3 files | `crates/oxc_mangler/` (`base54.rs` is 84) |
| Compressor-ordered name alphabet | ~200 | esbuild: 106 in `ast.go` + ~90 parser/linker |
| Source maps | **847 + 172 printer call sites** | esbuild `internal/sourcemap/sourcemap.go` |
| **Chunk assigner, one policy** | **1,184 / 8 files** | Scala.js `frontend/modulesplitter/` (`Tagger.scala` 341, `StrongConnect` 139, three 43–112-line policies) |
| …with size-driven merging | 1,018 | Rollup `chunkAssignment.ts` (+`Chunk.ts` 1,635, `deconflictChunk.ts` 266) |
| …Closure's entire chunk story | ~2,750 | `JSChunkGraph` 826 + `CrossChunkCodeMotion` 806 + `CrossChunkMethodMotion` 570 + `CrossChunkReferenceCollector` 544 |
| **A *general* syntax minifier** | 6,536 **+ 75,457 lines of tests** | Terser `lib/compress/` vs `test/` — a **2.7:1 test-to-code ratio** |
| Closure `jscomp/`, for scale | 180,293 / 384 files | but no single pass is large: `RenameProperties` 489, `CrossChunkCodeMotion` 806 |

**js_of_ocaml's complete self-contained minifier is ~3,450 lines** (`js_assign.ml` 520 +
`js_traverse.ml` 2,327 + `js_simpl.ml` 334 + `pretty_print.ml` 276), of which the
identifier-shortening core is **212**. It gets there by not being a general JS minifier: it handles
only the JavaScript *it* generates, from an IR it already trusts, with scope information it already
has. **That is beni's situation exactly.**

### 6.1 Against the §2 performance budget

| Minifier | MB/s | vs the 5 MB/s target |
|---|---:|---|
| @tdewolff/minify (Go) | 41–48 | clears by 8× |
| bun (Zig) | 34 | clears by 7× |
| oxc-minify (Rust) | 20–26 | clears by 4–5× |
| esbuild (Go) | 14.5–24.5 | clears by 3–5× |
| @swc/core (Rust) | 7–10 | clears |
| terser (JS) | 0.3–2.3 | **misses by 2–15×** |
| **Closure ADVANCED** | **0.06–0.16** | **misses by 30–80×** |

(Published figures from [minification-benchmarks](https://github.com/privatenumber/minification-benchmarks),
MB/s computed here. **Caveat:** that suite runs Closure in SIMPLE, not ADVANCED — its
[issue #14](https://github.com/privatenumber/minification-benchmarks/issues/14) is "Fixing the
google-closure-compiler advanced mode" — so its Closure rows are not ADVANCED evidence. The ADVANCED
figures are this report's own runs.)

1. **Minification does not threaten the budget; the implementation language and pass count do.**
   esbuild's `--minify` is measurably **not slower than plain printing** (447 ms vs 476 ms on a
   10.95 MB input; 84 ms vs 84 ms on 1.25 MB). The minifying is free; parsing and printing are the
   cost, and beni does not parse.
2. **Source maps are the real threat.** `--minify --sourcemap=external` costs **+61%** wall time on
   10.95 MB and **+42%** on 1.25 MB — the number behind Evan Wallace's *"generating source maps is one
   of the slowest things about doing a production build"*
   ([esbuild#833](https://github.com/evanw/esbuild/issues/833)). **§9.6's "off by default" is
   load-bearing for §2, not a nicety.**
3. **The chunk assigner is the other budget risk, and the mitigation is known.** GWT's splitter is
   181 s of an 11-minute compile because its exclusivity computation is F² whole-program traversals;
   Rollup's pre-BigInt chunk assignment took over two hours on 1,450 dynamic entries. **Both were
   fixed by the same move — interned/bitset colour representations with bulk updates — which is what
   dart2js's `ImportSetLattice` is.** Adopt it from the start, not after measuring a regression.
4. **Nothing threatens the 15 ms warm rebuild, because a warm rebuild must not minify.** Minification
   belongs to `beni build --release`; the dev loop prints readable names and skips renaming, the
   compress pass, chunking and source maps. That is also what makes the dev/prod split cheap: one
   printer, three booleans, as esbuild and js_of_ocaml both do it.

### 6.2 Source maps survive renaming for free — if fused into printing

esbuild does **not** patch mappings after renaming. The printer asks the renamer for each symbol's
name *at print time* and records the mapping *as it emits those bytes*, so the generated column is
post-rename by construction. Patching exists (`SourceMapPieces.Finalize(shifts)`) but only for
**linking** — banners, path substitution, cross-chunk imports. `addSourceMappingForName` carries the
symbol's *original* name in the mapping's fifth VLQ field, which is what makes a stack trace from
minified output readable. **This validates §9.6 and sharpens one point: the cost is not the 847-line
module but the 172 call sites threaded through the printer** — the part that cannot be retrofitted,
and the part §9.6 already insists on.

### 6.3 The aggregate

**Roughly 3–5k lines of Zig** for printer mode + renamer + the three compress transforms + chunk
assigner — comparable to beni's existing parser and smaller than its checker. One milestone's work,
not a second compiler. The number only explodes if beni tries to be a *general* JavaScript minifier,
which §5.1 shows it does not need to be.

---

## 7. What §9.5 must now say

**First, a correction to the brief.** §9.5 has *already* been rewritten for the full-stack decision.
This is a diff against the **current** text.

**1. *"The reference point for owning the whole pipeline is Closure Compiler's advanced mode, not
Terser."*** — **False on the evidence.** Closure ADVANCED finished **12% larger in brotli** than
Terser-with-purity-flags at **50× the wall time**, and Closure's own FAQ says the big ADVANCED wins
come from externs and exports, not analysis. Replace with:

> The reference point is **js_of_ocaml**: a compiler that owns short-name allocation, JS-level
> simplification and compact printing in ~3,450 lines, minified by default, with no external minifier
> in its dependency graph. Closure ADVANCED is the wrong model on three counts — 180k lines,
> 0.06 MB/s (80× under §2's emit budget), and no ES-module support, which is why Scala.js deprecated
> it.

**2. The list of things to build is right but unranked**, and constant folding is on it while
measuring ≈0. Replace with §5.1's ranking, and add the explicit *not* list: `booleans` makes brotli
output **larger**; `if_return` and `collapse_vars` are negative under brotli; `inline`, `evaluate`,
`reduce_vars`, `sequences`, `comparisons`, `switches` and `typeofs` are ≈0.

**3. *"Elm's TodoMVC is still the size target to beat: 122KB → 24KB → 9KB."*** — numbers right,
**citation wrong** (03 §6 attributes them to `hints/optimize.md`; they are in the
[Elm guide](https://guide.elm-lang.org/optimization/asset_size), verified against `references/elm` at
`1bd5b36`), and **units wrong**. Replace with:

> The target is the **compressed** figure and size is tracked post-compression everywhere: brotli
> primary, gzip secondary, raw as a diagnostic only. Raw byte counts invert the ranking of
> transformations — measured twice in report 12 §2.1 — and move 18% under a pure reordering that
> leaves the raw count identical. Closure's source says the same: *"Closure Compiler assumes that you
> are using gzip compression"*, and its `PerformanceTracker` measures every pass before *and after*
> gzip. Benchmarks report `brotli -q 11` as the achievable floor and `brotli -q 6 -w 512k` — nginx's
> actual defaults — as the deployment number; the two differ by more than 2× in brotli's margin over
> gzip. Zig's std has no brotli, so the benchmark shells out to a flake-pinned binary; beni does not
> emit compressed artifacts.

**4. The two open questions at the end of §9.5** become decisions:

> **Chunk assignment is per declaration**, by entry-set colouring over the §9.1 graph with the colour
> **hash-consed from the start** — dart2js's `ImportSetLattice`, adopted for the reason GWT and Rollup
> both discovered late, that the naive representation costs minutes. Closure's `CrossChunkCodeMotion`
> proves declaration-granular assignment is safe in JavaScript, and all four of its safety guards are
> vacuous in a pure language. **A size-driven merge pass runs after colouring, and its budget is set
> by compression, not request count:** four chunks cost ~6.6% of brotli'd bytes and sixteen ~18%
> before any chunk has saved anything (§2.6), corroborated by Khan Academy's measured +2.5% at file
> granularity. **Chunk assignment must synthesise the cross-chunk `import`/`export` bindings itself,
> as part of the pass** — Closure is the only system doing declaration-granular chunking with an ESM
> mode and the combination is broken there (#4264, open), because it relocates declarations without
> emitting the matching bindings. esbuild's `computeCrossChunkDependencies` is the model. Budget it
> with the assigner, not after.
>
> **The split trigger is a `lazy` marker on a top-level declaration**, rewriting its type into the
> effect language (`Task LoadError a`). Precedent: Leptos's `#[lazy]`, named by a Roc contributor as
> Roc's likely path for the same problem; and Dart's `deferred as`, whose static half this keeps and
> whose dynamic half the effect language replaces. **The asyncification cost that dominates every
> other language's version of this feature is already paid by §3.1's effects-as-values model.** The
> binding constraint is dart2js's — anything reachable from a pure position goes in the main chunk —
> so a diagnostic naming the stray reference is part of the feature, not an extra, and its interaction
> with §9.3's saturated-call specialization must be designed rather than discovered: whole-program
> optimisation defeating the splitter is the single most common entry in GWT's issue tracker.

**5. Add: ESM is what makes the full-stack decision necessary, not merely nice.** Closure ADVANCED has
never supported ESM as an emitter needs, and Terser's `--mangle` leaves ESM top-level names alone by
default — verified: `terser -m` and `terser -m toplevel=true` are byte-identical on Elm's IIFE.
**Elm's delegation works *because* of the IIFE; ours cannot.**

**6. Add: what chunking will not buy.** On the measured bundle **90% of bytes are runtime plus
library** and no chunker can split them. Chunking is a large-application feature.

**7. Add the counter-evidence, as an exit criterion.** Scala.js built the type-aware half and still
expects a downstream generic minifier; going without measured **1.58× brotli**. The reason that does
not sink the plan is that Scala.js never built the generic half at all. Make the risk measurable:
**M3 exits when beni's own brotli'd output is within ~10% of beni's output piped through esbuild
`--minify`.** If it approaches 1.58×, revisit before M5.

---

## 8. Top 10 highest-leverage techniques for beni

1. **Make compressed size the only target, measured at deployment settings.** Costs a benchmark
   column and a pinned `brotli` binary; prevents building transforms that lose (`booleans` under
   brotli) and prevents trusting a number that inverts the ranking and moves 18% under a pure
   reordering.
2. **Emit short, frequency-ranked names directly — never `$pkg$Module$name`.** Identifiers are 66.8%
   of unminified bytes, qualified globals 26.6%. Elm emits long names only because it delegates.
   *Cost: a whole-program name table, which §9.1 already builds.*
3. **Local dead-binding elimination over `JsIr` before printing.** 66% of the entire compress layer's
   brotli win, alone. *Cost: one use-count pass.*
4. **Whitespace/punctuation minimisation as one boolean on one printer.** ~19% of delivered bytes;
   esbuild does it in 35 branch points and measures it as *free* at runtime.
5. **Chunk by entry-set colouring over the declaration graph, hash-consing the colour from day one,
   then merge against a compression budget, and synthesise cross-chunk ESM bindings inside the pass.**
   dart2js's design at dart2js's granularity, with the representation that kept it fast, plus the
   binding synthesis whose absence is an open bug in the only system that does both. *Cost: ~1,200
   lines for the assigner, plus the cross-chunk symbol pass; the graph exists.*
6. **`lazy` on a declaration as the split trigger.** The only design with precedent that fits a pure
   effects-as-values language, and the asyncification cost is already paid. *Cost: one keyword, one
   type rewrite, one reachability diagnostic.*
7. **Type-directed field *ambiguation*, not just shortening.** Fields that never co-occur on a type
   share a short name, cutting the count of distinct identifiers — the quantity the compressor charges
   for. Requires exactly what M2 already built, and Elm cannot do it.
8. **`join_vars` and `?:` lowering in the printer.** #2 and #3 on the compress ranking, and both are
   emission decisions rather than optimiser passes. *Cost: ~zero.*
9. **Keep source maps fused into the printer and off by default.** Verified as the largest runtime
   cost in the backend (+61%), and the 172 call sites are the part that cannot be retrofitted.
10. **Emit declarations in module-grouped reachability order, and keep names stable across builds.**
    Worth up to 7% of gzipped bytes against a size-sorted order at identical raw size, and stable
    names are what makes chunking possible at all — the thing Elm's LCI-plus-renaming gave up.

## Open questions this report could not resolve

1. **What a `lazy` declaration means to the constant folder.** Dart's one restriction this report
   could not dismiss is that a deferred library's constants are not constants. beni must decide, and
   no precedent erases the problem.
2. **The chunk-count distribution a declaration-granular colouring actually produces.** §2.6 bounds
   the compression cost and §3.1 gives the algorithm, but **no source measures this**, and this report
   had no large beni program to measure. Given §2.6, a colouring that yields sixteen chunks where four
   would do costs ~11% of delivered bytes. **This is the biggest unquantified risk in the chunking
   plan.**
3. **No measured cost or benefit for Closure's `CrossChunkCodeMotion`/`CrossChunkMethodMotion`,
   dart2js's deferred-load task, or Scala.js's module splitter.** Not size savings, not compile time,
   not output-unit counts. The four systems that do what beni intends have published nothing about
   how well it works.
4. **No paper proves code splitting NP-hard, and none formulates it as an optimisation problem.** The
   only assertion in the ecosystem is a code comment deleted from GWT in 2.6.0. Doloto (2008) and
   Lazifier (2023) are the only measured systems, and both are profile- or heuristic-driven.
5. **What brotli's static dictionary contains.** RFC 7932 gives the 122,784-byte array but states
   neither the word count nor the corpus; "13,504 words from a web corpus" is secondary-source only.
   The single-occurrence probe found **no** dictionary advantage for `true` over `aaaa`, contradicting
   the usual telling — the repetition effect in §2.4 is real but its mechanism is unconfirmed.
6. **Any Google-published ADVANCED-vs-SIMPLE comparison on real code.** The documentation pages, both
   FAQs, the repo README, the Closure Tools blog archive and the releases changelog were all checked.
   The only official comparison is a 201-byte toy where the entire win is DCE. §0's Closure rows are
   this report's own measurement.
7. **"Property renaming wins even after gzip because it removes information"** is **false as usually
   stated**: Google documents that disambiguation *increases* gzipped size by creating more unique
   properties, and `AmbiguateProperties` exists to undo that. The pair is net positive; the mechanism
   is entropy reduction, not information removal.
8. **Whether beni's kernel/runtime JavaScript can be shrunk at all.** 45.5% of the measured bundle is
   hand-written runtime, outside every technique in this report. It is the largest single line in the
   byte attribution and this report has nothing to say about it.
