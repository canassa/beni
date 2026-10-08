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
each item paid for only by a page that reaches it: a twelve-line dispatch guard (defects, re-entrant
sends), the controlled-input edited set, one keyed reconciler, the fiber kernel, and the crash
screen in development. The model stays immutable and updated by spread; a later slice updates it in
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
change it, and in-place update is specified with its proof obligation (§7). **What is different
from today's `browser`**: everything in §3's table whose "today" column says runtime.

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
| **scheduling** | none | — | none: writes happen in the handler (§4.3) | 0 | ~60 B: the dispatch guard (§4.3) | the queue, the microtask, the turn: 1.4 + 0.4 µs **[measured, 59 §1]** |
| **DOM creation** | `innerHTML`, `cloneNode` | compile time | the same | parity **[measured, 60 §4.5]** | the template | the same |
| **DOM update** | `node.data = x` | compile time | the same write, in the handler | the write: ~5 µs cold **[measured, 59 §1.4]** | the write | the same |
| **a row's edit** | `trs[k]`, two `insertBefore` | compile time (which rows) + run time (`k`) | the edit script for the key's edit tag over an instance array (§6.2) | O(1) for an indexed edit; O(n) compares for the `map` idiom; O(n) for a filter | ~40–80 B per edit script **[estimate from P3]** | the keyed pass over every row |
| **a list replaced or permuted** | the author rewrites the rows | run time | one keyed reconciler, shipped only for a list some key replaces or permutes (§6.3) | O(n) | ~450 B once **[estimate from P3's `reconcile`]** | two keyed passes, 1 478 B **[measured, 59 §4.1]** |
| **selection** | `selectedRow` kept, two class writes | compile time (the selector) | the two rows found through the list's key map (§6.4) | O(1) | the key map, ~60 B, only for a list with a selector or a reconciler | the selector, through `forKeyed` |
| **memory** | `data[]`, `trs[]` | — | one module-level slot per group; one instance per row | — | — | the same, plus blocks and kinds |
| **controlled inputs** | nothing: never reconciled | run time (the user's edit) | the edited set of `backend.md` §15.3, reconciled at the end of the dispatch, shipped only when a `stateful` attribute exists (§8.1) | O(touched) | ~250 B when used **[estimate]** | the same, since 2026-10-08 |
| **defects** | an exception reaches the console | run time | the guard: `try … finally` setting `dead`, no `catch` (§8.2); the crash screen in development; `Task.shutdown` when the page reaches `Task` | ≈ 0 **[measured, 59 §1.3: the guards cost nothing]** | ~60 B; the screen in development only | the same |
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
2. **Derived values** (§5.4) whose read sets conflict with `writes(κ)`, recomputed in dependency
   order into their slots.
3. **Structure**: the edit scripts (§6.2) of every list write in `writes(κ)`, then the branches
   (§5.5) whose scrutinee reads conflict — each may make, move or remove nodes.
4. **Values**: the groups (§5.3) whose read sets conflict with `writes(κ)`, in the order of their
   first hole; the row holes an edit script marked.
5. **The after-render point**: the `Dom.rendered` waits and after-render work queued during
   steps 1–4 run here, in order (§10.2).
6. **Effects**: the command of step 1 is handed to the command driver; the subscription diff runs
   if `writes(κ)` conflicts with what `subscriptions` reads (§10.1).

A key whose write set is empty (a command-only message, 18 % of research 61's constructors) is
steps 1 and 6. A key of class `*` (`value ρ`) runs step 3 for every list and step 4 for every
group: **`patchAll`**, one outlined function per program that exists only when some key needs
it (Conduit's `ChangedUrl` does; research 62 §3.1). That is the Elm fallback — compare
everything — kept as the rule `compile-away.md` §2 states: an unknown write set is a cost, never
an error.

**What the handler never does**: decide "unchanged" from the analysis alone. Every group it calls
compares before it writes (`write-sets.md` §9.2); the analysis only chooses which groups to call.

### 4.2 Event delivery

A handler node is an element with an `on…` attribute. The fact "which node, which handler" is in
the template, so:

- **Outside every `For` row**, each handler node gets `addEventListener(name, listener)` at
  mount, where `listener` is an arrow that reads the payload (the event, or the extractor's result
  for a payload-form handler) and calls `send` with the key's handler and the arguments the
  handler expression names — `onClick={Select model.id}` becomes `send(h$Select, model.id)` read
  at the event, not captured. The DOM's own bubbling delivers the event to an ancestor's handler
  node after a descendant's, which is Elm's order; `stopPropagation` declared on the event's row
  calls `e.stopPropagation()`, `preventDefault` likewise. Cost: one listener object per handler
  node, made once; nothing per message beyond the browser's dispatch. A page has tens of such
  nodes, not thousands: the thousands are in rows.
- **Inside a `For` row**, one listener per event name on the list's **parent element** (the
  element whose children the rows are), added at the list's mount, shipped with that list. At an
  event it walks from `e.target` up to the row's root element, calling `send` for each node that
  carries a handler property (`$h`, set at the row's mount, holding the key's handler and reading
  the arguments from the row's instance `$r`, which the row's root carries), innermost first; it
  stops at a node whose declaration says `stopPropagation` and at the row's root, after which the
  DOM's bubbling reaches the direct listeners above. A removed row's walk stops at the detached
  root. This is dom-expressions' delegation restricted to a list (research 58 §4: "delegation
  inside rows" is part of the irreducible runtime), and js-framework-benchmark's own vanilla
  delegates on the `<tbody>` the same way; **S2 measures mount of 1 000 and 10 000 rows with a
  listener per row against it**, and the per-list listener stays unless a listener per row is as
  fast to mount and no larger (§13's `create` criterion), in which case rows get direct
  listeners too and no walk exists anywhere.
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

What the dispatch guard does, and all it does (`send` in `Rt`, twelve lines, ~60 B):

```js
let dead = false, running = false, queue = null;
const send = (h, a, b, c) => {
  if (dead) return;
  if (running) { (queue ??= []).push(h, a, b, c); return; }   // re-entrant: §9.8.4 rule 2
  running = true;
  let ok = false;
  try {
    h(a, b, c);
    while (queue !== null && queue.length > 0) { const q = queue; queue = null; for (…) q[i](q[i+1], …); }
    ok = true;
  } finally {
    running = false;
    if (!ok) dead = true;          // the defect: §8.2
  }
  end();                           // the edited-set reconcile and the after-render point, §8.1, §10.2
};
```

- **Order** (`boundary.md` §9.8.4): messages apply one at a time, in the order of their sends,
  each exactly once; a send made during a dispatch — from a fiber that answers at once, from
  anything `update` calls — is queued and applied when the running handler returns, never
  re-entrantly. The queue is allocated on the first re-entrant send and is `null` otherwise.
- **`end()`** runs once per outermost dispatch: it reconciles the controls the dispatch marked
  (§8.1) and resumes the after-render waits (§10.2). A page with neither has an `end` that does
  nothing, and reachability drops the call under `--release`.
- There is **no `catch`** (CLAUDE.md rule 9): a throw passes through `finally` to the host.

What vanilla does at run time here: nothing. The sixty bytes buy the ordering guarantee and the
defect rule, and research 59 §1.3 found a `try … finally` guard costs no time.

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
`slot`/`place`/`patch` (~200 B, **[estimate]**) only for a program that has such a site, and
`--self-profile` counts them (`markup_value_roots`), so a program that drifts onto it is a number.
Research 61's corpus has one recursive helper (the helper tree sweep) and a few `List Html` holes.

### 5.3 Groups and slots

A **group** is the set of holes of a unique or instanced site that share one anchored read set,
emitted once as a function `g<n>()` (or `g<n>(i)` for an instanced site), in the order of its
first hole. It computes its read values, compares each hole's **leaf value** with the slot holding
what the hole last wrote, and writes on difference — `backend.md` §15.3's table of writes, one row
per hole kind, unchanged. A group of one path whose holes are exactly that path is the one-line
form, `const x = model.name; if (x !== g3) { g3 = x; w3.data = x; }`.

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
source order, since a `let` reads only earlier ones.

### 5.5 Branches and `Show`

A hole whose expression is an `if` or `case` choosing between markups, and a `Show`, is a
**branch**: a slot holding which branch is shown and the nodes it holds, module-level for a unique
site. Each branch's markup is its own template and group code. A handler whose write set
conflicts with the scrutinee's reads (and, for a keyed `Show`, the key's) re-evaluates the
condition: the same branch, and the branch's groups that conflict run; another branch, and the old
nodes are removed, the new branch's template is cloned, mounted (its groups called) and inserted
at the slot's marker. That is `childHtml`'s "same kind, patch; other kind, remount"
(`backend.md` §15.4) decided by emitted code at the one site that needs it, with no block and no
runtime call. A branch whose arms are text only is a text hole with a conditional expression and
no branch at all. The nodes of a branch not shown are not kept: a branch switch remounts, which
is what keeps an input's value from leaking between `then` and `else` (`backend.md` §15.2).

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

The row's groups are the row's holes by read set, as §5.3, with the item as a root (`write-sets.md`
§3.7's εⱼ): a hole reading `row.label` is in the group `[*].label`; one reading
`(model.selected, row.id)` is the **class group**, read by a selector (§6.4). Research 60's
`select` lost 45 % by running the class group on every row; §6.4 keeps the two-row visit.

### 6.2 Edit scripts

For a list write in `writes(κ)` at the `For`'s path, the handler does, by tag:

| tag (`write-sets.md` §2.3) | from | the script | cost |
|---|---|---|---|
| `kept`, `[κ]` with sub-writes | `List.update xs k f`, `set`, an `indexedMap` with index guards | `const i = insts[k]; i.it = a[k];` then the row groups the sub-writes conflict with, on that instance (`[1]` and `[998]` for the table's `SwapRows`: two rows) | O(1) per index |
| `kept`, `[*]` with sub-writes | the `map` idiom, `indexedMap` with a residue guard | the **identity walk**: `for j in 0…n: if (insts[j].it !== a[j]) { insts[j].it = a[j]; …row groups the sub-writes conflict with }` — sound because `map` returns `===` elements where `f` returned its element (`backend.md` §4, *Identity*) | O(n) compares, O(changed) writes; the table's `update every 10th`: 1 000 compares, 100 writes, research 58 §9's 0.8–0.9 ms |
| `append` | `push`, `[ …xs, x ]`, `xs ++ ys` | make the new rows, append in one fragment | O(new) |
| `prepend` | `[ x, …xs ]` | make, insert before the first row | O(new) |
| `clear` | `[]` | `parent.textContent = ""` when the rows are the parent's only children, else remove each; `insts = []` | O(1) or O(n) |
| `insert κ` / `removeAt κ` | `insertAt`, `removeAt` | one make and `insertBefore`; one `remove` and `splice` | O(n) in the array, O(1) in the DOM |
| `swap κ₁ κ₂` | `List.swap` | two `insertBefore`, two array writes — vanilla's six lines | O(1) |
| `removeSome` | `filter`, `take`, `drop`, `pop`, `slice` | the **merge**: walk old instances and new items together by item identity, removing the instances whose item is not next in the new list | O(n) compares, O(removed) DOM |
| `permute`, `replaced`, a cap, `value` at the list from `Fresh` | `sort`, `reverse`, a list from a payload or a builder, an unsummarised call | the keyed reconciler (§6.3) | O(n) |

Every script first tests **whether the list changed**: `List.update` out of range and
`List.swap xs i i` return `xs` itself (`backend.md` §4), so a handler compares the new list with
the old (`!==`, or `same` for views) before it edits, as research 60 §3.2 did; an unchanged list
edits nothing. A positional `For` (`keyed={False}`) uses the same scripts over positions, and
`replaced` becomes the positional pass (patch `min(n, m)` rows, append or remove the rest).

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
- **The renderer reads a list through the protocol** (`length`, `Array.isArray`, `$plain()`), once
  per handler that reads it, into a local `a`; a trie's `$plain()` is computed once per header and
  cached (`backend.md` §4, invariant 1).
- **A `List.update`/`set` on a long list** copies ≤ 256 elements or path-copies a trie; research
  60 §4.3 measured one such call at 0.03 ms cold on 30 000 rows, and that is the price of an
  immutable list until §7.4 writes the slot in place. §13 prices it in the rows criterion.

What the page ships of `List` is what it reaches: a TodoMVC's `map`, `filter` and `append` on a
plain list are a few hundred bytes (research 59 §4.1: `indexedMap` 88, `filter` 82, `append` 188
in context); the trie's write half ships only for a program that pushes, prepends or sets past the
thresholds outside a building loop. That is a finding about `List` for the owner, not a change
asked for: **a program that prepends to a long list outside a loop pays ~500 B for the trie,
and the alternative — a plain copy, O(n) per prepend — is a time cost, not a guarantee.** The
size and speed of `List` for small and large lists are measured in S2 and S3 on both platforms
and reported in `plans/compile-away.md` B1.

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

The root `ρ` of a `Tea.sandbox` whose `update` never returns `model` from inside a message and
never logs it is owned by (1) and (2); the depth page's `child` chain is owned at every level;
the width page's fields are owned; the table app's `rows` is **not** (the rows are instances'
items: `it` is a reference outside the model) while `selected`, `nextId` and `seed` are. For an
owned path the handler emits the assignments and skips the spreads; for a path that is not, the
arm's spreads stay. **Two rules keep the page right**:

- **A group never decides "unchanged" by the identity of an object on an in-place-written path.**
  Slots hold leaf values (§5.3); the identity walk of §6.2 compares items, and an item's path is
  never owned by (2)'s last clause. So in-place writes and identity compares never meet, which is
  the renderer-side blocker research 55's header note named and this design removes by
  construction.
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

The promise is `backend.md` §15.3's, unchanged: after every dispatch, every element with a
`stateful` attribute shows the model's value, though the user changed it and `update` rejected
the change. The mechanism is the **edited set** specified there (the owner's R2 decision), reused
whole: `control(el, prop, v)` writes the property when the page's differs and keeps `v` on the
element; four capture listeners (`input`, `change`, `click`, `reset`) and `pageshow` mark the
controls an edit may have changed; the runtime's own writes mark them too; `end()` (§4.3)
reconciles the marked controls and clears the marks. What changes is only *when*: the reconcile
runs at the end of the outermost dispatch, which is where "the render ends" is on a platform with
no render. The listeners are installed by the first `control` call, so a page with no controlled
element ships none of this (~250 B when used, **[estimate]**), and an unrelated message visits no
control — research 60 §3.3 measured the live-rows page at P2's level with exactly this.

### 8.2 Defects

A **defect** is a throw that escapes a handler, a group, a script, a listener or the mount.
`send`'s `finally` sets `dead` (§4.3), after which every `send` returns at once; the throw goes on
to the host unchanged and is reported as an uncaught exception; in a development build an `error`
listener installed at `run` shows the crash screen; and when the page reaches `core/Task`, the
stop calls `Task.shutdown`, whose teardown — every finaliser once, every host resource released,
no other program code run — is `boundary.md` §9.8.14, unchanged and shared with today's
platform. No `catch` anywhere (rule 9). A page that reaches no `Task` ships none of the teardown.
Cost: the guard, measured free (research 59 §1.3); the screen, development only.

### 8.3 The page is a function of the model

This is the guarantee the analysis stands in for, and it is kept by two things: `write-sets.md`
§1.3's soundness (every changed path is covered by the key's write set, so every hole that reads
it is in a group the handler calls) and the comparison in every group (a covered hole whose value
did not change is not written). It is **tested** by the differential harness (§12.3): every
`browser/` fixture is built for both platforms and the transcripts must be equal after every step,
and V3's adversarial campaign (`compile-away.md` §4) attacks it directly.

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
DOM's bubbling, as `tests/corpus/browser/tea/TwoPrograms` pins. One `send` guard serves the page:
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
view: TodoMVC's one routing subscription pulled 1 948 B of fiber kernel. This document does not
change the fiber runtime (its bar is Effect v4 parity, `plans/effects-plan.md`); it notes for the
owner that `boundary.md` §9.8.11's rule — a command that cannot wait runs with no fiber — has no
twin for subscriptions, and that the twin would take the routing subscription off the kernel
(Q5, §15).

### 10.2 The after-render point

`Dom.rendered`, after-render work (`Hosted.afterRender`, focus after a render) and
`Browser.flush` were defined against a render loop. On this platform: the after-render point of a
dispatch is `end()` (§4.3), after every write of the handler and of the sends it queued, where the
waits resume in order and the after-render work runs; a message such work sends is a new
dispatch. **`Browser.flush` is a no-op** — there is nothing queued to flush; it stays in the API
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
the spread, the trie), never an error (rule 7). Each is dumped: `beni dump --stage=writes` gains
a `site` line per root (`unique`/`instanced`/`value`), a `carriers` line, and in S7 an `owned`
list, so a coarse answer has a stated cause.

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
recognises as a program site) evaluates to. **A program record the pass does not recognise**
(`update = withLogging update`; a record a helper builds) has no key tree and cannot be compiled
by this lowering; the build is refused with `program_not_compiled`, naming the shape the lowering
needs and the `browser-tea` platform that accepts any shape (Q1, §15).

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
same comparison for the bench pages. `emit/direct/` and `emit/release/direct/` pin shapes:
that a handler is one compare and one write, that a page has no reconciler, that a static hole
is text.

## 13. Targets and kill criteria

Research 58 §9's criteria are the owner's bar and are kept as written in
`plans/compile-away.md` §1; they judge the whole output, model included. This section says what
this design expects against them, per page class, in vanilla multiples, untraced real clicks.

| page class | speed, expected landing | bytes, expected landing | criterion met? |
|---|---|---|---|
| **empty page** (`bench/size.mjs` `page`) | — | ≤ 300 B brotli; today 1 234 | — |
| **static-heavy** (holes 10 / 10 000, width ≤ 256, helper rows, helper tree) | ≤ 1.15× (P3: 1.18 / 1.04 with a flush this design drops; the floor is the one DOM write) | holes: the HTML + ≤ 300 B at any N (P3: 394 / 442); 0 B per static hole | **yes** |
| **width 1 024** | ≤ 1.3× until S7, then ≤ 1.15×; before S7 V8's dictionary cliff stays (research 59 §2) | ≤ 2 B per field | after S7 |
| **depth 128** | ≤ 1.3× until S7 (P3: 1.29), then ≤ 1.15× | ≤ 4 B per level | after S7 |
| **long keyed list, one edit** (rows 30 000) | ≤ 1.3× until S7 (P3: 1.31, 0.03 ms of it `List.update` on a trie), then ≤ 1.15× | ~1.5 kB (P3: 1 643) | **yes** at 1.3; 1.15 after S7 |
| **swap** (rows 30 000) | ≤ 1.0× (P3: 0.98) | the same page | **yes** |
| **live rows 10 000** | ≤ 1.15× (P3: 1.25 at a 5 µs clock, with the flush) | ≤ 1.1 kB | expected, at the clock's edge |
| **derived 100 000** | flat, ≤ 1.15× | ≤ 1 kB | **yes** |
| **bursts K ≥ 30, stream** | ≤ 1.0× vanilla (vanilla writes K times too); K = 1–10 ≤ 1.15× | — | **yes**; gives up the 13 % at K = 1 000 |
| **the table app** | every operation ≤ 1.2×; `select` ≤ 1.0× (the selector kept); `swap` ≤ 1.2× with the exact edit from `List.swap` or the index guards (`write-sets.md` §10.4) | ≤ 2× vanilla = 2 830 B: P3's own module 2 243 + core after §7.2's building loop ≈ 400 → **≈ 2 650 [estimate]** | **expected, with little room**: the bytes criterion is the one most likely to miss, by core's `List` |
| **TodoMVC** | the three messages ≤ 1.2× vanilla TodoMVC | ≤ 2× vanilla TodoMVC, and below Svelte 4's 4 246 (today 5 317 sandbox, 10 053 with routing) | expected: one reconciler (its `For` is over a filtered list), no dispatcher in the sandbox, no kinds, blocks or slots |
| **Conduit** | every key's handler bounded but `ChangedUrl`; a page message ≤ the frame's one DOM write + the page's groups | ≤ 0.7× today's 30 842 brotli | expected on keys; bytes depend on the fiber kernel's share |

**Which of research 58's criteria this design expects to miss, and why.** None on speed, with
the width and depth and long-list points reaching 1.15× only at S7 (in-place), which research 58
itself ordered last. On bytes, the table app at ≤ 2× is expected to land within about a hundred
bytes either side of the line: the renderer's share is under the bound (research 60 §4.6) and the
rest is core's `List`, which §7.2's building loop cuts but does not remove (`append`, `get`,
`indexedMap`, `filter` stay). If it misses by core alone, that is reported as a finding on `List`
for the owner and not restated (rule 10, and `compile-away.md` §6).

**Kill criteria, so the design fails early and not as "P3 again"**, checked at the slice named:

1. **S0**: the empty mounted page is over 500 B brotli, or imports anything of `Rt` but `send`
   and `run` — the design is carrying a runtime it did not justify.
2. **S1**: the holes handler is not one compare and one write (`emit/direct/`), or holes 10 000
   is over 1.15× untraced, or the page grows with N by more than the HTML — the handler path is
   not direct.
3. **S2**: the rows edit is over 1.3× or the swap over 1.0×, or the bundle holds the reconciler
   for a page whose keys are all exact — edit scripts are not being read off the write set.
4. **S3**: any table operation over 1.2× or `select` over 1.0×, or bytes over 2× by more than
   core's measured share — the Million failure (a win on the sweeps and not on the app).
5. **S5**: TodoMVC's bytes or its three messages do not improve on today's platform — the win was
   constancy, which TodoMVC has none of (research 61), and the architecture buys nothing on a
   list-heavy app whose `For` reaches the reconciler on every list message: the Million failure
   again, seen from the other side.
6. **S6**: fewer than two thirds of Conduit's keys bounded (the write-set gate), or the share of
   dispatches that call `patchAll` on the three scripts above 10 % — the Imba failure, O(view)
   per event in disguise.
7. **At every slice**: a transcript that differs between the two platforms, or a V3 program that
   shows something its model does not hold — the Svelte 3 failure, a stale screen from analysis.
   A single one is a defect with a red-first fixture, and a rule corrected in `write-sets.md`.

## 14. The build order

Smallest first, each slice useful on its own, specified before it is built (the interface
additions in `boundary.md` §9.4.6, the backend rules in `backend.md`), red-first fixtures, and
measured on both platforms, P3, vanilla and Solid 1 in one batch. The slices are
`plans/compile-away.md` §7's, where their state is kept; this is what each contains and proves.

- **S0 — the platform and the harness.** `platforms/browser-direct/` registered in `build.zig`
  with the `direct` lowering and `Rt`; the program hook (§11.1); `Tea.sandbox` with a `view` of
  static markup only; `run`, `mountAt`, `programs`; the `send` guard; `emit/direct/Hello`,
  `browser/direct/Hello` built both ways; the harness subjects and `bench/size.mjs`'s page line.
  **Proves**: a program can be lowered as a whole through the interface; the floor is ≤ 300 B;
  the two platforms can be measured side by side. *Kill criterion 1.*
- **S1 — holes.** Text and attribute holes, constancy and baking (§5.1), per-key handlers with
  direct writes and direct listeners (§4.1–§4.3), groups and slots (§5.3), the holes, width,
  burst and stream sweeps, `browser/dom/Holes`, `ConstantWriteOnce`, `GroupedReads`,
  `TrustedTurn` (re-stated for direct writes), `DefectInHandler`. *Kill criterion 2.*
- **S2 — rows.** `For` keyed and positional, row templates, instances, static-key holes, the
  exact edit scripts (`set`/`update κ`, swap, append, prepend, clear, insert, remove), the
  delegated list listener and its mount measurement against a listener per row (§4.2), the rows
  sweep, `browser/dom/Keyed`, `KeyedInPlace`, `RowItemOnly`, `RowMountOrder`, `ForAtEnds`,
  `ForForms`. *Kill criterion 3.*
- **S3 — the table app.** The reconciler (§6.3) for `replaced`/`permute`, the identity walk and
  the filter merge, the selector and key map (§6.4), helper inlining and constant calls (§9.2),
  the building-loop rule (§7.2, in the backend, both platforms), `Html.map` static composition
  (§9.1), the dispatcher for carriers (§4.4); the table benchmark and B1's part-by-part bytes on
  both platforms; `browser/dom/KeyedEnds`, `KeyedMoves`, `KeyedReplace`, `Selector`,
  `HelperSkip`, `NullaryHelperSkip`, `tea/Counters`, `LatestTagger`. *Kill criterion 4.*
- **S4 — guarantees and the rest of rendering.** Controlled inputs by the edited set (§8.1),
  defects, the crash screen and the teardown (§8.2), branches and `Show` (§5.5), derived values
  (§5.4), nested updates (§7.3), the value path for recursive helpers and `List Html` holes
  (§5.2), two programs on a page (§9.3); the live, derived, depth, helper-rows and helper-tree
  sweeps; every `browser/dom/Controlled*`, `Defect*`, `Blocks`, `ShowAndBranches`,
  `LetInMarkup`, `LetOneOwner`, `EveryRender*`, `TwoPrograms`, `MountedPrograms`. The first V3
  campaign runs after it.
- **S5 — effects and TodoMVC.** `Tea.element`, `document`, `application`; the command driver
  copied and driven by handlers, subscriptions diffed by write set (§10.1), the after-render
  point and `flush`'s no-op (§10.2), messages from fibers through the dispatcher; every
  `browser/tea/` fixture; `bench/todomvc/` with its vanilla subject, parity and size. *Kill
  criterion 5.*
- **S6 — Conduit.** Nested keys and same-variant rebuilds through the handlers, `patchAll` for
  the `*` key, the three Conduit scripts on both platforms, bytes and the three timed messages;
  the second V3 campaign. *Kill criterion 6.*
- **S7 — in-place update.** The ownership analysis (§7.4, §11 item 4), the assignments in the
  handlers, the width, depth and rows criteria at 1.15×, `backend.md` §15.8's identity fixtures
  extended with the two rules of §7.4; the owner's W27 amendment (Q4) taken before it starts.
- **S8 — the decision.** One batch of everything on both platforms, P3, vanilla and Solid 1,
  one report, and the owner keeps one platform; the other's lowering, runtime and `Tea` are
  deleted, and the survivor's name is the owner's.

Slices S1–S3 are the first three; after S3 the design has either reached the table app's targets
or shown which piece cannot, before any guarantee machinery is built on it.

## 15. Open questions for the owner

Only those that change what developers can write, a guarantee, or a prior decision. Internal
parameters are decided above (the thresholds, the caps, the outlining rule, the delegated list
listener) and their limits are in plain words in §16.

- **Q1 — A program shape the compiler cannot compile is refused on this platform.** A program
  record that is not a literal with `init`, `update` and `view` as plain functions
  (`write-sets.md` §1.1: `update = withLogging update`, a record a helper returns) has no key
  tree, and this lowering has no `view` to run instead. Today's platform accepts any shape.
  *Recommendation*: refuse with `program_not_compiled`, naming the shape and pointing at
  `browser-tea`, through S8; count how often it fires; add a generic fallback (the whole view as
  one `*` group through the value path) only if a real program needs it. No guarantee is at
  stake — it is a capability gap on one platform while two exist — and the alternative, carrying
  today's whole runtime in this platform for the rare shape, is what the rewrite exists to avoid.
- **Q2 — Direct writes replace the render loop.** W28 chose Solid 2's microtask flush; research
  56's A moved the render to the end of a trusted dispatch; both batch K messages in one task
  into one render. This design writes in the handler and renders nothing (§4.3): K messages are K
  writes, as in vanilla. *Recommendation*: take it. Nothing a program can observe changes (DOM
  reads happen only through `Dom` after a dispatch), the burst win was 13 % at K = 1 000 and a
  cost at K = 1, and the stream criterion keeps the page at or under vanilla.
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
  take TodoMVC's routing subscription off the fiber kernel (research 51 §0.2: 1 948 B). It is a
  guarantee-adjacent change to the effects contract, so it is the owner's. *Recommendation*: yes,
  specified in `boundary.md` §9.8.5 before S5.
- **Q6 — TEA is this platform's architecture, not a layer on it.** `boundary.md` §9.1 makes an
  architecture a platform layered on a base `Program`; here the architecture is what the
  compiler compiles, so there is no low-level `Program` another architecture could be written
  over without its own program lowering. *Recommendation*: accept for `browser-direct`; `browser`
  stays the base for a library-style architecture while both exist, and S8 decides.

**Reported, not asked** (rule 10): `List`'s thresholds and the trie's ~500 B for a program that
prepends to a long list outside a loop (§7.2) are measured in S2/S3 and reported in B1; nothing
here changes them.

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
- **A program whose `init`/`update`/`view` are not plain functions in one record** is refused on
  this platform (Q1) and builds on `browser-tea`.

*Amendments go below this line, dated, without renumbering.*
