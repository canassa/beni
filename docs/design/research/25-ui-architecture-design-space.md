# The design space for a browser UI architecture when an effectful call is just a call

**Commissioned by** the project owner, 2026-09-19 — *"Beni is primarily a browser language, and the
browser platform comes before Node"* (CLAUDE.md, *Details about the project*) — and by the question
that decision immediately raises. In Elm, `update : Msg, Model -> ( Model, Cmd Msg )` is pure and an
effect is inert data the runtime performs, reporting back with another `Msg`. Under
[`transparent-effects-proposal.md`](../transparent-effects-proposal.md) (**P2**) an effectful call is
just a call: `let user = getUser id` performs a request and binds a `Result HttpError User`. There is
no `Cmd`, no `Task`, no `Sub` in the language. **So what is a beni browser program?**

This is one of three browser reports. **`research/24`** is **Elm's browser
runtime as built** — the scheduler, effect managers, the virtual DOM, subscriptions, ports — and this
report cites it rather than duplicating it; where I needed one Elm mechanism to make an argument I
read the source myself and say so. **`research/26`** is **the browser as a host,
measured** — the event loop, the yield budget in Chrome, input latency, size budgets — and every
number this report would like to have is in its scope, not mine. This report is the **architecture**
question and nothing else.

**What this report replaces.** Exactly one page: P2 §6.6, *"What this does to The Elm Architecture,
and where the rest of it lives"*, which makes one claim (`update` stays pure, commands stay inert,
time travel is unaffected) and defers everything else to `boundary.md` §5.4. §5.4 was written
**before** the effects decisions of 2026-09-19 and sketches `Cmd.run`/`Cmd.keyed`/`Cmd.cancel` in
eleven lines. Everything below is downstream of those two places and of
[`plans/effects-decisions.md`](../../../plans/effects-decisions.md)'s answered block.

---

## 0. Findings

**The one-line answer.** A beni browser program should be **TEA with a `sync` pure `update` and
effects that are fibers carrying a `send`** — option C below, of which `boundary.md` §5.4's
`Cmd.run` is a special case — because that is the only option in the space where **the model cannot
race with itself**, and the thing that proves it cannot is a *compile-time check beni is already
committed to building*: `sync` on `update` (A6). Elm gets the same property by accident, because its
target cannot suspend a stack. beni will be able to suspend one, so the property has to be bought;
`sync` is what buys it, and that is the single most important sentence in this report.

**But the architecture should be a library, not the language.** Rule 7 says beni's job is to make
guarantees, not to enforce taste. Everything in §3–§8 — TEA, components, signals — is writable on
**one** small kernel (§10), and the kernel is where the guarantees live: `view` is `sync` and pure,
event handlers are `sync`, subscriptions are scoped so they cannot leak, the mount is a scope so
unmount interrupts everything below it, and one render loop owns the frame. The platform ships TEA
as *the blessed architecture* and forbids nothing. The layered claim holds for four of the five
options and **breaks in exactly one place**, which is worth knowing before it is promised: a
fine-grained-reactivity library (§7) needs a fiber-local "current observer", and A7 deliberately
bought only *three fixed* fiber slots (clock, scheduler, log context) and declined a general
`Context`. Signals are the one architecture the kernel as decided cannot host.

### The ranking, against beni's commitments

| # | Option | One line |
|---|---|---|
| **1** | **C — pure `sync` `update`, effects are fibers with a `send`** | The only option where two in-flight effects provably cannot both write the model; keyed scopes make "latest wins" a two-word change; every Elm guarantee survives; `Cmd.run` (option A) is one convenience constructor over it |
| **2** | **A — pure `update`, `Cmd` as thunk + tagger** | C restricted to one message per effect. Everything A can do C can do; the restriction buys no guarantee, so under rule 7 A is C's *sugar*, not a rival |
| **3** | **D — components with local state** | Structured concurrency *is* the component lifecycle, so beni gets `LaunchedEffect`/`DisposableEffect` for free and better; but it needs an invalidation path the kernel does not have, it loses the message log, and it re-opens the lost-update race option C closes |
| **4** | **E — signals / fine-grained reactivity** | Needs a language/runtime addition nobody has budgeted (a fiber-local observer), trades exhaustive-message and single-source-of-truth for a performance property beni has not measured a need for. Not forbidden; not first |
| **5** | **B — effectful `update`** | The option transparency makes tempting, and a silent-wrong-answer generator. Either the input box freezes for the length of an HTTP request (mailbox), or two updates race on a stale model (concurrent). Rejected, in writing, with the typeahead worked through in §4 |

### The ten findings, in order of value

1. **`sync` on `update` is not a boundary check; it is a concurrency proof.** A `sync` function
   contains no suspension point, and a suspension point is the *only* place another fiber can
   interleave (P2 §9.1, §6.2). So `sync update` means: every message is applied to the model
   atomically, there is exactly one writer, and lost updates are impossible — checked by the
   compiler, for free, as a side effect of a check A6 already decided to ship. This is the argument
   for options A and C and against B and D, and no document states it yet. §4.3, §9.3.

2. **Elm's own `Http` already does `boundary.md` §5.4's keyed cancellation, and only kernel code
   can.** `elm/http`'s effect manager holds `reqs : Dict String Process.Id` and `cancel : String ->
   Cmd msg` looks the tracker up and kills the process (`elm-http/src/Http.elm:669-671`, `:973-976`,
   `:998-1019`). That `Dict` is the thing a beni user writes in ordinary beni. **The architectural
   change transparency buys is not to `update` — it is that the effect interpreter stops being
   privileged.** §3.2, §8.7.

3. **Debounce-with-cancel becomes three ordinary lines, and every system surveyed pays for it
   somewhere else.** In beni: `Task.sleep`, then the request, inside a `Restart`-keyed command; the
   next keystroke interrupts the sleeping fiber. redux-saga spends a state machine on it
   (`saga/packages/core/src/internal/sagaHelpers/debounce.js:21-37`, literally `race(take, delay)`);
   TCA deprecated its own `.debounce` and its deprecation message tells you to write
   `clock.sleep` + `.cancellable(id:cancelInFlight:)` by hand
   (`tca/Sources/ComposableArchitecture/Internal/Deprecations.swift:371-378`); Lustre cannot do it at
   all. §3.4, §8.1, §8.5.

4. **Stale responses stop being a bug class, and nobody else in the survey has that.** beni cancels
   the fiber, so the response for a query the user has replaced *cannot land* — the continuation is
   gone. Solid discards by promise identity (`pr === p`,
   `solid/packages/solid/src/reactive/signal.ts:650`), Leptos by a version counter
   (`leptos/reactive_graph/src/computed/async_derived/arc_async_derived.rs:368-390`), Lustre by
   tagging the id into the message and ignoring it in `update`
   (`lustre/examples/03-effects/01-http-requests/src/app.gleam:89-100`), Elm by ignoring a `Msg`.
   **None of them aborts the work**: `grep AbortController` finds nothing in Solid's reactive core or
   Leptos's reactive graph. beni's prompt interruption (56 ms vs 301 ms, `research/16` §2.4, re-measured
   on v4 at 57 ms, `research/21` §0.2) is the differentiator and the browser is where it shows. §9.2.

5. **A keyed cancellation namespace is a composition problem, and TCA has already solved it.** Two
   instances of the same child component returning `Cmd.keyed SearchKey` collide. TCA registers each
   cancellable under **every prefix** of a `NavigationIDPath`
   (`tca/Sources/ComposableArchitecture/Effects/Cancellation.swift:251-260`), so a parent-scoped
   cancel reaches every descendant's effects and two siblings never share a bucket. `boundary.md`
   §5.4 lists "whether keys are global with callers namespacing their own strings" as open; the
   answer is that **`Cmd.map` must push a path segment**, and if it does not, §5.4 ships a
   silent-wrong-answer. §9.8, decision 5.

6. **`sync` is not enough for `view`: `view` must also be pure.** `Html.lazy`, and any render
   memoisation, is exactly `language.md` §6's licence to *drop* a call — which A5 has just decided
   `impure` revokes. A `view` that calls `Ref.get` and a `lazy` that skips it is a silent wrong
   answer of precisely rule 7's class. So the browser platform needs **two** bits in argument
   position on `view`, not the one P2 §3.2 and plan §2.5 budgeted. §9.1, decision 3.

7. **Structured concurrency is the component lifecycle, exactly.** Compose's `LaunchedEffectImpl`
   launches a job in `onRemembered` and cancels it in `onForgotten`, and a key change is
   forget-then-remember — cancel-and-relaunch (`Effects.kt:492-535`, fetched URL in §14).
   `DisposableEffect` is acquire/release over the same hook. Both are `Task.scope` + `bracket` with a
   framework's name on them, and beni's version is stronger because finalisers are infallible (A1)
   and the interrupter waits for cleanup. Option D gets this **for free**; what it does not get is a
   way to tell the renderer that something changed. §6.

8. **effect-atom is the existence proof that a signal graph over a fiber runtime cancels properly —
   and beni would get that for free where Solid and Leptos do not.** When an atom is invalidated the
   registry disposes the lifetime *before* rebuilding, and the finalizer is
   `fiber.interruptUnsafe()` (`references/effect/packages/effect/src/unstable/reactivity/Atom.ts:578-604`,
   `AtomRegistry.ts:741-758`, `:1012-1023`). The last subscriber leaving schedules the same teardown
   (`:792-812`, `:625-627`). That is `Cmd.keyed … Restart` at cell granularity, and it is the piece
   §7 would inherit. §8.2.

9. **Leptos shows how to make reactive tracking survive a suspension point, and beni is the only
   language in the survey that could do it in the scheduler.** Solid loses the dependency silently
   at the first `await`, because `runComputation` restores `Listener` in a `finally` that runs when
   the async function returns its promise (`solid/.../signal.ts:1402-1427`); there is no warning and
   no check. Leptos re-installs `Owner` and `Observer` **on every `poll()`** via `ScopedFuture`
   (`leptos/reactive_graph/src/computed/async_derived/mod.rs:72-87`). beni's runtime owns the resume
   callback (P2 §6.1), so it could re-install a fiber slot at every resumption — the same trick,
   done once in the scheduler instead of once per future. It needs a slot A7 declined to make
   general. §7.3, decision 6.

10. **A defect in a browser has no exit code, and no document says what happens.** A1 decided
    defects are fatal and the process dies with a non-zero exit; a page has neither. The options are
    halt-the-program, an error boundary, or continue — and A1's own reasoning ("JS fibers share a
    heap, so containing one means running on state nobody can vouch for") rules out the error
    boundary in a page exactly as it does in a process. §9.5, decision 2.

### The layered-answer verdict

**It holds, with one named break.** A kernel of five things — a root scope tied to the mount, a
`sync` pure render, a `sync` event→fiber bridge, scoped subscriptions over `bracket`, and one
frame-aware render loop — supports TEA (A, C), a component library (D) and a `Cmd`-less
imperative style, and the platform can ship TEA as the blessed architecture while forbidding none of
them. It **does not** support fine-grained reactivity (E) without one addition: a fiber-local the
runtime restores at every resumption. That is a real, small, costed language/runtime ask (§7.3), and
the honest thing is to say in the spec that E is out until it lands, rather than to claim the kernel
is architecture-neutral when it is architecture-neutral-except-for-one-family. §10.

### What surprised me

- **Lustre's subscriptions leak by construction and nobody seems to mind.** `effect.from(fn(dispatch)
  { window.add_event_listener(...) })` is the documented idiom
  (`lustre/src/lustre/effect.gleam:145-154`); the callback is invoked once, its return value
  discarded, and there is no unregister path in `Actions`. The one subsystem Lustre *did* give a
  subscribe/unsubscribe lifecycle is the context protocol (`:293-306`). A TEA framework on a typed
  functional language shipping without a `Sub` is a data point for "subscriptions are not intrinsic
  to TEA" and against "so you can skip them".
- **TCA's reducer is not `@MainActor`; only its caller is** (`tca/Sources/ComposableArchitecture/Reducer.swift:3`
  versus `Core.swift:9-10`). The serialisation everyone attributes to the reducer is a property of
  the store's isolation, not of the reducer's type. beni's `sync` puts it in the reducer's type,
  which is stronger.
- **TCA does not use Swift's task tree for effect lifetime.** Each action's effect is an
  *unstructured* `Task` bookkept by hand in `effectCancellables` and a global
  `LockIsolated(CancellablesCollection())` (`Core.swift:159`, `:194-196`; `Cancellation.swift:226`).
  The system closest to "TEA plus structured concurrency" opted out of the structure.
- **Solid's `createResource` never aborts anything** and its "cancellation" is three characters:
  `pr === p`. The most-cited fine-grained framework's async story is a discard, not a cancel.
- **`boundary.md` §5.4's four policies are RxJS's four `*Map`s and also TCA's, Compose's and
  redux-saga's one policy each.** `Restart` is `switchMap`, `takeLatest`, `cancelInFlight: true` and
  `LaunchedEffect(key)`. Four independent systems shipped exactly one of the four and it is the same
  one. §9.2.

---

## Method

**What was read, at which commit, in which clone.** Shallow clones under
`scratchpad/browser-r2/`, all cloned 2026-09-20:

| Clone | Commit | What was read |
|---|---|---|
| `tca` — pointfreeco/swift-composable-architecture | `377da4061db10d26337a71bb279c506bb951f50f` | `Effect.swift`, `Core.swift`, `Reducer.swift`, `Store.swift`, `Effects/Cancellation.swift`, `Reducer/Reducers/PresentationReducer.swift`, `Internal/NavigationID.swift`, `Internal/Deprecations.swift`, `TestStore.swift`, four `Examples/` features with their tests |
| `lustre` — lustre-labs/lustre | `e5ca4d8b647c2c13f2f42f51d500c2198a7a4d19` | `src/lustre/effect.gleam`, `src/lustre.gleam`, `src/lustre/component.gleam`, `src/lustre/runtime/client/runtime.ffi.mjs`, `src/lustre/runtime/transport.gleam`, `src/lustre/vdom/*`, `examples/03-effects/*` |
| `solid` — solidjs/solid | `b25c557754f2ced0d86490e6dbfded9b1745b663` | `packages/solid/src/reactive/signal.ts` (signals, computations, `createResource`, owner tree) |
| `leptos` — leptos-rs/leptos | `619637063c888ca958629074359759a4487ca6a0` | `reactive_graph/src/graph/subscriber.rs`, `traits.rs`, `effect/effect.rs`, `computed/async_derived/*`, `owner.rs`, `lib.rs`, `tachys/src/reactive_graph/suspense.rs` |
| `saga` — redux-saga/redux-saga | `b603028ae2d6f1f96f94fb4f016bde3fa32d6a2d` | `packages/core/src/internal/sagaHelpers/takeLatest.js`, `debounce.js` |
| `iced` — iced-rs/iced | `fa3bae52874274c012a27d4bf11a83c49e1709ae` | `futures/src/subscription/tracker.rs`, `runtime/src/task.rs` |
| `elm-http` — elm/http | `81b6fdc67d8e5fb25644fd79e6b0edbe2e14e474` | `src/Http.elm` — the effect manager and `cancel`/`track` |

In the repository: `references/effect` at `3d59ae6d5f9ff3e52cb6ed4a9f325320580218d5` — the `atom`
package, whose core has moved upstream into
`packages/effect/src/unstable/reactivity/{Atom,AtomRegistry,AsyncResult}.ts` with only the framework
bindings left under `packages/atom/` — and `references/elm-browser` at
`1d28cd625b3ce07be6dfad51660bea6de2c905f2` for `Browser.element`'s record type
(`src/Browser.elm:104-111`). Jetpack Compose was fetched as a single file rather than cloned:
`https://raw.githubusercontent.com/JetBrains/compose-multiplatform-core/jb-main/compose/runtime/runtime/src/commonMain/kotlin/androidx/compose/runtime/Effects.kt`
(fetched 2026-09-20; line numbers are into that file).

On the beni side, at `master` (`657aa7b`): `CLAUDE.md` whole, `language.md` §0 and §3–§6,
`transparent-effects-proposal.md` whole, `plans/effects-decisions.md` whole, `boundary.md` §4–§5,
`research/21` §0, `research/22` §0 and §8, `platforms/node/Node.beni`, and a sample of
`tests/corpus/run/` for the syntax every example below is written in.

**The beni code in this report.** Every fragment is valid `language.md` **today** except where it
uses (a) P2's effects semantics — a call performs, a thunk defers — (b) a P2 form that is proposed
and not landed (bare `let` items, §3.3; `and` groups, §3.4; the `sync` keyword, §3.2), or (c) an API
this report is itself proposing. Each is marked **[proposed]** at first use in its section. Nothing
below is written in a syntax `language.md` rejects: calls are saturated, types are n-ary, pipes are
pipe-first, `where` clauses sit on top-level annotations, and at most one `_` appears per
application — a rule that bites in §3.6 and is worth the paragraph it gets.

---

## 1. The question, stated precisely

### 1.1 What actually changes

Elm's four-function program is a shape, and only one of its four functions is affected by
transparency:

```elm
-- Browser.element, elm-browser/src/Browser.elm:104-111, in Elm's own syntax
element :
    { init : flags -> ( model, Cmd msg )
    , view : model -> Html msg
    , update : msg -> model -> ( model, Cmd msg )
    , subscriptions : model -> Sub msg
    }
    -> Program flags model msg
```

`view` and `subscriptions` are pure functions of the model and stay pure under any option in this
report. `init` and `update` are where the question lives, and the question is not "what type do they
have" but **"where does the program suspend, and what is allowed to change while it is suspended"**.

Elm answers that by construction: nothing in Elm can suspend, because `Cmd` is data and the runtime
interprets it. beni removes the construction — `getUser id` suspends — so the answer must be either
a *rule* (`update` may not suspend, checked) or a *semantics* (`update` may suspend, and here is
what happens to everyone else). Options A and C take the rule. Option B takes the semantics and
§4 shows what it costs. Options D and E dissolve the four-function shape and are judged on their own
terms.

### 1.2 beni's fixed points — the yardstick

Every option in §3–§8 is scored against these and nothing else. Nine of them are already decided;
they are not up for renegotiation by an architecture.

| # | Commitment | Source |
|---|---|---|
| F1 | **No runtime exception in well-typed code.** Errors are `Result` values; a `foreign` that throws is a *defect* and defects are **fatal** | rule 7; A1 |
| F2 | **Exhaustive matches.** A `case` over `Msg` must cover it; `missing_patterns` is an error | `language.md`; r22 §0 finding 3 |
| F3 | **Managed effects**, and `sync` **ships in the first cut** — a compile-time check that a function does not suspend, valid in argument position | A6; P2 §3.2 as corrected |
| F4 | **Guarantees, not restrictions.** A rule that buys no guarantee is a warning or is dropped; a capability gap is filled inside the wall | rule 7 |
| F5 | **Structured concurrency**: scopes, infallible finalisers, `Exit a = Done a \| Cancelled`, children interrupted before a parent's finalisers, the interrupter waits for cleanup, interruption invisible to the interrupted code | A1, A2, A3, A10, A11 |
| F6 | **Services are records of functions plus `where` clauses**, with exactly **three** fixed per-fiber slots: clock, scheduler, log context. No general `Context` | A7 |
| F7 | **`impure` is used from the first slice**: an `impure` call is never dropped, duplicated, reordered across another `impure` call, or memoised | A5; P2 §5 |
| F8 | **`main : Program` stays**, and its body must not suspend | A8 |
| F9 | **Deterministic time** — a swappable clock and scheduler from the first commit, because half of r23's catalogue is untestable without it | A13 |
| F10 | **The browser comes first**: size, scheduling and latency are judged in a page, and the runtime's budget is ≤ 5 kB gzip | CLAUDE.md; B9 |

Two non-commitments matter as much. **Time travel is not on the list** — it is Elm's property, not a
rule-7 guarantee, and §9.7 says which options keep it and at what price. **A virtual DOM is not
specified anywhere in `docs/design/`**: `boundary.md` §5.3 says only "Browser: The Elm Architecture.
`init`, `update`, `view`, `subscriptions`, ports." Whether `Html msg` is diffed, and whether
`Html.lazy` exists, is open, and §9.1 shows it is not a rendering detail but a *typing* decision.

### 1.3 What this report does not reopen

The lowering (CPS onto an owned fiber runtime), the primitive list, the failure value, the keyword
`foreign pure|impure|suspends`, the yield budget, and every tier-A answer of 2026-09-19. Where an
option would require changing one of those, that is recorded as the option's **cost**, not proposed
as a change.

---

## 2. The running example

One example is used by every option, so the options differ only where they actually differ.

### 2.1 The specification

A search page.

1. A text input. Typing sets the query and, **250 ms after the last keystroke**, issues a search.
2. A results list with **three visible states**: loading, loaded (possibly empty), failed.
3. **The stale request is cancelled** when the user types again; the response to a replaced query
   must never reach the model.
4. Each result has a **favourite toggle**, persisted by a second HTTP call, applied **optimistically**
   and **rolled back** if the call fails. Two different results may be toggling at once.
5. **One subscription**: the window's width, which the layout reads.

That list is chosen because it forces every hard question at once: concurrency, cancellation,
staleness, optimistic state, per-item concurrency (so a single global "in flight" flag is not
enough), subscriptions, and two distinct error paths.

### 2.2 The shared vocabulary

This module is identical for options A, B and C, and is the parts of D and E that survive. It is
valid `language.md` today.

```elm
--! `Typeahead.Core` — types and the one service. Nothing here is architecture.
import Set exposing (Set)


type alias HitId =
    String


type alias Hit =
    { id : HitId, title : String }


type HttpError
    = Timeout
    | NetworkError
    | BadStatus Int
    | BadBody String


--| The service record (A7: services are records of functions). `search` and
--| `setFavourite` both PERFORM — under P2 a call is a call — so both are
--| inferred `suspends`. A test passes a fake built from a `Ref`; the browser
--| platform's entry point passes the real one. Nothing about this record is
--| special: it is the whole of beni's dependency injection for this program.
type alias Api =
    { search : String -> Result HttpError (List Hit)
    , setFavourite : HitId, Bool -> Result HttpError ()
    }


type Status
    = Idle
    | Loading
    | Failed HttpError
    | Loaded (List Hit)


type alias Model =
    { query : String
    , status : Status
    , favourites : Set HitId
    , saving : Set HitId
    , lastError : Maybe HttpError
    , width : Int
    }


--| Two helpers every option below uses, so that no option's code is doing
--| work another option's is not.
setMember : Set HitId, HitId, Bool -> Set HitId
setMember set id want =
    if want then
        Set.insert set id

    else
        Set.remove set id


statusOf : Result HttpError (List Hit) -> Status
statusOf result =
    case result of
        Ok hits ->
            Loaded hits

        Err e ->
            Failed e
```

Note what is *not* in `Model`: the `Api` record and any fiber handle. A `Model` holding a function
has no derived `eq` (a function type is not equatable), which costs `Html.lazy`, costs a
time-travel diff, and costs the `==` a test wants to write. §9.8 returns to this; the practical
consequence appears in §3.6.

### 2.3 The six questions the example forces

| | Question | Where it bites |
|---|---|---|
| Q1 | May `update` suspend? | §4 answers no, at length |
| Q2 | Who cancels the previous search, and how is it named? | §3.4, §9.2 |
| Q3 | Can the favourite toggle for hit A and for hit B be in flight together, and can their responses interleave badly? | §9.3 |
| Q4 | Where does the optimistic write live, and what un-writes it? | §3.5 |
| Q5 | How is the resize listener removed when the program goes away? | §9.4 |
| Q6 | Can the whole sequence — type, type, respond, toggle, fail, roll back — be a deterministic test with no browser? | §9.6 |

---

## 3. Option A — TEA unchanged in shape, effects as data

**The shape.** `Cmd msg` is an ordinary library type over thunks, as `boundary.md` §5.4 sketches it.
`update` is pure and `sync`; a command is a deferred computation plus a function that turns its
result into a message.

### 3.1 The API [proposed — `boundary.md` §5.4 plus this report's additions]

```elm
--! `Browser.Cmd`. Ordinary beni: no language feature is used that a user
--! could not use. `Policy` is `boundary.md` §5.4's, unchanged.
pub type Policy
    = Restart
    | Ignore
    | Queue
    | Concurrent


pub opaque type Cmd msg

pub none  : Cmd msg
pub batch : List (Cmd msg) -> Cmd msg

--| Run the thunk on a fiber; tag its result and deliver it as a message.
pub run : (() -> a), sync (a -> msg) -> Cmd msg

--| The same, under a key, with a concurrency policy against anything already
--| running under that key. `Restart` interrupts the running fiber — its
--| finalisers run, the interrupter waits for them (A10), and the abandoned
--| primitive's resume is dropped on the floor (P2 §6.2).
pub keyed : k, Policy, (() -> a), sync (a -> msg) -> Cmd msg
    where k.compare : k, k -> Order

pub cancel : k -> Cmd msg
    where k.compare : k, k -> Order

pub map : Cmd a, sync (a -> b) -> Cmd b
```

`sync (a -> msg)` is the **[proposed]** spelling of P2 §3.2's bit in argument position; the tagger
runs inside the dispatcher, ahead of `update`, and must not suspend for the reason §4 gives.
`where k.compare` and not `k.eq`: the runtime's key→fiber table is a `Dict`, and `Dict` takes
`compare` (`static-dispatch-spike.md` §5.3). `boundary.md` §5.4 says "k equatable"; that is one
constraint short.

### 3.2 What is different from Elm, and it is not `update`

Structurally, option A is Elm. The difference is **who may write the interpreter**. `elm/http`'s
cancellation is an effect manager holding

```elm
type alias State msg = { reqs : Dict String Process.Id, subs : List (MySub msg) }
```

(`elm-http/src/Http.elm:973-976`), and `cancel tracker` looks the tracker up in that `Dict` and kills
the process (`:669-671`, `:998-1019`). An Elm user cannot write that: `Process.Id`, `Platform.Router`
and the effect-manager hooks are kernel-privileged. In beni that `Dict` is `Dict Key (Fiber ())`,
`Task.spawn` is a `core` function, and `Cmd.keyed` is fifty lines of library code that any developer
could have written. **That is the whole architectural dividend of transparency at this layer**, and
it is precisely rule 7's "a capability gap is filled inside the wall".

The second difference is inside the thunk. In Elm, `Http.get` produces a `Cmd`, not a `Task`, so two
dependent requests need an intermediate `Msg` and a second `update` branch; `Http.task` exists but
most of the ecosystem is not written in it. In beni the thunk is direct-style:

```elm
loadDashboard : Api, UserId -> Result HttpError Dashboard
loadDashboard api id =
    let
        user = api.getUser id?
        prefs = api.getPrefs user.id?
    in
    Ok (Dashboard user prefs)
```

— one `Cmd`, one `Msg`, no `Task.andThen`, and `?` for the error path. Whether that matters is
settled evidence: `research/14/elm` §0.1 found the `andThen` pyramid is *not* a real complaint
(twelve declarations out of 765 reach depth three). The thing it does delete is the
**intermediate-`Msg` state machine**, which is a different and more common cost — every
`GotUser -> ( model, fetchPrefs )` branch that exists only to sequence two calls.

### 3.3 `init`, `update`, `view`, `subscriptions`

```elm
init : Api, () -> ( Model, Cmd Msg )
sync init api _ =
    ( { query = "", status = Idle, favourites = Set.empty
      , saving = Set.empty, lastError = Nothing, width = 0 }
    , Cmd.run (\() -> Browser.windowWidth ()) Resized
    )


type Msg
    = Typed String
    | GotHits (Result HttpError (List Hit))
    | Favourited HitId Bool
    | FavouriteSaved HitId Bool (Result HttpError ())
    | Resized Int


type Key
    = SearchKey
    | FavouriteKey HitId
```

`Key` is an ADT and not a `String`, deliberately: a mistyped string key silently never cancels, which
is rule 7's silent-wrong-answer class, and the derived `compare` on a two-constructor type costs
nothing (`static-dispatch-spike.md` §3). §9.2 and decision 5 make this a recommendation rather than
a style note.

```elm
update : Api, Msg, Model -> ( Model, Cmd Msg )
sync update api msg model =
    case msg of
        Typed q ->
            ( { model | query = q, status = Loading }
            , Cmd.keyed SearchKey Restart (\() -> searchAfterDelay api q) GotHits
            )

        GotHits (Ok hits) ->
            ( { model | status = Loaded hits }, Cmd.none )

        GotHits (Err e) ->
            ( { model | status = Failed e }, Cmd.none )

        Favourited id want ->
            ( { model
                | favourites = setMember model.favourites id want
                , saving = Set.insert model.saving id
              }
            , Cmd.keyed (FavouriteKey id) Restart
                (\() -> api.setFavourite id want)
                (FavouriteSaved id want)
            )

        FavouriteSaved id want (Ok ()) ->
            ( { model | saving = Set.remove model.saving id }, Cmd.none )

        FavouriteSaved id want (Err e) ->
            ( { model
                | favourites = setMember model.favourites id (not want)
                , saving = Set.remove model.saving id
                , lastError = Just e
              }
            , Cmd.none
            )

        Resized w ->
            ( { model | width = w }, Cmd.none )
```

`FavouriteSaved id want (Ok ())` and `… (Err e)` are two branches of one constructor — ordinary
nested patterns, and `case` exhaustiveness (F2) is what makes "you forgot the failure path"
impossible.

```elm
subscriptions : Model -> Sub Msg
sync subscriptions _ =
    Browser.onResize Resized


view : Model -> Html Msg
sync view model =
    Html.div []
        [ Html.input [ Html.value model.query, Html.onInput Typed ] []
        , viewStatus model
        ]
```

`sync` is written on the definition, following P2 §3.2's `Decl := 'sync'? lower_ident …`. Where it
goes when there is an annotation — on the annotation, like `pub`, or on the definition — is not
settled anywhere; §13 records it.

### 3.4 Debounce and cancellation, which is where the example earns its keep

```elm
searchAfterDelay : Api, String -> Result HttpError (List Hit)
searchAfterDelay api q =
    let
        () = Task.sleep (Duration.millis 250)
    in
    api.search q
```

Three lines and the whole of requirement 3. The next `Typed` message returns a command under the
same `SearchKey` with `Restart`, so the runtime interrupts the fiber — whether it is parked in
`Task.sleep` or parked in the HTTP request — its finalisers run (releasing the `AbortController`
that the `fetch` primitive minted at the leaf, `research/16` §3.8), and **the continuation that
would have called `GotHits` no longer exists**. The stale response cannot land. Not "is ignored":
cannot land.

Compare three systems that had to build this:

- **redux-saga** spells debounce as a three-state machine whose middle state is
  `race({ action: take(pattern), debounce: delay(delayLength) })`
  (`saga/packages/core/src/internal/sagaHelpers/debounce.js:21-37`) and `takeLatest` as
  cancel-then-fork (`takeLatest.js:13-29`).
- **TCA** deleted its `.debounce` operator; the deprecation message is the recipe —
  *"Use 'clock.sleep' and 'cancellable(id:cancelInFlight:)' instead"*
  (`tca/Sources/ComposableArchitecture/Internal/Deprecations.swift:371-378`) — and its live case study
  writes exactly that (`Examples/CaseStudies/SwiftUICaseStudies/03-Effects-Basics.swift:51-55`).
- **Lustre** cannot: a `grep` for `cancel`/`abort`/`AbortController` across its `src/` returns
  nothing effect-related, and its own timer example's comment says the way to stop a repeating effect
  is to stop returning it (`lustre/examples/03-effects/03-timers/src/app.gleam:49-57`).

beni's version is the TCA recipe with the ceremony removed, because `Task.sleep` is a call and the
key is a value in the returned `Cmd`.

### 3.5 Optimistic update and rollback

It is two branches of `update` (above) and nothing else. The optimistic write happens in
`Favourited`; the rollback happens in `FavouriteSaved … (Err e)`. Both are transitions of the single
model, both are in the message log, and a test asserts them by comparing models.

TCA's own reusable favouriting feature is the same shape, with one instructive difference: it flips
optimistically in `.buttonTapped`, and rolls back in `.alert(.dismiss)` rather than in
`.response(.failure)` — the failure branch only arms an alert
(`tca/Examples/CaseStudies/SwiftUICaseStudies/05-HigherOrderReducers-ReusableFavoriting.swift:44-69`).
Which is right is a product decision; the point is that in both systems it is a *state transition in
the reducer*, not a `catch` around the effect. effect-atom automates the same thing at cell level —
`Atom.optimistic` shows a provisional value and, on failure, `get.setSelf(lastValue)`
(`references/effect/packages/effect/src/unstable/reactivity/Atom.ts:1957-1988`) — which is a
convenience TEA can also have as a helper and does not need.

Per-item keys matter here: `FavouriteKey id` means toggling hit A and hit B run concurrently, while
double-clicking hit A restarts A's own save. A single `FavouriteKey` with no id would serialise
unrelated toggles — a bug the example was designed to catch.

### 3.6 Wiring, and the one place no-currying bites

```elm
main : Program
main =
    Browser.element
        { init = \flags -> init realApi flags
        , update = \msg model -> update realApi msg model
        , view = view
        , subscriptions = subscriptions
        }
```

The lambdas are not decoration. `update realApi _ _` is **`multiple_placeholders`** — `language.md`
§6.7 allows at most one `_` per application — so a service threaded into a two-parameter `update`
must be written as a lambda. This is the first real program where the no-currying decision costs a
visible keystroke, and the cost is one lambda per entry point. The alternative, putting `realApi`
in the `Model`, costs the model's derived `eq` and is worse (§2.2).

### 3.7 Scorecard

| | |
|---|---|
| **What runs in a fiber** | the thunk inside every `Cmd`, and each live `Sub` |
| **What must be `sync`** | `init`, `update`, `view`, `subscriptions`, every tagger `(a -> msg)`, every event handler in `view` |
| **Cancellation** | keyed, structural, prompt; policy chosen per command |
| **Stale results** | impossible under `Restart`; under `Concurrent` the author tags, as in Elm |
| **Testing** | the whole interaction, headless: §9.6 |
| **Guarantees kept** | F1–F9. Single source of truth, exhaustive messages, no stale-closure class, time travel |
| **Cost to the developer** | one `Msg` constructor per effect result; the intermediate-`Msg` state machine is gone but the *result* message is not |
| **Needs beyond the decided design** | `sync` in argument position (already decided, A6); a `view` purity bit (§9.1); nothing else |
| **Rule 7** | Imposes: `update`/`view` may not suspend. Buys: the single-writer proof (§4.3) and render determinism. Legitimate |

---

## 4. Option B — TEA with an effectful `update`

**The shape.** `update : Msg, Model -> Model`, and it may perform:

```elm
-- NOT `sync`: this is the option
update : Api, Msg, Model -> Model
update api msg model =
    case msg of
        Typed q ->
            let
                () = Task.sleep (Duration.millis 250)
                hits = api.search q
            in
            { model | query = q, status = statusOf hits }

        Favourited id want ->
            let
                saved = api.setFavourite id want
            in
            case saved of
                Ok () -> { model | favourites = setMember model.favourites id want }
                Err e -> { model | lastError = Just e }

        Resized w ->
            { model | width = w }
```

It is shorter, it needs no `GotHits`, no `FavouriteSaved`, no `Cmd`, no `Key`, and it is *wrong*.
Not stylistically: wrong in the sense that it computes the wrong model, silently.

### 4.1 The typeahead, keystroke by keystroke

The user types `a`, then 80 ms later `ab`.

- `t=0` `Typed "a"` arrives. `update` starts on a fiber and parks in `Task.sleep`. **The model has
  not changed** — `update` has not returned. The input box is rendered from `model.query`, which is
  still `""`.
- `t=80` `Typed "ab"` arrives. Now the runtime must choose, and there are only two choices.

### 4.2 The two choices, and both are bad

**B1 — mailbox (an actor).** Queue the message; process it when the first `update` returns. The
model is never raced. But `update` for `Typed "a"` takes 250 ms plus an HTTP round trip, and during
all of it *no message is processed at all* — not the second keystroke, not `Resized`, not the
favourite toggle. A controlled input box renders `model.query`, so the user's second character does
not appear on screen until the first search resolves. **The text input freezes for the length of an
HTTP request.** That is not a subtle failure; it is the single most visible bug a web application
can have, and it is what the actor discipline costs when the actor owns the view state.

**B2 — concurrent.** Run each `update` on its own fiber against the model as it stood when the
message arrived, and let whoever finishes last write. Then:

- `update(Typed "a", M₀)` is parked; it holds `M₀`.
- `update(Typed "ab", M₀)` runs, parks, resumes at `t≈330`, and writes
  `M₀ with query="ab", status=Loaded [...]`.
- `update(Typed "a", M₀)` resumes at `t≈250+rtt`, and writes `M₀ with query="a", status=Loaded [...]`.

The second keystroke is **lost**, along with everything else any interleaved message wrote — the
favourite toggle that landed in between, the resize. This is the classic read-modify-write race, and
it is exactly the bug class TEA exists to delete. In a language whose rule 7 names "no silent wrong
answer" as a guarantee, shipping it as the default architecture is not defensible.

**B3 — the re-application patch.** The interesting repair, and worth stating because it is what
React actually does. Do not let `update` return a *model*; let it return a *function* `Model ->
Model` applied atomically at the moment it resumes — React's `setState(s => …)` functional updater.
It fixes B2's lost update. It does not fix the type: with `update : Msg, Model -> Model` the `model`
in scope *after* a suspension is a value captured before it, and nothing in the source says so.
Every read of `model` after the first suspension point is a **stale-closure bug**, silently. The
repair is to make the post-suspension code take the fresh model as a parameter — at which point
`update` has become "a pure step, then an effect, then another pure step keyed by a message", which
is option C with the seams hidden.

### 4.3 What this proves, and it is the report's central result

The failure in B1 and B2 has one cause: **a suspension point is the only place another fiber can
interleave** (P2 §9.1: "a suspension point is also a point at which nothing else can run";
§6.2: an interrupt is delivered at a suspension point and nowhere else). Therefore:

> A `sync` function runs to completion with no interleaving. If `update` is `sync`, every message is
> applied to the model atomically, there is exactly one writer, and a lost update is impossible.
> The compiler checks it.

Elm has this property because JavaScript cannot suspend a stack (P2 §1). beni will be able to suspend
one, so the property stops being free and becomes a *check* — and A6 has already decided to build
that check. The browser platform's job is to spend it: `update`, `init`, `view`, `subscriptions` and
every tagger are `sync`, and the `Program` record's field types say so, which is precisely the
argument position `sync_boundary` exists for (P2 §8; report 17 §5.1's seven imposed signatures).

TCA arrives at the same serialisation by a weaker route: its `Reducer` protocol carries **no** actor
annotation (`tca/Sources/ComposableArchitecture/Reducer.swift:3`), and `reduce` is synchronous and
non-throwing by signature; what serialises it is that the only caller, `Core._send`, is `@MainActor`
(`Core.swift:9-10`, and the reducer call is an ordinary inline call at `Core.swift:116`). The
guarantee is a property of the *caller's* isolation. beni's `sync` puts it in the *callee's type*,
where a reviewer and a compiler can both see it.

### 4.4 Scorecard

| | |
|---|---|
| **Guarantees lost** | single source of truth (B2), no-stale-closure (B3), responsiveness (B1) |
| **Guarantees kept** | exhaustive messages; no runtime exception |
| **Needs** | nothing new — which is the trap: it is the option that compiles first and fails last |
| **Rule 7** | B imposes no restriction and buys no guarantee. That is not rule 7 working; rule 7 asks what a *rule* buys, and B's problem is the absence of one |
| **Verdict** | **Rejected as an architecture.** Worth keeping as a diagnostic: if a user's `update` ever fails the `sync` check, the error should say *why* the rule exists, not merely that it was broken |

---

## 5. Option C — pure `sync` `update`, plus fibers that send messages

**The shape.** `update` is exactly option A's: `sync`, pure, total. What changes is the command: it
is not "a thunk plus a tagger" but "a function that receives a `send` and may use it any number of
times, over any span of time".

### 5.1 The API [proposed]

```elm
--| The capability a running effect has: put a message in the mailbox. It is
--| `sync` because it re-enters the dispatcher, which calls `update`, which is
--| `sync`. It is `impure`, so the optimiser may not drop or duplicate a send.
pub type alias Send msg =
    sync (msg -> ())

pub perform : (Send msg -> ()) -> Cmd msg

pub performKeyed : k, Policy, (Send msg -> ()) -> Cmd msg
    where k.compare : k, k -> Order

--| Option A's constructors, which are now DEFINITIONS rather than primitives:
pub run : (() -> a), sync (a -> msg) -> Cmd msg
run task tag =
    perform (\send -> send (tag (task ())))
```

That four-line definition is the whole relationship between the options: **A is C with the `send`
called exactly once, at the end.** Anything A expresses, C expresses; C additionally expresses
progress, streaming, retry-with-feedback, and "start two requests and report each as it lands",
none of which A can say without a `Sub`.

This is not a novel shape. It is Lustre's `Effect`, which is literally a list of callbacks handed a
record of runtime capabilities —

```gleam
// lustre/src/lustre/effect.gleam:96-114
pub opaque type Effect(message) {
  Effect(synchronous: List(fn(Actions(message)) -> Nil),
         before_paint: List(fn(Actions(message)) -> Nil),
         after_paint:  List(fn(Actions(message)) -> Nil))
}
type Actions(message) {
  Actions(dispatch: fn(message) -> Nil, emit: ..., select: ..., root: ..., ...)
}
```

— and it is TCA's, whose `Effect.Operation` has exactly three cases, of which the live one is
`run(name:priority:operation: @Sendable (_ send: Send<Action>) async -> Void)`
(`tca/Sources/ComposableArchitecture/Effect.swift:5-24`, `:92-101`). Two independent TEA descendants
converged on "the effect is a function that is handed a `send`".

Three further notes, all from source:

- **`Send` must not suspend.** TCA's is `@MainActor` and its `callAsFunction` early-returns if the
  task was cancelled: `guard !Task.isCancelled else { return }` (`Effect.swift:180-194`). beni gets
  the first half from `sync` and should copy the second: **a send from an interrupted fiber is
  dropped**, not an error, because F5 says interruption is invisible to the interrupted code.
- **Lustre's `Actions` record is the argument for making `send` a plain function rather than an
  opaque handle.** Lustre passes a record because it also carries `emit`, `root`, `subscribe`. beni
  should pass `Send msg` alone until something needs more, because a bare `msg -> ()` is trivially
  faked in a test (`\m -> Ref.update log (\l -> m :: l)`), and an opaque platform type is not.
- **`Cmd.map` must map the key as well as the message.** §9.8.

### 5.2 The example

`update` is character-for-character option A's (§3.3), with the command constructors changed:

```elm
        Typed q ->
            ( { model | query = q, status = Loading }
            , Cmd.performKeyed SearchKey Restart (searchEffect api q _)
            )
```

`searchEffect api q _` is a **placeholder**, not a lambda — one `_` per application is exactly the
budget (`language.md` §6.7), and this is the shape it was designed for:

```elm
searchEffect : Api, String, Send Msg -> ()
searchEffect api q send =
    let
        () = Task.sleep (Duration.millis 250)
    in
    send (GotHits (api.search q))
```

The favourite toggle is the same, and gains something A cannot say — a "saving" message before the
request and the result after it, from **one** effect:

```elm
saveFavourite : Api, HitId, Bool, Send Msg -> ()
saveFavourite api id want send =
    let
        () = send (SaveStarted id)
        result = api.setFavourite id want
    in
    send (FavouriteSaved id want result)
```

In A that is two commands or a `Sub`. Here it is a fiber with two sends, and the mailbox serialises
both against every other message.

### 5.3 Where the fiber lives, and what cancels it

The runtime holds `Dict Key (Fiber ())`, every command's fiber is spawned in the **program's root
scope**, and the four policies are the four decisions about an existing entry. That is fifty lines of
beni over `Task.scope`/`Task.spawn`/`Fiber.cancel`, and it is the code `elm/http` had to write in
Elm's kernel (§3.2).

Two cancellation designs exist and the evidence favours keys, but not unanimously:

- **Keys** (`boundary.md` §5.4; TCA; React Query; SwiftUI `.task(id:)`; Compose `LaunchedEffect(key)`;
  redux-saga `takeLatest`). A key is *data*, so it survives the gap between the `update` that starts
  work and the `update` that cancels it — and §5.4's argument is exact: `update` is `sync` and pure,
  so no beni frame is alive in between.
- **Handles** (Kotlin `Job`, Go `context`, Effect `Fiber.interrupt`, Swift `Task`). Iced — an
  Elm-like in Rust — does hold handles, and can, because `Handle::abort_on_drop` ties the abort to
  the model's own lifetime (`iced/runtime/src/task.rs:218-234`, `:317-330`). beni has no `Drop`, and
  a `Fiber` in the model destroys the model's derived `eq` (§2.2). **Keys.**

TCA's registry is worth copying in one respect and not in another. Copy: the id is a *value* and
`cancelInFlight: true` is a swap under a lock —

```swift
// tca/Sources/ComposableArchitecture/Effects/Cancellation.swift:163-192
let (cancellable, task) = _cancellationCancellables.withValue {
  if cancelInFlight { $0.cancel(id: id, path: navigationIDPath) }
  let task = Task { try await operation() }
  ...
}
```

— which is `Restart`, exactly. Do not copy: TCA's effects are *unstructured* `Task`s bookkept by hand
(`Core.swift:159`, `:194-216`), because Swift's task tree does not match TEA's lifetimes. beni's
scopes do, so the fiber tree and the cancellation tree can be the same tree.

### 5.4 Scorecard

| | |
|---|---|
| **What runs in a fiber** | each command's `Send msg -> ()` function; each live subscription |
| **What must be `sync`** | `init`, `update`, `view`, `subscriptions`, `Send`, event handlers, taggers |
| **Cancellation** | keyed, structural, prompt; plus root-scope cancellation at unmount |
| **Stale results** | impossible under `Restart`; a send from a cancelled fiber is dropped |
| **Concurrency vs the model** | serialised by `sync update` (§4.3) |
| **Testing** | §9.6; `Send` is a plain function, so the fake is one lambda |
| **Guarantees kept** | all of F1–F9 |
| **Cost** | one `Msg` constructor per *observable* step — not per effect |
| **Needs beyond the decided design** | `sync` in argument position (decided); a `view` purity bit (§9.1); a key-namespacing rule for `Cmd.map` (§9.8) |
| **Rule 7** | Imposes `sync` on five signatures; buys atomic updates, render determinism, leak-free subscriptions. Every restriction is paid for |

### 5.5 The sharpest objection to C

**The key namespace is unchecked, and `Cmd.map` is where it breaks.** Two instances of the same child
component both return `Cmd.performKeyed SearchKey Restart …`; the parent maps both with `Cmd.map`;
they now share a bucket and each cancels the other. Nothing in the type system notices. This is
rule 7's silent-wrong-answer class arriving through the front door, and it is *not* hypothetical —
it is why TCA registers every cancellable under every prefix of a `NavigationIDPath`
(`Cancellation.swift:251-260`). §9.8 and decision 5 propose the fix; the objection stands until one
is taken.

The second objection is milder: a `Cmd` is an opaque closure, so `update`'s output is not inspectable
data, and a test cannot assert "this command was issued" without running it. Elm has the same
problem and `boundary.md` §5.4 already answers half of it — the *key* is ordinary data in the
returned value, so "navigating away cancels the search" is assertable where in Elm it is not.

---

## 6. Option D — components with local state

**The shape.** A component is a function from props to a view; it owns state that lives as long as
it is mounted; it starts effects tied to mount and cancels them on unmount or when a key changes.
React, SwiftUI and Compose.

### 6.1 What beni gives it for free, and it is more than any of those three

**Unmount is a scope close.** F5's structured concurrency says: closing a scope interrupts children
before the parent's finalisers run, finalisers are infallible, and the interrupter waits for cleanup.
That is the component lifecycle, exactly, and the three frameworks each hand-build it:

```kotlin
// Compose, Effects.kt:492-535
internal class LaunchedEffectImpl(...) : RememberObserver, CoroutineExceptionHandler {
    override fun onRemembered() { job?.cancel("Old job was still running!"); job = scope.launch(block = task) }
    override fun onForgotten() { job?.cancel(ExitedCompositionCancellationException()); job = null }
    override fun onAbandoned() { job?.cancel(ExitedCompositionCancellationException()); job = null }
}
```

`LaunchedEffect(key1) { block }` is `remember(key1) { LaunchedEffectImpl(...) }`, so a key change is
forget-then-remember — **cancel and relaunch**, the `Restart` policy again, at component granularity.
`DisposableEffect(key) { onDispose { … } }` is the same hook pair with an acquire and a release
(`Effects.kt:259-280`, `:335-340`) — that is `Task.bracket`. `rememberCoroutineScope` cancels on
`onForgotten` only, never on a key change (`:802-817`, `:864-872`) — that is a child `Scope`.

So the mapping is total:

| Compose | beni |
|---|---|
| `LaunchedEffect(key) { … }` | `Scope.replace scope key (\() -> …)` — a keyed child fiber |
| `DisposableEffect(key) { onDispose { … } }` | `Task.bracket acquire release use`, or `Scope.finalizer` |
| `rememberCoroutineScope()` | a child `Scope` |
| `remember { mutableStateOf(x) }` | `Ref.make x`, owned by the scope |

beni's version is stronger in two ways Compose cannot be: finalisers are **infallible** by type
(A1), so the two-failures-at-once case does not exist, and the interrupter **waits** for cleanup
(A10), so "unmounted" means "its sockets are closed", not "its cancel has been requested".

### 6.2 The example, and where it stops

```elm
--! [proposed] API: `Scope.state`, `Scope.replace`, `Html.dyn` are this
--! section's invention, not a decided design.
typeahead : Api, Scope -> Html Msg
sync typeahead api scope =
    let
        query = Scope.state scope ""
        status = Scope.state scope Idle

        onInput q =
            let
                () = Ref.set query q
            in
            Scope.replace scope SearchKey
                (\() ->
                    let
                        () = Task.sleep (Duration.millis 250)
                    in
                    Ref.set status (statusOf (api.search q))
                )
    in
    Html.div []
        [ Html.input [ Html.value (Ref.get query), Html.onInput onInput ] []
        , viewStatus (Ref.get status)
        ]
```

`onInput` is `sync`: `Scope.replace` interrupts the previous fiber and spawns a new one and returns;
it does not suspend. Cancellation and debounce are as good as option C's, and the *code* is shorter,
because the state transitions have no names.

Then it stops, on two things.

**(1) Nothing re-renders.** `Ref.set status` changes a cell; no one is listening. A component system
needs an invalidation path from a cell to the renderer, and the kernel (§10) does not have one. There
are only two ways to build it: mark the subtree dirty and re-render it (React), or track which reads
depended on which cells (option E). The first needs a second scheduler beside the render loop; the
second **is** option E. **effect-atom plus React is precisely the second choice made explicitly**:
the atom registry tracks dependencies, and React's binding is
`useSyncExternalStore(store.subscribe, store.snapshot, …)`
(`references/effect/packages/atom/react/src/Hooks.ts:54-58`). So option D is not an independent
runtime; it is E's runtime with a coarser granularity, or a vdom with a dirty bit.

**(2) `view` stops being pure.** `Ref.get query` inside the view is `impure`, which costs `Html.lazy`
and costs render determinism (§9.1). That is not fatal — it is a decision to have no `lazy` — but it
is a guarantee traded, and it should be traded knowingly.

### 6.3 What it loses against TEA, and what it keeps

**Loses:** the single source of truth (state is scattered across scopes, so "what is the app's state"
has no answer and therefore no serialisation and no time travel); the message log; and the
atomicity proof of §4.3. That last is the sharp one: two fibers both doing
`Ref.get` … suspend … `Ref.set` on the same cell is a lost update, and `sync` does not help because
the suspension is in the *effect*, not in the handler. The mitigation is real and cheap —
`Ref.update r f` and `Ref.modify` are atomic between suspension points, and the rule is "never split
a read and a write across a suspension" — but it is a rule a developer must know, where TEA's is a
rule the compiler enforces.

**Keeps:** F1, F2 (each component still matches exhaustively on its own results), F3, F5, F7.
Nothing in rule 7's list is broken.

### 6.4 The rule 7 verdict: is forbidding local state a guarantee or a taste?

**The case that it is taste, and beni must not forbid it.** Rule 7's list is: no runtime exception,
no silent wrong answer, exhaustive matches, managed effects. Local state in a `Ref` owned by a scope
breaks none of them. A `Ref` cannot dangle (the scope owns it), cannot leak (the scope's close drops
it), cannot throw, and cannot be read uninitialised. "You should keep all state in one place" is a
*design* opinion — a good one, held by this report — and rule 7 is explicit that a rule which "only
encodes taste, or 'you should not need that', does not belong". Moreover the capability is already
in the box: `Ref` is **T0** in r22 §8, so the language ships the ingredient and would be withholding
only the arrangement. That is the sparse-garden mistake `boundary.md` §1 exists to avoid.

**The case that it is a guarantee.** The lost-update hazard above is a silent wrong answer, and TEA
forecloses it by construction. If the platform ships a component library, it ships that hazard, and
beni has no static check for it — `sync` does not catch it, because the code is allowed to suspend;
it is the *interleaving of a read and a write* that is wrong.

**The verdict.** The hazard is real but it is not a property of *local state*; it is a property of
*mutable cells plus concurrency*, and `Ref` is already T0, so the hazard exists whether or not a
component library does. Forbidding D therefore buys nothing that shipping `Ref` has not already
spent. **Do not forbid it. Do not ship it in v1 either** — ship TEA, keep the kernel from
accidentally excluding D (§10), and if the hazard proves common, answer it with a `Ref.modify`-only
discipline or an `atomically` combinator, which is a library, not a rule.

### 6.5 Scorecard

| | |
|---|---|
| **What must be `sync`** | the component function itself (it is called by the renderer), every handler |
| **Cancellation** | keyed per scope; unmount cancels everything below — the best story of any option |
| **Stale results** | `Scope.replace` under a key; same guarantee as C |
| **Concurrency vs state** | **not** serialised; read-modify-write across a suspension is a lost update |
| **Testing** | harder: no message log to assert; the test must drive a renderer, or the component must expose its `Ref`s |
| **Needs beyond the decided design** | an invalidation path (a dirty-marking renderer, or §7's tracking) |
| **Rule 7** | Do not forbid; do not bless |

---

## 7. Option E — signals / fine-grained reactivity

**The shape.** No virtual DOM and no diff. A cell holds a value; reading it inside a *computation*
records a dependency; writing it re-runs exactly the computations that read it, which update exactly
the DOM nodes they built. Solid, Leptos, Svelte 5, Vue.

### 7.1 The mechanism, from source

The read is the mutation, and it is gated by a mutable global:

```ts
// solid/packages/solid/src/reactive/signal.ts:51-59
export var Owner: Owner | null = null;
let Listener: Computation<any> | null = null;

// :1302-1339 (readSignal)
if (Listener) {
  ...
  Listener.sources.push(this);  Listener.sourceSlots.push(sSlot);
  observers.push(Listener);     this.observerSlots.push(Listener.sources.length - 1);
}
```

Leptos is the same shape with a `thread_local! static OBSERVER`
(`leptos/reactive_graph/src/graph/subscriber.rs:7-9`) and an RAII guard instead of a `finally`, and
its `Track::track()` does `subscriber.add_source(...)` / `self.add_subscriber(subscriber)`
(`leptos/reactive_graph/src/traits.rs:110-120`).

The owner tree *is* a scope tree: `cleanNode` recurses into `node.owned` before running
`node.cleanups` — children first, exactly F5's order
(`solid/.../signal.ts:1700-1738`); Leptos's `Drop for OwnerInner` does the same
(`leptos/reactive_graph/src/owner.rs:519-547`).

### 7.2 How it sits with beni's purity and the `impure` bit

Better than it looks. A signal read mutates two arrays, so it is `impure` and not `suspends` — the
same class as `console.log` or `Ref.get`, which P2 §2 uses as its motivating example for splitting
the two bits. A5 has already decided `impure` is honoured from the first slice, so the optimiser may
not drop, duplicate, reorder or memoise a signal read. **`Opt.zig`'s single-use inlining, which moves
a binding to its use site, is exactly the transform that would silently break dependency tracking,
and `impure` already forbids it.** So beni's optimiser licence is not the obstacle; it is, unusually,
a help.

What *is* an obstacle is one thing, and it is the thing.

### 7.3 The suspension point destroys the tracking context, and only one system in the survey fixes it

Solid's computation runner installs the listener, calls the function, and restores in a `finally`:

```ts
// solid/packages/solid/src/reactive/signal.ts:1402-1427
const owner = Owner, listener = Listener;
Listener = Owner = node;
try { nextValue = node.fn(value); }
finally { Listener = listener; Owner = owner; }
```

If `node.fn` is async, it returns a promise at its first `await`, the `finally` runs **then**, and
every signal read after that point is untracked. Silently — there is no warning anywhere in
`signal.ts`, and `createResource` copes by convention: track synchronously up front, hand an already
tracked value to an untracked fetcher.

Leptos fixes it, and the fix is instructive:

```rust
// leptos/reactive_graph/src/computed/async_derived/mod.rs:72-87
fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
    let this = self.project();
    this.owner.with(|| this.observer.with_observer(|| this.fut.poll(cx)))
}
```

Rust's executor re-enters `poll` after every `.await`, so re-installing `Owner`/`Observer` inside
`poll` restores the context on **every resumption**. Its own doc example reads a signal after a
`sleep().await` and is tracked (`arc_async_derived.rs:63-70`).

**beni is the only language in this survey that could do that in the scheduler rather than in a
wrapper**, because P2 §6.1 gives the runtime the resume callback: whatever a fiber slot holds can be
restored at each resumption, once, for every fiber. The cost is that it needs a slot, and **A7 bought
exactly three fixed slots and declined a general `Context`**. A "current observer" is a fourth. It is
small — one pointer, inherited on fork, restored on resume — and it is a decision, not an
implementation detail (decision 6). r22 §10 item 1 / B11 already flags the neighbouring question
(*"can a fiber-local `Key a` be typed soundly without a language feature"*) as needing a spike.

### 7.4 The example

```elm
--! [proposed] API throughout: `Signal`, `Signal.resource`, `Html.dyn`.
typeahead : Api -> Node
sync typeahead api =
    let
        query = Signal.make ""
        hits =
            Signal.resource
                (\() -> Signal.get query)
                (\q ->
                    let
                        () = Task.sleep (Duration.millis 250)
                    in
                    api.search q
                )
    in
    Html.div []
        [ Html.input [ Html.onInput (Signal.set query _) ]
        , Html.dyn (\() -> viewStatus (Signal.get hits))
        ]
```

Note the shape `Signal.resource` has to have: a **`sync` source function** whose reads are tracked,
and a **suspending fetcher** whose reads are not. That is Solid's `createResource` signature and it
exists for exactly the §7.3 reason. Under decision 6 beni could collapse the two into one suspending
tracked function, which is a genuine improvement over both Solid and Leptos — Leptos needed a
`ScopedFuture` per future; beni would need it zero times.

And beni would get what neither has: **real cancellation of the superseded fetch**. Neither Solid nor
Leptos aborts a stale request (§0 finding 4). effect-atom, which is the same idea over a fiber
runtime, *does*:

```ts
// references/effect/packages/effect/src/unstable/reactivity/Atom.ts:578-604
const fiber = runFork(effect)
const remove = fiber.addObserver(onExit)
function cancel() { remove(); if (!uninterruptible) { fiber.interruptUnsafe() } }
```

and the registry disposes the lifetime — running that finalizer — at the *start* of `invalidate()`,
before the rebuild (`AtomRegistry.ts:741-758`, `:1012-1023`). That is the piece beni's version would
inherit for nothing.

### 7.5 What it costs against beni's commitments

- **F2 weakens.** There is no `Msg` type and so no exhaustive `case` over "everything that can happen
  to this screen". Per-cell `Result`s are still matched exhaustively; the *whole-program* version of
  the guarantee is gone.
- **Single source of truth is gone**, with time travel and state serialisation.
- **The emitter story changes.** No vdom means `view` builds DOM nodes with `impure` calls and
  `Html.lazy` is meaningless (which, as §9.1 notes, resolves that problem by deleting it).
- **The suspension-point hazard of §7.3 is a silent wrong answer** until decision 6 is taken. That is
  disqualifying for v1 and fixable afterwards.

### 7.6 Scorecard

| | |
|---|---|
| **What must be `sync`** | the component body, tracked source functions, handlers, the DOM effects |
| **Cancellation** | per cell, on invalidate and on last-unsubscribe — effect-atom's mechanism, better than Solid's or Leptos's |
| **Stale results** | cancelled, not discarded — the best of any option |
| **Concurrency vs state** | per-cell; no global serialisation |
| **Testing** | per-cell assertions; no message log; the whole-interaction test is harder |
| **Needs beyond the decided design** | **a fiber-local observer slot** (decision 6) — without it, silently wrong |
| **Rule 7** | Forbidding it is taste. Shipping it before decision 6 would ship a silent wrong answer |

---

## 8. Option F — what the evidence turns up

Seven systems, each read for the one mechanism that bears on a decision above.

### 8.1 TCA — the closest existing system to option C

Its reducer is synchronous and non-throwing by signature
(`tca/Sources/ComposableArchitecture/Reducer.swift:34`), the effect is
`run(name:priority:operation: (Send<Action>) async -> Void)` (`Effect.swift:92-101`), and the store
starts one unstructured `@MainActor` `Task` per action's effect whose `send` re-enters the reducer
loop synchronously (`Core.swift:157-198`). Four things to take and two to leave:

**Take.** (1) The cancellation id is an ordinary `Hashable` value and `cancelInFlight: true` is a
cancel-then-register swap (`Cancellation.swift:163-192`) — `boundary.md` §5.4's `Restart`. (2) The id
is scoped by a *path*, registered under every prefix (`Cancellation.swift:251-260`), which is the
answer to §5.4's open namespacing question. (3) A child feature's effects are all registered under a
sentinel id at the child's path, so when the child's identity changes the parent fires one `.cancel`
and every descendant effect dies (`PresentationReducer.swift:486-499`, `:542-554`) — *dismissal
cancels the subtree*, which in beni is just closing a scope. (4) `TestStore`'s two exhaustivity
assertions, quoted in §9.6.

**Leave.** (1) The unstructured `Task` plus a global `LockIsolated(CancellablesCollection())`
(`Cancellation.swift:226`) — beni's scopes make the fiber tree and the cancel tree the same tree.
(2) The default error path: an `Effect.run` whose operation throws and which supplied no `catch:`
produces `reportIssue("An \"Effect.run\" ... threw an unhandled error.")` (`Effect.swift:104-133`) —
a purple box in development and a test failure. beni has no throwing to catch: errors are `Result`s
and the only unhandled thing is a *defect*, which A1 says is fatal (§9.5).

### 8.2 effect-atom — Effect's own UI story

An `Atom<A>` is `{ keepAlive, lazy, read: (get: AtomContext) => A, equals, idleTTL?, refresh? }`
(`references/effect/packages/effect/src/unstable/reactivity/Atom.ts:67-77`); a writable one adds
`write(ctx, value)`. The registry is one `Map` of nodes with `parents`/`children`/`listeners`, and
the dependency edge is added by the `get` handed to a derived atom's `read`:

```ts
// references/effect/packages/effect/src/unstable/reactivity/AtomRegistry.ts:863-871
get<A>(this: Lifetime<any>, atom: Atom.Atom<A>): A {
  const parent = this.node.registry.ensureNode(atom)
  const value = parent.value()
  this.node.addParent(parent)
  return value
}
```

What the UI sees while an effect runs is `AsyncResult` — `Initial | Success | Failure` with a
**`waiting` flag** that keeps the last value visible while new work runs
(`AsyncResult.ts:156-158`, `:230-234`, `:268-272`). That three-plus-a-flag shape is better than this
report's `Status` for a typeahead (it distinguishes "loading with nothing" from "loading, showing
stale results"), and it is a library type any option can adopt.

Cancellation is the finding (§0 item 8, §7.4). React reads with `useSyncExternalStore` and a
synchronous snapshot, and suspension is opt-in through a separately named hook
(`packages/atom/react/src/Hooks.ts:54-58`, `:371-384`) — i.e. *the render path is kept synchronous by
construction, not by a rule*, which is what beni's `sync` does with a type.

### 8.3 Lustre — TEA on a typed functional language, two targets, no cancellation

§5.1 quotes its `Effect`. Three findings bear on beni.

**The effect runs synchronously inside `dispatch`, and the runtime re-enters `update` in a loop for
anything a synchronous effect dispatched immediately** (`runtime.ffi.mjs:110-122`, `:259-302`), with
`before_paint` drained in a `queueMicrotask` after the patch and `after_paint` in a
`requestAnimationFrame` (`:313-345`). That three-phase split is a real design input for §9.1: a
browser platform wants a way to say "run this after the DOM is updated but before paint" (focus,
measurement, scroll restoration), and beni's `Cmd` has no such phase. Recommend it be added as a
`Cmd` phase rather than discovered later.

**There are no subscriptions**, and listener registration leaks by construction (§0). The exception
proves the rule: the context protocol *does* have `subscribe`/`unsubscribe` and calls the previous
unsubscribe before resubscribing (`effect.gleam:293-306`, `runtime.ffi.mjs:165-206`, with an
`unsubscribeAll()` on teardown). Whoever designs beni's `Sub` should read that pair as "the shape you
need everywhere, which Lustre built once".

**A component is a whole TEA instance** with its own `init`/`update`/`view`, mounted as a custom
element with a shadow root; the parent talks in through `on_attribute_change`/`on_property_change`
decoders and the child talks out with a real bubbling `CustomEvent` (`component.gleam:118-144`,
`runtime.ffi.mjs:124-128`). That is a genuine answer to §9.8's composition question that Elm does not
have — child-owned state with the DOM as the message bus — and it costs a custom-element boundary.

Server components reuse the identical `init/update/view` and ship `Mount` then `Reconcile(patch)`
over a pluggable transport (`transport.gleam:13-38`, `server_component.gleam:117-121`). This is the
best available evidence for §10's layering claim: one TEA program, three runtimes, and the difference
is entirely "who drains the effects and where the patch lands".

### 8.4 Iced — an Elm-like where subscriptions are hashed and handles are held

`Subscription`s are diffed by hashing each recipe; live executions are kept in a map; the ones not in
the new set are dropped, and dropping the `oneshot::Sender` cancels the stream:

```rust
// iced/futures/src/subscription/tracker.rs:69-124 (elided)
let id = { let mut hasher = Hasher::default(); recipe.hash(&mut hasher); hasher.finish() };
alive.insert(id);
if self.subscriptions.contains_key(&id) { continue; }
let (cancel, mut canceled) = futures::channel::oneshot::channel();
...
self.subscriptions.retain(|id, _| alive.contains(id));
```

That is Elm's subscription diff in another language, and it makes explicit what Elm's kernel does
implicitly: **a subscription's identity is a value, and unsubscribe is a resource release**. beni's
version of `retain` is "close the scope", which runs the finaliser. §9.4.

Iced also holds effect handles in the model (`runtime/src/task.rs:218-234`, `:317-330`), which only
works because Rust's `Drop` gives the handle a lifetime. It is the counter-example that proves
`boundary.md` §5.4's keys argument rather than undermining it.

### 8.5 redux-saga — option C with a DSL

`takeLatest` is a three-state machine: take, cancel the previous task if any, fork a new one
(`saga/packages/core/src/internal/sagaHelpers/takeLatest.js:13-29`). `debounce` is
`race({ action: take(pattern), debounce: delay(delayLength) })` (`debounce.js:21-37`). Both are
*exactly* what a beni effect writes in straight-line code with `Task.sleep` and a `Restart` key, and
the reason saga needs a DSL is that JavaScript generators are its only way to make a cancellable
suspension. beni's suspension is a call. **The whole of redux-saga's vocabulary is, in beni, either a
`Task` primitive that already exists (`race`, `timeout`, `spawn`, `join`) or ordinary control flow.**

### 8.6 Compose — keyed scopes as the component lifecycle

Quoted in §6.1. The one line worth repeating is its doc warning: *"Jobs should never be launched into
any coroutine scope as a side effect of composition itself"* (`Effects.kt:855-856`) — i.e. the render
pass must not start work; work is started by a lifecycle-owned hook. beni's `sync view` says the same
thing more strongly and earlier: a view that started a fiber would be `impure`, and (§9.1) `view`
should be neither `impure` nor `suspends`.

### 8.7 Elm's own `Http` — the privileged version of §5.3

`cancel : String -> Cmd msg` (`elm-http/src/Http.elm:669-671`), a `State` of
`{ reqs : Dict String Process.Id, subs : List (MySub msg) }` (`:973-976`), and `updateReqs` looking
the tracker up and killing the process (`:998-1019`). Elm *has* keyed cancellation; it is available
to one package because that package is kernel. beni's `Cmd.keyed` is that, un-privileged. For Elm's
scheduler, the effect-manager protocol and the virtual DOM, see report 24.

---

## 9. The cross-cutting questions

### 9.1 Where may code suspend, and what must be `sync`

Report 17 §5.1 enumerated seven imposed signatures whose callback the host calls synchronously. For a
browser they are:

| Signature | Why it cannot suspend |
|---|---|
| `view : Model -> Html Msg` | called from the render loop, inside a frame |
| `update`, `init`, `subscriptions` | §4.3 — atomicity; and the dispatcher has no frame to park |
| an event handler / tagger `Event -> Msg` | `preventDefault`, `stopPropagation` and `composedPath()` are only valid **synchronously** inside dispatch; a handler that parked and resumed would call them too late |
| a `rAF` callback | the frame is over when it returns |
| `Send msg` | it re-enters `update` |
| a comparator, a decoder | report 17 §5.1 |

**And `view` needs a second bit.** `Html.lazy` — and any render memoisation, and re-rendering only
when the model changed — is the *drop* licence of `language.md` §6, which A5 has just decided
`impure` revokes. So:

- if the platform offers `lazy`, `view` must be **not `impure`** as well as `sync`, or `lazy` is a
  silent wrong answer whenever a view reads a `Ref`;
- if the platform does not offer `lazy`, one bit suffices and options D and E become cheaper.

P2 §3.2 and plan §2.5 costed **one** bool on a function type. This is the first requirement for a
second. It is decision 3, and it is not a rendering detail: it decides how many bits
`Interface.Term.Tag` carries.

### 9.2 Stale results

| Option | Mechanism | Does the work stop? |
|---|---|---|
| A, C | `Restart` key → the fiber is interrupted; the continuation is gone | **yes**, promptly |
| B | nothing — the race *is* the bug (§4.2) | no |
| D | `Scope.replace key` → same as A/C, at component granularity | yes |
| E | invalidate → dispose lifetime → interrupt, as effect-atom does | yes |
| Elm | tag the `Msg` and ignore it in `update` | no |
| Lustre | tag the id into the message (`app.gleam:89-100`) | no |
| Solid | `pr === p` promise identity (`signal.ts:650`) | no |
| Leptos | a version counter (`arc_async_derived.rs:368-390`) | no |
| TCA | `cancelInFlight: true` (`Cancellation.swift:163-192`) | yes |

The four policies of `boundary.md` §5.4 are RxJS's `switchMap`/`exhaustMap`/`concatMap`/`mergeMap`,
and every system above that has a policy at all has exactly `Restart`. Shipping all four costs
nothing and is awkward to add later; §5.4 is right.

### 9.3 Concurrency against the model

| Option | What serialises writes |
|---|---|
| A, C | **`sync update`** — no suspension point inside the writer, therefore no interleaving (§4.3). Checked |
| B1 | a mailbox — but the mailbox also blocks the UI |
| B2 | nothing. Lost updates |
| D, E | per-cell; `Ref.update`/`Ref.modify` are atomic between suspension points, and read-then-suspend-then-write is not. Not checked |

Two in-flight effects in A/C may both *send*, and both sends are serialised through `update`. This is
the answer to Q3 of §2.3: hit A's and hit B's toggles run concurrently and their results are applied
one at a time, in arrival order, each to the current model.

### 9.4 Subscriptions

Two designs, and they compose into one:

- **Declared from the model and diffed** (Elm; Iced's `Tracker`). The subscription set is a pure
  function of the model, so "what am I listening to" is derivable and testable, and a subscription
  cannot be forgotten.
- **Fibers in scopes** (`bracket`: acquire = `addEventListener`, release = `removeEventListener`).
  Leak-freedom by construction, and unmount kills everything.

**Use both**: `subscriptions : Model -> Sub Msg` declares a keyed set; the runtime diffs it after
every update, starting a scoped fiber per new key and closing the scope of every departed key. That
is Iced's `retain` with beni's finalisers, and it makes Lustre's leak (§8.3) unrepresentable.

The cost is one thing to decide: a subscription's identity. Iced hashes the recipe; Elm compares the
`Sub` structurally in kernel code. beni should require the key to be `compare`-able and derived, so
`Browser.onResize Resized` and `Browser.every (Duration.seconds 1) Tick` are distinct by value.

### 9.5 Errors, and what a defect does to a page

Ordinary failures are `Result`s matched by an exhaustive `case` (F1, F2). The interesting question is
what A1's "defects are fatal" means where there is no exit code.

| Behaviour | Verdict |
|---|---|
| **Halt the program**: stop dispatching, close the root scope (finalisers run → listeners removed, requests aborted), call a platform `onDefect`, leave the DOM as it is with a marker attribute | **Recommended.** It is A1 transposed: the heap is shared, so nothing below can be trusted, and stopping is the only honest move. Cleanup still happens, which is more than a Node process gets |
| **An error boundary** per subtree, re-rendering a fallback | **Rejected**, on A1's own reasoning: JS fibers share a heap, so containing a defect means continuing on state nobody can vouch for. It is React's answer and it is available to React because React has no such guarantee to keep |
| **Log and continue** | Rejected outright |

Per option: A, B and C halt coherently, because there is one model and one loop. D and E halt
*incoherently* — some components' state is fine, some is not, and the temptation to an error boundary
is strongest exactly where A1's argument is strongest. That is a genuine point in TEA's favour and it
has not been made anywhere.

Two follow-ups the queue already carries (A1: "a boundary check refusing `throw` in a sibling, a
hostile-input suite, a crash reporter") apply unchanged; the browser adds a third — **what the user
sees**. Recommend: the platform's default `onDefect` writes a structured report to `console.error`
and does nothing to the DOM; an application may replace it.

### 9.6 Testing

**Yes, for A and C, deterministically and with no browser**, and this is the strongest practical
argument for them. Three ingredients, all already decided: services are records (F6), so `Api` is
faked with a lambda; the clock is a fiber slot (F9/A13), so 250 ms of debounce costs no wall time;
and the scheduler is a slot, so resumption order is fixed.

```elm
--! [proposed] `Browser.Test` — a TestStore. Runs under the Node platform, in
--! `tests/corpus/run/`, with no DOM.
pub opaque type Test model msg

pub start    : Program model msg, model -> Test model msg
pub send     : Test model msg, msg -> Test model msg
pub advance  : Test model msg, Duration -> Test model msg
pub model    : Test model msg -> model
pub received : Test model msg -> List msg
pub finish   : Test model msg -> Result TestError ()
```

and the test the example was designed for:

```elm
fakeApi : Ref (List String), Result HttpError (List Hit) -> Api
fakeApi calls answer =
    { search =
        \q ->
            let
                () = Ref.update calls (\c -> q :: c)
            in
            answer
    , setFavourite = \_ _ -> Err NetworkError
    }
```

```elm
-- type, type again inside the debounce window, advance, and assert that the
-- FIRST query was never sent.
t0 = Test.start program init0
t1 = Test.send t0 (Typed "a")
t2 = Test.advance t1 (Duration.millis 100)
t3 = Test.send t2 (Typed "ab")
t4 = Test.advance t3 (Duration.millis 300)
-- Ref.get calls == [ "ab" ]      -- one call, not two
-- (Test.model t4).status == Loaded hits
```

Copy TCA's two end-of-test assertions verbatim in spirit
(`tca/Sources/ComposableArchitecture/TestStore.swift:680-691`, `:628-659`):

> `The store received \(count) unexpected action(s).` … and … `An effect returned for this action is
> still running. It must complete before the end of the test.`

Both are exactly the failures a beni corpus fixture wants, and the second is only checkable because
the runtime knows what is in flight — which Elm's does not. `Test.finish` is where they go.

For D and E the same test is harder: there is no message log, so a test asserts cell values or drives
a renderer. That is a cost, not a barrier.

### 9.7 Debuggability

| Facility | A, C | B | D | E |
|---|---|---|---|---|
| message log | free | free | none | none |
| time travel (replay the log through `update`) | yes, while `update` is pure and `sync` | no (effects re-run) | no | no |
| "what is in flight" | **free and new**: the runtime's `Dict Key (Fiber ())` is inspectable by key, which Elm cannot offer | — | per scope | per atom |
| fiber dump | needs `children`/`outcome` on the record (P2 §6.4) — note r21 §8.4: v4 *deleted* its supervision surface, so this is a decision, not a default | | | |

Time travel's precondition is worth stating once: it requires `update` to be pure *and* the `Model`
to be a value with no capability in it (§2.2). Both are true in A and C and in neither D nor E.

### 9.8 Composition at scale

**Message wrapping.** Pipe-first and no currying change the spelling and nothing else:
`Html.map childHtml ToChild`, `Cmd.map childCmd ToChild`, `Sub.map childSub ToChild`.

**Keys must be namespaced by `map`.** This is the open item of `boundary.md` §5.4 and the sharpest
objection to option C (§5.5). TCA's answer is a path registered at every prefix
(`Cancellation.swift:251-260`), which gives two properties at once: siblings never collide, and a
parent can cancel an entire subtree with one call. Recommendation: **`Cmd.map` pushes a segment onto
the command's key path**, the runtime's table is keyed by the path, and `Cmd.cancelAll : k -> Cmd
msg` cancels a prefix. It costs one field on the opaque `Cmd` and it is unavailable later without a
breaking change.

**Child-owned state.** Elm's answer is that the parent owns the child's model and wraps its messages.
Lustre's is a custom element with its own runtime and `CustomEvent`s out (§8.3). beni could offer
either; the second needs no language feature and gives real encapsulation at the cost of a DOM
boundary.

**Heterogeneous pages.** A router over `Page = Home HomeModel | Search SearchModel | …` and a `case`
is the only shape available, because a list of "things with an `update` and a `view`" needs
existential types, which beni does not have. Static dispatch does *not* rescue this: a `where p.update
: p, Msg -> p` clause fixes one `Msg` for every `p`, and there are no associated types to vary it. A
flat `case` is fine for routing and is what Elm does; it should be stated rather than discovered.

**Code splitting.** A route is the natural chunk boundary and `lazy` is parked (C9). Note the
interaction: DCE is reachability-driven from roots (`backend.md` §9), so a lazily-loaded page's
`update` is reachable only through whatever names the chunk — a design M5 owns, and one that a
component or signal library complicates, because their entry points are not a fixed four-function
record.

### 9.9 What each option needs beyond the decided effects design

| Option | Ask |
|---|---|
| A | `sync` in argument position (**decided**, A6). A `view` purity bit if `lazy` ships (§9.1) |
| B | nothing — and that is the warning |
| C | A's, plus a key-path rule for `Cmd.map` (library, not language) |
| D | an invalidation path from a cell to the renderer — a dirty-marking renderer (library) or E's tracking |
| E | **a fiber-local observer slot** restored at every resumption (§7.3) — a runtime/language decision A7 deliberately left out |

### 9.10 The comparison table

| | **A** Cmd-as-data | **B** effectful update | **C** fibers + send | **D** components | **E** signals |
|---|---|---|---|---|---|
| 1. must be `sync` | init/update/view/subs/taggers/handlers | view/subs only | + `Send` | component body, handlers | component body, tracked sources, handlers |
| 2. stale results | cancelled | **raced** | cancelled | cancelled | cancelled |
| 3. model races | impossible (checked) | **lost updates** or a frozen UI | impossible (checked) | possible (unchecked) | possible (unchecked) |
| 4. subscriptions | declared + diffed, scoped fibers | same | same | scope-owned | cell-owned |
| 5. defect | halt coherently | halt coherently | halt coherently | halts incoherently | halts incoherently |
| 6. deterministic headless test | **yes** | partly (nondeterministic by construction) | **yes** | harder | harder |
| 7. message log / time travel | yes / yes | yes / no | yes / yes | no / no | no / no |
| 8. composition | `Html.map` + key paths | same | same | natural | natural |
| 9. needs | `sync` arg position (decided) | — | + key paths | + invalidation | **+ fiber-local observer** |
| 10. rule 7 | restrictions all paid for | no restriction, no guarantee | all paid for | do not forbid, do not bless | do not forbid; unsound until its ask lands |

---

## 10. The layered answer

### 10.1 The kernel

Five things, and nothing else. Everything in §3–§8 is writable on them.

1. **A root scope tied to the mount.** `Browser.mount` opens a `Scope`; unmount closes it; every
   fiber below is interrupted, children first, finalisers run, and the caller waits (F5). This is the
   one guarantee no JavaScript framework can make and beni can.
2. **A `sync`, pure render.** Whatever `view` is — a `Html msg` tree, a DOM builder, a signal-driven
   node — the kernel's entry point demands a function that cannot suspend and (if memoisation is
   offered) cannot be impure (§9.1).
3. **A `sync` event→fiber bridge.** A DOM handler is `sync` so `preventDefault` works; what it
   returns is handed to the architecture. Starting a fiber from a handler is a kernel call, so the
   fiber is always parented in the root scope and can never be orphaned.
4. **Scoped subscriptions.** `bracket`-shaped: an acquire, a release, a scope. Leak-freedom by
   construction; Lustre's `effect.from` listener leak is unrepresentable.
5. **One frame-aware loop.** The kernel owns the render tick and the yield budget (report 26 owns the
   number). Two libraries in one page must not each own a rAF.

### 10.2 What sits on it

**TEA (option C) is the blessed architecture**, shipped in the browser platform package, with A's
`Cmd.run` as a convenience constructor and `boundary.md` §5.4's four policies. A component library
(D) is writable by anyone on kernel items 1, 3 and 4 plus a dirty-marking renderer. An imperative
"just call things and set the DOM" style is writable on items 1–3, which matters more than it sounds:
rule 7's capability-gap clause means a developer who wants to write a small widget without an
architecture should be able to.

### 10.3 Where it breaks

**Option E.** Fine-grained reactivity needs the current-observer to survive a suspension point
(§7.3), which needs a fiber slot restored at every resumption, which A7 declined when it bought three
fixed slots and refused a general `Context`. Without it a signal library is *silently* wrong — reads
after a suspension are untracked and the UI simply stops updating, which is Solid's behaviour today
and is not acceptable under rule 7.

Two smaller breaks, both fixable by saying so early:

- **Rendering phases.** Lustre needed three (`synchronous`, `before_paint`, `after_paint`) for focus,
  measurement and scroll restoration. If the kernel's loop has one phase, a library cannot add
  another. Decide now.
- **Key namespacing** (§9.8) is a `Cmd` representation decision, so it is the blessed library's, but
  if the kernel is what owns the key→fiber table then it is the kernel's. Decide which.

### 10.4 The honest summary of the claim

*"Fix the guarantees, leave the architecture to libraries"* is right, and it is right for the reason
rule 7 gives, but it is not free: a kernel is only architecture-neutral with respect to the
architectures it was designed against. This report designed it against five. The fifth does not fit,
and the fix is one slot.

---

## 11. Decisions this hands the owner

Numbered, with options and a recommendation. The owner decides.

**D1. Is TEA the browser platform's blessed architecture, and is a command a thunk-plus-tagger (A) or
a function handed a `send` (C)?**
Options: (a) A only; (b) C only; (c) C, with A's `run`/`keyed` as definitions over it.
*Recommendation: (c).* `run task tag = perform (\send -> send (tag (task ())))` is four lines, A is
then sugar rather than a rival, and progress/streaming effects become expressible without a `Sub`.
Blocks: `boundary.md` §5.4's rewrite, the `Cmd` type, every example in the platform's docs.
Reversibility: **low** — it is the type of every command in every program.

**D2. What does a defect do to a page?**
Options: (a) halt the program, close the root scope, call `onDefect`, leave the DOM; (b) an error
boundary per subtree; (c) log and continue.
*Recommendation: (a)*, because it is A1's argument unchanged, and because (b) is exactly "continuing
on state nobody can vouch for". Note that (a) is *more* than a Node process gets: finalisers run, so
listeners are removed and requests are aborted. §9.5. Reversibility: medium.

**D3. Does `view` need a purity bit as well as `sync`?**
Options: (a) two bits in argument position, and `lazy` is sound; (b) one bit and no `lazy`/no render
memoisation; (c) one bit, `lazy` offered, and documented as unsound for an impure view.
*Recommendation: (a) if a virtual DOM with `lazy` is planned, (b) otherwise; (c) is a rule-7
violation and should be refused in writing.* This changes the cost estimate in plan §2.5 from one
bool to two. §9.1. Reversibility: **low** — it is in `Interface.Term.Tag`.

**D4. Where does `sync` go on an annotated declaration?**
Options: (a) on the annotation, like `pub`; (b) on the definition, as P2 §3.2's grammar has it;
(c) both, with a diagnostic for a mismatch.
*Recommendation: (a)*, by analogy with `pub_on_definition`, because the annotation is where the type
is and `sync` is part of the type. Cheap now, awkward later. §3.3. Reversibility: medium
(formatter + corpus churn).

**D5. Are command keys namespaced, and by what?**
Options: (a) global keys, callers namespace by convention (today's §5.4 text); (b) `Cmd.map` pushes a
path segment and the table is keyed by the path, with `cancelAll` on a prefix — TCA's design;
(c) keys are `String` only.
*Recommendation: (b)*, with the key type a `compare`-able value and the documented idiom a program's
own `Key` ADT. (a) ships a silent wrong answer at the second reusable component; (c) ships it
immediately. §5.5, §9.8. Reversibility: **low** — it is in `Cmd`'s representation.

**D6. Does the runtime get a general fiber-local, restored at every resumption?**
Options: (a) no — the three fixed slots of A7 and nothing more; (b) a fourth fixed slot for a
"current observer"; (c) a general typed fiber-local (A7's option (c), whose typing is B11's spike).
*Recommendation: (a) for v1, and say in the spec that a fine-grained-reactivity library is therefore
out of reach until (b) or (c).* Do not ship a signal library on (a): Solid's silent untracked read
after an `await` is what that looks like. §7.3, §10.3. Reversibility: high for (a)→(b).

**D7. Do subscriptions stay `subscriptions : Model -> Sub Msg`, declared and diffed?**
Options: (a) yes, diffed by key, each live subscription a scoped fiber; (b) no — subscriptions are
started by commands and cancelled by key, like everything else; (c) Lustre's answer: no `Sub` at all.
*Recommendation: (a).* It keeps "what am I listening to" a pure function of the model, and the scoped
fiber makes the leak unrepresentable. (c) is a measured mistake. §9.4. Reversibility: medium.

**D8. How many rendering phases does the kernel's loop have?**
Options: (a) one; (b) two (synchronous, after-paint); (c) three, Lustre's.
*Recommendation: (b) at minimum*, because focus and measurement are not optional and a library cannot
add a phase the kernel does not have. §10.3. Reversibility: low.

**D9. Is a `TestStore`-shaped driver part of the platform, and is it the corpus's instrument?**
Options: (a) yes, with TCA's two end-of-test assertions; (b) a testing package outside the platform;
(c) no driver — fixtures drive `update` directly and never exercise a command.
*Recommendation: (a).* It is what makes requirement 6 of the running example testable at all, and
(c) means the corpus cannot test cancellation, which is the feature the whole lowering was chosen
for. §9.6. Reversibility: high.

**D10. Is a component/local-state library forbidden, unshipped, or shipped?**
Options: (a) forbidden; (b) not shipped in v1, and the kernel is checked not to exclude it;
(c) shipped alongside TEA.
*Recommendation: (b).* (a) is taste, not a guarantee, and `Ref` is already T0 so the hazard is
already in the box (§6.4). (c) splits the ecosystem before there is one. Reversibility: high.

---

## 12. What a prototype should measure first

Seven experiments, in order. The first two settle the architecture; the rest settle numbers this
report could not.

1. **The typeahead in option C, headless, under a fake clock and a fake `Api`** — the exact sequence
   of §9.6. Success is: one `search` call for two keystrokes inside the window; the stale fiber's
   finaliser observed to run; the rollback asserted from the message log; the whole thing
   deterministic at `--jobs=1` and `--jobs=8` (rule 5). This is simultaneously the architecture
   proof, the `TestStore` design and a `run/` fixture.
2. **Mount, then unmount with a subscription live and a request in flight.** Assert
   `removeEventListener` ran and the request's `AbortController` fired, both from the closing of one
   scope. This is kernel item 1 and it is the guarantee no other framework offers.
3. **`sync update` against a deliberately suspending `update`.** A corpus fixture that must *fail* to
   compile, with the `must_not_suspend` chain naming the path from `update` to `Http.get`. It is the
   §4.3 argument made executable, and it belongs in the corpus before the browser platform exists.
4. **`view` purity and `lazy`.** A `view` that reads a `Ref`, with `lazy` on, in `--release`. If the
   read is skipped, D3 answers itself.
5. **The rAF latency histogram at budgets 16 / 64 / 512 / 2048, in Chrome and Firefox, with a live
   typeahead in the page** — `research/16` §6's missing experiment in its real setting, and B1. This
   is report 26's, and it should use this report's example as the load.
6. **Prompt cancellation in a browser.** Time from keystroke to the previous `fetch`'s `abort`, against
   `research/16` §2.4's 56 ms / 301 ms measured on Node. The claim that sold the lowering has never
   been measured where it is meant to matter.
7. **Two libraries on one kernel**: a TEA app and a `Ref`-based widget mounted in the same page,
   sharing one render loop. It is the only way to find out whether §10's layering survives contact,
   and it is cheap.

Size is measured throughout, not at the end: the empty browser program's floor and the typeahead's
brotli size, development and `--release`, against B9's ≤ 5 kB gzip runtime budget (F10).

---

## 13. Could not determine

- **Anything measured in a browser.** Every figure in `research/16` and `research/21` is from Node.
  Report 26 owns this and nothing in §9 should be read as a performance claim.
- **Whether beni will have a virtual DOM at all.** No document in `docs/design/` specifies one;
  `boundary.md` §5.3 names TEA and stops. §9.1's `view`-purity finding is conditional on that answer,
  and report 24 is the input.
- **Where `sync` is written on an annotated declaration** (D4). P2 §3.2's grammar shows it on the
  definition; nothing states the interaction with an annotation or with `pub`.
- **TCA's clock injection.** `@Dependency(\.continuousClock)`'s `liveValue`/`testValue` wiring lives
  in `swift-clocks`/`swift-dependencies`, which are not in the shallow clone. The *usage* is quoted
  (`tca/Examples/CaseStudies/SwiftUICaseStudiesTests/03-Effects-BasicsTests.swift:64-76`); the
  mechanism was not read.
- **Whether a fiber-local can be typed soundly in beni** — B11 says it needs a spike and this report
  agrees; §7.3 states what it would be used for, not how to type it.
- **Whether Compose forbids suspending composables in the type system.** `Effects.kt` does not say so;
  the constraint lives in the compiler plugin, which was not read. The quoted doc warning
  (`:855-856`) is the closest evidence in the file fetched.
- **The cost of `sync` in argument position as a second bit.** Plan §2.5 priced one bool; D3 asks for
  two and this report did not re-cost it against `TypeStore` or the interface encoding.

---

## 14. Evidence index

**beni, at `master` `657aa7b`.** CLAUDE.md rules 6 and 7 and the *Target* bullet;
`language.md` §0, §3 (grammar, the type comma rule), §6.3 (records and method calls), §6.5, §6.6,
§6.7 (`_`, `|>`, `<-`), *Evaluation order*, Appendix A; `transparent-effects-proposal.md` §1–§9 with
§3.2 (`sync`), §5, §6.2–§6.6 and §9.1–§9.2 load-bearing; `plans/effects-decisions.md` — the answered
block (A1, A5, A6, A7, A8) and tiers A/B/C; `boundary.md` §4 (the four checks), §5, §5.1–§5.4;
`research/17` §5.1 (the seven imposed signatures), §6.1, §6.3; `research/21` §0 (the v4 table),
§8.4; `research/22` §0 (the ten findings), §8 (T0/T1); `research/16` §2.4, §3.4, §3.8, §5.3, §5.5
via P2 and r21; `platforms/node/Node.beni`; `tests/corpus/run/` for syntax.

**External, by clone and commit.**

| Claim | Citation |
|---|---|
| `Effect` is `.none`/`.publisher`/`.run(send)`; `Send` is `@MainActor` and drops on cancel | `tca` `377da40`: `Sources/ComposableArchitecture/Effect.swift:5-24`, `:92-101`, `:180-194` |
| the reducer is synchronous, non-throwing, and not actor-annotated; the store's `Core` is `@MainActor` | `tca`: `Reducer.swift:3`, `:34`; `Core.swift:9-10`, `:114` |
| one unstructured `Task` per action's effect, bookkept by hand | `tca`: `Core.swift:157-198`, `:194-216` |
| `cancelInFlight` is a cancel-then-register swap under one global lock | `tca`: `Effects/Cancellation.swift:163-192`, `:226` |
| a cancellable is registered under **every prefix** of the navigation path | `tca`: `Cancellation.swift:251-260` |
| a dismissed child's whole subtree of effects is cancelled by one `.cancel` | `tca`: `PresentationReducer.swift:486-499`, `:542-554` |
| debounce = `clock.sleep` + `.cancellable(id:cancelInFlight:)`; the operator was deprecated | `tca`: `Internal/Deprecations.swift:367-401`; `Examples/CaseStudies/SwiftUICaseStudies/03-Effects-Basics.swift:51-55` |
| `TestStore`'s unreceived-action and in-flight-effect failures | `tca`: `TestStore.swift:680-691`, `:628-659`, `:930-980` |
| optimistic favouriting with rollback | `tca`: `Examples/…/05-HigherOrderReducers-ReusableFavoriting.swift:44-69` |
| an unhandled thrown error becomes `reportIssue` | `tca`: `Effect.swift:104-133` |
| Lustre's `Effect` is three lists of `Actions -> Nil` | `lustre` `e5ca4d8`: `src/lustre/effect.gleam:96-114`, `:122-165`, `:322-343` |
| synchronous effects run inline in `dispatch`; `before_paint` is a microtask, `after_paint` a rAF | `lustre`: `src/lustre/runtime/client/runtime.ffi.mjs:110-122`, `:259-302`, `:313-345` |
| no cancellation anywhere; the timer example stops by not re-returning the effect | `lustre`: `examples/03-effects/03-timers/src/app.gleam:49-57` |
| staleness handled by tagging the id into the message | `lustre`: `examples/03-effects/01-http-requests/src/app.gleam:89-100`, `:118` |
| listener registration leaks; the context protocol is the one subscribe/unsubscribe pair | `lustre`: `effect.gleam:145-154`, `:293-306`; `runtime.ffi.mjs:165-214` |
| a component is a full TEA instance as a custom element; in via decoders, out via `CustomEvent` | `lustre`: `src/lustre.gleam:304-311`; `component.gleam:118-144`; `runtime.ffi.mjs:124-128` |
| server components reuse `init/update/view` and ship `Mount`/`Reconcile` | `lustre`: `runtime/transport.gleam:13-38`; `server_component.gleam:117-121` |
| a signal read mutates module-global `Listener`/`Owner` | `solid` `b25c557`: `packages/solid/src/reactive/signal.ts:51-59`, `:1302-1339` |
| the tracking context is restored in a `finally`, so an `await` loses it, silently | `solid`: `signal.ts:1402-1427` |
| `createResource` discards a stale response by promise identity; no `AbortController` in the core | `solid`: `signal.ts:649-743`, esp. `:650`, `:727` |
| the owner tree disposes children before its own cleanups | `solid`: `signal.ts:1700-1738`, `:150-185` |
| Leptos's observer is a `thread_local`; `track()` adds both edges | `leptos` `6196370`: `reactive_graph/src/graph/subscriber.rs:7-9`; `traits.rs:110-120` |
| `ScopedFuture` re-installs Owner+Observer on every `poll` | `leptos`: `reactive_graph/src/computed/async_derived/mod.rs:20-30`, `:72-87`; doc example `arc_async_derived.rs:63-70` |
| stale results are dropped by a version counter; the work is not aborted | `leptos`: `arc_async_derived.rs:368-390`, `:686-711` |
| task cancellation exists only tied to owner cleanup | `leptos`: `reactive_graph/src/lib.rs:150-183` |
| an `Atom` and its registry; the dependency edge is added by `get` | `references/effect` `3d59ae6`: `packages/effect/src/unstable/reactivity/Atom.ts:67-77`, `:150-153`; `AtomRegistry.ts:863-871`, `:685-770` |
| invalidation disposes the lifetime, interrupting the previous fiber, before rebuilding | `references/effect`: `Atom.ts:537-604`; `AtomRegistry.ts:741-758`, `:780-812`, `:1012-1023` |
| `AsyncResult` = Initial/Success/Failure + a `waiting` flag | `references/effect`: `AsyncResult.ts:156-158`, `:230-234`, `:268-272` |
| optimistic atoms roll back to the last source value | `references/effect`: `Atom.ts:1918-2070`, esp. `:1957-1988` |
| React reads through `useSyncExternalStore`; suspension is an opt-in hook | `references/effect`: `packages/atom/react/src/Hooks.ts:54-58`, `:371-384` |
| `LaunchedEffect` launches on remember and cancels on forget; a key change is forget+remember | Compose, fetched `https://raw.githubusercontent.com/JetBrains/compose-multiplatform-core/jb-main/compose/runtime/runtime/src/commonMain/kotlin/androidx/compose/runtime/Effects.kt` (2026-09-20): `:492-535`, `:566-569` |
| `DisposableEffect` is acquire/release over the same hooks | Compose `Effects.kt:259-280`, `:335-340` |
| `rememberCoroutineScope` cancels on leaving composition; do not launch from composition | Compose `Effects.kt:802-817`, `:853-872` |
| `takeLatest` is cancel-then-fork; `debounce` is `race(take, delay)` | `saga` `b603028`: `packages/core/src/internal/sagaHelpers/takeLatest.js:13-29`; `debounce.js:21-37` |
| subscriptions are hashed, kept in a map, and unsubscribed by `retain` dropping a cancel channel | `iced` `fa3bae5`: `futures/src/subscription/tracker.rs:69-124` |
| effect handles are held and aborted, including `abort_on_drop` | `iced`: `runtime/src/task.rs:218-234`, `:284-330` |
| Elm's `Http` keys cancellation by tracker string in a kernel-only effect manager | `elm-http` `81b6fdc`: `src/Http.elm:669-671`, `:682-684`, `:973-976`, `:998-1019` |
| `Browser.element`'s record | `references/elm-browser` `1d28cd6`: `src/Browser.elm:104-111` |
