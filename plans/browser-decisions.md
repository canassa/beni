# The browser platform — the owner's decision sheet

**Status:** synthesis **revision 2**, 2026-09-20. **Implementation is parked**; this sheet and
[`plans/browser-platform.md`](browser-platform.md) are the whole output of the browser design pass.

**What this is.** Six reports now feed this sheet. The first pass produced
[`research/24`](../docs/design/research/24-elm-browser-runtime.md) (**R24**, Elm's browser runtime as
built), [`research/25`](../docs/design/research/25-ui-architecture-design-space.md) (**R25**, the UI
architecture design space) and [`research/26`](../docs/design/research/26-browser-host-measured.md)
(**R26**, the browser as a host, measured). The owner then read revision 1 and said: *"I want built in
JSX in the language. Also, clone and research SolidJS 2. I want a Beni UI to be fast, as fast as
solid, the runtime cannot be a limitation."* Three more reports answer it:
[`research/27`](../docs/design/research/27-solid-2-as-built.md) (**R27**, Solid 2 as built),
[`research/28`](../docs/design/research/28-jsx-in-beni.md) (**R28**, JSX as a language feature) and
[`research/29`](../docs/design/research/29-rendering-strategies-measured.md) (**R29**, rendering
strategies measured).

**Ids are stable and never renumbered** (CLAUDE.md rule 2 applied to this sheet, because other
documents cite `W` ids). `W1`, `W4`, `W5` and `W10` are **withdrawn in place** — the text stays, marked,
with a pointer to what replaces it. `W6` was flagged for withdrawal and is **un-withdrawn**. New
questions continue the sequence at **W25**, and reports 27–29's own ids (`S1…S7`, `J1…J5`, `F1…F8`)
are folded in and cross-referenced in the table below so those reports stay navigable.

Every question has the same shape — *the situation in plain words · a small example · the options ·
what each costs · the recommendation and why · how reversible it is*, plus a **rule-7 check** on
anything that refuses something — and **none of them needs the reports to have been read.**

---

## What the owner asked for, and what the evidence says

Three sentences, answered directly.

### 1. "I want built in JSX in the language." — Yes, and here is the shape

It fits, and it is cheaper in beni than in any language in R28's survey. The reason is three
properties beni already has: `<` is never a prefix operator, so the position is free with zero
lookahead (R28 §3.3); shadowing is an error, so `<div>` has exactly one meaning in a file and the
"is this an HTML tag or a component?" problem does not exist (R28 §6.2); and string literals already
carry typed interpolation, so text children need no lexer mode (R28 §4.2). The recommended form, in
the typeahead's own view (R28 §11.2, `[proposed]`):

```elm
sync viewHit : Model, Hit -> Html Msg
viewHit model hit =
    <li class="hit">
        <span class="title">{hit.title}</span>
        <button class="fav" disabled={isSaving} onClick={Favourited hit.id (not isFav)}>
            {if isFav then "★" else "☆"}
        </button>
    </li>
```

Text children are **quoted** (`<p>"Hello ${name}"</p>`), a tag name is an **ordinary name**
(`<div>` is `Html.div` because the platform's prelude exposes it), an attribute desugars to a call in
the tag's namespace (`class="x"` is `Html.class "x"`), and `if`/`case` work inside `{…}` because they
are expressions — so there is no `<Show>` and no `<For>`. The whole feature is ≈1 300–1 900 lines of
Zig, of which **0–30 are in the lexer** and 80–150 in the checker (R28 §9.1). One restriction is
forced: an element may not be a bare application argument, because `f a <b` is a legal comparison
today — write `f (<div/>)` (R28 §3.4). The intrinsic element and attribute tables are a **platform
package's beni declarations**, never compiler knowledge (R28 §5.1).

**The honest finding, stated up front: the speed does not depend on JSX.** A pass that recognises
`Html.div [literal] [literal]` structurally can split a static template from dynamic holes exactly as
well as one that reads a JSX node — Leptos's default strategy *is* such a pass (R28 §8.1). What JSX
genuinely buys is (a) **typed child holes**, so `{hit.title}` with `hit.title : String` compiles to
`node.data = s` and no `Html.text` wrapper is ever written — Lustre's own migration guide names that
wrapper as the cost of the plain form (R28 §0 finding 5, §4.4); (b) a syntactic guarantee that the
structure is literal; and (c) familiarity. That accounting is why W32 recommends shipping JSX as
sugar *first* and the template optimisation as an independent recogniser second: both surfaces then
get the same treatment and the plain-call form is never the slow path.

### 2. "Clone and research SolidJS 2." — Done; what was learned

`references/solid` (`next`, 2.0.0-rc.9) and `references/dom-expressions` are vendored as shallow
submodule pointers. R27 read 24 312 lines of `packages/signals`, the Rust/Oxc JSX compiler and the
DOM runtime, and measured real Solid programs in headless Chrome. The five findings that matter here:

1. **The browser is the cost.** Solid's own share of building 1 000 rows is **3.35 ms of 21.9**; the
   rest is Chrome laying out a table. Updating 100 row labels costs Solid **0.12 ms** against 4.7 ms
   of relayout (R27 §10.4). *"An architecture 2× slower than Solid in its own layer is 2–15 % slower
   end to end."*
2. **Most of Solid's speed is its compiler, and that half is available to any architecture.** One
   HTML string cloned per instance, hole paths computed at compile time, static attributes baked in,
   one delegated listener for a thousand handlers, one grouped update effect per template root —
   none of it depends on signals (R27 §0.2, §6.2).
3. **Solid's team already ran beni's experiment.** On uibench, 96 cases, feeding a signal graph
   immutable snapshots with a keyed `<For>` beat their own store-plus-`reconcile` shape **96/96**,
   and their ruling is *"`reconcile` is … not for ingesting immutable snapshots (the snapshot is the
   diff)"* (R27 §7.8).
4. **R25's one named blocker on signals does not survive.** R25 §7.3 argued a signal library needs a
   fourth per-fiber slot for the "current observer". Solid's observer is two module-level variables
   restored in a synchronous `finally`; if tracked computations are `sync` — which A6 already decides
   — no fiber can interleave, so a plain module variable is correct (R27 §8.6). Tracking still does
   not survive an `await` in Solid, confirmed three ways, and Solid says it cannot be fixed (R27 §4.4).
5. **Solid 2's floor is the scheduler, not the renderer.** `@solidjs/signals` is ~75 % of an empty
   app's bundle, and ~14 kB minified of scheduling and async machinery ships in a program that does
   nothing asynchronous (R27 §10.3).

### 3. "As fast as Solid; the runtime cannot be a limitation." — Measured, with every caveat

R29 built **eight hand-written prototypes of what beni's compiler could emit**, ran them against ten
framework implementations from js-framework-benchmark plus a Solid 2 port, in headless Chrome 153,
using a line-for-line port of the official trace-based measurement rule. The answer:

**The Elm Architecture reaches Solid's speed and passes it, and the thing that gets it there is not a
virtual DOM.** A compiled template with per-hole `===` checks (prototype **P2**) beats Solid
2.0.0-rc.9 on **script time on 9 of 9 operations** and Solid 1.9 on 7 of 9 (R29 §7.3). Adding a
compiler analysis of which model fields feed which hole (**P3**) closes `select`, the one operation
where Solid 1.9 was ahead. A virtual DOM (**P1**) is the slowest architecture measured that is not
React, and on a static-heavy page it costs **146× a compiled template per message** (R29 §11.1).
Putting TEA on Solid's own runtime (**P4**) reproduces Solid 2's numbers exactly, for **12× the
bytes** (22 375 against 1 808 brotli, R29 §12.1).

**The caveats, all of them.** (i) Headless Chrome 153, one engine, one machine; totals are roughly 2×
the published ones and all of the difference is paint (R29 §1.5). (ii) The prototypes are
**hand-written**, so they bound what a compiler could reach rather than predict it, and they ship no
element vocabulary, no event system beyond one delegated listener, no XSS sanitisation and no runtime
(R29 §0.7, §14). (iii) **Most operations are paint-bound**: on seven of nine, the spread of script
between the best and worst sensible renderer is smaller than the paint every one of them pays (R29
§5.5) — `select` and `clear` are the two that are not. (iv) The manager re-ran the seven-subject core
on a quiet machine: **the ranking and the per-operation medians reproduce** (P3 < P2 < Solid 1.9 <
Solid 2 ≈ P4 < P1, per-op script within ~10 %), but the report's headline that P3 *reaches vanilla's
script cost* does **not** — that figure is a geometric mean of ratios dominated by sub-millisecond
operations and moved from 0.989 to 1.260 on re-run. **Read it as an ordering with a noise floor of
about ±0.25, never as a parity claim, and quote the per-operation medians instead** (R29, Manager's
validation note).

**What the requirement therefore demands of beni**, as a list:

| Requirement | Why | Question |
|---|---|---|
| **Compiled templates, not a virtual DOM** | P2 beats Solid 2 on 9/9 script; P1 is 146× a template on a static page | **W26** |
| **A written identity promise** — an untouched field of an updated record keeps its identity | `row === inst.row` is the whole of P2 and is only meaningful if an unchanged row is the *same object*. True today by construction, nowhere promised (R24 §6.8, R29 §2 fact 2) | **W27** |
| **An indexable sequence in `core/`** | `List` has no `get`; "swap rows 1 and 998" costs 64–81× an array and cannot be written better (R29 §10.3) | **W35** |
| **Keyed lists, typed** | what is keyed fully determines what is reactive (R27 §7.1 quoting Solid 2's own ruling); an unkeyed reorder attaches state to the wrong row | **W33** |
| **The field-dependency analysis, later** | worth `select` 1.71 → 0.49 ms; four fifths of it is the field diff, one fifth the selector pattern (R29 §7.4) | **W42** |

**And if the owner nonetheless wants signals as the programming model.** Three things are now true at
once. R27 §8.6 says it is **possible as an ordinary library**, because the fiber-slot objection
dissolves once tracked computations are `sync` — so W19's old text, which said the architecture was
"out of reach until the slot lands", is wrong and is amended below. R29 says it **buys no speed**:
signals are 1.6–1.8× the templates-and-holes approach on script and 12× the bytes, and P4 proves the
graph costs what the graph costs whatever sits on top of it. R25 §9.1 and R27 §9.1 list what it
trades: single source of truth, exhaustive messages, time travel, state serialisation. **Rule 7 says
the platform must not forbid it**: it is not a guarantee that is being protected, it is a choice. The
recommendation is therefore **unshipped, never forbidden, and the kernel not deliberately closed
against it** — the same position the sheet already takes on component libraries (W20).

---

## Answered by the owner

*(blank — the manager fills this in, in the shape of the effects sheet's block)*

| Item | Answer |
|---|---|
| **W2** | **As recommended** (2026-09-29): a defect is always logged and stops the app; a crash screen in development builds only; an optional `onDefect` hook later |
| **W3** | **As recommended** (2026-09-29): the hybrid rule — 256 operations between clock reads, a 1 ms slice — yielding through `MessageChannel`, one tier (no microtask yield loop); the numbers are platform constants. A one-shot bounded microtask flush (W28) is unaffected. Web Workers are a separate question, to be designed with effects and code splitting |
| **W6** | **As recommended** (2026-09-29), in the `browser-tea` platform: `subscriptions : Model -> Sub Msg` recomputed after every message and diffed against the live set; each live subscription is a scoped fiber whose finaliser removes its listener; a subscription's identity is a `compare`-able value. The platform also lets a command start a long-lived listener in a scope |
| **W7** | **As recommended** (2026-09-29), in the `browser-tea` platform: `Cmd.map` pushes a path segment onto a command's key, so two instances of one component never share a key; `Cmd.cancelAll` cancels a prefix; keys are `compare`-able values, idiomatically the program's own `Key` type. `boundary.md` §5.4's "k equatable" becomes `compare`-able. *Amended 2026-10-01 by W47*: the segment is written, `Cmd.map : Cmd a, k, (a -> msg) -> Cmd msg`, with no unkeyed `map`; `Cmd` and `Sub` are `browser` modules, `Tea.element` runs them (`boundary.md` §9.8.3) |
| **W8** | **As recommended** (2026-09-29): the platform's callback registration takes `sync` functions only, checked through `boundary.md` §4 (a `foreign` that receives a beni function the sibling may invoke declares that parameter `sync`); a handler that needs slow work spawns a fiber and returns |
| **W9** | **As recommended** (2026-09-29): `main : Program` is unchanged; a page has no exit code, and its only "exit" is an unhandled fiber death, which goes to W2's teardown |
| **W9, where a program mounts** | **Elm's rule** (2026-09-29, taken by the project's manager on the owner's delegation; reversible): a program is given the node it mounts at, `document.body` by default. `Browser.mountAt : Program, String -> Program` names the element by `id`; `Browser.programs : List Program -> Program` puts several programs on one page in one build, started in list order. A handler's message goes to the nearest mount node strictly above it, and events bubble on through outer programs. A missing or doubly used element throws at start. `backend.md` §15.11, *The program* and *Mount* |
| **`main` through an alias** | **Yes** (2026-09-29, taken by the project's manager on the owner's delegation; reversible): `main`'s annotation is compared with the platform's `program` through aliases, so `main : Tea.Program` builds; an alias is the same type and refusing it protected no guarantee (CLAUDE.md rule 7). `browser-tea` declares `Tea.Program`. `boundary.md` §5 |
| **W25** | **The Elm Architecture** (2026-09-29): one immutable model, a pure `update`, `view : Model -> Html Msg`, commands as the sheet describes; no signals as the programming model. Measured as fast as Solid with compiled templates (research 29: P2/P3) |
| **W26** | **Compiled templates, via Solid 2's JSX compiler** (2026-09-29): `view`'s JSX compiles to cloned static templates with numbered holes, ported from dom-expressions' Rust compiler; a hole is driven by `view` re-running and comparing its new value with the old one by reference, not by a signal. Never a virtual DOM |
| **W27** | **Yes, promised** (2026-09-29): the language guarantees that an untouched record field keeps its identity (the same object), and no optimiser may break it — the templates' reference checks depend on it. `lazy` is dropped: templates make it unnecessary |
| **W28** | **Copy Solid 2** (2026-09-29). A message does not render at once: the update is staged and one **microtask flush** renders — so several renders per frame are possible, as in Solid 2 (R27 §3.1–§3.2), not one per frame as the sheet recommended. An explicit synchronous flush (Solid's `flush()`; e.g. `Browser.flush ()`) replaces Elm's `stopPropagation`-implies-sync for controlled inputs. Effects that must see the DOM run after the flush has written it, as Solid 2's split effect does (R27 §3.3). R26's two constraints stand: post-render work is `sync`, and the patch pass batches DOM reads before writes. |
| **W29** | Solid 2's model: JSX compiles to cloned templates whose dynamic parts are functions the runtime wires up; how that meets TEA's `view` is settled with W25 (2026-09-29: the owner trusts Solid 2's choices for client rendering; take Solid 2's answer, as its JSX compiler and runtime implement it) |
| **W30** | Bare text children, as Solid 2 (2026-09-29: the owner trusts Solid 2's choices for client rendering; take Solid 2's answer, as its JSX compiler and runtime implement it) |
| **W31** | Lower-case tags are elements, Capitalised tags are components, as Solid 2 (2026-09-29: the owner trusts Solid 2's choices for client rendering; take Solid 2's answer, as its JSX compiler and runtime implement it) |
| **W32** | JSX and the template compilation ship together: JSX is the template compiler, as in Solid 2 (2026-09-29: the owner trusts Solid 2's choices for client rendering; take Solid 2's answer, as its JSX compiler and runtime implement it) |
| **JSX compiler** | **Copy Solid 2's JSX compiler** (2026-09-29): the reference implementation for how beni compiles JSX is dom-expressions' Rust compiler, `references/dom-expressions/packages/compiler` (OXC-based, ~24.5k lines of Rust) — its static-template extraction, hole classification, event handling and runtime calls are ported to Zig rather than designed afresh. The JSX items above (W29–W34) are answered in its terms. |
| **JSX targets** | **Platforms own the markup lowering, behind one compiler interface** (2026-09-29, replacing the same day's "fixed targets in the compiler"). The language owns JSX syntax, typing against the vocabulary a platform declares, and the guarantees. The compiler exposes one plugin interface: it parses and type-checks JSX and hands the platform a typed markup tree, which the platform's own Zig code lowers to JavaScript through the JsIr builder beni's emitter uses. Every rendering strategy is therefore platform code, not compiler code: `browser` supplies the `dom` template lowering (the port of Solid 2's compiler) and its runtime; `node` supplies `ssr`; anyone may write a virtual-DOM or plain-calls platform. Platforms are trusted code by design. Built-in platforms are Zig modules compiled into the beni binary, as `core/` is embedded; an external platform builds its own beni with the platform added through `build.zig`, with no dynamic loading. The compiler keeps the interface (typed markup tree + JsIr builder) stable, and a platform's Zig is part of cache keys and held to the determinism rule. |
| **Layers** | **The language, core, platforms and frameworks are separate** (2026-09-29). The compiler knows no architecture: TEA is not part of the language. TEA is provided as a platform, `browser-tea`, layered on a base `browser` platform (DOM APIs, the `dom` lowering and runtime, a low-level `Program`); another architecture is another platform on the same base. A platform may depend on another platform and re-export its modules — a change `boundary.md` must specify. W25's TEA is the default a new project gets, not something the language imposes. |
| **Research 36's questions** | **All seven accepted as recommended** (2026-09-29; `docs/design/research/36-solid-jsx-compiler-for-beni.md` §8): (1) platforms declare vocabulary with new keywords (`pub element`, `pub attribute`, `pub event`), not `foreign`; (2) HTML's nesting rules (void elements, implied end tags) are a fixed table in the `dom` lowering now, typed content categories later; (3) markup whose value escapes into a helper, `let`, branch or list is a block that patches when it is the same template and remounts otherwise — W29's answer, measured in the end-to-end slice with a helper-heavy page; (4) `For` keeps Solid 2's keying modes with no silent default, and a `For` over records without a key is a warning; (5) an event handler is a message or `payload -> msg` until effects land; (6) no mutable `ref`: an element handle arrives as a message, usable only in commands; (7) message-valued component props compare by identity at first. |
| **Spec review answers** | (2026-09-29) **Text follows Solid 2 exactly**: HTML character references in JSX text are decoded, and whitespace collapses by Solid's `trim_jsx_text` (all Unicode whitespace). **Keyed `Show` is kept** (`<Show when={x} keyed>` remounts when `x`'s identity changes); non-keyed conditionals stay `if`/`case`. **`class` and `style` get typed object/array forms** like Solid's (`classList`, a style record), compiled like Solid's helpers. **The lowering interface is stable under additive change**: adding optional fields or builder calls keeps old lowerings working; only a breaking change bumps its major version. |
| **W33** | Solid 2's list components (`For`, `Index`) instead of a keyed `Html` type (2026-09-29: the owner trusts Solid 2's choices for client rendering; take Solid 2's answer, as its JSX compiler and runtime implement it) |
| **W34** | Solid 2's event spelling and handling (delegated and native forms; the handler gets the event and calls `preventDefault` itself); payload types come from the platform's declarations (2026-09-29: the owner trusts Solid 2's choices for client rendering; take Solid 2's answer, as its JSX compiler and runtime implement it) |
| **W35** | **Yes, `core/Array`, immutable** (2026-09-29): an indexable sequence ships in `core/`, immutable like every beni value (field identity and purity depend on it). Its representation is chosen by measurement: popular persistent/immutable array implementations are benchmarked (operations, engines, memory, and bundle size, which is a concern) before the module is written. A local mutable builder is considered when effects land **Amended 2026-10-01, the owner: one sequence type.** After research 38 §15–§17 and research 46 (every candidate on every scenario), `List` becomes the only sequence type, array-backed with E1t's representation (research 38 §17.2: a plain array that becomes a 32-way trie with a claimable tail); there is no separate `Array` and no cons list. `[a, b]` literals and `x :: rest` patterns stay (the pattern is an O(1) view); code builds at the end with `push`. The compiler rule that turns an `x :: rest` walk into an index loop ships with it. **Amended 2026-10-01 again, the owner: list syntax.** `::` leaves the language. Lists are written, built and matched with brackets and a `...` spread, as in JavaScript: `[x, ...rest]` and `[...init, last]` as patterns, and `[...xs, 4]`, `[0, ...xs]`, `[...a, ...b]` as expressions. This holds whatever the prepend benchmark finds. O1 (a prepend warning) and O2 (keeping tail calls modulo cons for `::`) are withdrawn; O3–O5 are taken as recommended by the manager, reversible: views for pattern tails compared through `same`, `map`/`indexedMap` return their input when nothing changed, `tail`/`drop` return views. **Amended 2026-10-01, the owner: E1tp.** The array-backed `List` uses E1tp (research 46 §11): E1t plus a claimable head, so prepending (`[ x, ...xs ]`) is amortised O(1) like appending, access and updates unchanged, +429 bytes brotli. |

---

## The five-minute version

Six reports. **R24 read Elm's browser runtime line by line**: of its 25 pieces, twelve exist because
of the *browser* and beni needs an equivalent of each, and Elm's scheduler never yields — a
two-million-step chain froze the page for 372 ms and served zero animation frames.

**R25 asked what a UI looks like when an effectful call is just a call.** Its result: a `sync`
function has no suspension point, and a suspension point is the only place another fiber can
interleave, so **`sync update` is a compiler-checked proof that two in-flight effects cannot both
write the model**. Elm gets that free because JavaScript cannot suspend a stack; beni has to buy it,
and `sync` (already decided, A6) is what buys it.

**R26 measured the browser itself.** A fiber should yield through `MessageChannel` on a ~1 ms slice.
The microtask tier in the effects proposal is a mistake to withdraw, not a trade-off to tune:
yielding through microtasks every 64 ops is *worse than never yielding* (input p50 371 ms against
84 ms). A defect in a page kills nothing, so "fatal" is something the platform must implement. One
bundled file reaches `main` 3.0× faster on 4G than thirteen modules.

Then the owner asked for JSX and for Solid's speed, and three more reports answered.

**R27 read Solid 2 as built.** Solid's speed is, in order: getting out of the browser's way; the
**compiler** — templates, hole paths, delegated events — which is available to any architecture whose
compiler sees markup; and only last the signal graph. Solid's own uibench experiment has immutable
snapshots beating a mutable store 96/96. And the one objection that blocked a signal library in
beni — that it would need a fourth per-fiber slot — does not survive, because `sync` closes the hole.

**R28 designed JSX for beni.** An element is an atom at operand start only; text children are quoted;
a tag is an ordinary name; attributes desugar to platform-package calls; child holes are typed;
components take one record; and JSX desugars to exactly the calls the plain form produces, with the
template optimisation as an independent structural recogniser. ≈1 300–1 900 lines of Zig, no lexer
mode, no change to the interface hash or the throughput budget.

**R29 measured what a beni compiler could emit.** The Elm Architecture plus compiled templates plus a
per-hole reference check beats Solid 2 on script on all nine benchmark operations; a virtual DOM is
the slowest sensible architecture and 146× a template per message on an ordinary static-heavy page;
TEA over a signal graph is Solid 2 for twelve times the bytes. Most operations are paint-bound, so
the argument really lives in two of them. **The caveats are large** — one engine, hand-written
prototypes, and one headline figure that did not reproduce on re-run.

**So: TEA stays, and it stays on measured grounds rather than on assumption.** Seventeen questions
have to be answered before a browser-platform spec can be written; each has a one-line recommendation
below, so "go with the recommendations" is a usable answer.

| # | Question | Recommendation in one line |
|---|---|---|
| **W25** | Is TEA still the blessed architecture, and what shape is a command? | Yes — re-tested against the speed requirement, not assumed; a command is a function handed a `send`, with the thunk form defined over it in four lines |
| **W26** | Does `view` become a compiled template, or a tree the platform diffs? | A compiled template with one reference comparison per hole; the field analysis later; a virtual DOM only as a fallback, never as the architecture |
| **W27** | Does `language.md` promise that an untouched field keeps its identity — and does `lazy` come back? | Write the promise; it is load-bearing for the whole rendering strategy. `lazy` stays parked and is subsumed |
| **W28** | The render loop under templates: how many phases, what triggers a synchronous render? | Unchanged: one render per frame, an explicit render-now, one after-render phase. Solid's microtask flush is not a counter-example |
| **W29** | What is an `Html msg` value at run time, and where must the compiler fall back to building a tree? | **Open — this is the design's one unanswered technical question.** Settle it with a named prototype before `backend.md` §11 is written |
| **W30** | Are JSX text children quoted, or bare? | Quoted — it is the difference between a parser feature and a lexer rewrite |
| **W31** | Is a tag name an ordinary name, or does a Capital mean "component"? | An ordinary name; nothing is added to the language |
| **W32** | Does JSX ship before the template optimisation, or with it? | Sugar first; they are independent and the optimisation must serve the plain-call form too |
| **W33** | Are keyed lists a type, and is an unkeyed dynamic list a warning? | Yes to both: `Keyed msg` from `Html.keyed`, and a default-on root-package warning, because a proof is not available |
| **W34** | How are `preventDefault`/`stopPropagation` and an event's payload spelled? | Four named attributes per event; a typed payload per event with the raw `Event` reachable. Never Elm's silent decoder drop |
| **W35** | Does `core/` get an indexable sequence? | Yes — and measure a copy-on-write array against a 32-way trie before choosing which |
| **W2** | What does a defect do to a page? | Stop the scheduler and tear down the mount; a crash screen in development builds only |
| **W3** | The browser scheduler's default, and the microtask tier | `MessageChannel`, a ~1 ms slice counted as 256 ops then a clock read; **withdraw** the microtask tier |
| **W6** | Subscriptions: declared from the model and diffed? | Yes, and each live subscription is a scoped fiber. *Un-withdrawn: nothing in R27–R29 touches it* |
| **W7** | Are command keys namespaced? | Yes — `Cmd.map` pushes a path segment |
| **W8** | How does JavaScript call back into beni? | The platform's registration primitives take a `sync` function and nothing else |
| **W9** | What is `main` in a page, and what replaces the exit code? | `main : Program` unchanged; `Program` is the platform's mount descriptor; the harness reads a platform-defined global |

---

## Cross-reference — reports 27, 28 and 29's ids

So those reports stay navigable after their questions are folded in here.

| Report id | What it asked | Where it lives now |
|---|---|---|
| **S1** (R27 §11) | which of three ways of building a screen | **W26** |
| **S2** | should a computation keep tracking across a pause | **W19** (amended; it is no longer a blocker) |
| **S3** | how much of a frame may "work out what changed" take | **W36** (tier 2) |
| **S4** | control flow in markup: syntax or components | **settled by the grammar**, not a question — `if` and `case` are expressions, so a `case` in a hole is an expression (R28 §4.5). Recorded under *What is forced* |
| **S5** | a recoverable error boundary beside the fatal-defect rule | **W45** (tier 3) |
| **S6** | does beni advise against wide model records | **W39** (tier 2) |
| **S7** | are stores, proxies and `reconcile` out of scope | **W40** (tier 3) |
| **J1** (R28 §12) | quoted or bare text children | **W30** |
| **J2** | tag name: a name, or a Capital | **W31** |
| **J3** | the event-handler spelling | **W34** |
| **J4** | does `fmt` rewrite `<div></div>` as `<div/>` | **W41** (tier 3) |
| **J5** | JSX before the template optimisation | **W32** |
| **F1** (R29 §13) | data tree or compiled template | **W26** |
| **F2** | when the field analysis lands | **W42** (tier 2) |
| **F3** | an indexable sequence in `core/` | **W35** |
| **F4** | does `language.md` promise field identity | **W27** |
| **F5** | the change-detection budget | **W36** (tier 2) |
| **F6** | does `lazy` come back | **W27** (joined with F4 — they are one decision) |
| **F7** | is the equality-keyed selector a compiler pattern | **W43** (tier 3) |
| **F8** | anything left for signals as the programming model | **W19** (amended) |

And the withdrawals:

| Withdrawn | Replaced by |
|---|---|
| **W1** | **W25** (the architecture and the command shape, which survive) + **W26** (the virtual-DOM rider, which does not) |
| **W4** | **W27** |
| **W5** | **W28** |
| **W6** | *nothing — un-withdrawn, it stands as written* |
| **W10** | **W26** (there is no diff to write) + **W29** (the part that does survive: where a tree is still built) |

---

## Where the reports disagree, and how it is resolved here

Six from revision 1, unchanged, then nine new joins.

**1. Do gesture-scoped capabilities die when `update` leaves the handler's tick? — a real
disagreement, and R26 wins.** R24 §0.2 item 4 quotes Elm's documentation; **R26 §5.3 measured it and
it is not true** — `window.open` succeeded after a 4 900 ms macrotask hop, because transient
activation lasts five seconds in both engines. R24 §0.2 item 4 is withdrawn as an argument; `sync
update` still stands on R25 §4.3's atomicity proof. *Caveat: clipboard and fullscreen failed
synchronously in headless Chrome, so the spec must not claim them.*

**2. The microtask tier — R26 kills it, and nothing in R25 depended on it.** `Send msg` is
`sync (msg -> ())`, a synchronous call with no scheduler hop, so the withdrawal is clean. What it
creates instead is a re-entrancy hazard, recorded as an obligation in
[`plans/browser-platform.md`](browser-platform.md) §2.5, not as a question.

**3. "Render synchronously" (R24) versus "how many render phases" (R25 D8) versus rAF (R26) — two
axes nobody joined.** Compatible; **W28** states all three together.

**4. How strict is `sync`? — R26 refines R24, and both land in the same place.** A microtask hop is
still in time for `preventDefault`, and the conservative rule is still right, because whether a call
suspends only through a microtask is not something a caller can see. **W18.**

**5. Subscriptions — R24 asked, R25 answered.** **W6.**

**6. The size budget — R25's *"≤ 5 kB gzip"* is the fiber kernel's, not a renderer's.** W11 asks for
the browser number. **Revision 2 adds:** R24 §11.4's 35–50 kB estimate for a beni counter *assumed a
virtual DOM*, so it is now an estimate of the wrong thing — see
[`plans/browser-platform.md`](browser-platform.md) §2.6.

**7. R25 says a signal library is blocked; R27 says it is not. R27 wins, and W19 is amended.** R25
§7.3 and its §7.6 scorecard list *"a fiber-local observer slot — without it, silently wrong"*, and
the sheet's W19 said the architecture was out of reach until the slot landed. R27 §8.6 read Solid's
actual mechanism — two module-level `let`s restored in a synchronous `finally` — and produced a
four-step argument that a plain module variable is correct **provided tracked computations are
`sync`**, which A6 already requires and W8 already recommends for every callback crossing the
boundary. **Resolution: R27 is reading the mechanism and R25 was reasoning about it, so R27 wins.**
W19's text is amended in place: a signal library is *possible*, and the remaining question is
smaller — do we want tracking to survive a suspension, as a feature (S2)? Recommendation: no.

**8. Revision 1 assumed a virtual DOM; R29 measured it and it is the slowest sensible
architecture.** W1's third rider said *"`view` returns a data tree the platform renders — a virtual
DOM. No document in `docs/design/` specifies one."* R25 assumed one throughout and its own §13 listed
"whether beni has a virtual DOM at all" as undetermined. R29 §5.4 measures a *favourable* keyed vdom
(snabbdom's four-pointer diff, hoisted attribute constants) at **5.64 ms of script on `select`
against a template's 1.71** and §11.1 at **146× a template per message** on a static-heavy page.
**Resolution: R29 is measured and revision 1 was assuming, so R29 wins.** The rider is withdrawn;
W26 replaces it. Note what R29 is *not* saying: a keyed vdom with `lazy` is at or ahead of Solid 2 on
the structural operations (swap, remove, update-10th). It loses on the operation where the model
changes by one integer, and it loses catastrophically on a page that is mostly static.

**9. R28 says "desugar to `Html` calls and optimise by recognition"; R29's prototypes never build a
tree at all. This is not resolved — it is escalated as W29.** R28 §8.1 recommends lowering (i): JSX
becomes `Html.div [attrs] [kids]` in `bir/Lower.zig`, an `emit/` golden proves JSX and the plain form
emit identical bytes, and the template pass is a *separate structural recogniser* over that call
shape. R29's `p2-tpl` does something different: it clones a template and writes into holes, and there
is no `Html` value anywhere at run time. Both are right about their own half and neither addresses
the seam. **This is the one open technical question of the whole design and it gets its own id, its
own experiment and its own paragraph.** See **W29**.

**10. R27's "(B) now, (C) later" and R29's "P3 closes `select`" are the same recommendation — say
so.** R27 §0.5 defines strategy (B) as TEA + compiled templates + per-hole reference checks and (C)
as (B) plus a compiler-derived dependency graph, and insists *"(C) is not a different design from
(B); it is (B) with a compile-time narrowing of which holes to visit"*. R29 builds them as P2 and P3
and confirms it: P3 is P2 with a field diff, degrades to P2 where the analysis cannot prove what a
hole reads, and changes no program. **They are one recommendation with two rungs**, and W26 (rung 1)
and W42 (rung 2) split it that way. R27 §11 S1 said *"report 29 is built to test this and should be
believed over this paragraph"*; it was, and it agrees.

**11. R27's 18-field record-clone cliff versus the representation the identity promise pins.** R27
§5.6 measured beni's own emitted record update — `{...r, f: k}` — at 29.9 ns for a 17-field record and
**222.6 ns at 18**, rising to 986 ns at 64, because V8's fast object-clone inline cache bails out
above ~17 properties. `%HasFastProperties` is `true` on both sides, so it is not dictionary mode.
**A TEA `Model` of 20–40 fields is completely ordinary**, so this is not a corner case: every
`update` return would pay ~400 ns instead of ~30. Three things follow and they do not conflict, they
compound. (i) It is still 0.0025 % of a frame, and R29 §11.1 measured a 50-field record update at
**0.20 µs**, confirming it is not a crisis. (ii) It is an argument for **nested sub-records** —
`{ m | search = { m.search | query = q } }` allocates two small objects instead of one wide one — and
nesting is *also* what the per-hole check wants, because a hole should compare the record it reads
from, never the root model, which always changes (R27 §5.6). (iii) It is **not** an argument for a
different emitted representation: R27 measured field-by-field copying and it is *worse* (2.8 µs at 20
fields), and the identity promise (W27) forbids anything that re-materialises an untouched field
anyway. **Resolution: no conflict; it becomes guidance, W39, plus one measurement** — nobody has
measured whether a nested model's *two* small clones plus the extra hole indirection beat one wide
clone in a real view, and that measurement belongs beside the fallback prototype.

**12. R29's `List` finding versus what `core/` ships today.** `core/List` is a cons list and it is
the only sequence beni has: no indexed read, no indexed write, no `Array`, and `List.length` is a
fold. R29 §10.3 measured beni's real compiled `update`: `Swap` costs **64–81×** an array's, `Append`
degrades 9× → 28× with size, `List.length` is 20.8 µs at 10 000 rows — and `Remove` is *faster* on
the cons list at 10 000, which is why the comparison is not rigged. **The finding is not that `List`
is slow; at UI sizes the worst case is 0.21 ms, 1.3 % of a frame. The finding is that `get` does not
exist.** `backend.md` §4 has parked this in writing since M3 began — *"cons cells …, pending M3c's
benchmark of a vector trie"* — and R29 §10 is that benchmark. **Resolution: W35**, on rule 7's
ground that only `core/` may write `foreign`, so whatever it does not ship the language is
withholding. With R29 §10.4's caveat that the *shape* is a second, unanswered question.

**13. R27 §5.5's ~1 ns per hole versus R29 §7.4's ~68 ns per row — both right, and the difference
must not be lost.** R27 measured a per-hole reference-equality walk in Node at **0.93 ns per hole**,
flat in N. R29 measured P3-without-the-selector walking 1 000 row instances at **0.27 ms under 4×
throttling**, about 68 ns per row unthrottled. R29 §7.4 explains it: R27's walk is `a[i] !== b[i]`
over two dense arrays in a tight loop; R29's iterates a `Map`'s values and touches three fields of an
instance object before deciding. **The 1 ns figure is the floor of the technique, not what a renderer
pays.** Recorded so that W36's budget is set against 68 ns and not against 1 ns, and so that a
renderer keeping its instances in a dense array parallel to the model is recognised as the
optimisation it is.

**14. Nobody answered R27's Svelte-5 question, and it is the most valuable open one.** R27 §0.5's
prior-art table names Svelte 3/4's compile-time invalidation bitmasks as *"(C), shipped, at scale,
for six years"* and asks the single most valuable question either sibling report could answer: **why
did Svelte 5 replace it with signals?** If the reasons are Svelte-specific — component-granular
invalidation, a 31-bit-per-component limit, cross-component derived state — they do not transfer. If
they are fundamental to compiler-derived dependency graphs, they kill W42's rung 3. **R28 and R29 did
not chase it.** R28 read Svelte only for its markup grammar; R29 measured Svelte 5 as a subject
(geometric mean 1.186, script 1.788 — behind Solid 2) and read nothing of its history. **This is a
named unknown, and the cheapest way to retire it is primary-source reading, not measurement**:
Svelte's own RFC and the runes announcement, plus the `$$invalidate`/`$$dirty` code in a Svelte 4
tag, plus whether the 31-bit ceiling is discussed anywhere in the migration notes. It is experiment
**X3** in [`plans/browser-platform.md`](browser-platform.md) §3 — half a day, read-only — and it
should happen **before W42 is built, not before W26 is decided**: rung 1 does not depend on it at
all, which is another reason to sequence the rungs apart.

**15. R29's own re-run disagrees with R29's headline, and the manager's note wins.** The report's §0.1
says the field-directed prototype reaches *"the script cost of hand-written keyed vanilla
JavaScript"*. The manager's re-run on a quiet machine reproduces the ordering and the per-operation
medians but not that figure — it is a geometric mean of ratios dominated by sub-millisecond
operations, and vanillajs's own `swap` moved from 0.57 ms to 0.10 ms between runs, which alone shifts
the mean by ~20 %. **Resolution: the ordering is the result; the parity claim is not.** This sheet
quotes per-operation script medians and the ordering, and nothing anywhere should repeat the parity
figure.

---

## Tier 1 — must be answered before a browser-platform spec can be written

Seventeen. W26, W27 and W29 are the three everything in the rendering track waits on.

### W25. Is The Elm Architecture still the blessed architecture, and what shape is a command?

*(This is old W1 with its virtual-DOM rider removed and its recommendation re-tested rather than
re-asserted.)*

**The situation.** In Elm, `update` is a pure function returning a new model plus a *description* of
work; the runtime performs it and sends the answer back as another message. Under beni's effects
design there is no description — `getUser id` just performs. So: does the four-function shape
(`init`, `update`, `view`, `subscriptions`) survive, and what does a program hand back when it wants
something done?

R25 worked one example — a search box that debounces, cancels the stale request and optimistically
toggles a favourite — through five architectures. Two break: an `update` that may itself suspend
either freezes the text input for the length of an HTTP request, or lets two keystrokes race and
silently lose one (R25 §4.1–§4.2). The remaining three keep `update` pure and `sync` and differ only
in what a command is:

```elm
-- (a) a thunk plus a tagger: "run this, and turn the answer into a message"
Cmd.keyed SearchKey Restart (\() -> searchAfterDelay api q) GotHits

-- (c) a function handed a `send`, which it may call any number of times
Cmd.performKeyed SearchKey Restart (searchEffect api q _)

searchEffect api q send =
    let
        () = send (SaveStarted q)          -- progress, which (a) cannot express
        hits = api.search q
    in
    send (GotHits hits)
```

**Options.** (a) the thunk-plus-tagger form only; (b) the `send` form only; (c) the `send` form with
(a) defined over it — `run task tag = perform (\send -> send (tag (task ())))`, four lines.

**What each costs.** (a) is smaller but cannot express progress, streaming or "start two requests and
report each as it lands" without a second mechanism. (b) makes the common case wordier. (c) costs one
extra constructor. Two independent TEA descendants — TCA and Lustre — converged on the `send` shape
(R25 §5.1).

**Recommendation: (c), and this time it has been tested against the speed requirement rather than
assumed.** Revision 1 recommended TEA on architectural grounds and left the performance question
open; the owner's requirement made it the central question, and R29 answered it by building the
architecture and racing it. **The result is that TEA is not a speed compromise**: with compiled
templates it beats Solid 2 on script on all nine benchmark operations (R29 §7.3), retains **189 bytes
of JavaScript heap per row against a signal graph's 977** (R29 §9.1), and its runtime is ~1.7 kB
brotli against ~22 kB (R29 §12.1). R25's guarantees all survive because the rendering strategy does
not touch any of them: one model, a pure `sync` `update` applied atomically, exhaustive `Msg`,
messages as data, and therefore time travel (R29 §0.4).

**Two riders come with the answer**, and the owner is agreeing to them at the same time:

- **`sync` is on five signatures**: `init`, `update`, `view`, `subscriptions` and every event handler
  and tagger (R25 §3.7, §9.1).
- **The architecture is a library on a small kernel, not the language** (R25 §10): a root scope tied
  to the mount, a `sync` pure render, a `sync` event→fiber bridge, scoped subscriptions, one
  frame-aware loop. TEA ships blessed; nothing else is forbidden — including signals (W19).

*(The third rider of old W1 — "`view` returns a data tree the platform renders, a virtual DOM" — is
withdrawn. W26 replaces it.)*

**Rule 7 check.** This refuses one thing: `update`, `view` and handlers may not suspend. It buys
three guarantees — every message applied atomically, a render that cannot be half-done, and
`preventDefault`/`stopPropagation` that actually work. The restriction is paid for.

**Reversibility: low.** It is the type of every command in every program.

---

### W26. Does `view` become a compiled template, or a tree the platform diffs?

*(Folds R29 **F1** and R27 **S1**; replaces old W1's third rider and most of old W10.)*

**The situation.** The programmer sees the same thing either way: a function from the model to
markup. What differs is what the compiler emits. A **virtual DOM** builds a fresh description of the
whole screen on every message and compares it with the previous one. A **compiled template** builds
the unchanging markup once, and only ever revisits the places where a value can appear.

**The example.** A table of 1 000 rows; you click one row to highlight it. Median script
milliseconds, 4× CPU throttling, from a Chrome trace (R29 §5.4):

| what it does | ms |
|---|--:|
| virtual DOM: builds 9 000 objects describing every cell, compares them all, writes two `class` attributes | **5.64** |
| the same with Elm's `lazy`, written in the form that actually works | 2.31 |
| compiled template: compares 1 000 row records against last frame's, writes the same two attributes | **1.71** |
| the same, told by the compiler that only `selected` changed | **0.49** |
| Solid 2.0.0-rc.9 | 2.60 |
| Solid 1.9 (hand-written `createSelector`) | 1.38 |

And on an ordinary page rather than a table — 2 000 elements, 50 dynamic holes, one changing per
message — a virtual DOM costs **327.5 µs per message against a template's 2.25 µs**, which is 146×,
and 565× under 4× throttling (R29 §11.1). That page shape is almost every real screen.

**The options.** (a) a virtual DOM; (b) compiled templates re-run top-down with one reference
comparison per hole (R27's strategy B, R29's P2); (c) (b) plus compile-time knowledge of which model
fields feed which hole (strategy C, P3).

**What each costs.** (a) is the least compiler work and the most run-time work, and it is the option
that *needs* `lazy` to be competitive — which drags W27's identity promise along with it anyway, plus
a memoisation annotation on every list row whose correct form is not obvious and whose absence is
silent (R29 §6.3). (b) needs the compiler to split static markup from dynamic holes — which R28 §8.1
says it should do regardless of JSX, over ordinary `Html.div [..] [..]` calls — plus the language
property that `===` on an immutable value means "deeply unchanged", which beni has by construction
and W27 would write down. (c) adds one analysis, worth `select` 1.71 → 0.49 ms, of which four fifths
is the field diff and one fifth a syntactic selector pattern (R29 §7.4).

**Recommendation: (c), built as (b) first, and never (a) as the architecture.** The evidence is
above; the sequencing is because §7.4 measures that even a partial analysis pays, so nothing is lost
by shipping (b) alone — it is already ahead of Solid 2 everywhere. W42 owns the second rung.

**Three things the recommendation does *not* claim.** Most of these operations are paint-bound, so
end to end the gap is 2–15 % and not 3× (R27 §10.4, R29 §5.5). The prototypes are hand-written and an
emitter may not reach them (R29 §14). And the whole comparison is one engine on one machine.

**Rule 7 check.** Nothing is refused. A template renderer withholds nothing a virtual DOM offers: the
programmer still writes `view : Model -> Html Msg` and still has a data tree in the source; the
*compiler* stops materialising it. Where the compiler cannot prove a piece of markup is literal, it
must fall back to building and diffing nodes for that subtree — the virtual DOM retained as the
fallback rather than as the architecture. **That fallback is W29, and it is not yet designed.**

**Reversibility: medium.** It is a `backend.md` pass and a platform contract, not a type in every
program. But a program written against a `lazy`-bearing virtual DOM carries annotations a template
renderer has no use for, so (a) is not free to leave.

---

### W27. Does `language.md` promise that an untouched field keeps its identity — and does `lazy` come back?

*(Folds R29 **F4** and **F6**, R24 §6.8, and old W4. They are one decision: identity is what all of
them turn on.)*

**The situation.** beni emits `{ m | f = x }` as a JavaScript spread — a real build of
`tests/corpus/run/Records.beni` produces `({ ...p$2, x: Basics$add(p$2.x, dx$1) })` — so the new
record's every other field points at exactly the value it pointed at before (R29 §2 fact 2,
`src/js/JsIr.zig:199-204`). Because records are immutable, `row === inst.row` therefore means *row is
deeply unchanged*. R24 §6.8 established that this **holds today by construction and is nowhere
promised**, and that Elm never wrote it down either.

**Why revision 2 raises it from a `lazy` rider to a tier-1 question.** In revision 1 the identity
property was needed by exactly one optional feature — `Html.lazy` — so parking `lazy` parked the
question. Under W26 it is needed by **the rendering strategy itself**: `inst.row !== row` is the
entire per-hole check, it is what makes an unchanged row cost one pointer compare and zero
allocations, and without it the template strategy is unsound rather than slow. **It is now
load-bearing for every screen, and it constrains the optimiser forever** — `Opt.zig`, reachability
elimination, and any future unboxing or record-flattening pass may not break it.

**The example.** `{ model | selected = 3 }` returns a new model in which `newModel.rows` is the same
object as `model.rows`, and every row inside it is the same object. The renderer compares 1 000
pointers, finds none changed, and writes two `class` attributes. If any pass were free to rebuild an
untouched row, that comparison would be wrong — silently, and only on some builds.

**The options.** (a) write the guarantee into `language.md` §6: *an update preserves the identity of
every field it does not name, and no optimiser pass may break it*; (b) leave it unwritten and depend
on it anyway; (c) leave it unwritten and do not depend on it — which means a virtual DOM without
`lazy`, and nothing faster.

**What each costs.** (a) costs a sentence that constrains future passes — and the passes it
constrains are ones nobody wants, because a pass that *re-materialised* an unchanged field would be
adding an allocation (R29 §13 F4). It is a much smaller commitment than the one old W4 worried about:
W4's was about licensing `lazy` to **skip a call**, which needs purity as well; this one only says a
record update does not deep-copy. (b) is how a guarantee gets broken by an optimiser three years
later with no test that fails. (c) costs the whole of W26.

**Recommendation: (a), and it is the cheapest of the three by a wide margin.** It also needs
corpus fixtures that pin it under `--release`, because `--release` is where an optimiser would break
it (see [`plans/browser-platform.md`](browser-platform.md) §3, slice **L3**).

**And `lazy`: it stays parked, and under W26(b)/(c) it is subsumed.** R29 §6.3 measures `lazy` as the
single largest improvement any change in the report produced — geometric mean of script 2.336 →
1.323 — **and that is an argument against the virtual DOM, not for `lazy`.** `lazy` matters *because*
a virtual DOM rebuilds everything. Under a compiled template the template is already built, the holes
are already located, and the per-hole reference check *is* the memoisation. So: if W26 is (b) or (c),
state in writing that `lazy` is subsumed and close C9; if W26 were (a), `lazy` is mandatory and drags
a second argument-position demand with it (`plans/effects-plan.md` §2.5's one-bool budget becomes
two). **They are not independent questions and must be answered together.**

**Rule 7 check.** (a) refuses nothing and promises something. It is the honest form: a property
everything already depends on, written down where a reader and a future optimiser can both see it.

**Reversibility: low once written**, which is the point of writing it.

---

### W28. The render loop under templates: how many phases, and what triggers a synchronous render?

*(Old W5, re-issued. It was withdrawn because it was stated in virtual-DOM terms; the answer does not
change, and R27 supplies one new counter-argument that has to be met.)*

**The situation.** Three separate things are usually confused, and Elm confuses two of them in one
bit. The browser forces all three.

1. **One render per frame.** R24 §6.9 measured five messages delivered in one JavaScript loop
   producing exactly **one** DOM update, on the next frame.
2. **Except where the DOM holds its own state.** Elm renders synchronously when the handler used
   `stopPropagation`, because `<input type="text">` holds its own state and a fast typist outruns the
   frame. R24 §6.6 found the comment `// stopPropagation implies isSync` and calls it two unrelated
   concerns sharing one bit.
3. **Some effects must run after a render.** `Browser.Dom.focus` and every viewport read wrap
   themselves in a `requestAnimationFrame` so the node the program just described exists (R24 §8.2) —
   unconditionally, so every DOM read costs a frame. R25 D8 adds Lustre's evidence for three phases
   and the rule that **a library cannot add a phase the kernel does not have**.

**The new counter-argument, and why it does not land.** Solid 2 does **not** render once per frame:
it renders once per microtask flush, so several times per frame is possible (R27 §3.6). Does that
make frame batching wrong? No, and R27 says why itself: Solid's DOM writes are *mutations*, which the
browser coalesces within a frame anyway, so frame batching saves duplicated **JavaScript**, which for
Solid is small because its graph already skips unaffected work. **For a renderer that re-runs the
view top-down, the duplicated work is the whole view pass — so frame batching is worth more to beni
than it is to Solid.** R27 §3.6 states this as an argument *for* the recommendation, not against it.

**Options.** (a) one phase — render on the frame, and hide the rAF inside each DOM capability as Elm
does; (b) two — the frame render plus an explicit after-render suspension point a command can await
(`Browser.afterRender ()`), with a separate explicit "render now"; (c) three, Lustre's.

**What each costs.** (a) costs a frame on every DOM read forever and makes the ordering invisible.
(b) costs one concept and is what a fiber runtime with a real suspension primitive is *for* — and it
can be cheaper than Elm, because `afterRender` can return immediately when no render is pending.
(c) is one more phase than any evidence here demands.

**Recommendation: (b), with the three things named separately.** One render per frame; an explicit
`Browser.renderNow ()` (or a handler-level flag that is *not* `stopPropagation`) for the controlled
input case; one after-render suspension point. Unchanged from revision 1. Two constraints from R26
carry over: whatever runs after a render is `sync` (a rAF callback that suspended resumed 10.1 ms
later and its write landed in the *next* frame, §5.4), and the patch pass must batch reads before
writes (interleaving over 3 000 nodes cost **2 846 ms against 2.5 ms**, §5.5).

**Rule 7 check.** Nothing is refused: `renderNow` is an escape hatch and `afterRender` is a capability.

**Reversibility: low.** A phase the kernel does not have cannot be added by a library.

---

### W29. What is an `Html msg` value at run time, and where must the compiler fall back to building a tree?

*(New. This is the one technical question the whole design leaves open, and it is where two reports
each solve half of a problem and neither addresses the seam.)*

**The situation, stated sharply.** In the source, `view : Model -> Html Msg` is a function returning a
value of a type. R28 §8.1 recommends that JSX desugar in `bir/Lower.zig` to exactly the calls the
plain form produces — `Html.div [ Html.class "x" ] [ kid ]` — so that `Html msg` is an ordinary value
of an ordinary type, every existing pass works unchanged, and an `emit/` golden can prove JSX and
`Html.div [] []` emit identical bytes (R28 rule 19). The template optimisation is then a **separate
pass that recognises the call shape structurally**, which is what makes the plain-call form fast too.

R29's prototypes do something else entirely. `p2-tpl` clones a `<template>`, walks to the holes by
the paths the compiler computed, and keeps a per-row *instance record* `{el, row, sel, idT, lbT}`.
**There is no `Html` value anywhere at run time.** The "view" has been compiled into a mount function
and an update function over a template instance.

Those two pictures reconcile only when the recogniser can see the whole path from a root template to
every hole. It can when `view` is one literal expression. **It cannot, in general, when any of these
ordinary things happens — and every one of them is in R28's own worked example (§11.2):**

```elm
{viewStatus model}                                   -- a helper's result lands in a hole
{Html.keyed (List.map hits (\h -> ( h.id, viewHit model h )))}   -- Html values flow through List.map
let banner = <p class="hint">"…"</p> in …            -- an Html value in a let
<Card>{children}</Card>                              -- an Html value as a record field
```

Add: an `Html msg` returned from a `case` branch, stored in a list, crossing a module boundary into a
library the build cannot inline, or produced by a **recursive** view (a tree widget), which cannot be
inlined at all. So *something* must exist at run time for an `Html msg` that escapes its template.

**The options.** (a) **Inline everything** — the recogniser inlines across view helpers and list
comprehensions until the screen is one template family. Whole-program, and unbounded: recursion
defeats it outright, and `Opt.zig`'s inlining licence is deliberately narrow because widening it
broke four `run/` programs (`backend.md` §9, queue row 24). (b) **Two representations, with
`Html msg` a real value at the seam** — a mounted template instance plus an update closure is one
constructor of the runtime `Html` type, and a hole that receives one splices it. This is roughly
Leptos's shape, and R28 §9.2 warns it is exactly what cost Leptos and Dioxus their monomorphisation
scar tissue (`erase_components`, a 128-tuple cap, `split_oversized_templates`). (c) **A real tree as
the fallback** — where the recogniser cannot prove the shape, emit node construction and a diff for
that subtree only: a small virtual DOM retained as the fallback, never as the architecture.

**What each costs, honestly: nobody knows, and that is the point.** R29 measured the fallback only in
its extreme form — a *whole-app* virtual DOM — at 146× a template per message and 5.64 ms against
1.71 on `select`. What is unmeasured is a **mixed** program: a compiled template with one hole whose
subtree is a diffed tree. Three quantities are missing. (i) What the seam costs per message — is it a
node allocation per hole per frame, or nothing? (ii) Whether the fallback subtree's cost is
proportional to *its own* size (fine) or to the whole screen (not fine). (iii) **What fraction of an
idiomatic beni view falls back at all** — because if `{viewStatus model}` falls back, almost
everything does, and W26's numbers describe a program nobody writes.

**Recommendation: do not answer this from a document. Answer it with a named prototype, before
`backend.md`'s new §11 is written.** The experiment is **X1** in
[`plans/browser-platform.md`](browser-platform.md) §3 and §5: take R29's `p2-tpl` harness and R28
§11.2's typeahead, write the view three ways — everything inline (best case), helpers returning
`Html msg` into holes (idiomatic), and one hole whose subtree the recogniser is told it may not see
through (worst case) — hand-emit the three shapes (full template; template with a mounted-instance
seam; template with a diffed subtree), and measure per-message script on R29's static-heavy E1 page
and on the 1 000-row table. **Deliverable: the fraction of a realistic view that falls back under
each option, and the per-message cost of the seam.** It needs no compiler change, no platform, no
answered W, and it is about the size of one of R29's existing prototype pages.

**A provisional recommendation, to be confirmed or overturned by X1: (c) with (b) where it is
free.** (c) is the only option that is *sound by construction* — there is always something to emit —
and R29 §13 F1's rule-7 check already names it. (b) is worth taking wherever a helper's result is
consumed by exactly one hole shape, which is the common case. (a) should be bounded and opportunistic,
never relied on.

**Rule 7 check.** The failure mode to refuse is a *silent* cliff: a view that is fast until someone
extracts a helper, with nothing telling them. Two mitigations belong in the answer whichever option
wins — a `dump` stage or a `--release` report that says which holes fell back, and a documented rule
for what keeps a subtree in the fast path. Refusing the extraction itself would be a restriction with
no guarantee behind it, and is not on the table.

**Reversibility: low.** It decides the representation of `Html msg`, which is in `backend.md` §11,
in the platform's markup interface, and in the cost model every application is written against.

---

### W30. Are JSX text children quoted, or bare? *(= R28 J1)*

**The situation.** In HTML and React you write `<p>Hello</p>`. The question is whether beni does, or
whether text must be a string literal.

```elm
<p>Hello, ${name}!</p>          -- bare     [proposed]
<p>"Hello, ${name}!"</p>        -- quoted   [proposed]
```

**What bare text costs, concretely.** beni tokenises the whole file before the parser runs
(`src/lex/Tokenizer.zig:119-127`), so the lexer would have to decide for itself when it is inside a
tag — which is the parser's knowledge. Consequences: a mini-parser inside the tokenizer whose state
must survive M4-2's cached token stream; `--` inside text becomes a comment and eats the rest of the
line; a tab inside text is `tab_in_source`; and Babel's whitespace-collapsing algorithm — which the
JSX specification does not contain, and which is therefore folklore — has to go into `language.md`
and bind `beni fmt` forever (R28 §2.3, §4.2).

**What quoted text buys.** **Zero lexer change.** `${…}` interpolation inside the text, so
`<p>"Hello, ${name}!"</p>` is *one* text node instead of three children. Escapes and `\u{…}`. The
`\\` raw form for a block of prose. And the one that matters most: **the formatter provably cannot
change what the page says**, because `language.md` §9 already forbids it to touch bytes inside a
literal. Mint proves it by example — its formatter re-splits a long text child mid-word and the
output is byte-identical (R28 §0 finding 5).

**Options.** (a) bare, JSX's rules; (b) quoted; (c) no text children at all — every child is `{expr}`.

**Everyone else.** Mint, ReScript, Dioxus, Yew, Sycamore and Imba all require quoted text. Leptos
allows bare and its own book calls it lossy — *"can occasionally cause spacing issues around
punctuation, and does not support all Unicode strings"*. Marko allows it and had to invent a `--`
fence (R28 §4.3).

**Recommendation: (b), quoted.** It is the difference between a parser feature and a lexer rewrite.

**Rule 7 check.** (b) refuses a spelling, not a capability: every page you can write with bare text
you can write with quoted text, one keystroke apart, and it buys a formatter that cannot change your
page. (a) would additionally *lose* capabilities — `--` and tabs become hazards inside text.

**Reversibility: low.** It is grammar, and it is in everybody's source.

---

### W31. Is a tag name an ordinary name, or does a Capital mean "component"? *(= R28 J2)*

**The situation.** Everywhere else, `<Card/>` with a capital means "component, not HTML element",
because a local `div` might shadow the intrinsic one. In beni a capital already means constructor,
module or type (`language.md` §6.2) — and **beni forbids shadowing** (§7), so if `Html.div` is in
scope a local `div` is `shadows_import` and cannot exist. **`<div>` therefore has exactly one meaning
in a file, always, and the problem every other language solves with a convention is not there**
(R28 §6.2).

**The options.** (a) **A tag name is an ordinary name.** `<div/>` is `Html.div`; a component is
`<userCard title="x"/>`; a qualified one is `<Ui.card/>`. Capitalisation carries no meaning in a tag.
(b) **A capitalised tag names a MODULE and the component is its `view`** — `<Card title="x"/>` means
`Card.view { title = "x" }`, which is ReScript's (`<Foo.Bar/>` → `Foo.Bar.make`). (c) A capitalised
tag names a value in a new component namespace.

**What each costs.** (a) adds **no rule to the language**: a tag name resolves exactly as a name in an
expression resolves. Its cost is that `<userCard/>` does not look like `<UserCard/>`. (b) costs one
component per module and a convention to learn, and gives a module a home for its props type and its
`defaults`. (c) is the most familiar and the only option that adds a third meaning for a capitalised
name in expression position.

**Recommendation: (a), with (b) available later as sugar if the familiar look is missed.** It is the
only option that adds nothing to a language that has spent a year keeping its rules few. And it
matches where Solid went from the other direction: `<Dynamic component={…}>` became `dynamic(…)`, a
factory returning a stable value, so a dynamic tag is an ordinary identifier in tag position.
**The cost is purely a matter of taste, which is exactly why it is the owner's and not the
manager's.**

**Reversibility: medium.** (a) → (b) is additive sugar; (b) → (a) is not, because `<Card/>` would
change meaning.

---

### W32. Does JSX ship before the template optimisation, or with it? *(= R28 J5)*

**The situation.** JSX can land as pure sugar — the same calls a hand-written `Html.div [] []`
produces, about a week's work — or it can wait for the compiled-template lowering that makes it fast.

**Why it is the owner's.** The direction was two things at once: built-in JSX, *and* "the runtime
cannot be a limitation". R28 §8.1 is the honest finding that **they are independent**. The template
optimisation can be a pass that recognises the ordinary call shape — which is literally what Leptos's
default strategy is — and it then speeds up `Html.div [] []` too. So shipping JSX first costs nothing
and delays nothing.

**Options.** (a) sugar first, the optimisation second; (b) both together; (c) the optimisation first
and JSX later.

**What each costs.** (a) puts the surface in front of real views before the optimisation's shape is
fixed, and it cannot regress anything, because an `emit/` golden proves JSX and the plain form emit
identical bytes. (b) couples two things that W29 says are not yet both designed. (c) delays the
feature the owner asked for, for no measured gain.

**Recommendation: (a), sugar first.** Two conditions come with it, and they are not optional. It must
land **with** the `emit/` golden proving JSX and `Html.div [] []` are the same bytes — that is what
makes "two ways to write the same thing" a spelling rather than a second language (R28 §10 objection
4). And it must land **with a render-to-string platform**, because `tests/corpus/run/` executes
emitted JavaScript under Node where there is no DOM, and without one, rule 3 cannot be satisfied at
all (R28 §8.3; W38).

**Rule 7 check.** Nothing refused.

**Reversibility: high** — it is an ordering, not a mechanism.

---

### W33. Are keyed lists a type, and is an unkeyed dynamic list a warning?

**The situation.** `{List.map rows viewRow}` type-checks as a `List (Html msg)` hole and works. It is
also where a UI silently does the wrong thing: an unkeyed list that reorders re-uses the wrong DOM
nodes, losing focus, input state and scroll position. Solid 2 collapsed `For` and `Index` into one
`keyed` axis and its stated lesson is the sharp one — **what is keyed fully determines what is
reactive** (R28 §4.6, R27 §7.1). Leptos makes `key` non-optional; Yew makes it optional per node and
silently degrades when keyed and unkeyed children mix.

**The example.** Three ways to spell a key in beni `[proposed]`:

```elm
-- 1. a `key` attribute on the element inside the loop (React's, Elm's Html.Keyed)
-- 2. a keyed hole form, {for r in rows key r.id}…{/for}  — a second grammar inside the grammar
-- 3. a keyed list function whose TYPE says so:
Html.keyed : List (k, Html msg) -> Keyed msg where k.compare : k, k -> Order
{Html.keyed (List.map hits (\h -> ( h.id, viewHit model h )))}
```

**What each costs.** 1 puts the key on the *child*, so the list hole cannot see it without looking
inside a lambda the compiler did not inline. 2 needs a `for` production beni does not have. 3 needs
**no grammar at all**: the hole's type is `Keyed msg`, a *different type* from `List (Html msg)`, so
the compiler picks the keyed reconciler **by the type rather than by a convention it has to trust**,
and `where k.compare` is the mechanism R25 §3.1 already uses for command keys.

**Can the compiler require a key?** Not soundly — "this list is dynamic" is not decidable, and a
`List (Html msg)` hole may be a constant.

**Recommendation: option 3, plus a warning.** `Html.keyed` for the type, `Html.unkeyed` as the
explicit escape, and a **default-on warning for the root package** on an unkeyed list hole — *"if its
elements can be reordered, inserted or removed, state below them will attach to the wrong row"* —
exactly the shape `ambiguous_method_receiver` already has (`static-dispatch-spike.md` §10.9). Option
1 can be added later as sugar that lowers to option 3 when the lambda is syntactically present, which
is the only case it can be read anyway.

**Rule 7 check.** This is the model of a rule done right: a real hazard, no proof available, so warn
rather than refuse, and give the escape hatch a name so that suppressing it is a statement rather
than a silence.

**Reversibility: medium.** The type is in the platform's API; the warning is a flag.

---

### W34. How are `preventDefault`/`stopPropagation` and an event's payload spelled? *(= R28 J3)*

**What is already settled, and is not being re-asked.** A handler must be `sync` (**W8**), because
R26 §5.1 measured a link navigating anyway when `preventDefault()` was called one macrotask late,
while `event.defaultPrevented` still read `true` — an undetectable wrong answer. And the handler's
*variant* (`Normal`, `MayStopPropagation`, `MayPreventDefault`, `Custom`) must be **data** beside the
closure, because it decides the listener's `passive` flag (R24 §6.6).

**What is open** is the spelling:

```elm
<a href="/x" onClickPrevent={Navigate url}>          -- (a) four named attributes per event
<a href="/x" on:click|prevent={Navigate url}>        -- (b) one attribute, a modifier
```

**What each costs.** (a) is four ordinary values in the platform's namespace and needs **no grammar**.
(b) reads better — it is Vue's and Imba's — and costs a modifier production **plus** the
namespaced-attribute machinery Solid 2.0 just removed wholesale (*"No `attr:` / `bool:` / `on:` /
`oncapture:` namespaces"*, R28 §5.2, §0 finding 10).

**Recommendation: (a).** It can be extended to (b) later without breaking anything.

**A sub-question to answer at the same time: does `onInput` hand the handler a `String` or an
`Event`?** Elm's answer is a `Decoder msg` that **silently drops the event when the decode fails** —
*"No message, no log"* (R24 §6.6) — which is rule 7's silent-wrong-answer class and must not be
copied. **Recommend: typed per event**, so `onInput` hands a `String` because the platform declared
it that way, with the raw `Event` reachable for anything the platform did not anticipate.

**Rule 7 check.** Refusing a suspending handler (W8) buys `preventDefault`, `stopPropagation` and a
renderer that cannot be caught mid-frame; a handler that wants slow work spawns a fiber and returns.
Refusing Elm's silent decode drop removes a silent wrong answer and withholds nothing.

**Reversibility: medium.** The attribute names are in the platform's namespace; the payload typing is
in every handler's type.

---

### W35. Does `core/` get an indexable sequence? *(= R29 F3)*

**The situation.** `core/List` is a cons list and it is the only sequence beni has. There is no
indexed read, no indexed write, no `Array`, no persistent vector. `List.length` is a fold. `Dict` is
a balanced tree, so it gives O(log n) lookup and no order — which a table needs.

**The example.** "Swap rows 1 and 998" in a 1 000-row table. There is no way to write it in beni
except to walk to element 1, walk to element 998, and rebuild the whole list with `indexedMap`, which
is exactly what the compiler faithfully emitted from idiomatic source (R29 §2.1, Appendix A):

```elm
Swap ->
    if List.length model.rows < 999 then model
    else
        let a = at model.rows 1
            b = at model.rows 998
        in { model | rows = model.rows |> List.indexedMap (\i r -> if i == 1 then b else if i == 998 then a else r) }
```

Measured against the same `update` written for an indexable sequence: **81× at 1 000 rows, 64× at
10 000** (R29 §10.3). `List.length` is 20.8 µs at 10 000 rows and is called by ordinary guards. A
renderer over a `List` must materialise an array to reconcile, 3.6–32.5 µs per render. And a cons
cell costs 24 bytes of retained heap per row over an array (R29 §9.1).

**The options.** (a) ship a persistent indexable sequence as `core/Array`, with `get`, `set`, `push`,
`slice` and a `List` interconversion; (b) say cons lists are enough and write down why; (c) add
indexed operations to `List` that are O(n) and document the cost.

**What each costs.** (a) is several hundred lines inside the wall and a second sequence type to teach.
(b) leaves a beni program unable to name element *i* of a sequence in better than O(i) — every table
view, every virtualised list, every "move this row up", every drag-and-drop reorder. (c) is (b) with
a friendlier spelling of the same complexity.

**Recommendation: (a), and the ground is rule 7 rather than this benchmark.** §10 measures the `List`
version of `update` as a fraction of a millisecond at UI sizes, so **speed is not the argument**.
The argument is that **an ordinary developer cannot write `Array` themselves**: rule 6 means only
`core/` and platforms may write `foreign`, and CLAUDE.md rule 7 says in as many words that *"whatever
`core/` and the platforms do not ship, the language is withholding"*. `backend.md` §4 has parked a
vector trie *"pending M3c's benchmark of a vector trie"* since M3 began, and R29 §10 is that
benchmark.

**And a caveat that is part of the answer.** R29 §10.4 measured its "array" column as a
**copy-on-write JavaScript array** — `slice`, index assignment, `concat`, `filter` — not a persistent
vector. A 32-way trie makes `Swap` O(log₃₂ n) instead of O(n), but each node copy is a 32-element
allocation, and for `Append`, `Remove` and a full walk a plain copy-on-write array beats both a trie
and a cons list for everything this benchmark does. **So (a)'s real question is *which* array, and
that is a second measurement nobody has taken.** It belongs before the module is written, not after:
it is experiment **X2** in [`plans/browser-platform.md`](browser-platform.md) §3, half a day.

**Rule 7 check.** This fills a capability gap inside the wall, which is exactly what rule 7 asks for.

**Reversibility: high.** Adding a module to `core/` is additive.

*Specified 2026-10-01*, after the owner's one-sequence amendment in the table above: the contract is
`backend.md` §4 *Lists are arrays* (with §7, §8 and §15.5's amendments), `language.md` §6.8,
`boundary.md` §4 *How a sibling sees a `List`* and `schema.md` §6 *Lists are arrays*; the migration,
its slices and the decisions still the owner's are [`list-arrays.md`](list-arrays.md).

---

### W2. What does a defect do to a page?

*(Unchanged from revision 1; nothing in R27–R29 touches it, and R27 §9.2 supplies independent
confirmation.)*

**The situation.** A1 decided that defects are fatal: the process dies loudly with a report and a
non-zero exit. **A page has no process to kill.** R26 §7.1 measured it in Chrome and Firefox: an
uncaught throw inside a `MessageChannel` task, a rAF callback, an event listener, a microtask or a
timer **kills nothing** — the next task runs, the next frame runs, the sibling listener still runs,
the DOM is still mutable. `window.onerror` sees it, and that is all. A stack overflow is a catchable
`RangeError`. Elm's own runtime fails worse: a throw leaves its scheduler's `working` flag set
forever, so the application is silently wedged (R24 §3.5). So "fatal" in a page is a thing the
platform must *implement*.

**Options.** (a) **stop the scheduler** — a `dead` flag every fiber resume, listener and rAF callback
tests, ~10 lines. (b) **(a) plus tear down the mount** — remove every listener and close the root
scope, so finalisers run and requests abort, ~30 lines. (c) **(b) plus a crash screen**.
(d) `console.error` only — Elm's effective behaviour. (e) an optional `onDefect : Report -> ()` hook.

**What each costs.** (a) is not optional: without it the *other* fibers keep running on state A1 says
cannot be trusted. (b) costs a constraint on the platform's API — it must own every
`addEventListener`, so teardown is one `AbortController.abort()` — which is worth adopting anyway.
(c) costs **size**: a crash-screen string table is what `Reach.zig` cannot see is live, against a
789-byte brotli floor. An error boundary per subtree is rejected on A1's own reasoning.

**Independent confirmation, new in revision 2.** Solid 2 does exactly (a): an effect-phase error
with no boundary calls `haltReactivity`, stopping all scheduling, *"because app state is undefined at
that point"*. It does **not** do (b) — and its own issue #3338 comment says why that is a problem:
*"a halt that only reaches `console.error` leaves a page that LOOKS alive with nothing an app or its
telemetry can act on"* (R27 §9.2). A shipped project reporting the exact failure mode (b) prevents.

**Recommendation: (a)+(b) always, (c) in development builds only, (e) as a later addition.** And a
sub-question either way: **what replaces the non-zero exit code**, because the harness needs
something to assert on — a platform-defined global the page sets (R26 §9.1).

**Rule 7 check.** Halting refuses to keep going and buys "no silent wrong answer"; (e) is the escape
hatch. This is *more* than a Node process gets, because finalisers run. **Reversibility: medium.**

---

### W3. The browser scheduler's default budget and primitive — and the microtask tier

*(Unchanged from revision 1. R27 §3.5 adds one refinement, recorded below.)*

**The situation.** A fiber runtime that never gives the browser its thread back freezes the page —
which is exactly what Elm's does (R24 §3.3: 372 ms, zero frames). Two choices: *how* it hands back
and *how often*. `transparent-effects-proposal.md` §7.5 says: microtasks for throughput, escape to a
macrotask every 64 resumptions. R26 measured that design and it is wrong in both halves.

**The measurements** (Chrome 153 headless unless a Firefox column is named): a fiber yielding through
**microtasks** every 64 ops had input-handler latency of **p50 371 ms, max 653 ms** — *worse* than
never yielding (p50 84, max 364) — against **p50 0 ms, max 1 ms** for `MessageChannel` at every budget
from 16 to 8 192 (R26 §3.2). Microtasks buy **no throughput** either once the slice is ≥0.12 ms
(§3.4). Input latency p90 ≈ the slice length from 2 ms up. A macrotask yield costs 2.6–4.4 µs in
Chrome, 2.1–2.3 µs in Firefox. `setImmediate` does not exist in either engine.

**Options.** For the rule: (a) an op count; (b) a pure time slice; (c) a hybrid — count `k` ops, then
read `Date.now()`. For the primitive: `MessageChannel`, `scheduler.postTask`, or `scheduler.yield()`.

**What each costs.** A pure time slice is unaffordable (33–50 ns of clock per 465 ns op is 7 %) and
unenforceable below the clock's resolution (1 ms in Firefox). `scheduler.yield` and `postTask` at
`user-blocking` **starve the page's own timers** by design. `setTimeout(0)` is clamped to 4 ms.

**Recommendation: the hybrid, `k = 256` ops between clock reads, a 1 ms slice, through
`MessageChannel`.** The number lives in A7's **scheduler slot**, so it is a platform constant.

**And the second half: the two-tier design is withdrawn, not tuned.** One tier: a macrotask every
slice. **R27 §3.5 is worth recording beside it**, because it looks like a counter-example and is not:
Solid 2 flushes on a microtask and does not starve the page, because its flush is a *single, bounded*
microtask that does all pending work and returns — `schedule()` refuses to queue a second until the
first has run. R26 measured a *loop*, where each microtask enqueues the next and the checkpoint never
empties. **A one-shot microtask flush is fine; a microtask yield tier in a scheduler is not.** The
honest caveat R27 adds: "bounded" means bounded by the application's graph, and Solid has no yield
point inside its drain at all.

**Reversibility: high** for the number, **low** for the withdrawal, which is a spec rewrite.

---

### W6. Subscriptions: declared from the model and diffed?

**Un-withdrawn, 2026-09-20.** `plans/queue.md` listed W6 among the questions the owner's direction
re-opened, on the assumption that it belonged to the W1 cluster. On examination it does not:
subscriptions are about a *listener's lifetime*, and nothing in R27, R28 or R29 touches listener
lifetime. R27's only adjacent finding is that Solid's owner tree disposes children before the
parent's own finalisers, which **independently confirms** a decision beni has already taken (A1 item
7) rather than changing anything here (R27 §2.2). **The text below stands as written in revision 1.**

**The situation.** A program that listens to the window's size, or a clock, has a *resource with a
lifetime*. Elm's answer is `subscriptions : Model -> Sub Msg`, recomputed after every message, with
the runtime diffing the new set against the live one. What it buys is precise: **there is no
`unsubscribe` in user code anywhere in Elm**, a subscription cannot leak because "still wanted" is
re-derived rather than remembered, and it cannot be duplicated because a set is a set (R24 §5.1). The
counter-evidence is Lustre, which shipped with no subscriptions at all and leaks by construction.

**Options.** (a) keep the declared-and-diffed set, with each live subscription a **scoped fiber**
whose finaliser removes the listener; (b) no `Sub` — a subscription is started by a command and
cancelled by key; (c) Lustre's answer, no lifetime at all.

**What each costs.** (a) costs recomputing a small description after every message — Elm pays it and
so does Iced. (b) costs the author writing the stop, which is precisely the property R24 §0.3 says is
the hard one to replace. (c) is a measured mistake.

**Recommendation: (a)**, composing both: the declared set makes "what am I listening to" a pure
function of the model and therefore testable, and the scoped fiber makes the leak *unrepresentable*.
One thing comes with it: **a subscription's identity is a value**, so the key must be `compare`-able
and derivable (R25 §9.4).

**Rule 7 check.** Not a refusal *provided* the platform also lets a command start a long-lived
listener in a scope. Ship both; bless the `Sub`. **Reversibility: medium.**

---

### W7. Are command keys namespaced, and by what?

*(Unchanged from revision 1.)*

**The situation.** `boundary.md` §5.4 specifies keyed cancellation with four policies and leaves one
thing open: *"whether keys are global with callers namespacing their own strings"*.

**Here is the bug that leaves in.** Two instances of the same reusable component — two search boxes
on one page — both return `Cmd.keyed SearchKey Restart …`. The parent wraps both with `Cmd.map`. They
share a bucket, and **each cancels the other's request**. Nothing in the type system notices. It is
exactly why TCA registers every cancellable under **every prefix** of a navigation path (R25 §5.5).

**Options.** (a) global keys, callers namespace their own strings; (b) `Cmd.map` pushes a path segment
onto the key path and `Cmd.cancelAll` cancels a prefix; (c) keys are `String` only.

**What each costs.** (b) costs one field on the opaque `Cmd` and is unavailable later without a
breaking change; it buys a second property free — a parent cancels an entire subtree of work with one
call. (a) ships the wrong answer at the second reusable component; (c) ships it immediately.

**Recommendation: (b)**, with the key a `compare`-able value and the documented idiom a program's own
`Key` ADT. One correction to `boundary.md` §5.4 while it is open: it says *"k equatable"*, and the
runtime's table is a `Dict`, which takes `compare`.

**Rule 7 check.** Nothing refused; a silent wrong answer removed. **Reversibility: low.**

---

### W8. How does JavaScript call back into beni, and what is `sync` attached to?

*(Unchanged from revision 1. R27 §8.6 makes it carry more weight than it did.)*

**The situation.** Every event in a browser arrives on the browser's own stack. So the browser
platform needs a `foreign` that **registers a callback and later calls it** — a direction
`boundary.md` §4 says nothing about; its four checks cannot see that a sibling holds a beni closure
and invokes it from a listener. R26 §5.1 measured why it matters: hop a handler through one macrotask
before `preventDefault()` and the link navigates anyway while `event.defaultPrevented` reads `true`.

**Options.** (a) the language marks a function `sync` and the checker rejects suspension inside it;
(b) the platform's registration primitives take a `sync` function type and nothing else can be
passed.

**Recommendation: (b), with (a) as the mechanism that makes (b) checkable** — A6 plus one rule in
`boundary.md` §4: **a `foreign` that receives a beni function the sibling may invoke must declare that
parameter `sync`**, checked the way check 4 is checked (count what is declared; do not parse the
JavaScript).

**What revision 2 adds.** R27 §8.6's argument that a signal library needs no fourth fiber slot
**depends entirely on this rule**: the four-step proof is (1) a tracked computation cannot suspend,
by the checker; (2) a fiber can only be descheduled at a suspension point; (3) so nothing can
interleave between install and restore; (4) so a plain module variable is correct. Step 1 is this
rule. So W8 is now load-bearing for W19 as well as for `preventDefault`.

**Rule 7 check.** Refusing a suspending handler buys `preventDefault`, `stopPropagation` and a
renderer that cannot be caught mid-frame. A handler that wants slow work spawns a fiber and returns.

**Reversibility: low.**

---

### W9. What is `main` in a page, and what replaces the exit code?

*(Unchanged from revision 1.)*

**The situation.** A8 settled `main : Program`, a body that must not suspend, reference-counted
keep-alive, and exit codes 0 / 1 / 130. **All three are Node notions.** A page never exits, has no
exit code, and keep-alive is meaningless. A browser corpus fixture needs *something* to assert on.

**Options.** (a) `Program` is the platform's opaque mount descriptor and keep-alive is meaningless;
(b) the page's "exit" is an unhandled fiber death, which goes to W2's teardown; (c) both, with a
platform-declared `runtime` per `boundary.md` §5.2.

**Recommendation: (c), and `main : Program` is unchanged.** The browser platform's `Program` is what
`Browser.element` returns; the platform's `run(main)` mounts it; keep-alive is stated as a Node-only
concept rather than silently dropped; and the **harness reads a platform-defined global** plus the
page's text and console stream, measured at 10 ms per fixture (R26 §9.1). The ~70 `run/` fixtures
that write `main : Program` are untouched.

**Rule 7 check.** Nothing refused. **Reversibility: low for `main`'s type**, high for the harness
convention.

---

## Withdrawn, in place

A withdrawn id is **not deleted and not reused**, because other documents cite it. Each is marked
here with the reason, and its argument — where it survives — is carried forward by the replacement
named beside it; revision 1 in `git log` is where the original wording lives.

| # | Status | Why |
|---|---|---|
| **W1** | **WITHDRAWN 2026-09-20 — superseded by W25 and W26.** | The architecture and command-shape halves survive intact and are re-issued as **W25**, now argued from measurement. The third rider — *"`view` returns a data tree the platform renders — a virtual DOM"* — was written before anybody measured, and R29 §5.4 and §11.1 measure a virtual DOM as the slowest sensible architecture on the operation that separates strategies and 146× a compiled template on an ordinary page. **W26** replaces it |
| **W4** | **WITHDRAWN 2026-09-20 — superseded by W27.** | W4 treated reference identity as the *price* of an optional feature (`lazy`) and recommended parking both. R29 §13 F4 shows identity is load-bearing for the rendering strategy itself, not for `lazy`, so the question is no longer "is the feature worth the guarantee" but "write the guarantee down". `lazy` is joined into the same decision because under compiled templates it has no job (R29 §13 F6) |
| **W5** | **WITHDRAWN 2026-09-20 — superseded by W28.** | Withdrawn only because it was phrased in virtual-DOM terms ("the render loop") and the owner's direction re-opened the renderer. **The answer does not change**, and W28 re-issues it with R27 §3.6's microtask-flush counter-argument met |
| **W6** | **UN-WITHDRAWN 2026-09-20.** | Flagged for withdrawal in `plans/queue.md` as part of the W1 cluster; on examination, nothing in R27, R28 or R29 touches a listener's lifetime. It stands as written |
| **W10** | **WITHDRAWN 2026-09-20 — superseded by W26 and W29.** | W10 asked *"how much of the virtual DOM is written in beni?"* Under W26 there is no diff to write, so the question as posed has no answer. What survives is the part about where a *tree* still exists at all, which is **W29** — and W29 is bigger than W10 was, because it decides the representation of `Html msg` |

---

## Tier 2 — answered by a measurement

Each names the measurement. Two have already been taken and are marked; the rest name the slice in
[`plans/browser-platform.md`](browser-platform.md) §3 that takes them.

| # | Question | Measurement | Recommendation |
|---|---|---|---|
| **W11** | **How much runtime may a browser program ship?** Elm's floor is 109 530 B raw / 22 723 brotli for a counter, of which **0.9 % is the user's code** and 75.9 % is hand-written kernel (R24 §11.1–§11.2). beni's floor today is 2 147 B raw / 833 brotli with no runtime | **B1** then **B2′** (the template renderer), with `bench/size.mjs`. R24 §11.4's 35–50 kB estimate **assumed a virtual DOM** and is now an estimate of the wrong thing | Measure first. What R29 §12.1 gives is the *difference* between strategies, not a platform figure: a template renderer is ~1.7 kB brotli of machinery and a signal graph ~22 kB, and whatever else the platform adds, it adds to both. Do **not** quote effects' ≤ 5 kB gzip budget as a browser budget |
| **W12** | **Does the scheduler use `isInputPending`?** 45× fewer yields at identical input latency, but uncapped it produced an 82 ms long task; Chrome-only (R26 §4.1–§4.3) | **B4**, re-taken with a real beni fiber | Yes, capped by the time slice, behind a capability check — an optimisation, never the rule |
| **W13** | **Does the single-file bundle move ahead of chunking?** | **Already measured** (R26 §8.2): one bundle reaches `main` in **358 ms on 4G against 1 059 ms** for 13 modules — 3.0×, from round-trip depth rather than bytes. R29 §12.2 sees the same shape on localhost: nine files cost 19.8 ms of resource time against 2.4 | Yes. The degenerate case needs none of `backend.md` §10's PENDING decisions |
| **W14** | **Is sibling JavaScript minified in a release build?** Siblings are **71.6 %** of `Dictionaries`' raw bytes and are never minified; bundling with minification takes it 6 380 → **3 269** brotli (R26 §8.3). R29 §12.1 measures the same gap on a nine-file prototype: 10 592 as served against 3 758 minified, **2.8×** | **Already measured.** What is not measured is the interaction with W2: minifying `core/`'s JavaScript makes a defect report point into text nobody can read | Open, and the owner's. A middle answer: minify in `--release` only, and have the defect report name the `foreign` rather than quote it. Note `boundary.md` §4's checks read the sibling's *source text*, so §4's accepted export forms constrain who may minify and when ([`plans/browser-platform.md`](browser-platform.md) §3, **O2**) |
| **W15** | **What does the corpus's browser kind use for time?** CDP virtual time ran five chained 10-second timers — 50 000 ms — in **0.9 ms** of real time (R26 §9.3) | **B0** | Both, virtual time by default |
| **W16** | **Is a `TestStore`-shaped driver part of the platform?** TCA's two end-of-test assertions are worth copying: *"the store received N unexpected actions"* and *"an effect returned for this action is still running"* | **B5** | Yes, in the platform. Without it the corpus cannot test cancellation |
| **W36** | **What is the budget for "working out what changed"?** *(= R27 S3, R29 F5.)* At 1 000 rows under 4× throttling the model-to-screen step costs 0.03 ms (P3), 0.27 (P3 without the selector) or 1.30 (P2), against a 16.7 ms frame and 3 ms of paint (R29 §5.6) | **R1**'s exit criterion | **Publish 1 ms at 60 Hz**, measured from "`update` returned" to "the DOM is consistent with the model", excluding layout and paint. Set it against R29 §7.4's **68 ns per row**, not against R27 §5.5's 0.93 ns per hole — the second is the floor of the technique, not what a renderer pays (disagreement 13) |
| **W37** | **Which well-known runtime names does a platform declare for template lowering?** R28 §8.2's mechanism: a platform declares a fixed list (`template`, `insert`, `setAttribute`, `addEventListener`, `keyed`, …), checked the way `boundary.md` §4's check 4 is checked — count what is declared, do not parse the JavaScript | **R1**, and it must be settled by **W29** first, because the list is a function of what the fallback looks like | Take the `static-dispatch-spike.md` §3.2 well-known-name mechanism rather than inventing a second one. A platform that declares none gets the plain-call lowering and a perfectly good program |
| **W38** | **Does a render-to-string platform ship before JSX?** Rule 3 says every defect gets a fixture and `tests/corpus/run/` executes the emitted JavaScript — and there is no DOM under Node (R28 §8.3) | **L1**'s exit criterion | **Yes, and it is not optional**: without it, views cannot be black-box tested at all. It is also what proves the markup interface is real rather than a browser API wearing a hat |
| **W39** | **Does beni advise against wide model records?** *(= R27 S6.)* `{ r \| f = x }` costs 29.9 ns at 17 fields and **222.6 ns at 18**, 986 ns at 64, because V8's fast object-clone path bails out; field-by-field copying is *worse* (R27 §5.6). A real TEA `Model` has 20–40 fields | A measurement nobody has taken: does a **nested** model's two small clones plus the extra hole indirection beat one wide clone in a real view? Fold it into **X1** | **Document a preference for nested sub-records**, with the measurement as the reason — which is also what the per-hole check wants, because a hole must compare the record it reads from, never the root model (R27 §5.6). Do **not** change the emitted representation; the identity promise (W27) forbids the alternatives anyway |
| **W42** | **When does the compiler learn which fields feed which hole?** *(= R29 F2.)* Worth `select` 1.71 → 0.49 ms; §7.4 splits it — the field diff is worth 1.03 ms of 1.27 and the selector recognition 0.24. On a page where each hole has a field to itself it is marginally *slower* than P2 (3.5 µs against 2.25, R29 §11.1) | **R3**, after **R1** ships and has numbers | **Second, not first.** P2 is already ahead of Solid 2 everywhere; `backend.md`'s new section can leave a place in the hole table for the dependency set from the start. **And retire the Svelte-5 unknown before building it** (disagreement 14) |

---

## Tier 3 — can wait, and what each waits for

| # | Question | Waits for | Note |
|---|---|---|---|
| **W17** | Where is `sync` written — on the annotation like `pub`, or on the definition? | the effects spike's grammar | Recommend the annotation: `sync` is part of the type |
| **W18** | May a `sync` function await a *microtask*? | the same | Recommend **no** — whether a call suspends only through a microtask is not something a caller can see (R26 Q5) |
| **W19** | **AMENDED 2026-09-20.** Can a signal / fine-grained-reactivity library exist — and should tracking survive a suspension? *(absorbs R27 S2 and R29 F8)* | nothing; it is answerable now | **The old answer was wrong and is withdrawn.** It said a signal library was *"out of reach until the slot lands"*, on R25 §7.3's reasoning. R27 §8.6 read Solid's actual mechanism and showed the objection dissolves: if tracked computations are `sync` (W8), no fiber can interleave between install and restore, so a plain module variable in the platform's JavaScript is correct and **no fourth slot against A7's three is needed**. What remains is two smaller questions. *(i) Should tracking survive a suspension, as Leptos's does?* Recommend **no** — the `sync`-source / suspending-fetcher split states in the type which reads are dependencies, and Solid rejected the transaction analogue deliberately (R27 §4.4, axiom A26). *(ii) Is a signal library shipped?* Recommend **no** — R29 measures signals at 1.6–1.8× compiled templates on script and 12× the bytes, and P4 shows the graph costs what the graph costs whatever programming model sits on it. **But rule 7 forbids forbidding it**: the guarantees it trades (R27 §9.1) are a choice, not a guarantee beni is protecting. **Unshipped, never forbidden, kernel not deliberately closed against it** — the same position as W20 |
| **W20** | Is a component / local-state library forbidden, unshipped, or shipped? | a second real application | Unshipped, and the kernel checked not to exclude it. Forbidding it is taste |
| **W21** | Is a time-travel debugger a goal? | W25, and a user asking | The debugger is a *consequence* of one model cell + a pure `update` + messages as data (R24 §10.3). W25 and W26 keep all three — R29 §0.4 confirms the rendering strategy is invisible to every one of them — so the option stays open at no cost |
| **W22** | Is hydration of server-rendered HTML a requirement? | a server-rendering story | Cheaper to design in than to add. **Revision 2 adds two facts.** Solid's hydration costs **1 439 brotli bytes, +28 %** over the CSR runtime, and its `isHydrating` check is an unconditional early return at **every attribute write site** — so a CSR-only app pays it forever (R27 §6.8). Whatever beni does, the two builds must be separable. And W38's render-to-string platform is half of a server story already |
| **W23** | Two beni programs on one page — one runtime or two? | chunking | Elm merges a global and crashes on collision (R24 §2.6) |
| **W24** | Child-owned state: parent-owned model, or a custom element with its own runtime? | a component story, W20 | Also record: a heterogeneous page is a `case` over a `Page` ADT, because a list of "things with an `update`" needs existential types beni does not have (R25 §9.8) |
| **W40** | Are stores, proxies and `reconcile` out of scope? *(= R27 S7)* | nothing | **Confirm in writing that they are**, with the evidence, so the question does not reopen every time someone reads a Solid benchmark. 6 426 of Solid's 24 312 lines are the store, and every line of `reconcile.ts` is identity preservation — *"how to get new immutable data into an old mutable identity graph without destroying the identities the subscriptions are attached to"*. beni's model **is** the new data and `{ m \| rows = … }` **is** the correspondence (R27 §5.6). Solid's own ruling agrees (§7.8) |
| **W41** | Does `beni fmt` rewrite `<div></div>` as `<div/>`? *(= R28 J4)* | W30, W31 | **Normalise.** beni's formatter is canonical in the gofmt sense, not a fidelity-preserving printer: it already sorts imports and removes a leading `\|` in a `type` declaration. Mint normalises; ReScript deliberately does not and calls it fidelity (R28 §7) |
| **W43** | Is the equality-keyed selector a compiler pattern, a platform function, or neither? *(= R29 F7)* | a real application | **Neither first**, then the compiler pattern if asked. Worth 0.24 ms on one operation (R29 §7.4). **(b) is the option to refuse**, and rule 7 is why: a platform `createSelector` is a performance annotation the programmer has to know to write, whose absence is silent, and whose presence says something the compiler can already see. Solid needs it because Solid has no model to diff |
| **W44** | What is `ref` under immutability? | B2′ | Deliberately left open by R28 §5.4, §15. Mint refuses `ref` outright and redirects to an `as` clause; Solid 2 folds both `ref` and directives into `ref={fn}`; beni's platform needs `Browser.Dom.getElement`-shaped, identifier-based access (R24 §8.2) |
| **W45** | Does beni want a recoverable error boundary, separate from the fatal-defect rule? *(= R27 S5)* | a real application | **Not yet.** Solid has both a permanent halt and `createErrorBoundary(fn, fallback)` with a `reset` (R27 §9.2). beni's exhaustive `case` already puts the "something went wrong" branch where it happens. If it ever ships it is for `Result`-shaped failures only, **never** catching a defect, which would contradict A1 |

---

## What the owner's existing decisions already settle

So that nothing is asked twice.

| Already decided | What it settles for the browser |
|---|---|
| **A6** — `sync` ships in the first cut | The whole of R26 §0.2's list has a mechanism, and R25 §4.3 supplies a second, stronger reason than the boundary one: it is a concurrency proof. **Revision 2 adds a third**: `sync` is what makes a signal library implementable with no fourth fiber slot (R27 §8.6), and it is what makes beni stronger than the gold standard here — Solid's `sync: true` is a *memo option* whose violation is undefined behaviour in production (R27 §4.9) |
| **A7** — services are records of functions and `where` clauses | Elm's `Navigation.Key` becomes an ordinary record whose fields *are* the operations, which is testable with a fake. Solid's context is the general locator made cheap — copy-on-provide, inherit-by-reference, O(1) read — and **it needs no fiber slot either**, only an owner tree, which a UI scope tree already is (R27 §2.3) |
| **A7** — three fixed per-fiber slots, one of them the **scheduler** | W3's browser default lives in the scheduler slot. And R27 §8.6 closes the question of whether a fourth is needed: it is not |
| **A1** — finalisers infallible, the interrupter waits, children first | Scoped subscriptions are leak-free by construction. **Independently confirmed**: Solid's owner tree disposes a child's whole subtree before running the parent's own cleanup list, arrived at separately and shipped for years (R27 §2.2). Worth citing in beni's own documentation as prior art |
| **A1** — `Exit a = Done a \| Cancelled`, interruption invisible | A stale response **cannot land**. Contrast Solid, which cannot abort a promise at all: measured, both stale flights ran to completion and only the commit was discarded (R27 §4.5) |
| **A5** — `impure` is used from the slice that infers it | `Opt.zig`'s single-use inlining, the one transform that would silently break dependency tracking, is already forbidden from doing so (R25 §7.2, R27 §8.6a). It also constrains the template recogniser: a hole whose expression is `impure` may not be skipped by a reference check |
| **A8** — `main : Program`, body `sync` | The browser keeps the type and the rule; only the exit/keep-alive half is undefined, which is W9 |
| **A13** — a swappable clock and scheduler | 250 ms of debounce costs no wall time, which makes the typeahead assertable with no browser |
| **`boundary.md` §3.1 / milestone B3** — ports, a generated codec, a decode error **as a value** | Interop is specified and already better than Elm, whose incoming-port decode failure is a `__Debug_crash` |
| **`boundary.md` §5.2** — the `program` and `runtime` manifest keys | The mechanism JSX needs for the element vocabulary and for the markup interface already exists (R28 §5.1, §8.2). Three independent systems learned the same rule: ReScript keeps `JsxDOM.domProps` in the runtime package, Leptos and Dioxus generate their element tables in the library, and **Solid 2 moved JSX types out of its core package and wrote down that binding them there had been a mistake** |
| **`boundary.md` §7.1** — one export per `foreign`, one graph node per `foreign` | Elm's kernel DCE is per *file*, which is why `Debug.js` ships 7 265 B into an `--optimize` build. Already beaten |
| **`--release` refuses `Debug`** | Interacts with W2(c): a crash-screen string table is what `Reach.zig` cannot see is live |
| **C9** — `lazy` is parked | **Now recommended for closure rather than for continued parking.** Under W26(b)/(c) `lazy` has no job: the template is already built, the holes are located, and the per-hole check *is* the memoisation (R29 §13 F6). See W27 |
| **C6** — `Cmd`-level cancellation before the browser ships | W25 and W7 are that work |
| **Rule 7** and the stance of 2026-09-19 | Applied to every recommendation that refuses anything. Four refusals survive it: `sync` on the five signatures (W25, W8), halting on a defect (W2), quoted text children (W30), and typed child holes (W26's closed hole set). **One thing it forbids forbidding**: signals as a library (W19) |

---

## What the browser pass changes in decisions already taken

Honestly, with what would have to be re-written where. **Nothing in this list has been edited** — the
manager folds the cross-references in after the owner answers. Rule 2: no section is renumbered
anywhere; every addition is a new section at the end of its document or a row in an existing table.

| Decision / document | What the pass does to it | Where it would be re-written |
|---|---|---|
| **A8** (`main`, exit codes, keep-alive) | Only a Node half exists | `plans/effects-decisions.md` A8; `plans/effects-spike.md` §0.3; `boundary.md` §5. W9 |
| **A1** ("defects are fatal") | *Fatal* has no browser mechanism; the platform must implement it | `plans/effects-decisions.md` A1 gains a browser paragraph; queue rows 52–54. W2 |
| **P2 §7.5** (two-tier scheduling) | **Withdrawn for the browser.** One tier | `transparent-effects-proposal.md` §7.5 rewritten. W3 |
| **P2 §6.6** ("what this does to The Elm Architecture") | Superseded by R25 and this sheet | `transparent-effects-proposal.md` §6.6 → a pointer; `boundary.md` §5.4 rewritten |
| **C9** (`lazy` parked) | **Closed rather than parked**, if W26 is (b)/(c) | `plans/effects-decisions.md` C9; `plans/m3d-plan.md`'s `lazy` rows. W27 |
| **`plans/effects-plan.md` §2.5's one-bit budget** | Stays **one** bit if W27 is answered as recommended, because the identity promise is a language guarantee rather than an argument-position demand. It would have become two only under W26(a) | `plans/effects-plan.md` §2.5. W27 |
| **`language.md`** | **Three additions.** (1) §0's table and §3's grammar gain `Element` as an `Atom`, with *"an element is an operand, never a bare argument"*. (2) A new subsection beside *Evaluation order* — the twenty rules of R28 §11.1, plus attribute and child evaluation order (left to right in source order, which is §6's existing application row). (3) **The identity promise in §6** — an update preserves the identity of every field it does not name. Plus §9 (element formatting) and §10's new codes, appended never inserted: `unclosed_element`, `mismatched_closing_tag`, `child_not_renderable`, `duplicate_attribute`, `element_as_argument`, `component_children_arity`, `void_element_with_children`, `unkeyed_list_hole` (a warning) | `language.md` §0, §3, §6, §9, §10. W27, W30–W34 |
| **`frontend.md`** | The parser's element production, the two recovery cases (`unclosed_element`, `mismatched_closing_tag`), keyword attribute names, the quoted-name rule — and the statement that **no lexer mode is added**, with R28 §3.1's reason. The formatter's element rules. `dump --stage=ast`'s new tags | `frontend.md` §1.2, §3.5, plus a **new §9** |
| **`checker.md`** | One row in §6.1's obligation table for the typed child hole — `renderable(var, region)` beside `equatable`, `interpolatable`, `tuple_index` and `try` — its discharge arm in §6.4, and `child_not_renderable`'s message shape in §8. **Interface hashes are unaffected**: JSX lowers to ordinary calls, so a module's interface is whatever its annotations say (R28 §9.3) | `checker.md` §6.1, §6.4, §8 |
| **`backend.md`** | A **new §11 — compiled templates**: the recogniser and its predicate, the template and hole representation, the hole kinds and their update code, the keyed list hole, **the fallback path (W29)**, the template-id derivation rule (module index + instruction index, **never a shared counter** — that is the one place an implementer can break rule 5), the path-overflow rule if a packed path is used, and the `--release` gate. Also: §9's ranked list gains no row, because template lowering is not a size pass; §10's degenerate single-file case moves ahead of chunking | `backend.md`, new **§11**; §10. W26, W29, W13 |
| **`boundary.md`** | **Two additions and one rule.** A **new §9 — the markup interface**: a platform may declare an element namespace (its `pub` values are the intrinsic elements and attribute constructors) and a fixed list of well-known runtime names for template lowering, checked the way §4's check 4 is checked; a platform that declares none gets the plain-call lowering. §5 gains the render-to-string platform as the second implementation, and `main`'s browser meaning. §4 gains the callback rule (W8) | `boundary.md` §4, §5, §5.3, §5.4, §7.1, §8, new **§9**. W8, W37, W38 |
| **`core/`** | **Gains an indexable sequence** — `core/Array`, with `get`, `set`, `push`, `slice` and `List` interconversion. Which representation is a second question (W35). `backend.md` §4's parked *"pending M3c's benchmark of a vector trie"* is discharged by R29 §10 and replaced by the new question | `backend.md` §4; `core/`; `checker.md` Appendix B's signature list. W35 |
| **`boundary.md` §7.1** — *"roughly 45 % of Elm's TodoMVC bundle is hand-written runtime"* | Measured: **71.9–75.9 %** for small programs, the user's code under 1 % | `boundary.md` §7.1 |
| **`plans/effects-spike.md` §1.3** — *"The Elm Architecture… out of scope"* | Reversed | `plans/effects-spike.md` §1.3 |
| **`plans/effects-spike.md` S5** — the kernel lands in `platforms/node/` | Platform-neutral, browser first | `plans/effects-spike.md` S5, §0.3 |
| **`fast-compiler.md` §13** | The build order gains the language and rendering tracks, most of which need nothing from effects | `fast-compiler.md` §13 |
| **`plans/queue.md`** | Row 54 becomes the defect screen; 52–53 gain a browser column; the browser-first section gains the L/R/X tracks | `plans/queue.md` |

---

## What is forced, rather than chosen

So the owner does not spend attention on things with no alternative (R28 §13, plus two from R29).

| Forced | By what |
|---|---|
| An element may not be a bare application argument | `f a <b` is a legal comparison today (`src/parse/Parse.zig:1468-1473`) |
| An element may start wherever an operand starts | `op_lt` is `unexpectedExpr` there in every program that could exist (`:1720`) — the position is free |
| No lexer mode, given quoted text children | `Tokenizer.tokenize` runs to `eof` before `Parse.parse` |
| `type` and `as` must be accepted as attribute names | they are keyword tokens, and `<input type=…>` is unavoidable |
| Spread needs a new token or a different spelling | `...` is two `INVALID CHARACTER` diagnostics today |
| The intrinsic element table cannot live in the compiler | rule 6, `boundary.md` §5.2, and three systems that learned it the hard way |
| A template id may not come from a shared counter | rule 5 (determinism) |
| Attribute order is source order, everywhere | rule 5, and `language.md` §6's evaluation-order table |
| Control flow inside markup is `if` and `case`, not components | they are already expressions (R28 §4.5). Solid needs `<Show>`/`<For>` because a Solid component runs once and JavaScript is eager; after eight years it is adding `.tsrx` syntax to reach where beni starts (R27 §8.5). **This was R27's S4 and it is not a question.** *Amended 2026-09-29: non-keyed conditionals are `if`/`case`, but keyed `<Show when={x} keyed>` is kept for the one capability `if` lacks — forcing a remount (owner, "Spec review answers").* |
| An ill-formed element must still produce a tree | `frontend.md` §3.5, and what all three mature Rust macro DSLs converged on |
| A signal library is not blocked by the kernel | R27 §8.6 — provided tracked computations are `sync`, which W8 requires anyway |

---

## What this sheet does **not** decide

Recorded so nobody reads silence as agreement.

- **W29 is open**, and it is the largest one: nothing here settles what an `Html msg` is at run time or
  what the fallback costs. Every number in W26 describes a program whose whole view is one template.
- **Why Svelte 5 abandoned compile-time invalidation for signals is unknown**, and it is the most
  valuable unretired question in the pass, because Svelte 3/4 shipped W42's rung 3 at scale for six
  years and then replaced it (R27 §0.5, §12.5 item 11). R28 and R29 did not chase it.
- **One engine.** Safari and Firefox are entirely unmeasured for rendering; R26's Firefox columns
  cover the scheduler only. No GPU compositing, no vsync, no real device, no mobile.
- **The prototypes are not a compiler.** R29 §14 says so: they bound what an emitter could reach
  rather than predict it, and they ship no element vocabulary, no XSS sanitisation (Elm's is ~60
  lines and R24 §6.3 says there is no cheaper way), no rAF batching and no runtime.
- **The compile-time cost of the field analysis is unmeasured**, because there is no implementation
  (R29 §14).
- **Which array shape `core/` should ship** — copy-on-write, a 32-way trie, or something else — is a
  measurement nobody has taken (R29 §10.4).
- **The nested-versus-wide model measurement** has not been taken either (W39).
- Every op-count figure in W3 rests on a 465 ns stand-in rather than a real beni fiber.
- **The parity figure in R29 §0.1 did not reproduce** and must not be quoted; the ordering did.

Each is ranked with the cheapest experiment that would retire it in
[`plans/browser-platform.md`](browser-platform.md) §5.

---

## Effects in a browser program — open, 2026-09-30

[Research 45](../docs/design/research/45-effects-in-a-browser-program.md) (**R45**) designs how a
page performs effects now that the fiber runtime has landed (`transparent-effects-proposal.md` §16):
`update` stays pure and `sync` and returns a work order whose bodies are direct-style beni run in
fibers of the program's root scope; subscriptions are keyed long-lived fibers diffed once per flush;
after-render work is a command with a `sync` body. It builds on W6–W9, W25 and W28 and reopens none
of them except W7, whose answer needs a value to push (W47). **All ten answered 2026-10-01: W46 (A), W47–W55 as recommended.**

| # | Question | Options | Recommendation | Reversibility |
|---|---|---|---|---|
| **W46** — **answered 2026-10-01: (A)**, the owner | How does `update` start work? | (A) return `( model, Cmd msg )`, a `Cmd` being inert data naming bodies `Send msg -> ()`, keys and policies; (B) `update` gets an `Fx msg` capability and spawns itself, becoming `impure`; (C) no `Cmd`: work is a keyed set derived from the model, like `subscriptions` | **(A)**, with (C)'s half served by subscriptions whose bodies are general fibers. A keeps `update`'s output data — tests assert keys by value, replay drops commands, a computed update can be discarded — for one tuple per message; C re-issues a one-shot whose key leaves and returns (R45 §2) | low |
| **W47** — **answered 2026-10-01: as recommended**, the owner | *Amends W7.* `Cmd.map` cannot push the tagger as the key segment — it is a new closure every `update`, so a `Restart` would never match. What is the segment? | (a) written: `Cmd.map : Cmd a, k, (a -> msg) -> Cmd msg`, no unkeyed `map`; (b) an unkeyed `map` beside it; (c) no namespacing | **(a)**, `()` for a singleton child; an unkeyed `map` would reintroduce W7's bug the day a second instance appears (R45 §3.3) | low |
| **W48** — **answered 2026-10-01: as recommended**, the owner | Subscription semantics | the key is the resource's whole identity; every declaration of a live key receives each event through its own, latest tagger (Elm's `Browser.Events`); the set is recomputed once per flush when the model changed; `Sub.listen : k, (Send a -> ()), (a -> msg) -> Sub msg` is public so any author can add a subscription | **As stated.** Rule 7: Elm let only effect modules add a subscription (R45 §3.4) | low |
| **W49** — **answered 2026-10-01: as recommended**, the owner | How does a program ask for after-render work and DOM capabilities? | (a) `Cmd.afterRender` with a `sync` body run in `backend.md` §15.11's phase (2); DOM capabilities `impure`, by id, returning `Result`; `Dom.rendered : () -> ()` suspending for fibers; (b) research 17 §4.7's `suspends` capabilities that wait for a frame; (c) a `Rendered` token required by every DOM read | **(a)**; (b) colours callers for a wait the runtime now supplies, (c) buys speed not correctness and escapes like a `Scope` (R45 §3.6) | medium |
| **W50** — **answered 2026-10-01: as recommended**, the owner | `Browser.flush` | `impure`, renders now; latched (does nothing extra) when called during a dispatch or a flush | **As stated** (R45 §3.6) | high |
| **W51** — **answered 2026-10-01: as recommended**, the owner | Does a program get an unmount capability? | now / only W2's defect teardown | **Not now**; the program's root scope is specified so unmount is cheap to add (R45 §3.5) | high |
| **W52** — **answered 2026-10-01: as recommended**, the owner | May a model hold a handle — a `Queue` outbox for a socket — as an `equatable foreign type`, if every operation on a closed one is a `Result`? | (a) yes, amending `boundary.md` §4.1's "never hold a reference across an effect boundary" for total handles; (b) no: URL-keyed registries inside each platform module (Elm 0.18's WebSocket) | **(a)**: typed, no registry, and no silent loss (R45 §4.3) | medium |
| **W53** — **answered 2026-10-01: as recommended**, the owner | The dispatch ordering contract | arrival order, exactly once, `update` synchronous at `send`; a send during a dispatch queued, never re-entrant; a send from a cancelled fiber or a stopped program dropped; written into `boundary.md` | **Yes** — research 30 §8.3 asks for it in writing (R45 §3.2) | medium |
| **W54** — **answered 2026-10-01: as recommended**, the owner | Should the platform demand that `update` and `view` be *pure*, not only `sync`? | a second demand kind / none / a warning | **No demand**; it would refuse `Debug.log` in `update` and buys only replay of a program that mutates a `Ref` there (R45 §3.8) | high |
| **W55** — **answered 2026-10-01: as recommended**, the owner | How do tests fake HTTP? | (a) service records only (A7 as decided); (b) a fourth per-fiber slot, a transport | **(a)** for now; revisit when W16's driver meets a real program (R45 §3.7) | high |

## The runtime in beni — 2026-10-02

| # | Decision |
|---|---|
| **R47-1** | **The DOM runtime is rewritten in beni now**, not after the compiler work (the owner, 2026-10-02: "the sooner we rewrite the core the better"). The compiler work research 47 lists (a runtime module the lowering calls, mutable locals, inlining single-use top-level functions, whole-program specialisation) is built alongside the port, not before it. |
| **R47-2** | **Mutable locals for platform code are `Js.Ref`** (the owner, 2026-10-02): a privileged cell (`Js.ref`, `Js.read`, `Js.write`) behind the `Js` wall, lowered to a plain `let` where it does not escape. No `let mut` syntax. |
| **R47-3** | **The rewrite is gradual, and every step is at least as good as the hand-written JavaScript it replaces** (the owner, 2026-10-02). A step moves one runtime piece to beni and lands only if, for that piece, the generated JavaScript is no larger (release brotli, measured on the empty page, the `bench/ui` app and a page that uses the piece), no slower (`bench/ui` per-operation medians against the hand-written build and Solid 1, same batch), and equivalent in shape (side-by-side listing in the step's report). A piece that cannot meet the bar stays hand-written until the compiler feature it needs lands; the step then builds that feature first. |

The steps, and what each measured: [`plans/runtime-in-beni.md`](runtime-in-beni.md).
| **R47-4** | **Platform packages may write `sync (A -> B)` in ordinary beni signatures**, not only in `foreign` ones (the owner, 2026-10-02), so a runtime piece moved from JavaScript to beni keeps its "must not suspend" guarantee (`Browser.program`'s `update`/`view`, event handlers, the effects host). User packages still cannot write `sync`. |
