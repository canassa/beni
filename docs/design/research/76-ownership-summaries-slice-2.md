# 76 — The ownership checker's second slice: summaries, run over everything we have

*2026-10-12. What `beni dump --stage=ownership` says once calls go through inferred summaries
(`ownership-checker.md` §16: summaries, the caller's side of a written parameter, the recursion
fixpoint, the library's asserted primitive rows), over the corpora research 74 measured, compared
line by line with slice 1. All figures are **[measured]** by the commands in §8, on the branch that
adds the slice. As in research 74, none of these corpora is the external one the thesis's decision
rests on (thesis §12.4).*

---

## 0. The answer

1. **Summaries decide what slice 1 left open, and almost all of it held.** Of slice 1's 311 provisional
   acceptances outside the list-runtime tests (`param`, `call`, `callback-param`), **294 held**, **7 became
   rejections** and **10 became `pending`**; every `param` acceptance, and every `call` acceptance of the
   corpus, held.
   Five rejections became acceptances: TodoMVC's `changed` (thesis I5), in all four programs and the corpus
   copy, because `changed`'s summary never reads its first argument's `.todos`.
2. **The caller's side holds too.** Slice 2 adds 316 call-site demands — a call of a function whose summary
   writes a parameter is a demand at the call. Outside the list-runtime tests, of 257, **246 are accepted, 2
   pending and 9 rejected**, and every rejection is approximate (§4), not a caller that reads what it passed. Conduit's `Main.update` passing page models to the pages' `update`s is accepted at every call.
3. **Every application demand is accepted or waits for the entry protocol.** Conduit 22 accepted + 1 pending,
   the table app 4 + 1, TodoMVC 4 + 4: **0 rejections**. The pending lines are each program's `update`, which
   the runtime calls and the TEA entry protocol (thesis §7, not built) would check.
4. **Outside the list-runtime tests, 32 of 687 demands are rejected** (research 74: 20 of 352, which counted
   no call-site demand): the same 8 top-level lists, 4 identity promises and one `xs ++ xs`; **8 edits of an
   element** through `update`, `map`, `foldr` or `Dict.update`; 2 writes of a `Ref`'s contents; 6 inside the
   browser-tea runtime's job table; 2 through a recursive local function; and `Task.raceAll`'s once closure.
5. **The finding: a destructive read is not inferable.** `update`, `map`, the folds and `Dict.update` hand out
   an element while the container is still read, so their inferred summaries supply it *borrowed*, and a
   callback that edits its element is rejected (`supply`, approximate). The thesis asserts these rows and
   needs exclusive contents for them; slice 2 asserts neither (§5). Nine of the 32 rejections, every element-
   edit fixture of Table 6.2 (T40, T42, T57, and T59's accepted variant) and all four Lean-model
   disagreements (§6) are this one fact.
6. **`check` is not slower: the pass does not run in it.** `beni check --jobs=1` on the 100 000-line
   program: 145.2 ms on the branch, 144.1 ms on master (best of 7, interleaved runs within 1 %). The pass
   itself, in the dump, costs **38–74 % of a check** of the same modules (§7) — a number for slice 4, which
   must bring it under the thesis's ~10 % before the pass runs in every build.

## 1. What was measured

The corpora and commands of research 74 §1, with the same split: core (26 modules), the five platforms, the
table app, TodoMVC's four programs, Conduit, and the 928 corpus targets, of which the 23 `run/List*` and
`run/WriteRows*` programs are the list-runtime tests that pin persistence on purpose. The slice-1 numbers are
the slice-1 binary re-run on the same tree, so the two columns compare like with like; they differ from
research 74's corpus figures by the sweep's target discovery (875 targets check under some platform here).

What slice 2 adds to the lines a report prints (§16.11): **call-site demands** (`call M.f x`), **`value`
lines** for a writing function value where its calls are checked or go out of sight, and the **`pending`**
verdict. Its acceptances say which summary decided them.

## 2. The table

| Corpus | Demands | Accepted (fresh / call / param / callback-param) | Pending | Rejected | Rejected by cause |
|---|---|---|---|---|---|
| core | 119 (14) | 117 (9 / 20 / 84 / 4) | 0 | 2 (1) | supply 1, captured-edit 1 |
| platforms | 23 (8) | 10 (2 / 0 / 7 / 1) | 2 | 11 (1) | escaped 4, call 2, supply 5 |
| table app | 5 (2) | 4 (1 / 0 / 3 / 0) | 1 | 0 (0) | — |
| TodoMVC | 8 (4) | 4 (0 / 0 / 4 / 0) | 4 | **0** (4) | — |
| Conduit | 23 (15) | 22 (7 / 0 / 15 / 0) | 1 | 0 (0) | — |
| corpus, not list-runtime | 509 (298) | 401 (51 / 49 / 285 / 16) | 89 | 19 (14) | top-level 8, call 6, supply 4, disjoint 1 |
| **subtotal** | **687** (341) | **558** | **97** | **32** (20) | |
| corpus, list-runtime tests | 175 (113) | 97 (42 / 6 / 38 / 11) | 0 | 78 (70) | top-level 41, later-use 13, call 13, supply 4, alias 4, captured-edit 2, disjoint 1 |

Slice 1's figures for the same rows in parentheses. Two acceptances of the corpus row rest on a callee with
no summary (`assumed 2`, §15 decision 2). The growth outside the list-runtime tests is 257 call-site demands
and 89 `value` lines; in core most of the call-site demands are writes inside its own loops that slice 1 did
not see as demands (`put` and `done` on a builder, §16.8), all accepted.

## 3. Slice 1's provisional acceptances, and every flip

**What became of them.**

| Slice 1 accepted as | Corpus, not list-runtime | Applications, core, platforms | List-runtime tests |
|---|---|---|---|
| `param` (231 / 23 / 14) | 229 held (210 `param`, 19 now `call`: a recursive call's result the summary calls fresh), 2 renamed lines | 23 held | 14 held |
| `call` (23 / 3 / 3) | 23 held | **3 rejected** | 3 held |
| `callback-param` (27 / 4 / 9) | 13 held, **4 rejected**, 10 pending | 4 held | 8 held, **1 rejected** |
| `fresh` (3 / 7 / 17) | 3 held | 7 held | 17 held |

**Every flip from accepted to rejected (8).**

| Where | Line | Why |
|---|---|---|
| `browser/direct/NestedFor` 42:73 | `List.push g.kids` in a `List.update` callback | `update` supplies its element borrowed (§5) — approximate |
| `browser/direct/NestedFor` 48:66 | `List.update g.kids` in a `List.update` callback | the same |
| `check/good/RefUpdateImpure` 11:28 | `List.push seen` in a `Ref.update` callback | `Ref.update` hands its callback the cell's contents, which the `Ref` keeps: supplied borrowed, as the thesis's row says (⊤) |
| `run/RefModify` 26:28 | `List.push ns` in a `Ref.update` callback | the same |
| `run/ListForms` 100:73 (list-runtime) | `[ …ys, … ]` in a `List.map` callback | `map` supplies its element borrowed (§5) — approximate |
| core `Url.Parser` 298:66 | `[ …Maybe.withDefault g [], x ]` in a `Dict.update` callback | `Dict.update` supplies the value borrowed — approximate, a level of the folded tree (§5) |
| browser-tea `Tea` 263:30 | `[ …old, spawn host state.scope job ]` | `old` comes from the job table, which `spawn`'s summary escapes into a fiber — approximate |
| browser-tea `Tea` 285:30 | `[ …old, queue host job ]` | the same |

**Accepted to pending (10).** `LinkOutsideMount` 31:39 and `UrlAddress` 107:51 — an `update` written as a
lambda inside the program record, which the entry protocol would check; `PrependInLoop` 49:29,
`ReleaseEverything` 123:29 and `TailModConsBranches` 115:34 — a local function that calls itself, whose group
fixpoint (thesis §3.6) is not built; `PrependInLoop` 54:70 and `ConstrainedFunctionConstantRoutes` 83:32 — a
writing closure returned from its function; `CallbackOrderFoldr` 40:67, 41:68 and `CoreSetRest` 62:56 — a
callback handed to `Set.foldl`/`Set.foldr`, which pass it to `Dict.foldl` inside a lambda of their own, and a
function parameter captured by a lambda is out of the summary's sight (§16.5).

**Rejected to accepted (5).** TodoMVC's `changed { model | draft = "" } (model.todos ++ [ new ])` in
`Sandbox`, `NoEditing`, `NoRouting`, `NoStorage` and the corpus copy `browser/tea/TodoMVC`: the pending record
holds the old `todos` only at `.todos`, which `changed`'s summary (`π2 RA; res .todos π2`) never touches.

## 4. What is still rejected outside the list-runtime tests (32)

**Would be rejected by the full checker too (14).** The 8 top-level lists of research 74 §3; the 4
identity promises of `KeyedEnds` (`List.take rows k ++ [ r, …List.drop rows k ]`), now read off `take`'s
and `drop`'s inferred `res fresh, π1`; `dispatch/AppendOnLists`'s `xs ++ xs`; and the two `Ref.update`
callbacks of §3, which write what a `Ref` keeps.

**Limits of slice 2 (18).**

- *Element edits (8, `supply`, approximate):* `NestedFor` ×2, the browser platform's `Cmd.map`, whose
  `mapItem` extends each item's key path through `List.map` (×4), its `Sub.both` passed to `List.foldr`, and
  `Url.Parser`'s `Dict.update`. §5.
- *The browser-tea runtime's job table (6):* three call-site demands, a `List.append` and the two
  constructions of §3, all through `Dict` values of `state.jobs` that `spawn` and `keyedNow` escape into
  fibers or that a fold hands back — approximate (`escaped`, `call`).
- *A recursive local function (2, `call`, approximate):* `TailModConsBranches`'s `first` calls itself; its
  class is read off with its own calls conservative, so its write of `ys` is approximate and the two demands
  that rest on it say so.
- *A once closure (1, `captured-edit`):* `Task.raceAll`, as in slice 1.

**Pending (97).** 89 are a program's `update` handed to the runtime (77 `value Main.update` lines, the two
record lambdas above, and the applications' 8); 3 recursive local functions; 2 returned writing closures; 3
callbacks behind `Set.foldl`/`foldr`.

## 5. The library: what was asserted, and what inference could not reach

**Asserted primitive rows** (§16.8): `cons`, `append`, `set`, `insertAt`, `push`, `pop`, `removeAt` (the
writers whose bodies are `Js.pure`), `copy`, `length`, `at`, `unsafeGet`, `sliceOf`, `view`, `base`,
`offset`, `builder`, `put`, `done`, `identical`, `kept` — 20 rows, each a function over `Js` or a `foreign`
that touches a list's array. Every other function of `core/` and the platforms has an inferred summary;
`update`, `swap`, `map`, `indexedMap`, `filterMap`, the folds, `initialize`, `filter`, `slice`, `take`,
`drop`, `close`, `Dict` and `Set` included.

**Inferred as the thesis's rows say:** `foldl` and `foldr` supply their accumulator owned under "returns
owned" (`supply 2 π2 owned, cb3 owned`), and reject T46's callback that may return a top-level list;
`filter`, `take`, `drop` and `reverse` keep their identity promises (`res fresh, π1`); `map` returns its input
only where the types allow (§16.4's filter); `initialize`'s result elements are `cb2`, never `fresh`, so T59's
`[ cell, cell ]` is never supplied owned.

**Not reachable by inference (the finding).** `update`'s body is `set xs i (func (unsafeGet xs i))`: the
element goes to `func` while `xs` waits as `set`'s argument, so the supply is borrowed. `map`'s, the folds'
and `Dict.update`'s loops hand out `at a i` while `a` is read by the next iteration. The thesis asserts these
destructive reads (§3.8, §3.11) and makes them depend on exclusive contents, which slice 2 does not build.
Per the brief, they are **not asserted**: an element edit through them is rejected, `supply`, approximate.
This is §16.14's second open question.

**What it took to keep summaries narrow.** Two things the thesis has and slice 1 did not need: folding
recursive types (thesis §3.1) — without it every `Dict` function's summary exceeded the cap — and bounding
fresh numbers by result paths (thesis §4.6) — without it Conduit's `Main.update` named 2 601 provenances. With
both, one summary of all those measured (Conduit's `Main.update`, whose message type has 103 tracked paths) is
coarsened under §16.7's cap and none is pessimistic.

## 6. Against the Lean model

`proofs/ownership/Ownership/Fixtures.lean` gives each Table 6.2 program it runs an intended verdict; the
corpus fixtures that run the same programs (`Differential`, `Callbacks`, `Recursion`, `T59`,
`OpaqueSlots`, `ClosureCapture`, `StoredTwice`, `Toplevel`) agree on **T1, T2, T3, T7, T10, T12, T14, T15,
T17, T33 (both), T46, T48 (both), T52 (both), T53 and T59 (shared)**. They **disagree on four**, all accepted
by the Lean model and rejected here, all §5's finding:

| Program | Lean | Slice 2 | Why |
|---|---|---|---|
| T40 record shape | accepted | rejected `supply` | `update`'s owned element needs the asserted destructive read and exclusive contents |
| T42 distinct conditional map | accepted | rejected `supply` | the same, for `map` |
| T57 distinct | accepted | rejected `supply` | the same, for `update` with a callback that edits its element's head |
| T59 initialize distinct | accepted | rejected `supply` | the same: two literals are two cells, but `update` supplies borrowed |

No program the Lean model rejects is accepted here. The disagreement has a plain source: the Lean core has
`focus` (an element edit, `update`'s shape) and `traverse` (`map`'s and the folds') as *primitives*, with
exclusive contents built in — which is to say it asserts the destructive read that slice 2, following the
brief, infers from `core/List`'s bodies and cannot reach. Since PR #59 the Lean checker also publishes one
summary per function and applies it at calls (`Checker.lean`; the per-call re-inference is kept as
`Reinfer.lean`), as slice 2 does. The model could not be run here (no Lean toolchain in the environment); the
comparison is against its fixtures' recorded verdicts, which its own test suite asserts.

## 7. What it costs

`check` and `build` do not run the pass. **Check time, master vs branch** (ReleaseFast, `--jobs=1
--no-cache`, best of 7, pinned to one core, load 2.6): the 100 000-line generated program 144.1 / 145.2 ms
(three interleaved rounds: 144.1–146.0 / 146.2–146.7), `bench/corpus` 13.2 / 13.4 ms, Conduit 16.0 / 16.2 ms —
within 1 %, which the identical code path puts down to layout.

**The pass, in the dump** (`--self-profile`'s `ownership` event against the `check` events of the same run,
which checks core too, §16.9):

| Target | Pass | Check of every module | Ratio | Slice 1's pass |
|---|---|---|---|---|
| `bench/corpus` (18 files, 3 994 lines) | 6.7 ms | 17.4 ms | 38 % | ~2.6 ms |
| Conduit | 13.8 ms | 30.9 ms | 45 % | ~2.1 ms |
| `core` (every summary of core) | 12.7 ms | 17.2 ms | 74 % | ~5.7 ms |

Slice 1's column is master's dump wall time minus its `check` wall time on the same target (best of 7),
which includes printing the report.

Slice 1 walked each target declaration once; slice 2 computes every summary the targets reach, solves
recursive groups in about three walks, and checks core in the dump's process. The generated 100 000-line
program carries diagnostics, which the dump refuses, so it has no pass figure. Every corpus case stays within
the per-test instruction budget: the gates pass with the ownership fixtures, whose dumps check all of core.

## 8. How to reproduce

```sh
zig build
B=./zig-out/bin/beni
$B dump --stage=ownership core
$B dump --stage=ownership --platform=browser-tea platforms/browser-tea          # and node, browser, browser-direct, html
$B dump --stage=ownership --platform=browser-tea examples/conduit/src
$B dump --stage=ownership --platform=browser-tea bench/todomvc/apps/beni/Sandbox.beni
$B dump --stage=ownership --ownership-totals --platform=node tests/corpus/run/ListPrepend.beni
$B dump --stage=ownership --self-profile=p.json bench/corpus                    # the `ownership` event
zig build -Doptimize=ReleaseFast && zig build bench -- --generate=100000
time ./zig-out/bin/beni check --jobs=1 --no-cache .zig-cache/bench-gen
```

The corpus sweep is research 74's: every target dumped under the first platform it checks with, the totals
summed, and each slice-1 line matched with the slice-2 line at the same module, position, operation and
base.
