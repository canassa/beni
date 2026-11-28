# 157 — Ownership v3: one reading of stated positions

*Research report, 2026-11-18. A blind round found that the safe-build check `Check.checkWordedTwice` of the
checker v3 (`--ownership=v3`, `src/own3/`) panicked on a row the word validator accepts (#2559). This report
fixes it by giving the marker and the check one reading of the words, decides that reading by the words'
definitions, and closes two holes of the same reading that the base accepted. It revises the kernel
(`ownership-v3-kernel.md`) §4.4, §6 rule 10 and §9.*

---

## 1. Result

- **The fault.** `pub foreign pure into : written returned { items : List a }, stored a → { items : List a }`
  made every `--ownership=v3` build of its platform panic, called or not: `a summary location of a row's
  result holds a source that no word puts at stated positions, and is not twice`.
- **The root.** Report 156 read the words twice. The marker (`wordedContract`'s loop, `statesPositions`)
  took `stored` beside any `written returned` parameter as one store at **any** location of the result; the
  check (`checkWordedTwice`) took it at **element** locations only. Where the result has no `[*]` at its
  root, `intoElems` puts the stored value at every location of the result, and the two disagreed.
- **The answer, by the definitions.** `stored` is "a value retained at the result's `[*]`" and `written` is a
  write of the parameter's own storage at `ε` (`ownership-v2.md` §2.13.6). "One write at one position of
  that list" (§4.4) names a position only where the row writes one list and answers it: exactly one other
  parameter is `written returned`, it and the result have an element step at their roots, and the stored
  value is of their element type. Otherwise the words name no position, and the location is `twice`.
  `into` writes the record's own storage; no word says the item goes into `items`, or how many times.
- **One function.** `statesPositions` (with `oneStore`) is the one reading; the marker and the check both
  call it. The check now verifies the marking loop, `Contract.normal`'s output and the sites, not a second
  reading.
- **Sites found** (all in `src/own3/Check.zig`):
  1. `statesPositions` `.param`: `stored` beside a `written returned` parameter, at any result location
     (the panic, #2559; 178 of 27 195 fuzzed rows on the base).
  2. `statesPositions` `.answer`: the same for a stored callback's answer.
  3. `inPlace`: any `written returned` parameter counted, a record, an `Int` or a type variable included,
     and two of them. `stored a, written returned Int → List a` answering `[v, v]` was read as once: no
     panic, a **stale read** (`run/WordedStoredScalarDest`: in place `99 99`, plain `99 1`).
  4. `intoElems` (found by the review): a stored value that is no element (`stored List Int` beside a
     `List (List (List Int))`, a stored callback, `prepended`'s item) was put at the element by its label
     path, where the row puts it below the element, inside a list no word names: `l.push([a, a])` wrote in
     place while the other copy was read (`run/WordedStoredBelowElement`: `2 2` against `2 1`). It is now
     at every element location, and `twice` there.
- **Fixtures**: `run/WordedStoredRecordDest` (the panic), `run/WordedStoredScalarDest` and
  `run/WordedStoredBelowElement` (stale reads), each refused now; each fails with the base's `Check.zig`
  put back in the worktree.
- **Verdicts**: of the 2 862 ownership roots, only the three new fixtures change. **No other line of any
  dump changes**, `core/` and every platform included.
- **Ledger**: 294 of 308 before and after, row for row; v3-only refusals 18.
- **Sweeps**: 90 226 programs under the four legs, the three known faults only (§3).

## 2. The fuzzer

`bench/ownership-sweeps/row-words.mjs` writes random row signatures (word × type, 1 to 3 parameters,
function parameters, a third of them a `written returned` parameter beside a `stored` one), 60 rows to a
platform, a program calling each, and builds under v3; a row the validator or the type check refuses is
dropped and the batch built again, and a crashing batch is split down to its row.

| Binary | Seed | Rows that reached the checker | Crashes |
|---|---:|---:|---:|
| base `88751de392` | 1 | 27 017 | 178, all `checkWordedTwice` |
| fix | 1, 2, 3 | 27 001, 27 008, 27 021 | 0 |

The blind round's four `g6panic` programs: 134 on the base, 0 on the fix.

## 3. Sweeps

`run.mjs --checker=v3 --mode=both`, the ReleaseSafe compiler of the fix, every generator of the folder
(the new `worded-stored-dest.mjs` included: record, `Int` and below-element rows, once and twice, live and
dead, three carriers), the fault folders, `harvest-v2-records` and the corpus.

| Sweep | Programs | SAME | REFUSED | Faults |
|---|---:|---:|---:|---:|
| `corpus` | 1 784 | 1 245 | 518 | 3 |
| `worded-stored-dest` | 48 | 6 | 42 | 0 |
| 48 others | 88 394 | 18 951 | 69 280 | 0 |
| **all** | **90 226** | 20 202 | 69 840 | **3** |

The three are the known `run/ListSanitiserTrieHolder` and `dom`/`tea` `ShowAndBranches`. On the base every
program of `worded-stored-dest` is a `CRASH` (its platform has a record row). Its 42 refusals are platform
rows only; the `…1` rows, which put the value once, are refused too: their words state no count.

## 4. Review

One fresh adversarial reader (Opus). No other row where the marker and the check differ, and no panic over
its own sweeps (1 200 random rows; every `written returned T₁, stored T₂ → T₃` and stored-callback
combination of 11 types). One hole, fixed: site 4 above. Refused as they should be: two `stored` arguments of
one value, a stored value already in the destination. Left for the owner, as report 156 left them (#2558):
`l.push(a, a)` for `push`'s words and `l.push(l[0])` for `written returned List a → List a` are false rows
under the kernel's reading; the definitions give no count. The validator does not check that a stored
value's type is the destination's element type (`ownership-v2.md` §2.13.6 asks it to); v1 reads the same
validator and is frozen, so v3 reads such a row as above instead.

## 5. Reproduce

```sh
node bench/ownership-sweeps/row-words.mjs --beni=zig-out/safe/bin/beni --out=<dir> --rows=27000 --seed=1
node bench/ownership-sweeps/worded-stored-dest.mjs <dir>/wsd
node bench/ownership-sweeps/run.mjs --beni=zig-out/safe/bin/beni --checker=v3 --mode=both --jobs=20 --tmp=<disk> <dir>/wsd
zig build test-blackbox-corpus -Dcorpus=WordedStored
```
