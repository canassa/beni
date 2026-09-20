# Elm's browser runtime, as built: what each piece is FOR

**Commissioned by** the project owner, 2026-09-20 — `plans/queue.md`'s *"un-park for RESEARCH only —
a design pass on 'what is a beni browser program?'"*, report **B-R1** of three. It follows the owner's
decision of 2026-09-19 that **beni is primarily a browser language and the browser platform comes
before Node** (CLAUDE.md, *Target*), which moves *"what replaces The Elm Architecture under
transparent effects"* from a non-objective to a central question.

**What this is.** Elm's browser runtime is ~3–4 k lines of hand-written JavaScript and Elm that every
Elm program ships. beni will need a browser platform. Before designing one, this report establishes,
for every piece of Elm's: what it does, what problem it solves, how big it is, and — the crux —
**whether it exists because of the BROWSER** (beni needs an equivalent), **because of ELM'S EFFECT
MODEL** (`Cmd`/`Sub`/`Task`/effect managers, which beni has deleted, so the piece may vanish or
change shape), **or because of Elm-the-ecosystem** (the debugger, the kernel-code policy).

**What this is not.** It is not a design. It proposes nothing and decides nothing. Report 25 owns the
design space; this report hands it a list of constraints and a list of questions. Where a piece
admits several shapes under beni, all of them are stated and none is preferred.

**Citations.** `elm-core:<path>:<line>` is `references/elm-core/<path>`, and likewise
`elm-browser:`, `elm-vdom:` (= `references/elm-virtual-dom`) and `elm:` (= `references/elm`, the
compiler). A bare `` `:1234` `` continues the citation immediately before it. Bare document
references (`boundary.md` §5.4) are into this repository. **P2** is
[`transparent-effects-proposal.md`](../transparent-effects-proposal.md).

---

## 0. Findings

### 0.1 The table

Line counts are whole-file for a kernel `.js` and whole-file or region for an `.elm`. "Because of"
answers *why does this code exist at all*, not *where does it live*.

| Piece | Lines | Exists because of | Under beni |
|---|---:|---|---|
| `_Platform_initialize` — flags, `init`, the model cell, `sendToApp`, the stepper | 21 (`elm-core:src/Elm/Kernel/Platform.js:35-55`) | **both** — the cell and the render trigger are the browser's; the `Cmd`/`Sub` dispatch inside it is Elm's effect model | **replace**: keep the cell + stepper, delete the bag dispatch (§2) |
| Effect managers: `createManager`, `instantiateManager`, routers, bags, `gatherEffects`, `dispatchEffects`, the effects queue | ~200 (`Platform.js:76-328`) | **Elm's effect model**, whole | **vanishes as a mechanism.** What it *provides* — a stateful owner of live subscriptions — still needs an answer: OPEN (§4) |
| `Scheduler.js` — tasks, processes, run queue, `binding`'s kill handle, `kill` | 195 (`elm-core:src/Elm/Kernel/Scheduler.js`) | **Elm's effect model** — it is `Task`'s interpreter — but the *job* is a fiber kernel | **replace** with beni's fiber kernel (report 21 §0.4: 10 pieces, ~1 260 est. lines) (§3) |
| `Process.js` — `sleep` with a `clearTimeout` canceller | 18 (`elm-core:src/Elm/Kernel/Process.js`) | browser/host timer | **keep** as a platform `foreign` |
| `_Browser_element` / `_Browser_document` | ~60 (`elm-browser:src/Elm/Kernel/Browser.js:29-92`) | **browser** | **keep**, shape follows report 25 (§2) |
| `_Browser_makeAnimator` — NO_REQUEST / PENDING / EXTRA | 26 (`Browser.js:110-135`) | **browser** — one render per frame | **keep the mechanism.** The constraint is the browser's and no architecture dodges it (§6.9) |
| `_Browser_application` — link interception, `popstate`, `hashchange` | ~70 (`Browser.js:142-212`) | **browser** | **keep** (§7) |
| `Navigation.Key` — an unforgeable token | 3 (`elm-browser:src/Browser/Navigation.elm:67-69`) | **neither** — Elm's capability discipline | **replace** with beni's services decision (records / `where`), which expresses it directly (§7.3) |
| `_Browser_on` — a `document`/`window` listener as a process | 9 (`Browser.js:223-231`) | **browser** | **keep the listener**; its *lifetime* is the subscription question (§5) |
| `_Browser_withNode` / `withWindow` — an rAF before every DOM read | 24 (`Browser.js:293-316`) | **browser** — read-after-render ordering | **keep the deferral.** What sequences it under transparent effects is OPEN (§8) |
| `Browser.Dom` — focus, blur, viewport, scroll, `getElement` | 384 + ~110 JS (`elm-browser:src/Browser/Dom.elm`, `Browser.js:322-430`) | **browser** | **keep** as platform effects (§8) |
| `Browser.Events` — the `on*` family as an effect manager | 356 (`elm-browser:src/Browser/Events.elm`) | **split** — the listener is the browser's, the diffing manager is Elm's effect model | the manager half **vanishes**; the listener half stays: OPEN what owns it (§5.2) |
| `AnimationManager` — rAF only while someone subscribes | 114 (`elm-browser:src/Browser/AnimationManager.elm`) | same split | same (§5.3) |
| VirtualDom render / diff / patch / keyed diff | ~1 100 of 1 589 (`elm-vdom:src/Elm/Kernel/VirtualDom.js`) | **browser** | **keep or replace with another renderer** — report 25's question, not this one (§6) |
| The tagger (`map`) chain, in render, diff, patch and event dispatch | ~120 (`VirtualDom.js:145-153`, `:444-462`, `:772-818`, `:657-673`, `:1402-1411`) | **Elm's architecture** (message re-tagging up a tree), not the browser | depends on report 25's architecture; a design with no `msg` type has no taggers (§6.7) |
| `thunk` / `lazy` — reference-equality memoisation | ~70 (`VirtualDom.js:160-224`, `:752-770`) | **the pure-view model's performance** | **OPEN**, and already parked (`effects-decisions.md` C9). It rests on a property beni does not promise (§6.8) |
| The event-callback indirection `callback.__handler` | ~107 (`VirtualDom.js:574-680`) | **browser** — listener churn, and the synchronous `preventDefault` decision | **keep.** `sync` is beni's name for the constraint (§6.6) |
| The passive-listener feature probe | 10 (`VirtualDom.js:615-623`) | **browser** | **keep** (or drop the probe; 2026's browsers all support it) |
| XSS sanitisers (`javascript:` URIs, `<script>`, `on*`, `innerHTML`) | ~60 (`VirtualDom.js:274-333`) | **browser** (security) | **keep** — it is a guarantee in rule 7's sense (§6.3) |
| `virtualize` — adopt server-rendered DOM | ~40 (`VirtualDom.js:1530-1569`) | **browser** | **keep if hydration matters**; today it exists to make the mount node diffable (§6.10) |
| Ports: `outgoingPort`, `incomingPort`, converters, `subscribe`/`send` | ~140 (`Platform.js:332-471`) | **ecosystem** — the wall | **keep**; `boundary.md` §3.1 and milestone B3 already specify a wider version (§9) |
| Flags decoding, at `init` | 2 (`Platform.js:37-38`) + compiler | **ecosystem** — the wall | **keep** (§9.3) |
| `_Platform_export` + merge, `scope['Elm']` | 47 (`Platform.js:475-521`) | **ecosystem** — several Elm apps on one page | **replace**: the artifact shape is a platform manifest fact (`boundary.md` §5.2) (§2.6) |
| The debugger: `Debugger/*.elm` + `Elm/Kernel/Debugger.js` | 3 442 (64 % of `elm-browser`) | **ecosystem** | **vanishes unless chosen.** It is only *possible* because all state is one model and all change is one `update` — a property any beni UI design keeps or gives up (§10) |
| Kernel-file granularity of dead-code elimination | — (`elm:compiler/src/AST/Optimized.hs:218`) | **ecosystem** (Elm's kernel dialect) | **already beaten**: `boundary.md` §7.1, one export per `foreign` (§11.4) |

**Counts.** Of 25 rows: **12 exist because of the browser** and beni needs an equivalent of each
(rows 4–7, 9–11, 14, 17–20); **2 exist because of Elm's effect model alone** and vanish as
mechanisms (the effect-manager machinery, the scheduler); **2 more are splits** where a browser need
is wrapped in an effect-model mechanism (`Browser.Events`, `AnimationManager`) and only the wrapper
vanishes; **5 exist because of the ecosystem** (ports, flags, `_Platform_export`, the debugger,
kernel-file DCE); and **4 are neither** — `_Platform_initialize` is half of each, `Navigation.Key`
is Elm's capability discipline, the tagger chain is Elm's architecture, and `lazy` is the pure-view
model's performance. The single largest piece — the virtual DOM, 1 589 lines — is entirely a browser
piece and survives any effects decision.

### 0.2 The constraints the browser imposes that no design can dodge

Each is stated with the Elm evidence that it is real, not a preference.

1. **A handler must decide `preventDefault` and `stopPropagation` synchronously, inside the
   listener.** Elm's `Handler` type has four variants for exactly this
   (`elm-vdom:src/VirtualDom.elm:272-276`), and the callback reads the decision out of the decoded
   value and acts on it before returning (`VirtualDom.js:650-656`). This maps one-to-one onto beni's
   `sync` (`effects-decisions.md` A6 — *"`sync` ships in the first cut"*): **an event handler is a
   `sync` boundary, and everything reachable from it must not suspend.**
2. **One render per frame, and the renderer — not the program — decides when.**
   `_Browser_makeAnimator` (`Browser.js:110-135`) calls `view` at most once per animation frame.
   **Measured** (§6.9): five messages delivered in one synchronous JavaScript loop produce **one**
   DOM update, on the next frame.
3. **…except when the DOM holds its own state, where the render must be synchronous.** Elm's own
   text: *"if `stopPropagation` is used, we update the DOM immediately, within the same tick… This
   is useful for DOM nodes that hold their own state, like `<input type="text">`. If someone types
   very fast, the state in the DOM can diverge from the state in your `Model` while waiting on the
   next `requestAnimationFrame`"* (`elm-vdom:src/VirtualDom.elm:258-265`). **Measured** (§6.9):
   five `stopPropagation` clicks produce **five** synchronous DOM updates, all before the next
   frame. So the frame contract has a documented, load-bearing escape hatch.
4. **Some capabilities are scoped to the user gesture's tick.** Elm again: *"Some actions, like
   uploading and downloading files, are only allowed when the JavaScript event loop is running
   because of user input. This is for security! So when an event occurs, we call `update` and send
   any `port` messages immediately, all within the same tick"* (`VirtualDom.elm:252-256`). A design
   that defers `update` off the handler's tick **loses file dialogs, clipboard writes and
   fullscreen**. This is the sharpest argument the vendored sources make for a `sync` `update`.
5. **Some effects must run after a render.** `Browser.Dom.focus` and every viewport read go through
   `_Browser_withNode`, which wraps the DOM access in a `requestAnimationFrame`
   (`Browser.js:293-305`) so the node the program just described exists before it is looked up.
   Under beni, where an effectful call in `update` is just a call and runs **before** the re-render,
   something must sequence this explicitly (§8.3).
6. **A listener's lifetime must track what the UI currently wants.** Elm gets this for free from
   `subscriptions : Model -> Sub msg` recomputed after every message and diffed by the manager: a
   `Dict.merge` kills the processes whose subscriptions disappeared and spawns the new ones
   (`Browser/Events.elm:304-323`). Nothing else in Elm ever unsubscribes. Whatever beni does, **the
   listener that nobody wants any more must stop**, and it must stop without the author writing it.
7. **Navigation must be intercepted.** A single-page application has to catch `<a>` clicks before the
   browser leaves the page (`Browser.js:155-173`, which tests the modifier keys, `target` and
   `download` and only then calls `event.preventDefault()`), and has to listen for `popstate` and —
   for Trident — `hashchange` (`:152-153`). This is a browser fact, not an architecture fact.
8. **The JavaScript-interop boundary must not be able to crash the program.** Elm decodes every
   incoming port value and *crashes* on a decode failure (`Platform.js:459-461`,
   `__Debug_crash(4, name, result.a)`), which is the one place Elm's no-runtime-exception claim is
   discharged by a runtime check rather than by types. beni already has a stronger answer specified
   (`boundary.md` §3.1: a generated codec with a depth bound, a decode error as a value).
9. **There is one thread, and a long computation stops the page.** **Measured** (§3.6): a
   2 000 000-step `Task.andThen` chain runs to completion inside one `app.ports.x.send()` call,
   blocking for **372 ms** with **zero** animation frames served — the largest inter-frame gap in
   the run was 378 ms. Elm's scheduler has a run queue and no yield budget at all. This is exactly
   the hazard report 21 §0.5 item 1 and `effects-decisions.md` B1 exist to size, and it is the
   single clearest thing beni's fiber runtime can be **better** at than Elm.

### 0.3 What TEA gives, and what beni keeps or loses by its choice

TEA is not one property; it is six, and they are separable. Naming them separately is what lets
report 25 trade them individually.

| Property | What holds it up in Elm | Under beni |
|---|---|---|
| **A single source of truth** — one `Model`, one place a value lives | `_Platform_initialize`'s `model` cell (`Platform.js:41`, `:48`) and nothing else being allowed to hold state | Kept by any design that keeps one cell. Lost the moment components own state. Independent of effects |
| **Time travel / a debugger** | The same cell **plus** `update` being a pure function of `(msg, model)` — the debugger replays the message history against `wrapUpdate` (§10) | Kept only if both halves are kept. **An effectful `update` gives this up**, because replaying a message re-performs its effects. Flagged for report 25 |
| **No stale closures** | `view` is re-derived from the model every frame; a handler is a decoder plus a message, not a closure over an old model | Kept by a pure `view`. A signals/fine-grained design keeps it differently (a read is always current); a component design with captured state does not |
| **Exhaustively typed messages** | `Msg` is one ADT and `case` is checked exhaustively | Kept by beni's checker in any design that has a message type. A design where a handler calls a function directly has nothing to be exhaustive about — that is a **loss of a guarantee**, and rule 7 says to say so |
| **`update` is testable as a pure function** | It is one | **Kept, under the owner's services decision.** `effects-decisions.md` A7: services are *records of functions and `where` clauses*. An `update` that performs is testable exactly when its capabilities arrive as an argument or as `where` evidence: the test passes a fake record, the production build passes the platform's. That is the same technique Elm's users reach for when they extract logic out of `update`, made total. What is *not* recovered is the property that `update` cannot possibly perform — that needs `sync`, and `sync` is decided (A6) |
| **No manual subscription lifetime** | `subscriptions model` recomputed every message and diffed (`Browser/Events.elm:304-323`) | **This is the one TEA property with no obvious replacement under transparent effects**, and it is question 1 to report 25. A fiber holding a listener is not automatically cancelled when the model stops wanting it; something has to relate "what the UI currently is" to "what is running" |

**One more thing TEA buys that is easy to miss:** because a `Cmd` is an inert value, `update` can be
tested for *what it asked for* without performing it. beni has already decided to keep this shape at
the boundary — `boundary.md` §5.4's `Cmd.keyed k Policy thunk toMsg`, where *"the key is ordinary
data in the returned value, so 'navigating away cancels the search' becomes assertable, which it is
not in Elm today."* That section predates the effects decisions and P2 §6.6 defers to it; it is the
only written beni design for a browser command type and report 25 should either adopt or replace it
explicitly.

### 0.4 Questions this report hands to report 25 (the design space)

1. **What owns a live listener, and what cancels it?** Elm's answer is a manager that diffs a
   declarative `Sub` set. Under beni an event source could be (a) a fiber running a loop over a
   queue the listener fills, (b) a `foreign` that registers a listener and calls back into beni — a
   `sync` boundary, since the callback runs on the browser's stack, (c) a keyed registry in the
   platform, the `Cmd.keyed` shape of `boundary.md` §5.4 applied to subscriptions, or (d) a
   declarative set recomputed and diffed, as Elm does, over fibers instead of processes. §5.5 states
   each option's cost; this report does not choose.
2. **Is `view` still a pure function of a model?** Everything in §0.3 turns on it, and so does the
   whole of §6 — the diff is only worth doing because `view` is cheap and pure.
3. **What sequences an effect that must run after a render** (§8.3)? Elm's `_Browser_withNode` hides
   an rAF inside every DOM task. beni could (a) do the same inside each platform capability, (b)
   expose an explicit `afterRender` / `nextFrame` suspension point, or (c) make the renderer a fiber
   the program can join.
4. **Does anything replace the tagger chain?** `Html.map` exists because a child component's
   messages must be re-tagged on the way up. If report 25's architecture has no `msg`, ~120 lines of
   virtual-DOM complexity across four functions goes away with it (§6.7).
5. **Is the virtual DOM the right renderer at all?** This report establishes what Elm's costs and
   guarantees are; it takes no position on alternatives.
6. **Does a beni UI keep one model cell?** §10's finding is that the debugger is not a feature you
   add later — it is a consequence of the cell plus the pure `update`.

### 0.5 Questions for the owner (options only)

1. **Is a time-travel debugger a goal?** If yes, it constrains report 25 before report 25 starts: it
   requires one model cell, a pure `update`, and a message type. Options: (a) a goal, and the
   architecture is chosen to preserve it; (b) not a goal; (c) a weaker target — record/replay of
   *inputs* rather than of messages, which survives an effectful `update` but needs a deterministic
   clock and scheduler, and `effects-decisions.md` A13 already decided beni has those.
2. **Is `sync` on `view` and on event handlers, or on `update` too?** The browser forces `sync` on
   the handler (§0.2 item 1) and on `view` (item 2). `update` is a separate decision, and item 4 —
   gesture-scoped capabilities — is the argument for including it. `boundary.md` §5.4 already
   promises in writing that both `update` and `view` are `sync`; that promise predates the browser
   decision and can be re-taken. Options: (a) all three; (b) `view` + handler only; (c) all three,
   with an explicit escape for `update` that costs the gesture.
3. **What is `main` in a browser?** `effects-decisions.md` A8 settled `main : Program` with exit
   codes 0/1/130 and reference-counted keep-alive — all Node notions. A page never exits. Options:
   (a) `Program` is the platform's opaque mount descriptor and keep-alive is meaningless; (b) the
   page's "exit" is an unhandled fiber death, which goes to the console plus an error boundary;
   (c) both, with a platform-declared `runtime` per `boundary.md` §5.2.
4. **What does an unhandled fiber death do to a mounted page?** Options: (a) log and keep rendering
   the last good view; (b) unmount and render a platform error view; (c) A1's answer unchanged —
   defects are fatal — which in a browser means the page stops updating and says so.
5. **Is hydration of server-rendered HTML a requirement?** It decides whether `virtualize`
   (`VirtualDom.js:1530`) has an equivalent, and it is cheaper to design in than to add (§6.10).
6. **How much runtime may a browser program ship?** Elm's floor is **109 530 B raw / 22 723 brotli**
   for a counter, of which **0.9 % is user code** (§11). beni's floor today is 2 147 B raw / 833
   brotli with no runtime at all. Report 21 §0.4 holds the fiber kernel to ~5 kB gzip. Options for a
   stated budget: (a) a number now, which shapes §6's renderer choice; (b) measure first, decide
   after report 25.

---

## 1. Method

### 1.1 What was read, at which commit

| Source | Pin | What was read |
|---|---|---|
| `references/elm-core` | `65cea00`, `elm/core` **1.0.5** | `src/Platform.elm`, `Platform/Cmd.elm`, `Platform/Sub.elm`, `Task.elm`, `Process.elm`; kernels `Platform.js` (521), `Scheduler.js` (195), `Process.js` (18) |
| `references/elm-browser` | `1d28cd6`, `elm/browser` **1.0.2** | `src/Browser.elm` (289), `Browser/Dom.elm` (384), `Browser/Events.elm` (356), `Browser/Navigation.elm` (183), `Browser/AnimationManager.elm` (114); kernels `Browser.js` (460), `Debugger.js` (566), `Browser.server.js` (132); `Debugger/*.elm` (2 876) |
| `references/elm-virtual-dom` | `79d31f5`, tag **1.0.5** | `src/Elm/Kernel/VirtualDom.js` (1 589), `VirtualDom.elm` (381), `VirtualDom.server.js` (209) |
| `references/elm` | `1bd5b36` (2026-07-13, post-0.19.1 `master`) | `compiler/src/Generate/JavaScript.hs`, `Generate/JavaScript/Expression.hs`, `Generate/Mode.hs`, `Elm/Kernel.hs`, `AST/Optimized.hs`, `Optimize/Module.hs`, `Optimize/Port.hs`, `Optimize/Expression.hs`, `builder/src/Generate.hs`, `Nitpick/Debug.hs` |

**Kernel files that exist, in full.** `elm-core`: `Basics.js`, `Bitwise.js`, `Char.js`, `Debug.js`,
`JsArray.js`, `List.js`, `Platform.js`, `Process.js`, `Process.server.js`, `Scheduler.js`,
`String.js`, `Utils.js` — twelve, 1 954 lines. `elm-browser`: `Browser.js`, `Browser.server.js`,
`Debugger.js` — three, 1 158 lines. `elm-virtual-dom`: `VirtualDom.js`, `VirtualDom.server.js` — two,
1 798 lines. There is **no** `Elm/Kernel/Platform.js` counterpart in `elm-browser` and no
`Elm/Kernel/Process.js` beyond the 18-line one; `Elm/Kernel/Json.js` is in `elm/json`, which is not
vendored (its bytes are measured in §11 but its source is not cited).

### 1.2 What was run

**The Elm compiler is available**, contrary to the brief's expectation:
`nix run nixpkgs#elmPackages.elm -- --version` → **0.19.2**, and package downloads work. So §11's
numbers are measured, not cited.

Five programs were compiled in three modes each (plain dev, `--optimize`, `--debug`): a
`Platform.worker` with one outgoing port; a `Browser.sandbox` counter; a `Browser.element` with a
conditional `Browser.Events.onAnimationFrameDelta` subscription and a `Process.sleep` `Task`; a
`Browser.application` with `onUrlRequest`/`onUrlChange`; and two instrumented programs for the
browser experiments. Dependencies resolved to `elm/core` 1.0.5, `elm/browser` 1.0.2, `elm/html`
1.0.0, `elm/json` 1.1.3, `elm/time` 1.0.0, `elm/url` 1.0.0, `elm/virtual-dom` **1.0.3**.

**One version caveat, and it is small.** The compiled `elm/virtual-dom` is 1.0.3; the vendored one is
1.0.5. `diff` between them is **four lines**, both in the XSS sanitisers: 1.0.5 adds `outerHTML` to
`_VirtualDom_noInnerHtmlOrFormAction` (`VirtualDom.js:306`) and adds an `Array.isArray` arm to
`_VirtualDom_noJavaScriptOrHtmlJson` (`:325-329`). Nothing in §6's diff, patch, event or lazy
machinery differs. `elm-core:src/Elm/Kernel/Platform.js` and
`elm-browser:src/Elm/Kernel/Browser.js` are **byte-identical** to the versions that were compiled.

**Browser experiments** ran in **Google Chrome 153.0.8010.47**, `--headless=new`, driven over the
DevTools protocol from Node 24 (`WebSocket` and `fetch` are globals; no dependencies). Chrome was
started with `--disable-background-timer-throttling --disable-renderer-backgrounding
--disable-backgrounding-occluded-windows`, because without them a headless page's timers and
`requestAnimationFrame` do not run at all — the first two attempts produced no frames and are
discarded. Observation is by `MutationObserver` on `document.body` plus a continuous
`requestAnimationFrame` ticker, so "a render happened" is a DOM fact and not an Elm internal.

**Compression** is `gzip -9` and `brotli -q 11`; minification is `esbuild 0.27.2 --minify
--target=es2020`. Byte attribution splits a bundle at column-0 lines — Elm's code generator indents
everything inside a top-level statement, so this recovers 99.9–100.0 % of the file — and buckets
each statement by its identifier prefix (`_VirtualDom_*`, `$author$project$*`, …).

### 1.3 What was not run

No Firefox or Safari. No profiling of the diff against a realistic tree (the brief forbids quoting
benchmarks not run here, and the only trees measured are three and five nodes). No memory
measurement. No test of `virtualize` against real server-rendered markup. No `elm-optimize-level-2`
or any community post-processor. The debugger was measured by size only, not exercised.

---

## 2. Program bring-up

### 2.1 Four entry points, two implementations

`Browser.sandbox`, `element`, `document` and `application` are not four runtimes. `sandbox` is
`element` with the `Cmd`s erased — literally, in Elm:

```elm
sandbox impl =
    Elm.Kernel.Browser.element
        { init = \() -> ( impl.init, Cmd.none )
        , view = impl.view
        , update = \msg model -> ( impl.update msg model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
```
`elm-browser:src/Browser.elm:69-75`. And `application` is `document` plus a `setup` field:
`_Browser_application` builds a record with `__$setup`, `__$init`, `__$view`, `__$update`,
`__$subscriptions` and hands it to `_Browser_document` (`elm-browser:src/Elm/Kernel/Browser.js:142`,
`:148-182`). So there are **two** program shapes — `element` (mounts on a node) and `document` (owns
`<body>` and `<title>`) — and both are `_Platform_initialize` with a different `stepperBuilder`.

`Platform.worker` is the third caller of the same function, with a stepper that does nothing:
`function() { return function() {} }` (`elm-core:src/Elm/Kernel/Platform.js:26`).

### 2.2 `_Platform_initialize`, in 21 lines

```js
function _Platform_initialize(flagDecoder, args, init, update, subscriptions, stepperBuilder)
{
	var result = A2(__Json_run, flagDecoder, __Json_wrap(args ? args['flags'] : undefined));
	__Result_isOk(result) || __Debug_crash(2 /**__DEBUG/, __Json_errorToString(result.a) /**/);
	var managers = {};
	var initPair = init(result.a);
	var model = initPair.a;
	var stepper = stepperBuilder(sendToApp, model);
	var ports = _Platform_setupEffects(managers, sendToApp);

	function sendToApp(msg, viewMetadata)
	{
		var pair = A2(update, msg, model);
		stepper(model = pair.a, viewMetadata);
		_Platform_enqueueEffects(managers, pair.b, subscriptions(model));
	}

	_Platform_enqueueEffects(managers, initPair.b, subscriptions(model));

	return ports ? { ports: ports } : {};
}
```
`Platform.js:35-55`. Everything about TEA's *execution* is in this function. Read in order:

- **Flags are decoded before anything else**, and a failure is a crash, not a value (`:37-38`). The
  decoder is generated by the compiler from `main`'s declared flags type — `Optimize/Module.hs:256`
  dispatches on `Can.TType hm nm [flags, _, message] | hm == ModuleName.platform && nm ==
  Name.program` and calls `Port.toFlagsDecoder flags`, which for `()` emits
  `Json.Decode.succeed ()` (`elm:compiler/src/Optimize/Port.hs:140`).
- **The model is a closure variable**, `model`, assigned in the middle of an expression
  (`stepper(model = pair.a, …)`, `:48`). That one variable is TEA's single source of truth.
- **`sendToApp` is the only way in.** Every event handler, every port, every effect manager
  eventually calls it. It is 4 statements.
- **`subscriptions(model)` is re-evaluated after every single message** (`:49`) — not on a
  dependency, not on a diff of the model, unconditionally.
- **The stepper is built before the ports**, and `stepperBuilder` receives `initialModel`
  (`:42`), because `_Browser_makeAnimator` draws immediately (§6.9).

### 2.3 The per-message cost path, exactly

For one message, in order:

1. `update(msg, model)` — the user's function. One allocation for the returned pair.
2. `stepper(newModel, isSync)` — `_Browser_makeAnimator`'s two-line state machine
   (`Browser.js:123-134`). If `isSync` is falsy this is *one* comparison and possibly one
   `requestAnimationFrame` call; **`view` is not called**.
3. `subscriptions(newModel)` — the user's function, run in full, building a fresh `Sub` bag.
4. `_Platform_enqueueEffects(managers, cmdBag, subBag)` (`Platform.js:242`) — pushes a record, and
   if not already draining, drains.
5. `_Platform_dispatchEffects` (`:257`) — builds an `effectsDict`, walks the command bag and the
   subscription bag recursively (`_Platform_gatherEffects`, `:273`), applying the accumulated tagger
   chain to each leaf (`_Platform_toEffect`, `:300`), and then **sends every registered manager an
   `fx` message, whether or not it has any effects**:
   ```js
   for (var home in managers)
   {
   	__Scheduler_rawSend(managers[home], {
   		$: 'fx',
   		a: effectsDict[home] || { __cmds: __List_Nil, __subs: __List_Nil }
   	});
   }
   ```
   `:263-269`.
6. Each `rawSend` pushes onto that manager process's mailbox and enqueues it
   (`elm-core:src/Elm/Kernel/Scheduler.js:88-92`); the first of them drains the whole scheduler
   queue synchronously (§3.2), so every manager's `onEffects` — written in **Elm** — runs, for every
   message.

So the fixed per-message cost is: one `update`, one `subscriptions`, two bag walks, and **one
`onEffects` invocation per effect manager linked into the program**, each of which is an Elm function
that in `Browser.Events`'s case builds two `Dict`s and merges them (§5.2). A program that imports
`Browser.Events`, `Time` and `Task` pays three of those on every keystroke, even when nothing
changed.

**Measured** (Chrome 153, a `Browser.element` with one incoming port, one port subscription and the
`Task` manager linked):

| Path | ns/message | messages/s |
|---|---:|---:|
| `app.ports.x.send()` → `update` → stepper (no `view`) | **397** | 2 518 891 |
| A dispatched `click` → decode → tagger walk → `update` → stepper (no `view`) | **1 687** | 592 768 |
| A `stopPropagation` `click` → …→ **synchronous `view` + diff + patch** | **2 940** | 340 136 |

The three-node view in this program is tiny, so the third row is close to a floor for
"render synchronously". The gap between rows 1 and 2 — ~1.3 µs — is the event path: `Json.Decode`
run against a live `MouseEvent`, the handler lookup and the tagger walk.

### 2.4 How `update`'s returned `Cmd` is dispatched

A `Cmd msg` is not a function and not a thunk. It is a **bag**: `Leaf { home, value }`,
`Node { bags }` or `Map { func, bag }` (`Platform.js:176-205`). `Cmd.batch` is `_Platform_batch`, a
`Node`; `Cmd.map` is `_Platform_map`, a `Map`; and each effect module's `command` is
`_Platform_leaf("<ModuleName>")` (`:176`, and the compiler emits it at
`elm:compiler/src/Generate/JavaScript.hs:458`).

`_Platform_gatherEffects` walks the tree, accumulating a linked list of taggers on the way down, and
at each leaf calls the owning manager's `cmdMap` with a function that applies the whole accumulated
chain (`:273-316`). So `Cmd.map` costs nothing at construction and O(depth) per leaf at dispatch.

**The dispatch is queued, and the comment says why** — 19 lines of it (`:209-227`), naming three
issue numbers:

> Say your init contains a synchronous command, like `Time.now` or `Time.here` … If we just start
> dispatching FX_2, subscriptions from FX_2 can be processed before subscriptions from FX_1. No
> good!

and then nine more lines explaining why the guard is a boolean rather than a queue-length test
(`:230-237`). This is a re-entrancy hazard that any runtime where an effect can complete
synchronously will have, and beni's fiber runtime has the same class of problem — report 21 §0.3
item 1 calls it *a re-entrant interrupt*, and `effects-decisions.md` records it as unaddressed in P2.

### 2.5 For beni

**What is browser and what is Elm-effect-model in these 21 lines is separable to the statement.**
Lines 37-38 (flags), 40 (`init`), 41 (the cell), 42 (the stepper), 48 (`model = …; stepper(…)`) are
the browser's: something must decode the host's handoff, hold the state and trigger a render.
Lines 39, 43, 49, 52 — `managers`, `setupEffects`, `enqueueEffects` — are Elm's effect model in
full, and under beni's design there is nothing for them to do: an effectful call is a call, so there
is no bag to gather and no manager to send an `fx` message to.

What does *not* follow is that the per-message path gets simpler for free. Elm re-evaluates
`subscriptions` after every message because that is how it learns what the program wants; a beni
design has to answer the same question some other way, and §5.5 lists the options. The one thing
that can be said now is that the **fixed cost per message of walking two bags and waking every
manager (step 5 above) disappears**, and it is the part of Elm's path that grows with the number of
effect modules a program imports rather than with what it actually does.

### 2.6 `_Platform_export`, and the shape of the artifact

Elm's output is an IIFE that assigns `scope['Elm']` — merging into an existing one if two Elm
programs share a page, and crashing if two of them claim the same module path
(`Platform.js:482-521`; the debug variant names the module in the crash). The compiler builds the
nested object from the module name split on dots (`elm:compiler/src/Generate/JavaScript.hs:557`) and
emits `_Platform_export({'Main':{'init': $author$project$Main$main(<flagDecoder>)(<debugMetadata>)}})`
(`:503-529`, `Generate/JavaScript/Expression.hs:930-943`). So `main`'s value **is** the curried
initialiser: a `Program flags model msg` compiles to a function of a flag decoder and a metadata
blob.

beni emits ES modules and a platform declares its own output shape with the `runtime` manifest key
(`boundary.md` §5.2), so this piece is already superseded by a better mechanism. What is worth
carrying over is the *problem*: two independently compiled beni programs on one page, and the
question of whether their runtimes are shared or duplicated. That is a chunking question
(`backend.md` §10) and nobody has asked it yet.

---

## 3. The scheduler and `Task`/`Process`

This is the closest prior art to beni's fiber kernel inside the Elm lineage, and it is **195 lines**.

### 3.1 The data

A `Task` is one of six records (`Scheduler.js:10-59`):

| Tag | Fields | Meaning |
|---|---|---|
| `SUCCEED` | `__value` | done, with a value |
| `FAIL` | `__value` | done, with an error |
| `BINDING` | `__callback`, `__kill` | suspend; `__callback(resume)` may return a canceller |
| `AND_THEN` | `__callback`, `__task` | continue on success |
| `ON_ERROR` | `__callback`, `__task` | continue on failure |
| `RECEIVE` | `__callback` | take one message from this process's mailbox |

A process is `{ $, __id, __root, __stack, __mailbox }` — a unique id from a global counter, the task
it is currently on, a **heap-allocated continuation stack** (a linked list of
`{$: SUCCEED|FAIL, __callback, __rest}`), and an array mailbox (`:66-79`, and the type comment at
`:118-128`).

**This is the same shape as a fiber**, with one continuation stack and one current instruction. What
it does not have: a scope, finalisers, an interrupt cause, an op budget, observers, a parent/child
relation, or any notion of a fiber outcome other than the root task's tag.

### 3.2 The queue discipline, and the fact that it never yields

```js
function _Scheduler_enqueue(proc)
{
	_Scheduler_queue.push(proc);
	if (_Scheduler_working) { return; }
	_Scheduler_working = true;
	while (proc = _Scheduler_queue.shift()) { _Scheduler_step(proc); }
	_Scheduler_working = false;
}
```
`Scheduler.js:131-148`, reformatted. One global FIFO. The first caller to enqueue while idle becomes the drainer
and **runs the queue to exhaustion synchronously**. There is no budget, no counter and no escape to
a macrotask or a microtask anywhere in the file. A task chain only gives up control when it reaches
a `BINDING` whose callback does not resume immediately (`:169-176`).

`_Scheduler_step` is the run loop (`:151-195`): it is a `while (proc.__root)` over the six tags,
unwinding `__stack` to the matching kind on a `SUCCEED`/`FAIL`, pushing a frame on `AND_THEN`/
`ON_ERROR`, returning on a `BINDING` after arming the canceller, and returning on a `RECEIVE` with
an empty mailbox. **Because the continuation stack is on the heap, the loop is stack-safe**: no
JavaScript frame is consumed per `andThen`.

### 3.3 Measured: it is stack-safe, and it does block the page

A `Browser.element` whose `update` returns `Task.perform Finished (chain n)`, where `chain n` is `n`
`andThen` steps built with `List.foldl`, driven from JavaScript by one `app.ports.go.send(n)`:

| n | Time inside `ports.go.send()` | Animation frames served during the call |
|---:|---:|---:|
| 1 000 | 1.3 ms | 0 |
| 200 000 | 44.5 ms | 0 |
| **2 000 000** | **372.3 ms** | **0** |

The largest inter-frame gap over the whole run was **378 ms**; every other gap was ~16.8 ms. So: two
million continuation steps complete without a stack overflow (the trampoline works), the whole chain
runs **inside the port `send` that started it** (the synchronous drain of §3.2, reached through
`update` → `enqueueEffects` → `dispatchEffects` → `rawSend` → `enqueue`), and the page is frozen for
the duration.

Elm's own documentation claims the opposite in spirit: *"if `task1` makes a long HTTP request or is
just taking a long time, we can hop over to `task2` and do some work there"*
(`elm-core:src/Process.elm:71-76`). That is true only when "taking a long time" means *parked on a
`BINDING`*. CPU-bound interleaving does not exist in this scheduler.

**This is beni's clearest opportunity.** Report 21 §0.1 sizes Effect v4's answer — an op counter and
an always-macrotask yield — and `effects-decisions.md` B1 holds the budget open pending a browser
measurement (report 26). Whatever that number is, Elm's is *infinity*, and a beni browser platform
that yields at all is strictly better on the axis that matters most in a browser.

### 3.4 What `Process.kill` guarantees: less than it appears

```js
	var task = proc.__root;
	if (task.$ === __1_BINDING && task.__kill) { task.__kill(); }
	proc.__root = null;
	callback(_Scheduler_succeed(__Utils_Tuple0));
```
`Scheduler.js:105-113`, the body of the `binding` `_Scheduler_kill` returns. In full:

- It runs the canceller **only if the process is parked on a `BINDING` right now**. A process that is
  runnable, or parked on a `RECEIVE`, is simply dropped.
- **There are no finalisers.** `proc.__root = null` ends the run loop at its next `while` test
  (`:153`) and nothing else happens. Whatever the process had acquired stays acquired.
- The `__stack` is not unwound, so `ON_ERROR` handlers do not run.
- It is **not observable** by the killed process, and the killer gets `()`.
- `kill` is itself a `Task`, so killing costs a scheduler round trip. `research/16` §1.4 already
  records the consequence — *"`kill` needs an `Id`, `spawn` yields one only as a `Task`… By the time
  you can cancel, a frame has passed"* — and `boundary.md` §5.4 is the design that answers it with
  keys instead of handles.

beni's decisions are a strict superset and were taken with full knowledge of this: `Exit a = Done a |
Cancelled`, finalisers infallible and always run, the interrupter waits for cleanup, `bracket`'s
release receives the outcome, children interrupted before the parent's finalisers
(`effects-decisions.md`, *Answered by the owner, 2026-09-19*).

### 3.5 Error handling: a throw from kernel code is not handled at all

There is no `try`/`catch` anywhere in `Scheduler.js` or `Platform.js`. A `BINDING` callback that
throws throws through `_Scheduler_step`, through `_Scheduler_enqueue`'s `while`, and out of whatever
started the drain — **leaving `_Scheduler_working === true` for the life of the page**, because the
assignment at `:147` is not in a `finally`. Every later `enqueue` then early-returns at `:138-141`
and the scheduler is permanently wedged. This is the failure mode `boundary.md` §4.1 was written
against (*"Every privileged entry point is wrapped in `try`/`catch` … an uncaught foreign throw can
alter a value in a way its type forbids"*).

**Measured, from the other side of the wall.** A `Browser.element` whose `update` calls a
non-tail-recursive Elm function 200 000 deep throws
`RangeError: Maximum call stack size exceeded` **out of `app.ports.go.send()` into the calling
JavaScript**. A stack overflow in user Elm code is a JavaScript exception crossing the port boundary
in the direction Elm's guarantee does not cover. beni has decided the same class is fatal
(`effects-decisions.md` A1: *"A stack overflow in user code is the same: a crash"*), and queue items
52–54 are the follow-ups; the browser adds a question A1 did not answer — **what "the process dies"
means on a page that cannot exit** (§0.5 question 4).

### 3.6 Feature-for-feature against report 21's ten-piece kernel

| Report 21 §0.4 piece | v4 lines | Elm's scheduler | Elm lines |
|---|---:|---|---:|
| fiber record + run loop + `getCont` | 220 | yes — `_Scheduler_step` + the process record | ~45 (`Scheduler.js:66-79`, `:151-195`) |
| primitive/continuation protocol | 154 | yes — the six task tags | ~50 (`:10-59`) |
| `succeed`/`sync`/`suspend`/`yieldNow` | 60 | `succeed`/`fail` only; **no `yieldNow`** | ~16 |
| suspension primitive + canceller frame | 74 | `binding`, canceller as a field not a frame | ~8 (`:26-33`, armed at `:171`) |
| `flatMap`/`map` continuations | 52 | `andThen`/`onError` as records | ~16 |
| interruptibility regions and masks | 72 | **absent** | 0 |
| fiber `await`/`join`/`interrupt`/`interruptAll` | 137 | `kill` only; no `await`, no `join` | ~14 (`:102-115`) |
| fork variants | 169 | `rawSpawn` + `spawn`; no detach, no scope | ~21 (`:66-86`) |
| `Scope` + finalisers + `acquireRelease` | 191 | **absent** | 0 |
| `onExit` as a stack frame | 38 | **absent** | 0 |
| scheduler (buckets, dispatcher, macrotask escape) | 128 | a FIFO with no escape | ~18 (`:131-148`) |
| `Cause` | 212 | **absent** | 0 |
| **plus** a mailbox and `receive` | — | present, and Effect has no analogue | ~12 (`:53-59`, `:88-100`, `:177-184`) |

Elm has **seven of thirteen**, in about **200 lines against 1 507**. What it is missing is exactly
what the last five years of the concurrency literature added: structured lifetimes (scopes,
finalisers, child interruption), interruptibility control, a fiber outcome value, and a yield.
beni's estimate for the same list is ~1 260 lines (report 21 §0.4), so **the fiber kernel is roughly
six times Elm's scheduler**, and buying a great deal.

The one thing Elm has that report 21's kernel does not is the **mailbox and `RECEIVE`**, and it
exists for exactly one customer: effect managers (§4). If effect managers vanish, so does the
mailbox — which is worth noticing, because an actor mailbox is the sort of thing that looks
general-purpose and is in fact load-bearing for one feature.

---

## 4. Effect managers

### 4.1 What they are

An `effect module` is an Elm module with a manifest clause — `effect module Browser.Events where {
subscription = MySub } exposing (…)` (`elm-browser:src/Browser/Events.elm:1`) — that gets, from the
compiler, a synthetic graph node and a `command`/`subscription` constructor
(`elm:compiler/src/Optimize/Module.hs:129-146`). At link time the generator emits

```js
_Platform_effectManagers['Browser.Events'] = _Platform_createManager(init, onEffects, onSelfMsg, 0, subMap);
var $elm$browser$Browser$Events$subscription = _Platform_leaf('Browser.Events');
```
from `elm:compiler/src/Generate/JavaScript.hs:439-476` — a `Cmd`-only module passes four arguments,
a `Sub`-only module passes five **with a `0` hole in the `cmdMap` slot**, and a `Fx` module passes
five. `_Platform_createManager` is a five-field record constructor and nothing more
(`Platform.js:104-113`).

At startup `_Platform_setupEffects` instantiates every registered manager (`:82-101`), and
`_Platform_instantiateManager` (`:116-146`) spawns **one process per manager** running

```js
function loop(state)
{
	return A2(__Scheduler_andThen, loop, __Scheduler_receive(function(msg)
	{
		var value = msg.a;

		if (msg.$ === __2_SELF)
		{
			return A3(onSelfMsg, router, value, state);
		}

		return cmdMap && subMap
			? A4(onEffects, router, value.__cmds, value.__subs, state)
			: A3(onEffects, router, cmdMap ? value.__cmds : value.__subs, state);
	}));
}
```
`:128-143`. That is the whole idea: **a manager is a process in an infinite receive loop, threading
its own state, receiving two kinds of message** — `fx` (here is the complete set of commands and
subscriptions the program currently wants) and `self` (something I subscribed to has fired).

A `Router` is `{ __sendToApp, __selfProcess }` (`:118-121`). `Platform.sendToApp` is a `BINDING` that
calls `sendToApp` and resumes (`:153-160`); `Platform.sendToSelf` is a `Scheduler.send` to the
manager's own process (`:163-169`).

### 4.2 What problem they solve

**A subscription is not a one-shot effect; it is a resource with a lifetime, and something has to
own it.** `Time.every 1000 Tick` means "while the model says so, there is a `setInterval` running".
Nothing in a pure `update` can hold that. The manager is the place where:

- the live set is remembered between messages (`state`);
- the *declared* set (what `subscriptions model` just returned) is reconciled against the live set;
- a callback from the outside world is turned back into a `Msg` (`sendToSelf` → `onSelfMsg` →
  `sendToApp`);
- `Cmd.map`/`Sub.map`'s taggers are applied (`cmdMap`/`subMap`, called from
  `_Platform_toEffect`, `:300-316`).

The Elm packages that use it: `Task` (`elm-core:src/Task.elm:326-352` — a `Cmd`-only manager whose
`onEffects` just spawns each task), `Platform.Cmd`/`Sub`, `Time`, `Browser.Events`,
`Browser.AnimationManager`, `elm/http` (request tracking and cancellation), and — historically —
websockets, whose package was withdrawn in 0.19 precisely because its manager could not be
maintained outside the core organisation.

### 4.3 Why Elm restricts them

`effect module` is gated by the same `isKernel` author check as kernel JavaScript.
`boundary.md` §1 already records the consequence and the verdict — *"Also gates `effect module`, so
nobody else can ship a new *kind* of effect even in pure Elm — which is why `localStorage` has no
package"* — and §2 records beni's replacement: **privilege is a role with a checked contract, not an
author list.**

There is a real safety argument underneath the policy, and it is visible in the mechanism: a manager
is the only thing that can call `sendToApp` out of band, it owns a process the user cannot see, and
its `onEffects` runs on every message of every program that links it. A buggy one is a
whole-program failure. But that argument is about *what the code does*, not *who wrote it*, which is
§2's point.

### 4.4 For beni: what becomes of each

Under beni's model there is no `Cmd`, no `Sub`, no `Task` type and no bag. A command is a thunk the
runtime runs (`boundary.md` §5.4); an effectful call is a call. So:

- **`Task`'s manager vanishes outright.** Its entire body is *"spawn this task and send its result to
  the app"* (`Task.elm:334-351`). Under beni that is `Task.spawn` plus the command's `toMsg`, or
  simply a call.
- **`Time.every`, `Browser.Events.on*`, `AnimationManager`** are the hard cases. Each is a *source*
  that must be started when wanted, stopped when not, and whose callback arrives on the browser's
  stack. The options, stated and not chosen:

  **(a) A fiber running a loop.** `Browser.Events.onClick` becomes a fiber that awaits a queue the
  listener fills. Natural under a fiber runtime, gives cancellation for free (interrupting the fiber
  runs the finaliser that removes the listener), and matches report 21's structured-concurrency
  vocabulary exactly. Cost: something must decide when to spawn and interrupt it, which is question
  1 to report 25; and every event pays a queue offer plus a fiber resume rather than a direct call.

  **(b) A `foreign` that registers a listener and calls back into beni.** This is a `sync` boundary
  and must be declared one: the callback runs inside the browser's dispatch, so it may not suspend —
  which is the same constraint as §0.2 item 1 and is enforceable by A6's `sync` check. Cheapest per
  event. Cost: the wall grows a callback direction it does not have today, and `boundary.md` §4's
  four checks say nothing about a `foreign` that *calls back*. That is a boundary-spec gap, not just
  a design choice.

  **(c) A keyed registry in the platform**, the `Cmd.keyed` shape of `boundary.md` §5.4 applied to
  sources: `Events.listen "resize" handler` registers under a key, `Events.stop "resize"` cancels.
  Keeps the "key is data, so it survives the gap between updates" argument that §5.4 makes for
  commands. Cost: the author manages the lifetime by hand, which is exactly the property Elm's
  declarative `Sub` removed (§0.2 item 6).

  **(d) Keep the declarative set.** Recompute a description of *what sources the UI wants* after
  every change and diff it — Elm's design, with fibers where Elm has processes, and without the
  manager protocol (no `Router`, no `sendToSelf`, no mailbox). Cost: the per-message recomputation of
  §2.3 step 3, and it presupposes a single model.

- **HTTP tracking** — Elm's `elm/http` uses a manager to hold in-flight requests so they can be
  cancelled and tracked. Under beni this is a fiber plus `bracket`, which is strictly what
  `effects-decisions.md` A1/A3 built.
- **Ports** are implemented *as* effect managers (`Platform.js:348-471`), which is an implementation
  convenience rather than a need; see §9.

---

## 5. Subscriptions

### 5.1 The contract, and what it buys

`subscriptions : Model -> Sub Msg` is called after every message (§2.2, `Platform.js:49`), and its
result is a bag exactly like a `Cmd` bag — the same `Leaf`/`Node`/`Map` constructors, the same
`gatherEffects` walk, different `Map` function. What the manager receives in its `fx` message is the
**complete list of subscriptions for this manager, as of now** — not a delta.

Each manager computes its own delta. The value this buys is precise:

- **There is no `unsubscribe` in user code, anywhere in Elm.** The API has no such function, because
  the diff is the unsubscribe.
- **A subscription cannot leak**, because "still wanted" is re-derived from the model rather than
  remembered. A model transition that stops wanting a listener stops it, whatever path reached that
  model.
- **A subscription cannot be duplicated**, because the declared set is a set.

What it costs: `subscriptions model` runs on every message (a full allocation of the bag), and every
linked manager's `onEffects` runs on every message, whether or not its part of the bag changed
(§2.3 step 5). Neither cost is proportional to what changed.

### 5.2 `Browser.Events`: the diff, in 20 lines of Elm

```elm
type alias State msg =
  { subs : List ( String, MySub msg )
  , pids : Dict.Dict String Process.Id
  }
```
`elm-browser:src/Browser/Events.elm:272-275` — the state is *a map from a subscription key to the
process holding the listener*. The key is the node plus the event name: `"d_click"`, `"w_resize"`
(`:330-340`). And:

```elm
    (deadPids, livePids, makeNewPids) =
      Dict.merge stepLeft stepBoth stepRight state.pids (Dict.fromList newSubs) ([], Dict.empty, [])
  in
  Task.sequence (List.map Process.kill deadPids)
    |> Task.andThen (\_ -> Task.sequence makeNewPids)
    |> Task.andThen (\pids -> Task.succeed (State newSubs (Dict.union livePids (Dict.fromList pids))))
```
`:304-323`, with `stepLeft` accumulating dead pids, `stepBoth` keeping live ones and `stepRight`
calling `spawn` (`:309-316`). **A three-way merge: kill the left-only, keep the both, spawn the
right-only.** That is the whole subscription lifetime mechanism, and it runs after every message.

Two consequences worth stating. First, **the key does not include the decoder**: two `onClick`
subscriptions with different decoders share one listener, and `onSelfMsg` runs *every* subscription's
decoder against the event and sends every `Just` (`:289-301`). Second, `Dict.fromList newSubs` and
the merge allocate on every message regardless.

The listener itself is nine lines of kernel:

```js
var _Browser_on = F3(function(node, eventName, sendToSelf)
{
	return __Scheduler_spawn(__Scheduler_binding(function(callback)
	{
		function handler(event)	{ __Scheduler_rawSpawn(sendToSelf(event)); }
		node.addEventListener(eventName, handler, __VirtualDom_passiveSupported && { passive: true });
		return function() { node.removeEventListener(eventName, handler); };
	}));
});
```
`elm-browser:src/Elm/Kernel/Browser.js:223-231`. Note three things: it is a process parked forever on
a `BINDING`; the canceller returned at `:229` is what `Process.kill` runs (§3.4) — the one case where
Elm's `kill` does clean up; and **every global listener is `passive: true`**, so
`Browser.Events.onClick` *cannot* `preventDefault`. That is a deliberate restriction Elm never
documents in the module.

Each event **spawns a fresh process** (`rawSpawn`, `:227`) to run the `sendToSelf` task, so a
`mousemove` subscription allocates a process per pixel of movement.

### 5.3 `AnimationManager`: rAF only while someone subscribes

114 lines, and the interesting part is four cases (`elm-browser:src/Browser/AnimationManager.elm:66-85`):

```elm
onEffects router subs { request, oldTime } =
    case ( request, subs ) of
        ( Nothing, [] ) -> init
        ( Just pid, [] ) -> Process.kill pid |> Task.andThen (\_ -> init)
        ( Nothing, _ ) -> Process.spawn (Task.andThen (Platform.sendToSelf router) rAF) |> …
        ( Just _, _ ) -> Task.succeed (State subs request oldTime)
```

*No subscribers and no request:* nothing. *A request and no subscribers:* kill it — **this is what
stops `requestAnimationFrame` from running forever**. *No request and subscribers:* start one.
*Both:* leave it alone. And `onSelfMsg` (`:88-104`) immediately spawns the next `rAF` before sending
the frame's messages, so the loop is self-sustaining while wanted.

`Elm.Kernel.Browser.rAF` is a `BINDING` whose canceller calls `cancelAnimationFrame`
(`Browser.js:265-277`), so the kill is exact.

This module is the clearest small example of the whole pattern: **a hardware-ish resource, started on
demand, stopped by a diff, with the "is it running?" bit in the manager's state and nowhere else.**
Whatever beni does, it needs an answer at this size for this problem.

### 5.4 `Time.every` and ports

`Time` is not vendored, so its manager is not cited here; by construction it is the same shape with
`setInterval`. Ports are effect managers too: an incoming port's `onEffects` simply **stores the
subscription list** (`_Platform_setupIncomingPort`, `Platform.js:449-453`) and its `send` walks that
list calling `sendToApp` per subscriber (`:457-468`). An outgoing port's `onEffects` walks the
command list and calls every JavaScript subscriber synchronously (`:373-386`). See §9.

### 5.5 For beni

The declarative-diff design is **not** a consequence of `Cmd`/`Sub` being types; it is a consequence
of *the runtime being told, after every change, the complete set of what is wanted*. That input
could be produced by a design with no effect types at all. So the four options of §4.4 are genuinely
open and the effects decisions do not narrow them.

What the effects decisions **do** give, already, is the machinery any of them needs: a fiber with
finalisers that always run, `bracket` whose release receives the outcome, interruption that waits for
cleanup, and keyed cancellation at the command level (`boundary.md` §5.4). Option (a) — a fiber per
source — is the one that uses all of it, and it is the one whose "who decides to interrupt it"
question is unanswered.

The cost that no option avoids: **a listener that nobody wants must stop, and the author must not
have to write that.** If a beni design requires an explicit stop, it has given up §0.3's last row,
and rule 7 says to say so out loud rather than call it flexibility.

---

## 6. The virtual DOM

`elm-vdom:src/Elm/Kernel/VirtualDom.js` is **1 589 lines**; `VirtualDom.elm` is 381, almost all
documentation and thin wrappers. It is 27.2 % of a compiled `Browser.sandbox` (§11).

### 6.1 Node kinds

Six, all plain objects with a `$` tag (`VirtualDom.js:54-224`):

| Kind | Built by | Fields |
|---|---|---|
| `TEXT` | `_VirtualDom_text` `:54` | `__text` |
| `NODE` | `_VirtualDom_nodeNS` `:67` | `__tag`, `__facts`, `__kids` (array), `__namespace`, `__descendantsCount` |
| `KEYED_NODE` | `_VirtualDom_keyedNodeNS` `:98` | same, `__kids` are `(key, node)` pairs |
| `CUSTOM` | `_VirtualDom_custom` `:129` | `__facts`, `__model`, `__render`, `__diff` — the web-component escape hatch |
| `TAGGER` | `_VirtualDom_map` `:145` | `__tagger`, `__node` |
| `THUNK` | `_VirtualDom_thunk` `:160` | `__refs` (array), `__thunk`, `__node` (memo slot) |

`__descendantsCount` is maintained at construction (`:71-77`) and is what lets the patch walk skip
whole subtrees of the real DOM (§6.5).

### 6.2 Facts

Five kinds, distinguished by the `$` of the attribute record — `EVENT`, `STYLE`, `PROP`, `ATTR`,
`ATTR_NS` (`:231-270`) — and organised at construction by `_VirtualDom_organizeFacts` (`:391-417`)
into **one object with four sub-objects, and properties hoisted to the top level**. Two details
matter: **`class` and `className` accumulate rather than overwrite** (`_VirtualDom_addClass`,
`:419-423`, called from `:403` and `:411`) — the one place an attribute list is not last-wins — and
properties share the object with the four category keys, so `applyFacts` distinguishes them by
comparing against the four known strings (`:497-517`).

`applyFacts` has one special case: `value` and `checked` are written **only when they differ from
what the DOM already has** (`:515`), which is the beginning of the "the DOM holds its own state"
problem that §6.9 finishes.

### 6.3 XSS sanitisation

Four regexes and five functions (`:288-333`), guarding `<script>` tags, `on*`/`formAction`
attributes, `innerHTML`/`outerHTML` properties, and `javascript:` / `data:text/html` URIs — with
whitespace permitted between every character of the scheme, because *"tabs can appear in href
protocols and it still works"* (`:276-278`). In `--optimize` a caught vector becomes `''`; in dev it
becomes an `alert` that tells the author to use ports (`:312`). These functions are called from
`elm/html`'s generated attribute constructors, not from this file.

This is a guarantee in rule 7's sense — a `view` cannot inject script — and beni's renderer, whatever
it is, needs it. It is ~60 lines and there is no cheaper way to get it.

### 6.4 The diff

`_VirtualDom_diff(x, y)` returns a flat array of patch records, each carrying the traversal `index`
of the node it applies to (`:701-720`). `_VirtualDom_diffHelp` (`:723-850`) is the whole algorithm:

- **Reference equality short-circuits the whole subtree**: `if (x === y) return;` (`:725`). This is
  what makes `lazy` and, more importantly, *any unchanged subtree that the view function happened to
  share*, free.
- **Different node kinds bail to `REDRAW`**, with one exception: `NODE` vs `KEYED_NODE` is handled by
  dekeying the new one (`:735-747`, `_VirtualDom_dekey` at `:1571`).
- **`THUNK`**: compare the `__refs` arrays element-wise by `===`; if all equal, adopt the old
  rendered node and return; otherwise force the thunk and diff into a sub-patch list (`:752-770`).
- **`TAGGER`**: flatten nested taggers on both sides into arrays; **different lengths bail to
  `REDRAW`** (`:802-808`); otherwise compare pairwise by reference and emit a `TAGGER` patch if they
  differ; then diff below (`:772-818`).
- **`TEXT`**: string compare (`:820-825`).
- **`NODE`/`KEYED_NODE`**: `_VirtualDom_diffNodes` (`:866-880`) bails to `REDRAW` if the tag or
  namespace changed, diffs the facts, and delegates children to `diffKids` or `diffKeyedKids`.
- **`CUSTOM`**: bail if the `render` function changed, else diff facts and call the node's own
  `diff` (`:835-848`).

`_VirtualDom_diffFacts` (`:890-952`) is a recursive object comparison: removals get a
category-appropriate "erase" value (`''` for a style, `undefined` for an attribute or event, `null`
or `''` for a property, `:912-922`); reference-equal values are skipped **except `value` and
`checked`** (`:931`); events are compared by `_VirtualDom_equalEvents` (`:682-685`), which compares
the handler variant and then the *decoder*, by `_Json_equality` — a structural comparison of two
decoders, which is why an inline `Decode.map` in a view does not cause a listener to be re-added.

`_VirtualDom_diffKids` (`:959-992`) is deliberately naive: if the new list is shorter, one
`REMOVE_LAST`; if longer, one `APPEND`; then pairwise diff over the common prefix. **An unkeyed list
with an insertion at the front re-diffs every element.** That is the cost keyed nodes exist to avoid.

### 6.5 The keyed diff, and its limits

`_VirtualDom_diffKeyedKids` (`:999-1156`) is a **single forward pass with one element of lookahead**.
At each step, with `x` and `y` the current old and new child:

| Condition | Action | Advance |
|---|---|---|
| `xKey === yKey` | diff in place | +1, +1 |
| `xKey === yNextKey` **and** `yKey === xNextKey` | diff `x` against `yNext`, insert `y`, remove `xNext` — a swap | +2, +2 |
| `xKey === yNextKey` | insert `y`, diff `x` against `yNext` | +1, +2 |
| `yKey === xNextKey` | remove `x`, diff `xNext` against `y` | +2, +1 |
| `xNextKey === yNextKey` | remove `x`, insert `y`, diff the nexts | +2, +2 |
| none of the above | **`break`** | — |

`:1031-1126`. On `break`, the remaining old children are all removed and the remaining new children
are all inserted (`:1130-1146`) — but *not* blindly: `_VirtualDom_removeNode` and
`_VirtualDom_insertNode` (`:1166-1244`) keep a `changes` dictionary keyed by node key, and when an
insert meets an earlier remove of the same key (or vice versa) the entry is promoted to `MOVE` and
the existing DOM node is reused. So a reordering that defeats the lookahead still moves nodes rather
than recreating them; what it costs is that the whole tail is processed through the dictionary.

**The known limits, from the code:**

- **A duplicate key is handled by mangling.** `key + '_elmW6BL'` (`:1163`, `:1204`, `:1243`) —
  a second node with the same key is retried under a suffixed key, recursively. It does not crash and
  it does not warn; it silently treats the duplicate as a different node.
- **The lookahead is one.** A rotation by two positions falls to the `break` path.
- **The whole `REORDER` patch is one entry**, holding the local patches, the inserts and the end
  inserts (`:1148-1155`), and is applied by `_VirtualDom_applyPatchReorder` (`:1477-1506`) in the
  order: build end-inserts into a `DocumentFragment`, apply removals, apply inserts by
  `insertBefore(node, childNodes[index])`, append the fragment. **The insert indices are computed
  against the new list while the DOM is mid-mutation**, which is why the removals must run first.

### 6.6 Event handling — the indirection, and why it is the browser's fault

`_VirtualDom_applyEvents` (`:574-608`) is the piece with the most consequence per line:

```js
if (oldCallback)
{
	var oldHandler = oldCallback.__handler;
	if (oldHandler.$ === newHandler.$)
	{
		oldCallback.__handler = newHandler;
		continue;
	}
	domNode.removeEventListener(key, oldCallback);
}
```
`:590-599`. The listener actually registered with the DOM is a stable `callback` closure; the handler
it consults is a **mutable field on that closure**. So a view that produces a new handler every frame
— which every view does, since `onClick (Select id)` allocates — causes **zero**
`removeEventListener`/`addEventListener` pairs, as long as the `Handler` *variant* is unchanged. Only
a change of variant (`Normal` → `MayPreventDefault`) re-registers, because the variant decides the
`passive` flag:

```js
domNode.addEventListener(key, oldCallback,
	_VirtualDom_passiveSupported
	&& { passive: __VirtualDom_toHandlerInt(newHandler) < 2 }
);
```
`:602-605` — `Normal` (0) and `MayStopPropagation` (1) are passive; `MayPreventDefault` (2) and
`Custom` (3) are not. `VirtualDom.elm:248-251` states the intent: *"A passive event listener will be
created if you use `Normal` or `MayStopPropagation`. In both cases `preventDefault` cannot be used,
so we can enable optimizations for touch, scroll, and wheel events."*

`_VirtualDom_makeCallback` (`:630-680`) is the dispatch:

```js
var value = result.a;
var message = !tag ? value : tag < 3 ? value.a : value.__$message;
var stopPropagation = tag == 1 ? value.b : tag == 3 && value.__$stopPropagation;
var currentEventNode = (
	stopPropagation && event.stopPropagation(),
	(tag == 2 ? value.b : tag == 3 && value.__$preventDefault) && event.preventDefault(),
	eventNode
);
```
`:649-656`. Four facts:

1. **A decode failure silently drops the event** (`:637-640`). No message, no log. This is Elm's
   answer to "the event was not the shape I expected".
2. **`preventDefault` and `stopPropagation` are called inside the listener, synchronously**, before
   anything else happens. There is no other possible design: the browser reads the flags when the
   listener returns. This is §0.2 item 1, and it is the hardest constraint in this report.
3. **The tagger chain is walked here** (`:659-673`), innermost-out, re-tagging the message once per
   `Html.map` between the node and the root.
4. **`stopPropagation` doubles as the synchronous-render signal**:
   `currentEventNode(message, stopPropagation)` with the comment `// stopPropagation implies isSync`
   (`:674`). That single argument is what reaches `_Platform_initialize`'s `sendToApp(msg,
   viewMetadata)` (`Platform.js:45`) and then `_Browser_makeAnimator`'s `isSync` (`Browser.js:123`).
   **Two unrelated concerns share one bit**, and the reason is documented at
   `VirtualDom.elm:258-265` (§0.2 item 3).

**For beni.** Point 2 is the specification of `sync` in a browser. `effects-decisions.md` A6 decided
`sync` ships in the first cut and its stated motivation was `boundary.md` §5.4's promise about
`update` and `view`; this report adds a second, independent, and stronger motivation — **an event
handler's return is a deadline set by the browser, not by beni**, and any suspension inside it loses
`preventDefault`, loses `stopPropagation`, and (per §0.2 item 4) loses file and clipboard
capabilities. Point 4 is a warning: coupling "render now" to "stop propagation" is an accident of
Elm's implementation and beni should decide the two separately.

### 6.7 `Html.map` and the tagger chain

A `TAGGER` node costs the runtime in four places: render flattens the chain and hangs an
`elm_event_node_ref` on the DOM node (`:444-462`); diff flattens both chains and bails on a length
mismatch (`:772-818`); `addDomNodesHelp` follows the ref (`:1319-1329`); the event callback walks it
per event (`:659-673`); and `applyPatch` can swap it in place (`:1402-1411`). It also forces
`_VirtualDom_mapHandler` (`:347-384`) to rebuild a decoder per variant.

This machinery exists because a child component returns `Html ChildMsg` and the parent needs
`Html ParentMsg`. **It is Elm's architecture, not the browser's**, and report 25 should notice that a
design in which a handler calls a function rather than returning a message has no taggers, no
`Html.map`, and about 120 fewer lines of renderer.

### 6.8 `lazy`, and what it demands of the language

```js
var _VirtualDom_lazy = F2(function(func, a)
{
	return _VirtualDom_thunk([func, a], function() {
		return func(a);
	});
});
```
`:170-175`, with the diff comparing `__refs` element-wise by `===` (`:752-765`). So `lazy` is *fast
if and only if* the arguments are **reference-equal** across renders. Two requirements follow:

1. **The function must be a stable reference.** In Elm a top-level function is one object, so
   `lazy view model` is fine and `lazy (\m -> view m) model` is never fine — a fresh closure every
   frame. This is a well-known Elm footgun with no diagnostic.
2. **The data must be reference-equal, which means the language must not copy it.** Elm's record
   update copies the changed fields and shares the rest, so `{ model | a = x }` leaves
   `model.bigList` reference-equal and `lazy renderList model.bigList` still hits.

**Does beni's emitted JavaScript preserve that?** Today's answer, and it is not a promise:

- Record update emits a spread (`backend.md` §305, §351 — *"a spread moves no initialiser"*), so
  untouched fields keep their identity, as in Elm.
- `--release`'s optimiser drops zero-use bindings and inlines **exactly-one-use** bindings
  (`src/js/Opt.zig`, header). Single-use inlining moves an allocation to its use site; it never
  duplicates one.
- `language.md` §6's *What an optimiser may assume* forbids the duplication that would break this:
  *"Two evaluations that both survive may not be reordered against each other, and neither may be
  duplicated into a position where it runs more often than the table above says."*

So reference stability **holds today by construction**, and is **nowhere promised**. `lazy` would
make it a promise, and that is a language-level commitment (it constrains every future optimiser
pass) for a performance feature. `effects-decisions.md` C9 already parks `lazy` — *"Returns when a
browser platform and a real application want it"* — and this report's contribution is to say what
un-parking it would cost: **a written guarantee about reference identity that beni does not have and
that Elm never wrote down either.**

### 6.9 The animation-frame contract, exactly, and measured

```js
function _Browser_makeAnimator(model, draw)
{
	draw(model);

	var state = __4_NO_REQUEST;

	function updateIfNeeded()
	{
		state = state === __4_EXTRA_REQUEST
			? __4_NO_REQUEST
			: ( _Browser_requestAnimationFrame(updateIfNeeded), draw(model), __4_EXTRA_REQUEST );
	}

	return function(nextModel, isSync)
	{
		model = nextModel;

		isSync
			? ( draw(model),
				state === __4_PENDING_REQUEST && (state = __4_EXTRA_REQUEST)
				)
			: ( state === __4_NO_REQUEST && _Browser_requestAnimationFrame(updateIfNeeded),
				state = __4_PENDING_REQUEST
				);
	};
}
```
`Browser.js:110-135`. In words:

- **The first draw is synchronous**, at construction (`:112`) — before `_Platform_setupEffects`
  returns, and before any message can arrive.
- **An asynchronous step** (`isSync` falsy) requests a frame only if none is outstanding, and sets
  `PENDING`. N messages between frames cost N state assignments and one `requestAnimationFrame`.
- **A synchronous step** draws immediately and, if a frame was pending, demotes it to `EXTRA` so the
  frame will skip its draw.
- **`updateIfNeeded` keeps one frame in flight past the last draw**: when it draws, it requests
  *another* frame and sets `EXTRA`; the next frame sees `EXTRA`, clears to `NO_REQUEST` and draws
  nothing. So an idle app burns exactly one extra empty rAF after every burst, and the *next* burst
  after that costs no `requestAnimationFrame` call at all.

**Measured** (Chrome 153; `MutationObserver` on `document.body` for renders, a continuous rAF ticker
for frame boundaries; times in ms from page start):

```
  140.7 FRAME | 151.6 >> A: 5 port sends | 151.8 << loop returned
              | 157.3 FRAME | 157.4 RENDER 5          <- ONE render, on the next frame
  440.7 FRAME | 452.3 >> B: 5 plain onClick | 452.6 << loop returned
              | 457.3 FRAME | 457.4 RENDER 10         <- ONE render, on the next frame
  740.7 FRAME | 752.7 >> C: 5 stopPropagation clicks | 753.0 << loop returned
              | 753.0 RENDER 15 ×5                    <- FIVE renders, inside the loop
              | 757.4 FRAME                              (the frame comes after)
```

Three findings. **(i)** Five messages from a port produce one render, ~5 ms later, at the frame.
**(ii)** A *plain* `onClick` behaves identically — it is **not** synchronous, because `Normal`'s
`stopPropagation` is `false` (`VirtualDom.js:651`). Only `MayStopPropagation`/`Custom` with a true
flag render synchronously. **(iii)** With `stopPropagation`, all five render synchronously, each
inside the dispatch, and the DOM has caught up before the listener returns.

So "Elm renders once per frame" is true for the common case and **has a documented escape hatch that
is reached by an unrelated-looking API choice**. Any beni design has to answer both halves.

### 6.10 `render`, `applyPatches` and `virtualize`

`_VirtualDom_render` (`:430-490`) is a straightforward recursion: force a thunk, create a text node,
flatten a tagger chain into an `elm_event_node_ref`, or create an element, apply facts and recurse
into children. One browser-specific hook: if `_VirtualDom_divertHrefToApp` is set and the tag is
`a`, a click listener is added to the element at creation (`:477-480`) — this is how
`Browser.application` intercepts links (§7.2).

Applying patches is two passes. `_VirtualDom_addDomNodes` (`:1256-1351`) walks the **old virtual
tree** alongside the real DOM, matching each patch's traversal index and stamping the real node and
the event node onto the patch record; the comment explains the point — *"these indexes (along with
the `descendantsCount` of virtual nodes) let us skip touching entire subtrees of the DOM if we know
there are no patches there"* (`:1250-1253`). Then `_VirtualDom_applyPatchesHelp` (`:1369-1382`)
applies them in order, tracking a possible replacement of the root.

`_VirtualDom_virtualize` (`:1530-1569`) builds a virtual tree from real DOM: text nodes become
`text`, anything that is not an element becomes empty text, elements become `node tag attrs kids`
with **all attributes as `ATTR` facts**. `_Browser_element` calls it on the mount node
(`Browser.js:45`) and `_Browser_document` on `<body>` (`:78`), so the first draw is a *diff*, not a
render — which is Elm's hydration story, such as it is.

**Discovered while instrumenting:** because the mount node is virtualized as itself and the view's
root usually has a different tag or attributes, the first diff is a `REDRAW` and
`_VirtualDom_applyPatchRedraw` (`:1459-1474`) calls `parentNode.replaceChild`. **`Browser.element`
therefore destroys the node you gave it.** A `MutationObserver` registered on `#mount` after
`Elm.Main.init` observes nothing, because `#mount` is no longer in the document. This is not
documented in `Browser.elm` and cost two experiment runs to find.

---

## 7. `Browser.application` and navigation

### 7.1 The three pieces

`_Browser_application(impl)` (`Browser.js:142-183`) is `_Browser_document` plus:

1. **A `key` that is a function.** `var key = function() { key.__sendToApp(onUrlChange(_Browser_getUrl())); };`
   (`:146`) — the `Navigation.Key` the user receives is literally this closure, with its
   `__sendToApp` patched in during `setup`. Calling it reads `location.href` and sends an
   `onUrlChange` message.
2. **History listeners.** `popstate` always, `hashchange` for Trident only (`:152-153`).
3. **A link-click handler**, installed via `_VirtualDom_divertHrefToApp` (§6.10) on every `<a>` the
   renderer creates:
   ```js
   return F2(function(domNode, event)
   {
   	if (!event.ctrlKey && !event.metaKey && !event.shiftKey && event.button < 1 && !domNode.target && !domNode.hasAttribute('download'))
   	{
   		event.preventDefault();
   		…
   	}
   });
   ```
   `:155-173`. The guard is the whole specification of "a click the app should handle": no modifier
   keys (the user wants a new tab), primary button, no `target`, no `download`. Then
   `preventDefault`, parse the href with `Url.fromString`, compare protocol, host and port against
   the current URL, and send `Internal url` or `External href`.

`pushUrl`, `replaceUrl` and `go` are `BINDING`s that call the History API and then call `key()` to
synthesise the `onUrlChange` (`:190-212`) — because `history.pushState` does **not** fire `popstate`.
`load` sets `window.location` inside a `try`/`catch`, because *"Only Firefox can throw a
NS_ERROR_MALFORMED_URI exception here"* (`:445-459`).

`_Browser_getUrl` crashes if `Url.fromString` cannot parse `location.href` (`:185-188`).

### 7.2 Why link interception is in the renderer

Note that the click handler is attached **at element creation** (`VirtualDom.js:477-480`), not
delegated from the document. That means it only covers `<a>` elements Elm rendered, `divertHrefToApp`
is set only during the draw (`Browser.js:81`, `:87`), and an `<a>` inside a `CUSTOM` node or injected
by JavaScript is not intercepted. A document-level delegated listener would have been simpler and is
presumably avoided because it would fire for every click in the page.

### 7.3 The `Key`, and why it is the interesting part

```elm
type Key
    = Key
```
`elm-browser:src/Browser/Navigation.elm:67-69`, with the doc above it:

> You only get access to a `Key` when you create your program with `Browser.application`,
> guaranteeing that your program is equipped to detect these URL changes. If `Key` values were
> available in other kinds of programs, unsuspecting programmers would be sure to run into some
> annoying bugs…

`elm-browser:src/Browser/Navigation.elm:54-62`. This is **capability-as-value**: an opaque type with
no exported constructor, handed to `init` by the platform, required by every function that changes
the URL (`pushUrl : Key -> String -> Cmd msg`, `:89`). `boundary.md` §5 already names the technique —
*"Anything the platform manages is handed to `init` as a value no other code can construct — the
unforgeable-capability trick"* — and `effects-decisions.md` A7 decided beni's form of it: **records
of functions and `where` clauses.**

So this is the one piece in the whole runtime where beni's existing decisions express Elm's design
*better* than Elm does. `Key` is a phantom whose only purpose is to be unforgeable; a beni service is
a record whose fields are the operations, so the capability and the API are one value:
`nav.pushUrl url` where `nav` came from the platform, with `where` evidence if the program prefers
that spelling. It also makes the thing testable — pass a fake `nav` — which Elm's `Key` cannot be.

Note that `load` and `reload` take **no** `Key` (`:163`, `:173`): a full page load is allowed from
any program, because it cannot desynchronise a router that is about to be destroyed anyway. That
asymmetry is a real design decision and a beni service split should preserve it.

---

## 8. `Browser.Dom`

### 8.1 The surface

384 lines of Elm over ~110 lines of kernel: `focus`, `blur` (`Dom.elm:99`, `:122`, both
`Elm.Kernel.Browser.call`), `getViewport`, `getViewportOf`, `setViewport`, `setViewportOf`,
`getElement`. The error type is one constructor, `NotFound String` (`Dom.elm:134-135`), and the
window-level operations are infallible (`getViewport : Task x Viewport`, `:151`).

### 8.2 Every one of them waits for an animation frame

```js
function _Browser_withNode(id, doStuff)
{
	return __Scheduler_binding(function(callback)
	{
		_Browser_requestAnimationFrame(function() {
			var node = document.getElementById(id);
			callback(node
				? __Scheduler_succeed(doStuff(node))
				: __Scheduler_fail(__Dom_NotFound(id))
			);
		});
	});
}
```
`Browser.js:293-305`, and `_Browser_withWindow` (`:308-316`) does the same with no lookup.

**Every DOM read and every focus call is deferred by one animation frame**, unconditionally. The
reason is the ordering problem: `update` returns `(model, Task.attempt … (Dom.focus "search"))`, and
the input with `id="search"` exists only in the view derived from that new model — which, by §6.9,
has not been drawn yet. The rAF in `withNode` lands **after** `makeAnimator`'s draw for the same
frame, because `makeAnimator`'s request was made first (during `sendToApp`, before the command was
dispatched). It is an ordering that works because of the order two callbacks were registered in.

It also means every `Browser.Dom` task costs a frame (~16 ms) even when the node has existed for
minutes, and there is no way to opt out.

### 8.3 For beni: state the problem precisely

Under transparent effects **an effectful call in `update` runs before the re-render**, necessarily:
`update` is a function, it runs to completion (or suspends), and only then does the caller have a new
model to draw. So the naive translation of

```elm
update msg model = case msg of
    Opened -> ( { model | showing = True }, focusTask "search" )
```

into

```
update msg model = case msg of
    Opened -> Dom.focus "search"; { model | showing = True }
```

**is broken**, and broken in the way that is worst: it works whenever the node already existed and
fails whenever it did not. Three shapes of answer, none chosen here:

- **(a) Hide the frame inside the capability**, as Elm does: `Dom.focus` suspends for one frame
  before looking the node up. Costs a frame always; requires nothing of the architecture; makes the
  ordering invisible and therefore unexplainable when it goes wrong.
- **(b) Expose the sequencing point**: a platform operation like `nextFrame ()` or `afterRender ()`
  that suspends until the renderer has applied the pending view, so the author writes
  `afterRender (); Dom.focus "search"`. Costs a concept; makes the dependency visible; and it is
  exactly the sort of thing a fiber runtime with a real suspension primitive is *for*.
- **(c) Make the renderer joinable**: the draw is a fiber, and the program can await it. The most
  general, the most machinery, and the one that interacts with report 25's architecture choice.

There is a fourth possibility worth naming because it disappears if nobody notices it: if `update`
is `sync` (§0.5 question 2), then **none of (a)–(c) can happen inside `update`** — the sequencing
must live in the thing `update` hands back, which is `boundary.md` §5.4's `Cmd` thunk. In that case
Elm's design carries over unchanged and this whole section is about what a *command* may do rather
than about `update`.

---

## 9. Ports and flags

### 9.1 Outgoing

`_Platform_outgoingPort(name, converter)` registers a pseudo-manager with a `cmdMap` that ignores the
tagger (`_Platform_outgoingPortMap = F2(function(tagger, value) { return value; })`,
`Platform.js:360`) and a `portSetup` (`:348-357`). The setup keeps a JavaScript array of subscriber
callbacks and returns `{ subscribe, unsubscribe }` (`:363-411`). `onEffects` walks the command list,
runs the generated encoder, unwraps the JSON value and calls every subscriber **synchronously**
(`:373-386`).

The `setTimeout(0)`: the manager's `init` is `__Process_sleep(0)` and `onEffects` *returns* `init`
(`:370`, `:385`). Since the manager's loop is `andThen(loop, receive(...))`, returning a sleeping
task means **the manager parks for a macrotask after every batch of outgoing messages before it will
receive the next `fx`**. The effect is that outgoing port sends within one message are synchronous
with each other, but the manager cannot be re-entered from inside a subscriber callback. The
`unsubscribe` implementation copies the array first, *"in case unsubscribe is called within a
subscribed callback"* (`:396-399`), and `onEffects` grabs `var currentSubs = subs;` per command for
the same reason (`:377`) — two re-entrancy guards for a callback that runs user JavaScript.

### 9.2 Incoming

`_Platform_incomingPort` registers a `subMap` that composes taggers (`:430-436`) and a setup whose
`onEffects` just stores the subscription list (`:449-453`). `send` is the JavaScript-facing half:

```js
	var result = A2(__Json_run, converter, __Json_wrap(incomingValue));
	__Result_isOk(result) || __Debug_crash(4, name, result.a);
	var value = result.a;
	for (var temp = subs; temp.b; temp = temp.b) { sendToApp(temp.a(value)); }
```
`:459-468`, reformatted. **The decode happens on the JavaScript side of the boundary and a failure is a crash**,
not a `Msg`. Note also that `sendToApp` is called with one argument, so `isSync` is undefined — an
incoming port message never renders synchronously, which the §6.9 measurement confirms.

The codec is generated from the declared type: `Optimize/Module.hs:153-166` runs `Port.toDecoder` /
`Port.toEncoder` over the port's payload type, and `Optimize/Port.hs` is a structural recursion
emitting ordinary `Json.Decode`/`Json.Encode` calls (`:45-70`, `:319-324`). Unsupported shapes are
`error` calls, unreachable because the type checker rejected them earlier (`Optimize/Port.hs:34`).
`boundary.md` §1 records the consequence: *"the codec is generated from the declared type"*, so the
type whitelist is a limit of the generator and not of the technique — which is why `boundary.md`
§3.1 widens it to ADTs and records.

### 9.3 Flags

Flags are the same mechanism at `init`: decoded from `args['flags']`, a failure is `__Debug_crash(2)`
(`Platform.js:37-38`), and the decoder comes from `main`'s declared flags type via
`Port.toFlagsDecoder` (`Optimize/Port.hs:140`), which special-cases `()` to
`Json.Decode.succeed ()`.

### 9.4 For beni

This is the one area where beni's design is already ahead and written down: `boundary.md` §3.1 keeps
ports, widens the payload to any type the compiler can generate a codec for, adds a **depth bound**
to the generated decoder *"so that a decoder that recurses past the bound fails as a value rather
than as a stack overflow"*, keeps them asynchronous, and adds a correlation layer. Milestone B3 is
that work and it is now the browser platform's prerequisite rather than Node's.

Two things this reading adds. **First**, the owner's "defects are fatal and preventing them is the
wall's job" (`effects-decisions.md` A1) has a specific consequence here: Elm's incoming-port decode
failure is *not* a defect in that sense — it is malformed input from outside the wall, which is
exactly the case a `Result` is for. beni's decision to fail *as a value* is the right one and the
contrast with `__Debug_crash(4, …)` is worth keeping in the spec. **Second**, the two re-entrancy
guards of §9.1 are a reminder that an outgoing port hands control to arbitrary JavaScript that may
call back in; a beni runtime holding a fiber's state across that call has the same problem in a
sharper form.

---

## 10. The debugger, and `--optimize` / `--debug`

### 10.1 What exists, and its size

| File | Lines |
|---|---:|
| `elm-browser:src/Debugger/Main.elm` | 806 |
| `elm-browser:src/Debugger/Expando.elm` | 645 |
| `elm-browser:src/Elm/Kernel/Debugger.js` | 566 |
| `elm-browser:src/Debugger/Overlay.elm` | 534 |
| `elm-browser:src/Debugger/History.elm` | 459 |
| `elm-browser:src/Debugger/Metadata.elm` | 331 |
| `elm-browser:src/Debugger/Report.elm` | 101 |
| **total** | **3 442** — 64 % of `elm-browser`'s 5 360 lines |

Measured in a compiled bundle (§11): the debugger's Elm code is **111 514 B, 40.7 %** of a
`--debug` `Browser.sandbox`, and `Elm/Kernel/Debugger.js` another **13 829 B, 5.0 %**. A `--debug`
build of the counter is **274 042 B** against **109 530 B** for `--optimize` — 2.5×.

### 10.2 What it needs from the runtime

`_Debugger_element` is a parallel `_Platform_initialize` call that substitutes wrapped functions
(`elm-browser:src/Elm/Kernel/Debugger.js:37-40`, and the import header at `:3-19` names
`wrapInit`, `wrapUpdate`, `wrapSubs`, `getUserModel`, `cornerView`, `popoutView`). `Browser.js`
declares `var __Debugger_element;` and then `var _Browser_element = __Debugger_element || F4(…)`
(`Browser.js:27-29`) — so in a `--debug` build the kernel-file substitution makes the debugger's
version win, and in every other build the variable is undefined and the `||` picks the real one.

What it needs is short and total:

- **A message history**, with periodic model snapshots — `History` stores snapshots plus recent
  messages and counts (`Debugger/History.elm:33-35`, `:52-62`), and replays from the nearest
  snapshot.
- **A model it can freeze and restore**, which requires that the model *be* the state.
- **An `update` it can re-run**, which requires that it be pure.
- **Type metadata** for import/export, which the compiler generates only in `--debug`
  (`elm:compiler/src/Generate/JavaScript/Expression.hs:950-965`: `Mode.Dev (Just interfaces)` emits
  a JSON blob of the elm version and the `Msg` type's structure; every other mode emits `0`).

### 10.3 The property to flag

**The debugger is not a feature that was added to Elm; it is a consequence of TEA's shape.** One
model cell, one pure `update`, and messages as data — those three facts are what make "replay the
first 37 messages" meaningful. Remove any one and the feature is not hard, it is undefined:

- If state lives in components, there is no snapshot.
- If `update` performs, replaying a message re-sends the HTTP request.
- If a handler calls a function instead of returning a message, there is no history to store.

This report takes no position on whether beni wants it; it flags that the decision is **taken by
report 25's architecture choice, not later**, and that is §0.5 question 1.

### 10.4 `--optimize` and `--debug`, for the record

Both are `Mode` values, not passes (`elm:compiler/src/Generate/Mode.hs:24-27`), and the three build
entry points are `Mode.Dev (Just types)`, `Mode.Dev Nothing`, `Mode.Prod (shortenFieldNames graph)`
(`elm:builder/src/Generate.hs:55`, `:64`, `:75`). What `--optimize` changes:

- **Record field names are shortened**, bucketed by use frequency so the hottest fields get the
  shortest names (`Generate/Mode.hs:44-62`, consumed at
  `Generate/JavaScript/Expression.hs:272-275`). beni's equivalent is `backend.md` §9 item 4,
  which is **still to come** and needs a per-build field-interference artifact (CLAUDE.md).
- **Constructor tags become integers** instead of strings (`Expression.hs:242-249`), zero-arg
  constructors become bare integers (`Generate/JavaScript.hs:390`), single-constructor
  single-field types unbox to `identity` (`:405`, `Expression.hs:356-362`), `()` becomes `0`, and
  `Char` loses its wrapper.
- **`Debug` is refused, not stripped**: `checkForDebugUses` throws
  `GenerateCannotOptimizeDebugValues` if any module uses anything from `Debug`
  (`elm:builder/src/Generate.hs:91-95`, `Nitpick/Debug.hs:16`). beni took the same decision on
  2026-09-19 (`debug_in_release`, CLAUDE.md).

`--debug` adds exactly three things: the `Debugger` package stops being pruned
(`Generate/JavaScript.hs:219-224`), `debugMetadata` becomes real, and the console warning changes.
Representationally `--debug` is identical to a plain dev build.

---

## 11. What an emitted Elm program ships

### 11.1 The numbers

All figures in bytes. `min` is `esbuild --minify --target=es2020`. Elm does not minify in
`--optimize`; the output is still pretty-printed, 5 246 lines for the counter.

| Program | mode | raw | gzip-9 | brotli-11 | min | min+gzip | min+brotli |
|---|---|---:|---:|---:|---:|---:|---:|
| `Platform.worker`, one port | dev | 61 550 | 14 959 | 13 136 | 24 331 | 8 481 | 7 453 |
| | `--optimize` | 61 085 | 14 797 | 13 021 | 23 569 | 8 190 | **7 189** |
| `Browser.sandbox` counter | dev | 110 742 | 26 502 | 22 940 | 40 987 | 14 203 | 12 596 |
| | `--optimize` | **109 530** | 26 228 | **22 723** | 39 304 | 13 667 | **12 125** |
| | `--debug` | 274 042 | 53 807 | 44 688 | 89 621 | 28 854 | 25 514 |
| `Browser.element` + sub + `Task` | dev | 115 546 | 27 238 | 23 575 | 42 179 | 14 597 | 12 912 |
| | `--optimize` | 114 295 | 26 947 | 23 397 | 40 419 | 14 031 | 12 428 |
| | `--debug` | 278 787 | 54 626 | 45 341 | 90 845 | 29 267 | 25 909 |
| `Browser.application` + navigation | dev | 111 943 | 26 811 | 23 212 | 41 438 | 14 375 | 12 735 |
| | `--optimize` | 110 701 | 26 521 | 22 992 | 39 683 | 13 804 | 12 313 |
| | `--debug` | 275 888 | 54 248 | 45 085 | 90 629 | 29 162 | 25 813 |

**`--optimize` moves raw bytes by about 1 %.** Its value is entirely in what it enables downstream:
after minification the gap is still only ~4 %, because field shortening and integer tags are
compressible patterns that gzip was already finding. What it really buys is the `Debug` refusal and
the representation freedom.

Report 12's cited TodoMVC figure — 122 KB → 24 KB minified → 9 KB gzip — is consistent with the
counter measured here (109 530 → 39 304 → 13 667) once TodoMVC's extra user code and `elm/json`
usage are allowed for; this report does not re-derive it.

### 11.2 How much is runtime, and how much is the user's program

Byte attribution of the `--optimize` builds (§1.2's method; "kernel" is hand-written JavaScript,
"Elm library" is compiled `elm/*` Elm code):

| Program | file | hand-written kernel JS | compiled `elm/*` | user code | `F2..A9` |
|---|---:|---:|---:|---:|---:|
| `Platform.worker` | 61 085 | 43 923 — **71.9 %** | 13 970 — 22.9 % | 426 — **0.7 %** | 2 572 |
| `Browser.sandbox` | 109 530 | 83 083 — **75.9 %** | 22 518 — 20.6 % | 967 — **0.9 %** | 2 585 |
| `Browser.element` | 114 295 | 83 375 — 72.9 % | 26 290 — 23.0 % | 1 681 — 1.5 % | 2 572 |
| `Browser.application` | 110 701 | 83 096 — 75.1 % | 23 055 — 20.8 % | 1 601 — 1.4 % | 2 572 |
| `Browser.sandbox --debug` | 274 042 | 97 856 — 35.7 % | 172 033 — 62.8 % | 1 050 — 0.4 % | 2 569 |

`boundary.md` §7.1 says *"roughly 45 % of Elm's TodoMVC bundle is hand-written runtime"*. **For a
small program the figure is 72–76 %**, and the user's own code is under 1 %. §7.1's number is right
for a program with a lot of Elm in it; the floor is much worse.

### 11.3 Per-piece, for a `Browser.sandbox` counter

| Piece | bytes | % of file |
|---|---:|---:|
| `Elm/Kernel/VirtualDom.js` | 29 782 | **27.2 %** |
| compiled `elm/core` Elm | 13 952 | 12.7 % |
| `Elm/Kernel/Platform.js` | 9 997 | 9.1 % |
| `Elm/Kernel/Browser.js` | 9 173 | 8.4 % |
| `Elm/Kernel/Json.js` | 8 901 | 8.1 % |
| **`Elm/Kernel/Debug.js`** | **7 265** | **6.6 %** |
| `Elm/Kernel/String.js` | 5 024 | 4.6 % |
| compiled `elm/json` Elm | 3 923 | 3.6 % |
| `Elm/Kernel/Utils.js` | 3 420 | 3.1 % |
| **compiled `elm/url` Elm** | **3 144** | **2.9 %** |
| `Elm/Kernel/JsArray.js` | 2 635 | 2.4 % |
| `F`, `F2..F9`, `A2..A9` | 2 585 | 2.4 % |
| `Elm/Kernel/Scheduler.js` | 2 427 | 2.2 % |
| `Elm/Kernel/List.js` | 1 788 | 1.6 % |
| `Elm/Kernel/Basics.js` | 1 577 | 1.4 % |
| **user code** | **967** | **0.9 %** |
| `Elm/Kernel/Char.js` | 801 | 0.7 % |
| compiled `elm/browser` Elm | 631 | 0.6 % |
| `Elm/Kernel/Process.js` | 244 | 0.2 % |

Two rows are the argument for beni's boundary design, made by Elm's own output.

**`elm/url` ships 3 144 bytes into a counter that has no URLs**, because `_Browser_getUrl` calls
`__Url_fromString` (`Browser.js:187`) and `Browser.js` is one graph node. **`Elm/Kernel/Debug.js`
ships 7 265 bytes into an `--optimize` build** — 7.5× the user's whole program — because `Debug.js`
is reachable from `_Debug_crash`, which `Platform.js` calls for a bad flag decode, and the file is
atomic.

That is `boundary.md` §7.1's finding, measured: **kernel dead-code elimination is per FILE.** The
compiler confirms it — a kernel global is `Global (ModuleName.Canonical Pkg.kernel shortName)
Name.dollar` (`elm:compiler/src/AST/Optimized.hs:218`), where `Name.dollar` is the constant `"$"`, so
the *only* thing distinguishing two kernel nodes is the file name; `addKernelDep` maps every
`JsVar shortName _` reference to that whole-file node (`:205-215`); and `addGlobalHelp` splices the
entire chunk list (`elm:compiler/src/Generate/JavaScript.hs:219-224`). Elm-authored code, by
contrast, is eliminated per top-level value.

**beni already fixed this**, and `boundary.md` §7.1 states the mechanism: one export per `foreign`
value is one graph node per `foreign` value, with the dependency half recovered from the sibling's
own `import` statements (check 3 of §4). The measured consequence on beni's side is
`src/js/Reach.zig`'s result — an empty program from 70 684 bytes in 19 files to **2 147 in 5**.

### 11.4 By analogy: what a browser platform will add to beni's floor

beni's floor today is **2 147 B raw / 833 brotli** (`--release`: 1 874 / 789), with no runtime at
all. Piece by piece, from the Elm columns above, with the caveats that beni has no currying
(`F2..A9` disappears — 2 585 B), no effect managers, and per-declaration elimination of sibling
JavaScript:

| Elm piece | Elm bytes (`--optimize`, sandbox) | beni analogue | Expected direction |
|---|---:|---|---|
| `VirtualDom.js` | 29 782 | a renderer — report 25's choice | comparable if a VDOM; unknown otherwise |
| `Scheduler.js` | 2 427 | the fiber kernel (report 21: ~1 260 lines, ≤ 5 kB gzip budget) | **larger**, buying §3.6's missing seven pieces |
| `Platform.js` | 9 997 | the mount + model cell + command runner | **much smaller**: the effect-manager half is ~200 of its 521 lines |
| `Browser.js` | 9 173 | mount, animator, navigation, DOM tasks | comparable; per-declaration DCE should drop what a program does not use |
| `Json.js` + `elm/json` | 12 824 | ports' generated codecs (`boundary.md` §3.1) | **smaller**: generated per port, not a general decoder library |
| `Debug.js` | 7 265 | **zero** in `--release` — `debug_in_release` refuses the build | **gone** |
| `elm/url` | 3 144 | only in a program that navigates | **gone** from a counter |
| `F2..A9` | 2 585 | **zero** — no calling convention (`backend.md` §6) | **gone** |
| `elm/core` Elm | 13 952 | `core/`, already reachability-eliminated | **much smaller** at the floor |

The honest summary: **the renderer dominates and everything else is negotiable.** Elm's counter is
109 530 B, of which 29 782 is the virtual DOM and 967 is the program. If beni reproduces something
of the virtual DOM's size and wins everywhere else in the table, a beni counter lands on the order
of 35–50 kB raw before compression — roughly **20× today's 2 147 B floor and about half to a third
of Elm's**. That is an estimate from the column above, not a measurement, and it is stated so that
report 25 can argue against it with a number.

One caveat this report must carry forward from `plans/queue.md`: **sibling `.js` is never minified
and is 44–76 % of small programs' bytes** (`backend.md` §9's measurement: 1 643 of the floor's
2 147). A browser platform is mostly sibling JavaScript. That is a decision the browser platform
forces and the Node platform never did.

---

## 12. Could not determine

- **Whether Elm's keyed diff has pathological cases beyond the one-element lookahead.** The `break`
  path (`VirtualDom.js:1125`) hands the tail to the `changes` dictionary, which does reuse nodes;
  what it costs in DOM operations for, say, a reversal was not measured. No benchmark is cited
  because none was run.
- **The cost of the diff on a realistic tree.** §2.3's 2 940 ns for a synchronous render is for a
  three-node view. Nothing here supports a claim about Elm's rendering performance at scale, and the
  brief forbids citing benchmarks not run here.
- **`Time`'s effect manager.** `elm/time` is not vendored; §5.4's description is by construction from
  the same pattern and is marked as such.
- **`Elm/Kernel/Json.js`.** Not vendored; its 8 901 bytes are measured but its source is not read, so
  nothing is claimed about `_Json_equality`'s cost, which §6.4 relies on for event diffing.
- **Whether `_VirtualDom_virtualize` is adequate for real server-rendered markup.** It maps every
  attribute to an `ATTR` fact and ignores everything that is not an element or text
  (`:1530-1569`); whether that produces a clean first diff against server output was not tested.
- **How Elm's runtime behaves under a real user-input load.** All events in §6.9 and §2.3 were
  synthesised with `dispatchEvent`, which skips the browser's own input pipeline.
- **What `elm-optimize-level-2` and the community's post-processors change**, which is where several
  of Elm's published size numbers come from.

---

## 13. Evidence index

Every claim above carries its `file:line` inline; this index is the map of which region of which
file each section rests on, so a reader can go to the source without re-reading the report.

| File | Lines | Regions this report rests on | Section |
|---|---:|---|---|
| `elm-core:src/Elm/Kernel/Platform.js` | 521 | `:18`, `:26` worker; `:35-55` `initialize`; `:76-146` managers; `:153-169` routing; `:176-205` bags; `:209-237` the queue comment; `:242-316` dispatch; `:332-471` ports; `:475-521` export | §2, §4, §9 |
| `elm-core:src/Elm/Kernel/Scheduler.js` | 195 | `:10-59` the six task tags; `:64-115` processes, `spawn`, `kill`; `:118-128` the type comment; `:131-148` the queue; `:151-195` the run loop | §3 |
| `elm-core:src/Elm/Kernel/Process.js` | 18 | `:9-18` `sleep` + canceller | §3.1 |
| `elm-core:src/Task.elm` | 351 | `:256-257`, `:282-284`, `:311-317`, `:320-322`, `:326-352` the manager | §4.2 |
| `elm-core:src/Process.elm` | 106 | `:13-44` future plans; `:54-64` the interleaving claim; `:82-105` | §3.3 |
| `elm-core:src/Platform.elm` | 120 | `:42`, `:65-72`, `:83`, `:90`, `:100-120` | §2, §4.1 |
| `elm-browser:src/Elm/Kernel/Browser.js` | 460 | `:27-29` debugger substitution; `:29-92` element/document; `:99-135` rAF + animator; `:142-212` application + navigation; `:219-237` globals, `_Browser_on`, `decodeEvent`; `:265-316` rAF tasks, `withNode`/`withWindow`; `:322-460` DOM reads, `load`/`reload` | §2, §5.2, §6.9, §7, §8 |
| `elm-browser:src/Browser.elm` | 289 | `:63-75`, `:104-130`, `:161-164`, `:207-217`, `:287-289` | §2.1, §7 |
| `elm-browser:src/Browser/Navigation.elm` | 183 | `:54-69` the `Key` rationale; `:89-183` the operations | §7.3 |
| `elm-browser:src/Browser/Events.elm` | 356 | `:1` the header; `:225-235`; `:254-280`; `:289-323` the merge; `:330-356` | §5.2 |
| `elm-browser:src/Browser/AnimationManager.elm` | 114 | `:30-53`; `:66-104` the four cases; `:107-114` | §5.3 |
| `elm-browser:src/Browser/Dom.elm` | 384 | `:99-135`, `:151-249` | §8.1 |
| `elm-browser:src/Elm/Kernel/Debugger.js` | 566 | `:3-19` what it needs; `:37-40` | §10.2 |
| `elm-browser:src/Debugger/History.elm` | 459 | `:33-35`, `:52-62` | §10.2 |
| `elm-vdom:src/Elm/Kernel/VirtualDom.js` | 1 589 | `:54-224` node kinds + `lazy`; `:231-270` facts; `:274-333` XSS; `:340-423` `mapHandler`, `organizeFacts`; `:430-567` render + facts; `:574-685` events; `:701-952` diff; `:959-1244` kids, keyed, changes; `:1250-1527` patch application; `:1530-1589` `virtualize`, `dekey` | §6 |
| `elm-vdom:src/VirtualDom.elm` | 381 | `:233-234`; `:248-265` Notes 1–3; `:272-276` `Handler`; `:283-293` `lazy`; `:354` | §6.6, §6.8, §0.2 |
| `elm:compiler/src/Generate/JavaScript.hs` | — | `:42-55` link traversal; `:176-265` `addGlobal`; `:219-224` kernel splice + debugger; `:343-383` chunks + `_UNUSED`; `:426-476` ports + managers; `:503-557` export trie | §2.6, §4.1, §9.2, §11.3 |
| `elm:…/Generate/JavaScript/Expression.hs` | — | `:242-275` tags + field names; `:636-650` tail calls; `:930-965` `generateMain`, metadata | §2.2, §10 |
| `elm:…/Generate/Mode.hs`, `builder/src/Generate.hs`, `Nitpick/Debug.hs` | — | `Mode.hs:24-62`; `Generate.hs:55-95`; `Debug.hs:16` | §10.4 |
| `elm:…/Elm/Kernel.hs` | — | `:39-51` chunks; `:92-99` header; `:136-200` the `__` dialect; `:224-293` numbering + imports | §1.1, §11.3 |
| `elm:…/AST/Optimized.hs`, `Optimize/Module.hs`, `Optimize/Port.hs` | — | `Optimized.hs:193-218`; `Module.hs:129-166`, `:256-268`; `Port.hs:34-70`, `:140`, `:319-324` | §9, §11.3 |

**beni documents** — `CLAUDE.md` (the *Target* bullet; rules 6 and 7); `boundary.md` §1, §2, §3.1,
§4, §4.1, §5, §5.2, §5.3, §5.4, §7.1, §8 (B3, B4); `language.md` §6 *Evaluation order* and *What an
optimiser may assume*; `backend.md` §6, §9, §10; `transparent-effects-proposal.md` §6.6;
`plans/effects-decisions.md` (the 2026-09-19 block; A1, A5, A6, A7, A8, A13, B1, C6, C9);
`plans/queue.md` (the browser-first decision and the B-R1..3 table);
`research/21-effect-v4-runtime.md` §0.1, §0.3, §0.4, §0.5;
`research/12-js-output-and-chunking.md` (the TodoMVC figure); `src/js/Opt.zig` (the single-use
inlining contract).

**Measurements run for this report** — Elm 0.19.2 (nixpkgs), Chrome 153.0.8010.47 headless, Node
24.19.0, esbuild 0.27.2, `gzip -9`, `brotli -q 11`. Scripts and outputs in the session scratchpad;
every figure in §2.3, §3.3, §6.9 and §11 is from a run described in §1.2.
