# 74 — The ownership checker's first slice, run over everything we have

*2026-10-12. What `beni dump --stage=ownership` (`ownership-checker.md`, slice 1: report mode,
one declaration at a time, calls conservative) says about core, the platforms, the applications
and the compiler's corpus. All figures are **[measured]** by the commands in §6, on the branch that
adds the pass. Nothing here is the thesis's §12 evaluation: none of these corpora is the external
one its decision rests on (thesis §12.4), and slice 1 has no summaries.*

---

## 0. The answer

1. **Outside the programs written to keep old versions, slice 1 rejects 20 of 352 demands, and
   14 of those 20 are rejections the full checker would make too.** Across core, the five
   platforms, the table app, TodoMVC, Conduit and the 901 corpus programs that are not list-runtime
   tests, there are **352 demand sites**: **332 accepted**, **20 rejected**. Of the 20, **eight are
   top-level lists** (the position rule), **one is real sharing** (`xs ++ xs`), **five are
   identity promises or a lookup-then-insert** that summaries cannot remove, and **six exist only
   because calls are conservative** (§3).
2. **The applications are nearly clean.** Conduit: 15 demands, all accepted. The table app: 2, both
   accepted. TodoMVC: 4, all rejected — every one is the thesis's own I5 example,
   `changed { model | … } (model.todos ++ [ new ])`, which a summary saying `changed` never reads
   its first argument's `.todos` accepts (thesis §5.2). With that one summary, every application
   demand we have is accepted.
3. **The list-runtime tests are rejected, as they should be.** The 23 `run/List*` and
   `run/WriteRows*` programs exist to pin persistence and identity — they keep every old version
   and print it — so 94 of their 153 demands are rejected: 45 later uses, 41 top-level lists,
   3 aliases. These are the thesis's T33 and T41 shapes; they would take `List.copy`.
4. **Every acceptance but 29 is pending.** 330 of the 391 accepted demands are on a parameter
   (`param`, `callback-param`) and 32 on a call's result (`call`): slice 1 accepts them locally and
   cannot know what the caller passes or what the callee returns. Only the 29 `fresh` acceptances
   are final in the sense of slice 1's own rules. The rejection count is an upper bound on what
   calls cost; the acceptance count is **not** a lower bound on the full checker's (§4).
5. **Construction is where the demands are**: 282 of the corpus's 462 demands are a spread or a
   `++`, not a named writer — Change 1 is what makes the checker matter.

## 1. What was measured

| Corpus | Targets | How |
|---|---|---|
| core | 26 modules | `beni dump --stage=ownership core` |
| platforms | `node`, `browser`, `browser-tea`, `browser-direct`, `html` | `--platform=<p> platforms/<p>` |
| table app | `bench/ui/apps/beni` | for `browser-tea` and `browser-direct` (same 2 demands) |
| TodoMVC | `bench/todomvc/apps/beni/*.beni`, 4 programs | `browser-tea` |
| Conduit | `examples/conduit/src`, 16 modules | `browser-tea` |
| corpus | every `.beni` (or project) under `run/`, `emit/`, `browser/`, `writes/`, `check/good/`, `dispatch/`, `regress/` | the first platform under which it checks clean |

928 corpus targets dumped; 39 did not check under any platform tried — the `core/` fixtures, which
need `--core` (`emit/core/`, `check/good/core/`, `emit/release/core/`) and a `regress/` program that
checks only with its own flags. `tests/corpus/ownership/` itself is not counted.

## 2. The table

| Corpus | Demands | Accepted (fresh / call / param / callback-param) | Rejected | Rejected by cause |
|---|---|---|---|---|
| core | 14 | 13 (0 / 1 / 8 / 4) | 1 | captured-edit 1 |
| platforms | 8 | 7 (0 / 2 / 5 / 0) | 1 | call 1 |
| table app | 2 | 2 (0 / 0 / 2 / 0) | 0 | — |
| TodoMVC | 4 | 0 | 4 | call 4 |
| Conduit | 15 | 15 (7 / 0 / 8 / 0) | 0 | — |
| corpus, not list-runtime | 309 | 295 (4 / 25 / 238 / 28) | 14 | top-level 8, call 5, disjoint 1 |
| **subtotal** | **352** | **332** | **20** | |
| corpus, list-runtime tests | 153 | 59 (18 / 4 / 25 / 12) | 94 | later-use 45, top-level 41, alias 3, captured-edit 2, captured 1, disjoint 1, call 1 |
| **all** | **505** | **391** | **114** | |

The table app is counted once; for `browser-direct` it reports the same two demands. TodoMVC's
corpus copy (`browser/tea/TodoMVC`) is in the corpus row, as one of its five `call` rejections.

By operation, over corpus, core and platforms: 168 constructions, 114 `++`, 49 `List.push`, 26
`List.update`, 24 `List.set`, 24 `List.swap`, 20 `List.removeAt`, 19 `List.insertAt`, 11
`List.append`, 6 `List.pop`, 1 `List.cons`.

## 3. Every rejection outside the list-runtime tests, by cause

**Would be rejected with perfect summaries too.**

- *Top-level lists (position, 8).* `run/ConstrainedFunctionConstant*` (3): `List.append blankInts …`
  on a top-level `blankInts`. `run/NestingFlatList`, `run/LetHelperJoinedMethod`,
  `run/PhantomAliasUnifiesByExpansion`, `run/Int32Keys`: `++` onto a top-level `none` or `blank`.
  Thesis §3.10 rejects all of them; the fix is to make the constant a function (Change 4).
- *Real sharing (1).* `dispatch/AppendOnLists`: `doubled = xs ++ xs` — the base is read as the
  second operand while it is written (T1's construction form).
- *Identity promises (4).* `browser/direct/KeyedEnds` and `browser/dom/KeyedEnds`:
  `List.take rows k ++ [ r, …List.drop rows k ]`. `take` of everything and `drop 0` return `rows`
  itself, so the two operands may be one array. Thesis §3.8 keeps those promises (O2), so the full
  checker rejects this too, as approximate ("`List.take xs i` may be `xs` itself"); the in-place
  spelling is `List.insertAt rows k r`.
- *Lookup then insert (1).* `platforms/browser-tea/Tea.beni` `want`: `taps` comes out of
  `Dict.get d k` and `d` is inserted into afterwards — the shape thesis §5.4 lists as real sharing.

**Rejected only because calls are conservative.**

- *A call that never reads its argument (4 + 1).* TodoMVC's four programs and its corpus copy: the
  pending record `{ model | draft = "", … }` still holds the old `todos` while `model.todos ++ [ new ]`
  writes them, and `changed` receives it. Slice 1 assumes every call reads every argument; the
  inferred summary of `changed model todos = { model | todos = todos }` says `unused` at `.todos`.
- *A closure called once (1).* `core/Task.beni` `raceAll`: `[ first, …rest ]` inside the lambda
  handed to `within`. Whether that is legal is an ownership class (`within` calls its body once);
  slice 1 has none (`captured-edit`).
So of the 20: **14 stay** (8 top-level, 1 sharing, 4 identity promises, 1 lookup) and **6 go** with
summaries and ownership classes (TodoMVC ×5, `raceAll`). The `call` cause does not tell the two
apart by itself: in the list-runtime tests, `run/ListSpreadPatterns` is rejected as `call` through
`note tag x = Debug.log tag x`, a function that really does return its argument, so that rejection
would stay.

## 4. What the acceptances are worth

| Accepted as | Count | What slice 2 must still show |
|---|---|---|
| `fresh` | 29 | nothing slice 1 does not already check |
| `param` | 286 | that every caller passes the parameter unique — for an `update` arm, the entry protocol (thesis §7, P1–P5) |
| `callback-param` | 44 | the caller's row: `foldl` supplies its accumulator owned only when the callback returns owned (thesis §3.7) |
| `call` | 32 | that the callee's result is fresh, not shared or escaped |

The `param` row is the size of the open question. 238 of the 295 non-list-runtime acceptances are a
model list in an `update` arm or an accumulator parameter — the thesis's I1 and I5, which it
accepts by the entry protocol and the recursion fixpoint. Slice 1 checks only the half inside the
function: that nothing in the body reads the old version afterwards. That half holds everywhere
outside the tests written to violate it.

## 5. What this does and does not say about the research question

The question is whether idiomatic code almost never meets the error. This slice measures code
**we** wrote, partly to exercise the edits; the thesis says that corpus cannot decide anything
(§12.4), and it does not. What it shows:

- *Within one function, idiomatic code is clean.* No later read, no alias, no closure holding an
  edited list, in Conduit, the table app, TodoMVC, core, the platforms or the 141 ordinary corpus
  programs that edit a list — except `xs ++ xs`, written to test `++`.
- *The rejections that remain are the ones the thesis predicted*: top-level lists (Change 4's cost,
  T53), identity promises (O2's cost, T52), a dictionary lookup then insert.
- *The question is now inter-procedural.* 362 of 391 acceptances rest on a caller or a callee. The
  number that decides adoption is how many of those survive summaries and the entry protocol —
  slice 2, then the external corpus of slice 3.

## 6. How to reproduce

```sh
zig build
B=./zig-out/bin/beni
$B dump --stage=ownership core
$B dump --stage=ownership --platform=browser-tea platforms/browser-tea   # and node, browser, browser-direct, html
$B dump --stage=ownership --platform=browser-tea bench/ui/apps/beni
$B dump --stage=ownership --platform=browser-tea examples/conduit/src
$B dump --stage=ownership --platform=browser-tea bench/todomvc/apps/beni/Sandbox.beni   # and the other three
$B dump --stage=ownership --platform=node tests/corpus/run/ListPrepend.beni             # one corpus program
```

The corpus sweep runs the last command for every corpus target, trying no platform, `node`,
`tests/platforms/page`, `browser-tea`, `browser-direct`, `browser` and `html` in turn, and sums the
`demands` lines. Each run of the dump includes a full check; the pass itself took 8.9 ms on Conduit
in a debug build (`--self-profile`'s `ownership` event), against 12.4 ms for the check's longest
module.
