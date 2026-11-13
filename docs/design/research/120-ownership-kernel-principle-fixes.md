# 120 — Ownership v3: the kernel's principle applied to whole rules

*Research report, 2026-11-13. It answers reports 118 and 119, the fourth blind test of `src/own3/`
(`--ownership=v3`, pull request #2451). It is not normative: `docs/design/ownership-v3-kernel.md` is, and
this work changed its §6.4, §6.8, §6.11, §6.12, §6.13 and §8. It compares the branch head `c9b784cef3`
(before) with this work (after), rebased onto `829cc99c03` (the rows of `Js.get` and `Dict.focus`, report
117 §10), on the same programs, with ReleaseSafe compilers of each.*

---

## 0. Summary

Report 118 found six programs that v3 accepts and that then read a list after an in-place write. Report 119
found two compiles that never end. Each fault is a rule that read a negative fact — "no other holder", "no
escape", "only reads" — without deriving it. The fix is per rule, not per fault: each rule now reads each
such fact off positive sources, and refuses where none is named.

- **The entry rule** (kernel §6.13) is rewritten. A model location is `own` only where every source of it,
  in every function that makes the model, is a new cell let go nowhere or an `own` model location let go
  nowhere. The message is never `own`. This refuses four of the six faults, and three siblings that the
  audit found (§3).
- **The fold rule** (§6.8) reads the same three facts for a new cell as for a parameter: no escape, no
  other place in the answer, no hand-on. One fault.
- **Derived methods** (§6.11) are no longer read as code that only reads. The checker finds the methods
  that a derived `eq` or `compare` calls, through the dispatch terms, and applies what they can do to the
  operands. One fault.
- **Markup** (§6.12) holds every local that its holes read (#2505), and every value at an item that is not
  an attribute escapes (§5).
- **The hangs**: a chain of writes visits each entry once (40 writes: more than 60 s → 37 ms), and a
  type with more than 4 096 locations is a loud limit (§2).

All six live programs of `blind4a-faults` are refused, and the two hangs end in 37 and 55 ms. The
adversarial review found two more holes, both older than this work, and both are fixed (§5). Every
generator and fault folder of `bench/ownership-sweeps/` has 0 traps, differences and crashes after,
against 78 before (§4). The sanitiser corpus has 0 traps before and after. Of the 308 real writes, 287 are
accepted, against 292: five `update` writes of a TEA model are lost, each with its reason (§6).

## 1. The rules rewritten

### 1.1 The entry (kernel §6.13)

**What was wrong.** The old rule started from "`own` everywhere" and took away a location only in some
cases. It never read the escape bit of a new list (`init` puts `xs` in a `Ref` and answers it; report 118
§4.1). It compared two locations of the answer only for a parameter of `update`, never for a new list or
for `init` (§4.2, #2507). It never read the escape of a model location that `update` answers (§4.3). And
it made the message `own` wherever every model location was (§4.4). That argument was "a `send` is checked,
and a message built in `view` from the model can hold a model cell only where `view` keeps the model". It
covered the model's cells only. A message can hold a top-level list, and a handler keeps its message until
the next render, so two clicks send one list twice.

**The rule now.** A location of the model is `update`'s own only where a positive fact names its one
holder, the model, at every place the model comes from: the answer of `init`, `update` and `settle`. There,
each source of the location must be one of two things:

- a cell that the function made, whose site has no escape bit, is at no other location of the answer (a
  second model field, a command, the rest of a pair) and is in no supply to a function (`freshOwn`);
- a location of the function's own model parameter that is `own` in its turn, that the function did not
  let escape, answers at no other location and hands to no function (`paramOwn`).

Every other source is not `own`: a top-level value, the answer of a function, a capture, the `Host`, and
the message. The other functions of the record (`view`, `subscriptions`, …) keep what they write, let
escape, hand to a function (new: `handsOn`) or, except a `view`, answer.

**The corrected argument.** A cell has one holder only if no rule can name another, and every holder a
contract can name is a source of the same cells in that contract: an escape bit, another result location,
a supply. A contract lists every source of every location (a location with no source holds none, as a fact
of the body's walk), so "no other holder" is the absence of each of these from a complete list.

**The message is never `own`.** No positive fact names its one holder. A handler can send one message
twice; a message can hold a top-level value; commands, subscriptions and platform events make messages
that no rule of the checker follows. A `send` written in the program is checked where it is written, but it
is one source among these. To make a message `own`, a platform would have to declare that its runtime hands
each message once and that it holds no cell of anything else, and the checker would have to see each place
that makes one. That is a platform decision; it is not taken here.

### 1.2 The fold answer (kernel §6.8)

**What was wrong.** Where a callee hands a function its own answer back (a fold), the answer must be the
function's own. The text said "made by it, or a parameter handed `free` that it did not let go". The code
read "did not let go" for a parameter only: `answerOwn` took a new list as `own` without its escape bit
(report 118 §4.5).

**The rule now.** A new cell is the function's own where its site has no escape bit, is at no other result
location, and is in no supply to a function (`freshOwn`, the same test as the entry). The hand-on was a
further gap: a callback that hands its new list to a function parameter (`g k`) and answers it was taken as
`own`, because a supply is not an escape. It is refused now.

**The corrected argument.** The callee hands the answer back as a parameter that the function may write.
So the answer must have no other holder, and every holder its contract can name is one of the three
sources above. A new cell is one source among the others; it needs the same three facts.

### 1.3 Derived methods (kernel §6.11)

**What was wrong.** The text said that a derived method "reads its operands and calls its evidence".
`methodCall` treated every derived method as code that only reads, and `evidenceTerm` did not look inside
a derived term. But derivation is structural and recursive (`static-dispatch-spike.md` §3.3): the derived
`eq` of `( T xs, 1 )` calls `T.eq` on the first parts, and `T.eq` may write. For a tuple, a record, `Maybe`
or `Result`, the call of `T.eq` is in the derived term's arguments, which the site's walk never read
(the callee term has its evidence as arguments, and the site's own evidence list is empty). For a type of
the program (`type W = W T Int`), `T.eq` is in the derived row's body, which nothing walked.

**The rule now.** The functions that derived code calls are the edges of the site's dispatch terms,
through the body of each derived row, each term once (`Check.termEdges` over `Edges.termsEdges`, the walk
that `js/Reach.zig` already uses to keep those functions in the build). A derived row of another module is
read by a fact that its module now publishes (`Contract.DerivedFact`); a row with no fact can write and
keep. Each edge has an effect, read off its contract (`Contract.Effect`: writes, keeps, no contract). The
callee's effect is applied to the operands (`derivedEffect`): where one keeps or has no contract, each
operand escapes; where one writes, every cell of each operand is a demand, with the other operands as its
other operands, and a cell at two places of one operand is refused (the derived code reads the second
place after the method wrote the first). Evidence keeps its rule: a function handed as evidence is called
any number of times, so one that writes, keeps or has no contract is refused. Return-type dispatch
(`type_dispatch`) applies its callee the same way.

**The corrected argument.** The functions a derived method calls are named by the dispatch table: its
evidence, and the declared methods of its parts, at any depth. Each is called once per part of the
operands. So what the derived method does with its operands is the union of what those functions do,
applied to every cell of the operands. No method is read as read-only by being derived.

`codec` terms: a derived codec is a function of `⊤` that answers a schema; it reads no operand, and its slots
are codec terms, walked as edges. A codec method that the program declares is an edge like any other.

### 1.4 Markup holds what its holes read (kernel §6.12, #2505)

The `dom` lowering may evaluate a hole's expression where it renders, from the root's inputs (`backend.md`
§15.4). The walk held the hole's value. So `m = <p>{List.sum xs}</p>`, then `List.push xs 9`, was accepted,
and the render read the stale list. Markup now holds the value of every local and capture that a hole reads
(`markup_reads`), not only the hole's value. A write of a hole's input inside another hole is refused too:
the render may evaluate that hole again.

### 1.5 Markup in the model (#2506)

No separate change was needed. The issue says that a model location of type `Html msg` has no layout
entry; it has one (the markup type is a `foreign` type, so its location is `opaque`). The cause was #2505:
`shown xs = <p>{List.sum xs}</p>` answered markup that held only the hole's number, so its contract was
`res [ outside ]`. With §1.4 it is `res [ outside π1@0 ]`, so `{ model | cached = shown model.items }`
answers `model.items` at `cached` too, and the new entry rule, which compares each source of the answer
with every other location, takes `items` as not `own`.

## 2. The hangs

### 2.1 A chain of writes (report 119 §4.1)

The run of a `version` entry names the old names of the cells, and each old name has its own run.
`markAtom`, `groundOf` and `atomSrcs` went into the run of each atom of a run again, so write *n* cost
2ⁿ. Each now visits each entry of a run once per call (`run_seen`). The verdicts are the same: the chain
programs of `blind4b-faults` print the same lines before and after.

| Program | before | after (Debug) | after (ReleaseSafe) |
|---|---:|---:|---:|
| `version-chain.hang` (40 writes) | more than 60 s | 295 ms | 37 ms |

### 2.2 A type with repeated halves (report 119 §4.2)

A location is a path of labels, so `( x, x )` nested 32 times has 2³² locations. The layout had no bound,
and `addEntry` searched its list for each new location. The layout now has one limit,
`Loc.max_layout_entries` (4 096), and `addEntry` finds a location in one step (a column with a stamp). Past the limit, the place gets one
summary location of a type variable, the module authorises no write, publishes no contract and no derived
fact, and its report has an `ownership_limit` line: "limit Main: a type has more than 4096 locations (a
location for each path of labels through it), so the checker judges no write of the module". Under
enforcement this is a build error, as v1's summary-size limit is. It is never a cut toward "holds nothing".

**Why 4 096.** The work after the layout grows faster than the layout: each frame keeps flags, runs and
covers per entry. Measured with the ReleaseSafe test compiler on a type of repeated halves: 4 096
locations check in 0.5 s, 16 384 in 6 s, 65 536 (`w5`) in 71 s, and 131 072 does not end in 120 s. No
module of the real roots reaches the limit (§4). So 4 096 is huge for a program and still quick to refuse.

| Program | before | after (Debug) | after (ReleaseSafe) |
|---|---:|---:|---:|
| `dag-type.hang` | more than 60 s | 423 ms, refused (limit) | 55 ms, refused (limit) |
| `run/EvidenceDagBuildDepth32` | more than 60 s | 420 ms, refused (limit) | 57 ms, refused (limit) |

**Is there a principled layout?** Yes. Past a bound, the repeated halves of a type could get one summary
location for each object place below them, as the deep level of a cycle does (kernel §4.1). That is
sound: a summary location derives `twice`, and its parts are not apart. It is not built here, because
it touches the call map (`Loc.cover`), the projections and the path abstraction, which all reason about
cycles today. So `EvidenceDagBuildDepth32` is refused loudly, and a principled layout would win it back.
The program writes no list, so the refusal costs it nothing at run time.

The evidence walk had its own hidden blow-up: `evidenceTerm` expanded a shared term once per path and
stopped at depth 8. `Edges.termsEdges` visits each term once, so that limit is gone.

## 3. The sibling audit

For each rule, every other place in `src/own3/` that reads a negative fact, and its verdict. "Fixed" places
have a pin in `tests/blackbox/check_test.zig`.

**The entry and the fold (holders of a cell).**

| Place | Negative fact | Verdict |
|---|---|---|
| `entryCall`, a model location answered from the message (`Load l → { model \| items = l }`) | "the message is own, so this location is" | **fixed**: the message is never `own`, so neither is a location answered from it. Traps before (`Message` pin) |
| `entryCall`, the other functions of the record | "a function that does not write, let escape or answer the model does not keep it" | **fixed**: a hand-on to a function (`view` calls a captured `g model.items`, and `g` keeps it) is a holder too (`handsOn`; `Handed` pin, a trap before) |
| `entryCall`, a command or the rest of a pair that holds a model list (`Cmd.perform λsend → … model.items …`) | "only the model locations of the answer hold it" | already refused before, for a parameter source of `update` (the old duplicate test read every location of the answer for it; here the escape bit refuses it too); now the same test covers a new list of `init` and of `update` |
| `entryCall`, a model location below a wide location of the answer | "the wide location says nothing of this one" | **fixed**: no fact of its own, not `own` |
| `entryCall`, markup in the model (#2506) | "markup holds no model list" | **fixed** by §1.4 (`Cached` pin, a trap before) |
| `answerOwn`, a new cell handed to a function parameter and answered | "a supply is no holder" | **fixed** (`freshOwn`; `foldHandsOn` pin) |
| `answerOwn`, `.param` | "did not let go" | already derived: the escape bit is read, `handedBack` reads every supply of it, and `nonlinear` the duplicates |
| `answerOwn`, `.answer` | "passes the answer on once" | already derived: `passesOn` reads every result entry and supply of the contract |
| `handedBack`, a captured function handed the cell | "the captured function does not keep it" | already derived: `keepsOwn` reads its escape bits |
| `ownSupply` and `OwnSink.atoms`, a new cell in a supply | "the callee's new cell has no other holder" | already derived: `freshAtom` notes the escape bit at the call, and the demand reads every escape |
| `FnDraft.free` | "the owner does not read what it handed" | already derived: `free` falls where the supply's demand is refused (the four tests of §5) |
| `deriveLinear` for a literal | "no cell at two places" | already derived from the atoms (`dupOverlap`) |
| `Contract.old_result` and a `?` | "each answer is a new object" | **fixed** for the rule: the failure of `?` answers an object that exists, and now sets `tail_old`. No program could reach it: a function that answers a `Result` or a `Maybe` has a constructor in tail position, which is never new, so it was `old` already |

**What code that the walk does not follow does (derived methods, evidence).**

| Place | Negative fact | Verdict |
|---|---|---|
| `methodCall`, a derived callee | "a derived method only reads" | **fixed** (§1.3) |
| `evidenceTerm`, a derived term | "a derived term names no declaration" | **fixed**: its row's body is walked (`through_rows`); `sortNominal` pin |
| `evidenceTerm`, another module's derived term | "another module's row calls nothing" | **fixed**: its module publishes a fact for it, and no fact is the pessimistic one |
| `evidenceTerm`, depth past 8 | — | replaced: each term once, no limit |
| `type_dispatch` | "return-type dispatch runs a function that only keeps" | **fixed**: its callee and what that calls are applied as a derived callee (`derivedEffect`); its arguments still escape |
| `methodCall`, `.param` callee (`a.eq x y`) | "evidence handed by a caller reads only" | already derived: the caller that handed it judged every edge of it |
| `methodCall`, `.codec`, `.primitive`, `.undetermined` | "reads its operands" | already derived: compiler code that reads; what it calls is an edge of the terms |
| `call` of unknown code | "unknown code does not write in place" | already derived: a declaration with no contract had its walk give up, which refuses every write of it (§3.3); a `foreign` cannot reach a list's storage |

**Markup.**

| Place | Negative fact | Verdict |
|---|---|---|
| `evalInner .markup`, a hole's value | "a hole reads only its value" | **fixed** (§1.4, #2505; `Inputs` pin) |
| `evalInner .markup`, an event's value (a handler, a message made by `if` or a call) | "only a value built here, or a function that answers a cell, is kept" | **fixed** after the review (§5): every item that no row names as an attribute escapes (`Burst` pin) |
| `helperHoles`, a text hole | "a text hole is written where it is" | subsumed: the hole's inputs are held by §1.4 whatever the hole is |
| a markup primitive (`Html.map`) | "the runtime keeps no markup it is handed past the render" | trusted, by the owner's platform rule (`boundary.md` §9.4.8) |
| `Mod.isView` | "a `view`'s answer is no holder" | trusted, the same rule; the type decides which function is a `view` |

**Construction.**

| Place | Negative fact | Verdict |
|---|---|---|
| `listOf`, a literal whose place has no element step | "an element location holds the items" | **fixed** after the review (§5), as the contract work on the branch fixed it too: `unknown` over its items (`Listen` pin) |
| `built`, a kid whose step the place graph does not name | the same | already derived: `leavesOwn` reads all of the kid (`allLeaves`) |
| `call` of a constructor with no row | the same | already derived: `unknownOf` over the arguments |

**The hangs.** Every other walk over a run (`rootLeaves`, `rootReach`, `newItem`) reads one level of it. The
run of an entry is written once, where its root is made, so a visited set per call is exact.

## 4. The gate

ReleaseSafe compilers of `c9b784cef3` (before) and of this work (after; the same verdicts program for
program before and after the rebase onto `829cc99c03`), `run.mjs --checker=v3` on the same generated
programs; the five fault folders from a `LIST` of their programs. `blind4b` includes its 4 000 random
blocks.

| Generator | Programs | before SAME | before REFUSED | before TRAP/DIFF/CRASH | after SAME | after REFUSED | after TRAP/DIFF/CRASH |
|---|---:|---:|---:|---:|---:|---:|---:|
| blind-faults | 24 | 11 | 13 | 0 | 11 | 13 | 0 |
| blind2-faults | 20 | 9 | 11 | 0 | 7 | 13 | 0 |
| blind3-faults | 10 | 3 | 7 | 0 | 3 | 7 | 0 |
| blind4a-faults | 12 | 6 | 0 | **6** | 1 | 11 | 0 |
| blind4b-faults | 8 | 3 | 3 | **2** | 4 | 4 | 0 |
| blind | 9792 | 1675 | 8117 | 0 | 1675 | 8117 | 0 |
| blind2 | 1202 | 502 | 700 | 0 | 502 | 700 | 0 |
| blind3 | 417 | 160 | 257 | 0 | 160 | 257 | 0 |
| blind4a | 160 | 66 | 31 | **63** | 24 | 136 | 0 |
| blind4b | 6596 | 1286 | 5303 | **7** | 1290 | 5306 | 0 |
| evaluation-order | 440 | 288 | 152 | 0 | 276 | 164 | 0 |
| answers-beside | 240 | 77 | 163 | 0 | 77 | 163 | 0 |
| wider-functions | 354 | 144 | 210 | 0 | 144 | 210 | 0 |
| callbacks-keep | 720 | 108 | 612 | 0 | 108 | 612 | 0 |
| function-values | 1960 | 304 | 1656 | 0 | 304 | 1656 | 0 |
| handed-back | 2592 | 0 | 2592 | 0 | 0 | 2592 | 0 |
| aliased-arguments | 5160 | 1183 | 3977 | 0 | 1183 | 3977 | 0 |
| recursive-levels | 16131 | 4231 | 11900 | 0 | 4231 | 11900 | 0 |
| folds-callbacks | 30300 | 5392 | 24908 | 0 | 5392 | 24908 | 0 |
| **all** | 76138 | 15448 | 60612 | 78 | 15392 | 60746 | 0 |

What moved:

- **Traps to refusals**: the six faults of report 118 (`blind4a-faults`) and their 63 variants in `blind4a`.
- **Crashes**: the seven of `blind4b` and the two of `blind4b-faults` were the runner's 120 s limit, the two
  hangs. Six chains of 40 writes are now accepted and print the same as the plain build; the chain with a
  branch (`size.chain.join.40`) is refused, rightly (`later-use`: a branch can leave the older version in
  place, report 119 §3.1); `dag-type.hang` and `size.dag.6` are refused by the layout limit. `size.dag.5`,
  which the old code checked in 8.3 s, is refused by it too (SAME before); v1 refuses it by its own summary
  limit.
- **Safe twins refused** (61): the 42 `dead` twins of `blind4a` and the 5 of `blind4a-faults` (§6); 12
  programs of `evaluation-order` and 2 of `blind2-faults` that write a list in one hole of markup and read
  it in another (`order.markup`, `order.markupFor`, `markup-helper.dead`, `order-markup-for.dead`). These are
  safe only where every hole is evaluated once, as it is written; the `dom` lowering evaluates a hole where
  it renders, from the lists it reads (§1.4), so a write of one of those lists inside a hole is refused.

**The sanitiser corpus** (`bench/ownership-step0-sanitiser.mjs`, 347 fixtures): 97 same, 250 refused, 0
traps, differences or crashes, before and after; the losses against v2 by cause are the same. The
`.sanitize-lists-v3` markup fixtures (`run/SsrHolesInPlace`, `browser/dom/HolesInPlace`,
`browser/tea/HolesInPlace`, `browser/inline/HolesInPlace`) are corpus cases of `zig build gates`, and pass.

**Real writes** (`bench/ownership-v2-review.mjs --checkers=v1,v3 --roots=real`): of the 308 list writes v1
judges, v3 accepts **287** at v1's position (before: 292, on `c9b784cef3` and on `829cc99c03` alike),
refuses 20 (15) and has no line for 1 (1). By v1's ground: fresh 34 of 36, call 42 of 51, param 181 of 185, entry 11 of 16 (16), callback-param 19 of 20. The
five lost are all `entry` lines (§6). No module of the real roots reaches the layout limit.

**Speed.** ReleaseFast LLVM compilers (`zig build test-perf`) of `829cc99c03` and of this work,
`bench/ownership-v2-review.mjs --checkers=v1,v2,v3 --roots=real --runs=3 --jobs=1`, best of three, one
machine, one after the other:

| | lines | head ms | after ms | head lines/s | after lines/s |
|---|---:|---:|---:|---:|---:|
| type check (for scale) | 169 846 | 237.9 | 236.7 | 714 000 | 718 000 |
| v3, on the modules v2 walked | 169 846 | 199.3 | 201.8 | **852 000** | **842 000** |
| v3, on all it walks | 556 500 | 519.7 | 525.7 | 1 071 000 | 1 059 000 |

Report 117 measured 879 000 lines per second on the modules v2 walked; on this machine today the head is
852 000, so the ratio is the figure: this work costs about 1 % of v3's time (the edges of each derived
method's terms, the duplicate test over every location of an entry's answer, and the kept items of markup).

`zig build gates`: green on the final commit.

**The tests fail before the fix.** In a second worktree at `c9b784cef3` with this work's
`check_test.zig`, `zig build test-blackbox-check -Dtest-filter="ownership v3"` fails 7 of 21: the five new
tests (the faults of reader A: `derived-method.live` accepted; the siblings; the chain, which does not end
in 10 s; the entry's siblings and markup's inputs: `Message` accepted; the faults of the review: `Burst`
accepted) and the two older tests whose expected lines changed with §1.4.

## 5. The review

One fresh Opus reviewer had the kernel and the code, and was asked for a negative fact still read without
being derived, or a rule whose argument fails, each proven by a program that traps. It proved two faults.
Neither was caused by this work: the before compiler accepts each program too. Both are fixed, with pins
in `check_test.zig` ("the faults of the review of report 120 are refused"); the second was fixed on the
branch by the contract work too.

1. **A handler in a markup hole was not escaped.** `onClick={λ_ → if List.length items < 3 then Push else
   Nop}` captures the model, and the runtime calls it after `update` has run: three clicks in one task, or
   an event that bubbles through two handlers. The walk escaped a hole's value only when it was built there
   or was a function whose answer held a cell. So the model stayed `own`, and the third click read the
   pushed list. The same held for a message made by `if` or by a call. **The rule now** (kernel §6.12):
   every value at an item of markup that no row of the dispatch table names as an attribute — an event's
   handler or message, a component's prop, a spread — escapes, whatever made it (`keptItems`). A missing
   row is the pessimistic fact. **The argument** of §6.12 and §6.13, "the markup the runtime renders holds
   none of its holes after the render", holds for what the runtime reads where it renders. An event's
   value is the one thing that it keeps, and `boundary.md` §9.4.8 already counts it as escaped where the
   markup is made; the kernel's text and the code were narrower.
2. **A list literal whose place has no element step dropped its items.** The type checker gives each item
   of a `Js` intrinsic's literal argument a type of its own, so `Js.array [ host (withSend body _) ]`
   has a type variable as its place, with one location, its storage. `listOf` put the items' cells only
   at element locations, and there were none. So `Hosted.tap`, which a subscription is built through, lost
   what the subscription's body captured, and `Sub.listen "k" (λsend → body send m.items) Seen` left
   `m.items` `own` while the running body read it after the push. **The rule now** (kernel §6.4): a part
   that the place graph does not name is `unknown` over its value, and a literal with no element step is
   `unknown` over every value it was made of. About 218 sites in `platforms/` and `core/` build such a
   literal; the reviewer found the fault through one of them. The contract work on the branch found and
   fixed the same hole at the same time (`a960a3a01b`, report 117 §10.3); after the rebase this work keeps
   that code, and its pin and this one both pass.

It also tried, and found refused or correct: fold callbacks that capture the answered accumulator, one
parameter answered at two locations, a new list let go through a top-level helper or a captured function;
a model that holds a closure over a new list, a `Tea.element` command that captures a model list, the
entry record passed as a variable or through a wrapper; derived methods across modules over a nominal type
inside a nominal type, a recursive type, `List.member` with evidence, a tuple's `<`, one cell at two places
of an operand; a schema's `via` conversion whose backward direction writes. It found no way for the
layout limit to cut toward "holds nothing": each module's table is its own, and an importer reaches the
limit itself.

## 6. What it costs

**The safe twins of report 118** (`blind4a-faults`: 5 of 6 refused; `blind4a`: 42 of 80). Each is the
live program with its reader taken away from a place that the checker does not see into, so no sound rule of
this kernel can accept it:

- `fold-escaped-answer.dead` and the 30 `fold.*.dead`, `entry-escaped-fresh.dead`, `entry-escaped-param.dead`,
  `entry.initref`, `entry.updref`, `entry.updfreshref`: a list that went into a `Ref` and is never read
  from it. A cell's contents are a later stage of the kernel (§0); until then a list in a cell is never
  written again.
- `entry-fresh-twice.dead`, `entry.twofields`, `entry.maybe`, `entry.nested`, `entry.updtwo`: one list at two
  model locations, one of which no function of the record reads. A fact that a model location is never
  read by any function of the record would win these back.
- `entry-message.dead` and `entry.msgconstant`, `entry.msgconstlocal`, `entry.msgresend`: the same program as
  the live one, with one click fewer. No static rule tells them apart.
- `derived.user.sort.dead` and `derived.user.member.dead`: a `compare` or `eq` that writes, handed as
  evidence to `List.sort` or `List.member`, which call it any number of times. Refused whether or not the
  list is read later, as report 118 §5 says is right.

`derived-method.dead` is accepted: the derived `eq`'s write is a demand on the operands (§1.3).

**Real writes** (five, all an `update` of a TEA program; v1 accepts each as `entry`):

- `examples/todo/page` `model.todos`: `Loaded (Ok todos) → { model | todos = todos }` puts the list of an HTTP
  response's message into the model, and `[ …model.todos, todo ]` writes it later. The message is never
  `own` (§1.1). The fact that would win it back is a platform's: that its runtime hands the message of a
  command once, and that the message holds only what the runtime made (here, the decoded body).
- `examples/conduit` `errors` ×4 (`model#Article.0.errors`, `model#Profile.1.errors`, and the two `feed`
  errors): `Main.update` now lets these locations escape. `updateWith` hands each page's command to
  `Cmd.map`, whose contract now says that the function it is given has its answer escape: through
  `Hosted.mapJob`, the function's answer is the item of a literal, `Js.apply s [ host (tag (guest m)) ]`,
  which dropped its item before the review's second fix (§5). That function (`GotProfileMsg`, …) is
  handed what the platform makes, a value the checker cannot follow, so its answer is read as holding
  every value in sight, the page's model among them. The fact that would win them
  back is a precise row for `Cmd.map`'s function parameter: it is handed the page's message and nothing else.
  The feed's `errors` also have the message as a source (`CompletedFeedLoad (Ok feed)`), as `todos` does.

The contract work on `Js.get` and `Dict.focus` (report 117 §10) landed during this work and wins back no real
write (292 before and after it); it fixed the element-less literal of §5 first, and this work keeps its code
for it. The four `conduit` writes need both: that fix gives `Main.update` the escape bit, and the entry
rule now reads it.

## Appendix A. Commands

From the worktree root, `ZIG_GLOBAL_CACHE_DIR` as `flake.nix` sets it.

1. The compilers: `zig build -Doptimize=ReleaseSafe --prefix <dir>` at `c9b784cef3` and at this work.
2. The sweeps: `node bench/ownership-sweeps/<generator>.mjs <out>/<generator>`, then
   `node bench/ownership-sweeps/run.mjs --beni=<beni> --checker=v3 --tag=<before|after> --jobs=14 --tmp=<disk> <out>/<generator>`;
   the five fault folders the same way, from a `LIST` of their programs.
3. The sanitiser corpus: `node bench/ownership-step0-sanitiser.mjs --beni=<beni> --jobs=8`.
4. Real writes: `node bench/ownership-v2-review.mjs --beni=<beni> --checkers=v1,v3 --roots=real --runs=1`.
5. Speed: `zig build test-perf "-Dtest-filter=generated module of §7.6"` (a ReleaseFast LLVM compiler), then
   `node bench/ownership-v2-review.mjs --beni=zig-out/perf/bin/beni --checkers=v1,v2,v3 --roots=real --runs=3 --jobs=1`.
