# 156 — Ownership v3: "once" needs a run

*Research report, 2026-11-18. A blind round (#2557) found that the checker v3 (`--ownership=v3`, `src/own3/`)
read a worded row's result as holding each cell once. This report fixes it at its root, audits the other
sources of a "once" fact, and parks the readings it rests on as an owner decision (#2558). It revises the
kernel (`ownership-v3-kernel.md`) §4.2, §4.4, §6 rule 10 and §9.*

---

## 1. Result

- **The fault.** `pub foreign pure dupW : stored a → fresh List a`, JavaScript `(a) => [a, a]`. The words
  are true of the code, and say no count. `gg list = case list of [ b, …rest ] → …` wrote `b` in place while
  `rest` held the same record (`TRAP`, in place `99 99` against `99 1`).
- **The root.** `Check.wordedContract` builds a row's contract with no `Src.twice`. A walked body's `twice`
  comes from `Frame.finish`, which reads the runs its walk built (`partDup`, kernel §4.4); a row is not
  walked, so nothing derived "once", and its absence was read as "once". Every caller then took the row's
  result as `linear` (`argsApart` holds, the claim `!nonlinear` is read), so a list pattern's parts were
  apart (report 154).
- **Two sites of the one mistake** (§3): a summary location of a row's result (the blind round's fault);
  and, found by the review, two single locations of a `fresh` row's result, each a site of its own, so
  `fresh R × R` answering `{a: r, b: r}` was two cells.
- **Fixtures**: `run/WordedStoredTwice`, `run/WordedFreshShared` (`TRAP` on the base, refused), and the safe
  twin `run/WordedPositionsApart` (the rows of `core/`, accepted and `SAME`). Each refusal fixture was
  proven by reverting its fix in the worktree.
- **Verdicts**: of the 2 856 ownership roots, **no verdict line changes** (only `summary` lines gain
  `twice`). The real-writes ledger is **294 of 308** before and after, row for row; v3-only refusals 18.
- **Sweeps**: 90 175 programs under the four legs, the three known faults only (§5). The blind round's 46:
  the 30 of `dupW`/`tripW` refused; the 16 of `againW` (`copyof` answering `l.concat([l[0]])`) still `TRAP`
  — a false `copyof` row under the reading this fix keeps (§4, #2558).
- **Time**: v3 on the real roots 1 284.0 → 1 288.3 ms (+0.3 %, noise).

## 2. The rule

Kernel §4.4, *A worded row builds no run*: each summary location of a row's result that holds a cell is
`twice`, unless a word states the positions of what it puts there (`Check.statesPositions`). Rule 10: a
`fresh` row's locations are one site, `0`; `fresh exclusive` and a cell's handle keep one site each. Safe
builds read the words again, word by word (`Check.checkWordedTwice`, §9): with the `twice` turned off, or
the sites split, the first program the gates build panics.

## 3. Where "once" was assumed with no run

| Source | Before | Now |
|---|---|---|
| a row's summary location (`stored` into a new list, `fresh` elements, `elementof`, `taken`, `aliased`, no word, `Record.copy`, a placement below another place) | read as once | `twice` |
| two single locations of a `fresh` row's result | a site each: two cells | one site |
| a page's model made by such a row in `init` | `update`'s pattern parts apart | refused (`unknown`) |
| a walked body, a literal, `partDup` | derived from runs | unchanged |
| `Js` casts (`Js.array`, `Js.object`, `Js.to` of a row's `fresh Js.Value`), a `fresh a` read as a list, `elementof a` read as a list of lists | refused (§3.4: a summary below a wide entry is no single place) | unchanged |
| a cell's contents (`lent`, `cellread`), `Task`/`Deferred` rows | pessimistic row | `twice` too |
| another module, a generic wrapper, a callback (`List.map`), a record field, a nested list, `Dict.values` | the callee's `twice` read at the call | carries the row's `twice` |

## 4. What the fix reads, and what it leaves

`twice` on every placement costs real code (measured, #2558): `put`, `push`, `done` and `cons` are the
JavaScript leaves of every loop of `core/List`, and `twice` there reaches `List.map`, `indexedMap` and
`filter`: the ledger loses `Tea 516` and 13 TodoMVC, `bench/ui` and `jfb` lines become v3-only refusals.
`twice` on `copyof` and `concatenated` refuses report 154's safe wins (`KeyedInPlace`, `KeyedInPlaceMap`,
`RecordContentsRows`, `RecordSortWith`, `ViewSplitStoredBack`). So the words whose definitions name
positions are read so: `returned`, `builderdone`, `prepended`'s list and the elements of `copyof` and
`concatenated` at the same place; `stored` beside a `written returned` parameter, and `prepended`'s item,
as one store; `exclusive`. The bisection: every word `twice` (ledger 293, +13 refusals); exempt rows with
`returned`, `builderdone`, `prepended` (294, the 46 refused); per source, `copyof` and `concatenated`
`twice` (294, nine corpus roots lose 12 lines of safe writes); per source with them positional (294, no line moves).

A row true under the "may" reading that breaks these positions traps (the review's table, #2558:
`l.push(x, x)`, `a.concat(b, b)`, `[...l, l[0]]`, `[x, x, ...l]`, `l.concat([l[0]])`, `fresh exclusive`
`[r, r]`). No row of `core/` or a shipped platform has such code. The owner decides whether these are false
rows (the current reading) or core gets a word for the count.

## 5. Sweeps

`run.mjs --checker=v3 --mode=both`, the ReleaseSafe compiler of the last commit; every generator of the
folder, its fault folders, `harvest-v2-records`, the corpus and the new `worded-twice.mjs` (1 304 programs:
rows × carriers × list patterns × writes, the pair rows, the core twins, the pages; 84 `TRAP` on the base).

| Sweep | Programs | SAME | REFUSED | Faults | Other |
|---|---:|---:|---:|---:|---|
| `corpus` | 1 781 | 1 245 | 515 | 3 | 12 BOTHFAIL, 4 PLAINFAIL, 1 LIMIT, 1 TIMEOUT |
| `folds-callbacks` | 30 300 | 5 669 | 24 631 | 0 | |
| `recursive-levels` | 16 131 | 3 869 | 12 262 | 0 | |
| `blind` | 9 792 | 1 675 | 8 117 | 0 | |
| `blind4b` | 6 596 | 1 270 | 5 324 | 0 | 2 LIMIT |
| `aliased-arguments` | 5 160 | 1 270 | 3 890 | 0 | |
| `worded-twice` | 1 304 | 510 | 794 | 0 | |
| 41 other sweeps and fault folders | 19 111 | 4 688 | 14 262 | 0 | 123 PLAINFAIL, 14 LIMIT, 24 TIMEOUT (`bounded-walk`, `blind7f-faults`: as on the base) |
| **all** | **90 175** | 20 196 | 69 795 | **3** | |

The three faults are the known `run/ListSanitiserTrieHolder` and `dom`/`tea` `ShowAndBranches` (#2504).

## 6. Review

One fresh adversarial reader (Opus), 506 programs. One fault family, fixed: a `fresh` row's single
locations (§3; `run/WordedFreshShared`, the sweep's `pair.*`). The residual table of §4, parked (#2558).
Refused or `SAME`: core self-aliasing (`push`, `set`, `insertAt`, `cons`, spreads, `++`, `repeat`, `map`,
folds, `update`, `copy`, `sortWith`), `Js.pure`, `Js.finally`, `Js.array`, `Js.object`, `Js.ref`, casts,
`Debug.log`, `Dict.values`, `Maybe.withDefault`, pages.

## 7. Reproduce

```sh
node bench/ownership-sweeps/worded-twice.mjs <dir>/wt
node bench/ownership-sweeps/run.mjs --beni=zig-out/safe/bin/beni --checker=v3 --mode=both --jobs=20 --tmp=<disk> <dir>/wt
TMPDIR=<disk> node bench/ownership-v2-review.mjs --beni=zig-out/safe/bin/beni --checkers=v1,v3 --runs=1 --roots=real
zig build test-blackbox-corpus -Dcorpus=Worded
```
