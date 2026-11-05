# Record verdicts in the bridge — 2026-11-05 (#1872)

Slice 3 of #316. Before this change, the bridge skipped every program that held a
record object (`record-object`), so it compared no record verdict. Now the translator
spells a record object as a beni record and an update as `{ r | f = v }`, and the
comparison reads the `update` lines of the dump at their sites (`BRIDGE.md`, *Verdicts
and sites*). The fixed streams have the record probes (the `record` family, 37
programs) and the targeted product's record part (targeted 740–795, 56 programs).
Generator v7 (record objects) is a CI stream.

Evidence: `evidence/bridge-records/report.json` (the summary) and
`evidence/bridge-records/evidence.json.gz` (every lead, with its record lines).

## The CI campaign

`node scripts/bridge.mjs --ci --no-build --jobs=4`, on `69edbf7ba4` (this branch on
`master` at `c375937083`), with a Debug beni of that tree (`compilerSha256` `1fc01a84…`)
and the oracle of the same tree (`oracleSha256` `61a0166b…`). 29 s. The same run on the
branch's first base, `master` at `1468390492` (beni `1b55fdc4…`), gave the same counts,
stream by stream and site by site.

| Stream | Programs | Translated | Agreements | Precision | Leads |
|---|---:|---:|---:|---:|---:|
| fixtures (with `record`) | 1,065 | 828 | 782 | 23 | 23 |
| enumerate, bound 1 | 399 | 381 | 353 | 27 | 1 |
| generator v5, seed 17 | 128 | 61 | 51 | 5 | 5 |
| generator v6, seed 17 | 128 | 56 | 54 | 2 | 0 |
| generator v7, seed 17 | 128 | 64 | 58 | 3 | 3 |
| **Total** | **1,848** | **1,390** | **1,298** | **60** | **32** |

Every translated program had its `browser-tea` final value checked against the
oracle (1,390). No in-place run differs from its `browser-tea` run: 32 leads are
`unconfirmed`, 28 are `blocked-by-other-refusals`, 0 are `confirmed`.

Sites: 1,290 agreements, 66 precision, 52 leads, 1,161 unknown, 86 pending. The
sites that hold a record line (`recordSites`, a subset):

| Agreement | Precision | Lead | Unknown | Lead where Zig hoists |
|---:|---:|---:|---:|---:|
| 120 | 15 | 24 | 111 | 23 |

The translated constructs: 171 `object`, 218 `get`, 9 `record-copy` and 183 updates
(`assign`).

## The record differences, each explained

**Leads** (the oracle refuses, Zig accepts), 24 record sites:

- 23 are the hoist (§31.14). Zig reads a written field into a temporary before the
  write, at an update or at a call that writes the argument (`[hoisted 1]` on the Zig
  line). This core has no hoist and refuses the read, by Jayson's decision of
  2026-11-04 (#316, `own-record-assign-q1`). Programs: `writtenRead`, `payloadRead`,
  `calleeWritten`, `layersWritten`, `eitherWritten`, the 16 targeted reads of a
  written field (`readAfter n w w`, `callRead n w w`), and v7's `v7-17-4` and
  `v7-17-6`. Every one that runs is `unconfirmed`: Zig's in-place run gives the
  value-semantics answer.
- 1 is the oracle's imprecision: `callbackKept` (a write through a callback is a
  consume row, which has no field set, and the supply's owned bit is cleared).

The other leads are not at a record line: `selfHandler` (the oracle's limit on a
function below an input path), two v7 programs that the oracle refuses as `recursive
call does not preserve entry ownership assumptions`, one v7 site and `forShared`'s site
(`exclusive contents`) in programs that Zig refuses elsewhere, and the leads that the
list streams had before.

**Precision** (the oracle accepts, Zig refuses), 12 programs at a record line:

- 10 update one field twice through one holder, the first result dead
  (`sameFieldTwice`, the 8 targeted `updateTwice n f f`, `v7-17-122`). Zig reads a
  later update's base whole (§31.4 item 5); the oracle reads the fields that it keeps.
  This difference is on purpose (`DESIGN.md`, *Records written in place*).
- `copied`: Zig reads a local bound to `Record.copy r` as still holding `r`'s object
  (`alias`). This is the cause of #871.
- `bumpOnce`: Zig refuses a once lambda that reads a field of its captured record and
  then updates it (`later-use`). #2008.

Both Zig refusals are over-refusals: the oracle accepts, and its two runs agree.

## What the counts do not show

- A call argument is a whole use in this core, so an update followed by a call that
  reads only kept fields is refused here and accepted by Zig. That shape would be a
  lead. No program of these streams has it.
- The long campaign does not run v7 yet (#2010).
- Finite campaigns prove neither checker sound, nor the two equivalent.
