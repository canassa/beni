# 125 — Ownership v3: rows at the entry, and what the default may ask

*Research report, 2026-11-13. It answers report 124, the sixth blind test of `src/own3/`
(`--ownership=v3`, pull request #2451). It is not normative: `docs/design/ownership-v3-kernel.md` is, and
this work changed its §4.1, §5 (the theorem's argument), §6.2, §6.8 and §6.13. It compares the branch head
`37ec2e1971` (before) with this work (after), on the same programs, with ReleaseSafe compilers of each.*

---

## 0. Summary

Report 124 found two faults. Each is the pattern of kernel §1: a fact the checker did not have, read as
the empty fact.

- **The entry compared locations by label path.** A function of the program's record that takes the
  model as `{ r | n : Int }` names the model's `items` by its row. The row's location is no prefix of the
  field's, so the entry found no match and read it as "keeps nothing". The audit found the same mistake in
  three more places: where the checker composes a function's answer with its holder's, where it composes
  what a holder hands a function, and in a constructor's row. Now **every comparison between two layouts'
  locations goes through the call map** (`Loc.cover`, in both directions), and a pair it cannot decide
  counts as one cell.
- **The default was asked only one question.** A function in a place no contract describes was refused
  only if it wrote its own parameter. But the code that runs it hands its callback a function that keeps
  what it is handed, so a function that writes a list after it gave the list to its callback is unsafe
  there too. The audit found that **any holder that runs a function** hands its callback the same kind of
  function, and so does code that runs evidence. Now the rule is stated whole: what such a function may
  ask, and what it may not, and each holder that runs it applies it.

All four fault programs of report 124 are refused, their four `.live` twins stay refused, and their four
`.dead` twins are accepted. Six siblings that the audit found and eight that the review found (§6), each
accepted before and each trapping, are refused, and their safe twins are accepted. The review's eight
are one older hole in the call map itself, which compared deep locations of two cycles by label path. The
fix for it costs speed and precision (§4, §5). The gate is in §4.

## 1. The rules rewritten

### 1.1 Comparing locations (kernel §4.1)

**What was wrong.** A layout lists the locations of one type. Two layouts are often two readings of one
type position: a function's signature over `a` or `{ r | n : Int }`, and the caller's `Model`. Several
places compared their locations by label path, with `==` or `isPrefix`. A row stands for the fields its
record does not name, but its label is `row`, not the field's label. So the comparison said "no match",
and the code read "no match" as "this location holds no cell of that one".

**The rule now.** `Frame.locsMeet` is the one relation. It reads `Loc.cover` in both directions. Where the
map sends an entry to an entry of the other layout that is no narrower, that entry holds every cell of it.
The entries of one layout name apart positions, so that answer decides. Where neither direction decides,
the two entries meet. `Frame.anyMeets` asks whether any entry of a layout meets a given one. `Loc.within`
is the label relation made row-aware, used only to keep more slots, never to drop one. The label tests
`Loc.noObject`, `Loc.belowWide` and `Loc.startsAbove` had no caller left, and are deleted.

**The corrected argument.** "These two locations share no cell" is a negative fact; it is derived only
from a positive answer of the call map that names two different entries of one layout.

### 1.2 The entry (kernel §6.13)

**What was wrong.** `entryCall` matched a model location with a location of a function's contract by label
path. A consumer's kept row matched no model location, so the view, `Sub.listen` body, `Tea.element` or
`Tea.document` view that kept the model kept nothing. A producer's answer at the row matched no model
location, so its source was never judged. The kernel text also said that "a location answered through a
wide location of the answer has no fact of its own", which the code applied only to a label prefix.

**The rule now.** Each comparison uses `locsMeet`:

- the sources of a model location in a producer's answer are the sources of every answer entry that can
  hold a cell of it, as at a call (rule 2); a wide entry holds each cell below it or in its row;
- a parameter source names every model location that its entry meets, and each must be `own`;
- every model location that a consumer's kept location meets is not `own`;
- a producer's write is accepted only where every model location that the written location meets is
  `own`;
- the runtime hands each function parameter of a function of the record the default (§1.3).

**The corrected argument.** "No other holder" of a model location is read at every location of every
contract that can share a cell with it; a comparison that fails for any reason but "apart" leaves the
statement without a ground.

### 1.3 What a function in a default location may ask (kernel §6.8, §6.2)

**What was wrong.** `flowCode`, where the use is `top`, a holder lost the function, or the arity differs,
refused only `writesOwn`. A function whose contract says that it writes a cell after it handed the cell
to its function parameter (`Fn.rewrites`) went through. `Use.rewrites` stops at `top`, which is right for
the holder (§1.4), but nothing asked the function itself. A known holder that runs a function was no better:
whatever a frame hands one of its function parameters goes to `top` in that frame (`mention`), so the
callback the function meets is the default too, and its `rewrites` was never read there.

**The rule now.** The code that runs a function in a default location runs it at any time, any number of
times. It hands each parameter a value with no claim, each function parameter a function in the default
state, and it keeps the answer. Of the facts a contract carries, two ask something of that code, and both
are refused:

| Fact | Asks | Verdict at the default |
|---|---|---|
| a written parameter location (`flag_w`) | a value it owns | refused (`writesOwn`) |
| a function parameter with `Fn.rewrites` | a function that does not keep | refused (`defaultParams`) |
| a read, an escape (`flag_r`, `flag_e`), `flag_s` | nothing | — |
| an answer (`res`) | nothing: the default keeps it | — |
| what it hands a function parameter (`supply`, `free`) | nothing: the default writes nothing | escapes |
| `called`, `lost`, `ans_escapes` of a function parameter | nothing | — |
| a captured function | its own use (`flowCaptures`) | composed |

`defaultParams` applies this at each holder that can run the function: `top`, a lost holder, an arity
mismatch, a partial application (`applyAt`), a known holder whose contract says it calls the function
(`Fn.called`), and the runtime at the entry. It makes each function parameter of the function the default
meeting that parameter's use: what the function hands it escapes (with the holder's key, so a fresh cell
handed there and answered is one root), and `rewrites` on the way is refused. Evidence carries the same
fact: `Contract.Effect` has `rewrites`, a method handed as evidence with it is refused, and derived code
that calls one lets its operands escape. `writesOwn` no longer answers "no" for a parameter count past the
contract's arity.

**The corrected argument.** "No holder keeps what this function hands its callback" is never assumed for a
function a holder runs; it is derived only where the frame flows a known function to that callback, at a
direct call.

### 1.4 `Use` predicates at `top`

Each `Use` predicate and each place that tests `kind == .top` answers pessimistically or from a positive
fact:

| Place | At `top` | Why it is sound |
|---|---|---|
| `Use.rewrites` | false | the default hands only cells outside every frame, so it writes none after it handed it |
| `flow`, `ans_escapes` | not read | the default keeps the answer; its cells are new, outside, or captured, and a closure holds what it captured |
| `flowOwn` | the parameter is lost | the frame's caller judges what it hands there |
| `flowUnknown`, `escapeSupplies` | nothing | the default hands nothing of a frame, and an unknown function was judged where it entered the default |
| `slotsOf`, `resolve` | `outside` | the default hands no claim |
| `answerOfParam`, `answerOfCode`, `answerOf` | `lostAnswer` | outside, and every value in sight |

## 2. The tests

`tests/blackbox/check_test.zig`, two tests:

- **"the faults of the sixth blind test are refused"**: the twelve programs of
  `bench/ownership-sweeps/blind6e-faults/`. The four faults and the four `.live` twins are refused with
  their lines, and the four `.dead` twins are accepted.
- **"the siblings of the sixth blind test are refused"**: six programs the audit found (§3) and eight that
  the review found (§6), each with a twin that writes `List.copy` and is accepted.

Both tests run every case and name each one they get wrong. Run on the `37ec2e1971` compiler (a second
worktree, with only the test file copied in), they fail on exactly the eighteen programs that were accepted
before: the four faults, the six siblings of §3 (`HolderRewrite`, `HolderAnswer`, `AnswerRow`,
`PartialRewrite`, `EvidenceRewrite`, `SupplyRow`) and the eight programs of §6 (`CycleAnswer`,
`CycleEscape`, `CycleAncestor`, `CycleRow`, `CycleRowField`, `CycleNested`, `CycleMerged`,
`CycleAboveVariable`). On this work they pass.

A page under the `.sanitize-lists-v3` convention, `tests/corpus/browser/dom/RowModelInPlace`, is the
page form of `entry-row-view.dead`: a view over `{ r | n : Int, items : List Int }` whose row holds a list
of the model, a bubbling outer handler, and an `update` that pushes onto both lists in place. It is built
under `--ownership=v3 --sanitize-lists` and its transcript is the plain one. Its two `entry` lines are in
`tests/blackbox/ownership-v2-known.txt` with the reason `HolesInPlace`'s have: v2 makes no `entry` demand.

## 3. The sibling audit

Every place in `src/own3/` that compares locations by label path, and every place that reads a `Use`, a
contract or a cover answer that may be unknown.

### 3.1 Fixed

| Place | What it read as nothing | Program |
|---|---|---|
| `entryCall`, producers (`re.loc != want`, a wide prefix) | a producer's answer through a row | `entry-row-update` |
| `entryCall`, a producer's parameter source (`me2.loc == from`, a prefix) | the model locations a row source names | (same) |
| `entryCall`, consumers (`me.loc == pe.loc`, a prefix) | a consumer's kept row | `entry-row-view` |
| `entryCall`, the verdict (`me.loc == pe.loc`) | a write whose location meets more than one model location | (pessimistic now) |
| `answersAt` (`isPrefix`, `startsAbove`) and the `noObject` skip in `answerOfCode`, `answerOwn` | a function's row in its holder's concrete answer | `AnswerRow` |
| `slotsOf` (`belowWide`, `noObject`) | what a concrete holder hands a function's row | `SupplyRow` |
| `slotsOf`, the narrowing by `at` (`isPrefix`) | a row that holds the asked part; it fell back to all, by a fragile argument | now `Loc.within` |
| `Loc.cover`, a deep location matched by its label path (found by the review, §6) | the cells a wider caller cycle puts there | `CycleAnswer` … `CycleAboveVariable` |
| `ctorValue` (`pe.loc == ce.loc`) | an argument entry with no label twin in the constructor's row | none found: both are one instantiated type |
| `flowCode` with `top`, lost, or another arity | `Fn.rewrites` | `top-rewrite`, `top-rewrite-send` |
| `flowCode` with a holder that calls the function | `Fn.rewrites`, and what it hands its callback | `HolderRewrite`, `HolderAnswer` |
| `applyAt`, an application of another arity | `Fn.rewrites` | none written here: `f a _` lowers to a lambda, which `flowCode` refuses at `top` (`PartialRewrite`) |
| `entryCall`, the record's functions | `Fn.rewrites` of a function parameter | none possible: no platform's entry hands one today |
| `Contract.Effect`, `edgeEffect` | `Fn.rewrites` of a method handed as evidence | `EvidenceRewrite` |
| `writesOwn` past the arity | "writes nothing" | none: a state no caller makes |

### 3.2 Already derived

| Place | Why it is sound |
|---|---|
| `partBelow`, `expandSrcs`, `pairedLeaves`, `argEntries`, the `exact` narrowing in `answerOfCode`, `answerOwn` and `DraftSink.answer` | a label path only narrows a wide entry to an entry at exactly that path; with no such entry the answer is all of it |
| `passesOn` | label equality is a positive claim; a mismatch refuses |
| `otherReaches`, `cov[k] == Loc.all` on the written operand | that entry is in the write itself; a cell at two of its places makes it `twice` (test 1), and a cell also at another entry is caught on that entry |
| `freshOwn`, `paramOwn`, `handsOn`, `handsFree` | they compare entries of one contract's own layouts, which name apart positions |
| `Check.wordedContract`, `wordedFn`, `intoElems`, `elemsToElems`, `selfToSelf` | label paths inside one signature; a location with no twin gets every result entry |
| `Loc.cover`'s row step and its single-wide fallback | the review's sixth pass: a wide entry at or above the deep level holds the whole cycle |
| `Frame` paths (`pathPrefix`, `comparable`) | paths of one root, not of two readings |
| `Check.isSender` and a program's alias of `Browser.Send` | the send is an ordinary function parameter there: the message is never `own` at the entry, and a body with `rewrites` in a command is now refused at `top`; a precision difference only |
| the §1.4 table | each answer at `top` is pessimistic or a positive fact |

## 4. The gate

ReleaseSafe compilers of `37ec2e1971` (before) and of this work's last commit (after), on the same
programs. Every generator of `bench/ownership-sweeps/` and every fault folder, through
`run.mjs --checker=v3`:

| Generator | Programs | before SAME | before REFUSED | before TRAP/DIFF/CRASH | after SAME | after REFUSED | after TRAP/DIFF/CRASH |
|---|---:|---:|---:|---:|---:|---:|---:|
| blind-faults | 24/24 | 11 | 13 | 0 | 11 | 13 | 0 |
| blind2-faults | 20/20 | 7 | 13 | 0 | 7 | 13 | 0 |
| blind3-faults | 10/10 | 3 | 7 | 0 | 3 | 7 | 0 |
| blind4a-faults | 12/12 | 1 | 11 | 0 | 1 | 11 | 0 |
| blind4b-faults | 8/8 | 4 | 4 | 0 | 4 | 4 | 0 |
| blind5c-faults | 10/10 | 5 | 5 | 0 | 5 | 5 | 0 |
| blind5d-faults | 10/10 | 5 | 5 | 0 | 5 | 5 | 0 |
| blind6e-faults | 12/12 | 4 | 4 | 4 | 4 | 8 | 0 |
| blind | 9792/9792 | 1675 | 8117 | 0 | 1675 | 8117 | 0 |
| blind2 | 1202/1202 | 502 | 700 | 0 | 502 | 700 | 0 |
| blind3 | 417/417 | 160 | 257 | 0 | 160 | 257 | 0 |
| blind4a | 160/160 | 24 | 136 | 0 | 24 | 136 | 0 |
| blind4b | 6596/6596 | 1290 | 5306 | 0 | 1229 | 5367 | 0 |
| blind5c | 226/226 | 81 | 145 | 0 | 81 | 145 | 0 |
| blind5d | 1234/1234 | 456 | 778 | 0 | 456 | 778 | 0 |
| blind6e | 238/238 | 90 | 122 | 19 | 90 | 141 | 0 |
| evaluation-order | 440/440 | 276 | 164 | 0 | 276 | 164 | 0 |
| answers-beside | 240/240 | 77 | 163 | 0 | 77 | 163 | 0 |
| wider-functions | 354/354 | 144 | 210 | 0 | 144 | 210 | 0 |
| callbacks-keep | 720/720 | 108 | 612 | 0 | 108 | 612 | 0 |
| function-values | 1960/1960 | 304 | 1656 | 0 | 304 | 1656 | 0 |
| handed-back | 2592/2592 | 0 | 2592 | 0 | 0 | 2592 | 0 |
| aliased-arguments | 5160/5160 | 1183 | 3977 | 0 | 1183 | 3977 | 0 |
| recursive-levels | 16131/16131 | 4231 | 11900 | 0 | 4140 | 11991 | 0 |
| folds-callbacks | 30300/30300 | 5392 | 24908 | 0 | 5392 | 24908 | 0 |

**0 TRAP, DIFF or CRASH after**, against 23 before (the four faults and the 19 traps of `blind6e`). 156
programs moved, every one of them a safe twin (`dead`); §5 has them.

- **The sanitiser corpus:** 0 traps, differences and crashes, before and after. 97 fixtures print the
  same before, 93 after; four more are refused (§5).
- **Real writes** (`--checkers=v1,v3`): 287 of 308 before and after, the same 287; no write lost or
  won.
- **Speed** (a ReleaseFast LLVM compiler of each, v3 on v2's modules, best of three): **837k lines/s
  before, 589k after** (202.9 ms → 288.4 ms for 169 846 lines); on all 556 500 lines, 1 046k → 843k.
  Almost all of it is the call map's new rule for deep locations (§6): with `cycleWider` answering "no",
  v3 on `bench/corpus` takes 56 ms against 55 before, and with it 117 ms. The rule makes `Loc.all` common
  for a generic recursive type whose signature has a variable in its cycle's region, and `all` makes the
  walk read more atoms. This is a finding, not a trade: a sharper rule that won most of it back was
  unsound and is reverted (§6). Winning it back needs a rule that decides by every place a location
  stands for.
- **`zig build gates`:** green.

## 5. Precision

Safe programs that the work refuses and the old code accepted. By the owner's rule for this stage they are
reported, not won back.

- **The call map's deep-location rule** (§6): 152 sweep programs — 91 of `recursive-levels`
  (`fam.nest-*`, `fam.lnest-*`: a generic recursive helper over a type that holds lists) and 61 of
  `blind4b` (`hold.dict`, `hold.dictValues`, `mod.*`: generic helpers of a second module over a
  recursive type) — and four sanitiser fixtures: `SanitiserEmptyValue`, `SanitiserFamilyApart`,
  `SanitiserLevelResultFamilyApart`, `SanitiserRowLevelApart`. Each is a deep location of a caller whose
  signature has a variable in that cycle's region, now read as `Loc.all`.
- **A `Sub.listen` body over a row that captures the model** (`blind6e` `row.tea-subs.row*.direct.dead`):
  refused now, as its `Model`-typed twin already was. The closure holds the model; this is the rule.
- **Won, not lost:** `blind6e` `row.hosted-update.var.direct.dead` and `row.hosted-settle.var.direct.dead`,
  an `update` or `settle` typed `a → a` that lets the model go nowhere, are accepted now. The entry reads
  a producer's answer as a call does (§1.2); their `.live` twins stay refused.
- **The default rule** (§1.3) moved no sweep program and no real write.
- Report 124 §5's losses (a lambda that reads a field of the model handed to a writer of the model,
  `Dict.update` with a writing callback, …) are unchanged.

## 6. The review

One fresh reviewer, given the code, the kernel and `boundary.md` §9.4.8 but not this report, looked for
a location comparison that is not shape-aware and for an unknown or `top` fact read as "nothing".

It worked in seven passes, each on the commit that fixed the last one. Every hole it found was in one
place, `Loc.cover`, and is older than this work: each of its programs trapped with the `37ec2e1971`
compiler too.

**The hole.** `Loc.cover` paired a location of a deep level by its label path. Take
`type Tree2 a = Node a (List (Tree2 a))` and `type T = T (List (Tree2 T))`. The signature `Tree2 a`
has its own cycle, and its deep location for lists holds the lists below `#Node.1`. The caller's
`Tree2 T` closes a larger cycle through the type argument: its deep location with the same label path
also holds every list of a tree inside a `T`, which the signature names under its variable `a`. So a
function's answer or escape of `a` never reached the caller's deep lists.

**The passes.**

| Pass | What it found | Program |
|---|---|---|
| 1 | the exact match of a deep location | `CycleAnswer`, `CycleEscape` |
| 2 | the same through a wide ancestor inside the deep level; a row step the place walk cannot follow, read as "no cycle" | `CycleAncestor`, `CycleRow` |
| 3 | the same through the row branch of the walk | `CycleRowField` |
| 4 | a wider cycle nested in another's deep level, where only the outer one was tested | `CycleNested` |
| 5 | a location that stands for two places, two cycles, where one sample path was tested | `CycleMerged` |
| 6 | nothing | — |
| 7 | the speed rule below | `CycleAboveVariable` |

Passes 1 to 5 tried to decide "is the caller's cycle wider?" more and more precisely, from label paths,
then from one sample path of places. Pass 5 showed why that cannot be complete: a location can stand for
several places. **The rule now** (`Loc.cycleWider`) reads one positive fact: the signature has a type
variable or a row at or below the start of the deep level. Where it has none, the region is a concrete
type, the caller's type there is the same type, and each deep location names the same cells in both.
Where it has one, every match the walk can take inside the deep level — the location, a wide entry above
it, a row that holds its field — answers `Loc.all`. Pass 6 found it sound. It checked the claim
"no variable means the same cells", a variable hidden behind a cell, a closure or a foreign value (the
only ways in give values the checker cannot write), merged locations, an empty layout, the over-limit
layout, a wide entry at or above the deep level's start, and the reverse direction as `locsMeet` reads
it.

**The speed rule, reverted.** The rule doubled v3's time on `bench/corpus` (§4). A sharper rule — wider
only where the caller's layout has an entry under a variable's path — brought most of it back. Pass 7
broke it: a caller that enters its cycle above the variable (`List (Tree2 T)`) has the argument's
objects under member labels, not under the variable's path. The commit is reverted and its program is a
test. The speed is an open finding (§4); a rule that wins it back must decide by every place, not by
label paths or one sample.

The reviewer also checked and found sound: `locsMeet`'s rule that one direction decides, given a
correct `cover`; the narrowing by `within` and by `exact`; rows and type variables at eleven
holders; the entry with rows and variables (six programs); `Fn.rewrites` handed on through a helper, a
closure, a local function, a pipe, `Maybe.map` and a tuple; `writesOwn` and `keepsOwn` past the
arity; `edgeEffect` for the compiler's own terms; `Schema` codecs; core callbacks that write a
`Ref`'s or a `Dict`'s contents. It did not prove a cycle that passes through a closure's answer or a
cell's contents, and found no way to write a cell there.

## Appendix A. Commands

Scratch in `~/.cache/beni-agents/fix125/`; `base` is a worktree at `37ec2e1971`, `wt` this work.

```sh
# compilers
(cd base && zig build -Doptimize=ReleaseSafe --prefix ../before)
(cd wt && zig build -Doptimize=ReleaseSafe --prefix ../after)
# programs: each generator into sweeps/<name>; each fault folder copied with a LIST
node bench/ownership-sweeps/<generator>.mjs sweeps/<generator>
node bench/ownership-sweeps/run.mjs --beni=<compiler> --checker=v3 --tag=<before|after> --jobs=24 --tmp=tmp sweeps/<name>
# the sanitiser corpus and the real writes
node bench/ownership-step0-sanitiser.mjs --beni=<compiler> --jobs=14
node bench/ownership-v2-review.mjs --beni=<compiler> --checkers=v1,v3 --roots=real --runs=1 --jobs=8
# speed: a ReleaseFast LLVM compiler of each tree
zig build test-perf "-Dtest-filter=generated module of §7.6"
node bench/ownership-v2-review.mjs --beni=zig-out/perf/bin/beni --checkers=v1,v2,v3 --roots=real --runs=3 --jobs=1
# the tests before the fix: the test file copied into base
(cd base && zig build test-blackbox-check "-Dtest-filter=sixth blind test")
```
