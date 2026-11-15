# 142 — Records written in place, judged by v3

*Research report, 2026-11-15. The owner decided the same day that records are updated in place, as
JavaScript does: `{ r | f = v }` that the ownership checker accepts writes `r`'s own object, and a write
it cannot show safe is a compile error with a copy fix (`Record.copy`), as a list's is (`backend.md`
§4). Until now the checker v3 (`--ownership=v3`, `ownership-v3-kernel.md`) judged lists only, and records
were copied under it. This report builds the oracle for records first, then the rules (kernel §11) and the
checker, then runs the sweeps and the corpus under every leg.*

---

## 1. Result

- **The oracle writes records in place** (§2). Under `--ownership=v3`, each update v3 accepts is a line of
  its lowering channel. `--lists-in-place` (dev and `--release`) stores into the base's object;
  `--sanitize-lists` copies it and poisons, on every older name of the object, each field whose value an
  in-place store would change, and `Js.same` traps two names of one object. `run.mjs --mode=both` judges
  records as it judges lists, with no change of its own.
- **A record's field slots are cells** (§3, kernel §11). A record type has one location for each field it
  names, the slot that holds the field's value. An update is a demand of the slots it names; a field read
  reads its slot; an update's answer is the base's object under a new name. Every other rule is the list
  rule, unchanged.
- **No soundness fault** in any leg on the record sweep, the corpus, or the 17 100 sweep programs that hold
  a record update (§5).
- **Identity**: `browser-inline`, the static site generator and `core/` decide nothing by the identity of
  a record (§4). A hole refreshes because the write set names a field it reads, and the write set follows a
  write into helpers of the module and of other modules, callbacks of `core/` and commands' messages; where
  it cannot, it refreshes every hole under the path. The `dom` lowering keys a `Show` by identity and
  shows a stale page when a record is written in place (`browser/dom/ShowAndBranches`): out of scope, #2504.
- **List verdicts** (§6): no list refusal is gone, on the corpus or on 27 071 sweep programs. New
  refusals are of writes that record updates make. 37 corpus programs that v1 accepts with
  `--records-in-place` are refused, each in an issue (§7): the entry (#2529), reads of a written field
  that v1 hoists (#2517), rows and callbacks (#2518), and three whose base is top-level or unknown.
- **CLAUDE.md rule 8** says field identity is load-bearing; with records written in place it is not
  (§4, last paragraph). The manager edits CLAUDE.md.

## 2. The oracle

`Lower.recordWrittenV3`: in a build under `--ownership=v3` with either oracle (`Input.records_v3`), an
update the module's channel lists (`Hoists.Write`, kind `update`) is

- under `--lists-in-place`, v1's in-place form, `(r.f₁ = v₁, …, r)`, every value evaluated first
  (`recordUpdateInPlace`, with v1's hoisting and its nested-store skip off: v3 hoists nothing);
- under `--sanitize-lists`, the plain spread `{ ...r, f₁: v₁ }` with `r` bound to a name, handed to the
  runtime's `record(r, copy, site)` (`recordUpdateSanitized`).

The channel now carries `update` lines (`Hoists.Builder.add`); only `records_v3` reads them. Core and the
platforms authorise no write of their own, so their updates stay spreads in every leg, as their list
writes do.

**The trap** (`sanitize_runtime.mjs`, `record`). In place, every name the program kept of a record is one
object. Here each update makes a copy, so the objects of one in-place identity are a group, the newest
last. At each update, each field of each older member whose value differs from the copy's is redefined as
a getter that throws: a read of it is exactly a read that an in-place run would answer with another
value. A field whose value is the same object or the same scalar is left alone, since in place it reads the
same. A spread of a stale record (an update whose base is an older name) traps at the copy, where the
in-place run would carry the newer fields into the answer. `same(a, b)` throws when `a` and `b` are two
members of one group: in place they are one object. Core's identity compares are §4's.

## 3. The rules (kernel §11)

1. **Slots.** `Loc.addSlots` gives a record place one location `.f=` per field it names, of kind `field`.
   It is no step of the place graph: a layout's path to it ends in the field's step with `Loc.slot_bit`.
   Under an element step it is a summary; in the deep level of a cycle the slots of one field of every
   record of the cycle are one summary location. A row's fields are the row's location, which covers
   every slot below it (`Loc.within`, `Loc.cover`).
2. **A literal** is a construction of its values plus one more part, the object: a root the frame made
   whose slots are `own` (`Frame.recordOf`). Keeping the construction keeps a `join`'s arms: making the
   literal a root flattened them and refused `ListPrependDeep`'s push, which is accepted.
3. **An update** (`recordUpdate`) evaluates the base, then the values, then demands the base's atoms at the
   slots it names, with each value as another operand. It reads every slot of the base at that time. Its
   answer's slots are the base's under a new name (`version`, dead at the update), so a chain of updates
   through new names is accepted and a write through an older name is refused. An update makes no object
   (`makesObject`): a function that answers one answers an old object.
4. **Reads.** `r.f` and a record pattern's field read the slot (`readSlots`); a whole read reads every slot.
   A list pattern reads the list, not its elements' slots (`readNoSlots`). The frame's answer is read where
   it is answered, but its slots are not a read of a parameter in the contract, and neither is an answered
   slot: the caller holds the answer and reads the slots where it reads them. A callee that answers a name
   older than its own write is still refused inside it.
5. **Kinds.** A callee's write of a `list` location writes no slot (`DemandIn.list_only`); a part of a root
   reaches only the slots below it (`rootReach`).
6. **Sends.** A message's slots are supplied to `send` like any function parameter, not asked for: `update`
   never writes a message, and a write of them after the send is refused through `Fn.rewrites`.
7. **`Record.copy`** is `borrowed { r | } → copyof { r | }`. A direct call is applied as a record the frame
   makes from the argument's values (`recordCopy`); every other use reads its contract, which puts a new cell
   and every cell of the argument at each location of the answer. v2 reads the declaration as the `foreign`
   with no word it was (`own2/Rows.fromWords`), so v1 and v2 judge exactly as before.
8. **The entry.** The runtime hands the model only at the model parameter: a consumer's other parameter (a
   `Url`) is no model location (`entryCall`). Before, the `Url` record had no location and the question did
   not arise; with slots, the call map compared `Url`'s slots with the model's and took the model's `own`
   away (`browser/tea/Router`, `Routes`).

## 4. Identity and refresh, with a verdict each

**`browser-inline`.** Safe. Which holes refresh after a key is fixed at compile time: the handler runs the
buckets of `keyBuckets(k)` (`inline.zig` `handlerBody`, `passOf`), from `Emit.sparseConflicts` and
`Writes.conflicts`. The compares are scalars against the DOM (`Inline.text`, `prop`, `writeProp`), arm
numbers (`taken === n`), attribute and option strings. `copyIn`'s `next === old` skips a copy of a route's
answer that is the old object, which holds every field already. `copy` and `planned` write into the old
object, which keeps its identity. `Key.replaced` decides stores and cells, not refresh. Keyed rows are not
built, and §9.4 already forbids identity there. `Navigation`'s `Js.same` compare strings and numbers.

**The write set follows the write.** A helper of the module or of another module is summarised from its
body and instantiated at the call (`Writes.applyClosure`, `direct`); `List.map`, `indexedMap`, `update` and
the `Dict` rows write `p[*].f`; `Maybe.map` and `Result` are walked; a command's message is a key. Where the
pass cannot follow (an unknown callee, a body-less `foreign`, the depth, recursion or work caps) the write
is `Fresh` or `value ρ`, and `conflicts` matches every read under the path; a key cut short is refused.
New fixture: `browser/inline/HelperOtherModuleWrite`, where each key writes the model through a helper of
another module, one inside a `Maybe.map` callback, and the program's own holes read the written fields. It
prints the same page plain, under v3's sanitiser and in place. `browser-inline.md` §8.3 says this now.

**The static site generator** (`Browser.prerender`, `html`, `node`'s `Rt.beni` and `ssr`): lengths,
strings, arm numbers, sockets. Safe.

**`core/`.** A derived `==` or `compare` of a record compares field by field, with no identity shortcut
(`Lower.structuralArrow`); `List.eq`, `Dict.eq` likewise. `List.cons`, `reconsed`, `set`, `claim`, `trieSet`
ask whether a slot already holds the object stored: if it does, it holds the new value, written or not.
Safe.

**Out of scope.** `platforms/browser/zig/dom.zig` guards a kept `let` and each hole with `v !== i.aK`, and
`Rt.beni` reuses rows and a keyed `Show` by item identity: a record written in place compares equal and
shows a stale value. The sweep found it in `browser/dom/ShowAndBranches` and `browser/tea/ShowAndBranches`
(TRAP under the sanitiser, DIFF in place). That is #2504's class; nothing there was changed.

**CLAUDE.md rule 8** says that field identity is load-bearing: "values are immutable and a record update is
a spread, so an untouched value is the same object: field identity is load-bearing, and no optimiser change
may break it." With records written in place that is no longer true of `browser-inline`: an updated record
is the same object, and a hole refreshes because the write set names the field it reads. Rule 8's sentence
needs the manager's edit; this report does not touch CLAUDE.md.

## 5. The sweeps

Every program built plain, under v3's sanitiser with the trap, in place, and, when those three pass, under
`--release` plain and in place (`run.mjs --mode=both`, research report 141). Faults are TRAP, DIFF,
IPTRAP, IPDIFF, RIPTRAP, RIPDIFF and CRASH.

| Sweep | Programs | Same output, every leg | Refused | Faults | Not judged |
|---|---:|---:|---:|---:|---:|
| `records.mjs` (new) | 720 | 353 | 367 | 0 | 0 |
| report 140's generators, each program with a record update | 17 100 | 3 641 | 13 337 | 0 | 122 |
| corpus `run/` | 1 087 | 739 | 334 | 0 | 14 |
| corpus `browser/inline/` | 124 | 111 | 13 | 0 | 0 |
| corpus `browser/prerender/` | 31 | 31 | 0 | 0 | 0 |
| corpus `browser/` pages | 2 | 2 | 0 | 0 | 0 |
| corpus `browser/dom/` (out of scope) | 72 | 63 | 8 | 1 | 0 |
| corpus `browser/tea/` (out of scope) | 284 | 240 | 41 | 1 | 2 |
| corpus `browser/managed/` | 54 | 0 | 53 | 0 | 1 |

- **`records.mjs`**: every `live` twin is refused, and every accepted program is a `dead` twin. Of the 405
  `dead` twins 52 are refused: 33 update an element in a `List.map` callback, which the row does not hand
  `free`, and 19 read a `Dict` value through `Dict.get`, whose row over a type variable reads every slot of
  the value (#2518).
- **Report 140's generators**: the 17 100 programs of its 82 564 whose source holds a record update, by
  generator: `blind4b` 5 056, `folds-callbacks` 5 050, `blind9h` 3 144, `blind5d` 1 068, `blind7f` 828,
  `blind` 816, `blind10i` 420, `blind6e` 200, `recursive-levels` 177, `callbacks-keep` 120, `blind5c` 118,
  `blind2` 42, `evaluation-order` 24, `blind8g` 23, `blind4a` 14. A program with no record update builds
  every leg as before: the lowering changes only at an update v3 accepted, and §6 shows that v3's
  verdicts on lists are unchanged. *Not judged*: 121 `PLAINFAIL` pages of `blind10i` and `blind6e` that
  the platform does not compile (report 140's), and one `LIMIT` of `blind8g`.
- **The corpus**: the two faults are `browser/dom/ShowAndBranches` and `browser/tea/ShowAndBranches`,
  the `dom` lowering's keyed `Show` (§4). `run/ListSanitiserTrieHolder` traps under the sanitiser as its
  golden says (report 140). `run/TailModConsMerge` passed its 20 s under the sanitiser on a loaded machine
  and on the compiler before this change alike (46 s and 49 s alone); it has no record update.
- **The review's probes** (§8): about 70 hand-written programs, and the corpus again: no fault but the
  `dom` one.

## 6. List verdicts before and after

- **The corpus**, by `dump --stage=ownership --ownership=v3` of every program, without the lines of
  updates and of slots: the same on every program but `run/SanitiserFieldCall`, where a caller's line of a
  write that the callee refuses anyway (`r.load ⊤` is unknown code, and its row holds the record's slots)
  moved from accepted to refused, and `run/SanitiserRowWider`, refused for another reason. The other 11
  programs whose lines differ differ in lines of records.
- **27 071 sweep programs** (the 17 100 above and a tenth of the others), by the diagnostics of a v3
  build, on the compiler before and after: no list refusal is gone. 324 programs have more: each at a
  write that a record update in a callback or a function makes (`List.map`, `foldl`, `foldr`,
  `indexedMap`, `Maybe.map`, `andThen` with a record-updating callback; the entry; a function value that
  updates its parameter). 259 of them were accepted before. Where the written location is a type variable
  that holds a list and a record's slots, the diagnostic says `LIST CHANGED WHILE STILL IN USE`.
- What changed for lists is what records add to a location: a type with records has more locations, so
  layouts are larger (a record of 1 300 lists now passes the 4 096-location limit, and the budget test
  of research report 130 uses 1 000), and an `unknown` value or a type variable holds slots too.

## 7. Safe real programs refused

37 corpus programs that v1 accepts with `--records-in-place`, and that v3 accepted before it judged
records, are refused now. Each is in an issue:

- **#2529, the entry (24):** `update`'s write of a model slot is refused because the model slot is not
  `own`. `browser/inline/` CaseLoader, NestedStableLoad, PartialRoutes, ResearchS3, ShapeLoader,
  SnapshotFromTable, TickFresh, TickInPlace, ValidatedLoader, ModelCallback; `browser/tea/` TodoMVC,
  TodoRouting, ControlledUnseen, DefectInUpdate, KeyedInPlaceMap, KeyedOriginal, LogCommandContext,
  TemplateChildren, VerifyAttributeOrder; `browser/dom/` ControlledUnseen, Keyed, KeyedInPlace,
  LiveRowsOnce, SkippedMarkupLive, StatefulNested. TodoMVC's: `changed model todos = ( { model | todos =
  todos }, save todos )` puts each element at two places of the answer.
- **#2517, a read of a written field after the update (6):** `run/RecordHoistValues`,
  `RecordInPlaceValues`, `ListPersistence`, `browser/tea/RecordUpdateCompare`, and the second refusal of
  TodoMVC, TodoRouting and LogCommandContext (`changed { model | nextId = model.nextId + 1 }
  (… model.nextId …)`). v1 moves the read before the stores.
- **#2518, rows and callbacks (5):** `run/PayloadUnreadField` (a record a schema decoded),
  `FieldColouringSchema`, `SchemaTypeConstructorArgument` (a schema's answer), `browser/tea/OpaqueUpdate`,
  `OpaquePageKeys` (a callee hands the function a value it does not own).
- **The base is top-level or unknown (3):** `run/EvalOrderLiterals` updates a top-level record
  (`{ base | … }`), `run/PtsLiveSiteOrder` and `ShapeRecordNames` a model a test platform makes. In place
  these would write a value every reader shares or that no fact names; the refusal stands, and its fix is
  `{ Record.copy base | … }`.

`run/SanitiserCellCapture`, a list fixture, is refused too: its `Ref.update` function updates the cell's
record, and a cell's contents are never `own` (#2518). It left the list of accepted twins in
`check_test.zig`.

## 8. The review

One adversarial reader read the change before it was pushed, with about 70 probes and the corpus in
every leg. It found one fault: the `dom` lowering's keyed `Show` keeps its last value and compares the
next by identity, so a record written in place keeps the old body (§4). That is the platform rule of
`boundary.md` §9.4.4 (*Skip on a record's identity*) and §9.4.8 broken by a platform out of this report's
scope; §9.4.8 and kernel §11 now say that the rule holds of records as of lists, and #2504 has the
finding. It found no fault in the tail-read and answered-slot exemptions, `list_only`, `rootReach`,
`readNoSlots`, `Record.copy`, nested updates, release builds, derived `==`, closures or fibers, and noted
the `List.map` refusal of §7 (#2518).

After the review: a refused write that reaches a list says `LIST CHANGED` (it said `RECORD CHANGED`
wherever one slot was among its cells); a fresh site that a callee's wide location puts at two field slots
is two cells (`Frame.canShare`), which accepts 9 corpus pages of `dom` and `tea` (SAME in every leg); and
the test of a part's slots in `rootReach` marks them once, where it scanned the part for each slot (a
record of 1 300 lists spent a declaration's budget there).

## 9. Reproduce

```sh
node bench/ownership-sweeps/records.mjs <dir>/records
node bench/ownership-sweeps/corpus.mjs <dir>/corpus
node bench/ownership-sweeps/run.mjs --beni=zig-out/safe/bin/beni --checker=v3 --mode=both --jobs=16 --tmp=<disk> <dir>/records
```
