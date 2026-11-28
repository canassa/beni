# 158 — Ownership v3: records precision, round 3

*Research report, 2026-11-18. The third lane of the records precision round of the checker v3
(`--ownership=v3`, `src/own3/`): the wins research report 154 §5 declined, and the smaller losses. Issues
#2548 (item 2), #2532 (items 2 and 4), #2546 and #2550. It revises kernel (`ownership-v3-kernel.md`) §3.1,
§3.4, §4.1 and §4.4.*

---

## 1. Result

| Issue | Rule | Won | Left |
|---|---|---|---|
| #2548 item 2, the `Dict` wall | five facts (§2): a typed answer, a top-level value through `Loc.all`, a constructor pattern's positions, one value of a join at a time, a regular type's own layout | 16 verdict lines of 11 corpus roots; `run/BasicsEqOwnEq` and `run/DictSetEquality` accepted whole (9 evidence refusals of `Dict.eq` gone) | a value written in a dictionary that `insert` built: the deep level is still `twice` (§2.6) |
| #2532 item 4, #2548 item 2: get, then set or insert, at one index or key | not built: needs a positional word (§3) | — | the design choice of §3 |
| #2532 item 2, #2548 item 4, #2546: budgets | not built (§4): the cost is located | — | `finish` reads the answer once per location |
| #2550, #2518 | not reached | — | — |
| the second review: a captured cast function (on the base too) | a cast function's answer read at a location that is not wide is lost (§7) | soundness: 20 `TRAP` programs refused | — |

- **Real-writes ledger** (`ownership-v2-review.mjs --checkers=v1,v3 --roots=real`): **294 of 308 before and after**,
  row for row; v3 refusals at positions v1 has no line for: 18 before and after. No real root changes a verdict.
- **Verdicts on every ownership root** (§5): refused → accepted 16 lines, refused → absent 9 (evidence); **accepted →
  refused 0**.
- **Sweeps** (§6): 90 266 programs under the four legs, the three known faults only.
- **Reviews** (§7): two fresh adversarial readers, no fault in the new rules; the second found an older cast hole, fixed (`run/CastCapturedLambda`).
- **Time** (§8): v3 on the real roots 1 308.9 → 1 291.7 ms (−1.3 %, noise).

## 2. The `Dict` wall (#2548 item 2)

Report 154 §5 named the wall as `insert` reaching `insertHelp` "through a `type_dispatch`". The BIR has no such
instruction there: `insert (Dict tree) key value = Dict (blacken (insertHelp tree key value))` is a plain call
(`dump --stage=bir`). A bisection on private copies of the tree code found the real causes, in this order.

### 2.1 An `Int` key at the values: a typed answer (§3.4)

A parameter of a type of no location holds `outside` (kernel §3.4), and a call reads a parameter source as the
argument's leaves. `insertHelp`'s contract puts the key at the values' location (`k` and `v` are one place, and
the deep level is read through `Loc.all`), so every value of a dictionary built by `insert` with an `Int` key held
`outside`, which refuses a write. A callee that does not cast answers a value only at a location of its own type
(*What a value was made from*); the reading has a location at the entry and the key's type has none, so the key
is not there. `SrcState.typed` drops such a source where neither the callee nor a function argument casts.
`useG2 d k = insertG d k { n = 1 }` (a generic copy) lost its `outside`; so did core's `Dict.insert`, `update`,
`fromList` (§5).

### 2.2 `Dict.empty`'s deep level (§3.1)

A top-level constant is read through its contract (`evalInner .top`): `outside` where an entry has a source.
A location of the reading at `Loc.all` (a deep level the contract reads through a type variable) held
`outside` whatever the contract said. Now it holds it only where some entry has a source (`topHolds`); none of
`Dict.empty`'s does. Wins `ownership/Toplevel` 58:15 and `run/SanitiserEmptyValue` 35:17, 36:17.

### 2.3 Two children of a recursive type: positions (§4.4)

`Node nColor nKey nValue nLeft nRight` reads `nLeft` and `nRight` at one deep level. Report 154's positions
apply to a constructor pattern of two or more arguments on the same condition as a list pattern's (`listParts`):
each argument is bound at a position of a new match. A scrutinee that already carries a list pattern's position
keeps it (the first attempt started an inner match there and lost 115 lines of `CycleLink*`, `RecursiveSiblings`,
`ViewCycleHolder`: `[ Rose l k, …rest ]`'s `l` was no longer apart from `rest`). Wins `ownership/FoldLevels`,
`LevelFresh`, `ReturnedKids`, `ReturnedKidsImported`; fixture `run/TreePartsApart` (refused on the base,
`later-use`) and its live twin `run/TreePartsShared` (one record at three places: refused).

### 2.4 One value of a join at a time (§4.4)

`finish` called a contract `nonlinear` where a cell is at two locations of the merged runs of the result. A
recursive insert answers its argument at the root in one arm and below it in the other; a run answers one arm.
Where the merged runs say yes and the result is a join, each value is now tested on its own (`atTwoLocations`,
joins nested to depth 8; deeper, the merged runs). The first version tested every arm always and doubled the work
of `finish` (§4's profile showed it); the merged test runs first now. Wins `ownership/FoldCertificateRawBase` (6),
`RecastActualSep`, `SlotRecursiveFamilies` (2); fixture `run/JoinOneValue` (refused on the base, `element`) and
its live twin `run/JoinOneValueShared` (`Node a [] a`: refused).

### 2.5 A regular type read at its own layout (§4.1)

A recursive call at the declared type, or `balance` called by `insertHelp`, reads the callee's result at the
same layout as the contract's; the call map still answered `Loc.all` for every deep location (§4.1's guard
against a caller whose places split a wide entry). With one layout there is no split, so `cover(sig, of)` is the
identity there, but only for a regular type: a family (`ownership-v2.md` §2.1, *A family*) has one place for all
its instantiations. The first version without that condition accepted `run/SanitiserFamily`'s writes (28 lines
went from refused or accepted to absent, the writes of folded payloads vanished from `wr`'s contract); the
family is now recognised by its payload place, a `var` other than the one place of every type variable
(`Loc.familyBelow`, `plain_var`). `run/SanitiserFamily.sanitize-lists-v3-refuses` pins it. Wins `Dict.eq` as
evidence: `run/BasicsEqOwnEq` and `run/DictSetEquality` lose their 9 evidence refusals and are accepted whole
(both now carry `.sanitize-lists-v3`).

### 2.6 What is left: the first `via`

A value written in a dictionary that `insert` built is still refused (`element`): `balance`'s answer holds
`insertHelp`'s recursive answer at both its levels, and the atoms of that answer were first read through the
tree parameter (`via` is the first root an atom was read through, `copyAtoms`). A linear call root whose two
entries hold one atom cannot then tell them apart. The fix is a second `via` (the last linear root, with its
entry), read by `viaApart` and by `runsShare`'s tables alike, so `checkShare` stays exact; it is a change to
`Atom` and to the linear-time duplicate test, not attempted here. `insertLeft (insertLeft Leaf a) b` meets the
same wall in a user's tree.

## 3. Get, then set: a positional word (a design choice)

`List.get l i` … `List.set l i v` and `Dict.get d k` … `Dict.insert d k v` replace the element they read when the
index or key is one local and the list one value. No fact in the words says so: `set : written returned List a,
borrowed Int, stored a → List a` is also true of `insertAt`, which keeps the element. A rule needs the fact that
the `Int` is a position, that `elementof` answers the element at it and `stored` replaces it. Kernel rule 11
forbids reading `List.set` by its name. So it is a word, and `Ast.OwnWord` is `enum(u5)` with 32 members: a
33rd widens every word set (`Bir.OwnSlot`, the frontend artifact, v1's and v2's readers).

**Recommendation**: a word `position` in a v3-only column, as `Bir.ownSlotsV2` keeps v2's words from v1, on
`unsafeGet`, `set`, `focus`, and later `Dict` rows; the caller tracks a position keyed by (list value, index
local) as report 154's match, and `set`'s answer holds the list's elements at the other positions. A v3 column
also unblocks rows on `Dict.get` and `Dict.insert`, which v2 cannot read (kernel rule 10, `Dict.focus`).

## 4. Budgets: where `Gpu.Make.checkedIn` spends its units

A sampling build (a stack every 20 000 units, `--jobs=1`) of `platforms/browser` puts most of `checkedIn`'s units
in `finish`: for each of the result's locations it reads the whole answer again (`leavesAs` per entry, each a
walk of the construction, `leavesSet` → `leavesOwnWalk` → `leavesOwn`). A `Result Error.Error V` has thousands of
locations, so the work is locations × construction. A linear version reads the answer once, splitting the atoms
by entry as it walks; `leavesOwn`'s memo is keyed by entry set, so it needs a walk of its own. Not built.

## 5. Verdicts on every ownership root

`dump --stage=ownership --ownership=v3 --ownership-everywhere` of all 2 862 roots of the base and 2 867 of the
last commit (the new fixtures). Lines that only moved are left out.

| Root | Change | Rule |
|---|---|---|
| `ownership/Toplevel` 58:15 | refused → accepted | §2.1, §2.2 |
| `run/SanitiserEmptyValue` 35:17, 36:17 | refused → accepted | §2.2 |
| `ownership/FoldLevels` 94:23, `LevelFresh` 46:23, `ReturnedKids` 26:21, `ReturnedKidsImported` 12:21 | refused → accepted | §2.3 |
| `ownership/FoldCertificateRawBase` 75:15, 91:18, 95:15 (6), `RecastActualSep` 44:5, `SlotRecursiveFamilies` 23:15 (2) | refused → accepted | §2.4 |
| `run/BasicsEqOwnEq` (4), `run/DictSetEquality` (5) | evidence refusal → absent | §2.5 |

**Refused → accepted: 16 lines; refused → absent: 9; accepted → refused: 0.** Each rule's lines were confirmed by a
build with that rule turned off (§2.4, §2.5) or by the order of the commits (§2.1–§2.3).

## 6. Sweeps

`run.mjs --checker=v3 --mode=both` with the ReleaseSafe compiler of the first commit (the cast fix of §7 only refuses more,
and the corpus and the casting sweeps give the same rows under it): every generator of the folder, the
fault folders, `harvest-v2-records`, the corpus and the new `precision-158.mjs` (`tree.<shape>.<twin>`,
`join.<fn>.<twin>`, `dict.<src>.<twin>`: 34 programs, all refused on the base; 7 `dead` now `SAME`, every live
twin refused).

| Sweep | Programs | SAME | REFUSED | LIMIT | Faults | Other |
|---|---:|---:|---:|---:|---:|---|
| `corpus` | 1 790 | 1 250 | 519 | 1 | 3 | 12 BOTHFAIL, 4 PLAINFAIL, 1 TIMEOUT |
| `folds-callbacks` | 30 300 | 5 669 | 24 631 | 0 | 0 | |
| `recursive-levels` | 16 131 | 3 869 | 12 262 | 0 | 0 | |
| `blind` | 9 792 | 1 683 | 8 109 | 0 | 0 | |
| `blind4b` | 6 596 | 1 350 | 5 244 | 2 | 0 | |
| `aliased-arguments` | 5 160 | 1 270 | 3 890 | 0 | 0 | |
| `precision-158` | 34 | 7 | 27 | 0 | 0 | |
| 43 other sweeps and fault folders | 20 463 | 5 206 | 15 096 | 14 | 0 | 123 PLAINFAIL, 24 TIMEOUT (as on the base) |
| **all** | **90 266** | 20 304 | 69 778 | 17 | **3** | 12 BOTHFAIL, 127 PLAINFAIL, 25 TIMEOUT |

The three are the known `run/ListSanitiserTrieHolder` and `dom`/`tea` `ShowAndBranches` (#2504). Against report
157, 102 more programs are `SAME` (`blind4b` +80, `blind` +8 among them).

## 7. Reviews

Two fresh adversarial readers (Opus), each told to write programs the new rules accept that trap or differ
under the four legs.

- **First** (about 4 000 programs: trees of records by 24 makers × 13 writers, generic helpers, joins, `Dict`s with
  `Int` and `String` keys, top-level constants, nested patterns, families, mutual recursion, casts through a
  platform of its own): **no fault**. 45 programs moved from refused to `SAME`, each safe on inspection. Rules
  2.1 and 2.2 decided almost nothing outside the fixtures: every dictionary write met §2.6 first.
- **Second** (905 programs, about 450 with a live twin: joins up to depth 12, `as` and nested patterns, an `Int`
  that is a list by 24 casts, trees from a second module, `Rose`/`List Rose`, `Tree (Tree (List Int))`, top-level
  trees, rule 3's acceptances under 12 holders, a non-regular `N a`): **no fault in the new rules**; 12 programs
  newly `SAME`, each refused on the base and safe. **One older fault, on the base too** (20 programs `TRAP`): a
  function that casts, captured by a lambda (`k = Pun.conv`, `(λy → k y) n` with `n` an `Int` that `Pun.hide`
  made of a list), answered a list nobody held, through a lambda, `appl`, `List.map`, `List.foldl`,
  `Maybe.map`, `Result.map` and a top-level tree. The holder hands `k` a value of no location, so its supply
  names nothing, and `answerOfCode` read `conv`'s answer through it as empty. **Fixed**: a cast function's answer
  read at a holder's location that is not wide is lost (kernel §3.4, *A cast function in a holder*); fixture
  `run/CastCapturedLambda` (a lambda and `Maybe.map`; `TRAP` on the base, refused). The 41 trapping programs of
  the review, rerun: all refused. No root's verdict moves, the ledger is 294 row for row, and the casting
  sweeps (`casts-at-vars`, `host-values`, `function-values`, `wider-functions`, `worded-no-location`) and the
  corpus give the same rows.

## 8. Timing

`bench/ownership-v2-review.mjs --checkers=v3 --runs=3 --jobs=1 --roots=real`, ReleaseFast LLVM compilers of the
base and the commit: v3 on the 33 real roots **1 308.9 → 1 291.7 ms** (−1.3 %, noise).

## 9. Reproduce

```sh
node bench/ownership-sweeps/precision-158.mjs <dir>/p158
node bench/ownership-sweeps/run.mjs --beni=zig-out/safe/bin/beni --checker=v3 --mode=both --jobs=20 --tmp=<disk> <dir>/p158
TMPDIR=<disk> node bench/ownership-v2-review.mjs --beni=zig-out/safe/bin/beni --checkers=v1,v3 --runs=1 --roots=real
zig build test-blackbox-corpus -Dcorpus=TreeParts   # and JoinOneValue, DictEmptyValueLive, SanitiserFamily, DictSetEquality
```
