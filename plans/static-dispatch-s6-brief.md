<!-- Written during the spike as the implementer brief; decisions at the top are the manager decisions taken at the time. Kept for report 19 and the S8 read-back. -->
# S6 — well-known `compare` + the core rewrite

**Manager decisions on §4's open questions (binding):**
- O-1: the spec wins — `pub empty : Dict k v`, a constant; `singleton` unconstrained.
- O-2: S6 opens by reading the tree; whichever half of §5.2 S5 did not land is S6's; the `compare` half is S6's in every case; whoever lands a `pub foreign … where` owns the sibling `.js` arity.
- O-3: keep the annotations on Dict's private helpers and write explicit `where` clauses; record the reading in the diary.
- O-4: `max`/`min`/`clamp` stay `number` — out of scope.
- O-5: do NOT add `pub eq`/`pub compare` to `Dict`/`Set`; add `run/DictStructuralEquality.beni` that prints the actual answer, add a §11 row, hand to report 19.
- O-6: fix `deriveOne` (table before step 1) in S6a, with `run/OrderValues.beni` and a `dispatch/` golden.
- O-7: no action; re-run the four witnesses after `core/List.beni` changes and read the diffs.
- O-8: delete `refuseDerived`/`structuralEq` at the end of S6b after confirming `dispatch/UserEqInsideParametric` names the user's `eq` in evidence position and `run/UserEqInsideRecord` is green.
- O-9/O-10: trust the tree; re-grep before each step; skip c1-rewrite §2.5.
- O-11: capture c1-rewrite's list (M1b, M3, M4, M5 R1–R3, M8).
- O-12: replace the `build_test.zig` nested-package assertion with a nested module in the test's own world.
- O-13: the S5 agent is fixing the `core/` project collection now; use it if landed.
- O-14: step 0b (`run/ConstrainedMutualRecursion`) first.
- Split: **S6a then S6b**, committed separately at the S6a boundary.

---

**Base:** branch `spike/static-dispatch` (S5 will have landed on top of `c63ae48` by the time S6a starts; read the S5 commit first).
**Normative:** `docs/design/static-dispatch-spike.md`. Where `plans/static-dispatch-spike.md` or `plans/static-dispatch-c1-rewrite.md` disagrees, the spec wins.
**Line numbers below are `c63ae48`.** `core/Dict.beni`, `core/Set.beni`, `core/List.beni` have not moved since `f466aac` except where S5 touched `List`.

**Working rules:** one implementer builds at a time, no ReleaseFast inside an agent except the final bench, every fail-first proof in a `git worktree` at the base commit — never by stashing.

---

## 1. Exact scope

### 1.1 The `<` family on `compare` evidence — §3.1, §8.3, A.3, A.22

Mostly landed in S4: `primitiveOperator` (`Lower.zig:1808`), `orderTest` (`:1856`), the `.top/.ext/.evidence` arm of `methodCallExpr` (`:1726`), `primitiveValues` (`:1313`). Proof: `emit/ComparisonOperators.js`, `run/OrderingPrimitives.beni`.

Remaining for S6:
1. The `derived`/`ext_derived` arm for ordering origins. `methodCallExpr`'s `.derived, .ext_derived` arm (`:1694-1708`) is A.51's wall; after S6 a derived `compare` target emits `<fn>(<evidence…>, l, r)` then `orderTest`. `typeDispatchExpr` (`:1764-1783`) has the same wall.
2. Retire the wall (`refuseDerived`, `structuralEq`) at the end of S6b — see O-8.
3. `max`/`min` NOT in scope (O-4).

### 1.2 Derived `compare` bodies, per shape — §9 preamble, §9.1–§9.5, §8.5

`Order` at runtime is a bare tag string `"LT"`/`"EQ"`/`"GT"` (all-nullary, `backend.md` §4). A derived `compare` returns those strings; `orderTest` compares against string literals.

Parts contract (§9 preamble) — one `Target` per structural position; inside a body a `primitive` part is the JS operator inline:

| Part target | `CMP(l, r)` |
|---|---|
| `primitive num_compare` | `l < r ? "LT" : l > r ? "GT" : "EQ"` |
| `primitive char_compare` | code points via `codePointOf` (`:1390`), hoisted into `const`s when operands are not names |
| `primitive string_compare` | `String$compare(l, r)` — a call, never `<` (§3.2, A.26); import via `coreValue(.String, .compare, …)` (`:1874`) |
| `top` / `ext` | `M$compare(l, r)` |
| `evidence k` | `$m$k(l, r)` |
| `derived i` | `<name>(<its evidence…>, l, r)` |

Shapes (§9):
- **records (§9.2)** — keyed on sorted field names, one evidence param per field in that order, lexicographic with early return: `const M$compare$r$x$y = ($m$0, $m$1, x, y) => { const o0 = $m$0(x.x, y.x); if (o0 !== "EQ") return o0; return $m$1(x.y, y.y); };` Empty record → `compare$r` returning `"EQ"`. Evidence is a property of the use (A.46).
- **tuples and unit (§9.3)** — keyed on arity, slots `a`,`b`,`c`; `compare$unit` returns `"EQ"`.
- **nominal, all-nullary (§9.4)** — an `$order` table plus `a === b ? "EQ" : order[a] < order[b] ? "LT" : "GT"` in declaration order. `eq` on the same shape is `strict_eq` at the use and has no function (A.18): an all-nullary type produces `$compare` and `$order`, no `$eq`.
- **nominal with payload (§9.4)** — `if (x.$ !== y.$) return order[x.$] < order[y.$] ? "LT" : "GT";` then `switch (x.$)` with the last constructor as `default`; padding slots not compared (A.12); nullary arm returns `"EQ"`; one-constructor type emits no `$order` and no tag test; recursive type calls itself by name.
- **parametric (§9.4, A.20)** — one evidence param per type parameter in declaration order, used or not. `Result x a = Ok a | Err x` ⇒ `$m$0` is `x`'s, `$m$1` is `a`'s; `Ok a` uses `$m$1`. The `dispatch/` `part` lines catch this.
- **`List` (§9.5)** — not derived; `core/List.js` hand-written loop (1.5).
- **excluded** — types reaching a function get neither; gate already in the checker (A.54/A.58).

Emission (§8.5, A.14, A.15): module-level exported `const` arrows named `<Module>$<Type>$compare` / `$order` for nominal and `<Module>$compare$r$x$y` / `$compare$t2` / `$compare$unit` for structural. Nominal ones eager, one per declared nominal type in its declaring module. The pass runs before the declaration loop in two sorted runs: every `$order` table first by name text, then every function by name text. S5 built this pass for `eq`; S6 adds the `compare` arm and the `$order` run.

### 1.3 `String`/`Char` comparators — §3.2, §9.1, A.26

Already emitted by S4 (`compareCharDecl :1350`, `stringCompare :1303`). Remaining: reachable from inside a derived body as parts — the `string_compare` part registers its import from the derived pass; the `char_compare` part threads a `StmtList` for the hoisted consts. §11 records this is correctness over speed; M5 R3 shows the cost.

### 1.4 The `Order`/`Never` eager-derivation gap (not in any plan)

`Solve.deriveOne` (`src/check/Solve.zig:3010`) applies §3.3 step 1 (`if (s.ownDeclNamed(name) != null) continue;`) before §3.2's table. `core/Basics.beni:366` declares `pub compare : number, number -> Order`, so `Basics.Order` and `Basics.Never` get no derived row — but `methodOnApp` (`:2405`) consults `wellKnownTarget` first and hands back `ext_derived Basics.Order compare` → `Basics$Order$compare`, which `core/Basics.mjs` never defines. Invisible today only because the backend refuses derived targets.

Fix (S6a): in `deriveOne`, consult the well-known table before the step-1 exclusion. Fixtures: `run/OrderValues.beni` (`LT < GT`, `List.sort` of `List Order` — S6b — and a record with an `Order` field) and a `dispatch/` golden showing the row in `Basics`.

### 1.5 `core/List.beni` + `core/List.js` — §5.2, §9.5, A.7, A.19, A.50

```elm
pub foreign compare : List a, List a -> Order
    where a.compare : a, a -> Order
```
`core/List.js` gains §9.5's loop: `export const compare = (m0, xs, ys) => …`, a loop not recursion; shorter list is `LT` against a longer one with the same prefix. Sibling arity = evidence count + declared arity (A.7); `Sibling.zig` does not check arity — the `run/` fixture is what catches it. `List.beni:16` module doc count of foreigns changes.

A.50 expires: retire `tests/corpus/check/bad/CompareOnForeignType.beni`; confirm `check/bad/core/CompareOnWrappedForeign` and `check/bad/PrivateForeignCompare/` still hold "a foreign type with no pub compare is refused"; add `check/bad/core/CompareOnForeignNoCompare` if not.

### 1.6 `core/Dict.beni` — §5.3

`pub opaque type Dict k v = Dict (Tree k v)` (`:40-41`: the comparator field goes).

| `c63ae48` | Branch |
|---|---|
| `:60-62` `empty cmp = Dict cmp Leaf` | `pub empty : Dict k v`; `empty = Dict Leaf` — no constraint |
| `:69` `singleton : k, v, (k,k->Order) -> Dict k v` | `pub singleton : k, v -> Dict k v` — no constraint |
| `:80 get`, `:106 member`, `:149 insert`, `:219 remove`, `:393 update`, `:406 union`, `:412 intersect`, `:419 diff`, `:434 merge`, `:534 filter`, `:552 partition` | each gains `where k.compare : k, k -> Order` |
| `:594 fromList : List (k,v), (k,k->Order) -> Dict k v` | `pub fromList : List ( k, v ) -> Dict k v where k.compare : k, k -> Order`; body `List.foldl assocs empty …` |
| `:85 getHelp`, `:165 insertHelp`, `:227 removeHelp`, `:287 removeHelpEQGT` | drop the comparator parameter; `case cmp a b of` → `case a.compare b of`; keep annotations with explicit `where k.compare` (O-3) |
| `:444-445` `cmp = comparatorOf leftDict`; `:453` | delete the `let`; `case lKey.compare rKey of` |
| `:469-471 comparatorOf` | deleted |
| `:478-480 map` | annotation unchanged; `map (Dict tree) func = Dict (mapTree tree func)` |
| `:535-538 filter`, `:553-561 partition` | `(Dict cmp Leaf)` → `empty` |
| `size`, `isEmpty`, `foldl`, `foldr`, `keys`, `values`, `toList` | unchanged |
| `:1-32` module doc incl. `:24-25` | rewritten (1.11) |

`removeHelp` ↔ `removeHelpEQGT` are mutually recursive and both constrained — step 0b.

### 1.7 `core/Set.beni` — §5.4

`:36 empty` → `pub empty : Set t`, body `Set Dict.empty`. `:44 singleton` → `pub singleton : t -> Set t`, body `Set (Dict.singleton value ())`. `:117 fromList` → `pub fromList : List t -> Set t where t.compare : t, t -> Order`. `:128 map : Set a, (b,b->Order), (a->b) -> Set b` → `pub map : Set a, (a -> b) -> Set b where b.compare : b, b -> Order` — argument count changes, hence `run/LibraryArgumentOrder`. `insert`, `remove`, `member`, `union`, `intersect`, `diff`, `filter`, `partition` gain `where t.compare`. `isEmpty`, `size`, `toList`, `foldl`, `foldr` unchanged. Module doc `:1-21` rewritten (the "ordering comes first and the callback stays last" sentence is now false).

### 1.8 `core/List.beni` sort family — §5.5, A.9

| `c63ae48` | Branch |
|---|---|
| `:367-369 sort : List number -> List number` | `pub sort : List a -> List a where a.compare : a, a -> Order`; `sort xs = sortWith xs (\x y -> x.compare y)` |
| `:374-376 sortBy : List a, (a -> number) -> List a` | `pub sortBy : List a, (a -> b) -> List a where b.compare : b, b -> Order`; `sortWith xs (\x y -> (toKey x).compare (toKey y))` |
| `sortWith`, `mergeWith`, `mergeWithHelp` | unchanged |
| `maximum`, `minimum` | unchanged, still `number` |
| `member` | S5's — confirm it landed |
| `:16-33` module doc | rewritten |

Evidence inside a lambda — captured lexically (§8.1, A.31); `run/EvidenceCapture` pins the mechanism.

### 1.9 `Dict.empty` is a constant — §5.3, A.8, §11 (O-1)

### 1.10 `Dict.String`/`Dict.Int` deletion — §5.7

Delete `core/Dict/String.beni`, `core/Dict/Int.beni`, the `core/Dict/` directory. `build.zig:209-226` generates the embedded list from the directory.

Sites at `c63ae48` — 7 import lines, 17 occurrences:

| File | Import | Uses |
|---|---|---|
| `bench/corpus/DictExtra.beni` | `:8` | `:28 :54 :73 :83 :89 :102 :108`(×2) |
| `bench/corpus/FormValidation.beni` | `:6` | `:291 :295` |
| `bench/corpus/JsonCodecs.beni` | `:6` | `:159 :313` |
| `bench/corpus/NotesApp.beni` | `:5`, `:6` | `:63 :283` |
| `bench/corpus/PrettyPrinter.beni` | `:6` | `:261 :267` |
| `bench/corpus/Router.beni` | `:5` | `:158` |

Plus: `core/Dict.beni:24`, `core/String.beni:11` prose; `tests/corpus/check/good/TypeOwnerEdges/_expected.graph:14-19` (six rows disappear); `tests/blackbox/build_test.zig:94` asserts `out/core/Dict/Int.mjs` — replace with a nested module in the test's own world (O-12). `src/js/Emit.zig:836` is a pure string test — leave it.

The 17 ordering arguments → 0 (M8): `core/Dict/String.beni:26,34,42`; `core/Dict/Int.beni:22,30,38`; `core/List.beni:369`; `bench/corpus/DictExtra.beni:47,159`; `FormValidation.beni:204`; `NotesApp.beni:84`; `tests/corpus/run/Dictionaries.beni:14`; `parse/good/DictCache.beni:17`; `parse/good/LongModule.beni:85,90,285,744`. Four survivors keep a comparator parameter: `List.sortWith`, `mergeWith`, `mergeWithHelp`, `bench/corpus/DictExtra.beni:144 toSortedList`.

Do not touch `bench/runtime/c0/`. C1 versions go in new `bench/runtime/c1/` under the same file names (`bench/runtime.mjs --variant=c0|c1`).

### 1.11 Prose that becomes false — c1-rewrite §5

Rewritten: `core/Dict.beni:1-32`, `core/Set.beni:1-21`, `core/List.beni:16-33`, `core/Basics.beni:15-17` and `:19-31`, `core/String.beni:11-12`, `tests/corpus/run/Dictionaries.beni:1-3`, `tests/corpus/run/Sorting.beni:1-3`. Deleted with their files: `core/Dict/*.beni`, `tests/corpus/check/args/DictEmptyMissingComparator.beni`. `docs/design/checker.md` Appendix B not edited (rules 1–2).

---

## 2. Ordered steps, each with its fail-first fixture

Set up once: `git worktree add /tmp/beni-s6-base <base>`, build Debug, run every new fixture there first.

| # | Work | Fail-first fixture | Gate |
|---|---|---|---|
| 0a | Confirm what S5 landed (`List.eq` foreign, `List.member`, derived pass, `emit/DerivedEq*`). | — | read |
| 0b | `run/ConstrainedMutualRecursion.beni` — mutually recursive top-level pair, both annotated with the same `where a.compare`, each calling the other and using `x.compare y`. | itself | `test-blackbox` |
| 1 | Derived `compare` bodies (1.2): the `compare` arm of the derived pass, `$order` tables, two sorted runs, the `derived`/`ext_derived` arm of `methodCallExpr`/`typeDispatchExpr`. | `emit/DerivedCompare` (record, tuple, unit, mixed parts incl. a `String` field and a `Char` field); `emit/DerivedCompareNominal` (all-nullary + `$order`; two-constructor payload with padding; one-constructor; recursive; `Result`-shaped parametric proving `$m$1`/`Ok`); `emit/DerivedEmissionOrder` (interleaving names, tables-then-functions); `run/DerivedOrdering` | `test`, `test-blackbox` ×2 |
| 2 | `Order`/`Never` eager gap (1.4). | `run/OrderValues.beni`; `dispatch/` golden | `test-blackbox` |
| — | **S6a boundary: commit.** | | |
| 3 | `core/List.beni` `pub foreign compare` + `core/List.js` (1.5); retire `check/bad/CompareOnForeignType`. | `run/ListOrdering.beni` (`[1,2] < [1,2,3]`, sort of `List (List Int)`, list of records) | `test-blackbox` |
| 4 | `core/Dict.beni` (1.6). | `zig build test` | `test` |
| 5 | `core/Set.beni` (1.7). | | `test` |
| 6 | `core/List.beni` sort family (1.8). | `run/Sorting` | `test` |
| 7 | Delete `core/Dict/`; `build_test.zig:94`; `TypeOwnerEdges/_expected.graph`. | graph golden loses six rows | `test`, `test-blackbox` |
| 8 | `run/Dictionaries.beni:14` loses `String.compare` (`.expected` byte-identical); `run/Sorting.beni` gains one `sortBy` line (`.expected` gains one line); `run/LibraryArgumentOrder.beni` gains `Set.map`, `Dict.fromList`, `Set.fromList` rows. New: `run/StringOrdering.beni`, `run/DictRecordKey.beni`, `run/DictStructuralEquality.beni` (O-5). | each new fixture | `test-blackbox` ×2; every `.expected` read |
| 9 | `check/args/`: delete `DictEmptyMissingComparator.{beni,diag}`; add `SetMapMissingCallback.{beni,diag}`. `SortByMissingKey.diag` moves (`a -> number` → `a -> b`). | the new `.diag` | `test-blackbox` |
| 10 | `parse/good/DictCache.beni:17`, `LongModule.beni:85,90,285,744` and their `.ast` goldens. | `.ast` goldens | `test-blackbox`, `fmt-check` |
| 11 | `bench/corpus/` — six files of 1.10. | `zig build bench -- --corpus=bench/corpus` | |
| 12 | Prose (1.11). | | `fmt-check` |
| 13 | `bench/runtime/c1/{R1DictString,R2DictRecord,R3Sorting}.beni`, same names and `-- ops:` headers as `c0/`. | `node bench/runtime.mjs --variant=c1` | checksums identical to `c0` |
| 14 | Measurements (§3), spec §11/Appendix A additions, `refuseDerived`/`structuralEq` removal (O-8). | | all three gates |

**Goldens that move**

| Golden | Why |
|---|---|
| `dispatch/UserEqInsideParametric.dispatch`, `dispatch/WhereClauseDerives.dispatch` | `ext_derived List.List eq` → `ext List eq` once `List` declares `pub foreign eq` (module rule beats derivation). A.60's point must survive as the evidence argument to `List$eq` — check, don't just bless |
| `parse/good/DictCache.ast`, `LongModule.ast` | one argument node each |
| `check/args/SortByMissingKey.diag` | `a -> number` → `a -> b` |
| `check/good/TypeOwnerEdges/_expected.graph` | deleted modules' edges |
| `.iface` goldens | none currently mention `Dict`/`Set`/`sort`; any that moves is information |
| `--stage=raw` determinism set | `where` clauses in interface bytes |
| `emit/*.js` | any module now carrying derived functions |
| `bir/ResolveExposed.bir` | does NOT move |
| every `run/*.expected` | unchanged except `Sorting.expected` (+1 line). Any other that moves is a bug in the rewrite |

---

## 3. The C1 corpus production

"Produced by hand" (c1-rewrite §0): no script, no sed. Rules: (1) nothing changes except ordering and equality; (2) a user-supplied ordering stays a value (`sortWith`, `DictExtra.toSortedList`); (3) every comment explaining the comparator convention is rewritten, not deleted. Every golden re-blessed and read.

C0 vs C1 = the S1 worktree (`../beni-s1`, `c870e9a`) vs this one, interleaved per `bench/README.md:60-64`, load average checked, best of 5 after warm-up:

```sh
zig build bench -- --generate=100000
zig build bench -- --generate=100000 --dispatch       # MUST report 0 diagnostics after S6b
zig build bench -- --corpus=bench/corpus
sh bench/churn.sh --corpus=bench/corpus
sh bench/churn.sh --corpus=core --core
node bench/size.mjs
node bench/runtime.mjs --variant=c1 --runs=20 --program=R1DictString --program=R2DictRecord --program=R3Sorting
```

`bench/gen.zig:1178-1186` already generates dot-call `Dict`/`Set` code; S1 recorded 1 682 diagnostics for it. After S6b it must be 0 — the acceptance test. `bench/size.mjs`'s `hand_written` set (`:206-215`) already excludes `List$eq`, `List$compare`, `String$compare`, `Basics$compare`.

M8 is recomputed by grep on the finished tree: 17 ordering arguments → 0, 15 comparator parameters → 4, 7 imports + 17 use sites → 0, 2 core modules deleted.

Results: `plans/static-dispatch-spike-results.md`, append-only, `## YYYY-MM-DD — S6, C1 …`, raw JSON lines verbatim per `### M<n>` then a summary table; cite the C0 rows (`:220` M3, `:293` M4, `:359` M5, `:448` M8), never edit them. M4 reports derived `eq` bytes and derived `compare` bytes as two numbers, never a sum (§11, A.38).

---

## 5. Ownership, not-in-scope, gates

**S6a owns:** `src/js/Lower.zig` (derived `compare` arm, `$order` tables, `derived`/`ext_derived` arms), `src/check/Solve.zig` `deriveOne` only, `tests/corpus/{emit,run,dispatch}/` new fixtures.

**S6b owns:** `core/Dict.beni`, `core/Set.beni`, `core/List.beni`, `core/List.js`, `core/Dict/` (deleted), doc paragraphs in `core/Basics.beni`, `core/String.beni`; `src/js/Lower.zig` (`refuseDerived`/`structuralEq` removal); `bench/corpus/{DictExtra,FormValidation,JsonCodecs,NotesApp,PrettyPrinter,Router}.beni`; new `bench/runtime/c1/`; `tests/corpus/run/{Dictionaries,Sorting,LibraryArgumentOrder}.beni` + new run fixtures; `tests/corpus/check/args/`; `check/bad/CompareOnForeignType` (retire); goldens in §2; `tests/blackbox/build_test.zig` (one assertion); `plans/static-dispatch-spike-results.md` (append); `docs/design/static-dispatch-spike.md` §11 and Appendix A (append rows only — never renumber).

**Not in scope:** S7 return-type dispatch; `Dict`/`Set` own `eq`/`compare` (O-5); `max`/`min`/`clamp` (O-4); removing `equatable` or the A.53 bridge; DCE, `--release`, chunking; stretch items; report 19 and `fast-compiler.md` (S8); `docs/design/checker.md`, `language.md`; `bench/runtime/c0/`; `master`.

**Gates** (blackbox twice):
```sh
zig build && zig build test && zig build test-blackbox && zig build fmt-check
zig build test-blackbox
```
S6b additionally: the bench commands of §3.

**Report format:** scope items each done/partial/not reached with the proving fixture; per new fixture the fail-first evidence; re-blessed goldens with one line each on why; statement that every `run/*.expected` except `Sorting.expected` is byte-identical (S6b); M8 counts; raw instrument lines appended (S6b); decisions taken; anything not reached.

## 6. Size

≈60–70 files total. S6a ~20 files, ~1 session. S6b ~45 files, must land in one commit (the corpus cannot be half-rewritten; `zig build test` is red from the first `core/Dict.beni` line until the last golden is blessed), ~1–1.5 sessions. Dependency is one-way: S6b needs S6a (a rewritten `Dict` needs derived `compare` as evidence for a record key); S6a needs nothing from S6b.

---

## 7. Additions from the S5 report (binding, S6a scope)

S5 landed derived `eq` bodies but could NOT add §5.2's `pub foreign eq` to `core/List.beni`, because of a table defect. S6a therefore gains a checker prerequisite:

- **S6a-0: `Target.ext` (and `Target.top`) gain a `parts` range** (spec §7.1 amendment, Appendix A row). Today `{ p : { x : Int }, q : List Int } == …` writes `part 1 ext List eq` with no parts, and once `List` has a `pub foreign eq … where a.eq`, the emitted call is one argument short. Change `src/check/Dispatch.zig` (`Target.ext`/`top` carry `parts`, `partsOf` covers them), `Solve.zig`'s part resolver (a `top`/`ext` target for a parametric type with a `where` clause gets one part per constrained parameter, same rule as `derived`), `src/dump/dispatch.zig` (print them), and `src/js/Lower.zig` (`partEq`/`partValue` pass them as evidence; `evidenceShapeOk` counts them). Fixture: `dispatch/ExtWithParts` (a user module exporting `pub eq : Box a, Box a -> Bool where a.eq` used inside a record in another module) — fails before with a parts-less `ext` row. Then land `core/List.beni` `pub foreign eq` + `core/List.js` `eq` loop (§9.5) in S6a, and `pub foreign compare` in S6b as planned; `run/ListMemberEq` and the blackbox scenario "a list whose elements have an eq of their own is refused until List gets one" flip to success.
- **§8.0 deviation to record:** `Lower.Input` now carries `types: *const Types` as a name/declaration service (S5). Add the Appendix A row in S6a.
- **`err` for concrete positions** (`Ok 1 == Err "a"` writes `err` for the `x` part because the argument's information arrives after the part is written): S6a fixes it in `Solve.zig` if the fix is local (resolve parts after both operands unify), else records it in §11 and keeps `dispatch/ErrParts` as the pin. Decide after reading the code; report which.
- 1.4 (`Basics$Order$compare` has no row) is confirmed by S5: `dispatch/Primitives` shows `site 53 0 ext_derived Basics.Order compare` while no row exists. S6a fixes it as planned.
- A.53's bridge: keep it; its `number` half goes with S6b's core rewrite only if nothing in core still reaches `<` through a `number` rigid (S5 verified `Basics.abs/max/min/clamp/compare`, `List.repeatHelp/rangeHelp/takeHelp/drop` still do — so it stays through S6 too; O-4 stands).

S6a ownership therefore adds: `src/check/Dispatch.zig`, `src/check/Solve.zig` (part resolver + `deriveOne`), `src/dump/dispatch.zig`, `core/List.beni` + `core/List.js` (the `eq` half only), the spec §7.1 text and Appendix A rows (append only).

## 8. Naming decision from the S5 fix pass (binding)

Synthesised nominal bases use a double separator: `<Module>$<Type>$$eq`, `<Module>$<Type>$$compare`, and the S6 `$order` table is `<Module>$<Type>$$order`. Reason: `Shapes$Box$eq` collided with module `Shapes.Box`'s `pub eq`. Structural bases (`eq$r$…`, `compare$t2`, …) are unchanged. §8.5 and an Appendix A row record it; S6a follows it for `compare` and `$order`.
