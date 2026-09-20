# The browser platform — the plan

**Status:** plan, 2026-09-20. **Implementation is parked.** Nothing here is started and nothing here
is normative: the normative documents are `boundary.md`, `backend.md` and
[`transparent-effects-proposal.md`](../docs/design/transparent-effects-proposal.md) (**P2**), and §4
below lists the edits this plan would owe them *once the owner answers*
[`plans/browser-decisions.md`](browser-decisions.md).

**How to read it.** Every part is marked with the `W` ids it depends on, so the plan survives the
owner choosing differently. Where a part would simply disappear under another answer, it says so.
Evidence is **R24** ([`research/24`](../docs/design/research/24-elm-browser-runtime.md)), **R25**
([`research/25`](../docs/design/research/25-ui-architecture-design-space.md)) and **R26**
([`research/26`](../docs/design/research/26-browser-host-measured.md)); no number appears without its
source and its caveat.

---

## 1. What a beni browser program is

*Depends on: **W1** (TEA, commands handed a `send`), **W5** (the render phases), **W6**
(subscriptions), **W8** (`sync` handlers), **W9** (`main`). Under a different W1 this page is
rewritten; under a different W5/W6 it loses a line each.*

This is the page that replaces P2 §6.6. It is R25 §2's running example — a search box that debounces,
cancels the stale request, and toggles a favourite optimistically — in its option-C form, trimmed to
one screen, with its test beside it.

**Marking.** `[proposed]` marks an API or a semantics that does not exist: the `Browser` package
whole, `Cmd`/`Send`, `Task.sleep`, `Ref`, and the `sync` keyword (P2 §3.2, decided by A6 but not
built). Everything else is `language.md` as it stands today: calls are saturated, function types are
n-ary, `|>` is pipe-first, `where` sits on a top-level annotation, and at most one `_` appears per
application.

### 1.1 The program

```elm
--! `Typeahead` — a whole beni browser program. [proposed] throughout: the
--! `Browser` package, `Cmd`, `Send`, `Task`, `Duration`, and the `sync`
--! keyword. Three small helpers are elided for space: `statusOf`,
--! `setMember` and `viewStatus`, all pure, all in R25 §2.2.
import Browser exposing (Sub)
import Browser.Cmd as Cmd exposing (Cmd, Send)
import Browser.Html as Html exposing (Html)
import Duration
import Set exposing (Set)
import Task


type alias HitId =
    String


type alias Hit =
    { id : HitId, title : String }


type HttpError
    = Timeout
    | NetworkError
    | BadStatus Int


--| The one service. A7 decided services are records of functions, so this is
--| the whole of this program's dependency injection: `search` and
--| `setFavourite` both PERFORM, so both are inferred `suspends`, and a test
--| passes a record of fakes where the platform passes the real one.
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
    , width : Int
    }


type Msg
    = Typed String
    | GotHits (Result HttpError (List Hit))
    | Favourited HitId Bool
    | Saved HitId Bool (Result HttpError ())
    | Resized Int


--| Keys name work, not values. An ADT and not a `String`: a mistyped string
--| key silently never cancels, which is rule 7's silent-wrong-answer class,
--| and a derived `compare` on this type costs nothing.
type Key
    = SearchKey
    | FavouriteKey HitId


sync init : Api, () -> ( Model, Cmd Msg )
init _ _ =
    ( { query = "", status = Idle, favourites = Set.empty, width = 0 }
    , Cmd.none
    )


sync update : Api, Msg, Model -> ( Model, Cmd Msg )
update api msg model =
    case msg of
        Typed q ->
            ( { model | query = q, status = Loading }
            , Cmd.performKeyed SearchKey Cmd.Restart (searchEffect api q _)
            )

        GotHits result ->
            ( { model | status = statusOf result }, Cmd.none )

        Favourited id want ->
            ( { model | favourites = setMember model.favourites id want }
            , Cmd.performKeyed (FavouriteKey id) Cmd.Restart
                (saveEffect api id want _)
            )

        Saved _ _ (Ok ()) ->
            ( model, Cmd.none )

        Saved id want (Err _) ->
            ( { model | favourites = setMember model.favourites id (not want) }
            , Cmd.none
            )

        Resized w ->
            ( { model | width = w }, Cmd.none )


--| An effect is a fiber handed a `send`. `Task.sleep` is a call, so debounce
--| is a line; the next `Typed` returns a command under the same key with
--| `Restart`, the runtime interrupts this fiber wherever it is parked, its
--| finalisers run (the `fetch`'s `AbortController` fires), and the
--| continuation that would have called `send` no longer exists. The stale
--| response cannot land — not "is ignored": cannot land.
searchEffect : Api, String, Send Msg -> ()
searchEffect api q send =
    let
        () = Task.sleep (Duration.millis 250)
    in
    send (GotHits (api.search q))


saveEffect : Api, HitId, Bool, Send Msg -> ()
saveEffect api id want send =
    send (Saved id want (api.setFavourite id want))


--| Declared from the model and diffed after every message: the runtime starts
--| a scoped fiber for each key that arrived and closes the scope of each key
--| that left, so nobody writes `unsubscribe` and a listener cannot leak.
sync subscriptions : Model -> Sub Msg
subscriptions _ =
    Browser.onResize Resized


--| `view` is `sync` and pure. Every handler is `sync` too: it may call
--| `preventDefault`, and if it wants to do slow work it spawns a fiber and
--| returns (R26 §5.1 — one macrotask hop and the link has already navigated).
sync view : Model -> Html Msg
view model =
    Html.div []
        [ Html.input [ Html.value model.query, Html.onInput Typed ] []
        , viewStatus model
        ]


main : Program
main =
    Browser.element
        { init = \flags -> init realApi flags
        , update = \msg model -> update realApi msg model
        , view = view
        , subscriptions = subscriptions
        }
```

Three notes on the shape, because each is a design decision rather than a style choice.

- **`searchEffect api q _` is a placeholder, not a lambda.** `language.md` §6.7 allows at most one
  `_` per application, and this is the shape it was designed for (R25 §5.2). The two lambdas in
  `main` are the price of the same rule: `update realApi _ _` is `multiple_placeholders`, so a
  service threaded into a two-parameter `update` is written as a lambda — one per entry point, and
  R25 §3.6 is where the no-currying decision first costs a visible keystroke.
- **The `Api` record is not in the `Model`.** A model holding a function has no derived `eq`, which
  costs the `==` a test wants to write, any render memoisation, and a time-travel diff (R25 §2.2).
- **`sync` is written on the annotation**, by analogy with `pub`. Where it goes is W17 and P2 §3.2's
  grammar puts it on the definition; this page assumes the recommendation.

### 1.2 The test, with no browser and no wall clock

*Depends on: **W16** (a `TestStore` in the platform), **A13** (a swappable clock), **A7** (services
are records).*

```elm
--! [proposed] `Browser.Test` and `Ref` (effects T0). Runs under the NODE
--! platform, in `tests/corpus/run/`, with no DOM: the TEA loop is DOM-free.
--! `program` is the record `main` builds, with the fake `Api` threaded in.
fakeApi : Ref (List String) -> Api
fakeApi calls =
    { search =
        \q ->
            let
                () = Ref.update calls (\c -> q :: c)
            in
            Ok [ { id = "1", title = q } ]
    , setFavourite = \_ _ -> Err NetworkError
    }


--| Type, type again inside the debounce window, advance the FAKE clock, and
--| assert the first query was never sent. 250 ms of debounce costs no wall
--| time, and the determinism test can run this at --jobs=1 and --jobs=8.
typeaheadDebounces : Ref (List String) -> Bool
typeaheadDebounces calls =
    let
        t0 = Test.start (program (fakeApi calls))
        t1 = Test.send t0 (Typed "a")
        t2 = Test.advance t1 (Duration.millis 100)
        t3 = Test.send t2 (Typed "ab")
        t4 = Test.advance t3 (Duration.millis 300)
    in
    Ref.get calls == [ "ab" ] && (Test.model t4).status == Loaded [ ... ]
```

Two end-of-test assertions are worth copying verbatim in spirit from TCA (R25 §9.6): *"the store
received N unexpected actions"* and *"an effect returned for this action is still running; it must
complete before the end of the test."* The second is only checkable because the runtime knows what
is in flight — which Elm's does not, and which is the whole reason cancellation is testable here.

---

## 2. The kernel and the layers

*Depends on: **W1**, **W3** (the scheduler), **W5**, **W6**, **W8**, **W10** (how much of the
renderer is beni).*

### 2.1 The kernel — five things, and everything else sits on them

R25 §10.1. The kernel is where the *guarantees* live; the architecture is a library.

1. **A root scope tied to the mount.** `Browser.element` opens a `Scope`; unmount closes it; every
   fiber below is interrupted, children first, finalisers run, and the caller waits (A1). This is the
   one guarantee no JavaScript framework can make.
2. **A `sync`, pure render.** The kernel's entry point demands a function that cannot suspend — and,
   if memoisation is offered, cannot be impure (W4).
3. **A `sync` event→fiber bridge.** A DOM handler is `sync` so `preventDefault` works; starting a
   fiber from a handler is a kernel call, so the fiber is always parented in the root scope and can
   never be orphaned.
4. **Scoped subscriptions**, `bracket`-shaped: acquire is `addEventListener`, release is
   `removeEventListener`, and the scope owns both. Lustre's listener leak is unrepresentable.
5. **One frame-aware loop.** The kernel owns the render tick and the yield budget. Two libraries in
   one page must not each own a `requestAnimationFrame`.

### 2.2 The pieces, and which side of the wall each is on

Rule 6: only a platform package may write `foreign`, so every line in the "JS" column is behind the
wall and is the platform's responsibility. Elm's equivalent is R24 §0.1's table. **Size estimates are
estimates**, derived from R24 §11.3's byte attribution of an `--optimize` Elm counter, and are stated
so W11's measurement can contradict them.

| Piece | Elm's equivalent (R24) | Side | Guarantee it carries | Rough size |
|---|---|---|---|---|
| **Mount + model cell + dispatcher** | `_Platform_initialize` minus the bag machinery (R24 §2.2, §2.5) | **beni**, over a `Ref` | one source of truth; every message applied atomically (W1) | ~80 lines beni |
| **The render loop / animator** | `_Browser_makeAnimator`, 26 lines (R24 §6.9) | **JS** | one render per frame; a render is never caught half-applied | ~40 lines JS |
| **Virtual DOM: node and fact construction** | `VirtualDom.js:54-224`, `organizeFacts` | **beni** | `view` is a pure function returning data | ~150 lines beni |
| **Virtual DOM: the diff** | `_VirtualDom_diff*`, ~450 lines (R24 §6.4, §6.5) | **beni**, W10 | none by itself; it is where the language earns its keep | ~400 lines beni |
| **Virtual DOM: render, patch, keyed reorder** | `_VirtualDom_render`, `applyPatches`, ~500 lines | **JS** | reads batched before writes (R26 §5.5: 1 139× otherwise) | ~350 lines JS |
| **Event registration and dispatch** | `makeCallback`, `applyEvents`, ~107 lines (R24 §6.6) | **JS** + a `sync` beni closure | `preventDefault`/`stopPropagation` work (W8) | ~90 lines JS |
| **XSS sanitisers** | `VirtualDom.js:274-333`, ~60 lines (R24 §6.3) | **JS** (four regexes) | a `view` cannot inject script — a rule-7 guarantee | ~60 lines JS |
| **The fiber kernel and scheduler** | `Scheduler.js`, 195 lines — which has **seven of thirteen** pieces and no yield at all (R24 §3.6) | **JS**, platform-neutral, the browser its first host | structured lifetimes, prompt cancellation, a page that keeps breathing | ~1 260 lines JS (r21 §0.4's estimate) |
| **The browser scheduler slot** | none — Elm has a FIFO with no escape | **JS** | input p90 ≈ the slice (R26 §3.3) | ~30 lines JS (W3) |
| **The command runner**: `Dict Key (Fiber ())`, four policies, key paths | `elm/http`'s effect manager, which only kernel code may write (R25 §3.2, §8.7) | **beni** | keyed cancellation as ordinary library code | ~80 lines beni |
| **Subscriptions**: the declared set, the diff, a scoped fiber per key | `Browser/Events.elm`'s three-way `Dict.merge` (R24 §5.2) | **beni** over a JS registration primitive | a listener nobody wants stops, unwritten (W6) | ~80 lines beni, ~30 JS |
| **Navigation** | `_Browser_application`'s link guard and `popstate` (R24 §7.1) | **JS** for interception, **beni** for the capability record | a single-page app cannot lose a click | ~70 lines JS |
| **`Browser.Dom`** — focus, viewport, `getElement` | `_Browser_withNode`, an rAF before every DOM read (R24 §8.2) | **JS** foreigns + W5's after-render point | a read sees the tree the program just described | ~90 lines JS |
| **Interop** — ports | `Platform.js:332-471` (R24 §9) | **beni** codec, generated; **JS** transport | a malformed payload is a `Result`, not a crash (`boundary.md` §3.1) | B3's, already specified |
| **Defect teardown + screen** | none — Elm wedges silently (R24 §3.5) | **JS** flag + `AbortController`, **beni** report | nothing runs on state nobody can vouch for (W2) | ~40 lines JS |

**How much JavaScript the wall has to hold.** Elm's is ~3–4 k lines. The column above adds up to
roughly **2 000 lines of JavaScript** (of which the fiber kernel is 1 260 and is not browser-specific)
plus **~800 lines of beni**. That is the ambition stated as a number; W11 is the measurement that
tests it.

### 2.3 Can the diff really be written in beni? — honestly

*Depends on: **W10**. This is the plan's most load-bearing feasibility claim.*

R24 §6.4 is the evidence. Elm's diff leans on four things, and beni has two of them.

- **A flat array of patch records built by mutation, each carrying a traversal index.** beni can
  build a `List Patch` functionally instead; the JS patcher walks it. Cost: one allocation per patch
  and one crossing per patch instead of one array. Fine.
- **`__descendantsCount` maintained at construction**, which lets the patcher skip whole subtrees of
  real DOM. Trivially expressible as a field on a beni node; it is computed at construction anyway.
- **A reference-equality short-circuit: `if (x === y) return;`** — which makes an unchanged subtree
  free whenever the view function happened to share it. **beni has no reference equality.** `==` is a
  structural, derived `eq`, which on a big tree is O(n) and therefore worse than the diff it is
  trying to avoid. The honest options are: give it up (the diff is then always proportional to the
  view, which is what it is anyway for a view that allocates a fresh tree), or bless a platform
  `foreign refEq : a, a -> Bool` — which is the same reference-identity promise W4 says `lazy`
  needs, arriving by a different door.
- **A structural comparison of two event decoders** (`_Json_equality`), so an inline decoder in a
  view does not cause a listener to be re-added. beni cannot compare two closures at all. **But Elm's
  own mechanism does not need it**: the listener registered with the DOM is a *stable* JS callback
  whose handler lives in a mutable field, so a fresh handler every frame causes **zero**
  add/remove pairs, and only a change of handler *variant* re-registers, because the variant decides
  the `passive` flag (R24 §6.6). So beni adopts the same design and drops the decoder comparison
  entirely — provided the node representation carries the handler's variant as **data** beside the
  closure (`Normal` / `MayStopPropagation` / `MayPreventDefault` / `Custom`).

**Verdict: feasible, with one named loss** (the shared-subtree short-circuit) that W4's answer can
buy back. What is *not* known is whether a diff written in beni is fast enough on a realistic tree,
because **nobody has measured a diff on a realistic tree at all** — R24 §12 says so explicitly, and
its only timing is 2 940 ns for a synchronous render of a three-node view.

### 2.4 The render loop contract

*Depends on: **W5**.*

1. **One render per frame.** N messages between frames cost N model writes and one
   `requestAnimationFrame`. Measured in Elm: five messages in one synchronous loop → one DOM update,
   on the next frame (R24 §6.9).
2. **An explicit "render now",** for the case Elm documents: a `<input type="text">` holds its own
   state, and a fast typist outruns the frame. Elm reaches this by an unrelated-looking API choice —
   `// stopPropagation implies isSync` (R24 §6.6) — and beni decides the two separately.
3. **One after-render suspension point.** `Browser.afterRender ()` parks until the pending view has
   been applied, so `afterRender (); Dom.focus "search"` is the sequencing written down instead of
   hidden. Better than Elm in one way: Elm's `_Browser_withNode` costs a frame *unconditionally*,
   even when the node has existed for minutes (R24 §8.2), where `afterRender` can return immediately
   when nothing is pending.
4. **The patch pass batches reads before writes**, and nothing in it may suspend. R26 §5.4: a rAF
   callback that hopped one macrotask resumed 10.1 ms later and its write landed in the *next*
   frame. R26 §5.5: interleaved read/write over 3 000 nodes cost **2 846 ms against 2.5 ms** batched.
5. **The frame budget is real.** R26 §5.6, headless Chrome: 4.7 ms of work per frame is free, 18.6 ms
   costs a frame, 55.8 ms costs four. That is the measured basis for W3's ~5 ms slice ceiling. (No
   display, no vsync, so frame *jitter* is not represented — R26 §1.4.)

### 2.5 One obligation the reports have separately and nobody joined

*Depends on: **W1**. This is a design obligation, not a question.*

`Send msg` is `sync (msg -> ())` and re-enters the dispatcher synchronously. So a fiber's `send`
calls `update`, which may return a command that spawns a fiber, which may send again — **inside the
first send**. Elm has exactly this hazard and guards it with a queued dispatch and a nineteen-line
comment naming three issue numbers (R24 §2.4), and R24 says in terms that *"beni's fiber runtime has
the same class of problem"*. It is the same class as the re-entrant interrupt the effects spike
already owns (`plans/effects-spike.md` S6, r21 §0.3 item 1). **The dispatcher needs a drain flag or a
queue, specified before it is written, with a fixture.**

### 2.6 Interop, navigation and the defect screen, in one paragraph each

- **Interop** is `boundary.md` §3.1's ports, already specified and already better than Elm's: a codec
  generated from the declared type, a depth bound, and a decode failure **as a value** where Elm's is
  `__Debug_crash` (R24 §0.2 item 8, §9.4). The distinction to keep in the spec: a bad payload is
  malformed input from *outside* the wall, which is what a `Result` is for, and not a defect in A1's
  sense. What is new is the *other* direction — a `foreign` that holds a beni closure and calls it
  from a listener — which is W8 and a gap in `boundary.md` §4.
- **Navigation** is a capability record (A7), not Elm's opaque `Key` phantom: `nav.pushUrl url`,
  where `nav` came from the platform, which is the same unforgeability and is additionally testable
  with a fake (R24 §7.3). Preserve Elm's asymmetry: `load` and `reload` take no capability, because a
  full page load cannot desynchronise a router that is about to be destroyed. The link-click guard is
  a browser fact and copies across unchanged: no modifier keys, primary button, no `target`, no
  `download`, then `preventDefault` (R24 §7.1).
- **The defect screen** is W2's (b)+(c): a `dead` flag the scheduler and every listener test, a
  single `AbortController` that removes every listener the platform installed (R26 §6.3), the root
  scope closed so finalisers run and requests abort, and — **in development builds only** — a report
  written into the root. It is `plans/queue.md` row 54 (the crash reporter) with a browser half.

---

## 3. Order of work — the slices

Each slice: goal · what it proves · its black-box test kind · what it needs from the effects spike
(`plans/effects-spike.md`'s S0…) · exit criterion. **Three of them and the whole output track need
nothing from effects at all**, which is the single most useful fact in this section.

| # | Slice | Needs from effects | Depends on |
|---|---|---|---|
| **B0** | The browser test harness as a corpus kind | **none** | — |
| **B1** | Platform package skeleton, `main` for a page, a static render | **none** | B0 |
| **B2** | The virtual DOM and events with `sync` handlers | **S2 + S3** (the bits, then `sync`) | B1, W8, W10 |
| **B3** | The TEA loop with a pure `update`, no effects | **S3** | B2, W1 |
| **B4** | The fiber kernel hosted on `MessageChannel`, with the slice rule | **S4, S5, S6, S11** | B3, W3 |
| **B5** | Commands as fibers with `send`, keyed scopes, cancellation | **S6, S7, S8, S10, S11** | B4, W1, W7 |
| **B6** | Subscriptions | **S8** | B5, W6 |
| **B7** | Navigation | none beyond B5 | B5 |
| **B8** | Interop (ports) | none | boundary milestone B3 |
| **B9** | The defect screen and crash reporter | **S9** | B4, W2 |
| **O1** | The single-file `--release` bundle | **none** | — |
| **O2** | Minifying sibling JavaScript | **none** | O1, W14 |
| **O3** | Source maps | **none** (but S4's lowering must not foreclose them) | — |

**B0 — the browser test harness as a corpus kind.** *Needs no effects work, no platform and no
compiler change.*
- *Goal.* A `tests/corpus/browser/` kind driven by one long-lived headless Chrome, a fresh `Target`
  per fixture, up to 8 in flight, with CDP virtual time on by default for any fixture that mentions
  time.
- *What it proves.* That a browser kind is affordable, and that the determinism rule (rule 5)
  survives it: a fixture's observable output is the page's text, its console stream and a
  platform-defined exit global, all byte-comparable at `--jobs=1` and `--jobs=8`.
- *Test kind.* It **is** the test kind. The bring-up fixture is a static ES-module page.
- *Exit.* **≤ +2 % of `zig build test-blackbox`.** R26 §9.1 measured 10.0 ms per fixture at 8-way
  parallelism, against a gate of 1 m 50 s for 668 fixtures; 125 browser fixtures cost 1.3 s, +1.2 %
  (§9.4). Process reuse is worth **15×** (272 → 18.5 ms) and is the single decision that matters.
- *What happens with no Chrome.* **Skip loudly, never silently pass.** The harness reports the kind
  as skipped with the reason and a non-zero count in the summary; a green gate that silently ran zero
  browser fixtures is precisely the failure CLAUDE.md rule 3 warns about. The DOM emulators are not
  an answer: `jsdom` and `happy-dom` are 13–28× more expensive per fixture **and neither has
  `MessageChannel`** — the exact primitive W3 builds the scheduler on (R26 §9.2).
- *Also settles.* W15 (virtual time: five chained 10-second timers, 50 000 ms, in **0.9 ms** of real
  time — R26 §9.3), and W9's exit-code convention.

**B1 — the platform package, `main` for a page, and a static render.** *Needs no effects work.*
- *Goal.* `platforms/browser/` with a `beni.json` declaring `program` and `runtime`
  (`boundary.md` §5.2), a `Program` that is a mount descriptor, and a `view` with no events rendered
  once into a root node.
- *What it proves.* That the artifact shape, the `runtime` hand-off and `main : Program` need no
  compiler change — exactly as R26 §8.1 found when it loaded a Node-built program in a browser by
  replacing **one** file, the five-line `runtime.foreign.mjs` stub, and every other sibling needed no
  change at all.
- *Test kind.* `tests/corpus/browser/` — the page's text after mount.
- *Exit.* The empty mounted page's floor measured, dev and `--release`, into `bench/size.mjs`. It is
  the first half of W11; today's runtime-free floor is 2 147 B raw / 833 brotli.

**B2 — the virtual DOM and events.** *Needs **S2** (the two bits) and **S3** (`sync`).*
- *Goal.* §2.2's renderer: node construction and the diff in beni, render/patch/events/XSS in
  JavaScript, handlers `sync` and carrying a variant.
- *What it proves.* W10's feasibility claim, and W8's registration rule end to end.
- *Test kind.* `browser/` for behaviour (a keyed list reordered, a controlled input, a
  `preventDefault`ed link that does **not** navigate) plus `emit/` for shape. A `check/bad/` fixture
  for a handler that suspends — which is S3's diagnostic seen from the platform side.
- *Exit.* The counter's bytes, dev and `--release`, against R24 §11.3's Elm decomposition (Elm's
  virtual DOM is 29 782 B, 27.2 % of a counter); and a diff-cost number on a tree with hundreds of
  nodes, which **nobody has ever measured** (R24 §12) so there is no figure to beat — record it as
  the first.

**B3 — the TEA loop with a pure `update`.** *Needs **S3**.*
- *Goal.* `Browser.element` with `init`/`update`/`view`, no commands, no subscriptions; the model
  cell, the dispatcher with §2.5's re-entrancy guard, and the animator.
- *What it proves.* R24 §6.9's frame contract holds in beni: N messages between frames produce one
  render.
- *Test kind.* `browser/`, plus a DOM-free `run/` fixture under Node driving the same loop — R26
  §9.1 measures a plain node process at 26 ms per fixture, which is where a fast inner loop lives.
- *Exit.* Five messages in one turn produce one DOM mutation; the render-now path produces five.

**B4 — the fiber kernel on `MessageChannel`.** *Needs **S4** (the lowering), **S5** (the kernel),
**S6** (interruption), **S11** (the scheduler slot).*
- *Goal.* The kernel of `plans/effects-spike.md` S5 hosted in the browser, with W3's rule: count 256
  ops, read `Date.now()`, yield through `MessageChannel` on a 1 ms slice.
- *What it proves.* **R26's numbers with a real beni fiber.** R26 could only use a 465 ns stand-in
  work unit and says every op-count figure must be re-derived once a beni fiber exists (R26 §12 item
  8). This is `plans/effects-spike.md` E-M10's browser half, closed.
- *Test kind.* `bench/fiber/` plus a `browser/` fixture that runs a long computation while injected
  input arrives.
- *Exit.* Input p90 **≤ 2 ms** at the chosen slice (R26 §3.3 measured p90 = 1 ms at every slice
  ≤ 0.5 ms and 2 ms at 1.95 ms); yield overhead **≤ 1.02×** against an interleaved no-yield baseline
  (R26 §3.4); zero `longtask` entries. And the negative control: the microtask variant must reproduce
  R26 §3.2's catastrophe, or the harness is not measuring what it thinks.

**B5 — commands as fibers, keyed scopes, cancellation.** *Needs **S6**, **S7**, **S8**, **S10**,
**S11**.*
- *Goal.* §1.1's `Cmd`: `perform`, `performKeyed`, `cancel`, the four policies of `boundary.md` §5.4,
  key paths pushed by `Cmd.map` (W7), and `Send` as a plain `sync` function so a test can fake it
  with one lambda.
- *What it proves.* The whole architecture. It is R25 §12's first prototype experiment and R25 §9.6's
  test in one.
- *Test kind.* `run/` under Node with a fake clock and a fake `Api` — the typeahead of §1.2 — **and**
  a `browser/` fixture that mounts, starts a request, unmounts, and asserts the listener was removed
  and the request aborted from the closing of **one** scope.
- *Exit.* One `search` call for two keystrokes inside the debounce window; the stale fiber's
  finaliser observed to run; deterministic at `--jobs=1` and `--jobs=8`. And cancellation latency in
  a page: R26 §6.1 measured the owned-continuation path at **50 ms against native `async` +
  `AbortController`'s 301 ms** in Chrome, so **≤ 60 ms** is the bar (the same one E-M7 sets on Node).

**B6 — subscriptions.** *Needs **S8** (scopes and `bracket`).* `subscriptions : Model -> Sub Msg`,
diffed by key after every message, one scoped fiber per live key. *Proves* W6's leak-freedom.
*Test:* `browser/` — a subscription that the model stops wanting, with the listener's removal
asserted. *Exit:* no `removeEventListener` appears in user code anywhere in the corpus.

**B7 — navigation.** *Needs nothing beyond B5.* Link interception, `popstate`, and the capability
record. *Proves* that A7's services express Elm's `Key` better than Elm does (R24 §7.3). *Test:*
`browser/` — a click on an internal `<a>` that does not leave the page, and one on an external
one that does. *Exit:* R24 §7.1's guard reproduced, modifier keys and `download` included.

**B8 — interop.** *Needs nothing from effects.* `boundary.md` milestone B3's ports, in a page.
*Proves* that the codec and the depth bound work identically on both platforms. *Test:* `browser/`
with a hostile-payload fixture (queue row 53's suite, browser half).

**B9 — the defect screen.** *Needs **S9** (the failure value and its renderer).* W2's (a)+(b)+(c).
*Proves* that "fatal" exists in a page at all — R26 §7.1 measured that the browser gives you nothing
to be fatal with. *Test:* `browser/bad/`-shaped: a program that defects, with the expected report and
the expected exit global. *Exit:* after a defect, no further fiber resumes, no listener fires, and
the `AbortController` has fired — verified in the page.

### The output track, which is independent of all of the above

**O1 — the single-file `--release` bundle.** *No dependency on anything in this plan or in effects.*
`backend.md` §10 already specifies it and states that *"with one entry point and no `lazy`, a release
build is exactly one file"* — the degenerate case needs no colouring lattice, no merge pass, no
threshold and none of §10's PENDING decisions. *Exit:* §10's acceptance criterion 1
(`split_brotli_bytes == brotli_bytes`), every `emit/` and dev golden byte-identical, and R26 §8.2's
**3.0× to `main` on 4G** reproduced. *Caveat to carry:* that figure is HTTP/1.1; over HTTP/2 the
`modulepreload` alternative improves and the bundle row does not, so the true multiple is somewhere
between 3.0× and the compression-only ratio (R26 §12 item 5).

**O2 — minifying sibling JavaScript.** *Depends on **W14**, and it is the open one.* Sibling
`.foreign.mjs` files are **71.6 %** of `Dictionaries`' raw bytes and whole-line comments are 42 % of
the tree; bundling with minification takes it 6 380 → **3 269** brotli (R26 §8.3). **What
minification must preserve, and whose job it is:** `boundary.md` §4's checks read the sibling's
*source text* — check 2 counts its exports, check 3 classifies its identifiers lexically, check 4
counts the parameter list **at the export** and §4 says in terms that the accepted export *forms* are
part of the contract. So a minifier that rewrites `export function f(a, b)` into a different form
breaks check 4. Two ways out: **(a) a platform-build job** — the platform ships its siblings already
minified and the checks run against what it shipped, which keeps the compiler out of it entirely and
is consistent with rule 6; or **(b) a compiler job** run *after* the four checks have passed, on the
copy being written, never on the copy being read. (a) is simpler and is probably right; (b) is what
gets `core/`'s own siblings, which the platform does not own. Either way it collides with W2: a
minified `core/` makes a defect report point into text nobody can read.

**O3 — source maps.** `--source-maps` is refused today and debugging emitted JavaScript in browser
devtools without them is poor; the browser-first decision moves it up (`plans/queue.md`). Nothing in
this plan blocks it, and `plans/effects-spike.md` §1.3 already requires that S4's lowering not
foreclose it.

---

## 4. What changes elsewhere

Owed **once the owner answers**, one line each. Rule 2: no section is renumbered anywhere.

| File | Section | Edit |
|---|---|---|
| `transparent-effects-proposal.md` | §6.6 | Replaced: the one-claim TEA page becomes a pointer to the browser platform spec and to §1 of this plan (W1) |
| `transparent-effects-proposal.md` | §7.5 | The microtask tier is **withdrawn** for the browser; one tier, a macrotask every slice; the 64 becomes a slice in milliseconds in the scheduler slot (W3, R26 §3.2, §3.4) |
| `boundary.md` | §5 | `main`'s browser meaning: a mount descriptor, keep-alive stated as Node-only, and what replaces the exit code (W9) |
| `boundary.md` | §5.3 | The one-line "Browser: The Elm Architecture" entry gains the command shape, the renderer and the defect behaviour |
| `boundary.md` | §5.4 | Rewritten: `perform`/`performKeyed` beside `run`/`keyed`; keys are `compare`-able, **not** "equatable"; `Cmd.map` pushes a key-path segment; the four policies kept; the "Open" paragraph closed (W1, W7) |
| `boundary.md` | §4 | A rule for a `foreign` that receives a beni function and calls it back: that parameter must be declared `sync`, checked the way check 4 is checked — by counting what is declared, not by parsing JavaScript (W8) |
| `boundary.md` | §7.1 | *"roughly 45 %"* corrected: **71.9–75.9 %** of a small Elm program is hand-written runtime, and the user's own code is under 1 % (R24 §11.2) |
| `boundary.md` | §8 | Milestone **B4** (the browser platform) expands into B0–B9 above; B3 (ports) stays its prerequisite |
| `backend.md` | §10 | The degenerate single-file case gains R26 §8.2's latency number and moves ahead of chunking (W13) |
| `backend.md` | §9 | If W14 is answered yes, a sentence on sibling minification and where it sits relative to `boundary.md` §4's checks |
| `plans/effects-spike.md` | §1.3 | *"The Elm Architecture… out of scope"* reversed; it is the central question and `plans/browser-decisions.md` is its answer |
| `plans/effects-spike.md` | §0.3, S5 | The kernel is platform-neutral with the **browser** as first host, not `platforms/node/` |
| `plans/effects-spike.md` | S11, E-M10 | The browser half of the budget sweep is **done** (R26 §0.1, §3), except for a re-take with a real beni fiber, which becomes B4's exit criterion |
| `plans/effects-decisions.md` | A1, A8, B1, C9 | A browser paragraph each: what "fatal" means in a page; `main`/keep-alive/exit in a page; the budget answer; `lazy`'s un-parking price |
| `plans/effects-plan.md` | §2.5 | If W4 is (a), the one-bool budget for an argument-position demand becomes two |
| `language.md` | §6 | Only if W4 is (a): a reference-identity guarantee, which constrains every future optimiser pass (R24 §6.8). And the `sync`-on-annotation spelling if W17 says so |
| `checker.md` | §7 | Only if W4 is (a): a second `Interface.Term.Tag` value and obligation kind |
| `fast-compiler.md` | §13 | The build order: O1 ahead of chunking; B0–B9 interleaved with the effects spike as §6 below proposes |
| `plans/queue.md` | rows 51–55 | Row 54 (the crash reporter) acquires W2 and becomes the defect screen; 52–53 gain a browser column; the browser-first section gains B0–B9 |

---

## 5. Risks and unknowns, ranked

Each is carried from a report's own *could not determine*, with the cheapest experiment that retires
it.

1. **No real beni fiber has ever been measured in a browser.** Every §3 and §4 figure in R26 comes
   from a 40-line micro-kernel with a 465 ns stand-in work unit (R26 §12 item 8). Every op-count
   number in W3's recommendation has to be re-derived. *Cheapest retirement:* B4, which is why B4's
   exit criterion is "re-take R26's table".
2. **The diff's cost on a realistic tree is unmeasured, by anyone.** R24 §12 says so; its only figure
   is 2 940 ns for a synchronous render of a **three-node** view. The whole "write the diff in beni"
   ambition rests on an unmeasured quantity. *Cheapest retirement:* a standalone prototype before
   B2 — build a 500-node tree in beni and in hand-written JavaScript, diff both, compare. It needs no
   compiler change and no platform.
3. **Whether a 1 ms slice survives a real page.** Every R26 measurement is a blank page with one
   fiber; a page with a patch pass, CSS animations and a compositor may not give the thread back at
   the same cadence (R26 §12 item 9). *Cheapest retirement:* B5's typeahead fixture with the input
   histogram switched on — R25 §12 experiment 5 asked for exactly this, with a live typeahead as the
   load.
4. **Safari is entirely unmeasured**, and `scheduler.postTask`/`yield` are not in WebKit (R26 §12
   item 1). *Cheapest retirement:* run R26's `postsrv.mjs`/`xengine.mjs` POST-back harness — which
   needs no devtools protocol, which is how the Firefox columns exist — on any machine with Safari.
5. **Input latency is Chrome-only**; there is no Firefox input injection without WebDriver BiDi
   (R26 §12 item 7). *Cheapest retirement:* the same harness plus a BiDi client, or accept it and
   say so in the spec.
6. **The loading numbers are HTTP/1.1.** Over HTTP/2 the `modulepreload` row improves and the bundle
   row does not, so 3.0× is an upper bound on the *gap* (R26 §12 item 5). *Cheapest retirement:* one
   HTTP/2 server in R26's `e8-load.mjs`; a morning's work, and it changes O1's justification only in
   degree.
7. **`isInputPending`'s 45× is one measurement on a contaminated machine** (R26 §4.2's overhead
   column was taken at load 0.39–0.55 and says so). *Cheapest retirement:* B4, on a quiet machine.
8. **Hydration was never tested against real server-rendered markup.** Elm's `virtualize` maps every
   attribute to an `ATTR` fact and ignores anything that is not an element or text; whether that
   produces a clean first diff is unknown (R24 §12). *Cheapest retirement:* none needed until W22 is
   asked; the insurance is to keep "build a tree from existing DOM" separable in B2's design.
9. **Clipboard and fullscreen activation gating** could not be measured headless (R26 §12 item 4), so
   the platform must not make a claim about them.
10. **Elm's keyed diff may have pathological cases** beyond its one-element lookahead; the `break`
    path was never benchmarked (R24 §12). It matters only if beni copies the algorithm, which B2
    would. *Cheapest retirement:* fold a reversal and a rotation-by-two into B2's diff benchmark.

---

## 6. A proposed sequence across the whole project

*Given browser-first, and with implementation parked until the owner says otherwise. This is a
recommendation; the owner decides.*

| Phase | Work | Depends on | Why here |
|---|---|---|---|
| **0** | **O1 — the single-file `--release` bundle** | nothing | Unblocked by every open decision; on `master`, not a branch; the largest measured payoff per unit of work anywhere in this plan |
| **0** | Answer `plans/browser-decisions.md` tier 1 (W1–W9) | — | Nothing below B2 can be specified without W1, W5 and W8 |
| **0** | **B0 — the browser corpus kind** | Chrome | The asset every later browser slice needs; +1.2 % of the gate |
| **0** | The diff prototype (risk 2) | nothing | Retires the plan's one unmeasured feasibility claim for a day's work |
| **1** | **B1** — the platform skeleton and a static render | B0 | Proves the artifact shape needs no compiler change |
| **1** | Effects **S0 + S1** — baselines, and the kernel probe | M4-3 (landed) | Still the riskiest unknown in the project: if compiled closure-CPS does not beat 82 ns/op, the whole lowering reopens, and eleven more slices should not be spent first |
| **2** | Effects **S2 + S3** — the two bits, then `sync` | S1 | `sync` is what B2 and B3 need, and it is independently adoptable (`plans/effects-spike.md` §1.2 option (b)) |
| **2** | **B2 + B3** — the renderer, events, the TEA loop | S3 | A working, effect-free beni UI. This is the first point at which someone can write an application |
| **3** | Effects **S4–S11** — the lowering and the kernel | S3 | Unchanged from the effects plan, with S5 re-aimed at a platform-neutral kernel and S11's sweep taking R26's browser answer as its input |
| **3** | **B4 + B5** — the kernel in a page, then commands | S11, S10 | B4 re-takes R26's numbers; B5 is the architecture proof and the typeahead fixture |
| **4** | **B6 + B7 + B9**, effects **S12–S15** | B5, S11 | Subscriptions, navigation, the defect screen, T0/T1 and the spike's report |
| **4** | **O2 + O3** — sibling minification, source maps | W14 | Both are size/debuggability, both wait for a decision rather than for work |
| **5** | **M4-4, M4-5** (the daemon), **B8** (ports), chunking | — | The daemon is what makes the compiler fast to *use*; it has been overtaken by browser-first and should be said so out loud rather than left implicitly next. Queue row 55's two honest M4-3 misses live here |

**The recommended first un-parked implementation slice: O1, the single-file `--release` bundle.**
Four reasons, in order of weight.

1. **It is unblocked by every question on the decision sheet.** It needs no W answer, no effects
   slice, no platform and no new corpus kind.
2. **It has the largest measured payoff of anything in the plan**: 358 ms to `main` against 1 059 ms
   on 4G, 1 156 against 3 437 on fast 3G — 3.0× both times (R26 §8.2) — for a change `backend.md`
   §10 has already specified down to the acceptance criteria.
3. **It makes every later browser measurement real.** W11's size budget, B1's floor and B2's counter
   are all judged on what a browser actually downloads, and today that is thirteen files with
   unminified comments in them.
4. **It lands on `master`, not on a branch**, so it does not compete with the effects spike for the
   one-builder-at-a-time constraint and it cannot be stranded by an adoption decision.

The runner-up is **B0**, and the honest argument for putting it first instead is rule 3: the harness
is the asset, and a browser platform with no way to test it is the thing the project has repeatedly
been burned by. The argument against is that B0 tests nothing until B1 exists, and B1 needs W1. Doing
O1 first costs B0 nothing, because they touch different files.

**What should *not* be first: the effects spike.** Not because it is less valuable — S1's question is
the riskiest in the project — but because it is a branch that runs for days, it needs the owner's
remaining tier-A answers (A4, A9, A12–A16) before S0, and browser-first has just changed where its
kernel lands (S5) and what its scheduler defaults to (S11). It should start when those are folded in,
which is one docs pass away.
