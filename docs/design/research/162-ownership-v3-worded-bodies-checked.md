# 162 — Worded beni bodies checked against their walk

*Research report, 2026-11-19. #2573, from blind round AL: a platform declaration with a beni
body and no JavaScript, worded `borrowed shallow`, read a value's contents; v3 trusted the words,
and a caller that wrote the value in place trapped. Kernel §6 rule 10, *A worded body is checked
against its walk*, §7 and §9 hold the rule. Hardening only: it adds no acceptance.*

---

## 1. Result

- A worded declaration whose body **reaches no JavaScript** is checked against its own walk:
  the walk's contract must be below the words' contract (`Check.falseWord`). Where it is not,
  the build refuses `false_ownership_word` at the declaration's name, in every package and every
  build where v3's lines are enforced. The repro (`peekBody`) is refused; its true twin
  (`sizeBody`, `Dict.size`) is accepted and written in place.
- **No row of `core/` or of a shipped platform is refused.** All 44 shipped worded bodies that
  v3 walks reach JavaScript at a cell, and are not checked (§3).
- **Verdicts of the 2 896 ownership roots: 0 changes** (§5). **Ledger: 309 of 319**, row for row.
- **Sweeps, four legs, 96 838 programs: no new fault** (§6).
- One fresh adversarial review: four lying bodies found that passed, all four now refused (§7).

## 2. The rule

The comparison reads a contract as its callers read it (`Contract.zig`):

- a parameter location's flags: read (`unused`, `shallow` below the storage), written,
  escaped, answered;
- each source of each result location: a parameter location at its position or none, a
  function's answer, `outside` (not covered by `fresh`), a cell the body made (covered by
  `outside`, a new cell of the words, or, where unescaped, a parameter location or an answer),
  one new cell at two locations (`exclusive`);
- `nonlinear` (by a parameter's cell at two locations), `casts`, `old_result`;
- each function parameter: what it is handed, `free`, `called`, `lost`, `ans_escapes`,
  `rewrites`.

So every word whose meaning a contract carries is covered by one comparison: `shallow`,
`unused`, `borrowed` (writes, keeps), `escaped`, `fresh` (a parameter, a top-level value, an
escaped cell), `exclusive`, `position`, `once`/`many` (a kept function), and every placement word
(`returned`, `stored`, `elementof`, …), which must name each source the walk found.

**Reaches JavaScript** (`Check.reachesJs`): an edge of the body (`Edges.declEdgesAt`) to core's
`Js`, a wordless `foreign`, a markup primitive or a missing name **read at a type that holds a
cell** (`touchesCells`; `List`'s bounds test `Js.shiftRightZero` on `Int`s sees none, so
`List.get` and `head` do not reach); another module's derived row with no fact, or a codec; a
worded row that hands a parameter to code no walk sees (`handsUnseen`) or casts; a wordless
declaration with no contract, one that casts, or one whose body reaches, in any module
(`Published.js`, computed for core and platform modules only). It runs after every budget and
counts no work.

**Not judged**, each written in the kernel: a count of handed cells (`twice` where the walk has
only parameter locations, answers or `outside`: no walk derives a permutation's count, #2575),
`taken`'s `free`, `entry`, `Record.copy`'s `copyof`, a point-free declaration's other layouts.
A walk that gave up is **refused** (its words cannot be checked).

## 3. Shipped rows

The first definition (own code only) refused three shipped rows; each was the walk, not the row:

| Row | What the walk found | Why the row is right | Now |
|---|---|---|---|
| `Schema.print` | an escaped new cell in `#Err.0` | `printWith`'s `Options` has no word, so it is put everywhere; the result is new | reaches (`handsUnseen`) |
| `Schema.printWith` | parameter 1 escapes | `boxOf s = cast s`, a walk of a cast | reaches (a callee casts) |
| `List.swap` | `twice` at `[*]` | two `set`s: the walk cannot see that `y` left position `j` | in scope; count not judged |
| `List.sortWith` | `twice` at `[*]` | a merge | count not judged |

## 4. Fixtures

- `run/WordedBodyFalse` (`.sanitize-lists-v3-refuses`): seven false rows — `shallow` read,
  `fresh` on the parameter, a closure holding it, `many` kept in a `Ref`, a derived compare,
  a walk that gives up, `exclusive` over `[ t, t ]`. With the check turned off the case fails
  (v3 accepts, the sanitised run traps). A `check/` fixture cannot carry v3's flags, so the
  refusal is pinned in `run/` as the other v3 refusals are.
- `run/WordedBodyTrue` (`.sanitize-lists-v3`): the true twin, its writes accepted in place.

## 5. Verdicts and ledger

`dump --stage=ownership --ownership=v3 --ownership-everywhere` of every root, base
(`e92675d57e`) against the lane on the lane's sources: 2 896 roots, **byte-identical**. Before the
rebase, against `f28c5169be`: 2 888 roots, 0 verdict changes. Ledger
(`ownership-v2-review.mjs --checkers=v1,v3 --roots=real`): 319 v1 writes, v3 accepts 309,
refuses 10, no line 0; 27 v3 refusals with no v1 line — the same before and after.

## 6. Sweeps

`run.mjs --checker=v3 --mode=both` on every generator of `bench/ownership-sweeps/` and the corpus
(96 838 programs, lane compiler before the rebase):

| Verdict | Programs |
|---|---:|
| SAME | 20 806 |
| REFUSED | 74 820 |
| PLAINFAIL / BOTHFAIL / LIMIT | 1 728 / 12 / 10 |
| TIMEOUT | 19 (18 `bounded-walk` plain runs under a load of ~15; `run/TailModConsMerge`) |
| TRAP | 4: the known `run/ListSanitiserTrieHolder`, `dom`/`tea` `ShowAndBranches`, and `worded-bodies` `twice.unjudged-stored.live` (#2575, by design) |

`worded-bodies.mjs` (92 programs): 40 `lie` refused `false_ownership_word`, 0 `honest`
refused so (27 SAME, the rest refused by the program's own writes), 2 `unproven` refused
(`shallow` over `List.length`, whose words say `borrowed`), 1 `unjudged` trap.

## 7. Review

One fresh Opus reader, told to find a lying body that passes or a true one refused. Findings,
each fixed and pinned in `WordedBodyFalse`:

1. A derived compare on cell-free values (`( 1, 2 ) == ( 2, 1 )`) marked the body as reaching:
   this module's derived rows are now read through the methods they call.
2. A walk that gave up was not checked, silently: now refused.
3. `exclusive` over `[ t, t ]`: counts were not judged at all; now judged where the body made
   the cell.
4. (second pass) A made cell pushed twice beside handed cells hid behind them: a count is now
   judged wherever a made cell is at the place.

Held: user `eq` that reads cells (same and other module), cross-module helpers, escapes through
`Ref`, `Dict`, `Just`, records, `case`, closures; every shipped module checked with no refusal;
application dumps identical.

## 8. Reproduce

```sh
node bench/ownership-sweeps/worded-bodies.mjs <dir>/wb
node bench/ownership-sweeps/run.mjs --beni=zig-out/safe/bin/beni --checker=v3 --mode=both --jobs=16 --tmp=<disk> <dir>/wb
```
