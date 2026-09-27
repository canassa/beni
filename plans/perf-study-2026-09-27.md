# beni compiler — whole-pipeline performance study (read-only, commit `8b98464`)

Date 2026-09-27. Scope: lex → parse → BIR → graph/resolve → keys → check → emit → cache, on the
two `zig build bench -- --generate=100000` corpora (plain and `--dispatch`, 624 files, ~100 k
lines, 635 modules with core), `--wide=5000|20000` (one 128 k-line module), `bench/pathological`,
and the warm (cached) path. Nothing tracked was edited; prototypes were built in a private worktree
(`scratchpad/perfstudy/wt`, since removed) with `--prefix`.

## Method

- ReleaseFast binaries of `8b98464` built in my own worktree; one extra copy with
  `omit_frame_pointer = false` for `perf record -g` (Zen 3 has no LBR and DWARF unwinding of Zig
  ReleaseFast frames failed). The frame-pointer build executes the same instruction count
  (1 306.39 M vs 1 306.04 M on the plain build).
- Counters: `perf stat -e instructions:u,cycles:u,page-faults:u`, pinned with `taskset -c N`,
  7 interleaved runs, **minimum** of cycles (instructions are deterministic to ±0.01 %).
  User cycles only (`perf_event_paranoid = 2`), so kernel time was read separately with GNU
  `time` (`%U %S`) and `strace -c`.
- Where-it-goes: `perf record -g -e cycles:u` (5 k–25 k samples) and `-e page-faults:u -c 1`
  (every fault), aggregated from `perf script` by caller / callee frame.
- Phase split and wall-clock timelines: `--self-profile`, taken once when the machine's load fell
  to ~2.5 (it was 10–47 for most of the study) and cross-checked against counters.
- Output identity for every prototype: `diff -r` of the full `--library` output trees of both
  corpora (dev and `--release`), plus every directory fixture of `tests/corpus/run` built by the
  base and prototype binaries (stdout/stderr hash and output tree).

Commands (`B` = binary, corpus root = the generated tree):

```
B check --no-cache --jobs=1 .
B build --library --platform=node --no-cache --jobs=1 --out=OUT .
```

## Where the time goes today (baseline `8b98464`)

Plain corpus, one core, whole process:

| | instructions | user cycles | page faults | user / sys (s) | max RSS |
|---|---|---|---|---|---|
| `check` | 934 M | 434–437 M | 10 048 | 0.11 / 0.025 | 45 MB |
| `build --library` | 1 306 M | 567–578 M | 26 409 | 0.15 / 0.06 | 115 MB |

- **System time is 18 % of `check` and 28 % of `build` CPU**, almost all of it first-touch page
  faults (~2.3 µs each measured as sys-time ÷ faults). At `--jobs=8` sys time doubles (check
  0.025 → 0.06 s) for the same fault count: faults contend on the process's `mmap_lock`.
- Cycles by phase, `build`, jobs=1 (inclusive, frame-pointer profile): check 47 %, emit 24–30 %,
  front end (lex+parse+lower) 26 %, resolve 6.6 %. Emit alone produces 65 % of all page faults.
- Wall clock at `--jobs=8` on a quiet machine (self-profile timeline, plain `build --library`,
  baseline): front end 11 ms (parallel), interner merge 2 ms, graph 1 ms, **resolve 9.5–10 ms
  serial**, keys + types 2 ms, check 14 ms (parallel), a ~4 ms serial tail, then **emit 71 ms
  serial**. Total ≈ 115–120 ms, of which only ~25 ms runs in parallel. Amdahl, not per-core speed,
  is what limits the cold build.
- The warm, nothing-changed path (`.beni-cache` populated): `check` 53 ms wall at jobs=1, `build`
  131 ms, of which emit is 70 ms (58 %) because a build re-lowers, re-prints and rewrites every
  output file.

---

## Ranked candidates (expected gain ÷ effort)

Numbers marked **measured** come from a prototype in the private worktree; the others are
estimates, with the reasoning next to them.

### 1. The emitter builds a module-specifier table per module: O(modules²) — MEASURED

**Evidence.** `js.Emit.relativeSpecifier` is **8.7 % of all user cycles** of the build and
**13 414 of 26 409 page faults (51 %)**. For each emitted module, `emitModules` builds a fresh
`specifiers[count]` array and a fresh string for every module in the project
(`src/js/Emit.zig:1299-1300`), in the emit arena, which is never reset between modules. With
635 modules that is 403 k small string builds (each `ArrayList` grown two or three times in an
arena that cannot free) and ~55 MB of fresh memory. That is what took the build's RSS from 45 MB
(check) to 115 MB.

**Root cause.** A specifier depends only on the importer's directory **depth** and the target's
path. Only imported modules are read (`js/Lower.zig:1159`).

**Change.** Build one table per distinct depth (the prototype does this in 9 lines), or compute
specifiers lazily for the module's actual imports.

**Measured** (plain / dispatch, `build --library`, jobs=1, min of 7):

| | instructions | user cycles | page faults | RSS | wall, jobs=8 (quiet) |
|---|---|---|---|---|---|
| base | 1 306 M / 1 356 M | 567 M / 615 M | 26 409 / 26 932 | 115 MB | 115–120 ms |
| P1 | 1 165 M / 1 214 M | 519 M / 565 M | 12 069 / 12 501 | 58 MB | 79–86 ms |
| Δ | **−10.8 % / −10.4 %** | **−8.4 % / −8.1 %** | **−54 %** | **−50 %** | **−30 %** |

Emit went from 71 ms to 36 ms at jobs=8. The output is byte-identical (both corpora).

**Risk.** None. Determinism and output are untouched. **Effort:** minutes. The quadratic grows
with project size: at 2 000 modules it would dominate the whole build.

*Landed 2026-09-28 by R15-fix-B* (`Emit.specifierTable`, one table per importer depth): plain
1 306.3 M → 1 166.0 M instructions (−10.7 %), dispatch 1 355.9 M → 1 214.8 M (−10.4 %), page
faults −54 % / −53 %, output byte-identical (`plans/checker-rewrite.md`, *R15-fix-B*).

### 2. Emit is entirely serial — ESTIMATED −20–25 ms wall at jobs=8 after #1 (≈ −30 %)

**Evidence.** After #1, emit is still 33–36 ms of an ~80 ms `--jobs=8` build (45 %), on one
thread, `build/Command.zig:87-100` → `Emit.run`. Its parts at jobs=1: `js/Lower` ≈ 8 % of build
cycles, `Print` ≈ 4 % (after #3), writes ≈ 8–11 ms of syscalls (629 × `mkdirat` + open/writev/close;
`Emit.zig:1684-1700` calls `createDirPath` for every file). `fast-compiler.md` §10 lists
"codegen per declaration as a bounded producer/consumer pipeline behind the checker" as a thing
to parallelise, and it is not.

**Root cause (why it is serial).** Per-module lowering and printing read only immutable inputs
(Bir, interfaces, dispatch tables, `Types`, the `Reach` live set) **except** for two shared
mutable things:

- `js/Lower` interns into the session's **global** `InternPool` (28 `interner.getOrPut` sites,
  e.g. `js/Lower.zig:190-199`, `:626-680`, `:4163`);
- `--release`'s `Rename.begin(…, &e.globals)` (`Emit.zig:1338`) numbers global names across
  modules in module order.

**Change.**

1. Intern the backend's fixed names (`$t`, `$x`, `apply`, `codePointAt`, the derived-runtime
   names …) once, before the fan-out.
2. Invented names go into either a per-worker `InternPool.Local` overlay (the front end already
   has the pattern, with ids tagged by worker) or straight into the module's `JsIr.string_bytes`.
   A `Name` needs text, not global identity.
3. Run `Lower → Opt → Print` per module on the existing workers, results in a per-module slot.
   Concatenate diagnostics in module order.
4. Release: compute the cross-module half of `Rename` (exported names) serially first, then fan
   out. It is the same order as today.
5. Create each output directory once, then write files in parallel (or on a writer thread, as
   results arrive in module order).

**Estimate.** Lower + print ≈ 20 ms of CPU at jobs=1 → ~3–4 ms on 8 workers. Writes ≈ 8 ms →
~2–3 ms parallel, less with directories made once. That gives −20 to −25 ms of an ~80 ms build.
The output is identical by construction (module-indexed slots).

**Risk.** Determinism is the main one: names must not depend on which worker interned them,
which holds if printed text comes from the name's bytes and never from a symbol id. That is
already the rule after CK-71. Medium effort.

### 3. The JS printer's piece-list joiner, and a linear reserved-word scan — MEASURED

**Evidence.** Under `Printer.statement`:

- 34 % of samples are an out-of-line `ArrayList(Piece).append` (it shows up as the ICF-merged
  symbol `array_list.Aligned(check.Cycles.Graph.Frame,null).append`);
- 25 % are `mem.eqlBytes`, from `isReservedWord` doing 48 `std.mem.eql` per binding name
  (`js/Print.zig:1300-1314`).

`Print.Joiner` (`js/Print.zig:131-181`) stores a 16-byte `Piece` for every token-sized push
(`"("`, `"$"`, a name) and blits at the end. For ~1–3 bytes of output per piece, that is ~5× the
memory traffic of writing the bytes. esbuild's `Joiner` joins large precomputed chunks in the
linker; it was never meant for per-token output.

**Change.** Make the joiner a plain `ArrayList(u8)` (`push` = `appendSlice`; `blit` =
`toOwnedSlice`). Make the reserved-word test a comptime `std.StaticStringMap` (length-bucketed).
The prototype touches ~40 lines, and the public `Joiner` API is unchanged.

**Measured** on top of #1: build **−3.8 % instructions, −3.8 % user cycles** on both corpora
(1 165 → 1 121 M, 519 → 501 M plain). The output is byte-identical: dev and `--release` trees of
both corpora, and all `tests/corpus/run` directory fixtures.

**Risk.** None. **Effort:** an hour.

### 4. `Graph.lookup` is a hash map keyed by a dense id, probed up to three times per reference — MEASURED

**Evidence.** `resolve.Graph.lookup` plus its `Wyhash.final` is 3.5 % of build cycles and
**≈12 % of a warm `check`**. `by_name: AutoHashMap(Key{package, Symbol}, Index)`
(`resolve/Graph.zig:95`) is probed by `lookup` (`:196-205`) in the order own package → platform
→ core. An app module's `List.map` therefore costs three wyhash probes, and the resolver calls it
per qualified reference (`Resolve.zig:308`, `:329` and eight more sites), not once per import.
This is `fast-compiler.md` §5 rule 5, "No HashMap keyed by a dense id", which is also the one
rule Roc lints for.

**Change (prototype).** After step 1 of `Graph.build`, a dense `[3][]u32` table (per `from`
package, indexed by module-name symbol, answers precomputed with the same precedence), and
`lookup` becomes one bounds check and one load. The better long-term shape is to resolve each
`import` to its `Graph.Index` once per module and have qualified references carry the import
index, so resolution does no name lookup at all.

**Measured** on top of #1–#3:

| | instructions | user cycles |
|---|---|---|
| `check`, plain / dispatch | −4.6 % / −2.7 % | −4.3 % / −2.5 % |
| `build`, plain / dispatch | −3.9 % / −2.3 % | −3.2 % / −2.5 % |
| warm cached `check` | **−18 %** (187 → 153 M) | **−18.5 %** (87.7 → 71.5 M) |

The output is byte-identical.

**Risk.** None: same answers, same precedence. The table is sized by the largest module-name
symbol (kilobytes). **Effort:** an hour. The import-index version is a day.

### 5. Resolution is serial, and re-runs for every cache hit — ESTIMATED −7–9 ms wall (jobs=8), −15 % warm

**Evidence.** `Session.resolveSerial` → `Resolve.run` walks `graph.order` on one thread
(`resolve/Resolve.zig:144-148`): 9.5–10.5 ms in every jobs=8 run. That is the single largest
phase of a `--jobs=8` `check` (≈40 ms total), bigger than the whole parallel check (14 ms). On a
warm run where every module is a cache hit, it still rewrites every module's Bir and rebuilds
every interface: 8.4 ms of 53 ms (16 %) at jobs=1. The cached front-end artifact is the
pre-resolve Bir (`frontend/artifact_bytes.zig` header).

**Change.**

- **(a)** Schedule `Pass.module(m)` on the check driver's DAG (`check/Driver.zig`). A module
  needs only its imports' resolved interfaces, which is exactly the check schedule's readiness
  condition. The simplest form is a second DAG pass with the same scheduler; the best form fuses
  resolve(m) into the task that checks m.
- **(b)** For a module whose check key hits, skip the rewrite: its interface comes from the cache
  entry. That needs the key's own terms to be computable before resolution, or the resolved Bir
  (or the resolution side table) stored in the frontend artifact.

**Estimate.** (a) takes ~7 ms (after #4) of serial time down to ~1–2 ms at 8 jobs, −6 to −9 ms
wall on a 40–80 ms command. (b) removes most of the warm path's resolve share (−10 to −15 % of a
warm check).

**Risk.** (a) is low (same scheduler, module-indexed results). (b) is medium: the key must cover
everything resolution reads, and `reads.zig`'s coverage self-check is the tool for that.
**Effort:** (a) a day; (b) days.

### 6. First-touch memory: page faults cost as much as a phase — PARTLY MEASURED

**Evidence.** Check: 10 048 faults ≈ 40 MB of fresh pages for 1.8 MB of source, sys = 18 % of CPU.
Bucketed by owner (every fault sampled):

| Owner | Share of faults |
|---|---|
| front end (`bir.Lower` 27 %, `parsePhase` 20 %, `Tokenizer` 19 %, `Parse` 3 %) | **70 %** |
| `check.Publish` | 13 % |
| everything else | 17 % |

This is also why the front end costs **1.9× more in the real process than `zig build bench`
reports**: in-process lex+parse+lower at jobs=1 is 45 ms, against the bench's 24 ms. The bench
times warm iterations whose memory the allocator recycles, so it never pays first touch.

**Root causes.**

- **The AST is kept for the whole session.** Nothing on a `check`/`build` path reads it after
  lowering (`artifact_bytes.zig` header; `Session.zig:844`).
- **`Schemes.Writer.resetMemo`** (`check/Schemes.zig:274-289`) allocates three `store.count()`
  arrays per module from the gpa (12 bytes per type variable) and memsets one. `TypeStore`
  already owns an epoch `mark` column for exactly this purpose, and the worker's scratch arena
  (R14b) would recycle the rest.
- **Everything the front end outputs is fresh gpa memory** (`Artifacts.zig` rationale). That is
  right for a daemon's replace-one-file story, but in a cold process it means every byte is
  written into never-touched pages. `toOwnedSlice` on `ArrayList`s (`bir/Lower.zig:359-369`,
  `Parse.zig:210-212`) can add a second copy into fresh memory when the size class changes.

**Change.**

- **(a)** Free the AST's nodes and extra right after lowering on `check`/`build`. Keep `errors`,
  which `isMalformedSchemaOffset` reads during lowering. Better still, parse into the worker
  arena when the command does not need the tree.
- **(b)** Give `Schemes.Writer` its memo from the scratch arena and the store's epoch column.
- **(c)** Back large arena chunks and the artifact storage with `madvise(MADV_HUGEPAGE)` regions
  (THP is in `madvise` mode on this machine), so a 2 MB region costs one fault instead of 512.
- **(d)** Add a **cold single-shot** measurement to `zig build bench` (faults and sys time), so
  §12's budget line sees what the process pays. R14b found the store's version of this by
  accident.

The daemon (M4) removes most of it for warm edits, but not for cold builds or CI.

**Measured (a)** (on top of #1–#4): `check` faults 9 067 → 7 286 (**−19.6 %**), sys 22 → 18 ms, RSS 40 → 32 MB, user cycles −1.2 %; build faults −15 %; output identical. **Estimate for (a)+(b)+(c):**
−40 to −60 % of faults. At ~2.3 µs per fault that is −9 to −14 ms of CPU per cold `check`
(−7 to −10 %), and it recovers the jobs=8 sys-time doubling, which is contention and not work.

**Risk.** Low for (a) and (b). (c) is platform-specific: Linux only, with a fallback to plain
pages. **Effort:** (a) an hour, (b) a few hours, (c) a day.

### 7. A field access on a large record materialises the remainder record — MEASURED pathology

**Evidence.** `--wide`, one module:

| | lines | check | throughput |
|---|---|---|---|
| `--wide=5000` | 34 k | 78 ms | 436 k LOC/s |
| `--wide=20000` | 128 k | **550 ms** | **234 k LOC/s** |

That is 3.76× the lines for 7× the time, and below the §2 budget of 250 k. The 20 k run takes
**620 MB RSS, 160 k page faults and 0.30 s of sys time**. Of its samples:

| Hot spot | Share |
|---|---|
| `std.sort.block` from `TypeStore.addFields`, via `Unify.freshRecord` / `flat` | 15 % |
| `Generalize.enter` (rank adjustment) | 8 % |
| kernel page faults, mostly `ArrayList(u32).ensureTotalCapacity` → memcpy of the store's `extra` | ~20 % |

**Root cause.** `w.f` is constrained as `{ ρ | f : a } ~ typeof w` (`constrain/Expr.zig:166-177`).
Against a closed k-field record, `Unify.record` (`check/Unify.zig:792-904`):

1. gathers all k fields;
2. builds `only_a` with k−1 fields;
3. `freshRecord` appends those k−1 fields to `store.extra` and **re-sorts them** (`addFields`
   always sorts, `TypeStore.zig:743-744`, although merge-join output is already in symbol order);
4. makes a young k-child node, which rank adjustment then walks.

So each access costs O(k log k) time and O(k) permanent memory. A record update of k fields does
k of them. Real Elm programs have 30–100-field `Model`s accessed hundreds of times.

**Change.**

- **(a)** A dedicated has-field constraint, solved by a binary search in the resolved (flattened,
  sorted) record when the receiver is already a record containing the field: unify `a` with that
  field's variable and nothing else. Otherwise fall back to today's row unification. That is the
  common OCaml/Roc shape. The fallback keeps every diagnostic path identical. The skipped ρ is
  fresh, occurs nowhere else, and is unreachable after the constraint, so no scheme or message
  changes.
- **(b)** `addFields` for already-sorted input (every `freshRecord` / merge caller) skips the
  sort.

**Estimate.** The wide case goes from quadratic to about linear: from 550 ms to, plausibly, under
150 ms. RSS drops by hundreds of MB. The 100 k corpora gain ~1 % (`Unify.flat` is 2.2 % of build
cycles there). Worth doing for the budget's own `--wide` line.

**Risk.** Medium: it is a new constraint kind in the rewritten checker. It needs CK-style
differential tests against the fallback, which is the same pattern the checker rewrite used.

### 8. The serial tail and the cache formats — small, cheap items

- **`cache_store` is 8 ms serial** on a default (cached) cold build at jobs=8
  (`Session.storeEntries`, `Session.zig:1457`). Writing each entry on the worker that checked the
  module removes it. The front-end store is already per worker.
- **`createDirPath` per output file** (`Emit.zig:1689`): 629 `mkdirat` calls, all `EEXIST`.
  Create each distinct directory once.
- **SipHash-128(1,3) as the integrity hash** of cache artifacts (`resolve/iface_bytes.zig:153`,
  used by `artifact_bytes`): 11.5 % of a warm `check`'s cycles, 90 of 126 samples on
  `frontend.artifact_bytes.read`. The guarantee it buys is torn or flipped bytes, not an
  adversary. A 128-bit non-cryptographic hash (XXH3-128 class) is 5–10× faster. Keep SipHash
  where a hash is a content address.
- **`dep_digest` + `cache_key` + interface hashing on `--no-cache`** (~3 % of a cold check).
  This is deliberate ("one code path", `Session.zig` `keys` doc), so it is only noted here. If
  the cost matters, compute them lazily only when a cache or `--frontend-keys` asks.

### 9. Warm builds re-emit everything — the largest warm-path item (M4)

**Evidence.** A no-change `build` with a warm cache takes 131 ms at jobs=1 and 110 ms at jobs=8,
of which emit is 70 ms (58 %): every module is re-lowered, re-printed and rewritten, and every
file is rewritten.

**Change.** The EmitCache in `fast-compiler.md` §4's diagram:

- per module, key the emitted bytes by (module check key, the module's `Reach` live set, emit
  options, backend build id), and reuse them on a hit;
- skip the write when the file already on disk has the same content, and hash rather than read
  it where the daemon knows the file.

**Estimate.** A no-change build goes from ~130 ms to ~40–60 ms today, and to the §2 budget
under the daemon. This is M4 work, and #2 composes with it.

---

## Summary of the prototypes (plain corpus, `build --library --no-cache --jobs=1`)

| Build | instructions | user cycles (min of 7) | page faults | output |
|---|---|---|---|---|
| base `8b98464` | 1 306.0 M | 567–578 M | 26 409 | — |
| + P1 specifier table | 1 165.3 M | 519–521 M | 12 069 | identical |
| + P2 printer buffer + reserved map | 1 121.3 M | 501–505 M | 12 069 | identical |
| + P3 dense `Graph.lookup` | 1 077.9 M | 489 M | 12 103 | identical |
| + P4 free the AST after lowering | 1 077.8 M | 477 M (check: 406 M, −1.2 %) | 10 321 (check: 7 286, **−19.6 %**) | identical; check sys 22 → 18 ms, RSS 40 → 32 MB |

- **P1+P2+P3 together:** build **−17.5 % instructions, −15 % user cycles, −54 % page faults,
  −50 % RSS**; `check` −4.6 % instructions; warm `check` −18 %.
- **Dispatch corpus, same three:** build 1 356 → 1 142 M instructions (−15.8 %) and
  615–620 → 536 M cycles (−13.5 %).
- **Wall at `--jobs=8` (quiet machine):** build ≈ 115–120 → ≈ 80 ms from P1 alone.
- #2 and #5 are the remaining Amdahl items. Together they bring the jobs=8 cold build to an
  estimated 45–55 ms, and the check to ~30 ms.

## What is already good — leave it alone

- **The front-end data layout.** SoA tokens, the 13-byte AST node, Bir `{tag, main_token, lhs, rhs}`
  with `extra`, symbols in one remappable column, and interning while scanning (FxHash, 180–220
  MB/s lex in the bench). No hot spot in the front end is a layout problem. Its only extra cost is
  first touch (#6).
- **The type store and checker core.** They were tuned hard by R8c/R9b/R14b, and §18's
  measured-and-declined list matches what I see:
  - the `TypeStore` MultiArrayList (a module's store fits in L2; the AoS version bought nothing);
  - epoch marks;
  - the worker-scratch store (R14b);
  - the flat profile: the largest check leaf, `Unify.go`, is 3 %.

  The constrain → solve split costs a tree build (constrain ≈ 12 ms of 63 ms at jobs=1), but
  fusing it would be a rewrite for ~10 % of one phase. Not recommended.
- **Per-module DAG parallelism in check.** It scales 5.5× on 8 threads (78 → 14 ms). It is the
  model for #2 and #5.
- **Determinism machinery.** The file-order interner merge is only 2 ms serial, and
  module-indexed result slots make #2 and #5 safe by construction.
- **The arena** (`src/Arena.zig`): it has no atomics and retains its largest chunk. Only the
  backing of large chunks is worth revisiting (#6c).
- **The pathological corpus** (`AccessChain8000`, `PlusChain8000`, `QuestionChain8000`) checks
  in 7–10 ms. Nothing superlinear there.

## Notes on measurement

- On this machine the minimum of pinned `perf stat` runs moved by < 1 % between identical
  binaries. Wall-clock under load 10–47 was useless, so every wall figure above was taken while
  the load average was ~2.5, and is backed by counters.
- `zig build bench`'s phase lines are warm-iteration numbers. They are right for per-phase code
  quality, but they undercount the real process by ~1.9× in the front end and miss emit's
  quadratic entirely: the bench's `emit` line lowers and prints each module but never calls
  `emitModules`' specifier loop. A single cold-process line, with faults, sys time and RSS, would
  have caught #1 and #6.
