# Static dispatch spike — raw measurements

Append-only, like `diary.md`. Every number here is a raw instrument line, copied
verbatim. Nothing in this file is edited after it is written; a correction is a
new entry further down. `plans/static-dispatch-spike.md` §7 names the rows.

---

## 2026-09-17 — S1 baselines, C0 at c870e9a

**Machine:** Intel N100, 4 cores / 4 threads, 6 MiB L3, single memory
channel, 16 GB RAM, Linux 7.2.2, Zig 0.16.0, Node v24.19.0, ReleaseFast.

**Binary under test:** `/home/canassa/code/src/github.com/canassa/beni-s1/zig-out/bin/beni`,
a `-Doptimize=ReleaseFast` build of `c870e9a` ("measurement harness for the
static-dispatch spike"). `c870e9a` is `master` at `f466aac` plus the S1 harness.
It **does** touch `src/` — 4 files, +53 −16 — but only to add the five
`Solve.Counters` fields (`constraints_created / merged / deferred / discharged /
promoted`, all `= 0`), the matching `Profile.Counter` names, and a reflective
`Counters.add` replacing two hand-written field-by-field sums. No inference,
solving, lowering or emission path changes, so the checker's and backend's
*behaviour* is `master`'s and these are **C0 on `master`** in the sense of §7,
taken on the tree that carries the instruments. The exact diff is under M7
below.

**Corpus:** C0 — the current sources: `bench/corpus`, `tests/corpus`, `core/`,
and `--generate=100000`.

Every instrument was run from the `beni-s1` worktree via
`direnv exec /home/canassa/code/src/github.com/canassa/beni <cmd>` for the dev
shell. `uptime` is recorded immediately before each instrument; per
`bench/README.md` no number is recorded while the 1-minute load average is
above 2.0.

---

### M1a — what the feature costs code that never uses it (C0 side)

`plans/static-dispatch-spike.md` §7 M1a. Instrument: `zig build bench`,
best of 5 after one warm-up, `jobs = 1` throughout.

**Load before:** ` 13:38:21 up 3 days, 20:19,  5 users,  load average: 0.41, 1.12, 1.10`

```
$ direnv exec /home/canassa/code/src/github.com/canassa/beni zig build bench -- --generate=100000 --iterations=5
bench: generated 624 files, 100159 lines, 1835619 bytes (plain) under .zig-cache/bench-gen
{"phase":"read","files":624,"bytes":1835619,"tokens":0,"nodes":0,"insts":0,"ms":2.1,"mb_per_s":829.0,"loc_per_s":47428574}
{"phase":"lex","files":624,"bytes":1835619,"tokens":302615,"nodes":0,"insts":0,"ms":9.8,"mb_per_s":178.9,"loc_per_s":10235155}
{"phase":"parse","files":624,"bytes":1835619,"tokens":302615,"nodes":221576,"insts":0,"ms":6.9,"mb_per_s":254.7,"loc_per_s":14569728}
{"phase":"lower","files":624,"bytes":1835619,"tokens":302615,"nodes":221576,"insts":205097,"ms":9.7,"mb_per_s":181.2,"loc_per_s":10368760}
{"phase":"resolve","modules":635,"edges":3787,"interfaces":635,"ms":5.53,"cold_check_ms":41.2}
{"phase":"check","modules":635,"lines":100159,"unifications":231352,"generalisations":101320,"instantiations":55228,"obligations":3151,"constraints_created":0,"constraints_merged":0,"constraints_deferred":0,"constraints_discharged":0,"constraints_promoted":0,"diagnostics":0,"ms":71.77,"loc_per_s":1395638,"cold_check_ms":113.0}
{"phase":"emit","modules":635,"js_bytes":3075595,"nodes":254951,"lines":103669,"ms":33.87,"mb_per_s":86.6,"loc_per_s":3060774}
{"phase":"total","files":624,"bytes":1835619,"tokens":302615,"nodes":221576,"insts":205097,"ms":139.6,"mb_per_s":12.5,"loc_per_s":717482}
```

Reading: **`check` 71.77 ms / 1.396 M LOC/s, total 139.6 ms** on the 624-file,
100 159-line plain tree; the five new `Solve.Counters` fields
(`constraints_created / merged / deferred / discharged / promoted`) are all
**0**, which is what "zero on `master`" means and is the fixed point M1b's
branch run is read against.

**Load before:** ` 13:39:34 up 3 days, 20:20,  5 users,  load average: 0.82, 1.09, 1.09`

```
$ direnv exec /home/canassa/code/src/github.com/canassa/beni zig build bench -- --generate=100000 --dispatch --iterations=5
bench: generated 624 files, 100327 lines, 1887474 bytes (dispatch) under .zig-cache/bench-gen-dispatch
{"phase":"read","files":624,"bytes":1887474,"tokens":0,"nodes":0,"insts":0,"ms":2.1,"mb_per_s":838.6,"loc_per_s":46738850}
{"phase":"lex","files":624,"bytes":1887474,"tokens":313333,"nodes":0,"insts":0,"ms":9.7,"mb_per_s":185.8,"loc_per_s":10354199}
{"phase":"parse","files":624,"bytes":1887474,"tokens":313333,"nodes":229869,"insts":0,"ms":6.9,"mb_per_s":260.0,"loc_per_s":14491472}
{"phase":"lower","files":624,"bytes":1887474,"tokens":313333,"nodes":229869,"insts":215272,"ms":9.8,"mb_per_s":183.5,"loc_per_s":10227067}
{"phase":"resolve","modules":635,"edges":3873,"interfaces":635,"ms":5.95,"cold_check_ms":43.0}
{"phase":"check","modules":635,"lines":100327,"unifications":239539,"generalisations":130066,"instantiations":58225,"obligations":3721,"constraints_created":0,"constraints_merged":0,"constraints_deferred":0,"constraints_discharged":0,"constraints_promoted":0,"diagnostics":1682,"ms":83.39,"loc_per_s":1203097,"cold_check_ms":126.4}
{"phase":"emit","modules":635,"js_bytes":3138282,"nodes":259273,"lines":103837,"ms":34.80,"mb_per_s":86.0,"loc_per_s":2983866}
{"phase":"total","files":624,"bytes":1887474,"tokens":313333,"nodes":229869,"insts":215272,"ms":152.7,"mb_per_s":11.8,"loc_per_s":656975}
```

Reading: the **front-end phases are the meaningful half of this run** —
`--dispatch` costs 168 more lines, 51 855 more bytes, 10 718 more tokens and
8 293 more AST nodes, and `lex`/`parse`/`lower` are flat against the plain
tree at 9.7 / 6.9 / 9.8 ms (the plain tree's 9.8 / 6.9 / 9.7). **`check` on the
dispatch tree is NOT meaningful before S3**: the checker has no dispatch yet,
so the 1 682 diagnostics are the dot-calls and `where` clauses failing to
resolve, and the 83.39 ms is the cost of *failing* on them, not of checking
them. It is recorded only so S3's run has a same-machine predecessor to be
compared against for the front end; the `check` row itself is re-measured on
the branch.

---

### M2 — constraint accumulation in unannotated code (C0 side)

`plans/static-dispatch-spike.md` §7 M2. **What this measures today:** per
`bench/gen.zig`'s `constraint-chain` header comment, on a tree without
dispatch `x.m<i> 1` is `apply(field_access(x, m<i>), [1])`, so
`Gen/ConstraintChain.beni` is a chain of **row-polymorphic field calls** — `x`
is inferred as an open record of `n` function fields. This baseline is
therefore the **row-extension and field-lookup cost the language already pays
for this shape**, not the cost of method constraints, and the two numbers
"must never be read as before/after of the same mechanism".

**Load before:** ` 13:40:04 up 3 days, 20:20,  5 users,  load average: 0.60, 1.02, 1.06`

```
$ direnv exec … zig build bench -- --pathological=constraint-chain=10 --iterations=5
bench: generated constraint-chain n=10 (787 bytes) under .zig-cache/bench-pathological
{"phase":"check","modules":12,"lines":38,"unifications":5366,"generalisations":2092,"instantiations":1662,"obligations":3,"constraints_created":0,"constraints_merged":0,"constraints_deferred":0,"constraints_discharged":0,"constraints_promoted":0,"diagnostics":0,"ms":2.00,"loc_per_s":18990,"cold_check_ms":3.2}

$ … --pathological=constraint-chain=100 --iterations=5
bench: generated constraint-chain n=100 (3760 bytes) under .zig-cache/bench-pathological
{"phase":"check","modules":12,"lines":308,"unifications":6716,"generalisations":17617,"instantiations":2022,"obligations":3,"constraints_created":0,"constraints_merged":0,"constraints_deferred":0,"constraints_discharged":0,"constraints_promoted":0,"diagnostics":0,"ms":5.76,"loc_per_s":53483,"cold_check_ms":7.1}

$ … --pathological=constraint-chain=1000 --iterations=5
bench: generated constraint-chain n=1000 (36163 bytes) under .zig-cache/bench-pathological
{"phase":"check","modules":12,"lines":3008,"unifications":20216,"generalisations":1509367,"instantiations":5622,"obligations":3,"constraints_created":0,"constraints_merged":0,"constraints_deferred":0,"constraints_discharged":0,"constraints_promoted":0,"diagnostics":0,"ms":275.89,"loc_per_s":10903,"cold_check_ms":278.7}

$ … --pathological=constraint-chain=5000 --iterations=5
bench: generated constraint-chain n=5000 (192163 bytes) under .zig-cache/bench-pathological
{"phase":"check","modules":12,"lines":15008,"unifications":72268,"generalisations":1623447,"instantiations":21622,"obligations":3,"constraints_created":0,"constraints_merged":0,"constraints_deferred":0,"constraints_discharged":0,"constraints_promoted":0,"diagnostics":1,"ms":297.29,"loc_per_s":50483,"cold_check_ms":306.4}
```

Two extra points, taken in the same session to bracket where the `n=5000` row
stops being a chain of 5 000 (load ` 13:41:08 … load average: 0.34, 0.87, 1.01`,
`--iterations=3`):

```
$ … --pathological=constraint-chain=2000 --iterations=3
{"phase":"check","modules":12,"lines":6008,"unifications":33268,"generalisations":1599447,"instantiations":9622,"obligations":3,"constraints_created":0,"constraints_merged":0,"constraints_deferred":0,"constraints_discharged":0,"constraints_promoted":0,"diagnostics":1,"ms":284.40,"loc_per_s":21124,"cold_check_ms":288.8}

$ … --pathological=constraint-chain=3000 --iterations=3
{"phase":"check","modules":12,"lines":9008,"unifications":46268,"generalisations":1607447,"instantiations":13622,"obligations":3,"constraints_created":0,"constraints_merged":0,"constraints_deferred":0,"constraints_discharged":0,"constraints_promoted":0,"diagnostics":1,"ms":279.33,"loc_per_s":32248,"cold_check_ms":285.3}
```

| n | check ms | generalisations | diagnostics | clean? |
|---:|---:|---:|---:|---|
| 10 | 2.00 | 2 092 | 0 | yes |
| 100 | 5.76 | 17 617 | 0 | yes |
| 1 000 | 275.89 | 1 509 367 | 0 | yes |
| 2 000 | 284.40 | 1 599 447 | 1 | **no** |
| 3 000 | 279.33 | 1 607 447 | 1 | **no** |
| 5 000 | 297.29 | 1 623 447 | 1 | **no** |

Reading: check time on the C0 (row-polymorphic) chain is **super-linear in n up
to ≈1 000 and then flat** — 2.00 → 5.76 → 275.89 ms for 10 → 100 → 1 000, a
48× jump for the last 10×, driven by `generalisations` going 2 092 → 17 617 →
1 509 367 (the accumulated open record is re-walked at every generalisation).
Past ≈1 000 the curve stops because **the checker stops building the chain**,
not because the cost stops: every n ≥ 2 000 emits exactly one diagnostic and
the numbers plateau at ~280–300 ms. The diagnostic at n = 5 000 is, verbatim
(`beni check --jobs=1 .zig-cache/bench-pathological`, head):

```
-- UNKNOWN FIELD - .zig-cache/bench-pathological/Gen/ConstraintChain.beni:3089:23

This record has a `m1027` field I did not expect:

    { r | m1027 : number -> number2 }

But I need a record like:

    { m1 : number3 -> number2, m10 : number4 -> number2, … m9 : number67 -> number2 }

Hint: this looks like a typo. Maybe `m1027` should be `m10`?

3089|    x.m1027 1 + f1026 x
                           ^
```

So **`n = 5000` is not a data point for a 5 000-long chain**; the last clean
row is n = 1 000, and n ∈ {2 000, 3 000, 5 000} are recorded as-run with the
failure quoted rather than dropped.

Two pre-existing C0 observations fell out of this row and are recorded because
§7 M2 asks for "max constraints per scheme" and "rendered scheme length", and
on C0 neither can be read off the tools:

- **The printer caps a record at 65 fields.** `Render.writeRecord`
  (`src/check/Render.zig:283`) flattens the extension chain under
  `while (guard < 64)`, and falls out of the `while`'s `else` with
  `open = null`. So from f65 onward every rendered type is the *same*
  65-field **closed** record, with the `| r` tail dropped. `dump --stage=types`
  on the n = 1 000 tree:

  ```
  f1     fields=1   chars=36    …  f1 : { r | m1 : number -> a } -> a
  f10    fields=10  chars=277   …  , m9 : number11 -> number2 } -> number2
  f65    fields=65  chars=1758  …  , m9 : number66 -> number2 } -> number2
  f66    fields=65  chars=1758  …  , m9 : number66 -> number2 } -> number2
  f100   fields=65  chars=1759  …  , m9 : number66 -> number2 } -> number2
  f500   fields=65  chars=1759  …  , m9 : number66 -> number2 } -> number2
  f1000  fields=65  chars=1760  …  , m9 : number66 -> number2 } -> number2
  ```

  The inferred scheme really does carry n fields — checking is clean to
  n = 1 000 — so **"rendered scheme length" saturates at ~1 760 characters** and
  is not a measure of the scheme past 65 members. The n = 5 000 diagnostic above
  is the same cap seen from the user's side.

- **The interface cannot carry the scheme past ~64 links.**
  `dump --stage=interface` on the same n = 1 000 module (411 529 bytes) prints
  the small ones and then gives up:

  ```
  module ConstraintChain
    value f1 : { r | m1 : number -> a } -> a
    value f10 : { r | m1 : number -> number2, m10 : number3 -> number2, … } -> number2
    value f100 : { m1 : number -> number2, m10 : num…
    value f1000 : <error>
  ```

  `f500`, `f900`, `f999` and `f1000` are all `value … : <error>` while
  `beni check` on the same tree exits **0 with no diagnostic** — consistent with
  `Schemes.Writer.max_depth = 512` (`src/check/Schemes.zig:93`) stopping the
  walk without a report. Both observations are C0 behaviour at `c870e9a`,
  untouched by the spike, and are flagged here as candidates for a corpus
  fixture rather than asserted as root-caused.

---

### M3 — interface churn (C0 side)

`plans/static-dispatch-spike.md` §7 M3. `bench/churn.sh` applies four edit
classes to every `pub` declaration and byte-diffs `dump --stage=raw` before and
after, in each of two variants (the declaration keeps its annotation /
the annotation is stripped). E1 changes a literal (the control), E2 duplicates
an operator application already used on a parameter, E3 adds a new `==` on any
parameter, and E3poly restricts E3 to a parameter the annotation types with a
**bare type variable** — the row report 18 §2.3 is actually about.

**Load before:** ` 13:47:03 up 3 days, 20:27,  5 users,  load average: 0.38, 0.86, 0.99`

```
$ direnv exec … sh bench/churn.sh --corpus=bench/corpus
corpus: bench/corpus
modules excluded (the pristine root does not resolve them): JsonCodecs.beni NotesApp.beni
tree restored: yes

edit    variant       changed/accepted  applied  skipped  rejected  decls
------  ------------  ----------------  -------  -------  --------  -----
E1      annotated               0/20       20       83         0    103
E1      unannotated             0/19       21       82         2    103
E2      annotated                0/1        2      101         1    103
E2      unannotated              0/1        4       99         3    103
E3      annotated               0/52       84       19        32    103
E3      unannotated             5/52       84       19        32    103
E3poly  annotated                0/0        5       98         5    103
E3poly  unannotated              4/4        7       96         3    103

real	1m3.154s
user	1m22.371s
sys	0m12.900s
```

**Load before:** ` 13:48:09 up 3 days, 20:29,  5 users,  load average: 1.35, 1.04, 1.04`

```
$ direnv exec … sh bench/churn.sh --corpus=core --core
corpus: core
tree restored: yes

edit    variant       changed/accepted  applied  skipped  rejected  decls
------  ------------  ----------------  -------  -------  --------  -----
E1      annotated               0/15       15      129         0    144
E1      unannotated             0/15       15      129         0    144
E2      annotated                0/7        8      136         1    144
E2      unannotated              0/7        8      136         1    144
E3      annotated               0/88      111       33        23    144
E3      unannotated             8/94      111       33        17    144
E3poly  annotated                0/0       16      128        16    144
E3poly  unannotated            14/14       16      128         2    144

real	0m57.694s
user	1m2.453s
sys	0m11.753s
```

Reading: on C0 the interface is **completely insensitive to a body edit while
the declaration keeps its annotation** — every `annotated` row is `0/…` on both
corpora, E3 and E3poly included. Strip the annotation and the picture splits:
E1 and E2 are still 0 (a literal change and a second use of an already-used
operation do not move the inferred scheme), but E3 moves it 5/52 on
`bench/corpus` and 8/94 on `core`, and **E3poly — the polymorphic-parameter row
— moves it on every single edit that applies: 4/4 and 14/14.** That is the C0
side of report 18 §2.3's claim, and it says the equivalent baseline edit already
changes the interface 100 % of the time once the parameter is a bare type
variable and the annotation is absent. The `annotated` E3poly rows are 0/0
because every such edit was *rejected* (5/5 and 16/16): with the annotation
present, adding `==` to a bare type variable does not type-check on C0, which
is itself the ergonomic finding.

---

### M4 — output size (C0 side)

`plans/static-dispatch-spike.md` §7 M4. `bench/size.mjs` builds every
`tests/corpus/run/` fixture and `bench/corpus` with `beni build` and reports
raw, gzip and brotli bytes (Node `zlib`). The **floor** line is the empty
program: the embedded `core/` that every program carries. `net_*` is a program
minus that floor. **Caveat, recorded per §9: no DCE exists yet, so every number
here is an upper bound.**

**Load before:** ` 13:49:34 up 3 days, 20:30,  5 users,  load average: 1.20, 1.11, 1.07`

```
$ direnv exec … node bench/size.mjs
{"floor":true,"entry":"Empty","files":21,"raw_bytes":65214,"gzip_bytes":15410,"brotli_bytes":12932,"derived_bytes":0,"derived_functions":0}
{"program":"bench/corpus","entry":"BenchMain (synthesised)","modules_measured":7,"modules_excluded":["Data/Parser.beni","ExprParser.beni","JsonCodecs.beni","NotesApp.beni"],"files":28,"raw_bytes":109053,"gzip_bytes":24085,"brotli_bytes":20423,"derived_bytes":0,"derived_functions":0,"net_raw_bytes":43839,"net_gzip_bytes":8675,"net_brotli_bytes":7491}
{"program":"tests/corpus/run/Adt.beni","entry":"Adt","files":21,"raw_bytes":66350,"gzip_bytes":15694,"brotli_bytes":13196,"derived_bytes":0,"derived_functions":0,"net_raw_bytes":1136,"net_gzip_bytes":284,"net_brotli_bytes":264}
{"program":"tests/corpus/run/Arithmetic.beni","entry":"Arithmetic","files":21,"raw_bytes":66218,"gzip_bytes":15591,"brotli_bytes":13101,"derived_bytes":0,"derived_functions":0,"net_raw_bytes":1004,"net_gzip_bytes":181,"net_brotli_bytes":169}
{"program":"tests/corpus/run/BindPipeRhs.beni","entry":"BindPipeRhs","files":21,"raw_bytes":66072,"gzip_bytes":15592,"brotli_bytes":13112,"derived_bytes":0,"derived_functions":0,"net_raw_bytes":858,"net_gzip_bytes":182,"net_brotli_bytes":180}
{"program":"tests/corpus/run/CaseLiterals.beni","entry":"CaseLiterals","files":21,"raw_bytes":65928,"gzip_bytes":15594,"brotli_bytes":13087,"derived_bytes":0,"derived_functions":0,"net_raw_bytes":714,"net_gzip_bytes":184,"net_brotli_bytes":155}
{"program":"tests/corpus/run/CharOps.beni","entry":"CharOps","files":21,"raw_bytes":66104,"gzip_bytes":15614,"brotli_bytes":13110,"derived_bytes":0,"derived_functions":0,"net_raw_bytes":890,"net_gzip_bytes":204,"net_brotli_bytes":178}
{"program":"tests/corpus/run/Closures.beni","entry":"Closures","files":21,"raw_bytes":66370,"gzip_bytes":15701,"brotli_bytes":13201,"derived_bytes":0,"derived_functions":0,"net_raw_bytes":1156,"net_gzip_bytes":291,"net_brotli_bytes":269}
{"program":"tests/corpus/run/Comparison.beni","entry":"Comparison","files":21,"raw_bytes":66271,"gzip_bytes":15582,"brotli_bytes":13132,"derived_bytes":0,"derived_functions":0,"net_raw_bytes":1057,"net_gzip_bytes":172,"net_brotli_bytes":200}
{"program":"tests/corpus/run/ConsPatterns.beni","entry":"ConsPatterns","files":21,"raw_bytes":66798,"gzip_bytes":15708,"brotli_bytes":13201,"derived_bytes":0,"derived_functions":0,"net_raw_bytes":1584,"net_gzip_bytes":298,"net_brotli_bytes":269}
{"program":"tests/corpus/run/DebugLog.beni","entry":"DebugLog","files":21,"raw_bytes":65837,"gzip_bytes":15561,"brotli_bytes":13032,"derived_bytes":0,"derived_functions":0,"net_raw_bytes":623,"net_gzip_bytes":151,"net_brotli_bytes":100}
{"program":"tests/corpus/run/Dictionaries.beni","entry":"Dictionaries","files":21,"raw_bytes":66145,"gzip_bytes":15635,"brotli_bytes":13114,"derived_bytes":0,"derived_functions":0,"net_raw_bytes":931,"net_gzip_bytes":225,"net_brotli_bytes":182}
{"program":"tests/corpus/run/ExitCode.beni","entry":"ExitCode","files":21,"raw_bytes":65407,"gzip_bytes":15472,"brotli_bytes":12983,"derived_bytes":0,"derived_functions":0,"net_raw_bytes":193,"net_gzip_bytes":62,"net_brotli_bytes":51}
{"program":"tests/corpus/run/HigherOrder.beni","entry":"HigherOrder","files":21,"raw_bytes":66469,"gzip_bytes":15734,"brotli_bytes":13202,"derived_bytes":0,"derived_functions":0,"net_raw_bytes":1255,"net_gzip_bytes":324,"net_brotli_bytes":270}
{"program":"tests/corpus/run/ImportedModule.beni","entry":"ImportedModule","files":21,"raw_bytes":65847,"gzip_bytes":15558,"brotli_bytes":13084,"derived_bytes":0,"derived_functions":0,"net_raw_bytes":633,"net_gzip_bytes":148,"net_brotli_bytes":152}
{"program":"tests/corpus/run/Interpolation.beni","entry":"Interpolation","files":21,"raw_bytes":65879,"gzip_bytes":15633,"brotli_bytes":13148,"derived_bytes":0,"derived_functions":0,"net_raw_bytes":665,"net_gzip_bytes":223,"net_brotli_bytes":216}
{"program":"tests/corpus/run/LetNesting.beni","entry":"LetNesting","files":21,"raw_bytes":65919,"gzip_bytes":15610,"brotli_bytes":13095,"derived_bytes":0,"derived_functions":0,"net_raw_bytes":705,"net_gzip_bytes":200,"net_brotli_bytes":163}
{"program":"tests/corpus/run/LibraryArgumentOrder.beni","entry":"LibraryArgumentOrder","files":21,"raw_bytes":66948,"gzip_bytes":15797,"brotli_bytes":13266,"derived_bytes":0,"derived_functions":0,"net_raw_bytes":1734,"net_gzip_bytes":387,"net_brotli_bytes":334}
{"program":"tests/corpus/run/ListBuild.beni","entry":"ListBuild","files":21,"raw_bytes":66385,"gzip_bytes":15624,"brotli_bytes":13131,"derived_bytes":0,"derived_functions":0,"net_raw_bytes":1171,"net_gzip_bytes":214,"net_brotli_bytes":199}
{"program":"tests/corpus/run/ListFold.beni","entry":"ListFold","files":21,"raw_bytes":66587,"gzip_bytes":15689,"brotli_bytes":13174,"derived_bytes":0,"derived_functions":0,"net_raw_bytes":1373,"net_gzip_bytes":279,"net_brotli_bytes":242}
{"program":"tests/corpus/run/MaybeResult.beni","entry":"MaybeResult","files":21,"raw_bytes":66604,"gzip_bytes":15701,"brotli_bytes":13167,"derived_bytes":0,"derived_functions":0,"net_raw_bytes":1390,"net_gzip_bytes":291,"net_brotli_bytes":235}
{"program":"tests/corpus/run/NumericEdge.beni","entry":"NumericEdge","files":21,"raw_bytes":66621,"gzip_bytes":15650,"brotli_bytes":13148,"derived_bytes":0,"derived_functions":0,"net_raw_bytes":1407,"net_gzip_bytes":240,"net_brotli_bytes":216}
{"program":"tests/corpus/run/Patterns.beni","entry":"Patterns","files":21,"raw_bytes":66398,"gzip_bytes":15699,"brotli_bytes":13185,"derived_bytes":0,"derived_functions":0,"net_raw_bytes":1184,"net_gzip_bytes":289,"net_brotli_bytes":253}
{"program":"tests/corpus/run/PipeFirst.beni","entry":"PipeFirst","files":21,"raw_bytes":66117,"gzip_bytes":15594,"brotli_bytes":13107,"derived_bytes":0,"derived_functions":0,"net_raw_bytes":903,"net_gzip_bytes":184,"net_brotli_bytes":175}
{"program":"tests/corpus/run/PipeNestedGrouping.beni","entry":"PipeNestedGrouping","files":21,"raw_bytes":66062,"gzip_bytes":15557,"brotli_bytes":13063,"derived_bytes":0,"derived_functions":0,"net_raw_bytes":848,"net_gzip_bytes":147,"net_brotli_bytes":131}
{"program":"tests/corpus/run/Placeholder.beni","entry":"Placeholder","files":21,"raw_bytes":66320,"gzip_bytes":15642,"brotli_bytes":13131,"derived_bytes":0,"derived_functions":0,"net_raw_bytes":1106,"net_gzip_bytes":232,"net_brotli_bytes":199}
{"program":"tests/corpus/run/PlaceholderAndBind.beni","entry":"PlaceholderAndBind","files":21,"raw_bytes":66644,"gzip_bytes":15732,"brotli_bytes":13208,"derived_bytes":0,"derived_functions":0,"net_raw_bytes":1430,"net_gzip_bytes":322,"net_brotli_bytes":276}
{"program":"tests/corpus/run/Records.beni","entry":"Records","files":21,"raw_bytes":65867,"gzip_bytes":15582,"brotli_bytes":13125,"derived_bytes":0,"derived_functions":0,"net_raw_bytes":653,"net_gzip_bytes":172,"net_brotli_bytes":193}
{"program":"tests/corpus/run/Recursion.beni","entry":"Recursion","files":21,"raw_bytes":66315,"gzip_bytes":15655,"brotli_bytes":13146,"derived_bytes":0,"derived_functions":0,"net_raw_bytes":1101,"net_gzip_bytes":245,"net_brotli_bytes":214}
{"program":"tests/corpus/run/RestOfBlockBind.beni","entry":"RestOfBlockBind","files":21,"raw_bytes":66247,"gzip_bytes":15686,"brotli_bytes":13197,"derived_bytes":0,"derived_functions":0,"net_raw_bytes":1033,"net_gzip_bytes":276,"net_brotli_bytes":265}
{"program":"tests/corpus/run/SaturatedCalls.beni","entry":"SaturatedCalls","files":21,"raw_bytes":66693,"gzip_bytes":15730,"brotli_bytes":13235,"derived_bytes":0,"derived_functions":0,"net_raw_bytes":1479,"net_gzip_bytes":320,"net_brotli_bytes":303}
{"program":"tests/corpus/run/ShortCircuit.beni","entry":"ShortCircuit","files":21,"raw_bytes":65635,"gzip_bytes":15526,"brotli_bytes":13012,"derived_bytes":0,"derived_functions":0,"net_raw_bytes":421,"net_gzip_bytes":116,"net_brotli_bytes":80}
{"program":"tests/corpus/run/Sorting.beni","entry":"Sorting","files":21,"raw_bytes":66196,"gzip_bytes":15642,"brotli_bytes":13164,"derived_bytes":0,"derived_functions":0,"net_raw_bytes":982,"net_gzip_bytes":232,"net_brotli_bytes":232}
{"program":"tests/corpus/run/StringBuilding.beni","entry":"StringBuilding","files":21,"raw_bytes":66052,"gzip_bytes":15633,"brotli_bytes":13124,"derived_bytes":0,"derived_functions":0,"net_raw_bytes":838,"net_gzip_bytes":223,"net_brotli_bytes":192}
{"program":"tests/corpus/run/StringOps.beni","entry":"StringOps","files":21,"raw_bytes":66350,"gzip_bytes":15710,"brotli_bytes":13229,"derived_bytes":0,"derived_functions":0,"net_raw_bytes":1136,"net_gzip_bytes":300,"net_brotli_bytes":297}
{"program":"tests/corpus/run/Tuples.beni","entry":"Tuples","files":21,"raw_bytes":66402,"gzip_bytes":15724,"brotli_bytes":13218,"derived_bytes":0,"derived_functions":0,"net_raw_bytes":1188,"net_gzip_bytes":314,"net_brotli_bytes":286}
{"total":true,"programs":35,"files":742,"raw_bytes":143834,"gzip_bytes":31997,"brotli_bytes":27563,"floor_raw_bytes":65214,"floor_gzip_bytes":15410,"floor_brotli_bytes":12932,"net_raw_bytes":78620,"net_gzip_bytes":16587,"net_brotli_bytes":14631,"gross_raw_bytes":2361110,"gross_gzip_bytes":555937,"gross_brotli_bytes":467251,"derived_bytes":0,"derived_functions":0}
```

Reading: the **floor is 65 214 raw / 15 410 gzip / 12 932 brotli bytes** — the
whole of embedded `core/` in 21 files, shipped by the empty program, and it
dwarfs every fixture's own code (the largest `run/` net is
`LibraryArgumentOrder` at 1 734 raw / 334 brotli). Across 35 programs the
**net** total is 78 620 raw / 16 587 gzip / 14 631 brotli bytes against a
**gross** of 2 361 110 / 555 937 / 467 251 — i.e. 97 % of what C0 ships today is
the undeduplicated, un-eliminated core floor, which is the number the "grows
per type × method" row of report 18 §1.5 has to be read against.
`derived_bytes` and `derived_functions` are **0** by construction on C0: there
is no derivation to attribute yet, and those two fields exist so the C1 run has
a place to put the per-type cost.

---

### M5 — runtime of the emitted JavaScript (C0 side)

`plans/static-dispatch-spike.md` §7 M5. `bench/runtime.mjs` builds each
`bench/runtime/c0/*.beni` program with `beni build` and runs it under Node,
20 runs, reporting best, median and ns/op net of a measured process `floor_ms`.
`checksum` is printed by the program itself so a variant that computes
something different cannot be compared by accident.

**Load before:** ` 13:50:40 up 3 days, 20:31,  5 users,  load average: 0.55, 0.94, 1.01`

```
$ direnv exec … node bench/runtime.mjs --runs=20
{"program":"R1DictString","variant":"c0","runs":20,"ops":120000,"floor_ms":35.25,"best_ms":314.4,"median_ms":336.2,"ns_per_op":2326.3,"checksum":"60000 288894"}
{"program":"R2DictRecord","variant":"c0","runs":20,"ops":120000,"floor_ms":35.66,"best_ms":144.35,"median_ms":147.33,"ns_per_op":905.8,"checksum":"60000 18600000"}
{"program":"R3Sorting","variant":"c0","runs":20,"ops":120000,"floor_ms":35.31,"best_ms":181.94,"median_ms":183.84,"ns_per_op":1221.9,"checksum":"4000 499313"}
{"program":"R4Equality","variant":"c0","runs":20,"ops":220200,"floor_ms":35.55,"best_ms":199.94,"median_ms":203.1,"ns_per_op":746.5,"checksum":"400 20000 200 0 6"}
{"program":"R5EvidenceForwarding","variant":"c0","runs":20,"ops":10000000,"floor_ms":35.83,"best_ms":144.29,"median_ms":148.4,"ns_per_op":10.8,"checksum":"5000000"}
{"program":"R6Megamorphic","variant":"c0","runs":20,"ops":3000000,"floor_ms":35.1,"best_ms":209.81,"median_ms":232.76,"ns_per_op":58.2,"checksum":"1352000"}

real	0m30.552s
user	0m31.524s
sys	0m5.165s
```

Reading: the C0 numbers the branch is measured against are
**R1 2 326.3 ns/op** (`Dict` of `String` keys, the comparator passed as a
closure), **R2 905.8**, **R3 1 221.9**, **R4 746.5**, **R5 10.8** (the closure
that dispatch replaces with an evidence parameter, three generics deep) and
**R6 58.2** (the same at three types in one loop — the inline-cache row).
R5 at 10.8 ns/op over 10 M ops is the tightest of the six and is where an
evidence parameter has the least room to hide.

#### `--cpu-prof` on R4 and R6

**Load before:** ` 13:51:15 up 3 days, 20:32,  5 users,  load average: 1.01, 1.02, 1.03`

```
$ direnv exec … node bench/runtime.mjs --runs=20 --cpu-prof --program=R4Equality --program=R6Megamorphic --prof-dir=…/prof
{"program":"R4Equality","variant":"c0","runs":20,"ops":220200,"floor_ms":34.83,"best_ms":200.36,"median_ms":202.43,"ns_per_op":751.7,"checksum":"400 20000 200 0 6","cpu_prof_dir":"…/prof"}
{"program":"R6Megamorphic","variant":"c0","runs":20,"ops":3000000,"floor_ms":35.25,"best_ms":218.07,"median_ms":233.77,"ns_per_op":60.9,"checksum":"1352000","cpu_prof_dir":"…/prof"}
```

Top 10 by self time, summed from the `.cpuprofile`'s `samples` × `timeDeltas`
(V8 emits one node per call site / optimisation tier, so the same function name
appears more than once and the duplicates are kept as V8 reported them):

```
# R4Equality — CPU.20260917.135121.2599885.0.001.cpuprofile  total sampled 193.9 ms
    49.2 ms   25.4%  structuralEq  Basics.foreign.mjs:93
    15.5 ms    8.0%  (garbage collector)
    14.8 ms    7.6%  structuralEq  Basics.foreign.mjs:93
    13.7 ms    7.1%  structuralEq  Basics.foreign.mjs:93
    12.7 ms    6.6%  foldl  List.foreign.mjs:22
    11.8 ms    6.1%  (program)
    11.7 ms    6.0%  (anonymous)  R4Equality.mjs:39
    11.6 ms    6.0%  (anonymous)  R4Equality.mjs:35
    10.7 ms    5.5%  eq  Basics.foreign.mjs:110
     7.5 ms    3.8%  structuralEq  Basics.foreign.mjs:93

# R6Megamorphic — CPU.20260917.135126.2600191.0.001.cpuprofile  total sampled 208.8 ms
    37.6 ms   18.0%  codePoints  String.foreign.mjs:24
    34.2 ms   16.4%  (anonymous)  R6Megamorphic.mjs:24
    27.6 ms   13.2%  (garbage collector)
    16.6 ms    8.0%  R6Megamorphic$tally  R6Megamorphic.mjs:17
    14.8 ms    7.1%  (anonymous)  R6Megamorphic.mjs:25
    11.1 ms    5.3%  (program)
     8.5 ms    4.1%  (anonymous)  R6Megamorphic.mjs:23
     5.4 ms    2.6%  codePoints  String.foreign.mjs:24
     5.4 ms    2.6%  (anonymous)  R6Megamorphic.mjs:23
     5.3 ms    2.6%  (anonymous)  R6Megamorphic.mjs:25
```

Reading: on **R4** the four `structuralEq` nodes sum to **43.9 %** of sampled
time plus **5.5 %** in its `eq` wrapper — i.e. **almost half of C0's equality
benchmark is the one shared structural walk in `core/Basics.js:93-111`**, which
is exactly the code derived `eq` replaces, and the single largest thing report
18 §1.4's runtime argument has to beat. On **R6** no dispatch-shaped frame
dominates: the cost is `String.codePoints` (20.6 % across two nodes), the loop
bodies, and 13.2 % garbage collection. C0 has no polymorphic call site to
inline-cache in R6, so this profile is the *reference* shape — the branch's R6
profile is what tells us whether V8 inlines the evidence-parameter call, and
that comparison cannot be made from this side alone.

Note: `--prof-dir` also held two `.cpuprofile` files dated 10:52 from an earlier
run in the same directory; only the two 13:51 files above are from this
measurement.

---

### M8 — ergonomics (C0 side)

`plans/static-dispatch-spike.md` §7 M8. These are **not** an instrument run:
they are the counts established by hand in
[`plans/static-dispatch-c1-rewrite.md`](static-dispatch-c1-rewrite.md) §1 and
§6.2 while that plan was written, against `master` at `f466aac`. They are
copied here verbatim so report 19 can cite the C0 side from one place; the C1
column is what S6 has to produce.

§1 — comparator arguments and the two sugar modules:

| Measure | C0 | C1 | Where |
|---|---|---|---|
| **call sites passing an ordering function as an argument** to a `Dict`/`Set`/`List` builder | **17** | **0** | c1-rewrite §2–§4 |
|  of those in `core/` | 7 | 0 | `Dict/String.beni` ×3, `Dict/Int.beni` ×3, `List.beni:370` |
|  of those in `bench/corpus/` | 4 | 0 | `NotesApp:84`, `DictExtra:47,159`, `FormValidation:204` |
|  of those in `tests/corpus/` | 6 | 0 | `run/Dictionaries:14`, `parse/good/DictCache:17`, `parse/good/LongModule:85,90,285,744` |
| **comparators threaded onward** inside core | 4 in `Set.beni` (`empty:36`, `singleton:44`, `fromList:117`, `map:128`) + 4 private helper chains in `Dict.beni` (`getHelp:85`, `insertHelp:165`, `removeHelp:227`, `removeHelpEQGT:287`) | 0 | c1-rewrite §2.2, §2.3 |
| **declarations taking a comparator parameter** | **15** — `Dict` 7 (`:60,69,85,165,227,287,594`), `Set` 4 (`:36,44,117,128`), `List` 3 (`:387,431,436`), `DictExtra` 1 (`:144`) | **4** | survivors are `List.sortWith:387`, `mergeWith:431`, `mergeWithHelp:436`, `DictExtra.toSortedList:144` (rule 2). `Dict.comparatorOf:469` is not counted: it *returns* a comparator and takes none |
| `Dict.String` / `Dict.Int` import lines | 7 | 0 | c1-rewrite §3 |
| `Dict.String` / `Dict.Int` use sites | 16 lines, 17 occurrences (`DictExtra.beni:108` has two) | 0 | c1-rewrite §3 |
| core modules deleted | — | 2 (`core/Dict/String.beni` 42 lines, `core/Dict/Int.beni` 38 lines) | c1-rewrite §2.1 |
| modules in the three trees declaring ≥ 2 nominal types | 21 | 21 | c1-rewrite §6 |

Headline: **17 ordering arguments → 0, and 15 comparator parameters → 4**, the
four survivors being the ones that were never the tax (they order by something
that is not the type's own order).

§6.2 — the module-rule namespace question:

| | Count |
|---|---|
| modules declaring ≥ 2 nominal types | 21 |
| of those, in `core/` | 2 |
| colliding **today** | **1** (`core/Basics.beni`), plus 1 latent (`core/Dict.beni`, both extra types private) |
| colliding **under the style the module rule rewards** | **6** — `core/Basics.beni`, `core/Dict.beni`, `bench/corpus/ExprParser.beni`, `bench/corpus/JsonCodecs.beni`, `bench/corpus/PrettyPrinter.beni`, `bench/corpus/Router.beni` |
| fixtures with ≥ 2 types and **no** `pub` values, so the question does not arise | 7 |

The full 21-module file list with per-module verdicts is
`plans/static-dispatch-c1-rewrite.md` §6.1, and the 22 alias-only modules
excluded from the count are §6.3.

Reading: on the module rule, **one module collides today and six would collide
once code is written in the style the rule rewards** — and the one that bites
now is `core/Basics.beni`, the first module of the standard library, where
seven types want `compare` and seven want `eq`. That is bought off by
`docs/design/static-dispatch-spike.md` §3.2's well-known table and §5.1's move
of `String` and `Char` out of `Basics`, and the fact that the workaround was
needed at all is itself the finding.

---

### M7 — compiler cost (harness only)

`plans/static-dispatch-spike.md` §7 M7. **This is the cost of the S1 harness,
not of the spike.** The spike's own compiler cost is the same four numbers taken
again at S8; this row exists so that comparison has a floor.

**Load before:** ` 13:53:02 up 3 days, 20:33,  5 users,  load average: 0.20, 0.74, 0.93`

```
$ git diff --stat master..c870e9a
 bench/bench.zig                                    |   75 +-
 bench/churn.sh                                     |  709 ++++++
 bench/gen.zig                                      |  943 ++++++-
 bench/runtime.mjs                                  |  287 +++
 bench/runtime/c0/R1DictString.beni                 |   48 +
 bench/runtime/c0/R2DictRecord.beni                 |   58 +
 bench/runtime/c0/R3Sorting.beni                    |  102 +
 bench/runtime/c0/R4Equality.beni                   |  268 ++
 bench/runtime/c0/R5EvidenceForwarding.beni         |  105 +
 bench/runtime/c0/R6Megamorphic.beni                |  162 ++
 bench/size.mjs                                     |  481 ++++
 .../20-roc-static-dispatch-implementation.md       | 1701 +++++++++++++
 docs/design/static-dispatch-spike.md               | 2691 ++++++++++++++++++++
 plans/static-dispatch-c1-rewrite.md                |  436 ++++
 src/Profile.zig                                    |    8 +
 src/Session.zig                                    |   11 +-
 src/check/Check.zig                                |   14 +-
 src/check/Solve.zig                                |   36 +
 tests/blackbox/build_test.zig                      |  458 ++++
 19 files changed, 8512 insertions(+), 81 deletions(-)
```

Per directory (`git diff --numstat master..c870e9a`, folded):

```
bench              5 files  +2430   -65
bench/runtime      6 files  +743    -0
docs/design        2 files  +4392   -0
plans              1 files  +436    -0
src                4 files  +53     -16
tests              1 files  +458    -0
```

The whole of the `src/` half is the counter plumbing — five `= 0` fields on
`Solve.Counters` with their doc block, the matching `Profile.Counter` names, a
reflective `Counters.add`, and two call sites switched to it (`Check.zig`'s two
hand-written sums and `Session.checkSerial`'s four `addCounter` lines becoming
an `inline for`). Nothing in constrain, solve, generalisation, lowering or
emission is touched.

**Wall times.** `rm -rf .zig-cache zig-out` in the worktree first. Zig's
**global** cache (`~/.cache/zig`, 404 MB) was **not** cleared, per the
instruction to touch only `.zig-cache`/`zig-out`, so these are cold-local /
warm-global numbers:

```
$ rm -rf .zig-cache zig-out
$ time direnv exec … zig build -Doptimize=ReleaseFast
real	1m8.793s
user	1m9.324s
sys	0m0.714s

$ stat -c '%s bytes' zig-out/bin/beni
13317664 bytes

$ time direnv exec … zig build test
real	0m11.483s
user	0m14.996s
sys	0m1.552s
```

Warm repeats immediately after, to separate compile from run
(load ` 13:54:39 … load average: 1.11, 0.90, 0.97`):

```
$ time direnv exec … zig build test
real	0m9.210s
user	0m9.109s
sys	0m0.843s

$ time direnv exec … zig build -Doptimize=ReleaseFast
real	0m0.135s
user	0m0.069s
sys	0m0.075s
```

Reading: **ReleaseFast from a clean `.zig-cache` is 68.8 s**, the installed
binary is **13 317 664 bytes (12.7 MiB)**, and **`zig build test` is 11.5 s**.
The 0.135 s warm rebuild confirms the 68.8 s was real compilation and not cache
probing; the 9.2 s warm `zig build test` against the 11.5 s first run says that
run was mostly the tests executing, the Debug artifacts having been served from
the uncleared global cache — so 11.5 s is a *warm-global* figure and the S8
comparison must be taken the same way to be comparable. `zig build test` passed
on both runs.

---

### Summary — S1 baselines, C0 at c870e9a

| Row | Headline |
|---|---|
| M1a | check **71.77 ms / 1.396 M LOC/s**, total **139.6 ms** on 624 files / 100 159 lines; all five new constraint counters **0** |
| M1a (`--dispatch`) | front end flat (lex 9.7 / parse 6.9 / lower 9.8 ms on +51 855 bytes); **`check` not meaningful before S3** — 1 682 diagnostics, 83.39 ms of *failing* |
| M2 | C0 row-polymorphic chain: **2.00 / 5.76 / 275.89 ms** for n = 10 / 100 / 1 000; n ≥ 2 000 breaks (1 diagnostic) and plateaus ~280–300 ms; rendered scheme saturates at **65 fields / ~1 760 chars**; interface entry is `<error>` past ~64 links |
| M3 | annotated: **0 interface changes in every class, both corpora**. Unannotated: E1/E2 0, E3 **5/52** and **8/94**, **E3poly 4/4 and 14/14** |
| M4 | floor **65 214 raw / 15 410 gzip / 12 932 brotli**; 35 programs net **78 620 / 16 587 / 14 631** vs gross **2 361 110 / 555 937 / 467 251**; `derived_bytes` 0 |
| M5 | ns/op — R1 **2 326.3**, R2 **905.8**, R3 **1 221.9**, R4 **746.5**, R5 **10.8**, R6 **58.2**; R4 profile is **43.9 % `structuralEq`** + 5.5 % `eq` |
| M7 | harness diff **19 files, +8 512 −81** (`src/` only +53 −16, counters); ReleaseFast cold-local **68.8 s**; binary **13 317 664 B**; `zig build test` **11.5 s** |
| M8 | **17 ordering arguments → 0**, **15 comparator parameters → 4**, 7 `Dict.String`/`Dict.Int` imports and 17 use sites → 0; **1 module collides today** under the module rule, **6** under the style it rewards |

Not captured in this session: **M1b** (needs C1 and the branch checker),
**M6** (needs the `check/bad/` fixtures of the spike), **M9** (a branch gate),
and the C1 column of every row — all of them are S8 work by construction.

---

## 2026-09-17 — S3, M2 after the attach fix

`bench/gen.zig --pathological=constraint-chain=<n>` (plan §7 M2), best of 5
after one warm-up, `--jobs=1`, interleaved **ABBA**: A is the S1 harness
binary at `c870e9a` (`../beni-s1`, no dispatch in the checker at all), B is
this branch with S3. Load average 1.5 on an otherwise idle machine; the two
binaries are built from the same Zig and run back to back.

The fix under test is `attachConstraint`: it rebuilt the whole constraint set
on every attach, which is quadratic in the set — and a chain is exactly the
input that walks into it. A set is a half-open range of an append-only list,
so it now costs one append when the old range ends at the tail and one copy
otherwise (`TypeStore.extendConstraints`). `promote`'s duplicate check moved
from a per-constraint scan to a per-VARIABLE one for the same reason.

```
$ … zig build bench -- --pathological=constraint-chain=1000 --iterations=5
A {"phase":"check","modules":12,"lines":3008,"unifications":20216,"generalisations":1509367,"instantiations":5622,"obligations":3,"constraints_created":0,"constraints_merged":0,"constraints_deferred":0,"constraints_discharged":0,"constraints_promoted":0,"diagnostics":0,"ms":280.76,"loc_per_s":10713,"cold_check_ms":283.5}
B {"phase":"check","modules":12,"lines":3008,"unifications":16199,"generalisations":1007901,"instantiations":5589,"obligations":1014,"constraints_created":1007,"constraints_merged":1999,"constraints_deferred":1014,"constraints_discharged":40,"constraints_promoted":500500,"diagnostics":0,"ms":483.51,"loc_per_s":6221,"cold_check_ms":486.3}
B {"phase":"check","modules":12,"lines":3008,"unifications":16199,"generalisations":1007901,"instantiations":5589,"obligations":1014,"constraints_created":1007,"constraints_merged":1999,"constraints_deferred":1014,"constraints_discharged":40,"constraints_promoted":500500,"diagnostics":0,"ms":493.67,"loc_per_s":6093,"cold_check_ms":496.5}
A {"phase":"check","modules":12,"lines":3008,"unifications":20216,"generalisations":1509367,"instantiations":5622,"obligations":3,"constraints_created":0,"constraints_merged":0,"constraints_deferred":0,"constraints_discharged":0,"constraints_promoted":0,"diagnostics":0,"ms":289.37,"loc_per_s":10394,"cold_check_ms":292.1}

$ … zig build bench -- --pathological=constraint-chain=2000 --iterations=5
A {"phase":"check","modules":12,"lines":6008,"unifications":33268,"generalisations":1599447,"instantiations":9622,"obligations":3,"constraints_created":0,"constraints_merged":0,"constraints_deferred":0,"constraints_discharged":0,"constraints_promoted":0,"diagnostics":1,"ms":301.84,"loc_per_s":19904,"cold_check_ms":306.2}
B {"phase":"check","modules":12,"lines":6008,"unifications":27199,"generalisations":4013901,"instantiations":9589,"obligations":2014,"constraints_created":2007,"constraints_merged":3999,"constraints_deferred":2014,"constraints_discharged":40,"constraints_promoted":2001000,"diagnostics":0,"ms":2061.24,"loc_per_s":2914,"cold_check_ms":2065.7}
B {"phase":"check","modules":12,"lines":6008,"unifications":27199,"generalisations":4013901,"instantiations":9589,"obligations":2014,"constraints_created":2007,"constraints_merged":3999,"constraints_deferred":2014,"constraints_discharged":40,"constraints_promoted":2001000,"diagnostics":0,"ms":2099.30,"loc_per_s":2861,"cold_check_ms":2104.1}
A {"phase":"check","modules":12,"lines":6008,"unifications":33268,"generalisations":1599447,"instantiations":9622,"obligations":3,"constraints_created":0,"constraints_merged":0,"constraints_deferred":0,"constraints_discharged":0,"constraints_promoted":0,"diagnostics":1,"ms":301.84,"loc_per_s":19904,"cold_check_ms":306.2}
```

| n | A (`c870e9a`) | B (S3) | B ÷ A | `constraints_promoted` |
|---|---|---|---|---|
| 1000 | 280.8 / 289.4 ms | 483.5 / 493.7 ms | **1.71×** | 500 500 |
| 2000 | 301.8 / 311.3 ms | 2061.2 / 2099.3 ms | **6.8×** | 2 001 000 |

**Read the ratio with two caveats.** A at n = 2000 reports `diagnostics: 1`:
the C0 chain stops checking past ~64 links (S1's M2 row records it), so it
is not doing the same work and the 6.8× is against a run that gave up. And
the growth that remains is the FEATURE, not the bookkeeping: link `k` of an
unannotated chain accumulates `k` constraints, so a chain of `n` promotes
n(n+1)/2 of them and the dispatch table gains one row per evidence argument
of every call — 2 001 000 at n = 2000. That accumulation is exactly what M2
exists to measure, and report 18 §2.3 is the claim it is measuring. What the
fix removed was the extra factor on top of it: before it, the same n = 2000
tree could not be measured at all at this budget.

`constraints_created` is now one per *new* name on a variable (2 007) and
`constraints_merged` one per union of two sets (3 999); before the fix both
counted every attach.
