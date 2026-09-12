# Compiler Architecture for Extreme Speed

**Scope:** general architecture techniques (not type checking, not JS-specific codegen) for a
from-scratch, whole-program-ish compiler for a small ML-family language targeting
**sub-100ms warm rebuilds** on a large codebase. Sources: rustc-dev-guide, salsa and
rust-analyzer blogs/issues, Zig/Carbon/oxc source and design docs, simdjson/simdutf papers,
Bazel/Unison docs, and measured benchmarks where available.

---

## 1. Lexing at GB/s

**Table-driven vs switch-based DFA.** Generated jump-table DFAs (e.g. Rust's `logos`)
dispatch per byte via an indirect table lookup — already branch-free and fast. Hand-written
switch-on-first-byte lexers with specialized inner loops (Clang's `Lexer.cpp`, the de facto
industrial benchmark) let the compiler turn dense `switch`es into jump tables while
hand-optimizing common inner loops (ASCII identifier runs, number scanning) that a generic
DFA generator can't special-case. **Recommendation:** hand-written switch + specialized
loops (Clang/Zig/Carbon style) — simpler than a generated DFA or SIMD, already close to the
SIMD ceiling.

**SIMD scanning.** simdjson's two-stage architecture (Langdale & Lemire, VLDB 2019,
[arXiv:1902.08318](https://arxiv.org/abs/1902.08318)): stage 1 classifies every byte in bulk
with AVX2 `VPSHUFB`/AVX-512 masks (32–64 bytes/cycle) producing a sparse "interesting
positions" index; stage 2 walks only that index. Measured: 6 GB/s minify, 13 GB/s UTF-8
validation ([simdutf](https://simdutf.github.io/simdutf/), now in Node/Bun/WebKit/Chromium),
3+ GB/s parse, ~4× RapidJSON, ~25× nlohmann/json.

Directly relevant lexer case study: [alic.dev, "Beating the fastest lexer generator in
Rust"](https://alic.dev/blog/fast-lexing) — ARM NEON `vqtbl4q_u8` byte classification plus a
"skip loop" for whitespace/identifier runs. A naive scalar lexer was 1.79× *slower* than
`logos`; after SIMD classification, 1.47× *faster*; 18–30% wins across realistic file sizes.
**Verdict:** real 30–50% win, but second-order — chase only after token representation and
dispatch are tight.

**Keyword recognition.** Three real designs:

- gperf-style minimal perfect hash at generator time — O(1), used historically by GCC.
- Trie/switch classification of a generically-lexed identifier
  ([michalpitr](https://michalpitr.substack.com/p/fast-scanning-detecting-keywords-c58bd64befeb))
  — measured **~30% faster on average** than hash+`strncmp` across 1K–128K line files,
  because most non-keywords are rejected after 1–2 characters while hashing must consume the
  whole string first.
- Register-packed perfect hash: pack short keywords (≤8 bytes) into a `u64`, compare in one
  instruction. Fastest for ML-family keyword sets (`let`, `type`, `case`, `if`), nearly all
  ≤8 bytes.

**Recommendation:** lex identifiers generically, classify keywords via switch-trie or
packed-register compare — before interning, not through the general symbol table.

**Token representation — 8 bytes/token, offsets not slices.** Zig's tokenizer
(`lib/std/zig/Ast.zig`) stores `MultiArrayList(struct{tag, start: u32})` — 5 bytes/token,
**no length field**, because length is derivable from the tag or re-derived when literals are
decoded anyway. Zig documents empirical ratios (~2 tokens/AST node, ~8 source bytes/token)
used to pre-size arrays.

Carbon did a *measured* bit-packing pass
([PR #4270](https://github.com/carbon-language/carbon-lang/pull/4270)): exactly 8 bytes/token
(kind + whitespace bit + payload + byte offset). **Measured: 5–12% lex-time reduction (more
on bigger files), ~4.5% parse-time, 1–2% total check-time** — a rare whole-pipeline number
for a "boring" layout change. oxc converges on the same design.

Why offsets not slices, from three independent sources: a slice is 16 bytes vs a 4-byte
offset (4× table size); offsets are relocatable/serializable (no pointer fixups — matters for
parallelism and persisted caches); length is cheap to re-derive. **Recommendation:** adopt
Zig's scheme near-verbatim: `{tag: u8/u16, start: u32}` in SoA layout.

**Eager vs on-demand lexing.** Eager (full token array up front — Zig, Carbon, oxc all do
this) enables SoA storage, parallel per-file lexing, and re-slicing for error recovery/IDE use
without re-invoking the lexer, at under 1 byte of token table per source byte.
**Recommendation:** eager.

---

## 2. Parsing speed

**Recursive descent + Pratt parsing.** matklad, ["Simple but Powerful Pratt
Parsing"](https://matklad.github.io/2020/04/13/simple-but-powerful-pratt-parsing.html) — parse
an operand, loop consuming infix/postfix operators while their left binding power ≥ the
caller's threshold, recursing with the right binding power; associativity falls out of
asymmetric `(left_bp, right_bp)` pairs. ~40 lines, handles prefix/infix/postfix/mixfix
uniformly, avoids one function per precedence level. Every fast modern hand-written parser
(Zig, Carbon, rust-analyzer, oxc) uses recursive descent for declarations + Pratt for
expressions. **Adopt — it's free.**

**Flat arena AST with u32 indices — the dominant pattern, confirmed across four designs:**

- **Zig**: `MultiArrayList(struct{tag, main_token: u32, data: Data})` where `Data.lhs/rhs` are
  u32 indices into the same array or an "extra data" array — no pointers at all. Direct
  application of Andrew Kelley's "Practical Data-Oriented Design"; the cited example shrank
  a working set to ~1700 bytes via an SoA transform (a "5-character diff").
- **Carbon** ([toolchain/docs/parse.md](https://github.com/carbon-language/carbon-lang/blob/trunk/toolchain/docs/parse.md)):
  flat *postorder* array (kind + token + subtree size per entry), explicitly justified as
  minimizing per-node allocation and pointer-chasing; semantic analysis consumes it in
  postorder because that's the natural availability order.
- **rust-analyzer's rowan / Roslyn's red-green trees**
  ([Eric Lippert](https://ericlippert.com/2012/06/08/red-green-trees/)): an immutable,
  position-free **green tree** storing only node *widths*, with structural sharing of
  identical subtrees; a lazily-materialized **red tree** facade adds parent pointers/absolute
  offsets on demand and is discarded per traversal. Swift's libsyntax uses the same model.

All four converge: don't store the AST as owned heap pointers; store index-addressed flat
arrays (or a shareable immutable green layer) and reconstruct rich views lazily. Buys: one
bump allocation per phase instead of per-node malloc, cache-friendly sequential traversal,
trivial serialization for caching, and (red-green) structural sharing across edits.

**Full-fidelity CST — cost and when to pay it.** rowan/Roslyn's split exists because IDE
tooling needs a lossless CST (every whitespace/comment byte round-trips) for exact-text
refactoring. matklad's [Resilient LL Parsing
Tutorial](https://matklad.github.io/2023/05/21/resilient-ll-parsing-tutorial.html) builds a
lossless CST directly as parser output with the AST as a thin typed view. **Cost:** trivia
must be threaded through every production (implementation complexity), but in a flat/arena
design trivia is "just more array entries" — near-zero runtime cost, all of it upfront design.
**Recommendation:** build the lossless CST from day one if LSP support is a goal — retrofitting
it later is documented (rust-analyzer, Roslyn) as effectively a parser rewrite.

**Error recovery without happy-path cost.** Two converged invariants: (1) every parse loop
must guarantee EOF-termination and consume ≥1 token per iteration (a correctness invariant
already needed on the happy path); (2) on error, synthesize a placeholder node (Carbon's
`InvalidParse`) so the tree stays structurally valid — downstream passes treat it as another
node kind, with no separate recovery machinery.

---

## 3. String and symbol handling

**Intern once, at lex time.** rustc's `Symbol` is a `u32` from a global interner, with
well-known identifiers pre-registered so common names skip hashing entirely. Compute the hash
while scanning identifier characters and probe the table immediately — never
materialize-then-rehash.

**Interner throughput.** [lasso](https://github.com/Kixiron/lasso): single-threaded
`Rodeo::resolve` ~13.2 GiB/s (ahash), `get_or_intern` ~865–980 MiB/s; a frozen `RodeoReader`
allows lock-free resolve-only phases. Concurrent `ThreadedRodeo` **degrades under
contention**: ~1.15 GiB/s resolve single-threaded, dropping to ~99 MiB/s resolve / ~73 MiB/s
intern at 24 threads. Naive shared-lock interners get *slower* with more threads.

**Hashing — FxHash beats "better" hashes here.** rustc uses
[rustc-hash/FxHash](https://github.com/rust-lang/rustc-hash) (8 bytes/iteration polynomial
hash) instead of SipHash. Measured: FNV→FxHash up to 6% speedup; reverting to SipHash caused
**4–84% slowdowns**; even FxHash→ahash was a net 1–4% *regression* on rustc's access patterns
([Rust Perf Book](https://nnethercote.github.io/perf-book/hashing.html)). Cryptographic
strength is waste for compiler-internal u32-keyed maps.

**Small-string optimization stacks with interning.** oxc found that removing an interning
library in favor of small-string types gave **~30% improvement in parallel parsing
throughput** and shrank `TokenValue` 32→24 bytes
([oxc.rs/docs/learn/performance](https://oxc.rs/docs/learn/performance)). Most identifiers are
short enough that SSO beats interning for the token payload; a real interner still pays once
identifiers persist into name resolution.

**Thread-safety: shard/merge, not shared-lock.** Per-thread/per-module interners during
parallel lex+parse, merged at a single synchronization point, avoid the contention collapse
above.

---

## 4. Memory strategy

**Arenas eliminate `free`.** Bump-allocate, reset the whole block at phase end; no per-object
bookkeeping, no destructors ([bumpalo](https://github.com/fitzgen/bumpalo), rustc's
`TypedArena`). **Measured:** oxc's move from per-node heap allocation to a bumpalo arena AST
gave **~20% overall improvement**, plus better cache behavior from construction-order layout.

**Index-based graphs beat pointers** — confirmed independently by Zig, rust-analyzer, and oxc.
Rule: anywhere an IR node would hold a pointer to another node, hold a `u32` index into a flat
array. Effects: halves node size on 64-bit, makes nodes trivially copyable/sendable (no
refcounting or GC), enables SoA layout. oxc's parent-pointer tree is index-backed rather than
`Rc`/`RefCell`, explicitly to avoid atomic refcounting and enable multithreaded access.

**SoA/MultiArrayList.** Zig's `std.MultiArrayList(T)` converts AoS→SoA with near-identical
call-site ergonomics ("a 5-character change"), used pervasively in the self-hosted compiler's
AST for cache locality.

**Cumulative effect, from oxc's own numbers:** arena AST (~20%) + enum boxing shrinking
variants 200+→16 bytes (~10%) + `usize`→`u32` spans (~5%) + SSO replacing the interning lib
(~30% in parallel parsing) + SIMD whitespace skip (a few %). None is a silver bullet; it's a
checklist.

**Allocator choice — a nearly free multiplier.** mimalloc claims to "always outperform"
jemalloc/tcmalloc/Hoard in its own benchmarks, at up to ~25% more worst-case memory. ScyllaDB
reported **40%** switching off glibc malloc under concurrent load. But this multiplies
allocation-heavy code — a compiler that already arena-allocates will see far less.

---

## 5. Parallelism

**Trivial wins: per-file lex/parse/signature extraction.** Embarrassingly parallel, near-linear
with core count, bounded by I/O and thread-spawn overhead.

**Work-stealing (rayon).** `join()` runs the left task inline and pushes the right onto a local
deque; idle threads steal from the back. Rustc's parallel frontend uses rayon. Important
limitation: the stealing model is safe for **tree-shaped fork-join work**, not arbitrary DAGs
— the Rust internals team explicitly flagged that naive DAG scheduling over rayon risks
deadlock. A module dependency graph is a DAG, not a tree.

**Measured backend parallelism (rustc CGUs).**
[Nethercote](https://nnethercote.github.io/2023/07/11/back-end-parallelism-in-the-rust-compiler.html):
16 codegen units, **9.7s serial → 4.5s parallel** (>2×), but the slowest CGU bounds wall time
regardless — a direct Amdahl's-law instance. Cost: worse codegen quality, higher peak memory,
larger binaries. His conclusion: **CGU-size estimation error, not scheduling, is the actual
bottleneck** — a caution against over-building a scheduler when partitioning is weak.

**Frontend parallelism, measured.**
[Rust blog](https://blog.rust-lang.org/2023/11/09/parallel-rustc/): `-Z threads=8` cuts compile
time **up to 50%** on real code, but with high variance, *slowdowns* on small/fast programs
(thread setup exceeds available work), and significantly increased memory.

**The hard parts.** Lex/parse parallelize trivially; global interning, name resolution, and
whole-program unification do not, because they touch shared mutable state or connect anything
to anything. matklad's [Three Architectures for a Responsive
IDE](https://rust-analyzer.github.io//blog/2020/07/20/three-architectures-for-responsive-ide.html)
catalogs the map-reduce escape hatch used by IntelliJ/Sorbet: index each file into a cheap
"stub" (unresolved signature) in parallel, then a single serial reduce pass touches only
cross-file references. Works whenever a language has a cheap per-file "signature" — true for
most ML-family module systems.

**Determinism under parallelism — a real, unsolved cost.** Rust's project goals state plainly:
"the parallel frontend has fundamental issues with deterministic compilation... some fixes may
make compilation slower." `codegen-units > 1` already produces non-deterministic binaries
because CGU merge order depends on thread timing ([rust#128675](https://github.com/rust-lang/rust/issues/128675));
a dedicated tool (`repro-check`) exists just to verify reproducibility.

Practical rules: assign stable input-derived IDs *before* parallel work starts (module index by
sorted path, not completion order); re-key fork-join results by that stable ID before merging,
never by arrival order; keep global tables append-then-sort; test determinism by diffing two
runs, don't assume it.

**Amdahl realism for sub-100ms warm rebuilds — the key finding.** Parallelism targets the
wrong axis for this goal. It buys large wins on clean builds and big batch recompiles, and
moderate/uneven wins on the whole-program middle (~1.5–2×). But at sub-100ms latency for a
*single-file-edit* rebuild, thread-pool wake-up and synchronization can exceed the actual work
— exactly what rustc's regressions on small inputs under `-Z threads=8` show.
**Recommendation:** parallelize lex/parse/per-module signature extraction; keep the warm
single-edit path serial.

---

## 6. Incremental compilation — compared honestly

### 6a. Query-based memoization + red-green invalidation (salsa, rustc, rust-analyzer)

**Mechanism** ([rustc-dev-guide](https://rustc-dev-guide.rust-lang.org/queries/incremental-compilation-in-detail.html)):
the compiler is a set of memoized pure queries; each execution records dependency edges into a
DepGraph; nodes are identified by 128-bit stable fingerprints that survive across runs.
Red-green: a node is green if `try_mark_green()` shows every previous dependency is recursively
green, in which case the query is **not** recomputed.

**Primary-source admission of cost:** the dev guide states outright — **"computing fingerprints
is quite costly. It is the main reason why incremental compilation can be slower than
non-incremental compilation."** The on-disk cache is rewritten wholesale each session, costing
"a few percent of total compile time."

**Measured net-negative case:** [rust#62445](https://github.com/rust-lang/rust/issues/62445) —
clean build 2.74s; incremental with stale cache 13.47s; follow-up incremental rebuild 4.45s,
still slower than clean.

**Measured memory blowup:** [rust#48172](https://github.com/rust-lang/rust/issues/48172) —
16–19GB incremental artifacts on a small project;
[rust#73337](https://github.com/rust-lang/rust/issues/73337) — incrementally compiling
`rustc_middle` OOM'd an 8GB machine while the same crate compiled fine non-incrementally.
On the salsa side: [rust-analyzer#19402](https://github.com/rust-lang/rust-analyzer/issues/19402)
— memory **quadrupled** to 22–30GB after a Salsa migration;
[rust-analyzer#16176](https://github.com/rust-lang/rust-analyzer/issues/16176) — salsa's
interning leaks due to churning unstable intermediate IDs. Salsa's LRU RFC states that
ordinary GC-style eviction is insufficient; dedicated LRU engineering only brought usage
8GB→4GB→~3.4GB across separate passes. **A structural cost, not a one-time bug.**

**One cheap idea worth stealing — durability tiers.** [rust-analyzer: Durable
Incrementality](https://rust-analyzer.github.io/blog/2023/07/24/durable-incrementality.html): a
single global revision counter forces re-validating every query that transitively touched *any*
file, including the standard library — ~300ms/edit re-checking provably-unchanged stdlib state.
Fix: a small version vector across durability tiers (volatile file / project / stdlib); bumping
a component bumps less-durable components, so whole durable subgraphs skip validation via an
integer comparison. Cheap, general, separable from the full query engine.

**The load-bearing quote**, from matklad — who *built* rust-analyzer on salsa: responsiveness
comes from **laziness** (not computing what you don't need), not incrementality per se; salsa's
fine-grained machinery was needed specifically because Rust's procedural macros and path
attributes break the laziness simpler architectures rely on. **An ML-family language without
unrestricted macros almost certainly does not have this problem.**

### 6b. Separate compilation via interface files (the firewall model)

**OCaml `.cmi`/`.cmx`**: downstream units depend only on `.cmi`; native compilation
additionally propagates cross-module inlining via `.cmx`, so an implementation-only change can
still force downstream recompilation. The `-opaque` flag (4.04+) severs this deliberately,
trading cross-module inlining for a hard firewall — an explicit granularity knob.

**GHC `.hi`**: the recompilation checker compares a *newly computed* `.hi` against the existing
one and leaves the file untouched if content is identical — Make-friendly with no bespoke
dependency machinery; `-ddump-hi-diffs` shows what triggered each invalidation.

**Elm's failure modes as a cautionary tale.**
[elm/compiler#1365](https://github.com/elm/compiler/issues/1365): changes failing to propagate
due to `elm-stuff`/`.elmi` cache desync;
[#313](https://github.com/elm/compiler/issues/313): stale artifacts from an incompatible
compiler version not auto-invalidated, requiring manual deletion. Generic risk: **the cache is
external, mutable, versioned state that can silently desync from source** — unlike
content-addressing, where staleness is structurally impossible.

### 6c. Content-addressed / hash-based caching (Bazel, Unison)

**Bazel**: action key = hash(command + inputs + env); the Action Cache maps action-hash→result
metadata, a separate CAS maps content-hash→bytes, deduping identical outputs. Correctness is
structural — identical inputs always produce the same key — not dependent on a bespoke,
possibly-incomplete dependency graph.

**Unison — the radical end-state.** Every definition is identified by a SHA3 hash of its
name-erased AST. From its docs: **"Unison has perfect incremental compilation… the results are
stored in a cache which is never invalidated… once anyone has parsed and typechecked a
definition… no one has to do that ever again."** Invalidation disappears as a concept.
Tradeoff: the whole toolchain (editor, VCS-equivalent) must be built around
content-addressing; ordinary textual diff/git tooling is given up.

### Granularity/cost comparison

| Model | Invalidation unit | Dep-tracking cost | Memory profile | Failure mode |
|---|---|---|---|---|
| Query/salsa | function/query | Highest — dynamic edge recording + fingerprinting every result | Documented 2–4× blowups; needs dedicated LRU | Silent staleness, or catastrophic memory |
| Interface firewall | module | Low — hash/diff one file | Small, bounded | Coarse over-invalidation (cheap); cache desync if hand-rolled |
| Content-addressed | definition-as-content | Low per lookup; requires restructuring identity | Naturally deduplicating | Structurally cannot go stale; hard to retrofit |

### What a small ML-family compiler should choose

1. **Skip salsa-style fine-grained query memoization.** The evidence comes from the people who
   built it: fingerprinting is cited by rustc's own docs as *the* reason incremental can lose
   to clean; 2–4× memory blowups needed dedicated engineering; a logged case had incremental
   (13.47s) lose to clean (2.74s). matklad's stated rationale — surviving macro-induced
   non-laziness — doesn't apply to a macro-free ML language.
2. **Use module-level interface-hash separate compilation as the primary incremental unit**
   (OCaml/GHC style): hash each module's public interface; recompile only modules whose own
   source changed or whose transitive interface *content* changed — not those whose
   implementation changed but interface didn't. Near-zero tracking cost, flat memory.
3. **Borrow two cheap ideas rather than whole architectures:** durability tiers (file /
   project / stdlib) so editing user code never re-validates stdlib state — a small vector, not
   a query engine; and content-hash cache keys (source + compiler version + flags) rather than
   mtime, making staleness structurally impossible (fixing Elm's exact bug class) at near-zero
   cost, composing naturally since "interface hash" already is a content hash.
4. Parallelize per-module signature extraction (map-reduce style); don't parallelize
   whole-program unification/name resolution at this scale.

---

## 7. Persisted caches

**Zero-copy formats eliminate deserialization, not just speed it up.** Cap'n Proto's wire
format is bit-identical to its in-memory layout — with mmap, "deserialization" never reads or
parses the file. rkyv benchmarks ([david.kolo.ski](https://david.kolo.ski/blog/rkyv-is-faster-than/)):
access after "deserialization" — rkyv **1.36 ns**, flatbuffers 2.98 ns, capnp 260 ns, bincode
**4.28 ms**, prost 5.10 ms on a log dataset — a ~3-million-to-1 ratio vs. tree deserialization,
because bincode allocates and copies a whole tree while rkyv validates a pointer cast.

**Content-hash invalidation with a cheap fast-path.** Zig layers a stat-based (mtime/size)
fast-path in front of full content hashing, since a stat syscall is far cheaper than hashing,
falling back to hashing when mtime granularity is unreliable.

**Recommendation:** don't pull in a general serialization library for the hot cache — dump the
arena's flat SoA arrays directly as raw byte ranges with a small header, mmap on load, validate
with a format-version + content-hash check. Use content hash for correctness and stat as a
fast-path to avoid hashing unchanged files.

---

## 8. Compiler-as-a-server / daemon architecture

**The process model dominates perceived latency — the most underrated lever here.** Process
spawn costs tens of milliseconds before your program runs anything (dynamic linker relocation,
libc/allocator init); fork itself is microseconds, but exec+relocation is "an order of
magnitude larger," with measured throughput losses (~2×, 2200 vs 4700 conn/s) from
dynamic-linker cost in fork-heavy cases. JVM startup is the canonical extreme, motivating
Nailgun — a tool whose entire purpose is keeping one JVM resident.

**If the target is sub-100ms, a fresh-process-per-compile CLI can burn a large fraction of the
whole budget on OS/runtime bring-up before lexing a single token.**

**Pattern: long-running server, immutable snapshots.** rust-analyzer: `AnalysisHost` (mutable,
ingests edits) vs `Analysis` (immutable snapshot handed to queries) — readers never race the
writer. gopls: `cache.Snapshot` is the same idea, plus persisted on-disk export data so a fresh
daemon start doesn't re-derive everything. Roslyn generalized this as "compiler as a service":
each phase (syntax trees, symbol tables, semantic models) is a durable, queryable, immutable
object, so IDE and CLI share one code path.

**Recommendation:** build the compiler as a daemon from day one with a thin CLI client over a
Unix socket — don't bolt it on later. Internal data structures must be designed for "persist
across edits" (arena reuse, snapshotting, no global mutable singletons). Make the LSP server
and the `build`/`check` CLI the same process type so incremental investment pays off in both.

---

## 9. Host-language choice

- **SWC/oxc chose Rust** for native speed + fearless parallelism: ~20× faster than Babel
  single-threaded, up to ~70× on 4 cores.
- **Roc moved from Rust to Zig** — a directly relevant, compiler-specific counter-signal:
  Rust's own compile times became a productivity tax on *compiler* development, its safety
  guarantees buy little for a batch/arena-scoped program, and Zig's idiomatic style (explicit
  allocators, first-class SoA/`MultiArrayList`) maps directly onto the arena/index-graph
  techniques above with less friction ([rtfeldman.com/rust-to-zig](https://rtfeldman.com/rust-to-zig)).
- **Zig's self-hosted compiler** exploits owning the entire backend (not going through LLVM) to
  do **in-place binary patching** for incremental builds — reported **50–70ms** incremental
  rebuilds of complex applications, because Zig controls codegen layout enough to make
  functions individually relocatable ([kristoff.it](https://kristoff.it/blog/zig-new-relationship-llvm/),
  [mlugg.co.uk](https://mlugg.co.uk/posts/incremental-compilation-internals/)). Owning your own
  backend is what makes this reachable.
- **Elm in Haskell** is a genuine counterexample: no compiler-speed rationale surfaces in Elm's
  materials — the choice reads as "the author knew Haskell," and Elm compile times are never
  marketed as a strength. Host choice isn't automatically about compiler speed.

**Recommendation:** Rust or Zig, not a GC'd host, given the arena/SoA/index-graph architecture.
If compiler-hacking iteration speed matters as much as the shipped compiler's speed, Zig's
faster self-compile times and native SoA/allocator ergonomics are an evidenced argument over
Rust — per Roc's actual migration.

---

## 10. Measurement discipline

**Self-instrumentation converges on a flame-chart/tracing format.** Clang's `-ftime-trace`
emits Chrome Tracing JSON viewable in Perfetto/speedscope, with per-block detail. rustc has
`-Z self-profile`, a per-*query* event trace integrated with the query system, so profiling
captures cache hits/misses at query granularity, not just phase time.
[samply](https://github.com/mstange/samply) is a good default sampler before you build custom
instrumentation; [Tracy](https://github.com/wolfpld/tracy) gives nanosecond manual
instrumentation for always-on tracking of known-hot functions.

**Continuous compile-time regression tracking, in production.**
[rustc-perf](https://github.com/rust-lang/rustc-perf): a living benchmark suite tracked
per-PR, explicitly grown by adding a benchmark **for every pathological case ever hit in
production** — `token-stream-stress` (added after a proc-macro caused quadratic blowup),
`tuple-stress` (65,535 nested tuples that OOM'd). Policy is deliberately *not* a hard gate —
some regressions are accepted tradeoffs — but the number is visible on every PR, making
regressions conscious rather than accidental.

**Recommendation:** build a `--self-profile`-style flag emitting Chrome-trace JSON per phase
from day one; grow a permanent corpus of pathological fixtures the rustc-perf way — freeze
every real slow file into the benchmark set forever; track headline numbers (cold N-file build,
warm rebuild after touching 1 file, warm rebuild after touching a widely-imported module) in CI
as a visible trend, not a hard gate.

---

## Top 10 highest-leverage techniques, ranked

1. **Daemon/server architecture with immutable snapshots.** Process spawn alone can cost tens
   of ms — often the majority of a 100ms budget — before a single token is lexed.
2. **Flat arena AST/IR with u32 indices instead of pointers.** The one structural decision that
   simultaneously enables SoA layout, cheap parallelism, zero-copy serialization, and no
   per-node malloc. Independently arrived at by Zig, Carbon, rust-analyzer, and oxc.
3. **Module-level interface-hash incremental compilation (not salsa-style queries).** Most of
   the value at near-zero tracking cost and flat memory.
4. **Content-hash cache keys, not mtime.** Structurally eliminates the stale-cache bug class at
   near-zero cost; composes with #3.
5. **Symbol interning at lex time (u32 symbols, FxHash-style, per-module + merge).** Removes
   double-hashing, makes downstream comparisons integer compares, sidesteps interner contention.
6. **Arena/bump allocation per phase, mimalloc as default allocator.** ~20% measured from the
   arena AST alone (oxc); the allocator swap is a free multiplier on top.
7. **Token representation as tag+u32-offset (no length, no slices), 5–8 bytes/token.** Carbon's
   measured 5–12% / 4.5% / 1–2% (lex/parse/check) with essentially no implementation risk.
8. **Trivial parallelism for lex/parse/signature extraction only — not the warm single-edit
   path.** Near-linear for cold builds; near-zero or negative at sub-100ms single-edit
   granularity.
9. **Recursive descent + Pratt parsing for expressions.** Free to adopt, ~40 lines, no runtime
   cost.
10. **Self-profiling instrumentation + a permanent pathological-case benchmark corpus in CI
    from day one.** The only way to notice regressions before users do.

---

## Overrated / not worth it (for this target)

- **Salsa-style fine-grained query memoization with red-green tracking.** rustc's own docs call
  fingerprinting "the main reason incremental compilation can be slower than non-incremental";
  repeated documented 2–4× memory blowups; a logged case of incremental (13.47s) losing to clean
  (2.74s). matklad — salsa's architect for rust-analyzer — says the real goal is *laziness*, and
  fine-grained tracking was needed specifically to survive Rust's macros. A macro-free ML
  language doesn't have that problem.
- **SIMD lexing as a first move.** Real (30–50%), but second-order: a switch-driven scalar lexer
  is already within ~2× of the SIMD ceiling, and per-ISA intrinsics/fallbacks cost a lot until
  everything else is tight. Do it last, if ever.
- **Parallelizing whole-program name resolution / unification.** rustc's frontend parallelism
  tops out around 50% on good cases with regressions on small inputs, and the determinism
  problem is called "fundamental" and still unsolved in rustc's own mature effort.
- **General-purpose serialization libraries for the hot persisted cache.** Steal the zero-copy
  *idea* (mmap + cast, no parse step); hand-rolling it for your own flat arena format is simpler
  than integrating an external framework's schema/codegen for a format only your compiler reads.
- **gperf-generated perfect hash tables for keywords.** A hand-written switch-trie measurably
  beats hash+strncmp (~30%) and needs no code-generation step.
- **Content-addressed code (Unison-style) as a whole-language design.** Elegant and genuinely
  eliminates invalidation, but it's a whole-system commitment that gives up ordinary git/diff
  tooling. Steal the *cache-keying* idea without the model.
- **Chasing allocator benchmarks beyond "pick one, link it, move on."** The gap between
  allocators is real but small next to the gap between arena-allocated and malloc-per-node.

---

## Bottom-line architecture recommendation

Build it as a **persistent daemon** (kills the process-startup tax, the biggest hidden cost at
100ms scale) in **Zig or Rust** (arena/SoA/index-graph ergonomics, no GC pauses), with an
**eager, SoA token array** (tag+u32-offset, no slices) feeding a **flat arena AST with
u32-indexed nodes** built via **recursive descent + Pratt parsing**, producing a **lossless
CST** from day one if any LSP story is planned. Intern identifiers **at lex time** into
per-module interners merged at a single sync point. For incremental compilation, skip
fine-grained queries in favor of **module-level interface-hash separate compilation** with
**content-hash cache keys** and a small **durability-tier** vector. Parallelize only the
embarrassingly-parallel per-file phases; leave the warm single-edit path serial. Instrument with
a **Chrome-trace-style self-profiler** from day one and grow a permanent pathological-fixture
corpus tracked in CI as a visible (not gating) trend.
