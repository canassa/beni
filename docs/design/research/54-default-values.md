# 54 — Default values: how languages give them, and how they spell them

*2026-10-03. Two research passes for `language.md` §11.8's optional props, findings only; the
decision is recorded there. Part 1 is how ML-family and related languages give default arguments
and fields and what went wrong; Part 2 catalogues every distinct spelling found, across mainstream
and niche languages. Checked by the manager against primary sources: Roc's August 2026 design (the
Zulip thread is dated 2026-08-14, not June as Part 1 says) and Richard Feldman's "defaulting makes
sense for nominal types only". **Corrected:** Roc issue #6423 ("Optional record fields can't be used
in two different ways") was closed as *not planned*; neither part may be read as showing Roc withdrew
its old `{ b ? 1 }` because of it, nor that a maintainer acknowledged it as a defect. Everything else
is the agents' reading: each claim is a lead with a source. Font coverage of the candidate symbols
was checked on one machine (DejaVu Sans Mono, FreeMono, JetBrains Mono): `¿` everywhere, `⁇` absent
from JetBrains Mono.*

# Part 1 — default arguments and fields in ML-family languages


## Roc

**Two separate features**, landed 2026-06 in the new compiler, after an older design was
scrapped:

- **Optional fields**, `field ?: Type`: `Attributes : { count : U64, label ?: Str }`. May be
  present or absent at runtime; presence is itself data. Accessed via `.?` (returns
  `Try(Str, [MissingField])`), with `??` supplying a fallback. Desugars (Karl, Roc Zulip
  `#397893-announcements`, ["optional + defaulted record
  fields"](https://roc.zulipchat.com/#narrow/channel/397893-announcements/topic/optional.20.2B.20defaulted.20record.20fields/near/616446901),
  2026-06) to a closed union `[#Missing, #Present(val)]`.
- **Defaulted fields**, `field ?? defaultExpr`, on a *nominal* record only (`:=`, not `:`):
  `RequestOptions := { retries : U8 ?? 3, timeout_ms : U64 ?? 5000 }`. Always present after
  construction — ordinary `.field` access, no `Try`. The default is evaluated lazily, only for
  a construction that omits the field.

**Restrictions, and why:**
- Defaults are initially **literal-only**, by scope-cutting choice: Jared Ramirez (same Zulip
  thread, msg
  [616558108](https://roc.zulipchat.com/#narrow/channel/397893-announcements/topic/optional.20.2B.20defaulted.20record.20fields/near/616558108)) —
  "i think we can do any pure expressions for rhs of `??`. i went with literal only to keep to
  cut scope." Feldman confirmed arbitrary pure expressions are plausible later.
- **`??` is nominal-only, never structural type aliases** — decided *because of a bug found
  live in the thread*: two structurally identical records with different default literals
  failed to unify, because the default is part of the type's identity. Feldman: "defaulting
  makes sense for nominal types only" (msg
  [616568172](https://roc.zulipchat.com/#narrow/channel/397893-announcements/topic/optional.20.2B.20defaulted.20record.20fields/near/616568172));
  Ramirez agreed it "solves these problems."
- **Optional fields are forbidden across the host/FFI boundary** (no foreign counterpart to
  `[#Missing,#Present]`); defaulted fields cross fine since they're always present.
- An unresolved name inside a `??` default crashes compilation redundantly at *every*
  construction site rather than once at the declaration — const-evaluation of the default runs
  per site ([#11922](https://github.com/roc-lang/roc/issues/11922)); nested `??` defaults
  (a default itself a record with its own defaulted, omitted fields) can crash the lowering
  pass entirely ([#11946](https://github.com/roc-lang/roc/issues/11946)).
- Empty-literal `{}` satisfies a nominal type only once every omitted field is optional or
  defaulted — required tracking exact per-construction omissions and a cycle-rejecting design
  ([#11173](https://github.com/roc-lang/roc/pull/11173), closing
  [#11024](https://github.com/roc-lang/roc/issues/11024)).

**History, closest precedent to a pattern-level default.** The older Roc compiler had exactly
beni's candidate syntax — a bare `?` default written directly in a record type/pattern, e.g.
`add : { a : U64, b ? U64 } -> U64; add = \{ a, b ? 1 } -> a + b`. It was filed as a type-system
defect, [roc-lang/roc#6423](https://github.com/roc-lang/roc/issues/6423), "Optional record
fields can't be used in two different ways": the same declared type was callable both
*with* and *without* the field supplied, which the reporter called a hole in the type checker;
closed "not planned" rather than fixed. Separately, per Feldman, the "default fields" concept
"had type problems and was confusing," so the Zig rewrite initially dropped it for static
dispatch and builder patterns, before the `??`/`?:` split above was specified. Eric Rogstad
proposed the actual split, `?:` optional vs `??` defaulted, "to prevent semantic confusion
between the two concepts"; Ramirez agreed combining them "doesn't make semantic sense."

**Serialization**: JSON encoding of optional fields maps to key presence; `null` is explicit
and distinct from absent (Feldman).

---

## OCaml

**Syntax.** `?x` in a signature (type `'a option` inside the body) or `?(x = default)` for a
concrete default (bare type, not wrapped). Caller passes `~x:v`/`?x:v` (the latter forwards an
existing option) or omits it — https://ocaml.org/docs/labels.

**Core problem: erasure vs. currying.** Because OCaml functions are curried, an application
supplying no positional argument after the optional one is syntactically indistinguishable
from a partial application. Rule: "an optional argument is erased as soon as the first
positional argument defined after it is supplied." With no later positional argument, the
compiler can never decide to apply the default, and emits **Warning 16: "this optional
argument cannot be erased"**
([discuss.ocaml.org/t/8131](https://discuss.ocaml.org/t/warning-16-optional-argument-cannot-be-erased/8131),
[t/8817](https://discuss.ocaml.org/t/compiler-question-why-cant-i-mix-optional-and-labelled-arguments-without-getting-an-erasure-warning/8817)):
"It's because of the interaction between automatic currying and optional arguments. ... if an
optional argument is not provided, is it because the programmer wants the function to be
partially applied or not?" Fixes: reorder so a mandatory positional argument follows the
optional ones, or add a trailing `()` unit parameter purely so the compiler has something to
"complete" the application on — Real World OCaml devotes a section to this, "Optional
Arguments and Partial Application"
(https://dev.realworldocaml.org/variables-and-functions.html). Related:
[ocaml/ocaml#5706](https://github.com/ocaml/ocaml/issues/5706), "Erasing of optional
arguments in interfaces"; a `-principal` flag exists partly because labelled/optional-argument
inference is not always *principal* (the inferred type can depend on constraint-solving
order).

---

## ReScript

**Syntax.** `~x=?` makes a labelled argument optional; inside the function it has type `option<t>` (`None` if omitted). `~x=default` gives a concrete default; inside the function it has the bare type `t`, not `option<t>`. The signature-as-seen-by-the-caller differs from the signature-as-seen-in-the-body (documented explicitly: "the type signature is different, depending on whether you're writing out the function type, or the parameter type annotation") — https://v11.rescript-lang.org/docs/manual/v11.0.0/function. `~x=?expr` at a call site forwards an existing `option` value without unwrapping it (used heavily for prop-forwarding in components).

**JSX.** `@react.component` props compile to one record-shaped function call; optional props use the same `~x=?` mechanism, and a bare prop omitted in a `<Comp />` tag is treated as `None`. A maintainer (forum, "Default value for optional prop in jsx4?") states there's conceptually "no difference" from pre-v4 JSX as long as `@react.component` is used, but a poster who needs to pass components themselves as props (so cannot use the `@react.component` sugar and must work with the underlying record type directly) reports this as a real ergonomic break — https://forum.rescript-lang.org/t/default-value-for-optional-prop-in-jsx4/4315.

**Inherited OCaml problem, and its fix.** Pre-v11 (curried-by-default) ReScript inherited OCaml's exact erasure ambiguity: a function with a trailing optional labelled argument needed `let myFun = (~name=?, ())` — an explicit trailing `()` — "to help the compiler understand when function application is finished." **ReScript v11's switch to uncurried-by-default removed this need entirely**: "with uncurried mode the 'final unit' pattern is not necessary anymore, while you still can use optional or default parameters" — https://rescript-lang.org/blog/uncurried-mode/. Uncurried mode also changed how trailing `undefined` arguments are passed to interop/external bindings ("trailing `undefined`s are automatically omitted"), because a JS callee can observe `fn(1)` vs `fn(1, undefined)` as different call shapes.

---

## F#

Optional parameters use `?x` and are, per Microsoft's F# docs
([Parameters and Arguments](https://learn.microsoft.com/en-us/dotnet/fsharp/language-reference/parameters-and-arguments)),
"permitted only on members, not on functions created by using `let` bindings." Internally
`?x : T` is sugar for `T option`; the body resolves it with `Some`/`None` matching or
`defaultArg x defaultValue` — a plain function call the body makes explicitly, evaluated each
time the body runs, not a compiler-managed default-expression slot the way OCaml/Koka/Lean
have. A `[<Struct>]` variant uses `ValueOption`/`defaultValueArg`. For .NET interop,
`[<Optional; DefaultParameterValue(v)>]` (F# 4.1, design doc
[FS-1027](https://github.com/fsharp/fslang-design/blob/main/FSharp-4.1/FS-1027-complete-optional-defaultparametervalue.md))
makes a parameter look optional to C# callers specifically. The same docs page: "Named
arguments are allowed only for methods, not for `let`-bound functions, function values, or
lambda expressions."

**Why methods-only**: the reference ties this to F#'s two calling conventions — "Methods
usually use the tuple form... The curried form is most often used with functions created by
using `let` bindings." Members are called at a single overload-resolved, tuple-style call site
where "omitted" has one unambiguous meaning; `let`-bound functions are curried values that can
be partially applied and passed around with no distinguished call site at which an omitted
argument's meaning is fixed — the same currying/erasure tension OCaml names explicitly for
warning 16. Symptom: [fslang-suggestions
#745](https://github.com/fsharp/fslang-suggestions/issues/745) — `static member M ?x = ()`
cannot be piped as `1 |> C.M` because the optional parameter breaks the plain function-value
shape the pipe operator expects; closed "not planned." No suggestion was found proposing
optional args for `let`-bound functions with a reasoned rejection — the methods-only line
reads as settled foundational design, not a live debate.

---

## Haskell

**No language-level default arguments or default record fields exist.** Nothing in the
Haskell Report or GHC's feature set provides them; `ghc-proposals/ghc-proposals` has no
"default field value" proposal — its record-related proposals (RecordDotSyntax #282,
NoFieldSelectors #160, record-set-field #158, OverloadedRecordFields #23) are all about field
*access/update* syntax, not defaults at construction.

**Origin and shape of the idiom.** Neil Mitchell's 2008 post ["Optional Parameters in
Haskell"](http://neilmitchell.blogspot.com/2008/04/optional-parameters-in-haskell.html) is the
earliest source for the standard pattern: a record of defaults, overridden with record-update,
`foo defFoo{s = "Goodbye", b = False}`, wrapped in a type class — `class Def a where def :: a`
— so inference picks the right default. He names the **field-namespace-collision problem**
directly: "a general problem with records, which as yet has no good solution," recommending
long type-prefixed field names as the (pre-`DuplicateRecordFields`) workaround. Verdict:
"optional parameters in Haskell are not quite as neat as in other languages."

**`data-default` on Hackage** productized this: `class Default a where def :: a`. Being an
ordinary type class, **it has room for only one `def` per type** — a second sensible default
for the same `Config` needs a `newtype` wrapper — and instances for third-party types require
**orphan instances**, a known wart independent of this package. Mark Karpov: "For simple types
like `Int` or `Bool` there is no universal default value because the concepts they represent
are too general" ([markkarpov.com](https://markkarpov.com/post/data-default.html)); Haskell
Discourse: "The class is lawless. There is often not a clear answer to what a Default should
be" (is `Default Int` 0 or -1?); real users cited there: xmonad, HMock.

**Builder-pattern alternative**: where one global default isn't enough, the ecosystem's
answer is the same as Elm's — a builder/combinator API (`optparse-applicative`'s style for CLI
option records) rather than a second type-class mechanism.

---

## Contrast: Scala, Kotlin, Swift, Rust (brief)

**Scala**: `def log(msg: String, level: String = "INFO")`; an overriding method may not
redeclare a different default than its base ("the implementation is always the one in the
superclass"), and defaults disappear at the Java interop boundary —
https://docs.scala-lang.org/tour/default-parameter-values.html.

**Kotlin**: `fun f(x: Int = 0)`; because defaulted-parameter calls compile to one method taking
every parameter, Java callers see no overloads unless `@JvmOverloads` synthesizes them —
https://kotlinlang.org/docs/functions.html#default-arguments.

**Swift**: defaults are legal on concrete methods and protocol *extensions* but **forbidden on
protocol requirements themselves**, because "default arguments are determined statically" while
protocol dispatch is dynamic, which can make a default silently disagree between a
protocol-typed and a concrete-typed reference to the same value — Swift Forums,
https://forums.swift.org/t/why-are-default-arguments-not-allowed-in-protocols/36399, with a
worked case at https://oleb.net/blog/2016/05/default-arguments-in-protocols/.

**Rust**: no default-argument syntax; the idiom is the `Default` trait plus struct-update
syntax, `Options { timeout: d, ..Default::default() }`. A 2020 "Pre-RFC: Optional Fields"
proposing `bio: String?` sugar drew pushback and went nowhere —
https://internals.rust-lang.org/t/pre-rfc-optional-fields/14087; the standing rationale against
language-level defaults is that "the reader of the code doesn't know that there are potentially
more parameters" — https://www.thecodedmessage.com/posts/default-params/.

---

## Comparison table

| Language | Where it lives | Pattern-level? | Evaluated | Visible in type? | First-class / partial application |
|---|---|---|---|---|---|
| Roc (optional `?:`) | record field type | no (via `.?` accessor) | n/a (presence is runtime data) | yes — closed union `[#Missing,#Present]` | n/a, not a function param |
| Roc (defaulted `??`) | nominal record field type | no | per-omitting-construction, pure/literal, compile-time-evaluable | not visible after construction (field always present) | n/a |
| OCaml | function parameter | no | per call that omits it | yes, as `?x:'a` / erased to `'a` | broken by currying ambiguity unless a trailing positional/unit param exists (Warning 16) |
| ReScript (curried, pre-v11) | function parameter | no | per call | yes (body sees `option`, caller sees bare type) | same OCaml problem, needed trailing `()` |
| ReScript (uncurried, v11+) | function parameter | no | per call | yes | fixed — no trailing unit needed once uncurried |
| F# | method parameter only | no | per call | yes, `?x` option-typed to callee | **not available on `let`-bound functions/lambdas at all** — curried form incompatible with named/optional args |
| Lean 4 | function parameter (`optParam`) AND structure field | **yes — defaults persist into patterns** | at elaboration time; tactic-based defaults (`autoParam`) run then too | desugars to `optParam α default` in the type | preserved in function *type*; interacts awkwardly with named-argument "argument suppression" (see below) |
| Koka | function parameter | no | — (not confirmed from primary source) | grammar shows `[= expr]` on parameters; distinct `?`-prefixed *implicit* parameters are a separate ad-hoc-polymorphism feature, not plain defaults | not confirmed |
| PureScript | none (row-type encoding only) | no | compile time (row/constraint solving) | yes, via row/Union constraints, not a dedicated feature | library-level (`Record.merge`), not language defaults |
| Haskell | none; `data-default`'s `def` + record update | no | type-class instance lookup, compile time | `Default a => a`, abstracted away | n/a — whole-record substitution, not an argument mechanism |
| Elm | none — deliberate | n/a | n/a | n/a | community: builder pipelines / `Optionals -> Optionals` functions |
| Gleam | none (proposed 2021, still open/unimplemented) | n/a | proposed: per call, literals only, tail-positioned | would be in the signature | proposed: defaults drop once the function degrades to a plain value, same as labels already do |
| Scala/Kotlin/Swift (contrast) | parameter default, but **fixed at the static/declared signature** | no | per call | yes | breaks under dispatch: override/conformance can't redeclare the default, or (Swift) can't have one in a protocol requirement at all |
| Rust (contrast) | none; `Default` trait + `..Default::default()` struct update | no | trait method call, compile-time dispatched | `Default` bound, not per-field | n/a — whole-value substitution; builder pattern is the escape hatch for partial overrides |

---

## Lean 4 detail

Syntax: `(x : α := default)` is sugar for `x : optParam α default`; the elaborator supplies `default` when the argument is missing. `autoParam` is the same mechanism but runs a **tactic** instead of a literal/expression. Structure fields take the identical `:=` default syntax; "every field that does not have a default value must be provided." **Defaults are visible inside pattern matching**: "if a pattern does not specify a value for a field with a default value, then the pattern only matches the default" — i.e. an under-specified structure pattern is not a wildcard over that field, it specifically requires the default value to match. Source: https://lean-lang.org/doc/reference/latest/Terms/Function-Application/ and the structures reference surfaced via search (lean-lang.org/doc/reference "Inductive Types" page).

Separately, a maintainer RFC/issue, https://github.com/leanprover/lean4/issues/5397, documents a **named-argument interaction bug-turned-design-debate**: supplying a named argument (e.g. `self := inst`) silently makes *other* explicit parameters that depend on it become implicit — "it is unclear to the user which parameters depend on implicit parameters" — and this persists even in fully-explicit (`@`) mode, which contradicts the "explicit mode supplies everything explicitly" invariant elsewhere in the language; users "often feel like it is an elaboration bug." The proposed fix restricts the auto-implicit-suppression behavior to structure-projection syntax specifically, rather than general named arguments, trading away generality for predictability.

---

## Koka

From the formal grammar (`doc/spec/spec.kk.md`): a parameter is `[borrow]? paramid [: type]? [= expr]?` — i.e. a bare `= expr` suffix gives a default, independent of the pattern/type annotation. A *different*, `?`-prefixed `implicitid` parameter form exists for a distinct feature (implicit/ad-hoc-polymorphic parameters — see open issue https://github.com/koka-lang/koka/issues/336, "Existential Default Named Parameter / Implicit Parameters for ad-hoc polymorphism"), which should not be conflated with ordinary optional-with-default parameters. The prose explanation of evaluation timing, whether a default can reference earlier parameters, and higher-order/partial-application behavior could not be retrieved from a live, fetchable primary source during this research (the long-form book page did not return that section's body); this is a gap, not a confirmed "no".

---

## PureScript

PureScript has **no language feature** for default record values. Row polymorphism plus the `purescript-record` library (`Record.merge`, `Record.union`, `Record.Builder.merge`, gated by `Union`/`Nub` row constraints) is the idiomatic substitute: merge a "defaults" record into a partially-specified one. Problems reported:
- Expressing "a record that *may* contain some of a set of labels" (a prerequisite for a generic "apply defaults to whatever subset is given" function) needs an **existential**, not a `forall`, quantifier over the row, which the language doesn't give you directly — "there exists an `a` ... which is a subrow" vs. the function "does not work for all subrows." Source: https://rubenpieters.github.io/programming/purescript/2018/03/02/subrecord-purescript.html.
- `Record.merge`-family functions favor their *first* argument on key conflicts while the corresponding `Record.Builder` functions favor their *second*, an inconsistency the library's own issue tracker flags as confusing/bug-prone: https://github.com/purescript/purescript-record/issues/55, https://github.com/purescript/purescript-record/issues/38 ("Builder.merge could be 'safer'" — i.e. it lacks the `Union` constraint that would make conflicting-type merges a compile error instead of silently picking one).

---

## Elm

**No defaults, by design** — confirmed by the complete absence of any such feature and by sustained community-proposal rejection rather than by a located direct Evan Czaplicki quote (none was found specifically against optional/named arguments in a talk transcript during this research; that attribution could not be verified).

**Discourse record of the problem and the community's answer.** A direct syntax proposal, "Optional Key Records," https://discourse.elm-lang.org/t/optional-key-records-syntax-proposal/2634, by Dillon Kearns (maintainer of elm-graphql) proposed `{ ? | first = Just 100 }` record literals defaulting absent fields to `Nothing`. It drew no recorded response from Evan Czaplicki or other core-team members in the thread, and a community member ("Punie") objected on the grounds that giving `Maybe` *compiler-magic* defaulting would be an ad-hoc special case ("What if someone would like some other type to have a default `empty` value? ... record syntax should stay minimal"), comparing it to the already-regretted magic type variables `comparable`/`appendable`. The thread closed without a language change. A second thread, "Pattern for default values," https://discourse.elm-lang.org/t/pattern-for-default-values/3933, collects the idiomatic non-language answers: (1) a `defaults` record plus `{ defaults | field = x }` record-update syntax for the simple case; (2) the "Optionals → Optionals" pattern — pass a `(Optionals msg -> Optionals msg)` transform function, defaulting to `identity`, so the API never widens positionally; (3) an options-list of a custom type; (4) the builder pattern.

**Builder pattern, concretely** (from https://sporto.github.io/elm-patterns/basic/builder-pattern.html, reinforced by https://elm-radio.com/episode/builder-pattern/): define an `Args` record, a `newArgs` constructor seeding defaults, and `withX : X -> Args -> Args` modifiers, chained with `|>`: `Button.newArgs "Click me" |> Button.withIsEnabled False |> Button.withHexColor "#123" |> Button.btn`. Stated rationale: "adding new arguments to `Args` doesn't require us to change every caller" — the builder absorbs new optional fields without breaking existing call sites, which plain positional/record-literal APIs cannot do. elm-ui is cited as a real, widely-used package following this shape for its `Element` attribute API.

---

## Gleam

**No defaults as of this research**, confirmed by the language tour (tour.gleam.run/functions/labelled-arguments): labelled arguments exist and are reorderable/optional-to-*write* at a call site, but no default-value mechanism is mentioned, and "there is no performance cost... it does not allocate a dictionary."

**Proposal status: open, unresolved, since 2021.** GitHub Discussions #1122, "Optional arguments with defaults" (opened by maintainer Louis Pilfold) — https://github.com/gleam-lang/gleam/discussions/1122. Proposed syntax: `pub fn log(message: String, at level: LogLevel = Info)`. Design constraints the thread converged on: optional parameters must be tail-positioned after all required parameters; must be *labelled* (to avoid positional-call ambiguity, mirroring the OCaml/F#/ReScript concern above, but solved by mandatory labels rather than a trailing unit); defaults should initially be literal-only (constants), with discussion of whether arbitrary expressions should ever be allowed. Pilfold's own framing: *"optional arguments are a compile time feature for named functions"* that must degrade predictably when the function is converted to a value/closure (consistent with how Gleam already drops labels when a function is used as a first-class value) — i.e. a function reference loses its optionality, the same way it loses its labels. He also stated a simplicity principle: *"we try to only have one way of doing each thing"* as a reason to be cautious about adding a second argument-passing convenience on top of labels. As of the research date the discussion is **still open with no implementation**, not formally rejected.

---

## Recurring problems, by who reported them

1. **Currying makes "omitted optional argument" ambiguous with "partial application," and every language resolves it by restricting where defaults are allowed, not with a general fix.** OCaml needs a trailing positional/unit marker (warning 16); pre-v11 ReScript inherits the identical requirement, and ReScript's own team calls the resulting `let myFun = (~name=?, ())` idiom something that "doesn't make any sense at all" (ryyppy) — ReScript v11 fixed it by dropping currying-by-default; F# instead disallows optional/named parameters on curried (`let`-bound) functions altogether, restricting the feature to methods' tupled convention; Gleam's (unimplemented) proposal sidesteps it by making labels mandatory rather than positional.
2. **Structural vs. nominal typing conflict when the default is part of the type.** Roc: two structurally-identical defaulted records with different default literals failed to unify; the fix was to restrict `??` defaults to nominal records only (Roc Zulip, Feldman/Ramirez, 2026-06).
3. **Compile-time evaluation of defaults produces bad diagnostics or crashes.** Roc: an unresolved name inside a `??` default crashes at every construction site instead of once at the declaration (GitHub #11922); nested `??` defaults can crash the lowering pass entirely (#11946).
4. **A "one default per type" type-class abstraction has no principled answer for simple types, and no clean per-field override.** Haskell's `data-default`: "For simple types like `Int` or `Bool` there is no universal default value" (Karpov); "There is often not a clear answer to what a Default should be" (Haskell Discourse). Rust's `Default`+struct-update has the adjacent problem that all unspecified fields must come from one `..` source as a whole value, so individual defaults can't be cherry-picked without extra plumbing (rust-lang/rust#63538).
5. **Named-argument sugar silently changing argument explicitness.** Lean 4: supplying one argument by name can make *other*, unrelated explicit parameters become implicit without being asked, confusing enough that users file it as a suspected compiler bug (GitHub #5397).
6. **Row-polymorphic encodings of "default record" need existential types the language doesn't expose ergonomically**, and the merge-helper libraries have inconsistent left/right-bias on field conflicts. PureScript (`purescript-record` issues #38, #55; Pieters' subrecords post).
7. **"Keep the surface minimal" is the recurring counter-argument that kills or narrows a proposal.** Elm (Discourse "Optional Key Records" rejected on this ground), Gleam (Pilfold's "one way of doing each thing"), Roc (narrowed repeatedly: nominal-only, literal-only initially, FFI-forbidden for optional fields).
8. **No-defaults languages converge on the same two user-level idioms**: a defaults record + record-update, and a chained builder/pipeline (`Thing.new |> Thing.withX |> Thing.withY` in Elm; the builder pattern as Rust's own fallback; `optparse-applicative`-style combinators in Haskell). Both exist specifically *because* the language refused to add defaults as syntax.
9. **Defaults and method dispatch (static or dynamic) don't compose.** Swift forbids default values in protocol requirements because "default arguments are determined statically" while protocol conformance is dynamic (Ben Cohen); Kotlin and Scala both forbid re-specifying a default in an overriding method/class for the same reason. A default is a property of a *call site's* static type; dispatch is per-implementor.

# Part 2 — a catalogue of default-value spellings

No recommendations. Grouped by distinct spelling; duplicate spellings merged across languages.

## Part 1 — Defaults INSIDE a destructuring/match PATTERN (most relevant)

| # | Form | Languages | Position | Expr or constant | May reference siblings |
|---|------|-----------|----------|-------------------|------------------------|
| P1 | `const { a = 1, b = 2 } = obj` | JavaScript, TypeScript | object destructuring pattern (decl/param/assignment) | arbitrary expr, lazy (fires only on `undefined`) | yes, left-to-right (TDZ) |
| P2 | `const [a = 1] = arr` | JavaScript, TypeScript | array destructuring pattern | arbitrary expr, lazy | yes, left-to-right |
| P3 | `const { a: b = 1 } = obj` | JavaScript, TypeScript | object destructuring, rename+default | arbitrary expr | yes (via new local name) |
| P4 | `function f({ a = 1 } = {})` | JavaScript, TypeScript | destructuring parameter, with outer default for a missing arg object | arbitrary expr (no `await`/`yield`) | yes |
| P5 | `(destructuring-bind (a &optional (b 1)) '(1) ...)` | Common Lisp | `destructuring-bind` pattern, reusing `&optional (var init)` / `&key (var init)` | arbitrary (init-form) | yes, left-to-right, incl. `supplied-p` flag |
| P6 | `{:keys [a] :or {a 1}}` | Clojure | map-destructuring pattern (`let`, `fn` arg vector, `defn`) | arbitrary expr | docs show literals only; cross-ref unconfirmed |
| P7 | `(match h [(hash-table ['a a #:default 0]) ...])` | Racket | `match` hash-table sub-pattern, per-key `#:default` | arbitrary expr | not documented |
| P8 | `{ a, b ? 1 }:` | Nix | function-argument attrset PATTERN | arbitrary expr, lazy | yes — all pattern names in scope, incl. each other |
| P9 | `\{ a, b ? 1 } -> a + b` | Roc (GitHub issue #6423; status contested/evolving, may be unifying toward `??`) | record-destructuring lambda pattern | arbitrary expr (constructor calls seen) | not confirmed |
| P10 | `field: opt @capture or "default"` | Nim (`fusion/matching` library macro, not core language) | `Option`-field match pattern | arbitrary expr | not confirmed |

Confirmed **absent** despite having pattern matching: Python `match` (PEP 634 — keyword in class pattern is an equality test, not a fallback), Ruby `case/in`, PHP `list()`/array destructuring, Dart 3 patterns, Swift `if case`/tuple patterns, Kotlin destructuring declarations, Scala `match`/extractors, Rust patterns (`..` discards, never defaults), OCaml/ReScript/F# pattern matching, Haskell (`RecordWildCards`/`NamedFieldPuns` only abbreviate, never default), PureScript, Erlang/Elixir/Prolog/Mercury pattern matching, Dhall (no value-level fallback operator at all), C++ structured bindings.

## Part 2 — Parameter-list / named-argument defaults

| # | Form | Languages | Position | Expr or constant | May reference siblings |
|---|------|-----------|----------|-------------------|------------------------|
| 1 | `f(a = 1)` / `a: Int = 1` flat parameter | JS/TS, Python (def-time only), Swift, Kotlin, Scala, C# (constant-only), D, Nim, Julia (positional, earlier-only), R (lazy, any order), Crystal (defaults must trail), Mojo, Pony, Ballerina, Koka (`len: int = xs.length`), PHP (constant-only, no sibling ref) | function/method parameter list | arbitrary expr in most; constant-only in PHP, C#, Dart; Python/Starlark/Jsonnet freeze at def-time | yes in Koka, R, Scala, Kotlin, JS; left-to-right-only in Julia; no in Python/PHP/C#/Dart/Jsonnet/Starlark (bound in outer/def scope) |
| 2 | `def f(a=1)` keyword-only `*, a=1` | Python | parameter list after bare `*` | expr, evaluated once at def time | no |
| 3 | `def f(a: 1)` | Ruby | keyword-argument list (colon spelling) | arbitrary expr, per-call | yes |
| 4 | `sub f($a = 1)` | Perl (signatures, scalars only) | subroutine signature | arbitrary expr | yes |
| 5 | `sub f($a = 1)`, `:$a = 1` | Raku | positional/named signature | arbitrary expr | yes, explicit in docs |
| 6 | `?(a = 1)`, `?label:(x = default)` | OCaml | optional labeled parameter | arbitrary expr, lazy | yes, earlier params |
| 7 | `~a=1` (default), `~a=?` (optional, no default), bare `?a` (forwarding) | ReScript | labeled argument list | arbitrary expr | yes (OCaml-derived) |
| 8 | `?a: int` + `defaultArg a 1` in body | F# | member/method parameter + body-level unwrap call | arbitrary expr (in `defaultArg` call) | yes, ordinary scoping |
| 9 | `[<Optional; DefaultParameterValue(1)>]` | F# (.NET interop) | member parameter attribute | constant | no |
| 10 | `{int a = 1}` named, `[int a = 1]` optional-positional | Dart | parameter list, braced/bracketed | compile-time constant only | no |
| 11 | `void f(int a = 1)` | C# | parameter list | constant / `new T()` / `default(T)` only | no |
| 12 | `void f(int a = 1)` | C++ | parameter list | arbitrary runtime expr (incl. calls) | no (error, except unevaluated contexts) |
| 13 | `fun f(a: Int = 1)` | Kotlin | parameter list | arbitrary expr | yes |
| 14 | `def f(a: Int = 1)` / `case class C(a: Int = 1)` | Scala | parameter list / case-class ctor | arbitrary expr | yes, preceding params |
| 15 | `?Name: Type = expr`, call-site `?Depth := 4` | Verse | parameter list + call site | not confirmed arbitrary; docs unclear | not confirmed |
| 16 | `:= 0` untyped default, mixed with `: Type = expr` | Odin | parameter list | compile-time constant only | no (generics/const params excluded) |
| 17 | `(x, y=0) => ...`, override must be named: `f(10, y=5)` | Grain | parameter list, any position | arbitrary expr | not confirmed |
| 18 | `def f(a \\ 1)` | Elixir | function head (compiles to arity overload) | arbitrary expr, per-call | not confirmed (guard clauses split off) |
| 19 | `proc f {a 1}` | Tcl | proc formal-argument list, 2-elem sub-list | literal word (no sibling visibility) | no |
| 20 | `param($a = 1)` | PowerShell | `param()` block | arbitrary expr | not restricted, ordinary scoping |
| 21 | `&optional (a 1)`, `&key (a 1)` | Common Lisp | ordinary/keyword lambda list (non-destructuring call) | arbitrary init-form | yes, left-to-right + `supplied-p` |
| 22 | `[a 1]` positional, `#:a [a 1]` keyword | Racket | `define`/`lambda` parameter list | arbitrary expr | yes, preceding arg-ids |
| 23 | `(define* (f a (b a)))`, `(key: k default)` | Scheme SRFI-89/88 | `define*`/`lambda*` parameter list | arbitrary expr | yes, explicit in spec |
| 24 | `function f(a, b=10)` | Jsonnet | parameter list | arbitrary expr, bound in *outer* scope | no (unlike Nix) |
| 25 | `def f(x, list=[])` | Starlark | `def`/`lambda` parameter list | arbitrary expr, evaluated once (mutable-default gotcha) | no (outer scope) |
| 26 | `(x : α := default)` optParam, `(x : α := by tac)` autoParam | Lean 4 | parameter list | arbitrary term, or a **tactic** (autoParam) | yes, ordinary elaboration scope |
| 27 | `{default 0 lag : Nat}` | Idris 2 | implicit parameter binder | arbitrary expr | not confirmed |
| 28 | n/a — confirmed absent | Java (no defaults; overloading only), Agda, Coq/Rocq (`Arguments ... default implicits` only affects implicit-inference, not a value), ATS (unconfirmed/not found), Hare (no defaults, Go-like), Unison, APL/BQN (no named params at all), Smalltalk (keyword messages make it moot), Erlang/Prolog/Mercury (arity overloading is the idiom), Elm (deliberately rejected — see notes), Gleam (open GitHub discussion #1122, unresolved), Jai (not found in available docs), Zig (no function defaults) | — | — | — |

## Part 3 — Struct/record/class field declaration defaults

| # | Form | Languages | Position | Expr or constant | May reference siblings |
|---|------|-----------|----------|-------------------|------------------------|
| 29 | `a: Type = 1` struct field | Zig (comptime expr), D, V (only non-zero fields need it), Jai (found in community primer), Ballerina `record`, Carbon (`var text: String = "default"`, must be compile-time constant) | struct/record/class declaration | constant (Zig comptime, Carbon) or arbitrary (D) | not supported |
| 30 | `type Foo = object; a: int = 2` | Nim | object field | constant only | not supported |
| 31 | `Base.@kwdef struct Foo; a::Int = 1; end` | Julia | macro-generated keyword constructor (plain `struct` has none natively) | arbitrary expr | not confirmed |
| 32 | `defstruct a: 1, b: 2` | Elixir | struct field defaults (keyword list) | effectively constant (compiled into `__struct__/0`) | no |
| 33 | `case class C(a: Int = 1)` | Scala | case-class field = ctor param (same as #14) | arbitrary expr | yes |
| 34 | `@Builder.Default private final String color = "blue"` | Java (Lombok, library not syntax) | annotated field + builder | field initializer expr | no |
| 35 | `S { a: 1, ..Default::default() }` + `#[derive(Default)]` | Rust | construction-site struct-update (not declaration syntax) | arbitrary expr (RHS of `..`) | n/a |
| 36 | `class Config { a: String = "x" }` | Pkl | class property | arbitrary expr | yes, explicit "class-as-function" docs example |
| 37 | `schema Person: age: int = 0` | KCL | schema attribute | not confirmed (likely arbitrary) | not confirmed |

## Part 4 — Config/schema/IDL/shell/SQL spellings

| # | Form | Languages | Position | Expr or constant | May reference siblings |
|---|------|-----------|----------|-------------------|------------------------|
| 38 | `a.b or 1` | Nix | expression-level attribute-select fallback (NOT a pattern default, contrast P8) | arbitrary expr | n/a |
| 39 | `Some x ? None Text` | Dhall | import-resolution fallback ONLY — unrelated to values/records; Dhall has no value-level `??` | arbitrary expr (import exprs) | n/a |
| 40 | `T::{ a = 1 }` record completion over a `default` record value | Dhall | call-site merge sugar, not a field-declaration default | arbitrary expr (ordinary record) | only via the paired `default` value |
| 41 | `{ a \| default = 1 }` | Nickel | record field metadata annotation (merge-priority based) | arbitrary expr | semantically priority-based, not direct reference |
| 42 | `*1 \| int` | CUE | disjunction-with-default, type/field position | arbitrary expr (may reference sibling fields, e.g. `*pet.species \| "cat"`) | yes, explicit example |
| 43 | `optional(string, "default")` | HCL/Terraform | object-type-constraint attribute | literal/expr matching type | no |
| 44 | `variable "a" { default = 1 }` | HCL/Terraform | `variable` block argument | constant-ish (no cross-resource refs) | no |
| 45 | `field(a: Int = 1): T`, `input I { a: Int = 1 }` | GraphQL | field argument / input-object field | CONST value grammar only (spec-mandated) | no |
| 46 | `[default = 1]` field option | Protobuf proto2 (removed entirely in proto3) | field option | constant/literal | no |
| 47 | `1: optional i32 a = 1;` | Thrift | struct field declaration | constant | no |
| 48 | `a @0 :Int32 = 123;` | Cap'n Proto | struct field declaration | constant literal (frozen forever once published) | no |
| 49 | `CREATE TABLE t (a INT DEFAULT 1)` | SQL (standard) | column definition | literal, niladic function (`CURRENT_TIMESTAMP`), or `NULL` | generally no (dialect-dependent) |
| 50 | `COALESCE(a, 1)` | SQL | any expression position (read-time, not declaration) | arbitrary expr | yes, freely |
| 51 | `${a:-1}` (non-assigning), `${a:=1}` (assigning) | Bash | variable/parameter expansion | arbitrary expr via substitution | yes, ordinary expansion |
| 52 | `set -q argName[1]; or set argName default` | Fish | body idiom (no signature-level default exists) | arbitrary expr | yes |
| 53 | `a = a or default` | Lua | plain assignment idiom (no parameter/pattern syntax exists) | arbitrary expr | yes |
| 54 | `$a //= 1` (defined-or), `$a \|\|= 1` (truthy-or) | Perl | assignment-statement idiom, not signature/pattern | arbitrary expr | yes |

## Notes and sources (selected)

- **JS/TS** (P1–P4, #—): MDN destructuring — https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Operators/Destructuring ; default parameters — https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Functions/Default_parameters
- **Common Lisp** (P5, #21): CLHS 3.4.1 — https://www.lispworks.com/documentation/HyperSpec/Body/03_dc.htm
- **Clojure** (P6): https://clojure.org/guides/destructuring (`:or` entries shown only as literals; cross-reference to sibling bindings not demonstrated)
- **Racket** (P7, #22): https://docs.racket-lang.org/reference/match.html ; https://docs.racket-lang.org/guide/lambda.html
- **Nix** (P8, #38): https://nix.dev/manual/nix/stable/language/constructs — note `args@{a?23,...}` does NOT include attrs that fell back to default (open issue #16423)
- **Roc** (P9): https://github.com/roc-lang/roc/issues/6423 (flags `?` overloaded between type-optional and pattern-default) and https://github.com/roc-lang/roc/issues/11946 (`??` on record-type fields); exact current canonical spelling unconfirmed, evolving
- **Python**: https://docs.python.org/3/reference/compound_stmts.html#function-definitions ; PEP 634 match has no default slot — https://peps.python.org/pep-0634/
- **Ruby**: https://docs.ruby-lang.org/en/3.2/syntax/calling_methods_rdoc.html ; pattern matching has no defaults — https://docs.ruby-lang.org/en/3.0/syntax/pattern_matching_rdoc.html
- **PHP**: https://www.php.net/manual/en/functions.arguments.php (constant-only; `list()` has no defaults, idiom is pre-merge with `+`)
- **Perl/Raku**: https://perldoc.perl.org/perlsub ; https://perldoc.perl.org/perlop ; https://docs.raku.org/language/signatures
- **Dart**: https://dart.dev/language/functions ; patterns have no defaults — https://dart.dev/language/patterns
- **Swift**: https://docs.swift.org/swift-book/documentation/the-swift-programming-language/functions/
- **Kotlin**: https://kotlinlang.org/spec/declarations.html
- **Scala**: https://docs.scala-lang.org/overviews/scala-book/case-classes.html ; https://docs.scala-lang.org/tour/extractor-objects.html (no defaults in extractors)
- **C#**: https://learn.microsoft.com/en-us/dotnet/csharp/programming-guide/classes-and-structs/named-and-optional-arguments
- **Java/Lombok**: https://projectlombok.org/features/Builder
- **OCaml**: https://ocaml.org/manual/5.4/lablexamples.html ; https://ocaml.org/docs/labels
- **ReScript**: https://rescript-lang.org/docs/manual/function/ ; https://forum.rescript-lang.org/t/best-way-to-have-default-values-for-a-record/738
- **F#**: https://learn.microsoft.com/en-us/dotnet/fsharp/language-reference/parameters-and-arguments
- **Haskell**: no field-default syntax exists — https://wiki.haskell.org/Default_values_in_records (library-only `data-default`)
- **PureScript**: https://pursuit.purescript.org/packages/purescript-data-default/0.3.2/docs/Data.Default (library-only)
- **Unison**: https://www.unison-lang.org/docs/fundamentals/values-and-functions/functions/ (no defaults found)
- **Elm**: deliberately rejected a `Maybe`-defaulting record syntax — https://discourse.elm-lang.org/t/optional-key-records-syntax-proposal/2634 (objection: would promote `Maybe` to special compiler status, "ad-hoc polymorphism" the team already limits); idiom thread — https://discourse.elm-lang.org/t/pattern-for-default-values/3933
- **Gleam**: open, unresolved — https://github.com/gleam-lang/gleam/discussions/1122 (worried defaults clash with labels being compile-time-only; proposed restricting to literal, tail-position, labelled-only defaults)
- **Koka**: https://koka-lang.github.io/koka/doc/book.html (`len: int = xs.length`; separate unrelated `?show` implicit-parameter feature using the same sigil family)
- **Nim**: https://nim-lang.org/docs/manual.html ; pattern-default only via library macro — https://nim-lang.github.io/fusion/src/fusion/matching.html
- **Crystal**: https://crystal-lang.org/reference/1.18/syntax_and_semantics/default_and_named_arguments.html
- **Mojo**: https://docs.modular.com/mojo/manual/parameters/
- **Grain**: https://grain-lang.org/docs/guide/functions ; https://github.com/grain-lang/grain/issues/388
- **Lean 4**: https://lean-lang.org/doc/reference/latest/Terms/Function-Application/
- **Idris 2**: https://idris2.readthedocs.io/en/latest/tutorial/miscellany.html
- **Coq/Rocq**: `Arguments` only affects implicit inference, not value defaults — https://rocq-prover.org/doc/V8.19.2/refman/language/extensions/arguments-command.html
- **Rust**: https://doc.rust-lang.org/std/default/trait.Default.html
- **C++**: https://en.cppreference.com/w/cpp/language/default_arguments ; https://en.cppreference.com/w/cpp/language/structured_binding (no defaults)
- **Zig**: https://ziglang.org/documentation/master/#Default-Field-Values (struct fields only; no function defaults, no destructuring defaults)
- **D**: https://dlang.org/spec/function.html ; https://dlang.org/spec/struct.html
- **Julia**: https://docs.julialang.org/en/v1/manual/functions/ ; `@kwdef` — https://discourse.julialang.org/t/what-is-the-deal-with-kwdef/96733
- **R**: https://adv-r.hadley.nz/functions.html (lazy promises, any-order cross-reference)
- **V**: https://docs.vlang.io/structs.html
- **Odin**: https://odin-lang.org/docs/overview/
- **Jai**: https://github.com/BSVino/JaiPrimer/blob/master/JaiPrimer.md (struct-field defaults only; function-parameter defaults not found)
- **Carbon**: https://github.com/carbon-language/carbon-lang/blob/trunk/docs/design/classes.md ; function-default design still open — issue #505
- **Hare**: no defaults (Go-like minimalism); zero-value `...` fill is construction-site, not a declared default — https://harelang.org/tutorials/introduction/
- **Verse**: https://dev.epicgames.com/documentation/fortnite/verse-glossary
- **Pony**: https://tutorial.ponylang.io/expressions/methods.html
- **Ballerina**: https://ballerina.io/learn/advanced-general-purpose-language-features/
- **Erlang**: no defaults, arity-overload idiom — https://www.erlang.org/doc/system/ref_man_functions.html
- **Elixir**: https://hexdocs.pm/elixir/modules-and-functions.html ; structs — https://hexdocs.pm/elixir/structs.html
- **Prolog**: no language defaults; library idiom `option/3` — https://www.swi-prolog.org/pldoc/man?section=option
- **Mercury**: no evidence found — https://mercurylang.org/information/doc-release/reference_manual.pdf
- **Smalltalk**: moot by keyword-message design — http://pharo.gforge.inria.fr/PBE1/PBE1ch5.html
- **Tcl**: https://www.tcl-lang.org/man/tcl8.6.11/TclCmd/proc.htm
- **PowerShell**: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_parameters_default_values
- **Fish**: https://fishshell.com/docs/current/cmds/function.html ; https://github.com/fish-shell/fish-shell/issues/2645
- **Bash**: https://www.gnu.org/software/bash/manual/bash.html#Shell-Parameter-Expansion
- **Lua**: https://www.lua.org/manual/5.4/manual.html#3.4.5 (idiom only; no parameter/pattern syntax)
- **Nix** (full): https://nix.dev/manual/nix/stable/language/constructs
- **Dhall**: https://github.com/dhall-lang/dhall-lang/wiki/Built-in-types,-functions,-and-operators (no `??`; `?` is import-fallback only)
- **Nickel**: https://nickel-lang.org/user-manual/syntax/
- **CUE**: https://cuelang.org/docs/concept/the-logic-of-cue/
- **Jsonnet**: https://jsonnet.org/ref/language.html (default bound in outer/defining scope, not sibling scope — contrast with Nix)
- **Pkl**: https://pkl-lang.org/main/current/language-reference/index.html
- **KCL**: https://www.kcl-lang.io/docs/reference/lang/tour
- **Starlark**: https://github.com/bazelbuild/starlark/blob/master/spec.md
- **HCL/Terraform**: https://developer.hashicorp.com/terraform/language/expressions/type-constraints ; https://developer.hashicorp.com/terraform/language/block/variable
- **GraphQL**: https://spec.graphql.org/October2021/#sec-Input-Values
- **Protobuf**: https://protobuf.dev/programming-guides/proto2/
- **Thrift**: https://thrift.apache.org/docs/idl
- **Cap'n Proto**: https://capnproto.org/language.html
- **SQL**: https://hightouch.com/sql-dictionary/sql-default

## Cross-cutting observations (no recommendation)

- True pattern-position defaults are rare: confirmed clean cases are Common Lisp's `destructuring-bind`, Clojure's `:or`, Racket's `match` hash `#:default`, Nix's attrset function pattern, and Roc's contested `{ a, b ? 1 }`. Everywhere else with pattern matching (OCaml family, Haskell, Rust, Swift, Kotlin, Scala, Dart, Python, Ruby, PHP, Elixir/Erlang/Prolog) a default is confirmed absent from the pattern itself.
- Expression-vs-constant is split along "wire/schema format" vs. "general-purpose language" lines: IDLs (GraphQL, Protobuf, Thrift, Cap'n Proto) and some mainstream statically-typed languages (C#, PHP, Dart, Odin) require constants; config languages (Nix, CUE, Pkl, Nickel) and most functional/scripting languages allow arbitrary expressions.
- Sibling-reference support is inconsistent even among expression-default languages: Nix, R, Scala, Kotlin, Koka, CUE, Pkl explicitly allow it; Jsonnet and Starlark explicitly bind the default in the *outer* scope, not sibling scope, despite looking syntactically similar to Nix/Python.
- Elm and Gleam are the only two languages found that explicitly considered and rejected adding default-value syntax, both on record-philosophy/consistency grounds (Elm: not promoting `Maybe` to special status; Gleam: conflict with labels being compile-time-only and library-evolution safety).
- Roc shows a documented maintainer-acknowledged defect from overloading one sigil (`?`) for two different jobs (type-level optionality vs. pattern-level default), apparently later separating the concern onto `??`.
