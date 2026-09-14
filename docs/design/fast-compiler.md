# Beni: design for an extremely fast Elm-like → JavaScript compiler

**Status:** implemented through M3a (see §13 for where each milestone stands). The design below
is the one the code follows; where a milestone proved part of it wrong, the correction is written
here and the commit that found it says so.
**Host language:** Zig.
**Target:** JavaScript (ESM).
**Source language:** Elm-like — ML family, full Hindley-Milner inference, ADTs, records,
modules; no typeclasses, no macros, no type-level computation.

**Stance: Elm's walled garden, better equipped.** The wall stays and is not up for negotiation:
user code does not reach arbitrary JavaScript, effects cross a controlled boundary, matches are
exhaustive, there is no null, and well-typed code does not throw at runtime. What was wrong with
Elm was never the wall. It was how sparsely the garden inside it was furnished — no exact 32-bit
arithmetic, no code splitting, no source maps, a deliberately small standard library, and a
privileged kernel only the core team could extend, so the garden grew only as fast as one person
planted it.

So the question a proposed capability faces is not "can user code reach this" — the answer to that
stays no. It is: **what would it take to offer this inside the wall, typed so that well-typed code
still cannot crash?** Exact 32-bit arithmetic needed a type, not a hole (§3.3). Code splitting
needed a declaration marker and an effect type (§9.5). Both are now in, and neither cost a
guarantee. The interesting cases are the ones where the answer turns out to be a *platform*
capability rather than a language one, and that is why the JavaScript-boundary contract is written
before M3 rather than discovered during it.

This is what "opinionated but powerful" means here. Opinionated is the guarantee list, which is
short and fixed. Powerful is refusing to accept that a guarantee must also mean an impoverished
language — which is the inference Elm drew and we do not.

## 1. The thesis

Compilers in this family are not slow because of clever algorithms done badly. They are slow for
three reasons, and each has a known fix:

1. **Process and phase overhead dominates small edits.** A fresh process costs tens of
   milliseconds on dynamic linking and runtime init before a single byte is lexed (04 §8). At a
   100ms budget that is most of the budget. *Fix: a daemon.*
2. **Pointer-chasing, per-node allocation and string comparison tax every phase.** oxc measured
   ~20% from arena allocation alone; Carbon measured 5–12% lex / 4.5% parse / 1–2% total check
   from packing tokens to 8 bytes; Zig measured −17.5% wall time from refining one intern pool
   (01 §5, 04 §1). Elm pays a byte-array comparison on *every* identifier lookup through the
   entire back half of its pipeline because `Name` is never interned (05 §2). *Fix: flat SoA IRs,
   u32 indices, arenas, intern once at lex time.*
3. **Invalidation is coarser than the edit.** Elm re-checks whole modules; declaration-level
   output granularity did not buy it declaration-level *compilation* granularity (03 §7, 05 §3).
   Zig, tracking a declaration's type separately from its value, re-analyses a single-file edit in
   a 500k-line project in **63ms** (01 §7). *Fix: a fine-grained dependency graph plus a
   module-interface firewall.*

The fourth reason is the one you get for free: **the language itself.** Feature surface costs
compile time, and the clearest statement of it comes from Gleam, which rejects typeclasses because
they "have a high compile time cost, and have a runtime cost unless the compiler performs
full-program compilation and expensive monomorphisation" (09 §3). PureScript's creator declined to
build that monomorphisation into the standard compiler for the same structural reason — "being
global, it doesn't always play nicely with separate compilation" — and the separate optimizer that
does it is explicitly non-incremental while recovering 25–35% runtime and 20–25% bundle size
(09 §2). Beni stays scope-limited on those grounds, and that is a language-design commitment, not an
implementation detail.

Two claims this document previously made here do **not** survive checking, and are corrected in
09 §2: PureScript's `RowList` blowup was root-caused to its *parser*, not dictionary resolution, and
the widely repeated "476 million dictionary comparisons" figure could not be sourced at all. Nor is
there evidence that *Elm's* speed comes from lacking typeclasses — Evan's own performance writing
credits parser allocation and GC. The argument above stands on the other languages' evidence, not
on Elm's.

## 2. Performance budget

Targets are per-operation, on a warm daemon, measured on a 100k-line project. These are the
numbers CI tracks (§12); missing them is a bug report, not a nice-to-have.

| Operation | Target | Evidence it's achievable |
|---|---|---|
| Cold full build, 100k LOC | **< 800ms** | Elm does ~120–130k lines/s full-compile in Haskell with no interning and mtime caching (02 §10) |
| Warm rebuild, one function body edited | **< 15ms** | Zig: 63ms for a 500k-line project with a much heavier type system (01 §7) |
| Warm rebuild, one exported signature changed | **< 60ms** | bounded by the transitive re-check the interface firewall permits |
| Warm rebuild, one dependency-free module added | **< 25ms** | one parse + one check + one emit |
| Daemon cold start (mmap cache hit) | **< 120ms** | zero-parse mmap load of cached artifacts (04 §7) |
| Type checking throughput (cold, per core) | **> 250k LOC/s** | HM with levels is near-linear; Elm reaches ~130k LOC/s for the *whole* pipeline in GHC |
| Emit throughput | **> 5 MB/s of JS** | esbuild prints+sourcemaps 547k lines in 390ms including parse and link (03 §1) |

Two non-goals, stated so they don't creep in: Beni does not aim to beat esbuild at bundling
third-party JavaScript, and it does not aim for sub-millisecond *cold* starts. It aims for edits
that feel instantaneous inside a running session.

**These targets are Elm-shaped, not Roc-shaped, and the difference is one phase.** Roc caches
checking and not specialisation, and its measured times split exactly along that line: `roc check`
does 58k lines in **0.78s**, while an `--opt=dev` build of 55k lines takes **16.9s** — about 3,400
lines/s against Elm's ~120–130k for its whole pipeline (10). We are aiming at the first profile, and
the reason it is reachable is that there is no specialisation phase to pay for.

## 3. Language constraints that exist for compiler speed

These are decisions about the *source language*, made now because they cannot be retrofitted.

- **LL(k), no backtracking.** The grammar must be parseable with constant lookahead and committed
  choice. This is Zig's stated parser invariant (01 §9) and Elm's practical one (its combinators
  are committed-choice: a failure after consuming input is final, 05 §1.3). It guarantees linear
  parse time and rules out a whole class of pathological inputs.
- **No typeclasses, no dictionary passing, and no static dispatch.** Settled — see §3.1 and
  reports 09 and 10. Dictionaries cost runtime and bundle size, and the effective fix is global;
  whole-program specialisation is the one phase nobody has made cheap to cache. *Not* because of the
  `RowList` incident, which was a parser bug.
- **No type-level computation, no row-polymorphic type functions.** Records get plain extensible
  rows with structural unification, nothing more.
- **No macros.** This is what lets a simple module-interface firewall work instead of a
  salsa-style query engine — matklad's own stated reason for needing fine-grained tracking in
  rust-analyzer was macro-induced non-laziness (04 §6a).
- **Explicit imports, no wildcards.** Makes per-module name resolution parallelisable without a
  global pre-pass. Roc's FAQ gives exactly this as its *primary* reason: "Module name resolution
  can be parallelized because errors are detectable within individual modules. Wildcard imports
  would break this parallelization, requiring all modules to be processed before knowing which
  names are exposed." Readability is listed as the minor reason.
- **Tabs are a syntax error; indentation rules are lexically decidable.** No layout pre-pass.
- **Currying stays** (it's an Elm-like language) — but see §9.3, this is the one place the
  decision is genuinely contested and it must be settled before codegen exists.

## 3.1 Ad-hoc polymorphism: `number` yes, `comparable` no

**The problem.** Without typeclasses, `+` still has to work on `Int` and `Float`, and something has
to order the keys of a `Dict`. Elm's answer is four magic type variables — `number`, `comparable`,
`appendable`, `compappend` — each meaning "one of a fixed set of types."

**Why it isn't free.** A unifier asks one question: *are these two types the same?* These variables
add a second: *is this type in the allowed set?* For `number` that's one comparison. For
`comparable` the set is defined recursively — a list of comparables is comparable, a tuple of
comparables is comparable — so answering it means walking the whole type, and because types can be
cyclic, each walk needs a loop guard. That guard is the **only** place Elm runs an O(term size)
check inside unification; everywhere else it is batched to once per let-bound name (02 §3). The
source carries the author's own doubt about it: `-- TODO: is there some way to avoid doing this?
Do type classes require occurs checks?` (`references/elm/compiler/src/Type/Unify.hs:421-422`).

Reading which branches actually pay is what decides this. In `unifyFlexSuperStructure`
(`Unify.hs:370-414`), `Number` and `Appendable` resolve with a name comparison or a plain merge;
only `Comparable` and `CompAppend` call `comparableOccursCheck` and then recurse per element. The
cost is not "constrained type variables" as a category — it is `comparable` specifically. It is
also the feature that forces a generic runtime comparator in the emitted JS (`_Utils_cmp`), the
megamorphic dispatch point V8 cannot inline through (03 §5.7). It taxes both sides.

### Decision

1. **Keep `number`.** `+`, `-`, `*` on `Int` and `Float`. Flat membership test, free.
2. **Keep `appendable`.** `++` on `String` and `List`. Also free — its branch is a plain merge.
3. **Drop `comparable` and `compappend`.** `<`, `>`, `<=`, `>=` are **numbers-only**. `"a" < "b"`
   does not compile; use `String.compare`.
4. **Ordering is passed explicitly.** `List.sortBy`, `List.sortWith`, and `Dict`/`Set` keyed by a
   concrete type (`Dict.String`, `Dict.Int`) as sugar over a comparator-taking core.
5. **`==` stays fully polymorphic, but its check leaves the unifier.** "This type must be
   equatable" is collected as an obligation during constraint generation and discharged *after*
   solving, when the type is concrete. Same principle as the occurs check: don't make the check
   faster, make it rare. This also turns Elm's last runtime crash — `==` on functions — into a
   compile error, which Elm's own roadmap wants and has never shipped.

   Roc already does this and its FAQ gives the reasoning we'd otherwise have to derive: function
   equality is undecidable in general (halting problem), and every fallback is worse — source
   equality makes refactoring `|x| x + 1` into `|x| 1 + x` a breaking change at a distance,
   reference equality contradicts the rest of the design, always-`False` and always-`True` both
   make functions unsafe to store in records or collections. Rejecting it at compile time removes
   the whole class.

### Why, and what it costs

The unifier ends up doing exactly one thing, with no recursive membership walk and no occurs check
anywhere on its hot path. That is the §7 premise intact rather than punctured.

The price is ergonomic and real: `List.sort` becomes `List.sortBy identity`, dictionaries with
tuple keys need a comparator, and some ordering code gets longer. Point 3 is the genuine departure
from Elm; 1, 2 and 5 are close to free wins.

**Roc reached the same place independently** (see [`research/07-roc-static-dispatch.md`](research/07-roc-static-dispatch.md)).
It has no `comparable`, ships no generic `sort` — `List.sort_with` takes an explicit comparator —
and deliberately keeps comparison operators numeric, on the grounds that `string1 < string2`
silently compiling is a footgun. Its uniform mechanism (methods named on types, resolved by static
dispatch) is *not* copyable here: what makes it cheap at runtime is monomorphisation, and the
non-specialising path it offers instead passes hidden dictionaries at runtime — the thing §3 rules
out — and is marked experimental in Roc's own docs.

### Revisited after the survey (09)

A three-language survey was run to test whether this exclusion was reasoned or inherited. It stands,
with two changes to the reasoning:

- **Elm's omission was deliberate deferral, not neglect** — Evan chose SML-style operator
  overloading in 2012 *"because it can be gracefully upgraded to work with type classes"*, and the
  four `SuperType`s form a real subsumption lattice, not a stopgap. But he never argued it on
  compile-speed grounds, and Elm's own performance writing credits parser allocation and GC. That
  justification was ours, wrongly attributed.
- **"You must do whole-program work" is too strong.** GHC's `SPECIALIZE` propagates dictionary
  elimination through per-module `.hi` interface files, and F#/Fable's SRTP resolves member
  constraints per call site on `inline` functions — both shipped, both compatible with separate
  compilation, both paying in code duplication rather than a global pass.

A follow-up survey (10) tested the obvious objection — Roc specialises the whole program and is
reputedly fast, so surely the two are compatible. The result sharpened the claim rather than
overturning it. Rust proves whole-program work *can* be made incremental, but pays for it with
256 codegen units instead of 16, explicitly worse codegen ("not recommended for release builds"),
cross-crate duplication of instantiations, and a labelled memory-blowup bug category — after a
decade of work its own maintainers still list it as open. Roc simply doesn't cache specialisation at
all: its `SpecializationCacheFile` format exists with zero call sites, and Feldman's own summary is
that "the most expensive parts of the compilation are in the backend... and they're also the most
challenging to cache — the specializations are the hard part."

So the defensible claim is narrower than "whole-program work is incompatible with incremental
builds": it is that **specialisation is the phase nobody has made cheap to cache**, and the two
projects that tried both say so.

### Decision: no static dispatch

**Settled. Beni has no typeclasses, no dictionary passing, and no static dispatch.** Ad-hoc
polymorphism is limited to `number` and `appendable` (above); ordering, equality on user types and
stringification are explicit.

What was ruled out, and on what evidence:

| Ruled out | Why |
|---|---|
| **Dictionary passing** | Runtime cost and bundle size. The effective fix is whole-program specialisation, and PureScript's creator declined to build it into the standard compiler because "being global, it doesn't always play nicely with separate compilation." Their separate optimizer recovers 25–35% runtime and 20–25% bundle size, and is explicitly non-incremental (09 §2). |
| **Whole-program specialisation** (Roc's model) | Specialisation is the one phase nobody has made cheap to cache. Roc caches checking but not mono; its `SpecializationCacheFile` has zero call sites. Measured: 0.78s to *check* 58k lines, 16.9s to *build* 55k — ~3,400 lines/s against Elm's ~120–130k for a whole pipeline. Feldman: "the specializations are the hard part" (10). |
| **JS prototype dispatch** (`x.method()`) | Free at runtime — the engine does it — but methods on prototypes defeat the precise whole-program tree-shaking §9.1 depends on. Rejected on output size, not compile time. |
| **Interface-propagated call-site specialisation** (GHC `SPECIALIZE`, F# SRTP) | The one incremental-compatible route, and genuinely viable — but it pays in code duplication, which is what §9 optimises hardest, and it would have to be opt-in per function. Putting a body into its interface file means body edits change the interface, which is exactly what §8.1 exists to prevent; GHC keeps the firewall intact only because `INLINABLE` is an explicit annotation. Not worth the language surface for what it buys. |

Two things this decision is **not** based on, both corrected in 09 §2: PureScript's `RowList` blowup
(a parser bug, not dictionaries) and the unsourceable "476 million dictionary comparisons" figure.
Nor is it based on Elm — Evan deferred typeclasses deliberately since 2012, but never argued it on
compile-speed grounds, and Elm's own performance writing credits parser allocation and GC.

The sourced version of the argument is Gleam's, which rejects typeclasses because they "have a high
compile time cost, and have a runtime cost unless the compiler performs full-program compilation and
expensive monomorphisation" — a modern language, compiling to JS among other targets, stating our
reasoning outright.

**What the survey establishes beyond this project:** across seven JS-targeting languages,
type-directed dispatch *with no value to dispatch on* always reduces to either a caller-threaded
dictionary or whole-program specialisation. There is no third option. Value-directed dispatch is
free everywhere because JS prototypes do it natively — that half never needed typeclasses (09 §3).

**If this is ever revisited**, the entry point is the last row of the table, and the reason the door
is not welded shut is that §3.1's mechanism is additive: `number` and `appendable` are a closed set
resolved post-solve, so adding opt-in call-site constraints later would change no existing type
representation and no part of the firewall. That is deliberately the shape Evan chose in 2012 —
"the current solution is best in my opinion until I add something better", picked *because* it
upgrades gracefully. It stayed upgradeable for thirteen years.

### Settled alongside it

Evidence for all four is in [`research/08-roc-language-answers.md`](research/08-roc-language-answers.md).

- **No user-defined infix operators.** Fixed set, fixed fixities. Arbitrary fixities force
  post-parse re-association (as in Haskell), which breaks §3's LL(k) guarantee. Roc reached the
  same answer for a different reason — Feldman: *"Elm used to have custom infix operators and
  removed them, and I think that decision was for the best in retrospect based on how they were
  used in practice."* Two independent arguments, same conclusion.
- **Module import cycles are forbidden**, detected during crawl. Allowing them collapses §10's DAG
  scheduling and §8.1's firewall into per-cycle units. Roc enforces this with a topological sort
  and justifies it purely on build times: cycles are *"a footgun for build times... you silently
  lose a huge amount of caching."*
- **Type aliases are transparent but interned, never expanded.** Elm expands them into every
  dependent's interface — measured bloat (elm/compiler#1453). Roc stores a compact alias node
  pointing at a shared backing type variable, avoiding that by construction. Copy Roc.
- **Shadowing is an error**, not a warning. Roc allows it with a permanent warning, but Feldman's
  own reasoning is an argument for banning: if shadowing is banned *"you can look at a local
  snippet of code, or a diff, and have stronger guarantees about what names mean."* Elm makes it an
  error; so do we.

- **Top-level annotations are optional**, as in Elm and Roc. A module's interface is therefore
  the *inferred* scheme of each `pub` declaration, not a lexical fact. The cost lands in §8.1:
  the interface hash can only be computed after checking, so an importer is re-checked whenever
  a dependency's inferred interface changes by value — Elm's `.elmi` comparison, Roc's
  content-hash chain. What stays lexical is the *set* of `pub` names, which is all per-module
  name resolution (§3) needs. The ergonomic alternative — requiring annotations on `pub`
  declarations — would have made interfaces free to compute; nobody has measured its cost, and
  matching the two languages this one is modelled on was judged worth more than the unmeasured
  win. Decided 2026-09-13, before M2.

- **Primitives: core is written in beni, embedded in the compiler, with `foreign`
  declarations for what cannot be.** Elm's Kernel modules and Roc's embedded builtin `.roc`
  files are the precedents. Most of core (`Maybe`, `Result`, `Bool`, `Order`, nearly all of
  `List` and `Dict`) is ordinary beni, so §9.1's DCE graph and §9.3's direct-call specialisation
  apply to the standard library — where most calls in real programs go — and core is tested
  through the same corpus and Node boundary as user code. Only arithmetic, string primitives and
  the list representation are `foreign name : Type`, bound by name to a sibling JavaScript file;
  `Int`, `Float`, `Char`, `String` and `List a` are `foreign type`, which keeps the list
  representation question (#2 below) out of the source until M3. `foreign` is legal only under
  the core root; user JavaScript is reached through the effects model, not through this. The
  alternative — signatures hardcoded in the compiler — parses nothing at startup but puts the
  standard library outside the language, untested by its own tools. The cold-start parse of core
  is under a millisecond per thousand lines at §2's targets and disappears under §8.3's cache.
  Syntax in [`language.md`](language.md) §5.4. Decided 2026-09-13, before M2.

- **Effects: a pure language, one function arrow, effects as values interpreted by a
  platform.** Elm's model, with Roc's name for the boundary. An effect is an ordinary value of
  an opaque core type (`foreign type`, §3.1 above); a *platform* is a JavaScript module shipped
  with the compiler, like core, that defines the type of `main` and the effect primitives — the
  browser platform is shaped like The Elm Architecture, and a Node one can follow without a
  language change. JavaScript interop is typed message passing at that boundary, as Elm's ports
  are, because that is what keeps the purity proof honest. The alternative — Roc's `->`/`=>` with
  effects in the types — composes effectful code more naturally but puts two function kinds and
  effect polymorphism into the unifier, exactly the surface §3 keeps small, and Roc's own docs
  list purity inference as a benefit no pass exploits. Consequences: §9.1's DCE is exact by
  construction; §7's unifier is unchanged; M2 gives `main` no special type — that is a platform
  fact checked in M3; the effect-marking syntax question in §3.2 closes as "none". Decided
  2026-09-13, before M2. **The platform interface, the shape of ports and the runtime are now
  specified** in [`boundary.md`](boundary.md), on report 13's evidence: ports stay and stay
  asynchronous, because across fourteen JavaScript-targeting compilers no shipped design lets user
  code call JavaScript and keep the no-crash guarantee — but the three restrictions Elm stacked on
  top of ports do not survive the evidence.

- **Project model for M2: one source root plus embedded core, no manifest; module identity is
  package-qualified from day one.** Internally a module is `(package, path)` — the user's project
  is one package, core is another, dependencies later are more — so M4 needs no retrofit when
  packages arrive; Elm's flat global namespace has to error when two packages define the same
  module, a friction its users know. Import syntax stays Elm's: `import Json.Decode` names a
  module, never a package; resolution looks in the importing package, then its dependencies; a
  name found in two dependencies is an error at the import site, fixed Zig's way by renaming one
  in the manifest. Everything a manifest answers — dependency names, versions, hashes, lockfiles
  — is M4, where the cache key has to hold exactly that information anyway. The one piece of M2
  built for M4 is the **interface record**: flat and index-based per §5, holding public names,
  types, constructors, opacity and inferred schemes; M2 compares it by value, M4 hashes and mmaps
  it unchanged. Decided 2026-09-13, before M2.

- **`Int` is a double; exact 32-bit work has its own type.** JavaScript has no integer type, so
  `Int` must be represented by something it does have, and every option costs something:

  | | Exact to | Cost per operation | Overflow |
  |---|---|---|---|
  | double | 9,007,199,254,740,991 | none, `+` is `+` | **silently inexact** |
  | 32-bit | 2,147,483,647 | a truncation on every result | wraps, defined |
  | BigInt | unbounded | boxed, ~an order of magnitude slower | never |

  BigInt is disqualified as a default: it would make the most common type in every program the
  slowest one. Between the other two, **double is the default**, as in Elm, which has shipped it for
  a decade without the ceiling being what bit people. Its failure mode is the worse one and that is
  stated rather than hidden — past 2⁵³ addition stops working and says nothing.

  What makes that acceptable is the escape hatch, and **bit operations alone are not one.** The work
  that needs 32-bit semantics — hashing, checksums, PRNGs, binary formats — needs wrapping
  *multiply*, which is the one operation that cannot be faked: a 32-bit product can exceed 2⁵³, so
  masking after multiplying returns confident garbage. Elm's own random and hashing libraries split
  each multiply into 16-bit halves by hand, which is the evidence that `Bitwise` is insufficient.

  So core ships an **opaque `Int32`** with its own total arithmetic — multiply to `Math.imul`, add
  and subtract to the truncating form, shifts and masks to the native operators — all free at
  runtime, since underneath it is an ordinary number (`toInt` is identity, `fromInt` truncates). A
  distinct type rather than Elm's module over plain `Int`, for the same reason `comparable` was
  dropped: if arithmetic wraps, the type says so, and the bug above becomes unreachable because `*`
  is not available on it. `Int64` over BigInt can follow the same shape when a binary format needs
  it; not now, but the convention should not have to be invented twice.

  Note the reframing, which came out of asking what the escape hatch is: with `Int32` available, the
  people most exposed to double's silent ceiling are exactly the people who should have been using
  `Int32` anyway. This is the stance's exemplar — a capability Elm lacks, added entirely inside the
  wall, total, with no hole cut anywhere. Decided 2026-09-13, before M3.

### Still open

Each is cheaper to take now than later:

| Decision | Why it is load-bearing | State of the evidence |
|---|---|---|
| String representation | Native JS strings are free but give O(n) indexing and a UTF-16/codepoint mismatch. Roc keeps `Str` deliberately minimal and pushes Unicode work to libraries — a stance available to us regardless of representation. |
| Sequence default: cons, vector trie, or flat array | A stdlib and literal-syntax decision, not only a representation one (open question #2) | Roc chose a **flat refcounted array**, explicitly rejecting persistent structures: *"flat data structures are much more cpu friendly than persistent ones."* It mutates in place when uniquely referenced and copies when shared, and pattern-matches with slice patterns rather than cons. That mechanism needs a refcount JS can't cheaply provide — but it argues against cons lists being the automatic choice. |

## 3.2 Surface syntax

Roc changed most of its syntax just before and during the Zig rewrite, and the reasoning is
recorded in [`research/08-roc-language-answers.md`](research/08-roc-language-answers.md). Two of
their findings are about *parsing cost*, which is our constraint too, so the decisions below are
taken now rather than discovered later.

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

**Whitespace application is ambiguous *without* indentation rules — not in general.** Roc moved
calls from `f a b` to `f(a, b)` after Joshua Warner produced token streams with two valid parses,
noting "with WSA you can continue on the next line with no symbol." But Roc is indentation-
*insensitive*; Elm keeps whitespace application and is fine precisely because it is not. So the
lesson is conditional, and it comes with a price we accept knowingly: **whitespace application
commits us to indentation-sensitivity.** §3 already requires indentation to be lexically decidable
with no layout pre-pass, and Elm shows the shape that works — thread the ambient indent through the
combinators (`Parse/Primitives.hs`'s `withIndent`), never a separate layout pass.

**`|x|` lambdas are not free when `|>` exists.** Anthony Bullard, opening #compiler development ›
"New lambda syntax / BinOp contention", 2025-01-15:

> "The new lambda syntax `|_| ...` has an issue. When parsing a term, we had to peek before trying
> to parse this to make sure we don't try to consume the `||` and `|>` operators as part of the
> lambda args."

That is lookahead introduced purely by a syntax choice. It produced fuzzer-caught bugs, and the same
class of ambiguity was still generating parse errors on `->`-plus-lambda in real user code as late
as 2026-02. We keep `|>`, so we keep `\x ->`.

### Error handling: `?`

`expr?` on a `Result` evaluates to the `Ok` payload, or returns the `Err` from the enclosing
function. `Result.andThen` chains remain — `?` is sugar for the common sequential case, not a
replacement.

Three rules, each chosen to keep the cost at zero:

1. **`?` returns from the nearest enclosing *named* function, and is a compile error inside a
   lambda.** This is the one real hazard, and Roc found it the hard way: their backpassing removal
   was driven by early returns landing in a function the reader wasn't looking at. In an Elm-like
   language lambdas are mostly `List.map (\x -> …)` arguments, where a silent early return from the
   lambda is almost never intended. Making the ambiguous case illegal is a scope check — free — and
   it stays reversible, since relaxing a restriction later is easy and tightening one is not.
2. **No implicit error conversion.** Rust's `?` applies `From::from` to the error, which needs a
   typeclass we don't have (§3). So the error type must match the enclosing function's error type
   exactly; otherwise you write `Result.mapErr` before the `?`. Stating this now avoids discovering
   it when the desugarer is already written.
3. **It desugars in the desugarer.** No new constraint kind, no unifier changes, nothing touching
   inference. Of every ergonomic feature considered here it is the only one that buys its keep
   entirely in the desugarer — which is exactly what §3's "minimal type-system surface area" premise
   makes affordable.

### Flat effect syntax — OPEN

**Nothing here is settled.** This section records what the evidence establishes and what the live
options are. Reports [15](research/15-flat-effect-syntax.md) and
[16](research/16-fibers-and-concurrency.md) are the evidence base; both are partial, and report 14 —
on whether Elm's ergonomics complaint is real at all — was never written, so the question "is this
worth fixing" is itself still open.

**What the evidence establishes.**

1. **Four languages invented the same mechanism independently**: OCaml's `let*`, Gleam's `use`,
   Koka's `with` and Roc's (removed) backpassing all reduce to one rewrite — *take the rest of the
   block, make it a lambda, pass it as the last argument to a named thing* — and **none consults a
   type class**. That matters because §3.1 rules out type classes, and this is the shape that is
   affordable without them. Gleam's author learned of the others only after designing his.
2. **`?` extended to `Task` is the most expensive shape, not the cheapest.** `?` is postfix on any
   application (`language.md` §3), so the continuation would have to be hoisted out of argument
   positions, conditions, scrutinees and pipelines. Roc shipped both shapes: backpassing desugared in
   44 lines; the arbitrary-position marker needed a dedicated 1,046-line pass and shipped with a
   compiler crash. **The expensive thing is not that the rewrite is non-local — it is that the marker
   may appear anywhere an expression may.**
3. **It would also introduce a silent wrong answer, verified in our own checker.** `?`'s shape is
   chosen by ordered speculative unification (`Solve.zig` tries `Result`, then `Maybe`), so
   `pub step a = let v = a? in Ok v` infers `Result e a -> Result e a` today with no diagnostic.
   `Task e a` would be a third two-parameter candidate and lose the same way, so a `?` meant for a
   task would silently type as a result. That is the failure class M2d existed to remove.
4. **Generators do something no syntactic rewrite can do**, and an earlier draft of this section was
   wrong to dismiss them as a workaround. `use`, `let*`, `with` and backpassing all capture *the rest
   of a block*; a generator suspends at an arbitrary point and keeps the rest of the whole function —
   inside a branch, inside a loop. Block-structured syntax cannot express a bind inside a loop at all;
   you reach for a fold instead.
5. **Effect-TS's cost is its fiber runtime, not its generators.** The same earlier draft claimed a
   generator "allocates an object and pays suspend and resume per bind". The generator object is **per
   call, not per bind**; per bind you pay a `next()`, a register spill and restore, and an iterator
   result object the engine may elide. Effect-TS's maintainers attribute their overhead to fibers —
   the interpreter loop, the effect nodes, the interruption checks — not to the generator layer.

**The live options**, in increasing order of compiler work:

| | Shape | Binds inside a branch | Binds inside a loop | Cost |
|---|---|---|---|---|
| A | Block-structured (`use`-style) | needs a nested block | **not expressible** | parser work; the desugaring is ~44 lines of precedent |
| B | Emit generators | yes | yes | one state object per call, plus the iterator protocol; opaque to §9.5's elimination and renaming |
| C | Emit a state machine ourselves | yes | yes | a real backend transform, the thing Rust and C# do for `async`; transparent to the optimiser |

B and C allocate the same per-call state object, so the gap between them is narrower than it looks:
the iterator protocol and control over layout, against a decade of engine optimisation obtained for
free. **Nobody has measured this for us, and it is measurable** — emit the same program both ways and
compare, which is what `bench` exists for.

**A second question is entangled with this one and has a different answer.** Effect-TS reads like
ordinary TypeScript partly because TypeScript *has statements*. beni is expression-based, so
`let … in` is the only sequencing construct: a run of binds is already flat inside one `let`, but a
branch is an expression, so a bind inside it nests whichever mechanism we choose. Making that read
flat is a **language** change (statement blocks), not a codegen one. The two questions — *can a bind
appear anywhere* and *does a sequence of binds read flat* — should be decided separately.

### `Maybe` stays

Roc has no `Maybe`, `Option`, `null` or `nil`. Failure uses `Try` with descriptive error tags, and
for genuine absence its FAQ argues a tag union says *why* rather than merely *that* —
`[Loading, Loaded(Artist)]` against `Maybe(Artist)` — adding `Errored(LoadingErr)` later needing no
refactor, while helpers like `Maybe.is_none` discourage exactly that evolution.

**The argument does not transfer, because Roc's tag unions are structural.**
`[Loading, Loaded(Artist)]` is a type you write inline, anywhere, with no declaration — which is
what makes "use a tag union instead" cheap there, and what makes the evolution argument work at
all: the type was never declared, so there is nothing to refactor.

Beni has **nominal** ADTs, like Elm. Dropping `Maybe` here means every `Dict.get`, `List.head` and
`String.toInt` either needs a bespoke declared type at each call site, or returns `Result () a` —
which is `Maybe` with extra ceremony. Sound reasoning in their language; inverted in ours.

Adding structural tag unions to recover it would be the wrong trade. They are row polymorphism for
sums, carrying exactly the inference costs §3 exists to avoid — OCaml's polymorphic variants are the
cautionary case, with large inferred types and hard error messages. And `Maybe` itself costs nothing:
it is an ordinary ADT, `type Maybe a = Nothing | Just a`, with no special machinery anywhere in the
compiler.

**Take Roc's real insight, which is orthogonal to whether `Maybe` exists:** don't reach for it when a
domain type says *why*. `[Loading, Loaded Artist]` beats `Maybe Artist` for the same reason `Result`
beats `Maybe` for failures. That is stdlib and API-design guidance — Elm's community already preaches
it — not a language decision.

**Resolving the `?` sub-decision:** `?` works on both `Maybe` and `Result`, with the enclosing
function required to return the *same* shape — `Maybe` inside a `Maybe`-returning function, `Result`
inside a `Result`-returning one. No conversion between the two, consistent with rule 2 above.
`Maybe.andThen` pyramids are as common as `Result` ones in Elm code, so the win is real, and the
check stays local: two desugaring cases, no inference involvement.

### Tuples: yes, unbounded arity (minimum 2)

Keep them — `Dict.toList`, `List.zip`, `List.indexedMap` and "return two things" all need a pair,
and without tuples each of those wants a declared record type, which is the same ceremony problem
as dropping `Maybe`.

**No arity cap.** An earlier draft of this section copied Elm's maximum of 3 and justified it on
compiler grounds: a fixed cap lets the tuple type be a fixed-size IR node
(`Tuple1 Variable Variable (Maybe Variable)`, `references/elm/compiler/src/Type/Type.hs:87`),
whereas unbounded arity "forces a slice into the `extra` array and a loop in the unifier's hot
path." **That argument is wrong, and Roc's compiler shows why: records are already variable-length,
so the machinery exists regardless — and tuples use strictly less of it.**

```zig
// references/roc/src/types/types.zig:554 and :743
pub const Tuple  = struct { elems:  Var.SafeList.Range };
pub const Record = struct { fields: RecordField.SafeMultiList.Range, ext: Var };
```

Same `SafeList`/`Range` primitive, same arena, same amortised-growth append. The record carries an
*extra* field — `ext`, the row-polymorphism extension variable — that tuples don't need. And the
unifiers are not close: `unifyTuple` (`src/check/unify.zig:1397-1421`) is an arity check plus a
pairwise loop, about twenty lines; `unifyTwoRecords` (`:2490+`) gathers fields transitively through
extension chains, partitions them into shared/only-a/only-b, handles four extension cases, and
allocates fresh ranges and type variables per divergence. The tuple path is a strict, cheap subset
of code we must write for records anyway.

The sharing continues at runtime: `pub const tuple = struct_;` and `insertTuple = insertStruct`
(`src/layout/layout.zig:864`, `src/layout/store.zig:554`) — tuples are an alias into the record
layout path, not a parallel implementation. Pattern matching rides the same variable-arity
constructor specialisation that tag unions already require.

**The argument the cap actually loses.** Feldman, #contributing, 2023-03-26, on why Roc has no
`Tuple` module: *"especially considering you have to implement a separate one for each arity of
tuple, which means you have to decide where to draw the line on what arity to support."* A cap
doesn't remove that problem — it relocates it into the standard library, which is exactly the mess
Elm ends up with: `Tuple.first`/`second` for pairs, and nothing at all for triples.

**Minimum of 2, structurally.** `(42)` is grouping, not a one-tuple. No counting required.

**Representation:** a fixed-shape object per arity, following §9.4's hidden-class rule. No runtime
tag is needed — the type is static and structural equality compares fields regardless — so tuples
cost one field less than Elm's `{$: '#2', a, b}`.

Note the §3.1 interaction: with `comparable` gone, a tuple-keyed `Dict` takes an explicit
comparator. That is the intended consequence, not an oversight.

**Positional access: `.0` / `.1`, zero-based.** An earlier draft rejected this because `x.0`
collides with float literals and "costs lookahead." The real cost is one extra branch and a single
byte of lookahead (`references/roc/src/parse/tokenize.zig:1412-1442`), inside the `.` case the lexer
*already* needs in order to tell record field access from a float continuation — the same order of
cost as `.field`, not a new expense. The reverse direction is already handled too: numeric lexing
only continues past `.` into a float when the next character is a digit or `e`/`E`, so `1.` followed
by anything else stays `Int` then `Dot`.

Dropping the arity cap is what makes this necessary rather than merely nice: with unbounded arity
there can be no per-arity accessor functions, so the choice is `.0` or destructuring-only.

Rules:

- The index is a **literal integer**, never a variable or computed expression — which is what lets
  the checker verify it against the tuple's arity at compile time.
- It applies to any expression of tuple type (`getPoint().0`) and chains (`nested.0.1`).
- Pattern destructuring stays, and remains the better choice when binding several elements at once.
- No `Tuple.first`/`second` in the standard library. That is the point: per-arity accessors are
  precisely what a cap forces and unbounded arity avoids.

### String interpolation: `${expr}`, no nested strings, primitives only

**Syntax.** `"total = ${count} items"`. A literal `${` is escaped as `\$`.

**What may be interpolated.** Without typeclasses there is no `Display`/`Show`, so nothing
auto-stringifies in general. Interpolation accepts a **fixed set of primitives** — `String`, `Int`,
`Float`, `Bool`, `Char` — and the compiler inserts the conversion. Anything else is an error that
names the conversion function, so `${user}` fails with a message pointing at `${user.name}` or an
explicit call.

Critically, this is **not** a new constraint in the unifier. "This type is interpolatable" is
collected as an obligation during constraint generation and discharged *after* solving, when the
type is concrete — the same mechanism as equatability in §3.1, and the same principle as the occurs
check: make the check rare rather than fast. A flat membership test at one syntactic site, run once.

**Lexing.** A mode flag and a brace-depth counter, no stack:

- `"` enters string mode.
- `${` switches to expression mode at depth 1; `{` and `}` adjust the depth; the `}` that returns it
  to 0 switches back to string mode.
- **A `"` inside an interpolation is a syntax error** — nested strings are what would force a full
  mode *stack*, and forbidding them removes the recursive case entirely. The diagnostic says to bind
  the inner string to a name first.

The token stream is `StrStart`, `StrChunk`, `InterpStart`, the expression's ordinary tokens,
`InterpEnd`, … `StrEnd` — all in the flat SoA array with real source offsets, so §6.1's lossless
CST and error recovery need nothing special. (The approach that *would* hurt is lexing a string as
one opaque token and re-lexing its insides later: it breaks the flat-array model and turns every
error position into offset arithmetic.)

**Codegen** is free: interpolation maps directly onto a JS template literal, which also keeps the
output readable.

**Multiline strings do not interpolate.** They stay fully raw, as in Zig — no escapes, no `${}`.
That keeps them dependable for embedded code samples (JSON, shell, generated JS all contain `${`
and `\` freely), and it means the lexer's line-prefixed path needs no mode switching at all:
interpolation state exists only inside ordinary quoted strings. Build a multiline string with
interpolation by concatenating, or interpolate an ordinary string into it — explicitly.

### Comments and multiline strings: line-oriented, Zig-style

Both are line-based. Nothing has a closing delimiter, nothing nests, and a newline always ends it.

- **`--` is an ordinary comment, `--|` documents what follows, `--!` documents the module.**
  Consecutive doc lines merge into one block, and it is an error to attach one where nothing can be
  documented — both Zig's rules.

  ```
  --! Utilities for working with non-empty lists.

  --| Returns the first element.
  --| Never fails, unlike `List.head`.
  first : Nonempty a -> a
  ```

  The spelling takes **Zig's machinery with Elm's vocabulary**. `|` already means "documentation" to
  this audience — Elm's `{-|`, Haskell's `-- |` — so `--|` needs no explaining, whereas `---` reads
  as a divider, and is also a diff marker and a Markdown/YAML separator. It is mechanically cheaper
  too: Zig needs an "exactly three slashes, not four" carve-out so a row of `////` isn't captured as
  documentation, and `---` would need the same rule for rows of dashes. `--|` cannot be produced
  accidentally, so no such rule exists. Lexing stays one byte peeked after `--`.
- **Multiline strings are line-prefixed**, Zig-style: the marker runs to end of line, a following
  marked line appends a newline, and the final line's newline is not included. **No escape
  processing at all** — they are raw by construction.

What this buys, and it is all lexer cost avoided:

- **No mode stack and no depth counter.** Elm's `{- -}` nests, which means the lexer carries
  nesting state; a block string needs the same. Line-oriented forms need neither.
- **A whole error class disappears.** There is no unterminated comment or unterminated multiline
  string — end of line terminates both. That also means a truncated file cannot swallow the rest of
  the program, which matters for the error recovery in §6.1.
- **Raw multiline strings sidestep escaping entirely**, so no escape grammar and no interaction
  between escapes and whatever interpolation ends up being.

- **No block comments at all**, as in Zig. Elm's `{- -}` nests, which is the nesting counter this
  whole section exists to avoid; commenting out a block is `--` per line, which every editor does
  with one keystroke. With this, the lexer has **no** delimited constructs to track state for
  besides ordinary quoted strings.

They are also **fully raw**: no escapes and no interpolation, so the line-prefixed scanner never
switches modes. See the interpolation section above.

Doc comments are trivia: the lossless CST (§6.1) carries them tagged, never discarded.

### Modules: no header, `pub` per declaration

```
import List exposing (foldr)
import Dict as D
import Json.Decode

--| Parse a URL.
pub parse : String -> Result ParseError Url

normalize : String -> String     -- private: no keyword needed
```

- **No header line.** The module's name comes from its path, as in Roc. Elm declares the name *and*
  requires it to match the path — redundancy that buys an entire error class. Path-derived also
  makes duplicate module names impossible rather than merely diagnosable, and moving a file means
  updating importers instead of importers *and* the file itself.
- **Visibility is marked at the declaration with `pub`.** Everything unmarked is private.
- **`pub opaque type T = …`** exposes the name without its constructors.
- **Imports are Elm-shaped:** `import Path [as Alias] [exposing (names)]`, parens for the list.

**Why not Roc's type modules.** Roc has no exposing list at all: a capitalised `Url.roc` must define
a type `Url`, that type is the whole public surface, and public functions are *associated items* on
it. It is genuinely nicer — nothing to maintain, one edit per new public function — but it is not a
separate feature. It is a view of static dispatch, which §3.1 rejected: attaching functions to types
only means something if calls can be resolved *from* a type, and that resolution is the dispatch
machinery we decided not to build. Roc's own docs also concede the model's costs, and both land
harder on a language whose stdlib is `List`/`Dict`/`String` modules of free functions: *"the `Util`
case is nicer in Elm (you don't need the void `Util` type), and it's more obvious how to organize
mutually recursive types... Roc optimizes for the common case at the expense of these less-common
ones."*

What we take from it is the part that doesn't need dispatch: *namespacing*. `Url.parse` meaning "the
`parse` in namespace `Url`" is plain name resolution, which Elm already does. Only `value.method()`
resolved by the value's type needs a dispatch plan.

**Why not Go's capitalisation rule.** Case is already spoken for: in ML syntax `Url` is a type or
constructor and `parse` is a value, and the lexer depends on it. If case also meant visibility, every
type would be forced public and every function private.

**Why not Elm's exposing list.** It is two edits for every new public function and an error class of
its own ("forgot to expose it"), and it duplicates information the declarations already carry.

**§8.1 is unaffected.** The public surface stays lexically computable — scan for `pub` rather than
read one line — so the interface hash needs no inference, and parallel name resolution keeps the
property §3 requires. It also removes the `exposing (Type(..))` problem: a wildcard whose meaning
depends on reading *another* module is exactly what breaks per-module name resolution, and with
opacity as a keyword there is no wildcard to ban.

**The cost, stated plainly:** you cannot read a module's whole API on one line; you scan the file or
ask the tooling. Zig and Rust live with this; generated docs make it moot.

### Two principles worth stealing

- **Delimiters are for humans, and that is a sufficient reason.** Bullard again: "for machine
  parsing there is no need for commas in ANY collection-like syntactic construct... They are there
  for the humans." Where a delimiter aids reading or editor selection, its parser cost is not an
  argument against it.
- **A formatter that auto-migrates makes micro-syntax reversible.** Roc flipped its optional-field
  marker twice, each time with formatter-driven migration and a did-you-mean diagnostic. That is
  only cheap if the formatter exists early — so it belongs in **M1**, alongside the parser, not in
  M5. It is also the same lossless CST the LSP needs (§6.1), so it costs little extra.

### Still open

Effect marking is settled by §3.1's effects decision: the language is pure, so there is none.
Record and optional-field syntax details are open; per the formatter principle above, they are
cheap to revisit.

## 4. Process architecture: a daemon, from day one

The CLI is a thin client over a Unix socket; the compiler is a resident process holding the
`Session`. The LSP server and `beni build` are the *same* process type, so every incremental
investment pays off in both (04 §8; rust-analyzer's `AnalysisHost`/`Analysis` and gopls'
`cache.Snapshot` are the model).

Consequences that must be designed in, not bolted on:

- No global mutable singletons. Everything hangs off `Session`.
- Arenas are reusable and resettable per compilation, not per process.
- Every phase must be able to run against an immutable snapshot while the next edit is ingested.
- File watching uses `inotify`/`FSEvents` directly. esbuild polls, and it's a documented scaling
  problem on large trees (03 §1).

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

Every IR in Beni is a `MultiArrayList` of fixed-size records with `u32` indices and a shared
`extra: []u32` sidecar for variable-length payloads. This is Zig's own design (01 §1–3), and
independently Carbon's, rust-analyzer's and oxc's (04 §2).

```zig
// Tokens: 5 bytes each, no length field — derivable from tag or re-derived at literal decode.
pub const Token = struct { tag: Tag, start: u32 };
pub const TokenList = std.MultiArrayList(Token);

// AST: ~13 bytes/node. data is an UNTAGGED union; `tag` already discriminates.
pub const Node = struct { tag: Tag, main_token: TokenIndex, data: Data };
pub const Index = enum(u32) { root = 0, _ };
pub const OptionalIndex = enum(u32) { none = std.math.maxInt(u32), _ };
```

Rules, non-negotiable across the codebase:

1. **No pointer inside any IR.** References are `u32` indices into a named array. Halves reference
   size, survives reallocation, serialises with no fixup pass, and makes equality an integer
   compare (01 §2).
2. **No per-node allocation.** One arena per phase; teardown is a handful of bulk frees. oxc
   measured teardown at ~0.3ms vs ~7ms for an equivalent heap AST (03 §2).
3. **Per-worker arenas, not a shared one.** Roc wrote `SingleThreadArena` specifically to avoid
   `std.heap.ArenaAllocator`'s atomic RMW per allocation, since every arena is owned by exactly
   one thread for its lifetime (05 §4). Copy this.
4. **Offsets, never slices, into source text.** A slice is 16 bytes; an offset is 4.
5. **No `HashMap` keyed by a dense id.** Roc enforces this with a CI lint (05 §4); adopt the same
   lint. Dense ids index parallel arrays.

### 5.1 Interning — with the contention caveat

Identifiers are interned **at lex time** into `Symbol = enum(u32)`, hashing while scanning rather
than materialising-then-rehashing (04 §3). Types and constants are interned into the same
`InternPool` so that type identity is `a.index == b.index` — one integer compare, no structural
walk (01 §5).

But interning has a documented failure mode: **oxc removed a global interner and gained ~30%
parallel parsing throughput**, because the interner mutex serialised precisely the phase being
parallelised (03 §2). Zig's answer is sharding — per-thread `locals` arrays with the thread id
packed into the index's high bits, plus per-shard locks on the dedup tables (01 §5).

**Decision:** per-worker interners during parallel lex/parse, merged at one synchronisation point;
a sharded global pool thereafter, following Zig's index encoding. Short identifiers use inline
storage (SSO) in the token payload so the common case never touches the table at all.

This directly fixes Elm's single largest structural cost — un-interned `Name` as a raw byte array,
compared byte-by-byte on every scope, environment and interface lookup for the entire back half of
its pipeline (05 §2).

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

**BIR is the load-bearing invention here.** Like Zig's ZIR, it is *untyped, unresolved, and purely
a function of one file's text* — which is what makes it content-addressable and cacheable across
process restarts, not just within a watch session (01 §6). A file whose bytes haven't changed
never gets lexed or parsed again, ever, on any machine with a warm cache.

Everything above the firewall is embarrassingly parallel. Everything below is scheduled on the
module DAG.

### 6.1 Parsing

Recursive descent for declarations, Pratt/precedence-climbing for expressions (04 §2) — ~40 lines,
no function-per-precedence-level, associativity from asymmetric binding powers.

Two invariants for error recovery, both of which cost nothing on the happy path (04 §2):

- Every loop consumes ≥1 token per iteration and terminates at EOF.
- On error, emit a structurally valid placeholder node. Downstream passes treat it as another node
  kind; there is no separate recovery machinery and no early abort.

**Build the lossless CST from day one.** Trivia is just more array entries in a flat design, so
the runtime cost is near zero, but retrofitting it later is documented as effectively a parser
rewrite (04 §2). The LSP will need it.

## 7. Type checking

Architecture is Elm's, because Elm's is right: **constraint generation, then solving** (02 §1),
not Algorithm W. Generation allocates fresh variables and emits a constraint tree; solving does
all unification in one pass. This avoids W's substitution-composition tax and centralises all
rank/generalisation bookkeeping in one function.

Five techniques, in leverage order (02 §Top 10):

1. **Union-find with mutation in place.** Type variables *are* graph nodes; "apply the
   substitution" is a pointer dereference. Path compression on find, union by size.
2. **Rémy/Kiselyov levels for generalisation.** Each descriptor carries a `rank` = enclosing `let`
   depth; `rank 0` means generalised. Generalisation scans only the pool of variables allocated at
   that rank, never the type environment — an asymptotic change, not a constant factor.
3. **Deferred occurs check.** Not on the unification hot path. Once per let-bound name, after that
   region has stabilised. Elm's `Unify.hs` calls `occurs` in exactly one narrow place and has a
   `TODO` wondering whether even that is necessary (02 §3).
4. **Sharing-preserving instantiation.** A per-copy memo field on the descriptor, cleared after
   each instantiation. Kills the classic `let x = (y,y)` doubling for any scheme with internal
   sharing — which real code hits constantly via large record aliases (02 §2.3).
5. **SCC-decomposed binding groups.** Only genuinely mutually-recursive definitions share a
   generalisation group; everything else is its own. Bounds both generalisation cost and error
   blast radius (02 §4).

**Errors never stop the build.** A failed unification merges both variables into a poisoned
`Error` content; every later unification touching it trivially succeeds. This is Elm's cascade
suppression, and it is why one mistake yields one message instead of forty (02 §6).

**Good messages must stay off the happy path.** Source spans are two packed 32-bit values (row in
the high half, column in the low) attached to every node — no allocation, no file path. The entire
error-rendering subsystem, including fresh-variable naming, runs only on failure (02 §5–6).

In Zig terms: the descriptor store is a `MultiArrayList` with an explicit undo journal (Roc's
`SlotUndo`/`DescUndo` design, 05 §4), which buys rollback for speculation without cloning.

## 8. Incrementality

Two layers, deliberately. The cheap one does most of the work; the fine one handles the case the
cheap one handles badly.

### 8.1 Layer 1 — the module interface firewall (primary)

Recompiling a module must **not** recompile its dependents unless its *public interface* changed.
Elm implements this by comparing the freshly computed `.elmi` against the cached one by value and
only bumping `lastChange` on a real difference (02 §8, 05 §1.4); GHC does the same with `.hi`;
OCaml exposes it as `-opaque`.

Beni keys this on **content hashes, not mtimes**. Elm's mtime scheme is the documented cause of
its cache-desync bugs and CI pathologies (05 §3), and content hashing composes naturally since the
interface hash *is* a content hash. Cache key = source bytes + module identity + compiler version
+ direct imports' interface hashes (Roc's `cache_key.zig` model, 05 §4). A `stat` fast-path avoids
hashing files whose size and mtime are both unchanged (04 §7).

**Explicitly rejected: salsa-style fine-grained query memoization.** rustc's own documentation says
fingerprinting "is the main reason why incremental compilation can be slower than non-incremental";
there are logged cases of incremental (13.47s) losing to clean (2.74s), and repeated 2–4× memory
blowups requiring dedicated LRU engineering (04 §6a). The macro-free language design removes the
reason rust-analyzer needed it.

### 8.2 Layer 2 — declaration-level dependency graph

Zig's `AnalUnit` insight, which is the difference between a 63ms rebuild and a 6-second one: a
declaration's **type** and its **value** are separate nodes in the dependency graph (01 §7).
Editing a function body invalidates its value, not its signature — so callers who depend only on
the signature are untouched, *within* the module as well as across it.

Beni's unit kinds:

| Unit | Invalidated by |
|---|---|
| `decl_ty` | a change to the declaration's type signature or inferred scheme |
| `decl_val` | a change to its body |
| `ctor` / `type_def` | a change to an ADT's constructors or a record alias's fields |
| `emit` | a change to `decl_val`, or to any representation decision it depends on |

Propagation is Zig's two-phase mark: a direct dependent becomes `outdated`; its transitive
dependents become `potentially_outdated` with a counter. A PO unit whose counter reaches zero
without ever being marked outdated is *proven* unchanged and never re-analysed. This is what stops
transitive invalidation from degenerating into "recompile everything" (01 §7).

### 8.3 Persisted cache format

Dump the arena's flat arrays as raw byte ranges with a small header; `mmap` on load; validate with
a format version and content hash. No general serialization library — rkyv-style zero-copy is the
*idea* to steal, not the dependency (04 §7). Roc calls this "zero-parse deserialization" and loads
at roughly memcpy speed (05 §4). This is only possible because of the no-pointers rule in §5.

## 9. JavaScript backend

### 9.1 Dead code elimination — copy Elm's mechanism exactly

Every top-level binding becomes a node in one flat whole-program map, keyed by module-qualified
name, carrying its own set of referenced globals. That dependency set is **a byproduct of ordinary
lowering** — no separate free-variable pass — because the name-resolution tracker records each
global reference as it generates the node (03 §5.1, 05 §1.5).

Emission is then a visited-set DFS from `main` and every exposed value. Anything unreachable is
never even looked up. No separate tree-shaking pass exists, and none is needed.

This is strictly better than what any JS bundler can do, because bundlers must *infer*
side-effect-freedom heuristically (`sideEffects: false`, `/*#__PURE__*/`) while Beni's type system
*proves* purity. It is also the same graph Layer-2 incrementality and code splitting use — build it
once, use it three times.

### 9.2 Two IRs, not one

Lower the typed IR into a small JS-shaped `JsIr` as part of existing lowering, then run one print
pass straight to a growable byte buffer.

This is a deliberate departure from esbuild's single-AST model, and the evidence is Elm's own
source: its author tried emitting directly to a byte builder, measured it "neutral for perf," and
kept the intermediate IR because codegen needs to pattern-match on generated structure to strip
redundant IIFEs and closures (03 §3). esbuild can skip the second IR only because its input and
output are both JavaScript; an ML-family source language is structurally far from JS, so the
peephole layer earns its place.

Output assembly follows esbuild's `Joiner`: accumulate `{data, offset}` pieces and a running
length, then allocate **exactly once** and blit (03 §3). Never concatenate.

### 9.3 Calling convention — the decision that must be made now

Curried semantics with an A2/F2-style adapter (Elm's scheme): functions are wrapped with an arity
tag `.a` and the raw n-ary implementation `.f`; saturated call sites emit `A2(f, x, y)`, which
checks `f.a === 2` and calls `f.f(x, y)` directly, falling back to `f(x)(y)` otherwise (03 §5.2).
Around 80% of calls in ML-family code are saturated, so the fast path dominates. PureScript's
measured cost of *not* doing this is 25–35% runtime and 20–25% bundle size.

The contested part: Gleam makes partial application an error unless explicitly requested, so every
saturated call is a plain JS call with no adapter at all. Hansen's measurements suggest the
adapter itself costs real performance — rewriting `A2(f,a,b)` to direct `f.f(a,b)` measured +49%
on Chrome, +109% on Firefox (03 §5.2).

**Resolved: keep currying** — see [`research/06-currying.md`](research/06-currying.md) for the full
evidence from Roc's FAQ and three years of its Zulip. Three findings decided it:

- **Roc's *particular* performance argument does not transfer** — but a JS-specific one does, and it
  binds. Roc's closure wins come from lambda sets and are LLVM-specific: stack-allocated closures,
  seeing through opaque function pointers. JS closures are already heap-allocated and V8 has neither
  problem. **However**, §9.3's own measurements say currying is only free if the adapter disappears:

  | Tier | Cost |
  |---|---|
  | Naive curried closures (PureScript stock) | 25–35% runtime, 20–25% bundle size |
  | Elm's `A2`/`F2` adapter at saturated sites | **+49% Chrome**, +109% Firefox, +37% Safari vs. direct |
  | Direct n-ary call at statically-known sites | baseline |

  The adapter costs a property load, an `=== n` comparison and an indirect call at every call site.
  So keeping currying is only cheap at the third tier, which makes the specializer a **requirement of
  M3, not a later optimisation**. Roc's FAQ concedes currying's cost is "most likely possible to
  optimize away" — that concession is the whole plan here, so it has to actually ship.
  (Caveat: these are `map`/`foldl` microbenchmarks from a community post, browser- and
  workload-specific. Directionally consistent with the PureScript figure; not a precise budget.)
- **Dropping currying is not a local change; it rewrites the idiom.** Elm's `|>` *depends on*
  partial application — `x |> String.split sep` only works because `String.split sep` is a value.
  Remove currying and you are forced into Roc's pipe-first convention and a standard library whose
  subject argument comes first, the opposite of `List.map f list`. Every signature flips. That is a
  far bigger change than the calling convention.
- **The one argument that does transfer is error quality**, and it is separable. Roc's real prize is
  a localised `TOO FEW ARGS` diagnostic, which a curried language supposedly cannot produce. But the
  unifier knows when it expected `a` and found `b -> a` — that *is* the missing-argument shape, and
  it can be reported as such with the call site underlined.

So: keep currying, and **treat the missing-argument diagnostic as a deliverable of M2, with its own
fixture suite**. That mitigation is the entire justification for keeping the feature, so it has to
be proven rather than assumed. If it does not land convincingly on real mistakes, revisit before M3
— afterwards it is a breaking language change, not a compiler change.

### Settled in M2b: the condition is met, currying stays

`tests/corpus/check/args/` holds 38 fixtures taken from real mistakes, each asserting a whole
diagnostic and each producing exactly one. On review, **37 of 38 read as the right message** —
above the 90% bar this section set. They name the function, its arity, what it got, the type of
the missing argument, and why the result could not be the value that was wanted:

```
The `update` function expects 2 arguments, but it got only 1.
The missing argument is:      Model
So this call produces a function:      Model -> Model
But I needed a value of type:      Model
```

The single failure is a composition (`f = String.toUpper >> String.trim`) where the message and
hint are right but the types shown are two unresolved variables: a lambda's equality is solved
before its body, so nothing has been learned yet at the point of report. Fixing it means
constraining a lambda's body before its type, which costs precision everywhere else. Three more
are right-message-but-imperfect-underline and pass on the strength of a dedicated hint.

The revisit trigger is therefore **discharged**: currying stays, and §9.3's two M3 obligations
below are what it now costs.

Concretely, that means **two** M3 obligations, not one: emit a direct n-ary call wherever the callee's
arity is statically known at a saturated call site — which is the overwhelming majority, since the
DCE graph (§9.1) already resolves every top-level reference — and fall back to the `A2`-style tagged
adapter only for genuinely higher-order or partially-applied positions. Elm leaves the ~49% on the
table precisely because it always routes through the adapter; there is no reason to repeat that.

### 9.4 Representation, tuned for V8

- **Records** → plain object literals with a canonical (sorted) key order, so every instance of a
  record type shares one hidden class (03 §5.3).
- **Constructors** → `{$: tag, a, b, ...}`, tag as a small integer in release mode, string in dev.
  Zero-argument constructors become bare integers.
- **Shape consistency is mandatory.** Elm's own `List` violates it (`Nil` is `{$:0}`, `Cons` is
  `{$:1,a,b}` — different shapes), and padding them to match measured ~11% on Firefox, ~4% on
  Chrome (03 §5.3). Beni pads every constructor of a type to a uniform shape.
- **Lists** → cons cells by default (they match pattern matching), but benchmark a 32-way
  persistent vector trie before committing; the cache-locality and deep-recursion failure modes are
  real (03 §5.6).
- **Tail calls** → direct self-recursion lowers to `label: while(true)` with parameter reassignment
  through temporaries. **This is mandatory, not an optimisation**: no JS engine reliably provides
  TCO — V8 shipped and reverted it, SpiderMonkey never shipped it (03 §5.5). Mutual recursion
  remains a real stack frame; flag it as a known limitation and revisit with a trampoline.
- **Pattern matching** → decision trees (Scott & Ramsey heuristics), compiled to native `switch`
  for multi-way tests, with single-use branches inlined and multi-use branches shared via labelled
  loops (03 §5.4).
- **Primitive peephole** → recognise core arithmetic/comparison calls at *print* time and emit
  native operators. Keeps the optimiser generic while avoiding a megamorphic dispatch point on the
  hottest call sites in the program (03 §5.7).

### 9.5 Output format and minification

**Emit ESM.** Elm's IIFE is universally compatible but opaque: no dev server can compute which
modules an edit affects, so any change forces a full reload (03 §6). ESM keeps the output
analysable, and the decision is unchangeable later without breaking every consumer.

**ESM is also what makes the full-stack decision necessary rather than merely nice** (12 §7.5).
Elm's delegation to a downstream minifier works *because* of the IIFE: Terser's `--mangle` leaves
ESM top-level names alone by default, and `terser -m toplevel=true` is byte-identical to `terser
-m` on Elm's output. Closure has never supported ESM as an emitter needs it, which is why Scala.js
deprecated it. Choosing ESM and choosing to own minification are the same decision.

**Beni is a full-stack solution: no external bundler, no external minifier.** `beni build`
produces deployable JavaScript on its own. This reverses the earlier split here, which handed
local-variable mangling and peephole compression to Terser or esbuild. That split was a reasonable
division of labour and is given up deliberately: a toolchain the user has to assemble is not the
product, and the handoff was the one place where the purity proof had to be re-explained to a tool
that could not verify it.

**The reference point is js_of_ocaml, not Closure.** An earlier draft of this section named
Closure's advanced mode, and report 12 falsified it by measurement: Closure ADVANCED finished 12%
*larger* in brotli than Terser given purity flags, at 50× the wall time, and Closure's own FAQ
attributes its big wins to externs and exports rather than analysis. js_of_ocaml owns short-name
allocation, JS-level simplification and compact printing in about 3,450 lines, is minified by
default, and has no external minifier in its dependency graph. Closure is the wrong model on three
counts: 180,000 lines, 0.06 MB/s against §2's emit budget, and no ES-module support.

**Size is tracked after compression, everywhere.** Brotli primary, gzip secondary, raw as a
diagnostic only. This is not a refinement — raw byte counts *invert* the ranking of
transformations. Report 12 measured renaming saving 12,269 more raw bytes than a compression pass
and still finishing 1,334 bytes larger after gzip, and measured an 18% swing in compressed size
from reordering declarations with the raw count held exactly constant. Closure reached the same
conclusion independently and says so in its source: it keeps `AliasStrings` disabled because "gzip
actually prefers that strings are not aliased", and its `PerformanceTracker` measures every pass
before *and* after gzip.

**The model is entropy, not length.** Fewer distinct identifiers means cheaper Huffman codes. This
corrects the reasoning an earlier draft gave for assuming brotli. The sliding-window mechanism is
real and confirmed — gzip matches within 32KB, brotli within megabytes, a 180× difference on
synthetic repetition — but on real bundles the extra reach is worth 5.1% at 206KB and 0.7% on a
minified 53KB file, and nothing at all once the file is smaller than the window. So the claim that
whole-program naming consistency "largely does not pay under gzip" is **refuted**: it pays under
both, through entropy, which is a whole-stream property with no window dependence. Brotli stays the
assumed encoding on its own merits, roughly 16% ahead on the same file, but the argument for it is
not the window and not the static dictionary, whose folklore did not reproduce (12 §2.3, §2.4).

The corollary is a technique Elm cannot have: **type-directed field ambiguation.** Fields that
never co-occur on any type can share one short name, which lowers the distinct-symbol count rather
than merely shortening it. Google's `AmbiguateProperties` exists precisely because disambiguation
*increases* compressed size, so this is the direction that helps.

What we must build, ranked by compressed bytes (12 §5.1), with an explicit *not* list: local and
top-level identifier renaming, property and field renaming including the ambiguation above, exact
dead-code elimination (§9.1), and compact printing. **Not** `booleans` (`true` → `!0` makes brotli
output *larger*), not `if_return` or `collapse_vars` (negative under brotli), and not `inline`,
`evaluate`, `reduce_vars`, `sequences`, `comparisons`, `switches` or `typeofs`, all of which
measured approximately zero.

**Two build modes, one graph.** `beni build` is development output: one ESM file per source
module, mirroring the source tree, no dead-code elimination, string constructor tags, source maps
on. It optimises for rebuild latency and debuggability, and it is what the §2 warm-rebuild budget
of 15ms is measured against — one edit rewrites one small file. `beni build --release` is
deployment output: reachability chunks, exact elimination, integer tags, whole-program renaming and
field ambiguation, maps off. Both read the same declaration graph, so nothing is built twice, and
§9.4's "tag as a small integer in release mode, string in dev" already assumed this split existed.

**Code splitting is designed in now, not retrofitted.** Elm has no chunking concept and adding one
means reworking its emission core. Large programs are expected to need chunks, so this is an M3
requirement. Three decisions, all from report 12:

**Chunking is opt-in per program, and release-only.** The entry points are `main` plus every
`lazy` declaration, so a program with no `lazy` colours every reachable declaration identically and
emits exactly one file. Nothing is split because a program got large; a program is split where its
author said to split it.

- **Chunk assignment is per declaration**, by entry-set colouring over the §9.1 graph, with the
  colour **hash-consed from the start** — dart2js's `ImportSetLattice`. Both GWT and Rollup
  discovered late that the naive representation costs minutes; dart2js measured 401 deferred
  imports producing 2.9 million import-sets and a 5GB heap before interning. Declaration
  granularity is proven in production by four whole-program compilers, and Closure's four safety
  guards for it are all vacuous in a pure language.
- **A size-driven merge pass runs after colouring, with its budget set by compression rather than
  request count.** Each chunk starts a fresh compression window, so four chunks cost about 6.6% of
  brotli'd bytes and sixteen about 18% *before any chunk has saved anything*.
- **The assigner synthesises the cross-chunk `import`/`export` bindings itself.** Closure is the
  only system doing declaration-granular chunking with an ESM mode, and the combination is broken
  there — it relocates declarations without emitting the matching bindings (closure-compiler#4264,
  open). esbuild's `computeCrossChunkDependencies` is the model. Budget this with the assigner, not
  after it.

**The split trigger is a `lazy` marker on a top-level declaration**, rewriting its type into the
effect language: `lazy adminDashboard : Model -> Html Msg` is seen by importers as
`Task LoadError (Model -> Html Msg)`. Every shipped trigger in every language changes a type at the
boundary — Dart a `Future`, Scala.js a `Promise` — and TC39's `import defer` proposal exists
because that "forces all functions and their callers into an asynchronous programming model". **In
a language whose effects are already values (§3.1), a value arriving through a `Task` colours
nothing that was not already coloured: the cost that dominates this feature everywhere else is
already paid.** Precedent is strongest for the declaration-level form — Leptos ships `#[lazy]`
exactly, and a Roc contributor named Leptos-style annotation as Roc's likely path for the identical
problem. First-class `LazyRef a` values were rejected as the one candidate with no working
precedent anywhere, and the design that maximally creates references reachability cannot see
through.

**Where the marker goes: on a top-level declaration, never on a file, a local or an import.**
`pub lazy adminDashboard : Model -> Html Msg`, with the body written at the declared type and the
rewritten type being what everyone else sees. Not per file, because in release mode files are not
output units at all and the marker should sit at the granularity of the graph it controls, which is
per declaration. Not on a local, because a `let` binding is not a node in the declaration graph.
Not on the import, which is the one arguable alternative and is where Dart and PureScript's proposal
put it: consumer-side marking would make a module's interface differ per importer, and the interface
being a single fact is what §8.1's firewall rests on. Producer-side also matches `pub`, already a
per-declaration marker on the same line. A private declaration may be `lazy`: it still creates an
entry point, which is what you want for one large helper behind one route.

**A `lazy` declaration is an entry point, not a chunk.** Its chunk is everything reachable from it
that no other entry point needs, so marking one function moves its whole private subtree. The
corollary is worth stating because it is how the feature reports its own futility: if almost
everything is shared, the chunk holds only that one function, and the merge pass folds it back
rather than paying a compression window and a round trip for nothing.

Two constraints come with it. dart2js's rule binds: **anything reachable from a pure position goes
in the main chunk**, so `view` cannot await — though here the type rewrite makes that a type error
rather than a dedicated check, which is the benefit of doing it in the type system. And the interaction with §9.3's saturated-call specialization
**must be designed rather than discovered** — whole-program optimisation silently defeating split
points is the single most common entry in GWT's issue tracker.

**What chunking will not buy.** On the bundle report 12 measured, 90% of bytes are runtime plus
library, which no chunker can split. Chunking is a large-application feature, not a size strategy.

**The exit criterion, because the counter-evidence is real.** Scala.js built the type-aware half of
this and still expects a downstream generic minifier; going without it measured 1.58× in brotli.
That does not sink the plan, because Scala.js never built the generic half at all — but it makes
the risk measurable. **M3 exits when beni's own brotli'd output is within about 10% of beni's
output piped through esbuild `--minify`.** If it approaches 1.58×, revisit before M5.

The size target is Elm's TodoMVC, and the number that counts is the compressed one: 122KB raw,
24KB minified, **9KB gzipped**. (Report 03 attributes these to `hints/optimize.md`; they are in the
Elm guide's asset-size page, verified against `references/elm`.)

### 9.6 Source maps

Fused into the print pass (`addMapping` at each emit site, no second traversal), delta-encoded VLQ
with a 64-byte lookup table and a single-sextet fast path, per-file chunks rebased once at join
time — all esbuild's techniques (03 §4). **Off by default**, since maps can be 3× the size of the
output and are among the slowest parts of a production build.

But position tracking must exist in the IR *from the start* even while maps are off: retrofitting
it means touching every pass, not just the printer. Elm never threaded positions through codegen
and consequently has no source maps at all (03 §4).

## 10. Parallelism — and where not to use it

**Parallelise:** lexing, parsing, and BIR lowering (per file, no cross-file knowledge, trivially
parallel); per-module interface extraction; codegen per declaration, as a bounded
producer/consumer pipeline behind the checker (Zig budgets in-flight bytes rather than spawning a
task per function, 01 §8).

**Do not parallelise:** the warm single-edit path. At a 15ms budget, thread-pool wake-up and
synchronisation can exceed the work — exactly what rustc measured, where `-Z threads=8` *regressed*
small inputs (04 §5). Also not the type checker's core: Zig's multi-year, still-incomplete
InternPool thread-safety migration initially made things *slower* (01 §5, §8). Module-DAG
parallelism captures nearly all the available win at a fraction of the risk.

**Determinism is a requirement, not an aspiration.** rustc's project goals call its parallel
frontend's non-determinism "fundamental," and `codegen-units > 1` still produces non-reproducible
binaries because merge order follows thread timing (04 §5). Rules: stable input-derived ids
assigned *before* parallel work starts (module index by sorted path, never completion order);
results re-keyed by that id before merging; global tables append-then-sort; two-run output diffing
in CI.

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

Build this before the optimiser, not after.

- **`--self-profile`** emitting Chrome-trace JSON per phase and per analysis unit, viewable in
  Perfetto/speedscope. Clang's `-ftime-trace` and rustc's `-Z self-profile` are the models; rustc's
  captures query cache hits/misses, not just phase time (04 §10).
- **A permanent pathological corpus.** Every real slow file ever encountered gets frozen into the
  benchmark set forever. This is exactly how rustc-perf grew (`token-stream-stress`,
  `tuple-stress`) (04 §10).
- **The §2 budget tracked per-PR as a visible trend, not a hard gate.** rustc deliberately doesn't
  gate — some regressions are correct trade-offs — but the number is on every PR, which makes
  regressions conscious rather than accidental.
- **Determinism test:** two full builds, byte-diff the output.

## 13. Build order

Each milestone ends in something measurable.

1. ~~**M0 — Skeleton.**~~ **Done.** Token SoA, arena infrastructure, intern pool,
   `--self-profile`, the benchmark harness and the determinism test. *Measured: read 780 MB/s.*
2. ~~**M1 — Front end.**~~ **Done.** Lexer, LL(k) parser with error recovery and a lossless CST,
   BIR lowering, and the formatter. Parallel per file. *Measured on 100k LOC: lex 9 ms
   (185 MB/s), parse 6 ms, lower 9 ms, `fmt --check` 26 ms on four cores; the formatter round-trips
   the corpus and every `.expected` is a fixed point.* Milestone detail is in
   [`frontend.md`](frontend.md) §8.
3. **M2 — Checker.** Contract in [`checker.md`](checker.md). M2a (packages, module graph,
   interfaces, cross-module resolution) and M2b (type store, constrain/solve, the ad-hoc
   obligations, the missing-argument suite) are **done**; M2c (exhaustiveness, DAG-parallel
   checking) and M2d (measurement and review) remain. *Measured: 1.33M LOC/s for checking alone
   against the >250k target, and 118 ms for the whole cold pipeline including core against the
   800 ms budget. The missing-argument suite scored 37/38, discharging §9.3's revisit trigger.*
4. **M3 — Backend.** Decl graph, reachability DCE, JsIr, printer, **saturated-call specialization
   with `A2`/`F2` only as fallback** (§9.3), TCO loops, decision trees, ESM output. *Measure: emit
   throughput; output size vs Elm; and the share of call sites emitted as direct n-ary calls — if
   that share is low, the currying decision was wrong.*
5. **M4 — Daemon + incrementality.** Socket protocol, content-hash cache, mmap artifacts, interface
   firewall, then the declaration-level graph. *Measure: the warm-rebuild budgets in §2.*
6. **M5 — Polish.** Source maps, code splitting, LSP, field-name shortening, minifier handoff.

The ordering is deliberate: M4's incrementality is the single largest win (63ms vs seconds), but it
is also the one that needs the data model from M0–M3 to be right first. Zig's own experience is
that doing this in the wrong order costs a 30,000-line refactor (01 §7).

## 14. Open questions

1. ~~**Currying vs. Gleam-style explicit partial application**~~ — **resolved, see §9.3**: keep
   currying; recover Roc's `TOO FEW ARGS` diagnostic in the unifier instead. Carries an M2
   obligation (a missing-argument fixture suite) and a revisit-before-M3 trigger if that fails.
2. **List representation** — cons cells vs. persistent vector trie (§9.4). Benchmark against real
   idiomatic code during M3; the answer is workload-dependent and PureScript's experience shows
   intuition is unreliable here.
3. **How fine is too fine for Layer 2?** Zig found `AnalUnit` granularity needed a major refactor
   to avoid over-analysis when a type doubles as a namespace (01 §7). Start at the four kinds in
   §8.2 and resist adding more without a measurement that demands it.
4. **Does BIR need to be separate from the resolved IR at all**, given that Beni has no `comptime`
   and a much simpler semantic model than Zig? The caching argument says yes; the complexity
   argument says measure it in M1 before committing.
5. **Mutual-recursion stack safety** (§9.4). Trampolining costs the common case; leaving it
   unfixed is a real cliff for idiomatic ML code. Defer, but don't forget.
