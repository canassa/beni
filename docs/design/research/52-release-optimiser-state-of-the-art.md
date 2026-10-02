# The release optimiser against the state of the art

**Status:** research, 2026-10-02. Not normative. **Nothing here changes the compiler.** The owner
asked: *"are we using state-of-the-art algorithms for the release optimiser? This is an old
problem; others have solved it."* The optimiser in question is `src/js/Spec.zig`, `backend.md`
§9's *Whole-program specialisation*, about 7 550 lines. It runs after every module is lowered and
before `Opt` (`src/js/Opt.zig`, local dead bindings) and the printer. It works with `Reach`
(`src/js/Reach.zig`, declaration reachability before lowering) and `Minify` (`src/js/Minify.zig`,
hand-written JavaScript).

**What was done.**

1. The primary literature and the production implementations were read. Six of the
   implementations are now shallow submodules under `references/`: `llvm-project`,
   `closure-compiler`, `graal` and `ghc` sparse, `mlton` and `egg` whole. `references/README.md`
   lists the commits and the sparse paths.
2. `Spec.zig` was audited part by part against what was found.
3. Five experiments were run. They used master's compiler and, for counting only, a compiler with
   counters and raised caps added to `Spec.run`. That copy was never committed; the scripts are
   described in §7.

**Read §0, then §4.**

---

## 0. Findings

### 0.1 The verdict

**The facts are mostly state of the art; the architecture that computes them is not.**

**The facts.** Each analysis in `Spec.zig` is a recognisable, well-chosen algorithm, and some are
ahead of production JavaScript optimisers:

- an Andersen-style, allocation-site, field-sensitive points-to analysis with an on-the-fly call
  graph — Closure Compiler has no points-to analysis at all (§2.6);
- an optimistic constant lattice for parameters, variables, fields and returns, in Wegman and
  Zadeck's sense;
- parameter and key elimination that matches Closure's `OptimizeParameters` and MLton's `Useless`;
- case-of-known-constructor and inline-once that match GHC's simplifier.

**The architecture** is the textbook *iterate separate analyses with rewrites in between*. The
literature showed thirty years ago that this is both weaker and slower than one optimistic
combined fixpoint:

- Wegman & Zadeck 1991, p.192;
- Click & Cooper 1995, Click's thesis §1.2 and §3.7;
- Lerner, Grove & Chambers 2002.

Four concrete divergences cost something today:

1. **No reachability inside the fixpoint.** Both arms of every `if` are analysed even when the
   facts decide the test, and a function's body is analysed whether or not a live call reaches it.
   Rounds of analyse → rewrite → prune recover the acyclic cases. They can never recover a fact
   whose dead branch is dead *because of* that fact. Measured as E2 below.
2. **Iteration by ordered sweeps over whole statements, with caps.** Facts flow from caller to
   callee, and declarations are emitted callee-first, so each level of a call chain costs a sweep.
   A round that hits the 24-sweep cap rewrites nothing at all. That is a cliff: a 24-deep
   pass-through chain switches off facts 1–5 for the whole program (E1).
3. **Fact 3's transfer functions are not monotone.** A read through a ⊤ value forgets the
   `prim`/`null`/`undefined` bits that the same read through that value's earlier site set gave.
   This, not anything inherent, is why the fixpoint depends on walk order. It is also why
   `backend.md` §9 concluded on 2026-10-02 that exact incrementality and a free iteration order are
   impossible. Monotone frameworks reach one least fixpoint under every fair order (Kildall 1973;
   Kam & Ullman 1977; Cousot 1977).
4. **Repeated full analyses.** A release build runs the whole analysis 4.0 times on average, and
   up to 9 times, each one from ⊥ (E3). The analysis is about 20% of a TodoMVC release build and
   36% of a 100 000-line one (`backend.md` §9, *As built — the worklist*).

What it does **not** cost today is many bytes. Raising every cap changes 5 of 411 programs, by
14–46 raw bytes each (E3). The architecture change is about:

- robustness: no cliffs, no order dependence;
- compile time;
- determinism that holds by construction rather than by a fixed schedule;
- incrementality, which becomes possible.

The byte wins visible now are three gaps in what the facts can say, independent of the
architecture (§3.6):

- `x || true` is not folded when `x` is not a literal. This leaves two dead bodies on 28 of 59
  `browser-tea` pages, about 40 brotli bytes each (E4).
- A call's constant result is never used, though `language.md` §6 licenses it for pure callees.
- No function is ever cloned for its arguments.

### 0.2 What was measured

| | Experiment | Result |
|---|---|---|
| **E1** | `f1 … fN`, each `if x * 3 > 1000 then x else f(k+1) x * 2 + f(k+1) x`, `main` calls `f1 7` (§7) | N ≤ 23: every parameter folds and dropped. **N = 24: nothing is specialised anywhere** — not even `7*3>1000` in `main`. The round reaches the 24-sweep cap and declines. The corpus's deepest round needs 8 sweeps (facts 1–5) and 41 (fact 3, cap 64) |
| **E2** | `go verbose n = if n ≤ 0 then 0 else if verbose then 100 + go True (n - 1) else 1 + go verbose (n - 1)`, called `go False 10` | `verbose` is never specialised: the dead arm's `go True` makes it ⊤, and ⊤ keeps the arm alive. With the arm passing `verbose` instead (control), it folds to `c=a=>a<=0?0:1+c(a-1)`. An optimistic combined analysis folds both |
| **E3** | All 348 single-file `run/` programs, 59 `browser/tea` pages and 4 `bench/todomvc` apps, release, with counters (§7) | Full analyses per build: mean **4.02** (1: 22 builds, 2: 21, 3: 133, 4: 109, 5: 48, 6: 42, 7: 28, 8: 7, 9: 1). Sweeps per analysis 4.1 (facts 1–5) and 7.2 (fact 3). **The pass loop's cap of 3 was still finding work in 65 builds (16%).** No round failed to converge. With every cap raised (rounds 16, passes 16, sweeps 1 000): 5 builds smaller by 14, 14, 14, 24 and 46 raw bytes; mean analyses 4.48, maximum 17 (`SyncKeyedPolicies`) |
| **E5** | The same, passes alone raised | **Four `browser/tea` pages panic on the sixth pass** (`ApplicationNotHttp`, `DefectInUpdate`, `DefectReleasesHost`, `LatestTagger`): `index out of bounds: index 2863311530` — `0xAAAAAAAA`, the safety build's fill for undefined memory — in `Pts.escapeSite` (`Spec.zig:6030`), from `Pts.combine` (`:6938`). Five passes are fine. A latent use of stale state across passes that today's cap hides |
| **E4** | Release output of the same 411 programs, searched for folds left undone | `\|\|true` 32 times in 28 files, `null.length`/`null[` 32 times. All 32 are `platforms/browser/Rt.beni`'s `sameInputs` and `sameInputsBut` with `b` folded to `null`: `if(a===null)return true;if(a===null\|\|true\|\|a.length!==null.length)return false;let b=0;while(…a[b]===null[b])…`, where `a=>a===null` is the whole function. Folding both by hand: **−39.5 brotli bytes per page** (−158 raw) on all 28 pages |

### 0.3 Decisions for the owner

1. **Adopt the combined fixpoint (§4) as the optimiser's architecture.** The alternative is to keep
   the rounds and only fix the three local defects (E1's cliff, fact 3's monotonicity, E5). The
   proposal does both, in slices, with byte-identity checkpoints. It is research's recommendation.
2. **Fix E5 now, whatever is decided.** It is a latent undefined read. Rule 3 wants a fixture first;
   a unit test that raises `max_passes` is the smallest input that reaches it.
3. **Whether `Spec` may use the checker's purity.** `language.md` §6 says a pure expression's value
   may be dropped and a pure call is droppable. `Spec` does not know which JavaScript calls are
   pure, so a call whose result the facts know is never replaced (E1's `c()*2+c()` with `c=()=>72`).
   Handing `Spec` the checker's `Effects` bit per function is small. It moves `language.md` §6's
   licence into the whole-program pass. A diverging pure call may then vanish, which §6 already
   allows `Opt` to do.
4. **Whether to clone.** LLVM's FunctionSpecialization and GHC's SpecConstr make copies per constant
   argument; `Spec` only drops a parameter every call agrees on. In a browser-first language a
   clone costs bytes. The question is whether a size-gated rule is wanted: clone only when the
   copies print smaller than the original plus calls, as LLVM's ≥20%-savings gate does. Research
   recommends deciding after the combined fixpoint lands, because it changes what is constant.
5. **Not recommended:** equality saturation, a general Attributor-style framework, an embedded
   Datalog engine, or partial escape analysis now (§4.7).

---

## 1. `Spec.zig` in the literature's terms

| Part of `Spec.zig` | The known algorithm | Closest production implementation | Where it diverges |
|---|---|---|---|
| Facts 1–2, 4–6 (`analyse`, `sweeps`, `walkAll`, `evalStmt`, `binary`) | Optimistic constant propagation, Wegman & Zadeck's *SC* (no executable edges), interprocedural with pass-through jump functions (Callahan et al. 1986) | LLVM IPSCCP (`llvm/lib/Transforms/IPO/SCCP.cpp`, `Utils/SCCPSolver.cpp`) | IPSCCP is *SCC*: executable blocks and edges, functions reached only from executable calls (`SCCP.cpp:136-147`). Its unit is an SSA def-use edge, not a top-level statement |
| Fact 3 (`Pts`) | Andersen inclusion-based points-to, allocation-site, field-sensitive by name, on-the-fly call graph (Spark, Lhoták & Hendren) | SVF's `AndersenWaveDiff`; Doop/Soufflé in Datalog | No SCC collapse, no difference propagation, statement-granularity re-walks. **Non-monotone read of ⊤** (§3.3) |
| Guards (`guardNames`, `Pts.narrowed`) | Predicate-based narrowing; LLVM's `PredicateInfo` inside SCCP | LLVM SCCP + PredicateInfo | Fine in kind. Intraprocedural only; nothing through a call (the empty page's `place`, §3.4) |
| Definite initialisation (`Pts.definiteInit`) | A *must* fact, stratified over the may-analysis | Laddder's lattice ⊥ ⊑ O(obj) ⊑ C(cls) | Re-runs the whole of fact 3 up to 3 times (`max_init_runs`) |
| Fact 6, allocated once | Singleton abstraction (recency or "allocated once") | MLton ConstantPropagation's globalisation (`ssa/constant-propagation.fun:965-983`) | Equivalent |
| Parameter dropping (`rewriteCalls`, `trimArguments`, unread parameters) | Interprocedural constant propagation plus absence analysis | Closure `OptimizeParameters` (`jscomp/OptimizeParameters.java:44-53`), GHC worker/wrapper absence | Closure handles one definition only (`:819`); `Spec` handles calls through properties too. No cloning (LLVM FuncSpec, GHC SpecConstr) |
| Unread keys (`dropKeys`, `neverRead`) | Useless-component elimination | MLton `Useless` (`ssa/useless.fun:13-31`) | Equivalent in kind; driven by points-to rather than unification |
| `prune` | Mark-and-sweep reachability | Closure `RemoveUnusedCode`, MLton `RemoveUnused` | A separate pass, **after** the facts: §3.1 |
| `inlineOnce`, `inlineSmall` | Occurrence-count inlining; size-model inlining | GHC `preInlineUnconditionally` (`Simplify/Utils.hs:1522`); Closure `InlineFunctions` ("called only once OR … smaller than the call itself", `InlineFunctions.java:52`) | Closure's rule, almost verbatim |
| `constructors` (slice 9) | Case-of-known-constructor; constructed product result (CPR) | GHC simplifier (`exprIsConApp_maybe`); MLton `KnownCase` | Equivalent in kind |
| `scalarReplace` (slice 7) | Scalar replacement of aggregates (SRA) | LLVM SROA; MLton `LocalFlatten`; Terser `hoist_props` | All-or-nothing per object, like SROA. Not partial (Graal PEA) |
| Folding (`binary`, `unary`, `foldList`) | Constant folding plus a peephole | LLVM InstCombine | No truthiness lattice: `x \|\| true` with a non-literal `x` stays (E4) |
| `rounds`, `run`'s pass loop | Phase iteration with caps | GHC simplifier (4 iterations), LLVM devirtualisation walk (4), Closure `PhaseOptimizer` (100) | Rounds iterate *analyses* that a combined fixpoint would not need to iterate (§3.1). Passes iterate *IR changes*, where caps are normal |

---

## 2. What the literature and the implementations say

### 2.1 Constant propagation and reachability, together

**Wegman & Zadeck**, "Constant propagation with conditional branches", TOPLAS 13(2) 1991. They
order four algorithms by power: SC (Kildall's simple constant propagation), SSC, CC and SCC (§3,
Fig. 5, p.186).

- **Executable edges.** CC and SCC add *executable edges*. Every flow edge starts non-executable.
  At a branch whose test is a constant, only the taken edge becomes executable. So "values created
  in the unreachable areas cannot possibly kill potential constants" (p.186), and Fig. 9 (p.192)
  is the canonical case.
- **Combined beats iterated.** "Many optimizing compilers repeatedly execute constant propagation
  and unreachable code elimination since each provides information that improves the other. CC
  solves this problem in an elegant way by combining the two optimization. Additionally, the
  algorithm gets better results than are possible by repeated applications of the separate
  algorithms." (p.192)
- **SCC is linear.** "Each SSA edge can only be examined twice" (§3.4.1, p.193).
- **Interprocedurally** (§6.3, pp.205–207), a callee is marked executable from its call sites, and
  its entry state is the meet over its executable callers. They fault the separate-phase pipelines
  of Callahan et al. and Burke–Cytron because "there is no feedback between the steps" (p.207).
- **Stopping early.** "If an optimistic algorithm is stopped before it terminates naturally, the
  information gathered may be wrong. Pessimistic algorithms may be stopped at any time" (§5.1,
  p.196). This is why `Spec`'s "a round that does not converge rewrites nothing" is the right
  policy for an optimistic round.

**Click & Cooper**, "Combining analyses, combining optimizations", TOPLAS 17(2) 1995, and Click's
thesis (Rice, 1995).

- **The theorem.** If each analysis and the "mixed functions" that connect them are monotone, the
  combined framework is monotone and has a fixpoint the iterative method finds (thesis §3.2.3,
  §3.7, pp.20, 27–29).
- **Why iterating cannot catch up.** Separate analyses "make use of the optimistic assumption within
  themselves, but not between themselves … constant propagation assumes all code is reachable"
  (§1.2, pp.3–4). The worked loop of Figs. 3.7–3.10 is E2's shape: "Repeated applications of these
  separate analyses cannot discover any more new facts because each new application starts out with
  no more facts than the first analysis did" (p.31).
- **When ordering suffices.** When information flows one way only, careful ordering suffices
  (§3.7.1, p.29). That is the case `Spec`'s rounds handle.
- **Cost.** The combined pass cost about one pass of each separate analysis, and was 51% faster
  than repeating them (§5.6.2, pp.82–83).

**Lerner, Grove & Chambers**, "Composing dataflow analyses and transformations", POPL 2002
(TR UW-CSE-01-11-01).

- Analyses propose rewrites that are only *simulated* during the fixpoint; the last chosen
  rewrites are applied once it is sound (§2.1).
- Iterating separate analyses to a fixpoint cost 5.7–7.5× the compile time of composing them,
  which cost 1.0–1.2× (Fig. 1, §7).
- A warning: analyses that are each monotone can compose non-monotonically through rewrites (§6.3).

### 2.2 Interprocedural, in production

**Jump functions** (Callahan, Cooper, Kennedy, Torczon, CC'86; Grove & Torczon, PLDI'93):
pass-through jump functions are the cost-effective kind. That is exactly fact 1's "an argument that
is a caller's own parameter takes that parameter's value".

**LLVM IPSCCP.** All paths below are under `llvm/`, at `b05bc1f7`.

- **Its lattice** has a range component that is widened after 10 extensions
  (`lib/Transforms/Utils/SCCPSolver.cpp:47`).
- **What it tracks:** executable blocks, per-field values of struct SSA values, internal globals,
  function returns, and argument-tracked functions (`SCCPSolver.cpp:570-630`).
- **Its fixpoint** is `SCCPInstVisitor::solve` (`:2250`), which drains an instruction worklist and
  a block worklist. `markBlockExecutable` (`:1098`) and `markEdgeExecutable` (`:1294`) are Wegman &
  Zadeck verbatim.
- **Functions are reached from calls.** A function whose callers are all known is *not* marked
  executable up front (`lib/Transforms/IPO/SCCP.cpp:136-141`). Its entry block becomes executable
  when an executable call reaches it, and the arguments merge into its formals then.
  Address-taken functions are executable from the start, with every argument tracked from what its
  attributes say (`:143-147`).
- **Rewriting comes after solving.** Constants are replaced, infeasible edges removed and returns
  zapped in one pass after the solve, never during it.
- **No heap tracking.** IPSCCP has no points-to and no heap fields. `Spec`'s fact 3 does strictly
  more there.

**LLVM FunctionSpecialization** (`lib/Transforms/IPO/FunctionSpecialization.cpp`). It runs *inside*
IPSCCP on the solver's lattice, repeated at most `funcspec-max-iters` = 10 times
(`SCCP.cpp:46-48`).

- **Cost model.** A function must be at least 500 instructions unless the argument is a literal. A
  clone is accepted at ≥20% code-size or latency savings, with at most 3 clones per candidate.
- **History.** It was enabled by default at O1–O3 in December 2022, reverted the next day over a
  miscompile (the benchmark's strict-aliasing undefined behaviour), and relanded in January 2023.
- **Cost.** +0.14% instructions on CTMark at O3, +0.35% with LTO.

**LLVM Attributor** (Doerfert et al., LLVM Dev Meeting 2019; `include/llvm/Transforms/IPO/Attributor.h:9-63`).

- **Design.** An optimistic interprocedural fixpoint over "abstract attributes". Asking one
  attribute about another *records the dependence*, and only changed attributes and their
  dependents are re-evaluated (`lib/Transforms/IPO/Attributor.cpp:2182-2316`).
- **Liveness is in every update.** An attribute at a position that is assumed dead is skipped, and
  revisited if the position becomes live (`:2757`). This is the combined fixpoint in its general
  form.
- **What happens at the iteration limit** (`attributor-max-iterations`, default 32, `:92-95`).
  Attributes still changing *and their transitive dependents* are reset to pessimistic; the rest
  keep their optimistic results (`:2293-2316`). That is a finer non-convergence policy than "rewrite
  nothing".
- **Cost keeps it off by default** (`attributor-enable` is `NONE`, `lib/Passes/PassBuilderPipelines.cpp:290-306`).
  "Attributor-light" drops exactly the liveness integration. TinyGo measured the full Attributor
  taking a medium program "from a few seconds to almost 2 minutes" (tinygo-org/tinygo#4582,
  2024-11-04).
- **The lesson** is not that combining is slow. A *general* framework of many attribute kinds with
  dependence tracking everywhere is slow; a purpose-built sparse combined solver is the cheap end
  (Click: one pass's cost).

**LLVM's phase ordering is repetition.** The function-simplification pipeline (SCCP included) is
nested inside a bottom-up call-graph SCC walk, re-run when calls become direct and capped at 4
(`max-devirt-iterations`). The source admits "Much of this doesn't make a lot of sense"
(`PassBuilderPipelines.cpp:1013-1015`). InstCombine dropped from iterate-to-fixpoint to **one**
iteration in LLVM 18, saving about 4% of compile time; a fixpoint iteration was wasted in 22.3% of
runs (Popov, Red Hat Developer, 2023-12-07).

**V8 left the Sea of Nodes** (Mercadier, "Land ahoy: leaving the Sea of Nodes", v8.dev, 2025).
Click's combining IR lost its order in JavaScript, because most nodes sit on the effect chain.
Turboshaft's CFG IR halved compile time. Ben Titzer, a TurboFan designer, put what was worth
keeping this way: "all of the other forward dataflow analyses that do monotonic reductions can be
combined into a single pass … and can iterate to a fix point efficiently" (HN 45690854, 2025).

### 2.3 Monotonicity is what makes order free

Kildall (POPL 1973), Kam & Ullman (Acta Informatica 7, 1977) and Cousot (1977; Cousot & Cousot,
POPL 1977, 1979): **monotone transfer functions over a lattice of finite height reach the same
extremal fixpoint under any fair iteration order.** Order changes only the number of steps.

Three things break that:

- a transfer function that is not monotone;
- widening, which LLVM's range lattice uses and `Spec` does not need;
- a rewrite made mid-solve.

Datalog makes the same point: rules that are "pure … and monotonic" cannot depend on evaluation
order (Smaragdakis & Balatsouras, *Pointer Analysis*, FnT PL 2(1) 2015, §2.1). *Must* facts — not
monotone with respect to the may-analysis — go in a separate **stratum**, computed before it or
after it closes, never fed back mid-solve (Soufflé's stratified negation; Szabó, Erdweg & Bergmann,
PLDI'21, assumption ASM3).

TAJS shows the right lattice for JavaScript (Jensen, Møller & Thiemann, SAS 2009, §4). Its
abstract value is a **product**, `Undef × Null × Bool × Num × String × P(L)`: `undefined` and
`null` are independent components beside the location set, each joined on its own.

### 2.4 Points-to at scale, and incrementally

**Inclusion versus unification.** Andersen (inclusion, cubic worst case) against Steensgaard
(unification, near-linear). GCC and LLVM-based tools use inclusion (Pereira & Berlin, CGO 2009,
§2).

**Solving it fast.**

- Hardekopf & Lin, PLDI 2007: lazy and hybrid cycle detection. 2.17 MLOC; 3.2× faster than
  Heintze–Tardieu and 6.4× faster than Pearce et al.
- Pereira & Berlin, CGO 2009: *wave propagation*. Collapse strongly connected components into a
  topological order, propagate only the difference `Pcur − Pold` once in that order, add the edges
  that loads and stores create, and repeat.
- SVF (Sui & Xue, CC 2016) is the LLVM-ecosystem instance (`svf/lib/WPA/AndersenWaveDiff.cpp`). It
  collapses an object on a positive-weight cycle to field-insensitive. That is the principled form
  of `Spec`'s "a computed access makes the object field-insensitive".

**State of the art** (Smaragdakis & Balatsouras 2015): context-insensitive Andersen at millions of
lines is solved. Putting locals in SSA makes the flow-insensitive rules flow-sensitive for locals
(§5.1), and beni's `const`s are SSA already.

**Datalog.** Doop (Bravenboer & Smaragdakis, OOPSLA 2009) was over 15× faster than Paddle at
identical precision. Soufflé (Jordan, Scholz & Subotić, CAV 2016) does points-to on OpenJDK 7
(1.4 M variables) in under a minute. Its semi-naïve evaluation is difference propagation.

**Incrementally, when the facts are monotone.**

- DRed's delete-and-rederive (Gupta, Mumick & Subrahmanian, SIGMOD 1993) took 9 s on average
  against 35 s from scratch on Doop's points-to.
- Laddder (Szabó, Erdweg & Bergmann, PLDI 2021), on differential dataflow, updates whole-program
  points-to and constant propagation **in under 10 ms** for virtually every change. It needs only
  *eventual* monotonicity.
- Microsoft's incremental whole-program optimisation (Sathyanathan, He & Tzen, CGO 2017) ships in
  Visual C++, with up to 7× faster rebuilds.

`backend.md` §9's argument that exact incrementality is impossible rests on fact 3's order
dependence (*Fact 3 depends on walk order*). With monotone transfer functions that premise goes.

### 2.5 Escape analysis and scalar replacement

**Choi et al.**, OOPSLA 1999: connection graphs; a median of 19% of objects stack-allocatable.

**Stadler, Würthinger & Mössenböck**, "Partial Escape Analysis and Scalar Replacement for Java",
CGO 2014.

- An allocation stays *virtual* and is *materialised* only on the branches where it escapes (§1,
  §4).
- Merges produce a Phi of materialised values (§5.3), and `==` of two virtual objects folds (§5.2).
- Results: DaCapo −4.9% allocated memory and +2.2% speed; ScalaDaCapo −15.2% memory and +10.4%
  speed; one benchmark (jython) −2.1% from code growth.
- In Graal: `virtual/phases/ea/PartialEscapePhase.java:83`, with loop-depth cutoffs and a
  retryable bailout against exponential cases (`PartialEscapeClosure`, `EffectsClosure`).

**LLVM SROA** is all-or-nothing per alloca, like `Spec`'s slice 7.

### 2.6 Whole-program optimisers for functional languages and JavaScript

**MLton** (`references/mlton`).

- **Shape.** One fixed list of 37 SSA passes, `mlton/ssa/simplify.fun:46-122`. There is no loop.
  Repetition is by listing a pass again: `removeUnused` five times, `contify` three times.
- **Cleanup.** Every pass ends with the shrinker: case-of-known-constructor, folding and copies.
- **Ordering.** `useless` runs "after constant propagation because constant propagation makes slots
  of tuples that are constant useless" (`:59-63`). That is `Spec`'s key dropping after fact 4, by
  the same reasoning.
- **Weeks**, "Whole-Program Compilation in MLton", ML Workshop 2006, slides 19 and 31–32: "22
  small, independent SSA→SSA rewrite passes; each pass: analyze, transform, shrink"; "all passes
  benefit from CFA, which is only done once"; and a 0-CFA "imprecise in theory, but precise in
  practice … less than 2s to analyze MLton itself" (slide 14).

**Closure Compiler ADVANCED** (`references/closure-compiler`, under `src/com/google/javascript/jscomp/`).

- **The loop.** `PhaseOptimizer` repeats a loop of passes to a fixpoint, capped at `MAX_LOOPS` =
  100 (`PhaseOptimizer.java:75`).
- **Change tracking.** `hasScopeChanged` (`:270`) lets a pass skip functions unchanged since its
  last run.
- **A size stop.** The loop stops early when two batches shrink the program by less than 0.05%
  (`isAstSufficientlyChanging`, `:436`).
- **No points-to.** Its analyses are names, conventions and type colours: property disambiguation
  is a union-find over types (`disambiguate/PropertyClustering.java`).
- **Purity by name.** `PureFunctionIdentifier` treats a side effect of any function named `foo` as
  one of every call of `foo`.
- **Practitioners** found it slow ("unbelievably slow", HN 6813511; 1m30s cold, HN 7909895), and
  found that ADVANCED "can break code that will work when uncompressed" (HN 6083548).
- **esbuild deliberately does none of this.** Its documentation lists inlining, cross-statement
  constant propagation, shape modelling and devirtualisation as *not done*
  (esbuild.github.io/api/#minify).
- **Terser's** `passes` defaults to **1**.

**GHC** (`references/ghc`, `compiler/GHC/Core/Opt/`).

- **The simplifier is one combined traversal.** Inlining, beta reduction, case-of-known-constructor,
  case-of-case, let-floating and rewrite rules all happen in one walk (`Simplify/Iteration.hs`).
- **Iterations.** It is iterated at most `maxSimplIterations` = 4 times (`GHC/Driver/DynFlags.hs`),
  stopping at "Simplifier reached fixed point" or "Simplifier bailing out" (`Simplify.hs:235, 311`).
- **Inline-once.** `preInlineUnconditionally` (`Simplify/Utils.hs:1522`) inlines a binding that
  occurs once and not inside a lambda, "REGARDLESS of how big the RHS might be". That is `Spec`'s
  inline-once, down to the "outside any loop and any function" condition.
- **Absence and CPR.** Demand analysis finds absent (unused) arguments. Worker/wrapper drops them,
  and CPR returns a constructor's fields so that the caller's case-of-known-constructor cancels it.
  That is `Spec`'s slice 9 by another route.
- **SpecConstr** (Peyton Jones, ICFP 2007) clones recursive functions per constructor shape,
  bounded at 3 per function and halved when nested.

### 2.7 Equality saturation

The papers:

- Tate, Stepp, Tatlock & Lerner, POPL 2009, saturates program-expression graphs per method. On
  SpecJVM, extraction (pseudo-boolean solving, 1.5 s per method) cost about 17× the saturation, and
  timed out on 1% of methods.
- egg (Willsey et al., POPL 2021) made rebuilding cheap. It always runs under limits
  (`references/egg/src/run.rs:344-345`: 30 iterations, 10 000 nodes).
- egglog (Zhang et al., PLDI 2023) joins Datalog and e-graphs.

**Cranelift**, the one production compiler mid-end built on it (Fallin, "The acyclic e-graph",
cfallin.org, 2026-04-09):

- It **does not saturate**. It rewrites eagerly when a node is created and keeps effects in a
  control-flow skeleton.
- The result was about 2% faster code for 7–8% more compile time.
- In Fallin's words, the multi-version representation "may not (yet?) be pulling its weight". The
  win was one fixpoint over all rewrites.

Every use found is local, pure and intraprocedural. None does interprocedural facts with effects.

### 2.8 Prepack

Prepack, Facebook's partial evaluator for JavaScript, was set down; the repository was archived in
February 2022.

**The stated reason**, in the React Server Components RFC (`reactjs/rfcs`, 0188, *Avoiding the
Abstraction Tax*): "many AOT optimizations don't work because they either don't have enough global
knowledge or they have too little … Even when we could make optimizations work, we found that they
were unpredictable to the developer."

**Dan Abramov** on HN: "One compiler bailout, and the difference in the bundle is huge" (25499545,
2020); and Prepack "needs to have a model of the environment … and it can produce larger code"
(16888124, 2018).

### 2.9 Phase ordering

Finding the best phase order is undecidable in general (Touati & Barthou, CF 2006). Production
compilers answer with fixed pipelines and repeated simplification under small caps:

| Compiler | Cap |
|---|---|
| GHC | 4 |
| LLVM | 4 devirtualisation walks, 10 FunctionSpecialization iterations, 32 Attributor iterations |
| Closure | 100 |
| Terser | 1 |
| egg | 30 |

Search-based and learned orderings exist (Kulkarni et al., CGO 2006; Kulkarni & Cavazos, OOPSLA
2012) and are not used for a fixed release pipeline. **Combining analyses is the one known
technique that removes a phase-ordering problem instead of searching it** (Click p.4; Lerner §1).

---

## 3. The audit

### 3.1 Rounds: separate analyses, rewritten between

`rounds` (`Spec.zig:812`) runs this loop up to `max_rounds` = 4 times:

1. `analyse`: fact 3 to its fixpoint, then facts 1, 2, 4 and 5 to theirs;
2. `rewrite`;
3. `prune`.

`run` (`:321`) wraps it in up to `max_passes` = 3 passes of inline small, inline once,
constructors and scalar replacement, each followed by `prune`, `grow` and `rounds` again.

`evalStmt`'s `if_stmt` walks both arms whatever the test's value (`:1399-1404`), and `Pts.stmt`
does the same (`:6603-6609`). A function body is walked whether or not a live call reaches it. So
every fact is computed over code the same facts prove dead. `prune` and the next round recover
that, one dependency level per round, starting from ⊥ each time.

**What it costs:**

- **Missed facts** in every cycle of the kind Click's p.31 describes. E2 is the smallest. A mode
  flag of the runtime that is set only inside a branch the flag itself guards is the realistic one.
- **Repeated work.** E3 averages 4.02 analyses per build. One analysis per structural pass (1 +
  1.39 passes on average, §3.7), plus the occasional `releaseKeeps` round, is the floor a combined
  fixpoint would sit at: about **2.4–2.6, roughly 40% fewer analyses**. Each would also walk only
  executable code.
- **Order bugs.** `rewrite` reads facts that it is itself changing. Commit `f2a2e5f1` (*inline a
  release constant whichever module the specialiser sees first*) found two such cases, where module
  order decided whether `const c=-2147483648` stayed. It fixed them by asking for another round.
  Lerner's and LLVM's discipline — solve completely, then rewrite once from the final facts — makes
  that class of bug impossible: no decision reads a fact mid-rewrite.

### 3.2 Sweeps: ordered, coarse and capped

`sweeps` (`:984`) and `Pts.fixpointWith` (`:6430`) are round-robin (Gauss–Seidel) iterations over
the top-level statements, and for fact 3 over function bodies, in module order. The worklist
(*As built — the worklist*, `caf56054`) skips units nothing woke, which made a sweep cheap. But
each sweep still visits the woken units in program order, so the number of sweeps is the length of
the longest dependency chain that runs *against* that order.

Facts 1 and 4 flow from caller to callee, and emission is callee-first, so every pass-through level
is one sweep. E1 measures the consequence: 23 levels converge in 24 sweeps, and 24 levels hit
`max_sweeps` = 24. The round then declines, and everything goes, including folds that have nothing
to do with the chain. The corpus never comes near (8 and 41 sweeps at most), but nothing in beni
bounds a user's call depth. LLVM, Attributor and SCCP worklists have no sweep notion at all.
Termination comes from the lattice's finite height, and an iteration budget is a backstop that
fires only on a bug.

The unit is coarse. For facts 1, 2, 4 and 5 a woken unit is a whole top-level statement, so a
16 400-arm function woken by one changed parameter is walked whole. That is the pressure behind
*Added 2026-10-02 — why a later pass is not incremental* and the `abuse_wide_test` budget (4 139 of
4 300 million instructions). SCCP's unit is one SSA def-use edge, and the Attributor's is one
attribute.

### 3.3 Fact 3: why the fixpoint depends on order

`Pts.read` (`:6201`) of a value whose `top` is set returns `{top}`, with no `prim`, `null` or
`undefined` bit (`out = .{ .top = obj.top or obj.prim }`). `makeTop` (`:6003`) clears the var's
site list when it goes ⊤. Before that, a read through the same var returned the union of the bits
of every site's property. So **`read` is not monotone in the bit components**: `read(⊤)` does not
contain `read({A})`. A var that was joined with `read({A})` before its source went ⊤ keeps those
bits, and one walked after does not. That is exactly the `backend.md` §9 observation that "which
it gathers depends on what transient values it was joined with before it went `top`", and the
reason `run/CallbackOrderDict` reached "a different, equally sound fixpoint" in another order.

**The fix is local.** Use the TAJS product: `⊤` (host or unknown) is one more component beside
`prim`, `null` and `undefined`, every component is ORed, and a read of `⊤` yields
`{⊤, prim, null, undefined}`. That is what a host property can hold.

The two consumers that read `prim` beside `⊤` are the node-maker fact and `appendChild`. The
node-maker fact's soundness argument is "a primitive receiver throws". That still holds if `⊤`
implies `prim`, because the rule only needs the receiver to be no object of the program. This
should be confirmed for `appendChild` when it is built.

With `read` monotone, and the other transfer functions checked one by one, fact 3 has one least
fixpoint for every order. Then:

- the safety build's `expectSame` reference sweep (`:6367`) can be replaced by an
  order-randomisation check, a stronger test of rule 5;
- the units can be visited in any order: by priority, per module in parallel, or incrementally.

The 48-site cap (`max_sites`) is monotone as written, because a ⊤ var's later sites escape too
(`addSite`), so it can stay.

### 3.4 Facts 1, 2, 4, 5, 6: right lattice, missing pieces

The `Lat` lattice (`:380`) is ⊥ < {literal, `name`} < *nonnull* < ⊤, with nullish literals joining
straight to ⊤. It has height 4 and its join is monotone. What it lacks:

- **Executability.** See §3.1.
- **Truthiness.** `binary` (`:2001`) folds `&&` and `||` only with a literal left side. Otherwise
  it joins both sides, so `x || true` is ⊤ even though every value it can take is truthy. A
  truthiness component (⊥/truthy/falsy/⊤) beside the value — Click's "combined lattice" for
  conditions — decides `if (x || true)`. E4 is the cost.
- **Call results.** `callValue` (`:1760`) demotes any return lattice to *nonnull* (`s.demote(out)`),
  because a call may have effects. IPSCCP replaces the uses of a call whose return is constant and
  keeps the call only when it may have side effects.
- **Clones.** A parameter is specialised only when every call agrees.
- **Context through a call.** `swap` and `drop` survive on the empty page because "`place`'s
  `else` is reached only from a branch that tested `s.i` was `null`, which no fact sees through a
  call" (*definite initialisation* note). That is context sensitivity, not combination. The cheap
  forms are inlining (already done when the callee is small or called once) or one-call-site
  sensitivity chosen introspectively (Smaragdakis, Kastrinis & Balatsouras, PLDI 2014).

### 3.5 Must facts: definite initialisation and guards

`Pts.analyse` runs fact 3's whole fixpoint up to `max_init_runs` = 3 more times (`:6323`) while
`definiteInit` finds new keys. That is a stratified must-fact, iterated by restarting.

In an optimistic combined solver the same fact is monotone when stated the other way round:

- "key *k* of literal *O* may be read before it is written" is a may-fact;
- it starts false, while *O*'s function has no reached caller;
- it becomes true when a reached caller fails `writesAfter`'s condition.

Reads then gain `undefined` monotonically, and no restart is needed.

Guards (`Pts.narrowed`, `guardNames`) are a meet with a filter on one use. They are monotone as
long as they apply to a name that is declared once and never assigned, which the code requires.

### 3.6 The rewrite: folds left undone

E4's `sameInputs` is the visible one. `Rt.beni:691-699` specialised with `b = null` should be
`a=>a===null`, which needs two things:

1. truthiness (§3.4), so that `if (a===null||true||…)` is taken;
2. dropping the statements after an `if` whose arm always returns.

Both are general, and neither needs the new architecture. Worth about 40 brotli bytes on 28 of 59
`browser-tea` pages today (§0.2).

Research 49 §3.4 recorded an earlier instance in `core/Task.beni` (`a||true` after a folded cell),
which is no longer in any corpus output.

### 3.7 The structural passes

`inlineSmall`, `inlineOnce`, `constructors` and `scalarReplace` are the right passes, with the
right rules, in the order GHC and Closure would take them. Repeating them is legitimate, because
each changes the IR (Click §3.7.1). The cap of 3 matches GHC's 4 and LLVM's 4.

In E3 the pass loop was still finding work at its cap in 65 of 411 builds. Raising it bought at
most 46 raw bytes. Like GHC's "Simplifier bailing out", the cap should be a counter in
`--self-profile`, so that a size regression can be traced to it.

E5 is a defect: after the fifth pass the facts read memory that was never initialised. Every node
and name table is grown in place across passes (`grow`, `:827`), and some table that `Pts` reads is
not. The cause was not chased (research only). It is evidence for the proposal's rule that the
solver rebuild its state from the IR for each solve, in tables sized by a pre-count.

### 3.8 Determinism, as built

Rule 5 holds today *by schedule*: modules in module order, statements in IR order, and `expectSame`
checking the worklist against a sweep of everything on programs of at most 1 500 nodes. It does
not hold *by construction*. Two orders give two different, equally sound programs: `backend.md`
§9's `run/CallbackOrderDict`, and commit `f2a2e5f1`'s `run/Int32Bits`, 782 against 778 bytes.

`build_test`'s module-order test guards the cases found. A monotone combined solver makes the
answer independent of order, so determinism no longer depends on a schedule nobody may change.

### 3.9 Compile time

From `backend.md` §9, *As built — the worklist* (ReleaseSafe, millions of instructions):

| Build | Specialisation | Total | Share |
|---|--:|--:|--:|
| TodoMVC release | about 420 | 2 087 | 20% |
| 100 000 generated lines | about 4 550 | 12 611 | 36% |
| `abuse_wide_test`'s 16 400 arms with `List` in beni | — | 4 139 | 96% of the 4 300 budget |

Only the last is close to a limit. Its cost is the unit's coarseness and the full re-analysis after
each structural pass.

---

## 4. Proposal: solve once, then rewrite once

### 4.1 The architecture

**One optimistic, combined, sparse fixpoint per structural pass**, in place of `rounds`. Facts 1–6,
points-to, reachability, never-written, never-read and definite initialisation are all cells of one
system:

- **Cells**, numbered densely before solving, in module and IR order (rule 5):
  - every whole-program name;
  - every parameter;
  - every local declared once;
  - every function's return;
  - every (site, property) pair;
  - every site's flags (escaped, all-read, any-written, callers);
  - every function's *reached* bit;
  - every branch's *executable* bit: an `if` arm, a `case` leaf, a `?:` arm, an `&&`/`||` right
    side.
- **Values**, a product: `Const` (⊥ < literal | `name` < nonnull < ⊤) × `Truth` (⊥, truthy,
  falsy, ⊤) × `Pts` (bits `⊤host`, `prim`, `null`, `undefined`, ORed, and a site set capped at 48
  → `⊤host`, the sites escaping). Every component is joined on its own, so every transfer function
  can be checked monotone component by component.
- **Mixed functions** (Click's):
  - an arm is executable only when its test's `Truth` allows it;
  - a function is reached only from a reached call, or because it escapes (IPSCCP's rule,
    `SCCP.cpp:136-147`);
  - code that is not executable contributes nothing to any cell: no arguments, no writes, no
    allocations, no escapes.
- **Constraints, extracted once per module, on the workers.** Lowering already runs per module.
  Extraction emits a flat constraint list per module, merged in module order exactly as the
  per-module walks that feed the facts are merged today. This is the Doop/Soufflé/SVF split, "extract
  facts, then solve".
- **A worklist of cells**, not of statements. A changed cell wakes the constraints that read it.
  Points-to uses difference propagation (send `Pcur − Pold`) and, if measurement asks for it, lazy
  SCC collapse (Hardekopf & Lin's LCD). Because the system is monotone, the visiting order is chosen
  for speed — a FIFO, or reverse post-order of the call graph — and **cannot change the answer**.
- **No sweep caps.** Each cell can change at most about 52 times (the lattice height plus the site
  cap), so the solve terminates. Keep a work budget as an assertion that names the cell still
  changing. If it ever fires, pessimise the still-changing cells and their dependents (the
  Attributor's policy, `Attributor.cpp:2293-2316`) rather than declining the whole program.
- **Then rewrite once**, from the final facts, with no fact read mid-rewrite:
  - fold;
  - drop parameters, arguments and keys;
  - delete every non-executable arm and every unreached function — `prune` becomes a read-off;
  - write the `name` constants and `appendChild`.

### 4.2 What stays an outer loop

The structural passes stay, run in this order after each solve and rewrite: small functions,
functions called once, constructor folding, scalar replacement. Each pass is followed by one new
solve, not by up to four rounds. The cap stays at 3, as a profiled counter. MLton's lesson applies:
"all passes benefit from CFA, which is only done once". Here the analysis is done once per
structural change, and the structural changes are bounded.

Incrementality across those solves is now *possible*: monotone facts admit DRed or
counting-based maintenance, and Laddder's sub-10 ms updates. It is **not proposed now**. The first
saving is not having rounds at all, and a DRed implementation is a re-architecture of its own,
priced by `backend.md` §9's *why a later pass is not incremental*.

### 4.3 What to expect

**Compile time.** Analyses per build fall from 4.0 to about 2.5 on today's corpus (§3.1), and each
walks only executable code. The re-walk unit falls from a top-level statement to a constraint, so
the 16 400-arm case stops re-walking its function. The literature's figures:

| Source | Combined | Iterated separately |
|---|---|---|
| Click §5.6.2 | about one pass of each separate analysis | 51% slower when repeated |
| Lerner Fig. 1 | 1.0–1.2× | 5.7–7.5× |
| IPSCCP with FunctionSpecialization | +0.14–0.35% of an LLVM build | — |

**Estimate for beni:** specialisation's share drops from about 420 to about 150–250 million
instructions on TodoMVC, and more on the 100 000-line build. This is an estimate to be measured
(§4.5's checkpoints), not a promise. Constraint extraction adds a pass, but it runs per module on
the workers.

**Output size.** Small today:

- On the corpus, the combined fixpoint adds what raising every cap adds (5 programs, ≤46 raw bytes,
  E3), plus every cyclic case like E2. It removes E1's cliff.
- The truthiness component is the same work as E4's fold, about 40 brotli bytes on half the tea
  pages.

The larger byte opportunities are §0.3's decisions 3 and 4 (call results with purity, and cloning),
and they are easier on the new solver, because a constant return or a clone is one more cell.

**`core/Task.beni`.** The combined fixpoint folds little of it that rounds do not already fold:

- its cells (`slotted`, and research 49's `soonRunning` and `defect`) are written only from
  functions that a build either reaches or does not — the acyclic case rounds handle;
- its remaining hand specialisation is inlining policy, not facts. One example is `takeOn`, the
  copy of `pushBack` that keeps both loops written in place (`Task.beni:2568-2579`). Another is
  "the protocol by hand" in `join` and `deferral`, which is a suspension-lowering choice (research
  49 §3.3).

What the new solver does for Task is make a runtime written in beni **safe to grow**: no depth cliff
at 24 call levels, no fact lost to a self-guarding flag, and no module-order surprise.

**Determinism.** Rule 5 holds by construction. The answer is the least fixpoint; iteration order
and module order cannot move it. The safety check becomes "solve in a shuffled order and compare",
which tests the property itself.

**Soundness.** The same as today's in kind: an optimistic solve is read only at its fixpoint, and
every rewrite is licensed by a final fact. The new risk is a mixed function that is not monotone,
which Lerner §6.3 warns about. The defence is the shuffled-order check in safety builds, and a
monotonicity property test per transfer function on small lattices.

### 4.4 Zig and data-oriented design

The data-oriented layout makes this design cheaper, not harder:

- Cells are dense `u32` ids, with values in struct-of-arrays columns: `[]Const`, `[]Truth`, and a
  `[]PtsBits` plus a site-set pool. Constraints are flat arrays of `(kind, in, in, out)` per module,
  like `Bir`'s instructions. Dependency lists stay in one pool, as `w_deps` and `Pts.deps` already
  are. The worklist is a bitset plus a ring of `u32`.
- Site sets are sorted `u32` slices for small sets and bitsets past a threshold. Hardekopf & Lin
  measured sparse bitmaps about 2× faster than BDDs. `max_sites` = 48 keeps most sets in one cache
  line or two.
- Today's walk re-reads `JsIr` nodes and re-hashes keys (`KeyMap`, `locals`) on every visit. A
  constraint list is read once, in order, and indexes columns directly. That is where `Spec`'s
  recent ⚡ commits found their wins (`25c38bed`, `018d7f6d`, `34236f33`), and a constraint system
  makes them structural.
- Extraction per module on the workers fits the existing parallel lowering. Ids are assigned from
  module order before solving, so the output is the same at `--jobs=1` and `--jobs=8`.

What Zig changes: nothing about which algorithm is right. The cost of a pointer-chasing
general framework like the Attributor's is exactly what Zig's own backend (which builds the tests'
compiler) compiles poorly. The `KeyMap` comment in `Spec.zig` already measured a generic hash probe
at over a thousand instructions. A flat constraint solver avoids generic layers in its inner loop.

### 4.5 Migration in gates-green slices

Each slice is byte-identical on every `emit/release/` golden, run hash and `bench/size.mjs` line,
or else measured smaller and its goldens moved with a fixture that is red before it.

0. **E5's fixture and fix** (independent). A unit test with `max_passes` raised, reaching the
   undefined read; then the fix. Byte-identical.
1. **Instrument.** `--self-profile` counters for analyses, sweeps, passes and caps hit (E3's
   numbers, permanently), and E1 and E2 as `emit/release/app/` fixtures pinned at today's output.
   Byte-identical.
2. **Make fact 3 monotone** (§3.3). Expect a few outputs to *move* where the bits differed, all
   toward the least fixpoint. Replace `expectSame` with a shuffled-order check. Measured; the
   goldens that move are justified one by one.
3. **Truthiness and dead-after-return** (§3.4, §3.6) in today's evaluator. E4's 28 pages shrink.
   Fixture: `emit/release/app/` with `sameInputs`'s shape, red before.
4. **The constraint extractor and the cell solver for facts 1, 2, 4 and 5, without executability.**
   It must reproduce today's facts exactly: checked in safety builds against the old sweeps on
   every program under the node limit, then the old sweeps deleted. Byte-identical. Instructions
   measured on TodoMVC and the 100 000-line build.
5. **Fact 3 into the same solver.** Byte-identical, by the same double-run check.
6. **Executability and reachability as cells; `rounds` becomes one solve; `prune` becomes a
   read-off.** E2 folds and E1's cliff is gone; their fixtures move. Expect the corpus to shrink a
   little (E3's raised-cap figures are the floor). Measured: analyses per build and specialisation
   instructions.
7. **Definite initialisation as a may-fact in the solver** (§3.5). `max_init_runs` goes.
   Byte-identical or smaller.
8. **Optional, after the owner's decisions:** purity-licensed call results, then size-gated
   cloning.

### 4.6 Risks

- **A non-monotone mixed function** gives a fixpoint that depends on order, the problem being
  removed. Mitigation: the shuffled-order check from slice 2 on, in every safety build of a small
  program.
- **Executability makes optimism bite harder.** Code the analysis believes dead must be dead. Every
  `foreign`, the entry file and `Input.escaping` must reach their functions, as `escaping` does
  today, and an unknown call target (`⊤host`) must reach every escaped function. IPSCCP's rule
  (address-taken means executable) is the model.
- **Slice 4's double run** costs compile time in safety builds only, as `checkedSweeps` already
  does.
- **Size regressions from more folding.** These are possible where a fold makes a longer literal or
  shifts brotli's matches. `Spec`'s per-site size rules (`substitutes`, 5 bytes) are untouched by
  the architecture and keep applying.
- **Scope.** The rewrite half of `Spec` (about 4 000 lines) is untouched until slice 6. Each slice
  replaces one analysis behind the same interface.

### 4.7 What is not recommended

- **Equality saturation.** `Spec`'s facts are interprocedural and heap-aware; e-graphs are local
  and pure. The cost to minimise is brotli bytes of the whole bundle, which no per-node extraction
  cost captures. Cranelift, the one production user, does not saturate (§2.7).
- **An Attributor-style general framework.** It is the right shape, but its generality is its cost
  (off by default in LLVM; TinyGo's minutes). A purpose-built cell solver with the eight cell kinds
  of §4.1 is the cheap end.
- **An embedded Datalog engine** (Soufflé or differential dataflow). The constraint system of §4.1
  *is* the Datalog program with its rules written as Zig switch arms. An engine adds a dependency
  and a representation boundary for no fact the switch cannot express. Revisit if incrementality
  across builds (M4's daemon) wants DRed or differential maintenance.
- **Partial escape analysis now.** Values are immutable, so PEA would be simpler here than in Java.
  But field identity is load-bearing (rule 8), so any path may materialise an object at most once.
  Sinking a literal into its escaping branches duplicates text, and V8 already does escape analysis
  in optimised code. Measure the "sink to the one escaping branch" special case first, if a page
  shows the need.
- **Prepack's road.** Modelling the host to evaluate the program ahead of time is the opposite of
  `Spec`'s design, where a host value is ⊤ by contract. Prepack's lesson: predictability matters
  more than peak power. That argues *for* §4's order-independence.

---

## 5. Decisions for the owner

1. **Architecture.** Adopt §4: one optimistic combined fixpoint per structural pass, solve then
   rewrite, sparse cell worklist, no sweep caps. Migrate by §4.5's slices. *Recommended.*
2. **E5.** Fix the latent undefined read now, with its fixture, independent of decision 1.
   *Recommended.*
3. **Purity for `Spec`.** Hand it the checker's `Effects` bit per function, so that a pure call
   with a known result is its result (language.md §6 already licenses it). *Recommended after
   slice 6.*
4. **Cloning.** Specialise a function per constant argument when the copies print smaller (LLVM's
   gate). *Decide after slice 6, with measurements.*
5. **Incrementality.** Not now. Recorded as possible once the facts are monotone, for M4.

---

## 6. Sources

**Papers.**

- **Constant propagation and combining:**
  - Wegman & Zadeck, TOPLAS 13(2) 1991.
  - Click & Cooper, TOPLAS 17(2) 1995; Click, PhD thesis, Rice 1995.
  - Lerner, Grove & Chambers, POPL 2002 / UW-CSE-01-11-01.
  - Callahan, Cooper, Kennedy & Torczon, SIGPLAN CC 1986; Grove & Torczon, PLDI 1993.
- **Monotone frameworks:**
  - Kildall, POPL 1973.
  - Kam & Ullman, Acta Informatica 7 1977.
  - Cousot & Cousot, POPL 1977/1979.
  - Bourdoncle, FMPA 1993.
- **Points-to:**
  - Andersen, DIKU 94/19.
  - Steensgaard, POPL 1996.
  - Hardekopf & Lin, PLDI 2007 and CGO 2011.
  - Pereira & Berlin, CGO 2009.
  - Sui & Xue, CC 2016.
  - Smaragdakis & Balatsouras, FnT PL 2(1) 2015.
  - Smaragdakis, Kastrinis & Balatsouras, PLDI 2014.
- **Datalog and incremental analysis:**
  - Bravenboer & Smaragdakis, OOPSLA 2009.
  - Jordan, Scholz & Subotić, CAV 2016.
  - Gupta, Mumick & Subrahmanian, SIGMOD 1993.
  - Szabó, Erdweg & Bergmann, PLDI 2021.
  - Sathyanathan, He & Tzen, CGO 2017.
- **JavaScript analysis and escape analysis:**
  - Jensen, Møller & Thiemann, SAS 2009.
  - Choi et al., OOPSLA 1999.
  - Stadler, Würthinger & Mössenböck, CGO 2014.
- **GHC:**
  - Peyton Jones & Marlow, JFP 12(4–5) 2002.
  - Peyton Jones, ICFP 2007.
- **Equality saturation:**
  - Tate, Stepp, Tatlock & Lerner, POPL 2009.
  - Willsey et al., POPL 2021.
  - Zhang et al., PLDI 2023.
- **Phase ordering:**
  - Touati & Barthou, CF 2006.
  - Kulkarni et al., CGO 2006.
  - Kulkarni & Cavazos, OOPSLA 2012.

**Practitioners.**

- Weeks, *Whole-Program Compilation in MLton*, ML Workshop 2006
  (`references/mlton/doc/guide/src/References.attachments/060916-mlton.pdf`).
- Doerfert et al., *The Attributor*, LLVM Dev Meeting 2019.
- TinyGo issue 4582.
- Popov, *How single-iteration InstCombine improves LLVM compile time*, Red Hat Developer,
  2023-12-07.
- Mercadier, *Land ahoy: leaving the Sea of Nodes*, v8.dev 2025.
- Fallin, *The acyclic e-graph*, cfallin.org 2026-04-09.
- The React RSC RFC 0188.
- HN threads 25499545, 16888124, 45690854, 47717192, 6813511, 7909895 and 6083548.
- esbuild's *Minify* documentation.
- Terser's README.

**Source, pinned under `references/`** (`references/README.md`):

| Submodule | Commit |
|---|---|
| `llvm-project` | `b05bc1f7` |
| `closure-compiler` | `e2e99ba9` |
| `graal` | `bcdab016` |
| `ghc` | `c35096f5` |
| `mlton` | `936011ca` |
| `egg` | `73975c98` |

Line numbers in this document are at those commits.

## 7. Method

**Compilers.** Every experiment used master at `8657c5dc`, built ReleaseSafe. E3 and E5 also used
copies of it with five lines added to `Spec.run`, `rounds` and `analyse`:

- a counter of analyses, sweeps, fact-3 sweeps, failed rounds and passes, printed to stderr;
- for the raised-cap copy, `max_rounds` 16, `max_passes` 16, `max_sweeps` 1 000 and
  `max_pts_sweeps` 1 000;
- for E5's bisection, `max_passes` alone at 4, 5, 6 and 16.

The copies were built into `zig-out/` and discarded. `src/` is unchanged.

**E1.** A shell generator writes the chain of §0.2 for N = 5–60 in both declaration orders. Both
give the same output, since emission is reachability-ordered. Each was built with `--platform=node
--release`.

**E3 and E4.** `beni build --release --allow-debug --no-source-maps` of every
`tests/corpus/run/*.beni`, `tests/corpus/browser/tea/*.beni` and `bench/todomvc/apps/beni/*.beni`
(411 builds), comparing raw output bytes. E4's brotli figure is Node 24.19's `brotliCompressSync`
at quality 11 over each `_main.mjs`, with and without the two bodies replaced by `a=>a===null`.
