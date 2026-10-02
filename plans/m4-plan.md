# M4 — the daemon and incrementality: a design-readiness pass

**Status:** plan, 2026-09-18, written at `6847a51` with M3 nearly closed. Nothing is started.
Written for the project owner to read **before** any M4 code exists, because
[`fast-compiler.md`](../docs/design/fast-compiler.md) §13 calls M4 *"the single largest win (63ms
vs seconds) but the one that needs the data model from M0–M3 to be right first — Zig's own
experience is that the wrong order costs a 30,000-line refactor (01 §7)."* The job of this document
is to answer whether the data model **is** right, now, while the answer is still cheap.

**The short answer: not yet, in four specific places, and one of them gets more expensive with every
milestone that ships.** §2 is the audit. Every claim about today's code is a `file:line`; every
number is measured here or cited to where it was measured.

**Measurement machine**, for every number in this document marked *(measured)*: AMD Ryzen 9 5950X,
16 cores / 32 threads, 64 MiB L3, 31 GB RAM, Linux 6.12.110, Zig 0.16.0, ReleaseFast, load average
1.2, built in a throwaway worktree at `6847a51`. This is **not** the N100 that `bench/README.md`'s
entries were taken on, so no number here is comparable to one there; the ratios are what travel.
Corpus is `zig build bench -- --generate=100000` — 624 files, 100 159 lines, 1 835 956 bytes,
634 modules with core.

---

## 1. What M4 is specified to be

### 1.1 The budgets it must hit (`fast-compiler.md` §2)

Five of the seven rows in §2's table are M4's, and they are *"the numbers CI tracks (§12); missing
them is a bug report, not a nice-to-have"*:

| Operation | Target | §2's stated evidence |
|---|---|---|
| Warm rebuild, one function body edited | **< 15 ms** | "Zig: 63ms for a 500k-line project with a much heavier type system (01 §7)" |
| Warm rebuild, one exported signature changed | **< 60 ms** | "bounded by the transitive re-check the interface firewall permits" |
| Warm rebuild, one dependency-free module added | **< 25 ms** | "one parse + one check + one emit" |
| Daemon cold start (mmap cache hit) | **< 120 ms** | "zero-parse mmap load of cached artifacts (04 §7)" |
| Cold full build, 100k LOC | < 800 ms | Elm at ~120–130k lines/s |

**The 63 ms is Zig's number, not beni's budget.** It is the evidence row for beni's own **15 ms**
target, and it belongs to a 500k-line project (`research/01-zig-data-oriented.md:261-266`: 14 s
initial `-fincremental --watch`, 63 ms for a subsequent single-file edit). Beni's warm budget on a
100k-line project is 15 ms; 60 ms for a signature change; 25 ms for a new module.

**Where a cold build stands today** *(measured)*, `beni build --platform=node --library --jobs=1`
on the 100k corpus: **180 ms wall**, against the 800 ms cold budget. `check --jobs=1` alone is
120–130 ms; `--jobs=8` is 30–40 ms. The cold budget is not in danger. The warm budget has never
been measured because nothing warm exists.

### 1.2 The process architecture (§4) — decided, unbuilt

> "The CLI is a thin client over a Unix socket; the compiler is a resident process holding the
> `Session`. The LSP server and `beni build` are the *same* process type… no global mutable
> singletons; arenas reusable per compilation, not per process; every phase able to run against an
> immutable snapshot while the next edit is ingested; file watching on `inotify`/`FSEvents`
> directly, since esbuild polls and that scales badly on large trees (03 §1)."

§4's diagram names five resident structures: `SourceStore` (mmap'd, content-hashed), `InternPool`,
`ModuleGraph + DepGraph (AnalUnits)`, arenas, and `EmitCache (per-decl JS chunks)`.

**Scored against the code.** No global mutable state: **true and verified** — zero `threadlocal`,
zero container-scope `var`, no singletons in `src/`; the one shared mutable object is
`Session.next_file`, an explicit atomic (`src/Session.zig:105`, header claim at `:4-6`). Arenas
reusable per compilation: **true** (`src/Arena.zig`, reset `.retain_capacity` per file at
`src/Session.zig:580`). Everything else — mmap, content hashes, the dep graph, the emit cache, the
socket, the watcher — **does not exist**, and there is no `daemon` subcommand: `Cli.Command` is
`{build, check, fmt, dump, version, help}` (`src/Cli.zig:142-149`).

### 1.3 The firewall (§8.1) — decided, with a formula

> "Recompiling a module must **not** recompile its dependents unless its *public interface*
> changed… Beni keys it on **content hashes, not mtimes** — Elm's mtime scheme is the documented
> cause of its cache-desync bugs and CI pathologies (05 §3). **Cache key = source bytes + module
> identity + compiler version + direct imports' interface hashes** (Roc's `cache_key.zig` model,
> 05 §4), with a `stat` fast-path avoiding hashes for files whose size and mtime are both
> unchanged (04 §7)."

Two later documents add to that key, both normative: [`boundary.md`](../docs/design/boundary.md)
§7.3 (`:404-416`) adds *"the content hash of the sibling JavaScript file"* and requires the `stat`
fast-path to cover sibling files; [`backend.md`](../docs/design/backend.md) §9 (`:1304-1312`)
restates the whole key for the reachability edge list.

§8.1 also **explicitly rejects** salsa-style query memoization, on rustc's own evidence
(fingerprinting named by rustc's docs as *the* reason incremental can lose to clean; 2–4× memory
blowups; `research/04-architecture.md:242-281`). That rejection is load-bearing and should not be
reopened without new evidence.

### 1.4 The declaration-level graph (§8.2) — a sketch, and §14 says so

Four unit kinds (`decl_ty`, `decl_val`, `ctor`/`type_def`, `emit`) and Zig's two-phase
outdated / potentially-outdated mark with a counter. §14 open question #3 is *"How fine is too fine
for Layer 2? Zig found `AnalUnit` granularity needed a major refactor to avoid over-analysis when a
type doubles as a namespace (01 §7). **Start at the four kinds in §8.2 and resist adding more
without a measurement that demands it.**"* That is a sketch with a stated discipline, not a
specification. §13 puts it **last** in M4's own build order: *"Socket protocol, content-hash cache,
mmap artifacts, interface firewall, then the declaration-level graph."*

### 1.5 The cache format (§8.3) — decided in one paragraph

> "Dump the arena's flat arrays as raw byte ranges with a small header; `mmap` on load; validate
> with a format version and content hash. No general serialization library — rkyv-style zero-copy
> is the *idea* to steal, not the dependency (04 §7)… Only possible because of the no-pointers rule
> in §5."

### 1.6 What §14 leaves open, and one answer the code has already given

**#3, Layer-2 granularity** — genuinely open (§1.4). **#4, *"Does BIR need to be separate from the
resolved IR at all?"*** — the premise is overtaken: there *is* no separate resolved IR. `Resolve`
rewrites the BIR **in place**, turning every `import_value`/`qualified`/`type_import` instruction
into `ext_value`/`top`/`ext_type` (`src/resolve/Resolve.zig:221-238`, `:303-315`;
`src/Artifacts.zig:121-127`). One array, two states — pre-resolve, the cacheable one, and
post-resolve, which carries `Graph.Index` and interface indices. §2.3 is what that costs.

### 1.7 Summary: decided / sketch / open

| Decided | Sketch | Open |
|---|---|---|
| Daemon + thin socket client (§4); interface firewall as the primary layer (§8.1); content hashes not mtimes; cache-key formula (§8.1 + boundary §7.3 + backend §9); zero-copy mmap of our own flat arrays (§8.3); no salsa (§8.1, §11); determinism as a requirement (§10); `--self-profile` and the pathological corpus (§12) | The declaration-level graph (§8.2): four unit kinds and two-phase marking, with no shape for the dependency table and no decision about where it lives | Layer-2 granularity (§14 #3); the socket **protocol** (framing, request set, versioning — nothing anywhere specifies it); the memory ceiling; file watching vs explicit requests; the multi-entry-point/multi-platform manifest (boundary §5.3) |

---

## 2. The audit: is the data model right for M4?

### 2.1 The table

For each per-module artifact: **(a) pure?** — is it a function of (this module's source, its imports'
*interfaces*) alone? **(b) relocatable?** — could it be memcpy'd to disk and mmap'd back without a
fixup pass? **(c) unstable ids embedded?**

| Artifact | (a) pure? | (b) relocatable? | (c) embeds which unstable ids? |
|---|---|---|---|
| **Tokens** (`Token.TokenList`) | **yes** — one file's bytes | almost: flat SoA, `payload` is a `Symbol` | `Symbol` (pool-relative, `--jobs`-dependent) |
| **Comments, lex diagnostics** | yes | yes — offsets and codes only | none (`src/lex/Diagnostics.zig:7` designed for it) |
| **Ast** | **yes** | **yes** — three flat arrays, "copy, cache and (in M4) mmap without a fixup pass" (`src/parse/Ast.zig:8-9`) | none |
| **Bir, pre-resolve** | yes, *plus* `Lower.Options{core, platform, module_name}` (`src/bir/Lower.zig:149-162`) | yes for contents; the record is 12 owned slices needing a header+offsets. `extra` is 4-byte-word aligned (`src/bir/Bir.zig:750-754`) | `Symbol`, but **indirected through one `symbols: []Symbol` column** (`:57-60`) — remap is one loop (`:731-733`) |
| **Bir, post-resolve** | **no** — mutated in place by `Resolve` | no | `Graph.Index` + `Interface.ValueIndex` in every `ext_*` instruction (`src/resolve/Resolve.zig:221-238`) |
| **Resolved imports / module graph** | n/a — whole-program | no | `Graph.Index` throughout; `Graph.by_name` is keyed on a `Symbol` (`src/resolve/Graph.zig:95`, `:114-117`) |
| **`Types` (session type table)** | **no** — walks **every** module's Bir (`src/check/Types.zig:257`, `:363`) | n/a — whole-program | assigns `TypeId` by module index × declaration order (`:250-278`) |
| **TypeStore** (per module) | yes | no — arena-backed, discarded per module by design (`src/check/Check.zig:584-586`) | not cached; not wanted |
| **Interface record** | **no — see §2.2** | yes in shape; `Interface.zig:357-366` bounds-checks ranges *specifically* "because a record that does not describe itself must not be able to crash the compiler" | `Symbol` column (`:56-58`) **and session-global `TypeId` in `Term.app`/`Term.alias`** (`:182-183`, `:194-196`) |
| **Dispatch table** | pure w.r.t. importers; depends on imports' interfaces | yes in shape (seven flat tables, `src/check/Dispatch.zig:227-247`) | **`Graph.Index`** in `Target.ext` (`:96-100`) and `Target.ext_derived` (`:118-123`); `TypeId` in `Shape.nominal` (`:48-49`); sorted by a key that reads **another module's name** (`src/check/Check.zig:1222`) |
| **Cycles result** | **yes — the cleanest artifact in the compiler.** Signature is `(scratch, bir, dispatch, interner, reporter)`: no graph, no artifacts, no interfaces (`src/check/Cycles.zig:87-93`, `:58-64`) | n/a (diagnostics only) | none |
| **Exhaustive result** | **yes** — cross-module reads go through the *interface* only (`src/check/Exhaustive.zig:948-968`, header `:31-36`); its `graph`/`artifacts` fields are dead (`:354-355`) | n/a | `TypeId` as union identity (`:951`, `:961`) — comparison only, stable under renumbering |
| **Diagnostics** | yes, per module | yes — stored as codes + offsets, never rendered strings, "so a daemon can re-report a cached file without re-lexing" (`src/lex/Diagnostics.zig:7`, `src/parse/Diagnostics.zig:9`, `src/bir/Diagnostics.zig:10`, `src/render/text.zig:14`) | none |
| **Reach edge list** (per module) | **no** — see §2.4 | yes: CSR arrays in independent slots (`src/js/Reach.zig:345-359`, built one-per-slot at `:304-305`) | `Graph.Index` in every node (`:92-100`) |
| **JsIr** (per module) | yes w.r.t. bodies — lowering never reads another module's Bir (`src/js/Decision.zig:49-57`) — but reads whole-program `Types` and whole-program `Reach.Result` | **yes, by design**: "there is no pointer and no slice anywhere… **M4 can map the whole thing**" (`src/js/JsIr.zig:11-16`); `verify()` at `:509-532` is a ready-made loaded-cache validator | `Symbol` in every `Name` (`:311-329`) |
| **Emitted text** | per module | yes (bytes) | none — but there is no write-skip: `flush` rewrites every pending file every build (`src/js/Emit.zig:928-945`) |

### 2.2 Finding 1 — the interface record is **not** a pure function of (source, imports' interfaces), and this is the one that gets worse with waiting

`Interface.Term.app` and `Interface.Term.alias` spend `lhs` on a `TypeStore.TypeId`
(`src/resolve/Interface.zig:182-183`, `:194-196`). A `TypeId` is a **whole-program dense index**,
assigned by `Types.build` walking modules in `Graph.Index` order and, inside a module, in
declaration order, incrementing only on type declarations
(`src/check/Types.zig:250-278`, the assignment at `:263`).

**Demonstrated** *(measured)*. A three-module project; `Zeta.beni` imports nothing and is never
edited. `beni dump --stage=raw --jobs=1 src`, Zeta's section:

```
term 4 app 15 10      # before
term 4 app 16 10      # after adding one type declaration to Alpha.beni
```

The same one-word shift is produced by **all three** of:

1. adding `pub type Extra = Solo` to `Alpha.beni` (an alphabetically earlier module Zeta does not
   import);
2. adding a **private** `type Hidden = Secret` to the same module — so the answer to *"does adding a
   private type change an importer-visible artifact?"* is **yes, today, through renumbering**, quite
   apart from the DCE spec's nominal-derived-row rule;
3. adding a **new file** `Beta.beni` containing one type.

A new file containing only *values* leaves Zeta's bytes identical, because `by_decl` appends `.none`
for a value (`src/check/Types.zig:258-261`).

**What this costs.** §8.1's cutoff is "recompile a dependent only when the dependency's interface
changed." If the interface is hashed as it stands, **one new type declaration anywhere earlier in
sorted-path order changes the hash of every interface that mentions any type numbered after it** —
which on a real project is most of them. The firewall would fire on approximately every
type-introducing edit, and the 15 ms and 60 ms budgets would be measured against a full rebuild.

`checker.md` §7 already names the neighbourhood of this problem — *"what M4 needs is a story for the
whole type table"* — but frames it as two cross-module **Bir reads** (`Types.build` itself and
`Types.Builder.aliasBody`, `src/check/Types.zig:842-850`). The renumbering consequence for the
**hashed bytes** is not written down anywhere, and it is the sharper half.

**Smallest fix.** Do not write a session `TypeId` into the interface. Write instead the pair the
record already knows how to hold — a module reference plus that module's own interface `TypeIndex` —
or, cheaper still, a **stable content-derived type key**: `(package, module path, type name)`
interned into the record's own `symbols` column, which is already remapped on load. Consumers
already go interface-`TypeIndex` → session `TypeId` through `Types.ofInterface`
(`src/check/Solve.zig:2587`, `src/check/Schemes.zig:673-677`); `app`/`alias` are the two sites that
skipped that indirection.

**Why now rather than later.** This is a change to the *bytes of the interface record*, which is (i)
what every `check/good/*.iface` and `--stage=raw` golden asserts, (ii) what the static-dispatch
`where` blocks were built into (`static-dispatch-spike.md` §6.5), (iii) what the effects proposal
plans to add two bits to (`plans/effects-plan.md` §3), and (iv) what M3d's `lazy` type rewrite
would touch at the boundary. Every one of those makes the record wider and the golden set larger.
**Changing two term tags is a one-slice job today and a re-blessing exercise after each of them.**

### 2.3 Finding 2 — BIR has two states and only one is cacheable

`Resolve.rewriteReferences` mutates the BIR in place, rewriting `import_value`/`import_ctor`/
`qualified`/`qualified_ctor`/`type_import`/`type_qualified` into `ext_value`/`ext_ctor`/`ext_type`/
`top`/`ctor`/`type_top`/`error` (`src/resolve/Resolve.zig:221-238`, target resolution `:303-315`;
tag comments `src/bir/Bir.zig:169-186`, `:202-204`). `Artifacts.birMut` exists for exactly this
(`src/Artifacts.zig:121-127`).

So the "purely a function of one file's text, content-addressable across process restarts" BIR of
§6 **is** that — right up to the firewall — and then the same array becomes graph-relative.
`Bir.refs`, by contrast, stays symbolic and is never rewritten, which is why `Reach` leg 2 has to
read instructions rather than refs (`src/js/Reach.zig:400-423`).

**Smallest fix.** Serialize the **pre-resolve** BIR and re-run `rewriteReferences` on load. That is
already the cheap half: `resolve` is 3.05 ms across 634 modules *(measured)*, ~5 µs per module.
State it in the spec so nobody caches the post-resolve form by accident.

**Also on the key:** `Lower.Options{core, platform, module_name}` is an input
(`src/bir/Lower.zig:149-162`), so the BIR cache key is (file bytes, package privilege bits, module
name, compiler build) — not file bytes alone as §6 implies.

### 2.4 Finding 3 — three "pure per module" claims in the specs are not true of the code

| Claimed | Where | What the code does |
|---|---|---|
| A Reach edge list "is a pure function of that module's `Bir` and dispatch table" | `src/js/Reach.zig:69-77`; repeated `backend.md:1172-1180` | Building module M's list reads the **target** module's `Interface.Provenance` (`src/js/Reach.zig:472-476`), the **target's** `Dispatch.derived` table (`:494-505`), the whole-program `Types` (`:488-492`), and **core's `Bir`** for `string_compare`/`err` (`:206-221`) |
| The interface is what a dependent checks against | `checker.md` §7 | Two cross-module Bir reads remain on the checking path and the code says so: `Types.build` (`src/check/Types.zig:257`, `:363`) and `Types.Builder.aliasBody` (`:848-850`). A third, on the error path, is `Solve.privateInOtherModule` (`src/check/Solve.zig:3058-3066`) |
| Invalidation follows `graph.dependencies` | implicit in §8.1 | The solver reaches into `core/Basics`' interface **with no import edge** (`src/check/Solve.zig:2583`, `:3348`). "Did `Basics` change?" must invalidate more than the graph says |

None of these is fatal — `backend.md` §9's M4 bullet already keys the edge list on *imports'
interface hashes*, which covers the first if it is stated deliberately rather than assumed. But
each is a place where an M4 implementer following the prose would build a cache that is silently
wrong, and the third is invisible unless someone reads `Solve.zig`.

**Smallest fix:** correct the three comments; add `core/Basics` (and `core/String`, which `Reach`
also reaches into) as an implicit dependency edge of every module, or make the prelude a named
durability tier (`research/04-architecture.md:271-278`) that a user edit never invalidates.

### 2.5 Finding 4 — `Symbol` ids are assigned by thread scheduling, and the code already calls this a future bug

`Symbol` is the append position in the pool (`src/InternPool.zig:313`). Files are handed to workers
by a racing atomic counter (`src/Session.zig:566`); each worker interns the identifiers of the files
it happened to take; the merge is in worker-index order, which is deterministic *given the local
pools*, and the local pools are not. `Session.zig:16-22` states the consequence and the remedy:

> "a worker's local pool holds the identifiers of the files it happened to take, so the global index
> a given identifier ends up with still varies with `--jobs`. Nothing observable depends on it… and
> **the moment one reaches an artifact that is compared or cached, this becomes a bug and the ids
> have to be assigned by a pass keyed on file index instead.**"

M4 is that moment. A second, independent hazard: the pre-seeded `WellKnown` block is stable only
within one compiler build — *"entries come and go from the MIDDLE of this list as the language
changes… When M4's daemon starts writing indices into an on-disk cache, that cache has to be keyed
on the compiler build"* (`src/InternPool.zig:142-148`).

**This one is already mostly paid for.** Every artifact that holds symbols holds them through **one
column** — `Bir.symbols`, `Interface.symbols`, `JsIr.names` — precisely so a remap is one loop
(`src/bir/Bir.zig:731-733`, `src/Artifacts.zig:151-159`). The fix is to write the column as *text*
(or as offsets into a per-artifact string blob) and re-intern on load, which is `Global.merge`'s
shape run backwards. Nothing else in any artifact needs touching.

**One documentation defect found on the way:** `fast-compiler.md` §5.1 states that *"short
identifiers use inline storage (SSO) in the token payload so the common case never touches the
table"* and that the pool becomes *"a sharded global pool following Zig's index encoding."* Neither
is implemented. `Token.payload` is a plain `Symbol` (`src/lex/Token.zig:22-28`); there is no mutex,
no atomic and no sharding in `InternPool.zig`, and `:24-26` says sharding is *"M4 work and is
deliberately not started here."* Corrected in place (§9 below).

### 2.6 Finding 5 — `Session.run` is not re-entrant, and `Schemes.Writer.attach` is not idempotent

A daemon runs many compilations in one process. Today:

| Structure | Behaviour on a second `run` | Cite |
|---|---|---|
| `SourceStore.files` | **appends** — `finish` never clears, so files duplicate and `find`'s binary search breaks | `src/SourceStore.zig:309`, `:338-346`, `:159-166` |
| `worker.diagnostics` | **never cleared** — the previous run's diagnostics are re-collected and re-rendered | `src/Session.zig:317-318`, `:1008-1041` |
| `worker.counters` | never reset — profile counters accumulate | `src/Session.zig:248`, `:450-454` |
| `artifacts` | correct per file, but `resize` `freeAll`s **everything** and is called unconditionally at the top of every run | `src/Artifacts.zig:86-91`, called `src/Session.zig:366` |
| `Schemes.Writer.attach` | **appends** to `iface.symbols` and **overwrites `schemes`/`terms`/`extra` without freeing** — a module cannot be re-checked in place at all | `src/check/Schemes.zig:423-434` |
| `graph`, `resolution`, `checked`, `next_file` | correctly torn down and rebuilt | `src/Session.zig:777-778`, `:784`, `:818`, `:402` |

The asymmetry in the last row but one looks unintentional: `fillInterface` *does* free-and-replace
`iface.values` (`src/check/Check.zig:1089-1090`) and `fillCtorTerms` does the same for `iface.ctors`
(`:1162-1163`). Five small fixes, none architectural — but "one build per process" is a real
constraint that nothing today tests.

### 2.7 What is already right, and should be protected

Worth stating, because the audit is otherwise a list of problems. Six things M0–M3 got right:

1. **Enumeration is the one serial deterministic spine.** File index is a function of the sorted,
   deduplicated `(path, package)` list, assigned before any thread starts
   (`src/SourceStore.zig:299-351`, `src/Session.zig:365`); `Graph.Index` is that list compacted
   (`src/resolve/Graph.zig:236-249`); the topological order is Kahn over Tarjan with a min-heap keyed
   on each component's lexically smallest module (`:540-584`). Nothing follows completion order.
2. **Per-file artifact columns can already be freed and rebuilt one at a time**
   (`src/Artifacts.zig:95-99`), and the header says that is what the daemon needs (`:15-16`).
3. **Every IR is pointer-free** and says so: `Ast` (`src/parse/Ast.zig:8-9`), `Bir`
   (`src/bir/Bir.zig:7-14`), `Interface` (`src/resolve/Interface.zig:41-58`), `JsIr`
   (`src/js/JsIr.zig:11-16`). §8.3's zero-copy plan is buildable.
4. **Diagnostics are codes plus offsets, never rendered strings** — four modules say this is for the
   daemon.
5. **A declaration's instruction range is contiguous and self-contained** — *"a declaration can be
   checked, cached or dumped on its own"* (`src/bir/Bir.zig:10-14`). That is the property §8.2's
   units need, and it exists.
6. **The instruments exist before the thing they measure**: `Phase.eliminate`/`.emit`
   (`src/Profile.zig:64-76`) and the `emitted_files`/`modules`/`unifications`/`instantiations`
   counters, declared *"because M4's incrementality tests assert ('dependents were not re-checked'),
   which is why they exist before there is anything to count"* (`src/Profile.zig:13-14`).

---

## 3. The firewall in practice

### 3.1 There is no interface hash, and no interface comparison either

Grep over `src/resolve/` and `src/check/` finds "hash" only in future-tense comments
(`src/resolve/Interface.zig:9`, `:28-29`, `:125`, `:138`; `src/check/Schemes.zig:345-346`;
`src/dump/interface.zig:42-44`). `research/19` §16 said *"interface hashing does not exist yet (spec
§11) — and that is the quantity report 18 §2.3's argument turns on."* Still true.

Stronger: `Interface.zig:9`'s *"M2 compares it by value"* is **not backed by code**. Nothing in
`src/` compares two `Interface` values; there is no `eql`, no cached previous interface, no
invalidation of any kind. Every run rebuilds every interface from scratch
(`src/resolve/Resolve.zig:166`, `src/Session.zig:784-788`). The firewall is a *layout* decision
that has been honoured throughout and a *mechanism* that has never been built.

### 3.2 What static dispatch put into the hashed bytes

`Interface.Quantified` grew from two words to four (`src/resolve/Interface.zig:147`); words 2 and 3
are `constraints_start`/`constraints_len` into `extra`, each constraint two words of
`(SymbolIndex, TermIndex)` (`:127-144`). Rules that exist *because* of M4's hash, all honoured:
sorted by name **text**, never by symbol id; every name a `SymbolIndex`; `var(i)` means quantifier
`i` of the same scheme, so a dependent rebuilds the clause from the record alone.

`Interface.Provenance` is deliberately **outside** the record — *"meaningless once the Bir is gone,
so it must never be hashed, compared or written to disk"* (`:279-307`).

**`<error>` is load-bearing in the cached record**, and it is the one thing the record cannot say
about itself. Four paths publish a single-`err`-term scheme (`src/check/Check.zig:1049-1086`), and a
module cached while broken publishes holes its dependents will check clean against. Nothing in
`Interface` records whether the producing module had diagnostics. **M4's cache entry needs a
"produced by a clean check" bit, or broken modules must not be cached at all.**

### 3.3 Churn: what `bench/churn.sh` measures, and what it cannot

`bench/churn.sh` applies four mechanical edit classes (E1 literal, E2 duplicated operator, E3 new
`==`, E3poly the same restricted to a bare type variable) to every `pub` declaration, in two variants
(annotation kept / stripped), and **byte-diffs `dump --stage=raw` before and after**. Report 19 §4:

- **Every `annotated` row is 0 on both compilers and both corpora**, E3 and E3poly included. *"An
  annotation is the whole interface… a body edit cannot move it."*
- **Unannotated `pub` declarations are 4.4× and 6.5× worse** under dispatch: `core` went from
  8/94 (8.5 %) to 50/90 (55.6 %); `bench/corpus` from 5/52 (9.6 %) to 29/68 (42.6 %).
- **E3poly is 100 % unannotated on both sides.**

Two mitigations landed on 2026-09-18 and both are already in `fast-compiler.md` §8.1: the
`too_many_inferred_constraints` **cap of 64** (spec A.83), bounding a promoted suffix to ~2 kB at
§3.1's measured 31 characters per clause; and `ambiguous_method_receiver` **on by default** for
root-package modules, so the author is told the moment an unannotated `pub` declaration acquires a
constraint. Measured at the time: `core/` and `platforms/` together would produce **0** warnings.

**What churn.sh cannot measure: time.** It counts *bytes changed*, which is the right proxy for
"would the hash move" and says nothing about what a moved hash costs an importer. Report 19 §16 lists
that gap explicitly. It also cannot see a *cross-module* effect, because it diffs one module's dump.
**It would not have caught §2.2**: the `TypeId` shift comes from editing a *different* module, and
every one of churn.sh's edit classes edits the declaration whose dump it diffs.

### 3.4 The measurement M4 needs first — and why it cannot be run today

The right first instrument is a **warm-rebuild simulation with no daemon**: check module M alone,
given serialized interfaces for its imports, and compare the result byte-for-byte with M's slice of
a cold whole-project check.

**That is not possible today, and it is slice zero.** Two independent blockers, both measured:

1. `beni check` on a single file whose import is not also on the command line reports
   `UNKNOWN MODULE` and exits 1 *(measured)*. There is no `--module`, no `--only`, no way to supply
   an interface. `runCheck` forces `core_package = true` and `Session.run` unconditionally enumerates
   core, the platform and then the user's paths (`src/main.zig:108-110`, `src/Session.zig:351-367`).
2. `Check.run` has no per-module entry point at all — it takes the whole graph, the whole artifacts
   table and the whole interfaces slice (`src/check/Check.zig:170-181`), and the driver's
   `parallelisable()` gate reasons about the whole project (`:382-389`).

Until `beni check` can consume a serialized interface, every M4 claim about the firewall is
unfalsifiable. **Say it plainly: that is slice zero, and nothing downstream of it can be measured
before it lands.**

---

## 4. Long-lived process hazards

### 4.1 Arenas that only grow

| Structure | Growth | Cite |
|---|---|---|
| `InternPool.Pool` (bytes + entries) | **no removal API exists at all**; grows monotonically for the life of the process | `src/InternPool.zig:255-333` |
| `SourceStore.files` | only `deinit` frees | `src/SourceStore.zig:104-116` |
| `Worker.diagnostics` | appended per run, freed only at `deinit` | `src/Session.zig:272`, `:317` |
| `TypeStore` | arena-backed; `Arena.free` "rolls the bump pointer back only for the most recent allocation and is otherwise a no-op" (`src/Arena.zig:14-16`), so **every `ArrayList` growth leaks the old block** until `deinit` | `src/check/TypeStore.zig:294-357` |
| `Profile.ThreadBuffer` | **fixed capacity**, 64 Ki events = 2 MiB/thread, overflow counted as `dropped` — the one structure already bounded | `src/Profile.zig:175-180`, `src/Session.zig:183` |

**The good news about `TypeStore`:** it is one per module, `init`/`deinit` around each module's check
(`src/check/Check.zig:584-586`), so the arena is released wholesale and re-checking a module 1000
times causes **no `TypeStore` growth**. The 29 GiB incident is not a `TypeStore` design fault; it is
`src/check/Solve.zig:2064-2078`, where `attachConstraint` rebuilt a whole constraint set per
obligation, making an unannotated chain cubic — *"n = 1000 reached 29 GiB and was killed"* — and the
arena turned a cubic time bug into an OOM kill because every rebuilt set was permanently retained.
Post-fix: 441 ms / 411 MB (`research/19` §3). **The lesson for a daemon is the general one: in an
arena, a quadratic is a leak.** Any per-rebuild structure that grows must live outside `Arena`.

**The bad news is `Schemes.Writer.attach`** (§2.6): it appends to `iface.symbols` every time, so a
re-checked module's symbol column grows without bound, and it drops three tables per call. A daemon
must rebuild the `Interface` from `Interface.build` (`src/resolve/Interface.zig:479-549`) before
re-checking, or fix `attach`.

**Memory ceiling, measured.** Peak RSS on the 100k corpus: `check --jobs=1` **38.0 MiB**,
`build --library --jobs=1` **103.8 MiB** *(measured)*. A resident daemon holding one project's
artifacts is therefore ~100 MiB at 100k lines — 1 kB per source line. Against `research/04`'s
warning about salsa's 2–4× blowups and 22–30 GiB regressions, this is a comfortable starting point,
but it needs a stated policy: **what does the daemon do at, say, 4 GiB?** Nothing in any document
says. Recommendation: a hard ceiling with a clean restart, not an LRU — the cold start budget is
120 ms and rebuilding from the disk cache is cheaper than evicting correctly.

### 4.2 The embedded `core/`

Core is nine `.beni` modules `@embedFile`d into the binary (`build.zig:241-246`,
`src/Session.zig:532-536`) and enumerated into the **same flat index space** as app files, at
whatever position `"core/Basics.beni"` falls in the global sort — there is no reserved block.
Consequence: **core's indices move whenever app paths change**, so a cache cannot assume core is
`0..8`.

**Cost of re-checking it, measured.** A single-module project (10 modules: core plus one app file)
profiles at 2.205 ms of `check` and under 10 ms end to end. So core costs ~4 ms of front end plus
check on this machine, cold, per process. In a daemon that is paid **once per process**, which
removes about a quarter of the 15 ms warm budget before anything else is done. Per *build*, today,
it is paid every time.

### 4.3 The whole-program serial floor — 4.68 ms before any incremental work

`--self-profile`, `beni build --library --jobs=1` on the 100k corpus *(measured)*:

| Phase | ms | n | O(?) |
|---|---:|---:|---|
| `check` (parent) | 71.19 | 634 | per module |
| `emit` | 58.02 | 1 | per module inside, serial loop |
| `solve` | 36.69 | 634 | per module |
| `constrain` | 15.95 | 634 | per module |
| `lower` | 14.58 | 634 | per file |
| `lex` | 12.32 | 634 | per file |
| `parse` | 10.38 | 634 | per file |
| `read` | 5.26 | 634 | per file |
| `resolve` | 3.05 | 634 | per module |
| `exhaustive` | 2.60 | 634 | per module |
| **`merge_interners`** | **1.36** | **1** | **whole project** |
| **`eliminate`** (DCE walk) | **1.33** | **1** | **whole project** |
| **`types`** (the type table) | **0.75** | **1** | **whole project** |
| **`graph`** | **0.65** | **1** | **whole project** |
| **`enumerate`** | **0.59** | **1** | **whole project** |

**The five whole-program serial passes total 4.68 ms at 100 159 lines — 31 % of the 15 ms warm
budget, spent before a single edited declaration is looked at.** Each is O(project), not O(edit):
`enumerate` sorts every path, `merge_interners` merges every worker's pool, `graph` builds every
edge, `types` walks every module's Bir, `eliminate` walks every declaration.

That is not a crisis — 4.68 ms leaves 10 ms — but it is the number M4's design has to hold flat as
projects grow past 100k lines, and three of the five have a cheap incremental form (`enumerate` and
`graph` only need redoing when the file set changes; `merge_interners` only for new identifiers).
`types` and `eliminate` are the two that genuinely rerun, and `backend.md` §9 already says so of
`eliminate`. **`types` has no such story and should get one** — it is also the source of §2.2.

### 4.4 Cancellation: there is none, by construction

The DAG driver uses `lockUncancelable` and `waitUncancelable` (`src/check/Check.zig:477-479`,
`:501`), deliberately. The only early exit is `d.failure`, set only from `Allocator.Error`
(`:346-348`, `:504-506`). `Session` spawns one 64 MiB thread and `join()`s it with no token
(`src/Session.zig:849-885`).

"Cancel the in-flight build" therefore means one of three things, and M4 must pick:

1. **Don't.** Let the in-flight build finish and queue the next request. Simplest; worst tail
   latency when a user types fast.
2. **A cooperative flag checked at module boundaries.** The DAG scheduler pops one module at a time
   under a mutex (`:464-498`); adding a `cancelled` check there is a handful of lines and bounds the
   wasted work at one module's check (≈0.1 ms at the corpus average). Per-module artifacts already
   land in their own slots, so a cancelled run leaves no torn state — *provided* §2.6's re-entrancy
   fixes have landed.
3. Thread cancellation. No.

**Recommend (2).** It is cheap, it composes with the LSP's "the user typed again" case, and the
per-module slot discipline already makes it safe.

### 4.5 Determinism: state the acceptance test now

CLAUDE.md rule 5 and §10 make one requirement, and M4 needs it in a sharper form than the existing
test asserts:

> **An incremental build's every output stream and output file must be byte-identical to a cold
> build of the same source tree.**

The existing determinism test (`tests/blackbox/blackbox_test.zig:457`) runs the corpus at `--jobs=1`
and `--jobs=8`, twice each, and byte-compares every stream and output file; `--stage=raw` exists
precisely so the *interface bytes* are covered and not just a printer's view of them
(`src/dump/interface.zig:37-45`). The extension is one more axis on the same matrix:

```
for each corpus project:
  cold   = build with an empty cache
  warm_k = for each single-file edit e in a fixed edit set:
             build with the cache warm, apply e, build again, revert e, build again
  assert bytes(warm_k final) == bytes(cold)        # every stream, every output file
  assert counters(warm_k) show the dependents were NOT re-checked
```

The second assertion is what `Profile`'s counters exist for (`src/Profile.zig:13-14`), and the
counters that must not move are named in `checker.md` §9: `unifications`, `generalisations`,
`instantiations`, `obligations`. Note the standing warning there — `instantiations` moved
73 934 → 55 231 in M2d as a *fix* — so the assertion has to be "did not move across this edit",
never a golden absolute.

**Diagnostics order** is the subtle half: they are gathered in file-index order and then stably
sorted by the schema's comparator (`src/Session.zig:16-27`, `:442-456`). An incremental build that
re-checks a subset must still emit the *whole* diagnostic set in that order — meaning **cached
diagnostics are part of the cached artifact**, which the code has anticipated (codes + offsets, four
modules).

---

## 5. Interactions with what just landed, and what is pending

- **Always-on DCE (M3c).** The walk reruns every build by definition (`backend.md:1313-1318`).
  `plans/dce-notes.md:140-142` estimated "microseconds" from 278 nodes on the null program;
  **measured at 100k lines: 1.33 ms** — cheap, but 9 % of the warm budget and O(declarations).
  `backend.md` §9's M4 bullet is right that the *edge lists* cache per module; §2.4 corrects what the
  key must cover. One thing the spec gets right and the code does not: *"a change to liveness is one
  more such input"* to §8.2's `emit` unit — yet `Emit.flush` rewrites every pending file every build
  (`src/js/Emit.zig:928-945`), so "one edit rewrites one small file" needs a write-skip that does not
  exist.
- **The release namer (M3c slice 2, in flight)** and **chunking (M3d)** both belong to `--release`,
  which is explicitly not the warm path (§9.5: *"`beni build` is dev… what §2's 15 ms warm budget is
  measured against"*; `backend.md` §10: *"M4 and chunking never meet"*). **No action.** The one
  M4-facing item from M3d's neighbourhood is `boundary.md` §5.3 — *"the manifest concept M4
  introduces should carry the set"* of (entry point, platform) pairs — and nothing forecloses it:
  `beni.json` has four keys parsed with `ignore_unknown_fields = true` precisely so *"M4's package
  manifest will be a superset rather than a replacement"* (`src/js/Manifest.zig:11-12`, `:27-28`).
- **Decision trees and the tail-call loop (M3b, landed).** Per declaration, inside `js/Lower`, no
  cross-module input. Cacheable with the rest of `JsIr`. No action.
- **Effects (`plans/effects-plan.md`, waiting on owner).** §3 of that plan already prices the
  interface change: two constant bits are *"three spare `Tag` values and cost zero words"*; a flag
  **variable** needs one word from a two-word `extra` header before the parameter range
  (`src/resolve/Interface.zig:180-184`); `Quantified` is already `words = 4` with bits 9–31 free.
  **Do not reserve the bits now** (D4): a reserved-but-unused field is dead bytes in the hash and in
  every `--stage=raw` golden. State a **format version in the cache header** — §8.3 requires one
  anyway — so adding them is a version bump and a cache discard, not a migration.
- **LSP (M5).** §4 makes the daemon its host. What the protocol must not foreclose, from
  `research/04` §8's `AnalysisHost`/`Analysis` and gopls' `cache.Snapshot`: an **immutable snapshot
  handle**, so a long query cannot be torn by an incoming edit; **unsaved-buffer overlays** —
  content supplied in the request rather than read from disk, which a content-hash key handles
  naturally and an mtime key would not; **position-level queries**, needing the lossless CST and IR
  positions (both built); **cancellation** (§4.4); and **partial results** — do not design a protocol
  whose only reply shape is "the whole build's diagnostics".

---

## 6. A slice plan

Style follows `plans/static-dispatch-spike.md` §8: each slice is spec-first, then implementation from
the spec, with fixtures that fail before and pass after, the three gates green, and a commit. A slice
that cannot be finished is not half-landed.

**Ordering note, taken honestly against §13.** §13 says *"Socket protocol, content-hash cache, mmap
artifacts, interface firewall, then the declaration-level graph."* This plan puts the **socket
last**, and the reason is the audit: four of the five findings in §2 are about *artifact identity*,
none of them is about a protocol, and all of them are testable through the existing black-box harness
with no protocol at all. A persistent on-disk cache used by plain `beni build`/`beni check` exercises
the cache key, the serialization, the remap, the firewall cutoff and the byte-identity acceptance
test — which is most of M4's risk — and it does it with fixtures the harness can already drive.
The socket then buys process start (measured at **under 10 ms end to end** on this machine for a
hello-world, so the daemon's headline win is real but smaller here than `research/04` §8's "tens of
milliseconds") plus the in-memory hot path. **Recommend: cache first, socket after.** Owner decision
D1.

| Slice | Work | Fixtures / gates | Measurement |
|---|---|---|---|
| **M4-0 — single-module check against a serialized interface** *(slice zero)* | Spec: a `.beni-iface` on-disk form, its header (magic, format version, compiler build id, content hash), and `beni check --interface=<dir>` reading it. Code: write/read the `Interface` record; the `symbols` column as text + re-intern on load; a per-module `Check` entry point. **Includes the §2.2 fix** — `Term.app`/`Term.alias` stop carrying a session `TypeId` | `check/iface/` corpus kind: for every existing `check/good` project, (a) cold whole-project `--stage=raw` and (b) per-module check from serialized interfaces produce **identical** bytes; the §2.2 fixture — add a private type to an earlier module, assert an untouched module's `--stage=raw` is unchanged (**fails today**, proven in §2.2); round-trip test at every `--jobs` | none yet; this slice is what makes measurement possible |
| **M4-1 — the content-hash cache key** | Spec: the key as §8.1 + `boundary.md` §7.3 + `backend.md` §9 define it, with the `stat` fast-path covering sibling `.js`. Code: hash source bytes, module identity, compiler build id, direct imports' interface hashes, sibling hashes; a `SourceStore` size/mtime/inode column (there is none today, `src/SourceStore.zig:67-85`); the **"produced by a clean check" bit** of §3.2 | `check/bad` fixture: a module cached while broken is never reused; a fixture proving a sibling `.js` edit invalidates only that module's emit unit; a fixture proving a compiler-build change discards the whole cache | cache-key computation time as a `--self-profile` row; must be « 1 ms at 100k |
| **M4-2 — BIR and AST on disk** | Spec: §8.3's header + byte-range format; **pre-resolve BIR only** (§2.3); `Lower.Options` in the key. Code: write and mmap `Ast`, `Bir`, tokens, comments, diagnostics; `JsIr.verify`-style validation on load | The existing corpus, built twice: second build byte-identical, and `--self-profile` shows `lex`/`parse`/`lower` at ~0 for unchanged files. A **corrupt-cache** fixture per artifact: truncated, wrong version, wrong build id, garbage — each must be refused, never crash (`Interface.zig:357-366`'s posture generalised) | cold start with a warm cache against §2's **< 120 ms**; front-end phases (`read`+`lex`+`parse`+`lower` = 42.5 ms *(measured)*) should go to near zero |
| **M4-3 — the firewall cutoff** | Spec: the two-state rule (hash unchanged → dependents not re-checked). Code: compare the freshly computed interface hash against the cached one; skip dependents whose inputs are all unchanged. **Requires §2.6's five re-entrancy fixes and §2.4's three corrections** | The **incremental-determinism matrix** of §4.5 over the whole corpus; counter assertions (`unifications`/`instantiations` did not move) per `checker.md` §9; the annotated/unannotated churn split of §3.3 turned into fixtures | the three warm budgets: **15 ms**, **60 ms**, **25 ms**. This is the slice §2 exists to make measurable |
| **M4-4 — whole-program passes made incremental** | Spec: a story for `Types` (§4.3 — the one whole-program pass with no plan), and per-module Reach edge lists cached per `backend.md` §9. Code: cache edge lists; make `types` incremental or prove it need not be | edge-list cache byte-identity; a fixture where an edit flips a declaration's liveness and exactly one output file changes | the 4.68 ms serial floor; target: flat as the project grows |
| **M4-5 — the daemon** | Spec: the socket protocol (framing, request set, versioning, cancellation), the memory ceiling policy, watch vs explicit request. Code: `beni daemon`, the thin client, `inotify` | the daemon harness of §6.1 | warm rebuild end to end including client round-trip |
| **M4-6 — the declaration-level graph (§8.2)** | Only if M4-3's measurements demand it. Four unit kinds, two-phase marking. §14 #3's discipline applies: resist adding kinds without a measurement | per-unit invalidation fixtures | the 15 ms budget, again — this slice's justification is whatever M4-3 leaves on the table |

### 6.1 How the black-box harness drives a daemon

`tests/blackbox/world.zig` already spawns the real binary as a subprocess with both pipes drained,
a single `poll` deadline, and kill-and-reap on every exit path (`:11-25`, `timeout_ms = 60_000`).
The daemon extension is one new type beside `World`, and it must keep every property that makes the
existing harness a black box — no compiler internal linked, a replacement environment, a temp
project dir:

```
DaemonWorld = World + {
    socket: []const u8,        // <tmp>/beni.sock — inside the world, never /tmp
    daemon: std.process.Child, // spawned `beni daemon --socket=<socket> --jobs=N`
}

  init      spawn the daemon; poll the socket path until connectable or the deadline;
            a daemon that does not come up is a test failure, never a skip
  request   run the ORDINARY client: `beni build --socket=<socket> …` as a subprocess,
            so a scenario asserts on the same {exit_code, stdout, stderr, diagnostics}
            shape every existing scenario does
  edit      write a file, then request again — this is the warm path
  counters  read the daemon's `--self-profile` output, which is how a scenario asserts
            "dependents were NOT re-checked"
  deinit    send a shutdown request, then kill-and-reap on the deadline; assert the
            daemon exited cleanly, because a leaked daemon poisons the next test
```

Two rules the contract needs from the start: **one daemon per `DaemonWorld`**, keyed on its own
socket path inside the temp dir, so tests never share a resident process; and **every scenario must
also pass with no daemon**, driving the same assertions through plain `beni build`. That second rule
is what keeps the cache-first ordering honest — the warm-path fixtures of M4-1..M4-4 all run against
the on-disk cache, and M4-5 re-runs them through the socket.

---

## 7. Owner decisions

**D1 — Disk cache before the daemon, or §13's order?** (a) §13 as written, socket first.
(b) Persistent on-disk cache used by plain `beni build`/`check` first; daemon after.
→ **(b).** Four of five audit findings are artifact-identity problems a protocol neither causes nor
solves, and every one is testable through the existing harness. Process start is under 10 ms here
*(measured)*, so the daemon's headline win is smaller than `research/04` §8's "tens of milliseconds"
suggests and it can wait. Amend §13 in place if taken.

**D2 — Fix the interface's `TypeId` leak now, or after effects/M3d?** (a) Now, in slice zero.
(b) After the record has stopped changing.
→ **(a), and this is the one genuinely cheaper now.** It is two term tags; the cost of deferring is
re-blessing the `--stage=raw` and `.iface` goldens once per intervening milestone. It is also the
difference between a firewall that fires and one that does not.

**D3 — Spike-and-measure, as static dispatch was, or build straight to spec?** (a) A throwaway spike
faking a cache for early warm numbers. (b) Build M4-0..M4-3 on `master` behind a flag.
→ **(b).** Dispatch was spiked because the question was *"is the feature worth its cost"* — a
decision. M4 has none: §13 already committed to it. What M4 needs is the warm number, and M4-0
produces it on the first slice; a spike would duplicate the serialization that *is* the deliverable.

**D4 — Reserve effects' two interface bits now?** (a) Reserve. (b) Rely on the cache format version.
→ **(b).** See §5. Constant bits cost zero interface words; a reserved field is dead bytes in the
hash and in every golden; §8.3 requires a version anyway.

**D5 — Ordering against M3c-slice-2 (`--release`), M3d and effects.**
→ **`--release`, then M4-0..M4-3, then effects, then M3d.** `--release` is in flight in a worktree
and half-landed is worse than either order; M4 does not touch the release path at all (§5); doing
effects *after* the record is cacheable means the format-version mechanism is already there to absorb
them; M3d is hard-blocked on effects anyway (`plans/m3d-plan.md` §2) and never meets the warm path.

**D6 — Socket protocol.** (a) LSP/JSON-RPC from the start. (b) A private length-prefixed binary
framing, LSP translated by a separate `beni-lsp` front end. (c) Newline-delimited JSON.
→ **(b).** §4 says the LSP server and `beni build` are the same *process type*, not the same
*protocol*; a build client asking "rebuild and tell me what you wrote" should not pay JSON-RPC's
shape. A framed binary message with a version word costs a day and keeps the counter channel cheap.
Reversible — an LSP front end layers over it.

**D7 — Memory ceiling policy.** (a) None. (b) A hard ceiling with clean restart. (c) LRU eviction.
→ **(b).** Baseline is ~100 MiB per 100k lines *(measured)* and a warm cold-start is budgeted at
120 ms — cheaper than getting eviction right. `research/04` §6a: salsa's LRU work took three passes
to go 8 GiB → 3.4 GiB and was still *"a structural cost, not a one-time bug"*. Do not start there.

**D8 — File watching, or explicit requests?** (a) `inotify` in the first daemon slice, per §4.
(b) Explicit requests only; watching in M5 with the LSP.
→ **(b) for M4-5, (a) in M5.** A build client knows when it wants a build; a watcher's value is the
editor case. §4's argument against polling is about *how* to watch, not *when*.

**D9 — Cancellation semantics.** → the cooperative per-module flag, §4.4 option (2).

*Decided 2026-10-03 by the owner*, after [`research/53`](../docs/design/research/53-daemon-prior-art.md)
(sixteen daemons' choices and failures): **D6–D9 as recommended above, with these additions.**
- **D6:** the protocol carries unsaved-buffer contents and immutable snapshot handles from its
  first version. The daemon is keyed by the compiler build id: a client whose id differs replaces
  the daemon rather than talking to it (Bazel's rule; version skew is the most-reported daemon
  failure — gopls, tsserver, Gradle, Kotlin, dune). The socket lives inside the project, not in
  `$TMPDIR` (gopls #41266), and a stale socket or lock is detected and removed, never trusted.
- **D7:** the ceiling is a flag with a default of 2 GiB, about 20× the measured 100k-line baseline;
  at the ceiling the daemon restarts cleanly from the on-disk cache.
- **D8:** when watching arrives with the LSP, the editor's change notifications are the default
  source (gopls's default); a beni-owned OS watcher, if ever, is opt-in — watchers are research 53's
  largest source of reported failures (inotify limits, FSEvents rename recrawls, watcher feedback
  loops, Windows).
- **D9:** an edit that arrives mid-build may be merged into the running build instead of cancelling
  it (Sorbet, esbuild); the specification chooses per request. Nothing is ever killed mid-write
  (Bazel's third Ctrl-C loses its whole cache).
- **D10 — idle shutdown** (new): the daemon exits after a period with no clients, as every daemon in
  research 53 does (gopls 1 min, Gradle and Bazel 3 h); the default is the specification's to set.

---

## 8. Risks, and what could not be determined

**Risks**

1. **The `TypeId` fix has a blast radius nobody has scoped.** §2.2's smallest fix touches
   `Schemes.Writer` (`src/check/Schemes.zig:325`, `:369`), `Schemes.instantiate` (`:716`, `:762`),
   and every `--stage=raw` golden. If the right answer turns out to be "make `Types` incremental"
   rather than "change two tags", the slice is much larger.
2. **The evidence-numbering ABI is unvalidated across artifacts.** Callee and caller compute the
   hidden-parameter order independently — `Schemes.quantifierOrder` (`:449-473`, *"This must agree
   with `Writer.writeVar` exactly… a disagreement is a silent miscompile rather than a diagnostic"*)
   versus `Schemes.instantiate`'s loop (`:571-573`). A **cached** interface plus a **recompiled**
   dependent is exactly the configuration that can disagree, and nothing checks it. This deserves a
   fixture in M4-0.
3. **`Cycles.zig` and `Reach.zig` duplicate one edge walk with nothing mechanical keeping them in
   step** (`src/check/Cycles.zig:51-56`; queue.md item 26). Two caches of one graph is worse than
   one. Hoist before M4-4.
4. **`<error>` interfaces in a cache** (§3.2). Without the clean-check bit, a cached broken module is
   a silent exit-0 hole — the one failure mode `checker.md` §7 says a compiler may not have.
5. **The audit was read, not run.** Everything in §2 except the §2.2 demonstration is a reading of
   the code. A spike would find things a reading does not; CLAUDE.md rule 3's own warning ("a green
   suite has repeatedly coexisted with real defects") cuts both ways.

**Could not determine**

- **What a warm rebuild actually costs.** Nothing warm exists and §3.4 shows it cannot be simulated
  today. Every budget number in §1.1 is unvalidated. This is the largest gap and slice M4-0 is
  aimed at it.
- **What a changed interface costs an importer** — report 19 §16's own gap, still open for the same
  reason.
- **Whether the 4.68 ms serial floor grows sub-linearly or linearly past 100k lines.** One corpus
  size was measured; `bench/gen.zig --generate=` can produce more, and should before M4-4.
- **Whether `--jobs` parallelism survives incrementality.** `research/04` §5 warns that at a 15 ms
  budget thread wake-up can exceed the work, and §10 says *"do not parallelise the warm single-edit
  path."* Unmeasured here.
- **How large the on-disk cache is.** Proxy only: `dump --stage=raw` over the whole 100k corpus is
  1 811 923 bytes of *text* against 1 835 956 bytes of source *(measured)* — so interfaces alone are
  roughly source-sized in their printed form. The binary form will be smaller and BIR/AST larger;
  nobody has measured the total.
- **Whether the `beni.json` superset can express (entry point, platform) pairs without breaking the
  four keys M3a reads.** `boundary.md` §5.3 requires it; `src/js/Manifest.zig:27-28`'s
  `ignore_unknown_fields` suggests it is fine; nothing has been drafted.

---

## 9. Corrections made to `fast-compiler.md`

Three in-place dated notes, no section renumbered, no section added:

1. **§5.1** — SSO and the sharded global pool are stated as decisions; neither is implemented, and
   symbol numbering varies with `--jobs`.
2. **§8.1** — the interface record as landed embeds session-global `TypeId`s, so it is not yet a pure
   function of (source, imports' interfaces); and the cache key has grown by `boundary.md` §7.3's
   sibling hash.
3. **§14 #4** — the question's premise is overtaken: `Resolve` rewrites the BIR in place, so BIR and
   the resolved IR are already one array in two states.
