# The Elm Compiler, Source-Verified — with a Roc Comparison

**Source scope.** Sections 1–3 and the Elm parts of §5 are verified against the local clone at
`references/elm` (a fork ahead of stock 0.19.1 — it uses `UnliftedDatatypes`/`MagicHash`/
`ExtendedLiterals` more aggressively than the classic release). Section 4 (Roc) is verified
against Roc's live repo, FAQ/design docs, and Feldman's post on the Rust→Zig rewrite. **Roc's
compiler is now Zig (`src/`), not Rust (`crates/compiler/`)**, and Roc targets native/LLVM/Wasm —
so it is treated here purely as a front-end/compile-speed and Zig-implementation reference, never
as a JS-backend data point. Items that could not be confirmed from primary sources are flagged
rather than filled in from folklore.

---

## 1. Phase-by-phase map of the Elm compiler

### 1.1 Top-level structure (`compiler/src/`)

| Dir | Job |
|---|---|
| `AST/` | Three ASTs, one per phase: `Source.hs` (raw parse tree, still surface syntax), `Canonical.hs` (fully name-resolved, deliberately pre-caches metadata so later passes are O(1) — `AST/Canonical.hs:34-46`, `:207`), `Optimized.hs` (flattened JS-codegen IR: `VarLocal/VarGlobal/VarEnum/VarKernel`, `TailCall`, `Decider`, `GlobalGraph`/`LocalGraph`, `AST/Optimized.hs:41-77,127-158`). |
| `Canonicalize/` | `Src → Can`: name/scope resolution (`Environment*.hs`, duplicate detection in `Environment/Dups.hs`), effect-manager rewriting (`Effects.hs`). Entry: `Canonicalize.Module.canonicalize`. |
| `Data/` | Foundational types: `Name.hs`, `Utf8.hs`, `Index.hs`, `Map/Utils.hs`, `NonEmptyList.hs`, `Bag.hs`, `OneOrMore.hs`. |
| `Elm/` | Package/model types outside the AST: `Interface.hs` (.elmi format), `Kernel.hs`, `Package.hs`, `ModuleName.hs`, `Version.hs`, `Docs.hs`, `Constraint.hs`. |
| `Generate/` | JS-only backend: `JavaScript.hs` (whole-program DFS/emit), `JavaScript/{Builder,Expression,Functions,Name}.hs`, `Mode.hs` (Dev/Prod), `Html.hs`. |
| `Json/` | Hand-written JSON encode/decode for `elm.json`, tool IPC, `--report=json`; reuses the same `MagicHash`/unboxed-tuple/CPS style as `Parse.Primitives`. |
| `Nitpick/` | Post-type-check *structural* analyses: `PatternMatches.hs` (exhaustiveness/redundancy via Maranget's algorithm, cited in-file), `Debug.hs` (bans `Debug.log`/`Debug.todo` in package publishes). |
| `Optimize/` | `Can → Opt` lowering: `Module.hs`, `Expression.hs`, `Names.hs` (dependency/field tracking), `DecisionTree.hs` + `Case.hs` (pattern-match compilation), `Port.hs` (compiled JSON codecs). |
| `Reporting/` | All diagnostics: position/region types, per-phase error ADTs, pretty-printer doc type, "did you mean" suggestions, snippet rendering. |
| `Type/` | Full HM inference with **mutable, IO-based unification**: `Type.hs`, `Constrain/*.hs`, `Solve.hs`, `Unify.hs`/`Occurs.hs`/`Instantiate.hs`, `UnionFind.hs`. |

### 1.2 Pipeline entry point — `compiler/src/Compile.hs`

```haskell
-- Compile.hs:42-48
compile :: Pkg.Name -> Map.Map ModuleName.Raw I.Interface -> Src.Module -> Either E.Error Artifacts
compile pkg ifaces modul =
  do  canonical   <- canonicalize pkg ifaces modul
      annotations <- typeCheck modul canonical
      ()          <- nitpick canonical
      objects     <- optimize modul annotations canonical
      return (Artifacts canonical annotations objects)
```

Strictly sequential, `Either`-short-circuiting: **canonicalize → typeCheck → nitpick → optimize**.

- `canonicalize` (`:55-62`) → `Canonicalize.Module.canonicalize`; errors → `E.BadNames`.
- `typeCheck` (`:65-72`) → `Type.Constrain.Module.constrain` then `Type.Solve.run`, run under
  `unsafePerformIO` at line 67 **because the solver is IO-based (mutable union-find) even though
  `compile` is pure** — a deliberate escape hatch rather than threading `IO` through the compiler.
- `nitpick` (`:75-82`) → `Nitpick.PatternMatches.check`, pure, runs *after* type checking so it
  only handles well-typed programs, though its logic is purely structural.
- `optimize` (`:85-92`) → `Optimize.Module.optimize`, produces `Opt.LocalGraph`.

### 1.3 The parser — `Parse/Primitives.hs` (no lexer, hand-rolled over raw memory)

There is **no tokenizer stage at all**. The parser type is CPS with four continuations — the
classic Parsec "consumed/empty × ok/err" design:

```haskell
-- Parse/Primitives.hs:53-63
newtype Parser x a =
  Parser (
    forall b.
      ForeignPtrContents -> State
      -> (a -> State -> IO b)               -- consumed ok
      -> (a -> State -> IO b)               -- empty ok
      -> (Cursor -> (Cursor -> x) -> IO b)  -- consumed err
      -> (Cursor -> (Cursor -> x) -> IO b)  -- empty err
      -> IO b
  )
```

This makes `oneOf` **committed-choice, not full backtracking**: a `cerr` (failure after consuming
input) is final for that alternative; only `eerr` tries the next (`oneOfHelp`, `:189-199`).

`State` is `UnliftedType` and stores **raw unboxed machine values, no boxed record**:

```haskell
-- Parse/Primitives.hs:66-76
type State :: UnliftedType
data State = State { _pos :: Addr#, _end :: Addr#, _indent :: Indent, _cursor :: Cursor }
type Indent = Word32#
```

`Addr#` is a bare pointer into the source `ByteString`'s buffer (obtained by pattern-matching
`B.BS (ForeignPtr pos fpc) (I# len)` directly, `:256-263`); `_end` is one-past-end so bounds checks
are pointer comparisons. Position is a **single packed `Word64#` `Cursor`** — row in the high 32
bits, column in the low — so advancing is one arithmetic op (`slide`/`newline`, `:86-97`), and
row/col are never materialized as boxed `Int`s until a diagnostic is rendered
(`Reporting/Annotation.hs:59-105`: *"Anything that leaves the compiler for a human or a tool must
go through this, not through toRowCol"*). Byte matching is raw primops, `INLINE`d:
`eqIndex p o w = isTrue# (eqWord8# (indexWord8OffAddr# p o) w)` (`:443`). Even UTF-8 validation is
a hand-written byte-at-a-time FSM (`skipUtf8`, `:451-469`) — no decoded `Char` is ever allocated.

Whitespace/indentation (`Parse/Space.hs`) is interleaved into the combinator layer, not a separate
pass: `eatSpaces` returns an **unboxed 3-tuple** `(# Status, Addr#, Cursor #)` (`:124`), tabs are
hard syntax errors (`:141`), and `withIndent`/`withBacksetIndent` (`Primitives.hs:340-358`)
push/pop the ambient indent level to implement the off-side rule without a layout pre-pass.

Errors are structured ADTs carrying a `Cursor`, not strings (`Reporting/Error/Syntax.hs:84-137`),
and every low-level combinator takes a `Cursor -> x` "make the error" function from its caller, so
the failure position is captured immediately and converted to human row/col only at render time.

Allocation-consciousness is **surgical, not pervasive**: `BangPatterns` in 25 files, 88 `INLINE`
pragmas in 32 files (concentrated in `Parse/*`, `Data/Name.hs`, `Data/Utf8.hs`,
`Reporting/Annotation.hs`), but only **4 files / ~8 sites** of `{-# UNPACK #-}` project-wide. The
rest of the compiler is ordinary boxed Haskell.

### 1.4 The build driver — `builder/src/Build.hs` (1257 lines)

Two phases: **crawl** (discover the whole module graph, to detect import cycles before compiling —
`checkForCycles`, `Data.Graph.stronglyConnComp`, `:614-633`) then **compile**.

- Crawl does a **full parse** of any changed file (`crawlFile`, `:312-333`) — no cheap header-only
  pre-parse; only files whose `(path, mtime)` are unchanged skip parsing (`:268-289`).
- Concurrency is **one green thread + one MVar per module**, no worker pool:

  ```haskell
  -- Build.hs:120-124
  fork :: IO a -> IO (MVar a)
  fork work = do mvar <- newEmptyMVar; _ <- forkIO $ putMVar mvar =<< work; return mvar
  ```

  A dependent blocks on `readMVar (results ! dep)` per dependency (`checkDepsHelp`, `:456-503`);
  the GHC scheduler is the scheduler. `:116-119` flags this as known-unoptimized:
  `-- PERF try using IORef semephore on file crawl phase?`
- **Staleness = mtime equality**, no content hashing (`Elm/Details.hs:83-94`): `_time`
  mtime-equality catches saves/checkouts, and `_lastChange`/`_lastCompile` `BuildID`s catch
  "interface changed but wasn't recompiled."
- **The key perf trick**: a recompiled module whose *interface is structurally unchanged* does not
  force dependents to recompile. `compile` (`:705-736`) compares the new `.elmi` against the cached
  one by value equality; `RSame` keeps the old `lastChange`, `RNew` bumps it. Dependents recompile
  only if a dep's `lastChange` is newer than their own `lastCompile` — editing a function body
  without changing its signature does not cascade.
- Cache on disk (`builder/src/Stuff.hs`): `elm-stuff/<version>/d.dat` (whole-project `Details`),
  `i.dat`/`o.dat` (combined interfaces/object graph), plus per-module `<Module>.elmi`/`.elmo` —
  all plain `Data.Binary.encodeFile`/`decodeFileOrFail` (`File.hs:67-89`), no custom container.

### 1.5 Optimize / dead-code elimination — the exact mechanism

Every top-level binding, in **every module of every dependency package**, becomes one entry in a
single flat whole-program map:

```haskell
-- AST/Optimized.hs:76, 127-158
data Global = Global ModuleName.Canonical Name
data GlobalGraph = GlobalGraph { _g_nodes :: Map.Map Global Node, _g_fields :: Map.Map Name Int }
data Node = Define Expr (Set.Set Global) | DefineTailFunc ... | Ctor ... | Enum ... | Box
          | Link Global | Cycle ... | Manager EffectsType | Kernel [K.Chunk] (Set.Set Global)
          | PortIncoming Expr (Set.Set Global) | PortOutgoing Expr (Set.Set Global)
```

Each `Node` carries its own out-edges as a `Set Global`, populated during
`Optimize/Expression.hs` by the `Names.Tracker` monad (`registerGlobal`). Codegen
(`Generate/JavaScript.hs:38-58,149-244`) is a plain **visited-set DFS from `main` and every
port/exposed value**, emitting a node's dependencies before the node itself (post-order).

**Anything not reachable from a root is never even looked up, let alone emitted** — there is no
separate minification/tree-shaking pass; dead code is simply never generated, because the
whole-program call graph is statically known (no dynamic dispatch to break soundness). This is the
entire mechanism behind Elm's small bundles.

Field-name shortening rides the same graph: `Names.Tracker` counts global field-usage frequency
into `_g_fields :: Map Name Int`; `Generate/Mode.hs:40-63` buckets fields by frequency and assigns
the shortest JS identifiers to the *most globally common* names, in `Mode.Prod` only.

### 1.6 Generate/JavaScript.hs

- **Builder**: a custom typed JS AST (`Generate/JavaScript/Builder.hs:38-77`), reduced to
  `Data.ByteString.Builder` only at final serialization — with an explicit rejected-alternative
  comment (`:27-39`) noting a direct-`Builder` approach was tried, found "neutral for perf," and
  rejected because it lost the ability to inspect/strip closures structurally.
- **A2/F2 uncurrying, arity cutoff 9**: creation wraps arity 2–9 in `F2..F9`; calls use `A2..A9`;
  outside that range it falls back to manual JS currying (`Expression.hs:320-343`, `:368-392`).
  Runtime helpers (`Functions.hs:18-89`) tag closures with `.a` (arity)/`.f` (impl):
  `A2(fun,a,b) { return fun.a === 2 ? fun.f(a,b) : fun(a)(b); }` — fast path for saturated calls,
  correct fallback for partial application.
- **Modes** (`Mode.hs:24-26`): `Dev (Maybe Extract.Types) | Prod ShortFieldNames`. In Prod: char
  literals inlined rather than wrapped in a Unicode-correct kernel call; zero-payload enum values
  become bare integers; `Unit` becomes literal `0`; constructor tags become small ints rather than
  strings; field names are frequency-shortened. Dev additionally emits a `console.warn` nudging
  toward `--optimize`.
- **Records**: plain JS object literals; update goes through a shared kernel helper
  `_Utils_update` rather than being inlined per call site.
- **Custom types**: tagged JS objects — `$` field for the tag plus positional `a,b,c...` fields.
  **Zero-arg constructors skip object allocation entirely and become raw integers in Prod.**
- **Strings**: native JS strings, no wrapper.
- **Lists**: not JS arrays — cons-style linked lists via kernel calls (`_List_fromArray`/`Nil`);
  the cons-cell shape lives in `elm/core`'s kernel JS, outside this clone.
- **Pattern matching**: `Optimize/DecisionTree.hs` builds a decision tree using SML/NJ heuristics
  (paper cited in-file); `Optimize/Case.hs` deduplicates — a branch reachable from exactly one path
  is inlined, one reachable from several is compiled once and jumped to, avoiding code blow-up.

---

## 2. Data representations & serialization

- **`Name` (identifiers) is NOT interned.** `Data/Name.hs:59-63` — `type Name = Utf8.Utf8 ELM_NAME`,
  and `Data/Utf8.hs:65-66` is `data Utf8 tipe = Utf8 ByteArray#` — a raw GHC byte array with **no
  dedup/symbol table anywhere**. Equality/ordering are hand-written byte-array comparisons via
  `compareByteArrays#` (`:246-277`). Every `Map Name.Name v` (scopes, type environments,
  interfaces) therefore pays a full byte compare per lookup. ~90 well-known names are precomputed
  `NOINLINE` CAFs to share at least the common ones (`Data/Name.hs:426-603`).
- **`Data/Index.hs`**: a `newtype ZeroBased Int` constructible only 0-based but rendered 1-based
  (`toMachine`/`toHuman`), preventing off-by-one bugs between internal indices and "2nd
  argument"-style messages; `indexedZipWith` returns `LengthMismatch` rather than truncating.
- **`Data/Map/Utils.hs`**: adds `fromKeys`/`fromValues` and a hand-written short-circuiting `any`
  over `Data.Map.Internal`'s tree directly, avoiding a list round trip.
- **`Data/NonEmptyList.hs`**: `data List a = List a [a]`, making "cannot be empty" invariants
  explicit in types rather than relying on partial-function discipline.
- **Binary serialization (.elmi/.elmo)**: plain `Data.Binary`, but **every instance is
  hand-written**, never `deriving Generic`. Sum types get explicit tag bytes
  (`Elm/Interface.hs:199-217`). `Name`/`Utf8` gets a size-optimized encoding —
  `putUnder256`/`getUnder256` (`Data/Utf8.hs:517-528`) write **one length byte + raw bytes**
  instead of `Data.Binary`'s variable-length `Int` prefix, since identifiers are near-universally
  under 256 bytes. Rationale: precise on-disk format control, and avoiding `Generic`'s
  representation indirection on the most frequently executed deserialization path in the toolchain
  (every dependency's interface is read on every build).
- **Strictness is surgical**: only 4 files / ~8 sites use `{-# UNPACK #-}` project-wide, all on hot
  numeric fields (version numbers, union-find weight refs, record field-order tags). Unification
  itself is classic mutable weighted union-find over `IORef`s (`Type/UnionFind.hs:40-47`).

**Design implication.** Elm's strategy is not "optimize everywhere" — it is "drop the
tokenizer-free parser and position representation to raw unlifted primitives because that code
runs once per source byte of every file," while leaving canonicalization/inference/optimization as
ordinary boxed Haskell. Not interning `Name` is a real, identifiable cost paid throughout the back
half of the pipeline.

---

## 3. Where Elm is fast, where it is slow

**Fast / deliberate:**

- Hand-rolled, no-lexer, CPS combinator parser reduced to raw pointers and packed cursors for the
  highest-frequency code path.
- Committed-choice parsing avoids the exponential backtracking a naive combinator/PEG parser hits.
- Interface-content recompilation short-circuit: a body-only edit does not cascade to dependents —
  genuinely finer-grained than GHC's module-granularity-only caching.
- Whole-program `Global → Node` reachability DFS gives *exact*, structurally guaranteed dead-code
  elimination with no separate tree-shaking pass and no dynamic-dispatch soundness holes.
- Heavy optimization (`--optimize`, field shortening, enum-to-int, int ctor tags) is opt-in; a
  normal `elm make` pays none of it.
- Exhaustiveness and decision-tree compilation reuse published algorithms (Maranget; SML/NJ) rather
  than ad hoc ones, and `Optimize/Case.hs` deduplicates branches to avoid code blow-up.

**Slow / limited (verified):**

- **No `Name` interning** — every identifier comparison in canonicalization, inference and
  optimization is a byte-array compare, not an integer compare.
- **Crawl always fully parses changed files** — no header/import-only pre-pass, so a one-line
  change to a huge file costs a full parse before scheduling can begin.
- **Concurrency is one green thread + one MVar per module, flagged in-source as unoptimized**
  (`Build.hs:116-119`) — no work stealing, no bounded pool; large fan-out graphs oversubscribe the
  RTS scheduler.
- **Staleness is mtime-only**, not content hash — fine locally, the documented root of CI-slowness
  reports (elm/compiler#1473: 2.6s local vs 234s on Travis, ultimately traced to package-download
  caching rather than the compiler's own algorithm).
- **Type aliases are fully expanded into `.elmi` at every use site** — large shared record aliases
  duplicate across every dependent's interface, inflating both `.elmi` size and compile time
  (elm/compiler#1453; workaround is manually opaque-typing large shared records).
- **Type solving runs under `unsafePerformIO`** (`Compile.hs:67`) because unification is
  IO/mutable — not a bug, but evidence the clean phase boundaries mask an imperative core.
- Anecdotal, self-reported (Discourse, not independently audited) real-project times: ~50k LOC ≈
  5s, ~120k LOC ≈ 13s, ~194k LOC ≈ 21s full builds; incremental rebuilds ~1–5s.

---

## 4. What Roc does differently, and why

**Roc's compiler is now Zig (`src/`).** The Rust tree is reachable only at the `alpha4-rolling`
tag; `main` has no `crates/` directory. Roc targets native code via LLVM/its own backends and Wasm.

- **Compile speed is a language-design constraint, not just an implementation goal.** Roc's FAQ
  states refinement/dependent/uniqueness types are permanently rejected specifically because they
  cause exponential compile-time blowup, and wildcard imports are banned partly so "the name
  resolution step in compilation can be parallelized across modules." Elm makes no comparable
  public commitment — its simplicity is attributed to audience/scope, not a stated compile-speed
  budget.
- **Explicit target numbers** (roc-lang.org/fast): incremental/cached builds under 1s,
  aspirationally ~100ms — stated as a *cached*-build target, not a clean-build guarantee. No
  verified numbers exist for compiling actual Roc *programs* at scale; the only published figures
  are self-hosted compiler build times from the migration: 3.4s Rust / 8.6s Zig / **0.035s
  Zig-incremental** for rebuilding the ~450K-line compiler itself.
- **Pipeline shape is the same family as Elm's** (parse → canonicalize → check (constrain + solve +
  unify) → monomorphize/lower → codegen), but type solving uses an explicit, reusable **mutable
  arena of type variables with an undo/journal trail** (`src/types/store.zig`'s `Slot`/`Descriptor`
  store with `SlotUndo`/`DescUndo`/`UnionRankUndo`) rather than Elm's `IORef`-per-node union-find —
  supporting rollback/speculation without cloning. A current design doc (`reunify.md`) explicitly
  targets *removing* Elm-style repeated tree-walking/re-solving: "Substitution over frozen schemes
  is a memoizable, allocation-light copy; interned monotypes give O(1) interning equality."
- **Reference counting instead of GC or a borrow checker.** Roc inserts `incref`/`decref`/`free` as
  explicit LIR statements at compile time (backends just execute them). No Elm analogue — Elm's JS
  output relies on V8's GC — and **not applicable to a JS target**; noted only as a verified
  architectural difference.
- **"Morphic" opportunistic-mutation analysis was real in the Rust era** (`alias_analysis` crate
  depending on external `morphic_lib`) **but has no confirmed equivalent in the current Zig
  codebase** — a repo-wide search found nothing beyond substring hits on "poly*morphic*," and the
  glossary's "Alias Analysis"/"Mutate in Place" entries are literal TODOs. Flag as
  unverified/possibly dropped.
- **"Perceus" is not named in any current official Roc doc** found; Roc's docs cite a thesis
  (J. Teeuwissen, "reference counting with reuse in Roc") rather than the Perceus paper. The
  attribution circulates in talks/HN threads — community-level, not source-verified.
- **Zig-specific idioms directly relevant to a Zig-based compiler** (all verified against `main`):
  - A **custom single-thread-owned arena** (`SingleThreadArena.zig`) built explicitly to avoid
    `std.heap.ArenaAllocator`'s atomic RMW/`cmpxchg` overhead per allocation, since every arena is
    owned by exactly one worker thread for its lifetime — "dropping it leaves a plain bump in the
    fast path."
  - **Struct-of-arrays collections with dense integer IDs**, enforced by a CI lint that *rejects any
    `HashMap` keyed by a type named `...Id`* — dense IDs map to parallel-array storage; `...Key` is
    reserved for structural identity that must survive serialization.
  - A **hand-rolled work-stealing/actor-style scheduler** (Rust era: `crossbeam::deque`; Zig era:
    `coordinator.zig` — single mutable-state owner, pure worker threads, bounded channels, one
    arena per worker). No Salsa or other off-the-shelf incremental framework in either era.
  - **Target-independent, per-module content-hash cache keys** (`cache_key.zig`: source bytes +
    module identity + checking-context identity + direct import artifact keys; filename = hex
    digest) plus **"zero-parse deserialization"** — cached artifacts are index-based SoA data
    loaded "roughly the speed of memcpy" via scatter-gather `pwritev` serialization with fixed
    alignment (`CompactWriter.zig`). Strictly stronger than Elm's mtime staleness and tag-byte
    `Data.Binary` decode.
  - Rust→Zig motivations (Feldman, rtfeldman.com/rust-to-zig): Rust assumes one global allocator
    while the compiler wants many arenas; ~1,200 required `unsafe` blocks from SoA layouts; cargo
    incremental build times were a growing pain; the old lambda-set specialization design was
    "architecturally broken across several compiler phases." None are Elm-relevant (Elm has no
    monomorphization phase at all), but all are relevant to a new compiler written in Zig.
  - No verified numbers exist for Roc compiling *Roc source*; the quicksort-vs-Go/C++ benchmarks are
    runtime performance, unrelated to compile speed — don't conflate them.

---

## 5. Design decisions for a new Elm-like-to-JS compiler

### Copy

| Decision | Reason |
|---|---|
| Hand-written, no-lexer, combinator/recursive-descent parser directly over bytes | Avoids a separate token-stream allocation pass; Elm drops to raw pointers here precisely because this runs once per byte of every file, every build. |
| Committed-choice (`consumed`/`empty` × `ok`/`err`) combinators, not full backtracking | Prevents exponential blow-up on ambiguous prefixes while keeping precisely located errors. |
| Structured, position-carrying error ADTs resolved to human row/col only at render time | Keeps the hot path free of string formatting. |
| Whole-program `Global → Node` reachability DFS from `main`/ports for DCE | Exact, structurally guaranteed tree-shaking with no separate minifier — the actual mechanism behind Elm's small bundles. |
| Field-name/tag shortening driven by whole-program frequency counts, gated behind a prod mode | Keeps default builds fast and debuggable while still producing small output on demand. |
| A2/F2-style arity-tagged call wrappers with a small hard arity cutoff | Handles higher-order/partial application in dynamically-typed JS output without full closure-conversion machinery. |
| Interface-content-equality short-circuit for incremental builds | The single best idea in Elm's build driver — cheaper and more correct than whole-project rebuild or naive mtime propagation. |
| Content-hash-keyed, target-independent module cache with zero-parse/memcpy-speed load (Roc's `cache_key.zig`/`CompactWriter.zig`) | Strictly better than mtime staleness + tag-byte decoding; content hashing survives `git checkout`/CI cache restores. |
| Intern identifiers into small integers up front | Elm pays a byte-array compare on every `Map Name v` lookup through the whole back half — a verified, avoidable cost. |
| Dense integer IDs + SoA storage for AST/IR nodes, enforced by lint (Roc's `...Id` vs `...Key` split) | Cache-friendly, avoids hash-map overhead on the hottest structures; directly portable to Zig. |
| Per-thread-owned bump arenas instead of a shared allocator (Roc's `SingleThreadArena.zig`) | Removes atomic RMW overhead from the hottest allocation path once module compilation is parallel. |
| Non-naive pattern-match compilation (decision trees + branch dedup) | Avoids both missed exhaustiveness and code-size blow-up; `Optimize/DecisionTree.hs` + `Case.hs` is a good template. |
| Heavy optimization as an opt-in pass, not default pipeline behavior | Fixpoint/iterative work should not tax every dev-loop build. |

### Do NOT copy

| Decision | Reason |
|---|---|
| Un-interned `Name` as a raw byte array compared byte-for-byte everywhere | Verified structural cost through the whole back half; interning is strictly better and cheap on day one. |
| mtime-equality-only staleness detection | Doesn't survive `git checkout`/CI cache restores; content hashing is barely harder and strictly more correct. |
| "One green thread + one MVar per module" with no pool/backpressure | Elm's own source flags this as an unaddressed PERF TODO; a bounded work-stealing pool avoids oversubscription. |
| Fully parsing every changed file during dependency crawl | Wastes work when only the import list is needed to schedule; a cheap header pre-pass lets scheduling start earlier. |
| Fully expanding type aliases into every dependent's interface file | Documented bloat (elm/compiler#1453) in both `.elmi` size and compile time; needs a sharing/interning scheme for aliased structural types. |
| Ad hoc per-type binary serialization with no content addressing | Works, but tag-byte `Data.Binary` is slower to load than an index-based, memcpy-loadable format; design for zero-parse loading from the start. |
| Adopting compile-time-heavy ML features "for free" — typeclass-style instance resolution, row-polymorphism/type-level lists, or a default fixpoint simplifier | Every documented "slow ML compiler" data point traces to one of these three: PureScript's 476M-call dictionary-filtering bug, PureScript's RowList super-exponential blowup, GHC's simplifier/TH costs. |
| Porting Perceus/Morphic-style RC-with-reuse into a JS-target compiler | Both are mechanisms for native, GC-less memory management; JS output runs under V8's GC, so the entire class is inapplicable. |

### Synthesis: what separates fast from slow compilers in this family

Every verified "slow" data point traces to one *specific, nameable* mechanism, not to generally
worse engineering: PureScript's measured 2.5× regression was 476 million dictionary-equality calls
from typeclass-instance lookup keyed wrong; PureScript's RowList issue is type-level-list
elaboration blowing up super-exponentially; GHC's slowness is attributed by its own community to
superlinear-in-module-size typechecking/simplification, module-granularity-only caching,
package-boundary serialization of parallelism, and Template Haskell forcing extra compile+run
cycles.

Conversely, both languages verified fast here — Elm and OCaml — simply **do not have** typeclass
resolution, type-level programming, or default whole-program optimization passes. Their speed is
the *absence of a mechanism*, not a superior implementation of an equivalent one. A new
Elm-like-to-JS compiler inherits this for free by staying scope-limited. The higher-leverage
remaining work is exactly the caching/interning/scheduling details above — content-hash staleness,
interned names, dense-ID/SoA IR, worker-pool scheduling, zero-parse cache format — where Elm's own
implementation is verifiably behind what Roc's Zig rewrite does.
