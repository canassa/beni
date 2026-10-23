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

*Amended 2026-10-17 (the owner): a `*` key is one of three.* A `*` that comes from lost precision —
a cap of the write-set pass cut the key, or the pass wrote the whole model as an approximation: an
opaque call's result, an application through a parameter, a record of a type it could not read
(`write-sets.md`, amended 2026-10-18, `Write.lost`) — is a limit of the compiler, class 4, to be
closed. Only an exact inferred write of the whole model, when its type is a record of more than
one field, with no declared `replace`, is the language rule, class 3: the rule forbids a write
that hides which fields changed. A model that is a single value — not a record of several fields,
by its type — hides nothing: it is written exactly, and accepted.
(`Program.Key.star_kind`, `boundary.md` §9.4.6 1.15; §8.7.)

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
   *Amended 2026-10-19 (the owner: both are S1's, for big-component; S4 is lifetime only):*
   markup **held in data or chosen at run time** — a markup value stored in the model or a
   record, passed to a function that decides where it goes, returned by a function whose body the
   compiler cannot see — stays class 1. Two shapes of static structure move into S1: a **view
   helper** of the program's own module, a function whose body is markup, called from the `view`
   in a hole (`{part1 model}`), written in place in a context of its own (§8.4); and a **`case`
   in markup** whose arms are each one element or `<></>`, written as eager `when`s, one per
   element arm (§8.2).
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
`<Module>$<declaration>$$html$<n>`, its binding functions
`<Module>$<declaration>$$bind$<n>$<k>` and its event wiring `<Module>$<declaration>$$on$<n>`
(§8.4, amended 2026-10-18). The program site knows an arm piece by its name and parameters and a view piece by the
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
  before either, a cell's before a cell, `</tr>` before a row, `</thead>`
  and `</tbody>` before a row group, and `</p>` before the block elements whose start tag closes a
  `<p>` in button scope — not `<table>`, which does only outside quirks mode, nor `<form>`;
- at its parent's end only where the parent's end tag generates implied end tags (`div`, `section`,
  `ul`, `li`, `dd`, `button`, `h1`–`h6`, `td` and the rest of the standard's list), or a row closes
  a cell, a row group a row. A `<span>`, a `<label>`, a
  formatting element and a custom element close none of them.
- but never before a sibling when its own last child is an element other than a `<p>` whose end
  tag was left out (*corrected 2026-10-18, the second review*): that child is still open, and an
  `<li>`, `<dt>` or `<dd>` start tag stops its search for an open one at a special element, so
  `<ul><li><dd>x<li>y` puts the second `<li>` inside the `<dd>`; the element then keeps its end tag,
  `<ul><li><dd>x</li><li>y`.
- and never inside a `<select>`, the select's own end tag included (*corrected 2026-10-18, the
  review of #350*): the standard reworked `select` parsing for the customizable `<select>`, and the
  rules for `</option>` and `</optgroup>` were the old "in select" mode's. The rules here follow
  the standard as parse5 7.3.0 implements it, the parser the gates check pages with; with every
  end tag written in a select, the rework changes nothing (`browser/inline/SelectEndTags`, in parse5
  and in Chrome). An `<hr>` inside an `<optgroup>` is refused as markup the parser rebuilds: the
  parser closes the group before it (`build/bad/inline/OptgroupRule`).

The run of end tags at the very end of a string parsed alone is left out too, which the parser
closes at the end of its input. A string that is concatenated with another keeps its own closing
run.

*Amended 2026-10-24 (#916): an end tag that pops closes what its parent's last child leaves
open.* The end tag of `address`, `article`, `aside`, `blockquote`, `button`, `center`, `details`,
`dialog`, `dir`, `div`, `dl`, `fieldset`, `figcaption`, `figure`, `footer`, `header`, `hgroup`,
`main`, `menu`, `nav`, `ol`, `search`, `section`, `summary` and `ul` generates implied end tags
and then pops every element open above its own (§13.2.6.4.7). So the last child of such a parent
needs no end tag, nor does any element that child's end leaves open, when each of them is one a
pop closes exactly as its own end tag would, and none has the parent's name, whose end tag would
match it first: `<section><header><aside><p>x</section>`. The elements a pop closes exactly are
the elements of that list but `center` and `dir`, and `li`, `dd`, `dt`, `h1`–`h6`, `p`, `span`, `label` and `output`.
Not a formatting element, which the list of active formatting elements opens again after the
pop; not a `form`, whose end tag also clears the form element pointer; not a table or its parts,
a scope's boundary, a `select` or a `template`, which change the insertion mode. A piece's
string keeps its top element's end tag. On S1 this is each widget's
`</aside></header></section>` closing run: N = 1 −11 B, and −1.9 B per widget from 16 to 64 (seed
1). `browser/inline/PoppedEndTags`, whose transcript is the one the full string gave, in parse5;
`emit/release/inline/PoppedEndTags`.

**Elements by document order.** An element some code refers to is `E[n]`, the `n`-th descendant of
the unit's top element in document order (`top.querySelectorAll("*")`, read once at the mount, and
only when some code refers to a descendant); the top element is the unit's node itself. There is
no marker attribute and no walk. *Amended 2026-10-17:* when code refers to one descendant only, it is
reached by its path of `firstChild` and `childNodes[i]` from the top node, which costs less than
the list. *Amended 2026-10-18:* `text` takes a string — the lowering writes a lone number hole as
one, by a template — and a page that calls it once has it written there by release's single-use
inlining (`backend.md` §9, *A body whose returns all end it*), not by a case of this lowering (S0's
pinned 589 B for `PushAndTimer` holds: 583 B).

**A binding** is one write guarded by a compare, through the runtime's functions, which are
beni over `Js` in `Inline.beni`:

| Function | What it writes |
|---|---|
| `text(node, value)` | `node.textContent`, `String(value)`, when it differs |
| `prop(node, value, key = "value")` | the DOM property `key` when it differs: a control's `value`, `checked`, `selected`, and the boolean attributes whose property has their name (`disabled`, `hidden`, `multiple`, `open`, `required`) |
| `when(node, hidden)` | the node, or the empty text node it keeps in its place while `hidden` |
| `on(node, f, type = "click")` | a listener of `type` whose event enters the dispatch guard with `f` |
| `onArm(node, f, type, arms)` | `on` for a handler inside eager arms: while one of `arms` (an element, or an array of them outermost first) is hidden, the event does nothing |

- **A text hole** is `text` on its element. An element whose children are texts and text holes —
  *mixed text* — is one binding writing its whole text as a template. A hole of `String`, `Char` or
  a number only; a text hole beside an element is a limit of the compiler (§8.7).
- **An attribute** whose value changes is `prop`; a constant one, and one `init` bakes, is in the
  markup. An attribute that is not a DOM property and whose value changes, a URL, raw HTML, and a
  class or style list that changes are limits of the compiler.
- **An eager `when`** (the owner's D-b) is an `html` hole whose value is an `if` — a `case` of two
  arms — one arm of which is one element written in place and the other `<></>`, and whose markup
  arm reads no variable the branch binds (`Program.Arm.eager`): the arm's element is in the markup
  and its holes are bindings like any other; `when` hides it while the value takes the other arm.
  *Corrected 2026-10-19 (the owner, #459):* eager evaluation is valid only for expressions proven pure
  and total. Every other value, including an effect, a potentially throwing call, a foreign call or an
  operation whose totality is unknown, executes only in the selected arm, as in an ordinary `if` or
  `case`. A hidden arm does not log or throw. Entering it computes current values; no value persists
  as a memo while it is hidden. A branch of any other shape is S4's (§5, class 1).
  *Amended 2026-10-19 (the owner): a `case` in markup.* A hole whose value is a `case` (or an `if`
  of `else if`s) of any number of arms, each one element written in place or `<></>`, each element
  arm eager, is one eager `when` per element arm: every arm's element is in the markup, in
  document order, and each `when` shows its element while the value takes that arm and hides it
  otherwise. The value is evaluated once per pass for all of them (`programBranchArm`). An arm that
  reads a variable its pattern binds, or that is not one element or `<></>`, stays class 1
  (`browser/inline/CaseInMarkup`, `emit/release/inline/CaseInMarkup`).
- **Groups.** Bindings are grouped by read set, `programHole`'s `group`: one binding *function* per
  distinct set of groups among the bindings of a unit — a mixed text whose holes read two sets is in
  both — in document order of its first binding. A `when`'s group is its hole's, which is the read set
  of the whole value, arm included: the `when` runs again on a write its arm's text reads, and writes
  nothing then. A guarded arm shares that whole-branch group, including its selector, so a reveal
  after hidden data updates prepares current values and its visibility together.
- **A `view` `let`** read by one hole is that hole's value, substituted (D-d); one read by several
  holes is a memo node, S3's, and refused as a limit of the compiler until then.
  *As built 2026-10-18 (S1, #351 and its correction):* the `let` is evaluated in the binding function
  of the hole that reads it, from the model that function is handed, and in no other: a function
  evaluates the `let`s its writes' values and its `when`s' branch values read, through any `let` they
  read in turn. A release build does not drop a `let` a function evaluates and never reads — the
  release optimiser keeps a binding whose value reads a field, which it cannot prove pure — so
  #351's first text, which evaluated every `let` in every binding function and counted on release
  to drop the unread ones, was wrong.
- **Evaluation order** (*added 2026-10-19, the review of #398*). A binding function evaluates, per
  context: first the `let`s it reads; then every value that may throw — a hole's or an attribute's
  value, or a `when`'s branch value, holding any call that is not a basic operator
  (`Context.valueSafe`: literals, locals, field and tuple reads, `if`s and `case`s, interpolation
  and `Operator`'s calls of such are safe); then each write, with its safe values evaluated just
  before it. A `Debug.todo` in a binding therefore throws before the function has written
  anything, and the page stays as the last pass left it, as on master and `browser-tea`
  (`browser/inline/ThrowBeforeWrite`); a safe value is still written at its write, where release
  writes it in place (#365's rule, `backend.md` §9 item 1, is the same set of values).
  *Corrected 2026-10-19 (#459):* guarded arms and functions whose later context may fail prepare
  their selected values and helper arguments in source order before any DOM write of that function.
  An argument is evaluated once per call site, before that helper's body; sibling calls keep separate
  bindings. Only invocation-local temporaries cross the preparation and write phases. Functions whose
  work is all proven pure and total keep their existing eager code.
  *Amended 2026-10-23 (#618):* "proven pure and total" (`Context.valuePureTotal`) includes a
  saturated call, with no hidden evidence, of a declaration the checker proved total
  (`checker-v2.md` §26) when every argument is pure and total too, so `bump (String.length s)` is
  eager; the classification is an uncapped iterative walk, so an expression's size alone never
  makes it guarded.
  *Amended 2026-10-23 (#844):* it includes a well-known `==`, `≠`, `<`, `≤`, `>` or `≥`, or a
  dot-call — a `method_call` — with no hidden evidence whose callee the checker proves total
  (`checker-v2.md` §26, `Totality.termTarget`): a primitive comparison (`===`, a number's or a
  character's order), `String`'s order and a key's when `String.compare` is total, and a method that
  is a declaration the checker proved total; its operands must be pure and total too. These are
  the facts the checker already uses for a declaration's totality, so `if model.n < 4 then <p>…</p>
  else <></>` inside an arm no longer makes that arm guarded. An evidence parameter, a derived
  function and a field call stay unknown, and a type's own `compare` that logs keeps its arm guarded
  (`browser/inline/SelectedOperators`, `browser/inline/ArmOperators`,
  `emit/release/inline/ArmOperators`).
  *Amended 2026-10-23 (#844, step 3):* every value proven pure and total is safe too
  (`Context.valueSafe`): it throws nothing and does nothing, so where it is evaluated against a
  DOM write cannot be seen, and it is evaluated just before its write like the other safe values.
  Before, a total call or a comparison was hoisted with the values that may throw. A value that may
  throw is still evaluated before any write of its function, so `ThrowBeforeWrite` and
  `SelectedThrows` are unchanged (`emit/release/inline/ArmOperators`, `CounterLocal`,
  `SingleValueModel`).
  *Corrected 2026-10-19 (the owner, #466):* a helper argument used by an event handler is part
  of the handler binding, as in the source: its message is built during view evaluation and lives
  on the node until the binding reruns. Bound arguments share that lifetime, are refreshed by a
  relevant selected binding evaluation, and are released on arm exit or teardown. This is ordinary
  handler binding, not a memo exception. Its complete read set includes argument fields used only
  by handlers; updating one refreshes the binding even when no text changes. Every helper call
  occurrence has its own binding. An argument proven pure and total may instead be recomputed at
  dispatch when observably equivalent; an effectful or possibly throwing argument is retained
  from binding evaluation and never rerun by dispatch. Successful preparation publishes the new
  binding with its selected writes; a failed preparation publishes neither. An inactive arm has
  no active handler, including no `preventDefault` or `stopPropagation` effect from a host's
  programmatic event on a retained detached node. Hidden updates keep no stale argument binding;
  reentry evaluates current-model arguments freshly. Ownership guarantees are unchanged.
  *Amended 2026-10-23 (#844):* for a handler with no captured argument and neither
  `preventDefault` nor `stopPropagation`, the test lives in the runtime: the wiring is `on`
  handed the element of each eager arm around the handler, outermost first (one element alone, or
  an array), and `on`'s listener asks each element's `when` anchor before the event enters the
  guard, as the listener written in place did. A handler with a flag or a captured argument keeps
  its listener written in place (`browser/inline/ArmListenerHidden`,
  `emit/release/inline/ArmListener`).
  *Amended 2026-10-23 (#874):* that wiring is `onArm`, a runtime function apart from `on`, and
  `on` is the three-argument function it was before: a page with no handler inside an arm names
  only `on`, so dead-export removal leaves out `onArm` and its arm walk, and its `on` is the one it
  had before the step above, byte for byte (`emit/release/inline/CounterLocal`). A handler
  inside an arm keeps the test above unchanged.

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

*Amended 2026-10-18 (the owner): there is no coarse pass.* No key's pass calls every binding of
the page: a `*` key reaches the lowering only for a model of one value, whose whole write is that
value, and its pass is the groups the write-set pass found for it, as any key's
(`browser/inline/SingleValueModel`).

*Amended 2026-10-19 (the review of #389):* the first text said a program the pass does not know
cannot reach the pass, and one could: a program defined in a module of the project's own
platform layer, which the pass skipped as not the app's. The pass now reads a module of a layer above
the platform as the program's own code (`Writes.Input.own`, `Emit.ownCode`), decided by the
layer's role and not by where it is read from: the platform is the layer that owns the lowering,
every layer declaring a program constructor or placement the lowering names, and all they depend
on; every other layer is the project's. A shipped platform named by its directory is still the
platform (`platform_test`'s by-directory cases, red against the first fix, which went by
embedded-ness). So such a program has its keys, holes and groups like any other
(`browser/inline/PlatformProgram`, `PlatformRecord`, `PlatformElement`, `PlatformWidget`,
`PlatformReader`, `PlatformTwoLevels`). Whatever the pass still does not know is a limit of the
compiler in every build mode, never a handler without its pass: a program it did not analyse
(its keys, at `refuseKey`, and its pass, at `passOf`), and a hole it did not reach (`known`). The
safe-build asserts that remain hold by construction, each with its argument at the assert.

*Amended 2026-10-23 (#315 R7):* an arm that writes its model in place (`ownership-checker.md`
§31.10) answers the object the model already holds, and `programArmFields` then answers the
`model` handle itself; the handler writes no `model = next`. In a sandbox program whose arms all
write in place the model is never reassigned, so release folds the handler to its stores:
`e.a.b=4` for `{ model | cup = { cup | tea = 4 } }` (`emit/release/inline/NestedFieldWrite`).

**Controlled inputs.** A binding of a `stateful` attribute (a control's `value`, `checked`,
`selected`) is called by the handler of every key one of its own element's events reaches, whatever
the key writes, so the control shows the model after the user's edit even when the arm leaves the
model as it was (`plans/direct-rewrite.md` §8, pay-per-use). `prop` compares with the DOM's live
value, so an edit the model agrees with writes nothing. *Noted 2026-10-18:* the rule is per element, so an `<option selected={…}>` is not
written back on its `<select>`'s event — the event is the select's, not the option's; a select shows
the model through its own `value`.

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
  (`emit/release/core/InlineOnce.beni`). A constructor of a type of one constructor, which no
  `case` splits — `CounterMsg` around `Counter.Msg` — is followed on the leaf's path all the same:
  the key is `Inc` under it, and its arm takes `Inc`'s fields (`browser/inline/ArmPiece/`,
  `emit/release/inline/ArmPiece/`). A message of a type of one constructor is followed to it in
  the same way (`write-sets.md`, *amended 2026-10-18*): its key's leaf is the constructor, and the
  handler takes its fields (`browser/inline/ArmSingle/`). A key whose split inside another module is followed by a
  further split in a function that branch's arm calls (`deep_split`) has no piece for that
  function: the arm calls it as written, handed the message the key's fields make (D-e, *Arms the
  tracking does not specialise* below).
- **View pieces**, of a `view` (or a function `view` calls through `Html.map`) of another module,
  on one call path: `<Module>$<declaration>$$bind$<n>$<k>`, one per binding function (§8.2's
  grouping), taking `E` — the root's top element's descendants, which the program site finds with
  one `querySelectorAll` — then the function's parameters; and `<Module>$<declaration>$$on$<n>`,
  taking `E` and one handler per constructor the root's events send, in the order of each's first
  event, which wires every event of the root: the handler called with none, or with the payload
  through the event's extractor. The program site passes each handler of the key the constructor
  reaches through the `Html.map`s around the call, each a constructor of one field — the key's own
  handler when its leaf is that constructor, or, when its leaf is a map's constructor, a function
  that makes the message below the leaf from the constructor's fields and calls it. Any other
  handler value is a limit of the compiler. The root's static markup is the piece
  `<Module>$<declaration>$$html$<n>`, a string with every end tag of its top element written, since
  the program site's string goes on after it; the program site writes it into its own string as a
  template, `<div>${W1$view$$html$0}</div>`, and the release optimiser folds the template, the
  constant being used once, into one string. An element before it keeps its end tag, since the
  program site does not read the piece's string, and nothing in the piece is left open.
- **Names and numbers** are input-derived: a piece's `n` counts the pieces of its declaration
  before it, in the order the pass meets them, and `k` its binding functions in document order
  (CLAUDE.md rule 5). *Amended 2026-10-18 (as built):* the pieces pre-pass, serial and before any
  module is lowered, finds the roots — each markup root of a module other than the program's on the
  write-set pass's sites, its declaration, its call path, and whether anything but the program's
  own markup functions names the declaration (if not, the declaration is written only as its
  pieces) — and the **owning module's lowering** computes the facts (`Lowering.piece`): its
  groups, bakes, element ordinals and events, and exports the static markup, with the program's write-set facts on
  the root's call path. A module is lowered in a wave one past every module whose pieces it reads,
  so a program site reads facts no worker is still writing; the waves are input-derived, and the
  output is the same at every `--jobs`. A root a program shows at more than one place, or one not
  exposed, is a limit of the compiler, reported at the program's hole.
- **A constraint on M4** (*added 2026-10-18, the review of #351*). Emit is not cached today, so
  pieces and their facts are made again on every build. A future emit cache or resident daemon
  must key a program module's output on the facts of every owner whose pieces it reads, and an
  owner's pieces on the write-set facts of each program that reads them, on the root's call path
  (`Lower`'s `piece_pc` and `inline_path`): both directions, since an owner's facts are computed
  from its readers' write sets. The checker's interface firewall does not cover this: a body edit
  that changes a piece moves no interface.
- **Arms the tracking does not specialise** (*amended 2026-10-18, the review of #351*): a default
  branch, bindings before the `case`, a function a value holds, another module's function with no
  arm piece, a recursion, the message read whole or wrapped in a constructor. The arm is then the
  ordinary code, with the message built from the key's fields where it is read (D-e), not a
  refusal. Only a message wrapped in a constructor whose other fields the handler is not handed
  is still a limit of the compiler (`ArmWideWrapper/`); `deep_split` is no longer a refusal.
- **A cross-module reader** (D-c) — `W2.view` reading `W1.Model` — is a binding piece of `W2`
  whose groups `W1`'s keys reach: the handler of each such key calls it in its write pass, from the
  program site, by name. There is no registration at mount and no rule about which widget is above
  which. *Reversed 2026-10-22 (the owner, #668): readers register once at mount; see below.*
- **A view helper** (*added 2026-10-19, the owner*: the same-module case of a piece). A hole of the
  program's `view` or of a piece's root, or of markup written in place under them, whose value
  calls a function of the same module whose body is markup (`Program.Callee`, refusal `none`, under no
  `Html.map`, with no `let`s) is that function's markup written in place: its elements are the
  page's, in document order, its holes have the facts of the call's path (`programInlineEnter`),
  and each binding that reads them enters the call with its arguments evaluated in the enclosing
  context. A helper's fragment's children are spliced where the hole is. It is lifted as a piece
  is, in its own module — the program's, or the piece's owner (`browser/inline/ViewHelper`,
  `emit/release/inline/ViewHelper`; big-component's `part1 model`). A function that calls itself,
  one under `Html.map`, one with `let`s no hole reads, and markup held in data or chosen at run time
  stay class 1 (`build/bad/inline/MarkupInModel`, `HelperNamedElsewhere`, `HelperMarkupArg`,
  `CaseValueArm`). *Amended the same day (#436's review):* each binding function that writes into
  a helper's markup enters the call, its arguments evaluated again; an argument that may have an
  effect (`valueSafe`) must therefore be entered by exactly one function, or it is S3's memo node
  and refused (`HelperArgTwice`), as a `let` read by several functions is. Within one binding
  function, a helper's effectful arguments are bound once at their first entry and reused when
  a nested context enters that same call again (`browser/inline/HelperArgOnce`); distinct sibling
  call sites bind their own arguments. This is local evaluation, not a memo shared between passes. Two calls of one helper
  share its root, so a `let` of the helper read by both, in two functions, is refused the same
  way: conservative, never unsound.
- **The first refusal S1 removes** is a `view` through `Html.map` whose markup is another
  module's (§5, class 1 until then). *Removed 2026-10-18* (`browser/inline/Counter/`, `Reader/`,
  `ResearchS2/`, `ResearchS3/`, `Texts/`).
- **Handlers live at the program site**: the arm, the pass and the wiring of every key, whatever
  module its markup is in. *Measured against tea-inline's in-widget handlers at N = 256.*
  *Reversed 2026-10-22 (the owner, #668); see below.*

*Amended 2026-10-22 (the owner, #668): one closure per root, writes in place, readers registered
once.* The two bullets above, D-c and "Handlers live at the program site", are reversed. About 100
of S1's 114 B per widget above tea-inline are this output's shape, not beni's guarantees, and no
smaller change closes it (`plans/s1-gap-and-latency-report-2026-10-22.md`, Part 3). The target is
tea-inline's output, as for every slice:
- **A root's code is one closure.** For each markup root a program shows through `Html.map` (a
  piece's root), one closure holds the root's slice of the model, its elements, its binding groups
  and its handlers. A handler writes the slice **in place** and schedules the groups its writes
  reach (`t.cups = 4, n(r[0])`). It is written with its root's markup, not at the program site.
- **Bindings are grouped by the field they read.** A group is a list of binding entries that one
  call runs. A handler's write pass, the first render and each pushed-state tail run groups, never
  lists of single bindings.
- **A cross-module reader registers once, at mount.** A root that reads another root's field adds
  its binding to that field's group in the other root's table (`i[1][3].push(r[3])`). A writer's
  handler then runs only its own groups. Registration is synchronous and happens at mount, so D3
  holds and no run-time cost is paid per event.
- **Pushed state is loaded by one generic loader.** A tail that writes a root's whole slice
  (`replace`) validates the value, copies it into the slice and runs every group of the root. There
  is no per-binding pass and no per-root route case where the program's `update` permits.
- **`init` is data**: the model's initial value is written as literals in the model.
- **Depends on #315 R4–R7.** A closure can hold its slice only while the slice is the same object
  after every write: the ownership checker must accept the in-place record writes. Until #315
  lands, §8.3–§8.4 above stand as built. There is no build that writes both forms.
- **Decided with the build** (#668): which module writes a root's closure under per-module parallel
  lowering. §7 rejected writing another module's code at the program site. The likely form is a
  piece of the root's own module that the program site hands the slice and the registration table.
  Also decided then: what the lowering reads from #315 to know that a slice is stable, and how a
  reader's root finds the writer's table when the two mount in either order.

*Design amendment 2026-10-22 (#668, proposed for owner review; its six decisions taken 2026-10-23, below): the root piece
and its mount contract.* This specifies the preceding owner's reversal; it is **not implemented**. It takes
effect after #315 R6/R7, including enforcement, hoists, stores and the optimiser barrier. Until
then the preceding *as built* rules describe the compiler. No section is renumbered. D-c now
means **mount-time registration**, not static reader calls. The decisions explicitly left to
the owner are listed at the end of this amendment; the rest is the proposed implementation
contract, to be reviewed with them.

**Who writes the closure.** The root's **own module** writes a root factory piece,
`<Module>$<declaration>$$root$<n>`, beside its `$$html$<n>`. Calling the factory at mount creates
one lexical scope holding the slice, elements, anonymous binding entries, groups and local
handlers. A local root uses the same contract, without an import. `n` retains §8.4's
preassigned declaration/call-path identity. This replaces `$$bind`/`$$on` exports for that root;
it does not copy their bodies into `Main`. Release may fuse a single-use factory under its
ordinary rules; development retains the piece call. Neither form changes module ownership.

The serial direct-program pre-pass builds a **root plan** before parallel lowering. It joins
the write-set pass's keys, split sites, exact per-tail writes and anchored per-call reads with
ownership facts; it does not rediscover them by inspecting generated JavaScript. The plan gives
each worker only the code it owns and named calls for everything else. The piece hook in
`platforms/browser-inline/zig/inline.zig` writes the factory; `Lower.zig`'s `Direct.ViewPiece`,
`piece_now`/`piece_pc`, `programPiece` and program/arm hooks carry the extended plan. This needs
a versioned markup interface extension, not an unversioned cast to the current `PieceData`.
An arm and its view can be in different modules: the arm remains an arm piece in its own
module, called from the root. No worker lowers another module's BIR body.

The factory takes, with unused arguments omitted by ordinary lowering:

- the **slice object**, for a proved stable record slice; otherwise an explicit **slice cell**
  for a value whose exact source semantics replace the value (a number, union, list, or an
  entire record rebuilt fresh). A cell is one mutable slot, read afresh by bindings and
  updated by the selected arm. A record cell is not permission to copy a rejected update;
- the elements selected once from that root's markup, as today;
- its own preallocated group table, the program's registration table, and live access to any
  other model paths its bindings read (stable slices directly; replaceable values through
  their cells). Passing a captured scalar snapshot is wrong;
- handlers for keys whose arm belongs to the program site, and named arm-piece dependencies
  for other modules' code. Their ordering and payload convention are in the plan, not inferred
  from the first event at run time. If the program needs a root-local handler for a subscription
  or command, the factory publishes that handler in a planned export slot.

`Main` still writes the mount and combined HTML string, the fresh model, table allocation,
factory calls, its own update arms, subscription starts/disposers and command host. It hands
its own handlers into roots; it does not export every widget handler just to wire a click.
A local handler may move to a root only when the plan proves that the enclosing forwarding
arms contribute no additional model writes, condition, command or effect. Otherwise that key
stays with its enclosing arm and is passed in. A sole local event can therefore be literally
`on(e[0],()=>{t.cups=4;n(r[0])})`, without silently deleting work in `Main.update`.

Rejected: writing the closure at the program site repeats §7's cross-body cache dependency;
keeping handlers there preserves the repeated slice paths and reader calls #668 removes;
a module-global widget registry couples independent mounts and makes mutable state global.
The table here is fresh per mount, not a registry of modules at import time.

**Numbering and registration.** A field group is a bucket of binding entries, not a function
that takes `(elements, slice)` at every call. One anonymous entry contains the writes of one
of §8.2's existing binding functions, retaining its `let`s and evaluate-before-write rule.
The same entry can belong to several buckets when it reads several fields. Equal read sets
at different roots do not merge entry identity (`write-sets.md`, *parameterised template reads*).

Before workers start, root ids are assigned in markup placement order, using the input-derived
module/declaration/call-path identities to distinguish sites. Within a root, bucket keys are
anchored read paths relative to its model slice, ordered by their structural encoding: field
names in source UTF-8 byte order, tuple/constructor indices numerically, a prefix before its
extensions. Tag and whole-value reads have distinct tags in that encoding. This uses neither
interner ids, release field names, hash iteration, absolute paths nor worker completion order.
A prefix write selects every conflicting bucket, using the write-set pass's conflict relation;
a whole-value read is not guessed to be a leaf field. Controlled-input repair and `ω`/every-key
reads have explicit planned buckets too. Lost precision is still §5's class 4.

Both the writer and reader are handed the same plan reference `(writer root id, bucket index)`.
The reader knows the **index**, from substituted anchored reads; the writer knows which of its
own buckets each tail writes. Neither reads the other's body or computes an index by counting
the other's emitted bindings. An otherwise unread field gets a bucket when an external reader
needs it. Changing such a reader can therefore change the writer's plan even with unchanged
interfaces. No registration call appears in a writer's event handler.

All bucket arrays for **all roots** exist before the first factory call. Factories append entries
into existing arrays; they never replace them or grow the table by `r.push(newBucket)`. A reader
may mount before its writer and execute `i[1][3].push(r[3])`; writer setup later appends its own
entries to `i[1][3]`. Cycles of reads need no topological mount order. After all factories have
registered, mount finalises each bucket in entry document order and does one first pass; only
then are subscriptions and the initial command started. Listeners wired during setup enter the
existing guard and cannot dispatch into partially initialised tables. Stop releases the tables,
entries and listeners with the program; there are no registrations across mounts.

**The synchronous group runner.** In the examples `n(...groups)` runs a write pass inside the
existing dispatch guard, not tea-inline's microtask scheduler. A tail supplies all its selected
groups in one call. Entries have preassigned document ordinals; finalised buckets are ordered by
those ordinals. The runner merges the selected buckets in that order and executes each entry
identity once, even when two selected fields reach it. It need not sort the page or enumerate
unselected groups at each event. First render and a whole-slice load use the same runner over
all that root's buckets. An empty write can still select the event element's controlled-input
repair bucket. Commands run after this pass; nested sends retain §6's queue and defect rule.
This replaces §8.3's compile-time-only deduplication with a group merge when registrations overlap;
it makes no new speed or byte claim without the later owner's measurements.

Rejected: immediate separate `n(r[0]); n(r[1])` calls can run a shared reader twice and reverse
document order; `Set` insertion order alone is not document order; a microtask breaks D3;
running every root on every event is the coarse pass §8.3 forbids. A binding still evaluates
its potentially throwing values before its writes, and an unknown defect still stops the page.

**Ownership: what authorises a held slice.** R5's channel is necessary, **not a stable-slice
certificate by itself**. `Lower.Input.ownership` supplies `Hoists.Table` (format 1, currently
cache-entry 13), its `clean` enforcement bit, accepted BIR demands, written fields, exact old-read
identities, captures and placements. R6 consumes those placements and capture loads, performs
base/operand evaluation before stores, and treats each demand as an optimiser barrier.
The inline lowering must use that path for every original store and call-site demand it emits.
Report-only acceptance, a missing table, or an unchecked module never authorises a store.

In addition the root plan must prove, for **every reachable tail**, that a directly held slice
and each held ancestor remain the same object: accepted nested updates return their base;
forwarding arms reinstall that same base; a declared load copies into it under the contract
below. Fresh reconstruction or assignment from another model path is not proof of identity,
even if the old slice is dead. A cell is the exact representation of an accepted replacement;
if a path can alternate between stable and replaced objects it uses a cell from the outset.
A binding reading a replaceable foreign slice reads its cell, so it cannot go stale. A held
nested stable slice must also survive ancestor loads; otherwise it too is cell-addressed.
There is no run-time choice between a store and a spread.

Generated root closures are **compiler-owned model access**, not source closures capturing old
values. Source lambdas inside arms, bindings, commands and subscriptions still obey §31.6:
field paths read at creation, whole captures keep their object, and once-writing closures keep
their restrictions. The root plan neither suppresses an escape nor marks a user closure reusable.
The model-entry exclusivity check (§31.8), accepted demands and absence of observable old whole
holders justify retaining the current model behind generated accessors. An implementation that
cannot establish this correspondence must stop with a class 4 compiler-limit diagnostic;
R5 alone must never be treated as authority to retain an arbitrary source capture.

Ownership rejects sharing, payload edits, old whole holders, escapes and unknown origins with
§31.9's existing record errors and explicit `Record.copy`/restructure fixes. A known valid shape
whose retention or group projection the compiler cannot represent is §5 class 4; a construct
reserved for a later slice is class 1 (or a suspending command class 2). The existing language
rules, including undeclared exact `*` replacement of a multi-field model, remain class 3.
No rejection selects `browser-tea`, spreads, polling or a broad pass automatically.

**Program-owned keys and pushed state.** `Pushed`, `Tick`, and a `*` key of a one-value model
remain ordinary keys with arms at `Main` when that is where they are declared. Their own tails
perform the writes and call `n(i[root][group], …)` for that tail's exact conflicts; registrations
bring in external readers. They never call exported binding functions. A root event sending
one of those keys calls the handler supplied by `Main`. A one-value model uses a cell:
`c[0]=value; n(i[0][0])`. A scalar does not become a pretend mutable record.

A declared `replace` is a semantic boundary, not permission to skip its body. The pre-pass may
factor routes into **data** only after proving that each successful route consists of validation,
replacement and the same command/result behavior, and that failures retain exactly the source
behavior. `replace` names a source helper today; recognising its spelling alone is insufficient.
Arbitrary route guards, transformations, error handling or side effects stay in their original
arm or own-module piece and then select groups. This is exact lowering of accepted code, not
a second renderer or a fallback representation. The existing key's schema tag switch is allowed.

For eligible `serverSet`/`snapshot` routes the data row is `(validator, destination, copy plan,
groups)` keyed by the source's widget key. One generic loader looks up the row, invokes the
schema validator, and **only on success** commits the validated owned value and runs the groups.
Unknown keys and invalid values follow the source arm (a no-op only if it was a no-op). There
is no per-root route `case`, wrapper loader closure, or repeated list of binding calls. The
validator is still beni's: host keys map to release field names under `schema.md` §6, unread
`Err` values produce no issues/prose, and a source that reads the error retains its decoder.
No `structuredClone` or unchecked `Object.assign(hostValue)` replaces validation.

For a stable record, a copy plan enumerates the record's complete checked fields and installs
the decoded values into the existing object; it does not retain a host object. For a stable
nested root, it descends into that existing destination rather than overwriting the pointer;
replaceable children/cells are assigned the new owned value. Validation completes before any
store in that source transaction. A snapshot that validates all widgets before updating any
keeps that atomicity: prepare every row, commit all rows, then one unioned pass. If source
snapshots instead accept fields independently, retain that order and those failure boundaries.
A fresh decoded record may donate fields only under ownership's disjoint/exclusivity conditions.

These additional copy stores need **explicit checked replacement evidence** in the root plan:
source tail and ownership entry/call demand, closed destination layout, owned decoded input,
absence of retained old whole holders, and which nested destinations retain identity. They
cannot be fabricated as accepted `record_update` instructions in the R5 table. R6/R7 provide
the stores/barrier machinery; if their interface cannot express this replacement proof, extending
that interface is a prerequisite of #668's implementation. The design must not claim that an
ordinary accepted update demand proves an arbitrary `Object.assign` safe.

`init` becomes a fresh literal allocation **inside mount** where the analysis proves it is data;
there is no `W.init(null)` per root. Never hoist that mutable record to a shared module constant.
A genuinely effectful/computed `init` keeps its evaluation and order; the target output is not
licence to erase effects. Rejected: a route switch per widget repeats the measured shape;
a loader which replaces a stable object invalidates all captured slices; a validator per binding
repeats work; skipping validation violates beni's boundary guarantee.

**Incremental lowering and the emit cache (#631), in both directions.** The checker's interface
firewall is unchanged; the emit dependency graph is not that firewall. Persist a canonical,
versioned root-plan artifact containing identities, call-path substitutions, bucket layout,
entry ordinals, ownership/retention/replacement evidence, key ownership and payload conventions,
external handler slots, markup/element facts, and named piece/arm dependencies. Persist portable
indices/bytes and hashes, never `PieceFacts.data` pointers, scratch arenas or interner ids.

- **Owner to program/reader:** a root's HTML, element order, bucket map, handler ABI, publication
  slots or retention mode invalidates each consuming program/reader's emitted row even when its
  interface hash stays unchanged. A body-only handler edit with an identical contract needs only
  its owning piece re-lowered; no program copies that body. A changed arm-piece contract also
  invalidates a root that calls it.
- **Program/reader to owner:** edited forwarding arms, per-tail writes, replace routes,
  substitutions/placement or a reader's anchored dependencies can change a writer's bucket layout,
  handlers or retention proof. Rebuild the plan and invalidate every affected root piece and
  consumer. An unchanged interface cannot mask that change. Unrelated roots may keep their rows
  when their canonical plan projection is identical.

Key rows on the module's own BIR/check artifacts and the exact plan/dependency projections they
consume, plus lowering/interface/plan versions and relevant build options. Ownership tables and
callee pattern facts (including #654's trailing unit arguments) are dependencies too. Restore
piece facts and their dependencies before allowing a consuming program row to hit; regenerate
reachability, consumed declarations and live piece selectors for this build before deciding reuse.
A missing/mismatched fact or unknown artifact version is an emit miss, not unchecked reuse.
The current cache's refusal to reuse markup is safe and can remain until these facts can be
recorded and replayed. That miss must still lower the **new** root shape; it never selects the
old handlers. Owner-first waves may remain for HTML facts, but bucket indices are fixed before
workers start, and waves and replay cannot assign ids. Differential tests compare cold, warm,
body-edited and cache-disabled output byte for byte at `--jobs=1` and `--jobs=8`, both for owner
edits and reader/program edits, with identical interfaces deliberately retained.

**Concrete output and goldens to build after the prerequisites.** The following is a readable
release-shape oracle for two widgets; names stand for the ordinary release renamer's choices.
It is proposed output, **not output of today's beni**. On dagon the reference was generated with
`./rr build unique-components tea-inline --size 2 --seed 1 --lists none` and its `src/app.js`,
widget modules, runtime and `dist/assets/index-DN-xTeer.js` read. Its two widgets initialise
`cups/season/coins/status` and `venue`; they have no cross-reader at this seed. The small example
below adds that edge deliberately. It retains beni's guard, synchronous pass, validation,
code-point helpers and full clamp wherever those are used; tea-inline's microtask, unchecked
loader and generator-only arithmetic simplifications are not imported.

Here W1's only field is `cups`, W2's is `venue`; W2 also displays W1's cups. All records are
stable. `text`, `prop`, `on` and the dispatch guard are the existing helpers; `n` is the ordered,
once-per-entry synchronous group runner above. The markup constants keep the existing HTML
parser/end-tag rules. A binding entry's ordinal is metadata shown by its placement here; the
implementation must retain that ordering through release renaming.

```js
// W1.mjs: only W1 writes these bodies. Bucket 0 is cups.
export const W1$html = '<section><button>Make it 4</button><p></p></section>';
export function W1$root(e,t,r,i,m) {
  r[0].push(()=>text(e[1],`${t.cups}`));
  on(e[0],()=>{t.cups=4;n(r[0])});
}
// W2.mjs: only W2 writes these bodies. Bucket 0 is venue.
export const W2$html = '<section><input><p></p><output></output></section>';
export function W2$root(e,t,r,i,m) {
  r[0].push(()=>{prop(e[0],t.venue);text(e[1],t.venue)});
  const b=()=>text(e[2],`${m.w1.cups}`);
  i[0][0].push(b);                         // register once, never per writer
  on(e[0],v=>{t.venue=v.target.value;n(r[0])},'input');
}
// Main.mjs: fresh model and buckets; root calls, no imported bind/on pieces.
const m={w1:{cups:-1},w2:{venue:''}},i=[[[]],[[]]];
root.insertAdjacentHTML('beforeend',`<div>${W1$html}${W2$html}</div>`);
W1$root(E1,m.w1,i[0],i,m);
W2$root(E2,m.w2,i[1],i,m);
// Finalise buckets, then first render exactly once per entry:
n(i[0][0],i[1][0]);
const tick=()=>{m.w1.cups=m.w1.cups+1;n(i[0][0])};
// Push/interval starts get these Main-owned guarded handlers after first render.
```

The mount/stop guard, element selection and registration ordering are required around this
excerpt, not optional runtime deletions. With initial `(-1, '')`, the first pass writes W1
`-1`, W2's input/text `''`, W2's output `-1`. Clicking W1 writes `4` to both cups displays;
inputting `Hall` changes only W2's venue group; a tick writes `5` to both cups displays.
Reversing the two factory calls still works because the buckets already exist and finalisation
restores document order. In a reversed markup placement the ordinals follow that placement.

For an eligible two-widget push, **the extra output** is data plus this shared algorithm (the
symbols `validCups`/`validVenue` denote the specialised schema validators, not truthiness tests;
`prepare` returns an explicit success/failure result). Copy-plan tags distinguish stable records,
nested stable destinations and cells. A flat stable-record case is shown:

```js
const routes=new Map([['w1',[validCups,m.w1,['cups'],i[0]]],
                      ['w2',[validVenue,m.w2,['venue'],i[1]]]]);
function prepare(key,raw) {
  const d=routes.get(key);
  return d===undefined ? failure : validate(d[0],raw,d);
}
function commit(p) {                       // p holds a validated owned value
  const [validator,target,fields,groups]=p.route;
  for(let k of fields) target[k]=p.value[k]; // known decoded keys, no host keys
  return groups;
}
function serverSet(key,raw) {
  const p=prepare(key,raw);
  if(p.ok) n(...commit(p));
}
function snapshot(raw) {
  const ps=prepareSnapshot(raw,routes);     // source's all-or-nothing validation
  if(ps.ok) {
    const groups=[];
    for(const p of ps.values) groups.push(...commit(p));
    n(...groups);
  }
}
```

These functions are shared, not emitted once for W1 and again for W2. Access to `routes` must
be an own-key lookup (or a `Map`): `__proto__`/`constructor` are unknown keys, not route rows.
The complete validator rejects missing/wrong fields before stores; a failed `w1` push leaves
both displays unchanged, a valid `{cups:9}` push writes both to `9`, and a valid snapshot of
`{w1:{cups:2},w2:{venue:'West'}}` commits both before either reader runs. Unknown keys and a
snapshot with one bad widget follow the no-op behavior stipulated for this example. A source
that adds one to decoded cups keeps that transformation in its arm; it is not this generic route.
A route's fields are the decoded layout's release names, not necessarily the source strings
shown here. Nested copy plans use the same generic interpreter and preserve planned identities.

The fixture ledger below is a **future change list**, not permission to bless output in this
PR. Prefixes are `tests/corpus/emit/release/inline/` and `tests/corpus/browser/inline/`.
Every listed emit fixture pins the relevant projection of the code above; every page pins the
observable transcript and retains its development/release comparison. Existing page transcripts
should stay unchanged; emitted output/run hashes change. Development `emit/inline/` piece goldens
must move with the new ABI too.

| Existing emit fixtures to change | Expected shape from the two-widget oracle |
|---|---|
| `WidgetHandler/`, `ArmPiece/`, `ArmSingle/`, `EnumCycleModule/`, `MergedChildren/` | owner `$$root` plus HTML; anonymous group entries, local in-place handler or own-module arm-piece call; no `$$bind`/`$$on` exports; repeated child roots get distinct preassigned plans |
| `ErrorUnreadWidgets/` | route data and one loader as above, schema validation retained with unread errors erased; threshold/shared shape validators retain the same contract |
| `CounterLocal`, `FormLocal`, `EnumCycle`, `MemberReadsWide`, `SingleValueModel`, `TypedMerge`, `PushAndTimer/` | local root scope and `n(groups)`; Main-owned push/tick tails as above; one-value replacement through a cell; controlled input still repaired on empty writes |
| `OldValueAfterWrite`, `SpreadArms`, `SpreadCopies`, `SpreadCopiesBatched`, `SpreadCopiesLookups`, `SpreadCopiesWide`, `SpreadEscapes`, `SpreadWide` | accepted stores use R6 temporaries/hoists before mutation, explicit copies remain explicit, exact whole replacements use cells or checked copy plans; no alias is legitimised by a root closure |

`EmptyElement` and `EmptySandbox` have no dynamic root and need no table/factory solely to fit
this design. Do not mechanically add a closure to static output.

| Existing browser fixtures to rebuild (source basename; directories end in `/`) | Required behavior/projection |
|---|---|
| `CounterLocal`, `FormLocal`, `Counter/`, `Texts/`, `Reader/`, `ResearchS2/`, `ResearchS3/` | the oracle's local groups, cross-reader registration and generic eligible push routes; all existing actions and invalid-push outcomes retained |
| `ArmDefault/`, `ArmEffectOnce/`, `ArmHeldFunction/`, `ArmLetBeforeCase/`, `ArmMessageWhole/`, `ArmNotCase/`, `ArmPiece/`, `ArmSingle/`, `ArmWrapMessage/`, `OneConstructor/`, `OneMessage/` | only proven forwarding keys move; opaque/default/whole-message arms keep their original execution once, then exact groups |
| `PieceLet/`, `PieceLetGroups/`, `PieceRow/`, `PieceTable/`, `FunctionElements`, `EndTags`, `SelectEndTags` | group-local lets and existing markup parser/element facts survive the factory boundary |
| `PlatformElement/`, `PlatformProgram/`, `PlatformReader/`, `PlatformRecord/`, `PlatformTwoLevels/`, `PlatformWidget/` | identical owner/module plan through a project platform layer, no body copied to Main |
| `DefaultTagger/`, `InitCommand/`, `KeysPastCap/`, `LayerStart/`, `PushAndTimer/`, `TopStart/`, `PointerPoint` | handlers published only where needed; starts/init commands occur after registration/first pass; key and event payload semantics unchanged |
| `OldValueAfterWrite`, `SingleValueModel`, `ThrowBeforeWrite/`, `ThrowingRead/`, `ReadDuringDispatch/`, `StopMidDispatch/`, `StopThrowingDisposer/` | hoisted old values, cell reads, throw-before-write, synchronous reads, queued sends and stop/defect behavior retained |

`MissingRoot` and `TwoPrograms/` retain their existing refusal/fault contracts; the rewrite must
not make them successful. Their run hashes are updated only if their emitted bytes change.

New fixtures (the same basename under **both** prefixes unless stated otherwise) have these
specific output and transcript oracles, all with two widgets so an accidental page-wide pass
cannot pass unnoticed:

| New fixture | Required written output and page assertion |
|---|---|
| `RootClosures/` | the complete W1/W2/Main oracle above, including fresh literal `init`; click/input/tick transcript `(-1,'',-1)` → `(4,'',4)` → `(4,'Hall',4)` → `(5,'Hall',5)` |
| `ReaderBeforeWriter/` | W2 factory called first; `i=[[[]],[[]]]` precedes it, W2 appends to `i[0][0]`, W1 appends without overwriting; same displayed values as `RootClosures` |
| `ReaderCycle/` | W1 also appends a reader into `i[1][0]`; neither event names the other factory/binding; each field's event updates its two displays synchronously |
| `ReaderTwoFields/` | one W2 entry reads both `m.w1.cups` and `m.w2.venue`, registered in both buckets; an arm that writes both ends `n(i[0][0],i[1][0])`, and the entry executes once in document order |
| `MainOwnedKeys/` | W1 factory takes a Main handler `h`, wires `on(e[0],h)`; Main arm writes both slices then `n(i[0][0],i[1][0])`; its command/effect occurs once after the pass; Tick and the root event give the same post-pass reads |
| `ValidatedLoader/` | the two route rows and shared `prepare`/`commit`/load code above; valid push, invalid push, unknown/prototype keys, valid snapshot, bad second snapshot member; neither partial writes nor stale cross-reads |
| `PushTransformed/` | Main keeps `decoded.cups+1` and its conditional/error behavior, then `n(i[0][0])`; no route entry pretends this arm is a direct replacement |
| `ReplaceableSlice/` | W1 uses `c[0]`, W2 reads that same cell's current value; a fresh whole-slice replacement updates the cell then `n(i[0][0])`; W2 sees the new value, then the next local edit sees it too |
| `NestedStableLoad/` | route copy-plan data descends into a held nested W1 slice, all validation precedes stores, W2's nested reader updates after push and after the next local event |
| `ControlledNoWrite/` | W2 input's Main handler rejects the user's value with no model write but calls its planned repair bucket; the input returns to `''`, W1's group does not run |

The other new emit goldens write the following deltas to that two-widget program, shown
explicitly to fix the output shape. Each snippet replaces the corresponding part above; it
is not an additional runtime abstraction. The same new pages exercise these variants.

```js
// ReaderBeforeWriter: allocation precedes either call; no R[i]=[] in a factory.
const i=[[[]],[[]]];
W2$root(E2,m.w2,i[1],i,m);
W1$root(E1,m.w1,i[0],i,m);
n(i[0][0],i[1][0]);

// ReaderCycle: W1 also reads W2; W2's original foreign-reader registration stays.
// Inside W1's factory (the additional output element is in its HTML):
i[1][0].push(()=>text(e[2],m.w2.venue));
// The writer handlers remain t.cups=4;n(r[0]) and t.venue=...;n(r[0]).

// ReaderTwoFields: replace W2's foreign entry with this single entry.
const b=()=>text(e[2],`${m.w1.cups}:${t.venue}`);
r[0].push(b);
i[0][0].push(b);
// Main's arm writes both, then one pass (b has one identity in both buckets):
m.w1.cups=4;m.w2.venue='Hall';n(i[0][0],i[1][0]);

// MainOwnedKeys: replace W1's local event with the supplied Main handler.
export function W1$root(e,t,r,i,m,h) {
  r[0].push(()=>text(e[1],`${t.cups}`));
  on(e[0],h);
}
const h=()=>{
  m.w1.cups=4;m.w2.venue='Hall';n(i[0][0],i[1][0]);
  enqueueCommand(commandBody); // existing command host, after writes and pass
};
W1$root(E1,m.w1,i[0],i,m,h);

// PushTransformed: remains Main's code, not a direct-replace route row.
const pushed=raw=>{
  const p=readEvent(raw);
  if(p.ok && p.value.cups>=0) {
    m.w1.cups=p.value.cups+1;n(i[0][0]);
  }
};

// ReplaceableSlice: the entire one-value W1 model is an Int.
// Main owns its cell; both factories receive that same slot explicitly.
const c=[-1];
export function W1$root(e,c,r) {
  r[0].push(()=>text(e[1],`${c[0]}`));
  on(e[0],()=>{c[0]=c[0]+1;n(r[0])});
}
// W2's foreign entry and Main's exact whole-value push tail:
i[0][0].push(()=>text(e[2],`${c[0]}`));
const pushedValue=value=>{c[0]=value;n(i[0][0])};

// NestedStableLoad: W1 captures m.w1.form, whose only field is cups.
// Route data uses the generic copy interpreter's tagged nodes (not new code per root).
const route=[validForm,m.w1,['record',['form',['record',['cups']]]],i[0]];
// The shared interpreter descends before installing cups, preserving m.w1.form.
// W1's local handler is still t.cups=4;n(r[0]); W2 reads m.w1.form.cups.

// ControlledNoWrite: the source rejects W2's typed value; no model store.
// The element's repair dependency selects its existing venue bucket.
const rejectedInput=value=>{n(i[1][0])};
// W2 receives rejectedInput and wires it in place of its local venue store:
on(e[0],v=>rejectedInput(v.target.value),'input');
```

`ValidatedLoader` uses the full shared-loader block above, not a different delta. An accepted
old-value demand (existing `OldValueAfterWrite`) still writes, schematically,
`const old=t.cups; t.cups=4; use(old); n(r[0])`, with the hoist at R5's precise placement;
a two-field swap evaluates both right-hand sides before either store. Neither the runner nor
the root factory may re-inline `old` past that barrier. `ReplaceableSlice` has a second version
where the cell holds a freshly reconstructed record, and its bindings read `c[0].cups`; its
subsequent accepted nested edit mutates that current record, not the pre-push object.

The two-field/order fixtures need an observable ordered probe (the corpus's existing Debug
instrument in its permitted comparison mode), not only text comparisons that could hide double
execution. Cache differential cases belong in `tests/blackbox/build_test.zig`: change only a
writer's HTML/bucket contract, then only a reader's read path, then Main's forwarding/replace
arm, then ownership eligibility; assert warm equals cold and disabled-cache, at both job counts.
The accompanying bad-build fixtures exercise missing retention proof (class 4), unavailable
constructs (class 1/2), the existing class 3 whole-model rule, and ownership's shared/escaped
record errors. They never update a refusal golden to a spread or coarse pass.

**Decisions for the owner (recommendations, not decisions already taken).**

| Decision | Recommendation and rejected alternative |
|---|---|
| Slice versus slice cell | use a direct slice for proved stable records and a cell for semantically replaceable values; never reject an otherwise valid scalar/fresh replacement solely to force a direct record capture. Reject automatic copying of an ownership refusal. |
| Scope of movable handlers | move only keys with proven pure forwarding wrappers; retain Main-owned work as explicit handler parameters. Reject moving a leaf while dropping its enclosing work. |
| Retention and copy evidence | require the explicit root-plan proof above, extending R6/R7's interface if needed before implementation; R5's clean bit alone is insufficient. Reject an unchecked model-holder exemption or invented BIR demand. |
| Multi-field and cross-root ordering | keep D3 and document order with an ordered union of registered groups per tail, deduplicated by entry identity. Reject tea-inline's microtask and immediate independent bucket calls. |
| Generic pushed-state eligibility | factor only proved equivalent replace routes, retaining validation and source transaction boundaries; other arms remain exact Main/arm-piece code. Reject recognising only the helper's name or requiring users to weaken update semantics. |
| Implementation boundary | land the shape only after R6/R7, with cold/warm differential and page/emit evidence together. Keep markup emit-cache misses until plan dependencies can be replayed safely. Reject partial release output that mixes old per-writer reader calls with registration. |

No measurement was made for this amendment. The later implementation still owes #668's S1
byte bar and the owner's comparison; the earlier report's estimates are not a result of this PR.

*Decided 2026-10-23 (the owner, #668's comment of that date): the six recommendations above are
adopted as written.* They are no longer proposals, and this amendment is the implementation
contract of #668:

1. **Slice versus slice cell.** A root holds its slice directly when the root plan proves it a
   stable record; a value the program can replace — a number, a union, a list, a record rebuilt
   fresh — is reached through a cell. A valid replacement is never refused to force a direct
   capture, and an ownership refusal is never answered with an automatic copy.
2. **Movable handlers.** Only a key whose forwarding arms are proved pure — no model write, no
   condition, no command and no effect of their own — has its handler written in its root. Work
   that belongs to `Main` stays there and reaches the root as a handler parameter.
3. **Retention and copy evidence.** A held slice and every generic-loader copy rest on the root
   plan's explicit proof. Where R6/R7's interface cannot express that proof, it is extended
   first. There is no unchecked model-holder exemption and no invented BIR demand.
4. **Ordering.** D3 and document order hold: a tail hands its selected groups to one synchronous
   runner, which runs the ordered union of their entries, each entry once. There is no microtask
   and no run of independent bucket calls one after another.
5. **Pushed state.** The generic loader serves only routes proved equivalent to the source arm,
   validation kept; every other arm stays exact `Main` or arm-piece code. No route is recognised
   by a helper's name.
6. **The implementation boundary.** The whole shape lands at once, with the cold, warm and
   disabled-cache differential and the page and emit evidence of this amendment. No release
   output mixes the old per-writer reader calls with registration. Markup emit-cache misses stay
   until the plan's dependencies can be replayed safely. Preparatory changes that move no emitted
   byte may land before it.

*As built 2026-10-23 (#668): the root closures.* The design amendment above, built whole; the
preceding *as built* rules of §8.3–§8.4 that it reverses no longer describe the compiler. What the
code settled, which the amendment left to the build:

- **The root plan** is `Emit.buildPlans`, serial, after the write-set pass and the pieces pre-pass,
  from the pass's facts (`write-sets.md`, amended 2026-10-23). A program's **roots** are its own
  `view` and each root another module writes as pieces, in placement order: the program's own
  first, then the pieces by their call paths. A piece's **slice** is the exact model path of the
  first argument of its function. A path **keeps its object** when no key's `Key.replaced` path
  may be a prefix of it. Each argument is `held` — a path that keeps its object, handed once as
  that object — `through` — a path below the deepest prefix that keeps its object, handed that
  object and read through it — `cell` — read through the program's model cell, when not even the
  model keeps its object — or `constant`. An argument that is none of these, a value the program
  computes, is refused as a limit of the compiler (§5, class 4; `build/bad/inline/RootComputedArg`).
- **The cell of a replaceable value is its slot.** A value the program replaces — a number, a
  record rebuilt fresh — is read through the nearest object that keeps its identity, whose field
  is the one mutable slot, or through the program's model cell `[model]`, whose one slot the
  handlers write in place of the model's local, when no object of the model keeps its identity.
  The oracle's separate cell `c = [-1]` beside the model is not built: the model's own slot is that
  cell, and every source write lands in it (`browser/inline/ReplaceableSlice`,
  `ReplaceableRecord`).
- **Buckets.** Each read path of the program's read sets is owned by the root whose slice is its
  longest prefix — the first placed among equals — and every other read, the model whole and any
  read not of the model among them, by the program's own `view`. A row is a root that owns a
  read; its buckets are those reads, ordered by `Writes.pathLess`, which is §8.4's structural
  encoding. `groupBuckets` maps a read set to its buckets and `keyBuckets` a key to the buckets
  its writes conflict with, by `Writes.conflicts`, as `sparseConflicts` does for groups. A
  control's repair (§8.3) runs the buckets of the control's own binding entry.
- **Ordinals.** The runtime's `entry(f, buckets)` gives each entry its ordinal as it is made and
  adds it to each bucket of what it reads, one bucket or an array of them. The
  mount makes the program's own entries, then calls each root's factory in placement order, and a
  factory makes its entries in document order, so the order made is the pass order: the program's
  own entries, then each root's — the order §8.3's passes had. Each bucket is filled as entries are
  made, so it is in ordinal order and finalisation sorts nothing. `pass(bucket)` runs one bucket;
  `passes([…])` stamps each entry once and sorts the union by ordinal; `first()` runs every entry
  made at the mount, once, before the subscriptions start.
- **The factory** is `<Module>$<declaration>$$root$<n>`, taking `(elements, holder…, row?,
  table?, handler…)`: one holder per argument of the root's function, its own row when it fills
  it, the program's table when it fills another root's, and one handler per constructor of a key
  that stays the program's, in the order of each one's first event. A root with no binding and no
  event has no factory. The program's own `view` is written in the mount.
- **Moved handlers** (the owner's decision 2). A key moves into the root at the hole whose one
  `Html.map` applies the key's first constructor when the key has two steps; the program's arm for
  that constructor is exactly `{ model | f = W.fn sub model.f }`, reached through calls of the
  module's functions that hand the message and the model on and, for `Tea.element`, as the model
  of a pair whose command is `Cmd.none` (`Emit.forwardOf`); `model.f` is the root's slice and is
  `held`; `W.fn`'s arm piece for the key takes the branch's fields and the slice alone; no
  subscription names the key; and no command of the program runs, which would need every handler
  at the program's dispatcher. Any other key's handler is the program's, handed to the root
  (`browser/inline/MainOwnedKeys`).
- **Pushed state** (the owner's decision 5). A route is what `write-sets.md`'s `findRoutes`
  recognises, amended the same day: a tail of `update` that gives a field `F x model.f`, `F` a
  function whose body is `Result.withDefault D old` with `D` not reading `old` (or, amended
  2026-10-23 below, any function that reads `old` only as a whole tail) — so its result is
  the old value itself, or a value made from `x` alone that holds nothing of it — reached with
  nothing on the way reading the model, every declaration on the way called only there — by its
  own module and by every other. Its site
  is lowered as the loader: a keyed `case` as `load(model, table, key, raw)`, `table` a constant
  of `[key, row]` pairs, looked up by an own-key scan, so `__proto__` and `constructor` are
  unknown keys; an update or a record of every field as `loadAll(model, rows, raws)`, which runs
  every row's function before it copies any result. A row is the constant `[F, field, plan]`: the
  source's own function, which validates and decides between the old value and the new, the field,
  and the copy plan — the record type's fields, each record field with a plan of its own. A result
  that is not the old value is copied into the old object, which keeps its identity, nested
  records descended into (`browser/inline/ValidatedLoader`, `NestedStableLoad`; a transformed
  push stays the program's code, `PushTransformed`). The copy is exact: the old object has no
  holder but the model's slot — nothing on the way to the route reads the model, the model is
  exclusive at the entry (`ownership-checker.md` §31.8), a binding that retains an argument is
  in the push's pass and is evaluated again, and a program whose commands run keeps no route,
  since a command's closure from an earlier dispatch may hold the old object. A field the copy
  writes by assignment — a list, a union, a number — takes the result's value itself, as the
  source's replacement does, so it shares what the source would share and the ownership checker
  judged that sharing; a record field is copied into, so it shares less. So the evidence is
  the route's own proof and ownership's entry exclusivity; R5's table needed no extension
  (decision 3). The write-set pass reads a route site as the copy it is (`write-sets.md`), so the
  model and its routed slices keep their objects in the plan.
- **Retention** rests on `Key.replaced` and the ownership channel's clean bit
  (`Lower.Input.ownership`, `Emit.runWrites`'s `in_place`): an update of a module that is not
  clean, a project's platform layer among them, is trusted to keep nothing, and its program's
  slices are read through the program's model cell (`browser/inline/PlatformWidget`,
  `PlatformReader`).
- **What stays as it was.** A key's pass is the buckets its whole write set reaches, at the end of
  its arm: §8.5's per-tail passes are not built (the write-set pass's per-path sets are not
  either), so a route's row carries no groups and a push runs the buckets of every root its key
  may write, as the pass before this one did. The development output of a piece keeps its arm
  pieces as exports; release fuses a factory used once into the mount.
- **Caches.** App modules are lowered on every build and the plan is made on every build from the
  modules' BIR; the emit pack covers the embedded modules only, none of which is a root's owner or
  a program. `build_test`'s *root closures: warm, cold and cache-less builds agree…* edits a
  writer's markup and buckets, a reader's read path, the program's forwarding arm and a slice's
  identity in turn, with every interface kept, and compares warm, cold and cache-less builds at
  one job and eight, development and release.
- **Evidence.** The new pages and goldens of the fixture ledger above — `RootClosures`,
  `ReaderBeforeWriter` (the reader placed first), `ReaderCycle`, `ReaderTwoFields` (one entry in
  two buckets, run once, logged), `MainOwnedKeys`, `ValidatedLoader`, `PushTransformed`,
  `ReplaceableSlice`, `ReplaceableRecord`, `NestedStableLoad`, `ControlledNoWrite` — whose
  transcripts are, normalised for the platforms' anchors, `browser-tea`'s for the same sources; the
  bad builds `RootComputedArg` (class 4), `RootsSharedRecord` and `RootsPayloadRecord` (the
  ownership checker's record errors), beside the existing class 1, 2 and 3 fixtures; every
  existing `browser/inline/` transcript unchanged.

*Amended 2026-10-23 (#896): a route's function is any function whose result is `old` or holds
nothing of it.* On S1's own programs the root plan's proof failed at N ≥ 16: the generator writes a
widget's `replace` in two shapes, `Result.withDefault (Json.decodeValue state) model` and `case
Json.decodeValue state of Ok new → { … from new … }; Err _ → model`, and only the first was a
route. One widget of the second shape left the `Snapshot` tail a record literal of the model, so
the model, and every slice under it, could be another object after a push: the model was a cell,
every reader read through it, and no handler could move into its root, which needs its slice
`held`. At N = 1 every widget had the first shape. The copy needs only what the first shape gives:
`F`'s result is `old` itself or a value that holds nothing of it. So a route's `F` is any function
that reads `old` only as a whole tail — through `let`s and `case`s that do not read it — or as the
default of a tail `Result.withDefault D old`, every other tail reading nothing of `old`
(`write-sets.md`, amended the same day). The second shape is one: its `Ok` tail is a record made
from the decoded value alone, which the loader copies into the old object as it copies `D`'s
value. A function that reads `old` anywhere else — `Ok new → { model | f = new.f }` — stays a call,
written as the source says. With it, every slice of S1's `unique-components` at N = 1, 16, 64 and
256, seeds 1–3, is held, and each widget's keys move into its root (decision 2): the forwarding
`update msg model = ( step msg model, Cmd.none )` → `step` → `{ model | wN = WN.update m
model.wN }` was already proved pure; only the cell stopped it (`browser/inline/CaseLoader`,
`emit/release/inline/CaseLoader`).

*Amended 2026-10-23 (#896): no store of what the model already holds.* #888 left out two stores
that change nothing (`ownership-checker.md` §31.12, *As built — R7*); the root closures brought
three shapes back. Each is now left out, exactly where the store would change nothing:
- **The handler's `model = next`.** When no key gives the model another object — the plan's proof
  that no key's `Key.replaced` holds a prefix of ρ (`programModelKept`, interface 1.18) — the arm
  wrote the object the model holds, and the handler stores nothing, for an element's pair too. The
  arm still runs, as a statement (`Opt` drops a binding nothing reads, and with it the arm's
  writes), and an element's pair is kept only when its command runs: `l=a=>{K(a,f);t([…])}`, not
  `let b=f,c=K(a,b);f=c`.
- **A field stored back from a call that answers it.** `{ model | w7 = W7.tick model.w7 }`,
  `W7.tick` answering its model or an update of it written in place, writes `W7$tick(m.w7)` and no
  `m.w7 = …` (`ownership-checker.md` §31.12, amended the same day; `emit/release/inline/TickInPlace`,
  `browser/inline/TickInPlace`).
- **The value of a record written in place, discarded.** `c.a=4,c;` — an arm piece's value where
  the handler holds the slice — is `c.a=4;` (`backend.md` §9, *Compact statements*, item 10).
  The residue a `case` arm of the program leaves, `let c; … c=b`, the result's temporary nothing
  reads once the handler stores nothing, is not removed by this amendment.

*Amended 2026-10-23 (#896): the runtime a page ships.* The runtime's group and loader functions are
exports of `Inline.beni`, and dead-export removal already leaves out each one a page does not
call: a page with one bucket per pass ships no `passes` and no sort, and a page with no route ships
no loader and no copy (`emit/release/inline/CounterLocal`, `RootClosures`). S1's pages call them all,
even at N = 1: a key that writes two fields selects two buckets, and the push selects every bucket.
So what changes is what each one costs, and what a pass names. Every change gives the same result
as before:
- `entry(f, buckets)` gives `f` the count of entries once it is in as its ordinal. That is one more
  than its place, so the order is the same. One loop adds it to its buckets, whether `buckets` is
  one bucket or several.
- `passes(buckets)` is `pass(Array.from(new Set(buckets.flat())).sort(byOrdinal))`. Each entry
  runs once, in ordinal order. The pass stamp is gone.
- `load` is `loadAll` of the one row its key finds. `loadAll` maps its rows to their functions'
  results before it copies any of them, as before, and the separate `commit` is gone.
- A pass that selects every bucket of one row passes that row, the array of its buckets. A pass that
  selects every bucket of every row passes `table.flat()`. So the push of a program whose key writes
  every widget is `passes(t.flat())`, not a list of every bucket, which grew with N.

*Amended 2026-10-24 (#916): a run of roots is mounted through one table.* The mount called each
root's factory by name, after it had found the root's elements with `part(E[n])`: about 8 B per
widget on S1 for the lookup, the call and its arguments. Now roots next to each other in placement
order whose factories take no handler and fill their own rows, the rows next to each other in the
same order, are one **run**, and a run of two or more is one call of the runtime's
`roots(rows, elements, from, table, at)`. Row `i` is `[factory, holder…]`, the holders as the
plan hands them; `roots` calls each factory in turn with `part(elements[from + i])`, the row's
holders, `table[at + i]` and the table. A factory takes only what it uses, so the table is ignored
by one that fills no other root's row. `elements` is the `children` of the roots' parent when the
roots are its element children `from` to `from + len - 1` in order — `E` is then not looked up
for them, and not at all when nothing else refers to an element by its place — or else an array of
each root's top element, `[E[n], …]`, with `from` 0. A root that takes a handler (decision 2), or
fills no row, is called by name as before, where it stands, and ends the run.

Nothing a program does changes. Each factory is still called once, in placement order, so the
entries are made, and given their ordinals, in the same order. The holders are reads of the model,
which no factory writes, so reading them all before the first factory runs reads the same objects;
and `part` reads a root's own subtree, which no factory changes before the first pass
(`browser/inline/RootRuns`, `emit/release/inline/RootRuns`). A page with one root ships no
`roots`.

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
| a `*` key (`write-sets.md` §3.4) of an exact inferred whole write of a model whose type is a record of more than one field — by `update`'s annotation, or else by the record literal `init` makes — without a declared `replace` (`plans/direct-rewrite.md` §6): *"Key `Restore` writes the whole model, a record of several fields, in one value, which hides which of its fields changed … Write the fields the arm changes …, or … a declared `replace` once the language has one"* (*decided 2026-10-17, the owner*; `StarUnannotated/` without the annotation). A `*` of lost precision — a cap cut the key, the pass marked the whole write an approximation, or neither the annotation nor `init` gives the model's type — is a limit of the compiler, class 4, reported at the first approximation in source order, which it quotes and says how many more there are (`StarOpaque/`: `f model`; `StarParameter/`: `g m`; `StarRecord/`: `{ next | count = 0 }`; `StarPrecision/`: the cap and its call); a model of one value (an `Int`, a record of one field) is written exactly and accepted, its pass the groups the write-set pass found for that whole write (*amended 2026-10-18, the owner*: no pass calls every binding of the page, and the lowering asserts it; `SingleValueModel`). A key is named as the program spells it, never `(any)` | 3 / 4 | the record's `update`; the approximation | `StarNotReplace/`, `StarUnannotated/`, `StarOpaque/`, `StarParameter/`, `StarRecord/`, `StarPrecision/` |
| a keyed `For`: *"… does not compile keyed rows — a `For` with `keyed` — yet …"* | 1 | the `For` | `ResearchListWidget/` |
| a key whose writes a cap of the write-set pass cut (`Program.Key.cap`): the depth limit `k` and the rounds of a recursive component until #286's folding replaces them; the leaf, alternative and size caps are lifted in S1 | 4 | the record's `update` | `CapFired/` |
| a message wrapped in a constructor of several fields, a field of which the arm binds: *"… wraps another in a constructor of more than one field, and a handler is handed only the inner message's fields …"* | 4 | the field's pattern | `ArmWideWrapper/` |
| another module's markup shown at more than one place: *"… writes another module's markup as pieces for one place only …"* | 1 | the program's hole | `PieceTwice/` |
| an event of another module's markup whose handler value is not one constructor taking the payload or nothing: *"… wires an event of another module's markup to a handler of the constructor it sends …"* | 4 | the event | `PieceEventArgs/` |
| a statement (`_ = …`) in another module's `view` | 1 | the statement | `PieceStatement/` |
| a `let` of another module's `view` read by several holes (a memo node, S3's) | 4 | the root | `PieceLetTwice/` |
| an event argument or a piece capture the program site cannot write | 4 / 1 | the construct | — |
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

### 8.9 Golden bytes against their targets

*Added 2026-10-18, the review of S1's first pull request.* A golden is the compiler's actual
output, and S1's red goldens held the hand-written target; the gap is recorded here, not hidden.
Brotli 11, measured by editing the actual output into each target form one at a time (`plans/` has
no tool for it; the numbers are each edit's own delta against the actual file).

| Golden | Target | Actual |
|---|---|---|
| `CounterLocal` | 510 | 523 |
| `FormLocal`, the program as S1's first commit wrote it (no code or locked field) | 812 | 939 |
| `FormLocal`, as the corpus holds it (two more inputs) | — | 1 002 |
| `PushAndTimer` (S0's pinned bar) | ≤ 589 | 583 |
| `ResearchS2` (pending), its target with core's `Maybe` (the owner, 2026-10-18) | 1 004 | — |

What accounts for the gap, per item:

| Item | `CounterLocal` | `FormLocal` | Kind |
|---|---|---|---|
| `Maybe` boxed as `{$:0,a:…}` / `{$:1,a:null}` (core's representation, kept: the owner, 2026-10-17); tea-inline has no `Maybe` | — | 18 | **a language cost**, like a record spread |
| — the same, in `ResearchS2`'s target: 1 004 against 981 with `null` for `Nothing` (`plans/inline-s1/n1s2-spread.js`, whose `Maybe` is `null`) | — | — | 23, a language cost |
| the enum cycle as a `switch` in a labelled block (`EnumCycle`, pending) | — | 16 | owed by S1 |
| `when`'s anchor through an `=== undefined` branch, where the target has `a.$a ||= new Text` | — | 18 | beni has no `\|\|=`: a finding about the language |
| `prop`'s and `on`'s defaults as `c === undefined ? … : c`, where the target has default parameters | 6 | 17 | beni has no default parameters: a finding about the language |
| `prop`'s constant key read through a binding, `a[c]`, not `a.disabled` | 8 | — | optimiser |
| one read of a field per hole, `let b=f.a,c=f.a`, not one per field | 10 | 3 | optimiser (common reads in one declaration list) |
| S0's `send` alias, `f=e` | 3 | 2 | optimiser |
| the rest: arms through a `before` binding and a spread, a payload alias, the input's `Maybe`-shaped arm, a top-level name each, renaming | — | ≈ 49 | mixed |

The reviewer's other items were measured and declined: a payload alias dropped (`c=b`) moved
`FormLocal` from 1 002 to 1 004, and `!x` for `x ? 0 : 1` costs 13 in this file. A handler whose
key writes nothing still reads its payload: the extractor is `foreign impure`, and only an
interface fact that the key never reads its field would let the lowering skip it.
