# 165 — Cells and fibers under v3: the plan and the oracle

*Research report, 2026-11-20. Lists, records and dictionaries are written in place under the ownership
checker v3 (`ownership-v3-kernel.md`; owner decisions of 2026-10-15 and 2026-11-15, research reports 142
and 160). Kernel §0 says that cells and fibers are later stages of the same rules (report 116 §5.4). This
report starts that stage by report 142's method: the plan, then the oracle, then the rules and the
checker. It lands the plan, the oracle's proof and a sweep family. The rules and the checker are the
slices of §9, which the next lane takes. #2521, #981.*

---

## 1. Result

- **What v3 does today** (§2): a `Ref`'s layout stops at its handle, so the contents have no location.
  What goes into a cell escapes, `Ref.get` answers `outside`, and a `Ref.update` function that writes its
  parameter is refused (`supply`). Every program of the new sweep that writes a cell's contents in
  place is refused, live and dead alike: 720 of 720.
- **The oracle needs no new code** (§7). `--sanitize-lists` and `--lists-in-place` route a write inside
  a `Ref.update` or `Ref.modify` function as they route any accepted write, and the old array, record or
  dictionary that a stale holder reads is the one the write poisoned or changed. A mutant v3 that
  accepts every supply let 288 live programs through: each is TRAP under the sanitiser and DIFF in place,
  72 of them a read **in another fiber, after a park**, of a value the first fiber took before the other
  wrote. No live program was SAME. The dead twins it accepts are SAME in all four legs.
- **The plan** (§3–§6, §8): a cell's contents are a location below its handle; `make`, `get`, `set`,
  `update` and `modify` read, answer and **renew** that location; a handle that gets another holder
  makes its contents escape; a park needs no rule while a cell's handle is held by one frame, and the
  owner's loan rule (#981) is the rule for a cell that two fibers hold.
- **The sweep** `cells.mjs` (new, 720 programs): contents (a list, a record, a dictionary) × who makes
  the cell × five writers × four readers × three holders of a loan × four fiber shapes, with live and
  dead twins.
- **No owner decision is open.** #981's decision (a `Ref` owns its contents; `Ref.get` answers a loan
  that may not be read after a suspension point or escape; the fix is `List.copy`) is the rule of §6,
  and every other choice here is technical.
- **No verdict changed**: this lane changes no code of the compiler. The v3 dumps of the 2 475
  ownership roots and the real-writes ledger (309 of 319) were taken on the base for the next lane's
  diff (§10).

## 2. What v3 does with `Ref` and fibers today

`core/Ref.beni` is `opaque cell type Ref a = Ref Js.Value` with worded bodies over `Js`:

| Row | Words | v3's contract today |
|---|---|---|
| `make` | `consumed a → cellnew Ref a` | `π1 E; res [fresh0]`: the value escapes into the cell |
| `get` | `cellread Ref a → lent a` | `π1; res [outside π1@0]`: the pessimistic row |
| `set` | `cellwrite Ref a, consumed cellstored a → ⊤` | `π1, π2 E`: the value escapes |
| `update` | `cellwrite Ref a, cellupdate stored sync (a → a) → ⊤` | the function is handed the handle and itself, not `free`; its answer escapes |
| `modify` | `cellwrite Ref a, cellmodify stored sync (a → b × a) → b` | the same, and the result is the answer |

The reason is in `Loc.zig` (`visit`, `visitEntry`, `deepMember`): a place of kind `ref` gets one location
of kind `cell`, and nothing below it ("what a cell holds is never `own`"). The place graph has the step
already (`own2/Groups.zig`: a `cell` type has one `contents` step, `◆` in a dump); v3 does not descend
into it. The three `cell` types are `Ref`, `Deferred` and `Task.Fiber`. `Queue` is no cell type: it is an
opaque type whose walked bodies keep values in JavaScript, so what is offered escapes (unknown code).
`Log`'s operations take strings and callbacks.

v3 has no notion of a suspension point. It needs none today: a value another fiber can read is one that
escaped (a spawned closure is `escaped`, `Task.spawn : escaped (⊤ → a) → cellempty Fiber a`, and rule 3's
`heldLeaves` lets every capture location its contract reaches escape), and a cell's contents are
`outside`. The blind rounds found no fault across fibers for that reason, and every fiber shape that
involves a cell was refused.

Measured (`cells.mjs` on the base, `--mode=both`): 720 refused, 432 `supply` (the `update`, `modify` and
helper writers), 288 `unknown` (a write of what `Ref.get` answered, `outside`). The eleven `run/`
programs of #2521 are refused today (1 to 8 refusals each); under the mutant of §7, eight of them print
their golden under the sanitiser (`CellStoresApart`, `CellWordsReadOnly`, `LoanStoredLocal`,
`SanitiserCellEdit`, `SanitiserCellStoredFresh`, `SanitiserCellReentryApart`,
`SanitiserCellLoanKeptApart`, `SanitiserNestedCallbackWrite`), and three keep refusals of a write of
`Ref.get`'s answer (`RefModifyIndependent`, `RefTakeOwned`, `SanitiserLoanPerCell`).

## 3. What a cell is to v3

A cell is a location whose contents every holder of its **handle** can read, at any later time, from any
fiber. Two facts follow:

1. **The contents are a location of the handle.** `Ref (List Int)` has the layout `[r, r◆]`: the handle
   (kind `cell`, a JavaScript array of one slot) and the contents' own layout below the step `◆`. A
   contract then names `π1◆` as it names `π1[*]`: a row can read it, answer it, hand it to a function and
   say what it holds after the call.
2. **A write of the cell is no write in place.** `Ref.set` changes what every holder of the handle reads;
   the copying program does the same. So a store is never a demand. What is judged is a write in place
   of a value **inside** the cell (a list, a record, a dictionary): its old value is held by the cell and
   by every value that `Ref.get` answered before.

The handle itself is one object that all its names share. So what the frame knows of the contents holds
only while it knows every name of the handle (§5).

## 4. Which operation reads and writes which location

| Operation | Reads | Writes in place | Answers | The contents after |
|---|---|---|---|---|
| `Ref.make v` | `π1` | — | a new handle, `◆` holding `π1` | `π1` |
| `Ref.get r` | `π1◆` | — | `π1◆` (a loan) | unchanged |
| `Ref.set r v` | `π1`, `π2` | — | — | `π2` (a store, no demand) |
| `Ref.update r f` | `π1◆` | what `f` writes of `π1◆`, handed `free` | — | `f`'s answer |
| `Ref.modify r f` | `π1◆` | the same | `f`'s answer `.0` | `f`'s answer `.1` |
| `Deferred.make`, `Task.spawn` | — | — | a new handle, `◆` holding `outside` | `outside` |
| `Deferred.wait`, `Task.join` | `π1◆` | — | `π1◆`, which is `outside` | unchanged |
| `Deferred.complete d v` | `π1`, `π2` | — | — | `π2` escapes, as today |
| `Deferred.poll` | as today: the pessimistic row | | | |
| `Queue.offer`, `take`, … | walked bodies over `Js`: the value escapes, the answer is unknown code's, as today | | | |
| `Log.*` | strings; callbacks as any function parameter | | | |

The new fact is the last column. A contract today says what its result holds; nothing says what a
parameter's location holds **after** the call. A cell needs it: `set`, `update` and `modify` answer `⊤`
(or `b`), and the new contents are in the handle the caller holds. So a contract gets, per parameter
location of kind `cell` contents, an optional list of sources: the **renewal** (`Contract.renew`). A
location with no renewal keeps its contents; one with a renewal holds those sources from the call on.
The rows say it by the words they have (`cellstored` → `π2`, `cellupdate` → the answer, `cellmodify` →
the answer's `.1`); no new word is needed, and v1 and v2 read the words as before (rule 10). `cellnew`
and `cellempty` stop naming a new cell at every location: the handle is new, and the contents are `π1`
or `outside` (safe builds would stop at `Ref.make` otherwise: `Check.core_phantoms` panics as soon as the
layout descends, measured in this lane).

`Deferred` and `Fiber` keep today's meaning in this stage: their contents are `outside` at every reading,
so nothing they hold is written in place. They descend all the same (one layout rule for every `cell`
place), which costs locations and changes no verdict.

## 5. When a value taken out of a cell can be written in place

#981's shape: `r = Ref.make [ 1, 2 ]`, `Ref.update r λxs → List.push xs 5`, `List.length (Ref.get r)`.

- **The hand-off.** `update` hands its function `π1◆` `free` (as `taken` hands a loop's element), so
  the function's write of its parameter is a demand at the `update` call on the caller's atoms at `r◆`:
  the four tests of §5 against every holder the frame knows of the old contents.
- **The renewal is a new name** (§5.1). After the call the handle's contents are the function's answer
  (here the push's version of the old array) under names that are old from the call on (`Atom.dead`).
  The frame gives the handle root a new **version root** whose `◆` entries hold those atoms, and a later
  use of the handle as an argument reads the version (`apply` maps each argument that is a part of a
  renewed root to its latest version). A `Ref.get` after the update answers the new name, which reads
  nothing the update wrote; a loan answered before it holds the old names, and a read of it after is
  test 4's later read.
- **Loans are snapshots.** `Ref.get`'s answer is a call's result: a root whose runs are the atoms of
  `r◆` at the time of the call. A version root is immutable once made. So no read is ever evaluated
  against a later state of the cell (a read is recorded as a value and judged at the end of the walk:
  an override of the handle's own entries would read the last state, and with two updates a loan read
  between them would read as a new name; a version root keeps each state apart).
- **A parameter's handle.** `bump r = Ref.update r λxs → List.push xs 1`: the demand is on `π1◆`, which
  the contract publishes as written (`flag_w`) and renewed (to the old names under a new name, for the
  caller). The caller judges the write against its own holders, then reads `r` through a version root.
- **A store** into a handle the frame tracks is the renewal with the stored value's atoms: `Ref.set r v`
  then a write of `v` in place with `Ref.get r` read after is test 4; a write of `v` with nothing read
  after is accepted.

**A handle with another holder.** The frame knows the contents only while every name of the handle is a
name it follows: the root itself, its parts through constructions and patterns, and direct arguments
whose contract says what the call does to `π◆`. Each of these is another holder, and makes the handle
**shared** from that time on:

- a closure that captures the handle (it can run at a time the frame does not see, and store into it);
- an escape of the handle (unknown code, a kept closure, `Task.spawn`, a top-level value);
- a callee that answers or keeps the handle (`flag_a` or `flag_e` at `π@r`): the caller's result root
  holds a copy of the handle's atoms, and a store through one name is a store the other does not see.

When a handle becomes shared, its current contents escape, the handle's version holds `outside` at `◆`
from then on, and a store into a shared handle lets the stored value escape. Each half is needed, and
each was found unsound without it while this plan was written:

- with `outside` alone, a loan taken before the sharing (`old = Ref.get r; t = keep r; …`) is written in
  place while a get through the other name reads the same array as `outside`, which overlaps nothing;
- with a copy of the contents in the other name's root, a `Ref.set` through the first name leaves the
  second reading the old contents, and a write of what it gets writes the new value under the old
  value's atoms.

A top-level `Ref` is a handle every reader holds: its contents are `outside`, as today, and the fix of a
refused write is `List.copy`.

## 6. Fibers and parks

Only one fiber runs at a time, and the runtime switches fibers only where one may suspend
(`Js.suspending`, reached through `Io.sleep`, `Task.join`, `Task.yieldNow`, `Deferred.wait`, …). So a
write in place before a park can be observed by another fiber only through a holder that fiber has: a
value it captured, or a handle it can read.

**While a handle is held by one frame** (§5), no other fiber has it, so a park changes nothing: another
fiber can hold the old contents only if it was handed them, which is an escape. `Task.spawn λ⊤ → … r …`
shares the handle (the closure captures it, and it escapes), so the contents escape there, and the
spawner's later in-place writes of them are refused by test 3. This is the first slice's fiber rule; it
needs no rule of its own, and the sweep's `park` and `writer` shapes are its tests.

**A cell two fibers hold** is #981's case: a log or a queue collected by several fibers through one
`Ref`, `Ref.update log λl → List.push l x` in each. It is safe exactly when no fiber holds a loan of the
contents at a point where another can run. The owner's decision is that rule: "A loan may be read and
used to build new values. It may not stay alive across a suspension point or escape … `Ref.update` /
`Ref.modify` edit in place when no loan of the cell is alive." In v3's terms, for a cell whose handle is
held by spawned closures **only as a handle** (each closure's contract reaches `π◆` only through the
cell's own rows), an in-place write of the contents through `update` is accepted when, in every frame
that can run it:

1. no loan of the cell is alive at the write (test 4 in the writer's frame and its callers', as above);
2. no loan of the cell is read after a call that may suspend (the effects checker's bit,
   `src/check/Effects.zig`, `checker-v2.md` §26; report 116 §5.4: "a row on the suspending primitives, by
   form 5 a word, not a name"), and none escapes.

The second is a property of every frame that holds the handle, not of the writer's, so it is a fact the
handle carries: a frame that reads a loan after a park, or lets one escape, marks the cell's contents
**fiber-visible**, and a function that writes the contents of a fiber-visible cell in place is refused
where it is handed to the cell. A contract publishes the mark at `π◆` as it publishes an escape. That
slice is the fourth of §9; until it lands, a cell two fibers hold is shared, and its contents are not
written in place (refused, with the copy fix).

## 7. The oracle

Report 142 §2 and report 160 §4 built the in-place lowering for records and dictionaries. A cell needs
none: the write in place is the write of a list, a record or a dictionary inside the function `update`
is handed (or of what `get` answered), and the lowering routes it by its site as it routes any accepted
write. `Ref.update`'s body (`set ref (f (get ref))`) stores what the function answers: under the
sanitiser a copy, and the old object poisoned; in place the same object, changed. A loan or a stored
value read after is the poisoned object (TRAP) or the changed one (DIFF), in whatever fiber reads it.

**The mutant.** `Frame.ownSupply` returning at once (every function that writes what it is handed is
accepted where it is handed), built in the lane and not committed. On `cells.mjs`, `--mode=both`:

| Twin | SAME | REFUSED | TRAP (and `ip=DIFF`) |
|---|---:|---:|---:|
| live (504) | 0 | 216 | 288 |
| dead (216) | 144 | 72 | 0 |

The 288 TRAPs are 96 lists, 96 records and 96 dictionaries; 72 in each fiber shape, `park` among them:
fiber A takes `old = Ref.get r`, sleeps, and reads `old`, while fiber B sleeps less and writes through
`Ref.update`. Each TRAP is also DIFF in place. The refusals left are writes of what `Ref.get` answered,
which is `outside` today. The base refuses all 720.

## 8. The kernel rules (for the next lane: kernel §13, *Cells*)

The text the checker slice adds, as one new section (no section renumbered):

1. **Contents.** A place of kind `ref` has a location of kind `cell` (its handle) and, below the step
   `◆`, the layout of its contents (`Loc.visit`). Its contents are no summary.
2. **Rows.** `cellnew`: the handle is a new cell, the contents are parameter 0's locations, which do not
   escape. `cellempty`: the handle is new, the contents are `outside`. `cellread … → lent`: the result is
   `π1◆`. `cellstored` beside `cellwrite`: the renewal of `π1◆` is the parameter. `cellupdate`: the
   function is handed `π1◆` `free`, and the renewal is its answer. `cellmodify`: the same, the renewal
   its answer's second part and the result its first. `cellcomplete` and `lentoptional`: as before.
3. **Renewal** (`Contract.renew`, per parameter location under a `cell`): from the call on, the
   argument's contents are those sources, under names that are old from the call (§5.1). The caller
   makes a version root of the handle; a later argument that is a part of the handle's root is read as
   its latest version. A walked body publishes, for each parameter handle it renewed, the sources of its
   latest version.
4. **Shared handles.** A handle root becomes shared where a closure captures it, where it escapes, and
   where a callee answers or keeps it. From then on its version holds `outside` at `◆`, its contents at
   that time escape, and a store into it lets the stored value escape. A capture's or a top-level
   handle is shared from the start.
5. **Stores are not demands.** A store renews; only a write in place of a value inside the cell is a
   demand, judged by §5.
6. **Fibers** (§6): a park needs no rule while a handle is not shared; a shared handle's contents are
   not written in place until rule 7 (the loan rule) lands.

## 9. The slices

| Slice | What | State |
|---|---|---|
| 0 | the plan, the oracle's proof (a mutant), `cells.mjs`, the base's dumps and ledger | landed (this report) |
| 1 | `Loc` descends into `◆`; the rows of §8 item 2; `Contract.renew` (walk, publish, import, `join`, `eql`, the dump, `falseWord`'s *below*); version roots in `apply`; kernel §13 | open |
| 2 | shared handles (§8 item 4): the three ways a handle gets another holder, the contents' escape, stores into a shared handle | open, with slice 1: slice 1 alone is unsound for any program whose handle has a second holder |
| 3 | `run/` twins for #2521's eleven programs and #981's shape, live twins refused; the copying fixtures of #981 without their copies | open |
| 4 | the loan rule for cells two fibers hold (§6), on the effects checker's may-suspend bit | open |
| 5 | `Deferred` and `Fiber` contents (`Task.join`'s answer, a completed value), if a real program needs them | open |

Slices 1 and 2 land together. The hooks, from this lane's reading: `Loc.visit`/`visitEntry`/`deepMember`
(the three `if (k != .list) return`), `Check.wordedContract` (`into_cell`, `pessimisticRow`'s `cellread`,
the `cellnew`/`cellempty` sites), `Check.wordedFn` (`free` and the supply for `cellupdate`/`cellmodify`),
`Contract.Contract` (a `renew` table beside `res`), `Contract.publish`, `Frame.apply` (argument versions,
renewals after the demands), `Frame.expandSrcs` (a renewal's sources, as a result's), `Frame.closureOf`
and `Frame.noteEscape` (sharing), `Frame.finish` (a parameter handle's renewal), `Check.falseWord`.
Every acceptance must keep the theorem of §5: a renewed handle read through a name the frame does not
follow is the hole §5 names twice.

## 10. Evidence for the next lane's diff

On the base (`5b981be777`, ReleaseSafe self-hosted):

- `bench/ownership-v3-dumps.mjs` (new): `beni dump --stage=ownership --ownership=v3
  --ownership-everywhere` of the 2 475 roots of `bench/ownership-roots.mjs`, one file per root. Ten
  dumps exit 1 on the base: `run/core/TopLevelJsRefSuspendingCallback`, the `browser/` directories
  `dedicated`, `gpu`, `managed` and `prerender`, `check/good/dedicated`, and `emit/`'s and
  `emit/release/`'s `dedicated` and `prerender`. The next lane makes the same directory on this commit
  and on its own, and compares them file by file;
- the ledger, `bench/ownership-v2-review.mjs --checkers=v1,v3 --roots=real`: 319 list writes v1 judges,
  v3 accepts **309**, refuses 10;
- `cells.mjs` on the base: 720 refused; on the mutant: §7's table.

## 11. Reproduce

```sh
zig build beni-fmt-check   # zig-out/safe/bin/beni; this report changes no compiler code, so any commit from 5b981be777 to it
TMPDIR=<disk> node bench/ownership-v3-dumps.mjs zig-out/safe/bin/beni <dir>/before 16
node bench/ownership-sweeps/cells.mjs <dir>/cells
node bench/ownership-sweeps/run.mjs --beni=zig-out/safe/bin/beni --checker=v3 --mode=both --jobs=16 --tmp=<disk> <dir>/cells
TMPDIR=<disk> node bench/ownership-v2-review.mjs --beni=zig-out/safe/bin/beni --checkers=v1,v3 --runs=1 --roots=real
```

The mutant: in `src/own3/Frame.zig`, `fn ownSupply`, return after its first line; build, run the sweep
with `--tag=mutant`, and restore.
