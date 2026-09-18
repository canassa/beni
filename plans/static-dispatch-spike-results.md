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

---

## 2026-09-17 — S5, M5 R4 (derived `eq` against the structural walk)

`plans/static-dispatch-spike.md` §7 M5, R4 only: it is the one program of the
six whose work is `==`. R6 is here because it contains one `==` as well —
on an `Int`, which §3.2 has answered with `===` since S4, so it is the control
that says the machine did not move under the measurement.

**Interleaved ABBA on one machine state, not against the S1 row.** A is the
branch at `c63ae48` (S4: every `==` still routed to `core/Basics.js`'s single
structural walk through A.51's bridge), B is S5 (the derived `eq` of §9).
Both are Debug compilers building the same `bench/runtime/c0/*.beni` sources —
the measurement is of the EMITTED JavaScript under Node, so the compiler's own
optimisation level is not in it. 20 runs each, best and median, net of a
measured process floor.

**Load before:** ` 23:18:45 up 4 days,  5:59,  3 users,  load average: 0.48, 1.04, 1.19`
**Load after:** ` 23:19:44 up 4 days,  6:00,  3 users,  load average: 0.80, 1.02, 1.17`

```
$ direnv exec … node bench/runtime.mjs --runs=20 --program=R4Equality --program=R6Megamorphic --beni=<A>
A {"program":"R4Equality","variant":"c0","runs":20,"ops":220200,"floor_ms":35.85,"best_ms":198.21,"median_ms":200.43,"ns_per_op":737.3,"checksum":"400 20000 200 0 6"}
A {"program":"R6Megamorphic","variant":"c0","runs":20,"ops":3000000,"floor_ms":34.75,"best_ms":160.04,"median_ms":163.4,"ns_per_op":41.8,"checksum":"1352000"}
B {"program":"R4Equality","variant":"c0","runs":20,"ops":220200,"floor_ms":35.38,"best_ms":151.02,"median_ms":156.1,"ns_per_op":525.2,"checksum":"400 20000 200 0 6"}
B {"program":"R6Megamorphic","variant":"c0","runs":20,"ops":3000000,"floor_ms":35.85,"best_ms":158.65,"median_ms":162.8,"ns_per_op":40.9,"checksum":"1352000"}
B {"program":"R4Equality","variant":"c0","runs":20,"ops":220200,"floor_ms":35.30,"best_ms":152.86,"median_ms":156.52,"ns_per_op":533.9,"checksum":"400 20000 200 0 6"}
B {"program":"R6Megamorphic","variant":"c0","runs":20,"ops":3000000,"floor_ms":35.15,"best_ms":160.12,"median_ms":163.22,"ns_per_op":41.7,"checksum":"1352000"}
A {"program":"R4Equality","variant":"c0","runs":20,"ops":220200,"floor_ms":35.28,"best_ms":198.89,"median_ms":202.09,"ns_per_op":743.0,"checksum":"400 20000 200 0 6"}
A {"program":"R6Megamorphic","variant":"c0","runs":20,"ops":3000000,"floor_ms":34.76,"best_ms":160.57,"median_ms":162.35,"ns_per_op":41.9,"checksum":"1352000"}
```

| Program | A — S4 bridge (ns/op) | B — S5 derived (ns/op) | B ÷ A |
|---|---|---|---|
| R4Equality | 737.3 / 743.0 | **525.2** / 533.9 | **0.71×** (−28.8 %) |
| R6Megamorphic | 41.8 / 41.9 | 40.9 / 41.7 | 0.98× (noise) |

Reading: **a derived `eq` is 1.40× faster than the one structural walk** on
R4's mix of a five-field record, a 1 000-element list of ADTs and a nested
`Maybe (List Int)`. The `checksum` is byte-identical across all four runs —
`400 20000 200 0 6`, whose fourth field is R4's `nearMisses` counter and must
stay 0 — so the two are computing the same answers and the ratio is a
like-for-like one. R6 does not move, which is what a program whose only `==`
is on an `Int` should do.

**What the number is NOT.** R4 still contains one comparison S5 does not
derive: `List a` is a `foreign type`, no module writes a body for it (A.55,
A.60) and §5.2's `pub foreign eq` is S6's, so the list of ADTs and the nested
`Maybe (List Int)` still go through `Basics.eq` — with the *elements* walked
structurally too, since the bridge is all-or-nothing. The 28.8 % is therefore
a LOWER bound on what §9 buys on this program, and S6 should move it again.

**Do not compare this to the S1 M5 row.** S1 measured R4 at 746.5 and R6 at
58.2 on `master` on 2026-09-17 at 13:50; the same R6 measures 41.8 today on a
binary that changed nothing about it. The machine moved between sessions by
more than the effect being measured on that row, which is exactly why
`bench/README.md` asks for interleaved runs and why this row carries its own A.

**`derived_bytes` has left zero.** Not a timed row, but the M4 counter S1
recorded as 0 is now non-zero for every program: derivation is eager (A.23),
so core alone ships four derived functions — `Maybe$Maybe$eq`,
`Result$Result$eq`, `Dict$Tree$eq`, `Dict$NColor$eq` — in the floor that every
build carries, plus one per nominal type and one per structural shape the
program itself uses. `bench/size.mjs` counts them today
(`tests/blackbox/build_test.zig`, the two `size.mjs` scenarios); the full M4
table is S8's.

---

## 2026-09-18 — S6, C1: the corpus with the comparator removed

**Machine:** Intel N100, 4 cores / 4 threads, 6 MiB L3, single memory
channel, 16 GB RAM, Linux 7.2.2, Zig 0.16.0, Node v24.19.0, ReleaseFast.

**Binary under test:** a `-Doptimize=ReleaseFast` build of the working tree at
S6b (`8081b5f` plus the C1 rewrite), installed to `/tmp/rf/bin/beni` so that
`zig-out/bin/beni` — the Debug binary the black-box gates drive — was not
disturbed. The **C0** side of M5 is `../beni-s1` at `c870e9a`, the same
ReleaseFast binary the S1 baselines were taken with, run back to back with the
C1 side in the same minutes; the C0 sides of M3, M4 and M8 are the rows already
in this file at `:220`, `:293` and `:448` and are **not** re-run or edited here.

**Corpus:** C1 — `core/` with the comparator argument gone from `Dict`, `Set`
and the `List` sort family, `core/Dict/String.beni` and `core/Dict/Int.beni`
deleted, the six `bench/corpus/` modules and the `tests/corpus/` fixtures
rewritten by hand, and `bench/runtime/c1/`.

`uptime` is recorded immediately before each instrument; per `bench/README.md`
no number is recorded while the 1-minute load average is above 2.0.

**Two rows were re-taken after S6b's review fixes and say so where they sit**:
the M1b `--dispatch` block and the whole of M4. They are the two the fixes
could move — the checker instantiates a callee's `where` clause once per
instruction now, and `tests/corpus/run/Dictionaries.beni` builds again — so
they are measured on the finished tree rather than on the tree the rest of
this entry was taken from. Every other row is the earlier binary's and is not
edited.

---

### M1b — what USING the feature costs (C1 side)

`plans/static-dispatch-spike.md` §7 M1b. Instrument: `zig build bench`, best of
5 after one warm-up, `jobs = 1` throughout. Read against M1a's C0 rows at `:37`
and `:66`, which were taken on the same machine with the same generator.

**Load before:** ` 03:39:44 up 4 days, 10:20,  3 users,  load average: 0.64, 1.08, 0.98`

```
$ direnv exec . zig build bench -- --generate=100000 --iterations=5
bench: generated 624 files, 100159 lines, 1835619 bytes (plain) under .zig-cache/bench-gen
{"phase":"read","files":624,"bytes":1835619,"tokens":0,"nodes":0,"insts":0,"ms":2.1,"mb_per_s":824.7,"loc_per_s":47185451}
{"phase":"lex","files":624,"bytes":1835619,"tokens":302615,"nodes":0,"insts":0,"ms":9.5,"mb_per_s":183.7,"loc_per_s":10509786}
{"phase":"parse","files":624,"bytes":1835619,"tokens":302615,"nodes":221576,"insts":0,"ms":7.2,"mb_per_s":243.4,"loc_per_s":13928665}
{"phase":"lower","files":624,"bytes":1835619,"tokens":302615,"nodes":221576,"insts":202303,"ms":9.8,"mb_per_s":179.2,"loc_per_s":10254820}
{"phase":"resolve","modules":633,"edges":3932,"interfaces":633,"ms":5.40,"cold_check_ms":41.4}
{"phase":"check","modules":633,"lines":100159,"unifications":228149,"generalisations":104086,"instantiations":52346,"obligations":3486,"constraints_created":281,"constraints_merged":4,"constraints_deferred":476,"constraints_discharged":2713,"constraints_promoted":1,"diagnostics":0,"ms":87.63,"loc_per_s":1142937,"cold_check_ms":129.1}
{"phase":"emit","modules":633,"js_bytes":3869809,"nodes":347646,"lines":103650,"ms":50.31,"mb_per_s":73.4,"loc_per_s":2060078}
{"phase":"total","files":624,"bytes":1835619,"tokens":302615,"nodes":221576,"insts":202303,"ms":172.0,"mb_per_s":10.2,"loc_per_s":582462}
```

**Load before:** ` 04:58:47 up 4 days, 11:39,  3 users,  load average: 0.80, 0.85, 0.58` (re-taken after the S6b review fixes)

```
$ direnv exec . zig build bench -- --generate=100000 --dispatch --iterations=5
bench: generated 624 files, 100327 lines, 1885570 bytes (dispatch) under .zig-cache/bench-gen-dispatch
{"phase":"read","files":624,"bytes":1885570,"tokens":0,"nodes":0,"insts":0,"ms":2.2,"mb_per_s":835.4,"loc_per_s":46609805}
{"phase":"lex","files":624,"bytes":1885570,"tokens":317281,"nodes":0,"insts":0,"ms":10.2,"mb_per_s":176.1,"loc_per_s":9825863}
{"phase":"parse","files":624,"bytes":1885570,"tokens":317281,"nodes":231896,"insts":0,"ms":7.2,"mb_per_s":248.8,"loc_per_s":13878508}
{"phase":"lower","files":624,"bytes":1885570,"tokens":317281,"nodes":231896,"insts":209801,"ms":9.9,"mb_per_s":182.4,"loc_per_s":10173992}
{"phase":"resolve","modules":633,"edges":4018,"interfaces":633,"ms":5.34,"cold_check_ms":43.4}
{"phase":"check","modules":633,"lines":100327,"unifications":238018,"generalisations":115730,"instantiations":56199,"obligations":4213,"constraints_created":347,"constraints_merged":80,"constraints_deferred":1203,"constraints_discharged":5134,"constraints_promoted":77,"diagnostics":0,"ms":93.11,"loc_per_s":1077565,"cold_check_ms":136.5}
{"phase":"emit","modules":633,"js_bytes":4086222,"nodes":372018,"lines":103818,"ms":56.64,"mb_per_s":68.8,"loc_per_s":1832944}
{"phase":"total","files":624,"bytes":1885570,"tokens":317281,"nodes":231896,"insts":209801,"ms":184.5,"mb_per_s":9.7,"loc_per_s":543673}
```

Reading, in the order the numbers matter.

**`diagnostics` on the `--dispatch` tree is 0.** S1 recorded **1 682** for the
same generator (`:66`) — every dot-call and every `where` clause failing to
resolve. This line is the spike's acceptance test and it is the single most
important number in this entry: 100 327 lines of generated code written in the
dot-call style compile clean.

**`check` costs 8 % on the plain tree and 12 % on the dispatch tree.** 87.63 ms
against M1a's 71.77 ms plain, 93.11 ms against 83.39 ms dispatch — but the
second pair is not a like-for-like: S1's 83.39 ms was the cost of *failing* on
1 682 diagnostics, and this one is the cost of checking the same program
successfully. The honest reading is the first: **a tree with no dot-call
anywhere pays 8 % in `check`** for the machinery being present, and the
counters say where it goes — 281 constraints created, 476 deferred, 2 713
discharged on a corpus that never writes a `where` clause, which is `==` and
`<` on the generated code lowering to method calls (§3.1).

**`emit` costs 48 %**: 50.31 ms against 33.87 ms, and `js_bytes` 3 869 809
against 3 075 595 — **+26 % of output**. That is eager derivation (§8.5) with
no DCE, and it is the same number M4 measures from the other side.

**The front end is flat**, as it was for S1: `lex`/`parse`/`lower` at
9.5 / 7.2 / 9.8 ms plain against S1's 9.8 / 6.9 / 9.7.

---

### M3 — interface churn (C1 side)

`plans/static-dispatch-spike.md` §7 M3, same instrument and same four edit
classes as the C0 run at `:220`. Read against it directly; the `decls` column
differs because C1 has fewer declarations (`Dict.comparatorOf` is deleted, and
`core/Dict/{String,Int}.beni` with it).

**Load before:** ` 03:41:31 up 4 days, 10:22,  3 users,  load average: 0.79, 1.02, 0.98`

```
$ direnv exec . sh bench/churn.sh --corpus=bench/corpus --beni=/tmp/rf/bin/beni
corpus: bench/corpus
modules excluded (the pristine root does not resolve them): JsonCodecs.beni NotesApp.beni
tree restored: yes

edit    variant       changed/accepted  applied  skipped  rejected  decls
------  ------------  ----------------  -------  -------  --------  -----
E1      annotated               0/20       20       83         0    103
E1      unannotated             0/19       25       78         6    103
E2      annotated                0/1        2      101         1    103
E2      unannotated              0/1        8       95         7    103
E3      annotated               0/70       84       19        14    103
E3      unannotated            29/68       85       18        17    103
E3poly  annotated                0/0        5       98         5    103
E3poly  unannotated              4/4       11       92         7    103

real	0m10.134s
user	0m7.612s
sys	0m5.262s
```

**Load before:** ` 03:41:46 up 4 days, 10:22,  3 users,  load average: 0.82, 1.02, 0.98`

```
$ direnv exec . sh bench/churn.sh --corpus=core --core --beni=/tmp/rf/bin/beni
corpus: core
tree restored: yes

edit    variant       changed/accepted  applied  skipped  rejected  decls
------  ------------  ----------------  -------  -------  --------  -----
E1      annotated               0/15       15      123         0    138
E1      unannotated             0/15       15      123         0    138
E2      annotated                0/7        8      130         1    138
E2      unannotated              0/7        8      130         1    138
E3      annotated               0/74      105       33        31    138
E3      unannotated            50/90      105       33        15    138
E3poly  annotated                0/0       13      125        13    138
E3poly  unannotated            12/12       13      125         1    138

real	0m12.905s
user	0m8.388s
sys	0m6.485s
```

Reading — and this is the row report 18 §2.3 is about.

**Every `annotated` row is still 0.** E1, E2, E3 and E3poly alike, on both
corpora. An annotation is the whole interface (§6.4's promotion table: an
annotated declaration never promotes), so a body edit cannot move it, and
static dispatch has not changed that. **This is the answer to the objection**:
the interface churn report 18 §2.3 predicts is confined to unannotated `pub`
declarations, exactly as it was on C0.

**The `unannotated` rows got worse, and by how much is the finding.** E3 on
`core` moves the interface **50/90** against C0's **8/94** — 5.6×. On
`bench/corpus` it is **29/68** against **5/52**. The mechanism is not a
surprise: on C0 a new `==` on a parameter adds an `equatable` flag the
interface may or may not already carry, and on C1 it adds a **`where` clause**
that the interface always prints. E3poly — the bare-type-variable row — was
already 100 % on C0 (4/4, 14/14) and stays 100 % (4/4, 12/12), so the
polymorphic case was never the difference.

**E3's `accepted` and `rejected` columns move in opposite directions on the
two corpora, and the reason is worth stating rather than averaging.** On
`bench/corpus` more E3 edits now type-check — `annotated` accepted 70 against
C0's 52, rejected 14 against 32 — because `p == p` on a bare type variable is
legal under an inferred or written `where` clause and was not legal before.
That is the ergonomic half of the same row. On `core` it goes the other way,
`annotated` accepted 74 against 88 and rejected 31 against 23, and the
`decls` denominator itself fell from 144 to 138: `core/Dict/String.beni` and
`core/Dict/Int.beni` are deleted with six `pub` values between them and
`Dict.comparatorOf` with them, so the two runs are not over the same
declaration set. **Only the `changed/accepted` ratios are comparable between
the two runs, not the raw counts**, which is why the reading above is stated
as 50/90 against 8/94 rather than as a difference of fifty.

---

### M4 — output size (C1 side)

`plans/static-dispatch-spike.md` §7 M4, same instrument as the C0 run at
`:293`. `derived_bytes` and `derived_functions` are **0 by construction on C0**
and are the point of this run.

**Load before:** ` 04:58:33 up 4 days, 11:39,  3 users,  load average: 0.95, 0.87, 0.58`

```
$ direnv exec . node bench/size.mjs --beni=/tmp/rf/bin/beni
{"floor":true,"entry":"Empty","files":19,"raw_bytes":68791,"gzip_bytes":16399,"brotli_bytes":13838,"derived_bytes":3159,"derived_functions":22}
{"program":"bench/corpus","entry":"BenchMain (synthesised)","modules_measured":7,"modules_excluded":["Data/Parser.beni","ExprParser.beni","JsonCodecs.beni","NotesApp.beni"],"files":26,"raw_bytes":121965,"gzip_bytes":26465,"brotli_bytes":22507,"derived_bytes":11659,"derived_functions":59,"net_raw_bytes":53174,"net_gzip_bytes":10066,"net_brotli_bytes":8669}
{"program":"tests/corpus/run/Adt.beni","entry":"Adt","files":19,"raw_bytes":71039,"gzip_bytes":16827,"brotli_bytes":14245,"derived_bytes":4199,"derived_functions":28,"net_raw_bytes":2248,"net_gzip_bytes":428,"net_brotli_bytes":407}
{"program":"tests/corpus/run/Arithmetic.beni","entry":"Arithmetic","files":19,"raw_bytes":69795,"gzip_bytes":16579,"brotli_bytes":14000,"derived_bytes":3159,"derived_functions":22,"net_raw_bytes":1004,"net_gzip_bytes":180,"net_brotli_bytes":162}
{"program":"tests/corpus/run/BindPipeRhs.beni","entry":"BindPipeRhs","files":19,"raw_bytes":69649,"gzip_bytes":16573,"brotli_bytes":13968,"derived_bytes":3159,"derived_functions":22,"net_raw_bytes":858,"net_gzip_bytes":174,"net_brotli_bytes":130}
{"program":"tests/corpus/run/CaseLiterals.beni","entry":"CaseLiterals","files":19,"raw_bytes":69505,"gzip_bytes":16579,"brotli_bytes":13982,"derived_bytes":3159,"derived_functions":22,"net_raw_bytes":714,"net_gzip_bytes":180,"net_brotli_bytes":144}
{"program":"tests/corpus/run/CharOps.beni","entry":"CharOps","files":19,"raw_bytes":69681,"gzip_bytes":16603,"brotli_bytes":14012,"derived_bytes":3159,"derived_functions":22,"net_raw_bytes":890,"net_gzip_bytes":204,"net_brotli_bytes":174}
{"program":"tests/corpus/run/Closures.beni","entry":"Closures","files":19,"raw_bytes":69947,"gzip_bytes":16683,"brotli_bytes":14069,"derived_bytes":3159,"derived_functions":22,"net_raw_bytes":1156,"net_gzip_bytes":284,"net_brotli_bytes":231}
{"program":"tests/corpus/run/Comparison.beni","entry":"Comparison","files":19,"raw_bytes":69864,"gzip_bytes":16588,"brotli_bytes":13973,"derived_bytes":3208,"derived_functions":23,"net_raw_bytes":1073,"net_gzip_bytes":189,"net_brotli_bytes":135}
{"program":"tests/corpus/run/ConsPatterns.beni","entry":"ConsPatterns","files":19,"raw_bytes":70375,"gzip_bytes":16690,"brotli_bytes":14083,"derived_bytes":3159,"derived_functions":22,"net_raw_bytes":1584,"net_gzip_bytes":291,"net_brotli_bytes":245}
{"program":"tests/corpus/run/ConstantMethodCall.beni","entry":"ConstantMethodCall","files":19,"raw_bytes":69750,"gzip_bytes":16606,"brotli_bytes":14021,"derived_bytes":3327,"derived_functions":24,"net_raw_bytes":959,"net_gzip_bytes":207,"net_brotli_bytes":183}
{"program":"tests/corpus/run/ConstrainedMutualRecursion.beni","entry":"ConstrainedMutualRecursion","files":19,"raw_bytes":70255,"gzip_bytes":16673,"brotli_bytes":14090,"derived_bytes":3258,"derived_functions":23,"net_raw_bytes":1464,"net_gzip_bytes":274,"net_brotli_bytes":252}
{"program":"tests/corpus/run/ConstrainedPartEvidence.beni","entry":"ConstrainedPartEvidence","files":19,"raw_bytes":72258,"gzip_bytes":16919,"brotli_bytes":14262,"derived_bytes":3884,"derived_functions":28,"net_raw_bytes":3467,"net_gzip_bytes":520,"net_brotli_bytes":424}
{"program":"tests/corpus/run/DebugLog.beni","entry":"DebugLog","files":19,"raw_bytes":69414,"gzip_bytes":16545,"brotli_bytes":13918,"derived_bytes":3159,"derived_functions":22,"net_raw_bytes":623,"net_gzip_bytes":146,"net_brotli_bytes":80}
{"program":"tests/corpus/run/DerivedEquality.beni","entry":"DerivedEquality","files":19,"raw_bytes":74108,"gzip_bytes":16993,"brotli_bytes":14385,"derived_bytes":5396,"derived_functions":35,"net_raw_bytes":5317,"net_gzip_bytes":594,"net_brotli_bytes":547}
{"program":"tests/corpus/run/DerivedEqualityEdges.beni","entry":"DerivedEqualityEdges","files":19,"raw_bytes":72006,"gzip_bytes":16805,"brotli_bytes":14183,"derived_bytes":3652,"derived_functions":28,"net_raw_bytes":3215,"net_gzip_bytes":406,"net_brotli_bytes":345}
{"program":"tests/corpus/run/DerivedOrdering.beni","entry":"DerivedOrdering","files":19,"raw_bytes":75205,"gzip_bytes":17218,"brotli_bytes":14578,"derived_bytes":6281,"derived_functions":39,"net_raw_bytes":6414,"net_gzip_bytes":819,"net_brotli_bytes":740}
{"program":"tests/corpus/run/DictRecordKey.beni","entry":"DictRecordKey","files":19,"raw_bytes":70804,"gzip_bytes":16819,"brotli_bytes":14192,"derived_bytes":3440,"derived_functions":24,"net_raw_bytes":2013,"net_gzip_bytes":420,"net_brotli_bytes":354}
{"program":"tests/corpus/run/DictStructuralEquality.beni","entry":"DictStructuralEquality","files":19,"raw_bytes":70437,"gzip_bytes":16689,"brotli_bytes":14076,"derived_bytes":3318,"derived_functions":24,"net_raw_bytes":1646,"net_gzip_bytes":290,"net_brotli_bytes":238}
{"program":"tests/corpus/run/Dictionaries.beni","entry":"Dictionaries","files":19,"raw_bytes":69786,"gzip_bytes":16627,"brotli_bytes":14016,"derived_bytes":3159,"derived_functions":22,"net_raw_bytes":995,"net_gzip_bytes":228,"net_brotli_bytes":178}
{"program":"tests/corpus/run/EvidenceCapture.beni","entry":"EvidenceCapture","files":19,"raw_bytes":69971,"gzip_bytes":16625,"brotli_bytes":14008,"derived_bytes":3475,"derived_functions":25,"net_raw_bytes":1180,"net_gzip_bytes":226,"net_brotli_bytes":170}
{"program":"tests/corpus/run/ExitCode.beni","entry":"ExitCode","files":19,"raw_bytes":68984,"gzip_bytes":16459,"brotli_bytes":13868,"derived_bytes":3159,"derived_functions":22,"net_raw_bytes":193,"net_gzip_bytes":60,"net_brotli_bytes":30}
{"program":"tests/corpus/run/HigherOrder.beni","entry":"HigherOrder","files":19,"raw_bytes":70046,"gzip_bytes":16715,"brotli_bytes":14098,"derived_bytes":3159,"derived_functions":22,"net_raw_bytes":1255,"net_gzip_bytes":316,"net_brotli_bytes":260}
{"program":"tests/corpus/run/ImportedModule.beni","entry":"ImportedModule","files":19,"raw_bytes":69424,"gzip_bytes":16541,"brotli_bytes":13956,"derived_bytes":3159,"derived_functions":22,"net_raw_bytes":633,"net_gzip_bytes":142,"net_brotli_bytes":118}
{"program":"tests/corpus/run/Interpolation.beni","entry":"Interpolation","files":19,"raw_bytes":69456,"gzip_bytes":16622,"brotli_bytes":14012,"derived_bytes":3159,"derived_functions":22,"net_raw_bytes":665,"net_gzip_bytes":223,"net_brotli_bytes":174}
{"program":"tests/corpus/run/LetNesting.beni","entry":"LetNesting","files":19,"raw_bytes":69496,"gzip_bytes":16588,"brotli_bytes":14013,"derived_bytes":3159,"derived_functions":22,"net_raw_bytes":705,"net_gzip_bytes":189,"net_brotli_bytes":175}
{"program":"tests/corpus/run/LibraryArgumentOrder.beni","entry":"LibraryArgumentOrder","files":19,"raw_bytes":71377,"gzip_bytes":16941,"brotli_bytes":14341,"derived_bytes":3252,"derived_functions":23,"net_raw_bytes":2586,"net_gzip_bytes":542,"net_brotli_bytes":503}
{"program":"tests/corpus/run/ListBuild.beni","entry":"ListBuild","files":19,"raw_bytes":69962,"gzip_bytes":16603,"brotli_bytes":13985,"derived_bytes":3159,"derived_functions":22,"net_raw_bytes":1171,"net_gzip_bytes":204,"net_brotli_bytes":147}
{"program":"tests/corpus/run/ListElementEq.beni","entry":"ListElementEq","files":19,"raw_bytes":72715,"gzip_bytes":16843,"brotli_bytes":14235,"derived_bytes":3600,"derived_functions":25,"net_raw_bytes":3924,"net_gzip_bytes":444,"net_brotli_bytes":397}
{"program":"tests/corpus/run/ListFold.beni","entry":"ListFold","files":19,"raw_bytes":70250,"gzip_bytes":16694,"brotli_bytes":14080,"derived_bytes":3240,"derived_functions":23,"net_raw_bytes":1459,"net_gzip_bytes":295,"net_brotli_bytes":242}
{"program":"tests/corpus/run/ListMemberEq.beni","entry":"ListMemberEq","files":19,"raw_bytes":70425,"gzip_bytes":16685,"brotli_bytes":14086,"derived_bytes":3597,"derived_functions":25,"net_raw_bytes":1634,"net_gzip_bytes":286,"net_brotli_bytes":248}
{"program":"tests/corpus/run/ListOrdering.beni","entry":"ListOrdering","files":19,"raw_bytes":71601,"gzip_bytes":16803,"brotli_bytes":14208,"derived_bytes":3408,"derived_functions":24,"net_raw_bytes":2810,"net_gzip_bytes":404,"net_brotli_bytes":370}
{"program":"tests/corpus/run/MaybeResult.beni","entry":"MaybeResult","files":19,"raw_bytes":70181,"gzip_bytes":16687,"brotli_bytes":14073,"derived_bytes":3159,"derived_functions":22,"net_raw_bytes":1390,"net_gzip_bytes":288,"net_brotli_bytes":235}
{"program":"tests/corpus/run/MethodCalls.beni","entry":"MethodCalls","files":19,"raw_bytes":70387,"gzip_bytes":16696,"brotli_bytes":14106,"derived_bytes":3309,"derived_functions":24,"net_raw_bytes":1596,"net_gzip_bytes":297,"net_brotli_bytes":268}
{"program":"tests/corpus/run/NestedConstrainedCalls.beni","entry":"NestedConstrainedCalls","files":19,"raw_bytes":71119,"gzip_bytes":16822,"brotli_bytes":14172,"derived_bytes":3828,"derived_functions":26,"net_raw_bytes":2328,"net_gzip_bytes":423,"net_brotli_bytes":334}
{"program":"tests/corpus/run/NestedConstrainedListKeys.beni","entry":"NestedConstrainedListKeys","files":19,"raw_bytes":74993,"gzip_bytes":17379,"brotli_bytes":14686,"derived_bytes":4006,"derived_functions":27,"net_raw_bytes":6202,"net_gzip_bytes":980,"net_brotli_bytes":848}
{"program":"tests/corpus/run/NumericEdge.beni","entry":"NumericEdge","files":19,"raw_bytes":70198,"gzip_bytes":16636,"brotli_bytes":14037,"derived_bytes":3159,"derived_functions":22,"net_raw_bytes":1407,"net_gzip_bytes":237,"net_brotli_bytes":199}
{"program":"tests/corpus/run/OrderValues.beni","entry":"OrderValues","files":19,"raw_bytes":70404,"gzip_bytes":16664,"brotli_bytes":14063,"derived_bytes":3516,"derived_functions":25,"net_raw_bytes":1613,"net_gzip_bytes":265,"net_brotli_bytes":225}
{"program":"tests/corpus/run/OrderingPrimitives.beni","entry":"OrderingPrimitives","files":19,"raw_bytes":70133,"gzip_bytes":16632,"brotli_bytes":14002,"derived_bytes":3159,"derived_functions":22,"net_raw_bytes":1342,"net_gzip_bytes":233,"net_brotli_bytes":164}
{"program":"tests/corpus/run/ParametricEquality.beni","entry":"ParametricEquality","files":19,"raw_bytes":73192,"gzip_bytes":16864,"brotli_bytes":14241,"derived_bytes":3628,"derived_functions":27,"net_raw_bytes":4401,"net_gzip_bytes":465,"net_brotli_bytes":403}
{"program":"tests/corpus/run/Patterns.beni","entry":"Patterns","files":19,"raw_bytes":70419,"gzip_bytes":16758,"brotli_bytes":14161,"derived_bytes":3476,"derived_functions":26,"net_raw_bytes":1628,"net_gzip_bytes":359,"net_brotli_bytes":323}
{"program":"tests/corpus/run/PipeFirst.beni","entry":"PipeFirst","files":19,"raw_bytes":69801,"gzip_bytes":16601,"brotli_bytes":13994,"derived_bytes":3241,"derived_functions":23,"net_raw_bytes":1010,"net_gzip_bytes":202,"net_brotli_bytes":156}
{"program":"tests/corpus/run/PipeNestedGrouping.beni","entry":"PipeNestedGrouping","files":19,"raw_bytes":69639,"gzip_bytes":16541,"brotli_bytes":13961,"derived_bytes":3159,"derived_functions":22,"net_raw_bytes":848,"net_gzip_bytes":142,"net_brotli_bytes":123}
{"program":"tests/corpus/run/Placeholder.beni","entry":"Placeholder","files":19,"raw_bytes":69897,"gzip_bytes":16624,"brotli_bytes":14016,"derived_bytes":3159,"derived_functions":22,"net_raw_bytes":1106,"net_gzip_bytes":225,"net_brotli_bytes":178}
{"program":"tests/corpus/run/PlaceholderAndBind.beni","entry":"PlaceholderAndBind","files":19,"raw_bytes":70221,"gzip_bytes":16713,"brotli_bytes":14100,"derived_bytes":3159,"derived_functions":22,"net_raw_bytes":1430,"net_gzip_bytes":314,"net_brotli_bytes":262}
{"program":"tests/corpus/run/PrimitiveEvidence.beni","entry":"PrimitiveEvidence","files":19,"raw_bytes":70884,"gzip_bytes":16712,"brotli_bytes":14118,"derived_bytes":3615,"derived_functions":26,"net_raw_bytes":2093,"net_gzip_bytes":313,"net_brotli_bytes":280}
{"program":"tests/corpus/run/Records.beni","entry":"Records","files":19,"raw_bytes":69444,"gzip_bytes":16565,"brotli_bytes":13998,"derived_bytes":3159,"derived_functions":22,"net_raw_bytes":653,"net_gzip_bytes":166,"net_brotli_bytes":160}
{"program":"tests/corpus/run/Recursion.beni","entry":"Recursion","files":19,"raw_bytes":69824,"gzip_bytes":16626,"brotli_bytes":14042,"derived_bytes":3159,"derived_functions":22,"net_raw_bytes":1033,"net_gzip_bytes":227,"net_brotli_bytes":204}
{"program":"tests/corpus/run/RestOfBlockBind.beni","entry":"RestOfBlockBind","files":19,"raw_bytes":69824,"gzip_bytes":16667,"brotli_bytes":14063,"derived_bytes":3159,"derived_functions":22,"net_raw_bytes":1033,"net_gzip_bytes":268,"net_brotli_bytes":225}
{"program":"tests/corpus/run/SaturatedCalls.beni","entry":"SaturatedCalls","files":19,"raw_bytes":70623,"gzip_bytes":16786,"brotli_bytes":14179,"derived_bytes":3450,"derived_functions":24,"net_raw_bytes":1832,"net_gzip_bytes":387,"net_brotli_bytes":341}
{"program":"tests/corpus/run/ShortCircuit.beni","entry":"ShortCircuit","files":19,"raw_bytes":69212,"gzip_bytes":16509,"brotli_bytes":13923,"derived_bytes":3159,"derived_functions":22,"net_raw_bytes":421,"net_gzip_bytes":110,"net_brotli_bytes":85}
{"program":"tests/corpus/run/Sorting.beni","entry":"Sorting","files":19,"raw_bytes":69993,"gzip_bytes":16673,"brotli_bytes":14089,"derived_bytes":3239,"derived_functions":23,"net_raw_bytes":1202,"net_gzip_bytes":274,"net_brotli_bytes":251}
{"program":"tests/corpus/run/StringBuilding.beni","entry":"StringBuilding","files":19,"raw_bytes":69629,"gzip_bytes":16619,"brotli_bytes":14004,"derived_bytes":3159,"derived_functions":22,"net_raw_bytes":838,"net_gzip_bytes":220,"net_brotli_bytes":166}
{"program":"tests/corpus/run/StringOps.beni","entry":"StringOps","files":19,"raw_bytes":69927,"gzip_bytes":16693,"brotli_bytes":14079,"derived_bytes":3159,"derived_functions":22,"net_raw_bytes":1136,"net_gzip_bytes":294,"net_brotli_bytes":241}
{"program":"tests/corpus/run/StringOrdering.beni","entry":"StringOrdering","files":19,"raw_bytes":70085,"gzip_bytes":16676,"brotli_bytes":14061,"derived_bytes":3159,"derived_functions":22,"net_raw_bytes":1294,"net_gzip_bytes":277,"net_brotli_bytes":223}
{"program":"tests/corpus/run/Tuples.beni","entry":"Tuples","files":19,"raw_bytes":69979,"gzip_bytes":16712,"brotli_bytes":14087,"derived_bytes":3159,"derived_functions":22,"net_raw_bytes":1188,"net_gzip_bytes":313,"net_brotli_bytes":249}
{"program":"tests/corpus/run/TwoSlotsNested.beni","entry":"TwoSlotsNested","files":19,"raw_bytes":75897,"gzip_bytes":17197,"brotli_bytes":14466,"derived_bytes":3389,"derived_functions":25,"net_raw_bytes":7106,"net_gzip_bytes":798,"net_brotli_bytes":628}
{"program":"tests/corpus/run/TypeDispatch.beni","entry":"TypeDispatch","files":19,"raw_bytes":69641,"gzip_bytes":16600,"brotli_bytes":14020,"derived_bytes":3311,"derived_functions":24,"net_raw_bytes":850,"net_gzip_bytes":201,"net_brotli_bytes":182}
{"program":"tests/corpus/run/UserEqInsideParametric.beni","entry":"UserEqInsideParametric","files":19,"raw_bytes":70845,"gzip_bytes":16735,"brotli_bytes":14104,"derived_bytes":3627,"derived_functions":25,"net_raw_bytes":2054,"net_gzip_bytes":336,"net_brotli_bytes":266}
{"program":"tests/corpus/run/UserEqInsideRecord.beni","entry":"UserEqInsideRecord","files":19,"raw_bytes":70800,"gzip_bytes":16745,"brotli_bytes":14146,"derived_bytes":3778,"derived_functions":27,"net_raw_bytes":2009,"net_gzip_bytes":346,"net_brotli_bytes":308}
{"program":"tests/corpus/run/UserEquality.beni","entry":"UserEquality","files":19,"raw_bytes":69710,"gzip_bytes":16609,"brotli_bytes":13997,"derived_bytes":3551,"derived_functions":24,"net_raw_bytes":919,"net_gzip_bytes":210,"net_brotli_bytes":159}
{"total":true,"programs":60,"files":1147,"raw_bytes":227782,"gzip_bytes":44800,"brotli_bytes":37996,"floor_raw_bytes":68791,"floor_gzip_bytes":16399,"floor_brotli_bytes":13838,"net_raw_bytes":158991,"net_gzip_bytes":28401,"net_brotli_bytes":24158,"gross_raw_bytes":4286451,"gross_gzip_bytes":1012341,"gross_brotli_bytes":854438,"derived_bytes":213610,"derived_functions":1472}
```

`bench/size.mjs` reports one `derived_bytes` figure. §11 and A.38 require the
per-method split to be reported as **two numbers and never a sum**, so it was
taken separately over the floor tree — the embedded `core/` that every program
ships — by the same statement walk and the same `hand_written` exclusion list:

```
$ node -e '<the size.mjs statement walk, split by the $eq / $compare / $order segment>'
{"floor":true,"eq_functions":8,"eq_bytes":1050,"compare_functions":9,"compare_bytes":1889,"order_tables":5,"order_bytes":244}
eq:      Basics$Never$$eq Dict$Dict$$eq Dict$NColor$$eq Dict$Tree$$eq Maybe$Maybe$$eq Result$Result$$eq Set$Set$$eq Set$eq$unit
compare: Basics$Never$$compare Basics$Order$$compare Dict$Dict$$compare Dict$NColor$$compare Dict$Tree$$compare Maybe$Maybe$$compare Result$Result$$compare Set$Set$$compare Set$compare$unit
order:   Basics$Order$$order Dict$NColor$$order Dict$Tree$$order Maybe$Maybe$$order Result$Result$$order
```

Reading.

**The floor grew 3 577 raw bytes, 5.5 %**: 68 791 against C0's 65 214, on two
fewer files (19 against 21 — `Dict.String` and `Dict.Int` are gone). Gzip 16 399
against 15 410 (+6.4 %), brotli 13 838 against 12 932 (+7.0 %). Of that,
**3 159 bytes are derived functions** — so eager derivation is 4.6 % of
everything an empty program ships, and the rest of the growth is `core/List.js`
gaining two loops and `core/Dict.beni` gaining seventeen `where` clauses,
against the two deleted modules.

**Derived `eq` is 1 050 bytes over 8 functions; derived `compare` is 1 889
bytes over 9, plus 244 bytes of `$$order` table over 5.** Three numbers, not
one: `compare` costs roughly **1.8× what `eq` costs per function** (210 bytes
against 131), which is §9's lexicographic-with-early-return shape against a
chain of `&&`, and the `$order` tables are the part that has no `eq`
counterpart at all.

**Six of the twenty-two floor functions are new with this slice and nothing
calls them**: `Dict$Dict$$eq`, `Dict$Dict$$compare`, `Set$Set$$eq`,
`Set$Set$$compare`, `Set$eq$unit`, `Set$compare$unit`. `Dict k v` held a
comparator before §5.3, so §6.3.1 step 4's function-payload exclusion gave it
neither method and `Set t = Set (Dict t ())` inherited the exclusion; taking
the comparator out of the data structure made both derivable. That is eager
derivation plus no DCE, priced: **removing one function-typed field from one
core type added six functions to every program in the language.**

**Per program the net cost is small and uniform.** `run/Sorting` is 1 202 net
raw against C0's 982, `run/LibraryArgumentOrder` 2 586 against 1 734 (it gained
three lines of source), and the median `run/` fixture moves by a few hundred
bytes of which nearly all is the shared floor. `bench/corpus` is 121 965 raw
against 109 053 (+11.8 %) with **11 659 derived bytes over 59 functions** — the
first real measurement of "grows per type × method" (report 18 §1.5), and it
says the answer is **~198 bytes per derived function** before any minification
or elimination.

**The totals cover 60 programs, and the three that are new are the only lines
that moved.** This block was re-taken after the S6b review fixes, and every
program the earlier run measured comes out byte-identical — same raw, gzip,
brotli, `derived_bytes` and `derived_functions` — so the checker fixes changed
no output except where a program nests a constrained call, which is what they
are about. The three additions are `run/Dictionaries` (995 net raw), which the
earlier run could not build at all and which is why it covered 57,
`run/NestedConstrainedCalls` (2 328) and `run/NestedConstrainedListKeys`
(6 202). The last is the third largest net figure in the `run/` corpus, behind
`TwoSlotsNested` (7 106) and `DerivedOrdering` (6 414), and for a related
reason: nested evidence means a derived or foreign method per level, and this
program has four such nestings over three element types.

---

### M5 — runtime of the emitted JavaScript, R1–R3 (C0 and C1 interleaved)

`plans/static-dispatch-spike.md` §7 M5. `bench/runtime.mjs --variant=c0|c1`
builds each `bench/runtime/<variant>/*.beni` program and runs it under Node,
20 runs, best / median / ns per op net of a measured process floor. The C0 side
is the S1 binary at `c870e9a` against `bench/runtime/c0/`, which is untouched;
the C1 side is this tree against the new `bench/runtime/c1/`. **Two rounds,
interleaved C1→C0→C1→C0**, all four inside three minutes.

`checksum` is printed by the program itself, and **all six lines of each
program agree across both variants and both rounds** — `60000 288894`,
`60000 18600000`, `4000 499313`. That is the assertion that C1 is the same
three programs and not three new ones.

**Load before:** ` 03:43:08 up 4 days, 10:24,  3 users,  load average: 0.36, 0.84, 0.92`

```
$ direnv exec . node bench/runtime.mjs --variant=c1 --runs=20 --beni=/tmp/rf/bin/beni --program=R1DictString --program=R2DictRecord --program=R3Sorting
{"program":"R1DictString","variant":"c1","runs":20,"ops":120000,"floor_ms":35.79,"best_ms":315.99,"median_ms":334.81,"ns_per_op":2335,"checksum":"60000 288894"}
{"program":"R2DictRecord","variant":"c1","runs":20,"ops":120000,"floor_ms":35.8,"best_ms":143.68,"median_ms":146.72,"ns_per_op":899,"checksum":"60000 18600000"}
{"program":"R3Sorting","variant":"c1","runs":20,"ops":120000,"floor_ms":36.08,"best_ms":184.54,"median_ms":187.48,"ns_per_op":1237.2,"checksum":"4000 499313"}

$ (in ../beni-s1) node bench/runtime.mjs --variant=c0 --runs=20 --beni=…/beni-s1/zig-out/bin/beni --program=R1DictString --program=R2DictRecord --program=R3Sorting
{"program":"R1DictString","variant":"c0","runs":20,"ops":120000,"floor_ms":35.2,"best_ms":317.85,"median_ms":336.13,"ns_per_op":2355.4,"checksum":"60000 288894"}
{"program":"R2DictRecord","variant":"c0","runs":20,"ops":120000,"floor_ms":35.29,"best_ms":141.29,"median_ms":147.93,"ns_per_op":883.3,"checksum":"60000 18600000"}
{"program":"R3Sorting","variant":"c0","runs":20,"ops":120000,"floor_ms":35.84,"best_ms":181.6,"median_ms":185.85,"ns_per_op":1214.7,"checksum":"4000 499313"}

$ (round two, same two commands)
{"program":"R1DictString","variant":"c1","runs":20,"ops":120000,"floor_ms":34.94,"best_ms":318.99,"median_ms":332.92,"ns_per_op":2367.1,"checksum":"60000 288894"}
{"program":"R2DictRecord","variant":"c1","runs":20,"ops":120000,"floor_ms":35.57,"best_ms":143.48,"median_ms":146.22,"ns_per_op":899.3,"checksum":"60000 18600000"}
{"program":"R3Sorting","variant":"c1","runs":20,"ops":120000,"floor_ms":35.81,"best_ms":185.55,"median_ms":190.34,"ns_per_op":1247.8,"checksum":"4000 499313"}
{"program":"R1DictString","variant":"c0","runs":20,"ops":120000,"floor_ms":36.12,"best_ms":320.36,"median_ms":341.34,"ns_per_op":2368.7,"checksum":"60000 288894"}
{"program":"R2DictRecord","variant":"c0","runs":20,"ops":120000,"floor_ms":35.22,"best_ms":144.72,"median_ms":149.85,"ns_per_op":912.5,"checksum":"60000 18600000"}
{"program":"R3Sorting","variant":"c0","runs":20,"ops":120000,"floor_ms":35.41,"best_ms":183.53,"median_ms":186.66,"ns_per_op":1234.3,"checksum":"4000 499313"}
```

| program | C0 ns/op (r1, r2) | C1 ns/op (r1, r2) | Δ |
|---|---|---|---|
| R1 `Dict` over `String` keys | 2 355.4, 2 368.7 | 2 335.0, 2 367.1 | −0.9 %, −0.1 % |
| R2 `Dict` over a record key | 883.3, 912.5 | 899.0, 899.3 | +1.8 %, −1.4 % |
| R3 `List.sort` ×3 | 1 214.7, 1 234.3 | 1 237.2, 1 247.8 | +1.9 %, +1.1 % |

**The answer is that it costs nothing measurable.** Every difference is inside
the round-to-round spread of the same variant (C0's own R2 moves 3.3 % between
rounds, C1's R1 1.4 %), and the sign flips between rounds on two of the three.
An evidence parameter passed as a hidden first argument and called directly is
**the same work V8 was already doing** when the comparator was an explicit
parameter — which is what §8.1 predicted and what R5's evidence-forwarding row
already suggested on C0.

**R2 carries one deliberate difference, and it is not dispatch's.**
`c1/R2DictRecord.beni` reads the point's fields through a `weight : Point -> Int`
helper where `c0/R2DictRecord.beni` writes `(p.x + p.y)` inline, because the
inline form does not compile: the field access makes the lambda's parameter an
open record while the `where k.compare` obligation is still waiting, and §6.3
refuses an open record. So R2's C1 side pays one extra direct call per insert
— 60 000 of them — and still lands inside the noise. §11 carries the row.

**R2 also swaps a hand-written comparator for a derived one**, which was the
whole point of the program: `comparePoint` is deleted and the record shape's
own `compare` (§9.2) is what `Dict.insert` receives. The two are the same
lexicographic comparison in the same field order and, on this evidence, the
same speed.

---

### M8 — ergonomics (C1 side), recounted by grep on the finished tree

`plans/static-dispatch-spike.md` §7 M8. The C0 column is the hand count at
`:448`; this column is a **re-count on the tree as it now stands**, not a
restatement of the plan's prediction.

| Measure | C0 (`:448`) | C1, counted | Verdict |
|---|---:|---:|---|
| call sites passing an ordering function to a `Dict`/`Set`/`List` builder | 17 | **0** | met |
| declarations taking a comparator parameter | 15 | **4** | met |
| `Dict.String` / `Dict.Int` import lines | 7 | **0** | met |
| `Dict.String` / `Dict.Int` use sites | 17 | **0** | met |
| core modules deleted | — | **2** | met |

The four surviving comparator parameters are the ones rule 2 of the rewrite
plan protects — they order by something that is **not** the type's own order:

```
$ grep -rnE '\(\w+, ?\w+ -> Order\)' --include='*.beni' core bench/corpus tests/corpus
core/List.beni:433:pub sortWith : List a, (a, a -> Order) -> List a
core/List.beni:477:mergeWith : List a, List a, (a, a -> Order) -> List a
core/List.beni:482:mergeWithHelp : List a, List a, List a, (a, a -> Order) -> List a
bench/corpus/DictExtra.beni:144:pub toSortedList : Dict String v, (v, v -> Order) -> List ( String, v )

$ grep -rn 'Dict\.String\|Dict\.Int' --include='*.beni' core bench/corpus tests/corpus | wc -l
0
```

The headline for report 19 therefore stands as the rewrite plan predicted it:
**17 ordering arguments → 0, and 15 comparator parameters → 4.** The
"modules declaring ≥ 2 nominal types" row is unchanged at 21 and is not
re-counted here: no module gained or lost a type.

---

## 2026-09-18 05:32 CEST — S8a, correction to the S6b header

**This is a correction, not a measurement.** The S6b entry's header at `:739-745`
says:

> The **C0** side of M5 is `../beni-s1` at `c870e9a`, the same ReleaseFast
> binary the S1 baselines were taken with, run back to back with the C1 side in
> the same minutes

**The binary it actually ran was a Debug rebuild of the same commit, not the
ReleaseFast one.** `../beni-s1/zig-out/bin/beni` was **42 950 861 bytes, dated
2026-09-17 16:06** when S8a opened at 05:30 on 2026-09-18 — i.e. some later
`zig build` in that worktree had overwritten the 13 317 664-byte ReleaseFast
install of 13:54 with a Debug one, hours before the S6b M5 rows were taken at
03:43. The commit under it is unchanged (`c870e9a`, tree clean), so the
*program* the C0 side compiled is the right one; only the optimisation level of
the compiler that compiled it is wrong.

**Why it is harmless for the M5 rows and for nothing else.** M5 times the
EMITTED JavaScript under Node. The compiler runs once, outside the timed loop,
and `bench/runtime.mjs` never times `beni build` — so a Debug compiler produces
the same `out/main.mjs` a ReleaseFast one does and the `ns_per_op` figures at
`:1120-1139` stand as recorded. The S5 entry at `:667-733` already says the same
thing of itself in the open ("Both are Debug compilers building the same
`bench/runtime/c0/*.beni` sources"). What the claim would have invalidated is any
row that times the COMPILER, and no such row in the S6b entry used `../beni-s1`:
M3, M4 and M8 cite the S1 rows at `:220`, `:293` and `:448` rather than re-run
them, and M1b is `/tmp/rf` against those S1 numbers.

**State now.** S8a's step A-0 rebuilt `../beni-s1` at `-Doptimize=ReleaseFast`;
the install came straight back out of the Zig cache and reproduced the S1 figure
**exactly — 13 317 664 bytes** (mtime 2026-09-17 13:54, the original S1 install
relinked). So the A binary of every row below is byte-identical to the one the
S1 baselines were taken with, and that identity is asserted rather than assumed.

```
$ cd ../beni-s1 && uptime && time direnv exec …/beni zig build -Doptimize=ReleaseFast
 05:32:10 up 4 days, 12:13,  3 users,  load average: 0.34, 0.97, 0.95
real	0m0.223s
$ stat -c '%s' zig-out/bin/beni
13317664
```

---

## 2026-09-18 05:33 CEST — S8a, M1a: what the feature costs code that never uses it

**Machine:** Intel N100, 4 cores / 4 threads, 6 MiB L3, single memory channel,
16 GB RAM, Linux 7.2.2, Zig 0.16.0, Node v24.19.0, ReleaseFast.

**A** = `../beni-s1/zig-out/bin/beni` at `c870e9a`, **13 317 664 bytes**, the S1
binary (see the correction above). **B** = this branch at `99e0a05` built
`-Doptimize=ReleaseFast --prefix /tmp/rf`, **16 854 856 bytes**. Instrument:
`zig build bench -- --generate=100000 --iterations=5`, best of 5 after one
warm-up, `jobs = 1`. **Interleaved ABBA inside 20 seconds**, which is what the
S6b "+8 %" reading did not have: it compared a B run taken at 03:39 on
2026-09-18 with an A run taken at 13:38 on 2026-09-17.

**The generator header is byte-identical on both sides**, which is the assertion
that the two runs read the same 624 files:

```
A: bench: generated 624 files, 100159 lines, 1835619 bytes (plain) under .zig-cache/bench-gen
B: bench: generated 624 files, 100159 lines, 1835619 bytes (plain) under .zig-cache/bench-gen
```

**Caveat, and it is the one that limits this row.** The user code is the same
but the *cores are not*: A checks 635 modules, B checks 633 — C1 deletes
`core/Dict/String.beni` and `core/Dict/Int.beni` — and B's `core/Dict.beni`
carries seventeen `where` clauses A's does not. So this pair is "the branch as
it stands against `master` as it stands", not "the same program through two
checkers".

**Load before A-1:** ` 05:33:11 up 4 days, 12:14,  3 users,  load average: 0.24, 0.84, 0.91`
**Load before B-1:** ` 05:33:17 up 4 days, 12:14,  3 users,  load average: 0.30, 0.84, 0.91`
**Load before B-2:** ` 05:33:23 up 4 days, 12:14,  3 users,  load average: 0.33, 0.83, 0.90`
**Load before A-2:** ` 05:33:30 up 4 days, 12:14,  3 users,  load average: 0.30, 0.82, 0.90`

```
$ (A) direnv exec …/beni zig build bench -- --generate=100000 --iterations=5
A1 {"phase":"lex","files":624,"bytes":1835619,"tokens":302615,"nodes":0,"insts":0,"ms":9.9,"mb_per_s":176.8,"loc_per_s":10115460}
A1 {"phase":"parse","files":624,"bytes":1835619,"tokens":302615,"nodes":221576,"insts":0,"ms":6.7,"mb_per_s":262.1,"loc_per_s":14998096}
A1 {"phase":"lower","files":624,"bytes":1835619,"tokens":302615,"nodes":221576,"insts":205097,"ms":9.5,"mb_per_s":184.2,"loc_per_s":10537997}
A1 {"phase":"resolve","modules":635,"edges":3787,"interfaces":635,"ms":5.62,"cold_check_ms":41.1}
A1 {"phase":"check","modules":635,"lines":100159,"unifications":231352,"generalisations":101320,"instantiations":55228,"obligations":3151,"constraints_created":0,"constraints_merged":0,"constraints_deferred":0,"constraints_discharged":0,"constraints_promoted":0,"diagnostics":0,"ms":71.88,"loc_per_s":1393337,"cold_check_ms":113.0}
A1 {"phase":"emit","modules":635,"js_bytes":3075595,"nodes":254951,"lines":103669,"ms":33.36,"mb_per_s":87.9,"loc_per_s":3107267}
A1 {"phase":"total","files":624,"bytes":1835619,"tokens":302615,"nodes":221576,"insts":205097,"ms":139.1,"mb_per_s":12.6,"loc_per_s":720203}

$ (B) direnv exec . zig build bench -- --generate=100000 --iterations=5
B1 {"phase":"lex","files":624,"bytes":1835619,"tokens":302615,"nodes":0,"insts":0,"ms":9.4,"mb_per_s":185.4,"loc_per_s":10606805}
B1 {"phase":"parse","files":624,"bytes":1835619,"tokens":302615,"nodes":221576,"insts":0,"ms":6.8,"mb_per_s":258.9,"loc_per_s":14814458}
B1 {"phase":"lower","files":624,"bytes":1835619,"tokens":302615,"nodes":221576,"insts":202303,"ms":9.4,"mb_per_s":186.0,"loc_per_s":10643121}
B1 {"phase":"resolve","modules":633,"edges":3932,"interfaces":633,"ms":5.52,"cold_check_ms":41.4}
B1 {"phase":"check","modules":633,"lines":100159,"unifications":228143,"generalisations":104086,"instantiations":52346,"obligations":3486,"constraints_created":281,"constraints_merged":4,"constraints_deferred":476,"constraints_discharged":2710,"constraints_promoted":1,"diagnostics":0,"ms":86.57,"loc_per_s":1156915,"cold_check_ms":127.9}
B1 {"phase":"emit","modules":633,"js_bytes":3870047,"nodes":347677,"lines":103650,"ms":49.32,"mb_per_s":74.8,"loc_per_s":2101595}
B1 {"phase":"total","files":624,"bytes":1835619,"tokens":302615,"nodes":221576,"insts":202303,"ms":169.2,"mb_per_s":10.3,"loc_per_s":592119}

B2 {"phase":"lex",...,"ms":9.5,"mb_per_s":184.9,"loc_per_s":10579184}
B2 {"phase":"parse",...,"ms":6.8,"mb_per_s":257.4,"loc_per_s":14726951}
B2 {"phase":"lower",...,"insts":202303,"ms":9.4,"mb_per_s":186.0,"loc_per_s":10640257}
B2 {"phase":"resolve","modules":633,"edges":3932,"interfaces":633,"ms":5.46,"cold_check_ms":41.4}
B2 {"phase":"check","modules":633,"lines":100159,"unifications":228143,"generalisations":104086,"instantiations":52346,"obligations":3486,"constraints_created":281,"constraints_merged":4,"constraints_deferred":476,"constraints_discharged":2710,"constraints_promoted":1,"diagnostics":0,"ms":86.79,"loc_per_s":1154009,"cold_check_ms":128.2}
B2 {"phase":"emit","modules":633,"js_bytes":3870047,"nodes":347677,"lines":103650,"ms":49.30,"mb_per_s":74.9,"loc_per_s":2102635}
B2 {"phase":"total",...,"ms":169.3,"mb_per_s":10.3,"loc_per_s":591546}

A2 {"phase":"lex",...,"ms":9.5,"mb_per_s":185.2,"loc_per_s":10598511}
A2 {"phase":"parse",...,"ms":6.6,"mb_per_s":264.1,"loc_per_s":15110710}
A2 {"phase":"lower",...,"insts":205097,"ms":9.5,"mb_per_s":184.1,"loc_per_s":10533833}
A2 {"phase":"resolve","modules":635,"edges":3787,"interfaces":635,"ms":5.44,"cold_check_ms":41.1}
A2 {"phase":"check","modules":635,"lines":100159,"unifications":231352,"generalisations":101320,"instantiations":55228,"obligations":3151,"constraints_created":0,"constraints_merged":0,"constraints_deferred":0,"constraints_discharged":0,"constraints_promoted":0,"diagnostics":0,"ms":72.23,"loc_per_s":1386713,"cold_check_ms":113.4}
A2 {"phase":"emit","modules":635,"js_bytes":3075595,"nodes":254951,"lines":103669,"ms":33.27,"mb_per_s":88.2,"loc_per_s":3116070}
A2 {"phase":"total",...,"ms":138.7,"mb_per_s":12.6,"loc_per_s":722157}
```

| phase | A (`c870e9a`) ms | B (`99e0a05`) ms | B ÷ A |
|---|---:|---:|---:|
| lex | 9.9, 9.5 | 9.4, 9.5 | 0.98× |
| parse | 6.7, 6.6 | 6.8, 6.8 | 1.02× |
| lower | 9.5, 9.5 | 9.4, 9.4 | 0.99× |
| resolve | 5.62, 5.44 | 5.52, 5.46 | 1.00× |
| **check** | **71.88, 72.23** | **86.57, 86.79** | **1.203×** |
| **emit** | **33.36, 33.27** | **49.32, 49.30** | **1.480×** |
| **total** | **139.1, 138.7** | **169.2, 169.3** | **1.218×** |

| counter | A | B |
|---|---:|---:|
| modules | 635 | 633 |
| unifications | 231 352 | 228 143 |
| generalisations | 101 320 | 104 086 |
| instantiations | 55 228 | 52 346 |
| obligations | 3 151 | 3 486 |
| constraints created / merged / deferred / discharged / promoted | 0 / 0 / 0 / 0 / 0 | 281 / 4 / 476 / 2 710 / 1 |
| `js_bytes` | 3 075 595 | 3 870 047 (**+25.8 %**) |

Reading.

**`check` on a corpus with no dot-call and no `where` costs 20.3 %, not 8 %.**
Both runs are clean (`diagnostics: 0`), both read the same 1 835 619 bytes, and
the ABBA spread inside each binary is 0.5 % (A 71.88/72.23, B 86.57/86.79) —
smaller than a twelfth of the gap, so the gap is real. **This supersedes the
S6b entry's "check costs 8 % on the plain tree" at `:823`**, which is an
arithmetic slip on its own numbers: 87.63 against 71.77 is +22.1 %, not +8 %.
The companion "12 % on the dispatch tree" at the same line is right
(93.11 against 83.39 = +11.7 %) but compares a successful check with a failing
one and is superseded by M1b below, which does not have to.

**Where the 20 % goes, per the counters.** B creates 281 constraints, defers
476 and discharges 2 710 on a corpus that never writes a `where` clause: that
is `==` and `<` on generated code lowering to method calls (§3.1) and then
resolving against a concrete receiver. It also does 3 209 *fewer* unifications
and 2 882 fewer instantiations than A, so the cost is not extra unification —
it is the obligation bookkeeping on top of it, plus 2 766 more generalisations.

**`emit` costs 48 % and output grows 25.8 %**, unchanged from the S6b reading
and for the same reason: eager derivation (§8.5) with no DCE. It is now
measured interleaved, so the figure is no longer a cross-session one.

**The front end is flat to within the noise**, which is the part of M1a that
report 18 §2.1 asks about: lexing, parsing and lowering the *same bytes* costs
the same on both binaries (0.98×, 1.02×, 0.99×), and B lowers 2 794 fewer BIR
instructions because C1's core is two modules smaller.

---

## 2026-09-18 05:33 CEST — S8a, M1b: what USING the feature costs, same binary both sides

`plans/static-dispatch-spike.md` §7 M1b, and the first version of this row where
**both sides are the same compiler** — B at `99e0a05` against the plain tree and
against the `--dispatch` tree, run **PDDP** inside eight seconds. The M1b row in
the S6b entry (`:770-800`) compared a B plain run at 03:39 with a B dispatch run
at 04:58 after the review fixes; this one does not span a session.

**Load before P-1:** ` 05:33:46 up 4 days, 12:14,  3 users,  load average: 0.23, 0.78, 0.88`
**Load before D-1:** ` 05:33:48 up 4 days, 12:14,  3 users,  load average: 0.30, 0.78, 0.88`
**Load before D-2:** ` 05:33:50 up 4 days, 12:14,  3 users,  load average: 0.30, 0.78, 0.88`
**Load before P-2:** ` 05:33:52 up 4 days, 12:14,  3 users,  load average: 0.30, 0.78, 0.88`

```
$ direnv exec . zig build bench -- --generate=100000 --iterations=5
P1 bench: generated 624 files, 100159 lines, 1835619 bytes (plain) under .zig-cache/bench-gen
P1 {"phase":"lex",...,"tokens":302615,"ms":9.7,"mb_per_s":179.9}
P1 {"phase":"parse",...,"nodes":221576,"ms":6.7,"mb_per_s":261.2}
P1 {"phase":"lower",...,"insts":202303,"ms":9.5,"mb_per_s":184.9}
P1 {"phase":"resolve","modules":633,"edges":3932,"interfaces":633,"ms":5.26,"cold_check_ms":41.2}
P1 {"phase":"check","modules":633,"lines":100159,"unifications":228143,"generalisations":104086,"instantiations":52346,"obligations":3486,"constraints_created":281,"constraints_merged":4,"constraints_deferred":476,"constraints_discharged":2710,"constraints_promoted":1,"diagnostics":0,"ms":86.52,"loc_per_s":1157586,"cold_check_ms":127.7}
P1 {"phase":"emit","modules":633,"js_bytes":3870047,"nodes":347677,"lines":103650,"ms":49.52,"mb_per_s":74.5}
P1 {"phase":"total",...,"ms":169.4,"mb_per_s":10.3,"loc_per_s":591189}

$ direnv exec . zig build bench -- --generate=100000 --dispatch --iterations=5
D1 bench: generated 624 files, 100327 lines, 1885570 bytes (dispatch) under .zig-cache/bench-gen-dispatch
D1 {"phase":"lex",...,"tokens":317281,"ms":9.8,"mb_per_s":183.6}
D1 {"phase":"parse",...,"nodes":231896,"ms":7.3,"mb_per_s":246.7}
D1 {"phase":"lower",...,"insts":209801,"ms":10.0,"mb_per_s":179.5}
D1 {"phase":"resolve","modules":633,"edges":4018,"interfaces":633,"ms":5.71,"cold_check_ms":43.0}
D1 {"phase":"check","modules":633,"lines":100327,"unifications":238018,"generalisations":115730,"instantiations":56199,"obligations":4213,"constraints_created":347,"constraints_merged":80,"constraints_deferred":1203,"constraints_discharged":5134,"constraints_promoted":77,"diagnostics":0,"ms":93.07,"loc_per_s":1078021,"cold_check_ms":136.1}
D1 {"phase":"emit","modules":633,"js_bytes":4086222,"nodes":372018,"lines":103818,"ms":55.47,"mb_per_s":70.2}
D1 {"phase":"total",...,"ms":183.5,"mb_per_s":9.8,"loc_per_s":546766}

D2 {"phase":"lex",...,"ms":9.9}  {"phase":"parse",...,"ms":7.2}  {"phase":"lower",...,"ms":10.1}
D2 {"phase":"resolve","modules":633,"edges":4018,"interfaces":633,"ms":5.70,"cold_check_ms":43.1}
D2 {"phase":"check",…same counters…,"diagnostics":0,"ms":93.12,"loc_per_s":1077407,"cold_check_ms":136.2}
D2 {"phase":"emit","modules":633,"js_bytes":4086222,"nodes":372018,"lines":103818,"ms":55.42,"mb_per_s":70.3}
D2 {"phase":"total",...,"ms":183.6,"mb_per_s":9.8,"loc_per_s":546420}

P2 {"phase":"lex",...,"ms":9.4}  {"phase":"parse",...,"ms":6.7}  {"phase":"lower",...,"ms":9.5}
P2 {"phase":"resolve","modules":633,"edges":3932,"interfaces":633,"ms":5.52,"cold_check_ms":41.4}
P2 {"phase":"check",…same counters…,"diagnostics":0,"ms":86.22,"loc_per_s":1161628,"cold_check_ms":127.6}
P2 {"phase":"emit","modules":633,"js_bytes":3870047,"nodes":347677,"lines":103650,"ms":49.31,"mb_per_s":74.8}
P2 {"phase":"total",...,"ms":168.8,"mb_per_s":10.4,"loc_per_s":593474}
```

| phase | plain (ms) | `--dispatch` (ms) | ratio |
|---|---:|---:|---:|
| lex | 9.7, 9.4 | 9.8, 9.9 | 1.04× |
| parse | 6.7, 6.7 | 7.3, 7.2 | 1.08× |
| lower | 9.5, 9.5 | 10.0, 10.1 | 1.06× |
| resolve | 5.26, 5.52 | 5.71, 5.70 | 1.06× |
| **check** | **86.52, 86.22** | **93.07, 93.12** | **1.078×** |
| emit | 49.52, 49.31 | 55.47, 55.42 | 1.122× |
| **total** | **169.4, 168.8** | **183.5, 183.6** | **1.085×** |

The `--dispatch` tree is the same 624 modules written in the dot-call style:
**+168 lines, +49 951 bytes, +14 666 tokens, +10 320 AST nodes, +7 498 BIR
instructions**. Per byte the front end is *flat* (lex 183.6 MB/s against
179.9–184.9 plain); the 4–8 % on `lex`/`parse`/`lower` is the extra 2.7 % of
source, not a slower pass.

Constraint counters, plain → dispatch: created 281 → 347, merged 4 → 80,
deferred 476 → 1 203, discharged 2 710 → 5 134, promoted 1 → 77.

Reading: **writing 100 327 lines in the dot-call style costs 7.8 % of `check`
and 8.5 % of total wall time over writing the same program without it**, on one
compiler, in one machine state, both sides clean. That is the honest M1b number
and it is smaller than M1a's 20.3 %: most of what the feature costs is paid by
code that never uses it.

### The acceptance row — one corpus, two compilers

The `diagnostics: 0` above is B's own reading of a corpus B generated, which is
not by itself an acceptance test. So: generate the `--dispatch` tree with B,
then hand **that exact directory** to A. S1's 1 682 (`:66`) and S6b's 0 (`:797`)
were taken on two different generators — the tree has moved from 1 887 474 bytes
to 1 885 570 since — and so were never comparable.

**Load before:** ` 05:34:06 up 4 days, 12:15,  3 users,  load average: 0.30, 0.76, 0.88`

```
$ ../beni-s1/zig-out/bin/beni check --jobs=1 .zig-cache/bench-gen-dispatch --diagnostics=json
exit 1; 596 429 bytes of JSON on stderr; 1683 diagnostics
  type_mismatch 1425, wrong_type_arity 129, unexpected_token 129
first: Gen/Data/Store1.beni:63:57 TYPE MISMATCH
  "This is not a record with a `insert` field: It is: (k, k -> Order) -> Dict k v"

$ /tmp/rf/bin/beni check --jobs=1 .zig-cache/bench-gen-dispatch --diagnostics=json
exit 0; 0 bytes on stderr; 0 diagnostics
```

**Load before:** ` 05:34:13 up 4 days, 12:15,  3 users,  load average: 0.25, 0.73, 0.87`

Reading: **the same 624 files, the same bytes: 1 683 errors and exit 1 on
`master`'s checker, 0 errors and exit 0 on the branch.** This is the spike's
acceptance test stated so that both halves are the same input. The 129
`unexpected_token` diagnostics are the `where` clauses — S2's grammar — and the
1 425 `type_mismatch` are the dot-calls landing on `master`'s row-polymorphic
field access, which is exactly the "no grammar change needed, but no meaning
either" position §1.1 describes.
