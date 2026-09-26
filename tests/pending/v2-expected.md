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
- `tests/corpus/check/bad/PriorityGroupSpecializedPayloadEq` — re-derived without priority groups (R7): still a refusal at the same `==` (20:44), but R8a's `not_implemented` (P6 cannot write `L`'s derived row under v1's one-entry-per-parameter context) where the golden pins `not_equatable`; R8a's contexts decide it, re-blessed at R11
- `tests/corpus/check/bad/DeferredReceiverGeneralised.beni` — eager draining (§9.1, as R6b built it; R7's guard of CK-105): the same `no_methods_on_shape` at 19:9, but the record is rendered when it meets `f`'s instantiated receiver, before the inline lambda's body is constrained, so the message shows `{ combine : a -> b }` where v1's golden (rendered at the boundary) pins `{ combine : number -> number }`; re-blessed at R11

## Expected differences R4b introduced (re-blessed at R11)

v2's output differs from v1's golden on purpose, by a rule `checker-v2.md` states; the golden stays
v1's until the cut-over, when the fixture is re-blessed (or re-cut) under v2 with review.

- `tests/corpus/check/bad/InfiniteType.beni` — CK-04/CK-57 (§6.3, §8.2, `checker.md` §8.5): v2 reports the cycle at the parameter `f` (4:7), a binder, and writes the type down as `a = a -> b`; v1 reports it at the body with `a  =  … a …`
- `tests/corpus/check/good/RecordExtChain.beni` — §4.1's normalised records (CK-08): a record merge leaves one node, so the 65-link extension chain this fixture builds for `Render.max_ext_links` no longer exists, and v2 publishes the whole open record `{ r | a1 : a, … }`; at R11 the printer's truncation needs a fixture that reaches it another way
- `tests/corpus/check/depth/RecordExtTruncatedDeep.beni` — the same §4.1 rule: the mismatch's record prints in full instead of `{ … | … }`; re-cut with `RecordExtChain` at R11

## Expected differences R5 introduced (re-blessed at R11)

- `tests/corpus/check/bad/MissingField.beni` — CK-59 (§6.5 as built by R5): the literal's fields are constrained before it meets an expectation that cannot take its field names, so the message shows `{ x : number }` where v1's golden pins `{ x : a }`
- `tests/corpus/check/bad/UnknownField.beni` — the same rule: `{ x : number, y : number2, z : number3 }` where v1 shows `{ x : a, y : b, z : c }`
- `tests/corpus/check/bad/RecordNotClosed.beni` — the same rule: the literal is `{ x : Int }` where v1 shows `{ x : a }`
- `tests/corpus/check/bad/TryMixedShapes.beni` — CK-51 (§8.6, `checker.md` §8.6): a `Maybe` subject in a `Result` definition names the enclosing leg; v1's golden pins "this is neither: `Maybe Int`"
- `tests/corpus/check/bad/TryDefaultCycle.beni` — the guard of §5.1 holds (one `infinite_type`, the `?` defaulted to `Result` and the cycle reported, not silenced), in v2's own text and place (CK-04/CK-57, `checker.md` §8.5): at the parameter `x` (6:3), written `a = Result b a`; v1's golden reports it at the body with `a  =  … a …`

## Expected differences R6a introduced (re-blessed at R11, or at the slice named)

- `tests/corpus/check/bad/CyclicReceiverReportedOnce.beni` — CK-57 (§8.2, `checker.md` §8.5): the one `infinite_type` is at the `==` (2:7), as the golden pins (§9.5, CK-37), and written as its structure, `a = List a`; v1's golden prints `a  =  … a …`
- `tests/corpus/check/bad/LetHelperCyclicReceiver.beni` — the same rule, at the same `==`: `a = List a` for v1's `a  =  … a …`; a D5 row of §20.4, which R14 changes again
- `tests/corpus/check/bad/LetConstrainedTwice.beni` — eager draining (§9.1): `show n` binds `x` to `Int`, and `x.render` is resolved right after that node, so `Int`'s missing `render` is `unknown_method` at 11:14 before the second use's `type_mismatch`; v1 resolved it only at the boundary, after the mismatch had poisoned `Int`. A D5 row of §20.4, which R14 changes again
- `tests/corpus/check/bad/SpecializedEqWrongReceiver` — R8a (§11.2): `Wrapper`, `Before`, `After` and `Generic String` are own types whose derived `eq` depends on a payload's specialised `Holder.eq`; v2 derives with v1's one-entry-per-parameter context (the payload is never asked) until R8a's fixpoint, so it reports only the record and tuple shapes (48:10, 53:10), whose positions it does resolve (R6b fixed CK-102: before it, v2 refused those two in silence and accepted the file)
- `tests/corpus/run/DerivedEqInPriorityGroup` — R8a (§11.2): `W`'s derived `eq` holds a `Holder Keyed` whose imported `eq` asks `a.key`, not `a.eq`; v1's capability settle over method schemes answers it, v2's one-entry-per-parameter context does not ask the payload, and the syntactic capability bit it reads until R8a refuses `W` (`not_equatable` at 31:9 and 38:17), so `build` stops there too
- `tests/corpus/run/DerivedEqThroughCustom` — the same R8a case, through `ArbitraryHolder.Holder KeyedFunction.Keyed` at 170:35 and 171:35
- `tests/corpus/check/bad/MethodConstraintMismatch.beni` — review F6 (§14.1, §9.4 *As built by R6a's review*): a declaration whose method type failed publishes `<error>` and says nothing more about its requirements, so the `CONFLICTING METHOD TYPES` stands alone; v1's golden also pins a `CONSTRAINT IN AN INFERRED INTERFACE` warning printing `where a.render : ?` — a scheme v1 publishes with a hole in its `where` clause
