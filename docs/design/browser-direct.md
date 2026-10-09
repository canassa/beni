# The direct browser platform — compiling The Elm Architecture to the page a vanilla author writes

*2026-10-09. The normative design of a second browser platform, `browser-direct`, built beside
today's `browser`/`browser-tea` so the two can be measured against each other. The owner's brief
(2026-10-08): "Stop patching and rewrite P3 from scratch and first principles … The target is fast
and small runtime"; vanilla JavaScript is the floor in speed and in bytes, and "adding runtime is a
balancing act" — every byte of runtime must say what it buys. Evidence: research 58 (the first-
principles review and its criteria), 59 (where today's time and bytes go), 60 (P3, the hand-written
target), 61 and 62 (how analysable real programs are), and the write-set contract
[`write-sets.md`](write-sets.md), which this platform consumes unchanged. Section numbers are never
renumbered (CLAUDE.md rule 2); later changes are dated amendments in place. The build order is
[`plans/compile-away.md`](../../plans/compile-away.md) §7.*

**The name.** The brief suggested `browser-next.md`. It is `browser-direct.md`, and the platform is
`browser-direct` with the lowering `direct`, because "next" says nothing once the platform is
current, and "direct" is the design: a message is a function that writes the DOM directly, a
listener is on the node, a list edit is the two `insertBefore` calls the vanilla author writes.

---

## 0. The design in one paragraph

A program on `browser-direct` is compiled, not run. Its page is one HTML string per mount, with
every value the program can never change baked into it as text; its dynamic nodes are reached once,
at mount, and held in module-level variables; and **each message key** (a path of constructors
through the message type, `GotEditorMsg · EnteredTitle`, from `write-sets.md` §4.4) **is one
JavaScript function** that runs that key's `update` arm with the message's payload as its parameters
and then writes, directly and in order, exactly the holes, rows and branches whose read paths the
key's write set can reach — each write guarded by one comparison with the value last written. There
is no `view` at run time, no block, no kind, no instance for markup that exists once, no render loop,
no microtask, no message object unless the program makes a message a value, and no list
reconciler unless some message replaces or permutes a list. What ships as runtime is a short list,
each item paid for only by a page that reaches it: a dispatch guard of a dozen lines (defects,
re-entrant sends, every entry into program code), the controlled-input edited set, one keyed
reconciler, the fiber kernel, and the crash screen in development. The model stays immutable and updated by spread; a later slice updates it in
place where the compiler proves the written path unshared. Everything the language promises stays:
no runtime errors, exhaustive matches, managed effects, inputs that always show the model, a defect
that stops the page.

**What is different from P3** (research 60), so that this is not P3 renamed: no staging and no
flush — a handler writes as it runs (§4.3); no instance object for a unique markup site (§5.2);
handlers take the payload as parameters and never build a message for a view event (§4.1);
`Html.map` over a constructor is composed at compile time, and there is no context chain (§9.1);
the reconciler is emitted only for a list some key replaces or permutes, and the rows' selector is
kept (§6); the model half is not beni's output verbatim: the arm is specialised to the key, an
accumulator loop builds a plain array, a derived `let` is recomputed only by the keys that can
change it, and in-place update is specified with its proof obligation (§7); and the design
carries two early oracles of its own — differential fuzzing against today's platform and a
development-only verify mode (§8.3) — from the first slice that writes a hole. **What is
different from today's `browser`**: everything in §3's table whose "today" column says runtime.

## 1. Terms

- **Hole**: one dynamic position in markup — a text child, an attribute, a class or style entry,
  a markup child, the `each` of a `For`, the scrutinee of a branch.
- **Read set** of a hole: the model paths its expression reads, anchored to the model root
  (`write-sets.md` §3.6). **Write set** of a message key: the model paths that key's `update` may
  change (`write-sets.md` §1). A read **conflicts** with a write set by `write-sets.md` §2.5.
- **Group**: the holes that share one read set; the unit of emitted code for values (§5.3).
- **Site**: one markup root in the source (`backend.md` §15.2). A site is **unique** when the
  program can show it at most once at a time (§5.2); otherwise it is **instanced**.
- **Handler**: the function emitted for one message key (§4).
- **Edit script**: what a handler does to a list's rows for a list write with a known edit tag
  (`write-sets.md` §2.3): append, clear, `set κ`, swap, and the rest of §6.2.
- **Dispatch**: one entry into the program from the host — a listener, a fiber, a timer — and
  everything that runs until it returns.
- **Vanilla**: the page a competent author writes by hand with no framework, as the subjects in
  `bench/ui/apps/scaling/*.mjs` and js-framework-benchmark's `vanillajs` are written.

## 2. The question every piece answers

The owner's floor is vanilla. A vanilla author has four facts the framework must either prove or
pay for at run time (research 58 §1 (i)): which values never change, which node shows which value,
which row a message touches, and which shapes the page uses. beni's compiler has all four for a TEA
program: the complement of every write set, the anchored read sets, the index symbols and edit tags
of the write set, and reachability. So for every piece of this design the question is:

> *What does the vanilla author write for this; is the fact it depends on known at compile time
> (then it is emitted specialised, or not at all) or only at run time (then what is the smallest
> run-time step, measured against what vanilla does at run time); and what does it cost?*

A piece that answers "known at compile time" ships no runtime. A piece that answers "run time"
ships the step vanilla also takes, or the step that stands in for a guarantee vanilla does not
give, and §3 prices it.

## 3. The cost table

Every piece of a page on this platform, what vanilla writes for it, when its fact is known, what
this platform emits, and the cost. Time is per message, untraced, on research 60's harness; bytes
are brotli 11 after minification. **[measured]** cites a report; **[estimate]** is this document's
reasoning and is to be replaced by the slice that builds the piece.

| piece | vanilla writes | known when | this platform emits | time | bytes | today (`browser`) |
|---|---|---|---|---|---|---|
| **static markup** | the HTML string | compile time | the same string, every never-written path with a string literal in `init` baked as text (`write-sets.md` §9.1) | 0 | the HTML, as vanilla | 6.1 B per static hole **[measured, 59 §4.2]** |
| **reaching a dynamic node** | `getElementById` once | compile time | one walk per dynamic node at mount, into a module-level variable (§5.2) | 0 per message | ~3 B per dynamic hole **[measured, 59 §4.2]** | the same, into an instance field |
| **event delivery** | `addEventListener` on the node | compile time | the same, on every handler node outside a list; one delegated listener per event name on a list's parent (§4.2) | the browser's dispatch; inside a list a walk of the row's depth | ~30 B per direct listener; ~120 B per delegated list **[estimate from P3]** | one document listener, a walk to the document, string-built property names: 7.7 µs above P2 **[measured, 59 §1]** |
| **the message** | nothing: the handler is the message | compile time | nothing: the listener calls the key's handler with the payload as arguments (§4.1); a message object exists only where the program makes one a value (§4.4) | 0 | 0 | one object per event |
| **state transition** | `tick++` | run time | the key's `update` arm, inlined, over the immutable model (§7.1); in place where proved unshared (§7.4) | a spread per record on the path, ~20–50 ns each **[estimate, 58 §4]**; 0 in place | the arm, as today | the whole `update` with its `case` |
| **change detection** | none | compile time (which holes) + run time (whether the value differs) | the handler calls only the groups the key's write set conflicts with; each compares a leaf value with the one last written (§5.3) | one `!==` per hole the key can reach — 40 % of holes on average **[measured, 61 §4.1]** | ~6 B per dynamic hole **[measured, 59 §4.2]**, plus ~2 B per (key, group) call | every group of the root compared on every message |
| **scheduling** | none | — | none: writes happen in the handler (§4.3) | 0 | ~100 B **[estimate]**: the dispatch guard (§4.3) | the queue, the microtask, the turn: 1.4 + 0.4 µs **[measured, 59 §1]** |
| **DOM creation** | `innerHTML`, `cloneNode` | compile time | the same | parity **[measured, 60 §4.5]** | the template | the same |
| **DOM update** | `node.data = x` | compile time | the same write, in the handler | the write: ~5 µs cold **[measured, 59 §1.4]** | the write | the same |
| **a row's edit** | `trs[k]`, two `insertBefore` | compile time (which rows) + run time (`k`) | the edit script for the key's edit tag over an instance array (§6.2) | O(1) for an indexed edit; O(n) compares for the `map` idiom; O(n) for a filter | ~40–80 B per edit script **[estimate from P3]** | the keyed pass over every row |
| **a list replaced or permuted** | the author rewrites the rows | run time | one keyed reconciler, shipped only for a list some key replaces or permutes (§6.3) | O(n) | ~450 B once **[estimate from P3's `reconcile`]** | two keyed passes, 1 478 B **[measured, 59 §4.1]** |
| **selection** | `selectedRow` kept, two class writes | compile time (the selector) | the two rows found through the list's key map (§6.4) | O(1) | the key map, ~60 B, only for a list with a selector or a reconciler | the selector, through `forKeyed` |
| **memory** | `data[]`, `trs[]` | — | one module-level slot per group; one instance per row | — | — | the same, plus blocks and kinds |
| **controlled inputs** | nothing: never reconciled | run time (the user's edit) | the edited set of `backend.md` §15.3, reconciled at the end of the dispatch, shipped only when a `stateful` attribute exists (§8.1) | O(touched) | ~250 B when used **[estimate]** | the same, since 2026-10-08 |
| **defects** | an exception reaches the console | run time | the guard: `try … finally` setting `dead`, no `catch`, around every entry — listener bodies, `end()`, `run` and the mount (§8.2); the crash screen in development; `Task.shutdown` when the page reaches `Task` | ≈ 0 **[measured, 59 §1.3: the guards cost nothing]** | inside the ~100 B above; the screen in development only | the same |
| **effects** | `fetch`, `setTimeout` by hand | run time | the handler hands its `Cmd` to the command driver after its writes; the subscription diff runs only in handlers whose key can change what `subscriptions` reads (§10) | as today's `Tea`, minus a diff per render | `core/Task` and the driver, only when reached | the same, with the diff on every render |
| **generality** | code for this page's shapes only | compile time | code for this program's shapes only: an unreached runtime piece is not written | — | the empty page ≤ 300 B **[target]** | 1 234 B **[measured, `backend.md` §15.11]** |

The sum, for the pages research 60 measured: the holes page is the HTML plus one handler of one
compare and one write (P3's 394 B against vanilla's 168, with P3's 100-byte loop replaced by the
60-byte guard); the rows page is a row template, an instance array, two edit scripts and a
delegated listener; the table app is that plus the reconciler, the key map and the dispatcher-free
buttons. §13 states the targets per page class.

## 4. Messages: one function per key

### 4.1 The handler

For every leaf key κ of the program's key tree (`write-sets.md` §4.4) the lowering emits one
function, named by the key (`Main$h$Edit`, `Main$h$GotEditorMsg$EnteredTitle`; short under
`--release`), whose parameters are the payload fields along the key — for `Edit Int String`,
`(id, s)` — and whose body is, in this order:

0. **The old model.** A handler whose scripts need the model before the arm — an index symbol
   that reads it (`write-sets.md` §2.3), a derived value's old input — binds `const old = model`
   first; one that does not, does not. The instance arrays of §6.1 hold the old *shape* of every
   list, so a script's guard (§6.2) never needs the old list itself.
1. **The arm.** The code of `update`'s arm for κ, inlined, with the pattern's variables bound to
   the parameters and `model` bound to the program's module-level `model` variable; the arm's
   result replaces `model` (`model = …`), and for a `Tea.element` program its second component
   is the command (step 6). For a key below a helper the top-level `update` calls
   (`GotHomeMsg sub → updateWith … (Home.update sub home)`), the top-level arm is inlined and the
   sub-message is rebuilt as a value for the call, unless the release optimiser's specialiser
   (`backend.md` §9, *Whole-program specialisation*) has specialised the helper to the key, in
   which case no message exists. An arm that reads `msg` whole (`Debug.log "msg" msg`,
   `remember msg`) rebuilds it the same way. **Nothing dispatches on a constructor** in the
   common case: the `case msg of` is gone, its arms are the handlers.
2. **Top-level derived values** (§5.4) — those belonging to no branch arm — whose read sets
   conflict with `writes(κ)`, recomputed in dependency order into their slots. An arm's derived
   values are not here: they run at the arm's mount and first in the arm's visit of step 3, under the arm's liveness
   (§5.4, §5.5), because step 1 may have made the model another variant and the arm's old
   liveness would still read as true until step 3 switches it.
3. **Structure and values, per arm, outermost first.** The top level is the outermost arm, and
   its nested branches' live arms follow it, each visited as a whole before the next and only
   under its liveness. For each arm, in this order: **(a)** its derived values that conflict
   with `writes(κ)` (§5.4), in dependency order — before anything of the arm reads them, which
   is what a flat "structure, then values" order got wrong (a `For each={shown}` inside a page
   arm would have reconciled against the stale `shown`); **(b)** its nested branches whose
   scrutinee reads conflict (§5.5) — a switch tears the old arm down and mounts the new one
   from the current model, and **an arm mounted earlier in this dispatch is not visited again**:
   its lists, groups and derived values were built from the model after step 1, and a visit
   would run its scripts a second time (a `swap` against rows already in their new order);
   a kept arm is visited in its turn; **the live nested arms are read after (b) has run**,
   never snapshotted before it, so a torn-down arm is not visited and a newly mounted one is
   skipped; **(c)** the edit scripts (§6.2) of every list write in `writes(κ)` whose `For` is
   the arm's, in the source order of the sites; **(d)** its groups (§5.3) whose read sets
   conflict, in the order of their first hole, the row holes an edit script marked, and the
   selector's two rows (§6.4). Mount (§5.5) runs the same four in the same order on every arm
   it mounts. Pinned by `browser/direct/SwapAndShow` (one message makes a hidden `Show` visible
   and swaps two rows of the list inside it: the rows appear once, in the new order).
4. *(folded into 3: there is no separate value step; each arm's values follow its structure.)*
5. *(withdrawn: there is one after-render point, `end()` in §4.3, after every queued message of
   the dispatch has applied; §10.2.)*
6. **Effects**: the command of step 1 is handed to the command driver; the subscription diff runs
   if `writes(κ)` conflicts with what `subscriptions` reads (§10.1).

**Every step runs under its branch's liveness.** A group, a script, a selector visit or a derived
value that belongs to a branch arm (§5.5) — a page of Conduit's union, the `then` of an `if` in a
hole, a `Show`'s body — is emitted inside a test that the arm is the one shown, `if (br3 === 1)
{ … }`, nested for nested branches, and is never called otherwise. The handler for
`GotHomeMsg · Loaded` that arrives after the page moved to `Article` (a late HTTP answer) runs its
arm — which `write-sets.md` §4.4's fallthrough makes a no-op on another page — then finds the
home branch not shown and reads nothing of `ρ.Home#0`. A path read of a variant that is not
there would be a `TypeError`, which the language forbids; the liveness test is what makes it
impossible by construction. Pinned by `browser/direct/LateResponse` (a message for a page no
longer shown, and one for a `Show` that closed).

A key whose write set is empty (a command-only message, 18 % of research 61's constructors) is
steps 1 and 6. A key of class `*` (`value ρ`) runs step 3 over every arm, every list and every
group: **`patchAll`**, one outlined function per program that exists only when some key needs
it (Conduit's `ChangedUrl` does; research 62 §3.1). That is the Elm fallback — compare
everything — kept as the rule `compile-away.md` §2 states: an unknown write set is a cost, never
an error. **An opaque `update`** — `update = withLogging update`, a record a helper builds, any
program whose `update` the analysis cannot key (`write-sets.md` §1.1's unrecognised program) —
is the same case taken to its end: one key, `*`, one handler `h$All(msg)` that calls the `update`
function with a message built as a value (§4.4) and then `patchAll`. No shape of `update` is
refused (rule 7); it is only slower, by today's amount, and the dump says so (§11).

**What the handler never does**: decide "unchanged" from the analysis alone. Every group it calls
compares before it writes (`write-sets.md` §9.2); the analysis only chooses which groups to call.

### 4.2 Event delivery

A handler node is an element with an `on…` attribute. The fact "which node, which handler" is in
the template, so:

- **A site's listener body.** For every handler node the lowering emits one **listener body**
  `l(e)`: a function of the event that reads the payload — the extractor's result for a
  payload-form handler, the arguments the handler expression names (`onClick={Select model.id}`
  reads `model.id`), a row's instance through its root — and calls the key's handler with them,
  at whatever arity the handler has. The DOM listener is `e => { flags; send(l, e); }`: the
  body runs **inside the guard** (§4.3), so a throw in the payload read is a defect like any
  other. **The event's flags run in the DOM listener, synchronously, before `send`**: the
  declaration's `preventDefault` and `stopPropagation` (`EventFacts`, known at compile time) are
  native calls the lowering writes into the DOM listener itself, never into the body, because a
  body that arrives while a dispatch is running is queued (§4.3) and runs after the event has
  finished dispatching, when `preventDefault()` and `stopPropagation()` do nothing and
  `e.currentTarget` is `null`. Only the message part is ever queued. A payload extractor reads
  `e.target` and the event's own fields, which survive the dispatch; one that read
  `currentTarget` would not, and `html`'s declare none. Pinned by `browser/direct/SubmitFromWrite`
  (a `submit` with `preventDefault` fired synchronously by a handler's own DOM write — a button
  the handler enables and the browser's implicit submission — does not navigate).
- **Read at the event, not captured** (*Elm differs here, and §15's Q1 is the owner's*). Elm's
  `onClick (Select model.id)` captures the value at the last `view`; this platform reads
  `model.id` when the listener body runs. The two agree whenever the page and the model are in
  step, and they always are when a body runs: dispatches are serialised (§4.3), so a body runs
  either outside any dispatch, with the page showing the model, or queued after the dispatch
  that was running, with the page showing that dispatch's result. The one observable difference
  is an event a handler's own DOM write fires synchronously — a `blur` when the focused input is
  removed: Elm would hand the blur's message the value the previous view captured; here the body
  runs after the handler and reads the model the handler made. The same holds for a row's event
  reaching a row the same dispatch detached: it is **delivered**, with the item the row showed
  (the instance is still the handler property's), as Elm delivers it. Pinned by
  `browser/direct/EventReadsModel` (a handler removes the focused input; the blur's message
  carries the new model's value) and `browser/direct/DetachedRowEvent`. The same holds of what
  a queued body reads from the event's node: a queued `e.target.value` is read after the running
  handler's own writes to that control, so it sees what the handler wrote, not what the user
  typed before it — narrow today, since only a `blur` or `focus` a DOM write fires can queue,
  and `EventReadsModel` pins that reading too.
- **Outside every `For` row**, each handler node gets `addEventListener(name, e => send(l, e))`
  at mount. The DOM's own bubbling delivers the event to an ancestor's handler node after a
  descendant's, which is Elm's order; `stopPropagation` declared on the event's row calls
  `e.stopPropagation()`, `preventDefault` likewise. Cost: one listener per handler node, made
  once; nothing per message beyond the browser's dispatch. A page has tens of such nodes, not
  thousands: the thousands are in rows.
- **Inside a `For` row**, for an event whose vocabulary row says `delegated` (`EventFacts.
  delegated`, `boundary.md` §9.4.2 — the bubbling events: `click`, `input`, `keydown`, …), one
  listener per event name on the list's **parent element** (the element whose children the rows
  are), added at the list's mount, shipped with that list. At an event it walks from `e.target`
  up to **this list's** row root, collecting the listener bodies of the nodes that carry one
  (`$h`, set at the row's mount, holding the body; a row's root carries its instance, `$r`,
  which names its list), and runs them innermost first; at a node whose declaration says
  `stopPropagation` it calls the native `e.stopPropagation()` and stops, so the direct
  listeners above the list do not fire either; a `preventDefault` is applied as the walk passes
  the node, synchronously; otherwise the DOM's bubbling reaches the listeners above after the
  walk. **A walk never crosses another list's rows or another program's nodes.** A `For` inside
  a row, or a program mounted inside a row, puts a second delegated listener below this one,
  and the DOM fires the inner one first; the outer listener's walk then starts at the same
  target, inside the inner row. So the walk **buffers** the bodies it meets and, on reaching a
  row root, runs the buffer only if that root is this list's (`$r.list === this list`) and
  otherwise **discards** it — those nodes were the inner list's, whose own listener has already
  run them — and goes on with an empty buffer until it reaches its own row root; a program's
  mount root counts as another list's row root. `$r.list` is the **list's run-time identity** —
  the descriptor or instance array of this mount — never its static site, so two mounts of a
  function-built program (§8.2) that hold nested lists are told apart. **A `stopPropagation`
  node** inside a row stops the walk *after* running the buffer up to and including that node,
  provided the walk has not crossed another list's row root since it last discarded (the
  stopper is this list's row's): the stopper's own body and the bodies below it run, the
  native `e.stopPropagation()` is called, and nothing above runs. The order that results is
  Elm's: the inner row's handlers, then the outer row's, each once. Pinned by `browser/direct/NestedFor` (a
  `For` in a `For` row, a click on the inner row's button and on the outer row's cell) and
  `browser/direct/NestedPrograms` (a program mounted inside another's list row). **An event that does not
  bubble** — `focus`, `blur`, `mouseenter`, `mouseleave`, `scroll`, `load`, the media events —
  cannot be delegated; its vocabulary row says so (`delegated: false`), and a row node with such
  a handler gets a **direct listener** at `make`, exactly as a node outside a list does.
  TodoMVC's edit field is `onBlur`, so its rows pay one listener each for it; dom-expressions
  makes the same split. This is delegation restricted to a list and to the events it can serve
  (research 58 §4: "delegation inside rows" is part of the irreducible runtime), and
  js-framework-benchmark's own vanilla delegates on the `<tbody>` the same way; **S2 measures
  mount of 1 000 and 10 000 rows with a listener per row against it**, and the per-list listener
  stays unless a listener per row is as fast to mount and no larger (§13's `create` criterion),
  in which case rows get direct listeners for every event and no walk exists anywhere. Pinned by
  `browser/direct/RowBlur` (a blur in a row), `browser/direct/StopInRow` (a row handler that
  stops propagation: its own message is sent, a handler below it in the row is sent first, and
  an outer direct listener does not fire).
- **Which program** an event belongs to is known at compile time: a program's handler nodes are
  in its own templates, and its listeners call its own handlers. Two programs on one page (§9.3)
  need no walk to a mount root.

Research 59 §1.3 attributed 2.1 µs of today's gap to the document listener, 1.9 to the property
names built per event and 1.2 to the walk past the handler; all three are gone outside lists, and
inside a list the walk is the row's depth (two to four nodes) and the property name is a constant.

### 4.3 Dispatch: direct writes, no staging

A vanilla handler writes the DOM as it runs, and so does this one. There is no render queue, no
dirty set, no microtask and no "trusted turn": the handler's steps 2–4 write, and the handler
returns. What this gives up is the burst win: K messages in one task that write the same hole
write it K times where today's end-of-dispatch render writes it once. Research 60 §4.4 measured
that win at 13 % at K = 1 000 synthetic clicks and nothing below K = 30, and at K = 1 — a user's
click — the batching cost a microtask (3–5 µs in the page, 0.05 ms traced). A thousand messages
in one task is not an interaction; the browser paints once per task either way; and §13's burst
and stream criteria keep the stream (K per 60 Hz tick) at or under vanilla. *This reverses the
owner's W28 render loop (Solid 2's microtask flush) and research 56's A (render at the end of a
trusted dispatch): open question Q2 (§15).*

What the dispatch guard does, and all it does (`send` in `Rt`, ~100 B **[estimate]**, written
in beni over `Js` as today's `Rt` is; the JavaScript below is its shape):

```js
let dead = false, running = false, queue = null;
const send = (f, x) => {                 // f: a listener body, `dispatch`, or the mount; x: its one argument
  if (dead) return;
  if (running) { (queue ??= []).push(f, x); return; }   // re-entrant: §9.8.4 rule 2
  running = true;
  let ok = false;
  try {
    f(x);
    for (;;) {
      while (queue !== null) { const q = queue; queue = null; for (let i = 0; i < q.length; i += 2) q[i](q[i + 1]); }
      end();                             // the edited-set reconcile and the after-render point, §8.1, §10.2
      if (queue === null) break;         // a message `end()`'s work sent: apply it in this dispatch
    }
    ok = true;
  } finally {
    running = false;
    if (!ok) dead = true;                // the defect: §8.2
  }
};
```

- **Two arguments, always.** `f` is a function of one argument — a listener body with its event
  (§4.2), `dispatch` with a message value (§4.4), the mount with its program (§8.2) — and the
  body applies the key's handler at any arity. So the payload's arity is the handler's business,
  never the guard's, and nothing is dropped on the queued path.
- **Order** (`boundary.md` §9.8.4): messages apply one at a time, in the order of their sends,
  each exactly once; a send made during a dispatch — from a fiber that answers at once, from
  anything `update` calls, from an event a DOM write fired synchronously — is queued and applied
  when the running body returns, never re-entrantly. The queue is allocated on the first
  re-entrant send and is `null` otherwise.
- **`end()` is inside the guarded region and inside the loop**, after the queue is drained: it
  reconciles the controls the dispatch marked (§8.1) and resumes the after-render waits and
  work (§10.2), which is program code and may throw. A message such work sends — a
  `Dom.rendered` continuation that sends, `afterRender` work that sends — is queued by the
  `running` flag, and the `for (;;)` above drains it and runs `end()` again, until an `end()`
  queues nothing; so it applies in this dispatch and is never stranded until a later one. A
  page with neither controls nor after-render work has an `end` that does nothing, and
  reachability drops the call under `--release`. Pinned by `browser/direct/RenderedSends` (a
  `Dom.rendered` continuation sends a message; the page shows it before the dispatch ends, and
  a `Debug.log` in `end`'s order shows the second `end`).
- There is **no `catch`** (CLAUDE.md rule 9): a throw passes through `finally` to the host.
- **Everything that runs program code enters through `send`**: listener bodies, `dispatch`,
  `run`'s mount, a fiber's resumption. Nothing of the program runs outside the guard, which is
  what §8.2's definition of a defect requires.

What vanilla does at run time here: nothing. The hundred bytes buy the ordering guarantee and
the defect rule, and research 59 §1.3 found a `try … finally` guard costs no time.

### 4.4 When a message is a value

A message exists as a JavaScript object only where the program makes one a value: a `Cmd` or
`Sub` result, `onUrlChange`, a `Browser.Events` subscription, an `Html.map` whose function is not
a constructor (§9.1), a message stored in the model or logged whole. Such a program gets one
**dispatcher** per program, `dispatch(msg)`: the decision tree of `backend.md` §7 over the key
tree — one tag read per step — calling the leaf's handler with the payload's fields. It costs
3–5 B per key and nothing when the program has no carrier: a `Tea.sandbox` whose every message is
a view event has none, and a `Tea.element` has one because commands send values. The analysis
that decides it — **carriers** — is §11.3.

## 5. Rendering: templates, slots, groups, branches

### 5.1 Templates and what is baked

Each unique site (§5.2) of a program is one HTML string, as today's `dom` lowering writes it
(`backend.md` §15.3: the parser table, escaping, markers, flags), with three differences:

- **A static hole is text.** A hole whose read set conflicts with no key's write set is written
  at mount from its expression and never again; one whose expression is exactly a model path
  that `init` gives a plain string literal, standing alone under an ordinary element, is the
  string itself in the template — `write-sets.md` §9.1's rule, verbatim, including its parent
  allowlist and its definition of *plain*. Research 61: 27 % of holes overall, 13 of 16 in the
  table app, 0 of 16 in TodoMVC — so this is a bytes win on component-style pages and nothing
  on list-heavy ones, and §13 does not credit it with speed.
- **A unique site's whole markup is one string**, helpers and components inlined (§5.2), so the
  table app's root is the jumbotron, the six buttons and the table in one `innerHTML`, as P3's is.
- **A text hole that is its parent's only child is a text node of the template** (P2's and
  today's shape); any other is made at mount before its marker.

Mount of a unique site: one `template.innerHTML = …`, one adoption of its content (not a clone:
the site is used once), the walks to its dynamic nodes into module-level variables, the listeners,
and one call of every group (which writes every dynamic hole from `init`'s model; a hole whose
`init` value is in the template and in its slot writes nothing).

### 5.2 Sites: unique and instanced

A site is **unique** when the program can show it at most once at a time: it is `view`'s root, or
a helper's or component's markup reached from a unique site through a hole, a branch or an
`Html.map`, not through a `For` row, not through a `List (Html msg)` hole, and not through a
recursive helper; and the helper is called from one site, or is inlined per call site (the
table app's `button`, called six times, is six unique sites of one template string). A unique
site's state — node handles, group slots, branch state, list instance arrays — is **module-level
variables**, so a write is `w3.data = x` and a slot read is a context-slot load, with no instance
object. §4's handlers read and write them directly. *Why not an instance object anyway:* research
59 §4.2 prices the instance's two fields per hole at 1.1 B and its `i.` prefix per reference at
about a byte, and the hot-loop profile puts the instance load in the noise; the saving is small
and the simplification is large — a unique site needs no `m`/`p` pair, no block, no slot object.

A site is **instanced** when it can be shown several times at once: a `For` row (one instance
per item, §6.1), a `List (Html msg)` hole's elements, a recursive helper's markup, a helper or
component called from an instanced site. An instanced site keeps its state in an **instance
record** `{ e, …nodes, …slots }` made at its mount, as a row's is, and its group code takes the
instance as a parameter. A row is the common case and §6 is its contract; the other three go
through the **value path**: the site is a *kind* `{ m, p }` as today's `dom` emits
(`backend.md` §15.3–§15.4, blocks and slots), placed through a slot. The value path ships
`slot`/`place`/`patch` (~200 B, **[estimate]**) only for a program that has such a site. It is
today's runtime kept as a fallback, so it is **counted before it is built**: `beni dump
--stage=writes` prints `markup_value_roots` per program from S0 (§11), and the S0 stats gate
(§14) reports it for every corpus app, the table app, TodoMVC and Conduit, so the share of a
program on the old path is a number before S4 writes a line of it. Research 61's corpus has one
recursive helper (the helper tree sweep) and a few `List Html` holes.

**A helper called from several unique sites is a shared site, and inlining has a size gate.** A
helper's markup is inlined at a call site only when every call site's copy together is no larger
than one outlined copy plus its calls — the release optimiser's single-use rule measured in
bytes, applied to markup — with this **default**: the sizes are the emitted JavaScript's
minified byte counts (brotli is not additive and is measured, not used, by the gate), a call
site's share of the outlined form is 24 bytes (an instance record, a mount call and the group
calls), and a helper of n call sites is inlined when `n × inlined ≤ outlined + n × 24`; a
helper whose markup is constants only (the table app's `button`) is always inlined, since its
copy is template text. The release optimiser's own solver can refine the constants; this is
the number the design starts from. The table app's `button`, six calls of constants, inlines to six
template strings and six listeners and nothing else, so it passes. A Conduit form-field helper
called thirty times does not: it becomes a **shared site**, its template string and its group
functions emitted once with an instance parameter, each call site holding an instance record
and its own node handles, and the handlers calling the groups with each live instance. A shared
site is not the value path — no kind, no slot, no block — and costs one object per call site.
The same gate applies to `--release`'s specialisation of a helper to a key (§4.1): a `validate`
helper forty keys call is specialised only where the specialised copies are smaller than the
one copy plus its message rebuilds, which the release optimiser's combined solver decides by
bytes (`backend.md` §9). And the (key, group) pairs are counted: the dump prints, per program,
the number of pairs and the share of groups a root-level read makes every key call (a header
showing `model.session` conflicts with most keys), so the "~2 B per pair" of §3 is measured on
Conduit at S0 and the 0.7× target of §13 rests on a number.

### 5.3 Groups and slots

A **group** is the set of holes of a unique or instanced site that share one anchored read set,
emitted once as a function `g<n>()` (or `g<n>(i)` for an instanced site), in the order of its
first hole. It computes its read values, compares each hole's **leaf value** with the slot holding
what the hole last wrote, and writes on difference — `backend.md` §15.3's table of writes, one row
per hole kind, unchanged. A group of one path whose holes are exactly that path is the one-line
form, `const x = model.name; if (x !== g3) { g3 = x; w3.data = x; }`.

- **Every slot is declared `= unset`** — the module-level slots of a unique site, an instance
  record's fields, a branch's `br`, a derived value's slot — and never left `undefined`, because
  a `⊤`-typed value is `undefined` under `--release` (`backend.md` §4) and a slot that started
  as `undefined` would read as already holding it: a `⊤` hole or a `Maybe ⊤` scrutinee would
  never be written at first mount. `unset` is one module-level `const unset = {}` of `Rt`, which
  no value is `===` to; teardown writes it back (§5.5). Pinned by `browser/direct/UnitHoles` (a
  `⊤`-typed hole and a `Maybe ⊤` scrutinee, first mount, under `--release`).
- **Slots hold leaf values, never structures, for a scalar hole**; a hole that shows a structure
  — a markup value, a list, a `Maybe Html` — is written when its key writes it (a `value` write
  at or above its path) and compared by identity only where this document says identity holds
  (§7.4's rule for in-place update). This is what lets §7.4 update the model in place without
  the renderer missing a change.
- **Outlined by default, inlined on single use** (research 58 §7): a group called by one handler
  is written inside it; a group several handlers call is a function. The table app's `label`
  row group is called by `Update`'s identity walk and by the reconciler; its `class` group by
  `Select` and by mount.
- **Constants** (`Tree.constant`, `boundary.md` §9.4.6 version 1.4) and holes with an empty read
  set run at mount only, in the mount's group, and no handler calls them.
- **An every-render value** (`tree.everyRender`: `Random.value`, `Time.now` in a view) belongs to
  a group every handler calls; it is the one case where a group is in every W3(κ). `Debug.log`
  is grouped like any other value (`language.md` §11.11), so a fixture can count what runs.

What a handler pays per group it calls: one path read and one `!==` per hole; research 59 §1.4
found the compares around the one DOM write "nothing". What vanilla pays: the write, with no
compare, because its author knows the value changed; the compare is the one run-time step the
analysis's "possibly" leaves, and it costs about a nanosecond.

### 5.4 Derived values: a `let` per key

A constant `let` of `view` that only markup reads (`shown = top model.items`,
`language.md` §11.11's let rule) is a **derived value**: a module-level slot plus a function that
recomputes it, called in step 2 of every handler whose write set conflicts with the `let`'s read
set, before the groups that read it. On the derived sweep (top 50 of N sorted; research 59's
table) a message that writes an unrelated field recomputes nothing, as today's grouped root does,
and a message that writes `items` recomputes once and then runs the groups that read `shown`. A
`let` that reads a derived value reads the slot and inherits its read set; dependency order is
source order, since a `let` reads only earlier ones. **A derived value belongs to the innermost
branch arm that encloses every one of its readers**, and to the top level when no arm does (a
`let` inside a page's `view` read only by that page's markup; a `let` bound inside an `if`'s
`then` markup; a `let` read by an outer arm's group and by a nested arm's belongs to the outer
arm, so that the outer groups never read a slot nobody computed): it is computed at that arm's
mount, after the arm's slots are reset and
before anything else of the arm, and recomputed **first in the arm's visit** of step 3 under
the arm's liveness (§4.1, (a) before (b)–(d)) — before the arm's nested branches, its `For`
sites' scripts and its groups read it — and never in step 2, where the model may already be
another variant and the read would be a `TypeError`. A derived value read by top-level markup,
or by two arms no single arm encloses, is top-level and is step 2's. Pinned by `browser/direct/LetInArm`:
a `let` inside a page arm under `A → B → A`, the message that switches arms also writing what
the `let` reads; and, with no arm switch, a `let` that feeds both a nested `if` (`if List.isEmpty
shown`) and a `<For each={shown}>`, where the message adds an item the `let` keeps — the new
row appears and the `if` flips in the same dispatch.

### 5.5 Branches and `Show`

A hole whose expression is an `if` or `case` choosing between markups, and a `Show`, is a
**branch**: a slot holding which arm is shown (`br3`, the arm's index, or `-1` for a `Show`'s
`Nothing`) and the nodes it holds, module-level for a unique site. Each arm's markup is its own
template and group code, and each arm's groups, scripts, lists and derived values belong to that
arm and run only under its liveness (§4.1). A handler whose write set conflicts with the
scrutinee's reads (and, for a keyed `Show`, the key's) re-evaluates the condition: the same arm,
and the arm's groups that conflict run; another arm, and the old arm is **torn down** and the
new one **mounted**. That is `childHtml`'s "same kind, patch; other kind, remount"
(`backend.md` §15.4) decided by emitted code at the one site that needs it, with no block and no
runtime call.

**Teardown resets the arm's slots.** An arm's slots are module-level (§5.2) and outlive its
nodes, so without a reset an `A → B → A` switch with unchanged model values would find every
slot equal to its value, write nothing, and leave the new nodes blank. So teardown writes **the
sentinel** into every slot of the arm — one module-level `const unset = {}` of `Rt`, an object
no value can be `===` to, and not `undefined`, which today's fresh instances use
(`backend.md` §15.5) but which a `⊤`-typed value is under `--release` (`backend.md` §4: `⊤` is
`null`, or `undefined` in release), so that a `Maybe ⊤` scrutinee's slot could read as unwritten
—: its hole slots, its derived values, its nested branches'
`br`, and it empties its lists' instance arrays (and key maps) after removing their rows. Mount
then runs, in this order: the arm's derived values (§5.4), the arm's nested branches (each
evaluated and mounted the same way, recursively), its lists (every row made), and every group
of the arm — and every compare fails, so every hole is written from the model. Pinned by `browser/direct/BranchReturn` (`A → B → A` and `Just → Nothing → Just` with
the same values; a Conduit-shaped `Home → Article → Home`). A branch whose arms are text only
is a text hole with a conditional expression and no branch at all. The nodes of an arm not
shown are not kept: a switch remounts, which is what keeps an input's value from leaking between
`then` and `else` (`backend.md` §15.2).

## 6. Lists

A `For` over `model.rows` is the piece where TEA genuinely differs from vanilla: `update` returns
a new list and "which row" is lost at that return unless the compiler reads it off the arm. The
write-set contract reads it: every list write carries an edit tag and, where there is one, an index
symbol (`write-sets.md` §2.3), and the core summary table says which `List` function gives which
tag. The design follows the tags.

### 6.1 Rows and instances

A `For` site emits: a **row template** (one HTML string, cloned per row), **`make(item)`** — clone,
walk to the row's dynamic nodes, write the static-key holes (`row.id` under `keyed={.id}`: once,
at mount), run the row's groups, set `$r` on the row's root to the instance and `$h` on each
handler node — and an **instance array** `insts` holding `{ e, it, …slots }` in list order,
module-level for a unique list. The list's place in the DOM is its parent element and the node
after the list (a marker, or `null` when the rows are the parent's last children), known from the
template. Instances are the vanilla author's `trs[]`; `it` is the item the row shows.

**What a row carries on its nodes is measured, not assumed.** The shape above writes `$r` on the
row's root and `$h` on each handler node: one object and two or three expando properties per row,
which change the DOM wrapper's shape and which vanilla does not have (js-framework-benchmark's
vanilla reads the row's id from the cell's text and looks the index up). S2 compares three forms
on mount (`create 1k`, `create 10k`) and on a row event: expandos as above; **no expandos** — the
delegated listener finds the row's instance by the key read from the DOM and the list's key map,
or by the row's index among `parent.children`; and a `WeakMap` from node to instance. The form
that mounts fastest and is no larger ships, and `emit/direct/` pins it.

The row's groups are the row's holes by read set, as §5.3, with the item as a root (`write-sets.md`
§3.7's εⱼ): a hole reading `row.label` is in the group `[*].label`; one reading
`(model.selected, row.id)` is the **class group**, read by a selector (§6.4). Research 60's
`select` lost 45 % by running the class group on every row; §6.4 keeps the two-row visit.

### 6.2 Edit scripts

For a list write in `writes(κ)` at the `For`'s path, the handler does, by tag:

| tag (`write-sets.md` §2.3) | from | the script | cost |
|---|---|---|---|
| `kept`, `[κ]` with sub-writes | `List.update xs k f`, `set`, an `indexedMap` with index guards | `const i = insts[k]; i.it = get(xs, k);` then the row groups the sub-writes conflict with, on that instance (`[1]` and `[998]` for the table's `SwapRows`: two rows). `get` is core's `unsafeGet`, O(1) on a plain list and O(log₃₂ n) on a trie; an indexed script never flattens the list | O(1) per index |
| `kept`, `[*]` with sub-writes | the `map` idiom, `indexedMap` with a residue guard | the **identity walk**: `for j in 0…n: if (insts[j].it !== a[j]) { insts[j].it = a[j]; …row groups the sub-writes conflict with }` — sound because `map` returns `===` elements where `f` returned its element (`backend.md` §4, *Identity*) | O(n) compares, O(changed) writes; the table's `update every 10th`: 1 000 compares, 100 writes, research 58 §9's 0.8–0.9 ms |
| `append` | `push`, `[ …xs, x ]`, `xs ++ ys` | make the new rows, append in one fragment | O(new) |
| `prepend` | `[ x, …xs ]` | make, insert before the first row | O(new) |
| `clear` | `[]` | `parent.textContent = ""` when the rows are the parent's only children, else remove each; `insts = []` | O(1) or O(n) |
| `insert κ` / `removeAt κ` | `insertAt`, `removeAt` | one make and `insertBefore`; one `remove` and `splice` | O(n) in the array, O(1) in the DOM |
| `swap κ₁ κ₂` | `List.swap` | two `insertBefore`, two array writes — vanilla's six lines | O(1) |
| `removeSome` | `filter`, `take`, `drop`, `pop`, `slice` | the **merge**: walk old instances and new items together by item identity, removing the instances whose item is not next in the new list | O(n) compares, O(removed) DOM |
| `permute`, `replaced`, a cap, `value` at the list from `Fresh` | `sort`, `reverse`, a list from a payload or a builder, an unsummarised call | the keyed reconciler (§6.3) | O(n) |

**A script is guarded by its tag's own condition, never by the list's identity.** `List.update`
out of range and `List.swap xs i i` return `xs` itself (`backend.md` §4), so something must keep
a no-op edit from touching rows; but a test `newList !== oldList` would be wrong the day §7.4
writes a list in place (then `new === old` always), and would make every earlier slice's
`emit/direct/` shape change at S7. So the guard is computed from what the handler has — the new
list and the instance array, which holds the old shape:

| tag | the guard |
|---|---|
| `kept [κ]`, `set κ` | `0 ≤ κ < insts.length` and `get(xs, κ) !== insts[κ].it` (the element changed, not the list) |
| `swap κ₁ κ₂` | both in range, `κ₁ !== κ₂`, and the data moved: `get(xs, κ₁) !== insts[κ₁].it` — so the script is idempotent, and a list already in its new order (a `swap xs i i`, or rows an arm's mount built from the new model) is left alone |
| `append` / `prepend` | `xs.length > insts.length`; the new rows are the last (first) `xs.length − insts.length` items |
| `clear` | `insts.length > 0` |
| `insert κ` / `removeAt κ` | in range: `xs.length === insts.length + 1` (`− 1`) |
| `kept [*]`, `removeSome` | none: the identity walk and the merge are their own guards |

A positional `For` (`keyed={False}`) uses the same scripts over positions, and `replaced`
becomes the positional pass (patch `min(n, m)` rows, append or remove the rest). Pinned by
`browser/direct/NoOpEdits` (an update out of range, a swap of a row with itself, an empty
append, a clear of an empty list: no row touched, which `Debug.log` in the row shows).

**How tags compose.** One list, one key, one script: the write set carries one tag per list
path, joined by `write-sets.md` §2.4 — equal tags stay, `kept` under another tag is the other
tag, two different tags are `replaced`, and element writes survive every join — so an arm that
appends on one branch and maps on another is `replaced` for that list, and the reconciler runs;
an expression that composes two edits (`List.map f rows ++ [x]`, `List.set (List.filter …) k v`)
is `Fresh` to the core rows and so `replaced` too. The handler runs the one script the joined
tag names, and for several lists written by one key, the scripts in the source order of the
`For` sites. The reconciler is therefore reached by composition more often than by sorting;
the dump's `reconciler` line (§11) names the keys that reach it, so a surprise is a line.

**What is read how.** An indexed script reads one element by `get`; the identity walk, the
merge and the reconciler read the whole list once through the protocol (`Array.isArray(xs) ? xs
: xs.$plain()`) — O(n) for a trie whose header is new, which it is after any write to it, and
which is the cost of the idiom (the walk is O(n) anyway). A plain list, which §7.2's rule keeps
UI lists, costs nothing to read.

The index κ is **handler-evaluable** by definition (`write-sets.md` §2.3): the handler has the
payload and the old model, so `insts[id]` is one array read. A row hole that reads the row's
*position* (a two-parameter row function) is in a group an insert, remove or permute marks for
every row after the edit.

**The scripts apply to a `For` whose `each` is exactly a model path.** A `For` over a derived
expression — TodoMVC's `<For each={List.filter model.todos (visible model.filter _)}>` — shows a
list the write set has no tag for: the `each` is a derived value (§5.4), recomputed by every key
whose write set conflicts with its reads, and the new list reaches the rows as `replaced`, through
the reconciler (§6.3). Its cost there is bounded by identity: `filter` keeps `===` elements, so
the reconciler's end-trimming patches the kept rows in O(n) compares and only the rows whose item
changed are written. A derived `each` that the analysis can relate to the model list by a tag
(`List.filter` of the list by a condition that reads no written path, so that a `kept [*]` write
to the list is a `kept [*]` write to the view of it) is a precision the design allows and does
not promise; S5 measures what TodoMVC pays without it.

### 6.3 One reconciler, where it is needed

A list some key writes with `permute`, `replaced`, a cap, or `value` from an unsummarised call
needs a run-time match of old rows to new items by key, because the write set cannot say which
rows survive. That list's site allocates a **descriptor** `{ parent, end, insts, key, make, patch }`
once and the handler calls `Rt.reconcile(d, items)`: P3's `reconcile` (research 60 §2, item 4),
one pass — trim the same keys at both ends, patching the kept rows whose item changed; the two
moves of crossed ends; the middle by a `Map` from key to row, duplicate keys chained by rank
(`language.md` §11.9); a replacement that keeps no row and owns its parent emptied with
`textContent = ""` (`backend.md` §15.5's amendment of 2026-09-30). It is the only generic list
code on the platform, **one** pass where today's runtime ships two (research 59 §4.1: 1 478 B),
and it is written once in `Rt`, shared by every list that needs it, and not written for a program
whose lists are all edited by script. Its soundness does not depend on the analysis: a reconcile
is correct for any new list.

The table app reaches it through `Run`/`RunLots` (`replaced`); TodoMVC through its `For` over
a filtered expression (§6.2, last paragraph), though its model list is only ever appended to,
mapped and filtered; Conduit through every list loaded from the API (`replaced`) and through
`ChangedUrl` (`*`). The rows and live-rows sweeps, whose `For` is over `model.rows` and whose
keys are exact, ship none. Against today's platform the saving is one pass instead of two
(research 59 §4.1: 1 478 B) and nothing of the slot and kind machinery around it; where TodoMVC's
bytes land is S5's measurement, and §13 says what it must show.

### 6.4 The selector and the key map

A keyed list keeps a **key map** (key → instance) only when some key of the program needs one: a
reconciler (§6.3), or a **selector** (`language.md` §11.9: a row input read only in comparisons
with the row's key). For a selector, the handler of a key that writes the selector's path finds
the previously selected row and the newly selected one by the map and runs the class group on
those two, as today's `forKeyed` does and as js-framework-benchmark's vanilla does with
`selectedRow`; every other row is untouched. Research 60 §5.5 measured dropping this at +45 % on
`select`; vanilla's `select` is 1.39–1.74 ms, beni's 0.90–1.07, and the target is to stay under
vanilla. The map is maintained by `make` and by the scripts that remove rows; a list with neither
a selector nor a reconciler has none.

**Order, and a row that is gone.** The selector visit is part of the arm's (d), after its (c)
scripts (§4.1 step 3), so the map is the list's current shape when it is read. The two probes — the
old selector value, kept in the selector's own slot, and the new one — are looked up in the
map, and **a probe no row has is skipped**: a `Remove id` that also clears `selected` removed
the selected row in (c), and the visit finds nothing for the old probe; a row the same arm
inserted was made with the current selection and needs no visit. A probe that is `Nothing`, or
a key no row has, finds nothing, as today's runtime's probe value "no key is" does. Pinned by
`browser/direct/SelectAndRemove` (remove the selected row, select a row and remove another,
select a row inserted by the same message).

### 6.5 What a list costs in bytes

Per `For` site: the row template, `make` (~80 B), the scripts the program's keys need
(~40–80 B each), the delegated listener (~120 B) if the row has handlers, the key map (~60 B) if
needed. Per program: the reconciler (~450 B) if needed. For the table app that is every script,
the listener, the map and the reconciler; research 60's P3, which shipped all of them in one
page, was 2 243 B with core counted apart, and §13's target counts core.

## 7. The model half

Research 60 §5's finding: once the renderer runs only what a message can reach, the gap to vanilla
is the model — core's `List` running cold, a spread chain per nested update, code run once per
message that never warms. P3 copied beni's model code verbatim and measured it; this section is
what changes.

### 7.1 The arm, specialised to its key

The handler inlines `update`'s arm (§4.1): no `case msg of`, no message allocation for a view
event, the payload in parameters. A nested update through helpers (`bumpK n = { n | child =
bumpK+1 n.child }`, 128 distinct functions on the depth page) stays a chain of calls in the
development build, and the release optimiser's single-use inlining writes a helper called once
where it is called (`backend.md` §9), which research 60 §4.3 measured at a third of the depth
gap. The rest of that gap is the copy, §7.4.

### 7.2 `List`: the representation stays, the idioms are compiled

`List` is the owner's decided one sequence type, array-backed, E1tp (`backend.md` §4, *Lists are
arrays*): a plain array until written, a view for a pattern's `rest`, a 32-way trie with a
claimable head and tail past the thresholds (`push` at 32, `set` at 256, `cons` at 32). This
document changes none of it (CLAUDE.md rule 10). What it adds is on the compiler's side:

- **An accumulator loop builds a plain array.** The table app's `buildFrom` prepends one row per
  iteration onto an accumulator parameter and returns it at the exit, so after 32 rows every
  prepend is a trie operation and the program ships the trie's write half, 526 B in context
  (research 59 §4.1), to build a list it then only reads. A tail-recursive loop whose accumulator
  parameter is only ever `[ x, …acc ]`-prepended (or `[ …acc, x ]`-appended) and otherwise only
  returned at the exit — never read, never passed elsewhere — is a **building loop** in the sense
  of `backend.md` §8's *Tail calls modulo cons, onto an array*: the compiler builds it in an owned
  plain array (invariant 5), reversed once at the exit for a prepend accumulator, and `cons` is
  never called. That is `backend.md` §8's rule extended to the accumulator shape, specified there
  when built (slice S3), shared by both platforms; it removes the trie from the table app and from
  every Elm-style `go acc` loop, and makes `RunLots` one array of 10 000 rows.
- **An indexed script reads one element** (`get`, §6.2); only a walk over the whole list reads
  it through the protocol (`length`, `Array.isArray`, `$plain()`), once per handler, into a
  local. A trie's `$plain()` is cached per header (`backend.md` §4, invariant 1), and a header
  is new after every write, so a walk after a write to a trie flattens it: O(n), the walk's own
  order.
- **A `List.update`/`set` on a long list** copies ≤ 256 elements or path-copies a trie; research
  60 §4.3 measured one such call at 0.03 ms cold on 30 000 rows, and that is the price of an
  immutable list until §7.4 writes the slot in place. §13 prices it in the rows criterion.

What the page ships of `List` is what it reaches: a TodoMVC's `map`, `filter` and `append` on a
plain list are a few hundred bytes (research 59 §4.1: `indexedMap` 88, `filter` 82, `append` 188
in context); the trie's write half ships for a program that pushes, prepends or sets past the
thresholds outside a building loop — and **`set` past 256 elements births a trie as `cons` past
32 does** (`backend.md` §4, *the read/write split*: "a trie is born only in a writer"), so a
program that calls `List.update` or `List.swap` on a 1 000-row list ships the write half though
it never prepends. The table app as written does not (`SwapRows` and `Update` are `indexedMap`,
which builds a plain list), but the rows sweep does (`List.update` on 30 000), and the S0 stats
gate (§14) measures the write half's bytes under a `set`-only program with `size-parts.mjs`
before §13's table-app estimate is believed. That is a finding about `List` for the owner, not
a change asked for: **a program that prepends to, or sets into, a long list pays ~500 B for the
trie, and the alternative — a plain copy, O(n) per write — is a time cost, not a guarantee.**
The size and speed of `List` for small and large lists are measured in S2 and S3 on both
platforms and reported in `plans/compile-away.md` B1.

### 7.3 Nested pages and same-variant rebuilds

Conduit's `Main.update` rebuilds its page union with its own variant (`Home (Home.update sub
home)`); `write-sets.md` §3.4 reads that as a `node` write at the root and the page's writes
below `ρ.Home#0`, so the handler for `GotHomeMsg · ClickedTag` writes the home page's two holes
and nothing of the frame. The model code is the arm as written: `Con(Home, …)` is one small
allocation and one spread below it. In-place (§7.4) turns the spread into an assignment when the
page record is owned, and the `Con` stays a two-field object — V8's cost for it is tens of
nanoseconds.

### 7.4 In-place update, where the path is owned

The last slice of the model half (S7), specified here so that every earlier slice keeps it
possible. The write set of key κ is also the list of assignments an in-place update would make:
a `value` write at `p` is `m.a.b.c = v`, a `node` write is nothing — the object at `p` is kept.
It is sound when **no reference to any object on the written path exists outside the model**,
so that assigning through it changes nothing a program or the page holds. The condition is a
static, whole-program property of a path, computed by the same interpreter as the write set:

> A path `p` is **owned** when (1) every abstract value any key or `init` places at `p` or at a
> prefix of `p` is a `Rec(q, …)` with `q` the same path, a `Rec(none, …)`, a `Con` or `Tup` of
> owned parts, a `Lit`, or a `Lst(none, …)` — never `Same(q)` with `q ≠ p`, never `Fresh`; and
> (2) the value at `p` and at every prefix of `p` is never **read whole into anything that
> outlives the dispatch**: never a `Same(p…)` placed at another path by any key, never an
> argument of a call the analysis does not summarise, never captured by a lambda that becomes a
> `Cmd`, a `Sub` or a stored function, never the payload of a message a view event sends
> (`onClick={Save model.form}`), never passed to `Debug` or `Js`, and never a value a `For` row
> shows as its item (an instance's `it` holds it).

**A list's container and its elements are owned separately.** For a list path `p`, condition (2)
is asked of the list value itself — the array — and (1) of what is placed at `p`; the elements
at `p[*]` are a path of their own with their own answer. A `For`'s instances hold the *items*
(`it`), never the list (scripts are driven by tags, §6.2, so no instance array keeps a reference
to the list it shows), so `model.rows` can be **container-owned** while `model.rows[*]` is not:
`List.update rows k f` on a container-owned, **plain** (`Array.isArray` at run time; a trie is
written through `set` as before) list is `a[k] = f(a[k])` in place — the slot assigned, the item
still built by `f`'s spread — and `List.set`, `swap`, `push`, `insertAt` and `removeAt`
likewise. The element path is owned, and the item written in place, only when (2) holds of the
elements too, which it does not for any list a `For` shows.

The root `ρ` of a `Tea.sandbox` whose `update` never returns `model` from inside a message and
never logs it is owned by (1) and (2); the depth page's `child` chain is owned at every level;
the width page's fields are owned; the table app's and the rows sweep's `rows` are
container-owned and their elements are not; `selected`, `nextId` and `seed` are owned. For an
owned path the handler emits the assignments and skips the spreads; for a path that is not, the
arm's spreads stay. **Two rules keep the page right**:

- **A group never decides "unchanged" by the identity of an object on an in-place-written path.**
  Slots hold leaf values (§5.3); the identity walk of §6.2 compares items, and an item's path is
  never owned by (2)'s last clause; a script's guard is its tag's condition and never the list's
  identity (§6.2), so an in-place `a[k] = v` is still followed by the row's write. So in-place
  writes and identity compares never meet, which is the renderer-side blocker research 55's
  header note named and this design removes by construction.
- **The old model is dead after the arm.** Nothing holds it: there is no `view` to hand it to, no
  `lastRendered` to compare with (today's `backend.md` §15.11 check is gone), and (2) says no
  program value does. `language.md` §11.12's promise — an untouched field keeps its identity — is
  kept for every value a program can observe; what changes is that a *written* field's record may
  be the same object as before, which no beni program can tell and which this document's two
  rules keep the page from relying on. *Amending W27 is the owner's: Q4 in §15.*

What it buys, from the measurements: the width page's 1 024-field spread (V8's dictionary cliff at
1 021 fields, research 59 §2) becomes one assignment and the curve is flat; the depth page's
128 spreads become one assignment; a `List.update` on an owned list of 30 000 becomes `a[k] = v`
on the plain array (the trie's path copy and the 256-threshold no longer apply to a write the
compiler makes itself, since the array is unshared by (2)). In bytes, a nested write is
`m.a.b.c=v` where a spread chain is ~10 B a level.

## 8. Guarantees, paid where used

### 8.1 Controlled inputs

The promise is `backend.md` §15.3's, unchanged, and it covers **exactly the properties the
vocabulary declares `stateful`**: in `html`, `value` on `input`, `select` and `textarea`,
`checked` on `input`, `selected` on `option`. After every dispatch, every element with one of
those attributes shows the model's value in that property, though the user changed it and
`update` rejected the change. Nothing else the user can change is covered — `open` on `details`
and `dialog`, `scrollTop`, a `<select>`'s selection through `value` on a `multiple` select beyond
its first option (`backend.md` §15.3 lists these) — exactly as on today's platform: such a
property is compared with the value last written, not with the page, so a model that returns to
its previous value after the user changed the page writes nothing. A vocabulary that declares
another attribute `stateful` extends the promise and must name the event that reveals its change. The mechanism is the **edited set** specified there (the owner's R2 decision), reused
whole: `control(el, prop, v)` writes the property when the page's differs and keeps `v` on the
element; four capture listeners (`input`, `change`, `click`, `reset`) and `pageshow` mark the
controls an edit may have changed; the runtime's own writes mark them too; `end()` (§4.3)
reconciles the marked controls and clears the marks. What changes is *when*, and in the
promise's favour. Today a control with no handler is marked and reconciled "when a render
ends" (`backend.md` §15.3), which is the next render some other message makes; until then the
edit stays on screen. Here the four names also get a **bubble-phase listener on the document**,
added with the capture ones by the first `control` call, which calls `send(noop, e)` — a body
that does nothing — so that `end()` runs and reconciles the marks **after every user edit**,
handler or none. It runs after every element listener, so a control's own handler has already
dispatched and reconciled, and the no-op's `end()` finds nothing marked; it is a few bytes, only
on a page with a control, and it makes the promise "after every dispatch *and after every edit*
a controlled element shows the model". A `reset`'s and a prevented checkable click's held
controls are reconciled in the timer today's design already uses. Pinned by
`browser/direct/ControlledNoHandler` (typing into a control with no handler is put back at
once; today's platform leaves it until the next message). The listeners are installed by the first `control` call, so a page with no controlled
element ships none of this (~250 B when used, **[estimate]**), and an unrelated message visits no
control — research 60 §3.3 measured the live-rows page at P2's level with exactly this.

### 8.2 Defects

A **defect** is a throw that escapes program code, and every entry into program code is a
`send` (§4.3): a listener body with its payload read, a handler, a group, a script, a derived
value, `end()`'s after-render work, a fiber's resumption through `dispatch`, and `run`'s mount —
`run` mounts every program by `send(mount, program)`, so a throw in `init` or in a mount's first
groups is a defect like any other. `send`'s `finally` sets `dead`, after which every `send`
returns at once; the throw goes on to the host unchanged and is reported as an uncaught
exception; in a development build an `error` listener installed at `run` shows the crash
screen; and when the page reaches `core/Task`, the stop calls `Task.shutdown`, whose teardown —
every finaliser once, every host resource released, no other program code run — is
`boundary.md` §9.8.14, unchanged and shared with today's platform. No `catch` anywhere (rule 9).
A page that reaches no `Task` ships none of the teardown. Cost: the guard, measured free
(research 59 §1.3); the screen, development only. Pinned by `browser/direct/DefectInListener`
(a throw in a payload extractor), `DefectInAfterRender` and `DefectInMount`, beside today's
`Defect*` pages.

**A program built by a function has state per mount; one program value mounted twice is a
fault, never an alias.** A program site reached through a function with parameters —
`counter start = Tea.sandbox { init = start, … }` used as `programs [ counter 0, counter 5 ]` —
is two program values, and each mount gets its own state: such a site's `model`, node handles,
slots and lists live in a **mount record** allocated by `run` per mount (the shared-site form
of §5.2 applied to the program), and its handlers take the record; a site that is a top-level
constant (`main = Tea.sandbox …`, the common case) keeps module-level state. That is rule 7's
escape, built in. What cannot be allowed is one program *value* mounted twice —
`programs [ main, main ]`, or `mountAt` applied twice to one constant — because the two mounts
would share one `model` and one set of slots and show one page's writes in the other: the
compiler refuses the static case (the same top-level program value named twice in a `programs`
literal, or in one and in a `mountAt`) with `program_mounted_twice`, whose message names the
escape — *build the program with a function so each mount is its own value* — and `run`
refuses the rest before any program renders (a `$mounted` mark on the value), as it refuses a
missing element or one that already holds a program (`backend.md` §15.11: a fault of the page).
A guarantee is at stake (two mounts would show a wrong page), so the aliasing case is an error
and not a warning. Pinned by `browser/direct/ProgramsByFunction` (`counter 0` and `counter 5`,
each counting on its own) and `build/bad/DirectMountedTwice`; the run-time refusal follows
today's rule and, like today's, has no page fixture (an uncaught exception fails a page case).

### 8.3 The page is a function of the model

This is the guarantee the analysis stands in for, and it is kept by two things: `write-sets.md`
§1.3's soundness (every changed path is covered by the key's write set, so every hole that reads
it is in a group the handler calls) and the comparison in every group (a covered hole whose value
did not change is not written). A missed write — an aliasing the analysis did not see, a core
row that overstates a guarantee, a `Js` call summarised wrongly — would be a stale screen that
nothing on the page catches: the Svelte 3 failure. So it is **tested three ways, and two of them
from S1**, before any guarantee machinery is built on the design:

1. **The differential corpus** (§12.3): every `browser/` fixture is built for both platforms and
   the transcripts must be equal after every step; V3's adversarial campaign
   (`compile-away.md` §4) attacks it directly from S4.
2. **Differential fuzzing, from S1.** `tests/browser/fuzz.mjs` generates random message
   sequences — random `Int`s, `String`s, `Bool`s, constructors of the payload types, and for a
   view event a random handler node of the page — and replays each sequence on the program
   built for `browser-tea`, which compares every group on every message and so is an
   independent oracle, and for `browser-direct`, DOM-equal (`p3-verify.mjs`'s comparison) after
   every step. **Where the messages come from**: from the **message type**, as the checker
   records it (every constructor and its payload types, under a hidden `--msg-types` dump), not
   from the key tree the lowering consumes — so a constructor the key tree mis-filed is still
   generated, and reaches the direct page through its dispatcher, which a fuzz build emits
   whether or not the program has carriers (a hidden, test-only `--fuzz` flag, as the release
   corpus has `--allow-debug`). What the fuzzer shares with the lowering is only the checker's
   type table, which both platforms also share; a mistake there is `write-sets.md`'s default
   child rule's to catch (every constructor is under some leaf), and the gap that remains — a
   constructor that exists in neither the type table nor the tree — cannot arise, since the
   tree is built from the table. The gates run it with fixed seeds within the test budget on
   every `browser/direct/` program, as the determinism test runs the corpus at `--jobs=1` and
   `--jobs=8`; `zig build fuzz` runs long sweeps. A difference is a defect with a red-first
   fixture and a rule corrected in `write-sets.md`.
3. **A development-only verify mode, from S1.** A development build of this platform emits,
   beside the handlers, `verifyAll()`, which `send` calls at the end of every dispatch in
   development and `--release` never emits. It checks **values and structure** of every live
   site: every scalar hole's value against its slot; every branch scrutinee re-evaluated
   against `br`; every derived value recomputed against its slot; every list's items against
   its instances — `xs.length === insts.length` and `get(xs, i) === insts[i].it` for each
   `i`; a nested branch's and a row's holes recursively. **A derived value is never compared by
   identity, at any depth**: recomputing a `filter`, a `map` or a record gives a fresh object
   on every correct dispatch, and a `List.map (λt → { t | done = True })` gives fresh elements
   too. It is compared **structurally**: a scalar by `===`; a list by length and then each
   element structurally; a record, tuple or constructor field by field, recursively, to the
   leaves; a function value not at all. The identity rule holds for exactly one check, `get(xs,
   i) === insts[i].it`, because a `For` assigns the very object it shows. A derived value
   longer than 1 000 elements is compared by length and its first and last 100 elements only, so
   the development check stays usable on large lists; the cap is a known limit of the check, not
   of the guarantee (§16). Any difference is a defect (§8.2, naming the hole, list or branch). **It
   must change nothing unless the compiler is wrong**, so it skips what evaluating again would
   change: an every-render group (`Random.value`, `Time.now`: a different value each time is
   not a missed write), and any value whose evaluation **reaches** a `Debug` call — directly
   or through any function it calls, transitively over the call graph, which the compiler
   already knows per function because `--release`'s `debug_in_release` refuses exactly those
   (evaluating it again would print again, and `GroupedReads`-shaped fixtures count prints); a
   correct handler leaves everything else equal to its slot, so a page with a correct compiler
   runs the same with verify on and off, and `browser/direct/VerifyQuiet` pins that it does:
   every-render values, a `Debug.log` in a view hole, a hole calling a helper that logs two
   calls deep, a list-valued `let` recomputed and compared per element, and a derived list of
   fresh records (`List.map` building a record per element), all with verify on. It catches the Svelte 3 class at its first occurrence, on every
   development page a developer runs and on every development page of the corpus. Its cost in
   development is a full compare per dispatch, today's cost.

### 8.4 Development and release

**A release build behaves exactly as the development build does** (`backend.md` §9's rule), and
on this platform the two emit the same handlers, the same groups and the same scripts; `--release`
renames the module-level slots, handlers and runtime imports as the top-level names they are,
prints compactly, specialises helpers to their call sites (which is what removes the sub-message
of §4.1's nested keys and the per-level functions of §7.1), cuts the runtime module to what the
program reaches, and refuses `Debug` as it does today (`debug_in_release`). What differs between
the builds is observable only through `Debug`: a `Debug.log` in `view` prints when its group runs
(`language.md` §11.11, already relaxed), and one in `update` prints in the handler. The crash
screen exists in development only (`Js.development`); in release a defect is logged and the page
stops. **Source maps**: a development build writes a `.mjs.map` beside every module as today
(`backend.md` §11.1); a hole's write is positioned at its hole (`cx.at`, `boundary.md` §9.4.3) and
an arm's statements at the arm, so a defect's stack names the hole or the arm in the source.
Release maps are not started, as before.

## 9. Composition

### 9.1 `Html.map`

`Html.map f child` wraps the child's messages. When `f` is a **constructor**, or a constructor
with handler-evaluable arguments applied through a placeholder (`ChildMsg row.id _`), the key
of every handler node under the map is known at compile time: a `<button onClick={Inc}>` under
`Html.map GotCounter` calls `send(h$GotCounter$Inc, …)` directly, with the placeholder's arguments
read at the event. There is no context chain, no `$$cx` write at mount and no walk per event;
research 59 §1.3's 0.6 µs and the 26 bytes of `backend.md` §15.11's last amendment are gone.
When `f` is anything else — a lambda, a function from a value — the node's listener builds the
child message, applies `f`, and hands the result to the dispatcher (§4.4), which that program then
has. A nested `Html.map` composes the same way, innermost first (Elm's order).

### 9.2 Components and helpers

A component or a markup helper is inlined at its call site when the site is unique (§5.2); its
holes read the arguments' paths, which anchor to the model through the call (`write-sets.md`
§3.6), so a prop that never changes is static and a prop a key writes is a group that key's
handler calls. `Tree.constant` arguments (`button "run" "Create 1,000 rows" Run`) make the whole
call static: the table app's six buttons are template text with a direct listener each. A
component called from an instanced site is part of that site's template; a recursive one is on
the value path (§5.2).

### 9.3 Several programs on one page

`Browser.programs` and `Browser.mountAt` keep their meaning (`backend.md` §15.11). Each program
is compiled on its own — its own `model`, slots, handlers, lists, listeners — in one module, its
state namespaced by program. A program mounted inside another's markup receives its own events
through its own listeners; the event then bubbles to the outer program's handler nodes by the
DOM's bubbling, as `tests/corpus/browser/tea/TwoPrograms` pins — and an outer list's delegated
walk never runs the inner program's handlers, because it discards what it collected below a
mount root as it discards another list's rows (§4.2; `browser/direct/NestedPrograms`). One `send` guard serves the page:
the ordering rule is page-wide (`boundary.md` §9.8.4 rule 2), and so is `dead`.

## 10. Effects

### 10.1 Commands and subscriptions

`Tea.element` and `Tea.application` keep their types and their meaning (`boundary.md` §9.8). The
command driver — the keyed table, the four policies, outlets, `Restart` — is `browser-tea`'s
`Tea.beni` logic, written over `browser`'s `Hosted`, and this platform's `Tea` module is that code
driven by handlers instead of by a run-time `view`: the handler's step 6 calls `perform host cmd`
with the command its arm returned. **Subscriptions are diffed by write set**: `subscriptions
model` is analysed like a `view` value, its read set anchored, and only a handler whose key's
write set conflicts with it runs the diff (`settle`); every other handler skips it, where today's
loop settles on every render. A fiber's message arrives through the dispatcher (§4.4), so a
program with commands has one.

What ships: `core/Task` and the driver, by reachability, as today — the empty `Tea.element` page
and the `fibers` line of `bench/size.mjs` are the numbers, and §13 keeps research 51's finding in
view: TodoMVC's one routing subscription pulled 1 948 B of fiber kernel. This is the one piece of
the platform that is a generic run-time loop by nature — the dispatcher, the keyed table, the
policies, outlets, `settle` and the kernel behind them — and the design keeps it as such on
purpose: effects are not compile-away material, and "only where reached" is the whole of what
this platform does for them. For a real application that is most of the bytes above the
renderer's, which is why Q5 and the fiber kernel's own size work (`plans/effects-plan.md`)
matter to §13's application targets more than anything in §4–§6. This document does not
change the fiber runtime (its bar is Effect v4 parity, `plans/effects-plan.md`); it notes for the
owner that `boundary.md` §9.8.11's rule — a command that cannot wait runs with no fiber — has no
twin for subscriptions, and that the twin would take the routing subscription off the kernel
(Q5, §15).

### 10.2 The after-render point

`Dom.rendered`, after-render work (`Hosted.afterRender`, focus after a render) and
`Browser.flush` were defined against a render loop. On this platform: the after-render point of a
dispatch is `end()` (§4.3), after every write of the handler and of the sends it queued, where the
waits resume in order and the after-render work runs; a message such work sends is queued and
applied **in the same dispatch**, by §4.3's loop, before `end()` runs again. **`Browser.flush` is a no-op** — there is nothing queued to flush; it stays in the API
so a program builds on both platforms, and its documentation says so (Q3, §15).

## 11. What the compiler analyses

All on the compiler's side, platform-independent, consumed by the `direct` lowering:

1. **Write sets, anchored reads, keys, literals** — `write-sets.md` whole, unchanged. It is the
   contract; this platform is its first consumer (R3, R4, R5 of `compile-away.md` are this
   platform's §5.1, §4 and §6). The gate (`write-sets.md` §8.2) stands.
2. **Site multiplicity** (§5.2): for every markup root, unique or instanced, and for a helper
   whether it is inlined per call site. One walk of `view` and the markup helpers it reaches,
   following holes, branches, `Html.map`, `For` rows and `List Html` holes; a helper reached
   through a cycle is recursive. Linear in the markup.
3. **Carriers** (§4.4): whether any message of the program is a run-time value. True when the
   program is a `Tea.element`/`application`, when any `Html.map`'s function is not a
   constructor shape (§9.1), when any `Sub` or `Browser.Events` subscription exists, or when an
   arm reads `msg` whole or stores a message in the model. One scan.
4. **Ownership** (§7.4), for S7 only: per path, the two conditions, from the write-set
   interpreter's placements plus an escape scan (call arguments, lambda captures that reach a
   `Cmd`/`Sub`/stored function, view event payloads, `Debug`/`Js` arguments, `For` items).
5. **Building loops** (§7.2): the accumulator shape of `backend.md` §8, in the backend, for both
   platforms.

None produces a diagnostic; every limit yields the coarse answer (the value path, the dispatcher,
the spread, the trie, the `*` key), never an error (rule 7). Each is dumped, **from S0, before
any of it is consumed**: `beni dump --stage=writes` gains, per program, a `site` line per root
(`unique`/`shared`/`instanced`/`value`), `markup_value_roots` (the count on the value path), a
`carriers` line, a `pairs` line (the (key, group) pairs and the share of groups every key
calls), a `reconciler` line (the lists some key writes `replaced`/`permute`/`*`, with the keys),
a `patchAll` line (the keys of class `*`), and in S7 an `owned` list. These are the S0 **stats
gate** (§14): the numbers §13's kill criteria name, measured on every corpus app, the table app,
TodoMVC and Conduit by the analysis alone, so a design that fails on Conduit's shape is stopped
at S0 and not at S6.

### 11.1 The program lowering interface

Today's markup lowering interface (`boundary.md` §9.4) hands a lowering one markup root at a time
and never the program. This platform needs the program: `init`, the key tree with each key's arm,
the write sets, `view`'s roots with their anchored reads, `subscriptions`. So the interface gains,
additively (a minor version; a lowering that does not set it is handed roots as before), a
**program hook**: `Lowering.program`, called once per recognised program record
(`write-sets.md` §1.1's shape) with a `Program` handle, and context calls to walk it — the keys and
their payload shapes; `cx.arm(key, block, params)`, which emits the arm's statements for a key
into a block with the message's fields bound to given names and returns the result expression;
`cx.writes(key)`, `cx.reads(value)`, `cx.conflicts(key, value)`, `cx.site(root)`,
`cx.carriers()`, `cx.literal(path)`; and the init value. The lowering returns the program's mount
expression, which the platform's program constructor (`Tea.sandbox`, a `foreign` the lowering
recognises as a program site) evaluates to.

**What the hook needs, and the one thing it cannot do without.** It needs `view`: a function
whose body the compiler can reach as markup — the record's `view` field a top-level function or
a lambda, or a value the write-set summaries resolve to one (`view = Page.frame viewBody`,
through its summary). It needs `init` as a value. It does **not** need `update` to be keyed: an
`update` the analysis cannot key (`write-sets.md` §1.1's unrecognised shapes — `update =
withLogging update`, a record a helper builds whose `update` the summary cannot resolve) is the
single `*` key of §4.1, `h$All`, with every message a value and `patchAll` after the call. So
no shape of `update` is refused, and the hook degrades to today's cost, never to an error (rule
7). The one refusal left is a `view` the compiler cannot reach as markup — a function value
chosen at run time (`view = if flag then viewA else viewB` with `flag` a run-time value), a
`view` from a payload — and it is refused with `view_not_compiled` because **no fallback
exists**: this platform has no run-time renderer to hand an unknown function to, and building
one would be today's platform. The message names what was found, the shape needed, and
`browser-tea`, which renders any `view`. Research 61's and 62's programs have no such `view`;
the dump counts it (`program <unrecognised>`) so its frequency is known before it is ever hit.

The exact signatures are written into `boundary.md` §9.4.6 as a dated version when S0 builds them,
as every interface version has been.

## 12. The comparison harness

### 12.1 Two platforms, one source

`platforms/browser-direct/` is a platform package layered on `browser` (`boundary.md` §9.1):

```json
{ "platform": true, "name": "browser-direct", "platforms": ["browser"],
  "program": "Browser.Program",
  "markup": { "lowering": "direct", "module": "Rt" },
  "zig": "zig/root.zig",
  "reexports": ["Html", "Browser", "Cmd", "Sub", "Time", "Dom", "Http", "Browser.Events", "Browser.Navigation", "Random", "Storage", "Log"] }
```

It declares a module **`Tea`** with the same API as `browser-tea`'s — `sandbox`, `element`,
`document`, `application`, `Program`, `Document` — so **the same source builds for both**:
`beni build --platform=browser-tea Main.beni` and `--platform=browser-direct Main.beni`, with no
edit. `main : Browser.Program` stays the type (`program` may name a type of any module of the
chain), and the direct `Tea.sandbox` produces a `Program` value of the shape `Browser.mountAt`
and `programs` already rewrite (`{ a, n }`), so those two need no copy.

**Shared, one copy** — the compiler and its analyses (§11); `core`; `html` (the vocabulary and
the parser table); `browser`'s capability modules and siblings (`Http`, `Time`, `Dom`, `Storage`,
`Random`, `Listen`, `Log`, `Browser.Events`, `Browser.Navigation`, `Cmd`, `Sub`, `Hosted` and the
defect teardown); the markup interface's tree; the corpus driver and happy-dom; the bench harness.
**Not shared** — the lowering (`zig/direct.zig`), the runtime module `Rt.beni` (the guard, the
reconciler, the edited set's reconcile, `run`; beni over `Js`, as today's `Rt` is), and the
`Tea` module, whose command driver is a **copy** of `browser-tea`'s `Tea.beni` logic driven by
handlers — about 300 lines duplicated for the comparison period, deleted with whichever platform
loses. `browser`'s own `Rt` and `dom` lowering are in the chain and unreached, so a
`browser-direct` build writes none of them.

### 12.2 Subjects, pages and measures

The harness is `bench/ui/` as it stands (research 60 §1's method), with these additions:

- **Subjects**: `beni-direct` (development) and `beni-direct-release`, built by
  `--platform=browser-direct` from the same sources as `beni`/`beni-release`; beside `beni`,
  `beni-release`, `p3`, `p2`, `vanillajs`, `solid1`. Every batch rotates subjects per page as the
  harness does, in one batch, on one machine, load recorded.
- **Pages**: the nine sweeps (`holes`, `rows`, `width`, `depth`, `derived`, `live`, `helper
  rows`, `helper tree`, `burst`/`stream`), the table app, TodoMVC (`bench/todomvc/`, which gains
  a **vanilla subject**: tastejs's `vanilla-es6` TodoMVC, vendored and checksummed as
  `build.mjs` vendors js-framework-benchmark's files, so that TodoMVC has a vanilla floor for
  bytes and for three timed messages — add a todo, toggle one, clear completed) and Conduit
  (`examples/conduit/`, bytes, and three messages timed untraced in Chrome against a scripted API
  loaded in the page — a feed tab, a favorite, a keystroke in the editor — against today's
  platform; there is no vanilla Conduit, and the floor there is the DOM write itself).
- **Measures**: script ms traced (`scaling.mjs --full`) **and** untraced real clicks
  (`--untraced`) for every speed number; bytes by `scaling-sizes.mjs` and `sizes.mjs` (minified,
  brotli 11, the whole bundle), with `size-parts.mjs`'s part-by-part attribution for the table
  app on both platforms (B1); mount time (`create 1k`, `create 10k`); and the `bench/size.mjs`
  `page` lines for the empty page per platform.
- **A slice's batch** is the sweeps the slice touches at three points each plus the table app,
  and finishes in under fifteen minutes; the full nine-sweep batch is opt-in (`--full`), as the
  owner's rule for benchmarks says.

### 12.3 Correctness: the two platforms are each other's oracle

A `browser/` corpus fixture under `tests/corpus/browser/direct/` is built for **both** platforms
and driven through the same `.steps`; both transcripts must equal the one golden. Every fixture of
`browser/dom/` and `browser/tea/` is added to the direct kind as its slice reaches the feature it
pins (§14), so the whole existing page corpus becomes the differential test research 58 §8 item 2
requires, with happy-dom in the gates and headless Chrome under `test-browser`. `p3-verify.mjs`'s
DOM-equality check (every element, attribute, text and input value, comments skipped) is the
same comparison for the bench pages, and for the fuzz sequences of §8.3, which replay random
key sequences on both platforms from S1. `emit/direct/` and `emit/release/direct/` pin shapes:
that a handler is one compare and one write, that a page has no reconciler, that a static hole
is text. The development verify mode (§8.3) runs on every development page of the direct kind,
so every fixture step is also a full compare of every group.

## 13. Targets and kill criteria

Research 58 §9's criteria are the owner's bar and are kept as written in
`plans/compile-away.md` §1; they judge the whole output, model included. This section says what
this design expects against them, per page class, in vanilla multiples, untraced real clicks.
**Every figure in the table is a hypothesis**: the P3 numbers are a hand-written page's
(research 60), the rest are this document's estimates, and nothing here is a measurement of a
generated program until the slice named measures it. The last column says what would have to be
true for the criterion to be met, not that it is.

| page class | speed, hypothesis | bytes, hypothesis | what it rests on |
|---|---|---|---|
| **empty page** (`bench/size.mjs` `page`: one program mounted at the body, `send`, `run`, no `mountAt`/`programs`) | — | ≤ 300 B brotli **[estimate]**; today 1 234; P3's loop and root were about 150 | the guard (~100 B), `run` and the mount, and nothing else reached |
| **static-heavy** (holes 10 / 10 000, width ≤ 256, helper rows, helper tree) | ≤ 1.15× (P3 by hand: 1.18 / 1.04, with a flush this design drops; the floor is the one DOM write) | holes: the HTML + ≤ 300 B at any N (P3: 394 / 442); 0 B per static hole | §4.1, §5.1; S1 |
| **width 1 024** | ≤ 1.3× until S7, then ≤ 1.15×; before S7 V8's dictionary cliff stays (research 59 §2) | ≤ 2 B per field | S1, then §7.4 at S7 |
| **depth 128** | ≤ 1.3× until S7 (P3: 1.29), then ≤ 1.15× | ≤ 4 B per level | S4, then §7.4 at S7 |
| **long keyed list, one edit** (rows 30 000) | ≤ 1.3× until S7 (P3: 1.31, 0.03 ms of it `List.update` on a trie); ≤ 1.15× after S7 **only if** the list is container-owned and plain (§7.4) — the rows sweep's is; a list that is a trie keeps the path copy and the 1.3× | ~1.5 kB (P3: 1 643) | §6.2; S2, then S7 |
| **swap** (rows 30 000) | ≤ 1.0× (P3: 0.98) | the same page | §6.2; S2 |
| **live rows 10 000** | ≤ 1.15× (P3: 1.25 at a 5 µs clock, with the flush) | ≤ 1.1 kB | §8.1; S4 |
| **derived 100 000** | flat, ≤ 1.15× | ≤ 1 kB | §5.4; S4 |
| **bursts and stream** | **the K = 1 ratio at every K**: ≤ 1.15× for all K, and the stream not worse than K = 1. With no batching, K messages cost K times the per-message path (guard, arm, spread, compares, write), so the ratio to vanilla is the one-message ratio; the 13 % win at K = 1 000 was the batching this design deletes, and before S7 every message also pays a model spread vanilla's `tick++` does not | — | §4.3; S1 |
| **the table app** | every operation ≤ 1.2×; `select` ≤ 1.0× (the selector kept); `swap` ≤ 1.2× with the exact edit from `List.swap` or the index guards (`write-sets.md` §10.4); **and no operation slower than P3** (below) | ≤ 2× vanilla = 2 830 B: P3's own module 2 243 + core after §7.2's building loop ≈ 400 → **≈ 2 650 [estimate]**, a 6 % margin on an estimate, and the ≈ 400 holds only if the trie's write half is not reached (§7.2: the S0 stats gate measures it) | §6; S3 |
| **TodoMVC** (`bench/todomvc/apps/beni/`, at **100 todos and 1 000 todos**: add one, toggle one, clear completed) | the three messages ≤ 1.2× vanilla TodoMVC at 100 todos; at 1 000, toggle-one is O(n) through the reconciler (§6.2, a `For` over a filtered list) where vanilla is O(1), so the target there is ≤ 1.3× and the measurement says what the derived-`each` precision §6.2 allows would buy | the **routing build** (the corpus page, no editing: today 10 053 B) ≤ 2× vanilla TodoMVC and below Svelte 4's 4 246 (tastejs's, persistence included) — **which depends on Q5** (§15): with the routing subscription on the fiber kernel, 1 948 B of it is the kernel (research 51 §0.2) and the target is out of reach; the sandbox build (today 5 317) is reported beside it | §6.3, §10.1; S5 |
| **Conduit** | every key's handler bounded but `ChangedUrl`; a page message ≤ the frame's one DOM write + the page's groups | ≤ 0.7× today's 30 842 brotli, **if** the (key, group) pair count and the shared-site gate (§5.2) hold the handlers linear; the S0 stats gate gives the count | §4, §5.2; S0 for the counts, S6 for the bytes |

**Which of research 58's criteria this design expects to miss, and why.** None on speed, with
the width and depth and long-list points reaching 1.15× only at S7 (in-place), which research 58
itself ordered last. On bytes, the table app at ≤ 2× is expected to land within about a hundred
bytes either side of the line: the renderer's share is under the bound (research 60 §4.6) and the
rest is core's `List`, which §7.2's building loop cuts but does not remove (`append`, `get`,
`indexedMap`, `filter` stay). If it misses by core alone, that is reported as a finding on `List`
for the owner and not restated (rule 10, and `compile-away.md` §6).

**The number that justifies a compiler over a hand-written page.** P3 is a page a person wrote
with the facts a compiler has; a generated page that is no better than P3 is P3 renamed, at the
price of a second platform. So at S3, on the table app in one batch: the generated page is **no
slower than P3 on any of the nine operations** (within one page's spread), **faster on `select`
by at least 30 %** (the selector P3 dropped) and **on `swap`** (the exact edit P3 could not
read), and **no larger than 0.85× P3's 3 454 B** (P3 with its trie and its loop removed is about
2 900 B; the generated page must be under that, which is where §7.2's rule and §4.3's guard
show). If any of the three fails, the design stops at S3 and the report says which mechanism
did not deliver. The same comparison is repeated at S5 on TodoMVC against the P3-shaped pages
research 60 wrote where one exists, and at S8.

**Kill criteria, so the design fails early and not as "P3 again"**, checked at the slice named:

1. **S0, the stats gate** (analysis only, no lowering needed — the numbers §11 dumps, over
   every corpus app, the table app, TodoMVC and Conduit), any of:
   - fewer than two thirds of Conduit's keys bounded (the write-set gate);
   - **static**, independent of any script: the share of the message type's constructors that
     lie under a `*` key, counted per leaf constructor (a `*` key over a sub-message counts
     every constructor beneath it), above 5 % on Conduit or on any corpus app;
   - **dynamic**: `patchAll` reached by more than 10 % of the dispatches of Conduit's three
     corpus scripts (the driver logs each dispatch's key) — `Reader`, `Editor` and **`Tour`,
     which navigates** (page 3, a tag, a profile, settings, sign-out: every `ChangedUrl` is a
     `*` dispatch), so the known `*` key is in the count, and a script that never navigated
     could not game it;
   - more than **3 value roots** in any program, or value roots above **5 % of its sites**;
   - the (key, group) pair count growing faster than linearly in the number of keys, fitted
     over the series of programs ordered by key count — the corpus apps, TodoMVC, the table
     app, and Conduit's Main and its eight pages each as a program (research 62's `Pages.beni`)
     — with the test that pairs ÷ keys on the largest program is no more than **2×** its
     value on the median one;
   - the trie's write half shipping under a `set`-only program when §13's estimates assumed
     not.

   Each is the design failing on a real shape, found before a line of the lowering is written:
   the Imba failure (O(view) per event) and the size blow-up, caught at S0 instead of S6.
2. **S0, the floor**: the empty mounted page is over 500 B brotli, or imports anything of `Rt`
   but `send`, `run` and the `unset` sentinel (§5.3) — the design is carrying a runtime it did not justify. The 300 B target
   is the estimate; 500 is where a reconciler's or a dispatcher's worth of bytes has crept in
   unreached, which is the one failure this tripwire exists for.
3. **S1**: the holes handler is not one compare and one write (`emit/direct/`), or holes 10 000
   is over 1.15× untraced, or the page grows with N by more than the HTML — the handler path is
   not direct. And from S1 the fuzz and the verify mode (§8.3) run on every direct page.
4. **S2**: the rows edit is over 1.3× or the swap over 1.0×, or the bundle holds the reconciler
   for a page whose keys are all exact — edit scripts are not being read off the write set.
5. **S3**: any table operation over 1.2× or `select` over 1.0×, or bytes over 2 830 with the
   bundle's **non-core part** (the whole minus core's in-context share, `size-parts.mjs`'s
   leave-one-out) over **2 400 B** or core's share over **600 B** — a miss by the non-core part
   is the Million failure (a win on the sweeps and not on the app), a miss by core alone is
   reported to the owner under rule 10 and is not the design's; **or
   the generated page does not beat P3 as §13 states** — P3 renamed. And the TodoMVC-shaped
   fixture (a filtered `For` with a toggle, `browser/direct/FilteredFor`, measured at 100 and
   1 000 todos) is in S3's batch, so the dynamic-hole shape is measured before S4, not at S5.
6. **S5**: TodoMVC's bytes or its three messages do not improve on today's platform — the win was
   constancy, which TodoMVC has none of (research 61), and the architecture buys nothing on a
   list-heavy app whose `For` reaches the reconciler on every list message: the Million failure
   again, seen from the other side.
7. **S6**: the S0 numbers re-measured on the built platform disagree with the analysis's — a
   handler calling more groups than its pairs, `patchAll` reached more often than the keys say.
8. **At every slice**: a transcript that differs between the two platforms, a fuzz sequence that
   differs, a verify-mode defect, or a V3 program that shows something its model does not hold —
   the Svelte 3 failure, a stale screen from analysis. A single one is a defect with a red-first
   fixture, and a rule corrected in `write-sets.md`.

## 14. The build order

Smallest first, each slice useful on its own, specified before it is built (the interface
additions in `boundary.md` §9.4.6, the backend rules in `backend.md`), red-first fixtures, and
measured on both platforms, P3, vanilla and Solid 1 in one batch. The slices are
`plans/compile-away.md` §7's, where their state is kept; this is what each contains and proves.

- **S0 — the stats gate, the platform and the harness.** *Q6 answered before it starts: the
  platform's layering is its shape.* First the **stats gate**: the dump
  lines of §11 (`site`, `markup_value_roots`, `carriers`, `pairs`, `reconciler`, `patchAll`)
  built into `dump --stage=writes` and run by `bench/writesets/stats.mjs` over every corpus app,
  the table app, TodoMVC and Conduit, with the Conduit driver logging each dispatch's key on
  the three scripts, and `size-parts.mjs` on a `set`-only program for the trie's write half —
  §13's kill criterion 1, which needs no lowering. Then `platforms/browser-direct/` registered
  in `build.zig` with the `direct` lowering and `Rt`; the program hook (§11.1); `Tea.sandbox`
  with a `view` of static markup only; `run`, `mountAt`, `programs`, the mount inside the guard
  and the mounted-twice refusal (§8.2); the `send` guard; `emit/direct/Hello`,
  `browser/direct/Hello` built both ways; the harness subjects and `bench/size.mjs`'s page line.
  **Proves**: the design holds on real programs' shapes by the analysis alone; a program can be
  lowered as a whole through the interface; the floor is ≤ 300 B; the two platforms can be
  measured side by side. *Kill criteria 1 and 2.*
- **S1 — holes, and the two oracles.** *Q1 and Q2 answered before it starts.* Text and attribute
  holes, constancy and baking (§5.1), per-key handlers with direct writes and direct listeners
  (§4.1–§4.3, the listener body inside the guard, read-at-event), the `*` key for an opaque
  `update` (§4.1), groups and slots (§5.3); **differential fuzzing and the development verify
  mode** (§8.3), run on every `browser/direct/` program from here on; the holes, width, burst
  and stream sweeps; `browser/dom/Holes`, `ConstantWriteOnce`, `GroupedReads`, `TrustedTurn`
  (re-stated for direct writes), `DefectInHandler`, and the new `EventReadsModel`,
  `SubmitFromWrite`, `VerifyQuiet`, `UnitHoles`, `DefectInListener`, `DefectInMount`. *Kill
  criterion 3.*
- **S2 — rows.** `For` keyed and positional, row templates, instances, static-key holes, the
  exact edit scripts with their tag guards (§6.2: `set`/`update κ`, swap, append, prepend,
  clear, insert, remove), the delegated list listener for delegatable events and direct
  listeners for the rest (§4.2), the mount measurement of listener placement and of expandos
  against a lookup (§6.1), the rows sweep; `browser/dom/Keyed`, `KeyedInPlace`, `RowItemOnly`,
  `RowMountOrder`, `ForAtEnds`, `ForForms`, and the new `NoOpEdits`, `RowBlur`, `StopInRow`,
  `DetachedRowEvent`, `NestedFor`. *Kill criterion 4.*
- **S3 — the table app, and the TodoMVC shape.** The reconciler (§6.3) for
  `replaced`/`permute`, the identity walk and the filter merge, the selector and key map with
  their order (§6.4), helper inlining under the size gate and shared sites (§5.2, §9.2), the
  building-loop rule (§7.2, in the backend, both platforms), `Html.map` static composition
  (§9.1), the dispatcher for carriers (§4.4); the table benchmark against vanilla **and P3**
  (§13's P3 criterion), B1's part-by-part bytes on both platforms; the TodoMVC-shaped fixture
  `browser/direct/FilteredFor` measured at 100 and 1 000 todos; `browser/dom/KeyedEnds`,
  `KeyedMoves`, `KeyedReplace`, `Selector`, `HelperSkip`, `NullaryHelperSkip`, `tea/Counters`,
  `LatestTagger`, and the new `SelectAndRemove`. *Kill criterion 5.*
- **S4 — guarantees and the rest of rendering.** *Q3 answered before it starts: `flush` and
  `Dom.rendered` are used from here.* Controlled inputs by the edited set and the no-op send
  after an edit (§8.1),
  defects, the crash screen and the teardown (§8.2), branches and `Show` with teardown's slot
  reset and liveness (§5.5, §4.1), derived values (§5.4), nested updates (§7.3), the value path
  for recursive helpers and `List Html` holes (§5.2), two programs on a page (§9.3); the live,
  derived, depth, helper-rows and helper-tree sweeps; every `browser/dom/Controlled*`,
  `Defect*`, `Blocks`, `ShowAndBranches`, `LetInMarkup`, `LetOneOwner`, `EveryRender*`,
  `TwoPrograms`, `MountedPrograms`, and the new `BranchReturn`, `LateResponse`, `LetInArm`,
  `SwapAndShow`, `RenderedSends`, `ControlledNoHandler`, `ProgramsByFunction`, `NestedPrograms`,
  `DefectInAfterRender`. The first V3 campaign runs after it.
- **S5 — effects and TodoMVC.** *Q5 answered before its target is set.* `Tea.element`,
  `document`, `application`; the command driver copied and driven by handlers, subscriptions
  diffed by write set (§10.1), the after-render point and `flush`'s no-op (§10.2), messages
  from fibers through the dispatcher; every `browser/tea/` fixture; `bench/todomvc/` with its
  vanilla subject, parity and size, the routing and sandbox builds both reported. *Kill
  criterion 6.*
- **S6 — Conduit.** Nested keys and same-variant rebuilds through the handlers, `patchAll` for
  the `*` key, the three Conduit scripts on both platforms, bytes and the three timed messages,
  the S0 numbers re-measured on the built platform; the second V3 campaign. *Kill criterion 7.*
- **S7 — in-place update.** *Q4 answered before it starts.* The ownership analysis (§7.4, §11
  item 4) with container and element ownership apart, the assignments in the handlers, the
  width, depth and rows criteria at 1.15×, `backend.md` §15.8's identity fixtures extended with
  the two rules of §7.4.
- **S8 — the decision.** One batch of everything on both platforms, P3, vanilla and Solid 1,
  one report, and the owner keeps one platform; the other's lowering, runtime and `Tea` are
  deleted, and the survivor's name is the owner's.

Slices S0–S3 are the first; S0's stats gate is the earliest stop, and after S3 the design has
either reached the table app's targets, beaten P3, and shown its cost on the TodoMVC shape, or
shown which piece cannot, before any guarantee machinery is built on it.

## 15. Open questions for the owner

*Re-derived 2026-10-09 after the adversarial review.* Only those that change what developers
can write, a guarantee, or a prior decision. Internal parameters are decided above (the
thresholds, the caps, the outlining and inlining gates, the delegated list listener, the
mounted-twice refusal, which is an error because aliasing is a wrong page) and their limits are
in plain words in §16. The refusal of a program shape (the first draft's Q1) is withdrawn: an
`update` of any shape is the single `*` key (§4.1, §11.1), and the one refusal left — a `view`
no compiler can reach as markup — has no fallback on a platform with no run-time renderer, is
not a question, and is reported under §16.

- **Q1 — A view event's payload is read at the event, not captured at the last view** (§4.2).
  Elm captures `Select model.id` when `view` runs; this platform reads `model.id` when the
  listener body runs, which is always with the page and the model in step. The one observable
  difference: an event a handler's own DOM write fires synchronously (a `blur` on a removed
  input) gets the model the handler made, where Elm would hand it the previous view's value;
  and an event on a row the same dispatch detached is delivered with the row's item. It changes
  what a program can observe in that corner, so it is the owner's. *Recommendation*: read at
  the event. It is the only reading with no closure per event and no message object, it is the
  more consistent one (the message carries the state the page shows), and
  `browser/direct/EventReadsModel` pins it.
- **Q2 — Direct writes replace the render loop.** W28 chose Solid 2's microtask flush; research
  56's A moved the render to the end of a trusted dispatch; both batch K messages in one task
  into one render. This design writes in the handler and renders nothing (§4.3): K messages are K
  writes, as in vanilla, so a burst costs K times one message and the K = 1 ratio holds at every
  K (§13). *Recommendation*: take it. Nothing a program can observe changes (DOM reads happen
  only through `Dom` after a dispatch), the burst win was 13 % at K = 1 000 and a cost at K = 1,
  and the stream criterion is "not worse than one message".
- **Q3 — `Browser.flush` becomes a no-op and `Dom.rendered` resolves at the end of the
  dispatch.** Both were defined against a loop. *Recommendation*: keep both names and types so
  one source builds on both platforms, document the meaning per platform, and delete `flush`
  with the losing platform at S8.
- **Q4 — In-place update amends W27** (`language.md` §11.12): a written field's record may be the
  same object as before, which no program can observe and §7.4's two rules keep the page from
  relying on. *Recommendation*: amend W27 to "an untouched value keeps its identity; a written
  value's container may be rebuilt in place where the compiler proves it unshared; no emitted
  comparison may rely on identity across such a write", and take S7 only after S3's numbers say
  the model half is where the remaining gap is (research 60 says it is).
- **Q5 — A subscription whose body cannot suspend runs with no fiber**, the twin of
  `boundary.md` §9.8.11's rule for commands. It changes nothing a program can observe and would
  take TodoMVC's routing subscription off the fiber kernel (research 51 §0.2: 1 948 B), on which
  §13's TodoMVC bytes target depends: without it the routing build cannot reach Svelte 4's
  4 246 B, and the target is restated as the sandbox build's. It is a guarantee-adjacent change
  to the effects contract, so it is the owner's. *Recommendation*: yes, specified in
  `boundary.md` §9.8.5 before S5's target is set.
- **Q6 — TEA is this platform's architecture, not a layer on it.** `boundary.md` §9.1 makes an
  architecture a platform layered on a base `Program`; here the architecture is what the
  compiler compiles, so there is no low-level `Program` another architecture could be written
  over without its own program lowering. *Recommendation*: accept for `browser-direct`; `browser`
  stays the base for a library-style architecture while both exist, and S8 decides.

**Reported, not asked** (rule 10): `List`'s thresholds and the trie's ~500 B for a program that
prepends to, or sets into, a long list outside a loop (§7.2) are measured at S0 and in S2/S3 and
reported in B1; nothing here changes them. And the one refusal (`view_not_compiled`, §11.1):
reported with its count from the dump, because it has no fallback and is expected never to fire
on a program anyone has written.

## 16. The limits, in plain words

No limit can make a page wrong; a limit makes a message do more work than it needed.

- **A message the analysis cannot bound** ("may change everything", `write-sets.md`'s limits)
  re-checks every value on the page and reconciles every list, as today's page does on every
  message. `beni dump --stage=writes` names the message and the cause.
- **Markup used as a value** — a helper that calls itself, a list of `Html` values, markup
  stored and placed later — is rendered through a small generic path (~200 B once) and compared
  as today's page compares it. A helper called from one place, or from a row, costs nothing
  extra.
- **A message that is a value** — sent by a command, a subscription or an `Html.map` over a
  lambda — is dispatched by its tags: one property read per constructor on its path, and one
  dispatcher per program (a few bytes per message kind). A page whose messages all come from its
  own markup has none.
- **A list a message replaces, sorts or reverses** is matched row by row by its key (~450 B
  once per page, O(n) per such message); a list only ever appended to, edited at an index,
  filtered or mapped is not.
- **A handler inside a list row** reaches its message through a walk of two to four nodes; one
  outside a list is called by the browser directly.
- **The model is copied on the written path** (a spread per record) until S7 proves the path
  unshared; a record of more than 1 020 fields is slow to copy in V8 (research 59 §2) until then.
- **An `update` the analysis cannot key** (wrapped by a helper, or in a record a helper builds)
  is one message kind that "may change everything": every message builds a value, calls your
  `update`, and re-checks the whole page, as today's platform does on every message. The page
  is right; it is slower by today's amount.
- **A `view` that is not a function the compiler can reach as markup** — chosen at run time,
  or arriving in a message — cannot be compiled by this platform at all, because the platform
  has no renderer to hand it to; the build says so and names `browser-tea`, which renders any
  `view`. No program in the repository is written this way.
- **A program value mounted twice on one page** is refused, at build time where the compiler
  can see it and at start otherwise, because two mounts would share one state and show each
  other's writes.
- **An event fired by a handler's own DOM write** (a `blur` on an input the handler removed)
  runs after that handler and reads the model the handler made (Q1).
- **After-render work that always sends and waits again** (a `Dom.rendered` continuation that
  sends a message and registers another wait, every time) keeps the dispatch going: each
  message applies, `end()` runs again, and the page never returns to the browser — the same
  hang today's microtask loop has with the same program, and a defect of the program, not of
  the platform.

*Amendments go below this line, dated, without renumbering.*

### *Amended 2026-10-09 (the manager, from the fifth review):* one more limit

- **The development verify check samples large derived lists.** After each message, the
  development build re-checks every value it computed. For a derived list longer than 1 000
  elements it compares the length and the first and last 100 elements only. A missed write in
  the middle of such a list is caught by the fuzzer and the page tests, not by this check.

### *Amended 2026-10-09 (the owner):* the open questions are decided

The owner took every recommendation of §15:
- **Q1:** a view event's payload is read at the event, not captured at the last view.
- **Q2:** direct writes replace the render loop. There is no batching: K messages are K writes,
  as in vanilla.
- **Q3:** `Browser.flush` and `Dom.rendered` keep their names and types. On this platform
  `flush` does nothing and `Dom.rendered` resolves at the end of the dispatch; `flush` goes
  with the losing platform at S8.
- **Q4:** W27 (`language.md` §11.12) is to be amended for in-place update, before S7: an
  untouched value keeps its identity, and a written value's container may be rebuilt in place
  where the compiler proves it unshared.
- **Q5:** a subscription whose body cannot suspend runs with no fiber, specified in
  `boundary.md` §9.8.5 before S5's target is set.
- **Q6:** TEA is this platform's architecture, not a layer on a base `Program`. `browser` stays
  the base for a library-style architecture while both exist; S8 decides.

§15's questions are settled, and S0 may start.

### *Amended 2026-10-09 (S0, the stats gate):* the dump lines of §11, exactly

§11 names the lines and not their format or their counting rules; this fixes both, before they
are built. They follow a program's `holes` line in `beni dump --stage=writes`, in this order, one
fact per line, sorted by text or position and never by an id (`write-sets.md` §7):

```
  site Main.beni:200:5                            unique
  site Page.beni:30:5                             shared     8 calls
  site Main.beni:229:17                           instanced
  site Tree.beni:12:5                             value      recursive
  sites 4: unique 1, shared 1, instanced 1, value 1
  markup_value_roots 1 (25% of 4 sites)
  carriers yes: commands; Html.map Main.beni:94:62; msg whole
  constructors 74: under * 1 (1%)
  pairs 120 over 90 keys and 40 groups (1.33 per key); every key calls 3 of 40 groups (7%)
  list Main.beni:228:18                           reconciler Run ⟨replaced⟩; RunLots ⟨replaced⟩
  list Main.beni:240:18                           scripts
  reconciler 1 of 2 lists
  patchAll ChangedUrl
```

- **`site`**, one per markup root of the program's own modules that the view walk reaches (a
  `markup` expression; its position is its first token), with its class by §5.2, read off the
  walk, which inlines every call of the program's functions (`write-sets.md` §3.6): **`value`**
  when some visit is inside an element of a list — a list literal's element, or a `List`
  function's callback (`map`, `foldl`, …) — printed `list`, or when the function or `let`
  function holding the root re-enters itself on the walk, printed `recursive`; otherwise
  **`instanced`** when some visit is inside a `For` row; otherwise **`shared`** when the walk
  visits it more than once and one of its holes reads the model, with the count printed (`N
  calls`); otherwise **`unique`**. `shared` is the count *before* §5.2's size gate, which S3
  builds: the gate may inline a shared site into unique copies, never the other way, so the
  line is an upper bound on shared sites and changes no other class. Markup stored in the model
  is not a site the walk can see and is not counted (no program in the gate's set stores
  markup). `sites` counts the classes.
- **`markup_value_roots`**: the number of `value` sites, and their share of `sites`.
- **`carriers`** (§11 item 3): `no`, or `yes:` with every reason — `commands` for a
  `Tea.element`, `document` or `application` (commands and subscriptions send values);
  `Html.map <position>` for each `Html.map` whose function is not a constructor, a constructor
  under a placeholder, or a choice between those (§9.1); `msg whole` when a key's walk passes
  the message, or a sub-message the key tree splits, to a function the analysis does not
  summarise or to `Debug.log`, or places it in the model — the message itself, inside what the
  arm builds; a value merely computed from it is not looked into, since a closure's
  environment names `msg` whether or not the closure reads it; `unrecognised` for a program the
  pass does not recognise.
- **`constructors`** — the static share of kill criterion 1. A key's **message constructor** is
  the last constructor along it that a module of the program's own package declares: a split of
  a `Result`, a `Maybe` or a platform type below it (`· Ok`, `ClickedLink · Internal`) is a
  payload split and adds none. A default child `_` stands for every constructor of its type its
  siblings do not name. A leaf key with no constructor of the program's package stands for every
  constructor of the message type (`(any)`). The line counts the program's message constructors
  so identified and those **under `*`** — a constructor any of whose leaf keys is `*`. An
  unrecognised program is one constructor under `*`. *Coarse on one side, stated:* a
  sub-message the key tree does not split (a constructor whose payload is a message `update`
  hands to an unsummarised function) counts as one constructor, not as the constructors beneath
  it; the report lists every `*` key's payload type so that case is visible.
- **`pairs`** — the (key, group) pairs of §5.2 and §3. A **group** is the set of a site's holes
  with one anchored read set (§5.3), counted over holes whose read set is not empty (an empty one
  runs at mount and is called by no key). A bounded key κ **calls** group G when some read of G
  conflicts with `writes(κ)` (`write-sets.md` §2.5). The pairs are summed over the **bounded**
  keys only: a `*` key calls `patchAll`, one function per program (§4.1), not a group each, and
  is the `patchAll` line's. `per key` is pairs ÷ bounded keys; **every key calls** counts the
  groups that every bounded key calls — the root-level read §5.2 names.
- **`list`**, one per `For` the walk reaches, with its `each` hole's position: **`reconciler`**
  and the keys that reach §6.3's reconciler, each with why, or **`scripts`** when none does.
  When the `each` is exactly a model path `p` (every visit), a bounded key reaches it by a write
  that may coincide with `p` itself (`write-sets.md` §2.1) whose tag is `permute` or
  `replaced`, or that is a `value` write with no tag (printed `⟨value⟩`), or by a `value` write
  at a proper may-prefix of `p` (printed with that path) — the list is another list; every other
  tag, and an element write below `p`, is a script. When the `each` is not exactly a model path
  (a derived list, §6.2's last paragraph), a bounded key reaches the reconciler when it
  conflicts with any of the hole's reads (printed `derived`). Every `*` key reaches it (printed
  `*`). A `For` with `keyed={False}` prints **`positional`** in place of `reconciler`: the
  positional pass, not the keyed reconciler. A `value` write at a prefix may in fact switch the
  branch arm holding the list, which remounts and does not reconcile; the analysis cannot tell
  the two apart, so the line is an upper bound. `reconciler N of M lists` counts the keyed lists
  some key reconciles.
- **`patchAll`**: the `*` keys, joined by `; `, or `<none>`; `*` for an unrecognised program.

An unrecognised program (`write-sets.md` §1.1) prints the same lines, with its one `*` key.

**Kill criterion 1's dynamic count is the harness's** (§13): `bench/writesets/stats.mjs` builds
Conduit for `browser-tea` in development, adds to the copy of the emitted `Main.mjs` it runs — not
to the compiler, the platform or the fixture — one statement at the head of `Main.update` that
logs the message, runs `tests/browser/driver.mjs` on each of the three `browser/tea/Conduit*`
scripts, and maps each logged message to its leaf key by its constructor tags against the dump's
key names. A message that maps to a `*` key is a `patchAll` dispatch.

**The trie's write half** (§7.2, kill criterion 1's last item) is measured by the same script, on
`--release` bundles: whether the core functions only `List`'s writers name — `fromPlain`,
`triePrepend`, `triePushed`, `triePush`, `trieSet`, `triePop` and what they call — ship, and their
bytes, for the table app as written, the table app with its building loop's prepend taken out
(what S3's building-loop rule would leave), and a program whose only list write is `List.set`.

### *Amended 2026-10-09 (slice S0, as built; research 65):* the platform, the hook and the floor

The platform half of S0 is built; the stats gate is separate work. What building it settled:

- **The program hook is `boundary.md` §9.4.6's version 1.6**, the part of §11.1 a static `view`
  needs: `Lowering.programs`, `Lowering.program`, the `Program` shapes, `cx.programInit`,
  `cx.programReport`, `cx.notImplemented`, `Lowering.no_markup_values` and
  `Lowering.placements`. §11.1's other calls arrive with the slices that consume them. A
  constructor's call is compiled as the constructor applied to the mount, so `Tea.sandbox`'s
  sibling makes the `{ a, n }` §12.1 names; the record is never evaluated as a value, and a `view`
  or `update` only a record names is not emitted.
- **The runtime module is `Direct`, not `Rt`** (§12.1): a module's name is unique across the
  platform chain (`boundary.md` §9.1), and `browser`'s `Rt` is in `browser-direct`'s. Everything
  this document says of "`Rt`" is said of `Direct`.
- **The mount is `(root, t)`**: `run` hands each program's mount its node and a `template`
  element, inside the guard, after refusing a program value mounted twice and before any program
  renders; the mount evaluates `init`, writes `t.innerHTML` and appends `t.content` (§5.1). The
  static template's text is `dom`'s own, so both platforms parse the same characters.
- **`init`'s evaluation is a specified difference between the platforms.** On this platform it is
  in the mount, so a throw there is a defect (§8.2); on `browser-tea` it is where `main` is
  evaluated, while the module loads. `browser/direct/InitThrows` pins both with a
  `.tea-expected`, the corpus's one exception to §12.3's single golden.
- **`Browser.program` and `Browser.hosted` are refused at build time** (`not_implemented`), since
  this platform's runtime does not run them (Q6).
- **`init` runs at mount** (§11.1 as built; `boundary.md` §9.4.6, version 1.6): the hook evaluates
  it inside the mount, never where the program value is built, so its effects happen at mount.
- **Where §8.2's `error` listener is installed** (*amending §8.2*): not at `run`, but by the guard
  when the page stops, in a development build only — `stop` sets `dead` first, then draws the
  crash screen, which installs a `once` listener on `window` that appends the host's report of the
  throw. The host reports the throw after the guard's `finally`, so the listener is in place for
  it; a page that never stops installs nothing. This is `browser`'s order too, so the two
  platforms' crash screens are the same.
- **`dom`'s flag 1 is refused until S1** (`not_implemented`): a custom element, an `is`, and an
  `<img>` or `<iframe>` with `loading`, which `browser` imports rather than clones so that the
  page upgrades or loads them. The direct mount adopts them by `append`; until a Chrome page shows
  that does the same, the platform does not compile them. Flag 2 (an SVG or MathML root that is
  not `<svg>`/`<math>`) is refused as well, and no vocabulary that ships can reach it today.
- **The floor is 399 B, and today's is 446, not 1 234** (§3, §13): kill criterion 2 passes — under
  500 B, and the empty page imports nothing of `Direct` but `run` — and the 300 B target is missed
  by the refusal messages (70 B) and the guard. A static page of 1 000 elements mounts at 1.12×
  vanilla from a real click, `browser-tea` at 1.41×.

### *Amended 2026-10-09 (§8.3's differential fuzzing, as built):* the page fuzzer and the `--fuzz` contract

§8.3 item 2 names the fuzzer, its messages and the gates' seeds, not its interfaces. This fixes
them; the part S1's `--fuzz` flag must meet is marked **contract**. Revised the same day after
the first review listed the ways it could report two builds equal when they differ: **what is
not compared is listed, never what is**.

- **Where it runs.** `tests/browser/fuzz.mjs` is a module of the page driver: `node driver.mjs
  --dom=… --fuzz=<spec.json>@<report.json>` runs it in the driver's process, after any `--page`
  of the same run, so a fixture pays for Node and the DOM once. Every page it makes is the
  driver's (`happyDomPage`, or `chromePage` under `zig build test-browser`), driven by the
  driver's `step` and printed by its `serialise`. The spec names two builds' entry files, how
  the report calls them, the message types file, whether both builds take messages as values,
  the fixture's `.steps`, the log lines the builds may differ on, whether their crash screens
  are the same, whether to replay, the seeds and the steps. Its report is a page report: `code`
  0 when every seed agreed, 1 on a difference, 2 for a fault of the fuzzer, a mount count that
  disagrees with the dump, or a page that does not replay itself.
- **Where the messages come from: `beni dump --stage=writes --msg-types`**, hidden and test-only
  as `--writes-work` is. It prints one JSON line per program, in `--stage=writes`' order (the
  order `Browser.programs` mounts them): `{"program","index","kind","msg"}`, where `msg` is the
  type of `update`'s first parameter as the checker records it — the scheme of the declaration
  `update` names, or the type of a lambda's first parameter — written as `Debug.toString`'s
  descriptor (backend.md §4, *`Debug.toString` reads the argument's type*, by the same code:
  `check/DebugShape.zig`'s walk, `js/DebugShape.zig`'s writer). `msg` is null for a program the
  write-set pass does not recognise, or whose `update` is neither. What the fuzzer shares with
  the lowering is the pass's recognition of which field is `update`, and the type table; never
  the key tree.
- **The messages.** A value is generated from the descriptor in the **development
  representation** (backend.md §4): numbers, strings, `true`/`false`, `null` for `⊤`, records by
  field name, tuples as `{a, b, …}`, lists as arrays, an all-nullary type's constructor as its
  bare tag, any other as `{$, a, b, …}` padded with `null` to the type's widest constructor.
  - **Every constructor first.** The first messages of a sequence sweep every constructor of
    every program that can be made, in order, half the actions while the sweep lasts; then three
    in ten, the constructor drawn at random.
  - **The page's own values.** A third of the ints and strings are taken from what the page
    shows — its text and its `id`, `value`, `href` and `data-*` attributes — so a keyed message
    names a row that exists; the rest from a fixed pool (empty, spaces, an astral character,
    markup, `-0` among the floats).
  - **Lists** are up to three elements, and one in twelve near the top is 33 to 48: past the
    trie's first leaf (*Lists are arrays*).
  - **Not sent**, and said so: a constructor every choice of whose payload holds a function, a
    `foreign type`, a `Dict`, a `Set` or an unknown type. The report's first line per program is
    `the program: N constructors sent; not sent: Tag (a foreign type), …`.
  - A message goes to a program by its place among the mounts; a page that mounted another
    number of programs than the dump lists is a fault (code 2), not a run without messages.
- **The other actions** are driver steps drawn from the page as it stands: `click`, `dblclick`,
  `input` of a random text or one the page shows, `key`, `focus` and `blur` on a random element
  (a `>` chain of `:nth-child` selectors from the body); `event` on the window or the document;
  `advance` of the virtual clock; `respond` to or `fail` a pending request — half the answers
  being the fixture's own script's `respond` lines, status, body and headers, so a decoder sees
  what it expects; `hash`. A sequence with no message is therefore a `.steps` script, and the
  report prints it as one.
- **The comparison**, after the load and after every step, of everything a step may change:
  - the body as `serialise` prints it (every element, attribute, text, comment, a control's
    live value and the focus, as a fixture's transcript);
  - what it does not print: an option's `selected`, `disabled`, `hidden`, `indeterminate`,
    `open` and `readOnly` as properties, and a text control's selection range;
  - `document.title`, `location.href`, and both storages (a storage the page made unreadable,
    by what reading it threw);
  - every line the driver logged — requests, `console.*`, prevented defaults, links followed —
    less the patterns the spec's `ignore` names, which is a denylist: empty for a development
    and release pair, `^console\.log: ` for `browser-tea` against `browser-direct` (a
    `Debug.log` in a view prints when its group runs, §8.4);
  - every error the step threw, by its text.
- **When a step throws.** "Both threw" is not agreement: the errors' texts, the log and the
  title, address and storages must agree too, and the body as well when the spec says the two
  builds' crash screens are the same (`browser-tea` against `browser-direct`, by S0's amendment;
  not a development build against a release one, whose screen is its own). The pages then settle
  up to five more turns, so what the stopping pages still do — a release a task later — is
  compared whole, wherever it falls between two turns. The sequence ends there, and the line
  says so: `seed 1: both threw at the load, so 0 of 30 steps ran (…): Error: …`, never "30
  steps agree".
- **The report** names the seed, the step and its action, the sequence shrunk to fewer actions
  that still differ **in the same part** (dropping halving chunks, at most 40 tries, each two
  pages, and saying so when the budget ran out), what differs, and for the body the smallest
  element of each holding every differing line.
- **Seeds and replay.** A seed is a mulberry32 stream; the second build replays the first's
  actions. Every page has `Math.random` (an LCG from 1), `new Date()`, `Date.now` and
  `performance.now` pinned to the driver's virtual clock and fixed sequence, besides the
  prelude's `crypto.getRandomValues`. Wherever a verdict may be recorded — `zig build
  test-run-hashes`, the scenarios of `page_fuzz_test.zig` — and in a sweep, the first seed is
  also played twice on the first build, and the two must agree, so a page that does not replay
  itself never passes into a record.
- **Which pairs the gates fuzz** (the corpus walker, `fuzzPair`): a `browser/direct/` page's
  `browser-tea` and `browser-direct` development builds, unless the fixture has a
  `.tea-expected`; a `browser/tea/` page's development and release builds, which backend.md §9
  says behave alike. **One seed of thirty steps**, a line `fuzz <node> <dom> <sha-256>` in the
  fixture's `.run-hash` covering both output trees, the driver, the fuzzer, the message types,
  the fixture's script and the spec. One seed and not two of fifteen, because a page and its
  module graph cost more than fifteen steps: `browser/tea/ApiAndRoutes`'s two builds take 3.4
  of its 4.3 billion instructions, and the fuzz with two pages brings it to 4.14. `zig build
  fuzz` runs fifty seeds of sixty steps (`BENI_FUZZ_SEEDS`, `BENI_FUZZ_STEPS`), with no record
  and no budget. Each page loads a copy of its build at a path made of the build's content and
  the page's number (`zig-out/browser-fuzz-pages/`, pruned after an hour), so the driver's
  compile cache, keyed by path, keeps one entry per module of a page and not one per run.
- **Messages as values in the gates: through `--fuzz` builds, for both pairs.** The generator
  does not learn the release representation (integer tags, short field names): those are the
  release optimiser's choices, which the fuzz would then share. Instead a `--fuzz` build takes
  the development representation in release too (contract, below), and when the compiler has
  the flag, `fuzzPair` builds the pair's two sides again with it, dumps the message types and
  sends values; until then the pair is the fixture's own builds and its fuzz is view and host
  events. The walker asks the compiler once per process whether `build --fuzz` is known.
- **Contract — S1's `--fuzz` flag.** A hidden, test-only flag of `beni build`, on both
  platforms, **in development and in release** (`--release --fuzz` is accepted; amending the
  first version of this list, which refused it):
  1. **It roots every constructor of every program's message type**, and transitively of every
     type its payloads name, as a `--library` build roots every constructor (backend.md §9, *A
     `case` arm on a constructor nothing builds*). Without it a message whose constructor no
     code builds reaches an arm lowered as `undefined`, or none, and the two builds need not
     agree — the fuzzer would report the elimination, not a missed write.
  2. **Under `--release`, every program's message type, and every type its payloads name, is a
     type JavaScript sees** (boundary.md §4, *What JavaScript may read of a beni value*): its
     tags stay strings and its records' fields their names (§9, *Item 4, taken up*), so a value
     the fuzzer makes in the development representation is one the release build reads. The
     rest of the program keeps item 4's representation.
  3. **On `browser-direct` it emits the dispatcher** `globalThis.__beniFuzz = { send(program,
     msg) }`, set before the first program mounts: `program` is the index of the program in
     mount order, `msg` a value of its message type in the development representation. `send`
     dispatches `msg` as a carrier's message is dispatched (§4.4): through the guard, to the
     handler of its key or to `patchAll`, its writes done when `send` returns. An index with no
     program throws.
  4. On `browser-tea` nothing more is needed: the fuzzer sends a value to a mount node's
     `$$root`, recording the mounts in order before the program loads.
- **The proof** (`page_fuzz_test.zig`): two clean development builds agree; a build that
  misses a text hole's write only for negative counts is caught at `Set { count = -3, … }`,
  shrunk to that one message, while the same seeds with view events alone never reach it; and
  builds that miss every write after the first of an attribute (`class`), a controlled input's
  `.value`, a keyed list's rows and the document's title are each caught at the message that
  shows it, each report pinned whole. A release-only break in `browser`'s runtime (a `hidden`
  attribute never removed) was caught on TodoMVC as a two-step `.steps` script, and removed.
- **Known limits.** `browser/dom/` pages and the root `browser/` pages are not fuzzed (a
  development-against-release pair would serve, as for `browser/tea/`). Not compared: scroll
  positions, listeners an element holds (a stale handler shows only when an action lands on it),
  `<html>`'s and `<head>`'s attributes other than the title. Coverage of a random walk is what
  the seeds give: a write reached only by a deep sequence is the sweep's, not the gates'.
- **A finding, not the fuzzer's:** `browser/tea/ApiAndRoutes` costs 4.52 billion instructions
  without the fuzz whenever its pages must run, over the 4.3 billion budget; the gates pass only
  because its pages' run hashes are recorded, and `test-run-hashes` records without a budget.
  Its two builds alone are 3.4 billion.
