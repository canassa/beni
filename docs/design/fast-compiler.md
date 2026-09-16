# Beni: design for an extremely fast Elm-like → JavaScript compiler

**Host language:** Zig. **Target:** JavaScript (ESM). **Source language:** Elm-like — ML family,
full Hindley-Milner inference, ADTs, records, modules; no typeclasses, no macros, no type-level
computation.

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
- **No typeclasses, no dictionary passing, no static dispatch.** Settled — §3.1, reports 09 and 10.
  Dictionaries cost runtime and bundle size, the effective fix is global, and whole-program
  specialisation is the one phase nobody has made cheap to cache. *Not* the `RowList` incident, a
  parser bug.
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
   does not compile; use `String.compare`.
4. **Ordering is passed explicitly.** `List.sortBy`, `List.sortWith`, and `Dict`/`Set` keyed by a
   concrete type (`Dict.String`, `Dict.Int`) as sugar over a comparator-taking core.
5. **`==` stays fully polymorphic, but its check leaves the unifier.** "This type must be equatable"
   is an obligation discharged *after* solving, when the type is concrete — same principle as the
   occurs check: don't make the check faster, make it rare. It also turns Elm's last runtime crash,
   `==` on functions, into a compile error, as Roc does, function equality being undecidable.

### Why, and what it costs

The unifier does one thing, with no recursive membership walk and no occurs check
on its hot path — §7's premise intact. The price is ergonomic and real: `List.sort` becomes
`List.sortBy identity`, tuple-keyed dictionaries need a comparator, some ordering code gets longer.
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
one field less than Elm's `{$: '#2', a, b}`. With `comparable` gone (§3.1) a tuple-keyed `Dict` takes
an explicit comparator — the intended consequence. **Positional access `.0`/`.1`, zero-based,
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
*namespacing*; **Go's capitalisation rule**, unavailable because case is spoken for — in ML syntax
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
   unreliable here.
3. **How fine is too fine for Layer 2?** Zig found `AnalUnit` granularity needed a major refactor to
   avoid over-analysis when a type doubles as a namespace (01 §7). Start at the four kinds in §8.2
   and resist adding more without a measurement that demands it.
4. **Does BIR need to be separate from the resolved IR at all**, given that Beni has no `comptime`
   and a much simpler semantic model than Zig? The caching argument says yes; the complexity argument
   says measure it before committing.
5. **Mutual-recursion stack safety** (§9.4). Trampolining costs the common case; leaving it unfixed
   is a real cliff for idiomatic ML code. Defer, but don't forget.
