# Type-directed points-to — review of #464's diagnosis and a plan

Part of #464 (PR #485, branch `pts-field-summaries`, at `223d63b88`). Written 2026-10-20 after reading
`src/js/Spec.zig`, `core/Result.beni`, `core/Schema.beni`, `core/Js.beni`, `src/check/Module.zig`,
`src/js/Lower.zig` and `backend.md` §3, §9. Measured on dagon (x86-64 Linux, ReleaseFast,
`build --release --no-cache --jobs=1`). Nothing here is built. Rule 1 applies: the decisions in §3
come first.

## 1. Verdicts

### Claim 1: `Result.withDefault` merges every widget model, and the host value makes the sets escape. **Confirmed**, with one correction

- Every widget has `replace state model = Result.withDefault (Json.decodeValue state) model`. It
  lowers to `Result$withDefault(Schema$validShape(shape, state$1), model$2)` (dev output,
  `dist/Widget/W64.mjs:114`).
- `withDefault` reads `result` twice (`result.$` and `result.a`), so `smallOf` sets `first[0] =
  false` (`Spec.zig:5111`, `r == 1 and firstUse`). `inlineSmallAt` refuses a non-atom argument
  whose parameter is not read exactly once and first (`Spec.zig:5389`). `inlineOne` takes only a
  function mentioned once (`Spec.zig:5765`), and `withDefault` has 64 mentions. The correction: the
  call is refused because the parameter is read twice, not because the argument is a call. A call
  read once would be inlined.
- The host value: `validShape` returns `Ok (fromHost x)`, where `fromHost = Js.to` and `x` comes from
  the JavaScript `shapeRun` (`core/Schema.beni:3505-3508`, `438-439`). So `result.a` is `top`. It
  reaches `withDefault`'s return var through `return value`, and `makeTop` escapes every site that
  var holds (`Spec.zig:8524-8546`). `$default` and the return var therefore merge all 64 models.
  Before `top` arrives, the merged set travels back out through every `replace` result into
  `Main`'s model and into every widget's update arms.
- **Measured.** I rewrote every `replace` as `case Json.decodeValue state of Ok v → v; Err _ → model`.
  N=64 went from **6.41 s / 1.07 GiB to 1.06 s / 366 MiB**. The variant still spends about 55% of
  its samples in `Pts` (`copy` 20%, `joinNow` 12%, `enqueue` 9%, `difference` 7%, mostly under
  `load`), so a second merge of more than 48 sites remains somewhere. With `max_sites = 48` both
  programs take 0.45–0.47 s, and the output is byte-identical to the cap of 1 000 for each.
  I did not check the "448 parameters × 270 sites" figure, which would need instrumentation.

### Claim 2: filter by type at polymorphic calls. **Partly confirmed.** The idea is sound if it is restated; the mechanism as proposed is neither sufficient nor the cheapest

(a) **Soundness.** Parametricity does not hold inside the wall:

- `Js.to : Value → a` and `Js.from : a → Value` compile to nothing (`core/Js.beni:42-47`). Core
  and platforms therefore can and do make an `a` out of anything (`fromHost`). Their contract
  says "the caller answers for the type".
- `Js.Value`, and every `foreign type`, is a concrete type that holds sites of other types after
  a `Js.from`. Filtering a var of type `Js.Value` by its type would drop live flows.
- Unboxing (`backend.md` §4, around line 6105): a one-constructor, one-field type is its field,
  so a site of type `R` is held at type `Wrap`. The key must be the representation, not the beni
  type.
- Evidence parameters, derived `eq`/`compare` bodies, schema-compiled parsers, markup lowerings
  and every node that `Spec`'s own rewrites make have no beni type.
- Records are structural and aliases transparent, so two widgets with the same model shape share
  a key. That is no regression, but it is no separation either.
- `Debug` is refused under `--release`. `Record.copy` and `List.js` results are host values (`top`).

The filter is sound when it treats all of the above as **wild**: a wild site passes every filter,
and a wild var filters nothing. It also needs `Js.to`'s contract to become an invariant that the
optimiser relies on (decision D2).

(b) **Feasibility.** `backend.md` §3 (line 404) says **"the backend still sees no types"**. Lowering
reads only the dispatch table (`Lower.zig:198-225`). The precedent is *Item 4*'s field-interference
artifact, which was specified and then declined (§9, around line 5744). The checker can supply
types: `Check.Module.local_type` (one per Bir local) is built in every run. `inst_type` (one per
instruction) is built only under `keep_stores`. Both are freed with the module's store
(`Module.zig:150-155`). Two more facts constrain the design:

- A module loaded from the cache, and the checked core shipped in the binary, are never re-checked.
  Keys must therefore travel in the cache entry (a version bump), or such modules must be wild.
  Otherwise the output would depend on whether the cache was warm.
- `Lower.localName` (`Lower.zig:4375`) is the one place a Bir local becomes a `JsIr` name, so a
  per-name key column is cheap to fill.

(c) **The filter in `Pts`.** The proposal filters at polymorphic calls by the caller's
instantiation, and that is not enough. `withDefault`'s `$default` and return vars are shared by
every caller (no context sensitivity), so they still hold 270 sites, and `top` still escapes them
all. A per-call filter on the way out is equivalent to a simpler rule, the SPARK-style
declared-type filter: **a var whose static type is closed (no type variable, no row variable,
nothing wild) holds only sites with a matching key.** That covers `W64.replace`'s return var
(`W64.Model`), every concrete local and parameter, and the parameters of lambdas made in concrete
code. No call needs an instantiation at all. Implementation:

- In `joinNow` (`Spec.zig:8568`), where every join, copy and drain lands, filter `val.sites` by
  `allow[v]` before `difference`.
- `Site` records its key at `siteOf` (`Spec.zig:8998`).
- The filter is a fixed intersection, so it is monotone and distributes over union. The least
  fixpoint stays unique, and `expectSame` needs no change.
- One rule must change: `summaryOf` and `linkSummaries` rely on Σ(A∪B) = Σ(A) ∪ Σ(B) along a copy
  edge. Across an edge into a stricter var, link summaries only when `allow[to]` is wild or equal
  to `allow[from]`. Otherwise fold the sites one by one, which costs precision and not soundness.

(d) **Generic `List`, `Dict`, `Cmd` and `Html` in TEA apps.** **Partly.** Sites made inside generic
code (`List.map`'s result array, `Ok` in `Result.map`, Dict nodes) have open types and stay wild.
Their property vars still hold every caller's values, one shared var each. What is cut is the
outflow: a read in concrete code lands in a concrete var and is filtered there, and a callback
made in concrete code has typed parameters, so `f(x)` inside `map` no longer feeds other callers'
elements into `f`. The work drops from (callers × sites) at every consumer to one union per
generic var.

### Claim 3: once the merge is gone, `specialise` is structural passes plus repeated analyses. **Partly confirmed**

With `max_sites = 48`, N=64 takes **0.45 s / 215 MiB**, with output identical to the cap of 1 000.
`specialise` takes 397 of 431 ms of `emit`, with `spec_analyses` = 6, `spec_points_to_runs` = 6,
`spec_passes` = 3 and `passes_capped` = 1. The flat profile:

| Share | Where |
|--:|---|
| 20% | `pushChildren`, of which 11.9% is `inlineOnce → preorder`, 4.5% is `scalarReplace → srList` and 3% is `constructors → onlyInspected` |
| 7% | `srList` |
| 5.7% | `placeExpr` |
| 5.4% | `inlineScan` |
| 4.5% | `onlyInspected` |
| 4.3% | `namedIn` |
| 4.1% | `preorder` |

Summed by category: `Pts.*` 7.4%, facts 1, 2, 4 and 5 (`Spec.combine`, `eval`, `analyse`, …) 3.5%,
other `Spec` 65%, rest 24%. So the time is the structural passes, as claimed. But "from scratch
about 7 times" is a minor share, about 11% at the cap. And *The combined solver* keeps the
structural passes "unchanged" (step 6, §9, around line 8020), so it buys about 10% here. The 65%
needs its own fix: incremental `preorder`, `srList` and `onlyInspected`, keyed by `Mod.version`.

### Claim 4: PR #485's code. **Sound as far as I can find.** Four weaknesses and one perf defect

- **Copy edges under a guard** (`maybeNarrowed`, `Spec.zig:8834`; used at 9704, 9725, 10367): sound.
  A copy carries the un-narrowed set, which is a superset, and narrowing removes only `nul`/`undef`.
  The two modes agree: `byUnits` refuses a copy under any guard in view, and `byConstraints` under
  any guard the recording noted. A dead guard narrows nothing either way.
- **`uncapped` load vars** (`newLoad`, 9139): sound, because `top` sits beside the sites and every
  consumer that joins the value turns `top`. But it removes the `max_sites` bound that §9
  *Values* uses to keep the analysis linear. A cell can grow to every site, one new slice per
  batch, which is O(n²) in the worst case.
- **Dead summaries**: sound. Only the `top` var's own summary dies. Successors die when `top`
  reaches them along their edges, and a spread of a `top` var writes `top` through `from.top`.
- **`expectSame.sameVal` relaxed** (9339): the tolerance covers every `top` node value, not only
  load cells. It is harmless, since the consumers that walk a `top` value's sites (`call`) touch
  only escaped sites, whose facts are not compared. Two limits matter more:
  - The order check runs only on programs of at most `max_checked_nodes` = 1 500 nodes (9270). It
    never sees `SpreadWide` or the dashboard.
  - The reference walk (`byUnits`) uses the same `copy`, `summary` and `load` machinery. The check
    proves order independence of the new transfer functions, not their equality with the old ones.
    Only goldens and run hashes guard that.
- **The escaped-site path in `load`** (9099): sound. It links an escaped site's property values
  (which `propagate` escapes) and joins `top`. Two differences from `read`:
  - `load` creates `Prop`s on escaped sites (`p.prop`), where `read` does not. That wakes
    `prop_deps`, feeds summaries and sets `changed`. It is extra work, not a wrong fact.
  - **Perf defect**: `done = obj.sites` replaces the set instead of joining it. Two reads share one
    cell per (var, property). One can be evaluated with a stale, smaller input (its ident constraint
    is still waiting), which shrinks `done`. The next evaluation then relinks sites, appends `li` to
    `Site.loads` again and asks `hasEdge` again. `copy`/`hasEdge`/`edge_set` lookups under `load`
    are the largest profile entry in the nowd variant.
- **Recursion and memory**: `summaryOf` recurses over predecessors transitively, and
  `linkSummaries → copy → linkSummaries`, `setUnknown` and `setAnyWritten` recurse over successors.
  So the depth is a copy chain's length, although the PR text says "never by recursion" of joins.
  `edge_set.put` runs for every edge, even though lookups use it only when both lists exceed 8.

## 2. What the fix should be

The parametric-instantiation proposal is replaced by **representation-keyed declared-type filtering
at vars**:

- a **key** per closed type, by representation;
- **wild** for anything open, foreign, in the boundary or made without a type;
- keys carried from the checker through `Lower` as two `JsIr` columns;
- the filter applied once, in `joinNow`.

`withDefault`'s own vars still merge, but the merge stops at the first concrete binder. That keeps
the N=64 work proportional to the program. The structural passes (claim 3) are a separate track.

## 3. Owner's decisions (before slice 3)

- **D1** — Amend `backend.md` §3. `Lower.Input` gains a *type-key artifact*, read only by fact 3,
  never by a lowering decision. This reverses "the backend sees no types" in one named place, and
  Item 4's artifact was declined on similar grounds.
- **D2** — Make `Js.to`/`Js.from`'s "the caller answers for the type" (`core/Js.beni:42-47`) an
  invariant that `--release` correctness relies on: a wrong `Js.to` in core or a platform may then
  miscompile, not only mistype. The alternative is to make wild every type reached by a
  `Js.from`/`Js.to` instantiation. Unboxing already computes that boundary set.
- **D3** — Still open from #464, and independent of this plan:
  - the cap: §9's 48 against the interim 1 000 (#442). At 48 this build takes 0.45 s today, with
    byte-identical output.
  - whether `inlineSmallAt` may bind a parameter that is read more than once to a fresh `const`
    where the call stands in a `return` or `const` initialiser. That alone takes N=64 from 6.4 s
    to about 1.1 s.
- **D4** (optional, for slice 5) — Split `top` into "may be a host value", which keeps its sites
  as load cells do, and "forgot its sites", which escapes them. This changes §9 *Values*'s "`top`
  implies the other three and its sites escape". With the filter it would stop `withDefault`'s
  host result from escaping every model. Without the filter it makes the merge worse.

## 4. Slices

Each slice is one PR with its own issue. `zig build gates` must be green on dagon.

### Slice 0 — Measure the sets (no output change)

- **What.** `--self-profile` counters `spec_pts_max_set`, `spec_pts_set_words` (site words
  allocated), `spec_pts_edges` and `spec_pts_load_cells`, plus the node of the largest var under a
  hidden flag.
- **Test.** The existing self-profile black-box test lists the new counters. Every golden stays
  byte-identical.
- **Measure.** N=1, 4, 16, 64, the nowd variant and `SpreadWide`. Name the merge that is left in
  nowd (1.06 s at cap 1 000, against 0.47 s at 48).
- **Risk.** None.

### Slice 1 — Repair PR #485's machinery (byte-identical)

- **What.**
  - `Load.done` becomes the union of what it was and `obj.sites`.
  - `load` never makes a `Prop` on an escaped site; it joins `top` and links nothing for it.
  - `edge_set` is filled only once a list passes 8 entries.
  - `summaryOf`, `linkSummaries`, `setUnknown` and `setAnyWritten` become loops over a worklist.
- **Tests.**
  - A small-stack unit test: a chain of 10 000 `const` copies plus a spread, which today recurses.
  - A corpus reduction of at most 1 500 nodes, `emit/release/inline/SpreadEscapes`: a summary,
    a shared load cell and a site that escapes after it was linked, so that the safety build's
    shuffled-order check covers the new machinery.
  - Goldens and run hashes unchanged.
- **Measure.** Instructions on `SpreadWide` and the time of nowd. A fall is expected, since
  `copy` under `load` is the top profile entry there.
- **Risk.** Low.

### Slice 2 — Type keys from the checker (no output change)

- **What.**
  - In `Module.zig`, before the store is freed and only for a `--release` build, compute a key for
    each Bir local and for each allocating instruction: record literal or update, constructor
    application, tuple, list literal, lambda (whose key is its result type).
  - A key is the canonical form of a closed type: nominal `TypeId` and argument keys, records by
    sorted (field symbol, key), functions, tuples. A key is `wild` when the type holds a type or
    row variable, a `foreign type`, `Js.Value`, or anything of the schema `Value`.
  - Keys are content hashes, or are interned at the merge in module order, so ids never depend on
    threads (rule 5).
  - Keys travel in the cache entry (a version bump, schema.md A.6's table). Core and platform
    modules are wild in v1 (the checked core).
- **Test.** A dump of the keys, corpus-tested like the other stages (`dump/typekeys/`). Cases: an
  alias equal to its structure, an extensible record (wild), a polymorphic local (wild),
  `Js.Value` (wild), a closed lambda, and a cached module's keys equal to a fresh check's (a
  warm/cold pair in `incremental_test`).
- **Measure.** Check time on `bench/corpus`, which must cost no more than 2% of `check`. Also
  cache bytes.
- **Risk.** Memory of keeping one key per local; cache format churn.

### Slice 3 — Representation keys in `JsIr` (no output change; needs D1 and D2)

- **What.**
  - `Lower` maps a type key to a representation key:
    - an unboxed type is its field's key (`CtorRep.unboxed`);
    - a type in the boundary is wild (if D2 takes the alternative);
    - `Bool`, nullary-only types and primitives make no site.
  - Two columns: `JsIr.name_key` (filled in `localName`, `Lower.zig:4375`; `Lift` gives a lifted
    arm's parameter its local's key) and `node_key` (object, array and arrow nodes).
  - In `Spec`, `Mod.setNode`, `copyNode` and `foldTo` clear a node's key, and `addName` and
    `freshLocal` are wild. `Copy` keeps the keys only when it copies a body whose declaration has
    no type variable.
- **Test.** Every `emit/` golden is byte-identical, run hashes are unchanged, and the
  determinism test passes.
- **Measure.** `JsIr` bytes and lowering time.
- **Risk.** A stale key after a rewrite, so every mutator must clear one. A safety-build assertion:
  a keyed node is still an object, array or arrow.
- **As built (2026-10-20, #490).** `js/RepKeys.zig`, the two columns, `Spec`'s clears and
  `Copy`'s rule, the assertion in `JsIr.nodeKey` read at `Pts.siteOf`; `backend.md` §9's *As
  built* note has what the specification did not foresee (a `NameIndex` is shared by two
  declarations' locals; the artifact keys no declaration). Every golden, run hash and the
  determinism test unchanged. `bench/corpus` (`--release --library --jobs=1`, ReleaseFast):
  with a dense node column, `JsIr` 478 162 bytes → 587 858 (+23 %) and lowering 3.21 ms → 3.36 ms
  (median of 21, quiet machine); with `node_keys` sparse (a row per keyed allocation),
  478 162 → 493 218 (+15 056, +3.1 %, of which the dense `name_key` is most), and the whole build
  381.1M → 382.5M user instructions (+0.36 %, `perf stat`, five runs; the host was too loaded for
  wall times then). The merge costs about 0.06 ms.

### Slice 4 — The filter

- **What.**
  - `VSet.allow` is set from `name_key` for locals and parameters and from the arrow's `node_key`
    for `ret`. Sites, properties, `any`, summaries, loads and globals are wild.
  - `Site.key` is set from `node_key` at `siteOf`.
  - `joinNow` drops each site whose key is neither `allow` nor wild.
  - The summary-link rule of §1 claim 2 (c).
  - `backend.md` §9 gains *Amended — declared-type filtering*, with its soundness argument and the
    list of wild sources.
- **Tests. Soundness**: `run/` fixtures, built twice (dev and `--release`), each of which
  miscompiles if a live flow is filtered away:
  - an unboxed type through a generic function (extend `run/UnboxedTypes`);
  - a model through `Js.to`/`Js.from` in `tests/platforms/toy`;
  - an extensible-record function updating two record types;
  - a `where a.compare` helper over two records;
  - `Debug.log` under `--allow-debug`;
  - the dashboard's `withDefault (Json.decodeValue s) m` with two models, one field of which only
    the host's JSON supplies.
- **Tests. Precision**: `emit/release/inline/TypedMerge`. Two models pass through one
  non-inlinable generic helper; a field read only on model A stays on B today (B's prop is marked
  read through the merged var) and is dropped after. It fails before and passes after.
- **Goldens.** The `emit/release/` goldens that change are listed in the PR. Each must be a shrink
  or the same size. Run hashes are re-recorded.
- **Measure.** N=64 base and nowd at cap 1 000 (target: under 0.6 s with no cap change),
  `SpreadWide`, and bench/corpus brotli bytes.
- **Risks.** An unsound key is a silent miscompile, which is why the wild list is generous and the
  fixtures are run-level. Shape-equal records still merge.

### Slice 5 (optional) — Filters at nodes and properties, and D4

- **What.** Filter a member read's or call result's value by the instruction's closed type
  (`inst_type`), for `f(x).p` and `{...f(x)}`, and filter a site property's var by its field's key.
  If D4 is taken, the `top` split.
- **Test.** Precision fixtures, as in slice 4.
- **Measure.** Corpus brotli.

### Slice 6 — Structural passes (a separate issue; claim 3)

- **What.**
  - Cache `preorder` per (module, top-level statement, `Mod.version`). `inlineOnce` asks for it
    once per candidate: 12% at the cap.
  - Make `srList` and `onlyInspected` incremental.
  - The 6 analyses go with *The combined solver* (§9), about 10% here.
- **Test.** Byte-identical, plus a `test-perf` scenario on N=64.
- **Measure.** `specialise` at N=64 with the cap at 48: today 0.40 s; target under 0.15 s.
