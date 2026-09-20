# The browser platform — the owner's decision sheet

**Status:** synthesis, 2026-09-20. **Implementation is parked**; this sheet and
[`plans/browser-platform.md`](browser-platform.md) are the whole output of the browser design pass.

**What this is.** The three reports the pass produced — [`research/24`](../docs/design/research/24-elm-browser-runtime.md)
(**R24**, Elm's browser runtime as built), [`research/25`](../docs/design/research/25-ui-architecture-design-space.md)
(**R25**, the UI architecture design space) and [`research/26`](../docs/design/research/26-browser-host-measured.md)
(**R26**, the browser as a host, measured) — each ended with a list of questions for the owner. There
are 25 and they overlap. This is the deduplicated list: **24 questions with stable ids `W1…W24`**
(W for web; the effects sheet's `A…`/`B…`/`C…` ids are untouched), tiered by whether a
browser-platform spec can be written without the answer. Every question has the same shape — *the
situation in plain words · an example where it helps · the options · what each costs · the
recommendation and why · how reversible it is* — and none needs the reports to have been read. Form
is copied from [`plans/effects-decisions.md`](effects-decisions.md), which worked. **P2** is
[`transparent-effects-proposal.md`](../docs/design/transparent-effects-proposal.md).

---

## Answered by the owner

*(blank — the manager fills this in, in the shape of the effects sheet's block)*

| Item | Answer |
|---|---|
| **W1** | |
| **W2** | |
| **W3** | |
| **W4** | |
| **W5** | |
| **W6** | |
| **W7** | |
| **W8** | |
| **W9** | |

---

## The five-minute version

Three reports were written. **R24 read Elm's browser runtime line by line** and found that of its 25
pieces, twelve exist because of the *browser* and beni needs an equivalent of each; only two exist
because of Elm's `Cmd`/`Sub`/`Task` machinery and vanish outright. The virtual DOM is the single
biggest piece (1 589 lines, 27 % of a counter's bytes) and survives every effects decision. Elm's
scheduler never yields: a two-million-step chain froze the page for 372 ms and served zero animation
frames (R24 §3.3) — the clearest thing beni can simply be better at.

**R25 asked what a UI looks like when an effectful call is just a call**, worked one typeahead
example through five architectures, and found one result that matters more than the rest: a `sync`
function has no suspension point, and a suspension point is the only place another fiber can
interleave — so **`sync update` is a compiler-checked proof that two in-flight effects cannot both
write the model** (R25 §4.3). Elm gets that property free because JavaScript cannot suspend a stack;
beni will be able to, so it has to be bought, and `sync` (already decided, A6) is what buys it. Its
recommendation: The Elm Architecture stays, `update` stays pure, and a command is a fiber handed a
`send`. Keyed, structural cancellation then makes "the stale response cannot land" true rather than
"the stale response is ignored" — which no other system surveyed can say.

**R26 measured the browser itself.** A fiber should yield through `MessageChannel` on a time slice of
about 1 ms; input latency p90 tracks the slice almost exactly. P2 §7.5's microtask tier is not a
trade-off to tune but a mistake to withdraw: yielding through microtasks every 64 ops is *worse than
never yielding at all* (p50 371 ms against 84 ms) and buys no throughput. A defect in a page kills
nothing — an uncaught throw leaves the next task, the next frame and the sibling listeners all
running, in both engines — so "fatal" is something the platform must implement. One bundled file
reaches `main` **3.0× faster on 4G** than thirteen modules. A browser test kind costs ~10 ms per
fixture against today's 1 m 50 s gate: about +1 %.

Nine questions have to be answered before a browser-platform spec can be written. They are below,
with a one-line recommendation each, so "go with the recommendations" is a usable answer.

| # | Question | Recommendation in one line |
|---|---|---|
| **W1** | Is TEA the blessed architecture, and what shape is a command? | Yes; a command is a function handed a `send`, with the simple "run this thunk, tag the result" form defined over it in four lines |
| **W2** | What does a defect do to a page? | Stop the scheduler and tear down the mount (finalisers run, listeners go, requests abort); a crash screen in development builds only |
| **W3** | The browser scheduler's default, and P2 §7.5's microtask tier | `MessageChannel`, yield on a ~1 ms slice counted as 256 ops then a clock read; **withdraw the microtask tier from P2 §7.5** |
| **W4** | Must `view` be pure as well as `sync`? | Only if render memoisation (`lazy`) ships. Recommend: keep `lazy` parked, one bit, and revisit when a real application asks |
| **W5** | The render loop: how many phases, and what triggers a synchronous render? | One render per frame; a *separate, explicit* "render now" for text inputs; plus one after-render phase. Three things, not Elm's two-in-one bit |
| **W6** | Subscriptions: declared from the model and diffed? | Yes, and each live subscription is a scoped fiber, so a listener nobody wants cannot survive and nobody writes `unsubscribe` |
| **W7** | Are command keys namespaced? | Yes — `Cmd.map` pushes a path segment; without it the second reusable component silently cancels its sibling's work |
| **W8** | How does JavaScript call back into beni? | The platform's registration primitives take a `sync` function and nothing else can be passed; `boundary.md` §4 gains a rule for a `foreign` that calls back |
| **W9** | What is `main` in a page, and what replaces the exit code? | `main : Program` unchanged; `Program` is the platform's mount descriptor, keep-alive is meaningless, and the harness reads a platform-defined global instead of an exit code |

---

## Where the three reports disagree, and how it is resolved here

Six places. Two are real disagreements, four are the same thing seen from different angles and never
joined up.

**1. Do gesture-scoped capabilities die when `update` leaves the handler's tick? — a real
disagreement, and R26 wins.** R24 §0.2 item 4 quotes Elm's own documentation — *"Some actions, like
uploading and downloading files, are only allowed when the JavaScript event loop is running because
of user input… we call `update` and send any `port` messages immediately, all within the same
tick"* — and calls it *"the sharpest argument the vendored sources make for a `sync` `update`"*.
**R26 §5.3 measured it and it is not true**: `window.open` succeeded after a 4 900 ms macrotask hop
and failed at 5 200 ms, because transient activation lasts five seconds in both Chrome and Firefox.
**Resolution: R26 is measured and R24 is quoting a document, so R26 wins and R24 §0.2 item 4 is
withdrawn as an argument.** `sync update` still stands on R25 §4.3's atomicity proof, which is
independent and stronger. *Caveat: clipboard and fullscreen failed synchronously in headless Chrome,
so their activation behaviour is unmeasured (R26 §12 item 4) and the spec should not claim them.*

**2. The microtask tier — R26 kills it, and nothing in R25 depended on it.** The thing to check was
whether any of R25's options need microtask-speed resumption, in particular `send` from a fiber into
the `update` loop. **They do not.** R25 §5.1 types `Send msg` as `sync (msg -> ())` — an ordinary
synchronous call that re-enters the dispatcher, with no scheduler hop at all. The only thing the
withdrawal touches is the throughput of a long-running fiber, which R26 §3.4 puts at 1.00–1.02×
overhead once the slice is ≥0.25 ms. **So the withdrawal is clean.** What a synchronous `send` *does*
create is a hazard R24 names from the other side: Elm's dispatch is queued, with a nineteen-line
comment explaining that an effect completing synchronously can reorder subscription processing, and
R24 §2.4 says in terms that *"beni's fiber runtime has the same class of problem"*. A `send`
re-enters `update`, which may return a command that spawns a fiber that sends again. **The dispatcher
needs the same guard** — the same class as the re-entrant interrupt the effects spike already owns
(S6). Recorded as an obligation in [`plans/browser-platform.md`](browser-platform.md) §2.5, not as a
question.

**3. "Render synchronously" (R24 §0.2 item 3, §6.9) versus "how many render phases" (R25 D8) versus
rAF (R26 §5.4) — two different axes that nobody joined.** R24 is about *when the DOM is patched
relative to an event*: once per frame, except that Elm renders synchronously when the handler set
`stopPropagation`, because `<input type="text">` holds its own state. R25 D8 is about *what phases an
effect may run in*: Lustre needed three for focus, measurement and scroll restoration. R26 constrains
the last: a rAF callback that suspends resumed 10.1 ms later and its write landed in the *next*
frame, and interleaving DOM reads with writes over 3 000 nodes cost 1 139× a batched pass (§5.5).
**Resolution: compatible, and W5 states all three together** — one render per frame, an explicit
render-now, one after-render phase — with R24 §6.6's warning honoured: Elm couples "render now" to
`stopPropagation` by accident and beni should decide them separately.

**4. How strict is `sync`? — R26 refines R24, and both land in the same place.** R24 §0.2 item 1 says
`preventDefault` must be decided synchronously inside the listener. R26 §5.1 measured that a
**microtask** hop is still in time while a `MessageChannel`, `setTimeout` or rAF hop is not — and
that `event.defaultPrevented` reads `true` in every case, so the mistake is undetectable at run time.
R26 Q5 still recommends the conservative rule, because whether a call suspends only through a
microtask is not a property a caller can see. **No conflict; recorded as W18.**

**5. Subscriptions — R24 asked, R25 answered.** R24 §0.4 question 1 and §5.5 leave four options open
and warn that *"if a beni design requires an explicit stop, it has given up"* the one TEA property
with no replacement. R25 §9.4 composes two of them (declared-and-diffed **plus** scoped fibers), as
Iced does in another language (R25 §8.4). **Resolved by R25; it is W6.**

**6. The size budget — R25 quotes a number that does not cover what a browser ships.** R25's fixed
point F10 states *"the runtime's budget is ≤ 5 kB gzip"*. That figure is `plans/effects-decisions.md`
B9's, and B9 is about the **concurrency** runtime — the fiber kernel — not about a renderer. R24
§11.4 estimates a beni counter at 35–50 kB raw once a virtual DOM is in it, against Elm's 109 530 B,
and says plainly that it is *"an estimate from the column above, not a measurement"*. **Resolution:
the 5 kB figure is not a browser budget and must not be quoted as one; W11 asks for the browser
number and names the measurement.**

---

## Tier 1 — must be answered before a browser-platform spec can be written

Nine, all low-reversibility. W1 and W5 are the two everything else waits on.

### W1. Is The Elm Architecture the blessed architecture, and what shape is a command?

**The situation.** In Elm, `update` is a pure function that returns a new model plus a *description*
of work to do; the runtime performs the work and sends the answer back as another message. Under
beni's effects design there is no such description — `getUser id` just performs. So the question is
whether the four-function shape (`init`, `update`, `view`, `subscriptions`) survives, and if it does,
what a program hands back when it wants something done.

R25 worked one example — a search box that debounces, cancels the stale request, and optimistically
toggles a favourite — through five architectures (R25 §2, §3–§7). Two of them break: an `update` that
may itself suspend either freezes the text input for the length of an HTTP request, or lets two
keystrokes race and silently lose one (R25 §4.1–§4.2). The remaining three keep `update` pure and
`sync`, and differ only in what a command is:

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

**Options.** (a) the thunk-plus-tagger form only; (b) the `send` form only; (c) the `send` form, with
(a) defined over it — `run task tag = perform (\send -> send (tag (task ())))`, four lines.

**What each costs.** (a) is smaller but cannot express progress, streaming or "start two requests and
report each as it lands" without a second mechanism. (b) makes the common case wordier. (c) costs one
extra constructor. Two independent TEA descendants — TCA and Lustre — converged on the `send` shape
(R25 §5.1).

**Recommendation: (c)**, which is R25 D1's. The ranking behind it is R25 §0: option C is the only
shape where the model provably cannot race with itself, and the thing that proves it is `sync` on
`update` — a check already decided (A6). Everything Elm guarantees survives; `boundary.md` §5.4's
`Cmd.run` becomes sugar rather than a rival.

**Three riders come with the answer**, and the owner is agreeing to them at the same time:

- **`sync` is on five signatures**: `init`, `update`, `view`, `subscriptions` and every event handler
  and tagger (R25 §3.7, §9.1). R24 §0.5 question 2 asked whether `update` is included; R25 §4.3 is
  the argument that it must be, and it is stronger than the one R24 offered (see disagreement 1).
- **`view` returns a data tree the platform renders** — a virtual DOM. No document in `docs/design/`
  specifies one (`boundary.md` §5.3 names TEA and stops); this is where it gets decided. How much of
  it is beni and how much JavaScript is W10.
- **The architecture is a library on a small kernel, not the language** (R25 §10): a root scope tied
  to the mount, a `sync` pure render, a `sync` event→fiber bridge, scoped subscriptions, one
  frame-aware loop. TEA ships blessed; nothing else is forbidden.

**Rule 7 check.** This refuses one thing: `update`, `view` and handlers may not suspend. It buys
three guarantees — every message applied to the model atomically (no lost update), a render that
cannot be half-done, and `preventDefault`/`stopPropagation` that actually work. All three are
rule-7 guarantees; the restriction is paid for.

**Reversibility: low.** It is the type of every command in every program.

---

### W2. What does a defect do to a page?

**The situation.** A1 decided that defects — a `foreign` that throws, a stack overflow — are fatal:
the process dies loudly with a report and a non-zero exit, because JavaScript fibers share a heap, so
containing a defect means running on state nobody can vouch for. **A page has no process to kill.**
R26 §7.1 measured it in Chrome and Firefox: an uncaught throw inside a `MessageChannel` task, a rAF
callback, an event listener, a microtask or a timer **kills nothing** — the next task runs, the next
frame runs, the sibling listener on the same element still runs, the event still bubbles, pending
timers still fire, the DOM is still mutable. `window.onerror` sees it, and that is all. A stack
overflow is a catchable `RangeError`. Elm's own runtime fails worse: a throw leaves its scheduler's
`working` flag set forever, so the application is silently wedged with no message anyone sees (R24
§3.5).

So "fatal" in a page is a thing the platform must *implement*.

**Options** (R26 §7.2, R25 §9.5): (a) **stop the scheduler** — a `dead` flag every fiber resume,
listener and rAF callback tests; ~10 lines, the page freezes but stays on screen. (b) **(a) plus tear
down the mount** — remove every listener and close the root scope, so finalisers run and requests
abort; ~30 lines. (c) **(b) plus a crash screen**. (d) `console.error` only — Elm's effective
behaviour, invisible to a non-developer. (e) an optional `onDefect : Report -> ()` hook.

**What each costs.** (a) is not optional: without it the *other* fibers keep running on state A1 says
cannot be trusted, and R26 §7.1 shows the browser will happily let them. (b) costs a constraint on
the platform's API — it must own every `addEventListener`, so teardown is one `AbortController.abort()`
(R26 §6.3) — which is worth adopting anyway. (c) has a **size** cost: a crash-screen string table is
exactly what `Reach.zig` cannot see is live, and `--release` has just been tuned to a 789-byte brotli
floor. An **error boundary** per subtree, the React answer, is rejected on A1's own reasoning:
containing a defect is continuing on unvouchable state (R25 §9.5).

**Recommendation: (a)+(b) always, (c) in development builds only, (e) as a later addition.** And a
sub-question that needs an answer either way: **what replaces the non-zero exit code**, because the
test harness needs one to assert on (R26 §7.2, §9.1). The cheap answer is a platform-defined global
the page sets, which is what R26 §9.1's measured harness used.

**Rule 7 check.** Halting refuses to keep going, which is a refusal — and it buys "no silent wrong
answer", which is on rule 7's list. The escape hatch is (e): an application that wants to log and
limp may supply a hook. Note this is *more* than a Node process gets, because finalisers run.

**Reversibility: medium.** (a)+(b) are behaviour; (c) is a build-mode flag.

---

### W3. The browser scheduler's default budget and primitive — and P2 §7.5's microtask tier

**The situation.** A fiber runtime that never gives the browser its thread back freezes the page —
which is exactly what Elm's does (R24 §3.3: 372 ms, zero frames). So a fiber must stop periodically
and hand control back. Two choices: *how* it hands back (which browser primitive) and *how often*.
P2 §7.5 says: run continuations in microtasks for throughput, escape to a macrotask every 64
resumptions. R26 measured that design and it is wrong in both halves.

**The measurements** (Chrome 153 headless unless a Firefox column is named):

- A fiber yielding through **microtasks** every 64 ops had input-handler latency of **p50 371 ms,
  max 653 ms** — *worse* than the same fiber that never yields at all (p50 84, max 364), against
  **p50 0 ms, max 1 ms** for `MessageChannel` at every budget from 16 to 8 192 (R26 §3.2). A
  microtask checkpoint never reaches input, timers or rendering, so the loop pays and buys nothing
  (R26 §2.3, both engines).
- Microtasks buy **no throughput** either once the slice is ≥0.12 ms: 1.00–1.02× against
  `MessageChannel`'s 1.02–1.05× (R26 §3.4). There is no trade here to make.
- **Input latency p90 ≈ the slice length** from 2 ms up: 0.24 ms → p90 1 ms; 7.8 ms → 5 ms; 31 ms →
  26 ms; 125 ms → 102 ms and the first long task (R26 §3.3).
- A macrotask yield costs **2.6–4.4 µs** in Chrome, **2.1–2.3 µs** in Firefox — 0.3 % at a 1 ms slice.
- `setImmediate` **does not exist** in either engine, so Effect v4's Node knee of 512 does not
  transfer; and an op count is a proxy for a slice with a per-program constant that varies 40×
  (R26 §2.1, §3.3).

**Options.** For the rule: (a) an op count, as P2 §7.5 and r21 §9.3 have it; (b) a pure time slice,
reading the clock every op; (c) a hybrid — count `k` ops, then read `Date.now()`. For the primitive:
(a) `MessageChannel`; (b) `scheduler.postTask` at `user-visible`; (c) `scheduler.yield()`.

**What each costs.** (b) for the rule is unaffordable — 33–50 ns of clock per 465 ns op is 7 % — and
unenforceable below the clock's resolution (100 µs Chrome, **1 ms Firefox**). `scheduler.yield` and
`postTask` at `user-blocking` **starve the page's own timers and channels completely** (an armed
timer fired at 282 ms in a 275 ms run), because a yielded continuation is scheduled ahead of
same-priority tasks by design (R26 §3.1). `setTimeout(0)` is clamped to 4 ms and costs 9.7×.

**Recommendation: the hybrid, `k = 256` ops between clock reads, a 1 ms slice, through
`MessageChannel`** (R26 Q1, Q2). 1 ms is the smallest slice *measurable* in both engines, costs
0.03 % for the clock and 0.35 % for the yield, and gives input p90 of 1 ms. A 5 ms slice is also
defensible — it is the RAIL frame budget — and trades 4 ms of input latency for 0.25 % of
throughput, which there is nothing to buy with. The number lives in A7's **scheduler slot**, so it is
a platform constant, not a language decision.

**And the second half of this question: P2 §7.5's two-tier design is withdrawn, not tuned.** The
proposal's premise — that microtasks are the throughput path and the macrotask is an escape — is what
the measurement contradicts. There is one tier: a macrotask every slice. This needs an edit to P2
§7.5 (see *What the browser pass changes*, below).

**Reversibility: high** for the number (a slot), **low** for the withdrawal of the two-tier design,
which is a rewrite of a specification section.

---

### W4. Must `view` be pure as well as `sync`? — or does `lazy` stay parked?

**The situation.** Elm's `Html.lazy` is a render optimisation: *"if these arguments are the same
objects as last frame, skip calling the view function and reuse last frame's tree."* R24 §6.8 read
its implementation: it compares arguments by JavaScript reference equality and, if they match, adopts
the previously rendered node.

That is a licence to **drop a call** — and A5 has just decided that `impure` revokes exactly that
licence. So a `view` that reads a mutable cell and a `lazy` that skips the read is a silent wrong
answer, rule 7's worst class. R25 §9.1's consequence: if memoisation ships, `view` must be *not
`impure`* as well as *not `suspends`* — a **second demand in argument position** beside `sync`.

**One clarification, because R25's wording invites a misreading.** A function type already carries
two bits (`impure` and `suspends`, P2 §2). What is asked for is not a third bit on the type; it is
that an *argument position* can demand both be false, where today only `sync` is planned (A6;
`plans/effects-plan.md` §2.5 priced one bool). The cost is one more `Interface.Term.Tag` value, one
more obligation kind and its discharge arm, and a `language.md` sentence.

**And a second, larger price nobody has paid.** `lazy` only works if the language promises that an
untouched field of an updated record keeps its identity. R24 §6.8 checked: it holds today by
construction — record update emits a spread, and `Opt.zig` inlines only single-use bindings and never
duplicates — but **it is nowhere promised**, and Elm never wrote it down either. Un-parking `lazy`
means putting a reference-identity guarantee into `language.md` §6 that constrains every future
optimiser pass, for a performance feature.

**Options.** (a) two demands, and `lazy` is sound; (b) one demand, no `lazy` and no render
memoisation; (c) one demand, `lazy` offered anyway and documented as unsound for an impure view.

**Recommendation: (b) for now**, which is C9 unchanged — `lazy` is parked until a browser platform
*and a real application* want it, and the application does not exist. Nothing in the three reports
measures a need: R24 §12 is explicit that the diff's cost on a realistic tree was never measured.
**(c) is a rule-7 violation and should be refused in writing.** Revisit at W10's measurement.

**Rule 7 check.** (b) refuses nothing; it withholds a feature and says so, which is the honest form.

**Reversibility: (b)→(a) is additive and cheap** as long as the interface encoding is not frozen
against it; (c) is not reversible, because the unsoundness ships in user code.

---

### W5. The render loop: how many phases, and what triggers a synchronous render?

**The situation.** Three separate things are usually confused, and Elm confuses two of them in one
bit. The browser forces all three.

1. **One render per frame.** R24 §6.9 measured five messages delivered in one JavaScript loop
   producing exactly **one** DOM update, on the next frame. No architecture dodges this.
2. **Except where the DOM holds its own state.** Elm's own text: *"if `stopPropagation` is used, we
   update the DOM immediately… This is useful for DOM nodes that hold their own state, like
   `<input type="text">`. If someone types very fast, the state in the DOM can diverge from the state
   in your `Model` while waiting on the next `requestAnimationFrame`."* Measured: five
   `stopPropagation` clicks produce five synchronous renders, inside the dispatch. **And the trigger
   is an accident** — R24 §6.6 found the comment `// stopPropagation implies isSync` and calls it two
   unrelated concerns sharing one bit.
3. **Some effects must run after a render.** `Browser.Dom.focus` and every viewport read wrap
   themselves in a `requestAnimationFrame` so the node the program just described exists before it is
   looked up (R24 §8.2) — unconditionally, so every DOM read costs a frame even when the node has
   existed for minutes. Under beni it is sharper: an effectful call in `update` runs *before* the
   re-render, so the naive `Dom.focus "search"; { model | showing = True }` works whenever the node
   already existed and fails when it did not (R24 §8.3). R25 D8 adds Lustre's evidence — three phases
   for focus, measurement and scroll restoration — and the rule that **a library cannot add a phase
   the kernel does not have**.

R26 constrains phase 3: a rAF callback that suspends resumed 10.1 ms later and its write landed in
the *next* frame (§5.4), and interleaving DOM reads with writes over 3 000 nodes cost **2 846 ms
against 2.5 ms batched — 1 139×** (§5.5). So whatever runs after a render is `sync`, and the patcher
must not interleave measurement with mutation.

**Options.** (a) one phase — render on the frame, and hide the rAF inside each DOM capability as Elm
does; (b) two — the frame render plus an explicit after-render suspension point a command can await
(`Browser.afterRender ()`), with a separate explicit "render now"; (c) three, Lustre's.

**What each costs.** (a) costs a frame on every DOM read forever, and makes the ordering invisible and
therefore unexplainable when it goes wrong. (b) costs one concept and is exactly what a fiber runtime
with a real suspension primitive is *for* — and it can be cheaper than Elm, because `afterRender`
can return immediately when no render is pending. (c) is one more phase than any evidence here
demands.

**Recommendation: (b), with the three things named separately.** One render per frame; an explicit
`Browser.renderNow ()` (or a handler-level flag that is *not* `stopPropagation`) for the controlled
input case; one after-render suspension point. This is R25 D8's "(b) at minimum" plus R24 §6.6's
warning honoured.

**Rule 7 check.** Nothing is refused: `renderNow` is an escape hatch, and `afterRender` is a
capability rather than a restriction.

**Reversibility: low.** A phase the kernel does not have cannot be added by a library.

---

### W6. Subscriptions: declared from the model and diffed?

**The situation.** A program that listens to the window's size, or a clock, has a *resource with a
lifetime*. Elm's answer is `subscriptions : Model -> Sub Msg`, recomputed after every message, with
the runtime diffing the new set against the live one — kill what left, start what arrived (R24 §5.2
has the twenty lines). What it buys is precise (R24 §5.1): **there is no `unsubscribe` in user code
anywhere in Elm**, a subscription cannot leak because "still wanted" is re-derived rather than
remembered, and it cannot be duplicated because a set is a set. R24 §0.3 calls it *the one TEA
property with no obvious replacement under transparent effects*.

The counter-evidence is Lustre, a TEA framework on a typed functional language that shipped with no
subscriptions at all: `window.add_event_listener` inside an effect is the documented idiom, the
callback's return value is discarded, and **there is no unregister path** (R25 §0, §8.3). It leaks by
construction and nobody seems to mind.

**Options** (R24 §4.4, R25 §9.4): (a) keep the declared-and-diffed set, with each live subscription a
**scoped fiber** whose finaliser removes the listener; (b) no `Sub` — a subscription is started by a
command and cancelled by key, like everything else; (c) Lustre's answer, no lifetime at all.

**What each costs.** (a) costs recomputing a small description after every message — Elm pays this
and so does Iced, which hashes each recipe and `retain`s the live ones (R25 §8.4). (b) costs the
author writing the stop, which is precisely the property R24 §0.3 says is the hard one to replace;
rule 7 says to say that out loud rather than call it flexibility. (c) is a measured mistake.

**Recommendation: (a)**, composing both mechanisms: the declared set makes "what am I listening to" a
pure function of the model and therefore testable, and the scoped fiber makes the leak
*unrepresentable* — closing the scope runs the finaliser, and A1 has already decided finalisers are
infallible and the interrupter waits for them. One thing comes with it: **a subscription's identity
is a value**, so the key must be `compare`-able and derivable, so that `Browser.onResize Resized` and
`Browser.every (Duration.seconds 1) Tick` are distinct by value (R25 §9.4).

**Rule 7 check.** This is not a refusal *provided* the platform also lets a command start a
long-lived listener in a scope — a listener whose lifetime is not derivable from the model (a
WebSocket owned by a page, say) must still be expressible. Ship both; bless the `Sub`.

**Reversibility: medium.** Adding `Sub` later is additive; removing it is not.

---

### W7. Are command keys namespaced, and by what?

**The situation.** `boundary.md` §5.4 already specifies keyed cancellation: `Cmd.keyed k Policy …`
with four policies (`Restart`, `Ignore`, `Queue`, `Concurrent`), the runtime holding a map from key
to fiber. §5.4 leaves one thing open: *"whether keys are global with callers namespacing their own
strings"*.

**Here is the bug that leaves in.** Two instances of the same reusable component — two search boxes
on one page — both return `Cmd.keyed SearchKey Restart …`. The parent wraps both with `Cmd.map`.
They now share a bucket, and **each one cancels the other's request**. Nothing in the type system
notices. This is rule 7's silent-wrong-answer class arriving through the front door, and it is not
hypothetical: it is exactly why TCA registers every cancellable under **every prefix** of a
navigation path (R25 §5.5, §9.8, citing `Cancellation.swift:251-260`).

**Options.** (a) global keys, callers namespace their own strings — today's §5.4 text; (b) `Cmd.map`
pushes a path segment onto the command's key path, the runtime's table is keyed by the path, and
`Cmd.cancelAll` cancels a prefix; (c) keys are `String` only.

**What each costs.** (b) costs one field on the opaque `Cmd` and is unavailable later without a
breaking change. (a) ships the wrong answer at the second reusable component; (c) ships it
immediately, because a mistyped string silently never cancels. (b) buys a second property for free:
a parent can cancel an entire subtree of work with one call — which is what "dismissing this screen
aborts everything it started" means.

**Recommendation: (b)**, with the key type a `compare`-able value and the documented idiom a
program's own `Key` ADT rather than a string. Note one correction to `boundary.md` §5.4 while it is
open: it says *"k equatable"*, and the runtime's table is a `Dict`, which takes `compare` — so the
constraint is `where k.compare : k, k -> Order` (R25 §3.1).

**Rule 7 check.** Nothing refused; a silent wrong answer removed.

**Reversibility: low.** It is in `Cmd`'s representation.

---

### W8. How does JavaScript call back into beni, and what is `sync` attached to?

**The situation.** Every event in a browser arrives on the browser's own stack: `addEventListener`
runs *your* function, inside its dispatch, and reads `preventDefault`/`stopPropagation` when it
returns. So the browser platform needs a `foreign` that **registers a callback and later calls it** —
a direction `boundary.md` §4 says nothing about. Its four checks are about a `foreign`'s type, its
sibling's exports, its sibling's imports, and the export's arity; none of them can see that a sibling
holds onto a beni closure and invokes it from a listener (R24 §4.4 option (b) names this as *a
boundary-spec gap, not just a design choice*).

And R26 §5.1 measured why it matters: hop a handler through one macrotask before calling
`preventDefault()` and **the link navigates and the form submits anyway**, while
`event.defaultPrevented` still reads `true`. The mistake is undetectable at run time; it has to be
prevented by a type.

**Options** (R26 Q4): (a) the language marks a function `sync` and the checker rejects suspension
inside it; (b) the platform's registration primitives take a `sync` function type and nothing else
can be passed.

**Recommendation: (b), with (a) as the mechanism that makes (b) checkable** — A6 plus one rule in
`boundary.md` §4: **a `foreign` that receives a beni function the sibling may invoke must declare
that parameter `sync`**, checked the way check 4 is checked (count what is declared; do not parse the
JavaScript). The registration points that need it are R26 §0.2's list: every DOM event listener the
platform installs, and every `requestAnimationFrame` callback.

**A related design point worth taking at the same time.** Elm keeps a *stable* JavaScript callback
whose handler is a mutable field, so a view that allocates a fresh handler every frame causes
**zero** add/remove pairs; only a change of handler *variant* re-registers, because the variant
decides the `passive` flag (R24 §6.6). beni cannot compare two closures for equality, so this is not
an optimisation for beni — it is the only workable design, and the node representation must carry
the handler's variant (`Normal` / `MayStopPropagation` / `MayPreventDefault` / `Custom`) as data
beside the closure.

**Rule 7 check.** Refusing a suspending handler buys `preventDefault`, `stopPropagation` and a
renderer that cannot be caught mid-frame. A handler that wants to do slow work spawns a fiber and
returns, which is a capability, not a workaround.

**Reversibility: low.** It is in the type of every platform registration function.

---

### W9. What is `main` in a page, and what replaces the exit code?

**The situation.** A8 settled `main : Program`, its body must not suspend, reference-counted
keep-alive, and exit codes 0 / 1 / 130. **All three are Node notions.** A page never exits, has no
exit code, and keep-alive is meaningless because the page is alive until the user leaves. R24 §0.5
question 3 asks it; R26 §7.2 asks it again from the harness side, because a browser corpus fixture
needs *something* to assert on. (A related question nobody has asked: whether two beni programs on
one page share one runtime, where Elm merges a global and crashes on a collision — R24 §2.6. That is
W23, a chunking question.)

**Options.** (a) `Program` is the platform's opaque mount descriptor and keep-alive is meaningless;
(b) the page's "exit" is an unhandled fiber death, which goes to W2's teardown; (c) both, with a
platform-declared `runtime` per `boundary.md` §5.2.

**Recommendation: (c), and `main : Program` is unchanged.** The browser platform's `Program` is what
`Browser.element`/`Browser.document` return; the platform's `run(main)` mounts it; keep-alive is
stated as a Node-only concept in the spec rather than silently dropped; and the **harness reads a
platform-defined global** (`__EXIT`-shaped) plus the page's text and console stream, which is what
R26 §9.1 measured at 10 ms per fixture. The ~70 `run/` fixtures that write `main : Program` are
untouched, which was A8's reason for choosing it.

**Rule 7 check.** Nothing refused.

**Reversibility: low for `main`'s type** (corpus-wide), high for the harness convention.

---

## Tier 2 — answered by a measurement

Each names the measurement. Two of them have already been taken, and are marked so; the rest name the
browser slice (`B0`…) in [`plans/browser-platform.md`](browser-platform.md) §3 that takes them.

| # | Question | Measurement | Recommendation |
|---|---|---|---|
| **W10** | **How much of the virtual DOM is written in beni?** R24 §6 establishes that the diff leans on three things beni does not have: a reference-equality short-circuit (`x === y` skips a whole subtree, R24 §6.4), a mutable patch array with traversal indices, and a structural comparison of two event decoders. The ambition is to write the *diff* in beni and leave render, patch, events and rAF in JavaScript | **B2**: build both halves and measure bytes and diff time against Elm's 29 782 B / 1 589 lines. R24 §12 records that the diff's cost on a realistic tree is **unmeasured**, so there is no prior number to beat | Write the diff in beni; keep patch/render/events/XSS in JavaScript. Accept losing the reference-equality short-circuit unless W4 blesses a `foreign refEq`, and state what that costs (an unchanged shared subtree stops being free) |
| **W11** | **How much runtime may a browser program ship?** Elm's floor is 109 530 B raw / 22 723 brotli for a counter, of which **0.9 % is the user's code** and 75.9 % is hand-written kernel JavaScript (R24 §11.1–§11.2). beni's floor today is 2 147 B raw / 833 brotli with no runtime at all. R24 §11.4 estimates a beni counter at 35–50 kB raw and says it is an estimate, not a measurement | **B1** then **B2**: the empty mounted page, then the counter, dev and `--release`, with `bench/size.mjs` | Measure first, set the number after B2. Do **not** quote effects' ≤ 5 kB gzip budget as a browser budget — it covers the fiber kernel only (see disagreement 6) |
| **W12** | **Does the scheduler use `isInputPending`?** It buys a **45× cut in yield count at identical input latency** (37 yields against 1 651), but uncapped it produced an **82 ms long task** — it answers "is there input", not "does the page need the thread". Chrome-only; absent in Firefox 156 (R26 §4.1–§4.3) | **B4**, re-taken with a real beni fiber: R26's work unit was a 465 ns stand-in and every op-count figure has to be re-derived (R26 §12 item 8) | Yes, capped by the time slice, behind a capability check — as an optimisation, never as the rule (R26 Q3) |
| **W13** | **Does the single-file bundle move ahead of chunking in M3d?** | **Already measured** (R26 §8.2): one bundle reaches `main` in **358 ms on 4G against 1 059 ms** for 13 modules, and 1 156 ms against 3 437 ms on fast 3G — **3.0×** both times, from round-trip depth rather than bytes. HTTP/1.1 only; §12 item 5 notes H2 would narrow the `modulepreload` row but not the bundle row | Yes. `backend.md` §10 already states that with one entry point and no `lazy` a release build is exactly one file; the degenerate case needs none of §10's PENDING decisions |
| **W14** | **Is sibling JavaScript minified in a release build?** Sibling `.foreign.mjs` files are **71.6 %** of `Dictionaries`' raw bytes and are never minified; whole-line comments are **42 %** of the tree. Bundling with minification takes it 6 380 → **3 269** brotli (R26 §8.3) | **Already measured** (R26 §8.3). What is *not* measured is the interaction with W2: minifying `core/`'s hand-written JavaScript makes a defect report point into text nobody can read | Open, and it is the owner's: the size win is large and `boundary.md` §4 constrains only the siblings' *exports*, not their formatting — but it collides with W2(c) and with the debugging bar. A middle answer: minify in `--release` only, and have the defect report name the `foreign` rather than quote it |
| **W15** | **What does the corpus's browser kind use for time?** CDP virtual time ran **five chained 10-second timers — 50 000 ms — in 0.9 ms of real time**, with no cooperation from the program, and it covers `setTimeout` inside a `foreign` sibling that beni's own clock slot cannot see (R26 §9.3) | **B0** | Both, virtual time by default. The clock slot (A13) stays for beni-level tests of beni code |
| **W16** | **Is a `TestStore`-shaped driver part of the platform?** R25 §9.6 sketches one and TCA's two end-of-test assertions are worth copying: *"the store received N unexpected actions"* and *"an effect returned for this action is still running"* — the second is only checkable because the runtime knows what is in flight, which Elm's does not | **B5**: the typeahead fixture under a fake clock and a fake `Api` is simultaneously the architecture proof and the `TestStore` design | Yes, in the platform. Without it the corpus cannot test cancellation, which is the feature the whole lowering was chosen for |

---

## Tier 3 — can wait, and what each waits for

| # | Question | Waits for | Note |
|---|---|---|---|
| **W17** | Where is `sync` written on an annotated declaration — on the annotation like `pub`, or on the definition as P2 §3.2's grammar has it? | the effects spike's S2/S3 grammar | Recommend the annotation: `sync` is part of the type and the annotation is where the type is (R25 D4). Cheap now, formatter-and-corpus churn later |
| **W18** | May a `sync` function await a *microtask*? | the same | Recommend **no**. R26 §5.1 measured that a microtask hop is currently in time for `preventDefault` — and it is still the wrong rule, because whether a call suspends only through a microtask is not something a caller can see (R26 Q5) |
| **W19** | Does the runtime get a general fiber-local, restored at every resumption — and therefore, can a signal / fine-grained-reactivity library exist? | someone wanting fine-grained reactivity | A7 bought three fixed slots and declined a general `Context`. Without a fourth, a signal library is *silently* wrong: reads after a suspension are untracked, which is Solid's behaviour today (R25 §7.3, §10.3). Recommend (a) for v1 and **say in the spec that this architecture is out of reach until the slot lands**, rather than claiming the kernel is architecture-neutral |
| **W20** | Is a component / local-state library forbidden, unshipped, or shipped? | a second real application | Recommend unshipped, and the kernel checked not to exclude it. Forbidding it is taste: `Ref` is already T0, so the read-modify-write hazard is in the box whether or not a component library exists (R25 §6.4) |
| **W21** | Is a time-travel debugger a goal? | W1, and a user asking | R24 §10.3's finding: the debugger is not a feature Elm added, it is a *consequence* of one model cell plus a pure `update` plus messages as data. W1's recommended answer keeps all three, so the option stays open at no cost. Elm's costs 3 442 lines and 2.5× the bundle in `--debug` |
| **W22** | Is hydration of server-rendered HTML a requirement? | a server-rendering story | Cheaper to design in than to add (R24 §6.10, §0.5 q5). The cheap insurance is to keep "build a tree from existing DOM" separable in the renderer's design without building it. Also worth knowing: `Browser.element` **destroys the node you give it** (R24 §6.10, found while instrumenting) |
| **W23** | Two beni programs on one page — one runtime or two? | chunking (`backend.md` §10) | Elm solves it with a global merge and a crash on collision (R24 §2.6); beni's `runtime` manifest key supersedes the mechanism but nobody has asked the question |
| **W24** | Child-owned state: the parent owns the child's model (Elm), or a custom element with its own runtime (Lustre)? | a component story, W20 | Lustre's is a real answer Elm does not have — child state with the DOM as the message bus — and it costs a custom-element boundary (R25 §8.3, §9.8). Also record, so it is stated rather than discovered: a heterogeneous page is a `case` over a `Page` ADT, because a list of "things with an `update`" needs existential types beni does not have and static dispatch does not rescue (R25 §9.8) |

---

## What the owner's existing decisions already settle

So that nothing is asked twice.

| Already decided | What it settles for the browser |
|---|---|
| **A6** — `sync` ships in the first cut | The whole of R26 §0.2's list has a mechanism. `boundary.md` §5.4's written promise that `update` and `view` are checked stops being conventional. R25 §4.3 supplies a *second*, stronger reason than the boundary one: it is a concurrency proof |
| **A7** — services are records of functions and `where` clauses | Elm's `Navigation.Key` — an opaque phantom whose only job is to be unforgeable — becomes an ordinary record whose fields *are* the operations (`nav.pushUrl url`), which is both simpler and, unlike Elm's, testable with a fake (R24 §7.3). Every capability in the platform is injected this way, and every test fake is a record literal. One asymmetry to preserve: Elm's `load`/`reload` take no `Key`, because a full page load cannot desynchronise a router that is about to be destroyed |
| **A7** — three fixed per-fiber slots, one of them the **scheduler** | W3's browser default lives in the scheduler slot, so it is a platform constant. `scheduler.postTask` and `scheduler.yield` become alternative slots rather than rivals (R26 §0.1) |
| **A1** — finalisers infallible, the interrupter waits, children first | Scoped subscriptions are leak-free *by construction*: closing the mount's scope removes every listener and aborts every request, and the caller waits (R25 §10.1). No JavaScript framework offers this |
| **A1** — `Exit a = Done a \| Cancelled`, interruption invisible to the interrupted code | A stale response **cannot land** — the continuation is gone, so it is not "ignored", it does not exist. A send from an interrupted fiber is dropped rather than an error (R25 §5.1) |
| **A5** — `impure` is used from the slice that infers it | It is what makes W4's `lazy` question a real question rather than an accident; and `Opt.zig`'s single-use inlining, the one transform that would silently break dependency tracking, is already forbidden from doing so (R25 §7.2) |
| **A8** — `main : Program`, body `sync`, work spawned inside it | The browser keeps the type and the rule. Only the exit/keep-alive half is undefined, which is W9 |
| **A13** — a swappable clock and scheduler | 250 ms of debounce costs no wall time and resumption order is fixed, which makes R25 §9.6's typeahead assertable with no browser |
| **`boundary.md` §3.1 / milestone B3** — ports, a generated codec, a depth bound, a decode error **as a value** | Interop is specified and the browser inherits it — already better than Elm, whose incoming-port decode failure is a `__Debug_crash`, the one place Elm's no-runtime-exception claim rests on a runtime check (R24 §0.2 item 8, §9.4). Keep the distinction in the spec: a bad payload is malformed input from outside the wall, not a defect in A1's sense |
| **`boundary.md` §5.2** — the `runtime` manifest key | Elm's `_Platform_export` has no analogue to build (R24 §2.6) |
| **`boundary.md` §7.1** — one export per `foreign`, one graph node per `foreign` | Elm's kernel DCE is per *file*, which is why `elm/url` ships 3 144 B into a counter with no URLs and `Debug.js` ships 7 265 B into an `--optimize` build — 7.5× the user's whole program (R24 §11.3). Already beaten |
| **`--release` refuses `Debug`** | Interacts with W2(c): a crash screen's strings are what `Reach.zig` cannot see is live, which is why the recommendation gates the screen on the development build |
| **C9** — `lazy` is parked | Is W4's recommended answer, unchanged. What the pass adds is the *price* of un-parking: a reference-identity guarantee in `language.md` §6 (R24 §6.8) |
| **C6** — `Cmd`-level cancellation before the browser ships | W1 and W7 are that work. R25 §9.2 confirms §5.4's four policies: they are RxJS's four `*Map`s, and four independent systems each shipped exactly one of them — `Restart` |
| **Rule 7** and the stance of 2026-09-19 | Applied to every recommendation above that refuses anything. Two refusals survive it: `sync` on the five signatures (W1, W8) and halting on a defect (W2) |

---

## What the browser pass changes in decisions already taken

Honestly, with what would have to be re-written where. **Nothing in this list has been edited** — the
manager folds the cross-references in after the owner answers.

| Decision | What the browser pass does to it | Where it would be re-written |
|---|---|---|
| **A8** (`main`, exit codes, keep-alive) | It has only a Node half. A page never exits, has no exit code, and keep-alive is meaningless | `plans/effects-decisions.md` A8's row and the queue's A8 row; `plans/effects-spike.md` §0.3's A8 row; `boundary.md` §5. W9 |
| **A1** ("defects are fatal", non-zero exit) | *Fatal* has no browser mechanism at all — R26 §7.1 measured that a throw kills nothing, identically in Chrome and Firefox. The platform must implement it | `plans/effects-decisions.md` A1's row gains a browser paragraph; queue rows 52–54 (the `throw` check, the hostile-input suite, the crash reporter) gain a browser column. W2 |
| **P2 §7.5** (two-tier scheduling, microtasks for throughput, escape every 64) | **Withdrawn for the browser.** The premise is contradicted: microtasks buy 0–3 % throughput above a 0.12 ms slice and cost up to 653 ms of input latency. There is one tier | `transparent-effects-proposal.md` §7.5 rewritten (rule 2: no renumbering); `plans/effects-decisions.md` B1's row; `plans/effects-spike.md` E-M10. W3 |
| **P2 §6.6** ("what this does to The Elm Architecture") | Superseded. It makes one claim — `update` stays pure, commands stay inert — and defers everything else to `boundary.md` §5.4. R25 is the replacement page and §5.4 predates the effects decisions | `transparent-effects-proposal.md` §6.6 replaced by a pointer to the browser platform spec; `boundary.md` §5.4 rewritten (keys as paths, `compare` not `eq`, the `send` shape, the four policies kept) |
| **`plans/effects-plan.md` §2.5's one-bit budget** for an argument-position effect demand | Two demands if W4 is answered (a). One more `Interface.Term.Tag` value, one more obligation kind | `plans/effects-plan.md` §2.5; `checker.md` §7; `language.md` (the `sync`/purity rule). W4 |
| **C9** (`lazy` parked) | The parking condition was *"until a browser platform and a real application want it"*. The browser platform is now the plan; the application is not. What the pass adds is the price: an identity guarantee in `language.md` §6 | `plans/effects-decisions.md` C9's row; `language.md` §6 if un-parked. W4 |
| **B1** (the yield budget) | The browser half is answered — and it turns out the axis is input latency, not the rAF histogram `research/16` §6 asked for: rAF is satisfied by *any* macrotask yield at any budget tested | `plans/effects-decisions.md` B1; `plans/effects-spike.md` E-M10, whose browser half is now done **except** for a re-take with a real beni fiber (R26 used a 465 ns stand-in) |
| **`plans/effects-spike.md` §1.3** — *"The Elm Architecture… **Out of scope**"* | Reversed by the browser-first decision, which `plans/queue.md` already records. TEA is now the central question and this sheet is its answer | `plans/effects-spike.md` §1.3 |
| **`plans/effects-spike.md` S5** — the kernel lands *"in `platforms/node/`"* | The kernel must be platform-neutral with the **browser** as its first real host; the scheduler default is the browser's, not Node's | `plans/effects-spike.md` S5 and its §0.3 rationale |
| **`boundary.md` §7.1** — *"roughly 45 % of Elm's TodoMVC bundle is hand-written runtime"* | Measured: **71.9–75.9 %** for small programs, with the user's own code under 1 % (R24 §11.2). §7.1's number is right for a program with a lot of Elm in it; the floor is much worse | `boundary.md` §7.1 |
| **`boundary.md` §5.3** — *"Browser: The Elm Architecture. `init`, `update`, `view`, `subscriptions`, ports."* | Gains the command shape, the renderer, the kernel and the defect behaviour | `boundary.md` §5.3 |
| **`boundary.md` §4** (the four checks) | Gains a rule for a `foreign` that receives a beni function and calls it back — the direction the wall has never had (R24 §4.4) | `boundary.md` §4. W8 |
| **`backend.md` §10** (chunking) | The degenerate single-file case gets a latency number (3.0× to `main` on 4G) and a reason to move ahead of chunking | `backend.md` §10; `fast-compiler.md` §13's build order. W13 |
| **`plans/queue.md`** rows 51–55 | Re-weighted: 51 (a shipped program cannot log) is unchanged; 52/53 apply to a browser platform exactly as to Node; **54 (the crash reporter) becomes the defect screen** and acquires W2; 55 is untouched | `plans/queue.md` |

---

## What this sheet does **not** decide

Recorded so nobody reads silence as agreement: Safari is entirely unmeasured; input latency is
Chrome-only; every op-count figure rests on a 465 ns stand-in rather than a real beni fiber; nobody
has measured a virtual-DOM diff on a realistic tree, in Elm or anywhere else; and no measurement here
was taken on a page with a compositor, CSS animations and a patch pass in it. Each is ranked with the
cheapest experiment that would retire it in
[`plans/browser-platform.md`](browser-platform.md) §5.
