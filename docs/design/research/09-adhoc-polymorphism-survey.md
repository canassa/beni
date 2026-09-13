# Ad-hoc polymorphism on JavaScript: who pays what

Commissioned to test whether §3.1's exclusion of typeclasses is a reasoned decision or inherited
laziness. Three strands: was Elm's omission deliberate; what dictionary passing costs on JS; and
what the languages that refuse dictionaries do instead.

**Caveat:** the session's WebSearch budget was exhausted, so agents worked from directly
constructed URLs and the vendored repos. Several sources were unreachable (GHC's wiki is behind an
anti-bot wall; several elm-lang.org essays 404). Unverified items are marked as such.

---

## 1. Elm: deliberate deferral, not neglect — and not a principle either

Evan Czaplicki, elm/compiler#38, opened 2012-11-12:

> "Elm currently uses Standard ML's method of operator overloading. It is a thing :) I chose it
> because it **can be gracefully upgraded to work with type classes**... Long story short, type
> classes are in the works, and based on the trade offs that come with each interim option, the
> current solution is best *in my opinion* until I add something better."

Closing it in 2015: *"This is obviously on my list of 'features to think about'."* The successor
issue #1039 remains open:

> "since the very beginning of Elm, it has not become clear which is 'the right choice' for Elm. It
> is also true that if you go too crazy adding this stuff, you probably can never un-add it."

The compiler corroborates deliberate scoping. The four `SuperType`s are not a stopgap hack —
`Type/Unify.hs` implements a real lattice over them with subsumption (`Comparable + Appendable →
CompAppend`), `combineRigidSupers`, `atomMatchesSuper`. It is a closed, hand-built kind system,
ported from SML on purpose as upgradeable scaffolding. The idea stayed live on the record: `roadmap.md`
parks an `eq` constrained variable, and the 2021 "Faster Builds" post mentions planned `equatable`
and `hashable` types.

**The finding that goes against us:** there is **no evidence tying Elm's compile speed to the
absence of typeclasses.** Evan's own performance writing attributes 0.19.2's gains to parser
allocation and GC pressure (20% lower GC copying, 10% lower peak memory, 7% faster overall) —
nothing about constraint solving or dispatch. Any "Elm is fast *because* it lacks typeclasses"
claim is community folklore, not sourced from Elm.

## 2. Dictionary passing: manageable until you try to erase it

**The decisive precedent.** Phil Freeman, PureScript's creator, on why the standard compiler does
not monomorphise:

> "[monomorphization is] a global program transformation for compiling type classes. Being global,
> it doesn't always play nicely with separate compilation."

He shipped narrower fixes — CSE of dictionary expressions, inlining of already-monomorphic
dictionaries — rather than sacrifice separate compilation. That is exactly the trade this design
faces, decided the same way by someone who faced it first.

`purescript-backend-optimizer`, which *does* do whole-program specialisation, confirms both halves:
**25–35% runtime improvement, 20–25% smaller minified bundles, 15–20% smaller gzipped** — and its
README states optimisation "is currently not incremental." A user filed #124 after having to build
module-caching themselves, because "recompiling and optimizing the entire AST for every single
module on every build is a significant bottleneck."

| Language | Mechanism | Cost found | Whole-program dependence |
|---|---|---|---|
| PureScript | Dictionaries as plain JS objects, passed as extra args | Compiler-side dictionary lookup was once quadratic (PR #1160: 142.9s → 56s); pattern-matching over instances can emit 17,000+ lines from small input (#113) | Optimizer explicitly non-incremental |
| Scala.js | Implicits resolved in the typer; instance is an ordinary object argument | fastOpt 0.9–6× slower than JVM; fullOpt 0.9–3× | DCE is whole-classpath reachability (#1626) |
| GHCJS / GHC JS backend | Standard GHC dictionary desugaring | Compile time "an hour or two" → "a full day" across a version bump; memory 20GB → 30GB+ (#820, #821) | **No** — see below |
| Fable (F#) | No dictionaries at all; SRTP on `inline` functions, resolved per call site | Code duplication; Fable fails to alpha-rename consistently, emitting `'x_1' has already been declared` (#3921) | None |

### Two corrections to claims made earlier in this project

- **The "476 million dictionary comparisons" figure could not be located** in any accessible
  PureScript source. Treat as unverified; it should not be cited.
- **PureScript's RowList "30-minute compile" was root-caused to the parser, not dictionary
  resolution** (#3376). It has been repeatedly conflated with a typeclass cost, including in this
  project's earlier notes. It is not one.

### The counterexample that matters

**GHC's `SPECIALIZE` is not a whole-program pass.** An `INLINABLE` function's Core unfolding is
serialised into its `.hi` interface file at definition time; any importing module can generate its
own specialised, dictionary-free copy from that local interface data, transitively, without
reprocessing the original module. This is an existence proof that **dictionary elimination can be
made compatible with separate compilation** — propagated through interfaces rather than a global
analysis. Whether it survives intact to GHC's JS backend could not be confirmed.

**F#/Fable's SRTP is the same idea, simpler.** Member constraints on `inline` functions resolve at
compile time per call site. Confirmed in emitted output: a wrapped numeric type compiles to a direct
static call (`WrappedNum_op_Addition_…(x, y)`), plain numbers to a bare `x + y` — no dictionary
either way. The costs are code duplication and a language-level fork: SRTP works *only* on `inline`
functions, so you cannot write a non-inline generic function with member constraints.

## 3. The languages that refuse dictionaries

| Language | Mechanism | Value-directed? | Type-directed, no value? | DCE impact |
|---|---|---|---|---|
| ClojureScript | Protocols → prototype methods; `goog/typeOf` table for host types; bitmask fast path for core protocols | Yes, native | No | Methods on shared prototypes; advanced-mode DCE needs strict conventions |
| Kotlin/JS | Interfaces → prototype methods | Yes | No on bare `T` (erasure); partial escape via `inline reified`, per call site only | IR backend does member/class-level DCE |
| Dart | Structural interfaces + extension methods resolved on the *static* type | Yes, at static-call speed | Generics reified, but no confirmed bare-`T` construction | tree-shaking claimed, no numbers |
| Haxe | Static extensions + abstract types (fully erased) | Yes, zero-overhead — abstracts "completely disappear from the output" | **`@:generic` = whole-program monomorphisation**, emitting `MyValue_String`, `MyValue_Int` | class/field-level, traced from `main` |
| ReScript / OCaml | Modules and functors — `Set.Make(Comparable)` | Threaded explicitly | Functors *are* the dictionary, passed by hand; docs call it "dependency injection" | Functor applications are **inlined/specialised**: "none of the JS output references the Make* function" |
| Gleam | Nothing. Explicit function parameters — `list.sort(list, by: compare)` | Yes | No, by design | explicit calls shake trivially |
| TypeScript | Structural typing → ordinary prototypes; generics fully erased | Yes, free | **No** — "no value `T` at runtime", no reified escape hatch | Webpack flags class-shaped exports as "problematic" vs plain functions |

### Gleam's FAQ is the sourced version of the argument Elm never made

Typeclasses, in their words:

> "can make it easy to make challenging to understand code, tend to have confusing error messages,
> make consuming the code from other languages much harder, **have a high compile time cost, and
> have a runtime cost unless the compiler performs full-program compilation and expensive
> monomorphisation**."

A modern language rejecting them explicitly on compile-time grounds, compiling to JS among other
targets. This is the citation §1 previously lacked.

### The structural result

Across all seven languages, genuine **type-directed dispatch with no value** reduces to exactly two
things wearing different clothes:

1. **An explicit value threaded by the caller** — Gleam's comparator, TypeScript's constructor-function
   workaround, ReScript's functor argument. Their own docs concede these are dictionaries by another
   name.
2. **Whole-program specialisation** — Haxe's `@:generic`, ReScript's functor inlining.

Languages that reject both simply do not offer return-type polymorphism, and treat that as correct.

**Value-directed dispatch (`x.method()`) is free everywhere**, because JS prototypes do it natively.
That half never needed typeclasses.

## 4. What this means for §3.1

**The exclusion stands, but the justification changes.**

- The "Elm is fast because it has no typeclasses" framing is unsupported and must go.
- The supported argument is Gleam's and Phil Freeman's: dictionaries cost compile time and output
  size, and the effective fix is global, which conflicts with separate compilation. PureScript's own
  creator declined to build it for that reason; PureScript's optimizer proves both the benefit and
  the non-incrementality.
- **But "you must do whole-program work" is too strong.** GHC's interface-propagated specialisation
  and F#'s SRTP are shipped counterexamples. A future version of this language could offer
  constraints resolved at concrete call sites, carried through interface files, without a global
  pass — trading code size for ergonomics.
- That option is worth keeping open precisely because it is *additive*: `number`/`appendable` today,
  call-site-specialised constraints later, with no change to the representation or the firewall.
  Evan's 2012 reasoning — pick the interim mechanism that upgrades gracefully — applies unchanged.
