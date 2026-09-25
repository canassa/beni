# tests/pending/v2-expected.md — corpus fixtures `test-v2` does not hold v2 to

`zig build test-v2` runs the whole of `tests/corpus/` under `--checker=v2`
([`plans/checker-rewrite.md`](../../plans/checker-rewrite.md) §2.4,
[`checker-v2.md`](../../docs/design/checker-v2.md) §22.2). Every fixture covered by an entry
below is **skipped and printed** (`REPORT  SKIP`), in report mode (R4a–R8b) and in strict mode
(R9–R11) alike. Nothing else is exempt.

An entry is a list item that starts with a back-quoted repo-relative path: one fixture (a `.beni`
file or a project directory directly under a kind directory, written without a trailing `/`), or a
whole `<kind>/core/` directory, written with one. The walker refuses anything else: a path that
does not exist, a golden or a file inside a project, a directory entry wider than `core/`, an
entry the walk of its kind never runs, and a fixture also listed in `v2-green.txt`. Every entry
says why, and which slice removes it.

## Not yet v2 (N13): `--core` fixtures, until R9

A fixture under a `core/` subdirectory runs with `--core`, which makes its own module part of
`core`. Until R9, `--checker=v2` checks the root package only and leaves `core` to v1
(`checker-v2.md` §22.1), so these still run v1 under `BENI_CHECKER=v2`: a PASS would count v1's
work as v2's. R9 deletes this section.

- `tests/corpus/bir/core/` — `dump --stage=bir`, which checks nothing; listed for the rule's sake
- `tests/corpus/dispatch/core/` — v1's dispatch tables
- `tests/corpus/check/bad/core/` — v1's diagnostics
- `tests/corpus/check/good/core/` — v1's interfaces

## Expected differences (`checker-v2.md` §20.4), re-blessed at the slice named

Only the rows whose v2 output differs from the golden before the cut-over; the D5 rows of §20.4
(`LetConstrainedTwice`, `LetHelperCyclicReceiver`) change at R14, after v1 is gone, and
`run/DerivedEqInPriorityGroup` must keep passing.

- `tests/corpus/check/bad/MethodNeedsAnnotation` — D3 (R7): v2 accepts the program; it becomes a `run/` fixture at R11
- `tests/corpus/check/bad/PriorityGroupSpecializedPayloadEq` — re-derived without priority groups (R7): still a refusal, with a new region; re-blessed at R11

## Expected differences R4b introduced (re-blessed at R11)

v2's output differs from v1's golden on purpose, by a rule `checker-v2.md` states; the golden stays
v1's until the cut-over, when the fixture is re-blessed (or re-cut) under v2 with review.

- `tests/corpus/check/bad/InfiniteType.beni` — CK-04/CK-57 (§6.3, §8.2, `checker.md` §8.5): v2 reports the cycle at the parameter `f` (4:7), a binder, and writes the type down as `a = a -> b`; v1 reports it at the body with `a  =  … a …`
- `tests/corpus/check/good/RecordExtChain.beni` — §4.1's normalised records (CK-08): a record merge leaves one node, so the 65-link extension chain this fixture builds for `Render.max_ext_links` no longer exists, and v2 publishes the whole open record `{ r | a1 : a, … }`; at R11 the printer's truncation needs a fixture that reaches it another way
- `tests/corpus/check/depth/RecordExtTruncatedDeep.beni` — the same §4.1 rule: the mismatch's record prints in full instead of `{ … | … }`; re-cut with `RecordExtChain` at R11
