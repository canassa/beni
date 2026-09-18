<!-- Written during the spike as the implementer brief; decisions at the top are the manager decisions taken at the time. Kept for report 19 and the S8 read-back. -->
# S7 — return-type dispatch (pin-and-close)

**Manager decisions (binding):** do NOT cut S7; do all steps 0–8. Q-1: do not pre-empt; step 6 is the test; if `Interface.Quantified` must grow, stop and report. Q-2: `run/DecodeInto` in the §1.7 shape; drop to two of the three ideas only if one cannot work in one file. Q-3: leave the rigid-arm order alone; record it as an Appendix A row. Q-4: pin only the success half of the constrained `let`. Q-5: no fixture; add the by-construction sentence to §4.1. Q-6: S6b is committed before S7 starts (base = the S6b commit, not `8081b5f`).

**Headline:** S2 landed parse/lower, S3 the checker incl. `type_dispatch_needs_annotation`, S4 the backend. `run/TypeDispatch` prints `7 / 42` across two target types; `emit/TypeDispatch.js` shows `($m$0, n$1) => $m$0(n$1)`; `check/bad/TypeDispatchUnannotated.diag` exists. S7 finds the parts of §4 that work by accident, gives each a fixture, and corrects two spec errors. ~16 files, no expected `src/` change.

**Working rules:** one implementer builds; fail-first in a `git worktree` at the base commit; steps 1–3 are EXPECTED to pass at base — record them as "already correct, now pinned", never quietly bless; every blessed golden read against its intent comment.

## 1. Scope

- **1.1 front end (§4.1, §1.4, A.5)** — landed: `src/bir/Lower.zig typeDispatchVar` (not local, not top-level, not prelude, then enclosing decl's `where` list, then `annotation_vars`). No work.
- **1.2 checker (§4.2, §6.7)** — landed: `Constrain.zig typeDispatch` builds `fn_var = (args) -> expected` with no receiver, `Origin.type_dispatch`; rigid arm of discharge answers `evidence k`. No work.
- **1.3 backend (§8.4)** — landed: `Lower.typeDispatchExpr`. READING only: the constraint root is always a rigid, so outcomes are `evidence k`, a `primitive` (A.53 bridge on an `equatable`/`number` rigid), or §10.8's error; the `.derived`/`.ext_derived`/`.top`/`.ext`/`.field` arms are unreachable table-bug walls. Record as an Appendix A row; do not delete them.
- **1.4 `type_dispatch_needs_annotation` (§10.8, A.5)** — trigger (2) "no `where` clause at all" is pinned by `check/bad/TypeDispatchUnannotated`; trigger (1) "the clause names the variable but not the method" is NOT. S7 adds it.
- **1.5 result-only `where` across modules (§2.4, §4.2)** — same-module pinned by `run/TypeDispatch`; the imported form (constraint through `Schemes.Writer.quantifierOf` → interface → `Schemes.instantiate`, canonical order computed identically by callee and caller) is NOT. Every existing cross-module evidence fixture has the variable in an argument position.
- **1.6 dispatch as forwarded evidence (§7.2, §8.2, A.46)** — `decodeTwo : String, String -> ( a, a ) where a.fromList …` calling `decodeInto` twice; the return-position analogue of `run/EvidenceCapture`. Unpinned. "Dispatch inside a derived shape" cannot arise (derivation is by name, A.56): record, do not fixture.
- **1.7 `run/DecodeInto`** — two user types cannot both have a `decode` in one module (module rule) and `run/` is single-file, so the second target is a core type. Use `String.fromList : List Char -> String` / `String.toList`. Shape: `pub type Tag = Tag String`, `pub fromList : List Char -> Tag`, `pub label : Tag -> String`; `decodeInto : String -> a where a.fromList : List Char -> a` with body `a.fromList (String.toList s)`; `decodeTwo` as in 1.6; `asTag : Tag` (target `top fromList`), `asString : String` (`ext String fromList`), `pair : ( Tag, Tag )`; one caller pinned by a LATER USE, not an annotation (1.8).
- **1.8 annotation vs later use; `let` (§4.2, §6.4 rule (a), A.30)** — the "flex made concrete by a later use" route is untested; one line `let t = decodeInto "zz" in label t` pins rule (a) and the route. Do not duplicate `check/bad/LetConstrainedTwice`.
- **1.9 `settleUndetermined` `.any` arm (A.66, §10.1)** — `undeterminedMethodReceiver` has three `kind` arms; only `.number` is pinned. A result-only constraint the caller never pins is the natural `.any` producer. Keep the constraint off the caller's interface (annotate the caller at a type not mentioning `a`, e.g. `pub ignored : Int` / `Basics.always 1 (decodeInto "x")`), else `promote` claims it.
- **1.10 dump shape (§7.2, §7.3)** — no `dispatch/*TypeDispatch*` exists; nothing reads a receiver-less site out of the table.
- **1.11 spec corrections** — (1) §4.1 cites `module(a).decode(bytes)`; research 20 §5.4 (line ~1013) says that syntax does not exist in Roc's shipped form (`s_type_var_alias` + `e_type_method_call` → `e_type_dispatch_call`), and that beni's form is "Roc's design minus the binding statement" — fix the citation in place. (2) §4.2 gains one paragraph on both routes the result type arrives by. (3) §8.4 gains one sentence recording 1.3's reading. (4) Appendix A rows (append only; read the tail for the next number): the `run/` single-file limit and why `DecodeInto`'s second target is core; 1.3's unreachable arms; the `.any` arm belongs to return-position dispatch; Q-3's ordering (`builtinRigidTarget` before §10.8). (5) §4.1 by-construction sentence (Q-5).

## 2. Steps

| # | Work | Fixture | Expected at base |
|---|---|---|---|
| 0 | `grep -rn type_dispatch src/`; read the five existing `*TypeDispatch*` fixtures | — | — |
| 1 | 1.10 receiver-less site in the table (copy `run/TypeDispatch`'s shape) | `dispatch/TypeDispatch.{beni,dispatch}` | passes; golden shows `decl make evidence=1`, `site N 0 evidence 0`, the two caller sites |
| 2 | 1.4 trigger (1): `pub decode : String -> Result String a where a.describe : a -> String`, body `a.decode s` | `check/bad/TypeDispatchMethodNotInWhere.{beni,diag}` | `type_dispatch_needs_annotation` naming the type THIS use wants |
| 3 | 1.9 `.any` undetermined receiver | `check/bad/TypeDispatchUnpinnedResult.{beni,diag}` | `unknown_method` "a type variable no use of this value determines" |
| 4 | 1.5–1.8 the program | `run/DecodeInto.{beni,expected}` | may genuinely fail — that is S7's finding |
| 5 | the table for step 4 | `dispatch/DecodeInto.{beni,dispatch}` | pre-order nesting for the forwarded slot (A.68) |
| 6 | 1.5 across modules: `Decoder.beni` exports `pub decodeInto`; `Main.beni` annotates callers at its own type and at `String` | `dispatch/DecodeIntoAcrossModules/{Decoder.beni,Main.beni,_expected.dispatch}` | may fail: interface round-trip of a result-only quantifier |
| 7 | 1.11 spec | — | — |
| 8 | report; if steps 4/6 needed a `src/` change, all three gates and say which file | — | — |

Order: 4 before 5; 6 after 4; 1–3 any order.

## 3. Open questions — decided above (Q-1…Q-6)

Q-3 detail: rigid-arm order is `findConstraint` → `builtinRigidTarget` → the `.type_dispatch` check, so `pub same : a, a -> Bool` with body `a.eq x y` and no clause resolves to `primitive strict_eq`, not §10.8. Leave it; add the program as a one-line addition to `run/DecodeInto` and an Appendix A row.

## 4. Ownership / not in scope / gates

**Owns:** the six fixtures above; spec §4.1, §4.2, §8.4 text and appended Appendix A rows; ONLY if a step fails, the single `src/` file it points at (say which and why).
**Not in scope:** changes to `src/bir/Lower.zig`, `src/check/Constrain.zig`, `src/js/Lower.zig`; deleting `typeDispatchExpr`'s unreachable arms; reordering the rigid-arm tests; a second `check/bad` for constrained-`let` failure; `run/` project support; `ambiguous_method_receiver` beyond reading; §5, §9, `core/`, `bench/`; S8; `master`; the diary (the manager writes it).
**Gates:** `zig build && zig build test && zig build test-blackbox && zig build fmt-check`, then `test-blackbox` again. Bless with `BENI_WRITE_EXPECTED=1`, narrowed with `BENI_BLESS_ONLY=`.
**Report:** each item 1.1–1.11 done/partial/not reached with its fixture; per fixture, whether it PASSED at base (pinned) or FAILED at base (gap closed); goldens re-blessed with reasons; any `src/` change; answers to Q-1…Q-6; Appendix A numbers; anything not reached.
