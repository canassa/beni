# 148 — Ownership v3: an audit of every absence read as nothing

*Research report, 2026-11-16. Reports 146 and 147 each found, by a blind reader, the same mistake in
the checker v3 (`--ownership=v3`, `src/own3/`): where it had no fact about a part of a value, it answered
"holds nothing" in place of "could hold anything" (ownership-v3-kernel.md §1, §3). This report closes the
class by inspection: it lists every site in `src/own3/`, and in the `own2` code that v3 calls, where a
lookup that misses can turn into an empty answer, says of each whether a positive fact proves the answer
empty, reaches each site that none proves with programs, and fixes what they reach. The kernel is
`ownership-v3-kernel.md`; this report revises its §3.4, §4.1, §5, §6 rules 10 and 12, §9 and §11.*

---

## 1. Result

- **The audit** (§3): 498 sites in five parts of the code. **449 are proved empty** by a positive fact
  (a type of no cell, another constructor's argument, a rule of the kernel, a budget that gives up) and
  **49 are assumed empty**: 42 that the readers found, and 7 that they classified as proved and that the
  sweep of the first fix (one) and the review (six) showed are not.
- **Reached by a program** (§4): 21 of the 49, in **six faults**, each a program that v3 accepted and that
  read a list after an in-place write:
  1. a list cast to a type of no cell (`Int`), or to a list of numbers, lost its arrays: the contract of
     the function that cast it said that it keeps nothing (`run/HostValueNarrowInt`,
     `run/HostValueNarrowList`);
  2. a value read through a cast at a type with a location that its own place does not have — an array
     where it has a number — was a part of the value that no reader found (`run/HostValueWidenInt`,
     `run/HostValueNarrowList`): report 147's cast rule covered slots and constructors' arguments only;
  3. a number read as a list through `Js.Value` in a platform function of `Int → List Int` answered a list
     that nobody held (`run/HostValueFromInt`), found when the first fix was swept;
  4. a callee's operand location that the call map cannot place (`Loc.all`, a deep level read through a
     type variable) was skipped as if it were the written location (`run/CycleVarOtherPlace`);
  5. (the review) a value of a type with no location read back as a list through a type variable held
     nothing: answered as it is (`run/HostValueVarAnswer`), or by a cast handed to `Maybe.map` as a
     function value (`run/HostValueVarMap`);
  6. (the review) a callee that answers what it was handed at a type variable that its caller reads as a
     list, handed a value whose type has no cell there, gave the caller's list no cell
     (`run/HostValueVarCtor`, `run/HostValueVarRecord`).
  One more reached site was sound but made no demand at all (an update of a number read as a record,
  `run/RecordPunNumberUpdate`): it now refuses, as report 147's slot write of no cell does.
- **Fixed** (§5): 15 changes, which close 45 of the 49 assumed sites: the six faults, the update above,
  and the latent sites, each now the pessimistic answer or proved by the cast's rule. **A value whose type
  has no location holds `outside`**, never nothing: whatever a cast put there escaped where it was put.
  Four sites stay open, argued (§12). **Ten `run/` fixtures** fail on the base and pass after.
- **Safe-build checks** (§6, kernel §9): every location that a reader asks of a value at another reading
  than its own is placed in the value's own layout (`Frame.checkPlaced`, at every reader, not only at
  `finish` as report 146's `checkEmpty`). With report 146's rule turned off, the first program the gates
  build panics. A join of two contracts of different signatures panics unless the first has no fact.
- **A generator family** (§7), `build-read.mjs` (1 050 programs): ten ways to build a value crossed with
  fifteen ways to read it, each with a write in place and three twins. On the base its cast through an
  `Int` traps 60 times; on the fix, 0.
- **Verdicts** (§8): of the 2 768 ownership roots of the base, **no root newly refuses a program it
  accepted** but one `browser-tea` page (out of scope). 17 roots change lines, every one of them a
  program the base refused already. **Real-writes ledger: 294 of 308 before and after**, and every v3
  demand of the 32 real roots has the same verdict.
- **Sweeps** (§9): every generator (the new one included), every fault folder, the corpus, the readers' probes
  and the review's programs under the four legs, 88 214 programs: **0 faults** but the corpus's three known
  ones and one `case` of #1997's (§11).
- **Speed** (§10): v3 on the 32 real roots **+2.0 %** (ReleaseFast, the least of five alternated rounds),
  +3.0 % without `platforms/browser`; every demand count the same.
- **Review** (§11): one fresh adversarial reader (Opus) found two more faults (5 and 6), both on the base
  too; both fixed, with four fixtures. The fixes after the review (fix 8 to 17 of the work) are covered by
  the reader's own 526 programs and the full sweeps, not by a second reader.

## 2. Method

Five readers (agents forked with this report's brief) each read one part of the code every line:
`Frame.zig` in four parts (lines 1–1 830, 1 830–3 240, 3 236–5 390, 5 387–7 917) and `Check.zig`,
`Contract.zig`, `Loc.zig`, `Enforce.zig` with the `own2` code v3 calls (`Place`, `Groups.Adapter`,
`Prepass`). Each listed every site where a miss can become an empty or an optimistic answer — an
`orelse`, a `continue` in a loop that builds a set, an early return, a `v_none`, a `false` for "may hold"
or a `true` for "apart" — and classified it. Each assumed site was probed with programs on the base
compiler (`7c6f8ffcb7`), built plain, sanitised and in place. The line numbers below are the base's.

A site is **proved** when a positive fact makes the empty answer true: the kernel rule or the code
invariant is named. A **pessimistic** site answers "can hold", "can share" or gives up (a budget, §8 of
the kernel): it is proved too, on the side that refuses. A site is **assumed** when nothing but the
absence says the answer is empty.

## 3. The audit

The tables give, for each site, what is looked up, what a miss answers, and the class. `P` is proved
(with its fact), `pess.` pessimistic, `A` assumed; an assumed site gives what this report did with it.

### 3.1 `Frame.zig` 1–1 830: values, atoms, duplicates, leaves

| Site | Looked up | A miss answers | Class |
|---|---|---|---|
| 521 `giveUp` | a value the walk cannot follow | `unknownOf(place, &.{})` | P: the frame fails, publishes nothing, refuses every demand (§3.3) |
| 553 `noteWalked` | an instruction's bit | skipped past the bit set | P: a safe-build check only |
| **592 `rootVal`** | the root's layout | `v_none` for a layout of no entry | **A, reached (faults 1, 5)** → fixed: `v_outside` (§5) |
| 601, 606 `joinVal` | arms that are `v_none` | skipped; all `none` is `v_none` | P: a fact of each arm |
| 621 `armLive` | an arm's context | arm skipped | P: rule 7 |
| 632 `newRoot` | a parameter's or capture's linearity | `yes` | P: the apart-arguments rule (§4.4) |
| 639 `newRoot` | an answer's or fresh root's linearity | `yes` | P: no entries; `via` is set only for locals |
| 675 `freshAtom` | an escape noted for the root | no second escape | P: already in `esc_atoms` |
| 701 `overlap` | root 0 | false | P §3.1: the outside atom refuses by permission |
| 744, 770, 926, 979, 1038, 1067, 1198, 1582–1584, 1601–1603, 1617–1619 | the budget (`charge`) | "can share", not linear, `outside_atom` | pess. (§8) |
| 755 `isLinear` | an undecided root | `no` | pess. (asserted, §4.4) |
| 786 `viaApart` | `via` missing, different or not linear | not apart | pess. |
| 787 `viaApart` | different `via_e` or incomparable `via_path` | apart | P: `linear` is derived; one layout's entries are apart |
| 798 `partDup` | the first part | not tested | P: no earlier part |
| 913 `shareWith` | fewer than two runs | false | P: a run's own duplicate is its `dup` |
| 925 `shareWith` | an atom of root 0 | skipped | P §3.1 |
| 941 `shareWith` | an empty group | no test | P |
| 985–986 `shareEach` | an unselected pair | skipped | P |
| 1022–1026 `shareTables` | a table miss | `no` | P: equal to the test in pairs (`checkShare`) |
| 1040, 1044 `shareLook` | no path up to `mind` | null | P |
| 1052–1054 `shareFit` | two kept atoms of other keys | null | P (§8) |
| 1110–1113 `atomsShare` | as `overlap`, `viaApart` | as above | P |
| 1152 `deriveLinearSplit` | no claim | derived from atoms | P §4.4 |
| 1160 | entries with an empty run | not tested | P: the run holds every other root's cell |
| 1171, 1207–1211 | pairs the claim covers | skipped | P §3.4, §4.4 (`canShare`) |
| 1203 | `e2 == e1` | skipped | P: a duplicate in one entry is its `twice` |
| 1244 `twiceAt` | a root that is not local | false | P |
| 1305 `rootLeaves` | an `alias` entry's own atom | none | P §4.3 |
| 1308 `rootLeaves` | the run of an `own` or `taken` entry | not copied | P §4.3; `taken` by a trusted row |
| 1319, 1459 | the budget | false, no atoms | pess. (the declaration gives up) |
| 1322, 1680, 1792, 1832 | `none`, `fnref` | no atoms | P: `fnref` by the position rule; `none` as sound as its producer |
| 1334 `leaves` | a closure's captures' `dup` | dropped | P: rule 3 |
| 1338–1341 `leaves` | an unknown's members' `dup` | dropped | P: its leaves hold `outside_atom` |
| 1490, 1614 | a part that is `v_none` | skipped | P: rule 4 |
| 1495, 1627 | an object part's entries | own slots only | P §11.2 |
| **1500 `builtIndex`** | a part's location with no location in the whole (`up` is `none`) | the part never indexed | **A, latent → fixed**: the part is read for every entry |
| 1504, 1652 | no projection for a part's step | the whole part read | pess. |
| **1553–1555 `leavesOwnWalk`** | a part's location the root does not name (`to_root` is `none`) | `outside_atom` only | **A → fixed, and reached**: a read or an escape of it read none of the root's cells; every entry of the root is read now (§8: `PolyRecBranch.ww`) |
| 1564 | `dup` of local roots only | false for a parameter | P: the caller's `argsApart` |
| 1577 `builtKids` | parts with no location at the asked entries | not walked | P (§8), given 1500 |
| 1591, 1629, 1655 | a single asked entry | no `partDup` | P §4.4 |
| 1628, 1651 | `js` empty | the part not read | P, given 1500 and 1553 |
| 1664 | a dead arm | skipped | P: rule 7 |
| 1689, 1692 `leavesSet` | the same place or layout | own reading | P |
| **1705, 1737 `leavesSet`** | an own entry the reading's map does not cover | never read | **A, reached (fault 1)**: closed at the cast (`narrowed`); a reading with entries puts it at `Loc.all`, which is read |
| 1741 | `slotsLost` | `outside_atom` | pess. (report 147) |
| 1750, 1754 `holeFlags` | `holes` null, `read[j]` none | no extra flags | P: `Loc.holes` |
| **1774 `unknownOf`** | a place of no entry | `v_none`, dropping each member | **A, reached (fault 1)** → fixed: `v_outside` where a member holds anything |
| 1776, 1778 | members `none` or `outside`; no member | `v_outside` | P §3.2 |
| 1819 `reach` | a value reached in this walk | false | P (§8) |

### 3.2 `Frame.zig` 1 830–3 240: reaches, projection, reads, demands, patterns

| Site | Looked up | A miss answers | Class |
|---|---|---|---|
| 1811, 1863, 1869, 1971–1972, 1979, 2001, 2006, 2038, 2405, 2618, 2684, 2688, 2721, 2843, 2851 | the budget | reaches, refused `limit` | pess. |
| 1832 `reachWalk` | `none`, `outside`, `fnref` | false | P §3.1 |
| 1839 | a dead arm | skipped | P: rule 7 |
| 1842–1844 | an unknown: its members only | `outside_atom` not compared | P §3.1 |
| 1865 | a target atom of another root | skipped | P: §2's atom invariant |
| 1867–1870 | a target above the part, entry not in `to_root` | not reached | P §4.1 |
| 1895, 1940 | `own`/`taken`: run not read | skipped | P §4.3 |
| 1898, 1984 | a field slot not below the part | skipped | P §11.1 |
| 1906 | `outside`, `param`, `capture`, `fresh` roots | no run | P: atoms only (§4.2) |
| 1904 | the answer equal to `skip_answer` | base not read | P: its base is W (§6.2) |
| 1925, 1927 `runEntries` | undecided or small | full scan | P: same answer |
| 1943 | an empty run | left out | P |
| 1997–2025 | an old name | not compared | P §5.1 |
| 2053 | a `WIndex` group miss | empty | P: every atom of W is indexed |
| 2085 | a write of at most 32 atoms | scanned | P: same answer |
| 2149 `placeOfVal` | `none`, `outside`, `fnref` | null | P |
| 2160–2165 `project` | `none`, `outside`, `fnref` | `v_none`, `v_outside` | P §3.1 |
| 2169, 2189, 2193, 2199, 2259, 2262 | a step a root, join or unknown lacks; the budget | `unknownOf` | pess. §3.4 |
| **2171, 2200** | a child place of no entry | `v_none` | A (the readers said P; a part of no location can hold what a cast put there) → fixed: `v_outside` |
| 2253 `builtAbsent` | a step the construction's place lacks | `unknownOf` | pess. (report 147) |
| 2254 `builtAbsent` | a step the place has, no part | `v_none` | P: rule 4 (`built`, checked for records); another constructor's argument in a dead arm |
| 2236–2237 | `builtPart`'s first part | first | P: the scan's answer |
| 2299 `compatible` | the budget | true | pess. |
| 2305–2316, 2335, 2341, 2343 | reads of `none`, `outside`, `fnref`; a layout of slots only | no read | P §3.1, §11.4 |
| 2353 `readBy` | a whole value with no read flag | no read | P: the contract's flags |
| 2372 | cover `none` or `Loc.all` | `all` reads where any flag reads | pess. |
| 2373, 2376 | an entry with no flag | not read | P: the flags and `holeFlags` |
| **2408 `refReaches`** | a part's entry the root does not name (`to_root` none) | false | **A, latent → fixed**: reaches |
| 2411, 2419, 2432, 2446–2448 | outside root, `own`/`taken` run, empty run, an old run | false | P (§3.1, §4.3, §5.1, asserted) |
| 2454, 2466 | `escape` of `none`/`outside`; no atoms | nothing | P |
| 2510, 2521, 2524 | `markAtoms` of own/alias atoms; an answer; outside or fresh roots | not followed, no flag | P (runs copied by `rootLeaves`; `freshSrc`) |
| 2594, 2596 `otherReaches` | `none`, `outside`, `fnref` | false | P §3.1 |
| 2598, 2604 | a spread item: storage only | others skipped | P |
| 2611–2612 | an operand with no sig, or whole | false where written | P: an unknown holds `outside_atom` |
| 2628–2636 | the written part's suffix not found | skipped at `skip` | P (probe `applywide` refused) |
| 2648–2661 | a target of no layout | any kind | pess. |
| 2687–2692 | an answered location that cannot share with the targets | skipped | P §11.9 (`canShare`) |
| 2694–2696 | the entry mapped to the written one | skipped | P: it is W |
| **2698–2700 `otherReaches`** | an operand entry the map sends to every entry (`Loc.all`) | skipped whenever a location is written | **A, reached (fault 4)** → fixed: another place of the operand where another location has a flag, apart only when the operand holds each cell once |
| 2701 | an entry with no flag | skipped | P |
| 2714–2726 | another location of a written root, apart | skipped | P §5 test 2 |
| 2737, 2739 `isSlotAtom` | an outside or fresh root; entry out of range | false | P (kept as no slot, pessimistic in `list_only`) |
| 2751–2758 `demand` | a list write whose W is empty | accepted | A, kept: a list value holds its array, so an empty W comes from another constructor's argument in an arm that does not run, or a cast, which is now `unknown` (`punned`); `outside` there would refuse dead arms (§12) |
| 2786–2799 | a repeated demand | merged | P |
| 2849, 2966–2967 | an escape or a read in another context; a read at the write's time | skipped | P: rule 7, §5.3 |
| 2866 | an answer scan past the budget | no rewrite mark | pess. (gives up) |
| 2878, 2907, 2925, 2936 | grounds | text only | P: no verdict |
| 2949 | a failed walk | refused | P §3.3 |
| 2994–2999 | a send | accepted | P: rule 13 |
| 3041, 3057 | a constructor pattern with no argument; a wild field | nothing bound or read | P |
| 3051–3055, 3064, 3076 | an alias field, a constructor row or a record field missing | `unknownOf` | pess. |
| 3065 | `v_none` | `v_none` | P |
| 3079, 3100 | `bindPattern`'s and `readsList`'s `else` | nothing bound or read | P today (each listed tag binds no local); not exhaustive, against §3.3 (§12) |
| 3122 | the budget | `giveUp` | pess. |
| 3156–3162 `makesObject` | a miss | false (old result) | pess. |
| 3175, 3177 `mention` | not a function | no `flowTop` | P: each function is mentioned where it is made |
| 3196, 3205 | `own > arity` | every flag | pess. |
| 3220–3224 | a capture in the declaration's frame; seen | `v_outside` and fail; the same root | P §3.3 |
| **3227** | a captured local of no entry | `v_none` | A (as 2171) → fixed: `v_outside` |

### 3.3 `Frame.zig` 3 236–5 390: expressions, markup, constructions, records, calls, `finish`

| Site | Looked up | A miss answers | Class |
|---|---|---|---|
| 3241 | a literal | `v_none` | P: no cell |
| 3276, 3284 | a field or index of `v_none` | `v_none` | P |
| 3289–3291 | interpolation | `v_none`, parts read | P |
| 3295 | a `top` reference with no declaration | `unknownResult` | P §3.1 |
| 3306 | the reading's layout of no entry | `v_none` | P |
| 3307, 3308 | a top-level value's contract | `v_outside` | P §3.1 |
| 3313–3316, 3321 | a contract result location with no source | no atom | P: a location with no source holds none, `finish` complete (§9) |
| 3361 | `?` on `v_none` | `v_none` | P |
| 3453 | a component's children | escape | pess. |
| **3457–3465** | a kept hole's value that is a `join` | read, not kept | **A, latent → fixed**: a join is kept where an arm is (`keptHole`, rule 12) |
| 3567, 3600, 3658 | a `For`/`Show` with no list; a position; a valueless item | nothing | P |
| 3580–3582 | `valOf` | `unreachable` | P |
| 3598, 3602–3613, 3660 | a row's type, code or row missing | escape | pess. |
| 3696–3706 | a hole that is not a helper call | not a helper | P: `markup_reads` holds what it reads |
| 3724, 3729 | a constructor's function type; a result of no entry | `v_none` | P |
| 3725, 3727, 3737, 3738 | `ctorInfo`, arity, step | `v_outside` | pess. |
| 3742 | `up[j] == none` in `ctorValue` | no source | P: `Loc.proj` places each child entry outside a cut |
| 3744 | `locsMeet` false | no source | P §4.1 |
| 3751–3753 | another constructor's argument | no source | P: rule 5 |
| 3757 | flags | read everywhere | pess. |
| **3771** | a construction of a type of no entry | `v_none`, dropping its parts | A (the readers said P), **reached (fault 6: `W i 1` at `W Int`)** → fixed: `v_outside` where a part holds anything |
| 3784–3787 | every kid `v_none` | `v_none` | P (§9 `built`) |
| 3806, 3811 | the budget; no element step | `unknownOf` | pess. §6.4 |
| 3835, 3857, 3865, 3861 | a literal's own storage; `v_none` items; `downOf` empty | `own`; skipped | P |
| 3886, 3887, 3894, 3896 | `Record.copy` of `v_none`; level steps; `v_none` parts | fresh; skipped | P |
| **3924 `recordUpdate`** | a base that is `v_none` | a fresh record, **no demand** | **A, reached (sound)** → fixed: the slot write of no cell writes `outside` (§11.3) |
| 3932 | slot atoms none | `outside_atom` | pess. (report 147) |
| 3941, 3952, 3959 | `placeOfVal` null; level; `v_none` parts | the update's place; skipped | P |
| 3968, 3975, 3993 | not an own slot; slot label miss | not a slot; whole value | P, pess. |
| 4002–4012, 4029–4038 | `slotAtoms`, `readSlots` of `none`/`outside`/no slot | nothing, `outside`, `readAll` | P, pess. |
| 4056, 4064, 4073, 4078, 4086, 4102 | `recordOf`: budget, no entry, a field, a new base | as named | P (§9 `built`) |
| 4120, 4155, 4157, 4229, 4234, 4255–4257, 4267 | `let` values, code bindings, groups | none | P |
| 4416–4421, 4433, 4457–4477, 4494 | `solveCodes`: budget, depth, bottom, rounds | `failed`, wide | P, pess. |
| 4551 | a `later` slot unbound | `unknownOf`, fail | P §3.3 |
| 4609 | a result `v_none` | no atoms | P |
| 4644, 4651–4654 | an answered slot; `fns` of non-functions | `flag_a`; null | P §11.9 |
| 4687 | the small set | pairs only | P |
| 4715–4725 `checkEmpty` | wide entries above only | — | check only; its net is `holes.above` (§6 adds every reader) |
| 4770, 4771, 4774 `atomSrcs` | visited; budget; alias atoms | skipped | P, pess. |
| 4791–4805 `freshSrc` | the escape memo | from its mark | P: escapes only grow |
| 4829–4834, 4857–4858, 4871 | constructor step, callee, contract missing | unknown code | pess. §6.10 |
| 4898 | a primitive's markup arguments | held, not escaped | P §6.12 |
| 4916, 4921 | no code, wrong arity | `giveUp` | P §3.3 |
| 4956–4960, 4969 | dispatch misses; `undetermined`, `primitive`, `param` | unknown; reads | pess., P §6.11 |
| 5018–5020 | `dispatch`, `sites` missing | no effect | P: `Dispatch.checkI7` |
| 5049, 5056, 5072 | no write; an operand of no atom; `none`/`fnref` | no demand | P |
| 5126, 5257 | `argEntries` false | `leaves(v, 0)` | P: unknown, outside, closure hold all at 0 |
| 5157–5177 `slotHeld` | held branches | no `outside` | P, but the cycle branch: **A, known (#2540)** |
| 5190–5225, 5244 | not a slot; outside/unknown; above; wide | not lost | P |
| 5283–5305 | a suffix missing | fallback, all hits | pess. |
| 5296, 5302 | an own entry mapped to `all`; closures above | skipped unless deep; no wide add | P |
| 5346, 5352 | `cov[k]` none | dropped | P: `none` only for an empty sig |

### 3.4 `Frame.zig` 5 387–7 917: calls, identities, flows, answers, the entry

| Site | Looked up | A miss answers | Class |
|---|---|---|---|
| 5401–5413 | the arity of a partial application | every value to `top`, escapes | P §6.2 |
| **5419–5426 `applyAt` identity** | the reading's locations against the value's own | `args[0]` as it is; own entries no reading location names dropped | **A, reached (fault 1)** → fixed: they escape (`narrowed`) |
| 5425, 6081 `punned` | `placeOfVal`, else the argument's place | no pun | P for a value with a place; **A, reached (fault 3)** for `v_none` read through `Js.Value` → fixed; missed by the reader, found by the sweep |
| **6084 `punned`, `v_none` at a type variable** | a value of no cell read at `var` or `opaque` | no pun | A (missed; the review), **reached (fault 5)** → fixed: a pun |
| 6082 `punned` | `own == place` | no pun | P |
| **6084 `punned`** | `var`, `opaque`, **`cross`** kinds | no pun | `var`/`opaque` P (wide, §3.4); **`cross` A, reached (fault 2)** → fixed |
| **6101–6103 `punned`** | an uncovered reading location of kind slot or constructor argument only; the root location skipped | no pun for a list level | **A, reached (fault 2)** → fixed: any kind, any location, `none` or `Loc.all` |
| 5442–5446, 5450 | escaped entries; `fns` null | as listed | P |
| 5467 | a written slot entry of no atom | `outside` | pess. (report 147) |
| 5467 | a written list entry of no atom | accepted | A, kept (as 2751–2758) |
| **5489 `applyAt`** | a result layout of no entry | `v_none` | **A, reached (fault 1)** → fixed: `v_outside` |
| 5510, 5519 | `cov[e]` none; `Loc.all` | `lostAnswer`; every source | pess. |
| 5555, 5574–5590, 5578 | `twice`; split; cover none | as listed | P §3.4, §4.4 |
| 5694–5724 `partsOf` | none/outside; depth 8; dead arms; roots; unknown; empty | apart, or not | P, pess. |
| 5622, 5626, 5637, 5664, 5665 | `argsSplit`, `runsApart` | as listed | P, pess. |
| 5774, 5782, 5805, 5820, 5843, 5855 | `expandSrcs`: budget, prefix, arg out of range, no atom, twice | lost, all, twice | P, pess. |
| 5847, 5859, 5880 | `alternatives`, `fnc` null | skip, not alternatives | P §4.4 |
| 5900, 5905, 5916 | `pairedLeaves`: cast slot, not prefix, fallback | `outside`, all, `dup` | pess. |
| **5925 `pairedLeaves`** | an argument that gives no cell (or only slots) at a caller's list | nothing | A (missed; the review), **reached (fault 6)** → fixed: `outside` where the argument's type holds no cell on the path (`Loc.emptyAlongLabels`) |
| 5938–5951 | `ownFnRoot`, `isFnRoot` | none, not a root | P (pessimistic `flowUnknown`) |
| 5973–5975, 6008, 6043, 6051 | `locsMeet`, `meetsOf` undecided or budget | meet, give up | pess. §4.1 |
| 6115–6119 `isIdentity` | preconditions | not an identity | P |
| 6132, 6146, 6162, 6163, 6175, 6178 | code, suffix, `v_none`, budget, memo, in work | as listed | P §3.2, §3.3, §8 |
| 6274, 6292, 6310–6314, 6333, 6349, 6365, 6366 | `flowCode`: top, called, `slotsOf`, `fns`, arity | default, no escape, every supply | P §6.2, §6.8 |
| 6397–6427 | lost, top, arity, `fe` | `supplyLost`, returns | P §6.8 |
| 6450–6504 `slotsOf` | top; `k ≥ arity`; filter empty; no meet | `outside`, all, every slot, true | pess., P §4.1 |
| 6572–6583 `resolve` | twice, arg range, top, depth, `slotsOf` | `outside`, lost | P (asserted), pess. |
| 6630, 6648–6661 | fresh; `EscSink`; unknown answer | no old names; nothing | P (§5 test 3 through `escapeAnswer`) |
| 6686 `OwnSink.atoms`, 7283 `supplyAtomsSend` | no atoms | no demand | A, upstream: empty only where a cast lost cells, now closed |
| 6712, 6762–6769, 6790–6795, 6816–6820, 6834, 6845, 6862–6912 | `ownSupply`, `answerOwn` misses | refused, or all | P |
| 6924–6928 `canShare` | field vs list, two fields | false | P §11.1, §11.9 |
| 6938–7038 | `freshOwn`, `paramOwn`, `handsOn`, `passesOn`, `handedBack`, `ownAnswer` | positive facts only | P §6.8, §6.13 |
| 7059–7183 | `answerOfParam`, `answerOf`, `answerOfCode` misses | `lostAnswer` | pess. |
| 7083 | a `v_none` function | no answer | P (a constructor of no cell) |
| 7216, 7230–7239 | `escapeSupplies` top; `draftOf` no type | no escape; arity 0, lost | P |
| 7326–7337, 7346 | `sendSlots` misses; arity | all slots; lost | pess. |
| 7416–7418, 7427, 7435, 7443 | `selfAtoms`, `readSelf` of no place | nothing | P by typing; under a cast now `unknown` |
| 7453–7474 `newItem` | misses | not new (the base answered) | pess. |
| 7504, 7554 | a spread or append base `v_none` | no demand | A, upstream (as 6686), closed |
| 7575–7639 `fnMembers`, `entryCall` | no code, no shape, unnamed field | no fact | P §6.13 |
| 7690–7916 `entryCall` | no model type, layout or entry, budget, no source, `meetsOf` | `bad`, nothing `own` | P §6.13 (a location with no source holds none) |

### 3.5 `Check.zig`, `Contract.zig`, `Loc.zig`, `Enforce.zig` and the `own2` code v3 calls

| Site | Looked up | A miss answers | Class |
|---|---|---|---|
| Contract 174, 193–194 | `normal`, `union2` of an empty set | empty, the other side | P |
| Contract 220–227, 232 | `joinFn` of a null side; other arity | the other side; `lost` | P (one decision of "is a function"), pess. |
| **Contract 240 `join`** | two contracts of different signatures | `b`, dropping `a`'s facts | **A, reached** (a local's bottom contract against its first walk): P for that pair, since the bottom has no fact; a safe-build check refuses any other (§6) |
| Contract 248, 341–351, 372, 402, 425, 432, 435 | `record_copy`; derived fact, published contract or layout missing | `and`; null (unknown code); empty layout | P, pess. |
| Loc 146 | a sparse `downOf` key | empty | P |
| Loc 332–333 | `indexOf` | `none` | P (each caller handles it) |
| **Loc 404–406, 475** | `layoutOf` of a place that holds nothing | the empty layout | **A, reached (faults 1–3)**: a fact of the type, not of a value a cast filled; P after the fix (`narrowed`, `punned`) |
| Loc 413–422, 434, 443, 440 | the layout limit; two places at one location | wide, `over`, `var` | pess. §8 |
| Loc 423, 462, 466, 487–552, 576, 611, 627–630, 730–732, 803, 819, 842, 898, 911–921 | visits, slots, wide stops, levels, steps, holes, `find`, cover's climb | as listed | P (each read pessimistically by its caller) |
| Loc 581, 603, 642–646, 736 | `abstractPath` null; `up` or `to_root` none | `none` | A, latent: no program of the base gives one outside a cut; but in the corpus's polymorphic recursion `to_root` is `none` (§8). Its readers now read all (§5) |
| Loc 776, 782 `within` | a depth or label that differs | false | A, latent → closed: `slotsOf`, its one reader, falls back to every slot where nothing is left |
| **Loc 830 `holes`** | `cover(of, view)[j]` none or `all` | no hole | **A, reached (faults 1–3)**: P after the fix: such a value is `unknown` before it is read |
| **Loc 910 `cover`** | an empty signature | `none` for each entry | **A, reached (fault 1)**: P after `narrowed` |
| Place 111, 592–597; Groups 378, 381, 645 | a type that holds nothing becomes `cross` | no object | P for a typed value; **A in a cast** (faults 1–3), closed by `narrowed`/`punned` |
| Groups 379, 397–404, 466–472, 532–549, 603–608, 628, 648, 665–708 | a var, alias, error, limit, schema endpoint, folded payload | `var` | pess. |
| Place 310–324 | `child` | null | P (callers make it unknown) |
| Check 604–655, 662–748 | places, `fnType`, `isMarkup`, `isView`, `isSender` | `var`, null, false | P, pess. |
| Check 753–915 | `ctorStep`, `holdsAt`, `ctorAt`, `ctorArgStep`, `isRecordAliasCtor`, `recordAliasStep`, `trySuccess`, `calleeOf`, `methodTarget`, `isListAppend`, `spreadOf` | null, false, the whole | P (the caller makes it unknown or a call) |
| Check 946–988 | `entryShape` | null, `unknown` | P §6.13 |
| Check 1008–1093 | `isWorded`, `declContract`, `edgeEffect`, `valueIsFunction` | null, unknown, writes and keeps | P, pess. §6.11 |
| Check 1113–1250 | `termsInfo`, `rowInfo`, `derivedFacts` | `.{}`, writes and keeps | P, pess. |
| Check 1263–1345 | `sigOf`, `bottom`, `bottomFn`, `emptyContract` | null, least start | P §6.9 |
| Check 1359–1445 | `wordedContract`: no signature, no protocol, unworded parameter, `unused`, `written`, `returned`, `fresh` | unknown; escape and every location; every location | P, pess. (rule 10) |
| Check 1461–1462 | `copyof` of a record | every location | pess. |
| **Check 1469–1471 `builderdone`** | a parameter location no result location holds | nowhere | **A, latent → fixed**: every result location, as `returned` |
| Check 1476–1488 | `elementof` not of a list | `undescribed` | pess. |
| **Check 1479 `elementof`** | `up[k] == none` | the source dropped | **A, latent → fixed**: the pessimistic row |
| Check 1492, 1547–1548 | no word; `selfToSelf` | `undescribed`; nothing | P, pess. |
| Check 1517–1522 `intoElems` | `up` is `none` | skipped | A, latent → closed: with nothing found it falls back to every element |
| **Check 1531 `elemsToElems`** | a parameter's self entry that is wide | skipped, with its elements | **A, latent → fixed**: only a storage that is not wide is skipped |
| Check 1556–1590 `wordedFn` | the function type; `taken` | null; the element's place | P |
| **Check 1598–1610 `wordedFn`** | an answer no word puts in the result | no source | **A, latent → fixed**: it escapes (`ans_escapes`) |
| Check 1620, 1633–1746, 1805, 1849, 1870–1908, 2217–2235, 2420–2439 | walks, schema, exports, groups, limits | null, unknown | P §3.3, §8, §6.14 |
| Enforce 131–143, 157–160, 211–214, 247–270; MarkupTree 327–332 | the module's channel, lowering, roots | no line kind, no write, keeps none | P (no write authorised, or the lowering's own answer) |

The counts. A site is **closed** when the change answers it pessimistically, or the rule of the cast
(`narrowed`, `punned`) proves its empty answer; the open ones are in §12.

| Part | Sites | Proved (incl. pessimistic) | Assumed | Reached by a program | Closed | Open |
|---|---:|---:|---:|---:|---:|---:|
| `Frame.zig` 1–1 830 | 47 | 42 | 5 | 4 | 5 | 0 |
| `Frame.zig` 1 830–3 240 | 80 | 74 | 6 | 1 | 4 | 2 |
| `Frame.zig` 3 236–5 390 | 101 | 96 | 5 | 2 | 4 | 1 |
| `Frame.zig` 5 387–7 917 | 138 | 124 | 14 | 6 | 13 | 1 |
| `Check`, `Contract`, `Loc`, `Enforce`, `own2` | 132 | 113 | 19 | 8 | 19 | 0 |
| **total** | **498** | **449** | **49** | **21** | **45** | **4** |

Seven of the 49 were classified proved by the readers: `punned` of `v_none` (found by the sweep of the
first fix), and `project` 2171 and 2200, `capture` 3227, `built` 3771, `punned` of `v_none` at a
type variable and `pairedLeaves` 5925 (the review). Each rested on "a value of a type with no location
holds no cell", which a cast breaks.

In the last part, 7 assumed sites are one class (a type of no cell filled by a cast: `Loc.layoutOf`,
`visit`, `holes`, `cover`, `Groups`, `Place`, and `punned`'s `cross`), all reached; 12 are latent
rows and readers of a missing `up` or `to_root` (`Loc` 581, 603, 642, 736, 776, 782; `Check` 1469,
1479, 1517–1522, 1531, 1598–1610; `Contract.join`, reached once, by the bottom contract). In the fourth,
8 assumed sites read an empty set from upstream of fault 1 (`OwnSink.atoms`, `supplyAtomsSend`,
`selfAtoms`, `spreadChain`, `appendChain`, `entryCall`'s sources, a `v_none` function, a written list
entry of no atom) and are closed by `narrowed` and `punned`, but the last, which stays with `demand`'s.

## 4. The faults

| Fault | Program | Base: plain / sanitised / in place | Sites |
|---|---|---|---|
| 1. a cast to a type of no cell, or of fewer places, loses cells | `run/HostValueNarrowInt` (`hide : List Int → Int`), `run/HostValueNarrowList` (`flat : List (List Int) → List Int`) | `3 2` / TRAP / `3 3` | `applyAt` identity, `leavesSet` 1705, `unknownOf` 1774, `rootVal` 592, `apply` 5489, `Loc.cover` 910, `Loc.layoutOf` 404 |
| 2. a cast to a type with more places reads nothing there | `run/HostValueWidenInt` (`ys : List Int = Pun.conv (keep i)`), `run/HostValueNarrowList` (read back as a list of lists) | `3 2` / TRAP / `3 3` | `punned` 6084 (`cross`), 6101–6103 (slots and constructors' arguments only), `Loc.holes` 830 |
| 3. a number read as a list through `Js.Value` | `run/HostValueFromInt` (`fromInt n = Js.to (Js.from n)` in a platform) | `3 2` / TRAP / `3 3` | `punned` 6081: `v_none` has no place, and the argument's place is `Js.Value`, opaque |
| 4. an operand location the call map cannot place | `run/CycleVarOtherPlace` (`each : T a, (a → a), (a → Int) → a × Int` handed `T xs [ T xs [] ]`) | `2 1` / `2 2` / `2 2` | `otherReaches` 2698–2700 |
| 5. (review) a value of no location read back as a list through a type variable | `run/HostValueVarAnswer` (`unhide : Int → b`), `run/HostValueVarMap` (`Maybe.map t Pun.conv`) | `2 1` / TRAP / `2 2` | `punned`'s `var` exemption for `v_none`; `rootVal` 592 (a parameter of `Maybe Int` held nothing) |
| 6. (review) a callee answers at a list of the caller a value whose type has no cell there | `run/HostValueVarCtor` (`un : W a → W b`, handed `W i 1`), `run/HostValueVarRecord` (`un : { a : Int } → b`) | `2 1` / TRAP / `2 2` | `built` 3771 (`W i 1` at `W Int` was `v_none`), `pairedLeaves` 5925 (a slot fed a list) |
| (sound) an update of a value of no cell made no demand | `run/RecordPunNumberUpdate` | `5` / `5` / `5`, no line | `recordUpdate` 3924 |

Fault 3 was found by the sweep of the first fix: the readers' probe `E/int-cast` still trapped. Faults 5
and 6 were found by the review (§11), on the first fix and on the base alike. Faults 1
to 3 need a platform that casts (only a platform or `core/` may import `Js`), as reports 146 and 147's
did. Fault 4 needs none: any program over a recursive type whose callee reads its cycle with a type
variable. v1 accepts it too; v1 is frozen, so it is one line of `ownership-v2-known.txt`, as is
`HostValueNarrowList`, which v2 accepts.

## 5. The fixes

- **`narrowed`** (kernel §3.4, *A value read at a type with fewer places than its own*): at an identity,
  each location of the value's own layout that no location of the reading covers escapes.
- **`punned`**: any location of the reading that the map leaves uncovered (`none` or `Loc.all`), of any
  kind and at the root too, makes the identity a pun; a `cross` own place is no exemption; a value of no
  cell read at a type with a location is a pun, whatever the argument's type.
- **`otherReaches`**: a `Loc.all` entry of the written operand is another place where another location has
  a flag, unless `valueApart` holds and the entry holds no cell twice.
- **`recordUpdate`**: an update of `v_none` writes `outside`.
- **A value whose type has no location holds `outside`** (`rootVal`, `capture`, `project`, `built`,
  `unknownOf`, `applyAt`'s answer); a literal stays `v_none`. And `pairedLeaves` gives a caller's list
  `outside` where the argument gave no cell, or only a record's slots, and its type has no cell on the path.
- **Latent, pessimistic** (no program reached them on the base, but `leavesOwnWalk`'s, which the corpus
  does): `builtIndex`, `leavesOwnWalk`, `refReaches` read every entry where a part's location has none in
  the whole; `keptHole` keeps a join where an arm is kept; `wordedContract`'s `builderdone`, `elementof`
  and `copyof`, and `wordedFn`'s undescribed answer.

The ten fixtures fail on the base, each by the harness's own test (a stale read, or for
`RecordPunNumberUpdate` a refusal its `.sanitize-lists-v3-refuses` names that the base does not make), and
pass on the fix; `HostValueFromInt` and the four `HostValueVar*` fail on the first fix as well.

**A rule that was tried and dropped.** A list write whose atoms are none could write `outside`, as 147's
slot write does. It closed faults 5 and 6 where the written value held nothing, but not where it was one
arm of a `case` whose other arm is a new list, and it refused a real write: `bench/corpus`'s
`FormValidation.andMap`, whose `left ++ right` writes `Invalid`'s list of a `Valid` construction, a
constructor's argument the value does not have. It newly refused 12 roots in all. The fix is at the
source instead.

## 6. Safe-build checks

`Frame.checkPlaced` (kernel §9) runs at each reader of a value at another reading than its own
(`leavesSet`, and `argEntries` where no entry is hit): every location asked must be placed in the value's
own layout — an entry at it, `Loc.all`, a wide entry above it, or a path the value's own place has that
reaches a type of no cell (`Loc.emptyAlong`); a slot, a row or a deep level's member is read by another
rule. It generalises report 146's `checkEmpty` from `finish` to every reader. Its first version, which
had no `emptyAlong`, panicked on 95 roots; each case was a reading below a place of no cell
(`Result String b` read as `Result a b`, `Maybe Int` as `Maybe (List a)`'s list, a closed record read
through a row), all proved empty by the type, and the final version panics on none of the 2 778 roots.
With `Loc.holes` turned off, report 146's fault, the first corpus program the gates build panics. It
counts no work.

`Contract.join` answers the second contract where the two differ, which drops the first's facts. Two
such pairs exist: a local function's bottom contract against its first walk, and — the sweep found it, 70
`function-values` programs whose local function is called before its binding — a contract of an earlier
walk that found fewer captures. A local function's arity is its parameters and its captures, so a
contract of another arity says nothing the rounds can use, and they walk again to a fixed point at the new
one: no fact is lost. A safe build now panics only where two contracts of one arity have other layouts
and the first has a fact.

## 7. The generator

`bench/ownership-sweeps/build-read.mjs`, 1 050 programs: an item (a list, or a record of numbers) is put in
a container (`rec`, `ctor`, `tup`, `list`) by one of ten makers and taken out by one of the shape's readers,
written in place, and read after (`live`: the item; `kept`: the container) or not (`dead`).

| Run | SAME | REFUSED | TRAP | PLAINFAIL |
|---|---:|---:|---:|---:|
| base, the first 912 (no `viaInt`) | 254 | 658 | 0 | 0 |
| base, `viaInt` (138) | 69 | 9 | 60 | 0 |
| fix, all 1 050 | 248 | 802 | 0 | 0 |

The nine makers of 147's shapes find nothing on the base: reports 146 and 147 closed them. The maker
through an `Int` (a helper `hide : t → Int` and `Js.to` back) traps on 60 `live` and `kept` twins of
the base; on the fix it refuses all 138, the `dead` twins too: a cast through a type of no cell is no
claim (§12).

## 8. Verdicts

`dump --stage=ownership --ownership=v3 --ownership-everywhere` of every ownership root, base against the
fix: 2 768 roots on the base, 2 778 on the fix (the ten fixtures). 84 roots change their dump, 18 their verdict lines. **No root's program goes from accepted
to refused** but `browser/tea/StatefulNested` (`browser-tea`, out of scope): its `update`'s write of
`model.text=` is refused because a `Maybe Html` hole of an `if` is now kept (rule 12). 17 more roots
change lines, each a program the base refused already:

| Root | Lines | Cause |
|---|---:|---|
| `ownership/core/CastCallHolds`, `CastOccurrence` | 5, 2 | a list cast to a list of lists is `unknown` (fault 2); 2 `fresh` twins now refused, 5 refusals change cause |
| `ownership/PolyRecBranch`, `PolyRecCps`, `PolyRecTuples`, `PolyRecTwice`, `run/SanitiserFamilyBase`, `SanitiserFamilyBaseApart`, `SanitiserFamilyDepth`, `SanitiserFamilyDepthCallback`, `SanitiserFoldedType` | 2 to 11 new lines each | `leavesOwnWalk` reads the root where a folded part's location has none: a callee that writes an element of a folded payload now writes its parameter (`PolyRecBranch.ww`: the base said it writes nothing), so its callers get demands; 6 new lines accepted, the rest refused |
| `run/SanitiserFamily`, `SanitiserFamilyApart`, `SanitiserFamilyJoinBelow`, `SanitiserFamilyJoinBelowApart`, `SanitiserRowLevel`, `SanitiserRowLevelApart` | 1 or 2 each | fault 4's rule: a written operand whose deep level the map cannot place, and which is not apart (a summary below a fold is `twice`, report 146), is refused `disjoint` |

The `Apart` twins are safe programs that change lines (the same precision loss on folded types as #2538,
report 146), but each was refused before on another line.

**The real-writes ledger** (`bench/ownership-v2-review.mjs --checkers=v1,v3 --roots=real`): of the 308
list writes v1 judges, v3 accepts **294** and refuses 11 (3 with no line), before and after, and every v3
demand of the 32 real roots has the same count. **No real program is newly refused.**

## 9. Sweeps

`bench/ownership-sweeps/run.mjs --checker=v3 --mode=both --jobs=20`, the self-hosted ReleaseSafe
compiler of the fix, every program of the 28 generators of the folder (`build-read` and the corpus
included), its 13 fault folders, the readers' probes and the review's programs. The `function-values` row
is of the final compiler: on the one before it, 70 of its programs (a local function called before its
binding) stopped at `Contract.join`'s first safe-build check, which was too strict (§6); the final
compiler gives the base's verdicts on all 70.

| Sweep | Programs | SAME | REFUSED | LIMIT | Faults | Other |
|---|---:|---:|---:|---:|---:|---|
| the readers' probes | 29 | 0 | 26 | 0 | 0 | 3 PLAINFAIL |
| the review's programs | 526 | 2 | 451 | 0 | 1 | 1 BOTHFAIL, 71 PLAINFAIL |
| `alias-ctors` | 188 | 79 | 109 | 0 | 0 | — |
| `aliased-arguments` | 5160 | 1216 | 3944 | 0 | 0 | — |
| `answers-beside` | 240 | 79 | 161 | 0 | 0 | — |
| `answers-sends` | 54 | 19 | 35 | 0 | 0 | — |
| `blind-faults` | 24 | 11 | 13 | 0 | 0 | — |
| `blind` | 9792 | 1675 | 8117 | 0 | 0 | — |
| `blind10i-faults` | 16 | 7 | 9 | 0 | 0 | — |
| `blind10i` | 474 | 151 | 209 | 0 | 0 | 114 PLAINFAIL |
| `blind2-faults` | 20 | 7 | 13 | 0 | 0 | — |
| `blind2` | 1202 | 502 | 700 | 0 | 0 | — |
| `blind3-faults` | 10 | 3 | 7 | 0 | 0 | — |
| `blind3` | 417 | 160 | 257 | 0 | 0 | — |
| `blind4a-faults` | 12 | 1 | 11 | 0 | 0 | — |
| `blind4a` | 160 | 24 | 136 | 0 | 0 | — |
| `blind4b-faults` | 8 | 4 | 3 | 1 | 0 | — |
| `blind4b` | 6596 | 1188 | 5406 | 2 | 0 | — |
| `blind5c-faults` | 10 | 5 | 5 | 0 | 0 | — |
| `blind5c` | 226 | 77 | 147 | 2 | 0 | — |
| `blind5d-faults` | 10 | 5 | 5 | 0 | 0 | — |
| `blind5d` | 1234 | 450 | 784 | 0 | 0 | — |
| `blind6e-faults` | 12 | 4 | 8 | 0 | 0 | — |
| `blind6e` | 238 | 91 | 140 | 0 | 0 | 7 PLAINFAIL |
| `blind7f-faults` | 2 | 0 | 0 | 0 | 0 | 2 TIMEOUT |
| `blind7f` | 960 | 396 | 564 | 0 | 0 | — |
| `blind8g-faults` | 8 | 4 | 3 | 1 | 0 | — |
| `blind8g` | 121 | 21 | 99 | 1 | 0 | — |
| `blind9h` | 3213 | 849 | 2364 | 0 | 0 | — |
| `bounded-walk-faults` | 12 | 2 | 4 | 2 | 0 | 4 TIMEOUT |
| `bounded-walk` | 34 | 5 | 7 | 4 | 0 | 18 TIMEOUT |
| `build-read` | 1050 | 248 | 802 | 0 | 0 | — |
| `callbacks-keep` | 720 | 108 | 612 | 0 | 0 | — |
| `corpus` | 1694 | 1191 | 483 | 1 | 3 | 12 BOTHFAIL, 1 TIMEOUT, 3 PLAINFAIL |
| `evaluation-order` | 440 | 276 | 164 | 0 | 0 | — |
| `folds-callbacks` | 30300 | 5152 | 25148 | 0 | 0 | — |
| `function-values` | 1960 | 302 | 1658 | 0 | 0 | — |
| `handed-back` | 2592 | 0 | 2592 | 0 | 0 | — |
| `host-values` | 81 | 13 | 68 | 0 | 0 | — |
| `records` | 1876 | 353 | 1523 | 0 | 0 | — |
| `recursive-levels` | 16131 | 4034 | 12097 | 0 | 0 | — |
| `runtime-calls-faults` | 8 | 2 | 5 | 1 | 0 | — |
| `wider-functions` | 354 | 144 | 210 | 0 | 0 | — |
| **total** | **88214** | **18860** | **69099** | **15** | **4** | 198 PLAINFAIL, 13 BOTHFAIL, 25 TIMEOUT |

- **Faults**: the corpus's three `TRAP`s are the known ones of reports 144 to 147
  (`run/ListSanitiserTrieHolder` traps as its golden says; `dom/ShowAndBranches` and `tea/ShowAndBranches`
  are #2504, out of scope); the review's one is a constructor read from a record through `Js.to`, which
  matches no arm in the plain build too (#1997).
- **Verdicts against the base's sweeps** (report 147's results, program by program): **none goes from
  `REFUSED` to `SAME`**. Six go from `SAME` to `REFUSED`, each a `dead` twin or a safe program:
  `function-values`' `viafold.call2.keep.dead` and `viafold.call2.push.dead` (an `Int` handed to a
  fold now holds `outside`, which the fold's answer, a summary of what it was handed, puts at the
  accumulator's list: the cost of §5's rule for values of no location), `blind5c`'s
  `row.showlit.dom.dead` and `row.showlit.tea.dead`, and the corpus's `dom/StatefulNested` and
  `tea/StatefulNested` (a `join` of markup values in a hole is kept, rule 12; `dom` and `browser-tea`,
  out of scope).

## 10. Speed

`bench/ownership-v2-review.mjs --checkers=v3 --runs=1 --jobs=1 --roots=real` on ReleaseFast LLVM compilers of
the base and of the fix, five rounds alternated, the least of each root kept (load average 4 to 15).

| Measure | Base | Fix | Change |
|---|---:|---:|---:|
| v3 on the 32 real roots | 1 251.2 ms | 1 276.3 ms | +2.0 % |
| the same without `platforms/browser` | 792.0 ms | 815.9 ms | +3.0 % |
| the largest rise, `examples/conduit` | 117.8 ms | 120.3 ms | +2.5 ms |
| demands, accepted, refused of each root | | the same | — |

The work the fix adds is counted (kernel §8): `narrowed` and `punned` a scan of a map at each cast,
`emptyAlongLabels` a scan of a path where an argument gives no cell, and `otherReaches`' `valueApart`
once for each written operand that has a location the map cannot place. A first measurement under a load
of 21 gave −11 %, which was noise.

## 11. The review

One fresh adversarial reader (Opus), given the code and the commit but not this report's table, wrote
about 330 programs (526 directories with its controls and generated families): casts of a list to 25 types
directly, through helpers, in lists and tuples, through `Js`'s objects, arrays, references, globals and
methods; aliasing without casts over closures, record alias constructors, patterns, rows, `Record.copy`,
`List.copy`, spreads and about 30 functions of `List`, `Maybe` and `Dict`; records in place; cycles and
polymorphic recursion; closures read or written after a push; an unknown operand that holds one list twice.

- **Found, fixed: fault 5**, a value of no cell answered at a type variable (`unhide : Int → b`, and 24
  more of its programs over `String`, `⊤`, `Maybe Int`, tuples, records, `Dict`, a function value, `Js.pure`
  and `Maybe.map`). **Found, fixed: fault 6**, a callee of `W a → W b` or `{ a : Int } → b` handed a
  value whose type has no cell where its answer has a list (4 programs). Both were there on the base too.
  The commit's first answer (a list write of no cell writes `outside`) was dropped (§5).
- **Not ours**: a constructor read from a record or a tuple through `Js.to` matches no arm, so the `case`
  answers `undefined` in the plain build as well (`case w of W x y → …`, `review/cb2`, `g4/ctorBack`).
  That is the open owner's decision #1997 (a `case` has no default arm, and `Js.to` is not checked).
- **Held**: every other program; no safe-build panic.

On the final fix the reader's programs are 451 `REFUSED`, 2 `SAME`, 71 that do not build and the one
`case` above; on the first fix, 47 `TRAP`.

## 12. What stays open

- **A list write of no cell** (`demand` 2751–2758, `applyAt` 5467): accepted. A list value holds its
  array, so an empty W comes only from a cast, which is `unknown` now, or from another constructor's
  argument in an arm that does not run (`case Nothing of Just l → List.push l 1`), where `outside` would
  refuse a dead arm. Kept, with that argument.
- **Ten `else` arms on `Bir.Inst.Tag`** (`bindPattern`, `readsList` and eight more in `Frame.zig`): no
  tag they take binds a local, reads a list or names code today, but they break §3.3's rule of no `else`;
  §3.3 now says so, and #2541 asks for them to go.
- **#2540** (report 147): a cast of a value of a recursive type read at a slot of the deep level.
- **Precision**: a cast through a type of no cell, or a widening cast, is no claim, so its `dead` twins are
  refused (`build-read`'s `viaInt`, `CastCallHolds`' `fresh` twins); and fault 4's rule refuses a write
  through a folded type whose summary is `twice` where the program is safe (#2538).

## 13. Reproduce

```sh
node bench/ownership-sweeps/build-read.mjs <dir>/build-read
node bench/ownership-sweeps/run.mjs --beni=zig-out/safe/bin/beni --checker=v3 --mode=both --jobs=20 --tmp=<disk> <dir>/build-read
TMPDIR=<disk> node bench/ownership-v2-review.mjs --beni=zig-out/safe/bin/beni --checkers=v1,v3 --runs=1 --roots=real
zig build test-blackbox-corpus -Dcorpus=HostValue     # and CycleVarOtherPlace, RecordPunNumberUpdate
```
