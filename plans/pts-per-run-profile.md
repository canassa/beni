# Where one fact-3 run spends its time (issue #464)

*Measurement only. No code change, no PR. 2026-10-21, master `d74161189`, dagon (Ryzen 9 5950X,
TSC 3.39 GHz), ReleaseFast, `build --release --no-cache --jobs=1`. Committed with #563, which acts on causes 2 and 3.*

## Method

Three compilers were built from `d74161189` in the throwaway worktree `~/src/github.com/canassa/beni-prof` on dagon:

1. **Plain ReleaseFast** (`zig-out/fast`): wall time, peak RSS and `--self-profile`.
2. **ReleaseFast with frame pointers** (`zig-out/fastfp`, `.omit_frame_pointer = false` in
   `build.zig`, not committed). Profiled with `perf record -e instructions:u --call-graph fp`, then
   `perf script`, then `~/prof-pts/attr.pl`. Each sample is charged to the first "owner" frame above
   the leaf, the way an exclusive timer would charge it: `joinNow`/`drain` → join, `copy`/`hasEdge` → copy,
   `foldSite` → fold, and so on. The leaf group is kept as a second axis (sets helpers,
   `KeyMap`, the pending list). **All the instruction shares below come from this build.**
3. **ReleaseFast with counters** (`zig-out/fastprof`, a scratch `Spec.zig` saved as
   `~/prof-pts/SpecProf.zig`). It has rdtsc category switches and about 60 counters, and it
   prints one report per fact-3 run (`PTSPROF` lines in `~/prof-pts/*.prof4.txt`).
   The rdtsc switches cost 40–64% overhead, most of it in the cheapest and most frequent calls
   (`setOf`, `difference`), so **this build's cycles are used only for per-run proportions**. Its
   counts are exact.

Baseline, plain build:

| program | wall | peak RSS | `specialise` | instructions:u | `spec_pts_edges` |
|---|---|---|---|---|---|
| N=16 (`n16-s1`) | 0.11 s | 55 MB | ≈0.08 s | — | — |
| N=64 no-`withDefault` (`nowd`) | 0.57 s | 198 MB | 0.471 s | 3.73 G | 680 243 |
| N=64 (`n64-s1`) | 2.12 s | 623 MB | 2.061 s | 10.2 G | 7 541 006 |

Each build runs 6 analyses (`spec_analyses`), 6 fact-3 runs, 10 sweeps per run and 3 passes.

## The headline: N=64 is two runs, not six

The per-run table shows that runs 1–4 of N=64 cost the same as `nowd`'s runs, edge for edge.
**Runs 5 and 6, the solves after structural passes 1 and 2, hold 7.09M of the build's 7.54M
edges and about 7.4G of its 10.2G instructions.** "7.5M edges over 6 runs" is two degenerate runs
on top of four ordinary ones.

### Per run: N=64 (`n64-s1`)

ms is estimated: the run's share of the counting build's fact-3 cycles × the plain build's fact-3
time (1.93 s). Runs 1–4 are scaled as `nowd`'s are.

| run | after | edges | joins (no-op) | folds | vars | sites | cons | summaries | ≈ms | ≈instr |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | round 1 | 114 893 | 888 638 (485k) | 7 227 | 61 934 | 3 339 | 34 725 | 2 042 | ~70 | ~0.42 G |
| 2 | round 2 | 114 056 | 882 057 | 7 191 | 59 319 | 2 863 | 29 161 | 1 857 | ~70 | ~0.42 G |
| 3 | round 3 | 114 056 | 882 056 | 7 191 | 59 318 | 2 863 | 29 160 | 1 857 | ~64 | ~0.38 G |
| 4 | pass 0 | 111 921 | 883 307 | 6 907 | 56 369 | 2 318 | 26 967 | 1 320 | ~65 | ~0.39 G |
| 5 | pass 1 | **3 393 304** | 5 124 944 (4.76M) | **113 401** | 88 059 | 2 062 | 25 625 | 1 286 | ~780 | ~3.5 G |
| 6 | pass 2 | **3 692 776** | 5 609 722 (5.24M) | **123 508** | 87 505 | 1 973 | 24 955 | 1 286 | ~880 | ~3.9 G |

### Per run: N=64 without `withDefault` (`nowd`)

| run | edges | joins (no-op) | adding joins / sites added | folds | ≈ms | ≈instr |
|---|---|---|---|---|---|---|
| 1 | 115 363 | 882 924 (485 k) | 398 k / 404 k | 7 291 | ~72 | ~0.42 G |
| 2 | 114 526 | 877 906 | ≈395 k / 401 k | 7 255 | ~71 | ~0.42 G |
| 3 | 114 526 | 877 905 | same | 7 255 | ~64 | ~0.38 G |
| 4 | 112 342 | 880 919 | ≈397 k | 6 971 | ~66 | ~0.39 G |
| 5 | 111 930 | 677 381 | ≈392 k | 6 971 | ~53 | ~0.32 G |
| 6 | 111 556 | 665 321 | ≈392 k | 6 971 | ~52 | ~0.31 G |

Other sizes of one `nowd` run: about 56–62k vars, 2.0–3.3k sites (909 escaped), 24–25k site
properties, 25–35k constraints, 46–60k dependency records, 1.3–2.1k summaries, 1.3–2.0k load
cells and 4–6k set-table entries. In a run the program has 50–69k IR nodes. `held_words`, the
total size of the final site sets, is 280–285k.

### Where the instructions go (plain build, % of the whole build)

| category | nowd | n64 |
|---|---|---|
| **join worklist** (`joinNow`/`drain`/`enqueue` and what they call) | **47.7** | **36.2** |
| — set-table helpers under it (`setOf`, `difference`, `unionSets`, `intern`, `filterSites`, `KeyMap(SetHash/SetOpKey)`) | 28.7 | 14.3 |
| — `pending` push/pop | 8.4 | 9.3 |
| — `joinNow` itself | 7.6 | 11.0 |
| — `linksAcross` | 1.6 | 0.9 |
| **copy** (`copy`, `hasEdge`, `indexEdge`, `edge_set`) | 3.9 | **37.1** (`edge_set` probes 23.6, `hasEdge` 9.7) |
| summaries: `summaryProp` / `marks` / `summaryOf` / `foldSite` / `linkNow` | 3.1 / 2.2 / 0.8 / 0.5 / 0.1 | 5.9 / 1.5 / 0.2 / 3.6 / 0.0 |
| first walk (`walkStatements`, its own work) | 4.4 | 1.4 |
| re-evaluation (`evaluate`, its own work) | 2.9 | 1.6 |
| `call` / `makeTop` / `load` / `propagate` / `escape` / reset | 0.8 / 0.5 / 0.4 / 0.1 / 0.1 / 0.2 | 0.4 / 1.0 / 0.1 / 0.0 / 0.2 / 0.1 |
| **fact 3 total** | **≈68** | **≈89** |
| Spec, other: structural passes / facts 1–2 sweeps / `rewrite` / `prune` / other | 11.0 / 3.8 / 1.3 / 0.6 / 0.4 | 3.8 / 1.3 / 0.6 / 0.2 / 0.2 |
| outside `specialise` (frontend, checker, ownership, emit) | 15.0 | 4.7 |

**What starts the join work.** The first owner frame above the join machinery:

| started by | nowd | n64 |
|---|---|---|
| a `join` in `combine` (object properties, arrays, non-name spreads) | 33.2 | 16.3 |
| a `join` in `effect` (bindings, assignments, returns) | 10.2 | 11.9 |
| a new copy edge's first enqueue | 3.4 | 4.0 |
| `call` | 0.8 | 3.7 |

A drain runs at the end of the join that starts it, so the cascade it propagates along the
copy edges is charged to that join.

**Phase.** Of the fact-3 instructions, `evaluateWaiting` takes 42% of the build for `nowd` and 80%
for n64. The first walk takes 25% and 9%.

**Re-evaluations by node, `nowd` run 1** (count / unchanged / inclusive Mcyc in the counting
build): `object` 2 054 / 2 054 / 249, `call` 8 672 / 6 148 / 24, `ident` 16 790 / – / 3.5,
`member` 8 419 / 690 / 2.8, `const_decl` 4 737 / – / 12. An object's value never changes, since it
is its own site. Its re-evaluation re-runs the property joins and the spread copies, and that is
where 58% of the run's cycles start. For n64 in runs 5–6, the inclusive cost of the
`const_decl` re-evaluations is 2.68G and 2.76G cycles: these are the member-read bindings of
cause 1.

## The top five causes

### 1. N=64 runs 5–6 fold into summaries that are dead or escaped (≈ 75–80% of the N=64 build)

**Evidence.** In run 5 the new copy edges come from `foldSite` (3 085 217), from `evaluate` (172 706,
the spreads' copies) and from the marks (110 913). By kind of the edge's two ends, run 5 has
3 216 635 edges from a site's property var to a summary's property var (`4>7`) and 112 712 from a
site's `any` to a summary's `any`. Run 6 has 3 506 374 and 122 819.

**At the end of the run, 3 278 151 of run 5's 3 393 304 edges point into summaries whose owner var is
`top`, and every one of those summaries is dead, escaped or unknown.** Run 6 has 3 577 997 of
3 692 776. That is 97% of each run. Through a dead summary a spread copies nothing, and a read
through an escaped one is `top`. These edges and the joins they carry (3.35M of run 5's copy
first-enqueues are no-ops) feed nothing a fact reads.

**Which bindings.** Fold edges by why the site was folded, runs 5 and 6:

| reason | run 5 | run 6 |
|---|---|---|
| a direct join into a `const` whose initialiser is a **member read** (`effect`, `join(target, vals[value])`) | **2 493 994** | **2 980 349** |
| a copy edge across a stricter filter (`linksAcross` false) | 478 989 | 261 191 |
| a call argument that is not a name | 72 665 | 80 345 |

The largest summaries hold 190–202 merged widget-model sites, have 78 properties and are read
whole (by a spread), so each has 14.8–15.8k in-edges. Their owners:

- locals of the lifted `update` arms in widget modules: module 60 at offsets 638, 723, 787, 851,
  913 and 976, and module 63 at 1123, 1512 and 1800. Each owner has a closed filter, but the
  merged sites are wild, so the filter keeps them. The owner now holds 0 sites and is `top`, which
  means it became `top` after its summary had folded.
- locals of `main`'s statement in `Main.beni` (offset 1969, the `browser-inline` handler code).
  These are `top` and uncapped and keep their 202 sites.

There are 609 summaries with 100 folds or more, holding 111 681 of run 5's 113 401 folds.
`edge_set` grows to 3.27M and 3.57M entries, because both ends of these edges have long lists.
That is why `KeyMap` probes are 23.6% of n64. `foldSite`'s duplicate scan over a site's
`summaries` list reads 33M and 36M words in runs 5–6, against 0.24M in `nowd`.

**Overlap with #562.** This is the case #562 is fixing, the member-read binding that folds instead
of composing, and #562 should take most of it: **≈ 5.5M of the build's 7.54M edges, and with them most
of runs 5–6.** The remedy below is a separate one, and it also covers the 0.74M edges that cross a
filter and the 0.15M from arguments that are not names.

**Structural remedy, as the design allows.** A summary that will be dead or escaped by the fixpoint
should never be filled. Two exact levers, each a change of order or laziness, with no fact
changed:

- **`top` before sites.** In `pending`, a batch whose flags make the target `top` (capped:
  `makeTop`; uncapped load-cell bindings: the `top` flag) is taken before any site batch. Today
  `pending` is a LIFO stack of `(var, batch)`, so a site batch can fold 190 × 78 property edges
  before the `top` that kills the summary arrives. Under *The worklist*, any fair order reaches the
  same least fixpoint, so ordering `top` first is exact.
- **Fold lazily.** A summary's per-property copy edges for a site are made only when a consumer that
  reads them, a spread or a load cell, is evaluated, and not on every `joinNow` into the owner.
  Then a dead summary makes no edges at all.

With #562's composing bindings, N=64 should fall to about `nowd`'s cost: **2.1 s → ≈ 0.55 s**
(−1.55 s, −75%). That is consistent with runs 5–6 costing what runs 1–4 do.

### 2. The set table's lookups on every join (28.7% of `nowd`, 14.3% of n64)

**Evidence, per `nowd` run.** 1.18M `setOf` calls, 96% of which are `by_slice` hits: hashing a
slice's address only to recover an id the caller held a moment before. 858k `difference` calls,
of which 296k are fast and 291k answered by `containsSites`. 320k `unionSets`, of which 84% hit
the `ops` memo, so each is one hash probe for nothing new. 271k `differenceSets`, 99% memo hits. One
adding join does `filterSites`, `difference` (two `setOf` and an `ops` probe), `setOf(added)`,
`setOf(old)` and `unionSets`, which is 5–6 hash probes for **1.01 sites on average**. That works out
to about 300–340 instructions per join.

**Remedy.** Carry the `SetId` in `VSet` and `Val`, so that `sites` is read from the id, and key every
operation by ids. `by_slice` and `sliceKey` go away. This is what *Cells* already specifies
(`set: []SetId`, `done: []SetId`).

Add a fast path for a one-site batch: a binary search for membership, and the union taken from the
memo without the difference. Answer `difference(batch, old)` with `containsSites` before any id is
made, as already happens, and when the batch's id equals `old`'s, answer without any work.

**Estimate.** The per-join cost roughly halves: **≈ −15% of `nowd` (≈ −80 ms), ≈ −7% of n64** before
cause 1 is fixed, and more after.

### 3. Site-at-a-time propagation on a LIFO worklist (the join count itself)

**Evidence, `nowd` run 1.** 882 924 joins over 115 363 edges, 7.7 joins per edge.

| join path | joins | no-ops |
|---|---|---|
| along a copy edge (`via` 1) | 693 957 | 325 718 (47%) |
| a new edge's first enqueue (`via` 3) | 115 363 | 104 985 (91%) |
| a `top` passed on by `makeTop` (`via` 4) | 42 572 | 39 937 (94%) |
| direct | 30 239 | 10 471 |

**About 398k joins add something, and they add 404k sites, so propagation is one site per batch.**
Each new site, made by the walk or a re-evaluation (`combine` starts 33% of all instructions),
drains through the whole downstream graph before the next one is made. Every var with k paths to it
takes k separate batches, makes a grown set for each and passes each on.

`Main`'s `$model` local (offset 1969) has 283 successors and receives 349 `Main.Model` sites one at
a time. That alone is 349 × 283 ≈ 99k joins.

**Remedy.** The worklist *The worklist* specifies, a queue of **vars with an accumulated delta**, not
of `(var, batch)` pairs:

- `join` unions into the var's pending delta and queues the var once, so a var is processed once
  for everything that arrived.
- The queue is FIFO, so it tends toward Pereira–Berlin wave order. With the copy graph's SCCs
  collapsed it would be the full wave.
- The drain is deferred to the end of the statement being walked or evaluated, rather than run
  inside every `join`.

Deferring is sound and exact. A read made before propagation finishes registered its dependency
and is woken when the var changes, and the transfer functions are monotone.

**Estimate.** Joins fall toward one or two per edge, from 880k to about 150–250k a run. The join
machinery's share falls by 60–70%, so **`nowd`'s fact 3 goes from ≈ 63 ms to ≈ 25–30 ms a run**,
about −200 ms over six runs. This compounds with cause 2: fewer joins and cheaper ones.

### 4. Spread targets copy their source's summary property by property (half of `nowd`'s edges)

**Evidence, `nowd` run 1:**

- 58 162 of the 115 363 edges (50%) run from a site's property var into a summary's (`4>7`), and
  57 693 edges are made by `foldSite`.
- 23 397 edges run from a summary's property into a site's (`7>4`): the spreads' copies.
- Site property vars take 152k site additions (162k joins), 37% of all additions.
- Summary property vars take 124k (150k joins).

`Main.Model` is a record of 64 fields with 349 record-update sites. Every update
`{...$model, w_i: x}` gives its new site 63 property vars, each fed by **one** copy edge from the
same summary property var. So every field's set exists, and is propagated to, 349 times. Then a
summary that folds those sites takes 349 edges per field that carry the identical set.

**Remedy.** Copy equivalence, as in Hardekopf and Lin's HVN, or Rountev and Chandra's offline
variable substitution. A spread's untouched field cell **is** the source summary's property var,
not a new var with one copy edge from it, until something else joins it. At that point it
splits: its own var, the copy edge, then the join. In beni a record is not written after it is
made, so the split is rare. A fold of such a site then makes edges from a few distinct vars, and
`hasEdge` removes the duplicates.

The fixpoint is unchanged: a var whose only in-edge is a copy from `s` holds exactly `s`'s set.
Under *Cells* this is a field cell resolving to another cell, and it leaves the slice-5 layout as
it is.

**Estimate.** Up to −50% of edges, −35% of site additions and about −30% of fact-3 time on
`nowd` (≈ −100 ms). In the N=64 runs 5–6 the same sharing would also shrink the 4>7 edges that
cause 1's folds make (190 sites → a few distinct vars).

### 5. Repetition: six runs, the third almost a no-op, and the passes in between (#499)

**Evidence.** Facts against the previous run, comparing each node's value and each site's facts
(by node) with what the last run had for them:

| run | nodes differing / compared (new) | modules with a change (version moved) | sites differing / compared (new, gone) |
|---|---|---|---|
| 2 | 5 236 / 49 692 (0) | 72 (74) | 358 / 2 863 (0, 476) |
| **3** | **1 / 49 692** (0) | **1 (2)** | **1 / 2 863** (0, 0) |
| 4 | 8 661 / 49 692 (8 780) | 65 (67) | 532 / 2 301 (17, 562) |
| 5 | 5 797 / 58 472 (4 623) | 62 (63) | 526 / 1 834 (228, 484) |
| 6 | 5 016 / 63 095 (4 677) | 68 (68) | 593 / 1 878 (95, 184) |

N=64 is shown. `nowd` gives the same pattern: run 3 has 1 node and 1 site different.

- **Run 3 recomputes run 2 to within one node and one site.** It costs about 1/6 of runs 1–4
  (≈ 64 ms on `nowd`) and decides nothing. That bears out #499's option (b).
- Every other run changes facts in 62–72 of 78 modules. This confirms that a module-grain
  incremental re-solve buys nothing here.

Spec's own work between the runs is 17% of `nowd`: structural passes 11.0% (`inlineScan`,
`inlineOne`, `Copy`, `findUse`, `namedTwice`), facts 1–2 sweeps 3.8%, `rewrite` 1.3% and `prune`
0.6%. Outside `specialise` the build is 15% of `nowd` (≈ 85 ms) and 4.7% of n64.

**Remedy, in the design's order:**

- skip run 3 when round 2's rewrite is fact-3-neutral (#499 (b)): −1/6 of runs 1–4;
- slice 6, one solve per structural pass (four solves, not six; it moves three goldens by design);
- after causes 1–4, the structural passes become the next item, about 60 ms on `nowd`.

**Estimate.** About −65 ms on `nowd` for the skip, and −2 of 6 solves with slice 6.

## What this means for the order of #464's slices

1. **#562 (in progress), plus "`top` first / fold lazily".** N=64 2.1 s → about 0.55 s. Nothing else
   matters for N=64 until this lands, because runs 5–6 are 80% of its instructions.
2. **The var-delta worklist with deferred drains (cause 3), then ids in place of slices (cause
   2).** They multiply. The join machinery is 48% of `nowd`, and the two together should take
   fact 3 from about 63 ms to about 15–20 ms a run.
3. **Copy-equivalent field cells (cause 4).** This halves the edges that remain.
4. **The run-3 skip, or slice 6 (cause 5).** Then the structural passes and the frontend floor.

Estimated end state for `nowd`, and for N=64 once cause 1 is fixed: fact 3 about 6 × 15 ms =
90 ms, plus about 60 ms of structural passes and sweeps, plus about 85 ms outside `specialise`.
That is **≈ 0.25 s**. Milliseconds also need slice 6 and work on the structural passes and the
frontend.

## Files (dagon)

- Scratch instrumentation: `~/prof-pts/SpecProf.zig`. The patch is in this session's scratchpad
  (`prof/patch.pl`, `prof_pts.zig`, `prof_tail.zig`).
- Counter reports: `~/prof-pts/{nowd,n64-s1,n16-s1}.prof*.txt`.
- perf data: `~/prof-pts/{nowd,n64}.fp.data`. Folded scripts: `*.fp.script`. Attribution script:
  `~/prof-pts/attr.pl`.
- Worktree: `~/src/github.com/canassa/beni-prof`. It is detached at `d74161189`, its `Spec.zig` is
  instrumented, and it is a throwaway: delete it when done.

## Legend for the counters

The `via` of a join: 0 direct, 1 along a linking edge, 2 along an edge across a filter, 3 a new
edge's first enqueue, 4 `makeTop` passing on `top`.

The `src` of a direct join: 1 a narrowed name, 2 a member-read initialiser, 3 a call initialiser,
4 any other initialiser, 5/6 an assignment to a name (from a member read: 6), 7 a `return`,
8 a call argument that is not a name, 10 an object literal's property.

A fold reason is `via` for an edge join, `16 + src` for a direct one, and 5 for
`feedSummary`'s uncovered sites.

Var kinds: 1 global, 2 local or parameter, 3 return, 4 site property, 5 site `any`, 6 summary `any`,
7 summary property, 8 load cell.
