# Effect-TS v4's API surface, and what "Effect-level API coverage" means for beni

**Commissioned by** the project owner, 2026-09-19: *"Clone EffectTS locally. It's our gold standard.
I want to achieve EffectTS levels of quality and API coverage… Effect needs to deal with shit we
don't — like generators and TypeScript — but we should learn from them regardless."* Vendored as
`references/effect` and named in CLAUDE.md's *References* as the gold standard for the effects work.

This is one of three inputs to the effects spike's plan.
[`research/21`](21-effect-v4-runtime.md) covers the **runtime** — fibers, the scheduler, interruption
internals, the implementation of scopes — and this report cites it rather than duplicating it.
[`plans/effects-plan.md`](../../../plans/effects-plan.md) is the implementation work-up against the
repository, and its §5 decisions are separate from and prior to §9's here.

**What this report answers.** For every piece of Effect's API: is it (a) essential semantics beni
must offer to claim Effect-level coverage, (b) something beni gets for free or differently because
of its own design, (c) induced by TypeScript and unnecessary here, or (d) batteries that belong in
a platform package or a later release. The hard part is **translation**: the proposal
([`transparent-effects-proposal.md`](../transparent-effects-proposal.md)) deletes the `Effect` type,
so every API built on `Effect<A, E, R>` has to be re-expressed as functions with two inferred bits
over thunks — or conceded as absent.

Source: Effect-TS/effect `main` at `3d59ae6d5f9ff3e52cb6ed4a9f325320580218d5` (2026-09-19),
`packages/effect` **4.0.0-rc.116**. Every Effect name below was checked against that source; v3
names that no longer exist are marked as such, because half the available Effect material describes
a version this tree does not contain. beni claims are against `master` at `a718b65`.

---

## 0. Findings

**The one-line answer.** Effect's public core is **139 modules, 191 434 lines, 4 783 exports**.
About **34 %** of it by line count is filling a hole in TypeScript or in JavaScript's standard
library, and another **16 %** is `Schema`, a runtime re-implementation of the type system — so
**over half of Effect exists because of its host language**. Of what remains, the great majority
translates to beni's `let`, `case` and `Result` for nothing. **The kernel beni actually has to
build is one runtime primitive (the suspension protocol) plus a mutable cell**; everything Effect
calls `Queue`, `Semaphore`, `Pool`, `Cache`, `PubSub`, `Schedule` and STM is library code on top,
writable by an ordinary developer once the kernel exists. That last sentence is the answer to
CLAUDE.md rule 7's question — *what is the language withholding?* — and the answer is: almost
nothing, after the kernel.

### The coverage scorecard

Seventeen public families. Verdicts: **free** (beni's existing language deletes it), **T0/T1/T2**
(§8's tiers), **not needed**, **decision** (§9).

| # | Family | modules | lines | exports | verdict |
|---|---|---:|---:|---:|---|
| 1 | core `Effect` | 1 | 15 434 | 246 | ~95 **free**, ~30 **T1 core**, ~50 **T0/T1 runtime**, ~25 **decision**, ~26 **not needed** |
| 2 | errors & outcomes (`Cause`, `Exit`, `Result`, `Option`) | 4 | 6 209 | 205 | **free** for `Result`/`Option`; `Exit` is **D2**; `Cause` **not needed** |
| 3 | concurrency & coordination | 19 | 18 187 | 343 | **T0** ×4, **T1** ×4, **T2** ×11 |
| 4 | STM (`Tx*`) | 11 | 9 289 | 215 | **D3** — recommended out of scope |
| 5 | resources (`Scope`, `ScopedRef`, `Resource`) | 3 | 923 | 26 | **T0** for `Scope`, **T2** for the rest |
| 6 | services & config (`Context`, `Layer*`, `References`, `Config*`) | 8 | 9 051 | 181 | **D1** — the one family with no counterpart |
| 7 | scheduling & time | 6 | 8 141 | 232 | **T1** (`Schedule`, `Duration`, `Clock`); **T2** (`Cron`, `DateTime`) |
| 8 | streaming (`Stream`, `Channel`, `Sink`, `Pull`, `Take`) | 6 | 23 741 | 509 | **D5** — recommended **T2** |
| 9 | data structures | 22 | ~36 105 | ~894 | **not needed** — stdlib work, not effects work |
| 10 | equality, ordering, protocols | 13 | 12 294 | 298 | **free** — derived `eq`/`compare`, exhaustive `case` |
| 11 | schema & encoding | 10 | 32 692 | 1 164 | **not needed** — beni's compiler-derived codec (`boundary.md` §3.1) |
| 12 | observability (`Logger`, `Metric`, `Tracer`) | 5 | 5 808 | 111 | `Log` is **T1 and missing today**; `Tracer` is **D8**; `Metric` **T2** |
| 13 | platform abstractions in core | 8 | 4 249 | 80 | **platform packages** (`boundary.md` §2) |
| 14 | batching (`Request`, `RequestResolver`) | 2 | 1 921 | 43 | **T2** |
| 15 | testing (`TestClock`, …) | 4 | 1 578 | 22 | **T1**, and ranked second by value in §6 |
| 16 | TypeScript machinery | 12 | 7 307 | 215 | **not needed**, every one |
| 17 | `unstable/**` — the ex-platform packages | 232 | 129 498 | 3 401 | **platform packages and later** |

By family: **2 free, 3 T0/T1-with-runtime, 3 T1, 4 T2-or-platform, 4 not needed, 4 needing an
owner decision** (families 2, 4, 6, 8 each carry one; families 1 and 12 carry parts of D1/D2/D8).

### The ten findings, in order of value

1. **Effect v4 is beni's argument made by Effect's own authors.** In one major version they deleted
   `Either` for `Result`, collapsed `STM` into `Effect.tx`, deleted `Micro` because *"the rewritten
   Effect runtime is itself lightweight"*, **flattened `Cause` from a six-variant recursive tree to
   `{ reasons: Array<Fail|Die|Interrupt> }`**, collapsed `RuntimeFiber` into `Fiber`, deleted
   `Runtime<R>`, `Supervisor`, `RequestBlock`, `RuntimeFlags` and `FiberRefs`, merged four service
   idioms into one, and **deleted about twenty-five `Schedule` combinators** by replacing them with
   one metadata record. The direction of travel is fewer, flatter, non-recursive. §1.3.

2. **The kernel is one primitive.** Effect's interpreter has eighteen op tags, and every module in
   this report's §4 — `Deferred`, `Latch`, `Semaphore`, `Queue`, `PubSub`, `Pool`, `Cache`, `RcRef`,
   all eleven `Tx*` — is library code over **one** of them: `Effect.callback`, whose register
   function returns a cleanup effect that runs uninterruptibly on interrupt. That *is* the
   proposal's §6.1 suspension protocol and §6.4's `finalizers` list. So beni's privileged `foreign`
   surface for all of concurrency is the suspension protocol plus a mutable cell. §4.0.

3. **`catchTag` versus a `case` is the one row where beni's existing guarantee beats the gold
   standard.** Effect's error channel is a TypeScript union narrowed by a runtime `_tag` string,
   with no exhaustiveness obligation anywhere; beni's is an ADT matched by the checker with
   `missing_patterns`. The cost is that beni must declare a union type where Effect forms one for
   free. §3.2.

4. **`R`, the requirements channel, is the one part with no beni counterpart, and it should be
   conceded rather than argued away.** Four options exist — capability records (Elm's, and the
   proposal's own §9.3), `where`-clause constraints (already built), a fiber-local environment, or
   nothing — and between them they cover configuration, clients, test doubles, resource lifetimes
   and ambient values. **None recovers `R = never` at the entry point**: the compile-time proof that
   no dependency was forgotten. §3.3, decision D1.

5. **beni has no way to log from a shipped program.** `core/Debug.beni` is the only way to write a
   line and `--release` now refuses any build that reaches `Debug` (`debug_in_release`, 2026-09-19).
   No guarantee is at stake — this is a missing library, and CLAUDE.md rule 7 says a capability gap
   is filled inside the wall. §2 S18, §8's `Log`.

6. **`uninterruptible` is missing from the proposal's primitive list, and it is the answer to the
   proposal's own sharpest admitted risk.** §9.1 says a maintainer adding a log line can create an
   interruption point inside someone else's charge-then-reserve sequence, and that `bracket`'s
   implicit uninterruptibility *"is the right answer for a resource and no answer at all for a
   sequence"*. Effect has `uninterruptible`, `interruptible` and `uninterruptibleMask`. It costs
   nothing in the type system. Add it. §6 item 9, §8 T0.

7. **`Task.retry : Int, …` is the weakest signature in the proposal.** Effect's `Schedule` is a
   composable value — `exponential`, `spaced`, `recurs`, `jittered`, `while`, `min`, `max`, `tap` —
   consumed by both `retry` and `repeat`. It is pure data with a step function and needs **no
   runtime support at all**, so it can land in `core/` before the fiber runtime exists. §5.A, §8.

8. **Deterministic time is four functions and it is the highest-value thing Effect has that the
   proposal never mentions.** `TestClock.adjust(60_000)` makes a test that sleeps a minute run
   instantly. The whole mechanism is that `sleep` asks a *service* with a default rather than a
   `foreign`. beni's pitch is Elm's guarantees; "your concurrent code is testable" is a claim Elm
   has never been able to make. §6 item 2.

9. **`dual` is measurably the largest single TypeScript tax and beni deletes the whole category.**
   1 107 call sites across 115 non-`internal` files — 156 in `Stream.ts` alone — each a runtime
   `arguments.length` branch and two hand-written overloads, existing only because TypeScript cannot
   express "callable both ways". beni's `|>` is pipe-first *syntax*, every call is saturated, and
   the library is subject-first by convention. §7.4.

10. **Effect's platform split is `boundary.md`'s split, arrived at independently.** v4 moved every
    platform *interface* into core and left only `Layer`s in the adapter packages: 18 102 adapter
    lines against 362 457 core lines, `NodeFileSystem` in `node/` is 22 lines, and `Crypto.make`
    derives eleven service operations from **two** foreign functions. That is `boundary.md` §4's
    narrow-`foreign` rule and §5.1's "platforms are packages that depend on packages", confirmed
    from outside. §5.F.

### What surprised me

- **v4 deleted more than it added.** I expected a maturing library to accrete; it shed. The
  `Schedule` combinator cull (about 25 names replaced by `while` + `tap` over one metadata record)
  and the `Cause` flattening are the clearest cases, and both are arguments *for* the smaller
  design beni is proposing.
- **`Pull`'s trick is beni's `?`.** v4's newest streaming idea is to put end-of-input in the error
  channel as `Cause.Done`, so a pull is just an effect you can sequence. beni's `Result e a` plus
  `?` (`language.md` §6.6) is that, already in the language, with early return for free. §5.B.
- **`Effect.timeout` does not return an `Option`.** It widens the error channel with
  `Cause.TimeoutError`, and `timeoutOption` is a separate function. The proposal's
  `Task.timeout : … -> Maybe a` is the better of the two, and it got there by having no way to widen
  a closed ADT.
- **Effect's `Semaphore` is not FIFO** and documents the fact; its bare `take`/`release` pair is not
  interruption-safe and documents that too. Both are places to choose deliberately rather than copy.
- **`MaxOpsBeforeYield` is still 2048 in v4** (`Scheduler.ts:279`), unchanged since the version
  `research/16` §2.3 measured freezing an armed `setTimeout(0)` for 361 ms. beni's proposed 64 is a
  deliberate divergence from the gold standard and should stay one.

## Method

**What was read, and at which commit.** `references/effect`, Effect-TS/effect `main` at
`3d59ae6d5f9ff3e52cb6ed4a9f325320580218d5` (2026-09-19), `packages/effect` at **4.0.0-rc.116**. Read
in full: `README.md`, `LLMS.md`, `MIGRATION.md`, every file under `migration/` (14 files, 19 527
lines, of which `v3-to-v4.md` is 16 797 and is machine-generated from an API diff, `:5-9`), every
example under `ai-docs/src/` (49 files, 3 946 lines), and `packages/effect/*.md`. Read in part, by
targeted search and by section: `Effect.ts`, the concurrency and resource modules, the `Tx*` family,
`Schedule`, `Stream`/`Channel`/`Sink`/`Pull`, `Schema` and its siblings, `Config`/`ConfigProvider`,
`Layer`/`Context`/`References`/`ManagedRuntime`, the observability trio,
`packages/effect/src/testing/`, `packages/effect/src/unstable/**` and `packages/platform/src/**`.

On the beni side, at `master` (`a718b65`): `CLAUDE.md` whole — rules 6 and 7 in particular —
`transparent-effects-proposal.md` whole, `plans/effects-plan.md` whole, `language.md` whole,
`boundary.md` whole, `static-dispatch-spike.md` §1–§4, and `research/17` §4.14 and §5.1.
`research/16` is cited through the proposal and the plan rather than re-read; its subject is report
21's.

**Every Effect name here was checked against the v4 source.** v3 names that no longer exist are
called out as such (§2.1) rather than used.

**Counts.** Scripts in the session scratchpad, all run from `references/effect/`:

- `module-map.sh` — for every `.ts` under `packages/effect/src` excluding `internal/**`, emits path,
  lines, export count, `@since` and the first JSDoc prose line, as TSV; 375 rows. The export count
  is
  `grep -cE '^[[:space:]]*export[[:space:]]+(declare )?(abstract )?(async )?(const|function|interface|type|class|namespace|declare)\b'`.
  **Known limitation, because a §1.1 number depends on it**: it counts declaration forms only, so a
  barrel file reports zero — `index.ts` re-exports 138 namespaces with `export * as` and counts as 0.
  Non-barrel modules are unaffected.
- `classify.awk` — buckets those rows into (a) TypeScript machinery, (b) data-structure
  re-implementation, (c) effect-related; the membership is listed in §7 so the cut can be re-taken.
- `erase.mjs` / `agg.mjs` — run Node 24's `stripTypeScriptTypes` over each file and count the
  non-comment code lines that vanish. This is §5's "type-only %".
- `count.sh` — per-module export counts split by declaration kind, for §4.
- a per-category pass over `Effect.ts` grouping its exports on the file's own `@category` banners.

**Two counts of `Effect.ts`'s exports disagree and both are given.** The category pass says **246**,
treating the five reserved-word aliases (`export { void_ as void }` and friends) as one each and
excluding re-declarations; `module-map.sh` says **258**, because it counts declaration-merged names
twice (`TypeId` is a `type` and a `const`; `gen` and `fn` are each a `const` and a
`declare namespace`). Nothing turns on the difference. The line count is 15 434.

**Out of scope**: the fiber runtime, the scheduler, interruption internals and the implementation of
`Scope` — report 21's, commissioned in parallel. **Could not determine** items are in §10.

---

## 1. The module map

### 1.1 The size of the thing

| Scope | files | lines | exports |
|---|---:|---:|---:|
| `packages/effect/src` overall, including `internal/` | 493 | 362 457 | 9 621 |
| excluding `internal/` — the public surface | 375 | 322 510 | 8 206 |
| `internal/` only | 118 | 39 947 | 1 415 |
| **top-level `effect/*` only** | **139** | **191 434** | **4 783** |
| `unstable/**` | 232 | 129 498 | 3 401 |
| `testing/` | 4 | 1 578 | 22 |

The number that matters for "what is Effect's API" is **139 modules and 4 783 exports**, because
`unstable/**` is the ex-`@effect/platform`, `rpc`, `cluster`, `cli`, `sql` and `ai` packages moved
inside core in v4 and held to a weaker compatibility promise (`MIGRATION.md:22-26`, `:40-50`). Those
are batteries, and §5 treats them as such.

Largest modules: `Effect.ts` 15 434, `Schema.ts` 15 423, `Stream.ts` 11 864, `Channel.ts` 8 923,
`Graph.ts` 8 530, `SchemaAST.ts` 5 201, `Array.ts` 5 000, `Metric.ts` 3 529,
`SchemaRepresentation.ts` 2 927, `Chunk.ts` 2 878, `DateTime.ts` 2 874, `PubSub.ts` 2 816,
`Layer.ts` 2 802, `Match.ts` 2 682, `Option.ts` 2 483.

### 1.2 The families, and this report's verdict on each

| Family | modules | lines | exports | Verdict |
|---|---:|---:|---:|---|
| **core `Effect`** — `Effect.ts`. §2 is its inventory | 1 | 15 434 | 246 | see §2.3 |
| **errors & outcomes** — `Cause` 1 839/80 (flat `{reasons}` in v4), `Exit` 1 035/31, `Result` 1 852/47 (**new; `Either.ts` does not exist**), `Option` 2 483/67 | 4 | 6 209 | 205 | `Result`/`Option` **free** (`core/Result.beni`, `core/Maybe.beni`); `Exit` **D2**; `Cause` **not needed** |
| **concurrency & coordination** — `Fiber`, `FiberHandle/Map/Set`, `Deferred`, `Latch`, `Semaphore`, `PartitionedSemaphore`, `Queue`, `PubSub`, `Ref`, `SynchronizedRef`, `SubscriptionRef`, `MutableRef`, `Pool`, `Cache`, `ScopedCache`, `RcRef`, `RcMap`. §4 | 19 | 18 187 | 343 | **T0** ×4, **T1** ×4, **T2** ×11 |
| **transactional memory** — `TxRef` 291/7, `TxChunk` 852/22, `TxQueue` 1 512/37, `TxHashMap` 2 109/38, `TxHashSet` 941/23, `TxSemaphore`, `TxReentrantLock`, `TxDeferred`, `TxPriorityQueue`, `TxPubSub`, `TxSubscriptionRef` | 11 | 9 289 | 215 | **D3** — recommended out of scope |
| **resources** — `Scope` 545/17, `ScopedRef` 194/6, `Resource` 184/6, plus `Effect.ts`'s 15 | 3 | 923 | 26 | **T0** (`Task.scope`, `Task.bracket`); rest **T2** |
| **services & config** — `Context` 1 332/35 (**rewritten**), `Layer` 2 802/54, `LayerMap`, `LayerRef`, `ManagedRuntime`, `References` 674/13, `Config` 1 626/37, `ConfigProvider` | 8 | 9 051 | 181 | **D1** — §3.3, §5.E |
| **scheduling & time** — `Schedule` 1 517/39, `Duration` 1 798/57, `DateTime` 2 874/110, `Cron` 1 318/14, `Clock` 326/6, `Scheduler` 308/6 | 6 | 8 141 | 232 | **T1** (`Schedule`, `Duration`, `Clock`); **T2** (`Cron`, `DateTime`) |
| **streaming** — `Stream` 11 864/247, `Channel` 8 923/157, `Sink` 2 205/82, `Pull` 392/15 (**new**), `Take` 46/2, `ChannelSchema` 311/6 | 6 | 23 741 | 509 | **D5** — recommended **T2** |
| **data structures** — `Array` 5 000/142, `Chunk`, `HashMap`, `HashSet`, `Trie`, `Graph` 8 530/138, `HashRing`, `Record`, `Struct`, `Tuple`, `Iterable`, the `Mutable*` four, `BigDecimal`, `String`, `Number`, `Boolean`, `BigInt`, `RegExp`, `ByteSize` (**new**) | 22 | ~36 105 | ~894 | **not needed** — stdlib work, not effects work |
| **equality, ordering, protocols** — `Equal`, `Hash`, `Equivalence`, `Order`, `Ordering`, `Combiner` (v3's `Semigroup`), `Reducer` (v3's `Monoid`), `Data`, `Filter`, `Predicate`, `Match`, `Option`/`Result` | 13 | 12 294 | 298 | **free** — derived `eq`/`compare` and exhaustive `case`; §7.1 |
| **schema & encoding** — `Schema` 15 423/549, `SchemaAST` 5 201/170, `SchemaRepresentation`, `SchemaGetter`, `SchemaTransformation`, `SchemaIssue`, `SchemaParser`, `StandardSchema`, `JsonSchema`, `Encoding` | 10 | 32 692 | 1 164 | **not needed** — beni's compiler-derived codec (`boundary.md` §3.1); §5.C |
| **observability** — `Logger` 1 147/25, `LogLevel`, `Metric` 3 529/53, `Tracer` 748/22, `ErrorReporter` (**new**) | 5 | 5 808 | 111 | `Log` **T1 and missing today**; `Tracer` **D8**; `Metric` **T2** |
| **platform abstractions in core** — `FileSystem` 1 123/20, `Path`, `Terminal`, `Stdio` (**new**), `Crypto` (**new**), `Console`, `Random`, `PlatformError` | 8 | 4 249 | 80 | **platform packages** (`boundary.md` §2); §5.F |
| **batching** — `Request` 606/21, `RequestResolver` 1 315/22 | 2 | 1 921 | 43 | **T2**; §6 item 7 |
| **testing** — `TestClock` 614, `TestConsole`, `TestSchema` | 4 | 1 578 | 22 | **T1**; §6 item 2 |
| **TypeScript machinery** — `HKT`, `Unify`, `Types`, `Pipeable`, `Effectable`, `Function`, `Inspectable`, `Utils`, `Brand`, `Newtype`, `Symbol`, `UndefinedOr` | 12 | 7 307 | 215 | **not needed**, every one; §7.1 |
| **`unstable/**`** — 20 subtrees: `ai` 21 779, `cluster` 15 826, `http` 15 416, `cli` 13 361, `httpapi` 8 761, `encoding` 7 875, `eventlog` 6 747, `rpc` 6 713, `reactivity` 6 414, `persistence` 6 130, `sql` 4 146, `workflow` 3 750, `observability` 2 976, `schema` 2 620, `net` 1 927, `process` 1 385, `socket` 1 383, `devtools` 997, `workers` 667, `arbitrary` 625 | 232 | 129 498 | 3 401 | **platform packages and later**; §5.F |

(`arbitrary` and `net` are not in `MIGRATION.md:46-48`'s list of 18 unstable subtrees, which is
stale.)

### 1.3 What v4 moved, merged or dropped

This matters for one reason: **Effect spent a major version removing abstractions that a language
with real ADTs and a real effect system would never have had.** The direction is fewer, flatter,
non-recursive — and beni's design is at the destination already.

| v3 | v4 | Citation |
|---|---|---|
| `Either<R, L>` | **deleted**; `Result<A, E>` with `Success`/`Failure`, success-first | `migration/v3-to-v4.md:22`, `:690`; `Result.ts:66`, `:278`, `:305` |
| `Effect.either` | `Effect.result` | `Effect.ts:2275`; `:9879` |
| `STM` monad | **deleted**; `Tx*` structures returning `Effect`, wrapped by `Effect.tx` | `:729`, `:13614`; `Effect.ts:14609`, `:14735` |
| `TRef`/`TMap`/`TSet`/… | `TxRef`/`TxHashMap`/`TxHashSet`/…; `TArray` and `TRandom` **dropped** | `:24-33`, `:742`, `:748` |
| `Cause` as a 6-variant recursive tree | **flattened** to `{ reasons: Array<Fail\|Die\|Interrupt> }`; `Empty`, `Sequential`, `Parallel` removed | `migration/cause.md:3-26`; `Cause.ts:75-78`, `:144` |
| `Context.Tag`, `GenericTag`, `Effect.Tag`, `Effect.Service` | all four **collapsed** into `Context.Service` | `migration/services.md:1-8`; `Context.ts:201` |
| `Effect.Tag` static accessors | **removed** — "generic methods lost their type parameters" | `migration/services.md:74-83` |
| `FiberRef`, `FiberRefs`, `Differ` | **removed**; `Context.Reference` + `References` | `migration/fiberref.md:1-8` |
| `Runtime<R>` | **removed**; `Context<R>` + `Effect.run*With`; the module is now `Teardown`, `defaultTeardown`, `makeRunMain` | `migration/runtime.md:15-17`, `:84-88` |
| `Micro` | **deleted** — "the rewritten Effect runtime is itself lightweight and replaces it" | `:717`, `:12256` |
| `Supervisor` | **removed** — "use structured concurrency or explicit `FiberSet`/`FiberMap`" | `:16017` |
| `RequestBlock` | **removed**, made private | `:726`, `:13410` |
| `RuntimeFiber`, `Fiber.Descriptor`/`Dump`/`Order` | collapsed into one `Fiber` (620 lines), **no longer an `Effect`** | `:10969-10989` |
| `Ref.Synchronized` | top-level `SynchronizedRef`, no longer extending `Ref`; `Ref` no longer an `Effect` | `:13328`, `:16039-16047` |
| `catchAll`/`catchAllCause`/`catchAllDefect`/`catchSome*` | `catch`/`catchCause`/`catchDefect`/`catchFilter`; `catchSomeDefect` removed | `migration/error-handling.md:172-182` |
| `Effect.fork`/`forkDaemon` | `forkChild`/`forkDetach`; `forkAll` and `forkWithErrorHandler` removed | `migration/forking.md:8-15` |
| `Scope.extend` | `Scope.provide` | `migration/scope.md:1-3` |
| `List`, `RedBlackTree`, `SortedMap`, `SortedSet`, `MutableQueue`, `Secret`, `FastCheck` | **dropped** | `:702`, `:724`, `:735-736`, `:719`, `:733`, `:692` |
| `TestClock`, `TestAnnotation*`, `TestServices` | `effect/testing/TestClock`; the rest deleted in favour of Vitest | `:754-762` |
| reference equality for plain objects | **structural by default**; `Equal.equals(NaN, NaN)` is now `true` | `migration/equality.md:99-124`, `:147-154` |
| `unsafeX` | `xUnsafe` everywhere (0 of the former, 83 of the latter) | `:13350` |

New in v4 with no v3 counterpart (`:314-356`, plus four the diff missed): `ErrorReporter`, `Filter`,
`JsonPatch`, `JsonPointer`, `Latch`, `Newtype`, `Optic`, `Pull`, `SchemaGetter`,
`SchemaRepresentation`, `Semaphore`, `Stdio`, `TxChunk`, `UndefinedOr`, and `ByteSize`, `Crypto`,
`LayerRef`, `StandardSchema`.

**One premise worth correcting for anyone else reading the tree.** A `ServiceMap` module existed
during v4 development and was **renamed back to `Context`** before RC
(`.changeset/pre/slow-beans-battle.md:28`). `grep -rn ServiceMap` over the whole repository returns
25 hits, all in CHANGELOGs or that changeset, none in any `.ts` source. There is no `ServiceMap.ts`.

## 2. `Effect.ts` itself, and the beni translation of every category

`packages/effect/src/Effect.ts` is **15 434 lines and 246 top-level exports**, and it is a pure type
facade: **there is no `export function` in the file at all** — every value is
`export const NAME: <overload set> = internal.NAME`, delegating to `internal/effect.ts`,
`internal/core.ts`, `internal/schedule.ts`, `internal/layer.ts`, `internal/request.ts` and
`internal/executionPlan.ts`. 228 of the 246 are runtime values, 18 type-only; **90.6 % of its code
erases** under `stripTypeScriptTypes`. 79 exports carry `@since 4.0.0`, so a third of the module is
new or renamed in this version.

### 2.1 The categories, with counts

Grouped on the file's own `@category` banners.

| Category | n | Names (v4, checked against the file) |
|---|---:|---|
| constructors | 24 | `succeed` `succeedNone` `succeedSome` `sync` `suspend` `promise` `tryPromise` `try` **`callback`** `fail` `failSync` `failCause` `failCauseSync` `die` `never` `void` `undefined` `yieldNow` `yieldNowWith` `withFiber` `withFiberSucceed` `gen` `fn` `fnUntraced` |
| converting | 6 | `fromResult` `fromOption` `transposeOption` `fromNullishOr` `effectify` `Effectify`[T] |
| mapping / sequencing / zipping | 15 | `map` `as` `asSome` `asVoid` `flip` `mapBoth` `flatMap` `flatten` `andThen` `tap` `zip` `zipWith` + 3 `*Eager` |
| error handling | 36 | the 13 `catch*` below, plus `result` `option` `exit` `mapError` `orDie` `orElseSucceed` `firstSuccessOf` `sandbox` `ignore` `ignoreCause` `eventually` `retry` `retryOrElse` `tapError` `tapErrorTag` `tapCause` `tapCauseIf` `tapCauseFilter` `tapDefect` `unwrapReason` `withExecutionPlan` `withErrorReporting` |
| collecting / concurrency | 13 | `all` `forEach` `partition` `reduce` `validate` `findFirst` `findFirstFilter` `head` `whileLoop` `filter` `filterMap` `filterMapEffect` |
| racing / forking | 9 | `race` `raceAll` `raceFirst` `raceAllFirst` · `forkChild` `forkIn` `forkScoped` `forkDetach` `awaitAllChildren` |
| resources & scope | 15 | `scope` `scoped` `scopedWith` `acquireRelease` `acquireDisposable` `acquireUseRelease` `addFinalizer` `ensuring` `onError`(+`If`/`Filter`) `onExit`(+`If`/`Filter`/`Primitive`) |
| interruption | 7 | `interrupt` `interruptible` `uninterruptible` `interruptibleMask` `uninterruptibleMask` `onInterrupt` `abortSignal` |
| services / context | 15 | `provide` `provideContext` `provideService` `provideServiceEffect` `setContext` `updateContext` `updateService` `updateServiceScoped` `context` `contextWith` `service` `serviceOption` `fiber` `fiberId` `clockWith` |
| scheduling & time | 16 | `repeat` `repeatOrElse` `forever` `replicate` `replicateEffect` `schedule` `scheduleFrom` `timeout` `timeoutOption` `timeoutOrElse` `delay` `sleep` `timed` (+`retry`, `retryOrElse`) |
| tracing / logging / metrics | 34 | 17 span functions led by `withSpan`; 12 log functions led by `log`, `logWithLevel`, `annotateLogs`, `withLogger`; 5 `track*` |
| running | 14 | `runSync` `runPromise` `runFork` `runCallback` and their `*With` / `*Exit` variants |
| do-notation / generators | 7 | `Do` `bindTo` `bind` `let` `gen` `fn` `fnUntraced` |
| caching | 3 | `cached` `cachedWithTTL` `cachedInvalidateWithTTL` |
| matching / filtering / predicates | 14 | 7 `match*`, `filterOrElse` `filterMapOrElse` `filterOrFail` `filterMapOrFail` `when`, `isFailure` `isSuccess` |
| batching / transactions | 5 | `request` `requestUnsafe` · `Transaction`[T] `tx` `txRetry` |
| models & type machinery | 13 | `TypeId` `Effect`[T] `Variance`[T] `Success`[T] `Error`[T] `Services`[T] `EffectUnify`[T] `EffectTypeLambda`[T] `EffectIterator`[T] `isEffect` `satisfiesSuccessType` `satisfiesErrorType` `satisfiesServicesType` |

The thirteen `catch*`: `catch` `catchTag` `catchTags` `catchReason` `catchReasons` `catchCause`
`catchDefect` `catchIf` `catchFilter` `catchNoSuchElement` `catchCauseIf` `catchCauseFilter`
`catchEager`. **`catchAll`, `catchAllCause`, `catchAllDefect`, `catchSome`, `catchSomeCause` and
`catchSomeDefect` are gone** (`migration/error-handling.md:172-182`).

**Nine names a v3 reader will reach for and not find**, which matters because most Effect material
online describes v3: `Effect.async` (it is `callback`, `:1229`), `Effect.either` (it is `result`,
`:2275`, and **there is no `Either.ts` module in v4 at all**), `Effect.fork` (`forkChild`, `:8578`),
`forkDaemon` (`forkDetach`, `:8704`), `timeoutFail`/`timeoutTo` (one function, `timeoutOrElse`,
`:4641`), `Effect.locally` (gone — `provideService` over a `Context.Reference`), `provideLayer`
(`provide` takes a layer), `withConcurrency` (concurrency is always an option object), and
`forkAll`/`zipLeft`/`zipRight` (removed outright).

### 2.2 The translations, side by side

Each row is real v4 code from the vendored tree, or a minimal program written against the signatures
cited above, beside its beni equivalent. Every beni snippet is valid under `language.md` **as it
stands today** except where marked **[P]**, which means it uses the proposal's semantics: an
effectful call looks like a call, deferral is a thunk, and `Task`/`Fiber`/`Scope` are its §6.5.
Verdicts: **free** (beni already does it), **core** (a beni function, no runtime), **runtime**
(needs the fiber runtime), **decision**, **cannot**.

**S1 — constructors.** *free.*
```ts
Effect.succeed({ env: "prod" })   // :999     Effect.fail(new ParseError({ input }))  // :1507
Effect.sync(() => Date.now())     // :1169    Effect.callback((resume) => …)          // :1229
```
```elm
{ env = "prod" }        Err (ParseError input)        Time.now ()   -- [P] a call performs
```
The 24-constructor family exists because an `Effect` is a *description*: you need ways to lift a
value, a thunk and a failure into it. beni has no description, so there is nothing to lift into.

**S2 — `Effect.gen` and `yield*`.** *free.*
```ts
Effect.gen(function*() { const u = yield* getUser(id); const p = yield* getPermissions(u); return { u, p } })
```
```elm
let  user = getUser id
     perms = getPermissions user
in { user = user, perms = perms }          -- [P]
```
`gen` is the workaround for not having direct style. `Effect.gen`, `Effect.fn`'s generator body,
`Do`/`bind`/`bindTo`/`let` — 7 exports plus `EffectIterator`, `Yieldable`, `Utils.ts` and
`Effectable.ts` — become `let`. **The largest single deletion in this report.**

**S3 — `flatMap` / `tap` / `andThen`.** *free.* 13 exports of monadic plumbing become `let` and the
value; where the subject is a `Result`, `core/Result.beni` and `?` already collapse the chain.

**S4 — `Effect.catch` (v3's `catchAll`).** *free.*
```ts
loadPort("80").pipe(Effect.catch((e) => Effect.succeed(3000)))     // :2694
```
```elm
case loadPort "80" of
    Ok port -> port
    Err _ -> 3000
```

**S5 — `catchTag` / `catchTags`.** *free, and beni is stricter.*
```ts
// LLMS.md:203-213
loadPort("80").pipe(Effect.catchTag(["ParseError", "ReservedPortError"], () => Effect.succeed(3000)))
```
```elm
type PortError = ParseError String | ReservedPort Int

case loadPort "80" of
    Ok port -> port
    Err (ParseError _) -> 3000
    Err (ReservedPort _) -> 3000
```
The `case` is exhaustive by the checker (`missing_patterns`); `catchTag` narrows a TypeScript union
by a runtime `_tag` string and carries **no exhaustiveness obligation anywhere** — a program that
handles two of three errors simply keeps the third in the channel. **This is the clearest row where
beni's existing guarantee beats the gold standard.** The cost: Effect forms the union
`ParseError | ReservedPortError` without declaring anything; beni declares `PortError`.

**S6 — `catchReason` / `catchReasons` / `unwrapReason`.** *free.* v4-only (`:2956`, `:3053`,
`:3197`): an error carries a `reason` field that is itself a tagged union, narrowed without removing
the parent from the channel.
```ts
// ai-docs/src/01_effect/04_errors/20_reason-errors.ts:31-38
Effect.catchReason("AiError", "RateLimitError", (r) => Effect.succeed(`Retry after ${r.retryAfter}`), …)
```
```elm
case callModel () of
    Err (AiError (RateLimitError retryAfter)) -> "Retry after ${retryAfter}"
    Err (AiError _) -> "Model call failed"
    Ok text -> text
```
Three exports plus a `TagsWithReason` type-level helper exist because TypeScript cannot match a
nested discriminated union in one construct. beni's `case` already nests.

**S7 — `result` / `option` / `exit`.** *free / free / **D2**.*
```ts
Effect.result(eff)  // Effect<Result<A,E>>  :2275     Effect.option(eff)  // :2318     Effect.exit(eff)  // :2360
```
```elm
loadPort "80"                      -- already a Result; nothing to convert
loadPort "80" |> Result.toMaybe
-- exit: no counterpart until D2 decides whether Exit exists
```

**S8 — `Effect.all` with concurrency.** *free (sequential) / **runtime** (parallel).*
```ts
Effect.all([fetchA, fetchB], { concurrency: 2 })     // :492 — heterogeneous tuple
```
```elm
let a = fetchA ()
    b = fetchB ()
in ( a, b )                                     -- [P] sequential: a let block already means this

let ( a, b ) = Task.par2 (\() -> fetchA ()) (\() -> fetchB ())   -- [P] both at once

let a = fetchA ()
    and b = fetchB ()                           -- [P] proposal §3.4's surface sugar
in ( a, b )
```
Effect's `all` is one function over a tuple *or* a record *or* an iterable, with the result type
computed by `All.Return`, a ~90-line conditional type (`:262-366`). beni needs an arity family
`par2`/`par3`/… for heterogeneous results — the cost of having no variadic tuple types, and
`Task.map2`–`map5`'s shape — plus a list version, plus `and` groups as compiler-known syntax.

**S9 — `forEach` with concurrency.** *free (sequential) / **core + runtime** (parallel).*
```ts
Effect.forEach([1,2,1,3,2], getUserById, { concurrency: "unbounded" })   // :777
```
```elm
List.map ids getUserById                                        -- [P] sequential, bit-polymorphic
Task.parAll 4 (List.map ids (\id -> \() -> getUserById id))     -- [P] bounded
```
Two notes. **`List.map` serving an effectful callback with no signature change is the single largest
thing the proposal buys** (§2) and is what Roc gave up. And **the bound on `parAll` is mandatory**:
`research/16` §3.4 measured 901 MiB against 78.6 KiB for the same 200 000 operations, and
*"`'unbounded'` is one word away from a number"*. Effect ships `"unbounded"` as a first-class
option; beni should not — a deliberate divergence from the gold standard. The ergonomic gap
(§6 item 10) is that an Effect user changes one option where a beni user must reach for a different
function and wrap each element in a thunk; `List.mapPar : List a, Int, (a -> b) -> List b` beside
`map` closes it and is **core**.

**S10 — error accumulation.** *core.*
```ts
Effect.validate(inputs, parse)           // Effect<Array<B>, NonEmptyArray<E>, R>  :621
Effect.partition(inputs, parse)          // Effect<[Array<E>, Array<B>], never, R> :533
Effect.all(effects, { mode: "result" })  // Effect<Array<Result<A,E>>, never, R>
```
```elm
List.map inputs parse |> Result.combineAll   -- Result (List e) (List a)   [core, D4]
List.map inputs parse |> Result.partition    -- ( List e, List a )         [core, D4]
List.map inputs parse                        -- List (Result e a) — free, it already is
```

**S11 — `race` / `raceAll` / `raceFirst`.** *runtime.*
```ts
Effect.race(primary, fallback)  // :4847     Effect.raceAll([a,b,c])  // :4771
Effect.raceFirst(a, b)          // first SETTLED, success or failure  :4904
```
```elm
Task.race [ \() -> primary (), \() -> fallback () ]      -- [P] proposal §6.5
```
The proposal has one `race`; Effect has four, separating "first to **succeed**" from "first to
**settle**" and giving each a binary and an n-ary form. That distinction is real and beni needs a
position on it. `research/16` §5.6 is emphatic that `race` must be built on `Task.scope`, not
`Promise.race`, *"because `Promise.race` forgets its losers"*.

**S12 — `timeout`. And v4's answer is not an `Option`.** *runtime.*
```ts
Effect.timeout(eff, "5 seconds")        // Effect<A, E | Cause.TimeoutError, R>  :4564
Effect.timeoutOption(eff, "5 seconds")  // Effect<Option<A>, E, R>               :4604
Effect.timeoutOrElse(eff, { duration, orElse })                                // :4641
```
```elm
Task.timeout (Duration.seconds 5) (\() -> fetch url)     -- [P] Maybe a
```
`timeout`'s `Cause.TimeoutError` exists because Effect's error channel is a union it can widen for
free. beni cannot widen a closed ADT, so the `Maybe` is not a simplification — it is the only shape
available, and it happens to be the better one. `timeoutOrElse` is `Maybe.withDefault`.

**S13 — `retry` and `repeat` with a `Schedule`.** *core (the schedule) + runtime (the sleeping).*
```ts
// ai-docs/src/06_schedule/10_schedules.ts:179-187, :214-218
const policy = Schedule.min([Schedule.exponential("250 millis"), Schedule.spaced("10 seconds")])
  .pipe(Schedule.jittered, Schedule.setInputType<HttpError>(), Schedule.while(({ input }) => input.retryable))
fetchUserProfile("user-123").pipe(Effect.retry(policy), Effect.orDie)
```
```elm
policy : Schedule HttpError
policy =
    Schedule.min (Schedule.exponential (Duration.millis 250)) (Schedule.spaced (Duration.seconds 10))
        |> Schedule.jittered
        |> Schedule.while (\err -> err.retryable)

loadUser : UserId -> Result HttpError Profile
loadUser id =
    Task.retry policy (\() -> fetchUserProfile id)      -- [P]
```
The proposal's `Task.retry : Int, (() -> Result x a) -> Result x a` is a *count*, and it is the
weakest signature in its §6.5 list. A `Schedule` is a state plus a step; none of it needs runtime
support, only the sleeping does. **core, and it should land as core.** `repeat` shares the type,
keyed on the success value instead of the error — one `Schedule`, two consumers.

**S14 — `acquireRelease` and `scoped`.** *runtime.*
```ts
// :6589, and ai-docs/src/01_effect/05_resources/10_acquire-release.ts:98-108
const t = yield* Effect.acquireRelease(Effect.sync(() => createTransport(opts)), (t) => Effect.sync(() => t.close()))
```
```elm
let conn <- Task.bracket (\() -> Db.open url) Db.close
in query conn "select 1"                        -- [P]; language.md §6.7 already parses this
```
`let x <- e` is what makes a bracket sit flat at the top of a block, and `fast-compiler.md` §9.3
item 7 says reaching `Task.bracket` and `Task.scope` was half the reason `<-` was generalised.
Effect's difference: `acquireRelease` puts `Scope` in `R` and `scoped` removes it, so the *type*
records an outstanding scope. `research/16` §5.3 row 2 says preventing a `Scope` from outliving its
block needs region or rank-2 typing and `checker.md` §6.3 forbids the addition — beni takes Trio's
position, the guarantee is the runtime's. Effect's 15 resource exports become three in beni
(`bracket`, `scope`, `Scope.finalizer`), because `ensuring`/`onError`/`onExit` and their
`If`/`Filter` variants are a `case` on the result plus a bracket.

**S15 — interruption. *The gap the proposal argues about and does not close.*** *runtime.*
```ts
Effect.uninterruptible(eff)                                   // :7387
Effect.uninterruptibleMask((restore) => …)                    // :7422
Effect.onInterrupt((interruptors) => cleanup)                 // :7354
```
```elm
Task.uninterruptible (\() ->
    let _ = charge account amount
        _ = reserve inventory item
    in ()
)                                       -- [P], and NOT in the proposal's §6.5 list
```
The proposal's §9.1 accepted risk is *"a new interruption point appears in the middle of someone
else's charge-then-reserve sequence three packages away"*, and it concludes there is no annotation
to catch it. There does not need to be: `uninterruptible` over a thunk is a **runtime** answer to a
**runtime** hazard, needs no bit in any type, and §9.1 itself says `bracket`'s implicit version *"is
the right answer for a resource and no answer at all for a sequence."* **Add it.**

**S16 — fork and join, and a naming trap.** *runtime.*
```ts
// ai-docs/src/09_testing/10_effect-tests.ts:175-182
const fiber = yield* Effect.forkChild(Effect.sleep(60_000).pipe(Effect.as("done")))
const value = yield* Fiber.join(fiber)
```
```elm
let fiber = Task.spawn (\() -> sleepThen (Duration.seconds 60) "done")
    value = Fiber.join fiber                    -- NOT fiber.join
in value                                        -- [P]
```
`static-dispatch-spike.md` §1.1: *"`x.m` with no arguments is never a method call … an application
with no arguments is not an application."* So `fiber.join` is a **field access** and does not
compile. Every nullary operation on a runtime handle is affected — `join`, `cancel`, `await`,
`Deferred.await`, `Queue.take`, `Ref.get`. The dot-call form works wherever there is at least one
argument: `queue.offer x`, `sem.withPermits 2 thunk`, `ref.update f`. **This should shape the API —
prefer operations that take an argument — and the spec should say so rather than let every user
discover it.** It is a rule, not a defect, and the effects API is its first large consumer.

**S17 — services.** ***D1.***
```ts
// migration/services.md:48-56, :107
class Database extends Context.Service<Database, { query(sql: string): Effect<Rows, DbError> }>()("Database") {}
Effect.provideService(program, Database, { query: (sql) => … })
```
```elm
-- R-A, a record argument:
type alias Database = { query : String -> Result DbError Rows }
program : Database -> Result DbError Rows
program db = db.query "select 1"

-- R-C, a where clause, and the compiler finds the implementation:
program : db -> Result DbError Rows
    where db.query : db, String -> Result DbError Rows
program db = db.query "select 1"
```
Both compile today; neither gives `R = never` at the entry point. §3.3.

**S18 — logging. *Missing entirely today.*** *core + runtime.*
```ts
Effect.logInfo(`Sent welcome email to ${to}`)      // :13859
Effect.annotateLogs({ method: "sendWelcome" })     // :14001
```
```elm
Log.info "Sent welcome email to ${to}"             -- [P] does not exist
Log.with "method" "sendWelcome" (\() -> …)         -- [P] does not exist
```
`core/Debug.beni:23` is the only way to write a line, and since 2026-09-19 a `--release` build that
reaches any `pub` value of `Debug` is refused (`debug_in_release`). **So a shipped beni program
cannot log** — a capability gap of exactly the kind CLAUDE.md rule 7 names. Note that Effect
implements `annotateLogs` as `updateService(effect, CurrentLogAnnotations, …)` (`:14018`), i.e. over
the fiber-local environment: **designing `Log` is what will tell you whether D1 needs option R-B.**

**S19 — `withSpan` and `Effect.fn`.** *core + runtime, later.*
```ts
// LLMS.md:70-86
export const f = Effect.fn("effectFunction")(function*(n: number) { … }, Effect.catch(…), Effect.annotateLogs(…))
```
```elm
effectFunction n = Trace.span "effectFunction" (\() -> …)     -- [P] does not exist
```
`Effect.fn` bundles three things Effect *had* to bundle: a tracing span, a stack frame the generator
destroyed, and generator-body reuse so a closure is not allocated per call. beni needs only the
first — §7.3–§7.4 of the proposal already require each continuation to carry the span of the call it
resumes, so the information is being computed anyway. D8.

**S20 — `cached`.** *core.*
```ts
Effect.cached(expensive)                        // Effect<Effect<A,E,R>>  :7122
Effect.cachedWithTTL(expensive, "1 minute")     // :7207
```
```elm
Task.cached : (() -> a) -> (() -> a)            -- [P] core, over a Ref + Deferred
```
A thunk in, a memoising thunk out. The `impure` bit exists to tell the *optimiser* it may not
memoise; this is the user asking for it, which is a different thing and is not in the proposal.

**S21 — running.** *platform.*
```ts
Effect.runPromise(program)   // :9030          NodeRuntime.runMain(program, { … })
```
```elm
main : Program
main = Node.run (\() -> program ())             -- [P], boundary.md §5
```
14 run functions become one entry point, because beni does not have the "run an effect from
non-Effect code" problem. What beni *does* inherit is keep-alive: v4 built reference-counted process
keep-alive into the core runtime (`migration/fiber-keep-alive.md:199-211`) because in v3 a program
parked on `Deferred.await` exited silently. D9.

**S22 — `Queue`.** *runtime.*
```ts
const q = yield* Queue.bounded<Job>(100);  yield* Queue.offer(q, job);  const job = yield* Queue.take(q)
```
```elm
let q = Queue.bounded 100
    _ = q.offer job                             -- dot-call: has an argument
    job = Queue.take q                          -- nullary: must be qualified (S16)
in handle job                                   -- [P]
```

**S23 — `Semaphore`.** *runtime.* `sem.withPermits 2 (\() -> work ())` against Effect's curried
`sem.withPermits(2)(work)` — a rare row where beni's dot-call reads better.

**S24 — `Effect.request` and `RequestResolver`.** *core, T2.* No counterpart; it is a `Deferred` per
request, a queue and a timer, all writable in beni once T0/T1 exist
(`ai-docs/src/05_batching/10_request-resolver.ts:115-129`). Worth naming as a target because it is a
differentiating feature and constrains nothing.

### 2.3 The score for `Effect.ts`

| verdict | ~n | what |
|---|---:|---|
| **free** | ~95 | constructors, gen/Do/bind, map/flatMap/tap/zip, the 13 `catch*`, `result`/`option`, match, predicates, filtering, the type machinery |
| **core** | ~30 | `Schedule` and its consumers, accumulation, `cached`, logging, `Duration`, `mapPar` |
| **runtime** | ~50 | fork/join, race, timeout, sleep, resources, interruption, `all` with concurrency |
| **platform** | ~20 | running, tracing, metrics |
| **decision** | ~25 | services/context (15), `exit`/`sandbox`/cause-related (~7), transactions (3) |
| **not needed** | ~26 | the nine `Eager` combinators, `Effectify`, `satisfies*Type`, `Unify`, `Variance`, dual overloads |

The biggest number is **free**, for one reason: direct style plus `Result` plus exhaustive matching
deletes the monadic plumbing and the error-channel API at once. The second biggest is **runtime**,
which is report 21's subject.

## 3. `Effect<A, E, R>`, parameter by parameter

The proposal deletes the type. `Effect<A, E, R>` is a value that *describes* a computation; beni has
no such value, only a function with two inferred bits whose call performs. Everything Effect
expresses by putting something in one of three slots, beni must express some other way or concede.

```ts
export interface Effect<out A, out E = never, out R = never> extends Pipeable, Inspectable {
  readonly [TypeId]: Variance<A, E, R>                                  // Effect.ts:117-123
  [Symbol.iterator](): EffectIterator<Effect<A, E, R>>
}
export interface Variance<A, E, R> { _A: Covariant<A>; _E: Covariant<E>; _R: Covariant<R> }  // :154-158
```

Three parameters still, same order, and in v4 **`R` is covariant** where v3 made it contravariant.

### 3.1 `A` — the success channel. Free, and the only one of the three that is.

`A` is the return type. `Effect<User, UserNotFound, Database>` is
`getUser : UserId -> Result UserNotFound User` with `suspends` inferred and the database reached
some other way (§3.3). `Effect<void>` is `()`; `Effect<never>` is `Never`, already a prelude type.

**One loss**: an `Effect` is a value, so it can be stored and run later. beni's equivalent is the
thunk `() -> a`, which is a value too, so the loss is only that a thunk carries no type-level record
of what it will do. `List (() -> Result HttpError Response)` is as expressible as
`Array<Effect<Response, HttpError>>`; what is not is `Array<Effect<…, Database>>`, and that is §3.3.

**One gain**: there is nothing to forget to run. Effect's commonest beginner error is building an
`Effect` and dropping it — the value is inert, nothing warns, the work silently never happens. beni
cannot have that for an ordinary call, and can have it only where the proposal makes thunks explicit
(`retry`, `timeout`, `race`, `spawn`) — a much smaller surface, with §3.3's `no_effect` warning
covering the adjacent case.

### 3.2 `E` — the error channel. Mostly free, partly better, three real gaps.

beni's answer is `Result e a` plus `?` (`language.md` §6.6), already in the language.

| Effect v4 | beni today | verdict |
|---|---|---|
| `Effect<A, E>` / `Effect.fail(e)` | `-> Result e a` / `Err e` | free |
| `Effect.mapError(f)` / `Effect.catch(h)` | `Result.mapError r f` / a `case` | free |
| `Effect.catchTag` / `catchTags` | a `case` arm on a constructor | **better** |
| `Effect.result` (`:2275`) / `option` (`:2318`) | it already is a `Result` / `Result.toMaybe` | free |
| `yield*` propagating `E` | `?` | free |
| `Effect.orDie` | see §3.2.2 | decision |

**`catchTag` versus a `case` is the one row where beni is strictly better, and it is worth being
precise about why.** Effect's error channel is a TypeScript *union* narrowed by a runtime `_tag`
string. Two consequences follow. The compiler cannot tell you that you forgot a member: `catchTag`
removes what it handled and leaves the rest in the channel, so a program handling two of three
errors simply keeps the third — there is **no exhaustiveness obligation anywhere**, except that
`runPromise` needs `E = never`. And the tag is a string matched at run time, made safe only because
TypeScript can infer the literal union.

beni's is a `case` on an ADT decided by the checker, with `missing_patterns` when an arm is absent
and `redundant_pattern` when one cannot be reached (`checker.md` §6.6). The error type is closed by
construction, the match exhaustive by construction, the tags constructors rather than strings.
**This is Elm's guarantee, and CLAUDE.md rule 7 says it is exactly the kind of rule that stays.**
The cost is the other side of "closed": beni cannot form the union of two error types without
declaring a third, which Effect does for free. In practice the Elm answer — declare the union where
you join the two calls — is what every Elm codebase already does.

#### 3.2.1 Error accumulation

v4 gives this three spellings, none of them v3's names. `Effect.all` takes
`mode?: "default" | "result"` (`:496-500`); `"result"` runs everything and returns
`Effect<Array<Result<A, E>>, never, R>` (`:279-283`). `Effect.validate` (`:621`, `:636-643`) returns
`Effect<Array<B>, Arr.NonEmptyArray<E>, R>` — every failure, accumulated — and `Effect.partition`
(`:533`) returns `Effect<[excluded: Array<E>, satisfying: Array<B>], never, R>`. The default
short-circuits; `forEach` has no `mode` at all.

beni has `"result"` for free: `List.map xs attempt` where `attempt` returns a `Result` *is*
`List (Result e a)`, and `Result.combine` collapses it short-circuiting. What is missing is
`validate`'s and `partition`'s shape — a `core/` function, not a language feature:

```elm
pub combineAll : List (Result e a) -> Result (List e) (List a)
pub partition  : List (Result e a) -> ( List e, List a )
```

Twenty lines, no runtime support. They need deciding only because the names and shapes want to be
right the first time (D4).

#### 3.2.2 Defects, and whether beni has any

Effect's `E` is half its failure story. It splits **failures** (typed, in `E`, recoverable) from
**defects** (untyped, a bug): `Effect.die(x)` makes one, `orDie` promotes a failure into one, an
uncaught `throw` inside `Effect.sync` becomes one. `Cause<E>` carries both plus interruption, and v4
flattens it to `{ reasons: Array<Fail<E> | Die | Interrupt> }` (`migration/cause.md:12-26`);
`Exit<A, E>` is `Success<A> | Failure<Cause<E>>` (`Exit.ts:59`) and is what `Fiber.await` gives you.

**beni's proposal has no word for any of this.** `research/16` §5.3 and §6.5 type
`Fiber.join : Fiber a -> Result Cancelled a`, a two-case answer where Effect has three. So: does
beni have defects, and what are they? Four candidates, and they are not the same kind of thing.

1. **A `foreign` that throws.** `boundary.md` §4.1's recipe says every privileged entry point is
   wrapped in `try`/`catch` and every specification-defined failure is a constructor — so under the
   recipe there is no such thing, and where there is, it is a bug in privileged code.
2. **`Debug.todo`** (`core/Debug.beni:32`), whose type is a lie by construction and which throws.
   `effects-plan.md` §7 names it as undecided. Since 2026-09-19 `--release` refuses any build that
   reaches `Debug`, so it cannot reach a shipped program — a development-only defect, which is a
   coherent position that should be written down rather than inferred.
3. **Stack overflow and out of memory.** Not expressible as a value on this target.
4. **An interrupted fiber** — which Effect calls a third thing with its own `Reason` variant, where
   the proposal puts it in the error channel and so forces every `join` to handle cancellation as
   though it were a domain error.

So beni has **one** defect source it cannot rule out (3), one ruled out by contract (1), one by
`--release` (2), and one that is not a defect but a third outcome (4). The shape it needs is
narrower than `Cause`:

```elm
type Exit a
    = Done a
    | Failed String       -- a defect: what nothing typed accounted for
    | Cancelled
```

with `Fiber.await : Fiber a -> Exit a` beside `join`. Note this is **not** a `Cause`: no tree, no
annotations, no error channel inside it, because beni's error channel is already `Result` *inside*
`a`. A fiber running `() -> Result HttpError Response` has `Exit (Result HttpError Response)`, and
the two levels are what Effect flattens into one `Cause`. That is a cleaner separation than
Effect's, and it falls out of having errors be values. **D2.**

Everything Effect builds on `Cause` — `sandbox`, `unsandbox`, `catchCause`, `catchDefect`,
`tapDefect`, `exit` — then has no beni counterpart. That is a real coverage gap and it is the right
one to accept: it is the API surface of a distinction beni does not make.

### 3.3 `R` — the requirements channel, and the part with no counterpart

**What `R` is.** A *set of service identifiers the computation needs and does not have*. It is
subtractive: `provideService` removes one, and `runPromise` requires `R = never`, so the type system
proves at the entry point that nothing is missing. In v4 a service is `Context.Service`
(`migration/services.md:48-56`), built with `Layer.effect`, composed with `Layer.provide`; layers are
memoised by identity; a layer may be scoped; `ManagedRuntime` builds the graph once for non-Effect
callers; and `Context.Reference` is the *defaulted* case, which is what v4 uses in place of v3's
`FiberRef` (`migration/fiberref.md:1-8`).

**What Effect users actually use it for** — five uses that should not be conflated:

| # | Use | Example in the tree | Needs a *type-level* channel? |
|---|---|---|---|
| U1 | configuration | `Config.String("SMTP_USER")` inside a layer (`ai-docs/…/10_acquire-release.ts:89`) | no — read at startup |
| U2 | clients and connections | `Smtp`, `Database`, `HttpClient` | no — a value the entry point makes |
| U3 | **test doubles** | `Layer.mock`, `TestClock` | **this is what pays for the channel** |
| U4 | resource lifetime | a layer whose build is `acquireRelease` | no — `bracket`/`scope` does it |
| U5 | **ambient, fiber-local values** | `References.CurrentLogLevel`, log annotations, `MaxOpsBeforeYield` | **yes, and it is a different mechanism** |

U5 is separate because Effect itself separates it: a `Context.Reference` has a default, never appears
in `R`, and its point is that a caller ten frames up can change it for the subtree without any
signature between mentioning it. That is dynamic scoping.

**Four options for beni, laid out, not chosen.**

**R-A — capabilities as arguments (Elm's answer, and the proposal's own §9.3).**
```elm
type alias Payments = { charge : Cents -> Result ChargeError Receipt }

processOrder : Payments, Order -> Result OrderError Receipt
processOrder payments order = Ok (payments.charge (total order)?)
```
*Serves*: U1, U2, U3 (pass a different record), U4. *Not*: U5. *Cost*: every function naming the
capability and every caller threading it — the complaint `R` exists to answer, though
`research/14/elm` found four companies with 300k lines between them not voicing it. **Beni cost:
zero.** It works today.

**R-B — a fiber-local environment, platform-provided.** The fiber record exists and carries a parent
chain (§6.4); a `Context` is a map from key to value read through that chain, exactly as v4's
`References` is.
```elm
Context.get  : Key a -> Maybe a
Context.with : Key a, a, (() -> b) -> b        -- dynamically scoped over the thunk
```
*Serves*: U5 exactly, U3 partly. *Not*: the proof that nothing is missing — `get` returns `Maybe a`,
so a missing service is a runtime `Nothing`. *Beni cost*: a `Key a` needs type-indexed identity,
which beni has no mechanism for; the honest spelling is a platform-minted `foreign type Key a` per
service, which is `boundary.md` §5's unforgeable capability. **Could not determine** whether that can
be made safe without a language feature — §10 item 1, and the one place this report thinks a spike
is needed rather than an argument.

**R-C — `where` clauses as the resolution mechanism.** beni already has constraints resolved
statically and passed as hidden evidence. `effects-plan.md` §2.1 already noticed this, calling a
user-written `where a.fetch : …` *"a capability record expressed one method at a time, which is P2
§9.3's own recommended granularity mechanism arriving for free."*
```elm
fetchUser : db, UserId -> Result DbError User
    where db.query : db, String -> Result DbError Rows
fetchUser db id = parseUser (db.query "select …"?)
```
*Serves*: U2 and U3 well — a test passes a different type whose module exports `query`. *Not*: U5 at
all, U1 awkwardly. *Limits, and they are real*: evidence resolves from the **type**, so there is one
implementation per type, a test double must be a different type, and an implementation cannot be
chosen at run time — which `Layer` can. Also, an inferred `where` suffix is capped at 64
(`static-dispatch-spike.md` §10.11) and report 19 §4 measured that constraints in an inferred
interface make it churn 6.5× more, so making this *the* DI mechanism loads cost onto the shape that
already has one. **Beni cost: zero; it is already built.**

**R-D — the platform is the environment.** `boundary.md` §5: *"Anything the platform manages is
handed to `init` as a value no other code can construct."* No injection mechanism at all; per-platform
compilation (§5.3) decides what resolves. *Serves*: U1, U2, U4. *Not*: U3, U5. **Beni cost: zero**,
and it is the status quo.

**My reading, offered as input.** R-A and R-D are already true and free; R-C is already built and
free; R-B is the only one needing new machinery and the only one serving U5 — which Effect itself
moved *out* of `R` because it is a different thing. So the shape covering the most ground for the
least language work is **R-A + R-C for services, R-B for ambient values**, and the piece to design is
R-B's key. What none of them recovers is **`R = never` at the entry point** — the proof that nothing
was forgotten — and that is the single largest thing on Effect's side of the ledger. It should be
conceded in writing rather than argued away. **D1.**

## 4. Concurrency and coordination primitives

### 4.0 What Effect's kernel actually is — the structural finding

**Effect's interpreter has eighteen primitive ops**, all in `internal/core.ts` and
`internal/effect.ts`. There is no opcode enum: a primitive is an object with a string `identifier`
and up to four methods — `[evaluate](fiber)`, `[contA]`, `[contE]`, `[contAll]`
(`internal/core.ts:365-381`, built by `makePrimitive` `:425`), and the set is **open**, since
`Effectable.Prototype({ label, evaluate })` (`Effectable.ts:32-42`) lets userland add ops.

`Success` / `Failure` (`core.ts:518`, `:538`), `WithFiber` / `WithFiberSucceed` (`:565`, `:580`),
`YieldableError` (`:592`), `Sync` / `Suspend` / `Yield` (`effect.ts:975`, `:987`, `:1028`),
**`Async` / `AsyncFinalizer`** (`:1156`, `:1202`), `Iterator` (`:1423`), `OnSuccess` / `OnFailure` /
`OnSuccessAndFailure` (`:1481`, `:2611`, `:3580`), `Exit` / `OnExit` (`:3754`, `:4142`),
`SetInterruptible` (`:4494`), `While` (`:4838`).

**Every module in this section is library code over those eighteen, and almost all of it over one**:
`Effect.callback` (`Effect.ts:1229`), whose `register` returns a cleanup effect that
`AsyncFinalizer` runs **uninterruptibly** when the fiber is interrupted (`effect.ts:1180-1186`,
`:1210-1214`). That single mechanism is why a cancelled waiter is removed from its waiter list in
`Deferred`, `Latch`, `Semaphore`, `PartitionedSemaphore`, `Queue`, `PubSub` and `Pool`.

**Read against `research/16` §5.3 and the proposal's §6.1, this is the same design.** beni's
`foreign suspends` primitive — "returns either a value or a suspension; a suspension is a
registration handed the fiber's resume callback" — *is* `Effect.callback`, and the fiber record's
`finalizers` list (§6.4) is `AsyncFinalizer`. **So the beni `foreign` surface for all of §4 is one
primitive plus a mutable cell**, which is far narrower than a module-by-module reading suggests and
is what makes CLAUDE.md rule 6 survivable here.

One number for report 21 to reconcile: v4's `MaxOpsBeforeYield` is still **2048**
(`Scheduler.ts:279`), checked once per op in `runLoop` (`effect.ts:671-682`) with the counter reset
on each resumption. `research/16` §5.5 recommends 64 (Cats Effect's) or 16 (Kotlin's), because §2.3
measured a `setTimeout(0)` armed at the start of a 2 000 000-op chain firing after **361 ms**. beni's
divergence from the gold standard here is deliberate and should stay.

### 4.1 Module by module

**`Fiber`** — 620/13. `await` `:185` → `Exit`, `join` `:304`, `interrupt` `:379` (**blocks until the
target has finished** — the semantics structured concurrency needs), `interruptAs`, `interruptAll`,
`awaitAll`, `joinAll`, `getCurrent`, `runIn(scope)`; the interface (`:71-87`) exposes `id: number`
(v4 dropped the `FiberId` ADT), `addObserver` returning an unsubscribe, `pollUnsafe`. In v4 a
`Fiber` is **no longer an `Effect`**, and `RuntimeFiber`, `Fiber.Descriptor`, `Fiber.Dump` and
`Fiber.Order` were deleted (`migration/v3-to-v4.md:10969-10989`). Forking is four functions — all
taking `{ startImmediately?, uninterruptible?: boolean | "inherit" }`, all through
`forkUnsafe` (`effect.ts:5454`): `forkChild` is structured (the parent interrupts and awaits its
children before committing its own exit, `:632-638`, `:805`), `forkIn` is a daemon with a scope
finaliser, `forkScoped` adds `Scope` to `R`, `forkDetach` is v3's `forkDaemon`.
*beni*: `Task.spawn (\() -> …)`; all four operations are nullary in the receiver so all are written
`Fiber.join f`. Bits: `spawn`/`cancel` are `suspends`+`impure`, `join`/`await` `suspends`.
**Primitive** — the fiber record of proposal §6.4, the only one in the section.

**`Deferred`** — 921/24. `make` `:172`, `await` `:174`, `succeed` `:784` → `Effect<boolean>`, `fail`,
`interrupt` `:630`, `poll` `:749`, `isDone`. Write-once, first writer wins; waiters are an `Array`
of resume functions and **an interrupted awaiter is spliced out of `self.resumes`** (`:174-186`),
with `resumes` swapped to `undefined` before the resume loop (`:860-862`).
*beni*: `Deferred.await d`, `d.succeed x`. `await` is `suspends`; the rest `impure`.
**Library over the suspension protocol**, but T0 in §8 because everything else parks on it.

**`Latch`** — 382/11, new in v4. `make(open?)` `:196` **defaults to closed**, `open` `:216`,
`close` `:312`, `release` `:260` — the non-obvious one, a one-shot pulse that wakes current waiters
without opening the gate — `await` `:262`, `whenOpen`, `isOpen`. Interrupted waiters are removed
from both the waiter array and the staging array (`effect.ts:5813-5828`). **Library.** T1.

**`Semaphore`** — 574/11, new as a top-level module in v4. `make(permits)` `:358`, `withPermits`
`:407`, `withPermit` `:432`, `withPermitsIfAvailable` `:461` → `Option`, `take` `:494`,
`takeIfAvailable`, `release` `:554`, `releaseAll`, `resize` `:380`; no `shutdown`.
**Two warnings worth taking as design input.** It is **not FIFO** — a smaller later request may
overtake a larger earlier one, documented at `:121-124` and visible in `releaseUnsafe` `:254-265` —
and **the bare `take`/`release` pair is not interruption-safe**: only `withPermits`, which runs under
`uninterruptibleMask` with `onExitPrimitive(…, true)` (`:295-315`), guarantees the release.
*beni*: `sem.withPermits 2 (\() -> …)`. **Library.** T1, and under CLAUDE.md rule 7 the unsafe pair
should be omitted or bracketed rather than shipped with a doc warning.
`PartitionedSemaphore` (557/13, new) is the keyed version — freed permits dripped round-robin so no
partition monopolises them, partial permits returned on interrupt (`:217-229`), and a request above
the maximum blocks forever (`:167-170`). T2 at most.

**`Queue`** — 2 088/44. `make({ capacity?, strategy?: "suspend" | "dropping" | "sliding" })` `:449`
— defaults are infinite capacity and `"suspend"` (**not** "backpressure"; v3's `Strategy` and
`BackingQueue` types are gone) — with wrappers `bounded` `:501`, `sliding` `:538`, `dropping` `:574`,
`unbounded` `:612`. `offer` `:646` → `Effect<boolean>`, `offerAll` `:763`, `take` `:1426`,
`takeAll` `:1244` → `NonEmptyArray`, `takeN`, `takeBetween`, `poll` `:1465`, `peek`, `size`,
`isFull`, `clear`. A queue has an **error channel**: `fail` `:873` and `end` `:1005` are *graceful*
(the queue enters `Closing` and drains) while `shutdown` `:1138` clears the buffer; `end` is
`failCause(Cause.fail(Cause.Done()))`, the same sentinel `Pull` uses for end-of-stream (§5.B).
`Queue<A,E>` splits into `Enqueue` `:168` and `Dequeue` `:236` and is no longer an `Effect`.
Capacity ≤ 0 is a rendezvous channel.

**The obligation `research/16` §5.3 row 10 names is honoured here, and it is the fixture beni owes:**
```ts
// Queue.ts:2048-2058, awaitTake
self.state.takers.add(resume)
return internalEffect.sync(() => {
  if (self.state._tag !== "Done") self.state.takers.delete(resume)
})
```
Same pattern for suspended offers (`:1963-1996`) and awaiters (`:1650-1662`). Without it the queue
leaks a dead waiter per cancellation and eventually hands a value to nobody.
*beni*: `Queue.bounded 100`, `q.offer job`, `Queue.take q`. `offer` on a full queue and `take` on an
empty one are `suspends`; `poll`/`size` are `impure` only. **Library.** T1. One defect not to copy:
**`poll` cannot distinguish an empty queue from a failed one** (`:1465`).

**`PubSub`** — 2 816/32. `bounded(capacity | { capacity, replay? })` `:335`, `dropping` `:382`,
`sliding` `:428`, `unbounded` `:468`; `publish` `:908`, `publishAll` `:1011`,
`subscribe : Effect<Subscription<A>, never, Scope>` `:1083`, and the subscription's `take` `:1150`,
`takeAll`, `takeUpTo`, `remaining`; `shutdown` `:758`. **A replay buffer exists** (`:513`), which is
what lets a late subscriber catch up. Strategies are **public classes** here
(`BackPressureStrategy` `:2365`, `DroppingStrategy` `:2505`, `SlidingStrategy` `:2588`) — a different
vocabulary from `Queue`'s strings, an inconsistency not to copy. Parked consumers and backpressured
publishers are removed via `Effect.onInterrupt` (`:1233-1239`, `:2386-2396`).
*beni*: `PubSub.bounded 256`, `pub.publish e`, `sub <- PubSub.subscribe pub` (a `<-` bind, since
`subscribe` is scoped). **Library.** T2.

**`Ref` / `SynchronizedRef` / `SubscriptionRef` / `MutableRef`** — 747/17, 668/24, 1 033/26, 913/17.
`MutableRef` is `{ current: T }` and the **only primitive of the four**. `Ref` is `MutableRef` plus
`Effect.sync` (`:142-146`): `make` `:173`, `get` `:200`, `set` `:236`, `modify` `:461`,
`modifySome` `:521`, `update` `:573`, `updateAndGet` `:610`. It is fiber-safe because **every
operation is a single `Effect.sync` with no interruption point** — there is nothing to interleave.
`SynchronizedRef` adds `Semaphore(1)` so an *effectful* update (`modifyEffect` `:307`,
`updateEffect` `:485`) is serialised; `get` bypasses it, and an interrupted update leaves the old
value and always releases the permit. `SubscriptionRef` sets and publishes together (`:250-253`) and
exposes `changes : Stream<A>` (`:160`) whose new subscriber sees the current value first. In v4
`Ref` is **no longer an `Effect`** and `Ref.Synchronized` became the top-level `SynchronizedRef`, no
longer extending `Ref` (`migration/v3-to-v4.md:13328`, `:16039-16047`).

***beni, and the one genuinely new language question in this section.*** `ref.update f` and
`ref.modify f` dot-call; `Ref.get r` does not. Bits: `get`/`set` are `impure` and **not**
`suspends` — which makes **`Ref` the first real consumer of the `impure` bit**, because
`language.md`'s *What an optimiser may assume* says every beni expression is pure and may be
dropped, duplicated, reordered or memoised. `Ref.get` must be `impure` or two reads collapse into
one. `effects-plan.md` §5 decision 4 recommends inferring `impure` and **not using it in v1**; a
`Ref` makes "not using it" a miscompile, and that should be recorded against decision 4.
**Library over a mutable cell** — one `foreign type` and four `foreign` functions, the smallest
addition in the report. T0.

**`Pool`** — 1 029/13. `make({ acquire, size, concurrency?, targetUtilization? })` `:232`;
`makeWithTTL({ …, min, max, timeToLive, timeToLiveStrategy?: "creation" | "usage" })` `:299`;
`get : Effect<A, E, Scope>` `:446`, `use` `:488`, `invalidate` `:755`. Defaults: concurrency 1,
`targetUtilization` 1 clamped to [0.1, 1] (`:480-490`); target size is
`ceil((usage / targetUtilization) / concurrency)` clamped to `[min, max]` (`:925-931`). `get` blocks
on exhaustion with the waiter removed and `usage--` on interrupt (`:638-651`, `:543-550`);
`invalidate` matches by reference, is uninterruptible, and defers finalising a leased item until it
returns. **Library over `Semaphore` + `Queue` + `bracket`.** T2.

**`Cache` / `ScopedCache` / `RcRef` / `RcMap`** — 1 405/17, 827/18, 244/5, 707/10. `Cache` is **LRU
over an insertion-ordered map** (a hit removes and re-sets the key, `:428-433`; overflow evicts from
the front, `:494-503`; `has` does not touch recency), `capacity` is required, and a concurrent miss
shares **one in-flight lookup fiber** with an awaiter count, interrupted only when the last awaiter
leaves (`:476-484`); failures are cached, interrupted exits are not. `ScopedCache` is an independent
reimplementation giving each entry a `Deferred` and a `Closeable` scope (`:104-108`). `RcRef`
reference-counts one scoped resource: `get` increments, a finaliser on the borrower's scope
decrements, and at zero it closes immediately, keeps forever, or forks `sleep(ttl)`-then-close
(`internal/rcRef.ts:157-179`), with **revival interrupting the timer fiber and awaiting it**
(`:106-108`). `RcMap` is the keyed version and **behaves differently on revival** (it does not
interrupt the timer, relying on a `refCount > 0` re-check) and **its capacity is a hard error**
(`Cause.ExceededCapacityError`, `RcMap.ts:353-356`) where `Cache`'s evicts.
**All library, over `Ref`/`Dict`, `Deferred`, `Scope` and `Clock`.** T2 — and those inconsistencies
(two reference-counting implementations with different revival behaviour; capacity meaning eviction
in one module and failure in another) are exactly what writing one instead of four avoids.

**`FiberSet` / `FiberMap` / `FiberHandle`** — 743/14, 1 062/19, 851/15. Each `make` is an
`acquireRelease` returning `Effect<X, never, Scope>` (`:154`, `:162`, `:146`); closing the scope
interrupts every held fiber and awaits them. Replacement differs: `FiberHandle.setUnsafe` interrupts
the existing fiber unless `onlyIfMissing`, in which case it interrupts the *incoming* one
(`:331-343`); `FiberMap.setUnsafe` installs the replacement before interrupting the old (`:363-384`).
Adding to a closed container interrupts the incoming fiber with the sentinel id `-1`. Failures latch
into a shared `Deferred` and reach the owner only through `join`. **These three are what v4 told
users to reach for when it deleted `Supervisor`** (`migration/v3-to-v4.md:16017`). **Library over
`Scope` and `Fiber`**, T2, and they need `Exit` (D2). `boundary.md` §5.4's `Cmd.keyed` with its four
policies *is* `FiberMap` with a policy argument — the two designs converge from opposite directions.

### 4.2 STM in v4: `Tx*` and `Effect.tx`

**There is no `STM.ts`.** v4's transactional memory is a family of data structures whose operations
return ordinary `Effect`s, plus a runner:

```ts
class Transaction extends Context.Service<Transaction, {
  retry: boolean
  readonly journal: Map<TxRef<any>, { readonly version: number; value: any }>
}>()("effect/Effect/Transaction")                                    // Effect.ts:14549
tx: <A,E,R>(effect: Effect<A,E,R>) => Effect<A, E, Exclude<R, Transaction>>   // :14609
txRetry: Effect<never, never, Transaction>                           // :14735
interface TxRef<in out A> { version: number; pending: Map<unknown, () => void>; value: A }  // TxRef.ts:61-67
```

There is no `Effect.transaction`, no `Effect.atomically`, no `STM.commit`; an interim
`Effect.atomic`/`atomicWith` was removed during pre-release
(`.changeset/pre/add-missing-tx-modules.md`).

`tx` returns the effect unchanged if a `Transaction` is already in context (`:14613-14616`) — nested
`tx` joins the outer journal, so there are no nested boundaries. Otherwise it loops under
`uninterruptibleMask`: run the body with a fresh journal, capture the `Exit`, and if `state.retry`
is set or any journaled `ref.version` has moved (`:14651-14658`), clear and loop; otherwise commit
(`:14681-14692`), bumping `version` only where the value changed and waking every `ref.pending`
thunk. **`txRetry` sets `state.retry` and then returns `interrupt`** — retry rides the interruption
channel, so `Effect.catch` cannot catch it — and `tapCause` parks the fiber in
`awaitPendingTransaction` (`:14660-14679`), a `callback` registering in every journaled ref's
`pending` map whose cleanup removes it.

`TxRef.modify` ends in `Effect.tx` (`:166-186`), which **discharges the `Transaction` requirement**,
so `TxRef.get : <A>(self) => Effect<A>` has no `Transaction` in `R` (`:254`): outside a `tx` it is a
single-op transaction, inside one it joins the ambient journal. `Effect.tx` is needed only to make
several operations atomic *together*.

The eleven modules, all library code over `TxRef`: `TxRef` 291/7, `TxChunk` 852/22 (new),
`TxQueue` 1 512/37, `TxSemaphore` 725/14, `TxReentrantLock` 712/17, `TxDeferred` 327/8,
`TxPriorityQueue` 586/19, `TxPubSub` 705/18, `TxSubscriptionRef` 529/12, `TxHashMap` 2 109/38,
`TxHashSet` 941/23. Blocking is always `Effect.txRetry`. v3's `TArray` and `TRandom` have **no
counterpart**.

**Three limits worth knowing before deciding D3.** (1) **There are no journal savepoints** —
`STM.orElse`/`orElseEither`/`orTry` map to nothing, and a test pins the consequence: a nested `tx`
that fails and is caught **keeps its writes** (`test/Effect.test.ts:3415-3433` — the value is 20,
not 10), while an uncaught failure rolls back the whole composed transaction (`:3397-3413`).
(2) **Arbitrary effects may run inside a `tx` body and re-execute on retry** — the guide says
`Random.next` *"may be re-executed if used inside a retried transaction"*, and nothing stops a
`console.log` running twice. (3) `TxPriorityQueue` is not a heap (binary search plus an O(n) rebuild,
`:87-104`), and `TxChunk` and `TxHashSet` have **opposite conventions** for transformations.

*beni*: D3, recommended out of scope for a first release. The observation that matters for the
kernel spec is that **v4's design costs almost nothing at the runtime level** — a version counter
and a pending map per cell, a journal per transaction, a retry loop built from `uninterruptibleMask`
+ `callback` + `interrupt`, all of which the proposed runtime already has. Deciding "not yet"
forecloses nothing **provided the kernel keeps `uninterruptible` (§8 T0) and a per-cell waiter
list**. Limit (2) is also an opportunity: beni's `impure` bit could in principle refuse an `impure`
call inside a transaction body, a guarantee Effect does not have and rule 7 would approve of.

### 4.3 The summary table

| Effect module(s) | lines/exports | beni tier | primitive or library? |
|---|---|---|---|
| `Fiber` + fork family | 620/13 | **T0** | **primitive** — the fiber record |
| `Deferred` | 921/24 | **T0** | library over the suspension protocol |
| `Ref`, `MutableRef` | 1 660/34 | **T0** | library over a mutable cell (1 `foreign type`, 4 functions) |
| `Scope` | 545/14 | **T0** | library — a finaliser list on the fiber |
| `Queue` | 2 088/44 | T1 | library |
| `Semaphore` | 574/11 | T1 | library |
| `Latch` | 382/11 | T1 | library |
| `SynchronizedRef` | 668/24 | T1 | library — `Ref` + `Semaphore(1)` |
| `PubSub` | 2 816/32 | T2 | library |
| `SubscriptionRef` | 1 033/26 | T2 | library |
| `Pool` | 1 029/13 | T2 | library |
| `Cache`, `ScopedCache` | 2 232/35 | T2 | library |
| `RcRef`, `RcMap` | 951/15 | T2 | library |
| `FiberSet`/`Map`/`Handle` | 2 656/48 | T2 | library |
| `Request`, `RequestResolver` | 1 921/42 | T2 | library |
| `PartitionedSemaphore` | 557/13 | T2 | library |
| `ScopedRef`, `Resource` | 378/12 | T2 | library |
| `Tx*` ×11 + `Effect.tx` | 9 289/215 | **D3** | library over `TxRef` |

**One primitive, one mutable cell, and everything else is beni.** Of ~30 000 lines and ~600 exports
of Effect concurrency, the part that must be privileged code behind `boundary.md`'s wall is the
fiber record and the suspension protocol — which the proposal already specifies — plus a `Ref` cell.
Under CLAUDE.md rule 7, the answer to *"what is the language withholding?"* is: almost none of it,
once the kernel exists.

## 5. The big batteries

A measurement used throughout: **type erasure**, the share of non-comment code lines that vanish
under Node 24's `stripTypeScriptTypes`. Blunt, but a direct answer to *how much of this file is
fighting the type system*. Top-level `packages/effect/src/*.ts` is **37 % type-only**, `internal/`
15 %, `unstable/` 23 %, the platform adapters 14 %. `Effect.ts` is **90.6 %**, being a facade over
`internal/effect.ts` + `core.ts` (7 605 lines).

### 5.A `Schedule` — 1 517 lines, 37 exports, 32 % type-only

A `Schedule` is an acquired, **stateful step function**; everything else is sugar over two
functions.

```ts
export interface Schedule<out Output, in Input = unknown, out Error = never, out Env = never>  // :53
// fromStep, :250
step: Effect<(now: number, input: Input) => Pull.Pull<[Output, Duration], ErrorX, Output, EnvX>, Error, Env>
```

The outer `Effect` acquires per-run state (a closure holding counters); each step returns
`[output, delay]` or stops by putting `Cause.Done<Output>` in the error channel. A metadata record —
`{ input, attempt, start, now, elapsed, elapsedSincePrevious }` (`:63`), plus `output` and
`duration` (`:78`) — is handed to the repeated effect through a `Context.Reference`, `CurrentMetadata`
(`:96`).

Constructors: `spaced` `:1198`, `fixed` `:933`, `exponential` `:850`, `fibonacci` `:882`,
`recurs` `:1169`, `windowed` `:1423`, `duration` `:720`, `during` `:750`, `forever` `:1460`,
`cron` `:678`. Combinators: `addDelay` `:465`, `modifyDelay` `:1043`, `jittered` `:1093` (0.8×–1.2×),
`map` `:987`, `tap` `:1234`, `passthrough` `:1125`, `concat` `:500`, `concatResult` `:538`,
**`min` `:783` / `max` `:618`**, `upTo` `:1294`, `while` `:1323`, `setInputType` `:1516`.

**v4 deleted about twenty-five v3 combinators, and this is the most instructive fact in the
section.** None of `union`, `intersect`, `andThen`, `either`, `both`, `whileInput`, `untilOutput`,
`whileOutput`, `untilInput`, `tapOutput`, `tapInput`, `recurWhile`, `recurUntil`, `elapsed`,
`compose`, `collectAll`, `reduce`, `resetAfter` or `ScheduleDriver` survives
(`migration/annotations/effect__Schedule.yaml`). `union`/`either` → `min`; `intersect` → `max`;
`andThen` → `concat`; **every `while*`/`until*` variant → one `Schedule.while` over the metadata
record**; `tapInput`/`tapOutput` → `tap`. A dozen names collapsed into three because one record made
them redundant.

`Effect.retry` (`Effect.ts:4090`) and `repeat` (`:7656`) each take a `Schedule`, a builder, or an
options object `{ while?, until?, times?, schedule? }` (`:4030-4036`), which `buildFromOptions`
(`internal/schedule.ts:222`) lowers onto `passthrough` + `while`. The driver is `repeatOrElse`
(`internal/schedule.ts:13`): `toStepWithMetadata`, then `forever(self ⨟ step)` with `CurrentMetadata`
provided, succeeding with `error.value` when `Cause.Done` is caught; the sleep is inside the step.

*TypeScript-forced*: the variance phantom, `Pipeable`, the `dual` overloads, the
`Retry.Return`/`Repeat.Return` conditional types that compute a result type from an options literal
(`Effect.ts:3995-4025`), and `setInputType`, an identity function that exists only to steer
inference. *Essential*: the step function, the metadata record, done-as-a-value.

**In a first release? Yes, and before the runtime** — it is pure data and replaces the proposal's
weakest signature. The smallest honest beni version is §8's T1 `Schedule`, taking v4's `min`/`max`
names. **The one open design question** is how the state is carried: Effect uses a per-run mutable
closure; a beni `Schedule a` wants `{ state : s, step : s, a -> Maybe ( Duration, s ) }` and `s` is
existential, which beni has no mechanism for. §10 item 2.

Alongside: `Duration.ts` 1 798/57 (take the typed duration, leave the template-literal `"250 millis"`
parsing), `Clock.ts` 326/6 (small, and important because it is a `Context.Reference` with a default
at `:189` — which is what makes `TestClock` possible), `Cron.ts` 1 318/14 and `DateTime.ts`
2 874/96, both T2 / `boundary.md` §6 capabilities.

### 5.B `Stream` / `Channel` / `Sink` / `Pull` — 23 741 lines, 506 exports

The primitive is `Pull`, and it is 392 lines:

```ts
export interface Pull<out A, out E = never, out Done = void, out R = never>
  extends Effect<A, E | Cause.Done<Done>, R> {}                      // Pull.ts:40
```

A `Pull` *is* an `Effect` whose error channel may carry a distinguished "done" value. That one trick
removed the v3 channel interpreter: **a `Channel` in v4 is a single closure**,
`transform: (upstream: Pull, scope) => Effect<Pull>` (`Channel.ts:284`, `:437`), `pipeTo` (`:6776`)
is function composition, and there is no instruction ADT and no executor. A `Stream` holds a
`Channel` of non-empty batches (`Stream.ts:126`); **`Chunk` is gone from streaming** and batches are
`NonEmptyReadonlyArray` with a default size of 4096 (`Channel.ts:458`). `Sink` is no longer a
`Channel` — it consumes a `Pull` directly (`Sink.ts:64`). `Channel` still has seven type parameters
(`:141`), which is not gratuitous: `pipeTo` must type the seam between two channels in both
directions with an error, a done value and an environment on each side.

Sizes: `Stream.ts` 11 864/247 (40 % type-only), `Channel.ts` 8 923/157 (**59 %**), `Sink.ts`
2 205/79, `Pull.ts` 392/15, `Take.ts` 46/2, `ChannelSchema.ts` 311/6 (**79 %** — `duplex` has a
three-line body under ~70 lines of signature). Operations divide into constructors (`fromIterable`,
`fromQueue`, `fromPubSub`, `callback`, `unfold`, `paginate`, `range`, `fromSchedule`), transforms
(`map` — which now takes an index — `filter`, `filterMap`, `mapArray`, `scan`, `mapAccum`, `take`,
`drop`, `tap`), concurrency (`mapEffect(f, {concurrency, unordered})`, `flatMap(f, {concurrency,
bufferSize})`, `merge(that, {haltStrategy})`, `mergeAll`, `broadcast`, `share`, `buffer`), grouping
and rate (`grouped`, `groupedWithin`, `groupBy`, `groupAdjacentBy`, `sliding`, `debounce`,
`throttle`, `aggregate`, `transduce`), and runners (`run`, `runCollect`, `runForEach`, `runDrain`,
`toPull`, `toQueue`, `toReadableStream`, `toAsyncIterable`).

*TypeScript-forced*: variance structs, three `Unify` interfaces per type, every operator written
three times because of `dual` (**156 `dual(` sites in `Stream.ts`, 82 in `Channel.ts`** — the two
worst files in the package), and `ChannelSchema`'s empty `<IE, Done>()` call stage, which exists only
because TypeScript has no partial type application. *Essential*: the `Pull` trick, non-empty batches,
the scoped pull-to-pull transducer.

**In a first release? No — D5, recommended T2.** Not because `Stream` is unimportant, but because
`Channel`'s generality serves `Stream`, `Sink`, RPC framing and HTTP bodies at once and beni will
have none of the last three for a long time. The smallest honest version is a scoped pull plus
map/filter/take/drop/fold/forEach, `fromList`, `fromQueue`, and `mapPar` with a mandatory bound —
no `Channel`, no seven parameters, representation kept opaque.

**One note that lands squarely on beni.** `Pull`'s trick — end-of-input as a value in the error
channel — is exactly what `Result e a` plus `?` already does. `pull : Stream a -> Result Done a`
with `?` gives early return on end-of-stream with no machinery at all. beni's existing language
feature lands on Effect v4's newest idea.

### 5.C `Schema` — 8 modules, 30 688 lines, 1 092 exports, ~41 % type-only

**Not a validation library: a runtime re-implementation of the type system.** TypeScript's types are
erased, so nothing at a boundary can ask "is this a `User`?". A `Schema` is a value carrying a
runtime tree (`SchemaAST`, a 21-case AST at `:52-73`) from which a decoder, encoder, JSON Schema,
`Arbitrary`, `Equivalence`, formatter, optic and diff are all derived.

The parameter count is the tell. The user-facing interface is one parameter —
`Schema<out T> extends Top` (`Schema.ts:935`) — but the real base is `Bottom` (`:292`) with
**fifteen**, of which **nine are phantoms** encoding `readonly`, `?`, "has a default" and a self
type; there are 339 `"~…"` phantom-property occurrences in `Schema.ts` and nine parallel views of
one runtime object (`:743-1141`). `Codec<T, E, RD, RE>` (`:1040`) splits v3's single `R` into
decoding and encoding service channels.

Declaring a struct is `Schema.Struct({ … })` (`:3402`) with `optionalKey` `:2317`, `optional`
`:2379`, `mutableKey` `:2442`, five flavours of default (`:5651`–`:5917`), plus `Class` `:13983` and
`TaggedClass` `:14042`. Decoding is a hand-written matrix — `{decode, encode} × {Unknown, typed} ×
{Effect, Exit, Option, Result, Promise, Sync}` — duplicated across `Schema.ts` and `SchemaParser.ts`.
The error type is a path-carrying tree, `Issue = Leaf | Filter | Encoding | Pointer | Composite |
AnyOf` (`SchemaIssue.ts:142`), which is what accumulation needs. There are **three execution
strategies**: an interpreter, a JIT via `new Function`, and an AOT compiler (`SCHEMA.md:68-199`).

**How much is type reconstruction?** 41.5 % of the public Schema modules by erased characters, and
**50.6 % of `Schema.ts`** (98 910 of 195 589). That is a floor: it excludes the 74 of 193 interfaces
documented as "type-level representation returned by…", the doubled decode matrix, and the JSDoc
explaining which view to use. Pure gymnastics: `Struct.View` (`:3198-3212`); `optionalKey`, 34 lines
of type around a two-line body (`:2270-2318`); `MissingSelfGeneric`, a compiler diagnostic encoded
as a template-literal type (`:3743`); `revealCodec`, whose body is `return codec` (`:1115`). A
defensible estimate is that **40–60 % of the public surface would not exist** given real ADTs and
compiler-derived codecs.

**What remains essential, and any deriving compiler owes too:** the AST, the code generator
(`internal/schema/codegen.ts`, 922 lines, 7 % type-only), the issue tree with its
`errors: "all" | "first"` policy, `SchemaGetter`'s `Option → Option` step (which is what lets it
create or delete keys), generator termination for recursive types, and JSON Schema dialect
translation.

**In a first release? No, and arguably never as a `Schema` module.** beni's counterpart already
exists in the design: `boundary.md` §3.1's codec generator — *"the compiler generates the codec from
the type you wrote"* — widened to ADTs and records with a depth bound, and `research/18` §6's
derived-codec question as the open half. The smallest honest beni version is therefore not a module
but `Json.encode`/`decode` derived per type **plus an `Issue`-shaped error with a path**, because
*"expected an Int at `.users[3].age`"* is the one thing a derived decoder must not lose.
`SchemaIssue` is the model for that error type and is worth copying closely.

### 5.D `Config` — 2 943 lines, 58 exports, ~15 % type-only. The most beni-shaped battery.

A `Config<T>` **is** an `Effect<T, ConfigError>` (`Config.ts:108`) that reads whatever
`ConfigProvider` is current; the provider is a `Context.Reference` defaulting to the environment
(`ConfigProvider.ts:342`). The split: **logical paths belong to the `Config`, source mapping belongs
to the provider.** Every primitive is one line over `Config.schema` (`:877`) — `String(name?)` at
`:998` is literally `schema(Schema.String, name)` — across `String`, `NonEmptyString`, `Number`,
`Int`, `Boolean`, `Port`, `URL`, `Date`, `Duration`, `ByteSize`, `LogLevel`, `Redacted`, `Literal`,
`Array`, `Record`. Composition is `all` `:400`, `map`, `mapEffect`, `orElse`, `withDefault` `:528`,
`option`, `nested` `:1619`; providers are `fromEnv` `:926`, `fromDotEnv` `:1200`, `fromDir` `:1271`,
`fromUnknown` `:780`, combined with `orElse`, `mapInput`, `constantCase`, `nested`.

**One detail worth stealing outright:** `Resolution = Resolved { value, hasInput } | Absent`
(`:113-124`) keeps **absent** separate from **invalid**, so `withDefault` fires only when no input is
present and a malformed value is still an error. Easy to get wrong; one ADT.

Almost nothing here is TypeScript tax. In a first release: no, but it is cheap and it is not effects
work — a beni `Config` is a decoder over a string tree returning `Result ConfigError a`.

### 5.E `Layer` / `Context` — 6 modules, 6 108 lines, 112 exports, ~35 % type-only

Covered as a *design question* in §3.3; the machinery is this. `Context.Key<Identifier, Shape>`
(`Context.ts:64`) **is itself an `Effect<Shape, never, Identifier>`**, which is why `yield* Database`
retrieves the service; `Context.Service` (`:98`) adds `of`, `context`, `use`, `useSync`;
`Context.Reference` (`:335`) adds a `defaultValue` and has `Identifier = never`, so it contributes
nothing to `R`. **The runtime identity of a service is its string `key`** — the class and the type
parameters exist only to give TypeScript a nominal handle; there are 175 `extends Context.Service`
declarations inside `packages/effect/src` alone.

`Layer<ROut, E, RIn>` (`Layer.ts:54`) is `build(memoMap, scope) => Effect<Context<ROut>, E, RIn>`.
**Memoisation is a `Map` keyed on Layer object identity** (`:222`, `:421`) with parent chaining
(`:511`), observer counting, a finaliser per scope (`:244-273`), and the map itself carried as a
service (`CurrentMemoMap`, `:584`); `Layer.fresh` builds with a new map and
`ManagedRuntime.make(layer, { memoMap })` shares one (`ManagedRuntime.ts:285`). The consequence
worth knowing: a layer is shared only if it is the *same value*, so a layer-producing function called
twice builds twice. `LayerMap` (521 lines) is a keyed reference-counted cache over `RcMap`;
`LayerRef` (383, new) the same for one layer over `RcRef`.

Test doubles are `Layer.succeed(Tag, impl)` or **`Layer.mock(service)(partial)`** (`:2308`), a Proxy
whose unimplemented members die with `UnimplementedError`; per-module test layers exist too
(`Stdio.layerTest`, `FileSystem.layerNoop`, `TestClock.layer()`).

*TypeScript-forced*: the class trick for nominal identity, the `in ROut` contravariance and the
`Exclude<RIn2, ROut>` arithmetic emulating row subtraction, the `Unify` hooks, the `satisfies*Type`
helpers. *Essential*: a string-keyed map, scoped construction, identity memoisation.

**In a first release?** The mechanism, no. **The decision, yes** — D1 must be taken before the first
platform capability is designed, because every capability is either a record argument, a `where`
constraint or an ambient reference, and changing that later rewrites every signature.

### 5.F Platform — and what v4 moved

**v4 moved the platform abstractions into core.** `packages/platform/` has no `src` and no
`package.json`; it holds five adapter packages totalling ~18 100 lines against 362 457 for `effect`.
`packages/effect/README.md:47`: *"In v4, functionality that previously lived in separate packages
ships inside `effect` under the `effect/unstable/*` namespaces."* The evidence in the tree:
`platform/node-shared/src/NodeFileSystem.ts:17` imports `effect/FileSystem` and `:710` exports
`layer = Layer.effect(FileSystem.FileSystem)(makeFileSystem)`;
`platform/node/src/NodeFileSystem.ts` is **22 lines**; `BunHttpClient.ts` is one line,
`export * from "effect/unstable/http/FetchHttpClient"`.

**The pattern is `boundary.md`'s pattern**: the interface, the error type and the service key live in
core — often with a working default — and only a `Layer` lives in the runtime package. Two
illustrations: `Path.ts` (867 lines) ships a working POSIX implementation in core (`:867`), and
`Crypto.ts` (308 lines) **derives all eleven operations of its service from two foreign functions**,
`randomBytes` and `digest` (`:230`). That is `boundary.md` §4's narrow-`foreign` rule, arrived at
independently.

**The core service surface — the candidate list for a beni Node/browser platform**:
`FileSystem.ts` 1 123/20 (30 interface members: `open`, `readFileString`, `stream`, `watch`, `File`,
`layerNoop`, a `WatchBackend` seam), `Path.ts` 867/6, `Terminal.ts` 188/7 (`readInput`, `readLine`,
`display`), `Stdio.ts` 162/6 (`stdout` is a `Sink`, `stdin` a `Stream`, `layerTest` at `:152`),
`Crypto.ts` 308/4, `Console.ts` 853/21, `Random.ts` 586/10, `PlatformError.ts` 221/6
(`BadArgument | SystemError` under one tag).

**The adapter packages**, which map onto beni platform packages one for one: `browser` 5 439
(`BrowserCrypto`, XHR `BrowserHttpClient`, `BrowserKeyValueStore`, `BrowserSocket`, `BrowserWorker`,
plus browser-only `Clipboard`, `Geolocation`, `Permissions`, `IndexedDb*` — the query builder alone
is 2 078); `node-shared` 3 859 (the real implementations: `NodeFileSystem` 711,
`NodeChildProcessSpawner` 771, `NodeSocket` 597, `NodeStream` 453, `NodeTerminal` 179,
`NodePath` 79, `NodeStdio` 70, `NodeCrypto` 61); `node` 3 305 (`NodeHttpServer` 679,
`NodeHttpClient` 668 on undici, multipart, worker and cluster wiring); `bun` 2 054
(`BunHttpServer` 744, the rest re-exports); `deno` 3 445.

`boundary.md` §5.1 already argues each runtime gets its own platform and that Node is the lowest
common denominator; Effect's split — implementations in `node-shared`, differences in
`node`/`bun`/`deno` — is the concrete shape of §5.1's *"platforms are packages and packages depend
on packages … and differ only in their foreigns."* **Independent confirmation of a decision beni has
already taken.**

**`unstable/`, as the candidate battery list**, 232 modules and 129 498 lines in 20 subtrees:
`ai` 21 779, `cluster` 15 826, `http` 15 416 (`HttpClient` alone 1 824), `cli` 13 361 (`Prompt`
4 070), `httpapi` 8 761, `encoding` 7 875 (`SchemaBinary` 5 261), `eventlog` 6 747, `rpc` 6 713,
`reactivity` 6 414, `persistence` 6 130, `sql` 4 146, `workflow` 3 750, `observability` 2 976,
`schema` 2 620, `net` 1 927, `process` 1 385, `socket` 1 383, `devtools` 997, `workers` 667,
`arbitrary` 625. Plausibly beni platform packages in the next two years: **`http`** (client first),
**`process`**, **`socket`**, **`workers`**, `persistence`'s `KeyValueStore`, and `encoding`'s codecs.
`cluster`, `workflow`, `eventlog`, `ai` and `reactivity` are applications *on* a platform, not
platform.

### 5.G Observability and testing

`Logger.ts` 1 147/25 is `Logger<Message, Output> { log(options) }` with
`options = { message, logLevel, cause, fiber, date }` (`:64`, `:101`), four formatters
(`formatSimple`, `formatLogFmt`, `formatStructured`, `formatJson`, `:524`–`:664`), `batched` `:702`,
`toFile` `:1115`, and the active logger set in a `Context.Reference` (`:162`). `LogLevel.ts` 384/11
is a string union with an `Order`. `Metric.ts` 3 529/44 has `counter`, `gauge`, `frequency`,
`histogram`, `summary`, `timer` over a `MetricRegistry` reference. **`Tracer.ts` 748/22 is one
method** — `span(options): Span`, with `Span` carrying `end`, `attribute`, `event`, `addLinks`, a
`ParentSpan` service and a `Tracer` reference. That last fact is the most encouraging in the
subsection: beni's tracing story is small if it is designed as an interface rather than an
integration.

`packages/effect/src/testing/` is 1 578 lines: `TestClock.ts` 614 (`adjust` `:507`, `setTime` `:544`,
`withLive` `:580`, `layer` `:436`, and a warning state for tests that sleep without advancing),
`TestConsole.ts` 370, `TestSchema.ts` 574. **There is no `TestServices` apparatus** — v3's was
deleted (`migration/v3-to-v4.md:754-762`) and a test double is now just a `Layer` over the same
reference. For beni the lesson is exact and cheap: **a deterministic clock is a service with a
default and a test-time replacement, and that is all it is.**

## 6. What Effect gets right that beni's proposal has not specified

API-level only. The runtime's own gaps are report 21's. Ranked by value to a beni user — my
ranking, argued, not measured.

**1. `Exit` as a value a user can inspect.** `Fiber.await` gives you `Exit<A, E>`, and a supervisor,
a pool, a restart policy and a test can all read it. The proposal types `Fiber.join : Fiber a ->
Result Cancelled a` and stops. `research/16` §1.4's complaint about Elm is exactly that
`_Scheduler_spawn` has no outcome slot, *"so nothing can learn what a spawned task produced"* — and
the proposal's `Result Cancelled a` is only one constructor better than that. §3.2.2 proposes the
beni shape. **Cheap, and everything supervisory depends on it.**

**2. Deterministic time.** `TestClock.adjust(60_000)` (`references/effect/ai-docs/src/09_testing/10_effect-tests.ts:180`)
makes a test that sleeps a minute run instantly and deterministically. beni's proposal mentions
deterministic scheduling as a *question* (§11 Q11) and never mentions a virtual clock. The whole
mechanism is: `Clock` is a service with a default, `sleep` asks it, and a test provides a different
one. Under D1 option (c) that is four functions. **This is the single highest-value thing in the
list for a language whose pitch is Elm's guarantees**, because "your async code is testable" is a
claim Elm has never been able to make and Effect can.

**3. `Schedule` as a composable value.** The proposal has `Task.retry : Int, (() -> Result x a) ->
Result x a` — a count. Effect has a `Schedule` you build from `exponential`, `spaced`, `recurs`,
`cron`, combine with `min`/`max`, modify with `jittered`, `while`, `tap`, and hand to *either*
`retry` or `repeat` (`references/effect/ai-docs/src/06_schedule/10_schedules.ts:179-187`). A retry
policy is a value you can name, test and share. beni can have this as ordinary data with no runtime
support at all — §5.A gives the shape. **The proposal's `Int` is the single weakest signature in
its §6.5 list.**

**4. Structured logging with annotations and levels.** `Effect.log`, `Effect.logInfo`,
`Effect.annotateLogs({ method: "…" })`, a minimum level, a pluggable `Logger`. beni has
`Debug.log : a, String -> a` (`core/Debug.beni:23`), which is a debugging tool that `--release`
now refuses outright. **There is no way to log in a shipped beni program.** That is a capability
gap of exactly the kind CLAUDE.md rule 7 names — it is not a guarantee, it is a missing library —
and it is filled inside the wall or not at all.

**5. `Effect.fn("name")` — automatic spans and better traces.** Wrapping a function so that calling
it opens a span is one line at the definition and nothing at the call sites. beni can go further
than Effect here, because it owns the emitter (D8 option (c)); Effect had to pay for it twice, with
two synthetic `Error`s and a rejected build-time AST transform (`research/14/effect-ts` §7.6).

**6. `timeout` returning an `Option`.** Effect's v4 `timeout` puts the timeout in the error channel
and `timeoutOption` returns `Option<A>`; the proposal's `Task.timeout : Int, (() -> a) -> Maybe a`
already has the better of the two as its only one. Recorded as a thing the proposal got *right*,
because §8's table should not read as one-sided.

**7. Request batching.** `Request.Class` + `RequestResolver` + `Effect.request` collapses N
concurrent lookups into one batched call with dedup, an LRU cache and a configurable delay window
(`references/effect/ai-docs/src/05_batching/10_request-resolver.ts:95-129`). This is the n+1 query
problem solved at the library level. It needs nothing from the language — it is a `Deferred` per
request, a queue, and a timer — and it is a genuinely differentiating feature. T2, but say so.

**8. `Effect.cached` / memoisation with a TTL.** A computation whose result is computed once and
reused, optionally invalidated. beni's `impure` bit exists precisely so the optimiser knows what it
may *not* memoise, and the proposal says nothing about what a user may *ask* to memoise. One
function over a `Ref` and a `Deferred`; not hard, not specified.

**9. Interruption as an explicit API surface.** `Effect.uninterruptible`, `Effect.interruptible`,
`Effect.uninterruptibleMask`, `Effect.onInterrupt`. The proposal has `bracket`'s implicit
uninterruptible acquire and release (§6.3) and nothing a user can reach. §9.1's own accepted risk —
a maintainer adding a log line creates a new interruption point in someone else's
charge-then-reserve sequence — has **no mitigation in the API**, and `uninterruptible (\() -> …)`
is exactly the mitigation. It does not need `sync`, it does not need a type, and it makes the
proposal's sharpest admitted hazard survivable. **This is the highest-value item that the proposal
argues about and does not fix.**

**10. `Effect.forEach` with a concurrency option.** One function, `{ concurrency: n | "unbounded" }`,
covering sequential traversal, bounded fan-out and unbounded fan-out. The proposal splits these:
`List.map` is sequential, `Task.parAll` is bounded, and nothing is unbounded (deliberately —
`research/16` §5.3 row 5 makes the bound mandatory). The gap is that a beni user writing
`List.map ids fetch` gets sequential and has to *know* to reach for `Task.parAll`, where an Effect
user changes one option. A `List.mapPar : List a, Int, (a -> b) -> List b` beside `map` closes it.

Three more, below the line, with the reason they are below it:

- **`Effect.Service` accessors and `Layer` composition** — the value is real and it is the `R`
  question (D1), not a separable feature.
- **`Metric`** — counters, gauges, histograms with a pluggable backend. Real, and it is platform
  work, not core.
- **`Effect.ensuring` / `onExit` / `onError`** — beni gets these from `bracket` and a `case`, at
  the cost of a name. Not a gap, a spelling.

## 7. What is TypeScript-induced, and beni should not copy

"Effect needs to deal with shit we don't." This section counts it.

### 7.1 The machinery census

Twelve modules exist only because TypeScript is the host language, and a further thirteen are real
abstractions that a language with ADTs, exhaustive matching and derived comparison provides rather
than ships.

| Module | lines | exp. | Why it exists | beni's answer |
|---|---:|---:|---|---|
| `Types.ts` | 1 201 | 38 | compile-time utility types, zero runtime | the type system |
| `Function.ts` | 1 385 | 54 | `pipe`, `flow`, **`dual`** | `\|>` is syntax (§6.7) |
| `Predicate.ts` | 1 883 | 57 | runtime type guards | `case` on an ADT |
| `Pipeable.ts` | 675 | 6 | a `.pipe` method on every type | `\|>` again |
| `Unify.ts` | 312 | 8 | stops TS widening `Effect<A> \| Effect<B>` wrongly | unification |
| `Brand.ts` / `Newtype.ts` | 644 | 25 | nominal types faked with a phantom, twice | `pub opaque type` |
| `Inspectable.ts` | 331 | 7 | a `Show` protocol | `Debug.toString` |
| `Utils.ts` | 230 | 4 | internals for the generator syntax | no generators |
| `HKT.ts` | 219 | 4 | higher-kinded types emulated | `language.md` §3: "there are no higher-kinded types" |
| `Effectable.ts` | 137 | 3 | make a value behave like an `Effect` | there is no `Effect` |
| `UndefinedOr.ts` | 239 | 8 | JS has two bottoms | beni has none |
| `Symbol.ts` | 31 | 1 | one runtime predicate | — |
| **(a) subtotal** | **7 307** | **215** | | |
| `Option.ts` / `Result.ts` | 4 335 | 114 | `Maybe` and `Result` as libraries | ADTs in `core/`, plus `?` |
| `Match.ts` | 2 682 | 59 | 2 682 lines emulating `case … of` | `case`, with `missing_patterns` |
| `Order` / `Equivalence` / `Equal` / `Hash` / `Ordering` | 3 106 | 67 | `Eq`/`Ord` as first-class dictionaries | derived `eq`/`compare` (spec §9) |
| `Filter.ts` / `Data.ts` | 1 606 | 43 | refinement-plus-map; tagged constructors | a `case` that binds; `type T = A \| B` |
| `Combiner.ts` / `Reducer.ts` / `NonEmptyIterable.ts` | 565 | 15 | Semigroup, Monoid, a refinement type | a function, a value, — |
| **(b) subtotal** | **12 294** | **298** | | |

**Together: 25 modules, 19 601 lines, 513 exports — 10.2 % of the top-level namespace.**

### 7.2 The data-structure re-implementations

A third group is not TypeScript's fault: it is what any language ships and Effect ships because
JavaScript's standard library is thin. **33 modules, 45 943 lines, 1 188 exports, 24.0 %**:
`Array`, `Iterable`, `Record`, `Struct`, `Tuple`, `String`, `Number`, `Boolean`, `BigInt`, `RegExp`,
`Chunk`, `HashMap`, `HashSet`, the four `Mutable*`, `Trie`, `Graph`, `HashRing`, `BigDecimal`,
`DateTime`, `Duration`, `Cron`, `Encoding`, `Redacted`, `ByteSize`, `JsonPatch`, `JsonPointer`,
`JsonSchema`, `Optic`, `Differ`, `Formatter`.

beni must ship *some* of this — `Duration` is T1, `DateTime` a `boundary.md` §6 capability,
`Encoding` platform work — but none of it is effects work and none is what "Effect-level coverage"
should be taken to mean.

**(a) + (b) = 60 modules, 65 731 lines, 1 728 exports — 34.3 % of the top-level namespace.** One
third of Effect's core fills a hole in its host language or that language's standard library.

### 7.3 `Schema` is a fourth category, and it is the biggest

8 modules, **30 688 lines, 1 092 exports — 16 % of the top-level namespace on its own**, and ~41 %
of it erases. §5.C has the anatomy; the point here is that it is not a validation library but a
runtime re-implementation of the type system, needed because TypeScript's types are erased.
**Counting it as machinery puts the figure over 50 %.** That is the owner's quote made quantitative.
beni's counterpart is `boundary.md` §3.1's codec generator plus `research/18` §6's derived-codec
question — the same capability at a tenth of the size.

### 7.4 `dual` — the largest single tax, measured

`dual` (`Function.ts:102`) makes one implementation callable both data-first (`Effect.map(eff, f)`)
and data-last (`eff.pipe(Effect.map(f))`) by inspecting `arguments.length` at run time. It exists
because TypeScript cannot express two call shapes — and it *still* requires both overloads written
by hand in every signature.

**1 107 `dual(` call sites across 115 non-`internal` files** (1 247 including `internal/`). Worst:
`Stream.ts` 156, `Channel.ts` 82, `Array.ts` 78, `Graph.ts` 46, `Chunk.ts` 41, `Iterable.ts` 32,
`Record.ts` 24, `Option.ts` 24, `TxHashMap.ts` 21, `Sink.ts` 20. **v4 did not drop them**: `TxRef.ts`,
a module that did not exist in v3, imports `dual` on line 15.

Each costs a runtime branch per call, two overload signatures in the `.d.ts`, doubled documentation,
and an inference cliff when the data-last form must guess. **beni deletes the whole category**: `|>`
is pipe-first *syntax* rewritten before anything else (`language.md` §8 step 2), every call is
saturated, the library is subject-first by convention, and `x |> f a` is `f x a` with no second
signature anywhere.

### 7.5 Generators, `Effect.gen` and the `Do` family

`Effect.gen` is still the primary idiom (`LLMS.md:14-23`) and exists because TypeScript has no
do-notation and `yield*` is the only construct that threads a value out of a monadic step with
inference intact. It costs a generator allocation per call (which `Effect.fn` exists to amortise,
`Effect.ts:13537-13558`), the `EffectIterator`/`Yieldable` protocol, `Utils.ts`, `Effectable.ts`, and
— the expensive one — **the call stack and the source location**, which `research/14/effect-ts` §7.6
records Effect paying for twice, with two synthetic `Error`s and a rejected build-time AST transform.

beni's answer is `let`. Seven exports plus three modules plus a `Symbol.iterator` member on every
`Effect` translate to nothing. The proposal §7.1 also **rejects generators as a lowering** for an
independent reason: `yield` cannot cross a function boundary, so every effectful lambda would have to
be its own generator.

### 7.6 The rest of the do-not-copy list

- **Tagged-class boilerplate.** `class HttpError extends Schema.TaggedError<HttpError>()("HttpError",
  { message: Schema.String, status: Schema.Int })` (`ai-docs/…/10_schedules.ts:233-237`) is five
  lines and a `Schema` dependency for what beni writes as
  `type HttpError = HttpError { message : String, status : Int }`. The `_tag`, the factory, the
  self-referencing type parameter and the runtime field schemas all exist to give TypeScript a
  discriminant it can narrow and a witness it can check. Likewise
  `Context.Service<Self, Shape>()("id")`, whose argument order is itself a v3→v4 breaking change
  caused by nothing but inference ordering.
- **Variance annotations and the `Variance` witness** (`Effect.ts:154-158`). beni's subtyping
  question is one two-point lattice (proposal §4.4) and needs no declaration.
- **Overload explosions.** `provideService` has three, `catchTag` four, `provide` six, and `all`'s
  return type is a ~90-line conditional type (`:262-366`). Saturated n-ary calls have one signature.
- **Runtime `is*` guards for what a checker proves** — `isEffect`, `isFailure`, `Cause.isFailReason`,
  all of `Predicate.ts`. `LLMS.md:321-322` instructing users *"**NEVER** write your own helper
  functions like `isRecord` or `isString`"* is a symptom.
- **`satisfiesSuccessType` / `satisfiesErrorType` / `satisfiesServicesType`** (`:15105`, `:15138`,
  `:15168`) — three exports whose only purpose is to make the compiler check a type already written.
- **The `Eager` family** — `mapEager`, `mapErrorEager`, `mapBothEager`, `flatMapEager`, `catchEager`,
  `matchEager`, `matchCauseEager`, `matchCauseEffectEager`, `fnUntracedEager` (`:15180` onward, all
  `@since 4.0.0`): nine exports applying the function immediately when the effect is already
  resolved — a hand-written constant-folding fast path. **beni's §7.2 synchronous fast path is in the
  compiler, applies everywhere, and needs no second name for anything.**
- **`Effectify`/`effectify`** (`:14748`, `:15044`) — turning a Node-style callback API into an
  `Effect`. A `foreign` declaration.

### 7.7 What beni should copy anyway

Two things in these families are worth taking, and saying so keeps the section honest.

- **A typed `Duration`.** Effect's time-taking functions accept `"250 millis"` or a `Duration`; the
  string form is a template-literal trick beni cannot have, but the typed value is the right idea and
  beni should not spell delays as bare `Int` milliseconds the way proposal §6.5 does
  (`Task.timeout : Int, …`). `Duration.seconds 10` costs nothing and prevents the units bug.
- **`Redacted`.** A wrapper whose `toString` does not reveal its contents, so a secret cannot leak
  into a log line. 314 lines in Effect; in beni a `pub opaque type` plus a `Debug.toString` hook —
  and exactly the kind of guarantee CLAUDE.md rule 7 says to keep.

## 8. A proposed beni effects API, v0

Everything below is beni syntax as `language.md` has it today — n-ary types, subject-first,
`where` clauses where evidence is needed — under the proposal's semantics: an effectful call looks
like a call, deferral is a thunk, and `suspends`/`impure` are inferred and never written outside a
`foreign`. **T0** is the minimal kernel a spike must build; **T1** is what makes it feel like
Effect; **T2** is batteries.

Two rules shape every signature. **Subject first, function last** (`language.md` §6.7): `Queue.offer
q x`, not `offer x q`. And **a nullary method cannot be dot-called** — `fiber.join` is a field access
(`static-dispatch-spike.md` §1.1), so `Fiber.join fiber` is the spelling. Signatures taking at least
one argument beyond the receiver read as `x.m a`; the rest are qualified. The effects API is the
first large consumer of that rule and the spec should say so.

### T0 — the kernel

**`Duration`** — pure, no runtime, in T0 because every T0 signature taking a time should take one
of these rather than a bare `Int` (§7.7).
```elm
pub opaque type Duration
pub millis : Int -> Duration        pub seconds : Int -> Duration       pub minutes : Int -> Duration
pub toMillis : Duration -> Int      pub add : Duration, Duration -> Duration
pub max : Duration, Duration -> Duration     pub min : Duration, Duration -> Duration
```

**`Task`** — the entry points.
```elm
pub spawn   : (() -> a) -> Fiber a
pub scope   : (Scope -> a) -> a
pub bracket : (() -> r), (r -> ()), (r -> a) -> a
pub sleep   : Duration -> ()
pub yield   : () -> ()
pub uninterruptible : (() -> a) -> a
pub interruptible   : (() -> a) -> a
```
`spawn`, `scope` and `bracket` are `research/16` §5.3's and proposal §6.5's. `sleep` and `yield` are
the two the proposal leaves implicit and nothing above them works without — `timeout` is a race
against a sleep, and `yield` is the cooperative check `research/16` §3.5 measured at 3 ns.

**`uninterruptible` is this report's one addition to the proposal's primitive list.** §9.1's accepted
risk — a maintainer adds a log line and creates an interruption point inside someone else's
charge-then-reserve sequence — has no mitigation anywhere in the proposal, and §9.1 says so:
`bracket`'s implicit version *"is the right answer for a resource and no answer at all for a
sequence."* Effect has `uninterruptible`, `interruptible` and `uninterruptibleMask`
(`Effect.ts:7387`, `:7326`, `:7422`); beni needs at least the first two, they cost nothing in the
type system, and they turn the proposal's sharpest admitted hazard into something a user can defend
against.

**`Fiber`**, **`Scope`**, **`Deferred`**, **`Ref`**.
```elm
pub foreign type Fiber a
pub join : Fiber a -> Result Cancelled a       pub await : Fiber a -> Exit a     -- await iff D2
pub cancel : Fiber a -> ()                     pub poll : Fiber a -> Maybe (Exit a)

pub foreign type Scope
pub spawn : Scope, (() -> a) -> Fiber a        pub finalizer : Scope, (() -> ()) -> ()
pub cancel : Scope -> ()

pub foreign type Deferred a
pub make : () -> Deferred a                    pub await : Deferred a -> a
pub succeed : Deferred a, a -> Bool            pub isDone : Deferred a -> Bool

pub foreign type Ref a
pub make : a -> Ref a                          pub get : Ref a -> a
pub set : Ref a, a -> ()                       pub update : Ref a, (a -> a) -> a
pub modify : Ref a, (a -> ( b, a )) -> b
```
Effect's `Fiber.interrupt` **blocks until the target has finished**; beni's `cancel` should too, and
`boundary.md` §5.4 already uses "cancel" throughout so the name wins over "interrupt" (D6).
`scope.spawn` and `scope.finalizer` dot-call, which is the reading this API wants; `research/16`
§5.3 row 2 is explicit that a `Scope` escaping its block cannot be typed away, so the guarantee is
the runtime's. `Deferred` is T0 because everything else parks on it. **`Ref` is the first real
consumer of the `impure` bit** (§4.1): `Ref.get` must carry it or the optimiser may memoise two
reads into one, which makes `effects-plan.md` §5 decision 4's "infer `impure`, don't use it in v1" a
miscompile the day `Ref` lands.

### T1 — what makes it feel like Effect

```elm
-- Queue
pub bounded : Int -> Queue a    pub dropping : Int -> Queue a    pub sliding : Int -> Queue a
pub unbounded : () -> Queue a
pub offer : Queue a, a -> ()              -- parks when a bounded queue is full
pub offerAll : Queue a, List a -> ()      pub take : Queue a -> a        -- parks when empty
pub takeAll : Queue a -> List a           pub poll : Queue a -> Maybe a  -- never parks
pub size : Queue a -> Int                 pub shutdown : Queue a -> ()

-- Semaphore
pub make : Int -> Semaphore
pub withPermits : Semaphore, Int, (() -> a) -> a
pub with : Semaphore, (() -> a) -> a
pub withIfAvailable : Semaphore, Int, (() -> a) -> Maybe a

-- Latch
pub make : Bool -> Latch    pub open : Latch -> ()      pub close : Latch -> ()
pub release : Latch -> ()   pub await : Latch -> ()     pub isOpen : Latch -> Bool

-- Task, continued
pub par2   : (() -> a), (() -> b) -> ( a, b )
pub par3   : (() -> a), (() -> b), (() -> c) -> ( a, b, c )
pub parAll : Int, List (() -> a) -> List a       -- the Int is MANDATORY
pub race      : List (() -> a) -> a              -- first to SUCCEED; losers cancelled
pub raceFirst : List (() -> a) -> a              -- first to SETTLE
pub timeout : Duration, (() -> a) -> Maybe a
pub retry   : Schedule e, (() -> Result e a) -> Result e a
pub repeat  : Schedule a, (() -> a) -> a
pub cached  : (() -> a) -> (() -> a)

-- Schedule: pure data, NO runtime support
pub opaque type Schedule a
pub recurs : Int -> Schedule a          pub spaced : Duration -> Schedule a
pub exponential : Duration -> Schedule a    pub fibonacci : Duration -> Schedule a
pub once : Schedule a                   pub forever : Schedule a
pub jittered : Schedule a -> Schedule a
pub while : Schedule a, (a -> Bool) -> Schedule a
pub until : Schedule a, (a -> Bool) -> Schedule a
pub max : Schedule a, Schedule a -> Schedule a     -- continue while BOTH do
pub min : Schedule a, Schedule a -> Schedule a     -- continue while EITHER does
pub modifyDelay : Schedule a, (Duration -> Duration) -> Schedule a
pub tap : Schedule a, (a -> ()) -> Schedule a

-- Clock
pub currentMillis : () -> Int           pub sleep : Duration -> ()

-- Log
pub type Level = Trace | Debug | Info | Warn | Error
pub trace : String -> ()   pub debug : String -> ()   pub info : String -> ()
pub warn : String -> ()    pub error : String -> ()
pub with : String, String, (() -> a) -> a        -- annotate the subtree
pub atLevel : Level, (() -> a) -> a

-- Exit, if D2 says yes
pub type Exit a = Done a | Failed String | Cancelled
```

Notes. **`parAll`'s bound is mandatory and not defaulted** — `research/16` §3.4 measured 901 MiB
against 78.6 KiB for the same 200 000 operations, and *"`'unbounded'` is one word away from a
number"*; **Effect's `"unbounded"` is deliberately not copied.** Only the *scoped* semaphore forms
should exist: Effect also exposes a bare `take`/`release` pair and documents that it is not
interruption-safe, which under rule 7 is a guarantee rather than taste — omit it or bracket it. Its
non-FIFO ordering (`Semaphore.ts:121-124`) is a starvation hazard beni should choose deliberately
and pin with a fixture. `Latch.release` is the non-obvious operation: a one-shot pulse, not a state
change. `Schedule`'s `min`/`max` take v4's names over v3's `union`/`intersect` because they are
better, and the module should land in `core/` **before the runtime**, since none of it needs a
fiber. `Clock` exists less for its two functions than because `sleep` asking a *service* is what
makes `TestClock` possible (§6 item 2) — which makes it the first consumer of D1's option R-B.
**`Log` is missing today**: `core/Debug.beni` is the only way to write a line and `--release` refuses
any build reaching `Debug`, so a shipped beni program cannot log. Effect implements `annotateLogs`
over the fiber-local environment (`Effect.ts:14018`), so **designing `Log` is what will tell you
whether D1 needs R-B**.

### T2 — batteries

**`PubSub`** (`Queue` plus a subscriber list and a replay buffer — an in-process event bus);
**`Pool`** (`Semaphore` + `Queue` + `bracket`); **`Cache`** (`Ref (Dict k (Deferred v))` plus a
clock); **`RcRef`/`RcMap`**; **`FiberSet`/`FiberMap`/`FiberHandle`** — which v4 named as the
replacement when it deleted `Supervisor` (`migration/v3-to-v4.md:16017`), and which need `Exit`
(D2); **`Stream`** (D5 — a pull source and combinators, not `Channel`); **`Request`/`RequestResolver`**
(batching, the n+1 problem, §6 item 7); **`Metric`** (platform); **`Trace`** (D8); **`Tx*`** (D3).

### The signature count

| Tier | modules | signatures |
|---|---:|---:|
| T0 | `Duration`, `Task` (7), `Fiber`, `Scope`, `Deferred`, `Ref` | ~35 |
| T1 | `Queue`, `Semaphore`, `Latch`, `Task` (9 more), `Schedule`, `Clock`, `Log`, `Exit` | ~60 |
| T2 | ten modules | ~150 |

Against Effect's 4 783 top-level exports. The ratio is the report in one number: **beni needs
roughly 2 % of Effect's export count to cover what Effect's `Effect`, concurrency, resource and
scheduling families do**, because direct style, `Result` + `?`, ADTs with exhaustive matching,
derived `eq`/`compare` and `|>`-as-syntax delete the other 98 % at the *language* level rather than
the library level.

## 9. Decisions for the owner

Nine, numbered. Each is framed with options and a recommendation; none is taken here. They are
ordered by how much else depends on them.

### D1. The services / `R` question

*What is beni's answer to dependency injection?* §3.3 lays out four options.

- **(a) R-A alone** — capabilities as record arguments, Elm's answer, the proposal's own §9.3.
- **(b) R-A + R-C** — records where a bag of functions is wanted, `where` clauses where a handle
  with methods is wanted. Both already exist.
- **(c) add R-B** — a fiber-local `Context` for ambient values, which is the only one that needs
  new machinery and the only one that serves `References`-shaped uses (log level, log annotations,
  the scheduler budget, a `TestClock`).
- **(d) R-D alone** — the platform is the environment and there is no injection mechanism.

**Recommendation: (b) now, (c) with the runtime.** (b) costs nothing and covers services and test
doubles. (c) is not optional in the long run because §6's structured logging, `TestClock` and the
scheduler's own `MaxOpsBeforeYield` all want it, and the fiber record already has the parent chain
it needs. What must be conceded in writing under every option: **beni will not have `R = never` at
the entry point** — the compile-time proof that no dependency was forgotten — and that is the
largest single thing Effect has that this design cannot.

### D2. Do defects exist in beni, and is there an `Exit`?

§3.2.2. Effect distinguishes failure (`E`), defect (untyped bug) and interruption, and makes all
three inspectable through `Cause` and `Exit`.

- **(a) No.** `Fiber.join : Fiber a -> Result Cancelled a` as the proposal already types it; a
  defect terminates the program. Nothing to inspect.
- **(b) A three-constructor `Exit a`** — `Done a | Failed String | Cancelled` — with
  `Fiber.await : Fiber a -> Exit a` beside `join`. No `Cause`, no tree, no annotations: the error
  channel is already inside `a` as a `Result`.
- **(c) A full `Cause`.** Effect's shape, flattened as v4 flattened it.

**Recommendation: (b).** (a) makes a supervisor unwritable — nothing can learn *why* a child died,
which is `research/16` §1.4's complaint about Elm's scheduler restated. (c) buys a tree beni has no
source of: `boundary.md` §4.1's recipe means a `foreign` does not throw, `--release` refuses
`Debug`, and the only unruled-out defect source is stack overflow. Decide with it what `Debug.todo`
is: a defect, in development only, and unreachable in a release build.

### D3. Is STM in scope?

v4 keeps transactional memory and reshapes it: the `Tx*` modules are a family of transactional data
structures rather than v3's single `STM` monad.

- **(a) No, ever.** Beni has no mutation to make transactional outside the runtime's own primitives.
- **(b) Not in the first release**, revisited when `Ref` and `Queue` have users.
- **(c) Yes** — it is the difference between "you can write a concurrent program" and "you can write
  a correct one".

**Recommendation: (b).** STM is the one family in Effect's concurrency story with no counterpart in
Elm, Roc, Go or Kotlin, and the `research/16` survey did not consider it. It is also the only one
that constrains the *runtime* rather than sitting on top of it — a transaction has to be able to
retry, which means the runtime must be able to roll back a fiber's writes. Deciding it late is
cheap only if the kernel does not foreclose it; say so in the kernel spec (§8, T0) rather than
discovering it at T2.

### D4. Error accumulation

§3.2.1. Effect's `Effect.all(…, { mode: "validate" })` returns every failure positionally.

- **(a) `Result.combineAll : List (Result e a) -> Result (List e) (List a)` in `core/`**, and
  nothing in the language or the runtime.
- **(b) That, plus a `mode` on the parallel primitives** (`Task.parAll`, and §3.4's `and` group),
  so a parallel group can accumulate rather than cancel its siblings on the first failure.
- **(c) Nothing; the caller writes the fold.**

**Recommendation: (a) now, (b) with the runtime.** (a) is ten lines and is useful today, before any
effects work. (b) is the same question the proposal's §11 Q4 already asks about `and` groups — *"should
a group's items be allowed to fail independently … or should the group collect every result"* — so
it should be answered once, for both.

### D5. Is `Stream` in the first release?

§5.B. Effect's streaming subsystem is its largest battery after `Schema`.

- **(a) No.** T2. A first release ships `Queue` and `PubSub`, which is what a producer/consumer
  program actually needs.
- **(b) A pull-based `Stream` with no `Channel` under it** — beni's `Stream a` is a
  `() -> Maybe a`-shaped thunk source plus combinators, with no bidirectional channel algebra.
- **(c) Effect's shape.** `Channel` as the core, `Stream` and `Sink` as specialisations.

**Recommendation: (a) for the first release, (b) as the target.** Effect's `Channel` is a
bidirectional, typed, effectful pipe with its own error, done and requirement channels; most of
that generality exists to serve `Stream`, `Sink`, RPC framing and HTTP bodies at once. A beni
`Stream` that is honestly just "a pull source and the combinators over it" is a tenth of the size
and covers the reason people reach for it. What forecloses (c) is committing to a `Stream`
*representation* early; keep it opaque.

### D6. Naming — do we keep Effect's names?

A beni user coming from Effect transfers knowledge in proportion to how many names match.

- **(a) Effect's names where the semantics match.** `Queue.offer`/`take`, `Deferred.await`, `Fiber.join`,
  `Semaphore.withPermits`, `Schedule.exponential`, `Scope.addFinalizer`.
- **(b) Elm's names where Elm has one, Effect's where it does not.**
- **(c) beni's own, chosen for the subject-first convention.**

**Recommendation: (a), bounded by beni's own conventions.** The two constraints that bind: the
standard library is **subject first and function last** (`language.md` §6.7), so `Queue.offer q x`
not `Queue.offer x q`; and a type's methods are the `pub` values of its declaring module
(`static-dispatch-spike.md` §1.2), so the name that matters is the one after the dot in `q.offer x`.
Where Effect's name fights either rule the rule wins. Where Effect's name and Elm's differ and
neither fights — `Effect.forkChild` vs `Task.spawn` — say which and why once, in the spec, rather
than case by case.

### D7. Does the first cut have `Cmd`-level cancellation, or only fiber-level?

`boundary.md` §5.4 already specifies `Cmd.keyed` with four policies (`Restart | Ignore | Queue |
Concurrent`) and says commands must be cancellable *"or the runtime's justification stops at this
boundary"*. Effect has no counterpart — its cancellation is handle-based, `Fiber.interrupt` — and
§5.4 argues at length that a declarative architecture keys by value instead.

- **(a) Fiber-level only in the first cut.** `Fiber.cancel`, `Scope`, `bracket`.
- **(b) Both**, with the browser platform's `Cmd` layer landing with the runtime.

**Recommendation: (a) for the spike, (b) before the browser platform ships.** The Node platform has
no `Cmd`; the browser platform cannot ship without it. Naming the four policies now costs nothing
and `boundary.md` §5.4 has already done it.

### D8. `Effect.fn`'s span, and whether spans exist at all

§6 ranks automatic spans high. Effect's `Effect.fn("name")` wraps a function so that every call
opens a tracing span named for it, and the name also improves the stack trace
(`references/effect/LLMS.md:64-66`). beni has no tracer, no span, and no `Tracer` service.

- **(a) Nothing.** Observability is a platform package's business.
- **(b) A `Tracer` in `core/` with `withSpan` as an ordinary higher-order function over a thunk**,
  and no automatic instrumentation.
- **(c) (b), plus compiler support**: a build flag that wraps every `suspends` function in a span
  named for its declaration, which beni can do and Effect cannot, because beni owns the emitter.

**Recommendation: (b), with (c) recorded as the thing to revisit once the CPS lowering exists.**
(c) is a genuine asymmetry in beni's favour and §7.4 of the proposal already requires each
continuation to carry the span of the call it resumes — so the information (c) needs is being
computed anyway. Deciding it late is fine; *forgetting* it is not.

### D9. What `main` may do, restated for effects

`effects-plan.md` §5 decision 5 already frames this (`main : Program` stays and its body is `sync`
vs `main` becomes a thunk) and it is repeated here only because Effect's answer is the opposite and
the comparison is informative: Effect's entry point is `NodeRuntime.runMain(program)`, the whole
program *is* an effect, and v4 went further by building process keep-alive into the core runtime so
a suspended fiber holds the process open without a platform timer
(`references/effect/migration/fiber-keep-alive.md:199-211`). Whatever beni decides about `main`,
**the keep-alive question is a separate one and it has a right answer**: the runtime must hold the
process open while a fiber is parked, or a program that awaits anything exits silently with the
work undone. That is not in `research/16`, it is not in the proposal, and it is the kind of thing
found at 2 a.m. rather than at design time.

## 10. Could not determine

1. **Whether a `Key a` for a fiber-local environment (§3.3 option R-B) can be made safe without a
   language feature.** `Context.Key<I, S>` gets its identity from a class and a string, and
   TypeScript's nominal-typing workaround is what makes it type-safe. beni has `pub opaque type` and
   `foreign type`, and a platform could mint one `foreign type Key a` per service — but nothing
   checked here shows that `Context.get : Key a -> Maybe a` can be typed soundly without either
   existentials or one opaque type per service. **The one item in this report that needs a spike
   rather than an argument.**
2. **How a `Schedule`'s state is carried in beni.** Effect acquires a stateful closure per run
   (`Schedule.ts:250`), which is mutation. A beni `Schedule a` wants
   `{ state : s, step : s, a -> Maybe ( Duration, s ) }`, `s` is existential, beni has none, and
   `checker.md` §6.3 forbids adding to `Kind`. An `Int` counter plus a `Duration` covers `recurs`,
   `spaced`, `exponential` and `fibonacci`, so a fixed state type may be enough — but `while`, `tap`
   and `min`/`max` compose schedules of different states and I did not work out whether the encoding
   survives that.
3. **Whether `combineAll` should be `Result (List e) (List a)` or Effect's non-empty
   `Result (NonEmpty e) (List a)`.** Effect uses `NonEmptyArray<E>` (`Effect.ts:636-643`) because an
   accumulating failure with zero errors is incoherent; beni has no non-empty list type. Whether to
   add one, or accept the incoherence, is a `core/` question this report raises and does not answer.
4. **What `Exit`'s `Failed` payload should be.** §3.2.2 proposes `Failed String`, which is a guess:
   `String` suffices for a stack-overflow report and a `Debug.todo` message and does not suffice if
   anything ever wants to re-raise a defect with its original shape. Effect carries an arbitrary
   `unknown`.
5. **Whether beni should refuse an `impure` call inside a transaction body**, if STM is ever in
   scope. §4.2 notes v4 permits arbitrary effects inside a retried `tx` and that they re-execute;
   beni's `impure` bit could make that a compile error — a guarantee Effect does not have. Whether
   the rule is sound (a `Ref.get` is `impure` and must be allowed) was not worked out.
6. **Whether `Log` needs the fiber-local environment or can be done with an ordinary argument.** §2
   S18 observes that Effect implements `annotateLogs` over the ambient environment, and §8 says
   designing `Log` is what will answer it. That is a claim about the order of work, not an answer.
7. **The export count of `Effect.ts`.** Two methods give 246 and 258 (Method). Nothing turns on it,
   but a future report citing one number should say which.
8. **Whether any Effect concurrency module depends on mutation beni does not have.** §4 says all are
   "library code over the suspension protocol plus a mutable cell", and the dependency graph supports
   it — but `Queue` uses a `MutableList`, `Cache` and `RcMap` a `MutableHashMap`, and `Pool` an
   intrusive free list. Whether `Ref (Dict k v)` stands in for those, or `core/` needs mutable
   collections behind the wall, is a performance question nobody has measured.

---

## 11. Evidence index

**Effect, at `3d59ae6`, `packages/effect` 4.0.0-rc.116.** Paths relative to `references/effect/`.

- `MIGRATION.md` — single versioning `:16-20`, package consolidation `:22-26`, the `unstable/*` tier
  and its 18 named subtrees `:40-50`, the runtime rewrite and bundle figures `:52-57`.
- `migration/v3-to-v4.md` — 16 797 lines, machine-generated (`:5-9`): import map `:11-307`,
  no-counterpart list `:309-356`, removed modules `:358-766`, per-API guidance `:767-16797`. §1.3.
- `migration/cause.md` `:3-26`, `:77-93`, `:103-108`, `:127-138`, `:150-163` — the `Cause` flattening.
- `migration/services.md` `:1-8`, `:48-61`, `:74-83`, `:142-199` — the four-to-one service collapse.
- `migration/error-handling.md` `:172-182`, `:260-269`; `migration/forking.md` `:8-15`, `:58-69`;
  `migration/fiberref.md` `:1-8`, `:236-256`; `migration/runtime.md` `:15-17`, `:84-88`;
  `migration/scope.md`, `equality.md`, `generators.md`; `migration/fiber-keep-alive.md:199-211` (D9).
- `LLMS.md` — the house style: `Effect.gen` `:14-23`, `Effect.fn` `:51-60`, `Context.Service`
  `:128-172`, `catchTag` `:186-213`, and `:321-322`'s "NEVER write your own `isRecord`".
- `ai-docs/src/**` — 49 examples, 3 946 lines, the source of every idiomatic v4 snippet in §2.
- `packages/effect/src/Effect.ts` — §2 throughout; interface `:117-123`, `all` `:492`, `forEach`
  `:777`, the `catch*` family `:2694`–`:3550`, `race` `:4847`, `timeout` `:4564`, `retry` `:4090`,
  resources `:6404`–`:7056`, interruption `:7285`–`:7489`, forking `:8578`–`:8743`, running
  `:8786`–`:9343`, `fn` `:13659`, transactions `:14516`–`:14741`.
- `internal/core.ts`, `internal/effect.ts` — the 18 ops and `FiberImpl`; §4.0.
- The concurrency modules and the `Tx*` family — §4, each cited in place.
- `Schedule.ts` + `internal/schedule.ts` — §5.A. `Pull.ts`, `Channel.ts`, `Stream.ts`, `Sink.ts` —
  §5.B. `Schema*.ts` + `SCHEMA.md` — §5.C. `Config.ts`, `ConfigProvider.ts`, `CONFIG.md` — §5.D.
  `Context.ts`, `Layer.ts`, `References.ts`, `ManagedRuntime.ts` — §3.3, §5.E.
  `packages/platform/**`, `src/unstable/**` — §5.F. `src/testing/**` — §5.G, §6 item 2.
- `.changeset/pre/slow-beans-battle.md:28` — the `ServiceMap` → `Context` rename, §1.3's footnote.

**beni, at `master` `a718b65`.**

- `CLAUDE.md` — rule 6 (the `foreign` wall), rule 7 (*Guarantees, not restrictions*), References.
- `transparent-effects-proposal.md` — the design this report translates. §2 (the two bits), §3.1
  (the `foreign` keyword), §3.3 (bare `let` items), §3.4 (`and` groups), §5 (semantics), §6.1–§6.5
  (the platform and the primitive list), §7 (the CPS lowering), §9.1 (the accepted risk §6 item 9
  answers), §9.3 (capability records, §3.3's R-A), §11 (the open questions).
- `plans/effects-plan.md` — §2.1 (evidence parameters, the `List.eq` hole), §2.4 (`List.map`'s effect
  order), §5 (the eight decisions preceding §9's), §7 (what it could not determine, which §10
  extends).
- `docs/design/language.md` — §0, §3, §6.5, §6.6 (`?`), §6.7 (saturated calls, `_`, `|>`, `<-`),
  *Evaluation order*, §7, §10 (`debug_in_release` on the last line).
- `docs/design/boundary.md` — §2, §3.1 (the codec generator), §4 and §4.1 (the four checks and the
  recipe), §5, §5.1, §5.3, §5.4 (`Cmd.keyed`), §6.
- `docs/design/static-dispatch-spike.md` — §1.1 (a nullary method cannot be dot-called), §1.2,
  §2.1–§2.4, §3, §4, §8.1 (evidence parameters), §9 (derivation), §10.11 (the 64-constraint cap).
- `docs/design/research/16-fibers-and-concurrency.md` — cited through the proposal and the plan:
  §2.3, §2.4, §3.4, §3.5, §5.2, §5.3 (including row 10's cancelled queue taker), §5.5, §5.6.
- `research/17` §4.14, §5.1, §6.1; `research/18` §6; `research/19` §2.1, §4, §5.1.
- `core/Debug.beni:19`, `:23`, `:32`; `core/List.beni`, `core/Result.beni`, `core/Dict.beni` — the
  style every beni snippet here follows.

**Scripts.** `module-map.sh`, `classify.awk`, `erase.mjs`, `agg.mjs`, `count.sh`, and the `Effect.ts`
category pass, all in the session scratchpad; `module-map.sh`'s regex and its one known limitation
are in the Method section.

