# 137 — Ownership and the platform boundary

*Research report, 2026-11-14. A design study, on pull request #2451's branch
(`ownership-v2-design-review`, commit `a982e4641d`). It is not normative, and it changes no code. The
owner asked for a principled answer to one question: most faults of the ownership checker v3 now come
from the boundary between the program and the platforms. Should the work go on as it is? Every
decision this report names is the owner's.*

Words used here, each explained once:

- A **holder** of a list is anything that can still read it: a name, a record field, a closure, a
  cell, a JavaScript object.
- A list **escapes** when it goes to a holder that the checker does not follow. The checker then
  never lets it be written in place.
- A **contract** is what the checker knows about a function without reading its body again: what it
  reads, writes, lets escape, hands to its callbacks, and what its answer holds.
- **Words** are the ownership keywords in a signature of `core/` or a platform (`borrowed`, `stored`,
  `fresh`, `entry`, …). Today the checker believes them without a check.
- A **lowering** is the compiler code that turns markup into JavaScript (`dom`, `inline`, `ssr`).
- The **boundary** is every place where code that the checker does not walk touches the program: a
  platform's runtime, a lowering's output, a schema's workers, derived methods, host JavaScript.
- **Trusted** means: the compiler believes it, and nothing checks it.

---

## 0. Summary (one page)

**The verdict on the current approach.** The interior of the checker is converging. The boundary is
not, and it cannot converge the way it is built. Since the kernel text was written (2026-11-12), the
blind rounds and reviews proved 26 distinct ways to get a stale list. 22 of them are at the
boundary (§2.1). The last reader who did not aim at the boundary found nothing in 19 357
programs (report 132). The next reader, who aimed at it, found a fault in a day (report 133). The
reason is structural. Inside the program, every construct has a rule, and a new kind of instruction
does not compile until each rule has a case for it. At the boundary there is no such closing rule.
The checker holds a hand-written copy of what 36 000 lines of platform code and 8 000 lines of
lowerings do. That code changed in 235 commits in the last 30 days. Nothing makes its authors say
what they keep, and nothing checks the copy against the code. One class of fault (a kept list
compared by identity, #2504) is invisible to the only test oracle. And no build writes a list in
place yet (`core/List.beni:287`), so that oracle is all there is.

**What the faults have in common.** Each one is a fact about code that the checker does not read.
The fact was written by hand inside the checker. It was not derived from that code, and that code
did not state it. Three kinds: the hand rule missed a program shape (a tuple model, a field with no
known code); the hand list missed a caller (`For` rows, a schema's `via`, `--library` exports); or
the platform does not do what the rule says (#2502, #2504, a wrong word on `Js.lt`). A new
experiment for this report
(§2.5) shows why the first kind exists. The entry rule is a special case of something the general
rules cannot do. I wrote the page loop as eleven safe, typed, generic functions in application code.
v3 refused nine of them.

**The recommendation: contracts at the wall.** Keep the kernel. Replace the hand-written model of
the boundary with one rule: *every fact about the boundary is a contract on a named declaration. The
code that makes the fact true states it. The pessimistic contract is the default. A contract is
either derived by the checker or marked `trusted`.* Five parts (§5):

1. **Trust is marked, and words are checked.** Where a declaration has a beni body, its words must
   not claim more than the checker derives from the body. A claim beyond that needs the keyword
   `trusted`. The trusted set is then a list a person can print and review.
2. **The entry becomes an ordinary contract.** The page loop is a *state thread*: `init` makes a
   value, `update` gets it as its own and gives one back, `view` borrows it. The platform declares
   that with words on its record type. One general rule applies it. The checker no longer guesses
   where the model is.
3. **One new primitive, an owning slot.** It is a cell whose content is still owned: take the value
   out, run a function, put the answer back. It compiles to the assignment the runtime has today.
   With it, a typed driver can be walked, and its thread contract can be derived instead of trusted.
4. **A lowering declares what its output does with each value**: reads it while it renders, keeps
   it, or calls a function with its items. The default is "keeps everything". `keeps_let` (report
   134) is the first instance. This settles #2504 without a change to the runtime: `dom` declares
   that a by-reference `For` keeps its items, and the checker refuses an in-place write of such an
   item.
5. **An oracle that sees every class**, before any of the above: the sanitiser traps an identity
   test on a stale list, the sanitised pages run in Chrome, and a build that really writes in place
   exists behind a flag.

No part adds work to a list operation, a row or a DOM node. Part 3 can add one flag test for each
message: 0.36 ns measured (§5.6).

**Alternatives rejected.**

- *Go on as now.* Each round adds a rule to the checker for one more thing a platform does. The list
  of such things is open-ended, and the third kind of fault cannot be fixed that way at all.
- *Ownership types in application code* (Rust, Clean, Hylo). It moves the problem. Platform code
  would still be untyped `Js`, so its signatures would still be trusted. It also breaks rule 7 and
  the finding that only `core/` needs to state a demand (report 69).
- *Value lists plus explicit builders* (Clojure, PureScript `ST`). It is sound by construction and
  removes the boundary problem whole. But it reverses the decision of 2026-10-15: a `push` on a
  shared list would copy in silence, or every loop would need a builder.
- *Teach the checker JavaScript* (analyse `Js` values, host objects, the DOM). A property read can
  run a getter that keeps its receiver, so `Js.get` has no true contract narrower than "unknown
  code" (report 117 §10.1), and the analysis cannot be sound against the host. It would be slow
  and imprecise, and it would follow a moving target.

**What the owner must decide.**

1. Whether platform packages get a `trusted` keyword, and words that the checker checks (part 1).
2. Whether the one rule "a runtime keeps no list from a hole" (`boundary.md` §9.4.8) is replaced by
   what each lowering declares (part 4). A program's verdict can then differ between two platforms.
   That is already so since `keeps_let`.
3. #2504, as a result of 2: declare the keep and refuse the write, or change `dom`.
4. Whether the state slot may carry one flag test for each message, so that #2502's class is a loud
   defect (part 3). The alternative is to trust that no runtime re-enters.
5. The order: the oracle first, and no more blind rounds on the boundary until the trust report
   (part 1) and part 4 exist.

What I am sure of: the diagnosis, and parts 1, 4 and 5. What I am less sure of: how much kernel work
parts 2 and 3 need. Steps 2 and 3 of the plan are the test, and the plan says what to do if step 3
fails.

---

## 1. What was read, and what was run

- `CLAUDE.md`; `ownership-v3-kernel.md`, all of it; `boundary.md` §4.2, §9.4.5, §9.4.8;
  `backend.md` §4 (*The representation: a plain array*, *Every platform edits in place*) and §15.5.
- Reports 116 and 117 in full; the fault lists, reviews and cost sections of 118 to 135; the
  summaries of 68 and 109. Report 136 is not on the branch; I read its draft in the lane that is
  writing it. It is about the budget, not the boundary.
- `TRACKING-ownership-v2.md` (untracked, in the main checkout).
- Issues #2502, #2503, #2504, #2508.
- Code: `core/Js.beni`; `platforms/browser/Rt.beni` (`mount`, the keyed `For`);
  `platforms/browser/Browser.beni`; `platforms/browser-tea/Tea.beni`; `src/markup/Interface.zig`
  (`Lowering`, `keeps_let`); `platforms/browser/zig/dom.zig` (`keepsLet`, the identity tests);
  `src/js/sanitize_runtime.mjs`; the entry and markup functions of `src/own3/`.
- Runs, all on dagon, in `~/.cache/beni-agents/platform-study/`: a Debug `beni` of `a982e4641d`;
  fourteen hand-written programs under `bench/ownership-sweeps/run.mjs --checker=v3` (§2.5, Appendix
  A); counts with `grep` and `git log` (§2.3, §2.4); one micro-benchmark in Node 24 (§5.6).

---

## 2. The diagnosis

### 2.1 The record

The table lists each distinct way to read a stale list that a blind reader or a fix's reviewer
proved on the kernel, from report 117 on. "Boundary" means that the fault needs code that the
checker does not walk. The count is mine, from the reports' own fault lists. Two readers often found
the same class; it is listed once.

| # | Class | Found by | Where it lives | Fixed by |
|---:|---|---|---|---|
| 1 | `init` lets the model's list escape | 118 §4.1 | boundary: entry rule | a checker rule (120) |
| 2 | one new list at two places of the model | 118 §4.2, #2507 | boundary: entry rule | a checker rule (120) |
| 3 | `update` lets a model location escape | 118 §4.3 | boundary: entry rule | a checker rule (120) |
| 4 | the message is not `update`'s own | 118 §4.4 | boundary: entry rule | a checker rule (120) |
| 5 | a derived `eq` calls a writing method | 118 §4.6 | boundary: generated code | a checker rule (120) |
| 6 | a hole's expression runs at render | 117 §9.6, #2505 | boundary: `dom` lowering | a checker rule (120) |
| 7 | markup kept in the model | 117 §9.6, #2506 | boundary: entry rule | a checker rule (120) |
| 8 | a handler in a hole is not escaped | 120 §5 | boundary: markup rule | a checker rule (120) |
| 9 | a list literal handed to `Js` drops its items | 117 §10.3, 120 §5 | boundary: `Js` argument lists | a checker rule (117) |
| 10 | `Js.lt` runs `valueOf`, which can keep | 117 §10.3 | boundary: a wrong word in `core/Js` | the word (117) |
| 11 | a tuple model | 121 §4.1, 122 §3.4 | boundary: entry rule | a checker rule (123) |
| 12 | a record field with no known code (`view`, `settle`) | 121 §4.2, 122 §3.1–3.2 | boundary: entry rule | a checker rule (123) |
| 13 | a closure made in a hole | 121 §4.3 | boundary: markup rule | a checker rule (123) |
| 14 | a `For` row, a key function or a `Show` body keeps its item | 121 §4.4, 122 §3.3 | boundary: the runtime calls the program | a checker rule (123) |
| 15 | the model as an extensible record | 124 F1 | boundary: entry rule | a checker rule (125) |
| 16 | a schema's `via` function | 128 §4.1 | boundary: generated code | a checker rule (129) |
| 17 | the exports of a `--library` build | 129 §2 | boundary: host JavaScript | a checker rule (129) |
| 18 | a method written as a constant (`pub eq = keeper`) | 129 §6 | boundary: generated code | a checker rule (129) |
| 19 | a `let` that the `dom` lowering keeps | 133 §4, #2503 | boundary: `dom` lowering | a checker rule and an interface (134) |
| 20 | the same, for a root that is a component call alone | 134 §7 | boundary: `dom` lowering | a checker rule (134) |
| 21 | `update` runs inside a render (Chrome `blur`) | 117 §9.6, #2502 | boundary: `dom` runtime | **open**; needs a runtime change |
| 22 | a kept `For` item or `Show` key compared by identity | 117 §9.4, 123 §5, #2504 | boundary: `dom` runtime | **open**; deferred |
| 23 | a callback's escaped answer comes back as `own` | 118 §4.5 | interior: fold rule | a checker rule (120) |
| 24 | a function at a default location writes what it handed on | 124 F2 | interior: rule 8 | a checker rule (125) |
| 25 | two deep levels of different cycles paired by label | 125 §6 | interior: the call map | a checker rule (125) |
| 26 | the depth cut of `flow` dropped supplies | 127 | interior: a limit | a checker rule (127) |

So 22 of 26 are at the boundary. The four interior ones were all found by 2026-11-13. The rounds
that found nothing unsound (119, 126, 132) tested mostly ordinary programs. The other findings of the
period are compile time, not wrong answers (119, 126, 128 §5, 133 §5).

On 2026-11-13 and 2026-11-14 the kernel's three boundary rules were rewritten nine times: the
markup rule (§6.12) by reports 120, 123 and 134; the entry rule (§6.13) by 120, 123 and 125; the
list of callers (§6.14) was added by 129 and revised by 131 and 134. The kernel's own note at §5 says it:
"the third time a hand-written list of these callers proved incomplete … Report 129 found a fourth."
The manager's counter of clean rounds is at 0 of the 4 that the owner asked for
(`TRACKING-ownership-v2.md`, 2026-11-14 19:51).

### 2.2 What they have in common

A write in place is safe when no other holder observes the old value (kernel §1). Inside the
program, the kernel derives that from positive facts: every value's cells have names, every consumer
records a read, every holder that the walk does not follow records an escape.

The boundary is where a holder exists in code that the walk does not read. For such code the honest
default is "it keeps everything": every list that reaches it escapes. That default is sound, and v3
has it. `Js.set`, `Js.get`, `Js.call` and `Js.apply` have no words, so what they are handed escapes
(kernel §6.10).

The trouble is that the default is too costly in one place: the page loop. Under it no list of the
model is ever `update`'s own, and the `update` of every real page program is refused (§2.3). So the
checker has **overrides**: rules that say "this code keeps less than everything".
Each override is a claim about platform code. There are four:

| Override | Where | What it claims |
|---|---|---|
| the entry rule | kernel §6.13; `Frame.zig` `entryCall`, `Check.zig` `entryShape` | the runtime holds the model in one place, hands it to `update` as its own, lends it to `view` |
| the markup rule | kernel §6.12; `boundary.md` §9.4.8 | a runtime reads a hole's value only while it renders, and keeps none; it calls rows and keys with items |
| the list of callers | kernel §6.14 | these, and no others, call the program from outside a walked body |
| the words of `core/` and the platforms | kernel §6.10, §7: "its contract is its words whatever the walk found" | what each signature says |

Every boundary fault is one of these four claims being wrong. They are wrong in three ways.

**Kind A: the override does not cover a program shape** (rows 1–4, 7, 11, 12, 15 of the table). The
entry rule is a small ownership analysis, written by hand, for one shape: a record of functions with
the model at a place read off a type. Each fault was a shape that the hand analysis did not handle:
a tuple, a field chosen by `if`, a row variable. The general rules of the kernel handle tuples, joins
and rows already. The entry rule had to learn each again. §2.5 shows why it exists at all.

**Kind B: the list misses a caller or a holder** (rows 5, 6, 8, 9, 13, 14, 16–20). Somebody outside
a walked body calls the program or keeps a value, and no rule said so. Report 129 made the list of
callers something read off the backend, and report 134 made the `dom` lowering say which `let`s it
keeps. Those two fixes are different in kind from the others: they move the fact to the code that
knows it, with "keeps everything" as the default. They are the pattern this report recommends.

**Kind C: the platform does not do what the override says** (rows 10, 21, 22). `Js.lt` had the word
`unused` and ran `valueOf`. The `dom` runtime runs `update` inside a render. A by-reference `For`
keeps each old item and compares it with `Js.same` (`platforms/browser/Rt.beni:1342-1350`). No rule
in the checker can fix these. Either the platform changes, or the override gets weaker.

### 2.3 What the overrides buy

Of the 308 real list writes that v1 judges, 16 rest on the entry rule (report 117 §4, ground
`entry`). Thirteen of them are an `update` of a page program that writes a list of the model that
its `view` shows (report 117 §5). Every page program has one. The other 292 writes need no
override.

So the boundary model is not there for speed. A copy of a model list for each message costs less
than the render that follows it. The model is there so that the most common line of a page program,
`{ model | todos = List.push model.todos t }`, builds without a `List.copy`. That is the owner's
rule: a safe real program is never refused. The price of that one line is all of rules 12 to 14.

### 2.4 Why the interior converges and the boundary does not

**The interior has a closing rule.** Every `switch` over a kind of value, root, source or
instruction in `src/own3/` has no `else` (kernel §3.3, §9). A new kind does not compile until each
reader has a case. A fact that no rule derives is the pessimistic one. So the set of things to get
right is finite and written down, and a reader who attacks it finds less each round.

**The boundary has none.** The model is a second, informal copy of what the platforms do. Its size:

| | Lines | Changed in the last 30 days |
|---|---:|---|
| `platforms/*.beni` | 36 284 | 235 commits, 38 601 lines added, 14 679 removed |
| of which lines that use `Js.` | 5 990 | |
| the three lowerings (`platforms/*/zig`) | 7 994 | 71 commits |
| the checker (`src/own3/`) | 9 660 | |
| the kernel text | 919 | rules 12–14 rewritten nine times in two days |

When a platform author adds a cache, a kept key or a new callback, nothing asks what it keeps. The
kernel says so itself (§6.14, *What it cannot catch*): "a contract of `core/`, a platform or a
`foreign` that is wrong; and a lowering that changes which calls run or their order. Each of those
is a row of the table above, and a new one must be added to it by hand."

**The platform code is untyped.** `Rt.beni` is JavaScript written in beni syntax. `mount` has the
type `V, V → ⊤`. The program's record is a `V`, the model is in a `Js.ref`, and `update` is called
with `Js.call program "update" [ msg, Js.read model ]` (`Rt.beni:788-832`). The checker does walk
platform code, but from this code a walk can derive only "everything escapes". So the override
cannot be checked against the code it describes. Even `browser-tea`, which is 742 lines of typed
beni with one line of `Js`, is believed by its word: `Tea.element` says `entry`, and the checker
reads the type, not the body (`Tea.beni:57-70`). It finds the model as "the type variable of the
last parameter of the field named `update`" (`Check.zig:616-630`, `own2/Prepass.zig:360`): a fact
by a name, which the kernel forbids everywhere else (§6.11).

**The oracle is partly blind, and no build writes in place.** The sanitiser copies on each accepted
write and poisons the old list. A read of the old list traps. An identity test does not: the copy is
a new object, so `old === new` is false in the sanitised build and true in a build that writes in
place. Report 117 §9.5 broke `forKeyed` on purpose with an identity skip, and no fixture failed.
`List.push` still copies below 32 elements and uses the trie above (`core/List.beni:287-299`), so
there is no build in which that fault can show. And #2502 does not show under happy-dom, because
happy-dom fires no `blur` on removal.

**So the rounds measure the reader, not the code.** Report 116 §4 said that of v3 before the
kernel. It is no longer true of the interior. It is still true of the boundary.

### 2.5 An experiment: the entry rule is a missing general capability

The page loop is a fold. `init` makes a model. For each message, `update` takes the model and
answers the next one. Between two messages, `view` reads the model. If the kernel's general rules
could judge that loop, the entry rule would not be needed: the platform's driver would be an
ordinary function with an ordinary contract.

I wrote the loop as typed beni in an **application** module on `node`, where no entry rule applies,
and judged it with `--ownership=v3 --ownership-everywhere --sanitize-lists`. `update` pushes onto
`model.items` in place. Each "safe" program keeps only the text that `view` answers. Each "live"
twin keeps the model and reads it after. Appendix A has the programs.

| Program | How the loop is written | Twin | v3 |
|---|---|---|---|
| `inline` | in `main`, with `init`, `update` and `view` named in the fold's lambda | safe | **accepted** |
| `inline` | the same, the fold keeps each model | live | refused |
| `upd-generic` | `drive : (msg, model → model), model, List msg → model`, the first model an argument | safe | **accepted** |
| `bare-fold` | `drive ini upd msgs = List.foldl msgs (ini ⊤) λmsg m → upd msg m` | safe | refused: "the callee hands the function the answer of another function" |
| `upd-only`, `upd-direct` | the same with `init` named inside `drive` | safe | refused: `later-use` |
| `upd-view`, `sep-concrete` | `drive` also takes `view` and calls it between steps | safe | refused: "the function writes a parameter that the callee reads again or does not hand as its own" |
| `rec-concrete`, `fold-record` | `drive` takes a record `{ init, update, view }` | safe | refused: "a function that writes its parameter goes where the checker does not follow it" |
| `ref-cell`, `ref-inline` | the model in a `core/Ref` between steps | safe | refused: `supply` |
| `sep-concrete`, `rec-concrete` | the driver keeps each model | live | refused |

Eleven safe programs, two accepted. Three live twins, all refused. Nothing unsound. But the general
rules lack three things, and the entry rule is exactly those three, written for one shape:

1. **A state thread through two function parameters.** The answer of one function parameter
   (`init`) is handed to another (`update`) as its own, and `update`'s answer is handed to it again.
2. **A borrowed look between two steps.** `view` reads the state, and the state goes back to the
   thread.
3. **A function in a record field followed as a function parameter is.** Today it goes to the
   default location, where it may write nothing (report 126 §5 lists this as a precision loss).

And the runtime needs a fourth thing that an application does not: the state lives in a cell between
two host callbacks. In the kernel, what goes into a cell has escaped (§3.1). So a driver that holds
the model in a cell can never hand it out as owned.

This explains kind A. The entry rule is not a description of the platform. It is a private copy of
a general analysis that the kernel does not have, with its own code for tuples, joins and rows. Its
faults were the faults of a second implementation.

### 2.6 The deeper tension, stated once

Rule 8 of `CLAUDE.md` says that the UI is as fast as Solid because values are immutable, so an
untouched value is the same object, and one `===` for each hole is enough. The list decision of
2026-10-15 says that lists are written in place. These two meet at the boundary. An in-place write
keeps the object and changes the content, so `===` no longer means "unchanged".

`backend.md` already draws the consequence (§4, *What every runtime keeps*, invariant 8; §15.5,
amended 2026-10-15 and 2026-10-17): no runtime decides "unchanged" from the identity of a list, nor,
once records are written in place, of anything that holds a record. It names `browser-inline`,
whose updates follow write sets, as the target. #2504 is the `dom` runtime not yet brought to that
amendment. The cost of the amendment for `dom` is "still to be measured" there.

This report does not reopen that decision. It matters here for one reason: the set of things a
runtime may keep is getting smaller and more subtle, the runtime that must obey it is 2 500 lines of
untyped code, and nothing checks it.

---

## 3. The options

For each: how it works, what it guarantees, what stays trusted, what it costs, and what moving to it
takes.

### 3.1 Go on as now: a hand-written model, made stricter each round

**How.** Blind readers attack; each fault adds a rule to the checker or a row to §6.14.

**Guarantee.** None that can be stated. The theorem of kernel §5 holds "if the list of §6.14 is
complete and each platform keeps `boundary.md` §9.4.8", and both conditions are checked by reading.

**Trusted.** All platform code (36 284 lines), the three lowerings, every word, and the checker's
copy of what they do.

**Cost.** No run-time cost. The cost is time and risk. Each fix round took hours (the tracking file
has 260 minutes for one). Kind C faults stay open. Every new platform feature is a new chance of a
silent wrong page, and the oracle cannot see one class of them.

**Is it converging?** For kinds A and B, slowly: the list of callers is now read off the backend,
and that part is close to done for today's code. It does not stay done, because the platforms
change every day. For kind C, no.

**Verdict.** Stop this for the boundary. Keep the rounds for the interior, where they work.

### 3.2 The checker checks the platforms' own code

There are two readings of this option.

**(a) Analyse the untyped code: follow `Js` values, host objects, the DOM, identity tests.** This is
a pointer analysis of JavaScript, written in beni syntax. It cannot be sound against the host: a
property read can run a getter or a proxy trap that keeps its receiver (report 117 §10.1), and a
host object can hold anything. To be useful it would need a model of the DOM and of the event loop,
which is a hand-written model again, only larger. It would be slow: host objects have no types, so
there is no bound on locations of the kind that makes v3 fast (report 109). I reject it.

**(b) Walk platform code that is typed, and believe only what the walk derives.** The checker walks
platform modules already. For typed beni the walk derives a real contract: `Tea.beni`'s helpers
(`tableInsert`, `step`, `perform`) get contracts as any function does. What is missing is small:

- the walk's result is thrown away where a declaration has words (kernel §7);
- the code that carries program values is typed `V`, so the walk can derive nothing from it;
- the kernel cannot express the page loop (§2.5).

Fix those three, and the checker derives the boundary's contracts wherever the code is typed, and
marks the rest. That is parts 1 to 3 of §5. What it needs to "understand" of the host is nothing: a
value that goes into `Js` escapes, as now. Identity needs no rule of its own, because a test of an
old reference against a new one needs a kept reference, and a kept reference is an escape or the
slot.

**Trusted after (b).** `foreign` declarations; declarations marked `trusted`; the lowerings.
**Cost.** No run-time cost, if typed platform code compiles to the JavaScript that `Js` calls
compile to today. I argue in §5.6 that it does, and step 3 of the plan measures it.
**Precision.** Better than now where the kernel gains the state thread. The same as now elsewhere.

### 3.3 Change beni

Each idea, weighed against rule 7 (*guarantees, not restrictions*) and "never refuse a safe real
program".

| Idea | What it would give | Weighed |
|---|---|---|
| **Ownership or uniqueness types in every signature** (Rust, Clean's `*`, Hylo's `inout` and `sink`, Mojo, Swift) | checking for each function alone; a fault is local | It does not solve the boundary: platform code is still `Js`, so its signatures are still claims. It adds a burden on every developer, and it would refuse programs that liveness accepts today (report 109 §4). Report 69 found that the demand needs to be written only in `core/`. **No.** |
| **A distinct type for a list that may be edited** (`Buffer a`, a `mut` local, a builder) with `List` always a value | soundness by construction: a builder is linear and local, and never crosses the boundary; no holder analysis, no boundary model | This is how Clojure (transients), PureScript (`ST`), Scala and Haskell do it. It is the cheapest sound design. It reverses the owner's decision of 2026-10-15: a `push` on a `List` would copy in silence, or not exist. **Rejected by a standing decision**; I name it because it is the floor to compare every cost against. |
| **A borrow or loan form in the language** | a developer could lend a list to a function | The contracts already carry "read, not kept". No developer needs to write it. Platform code needs one scoped form, and part 3 gives it as a library function, not as syntax. **Not in the language.** |
| **An explicit "frozen" view** | a value that nobody may write, safe to keep and to compare by identity | The kernel has it: an escaped cell is never written. A surface form would add nothing. **No.** |
| **Regions** (Cyclone, MLKit) | a lifetime for "while it renders" | The render is one function call in the driver. A function that lends a value for the time of a callback is a region with no new syntax (part 3's `lend`). **As a library function only.** |
| **Words in platform signatures, checked** | the boundary states its contracts in the language | The words exist. Checking them and marking trust is new. **Yes: part 1.** |
| **Optional words in application signatures**, as checked promises | a developer could pin "this function takes its list as its own", and get an error at the function, not at a far caller | It is a capability, not a restriction. It is not needed for the boundary. **Later, if error quality asks for it.** |

So beni changes for platform authors only. An application developer writes nothing new.

### 3.4 Change the platform language

| Idea | Weighed |
|---|---|
| **A lower-level dialect** | `Js` is that dialect already: `Js.get o "f"` is `o.f` and nothing else (`core/Js.beni`, header). Nothing to add. |
| **A different `Js` surface** | The surface is right as the *untyped* side. Its rule is simple and sound: what goes in escapes. Two changes: an owning slot beside `Js.Ref` (part 3), and typed reads of a list (`List.length`, an indexed read with the word `borrowed`), so that runtime code can read a program's list without a cast to `V`. |
| **Typed host handles** | `Js.Ref a` is one. `Slot a` is the second. A handle for a DOM node is not needed for ownership: a node holds no list unless one escaped into it. |
| **An ownership-aware FFI** | It exists in the words. It lacks the check and the mark of trust (part 1). |
| **An effect-aware FFI** | It exists (`sync`, `pure`, `impure`, `suspends`). One use is open (§7): if a platform's type asked that `view`, a row and a key function be `pure`, they could keep their argument nowhere but in their answer, and rows 13 and 14 of §2.1 could not be written. |
| **Linear host references** | The slot is the one linear reference the page loop needs. |
| **A small trusted kernel, everything above it checked** | Yes. This is the recommendation. |

**Which of the 36 284 lines must stay trusted?** Three groups:

1. Code that never holds a program's list: most of `Gpu/` (about 12 000 lines), `Http`, `WebSocket`,
   `Image`, `Video`, the Node and Cloudflare wrappers. A program value that reaches them goes into
   `Js` and escapes. They need no trust beyond the rows of `core/Js` being true.
2. Code that holds program values and claims less than "escapes": the drivers (`mount`, `host`,
   `Tea`'s four entries, the two `Worker.program`s), the markup runtime's list readers and rows, and
   `Hosted`'s command and subscription plumbing. My estimate is one to two thousand lines. I did not
   measure it; step 1 of the plan does.
3. The lowerings' Zig, behind the interface of part 4.

The floor of trust is then: the 11 JavaScript files of `core/` (164 lines), the 65 `foreign`
declarations of `core/`, the rows of `core/Js`, the declarations of group 2 that stay untyped, and
the lowerings' declared effects.

### 3.5 Other suggestions

- **Simplify the goal at the boundary only.** Delete all four overrides and take the default: every
  list that reaches a runtime has escaped. It is sound today, with no model at all. It costs the 16
  entry writes: every page program writes `List.copy` in `update`. That breaks "never refuse a safe
  real program", so I do not recommend it. But it is the right **fallback inside** the
  recommendation: a platform that declares nothing gets exactly this.
- **Change the order of work.** Build the oracle first (part 5). Today a reader must find by thought
  what a test could find by running.
- **Follow the target platform.** `backend.md` §15.5 names `browser-inline` as the target. There the
  compiler generates the driver, so the boundary is the compiler's own output, which part 4 covers
  best. If `dom` is on the way out, do not spend on typing `Rt.beni`; declare its keeps and move on.

---

## 4. Prior art, and what each teaches beni

Reports 68, 69, 71 and 109 survey ownership inside a language. This section is about the boundary.

| System | What it does at the edge | What beni can take | What it cannot |
|---|---|---|---|
| **Koka** (Perceus; `fip`, ICFP 2023) | Reuse in place is decided at run time by a reference count of one. `fip` is a static check that a function is in place *if* its arguments are unique; borrowed parameters are marked `^`. | The shape: "in place" is a contract of one function, with owned and borrowed parameters. v3's contracts are that. | The half that makes it easy: Koka never proves that the caller's value is unique; the count says so at run time. That missing half is where every beni hole is. |
| **Lean 4** | The same counts. Borrowed parameters are inferred inside Lean; at an `extern`, a parameter is owned unless written `@&`. | The default at the foreign boundary is the costly, safe side (ownership passes), and the cheaper fact is written down by the author. beni's "no word means escaped" is the same rule. | The counts. |
| **Roc** | Counts; an alias analysis picks in-place versions. The host gets values with their counts under a fixed ABI. Roc had uniqueness types and removed them. | The host boundary is an ABI with a stated ownership convention, not something a compiler pass rediscovers. | The counts. |
| **Clean** | Uniqueness types, inferred, with the demand written on primitives. The world is a unique value: `Start :: *World -> *World`. | The program's state at the entry is a unique value **in a type**. The page loop is `*World` threading. That is part 2: the thread is a contract, not a rule. | Attributes on user data types. |
| **Rust** | Checks each function against its signature. `unsafe` marks what is trusted; `UnsafeCell` is the one primitive under all shared mutation; a safe API around `unsafe` is the author's proof duty (RustBelt). Miri runs the unsafe code against the aliasing model. | Three things. Trust is marked, small and searchable (part 1). One primitive carries the exception (part 3). And trusted code has a dynamic checker (part 5: the sanitiser is beni's Miri, and it must see every class). | Signatures on all code. |
| **Swift** | `borrowing`, `consuming`, `inout`. Exclusive access is checked statically where it can be and **at run time** where it cannot (class fields, escaping closures). | A precedent for one cheap dynamic check exactly where static reasoning ends: a flag on a heap cell. Part 3's guard is that. | Copy-on-write by count. |
| **Mojo** | Argument conventions (`borrowed`, `inout`, `owned`) on every function. | The unit of the contract is the parameter. | Written conventions everywhere. |
| **Hylo** (mutable value semantics) | No reference escapes into the heap. A value stored for later is moved in (`sink`) or copied. | The rule for a kept value: keeping is consuming. beni's "what a runtime keeps has escaped" is the same law, and the slot is `sink` then take. | Its ban on stored references: beni has closures and cells. |
| **Vale** | During a pure call, a whole region is immutable. | A scope bounds what can happen to a value: while `view` runs, the model is lent. Purity bounds what a callee can keep (§7). | Generational references (a run-time check for each access). |
| **Austral** | Linear types with a checker small enough to audit, and capabilities for the FFI. | The trusted part of a checker should be small enough to read in one sitting. Rules 12 to 14 are not. | Linearity written by the developer. |
| **Linear Haskell, Granule** | A pure API over a mutable array: `alloc : Int → (MArray a ⊸ Ur b) ⊸ Ur b`. Uniqueness holds **by construction**: the callback is the only holder. | The owning slot. The platform gets "one holder" from the shape of an API, not from a search over all holders. | Linear arrows in user types. |
| **Cyclone** | Regions, and unique pointers inside shared structures, reached only by an atomic swap. **MLKit** infers regions with no errors and no annotations. | The swap: the one sound way to take a unique value out of a shared cell. Part 3's `step` is a swap around a call. | Region annotations. |
| **OxCaml** | Modes are inferred inside a module and written at its interface. Plain data "crosses" modes. | Infer inside, declare at the edge. `identitySafe` in the `dom` lowering is mode crossing. | The lack of mode polymorphism. |
| **Futhark** | Uniqueness on parameters (`*[]`). Its author's 2026 warning (report 68): alias reasoning in a type system explodes in complexity. | Keep the alias reasoning in one small kernel and do not let it spread into special rules. | — |
| **ReScript** | `external` bindings: typed, trusted, zero cost. Arrays are mutable and aliasing is visible. | Nobody checks FFI code. Everybody **declares** it. | Visible aliasing. |
| **PureScript** | `foreign import`, trusted. Mutation through `ST` with a rank-2 region; `unsafeFreeze` and `unsafeThaw` are zero-copy and say "unsafe" in their names. | The trusted conversion has a name that can be searched for. | `ST` in user code. |
| **Elm** | Kernel JavaScript only for the core team; everyone else uses ports, which copy. `Html.Lazy` compares by reference, which is sound because nothing is ever written. | The wall is the same as beni's rule 6. And the lesson of §2.6: reference tricks in a runtime are sound **because** of immutability. Each one must be argued again once a write in place exists. | Copying at the boundary. |

Three lessons recur. **Nobody verifies foreign code; every sound system makes it declare, and marks
the declaration as trusted.** **The exception to the rules lives in one primitive** (`UnsafeCell`,
the swap, the linear callback). **Where static reasoning ends at a heap cell, one cheap dynamic
check is the accepted price** (Swift, `RefCell`, Cyclone).

---

## 5. The recommendation: contracts at the wall

### 5.1 The principle

> Every fact that the checker uses about code it does not walk is a contract on a named
> declaration. The code that makes the fact true states it. A declaration that states nothing has
> the pessimistic contract. A contract is derived by the checker from a beni body, or it is marked
> `trusted`. No rule of the checker names a platform's concept.

It is the kernel's own principle (§1: a fact that no rule derives is the pessimistic one), applied to
the one place where it is not applied yet. Kernel rules 12, 13 and 14 then stop being rules. They
become uses of rule 2 (a call) and rule 10 (a trusted contract).

### 5.2 Part 1 — trust is marked, and words are checked

**The rule.** For a declaration with ownership words:

- If it is `foreign`, its words are trusted. Nothing changes.
- If it has a beni body, the checker walks the body, as it does now, and compares. The words may
  claim **less** than the walk derived (they may say `escaped` where the walk found a read). If they
  claim **more**, the build fails with a new error, unless the declaration starts with the keyword
  `trusted`.
- `trusted` is allowed only where `foreign` is: in `core/` and in a platform package (rule 6).
- A command prints every trusted contract of a build: the declaration, its words, and what the walk
  derived. The count is tracked, as output size is.

**What the platform author writes.**

```text
-- derived: the body is typed beni, so no keyword is needed, and the words are checked
focus : written returned List a, borrowed Int, once taken stored (a → a) → List a

-- trusted: the body goes through Js, the walk derives "everything escapes", the author claims more
trusted compare : borrowed Key, borrowed Key → Order
```

**What it gives.** A wrong word in typed platform code becomes a compile error, not a blind reader's
finding (row 10 of §2.1 was a wrong word). The claims that stay are few, visible, and reviewed like
`unsafe`. `Tea.element`'s `entry` is then either derived from `Tea.beni`'s body or visibly trusted.

**Cost.** One comparison of two contracts for each worded declaration. No run-time cost.

### 5.3 Part 2 — the entry is an ordinary contract: the state thread

**The contract.** A callee may hold a **thread**: a value that it hands to its function parameters
and takes back. The contract says, for each function parameter, how it meets the thread:

- `gives`: its answer (or one item of an answer tuple) becomes the thread's value;
- `own`: it is handed the thread's value as its own;
- `borrowed`: it is lent the thread's value, and the callee takes it back.

**What the platform author writes.** The word `entry` and the guess behind it go. The record type
says where the thread is:

```text
pub trusted program :
      { init : sync (⊤ → gives model)
      , update : sync (msg, own model → gives model)
      , view : sync (borrowed model → Html msg)
      }
    → Program

pub element :
      { init : ⊤ → gives model × Cmd msg
      , update : msg, own model → gives model × Cmd msg
      , view : borrowed model → Html msg
      , subscriptions : borrowed model → Sub msg
      }
    → Program
```

The three words are a sketch. `core/Ref` already has `consumed` and `lent` with close meanings, and
the final spelling is a detail of the specification.

**What the checker does.** At a call of such a function, with a record written at the call, each
field is a function parameter. The checker computes which locations of the thread are owned, as the
largest solution, exactly as `entryCall` does today (kernel §6.13): a location is owned only if
every `gives` source of it is a new cell that did not escape or an owned thread location handed on,
and no `borrowed` function lets it escape, writes it or answers it into something that is kept. A
field with no known code, a field the type does not word, or a record not written at the call takes
the default: no location is owned. The message is a plain parameter, so it is never owned.

**What is deleted.** `Mod.entryShape` (the guess of where the model is from a type variable's
position), `isView`, and the entry-only code for tuples and rows in `entryCall`. Rows 11 and 15 of
§2.1 were faults of that guess. The fixed point stays, as the general rule for a thread contract.

**What it gives beyond the platform.** The same rule judges a developer's own generic driver, once
the walk can derive a thread contract from a body (step 3 of the plan). The eleven safe programs of
§2.5 are then accepted. And the rule can be attacked on `node` with thousands of generated programs
a minute, which the entry rule, needing a page, never could.

### 5.4 Part 3 — one primitive: the owning slot

**The problem it solves.** A runtime holds the model between two host callbacks. A value in a cell
has escaped, so a walked driver can never show that it hands the model out as owned. And nothing
stops a runtime from running `update` while a render still reads the old model (#2502).

**The primitive**, in `core/`, usable only by platform packages:

```text
pub foreign type Slot a

-- The slot becomes the one holder of the value.
pub foreign pure new : consumed a → fresh Slot a

-- Take the value out, run the function on it, put the answer back.
pub foreign impure step : borrowed Slot a, once sync (own a → gives a) → ⊤

-- Lend the value to the function. Its answer may hold none of the value.
pub foreign impure lend : borrowed Slot a, once sync (borrowed a → b) → b
```

`Slot` is opaque, so `step` and `lend` are the only ways to reach the value. It compiles as `Js.Ref`
does: to a `let` where it does not leave the function that made it (`backend.md` §4, *A `Js.Ref`
that does not escape is a `let`*), and `step s f` is `s = f(s)`.

**The guard.** `step` or `lend` while another `step` or `lend` of the same slot runs is a defect. I
recommend one flag in the slot, tested and set by each. It costs one test for each message and each
render, and nothing for a list operation, a row or a node. It makes #2502's class a crash screen in
development and a stopped page in release (the decided defect rule), never a stale page. The other
choice is no flag and a trusted promise that a runtime never re-enters. That promise is false in
Chrome today.

**What the platform author writes.** The typed driver. A sketch of `mount`
(`Rt.beni:788-832` today, 35 lines of `V`):

```text
mount : { init : sync (⊤ → model), update : sync (msg, model → model), view : sync (model → Html msg) }, Node → ⊤
mount app root =
    state = Slot.new (app.init ⊤)
    render = λ⊤ → Slot.lend state λmodel → childHtml (slot root) (app.view model)
    Js.set root "$$root" (Js.from λmsg →
        Slot.step state λmodel → app.update msg model
        schedule render)
    render ⊤
```

**What the checker does.** It walks `mount`. The closure goes to JavaScript, so it is in the default
location; inside it, `app.update` is handed the slot's value as its own and its answer goes back, and
`app.view` is lent it. That is a thread contract, derived. `program`'s words (part 2) are then
checked against it (part 1), and the keyword `trusted` comes off.

Parts 2 and 3 are separate on purpose. Part 2 alone makes the entry a declared, trusted contract in
the general language. Part 3 makes it a derived one. A platform can stop after part 2.

### 5.5 Part 4 — a lowering declares what its output does

**The rule.** The markup interface (`src/markup/Interface.zig`) gets one more function beside
`keeps_let`. For each value at each item of a markup node, the lowering answers with one or more
**effects**:

| Effect | Meaning for the checker |
|---|---|
| `reads` | read while the markup renders, and not after: the markup holds the value until then (today's rule 12) |
| `keeps` | held after the render, to be read or compared later: the value escapes where the markup is made |
| `calls f with items of v` | a call of `f` with each item, applied as at a call site (rule 2) |
| `calls … and keeps the items` | the same, and each item escapes |

The default, for a lowering that says nothing, is `keeps` for every value and "keeps the items" for
every call. So a new lowering, or a new markup form, is sound before anybody thinks about it.

**What `dom` would declare.** An event's handler or message: `keeps` (as today). A text hole, a
class list, a helper's arguments: `reads`. A `For` with a key function whose keys hold no list:
`calls row`, `calls key`. **A `For` by reference, and a `Show` keyed by identity: `calls … and keeps
the items`.** That is the truth about `Rt.beni:1342-1350`, and it closes #2504 with no change to the
runtime: a write in place of an item that such a `For` shows is refused, with a message that names
the `For` and offers a key or `List.copy`. The outer list is still owned, because the slot keeps no
list (`backend.md` §15.5). If `dom` later stops keeping items, it changes its declaration and the
writes come back.

**Where emit and declare can be one call, they are.** A lowering reaches the runtime through
declared exports (`RuntimeExport`, `boundary.md` §9.4.5). Give each export that takes a program's
value a typed signature with words, and let the interface's "call this export with this value" both
emit the call and record the effect. The lowering then cannot emit such a call that it did not
declare. For a value that a lowering stores inline (as `d<k>` for a kept `let`), a safe-build check
compares the declaration with the emitted store, as report 134 did for `keeps_let`.

**The same for the compiler's own generated code.** A derived `eq`, a schema's workers, a codec, the
exports of a `--library` build, a suspendable twin: each is emitted by a few functions of
`js/Lower.zig` and `js/SchemaLower.zig`. The function that emits "a call of a program's declaration"
that is not the lowering of a call instruction takes the contract of the caller as an argument.
`checkCovered` then also covers what kernel §6.14 says it cannot: a call with no instruction behind
it cannot be emitted without its rule.

**What changes in the documents.** `boundary.md` §9.4.8 stops being one rule that every runtime must
keep and that an audit checks. It becomes: "a runtime does what its lowering declares, the default
is that it keeps everything, and one fixture for each declared effect shows it". Its list of known
breaches becomes a list of declarations.

### 5.6 What it costs

**Run time.** No part touches a list operation, a row, a patch or a node.

- Parts 1, 2 and 4 are compile-time only.
- Part 3, typed driver: `app.update msg model` compiles to the call `app.update(msg, model)`, as
  every beni call is saturated with no calling convention (`backend.md` §6), and
  `Js.call program "update" […]` compiles to the same call. Under `--release` a typed field gets a
  short name, and a name written in a `Js.call` string does not (`core/Js.beni`: "a property name is
  never renamed"). So the typed driver should be the same size or smaller. I did not build it; step
  3 measures it against the 1.4 kB empty page and the benchmark app.
- Part 3, the guard: I measured a dispatch with and without the flag in Node 24 on x86-64, 2·10⁸
  dispatches, the median of 7 runs: 7.42 ns and 7.78 ns. **The flag costs 0.36 ns for each
  message.** A render is five to six orders of magnitude more.

**Size.** The slot is the `let` that `Js.Ref` is today. The flag is a few bytes once. Nothing else is
emitted.

**Precision.** It rises where the kernel learns the thread (§2.5: functions in a record, generic
drivers). It falls only where a platform really keeps something and now says so. Those refusals are
correct.

**Checker speed.** One contract comparison for each worded declaration. The thread rule does the
work that `entryCall` does now, under the same budget. Some special code goes.

**Developer burden.** None for an application developer. A platform author writes `trusted` where a
claim is not derived, words on entry records, and one function in a lowering.

### 5.7 Why it is sound

**Claim.** Assume (T1) every `trusted` contract and every `foreign` row is true of its code; (T2)
each lowering's output does only what it declared; (T3) the slot's guard is on. Then a program that
the checker accepts prints what the copying program prints.

**Argument.** The kernel's theorem (§5) needs three things of code that the walk does not read.

1. *Every call into the program is applied by a rule.* A call comes from a walked platform body
   (rule 2, with a derived contract), from a trusted declaration (its contract, T1), or from
   generated code (its declared effect, T2). There is no fourth kind, because the emit functions
   take the declaration as an argument (part 4). Today this is the hand-written table of §6.14.
2. *Every holder that the walk does not follow records an escape.* A value that reaches untyped code
   goes through a `Js` operation with no word, and escapes (kernel §6.10). A value that a lowering's
   output keeps is declared `keeps`, or the default says so (T2). The only holder that keeps a value
   without an escape is a slot.
3. *A slot's value has no other holder.* The type is opaque, so the value is reached only through
   `step` and `lend`. Each value put in was handed over as owned (`gives`, checked as a demand where
   it is made). `lend`'s function may let nothing of it escape; where its contract shows that it
   does, that location is taken out of the owned set, by the same largest-solution argument as
   kernel §6.13. `step` hands the value out while the slot holds nothing, and T3 excludes a second
   access in that time. So "no other holder" of an owned thread location is derived from named
   facts: the contracts of the functions that the slot's value is handed to.

**Identity needs no rule.** Only `Js.same` and host collections observe which object a list is. To
see that a write kept the object, code must compare a reference from before the write with one from
after. The one from before was kept across the write. By 2 it escaped, so the write was refused; or
it is in the slot, which nothing compares.

**What the argument does not cover.** T1 and T2 are trust, now enumerated. The interior is the
kernel's own theorem, unchanged. A wrong contract in the trusted set is still a silent wrong answer;
part 5 is the test for those.

### 5.8 Part 5 — an oracle that sees every class

1. **The sanitiser traps an identity test on a stale list.** `sanitize_runtime.mjs` already keeps
   every poisoned array in `staleSites`. Under `--sanitize-lists`, lower `Js.same` to a check that
   traps when an operand is poisoned ("the identity of a stale list is observed"), and do the same
   for a poisoned key of a `Map`, `Set` or `WeakMap` that a platform makes. #2504 then fails
   `browser/dom/HolesInPlace` instead of waiting for a reader.
2. **The sanitised page fixtures run in Chrome**, not only under happy-dom. #2502 is invisible
   otherwise.
3. **A build that really writes in place, behind a hidden flag, soon.** Then every accepted program
   of the corpus and the sweeps can be run twice and compared, page transcripts included. It is the
   only oracle that needs no model of what a fault looks like.

### 5.9 The plan, in order, and what each step proves

| Step | Work | It proves |
|---:|---|---|
| 0 | Part 5, items 1 and 2. No change to the checker or a runtime. | That #2504 and #2502 fail a test. That the next kind C fault is found by a run. |
| 1 | The trust report, with no error yet: for every worded declaration with a beni body, print the words and the derived contract, and mark where the words claim more. | The real size of the trusted set. It also finds wrong words with no reader. |
| 2 | Thread words on the entry records (part 2), all marked `trusted`. `entryShape`'s guess is deleted; `entryCall` becomes the rule for a thread contract. | That the entry is expressible as a contract. The entry fault folders (`blind4a`, `5c`, `5d`, `6e`) must give the same verdicts, and the real writes must stay at 287 of 308 or rise. |
| 3 | The kernel derives a thread contract from a typed body: the three capabilities of §2.5, then the slot (part 3). First for application code on `node`, with a blind round on generic drivers. Then the `page` test platform's driver, then `Tea`, then `Browser.program`. | That the entry rule is a consequence of general rules. The eleven programs of Appendix A are accepted and their live twins refused. Release bytes and research 29's timings do not move. |
| 4 | Part 4 for markup: the effects function, `dom`'s declarations (with #2504's keep), `inline`'s and `ssr`'s. Kernel §6.12 is rewritten as "apply the declared effects". | That no markup fact is the checker's own. One fixture for each declared effect. |
| 5 | Part 4 for generated code: the emit functions take the caller's contract. The table of §6.14 is deleted. | That a call into the program cannot be emitted without a rule. |
| 6 | `trusted` becomes required (the error of part 1 is on). Then blind rounds on the boundary again, with the oracle of step 0 and of part 5 item 3. | Four clean rounds mean something, because the reader now attacks a finite, printed set. |

Steps 0 and 1 are small and change no verdict. I would start them now, beside the interior loop.

**If step 3 fails** — the kernel cannot derive threads soundly within a few rounds, or the cost is
high — stop at step 2 for the entry. The drivers stay `trusted`, in the general contract language,
and steps 4 to 6 go on. That is still a strict gain over today: the claim is one printed line for
each driver, and the guess is gone.

---

## 6. What the owner must decide

1. **`trusted` and checked words** (part 1). It is a change to the platform language. It makes rule
   6 sharper: `foreign` and `trusted` are the two marks of privilege.
2. **Per-lowering declared effects in place of the single platform rule** (part 4). A program's
   verdict can then depend on its platform, for a write of something a view shows. Since report 134
   this is already so for a kept `let`. The other choice keeps one rule for all runtimes, and then
   every runtime must really obey it, which `dom` does not.
3. **#2504.** Under decision 2 it becomes "`dom` declares the keep; an in-place write of a
   by-reference row's item is refused". The other choices in the issue (refuse by-reference keying
   over such items, or key by value) stay possible later.
4. **The slot's guard** (part 3): one flag test for each message, or a trusted promise. The guard
   is a run-time check, so it is the owner's call under the "no run-time count" decision. It is one
   flag for a program, not a count for a list.
5. **The order of work**: the oracle and the trust report first; the boundary rounds paused until
   step 4; the interior rounds go on.
6. **Whether `dom` gets the typed driver at all**, if `browser-inline` is the target (§3.5).

---

## 7. Open questions, and what would settle each

| Question | What would settle it |
|---|---|
| Can the kernel derive a thread contract from a body without new holes and within its budget? | Step 3 on `node`, then one blind round that attacks only generic drivers. I could not test this without writing checker code. |
| How many worded declarations claim more than their body shows? | Step 1's report. It is also the count of trusted contracts on day one. |
| Does a typed driver emit the same bytes and run as fast? | Step 3: byte-compare the empty page and the benchmark app in `--release`; research 29's harness. |
| What does "kept, so refused" cost once records are written in place? A by-reference `For` over records is the common case. | A count on the real roots of `update`s that write a row's item, with records in place. This is the same question as the cost of `backend.md` §15.5's record amendment, which is unmeasured. |
| Is `Js.same : unused a, unused a` true under the new argument? | It is, if 5.7's point 2 holds: an operand kept across a write has escaped. Step 0's trap tests exactly this. |
| Should a platform be able to ask that `view`, a row and a key function be `pure`? Then they can keep nothing outside their answer, and several markup rules become one line. Is that a restriction with no guarantee behind it (rule 7)? | Count the real programs whose `view` or row has an effect. If none, it costs nothing; the owner decides whether it is a guarantee (a render is deterministic) or taste. |
| Fibers: a list held across a suspension is held by the fiber runtime (`core/Task.beni`, 3 666 lines over `Js`). Is "the continuation is a closure at the default location" precise enough for commands? | The three deferred facts of #2508 are this question. A thread-like contract for "a message is delivered once" may answer it; I did not study it. |
| The `browser-inline` program hook never builds the record: its parts are inlined into the mount. Is its thread declared by the lowering (part 4) or judged before lowering and trusted to keep order, as now? | Decide with step 4; the kernel's §6.14 row for it is trust today. |
| What of the runtime was never audited: `Browser.programs` with nested mounts, workers, prerender hydration (report 117 §9.6)? | Under part 4 the default covers them: undeclared means kept. Today nothing does. |

---

## Appendix A. The experiment of §2.5

Compiler: a Debug build of `a982e4641d` (`zig build` under `nix develop`). Runner:

```sh
node bench/ownership-sweeps/run.mjs --beni=<wt>/zig-out/bin/beni --checker=v3 --jobs=4 --tmp=<dir> <progs>
```

Every program starts with this, and prints through `Node.print`:

```text
type alias Model =
    items : List Int
    n : Int

show : List Int → String
show l = String.join (List.map l String.fromInt) ","

init : ⊤ → Model
init _ = { items = [ 1, 2 ], n = 0 }

update : Int, Model → Model
update k model = { model | items = List.push model.items k }

view : Model → String
view model = show model.items
```

The drivers (the safe twins; `main` calls each with `init`, `update`, `view` and `[ 7, 8, 9 ]`):

```text
-- inline: SAME
main =
    ( _, out ) =
        List.foldl [ 7, 8, 9 ] ( init ⊤, [] ) λmsg ( m, acc ) →
            m2 = update msg m
            ( m2, List.push acc (view m2) )
    Node.print (String.join out " | ")

-- upd-generic: SAME
drive : (msg, model → model), model, List msg → model
drive upd first msgs = List.foldl msgs first λmsg m → upd msg m

-- bare-fold: REFUSED supply, "the callee hands the function the answer of another function"
drive : (⊤ → model), (msg, model → model), List msg → model
drive ini upd msgs = List.foldl msgs (ini ⊤) λmsg m → upd msg m

-- upd-only: REFUSED later-use (upd-direct hands `upd` to the fold with no lambda: the same)
drive : (Int, Model → Model), List Int → Model
drive upd msgs = List.foldl msgs (init ⊤) λmsg m → upd msg m

-- sep-concrete: REFUSED supply, "the function writes a parameter that the callee reads again or
-- does not hand as its own" (upd-view names `init` inside `drive`: the same)
drive : (⊤ → model), (msg, model → model), (model → String), List msg → List String
drive ini upd vw msgs =
    ( _, out ) =
        List.foldl msgs ( ini ⊤, [] ) λmsg ( m, acc ) →
            m2 = upd msg m
            ( m2, List.push acc (vw m2) )
    out

-- rec-concrete: REFUSED call, "a function that writes its parameter goes where the checker does
-- not follow it" (fold-record has a type variable for the view's answer: also refused)
type alias App model msg =
    init : ⊤ → model
    update : msg, model → model
    view : model → String

drive : App model msg, List msg → List String
drive app msgs =
    ( _, out ) =
        List.foldl msgs ( app.init ⊤, [] ) λmsg ( m, acc ) →
            m2 = app.update msg m
            ( m2, List.push acc (app.view m2) )
    out

-- ref-cell: REFUSED supply (ref-inline writes the same loop in `main`: the same)
drive : (⊤ → model), (msg, model → model), (model → String), List msg → List String
drive ini upd vw msgs =
    r = Ref.make (ini ⊤)
    List.foldl msgs [] λmsg acc →
        Ref.update r λm → upd msg m
        List.push acc (vw (Ref.get r))
```

The live twins of `inline`, `sep-concrete` and `rec-concrete` push `m2` onto `acc` and print every
kept model at the end. All three are refused.

The limits of this experiment: fourteen hand-written programs, one model shape, one writer, a Debug
compiler. It shows what the general rules cannot accept today. It does not show that the rule of
§5.3 is easy to build.

## Appendix B. The guard's micro-benchmark

```js
const plain   = (s, msg) => { s.v = update(msg, s.v); };
const guarded = (s, msg) => { if (s.b) defect(); s.b = true; s.v = update(msg, s.v); s.b = false; };
```

`update` pushes onto an array and returns its model. 2·10⁸ calls of each, 2 warm-up runs, the median
of 7: plain 7.42 ns, guarded 7.78 ns (Node 24.19.0, x86-64, dagon). A real driver also needs a
`finally` to clear the flag when `update` throws; `mount` has one already (`Rt.beni:828-832`).

## Sources

- `docs/design/ownership-v3-kernel.md` §1, §3, §5, §6.10–§6.14, §7, §8, §9.
- `docs/design/boundary.md` §4.2, §9.4.5, §9.4.8. `docs/design/backend.md` §4, §6, §15.5.
- Research reports 68, 69, 109, 110, 116 to 135.
- Issues #2451, #2502, #2503, #2504, #2505, #2506, #2507, #2508.
- `platforms/browser/Rt.beni:788-832, 1342-1350`; `platforms/browser/Browser.beni:38-48, 126-145`;
  `platforms/browser-tea/Tea.beni:42-70`; `core/Js.beni`; `core/List.beni:287-299`;
  `src/markup/Interface.zig` (`Lowering.keeps_let`); `platforms/browser/zig/dom.zig:108-122`;
  `src/js/sanitize_runtime.mjs`; `src/own3/Frame.zig` (`entryCall`, `formCalls`, `runtimeCall`,
  `keptItems`), `src/own3/Check.zig` (`entryShape`, `walkSchema`, `walkExports`).
