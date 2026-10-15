# 96 — Nullary method calls: how should beni spell `xs.length`?

*2026-10-15. Research only. It changes no specification and no code; the owner decides. The question
came from the ownership work on `browser-direct`. There, a developer sometimes has to copy a list before
appending to it, and writes `List.copy current.trail ++ other.trail`. The owner would rather write
`current.trail.copy ++ other.trail`. The same question covers `xs.length`, `xs.isEmpty`, `s.trim`,
`d.keys` and `x.toString`. Sources are linked where they are used. **[V]** marks a claim read in a
primary source during this research, and **[I]** marks an inference.*

---

## 0. The answer

**Recommendation: make `x.m` with no arguments follow the same rule as `x.m a`, decided by the
receiver's type.** If the receiver is a record, `x.m` reads the field `m`, exactly as today. If the
receiver is a nominal type `T` declared in module `M`, `x.m` is the call `M.m x`. If the receiver's type
is not yet known, the choice waits until it becomes known. If the receiver is **still** unknown when its
declaration is generalised, the default is the field. That default is the one place where the nullary
rule differs from the rule for calls with arguments. So `current.trail.copy ++ other.trail`,
`xs.length`, `s.trim` and `d.keys` all work, and nothing that checks today changes meaning.

Five facts make this cheaper in beni than in any language surveyed:

1. **beni has no case where a field and a method share a name.** A record has fields and no methods
   (`static-dispatch-spike.md` §1.2's record row). A nominal type has methods and no fields: a
   constructor wraps its payload, so reading the payload needs a pattern. Every language that adopts a
   type-directed `x.m` needs a rule that a field beats a method of the same name. Lean, Nim, D, Haskell's
   `HasField`, Scala extensions and Kotlin all have one (§2). That rule is the source of their
   refactoring hazard, where adding a field silently captures `x.m`. beni needs no such rule, and so it
   has no such hazard. Roc's argument for deciding in the parser is that a nominal type with a record
   backing **does** expose both fields and methods (`references/roc/design.md`, *Thing :=
   { f : … }.{ f : … }*). beni has no such type.
2. **The checker already makes this choice, for `x.m a`.** A dot-call whose receiver is unknown is held
   until the receiver is known. If it turns out to be a record, it is the field call, and the timing
   rule is order-independent (§11 *Deferred receiver*, amended 2026-09-26;
   `src/check/Instances.zig` `onRecord`/`fieldCall`). The proposal reuses that machinery. Its one new
   rule is the default at generalisation.
3. **The compiler already recognises the case, and only to refuse it.** `language.md` §12.5's
   call-style hint (`src/check/CallStyle.zig` `fieldHint`) already detects `xs.length` on a non-record
   whose module has a matching one-parameter function. Today it prints "Write `List.length xs`". The
   proposal turns that hint into the meaning.
4. **beni has no automatic currying.** In Lean and Koka, `x.f` on a function with more parameters is a
   partial application. In beni it can only be `too_few_args`, whose hint is `xs.take n` or
   `xs.take _`. A nullary dot-call is either a complete call or an error, never a function value.
5. **Field identity (rule 8) and ownership both depend on telling a read from a call, and the change
   keeps them apart.** After checking, a resolved nullary method becomes a `method_call` with no
   arguments, and every pass that walks field paths (ownership, write sets, markup) sees a call (§3.4).

**What it costs, plainly** (§3, §4.1):

Measured in PR #126's independent review (2026-10-15; machine not recorded):
field-dense synthetic code, 63k lines with `--jobs=1`, checks 41% slower
(284 → 401 ms); the 100k-line bench corpus moves 0.31 → 0.32 s.
Recorded without optimisation in the follow-up. Issue #131 subsequently adds a
known-record fast path; [the benchmark log](../../../bench/README.md) retains its
replacement generator, profile and interleaved before/after measurements.

- `x.m` no longer tells a reader whether it is a free read or a call. The call may allocate (`.copy`,
  `.reverse`), take O(n) time, be impure, or suspend.
- An unannotated `size xs = xs.length` still infers a record type, `{ r | length : a } → a`. A call
  `size [1, 2]` is then an error at the call site, which needs a good hint. Lean refuses the same
  program with "type is not known" (§2.1).
- Every post-check consumer that today assumes `field_access` means a path (§3.4 lists them) must see
  the resolved form. Missing one is a silent wrong answer, not an error. The mitigation is a single retag after checking
  (§3.4).
- A record type alias (`Url`, `Model`) still has no methods, as today for `x.m a`.

**Roc chose the opposite, on purpose.** `x.f` is always a field and `x.f()` is always a method, and "no
stage may … inspect the receiver type to recover a choice that syntax already made"
(`references/roc/design.md`; Feldman on Zulip, §1). Roc's reason does not carry over to beni (fact 1
above). Roc's choice also rests on parens-and-commas, which beni does not have: `x.m ⊤` is the nearest
spelling of `x.m()`, and §4.2 shows it is worse than Roc's.

---

## 1. Roc (primary source: the Roc Zulip and `roc-lang/roc`)

**The rule** [V]. Richard Feldman, #bugs › *Pipe into method*, 2026-09-01: *"syntactically,
`my_const.concat` always means, without exception, "access the field `concat` on a record named
`my_constant`""* and *"`my_const.concat()` is always syntactically a method call"*
(<https://roc.zulipchat.com/#narrow/channel/463736-bugs/topic/Pipe.20into.20method/near/620712713>,
`/near/620712809`). It was in the 2024 proposal from the start. Kevin Gillette quoted it: *"`x.foo` is
still a record field access; I can tell x is a record just from looking at this"*. Feldman then said a
function held in a field is called as `(x.foo)(bar)` (#ideas › *static dispatch - proposal*,
2024-11-09, <https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/static.20dispatch.20-.20proposal/near/481477753>,
`/near/481477782`). The new compiler enforces it. A record with a function in its field `next`, called
as `myiter.next(…)`, is reported as `MISSING METHOD`, and `(myiter.next)(…)` works (#beginners,
2025-12-12, <https://roc.zulipchat.com/#narrow/channel/231634-beginners/topic/Iterator.20type.20with.20the.20new.20compiler/near/563302677>).
`references/roc/design.md` makes it a stage invariant: *"THE PARSER, NOT THE TYPE CHECKER, MAKES THE
COMPLETE AND FINAL CHOICE"*. It holds even for a nominal type whose record backing has a field named
like one of its methods.

**Zero-argument calls always take `()`** [V]. Sam Mohr: *"Even if a function has zero args, it should
have parens … it'd be `Now!().floor().to_string()`"* (2024-12-26,
<https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/static.20dispatch.20-.20pass_to.20alternative/near/490898565>).

**Zero-argument calls did not drive the move to parens-and-commas** [V]. Parens-and-commas came from
static dispatch and from mainstream familiarity, with Gleam as the precedent. Sam Mohr said it would
*"probably stay even if SD is rejected because … people seemed to like Gleam more just for PNC"*
(`/near/490897028`). Zero-argument functions followed from the choice. Feldman, 2024-12-11: *"once we go
to parens-and-commas calling style we should just have an actual concept of zero-argument functions …
they come up all the time now that we have effectful functions"*
(<https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/static.20dispatch.20-.20proposal/near/488016885>).
In his 2025-01-13 list of pros they are one item among about twelve
(<https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/.E2.9C.94.20reflecting.20on.20static.20dispatch....20and.20discussing.20removin.../near/493452520>).

**The field-or-method ambiguity was raised against the whitespace alternatives** [V]. In *Static
dispatch without parens and commas* (2024-12-18), Anthony Bullard proposed a `.foo` that falls back from
field to method. He then conceded *"it's unclear now if it is field access or a function call"*
(`/near/489783088`). Norbert Hajagos: *"A beginner would confuse a 1 arg method for a field access …
`linkedList->last`"* (`/near/489729960`). The thread closed with "PNC will carry the day".

**Same-name field and method** [V]. When method tear-offs (a bare `subject.method`) were proposed,
Feldman asked: *"what happens if I have a custom record … with a function named `foo` and then later I
add an exposed field to the record named `foo`? Do all the usage sites silently change to being field
access…?"* He also said *"arguably it's a bad enough idea to have a method and field of the same name
that we could emit a compiler warning"* (2025-01-02,
<https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/Static.20Dispatch.20and.20method.20tear-offs/near/491624097>,
`/near/491629438`). In beni that hazard cannot arise (§0 fact 1).

**The one place Roc drops `()`, and the defects it caused** [V]. The pipe `a |> f` lets the formatter
drop the empty parentheses (`"hello" |> Str.is_empty`, `test/snapshots/arrow_qualified_functions.md`).
That caused two defects. In #11045 the formatter turned `x |> my_const.concat()` into a field access. In
#10510, `a->f()?` became `a |> f?`. Feldman: *"`()` could be load-bearing"* (2026-08-01, `/near/614033724`).
The second is still argued.

**Methods belong to nominal types only** [V]. A structural record alias gets no user methods
(Anton, 2026-04-04, <https://roc.zulipchat.com/#narrow/channel/231634-beginners/topic/How.20to.20define.20a.20static.20method/near/583587249>).
beni has the same rule.

**What transfers.** Roc settles field versus method in the parser because its parens-and-commas syntax
gives it a token to settle it with, and because a nominal type can have both. beni has neither.
Bullard's and Hajagos's complaint does transfer: in the source, a nullary method looks like a field.
That is a readability cost the recommendation accepts (§4.1).

---

## 2. The ML family and neighbours

| Language | `x.m` with no arguments | Field against function of the same name | What it costs |
|---|---|---|---|
| **Lean 4**, generalized field notation | `e.f` is `C.f e`, where `C` is the head constant of `e`'s type. A structure field is checked first, then the namespace `C` and its parents, then definitions are unfolded (`Username := String` finds `String.any`). `e` fills the first explicit parameter whose type is headed by `C` [V, `src/Lean/Elab/App.lean` `resolveLValAux`/`findMethod?`; [manual](https://lean-lang.org/doc/reference/latest/Terms/Function-Application/#generalized-field-notation)] | a field is the constant `C.f`, so within one type there is no clash; an inherited field beats a namespace function [I] | **the type must be known**: elaboration is postponed, then fails with *"Type of e is not known; cannot resolve field"*. [#6372](https://github.com/leanprover/lean4/issues/6372): `[0].map (·.toInt8)` fails unless the expected type is known. Only the type's own namespace is searched ([#3031](https://github.com/leanprover/lean4/issues/3031)). Choosing the receiver's parameter is fragile with implicit parameters ([#1629](https://github.com/leanprover/lean4/issues/1629)). Being curried, `x.f` with missing arguments is a partial application |
| **Koka** | `x.f` is `f(x)`; nullary calls drop the parentheses (`c.int`); a struct field *is* an accessor function (`brian.age` = `age(brian)`) [V, [book](https://koka-lang.github.io/koka/doc/book.html) §3.1.2, §3.3] | one namespace of overloaded functions, chosen by type | the book: a `map` defined for lists and strings makes a program *"ambiguous without an annotation"* [V] |
| **Haskell**, `OverloadedRecordDot` + `HasField` | `e.fld` is `getField @"fld" e`. A hand-written `HasField` instance makes a *virtual field* such as `xs.length` [V, [proposal 282](https://ghc-proposals.readthedocs.io/en/latest/proposals/0282-record-dot-syntax.html), [user guide](https://ghc.gitlab.haskell.org/ghc/doc/users_guide/exts/hasfield.html)] | there can be no virtual field over a real one, so **a field always wins** [V] | an unknown receiver becomes a `HasField` constraint [I]. Spacing decides the meaning of `.`, so that *"a record with a field called b might be added somewhere deep in the codebase and cause unexpected ambiguities"* ([HN](https://news.ycombinator.com/item?id=24540496)) |
| **F#** | `x.Length` is a property, a getter that runs a call; `x.Trim()` is a method; `s.Trim` without `()` is the method as a value [I] | .NET members: one name per member [I] | **FS0072**: *"The type of this expression could not be inferred before accessing its members"* [V, `FSStrings.resx`]. Lookup runs left to right, which is why F# writes `xs ▷ List.map (fun x -> x.Length)`. The .NET guideline is to make it a method if it is slow, a conversion, or returns a copy [V, [design guidelines](https://learn.microsoft.com/en-us/previous-versions/dotnet/netframework-4.0/ms229054(v=vs.100))] |
| **OCaml** | `r.x` is a field; a method is `p#get_x`, called with no parentheses [V, manual] | different symbols. Record labels are disambiguated by type, else by the *last defined type*, which *"may change surreptitiously after adding or moving around a type definition"* [V] | warnings 40–42 exist and are off by default [V, `utils/warnings.ml`] |
| **Scala** | a `def size: Int` is called `x.size`, the uniform access principle [V] | a member beats an extension [V] | Scala 3 **dropped auto-application**: `def next()` may no longer be called as `next` ([reference](https://docs.scala-lang.org/scala3/reference/dropped-features/auto-apply.html)) [V]. Style guide: drop the parentheses only when there are no side effects [V] |
| **Swift / Kotlin** | computed properties are declared as properties, and the declaration decides | a member beats an extension (Kotlin) [V] | conventions only: Swift says *"Document the complexity of any computed property that is not O(1)"*; Kotlin says a property should be cheap, not throw, and return the same result each time [V] |
| **Rust** | `x.f` is always a field; `x.f()` is always a method; a closure in a field is `(x.f)()` [V, Reference] | a field and a method may share a name, and it is idiomatic (the C-GETTER guideline) [V] | E0615 suggests the `()`. None of the hidden-call cost |
| **Nim** | UFCS: *"The parentheses can be omitted if there are no remaining arguments: `obj.len`"* [V, manual] | *"the builtin dot access is preferred"*, so a field wins, and visibility decides: inside the module it is the field, outside the getter [V] | *"`x` in `x.f` needs to be semantically checked … before it can be decided"* [V] |
| **D** | UFCS with optional parentheses: `arr.bar` is a call [V, spec] | a member beats UFCS [V] | `@property` has a standing spec warning: *"Using property functions is not recommended"* [V]. On HN: *"I … don't really use the UFCS dot style, it requires too much context"* ([p0nce](https://news.ycombinator.com/item?id=44453925)). Zig cites D's `c.d` *"might call a function"* as hidden control flow it rules out ([why Zig](https://ziglang.org/learn/why_zig_rust_d_cpp/)) |
| **Gleam, ReScript, SML** | no methods: a field, or a module function through a pipe [V Gleam tour; I the rest] | none | Gleam spells it `xs ▷ list.length` |

**What the adopters share.** Lean, Koka, Nim, D and Haskell's virtual fields all make a bare `x.m` a
type-directed call, and they pay three ways:

1. They need the receiver's type before the dot, so they postpone, fail, or turn the use into a
   constraint.
2. A field beats a same-named function, which is where the refactoring hazard comes from.
3. A call looks like a read, and every one of them answers that with a convention rather than a rule.

The refusers are Rust, Scala 3, Roc, OCaml and Gleam. They keep the call visible at a price of one
token or one symbol.

**What transfers to beni.** Cost 1 is real in beni and is §3.2's subject. Cost 2 does not arise (§0
fact 1). Cost 3 is real, and it is the one the recommendation accepts. Lean is the closest relative:
pure, functional, type-directed, searching one namespace (beni's module rule), with error messages good
enough to name the namespace searched. Lean's fragility over which parameter takes the receiver (#1629)
does not arise either, because beni's receiver is always the first parameter.

---

## 3. beni: what each piece of the compiler would see

### 3.1 What happens today

`x.m` lowers to `field_access` (`src/bir/Lower.zig`, `lowerApplication`'s comment). The constraint
generator turns that into `x : { m : t | ρ }` at once (`src/check/constrain/Expr.zig`, the
`.field_access` arm). `x.m a` lowers to `method_call`. That raises a dot-call wanted, which is resolved
when the receiver is known (Rule U0) and otherwise rides on the receiver's variable
(`src/check/Resolve.zig` `method`/`step`). When the receiver turns out to be a record, the wanted
becomes a field call (`Instances.onRecord` → `fieldCall`). The *Deferred receiver* amendment makes the
**time** of that choice order-independent (checker-v2.md I9). A wanted still open at generalisation is
promoted into an inferred `where` clause, capped at 64.

### 3.2 Type inference order: the one new rule

A nullary dot raises the same wanted as `x.m a`, with a method type of one parameter. The rules are the
existing ones, plus one:

| Receiver at the decision | `x.m` is |
|---|---|
| a record, known at the dot or found before generalisation | the field read, with today's `unknown_field` |
| a nominal `T` declared in `M` | `M.m x`; `unknown_method`/`private_method` as today; `too_few_args` if `M.m` takes more than the receiver, with the hint `x.m a` / `x.m _` |
| a rigid variable whose `where` clause names `m : a → R` | the method, as a dot-call with arguments is |
| a tuple, `⊤`, a function | `no_methods_on_shape`, as today (the well-known `eq`/`compare` take an argument, so a nullary `x.eq` is `too_few_args`) |
| **still a flexible variable when the declaration (or a `let`) is generalised** | **the field read**: the wanted is discharged by unifying the receiver with `{ m : t \| ρ }`, which is exactly today's typing |

**Why the last row defaults to the field.** If it promoted to a `where` clause instead, as `x.m a`
does, the unannotated `name r = r.name` would infer `a → b where a.name : a → b`. Every caller passing a
record would then be `no_methods_on_shape`, because a generalised requirement has no field accessor to
be (§11 *Deferred receiver*). That would break the row-polymorphic record access beni keeps from Elm.
Defaulting to the field keeps every inferred record type exactly as it is.

**It is deterministic.** Generalisation happens at the end of a binding group, and group membership
comes from the dependency graph, not from declaration order. So I9 holds by the same argument that
supports the 2026-09-26 amendment. The defaults must run **before** the group's other open wanteds are
closed. Defaulting a field can make a receiver a record, and that receiver's pending `x.g a` must then
become a field call, as it does today. They all unify into one row, so the order among the defaults
does not matter.

**Conservative extension (a claim to verify with the corpus, not a proof).** In a program that checks
today, every `x.m` is on a record, either a known one or a flexible variable that the row makes one.
Under the proposal each such dot ends as the same field read. The record information merely arrives
later: at the receiver's resolution or at generalisation, instead of at the dot. The risk is a feature
that reads a type *early*. Rule U0 seeds a lambda's parameters from a method only when the receiver is
concrete at that point. When an earlier `x.f` used to make `x` a record, a later `x.g a` was resolved
immediately; it would now be resolved at the default instead. That changes *when*, not *what*, because
the amended rule exists precisely so that the two give the same answer. The implementing slice should
run the whole corpus and the ordering tests to confirm that no verdict moves.

**Two shapes the implementing slice must test by name.**

- *A `let`-bound helper generalised before its use.* In `helper = λx → x.length` followed by
  `helper myList`, `x` is unknown when the `let` is generalised. So the default fires there, and
  `helper` takes a record. The call is then an error, the same error today's field access gives. It
  is not a regression, but it is where a user will expect the method, and it is the main case for
  the hint below.
- *A recursive group whose members fix each other's receivers.* The invariant "defaults run before
  the group's other open wanteds close" must become a declaration-permutation scenario in
  `ordering_test.zig`, not just a note: two members, one reading `x.f` and one calling `x.g a`, in
  both orders.

**The new failure, and its message.** `size xs = xs.length` with no annotation infers
`{ r | length : a } → a`, and `size [1, 2]` fails at the call. `CallStyle.fieldHint` already knows how
to say *`length` is a function of `List`*. The message should add the cause: *`size` reads `length`
from an argument whose type was not known there, so it was read as a field; annotate
`size : List a → Int`.* This is Lean's "type is not known" and F#'s FS0072, reported at the use instead
of at the definition. In beni it bites less than in either, because top-level annotations are the norm
(Feldman makes the same observation about Roc, report 18 §2.1). Inside
`List.map words λw → w.length`, the lambda's parameter is fixed by `map`'s signature before the
group is generalised.

### 3.3 Records with a field named like a method; extensible records; aliases

The case cannot arise. A record has no methods, and a nominal type has no fields. An extensible record
type `{ r | length : Int }` is a record, so it is a field. A type alias is transparent
(static-dispatch-spike.md §1.2), so `Url` and `Model` are records and **get no nullary methods**:
`url.toString` stays `unknown_field`, with the hint `Url.toString url`, exactly as `url.m a` behaves
today. Turning `type alias User = { … }` into a nominal `type User = User { … }` breaks every
`u.name` with an error, never silently, because the payload needs a pattern.

### 3.4 The passes after the checker: ownership, write sets, markup, emission

This is the largest cost. The BIR is built before types are known, and `field_access` chains are
treated as **paths** by:

- `src/own/Ownership.zig` (`refPath`, `rootToken`, `evalRaw`, `writeExpr`);
- `src/writes/Writes.zig` (`projField`, `isPathExpr`, `writeExpr`);
- `src/js/MarkupTree.zig` (six path walks);
- `src/js/Lower.zig`;
- `src/check/constrain/Decl.zig`, which walks a `field_access`'s operand when it collects a
  declaration's references (a retagged call is walked as `method_call` already is);
- the diagnostics: `Diagnostics.zig` names a `field_access` region as a field, and after the retag a
  method's region is named as a call, with the wording `x.m a` already gets.

If `current.trail.copy` reached ownership as a path, the checker would treat the copy as an **alias**
of `current.trail`, the opposite of what `copy` is for. The motivating line would be refused with
`list_still_used`. And a markup hole `{model.items.length}` would be tracked as a model path that no
update writes.

There are two ways to carry the decision, and they differ in what happens when a pass is missed:

- **The dispatch table only.** A nullary method gets a `Site` on the `field_access` instruction, as a
  `method_call` does today, and each pass asks before treating the node as a path. A pass that forgets
  silently gives a wrong answer.
- **A retag after checking (recommended).** Once the module checks, each `field_access` the checker
  resolved to a method becomes a `method_call` with an empty argument list, carrying the `Site` it
  already has. Every later pass then meets the shape it already handles for `x.m a`:
  - ownership applies `copy`'s summary (`res ε = fresh`), so `current.trail.copy ++ other.trail` is
    accepted;
  - write sets see a call whose argument is the path `model.items`;
  - the emitter writes `List$copy(…)`, or its suspendable form when it suspends.

  The frontend cache keeps the BIR as lowered, so the retag is applied to the checked module's copy.
  An empty argument list is a new shape for `method_call`, and each consumer needs one test of it.

Either way, every pass needs a corpus fixture with a nullary method on its path: an ownership fixture
for the motivating line, a `browser/` page with `{model.items.length}` in a hole, and an `emit/`
golden.

### 3.5 Placeholders, pipes, the accessor, the formatter

- **Grammar and formatter: no change.** `x.m` is already one atom with an access chain.
  `current.trail.copy ++ other.trail` parses as `(current.trail.copy) ++ other.trail`, because access
  binds tightest.
- **Placeholders**: `x.m _` is a method call with one argument, as today. A nullary method has no
  argument to elide.
- **Pipes**: `e ▷ x.m` is already `x.m e` (`lowerApplication`), and that is unchanged.
- **The accessor `.m`**: its lowering is `λr → r.m`, so it follows the same rule.
  `List.map words .length` becomes `String.length` per element. That falls out of the rule; the spec
  should say so on purpose. Where nothing fixes the element type, as in an unannotated
  `lengths xs = List.map xs .length`, the default makes `.length` a field reader, so `lengths` takes
  a list of records. `lengths [ "a" ]` is then §3.2's generalisation error, at the call.
- **Today's spelling breaks under precedence.** `current.trail ▷ List.copy ++ other.trail` parses as
  `current.trail ▷ (List.copy ++ other.trail)`, because `▷` binds loosest. The prefix form is the only
  status-quo spelling that works.

### 3.6 Errors, interfaces and caching, effects, determinism

- **Errors.**
  - A misspelt `xs.lenght` is `unknown_method` against `List`, and its did-you-mean should search
    `List`'s one-parameter `pub` values.
  - `xs.take` is `too_few_args`, and its hint shows `xs.take n` and `xs.take _`, never a partial
    application.
  - §12.5's two hints (`xs.length` and `xs.length ()`) change their text: the first becomes the
    generalisation hint of §3.2, and the second points at `xs.length`.
- **Interfaces.** No change. A nullary dot never promotes into a `where` clause, so no new interface
  term appears. An annotated `where a.length : a → Int` is an ordinary method requirement.
- **Caching.** The frontend artifact (tokens, AST, and the BIR as lowered) does not change, because
  parsing and lowering still produce `field_access` exactly as today. The checked output does change:
  the dispatch table gains a site for each nullary method, and the retag (§3.4) is applied to the
  checked copy of the BIR. So the check-cache entry's version goes up and the frontend artifact's
  does not.
- **The interface firewall.** It already makes a dependent depend on `M`'s `pub` value set for
  `x.m a`. Adding `pub length` to `M` can only turn an error into a call, never change a field read,
  because a receiver of `M`'s type was never a record.
- **Effects.** A nullary method is a call, so `Effects.zig` infers its rung from the callee as for any
  call. A dot may now suspend, which a field read never did. Markup holes need no new rule: a nullary
  method in a hole is a call in a hole. Whatever already governs `List.length xs` there (the `sync`
  boundary and `must_not_suspend`, `transparent-effects-proposal.md` §15) governs `xs.length`, with
  the same message. What readers of `view` code lose is the guarantee, from the spelling alone, that
  `a.b.c` is free. That is the cost §4.1 accepts.
- **The module-rule namespace** (§11's first limit): nullary methods make it slightly more visible.
  `n.toString` has no home, because `Int` is declared in `Basics`, which has no `toString`; the
  function is `String.fromInt`. That is the same limit `language.md` §12.4 records for `n.mod 2`.

---

## 4. The candidates

### 4.1 The receiver's type decides (recommended)

```elm
total = current.trail.copy ++ other.trail
label = if xs.isEmpty then "none" else "${xs.length} items"
List.map names .trim
```

**Rule.** §3.2's table. `x.m` resolves like `x.m a`, with the receiver as `M.m`'s only argument. If the
receiver is a record, the field is read. If the receiver is still unknown at generalisation, the field
is read.

**Costs.**

- **A call looks like a read.** `model.items.reverse` allocates on every render, while
  `model.items` keeps its identity. Rule 8 makes field identity load-bearing, so a reader can no longer
  tell from the spelling that a hole's value is the model's own. Swift, Kotlin, .NET and Scala answer
  this with a convention, and so should core: a nullary method should be cheap and pure, with
  `copy`/`reverse` the documented exceptions. A rule would encode taste (rule 7). The compiler gets
  a safeguard rather than a convention: after the retag a nullary method is a call, and no pass
  (write sets, the markup tree, the release optimiser) may treat it as an identity-preserving read
  of the path it is called on.
- **The generalisation default.** Unannotated helpers reading a method infer record types (§3.2). The
  call-site hint has to be good.
- **Every path-walking pass must see the retagged node** (§3.4).
- **Record aliases have no nullary methods.**

**Precedent.** Lean 4 (the closest), Koka, Nim, D, Haskell virtual fields, and the uniform access
principle of Scala, Swift and Kotlin. Against: Roc, Rust, Scala 3's removal of auto-application, D's
own retreat from `@property`, and Zig's "hidden control flow" objection.

### 4.2 A marker argument: `x.m ⊤`

```elm
total = current.trail.copy ⊤ ++ other.trail
```

**Rule.** A method call whose only argument is the literal `⊤`, on a method whose arity is 1, calls it
with no arguments. This is beni's nearest thing to Roc's and Rust's `x.m()`.

**Costs.**

- **It is a pun.** `⊤` is a value, and `λ⊤ → e` is a one-parameter function. A method
  `M.run : T, ⊤ → a` is legal, so `x.run ⊤` is a two-argument call. Telling the two readings apart takes
  the method's arity, so this is type-directed too, with a worse spelling.
- **Pipes and placeholders become ambiguous.** `x.m ⊤` would mean different things depending on whether
  `⊤` is a placeholder for "no arguments" or an argument.
- **Every nullary call is two tokens longer.** Roc's `()` is cheap because parens-and-commas already
  puts parentheses on every call. Under whitespace application, `⊤` is a visible word.
- **§12.5 already treats `xs.length ()` as a habit to correct.**

It keeps the call visible, which is its one advantage over §4.1.

**Precedent.** Roc, Rust, ML's `f ()`.

### 4.3 A distinct operator: `x#m`

```elm
total = current.trail#copy ++ other.trail
```

**Rule.** A new token `#` followed by a lower identifier, abutting an atom like `.m`, that is always a
method call with no arguments. It is never a field read, so the parser decides, as in Roc. `#` is free
in beni's lexer (`language.md` §2.2).

**Costs.**

- **There are two ways to call a method**: `.` with arguments and `#` without. `x#m a` must be either
  refused or a second spelling of `x.m a`.
- **The syntax is unfamiliar.** It is OCaml's object-send symbol, and no mainstream language uses it
  for this.
- **It reads as noise in the cases that matter most**, such as `xs#length`.
- **`#` is free today**, and no design document reserves it: attributes, schemas and markup use
  none. But taking it for this spends one of the few ASCII punctuation marks beni has not used.
- **It needs a lexer token, a formatter rule and a diagnostic for `x.m` where `x#m` was meant.** That
  diagnostic is §12.5's hint again, now pointing at `#`.

It buys what §4.2 buys, a visible call, without the pun.

**Precedent.** OCaml `p#get_x`; Lean's `|>.` and Roc's old `->` show that languages do mint a second
operator for a second kind of call. Roc reversed its `->` within a year [V, §1].

### 4.4 Status quo

```elm
total = List.copy current.trail ++ other.trail
```

**Rule.** As now: `x.m` is a field, and a nullary method is `M.m x`.

**Costs.**

- **Two spellings by arity.** `xs.take 3` but `List.length xs`, so a reader switches between subject
  first and function first by the method's arity.
- **Pipes do not rescue it.** `current.trail ▷ List.copy ++ other.trail` parses wrongly (§3.5).
- **The ownership checker's own fix text** (`src/own/Message.zig`) has to print the prefix form.
- **A frequency fact the change would be measured against.** `List.length` appears 525 times,
  `String.length` 114, `List.reverse` 95 and `List.copy` 23. These are whole-word matches,
  `grep -rhoE '\bList\.length\b' --include=*.beni core platforms tests bench examples | wc -l`, with
  `references/` excluded. A per-line count over a different tree gives smaller numbers.

**Precedent.** Gleam, Elm, and Roc with `()`.

### 4.5 Rejected variant: a record discharges a method requirement with its field

This would make §4.1's last row *promote* to `where a.m : a → b` instead of defaulting to a field, and
let a record satisfy it with its field as evidence, like Haskell's `HasField`. `size xs = xs.length`
would then be polymorphic over lists and records alike.

**Costs.**

- Every unannotated record-reading function changes its inferred type from a row to a `where` clause.
- Evidence passing appears on record reads, the hottest path in a `view`.
- Generalised field evidence is exactly what §11 *Deferred receiver* decided the calling convention
  does not have.

The change is much larger than the problem.

---

## 5. Recommendation

Take §4.1. The receiver's type decides, as it already does for `x.m a`: a record gives its field, a
nominal type calls `M.m x`, and an unknown receiver waits until it is known, defaulting to the field at
generalisation.

beni is the one language in the survey where a type-directed bare `x.m` has no shadowing hazard,
because records and nominal types share no names. It reuses the checker's existing deferred-receiver
machinery, and it gives the motivating line, `current.trail.copy ++ other.trail`, exactly the spelling
the owner asked for, with the ownership summary of `copy` applied to it.

**What it breaks or costs.**

- `x.m` stops telling a reader that it is free.
- An unannotated helper reading a method silently infers a record type and fails at its caller.
- Record aliases still get no nullary methods.
- Every path-walking consumer must see the retagged call, and a missed one is a silent wrong answer. That
  is why the retag, rather than a lookup in every pass, is part of the recommendation.

**The spec work it needs**, in order (rule 1):

1. `static-dispatch-spike.md` §1.1's table and the paragraph under it, §1.2's new row for the
   generalisation default, §11's *nullary method is unreachable* limit, and §8.3's zero-argument
   `method_call`.
2. `language.md` §6.3, and §12.5's two hints.
3. A note in `ownership-checker.md` and `write-sets.md` that a retagged nullary call is a call.
4. A core pass deciding which one-parameter functions read well as properties. That is a naming
   question, not a compiler one.

**One alternative is worth keeping in mind:** if the owner values a visible call above the shorter
spelling, §4.3's `x#m` is the honest form of that choice. §4.2's `x.m ⊤` is not, because it is
type-directed anyway.
