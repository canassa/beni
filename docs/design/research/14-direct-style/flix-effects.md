# Flix: effect inference by Boolean and set unification

**Commissioned by** `01-solution-space.md` §3 option S4 ("Effect typing with handlers: rows or
capabilities") and §5 item 3 ("Higher-order functions with effectful callbacks"), which found that
Koka and Effekt solve effect-polymorphic higher-order functions with rows at a documented cost
(let-generalisation breaking under `val`, whole-block error diffs, no formatter). Flix is the one
production language in this family that does not use rows: effects are a Boolean/set algebra
unified like ordinary Hindley-Milner types. This report asks whether that buys the same
higher-order-function ergonomics at a lower or different cost, and whether Flix's handler runtime
— built for the JVM, which like JavaScript has no native delimited continuations — tells beni
anything about compiling handlers to JS.

**Sources.** `doc.flix.dev` (`effects-and-handlers`, `purity-reflection`, `associated-effects`,
`error-handling`, `exceptions`, `effect-polymorphism`, `foreach`, `research-literature`), fetched
directly 2026-09-14. The Flix compiler source on `github.com/flix/flix` `master` (via
`raw.githubusercontent.com` and the GitHub API): `language/phase/unification/{BoolFormula,
EffUnification3,SetFormula}.scala`, `language/phase/EffectBinder.scala`,
`language/phase/jvm/GenEffectClasses.scala`, `language/phase/jvm/classes/GenResumption.scala`.
GitHub issues and discussions via `gh api` (search and GraphQL): #9446, #10783, #704, #8042,
#13229, discussions #5200 and #12274. Semantic Scholar's Graph API for the four papers' abstracts,
since `dl.acm.org` 403s non-browser clients (matching `00-landscape.md`) and no readable mirror
was found — `drops.dagstuhl.de` served the ECOOP 2023 PDF but this session has no PDF-to-text
tool, so that paper rests on its abstract plus the doc page walking the same example. **This
session's WebSearch budget was already exhausted before this report began**; everything after
used direct `WebFetch` and the GitHub/Semantic Scholar APIs, which is why no Reddit/HN/Discourse
threads appear below.

---

## 1. The mechanism

An effect annotation is written as a set: `def divide(x: Int32, y: Int32): Int32 \ DivByZero`, or
`\ {Ask, Say}` for several. Internally it is a Boolean formula over that set: `Type.Pure` is ⊥
(empty set, pure), `Type.Univ` is ⊤ (impure/unknown), a declared effect symbol is an element, and
an effect-polymorphic variable is a Boolean variable — confirmed in the compiler,
`EffUnification3.scala:148-163`, which lowers `Type.Univ → SetFormula.Univ`, `Type.Pure →
SetFormula.Empty`, an effect constant to `SetFormula.mkElemSet`, a flexible variable to
`SetFormula.Var`. Subtraction (`ef - Amb`) and complement are ordinary set operations; the
compiler's `BoolFormula.scala` (`Copyright 2022 Magnus Madsen`) shows the algebra is literally
`True | False | Var | Not | And | Or`. Unification translates both sides of an equality to
`SetFormula` and calls `SetUnification.solve`, run in two passes — "Phase 1: Try to solve without
subeffecting" (exact set equality) and, if that fails, "Phase 2: With subeffecting" using slack
variables to permit `ef ⊆ ef'` rather than `ef = ef'` (`EffUnification3.scala:96-125`). The
algorithm is successive variable elimination over Zhegalkin polynomials on a cofinite (not finite)
integer-set lattice, because Flix's effect universe is open — users declare new `eff`s, so
"everything except {A, B}" must be representable without enumerating every other effect that
exists. The published account is Madsen and van de Pol, *"Polymorphic Types and Effects with
Boolean Unification"* (OOPSLA 2020): *"We show how to support type inference by extending
Algorithm W with Boolean unification based on the successive variable elimination algorithm"*
(abstract; full PDF unreachable, see Sources). What the type system must know, beyond ordinary HM:
nothing structural like a row kind or a type class — an effect is just another type with its own
small algebra of constructors, unified by a dedicated solver instead of syntactic equality.

Flix has no bind syntax at all for effects, because an effectful call is an ordinary call — the
problem `fetchSummary` exists to solve in Elm does not arise the same way. The literal
`fetchSummary` from the brief, written with `getUser`/`getPermissions`/`getAuditLog` as
operations of a user-defined effect and failure as a second, non-resumable effect (Flix's
idiomatic shape for "this can go wrong", per `exceptions.html`'s advice below):

```flix
eff Http {
    def getUser(): User
    def getPermissions(user: User): Permissions
    def getAuditLog(user: User): AuditLog
}
eff HttpError { def raise(msg: String): Void }

def fetchSummary(): Summary \ {Http, HttpError} =
    let user  = Http.getUser();
    let perms = Http.getPermissions(user);
    if (perms.isAdmin) {
        let log = Http.getAuditLog(user);
        Summary(user, perms, Some(log))
    } else
        Summary(user, perms, None)

// bind inside a loop:
def printAll(ids: List[UserId]): Unit \ {Http, HttpError, IO} =
    foreach (id <- ids)
        println(fetchOne(id))
```

Flat, straight-line, no nesting at the branch or the loop — there is no continuation to build;
`let` is ordinary sequencing and the effect row is the only trace anything happened. The caveat:
this is bought by modelling failure as an effect, not a `Result` value — `error-handling.html`
shows Flix's actual `Result[e, t]` idiom is plain `case Ok`/`case Err` matching, with no bind
operator, `?`, or `do`-notation on that page or `exceptions.html`. Sequencing `Result`-returning
calls without effects reproduces Elm's pyramid exactly: Flix solves side-effect *tracking*, not
fallible-value *sequencing*, and the win is conditional on using effects, not `Result`, for
control flow that fails.

---

## 2. Effect polymorphism for higher-order functions

This is the specific question the report was commissioned to answer, and it is one line. From the
standard library (`api.flix.dev`, fetched 2026-09-14):

```flix
def map(f: a -> b \ ef, l: List[a]): List[b] \ ef
def forEach(f: a -> Unit \ ef, l: List[a]): Unit \ ef
```

One definition serves both a pure callback and an effectful one because `ef` is a Boolean set
variable like any other type variable: instantiate it to `Pure` (⊥) and `map` resolves to `Pure`;
instantiate it to `IO` and `map` resolves to `IO`. No duplicated `List.map`/`List.map!` pair
(Roc's answer to the same problem, `roc-purity-inference.md` §3.2, `01-solution-space.md` §5.3),
and no row-polymorphism machinery (Koka/Effekt's answer, same §). `ef` is inferred, not written,
at both `map`'s declaration and its call sites. `effect-polymorphism.html` documents one
restriction on where this generalisation is automatic: Flix performs *effect widening*
("sub-effecting") only "for (a) lambda expressions and (b) instance definitions" — a top-level
`def foo(): Bool \ IO = true` is a type error (`Expected type: 'IO' but found type: 'Pure'`)
because top-level signatures must match their inferred effect exactly, with no automatic
subsumption to a larger declared effect. A lambda argument or a trait instance method is not held
to that — its effect widens to fit the expected slot for free. That is the load-bearing asymmetry
behind `List.map`'s single definition: the flexibility Koka gets from row polymorphism, Flix gets
from set-inclusion subtyping applied only at abstraction sites.

---

## 3. Purity reflection

Purity reflection lets a higher-order function inspect, at the call site, whether the specific
function value it received is pure or effectful, and choose a different evaluation strategy per
case — the motivating use is lazy or parallel evaluation *only* when that cannot reorder or drop a
side effect. Madsen and van de Pol, *"Programming with Purity Reflection: Peaceful Coexistence of
Effects, Laziness, and Parallelism"* (ECOOP 2023, Distinguished Paper Award): *"The upshot is that
operations on data structures can selectively use lazy and/or parallel evaluation while ensuring
that side effects are never lost or re-ordered"* (abstract). The worked example, `Set.count`
(`purity-reflection.html`), matches on `purityOf(f)`: a `Purity.Pure(g)` case hands back a
statically-pure `g` usable with a parallel red-black-tree walk, a `Purity.Impure(g)` case falls
back to a single-threaded, order-preserving fold. This is a compile-time mechanism dressed as
runtime reflection, not a runtime type tag: the paper describes the implementation as "a
specialized compilation technique that eliminates this reflection feature at compile-time, with
negligible impact on performance and code size" (abstract). The exact specialisation strategy
(inlining per call site vs. a generated dispatch) was not recoverable from the doc pages or the
unreachable PDF — marked unverified below.

---

## 4. Inference in practice

Effect-error messages are raw Boolean-formula dumps, and Flix's own tracker treats this as an
open, acknowledged problem rather than a solved one. From #9446, *"Shown effect (Errors) are not
great"* (open): *"Effect errors are 1) big in trivial ways (even sometimes something like `IO +
Pure`) and 2) contain `& ~ef` and `⊕`"*, with an attached example ending `Unit \ IO & e35452996 \
(IO ⊕ (IO & e35452996)) ⊕ (IO & e35440102 & e35452996)` — a user reading unminimised formulas with
synthesised variable names (`e35452996`) in a type error, the same complaint
`koka-with-and-effects.md` §4.3 records for rows ("diff two rows by eye"), produced by a different
algebra. Three more open issues (#10401 "Effect errors", #10186 "Incorrect effect error", #10783
"Effect Errors: Examples and Ideas", literally a call to collect before/after examples) show this
is a maintained backlog, not a one-off report.

On Koka #401's hazard — extracting a local binding silently losing effect polymorphism because
`let`-generalisation does not generalise over the effect variable — Flix sidesteps the mechanism
rather than fixing it: issue #704 ("Add support for let-polymorphism (not just at the top-level)",
closed 2020) proposed generalising local `let`-bound functions; the only recorded comment is
*"This might be pushed back. For reference, see the paper 'let should not be generalized'."*
Flix's local `let`s are not generalised the way ML's are — only top-level `def`s are polymorphic
schemes — which removes Koka's bug outright, but reintroduces the §2 asymmetry: pull an
effect-polymorphic lambda out into a named top-level `def` and you must supply its effect
annotation yourself, since the automatic widening that applied inside the lambda position does not
apply to a `def`. No tracker issue describes users hitting this in practice; only the doc page
states the rule.

Users write few effect annotations by design — inference is the default path, and the examples
above are typical: no `\ ...` clause until the compiler requires one, with a top-level `def`'s own
exact effect the only mandatory case. No forum or blog complaint about annotation burden was found
(no search budget was left to look for one).

---

## 5. Handlers and compilation

Flix targets the JVM only — no JavaScript, WASM or other backend exists. The JVM has no native
delimited continuations, so handlers compile to an explicit, heap-allocated continuation rather
than any JVM-specific stack trick — the relevant fact for portability. `EffectBinder.scala` runs
before codegen and "transforms the AST such that all effect operations will happen on an empty
operand stack in `GenExpression`", because the JVM's operand stack cannot be captured and later
resumed; the pass ANF-normalises around every "pc point" (`do`, non-tail call, `try`-`with`) so
the compiler always knows what live state must be reified. `GenEffectClasses.scala` compiles each
`eff` to a JVM class implementing `Handler`, each operation a static method packaging its
arguments and a wrapped continuation into an `EffectCall`; `GenResumption.scala` compiles the
continuation to a `Resumption` interface — a `rewind` method over a cons-list of stack frames
invocable more than once, which is what makes multi-shot resumption possible (`drunkFlip` in
`effects-and-handlers.html` resumes one continuation twice: `resume(true) ::: resume(false)`).
None of this is JVM-specific (no `Thread`, no `Continuation`, no Loom virtual thread): it is
ordinary bytecode building ordinary heap objects, the "reify the frames, replay them" shape
`01-solution-space.md` §4 calls L2 rather than L3 (native host continuations) — arguing it
transfers to JavaScript in kind, though not for free: replaying a `rewind` chain by recursion
needs proper tail calls or a trampoline, and Madsen's own reason for not targeting WASM names
exactly this — *"We are interested in WASM. We are waiting for them to land tail calls and a GC"*
(GitHub discussion #5200, 2022-12-29). JavaScript guarantees no proper tail calls either, so a
literal port inherits the same open question beni's own L2/L3 lowerings already flagged.

---

## 6. What the designers say and what users say

Madsen's own account of choosing Boolean/set unification over rows was not recoverable at the
depth this report wanted — the OOPSLA 2020 paper (the natural source) returned a 403 from
`dl.acm.org` to non-browser fetches and no readable mirror was found; only the abstract was
recoverable: *"We present a simple, practical, and expressive type and effect system based on
Boolean constraints... supports parametric polymorphism, and preserves principal types modulo
Boolean equivalence"*. The follow-on ICFP 2023 paper frames the comparative motivation more
directly, arguing that even effect-polymorphic row systems "only admit indirect reasoning about
the absence of effects" and proposing complement/exclusion effects to fix that (abstract). Neither
quote is Madsen explaining, in his own words, why *this project* rejected rows outright at the
start; that rationale is likely in the OOPSLA 2020 related-work section, which this session could
not read. **None found** for that specific comparison in a source this session could reach.

Practitioner sentiment: the tracker issues in §4 are the only first-party user voices found, and
are bug-report-shaped complaints about error-message readability, not architecture complaints
about Boolean effects versus rows. Asked in discussion #12274 whether Flix is production-ready,
Madsen replied *"Yes, definitely. It is already being used in production for several years by some
people"* (2026-01-09) — adoption evidence, not opinion on the effect system specifically. **No
Reddit, Hacker News, Discourse or blog commentary on Flix's effect system was found**; this
session's WebSearch budget was exhausted before this report started, and GitHub/Semantic Scholar's
APIs do not index off-GitHub discussion.

---

## 7. Ranked summary

1. (documented) An effect is a Boolean/set formula over declared names, unified by a dedicated
   solver (`EffUnification3`/`SetUnification`), not row polymorphism — confirmed against source.
2. (documented) One `List.map` signature, `f: a -> b \ ef`, serves pure and effectful callbacks
   via an ordinary unification variable — the problem this report was commissioned to check,
   solved with no row kind and no duplicated stdlib function.
3. (documented) That flexibility has a scope limit: automatic effect widening ("sub-effecting")
   applies only to lambda arguments and trait instances, not top-level `def`s, which must state
   their effect exactly — Flix's analogue to Koka's extraction hazard, but a required annotation
   rather than a silent break.
4. (documented) Purity reflection (`purityOf`) lets code branch on a callback's purity to pick
   lazy/parallel vs. sequential evaluation without losing or reordering an effect; erased at
   compile time per the paper's abstract, exact specialisation mechanism not recoverable here.
5. (documented) Effect-error messages are unminimised Boolean formulas with synthesised names
   (`e35452996`, `⊕`, `~ef`), an open, self-acknowledged tracker backlog — the same complaint
   `koka-with-and-effects.md` records for rows, independent of the underlying algebra.
6. (inferred) Handlers compile to ordinary JVM objects (`Handler`, a reified `Resumption`
   cons-list, `rewind`), no JVM-specific continuation primitive, so the shape should transfer to
   JS; but replaying long resumption chains needs tail calls or a trampoline, which JS guarantees
   no more than the JVM.
7. (documented) Flix's `Result`-shaped errors use plain `case Ok`/`case Err` matching with no bind
   operator or `do`-notation — the effect system flattens side-effect sequencing, not
   fallible-value sequencing; the two are orthogonal here.
8. (unverified) Madsen's own rejection-of-rows rationale in his own words, from the OOPSLA 2020
   related work — full text unreachable this session.

**What could not be resolved.** Full text of the OOPSLA 2020, ICFP 2023 and PLDI 2024 papers
(`dl.acm.org` 403s non-browser clients; no mirror found; abstracts only, via Semantic Scholar).
The ECOOP 2023 PDF's formal typing rule for `purityOf` and its exact specialisation/erasure
algorithm (fetched, but no PDF-text tool in this session). Any Reddit/HN/Discourse/blog commentary
on Flix's effects (WebSearch budget was spent before this report began). Whether users actually
hit the top-level-`def` sub-effecting asymmetry from §4 in practice (only the doc page states the
rule; no tracker issue found describing it as lived experience).
