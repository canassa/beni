# Emitting JavaScript Extremely Fast

Sources: primary docs/source for esbuild, SWC, oxc, Bun, Rome/Biome, V8, and the
functional-to-JS compiler ecosystem (URLs inline); local reading of the Elm compiler at
`references/elm/compiler/src/` (file:line refs throughout).

> **Editor's note (unverified claim).** §2 originally asserted that Bun's ~535k-line Zig
> codebase was mechanically rewritten to ~1M lines of Rust in 2026 for memory-safety reasons.
> This session's web-search budget was exhausted before it could be confirmed, and it is not
> load-bearing for any recommendation here. Treat as unverified; it has been removed from the
> body below.

---

## 1. esbuild: the reference case for "fast codegen"

esbuild's own explanation lives almost entirely in one page —
[esbuild.github.io/faq/#why-is-esbuild-fast](https://esbuild.github.io/faq/#why-is-esbuild-fast) —
plus [`docs/architecture.md`](https://github.com/evanw/esbuild/blob/main/docs/architecture.md).
There is no separate deep-dive talk; those two documents *are* the primary source.

**Native code, not a JIT.** "It's written in Go and compiles to native code... a command-line
application is a worst-case performance situation for a JIT-compiled language" — every invocation
is cold, so a Node-hosted bundler pays parsing + warmup on its *own* source before starting on the
user's. esbuild's WASM build is itself "an order of magnitude (10x) slower" than native — a
self-consistent internal data point that most of the gap comes from native compilation.
*Nuance:* HN disputes the FAQ's "JS has a separate heap per thread" framing — `SharedArrayBuffer`
lets JS threads share memory ([HN 26154509](https://news.ycombinator.com/item?id=26154509)).

**Parallelism.** Design principle #1 in architecture.md: "Maximize parallelism." Parsing and
printing are embarrassingly parallel per file (goroutine per file); linking is the one inherently
serial phase. *Nuance:* Webpack's serial bottleneck is arguably its plugin/loader architecture, not
JS-the-language — Rspack and Turbopack posting large speedups over Webpack, and **Rolldown/Oxc
under Vite 8 posting a further 10–30× over esbuild+Rollup** (Linear 46s→6s), shows native+parallel
is the generalizable lesson, not that esbuild found a ceiling.

**Minimal-pass architecture.** esbuild touches the whole AST only **three times**: (1)
lex/parse/scope-setup, (2) bind/mangle/JSX-TS-lowering, (3) print + sourcemap. "This maximizes
reuse of AST data while it's still hot in the CPU cache." It never converts to an ESTree/Babel
tree — its private `js_ast` struct is lexed into and printed from directly, so there's no
string→AST→string round trip between stages. The doc *admits the cost*: merging scope-setup and
binding into two passes requires backtracking hacks (`popAndDiscardScope`, `popAndFlattenScope`)
for ambiguous arrow-function/TS-overload parsing.

**Custom-built everything, arrays over maps.** "Many bundlers use the official TypeScript compiler
as a parser... megamorphic object shapes and unnecessary dynamic property accesses." esbuild's
symbol table is a **flat array of symbols per file** (not a name→symbol map) referenced by 64-bit
index; cross-file linking merges these into an **array-of-arrays** addressed by
(file-index, inner-index) rather than a global map; AST source locations are a single integer byte
offset; cross-module identifier rebinding after linking uses a **union-find** structure (`Link`
fields + `FollowSymbols`) instead of rewriting the AST.

**Memory layout.** Go value types pack tightly (booleans take 1 byte, no hidden-class slot
overhead); Go embeds one struct in another with zero extra allocation, where JS objects are always
heap references; non-integer JS numbers are heap-boxed doubles where Go floats are unboxed.

**Zero-copy strings.** The lexer represents identifier text as
`MaybeSubstring{String string; Start ast.Index32}` — an index+length view into the original source
buffer, avoiding allocation in the common case. String *literals* are the deliberate exception:
transcoded to UTF-16 for surrogate-pair correctness, forcing a copy — a correctness/perf trade made
per token type. Escaped identifiers also fall back to a copy.

**Source maps fused into printing, not a 4th pass.** Every print call site invokes
`p.addSourceMapping(loc)` as it emits the corresponding bytes — no separate AST walk. Each per-file
printer builds a *relative* map "chunk" (as if the file started at offset 0); chunks are cheaply
rebased once at join time via `AppendSourceMapChunk` — a linear patch of only the first entry, not
a re-encode. Source maps are **off by default**.

**Output-buffer strategy.** Contrary to folklore, the per-file printer buffer (`p.js []byte`) is
*not* pre-sized from an estimate — it's a nil slice grown by Go's amortized-doubling `append`. What
*is* precisely sized is the final multi-piece join: `internal/helpers/joiner.go` records
`{data, offset}` pairs and a running length, then allocates **exactly once**
(`make([]byte, j.length)`) and blits each piece into place — "This is a measurable speedup," per the
doc comment. This gather-then-single-alloc pattern is the one to copy.

**Minify vs. pretty-print is one printer, not two.** Every whitespace/newline/indent decision is
gated behind a single `MinifyWhitespace` boolean inline — minification is the *same* traversal with
formatting branches short-circuited, not a separate code path.

**Watch mode is not what makes it fast.** esbuild's own docs: "watch mode is not faster than other
forms of incremental builds" — the speed comes from the *rebuild API* holding the previous build in
memory and skipping re-reads of files whose mtime hasn't changed. Its watcher **polls** (~2s worst
case) rather than using OS filesystem events, a documented pain point on large repos
([issue 1204](https://github.com/evanw/esbuild/issues/1204)).

**Benchmarks** ([esbuild's own](https://esbuild.github.io/faq/#benchmark-details)): three.js ×10
(547k lines), minify+sourcemap — esbuild 0.39s vs. Parcel 2 14.91s (38×), Rollup4+Terser 34.10s
(87×), Webpack 5 41.21s (106×); TypeScript bundle of the old Rome codebase (132k lines) — esbuild
0.10s vs. Parcel 6.91s (69×), Webpack 16.69s (167×), with esbuild's output *smaller* (0.97MB vs
1.27MB). An independent transform-only microbenchmark
([datastation](https://datastation.multiprocess.io/blog/2021-11-13-benchmarking-esbuild-swc-typescript-babel.html))
found a more modest **4–25×** over Babel and **3–9×** over tsc, with esbuild and SWC tracking each
other closely (3.066s vs 3.822s on the large sample) — a useful corrective, since the headline gap
is highly sensitive to whether type checking is included.

---

## 2. SWC, oxc, Bun, Rome/Biome — the Rust/Zig cohort

**SWC** ([swc.rs](https://swc.rs/)): visitor-based, multi-pass (Resolver → Hygiene → Fixer over the
whole AST), organized as separable crates. String interning via `JsWord = Atom<JsWordStaticSet>`
(Servo `tendril`/`string-cache` lineage) — dedups repeated identifiers with inline storage +
precomputed hashes. **No arena allocation** — ordinary heap allocation throughout, compensated by
interning/COW. Parallelism (`rayon`) is used at the bundling layer, not within single-file parsing.
Claims 20× over Babel single-threaded, 70× at 4 cores; Vercel's production numbers are more
credible: Next.js 11.1 saw Babel transforms drop ~500ms→~10ms and Terser minification ~250ms→~30ms
([nextjs.org/blog/next-11-1](https://nextjs.org/blog/next-11-1)). SWC's codegen generates source-map
entries as cheap `(BytePos, LineCol)` tuples pushed during printing, deferring the VLQ/base64 encode
to one batch pass at the end — "fuse mapping capture into printing, defer the encode."

**oxc** ([oxc.rs](https://oxc.rs/)): the arena-allocation reference case. `oxc_allocator` wraps
`bumpalo`; the team attributes **~20%** to bump allocation, plus a locality bonus since traversal
order matches allocation order. Enum-variant boxing cut node size 200+→16 bytes (~10%); `Span`
fields `usize→u32` gave up to 5% on large files; `CompactStr` (24-byte SSO) avoids allocation for
most identifiers. Two-phase design: a hand-written recursive-descent parser builds the AST with
minimal semantics, then a **single shared** semantic-analysis pass feeds every downstream consumer
(linter, transformer, minifier) — avoiding the N-separate-traversals cost of visitor-per-transform.
SIMD is used narrowly (whitespace/comment scanning) for "several percent" — smaller than the
allocation and layout wins.

A striking negative finding: oxc originally used a global string interner and found the interning
*mutex* collapsed parallel parsing to ~50% core utilization; **removing** interning gained ~30%
parallel throughput — the opposite lesson from SWC's design, showing global-lock interning becomes a
serial bottleneck once you parallelize across files
([rustmagazine.org](https://rustmagazine.org/issue-3/javascript-compiler/)). Parser benchmark: oxc
parses `cal.com.tsx` in 4.0ms vs. SWC 14.0ms (3.5×) vs. Biome 18.7ms (4.68×) on an M2 Mac mini;
arena teardown costs oxc ~0.3ms vs. ~7ms for SWC's heap AST — direct evidence that arenas make
*deallocation* nearly free too.

**Bun**: its transpiler/bundler/printer is an explicitly documented **line-for-line port of esbuild**
("Bun's JS transpiler... is a port of @evanw's esbuild project," `LICENSE.md`), in Zig. Bundler
benchmark (derived from esbuild's three.js test): Bun **1.75× faster than esbuild**, 150–220× faster
than Parcel/Rollup+Terser/Webpack — the 1.75× is the real signal; the rest measures native-vs-JS.
Bun embeds **JavaScriptCore**, not V8.

**Rome → Biome**: Rome (2020) aimed to unify Babel/ESLint/Webpack/Prettier/Jest into one Rust
toolchain; governance collapsed and it forked to **Biome** in 2023. Biome's parser is built on
`biome_rowan`, a fork of rust-analyzer's **rowan** — a Green/Red lossless CST: the Green tree is
immutable and structurally shared, storing only a `SyntaxKind` + text width per node, with trivia
attached to tokens as leading/trailing spans, enabling exact source reproduction for
formatting/autofix. This is the one **rope-adjacent** design across all four projects; it's a
formatter/lossless-reproduction concern, not a general codegen one — plain emitters (oxc, esbuild,
SWC) all use flat buffers. Biome's formatter separates CST→IR (`FormatElement` "Document" nodes,
Prettier-style)→printer. Claims ~25–35× faster than Prettier (up to 100× on more cores) and ~15×
faster than ESLint (~4× single-threaded); a persistent daemon amortizes parse/analysis cost across
CLI + editor invocations.

**Cross-cutting lesson:** arena allocation (oxc) and global interning (SWC) target *different*
overheads and can conflict once parallelism enters — a global interner lock serializes exactly the
workload you're trying to parallelize. SIMD is the most over-credited technique in the public
narrative; measured impact (a few percent) is dwarfed by memory-layout and allocation choices
(10–20%).

---

## 3. Codegen output strategy: buffer, rope, or nothing at all

**Naive string concatenation is O(n²)** under immutable-string semantics. Two standard fixes:
(a) **rope** — a tree of concatenated pieces, O(1) append, deferred flattening — for output that
must be edited/patched non-linearly (editors, Biome's Green tree); (b) **measure-once-allocate-once**
— accumulate `{data, offset}` references and lengths, sum, allocate the exact final buffer once,
blit. esbuild's `Joiner` and SWC's deferred batch VLQ encode are both instances, and this is the
right default for a compiler backend producing output in one linear pass.

**Direct-to-buffer vs. a separate JS-shaped print IR — Elm is primary-source evidence on this exact
trade-off.** `Generate/JavaScript/Builder.hs:29-40` contains this verbatim:

> "I tried making this create a B.Builder directly. The hope was that it'd allocate less and speed
> things up, but it seemed to be neutral for perf. The downside is that
> Generate.JavaScript.Expression inspects the structure of Expr and Stmt on some occasions to try to
> strip out unnecessary closures... For this to be worth it, I think it would be necessary to avoid
> returning tuples when generating expressions."

A real compiler author **tried collapsing the JS IR and print pass into one direct-to-bytes step,
measured no win, and kept the small intermediate `JS.Expr`/`JS.Stmt` IR** — precisely because codegen
needs to pattern-match on already-generated structure to do peephole cleanup. The concrete case:
`Expression.hs:185-220` (`codeToExpr`/`codeToStmtList`/`codeToStmt`) matches on
`JsBlock [JS.Return expr]` vs. arbitrary statement lists, and specifically on
`JsExpr (JS.Call (JS.Function Nothing [] stmts) [])` — an immediately-invoked no-arg function
wrapping a block — to unwrap it rather than emit a needless IIFE.

The realistic architecture for a new compiler: **lower your typed IR into a small, JS-shaped print
IR as part of existing lowering passes (don't add a dedicated extra traversal), then run one
dedicated print pass straight to a growable byte buffer** — borrowing esbuild's "no ESTree
round-trip" discipline for the *final* step, while accepting that your source IR and printable IR
are different (unlike esbuild, where the printed AST *is* the semantic AST).

**Printing itself, in Elm:** `stmtToBuilder`/`exprToBuilder` (`Builder.hs:130-136`) target
`Data.ByteString.Builder` — a monoidal, difference-list-style builder where `<>` is O(1) regardless
of operand size and the whole append tree is flattened once at the end. Functionally the same idea
as esbuild's `Joiner`. Indentation is precomputed and shared: `levelZero`/`makeLevel`
(`Builder.hs:143-155`) construct an infinite lazily-evaluated chain of `Level Builder Level` where
each level's tab-`Builder` is memoized — nesting deeper reuses rather than regenerates indentation.

**Minify vs. pretty-print — a different split from esbuild's.** Elm threads a `Grouping`/`Lines`
classification (`data Lines = One | Many`) through every expression for multi-line formatting, but
has **no separate minifying printer** — it relies on a downstream minifier for whitespace/identifier
minification (§6). A legitimate alternative division of labor: **let your printer only pretty-print
and hand minification to a dedicated tool** — viable specifically because Elm already does its own
frequency-based field/name shortening upstream.

---

## 4. Source maps: cost and how to make them cheap

**Where the cost comes from:** per-token bookkeeping (tracking generated *and* original position
through the print traversal), building a second artifact, and the VLQ/base64 encode. Evan Wallace:
source maps are "one of the slowest things about doing a production build" and can be "~3× larger
than your minified JavaScript" — hence off by default
([esbuild#833](https://github.com/evanw/esbuild/issues/833)).

**Fuse generation into the print pass — the single most important decision.** esbuild calls
`p.addSourceMapping(loc)` at each print call site, inline with emitting text; no separate AST walk.
SWC instead **defers the expensive part**: printing pushes cheap `(BytePos, LineCol)` tuples into a
`Vec` (deduped via a `HashSet`), and the VLQ/base64 math runs once in bulk afterward. Both avoid a
second traversal; they differ only in interleaved (esbuild) vs. batched (SWC) encoding — batching is
friendlier to instruction cache and branch prediction.

**Delta-encode everything.** esbuild's `appendMappingToBuffer` VLQ-encodes *differences* from the
previous mapping's generated column, source index, original line, original column, and name index.
VLQ size is proportional to magnitude, so small deltas are compact by construction. VLQ uses base64
because 6 bits maps 1:1 onto one printable character, so the string is usable directly inside JSON.

**Encoding trick:** esbuild's `encodeVLQ` uses a fixed 64-byte lookup table (avoiding
division/modulo) plus a fast path that skips the loop when a value fits in a single sextet.

**Segment/gap tricks, from esbuild source:**

- **Duplicate-mapping suppression** — no-op if the current position equals the previous mapping.
- **Line-gap coverage** — `coverLinesWithoutMappings`: a generated line with no mapping reuses the
  previous mapping's original position rather than leaving a gap.
- **ASCII fast path** — skips building a UTF-16-column conversion table for ASCII-only source lines.
- **Shift-patching without re-encoding** — when renaming shifts a generated column, esbuild patches
  only mappings crossing the shift boundary and copies untouched VLQ byte runs verbatim.
- **Parallel-then-rebase** — each file's map is generated as if it started at offset 0, then a cheap
  linear rebase joins them.

**"Lazy" source maps in practice** = Webpack's `devtool` spectrum: `eval-cheap-source-map` skips
column mapping and merges maps *per module* (embedded in each module's own `eval()`) instead of
bundle-wide, avoiding the expensive bundle-wide merge on every rebuild — dev-only.

**Elm opts out of the problem entirely.** Grepping `Generate/` found **no source-map generation at
all** — the builders produce plain text with no position tracking. Elm's story for "debug the
compiled output" is a separate Dev mode with human-readable variable/field names and console
warnings (`Generate/JavaScript.hs:60-74`), not source-mapped stepping. **The cheapest source map is
the one you never generate** — worth deciding explicitly whether your debugging story needs them.

---

## 5. Whole-program optimizations for an ML-style language

### 5.1 Dead-code elimination at declaration granularity — Elm's exact mechanism

A **mark-and-sweep over a whole-program dependency graph of top-level declarations**, not a
bundler-style module/statement heuristic.

**The graph is built during optimization, not codegen.** Every top-level definition is lowered from
`Can.Expr` to `Opt.Expr` (`AST/Optimized.hs:46-73`) via `Optimize.Expression.optimize`, running
inside a CPS-encoded `Names.Tracker` monad (`Optimize/Names.hs:33-41`) that threads three pieces of
state through the traversal: a fresh-name counter, a `Set.Set Opt.Global` of every global the
expression *references*, and a `Map Name Int` of record-field usage counts. Each reference-producing
case — `registerGlobal` (`:62-67`), `registerKernel` (`:56-59`), `registerCtor` (`:76-95`),
`registerDebug` — inserts into that set as a side effect of generating the node. **The
free-variable/dependency set for DCE falls out of ordinary compilation for free** — no separate
analysis pass.

**Each top-level binding becomes a graph node.** `Optimize.Module.addDefNode`
(`Optimize/Module.hs:274-289`) packages a definition as `Opt.Define expr (Set.union deps mainDeps)`
— an `Opt.Node` keyed by `Opt.Global home name` (`AST/Optimized.hs:150-161`: `Define`,
`DefineTailFunc`, `Ctor`, `Enum`, `Box`, `Link`, `Cycle`, `Manager`, `Kernel`,
`PortIncoming/Outgoing` — one variant per kind of top-level thing, each carrying its own dependency
set). All modules' nodes merge into one flat `GlobalGraph` (`Map Global Node`,
`AST/Optimized.hs:127-131`) — **the whole program's declarations live in a single cross-module map
before code generation starts.**

**Codegen is reachability from `main`, nothing else.** `Generate.JavaScript.generate`
(`JavaScript.hs:42-52`) starts from `addMain` per entry point and calls `addGlobal` (`:176-182`),
which checks a visited set (`_seenGlobals`) and recursively visits every dependency
(`addGlobalHelp`, `:185-223`). **Nothing is generated unless transitively reachable from an entry
point** — standard mark-and-sweep, but at single-top-level-declaration granularity, across the whole
linked program including kernel/JS-interop code (`Opt.Kernel chunks deps`, `:219-223`) and effect
managers. Kernel JS chunks even get *conditional* dead-branch elimination: `K.Debug`/`K.Prod` chunk
markers resolve per output mode (`:369-384`, emitting `"_UNUSED"` to intentionally break references
to code the current mode shouldn't keep), so DCE reaches inside hand-written interop shims.

**Transferability:** the highest-leverage, most directly portable technique in this report. Make
every top-level binding a node with an explicit, cheaply-computed dependency set (free globals are
already known from name resolution — don't add a pass), keyed module-qualified, and generate purely
by reachability from entry points. This gives tree-shaking finer than any JS bundler achieves on
hand-written JS (which must infer side-effect-freedom heuristically via `sideEffects: false` /
`/*#__PURE__*/`); **your compiler *knows* purity because the source language enforces it.**

### 5.2 Uncurrying / arity raising — the A2/F2 scheme, and why it exists

**The problem, formally.** Leroy et al.
([verified uncurrying](https://xavierleroy.org/publi/higher-order-uncurrying.pdf)): "a total
application of a n-ary curried function entails the creation of n − 1 short-lived intermediate
closures, as well as 2n control-flow jumps," where a native n-ary convention needs only 2.
Justifying the payoff: "Marlow and Peyton Jones report that [saturated calls] amount for 80% of
function calls" in a Haskell benchmark suite, with similar OCaml numbers — **~80% of calls in
typical ML-family code are fully applied.**

**Elm's runtime encoding** (`Generate/JavaScript/Functions.hs:17-94`, emitted into every program):

```js
function F2(fun) {
  return F(2, fun, function(a) { return function(b) { return fun(a,b); }; })
}
function A2(fun, a, b) {
  return fun.a === 2 ? fun.f(a, b) : fun(a)(b);
}
```

`F(arity, fun, wrapper)` stamps `wrapper.a = arity` and `wrapper.f = fun`, so the wrapper *is* the
callable value seen everywhere (needed because Elm functions are first-class and can be partially
applied or stored in data structures), while `A2` checks `fun.a === 2` at each call site and — if
true — calls straight into the real 2-ary function with no intermediate closures. Only
partially-applied or otherwise higher-order arrivals pay the closure cost (the rarer ~20%).

**The compile-time half.** `generateNormalCall` (`Expression.hs:378-386`) looks up the call's
argument count in a static `IntMap` of `A2..A9` helper refs (`callHelpers`, `:388-392`) and emits
`A2(fun, a, b)` directly when it matches; outside the range it falls back to `fun(a)(b)` chains.
Definitions use the mirror-image `generateFunction` (`:319-336`), wrapping the raw JS function in
`F2(...)`. Crucially, **this decision is entirely local/syntactic** — Elm does no interprocedural
arity inference; every call site knows its own argument count from the AST. This is first-order
uncurrying in Leroy's taxonomy; Elm does not attempt the harder higher-order case, always leaving
the runtime check as a fallback.

**Where others landed, and the measured cost of not doing this:**

- **ReScript** ships an explicit "uncurried mode" because best-effort static analysis "could not
  fully statically analyze when to automatically uncurry... across multiple files," leaving runtime
  `Curry._1(...)` dispatch on the slow path.
- **PureScript's stock backend does *not* do this** — it emits real nested single-argument closures
  for every curried function, even fully saturated ones
  ([purescript#1686](https://github.com/purescript/purescript/issues/1686)); an uncurrying proposal
  citing "Fay and Elm had already implemented similar optimizations" was closed as a duplicate
  ([#479](https://github.com/purescript/purescript/issues/479)). The gap was closed years later by a
  *separate* optimizing backend, `purescript-backend-optimizer`, doing directive-driven
  cross-function arity propagation, reporting **25–35% runtime improvement, 20–25% smaller minified
  bundles** — concrete quantification of what naive currying costs.
- **Gleam sidesteps it in language design**: partial application is a compile error unless requested
  via capture syntax or `curry2..curry6` helpers — the cheapest possible fix, since the JS backend
  then needs no adapter scheme at all.
- **V8-side validation**: `elm-optimize-level-2` targets Elm's own `A2`/`F2` calls for a "direct
  function call" rewrite (skip the wrapper, call `.f` straight), citing large speed effects — even
  Elm's scheme leaves gains on the table versus fully static specialization.

### 5.3 Record/variant representation and V8 hidden classes

**Elm's representation.** Records compile to plain object literals (`generateRecord`,
`Expression.hs:262-268`, `JS.Object (map toPair (Map.toList fields))` — `Map.toList` gives a
canonical, sorted key order every time a given record type is constructed, exactly the consistency
V8's hidden-class system rewards). Field names are shortened *by the compiler* in Prod mode via
whole-program frequency ranking: `Generate.Mode.shortenFieldNames` (`Mode.hs:44-62`) walks the
field-usage counts collected during optimization (the same `Names.Tracker` counters from §5.1),
buckets by frequency, and assigns the shortest ASCII names (via `JsName.fromInt`, a base-54/64
counter, `Name.hs:160-224`) to the *most frequently used* fields first — a global, cross-module
decision a generic minifier could never make.

Data constructors compile to functions returning a tagged object `{$: tag, a, b, ...}`
(`generateCtor`, `Expression.hs:236-248`): the tag is a readable string in Dev and a small integer
in Prod (`ctorToInt`, `:251-256`), with fixed positional field names in argument order — a
consistent shape per constructor.

**Validated by V8's literature, with a documented counter-example in Elm's own output.** V8's hidden
classes ([Fast properties in V8](https://v8.dev/blog/fast-properties)) share one HiddenClass across
objects with "the same named properties in the same order"; repeated shapes at one site keep an
inline cache **monomorphic** — the only state the optimizing compiler can inline through
([Egorov, *What's up with monomorphism?*](https://mrale.ph/blog/2015/01/11/whats-up-with-monomorphism.html)).
Elm's `$`-tag + fixed-key-order literals are what this recommends. But Hansen's analysis
([dev.to](https://dev.to/robinheghan/improving-elm-s-compiler-output-5e1h)) found Elm's `List`
violates it: `_List_Nil = {$: 0}` and `_List_Cons = function(hd,tl){return {$:1, a:hd, b:tl}}` have
**different shapes**, so any list traversal is polymorphic across every Nil/Cons boundary. Padding
`Nil` with `null` fields to match measured **~11% Firefox, ~4% Chrome, 0% Safari** on `foldl`. A
second finding, validating §5.2: rewriting `A2(fun,a,b)` to direct `fun.f(a,b)` measured **+109%
Firefox, +49% Chrome, +37% Safari** on `map`.

**PureScript picked the opposite encoding for the same reason** (a class per constructor with
`value0`/`value1` fields — chosen, per maintainer `garyb`, specifically because "that's what led us
to the hidden-class based data constructor representation"), and when a plain-array encoding was
benchmarked, results were workload-dependent. **Shape consistency matters unconditionally; the
specific choice of tagged-object vs. class-instance vs. array is workload-dependent and should be
benchmarked.** Gleam converged from another angle: it recently **monomorphized record-update
codegen** — a bespoke specialized update function per call site instead of one generic runtime
helper — explicitly to avoid a shared megamorphic dispatch point.

**Elements-kinds corollary.** V8 tracks array "elements kind" (packed-smi → packed-double →
packed-generic, each with a holey variant) as a *strictly monotonic, irreversible* lattice — one
hole or one float permanently downgrades an all-integer array
([Elements kinds in V8](https://v8.dev/blog/elements-kinds)). If tuples or fixed-size records are
ever represented as JS arrays, construct them **fully populated, contiguously, in one literal**.

### 5.4 Pattern matching → decision trees, not naive if-chains

Elm uses the **Scott & Ramsey ("When Do Match-Compilation Heuristics Matter?")** algorithm, same
family as SML/NJ (`Optimize/DecisionTree.hs:1-20` cites the paper). `pickPath` (`:528-539`) chooses
which pattern position to test next by minimizing "small defaults" first, then branching factor —
producing as few runtime tests as possible.

The tree becomes a `Decider` (`Optimize/Case.hs:53-86`) that **shares code between branches reached
from multiple leaves and inlines everything else**: `countTargets` (`:114-124`) counts leaves per
source branch; `createChoices` (`:126-138`) marks a branch `Inline` if reached from exactly one leaf,
or `Jump` only if reached from ≥2 — since JS has no `goto`, shared branches become
`label: while(true){...}` constructs that others `break`/`continue` into (`Expression.hs:730-770`).
Multi-way tests on one scrutinee compile to a real JS `switch` (`Opt.FanOut` → `JS.Switch`,
`:762-770`) — **one V8 jump-table dispatch instead of a chain of `===`**. Also relevant to §5.3:
`generateCaseTest` reads the tag via `.$` only for `Normal` constructors, skipping the check for
`Enum` (bare int/bool) and `Unbox` (single-field wrapper elided at runtime) kinds (`:844-861`).

### 5.5 Tail-call elimination into loops

**JS gives you no reliable TCO.** ES2015 mandated proper tail calls; only Safari/JavaScriptCore
shipped them, V8 shipped-then-reverted behind a flag, SpiderMonkey never shipped
([tc39/ecma262#535](https://github.com/tc39/ecma262/issues/535)). **A compiler targeting JS must
implement stack safety itself.**

Elm: `optimizePotentialTailCall` (`Optimize/Expression.hs:355-405`) detects genuine self-tail-position
calls and lowers them to `Opt.TailCall`; `addDefNode` routes such definitions to `Opt.DefineTailFunc`.
Codegen (`generateTailDef`, `Expression.hs:636-643`) wraps the body in
`JS.Labelled name $ JS.While (JS.Bool True) $ ...`; each tail call site (`generateTailCall`,
`:607-619`) reassigns the loop's parameter variables — via **temporaries first, then real
assignment**, to handle simultaneous rebinding without aliasing (the same reason SSA φ-nodes exist)
— then emits `JS.Continue (Just label)`. So `f n acc = if n<=1 then acc else f (n-1) (acc*n)` becomes
a genuine `while(true)` loop with zero call overhead and zero stack growth, generated structurally
from the IR, not as a peephole over printed text. **Documented limitation: only direct
self-recursion; mutual recursion still allocates a stack frame per call.** ClojureScript instead
makes the loop point a first-class construct (`loop`/`recur`); Scala.js's `@tailrec` is a
frontend-verified annotation enforced before codegen.

### 5.6 List/array representation trade-offs

Elm's `List` is a genuine singly-linked cons structure — trivial to pattern-match, free structural
sharing of any suffix, but O(n) random access, poor cache locality (each cell separately heap
allocated and pointer-linked — the opposite of the packed-array locality V8 rewards, §5.3), and a
real stack-overflow risk on deep right folds serious enough that `List.foldr` contains a depth
counter that switches strategy (to `foldl`+`reverse`) past 500 frames. Clojure/ClojureScript and
Immutable.js instead use **32-way branching persistent vector tries** (HAMT lineage), giving
O(log₃₂ n) — effectively constant at realistic sizes — for both random access and structural-sharing
update. **For a new compiler:** cons lists are the simplest correct choice and match how ML pattern
matching naturally works, but if idiomatic code does much indexed access or very deep recursion, a
vector-trie representation avoids both failure modes at significant implementation cost — benchmark
against your language's actual usage rather than defaulting to "linked list because ML."

### 5.7 Basics-call peephole specialization

`generateBasicsCall` (`Expression.hs:414-459`) recognizes calls to known `Basics`/`Bitwise`/`Tuple`/
`JsArray` core functions by module+name at codegen time and emits **native JS operators directly**
(`+`, `-`, `<<`) instead of a generic call — `Basics.add a b` becomes `a + b`, not `A2(add, a, b)`.
Structural equality/comparison get a similar fast path: `equal`/`notEqual`/`cmp` (`:463-489`) check
`isLiteral` on either operand and emit plain `===`/`<`/`>` instead of routing through the generic
deep-equality kernel helper `_Utils_eq`/`_Utils_cmp` — avoiding exactly the
single-call-site-sees-every-shape megamorphism Egorov warns about.

Note this happens **at codegen time, over already-generalized `Opt.Call` nodes** — Elm's optimizer
deliberately does *not* special-case binops (`Optimize/Expression.hs:75-79`: `Can.Binop` always
becomes `Opt.Call`). A clean separation worth copying: **the semantic optimizer stays generic
(uniform `Call` nodes); the JS backend does cheap, purely syntactic peephole recognition of known
core operations right before printing**, without the optimizer needing to know JS operator
precedence at all.

---

## 6. Output that's fast for the browser as well as fast to produce

**ESM vs. IIFE.** Elm emits a single **IIFE**: `"(function(scope){\n'use strict';" <> ... <>
"}(this));"` (`Generate/JavaScript.hs:47-52`) — universally compatible, but no downstream tool can
statically see the internal module graph (everything is already resolved and inlined by DCE before
emission, so there's nothing *to* import/export). The generalizable lesson is stronger than "IIFE is
fine": **emit ESM**, because HMR tooling depends on statically walkable `import`/`export` graphs to
compute which modules a change affects and to swap a module's body against a running registry
(`import.meta.hot.accept()`); an IIFE forces a full reload on any change
([bjornlu.com on HMR](https://bjornlu.com/blog/hot-module-replacement-is-easy)). Even with
whole-program DCE inlining everything, emitting the final artifact as ESM keeps it analyzable to
dev servers and bundlers.

**Downstream-bundler compatibility.** Elm's `toMainExports`/`generateExports`
(`JavaScript.hs:503-538`) builds a nested object (`Trie`, keyed by dotted module-name segments)
exposing each program's `init` under `scope['Elm']['MyApp']['init']` — the interop surface is a plain
object namespace, deliberately simple. General principle: whatever the internal representation, the
**public interop boundary** should be the most conservative widely-supported shape.

**Minify yourself vs. hand off.** Elm does its own whole-program-aware minification for what only it
can know cheaply — record field names ranked by real cross-module usage frequency (§5.3) — then hands
generic JS minification to Terser/UglifyJS via a documented two-pass invocation
(`hints/optimize.md`):

```
uglifyjs elm.js --compress "pure_funcs=[F2..F9,A2..A9],pure_getters,keep_fargs=false,unsafe_comps,unsafe" | uglifyjs --mangle
```

The `pure_funcs` annotation is the crux: it tells Terser it may freely DCE or reorder calls to
`F2..F9`/`A2..A9` because **Elm's purity guarantee makes this always safe** — information a generic
minifier could never infer from JS source, handed over for free as a build flag. TodoMVC: 122,297
bytes compiled → **24,123 minified → 9,148 gzipped**. **The split to copy:** the compiler does
whole-program-aware shrinking it uniquely can do (field/name frequency ranking, purity-driven
`pure_funcs`); a generic minifier does everything else. Don't reimplement Terser's peephole passes.

> **Superseded.** Beni no longer does this split: it ships no bundler and no minifier, so the
> "everything else" above is ours to build. Report 12 has the evidence and the ranked list, and
> §9.5 of the design doc is rewritten accordingly. Two specifics from this paragraph are now
> wrong for us rather than merely inapplicable: Terser's `--mangle` leaves ESM top-level names
> alone, so the handoff depends on Elm's IIFE and cannot survive our ESM decision; and the
> peephole passes worth reimplementing are a much shorter list than Terser's, because most of them
> measure approximately zero after compression and two of them are negative.

**Pre-minified names.** Elm's base-54/64 ASCII counter (`Name.hs:160-225`) is used for exactly two
things: record-field short names (Prod) and numbered temp names — *not* as a substitute for Terser's
mangle pass on locals. Reserve compiler-generated short names for identifiers whose frequency ranking
requires whole-program knowledge; leave function-local mangling to a tool built for it.

**Code splitting is conspicuously absent** from Elm's architecture — the whole reachable graph is
emitted as one file per `generate` call, with no chunking concept. A real gap: a new compiler
targeting large applications should design splitting into the entry-point/dependency-graph model from
the start (the §5.1 graph already has everything needed — per-entry-point reachability sets could be
intersected/subtracted to find shared vs. entry-specific chunks), since retrofitting chunk boundaries
onto "one file, whole-graph reachability" is exactly the kind of decision that's hard to change.

---

## 7. Watch mode / dev-loop speed

**Elm's actual weak point is instructive by contrast.** Despite declaration-granular *codegen*
(§5.1), Elm's *type checking/compilation* is **module-granular**: real-world reports cite full
rebuilds around 2 minutes and incremental rebuilds of 5–45 seconds on large interlinked codebases,
with the explicit failure mode that "heavily interlinked modules... changing one file causes all
dependent files to be recompiled"
([Elm compiler internals](https://discourse.elm-lang.org/t/improving-compilation-time-insights-from-elm-compiler-internals/9028)).
**Declaration-level output granularity does not automatically give declaration-level *compilation*
granularity** — two separate engineering problems, and Elm solved only the first well.

**State of the art:**

- **esbuild's rebuild API**: keep the previous build in memory; skip re-reading files whose mtime is
  unchanged. Its watcher **polls** rather than using OS events — worth avoiding by using native
  `inotify`/`FSEvents` from day one.
- **Vite**: doesn't bundle your source in dev at all — serves native ESM, transforming per
  file/request; only `node_modules` deps are pre-bundled, cached under `node_modules/.vite` keyed by
  lockfile hash + config hash, with each chunk served under a content-hashed URL so a version bump
  invalidates just that chunk.
- **Turbopack**: bundles even in dev (avoiding Vite's "excessive network requests at scale") but
  makes the incremental unit *function-level*, via a Salsa/Adapton/rustc-query-inspired "value cell"
  model (`Vc<T>`): each function call records its actual read-dependencies *dynamically*, so
  "changing one field of a large object only dirties functions that actually read that field."
  Recomputation is demand-driven; the graph persists to disk across dev-server restarts.
- **Webpack's filesystem cache**: coarser — modules/chunks cached under `node_modules/.cache/webpack`,
  invalidated by a `buildDependencies` list plus a manually bumped `cache.version`.

**Content-hash-keyed caching, generalized.** Every fast path above is "key the cached output by a
hash of its actual inputs, check the hash before redoing work." For a new compiler the natural
granularity is **the same top-level-declaration node used for DCE (§5.1)**: hash a declaration's own
source text plus the identities (not full content) of its dependencies, and skip re-checking/
re-emitting a node whose hash and dependency hashes are unchanged — reusing the graph DCE already
needs rather than building a second incremental system.

---

## 8. Consolidated benchmark numbers

| Comparison | Numbers | Source |
|---|---|---|
| esbuild vs. Webpack 5 / Rollup 4+Terser / Parcel 2 (547k lines, minify+sourcemap) | 0.39s vs 41.21s (106×) / 34.10s (87×) / 14.91s (38×) | [esbuild FAQ](https://esbuild.github.io/faq/#benchmark-details) |
| esbuild vs. same (TS, Rome codebase, 132k lines) | 0.10s vs Webpack 16.69s (167×), Parcel 6.91s (69×); output smaller (0.97MB vs 1.27MB) | same |
| esbuild vs SWC vs tsc vs Babel (transform-only, independent) | 3.066s / 3.822s / 37.286s / 70.576s → 4–25× over Babel, 3–9× over tsc | [datastation](https://datastation.multiprocess.io/blog/2021-11-13-benchmarking-esbuild-swc-typescript-babel.html) |
| SWC vs Babel | 20× (1 core), 70× (4 cores) claimed; Vercel prod: Babel 500ms→10ms, Terser 250ms→30ms | [swc.rs](https://swc.rs/blog/perf-swc-vs-babel), [Next.js 11.1](https://nextjs.org/blog/next-11-1) |
| oxc vs SWC vs Biome (cal.com.tsx, M2 mini) | 4.0ms vs 14.0ms (3.5×) vs 18.7ms (4.68×); memory 68.8 / 92.0 / 117.4 MB | [oxc bench](https://github.com/oxc-project/bench-javascript-parser-written-in-rust) |
| oxc arena teardown vs SWC heap-AST teardown | ~0.3ms vs ~7ms, same file | same |
| oxc allocator/layout wins | arena ~20%, enum boxing ~10%, `Span` u32 ~5%, interner removal +30% parallel throughput | [oxc.rs](https://oxc.rs/docs/learn/performance) |
| oxc minifier vs SWC / esbuild / Terser (TS 4.9.5) | 444ms vs 2,179ms vs 492ms vs 6,433ms | [oxc minifier blog](https://oxc.rs/blog/2025-03-13-minifier-alpha) |
| Bun bundler vs esbuild / Parcel / Rollup+Terser / Webpack | 1.75× faster than esbuild; 150× / 180× / 220× vs the JS tools | [bun.com/blog/bun-bundler](https://bun.com/blog/bun-bundler) |
| Biome vs Prettier / ESLint | ~25–35× (M1), up to 100× (10 cores); ~15× vs ESLint | [biomejs.dev](https://biomejs.dev/) |
| Elm shape unification (`Nil`/`Cons` padding) | +11% Firefox, +4% Chrome, 0% Safari (`foldl`) | [Hansen](https://dev.to/robinheghan/improving-elm-s-compiler-output-5e1h) |
| Elm direct-call rewrite (`A2`→`.f`) | +109% Firefox, +49% Chrome, +37% Safari (`map`) | same |
| PureScript backend-optimizer (arity raising) | 25–35% runtime, 20–25% smaller minified bundle | [README](https://github.com/aristanetworks/purescript-backend-optimizer) |
| Elm TodoMVC asset size (`--optimize` + Terser) | 122,297B → 24,123B minified → 9,148B gzipped | Elm guide, *Asset Size* (**not** `hints/optimize.md` — corrected in report 12 §7.3, verified against `references/elm`) |
| Elm real-world compile times | 2.6s local / 234s CI; 2min full, 5–45s incremental elsewhere | [#1473](https://github.com/elm/compiler/issues/1473) |
| Vite 8 Rolldown/Oxc vs esbuild+Rollup | further 10–30× (Linear 46s→6s) | [Vite 8 coverage](https://dev.to/stacknotice/vite-8-complete-guide-rolldown-oxc-and-10x-faster-builds-2026-48lh) |

---

## Top 10 highest-leverage techniques, ranked

1. **Whole-program declaration-level DCE via a global dependency graph + reachability from entry
   points** (§5.1). Both a size win and something no downstream JS tool can replicate as precisely
   (they must infer purity; you prove it). Cheap: the dependency set is a byproduct of name
   resolution.
2. **Fuse parse/lower/print into the fewest full-tree passes, direct to a growable byte buffer**
   (esbuild's 3-pass discipline + `Joiner`-style single-allocation join).
3. **Uncurry/specialize known-arity call sites at codegen time** (A2/F2, or better, Gleam's
   language-level non-currying). ~80% of calls are saturated; PureScript's 25–35% cost of *not*
   doing it is hard evidence.
4. **Consistent, fixed-shape object construction for every ADT constructor and record type** —
   validated by V8's hidden-class literature and Elm's measured 4–11% from unifying Nil/Cons shapes.
5. **Arena/bump allocation for the compiler's own AST/IR** (oxc's ~20% + near-free teardown).
6. **Tail-call self-recursion → `while(true)` loop lowering at the IR level** — mandatory, not
   optional; no JS engine reliably provides TCO.
7. **Fuse source-map capture into the print pass; make full source maps opt-in/lazy.**
8. **Decision-tree pattern-match compilation → native `switch`, single-use branches inlined,
   multi-use branches shared via labeled loops.**
9. **Peephole-recognize core/primitive operations at codegen time and emit native JS operators** —
   keeps the optimizer generic while avoiding megamorphic dispatch on arithmetic and equality.
10. **Design ESM output + a content-hash-keyed incremental cache over the same declaration-graph
    nodes used for DCE, from day one** — not the biggest single win, but retrofitting incremental
    compilation and HMR-shaped output later is the expensive class of change.

## Codegen decisions that are hard to change later

- **Top-level declaration as the unit of the dependency graph.** Dependency tracking, DCE and
  incremental compilation should all key off one graph; its granularity shapes how free-variable
  collection, caching and reachability thread through everything downstream.
- **Whether the JS IR is the same structure your typed IR lowers into, or a separate small
  "printable" IR.** Elm's author tested collapsing this and reverted (`Builder.hs:29-40`). Choosing
  "print directly from the typed IR, no JS-shaped IR" up front (esbuild's model — viable because its
  input and output are both JS) forecloses cheap peephole restructuring later when the source
  language is structurally far from JS. **Pick the two-IR design from the start.**
- **Data-constructor/record representation** (tagged object vs. class vs. array) and **discriminant
  encoding** (string vs. integer vs. class identity) — baked into every piece of generated code,
  every kernel/FFI shim and every consumer of output. Benchmark early.
- **Curried-by-default vs. non-curried calling convention** — a source-language semantics decision
  that fully determines whether an A2/F2 adapter scheme is needed at all.
- **One whole-program bundle vs. chunk/entry-point boundaries from the start.**
- **Module output format (IIFE vs. ESM)** — determines whether any downstream tool can statically
  analyze output structure; switching later breaks every consumer.
- **Whether source-position tracking exists in the IR from the start** — retrofitting source maps onto
  a pipeline that never threaded positions means touching every pass, not just the printer.
- **Field/name-shortening ownership** (compiler-internal frequency-based vs. deferring to an external
  minifier) — determines whether you collect whole-program usage-frequency data (free if DCE already
  collects it).
