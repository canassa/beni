# Why the Zig Self-Hosted Compiler Is Fast

Verified against the local clone at `references/zig` (master, Sept 2026) and primary sources
(ziglang.org devlogs/release notes, GitHub PRs, Andrew Kelley / Loris Cro / Jarred Sumner).
Every claim below is either a direct code citation (`file:line`) or a quoted primary source
with a URL.

---

## 1. Data-oriented design: SoA everywhere, zero pointer-chasing trees

**Mechanism.** Every IR in the pipeline — `Ast.Node`, `Zir.Inst`, `Air.Inst` — is stored as a
`std.MultiArrayList(T)`, not as heap-allocated, pointer-linked nodes. `MultiArrayList` does one
allocation for the whole list and splits it into per-field arrays sorted by descending
alignment (`lib/std/multi_array_list.zig:180-215`), so there is no per-element padding and each
field is densely packed and independently cache-scannable.

```zig
pub const Node = struct { tag: Tag, main_token: TokenIndex, data: Data };  // lib/std/zig/Ast.zig:2914-2917
comptime { assert(@sizeOf(Tag) == 1); if (!std.debug.runtime_safety) assert(@sizeOf(Data) == 8); }  // :2979-2984
```

A `Node` is `tag(1) + main_token(4) + data(8)` ≈ 13 bytes, stored as three parallel arrays
(`tags[]`, `main_tokens[]`, `data[]`). Compare to a classic AST where each node is a separate
heap object with a vtable/RTTI pointer, child pointers, and malloc header/padding — typically
40–80+ bytes plus 8–16 bytes of allocator overhead per node, and non-contiguous memory.

`Node.Data` is an **untagged union** (`Ast.zig:3843-3863`): `Node.Tag` (already stored
separately) tells the reader which arm is valid, so no runtime tag byte or branch is spent on
the union itself — "zero-overhead polymorphism," the DoD alternative to virtual dispatch. The
same pattern repeats for `Zir.Inst` (`lib/std/zig/Zir.zig:161-167`) and `Air.Inst`
(`src/Air.zig:33-35`).

**Anti-patterns explicitly avoided:** boxed/heap AST nodes, visitor-pattern double dispatch,
one malloc per node, tagged unions that waste a discriminant when an external enum already
discriminates, AoS layouts that pull unused fields into cache.

**Transfer to a JS-targeting compiler:** fully transferable in a non-GC host. Implement your own
`MultiArrayList` or hand-roll parallel arrays per field. (In a GC'd host you can't get a manual
single-slab allocation, but typed arrays per field recover most of the win.) One of the
highest-leverage, lowest-risk techniques to port.

## 2. u32 indices instead of pointers

**Mechanism.** Nothing in the AST/ZIR/AIR/InternPool layer holds a native pointer to another
node. Indices are wrapped in tiny `enum(u32)` types with sentinel-based optionals
(`.none = maxInt(u32)`) and relative "offset" variants for the common "just before me" case:

```zig
pub const Index = enum(u32) { root = 0, _ };
pub const OptionalIndex = enum(u32) { root = 0, none = maxInt(u32), _ };
pub const Offset = enum(i32) { zero = 0, _ };   // Ast.zig:2920-2966
```

Why this beats a 64-bit pointer:

1. Half the memory per reference, roughly doubling effective cache-line density for
   reference-heavy structures.
2. An index is trivially serializable to/from disk; a pointer is not, without a relocation
   pass. This is the explicit rationale in PR #11467 — "*Using integers to reference Decl
   objects rather than pointers makes serialization trivial*" (andrewrk, 2022-04-18,
   https://github.com/ziglang/zig/pull/11467).
3. Indices into a stable backing store stay valid across reallocation, unlike pointers into a
   list that reallocates.
4. Index equality is integer equality — exactly what makes interning (§5) cheap.

The 2024 roadmap coverage makes the payoff explicit: "*converting the compiler's internal
representation to avoid the use of pointers, instead storing information as flat arrays accessed
by index... permits the compiler's internal knowledge of the program to be saved directly to
disk and then loaded again without parsing or fixups, so incremental compilation can just
mmap() the previous analysis and access it directly*" (LWN, https://lwn.net/Articles/959915/).

**Transfer:** fully portable. In a GC'd host this is *more* valuable, not less — an array full
of indices contains no GC roots, so the collector never scans it.

## 3. `extra_data`: trailing-payload arrays instead of variant-sized nodes

**Mechanism.** Every node/instruction is fixed-size (13 bytes for `Ast.Node`), yet nodes need
variable amounts of data (a call's argument list, a struct's field list). The `data` field holds
either inline scalars or an `ExtraIndex` — an offset into one shared `extra: []u32` array — under
which a fixed-layout header struct (`Node.LocalVarDecl`, `Node.PtrType`) is stored, sometimes
followed by a trailing run of `u32`s (a `SubRange`) for open-ended lists (`Ast.zig:3861-3883`,
`Air.zig:26-30`).

This is the flat-array equivalent of a tagged union with an out-of-line variable-length payload,
except the payload lives in one shared `u32` buffer instead of N heap-allocated buffers — one
growable allocation serves every node's variable data, and reading it back is a slice index.

**Transfer:** directly portable. Even a GC'd host benefits: it avoids one small-object
allocation per variable-length payload, the pattern that stresses a generational GC hardest.

## 4. Arena / bump allocation, and never freeing per-node data

Per-file AST/ZIR memory is populated once by `Parse`/`AstGen` and never individually freed
node-by-node; the whole `Ast`/`Zir` is torn down (or cached) as one unit via `Ast.deinit`
(`Ast.zig:132-137` — four bulk frees for an entire file's AST, not thousands of node frees).

The `InternPool`'s per-thread mutation state uses a dedicated arena
(`src/InternPool.zig:970-975`): "*When we need to allocate any long-lived buffer for mutating
the InternPool, it is allocated into this arena... An arena is used to avoid contention on the
GPA, and to ensure that any code which retains references to old state remains valid.*" Interned
objects are essentially never individually freed — the doc comment admits "*this arena's
lifetime is tied to that of Compilation, although it can be cleared on garbage collection
(currently vaporware)*" (`InternPool.zig:974`).

A deliberate anti-pattern rejection: no destructors, no refcounting, no per-object free — pay a
bounded amount of "leaked until process exit" memory to eliminate malloc/free churn.

**Transfer:** portable in spirit to any language; literally use arenas in a non-GC host.

## 5. String/type/value interning via `InternPool`

**What's interned.** `Type` and `Value` are not separate boxed types; both are a **single 4-byte
wrapper** around one shared 32-bit space:

```zig
//! Both types and values are canonically represented by a single 32-bit integer
//! which is an index into an `InternPool` data structure.
ip_index: InternPool.Index;   // src/Type.zig:1-19, src/Value.zig:1-18
```

Comparing two types, or two values, for identity is `a.ip_index == b.ip_index` — one integer
comparison, no structural walk, no hashing at compare time (hashing happened once, at intern
time). Identifiers/strings intern into a shared `string_bytes`/`strings` table;
struct/union/enum/func/error-set types, comptime values and numeric constants are deduplicated
the same way. `Air.Inst.Ref` (`src/Air.zig:1099-1114`) and `Zir.Inst.Ref` reuse
`InternPool.Index`'s backing integers for their first N enum values, so an operand is *either* a
reference to an already-interned constant *or* a local instruction index, unified in one 32-bit
space with no boxing.

**Design rationale:** PR #15569, "Use InternPool for all types and constant values" (andrewrk,
2023-05-04, https://github.com/ziglang/zig/pull/15569): "*This changeset is centered around the
InternPool data structure... Follow-up enhancements will include: Reworking the AIR encoding to
take advantage of ability to reference constants via 32 bits... Introducing garbage collection to
the InternPool... Serialization and deserialization of the InternPool as part of incremental
compilation.*"

**Measured payoff of interning refinement.** PR #16105 ("InternPool: various optimizations,"
jacobly0, 2023-06-20, https://github.com/ziglang/zig/pull/16105), compiler self-build:

| metric | before | after | delta |
|---|---|---|---|
| wall time | 4.924s | 4.063s | **−17.5%** |
| CPU cycles | 24.64B | 20.29B | **−17.7%** |
| instructions | 46.26B | 41.30B | **−10.7%** |
| cache misses | 98.5M | 87.2M | **−11.5%** |
| branch misses | 95.3M | 74.8M | **−21.5%** |

A rare apples-to-apples self-hosted benchmark for a pure data-structure change — strong evidence
that mechanical-sympathy work (hash quality, layout, avoiding redundant lookups) outpays
algorithmic cleverness at this stage.

**Hashing/dedup.** Values hash with `std.hash.Wyhash` (`InternPool.zig:15`) into open-addressed
tables (`Shard.Map`, `InternPool.zig:1449-1520`); `getOrPutKey` does the intern-table
get-or-insert (`InternPool.zig:7149-7158`, plus 30+ call sites).

**Concurrency.** The `InternPool` is designed for future multi-threaded Sema, sharded to reduce
contention:

- `locals: []Local` — one array **per thread** (`InternPool.zig:24`), each with a `Shared` part
  (read via `.acquire()` atomic loads by any thread) and a `mutate` part touched only by its
  owner (`:960-988`).
- A 32-bit `Index` packs a thread id into the high bits and a per-thread offset into the low bits
  (`:209-221`): `@shlExact(tid, tid_shift_32) | local_index`. Lock-free allocation per thread,
  one globally comparable 32-bit handle.
- Dedup hash tables are **sharded** (`:1449-1520`) with per-shard recursive mutexes and lock-free
  `acquire()`/`release()` reads via atomic pointer swap — readers never block on a writer
  resizing a *different* shard.
- Still WIP: `Zcu/PerThread.zig:64-68` — "*This is a temporary workaround put in place to migrate
  from std.Thread.Pool to std.Io.Threaded... The eventual solution will likely involve significant
  changes to the InternPool implementation.*" Tracked in PRs #20528, #20552, #20632. PR #20528
  candidly reports the safety machinery initially *cost* performance ("*the multi-threaded
  features... have a large performance impact... it is still undecided how to minimize the
  impact*") before being clawed back with targeted sharding — thread-safety was **not** free.

**Real-world motivation:** issue #22236 ("Semantic analysis takes too long," Jarred Sumner/Bun,
2024-12-15, https://github.com/ziglang/zig/issues/22236) reports Sema alone taking 19–27 seconds
on an M3 Mac for Bun's codebase, single-threaded.

**Transfer:** interning is *the* highest-value technique to port regardless of host language —
O(1) equality and dedup for types/constants. Thread-sharding matters only if you actually
parallelize semantic analysis.

## 6. Pipeline: Tokens → AST → ZIR → AIR → backend, with a cacheable untyped IR

**Why a separate untyped IR (ZIR) matters.** ZIR is *per file*, generated once by `AstGen` from
the AST, and is **content-addressed and disk-cached independently of semantic analysis**. A file
whose text hasn't changed never needs re-parsing or re-lowering, even across separate compiler
invocations — not just within a `--watch` session.

Verified in `src/Zcu/PerThread.zig:485-620` (`updateFile`): the compiler computes a cache key
from `file.path`, compiler version and codegen backend (`h.final()`, ~line 495), looks up a
`local_zir_cache`/`global_zir_cache` entry by that hex digest, and — if the file's `stat`
(size/mtime/inode) is unchanged — returns the cached `Zir` without touching the tokenizer,
parser, or `AstGen` (`if (unchanged_metadata) return;`, ~line 510). File-level advisory locks
coordinate concurrent `zig` processes racing to update the same entry.

AIR, by contrast, is generated fresh per function by `Sema` and is not independently cached —
it's short-lived, consumed immediately by codegen (`src/Air.zig:1-5`: "*Unlike ZIR where there is
one instance for an entire source file, each function gets its own Air instance.*").

**What's memoized at each boundary:**

- Tokens → not cached (regenerated per parse, but parsing itself is skipped on a cache hit).
- AST/ZIR → cached to disk per file, keyed by content digest + compiler version + backend.
- ZIR → AIR (Sema) → memoized at declaration/function granularity via the incremental dependency
  graph (§7), recomputed in-memory but only for outdated declarations.
- AIR → machine code → not cached across runs generally, but under `-fincremental` the
  self-hosted ELF linker patches machine code for individual changed functions into the existing
  binary (§10).

**Transfer:** the single most portable architectural idea here. Keep an explicit IR that is
(a) untyped/unresolved and (b) purely a function of one source file's text, and cache *that*
separately from the type-checked representation. For JS output this maps onto "cache the per-file
lowered-but-unchecked IR; re-run inference/binding/codegen only for files whose
dependency-relevant surface changed."

## 7. Incremental compilation: a fine-grained dependency graph, not file-level

**Granularity is far below "per file."** `InternPool.AnalUnit` (`InternPool.zig:422-431`) is the
atomic unit of re-analysis:

```zig
pub const Kind = enum(u32) { @"comptime", nav_val, nav_ty, type_layout, struct_defaults, func, memoized_state };
```

A single declaration's **type** and **value** are tracked as *separate* units (`nav_ty` vs
`nav_val`) — editing a function body invalidates its `func`/`nav_val` unit, not callers who
depend only on its signature. Layout resolution (`type_layout`) and default field values
(`struct_defaults`) are independently tracked, so adding a method to a struct doesn't invalidate
everyone storing a field of that type.

**Dependency kinds tracked** (`InternPool.zig:38-77`): source hash of a ZIR instruction
(`src_hash_deps`), a Nav's value (`nav_val_deps`), a Nav's type (`nav_ty_deps`), a function's
inferred error set (`func_ies_deps`), a resolved layout (`type_layout_deps`), struct defaults
(`struct_defaults_deps`), a whole source/ZON file (`source_file_deps`), an `@embedFile`
(`embed_file_deps`), and the existence of a name in a namespace (`namespace_name_deps`) — that
last means adding an unrelated declaration doesn't spuriously invalidate every name lookup, only
ones that queried that specific (non-)existence.

**The propagation algorithm** (`src/Zcu.zig:270-293`, `:3157-3370`) is two-state and
dependency-counted:

1. When a `Dependee` changes, `markDependeeOutdated` walks its direct dependers. A fresh depender
   is marked `outdated`; *its* transitive dependers are marked `potentially_outdated` (PO)
   rather than outdated, incrementing a per-unit PO counter.
2. `PO` is a *maybe* state: analysis visits a PO unit later and decrements neighbours' counters;
   when a PO unit's counter hits zero without ever becoming outdated, it is proven unchanged and
   never re-analyzed. This avoids the classic trap where transitive invalidation degenerates into
   "recompile everything."
3. `findOutdatedToAnalyze` (`Zcu.zig:3322-3369`) prefers a `func` unit whose PO count is already
   zero, to feed codegen/linking sooner: "*We prioritize functions, because the sooner they get
   analyzed, the sooner they can be sent to the codegen backend and linker, which are usually
   running in parallel*".

**Design-rationale sources:** PR #21063 "Incremental compilation progress" (mlugg,
https://github.com/ziglang/zig/pull/21063) adds `resolveReferences`, a reachability traversal from
analysis roots so dead code isn't spuriously re-analyzed, and `putKeyReplace` so a changed type
gets a *new* InternPool index while stale references stay valid-but-unreachable. Issue #21165
tracks known gaps (COFF linker races, MachO incomplete, comptime-memoization dependency
registration incomplete). A 2026-03-10 devlog describes a ~30,000-line refactor specifically to
fix **over-analysis** where a type doubling as both value and namespace caused unnecessary work.

**Measured incrementality** (Zig 0.14.0 release notes,
https://ziglang.org/download/0.14.0/release-notes.html): on a synthetic ~500,000-line codebase,
initial `-fincremental --watch` compilation took **14 seconds**; a subsequent single-file edit
re-analyzed in **63 milliseconds** — ≈220× for the common edit-compile-test loop. Separately, the
2026-05-30 devlog reports genuinely incremental *linking* on Zig's own ~500K-line codebase: 36s
initial link, then **228–288ms** incremental rebuilds (https://ziglang.org/devlog/2026/).

**Persisted today:** per-file ZIR (§6). Full InternPool/dependency-graph serialization across
process invocations was planned but not shipped as of these sources; `--watch` keeps it in memory.

**Transfer:** the deepest idea in this report, and it generalizes cleanly. Model "signature vs.
body," "type vs. value," and "layout vs. contents" as *separate* graph nodes rather than one
coarse "this declaration" node, and use two-phase marking instead of naive transitive
invalidation. For a JS-emitting compiler that maps onto distinguishing "this module's exported
shape changed" (re-typecheck downstream) from "only bodies changed" (re-emit only) — a
distinction TypeScript's incremental builder does *not* make this finely.

## 8. Parallelism today: file-level AstGen, function-wise codegen, single-threaded Sema

`src/Zcu/PerThread.zig:155-198` (`pt.update`): parsing + lowering (`AstGen`) for every file
discovered via `@import` is dispatched as a set of `Io.Group` async workers
(`astgen_group.async(io, workerUpdateFile, ...)`), and newly-discovered imports are pushed into
the *same* group from inside a worker (`:408`) — file parsing scales with file count, bounded by
the `Io` runtime's concurrency rather than a manual thread pool.

Codegen is parallelized **per function** via `Zcu.CodegenTaskPool` (`src/Zcu.zig:5275-5420`):
each analyzed function's AIR goes to `io.async(workerCodegenOwnedAir, ...)`, bounded by an
in-flight-AIR-bytes budget (`max_air_bytes_in_flight = 10 MiB`, with a worst-observed 50× AIR→MIR
expansion factor baked in) and a max in-flight function count — a genuine bounded
producer/consumer pipeline between Sema and codegen, not naive task-per-function.

Sema itself is **not** parallelized: `findOutdatedToAnalyze` drives one `AnalUnit` at a time from
"the main semantic analysis loop" (`Zcu/PerThread.zig:128-131`). This matches the InternPool
thread-safety migration being WIP (§5) and the real-world complaint in issue #22236. Prelinking,
docs generation and the final link step all use the same `Io.Group`/`io.async` abstraction
(`src/Compilation.zig:4407-4440`) — essentially everything *except* Sema is already concurrent.

**Transfer:** file-level parallel parsing/lowering and per-unit parallel codegen port
straightforwardly. Parallel type checking is inherently harder; Zig's own experience — a
multi-month, still-incomplete migration with an initial performance *regression* from added
synchronization — is a useful caution: don't parallelize the checking core until the data model
(interning + dependency graph) is solid.

## 9. Tokenizer/parser: single pass, LL(k), no backtracking, no heap in the hot loop

**Explicit design invariant**, verbatim from the parser's header (`lib/std/zig/Parse.zig:1-14`):

> "*This recursive descent parser must be "predictive," using only constant token lookahead and
> never backtracking... Once the parser has made the choice, it must either succeed at parsing
> that sub expression or fail entirely... This ensures worst-case linear runtime rather than
> worst-case exponential runtime and requires the Zig grammar to be LL(k).*"

A hard constraint on the *grammar*, not just the implementation — Zig's syntax was kept simple
enough to parse without backtracking specifically to get this guarantee.

The tokenizer (`lib/std/zig/tokenizer.zig`) is a straight-line state machine driven by labeled
`continue :state` switch dispatch over raw bytes, with **no allocation** — tokens are
`{tag, start_offset}` pairs into the immutable source buffer (`Ast.zig:29-32`), so tokenizing
never touches the allocator. Keyword recognition uses a `comptime`-built `StaticStringMap`
(`tokenizer.zig:12-13`), so keyword-vs-identifier is resolved by a table built when the compiler
itself was built, not a runtime hash map.

**Error recovery** uses explicit resynchronization — `findNextContainerMember`/`findNextStmt`
(`Parse.zig:515-634`) skip forward to the next token that can legally start a declaration or
statement, so parsing continues and collects further diagnostics in the same pass.

**Measured tokenizer wins** (0.14.0 release notes): converting dispatch to labeled-switch gave a
**13% wall-time reduction** on `zig ast-check`; a later simplification gave a further **3.3%
wall-time / 4.0% instruction-count** reduction. Small percentages, but in the code that runs on
every byte of every file on every build.

**Transfer:** LL(k)-no-backtrack grammar design and allocation-free offset-based tokens are fully
portable. The "keep the grammar predictive" constraint is the one piece that must be decided when
you design the source language's syntax — it cannot be retrofitted.

## 10. Self-hosted incremental linking (avoiding LLD on the incremental path)

The self-hosted ELF/Mach-O/COFF/Wasm linkers use `MultiArrayList` for their internal tables
(`files: std.MultiArrayList(File.Entry)`, `sections: std.MultiArrayList(Section)` —
`Elf.zig:22-38`), and `src/link/Elf/ZigObject.zig` is documented as "*encapsulates the state of
the incrementally compiled Zig module*" — the linker keeps live, patchable in-memory state across
updates rather than re-linking from scratch. `src/link.zig:531-533`: "*Attempts incremental
linking, if the file already exists. If incremental linking fails, falls back to truncating the
file and rewriting it*"; and `:545`, "*LLD does not support incremental linking*" — precisely why
Zig maintains its own linker backends. The 228–288ms incremental self-relink numbers (§7) measure
this working end to end.

**Transfer:** not directly relevant when emitting JavaScript text, but the principle is: whatever
the final emission stage is (bundling, source-map stitching, minification), keep enough
persistent state to patch only the changed module's output rather than regenerating the whole
bundle. This is what esbuild's incremental mode and Vite's HMR do, and it deserves explicit
design attention rather than assuming "codegen is cheap, just redo it all."

---

## Top 10 highest-leverage techniques, ranked (for a JS-emitting compiler)

1. **Interning types/values/identifiers into a flat table with O(1) equality-by-index.** Biggest,
   most portable win; ~17% wall-time / ~18% cycles measured from refining this alone (PR #16105).
   Do it before anything else.
2. **Fine-grained incremental dependency graph (type vs. value vs. layout as separate nodes) with
   two-phase outdated/potentially-outdated marking.** Delivers the 14s→63ms (≈220×) headline.
   Highest ceiling, highest design cost — architect from day one.
3. **Struct-of-arrays for every IR** instead of arrays of boxed nodes. Cheap to adopt even
   mid-project.
4. **32-bit indices instead of pointers** for all intra-compiler links. Enables #1, #2 and #6 for
   free; halves memory for reference-heavy structures.
5. **A separate, cacheable, untyped per-file IR** (tokens→AST→"ZIR") independent from the
   type-checked IR. Skips re-parsing unchanged files across process invocations, not just within
   a watch session.
6. **Arena/bump allocation with bulk teardown** for phase-scoped data.
7. **LL(k), no-backtracking grammar + allocation-free, offset-based tokenizer.** Must be decided
   when designing the grammar.
8. **File-level parallel parsing/lowering feeding a bounded producer/consumer pipeline into
   per-unit parallel codegen.**
9. **Incremental/patchable final emission** keyed off the same dependency graph as #2. High payoff,
   but only after #2 is solid.
10. **Don't parallelize the type-checker core prematurely.** Zig's multi-year, still-incomplete
    effort and its initial regression from added synchronization (PR #20528) is a documented
    cautionary tale — #1–#4 alone deliver most of the measured wins.
