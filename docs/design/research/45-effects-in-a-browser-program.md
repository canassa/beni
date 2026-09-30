# Effects in a browser program: commands, subscriptions and the after-render queue

**Commissioned** 2026-09-30, after the fiber runtime spike landed
([`transparent-effects-proposal.md`](../transparent-effects-proposal.md) §16, **P2** below;
[research 44](44-effects-runtime-spike.md)). The question: how does a beni **browser** program
perform effects, now that beni has transparent effects — an inferred `suspends` bit, a `sync` check,
and a fiber runtime with structured concurrency and prompt interruption — and no `Task` monad? This
is a **design proposal**. It specifies nothing and changes no code; what it recommends becomes
normative only through the decision rows it adds to
[`plans/browser-decisions.md`](../../../plans/browser-decisions.md) (**W46–W55**) and a later spec
pass (CLAUDE.md rule 1).

**What it builds on and does not reopen.** W25 (TEA is the architecture; a command is a function
handed a `send`, with a thunk form over it), W6 (subscriptions declared from the model and diffed,
each a scoped fiber), W7 (command keys namespaced by `Cmd.map`, `compare`-able), W8 (host callbacks
are `sync`), W9 and its mounting rule, W28 (Solid 2's microtask flush, an explicit `flush`, and
after-render work that is `sync` and runs after the patch), and the effects decisions A1 (defects are
fatal, `Exit a = Done a | Cancelled`), A7 (services are records of functions plus three fixed
per-fiber slots), A13 (a swappable clock and scheduler). [Research 25](25-ui-architecture-design-space.md)
(**R25**) argued the architecture before effects existed; this report redoes the parts that change
now that the runtime is built and measured, and fills in what R25 and the decision sheet left open.

**Citations.** `effect:` is `references/effect/packages/effect/src/` at `4.0.0-rc.116`; `solid:` is
`references/solid/packages/signals/src/` at `2.0.0-rc.9`; `elm-browser:` is `references/elm-browser/src/`;
`roc:` is `references/roc/`. Every line cited was read for this report. **R24–R30, R43, R44** are this
directory's reports 24–30, 43 and 44.

---

## 0. Findings

1. **Keep `update` pure and `sync`, and make the command an inert work order whose body is ordinary
   direct-style beni.** `update : msg, model -> ( model, Cmd msg )` returns a value that *names* work
   (a body, a key, a policy); the runtime runs each body in its own fiber. The body is not a monad:
   `Cmd` has no `andThen`, and everything sequential happens inside the body as plain calls that the
   checker infers `suspends`. This is W25(c) made concrete against the runtime as built (option A,
   §2–§3), and it is the recommendation.
2. **The alternative worth taking seriously — `update` spawns fibers itself through a capability
   (option B) — works, and loses exactly one thing that matters:** `update`'s output stops being data.
   Replay, "assert what this message asked for" and "compute an update and throw it away" all go.
   It saves one tuple per message, which §7 prices at nanoseconds. Not recommended.
3. **Option C — work as a pure function of the model, SwiftUI's `.task(id:)` — is not a separate
   mechanism in the recommended design, it is a subscription.** Once a subscription's body is an
   arbitrary fiber (finding 5), "fetch while the model says so, restart when the key changes" is
   `Sub.listen (Fetch q) …`. It is the right tool for state-shaped work and the wrong one for a
   click-shaped one-shot (a POST), so it complements `Cmd` rather than replacing it (§2.3).
4. **Every cancellation policy is five lines of fiber code over the runtime as built**, not a runtime
   feature. `Restart` is "spawn the new body, which first `Task.cancel`s the old one" — so the new
   request starts only after the old one's `fetch` has been aborted and its finalisers have run, which
   is A1/A10's "the interrupter waits for cleanup" with nothing added. `Queue` waits on the previous
   fiber, `Ignore` checks it, `Concurrent` does neither. Debounce is `Restart` plus a `sleep` at the
   top of the body; throttle is `Ignore` plus a `sleep` at the bottom (§3.5).
5. **A subscription is a keyed, long-lived fiber, and the key is the resource's whole identity.**
   Elm's own `Browser.Events` does exactly this: the listener is keyed by node and event name, and
   each event is routed through the taggers of the *current* subscription list, so a tagger that
   changes never restarts the listener (`elm-browser:Browser/Events.elm:289-300`, `:304-321`).
   Copying that — the body runs once per live key, every declaration of that key receives each event
   through its own latest tagger — makes `Sub.listen` a single general primitive, and `Time.every`,
   `Browser.onResize`, a WebSocket and "visible only" are beni library code over it (§3.4).
6. **W7's answer is not implementable as written.** "`Cmd.map` pushes a path segment" needs a value
   to push, and the tagger is a closure: a new one is built on every `update`, so it cannot identify
   an instance from one message to the next. The segment has to be written: `Cmd.map : Cmd a, k,
   (a -> msg) -> Cmd msg` (§3.3, W47). Subscriptions need no segment — two instances listening to the
   same clock share one timer, which is what Elm does and what they want.
7. **After-render work is a command whose body is `sync`, and DOM capabilities are plain `impure`
   functions that return a `Result`.** `Cmd.afterRender body` queues `body` into §15.11's phase (2);
   `Dom.focus`, `Dom.box` and `Dom.scrollTo` are `foreign impure`, not `suspends` as research 17 §4.7
   projected, because under W28 the runtime supplies the moment and the function no longer has to
   wait for it. A fiber that wants that moment calls `Dom.rendered ()`, which suspends until the
   current flush's after-render phase — and returns at once when nothing is pending, which is the
   one place beni beats Elm's unconditional `requestAnimationFrame` per DOM read
   (`elm-browser:Elm/Kernel/Browser.js:293-305`) (§3.6).
8. **The `sync` check needs nothing new for any of this.** `update`, `view`, `init` and
   `subscriptions` inherit their demands from `Browser`'s `foreign` declarations through summaries
   (P2 §15.3); a command body and a subscription body are functions *stored* in data and called by a
   fiber, so they may suspend; a `Cmd.afterRender` body inherits `sync` from the one `foreign` that
   registers it. No beni-level annotation is written anywhere in user code or in `browser-tea`.
9. **`browser-tea` can stay beni with no JavaScript of its own**, as it is today, given one new
   low-level program form in `browser` (a running program's `send`, root scope and after-render
   queue, handed to a sync `update`) and two small `Task` additions (§3.9). The command table, the
   four policies, the subscription diff and the key paths are about 200 lines of beni.
10. **What it costs.** A message whose `update` returns `Cmd.none` pays one tuple; a keyed `Restart`
    on a keystroke pays an interrupt, one `AbortController.abort()` and one fork — a few microseconds
    against a 16.7 ms frame. The runtime is research 44's 1 952 bytes brotli, reached only by a page
    that performs anything; the command and subscription layer is estimated at 0.8–1.2 kB more (§7).
    Nothing here was measured; §7 says which numbers are estimates.

---

## 1. What is fixed, and what is missing

**Fixed.** `Browser.program { init, update, view }` exists, with `update` and `view` marked `sync` in
its `foreign` signature (`platforms/browser/Browser.beni`). `Tea.sandbox` is beni over it
(`platforms/browser-tea/Tea.beni`). A message runs `update` synchronously at `send` and queues one
microtask flush that renders every program with a pending message
(`platforms/browser/runtime.js:843-895`; `backend.md` §15.11). `core/Task` has `callback`, `spawn`,
`spawnIn`, `join`, `wait`, `cancel`, `yieldNow`, `start`, `scope`, `bracket` and `uninterruptible`;
`spawn` never runs its child inline — `fork` pushes it on the scheduler's FIFO and returns
(`core/Task.js`, `fork` and `enqueue`) — and outside a fiber `spawn` acts on a root record whose
finalisers nothing runs. A platform primitive is beni over `Task.callback` and one `impure` foreign
that starts the host's operation and returns its canceller (`platforms/node/Io.beni`).

**Missing, and this report's subject.** `Tea.element` with commands and subscriptions; the
after-render queue (`backend.md` §15.11 specifies the phase and says nothing can put work in it yet);
`Browser.flush` as a value a program can use; any browser primitive that suspends; and the
DOM capabilities (focus, measure, scroll). `plans/browser-platform.md` §7's *later* row lists all of
them as waiting on effects.

**One constraint every option below obeys, because it is a measured fact rather than a preference.**
An `update` that may suspend either freezes input for the length of a request or lets two keystrokes
race and silently lose one (R25 §4.1–§4.3). So in every option, `update` is `sync`; the options differ
only in how it *asks* for work.

---

## 2. Three ways for `update` to start work

The running example is R25's: a search box that waits 250 ms after the last keystroke, cancels the
stale request, and shows the latest results. `Api` is a record of functions (A7), so a test passes
fakes; `api.search` performs an HTTP request, so it is inferred `suspends`.

### 2.1 Option A — `update` returns a work order (recommended)

```elm
update : Api, Msg, Model -> ( Model, Cmd Msg )
update api msg model =
    case msg of
        Typed "" ->
            ( { model | query = "", results = Idle }, Cmd.cancel Search )

        Typed q ->
            ( { model | query = q, results = Loading }
            , Cmd.keyed Search Cmd.Restart (search api q _)
            )

        Got q result ->
            if q == model.query then
                ( { model | results = Loaded result }, Cmd.none )
            else
                ( model, Cmd.none )


search : Api, String, Send Msg -> ()
search api q send =
    let
        _ = Time.sleep (Time.millis 250)
    in
    send (Got q (api.search q))
```

(The `q == model.query` test is belt and braces; under `Restart` a stale `Got` cannot arrive, §3.5.)

**What a `Cmd` is.** Beni data: a list of work items, each a body `Send msg -> ()`, an optional key
path, a policy, and a kind (fiber, cancel, after-render). The body is a direct-style beni function;
`Time.sleep` and `api.search` are calls. It is not `Task e a` and not a monad — there is no `andThen`,
no `map2`, no `sequence`, because a body sequences with `let` and runs things side by side with
`Task.scope`/`spawnIn` like any other beni function (P2 §6.5). A `Cmd` is the one value whose job is
to cross the gap between a `sync` `update` and a fiber, and it carries nothing else.

**Why keep the tuple, now that effects are direct style.** Three properties, each one a guarantee
rather than a taste:

- **`update`'s output is data.** A test asserts the model *and* the keys a message asked for — "typing
  an empty query cancels `Search`" is `Cmd.keys cmd == [ Cancel Search ]` with nothing run
  (R25 §5.5; `boundary.md` §5.4's argument). A time-travel debugger replays the message log through
  `update` and drops the commands, which is exactly what Elm's does (R25 §9.7).
- **An update can be computed and thrown away.** A parent that calls a child's `update` to preview
  a change, or discards it on a guard, discards its commands with it. Under option B the effect has
  already happened.
- **Where a fiber lives is the runtime's business, never the user's.** Every body is spawned into the
  program's root scope by the runtime, so nothing a program starts can be orphaned, whatever the
  user writes.

### 2.2 Option B — `update` starts fibers through a capability

```elm
update : Fx Msg, Msg, Model -> Model
update fx msg model =
    case msg of
        Typed q ->
            let
                _ = fx.keyed Search Restart (search api q _)
            in
            { model | query = q, results = Loading }
        …
```

`Fx msg` is a record of `impure` functions the platform hands in (A7's service shape), bound to the
program's root scope. `update` is inferred `impure` and still `sync`, so the checker accepts it. It is
smaller — no tuple, no `Cmd.batch`, no `Cmd.map`; a child gets `Fx.within fx (Child id) ChildMsg` —
and it reads like the effects design it sits on.

**What it loses.** `update` is no longer a function of its inputs: two calls with the same message and
model do different things. A test passes a recording `Fx` and asserts on the recording, which works;
but replay must pass a null `Fx`, a parent cannot evaluate a child's update without committing its
effects, and the order of effects inside `update` becomes the order of evaluation of a `case` — which
`language.md` §6 does define, but which in option A is the plain order of a list. Rule 7 does not
decide this: nothing is refused either way. What decides it is that A keeps a property TEA users rely
on (R24 §0.3; R25 §9.7) for the price of a tuple.

### 2.3 Option C — work as a pure function of the model

```elm
work : Model -> Sub Msg
work model =
    case model.results of
        Loading ->
            Sub.listen (Fetch model.query) (debouncedSearch api model.query _) identity

        _ ->
            Sub.none
```

There is no command at all: the program declares, from the model, which work *should be running*,
and the runtime diffs it after every flush. A new query is a new key, so the old fiber is interrupted
and the new one starts — `Restart` falls out of the diff; leaving `Loading` cancels it. This is
SwiftUI's `.task(id:)`, React Query's query keys and Compose's `LaunchedEffect(key)` (R25 §5.3), and
Solid 2's own advice in its `createEffect` documentation, whose example is a fetch keyed by a tracked
value with an `AbortController` cleanup that runs *"before next run / disposal"*
(`solid:signals.ts:480-495`).

**Where it breaks.** One-shot work. A "save" POST on a click must be represented in the model as a
pending state and cleared by the response message — reasonable — but a key that disappears and
reappears (the user clicks Save, the model leaves and re-enters the pending state for the same item)
**re-issues the request**, silently. And after-render work, fire-and-forget logging and navigation
have no model state to hang on at all.

**Verdict: C is the subscription half of A, not an alternative to it.** §3.4's subscriptions are
general fibers, so every C-shaped program is expressible under A, and the choice between a `Cmd` and
a `Sub` becomes the choice between "a message asked for this" and "the model needs this running",
which is the right distinction to hand a programmer.

### 2.4 Scorecard

| | A — work order | B — `update` spawns | C — model-derived only |
|---|---|---|---|
| `update` is `sync` | yes | yes | yes |
| `update` is pure | **yes** | no (`impure`) | yes |
| test asserts what was asked for | **by value** | by a recording fake | by value |
| replay / time travel | drop the commands | pass a null `Fx` | recompute `work` |
| discard a computed update | **yes** | no | yes |
| one-shot work (POST, focus, navigation) | **natural** | natural | awkward, may re-issue |
| state-shaped work (fetch while visible) | through `Sub` | through `Sub` | **natural** |
| allocation per message | one tuple | none | none |
| new concepts for the user | `Cmd`, `Sub`, `Send`, keys | `Fx`, `Sub`, `Send`, keys | `Sub`, `Send`, keys |

---

## 3. The recommended design

### 3.1 The program and the command API

`browser-tea`, in beni, `[proposed]` throughout:

```elm
--| How a running body puts a message into its program. Calling it runs
--| `update` (so it never waits), and does nothing once the body's fiber has
--| been cancelled or its program stopped.
pub type alias Send msg =
    msg -> ()

pub type Policy
    = Restart      -- cancel the running body under this key, wait for its cleanup, then start
    | Ignore       -- drop the new body while one runs under this key
    | Queue        -- start the new body when the previous one under this key ends
    | Concurrent   -- start it now, beside any others

pub type Cmd msg   -- opaque, beni data

pub none : Cmd msg
pub batch : List (Cmd msg) -> Cmd msg
pub perform : (Send msg -> ()) -> Cmd msg                        -- a fiber in the program's scope
pub keyed : k, Policy, (Send msg -> ()) -> Cmd msg               where k.compare : k, k -> Order
pub cancel : k -> Cmd msg                                         where k.compare : k, k -> Order
pub cancelAll : Cmd msg                                           -- every keyed body at this path and below
pub map : Cmd a, k, (a -> msg) -> Cmd msg                         where k.compare : k, k -> Order
pub afterRender : (Send msg -> ()) -> Cmd msg                     -- runs in the flush's after-render phase
pub task : (() -> a), (a -> msg) -> Cmd msg                       -- perform (\send -> send (tag (work ())))
pub do : (() -> ()) -> Cmd msg                                    -- perform (\_ -> work ())

pub element :
    { init : ( model, Cmd msg )
    , update : msg, model -> ( model, Cmd msg )
    , view : model -> Html msg
    , subscriptions : model -> Sub msg
    }
    -> Program
```

Nothing above writes `sync`: the demand on `update`, `view` and `subscriptions` arrives from
`browser`'s `foreign` (P2 §15.3 — *"`Tea.sandbox` inherits `Browser.program`'s demands with nothing
written"*), and so does the one on an `afterRender` body (§3.9). `init` is a value evaluated with
`main`, which is `sync` already (P2 §15.2 item 5). `Tea.sandbox` stays, as `element` with no
commands.

`Cmd.task` and `Cmd.do` are definitions, not primitives, which is W25(c)'s "the thunk form defined
over it in four lines". `task` is what most commands are; `perform` is there for progress, streams and
several messages from one body (R25 §5.2's "saving… / saved").

### 3.2 How the runtime runs a command

**The program is a scope.** At mount, `run` opens a root scope for the program; every command body
and every subscription body is spawned into it with `Task.spawnIn`. Stopping the program — W2's
defect teardown today, an unmount if one ever ships (W51) — closes the scope: every fiber is
interrupted, children before parents, finalisers run last first, and listeners and requests are
released (A1, `plans/browser-platform.md` §2.1 item 1).

**Each body runs in its own fiber, and its `send` is bound to that fiber.** The `Send` a body receives
checks, before it dispatches, that the fiber has not been cancelled and the program has not stopped;
if either, the message is dropped (TCA's `guard !Task.isCancelled` in its `Send`, R25 §5.1). That is
what makes "a stale response cannot land" true rather than likely: the `send` belongs to the
cancelled fiber, not to the program.

**A command started by a message is never a child of the fiber that sent it.** A body that sends
`Got q hits` runs `update` inside its own fiber step; if that `update` returns a command, the runtime
spawns it into the program's scope, not into the sender — or a later `Restart` of the sender would
kill work it has no business owning. `Task.spawnIn` with the program's scope does this; `Task.spawn`
would not.

**The ordering contract** (research 30 §8.3 asks for it in writing before anyone discovers it):

1. A message is dispatched when `send` is called: `update` runs at once, on the current model, and its
   commands are started before `send` returns. Messages are applied one at a time, in the order the
   `send`s happened, each exactly once.
2. A `send` made while a dispatch is running — from inside `update` through a captured `Send`, or from
   an after-render body — is queued and applied when the running dispatch ends, never re-entrantly.
   This is Elm's guard (R24 §2.4) and `plans/browser-platform.md` §2.5's obligation, and it needs a
   fixture. Spawned bodies cannot trigger it: `fork` never runs a child inline.
3. A `send` from a cancelled fiber, or after the program stopped, does nothing.
4. Rendering happens on the flush after the messages of a task (W28); commands' fibers start in the
   same microtask checkpoint, after the flush that shows `Loading` is queued.

Because `update` always takes the current model, the Elm hazard research 30 §3.7 records — a message
carrying a stale snapshot of the whole model clobbering a subscription's result — can only be written
on purpose. The guidance to state: a message carries data, not a model.

**The command table is beni.** The Tea wrapper's own state (not the user's model) holds
`Dict Path (Fiber ())`. The four policies:

```elm
start : Scope, Dict Path (Fiber ()), Path, Policy, (() -> ()) -> Dict Path (Fiber ())
start scope table path policy body =
    case ( policy, Dict.get table path ) of
        ( Restart, Just old ) ->
            Dict.insert table path (Task.spawnIn scope (\() -> after (Task.cancel old) body))

        ( Ignore, Just old ) ->
            if Task.running old then table else Dict.insert table path (Task.spawnIn scope body)

        ( Queue, Just old ) ->
            Dict.insert table path (Task.spawnIn scope (\() -> after (ended (Task.wait old)) body))

        _ ->
            Dict.insert table path (Task.spawnIn scope body)
```

(`after` and `ended` are one-liners that sequence and discard.) **`Restart` makes the new body wait
for the old one's cleanup**, so the aborted `fetch` is aborted before the next one starts — A1's "the
interrupter waits", with no runtime support beyond `Task.cancel`. `Concurrent` keeps only the latest
fiber in the table, which is enough to cancel by key; `Cmd.cancel k` for a `Concurrent` key cancels
the whole path (§3.3), so the table keeps a set per path when the policy is `Concurrent`.

### 3.3 Keys and `Cmd.map` — W7 made implementable

W7 decided that `Cmd.map` pushes a path segment so two instances of one component never share a key,
and that `Cmd.cancelAll` cancels a prefix. **The tagger cannot be the segment.** `Html.map … (Row id)`
and `Cmd.map cmd (Row id)` build a new closure on every `update`, so comparing taggers by identity
never matches from one message to the next, and a `Restart` would never cancel anything — the silent
wrong answer W7 exists to remove, in a new place.

So the segment is written: `Cmd.map : Cmd a, k, (a -> msg) -> Cmd msg`. The idiom is the instance's
own identity:

```elm
RowMsg id m ->
    let
        ( row, cmd ) = Row.update m (rowOf model id)
    in
    ( setRow model id row, Cmd.map cmd id (RowMsg id _) )
```

A singleton child passes `()`. There is deliberately no unkeyed `map`: a one-instance component that
later becomes two would acquire the bug W7 describes with no line changed. **This amends W7's
answer; W47 asks the owner.**

**Key identity across types — an obligation on the implementation, not a decision.** A path mixes key
types (the page's `Key`, then a row's `Int`, then the row's own `Key`), and a segment compares with its
type's `compare`, handed in as `where` evidence. Two segments are the same when their evidence is the
same function and it answers `EQ`. For a nominal type or a primitive the evidence is one top-level
constant (`tests/corpus/emit/EvidenceValue.js:3`), so identity is stable. For a *structural* key — a
tuple, `Maybe Int` — the emitter may build the evidence at the call site, and then identity varies per
call and keys never match. The spec must either have the compiler hand closed-type evidence as a
stable, deduplicated constant, or compare segments by a type fingerprint the compiler supplies; a
`run/` fixture with a tuple key under `Restart` pins it either way.

### 3.4 Subscriptions

```elm
pub type Sub msg   -- opaque, beni data

pub none : Sub msg
pub batch : List (Sub msg) -> Sub msg
pub map : Sub a, (a -> msg) -> Sub msg
pub listen : k, (Send a -> ()), (a -> msg) -> Sub msg          where k.compare : k, k -> Order
```

**`listen key body tag`** declares: "while this key is in the set, one fiber runs `body`, and each
value it sends reaches `update` through `tag`." The rules, each chosen for a reason:

- **The key is the resource's whole identity.** `Time.every` keys by its interval, `Ws.listen` by its
  URL, `Browser.onResize` by a constant. Two declarations with one key describe one resource and
  share one fiber; the body that runs is the one that started it. Library functions build keys that
  include every parameter the body depends on, so a user of the library never meets this rule.
- **Every declaration of a live key gets every event through its own, latest tagger.** The fiber's
  `send` does not call the tagger it started with; it looks up the taggers of the current
  declarations of its key. So `Time.every (Time.seconds 1) (Tick model.zone)` — a new closure every
  update — never restarts the timer, and two components both on a one-second clock share one timer
  and each receives its tick. This is exactly Elm's `Browser.Events`: the listener process is keyed by
  node and name (`elm-browser:Browser/Events.elm:330-339`), and `onSelfMsg` routes each event through
  every current subscription with that key (`:289-300`).
- **Subscriptions need no path segment.** Sharing is the point, and a subscription cannot be cancelled
  by key from `update` — it is cancelled by leaving the set.
- **The set is recomputed once per flush, and only when the model changed.** Elm recomputes after
  every update; under W28 several messages share one flush, so recomputing per flush does the same
  work at most once and never churns a subscription that leaves and re-enters within one task. A
  model identical to the last one (the renderer already tests this) skips the call.
- **The diff is Elm's three-way merge** (`Events.elm:304-321`): keys that left have their fiber
  cancelled (its finaliser removes the listener), keys that arrived are spawned into the program's
  scope, keys that stayed keep their fiber and get their new taggers. No user code ever unsubscribes,
  and a leak is unrepresentable (W6).
- **`Sub.listen` is public.** A subscription the platform did not think of — a
  `ResizeObserver` on one element, a `BroadcastChannel`, a polling loop — is ordinary beni over a
  `foreign impure` primitive. Elm withheld this (only an effect module could add a subscription,
  `boundary.md` §1); rule 7 says a capability gap is filled inside the wall, and this fills it.

What a library subscription looks like, in full:

```elm
--| Time: a tick every `interval`, with the time it fired.
pub every : Duration, (Posix -> msg) -> Sub msg
every interval tag =
    Sub.listen (Every interval) (ticks interval _) tag


ticks : Duration, Send Posix -> ()
ticks interval emit =
    let
        _ = sleep interval
        _ = emit (now ())
    in
    ticks interval emit
```

A suspending tail-recursive loop: research 44's fast path keeps it a loop, and interruption reaches it
at `sleep`, where the timer's canceller clears the `setTimeout`. A window event is the same shape as
Effect's `Stream.fromEventListener` (`effect:Stream.ts:1412-1433`) — acquire adds the listener,
release removes it, a queue carries events across — with `Task.bracket` for the acquire/release and a
suspending `take` for the queue:

```elm
pub onResize : (Size -> msg) -> Sub msg
onResize tag =
    Sub.listen Resize (windowEvents "resize" readSize _) tag


windowEvents : String, (Event -> a), Send a -> ()
windowEvents name read emit =
    Task.bracket
        (\() -> listenWindow name)          -- foreign impure: addEventListener into a buffer
        (\l _ -> unlisten l)                -- foreign impure: removeEventListener
        (\l -> forward l read emit)


forward : Listener, (Event -> a), Send a -> ()
forward l read emit =
    let
        _ = emit (read (nextEvent l))       -- nextEvent: suspends until an event is buffered
    in
    forward l read emit
```

**One consequence to accept.** A DOM event reaches `update` one fiber resumption after the browser
dispatched it, not inside the dispatch, so a subscription can never `preventDefault`. That is already
true in Elm and is the reason markup handlers are `sync` and separate (W8, W34). A subscription that
must decide synchronously (a global keyboard shortcut that swallows the key) needs a `sync` filter
passed to the listener primitive, run inside the browser's dispatch; it is a later addition
(`Browser.onKeyDownWith`), not a reason to change the model.

### 3.5 Cancellation, debounce, errors, unmount

**Latest wins (switch).** `Cmd.keyed k Restart body`. The old fiber is interrupted where it is parked
— in `sleep`, the timer is cleared; in `Http.send`, the request's `AbortController` fires — its
finalisers run, its `send` is dead, and only then does the new body start. The stale response does not
arrive late and get ignored: it cannot arrive, and the socket it held is released now (research 16
§2.4's measurement, 56 ms against 301 ms, is why beni owns the resume callback). Contrast Solid 2,
which cannot abort a promise: both stale flights ran to completion and only the commit was discarded
(R27 §4.5).

**Debounce** is `Restart` whose body sleeps first (§2.1): every keystroke restarts the wait, and only
the last one survives it. **Throttle** is `Ignore` whose body sleeps last:

```elm
Scrolled y ->
    ( { model | y = y }, Cmd.keyed Save Cmd.Ignore (savePosition api y _) )

savePosition : Api, Int, Send Msg -> ()
savePosition api y _ =
    let
        _ = api.savePosition y
    in
    Time.sleep (Time.millis 500)      -- the key stays busy, so scrolls meanwhile are dropped
```

Neither needs a `Stream` type. Effect has `Stream.debounce`, `Stream.throttle` and `Stream.switchMap`
(`effect:Stream.ts:7997`, `:8276`, `:2315`) because in Effect a sequence of events must be a value to
be transformed; in beni the sequence is a loop in a fiber and the policy is a key's.

**Errors.** Three kinds, each with one place to go:

| | example | where it goes |
|---|---|---|
| an expected failure | `HttpError`, `Closed`, `QuotaExceeded` | a `Result` the body receives from the call and sends as a message; `update`'s `case` must handle it (exhaustiveness) |
| cancellation | `Restart`, `Cmd.cancel`, a key leaving the set, teardown | nowhere: invisible to the cancelled code (A1), its finalisers run, its `send` is dead |
| a defect | a `foreign` that throws, a stack overflow | W2: stop the scheduler, close the program's scope (finalisers run, requests abort, listeners go), crash screen in development builds |

There is no `Cause`, no error channel on `Cmd`, and no `Cmd.attempt`: the body is ordinary beni and a
failure is a value in it. What Effect puts in `E` beni puts in `Result`, which is the owner's A1 and
R43 §7's reading of it. **A body that ends normally reports nothing**; if the program wants to know,
the body sends.

**Unmount.** There is no unmount today: a page program lives until the page goes, or until a defect
tears it down (W2, W9). The root scope makes one cheap to add later — `run` would return, or a page
would reach, a capability that closes the program's scope and removes its mount — and W51 asks whether
it ships now (embedding a beni program in a host page that removes it is the use).

### 3.6 After render: the queue, the capabilities, and `Browser.flush`

`backend.md` §15.11 fixes the loop: a flush (1) patches every program with a pending message, then
(2) runs the after-render work queued during those messages' `update`s, in order, each synchronously;
a message sent during (2) queues the next flush. What this report adds is how a program puts work
there.

**`Cmd.afterRender body`** queues `body` into phase (2) of the flush that renders this `update`'s
model. The body is `sync` — it runs inside the flush, where waiting would land its writes a frame late
(R26 §5.4) — and it may send, which schedules the next flush. The demand arrives from the `foreign`
that registers it, so `browser-tea` writes nothing.

**The DOM capabilities are `impure`, return a `Result`, and address nodes by id** (Elm's rule, and
`boundary.md` §4.1's "address foreign objects by value"):

```elm
foreign impure focus : String -> Result DomError ()
foreign impure blur : String -> Result DomError ()
foreign impure box : String -> Result DomError Box               -- getBoundingClientRect
foreign impure viewport : () -> Viewport
foreign impure scrollTo : String, Float, Float -> Result DomError ()
foreign impure scrollIntoView : String -> Result DomError ()
```

Research 17 §4.7 projected `focus` as `suspends`, because Elm's waits for a frame and "the platform
will want to run it after the next frame". Under W28 the platform supplies the moment instead, so the
function need not wait, and making it `suspends` would colour every caller for nothing (R43 §9.5:
declare `suspends` only for something that can actually park). Called outside phase (2) these are
still correct — a measurement forces a synchronous layout, which costs time and gives the right
answer; a node the pending render has not yet created is `Err NotFound`, not a crash.

**A fiber that wants the moment** calls `Dom.rendered : () -> ()`, `suspends`: it returns at once if
no render is pending, and otherwise parks until the flush's after-render phase has begun. Its
continuation runs on the scheduler's next drain — before paint, in the same checkpoint — so a fiber can
write `send (Opened id)`, then `Dom.rendered ()`, then `Dom.focus`, straight-line.

**`Browser.flush : () -> ()`**, `impure`, renders now: Solid 2's `flush()` (`solid:core/scheduler.ts:1469-1471`).
Its use is a fiber that sends and must measure the result before continuing. Called while a dispatch
or a flush is running — inside `update`, which may call `impure` functions — it is latched and does
nothing more than the flush already queued, so no render ever sees a half-committed model (W50).

**Rejected: a `Rendered` token** handed only to after-render bodies, required by every DOM read. It
would make "reads after writes" a static fact, but it can be stored and used later exactly like a
`Scope` (P2 §6.5's escape problem), and the property it buys is performance, not correctness — a read
outside the phase is slow, not wrong.

### 3.7 Testing and determinism

Unchanged in substance from R25 §9.6 and `plans/browser-platform.md` §1.2, and now buildable, because
all three ingredients exist or are decided: services are records (A7), so `Api` is faked with a
record of lambdas; the clock is a per-fiber slot (A13), so `Time.sleep` in a test consumes virtual
time and 250 ms of debounce costs none; and the scheduler is ours, so the order in which ready fibers
resume is FIFO and reproducible at `--jobs=1` and `--jobs=8`. The W16 driver:

```elm
t1 = Test.send (Test.start program) (Typed "a")
t2 = Test.send (Test.advance t1 (Time.millis 100)) (Typed "ab")
t3 = Test.advance t2 (Time.millis 300)
-- fakeApi's log == [ "ab" ]; Test.received t3 == [ Got "ab" (Ok hits) ]; Test.finish t3 == Ok ()
```

Option A adds one assertion that needs no running at all: `Tuple.second (update api (Typed "") m)`
has `Cmd.keys` equal to `[ Cancel Search ]`. And TCA's two end-of-test checks — unexpected messages,
and "an effect returned for this action is still running" (R25 §9.6) — are possible because the
command table and the program's scope know what is in flight, which Elm's runtime does not.

**What cannot be faked this way.** A program that calls `Http.send` directly, rather than through a
record, can only be tested against a network. A7 decided three slots — clock, scheduler, log context
— and no transport; W55 asks whether the browser wants a fourth.

### 3.8 What `sync` checks here, and what it leaves alone

| function | demanded? | by what |
|---|---|---|
| `update`, `view` | `sync` | `Browser`'s `foreign` fields, inherited through `Tea.element` (P2 §15.3) |
| `subscriptions` | `sync` | called inside the wrapped `update`, whose class it joins |
| `init` | `sync` | evaluated with `main` (§15.2 item 5) |
| markup handlers, `For` rows, `Html.map` taggers | `sync` | §15.2 items 3–4 |
| a `Cmd.afterRender` body | `sync` | the registering `foreign`'s `sync` parameter |
| a command body, a subscription body | **no** | stored in data and run by a fiber; a lambda passed along joins nothing (P2 §14.3 rule 1) |
| a `Cmd`/`Sub` tagger | no | applied in the body's fiber, in beni |
| `Send msg` | not demanded; it never waits | it is the host's function, handed back (§14.3 rule 6's positive position); it runs `update`, which is `sync` |

**Impurity is not demanded anywhere.** `update` may call `Debug.log` or a `Ref`, and it may call
`Browser.flush` (latched, §3.6). A demand that `update` be *pure* — a second kind of demand beside
`sync` — would make option A's first property checked rather than conventional, and would refuse
`Debug.log` in `update`. Rule 7 says a refusal must buy a guarantee; this one buys replay correctness
only for a program that mutates a `Ref` in `update`, which is already visible. W54 recommends no
demand and, at most, a later warning.

### 3.9 What `browser-tea` is built from

`browser-tea` has no JavaScript today and should keep none. It needs three things from below:

1. **A running program's capabilities, from `browser`.** One new `foreign` form of program,
   `Browser.hosted`, whose `init` receives a `Host msg` — `send`, the program's root `Scope`, the
   after-render queue — and whose `update` receives it too:

   ```elm
   pub foreign type Host msg
   pub foreign pure hosted :
       { init : Host msg -> model
       , update : sync (Host msg, msg, model -> model)
       , view : sync (model -> Html msg)
       }
       -> Program
   pub foreign impure send : Host msg, msg -> ()
   pub foreign impure scopeOf : Host msg -> Scope
   pub foreign impure afterRender : Host msg, sync (() -> ()) -> ()
   pub foreign impure flush : () -> ()
   ```

   `Browser.program` stays as it is, for a page with no effects, and reaches no byte of `Task`.
2. **Two `Task` additions**, both `impure`, both small: `running : Fiber a -> Bool` (for `Ignore`, R43
   §9.1 classifies a non-waiting query as `impure`), and a way for a platform to hold a scope that no
   fiber's `scope` call brackets — an `openRoot : () -> Scope` / `closeRoot : Scope -> ()` pair — since
   the program's scope outlives every call. `Task.scope` cannot provide it: it closes when its function
   returns.
3. **The wrapper's state is beni.** Tea's model for `Browser.hosted` is `{ user : model, commands :
   Dict Path (Fibers), subs : Dict SubKey Live }`; a `Fiber` is fine there because it is the
   platform's state, not the user's, and nothing compares it.

---

## 4. Examples

All `[proposed]`; `Time`, `Http`, `Dom`, `Ws`, `Queue` and `Tea.element` do not exist yet. Markup is
`language.md` §11's.

### 4.1 A search box with a debounced fetch and cancellation

```elm
import Browser
import Html exposing (Html)
import Http
import Tea exposing (Cmd, Send, Sub)
import Time


type alias Hit =
    id : String
    title : String


type alias Api =
    search : String -> Result Http.Error (List Hit)


type Results
    = Idle
    | Loading
    | Loaded (Result Http.Error (List Hit))


type alias Model =
    query : String
    results : Results


type Msg
    = Typed String
    | Got String (Result Http.Error (List Hit))


type Key
    = Search


update : Api, Msg, Model -> ( Model, Cmd Msg )
update api msg model =
    case msg of
        Typed "" ->
            ( { model | query = "", results = Idle }, Cmd.cancel Search )

        Typed q ->
            ( { model | query = q, results = Loading }
            , Cmd.keyed Search Cmd.Restart (search api q _)
            )

        Got _ result ->
            ( { model | results = Loaded result }, Cmd.none )


--| Runs in its own fiber. The next keystroke restarts it wherever it is
--| parked: in `sleep` (the timer is cleared) or in `api.search` (the
--| request is aborted). Its `send` is dead from then on.
search : Api, String, Send Msg -> ()
search api q send =
    let
        _ = Time.sleep (Time.millis 250)
    in
    send (Got q (api.search q))


view : Model -> Html Msg
view model =
    <div class="search">
        <input value={model.query} onInput={Typed} />
        {viewResults model.results}
    </div>


realApi : Api
realApi =
    { search = \q -> Result.andThen (Http.get "/search?q=${Url.encode q}") decodeHits }


main : Tea.Program
main =
    Tea.element
        { init = ( { query = "", results = Idle }, Cmd.none )
        , update = \msg model -> update realApi msg model
        , view = view
        , subscriptions = \_ -> Sub.none
        }
```

What each piece is: `update` is `sync` and pure; `search` is inferred `suspends` and nobody wrote it;
`Restart` plus a leading `sleep` is the debounce; the empty query cancels by key.

### 4.2 A clock subscription that stops when the tab is hidden

```elm
type Msg
    = Tick Time.Posix
    | Seen Browser.Visibility


subscriptions : Model -> Sub Msg
subscriptions model =
    case model.visibility of
        Browser.Visible ->
            Sub.batch [ Time.every (Time.seconds 1) Tick, Browser.onVisibilityChange Seen ]

        Browser.Hidden ->
            Browser.onVisibilityChange Seen
```

Hiding the tab removes `Every 1000` from the set, so its fiber is cancelled parked in `sleep` and the
timer is cleared; showing it starts a new one. Nobody wrote `clearInterval`.

### 4.3 A WebSocket chat

The session is one subscription, a fiber that owns the socket and runs a reader and a writer side by
side in a scope. It hands `update` its outbox as a message; `update` keeps it in the model and puts
lines into it with a command.

```elm
type Msg
    = Chat Ws.Session
    | Draft String
    | Submit
    | Unsent String


type alias Model =
    room : String
    online : Bool
    draft : String
    lines : List String
    outbox : Maybe (Queue String)


subscriptions : Model -> Sub Msg
subscriptions model =
    if model.online then
        Ws.session "wss://chat.example/${model.room}" Chat
    else
        Sub.none


update : Msg, Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Chat (Ws.Opened outbox) ->
            ( { model | outbox = Just outbox }, Cmd.none )

        Chat (Ws.Line line) ->
            ( { model | lines = line :: model.lines }, Cmd.none )

        Chat (Ws.Closed _) ->
            ( { model | outbox = Nothing }, Cmd.none )

        Draft text ->
            ( { model | draft = text }, Cmd.none )

        Submit ->
            case model.outbox of
                Just outbox ->
                    ( { model | draft = "" }, Cmd.task (\() -> Queue.put outbox model.draft) (sent model.draft _) )

                Nothing ->
                    ( model, Cmd.none )

        Unsent line ->
            ( { model | draft = line }, Cmd.none )


sent : String, Result Queue.Closed () -> Msg
sent line result =
    case result of
        Ok () -> Draft ""
        Err _ -> Unsent line
```

and the library side, in `Ws`, beni over four foreigns:

```elm
pub type Session
    = Opened (Queue String)
    | Line String
    | Closed Error


pub session : String, (Session -> msg) -> Sub msg
session url tag =
    Sub.listen (Url url) (run url _) tag


run : String, Send Session -> ()
run url emit =
    Task.bracket
        (\() -> open url)                            -- foreign impure: `new WebSocket(url)`, never waits
        (\socket _ -> close socket)                  -- foreign impure
        (\socket ->
            Task.scope (\s ->
                let
                    outbox = Queue.unbounded ()
                    _ = Task.spawnIn s (\() -> writer socket outbox)
                    _ = emit (Opened outbox)
                in
                reader socket emit))


reader : Socket, Send Session -> ()
reader socket emit =
    case receive socket of                           -- foreign suspends: the next frame, buffered in the sibling
        Message line ->
            let
                _ = emit (Line line)
            in
            reader socket emit

        Ended why ->
            emit (Closed why)


writer : Socket, Queue String -> ()
writer socket outbox =
    let
        _ = send socket (Queue.take outbox)          -- take suspends; send is impure
    in
    writer socket outbox
```

When the room changes, the key changes; when `online` goes false, the key leaves. Either way the
session fiber is cancelled: the scope cancels the writer (parked in `take`), the bracket closes the
socket, and the queue is closed by its owner's finaliser, so a `Queue.put` racing it gets
`Err Closed` and the draft is restored — never a line silently lost. Two decisions sit in this example.
The model holds a handle (a `Queue`), which `boundary.md` §4.1's "never hold a reference across an
effect boundary" discourages; it is safe here only because every operation on a closed queue is a
`Result`, and it needs the `Queue` type to be `equatable foreign type` so the model keeps its derived
`==` (W52). And `open` never waits because the browser's `WebSocket` constructor does not: the `open`
event is simply the first thing `receive` could report, which keeps the acquire of `bracket` —
uninterruptible by A1 — free of any wait.

### 4.4 Focusing an input after render

```elm
update : Msg, Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Edit id ->
            ( { model | editing = Just id }, Cmd.afterRender (focusEditor id _) )

        …


focusEditor : String, Send Msg -> ()
focusEditor id send =
    case Dom.focus "edit-${id}" of
        Ok () -> ()
        Err e -> send (FocusFailed e)
```

The input is created by this update's render; the body runs after the patch, in the same flush, so the
node exists and focusing it costs no frame. The same shape measures (`Dom.box`) and scrolls
(`Dom.scrollIntoView`). From inside a fiber — a body that sends and then wants the result on screen —
it is `send (Edit id)`, `Dom.rendered ()`, `Dom.focus …`, in that order.

---

## 5. The first browser primitives

`Rung` is what the platform declares (P2 §14.1). A primitive that can park is `suspends` however rarely
it does (R43 §9.5); one that never parks is `impure`. Suspending ones are beni over `Task.callback`
and an `impure` start-and-return-canceller foreign, as `Io.sleep` is.

| Module | Signature | Rung | Note |
|---|---|---|---|
| `Http` | `send : Request -> Result Error Response` | `suspends` | `fetch` with an `AbortController` minted at the leaf; the canceller aborts (P2 §6.4) |
| | `get : String -> Result Error String` | inferred | beni over `send`; JSON through schemas when they parse |
| | `read : Body -> Maybe Bytes` | `suspends` | a streaming body as a pull (R17 §4.4) |
| `Time` | `now : () -> Posix`, `here : () -> Zone` | `impure` | read the clock slot (A7, A13) |
| | `sleep : Duration -> ()` | `suspends` | the clock slot; virtual under the test driver |
| | `every : Duration, (Posix -> msg) -> Sub msg` | — | beni over `Sub.listen` (§3.4) |
| `Browser` | `nextFrame : () -> Float` | `suspends` | `requestAnimationFrame`, for animation loops |
| | `onAnimationFrame`, `onResize`, `onVisibilityChange`, `onKeyDown`, `onWindow : String, (Event -> msg) -> Sub msg` | — | beni over one `listenWindow`/`nextEvent` pair |
| | `visibility : () -> Visibility` | `impure` | |
| | `flush : () -> ()` | `impure` | §3.6 |
| `Dom` | `focus`, `blur`, `box`, `viewport`, `scrollTo`, `scrollIntoView` | `impure` | `Result DomError _`, by id (§3.6); R17 §4.7's `suspends` withdrawn |
| | `rendered : () -> ()` | `suspends` | until the flush's after-render phase; at once if none pending |
| `Random` | `seed : () -> Seed` | `impure` | `crypto.getRandomValues` |
| | `step : Generator a, Seed -> ( a, Seed )` | `pure` | a hash (R17 §4.9) |
| | `generate : Generator a -> a` | `impure` | `step` over a fresh `seed ()`; rule 7's convenience |
| `Storage` | `get : String -> Maybe String`, `keys : () -> List String` | `impure` | Web Storage is synchronous (R17 §4.5) |
| | `set : String, String -> Result QuotaExceeded ()`, `remove : String -> ()` | `impure` | |
| | `onChange : (Change -> msg) -> Sub msg` | — | the `storage` event: another tab wrote |
| `Nav` | `Nav = { push : Url -> (), replace : Url -> (), go : Int -> () }` | fields `impure` | a capability record handed to `Tea.application`'s `init` (A7; `plans/browser-platform.md` §2.7); used as `Cmd.do (\() -> nav.push url)` |
| | `load : String -> ()`, `reload : () -> ()` | `impure` | no capability, Elm's asymmetry |
| | `Tea.application { …, onUrlRequest, onUrlChange }` | — | the link guard is Elm's (`elm-browser:Elm/Kernel/Browser.js:142-152`), in the runtime |
| `Ws` | `open : String -> Socket`, `send : Socket, String -> Result Error ()`, `close : Socket -> ()` | `impure` | the constructor never waits |
| | `receive : Socket -> Event` | `suspends` | frames buffered in the sibling between pulls |
| `Queue` (core) | `unbounded : () -> Queue a`, `put : Queue a, a -> Result Closed ()` | `impure` | P2 §6.5; `equatable foreign type` (W52) |
| | `take : Queue a -> a` | `suspends` | a cancelled taker leaves the waiter list (P2 §6.5) |

Every one is first-order, as research 17 §6.5 bet. The only higher-order functions are `Sub.listen`,
the `Cmd` constructors and `Task`'s combinators, all beni.

---

## 6. Against Elm, Effect v4, Solid 2 and Roc

| | Elm | Effect v4 | Solid 2 | Roc | **this design** |
|---|---|---|---|---|---|
| how work is started | `update` returns `Cmd msg` of `Task`s | an `Effect` value run by a fiber | an `action` (a generator, `solid:core/action.ts:112`) or an async memo | an effectful function (`=>`), called directly from `main!`-style platform entry points | `update` returns `Cmd msg` of direct-style bodies |
| sequencing | `Task.andThen` | `Effect.gen` / `flatMap` | `await`, then `yield` to re-enter the transaction | plain calls | plain calls, inferred `suspends` |
| cancellation | only `elm/http`'s kernel-private `cancel` (R25 §8.7); stale messages ignored | `Fiber.interrupt`, prompt | none: a stale promise runs to completion and its commit is dropped (R27 §4.5) | none: effects are synchronous host calls | keyed, prompt, waits for cleanup |
| subscriptions | `Sub`, diffed by key, kernel-only managers (`Browser/Events.elm:304-321`) | `Stream` + `Scope` | a tracked `createEffect` with a cleanup (`solid:signals.ts:495`) | none | `Sub.listen`, diffed by key, any author |
| after render | an rAF before every DOM read (`Browser.js:293-305`) | — | the effect half of the split effect, `onSettled` (`solid:signals.ts:1187`) | — | `Cmd.afterRender`, `Dom.rendered` |
| render now | `stopPropagation` implies sync (R24 §6.6) | — | `flush()` (`solid:core/scheduler.ts:1471`) | — | `Browser.flush` |
| failures | `Task x a`'s `x`, then a `Msg` | `E` channel, `Cause` | thrown, caught by boundaries | `Result`, `?` | `Result` in the body, then a `Msg`; defects fatal |
| services | none (ports) | `Context.Service`, `Layer` (`effect:Layer.ts:1014`) | context | platform-provided functions | records of functions + 3 slots (A7) |

**From Elm, take the shape and the subscription semantics, un-privileged.** `update` returning
`( model, Cmd msg )`, the three-way diff keyed by resource, taggers routed through the current
declarations (`Events.elm:289-300`), `Nav` as a capability, the link guard. Leave the effect-module
wall (`boundary.md` §1) — `Sub.listen` and `Cmd.keyed` are what `elm/http` and `Browser.Events` had
to be kernel to write — and leave `Task` as a monad: in beni the body is a function.

**From Effect v4, take the runtime semantics and not the surface.** Prompt interruption,
cleanup-before-return, scoped fibers (`effect:Effect.ts:8621`'s `forkIn` is `spawnIn`), and
`Stream.fromEventListener`'s acquire/release-plus-queue shape (`effect:Stream.ts:1412-1433`) for every
DOM subscription. Leave `Layer` and `Context` — A7 decided records and three slots, and a browser page
has one composition root, `main`, where a record is built once — and leave `Stream` as a type for v1:
a loop in a fiber plus a key's policy covers `debounce`, `throttle` and `switchMap`
(`effect:Stream.ts:7997`, `:8276`, `:2315`). `Schedule` (`effect:Schedule.ts:850`, `:1198`) is A4's
and belongs in `Time.every`'s successor and in `retry`, not here. The one thing Effect cannot offer a
browser is shown by R44 §3: its `yieldNow` in Chrome is 4.13 ms, because its scheduler falls back to a
clamped `setTimeout(0)`.

**From Solid 2, take the loop, the split effect and `flush`** — already decided in W28 and built in
`backend.md` §15.11 — and its keyed-effect idiom (`createEffect(() => userId(), id => { …; return ()
=> ctrl.abort() })`, `solid:signals.ts:483-490`), which is option C and which §3.4's subscriptions
express. Leave transitions and `isPending` (`solid:core/verdict.ts:709`): they hold the old UI while
async derivations settle, which in TEA is a model state (`Loading` beside the last results, the
`AsyncResult` "waiting" flag R25 §8.2 recommends as a library type). Leave `createOptimistic`
(`solid:signals.ts:1060`): an optimistic value in TEA is a model field set in `update` and reverted by
the failure message (R25 §3.5), with no runtime support.

**From Roc, take the principle and not the absence.** Roc infers purity and requires that
*"effectful functions can only be called by other effectful functions"*, and *"all effectful functions
originate in the platform"* (`roc:docs/langref/functions.md:25-28`, `:105-110`) — beni's `foreign`
wall and inferred rungs are the same idea without Roc's `=>`/`!` markers (`:60-71`, `:76-82`), which P2
§3 rejects. Roc has no concurrency and no browser architecture: its UI design, Action-State, is a
proposal with an experimental JS-DOM platform that reached "partially working" in 2024 (Luke Boswell,
#show and tell › Roc JS DOM platform experiment, 2024-11-27,
https://roc.zulipchat.com/#narrow/channel/304902-show-and-tell/topic/Roc.20JS.20DOM.20platform.20experiment/near/484670859),
and Richard Feldman's own summary puts it on TEA's side of the line — *"one giant state atom … I can
trace exactly how every part of the system changes"* (#ideas › Platform mocking in a PI world,
2024-12-10,
https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/Platform.20mocking.20in.20a.20PI.20world/near/487159701).
Nothing there to copy for cancellation or subscriptions.

---

## 7. What it costs

**Nothing here was measured.** The numbers are research 44's and research 16's measurements
combined, and they are estimates of what a built system would pay.

| Per message | cost | from |
|---|---|---|
| `update` returning `( model, Cmd.none )` | one two-element tuple; `Cmd.none` is a shared constant | — |
| a `Cmd.task` | one work item, one fork: ~0.3 µs | R44 §3, 343 ns per fiber spawned, yielding once, joined |
| a keyed `Restart` on a keystroke | interrupt a parked fiber, run its finalisers (one `AbortController.abort()`, ~1 µs), fork the new body: **~2–3 µs** | R16 §3.8 row 2, R44 §3 |
| the subscription diff | one `subscriptions model` call and a merge of a handful of keys per flush, skipped when the model is identical: ~1 µs | Elm's is the same merge |
| a suspension on the fast path | 2.0–2.4 ns Node, 5.0–6.5 ns Chrome | R44 §2 |
| a real park (`sleep`, `fetch`) | ~125–160 ns plus the host's own cost | R44 §3 |

Against a 16.7 ms frame and W36's 1 ms change-detection budget, the effect layer's share of a keystroke
is three orders of magnitude below the budget. The per-message cost of option A over option B is the
tuple, and V8 frequently scalar-replaces a tuple that is destructured at once.

| Bytes, brotli, `--release` | estimate | from |
|---|---|---|
| the fiber runtime and a program's continuations | **1 952** | R44 §4, measured |
| `Cmd`, `Sub`, the policies, the diff, key paths (~200 lines of beni) | 0.8–1.2 kB | estimated from `bench/size.mjs`'s ratio for beni code |
| `Browser.hosted`, the after-render queue, `flush` wiring in `runtime.js` | ~0.3 kB | ~40 lines JS |
| each primitive module a page reaches (`Http`, `Time`, `Dom`, …) | 0.1–0.4 kB each | one small sibling apiece |

So a TEA page that performs anything should land near the empty `browser-tea` page (6 251 brotli in
development, 6 178 released, `backend.md` §15.11) plus **~3–4 kB**. Elm's counter is 22 723 brotli
(R24 §11.1). A page that performs nothing — `Tea.sandbox`, or `Tea.element` whose every command is
`Cmd.none` — must not reach `Task`: elimination (`backend.md` §9) keeps that true only if `Cmd.none`
and the subscription diff do not reference the fork path when no body exists, which the spec should
pin with a size line.

---

## 8. Obligations for whoever specifies it

1. **The dispatcher queues re-entrant sends** (§3.2 rule 2) — a fixture sends from inside `update`
   through a captured `Send` and from an after-render body, and asserts one update at a time.
2. **A dead fiber's `send` is dead** — a fixture restarts a body parked in a fake request that
   completes afterwards, and asserts its message never reaches `update`.
3. **`Restart` waits for the old body's cleanup** — a fixture whose body's release logs, and the new
   body's first line logs, in that order.
4. **Key identity is independent of how evidence was built** (§3.3) — a tuple key under `Restart`.
5. **Taggers are the latest declaration's** — a subscription whose tagger closes over the model
   delivers the new closure's message after an update, with the timer not restarted (a `Debug.log` in
   the body's acquire runs once).
6. **The program's scope owns every body** — a command started from a message a body sent survives
   that body's `Restart`.
7. **A page that performs nothing ships no `Task`** — a `bench/size.mjs` line.
8. **Teardown (W2) closes the program's scope** — a defect in one body aborts another's request and
   removes a subscription's listener (a `browser/` fixture that counts listeners).

---

## 9. Decisions for the owner

Added to `plans/browser-decisions.md` as **W46–W55**, dated 2026-09-30, open.

| # | Question | Recommendation |
|---|---|---|
| **W46** | How does `update` start work: return a work order (A), spawn through a capability (B), or only derive work from the model (C)? | **A**, with C's half as subscriptions (§2) |
| **W47** | W7's `Cmd.map` needs a value to push: write it, `Cmd.map : Cmd a, k, (a -> msg)`, with no unkeyed `map`? | **Yes** (§3.3); amends W7 |
| **W48** | Subscription semantics: key = the resource's identity, every declaration of a key gets each event through its own latest tagger, diffed once per flush, `Sub.listen` public | **Yes** (§3.4) |
| **W49** | After-render work: `Cmd.afterRender` with a `sync` body; DOM capabilities `impure` returning `Result`; `Dom.rendered` for fibers | **Yes**, and R17 §4.7's `suspends` `focus` is withdrawn (§3.6) |
| **W50** | `Browser.flush`: callable anywhere, latched when called during a dispatch or a flush | **Yes** (§3.6) |
| **W51** | Does a program get an unmount capability now, or only defect teardown? | **Not now**; the root scope is specified so it is cheap later (§3.5) |
| **W52** | May a model hold a handle (`Queue`, a socket's outbox) as an `equatable foreign type`, provided every operation on a closed one is a `Result`? | **Yes**, amending `boundary.md` §4.1's "never hold a reference" for handles whose use is total (§4.3); the alternative is Elm 0.18's URL-keyed registries inside each platform module |
| **W53** | The ordering contract of §3.2 — arrival order, exactly once, synchronous at `send`, re-entrant sends queued, dead senders dropped — written into `boundary.md` | **Yes** (research 30 §8.3) |
| **W54** | Should the platform demand that `update`/`view` be *pure*, not just `sync`? | **No**; a warning later if asked (§3.8) |
| **W55** | Tests fake HTTP through service records only (A7 as decided), or does the browser get a fourth fiber slot, a transport? | **Records only** for now; revisit when W16's driver meets a real program (§3.7) |

**Reversibility.** W46 is low (it is the type of every `update`), W47 and W48 low (they are the
semantics of every key), W49–W55 medium to high.

---

## 10. What this report did not settle

- **No measurement.** Every figure in §7 is an estimate from R16 and R44. The cheapest confirmation is
  a `browser/` page with the §4.1 search box under the test driver, and a size line.
- **Subscriptions that must `preventDefault`** (a global shortcut) need a `sync` filter inside the
  browser's dispatch; its shape is not designed (§3.4).
- **Web Workers, `IndexedDB`, `Intl`** are left to research 17's table; nothing here changes their
  rungs.
- **Chunking and lazy loading** of a primitive module a route reaches late is `backend.md` §10's.
- **Whether `Cmd` should expose its keys to tests** (`Cmd.keys`) as a public function, or only to the
  W16 driver, is a detail for the spec.
- **Firefox and Safari**: R44 measured Node and Chrome only.

---

## 11. Evidence index

This repository: `transparent-effects-proposal.md` §6, §14–§16; `backend.md` §15.11;
`boundary.md` §4.1, §5.4; `plans/browser-decisions.md` W2, W6–W9, W16, W25, W28, W36;
`plans/browser-platform.md` §1, §2.1–§2.7, §7; `plans/effects-decisions.md` A1, A4, A7, A13;
research 16 §2.4, §3.8; 17 §4.2–§4.13, §6.5; 24 §2.4, §6.6, §11.1; 25 §2–§5, §8, §9; 27 §4.5; 30
§3.7, §8.3; 43 §7, §9.1, §9.5; 44 §2–§4. Code: `core/Task.beni`, `core/Task.js` (`fork`, `enqueue`,
`spawnIn`, `cancel`), `platforms/browser/Browser.beni`, `platforms/browser/runtime.js:843-895`,
`platforms/browser-tea/Tea.beni`, `platforms/node/Io.beni`, `tests/corpus/emit/EvidenceValue.js:3`.

References: `elm-browser:Browser/Events.elm:289-300`, `:304-321`, `:330-357`;
`elm-browser:Elm/Kernel/Browser.js:142-152`, `:265-305`; `effect:Stream.ts:1412-1433`, `:2315`,
`:7997`, `:8276`; `effect:Schedule.ts:850`, `:1198`; `effect:Layer.ts:1014`; `effect:Effect.ts:8621`;
`solid:signals.ts:480-495`, `:1060`, `:1187`; `solid:core/action.ts:112`; `solid:core/verdict.ts:709`;
`solid:core/scheduler.ts:1469-1471`; `roc:docs/langref/functions.md:25-28`, `:60-82`, `:105-110`.
Roc Zulip: messages 484670859 and 487159701, permalinks in §6.
