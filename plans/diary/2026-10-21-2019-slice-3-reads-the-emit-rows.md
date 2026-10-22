## 2026-10-21 20:19 CEST — Slice 3 reads the emit rows

**What I did.** Built slice 3 of the emit cache on `emit-cache-read`: a development build reads
the row the binary carries (`Emit.Task.lowerModule`), `Lower.planReuse` takes a declaration's
units whole when the parts and every fact match, `replayOrder` replays the surviving walk from
the row's per-unit edges (#328), `SchemaLower`'s parts are units at fixed indices (#349), and
`schema_shapes` is a funnel fact (#432) with the maker's canonical `false`. The join rebuilds the
head from the taken units' asks, the nullaries from the row's facts, and the maps from the row's
name identities; the counters count only when a row was available. Rebased onto master past
`e44f50d72` (#608's `lowerModule`/`printDevelopment` restructure), keeping `read_rows` and
splicing `unit.row` in `printDevelopment`.

Build5's differential tests found two failures. The real one: `fiberNames` cached a cross-module
name block and called `coreValue` only on a cache miss, so a unit taken from a later position
carried no `Needed` entry and embedded `core/List` was missing
`import { Task$andThen, Task$isWaiting } from "../_core/Task.mjs"` — the two trees differed by
that line. It now asks on every call; names stay cached. The other was the comparison: the
embedded core's maps name `beni:///core/…` and a `--core-root` core names `../../mycore/…`, so
the test normalizes both spellings and masks the manifest's map hashes (the map bytes are
compared directly).

Added `tests/corpus/run/SchemaShapeThreshold.beni` (30 syntactic `Json.decodeValue` sites of one
record, past `shape_threshold`'s 29; prints `210`) with the two-flag, two-core test, the page
test's `emit_units_lowered > 0` assertion, and `expectDifferentTrees` able to see a different
file set. Decoded the maker's own pack with a scratch parser to find that `Task`'s row is 232
units and 227 ask `probe`/`arm_dead`: the whole-program effect inference answers them, so a
program that suspends differently lowers almost all of `Task` (ForEachOrder 175, pure `forEach`
142, BracketRelease 143) while a matching one takes it (`Io.run` pure 113/10). Trees stay
byte-identical. Amended §9's "every core unit is reused" to say what was measured, wrote the
slice-3 As-built note, and opened #629 for the lost reuse. Gates green; `test-run-hashes`
recorded the new fixture's four modes and changed no existing hash.

**What I learned.** A funnel completeness hole can be invisible until a unit is **taken**: with
no rows every module lowered, so `fiberNames`' first call discovered the import; only a spliced
unit skips the discovery. The differential test is the oracle the spec says it is — it found a
module that would not load. And the counters alone cannot say which module fell back: `Task` and
`Tea` both looked plausible; decoding the row (idents grouped by module, then the fact questions
per unit) is what turned "41 lowered" into "227 of 232 units ask a fact the program answers".
§9's claim was a design assumption to be measured, and it did not hold; the doc now says so.
