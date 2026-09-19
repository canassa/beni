# Where the check-time tax goes — 2026-09-19

`plans/state-of-the-compiler.md` §8 left one number standing: `check` costs
**+24.5 %** against the pre-dispatch baseline on 100 159 lines that write no
`where` clause and no dot-call, up from report 19 §2.1's +20.3 % in the
morning, and nobody had looked at where it goes. This page looks.

Three answers up front, each measured below:

1. **Not the operator lowering.** All 2 794 uses of `== /= < <= > >=` in the
   corpus become method constraints, and solving all of them is **1.58 ms**
   against the ~2 814 `Basics` instantiations they replace. Roughly free.
2. **The evidence numbering that rides on EVERY instantiation** — all 52 414,
   constrained scheme or not. `evidenceCursor` + `tagInstantiated` +
   `commitEvidence` is **≈ 6.7 ms of the 8.7 ms `solve` grew by**, and
   `tagInstantiated` is a second complete traversal of a type `makeCopy` has
   just finished building.
3. **The day's three new passes are 1.9 ms of the 15.2 ms**, 12 %. They are
   not why the number moved 4 points; the instrument's spread is.

One change landed: **−3.7 % of `check`**, output-identical to the byte, the
tax **+20.6 % → +17.2 %**. The rest is named, priced and left.

---

## 1. Method

**Machine.** `dagon`: AMD Ryzen 9 5950X, 16C/32T, 31 GiB, Linux 6.12.110
NixOS, Zig 0.16.0, Node v24.19.0 from the flake — "machine 2" of
`plans/static-dispatch-spike-results.md`, the same machine every number in
`state-of-the-compiler.md` was taken on.

**Binaries**, all ReleaseFast. **A** = `c870e9a`,
`../beni-s1/zig-out/bin/beni`, 13 253 080 B, `master` before static dispatch,
never modified. **M** = `89ce028`, the adoption commit, built in a throwaway
worktree under the scratchpad and removed afterwards. **B0** = `53154b0`,
`master` today, 18 223 024 B. **B1** = B0 + this page's one change.

**Corpora.** `--generate=100000` writes 624 files, 100 159 lines. **A's and
M's corpus is 1 835 619 bytes, B's is 1 835 956** — a 337-byte difference
from `3c8fbf8`, where `gen.zig` started respecting the `let`-order rule and
picks a different in-scope local in 323 of the 624 files. **Token count
(302 615) and AST node count (221 576) are identical on both sides**, so the
two corpora are the same shape to 0.018 %.

**Discipline.** `uptime` before and after every instrument; the 1-minute load
stayed between **0.03 and 0.82** for every recorded run, nothing was measured
while anything built, and every before/after pair is interleaved ABBA in one
machine state. One batch taken at load 2.24 was **discarded without being
read into any table**.

**Two instruments.** `zig build bench -- --generate=100000 --iterations=5` is
the row `state-of-the-compiler.md` §2 quotes — best of 5 cold `Session.run`s
with `resolve` subtracted, plus the deterministic counters. `beni check
--jobs=1 <corpus> --self-profile=<path>`, events summed per name, is one cold
run per sample but is the only thing that splits `check` into sub-passes.
They disagree by ~8 % in absolute level; ratios are read **within** one
instrument, never across the two.

**No profiler was available**: `perf` is not on this NixOS box and
`perf_event_paranoid` is 2, and `valgrind` is not on `PATH`. §3's split comes
from **temporary timers under a local patch that was not kept** — new
`Profile.Phase` variants around each step of `Check.ModuleCheck.run` and a
`clock_gettime(MONOTONIC)` accumulator around seven `Solve.Solver` functions,
recorded at `scratchpad/instrumentation.patch`. `src/` was restored from git
before anything was changed for real.

---

## 2. The three columns: C0 → adoption → HEAD

`zig build bench -- --generate=100000 --iterations=5`, one interleaved batch,
order **A M B B M A**. Raw `check` lines verbatim:

```
 03:11:06 up 16:13,  3 users,  load average: 0.58, 0.62, 2.11
A1 {"phase":"check","modules":635,"lines":100159,"unifications":231352,"generalisations":101320,"instantiations":55228,"obligations":3151,"constraints_created":0,"constraints_merged":0,"constraints_deferred":0,"constraints_discharged":0,"constraints_promoted":0,"diagnostics":0,"ms":61.78,"loc_per_s":1621243,"cold_check_ms":93.5}
M1 {"phase":"check","modules":633,"lines":100159,"unifications":228143,"generalisations":104086,"instantiations":52346,"obligations":3486,"constraints_created":281,"constraints_merged":3,"constraints_deferred":476,"constraints_discharged":2710,"constraints_promoted":1,"diagnostics":0,"ms":72.99,"loc_per_s":1372261,"cold_check_ms":106.0}
B1 {"phase":"check","modules":633,"lines":100159,"unifications":228475,"generalisations":103953,"instantiations":52414,"obligations":3452,"constraints_created":262,"constraints_merged":2,"constraints_deferred":442,"constraints_discharged":2716,"constraints_promoted":1,"diagnostics":0,"ms":74.89,"loc_per_s":1337465,"cold_check_ms":107.4}
B2 {"phase":"check","modules":633,"lines":100159,"unifications":228475,"generalisations":103953,"instantiations":52414,"obligations":3452,"constraints_created":262,"constraints_merged":2,"constraints_deferred":442,"constraints_discharged":2716,"constraints_promoted":1,"diagnostics":0,"ms":73.55,"loc_per_s":1361718,"cold_check_ms":108.2}
M2 {"phase":"check","modules":633,"lines":100159,"unifications":228143,"generalisations":104086,"instantiations":52346,"obligations":3486,"constraints_created":281,"constraints_merged":3,"constraints_deferred":476,"constraints_discharged":2710,"constraints_promoted":1,"diagnostics":0,"ms":70.63,"loc_per_s":1417982,"cold_check_ms":105.5}
A2 {"phase":"check","modules":635,"lines":100159,"unifications":231352,"generalisations":101320,"instantiations":55228,"obligations":3151,"constraints_created":0,"constraints_merged":0,"constraints_deferred":0,"constraints_discharged":0,"constraints_promoted":0,"diagnostics":0,"ms":61.26,"loc_per_s":1634893,"cold_check_ms":93.2}
 03:11:19 up 16:13,  3 users,  load average: 0.64, 0.64, 2.10
```

An earlier plain ABBA at `02:58` (load 0.75 → 0.79), same fields, `ms` only,
for a second reading of the ratio: **A 62.96, B 77.55, B 74.49, A 63.36**.

| | **A** `c870e9a` | **M** `89ce028` (adoption) | **B** `53154b0` (HEAD) |
|---|---:|---:|---:|
| `check` ms, batch of 03:11 | 61.78 / 61.26 → **61.52** | 72.99 / 70.63 → **71.81** | 74.89 / 73.55 → **74.22** |
| vs A | — | **+16.7 %** | **+20.6 %** |
| `check` ms, batch of 02:58 | 62.96 / 63.36 → **63.16** | — | 77.55 / 74.49 → **76.02** |
| vs A | — | — | **+20.4 %** |
| modules · unifications | 635 · 231 352 | 633 · 228 143 | 633 · 228 475 |
| generalisations · instantiations | 101 320 · 55 228 | 104 086 · 52 346 | 103 953 · 52 414 |
| obligations | 3 151 | 3 486 | 3 452 |
| constraints created / merged / deferred | 0 / 0 / 0 | 281 / 3 / 476 | 262 / 2 / 442 |
| constraints discharged / promoted | 0 / 0 | 2 710 / 1 | 2 716 / 1 |

### 2.1 The adoption is +16.7 %; the day added +3.4 points

`B ÷ M` is **1.034**, and the counters say what it is: M and B differ by 332
unifications (+0.15 %), 68 instantiations (+0.13 %) and 6 discharges. **The
day changed essentially nothing about the inference work**; it added three
passes that run beside it, and §3 prices them at 1.87 ms — 2.6 % of B's
71 ms, against the 3.4 % measured. The two agree. So the split
`state-of-the-compiler.md` §9 could not make is **adoption +16.7 points, the
day's three new checker passes +3.9 points.**

### 2.2 The morning's 20.3 % and the evening's 24.5 % are the same number

M's counters — obligations **3 486**, deferred **476**, discharged **2 710** —
reproduce report 19 §2.1's row exactly, so M *is* the morning binary and this
instrument agrees with the morning's.

Tonight HEAD reads **+20.4 %** and **+20.6 %** where the evening read
+24.5 %. A's four samples tonight are 62.96 / 63.36 / 61.78 / 61.26 (spread
3.4 %) against the evening's 62.29 / 61.98 — the same. B's four are 77.55 /
74.49 / 74.89 / 73.55 (spread **5.4 %**) against the evening's 77.95 / 76.73.
**The gap is inside B's own run-to-run spread**, and the evening pair was
drawn from the slow end of it. There was no 4-point regression to find: the
three new passes are real and cost 3.4 %, the rest was noise, and **a single
ABBA pair on this row carries ±3 points.**

---

## 3. Attribution: where the 15.2 ms is

`beni check --jobs=1 --self-profile`, events summed by name. `check` is the
parent of everything below it; `constrain`, `solve` and `exhaustive` are the
three that already existed, and the `zz_*` rows are the temporary timers.

```
A  (03:01:17, load 0.50), two runs:
check 55.44 | solve 27.60 | constrain 13.09 | exhaustive 2.27
check 56.55 | solve 28.00 | constrain 13.37 | exhaustive 2.32
B0 (03:01:04, load 0.64), two runs of the temporarily instrumented binary:
check 71.26 | zz_groupsplit 53.47 | solve 36.61 | constrain 15.48 | zz_annotations 4.81 | zz_iface 4.59 | exhaustive 3.22 | zz_prologue 2.97 | zz_cycles 0.78 | zz_dispfinish 0.56 | zz_derive 0.53 | zz_toodeep 0.02
check 71.18 | zz_groupsplit 53.24 | solve 36.31 | constrain 15.52 | zz_iface 4.71 | zz_annotations 4.73 | exhaustive 3.26 | zz_prologue 2.98 | zz_cycles 0.81 | zz_dispfinish 0.61 | zz_derive 0.54 | zz_toodeep 0.02
```

The `zz_*` rows sum to `check` to within 0.3 ms, so nothing is unaccounted:

| sub-pass (`ModuleCheck.run` step) | A ms | B0 ms | Δ | share of +15.2 |
|---|---:|---:|---:|---:|
| 3b. **`solve`** | 27.8 | **36.5** | **+8.7** | **57 %** |
| 3a. **`constrain`** | 13.2 | **15.5** | **+2.3** | **15 %** |
| 4. **`exhaustive`** | 2.3 | **3.24** | **+0.94** | **6 %** |
| 8. **`Cycles.run`** (`zz_cycles`) — **new** | 0 | **0.78** | **+0.78** | 5.1 % |
| 6. **`Dispatch.finish`** (`zz_dispfinish`) — **new** | 0 | **0.56** | **+0.56** | 3.7 % |
| 2. **`deriveDeclaredTypes`** (`zz_derive`) — **new** | 0 | **0.53** | **+0.53** | 3.5 % |
| steps 1, 3-prologue, 5, 7 — the per-module scaffolding: store reserve and four arrays 2.97, annotations 4.81, binding-group loop 1.38, `fillInterface` 4.59, `reportTooDeep` 0.02 | 12.7 | 13.77 | +1.07 | 7 % |
| **`check`** | **56.0** | **71.2** | **+15.2** | **100 %** |

A cannot be split further — it has no `zz_` timers — so its scaffolding row is
`check − solve − constrain − exhaustive`. It grew by **1.07 ms** and no more.

**`solve` is 57 % of the tax and it is not unification.** B does **2 877
fewer** unifications and **2 814 fewer** instantiations than A, and pays 31 %
more for them.

### 3.1 Inside `solve`

Static accumulators around seven `Solver` functions, re-entrancy-guarded so a
recursive call is counted once. The timers cost 10 ms of clock in a 36.5 ms
`solve`, subtracted below.

```
zz method           1.578 ms  n=2834
zz discharge        0.618 ms  n=12509
zz generalize       8.338 ms  n=12509
zz finish_top       9.406 ms  n=9820
zz copy             2.613 ms  n=52414
zz instantiate     23.362 ms  n=52414
zz tag              5.060 ms  n=52414
zz quantorder       2.819 ms  n=52414
zz evcursor         1.901 ms  n=55248
zz try_shape        0.253 ms  n=257
```

`instantiate` nests `evcursor` (twice), `copy` and `tag`; `tag` nests
`quantorder`; `finish_top` nests `generalize` and `discharge`. Each nested
region costs its parent ~34 ns of clock, so `instantiate`'s true time is
23.36 − (55 248 + 3 × 52 414) × 34 ns ≈ **16.1 ms** and `tag`'s is
5.06 − 1.78 ≈ **3.28 ms**.

So of the 36.5 ms, **`instantiate` is 16.1 ms** — `evidenceCursor` 1.90,
`makeCopy` 2.61 (C0 had this), `tagInstantiated` 3.28 (of which
`quantifierOrder` 2.82), and ≈ 8.3 for `schemeOf`, `unify(target, copy)` and
`commitEvidence`. `generalize` is 8.34 ms and its code is C0's plus one
branch; `dischargeObligations` 0.62; the `method` nodes 1.58.

**`evidenceCursor` + `commitEvidence` + `tagInstantiated` ≈ 6.7 ms** —
`commitEvidence` is untimed but is the same `AutoHashMapUnmanaged(u32, u16)`
lookup as `evidenceCursor`, called once per instantiation, so ~1.5 ms. That
is **77 % of the 8.7 ms `solve` grew by** and **44 % of the whole +15.2 ms**,
and on this corpus **none of it does anything**: `tagInstantiated` calls
`Schemes.quantifierOrder`, which walks the **entire** type `makeCopy` has
just finished building — a second complete traversal — and then finds
`constraintCount(set) == 0` for every root it collected and writes nothing.

### 3.2 The operators are not the problem

`Bir.WellKnown.fromOperator` maps exactly six tokens — `== /= < <= > >=` —
and nothing else; `+ - * ++ :: && ||` are still calls of their `core`
function. Counting the 624 generated files (`grep -o -F " <op> "`): **`<`
1 452 · `>` 967 · `<=` 110 · `/=` 98 · `==` 85 · `>=` 82 = 2 794**, against
`+` 2 795 · `*` 2 676 · `-` 1 045 · `++` 1 153 that create no constraint at
all. Those 2 794 sites land as **2 834** `method` nodes solved (the 40 extra
are `core`'s own) and **2 716** `constraints_discharged`: the match is exact,
and every method constraint on this corpus is one of the six comparisons.

**What they cost.** All 2 834 together are **1.58 ms** of `solve`. On the
other side, B does **2 814 fewer instantiations** than A — almost exactly the
2 794 sites, because A instantiated `Basics.lt` and friends at each one — and
at B's own 307 ns per instantiation that is 0.86 ms saved. **The operator
lowering is a net cost of about 0.7 ms**, 5 % of the tax. Report 19's "the
obligation bookkeeping" is right only if that means the numbering riding on
the *other* 52 414 instantiations.

### 3.3 The three new passes, against their own claims

**`Cycles.run` does return early, as the slice said** — `anyRuns` scans the
declaration table before anything builds a graph, and its comment names this
corpus, "624 such modules"; its 0.78 ms is that scan and nothing more.
**`Dispatch.finish` is 0.56 ms** over 633 near-empty tables, not worth a
special case. **`exhaustive` 2.3 → 3.24 ms** is `59e47f3`'s
irrefutable-position usefulness pass — today's, not the adoption's.
**`deriveDeclaredTypes` is 0.53 ms** for `eq`/`compare` on every nominal
type, used or not (A.23).

---

## 4. What changed

One change, in `src/check/Solve.zig`.

**`Solver.copy_constrained`**, a bool set by `copyHelp`: true if the walk met
a variable carrying a method constraint, and true conservatively wherever
`copyHelp` *shares* a subtree instead of descending into it (a
non-generalised root, the depth guard) while the store holds any constraint
at all. `makeCopy` clears it before the walk.

`instantiate` then skips `tagInstantiated` when it is false, and skips
`commitEvidence` when the cursor comes back exactly as it went out.

**Why it is output-identical, argued before it is measured.** `copyHelp`
walks precisely the nodes `Schemes.orderWalk` then walks on the copy — every
child of every structure, alias, record field and constraint `fn_var` — and a
copied node's constraint set is non-`none` exactly when the original's was.
So a walk that met no constrained variable proves `quantifierOrder` collects
no root with `constraintCount != 0`, which proves `tagInstantiated`'s loop
body never runs: no site written, no obligation registered, `next` left where
it was. The one place the walks differ is a shared subtree, which `orderWalk`
descends into and `copyHelp` does not — and there the flag is set whenever
the store holds a constraint at all, so it can only be true too often.

**Measured.** `beni check --jobs=1 --self-profile`, **six interleaved runs
per side** in one machine state, order `B0 B1 B2 B2 B1 B0` × 3:

```
 03:19:15 up 16:21,  3 users,  load average: 0.66, 0.53, 1.42
B0 check 70.28  solve 35.54      B0 check 70.95  solve 35.89      B0 check 70.74  solve 35.65
B1 check 68.18  solve 33.53      B1 check 66.89  solve 33.10      B1 check 68.20  solve 33.52
B2 check 68.41  solve 33.73      B2 check 70.63  solve 35.03      B2 check 68.99  solve 33.88
B2 check 69.34  solve 34.21      B2 check 69.71  solve 34.60      B2 check 68.94  solve 33.99
B1 check 68.31  solve 33.67      B1 check 68.72  solve 33.99      B1 check 68.87  solve 33.76
B0 check 70.54  solve 35.69      B0 check 70.74  solve 35.68      B0 check 71.82  solve 36.38
 03:19:18 up 16:21,  3 users,  load average: 0.69, 0.54, 1.42
```

| | `check` mean of 6 | `solve` mean of 6 |
|---|---:|---:|
| **B0** — `53154b0` | **70.84** | **35.81** |
| **B1** — the change | **68.20** (−2.64, **−3.7 %**) | **33.60** (−2.21, **−6.2 %**) |
| B2 — a refinement, rejected | 69.34 (−1.50) | 34.24 (−1.57) |

B1 is faster than B0 in **every one of the six pairings**, and the change is
2.2 ms of the 6.7 ms §3.1 priced — the rest is the cases where
`copy_constrained` is conservatively true.

**Confirmed on the other two instruments.** Wall clock, `beni check
--jobs=1`, twelve interleaved runs, `03:38`, load 0.04: B0 128 / 130 / 129 /
130 / 127 / 128 → **128.7 ms**; B1 127 / 126 / 127 / 128 / 126 / 126 →
**126.7 ms** — **−2.0 ms** of a whole process that also lexes, parses,
lowers and resolves. And `zig build bench`, the row §2 is stated in, ABBA
`A F F A A F F A`:

```
 03:38:28 up 16:40,  3 users,  load average: 0.03, 0.94, 1.96
A 61.17   F 71.67   F 71.87   A 60.38   A 61.93   F 72.94   F 71.74   A 62.36
A mean 61.46   F mean 72.06   F/A 1.1724
 03:38:47 up 16:41,  3 users,  load average: 0.31, 0.95, 1.94
```

**A reads 61.46 here against 61.52 in §2's batch**, so the two are one
machine state and `B0 = 74.22` may be read against `F = 72.06` directly:
**−2.16 ms, −2.9 %**, and the tax goes **+20.6 % → +17.2 %** — within half a
point of the adoption commit's own +16.7 %. The change gives back very nearly
what the day's three new passes took.

**B2, and why it is not here.** B2 answered the shared-root case *exactly*
for a leaf (a shared `flex`/`rigid` has no children, so its own flags settle
it), conservatively only for a shared structure. It is strictly more precise
and **slower than B1**: the extra branch in `copyHelp` runs on every node of
every copy and costs more than the skips it buys. Reverted, with the
measurement recorded in the comment so nobody tries it again.

### 4.1 Output identity, verified rather than argued

Against B0, on the same inputs: `beni build --platform=node --library` over
the 624-file corpus is **629 files byte-identical in dev and 629 in
`--release`**; `dump --stage=dispatch|bir|types|interface` over the 270
fixtures of `tests/corpus/{dispatch,check,bir}` is **1 567 615 bytes
identical**; `dump --stage=dispatch` (571 849 B) and `--stage=interface`
(170 236 B) over the whole generated corpus are identical; `check
--iface-hash` gives the **same 633 hashes**; and every counter of the `bench`
`check` line matches field for field (§2's B row).

`zig build test`, `zig build test-blackbox` (three times, once more at the
end) and `zig build fmt-check` all pass, and
`BENI_WRITE_EXPECTED=1 zig build test-blackbox` followed by `git status`
leaves **only `src/check/Solve.zig`** — no golden moved.

---

## 5. What was NOT changed, and what it is worth

Every one of these is real and measured; none met both bars (local **and**
provably output-identical **and** measured to help).

| lead | file:line | ms | share of `check` | why not |
|---|---|---:|---:|---|
| **`evidence_next` is a `HashMap` allocated once per binding group** | `Solve.zig:259`, `:360` | ~1.9 + ~1.5 | **≈ 4.8 %** | 55 248 `getOrPut` at **34 ns** each is allocation-dominated: 9 820 `Solver`s, one map allocation each. Two fixes exist — give the map `env.scratch` (an arena) instead of `gpa`, or make `evidenceCursor` a non-allocating read and let `commitEvidence` do the insert. The second is the better one and it makes `commitEvidence` fallible, which its doc comment currently calls "infallible by construction" at four call sites. **A spec sentence has to move first.** |
| **`tagInstantiated`'s remaining traversals** | `Solve.zig:3546` | ~1.5–2.0 | **≈ 2.5 %** | what is left after §4, i.e. the instantiations where `copy_constrained` is conservatively true. Removing it needs the store to carry a "something below me is constrained" bit maintained through `merge`/`setContent`, which is neither local nor obviously identical. |
| **six gpa-allocated containers per `Solver` where C0 had four** | `Solve.zig:330–345` | not isolated | — | `promoted`, `resolved_methods`, `resolved_journal`, `superseded`, `deferred`, `evidence_next`, all created and destroyed **9 820 times per run**. Only `evidence_next` is always used; the other five are usually empty and cost nothing. Worth one arena, not five patches. |
| **`constrain` +2.3 ms** | `Constrain.zig` | 2.3 | **3.2 %** | 15 % of the tax and **not attributed**. It is not `operatorSection`, which returns on its first tag check. It is spread over `wellKnownCall`'s extra tree nodes for 2 794 sites and a `Generator`/`Env` that grew by 304 lines. Splitting it needs another instrumented build. |
| **`exhaustive` +0.94 ms** | `Exhaustive.zig` | 0.94 | 1.3 % | today's irrefutable-position pass, `59e47f3`. Under the 2 % bar. The `Patterns` arena is already per **worker** and reset per `case`, not per module — the brief's suspicion does not hold; M2c already fixed that. |
| **`Dispatch.finish` on an empty table** | `Check.zig`, step 6 | 0.56 | 0.8 % | under the bar. |
| **`Cycles` on a module with no running constant** | `Cycles.zig:102` | 0.78 | 1.1 % | **it already returns early** — `anyRuns` scans the declaration table and nothing else runs. Verified, not a defect. |
| **answering `Int == Int` at constrain time** | — | ≤ 1.6 | ≤ 2.2 % | the whole of `method` node solving is 1.58 ms (§3.2), so the ceiling is small — and it changes what `dump --stage=dispatch` prints. Not built, as instructed. |
| **`Schemes.Writer.typeRefOf`'s linear scan** | `Schemes.zig` | — | — | `fillInterface` is **4.59 ms** and it is not new: A's unsplit remainder is 12.7 ms against B0's 13.77 for the same four steps. Nothing here regressed. |

---

## 6. The number to watch

**`check` against `c870e9a` on `--generate=100000`, as the mean of at least
four interleaved samples per side.** It was **+20.4 % / +20.6 %** on
`53154b0` in two batches and is **+17.2 %** with §4's change — against
`fast-compiler.md` §2's budget of 250 k LOC/s, which the absolute number
(1.39 M LOC/s per core after the change) clears by **5.5×**.

The trend for that one number, every figure on this machine and this corpus:
**C0 `c870e9a` 61.5 ms → adoption `89ce028` 71.8 ms (+16.7 %) → `53154b0`
74.2 ms (+20.6 %) → `53154b0` + §4 **72.1 ms (+17.2 %)**.

Two things about how to read it, both learned here. **A single ABBA pair
carries ±3 points** — B's spread over four samples is 5.4 %, and the
20.3 % → 24.5 % "regression" of `state-of-the-compiler.md` §8 was that
spread, not a change in the compiler (§2.2). And **the counters are the
honest half of the instrument**: `unifications`, `instantiations`,
`generalisations`, `obligations` and the five `constraints_*` are
deterministic to the unit across runs and machine states, and they are what
caught that the adoption does *less* inference work and still costs more.
Quote them beside every timing.
