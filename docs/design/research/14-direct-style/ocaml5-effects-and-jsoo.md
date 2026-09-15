# OCaml 5 effect handlers, and what it costs to run them where there is no stack to switch

**Commissioned by** the shared brief for report 14, as the Tier 1 report on **the only system that
has actually shipped a compiler from one-shot, untyped effect handlers to JavaScript** — a language
where a bind is not a value passed to `andThen` and not a class-directed `do`, but an ordinary
function call that may, invisibly, suspend the entire call stack beneath it. `docs/design/research/
14-direct-style/00-landscape.md`'s entry for `ocaml5-effects-and-jsoo` asks specifically for
`compiler/lib/effects.ml`, the double-translation mechanism, whether wasm_of_ocaml uses JSPI, and
the PLDI argument for *not* typing effects; report 15 already covers OCaml's `let*` binding
operators (Family B) and `docs/design/research/14-direct-style/ocaml-let-operators.md` already
covers Lwt, Async and `ppx_let` in depth — this report does not repeat that ground. It goes to the
one mechanism boundary the other OCaml report leaves for here: **how a language with no delimited
continuations in its compilation target retrofits one-shot, non-local control flow onto that
target**, and what OCaml's own designers decided not to type, and why.

**Sources.** The OCaml manual's effect-handler chapter (`ocaml.org/manual/5.3/effects.html`, raw
HTML, code extracted directly) for the `perform`/`effect`/`continue` surface syntax and the
deep-vs-shallow, one-shot rules. Sivaramakrishnan, Dolan, White, Kelly, Jaffer and Madhavapeddy,
*Retrofitting Effect Handlers onto OCaml* (PLDI 2021, arXiv:2104.00250) — the PDF would not extract
as text, so the ar5iv HTML rendering was fetched and read in full (§1.1's five requirements, §2's
design rationale, §4's static semantics, and the related-work paragraph contrasting Effekt/Links/
Koka's type-directed CPS against OCaml's stack-based, untyped design — all quoted from that text,
not the abstract). The **js_of_ocaml repository** (`ocsigen/js_of_ocaml`, `master`, 2026-09-14) read
directly: `compiler/lib/effects.ml`, `compiler/lib/partial_cps_analysis.ml`, `runtime/js/effect.js`,
`runtime/wasm/effect.wat`, and the manual sources `effects.mld`, `debug.mld`, `errors.mld`,
`tailcall.mld`, `options.mld`, `wasm_overview.mld` fetched as raw `.mld` source (the rendered HTML
loses exact flag names). The **pull-request bodies** for the three PRs that built this feature —
Vouillon & Nicole's #1340 ("Effect handlers", 2022-11-30), Nicole's #1384 ("Effects: partial CPS
transform", 2023-01-13) and Guéneau & Vouillon's #1461 ("double translation", 2023-04-28) — fetched
via `gh api` in full, since the maintainers write their design rationale and measured trade-offs
directly into the PR description. `ocaml-multicore/eio`'s `README.md` and PRs #226 and #329. Two
Tarides blog posts read in full: *We're Moving Ocsigen from Lwt to Eio!* (2025-03-13) and
*Announcing `ciao-lwt`* (2026-03-05). discuss.ocaml.org read via its JSON/raw API for four threads:
*Tutorial: Roguelike with effect handlers* (topic 9422, 2022, Gabriel Scherer explaining why 5.0
shipped no handler syntax), *Am I wrong about Effects? I see them as a step back* (10829, 2022),
*Next priority for OCaml?* (12561, 2023, post #62, Scherer again) and, decisively, *What's the
status of typed effects?* (18439, **2026-08–09**, four weeks old at the time of writing, Scherer
admitting the typed-effects working group he started in 2023 never gathered steam). Leo White's
2018 Jane Street tech talk *Effective Programming: Adding an Effect System to OCaml*, transcript
read in full, for the planned row-polymorphic, region-based typed-effects design. **This session's
shared WebSearch budget was already exhausted** when this report's research began; every source
above was reached by direct URL fetch, the GitHub API/`gh` CLI, and the Discourse JSON/raw API —
precise and dated, but no broad discovery sweep, so older (2022–2023) Tarides posts specifically
about js_of_ocaml's effects work, if any exist, are not cited; the PR bodies substitute for that gap.
**No original measurements were run; this report contains no performance claims** — cross-cutting
question 6 is answered "out of scope". All web sources accessed **2026-09-14**.

---

## 0. The three findings, up front

**1. OCaml effects are the one case in this research programme where there is nothing to
sequence — the mechanism this report was assigned to find is largely absent, and that absence is
the finding.** Reports 15 and `ocaml-let-operators.md` are about *notation for binding a value out
of an effect*: `let*`, `use`, `with`, generators. OCaml 5 effects need none of that, because
`perform` is an ordinary expression and a function that performs one looks exactly like a function
that does not. Leo White's 2018 Jane Street talk puts it as the goal from the start: a concurrent
`foo` function is plain recursive calls and an `if`, with `perform (Fork …)` and `perform Yield` as
the only marked points — "you could think of algebraic effects as resumable exceptions"
([Jane Street tech talk, 2018](https://www.janestreet.com/tech-talks/effective-programming/)). Eio's
README states the payoff in the same terms used elsewhere in this programme: effects let you "write...
concurrent code... in the same style as plain non-concurrent code" and mean "the function colouring
problem" does not arise
([`ocaml-multicore/eio/README.md`](https://github.com/ocaml-multicore/eio/blob/main/README.md)).
Where every other Tier 1 report answers "what do you write, what does it desugar to", this one
answers: you write a function call, and it desugars to nothing — the cost moves entirely into the
compiler backend and the runtime, where §2 and §4 go next.

**2. js_of_ocaml's mechanism is exactly the "compile handlers to JS without engine support"
answer the landscape doc asked for, and it is a *dataflow analysis deciding a boolean per function*,
not a type system.** `--effects=cps` performs "a partial continuation-passing style transformation"
([`manual/effects.mld`](https://github.com/ocsigen/js_of_ocaml/blob/master/manual/effects.mld)),
and which functions need it is decided by `partial_cps_analysis.ml`'s `cps_needed`: seeded by three
facts — a function containing `%perform`/`%resume` ("effect primitives are in CPS",
`partial_cps_analysis.ml:170`), a call site whose callee set is not fully known ("if we don't know
all possible functions at a call point, it must be in CPS", `:151`), and (without double-translation)
a closure that escapes (`:157`) — then propagated to a fixpoint over a dependency graph built from
`Global_flow`'s whole-program points-to analysis. **`double-translation` (PR #1461, 2023-04-28) does
not change what needs CPS; it changes what happens once something does** — instead of forcing the
CPS-tainted function's direct-style callers into CPS too, it keeps *both* a direct and a CPS copy of
every affected function and switches at runtime, "delayed to run time"
([`effects.mld`](https://github.com/ocsigen/js_of_ocaml/blob/master/manual/effects.mld)). Both are
selective, whole-program, effect-free-by-default transforms with no type or annotation driving them
— the opposite of Koka's, Effekt's or Links's *type-directed* selective CPS, which the PLDI paper
names explicitly as the road not taken (§3.2 below).

**3. The typed-effects promise that justified shipping effects untyped in 2022 has, as of last
month, been retracted by the person who made it.** Gabriel Scherer, an OCaml compiler maintainer,
told a user in 2022 that handler *syntax* was deliberately kept out of OCaml 5.0 because "we want to
give a chance to a type system for effect handlers... we don't want to encourage the ecosystem to
rely on untyped effects, if it means a lot of pain upgrading to typed effects later"
([discuss.ocaml.org, topic 9422 post #4, 2022-02-26](https://discuss.ocaml.org/t/tutorial-roguelike-with-effect-handlers/9422/4)).
In August–September **2026**, a new thread asked "What's the status of typed effects?", and Scherer
answered: *"A couple years ago I tried to get people to work on typed effects specifically for
OCaml, but I failed to gather steam and actually do it... I don't know of active projects to
retrofit effects into OCaml... I feel bad about this because I think that typed effects would be
much more usable than untyped effects, but this is not a consensus position"*
([discuss.ocaml.org, topic 18439 post #9, 2026-09-01](https://discuss.ocaml.org/t/whats-the-status-of-typed-effects/18439/9)).
Four and a half years elapsed between those two posts, from the same author, and the second is a
retraction, not an update. This is the sharpest primary-source evidence in this research programme
of a language shipping "not yet, we're keeping it open" and then, years later, admitting the open
question was never actively worked.

---

## 1. The effect model

Effects in OCaml 5 are **native, one-shot, delimited control transfer** — not values interpreted by
a runtime (as beni's own `Task` would be), not a monad, not generator-style cooperative suspension
bolted onto an ordinary function call. `perform` is a keyword-level primitive; performing an effect
transfers control to the nearest enclosing handler exactly the way `raise` transfers control to the
nearest enclosing `try`, and the manual says so directly: *"effect handlers are a mechanism for
programming with user-defined effects, generalising, e.g., exception handlers"*
([`ocaml.org/manual/5.3/effects.html`](https://ocaml.org/manual/5.3/effects.html), accessed
2026-09-14). What generalises the exception model is the handler's access to a **continuation** `k`
— the suspended rest of the computation between the `perform` and the handler — which the handler
may call zero, one, or (in principle) more times. In practice OCaml restricts this to **exactly
once**: *"our continuations are one-shot, and resuming the continuation more than once raises an
`Invalid_argument` exception"* (PLDI 2021, §2). "Sequencing two effects" is therefore not an
operation the language defines at all — it is just what evaluation order already does. `perform e1;
perform e2` sequences because OCaml evaluates left to right, the same as any two ordinary
expressions; there is no `>>=` to write because there is no monadic value being threaded through.

Declaring an effect extends a single extensible variant type:

```ocaml
type _ Effect.t += Xchg : int -> int t
let comp1 () = perform (Xchg 0) + perform (Xchg 1)
```

Handling it is a `try`/`with` clause extended with an `effect` pattern:

```ocaml
try comp1 () with
| effect (Xchg n), k -> continue k (n + 1)
```

(both blocks quoted verbatim from `ocaml.org/manual/5.3/effects.html`). `effect` is a keyword that
disambiguates the pattern from an ordinary exception pattern in the same `with` — **effects and
exceptions share one syntactic construct**, which is the mechanism's answer to cross-cutting
question 10 in miniature: nothing is collapsed into "native side effects" in the sense of losing
structure, but nothing is preserved as a first-class deferred value either. `Effect.t` is a GADT
(`'c Effect.t`) so the *payload and return type* of an effect are ordinarily typed — `Xchg : int ->
int t` means performing `Xchg n` type-checks only where an `int` is expected back — but **whether a
given call performs any effect at all, and whether a handler catches every effect the code beneath
it might perform, is entirely untracked.** That is the axis on which this report's "effect model"
answer differs from every class-directed or row-typed report in this series: OCaml effects are typed
*per constructor*, at the term level, and untyped *as a control-flow property* of a function's
signature. §3 covers why that was a deliberate, named decision rather than an oversight.

## 2. The mechanism

### 2.1 What the user writes: `fetchSummary`, faithfully

The brief's example is a `Task`-returning chain. Because OCaml effects are not `Task`, the same
program does not need a chain at all — it is the direct-style program a monadic library asks you to
imagine, written for real. Using the shape of Eio's networking effects (`ocaml-multicore/eio`):

```ocaml
let fetch_summary ~env () =
  let user  = get_user ~env in
  let perms = get_permissions ~env user in
  if perms.is_admin then
    let log = get_audit_log ~env user in
    Summary { user; perms; log = Some log }
  else
    Summary { user; perms; log = None }
```

There is no operator to name, because there is nothing to desugar. `get_user`, `get_permissions`
and `get_audit_log` are ordinary OCaml functions that, internally, `perform` an I/O effect and are
resumed by a scheduler's handler once the underlying operation completes; from the caller's
perspective they are indistinguishable from functions that block. **Every hard case in the shared
brief that exists only because binding a value costs a level of nesting simply does not arise**, and
that is the finding, not an evasion of the question:

- **Loop (Q1).** A bind inside a loop is an ordinary loop — the shared brief calls this "not
  expressible at all" for block-structured rewrites, but OCaml effects have no block-structure
  restriction to hit:
  ```ocaml
  let fetch_all ~env urls = List.map (fun url -> get ~env url) urls
  ```
  This is sequential by default (`List.map` does not fork); Eio's `Fiber.List.map` gives the same
  shape concurrently. Either way, no rewrite, no fold-in-place-of-a-loop workaround.
- **Branch (Q2).** `let log = get_audit_log ~env user in ...` sits directly inside the `if`-branch
  above and is usable in the branch's tail — no nested block, because `perform` does not need one.
- **Early return (Q3).** Effects compose with normal exceptions under the same `try`; `raise` inside
  an effect-performing function still unwinds to the nearest `try`, and a handler's `exnc` field
  (part of the full handler record: `{ retc; exnc; effc }`) is invoked if the handled computation
  raises rather than returns. `try`/`finally`-style cleanup is written the ordinary way, or, per the
  PLDI paper's own worked motivation (§2), by discontinuing a continuation with an exception so that
  intervening `try`s run their cleanup.
- **Pattern matching on the bound value (Q2/Q4).** `user`, `perms`, `log` are ordinary let-bound
  values; matching them is ordinary `match`. No wrapper type appears anywhere in this program.
- **Mixing two effect types (Q10 in miniature).** A function may `perform` several different
  `Effect.t` constructors and a handler's `effc : 'c. 'c Effect.t -> (('c, 'b) continuation -> 'b)
  option` decides per-performed-effect whether it handles this one or returns `None`, in which case
  OCaml's semantics *forward* the effect to the next enclosing handler (PLDI 2021 §4, rule
  `EffFwd`). Composing two unrelated effect-using libraries is therefore "install two handlers,
  outermost wins if it wants the effect, else it falls through" — no product type, no lifting.
- **Error propagation.** Ordinary exceptions, unaffected in kind by the presence of effects; this is
  exactly the ground `ocaml-let-operators.md` covers for `Result`/`let*` and is not repeated here.

### 2.2 Position, type-system demand, optimiser transparency (Q4, Q5, Q7)

**Position (Q5).** `perform` is an ordinary expression former — "anywhere an expression may", the
most expensive category on report 15's cost axis for *syntactic* rewrites, but here for free,
because nothing is rewritten at the source level at all. The cost this buys does not vanish; §2.4
shows exactly where it reappears (function-colouring at the compiler-IR level, not the syntax level).

**Type-system demand (Q4).** Nothing, in the sense report 15's table uses the word: no class, no
row, no builder, no name resolved by scope. `Effect.t`'s GADT index typechecks a `perform`'s payload
and result type against the extensible-variant declaration, the same mechanism that types ordinary
exceptions' payloads — a `Field` lookup, not an effect system. The PLDI paper is explicit that this
is a decision, not an oversight (§3 below expands it): *"Programs without matching effect handlers
are well-typed Multicore OCaml programs. As a result, our static semantics is simpler than languages
that ensure effect safety"* (PLDI 2021 §4.1, ar5iv text).

**Optimiser transparency (Q7).** At the OCaml-source level, trivially yes — a `perform` is a
function call the inliner, the pattern-match compiler and dead-code elimination all already handle.
At the js_of_ocaml level the answer inverts: once a function is CPS-converted it takes an extra
continuation argument and its calls become tail calls into that continuation, which is *more*
optimisable for tail-call elimination (`tailcall.mld`: "CPS transformed [code] can be fully
optimized") but changes the calling convention enough that **you can no longer call a CPS'd OCaml
function as a plain JavaScript function** — PR #1340's body states this as a direct compatibility
cost: *"it is no longer possible to call a JavaScript function as if it was an OCaml function...
When calling \[a] JavaScript \[function] from OCaml, you have to use `Js.Unsafe.call`"*
([js_of_ocaml PR #1340](https://github.com/ocsigen/js_of_ocaml/pull/1340), 2022-11-30). The
transform is not transparent to hand-written JS interop; it is a wall the FFI boundary must now
cross explicitly.

### 2.3 What js_of_ocaml actually does: the CPS transform and how it decides scope

`--effects=cps` performs, in the maintainers' own words, *"a partial transforming of the program to
continuation-passing style... The transformation uses an analysis to detect parts of the code that
cannot involve effects and keeps them in direct style"*
([`manual/effects.mld`](https://github.com/ocsigen/js_of_ocaml/blob/master/manual/effects.mld)).
"Partial" is not a hand-wave; it is `compiler/lib/partial_cps_analysis.ml`, a fixpoint dataflow
analysis over a dependency graph, seeded by exactly three rules (`partial_cps_analysis.ml:148-172`,
read directly from `raw.githubusercontent.com`):

1. A definition site of `%perform`, `%reperform`, `%resume`, `%with_stack` or `%with_stack_bind`
   forces its enclosing function into CPS ("Effects primitives are in CPS", `:170`).
2. A call site whose callee set is not fully statically known (`Global_flow`'s points-to analysis
   returns `Top`, or `Values { others = true; _ }` — "some call target we didn't enumerate") forces
   that call site into CPS, because the callee's CPS-ness cannot be checked ("If we don't know all
   possible functions at a call point, it must be in CPS", `:151`).
3. Without `double-translation`, a closure that **escapes** (is stored, returned, or passed
   somewhere the analysis loses track of) is forced into CPS too (`:157`), because it might later be
   invoked from a CPS context that expects a CPS callee.

These three seeds are then propagated by the solver both ways along call edges: "if a called
function is in CPS, then the call point is in CPS" and, in single-translation mode only, "if a call
point is in CPS then all called functions must be in CPS" (`partial_cps_analysis.ml:80-84`) — this
second, *backward* direction is what PR #1384 calls "horizontal contamination": *"a function needs
to be turned into CPS since it is used in a context which expects a CPS function, and then this
impacts all other places it is called"* ([js_of_ocaml PR #1384](https://github.com/ocsigen/js_of_ocaml/pull/1384),
2023-01-13), which names exactly where it bites: *"Higher-order functions such as `List.iter` are
turned into CPS and then all functions that call directly or indirectly such a function need to be
turned into CPS as well"* — Lwt, Async and Incremental are named as the libraries whose heavy use of
higher-order combinators makes the analysis least effective (`manual/effects.mld`). Nothing here is
type-directed: `cps_needed` is a `bool Var.Tbl.t` computed by a graph solver, not an inferred effect
row. Cited once, per the brief's rule for a performance-hinged design claim: the whole-program
analysis brought self-compiling `ocamlc` from 60% slower (naïve full CPS) to "only about ~10%
slower" (PR #1384 body) — not revisited as a performance section.

**`--effects=double-translation`** (PR #1461, merged 2023-02-02) changes what happens to a function
once it is marked CPS-needed, rather than shrinking the marked set: it keeps **two compiled bodies**
— direct-style and CPS — and picks at run time, defaulting to the fast direct-style body except
"when entering an effect handler, in which case only CPS is run until the outermost effect handler
is exited" (PR #1461 body). The stated reason: *"all benefits are lost as soon as an effect handler
is installed. This is an issue for scheduling libraries such as Eio, as they usually work by having
an effect handler installed for the program's entire lifetime"* (PR #1461 body) — under plain
`--effects=cps`, using Eio at all means the entire program runs in slow CPS for its whole lifetime,
because Eio's scheduler handler wraps `main`; double-translation exists so an Eio-shaped program is
not permanently CPS just because a handler sits near the top. The design cost the same PR names: *"it
is unclear how to deal with captured identifiers when the functions are nested. To avoid this
problem, functions that must be transformed are lambda-lifted"* — a whole extra IR pass exists
solely to make the two-copies-per-function scheme tractable.
`Js_of_ocaml.Js.Effect.assume_no_perform : (unit -> 'a) -> 'a` lets a programmer manually assert a
sub-computation performs no effects, running its direct-style copy even inside an installed handler
— an escape hatch that is, notably, **unchecked**: "The programmer must ensure that these functions
do not perform effects" (PR #1461 body); a wrong `assume_no_perform` is a silent-until-you-hit-it
correctness bug, not a compile error, the same asymmetry OCaml itself has at the `perform`/handler
boundary (§1).

### 2.4 wasm_of_ocaml: JSPI and the native WasmFX path

wasm_of_ocaml offers three modes and, unlike js_of_ocaml, one of them needs **no code transformation
at all**: *"`--effects=jspi` (default) uses the JavaScript-Promise Integration extension. It does not
require any code transformation but requires a runtime that supports JSPI"*
([`manual/effects.mld`](https://github.com/ocsigen/js_of_ocaml/blob/master/manual/effects.mld)).
JSPI moves the entire CPS-or-not decision out of the compiler and into the engine: a `perform`
compiles to an ordinary Wasm call that the engine, via the JS Promise Integration proposal, is able
to suspend and resume as if it were an `await`, without the compiler ever rewriting the function's
control-flow graph. The cost is availability, not code size: as of the manual read on 2026-09-14,
JSPI "is currently only available in Chrome 137 and Node.js 25 (or higher)... Use `--effects=cps`
for other browsers" (`manual/wasm_overview.mld`) — and where it is unsupported, the failure is a
**runtime error, not a compile-time one**: the Wasm runtime's own `effect.wat` was patched (PR
#1841, "Wasm / effects: error message when the JSPI API is not available") to catch the failed
`suspend_fiber` cast and call `caml_failwith` with the literal string *"Effect handlers are not
supported: the JavaScript Promise Integration API is not enabled"*
(`runtime/wasm/effect.wat`, fetched from the PR diff) rather than crash uninformatively. `--effects=
native` is a third mode, using the WebAssembly stack-switching (WasmFX) proposal's typed
continuations directly — no JSPI, no CPS — but as of the same manual read it needs
`--experimental-wasm-wasmfx` and is gated to "Chrome 148 or higher, or a recent Node.js canary
release (V8 version 14.7.100 or higher)" (`manual/wasm_overview.mld`). The three modes are a strict
ordering of *how much of the suspension mechanism the host is trusted to provide*: CPS trusts
nothing and pays for it in code shape; JSPI trusts a promise-shaped suspend/resume primitive; native
trusts full typed continuations. None of the three is type-directed, and none of them make the
handled/unhandled distinction static — an unhandled `perform` still raises `Effect.Unhandled` (or,
under JSPI, may surface as a rejected promise) regardless of which of the three compiled it.

## 3. History and decisions

**The decision this report exists to explain is negative: OCaml 5.0 shipped effects with no
handler syntax on the main branch at all**, despite Multicore OCaml — the research fork — having had
one since 2015. Gabriel Scherer explained the reasoning directly to a user who had written a
tutorial using the fork's syntax: *"that syntax was intentionally not upstreamed, and it will not be
part of OCaml 5.0... Effects as a language feature were removed from Multicore OCaml before the
upstream merge... The reasoning for this choice is that we want to give a chance to a type system
for effect handlers, but that still need quite a bit more time than the Multicore runtime itself. We
don't want to encourage the ecosystem to rely on untyped effects, if it means a lot of pain
upgrading to typed effects later (or risk having to support both)"*
([discuss.ocaml.org, topic 9422 post #4, 2022-02-26](https://discuss.ocaml.org/t/tutorial-roguelike-with-effect-handlers/9422/4)).
5.0 shipped only "basic support for effect handlers as a runtime primitive" — meaning `Effect.perform`
as a library function usable via `Stdlib.Effect`, with the pattern-matching `effect` keyword syntax
*retained* (the manual example in §2.1 uses it), but the explicit party line was "don't use them
directly, let a library like Eio wrap them" (Nicolas Ojeda Bär, same topic 9422 as summarised in
topic 10829 post #7).

The PLDI 2021 paper is the primary source for *why untyped, one-shot* was the shape chosen, argued
against two live alternatives named in the paper itself:

- **Against CPS as the compilation strategy** (relevant directly to js_of_ocaml, which had no choice
  but to use it): *"with CPS, an explicit stack is absent, and hence, we would lose compatibility
  with tools that inspect the program stack. Hence, we choose not to use CPS translation and
  represent the continuations as call stacks"* (PLDI 2021 §2). This is requirement **R2, Tool
  compatibility**, one of five stated up front: *"OCaml programs with effect handlers produce
  well-formed backtraces and remain compatible with program analysis tools... that inspect the stack
  using DWARF unwind tables"* (§1.1). Native OCaml keeps this promise using real, malloc'd fiber
  stacks for continuations; **js_of_ocaml cannot**, because JavaScript gives it no stack to switch —
  precisely why it must CPS-convert, and precisely why R2 does not hold once code crosses to JS (§4).
- **Against multi-shot continuations:** *"our continuations are one-shot, and resuming the
  continuation more than once raises an `Invalid_argument` exception... continuations will be
  resumed at most once, and copying fibers is unnecessary and inefficient"* (PLDI 2021 §2) — a
  scoped trade-off, citing Bruggeman et al. 1996 for one-shot continuations admitting a cheaper
  implementation than multi-shot.
- **Against an effect-safety type system, for this release:** *"The search for an expressive effect
  system that guarantees that all the effects performed in the program are handled (effect safety)...
  is an active area of research... our implementation of effect handlers in OCaml does not guarantee
  effect safety. We leave the question of effect safety for future work"* (PLDI 2021 §2, naming
  Leijen 2017b/Koka, Biernacki et al. 2019/2020, Hillerström et al. 2020). The same section names the
  systems OCaml chose not to be: *"Effekt..., Links JavaScript backend..., and Koka... use
  type-directed selective CPS translation. These languages are equipped with an effect system, which
  allows compiling pure code in direct style and effectful code in CPS"* — the same selective-CPS
  shape js_of_ocaml later built, minus the type system driving the selection (`koka-with-and-effects.md`
  covers Koka's version).

**Unhandled effects were a designed-in escape hatch, not a gap.** The paper's static semantics admit
that *"if the function performs an effect with no matching handler, then the function will not
return at all. To remedy this, when such an effect bubbles up to the top-level, we discontinue the
continuation with an `Unhandled` exception so that the exception handlers may run and clean up the
resources"* (PLDI 2021 §2, formalised as rule `EffUnHn` in §4.1). `js_of_ocaml`'s runtime
reimplements this verbatim: `runtime/js/effect.js`'s `caml_raise_unhandled` throws
`caml_make_unhandled_effect_exn`, and `caml_resume_stack` opens with `if (!stack)
caml_raise_constant(caml_named_value("Effect.Continuation_already_resumed"))` — the JS mirror of the
native one-shot check. **The compilation target changes nothing about which programs are well-typed;
a program that performs an unhandled effect is well-typed OCaml both natively and compiled to JS,
and crashes at runtime in both.**

**What was withdrawn or never shipped (Q9).** Three items: (a) the pre-5.0 handler *syntax* from the
Multicore fork, deliberately not upstreamed, as above; (b) shallow-handler syntax — the manual states
plainly "OCaml does not provide syntax support for shallow handlers" (only the library-level
`Deep`/`Shallow` module distinction exists; the `try...with effect` sugar is deep-only); (c) the
typed-effects project itself, covered next because it was never formally announced as withdrawn — it
simply stalled, which §5 treats as the more interesting failure mode.

**What the planned typed design looked like.** Leo White's 2018 talk, four years before OCaml 5
shipped, demonstrated a working prototype effect system built on **row polymorphism** ("I'm mostly
getting away with using row polymorphism"), with functions carrying an inferred effect row, an
explicit *effect-polymorphic* case for higher-order functions ("a map takes a function, does some
effects... It's polymorphic in its purity essentially — this is effect polymorphism"), and
**regions** scoping effects like local mutable state and file handles to a lexical extent. He
stressed the inference stayed "very much still in the realms of the principal" — no bidirectional
type-checking concession — because "OCaml['s] major strength is its inference is extremely strong".
None of this shipped; §5 covers where it went.

## 4. Costs — ergonomic and structural

**Q6, per-bind and per-call cost, is explicitly out of scope for this report** per the shared
brief's rule against benchmarks, timings and allocation counts. Where a PR body states a number as
the designer's own justification for a decision (e.g. PR #1384's "~10% slower" versus "60% slower"
motivating why the partial analysis exists at all), it is quoted once in §2.3/§3 as the *reason a
choice was made*, and this section does not repeat or extend those numbers.

**Diagnostics and locations (Q8) split cleanly along the compilation boundary, and only one side of
it survives.** Native OCaml keeps its exception-handling promise for effects because a continuation
*is* a real call stack (§3's R2); DWARF unwind tables, debuggers and profilers see through it exactly
as they see through a normal call. **js_of_ocaml's `--effects=cps` gives up exactly this property**
for any function the analysis marks CPS-needed: there is no longer a JavaScript call stack shaped
like the OCaml call graph, because the "stack" is now a chain of closures invoked in tail position.
By default "OCaml exceptions don't carry JavaScript stack traces" at all —
`Js_error.attach_js_backtrace` must be called manually, or the program run with
`OCAMLRUNPARAM=b=1` / built `--enable with-js-error`, to capture a JS `Error`'s stack at the throw
site (`manual/errors.mld`); that stack is captured by the engine walking whatever the JS call stack
looks like at that instant, which under `--effects=cps` is the CPS trampoline's frames, not the OCaml
call graph's. Source maps (`--source-map`, `manual/debug.mld`) still map generated-JS *lines* back to
OCaml source, but a CPS-transformed function's lines no longer correspond one-to-one to the source
function's control flow the way tail-call-optimised direct-style code does (contrast
`manual/tailcall.mld`'s plain trampoline-and-counter JavaScript for ordinary mutual recursion). No
js_of_ocaml source found in this research states a specific fidelity guarantee for CPS-converted
code; recorded as "no verified claim found" (§8), not asserted either way.

**Optimiser and FFI opacity (Q7, expanded).** §2.2 already covers the calling-convention break PR
#1340 introduces. The cost compounds with `assume_no_perform`: an unchecked assertion that a piece
of code performs no effects, whose only failure mode if wrong is presumably a wrong runtime value or
a crash somewhere downstream, not a diagnostic at the assertion site (§2.3) — this is the same shape
of hazard the shared programme's `fast-compiler.md` rejects for beni's own `?` (a silently-wrong
answer chosen by an unannotated construct), reappearing here as a manually-written escape hatch
rather than an inference ambiguity.

**What newcomers get wrong.** The clearest documented case is a **library design bug born from the
untyped-effect ergonomics themselves**: Eio's `traceln` — the convenience `printf`-style tracer the
README recommends throughout — is implemented by performing an effect to fetch the active event
loop's trace sink, and used outside an event loop *"would crash with `Unhandled`"* ([Eio PR #226,
"Fallback for traceln without an effect handler"](https://github.com/ocaml-multicore/eio/pull/226)),
fixed by falling back to `stderr`. **The library built to showcase direct-style effect ergonomics
shipped an unhandled-effect crash in its own debug-printing convenience function** — as close to
primary evidence as this research programme gets that "an unhandled effect is a runtime exception"
is not a theoretical complaint but one the ecosystem's own flagship library tripped over.
Separately, `ocaml/ocaml#11423` moved `Unhandled` into the `Effect` module between alpha releases
(`eio#329`, "Qualify `Effect.Unhandled`") — a breaking rename as late as the release candidates.

**What it does to the compiler pipeline (Q4/Q5 restated as pipeline cost).** Nothing in the OCaml
frontend — no new constraint kind, no unifier work, because there is no effect-safety checking to do
(§3). All of the cost lives in js_of_ocaml's **middle end**: two new whole-program analysis passes
(`global_flow.ml`'s points-to analysis and `partial_cps_analysis.ml`'s fixpoint solve on top of it),
a lambda-lifting pass to make double-translation's two-copies-per-function scheme tractable (PR
#1461), and a CPS-rewriting pass (`effects.ml`, 1,245 lines) that special-cases tail calls and
stores exception/effect handlers in global mutable state rather than a stack of closures ("only the
current continuation is passed between functions, while exception handlers and effect handlers are
stored in global variables" — `effects.ml:20-33`), interacting with the separate tail-call
trampoline machinery (`tailcall.mld`). None of this is inference — it is backend analysis and IR
rewriting, closer to a state-machine `async` transform than to any binding-operator desugaring in
this series.

## 5. What users say

Evidence is thinner here than for a mature syntactic feature, because effects are three OCaml
release cycles old (5.0 was December 2022) and the practitioner conversation is still openly
contested rather than settled.

**Praise**, concentrated on the *absence* of monadic ceremony, from people who have done the
migration rather than only read about it. Simon Grondin, quoted by Tarides on his experience porting
code from Lwt to Eio: *"Eio helped me reason about my code, and I discovered bugs and problems
because of how much Eio had cleaned up the code. I uncovered hidden bugs in every program I converted
from Lwt to Eio. Every single one also ended up being faster, not because Eio itself was faster... but
because of the optimisations I could now afford to make, thanks to the reduced complexity"*
([Tarides, *We're Moving Ocsigen from Lwt to Eio!*, 2025-03-13](https://tarides.com/blog/2025-03-13-we-re-moving-ocsigen-from-lwt-to-eio/)).
That post is itself evidence of a scale claim worth recording carefully: Ocsigen — "Lwt's own
inventor and biggest user" — is migrating its own flagship framework off Lwt onto Eio, funded by an
NLnet/NGI Zero grant specifically to build automated migration tooling, because (in Tarides' framing,
not a quoted practitioner) monadic style's drawbacks are "creating an abundance of heap allocations
and introducing the function colouring problem".

**Complaints**, concentrated on exactly the untyped-effects ergonomics finding of §0.3. The 2022
thread *"Am I wrong about Effects? I see them as a step back"* (10829) opens with: *"Nothing is
hidden anymore, no unexpected runtime exceptions that appear out of the blue... there is no way for
you to know by reading the function signature, and there is nothing forcing you to handle such
scenario"* (Danielo Rodriguez, 2022-11-20). Replies split along a fault line still visible four years
later: several (`bluddy`, `sid`) defended the design as **transitional** ("untyped effects are
transitional. In the future, the effects will become typed" — `sid`); one (`nojb`) restated the
official guidance that effects are meant for library-internal use behind a monad-free API like
Eio's; and Gabriel Scherer added a **portability** complaint specific to this report's subject:
*"Currently the javascript targets don't support them. js_of_ocaml may support them at some point
(probably at some unknown performance cost to be paid by all code, not just effect-using code)...
Bucklescript and al.... may never support them at all"* (2022-11-21) — written while PR #1340 was
still in flight, evidence the JS-portability cost of effects was a live concern among OCaml's own
maintainers before this report's mechanism existed.

**Wishes**, concentrated on the stalled typed-effects timeline. From the August 2026 thread: *"the
current recommendation is... to use them purely on the implementation side, without exposing them to
the user"* (yawaramin, restating 2022's guidance as still current); *"as a semi-official position,
this is disappointing... That makes me want to avoid effects even more outside of concurrency"*
(`bluddy`, replying to Scherer's admission quoted in §0.3); and one dissent — Jane Street's
`handled_effect` library on OxCaml is cited as "typed effects" achieved via **modes** rather than a
row-typed system (`ColinMelendez`), suggesting the "typed effects" promised in 2022 and the "typed
effects" now shipping inside Jane Street's fork are not the same design. **Counting:** of the ~15
posts read across the two threads discussing typed effects directly, roughly two-thirds treat "typed
effects are coming" as settled fact as late as 2024–2025 (`rand`, topic 15513: *"my initial
introduction... that made me hyped for [effects], was Leo White's talk about typed effects"*,
2024-11-13), and the 2026-08 thread is the first found here where a maintainer states in public that
the project stalled — a shift in what users say over time, not a stable consensus either way.

## 6. What it would take to do this in beni

Beni is Hindley-Milner, has no typeclasses or row polymorphism (§3.1/§3 elsewhere in this
programme), targets JavaScript with no delimited continuations, and — per its stated guarantee —
well-typed code must not throw at runtime. Each of those four facts collides with a load-bearing
piece of OCaml's design:

- **No row polymorphism means beni cannot even attempt the typed-effects design OCaml wanted and
  never got.** Leo White's prototype needed row-polymorphic effect types and effect-polymorphic
  higher-order functions (§3) — precisely the "rejected on inference cost" decision report 15 and
  `fast-compiler.md` §3 already made. Adopting *OCaml's actual shipped design* (untyped effects) is
  available to beni without that cost, but §0.3 and §5 are the warning: the people who built it call
  the untyped-only state a stopgap they failed to move past, not a destination they recommend.
- **"Well-typed code does not throw at runtime" is the opposite of what OCaml chose.** PLDI 2021
  §4.1 states outright that "programs without matching effect handlers are well-typed... programs" —
  an unhandled `perform` is, by design, a well-typed program that crashes. Adopting OCaml-style
  untyped effects verbatim would violate beni's one fixed guarantee directly; it is disqualified by
  the wall, not by ergonomics.
- **No delimited continuations in the JS target is the one fact beni shares with js_of_ocaml, and
  its mechanism is the most directly transferable piece of this report.** `partial_cps_analysis.ml`'s
  three-rule seed set (perform-site, unknown-callee, escaping-closure) plus fixpoint propagation is
  a concrete, working, whole-program alternative to per-call generator allocation (`fast-compiler.md`
  §3.2's option B) or hand-rolling a state machine (option C) — but it is a **backend** technique for
  hiding suspension inside functions never marked async by the user, not a syntax proposal; it
  answers "how do you compile an effect handler", not "what does the user write to bind a value",
  which is report 15's question.
- **JSPI is the strongest argument in this programme for revisiting a Wasm-only future**, though the
  shared brief rules that out explicitly (§4 of `00-landscape.md`): a mode needing *no compiler
  transform at all*, because the engine provides suspend/resume natively, is the cleanest possible
  answer to "compile a suspension point to JS" — available today only behind a Wasm target and only
  in the newest two major browser engines.
- **What OCaml's own people would warn beni about, directly.** Scherer's 2026 admission (§0.3) warns
  against promising a future typed layer as the justification for shipping an untyped one now: OCaml
  told users for four years that untyped effects were a stopgap, and the stopgap became the
  destination because no one had the bandwidth to finish the harder design.

## 7. Ranked summary

1. **(documented)** OCaml 5 effects need no bind syntax at all — `perform` is an ordinary
   expression, so this report's assigned subject has no `fetchSummary`-style rewrite to describe;
   the mechanism answers "how do you compile a suspension", not "how do you write a bind".
2. **(documented)** js_of_ocaml's `--effects=cps` scope is decided by a whole-program dataflow
   fixpoint over three seed rules (perform site, unknown callee, escaping closure) in
   `partial_cps_analysis.ml`, not by any type or annotation — the opposite mechanism from Koka's,
   Effekt's or Links's type-directed selective CPS, which PLDI 2021 names as the road not taken.
2b. **(documented)** `--effects=double-translation` keeps two compiled bodies per affected function
   and switches at run time, specifically because installing one Eio-style top-level handler would
   otherwise force an entire program permanently into slow CPS (PR #1461).
3. **(documented)** wasm_of_ocaml's JSPI mode needs no code transformation at all — the suspend/resume
   burden moves to the engine — but is gated to Chrome 137+/Node 25+ as of the 2026-09-14 manual read,
   and fails at runtime, not compile time, where unsupported.
4. **(documented)** PLDI 2021 states the untyped-effects decision explicitly and scopes it: R2 (tool
   compatibility via real call stacks) is why OCaml rejected CPS as its native compilation strategy —
   the strategy js_of_ocaml is then forced into anyway, because JavaScript gives it no stack.
5. **(documented)** A compiler maintainer told users in 2022 that handler syntax was withheld from
   OCaml 5.0 specifically to leave room for typed effects, then told users in 2026 that the
   typed-effects effort he started never gathered enough contributors to produce a design.
6. **(documented)** Eio's own `traceln` debug helper shipped an unhandled-effect crash outside an
   event loop — the flagship direct-style library tripping over the exact ergonomics problem it was
   built to showcase the benefits of avoiding.
7. **(inferred)** Stack traces and source maps are reliable for js_of_ocaml code in general (per
   `debug.mld`/`errors.mld`'s manual attachment mechanism) but no source found states a specific
   fidelity guarantee for CPS-converted frames; treated as an open question, not a measured cost.
8. **(unverified)** Whether `Js_of_ocaml.Js.Effect.assume_no_perform`'s unchecked assertion has
   caused documented production bugs was not found in the sources reached this session.
9. **(inferred)** For beni, the transferable piece of this report is the CPS-scoping *analysis*
   (a backend technique), not any syntax; beni's HM-without-rows constraint rules out reproducing
   OCaml's abandoned typed-effects ambitions, and its "well-typed code does not throw" guarantee
   rules out reproducing OCaml's shipped untyped ones.

## 8. What could not be resolved

- **The PLDI 2021 PDF would not extract as text** (FlateDecode streams WebFetch could not decode,
  and no local PDF tool was available under the read-only rule); the ar5iv HTML rendering was used
  instead and cross-checked against the arXiv abstract metadata — adequate for every quote in this
  report, but the paper's figures and the exact operational-semantics typesetting were not verified
  character-for-character.
- **No source found stating a specific source-map or stack-trace fidelity guarantee for
  CPS-converted (`--effects=cps` or `--effects=double-translation`) code specifically**, as distinct
  from js_of_ocaml's general debugging story. `debug.mld`, `errors.mld` and `tailcall.mld` were read
  in full and none mentions effects as a caveat on source maps; this may mean the property holds
  by construction (source maps map generated-JS lines regardless of what produced them) or may mean
  it is simply undocumented. Recorded as "no verified claim found", not asserted either way.
- **Whether `assume_no_perform` misuse has caused reported production incidents** — no GitHub issue
  or discourse thread surfacing this was found; the search performed (issue search for "effects" +
  "backtrace"/"source map" in `ocsigen/js_of_ocaml`) returned unrelated runtime-review PRs.
- **Older Tarides blog posts specifically about js_of_ocaml's effects work** (as opposed to the
  general Eio/OCaml-5 posts found) were not located; the blog's listing page as fetched only reaches
  back to late 2024, and this session's WebSearch budget was already exhausted before this report's
  research began, so no broader archive sweep (e.g. via Wayback Machine or a site-specific crawl)
  was attempted. The PR bodies quoted in §2.3–2.4 are Vouillon's, Nicole's and Guéneau's own
  contemporaneous design writing and substitute for this gap in every case checked.
- **Whether the OCaml Workshop / ICFP talks the landscape doc names (Sivaramakrishnan, Dolan, White
  presenting this specific work, as opposed to Leo White's 2018 pre-OCaml-5 typed-effects talk found
  and used) exist as recordings or slides reachable without WebSearch** was not resolved; the PLDI
  2021 paper itself was treated as authoritative for that material instead, per the brief's
  preference for primary sources over secondhand summaries.
