# 117 — Ownership v3: the principled kernel

*Research report, 2026-11-12. The owner ordered it on pull request #2451 after report 116: "Write the rules
and do a principled fix on the core. Delete the other patches if possible. This is still a prototype, so feel
free to do whatever you think is best. The core must have soundness." It is not normative:
`docs/design/ownership-v3-kernel.md` is. It compares the branch head `8c63889ffc` (before) with this work
(after) on the same programs, with ReleaseSafe compilers of each.*

---

## 0. Summary

The kernel text came first, then the code. One rule: **every fact a verdict depends on negatively is derived
from named, positive facts, and a fact no rule derives is the pessimistic one** (kernel §1). It is applied
in the five forms report 116 §5.2 named, with one change of shape found while building: a fresh cell's
name must be canonical, or a recursive group never settles (§2.2).

The five faults of report 115 are refused; the three fault folders have 0 traps, 0 differences and 0 crashes;
every generator of `bench/ownership-sweeps/` has 0 traps (§3). The real writes and the markup cost are in
§4 and §5. The mechanisms that the principle subsumes are gone (§2.3). The code is about the same size,
because each `switch` is exhaustive and each rule carries its argument; what left was the arguments by hand.

## 1. What changed

### 1.1 Values: no state reads "unknown" as "empty"

`v_shared` meant two things and was returned at 14 sites. It is gone. A value is now `outside` only where a
positive fact says that every cell of it is outside the frame (a top-level value, a function that captured
nothing), `unknown(V)` where the walk cannot follow it (and it holds every cell of V), and a walk that
cannot go on **gives up**: the declaration publishes no contract and accepts no write (kernel §3). Before,
a failed walk published its contract, and every importer read it. The value of a local before its binding
is a poison that safe builds assert is never read.

Every `switch` over a value kind, a root kind, an entry kind, a source kind, a use kind and the BIR tags has
no `else`.

### 1.2 Names: a fresh cell has one

`Src.fresh` was a flag. It is `fresh(k, escaped)`: `k` the allocation site, `escaped` whether the body let
the cell go. In a caller, every reader of one call names one cell by one root (`freshAtom`), so an answer at
two places overlaps with itself, a cell handed to a callback and answered is the cell in the result, and an
escaped cell is escaped where the caller reads it. These are the three shapes of report 115 §4.1.

### 1.3 Duplicates: one test, `linear` derived

`REntry.twice` is set where a run is built, by one test (`partDup`). `Root.linear` is three-valued and has
one writer (`deriveLinear`); a reader that meets `undecided` is a failed assertion in a safe build. A
callee's claim that its result's parts are apart is taken only as far as the callee could see: when the
arguments are apart, and never for an entry that holds a callback's answer, which the callee's own frame saw
as an opaque root. That last clause closed a hole the first version of this work opened (§2.1).

### 1.4 No fact by a name

- `methodCall` read `eq`/`compare` by their names as "only reads". It now runs the code the dispatch table
  names: a declaration is a call of its contract; a derived function, a codec or an evidence parameter reads
  its operands; anything else is unknown code. The by-name check of `pub` annotated methods in `Check.zig`
  is deleted; the dispatch rule covers every method, annotated or not. Evidence that keeps its operand is
  refused as evidence that writes is.
- `Check.isSender` read the alias `Send` by its name. The platform's alias now carries the word the design
  reserved for it (`pub sender type alias Send msg`, `platforms/browser/Browser.beni`), and the checker reads
  the word, through aliases of it.
- `Check.isDictFocus`/`trustFocus` edited `Dict.focus`'s inferred contract by the function's name. Deleted.
  Report 115 §5 had already found that no `Dict.update` writes in place under any checker, so it wins no
  write today.
- A worded row that does not say what it hands a function parameter handed it `shared`, which escaped
  nothing (report 115 §4.3). It hands every cell of every parameter, not `free`. A worded row whose result
  no word describes gave `shared`, which held nothing: it is `outside` plus every cell of every parameter.
  The word `fresh` named one site for the whole result, so a builder's storage and its elements were one
  cell; each location of the result is its own site.

### 1.5 Markup holds its holes

The value of markup is `unknown` over the values of its holes and the arguments of a helper call in a hole
(kernel §6.12). The `late` reads at the frame's end, which approximated this, are gone. The cost is §5.

## 2. What was learned while building

### 2.1 Six holes the first version of this work had

The first three were found by the existing black-box tests and the sanitiser corpus before any sweep ran; the
adversarial reviewer found the other three (§7) after every sweep was at 0 traps. Each is a
state that read "unknown" as "empty" in a new place:

1. **An escape recorded inside a run under construction.** `freshAtom` noted the escape of a callee's cell
   as a range into `atoms`, and the run was then compacted by `uniqueTail`: the range dangled. An escape
   now owns a copy of its atoms (`esc_atoms`).
2. **A callee's `linear` claim covered an answer it could not see.** `withBoth f xs = ( f xs, xs )` derives
   `nonlinear = false` in its own frame, because the answer root and the parameter root never overlap
   there. With `f` the identity the two parts are one list. The old `sourcesApart` step 2 checked this by
   hand; the first version deleted it and trusted the claim. The caller now tests every pair of entries
   where one holds an answer (`deriveLinear`'s `answers`).
3. **The by-name `eq` rule deleted, an evidence parameter became unknown code.** `a.eq` under
   `where a.eq` is a `param` term of the dispatch table. Read as unknown code, `List.member` let its
   operands escape, and every fold that handed `member` on refused. The caller that hands the evidence is
   judged (`evidence`), so a call of an evidence parameter reads.

### 2.2 A fresh name must be canonical

Numbering fresh cells by first appearance made a recursive group grow a new name each round:
`List.sortRange` was walked 16 times in a minute and never settled. A cell the frame made is named by the
instruction that made it; a cell a callee made by the call, the callee and the callee's site; a cell of a
callee whose contract is still a draft by the call and the callee alone (`Mod.drafts`, `Mod.siteId`). The
rounds settle, and collapsing two cells into one name is on the pessimistic side.

### 2.3 What was deleted

`Src.also`; `Src.shared` as the answer for everything unnamed (`Src.outside` names the one case that is
positive); `EKind.shared`; the `smear` value; `v_shared`; `SrcState`'s `fresh`, `shared` and `dup`;
`sourcesApart`, `linearFn`, `handsOn` and the arguments by hand in their comments (the one named exception
that survives is `alternatives`, kernel §4.4); the `late` reads of markup; `isDictFocus`/`trustFocus`;
`isSender` by name; the by-name `eq`/`compare` check; the `methodCall` read-by-name rule; the depth caps of
`markAtom` and `groundOf` (the runs are acyclic); the silent `evidenceTerm` depth cap (a refusal now).

What stays, and the rule that needs it: `unknown` (kernel §3.2), `later`/`capVal`/`solveCodes` (§6.3: a
capture bound after the closure is made is the value bound there), `twice` (§4.4), the clock (§5.3),
`argsApart`/`partsOf` (§4.4: a contract is conditional on apart arguments), the resource limits (§8).

### 2.4 Lines

| | before | after |
|---|---:|---:|
| `src/own3/` | 6 800 | 7 036 |

The deletions are about 450 lines; the additions are the exhaustive `evalInner` (every BIR tag named), the
three-valued `linear`, the fresh roots, and a doc comment on each rule naming its kernel section.

## 3. The gate

ReleaseSafe compilers; the same generated programs; `run.mjs --checker=v3`.

| Generator | Programs | before SAME | before REFUSED | before TRAP | before DIFF | before CRASH | after SAME | after REFUSED | after TRAP | after DIFF | after CRASH |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| blind-faults | 24 | 11 | 13 | 0 | 0 | 0 | 11 | 13 | 0 | 0 | 0 |
| blind2-faults | 20 | 9 | 11 | 0 | 0 | 0 | 9 | 11 | 0 | 0 | 0 |
| blind3-faults | 10 | 5 | 0 | 5 | 0 | 0 | 3 | 7 | 0 | 0 | 0 |
| blind3 | 417 | 172 | 122 | 123 | 0 | 0 | 160 | 257 | 0 | 0 | 0 |
| blind2 | 1202 | 502 | 700 | 0 | 0 | 0 | 502 | 700 | 0 | 0 | 0 |
| evaluation-order | 440 | 288 | 152 | 0 | 0 | 0 | 288 | 152 | 0 | 0 | 0 |
| answers-beside | 240 | 62 | 178 | 0 | 0 | 0 | 77 | 163 | 0 | 0 | 0 |
| wider-functions | 354 | 171 | 183 | 0 | 0 | 0 | 144 | 210 | 0 | 0 | 0 |
| callbacks-keep | 720 | 108 | 612 | 0 | 0 | 0 | 108 | 612 | 0 | 0 | 0 |
| function-values | 1960 | 250 | 1710 | 0 | 0 | 0 | 304 | 1656 | 0 | 0 | 0 |
| handed-back | 2592 | 0 | 2592 | 0 | 0 | 0 | 0 | 2592 | 0 | 0 | 0 |
| aliased-arguments | 5160 | 963 | 4197 | 0 | 0 | 0 | 1183 | 3977 | 0 | 0 | 0 |
| recursive-levels | 16131 | 4291 | 11840 | 0 | 0 | 0 | 4231 | 11900 | 0 | 0 | 0 |
| folds-callbacks | 30300 | 6182 | 24118 | 0 | 0 | 0 | 5392 | 24908 | 0 | 0 | 0 |

The 5 `live` programs of `blind3-faults/` are refused: `answer-twice` and `answer-supply` as `later-use`,
`answer-escape` and `sortwith-keep` as `escaped`, `compare-unannotated` as `later-use` at the `==`. Their
safe twins: three accepted; `answer-escape.dead` and `sortwith-keep.dead` refused, because a cell that
escaped into a `Ref` is never written again (kernel §5, test 3), whether or not the program reads the cell.

Safe twins (`dead`, `none`) refused, before → after, of the twins in the generator:
- `blind-faults`: 0 → 0 of 11
- `blind2-faults`: 1 → 1 of 10
- `blind3-faults`: 0 → 2 of 5
- `blind3`: 43 → 55 of 215
- `blind2`: 35 → 35 of 468
- `evaluation-order`: 4 → 4 of 292
- `answers-beside`: 0 → 0 of 0
- `wider-functions`: 6 → 33 of 177
- `callbacks-keep`: 0 → 0 of 0
- `function-values`: 786 → 732 of 980
- `handed-back`: 0 → 0 of 0
- `aliased-arguments`: 468 → 0 of 960
- `recursive-levels`: 1086 → 1146 of 5377
- `folds-callbacks`: 6256 → 6676 of 10476

Where the kernel refuses a safe twin that the old code accepted, the cause is a named one (one more is
the fix of review finding 1, §7: two elements of one list the frame made, read by a pattern and put into
another list, are one atom, so \`[ a, b ]\` from \`case r of [ a, b ]\` is \`twice\` — a coarseness of the summary
location, not of the rule): `wider-functions` (27,
`disjoint`/`element`) and `recursive-levels` (60, `element`) are summary locations read through a type
variable, where one reading of the type now contributes the same atom to two parts and the location is
`twice`; `folds-callbacks` (420, `supply` and `element`) are nested folds whose accumulator is a list of lists
written through a callback, most of them refused by the fix of review finding 1 (two elements of one list
read by a pattern are one atom); `blind3` (35) are comparators and `eq`s that keep an operand, refused as `escaped`
whether or not the program reads the cell again. Where it accepts more: `aliased-arguments` (468 safe twins
won back, every one), `function-values` (54), `blind3` (23), `answers-beside` (15 programs): the fresh names and
the atom test replaced `shared`, which refused every write of a location it touched.

Sanitiser corpus (`bench/ownership-step0-sanitiser.mjs`, 347 fixtures):

| | before | after |
|---|---:|---:|
| same (accepted, same output) | 101 | 97 |
| refused | 246 | 250 |
| trap, differs, crash | 0 | 0 |
| losses against v2, by cause | supply 18, call 22, unknown 15, captured 7, later-use 6, escaped 3, element 3, disjoint 1 | supply 18, call 22, later-use 14, unknown 10, captured 7, escaped 6, element 5, disjoint 1 |

Four fixtures v2 accepts moved from accepted to refused; none moved the other way; no fixture traps.

## 4. Real writes

`bench/ownership-v2-review.mjs --checkers=v1,v3 --roots=real`, the 32 real roots of report 110, the 308 list
writes v1 judges.

| | before (`8c63889ffc`) | after |
|---|---:|---:|
| accepted at v1's position | 299 | **279** |
| refused | 9 | 28 |
| no line (the write is of a location that holds no cell) | 0 | 1 |
| by v1's ground: fresh | 34 of 36 | 34 of 36 |
| call | 44 of 51 | 42 of 51 |
| param | 185 of 185 | 181 of 185 |
| entry | 16 of 16 | 3 of 16 |
| callback-param | 20 of 20 | 19 of 20 |

The 9 refusals of before stay refused for the same reasons (two `send`s of a feed that `Js.get` answers, seven
in `FormValidation`), except `FormValidation 275:13`, a write of `Dict.empty`'s empty location, which now has no
line (a location that holds no cell asks nothing). The 20 new refusals, each with the fact that would win it back:

| Writes | Where | Cause | What would win them back |
|---:|---|---|---|
| 13 | `update` of every TEA program: `model.todos`, `model.rows`, `model.lines`, `model.log`, the four `errors` of `conduit`, `sternhalma`'s `board.cells` | `entry`: the view's markup holds the model (kernel §6.12), so another function of the record keeps it and the runtime does not hand it as `update`'s own | the owner's decision of §5: a platform row saying that its runtime reads a hole's value only where it renders |
| 4 | `Tea.tableRemove`, `tableInsert` ×3 (`state.jobs#Table.0`, `d#Table.0`) | the evidence `Hosted.compare` keeps its operand: it hands it to `Js.get`, a `foreign` with no word, so the operand escapes (kernel §6.11; the escape half of report 115 §4.2) | a word on `Js.get` saying that it reads and keeps nothing (report 112 §5.4 asked for it) |
| 2 | `Tea.tableFoldl` (505:12, 506:5) | the lambda handed to the fold answers a table that can hold one cell at two places, and the fold hands the answer back (`answerOwn`, kernel §6.8) | the lambda builds its answer through `tableInsert`, whose evidence escapes (the row above); with it the answer is linear |
| 1 | `FormValidation 276:17`, `Dict.update acc…` | `Dict.focus` is no longer trusted by its name: its inferred contract hands the callback a value it reads again (kernel §6.11) | words on `Dict.focus` that say what its comment asserts, as `List.focus` has (`once taken stored`) |

The two `send`s have a line again: the alias chain `Cmd.Send msg = Browser.Send msg` is followed to the word
`sender` (`Check.aliasIsSender`). Five `more` lines are refusals at a position v1 does not judge, all `Tea`'s
`tableGet`/`tableLower`/`tableMember` with the same `Hosted.compare` evidence.

## 5. Markup: the owner's decision

The sound default makes a markup value hold its holes' values. Measured on the 308 real writes:

| Markup value | accepted of 308 | entry writes |
|---|---:|---:|
| holds its holes' values (the kernel, built) | 279 | 3 of 16 |
| holds nothing (a one-line local toggle, not committed) | 292 | 16 of 16 |

So the sound default costs **exactly 13 real writes**, every one an `update` that writes a list of the model
in place in a TEA program (`examples/todo`, `chat`, `conduit` ×4, `sternhalma`, the three TodoMVC apps, the
js-framework-benchmark app ×2, `ApiAndRoutes`). Nothing else moves between the two rows. The task's estimate
was 12 with no exemption and 4 with one for `Html.map`; the measured cost is 13, and no `Html.map` exemption
is needed to reach it: the 13 are the `view` holding the model, which is the rule itself. The owner decides
whether a platform may declare that its runtime reads a hole's value only where it renders (and never after
`update` runs): with that row the 13 come back, and the walk changes nowhere else.

## 6. Speed

ReleaseFast LLVM compiler, `bench/ownership-v2-review.mjs --checkers=v1,v2,v3 --roots=real --runs=3 --jobs=1`,
best of three, one machine.

| | lines | ms | lines per second | report 116 (before) |
|---|---:|---:|---:|---:|
| type check (for scale) | 169 830 | 245.5 | 692 000 | 714 000 |
| v1 | 169 830 | 1 035.4 | 164 000 | 170 000 |
| v2 | 169 830 | 1 283.1 | 132 000 | 138 000 |
| v3, on the modules v2 walked | 169 830 | 193.2 | **879 000** | 1 026 000 |
| v3, on all it walks | 556 436 | 516.6 | 1 077 000 | 1 284 000 |

The machine ran 3 to 4 % slower than at report 116 on the type check, v1 and v2, so the ratio is the figure:
v3 is 6.6× v2 and 5.4× v1 on the same modules, against 7.4× and 6.0× before. The kernel costs about 12 %
of v3's own time: the fresh roots, the duplicate tests over a result's entries, and the part each atom
records. The compiler timed is the final commit.

## 7. The review

One fresh Opus reviewer read the kernel document and `src/own3/` with the fault folders, no conclusions, and
was asked for a state that reads "unknown" as "empty" or a rule whose argument does not hold. It wrote about
30 probe programs on the node platform and proved two traps end to end; a third finding it could not run.

1. **Two reads of one part of a linear root were two cells.** `r = [ [ 0 ] ]; case r of [ a ] → [ a, a ]`
   then a write of `ys[0]`: accepted, and the plain and in-place builds printed different lines.
   `Atom.via` recorded only the root a cell was read through, and `dupOverlap` took two overlapping atoms
   with one linear `via` for two cells, whatever part of the root each came from. Six variants trapped
   (through a call, a recursive function, a pair handed to a writer). Fix: an atom records the part it was
   read through (`via_path`, `via_e`), and the trust applies only to two apart parts (`viaApart`, kernel
   §4.4). The reviewer's reading named the exact clause of §4.4 that did not hold.
2. **An escaped answer did not protect what the function was handed.** `keep cell g x = y = g x; Ref.set
   cell y; List.set x 0 9` with `g` the identity: accepted in the callee (the escape held the answer root's
   one atom, and `demand`'s escape test does not expand an answer to its base as `atomsReach` does) and in
   the caller (`apply` judged the write demand before `flow` noted the answer's escape). Fix: an escape of
   an answer carries `Answer.base` (`noteEscape`), and `apply` records escapes and flows before it judges
   writes (kernel §5 test 3, §6.2).
3. **`update`'s message was `own` by the runtime's word.** A message built in `view` as `Push model.items`
   holds the model's list; `update` could write `msg.items` in place while the model held it. Not run (a
   browser program), but the argument held against the code. Fix: the message is `own` only when every
   location of the model is (kernel §6.13).

Each is a hole of the kind the kernel is meant to make impossible, in a place the five forms did not name: a
fact that was recorded too coarsely (the root, not the part), too late (after the demand), or trusted by a
word (the runtime's). Each fix is one named fact, and `tests/blackbox/check_test.zig` pins the three shapes.
The reviewer found no case where `project` on a construction, `unknownOf`, `giveUp` or a null contract read
as "holds nothing", and none in the views, the core rows, recursion and drafts, `later` slots or markup.

## 8. What this report does not show

- Two fresh readers on the kernel (report 116 §9 item 1): the experiment that says whether the holder side
  converges. This work ran the author's tests.
- Records, cells and fibers (report 116 §5.4): the same five forms, not built.
- The resource limits are still a prototype's constants (kernel §8); each falls to the pessimistic side.

## 9. The markup rule, adopted (2026-11-13)

The owner took §5's decision: **a `view`'s markup holds none of the lists in its holes, and in
return every platform's runtime reads a hole's value only while it renders, and keeps no list from a
hole to read after that render.** The platform rule is `boundary.md` §9.4.8; kernel rules 12 and 13
say how the checker uses it.

### 9.1 The setting of §5 was not sound, and what was built instead

§5's measurement made every markup value hold nothing (`unknownOf(place, &.{})`). Built that way, the
checker accepts report 114 §9's fault 3 again: a `view` that puts a fresh list in markup and then
pushes onto it, in the same function or in the caller of a helper that answers the markup. On
`browser-tea` the sanitised page traps on load, and the existing pin `check_test.zig` "the faults of
the review of report 114 are refused" fails. The runtime reads the hole when it renders, which is
after the program wrote the list. The rule is about what a runtime keeps **after** a render, so it
cannot excuse a write **before** the render.

So the walk is unchanged: markup holds its holes until it is rendered. The rule is used in one
place, the entry (`entryCall`). A function of the record whose answer is the build's markup type,
or a closed record or tuple with markup in it whose other parts hold no cell (`Tea.Document`;
`Mod.isView`), does not keep what its answer holds. What it writes or lets escape still counts. A
markup primitive (`Html.map`, a `vocab_markup` declaration) answers markup that holds its arguments,
and every argument that is not markup escapes. Before, it was unknown code, so the markup it was
handed escaped. Without this, conduit's four `errors` stayed refused (288 of 308).

### 9.2 Real writes

`bench/ownership-v2-review.mjs --checkers=v1,v3 --roots=real`: **279 → 292** of 308. Entry writes are
16 of 16. The contract agent's +7 (`Js.get`, `Dict.focus`) had not landed on the branch. The 13 are
§4's: every TEA `update` that writes a model list. Nothing else moved.

### 9.3 The gate

ReleaseSafe compilers, `ca2fc63410` (before) and this change (after), the same generated programs,
`run.mjs --checker=v3`:

| Generator | Programs | before SAME | before REFUSED | before TRAP/DIFF/CRASH | after SAME | after REFUSED | after TRAP/DIFF/CRASH |
|---|---:|---:|---:|---:|---:|---:|---:|
| blind-faults | 24 | 11 | 13 | 0 | 11 | 13 | 0 |
| blind2-faults | 20 | 9 | 11 | 0 | 9 | 11 | 0 |
| blind3-faults | 10 | 3 | 7 | 0 | 3 | 7 | 0 |
| blind | 9792 | 1675 | 8117 | 0 | 1675 | 8117 | 0 |
| blind2 | 1202 | 502 | 700 | 0 | 502 | 700 | 0 |
| blind3 | 417 | 160 | 257 | 0 | 160 | 257 | 0 |
| evaluation-order | 440 | 288 | 152 | 0 | 288 | 152 | 0 |
| answers-beside | 240 | 77 | 163 | 0 | 77 | 163 | 0 |
| wider-functions | 354 | 144 | 210 | 0 | 144 | 210 | 0 |
| callbacks-keep | 720 | 108 | 612 | 0 | 108 | 612 | 0 |
| function-values | 1960 | 304 | 1656 | 0 | 304 | 1656 | 0 |
| handed-back | 2592 | 0 | 2592 | 0 | 0 | 2592 | 0 |
| aliased-arguments | 5160 | 1183 | 3977 | 0 | 1183 | 3977 | 0 |
| recursive-levels | 16131 | 4231 | 11900 | 0 | 4231 | 11900 | 0 |
| folds-callbacks | 30300 | 5392 | 24908 | 0 | 5392 | 24908 | 0 |
| blind4a-faults | 12 | 6 | 0 | 6 | 6 | 0 | 6 |

The sweeps write no markup, so no verdict moved. `blind4a-faults` landed on the branch during this work (report 118): its six `live` traps are report 118's open faults, the same before and after. The sanitiser corpus (347 fixtures): 97 same, 250
refused, 0 traps, differences or crashes, before and after. `zig build gates` is green.

### 9.4 The audit of each runtime

| Platform | Renders markup | When it reads a hole | What it keeps after the render | Keeps the rule |
|---|---|---|---|---|
| `browser` (`dom`) | yes | `view` runs in the microtask flush and its answer is rendered at once (`Rt.beni:794-799`, `808-835`). A root that escapes is a block `{ t, v: [inputs] }` whose patch reads the inputs at render (`backend.md` §15.4). | DOM; identity-safe previous values only (`dom.zig:897-917, 2485-2541, 2659-2666`; `RenderIdentity.zig:78-103`); event messages and `Html.map`'s function on nodes (`dom.zig:2346`, `Rt.beni:2259-2343`); hosted `shown`, re-shown only when no `update` ran (`Browser.beni:358-360`) | **no**: `update` can run inside a render (#2502), a helper's `let` cache keeps lists (`dom.zig:889-899`, #2503), a by-reference `For` keeps old items and compares them by identity (`Rt.beni:1342-1350`, #2504) |
| `browser-tea` | through `dom` | as `browser` | as `browser`; its commands and subscriptions are beni state that the checker sees | as `browser` (#2502 traps on `Tea.element` too) |
| `browser-inline` | yes | a binding reads the model's paths while it runs, after each handler (`browser-inline.md` §8.3); holes are text only (`inline.zig:985`) | DOM; a handler's retained helper arguments, refreshed when their path is written (`inline.zig:1585-1591`) | yes. The specified, not built, keyed rows compare by identity (`browser-inline.md` lines 1678, 1777; #2504) |
| `node` (`ssr`) | yes | as the markup is made: `{ t: string }` (`Ssr.beni:17-21`, `Rt.beni:101-120`) | nothing | yes |
| `html` | no: vocabulary only (`text`, `map`; each lowering implements them) | — | — | — |
| `cloudflare` | no markup lowering (`beni.json`) | — | — | — |

### 9.5 The tests

One fixture for each platform that renders markup, with a `.sanitize-lists-v3` file. Each is built
under `--ownership=v3 --ownership-everywhere --sanitize-lists` and must show its golden:
`run/SsrHolesInPlace`, `browser/dom/HolesInPlace`, `browser/tea/HolesInPlace` (with `Html.map` and
subscriptions) and `browser/inline/HolesInPlace`. In a second worktree, each runtime was broken on
purpose: `node`'s `Rt.list` kept its list and read the last one at the next call, `browser`'s
`Rt.forPosition` did the same, and `browser-inline`'s lowering kept the model in each binding and
read its lists at the next run. All four fixtures then failed, each with `a stale read of a list`,
and their ordinary pages still passed. A second break, a `forKeyed` that skips a render when the
kept list is the same object, failed no fixture: the sanitiser's copy is a new object, and
`List.push` still copies below 32 elements (`core/List.beni:287`), so no build writes in place yet.
§9.4.8 says this, and #2504 is that class of fault.

### 9.6 The review

One fresh Opus reviewer had the rule and the runtimes' code, and was asked for a path that reads a
hole's list after rendering. It proved five faults with probe programs:

1. **New, caused by this change:** in Chrome, removing a focused input fires `blur` inside the
   render; `$$root` runs `update` at once, and the patch then reads the old block. v3 refused the
   program before and accepts it now (#2502). happy-dom fires no such blur, so the gates cannot see
   it. Fixing it changes the dispatch order of `boundary.md` §9.8.4, so it was filed, not fixed.
2. **Older:** a hole's expression runs at render from the root's inputs, but the walk holds its
   result: `m = <p>{List.sum xs}</p>`, then `List.push xs 9`, is accepted and traps (#2505).
3. **Older:** markup kept in the model has no layout entry at the entry (#2506).
4. **Older, no markup:** `init` can answer one fresh list at two model locations (#2507; report 118 §4.2 found it too).
5. **Older:** the `dom` lowering's `let` cache keeps a helper's list between renders (#2503).

It found the identity skips, hosted `shown`, after-render work, `Html.map`'s context, subscriptions,
`Tea.application`'s handlers, `ssr` and `browser-inline` safe. `Browser.programs` with nested mounts,
workers and prerender hydration were not tested.
## 10. The rows of `Js.get` and `Dict.focus`

§4 named two missing rows as the facts that would win back 7 of the lost writes: a word on `Js.get` (6, in
`Tea`) and words on `Dict.focus` (1, `FormValidation 276:17`). Each was written, measured and refused on
its argument. **None of the 7 is won back; real writes do not move**, every line as before (279 of 308 on `ca2fc63410`, 292 on `c9b784cef3`, which has §9's markup rule). The work
found three soundness holes instead, two of them fixed here.

### 10.1 `Js.get` has no true narrower row

`get o name` is `o[name]`. A property read runs a getter or a proxy's `get` trap with `o` as receiver, and
turns an object `name` into a key with its `toString`. Each can keep what it is handed. The row first
proposed, `borrowed Value, borrowed name → unknown Value`, claims that neither escapes: the adversarial
review (§10.4) declared it on a probe platform and proved two traps, a getter on `Array.prototype` that keeps
the list and a `toString` that keeps the name object. `platforms/browser/Rt.beni` defines an accessor
already. So `Js.get` stays unknown code, which is its true row.

It would not have won the writes either. `Hosted.compare` hands its keys to `Js.apply` (the key's own
comparer, read with `Js.get`, and the two keys' values), which runs code nobody can describe. Measured with
the row in place, both operands of `compare` still escape and `Tea` keeps all 9 evidence refusals. A
trusted row on `Hosted.compare` itself (`borrowed Key, borrowed Key → Order`) clears the 4 `tableInsert`
and `tableRemove` refusals in the review's copy of the platforms. It rests on every `Key` being built by
`Hosted.key`, whose evidence is judged where it is handed (checked: a keeping `compare` is refused at
`Cmd.cancel`). That is a platform invariant, not a fact the checker sees, and its words (`borrowed`) are
v1's, so v1 would read a row it never saw. It is the owner's call. The 2 `tableFoldl` writes do not move
with it: their cause is the `twice` on the value location of `tableInsert`'s result.

### 10.2 `Dict.focus`: a true row, and why it is not committed

The row `aliased Dict k v, stored k, once taken stored (Maybe v → Maybe v) → Dict k v` is true of the code,
and the review could not break it. `alter` is handed the value at the key and nothing else, and `insertHelp`
(at `EQ`) or `removeHelpEQGT` (at `EQ`) drops it. Every `Node` pairs a key with its own node's value, so
each value is at one place. It needs `taken` beyond lists (every entry of a non-list parameter 0, `free`)
and a lowering rule that lets a `stored` callback stand beside an `aliased` first parameter. Built, it
accepts the callback's write (`bump d k = Dict.update d k …` on a parameter). Three facts stop it:

1. **v2 reads the same words.** A signature with a v2-only word is in one column for v2 and v3. v2's row
   reader knows `taken` only for a list, so it reads `Dict.focus`'s callback as unknown code: the gates'
   v1/v2 parity refuses `DictTupleFocus 10:5`, and `DictFocus` and `FoldAccumulators` reach v2's limit.
   The enum of words is full (`enum(u5)`), so there is no word for v3 alone.
2. **The write is not won.** In `FormValidation`, the callback's write is accepted and the fold is then
   refused: `275:13 value <call List.foldl>: rejected supply: the function can answer one cell at two
   places`. A dictionary's values are at two locations, the root's and the deep level's (kernel §4.1), and
   a rotation moves a value between them. So the callback's answer and each value are at both, and the
   answer the fold hands back can hold one cell at two of them. This is a coarseness of §4.1 for a tree
   that rebalances, and no row removes it.
3. **The `alternatives` rule's own argument does not cover it.** The review found that `alternatives` (§4.4)
   skips the duplicate test between a callback's answer and a `free` supply, also when the callback
   captured the dictionary and answers another of its values. What kept every probe sound is the
   arguments-apart rule and the caller's own atom test of a function parameter's answer. A row that marks
   a non-list supply `free` must name these in §4.4 first.

Kernel §6.10 now states the rule that refused it: a row is written only where v1 and v2 read its words as
before.

### 10.3 The holes

1. **A list literal with no element location held nothing** (fixed, `Frame.listOf`). A literal typed by a
   callee's type variable — `Js.call`'s argument list, `Js.object`'s fields — has a place with no element
   step, and its items went to no location. So a list handed to JavaScript inside one did not escape, and
   `Hosted.key` did not hold the key it was made from: a program could write a list in place while a
   command's key held it. Such a literal is now `unknown` over its items (kernel §3.2, §6.4). The review
   tried 20 constructions after the fix (tuples, records, nested literals, joins, spreads, closures,
   `Js.array`, `Js.construct`, record updates) and found none that drops a cell; base accepted 12 of them.
2. **`Js.lt`, `gt`, `le`, `ge` were `unused a, unused a`** (fixed, `core/Js.beni`). `<` runs an object
   operand's `valueOf`, which can keep it; the review proved a trap. The operands have no word now, and
   escape. These words are v1's, so v1 reads the change too: the one verdict that moves is `JsWords 56:12`,
   accepted before and refused now, in v1 and v2 alike. It is a soundness fix of the frozen checker, and no
   real write depends on it.
3. **The `alternatives` rule** (§10.2 item 3): not exploitable through any row committed today, which hand a
   `free` supply only of a list that the row also writes (`List.focus`, where a capture of the list is
   another operand of the write). Open.

### 10.4 The gate

ReleaseSafe compilers, `ca2fc63410` (before) and this work (after), on the same generated programs.

| Generator | Programs | SAME before → after | REFUSED before → after | TRAP / DIFF / CRASH |
|---|---:|---:|---:|---:|
| blind-faults | 24 | 11 → 11 | 13 → 13 | 0 |
| blind2-faults | 20 | 9 → 9 | 11 → 11 | 0 |
| blind3-faults | 10 | 3 → 3 | 7 → 7 | 0 |
| blind3 | 417 | 160 → 160 | 257 → 257 | 0 |
| blind2 | 1202 | 502 → 502 | 700 → 700 | 0 |
| evaluation-order | 440 | 288 → 288 | 152 → 152 | 0 |
| answers-beside | 240 | 77 → 77 | 163 → 163 | 0 |
| wider-functions | 354 | 144 → 144 | 210 → 210 | 0 |
| callbacks-keep | 720 | 108 → 108 | 612 → 612 | 0 |
| function-values | 1960 | 304 → 304 | 1656 → 1656 | 0 |
| handed-back | 2592 | 0 → 0 | 2592 → 2592 | 0 |
| aliased-arguments | 5160 | 1183 → 1183 | 3977 → 3977 | 0 |
| recursive-levels | 16131 | 4231 → 4231 | 11900 → 11900 | 0 |
| folds-callbacks | 30300 | 5392 → 5392 | 24908 → 24908 | 0 |

Every program has the same verdict and position before and after: the generators write no platform code,
and both fixes are about JavaScript. The sanitiser corpus is the same before and after (same 97, refused
250, 0 traps). Real writes: 279 of 308 before and after on `ca2fc63410`, and 292 before and after once rebased onto `c9b784cef3` (§9), every line the same; the sweeps on the rebased head match the table program for program. One fresh Opus reviewer was
given the diff, the code of `Js.get`, `Dict.focus` and `Hosted.compare`, and the two rows; its findings are
§10.1 (two traps of the proposed `Js.get` row), §10.3 item 2 (a trap of a committed row) and §10.2 item 3.

## Appendix A. Commands

All from the worktree root, `ZIG_GLOBAL_CACHE_DIR` as `flake.nix` sets it.

1. The compilers: `zig build -Doptimize=ReleaseSafe --prefix <dir>` for each of the two commits; `zig build
   test-perf "-Dtest-filter=generated module of §7.6"` installs the ReleaseFast compiler at `zig-out/perf/bin/beni`.
2. The sweeps: for each generator, `node bench/ownership-sweeps/<generator>.mjs <out>/<generator>`, then
   `node bench/ownership-sweeps/run.mjs --beni=<beni> --checker=v3 --tag=<tag> --jobs=10 --tmp=<disk> <out>/<generator>`;
   the three fault folders are run the same way.
3. The sanitiser corpus: `node bench/ownership-step0-sanitiser.mjs --beni=<beni> --jobs=6`.
4. Real writes and speed: `node bench/ownership-v2-review.mjs --beni=<beni> --checkers=v1,v3 --roots=real --runs=1`
   (verdicts, any compiler) and `--checkers=v1,v2,v3 --runs=3 --jobs=1` with the ReleaseFast compiler (speed).
5. The markup cost: the same real-writes run twice, the second with `evalInner .markup` answering
   `unknownOf(place, &.{})` in place of `unknownOf(place, held.items)`, a one-line local edit that was not committed.
