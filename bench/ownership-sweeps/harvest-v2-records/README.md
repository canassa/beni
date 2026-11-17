# harvest-v2-records

The test programs of the 29 pull requests that built checker v2's record pass (`own2-*`), run under
`--ownership=v3` with the four-leg oracle (`--mode=both`) at `47aeb7854a`. The pull requests are closed.
v2's expectation files (`.v2`, `.v2.ownership`, `.in-place-v2`, `ownership-v2-known.txt`) are not kept.

```sh
node bench/ownership-sweeps/run.mjs --beni=zig-out/safe/bin/beni --checker=v3 --mode=both --jobs=8 \
  --tmp=/path/on/disk bench/ownership-sweeps/harvest-v2-records
```

One directory for each program: `Main.beni`, and `expected` when the pull request had a golden. A program
that was a library module in `tests/corpus/ownership/` (checked, never run) got a `run`/`main` at its end
that calls each `pub` function on fresh values and prints the answers, so the oracle can run it. The
library code is the pull request's text, unchanged. A refusal inside the library part is the checker's
judgement of the pull request's own code; a refusal in `run` would be the driver's, and the drivers hand
each call a fresh value for that reason.

Verdict: every program is SAME, REFUSED or LIMIT. There is no fault (no TRAP, DIFF, IPTRAP, IPDIFF,
RIPTRAP, RIPDIFF or CRASH). Safe = writing in place at the refused site would be correct.

| Program | Source PR | v3 verdict | Judgement |
|---|---|---|---|
| RecordBesideLists | 2438 | REFUSED disjoint | correct: `pushA`, `both`, `pair` and `keepIn` get one list or record at two places; `apart` passes |
| RecordBesideListsSupplied | 2441 | REFUSED disjoint, element | correct: `shared` and `twice`; `apart` passes |
| RecordBesideSchema | 2481, 2482 | REFUSED unknown | **precision loss**: `bump` writes a record that `Part.parse` answered, and nothing else holds it |
| RecordCalleeFields | 2428 | REFUSED later-use | correct: only `written`, which reads the written field |
| RecordCalleeWritesBelow | 2444 | REFUSED later-use | correct: `written` and `another` read what the write changes |
| RecordCellEdit | 2426 | REFUSED supply | **precision loss**: `Ref.update` of a record the cell alone holds (three sites) |
| RecordFieldAfterWrite | 2450 | REFUSED later-use | correct: three sites read the written record through another name |
| RecordFieldCapture | 2429 | REFUSED later-use, escaped | correct for `after`, `beforeWritten`, `listField`; **precision loss** for `nested` (it reads only `y` after the write of `x`) |
| RecordFoldPush | 2426, 2438 | REFUSED disjoint | correct: `twice` passes one list twice; `pushed` passes |
| RecordFullUpdateLater | 2450 | REFUSED later-use | correct: each site reads `count` or the record after its write |
| RecordLimitKeepsSpread | 2466 | LIMIT | a 42-field model; the write is unsafe in place (answer -99099), so the module needs a refusal, and v3 stops at its limit instead |
| RecordLocalFunction | 2456 | REFUSED later-use | correct: only `written`; `untouched` and `lambda` pass |
| RecordNeedHoist | 2453 | REFUSED call, later-use | correct: `mod` updates an answer of an unknown function; `inArm` reads `p.x` after the write |
| RecordOnceInPlace | 2466 | REFUSED captured | **precision loss**: a closure that runs at most once writes the record, and nothing reads it after |
| RecordPassOnly | 2426 | REFUSED captured, later-use | correct: the callback writes the list that `keep` still holds |
| RecordPassTwice | 2426 | REFUSED captured, later-use | correct, as RecordPassOnly |
| RecordRefusedKeepsSpread | 2466 | REFUSED later-use | correct: `s` and `t` are one record when written in place |
| RecordSiblingHolds | 2447 | REFUSED later-use, disjoint | correct: `sameField`, `wholeAfter`, `shared`, `sharedTwin`; `apart` passes |
| RecordStoresTopLevel | 2495 | SAME | |
| RecordTopLevel | 2468 | REFUSED unknown | correct: `moved` writes a top-level value |
| RecordWriteFields | 2431 | REFUSED later-use, captured | correct, except `onceUntouched` (**precision loss**: reads `p.y` after a write of `p.x`) |
| SanitiserCellCapture | 2468 | SAME | |
| SanitiserCellEdit | 2468 | REFUSED supply | **precision loss**: `Ref.update` and `Ref.modify` callbacks that push to the cell's own list (seven sites) |
| SanitiserRecordLimit | 2468 | LIMIT | as RecordLimitKeepsSpread (answer -98999) |
| SanitiserRecordRefused | 2468 | REFUSED later-use | correct: two updates of one record |
| SanitiserRowKeptApart | 2468 | REFUSED later-use | **precision loss**: the callback writes a `Record.copy`'s fresh field |

`SanitiserCellCapture`, `SanitiserCellEdit` and `SanitiserRowKeptApart` share a name with a corpus program;
the pull request changed it, so the text here differs. The other pull requests of the 29 add only v2
expectation files, `docs/`, `plans/` or `src/`.
