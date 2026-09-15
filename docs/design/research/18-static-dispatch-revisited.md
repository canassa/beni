# Static dispatch, revisited: what Roc's shipped design costs, and what transfers

**Commissioned by** a one-line objection — *"I am still not convinced about not adopting static
dispatch"* — against [`fast-compiler.md`](../fast-compiler.md) §3.1, which records the exclusion as
**settled**.

The evidence behind that decision is older than it looks. [`research/07`](07-roc-static-dispatch.md)
was written while Roc's static dispatch was a proposal, [`09`](09-adhoc-polymorphism-survey.md)
surveyed languages that had refused typeclasses, and [`10`](10-monomorphisation-and-incremental.md)
tested whether whole-program specialisation could be made incremental. None of them could see what
the feature costs *once shipped*. Roc has since removed abilities, designed static dispatch across
twenty-eight `#ideas` topics, rewritten its compiler around it, released it, and accumulated the
first experience reports. Its language reference is vendored here at
`references/roc/docs/langref/static-dispatch.md`.

This report re-tests §3.1 against that. **The objection is substantially right about the cost
model and substantially wrong about the conclusion** — but not for the reasons either side of the
argument had written down.

## 0. Findings

- **Every runtime-cost citation in §3.1 is borrowed from a language whose dictionary density is
  structurally higher than beni's could be.** PureScript's measured 25–35% is taken over code where
  `Functor`/`Applicative`/`Monad` dictionaries thread through every bind. beni has no monad
  hierarchy. The number is real; the transfer was never argued. (§1.1)
- **The check-time mechanism is row polymorphism, not dictionary infrastructure.** Constraints
  accumulate as `module(a).method : …` in the inferred type and reduce when a nominal type arrives.
  No global pass, no whole-program work. §3.1's "~3,600 lines of dispatch registry" framing
  overstates the conceptual cost. (§1.2)
- **The runtime argument, taken seriously on a JS target, mildly favours adopting it.** At a
  concrete call site static dispatch emits a direct call the engine inlines; beni's current
  dispatch-free route runs one shared structural walk that is megamorphic by construction. The
  costs that survive are check time and output size. (§1.4, §1.5)
- **The cost that does survive lands on inference, which is where beni is most exposed.** Roc lost
  principal type inference to static dispatch in August 2026 and is buying it back with accumulating
  method constraints. Roc's mitigation is "people annotate top-level functions in practice"; beni
  decided the opposite — annotations optional, the interface *is* the inferred scheme — and so
  cannot use that mitigation. (§2)
- **Nominal typing is required far more narrowly than §3.1's rejection of Roc's type modules
  implies.** Structural shapes receive derived `is_eq`, `to_hash`, `parser_for`, `encoder_for` and
  `map` automatically. Only *open, user-named* methods in `where` clauses need a declaring module.
  (§4)
- **beni already has three of Roc's four mechanisms**, under different names. The genuine gap is
  two features, and they separate cleanly: structural codec derivation needs no dispatch at all;
  user-named constraints need the checker and module-system changes. (§5)
- **§3.1's "the door is not welded shut" is overstated and should be corrected.** Static dispatch is
  additive to the type system and invasive to the module system. (§6)

## 1. What §3.1's argument gets wrong

### 1.1 The runtime-cost citations do not transfer

§3.1's dictionary-passing row rests on PureScript: its separate optimizer recovers 25–35% runtime
and 20–25% bundle size, and its creator declined to build the fix into the standard compiler. Both
facts are correct and correctly cited in [`09`](09-adhoc-polymorphism-survey.md) §2.

What neither report argued is the transfer. PureScript's dictionary traffic is dominated by the
`Functor`/`Applicative`/`Monad`/`MonadEffect` chain: in idiomatic code a dictionary is threaded
through every `bind`. beni has direct-style effects (`transparent-effects-proposal.md`) and no
currying (§9.3), so it has no monad hierarchy at all. The dictionary traffic a beni program would
generate is `eq`/`ord`/`hash`/`show` at collection boundaries. That is a different order of
magnitude, and the report that would establish how different has not been written.

The same gap applies to §3.1's use of Roc's throughput. The measured 3,400 lines/s is a
**whole-program monomorphising native backend** — `.lss` — not the dispatch front end.
[`10`](10-monomorphisation-and-incremental.md) established that specialisation is the phase nobody
has made cheap to cache, and that conclusion stands. §3.1 spends it twice: once against
monomorphisation, where it belongs, and once against static dispatch, where it does not.

### 1.2 The mechanism is row polymorphism

Asked how static dispatch is implemented in `unify`, Roc's answer is that it is the machinery
already present for open records and anonymous tag unions. Constraints accumulate in the inferred
type as calls are made, and *reduce* when a type with a known declaring module arrives:

> "in order to narrow a type variable in a `module` (e.g. the `x` in `module(x)`), you have to
> actually pass a specific nominal type — and as soon as you've passed a specific nominal type, we
> know what module it came from … at which point it's trivial to unify `module(x).foo : type goes
> here` with the type of that module's exposed `foo` function"

Richard Feldman, #compiler development › Static dispatch typing / unify implementation, 2025-08-23
<https://roc.zulipchat.com/#narrow/channel/395097-compiler-development/topic/Static.20dispatch.20typing.20.2F.20unify.20implementation/near/535778255>

There is no global analysis and nothing that conflicts with separate compilation. This is the
strongest correction to §3.1: the ~3,600 lines of `static_dispatch_registry.zig` and
`dispatch_evidence.zig` that [`07`](07-roc-static-dispatch.md) counted are an implementation's size,
not the mechanism's conceptual weight.

### 1.3 The prototype row is a strawman

§3.1 rejects `x.method()` because "methods on prototypes defeat the precise whole-program
tree-shaking §9.1 depends on." True, and irrelevant: static dispatch does not need prototypes. Roc's
own reference is explicit that dispatch is resolved at compile time and emits a direct call —
*"after compilation, it's exactly as if you had called the function directly"*
(`static-dispatch.md:11-13`). Where the checker knows the concrete type, `a == b` on two `Int`s
emits `a === b`. Dictionaries appear only where a constrained generic is called from another
constrained generic with no concrete instantiation in sight.

### 1.4 The residual dictionary cost depends on constraint arity, not on dictionaries

At a genuinely polymorphic site something must be passed. Two cases, with different costs:

- **Single-method constraint** (`compare`, `to_hash`): the "dictionary" is a bare function
  reference. That is exactly what `Dict.empty String.compare` costs today. No regression.
- **Multi-method constraint**: a record per instantiation. The call site then does `d.compare(a, b)`
  — one dictionary shape keeps the inline cache monomorphic, several make it megamorphic, and V8
  stops inlining through it ([`03`](03-js-codegen.md) §5.3, citing Egorov). This is the failure
  Gleam monomorphised record-update codegen to escape, also recorded in `03` §5.3.

The mitigation is an encoding choice, not a language choice: where the needed method set is known
at the call site, pass N function arguments rather than one record. That keeps every call direct
**and** preserves §9.1's granularity, which is the sharper cost — a dictionary record is one
top-level binding referencing all its methods, so reaching it for `eq` retains `compare`, `hash` and
`to_string` too. Today `Dict.empty String.compare` retains exactly `String.compare`.

### 1.5 The inversion §3.1 does not state

`eq` is already a `foreign` implemented as one shared structural walk over every type in the
program (`core/Basics.js:93-111`): a worklist array, an `Object.keys` allocation per node, and a
property access that is megamorphic by construction. `Debug.toString : a -> String` is the same
trick with no obligation at all.

So the honest statement of the trade is the reverse of §3.1's framing:

| | Runtime | Output size |
|---|---|---|
| beni today, structural foreigns | slow; one shared megamorphic walk | smallest |
| static dispatch, concrete call site | fastest; direct call, inlinable | small |
| static dispatch, single-method generic | same as today's explicit comparator | same |
| static dispatch, multi-method generic | megamorphic IC unless encoded as N arguments | coarser DCE (§9.1) |
| derivation | fast | grows per type × derived method |

"No static dispatch means no runtime cost" is not true. The cost is paid; it lives in a shared
function instead of in per-type code. Whether that trade is worth reversing is a measurement nobody
has taken (§7).

## 2. Where the cost actually lands: inference

### 2.1 Inferred types become traces of the call sequence

Joshua Warner put a four-line unannotated function to Roc and asked what it would infer:

```roc
|x, y| {
  joined = x.map2(y, Pair)
  res = joined.walk([], |acc, el| acc)
  if false { res } else { res.push(0) }
}
```

The answer is a four-clause `where` block naming `module(x).map2`, `module(joined).walk`,
`module(res).push` and `module(num).from_digits`
(<https://roc.zulipchat.com/#narrow/channel/395097-compiler-development/topic/Static.20dispatch.20typing.20.2F.20unify.20implementation/near/535777483>).
Anton's reaction: *"Tracking it seems manageable but it does not look nice in the LSP type hover"*
(<https://roc.zulipchat.com/#narrow/channel/395097-compiler-development/topic/Static.20dispatch.20typing.20.2F.20unify.20implementation/near/535714429>).
Feldman's mitigation, in the same thread: *"in practice people will normally annotate top-level
functions, at which point the type checker would just verify that the body matches the annotation
like normal."*

### 2.2 It cost principal type inference, in August 2026

A ten-line example using the same generic argument at two different instantiations failed to
unify, and adding a type annotation made it *succeed* — more programs typecheck with an annotation
than without:

> "so without this, we don't have principal type inference - because you can (as demonstrated at the
> top of this thread) add a type annotation which increases flexibility, which should not be
> possible if we are inferring principal types"

Richard Feldman, #beginners › Rank-2 limitation? (and an error message), 2026-08-28
<https://roc.zulipchat.com/#narrow/channel/231634-beginners/topic/Rank-2.20limitation.3F.20.28and.20an.20error.20message.29/near/619842472>

The fix is to allow several constraints on the same method name — `a.map` at both `(U32 -> U64)`
and `(U32 -> U128)` — with an acknowledged and deliberately-accepted risk:

> "in theory it can lead to type constraints accumulating in un-annotated programs in a way that
> could make performance worse. I am not worried about this in practice … This is especially true
> because as soon as type annotations are in the mix, this no longer even comes up."

Same thread
<https://roc.zulipchat.com/#narrow/channel/231634-beginners/topic/Rank-2.20limitation.3F.20.28and.20an.20error.20message.29/near/619843700>

Both mitigations are the same mitigation: *assume annotations*.

### 2.3 Why this lands harder on beni than on Roc

§3.1 records, decided 2026-09-13: **top-level annotations are optional**, and therefore "a module's
interface is the *inferred* scheme of each `pub` declaration, not a lexical fact" — an importer is
re-checked whenever a dependency's inferred interface changes by value.

Compose that with §2.1 and §2.2 and the interaction is direct. Under static dispatch an unannotated
`pub` function's inferred scheme carries its accumulated method constraints, so the constraint set
enters the §8.1 interface hash. Adding one method call inside an unannotated `pub` function then
changes its interface and re-checks every importer — churn §8.1 exists to prevent. Roc does not pay
this because its caching boundary is not the inferred scheme in the same way, and because its
answer to both §2.1 and §2.2 is an annotation habit beni deliberately declined to require.

This is the load-bearing finding of the report. It is not an argument that static dispatch is
expensive in the abstract; it is an argument that it is expensive **given two decisions beni has
already made**, and that adopting it means reopening at least one of them.

### 2.4 The error messages are still rough

Twenty months in, a week before this report: a missing `to_hash` constraint on a *caller* is
reported at a line inside the *callee*, which the reporter describes as "a game of
spot-the-difference" with more complicated signatures.

Jonathan, #bugs › Confusing error locations when generics are underconstrained, 2026-09-15
<https://roc.zulipchat.com/#narrow/channel/463736-bugs/topic/Confusing.20error.20locations.20when.20generics.20are.20underconstrained/near/624395790>

Anton's reply — that he is not sure which location would be *less* confusing — is the honest
statement of the difficulty. Related: groups of method constraints still cannot be named, so every
signature respells `where [id.is_eq : …, id.to_hash : …]`; Luke Boswell, #ideas › Thoughts on UI,
2026-07-29: *"We have talked about maybe supporting aliases for this use-case … but we decided to
see how much of an issue not having it would be in practice"*
(<https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/Thoughts.20on.20UI/near/613313503>).

## 3. Return-type dispatch, and what derivation costs in language surface

The prize that motivates the whole feature is decoding into a type. It is also the case that cannot
be expressed with values, because at the dispatch point no value of the dispatched type exists:

> "when the thing you want to express is 'use type information only to select a function to run' and
> there's no value we could use to infer that type, it's not possible to offer that feature in a way
> where you only use values and not types, because no value exists at that point"

Richard Feldman, #ideas › static dispatch revisions, 2025-10-04
<https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/static.20dispatch.20revisions/near/543088654>

Dispatching on the return type is not enough either, because a decoder returns `Result`:

> "if we dispatch on the return type, we'll go look for the decoding implementation of your custom
> type in `Result.roc`, which of course won't be where it is"

Richard Feldman, #ideas › static dispatch - dispatch on return types, 2025-01-31
<https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/.E2.9C.94.20static.20dispatch.20-.20dispatch.20on.20return.20types/near/497039228>

Roc's answer is `module(a).decode(bytes)`, naming a type variable *in an expression*. Three costs
were accepted along with it:

- **It requires a type annotation**, in a language whose author says *"I'm of course very opposed to
  requiring type annotations anywhere"*
  (<https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/.E2.9C.94.20static.20dispatch.20-.20dispatch.20on.20return.20types/near/497045301>).
- **It is the only place in Roc where a type is mentioned in a value** — Sam Mohr, same thread,
  *"a big barrier to cross"*
  (<https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/.E2.9C.94.20static.20dispatch.20-.20dispatch.20on.20return.20types/near/497043268>).
- **It is strictly weaker than the abilities it replaced.** Decode-then-transform is rejected
  because the dispatched variable must appear in the enclosing function's own type; Brendan
  Hansknecht: *"Yeah, just a loss of power compared to Abilities"*
  (<https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/.E2.9C.94.20static.20dispatch.20-.20dispatch.20on.20return.20types/near/499391153>).

And the whole complication exists for this one case. Feldman, a year earlier: *"if we only ever had
these in the 'first argument' position, then we would totally just do the nicer syntax … but then we
lose out on being able to decode directly into things, which would be a way bigger downside"*
(<https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/static.20dispatch.20-.20decoding/near/482219817>).

## 4. Nominal typing: why it is needed, and how little of it Roc actually needs

### 4.1 Why dispatch needs a name

`x.compare(y)` must resolve to one function, and the resolution rule is "look in the module where
`x`'s type is declared." A structural type is declared nowhere: `{ x : Int, y : Int }` can be
mentioned by twelve modules and is owned by none, so the constraint has no reduction step (§1.2) and
never discharges. Three consequences, none patchable:

- **Identity.** Structural types are equal when their shapes are equal, so dispatch keyed on shape
  would give unrelated coincident types the same methods, and adding a field would silently change
  which function runs.
- **Coherence becomes syntactic, and that is the whole saving.** The orphan-instance problem is what
  makes typeclasses expensive: Haskell needs global instance uniqueness, Rust needs orphan rules.
  "Methods live where the type is declared" yields exactly one candidate by construction — no global
  check, which is precisely why the mechanism survives separate compilation (§1.2). That property is
  bought with nominality.
- **Nothing else dispatches on types.** Rust needs a nominal `impl` target, Swift extends nominal
  types, Haskell instances attach to named constructors. The structural languages that dispatch —
  TypeScript, Go, JS — dispatch on *values* at runtime, which is [`09`](09-adhoc-polymorphism-survey.md)
  §3's finding restated: value-directed dispatch is free in JS, type-directed needs a name.

The exception is a **closed** set: `number`, `appendable` and `equatable` need no nominality because
the compiler owns every implementation and discharges the obligation post-solve
([`checker.md`](../checker.md) §Appendix B). Shape suffices when you also control the candidate
list. Open user extension is what needs the name.

### 4.2 Roc's four mechanisms

§708 of `fast-compiler.md` rejects Roc's type modules on the grounds that attaching functions to
types "only means something if calls can be resolved *from* a type." That is right about the
mechanism and wrong about the scope of what it forces, because Roc arranged for most code to need
no nominal type at all.

1. **Structural shapes get the well-known methods derived automatically.**
   `static-dispatch.md:72-75`: *"Roc can derive implementations of `is_eq`, `to_hash`, `parser_for`,
   `encoder_for`, `map`, and `map!`. **Structural types receive each derived method automatically
   when their shape supports it.** A nominal or opaque type must opt in."* A plain record compares
   with `==`, works as a `Dict` key, and JSON-encodes and decodes with no nominal type declared.
2. **Nominal types opt in per method with `method : _`**, or supply a body for custom behaviour.
   Nominality buys *different* semantics from the structural default, not the default itself.
3. **Structural literals lift into nominal types by annotation**, so wrapping costs nothing at
   construction sites: `p1 : Point` then `p1 = { x: 1, y: 2 }` with no constructor call
   (`static-dispatch.md:149-150`). The known limit is destructuring — Jared Ramirez, #bugs,
   2026-07-17: *"In many cases, the compiler can figure out how to lift structural values … into a
   nominal, but not always"*
   (<https://roc.zulipchat.com/#narrow/channel/463736-bugs/topic/Annotation.20dependent.20inference.20when.20destructuring.20opaque/near/611341347>).
4. **A second operator for types you do not own.** `.` resolves only in the type's own module; `->`
   calls an ordinary in-scope function with the receiver as first argument — `1->my_add(2)` (Jonathan,
   #beginners › How to define a static method, 2026-04-08,
   <https://roc.zulipchat.com/#narrow/channel/231634-beginners/topic/How.20to.20define.20a.20static.20method/near/584141818>).
   `.` deliberately does **not** fall back to local functions, because *"I define a new local
   function, not realizing I have code elsewhere in that module which happens to use an external
   function with the same name, and bad things silently happen"* (Richard Feldman, #ideas › static
   dispatch - proposal, 2024-11-16,
   <https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/static.20dispatch.20-.20proposal/near/482808502>).

### 4.3 What stays unsolved

Orphans are refused, not solved: you cannot make a type you do not own satisfy a `where` constraint.
The fallbacks offered on Zulip are the ones beni already uses — pass the function, or build a record
of functions, which is a hand-written dictionary.

And the module-shape pressure §708 worried about is real, just narrower than "everything becomes
nominal". Roc's own people describe it from both sides. Feldman frames it as a benefit: static
dispatch *"creates a natural incentive to organize each module around a particular type"*
(<https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/static.20dispatch.20-.20abilities.20concern/near/482878020>).
Jasper Woudenberg's objection in the same thread is that moving a type into its own module later
becomes a breaking API change
(<https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/static.20dispatch.20-.20abilities.20concern/near/482898870>);
Brendan Hansknecht expects *"a lot of structural types that probably should just be bags of data
turned into nominal types just to get static dispatch"*
(<https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/.E2.9C.94.20Static.20Dispatch.20-.20without.20nominal.20typing.3F/near/491299818>);
and Sky Rose, reacting to the October 2025 revision: *"By forcing the paradigm of one type for file,
it's not just a tool you can reach for when OOP makes sense for your problem, it's something you
have to do even when it doesn't fit"*
(<https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/static.20dispatch.20revisions/near/543126923>).
§708's conclusion survives; its reasoning should cite this rather than the type-module syntax alone.

## 5. What beni already has

| Roc mechanism | beni today | Gap |
|---|---|---|
| derived `is_eq`/`to_hash` for structural shapes | `foreign eq` over a structural walk, `equatable` discharged post-solve (`core/Basics.beni:141`, `checker.md` App. B) | none in kind; `compare` is missing by choice, not by mechanism |
| `->` receiver-first call on unowned types | `\|>` lowered first-argument-first: `e \|> f a` → `f e a` (`language.md` §8, desugar step 2) | none |
| annotation lifts a record literal into a nominal type | `type T = T { … }` needs an explicit constructor | ergonomic, small |
| derived `parser_for`/`encoder_for` | absent | **real**, and reachable without dispatch (§6) |
| `where`-constrained user method names | absent | **real**, and not reachable without dispatch |

The ergonomic tax the absence imposes is measurable rather than theoretical: 19 comparator-passing
sites in `bench/corpus`, 20 in `tests/corpus`, and `core/Dict/String.beni` and `core/Dict/Int.beni`
exist as pre-bound wrappers papering over it. None of that tax requires dispatch to remove — a
structural `compare` foreign with a `comparable` obligation, in the exact shape `equatable` already
has, restores `List.sort` and `Dict.empty` without a comparator. What blocks it is a separate,
independent taste decision recorded in §3.1 and in [`07`](07-roc-static-dispatch.md): Feldman's
argument that `string1 < string2` compiling silently is a footgun. That decision should be argued on
its own merits, not carried by the dispatch decision.

## 6. What this means for §3.1

The decision to exclude static dispatch **stands**, and three of its four stated reasons should be
withdrawn or rewritten:

- **Withdraw the runtime-cost row as stated.** On a JS target the runtime argument mildly favours
  adopting it (§1.4, §1.5). What is defensible is the *output-size* argument, and only against the
  record encoding of multi-method dictionaries.
- **Withdraw the Roc-throughput citation from this row.** It belongs to
  [`10`](10-monomorphisation-and-incremental.md) and to monomorphisation, not to dispatch (§1.1).
- **Withdraw the prototype-dispatch row.** Static dispatch does not use prototypes (§1.3).
- **Add the row that carries the decision**: static dispatch's cost lands on inference, and beni's
  optional-annotation interface (§3.1, decided 2026-09-13) is the property that makes it expensive
  here and cheap in Roc (§2.3).

And **§3.1's closing claim that the mechanism is additive should be corrected.** It is additive to
the type system and invasive to the module system: adopting it means either accepting that user
record types cannot carry user-named methods, or moving beni toward nominal-by-default, against the
transparent-alias and free-function-module decisions already recorded (§4, §708).

Two things follow that are worth doing regardless of whether the decision is ever revisited:

1. **Generalise obligation discharge.** `checker.md` already runs `number`, `appendable`,
   `equatable` and `interpolatable` as post-solve obligations. Making that a general mechanism
   rather than a hardcoded set costs nothing now and is what makes the door genuinely additive
   rather than nominally so.
2. **Separate the codec question from the dispatch question.** Structural derivation of
   encoders/decoders is Roc's mechanism 1, and mechanism 1 needs no nominality and no dispatch —
   only a way to name the target type. Whether beni wants hand-written codecs (Elm's answer, where
   the friction is arguably load-bearing) is a question that can be decided on its own.

## 7. Could not determine

- **No measurement of beni's dictionary density.** §1.1 argues PureScript's 25–35% does not
  transfer. How much traffic a realistic beni program would actually generate was not measured, and
  `bench/corpus` was counted for comparator sites only.
- **No benchmark of `structuralEq` against a specialised comparison.** §1.5 asserts the current
  route is slower at runtime on the strength of what the code does — a worklist, an `Object.keys`
  allocation per node, a megamorphic property access — not on a measurement. The inversion in that
  table is reasoned, not benchmarked.
- **No numbers on Roc's check-time cost for dispatch specifically.** The build-time survey in
  #announcements reports whole-pipeline timings; nothing isolates constraint solving with and
  without `where` clauses.
- **Whether Roc's principality fix shipped, and what it cost.** §2.2 records the design as stated in
  August 2026; the compiler was not read to confirm the implementation, and no later message
  reporting on it was found.
- **No primary source on how often return-type dispatch is actually used.** The feature carries the
  costs in §3 on the strength of decoding alone; whether real Roc programs reach for `module(a)`
  outside codecs could not be established.
- **The `->` operator is not in the vendored langref.** Its behaviour in §4.2 is sourced from Zulip
  and from `test/echo/all_syntax_test.roc`, not from the reference documentation.
