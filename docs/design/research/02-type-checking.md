# Fast Type Inference for ML-Family Languages

Evidence from the Elm compiler and the wider field.

Primary source: the local clone at `references/elm` (elm/compiler, Haskell). All paths
below are relative to that root unless a URL is given.

---

## 1. Constraint generation → solving, vs. naive Algorithm W

Elm does **not** implement Algorithm W (interleaved inference + immediate substitution).
It splits inference into two independent phases connected by a pure data structure:

- `compiler/src/Type/Type.hs:51-65` — a `Constraint` AST: `CTrue`, `CEqual`, `CLocal`,
  `CForeign`, `CPattern`, `CAnd [Constraint]`, and
  `CLet { _rigidVars, _flexVars, _header, _headerCon, _bodyCon }`.
- `compiler/src/Type/Constrain/Expression.hs`, `Constrain/Pattern.hs`,
  `Constrain/Module.hs` — a single walk over the canonical AST
  (`constrain :: RTV -> Can.Expr -> Expected Type -> IO Constraint`) that emits a
  `Constraint` tree. This pass never unifies anything; it only allocates fresh flexible
  variables (`mkFlexVar`, `mkFlexNumber`) and builds equality obligations lazily.
- `compiler/src/Type/Solve.hs:74-194` — `solve` walks the `Constraint` tree once and does
  all unification (`Unify.unify`), generalization, and error collection.

**Why the separation helps:**

1. *Batching*: `CAnd` constraint lists let the solver process siblings in one linear pass
   with a single shared `Pools` vector and running `Mark` counter — no re-derivation of
   context.
2. *Declarative scoping for generalization*: `CLet` is the only place rank/generalization
   logic lives (`Solve.hs:157-194`). Ordinary constraint-generation code never reasons
   about when to generalize; that concern is centralized in one function, `generalize`
   (`Solve.hs:275-309`).
3. *Decoupling from AST shape*: constraint generation is trivially testable/replayable,
   while imperative mutation is isolated to one module. Algorithm W entangles
   substitution-building with tree recursion, so every recursive call pays for building an
   ever-growing substitution and composing it — an O(n²) tax that constraint-based HM
   avoids by mutating a variable graph in place.
4. *Whole-program view*: because the constraint tree is built before solving, the solver
   can solve `headerCon` and `bodyCon` at different ranks in one call (§2).

This is the architecture of Pottier & Rémy, *"The Essence of ML Type Inference"*
(http://gallium.inria.fr/~fpottier/publis/emlti-final.pdf) — Elm's `Type.Constrain.*` →
`Type.Solve` is a direct, simplified implementation of that HM(X)-style design.

---

## 2. Union-find + rank/level-based generalization (Rémy's trick)

### 2.1 The union-find substrate

`compiler/src/Type/UnionFind.hs` (172 lines) is a mutable `IORef`-based, **weighted**
union-find (weight = subtree size; Elm reuses the word "rank" for something else, below):

- `fresh` (`:54-59`) allocates an `IORef (PointInfo a)` = `Info weight desc`.
- `repr` (`:62-74`) is find-with-path-compression: it recurses to the root and then
  **rewrites its own link** (`writeIORef ref pInfo1`) to point directly at the
  representative's info — path compression on every lookup.
- `union` (`:130-154`) attaches the smaller-weight tree under the larger and sums the
  weights — classic union-by-size, `O(α(n))` amortized.
- The header comment credits prior art: the Haskell `union-find` package and Yann
  Régis-Gianas's OCaml implementation (`:16-28`).

A `Variable` is literally `type Variable = UF.Point Descriptor` (`Type.hs:77-78`) —
**type variables are graph nodes**, and unification never builds a substitution map; it
mutates the union-find structure directly (`UF.union`, `UF.set`, `UF.modify`).

### 2.2 The generalization-rank field (Rémy/Kiselyov levels)

Separate from union-find weight, each `Descriptor` (`Type.hs:106-112`) carries an integer
`_rank`:

```haskell
data Descriptor = Descriptor
  { _content :: Content, _rank :: Int, _mark :: Mark, _copy :: Maybe Variable }
```

`noRank = 0` marks a variable as **already generalized** (a scheme's bound variable);
`outermostRank = 1` is the top level (`Type.hs:142-149`). This rank is exactly Rémy's
"level" — the nesting depth of the enclosing `let`.

The algorithm lives in `Solve.hs:157-349`:

- `CLet` for a real let-binding (`:157-194`) bumps `nextRank = rank + 1`, grows the
  `Pools` vector of `[Variable]` buckets-by-rank if needed (`MVector.grow`), stamps every
  newly introduced rigid/flex var with `nextRank`, and solves the binding's own constraint
  (`headerCon`) *at that deeper rank*.
- After solving, `generalize youngMark visitMark nextRank nextPools` (`:184`, defined
  `:275-309`) is called — **not a scan of the type environment**, only of the pool of
  variables allocated at this rank:
  - `poolToRankTable` (`:312-322`) buckets the young pool's variables by current rank.
  - `adjustRank` (`:332-349`) recomputes, bottom-up, the true minimal rank each variable's
    structure reaches ("ranks never increase as you move deeper... the outermost rank is
    representative of the entire structure" — comment at `:328-331`), memoized via two
    `Mark` values (`youngMark`/`visitMark`) so each variable is visited once.
  - Any variable whose final rank is still the young rank (i.e. it doesn't escape into an
    enclosing scope) is generalized: `UF.set var $ Descriptor content noRank mark copy`
    (`:309`). Anything belonging to an *older* rank is reinserted into that older bucket
    (`:296`, `:308`) — the "escaping variable / can't quantify locally" case.
- `isGeneric` (`:198-210`) is a debug assertion that crashes with a bug report if this
  invariant is violated — the authors treat rank-correctness as load-bearing.

**Payoff**: generalization is `O(size of the types allocated in this let group)`, never
`O(size of the whole type environment)`. Classic sources:

- Didier Rémy, *"Extension of ML Type System with a Sorted Equational Theory on Types"*,
  INRIA RR-1766, 1992 — the original level-based generalization.
- Oleg Kiselyov, *"Efficient and Insightful Generalization"*,
  https://okmij.org/ftp/ML/generalization.html — levels as "the incremental computation of
  graph dominators"; unification "has to update the level of each free type variable in
  `t` to the smallest of the two levels." Elm's `adjustRank`/`generalize` implement this
  discipline imperatively.
- OCaml uses this in production (`current_level`, `generic_level` sentinel) — the reason
  its checker is fast on huge codebases.

### 2.3 Instantiation with sharing (avoids the classic blowup)

`Solve.hs:574-635` (`makeCopy`/`makeCopyHelp`) turns a generalized scheme into fresh
variables at a use site, using the `_copy :: Maybe Variable` field as a **per-copy memo**:

- Before recursing into a variable's structure it stamps the *original* with
  `Descriptor content rank noMark (Just copy)` (`:602-603`), so reaching the same variable
  again during *this one copy* returns the memo instantly (`:585-587`).
- `restore` (`:642-701`) walks the copy afterward and clears `_copy` so future
  instantiations start fresh.

This defeats the textbook pathological case (`let x1 = (x0,x0) in let x2 = (x1,x1) in ...`):
when `x1`'s type is `(a,a)` with the *same* variable `a` twice, `a` is copied once and the
second occurrence is served from the memo — one instantiation is `O(size of the DAG)`, not
`O(size of the unrolled tree)`. It does **not** eliminate cross-call exponential behavior
(each use site still gets its own fresh copy; that is inherent to let-polymorphism), but it
removes the multiplicative blowup *within* a single instantiation — which real Elm code
hits constantly via big record/alias types referenced many times.

---

## 3. Occurs check: cheap, and more importantly deferred/batched

- `compiler/src/Type/Occurs.hs` is a plain DFS over the `Content`/`FlatType` graph carrying
  a `seen` list (`elem var seen`, `:24-27`) — `O(size of the reachable term)` per call,
  nothing exotic.
- The performance decision is **when it is called**. `Unify.hs` — the hot path for *every*
  unification — calls `Occurs.occurs` in exactly one narrow spot:
  `comparableOccursCheck` (`Unify.hs:423-429`), used only for Elm's
  `comparable`/`appendable` constrained-typeclass-lite feature, with an author's doubt in
  the source: `-- TODO: is there some way to avoid doing this? Do type classes require
  occurs checks?` (`Unify.hs:421-422`). **Ordinary structural unification
  (`unifyStructure`, `unifyFlex`, `unifyRigid`, `unifyAlias`) never calls `occurs`.**
- Instead `Occurs.occurs` is invoked from `Solve.hs`'s helper (`:255-266`), called once per
  name in a `let`'s header *after* that region has been solved (`Solve.hs:155` and `:194`).

So occurs-checking is **batched to one pass per let-bound name**, turning a potential
`O(unifications × term size)` cost into `O(let-bound names × term size)`. On a genuine
cycle the compiler doesn't abort — it sets the variable's `Content` to `Error` and appends
`Error.InfiniteType` (`Solve.hs:260-263`), then continues (§6).

The lesson: don't make the check asymptotically better — make it *rare*.

---

## 4. Avoiding exponential blowups

**The known worst case**: type-checking with let-polymorphism is exponential in the worst
case (each `let fN = (f(N-1), f(N-1))` doubles the type; adversarial constructions are
EXPTIME).

**Elm's mitigations, all verified in source:**

1. *Sharing-preserving instantiation* (`_copy` memo, §2.3) — kills representation-doubling
   inside one instantiation.
2. *Minimal generalization groups via SCC analysis*: `Canonicalize/Module.hs:81-111` and
   `Canonicalize/Expression.hs:309,519-538` run `Data.Graph.stronglyConnComp` over
   top-level (and let-block) definitions, turning each **acyclic** definition into its own
   `Can.Declare`/binding and only grouping genuinely mutually-recursive ones into a
   `CyclicSCC`/`DeclareRec`. Each group becomes exactly one `CLet`
   (`Constrain/Module.hs:56-58`). Small groups ⇒ cheap `generalize` calls.
3. *Records as extensible rows, merged lazily*: `Unify.hs:610-689`
   (`unifyRecord`/`gatherFields`). Records are flattened lazily (`:677-689` follows the
   `Record1`/`Alias` chain), and only differing fields (`Map.difference`, `:617-618`) get a
   fresh extension variable; shared fields unify via `Map.intersectionWith`. No
   materializing a closed record type just to compare two mostly-overlapping records.
4. *No occurs check on the hot path* (§3).
5. Practically, idiomatic Elm never hits the theoretical worst case; the mitigations bound
   *common* costs rather than fixing the complexity class, which is unavoidable for full
   let-polymorphism.

---

## 5. Representation choices

- **No substitution, ever** — mutation-in-place via union-find (`UF.union`/`set`/`modify`)
  replaces substitution application, avoiding Algorithm W's compose-and-rewalk tax.
- **Types are a small closed sum with variables as first-class nodes**: `FlatType`
  (`Type.hs:81-87`: `App1 | Fun1 | EmptyRecord1 | Record1 | Unit1 | Tuple1`) has all
  substructure as `Variable`s (graph pointers), not nested `Type` trees. During solving a
  "type" is a shallow one-level node whose children point into the same mutable graph. The
  deep immutable `Type` (`Type.hs:90-99`) exists only for constraint-generation input and
  error output, converted once via `typeToVar`/`register` (`Solve.hs:424-482`).
- **Compact, unboxed provenance and names** rather than heavy hash-consing:
  - `Data.Name.Name = Utf8.Utf8 ELM_NAME` (`compiler/src/Data/Name.hs:52-53`) — compact
    UTF-8 byte sequences with custom unboxed/`MagicHash` machinery.
  - `Reporting.Annotation.Region`/`Position` (`compiler/src/Reporting/Annotation.hs:69-131`)
    pack a full source span into **two unboxed `Word64#`** (row in high 32 bits, col in low
    32, `:60-66`), attached to nearly every node as `Located a = At Region a`. No file path,
    no heap-boxed pair, no allocation.
  - Elm does *not* hash-cons type terms (cf. Filliâtre's "Type-safe modular hash-consing",
    https://github.com/backtracking/ocaml-hashcons); it gets equivalent sharing free
    because equal types arising from the same variable *are* the same union-find node.
- **PERF-driven top-level lifting**: a comment at `Solve.hs:429-435` documents a real
  profiling finding — *"a 784 line entry in a `let` was causing a ~1.5 second slowdown ...
  Moving it to the top-level ... saved all that time"* — attributed to `typeToVar`/
  `register` cost. One `IORef` per syntactic type-annotation node is not free.

---

## 6. Error reporting without slowing the happy path

- **Provenance is nearly free**: two unboxed machine words per node (§5), paid once at
  parse time.
- **Human-readable type trees are built lazily, only on failure.** `CEqual`'s success
  branch (`Solve.hs:86-90`) never touches `Type.toErrorType`; only the `Unify.Err` branch
  (`Solve.hs:92-96`) produces an `Error.BadExpr`, and `Unify.unify`'s failure continuation
  (`Unify.hs:32-36`) converts the live mutable graph into the printable `ET.Type` tree
  (fresh-variable naming machinery in `Type.hs:552-725`). None of it runs without a
  mismatch.
- **Errors don't abort the build.** Solver `State` (`Solve.hs:66-71`) carries
  `_errors :: [Error.Error]`; `CAnd` is folded with `foldM` (`:143-144`) so a failing
  sub-constraint appends and solving continues on siblings.
- **Explicit cascade suppression.** On failure both variables are merged into
  `Content = Error` (`Unify.hs:44-47`, `errorDescriptor`), and any future unification
  touching them trivially succeeds (`Unify.hs:201-204`: *"If there was an error, just
  pretend it is okay. This lets us avoid 'cascading' errors..."*). Poison once, stay quiet.
- **Module-level fault isolation.** `builder/src/Build.hs`'s `RProblem` lets one module
  fail while independent siblings still compile and cache.

Net effect: the famously good error messages cost essentially nothing on the success path,
because the entire error-rendering subsystem is off it *by construction*.

---

## 7. Parallelism

Confirmed in `builder/src/Build.hs`:

- `fork :: IO a -> IO (MVar a)` (`:120-124`) spawns a GHC lightweight thread per unit of
  work; the comment cites *Parallel and Concurrent Programming in Haskell*, ch. 13.
- `forkWithKey` (`:127-131`) forks one thread **per module**.
- `fromExposed` (`:137-163`): crawling is forked per module, then compiling is forked per
  module (`resultMVars <- forkWithKey (checkModule env foreigns rmvar) statuses`, `:159`);
  `checkModule` reads dependencies via `readMVar (results ! dep)` (`:459`), which
  **blocks**. The module DAG thus becomes an implicit dataflow graph — ready modules run in
  parallel, blocked ones wait on an `MVar`.

**Barrier to intra-module parallelism**: `Type.Solve.solve` is a single sequential `IO`
computation threading one `Env`, one `Pools` vector and one `Mark`/`State` through the whole
constraint tree (`Solve.hs:74`), mutating the union-find graph with no locking. The general
barriers: (a) generalization at a `CLet` must see the fully solved state at that rank before
classifying variables as escaping; (b) unification mutates a shared graph, so parallel
unification needs fine-grained locking or a lock-free union-find; (c) error and rank/mark
bookkeeping is sequential state. Elm's parallelism granularity is strictly one thread per
module.

---

## 8. Incrementality

`builder/src/Build.hs` implements module-granularity, interface-firewalled incremental
compilation:

- `Details.Local path time deps hasMain lastChange lastCompile` (e.g. `:268-331`) tracks
  per-module mtime, deps, and two build-id timestamps: `lastChange` (when the module's
  *interface* last changed) and `lastCompile`.
- `checkDepsHelp` (`:453-503`) classifies each dependency as `RNew`/`RSame`/`RCached` and
  only escalates to full recompilation if a dependency is new or
  `lastDepChange > lastCompile` (`:494-503`).
- **Interface-equality early cutoff** — the actual firewall — is in `compile`
  (`:705-736`): after compiling, it reads the **old** `.elmi` from disk and compares by
  structural `Eq` against the fresh interface (`oldi == iface`, `:722`;
  `Elm.Interface.Interface` derives `Eq`, `compiler/src/Elm/Interface.hs:44`). If equal the
  module reports `RSame` and `lastChange` is **not** bumped, so nothing downstream sees a
  change — even though the `.elmo` object was rewritten. If different, `RNew` cascades
  exactly one hop to direct importers.

  This is the same "early cutoff on unchanged public interface" idea as Rust's red-green
  incremental compilation and Bazel's action graph — verified here as shipped Elm behavior.
- On-disk artifacts: `.elmi` (interface) and `.elmo` (objects) under
  `elm-stuff/<version>/`, plus aggregate `.dat` files (`i.dat`/`o.dat`/`d.dat`) bundling
  them for bulk loading. Format is intentionally undocumented/internal.
- **Caveat**: granularity is the whole module's public interface. If modules are heavily
  interlinked so most changes *do* alter a widely-imported interface, the cascade is large
  regardless. One production report: ~2-minute full rebuilds, 5–45s incremental, root-caused
  to inter-module coupling (https://medium.com/@antewcode/faster-elm-builds-e0669580ee67).
- TypeScript's project references + `.tsbuildinfo` do the analogue at project/file level;
  Rust does it at query-result granularity (finer, better at absorbing local edits). Same
  principle: **cache and compare an interface, not the source, to decide whether to
  propagate work.**

---

## 9. Lessons from other checkers

- **TypeScript**: architecturally lazy/on-demand (`getTypeOfSymbol` resolves and caches per
  symbol), good for editor latency, but structural typing makes specific operations
  quadratic or worse: template-literal types materialize cartesian products of string
  unions; conditional types over large literal unions measured multilinear-to-quadratic (a
  10k×10k union pair took ~19s) — microsoft/TypeScript#47481
  (https://github.com/microsoft/TypeScript/issues/47481). Gel's writeup frames most real TS
  slowness as "asking the checker to do something quadratic"
  (https://www.geldata.com/blog/an-approach-to-optimizing-typescript-type-checking-performance).
  Lesson: unrestricted structural comparison + eager materialization of derived unions is
  the trap; HM-style row-typed systems sidestep it.
- **Roc**: explicit goal of builds that "normally feel instant… almost always complete in
  under 1 second," ideally under 100ms for cached dev builds (https://www.roc-lang.org/fast),
  with sound, decidable, principal inference and no required annotations. Its solver adds
  recursive types and "lambda sets" for closure/effect inference on top of the same
  conceptual pipeline. **Not verified line-by-line** — the repo paths tried returned 404
  (the project has restructured; note it is now implemented in Zig, not Rust, and targets
  native/wasm rather than JS).
- **OCaml**: the production implementation of exactly the Rémy-level algorithm (§2), plus a
  graph-mutation unifier — same shape as Elm's, and the root of its speed reputation.
- **PureScript/F#**: HM-family, not inspected here. Consistent with the general finding that
  the HM core scales roughly linearly and *feature creep* erodes it (PureScript's
  backtracking instance search; F#'s SRTP/units-of-measure constraint solving).
- **General principle**, confirmed by TypeScript and by Elm's own `comparable`/`appendable`
  super-types (the one place Elm pays for occurs checks and extra unification cases,
  `Unify.hs:280-439`): every feature that isn't plain syntactic unification — subtyping,
  unions, ad hoc polymorphism, conditional or higher-kinded types — reintroduces cost
  exactly where pure HM is cheap. **Minimal type-system surface area is itself a performance
  technique.**

---

## 10. Concrete benchmark numbers

Elm 0.19.1, synthetic projects (Elm Discourse, "Help me profile Elm 0.19.2 compiler
speed!", https://discourse.elm-lang.org/t/help-me-profile-elm-0-19-2-compiler-speed/10521):

| LOC | Modules | Full compile | Incremental (1 file changed) |
|---|---|---|---|
| 105,827 | 256 | 0.87s | — |
| 212,067 | 512 | 1.50s | — |
| 424,547 | 1024 | 3.02s | — |
| 849,507 | 2048 | 6.41s | 1.32s |

→ roughly **120,000–130,000 lines/sec** full-compile throughput on synthetic code, and a
**~5× speedup** from the incremental interface firewall at 2048 modules.

Counter-example: a production codebase with ~2-minute full and 5–45s incremental rebuilds,
attributed to heavy inter-module coupling — the synthetic numbers above are best-case,
low-coupling.

TypeScript pathological case: 10k×10k string-literal union conditional type ≈ 19s.

Roc: no published numbers beyond the qualitative "<1s, ideally <100ms" target.

---

## Top 10 highest-leverage techniques, ranked

1. **Rank/level-based generalization (Rémy/Kiselyov).** Turns generalization from "scan the
   whole environment" into "scan the variables allocated since the last let" — an
   asymptotic change, not a constant factor. (`Solve.hs:157-349`)
2. **Union-find with mutation-in-place instead of substitution.** Every "apply the
   substitution" becomes a pointer dereference. (`UnionFind.hs`)
3. **Defer/batch the occurs check** to once per let-bound name, not once per unification.
   (`Solve.hs:255-266`)
4. **Sharing-preserving instantiation via a per-copy memo field.** Neutralizes the classic
   doubling blowup for internally-shared schemes. (`Solve.hs` `_copy`)
5. **Constraint generation/solving separation.** Enables all of the above by centralizing
   rank/mark/env bookkeeping.
6. **Errors don't stop the build**; failing unifications poison a variable to `Error` and
   continue. Keeps one bug from cascading.
7. **Interface-equality early cutoff for incremental builds.** Recompiling a module ⇏
   recompiling its dependents. The single highest-leverage incrementality technique.
8. **Module-DAG parallelism** via a thread-per-module dataflow schedule — cheap, no locking,
   because each module's mutable type graph is thread-private.
9. **Cheap unboxed provenance, lazy error rendering.** Good messages without taxing the
   success path.
10. **Small generalization groups via SCC analysis** on bindings — bounds worst-case group
    size and error blast radius.

## Traps that make checkers slow

- Full substitution/environment application anywhere in the hot path.
- Running the occurs check (or any O(term size) check) on every unification.
- Generalizing by scanning the entire type environment instead of tracking ranks/levels.
- Deep-copying schemes on instantiation without a memo table — turns a shared DAG into an
  exponential tree.
- One giant recursive binding group instead of SCC-decomposed minimal groups.
- General structural subtyping/unions/conditional types layered on a unification core.
- Coarse or absent incremental firewalling — keying invalidation on *source* change rather
  than *public interface* change.
- Materializing pretty-printed type representations unconditionally instead of on the error
  path only.
- Serializing across modules instead of exploiting DAG parallelism — or, conversely, trying
  to parallelize within one module's mutable union-find graph, which is high effort for
  little payoff next to module-level parallelism.
