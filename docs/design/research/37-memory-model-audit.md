# The memory model as built, audited against the design and against Roc

**Status:** research, 2026-09-29. Not normative. It audits `master` at `5cfb130` against
[`fast-compiler.md`](../fast-compiler.md) §5, [`frontend.md`](../frontend.md) §3.4,
[`checker-v2.md`](../checker-v2.md) §4.1/§4.5/§18 and [`backend.md`](../backend.md), and compares
the result with Roc's Zig compiler as vendored in `references/roc` (`f083385b5b`).

**Question.** The owner's requirement, for speed: like Roc, a module's compilation should allocate
what it needs up front or in a few large arenas, and data structures should refer to each other by
`u32` indexes into flat struct-of-arrays storage, not by pointers. Per-node heap allocation,
pointer-linked trees and hash maps keyed by dense ids should not appear on hot paths. Does beni do
this? The owner suspects agents drifted from the design.

**Citation convention.** Bare paths are beni's (`src/…`, `docs/…`). `roc/…` is
`references/roc/…`. `std/…` is the Zig 0.16.0 toolchain's std (`zig env`'s `std_dir`), which is
what beni builds against. Every measurement is reproducible by §8.

---

## 0. Findings

1. **The representation half of the requirement is met.** Every IR — tokens, `Ast`, `Bir`, the
   checker's `TypeStore` and constraint tree, `Interface`, `JsIr` — is a `MultiArrayList` of small
   fixed records with `enum(u32)` indexes and one `extra: []u32` sidecar. No IR holds a pointer or a
   source slice. The only pointer-linked structures are allocator bookkeeping and checker working
   state (§5.3). Token (13 B, a documented departure from 5 B) and AST node (13 B) sizes are as
   `frontend.md` §3.2 and §3.5 state.

2. **The allocation half is met at the front and in the type store, and not elsewhere.** The
   front end pre-sizes every output column from the source size, as Roc does. The type store
   reserves three variables per instruction inside the worker's scratch arena. But **88 % of the
   723 k allocations a cold 100 k-line check makes are the checker's working state** (§3.2). That
   is lists rebuilt from empty per module, per frame and per compound expression, on the process
   allocator or as abandoned blocks in the bump arena.

3. **Allocation is not where the time goes in a cold build, and page faults are.** The allocator
   calls a 100 k-line check makes cost about **3 ms of CPU out of 130 ms** in a microbenchmark
   (§3.3). The process spends **20–30 ms in the kernel**, mostly on 9 100 minor faults.
   Replacing `smp_allocator` with a bump allocator that never frees made the build **slower**, not
   faster (§3.3). Reducing the pages the build touches pays; counting fewer `malloc` calls barely
   does.

4. **A warm run is dominated by decoding, not by I/O or checking.** A fully cached 100 k-line
   `check` takes 40 ms wall, of which 20 ms is system time. Front-end artifact decode is 13.0 ms and
   interface/entry decode 7.8 ms (§3.4). The on-disk formats are index-based and
   position-independent, as Roc's are. The loaders copy them element by element into fresh `gpa`
   memory anyway. Cached tokens are re-inflated from their 5-byte on-disk form to 13 bytes a token,
   times 1.5 for capacity, with two columns memset to zero.

5. **The drift the owner suspects is real, but it is in the working state, not the IR.** In
   impact order:
   - The checker's per-frame and per-module lists live on `gpa`. §4.1 and §4.5 name a scratch arena
     and an append-only `obl_links` table instead (§6.3 D1–D3).
   - Emit's scratch is `std.heap.ArenaAllocator`, which uses atomics, and is never reset. §5 rule 3
     forbids that allocator (D4).
   - `ensureTotalCapacity` over-reserves 1.5× on every pre-size call (D5).
   - There is no dense-id hash-map lint, although §5 rule 5 says to adopt Roc's (D6).
   - Hash maps are keyed by dense ids in 14 places (§5.1).

6. **Several departures from Roc are deliberate and documented**, and this report does not
   re-argue them:
   - `read` into a reused buffer instead of `mmap` per file, measured (`fast-compiler.md` §8.3
     correction).
   - Symbol-keyed maps in `Bir` lowering (`src/bir/Lower.zig:20-30`).
   - `Resolve.derived`'s hash map (`checker-v2.md` §18).
   - A host-independent little-endian cache format.

   One of these deserves a second look: Roc's `design.md` rejects the exact argument `Lower.zig`
   makes (§6.2).

**Verdict by phase** (details in §4):

| Phase | Representation | Allocation | Verdict |
|---|---|---|---|
| Lexer | SoA, 13 B/token | pre-sized `bytes/6+16`, 1.5× overshoot | complies |
| Parser / AST | SoA, 13 B/node | pre-sized `tokens·7/8+16`, scratch in arena | complies; the AST is kept for the build and never read |
| BIR lowering | SoA insts; side tables row-wise | 3 columns pre-sized, 10 not; per-construct arena lists | mostly complies; 8 `Symbol`-keyed maps (documented) |
| Resolve / graph / interfaces | dense, flat | serial; interfaces built on `gpa` | complies; lookups by string compare |
| Checker: `TypeStore` | SoA, hoisted columns, epoch marks | reserved `insts·3+64` in the scratch arena | complies, and is the best-built store in the tree |
| Checker: solve/constrain/evidence | constraint tree SoA; working lists row-wise | `gpa` lists regrown per frame and per module; scratch lists per node | **drifts** (D1–D3) |
| Exhaustiveness | SoA pattern store; matrices are slices of slices | per-`case` arena, reset | contained; top allocator by count |
| JsIr / Opt / Rename / Print | SoA, dense side arrays | `JsIr` not pre-sized; emit scratch is atomic, never reset | **drifts** (D4) |
| Cache / serialisation | index-based, position-independent | full decode and copy on load | loses the zero-copy benefit |
| Session / workers | — | per-worker `Arena`, `reset(.retain_capacity)` | complies |
| Formatter | 3 × u32 side arrays per node | scratch arena | complies |

---

## 1. What the design requires

- **`fast-compiler.md` §5, rules 1–5 (`docs/design/fast-compiler.md:528-546`):**
  1. no pointer inside any IR;
  2. no per-node allocation, one arena per phase;
  3. per-worker arenas, not a shared one, copying Roc's `SingleThreadArena` "to avoid
     `std.heap.ArenaAllocator`'s atomic RMW per allocation";
  4. offsets, never slices;
  5. no `HashMap` keyed by a dense id, where "Roc enforces this with a CI lint; adopt the same
     lint".
- **§8.3 (`:715-736`)** wanted an `mmap`, zero-copy load. It was corrected on 2026-09-19: `read`
  per entry beats `mmap` per entry at one-file-per-key granularity, and "§8.3's zero-copy load is
  not abandoned but **re-aimed at the pack file**".
- **`frontend.md` §3.4 (`docs/design/frontend.md:335-341`):** each worker owns an `Arena`. Each
  per-file phase allocates from it, and "the driver resets it between files only when the previous
  file's artifacts have been moved to session-owned storage". So durable per-file IR on the
  session allocator is the design, not a drift.
- **`checker-v2.md` §4.1 (`docs/design/checker-v2.md:218-225`):** epoch marks instead of memsets.
  `Walk.zig` owns "one reusable `std.ArrayList` stack per walk kind **on the module's scratch
  arena**".
- **`checker-v2.md` §4.1/§4.5 (`:184`, `:425-430`):** obligations ride on a variable as "a range
  into the append-only `obl_links`".
- **`checker-v2.md` §18 (`:4360-4395`):** the as-built measurements. Carving each module's store
  out of the worker's scratch arena took page faults from 18 036 to 9 323 and system time down by
  19 ms. An array-of-structs store was measured neutral.

## 2. Roc's evidence

Roc's Zig compiler is the model the owner names. Four properties matter.

**Flat, typed, index-addressed stores.**
- `ModuleEnv` holds a `CommonEnv`, a `TypeStore`, a `NodeStore` and about 25 typed side tables,
  each a `SafeList` (`roc/src/canonicalize/ModuleEnv.zig:890-1041`).
- `SafeList(T).Idx` and `SafeMultiList(T).Idx` are `enum(u32)`
  (`roc/src/collections/safe_list.zig:125`, `:530`), as is `types.Var`
  (`roc/src/types/types.zig:82`).
- The CIR node is a 12-byte `extern union` payload plus a tag, stored as a `SafeMultiList`
  (`roc/src/canonicalize/Node.zig:11-16`).
- Unlike beni's single `extra`, the CIR has about 20 *typed* side lists
  (`roc/src/canonicalize/NodeStore.zig:277-301`).

**Pre-sizing from source size.**
- Tokens: one per source byte, "TODO: tune this more. Syntax grab bag is 3:1"
  (`roc/src/parse/tokenize.zig:1316-1318`).
- Parser nodes: one per token (`roc/src/parse/Parser.zig:45-46`).
- CIR nodes: `clamp(source/20, 1024, 100 000)`, "Typical Roc code generates ~1 node per 20 bytes"
  (`roc/src/canonicalize/ModuleEnv.zig:1218-1223`).
- Type slots: `clamp(source/50, 2048, 50 000)` (`roc/src/types/store.zig:207-210`).

Roc over-reserves by more than beni does (§4.1): a token per byte is 6× beni's ratio.

**The same allocator split beni uses.**
- Each worker has a `gpa` for long-lived data ("ModuleEnv, source, ASTs, reports") and a scratch
  arena reset between tasks, retaining at most 64 MiB (`roc/src/compile/coordinator.zig:386-432`).
- `SingleThreadArena` has no atomics (`roc/src/collections/SingleThreadArena.zig:1-16`).
- **So Roc does not put a module's IR in an arena either**: its `ModuleEnv` lives on `gpa`. The
  requirement's "allocate up front" is met in Roc by capacity estimates, not by arenas.
- Unification allocates only into scratch lists cleared with `clearRetainingCapacity`
  (`roc/src/check/unify.zig:318`, `:4360-4365`).

**Relocatable, zero-copy caches.**
- `SafeList.Serialized` is `extern struct { offset: i64, len: u64, capacity: u64 }`
  (`roc/src/collections/safe_list.zig:168-171`).
- `deserializeInto(base)` points the list into the cache buffer: "points into the cache buffer
  and CANNOT be grown" (`:248-265`).
- `ModuleEnv.Serialized` mirrors the runtime struct field for field
  (`roc/src/canonicalize/ModuleEnv.zig:3969-3975`).
- The cache is mapped copy-on-write where the platform allows, or read to the heap otherwise
  (`roc/src/compile/cache_module.zig:265-298`).
- Only the type store is copied, because checking mutates it
  (`roc/src/canonicalize/ModuleEnv.zig:4309-4310`).

**The dense-id rule is a lint, and the design document argues it.**
- Lint 5 rejects any `HashMap(` whose key type ends in `Id` (`roc/ci/zig_lints.zig:150-180`).
- `DenseMap` is the replacement (`roc/src/collections/DenseMap.zig:1-10`).
- `roc/design.md:117-145` states the rule and its reasoning. Two passages bear on beni:
  - "A short-lived scope over a larger ID domain uses a paged, reusable, epoch-based, or
    explicitly remapped dense column so that clearing and iteration remain proportional to the
    live scope… **The size of the owning ID domain is not a reason to hash an ID**" (`:130-136`).
  - "Known batch sizes reserve capacity once… serialization writes only live rows, never spare
    capacity" (`:141-145`).

Primary sources for why:
- Brendan Hansknecht's "Allocate with gpa for growing things and arenas for everything else.
  Everything should use indices not pointers… can just mmap and then get slices"
  ([Zulip, 2025-02-16](https://roc.zulipchat.com/#narrow/channel/395097-compiler-development/topic/zig.20compiler.20-.20IR.20serde/near/500056843)).
- His three-allocator proposal, gpa / arena / per-stage scratch
  ([Zulip, 2025-10-12](https://roc.zulipchat.com/#narrow/channel/395097-compiler-development/topic/allocators/near/544368346)).
- Richard Feldman on relocation by base-address subtraction
  ([Zulip, 2025-10-26](https://roc.zulipchat.com/#narrow/channel/395097-compiler-development/topic/roc.20build/near/547152240)).

## 3. Measurements

Machine 2 (AMD Ryzen 9 5950X, 32 threads, Linux 6.12.110, Zig 0.16.0, ReleaseFast, load about 2).
Timed runs were pinned with `taskset -c 7`, best of 7. The corpus is
`zig build bench -- --generate=100000`: 624 files, 100 159 lines, 1 835 956 bytes, 302 615
tokens, 221 576 nodes, 202 303 instructions. "One file" is a four-line `Main.beni`, which also
loads and checks `core` cold. Counts come from a measurement-only build (§8); the timings from an
unmodified `master` binary.

### 3.1 Whole process

| Run | wall | user / sys | minor faults | peak RSS |
|---|---:|---:|---:|---:|
| `check --no-cache --jobs=1`, 100 k | 129.5 ms | ~100 / 20–30 ms | 9 131 | 45 MB |
| `check --no-cache`, 100 k, 32 threads | 39.1 ms | — | 13 430 | 51 MB |
| `build --library --no-cache --jobs=1`, 100 k | 169.5 ms | ~125 / 30 ms | 12 377 | 52 MB |
| `build --library --no-cache`, 32 threads | 77.6 ms | — | — | — |
| `check --jobs=1`, 100 k, **all cached** | 40 ms | 15 / 20 ms | 7 309 | 31.5 MB |
| `check --no-cache --jobs=1`, one file (+ core) | < 10 ms | — | 900 | 6.5 MB |
| `fmt --check --jobs=1`, 100 k (front end only) | 50 ms | — | 6 054 | 24.6 MB |

`strace -c` shows only 855 `mmap` and 859 `munmap` calls on the cold 100 k check, costing a few
ms. What costs time is the 9 100 faults, about 37 MB of pages touched: the front end accounts for
about 6 000 of them and the checker for 4 700.

### 3.2 Allocation counts

The measurement build wraps `init.gpa` (`smp_allocator` in ReleaseFast, `std/start.zig:689-711`)
and counts inside `src/Arena.zig`.

| Run | `gpa` allocs | bytes requested | failed remaps (a growth copy) | peak live `gpa` | `Arena.zig` allocs | chunk opens |
|---|---:|---:|---:|---:|---:|---:|
| cold check, 100 k, jobs=1 | 141 180 | 72 MB | 29 414 | 28.1 MB | 580 009 | 642 |
| cold build, 100 k, jobs=1 | 161 712 | 127 MB | 38 757 | 43.0 MB | 580 120 | 643 |
| warm check, 100 k, jobs=1 | 37 682 | 24 MB | 6 720 | 22.1 MB | 13 327 | 1 |
| cold check, one file + core | 2 495 | 1.6 MB | 542 | 0.9 MB | 14 850 | 19 |

**Rates.** Per module that is 222 `gpa` plus 913 arena allocations, or 1.4 plus 5.8 per source
line. About one in five `gpa` allocations is a growth copy of a list. Emit's
`std.heap.ArenaAllocator` traffic is not in the table: only its chunk requests reach `gpa`.

**By phase**, from a Debug build that records a stack per allocation (jobs=1, cold check):

| Phase | `Arena.zig` allocs | `gpa` allocs | Share of all |
|---|---:|---:|---:|
| `src/check/` | 534 159 | 102 523 | **88 %** |
| `src/bir/` | 17 161 | 17 750 | 4.8 % |
| `src/resolve/` | 6 223 | 13 943 | 2.8 % |
| `src/cache/` | 5 063 | 893 | 0.8 % |
| `src/lex/`, `src/parse/`, `SourceStore`, `fs_read` | 1 489 | ~7 000 | ~1.2 % |

**Top sites**, with the stack's first beni frame:

Arena:
- `check/InterfaceTerms.zig:249` `readRange`, 24 225
- `check/Solve.zig:597` and `:636` `call`, 20 713 each
- `check/constrain/Expr.zig:368` and `:387` `call`, 19 710 each
- `check/Types.zig:1363` `apply`, 16 723
- `check/Exhaustive.zig:446` `one`, 14 724
- `check/Exhaustive.zig:729` `admit`, 13 629
- `check/Walk.zig:734` `recordRow`, 12 584
- `check/Generalize.zig:356` `adjustRanks`, 10 941

`gpa`:
- `check/constrain/Tree.zig:380` `binderOf`, 10 941
- `check/constrain/Tree.zig:358` `adoptSince`, 8 285
- `check/constrain/Decl.zig:180` `rigidReading`, 8 285
- `check/Groups.zig:357` `solveGroup`, 8 252
- `check/constrain/Tree.zig:322` `freshFlex`, 3 654
- `check/Resolve.zig:151` `create`, 2 927
- `bir/Lower.zig:789` `newDecl`, 2 689
- `check/Generalize.zig:190` `pushFrame`, 2 366

**By file:** `check/Exhaustive.zig` makes the most allocations of any file (84 926), then
`constrain/Expr.zig` (63 080) and `Types.zig` (47 784).

### 3.3 What allocation costs

A microbenchmark (`std.heap.smp_allocator` and a copy of `src/Arena.zig`, ReleaseFast, pinned)
replays the measured counts:

| Operation | Time |
|---|---:|
| 141 180 alloc+free pairs, sizes 8–1 000 B | 1.06–1.26 ms |
| 3 000 lists grown by `append` to 300 `u32` (≈ 30 k regrowths) | 0.42 ms |
| 580 009 bump allocations, reset every 1 000 | 1.25 ms |

That is about **3 ms of the 130 ms check**, roughly 2 %. Cache misses in the real program would
raise it, but not by an order of magnitude.

**Counterfactual.** With `BENI_GPA_BUMP`, `gpa` becomes a `std.heap.ArenaAllocator` that never
frees.

| Run | `smp_allocator` | never-free bump |
|---|---:|---:|
| check, jobs=1 | 133.1 ms | 142.1 ms |
| check, 32 threads | 38 ms | 68 ms |
| build, jobs=1 | 169.5 ms | 196.5 ms |

The never-free allocator lost every time. Its atomic RMW per allocation (the reason §5 rule 3
exists) and pages that are never reused cost more than `smp_allocator`'s free lists.

**The kernel's share is larger.** System time is 20–30 ms of the cold check (15–20 %) and half of
the warm one. `checker-v2.md` §18 already found that page faults, not user cycles, were the
store's hidden cost.

### 3.4 Where the memory is, and where the warm run goes

**Peak composition** (cold check, live `gpa` bytes by site at the high-water mark, 28.1 MB):
- `lex/Tokenizer.zig:186` holds 6.76 MB: the token columns.
- `parse/Parse.zig:203/204/217` hold 6.86 MB: nodes, extra and errors.
- `bir/Lower.zig:363` onward holds 8.27 MB.
- Source text holds 1.84 MB.
- **The front end's durable IR is 22 of the 28 MB.**

**Unused capacity** within that 22 MB:
- 302 615 tokens × 13 B is 3.93 MB, of 6.76 MB held.
- 221 576 nodes × 13 B is 2.88 MB, of about 5.6 MB.
- 202 303 instructions × 13 B is 2.63 MB, of 4.76 MB.
- **About 7.7 MB, 27 % of peak, is capacity that is never used.**

The cause is Zig 0.16's `ensureTotalCapacity`, which allocates `n + n/2 + init`, not `n`
(`std/multi_array_list.zig:514-528`, `std/array_list.zig:1412-1416`). The same pattern appears on
every pre-sizing call (§6.3 D5).

Untouched tail pages of large mappings do not fault, so this costs virtual memory more than time.
It matters for the daemon's resident set.

**Dead weight kept for the build**, according to `frontend.md` §3.2 and §3.5:
- Tokens' `line` and `payload` columns: 8 of 13 B, dead after lowering.
- The whole `Ast`: nothing on `check` or `build` reads it after `lower`, yet `Session.zig:903`
  keeps it.

**Warm run** (`--self-profile`, jobs=1, every file and module a hit):

| Event | Total |
|---|---:|
| `frontend_load` | 19.1 ms |
|   of which `frontend_decode` | 13.0 ms |
|   of which `frontend_read` | 3.9 ms |
|   of which `frontend_intern` | 1.6 ms |
| `cache_load` (interfaces, dispatch, entries) | 7.8 ms |
| `read` (sources, for the file key) | 5.9 ms |
| `resolve` | 5.0 ms |

The warm peak is 22 MB of `gpa`. Two decode sites dominate it:
- `frontend/artifact_bytes.zig:691`: tokens, 6.3 MB.
- `artifact_bytes.zig:639`: `Bir` instructions, 4.2 MB.

### 3.5 Parallel shape

At 32 threads, `check` takes 39 ms and `build --library` 78 ms. The single `emit` event is 34.9 ms,
because emit is serial end to end (`src/js/Emit.zig:1311-1370`). This is not a memory-layout
finding. It matters here because emit's allocator (D4) and its writes to the global interner
(`src/js/Lower.zig`, twelve `interner.getOrPut` calls) are what would stop it fanning out.

---

## 4. Phase by phase

### 4.1 Lexer (`src/lex/`)

**Representation.**
- `Token = {tag u8, start, line, payload u32}` in a `MultiArrayList`, 13 B in four columns
  (`src/lex/Token.zig:17-32`). This is `frontend.md` §3.2's documented departure from 5 B.
- `Comment` is row-wise in a plain `ArrayList`, 12 B (`src/lex/Tokenizer.zig:148`). Minor.

**Allocation.**
- Output lists are pre-sized on `gpa`: tokens `bytes/6 + 16`, lines `/24`, comments `/128`
  (`src/lex/Tokenizer.zig:169-188`).
- The estimate is measured and sits almost exactly on the corpus mean of 6.07 bytes per token. So
  the 1.5× of `ensureTotalCapacity` is what prevents regrowth, not the estimate.
- Interning is streamed while scanning (`:958-960`). No per-token allocation.

**Lifetime.**
- All four columns are kept for the build (`src/Session.zig:862-870`), although two are dead after
  lowering.
- `line_starts` and `comments` pass through `toOwnedSlice` (`:838`, `:856`), which may shrink by
  copying.

**Verdict:** complies.

### 4.2 Parser and `Ast` (`src/parse/`)

**Representation.** `Node = {tag, main_token, data{lhs, rhs}}`, 13 B, with a size assert
(`src/parse/Ast.zig:96-143`), and an `extra` sidecar. No pointers or source slices.

**Allocation.**
- Nodes and extra are pre-sized to `tokens·7/8 + 16` on `gpa` (`src/parse/Parse.zig:160-167`,
  `:203-204`).
- The stacks live in the worker arena (`:175`, `:201-202`).
- `extra` and `errors` pass through `toOwnedSlice` (`:217-219`).

**Lifetime.** The tree is kept for the build (`src/Session.zig:903`), against §3.5's statement that
nothing on `check` or `build` reads it.

**Verdict:** complies.

### 4.3 BIR lowering (`src/bir/`)

**Representation.**
- `Inst` is 13 B SoA with `extra`, `string_bytes` and a `symbols` column (`src/bir/Bir.zig:53-60`,
  `:93-141`).
- The side tables `decls`, `ctors`, `locals`, `refs`, `imports`, `exposed` and `interface` are
  plain row-wise slices (`:62-85`). Their rows hold only `u32` indexes. `Decl` is 92 B a row
  (`:601-627`).

**Allocation.**
- `insts`, `extra` and `symbols` are pre-sized from the node count (`src/bir/Lower.zig:294-300`,
  `:363-365`).
- The ten other output lists start empty (`:92-101`) and pass through eleven `toOwnedSlice` calls
  (`:390-400`).
- Per-construct lists live in the arena:
  - one per pipe or `saturate` (`:2224`)
  - one per `<-` bind (`:2750`, `:2758`)
  - one per `let` block (`:2478`, `:2641-2668`)
  - `dupe` plus `allocPrint` per schema declaration (`:828-846`)
- `FieldNames` grows a `U32Set` on `gpa`, not scratch (`:1869-1894`).

**Hash maps.** Eight `Symbol.Map`s (`:105-148`), keyed by a dense id and justified as sparse per
file (`:20-30`); see §6.2. Two composite-key maps are legitimate (`:122`, `:1145`).

**Done right.** `decl_stamp` and `ctor_stamp` are dense stamp arrays (`:781-783`).

**Verdict:** mostly complies.

### 4.4 Graph, resolve and interfaces (`src/resolve/`)

**Representation.**
- `Graph` is a `MultiArrayList(Module)`. It resolves module names through `name_rows`, a dense array
  indexed by `Symbol` (`src/resolve/Graph.zig:87-107`, `:300-305`, `:427`). There is no map. This is
  the model the rest of the tree should copy.
- `Interface` is flat, index-based slices with `terms` as a `MultiArrayList` (`src/resolve/Interface.zig:55-65`).

**Lookups.**
- `findValue`, `findType` and `findSchema` binary-search by comparing strings through the interner
  (`:946-958`).
- `findCtor` is a linear scan (`:886-891`).

**Allocation.** Resolve runs serially on worker 0's arena (`src/resolve/Resolve.zig:145-148`,
`src/Session.zig:1340`), although §10 lists interface extraction as parallel work.

**Verdict:** complies. The lookups and the serial schedule are cheap today: `resolve` is 4.75 ms.

### 4.5 Checker (`src/check/`)

**`TypeStore`: complies, and is the best-built structure in the tree.**
- `MultiArrayList(Descriptor)` with columns hoisted into plain slices (`src/check/TypeStore.zig:270-296`).
- Epoch marks instead of memsets.
- `reserve(insts·3+64, insts·2+64)` (`src/check/Module.zig:115`).
- The store's own `Arena` is carved from the worker's scratch arena
  (`src/check/Module.zig:107-110`), so a module's store neither maps nor unmaps pages.
- `constraints`, `constraint_sets` and `acyclic` are not reserved (`src/check/TypeStore.zig:315`,
  `:343-350`). They share one bump arena, so only the most recently grown list grows in place.

**The constraint tree is SoA** (`src/check/constrain/Tree.zig:167-170`). But `binders`,
`frame_binders` and its other lists grow on `gpa` from empty in every module:
- `binderOf` at `:378-380`: 10 941 allocations.
- `adoptSince` at `:358`: 8 285.

**Working state: drifts.**
- Every `Generalize.Frame` owns a `pool` and a `tries` list on `gpa` (`src/check/Generalize.zig:91`,
  `:95`), pushed empty (`:202-209`) and freed at pop (`:253`).
  - Groups append the pool again at `src/check/Groups.zig:357`: 8 252 allocations.
  - `Inherited` is `gpa.create`d per merge (`src/check/Groups.zig:548`).
  - Elm and Roc reuse per-rank pools.
- `Walk.Stacks` is freed with `gpa` (`src/check/Solve.zig:194`). §4.1 says these stacks live on
  the scratch arena.
- `Obligations` keeps two nested `ArrayList`s per set on `gpa` (`src/check/Obligations.zig:137-152`,
  `:176-184`). §4.5 specifies a range into an append-only `obl_links`.
- Constraint generation makes a fresh `parts` or `args` list per compound node on scratch
  (`src/check/constrain/Expr.zig:368`, `:387`; `Decl.zig:155`, `:227`; `Pattern.zig:121`). The
  children are generated between appends, so each growth abandons a block.
  `Schemes.Writer` already uses the shared-stack-and-base-index pattern
  (`src/check/Schemes.zig:617-619`).
- Record unification builds up to seven scratch lists per call (`src/check/Unify.zig:994-1117`).
- `Solve.call` dupes arguments and parameters per call node (`src/check/Solve.zig:597`, `:636`).

**Hash maps keyed by dense ids:** see §5.1.

### 4.6 Exhaustiveness (`src/check/Exhaustive.zig`, `PatternStore.zig`)

- Patterns are a `MultiArrayList` on a per-`case` arena (`src/check/PatternStore.zig:102`), reset
  per `case` (`src/check/Exhaustive.zig:277-302`).
- Matrices are `[]const []const PatIndex` (`:415`), and `isUseful` recurses (`:1120-1160`).
- This file makes 84 926 arena allocations, more than any other. They are cheap bumps into
  memory the arena reuses.

**Verdict:** contained.

### 4.7 Backend (`src/js/`)

**Representation.** `JsIr` is SoA with `extra`, `string_bytes` and a `names` column
(`src/js/JsIr.zig:47-59`). The side tables are dense, as they should be:
- `Opt` arrays (`src/js/Opt.zig:121-126`)
- `Reach` bitsets and CSR arrays (`src/js/Reach.zig:115-117`, `:300-413`)
- `Rename` stamp arrays (`src/js/Rename.zig:205-218`)

**Violation.** `Lower.IndexMap` is a hash map keyed by a node or term index
(`src/js/Lower.zig:385-392`), used for `bound` (`:492`, `:2632`, `:2669`).

**Allocation.**
- The `JsIr.Builder` is created fresh on `gpa` per module (`src/js/Lower.zig:177`). It is not
  pre-sized from `bir.insts.len`, and grows one part at a time (`src/js/JsIr.zig:984`).
- Print's joiner also grows one at a time (`src/js/Print.zig:181`).
- **Emit scratch is `std.heap.ArenaAllocator`** (`src/build/Command.zig:80`) and is never reset
  between modules. `Print` makes another per module (`src/js/Print.zig:95`).

**Lifetime.** `JsIr` is freed per module (`src/js/Emit.zig:1339`). That is correct, but every
module re-warms from zero.

### 4.8 Cache and serialisation (`src/cache/`, `src/frontend/artifact_bytes.zig`, `src/resolve/iface_bytes.zig`)

**Formats.** Every format is a section table of offset and length pairs over little-endian,
4-byte-aligned columns, with no pointers:
- `src/frontend/artifact_bytes.zig:13-21`, `:80-103`
- `src/resolve/iface_bytes.zig:78-120`

They are position-independent in Roc's sense.

**Loaders.** The loaders are full decodes:
- Instruction `lhs` and `rhs` are read one `readInt` at a time
  (`src/frontend/artifact_bytes.zig:646-652`).
- Row tables are decoded field by field through reflection (`:756-762`).
- `extra`, `string_bytes` and `line_starts` are duplicated (`:657-658`, `:709`).
- Tokens are `resize`d to four columns and two are memset to zero (`:691-705`). That undoes
  §3.2's 5-byte cached form.
- Interface terms go through one `MultiArrayList.set` per element
  (`src/resolve/iface_bytes.zig:558-567`).
- `Dir.load` allocates a fresh buffer per entry and hands it over (`src/cache/Dir.zig:238-247`).
  Front-end artifacts, by contrast, reuse a per-worker buffer (`:263-289`).

**Documented reasons:**
- Symbols travel as text and must be re-interned (`src/frontend/artifact_bytes.zig:47-55`).
- `read` beats `mmap` at this granularity (`:42-46`; `fast-compiler.md` §8.3).

Neither reason requires the numeric columns to be copied. §3.4 prices the copy at about 13 ms of a
40 ms warm run.

### 4.9 Session, driver and workers

- Each worker owns an `Arena` over `page_allocator` and a `Local` interner (`src/Session.zig:464`),
  reset with `.retain_capacity` per file (`:794`).
- The checker's workers own a scratch arena and a `patterns` arena, reset per module
  (`src/check/Driver.zig:338-374`).
- Threads are spawned per phase (`src/Session.zig:555-566`, `src/check/Driver.zig:122-131`).
- `Profile` preallocates per-thread event buffers (`src/Profile.zig:260-265`).

**Verdict:** complies. Persistent threads are the daemon's to add.

### 4.10 Formatter (`src/fmt/Format.zig`)

- Three `u32` side arrays per node come from scratch (`src/fmt/Format.zig:157-160`). §3.7 names
  one.
- Its stacks are scratch lists (`:302`, `:868`).
- There is no per-node allocation.

**Verdict:** complies.

---

## 5. Inventory

### 5.1 Hash maps keyed by a dense id

These break `fast-compiler.md` §5 rule 5 on its face. The inventory was found with a `grep` for
`HashMap`, `ArrayHashMap`, `Symbol.Map`, `int_hash.Map` and `IndexMap` over `src/`, excluding
tests. The table marks each map as justified (**J**), sparse by nature (**S**), or plain drift
(**D**).

| Site | Key | Path | Class |
|---|---|---|---|
| `src/bir/Lower.zig:105-148`: `values`, `ctor_names`, `types`, `schemas`, `import_by_alias`, `import_by_module`, `scope_index`, `type_param_index` | `Symbol` | every name lookup in lowering | **J** (`:20-30`); see §6.2 |
| `src/InternPool.zig:53-65` `Symbol.Map` | `Symbol` | the type the above use | J |
| `src/js/Lower.zig:385-392` `IndexMap` (`bound`) | term / node index | per call in derived bodies | **D** |
| `src/check/Resolve.zig:86` `derived` | `MemoKey{Var,…}` | per wanted | J (checker-v2 §18 measured a column) |
| `src/check/Resolve.zig:675`, `:838-840`, `:857`, `:936-939` | `Var` | per group close / `let` close | **D**: §4.1's epoch marks apply |
| `src/check/Evidence.zig:239` `given_ranges` | declaration index | per `where` declaration | **D**: a `decls.len` column |
| `src/check/Evidence.zig:244` `rejected` | `Var` → `ArrayList` | error path | S |
| `src/check/Schema.zig:394-426` | `Var` → `Var` | schema endpoints, cold | D: the descriptor's `copy` memo applies |
| `src/check/Publish.zig` `seen` | `TypeId` | per module, cold | S |
| `src/check/Schemes.zig:74` `ref_index` via `int_hash.Map` | `TypeId` | per interface write | J (in place) |
| `src/check/Elaborate.zig:161` `own` | `OwnKey{TypeId,kind}` | per module | S |
| `src/check/Render.zig:69`, `:204`; `Producers.zig:137` | `Var`, `u32` | error path | S |
| `src/frontend/artifact_bytes.zig:218-224` | `Symbol` | write path only | S |
| `src/u32_set.zig:13-78` | symbol / term | past 16 fields | S |

`src/check/int_hash.zig` exists to make hashing a dense id cheap. It works against the rule rather
than enforcing it.

**Beni has no lint.** `build.zig` has no step like Roc's `run-check-zig-lints`
(`roc/build.zig:2922`), although §5 rule 5 says "adopt the same lint".

### 5.2 Per-node or per-construct allocation

Every entry here is scratch or arena memory, and none is a heap object per IR node:
- BIR lowering: `src/bir/Lower.zig:2224`, `:2478`, `:2641-2668`, `:2750-2758`, `:828-846`
- constraint generation: `Expr.zig`, `Decl.zig`, `Pattern.zig`
- `Solve.call`: `src/check/Solve.zig:597`, `:636`, `:674`
- record unification: `src/check/Unify.zig:994-1117`
- `Instances`: `src/check/Instances.zig:329-1147`
- `InterfaceTerms.readRange`: `src/check/InterfaceTerms.zig:160-195`, `:249`

The one true `create` per construct is `Generalize.Frame.Inherited` (`src/check/Groups.zig:548`).
There are no per-node `allocator.create` calls anywhere in an IR builder.

### 5.3 Pointer-linked structures

- `Arena.Chunk.prev` (`src/Arena.zig:44`): allocator bookkeeping. Roc's arena is the same.
- `Groups.trees: ArrayList(*Tree)` (`src/check/Groups.zig:118`, `:235`), `Frame.inherited:
  ?*Inherited`, and `Types.Builder.Expansion.outer`: checker working state, never published.
- `Exhaustive`'s matrix rows (`src/check/Exhaustive.zig:415`): slices of slices inside a
  per-`case` arena.

No IR, interface, cache record or `JsIr` holds a pointer.

---

## 6. Beni against Roc

### 6.1 Where beni matches Roc

- **SoA and `u32` indexes everywhere that is published.** Beni goes further than Roc in one
  respect: a single `extra` per IR instead of Roc's twenty typed side lists.
- **Source-size pre-sizing of the front end,** with tighter measured ratios than Roc's. Roc
  estimates a token per byte, where beni measures 1/6.
- **The allocator split:**
  - `gpa` for durable per-module data (Roc: `roc/src/compile/coordinator.zig:394-432`; beni:
    `src/Session.zig:833`, `:884`, `:943`)
  - a single-thread scratch arena per worker, reset with retained capacity
  - no `std.heap.ArenaAllocator` in the front end or the checker

  The requirement's "one arena per module" is therefore not what Roc does. Roc allocates up front
  by estimate, into `gpa`, and beni copies that faithfully.
- **Epoch marks and dense side columns in the checker's hot structures:** `TypeStore`,
  `Schemes.Writer`'s memo, `Derivable.GroundMemo` and `Digest.IdSet`. Roc does the same
  (`roc/design.md:162-165`).
- **An index-based, position-independent cache format.**

### 6.2 Where beni deliberately differs, and says why

| Departure | Where it is argued | Holds up? |
|---|---|---|
| `read` into a reused buffer, not `mmap` per file | `fast-compiler.md` §8.3 correction; `src/frontend/artifact_bytes.zig:42-46`; 4.5–5.0 ms `mmap` vs 1.9–2.3 ms `read` over 633 files | Yes for the syscall. But the *decode-and-copy* after `read` is a separate cost (13 ms) that neither the correction nor Roc pays |
| Little-endian, host-independent format | same | Yes. Its cost is the per-element `readInt`, which on little-endian hosts can be one `@memcpy` per column |
| Symbols as text, re-interned per load | `artifact_bytes.zig:47-55`; `fast-compiler.md` §5.1 correction | Yes. Session-wide `Symbol` ids move with every edit. Roc avoids this by keeping identifiers per module env (`roc/src/base/CommonEnv.zig:22-33`) |
| `Symbol`-keyed maps in lowering | `src/bir/Lower.zig:20-30`: a per-file array "would cost a memset proportional to the worker's whole interner per file" | **Weak.** The memset argument is answered by a per-worker, symbol-indexed array with generation stamps, the pattern `decl_stamp` already uses at `:781-783` and `Graph.name_rows` uses at `src/resolve/Graph.zig:300-305`. Roc's design rejects the argument verbatim: "the size of the owning ID domain is not a reason to hash an ID" (`roc/design.md:134`) |
| `Resolve.derived` hash map | `checker-v2.md` §18 | Yes, measured |
| Array-of-structs working tables (`Evidence.wanteds`, `Obligations.rows`, `Types.entries`) | `checker-v2.md` §18 measured an AoS store as neutral | Plausible at their size |
| 13-byte tokens in memory | `frontend.md` §3.2 | Yes. But the loader re-inflates the 5-byte cached form (D7) |

### 6.3 Where agents drifted

These contradict a design statement, or pay a cost the design says to avoid, and no document
records a decision to do so.

- **D1. The solver's working lists live on `gpa` and are regrown per frame and per module.**
  - Sites: `src/check/Generalize.zig:91`, `:95`, `:202`, `:253`; `src/check/Solve.zig:96-141`,
    `:222`; `src/check/constrain/Tree.zig:322`, `:358`, `:380`; `src/check/Groups.zig:357`;
    `src/check/Decide.zig:103-104`.
  - Contradicts `checker-v2.md` §4.1: "on the module's scratch arena".
  - 102 523 `gpa` allocations are the checker's, most of them growth copies of lists that were
    empty at the start of the module or frame.
- **D2. Obligation sets are nested per-set lists** (`src/check/Obligations.zig:137-152`), not
  §4.1/§4.5's range into an append-only `obl_links`. Every `==`, `.0`, interpolation and `?` pays
  one or two `gpa` allocations.
- **D3. Per-construct scratch lists in constraint generation and unification** (§5.2), where
  `Schemes.Writer` shows the shared-stack pattern the design's "no per-node allocation" implies.
  In the arena this abandons blocks and raises the module's peak.
- **D4. Emit uses `std.heap.ArenaAllocator` and never resets it** (`src/build/Command.zig:80`,
  `src/js/Print.zig:95`). §5 rule 3 names that allocator as the one not to use. Every module's
  Lower, Opt, Rename and Decision scratch accumulates for the whole emit.
- **D5. `ensureTotalCapacity` where `ensureTotalCapacityPrecise` was meant.**
  - Sites: `src/lex/Tokenizer.zig:186-188`, `src/parse/Parse.zig:203-204`,
    `src/bir/Lower.zig:363-365`, `src/check/TypeStore.zig:347-349`.
  - The comments say "rounded up so a typical file never regrows", which is the estimate's job. The
    std then adds 50 % on top (`std/multi_array_list.zig:514-528`).
  - `checker-v2.md` §18 noticed this for the store ("a capacity of 4.5 after `MultiArrayList`'s
    growth factor"), but it was not fixed at the source. It costs 7.7 MB of the 28 MB peak.
- **D6. No lint for rule 5**, which §5 says to adopt. Without it, three dense-key maps arrived after
  the rewrite (§5.1, class D).
- **D7. The cache loaders copy what the format was designed not to copy.** This covers the
  per-element decode, the tokens re-inflated from 5 to 13 B with two columns memset
  (`src/frontend/artifact_bytes.zig:691-705`), and a fresh buffer per entry (`src/cache/Dir.zig:238-247`).
- **D8. The `Ast` and the dead token columns are kept for the build** (`src/Session.zig:903`),
  where `frontend.md` §3.2/§3.5 say nothing reads them after lowering. Together they are about
  5.3 MB used plus about 3 MB of capacity at 100 k lines. This matters for the daemon, which keeps
  them for its lifetime.

---

## 7. Recommendations, ranked by expected gain over effort

Each carries the measurement it rests on. "Gain" is on the 100 k-line corpus, jobs=1, unless it
says otherwise.

1. **Make the warm load zero-copy for numeric columns** (D7). Medium effort.
   - Keep the `read` into a reused buffer, which is §8.3's decision.
   - For `Bir.insts`, `extra`, `symbols`, `line_starts` and the token `tag` and `start` columns,
     point slices into a per-file buffer the session keeps, as Roc's `deserializeInto` does, or
     copy one column at a time with `@memcpy`.
   - Stop re-inflating tokens: carry a 2-column token view after lowering.
   - Remap `symbols` in place.
   - *Evidence:* `frontend_decode` is 13.0 ms and `cache_load` 7.8 ms of a 40 ms warm run (§3.4),
     and the decoded copies are 22 MB of `gpa` and most of the 7 300 faults.
   - *Expected:* 10–15 ms off the warm run, about a third.
   - This is also the shape the daemon's cold start (§2: < 120 ms) and the pack file want.
2. **Replace `ensureTotalCapacity(estimate)` with `ensureTotalCapacityPrecise(estimate)`** in the
   four pre-sizing sites (D5), and **pre-size `JsIr.Builder` from `bir.insts.len`**. Trivial
   effort.
   - *Evidence:* 7.7 MB of 28 MB peak is capacity that is never used (§3.4).
   - *Expected:* a smaller resident set rather than wall time, since untouched pages do not fault.
     Measure faults and RSS before and after. It is what makes the daemon's footprint honest.
3. **Move the solver's per-frame and per-module lists to reused storage** (D1, D2).
   - Keep `Solve`, `Tree` and `Groups` lists alive across modules on the worker, cleared with
     `clearRetainingCapacity`, as Roc's unifier scratch is (`roc/src/check/unify.zig:4360-4365`).
   - Give `Generalize` per-rank pools reused across frames, as Elm and Roc do.
   - Implement `obl_links` as §4.5 specifies.
   - Medium effort; the spec already exists.
   - *Evidence:* about 100 k `gpa` allocations and 29 k growth copies are the checker's (§3.2).
   - *Expected:* modest, 2–5 ms of 130. The CPU cost of those allocations is bounded by §3.3's
     microbenchmark. The larger win is fewer pages touched per module.
4. **Give emit an `Arena.zig` scratch, reset per module, and reuse the builder and Print buffers
   across modules** (D4). Small effort.
   - *Evidence:* §5 rule 3. The never-free counterfactual in §3.3 shows what atomic, never-reset
     allocation costs: 38 → 68 ms when parallel, 133 → 142 ms serial.
   - It is also a precondition for parallel emit, which at 32 threads is 35 ms of a 78 ms build
     (§3.5). The interner writes in `src/js/Lower.zig` are the other precondition.
5. **Add the rule-5 lint, and fix the three drift-class maps** (D6). Small effort.
   - The maps are `src/js/Lower.zig:385-392`, `src/check/Evidence.zig:239` and the `Var` sets in
     `src/check/Resolve.zig:675-939`.
   - Port `roc/ci/zig_lints.zig:150-180`'s rule: a `HashMap` whose key type is a dense-id enum
     (`Var`, `Symbol`, `*Index`, `TypeId`, `DeclIndex`) fails unless the declaration carries a
     comment citing its justification.
   - *Gain:* small in time. The value is stopping the drift the owner suspects.
6. **Replace `Lower`'s eight `Symbol.Map`s with a per-worker, symbol-indexed, generation-stamped
   column** (§6.2). Small-to-medium effort.
   - *Evidence:* `lower` is 16.7 ms of the cold jobs=1 profile, and name lookup is its most
     frequent operation. `Graph.name_rows` shows the pattern works here.
   - Roc's design rejects the memset argument.
   - Measure `lower` before and after; expect single-digit percent of `lower`.
7. **Drop the `Ast` and the token `line`/`payload` columns after lowering on `check` and `build`**
   (D8). Small effort.
   - *Evidence:* about 8 MB of the cold peak (§3.4).
   - *Gain:* resident set, mainly for the daemon.
8. **Constraint generation's per-node lists become one shared stack with base indexes** (D3), as
   `Schemes.Writer` does. Medium effort.
   - *Evidence:* `constrain/Expr.zig`, `Decl.zig` and `Pattern.zig` make 113 k arena allocations
     (§3.2), and `constrain` is 13.9 ms.
   - *Expected:* small.

**Not recommended:**
- Replacing `smp_allocator` with an arena for durable data. §3.3 measured it slower.
- `mmap` per cache file. §8.3 measured it slower.
- Putting whole modules in one arena. Roc does not either, and beni's durable data already lives
  where Roc's does.

---

## 8. Method, and how to reproduce

- **Measurement build.** A detached worktree of `5cfb130` in a scratch directory, deleted after,
  held the only code change.
  - `src/alloc_count.zig` wraps `init.gpa` in a counting allocator and counts `Arena.alloc`,
    `Arena.remap` and `Arena.openChunk`.
  - With `BENI_ALLOC_SITES` set, a Debug build captures a 10-frame stack per allocation
    (`std.debug.captureCurrentStackTrace`). It aggregates by the first beni frame outside the
    allocator plumbing, and tracks live bytes per site to snapshot the peak.
  - `BENI_GPA_BUMP` swaps the child for `std.heap.ArenaAllocator(page_allocator)`.
- **Timing and syscalls.** Timings are from an unmodified ReleaseFast build of the same commit.
  Faults and RSS come from GNU `time -f '%e %U %S %R %M'`, syscalls from `strace -f -c`, and phase
  times from `--self-profile` summed per event name.
- **Corpus.** `zig build bench -- --generate=100000` (§3's header).

The allocator microbenchmark is 60 lines. It replays §3.2's counts against `smp_allocator` and a
copy of `src/Arena.zig`.
