# 147 — Ownership v3: a record alias's constructor, and a step a value does not have

*Research report, 2026-11-16. A blind round found three soundness faults in the checker v3
(`--ownership=v3`, `src/own3/`) with one shape: a record built by its alias's constructor, `a = P n [ 1 ]`,
was updated in place while the program still read `a.k`; a pattern by that constructor bound nothing;
and a tuple read as a record through `Js.to` gave `p.a` no cell. This report finds the cause, fixes it at
the root, lists every place the same mistake was found, and measures the change. The kernel is
`ownership-v3-kernel.md`; this report revises its §3.4, §6 rules 4 to 6, §9 and §11.*

---

## 1. Result

- **The cause** (§2) has two halves. A record alias's constructor was read as a constructor of a
  custom type, not as the record literal it stands for: its application built a construction of the
  fields with no object (kernel §11.2), its pattern projected by a constructor's step that a record does
  not have, and as a function value its answer's slots had no source. And a construction projected at a
  step was answered `none` whenever no part was at that step, which kernel §3.4 says only of a step the
  value's own place has: a step it does not have is no claim, `unknown`.
- **The fix** (§3): the constructor makes the literal's value (`recordOf`); its pattern is a record
  pattern that reads the slots it binds; its function value answers new slots. A construction at a step
  its place does not have is `unknown` (`builtAbsent`). A record's slot that the value it is read from has
  no slot for — a tuple, a constructor or a value of no cell read as a record — holds `outside` wherever a
  reading meets it (`rootSlotLost`, a slot write of no cell, `punned`, `slotHeld`).
- **Same mistake, found** (§4): eight places, two of them by the review: the constructor's application,
  its pattern, its function value; `project` of a construction; the callee's view of an argument's root
  slot and of a slot below a type variable; the update of a value whose type does not name the slot; and
  a cast between two shapes of one object, by an identity or by a contract (the review found the second
  and a constructor read as another type's constructor). **Twelve `run/` fixtures** fail before the fix
  and pass after.
- **Verdicts** (§5): of the 2 756 ownership roots, **none changes a verdict**; two change the cause of a
  refusal. The new fixtures are refused. **Real-writes ledger: 294 of 308 before and after**, line for
  line; every v3 demand of the 32 real roots has the same verdict.
- **Sweeps** (§6): every generator, every fault folder, the corpus, the blind round's programs and fault
  folders, and the review's programs under the four legs: **0 faults**. A new generator,
  `alias-ctors.mjs` (188 programs), finds 81 faults on the base and none on the fix.
- **Speed** (§7): v3 on the 32 real roots +1.3 % (ReleaseFast, the least of three alternated rounds), +2.2 %
  without `platforms/browser`; the largest root, `examples/conduit`, +4.3 ms.
- **Review** (§8): one fresh adversarial reader wrote 478 programs and found two casts the first version
  left open; both are fixed, with fixtures, a kernel rule each, and a narrower residual (#2540).

## 2. The faults and their cause

The blind round's programs (`blindR/faults/`, now `run/RecordAliasCtorUpdate`,
`run/RecordAliasCtorCasePattern`, `run/RecordAliasCtorParamPattern`, `run/RecordPunTuple`):

```text
type alias P =
    k : Int
    u : List Int

a = P n [ 1 ]
a2 = { a | k = 5 }                 -- accepted fresh
"${a2.k} ${a.k}"                   -- plain 5 0; in place 5 5

case { p = xs, q = xs } of
    P u v → List.push u 9 …        -- u bound to nothing: accepted fresh

kOf (KQ k _) = k                   -- the contract reads no slot of the parameter

p : { a : List Int, b : List Int }
p = Pun.conv ( xs, xs )            -- Js.to (Js.from v)
List.push p.a 9                    -- `.a` of a tuple's construction: none
```

**A record alias's constructor.** `backend.md` §4 builds a record for it: `P n [ 1 ]` is `{k: n, u: [1]}`.
v3 read it as a constructor of a custom type (`Frame.call`'s constructor branch: `built` over the
arguments at the steps `ctorArgStep` names). For a record place `ctorArgStep` gave the field steps, so
the parts were right, but the construction had **no object**: kernel §11.2 makes a record literal a
construction of its fields *and* a root whose slots are the frame's own cells (`recordOf`). With no
object, `a.k` read no slot (`readSlots` of a construction with no object reads nothing), and
`{ a | k = 5 }` wrote the slot atoms of nothing: a demand with no atoms, which is accepted. A pattern by
the constructor (`bindPattern`, `.pat_ctor`) projected by `ctorStep(ordinal, k)`, a constructor's step,
on a record's value, which has field steps only: the projection of a construction answered `none` and of
a root `unknown`, and neither read a slot (`readSlots` was called by record patterns only). As a function
value (`ctorValue`), the constructor's contract put each argument at its field and gave the slots of its
answer no source.

**A step a value does not have.** `project` answered a construction's missing part with `none`: "a
construction names every part that holds a cell". That holds for a step of the construction's own place:
another constructor's argument, a field whose value holds no object. It does not hold for a step the place
does not have, which kernel §3.4 names: the value read at another type, of which its own layout says
nothing. A tuple and a record of fields `a`, `b` are one JavaScript object; `Js.to (Js.from ( xs, xs ))`
read as a record is the tuple's construction, and `.a` on it is a step the tuple's place does not have.

## 3. The fix

**The constructor is the literal** (kernel §6 rule 4, §11.2). `call` makes the record with `recordOf` when
the constructor's answer is a record; `ctorValue` gives each slot of a record answer a fresh site of its
own; `makesObject` says the application makes an object. A pattern by a record alias's constructor
(`Mod.isRecordAliasCtor`, `Mod.recordAliasStep`) is a record pattern: argument `k` is the field the alias
writes `k`-th, its slot is read where the pattern matches (§11.4), and the field's value is the part at
the field's step. It applies wherever `bindPattern` runs: `case`, `let`, `as`, a parameter, a lambda.

**A missing step is no claim** (kernel §6 rule 5, §3.4). `project` of a construction at a step its own
place does not have is `unknown` over the construction (`builtAbsent`); at a step the place has and no
part is at, `none` as before.

**A record's slot that the value has no slot for** (kernel §3.4). A tuple's or a constructor's object is no
cell: no write in place reaches one. Read as a record, its slots are a cell no atom names, and every other
holder reads it by parts that hold no location for it. So:

1. a reading of a slot of the record at a value's root, where the value's own place is no record that
   names the field and no wide place, holds `outside` (`rootSlotLost`): in `leavesSet` (each part of a
   construction and each arm of a join is read at its own place, so deeper slots are asked of the part
   that holds them) and in `argEntries` (a callee's slot of its parameter's root);
2. the update of a value whose type does not name the slot writes `outside` too (`slotAtoms`);
3. a slot write whose atoms are none writes `outside`: a record always holds its object, so a slot of no
   cell is of no record (`recordUpdate`, `applyAt`; a tuple of numbers read as a record is `v_none`);
4. a cast between two shapes of one object: an identity whose reading has a slot or a constructor's
   argument that no location of the argument's own layout covers answers `unknown` (`punned`); a
   contract that pairs a wide location of a parameter with an answer location a slot is at or below, or
   a wide location with a concrete one, holds the caller's slot only where the argument has a slot at
   the same label path, or a wide entry above (`slotHeld`, from `argEntries` and `castSlotLost`).

**The safe-build check** (kernel §9): a construction at a record's place holds the record's object
(`Frame.built`). With the constructor's branch put back to `built`, the first fixture panics:
`own3: a record construction at place … has no object, and its slot … holds no cell`. The check counts no
work.

## 4. Every place the same mistake was found

| Where | Mistake | Fixed by | Fixture |
|---|---|---|---|
| a record alias's constructor applied (`call`) | a construction of the fields, no object | `recordOf` | `run/RecordAliasCtorUpdate` |
| its pattern (`bindPattern`) | a constructor's step on a record: bound nothing, read no slot | field steps, `readSlots` | `run/RecordAliasCtorCasePattern`, `run/RecordAliasCtorParamPattern` |
| its function value (`ctorValue`) | the answer's slots had no source | a fresh site each | `run/RecordAliasCtorPartial` |
| `project` of a construction | a step the place does not have answered `none` | `builtAbsent` | `run/RecordPunTuple` |
| the callee's view of an argument (`argEntries`, `applyAt`) | a slot of a value that is no record wrote its other cells, or nothing | `rootSlotLost`, a slot write of no cell | `run/RecordPunHelper`, `run/RecordPunConstructor` |
| a slot below a type variable of a callee's answer (`pairedLeaves`, `argEntries`) | the slot held the argument's list, not the object | `slotHeld` | `run/RecordPunAnswer`, `run/RecordPunDeep`, `run/RecordPunBeside` |
| a cast by an identity (`applyAt`) | a constructor read as another type's: one step by position, `none` | `punned` | `run/RecordPunOrdinal` (review) |
| a cast in a callee's body (`pairedLeaves`) | a parameter of a type variable answered as a record | `castSlotLost` | `run/RecordPunGenericCast` (review) |

The other readers of a value were audited: `leavesOwnWalk` reads each part of a construction at its own
place (`leavesSet`), so a part's root is asked where it is; a `join` reads each arm at the join's place,
the same; `expandSrcs`, `holeFlags` and `readBy` read through the call map and its wide entries (§3.4,
report 146); the parts of a pattern of a tuple, a list, a record and `?` project by steps that the
scrutinee's type has. `project` of a root (`pathExtend`) and of `unknown` were `unknown` already.

**The constructor's other uses.** The literal classification of the budget (`Check.zig`, a constructor
applied to literals is a literal, kernel §8) is unchanged: a record literal of literals is one too, and
its walk is the same `recordOf`. The entry rule (§6.13) reads a constructor in a field of the record as a
function of no object only where its answer holds no cell, which a record alias's never is.

**What stays open** (#2540): inside a cycle's deep level the call map pairs one place under two label
paths, so `slotHeld` holds a slot there by any slot of the same field. A cast of a value whose type has a
cycle, read where the value's own record of that field is another object, would not be refused. No
program of the shape exists yet. Only code over `Js` can cast, and no platform in scope does.

## 5. Verdicts

`dump --stage=ownership --ownership=v3 --ownership-everywhere` of every ownership root
(`bench/ownership-roots.mjs` with every ownership fixture), base `d42449d9dc` against the fix: 2 756 roots
on the base, 2 768 on the fix (the 12 new fixtures). **No root's verdict lines change** but two causes:

| Root | Line | Base | Fix |
|---|---|---|---|
| `run/HostValueElements` | 22:17 `update v` | rejected `later-use` | rejected `unknown` |
| `run/SchemaDepth` | 132:12 `call Main.issues` | rejected `element` | rejected `unknown` |

Contracts change in 26 roots: new fresh sites (the constructor's object and slots, numbered after the
others), `run/SanitiserRecordCtor`'s `first` (a constructor pattern now reads one slot, not the whole
parameter), and `outside` at the slots of `Schema`'s and `Json`'s issue records in the answers of
Conduit and the todo page (six each) and `browser-tea/RaceTwoServices`: those records come through a
cast in core's engine, and no verdict reads them.

**The new fixtures** are refused, each at the line its `.sanitize-lists-v3-refuses` names. The blind
round's three fault folders and its 442 programs (`blindR/progs`, g1 to g10): every one of its 26 `TRAP`s
(one of them a dead twin that trapped under the sanitiser alone) is `REFUSED`; 3 dead twins move from `REFUSED` to
`SAME`, each a constructor pattern now bound as the record pattern it is (`ac.patparam`, `ac2.lambdapat`,
`ac2.otherpat`): the same verdict their literal twins have. 2 dead twins of the tuple pun move from `SAME`
to `REFUSED` (a cast read at another type is no claim).

**v1 and v2.** The corpus compares v2's verdicts with v1's on every `run/` program. v1 accepts the push of
`run/RecordAliasCtorCasePattern` (it binds the pattern's `u` apart from the field `q` that holds the same
list); v2 refuses it, as v3 does. v1 is frozen, so the difference is one line of
`tests/blackbox/ownership-v2-known.txt`.

**The real-writes ledger** (`bench/ownership-v2-review.mjs --checkers=v1,v3 --roots=real`, as report
146): of the 308 list writes v1 judges, v3 accepts **294** and refuses 11 (3 with no line) before and
after, line for line, and every v3 demand of the 32 real roots has the same verdict. **No real program is
newly refused.** Real programs build records with an alias's constructor (`examples/sternhalma`'s
`Player id (playerColor id)`, `bench/corpus`'s `SignUp user mail …` in `FormValidation`): their contracts now
give those records' slots fresh sites, and every verdict of those roots is the same.

## 6. Sweeps

`bench/ownership-sweeps/run.mjs --checker=v3 --mode=both --jobs=24`, the self-hosted ReleaseSafe compiler of
the fix, every program of the 27 generators of the folder (the new `alias-ctors` and the corpus included),
its 13 fault folders, the blind round's programs and fault folders (`blindR-*`) and this report's own
probes: 87 067 programs.

| Sweep | Programs | SAME | REFUSED | LIMIT | Faults | Other |
|---|---:|---:|---:|---:|---:|---|
| `alias-ctors` | 188 | 79 | 109 | 0 | 0 | — |
| `aliased-arguments` | 5160 | 1216 | 3944 | 0 | 0 | — |
| `answers-beside` | 240 | 79 | 161 | 0 | 0 | — |
| `answers-sends` | 54 | 19 | 35 | 0 | 0 | — |
| `blind10i` | 474 | 151 | 209 | 0 | 0 | 114 PLAINFAIL |
| `blind10i-faults` | 16 | 7 | 9 | 0 | 0 | — |
| `blind2` | 1202 | 502 | 700 | 0 | 0 | — |
| `blind2-faults` | 20 | 7 | 13 | 0 | 0 | — |
| `blind3` | 417 | 160 | 257 | 0 | 0 | — |
| `blind3-faults` | 10 | 3 | 7 | 0 | 0 | — |
| `blind4a` | 160 | 24 | 136 | 0 | 0 | — |
| `blind4a-faults` | 12 | 1 | 11 | 0 | 0 | — |
| `blind4b` | 6596 | 1188 | 5406 | 2 | 0 | — |
| `blind4b-faults` | 8 | 4 | 3 | 1 | 0 | — |
| `blind5c` | 226 | 79 | 145 | 2 | 0 | — |
| `blind5c-faults` | 10 | 5 | 5 | 0 | 0 | — |
| `blind5d` | 1234 | 450 | 784 | 0 | 0 | — |
| `blind5d-faults` | 10 | 5 | 5 | 0 | 0 | — |
| `blind6e` | 238 | 91 | 140 | 0 | 0 | 7 PLAINFAIL |
| `blind6e-faults` | 12 | 4 | 8 | 0 | 0 | — |
| `blind7f` | 960 | 396 | 564 | 0 | 0 | — |
| `blind7f-faults` | 2 | 0 | 0 | 0 | 0 | 2 TIMEOUT |
| `blind8g` | 121 | 21 | 99 | 1 | 0 | — |
| `blind8g-faults` | 8 | 4 | 3 | 1 | 0 | — |
| `blind` | 9792 | 1675 | 8117 | 0 | 0 | — |
| `blind9h` | 3213 | 849 | 2364 | 0 | 0 | — |
| `blind-faults` | 24 | 11 | 13 | 0 | 0 | — |
| `blindR-faults-alias-ctor-pattern` | 4 | 2 | 2 | 0 | 0 | — |
| `blindR-faults-alias-ctor-update` | 2 | 1 | 1 | 0 | 0 | — |
| `blindR-faults-tuple-read-as-record` | 3 | 0 | 2 | 0 | 0 | 1 PLAINFAIL |
| `blindR-g10` | 28 | 9 | 19 | 0 | 0 | — |
| `blindR-g1` | 48 | 10 | 38 | 0 | 0 | — |
| `blindR-g2` | 90 | 2 | 88 | 0 | 0 | — |
| `blindR-g3` | 58 | 24 | 34 | 0 | 0 | — |
| `blindR-g4` | 56 | 27 | 29 | 0 | 0 | — |
| `blindR-g5` | 32 | 16 | 16 | 0 | 0 | — |
| `blindR-g6` | 40 | 19 | 19 | 0 | 0 | 2 PLAINFAIL |
| `blindR-g7` | 32 | 13 | 19 | 0 | 0 | — |
| `blindR-g8` | 22 | 10 | 12 | 0 | 0 | — |
| `blindR-g9` | 32 | 14 | 18 | 0 | 0 | — |
| `bounded-walk` | 34 | 5 | 7 | 4 | 0 | 18 TIMEOUT |
| `bounded-walk-faults` | 12 | 2 | 4 | 2 | 0 | 4 TIMEOUT |
| `callbacks-keep` | 720 | 108 | 612 | 0 | 0 | — |
| `corpus` | 1684 | 1192 | 472 | 1 | 3 | 12 BOTHFAIL 3 PLAINFAIL 1 TIMEOUT |
| `evaluation-order` | 440 | 276 | 164 | 0 | 0 | — |
| `fix147-probes` | 21 | 5 | 16 | 0 | 0 | — |
| `folds-callbacks` | 30300 | 5152 | 25148 | 0 | 0 | — |
| `function-values` | 1960 | 304 | 1656 | 0 | 0 | — |
| `handed-back` | 2592 | 0 | 2592 | 0 | 0 | — |
| `host-values` | 81 | 13 | 68 | 0 | 0 | — |
| `records` | 1876 | 353 | 1523 | 0 | 0 | — |
| `recursive-levels` | 16131 | 4034 | 12097 | 0 | 0 | — |
| `runtime-calls-faults` | 8 | 2 | 5 | 1 | 0 | — |
| `wider-functions` | 354 | 144 | 210 | 0 | 0 | — |
| **total** | **87 067** | **18 767** | **68 118** | **15** | **3** (known) | 25 TIMEOUT, 127 PLAINFAIL, 12 BOTHFAIL |

- **No fault.** The three `TRAP`s are the corpus's known ones, as in reports 144 to 146:
  `run/ListSanitiserTrieHolder` traps as its golden says, and `dom/ShowAndBranches` and
  `tea/ShowAndBranches` are #2504 (`dom` and `browser-tea`, out of scope). The `TIMEOUT`s, `PLAINFAIL`s and
  `BOTHFAIL`s are those of report 146.
- **Every generator of report 146 gives its verdicts again**, count for count; `corpus` has 13 more
  programs, the new fixtures among them, all `REFUSED`.
- **`alias-ctors`** on the base: 81 `TRAP` (every `live` twin of `built.*` but `built.mapped`, 7 of the 9
  `matched.*` `live` twins (a lambda's and another module's pattern were refused `unknown`), every `param.*`
  `live` twin, and 7 `absent.*`), 85 `SAME`, 22 `REFUSED`. On the fix: 0 faults,
  79 `SAME` (all `dead`), 109 `REFUSED`, of which 15 are `dead`: the 10 `absent.*` casts (no claim) and 5
  `built.mapped` twins whose elements share the list the partial application captured.
- **The blind round's** 442 programs and 3 fault folders, and this report's 21 probes: 0 faults.

## 7. Speed

`bench/ownership-v2-review.mjs --checkers=v3 --runs=1 --jobs=1 --roots=real` on ReleaseFast LLVM compilers of
the base and of the fix, three rounds, alternated, the least of each root kept. The machine was shared
(load average 13 to 28).

| Measure | Base | Fix | Change |
|---|---:|---:|---:|
| v3 on the 32 real roots | 1 252.1 ms | 1 269.0 ms | +1.3 % |
| the same without `platforms/browser` | 836.6 ms | 855.3 ms | +2.2 % |
| `platforms/browser` | 415.5 ms | 413.7 ms | −0.4 % |
| verdicts of the 32 real roots | 1 477 demands, 1 370 accepted, 107 refused | the same, line for line | — |

The largest rise is `examples/conduit`, 116.8 to 121.1 ms (+4.3 ms): its records built by alias
constructors now make an object and its slots, and its `Schema` issue records read through a cast test
their slots (`slotHeld`). Every other root moves by 1.3 ms or less. The work the fix adds is counted
(kernel §8): `builtAbsent` a lookup, `punned` a scan of a map kept for each pair, `slotHeld` and
`castSlotLost` a scan of the argument's layout, each only at a cast.

## 8. The review

One fresh adversarial reader (Opus), given the diff and the kernel, wrote 478 programs in five folders
(records built and matched by alias constructors in every form, across modules, generic, nested, one
field, as function values through `List.map`, `List.map2`, `Maybe.map2`, user functions; puns of tuples,
constructors, lists and `Maybe` through identities and non-identities) and ran each under the four legs
on the base and the fix.

- **Found, fixed: a constructor read as another type's constructor.** `Y xs` of
  `type W = X (List Int) | Y (List Int)` read as `type V = V (List Int)`: `V`'s argument and `X`'s are one
  step (constructor steps are by position), which `W`'s place has, so `builtAbsent` answered `none`; `V u`
  reads `.a` with no test. 12 programs. An identity whose reading has a constructor's argument or a slot
  that the argument's own layout does not cover is now `unknown` (`punned`). A first version made every
  identity between two concrete types `unknown`; it refused core's `List.close` (a `List a` read as a
  `Builder a`) and two `ownership/core/Cast*` fixtures, and was narrowed to the uncovered slot or argument.
- **Found, fixed: a cast in a callee's body.** `toR : a → R; toR x = Pun.conv x`, called with
  `( n, [ 1 ] )`: the answer's slot `.a=` holds the parameter's one location, so the caller's slot held the
  list's cell and not the tuple's object. 16 programs, and 7 dead twins that trapped under the sanitiser. A contract that pairs a wide location with a
  concrete one is a cast, and its slot is held only by the argument's slot at the same path
  (`castSlotLost`, `slotHeld`). A first version tested "a slot of the field anywhere in the argument",
  which left a record of the same field beside the tuple open; the path test closed it
  (`run/RecordPunBeside`).
- **Held**: no program the base refuses is accepted by the fix and then fails; no ordinary program (no
  `Js`) is newly refused. 20 dead twins move from `REFUSED` to `SAME` (constructor patterns and
  constructors across modules), each the verdict of its literal twin.

On the final fix the reader's 478 programs (18 that do not build) are 317 `REFUSED`, 143 `SAME` and **0
faults**; on the base, 160, 176 and 124 `TRAP`. 23 more dead twins of
puns are refused than on the first version, a cost of reading a cast as no claim.

## 9. Reproduce

```sh
node bench/ownership-sweeps/alias-ctors.mjs <dir>/alias-ctors
node bench/ownership-sweeps/run.mjs --beni=zig-out/safe/bin/beni --checker=v3 --mode=both --jobs=24 --tmp=<disk> <dir>/alias-ctors
TMPDIR=<disk> node bench/ownership-v2-review.mjs --beni=zig-out/safe/bin/beni --checkers=v1,v3 --runs=1 --roots=real
zig build test-blackbox -Dcorpus=RecordAliasCtor       # and -Dcorpus=RecordPun
```
