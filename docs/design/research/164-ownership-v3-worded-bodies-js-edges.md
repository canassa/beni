# 164 — Worded bodies: JavaScript edges that see nothing, and aliases

*Research report, 2026-11-20. #2577, from blind round AO: two holes in research report 162's
check of worded beni bodies (`false_ownership_word`). Kernel §6 rule 10 (*An edge counts only
where what it can see reaches the contract*, *What it does not judge*, *A declaration with no
parameter whose body is a function*), §7, §9 and §12 hold the rule. Hardening only: it adds no
acceptance.*

---

## 1. Result

- **A call of JavaScript that sees no cell of the contract no longer turns the check off.**
  `peek d = if round 1.5 == 2 then …Dict.get d 1… else 0` under `borrowed shallow` is refused,
  and so are the same lies beside `toFloat`, `//`, `String.fromInt`, `++` on text,
  `String.length`, `Debug.toString`, `Js.same [ 1 ] [ 1 ]`, `Js.isNull (Js.from "x")`, an
  interpolation, and a helper of no words that calls `Js.same` on new lists, in the module or
  another.
- **An alias is compared with the contract of the function it names** (`same = keep`,
  `peek = Help.inner`, through wordless aliases, a record maker). An alias of a function at a type
  variable, or of a function with no contract, is refused, with the fix (write it with its
  parameters); so is any other function value with no parameter (`if`, `let`, `case`, a field, a
  call's answer).
- **No shipped row is refused.** One shipped row met the check and was read as the walk's
  imprecision, not a false row (`List.sortWith`, §3).
- **Verdicts of the 2 896 ownership roots: byte-identical. Ledger: 309 of 319**, row for row.
- Sweeps, four legs: §6. Two adversarial reviews: §7.

## 2. The rule

The walk keeps each call and method call with what it was handed and answered
(`Frame.noteJsSite`). When a frame finishes, each is judged by the walk's own values, with no
step (`judgeJsSites`, `siteHolds`, `rootHolds`: nodes, roots and their runs, never `leaves` or
`reach`, which count work): it **counts** where a value handed to it can hold a location of a
parameter, a capture or a function parameter's answer; where a root it was handed or answered is
one the frame's answer holds; or where it made the frame cast. `Check.reachesJs` skips an edge at
an instruction that finished walks applied and none counted; any other edge counts only where
the type it is read at holds a cell (`touchesCells`, now for every kind of callee); a row of the
reference table is read at the instruction that holds its name. A frame that never finished
leaves its calls unseen, so they count.

An alias (`Check.aliasOf`, `aliasWord`) is compared with the target's contract by the same
*below*; layouts are compared by entries (`sameLayouts`), since a contract read from another
module has its own layout numbers. A walk of other layouts than the words', which was "not
compared", is refused.

## 3. The shipped row: `List.sortWith`

Base: `sortWith` reached JavaScript through `slice`'s two calls of `clampIndex` (two `Int`s, a
body over `Basics`' JavaScript): the propagation had no cell test. Now `sortWith` is checked, and
its walk answers a new cell at `[*]` beside a count it cannot derive (#2575), and hands it to
`cmp`. The cell is the walk's reading of empty constructions: `slice`'s `[]` and `merge`'s
`builder (hi - lo)` (`fresh exclusive Builder a`, an array of holes). The row is right.

The narrowing, **in a module of core only** (`Check.phantomAt`): a new cell at a type variable
where the walk does not cast is none, at the result's count and handed to a function parameter.
Core's rows that name one there make none (`List.builder`, `Dict.keyIndex`, `Dict.empty`,
`Record.copy`, `Task.raceOk`, `Task.timeout`, and `Js`'s primitives); a safe build stops at any
other (`Check.checkCorePhantoms`, kernel §9). A platform's body is judged in full: the first
review showed that a platform row `foreign pure make : ⊤ → fresh a` (JavaScript `[1]`) makes a
real one. The real fix (a word for "new storage, no cell below", a reading of `[]`'s element
location as none) changes contracts and is the owner's decision: **#2578**. *This scoping is a
judgment the manager may veto.*

## 4. Fixtures

A `check/` fixture cannot carry v3's flags, so both are in `run/`, as report 162's are:

- `run/WordedBodyFalse` (`.sanitize-lists-v3-refuses`): 19 refused rows; base refuses 9 of
  them. New: `peekRound`, `sameRound`, `peekText`, `peekSame`, `aliasSame`, `aliasPeek` (another
  module), `aliasWrap` (a record), `aliasAny` (a type variable), `ifSame`, `fieldSame`; and the
  two review shapes `dupeMade`, `giveMade` (refused by base too), which pin the core-only scope.
- `run/WordedBodyTrue` (`.sanitize-lists-v3`): `sizeRound`, `copiedText`, `sizeSame`,
  `aliasSize` (another module), `aliasWrap`, with writes accepted in place beside them
  (`32:10`, `37:9` in the dump).

## 5. Verdicts and ledger

`dump --stage=ownership --ownership=v3 --ownership-everywhere` of all 2 896 roots, base
(`709c45e095`) and lane, on the lane's sources: **identical**. A platform's `false_ownership_word`
is a build's refusal, not a dump line: the build changes are `WordedBodyFalse`'s ten new rows.
Ledger (`ownership-v2-review.mjs --checkers=v1,v3 --roots=real`): 319 v1 writes, v3 accepts
**309**, refuses 10; 27 v3 refusals with no v1 line — line for line the same as base.

## 6. Sweeps

`worded-js-edges.mjs` (new, 147 programs), lane against base:

| Kind | Lane | Base |
|---|---|---|
| `lie` (72) | all REFUSED `false_ownership_word` | 12 refused (`plain` guards, `madeVar`, `madeGive`); 30 live TRAP, 30 dead SAME |
| `honest` (68) | 67 SAME, 1 REFUSED by the program's own write (`later-use`) | the same |
| `unproven` (6) | REFUSED `false_ownership_word` | 5 SAME, 1 `later-use` |
| `trusted` (1) | SAME | SAME |

All 42 sweeps of `bench/ownership-sweeps/` and the corpus, `run.mjs --checker=v3 --mode=both`,
the lane's ReleaseSafe compiler, 98 812 programs:

| Verdict | Programs |
|---|---:|
| SAME | 21 264 |
| REFUSED | 75 775 |
| PLAINFAIL / BOTHFAIL / LIMIT | 1 728 / 12 / 10 |
| TIMEOUT | 19 (18 `bounded-walk` plain runs, `run/TailModConsMerge`), as in report 162 |
| TRAP | 4: the known `run/ListSanitiserTrieHolder`, `dom`/`tea` `ShowAndBranches`, and `worded-bodies` `twice.unjudged-stored.live` (#2575, by design) |

Two `worded-twice` programs (`row.mkG.local.{head,last}.npush.dead`) are SAME in three legs and
fail in the plain `--release` run, with base too: `--release` renames a field of a record a
`foreign` row answers (#2579).

## 7. Review

Two fresh adversarial readers (Opus).

1. The first scoping of §3 read a new cell at a type variable as none in every module, and a
   platform row `make : ⊤ → fresh a` passed two lies base refused (`dupe ⊤ = x = make ⊤; [ x, x
   ]` under `exclusive`; `give g = x = make ⊤; g x; x` under `once`). Now scoped to core, with
   the safe-build list; both pinned in `WordedBodyFalse`.
2. A function value of no parameter that is no name, lambda or partial (`if True then keep else
   keep`, `let`, `case`, `table.f`, `choose 1`) was never compared, in base and lane: now
   refused (`ifSame`, `fieldSame`).

Held: the reading cannot add an acceptance (it only moves a body from trusted to checked); no step
or limit depends on it; aliases through wordless names, worded aliases, foreign targets, targets
that reach JavaScript and cycles; `--library` builds of every module of `node`, `browser`,
`browser-inline`, `browser-tea` and `cloudflare` refuse nothing.

## 8. Reproduce

```sh
node bench/ownership-sweeps/worded-js-edges.mjs <dir>/wj
node bench/ownership-sweeps/run.mjs --beni=zig-out/safe/bin/beni --checker=v3 --mode=both --jobs=16 --tmp=<disk> <dir>/wj
TMPDIR=<disk> node bench/ownership-v2-review.mjs --beni=zig-out/safe/bin/beni --checkers=v1,v3 --runs=1 --roots=real
```
