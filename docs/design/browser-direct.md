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
kept (§6); the model half is not beni's output verbatim: the arm is specialised to the key, a
derived `let` is recomputed only by the keys that can
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

*Amended 2026-10-13:* the owner dropped the identity promises of the functions that build
(`language.md` §6.8; `backend.md` §4, *Identity*): `map`, `filter`, `slice`, `take`, `reverse`, the
sorts, `concat` and `append` with an empty side return a fresh list now. Nothing above relied on
them. The identity walk compares *elements*, which `map` still passes through `===` where `f`
returned its element; the merge compares items; every guard is a tag's own condition; and the
writers' no-op returns, which this section's guards were written for, are unchanged. A derived
`each` (TodoMVC's `List.filter`, below) is recomputed only by a key whose write set conflicts with
its reads (§5.4) and then reaches the rows as `replaced`, so the identity of the list it computes
was never consulted.

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

- ~~**An accumulator loop builds a plain array.**~~ *Withdrawn 2026-10-11 by the owner: prepending
  is an anti-pattern the compiler must not reward.* This bullet specified a rule (S3, `backend.md`
  §8's *Accumulators build a plain array*, withdrawn there too) that compiled a loop prepending
  onto an accumulator into pushes onto a plain array reversed once at the exit, so that the table
  app's `buildFrom` would not birth a trie. A loop that prepends is lowered as written: past 32
  elements it conses onto a trie and ships the trie's write half. The table app builds its rows
  in order instead, `[ …acc, x ]`, with no rule. Whether the compiler should do anything about
  prepend-built lists is open with the owner.
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
thresholds — and **`set` past 256 elements births a trie as `cons` past
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
Release maps are not started, as before. *Amended 2026-10-15:* release maps are built
(`backend.md` §11.2): `--release --source-maps` writes one map for the scope-hoisted file, and
hand-written runtime JavaScript stays unmapped. A check of the 166 `browser/direct/` programs found
each release map valid and each file unchanged but for its comment line; no fixture pins a hole's
position in a release map yet.

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

*Amended 2026-10-12 (`boundary.md` §9.8.18):* `Browser.Events.onAnimationFrame` and
`onAnimationFrameDelta` are re-exported here, and nothing in them is `browser-tea`'s: each is a
`Sub.on` listener over `browser`'s frame clock, which hands its frame's messages on under
`Task.fromHost`. What is missing on this platform is subscriptions themselves — the lowering refuses
`Tea.element` until slice S5 (§14) — so a program here cannot subscribe to frames yet. When S5 lands,
the one thing to check is §9.8.18 (d)'s promise that a frame's messages render inside the frame: a
frame listener's delivery must enter through `send` (§4.3), whose dispatch writes synchronously, so
the promise holds if S5's subscription deliveries do not defer past the drain `Task.fromHost` runs.

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
5. ~~**Building loops** (§7.2)~~: *withdrawn 2026-10-11 by the owner* (§7.2); nothing is
   analysed for an accumulator loop.

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
| **swap** (rows 30 000) | ≤ 1.15× and no slower than P3 until S7, then ≤ 1.0× (P3: 0.98 in research 60, 1.12 in research 67's batch; the rest is the model's `List.swap`, §7.4) — *amended 2026-10-10, the owner* | the same page | §6.2; S2, then S7 |
| **live rows 10 000** | ≤ 1.15× (P3: 1.25 at a 5 µs clock, with the flush) | ≤ 1.1 kB | §8.1; S4 |
| **derived 100 000** | flat, ≤ 1.15× | ≤ 1 kB | §5.4; S4 |
| **bursts and stream** | **the K = 1 ratio at every K**: ≤ 1.15× for all K, and the stream not worse than K = 1. With no batching, K messages cost K times the per-message path (guard, arm, spread, compares, write), so the ratio to vanilla is the one-message ratio; the 13 % win at K = 1 000 was the batching this design deletes, and before S7 every message also pays a model spread vanilla's `tick++` does not | — | §4.3; S1 |
| **the table app** | every operation ≤ 1.2×; `select` ≤ 1.0× (the selector kept); `swap` ≤ 1.2× with the exact edit from `List.swap` or the index guards (`write-sets.md` §10.4); **and no operation slower than P3** (below) | ≤ 2× vanilla = 2 830 B: P3's own module 2 243 + core ≈ 400 → **≈ 2 650 [estimate]**, a 6 % margin on an estimate, and the ≈ 400 holds only if the trie's write half is not reached (§7.2: the S0 stats gate measures it; *amended 2026-10-11*: the building-loop rule this leaned on is withdrawn, and the table app keeps the trie out by building its rows with `[ …acc, x ]`) | §6; S3 |
| **TodoMVC** (`bench/todomvc/apps/beni/`, at **100 todos and 1 000 todos**: add one, toggle one, clear completed) | the three messages ≤ 1.2× vanilla TodoMVC at 100 todos; at 1 000, toggle-one is O(n) through the reconciler (§6.2, a `For` over a filtered list) where vanilla is O(1), so the target there is ≤ 1.3× and the measurement says what the derived-`each` precision §6.2 allows would buy | the **routing build** (the corpus page, no editing: today 10 053 B) ≤ 2× vanilla TodoMVC and below Svelte 4's 4 246 (tastejs's, persistence included) — **which depends on Q5** (§15): with the routing subscription on the fiber kernel, 1 948 B of it is the kernel (research 51 §0.2) and the target is out of reach; the sandbox build (today 5 317) is reported beside it | §6.3, §10.1; S5 |
| **Conduit** | every key's handler bounded but `ChangedUrl`; a page message ≤ the frame's one DOM write + the page's groups | ≤ 0.7× today's 30 842 brotli, **if** the (key, group) pair count and the shared-site gate (§5.2) hold the handlers linear; the S0 stats gate gives the count | §4, §5.2; S0 for the counts, S6 for the bytes |

**Which of research 58's criteria this design expects to miss, and why.** None on speed, with
the width and depth and long-list points reaching 1.15× only at S7 (in-place), which research 58
itself ordered last. On bytes, the table app at ≤ 2× is expected to land within about a hundred
bytes either side of the line: the renderer's share is under the bound (research 60 §4.6) and the
rest is core's `List`, which building in order keeps small but does not remove (`append`, `get`,
`indexedMap`, `filter` stay). If it misses by core alone, that is reported as a finding on `List`
for the owner and not restated (rule 10, and `compile-away.md` §6).

**The number that justifies a compiler over a hand-written page.** P3 is a page a person wrote
with the facts a compiler has; a generated page that is no better than P3 is P3 renamed, at the
price of a second platform. So at S3, on the table app in one batch: the generated page is **no
slower than P3 on any of the nine operations** (within one page's spread), **faster on `select`
by at least 30 %** (the selector P3 dropped) and **on `swap`** (the exact edit P3 could not
read), and **no larger than 0.85× P3's 3 454 B** (P3 with its trie and its loop removed is about
2 900 B; the generated page must be under that, which is where building in order and §4.3's
guard show — *amended 2026-10-11*: building in order is now the app's own code, §7.2's rule being
withdrawn). If any of the three fails, the design stops at S3 and the report says which mechanism
did not deliver. The same comparison is repeated at S5 on TodoMVC against the P3-shaped pages
research 60 wrote where one exists, and at S8.

*Amended 2026-10-11 (the owner):* **the `select` test is accepted as met** by what research 70 §7
measured — lean direct's `select` 18–25 % faster than P3 and 0.70× vanilla, its bytes 45 % under
P3's, its swap tied with P3's. The owner accepted the result as it stands: the 30 % is no longer
a stop condition for S3's lean slice or after it. Each later batch still reports `select` against
P3, and the other two tests (no operation slower than P3, bytes under 0.85× P3) and kill
criterion 5's bars hold as written.

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
4. **S2**: the rows edit is over 1.3× or the swap over 1.15× or slower than P3 (amended
   2026-10-10; ≤ 1.0× moves to S7), or the bundle holds the reconciler
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
   *Amended 2026-10-14 (the owner):* the owner deferred the timing condition. Direct is smaller on both TodoMVC variants and faster at 100 todos; the 1 000-todo misses (3–10%, sub-1.5 ms) come from filtered lists going through the general reconciler, which S6 and S7 address. Re-judged at S8.
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
  their order (§6.4), helper inlining under the size gate and shared sites (§5.2, §9.2), ~~the
  building-loop rule (§7.2, in the backend, both platforms)~~ (*withdrawn 2026-10-11 by the
  owner*, §7.2), `Html.map` static composition
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
(what S3's building-loop rule would have left; the rule was withdrawn on 2026-10-11, §7.2), and a program whose only list write is `List.set`.

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
### *Amended 2026-10-09 (slice S1, as built; research 66):* holes, handlers and the two oracles

S1 is built (`boundary.md` §9.4.6, version 1.7; `platforms/browser-direct/zig/direct.zig`). What
building it settled, each a resolution of a place this document left open or could not keep:

- **A program's state is the mount's own scope, not module-level variables** (§5.2, §8.2). The
  model, the node handles, the slots, the groups and the handlers are `let`s and `const`s of the
  mount function `run` calls, so a slot read is a context-slot load as a module variable's is, and
  every mount of a program a function builds has its own state with no mount record. The cost
  §8.2 gave the mount record is therefore paid by no program, and nothing else changes.
- **A handler's parameters** (§4.1): the constructor's fields for a key that is one named
  constructor; the message itself for any other key — a nested key (`Nested · A`), a default key
  (`_`), a key of a message never split (`(any)`), the `*` key. **The arm** is `update`'s body
  written in place: where `update` is a `case` on its message parameter, only the branch the key's
  first step selects, its pattern's variables read from the parameters (the fields of the message
  parameter, for a deeper key, whose inner `case` then decides); otherwise the whole body with the
  message bound. An `update` of another module, or one computed (`withLogging update`), is
  evaluated once at mount and called. The specialiser that removes the inner `case` of a nested
  key is §4.1's `--release` work and is not built.
- **Groups are functions, always** (§5.3's "inlined on single use" is not built): the mount calls
  every group once, so no group has a single caller. A group no key calls is written in place at
  mount, with no slot and no compare; a development build keeps its value in a slot for the
  verify mode only. A constant attribute that needs code and is merged into a group that runs
  again (an element's attributes stay in source order, `dom`'s rule) is guarded by a slot of its
  own and written once (`emit/direct/ConstantWriteOnce`).
- **The dispatcher is a chain of tests in key order**, not §4.4's decision tree: a key's named
  steps are tested and the last key is not. It is emitted only when a listener's handler value is
  not a constructor of a handler's key (a lambda, a computed message), or under `--fuzz`.
- **What the template bakes is `write-sets.md` §9.1's literal hole**, plain-checked again by the
  pass; dom's flag 1 (a custom element, `is`, a lazy `img`/`iframe`) is no longer refused: such a
  template is imported through the template element's own document (`t.ownerDocument.importNode`,
  as `Rt.template` imports it). Flag 2 stays refused (S4); no vocabulary that ships reaches it.
  *Amended 2026-10-12* (`boundary.md` §9.9 (f)): `html` declares SVG now, and **a `For` row whose root
  is an SVG element is compiled**: its template is parsed inside the `<svg>` wrapper and taken from
  inside it (`$t.content.firstChild.firstChild`), and everything after is a row like any other
  (`browser/direct/SvgRows`, against `browser-tea` in both DOMs). SVG nested in a view's template
  needed no change. **A `view` whose root is an SVG element other than `<svg>` stays refused until
  S4**, which needs first a mount node that may be an `<svg>` (`Browser.mountAt` on one): mounted into
  an HTML element, as every page is today, such a root draws nothing. A MathML row root stays refused
  with it.
- **Q1's observable difference in S1 is bubbling**, not a removed input: a click a button handles
  bubbles to its section, whose message, read at the event, carries the model the button's
  message made (`browser/direct/EventReadsModel`). The removed-focused-input shape needs branches
  and moves to S4. `browser/direct/SubmitFromWrite` pins the submit whose `preventDefault` runs in
  the DOM listener; `DefectInListener` throws in the handler's function applied to the event's
  payload, since no vocabulary that ships has an extractor that can throw.
- **The verify mode** (§8.3) is registered by each development mount with `Direct.verify` and
  run by `send` after the dispatch's queue drains; a difference throws `Direct.wrong`, naming the
  hole and its position — a defect, so the page stops. It checks every hole with a slot, static
  ones included, and every baked hole against its text; it skips every-message values and values
  that reach `Debug` through the whole program's call graph (`cx.reachesDebug`). A deliberately
  broken handler (one key's groups not called) is caught at the first message (research 66 §2).
  **Its cost in development is not "today's cost"**: it computes every hole of the page, static
  ones included, where today's page compares only what may change — 0.6 ms a message at 10 000
  holes, against 0.1 for `browser-tea` (research 66 §3). It is a development-only cost and no
  criterion judges it; a page that needs a faster development build could check static holes
  once at mount.
- **`--fuzz` meets the contract above** (§8.3's amendment, items 1–4), on both platforms, in
  development and release. Item 1: every constructor of every module is a root of elimination,
  so no arm is dropped for a constructor nothing builds. Item 2: each program's message type,
  written as the annotation of the `update` its record names, seeds the release boundary
  (`Fields.close`), so it and every type its payloads name keep string tags and field names;
  a program whose `update` has no written annotation (a lambda) keeps every name of the build.
  Item 3: a mount registers its dispatcher first thing (`Direct.fuzzMount`), so
  `globalThis.__beniFuzz.send(program, msg)` numbers programs in mount order, sends through the
  guard, and throws for an index with no program; under `--fuzz` a static `view` takes the same
  path, so every program has a dispatcher. `--msg-types` (the fuzzer's) lists the types.

### *Amended 2026-10-09 (the manager, at S1):* which pairs the gates fuzz with message values

§8.3 requires value fuzzing from S1 **on every `browser/direct/` program**; it does not require it
on `browser/tea/` pages. Sending messages as values costs a page two more builds (the `--fuzz`
pair) and a `--msg-types` dump, and on the `browser/tea/` pages that pushed 55 of them over the
4.3-billion-instruction budget. So, amending the contract's *Messages as values in the gates*:

- **The gates** (`fuzzPair`) send values only on the `browser/direct/` pairs (`browser-tea`
  against `browser-direct`, development builds, built again with `--fuzz`). A `browser/tea/`
  pair (development against release) keeps its event-only fuzz in the gates.
- **`zig build fuzz`'s sweep** sends values on both kinds of pair.
- **A value enters through the defect guard on both platforms**, as an event does: on
  `browser-direct` through `__beniFuzz.send` (`send`); on `browser-tea` through
  `globalThis.__beniFuzzSend(node, msg)`, which a `--fuzz` build's markup installs
  (`Rt.fuzzInstall`, shipped by no other build) and which calls the mount's `$$root` inside the
  same guard and turn an untrusted event's handler runs in, so a throw in `update` stops the page
  as one from a click does. The fuzzer sends either one from a listener of a node of its own,
  dispatched synchronously, so a throw is reported to the page's `error` listeners as a click's
  is. A `--fuzz` pair is built with the fixture's own `platform/` when it has one, and its
  message types are dumped from the project's directory, not its files one by one.

No budget is raised. Three `browser/direct/` pages are over it with the value fuzz (research 66
§6): `Holes` 4 597, `MessageKeys` 4 382 and `VerifyQuiet` 5 007 million instructions — each a
page of seven compiles (four builds, two `--fuzz` builds, a dump). The gates pass them on their
recorded run hashes, as they pass `browser/tea/ApiAndRoutes`.

### *Amended 2026-10-09 (the owner): §5.1's baking widened, and the over-budget pages*

**§5.1, *A static hole is text*,** follows `write-sets.md` §9.1 as the owner widened O8 the same
day: an `Int` within 2⁵³, a string with any character but NUL (escaped), and an attribute's
string or `Int` value (an empty one included; an empty text is not, since the page's text node
would be missing) are written into the template, and no code writes them. A `Float` stays mount
code. The development verify mode checks every baked text hole and attribute after every dispatch,
the value computed again from the model and compared, as text, with what `init` gave. Research 66
§3 has kill criterion 3's bytes re-measured.

**§8.3's value fuzz, for the pages it would take over the budget** (the owner's decision): a
`browser/direct/` page whose two `--fuzz` builds and dump would take it over the 4.3-billion
instruction budget keeps **event-only fuzzing in the gates** and gets its **value fuzzing in `zig
build fuzz`**. It is an explicit, named opt-out: the list `value_fuzz_in_sweep` in
`tests/blackbox/corpus_test.zig`, each page with its reason (today `Holes`, `MessageKeys` and
`VerifyQuiet`), and the gate's fuzz report for such a page begins `value fuzz: in \`zig build fuzz\`
(budget)`. No budget is raised and no `.budget` file is added.

### *Amended 2026-10-09 (PR #36's review): the verify mode reads the page*

**§8.3's verify mode compares the document, not only the slots.** After every dispatch — and the
mount is one, `run`'s, so a page no event reaches is checked once mounted — each text hole and
attribute the check covers is read back from the page and compared with the string its write
would leave there: a text node's `data` with `` `${v}` ``, an attribute's `getAttribute(name)`
with `` `${v}` `` (`safeUrl(v)` for a URL, `""` or `null` for a `Bool`, the payload or `null` for
a `Maybe String`). A write that stored the right slot and left the wrong page is caught, and so
is a baked value the HTML parser read differently from the text the compiler meant: each baked
text hole and attribute is read the same way, its node walked to in a development build only (a
release build walks nothing more). An attribute written as a property, raw markup, a class or
style list or a `stateful` value is not read back. The review's case was a form feed in a baked
attribute: unquoted, `data-ff=a<FF>b` is the value `a` and an attribute `b`, which the verify mode
now stops at the mount (`browser/direct/BakedQuoting`, in happy-dom and in Chrome, before the fix
to `write-sets.md` §9.1's quoting rule below).

With the page read back, three more pages go over the budget with the value fuzz on a fresh run:
`BakedQuoting` (4 315 million instructions), `BakedValues` (4 339) and `UnitHoles` (4 331). By
the owner's rule above they join `value_fuzz_in_sweep`: events in the gates, values in `zig build
fuzz`, which passes on every `browser/direct/` page.

### *Amended 2026-10-09 (slice S2, as specified):* rows, before they are built

§6 and §14 name S2's pieces; this fixes what §6 leaves open and the one place §14 and §6 disagree,
before a line of it is written. The interface is `boundary.md` §9.4.6's version 1.8; the read
the scripts rest on is `write-sets.md`'s amendment *which `[*]` is a row's own*.

- **What S2 compiles.** A `For` keyed by a field (`keyed={.id}`), by a key function, or by the
  item itself (no `keyed`), and a positional one (`keyed={False}`), whose `each` is exactly a
  path of the model or of an enclosing row's item (§6.2, last paragraph) — so a `For` in a
  `For` row is compiled — and whose row is markup with one element at its root. Its scripts
  are §6.2's for `set κ`, `kept [κ]` with sub-writes (`List.update`), `swap κ₁ κ₂`, `append`,
  `prepend`, `clear`, `insert κ` and `removeAt κ`, each under §6.2's guard. A positional
  `For` takes the same scripts over positions where a position keeps its node (`set κ`,
  `kept [κ]`, `append`, `clear`, and `swap` as two indexed patches) and **the positional
  pass** for every other tag and for a derived `each`, which §6.2 makes the positional form of
  `replaced`: patch the first `min(n, m)` rows whose item changed, then append or remove the rest.
- **What S2 refuses, naming the slice that adds it.** On a keyed `For`, a key whose joined tag is
  `replaced`, `permute` or `value` (§6.3's reconciler), `kept [*]` (§6.2's identity walk) or
  `removeSome` (the merge), an index the handler cannot evaluate (below), and a derived `each`:
  S3, whose list §14 gives all four. §14 also lists `browser/dom/Keyed`, `KeyedInPlace`,
  `RowItemOnly` and `RowMountOrder` under S2, and each of them reaches one of these (a
  `rotate`, a `List.reverse`, a `List.map`, a `List.take`); that is §14 disagreeing with its own
  S3 entry, and S3's entry wins: S2 rebuilds each of them on `browser-direct` with the edits S2
  compiles (`List.swap` for the rotation, `List.update` for the relabel, `List.removeAt` for the
  dedupe), keeps the original pages on `browser`, and names in each fixture what moved to S3. A
  row that reads its position (`λrow i →`) in a keyed `For`: S3, since an insert or a remove
  then marks every row after it (§6.2). A row that is not one element — several nodes, text, an
  `if`, a `case` or a `let` around its markup: S4 (§5.4, §5.5). `ForAtEnds`, whose subject is a
  component and a branch around a `For`, is rebuilt the same way with the `For` at each end of
  its parent; the component and branch half is S3's and S4's.
- **The index symbols a handler evaluates** (§6.2, *handler-evaluable*): an integer literal; a
  path of the message along the key's own constructor steps, then fields and tuple components;
  a path of the old model through fields and tuple components. Each is evaluated **before the
  arm**, into a constant, where `model` is still the old model — which is §4.1's step 0 without
  `const old`. A path through a constructor the key does not fix (`ρ.page.Home#0.sel`) could
  name a field of another variant and is treated as `?`: coarser, never a `TypeError`.
- **The list's state.** A **descriptor** per `For` per mount, or per row instance for a `For` in
  a row: `{ p, n, r, m, … }` — the parent element (none for a list at the view's top level,
  whose parent is its end marker's), the end marker (none when the rows are the parent's last
  children), the instance array, `make`, and, where they are needed, whether the rows are the
  parent's only children (`clear` empties it with `textContent = ""`, §6.2), the key function
  (below) and the enclosing row's instance. An instance is `{ e, it, …nodes, …slots, …lists }`.
  **Every loop is the runtime's**: §9.4.3's builder has none, so mounting the rows, `append`,
  `prepend`, `clear`, `insert`, `removeAt`, `swap`, the positional pass, a visit of every row
  and the verify mode's walk are `Direct` functions taking the descriptor, each shipped only
  when reached. The indexed script's guard (`0 ≤ κ < n` and the item changed) is one too, since
  the builder has no `<` either.
- **Row groups, and the two visits.** A row group is called on the rows a key's writes can
  change, and the bound reads decide which: an **element visit** at `κ` calls, on row `κ`, the
  row groups whose reads bound to the row conflict with the element writes at `κ` (`List.update
  rows k f`: the label's group, not the key's); an **all-rows visit** calls, on every row, the
  row groups with a read not bound to the row that conflicts with any write of the key
  (`model.mark` read in a row, `Mark` writing it) — O(n), the case §6.4's selector narrows to two
  rows at S3. Both are §4.1 step 3's (d) for a row site. A keyed list whose element write may
  change the key path makes the row again where the key changed (**rekey**: the old row
  removed, a new one made in its place), as the reconciler would; otherwise the key's holes are
  written once, at `make` (§6.1). A row group no key calls is written at `make` only.
- **Events in a row** follow §4.2: one listener per list instance and delegated event name, on
  the list's parent (for a list at the view's top level, the mount node), its walk the runtime's
  (`Direct.delegate`), buffering and discarding at another list's row root and at another
  program's mount root; a node whose `disabled` is true is passed over, as `browser`'s walk
  passes it. A non-bubbling event gets a direct listener at `make`. What marks a row and a
  handler node — expandos, a key-map or index lookup, a `WeakMap` — is chosen by §6.1's
  measurement, written below when made.
- **The verify mode** (§8.3) checks every list after every dispatch: its length against its
  instances', `get(xs, i) === insts[i].it` for each row, each row's holes as a unique site's,
  and each row's lists, recursively.
- **K3** (`plans/compile-away.md`, Track K). A `For` whose `each` is a model path no key's
  write set conflicts with, whose `init` value is a list literal, and whose every row hole is
  static and bakes per row by `write-sets.md` §9.1 (the item's field at `init`, an exact `Int`
  or a string), with no attribute that needs code, has its rows written into the template:
  each row's text, as `make` would leave it, in list order. Nothing makes them at mount; a row
  with a handler is **adopted** — its instance made over the node the template made, its
  handler nodes marked — and so is every row of a development build, for the verify mode. A
  list that some key writes, or whose rows are not all literal, is made at mount as before.
- **The fuzzer** (§8.3) sends, besides single messages, **bursts**: one generated message sent
  up to forty times in one action, so a page's own `push` and prepend take a list past the
  trie's thresholds (32), which single messages in thirty steps do not reach.

### *Amended 2026-10-09 (slice S2, as built; research 67):* rows

S2 is built as its amendment above specifies (`boundary.md` §9.4.6, version 1.8;
`platforms/browser-direct/zig/direct.zig`, `Direct.beni`'s list functions). What building and
measuring it settled:

- **What marks a row and a handler node: expandos, by measurement** (§6.1). `bench/ui/rowstate.mjs`
  measured five forms of one rows page, hand-written so that only the mechanism differs, from
  real clicks, untraced, ten pages each (research 67 §3). Mount at 1 000 / 10 000 / 30 000 rows,
  relative to expandos: a listener per row **1.11 / 1.09 / 1.10**; an index lookup among the
  parent's children 0.97 / 0.97 / 0.99, but its row event is O(n) — 0.21 / 0.40 / 0.74 ms against
  0.17 / 0.24 / 0.26; a key map read through the page 0.99 / 1.03 / 0.99, which needs the key shown
  in the row, so is not a general form; a `WeakMap` 1.03 / 1.01 / 1.07. **The delegated listener
  stays** (§4.2: a listener per row mounts 9–11 % slower), **and so do the expandos** `$r` and
  `$<event>`: no other general form mounts measurably faster, the index form's 1–3 % is inside its
  quartiles while its event grows with the list, and the five forms are within 20 B of each other
  but a listener per row (139 B, which ships no walk). `emit/direct/ListScripts` pins the shape.
- **A row's item is kept current wherever an element is written**, even where no row group reads
  what was written: a row's listener body reads its item at the event (Q1), so a `List.update`
  that changes a field no hole shows still visits that row (`Direct.row`). Found by the verify
  mode on `KeyedInPlace`'s second list.
- **Two rows side by side swap by one move**, the first row's, as a keyed reconcile moves them, so
  the second keeps its focus; two rows apart move both. Found by the sweep's fuzz.
- **The release optimiser specialises `make`'s calls**: a list whose rows read neither their
  position nor an enclosing row is made with the item alone (`a.m(b)`), the descriptor and the
  position dropped where nothing reads them.
- **A keyed edit is not rank-correct where a key repeats** — an open defect, not a choice.
  `language.md` §11.9 matches rows that share a key by their rank; S2's scripts edit the row at
  the index, so after `removeAt`, `insert`, `prepend`, `swap` or a key change at an index whose key
  occurs again in the list, a row's node (its focus, the text of an uncontrolled input) can sit on
  another item than `browser-tea` puts it on. The page's text, every hole and every row's item, is
  the same on both. Pinned by `browser/direct/DuplicateKeys` with a `.tea-expected`, and found by
  the sweep's fuzz on `KeyedInPlace` (forty duplicates, then a removal). The fix is S3's: a keyed
  script hands its edit to §6.3's reconciler when the key it touches is not unique — a count per
  key kept by `make` and the removals, which S2 measured nothing of.
- **K3 as built**: a list baked is written as text with every end tag (no implied end tag is
  relied on: rows run into one another); in a release build its rows are adopted only when they
  hold a handler, so a menu with no handler costs the template and nothing else.
- **The verify mode on lists** is O(n) per list per dispatch — the rows sweep's development build
  takes 15.6 ms at 30 000 rows against 0.088 for its release build — a development-only cost.

### *Amended 2026-10-10 (the owner): the swap's bar moves to S7*

Kill criterion 4 fired on the swap at 30 000 rows: **0.127 ms against vanilla's 0.113, 1.12×**,
with the bar at 1.0× (research 67 §3). The generated page equals P3, written by hand, in the same
batch (0.127), so the DOM half is at its floor. The remainder is the model's: `List.swap` builds
a new list and the model record is spread, where vanilla swaps two slots. The gap is about
10–15 µs at every N, including 10 rows where no trie exists, so it is the immutable update's
fixed cost more than the trie's path copy.

§13 had already given the rows edit's model cost to S7 and had not done so for the swap, whose
bar came from P3's 0.98 on another day. **The owner moved it the same way**: until S7 the swap
must stay within 1.15× vanilla and no slower than P3; S7 (in-place updates of a list nobody
else holds, §7.4) owns ≤ 1.0×, and S7's kill criterion includes the swap from here on. The
fixed cost per message is to be profiled (record spread against list copy) before S7 is designed.

### *Amended 2026-10-10 (PR #41's review of S2)*

- **A rekey compares keys as a key map does** (§6.2's `set κ`): `===`, and `NaN` equal to `NaN`
  (SameValueZero), the comparison `browser-tea`'s keyed reconcile makes. `===` alone remade the
  row of a `Float` key that is `NaN` on every write to it, losing its focus and the text of its
  inputs. A compound key cannot reach this: a key is a type whose `==` is identity
  (`key_not_primitive`, `checker-v2.md` §25.4), so the comparison is never structural. Pinned by
  `browser/direct/RekeyNaN`.
- **Duplicate keys are an S3 blocker** (CK-221). The open defect of the as-built note above is a
  wrong answer the user sees — a row's node, with its focus and the text of its inputs, on
  another row's item — so it blocks S3's acceptance and is not a note. It is red in
  `tests/pending/browser/direct/DuplicateKeys`, one list per script (`removeAt`, `insert`,
  `prepend`, `swap`, a rekey), its expected transcript `browser-tea`'s; no golden in the gates
  pins `browser-direct`'s wrong output. `browser/direct/KeyedInPlace`, which appended a second
  key 2 as `browser/dom/KeyedInPlace` does, appends a key no row has; the repeated key is
  CK-221's fixture's.
- **The verify mode compares every element** of a list it compares structurally — a derived
  list's row item that is itself a list, a slot holding a list. The cap of the 2026-10-09 text
  (§8.3: past 1 000 elements, the first and last 100) is withdrawn: a development-only cost, and
  the cap let a stale element between them pass. A row's own item was always compared row by
  row; it is a value inside a row that the cap reached. The comparison is a loop, so its length
  costs no stack. A function is still not compared: a closure made again is a new object, and
  two closures are equal only by identity.
- **The verify mode finds a row left behind.** A development build marks each row's root with
  its list (`$v`, written by `make`; a release build marks nothing), and after the rows are
  checked the verify mode counts the nodes of the list's parent so marked: they must be exactly
  its rows. A row a script failed to remove — before the first row, after the last, or in a list
  with none — is found; the order checks alone could not see one before a single row.
- Both are proved on broken builds (`tests/blackbox/page_fuzz_test.zig`, *The verify mode, on a
  broken build*): a positional pass that skips one row, whose item is a list of 1 500 that
  differs at element 750, and a `removeAt` that leaves the row's node. Each stops the page at the
  step that breaks it, naming the row or the count; with the cap restored, or the count taken
  out, the same broken builds run to the end in silence (research 67 §9).
- **The value fuzz is a case of its own.** A `browser/direct/` page is two cases of the corpus:
  the page case builds the four pages and runs them, and the *value-fuzz* case builds the two
  `--fuzz` builds, dumps the message types and fuzzes them, messages as values and bursts
  included, with its record in `<page>.fuzz-run-hash`. Each is budgeted alone, so **every page's
  value fuzz runs in the gates** and `value_fuzz_in_sweep`, with the owner's opt-out it carried,
  is withdrawn: one test per branch, not an exemption (CLAUDE.md, *Building*). The heaviest case
  is 3.8 billion instructions of the 4.3 (research 67 §9). `browser/direct/ListValues` is the
  smallest page that reaches every shape script with an index a payload (`insert`, `removeAt`,
  `swap`, `prepend`, `append`, `set`), its keys always fresh.
- **What a build costs** (research 67 §9): a page's seven compiler processes do not check
  `Direct` again — a build installs the checked core and platforms from the binary in about 1
  ms of `check` — and spend their instructions loading what is embedded (about 165 million a
  process), emitting the runtime module twice (emit's two passes), and, for `browser-tea`'s
  release build, specialising. The message types dump is the one process that checks everything
  from source, about 850 million instructions: `dump` runs without `informational`, which is a
  term of every module's key, so no embedded entry matches. With the bit set the same dump is 165
  million (measured, then reverted: `dump` stays silent about informational warnings on
  purpose). That is the wall — a defect of the dump's keys, not of the page — and its fix (the
  bit out of the keys of modules it cannot change) is queued, not taken here.
- **No nested dispatch of a delegated event in S2.** A list's buffer is one per listener; a
  dispatch of the same event on the same list while `fire` runs would reset it. Nothing in S2 can
  make one: a body runs inside `send`, which queues any message sent while one runs (§4.3), and
  the writes after it fire none of the events `html` delegates; a default action runs after the
  dispatch. Pinned by `browser/direct/RemoveFocusedRow`. **S5 must keep it so**: an effect that
  dispatches an event synchronously (`click()`, `requestSubmit()`) inside a running `fire` gives
  each event a buffer of its own.
- **A blur a row handler's write fires runs before the next handler of the same event** (Q1's
  corner, found in Chrome): a click on a row's button that removes the row, its input focused,
  runs the button's message, then the blur's, then the row's — `browser-tea` runs the blur's
  last, at its render. happy-dom fires no blur on a removal, so the gates cannot see it;
  `test-browser` can. It changes what a program observes, so it is the owner's, with Q1.
- **K3 and a `For` used on two lists** cannot meet in S2: a component that holds a `For` is markup
  as a value, refused naming S4 (`build/bad/direct/ForHelperTwoLists`), so each `For` S2
  compiles has one `each`. The slice that compiles components decides baking per use.

### *Amended 2026-10-10 (the owner): a blur a handler's write fires is delivered where the browser fires it*

Q1's corner of the S2 review (above) is decided. When a row handler's write removes a focused
element, Chrome fires `blur` synchronously, inside the write. On `browser-direct` that blur's
message is queued by the guard (§4.3) and applied when the running listener body returns: after
the event's first handler and **before the event's next handler** — the order the DOM produced,
as a vanilla page's own listeners see it. `browser-tea` applies it last, at its render. **This is
the intended behaviour, and a documented difference between the two platforms**, not a defect of
either: a click on a row's button that removes the row, its input focused, sends the button's
message, then the blur's, then the row's on `browser-direct` (`" remove 1 blur 2 row 2"`), and
the button's, the row's, then the blur's on `browser-tea` (`" remove 1 row 2 blur 2"`).
happy-dom fires no blur on a removal, so the gates see neither order; `zig build test-browser`
sees both. `browser/direct/BlurBetweenHandlers` pins it with a golden per platform for Chrome
(`tests/corpus/README.md`, *Which DOM*): its `.chrome-expected` is `browser-direct`'s order, its
`.tea-chrome-expected` `browser-tea`'s, and its `.expected` the happy-dom page both platforms
show. The page fuzzer runs in happy-dom and never meets the case.

### *Amended 2026-10-10 (slice S3, as specified):* the table app, and the TodoMVC shape

§6, §9 and §14 name S3's pieces; this fixes what they leave open, before a line of it is
written, as S2's amendment did. The interface is `boundary.md` §9.4.6's version 1.9; the
per-call facts it reads are `write-sets.md`'s amendment *a hole's facts per call*. (This line
named `backend.md` §8's building-loop rule too; the owner withdrew it on 2026-10-11, §7.2.)

**What S3 compiles.** Every keyed `For` S2 refused for its tag: `permute`, `replaced`, an
untagged `value` write at or above the list, a derived `each`, `kept [*]` (the identity walk),
`removeSome` (the merge), an index the handler cannot evaluate, and a keyed `For` in a row some
key patches whole; a keyed row that reads its position (`λrow i →`); the selector (§6.4); a markup
helper of the program's own module called in an `html` hole (`{button "run" "Create 1,000 rows"
Run}`), and a component of its own module with no children written between its tags; `Html.map`
whose child is one of those or markup written in place; and these inside rows and inside each
other. **What it still refuses**, each naming its slice: a row or a hole that is not markup
written in place or such a call — an `if`, a `case`, a `let`, a `Show` (S4, §5.4–§5.5); a
recursive helper, a `List Html` hole, markup stored, passed or returned as a value, a component
with children written between its tags, and **markup of another module** (S4, §5.2's value path:
a program's module cannot write another module's function in place, because the backend lowers
each module from its own code and a module's private names are not another's; another module's
markup is a value on this platform, and its messages reach the program through the dispatcher,
§4.4); controlled attributes (S4, §8.1); `Tea.element` and its kin (S5).

**The list's state, extended.** A descriptor is `{ p, n, r, m, o, k, u, w, x, d, z, i }`, every
field on every list, so the runtime's functions see one shape: S2's seven; `w`, the **whole-row
patch** `(r) => …` — every live row group, and each inner list reconciled (keyed) or patched by
position — where some script or the reconciler may patch a row whole, and null otherwise; `x` and
`d`, the **key map** (a `Map` from key to row) and the number of rows past the first of their key,
on a keyed list that keeps one, and null otherwise; `z`, the selector's last probe, or `unset`;
and `i`, whether the rows read their position. **A keyed list keeps the key map** when some key of
the program reaches a selector visit on it, or a script that depends on its keys being distinct
(*Rank*, below); otherwise it keeps none, and nothing is paid for one at mount. Every runtime
function that makes or removes a row keeps the map: a row made registers its key (`d` counts one
more when the key is there already); a removal while `d` is 0 deletes its key; the reconciler
rebuilds both from the rows it leaves; a clear empties both. **The map is exact whenever `d` is
0** — one entry per row, the row with that key — and nothing reads it as exact otherwise.

**Rank (CK-221).** Rows that share a key are matched by their rank among the rows with that key
(`language.md` §11.9), as `browser-tea`'s keyed reconcile, the oracle, matches them. An edit
script edits the row at the index the write set names, which is that only where no key the edit
touches repeats. So each keyed script asks the key map, in O(1), whether it may run, and otherwise
hands the edit to the reconciler, which is rank-correct for any list: `removeAt` and `swap` run
when `d` is 0; `insert` and `prepend` when `d` is 0 and no new item's key is in the map; a row
whose key changed (**rekey**) when `d` is 0 and its new key is not in the map; the merge when `d`
is 0; the identity walk when no row's key changed. `append`, `clear`, and an element write that
keeps the row's key are rank-safe and always run. The table app's `SwapRows`, an `indexedMap` with
index guards (`write-sets.md` §10.4), is two element writes whose rows take keys the list holds:
each is a rekey the map turns away, and the reconciler makes the two moves of its crossed ends.
Pinned by `browser/direct/DuplicateKeys` (CK-221, moved out of `tests/pending/` with
`browser-tea`'s transcript as its one golden) and `KeyedMoves`.

**The reconciler** (§6.3), `Direct.reconcile(L, xs)`: one function, shipped only by a page whose
lists reach it. It matches the new items to the rows by key and rank, makes the new items' rows,
patches the kept rows whose item changed with the list's `w`, moves the rows into the new order,
and removes the rest:

- **Matching** changes nothing on the page, so it may start again. The rows at the start whose
  item is the very one, or whose key is the new item's key, are kept in place: a rank-correct
  prefix whatever repeats. When the old keys are distinct the same is done from the end, and
  what is left between is looked up in a map of the old rows left; a key met twice there — a new
  key repeated, or one a row at the end took — starts the matching again without the end, every
  key chained by rank (`browser-tea`'s full pass).
- **Making and patching** follow `browser-tea`'s order: where the old keys were distinct, the kept
  rows at the start patched, then the new rows made, then the kept rows from the first change on
  patched; otherwise in position order. So a `Debug.log` in a row prints what it prints there
  wherever the two match rows alike.
- **Moving** is `browser-tea`'s `reconcile` (udomdiff over rows, its crossed ends, its parked
  rows), ported to rows of one element, so the same rows move and a focus stays or goes as it does
  there. A list made from none puts each row in; a replacement that keeps no row of a list whose
  rows are all their parent holds empties the parent with `textContent = ""` first.
- Then the key map, where the list keeps one, is rebuilt, and rows that read their position are
  given it (below).

It is reached by a keyed list's `permute`, `replaced` or untagged `value` write, a `value` write
at a prefix of the list, a derived `each` (§6.2's last paragraph: TodoMVC's filtered `For`), an
index the handler cannot evaluate, a keyed list in a row patched whole (the new item's list), and
the rank fallbacks above. A positional list keeps S2's positional pass for all of these.

**The identity walk** (§6.2's `kept [*]`), `Direct.walk(L, xs, f)`: for each row whose item is not
the very one the list now holds, the item is set and `f` — the row groups the element writes
conflict with — called on the row; a length that changed, or a key that changed where the edit
says one may, hands the list to the reconciler. An element write at `[*]` is an edit of its own
(`Program.Edit.rows`'s `changed`), never merged with a visit of every row for a read not bound to
the row, which visits every row whatever its item. **The merge** (`removeSome`), `Direct.merge(L,
xs)`: the rows and the new items walked together by identity, each row whose item is not the next
new item removed; a new item no row shows (a composition the tag's promise did not see) hands
the list to the reconciler.

**The selector** (§6.4). A visit of every row is a **selector visit** when every read that makes
the key's edit call its groups is the path of the row's selector input (`Row.selector`,
`language.md` §11.9): `Direct.select(L, probe, f)`. It runs after the list's scripts (§4.1 step
3's (c), then (d)); it reads the old probe from `z` and writes the new one; when the two are the
same value it does nothing, and otherwise calls `f` on the rows keyed by the old probe and then on
those keyed by the new one — from the map when `d` is 0, by a walk of the rows otherwise — so a
probe no row has, `Nothing`, or the row the same arm removed is skipped, and a row the arm made,
made with the new selection, is visited harmlessly. A key whose visit of every row is not a
selector visit writes `z` after it; `z` is set when the list is made. Pinned by
`browser/direct/Selector` and `SelectAndRemove`.

**A keyed row that reads its position** keeps it in its instance (`i`); after an edit that shifts
rows — `insert`, `removeAt`, `prepend`, `swap`, the merge, the reconciler — each row whose
position changed is given it and patched whole with `w`, as `browser-tea` patches such a row.
Pinned by `browser/direct/PositionRows`.

**Helpers and components, written in place** (§5.2, §9.2). A hole whose value is a call of a
function of the program's own module whose body — after its `let`s — is markup written in place,
a component of such a function with no children written between its tags, and an `Html.map`'s
child are planned **into the enclosing template at the call**: the helper's markup is the
caller's markup there, and its holes the caller's holes, under a **context** — the chain of calls
from the view's root, and the rows between them — that every op of the plan carries. Code that
evaluates a value of the helper's markup enters its context: `view`'s parameter bound to the
model, each enclosing row's item bound, and each call's arguments evaluated in its caller's
context and bound to the helper's parameters (a component's props as a record, or each field of
its record pattern). A `let` of the helper's body that its markup reads is evaluated with the
values that read it; any other (`_ = Debug.log …`) runs where the call's markup is made — the
mount, a row's `make` — and nowhere else (§8.4: a `Debug` in a view prints when its code runs).
**The facts are per call**: the write-set pass records each hole once per call path
(`write-sets.md`, *a hole's facts per call*), so `card "fixed" 7`'s holes are static where `card
"counted" model.count`'s are `Count`'s group, and a hole whose value at that call is a literal
argument — `button "run" "Create 1,000 rows" Run`'s `{label}` and `id={id}` — is baked into the
template by §5.1's rule, so the table app's six buttons are template text with a listener each. A
message written through a call (`onClick={msg}`, `msg` bound to `Run`) is read through to the
argument: `Run`'s handler is called and no message is made. A helper that calls itself, directly
or through others, is on the value path (S4) and refused.

**The size gate, and shared sites** (§5.2). A helper with n call sites is written in place at
each when `n × I ≤ O + 24 n`, or when no call site's copy has an op left after baking (constants
only: template text). `I` and `O` are **estimated from the plan, in bytes**, because the lowering
decides before anything is printed (amending §5.2's "the emitted JavaScript's minified byte
counts"): `I` is the helper's template text plus 12 per node walked, 18 per write with its
compare, and 34 per listener; `O` is `I` plus 64, for the shared form's `make`, its group
functions' parameters and its instance literal. S3 reports the estimate against the printed bytes
on its fixtures. A helper the gate does not write in place is a **shared site**: its template
parsed once; `make(c)`, which clones it, walks to its nodes and builds an instance `{ e, c,
…nodes, …slots }`, `c` being the call's arguments as a function of the model; and its groups,
each a function of the instance and the call's arguments. Each call site holds its instance; a
handler calls each shared group the key's writes reach at that call site, under that call's
facts, with the arguments that call site computes; and its listeners are the nodes' own
(`Direct.listen`), whose bodies read the arguments through `c`. A shared site's markup is one
element, a helper of several nodes is written in place at every call whatever the gate says, and
a helper called inside a row is part of the row's template. Pinned by `emit/direct/Helpers` (the
table app's buttons as text, a helper written in place, one shared) and
`browser/direct/HelperSkip`, `NullaryHelperSkip` and `SharedSite`.

**`Html.map`, composed at compile time** (§9.1). Under `Html.map child f`, a handler value `h` of
the child sends `f h`. When `f` is a constructor, or a constructor applied to arguments through a
placeholder (`Sel row.id _`), the key of `f h` is decided at compile time from the constructors
along it and its handler called directly: with the constructor's fields when the key is that one
constructor, and otherwise — a nested key, `Left · Increment` — with the composed message, which is
then made, as a nested key's handler has taken it since S1. Nested maps compose innermost first.
When `f` is anything else, the listener makes the child's message, applies `f` and hands the
result to the program's dispatcher (§4.4): the program has a carrier, and a dispatcher. Pinned by
`browser/direct/Counters` (`tea/Counters` with its component moved into the page's module; the
original's other-module component is S4's value path) and `MapLambda`.

**The fixtures S2 moved here** are rebuilt as their `browser/dom/` originals: `Keyed` (`rotate`,
`List.reverse`), `KeyedInPlace` (`List.map`), `RowItemOnly` (`List.map`), `RowMountOrder`
(`List.take`) — each keeping its S2 page where that page tested a script; and from `browser/dom/`
`KeyedEnds`, `KeyedMoves`, `KeyedReplace`, `Selector`, `HelperSkip` and `NullaryHelperSkip`, each
without what is S4's, named in its comment; `tea/Counters` as above. `tea/LatestTagger` needs
`Tea.element` and a subscription, which are S5's, and moves there (§14 lists it under S3, which
its subject cannot meet). New: `SelectAndRemove`, `FilteredFor` (TodoMVC's shape: a `For` over
`List.filter` of the model's todos, with a toggle, a filter switch, an add and a removal, measured
at 100 and 1 000 todos in S3's batch), `DuplicateKeys`, `PositionRows`, `SharedSite`, `MapLambda`
and `BlurBetweenHandlers`.

**The oracles.** The verify mode checks, besides S2's checks of every list: a list's key map,
where the list keeps one and `d` is 0 — one entry per row, each mapping that row's key to it; and
a selector's `z` against the probe computed again. A reconciled list needs nothing new: S2's
checks already compare its rows with the new items, in order, in the page. The value fuzzer
generates, for a list payload whose elements are records with an `Int` or a `String` field, lists
drawn from what the page shows as well as fresh ones — the shown values in another order (a
permutation), a subsequence (a filter), a value repeated (duplicate keys) — and each
`browser/direct/` page keeps its value-fuzz case within the budget alone, as S2 set up.

### *Amended 2026-10-11 (slice S3, as measured; research 70):* kill criterion 5 fires

S3 is built (research 70 §0), its fixtures pass on both platforms, and the building-loop rule
is withdrawn (§7.2). Measured in one batch on the table app: **4 524 B** brotli with a non-core
part of 3 783 B (bars 2 830 and 2 400), and the swap at **2.13× vanilla and 2.6× P3**, because
*Rank* hands `SwapRows`' two rekeys to the general reconciler; `select` is 0.60× vanilla but
only 24 % faster than P3. Kill criterion 5 and the P3 criterion both fail, so by §13 the design
stops at S3 until the owner decides; nothing was tuned around the result.

### *Amended 2026-10-11 (the lean slice, as specified):* the runtime slimmed, the swap one edit

The owner deferred kill criterion 5 (research 70 §4) for a measurement of direct with a
P3-sized reconciler, exact edits and the emission waste removed; research 70 §7's hand-written
lean direct priced that at ≈ 2.9 kB with the persistent `List` kept. This slice makes the
compiler emit it, keeping every guarantee of §8 and of S3's amendment — rank (CK-221), the verify
mode, the value fuzz, the defect rule, and the two platforms as each other's oracle (§12.3). What
changes, against S3's amendment above:

- **The reconciler** (§6.3) keeps S3's contract — rank-correct for any list, the new rows made and
  the kept rows patched in `browser-tea`'s order, `browser-tea`'s moves (udomdiff over rows, so a
  focus stays or goes as it does there), the replacement that empties an owned parent — and loses
  its two matchers: the rows kept in place at the start, then one matcher for every list, a map from
  each key to its first old row left and a link from each old row to the next with its key; an
  item takes its key's first row left (its rank's). Whether a key repeated (among the old rows or
  the new items) only picks the make-and-patch order, as before. The S3 matchers' end trimming
  and their second, ranked, pass go. A reconcile that finds no row is `append` (below).
- **One loop makes rows.** The mount's rows, an `append`'s, a reconcile from none and the
  positional pass's new rows are all `Direct.append`; `Direct.mount` goes.
- **A swap is one edit** (§6.2, `write-sets.md` §10.4). A key whose edits of a keyed list are
  element writes at exactly two evaluable indices whose rows may take other keys (the table app's
  `SwapRows`: an `indexedMap` with index guards) is one `Direct.exchange(L, xs, i, j, f)`, its keys
  checked once, after both writes: each row keeping its key is patched where its item changed;
  two rows that exchanged their keys while the list keeps its key map and every key is one row's
  (`d` is 0) trade places — §6.2's swap, two `insertBefore`s, one for neighbours — and are then
  patched where their item changed; anything else, a key that repeats among them, is the
  reconcile, rank-correct for any list. *Rank*'s refusal of the intermediate state (one write
  applied, a key held twice) no longer arises: the state checked is the message's last.
- **The visit a runtime function is handed is a name where one exists**: the list's whole-row
  patch `w` where the visit patches every live group, the group's own function where it calls one,
  a function of its own only otherwise.
- **The descriptor is the program's own.** A row's instance carries its list's number (`l`, a
  number among the page's `For`s) for the delegated walk (§4.2), not the descriptor, so the
  descriptor of a list of the view's root does not escape to the DOM and the release optimiser's
  facts (`backend.md` §9, facts 3–4) fold its constant fields — `o`, `i`, a `null` end marker, the
  key function — into the runtime functions the page reaches. `sameKey`'s `NaN` test goes: a key
  that is not `===` itself reaches the reconcile, whose map holds `NaN` as one key.
- **A listener outside a list with no flags** (§4.2) is `Direct.on(el, name, h)`, one shared
  function; `h` is the key's handler itself where the body only calls it with nothing (no payload,
  no field, every call written in place on the way given constants: the table app's buttons).
- **Errors at the mount are short in a release build** (§8.2, §8.4): `mounted twice`, `cannot mount
  at <id>`; the development build keeps the prose. `browser-tea`'s release keeps its own
  (`DefectAtMount.tea-release-expected`).
- **Unchanged**: the dispatch guard queues a send that arrives mid-dispatch, on every page (§4.3,
  the owner's decision below); the key map's rule (S3: kept where a selector or a script needing distinct keys
  is reached — the table app reaches both), the merge, the identity walk, the selector visit, the
  verify mode's checks.

New fixtures: `browser/direct/ExchangeRows` (the swap as one exchange, a focused row no edit
touches keeping the focus, then a key that repeats sending the swap to the reconcile, rank-correct)
and `ReconcileMoves` (a row moved alone, crossed ends, a reversal, a replacement keeping the middle
row's node), each on both platforms against one golden; `emit/release/direct/TableSwap` (the
exchange, `on` with the handler, no test of `o` or `i`).

### *Amended 2026-10-12 (the lean slice, as measured; research 73):* faster everywhere, 4.1 kB

Built as specified above, with one change found by measurement: a reconcile that finds no row
keeps S3's straight insertion of each row (a fragment there read 1.07× S3 on `create10k`). The
table app is **4 110 B** brotli (3 898 with the markup in the HTML; S3 4 524 / 4 305), non-core
3 384, core 726 (with the queue on every page, below); every operation at or under S3 within its spread, `swap` 0.11 ms (S3 1.01; the
same fast and slow sample groups as vanilla), `select` 0.67× vanilla and 0.80× P3. Kill criterion
5 still fires on bytes, and the P3 criterion fails on bytes only. The gap to research 70 §7's
2.9 kB is the guarantees this platform keeps and the prototype did not — rank-correct duplicates
and their key map, `browser-tea`'s moves (P3's would save 140 B and make the focus differ from
the oracle on eleven pages of the 50-seed sweep), the defect guard, several programs per page —
and the persistent `List`; research 73 §5 lists what the owner decides.

### *Amended 2026-10-12 (the owner, on PR #55):* the queue on every page, short mount errors kept

Two decisions on the lean slice as first proposed. **The dispatch queue stays on every page.** A
draft of this slice shipped the guard's queue only where an analysis of the page's listeners
found an event a DOM write could fire mid-dispatch, and stopped the page on any other such send.
The owner refused it: a page must never stop because an event the analysis did not foresee sent a
message, and the ≈ 30–40 B the queue costs a page that never re-enters are accepted. `Direct.send`
queues a send made while a dispatch runs, on every page, as S1 specified (§4.3); there is no
`Direct.reentrant`. The fixtures that exercise a send mid-dispatch (`BlurBetweenHandlers`,
`RowBlur`, `RemoveFocusedRow`) stay. **The short release errors at the mount are approved**:
`mounted twice` and `cannot mount at <id>` under `--release`, the prose in development.

### *Amended 2026-10-12 (`boundary.md` §9.8.16):* `init` is a function of `⊤`, on both platforms

The program record's `init` is `sync (⊤ → model)` (`sync (⊤ → model × Cmd msg)` for `element` and
`document`), the owner's decision for every platform (thesis Change 4). §11.1's "it needs `init` as a
value" now reads: it needs `init`, a function, and the hook evaluates `init ⊤` in the mount. A lambda
of `⊤` written in the record, `init = λ⊤ → e`, is lowered as its body `e`, in the mount, so every page
whose `init` was `e` is byte for byte what it was (`emit/direct/` did not move); a named function is
called. The write-set pass reads `init`'s literals the same way: a lambda's body evaluated where the
record is, any other function applied (`write-sets.md` §3.5's literals are unchanged on every
`writes/` fixture). §12.1's *`init`'s evaluation is a specified difference between the platforms* is
withdrawn: `browser-tea` calls `init` at mount too, so a throw in it is a defect of the mount on both
platforms and `browser/direct/InitThrows` has one golden. A program built by a function,
`counter start = Tea.sandbox { init = λ⊤ → start, … }`, is what `program_mounted_twice` now suggests.

### *Amended 2026-10-13 (slice S4, as specified):* guarantees and the rest of rendering

§5, §8, §9 and §14 name S4's pieces; this fixes what they leave open, before a line of it is
written, as S2's and S3's amendments did. The interface additions are `boundary.md` §9.4.6's
version 1.10, written there as they are built. S4 is built in this order, each step on its own
commit with its fixtures: **the value path**, **controlled inputs**, **branches and `Show`**,
**derived values**, then **programs, defects and the SVG root**, then the measurement.

**Q3, and what moves to S5.** Q3 is answered (the owner, 2026-10-09): `Browser.flush` does nothing
on this platform and `Dom.rendered` resolves at the end of the dispatch. A `Tea.sandbox` has no
command, so neither `Dom.rendered`, nor after-render work, nor a send from it can be reached before
`Tea.element` is compiled: `end()` in S4 is the edited set's reconcile (item 2) and nothing else,
and **`RenderedSends` and `DefectInAfterRender` move to S5** with `Tea.element`, as `tea/LatestTagger`
moved from S3 (§14 lists them under S4, whose subject cannot hold them). So does the fibers'
teardown (`Task.shutdown`, §8.2): a page reaches `Task` only through commands.

**1. The value path (§5.2, §16).** What it is: `dom`'s kinds and blocks, `backend.md` §15.3–§15.5,
unchanged. The `direct` lowering's `root` is `dom`'s, so a markup root that is a value evaluates to
a block `{ t, v }` whose kind `{ m, p }` is hoisted once per site; `Lowering.no_markup_values` is
no longer set, and `Html.text` and `Html.map` are `Direct`'s exports of those names. What runs a
kind is `Direct`'s: the functions of `browser`'s `Rt` that touch only the DOM — `template`,
`slot`, `unit`, `patch`, `place`, `put`, `drop`, `swap`, `childHtml`, `childMaybe`, `childList`,
`forKeyed`, `forPosition`, `show`, `hide`, `restate`, `text`, `map` — taken as they are (imported
from `Rt` where the module system allows it, copied otherwise; they keep no page-wide state), and
its own for what enters program code or keeps state for the page: the events, the controlled
inputs (item 2), the fuzz hook.

- **What is on it.** Every markup the platform does not write in place: a hole — `html`, `Maybe
  Html` or `List Html` — whose value is not a call S3 writes in place and not a branch item 3
  compiles; so markup of another module, a helper that calls itself, a helper whose body computes
  its markup (an `if`, a `case`: the branch is then the kind's, inside the helper), a component
  with children between its tags, markup held in a `let`, a record or an argument, `Html.text`,
  and an `Html.map` of any of these. And a **whole `For`** whose row is not one element written
  in place (several nodes, text, an `if`, a `case` or a `let` around the row's markup) or that has
  a `fallback`: such a `For` is planned by `dom` as a markup value of its own — its rows `dom`'s,
  `forKeyed` or `forPosition` — and placed through a value slot like any other. §6's scripts move
  one element per row; a row of another shape is the value path's, at today's cost.
- **A value slot.** In a site this platform writes (the view's root, a row, an arm, a shared
  site) each such hole is a slot `Direct.slot(parent, marker, null)`, made at mount where the hole
  stands, and an op of a group of its own read set (§5.3): the group evaluates the value and hands
  it to `childHtml`, `childMaybe` or `childList`, which patches the instance shown when the block
  is of its kind and mounts a new one in its place otherwise (`backend.md` §15.4). The compare is
  the kind's, per hole, inside `p` — a structure is never compared by its identity (§5.3). A key
  whose writes do not conflict with the hole's read set leaves the slot as it is; a value that is
  made on every render (`Tree.everyRender`) makes the group every handler's (§5.3).
- **Events.** A kind's handler node listens on itself, for every event — `dom`'s form for an
  event that is not delegated, `Direct.listen(el, name, flags)` — so the DOM's bubbling orders it
  against this platform's own listeners as Elm orders handlers (§4.2), and no document listener
  exists. The declaration's flags run in the DOM listener; the body — the message the node holds,
  or makes of the event's payload, passed through each `Html.map` context it is inside, innermost
  first (`$$cx`, `Rt.map`'s) — runs inside `send`, and the message goes to the **dispatcher**
  (§4.4) of the program whose mount node is nearest above the node: a program with a value slot
  writes its dispatcher on its mount node as `$$root`, where `run` writes `true` (§8.2's mark,
  which the row walk's discard of another program's nodes reads, unchanged). A program with a
  value slot therefore has a carrier and a dispatcher, whether or not its kinds hold a handler.
- **The verify mode** (§8.3) checks a value slot by its block: the value is computed again and
  compared with the block the slot's instance shows (`i.b`) — its kind by identity and its values
  structurally, by `same` (a function is not compared). What a kind writes inside itself is
  `dom`'s and is not walked: a known limit of the check, in §16's terms.
- **The dump** (§11) already counts these roots (`site … value`, `markup_value_roots`); S0's kill
  criterion 1 bounded their number.

**2. Controlled inputs (§8.1).** A `stateful` attribute is compiled: its write is
`Direct.control(el, prop, v)` — `backend.md` §15.3's write: the value kept on the element as
`$$s[prop]` and written when the page's differs — in a group compared by its slot as any
attribute. The **edited set** is `browser`'s, in `Direct` (it keeps state for the page): the
first `control` installs the four capture listeners (`input`, `change`, `click`, `reset`) and
`pageshow`, which mark the controls an edit may have changed, and `edited(el)` marks one a write
of the runtime's may have changed (`dom`'s kinds call it); **`end()`** — called by `send` after the
queue drains and before the verify mode — puts every marked control back to its kept value and
clears the marks; a `reset`'s and a prevented checkable click's controls are put back in a task,
which does nothing once the page has stopped. The marks are the page's, one set, since every
dispatch ends with `end()`. And the **no-op send** (§8.1): the first `control` also adds a
bubble-phase listener on the document for the four names, `send(noop, e)`, so `end()` runs after
every user edit, handled or not. A page with no `stateful` attribute ships none of it. Pinned by
the `browser/dom/Controlled*` pages, rebuilt for this platform where their subject is a sandbox,
and `ControlledNoHandler`.

**3. Branches and `Show` (§5.5).** What is compiled: an `html` hole, in markup this platform writes
in place, whose value is an `if` or a `case` (its `let`s allowed, as a helper's), each of whose
arms' results is markup written in place or a call S3 writes in place — an arm whose result is
anything else holds one value slot (item 1); and a `Show`, keyed or by identity, its body an arm
whose item is the `Just`'s payload and its fallback, when it has one, a second arm (markup written
in place, or a value slot).

- **An arm's state is an instance**, `{ …nodes, …slots, …lists, …branches }`, made at its mount as
  a row's is (§6.1), and a branch is `{ k, i }` — the live arm's number (`-1`: nothing shown) and
  its instance — a name of the mount for a branch of the view's root, a field of the instance it
  is in otherwise. **Teardown drops the instance**: its nodes are removed, and nothing reads its
  slots again; the arm mounted next is a new instance, every slot `unset`. That is §5.5's reset by
  construction rather than by writing the sentinel back (amending "module-level", as S1's
  amendment did for §5.2): an `A → B → A` with the same values writes every hole of the new `A`.
- **An arm's markup** is a site of any shape — several nodes, text, holes — placed before the
  branch's marker; its instance keeps its top-level nodes, which teardown removes.
- **The handler** (§4.1 step 3): a branch whose scrutinee's reads conflict with the key's writes
  computes its arm again — the same arm is **visited**, another is torn down and the new one
  **mounted** from the current model, and an arm mounted in this dispatch is not visited again; a
  branch whose scrutinee does not conflict visits its live arm only if some group, list or
  branch of that arm is called. Every visit is under the arm's liveness, `if (b.k === 1) { … }`.
  The scrutinee's read set is the hole's own facts (`write-sets.md` §3.6: an `Alt` reads its
  scrutinee and every arm), which over-calls the arm computation by the arms' reads and never
  misses a switch.
- **A `case` arm's variables** are bound again from the scrutinee wherever the arm's code
  evaluates a value — a group, a list's items, a nested branch — the scrutinee evaluated again
  where the arm's values are (a path read, as §5.3's groups read), through `cx` (version 1.10); a
  `Show` body's item is the `Just`'s payload, read the same way.
- **`Show`.** A keyed `Show` keeps its arm while the key is the same (SameValueZero, as a rekey
  compares, S2's review) and visits its body with the new payload; another key, or `Nothing`,
  tears it down. A `Show` by identity keeps it while the payload is `===` the one shown.
- **The verify mode** checks each branch's `k` against the arm computed again, and the live arm
  as a site.
- **A branch inside a row** is a field of the row's instance and compiled; a branch at a row's
  root makes the row not one element, so its `For` is on the value path (item 1).

**4. Derived values (§5.4).** A constant `let` of `view`'s body, or of an arm's, that only markup
reads is a **derived value**: a slot, and a function that computes it again, called by every key
whose writes conflict with the `let`'s read set — anchored as a hole's (`write-sets.md` §3.6), by
version 1.10 — in step 2 for the view's own `let`s and first in the arm's visit, under its
liveness, for an arm's (§4.1 (a)), before anything that reads it; and at the mount of its arm (or
of the page) before the arm's groups. The groups that read it read its slot. A `let` that reads an
earlier one reads that one's slot and its read set includes that one's (§5.4); a `let` no markup
reads runs where its markup is made, as S3's rule says (§8.4). The verify mode computes each
derived value again and compares it structurally (§8.3). The `let`s of a helper written in place
keep S3's rule (evaluated with the values that read them).

**5. Nested updates (§7.3).** Nothing new is compiled: a nested key's handler runs the arm S1
writes, with the sub-message made as a value (§4.1); the release specialiser that would remove it
is §4.1's `--release` work and is not built in S4. The depth sweep measures what it costs.

**6. Programs, defects, the SVG root.** **Programs**: a program built by a function has its
state per mount since S1 (the mount's own scope); S4 pins it (`ProgramsByFunction`), pins an
outer list's walk discarding an inner program's handlers (`NestedPrograms`), and rebuilds
`TwoPrograms` and `MountedPrograms` where their subject is a sandbox. **Defects**: the guard, the
crash screen and the stop are S0's and S1's; S4 rebuilds the `browser/dom/Defect*` pages and
adds a defect in a value-path handler and in a derived value. **The SVG root** (`boundary.md`
§9.9 (f)): a `view` whose root is an SVG element other than `<svg>` is compiled — its template
parsed inside the `<svg>` wrapper and taken from inside it, as a row's is since 2026-10-12 — and
mounted into the mount node it is given; mounted at an `<svg>` (`Browser.mountAt`), it draws.
`browser/direct/SvgRoot` mounts one at an `<svg>` in the page. A MathML root other than `<math>`
stays refused (no vocabulary declares MathML).

**7. The fixtures and the oracles.** Every fixture of §14's S4 list whose subject a sandbox can
hold is built for both platforms against one golden (§12.3); each `browser/dom/` page S4 reaches is
rebuilt on `browser-direct` with `Browser.program` written `Tea.sandbox`, as S3 rebuilt its own,
keeping what is another slice's out and naming it. New: `ValuePath` (another module's markup, a
helper that calls itself, a `List Html` hole, `Html.text`, an `Html.map` over a lambda, a
component with children, each with a handler), `ValuePathEvents` (a value-path handler inside a
direct handler's element, and the reverse, with `stopPropagation`: Elm's order), `WholeFor` (a
`For` whose row is an `if`, and one with a `fallback`), `ControlledNoHandler`, `BranchReturn`,
`LateResponse` (as a sandbox: a message for an arm no longer shown, and for a `Show` that closed),
`LetInArm`, `SwapAndShow`, `ProgramsByFunction`, `NestedPrograms`, `SvgRoot`, and
`EventReadsModel`'s removed-focused-input half (§4.2, the S1 note). `emit/direct/` pins a value
slot, a branch with its liveness test, a derived value's slot and a `control` write. The value
fuzz runs on each, within the budget alone (S2's amendment).

**8. What S4 is judged by** (§13; `plans/compile-away.md` §7's S4 row): live rows 10 000 ≤ 1.15×
vanilla, derived 100 000 flat and ≤ 1.15×, depth 128 ≤ 1.3× (S7 owns 1.15×), each untraced, in one
batch with vanilla, Solid 1, Solid 2, `browser-tea`, P3 where it has a page, and the table app
again; research 84's protocol for an operation under a millisecond. Kill criterion 8 at every
step. §13 names no kill criterion of S4's own; a target missed is reported, not tuned around
(rule 10).

### *Amended 2026-10-13 (slice S4, the value path and controlled inputs, as built)*

Items 1 and 2 of the amendment above are built (`boundary.md` §9.4.6, version 1.10;
`platforms/browser-direct/zig/direct.zig`, `Direct.beni`); items 3–6 are not, and are still
refused naming S4. What building them settled, each a place the amendment left open:

- **`Rt` is imported, not copied.** `Direct` imports `browser`'s `Rt` — a runtime module may import
  every module its package sees (`boundary.md` §9.2), and `browser-direct` layers on `browser` —
  and supplies each export `dom`'s kinds call (`template`, `slot`, `childHtml`, `childMaybe`,
  `childList`, `forKeyed`, `forPosition`, `show`, `hide`, `restate`, `text`, `map`) as a function
  that calls `Rt`'s. A page that reaches none ships none: the release empty page did not move
  (`emit/release/direct/EmptyPage`, 588 B, byte for byte). The kinds' `listen(el, name, flags)`
  is `Direct`'s own; the row node's own listener of S2, which had that name, is `listenRow`.
- **What is a value slot**, decided by one walk before planning (`supported`): a `Maybe Html` or
  `List Html` hole; an `html` hole that is not a call S3 writes in place — no callee, a refused one
  (another module's, a component with children, a body that computes its markup), or a call of a
  helper already being written on the current path; and a `For` with a `fallback` or whose row is
  not one element written in place, judged structurally (an element, alone in its fragment, or
  reached through calls written in place) and checked again by the plan. An `html` hole whose value
  is an `if` or a `case` is item 3's branch and is refused until it is built
  (`cx.programBranch`, version 1.10). **An `Html.map` written in place whose markup holds a value
  slot is itself a value slot**, its maps `dom`'s: S3 composes a mapped call's messages at compile
  time, and a slot made with no context would send its markup's messages unmapped.
- **Read sets.** A value slot of an `html` hole is grouped by the pass's facts for the hole
  (`programHole`), as any hole. A component's call and a whole `For` have none the pass records —
  a component node is no hole, and a `For`'s hole is its `each` — so **every key calls them**, and
  every key visits every row of a list whose rows hold one, and of each list around it. Correct, at
  the value path's cost; recording these reads in the pass would narrow it.
- **What the hook consumes and its code names is written.** S3's rule leaves unwritten a markup
  helper only consumed declarations name; a value slot calls such a helper (`List.map xs row`), so a
  consumed declaration the lowering's code names is lowered after all (`boundary.md` §9.4.6,
  version 1.10).
- **A skipped value slot is not restated**: an every-render value (`Random.value`, `Time.now`) in
  markup on the value path is evaluated when its slot's group runs, not on every message. A
  stated limit in §16's terms, as the verify mode's below.
- **The verify mode checks a value slot by its page, not its block's values.** The value is
  computed again; the instance the slot shows must be of its kind, by identity, and a fresh
  instance of the value, mounted off the page, must read as the slot's nodes do (each element's
  markup, each text's and comment's data; `Direct.verifySlot`). Comparing the block's values
  structurally, as the amendment says, would report what is not a defect: a grouped kind's block
  holds its root's inputs, whole locals, so `viewStatus model`'s block holds a `model` that a key
  writing a field `viewStatus` never reads leaves behind, rightly. An instance that is live
  (`l`, holding an every-render value) is checked by its kind only; a slot whose value reaches
  `Debug`, or may be another value on every evaluation, is not checked. A component's call is not
  a value the check can ask `reachesDebug` of, so a `Debug` in a component's body on the value
  path prints again in a development build: a known limit.
- **`end()` is queued, not called.** The first mark of a dispatch — a control's capture listener,
  or `edited` — queues the reconcile behind what the dispatch has queued (§4.3's queue), so it runs
  as the queue drains, after the writes queued before it and before the verify mode; a mark a later
  message makes queues it again. That is §4.3's `end()` for the edited set, and it leaves `send`
  as it was: a page with no `stateful` attribute ships none of it. S5's after-render point, which
  needs `end()` in `send`, is S5's to add. This platform's own writes mark as `dom`'s do
  (`backend.md` §15.3, *the runtime's marks*): a group marks the controlled elements its writes are
  on or in, at its end; a list's scripts mark those its rows are in, as do its first rows at mount
  (`browser/direct/ControlledOptions`).
- **Not rebuilt**, each for a reason of this platform's: `browser/dom/ControlledPrograms` — the
  marks are the page's, one set, by the amendment, where that page pins one set per program;
  `ControlledRemoved` — a control's edit is put back at once by the no-op send, so it is never
  still marked when a later message removes it; `ControlledReset` — happy-dom resets a form's
  controls before it dispatches `reset`, so the no-op send puts them back at once where Chrome,
  which dispatches first, puts them back in the task, and one golden cannot hold both. The edits
  with no handler are `ControlledNoHandler`'s, which is `browser-tea`'s `.tea-expected` where they
  differ. `ControlledOptions` adds options of distinct values: two options of one value are a page
  happy-dom selects both of, which the two platforms' orders of writes then show differently.
- **`ValuePathEvents`' reverse nesting** — a handler this platform writes inside one on the value
  path — cannot be written: markup on the value path is `dom`'s to its leaves. The page pins the
  order across a value slot both ways a stop can stand (a stopper on the value path below one of
  this platform's handlers, and one of this platform's around value-path markup) and inside one.
- **The value fuzz** of a project that has a platform of its own and several modules dumps its
  message types from a directory of its modules, as a project without a platform does
  (`tests/blackbox/corpus_test.zig`): `dump` takes one path.

### *Amended 2026-10-13 (slice S4, branches and derived values, as built)*

Items 3 and 4 of the S4 amendment are built (`boundary.md` §9.4.6, version 1.10;
`platforms/browser-direct/zig/direct.zig`, `Direct.beni`, `src/js/Lower.zig`); item 6 is not, and
still refused naming S4. What building them settled, each a place the amendment left open or got
wrong:

- **An arm is a site of its own.** Every `markup` instruction is a root of the tree, so an arm's
  markup is a root whose inputs are every local its values read bound outside it — the `case`'s
  pattern variables, the arm's `let`s, the `let`s around the `case`, `view`'s parameter. It is
  planned as a row's markup is (its holes, lists, value slots and branches), with nothing baked,
  and made by `make(u)`, which clones its template whole (several nodes, text), walks to its
  nodes, builds its instance `{ e, u, a, …nodes, …slots, …lists, …branches }` and makes its first
  writes, rows and arms. A branch's state is `Direct.branch(parent, marker, makes)`: `{ k, i, s,
  p, n, m, y }`, where `s` is a comment the branch puts where its arms go, once, so that tearing
  an arm down is removing the nodes between `s` and the op's marker — whatever an arm's top-level
  slots, lists and branches have put there since — and `Direct.arm(b, n, u)` tears the shown arm
  down and makes arm `n`. An arm whose result is a call of a helper written in place (S3) is the
  helper's markup entered with the call's arguments; any other result is a **value arm**, one value
  slot made where the arms go.
- **The scrutinee is not a path read.** It is any expression, so it is evaluated again — the
  `let`s around the `case`, the scrutinee, the decision up to the arm — wherever the arm's values
  are: `cx.programBranchEnter` lowers the hole's value again with each arm's result replaced, arm
  `k`'s by the array of what binds its values (its root's inputs, or its call's arguments) and every
  other arm's by `null`, then binds the arm's root to the array's entries. `programBranchArm`
  lowers it with every arm replaced by its number. Each lowering is in a JavaScript block of its
  own, since two in one function would bind the same names twice. An arm's `let`s its result does
  not need run only where it is made (`made`), as a helper's do (S3, §8.4).
- **Arm `let`s are not `Root.lets`.** A root inside another root's value takes no `let` (one owner
  per `let`, `MarkupTree`), and an arm's root is inside the hole's value, so an arm's `let`s are
  evaluated with its values, where they are bound — every time a group, a list or a nested branch
  of the arm evaluates them — not kept in a slot of the arm: item 4's arm-level derived values are
  not built. The `let`s of `view`'s own body are: a `view` whose body is `let`s around markup is
  compiled (`Program.view_lets`), each `let` its root takes is a slot of the mount, computed at
  mount and again in step 2 by a key whose writes conflict with its read set, which the write-set
  pass now records per `let` (`write-sets.md`, *a `let`'s facts per call*), and every group reads
  the slot (`cx.bindLet` after `programViewEnter`). A `let` of `view` that its root does not take
  and its markup reads — one that may have an effect — would run wherever the root's values do, so
  it is refused (`build/bad/direct/ViewLetEffect`). A `view` whose body past its `let`s is not
  markup is refused, naming `<>{…}</>` (`build/bad/direct/ViewBranch`).
- **A `Show`'s fallback** is not a root the tree maps for a lowering: `cx.programShowFallback`
  gives the markup root a fallback written in place is, and `programNestedEnter` binds its inputs
  where it stands, so it is an arm site; a fallback that is any other value, and a body that is a
  function or a lambda whose body is not markup, are value arms. A keyed `Show` keeps its arm while
  its key is SameValueZero to the one shown (`Direct.sameKey`) and one by identity while the
  payload is `===`; its key and payload are evaluated where it is.
- **Facts per arm.** The pass walks an arm's markup on the branch's call path plus the hole's
  token, and a `Show`'s body and fallback on the branch's own path; a call arm's helper is walked on
  the branch's path with no second token. `programBranchEnter` with no block extends the path the
  same way. Two arms calling one helper therefore share one fact entry, which is sound and
  over-calls. A branch's own facts — the hole's `Alt`, its scrutinee's reads and every arm's — are
  what a key recomputes the arm for.
- **The handler.** Step 3 visits, per site, its branches, then its lists, then its groups (a row
  keeps S2's order, its groups before its lists). A branch whose facts conflict computes its arm;
  another arm (or, for a `Show`, another key) is torn down and the new one made, and is not
  visited; the same arm is visited. Otherwise the live arm is visited only where some branch, list
  or group of it is called. Every visit is `if (b.k === j) { const a = b.i; … }`. A branch in a row
  is visited with the row's visit — its groups, `whole` — and a row patched whole visits its
  branches whole. A hole of an arm in a row with no facts makes its list's every row visited by
  every key, as an unknown value slot does.
- **An arm torn down still delivers its events.** A handler node's event can reach an arm the
  same dispatch tore down (a click whose own handler closes the arm, bubbling to the arm's next
  handler; a blur a removal fires). Its listener body reads the instance's branch: when the
  instance is no longer shown (`b.i !== r`), the arm's variables are bound from what the instance
  kept (`a`, `programBranchEnter`'s `held`), the array of what bound them when the arm's values
  were last evaluated — as a row's event is delivered with the item it showed (§4.2,
  `browser/direct/DetachedArmEvent`). An arm keeps `a` only when a handler node is in it, in a row
  of it or in an arm inside it.
- **The verify mode** computes each branch's arm again and compares it with `k`, then checks the
  live arm as a site, or a value arm's slot as a value slot; a branch whose scrutinee reaches
  `Debug` or is made on every evaluation is not checked. Each derived value is computed again and
  compared by `Direct.same`, which compares a markup value — `dom`'s block — by its kind only: its
  values are its root's inputs, whole locals, which a derived value that reads only some of their
  paths keeps from when it was computed, rightly (the value path's note above); the page it shows
  is checked where it is shown. `cx.reachesDebug` now follows a `let` a value reads and markup a
  value makes, so a slot whose markup prints is not mounted again by the check.
- **`cx.rootValues` binds the `let`s it evaluates.** A helper written in place whose markup read
  its own `let` read an unbound name, since S3 evaluated `Root.lets` through `rootValues` and
  bound none (`browser/direct/HelperLet`, red before this slice).
- **Two values made on every message are drawn in each platform's order.** Step 3 visits a
  site's branches before its groups, where `dom` evaluates a grouped root's values in the order
  of each group's first write, so two `Random.value`s of one message — one in an arm, one in a
  hole after it — draw in the opposite order on the two platforms, and one golden cannot hold
  both. Both orders are a function of the model; `browser/direct/EveryRenderNested` keeps one
  draw, and leaves out the original's `let` that calls a helper that draws, which is the refused
  shape above.
- **The rebuilt `LetChain` is a hundred `let`s long**, not 250: a `browser/direct/` page is built
  for both platforms, each twice, and the original's length put the case over its instruction
  budget with the code it reaches unchanged. Building it found a quadratic walk in
  `cx.reachesDebug` once it followed `let`s, which now remembers the `let`s it found free of
  `Debug`.
- **Not built**: item 6 (programs, defects, the SVG root) and item 4's arm-level slots, above;
  `EventReadsModel`'s removed-focused-input half, whose blur happy-dom does not fire (the page
  pinned here is `DetachedArmEvent`'s bubbling, the same path). New pages: `BranchReturn`,
  `LateResponse`, `LetInArm`, `SwapAndShow`, `ShowAndBranches`, `RowBranch`, `DetachedArmEvent`,
  `HelperLet`, and the rebuilt `LetInMarkup` (its `if` written in a hole), `LetOneOwner`,
  `LetChain`, `EveryRenderTop`, `EveryRenderNested`; `emit/direct/Branch` and `DerivedValue`. The
  refusals `build/bad/direct/MarkupHole` and `ForRowBranch` are pages now (`BranchReturn`,
  `RowBranch`) and are gone; `ViewLetEffect` and `ViewBranch` pin what is still refused.

### *Amended 2026-10-13 (slice S4, review fixes, programs, defects and the SVG root, as built)*

The review of the two as-built steps above, and S4's items 6 and 7 left open there, are built
(`boundary.md` §9.4.6, version 1.10, *amended for S4's review*; `platforms/browser-direct/zig/direct.zig`,
`Direct.beni`, `src/js/Lower.zig`, `src/writes/Writes.zig`, `write-sets.md`, *the direct platform's
S4 review*). Each finding has a page or a golden that failed before its fix, unless said. What it
settled:

- **The verify mode reads a value slot's page as sets** (`Direct.samePage`, `sameElement`).
  Comparing the slot's `outerHTML` with a fresh mount's reported a correct page: a class switched
  on is appended, a style property set again goes last, an attribute that turns on is added after
  the others. Each element is now its name and namespace, then every attribute the fresh mount has,
  equal on the page — a class list and a style's declarations as sets — then its children. Not
  compared: an attribute only the page has (the host's or an extension's; one a missed removal
  left is a limit of the check, whose opposite, an attribute missed, it catches), `open` on
  `details` and `dialog` (the user's, §8.1), and the children of a `contenteditable` element. No
  step can edit a `contenteditable`, so that rule has no page (`browser/direct/VerifyAttributeOrder`,
  Chrome too).
- **A kind's event is resolved as it fires** (`Direct.listen`): the mount node above the node, its
  handler, its extractor and its maps are read in the DOM listener, and only the message — the
  extractor applied, the handler called, the maps — is made in the body `send` may queue, inside
  the guard, as §4.2 says of a payload read. A blur the handler's own removal fires is delivered
  (the 2026-10-10 amendment); it was dropped, its node having no parent by then
  (`browser/direct/ValueBlurOnRemoval`, a `.chrome-expected`: happy-dom fires no blur on a
  removal). No happy-dom page reaches the queued path: happy-dom fires nothing synchronously from a
  write that a value-path node could hear. A stopped page's `listen` applies no flag, as
  `browser`'s `Rt.fire` does.
- **A component's call is not made again by the check when its function may print**
  (`Program.Callee.debug`; `reachesDebug` follows the components of markup a value makes). The
  review's case did not reproduce: a component is another module's, and the markup tree marks a
  call of one that reaches `Debug` impure, so its slot was every-render and unchecked already. The
  rule is now the check's own; `browser/direct/VerifyQuietComponent` pins it, and passed before.
- **`ControlledReset` is rebuilt**, with a golden per DOM: happy-dom resets before it dispatches
  `reset`, so on this platform the no-op send puts the controls back at once (`.expected`), and
  `browser-tea` in the task (`.tea-expected`); Chrome dispatches first, and both platforms put them
  back in the task (`.chrome-expected`). It found a defect in Chrome: the reset's own reconcile ran
  before the reset and took the held controls' marks, so a message before the task left the
  defaults on the page. Every later edit's capture listener marks the held controls again
  (`edits`): the dispatch it ends in puts them back, as `browser-tea`'s render does. A message
  that is not an `input`, `change`, `click` or `reset` before the task does not: a known limit.
  `browser/direct/ControlledHeldStopped` pins the task finding the page stopped (red without the
  `dead` test of `putBackHeld`).
- **`ControlledOptions` with duplicate options**: Chrome shows the two platforms alike — the
  transcript and the value fuzz both pass in Chrome with two options of one value. happy-dom
  reports both options `selected` in a single select, which no browser does; the page keeps its
  distinct values, and the difference is happy-dom's.
- **Small ones**: the size gate takes back the counts of calls inside an `Html.map` that turned
  out to be on the value path (`emit/direct/GateUnderMap`); a `For` rejected after its row was
  walked counted nothing, its row being walked with `in_row` above zero. A group marks the controls
  a write may change inside that write's compare, so a group that writes nothing queues no
  reconcile (`emit/direct/Control`).
- **A branch's value is evaluated once per choice of its arm** (`cx.programBranchChoose`): its
  scrutinee, the `let`s around it and the taken arm's `let`s give `[j, …]`, the arm and what binds
  it, which the arm's instance keeps (`a`) and every group, list, nested branch, listener and
  check of the arm binds from (`programBranchBind`) — the review's H1. Lowering the hole's value
  again in each of them let a scrutinee made on every evaluation choose one arm and then bind
  another's variables (`null[0]`), and an arm `let` that drew show two values
  (`browser/direct/BranchOnce`). A kept arm's `a` is replaced before it is visited, so a keyed
  `Show` visits its body with the new payload. A torn-down arm's listener binds from its own `a`,
  so `held` is gone. The check binds an arm from what the value makes now, not from what it kept.
  An arm's statements run at its mount through `programBranchStatements`, which evaluates the
  hole's value again for them: a known limit, since a scrutinee made on every evaluation may take
  another arm there (the statements then do not run), and one that prints prints again at the
  mount of an arm with statements. A branch whose value is made on every evaluation is chosen again
  by every key, as an every-render group is called.
- **Item 4's arm-level derived values, as built**: an arm `let` its markup reads is computed once
  per choice of the arm, with the branch's value, and kept with the arm (`a`) — not in a slot of
  its own computed by the keys that conflict with its own read set. The branch's facts hold the
  arm's reads, so the `let` is current wherever it is read; a message that writes what the
  branch reads but not the `let` computes it again, which over-calls it (`browser/direct/ArmLetOnce`,
  both platforms on one golden).
- **A `Show`'s arms are its read set too** (`write-sets.md`): a body or fallback that is a value
  was redrawn only where `when`'s reads conflicted, and went stale (`browser/direct/ShowValueArms`).
- **The check evaluates a `Show`'s body and fallback again only when they can neither print nor be
  another value** (the review's M3; `VerifyQuiet` gains a fallback that logs).
- **`same` compares a markup value by its kind** (the review's L5), kept and justified: `same` is
  the verify mode's alone, and a markup value reaches it only inside a derived value or a derived
  list's items, whose values are whole locals a correct page keeps from when it was made; what it
  shows is checked where it is shown, by `verifySlot`.
- **A handler's reads are a markup value's** (`write-sets.md`): a derived `let` holding a button
  was made again only when its text changed, and the button sent the count it was made with
  (`browser/direct/LetMarkupHandler`).
- **`LetChain` stays a hundred `let`s long, measured.** The page's own case costs 2 150, 2 470,
  2 868, 3 272 and 3 761 million instructions at 50, 100, 150, 200 and 250 `let`s, and its value
  fuzz case 3 043, 3 796, 4 742, 5 651 and 6 595 million: both linear, about 8 and 18 million per
  `let`. At 250 the page fits the 4 300 million budget and the value fuzz does not, by half. Which
  to change — a budget the owner grants the case, or a cheaper fuzz build of a page — is the
  owner's; the fixture is not lengthened over the budget (rule 10).
- **`EveryRenderNested` keeps its second draw**, the helper's after the arm's, with a
  `.tea-expected`: the two platforms make the two draws in each other's order, at the mount as on
  each message, and both orders are functions of the model. A finding for the owner: making this
  platform's order `dom`'s would change §4.1 step 3's order of an arm's visit and its site's
  groups. The original's `let` that calls the helper stays out (`ViewLetEffect`).
- **Shapes the binding must hold**: an `else if` chain, `case` arms of nested patterns, literals
  and tuples, and a branch nested in an arm whose handler reads both arms' variables
  (`browser/direct/BranchShapes`).
- **A `view` whose body is an `if` or a `case`** (item 7; `Program.view_branch`): a branch at the
  page's root, with no markup node — the page's one site holds it alone, a body with no template
  and one op, and its arms go at the mount's end. The pass records no read set for a value no hole
  holds, so every key chooses its arm again; its `let`s are bound wherever its arms' values are,
  and one that may have an effect is refused (`build/bad/direct/ViewBranchLetEffect`).
  `browser/direct/ViewBranch` is the page the refusal was; `build/bad/direct/ViewHelperBody` pins
  the one refusal left, a body that calls a helper.
- **Programs** (item 6): `ProgramsByFunction` (two mounts of `counter`, each with its own state),
  `NestedPrograms` and `TwoPrograms`. `NestedPrograms` found a defect: a list's number is its
  program's, so two programs number theirs alike, and the outer list's walk took the inner
  program's row for its own — it ran the inner handler a second time and never reached the outer
  row. A row of the list's number below a mount node between it and the list's parent is now
  another list's (`Direct.mountBetween`), about 100 B raw on a page with a delegated list.
  `browser/tea/MountedPrograms` is not rebuilt: its subject holds a `Tea.element` (S5).
- **Defects** (item 6): `DefectInRender` is rebuilt with its throw in a hole — the original's is a
  statement of `view`, which this platform runs only where the page is made (§8.4) — and
  `DefectInTurnRender` is not, since this platform renders in no turn. New: `DefectInValueHandler`
  (a throw in a kind's handler) and `DefectInDerived` (in a derived value), each stopping the page
  with the crash screen on both platforms. The other `browser/tea/Defect*` pages hold commands
  (S5).
- **The SVG root** (item 6): a `view` whose root is an SVG element other than `<svg>` is parsed in
  the wrapper and taken from inside it (`armTemplate`), and mounted into the mount node it is
  given; `browser/direct/SvgRoot` mounts a `<g>` at an `<svg>` another program renders, and draws in
  both DOMs. A MathML root stays refused, and no page reaches the refusal: no vocabulary declares
  MathML, so the checker refuses the element first.
- **Chrome**: every `browser/direct/` page and its value fuzz pass in Chrome (`zig build
  test-browser -Dchrome=…` with the host's Chrome; the flake's `nix develop .#browser` Chromium
  does not start on this host, a glibc mismatch).

### *Amended 2026-10-13 (ownership enforcement after S4's rebase):* the recursive value path

The ownership checker now refuses `browser-direct`'s `ValuePath`: its recursive `Tree` holds a
list of children, and the checker cannot prove that list unshared where `update` may edit it in
place (`list_may_be_shared`). The direct case is red under
`tests/pending/browser/direct/ValuePath` with the diagnostic code pinned; the same page remains
gated for `browser-tea` under `tests/corpus/browser/tea/ValuePath`. This is a checker limit, not a
verified unsafe edit. `browser/direct/Blocks` pins the other value-path shapes this slice reaches.
`browser/direct/ControlledOptions` copies its options before `List.push`: the old source changed
that list in place and then read it again in the same record update.

### *Amended 2026-10-13 (effects, blocked by ownership checking):* the unchanged driver

The first effects implementation copied `browser-tea`'s command/subscription driver into
`browser-direct/Tea.beni`, as §10.1 specifies. Checking the embedded platform rejected three
appends with `list_may_be_shared`: the `Concurrent` arms of `keyed` and `keyedNow`, and `want`'s
`List.append taps [ t ]`. Each diagnostic explicitly says this is a checker limit, not proof
of sharing. The compiler cannot build while the embedded platform is rejected, so no effectful
constructor can be shipped from that attempt. No `List.copy`, persistent-list substitution or
JavaScript driver was added to make the check pass (CLAUDE.md rule 10).

`tests/pending/browser/direct/SubscriptionTapAppend` isolates `want`: read the old tap list
from a dictionary entry, append one tap, and replace the same entry. Its expected transcript
is the correct result; `tests/pending/RED` pins the direct build's single
`list_may_be_shared`. The identical browser-tea source is gated under
`tests/corpus/browser/tea/SubscriptionTapAppend` against that transcript. The two Concurrent
refusals were observed in the full copied driver; the reduced tap fixture pins the blocker
needed even by a program with no keyed commands.

**Stopped:** `Tea.element`, `Tea.document`, `Tea.application`, subscriptions and after-render
work all need the blocked driver. Owned sends, value-taking/navigation commands and command
policies cannot be exercised through direct until it checks. The TodoMVC effectful parity,
value-fuzz coverage and the byte/timing measurements remain owed. Q5 is already answered by
the owner on 2026-10-09 and implemented by browser-tea's listener path (§10.1); no new owner
choice about subscription fibers is needed. Resuming effects requires fixing the ownership
checker limits rather than changing the specified driver.

### *Amended 2026-10-14 (effects resumed, as specified):* the compiled host

An effectful mount keeps its model and the command driver's state separately. The driver is
`browser-tea`'s beni code, with its scope, keyed jobs, outlets and subscription relays unchanged;
its model field is unit. The compiled handler binds its update result once, installs component 0,
writes the page and title, performs component 1, then settles subscriptions if their anchored
reads conflict with the key's writes. Mount writes the initial page before performing its command
and settling the initial subscriptions. A computed subscriptions function or a capped analysis
reads the whole model. Captures in subscription taggers count as reads, so kept relays receive
the latest tagger when those captures change. An effectful program always has a value dispatcher.

The direct host's `send` enters the page's existing guard, including sends from after-render
work. Its `after` queues work for the dispatch's end. End snapshots the rendered waiters and
work, resumes waiters in order, then runs work in order; messages they send drain before another
end. Work queued outside a dispatch starts an otherwise empty guarded dispatch. Controlled
inputs reconcile before end. `Browser.onRendered` delegates to this phase and `Browser.flush`
stays a no-op. A defect sets dead before shutdown, drops queued work, removes listeners and
closes root scopes using the browser platform's existing deadline and cleanup reporting.

`Tea.document` compiles the `body` of a record returned by its view as markup, and its `title`
as a value against the same model. It writes the title only when the document's title differs.
There is no runtime view call. `Tea.application` additionally calls init with the current URL
and navigation key and combines its declared subscriptions with the two navigation subscriptions,
using the browser platform's existing link interception and navigation errors.

The additive markup interface is version 1.11: `programStart(block, args)` evaluates init once
with explicit arguments (the existing `programInit` remains the unit form);
`programField(block, field, model)` evaluates subscriptions, navigation taggers or title in the
program record's declaration context; `programSettles(key)` answers the subscription conflict.
The existing init and arm results remain the complete declared result, a pair on effectful
constructors. Document body extraction is reflected in the existing view shape/root facts.

### *Amended 2026-10-14 (effects oracle boundaries):* dispatch and render phases

S5 retains the instrumented browser-tea fixtures as phase oracles. Q2 and Q3
make their render-loop instrumentation differ: `FlushLatched` and
`SyncCommandOrder` have mount-time view statements; `FocusInFlush` writes its
hole before the later host listener; `DefectQueuedDropped` can finish a direct
send and its rendered waiter before the next command throws. These fixtures
keep every assertion with explicit `.tea-expected` transcripts, as the existing
S4 phase oracles do. Common command, policy, subscription and navigation
fixtures continue to use one golden and differential value fuzz. The existing paired-page driver ignores renderer comment sentinels, so
adjacent holes keep a common golden and their value fuzz.

A compiled update's incoming model is bound before installing its result, so
closures in that result retain the model they received. Shared dispatch evidence
is scoped to the function that declares it, including sibling compiled handlers;
a reused statement-list stack address is not evidence of a shared scope. The
entry runtime exports `flush` only when the lowering reaches it for its active
host protocol (backend.md §9's optional-runtime-export amendment). Shutdown clears queued messages and after-render work
before closing scopes, so cleanup cannot resume a stopped page.

### *Amended 2026-10-14 (checkbox activation):* change follows click

A checkbox or radio with a declared change handler must retain its native
activation value through the preceding click, so the change handler can read
it. The click capture listener holds its restoration until change or the
fallback task; change marks it before the handler, and the dispatch reconciles
against the model afterwards. A control with no change handler still restores
at click end. This extends S4's controlled restoration contract without changing
its no-handler or cancelled-click guarantees.

### *Amended 2026-10-14 (effects measured, corrected):* size stop withdrawn; full timing verdict

The earlier 9,691 B routing result included unreached command constructors
solely because a foreign mount wrapper's annotation named `Cmd`. Backend §9
now proves inert foreign forwarders generically, without a Tea exception.
Routing is **7,026 B** versus tea's **8,258** (−14.9%); sandbox is **5,344**
versus **6,169** (−13.4%). The size-only stop and the decision to omit the
remaining comparisons are withdrawn. Research 91 and the checked-in raw
results now report both builds, the pinned tastejs vanilla-es6 subject,
feature parity, and all three operations at 100 and 1,000 todos, traced and
untraced in one batch.

The complete result still triggers §13 criterion 6 on timing at 1,000 todos:
sandbox add is 0.365 versus 0.330 ms, sandbox clear 1.385 versus 1.320, and
routing clear 1.465 versus 1.415 (direct versus tea). Traced orderings agree;
the near-tied sandbox toggle is not a win/regression claim. All six
100-todo comparisons improve. Derived filtered lists still invoke the
general reconciler on add and clear, losing the original exact edit; the
editing row keeps its helper/escaping-markup machinery. Routing's runtime
subscription fiber test hook also retains a fiber path in release, explaining
part of the remaining absolute byte-target miss. This is a measured
remaining condition, not the removed constructor-reachability bug. The owner
deferred this timing condition to S8 (§13 criterion 6, amended 2026-10-14),
authorizing S6 and S7 to proceed; the measurements remain recorded above.

Coverage now explicitly builds BikeWars on direct and pins its diagnostics,
restores a real parked-render-waiter cancellation case, and pairs the omitted
`DefectAfterRender`. Empty direct has no flush export (327 B, versus 347
before this correction and master's 316; the remaining 11 B buy queued
sends). RandomValues' exact-sharing diagnostic was a checker bug: approximate
supplies now yield `list_may_be_shared`, with no relaxed ownership verdict.
Sixteen tea pages remain pinned for ownership, including full editing
TodoMVC. The original `DefectInTurnRender` is explicitly pending with its
unchanged throws script: it compiles but its mount-only unused statement
does not repeat after a click, as S4's documented phase contract says. It
is a phase-oracle boundary, not an ownership checker refusal.

### *Amended 2026-10-14 (Conduit ownership resolved):* document helpers remain

The four nested errors-list rejections are precision limits, resolved by the
markup opaque slots and exact constructor callbacks in ownership-checker.md's
dated amendment (research 93). The unchanged application has all 26 ownership
demands accepted and an enforcing corpus case. Reader, Editor and Tour still
cannot run on direct: the document view's branches return helper-computed
documents, and the program hook reports `not_implemented` at Main.beni:257:18.
Their unchanged scripts, sources, goldens and budgets remain pending with that
lowering diagnostic. No source wrapping or copied list bypasses the gap.


### *Amended 2026-10-14 (Conduit validation):* preserve the ownership blocker

The original Conduit application currently fails direct's ownership enforcement:
`Main.update` cannot prove that view-event payloads do not retain the nested
`errors` lists in Article, Home's loaded feed, Profile, and Profile's loaded
feed. The ownership dump marks all four rejections as approximate `payload`,
not demonstrated sharing. The three unchanged Reader, Editor and Tour projects
are exercised under `tests/pending/browser/direct/`, with `list_may_be_shared`
pinned and their original sources, budgets, scripts and browser-tea goldens
preserved. No copied lists or modified application subject bypass this check.

This blocks Conduit's direct transcripts, timed messages, bundle bytes and the
built-platform comparison of S0's dispatch counts; analysis and browser-tea
counts can still be reported, but are not substitutes for those measurements.
Independent paired pages exercise nested message keys, same-variant rebuilding
and an opaque update's `*` path while this checker limit remains open. The S5
timing deferral does not defer ownership or transcript guarantees.

### *Amended 2026-10-14 (document helper branches):* keep the complete arm result

A document view may return a helper-computed document directly or from a branch.
The compiled view binds its model, outer bindings, decision and taken arm in
place; it does not call the view at runtime. A helper-returned document stays
a value: its body uses the existing markup value path, with its own listeners
and the mount's value dispatcher. The complete document is evaluated once per
choice and held in one value slot. Source branch changes do not tear down that
slot: the returned markup kind owns its lifecycle, so another arm returning
the same helper kind retains focus, as it does on browser-tea. Both body and title read that result, including
a same-variant rebuild; writing the title must not call the helpers again.
A document arm is a value computation: its bindings and statements run once
with the value. Outer view statements retain the mount-only rule of §8.4.
The verify check may evaluate a quiet choice again but must not repeat effects.

The additive interface 1.12 exposes `Program.document_branch`: a document
choice is represented by one value arm, `[0, document]`, including a helper
call with no source branch. The lowering reads
its body for the value slot and its title after the page writes. This extends
1.11's document shape facts. Analysis counts remain the independent prediction;
the built value path and visits must be counted against them at criterion 7.
A disagreement is a finding to explain, not permission to alter those counts.

### *Amended 2026-10-14 (Conduit built measurements):* criterion 7 fires

The unchanged Reader, Editor and Tour now run on direct and browser-tea in
development/release against one golden per paired case, with value fuzz.
The document-helper lowering shares each complete helper result between body
and title, and preserves markup-kind identity across source arms. Research 94
records its implementation, validation, raw measurements and remaining Chrome
harness boundary.

The S0 analysis still predicts 96/97 bounded keys, 667 bounded pairs over
106 groups and zero value roots. Actual `patchAll` calls agree: Reader 2/18,
Editor 1/12, Tour 6/32. But a key with no writes, `ClickedLink · Internal`,
enters 5–24 value-kind group comparisons instead of its predicted zero.
A root document choice evaluates shared helpers as values on every handler;
the analysis predicts selective visits to their sites. This is the mechanism
behind criterion 7, which fires. No count or threshold is adjusted to hide it.

Direct Conduit is 32,411 B brotli versus tea's 31,389. Its feed-tab, favorite
and editor-keystroke medians are 0.465/0.435/0.480 ms versus
0.370/0.305/0.420 ms in one rotated Chrome batch; traced orderings agree.
The empty direct page remains 327 B. **S6 stops on criterion 7**; the second
full V3 campaign and slice acceptance remain owed. The focused helper and
nested/opaque-key regressions do not replace that campaign.

### *Amended 2026-10-15 (document-helper review):* shape and synchronous lifetime

A whole-document `case` is distinct from a record whose `body` is a `case`.
The latter retains the existing compiled arm sites; the complete-document
value slot applies only to the former and to a direct document helper call.
Whole-document cases previously failed record-only body extraction.

A helper may run synchronous effects (including logging); helper and arm
statements run once with the chosen value, and the quiet verify check excludes
them. A helper that may suspend is refused transitively by the existing `sync`
view boundary of `Tea.document` and `Tea.application`, before lowering. Body
mount/visit populates or replaces the complete-document slot before title reads
it. A throw unwinds that guarded mount/handler and cannot reach the later title
write. The mismatch measured in research 94 is §4.1 step 3(d) and §5.2's
selective shared-site visit protocol, not permission to broaden the prediction.

### *Amended 2026-10-15 (the owner):* parameterised markup templates and visit verification

A function returning markup does not erase the markup's read information.
Its markup roots compile to **parameterised templates**: a template, its
instance slots and groups, and each group's reads relative to the function's
parameters and captures (`write-sets.md`, the amendment of the same date).
A call supplies values and substitutes their anchored paths for those roots.
The handler selects groups using that substitution and its write set, before
entering a group's value comparisons. Comparing every group and discovering
that nothing changed is not a selective visit.

This rule composes through calls, including imported functions, `let`s and
`case` results. Distinct call sites retain distinct substitutions and instance
storage even when they share one emitted template. A helper in a `For` row
uses that row's instance and the list's edit/selector rules; it does not turn
a changed field of one row into a visit of every helper in the list. A branch
retains its existing liveness and mount-once rule: a newly mounted instance is
initialised, not visited again by the dispatch which mounted it. Reusing a
kind across source arms preserves that instance, but replaces the arguments
and message captures before any later event. A complete document's title and
body still come from one evaluation; synchronous statements retain their
source order and count, and suspension remains a checker error.

An unchanged instance receives no group calls (apart from declared
every-render effects). Changed instances receive only groups whose substituted
reads conflict. Shared code is independent of a caller's substitution: masks
or specialised entry points belong to the call, not to the template globally.
The size gate of §5.2 still decides whether code is shared; no application or
module name participates in that decision.

**A real markup value has an explicit fallback.** Markup stored in the model,
an unresolved function value, a list of markup values without a resolved
producer, and recursive production beyond the finite summary have no precise
producer substitution. They retain kind/identity patching, cost O(groups in
the reached value subtree), plus O(rows) for reconciliation where necessary.
The compiler must identify that boundary and its reason in the direct plan;
it must not report the subtree as precisely compiled. A statically resolved
helper is not such a boundary merely because it returns through a function,
a record, another module, or a `case`. Analysis caps are reported boundaries,
not a licence to silently drop read information.

**Verify the visits, as well as the resulting DOM.** Every development direct
page checks each completed handler separately, including queued handlers and
`*`, before the next handler starts. A visit identity comprises the source
site, call path, group and live instance; two rows or two calls are distinct.
The analysis predicts the visit set from the key's writes and substituted
reads, restricted by the branch and row liveness/edit rules. Mount writes,
selector work, teardown and ordinary event capture refresh are separate from
group visits. Every-render groups are explicitly predicted; a documented
value fallback is predicted as a fallback subtree, with its actual groups
still observed. An undeclared fallback fails verification.

Actual group entry records an observation before the group's value/identity
comparisons. The independent expected walk uses the analysis's read facts
and live instance inventory, not the handler's emitted group-call list or
an observed trace. Missing and extra visits, and duplicate visits of the same
instance/group, are compiler defects. The check must not evaluate user holes,
helpers, selectors or effects again. It is enabled for every direct corpus
page in the gates and its paired value fuzz, without fixture opt-in; release
output contains neither the oracle nor its observations. Synthetic cases
cover composed helpers, rows, choices, distinct call substitutions and the
explicit value fallback. A negative probe must remove and add a group call
and observe both defects, so checking the prediction against itself cannot
pass. Criterion 7 compares these built visits with the analysis unchanged.

*Consumer-plan clarification, 2026-10-15:* a build using parameterised
templates writes `_direct-plan.json` beside its entry. It lists source
sites, precise versus fallback classification and reasons, call-path read
groups and their per-key conflicts. This is a build artifact, not page code
or a UI warning, and is not loaded by the page. Dynamic values therefore
have an inspectable declared cost boundary. Entering an unknown template
path without such a boundary is a verify-mode compiler defect. A library
can publish parameterised templates without knowing its eventual callers.

The independent expected walk retains live template instances across
handlers, not only patch calls that happened. Structural row/branch protocols
publish their eligible instance scopes; they do not derive eligibility from
observed group calls. Newly mounted instances are recorded with the dispatch
which initialised them and excluded from that dispatch's visits. Removed
instances are discarded when their retained DOM boundary is disconnected.

*Unbound placement clarification, 2026-10-15:* markup created outside the
active view walk has no parameter substitution. Its declared fallback is
attached at each placement: the slot's analysis mask decides entry, and an
entered fallback visits every dynamic group of that value. A quiet message
which cannot reach the slot visits none. The build plan states this rule as
well as each source root's classification; a producer may have both bound
and unbound uses. The whole view result's anchored read set similarly gates
root helper or branch entry. This entry fact does not count as a leaf hole
in S0. Debug and effect work preserves its every-render rule.

*Overlapping row traversals found 2026-10-15:* structural reconciliation can
patch a surviving row whole before the same handler's read-set walk reaches
it again. Both see the final model. Their group visits are a union: each
live instance/group executes once per dispatch, including every-render work.
The compiler coalesces those call sites with a dispatch stamp per row group;
it does not remove observations or accept repeated entries in the verifier.
The stamp costs one sparse array cell per emitted group used by that live
instance. New rows still initialise once, outside the visit set.

*Selected entry points, 2026-10-15:* a template's selected groups are cached
as an ordered list of group entry functions per program, call substitution
and message key. Patching invokes that list; it does not scan every group's
identity or mask test on every changed instance. Constructing a selection
costs O(template groups) once per key/substitution. Ordinary patches cost
O(selected groups), plus event-capture refresh when arguments change and
restates of slots that can contain every-render work. Mount initialises all
groups once. A declared dynamic fallback constructs its selection at the
placement and retains its stated O(value groups) cost.

Preparing a changed template also reads its argument vector and maintains
its cached local derivations in source order: O(arguments + local derivation
checks). Those checks compare their own input paths and evaluate a derivation
only when necessary. Group entry functions receive the prepared environment;
they do not close over locals belonging to another emitted function. The
release optimiser removes unused environment reads in each group entry.

*Mapped row ownership, 2026-10-15:* a value-row producer marks only its
returned block as the physical row boundary. `Html.map` preserves that
boundary with a row-scope token before mounting or patching its inner kind;
nested maps inherit the same token. The expected inventory therefore knows
which row is eligible even when an inner helper patch is missing. A kind
switch creates a fresh boundary. No DOM nodes are added. Metadata is attached
only to compiler-owned argument arrays; runtime primitives such as
`Html.text`, whose payload is a string, retain their native representation.

*Entered fallback identity, 2026-10-15:* a conservative `*` key can reach a
stored markup value while preserving that very block object. Once its slot
is selected, a value fallback still enters its groups; block identity selects
patch versus replacement, and does not silently bypass the declared fallback
visit set. This also composes through `Maybe`, markup lists and `Html.map`.
Precise templates continue to select only their substituted reads. Adopting
an unbound block at a value-row boundary retains its unbound classification.

Branch value arms install their own placement mask when adopting stored markup,
just as ordinary value holes do; a computed view root uses the root mask. An
entered fallback also traverses retained slots beneath mount-only producers:
the producer is not evaluated again, but its dynamic descendants receive their
predicted visits even when they have no every-render effects. A quiet placement
enters none of that subtree. `browser/direct/StoredBranchPlacement` pins both
the quiet write and a selected fallback retaining the same block and list.
Such retained-slot operations make the template entry necessary even when
none of its own dynamic groups is selected. Fallback eligibility is computed
once per template patch and restored across nested patches; restating each
retained slot reads that Boolean rather than looking up its fallback again.

*Oracle independence, 2026-10-15:* expected template visits are recomputed
from the immutable analysis masks, never copied from the execution cache's
selection bits or operation lists. A negative probe corrupts only that cache
so an unchanged title group enters: the DOM remains correct, but verification
must reject the extra group. Instances born in this dispatch contribute mount
initialisation, not predicted visits; a second entry is therefore an error.

*Component argument boundary, 2026-10-15:* component props, including markup
children, are evaluated in the caller's substitution, in their existing
field order. Only entry to the component's function extends its call path.
A child helper must retain the same substitution whether passed as a named
prop or written between the component tags. Moving argument evaluation into
the callee's template scope is a lowering defect, detected even on a quiet
message by the independent instance inventory.

*Volatile helper arguments, 2026-10-15:* parameter substitution retains the
analysis's host read `ω` for opaque impure results, such as a clock reading.
A pure helper hole receiving that value is selected on every render, even
when the message writes no model path. This is the same every-render cost
as the equivalent inline expression, and is visible in the consumer plan.

*Fragment children, 2026-10-15:* a fragment passed between component tags is
an outlined template over its enclosing root's input environment. Its own
holes use the caller's read facts and retain their individual selections;
its helper calls extend the caller's path, never the receiving component's.
Kinds and entry functions have names unique to the fragment, even when two
fragments share an enclosing root. Preparing the fragment retains the stated
O(arguments + local derivation checks) cost of that input environment.

*List values and structural precision, 2026-10-15:* a helper called inside a
`List Html` retains its hole's parameter read facts. That list still uses
value reconciliation rather than a `For` row edit plan: O(list values) on an
entered list slot, and O(template groups) to construct a value-root selection
on each patch. The consumer plan declares this list-value fallback even when
individual helper holes have exact masks. `TemplateListValues` pins the paired
behavior, hole selection invariant and fallback classification. This is not
a claim that structural list edits have become precise.

### *As built 2026-10-15:* helper group precision is verified; costs remain

Research 95 records the general parameterised-template lowering and its
composition/fallback fixtures. Every development direct corpus handler now
checks actual group entries against independent analysis masks and live
instances. Missing, duplicate, omitted-child and corrupted-cache probes prove
the oracle rejects disagreements; release omits it.

On the unchanged Conduit scripts, criterion 7 no longer fires: all 62
handler visits match prediction, including zero for all five empty-write
Internal messages. `patchAll` is exactly the nine ChangedUrl dispatches.
The S0 campaign has 96/97 bounded keys, 79 sites, no value roots and 782 leaf
pairs over 114 groups; parameter choice reads explain the increase from
667/106 without broadening message writes. The empty page stays 327 B.

This does not accept S6's performance. Direct release grows from 32,411 to
37,908 B brotli (tea 31,389); in the same fresh Chrome batch its feed-tab,
favorite and editor-input medians are 0.400/0.360/0.380 ms, against old direct
0.380/0.330/0.365 and tea 0.305/0.270/0.340. Context capture, argument preparation,
selection lookup/construction and emitted entry functions add costs outside
the now-correct group visits. Research 95 retains the probes and raw samples.
No timing/size tuning follows the measurement. Prior S0 tripwires and the
second full V3 campaign remain open; focused helper coverage does not replace
that campaign. The PR remains draft and unmerged.

*Review/rebase follow-up, 2026-10-15:* research 95's final batch is on master
`df04ca2db`, with new mixed literal/path, conditional-list, Maybe Html and
volatile-row probes. The latter found and fixed a shared row-effect-fact bug:
the ordinary DOM lowering must receive every-render facts even for ungrouped
rows (backend.md's dated amendment). All helper and Conduit paired Chrome
scripts and value fuzz pass with master's driver fixes.

Criterion 7 remains met on all 62 dispatches; Conduit's 782/114 leaf facts and
9/62 star dispatches are unchanged in the now-102-program S0 series. Final
direct size is 38,030 B brotli, versus old direct 32,411 and tea 31,389. Final
feed/favorite/editor medians are direct 0.395/0.315/0.365 ms, old direct
0.390/0.325/0.340, tea 0.295/0.250/0.315. The report gives min/max and raw
samples: direct before/after spreads overlap; tea is faster in both measured
modes. There is no speed acceptance or threshold change.

Master's new instruction-budget gate now refuses this macOS host. Native and
LLVM unfiltered local test/format steps have only the two known case-folding
failures; the hardware-budget gate is still owed on a suitable x86-64 Linux
host. This supersedes the earlier CPU-fallback validation as a current gate
claim, preserving the historical measurements and diary entries.

### *Measured dispatch and shared update bodies, 2026-10-15*

A value-message dispatcher shares the named constructor prefixes of adjacent
analysis keys. It tests a prefix once before descending to its children;
leaf handler arguments, key order, default priority and the final fallback
remain unchanged. This is a decision tree over the existing analysis, not a
new message classification or a change to group selection.

When an update cannot be specialised to a constructor arm, compile its body
once and call it from the handlers. Do not duplicate its entire decision tree
in every leaf. A specialisable arm remains eligible for in-place lowering.
Neither sharing changes evaluation order, incoming-model capture, commands,
write sets or the visits = prediction invariant. CPU profiles, source columns
and compression accounting must distinguish dispatch, the selected handler,
shared template machinery and host work; sampled native time stays unassigned.

*Shared root selector, 2026-10-15:* the computed root branch's selector is
one function per mounted program, closing over the current model and the
program's derived slots. Each selected handler calls it once at the same
point, inside that handler's template substitution. It returns the existing
arm-and-input array; mount, same-arm patch, title and commands retain their
order. This shares code and V8 compilation, never a computed document or a
previous handler's lexical inputs. Instance-dependent row/arm selectors keep
their existing scope.

*A single key, 2026-10-15:* a one-key program has no update duplication to
share and retains its existing inline update. This also keeps static-page
consumption and the small-program floor unchanged.

*As measured, 2026-10-15:* [research 97](research/97-conduit-dispatch-profiles.md)
finds first-use compilation of repeated unspecialisable update and computed-root
selector bodies behind most of the excess sampled dispatcher time. Sharing
those bodies changes Conduit's feed/favorite/editor medians from
0.425/0.4075/0.450 ms to 0.340/0.340/0.3725 ms on the same machine; tea is
0.3175/0.3475/0.4175 ms, with overlapping IQRs. Raw source falls 361,594 to
209,384 B; as-served brotli falls only 38,030 to 37,768 B, still 6,379 B above
tea. Parameterised template entries, consumer masks and their runtime remain
priced costs. All 62 dispatches match prediction and criterion 7 does not fire.
The complete report-87 sweeps have no slower-side disjoint-IQR before/after
case; this does not discharge their older threshold misses. The Linux hardware
budget gate remains owed; the local native/LLVM suites retain only the two
known macOS case-folding failures.

*Sharing eligibility clarified, 2026-10-15:* multi-key updates stay inline
when their first parameter is a variable and the body cases directly on it,
with constructor arms whose fields are variables, wildcards or unit, and
variable/wildcard defaults. Nested field patterns, tuple/derived scrutinees
and other bodies use the shared update. The model parameter is bound before
arm selection and may be an irrefutable destructuring pattern. Branch guards
are not part of the language. This code-sharing choice does not relax the
per-hole precision rule or introduce a dynamic-markup fallback.

For the computed-root selector specifically, `no_root` has no cached derived
slots: the leading view `let`s are evaluated inside the selector. Its external
bindings are program-scoped, and it is declared before the handler or mount
block requesting it is appended. Debug assertions pin the absence of row,
arm, shared-call and handler-instance contexts. The value dispatcher asserts
one handler per analysis key; only the actual final key is unconditional.
The analysis builds keys depth-first, so a prefix cannot be interleaved with
another prefix or followed by a second root catch-all.
