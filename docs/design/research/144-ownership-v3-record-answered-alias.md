# 144 — The answered alias of a record write

*Research report, 2026-11-15. A blind round on records written in place (research report 142, kernel
§11) found a soundness fault in the checker v3 (`--ownership=v3`): a callee that writes a field of one
parameter and answers another was accepted where its caller handed it one record at both places. This
report finds the root cause, fixes it as one rule for every kind of cell, audits each place where kernel
§11 treats a slot otherwise than a list's cell, and measures the change.*

---

## 1. Result

- **The fault**: `g u v = ( { u | a = u.a + 5 }, v )`, called as `g q q`. The copying program prints
  `5 0`, the in-place program `5 5`. The blind round reached it through every way of putting one record
  at two places: two arguments, a tuple, a field, a constructor, `Maybe`, a `Dict` value, a closure, a
  nested level and the same after `Record.copy`, an extensible row, `==` and a method on the answer, self,
  mutual and tail recursion (a loop whose state keeps a snapshot of one of its own records), and
  `browser-inline` pages. 34 TRAPs of about 900 programs, every one this cause.
- **The cause** (§2): a contract had no flag for a parameter's field slot that the body only answers.
  Test 2 of the write rule (kernel §5, "no other operand reaches W") counts a location of another operand
  only where the callee's contract flags it, so the answered slot was no operand. A list location the
  body answers is flagged read, and the same shape with `List.push` was refused (`disjoint`).
- **The fix** (§3): one flag, `Contract.flag_a`, "the body answers this location", set on every answered
  location of every kind. Test 2 counts every flagged location, so it counts an answered one for a slot
  as for a list. `readBy` does not read a location that is only answered, so what a call reads at its
  time is what it read before, and no later-read verdict moves.
- **The sweeps** (§6): 0 faults in every leg on the blind round's 878 programs, `records.mjs` (1 876,
  of which 1 156 are new programs of this class), the corpus (1 657) and the 15 569 programs of the
  sweep generators that hold a record update.
- **Verdicts** (§7): no list line changes anywhere. The corpus's ownership lines are the same line for
  line, so report 142's 37 refused record programs stay as they were. The only programs whose verdict
  moves are of the fault's shape.
- **Speed** (§8): v3 on the real roots takes 1 136 ms against 1 122 ms before at the best of three runs (+1.3%), with the same 1 359 demands and verdicts.

## 2. Root cause

A contract flags each location of each parameter: `flag_w` (written), `flag_e` (escaped), `flag_r`
(read), `flag_s` (handed to a function that can write it). At a call, `apply` makes a demand for each
written location with the other arguments as operands (`Other`, with the callee's flags for each), and
`otherReaches` tests each location of each operand **whose flag is not zero** (kernel §5, test 2).

`Frame.finish` sets the flags of what the body answers in two places, and both skipped a record's field
slot (report 142 §3.4, kernel §11 as it stood):

- the frame's answer is read where it is answered (`eval` with `tail`), and `finish` marked every atom of
  that read `flag_r` **except a slot atom** (`if (u.tail and f.isSlotAtom(a)) continue`);
- each `param` source of each result location was marked `flag_r` **except a location of kind `.field`**.

The intent was right for one test and wrong for the other. A call's read of its arguments (`readBy`) is
test 4's input: a slot the callee only answers is not read at the call, because the caller holds the
answer and reads its cells where it reads them. But the flags are also test 2's input, and there an
answered slot is exactly the operand that matters: the callee writes `u`'s slot `.a=` and answers `v`;
when `v` is the same record, the answer is the written object. With no flag, `otherReaches` skipped `v`,
the demand passed, and §5.1 then did the rest: `f q = g q q` has the contract "writes `π1.a=`, answers
`π1` at `.0` and at `.1`", so `f`'s caller reads `.1` as the new name of the written cell and no read
of it is a later read.

The list path had no exemption: an answered list location was flagged `flag_r`, so it was read at the
call and an operand of test 2. Two rules where one was meant.

## 3. The fix: one rule for test 2

`Contract.flag_a` (`Contract.zig`): the body answers the location. `Frame.finish` sets it on every
`param` source of every result location, of every kind, and on every slot atom of the frame's tail read.
A location of any other kind that the body answers is still read as well (`flag_r`), as v3 has judged
lists from the start; a record's field slot is not.

- **Test 2** (`otherReaches`) counts a location whose flags are not zero: a read **or answered**
  location, for every kind of cell. This is the one rule (kernel §5, test 2, as revised).
- **Test 4's input** (`readBy`) reads a location whose flags say more than `flag_a`
  (`Contract.reads`). So a slot that a callee only answers is no read at the call, exactly as before:
  the fix adds refusals only where test 2 now sees an operand.

**The cost of the new operands.** With every answered slot an operand, the gates' module-budget test
(`check_test.zig`, *one budget for each module*: a record of 1 000 lists of records, written by
`g b = { b | a0 = List.push b.a0 … }` and called as `g (g b)`) stopped at a declaration's limit before
the module's: each call's demands now compared all 1 000 answered element slots `a_i[*].k=` of the
argument, which nothing flagged before. A location the callee **only** answers is now compared with the
written targets only where its kind can hold one of their cells (`canShare`, the test report 142 added:
a field slot is no list cell, and the slots of two fields are two cells); a target of no layout, or of
more than 16 kinds, can be any cell. A location the callee reads is compared whatever its kind, as
before. On that test the checker now stops at the same declaration (`g22`) as before the fix, and no
verdict of the sweeps moves between the two versions of the fix (§7).

The principle of §1 reads the same: test 2's negative fact, "no other operand reaches W", is derived
from the positive fact of each operand's flags, and the answered slot was a cell that no flag named.

## 4. The audit: where §11 treats a slot otherwise than a list's cell

Each place where `src/own3/` or kernel §11 has a branch for a slot, with what it does for a list's cell
and a verdict for the class of gap the fault belongs to (a negative fact with no positive fact under it).

| Difference | Slot | List cell | Verdict |
|---|---|---|---|
| **Parameter exemption**: the frame's answer and an answered slot are no read of a parameter in its contract (`finish`) | no flag at all | `flag_r` | **Fault** (§2). Fixed: `flag_a`, an operand of test 2, not a read at the call. |
| **Answer**: what a call reads of an argument that the callee only answers (`readBy`) | not read (now `flag_a` only) | read (`flag_r`) | Sound. The caller's result holds the argument's atoms (`expandSrcs`), so a read of the answer after a write is a later read of those atoms; a lost or unknown answer is `outside` and every argument (§3.2). The list's read is pessimistic, and stays so: no list verdict may move. |
| **Version** (§5.1): a result location whose sources the callee writes is a new name, dead at the call | the same | the same | Sound once test 2 holds. Only the atoms of a written source get a dead name (`oldNames` per source, `flag_w`/`flag_s`); an answered location the callee does not write stays the old name, alive. The fault's new name came from a contract (`f`) whose own call should have been refused. Probes: a branch that answers `v` or a written `u` (`branch`), a forwarder `fwd u v = g u v` (`forward`), a callee answering its parameter before and after its own write (refused inside it). |
| **`canShare`**: one fresh site at two locations of a result (`freshOwn`) | two slots of two fields are two cells; a slot and a list cell share only through a wide location | always may share | Sound. Two field slots are two cells of the object model; one site at two slots of one field is one cell (`payload` equal), so `( o, o )` is no own answer. |
| **`list_only`**: a callee's write of a list location | not among the written cells | written | Sound: a slot is a cell of another kind. |
| **`rootReach`**: a part of a root reaches only the slots below it | below the part only | every run | Sound: a slot is a cell of one object, and every object a part can hold is below it, the deep level of a cycle a summary. |
| **`readNoSlots`**: a list pattern reads the list, not its elements' slots | not read | read | Sound: a field read reads its slot at its own time (§11.4). |
| **Sends** (§11.6): a message's slots are supplied to `send`, not asked for | supplied | asked | No gap of this class: `send` answers nothing, and a write after the send is refused through `Fn.rewrites`. Probes (`browser-inline`): a message that holds a model record, written by `update` through the model or through the message, is refused (`unknown`). |
| **Entry** (§11.8): the runtime hands the model only at the model parameter | a model location | a model location | No gap of this class. A model whose state keeps a snapshot of one of its records (`{ model | snap = model.cur }`, then a write of `cur`) is refused (`unknown`, #2529); the blind round's page (`pairUp`) is refused at the call now. |
| **Supply** (§6.2, §6.8): what a frame hands a function parameter | the same, with the callee's flags as operands | the same | Fixed with test 2: `apply h u v = ( h u, v )` with `apply bump q q` trapped before (`applyfn`) and is refused now. |
| **`Record.copy`** (§11.7) | a new object, the same values | — | Sound: a copy is one level; the nested fault through it (`g (Record.copy r) r.p`) is the answered alias, refused now. |
| **`makesObject`, `old_result`**: an update is no new object | old | — | Pessimistic: a function that answers an update answers an object that was there before. |
| **`d.record`** | the diagnostic's text | — | Text only. |

## 5. Fixtures

Each fails before the fix (it traps under v3's sanitiser, and the in-place build prints otherwise:
`run.mjs --mode=both` on the checker of `ef3098f82e`) and passes after it (refused, with exactly the
refusals of its `.sanitize-lists-v3-refuses` file):

| Fixture | Shape |
|---|---|
| `run/RecordAnsweredAliasParams` | `g q q`: two arguments |
| `run/RecordAnsweredAliasLoopSnapshot` | `loop (k + 1) { acc \| snap = acc.cur }`, then a write of `acc.cur`'s field |
| `run/RecordAnsweredAliasNestedField` | `g r r.p` and `g (Record.copy r) r.p`: a nested level |
| `run/RecordAnsweredAliasClosure` | the callee answers `λ⊤ → v.a` |
| `run/RecordAnsweredAliasMaybe` | `g (Just q) q` |
| `run/RecordAnsweredAliasRow` | extensible-row parameters |
| `run/RecordAnsweredAliasMutual` | two mutually recursive loops share a snapshot |
| `run/RecordAnsweredAliasEquality` | a derived `==` on the two answers |

## 6. The sweeps

All on the self-hosted ReleaseSafe compiler of the fix's first commit (the flag alone; the kind filter of
§3 came after, and its dumps give every line of every sweep the same verdict, so its builds are the
same), `run.mjs --checker=v3 --mode=both` (plain;
v3 with the sanitiser and its list and record traps; v3 in place; release plain against release in
place). Faults are TRAP, DIFF, IPTRAP, IPDIFF, RIPTRAP, RIPDIFF and CRASH.

| Sweep | Programs | Same, every leg | Refused | Faults | Not judged |
|---|---:|---:|---:|---:|---:|
| the blind round (themes A–Y and its three fault folders) | 878 | 210 | 650 | 0 | 18 (12 LIMIT, 6 PLAINFAIL, as before) |
| `records.mjs`, report 142's programs | 720 | 353 | 367 | 0 | 0 |
| `records.mjs`, the answered alias (new) | 1 156 | 0 | 1 156 | 0 | 0 |
| the sweep generators' programs with a record update | 15 569 | 3 099 | 12 348 | 0 | 122 (121 PLAINFAIL pages, 1 LIMIT, as in report 142) |
| corpus (`corpus.mjs`) | 1 657 | 1 187 | 450 | 3 known, 0 new | 17 |

- **The blind round**, before → after: themes F, G, M (62 programs) 28 refused, 1 same, 31 TRAP, 2
  PLAINFAIL → 60 refused, 2 PLAINFAIL; D 31/2/1 TRAP → 32/2; P 19/8/2 TRAP → 21/8; the three fault
  programs TRAP → refused. Every other theme the same.
- **The answered alias** (`records.mjs` `aa.…`): a callee writes one operand and answers another, and its
  caller hands it one record at both places, through 16 placements (two arguments, a tuple, a record, a
  constructor, `Maybe`, a `Dict` value, a list, a closure argument, a type variable, a row, a nested field
  and the same after `Record.copy`, a function parameter, a local lambda, a record a lambda and a local
  function capture) × 5 answers (as it is, in a closure, a constructor, a record, through `ident`) × 3
  writes (an update, a helper, a helper of a second module) × 5 reads of the answer, and 6 loops. On the
  checker before the fix: 530 refused, 251 same, **375 TRAP**. After: 1 156 refused.
- **The generators' programs**: those of `blind`, `blind2`, `blind4a`, `blind4b`, `blind5c`, `blind5d`,
  `blind6e`, `blind7f`, `blind8g`, `blind9h`, `blind10i`, `callbacks-keep`, `evaluation-order`,
  `folds-callbacks` and `recursive-levels` whose source holds a record update (15 569; report 142's
  filter found 17 100 with the generators of that day).
- **The corpus**: the faults are report 142's, out of this report's scope and unchanged:
  `browser/dom/ShowAndBranches` and `browser/tea/ShowAndBranches` (#2504), and `run/ListSanitiserTrieHolder`,
  which traps as its golden says. `run/TailModConsMerge` timed out under the sanitiser on a loaded
  machine (report 142 §5). The 12 BOTHFAIL are programs that fail by design (defects, parked mains).

## 7. Verdicts before and after

By `dump --stage=ownership --ownership=v3 --ownership-everywhere`, each line's verdict (accepted or
rejected), on the checker before and after:

- **The corpus** (1 657): the same, line for line. No list line, and none of report 142's 37 refused
  record programs, moves.
- **The generators' programs** (15 569): 6 programs differ, each in one line: a record demand
  (`<call Main.step>.0.l=`) in `folds-callbacks`' `loop.acc.rec-push.ans.dir.*` and
  `loop.acc.rec-upd.ans.dir.*`, accepted before and rejected now. Each of these programs was refused
  before (a list line at the same call) and is refused after: `step` answers `( { a1 | l = … }, a1 )`, a
  loop state that keeps the record it writes — this report's shape.
- **`records.mjs`** (report 142's 720): the same.
- **The blind round** (878): 41 programs differ. 37 are the fault programs, refused now. 3 were refused
  before for another reason (`F/recself`, `P/hole.g2p`, `P/hole.g2x`). One accepted program is refused
  now: `F/recint`, a loop whose state keeps a snapshot of `cur` and then writes `cur.b`, where the
  program reads only `.a`. The recursive call answers the snapshot, the snapshot's `.b=` is the written
  cell, and at the call nothing says that no later frame reads `.b`: refusing it is what the rule needs.
- **Lists**: no list line changes in any sweep.
- **The answered alias's dead twins**: 251 programs that read only a field the callee did not write, or
  nothing, were accepted before and are refused now. At the call the caller cannot know what is read of
  the answer later; the same programs with a `List` are refused too.

## 8. Speed

`bench/ownership-v2-review.mjs --checkers=v1,v3 --roots=real --jobs=1 --runs=5`, on ReleaseFast LLVM
compilers of `ef3098f82e` (before) and of the fix, three runs each, alternated, on one machine with
other work on it (load 13 to 34):

| | run 1 | run 2 | run 3 | best |
|---|---:|---:|---:|---:|
| before, v3 ms (556 564 lines) | 1 124.3 | 1 123.4 | 1 121.8 | 1 121.8 |
| after, v3 ms | 1 137.6 | 1 135.9 | 1 138.6 | 1 135.9 |

+1.3% at the best run, the same in each pair, inside the +15% budget. The
real roots' verdicts are the same in every run:
1 359 demands, 1 286 accepted, 73 rejected. **Real list writes**: of the 308 writes v1 judges, v3
accepts 274, refuses 23 and has no line for 11, before and after, line for line (reports 130 to 138
counted 287 accepted; the base of this report counts 274, and this report moves none).

## 9. The review

**Round 1**, on the flag alone. One adversarial reader, given the diff and kernel §5 and §11, wrote 103
programs in 13 sweeps and ran them through `run.mjs --mode=both` on the fix. It found no fault: every verdict was REFUSED or SAME.
Refused: the answered alias through closures, local functions, `Maybe`, a sub-record, a list element,
rows and type variables; through `apply2 fn x = fn x x`, a function in a record field, a local lambda,
`Maybe.map`, `▷`, a `List.foldl` callback and a callee that answers `v` on one branch; one record at
two places of one argument (`{ p = q0, q = q0 }`, `{ r | q = r.p }`, `( q0, q0 )`, `[ q0, q0 ]`);
loops that keep a snapshot in a parameter, a `List`, a `Maybe`, through a helper, `Record.copy`, mutual
recursion, `foldl` or another module, observed by `==` or by a read; chains of new names and a callee
that answers its parameter before and after its own write; top-level records. Accepted and the same in
every leg, release included: field reads bound before an in-place store in many orders, a literal
default written once per call, a row write where the shared object is not written, and a
`browser-inline` page that writes a nested model field. It confirmed from the code that `readBy` reads
what it read before, that §5.1's new names are still keyed on `flag_w` and `flag_s` only, and that a
group's rounds and other modules' contracts carry `flag_a`. `browser-inline` markup that holds a record
across a write did not compile for it in that platform's `view` form; on `node` with `Ssr`, v3 refused
those shapes.

**Round 2**, on the final diff with the kind filter (§3). A fresh reader, given the diff and kernel §1,
§4.1, §5 and §11 and pointed at the filter, wrote 93 programs in 10 sweeps. It found no fault. It read the
filter as sound: it applies only to a location whose flag is exactly `flag_a`, which only a field slot
can be (every other answered location is read too); both entries it compares are of the caller's own
layouts; a slot's label is its field name's rank, so two slots of two names are two cells; answering a
record answers the written field's slot too; and a target it cannot type makes it compare every answered
location. Refused: the answered parameter through function parameters, thunks, captures and partial
application; one value at two places of a literal, a parameter, a helper or a local, and slot snapshots;
generic callees and rows, `Maybe.withDefault`, `List.head`, returned closures and partial applications;
29 functions of `core/` that hand back an element which is then updated; higher-order callees that hand
one value twice; the same shapes in a second module; `browser-inline` pages sharing a model record
through helpers and row-generic setters; writes of a field and a list at once. Accepted and the same in
every leg: six safe evaluation orders and one page. It did not run probes of `Js` or schema-made values;
those are `unknown` (§3.2) and refused by test 1.

## 10. Reproduce

```sh
node bench/ownership-sweeps/records.mjs <dir>/records
node bench/ownership-sweeps/corpus.mjs <dir>/corpus
node bench/ownership-sweeps/run.mjs --beni=zig-out/safe/bin/beni --checker=v3 --mode=both --jobs=12 --tmp=<disk> <dir>/records
```
