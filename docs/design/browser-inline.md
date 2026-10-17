# `browser-inline` — the analysis rules and the error taxonomy

*2026-10-17. The normative part of the second direct platform, `browser-inline`, which the owner
ordered built from its output (`plans/direct-rewrite.md`). **The output is the specification**:
what a program compiles to is pinned by goldens taken from tea-inline
(`../reactivity-research/frameworks/tea-inline/`), under `tests/corpus/emit/inline/`,
`emit/release/inline/`, `build/bad/inline/` and `browser/inline/`, and this document holds only
what a golden cannot show — which facts the lowering takes from which analysis, and which programs
it refuses, with what. It grows one section per slice; section numbers are never renumbered
(CLAUDE.md rule 2), and a later change is a dated amendment in place.*

## 1. The platform

`platforms/browser-inline/` depends on `html` alone. It imports nothing of `browser`'s, of
`browser-tea`'s or of `browser-direct`'s — no `Rt`, no `Hosted`, no driver, no `core/Task`, no
`core/Dict` — and its runtime, `Inline.beni`, is beni over `Js`. Its markup lowering is `inline`
(`platforms/browser-inline/zig/`), a program lowering (`boundary.md` §9.4.6, version 1.6 on): a
program is compiled whole where its constructor is called, and there is no run-time renderer to
fall back on.

| Module | What a program may use |
|---|---|
| `Browser` | `Program`, `mountAt` |
| `Tea` | `Program`, `sandbox`, `element` — `browser-tea`'s signatures, so one source builds on both |
| `Cmd` | `Cmd`, `none`, `batch`, `perform` |
| `Sub` | `Sub`, `none`, `batch`, `map`, `on` — `browser`'s signatures; there is no `listen` |
| `Listen` | `on`, a listener on the window or the document |
| `Html` | `html`'s vocabulary, re-exported |

One program per page: `Browser.mountAt p id` mounts it at the element `id` names, and a program
not placed mounts at `document.body`. The runtime exports `run` and `stop` (`boundary.md` §9.4.5,
amended 2026-10-17).

## 2. What the lowering takes, and from where

The lowering re-derives nothing. Every fact below is an analysis's, through the markup lowering
interface:

| Fact | Analysis | Interface |
|---|---|---|
| the message keys, each key's arm, which bindings each key's writes reach | the write-set pass (`write-sets.md`) | `programKeys`, `programArm`, `programCalls`, `programHole` |
| what the subscription set is | the write-set pass, evaluating `subscriptions ρ` (§3) | `programSubscriptions` (version 1.14) |
| what each key's command is, and `init`'s | the write-set pass, evaluating the arm's result (§4) | `programCommand` (version 1.14) |
| whether a command's body may suspend | the checker's effect inference (`checker-v2.md` §26) | `programCommand` |
| whether a list is edited in place safely | the ownership checker, through the manifest's `"lists": "in-place"` | — (its refusals are its own) |

## 3. Subscriptions

The pass evaluates `subscriptions` applied to the model's root ρ, walking the platform layer's
functions (`Push.onPush`, `Interval.every`) as it walks the program's, and recognising the four
values of `Sub` by name. The set is the **flat list of `Sub.on` declarations** the value is made
of, in order: `batch` concatenates, `map` composes its function onto each declaration's tagger,
`none` is no declaration.

- **The set must not depend on the model.** A value whose shape, or any declaration's key, reads
  ρ is refused (§5, class 3): a set that changes needs the subscription diff, which is slice S4's.
- **A key is a constant**: a literal or a constructor of constants, whatever the module it is
  written in. Two declarations with equal keys are **one resource**, merged at compile time: the
  first one's `start` runs once, and each value it sends goes through every declaration's tagger,
  in declaration order (`boundary.md` §9.8.5's rule, decided when the program is built).
- **A tagger resolves to a key.** Applied to a fresh payload π, the tagger must give a constructor
  of the message type each field of which is π itself. Its key is the leaf of the program's key
  tree whose steps that message satisfies: a step naming the constructor, a default step whose
  constructors include it, or no step at all (a message type `update` does not split, one of one
  constructor among them). The value the start sends then calls that key's handler directly — no
  message is made. A tagger that gives no constructor of the message type is refused (§5, class
  3); one whose key splits further, on the payload's own shape, is a limit of the compiler (§5,
  class 4), since only the handler could tell.
- **`start` must not suspend**: `Sub.on`'s `start` is `sync`, so the checker refuses one that
  does, before the lowering sees it.

Each declaration compiles to the start applied to a send that enters the dispatch guard with the
key's handler; what it returns, the remover, is one of the program's disposers (`stop`).

## 4. Commands

The pass evaluates each key's arm — and `init` — to its `model × Cmd msg` result and reads the
command half, recognising `Cmd.none`, `Cmd.batch` and `Cmd.perform` by name:

- `Cmd.none`, and a `batch` of nothing but `none`, is **none**: the handler writes no code for it;
- a `perform` whose body cannot suspend, by the checker's answer at that call, **runs**: after the
  handler's write pass, in the same dispatch, through the guard's queue (`boundary.md` §9.8.4,
  amended 2026-10-17);
- a body that may suspend is refused (§5, class 2);
- a command the pass cannot read as one of these is refused (§5, class 4).

## 5. What the lowering refuses

Strict, not coarse: what the lowering cannot compile exactly is a build error, `not_implemented`,
at the program's call or at the construct, and never a fallback. Each message says which class it
is, what the cause is, and what to write instead. There are four classes, of two kinds.

*Amended 2026-10-17, the owner's refusal taxonomy.* **Compiler limits** — classes 1, 2 and 4 — are
temporary: every such message begins *"A limit of the compiler"*, may say *"yet"*, and is closed by
the slice in its area (a suspending command, a set of subscriptions that changes, `lazy`, an
analysis cap). **Language rules** — class 3 — are permanent departures from Elm, and their text
never says *"not yet"*: an opaque `update` or `view`, a tagger that gives no message constructor, a
markup site that cannot be numbered, a `*` key that is not a declared `replace`, and, from S2, a
structural write to a `List` of rows, whose error names `Dict.update`: **`Dict` is the keyed
collection** (#294). The messages keep the split between an idiom to write instead, a value meant
to be global, and a cap of the compiler.

1. **Not compiled yet** (a compiler limit) — a construct a later slice of
   `plans/direct-rewrite.md` §5 adds (S1: events and holes beyond the one text binding; S2:
   `For`; S3: a `view`'s `let`s; S4: a set of subscriptions that changes — moved here from class 3
   on 2026-10-17 — `Show`, branches; S6: the task kernel). The message says *"A limit of the
   compiler: … does not compile … yet"* and what to write instead; it names no slice and no
   plan, which are this document's and not the user's.
   *Amended 2026-10-17 (the owner's D-b and D-d, S1's design pass):* an `if` whose other arm is
   `<></>` is S1's, an eager `when` (§8.2), and no longer S4's, which keeps a branch of any other
   shape and `Show`; a `view`'s `let` read by one hole is S1's, substituted into the hole, and one
   read by several holes stays S3's.
2. **Needs the task kernel** (a compiler limit) — a command whose body may suspend: *"A limit of
   the compiler: … needs the task kernel, which `browser-inline` does not have yet"*, with the
   body's position. The kernel returns behind reachability in S6.
3. **The program's shape** (a language rule) — what the platform's model does not express, with
   what to write instead: a program record or `view` computed when the page runs, a tagger that
   gives no message constructor of the program (*"… tag the value with a constructor of the
   message that takes it …"*). A tagger that gives a constructor whose key the analysis splits on the
   payload's own shape (`Pushed (Box v)` with `update` matching on `Box`) is class 4, not 3:
   the program is valid.
4. **A limit of the compiler** — a fact the analysis did not give, or code the compiler cannot
   write where the lowering needs it. The message says *"a limit of the compiler"*, so it is never
   read as a rule of the language, and names what would lift it.

## 6. The release ledger (`plans/direct-rewrite.md` §8, as the owner decided for S0)

- **The dispatch guard and the mid-dispatch send queue are kept** on every page: a defect stops the
  page (`try … finally`, no `catch`), and a send made while a dispatch runs is queued.
- **The mount fault is development's.** A development build marks the mount node (`$$root`) and
  throws *"cannot mount at …"* for a node that is missing or already holds a program. A release
  build ships neither; a missing node still fails **inside the dispatch guard**, so the page stops
  as for any defect, without prose, and no `TypeError` escapes the entry unguarded.
- **No message object, no `switch` and no error prose in release** for what S0 compiles: a key's
  handler is called directly. A pushed value decoded with `Schema.read` whose `Err` payload is
  never read is a validator (`schema.md` §6, amended 2026-10-17), built for `read`: it makes no
  issue and ships no prose. The decoder's own tag test is still a `switch` over the literal tags
  (`schema.md` §6's table), which the golden shows.

## 7. Lifted pieces: another module's code at the program site

*Added 2026-10-17, the owner's decision (option 2 of the S0 report's wall).* A program site — the
mount and the handlers the lowering writes in the module that calls the program's constructor —
needs code that is written in other modules: a subscription's start is a lambda inside a layer's
`Push.onPush`, which calls that module's private `detail`. The compiler lowers each module on its
own, in parallel, so the program module cannot write that code itself.

**The mechanism.** Each module lowers its own pieces, as exported top-level functions, and the
program site calls them.

- **Which pieces.** The write-set pass, which already runs over every module, serially and
  deterministically, before the modules are lowered, says which: for S0, every subscription start
  that is a lambda (§3). The set is general: S1's per-key arms of `update` are pieces of the same
  kind.
- **What a piece is.** `<Module>$<declaration>$$lift$<n>`: the lambda, lowered in its own module
  where its declaration's other code is, as a function of the locals of that declaration it reads
  (its captures), whose value is the lambda; a piece with no captures is the lambda itself. `n` is
  how many lambda instructions of its declaration come before it in `Bir`'s order, which writes an
  expression's operands before it — post-order, so a lambda nested in another counts before the
  one around it: the name never names an instruction index, so it does not move when other code
  of the module does (CLAUDE.md rule 5).
- **What the program site knows of it.** Its name and its captures, in order — never its body. The
  program module still lowers in parallel with the others. At the program site each capture is the
  value the pass found for it, which must be a literal (`Interval.every 1000` captures `1000`);
  a piece that captures anything the program site cannot write is refused as a limit of the
  compiler (§5, class 4).
- **Reachability.** A piece is a node of its own (`backend.md` §9): reached from the program call
  that uses it, and reaching what its own instructions name. The value a program record's
  `subscriptions` field names is not reached through the record, since the program site never
  evaluates it, so a layer's `onPush` and `Sub.on` ship only if something else uses them.
- **In release**, the release optimiser fuses a piece used once into its listener where its rules
  allow; a development build shows each piece as a call, which is accepted.

*Amended 2026-10-17 (S1, #297):* the pieces are of three kinds, each named by its declaration and
an ordinal as above: a lifted lambda, `<Module>$<declaration>$$lift$<n>`; an **arm piece**,
`<Module>$<declaration>$$arm$<n>`, one branch of a `case` at which the key tree splits a message;
and the **view pieces** of a markup root another module's program uses, its HTML string
`<Module>$<declaration>$$html$<n>` and its binding functions `<Module>$<declaration>$$bind$<n>`
(§8.4). The program site knows an arm piece by its name and parameters and a view piece by the
facts `programPiece` gives (§8.4), never by its body.

**Rejected: writing the other module's code at the program site** (option 1). It specialises code
per program instance, the first platform's cause 3 (`plans/direct-rewrite.md` §1), and it makes a
module's output depend on another module's body at every use, which incremental lowering cannot
cache by module (`fast-compiler.md` §8.1, amended the same day).

## 8. Holes, handlers and pieces (S1)

*Added 2026-10-17, slice S1 (#297), the owner's decisions of the same day (`plans/inline-s1-brief.md`
§1). It holds what S1's goldens cannot show: which facts the lowering reads, how it names and
places what it writes, and what it refuses. The goldens are `emit/release/inline/` and
`browser/inline/` (`CounterLocal`, `FormLocal`, `Counter/`, `Texts/`, `Reader/`, `ResearchS2/`,
`ResearchS3/`), the refusals `build/bad/inline/`. S1 lands in several pull requests: §8.2–§8.3
first, in one module; §8.4–§8.6 after.*

### 8.1 What the lowering takes

§2's table, extended. Every row is an analysis's answer; the lowering re-derives none of them.

| Fact | Analysis | Interface |
|---|---|---|
| each hole's and attribute's read set, as a group, and whether `init` bakes it | the write-set pass's view walk, per call path (`write-sets.md`, *a hole's facts per call*) | `programHole` |
| which groups a key's writes reach | the same pass, §2.5's conflict | `programCalls`, `programGroupsOf` (1.15) |
| a `case` the key tree splits a message at, and each branch's arm piece | the key tree (`write-sets.md` §4.4, amended 2026-10-17: *split sites*) | `Program.Key`, `programArm` |
| which branch of an `if` a hole shows, and whether its arm can be evaluated eagerly | the lowerer's branch reading (`boundary.md` §9.4.6, 1.10) | `programBranch`, `Program.Arm.eager` (1.15) |
| another module's `view` as pieces: their names, groups, elements and events | the pieces pre-pass (§8.4) | `Program.Callee.piece`, `programPiece` (1.15) |
| what each tail of a key's arm writes | the write-set pass's per-path sets (`write-sets.md`, amended 2026-10-17) | `programArmTails`, `programCallsAt` (1.15) |

### 8.2 The page

**One HTML string per unit** — the program's `view`, or a piece's root (§8.4) — written into the
mount once, with `insertAdjacentHTML`. It holds every element of the unit, the elements of an eager
`when`'s arm included, every constant attribute and every text that never changes: a constant, or
a hole `init` bakes (`write-sets.md` §9.1). Attribute values are left unquoted where HTML reads them
back unquoted (no space, quote, `=`, `<`, `>` or backtick), and an empty value is the attribute's
bare name. An end tag HTML makes optional is left out only where the standard's tree builder
(§13.2.6) closes the element there exactly as the end tag would (*corrected 2026-10-17, the review
of S1's first pull request*: the first text left `</p>` out at the end of almost any parent, and an
`</em>` or a `</label>` does not close a `<p>`, so the parser rebuilt the tree):
- before a next sibling whose start tag closes it: `</li>` before an `<li>`, `</dt>` and `</dd>`
  before either, `</option>` before an `<option>`, an `<optgroup>` or an `<hr>`, `</optgroup>`
  before an `<optgroup>` or an `<hr>`, a cell's before a cell, `</tr>` before a row, `</thead>`
  and `</tbody>` before a row group, and `</p>` before the block elements whose start tag closes a
  `<p>` in button scope — not `<table>`, which does only outside quirks mode, nor `<form>`;
- at its parent's end only where the parent's end tag generates implied end tags (`div`, `section`,
  `ul`, `li`, `dd`, `button`, `h1`–`h6`, `td` and the rest of the standard's list), or a `<select>`
  or `<optgroup>` closes an `<option>`, a row a cell, a row group a row. A `<span>`, a `<label>`, a
  formatting element and a custom element close none of them.

The run of end tags at the very end of a string parsed alone is left out too, which the parser
closes at the end of its input. A string that is concatenated with another keeps its own closing
run.

**Elements by document order.** An element some code refers to is `E[n]`, the `n`-th descendant of
the unit's top element in document order (`top.querySelectorAll("*")`, read once at the mount, and
only when some code refers to a descendant); the top element is the unit's node itself. There is
no marker attribute and no walk. *Amended 2026-10-17:* when code refers to one descendant only, it is
reached by its path of `firstChild` and `childNodes[i]` from the top node, which costs less than
the list; and a page whose one text write is its only use of `text` writes it in place, so `text`
does not ship (S0's pinned 589 B for `PushAndTimer` holds: 583 B).

**A binding** is one write guarded by a compare, through the runtime's four functions, which are
beni over `Js` in `Inline.beni`:

| Function | What it writes |
|---|---|
| `text(node, value)` | `node.textContent`, `String(value)`, when it differs |
| `prop(node, value, key = "value")` | the DOM property `key` when it differs: a control's `value`, `checked`, `selected`, and the boolean attributes whose property has their name (`disabled`, `hidden`, `multiple`, `open`, `required`) |
| `when(node, hidden)` | the node, or the empty text node it keeps in its place while `hidden` |
| `on(node, f, type = "click")` | a listener of `type` whose event enters the dispatch guard with `f` |

- **A text hole** is `text` on its element. An element whose children are texts and text holes —
  *mixed text* — is one binding writing its whole text as a template. A hole of `String`, `Char` or
  a number only; a text hole beside an element is a limit of the compiler (§8.7).
- **An attribute** whose value changes is `prop`; a constant one, and one `init` bakes, is in the
  markup. An attribute that is not a DOM property and whose value changes, a URL, raw HTML, and a
  class or style list that changes are limits of the compiler.
- **An eager `when`** (the owner's D-b) is an `html` hole whose value is an `if` — a `case` of two
  arms — one arm of which is one element written in place and the other `<></>`, and whose markup
  arm reads no variable the branch binds (`Program.Arm.eager`): the arm's element is in the markup
  and its holes are bindings like any other, evaluated whichever arm the value takes; `when` hides it
  while the value takes the other arm. A branch of any other shape is S4's (§5, class 1).
- **Groups.** Bindings are grouped by read set, `programHole`'s `group`: one binding *function* per
  distinct set of groups among the bindings of a unit — a mixed text whose holes read two sets is in
  both — in document order of its first binding. A `when`'s group is its hole's, which is the read set
  of the whole value, arm included: the `when` runs again on a write its arm's text reads, and writes
  nothing then.
- **A `view` `let`** read by one hole is that hole's value, substituted (D-d); one read by several
  holes is a memo node, S3's, and refused as a limit of the compiler until then.

S0's one text binding — a text node marked by a space in the markup, its `data` written when it
differs from a slot — is a `text` binding like the others from S1: one shape, the same as
tea-inline's, and the S0 goldens move with it.

### 8.3 Handlers and the write pass

A handler is the arm of its key, called directly with the key's fields: no message, no `case`,
no dispatcher. The program module's own `update` is written in place, its top-level `case`'s arm
for the key's constructor taken (`programArm`); another module's arm is a piece (§8.4).

**The write pass** (D3, the owner, synchronous): at the end of the handler, inside the guard, the
binding functions of the page whose groups the key's writes reach (`programCalls`, or for a tail
`programCallsAt`, §8.5), each once — deduplicated when the program is built, not at run time — in
document order; then the key's command (§4). There is no scheduler and no microtask: two events in
one task are two passes. *Measured against tea-inline's microtask flush in S1's report.*

**Controlled inputs.** A binding of a `stateful` attribute (a control's `value`, `checked`,
`selected`) is called by the handler of every key one of its own element's events reaches, whatever
the key writes, so the control shows the model after the user's edit even when the arm leaves the
model as it was (`plans/direct-rewrite.md` §8, pay-per-use). `prop` compares with the DOM's live
value, so an edit the model agrees with writes nothing.

**An event** is `on(E[n], f, type)`: `f` is the key's handler when the handler value is a
constructor with no fields, and otherwise a function of the event that reads the payload through
the event's extractor (`onInput`'s `target.value`) and calls the handler with the constructor's
fields. A handler value that is not a constructor whose key the lowering can name (a message
value) is a limit of the compiler. `preventDefault` and `stopPropagation` run in the DOM listener,
before the guard.

### 8.4 Pieces: another module's view and arms

The program site (§7) is written in the module that calls the program's constructor; another
module's code reaches it as **pieces**: exported top-level functions and constants of the module
that declares the code, lowered there, in parallel with every other module, and called at the
program site by name (option 2 of §7, extended to `update` and `view`).

- **An arm piece**, `<Module>$<declaration>$$arm$<n>`: one per branch of a `case` at which the key
  tree splits a message inside a function of that module — `W1.update`'s `case msg of` — other
  than the program's own `update`'s. It takes the branch's pattern variables, in order, then the
  function's other parameters, and returns the function's result for that branch. `n` is the
  branch's index among the arms of every split `case` of the declaration, in `Bir` order. The
  arm of `Main` that hands the sub-message on (`{ model | w1 = W1.update sub model.w1 }`) is
  written at the program site with that call replaced by the arm piece of the key's next step,
  applied to the key's fields — the leaf constructor's, `Program.Key.fields` — and its other
  arguments, each a name, so release's single-use inlining fuses the piece
  (`emit/release/core/InlineOnce.beni`). A key whose split inside another module is followed by a
  further split in a function that branch's arm calls is `deep_split`, a limit of the compiler.
- **View pieces**, of a `view` (or a function `view` calls through `Html.map`) of another module,
  on one call path: `<Module>$<declaration>$$html$<n>`, the unit's HTML string (§8.2); and
  `<Module>$<declaration>$$bind$<n>`, one per binding function (§8.2's grouping), taking `E`, then
  the function's parameters. The events are not a piece: the program site wires each from
  `programPiece`'s facts — the element's ordinal, the key the event's message reaches through the
  `Html.map`s around the call, and its argument: none, the payload, or constants the program site
  spells. An argument the program site cannot write is a limit of the compiler.
- **Names and numbers** are input-derived: a piece's `n` counts the pieces of its declaration
  before it, in the order the pass meets them (CLAUDE.md rule 5). A piece's facts — its groups,
  bakes, element ordinals and events — are computed once, serially, by the pieces pre-pass from the
  write-set pass and the module's `Bir`, before any module is lowered, and both the owning module
  (the `piece` hook, run there) and the program site (`programPiece`) read that one record, so
  they agree by construction.
- **A cross-module reader** (D-c) — `W2.view` reading `W1.Model` — is a binding piece of `W2`
  whose groups `W1`'s keys reach: the handler of each such key calls it in its write pass, from the
  program site, by name. There is no registration at mount and no rule about which widget is above
  which.
- **The first refusal S1 removes** is a `view` through `Html.map` whose markup is another
  module's (§5, class 1 until then).
- **Handlers live at the program site**: the arm, the pass and the wiring of every key, whatever
  module its markup is in. *Measured against tea-inline's in-widget handlers at N = 256.*

### 8.5 Per-path passes

A key's write set joins what every path through its arm writes (`write-sets.md` §4.4): a host
event that one key receives — `Pushed`, decoded in the arm into `serverSet` of one widget or a
`snapshot` of all — writes every widget's state, and one pass at the end would run every binding
of the page for each push. So a key's arm, through the program module's own functions it calls, is
written in place, and **each tail** — each result of a `case` or `if` arm the value of the key's
`update` can be (`programArmTails`) — ends with its own pass, of the groups that tail's writes
reach (`programCallsAt`, `write-sets.md`'s per-path sets, amended 2026-10-17). A function of
another module is one path: its arm piece returns, and the pass follows.

### 8.6 Lists

`List` is positional only (#294, #298). S1 compiles what reads a list whole — `List.length`,
`String.join`, `List.foldl` in a hole — and the arms that append (`[ …xs, x ]`), remove the last
element (`List.pop`) or clear it, each a write of the list's path. A `For` is not S1's: a keyed one
is a limit of the compiler naming keyed rows; a positional one is S1's only if it stays small, and
is a limit until its size is reported. An edit of `List` rows by id (`List.filter (λr → r.id ≠
id)`, a `map` with an id guard) is a language rule's error that names `Dict.update`: **`Dict` is
the keyed collection** (§5, class 3, from S2).

### 8.7 What S1 refuses

The texts, each in `build/bad/inline/` (§5's classes; a limit of the compiler begins *"A limit of
the compiler"*, a language rule never says *"yet"*):

| Refusal | Class | At | Fixture |
|---|---|---|---|
| an `update` computed when the page runs: *"… cannot write each message's arm into the handler of its key: a handler is the arm itself, with no message made … Name a function of the program's modules as `update`, or write a lambda whose body chooses the arm."* | 3 | the record's `update` | `OpaqueUpdate/` |
| an `Html.map` whose function is not a constructor: *"… which key each of those messages reaches cannot be known when the program is built … Map with a constructor … and decide in `update` what the message means."* | 3 | the map's hole | `MapNotCtor/` |
| markup held as a value — in the model, a record, a list — at the hole that shows it and at the markup itself: *"… its elements cannot be numbered when the program is built … Keep in the model the data the markup shows, and write the markup in `view` or in a function `view` calls."* | 3 | each | `MarkupValue/` |
| a key whose write set is `*` (`write-sets.md` §3.4), whose arm replaces the whole model with a value the pass cannot see into: *"… no binding of the page can be chosen for it … Write the fields the arm changes …"* — a declared `replace` (`plans/direct-rewrite.md` §6) is the other way out once it exists *Open (2026-10-17, S1's first pull request):* a model that is one value — an `Int` — makes every write `value ρ`, exactly, and S0's pages are such programs, so the rule needs a criterion the owner has not given (a model with fields? a key whose arm builds the model from opaque parts?); until then a `*` key is compiled as S0 compiles it, every binding called | 3 | the record's `update` | `StarNotReplace/` (pending) |
| a keyed `For`: *"… does not compile keyed rows — a `For` with `keyed` — yet …"* | 1 | the `For` | `ResearchListWidget/` |
| a key whose writes a cap of the write-set pass cut (`Program.Key.cap`): the depth limit `k` and the rounds of a recursive component until #286's folding replaces them; the leaf, alternative and size caps are lifted in S1 | 4 | the record's `update` | `CapFired/` |
| a key that splits again inside another module (`deep_split`); an event argument or a piece capture the program site cannot write; a `view` `let` read by several holes | 4 / 1 | the construct | — |
| a text hole beside an element: *"… writes a text hole as its element's whole text, and this one stands beside an element; wrap the hole and the text around it in an element of their own …"* | 4 | the hole | `TextBesideElement/` |
| an attribute that changes and is not a DOM property `prop` writes | 1 | the element | `AttributeChanges/` |
| an event whose handler value is a message no key can be named for when the program is built: *"… so its message would need a dispatcher …"* | 4 | the element | `MessageValue/` |
| an `if` or `case` in markup that is not an eager `when`: arms that are not one element and `<></>`, or a shown arm that reads what the branch binds | 1 | the hole | `WhenBinds/` |

**An arm that reads its message whole** (D-e, `message_read_whole`) is not refused: that key's
handler builds the message value from its fields, in that handler only, and hands it on.

### 8.8 Release

What a golden shows, stated once: the runtime functions of §8.2 ship only when used; a piece used
once is fused into its one use by single-use inlining, which needs its arguments to be names; a
`case` on literals whose arms are expressions — an enum cycle — is a chain of conditionals; no
message object, `switch` on a key or context chain survives.
