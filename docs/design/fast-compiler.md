# Beni: design for an extremely fast Elm-like → JavaScript compiler

**Host language:** Zig. **Target:** JavaScript (ESM). **Source language:** Elm-like — ML family,
full Hindley-Milner inference, ADTs, records, modules; no typeclasses, no macros, no type-level
computation. Ad-hoc polymorphism is **static dispatch** — methods named on a type's declaring
module, constrained by a `where` clause, discharged by caller-threaded evidence — adopted
2026-09-18 and specified in [`static-dispatch-spike.md`](static-dispatch-spike.md) (§3.1).

**Stance: Elm's walled garden, better equipped.** The wall is not negotiable: user code does not
reach arbitrary JavaScript, effects cross a controlled boundary, matches are exhaustive, there is no
null, well-typed code does not throw. What was wrong with Elm was not the wall but how sparsely the
garden inside it was furnished — no exact 32-bit arithmetic, no code splitting, no source maps, a
small standard library, a kernel only the core team could extend. So the question a capability faces
is not "can user code reach this" (no) but **what would it take to offer it inside the wall, typed so
well-typed code still cannot crash?** Exact 32-bit arithmetic needed a type, not a hole (§3.1); code
splitting needed a declaration marker and an effect type (§9.5); neither cost a guarantee. The hard
cases are where the answer is a *platform* capability, which is why the JavaScript-boundary contract
is written up front.

## 1. The thesis

Compilers in this family are slow for three reasons, each with a known fix:

1. **Process and phase overhead dominates small edits.** A fresh process costs tens of milliseconds
   on dynamic linking and runtime init before a byte is lexed (04 §8) — most of a 100ms budget.
   *Fix: a daemon.*
2. **Pointer-chasing, per-node allocation and string comparison tax every phase.** oxc measured ~20%
   from arena allocation alone; Carbon 5–12% lex / 4.5% parse / 1–2% total check from packing tokens
   to 8 bytes; Zig −17.5% wall time from refining one intern pool (01 §5, 04 §1). Elm pays a
   byte-array comparison on *every* identifier lookup through the entire back half of its pipeline
   because `Name` is never interned (05 §2). *Fix: flat SoA IRs, u32 indices, arenas, intern once at
   lex time.*
3. **Invalidation is coarser than the edit.** Elm re-checks whole modules; declaration-level *output*
   granularity did not buy it declaration-level *compilation* granularity (03 §7, 05 §3). Zig,
   tracking a declaration's type separately from its value, re-analyses a single-file edit in a
   500k-line project in **63ms** (01 §7). *Fix: a fine-grained dependency graph plus a
   module-interface firewall.*

The fourth reason is free: **the language itself**, since feature surface costs compile time. Gleam
rejects typeclasses for their "high compile time cost, and… runtime cost unless the compiler performs
full-program compilation and expensive monomorphisation" (09 §3); PureScript's creator declined to
build that monomorphisation into the standard compiler because "being global, it doesn't always play
nicely with separate compilation", and the separate optimizer that does it is non-incremental while
recovering 25–35% runtime and 20–25% bundle size (09 §2). Beni stays scope-limited on those grounds,
as a language-design commitment.

**Correction.** Two claims made here previously do not survive checking (09 §2): PureScript's
`RowList` blowup was root-caused to its *parser*, not dictionary resolution, and the "476 million
dictionary comparisons" figure could not be sourced at all. Nor is there evidence that *Elm's* speed
comes from lacking typeclasses — Evan's own performance writing credits parser allocation and GC.
The argument stands on the other languages' evidence, not Elm's.

## 2. Performance budget

Per-operation, on a warm daemon, on a 100k-line project. These are the numbers CI tracks (§12);
missing them is a bug report, not a nice-to-have.

| Operation | Target | Evidence it's achievable |
|---|---|---|
| Cold full build, 100k LOC | **< 800ms** | Elm does ~120–130k lines/s full-compile in Haskell with no interning and mtime caching (02 §10) |
| Warm rebuild, one function body edited | **< 15ms** | Zig: 63ms for a 500k-line project with a much heavier type system (01 §7) |
| Warm rebuild, one exported signature changed | **< 60ms** | bounded by the transitive re-check the interface firewall permits |
| Warm rebuild, one dependency-free module added | **< 25ms** | one parse + one check + one emit |
| Daemon cold start (mmap cache hit) | **< 120ms** | zero-parse mmap load of cached artifacts (04 §7) |
| Type checking throughput (cold, per core) | **> 250k LOC/s** | HM with levels is near-linear; Elm reaches ~130k LOC/s for the *whole* pipeline in GHC |
| Emit throughput | **> 5 MB/s of JS** | esbuild prints+sourcemaps 547k lines in 390ms including parse and link (03 §1) |

Two non-goals: beating esbuild at bundling third-party JavaScript, and sub-millisecond *cold* starts.
**These targets are Elm-shaped, not Roc-shaped, and the difference is one phase.** Roc caches
checking and not specialisation, and its times split along that line: `roc check` does 58k lines in
**0.78s**, an `--opt=dev` build of 55k lines takes **16.9s** — ~3,400 lines/s against Elm's ~120–130k
for its whole pipeline (10). We aim at the first profile, reachable because there is no
specialisation phase to pay for.

## 3. Language constraints that exist for compiler speed

Decisions about the *source language*, made now because they cannot be retrofitted.

- **LL(k), no backtracking.** Constant lookahead, committed choice — Zig's stated parser invariant
  (01 §9) and Elm's practical one (05 §1.3). Guarantees linear parse time.
- **No typeclasses and no whole-program specialisation; static dispatch, since 2026-09-18, yes.**
  §3.1 and reports 09, 10, 18 and 19. Dictionaries cost runtime and bundle size and the effective
  fix is global, so specialisation — the one phase nobody has made cheap to cache — stays out; what
  came in instead is per-constraint evidence threaded by the caller, measured rather than argued
  ([`static-dispatch-spike.md`](static-dispatch-spike.md)). *Not* the `RowList` incident, a parser
  bug.
- **No type-level computation, no row-polymorphic type functions.** Records get plain extensible
  rows with structural unification, nothing more.
- **No macros** — what lets a simple module-interface firewall work instead of a salsa-style query
  engine, since matklad's stated reason for needing fine-grained tracking in rust-analyzer was
  macro-induced non-laziness (04 §6a).
- **Explicit imports, no wildcards.** Makes per-module name resolution parallelisable without a
  global pre-pass, which Roc's FAQ gives as its *primary* reason.
- **Tabs are a syntax error; indentation rules are lexically decidable.** No layout pre-pass.
- **No automatic currying** (§9.3): every call is saturated, `_` is the partial-application
  placeholder, `|>` is pipe-first syntax. Juxtaposition stays.

## 3.1 Ad-hoc polymorphism: `number` yes, `comparable` no

**The problem.** Without typeclasses, `+` must still work on `Int` and `Float`, and something must
order `Dict` keys. Elm's answer is four magic type variables — `number`, `comparable`, `appendable`,
`compappend` — each "one of a fixed set of types", making the unifier ask a second question beyond
"are these the same type": "is this type in the allowed set?" For `number` that is one comparison;
`comparable`'s set is recursive, so it walks the whole type under a cycle guard — the **only** place
Elm runs an O(term size) check inside unification, where everything else is batched to once per
let-bound name (02 §3). Only `Comparable` and `CompAppend` pay it (`Unify.hs:370-414`, the author's
own `TODO` doubting the guard at `:421-422`), so the cost is `comparable` specifically, not
constrained type variables as a category — and `comparable` also forces the generic runtime
comparator `_Utils_cmp`, the megamorphic dispatch point V8 cannot inline through (03 §5.7).

### Decision

1. **Keep `number`.** `+`, `-`, `*` on `Int` and `Float`. Flat membership test, free.
2. **Keep `appendable`.** `++` on `String` and `List`. Also free — its branch is a plain merge.
3. **Drop `comparable` and `compappend`.** `<`, `>`, `<=`, `>=` are **numbers-only**. `"a" < "b"`
   does not compile; use `String.compare`. — **Superseded 2026-09-18**; see *Reversed on
   2026-09-18* below.
4. **Ordering is passed explicitly.** `List.sortBy`, `List.sortWith`, and `Dict`/`Set` keyed by a
   concrete type (`Dict.String`, `Dict.Int`) as sugar over a comparator-taking core. —
   **Superseded 2026-09-18**; see *Reversed on 2026-09-18* below.
5. **`==` stays fully polymorphic, but its check leaves the unifier.** "This type must be equatable"
   is an obligation discharged *after* solving, when the type is concrete — same principle as the
   occurs check: don't make the check faster, make it rare. It also turns Elm's last runtime crash,
   `==` on functions, into a compile error, as Roc does, function equality being undecidable.

### Why, and what it costs

The unifier does one thing, with no recursive membership walk and no occurs check
on its hot path — §7's premise intact. The price is ergonomic and real: `List.sort` becomes
`List.sortBy identity`, tuple-keyed dictionaries need a comparator, some ordering code gets longer.
(That price is what *Reversed on 2026-09-18* below stopped paying; the paragraph is kept because
the price was the argument, and report 19 §9 is the measurement of it.)
Point 3 is the genuine departure from Elm; 1, 2 and 5 are close to free. **Roc reached the same place
independently** ([`research/07-roc-static-dispatch.md`](research/07-roc-static-dispatch.md)), but its
mechanism of methods named on types is *not* copyable: what makes it cheap is monomorphisation, and
its non-specialising path passes hidden dictionaries instead.

### Revisited after the survey (09)

The exclusion survived, with two corrections. **Elm's omission was deliberate deferral, not
neglect** — Evan chose SML-style operator overloading in 2012 because it upgrades gracefully to type
classes — but never argued it on compile-speed grounds, so that justification was ours, wrongly
attributed. And **"you must do whole-program work" is too strong**: GHC's `SPECIALIZE` and F#/Fable's
SRTP both ship dictionary elimination compatible with separate compilation, paying in code
duplication. A follow-up survey (10) sharpened rather than overturned the claim — Rust makes it
incremental only at 256 codegen units instead of 16, worse codegen, cross-crate duplication and a
memory-blowup bug category open after a decade; Roc does not cache specialisation at all — so the
claim is narrower: **specialisation is the phase nobody has made cheap to cache.**

### Decision: no static dispatch

Ad-hoc polymorphism is limited to `number` and `appendable`; ordering, equality on user types and
stringification are explicit. Four mechanisms ruled out:

| Ruled out | Why |
|---|---|
| **Dictionary passing** | Runtime cost and bundle size. The effective fix is whole-program specialisation, and PureScript's creator declined to build it into the standard compiler because "being global, it doesn't always play nicely with separate compilation." Their separate optimizer recovers 25–35% runtime and 20–25% bundle size, and is explicitly non-incremental (09 §2). |
| **Whole-program specialisation** (Roc's model) | Specialisation is the one phase nobody has made cheap to cache. Roc caches checking but not mono; its `SpecializationCacheFile` has zero call sites. Measured: 0.78s to *check* 58k lines, 16.9s to *build* 55k — ~3,400 lines/s against Elm's ~120–130k for a whole pipeline. Feldman: "the specializations are the hard part" (10). |
| **JS prototype dispatch** (`x.method()`) | Free at runtime — the engine does it — but methods on prototypes defeat the precise whole-program tree-shaking §9.1 depends on. Rejected on output size, not compile time. |
| **Interface-propagated call-site specialisation** (GHC `SPECIALIZE`, F# SRTP) | The one incremental-compatible route, and genuinely viable — but it pays in code duplication, which is what §9 optimises hardest, and it would have to be opt-in per function. Putting a body into its interface file means body edits change the interface, which is exactly what §8.1 exists to prevent; GHC keeps the firewall intact only because `INLINABLE` is an explicit annotation. Not worth the language surface for what it buys. |

Across seven JS-targeting languages, type-directed dispatch *with no value to dispatch on* always
reduces to a caller-threaded dictionary or whole-program specialisation — no third option — while
value-directed dispatch is free everywhere because JS prototypes do it natively (09 §3). **If ever
revisited**, the entry point is the last table row: `number` and `appendable` are a closed set
resolved post-solve, so opt-in call-site constraints would change no type representation and no part
of the firewall.

**Re-tested against Roc's shipped feature**
([`research/18-static-dispatch-revisited.md`](research/18-static-dispatch-revisited.md)): the
decision stands, three of the four reasons do not. The runtime-cost row is borrowed from a language
whose dictionary density beni cannot reach, and on a JS target the runtime argument mildly *favours*
adopting it (18 §1.1, §1.5); Roc's throughput number belongs to monomorphisation, not dispatch
(18 §1.1); the prototype row is a strawman, since static dispatch emits direct calls (18 §1.3).
Replacing them is one argument the earlier reports could not make: **the cost lands on inference** —
Roc lost principal type inference in August 2026 and bought it back by assuming top-level
annotations, the mitigation beni gave up in making annotations optional and the interface the
inferred scheme (18 §2.3). "Additive" is also too strong: additive to the type system, invasive to
the module system, since user-named methods need a declaring module (18 §4, §6). Two standing
recommendations: generalise obligation discharge beyond the hardcoded
`number`/`appendable`/`equatable` set, and decide structural codec derivation separately, needing no
dispatch at all.

### Reversed on 2026-09-18: static dispatch is adopted

The exclusion above was tested by building the feature and measuring it
([`plans/static-dispatch-spike.md`](../../plans/static-dispatch-spike.md), results in
[`research/19-static-dispatch-spike-results.md`](research/19-static-dispatch-spike-results.md)), and
on 2026-09-18 it was **reversed**: beni has static dispatch. The contract is
[`static-dispatch-spike.md`](static-dispatch-spike.md) — the file name is historical, the document
is normative — and it is the place to read what the feature *is*. What that does to this section:

| This section | State |
|---|---|
| Decision points 1, 2 and 5 — `number`, `appendable`, `==` as a post-solve obligation | **stand, unchanged.** `Kind` is still `{ any, number, appendable }` and nothing was added to it; a method constraint lives on a variable's own constraint set, not in `Kind` (spec §6.1). Point 5's obligation mechanism is what the new one is built beside |
| Decision point 3 — `comparable` dropped, `<` numbers-only | **superseded.** `<`, `>`, `<=`, `>=` call the receiver type's `compare` method and `"a" < "b"` compiles (spec §3.1, §3.2). The *mechanism* point 3 rejected is still absent: `comparable` is not a `Kind` and unification runs no recursive membership walk |
| Decision point 4 — ordering passed explicitly, `Dict.String`/`Dict.Int` as sugar | **superseded.** The two sugar modules are deleted; `Dict`, `Set` and `List.sort`/`sortBy` carry a `where k.compare` constraint instead; `List.sortWith` survives as the way to order by something that is not the type's own (spec §5.3–§5.5, §5.7) |
| `equatable` | **kept and now redundant.** A type that has an `eq` is equatable and a function type has neither, so the marker overlaps the constraint. Neither mechanism was removed; `not_equatable` survives as the better message for `==` on a function (spec §3.4) |
| The four ruled-out mechanisms above | beni takes the fifth: **caller-threaded evidence with no whole-program specialisation** — one hidden leading argument per constraint, in a canonical order both sides compute from the scheme record (spec §7.2, §8.1). It is the dictionary-passing row done per constraint rather than per class, and the row's own runtime objection was already retracted for a JS target by report 18 §1.1 and §1.5 |

**The evidence, and it is not one-sided.** Report 19 §6 measures the runtime win — 7.2× on
structural `==`, 3.2× on a sort, 1.28× on a dictionary build — and §9 the ergonomic one: the tax of
17 argument sites, 15 comparator parameters and two sugar modules goes to zero. Against that, §2
measures `check` **+20.3 %** on code that never uses the feature and **+7.8 %** more for code that
does; §5 output **+5.5 %** at the floor and **+11.8 %** on `bench/corpus`, all upper bounds while
no DCE exists; §4 unannotated `pub` interface churn **4.4–6.5× worse**; §3 an **n²** obligation
count on an unannotated chain; §8 the compiler itself +8 992 lines of `src/` and a 1.37× cold build.
§15 lays out the four options and the two questions the numbers could not answer; the owner took
option (b), the whole feature, and the reasons are recorded in spec A.82. Pre-1.0, it can still be
withdrawn.

**What the reversal owes**, from report 19 §14 — none of it is optional and all of it is tracked in
CLAUDE.md: dead-code elimination (already planned for the optimiser, and eager derivation without it is not shippable);
an arity check for a `foreign` carrying a `where` clause, or withdrawal of that combination
([`boundary.md`](boundary.md) §4); the two printer defects §3.1 of that report reproduces; a cap on
the `where` suffix an inferred interface may carry (§8.1 below); and a position on the n² count.

### Settled alongside it

Evidence for the first four is in [`research/08-roc-language-answers.md`](research/08-roc-language-answers.md).

- **No user-defined infix operators.** Arbitrary fixities force post-parse re-association, breaking
  §3's LL(k) guarantee; Roc reached the same answer from practice.
- **Module import cycles are forbidden**, detected during crawl: they collapse §10's DAG scheduling
  and §8.1's firewall into per-cycle units. Roc justifies the same rule purely on build times.
- **Type aliases are transparent but interned, never expanded.** Elm expands them into every
  dependent's interface — measured bloat (elm/compiler#1453). Copy Roc's compact alias node over a
  shared backing variable.
- **Shadowing is an error**, not a warning, as in Elm. Roc permits it with a permanent warning, but
  its own stated benefit — reading a snippet or diff with stronger guarantees about what names mean —
  is an argument for banning.
- **Top-level annotations are optional**, as in Elm and Roc. The cost lands in §8.1: an interface is
  the *inferred* scheme of each `pub` declaration, so its hash is computable only after checking, and
  an importer is re-checked whenever a dependency's inferred interface changes by value (Elm's
  `.elmi` comparison, Roc's content-hash chain). What stays lexical is the *set* of `pub` names, all
  per-module name resolution (§3) needs. Requiring annotations would have made interfaces free to
  compute; that win is unmeasured, and matching Elm and Roc was judged worth more.
- **Primitives: core is written in beni, embedded in the compiler, with `foreign` declarations for
  what cannot be** (`language.md` §5.4) — Elm's Kernel modules and Roc's embedded builtin `.roc`
  files are the precedents. Core being mostly ordinary beni, §9.1's DCE graph and §9.3's direct calls
  reach the standard library, and core is tested through the same corpus and Node boundary as user
  code; only arithmetic, string primitives and the list representation are `foreign`, with `Int`,
  `Float`, `Char`, `String` and `List a` as `foreign type`, keeping the list-representation question
  (§14 #2) out of the source. The cost is a cold-start parse of core, under a millisecond per
  thousand lines at §2's targets, which §8.3's cache erases.
- **Effects: a pure language, one function arrow, effects as values interpreted by a platform** —
  Elm's model with Roc's name for the boundary. The rejected alternative, Roc's `->`/`=>` with
  effects in the types, composes effectful code more naturally but puts two function kinds and effect
  polymorphism into the unifier. Consequences: §9.1's DCE is exact by construction; §7's unifier is
  unchanged; `main` gets no special type, a platform fact; §3.2's effect-marking question closes as
  "none". **Platform interface, ports and runtime are specified** in [`boundary.md`](boundary.md) on
  report 13's evidence: ports stay and stay asynchronous, because across fourteen JavaScript-targeting
  compilers no shipped design lets user code call JavaScript and keep the no-crash guarantee — but
  the three restrictions Elm stacked on ports do not survive it.
- **Project model: one source root plus embedded core, no manifest; module identity is
  package-qualified from day one.** A module is internally `(package, path)`, so packages need no
  retrofit when they arrive, where Elm's flat global namespace must error when two packages define
  the same module. Manifests, versions, hashes and lockfiles defer to the package work, whose cache
  key holds that anyway. Built ahead of it is the **interface record**: flat and index-based per §5,
  holding public names, types, constructors, opacity and inferred schemes; compared by value now,
  hashed and mmap'd unchanged later.
- **`Int` is a double; exact 32-bit work has its own type.** JavaScript has no integer type, and
  every representation costs something:

  | | Exact to | Cost per operation | Overflow |
  |---|---|---|---|
  | double | 9,007,199,254,740,991 | none, `+` is `+` | **silently inexact** |
  | 32-bit | 2,147,483,647 | a truncation on every result | wraps, defined |
  | BigInt | unbounded | boxed, ~an order of magnitude slower | never |

  BigInt would make the most common type in every program the slowest. **Double is the default**, as
  in Elm, and its failure mode is the worse one: past 2⁵³ addition stops working and says nothing.
  **Bit operations alone are not the escape hatch** — hashing, checksums, PRNGs and binary formats
  need wrapping *multiply*, unfakeable because a 32-bit product can exceed 2⁵³; Elm's own random and
  hashing libraries splitting each multiply into 16-bit halves by hand is the evidence that `Bitwise`
  is insufficient. So core ships an **opaque `Int32`** with total arithmetic — multiply to
  `Math.imul`, add and subtract truncating, shifts and masks native — free at runtime, since
  underneath it is an ordinary number. A distinct type rather than Elm's module over plain `Int`, for
  the same reason `comparable` was dropped: if arithmetic wraps the type says so, and `*` is not
  available on it. `Int64` over BigInt can follow. The stance's exemplar: a capability Elm lacks,
  added inside the wall with no hole cut.

  **Built 2026-09-19**, and two words of the paragraph above are corrected by what was built.
  It is a `pub equatable foreign type`, not an `opaque type` — a type with no beni representation
  is what `foreign type` means (`language.md` §5.4) — and while `*` is indeed unavailable, `==` and
  `<` are NOT, because `core/Int32.beni` declares its own `pub eq` and `pub compare` and the module
  rule makes them the type's methods. The signature list is `checker.md` Appendix B, the paragraph
  a reader meets first is `language.md` §2.5, and it is deliberately not in the prelude.

### Still open

Each is cheaper to take now than later:

| Decision | Why it is load-bearing | State of the evidence |
|---|---|---|
| String representation | Native JS strings are free but give O(n) indexing and a UTF-16/codepoint mismatch, and the choice reaches every string primitive in core | Roc keeps `Str` deliberately minimal and pushes Unicode work to libraries — a stance available to us regardless of representation |
| Sequence default: cons, vector trie, or flat array | A stdlib and literal-syntax decision, not only a representation one (open question #2) | Roc chose a **flat refcounted array**, explicitly rejecting persistent structures: *"flat data structures are much more cpu friendly than persistent ones."* It mutates in place when uniquely referenced and copies when shared, and pattern-matches with slice patterns rather than cons. That mechanism needs a refcount JS can't cheaply provide — but it argues against cons lists being the automatic choice. |

## 3.2 Surface syntax

Roc changed most of its syntax just before and during the Zig rewrite, reasoning in
[`research/08-roc-language-answers.md`](research/08-roc-language-answers.md); two of their findings
are about *parsing cost*, which is our constraint too. **The normative grammar is
[`language.md`](language.md); what follows is each decision and the compiler-speed reason it was
taken for, not a second copy of the rules.**

| Construct | Decision | Why |
|---|---|---|
| Function calls | `f a b` (whitespace application) | Elm-like, and safe **because we are indentation-sensitive** (below) |
| Lambdas | `\x -> …` | `\|x\|` collides with `\|>` and `\|\|` — measured lookahead cost, see below |
| Pipe | `\|>` stays | Roc dropped it for dot-chaining and had to restore it in 2026-07: chaining doesn't cover piping into a lambda |
| Case expressions | `case x of` + indentation | Consistent with being indentation-sensitive; no brace/delimiter apparatus needed |
| Naming | `camelCase` | Matches Elm and the JS target. Roc flip-flopped twice before settling on snake_case for Rust/Python familiarity — a different audience |
| Operators | fixed set, no fixity declarations | §3.1 |
| Type application | `List String` (whitespace) | Same reasoning as calls; Roc's equivalent question is still open because it lacks the indentation rules that make it safe |

### The two parser findings this rests on

**Whitespace application is ambiguous *without* indentation rules — not in general.** Roc moved calls
to `f(a, b)` after Joshua Warner produced token streams with two valid parses; but Roc is
indentation-*insensitive*, and Elm keeps whitespace application and is fine precisely because it is
not. So the lesson is conditional, and carries a price we accept knowingly: **whitespace application
commits us to indentation-sensitivity**, threaded through the combinators as Elm does
(`Parse/Primitives.hs`'s `withIndent`), never a separate layout pass.

**`|x|` lambdas are not free when `|>` exists.** Bullard, #compiler development, 2025-01-15, on Roc's
`|_| ...`: "we had to peek before trying to parse this to make sure we don't try to consume the `||`
and `|>` operators as part of the lambda args." That is lookahead from a syntax choice alone; it
produced fuzzer-caught bugs, and the class was still generating parse errors in real user code as
late as 2026-02.

### Error handling: `?`

`expr?` on a `Result` evaluates to the `Ok` payload, or returns the `Err` from the enclosing
function; `Result.andThen` chains remain. Normative in [`language.md`](language.md) §6.6. Three rules
keep its cost at zero, and a fourth extends its reach.

1. **`?` returns from the nearest enclosing *named* function; inside a lambda it is a compile
   error.** The one real hazard — Roc found it the hard way when backpassing let early returns land
   in a function the reader wasn't looking at. Making the ambiguous case illegal is a free scope
   check, and reversible.
2. **No implicit error conversion.** Rust's `?` applies `From::from`, needing a typeclass we don't
   have (§3), so error types must match exactly.
3. **It desugars in the desugarer** — no new constraint kind, no unifier change, nothing touching
   inference.
4. **It works on `Maybe` as well as `Result`**, the enclosing function returning the *same* shape
   with no conversion between the two: `Maybe` pyramids are as common as `Result` ones in Elm, and
   the check stays local at two desugaring cases.

### Flat effect syntax — OPEN

**Partly settled.** Reports [15](research/15-flat-effect-syntax.md) and
[16](research/16-fibers-and-concurrency.md) were the first evidence base; research
[14](research/14-direct-style/01-solution-space.md) — eighteen per-subject reports and a synthesis —
supersedes both on the design space, and its Elm report answers "is this worth fixing": the pyramid
is real but rare in Elm, the formatter is the binding constraint where it is hit, and the branch is
where the residual pain sits (14/elm §0, §7). The author holds it worth fixing regardless.

**Adopted: a rest-of-block bind, `let x <- e`,** the general sequencing form for **any function
taking its callback last** — `let x <- f a b` is `f a b (\x -> rest)`, Gleam's `use`, purely
syntactic (normative in [`language.md`](language.md) §6.7), on 44 lines of precedent in Roc's
measurement of the same block-shaped rewrite (research 15). The original form dispatched on an
`andThen` table resolved per type after inference, and **that is withdrawn**: typed effects remove
`Task` from the table, `?` covers `Result` and `Maybe`, and the table cannot express
`Task.scope : (Scope -> a) -> a` or `Task.bracket` — without which those nest and the pyramid
research 14 was commissioned to remove reappears at exactly the scopes and resource brackets the
effects design depends on (§9.3). Research 14's option B, adopted because dropping currying (§9.3)
removes Elm's applicative constructor pipeline and this replaces it. **Still open:** whether `Task`
uses this bind or a call-site marker over typed effect sets — research 14's S2, and the synthesis
discussion's "typed effects as calls, with the platform as the only handler", giving
effect-polymorphic higher-order functions and named effects in signatures at the cost of set
unification and a diagnostics deliverable.

**What the evidence establishes** — the rest of this section is the earlier record, numbered because
other documents cite these points by number.

1. **Four languages invented the same mechanism independently** (OCaml's `let*`, Gleam's `use`,
   Koka's `with`, Roc's removed backpassing), all one rewrite and **none consulting a type class**,
   the shape affordable without the type classes §3.1 rules out.
2. **`?` extended to `Task` is the most expensive shape, not the cheapest**: `?` is postfix on any
   application, so the continuation must be hoisted out of argument positions, conditions,
   scrutinees and pipelines. Roc shipped both — backpassing desugared in 44 lines, the
   arbitrary-position marker needed a dedicated 1,046-line pass and shipped with a compiler crash.
3. **It would also introduce a silent wrong answer, verified in our own checker.** `?`'s shape is
   chosen by ordered speculative unification (`Solve.zig` tries `Result`, then `Maybe`), so
   `Task e a` would be a third two-parameter candidate losing the same way.
4. **Generators do something no syntactic rewrite can do**, suspending at an arbitrary point inside
   a branch or loop where block-structured binds capture only the rest of a block.
5. **Effect-TS's cost is its fiber runtime, not its generators**, the generator object being **per
   call, not per bind**. Points 4 and 5 correct an earlier draft.

**The live options**, in increasing order of compiler work:

| | Shape | Binds inside a branch | Binds inside a loop | Cost |
|---|---|---|---|---|
| A | Block-structured (`use`-style) | needs a nested block | **not expressible** | parser work; the desugaring is ~44 lines of precedent |
| B | Emit generators | yes | yes | one state object per call, plus the iterator protocol; opaque to §9.5's elimination and renaming |
| C | Emit a state machine ourselves | yes | yes | a real backend transform, the thing Rust and C# do for `async`; transparent to the optimiser |

B and C allocate the same per-call state object, so the gap is narrower than it looks, and **nobody
has measured this for us, though it is measurable** — emit the same program both ways and compare,
which is what `bench` exists for. **A second question is entangled and answers differently:** beni is
expression-based, so a run of binds is already flat inside one `let`, but a branch is an expression,
so a bind inside it nests whichever mechanism we choose. Making that read flat is a **language**
change (statement blocks), not a codegen one; decide the two separately.

### `Maybe` stays

Roc has none, its FAQ arguing a tag union says *why* rather than merely *that*. **The argument does
not transfer, because Roc's tag unions are structural** — nothing was declared, so nothing needs
refactoring. Beni's ADTs are **nominal**, so dropping `Maybe` means every `Dict.get`, `List.head` and
`String.toInt` needs a bespoke declared type per call site or returns `Result () a`, `Maybe` with
extra ceremony; recovering it structurally would be row polymorphism for sums, carrying the inference
costs §3 exists to avoid (OCaml's polymorphic variants are the cautionary case), where `Maybe` is an
ordinary ADT costing no special machinery. Roc's real insight is orthogonal and worth taking: don't
reach for `Maybe` when a domain type says *why* — stdlib guidance, not a language decision.

### Tuples: yes, unbounded arity (minimum 2)

Normative in [`language.md`](language.md) §6.4. `Dict.toList`, `List.zip`, `List.indexedMap` and
"return two things" all need a pair, and without tuples each wants a declared record type — the
ceremony problem again. **No arity cap, reversing an earlier draft** that copied Elm's maximum of 3
so the tuple type could be a fixed-size IR node, unbounded arity "forcing a slice into the `extra`
array and a loop in the unifier's hot path." **That argument is wrong, and Roc's compiler shows why:
records are already variable-length, so the machinery exists regardless — and tuples use strictly
less of it.** Tuple and record nodes share one `SafeList`/`Range` primitive; `unifyTuple` is an arity
check plus a pairwise loop, twenty lines, against `unifyTwoRecords` with its transitive field
gathering and four extension cases; at runtime tuples alias the record layout path
(`roc/src/types/types.zig:554`, `:743`; `src/check/unify.zig:1397-1421`, `:2490+`;
`src/layout/layout.zig:864`, `src/layout/store.zig:554`). A cap only relocates the per-arity problem
into the standard library (Feldman, #contributing, 2023-03-26).

**Representation:** a fixed-shape object per arity, per §9.4's hidden-class rule; no runtime tag, so
one field less than Elm's `{$: '#2', a, b}`. With `comparable` gone (§3.1) a tuple-keyed `Dict` took
an explicit comparator — the intended consequence, and superseded on 2026-09-18: a tuple has a
derived `compare` and `Dict ( Int, Int ) v` needs nothing written
([`static-dispatch-spike.md`](static-dispatch-spike.md) §9.3). **Positional access `.0`/`.1`, zero-based,
reversing an earlier draft** that rejected it as costing lookahead: the real cost is one branch and
one byte (`roc/src/parse/tokenize.zig:1412-1442`) inside the `.` case the lexer *already* needs.
Unbounded arity makes it necessary, since there can be no per-arity accessors — hence no
`Tuple.first`/`second`.

### String interpolation: `${expr}`, no nested strings, primitives only

Normative in [`language.md`](language.md) §2.6. A **fixed set of interpolatable primitives**
(`String`, `Int`, `Float`, `Bool`, `Char`) with the compiler inserting the conversion, because
without typeclasses there is no `Display`/`Show`; **no new unifier constraint**, "this type is
interpolatable" being discharged *after* solving by §3.1's flat membership test at one syntactic
site; **lexing as a mode flag and a brace-depth counter, no stack**, which is why **a `"` inside an
interpolation is a syntax error**, nested strings being what would force a mode *stack* (the token
stream stays in the flat SoA array with real offsets, so §6.1's lossless CST needs nothing special;
lexing a string as one opaque token and re-lexing later is the approach that *would* hurt);
**multiline strings that do not interpolate and stay raw**, as in Zig, so the line-prefixed path
needs no mode switching; and **free codegen** onto a JS template literal.

### Comments and multiline strings: line-oriented, Zig-style

Normative in [`language.md`](language.md) §2.3 and §2.7. No closing delimiter, no nesting, a newline
always ends it, and **no block comments**, Elm's nesting `{- -}` being exactly the nesting counter
this avoids. `--` comment, `--|` documents what follows, `--!` the module — Zig's machinery with
Elm's vocabulary, because `|` already reads as "documentation" here while `---` is a divider, diff
and Markdown/YAML marker, and is mechanically dearer: Zig needs an "exactly three slashes, not four"
carve-out so `////` isn't documentation, `---` would need one for rows of dashes, whereas `--|`
cannot be produced accidentally — one byte peeked after `--`. It buys all lexer cost avoided (**no
mode stack, no depth counter**) and **a whole error class gone**: with no unterminated comment or
string, a truncated file cannot swallow the rest of the program, which matters for §6.1's recovery.
**Raw multiline strings** sidestep escaping entirely. The lexer tracks state for no delimited
construct besides quoted strings; doc comments are trivia, carried tagged in the CST (§6.1).

### Modules: no header, `pub` per declaration

Normative in [`language.md`](language.md) §5. The name comes from the path, as in Roc, where Elm
declares it *and* requires a match — redundancy buying an error class, and making duplicate names
merely diagnosable rather than impossible. Everything unmarked is private; `pub opaque type T = …`
exposes a name without its constructors; imports stay Elm-shaped. Rejected: **Roc's type modules** (a
capitalised `Url.roc` defines type `Url`, public functions *associated items* on it) — nicer, but a
view of static dispatch, which §3.1 rejected, so we take only the part needing no dispatch,
*namespacing*. **Half of that came back on 2026-09-18**: the module rule makes a method of `T` any
`pub` value of the module that declares `T` ([`static-dispatch-spike.md`](static-dispatch-spike.md)
§1.2), which is Roc's association without Roc's file-is-a-type rule. What is still rejected is the
per-type method block Roc moved to in October 2025 — lookup is keyed on `(TypeId, name)` and never
on text, so adopting it later is a front-end change and nothing else (spec §11); **Go's capitalisation rule**, unavailable because case is spoken for — in ML syntax
`Url` is a type or constructor and `parse` a value, and the lexer depends on it; and **Elm's exposing
list**, two edits per new public function plus an error class of its own.

**§8.1 is unaffected**, the compiler-speed point: the public surface stays lexically computable —
scan for `pub` — so the interface hash needs no inference, parallel name resolution keeps the
property §3 requires, and `exposing (Type(..))`, a wildcard whose meaning depends on reading
*another* module, disappears with it. **The cost:** you cannot read a module's whole API on one line;
you scan the file or ask the tooling.

### Two principles worth stealing

- **Delimiters are for humans, and that is a sufficient reason** (Bullard: "for machine parsing there
  is no need for commas in ANY collection-like syntactic construct... They are there for the
  humans"). Where a delimiter aids reading or editor selection, its parser cost is not an argument
  against it.
- **A formatter that auto-migrates makes micro-syntax reversible.** Roc flipped its optional-field
  marker twice with formatter-driven migration and a did-you-mean diagnostic each time — only cheap
  if the formatter exists early, so it is built alongside the parser rather than at the end, on the
  same lossless CST the LSP needs (§6.1).

### Still open

Effect marking is settled by §3.1's effects decision: the language is pure, so there is none. Record
and optional-field syntax details are open; per the formatter principle above, cheap to revisit.

## 4. Process architecture: a daemon, from day one

The CLI is a thin client over a Unix socket; the compiler is a resident process holding the
`Session`. The LSP server and `beni build` are the *same* process type, so every incremental
investment pays off in both (04 §8; rust-analyzer's `AnalysisHost`/`Analysis` and gopls'
`cache.Snapshot` are the model). Designed in, not bolted on: no global mutable singletons; arenas
reusable per compilation, not per process; every phase able to run against an immutable snapshot
while the next edit is ingested; file watching on `inotify`/`FSEvents` directly, since esbuild polls
and that scales badly on large trees (03 §1).

```
beni (CLI, ~5ms)  ─┐
beni-lsp           ├─► unix socket ─► beni daemon ─► Session
editor / LSP      ─┘                                 ├─ SourceStore (mmap'd files, content hashes)
                                                     ├─ InternPool (strings, types, constants)
                                                     ├─ ModuleGraph + DepGraph (AnalUnits)
                                                     ├─ Arenas (per phase, per worker)
                                                     └─ EmitCache (per-decl JS chunks)
```

## 5. Data representation — the spine of the design

Every IR is a `MultiArrayList` of fixed-size records with `u32` indices and a shared `extra: []u32`
sidecar for variable-length payloads — Zig's own design (01 §1–3), and independently Carbon's,
rust-analyzer's and oxc's (04 §2). A token is **5 bytes** (tag plus start offset, no length field:
derivable from the tag or re-derived at literal decode), an AST node **~13 bytes** (tag, main token,
and an *untagged* data union, since the tag already discriminates). Shapes are in
[`frontend.md`](frontend.md) §3. Rules, non-negotiable across the codebase:

1. **No pointer inside any IR.** References are `u32` indices into a named array: halves reference
   size, survives reallocation, serialises with no fixup pass, and makes equality an integer compare
   (01 §2).
2. **No per-node allocation.** One arena per phase; teardown is a handful of bulk frees. oxc measured
   teardown at ~0.3ms vs ~7ms for an equivalent heap AST (03 §2).
3. **Per-worker arenas, not a shared one.** Roc wrote `SingleThreadArena` specifically to avoid
   `std.heap.ArenaAllocator`'s atomic RMW per allocation (05 §4). Copy this.
4. **Offsets, never slices, into source text.** A slice is 16 bytes; an offset is 4.
5. **No `HashMap` keyed by a dense id.** Roc enforces this with a CI lint (05 §4); adopt the same
   lint. Dense ids index parallel arrays.
   *As built (2026-09-29):* the lint is `src/rules_test.zig`, a unit test and so a gate. It refuses a
   hash map, `int_hash.Map`, `Symbol.Map` or `U32Set` declared with a `u32` key or any `enum(u32)`
   key, unless an allowlist entry says why a column does not serve there. A short-lived table over a
   large id space is a stamped column (`src/stamped.zig`). Lowering's name tables stay maps: a
   column per worker was measured slower (the allowlist gives the numbers).

### 5.1 Interning — with the contention caveat

Identifiers are interned **at lex time** into `Symbol = enum(u32)`, hashing while scanning rather
than materialising-then-rehashing (04 §3); types and constants go into the same `InternPool` so type
identity is `a.index == b.index`, one integer compare (01 §5). This fixes Elm's single largest
structural cost, un-interned `Name` compared byte-by-byte on every lookup (05 §2). But interning has
a documented failure mode — **oxc removed a global interner and gained ~30% parallel parsing
throughput**, the mutex having serialised precisely the phase being parallelised (03 §2).
**Decision:** per-worker interners during parallel lex/parse, merged at one synchronisation point,
then a sharded global pool following Zig's index encoding (per-thread `locals` with the thread id in
the index's high bits, per-shard locks on the dedup tables, 01 §5); short identifiers use inline
storage (SSO) in the token payload so the common case never touches the table.

*Corrected 2026-09-18: of that decision, only the first clause has landed. Per-worker interners
merged at one synchronisation point in worker-index order: yes (`src/Session.zig:421-436`). **The
sharded global pool and the SSO are not implemented** — `Token.payload` is a plain `Symbol`
(`src/lex/Token.zig:22-28`), there is no lock, atomic or shard anywhere in `InternPool.zig`, and
`:24-26` defers sharding to M4. The consequence the rest of the design has to carry is stated at
`src/Session.zig:16-22`: because a worker interns the identifiers of the files it happened to take,
**a global symbol id still varies with `--jobs`**, so no artifact that is compared, hashed or cached
may hold one. That is why every record from `Bir` to `Interface` to `JsIr` holds symbols through one
remappable column; see `plans/m4-plan.md` §2.5.*

*Corrected 2026-09-24 (checker rewrite): the merge is now in FILE order —
`Session.mergeInterners` walks the files by index and interns each symbol a file's tokens or Bir
reference on first sight, then whatever no file references, by text. A global symbol id is
therefore input-derived and no longer varies with `--jobs` or with which worker took which file.
The 2026-09-18 note's premise was already a live bug: the old checker's `unifyRecord` chose a field by id, so
the same input printed different diagnostics under load. What still holds is the rule it drew: an
id moves with every edit to an earlier file, so no user-visible choice may be made by id.*

## 6. Pipeline

```
source bytes
  │ lex (parallel, per file, zero-alloc)          → TokenList (SoA)
  │ parse (recursive descent + Pratt, LL(k))      → Ast (SoA, flat, lossless CST)
  │ lower (per file, NO cross-file knowledge)     → BIR  ◄── content-hashed, disk-cached
  ├─────────────────────────── firewall ────────────────────────────
  │ resolve (per module, needs imports' interfaces) → Resolved + Interface
  │ check (constrain → solve)                       → Typed + Annotations
  │ optimise (lower to decl graph)                  → OptGraph (whole program)
  │ emit (reachability DFS → JsIr → bytes)          → ESM output
```

**BIR is the load-bearing invention here.** Like Zig's ZIR it is *untyped, unresolved, and purely a
function of one file's text*, which makes it content-addressable and cacheable across process
restarts, not just within a watch session (01 §6): a file whose bytes haven't changed never gets
lexed or parsed again on any machine with a warm cache. Everything above the firewall is
embarrassingly parallel; everything below is scheduled on the module DAG.

### 6.1 Parsing

Recursive descent for declarations, Pratt/precedence-climbing for expressions (04 §2) — ~40 lines, no
function-per-precedence-level. Two error-recovery invariants, both free on the happy path (04 §2):
every loop consumes ≥1 token and terminates at EOF, and on error the parser emits a structurally
valid placeholder node, so downstream passes treat it as another node kind and there is no separate
recovery machinery. **Build the lossless CST from day one** — trivia is just more array entries in a
flat design, so the cost is near zero, but retrofitting it later is documented as effectively a
parser rewrite (04 §2), and the LSP will need it.

## 7. Type checking

Architecture is Elm's: **constraint generation, then solving** (02 §1), not Algorithm W — which
avoids W's substitution-composition tax and centralises rank/generalisation bookkeeping in one
function. The contract is [`checker.md`](checker.md) §5–§6; the five techniques chosen for speed, in
leverage order (02 §Top 10):

1. **Union-find with mutation in place**, so "apply the substitution" is a pointer dereference.
2. **Rémy/Kiselyov levels for generalisation** — a `rank` per descriptor means generalisation scans
   only the variables allocated at that rank, never the type environment. Asymptotic, not constant.
3. **Deferred occurs check**, off the unification hot path, once per let-bound name after that region
   stabilises. Elm calls `occurs` in exactly one narrow place, with a `TODO` doubting even that
   (02 §3).
4. **Sharing-preserving instantiation** via a per-copy memo field, killing the classic
   `let x = (y,y)` doubling that real code hits constantly through large record aliases (02 §2.3).
5. **SCC-decomposed binding groups**, bounding both generalisation cost and error blast radius
   (02 §4).

**Errors never stop the build:** a failed unification merges both variables into a poisoned `Error`
content that later unifications trivially succeed against — Elm's cascade suppression, why one
mistake yields one message instead of forty (02 §6). **Good messages stay off the happy path:**
source spans are two packed 32-bit values per node, no allocation and no file path, and the entire
error-rendering subsystem runs only on failure (02 §5–6). The descriptor store is a `MultiArrayList`
with an explicit undo journal (Roc's `SlotUndo`/`DescUndo`, 05 §4), buying rollback for speculation
without cloning.

## 8. Incrementality

Two layers: the cheap one does most of the work, the fine one handles what it handles badly.

### 8.1 Layer 1 — the module interface firewall (primary)

Recompiling a module must **not** recompile its dependents unless its *public interface* changed.
Elm compares the freshly computed `.elmi` against the cached one by value and bumps `lastChange` only
on a real difference (02 §8, 05 §1.4); GHC does the same with `.hi`, OCaml exposes it as `-opaque`.
Beni keys it on **content hashes, not mtimes** — Elm's mtime scheme is the documented cause of its
cache-desync bugs and CI pathologies (05 §3). Cache key = source bytes + module identity + compiler
version + direct imports' interface hashes (Roc's `cache_key.zig` model, 05 §4), with a `stat`
fast-path avoiding hashes for files whose size and mtime are both unchanged (04 §7).

*Corrected 2026-09-18, on two counts, from the M4 readiness audit (`plans/m4-plan.md` §2.2, §3.1).*
*(i) **The key has grown by one term:** `boundary.md` §7.3 adds the content hash of a module's
sibling JavaScript file, and requires the `stat` fast-path to cover sibling files and not only
`.beni` ones; `backend.md` §9 restates the whole key for the reachability edge list.*
*(ii) **The premise of this layer is now an invariant of the record, and was not before.** An
interface is specified to be a function of one module's source and its imports' interfaces.
`Interface.Term`'s `app` and `alias` tags used to spend `lhs` on a `TypeStore.TypeId`, a
whole-program dense index assigned by walking every module in `Graph.Index` order — so, measured,
adding one type declaration (`pub` or private) to an alphabetically earlier module, or adding a new
file containing a type, shifted an untouched, non-importing module's `dump --stage=raw` bytes by one
word: `term 2 app 15 4` became `term 2 app 16 4`. Hashed as it stood, the cutoff would have failed
to fire on approximately every type-introducing edit. **Fixed the same day** (the owner's decision to fix the leak at once):
`app` and `alias` now index a per-module `type_refs` table whose rows are `(package, declaring
module's name, type's name)`, which no unrelated edit can move, and `checker.md` §7 states the
purity rule as an invariant with the encoding and its four consequences. The session's translation
of those rows into `TypeId`s lives outside the record, in `Types.ref_ids`, so reading one is still
one array index. Two whole-program reads named in `checker.md` §7 remain — `Types.build` and
`Types.Builder.aliasBody` — but neither is in the hashed bytes any more.*

**What static dispatch did to this layer, and it is the sharpest measured cost of adopting it.** An
interface is the *inferred* scheme of each `pub` declaration (§3.1, "Top-level annotations are
optional"), and since 2026-09-18 a scheme may carry a `where` suffix: every method constraint its
body accumulated, written into the interface record per quantified variable
([`static-dispatch-spike.md`](static-dispatch-spike.md) §6.5). Two consequences, both from
[`research/19-static-dispatch-spike-results.md`](research/19-static-dispatch-spike-results.md):

- **An unannotated `pub` declaration's interface changes far more often.** Report 19 §4 measures
  4.4–6.5× the churn of the same corpus without the feature — 8.5 % of edits to `core` changing an
  interface before, 55.6 % after. **An annotation removes it entirely**: annotated declarations
  measured 0 interface changes in every edit class on both corpora and both compilers, because an
  annotation's `where` clause is exactly the constraints and the body cannot add to it. That is the
  firewall argument report 18 §2.3 made, priced.
- **The suffix is capped at 64 clauses.** A record printer flattens at 64 links and the `where`
  printer did not, so report 19 §3.1 reached a 6.4 kB interface entry for one declaration. Since
  2026-09-18 an **unannotated** declaration whose inferred set would exceed 64 constraints is
  `too_many_inferred_constraints` and promotes nothing, so a promoted suffix is at most 64 clauses
  — ~2 kB at §3.1's measured 31 characters per clause — and an annotated one is bounded by the
  annotation's own text (spec §6.4, §10.11, A.83). The author is also told the moment an
  unannotated `pub` declaration in the root package acquires a constraint at all: spec §10.9's
  warning is on by default.

**Explicitly rejected: salsa-style fine-grained query memoization.** rustc's own documentation says
fingerprinting "is the main reason why incremental compilation can be slower than non-incremental";
there are logged cases of incremental (13.47s) losing to clean (2.74s), and repeated 2–4× memory
blowups requiring dedicated LRU engineering (04 §6a). The macro-free language design removes the
reason rust-analyzer needed it.

### 8.2 Layer 2 — declaration-level dependency graph

Zig's `AnalUnit` insight, the difference between a 63ms rebuild and a 6-second one: a declaration's
**type** and its **value** are separate nodes in the dependency graph (01 §7), so editing a body
invalidates its value, not its signature, and callers depending only on the signature are untouched
*within* the module as well as across it.

| Unit | Invalidated by |
|---|---|
| `decl_ty` | a change to the declaration's type signature or inferred scheme |
| `decl_val` | a change to its body |
| `ctor` / `type_def` | a change to an ADT's constructors or a record alias's fields |
| `emit` | a change to `decl_val`, or to any representation decision it depends on |

Propagation is Zig's two-phase mark: a direct dependent becomes `outdated`, its transitive dependents
`potentially_outdated` with a counter, and a PO unit whose counter reaches zero without ever being
marked outdated is *proven* unchanged and never re-analysed — what stops transitive invalidation
degenerating into "recompile everything" (01 §7).

### 8.3 Persisted cache format

Dump the arena's flat arrays as raw byte ranges with a small header; `mmap` on load; validate with a
format version and content hash. No general serialization library — rkyv-style zero-copy is the
*idea* to steal, not the dependency (04 §7). Roc calls this "zero-parse deserialization" and loads at
roughly memcpy speed (05 §4). Only possible because of the no-pointers rule in §5.

*Corrected 2026-09-19, on the `mmap` clause only, from the front-end artifacts' measurements (`plans/m4-2.md` §4).
Everything else here stands: flat arrays as byte ranges, a header, a format version, validation on
load, no serialization library. **But `mmap` per entry loses to `read` per entry at this granularity,
measured.** 633 files on this machine's btrfs: `open` + `mmap` + `munmap` costs **4.5–5.0 ms**, and
it costs the same whether the loader touches one byte or every page — the cost is the syscall pair,
not the paging — against **1.9–2.3 ms** for `open` + `read` into a reused buffer. An `mmap` wins only
with ONE mapping over MANY entries: one 8 MB pack file maps and reads its 633 headers in 0.05–0.28 ms.
So the granularity decides the mechanism, and the front-end cache is one file per key and therefore `read`. Two
consequences follow and are taken deliberately: the on-disk form stays **little-endian by definition
and host-alignment-independent**, exactly as the interface record is (`checker.md` §7), so nothing in
a cache directory is machine-specific by layout; and §8.3's zero-copy load is not abandoned but
**re-aimed at the pack file**, which is the incremental whole-program passes' to take when `Types`, the `Reach` edge lists and the
emit cache arrive and the directory's shape is being revisited anyway. The numbers for that are in
`plans/m4-2.md` §4 and §6 so it need not be measured twice.*

### The interface hash

*Added 2026-09-18. The interface hash is the part of M4 that is the same under every answer to
`plans/m4-plan.md`'s nine open decisions: make the interface serializable, hash it, and prove a
round-tripped build is byte-identical to a cold one. The record's byte format is `checker.md` §7;
the plan is `plans/m4-slice-zero.md`.*

**The hash is `std.hash.SipHash128(1, 3)` over the serialized record's bytes in full** — magic,
version, column table, columns and their alignment padding — with an all-zero key, and it is not
stored inside the record. 128 bits because an accidental collision then has to be impossible rather
than unlikely; SipHash-1-3 because it is the only 128-bit output in `std.hash` that is not
byte-at-a-time. Measured on the M4 plan's machine at a 3 kB record, the size of one module's
interface: **0.49 µs, 6.2 GB/s**, so hashing every module of the 100k corpus costs 0.31 ms.
Rejected: `Fnv1a_128`, the only other 128-bit choice, at 3.32 µs and 0.93 GB/s; `Blake3`, at 4.53 µs
and cryptographic, for a property a cache does not need; `Wyhash` (0.105 µs) and `XxHash3`
(0.057 µs), faster but 64-bit, and the 128-bit margin costs a third of a millisecond across the
whole project. **It is not a MAC.** The key is a public constant, so nothing here resists someone
who can choose the source files; the threat model is accident.

**Equal source ⇒ equal bytes ⇒ equal hash**, at every `--jobs`, on every run, and on every machine:
the record holds no `Symbol`, no `TypeId` and no `Graph.Index`, every order in it is by name text,
and every scalar of the serialized form is little-endian by definition (`checker.md` §7). A *cache
directory* is still machine-local — §8.3's zero-copy map wants the host's own alignment — but the
hash is not.

**Two hidden flags, and they are hidden on purpose.** `--roundtrip-interfaces` serializes and
deserializes every module's record in place the moment its check finishes, so every dependent, every
dump, every dispatch table and every emitted file is built from bytes that have been through the
format. `--iface-hash` makes `check` print one `<package>:<Module> <32 hex digits>` line per module,
including `core` and the platform, sorted by the printed key `<package>:<Module>`, as text. Both are accepted like `--jobs`, are absent
from `--help` and from `checker.md` §2's table, and are diagnostic surface rather than product
surface. A test-only entry point was the alternative and is refused: the suite is black-box (the
binary driven by files and flags), and an in-source hook would move the assertion off the thing that
ships.

**The acceptance test is §10's determinism rule with one more axis.** An incremental build's every
output stream and output file must be byte-identical to a cold build of the same source tree, so for
every corpus case of every kind that runs the checker, four runs — {plain, `--roundtrip-interfaces`}
× {`--jobs=1`, `--jobs=8`} — must agree byte for byte on exit code, stdout, stderr and every file
written: diagnostics, `--stage=raw`, the `.iface` golden, `--stage=dispatch`, and the emitted
JavaScript. The emitted JavaScript is compared as bytes in the three extra runs and executed once, as
today. At a measured 9.4 ms per small-fixture invocation the added axis is ~20 s over the ~576 cases.
This is the first test in the project that asserts the firewall's premise rather than assuming it:
until it passes, every claim about a warm rebuild is unfalsifiable (`plans/m4-plan.md` §3.4).

**And the firewall's first real measurement.** An interface-churn instrument (since retired;
its result is `research/19` §4) applied four mechanical edit classes
and byte-diffed `dump --stage=raw` before and after, which counts changed bytes in one module's dump
and cannot see a cross-module effect. With `--iface-hash` it reported "importers re-checked" by hash
instead, and gained the edit class it could not express: **a type added to a module the observed one
does not import — expected 0**, which is what `TypeId` in the record used to make nonzero.

**What the interface hash deliberately does not do**, each pointing at the decision that owns it: no cache
directory and no file naming (the owner's order: disk cache before daemon); no invalidation policy and no cache
key, so the `stat` fast-path, the sibling `.js` hash of `boundary.md` §7.3 and the "produced by a
clean check" bit all wait (the same order); no reserved bits for effects (decided: the version field
is the mechanism); no `mmap` and therefore no commitment to a host-specific layout (the same order); no memory
ceiling, no watching and no cancellation (the daemon's decisions). It also does not close the two cross-module
`Bir` reads `checker.md` §7 names, `Types.build` and `Types.Builder.aliasBody`: the round-trip
happens with every module's Bir in memory, which is what keeps the step small.

### The persistent cache, and its key

*Added 2026-09-19 (`plans/m4-1.md`), taken against the owner's decisions on the order of the
incrementality work. It is the first step that keeps anything between processes; it changes not one byte of the interface record.*

**What the persistent cache is, in one sentence.** A module whose cache key is unchanged is not re-checked: its
interface record, its dispatch table and its diagnostics are loaded from disk and installed, and
`constrain`, `solve`, `exhaustive`, `fillInterface` and `Cycles` never run for it. The FIREWALL
CUTOFF — an importer spared because its imports' interface *hashes* did not move although their
sources did — is **the firewall cutoff, below,** and is deliberately not here; §8.1's formula is reached in two steps and
this is the first.

**The key is a 128-bit value over this byte string, in this order, every integer little-endian:**

```
"BENIKEY\x00"           8       magic
key_version: u32                bumped whenever this recipe changes
build_id: [16]u8                the compiler build id, below
package: u8                     SourceStore.Package — app, core or platform
name_len: u32, name             the DOTTED module name ("Json.Decode"), UTF-8
options_len: u32, options       the canonical option string, below
source_hash: [16]u8             over the module's source bytes
sibling_hash: [16]u8            over its sibling .js, or 16 zero bytes when it declares no `foreign`
core_epoch: [16]u8              over every core module's key; 16 zero bytes for a core module itself
import_count: u32
  per direct import, sorted by (package, name) as bytes, duplicates removed:
    package: u8, name_len: u32, name, key: [16]u8
```

hashed with the same `std.hash.SipHash128(1, 3)` and the same all-zero key the record uses
(`src/resolve/iface_bytes.zig:141`), so there is one hash function in the compiler. Keys are
computed **serially, in `graph.order`** (`src/resolve/Graph.zig:172` gives the direct imports), which
is why an import's key is always available before its importer's.

**An import contributes its KEY, not its interface hash, and that is the step's central decision.**
A key is inductively the whole transitive input set, so an equal key means every byte that could
reach this module's check — sources, options, compiler — is identical, and every whole-program fact
recomputed from them (`Types`, the `equatable`/`comparable`/`has_function` fixpoint, the settled bits
of `plans/m4-slice-zero.md` §4) is identical with it. The interface-hash form is *weaker* than the
record: a dependent's check reads facts about its dependencies that the record does not carry, and
enumerating them and proving the enumeration complete is the whole content of the firewall cutoff. *Rejected: keying
on the imports' `(interface hash, sidecar hash)` pair now — it is the cutoff's answer arrived at without
its proof, and the sidecar that would carry the settled bits does not exist yet because every
module's `Bir` is still in memory.* The cost is stated plainly: **with this key alone a comment-only edit to a
leaf re-checks every transitive importer**, because the leaf's key moved even though its interface
hash did not. That is the number the firewall cutoff exists to fix.

**`core` is an unconditional input of every module's check**, with no import edge to say so — the
solver reaches `core/Basics` directly (`src/check/Solve.zig:2583`, `:3348`), `Types.findWellKnown`
reads core's interfaces, and `Reach` reads core's `Bir` (`src/js/Reach.zig:224`, `:313`). `core_epoch`,
one hash over the sorted `(module name, key)` list of the core package, is how the key says so.

**The compiler build id** is 16 bytes produced at build time by `build.zig` and passed to the
compiler as a build option: `SipHash128(1, 3)` over `beni.version` (`src/beni.zig:8`), the Zig
version string, the optimize mode, the target triple, and every file under `src/` — path then bytes,
in sorted path order. *(Amended 2026-09-29, not built: and every platform's Zig module compiled
into the binary — its markup lowerings and what they import, such as `html`'s parser table,
built-in or added with `-Dplatform` — because a lowering is part of the compiler; `boundary.md`
§9.5–§9.6. The table of HTML character references markup text decodes is under `src/` and so
already covered, `frontend.md` §9.7.)* `beni version` prints it after the version, so a bug report names the compiler
that wrote a cache. It does **not** cover `core/` or `platforms/`: those are hashed per module by
`core_epoch` and by the import terms, which is finer. *Rejected: hashing the installed binary at
runtime — correct, and ~2 ms of a 15 ms budget.* A test forces a different one with the hidden
`--cache-build-id=<s>`, whose bytes replace the build-id term; it is hidden for
`--roundtrip-interfaces`' reasons and is how the "a compiler-build change discards the whole cache"
fixture is written.

**The option string is the flags that change what a module produces, and only those**, written as
`core=<0|1>;platform=<0|1>;informational=<0|1>;pattern_budget=<n>` — `Lower.Options`' two permission
bits (`src/bir/Lower.zig:149-162`), the informational-warning switch, and the usefulness budget,
whose exhaustion is an error of that module (`checker.md` §6.6). Everything else on `Cli.Common`,
`Cli.Check` and `Cli.Build` (`src/Cli.zig:77-162`) is **out**, each for a reason: `--jobs` because
output is identical for every `n` and keying on it would hide the bug that rule forbids; `--root`
and `--core-root` because they reach the key through the module name and through `core_epoch`
respectively, and keying on the string would make `src` and `./src` miss; `--platform` because what
it changes is what an import resolves to, which the import terms already carry, and an unresolvable
one is an error and errors are not cached; `--diagnostics`, `--self-profile`, `--explain`,
`--iface-hash`, `--positions` because they select a rendering; `--roundtrip-interfaces` because a
run with it must produce the same record, and exempting it would excuse it from the acceptance
matrix; `--out`, `--library`, `--release` because they are the backend's and no emitted byte is
cached.

**The `stat` fast-path is the front-end artifacts'.** The persistent cache reads and hashes every source on every run because it reads
every source anyway, so the hash is the only added cost: 1 836 kB at the 3.2 GB/s measured here is
**0.57 ms** over the 100k corpus, against a 4.5 ms `read` phase. There is no size/mtime/inode column
on `SourceStore.File` (`src/SourceStore.zig:67-85`) and the persistent cache does not add one; the fast path pays
only once the read itself is gone.

**The cache directory** is named by `--cache-dir=<path>` on `check` and `build`
([`frontend.md`](frontend.md) §1) and **there is no default: at first the cache was opt-in**. A cache
that is on by default must be right about every input, and the fixtures that establish that are this
step's product, not its premise. It became the default with the firewall cutoff, whose cutoff makes it
worth having and whose edit-scenario table is what proves the key complete. Inside it, one file per
module, **content-addressed by the key**: `<dir>/v<n>/<key[0..2]>/<key[2..32]>.bec`, two levels so
no directory holds 100 000 entries. Writing is write-to-temp-then-`rename` inside the same directory
and there are no locks: two `beni` processes that compute the same key write identical bytes and the
later rename is harmless, and two that compute different keys never touch one file. *Rejected: one
entry per module path, overwritten — two builds of one project with different options then fight
over one file, and a stale entry becomes a wrong answer instead of an unreferenced one.* **No
garbage collection** and no size cap: entries accumulate at ~2 kB per checked module per
distinct key, and the remedy is deleting the directory, which is always safe. `.gitignore` it; a
cache is machine-local by policy from the moment §8.3's zero-copy map lands, and is never committed.

**A cache entry is written only for a module whose own check produced no `error`-severity diagnostic
and which the graph did not poison.** That is §3.2's "produced by a clean check" bit, and it is a
refusal to write rather than a bit to read: an `<error>` scheme is a hole every importer checks
clean against, and the one failure mode a compiler may not have is `beni check` exiting 0 over it.
Warnings are cached, with the entry, and re-reported byte-identically — `ambiguous_method_receiver`
is on by default, so "a module with any diagnostic is never cached" would exempt most real projects.

**What a hit skips, and what still runs.** For every module, hit or miss: `enumerate`, `read`,
`lex`, `parse`, `lower` — the front end runs for every module because `Types.build` and
`settleEquatable` walk every module's `Bir` (`src/check/Types.zig:364`, `:477`) and so do `Resolve`,
`Cycles`, `Reach` and `js/Lower` — then `merge_interners`, `graph`, `resolve` (which builds the
interface *shell* and its `Provenance`), the key pass, and `types`. For a **miss**: the whole of
`ModuleCheck.run` (`src/check/Check.zig:584`), then the entry is written. For a **hit**: translate
the entry's module
and type references into this session's `Graph.Index`es and `TypeId`s, install the record and the
dispatch table, replay the diagnostics, fill `Types.ref_ids` (`src/check/Check.zig:1127-1129`) — and
nothing else. `beni build` then runs `eliminate` and `emit` for every module as it always did: no
emitted byte is cached, and the write-skip `Emit.flush` wants belongs to the incremental whole-program passes.

**The acceptance test is the matrix with a third axis.** `tests/blackbox/matrix_test.zig` gains two
runs per fixture: a **cold-with-cache** run at `--jobs=1` into a fresh cache directory, which must be
byte-identical to the plain run and report `cache_hits = 0`, and a **warm** run at `--jobs=8` against
it, which must be byte-identical to the plain run and report `modules_checked = 0`. Three counters
say so: `cache_hits`, `cache_misses`, `modules_checked`. The `--jobs` cross is deliberate — a cache
written at one worker count and read at another is what would catch a `Symbol` reaching the bytes.
**What must NOT be asserted equal across the axis is `unifications`, `generalisations`,
`instantiations` and `obligations`**: on a warm run they go to nearly zero, which is the point, and
`plans/m4-plan.md` §4.5's "the counters did not move" is a claim about two runs at the same
temperature.

**The matrix has since been deleted** (the owner's decision, 2026-09-28): a sweep of every corpus
fixture through every axis cost a third of the black-box suite and had, for a while, been asserting
nothing about its dumps without anyone noticing. The same claims are made by a few hand-picked
tests, each on a small project built to reach one branch: in `tests/blackbox/cache_test.zig`, *a warm
build emits byte-identical JavaScript, and it runs* (cold at `--jobs=1`, warm at `--jobs=8`, over a
generic, a derived `eq`/`compare` and a type crossing modules), *a cache written in one configuration
and read in another*, *a cold run with --cache-dir writes entries* (`cache_hits = 0`) and *a second
check of an unchanged tree re-checks nothing*; in `iface_test.zig`, the three round trips on a build
and on an importer's diagnostics; and in `build_test.zig`, a refused build's diagnostics at both
`--jobs`.

**Explicitly not in the persistent cache**, each pointing at its owner: front-end artifacts on disk and the `stat`
fast-path (the front-end artifacts); the firewall cutoff, and with it the declared-type sidecar of
`plans/m4-slice-zero.md` §4 — the cutoff needs its definition and its hash, an incremental `Types` its bytes
(`checker.md` §7); the whole-program passes, `Types` and the `Reach` edge lists, and
any caching of emitted bytes (the incremental whole-program passes); `mmap` and §8.3's zero-copy load (the same, with the artifacts);
the daemon, the socket protocol, the memory ceiling, watching and cancellation (the daemon, its decisions
**PENDING**); the declaration-level graph of §8.2.

### The front-end artifacts, and the file key

*Added 2026-09-19 (`plans/m4-2.md`), taken against the owner's decisions on the order of the
incrementality work. It changes not
one byte of the interface record, the cache entry or the module key; it adds a SECOND file beside
them, under a second key.*

**What the front-end artifacts are, in one sentence.** A file whose **file key** is unchanged is not read for its
content, lexed, parsed or lowered: its pre-resolve `Bir`, its token spans, its line-start table and
its front-end diagnostics are loaded from disk and installed, and `lex`, `parse` and `lower` never
run for it. On the 100k corpus the front end is **41.9 ms of a 62 ms warm `check`** *(measured,
`--jobs=1`)* — 67 % of it — and that is what this step removes.

**The artifact set is decided by who still reads what on a WARM run, and it is smaller than the
front end produces.** Four things survive `lower` and go to disk; two do not.

| Artifact | Who reads it after `lower` | Cached |
|---|---|---|
| **`Bir`, PRE-resolve** | `Resolve` (rewrites it in place), `Types.build`, `Cycles`, `Reach`, `js/Lower`, `Emit`, and the whole check on a miss | **yes** — and only the pre-resolve state, `plans/m4-plan.md` §2.3 |
| **Token `tag` + `start`** | `Session.tokenSpan` and `moduleNameOfImport` (`Session.zig:1195`, `:1244`), `Emit.tokenPosition` (`js/Emit.zig:324`), `js/Lower`'s `token_starts` (`js/Emit.zig:1210`) | **yes**, those two columns and no others |
| **`line_starts`** | every `diagnostic.position` call, in four reporters | **yes** |
| **Front-end diagnostics**, as the lex/parse/lower phases RENDERED them | the collect-and-sort at the end of every run | **yes** — the phase that renders them does not run on a hit |
| **`Ast`** | **nothing** on a `check` or a `build` path | **no** |
| **`comments`** | `fmt` and `dump --stage=ast\|bir\|tokens` only | **no** |

Tokens lose `line` and `payload` because only the parser and lowering read them, and dropping
`payload` is what makes the token sections **hold no `Symbol` at all** — 13 bytes a token become 5.
The `Ast` is the load-bearing omission: it is a pure, relocatable, symbol-free artifact
(`plans/m4-plan.md` §2.1) and caching it would be easy, and no phase downstream of lowering reads
one, so it would be bytes nobody loads. `fmt` and `dump` take no cache flag (`frontend.md` §1), and
the one command that would want an AST back — M5's LSP — wants it for a file the user is editing,
which is a miss by construction. *Rejected: caching tokens whole and the `Ast` with them, "because
LSP will want it" — a cache pays for every byte it writes on every cold build and is asked for these
bytes by nothing that exists.*

**The file key is not the module key, and that is the whole reason for a second file.** The module key
folds every import's key, so a body edit in a leaf moves every transitive importer's module key. It
must not move their FRONT END. The file key is a 128-bit value over this byte string, in this order,
every integer little-endian, hashed with the same `SipHash128(1, 3)` and the same all-zero key
everything else in the compiler uses:

```
"BENIFEK\x00"           8       magic
key_version: u32                bumped whenever this recipe changes
build_id: [16]u8                the compiler build id, exactly as the module key takes it
package: u8                     SourceStore.Package — app, core or platform
lower_bits: u8                  bit 0 `Lower.Options.core`, bit 1 `.platform`
name_len: u32, name             the DOTTED module name, `Lower.Options.module_name`
source_hash: [16]u8             over the module's source bytes
```

Those are `Lower`'s inputs and nothing else: lowering is given `(text, tokens, tree, interner,
Options{core, platform, module_name})` (`src/Session.zig:735-744`, `src/bir/Lower.zig:149-162`) and
is specified to read no other module (§6). **`--pattern-budget` and the informational switch are
NOT in it**, although they are in the module key: neither reaches lowering, and putting them in
would throw the front end away for a flag that cannot change a token. Nor is any import, any sibling
`.js`, or `core_epoch` — a `Bir` is a function of one file. A module name is in it because
`self_import` reads it; the package and the two permission bits because `foreign` and `equatable`
are lexically gated.

**Two files, not two sections of one.** `<dir>/v<n>/<key[0..2]>/<key[2..32]>.bec` is the persistent cache's entry
under the module key and is untouched; `…/<file key>.bef` is the front end under the file key, same
fan-out, same directory, same "a bad file is a MISS, never a message and never an exit code"
posture. *Rejected: one file with two independently-keyed sections — a file is named by one key or
it is not content-addressed, and the common edit is exactly the one that moves an importer's module
key and leaves its file key alone, so the two would have to be rewritten together for no reason.*

**The container is the entry's, and it is read rather than mapped.** Magic `"BENIFE\x00\x00"`, a
`format_version`, a section count, the file key repeated in the header, then a section table of
`{offset, len}` from byte 0, 4-byte aligned, gaps zero-filled, every scalar little-endian — the
shape `checker.md` §7 fixes for the record and the entry, for the third time and deliberately, so
there is one container in the compiler. Sections, in this order and no other: `bir_insts_tag`,
`bir_insts_token`, `bir_insts_lhs`, `bir_insts_rhs`, `bir_extra`, `bir_string_bytes`, `bir_symbols`,
`bir_decls`, `bir_ctors`, `bir_locals`, `bir_refs`, `bir_imports`, `bir_exposed`, `bir_interface`,
`bir_diagnostics`, `token_tags`, `token_starts`, `line_starts`, `diagnostics`, `strings`. `insts` is
split into its four SoA columns for the reason the record's `terms` is: that is what the structure
already is. §8.3's `mmap` was measured and refused at this granularity; the correction is there.

**Loading validates, and a bad artifact is a MISS.** Wrong magic, unknown version, a header key that
is not the file's name, a section leaving the file, a `strings` record overrunning its blob: each is
a miss and the file is lexed. Past the header the posture is the record's — bounds-checked at use —
with one addition the `Bir` needs and the record does not: **`verify` walks the four structural
promises before the artifact is installed**, because a loaded `Bir` reaches code that reads it by
raw index with no check. Every `Decl.inst_start..inst_end` in range, nested and non-overlapping in
declaration order as `src/bir/Bir.zig:10-14` promises; every `locals`, `refs`, `ctors`,
`type_params` and `params` range in range; every `Inst.Tag`, `Decl.Kind`, `Local.Kind` and
`Ref.Kind` a value its enum defines; every `SymbolIndex` inside `symbols`; every `main_token` inside
`token_tags`. It is a linear pass over the columns with no allocation — the shape `JsIr.verify`
already has (`src/js/JsIr.zig:509-532`) — and the step must report its cost as a `frontend_load`
sub-row against the 14.1 ms `lower` it replaces. *Rejected: trusting the bytes because the key
covers them — the key says which compiler and which source, not that the disk kept them.*

**The write pass, re-evaluated, which `plans/m4-1.md` §11.5 handed here.** Measured on this
machine's btrfs, 633 files into a fresh tree, best of three, with the fan-out pre-created: a
temp-file-plus-`rename` per entry costs **26.1 ms serial** and **15.9 ms on 8 threads**; a plain
`create` with no temp and no rename costs **12.9 ms serial** and **7.0 ms on 8 threads**; and the
entry SIZE barely moves any of them — 2.2 kB and 13 kB are within 10 % of each other, so it is
syscalls and directory metadata, not bytes. Three decisions follow. **(1) The front-end artifact is
written by the worker that produced it**, inside the per-file phase, which is already parallel and
already does file I/O; it is not a serial pass and has no pass of its own. **(2) Both writers drop
the temp-and-rename** and write the file directly. That is safe precisely because the name is a
content hash: two processes racing on one key write IDENTICAL bytes, so an interleaving is still the
right bytes; a reader seeing a partial file sees a short one and the section table's bounds check
makes it a miss; and a crash mid-write leaves a truncated file that the next build's miss
overwrites, so the failure is self-healing. *Rejected: keeping `rename` — it is 13 ms of a cold
build to buy an atomicity that a content-addressed name already provides.* **(3) The pack file is
recorded and not taken.** One file for the whole generation writes in 0.5–2.7 ms and maps in 0.05–0.28
ms, 10–50× better than either, and it is where §8.3's zero-copy load goes — but it needs an index, a
merge on write, and an answer for two processes whose key sets differ, none of which the front-end artifacts have a
fixture for. It belongs to the incremental whole-program passes, with these numbers.

**The `stat` fast path stays out of the front-end artifacts, and moves to the daemon.** The persistent cache deferred it here on the argument
that it pays once the read is gone. It is not gone: the file key hashes the source, so the source is
still read. What a `stat` path would save is `read` **5.2 ms** plus the source hash **0.6 ms**, minus
**1.9 ms** for 633 `open`+`fstat` *(all measured)* — a net **~3.9 ms** of a predicted ~30 ms warm
`check`. Against that it wants an index from PATH to file key, and a path in this compiler is never
made absolute (`frontend.md` §1) — so the index would be keyed on how the build was invoked rather
than on the file, and `beni check src` and `cd .. && beni check proj/src` would miss each other. **The
rule it must obey when it does land is stated now so it is not re-derived: trust a `(size, mtime,
inode)` match only when the mtime is OLDER than the index's own write time by more than the
filesystem's timestamp granularity — git's "racy" rule — and hash otherwise.** That covers the edit
made twice inside one tick, a checkout restoring an old mtime, a copied tree and a skewed clock; each
of the others degrades to a hash, which is 0.6 ms. The daemon is where it belongs because it holds the
sources in memory and the watcher already knows what changed.

**Acceptance is the matrix, one hidden flag, and a counter that must be zero.** The matrix's cache
axis already runs cold-then-warm and byte-compares everything, and gains no new shape — what it
gains is an assertion: a warm run's `files_lexed`, `files_parsed` and `files_lowered` counters must
be **0**, which is the only way "the front end did not run" is a fact rather than a timing.
`--roundtrip-frontend` joins `--roundtrip-interfaces` and `--roundtrip-dispatch` as a hidden flag of
the same family: every file's artifacts are serialized, deserialized and re-installed in place the
moment its per-file phase ends and before anything downstream reads them, so every dump, every
diagnostic, every dispatch table and every emitted byte is built from artifacts that have been
through the format. It is passed with its two siblings on the matrix's round-tripped runs, at no
extra invocations. (The matrix is gone, see above; the warm-run counters are asserted by
`cache_test.zig`'s *a warm run lexes, parses and lowers NOTHING*, and the three flags together by
`iface_test.zig`'s build through all three round trips.)

**Explicitly not in the front-end artifacts**, each pointing at its owner: the firewall cutoff, and with it the
declared-type sidecar's definition and hash (below); the whole-program passes — `types`, `graph`,
`merge_interners`, `eliminate`, the 4.68 ms serial floor of `plans/m4-plan.md` §4.3 — and any
caching of emitted bytes (the incremental whole-program passes); the pack file and §8.3's zero-copy load (the same); the `stat` fast
path (the daemon, above); the daemon, the memory ceiling, watching and cancellation (its decisions
**PENDING**); the `Ast` an LSP will want (M5); the declaration-level graph of §8.2.

### The firewall cutoff, and the dependency digest

*Added 2026-09-19 (`plans/m4-3.md`), taken against the owner's decisions on the order of the
incrementality work. It is the
step §8.1 has been pointing at since the document was written: the first one in which an importer
is spared because its imports' PUBLIC FACE did not move, although their sources did. It changes not
one byte of the interface record, the cache entry or the front-end artifact; it changes the module
key, and it adds a second hash beside the interface hash.*

**What the firewall cutoff is, in one sentence.** A module is re-checked only when something it can OBSERVE about
one of its imports changed — and "observe" is a closed, enumerated list, not a hope.

**The measurement that says why.** On the 100k corpus, with the front-end artifacts in place *(measured, ReleaseFast,
`--jobs=1`, ABBA, load 0.3–0.6)*: a fully warm `check` is **40 ms** and a cold one **130 ms**, but a
warm `check` after **a comment added to one leaf module** is **115 ms** — 88 % of cold. A comment,
a whitespace change, an added private value and an added private type all cost the same 115 ms, and
so does the same edit made in a hub. The reason is the persistent cache's key induction: that one edit moves **624
of 634 module keys** and **0 of 634 interface hashes**. The cache is doing almost nothing for the
one case §2's budgets are about, and this step is the whole of the difference.

**An import contributes `(interface hash, dependency digest)`, and that pair replaces its key.** The
key's recipe is otherwise unchanged and `key_version` bumps to 2:

```
"BENIKEY\x00"           8       magic
key_version: u32                2
build_id: [16]u8                the compiler build id, unchanged
package: u8                     SourceStore.Package — app, core or platform
name_len: u32, name             the DOTTED module name, unchanged
options_len: u32, options       the canonical option string, unchanged
source_hash: [16]u8             over the module's source bytes, unchanged
sibling_hash: [16]u8            over its sibling .js, unchanged
core_surface: [16]u8            REPLACES core_epoch — one hash over the core
                                package's sorted (module name, interface hash,
                                dependency digest) list; 16 zero bytes for a
                                core module itself
import_count: u32
  per direct import, sorted by (package, name) as bytes, duplicates removed:
    package: u8, name_len: u32, name,
    iface_hash: [16]u8,         `iface_bytes.hash` over the import's record
    digest: [16]u8              the import's dependency digest, below
```

*Amended 2026-09-25 (`checker-v2.md` §14.3):* `key_version` 3. The compiler-identity
component gains the checker id right after the build id — `checker_len: u32, checker`, the text `v1`
or `v2` of the hidden `--checker` flag — in every module's key, core's included, so an entry one
checker wrote is never read by the other. Deleting v1 removes the term with the flag.

*Amended 2026-09-27 (`checker-v2.md` §14.3):* `key_version` 4. From then on `v2` checks
every package, `core` included, where it had meant "v2 checks the root package, v1 checks `core`";
the text stays `v2`, so the version moves instead, and no `core` entry v1 wrote under `v2` is read
by a v2 that checks `core` — not even across a `--cache-build-id` that pins the build id.

*Amended 2026-09-27, when v1 was deleted (`checker-v2.md` §14.3):* `key_version` 5. v1 and the hidden
`--checker` flag are deleted, and the checker id with them: the compiler-identity component is the
build id alone again, as before 2026-09-25. The bump keeps a key without the term from ever equalling one
written with it.

**`core_surface` is `core_epoch` with its term changed and nothing else.** `core_epoch` hashed core's
KEYS, so a comment in `core/Dict.beni` under `--core-root` moved every module in the project.
Hashing core's `(interface hash, digest)` pairs instead costs the same one term and gives the
property that matters: an edit to core that no module can observe re-checks nothing outside core.
*Rejected: narrowing it to implicit import edges on the six modules `Types.findWellKnown` names.* It
is sharper, and it is not worth the proof it would need — `js/Reach.zig:224` reaches `core/String`
and `core/Basics` by scanning their `Bir` with no edge at all, and enumerating the build side's core
reaches is the incremental whole-program passes' job, not this step's. One term over ten modules is the honest price of not
enumerating them yet.

**The dependency digest is a SECOND hash per module, and it is deliberately not part of the
interface hash.** Its bytes are `checker.md` §7. It carries what a dependent reads about a module
that the record does not say, and it is separate for the reason §8.1's purity rule gives: adding a
private type to a module must not move that module's interface hash, and it does not move its digest
either — but the two facts have different owners, and folding the digest into the record would put a
module's private business into the bytes every `.iface` golden and every `--stage=raw` output
asserts. The record is the public face; the digest is the checking contract. `dump --stage=raw` and
the `.iface` goldens do not move by one byte in this step, and the record's `format_version` does
not bump.

**The digest is INDUCTIVE over direct imports, and that is what covers transitive reachability.** A
module's check can read facts about a module it does not import: an inferred scheme may name `A.T`
through `B` (`checker.md` §7's first `type_refs` consequence), and `Types.find` then resolves that
name against `A`'s whole declaration list. So a key over direct imports alone would not be enough —
and a key over the transitive closure of type-reachability would have to compute that closure, which
is the thing nobody can compute before checking. The digest folds each direct import's
`(interface hash, digest)` into its own bytes, so one level of import terms carries every level of
reachability, exactly as the persistent cache's key is inductive over sources. *Rejected: an explicit reachability
closure — it is the same answer computed twice, and the second computation is the one that can be
wrong.*

**Two facts are demonstrated, not argued, and either one is a wrong program without the digest**
*(both measured; fixtures in `plans/m4-3.md` §7)*. A private type whose constructor payload becomes
a function stops being `equatable`; the declaring module still checks clean and **its interface hash
is byte-identical**, while an importer that compares two of its values goes from exit 0 to
`not_equatable`. And a `pub type alias` whose body no module of its own mentions has its expansion
nowhere in the record; renaming a field of it leaves the declaring module's hash byte-identical and
turns an importer's clean build into `missing_field`. An interface-hash-only firewall answers exit 0
to both, which is the one failure mode `checker.md` §7 says a compiler may not have.

*Amended 2026-09-27, for the new checker only (the only one since v1 was deleted).* Under `--checker=v2` the first fact's
hash is no longer byte-identical: a private type a `pub` scheme reaches has a `hidden_types` row in
the record with its derived `eq` and `compare` (`checker-v2.md` §14.2 *as amended 2026-09-26*), and
those rows go from `present` to `function`. The digest still moves as well, and the importer is
re-checked either way; the second fact (the alias no scheme mentions) is unchanged under both
checkers. `checker-v2.md` §14.3 lists every such difference.

**`TypeId` values are not a dependency, and that is why a private type is free.** A `TypeId` is a
whole-program dense index, so adding a private type anywhere renumbers most of the table — but
nothing a dependent emits or reports carries one: the record spends `app`/`alias` on `type_refs`
(§8.1's 2026-09-18 correction), the dispatch sidecar spends `Shape.nominal` on a name, the derived
tables sort by emitted name TEXT, and `Exhaustive` compares ids without printing them. What a
dependent observes is the `Types.Entry` FIELDS an id indexes, and the digest carries those by NAME.
So `plans/m4-1.md` §6.1's row 5 is kept: a private type added to a leaf re-checks the leaf alone.

**The key can no longer be computed in one serial pre-pass, and the DAG walk is where it moves.** An
import's interface hash exists only once that import has been checked or loaded, so the persistent cache's serial
`cache_key` phase splits in two. The part with no import term — package, name, option string, source
hash, sibling hash — stays serial and keeps the `cache_key` row. The key itself is finished on the
DAG, in the worker that claimed the module, from the two arrays the driver publishes as each module
completes; the schedule already releases a module only when every import has finished
(`src/check/Check.zig:530-544`), so the value is a function of the graph and never of thread timing,
which is §10's rule. **The entry load moves with it**, onto the same worker, and re-interns through
the NON-mutating `InternPool.Global.find` rather than `getOrPut` — which is what makes a load on a
worker legal at all, since `Global` is thread-confined. A `find` miss is a cache MISS and recomputes,
never an `internal`: the rule degrades instead of trapping. *Measured: over the warm 100k corpus,
`core` and `tests/corpus/run`, at `--jobs=1` and `--jobs=8`, **24 281 strings were re-interned on
cross-process loads and 0 of them would have missed `find`** — every string a cache entry names is
one some module of this build already interned.* The serial `cache_load` pass therefore disappears
and its 5.89 ms becomes per-worker work.

**The enumeration is enforced by the compiler, not by the specification.** In a safe build every
cross-module accessor records `(read module, kind of fact)` into the reading module's own set, and a
module that took a cache-key decision must not read a fact whose kind is not on the list or whose
module its key does not cover; either is `internal`. It compiles away in ReleaseFast, exactly as
`Reach.requireLive` and `Rename.verify` do, and it is what turns an incomplete enumeration into a
test failure instead of a stale answer in the field. *Measured: the census build this step was
specified from put an atomic increment on every one of those accessors and cost **nothing** — 128–131
ms against 127–130 cold, 41 ms against 41 warm — so the safe-build version is affordable without
argument.*

**Acceptance is the incremental-determinism matrix of `plans/m4-plan.md` §4.5, made sharp.** For
each project of a fixed set and each module of it, an edit from a fixed list of classes is applied,
the project rebuilt warm, the edit reverted and the project rebuilt warm again; every stream and
every output file must be byte-identical to a cold build at each step, **and** the counters must show
the importer was skipped exactly when the enumeration says it may be — not merely that it was
skipped. Byte-identity alone would pass a cache that never hits. The classes and the harness are
`plans/m4-3.md` §8; a bounded subset joins `test-blackbox` and the full cross stays a documented
`bench/` command.

**The cache becomes the default in this step, and that is its last commit.** `--cache-dir` keeps its
meaning; with no flag the directory is `.beni-cache/` in the working directory, created on demand,
and `--no-cache` is the escape. It is the last commit behind the harness so that the flip is a
one-line revert, and it flips only once the safe-build self-check is green over the whole corpus at
both `--jobs` and the matrix is green over every edit class. `.gitignore` it: a cache is machine-local
by policy from the moment §8.3's zero-copy map lands, and is never committed. Deleting the directory
is always safe and is the documented remedy; there is no `beni clean` and no garbage collection
yet, both of which stay the daemon's with the size cap.

**What a one-shot process can be held to, and what it cannot.** §2's warm rows were written for a
**daemon** — no process start, sources already in memory — and the firewall cutoff runs in a one-shot process. Its floor
is measured: `beni version` costs **1.14 ms** amortized over 200 invocations, and a fully warm
`check` of the 100k corpus is **40 ms**, of which the front end is `read` 5.3 + `frontend_load` 15.6
and the rest is `cache_load`, `resolve`, `merge_interners`, `graph`, `types`, `enumerate` and the key
pass — every one of them O(project) and none of them removed by this step. So **< 15 ms for a body
edit is not reachable by a one-shot process and is not this step's to miss**; it needs
the incremental whole-program passes and `frontend_decode`, and the daemon. What the firewall cutoff *is* held to is the
**< 60 ms exported-signature row**, which a one-shot should meet for the first time, and the
**< 120 ms daemon-cold-start row**, which the front-end artifacts already meet. Stating which budget a step owns is
what keeps the other two from being quietly missed.

**Explicitly not in the firewall cutoff**, each pointing at its owner: the emit-side cutoff and any caching of
emitted bytes, `frontend_decode`'s 10 ms, and the whole-program passes — `types`, `graph`,
`merge_interners`, `eliminate` — with the pack file and §8.3's zero-copy load (the incremental whole-program passes); the `stat` fast
path, the daemon, the socket protocol, the memory ceiling, watching and cancellation (the daemon, its decisions
**PENDING**); garbage collection and a size cap (the daemon); the `Ast` an LSP will want (M5); the
declaration-level graph of §8.2 (only if these measurements demand it).

## 9. JavaScript backend

### 9.1 Dead code elimination — copy Elm's mechanism exactly

Every top-level binding becomes a node in one flat whole-program map keyed by module-qualified name,
carrying its own set of referenced globals — and that dependency set is **a byproduct of ordinary
lowering**, no separate free-variable pass, because the name-resolution tracker records each global
reference as it generates the node (03 §5.1, 05 §1.5). Emission is a visited-set DFS from `main` and
every exposed value, so anything unreachable is never even looked up and no tree-shaking pass exists.
This beats any JS bundler, which must *infer* side-effect-freedom heuristically (`sideEffects: false`,
`/*#__PURE__*/`) where Beni's type system *proves* purity — and Layer-2 incrementality and code
splitting reuse the same graph: build once, use three times.

### 9.2 Two IRs, not one

Lower the typed IR into a small JS-shaped `JsIr` ([`backend.md`](backend.md) §3) as part of existing
lowering, then run one print pass straight to a growable byte buffer. A deliberate departure from
esbuild's single-AST model, and the evidence is Elm's own source: its author tried emitting directly
to a byte builder, measured it "neutral for perf," and kept the intermediate IR because codegen needs
to pattern-match on generated structure to strip redundant IIFEs and closures (03 §3). esbuild can
skip the second IR only because its input and output are both JavaScript. Output assembly follows
esbuild's `Joiner`: accumulate `{data, offset}` pieces and a running length, then allocate **exactly
once** and blit (03 §3). Never concatenate.

### 9.3 Calling convention — no currying

**No automatic currying.** The delta from Elm, itemised because five documents and one source
comment cite these items by number:

1. **Every call is saturated.** A function of *n* parameters has an *n*-ary type, and types of
   different arity do not unify.
2. **Function types are n-ary**, spelled Roc-style `Int, Int -> Int`, because space is already type
   application.
3. **Partial application is Gleam's placeholder**, `f a _`.
4. **Application stays juxtaposition.**
5. **`>>` and `<<` are removed.**
6. **`|>` becomes a syntactic form**, inserting its left operand as the callee's **first** argument.
7. **A rest-of-block bind, `let x <- e`**, is the general sequencing form for any function taking its
   callback last (§3.2) — including a callee of arity one, `scope <- Task.scope`, the shape the form
   was generalised to reach.
8. **The standard library goes subject-first and function-last** (`List.map xs f`), as in Roc, Gleam
   and Elixir, so `|>` inserts at the first argument and `<-` reaches the last.

Evidence: research [06](research/06-currying.md) on Roc,
[14](research/14-direct-style/01-solution-space.md) on the bind. **Normative rules:
[`language.md`](language.md) §3, §6.5, §6.7, §8, §9**; emission consequence
[`backend.md`](backend.md) §6. What follows is the decision record.

**The speed argument.** The rejected alternative is Elm's curried A2/F2 adapter: an arity tag `.a`
plus the raw n-ary `.f`, a saturated call site emitting `A2(f, x, y)`, which checks `f.a === 2` and
calls `f.f(x, y)`, falling back to `f(x)(y)` (03 §5.2). Around 80% of ML-family calls are saturated
so the fast path dominates, and PureScript's measured cost of *not* doing this is 25–35% runtime and
20–25% bundle size — but the adapter is not free either: rewriting `A2(f,a,b)` to direct `f.f(a,b)`
measured **+49% on Chrome and +109% on Firefox** (03 §5.2). Gleam's answer — partial application an
error unless explicitly requested, so every saturated call is a plain JS call with no adapter at all
(03 §5.2) — is the one taken: uncurried there is no adapter, no arity tag and no saturated-call
specialiser, so that cost is neither paid nor planned around.

**This reverses an earlier decision to keep currying**, which rested on one condition — that a curried
checker could match Roc's `TOO FEW ARGS` diagnostic — discharged by a 37/38 fixture score. That score
holds for the *direct* case and `too_many_args` but not the *displaced* case: a one-argument lambda
passed to `List.foldl` is not an error at the lambda, because `\x -> x` unifies with `a -> b -> b`
by making the accumulator a function, so the failure surfaces two arguments later
(`tests/corpus/check/args/FoldlLambdaTooFewParams`); the one admitted failure (`ComposeMissingArg`)
is the same class. Uncurried the class does not exist — a 1-ary and a 2-ary type do not unify. That,
Roc's documented rationale (06 §2) and three years of Roc's Zulip finding no regret (06 §5) decided
it.

**What it costs.** `_` recovers partial application and nested partials, and also covers leaving a
*first* argument open, which currying cannot; `|>` becomes syntax, as in Roc 2019–2024, and a
pipeline reads identically; the applicative constructor pipeline is replaced by the rest-of-block
bind, which Gleam's decoder library adopted after living without currying. **Point-free composition
(`List.map f >> List.sum`) is the one genuine loss**; name the argument. The standard library's
argument order flips to subject-first — every signature; the `A2`/`F2` machinery and the
saturated-call specialiser leave the backend plan; the arity fixtures are re-cut. It is a breaking
change to every program written so far.

**Also decided**, normative in `language.md`: exactly one `_` per call, as Gleam, in argument position
only; `e |> f a b` rewrites to `f e a b`, while `<|` stays and carries the trailing-lambda idiom;
`( operator )` stays, so `(+)` is the 2-ary function, and sections still do not exist; `>>`/`<<` and
the precedence-9 `non_associative_chain` go; and the formatter adopts research 14's Elm finding that
a trailing `<|` followed by a lambda must not indent (14/elm §0.2). **Deferred, not adopted:** letting
`_` mark a non-final callback slot, `let x <- f a _ b` — cheap, but no combinator wants it yet.
**Diagnostics are a deliverable:** Gleam's record for the same "purely syntactic" feature is four
bespoke error paths, a formatter function, an LSP action and two shipped confusing-error bugs
(14/gleam-use §0.2, §4). **Open, deliberately:** whether `Task` is sequenced with this bind (research
14's option B) or with a call-site marker over typed effect sets (research 14 S2, and the synthesis
discussion's "typed effects as calls, platform as the only handler") is not decided here; see §3.2.

### 9.4 Representation, tuned for V8

Emission detail is [`backend.md`](backend.md) §4, §7 and §8; the choices and their speed reasons:

- **Records** → plain object literals with a canonical (sorted) key order, so every instance of a
  record type shares one hidden class (03 §5.3).
- **Constructors** → `{$: tag, a, b, ...}`, tag a small integer in release and a string in dev,
  zero-argument constructors bare integers. **Shape consistency is mandatory:** Elm's own `List`
  violates it (`Nil` is `{$:0}`, `Cons` is `{$:1,a,b}`) and padding them to match measured ~11% on
  Firefox, ~4% on Chrome (03 §5.3), so Beni pads every constructor of a type to a uniform shape.
- **Lists** → cons cells by default (they match pattern matching), but benchmark a 32-way persistent
  vector trie before committing; the cache-locality and deep-recursion failure modes are real
  (03 §5.6).
- **Tail calls** → direct self-recursion lowers to `label: while(true)` with parameter reassignment
  through temporaries. **Mandatory, not an optimisation**: no JS engine reliably provides TCO — V8
  shipped and reverted it, SpiderMonkey never shipped it (03 §5.5). Mutual recursion remains a real
  stack frame; flag it as a known limitation and revisit with a trampoline.
- **Pattern matching** → decision trees (Scott & Ramsey heuristics) compiled to native `switch`,
  single-use branches inlined and multi-use branches shared via labelled loops (03 §5.4).
- **Primitive peephole** → recognise core arithmetic/comparison calls at *print* time and emit native
  operators, keeping the optimiser generic while avoiding a megamorphic dispatch point on the hottest
  call sites in the program (03 §5.7).

### 9.5 Output format and minification

**`beni build` produces deployable JavaScript on its own: no external bundler, no external
minifier.** This reverses an earlier split that handed local-variable mangling and peephole
compression to Terser or esbuild. A toolchain the user has to assemble is not the product, and the
handoff was the one place where the purity proof had to be re-explained to a tool that could not
verify it. Evidence for every row below is in report 12; report 03 for the ESM row.

| Decision | Why |
|---|---|
| **Emit ESM**, never Elm's IIFE | an IIFE is opaque, so no dev server can compute which modules an edit affects (03 §6). Unchangeable later without breaking every consumer |
| **Own minification** | Terser's `--mangle` leaves ESM top-level names alone and Closure never supported ESM as an emitter needs it, so choosing ESM and owning minification are the same decision (12 §7.5) |
| **js_of_ocaml is the model, not Closure** | ~3,450 lines, minified by default, no external minifier in its graph. Closure ADVANCED measured 12% *larger* in brotli than Terser at 50× the wall time, is 180,000 lines, runs at 0.06 MB/s against §2's budget, and has no ES-module support |
| **Measure after compression, always** | brotli primary, gzip secondary, raw as a diagnostic only. Raw counts *invert* the ranking: renaming saved 12,269 more raw bytes than a compression pass and still finished 1,334 bytes larger after gzip, and reordering declarations swung compressed size 18% at constant raw size |
| **The model is entropy, not length** | fewer distinct identifiers means cheaper Huffman codes, a whole-stream property with no window dependence. So whole-program naming consistency pays under gzip as well as brotli, and the sliding-window folklore is not the argument |
| **Two build modes, one graph** | `beni build` is dev: one ESM file per source module, no elimination, string constructor tags, maps on, and it is what §2's 15 ms warm budget is measured against. `--release` is chunks, exact elimination, integer tags, whole-program renaming and field ambiguation, maps off |

**Build, ranked by compressed bytes** (12 §5.1): local and top-level identifier renaming; property and
field renaming, including **type-directed field ambiguation**, where fields that never co-occur on a
type share one short name — it lowers the distinct-symbol count rather than merely shortening it, and
it needs exactly what the checker already built, so Elm cannot have it; exact dead-code elimination
(§9.1); compact printing. **Do not build** — all measured approximately zero or negative after
compression: `booleans` (`true` → `!0` makes brotli output *larger*), `if_return`, `collapse_vars`,
`inline`, `evaluate`, `reduce_vars`, `sequences`, `comparisons`, `switches`, `typeofs`.

#### Code splitting

Designed in now rather than retrofitted: Elm has no chunking concept and adding one means reworking
its emission core. **The mechanism — entry-set colouring, hash-consed colours, the
compression-budgeted merge pass and the synthesised cross-chunk bindings — is
[`backend.md`](backend.md) §10**, on report 12's evidence. Two decisions sit here rather than there.
**Opt-in per program, release only:** entry points are `main` plus every `lazy` declaration, so a
program with no `lazy` emits exactly one file, split where its author said to split it and never
because it got large. **Per declaration rather than a coarser unit**, because that granularity is
proven in four whole-program compilers and Closure's four safety guards for it are vacuous in a pure
language.

#### The `lazy` marker

- **On a top-level declaration, never a file, a local or an import.** Files are not output units in
  release mode; a `let` binding is not a node in the declaration graph; and consumer-side marking,
  where Dart and PureScript's proposal put it, would make a module's interface differ per importer,
  which is what §8.1's firewall rests on. Producer-side also matches `pub`.
- **It rewrites the declaration's type at the boundary**, `pub lazy adminDashboard : Model -> Html
  Msg` seen by importers as `Task LoadError (Model -> Html Msg)`. Every shipped trigger changes a
  type at the boundary — Dart a `Future`, Scala.js a `Promise`, TC39's `import defer` existing
  because that "forces all functions and their callers into an asynchronous programming model" — and
  in a language whose effects are already values (§3.1) a value arriving through a `Task` colours
  nothing not already coloured, so the cost that dominates this feature elsewhere is already paid.
  Leptos ships `#[lazy]` exactly; first-class `LazyRef a` values were rejected as the one candidate
  with no working precedent anywhere.
- **An entry point, not a chunk:** its chunk is everything reachable from it that no other entry
  point needs, so marking one function moves its whole private subtree. A private declaration may be
  `lazy` — what one large helper behind one route wants.
- **Anything reachable from a pure position goes in the main chunk** (dart2js's rule), so `view`
  cannot await; the type rewrite makes that a type error rather than a dedicated check.

> **Open.** That rewritten type names `Task`, which `transparent-effects-proposal.md` removes.
> Whatever replaces `Task` replaces it here.

**What chunking will not buy.** On the bundle report 12 measured, 90% of bytes are runtime plus
library, which no chunker can split. It is a large-application feature, not a size strategy.

**The counter-evidence is real, so the decision carries an exit.** Scala.js built the type-aware half
of this and still expects a downstream generic minifier; going without measured 1.58× in brotli. It
never built the generic half at all, which is why that does not sink the plan — but own minification
has to land within about 10% of beni's own output piped through esbuild `--minify`, and if it
approaches 1.58× the no-external-minifier decision is revisited. The size target is Elm's TodoMVC,
and the number that counts is the compressed one: 122 KB raw, 24 KB minified, **9 KB gzipped**.

### 9.6 Source maps

Fused into the print pass (`addMapping` at each emit site, no second traversal), delta-encoded VLQ
with a 64-byte lookup table and a single-sextet fast path, per-file chunks rebased once at join time —
all esbuild's techniques (03 §4). **Off by default**, since maps can be 3× the size of the output.
But position tracking must exist in the IR *from the start* even while maps are off: retrofitting it
means touching every pass, not just the printer, and Elm never threaded positions through codegen and
consequently has no source maps at all (03 §4).

## 10. Parallelism — and where not to use it

**Parallelise:** lexing, parsing and BIR lowering (per file, no cross-file knowledge); per-module
interface extraction; codegen per declaration as a bounded producer/consumer pipeline behind the
checker (Zig budgets in-flight bytes rather than a task per function, 01 §8).

*As built (2026-09-29):* codegen is parallel per MODULE, not per declaration, and behind the
checker rather than overlapped with it: `Emit` runs reachability's edge lists, lowering,
printing and the writes on one pool of threads, each module into a slot of its own, with every
name a lowering invents kept in a per-module overlay on the interner (`backend.md` §9, *How the
whole-program table is filled*). Resolution runs on the checker's DAG schedule (`checker.md`
§4, item 5). On the generated 100k-line corpus at `--jobs=8`, a `--library` build went from
about 69 ms to 50 ms (emit 27 → 10 ms) and a warm `check` from 23 to 19 ms, with the output
byte-identical at every `--jobs` and single-thread instructions +0.3 % (`--release` +1.8 %, a
second walk that lists each module's whole-program names).

**Do not parallelise:** the warm single-edit path — at a 15ms budget, thread-pool wake-up and
synchronisation can exceed the work, exactly what rustc measured where `-Z threads=8` *regressed*
small inputs (04 §5). Nor the type checker's core: Zig's multi-year, still-incomplete InternPool
thread-safety migration initially made things *slower* (01 §5, §8). Module-DAG parallelism captures
nearly all the available win at a fraction of the risk.

**Determinism is a requirement, not an aspiration.** rustc's project goals call its parallel
frontend's non-determinism "fundamental," and `codegen-units > 1` still produces non-reproducible
binaries because merge order follows thread timing (04 §5). Rules: stable input-derived ids assigned
*before* parallel work starts (module index by sorted path, never completion order); results re-keyed
by that id before merging; global tables append-then-sort; two-run output diffing in CI.

## 11. What we are deliberately not doing

| Not doing | Why |
|---|---|
| Salsa/query-based incremental engine | rustc's own docs blame fingerprinting for incremental losing to clean builds; 2–4× memory blowups; the macro-free design removes the motivation (04 §6a) |
| SIMD lexing (initially) | Real but second-order (~30–50%); a switch-based scalar lexer is within ~2× of the ceiling, and per-ISA intrinsics cost far more than the remaining gap until everything else is tight (04 §1) |
| Parallel unification | Modest ceiling, real determinism risk, and Zig's own attempt regressed before it improved (01 §5) |
| A general serialization library | Zero-copy mmap of our own flat arrays is simpler than adopting a schema framework for a format only we read (04 §7) |
| Reimplementing Terser | Do only what whole-program knowledge uniquely enables; hand off the rest (03 §6) |
| Perceus / RC-with-reuse | Native-memory techniques from Roc; JS output runs under V8's GC, so the entire class is inapplicable (05 §5) |
| Content-addressed code (Unison-style) | Eliminates invalidation structurally, but is a whole-system commitment that gives up ordinary git/diff tooling (04 §6c) |

## 12. Measurement discipline

Built before the optimiser, not after.

- **`--self-profile`** emitting Chrome-trace JSON per phase and per analysis unit. Clang's
  `-ftime-trace` and rustc's `-Z self-profile` are the models; rustc's captures query cache
  hits/misses, not just phase time (04 §10).
- **A permanent pathological corpus.** Every real slow file ever encountered is frozen into the
  benchmark set forever, exactly how rustc-perf grew (`token-stream-stress`, `tuple-stress`)
  (04 §10).
- **The §2 budget tracked per-PR as a visible trend, not a hard gate.** rustc deliberately doesn't
  gate — some regressions are correct trade-offs — but the number is on every PR, which makes
  regressions conscious rather than accidental.
- **Determinism test:** two full builds, byte-diff the output.

## 13. Build order

The order below is itself a design decision. M4's incrementality is the single largest win (63ms vs
seconds) but the one that needs the data model from M0–M3 to be right first — Zig's own experience is
that the wrong order costs a 30,000-line refactor (01 §7).

1. **M0 — Skeleton.** Token SoA, arena infrastructure, intern pool, `--self-profile`, the benchmark
   harness and the determinism test.
2. **M1 — Front end.** Lexer, LL(k) parser with error recovery and a lossless CST, BIR lowering, and
   the formatter. Parallel per file. Detail in [`frontend.md`](frontend.md) §8.
3. **M2 — Checker.** Packages, module graph, interfaces and cross-module resolution; the type store,
   constrain/solve and the ad-hoc obligations; exhaustiveness and DAG-parallel checking. Contract in
   [`checker.md`](checker.md).
4. **M3 — Backend.** Decl graph, reachability DCE, JsIr, printer, direct n-ary calls everywhere
   (§9.3: no currying, so no `A2`/`F2` adapter and no specialiser), TCO loops, decision trees, ESM
   output.

   **Static dispatch landed inside M3**, between M3a and M3b, rather than as a milestone of its own
   (§3.1, *Reversed on 2026-09-18*). It reaches every phase — parser, BIR, checker, interface,
   backend and `core/` — and [`static-dispatch-spike.md`](static-dispatch-spike.md) is its build
   order as well as its contract. **It moved M3c's reachability elimination from an optimisation to
   a prerequisite**: derivation is eager, so every declared nominal type ships an `eq` and a
   `compare` whether or not anything calls them, and report 19 §5 counts 216 942 bytes of derived
   code across 61 programs, mostly dead. Every output-size figure taken before DCE exists is an
   upper bound.
5. **M4 — Daemon + incrementality.** Socket protocol, content-hash cache, mmap artifacts, interface
   firewall, then the declaration-level graph.
6. **M5 — Polish.** Source maps, code splitting, LSP, field-name shortening. No minifier handoff:
   §9.5 reversed that split and beni owns minification.

## 14. Open questions

1. ~~**Currying vs. Gleam-style explicit partial application**~~ — **resolved, and reversed once:**
   kept on the strength of the missing-argument suite, then dropped when the suite was found to
   cover only the direct case. See §9.3.
2. **List representation** — cons cells vs. persistent vector trie (§9.4). Benchmark against real
   idiomatic code; the answer is workload-dependent and PureScript's experience shows intuition is
   unreliable here. *Decided 2026-10-01 by the owner, after research 38 and 46 measured both on
   beni's own output:* one array-backed `List` — a plain array until written, a 32-way trie with a
   claimable tail after — and no cons list (`backend.md` §4, *Lists are arrays*; `language.md` §6.8).
3. **How fine is too fine for Layer 2?** Zig found `AnalUnit` granularity needed a major refactor to
   avoid over-analysis when a type doubles as a namespace (01 §7). Start at the four kinds in §8.2
   and resist adding more without a measurement that demands it.
4. **Does BIR need to be separate from the resolved IR at all**, given that Beni has no `comptime`
   and a much simpler semantic model than Zig? The caching argument says yes; the complexity argument
   says measure it before committing. *Corrected 2026-09-18: the question's premise is overtaken by
   what landed. There is no separate resolved IR — `Resolve.rewriteReferences` mutates the `Bir`
   **in place**, turning every `import_value`/`qualified`/`type_import` instruction into
   `ext_value`/`top`/`ext_type` (`src/resolve/Resolve.zig:221-238`; `src/Artifacts.zig:121-127` exists
   for it). So one array holds two states: pre-resolve, which is the per-file pure form §6 describes
   and the one a cache may hold, and post-resolve, which carries `Graph.Index` and interface indices.
   The live question is therefore not whether to split them but that a cache must write the
   pre-resolve form and re-run resolution on load — 3.05 ms across 634 modules, ~5 µs each
   (`plans/m4-plan.md` §2.3). Note also that lowering takes `Lower.Options{core, platform,
   module_name}` (`src/bir/Lower.zig:149-162`), so "a function of one file's text" is really a
   function of that plus the package privilege bits and the module name.*
5. **Mutual-recursion stack safety** (§9.4). Trampolining costs the common case; leaving it unfixed
   is a real cliff for idiomatic ML code. Defer, but don't forget.
