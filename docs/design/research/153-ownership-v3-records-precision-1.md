# 153 — Ownership v3: records precision, round 1

*Research report, 2026-11-17. The first lane of the records precision round of the checker v3
(`--ownership=v3`, `src/own3/`): win back safe programs v3 refuses since records are written in place
(research report 142), without losing soundness. Issues #2529, #2517, #2518 and #2508. It adds kernel
(`ownership-v3-kernel.md`) §6 rule 3's *A kept closure is observed only through its calls*, rule 10's
*A platform's trusted row* and §11 item 10.*

---

## 1. Result

| Issue | Rule | Won | Left |
|---|---|---|---|
| #2529 the entry | a kept closure escapes only the capture locations its contract reaches (§2) | TodoMVC's and TodoRouting's entry lines; 6 pages of 24 wholly (`dom`/`tea` ControlledUnseen, `dom` LiveRowsOnce, SkippedMarkupLive; TodoMVC and TodoRouting with §3) | 18 pages: decoded loaders, a list pattern's head and rest, built holes, component props (§5) |
| #2517 a read of a written field | the lowering reads it first where the update runs on every path to it (§3) | TodoMVC, TodoRouting, 4 lines of `RecordHoistValues`, 1 of `RecordInPlaceValues`, the four `bench/todomvc` apps, `examples/chat/page` | reads through a `let`, a pattern, a capture or a call's write, an update in a `case` arm (v1 places these) |
| #2508 item 1 | `Hosted.compare : borrowed Key, borrowed Key → Order`, a trusted row: built, then withdrawn (§4) | — | the owner's condition does not hold |
| #2508 items 2–3 | not built: a design choice (§6) | — | the message's sources |
| #2518 | not built (§5) | — | already accepted: a `List.map` callback that updates its element; left: `Dict.get`, schema answers |

- **Real-writes ledger** (`ownership-v2-review.mjs --checkers=v1,v3 --roots=real`): **294 of 308 before and
  after**, row for row. Five v3 refusals at positions v1 has no line for are gone (44 → 39): the
  four `bench/todomvc` apps' and `examples/chat/page`'s `update model` (§3).
- **Verdicts on every ownership root** (§7): of 2 422 roots, 20 change a verdict and 52 lines go from
  refused to accepted; **none goes from accepted to refused**.
- **Sweeps** (§8): see the table.
- **Reviews** (§9).

## 2. A kept closure is observed only through its calls (#2529)

A holder that the walk does not follow and that keeps a closure (an item of markup the runtime keeps,
unknown code, a holder that lost the function) escaped every cell of every capture (`escape` → `allLeaves`).
But the one thing such a holder can do with a closure's environment is run its code, and a run reaches a
capture location only where the closure's contract has a flag, a source of the answer or a supply for it.
So `escape` now escapes, of a closure, only those leaves (`Frame.heldLeaves`, `closureHeld`). A captured
function, a contract that casts, and a draft escape whole. TodoMVC's `onCheck={λ_ → Toggle todo.id}`
reads `todo.id=` alone, so `update`'s write of `todo.completed` and `todo.title` is the model's own.

Fixtures: `browser/inline/KeptHandlerOtherField` (refused on the base, accepted, `SAME` in every leg) and
its live twin `KeptHandlerSameField` (the handler reads the written field: refused before and after).

## 3. A read of a written field, read first (#2517)

v1 binds a later read of a written field to a temporary before the update's stores (`ownership-checker.md`
§31.14). v3 now does the same for a subset it can prove (kernel §11 item 10, `Frame.hoistRow`,
`runsBefore`): the read is a chain of field reads from a parameter, and below the nearest instruction
common to the update and the read, the update is in a part that runs whenever that instruction does (a
call's callee or argument, but only the first of a callee the lowering may short-circuit; a construction's
part; a `case`'s scrutinee; a `let`'s definition), with no `let` block of its own between, before the part
that holds the read. Test 4 then skips the read, and the update's line carries a row. Where one read with a row is a part of another's
chain (`p.a` of `p.a.f`), each would be bound at its own update and the longer one after the first
update's stores, so every update that carries such a row is refused (`hoistsApart`; the first review's
fault, §9). The rows go to the
lowering through a channel of v3's own (`own3/Reads.zig`, `Check.hoist_reads`, `Lower.Input.v3_reads`),
which the lowering reads as v1's rows; v3's sanitised update places them before its copy.

Fixtures: `run/HoistFieldRead` (a later argument, a later `let`, two updates in a row; refused on the base,
accepted, `SAME` in every leg) `run/HoistFieldReadWhole` (the old name read whole: refused) and `run/HoistChainTwoUpdates` (the
review's fault: two updates of one chain, refused; accepted and trapping before the fix). `run/
RecordStillUsedV3`'s `oldField` now reads the old value through `Record.copy`, which no temporary stands
for, so it stays the refusal it tests.

## 4. `Hosted.compare`: the row is withdrawn (#2508 item 1)

The owner approved `Hosted.compare : borrowed Key, borrowed Key → Order` on 2026-11-15 on one condition:
that `Key` is opaque, so the types guarantee every `Key` comes from `Hosted.key`, whose comparer is the
key type's own `compare`, judged as evidence where `key` is called. Built (`79e7d7ec0e`), it won `Tea`'s
nine evidence refusals of its tables. The second review (§9) found that the condition does not hold: a
project may ship its own platform layer on `browser-tea`, which may import `Js` and `Hosted`, and make a
`Key` with `Js.to` whose comparer is any function the program gives. With one that keeps its key, the row
accepted a later push of the key's list, which trapped under the sanitiser and printed another page in
place. The row is withdrawn; kernel §6 rule 10 says why, and `browser/tea/KeyForgedKeeps` (the review's
program, refused) and `KeyCompareKept` (a writing `compare` refused at `Cmd.keyed`) pin both halves for
a future row. Making the fact true (no `Key` from a cast outside `Hosted`) is the owner's to decide (#2552).

## 5. What was not won, and why

- **#2529, loaders** (the ten `browser/inline` pages but `ModelCallback`): the model's slot is the answer
  of a derived codec (`Json.decodeValue`, `Schema.read`), code with no contract, so `outside`. Winning it
  needs a fact that a compiled decode worker answers new objects at every location where no `via` and no
  declared `codec` value is on the path. That is #2518's third bullet as well.
- **#2529, a list pattern's head and rest** (`dom/Keyed`, `KeyedInPlace`, `tea/KeyedInPlaceMap`,
  `KeyedOriginal`): `rotate` answers `rest ++ [ x ]`, and the two parts read one summary location of the
  parameter, so the answer is `twice`. A head and a rest of one list that holds each cell once are apart,
  but no atom says which position it was read at.
- **#2529, built holes and component props** (`StatefulNested`, `VerifyAttributeOrder`,
  `TemplateChildren`): a `Just (markup)` hole and a component's children escape whatever a hole reads,
  the whole model. `dom` and `tea` only, which the round leaves (#2504).
- **#2529, others**: `DefectInUpdate` (`Debug.todo`'s answer is one fresh site at every location),
  `ModelCallback` (a function in the model, called by `update`), `LogCommandContext` (a command's body
  keeps the model, and a read after the write through `Log.withSink`).
- **#2518**: a `List.map` callback that updates its element is accepted already (`traverseAt` hands it
  `taken`); its 33 dead twins are refused because `headOr (List.map [ r0 ] f) r0` can answer `r0`. A
  `Dict.get` reads the value's slots at the call: treating an answered type variable as answered only,
  as §11 item 9 treats a slot, did not move it, so the read is elsewhere in `Dict`'s walked contract; not
  committed.

## 6. #2508 items 2 and 3: a design choice

The owner approved "a sent message reaches `update` once and is not kept, declared per platform; `update`
owns such a message". `update` cannot tell a sent message from the others it gets, and the others are not
given up:

1. a view event's message is built from the markup, which the runtime keeps until the next render and can
   deliver twice (two clicks in one task); it can hold any cell the view could read or make;
2. a tagger's or a subscription's answer can hold what the tagger captured, at every delivery;
3. a `send` asks nothing of the sender today (kernel §6 rule 13, research report 143), so a sent list can
   still be held by the sender.

So "the message is `own`" needs a fact for each of the three. **Recommendation**: v1's rule (`ownership-
checker.md` §23.6), in v3's terms: on a platform that declares the delivery fact, a location of the message
is `update`'s own only where (a) every `send` asks for its cells again, as the sender's own (kernel §6 rule
13 before report 143); (b) no consumer of the record lets a cell escape at a kept item of its markup (the
view's contract has no escape flag and no escaped fresh site), since such a cell can come back in an
event's message; and (c) every tagger the program hands a command or subscription answers only the value
the runtime hands it and cells it made. Item 3 (`Cmd.map`) needs no contract of its own: `mapJob` takes a
`sync` function, so it is item 2's. Parked in #2551 for the owner.

## 7. Verdicts on every ownership root

`dump --stage=ownership --ownership=v3 --ownership-everywhere` of every root of `bench/ownership-roots.mjs`
(2 422), base (`775bfa71ea`) against the fix. Roots whose verdict lines change:

| Root | Change |
|---|---|
| `bench/todomvc` NoEditing, NoRouting, NoStorage, Sandbox | `update model` accepted (§3) |
| `examples/chat/page` | `update model` accepted (§3) |
| `browser/dom` ControlledUnseen, LiveRowsOnce, SkippedMarkupLive; `browser/tea` ControlledUnseen, PointerInput | entry lines accepted (§2) |
| `browser/tea` TodoMVC, TodoRouting; `writes/TodoMVC` | entry lines (§2) and `update model` (§3) accepted |
| `ownership/` RecordCells, RecordDemands, RecordHoistChannel; `run/` RecordHoistValues, RecordInPlaceValues, SchemaDeclDepth, SchemaDepth | later reads read first (§3) |

**Refused → accepted: 52 lines. Accepted → refused: 0.** `run/RecordInPlaceValues` keeps one refusal pair, a
chain that two updates hold (`m.form`, `m.form.name`, §3).

## 8. Sweeps

`bench/ownership-sweeps/run.mjs --checker=v3 --mode=both --jobs=20` (plain, sanitised, in place, and the release
pair) with the self-hosted ReleaseSafe compiler of `31903261a5` (the Hosted row still in; its withdrawal only
refuses more, so it can add no fault): every generator of the folder, its fault folders, the corpus, the
records family and the new `precision-153.mjs` (`hoist.<place>.<read>` and `kept.<handler>` with live
twins). The corpus and `precision-153` were run again on the final compiler: the same rows, and the
corpus's two new pages refused. Faults are `TRAP`, `DIFF`, `IPTRAP`, `IPDIFF`, `RIPTRAP`, `RIPDIFF`, `CRASH`.

| Sweep | Programs | SAME | REFUSED | LIMIT | Faults | Other |
|---|---:|---:|---:|---:|---:|---|
| `corpus` | 1769 | 1230 | 518 | 1 | 3 | 4 PLAINFAIL 1 TIMEOUT 12 BOTHFAIL |
| `records` | 1876 | 353 | 1523 | 0 | 0 |  |
| `p153` | 63 | 34 | 27 | 0 | 0 | 2 PLAINFAIL  |
| `blind10i-faults` | 16 | 7 | 9 | 0 | 0 |  |
| `blind2-faults` | 20 | 7 | 13 | 0 | 0 |  |
| `blind3-faults` | 10 | 3 | 7 | 0 | 0 |  |
| `blind4a-faults` | 12 | 1 | 11 | 0 | 0 |  |
| `blind4b-faults` | 8 | 4 | 3 | 1 | 0 |  |
| `blind5c-faults` | 10 | 5 | 5 | 0 | 0 |  |
| `blind5d-faults` | 10 | 5 | 5 | 0 | 0 |  |
| `blind6e-faults` | 12 | 4 | 8 | 0 | 0 |  |
| `blind7f-faults` | 2 | 0 | 0 | 0 | 0 | 2 TIMEOUT  |
| `blind8g-faults` | 8 | 4 | 3 | 1 | 0 |  |
| `blind-faults` | 24 | 11 | 13 | 0 | 0 |  |
| `bounded-walk-faults` | 12 | 2 | 4 | 2 | 0 | 4 TIMEOUT  |
| `harvest-v2-records` | 28 | 2 | 24 | 2 | 0 |  |
| `runtime-calls-faults` | 8 | 2 | 5 | 1 | 0 |  |
| `alias-ctors` | 188 | 79 | 109 | 0 | 0 |  |
| `aliased-arguments` | 5160 | 1216 | 3944 | 0 | 0 |  |
| `answers-beside` | 240 | 79 | 161 | 0 | 0 |  |
| `answers-sends` | 54 | 19 | 35 | 0 | 0 |  |
| `as-scrutinees` | 468 | 228 | 240 | 0 | 0 |  |
| `blind` | 9792 | 1675 | 8117 | 0 | 0 |  |
| `blind10i` | 474 | 151 | 209 | 0 | 0 | 114 PLAINFAIL  |
| `blind2` | 1202 | 501 | 701 | 0 | 0 |  |
| `blind3` | 417 | 160 | 257 | 0 | 0 |  |
| `blind4a` | 160 | 24 | 136 | 0 | 0 |  |
| `blind4b` | 6596 | 1188 | 5406 | 2 | 0 |  |
| `blind5c` | 226 | 77 | 147 | 2 | 0 |  |
| `blind5d` | 1234 | 449 | 785 | 0 | 0 |  |
| `blind6e` | 238 | 91 | 140 | 0 | 0 | 7 PLAINFAIL  |
| `blind7f` | 960 | 396 | 564 | 0 | 0 |  |
| `blind8g` | 121 | 21 | 99 | 1 | 0 |  |
| `blind9h` | 3213 | 849 | 2364 | 0 | 0 |  |
| `bounded-walk` | 34 | 5 | 7 | 4 | 0 | 18 TIMEOUT  |
| `build-read` | 1050 | 248 | 802 | 0 | 0 |  |
| `callbacks-keep` | 720 | 108 | 612 | 0 | 0 |  |
| `casts-at-vars` | 222 | 0 | 222 | 0 | 0 |  |
| `evaluation-order` | 440 | 276 | 164 | 0 | 0 |  |
| `folds-callbacks` | 30300 | 5152 | 25148 | 0 | 0 |  |
| `function-values` | 1960 | 300 | 1660 | 0 | 0 |  |
| `handed-back` | 2592 | 0 | 2592 | 0 | 0 |  |
| `host-values` | 81 | 2 | 79 | 0 | 0 |  |
| `recursive-levels` | 16131 | 3869 | 12262 | 0 | 0 |  |
| `wider-functions` | 354 | 144 | 210 | 0 | 0 |  |
| `worded-no-location` | 156 | 0 | 156 | 0 | 0 |  |
| **all** | **88 671** | 18 981 | 69 506 | 17 | **3** | |

The three faults are the known ones: `run/ListSanitiserTrieHolder`, and `dom` and `tea` `ShowAndBranches`
(#2504). The `TIMEOUT`s are of the plain build, the same on the base (`bounded-walk`: 18 on both), and
`run/TailModConsMerge` as before. Every `live` twin of `precision-153` is refused (two are `PLAINFAIL`: v1
refuses them in the plain `browser-inline` build); 34 of its 37 `dead` twins are accepted, and the three
refused are an update in an `if` arm, a read inside a lambda, and a pair the chain rule refuses (kernel
§11 item 10).

## 9. Reviews

Two fresh adversarial readers (Opus), each told to write programs the new rules accept that trap or
differ under the four legs.

- **After #2529 and #2517** (about 716 programs): **one fault**, F1. `q = { p | a = … }`, `r = { (p.a) |
  f = 77 }`, then `p.a.f`: the part `p.a` had a row at `q`'s update and the whole `p.a.f` one at `r`'s, so
  the lowering bound the whole after `q`'s stores and read the new `a` (TRAP, IPDIFF; the base refuses).
  Fixed by `hoistsApart` (§3), fixture `run/HoistChainTwoUpdates`; the reader's 89 hoist programs, rerun,
  are `SAME` or refused. No fault in the kept-closure rule: 420 `node` programs (`Task.soon` keeps a
  closure whole) and 207 `browser-inline` pages that send a handler's captures through helpers, derived
  `==`, `Debug.toString`, folds, joins, partial applications and `Cmd.perform`.
- **After #2508** (77 programs): **two faults**, both of the `Hosted.compare` row: a project's own platform
  layer forges a `Key` whose comparer keeps its key, or stashes it in a global (TRAP, DIFF; the base
  refuses). The row is withdrawn (§4), fixture `browser/tea/KeyForgedKeeps`, decision #2552. A writing
  `compare` through every carrier the reader tried is refused at `Hosted.key`; 31 more programs on the
  hoist fix found no fault.

## 10. Timing

`bench/ownership-v2-review.mjs --checkers=v3 --runs=3 --jobs=1 --roots=real` on ReleaseFast LLVM compilers of
the base (`775bfa71ea`) and the fix: v3 on the 33 real roots **1 316.3 ms → 1 326.3 ms (+0.8 %)**.

## 11. Reproduce

```sh
node bench/ownership-sweeps/precision-153.mjs <dir>/p153
node bench/ownership-sweeps/run.mjs --beni=zig-out/safe/bin/beni --checker=v3 --mode=both --jobs=20 --tmp=<disk> <dir>/p153
TMPDIR=<disk> node bench/ownership-v2-review.mjs --beni=zig-out/safe/bin/beni --checkers=v1,v3 --runs=1 --roots=real
zig build test-blackbox-corpus -Dcorpus=KeptHandler   # and HoistFieldRead, KeyCompareKept
```
