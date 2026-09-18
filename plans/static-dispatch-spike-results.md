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

---

## 2026-09-18 11:18 CEST — machine 2: AMD Ryzen 9 5950X (16 cores / 32 threads), 31 GiB RAM, Linux 6.12.110 (NixOS), Zig 0.16.0, Node v24.19.0

**Read this header before any number under it. Every row below this line was
taken on a SECOND MACHINE.** Everything above it — S1, S3, S5, S6, and the S8a
correction/M1a/M1b entries — is from one Intel N100 (4 cores / 4 threads, 6 MiB
L3, single memory channel, 16 GB RAM). The two machines are not comparable and
nothing below mixes them: **where a row needs a C0 side, the C0 side is re-taken
here on the A binary rather than cited from an N100 row**, and where a row is
counter-only (a count, a diagnostic, a byte size, a `changed/accepted` ratio)
that is said explicitly, because such a figure does not depend on the machine.

**M1a and M1b stay N100-only** and are not re-taken here; report 19's §1 method
section must say so.

`hostname` `dagon`. `lscpu`: `Model name: AMD Ryzen 9 5950X 16-Core Processor`,
`CPU(s): 32`, `Thread(s) per core: 2`, `Core(s) per socket: 16`. `free -g`
total 31. `uname -r` 6.12.110. `zig version` 0.16.0, `node --version`
v24.19.0, both from the flake's dev shell (`direnv exec` and the ambient shell
resolve to the same store paths, checked).

**Binaries.**

- **A = the C0 proxy**: `../beni-s1/zig-out/bin/beni`, a
  `-Doptimize=ReleaseFast` build of `c870e9a`, **13 253 080 bytes** here
  against **13 317 664** on the N100 — **64 584 bytes smaller**. Same commit,
  same tree (`git status` clean, `git log --oneline -1` = `c870e9a`), same Zig
  0.16.0; the difference is recorded as an observation and **not** explained.
  The one thing known about it is that this is a different host CPU, so the
  native target Zig resolves is different (`znver3` against an Alder Lake-N),
  and nothing here verifies that that is the cause.
- **B = the branch**: HEAD `eb03b77` built `-Doptimize=ReleaseFast --prefix
  /tmp/rf`, **16 751 760 bytes** here against **16 854 856** on the N100
  (−103 096). Never installed into the branch's `zig-out`.
- Three gates were green on this machine at `eb03b77` before any row was taken
  (M9 below re-runs them at the end of the session).

`uptime` is recorded immediately before every instrument, verbatim; per
`bench/README.md` no number is recorded with a 1-minute load average above 2.0.
This machine is otherwise idle — an idle load here is ~0.3–0.9 — so every load
line below is far inside the bar and none had to be retried.

---

### M2 — constraint accumulation in unannotated code (A and B, machine 2)

`plans/static-dispatch-spike.md` §7 M2. Instrument:
`zig build bench -- --pathological=constraint-chain=<n> --iterations=5`, best of
5 after one warm-up, `--jobs=1`, **interleaved ABBA per n** (A-1, B-1, B-2,
A-2), A run from `../beni-s1` and B from the branch. The C0 side is re-taken
here; S1's C0 rows at `:102-141` are N100 and are not compared against.

**The generated program is byte-identical on the two sides at every n**, which
is the assertion that the two checkers read the same source: `cmp` of
`../beni-s1/.zig-cache/bench-pathological/Gen/ConstraintChain.beni` against the
branch's copy printed nothing (`IDENTICAL`) at n = 10, 100, 200, 400 and 1000,
and the `bench:` header reports the same byte count on both sides at every n
(787 / 3 760 / 7 360 / 14 560 / 36 163 / 75 163).

**Caveat, the same one M1a carries**: A checks **12** modules and B checks
**10** — C1 deletes `core/Dict/String.beni` and `core/Dict/Int.beni` — so this
is "the branch as it stands against `master` as it stands", not one program
through two checkers.

#### n = 10

```
### uptime before A-1 (n=10)
 11:09:31 up 11 min,  3 users,  load average: 0.63, 0.62, 0.36
A1 bench: generated constraint-chain n=10 (787 bytes) under .zig-cache/bench-pathological
A1 {"phase":"check","modules":12,"lines":38,"unifications":5366,"generalisations":2092,"instantiations":1662,"obligations":3,"constraints_created":0,"constraints_merged":0,"constraints_deferred":0,"constraints_discharged":0,"constraints_promoted":0,"diagnostics":0,"ms":1.57,"loc_per_s":24256,"cold_check_ms":2.6}
### uptime before B-1 (n=10)
 11:09:31 up 11 min,  3 users,  load average: 0.63, 0.62, 0.36
B1 bench: generated constraint-chain n=10 (787 bytes) under .zig-cache/bench-pathological
B1 {"phase":"check","modules":10,"lines":38,"unifications":5153,"generalisations":2006,"instantiations":1574,"obligations":104,"constraints_created":18,"constraints_merged":64,"constraints_deferred":104,"constraints_discharged":39,"constraints_promoted":55,"diagnostics":0,"ms":2.06,"loc_per_s":18403,"cold_check_ms":3.0}
### uptime before B-2 (n=10)
 11:09:31 up 11 min,  3 users,  load average: 0.63, 0.62, 0.36
B2 {"phase":"check","modules":10,"lines":38,"unifications":5153,"generalisations":2006,"instantiations":1574,"obligations":104,"constraints_created":18,"constraints_merged":64,"constraints_deferred":104,"constraints_discharged":39,"constraints_promoted":55,"diagnostics":0,"ms":1.81,"loc_per_s":20961,"cold_check_ms":2.8}
### uptime before A-2 (n=10)
 11:09:31 up 11 min,  3 users,  load average: 0.63, 0.62, 0.36
A2 {"phase":"check","modules":12,"lines":38,"unifications":5366,"generalisations":2092,"instantiations":1662,"obligations":3,"constraints_created":0,"constraints_merged":0,"constraints_deferred":0,"constraints_discharged":0,"constraints_promoted":0,"diagnostics":0,"ms":1.56,"loc_per_s":24314,"cold_check_ms":2.5}
### generated-source identity check (n=10)
IDENTICAL
```

#### n = 100

```
### uptime before A-1 (n=100)
 11:09:36 up 11 min,  3 users,  load average: 0.58, 0.61, 0.36
A1 bench: generated constraint-chain n=100 (3760 bytes) under .zig-cache/bench-pathological
A1 {"phase":"check","modules":12,"lines":308,"unifications":6716,"generalisations":17617,"instantiations":2022,"obligations":3,"constraints_created":0,"constraints_merged":0,"constraints_deferred":0,"constraints_discharged":0,"constraints_promoted":0,"diagnostics":0,"ms":4.96,"loc_per_s":62045,"cold_check_ms":6.1}
### uptime before B-1 (n=100)
 11:09:37 up 11 min,  3 users,  load average: 0.58, 0.61, 0.36
B1 bench: generated constraint-chain n=100 (3760 bytes) under .zig-cache/bench-pathological
B1 {"phase":"check","modules":10,"lines":308,"unifications":6143,"generalisations":12446,"instantiations":1934,"obligations":5099,"constraints_created":108,"constraints_merged":5149,"constraints_deferred":5099,"constraints_discharged":39,"constraints_promoted":5050,"diagnostics":0,"ms":50.81,"loc_per_s":6061,"cold_check_ms":51.9}
### uptime before B-2 (n=100)
 11:09:37 up 11 min,  3 users,  load average: 0.58, 0.61, 0.36
B2 {"phase":"check","modules":10,"lines":308,"unifications":6143,"generalisations":12446,"instantiations":1934,"obligations":5099,"constraints_created":108,"constraints_merged":5149,"constraints_deferred":5099,"constraints_discharged":39,"constraints_promoted":5050,"diagnostics":0,"ms":49.56,"loc_per_s":6214,"cold_check_ms":50.7}
### uptime before A-2 (n=100)
 11:09:38 up 11 min,  3 users,  load average: 0.58, 0.61, 0.36
A2 {"phase":"check","modules":12,"lines":308,"unifications":6716,"generalisations":17617,"instantiations":2022,"obligations":3,"constraints_created":0,"constraints_merged":0,"constraints_deferred":0,"constraints_discharged":0,"constraints_promoted":0,"diagnostics":0,"ms":4.88,"loc_per_s":63090,"cold_check_ms":6.0}
### generated-source identity check (n=100)
IDENTICAL
```

#### n = 200 and n = 400 — two brackets added because n = 1000 does not finish

The brief's n set is {10, 100, 1000, 2000}. **B cannot check n = 1000 on this
machine at all** (next block), so two intermediate points were added in the same
session to draw the curve between the last n B survives and the first it does
not. They are extra rows, not substitutes.

```
### uptime before A-1 (n=200)
 11:14:03 up 16 min,  3 users,  load average: 0.82, 0.92, 0.56
A1 bench: generated constraint-chain n=200 (7360 bytes) under .zig-cache/bench-pathological
A1 {"phase":"check","modules":12,"lines":608,"unifications":8216,"generalisations":63367,"instantiations":2422,"obligations":3,"constraints_created":0,"constraints_merged":0,"constraints_deferred":0,"constraints_discharged":0,"constraints_promoted":0,"diagnostics":0,"ms":14.64,"loc_per_s":41519,"cold_check_ms":16.0}
### uptime before B-1 (n=200)
 11:14:04 up 16 min,  3 users,  load average: 0.82, 0.92, 0.56
B1 {"phase":"check","modules":10,"lines":608,"unifications":7243,"generalisations":43046,"instantiations":2334,"obligations":20149,"constraints_created":208,"constraints_merged":20299,"constraints_deferred":20149,"constraints_discharged":39,"constraints_promoted":20100,"diagnostics":0,"ms":382.17,"loc_per_s":1590,"cold_check_ms":383.4}
### uptime before B-2 (n=200)
 11:14:07 up 16 min,  3 users,  load average: 0.84, 0.92, 0.56
B2 {"phase":"check","modules":10,"lines":608,"unifications":7243,"generalisations":43046,"instantiations":2334,"obligations":20149,"constraints_created":208,"constraints_merged":20299,"constraints_deferred":20149,"constraints_discharged":39,"constraints_promoted":20100,"diagnostics":0,"ms":387.93,"loc_per_s":1567,"cold_check_ms":389.2}
### uptime before A-2 (n=200)
 11:14:10 up 16 min,  3 users,  load average: 0.85, 0.92, 0.57
A2 {"phase":"check","modules":12,"lines":608,"unifications":8216,"generalisations":63367,"instantiations":2422,"obligations":3,"constraints_created":0,"constraints_merged":0,"constraints_deferred":0,"constraints_discharged":0,"constraints_promoted":0,"diagnostics":0,"ms":15.05,"loc_per_s":40390,"cold_check_ms":16.3}
### generated-source identity check (n=200)
IDENTICAL

### uptime before A-1 (n=400)
 11:14:15 up 16 min,  3 users,  load average: 0.78, 0.90, 0.56
A1 bench: generated constraint-chain n=400 (14560 bytes) under .zig-cache/bench-pathological
A1 {"phase":"check","modules":12,"lines":1208,"unifications":11216,"generalisations":244867,"instantiations":3222,"obligations":3,"constraints_created":0,"constraints_merged":0,"constraints_deferred":0,"constraints_discharged":0,"constraints_promoted":0,"diagnostics":0,"ms":47.53,"loc_per_s":25414,"cold_check_ms":49.1}
### uptime before B-1 (n=400)
 11:14:16 up 16 min,  3 users,  load average: 0.78, 0.90, 0.56
B1 {"phase":"check","modules":10,"lines":1208,"unifications":9443,"generalisations":164246,"instantiations":3134,"obligations":80249,"constraints_created":408,"constraints_merged":80599,"constraints_deferred":80249,"constraints_discharged":39,"constraints_promoted":80200,"diagnostics":0,"ms":3114.04,"loc_per_s":387,"cold_check_ms":3115.5}
### uptime before B-2 (n=400)
 11:14:38 up 16 min,  3 users,  load average: 0.85, 0.91, 0.57
B2 {"phase":"check","modules":10,"lines":1208,"unifications":9443,"generalisations":164246,"instantiations":3134,"obligations":80249,"constraints_created":408,"constraints_merged":80599,"constraints_deferred":80249,"constraints_discharged":39,"constraints_promoted":80200,"diagnostics":0,"ms":3124.79,"loc_per_s":386,"cold_check_ms":3126.4}
### uptime before A-2 (n=400)
 11:15:01 up 17 min,  3 users,  load average: 0.90, 0.92, 0.58
A2 {"phase":"check","modules":12,"lines":1208,"unifications":11216,"generalisations":244867,"instantiations":3222,"obligations":3,"constraints_created":0,"constraints_merged":0,"constraints_deferred":0,"constraints_discharged":0,"constraints_promoted":0,"diagnostics":0,"ms":47.53,"loc_per_s":25414,"cold_check_ms":49.1}
### generated-source identity check (n=400)
IDENTICAL
```

(The A-2 line at n = 400 is `ms: 48.11, loc_per_s: 25111, cold_check_ms: 49.6`;
the line immediately above repeats A-1 by a copy slip in this transcription and
is corrected here rather than above, per the append-only rule. Both A runs are
in `m2-400.txt`: 47.53 and 48.11.)

#### n = 1000 — B is killed after exhausting the machine's memory

`zig build bench -- --pathological=constraint-chain=1000 --iterations=5` on B
**does not produce a `check` line.** The Zig build runner reports the child
gone:

```
### uptime before A-1 (n=1000)
 11:09:53 up 12 min,  3 users,  load average: 0.45, 0.58, 0.35
A1 bench: generated constraint-chain n=1000 (36163 bytes) under .zig-cache/bench-pathological
A1 {"phase":"check","modules":12,"lines":3008,"unifications":20216,"generalisations":1509367,"instantiations":5622,"obligations":3,"constraints_created":0,"constraints_merged":0,"constraints_deferred":0,"constraints_discharged":0,"constraints_promoted":0,"diagnostics":0,"ms":234.31,"loc_per_s":12837,"cold_check_ms":236.7}
### uptime before B-1 (n=1000)
 11:09:55 up 12 min,  3 users,  load average: 0.49, 0.58, 0.35
  (no output line; 47 s, then nothing)
### uptime before B-2 (n=1000)
 11:10:42 up 13 min,  3 users,  load average: 1.05, 0.71, 0.41
  (no output line; 47 s, then nothing)
### uptime before A-2 (n=1000)
 11:11:29 up 13 min,  3 users,  load average: 1.44, 0.85, 0.47
A2 {"phase":"check","modules":12,"lines":3008,"unifications":20216,"generalisations":1509367,"instantiations":5622,"obligations":3,"constraints_created":0,"constraints_merged":0,"constraints_deferred":0,"constraints_discharged":0,"constraints_promoted":0,"diagnostics":0,"ms":254.02,"loc_per_s":11841,"cold_check_ms":256.5}
### generated-source identity check (n=1000)
IDENTICAL
```

Run again with the build runner's own diagnostic visible
(`uptime`: ` 11:11:37 up 13 min,  3 users,  load average: 1.37, 0.85, 0.47`):

```
$ direnv exec . zig build bench -- --pathological=constraint-chain=1000 --iterations=5
bench
+- run exe bench failure
error: process terminated with signal TERM
failed command: cd /home/canassa/src/github.com/canassa/beni && ./.zig-cache/o/692b932a93a3cf0a9a920f058afa8be8/bench --pathological=constraint-chain=1000 --iterations=5
real	0m47.267s
user	0m17.081s
sys	0m29.703s
```

`sys` being nearly twice `user` is the tell. Running the same bench artifact
directly under `time -v`
(`uptime`: ` 11:12:36 up 14 min,  3 users,  load average: 1.27, 0.93, 0.53`):

```
$ time -v ./.zig-cache/o/692b932a93a3cf0a9a920f058afa8be8/bench --pathological=constraint-chain=1000 --iterations=1
Command terminated by signal 15
	User time (seconds): 16.65
	System time (seconds): 30.16
	Elapsed (wall clock) time (h:mm:ss or m:ss): 0:47.30
	Maximum resident set size (kbytes): 30886876
	Minor (reclaiming a frame) page faults: 10533383
	Swaps: 0
```

**30 886 876 kB is 29.5 GiB on a 31 GiB machine.** `systemctl is-active
systemd-oomd` reports `active` and `/proc/pressure/memory` read immediately
after the run shows `full avg60=20.05`, so the process was terminated under
memory pressure rather than by anything in the compiler; the kernel ring buffer
carried no OOM-killer line for it and `sudo` is not available in this session to
read the system journal, so **which supervisor sent the `TERM` is not
established** — only that the binary reached 29.5 GiB of resident memory and was
killed there.

#### The same series as `beni check`, with peak RSS — one tree, two compilers

Because the bench harness dies before it can print, the memory curve was taken
with the plain `check` command instead, **ABBA, both binaries over the same
generated directory**, so this half is one corpus through two compilers.
`time -f '%x %e %M'`.

```
### n=100  (uptime ` 11:15:28 up 17 min,  3 users,  load average: 0.65, 0.86, 0.57`, one line for all four — the four runs fit inside one second)
A-1 exit=0 wall=0.01s maxrss=6256kB
B-1 exit=0 wall=0.06s maxrss=52992kB
B-2 exit=0 wall=0.05s maxrss=53256kB
A-2 exit=0 wall=0.00s maxrss=6512kB

### n=200  (uptime ` 11:15:35 up 17 min,  3 users,  load average: 0.63, 0.85, 0.57`)
A-1 exit=0 wall=0.01s maxrss=14960kB
B-1 exit=0 wall=0.39s maxrss=402524kB
B-2 exit=0 wall=0.40s maxrss=402268kB
A-2 exit=0 wall=0.01s maxrss=15216kB

### n=400  (uptime ` 11:15:46 up 18 min,  3 users,  load average: 0.69, 0.86, 0.58`)
A-1 exit=0 wall=0.05s maxrss=51440kB
B-1 exit=0 wall=3.21s maxrss=3307304kB
B-2 exit=0 wall=3.22s maxrss=3306916kB
A-2 exit=0 wall=0.05s maxrss=51536kB

### n=1000 (uptime ` 11:16:24 up 18 min,  3 users,  load average: 0.51, 0.79, 0.56`)
A-1 exit=0 wall=0.25s maxrss=261444kB
B-1 Command terminated by signal 15 — wall=46.37s maxrss=30585800kB
A-2 exit=0 wall=0.26s maxrss=261228kB
### uptime after
 11:17:11 up 19 min,  3 users,  load average: 1.15, 0.91, 0.62
```

B was run once at n = 1000 rather than twice: the first run had already taken
the machine to 29.2 GiB and there was nothing a second would add.

#### The table

| n | A `check` ms (r1, r2) | B `check` ms (r1, r2) | B ÷ A | A peak RSS | B peak RSS | B `obligations` | B `constraints_promoted` | clean? |
|---:|---:|---:|---:|---:|---:|---:|---:|---|
| 10 | 1.57, 1.56 | 2.06, 1.81 | 1.24× | — | — | 104 | 55 | both yes |
| 100 | 4.96, 4.88 | 50.81, 49.56 | **10.2×** | 6.3 MB | 53.0 MB | 5 099 | 5 050 | both yes |
| 200 | 14.64, 15.05 | 382.2, 387.9 | **25.9×** | 15.0 MB | 402.5 MB | 20 149 | 20 100 | both yes |
| 400 | 47.53, 48.11 | 3 114, 3 125 | **65.2×** | 51.4 MB | **3 307 MB** | 80 249 | 80 200 | both yes |
| 1 000 | 234.3, 254.0 | **killed** at 46.4 s | — | 261 MB | **30 585 800 kB = 29.2 GiB** | — | — | A yes; **B never finishes** |
| 2 000 | 243.5, 247.1 | not attempted | — | — | — | — | — | A `diagnostics: 1` (C0 breaks past ~64 links, as at `:139`); B not attempted |

n = 2000 on A, for the C0 curve only
(`uptime`: ` 11:18:19 up 20 min,  3 users,  load average: 0.74, 0.86, 0.62` and
` 11:18:21 … load average: 0.76, 0.86, 0.62`):

```
A1 bench: generated constraint-chain n=2000 (75163 bytes) under .zig-cache/bench-pathological
A1 {"phase":"check","modules":12,"lines":6008,"unifications":33268,"generalisations":1599447,"instantiations":9622,"obligations":3,"constraints_created":0,"constraints_merged":0,"constraints_deferred":0,"constraints_discharged":0,"constraints_promoted":0,"diagnostics":1,"ms":243.53,"loc_per_s":24670,"cold_check_ms":247.2}
A2 {"phase":"check","modules":12,"lines":6008,"unifications":33268,"generalisations":1599447,"instantiations":9622,"obligations":3,"constraints_created":0,"constraints_merged":0,"constraints_deferred":0,"constraints_discharged":0,"constraints_promoted":0,"diagnostics":1,"ms":247.13,"loc_per_s":24311,"cold_check_ms":250.9}
```

**n = 2000 on B was not attempted and no number is claimed for it.** n = 1000
already reaches 29.2 GiB; the counters say n = 2000 would want four times that,
and the only thing another run could produce is a second kill.

Reading. **This is the row where the branch is worst, and it is worse than S3
left it.**

**Time on B is cubic in n and memory is cubic with it.** 50.8 → 382 → 3 114 ms
for n = 100 → 200 → 400 is **7.5× and 8.2× per doubling**, and peak RSS goes
53.0 → 402.5 → 3 307 MB, **7.6× and 8.2×**. Two doublings of a chain cost
sixty-five times the work and sixty-two times the memory. A over the same three
points is 4.96 → 14.64 → 47.53 ms at 6.3 → 15.0 → 51.4 MB, which is ~n² in time
and ~n² in space and is the row-polymorphic cost the language already paid.

**At n = 1000 the branch does not compile the program at all.** Not slowly —
`beni check` on 3 008 lines reaches **29.2 GiB of resident memory in 46 seconds
and is killed**, where `master`'s checker does the same file in **0.25 s and
261 MB**. The failure mode is a killed process with no diagnostic, which is the
worst shape a compiler failure can have.

**The counters say what grew, and they are machine-independent, so they may be
compared with the S3 entry at `:633-641` even though its times may not be.** At
S3, B at n = 1000 reported `obligations: 1014` — linear in n — and finished in
483.5 ms. Today B reports `obligations: 5 099` at n = 100 and **80 249** at
n = 400, which is exactly **n(n+1)/2 + 49** (5 050 + 49; 80 200 + 49; the 49 is
`core`'s own). `constraints_deferred` tracks it one for one and
`constraints_merged` is `n(n+1)/2 + 399`. **Obligations were linear in the chain
at S3 and are quadratic in it now**, on top of the `n(n+1)/2` promotions that
were always there — so the product is the cubic curve above. Something between
S3 and `eb03b77` (S4–S7: the evidence plumbing, the parts work, the redirect
map, the pre-order numbering) made every promoted constraint carry an obligation
of its own. **This is a finding, not a fix**: S8a takes no `src/` change, and
what the counters localise is the *shape*, not the line.

**What the row does and does not say.** It does not say that ordinary code is
cubic: M1a's 100 159-line generated corpus creates 281 constraints and defers
476 across 633 modules, and `bench/corpus` and `core` check in milliseconds. It
says that the *unannotated accumulating chain* — the shape report 18 §2.3 is
about, and the one M2 exists to measure — is where the branch's constraint
bookkeeping goes non-linear, and that on the branch it now goes non-linear hard
enough to be a denial of service rather than a slowdown. A `master` adoption has
to fix this before the feature is safe, and §14 of report 19 should carry it.

#### The `where` printer does NOT have the record printer's cap

The interesting half of M2 per the brief. S1 recorded two C0 printer limits
(`:177-216`): `Render.writeRecord` flattens at most 64 extension links, so from
f65 on every rendered type is the same 65-field **closed** record at ~1 760
chars; and `Schemes.Writer.max_depth = 512` puts `<error>` into an interface the
checker exits 0 on.

**Both C0 observations reproduce here exactly**, on A, at n = 100 —
`dump --stage=types` and `--stage=interface` on
`.zig-cache/bench-pathological/Gen/ConstraintChain.beni`
(`uptime`: ` 11:17:57 up 20 min,  3 users,  load average: 0.83, 0.88, 0.62`):

```
A types f1     fields=   1 chars=    34   f1 : { r | m1 : number -> a } -> a
A types f50    fields=  50 chars=  1355
A types f64    fields=  64 chars=  1733
A types f65    fields=  65 chars=  1756
A types f66    fields=  65 chars=  1756
A types f70    fields=  65 chars=  1756
A types f99    fields=  65 chars=  1756
A types f100   fields=  65 chars=  1757
A iface f65    fields=  65 chars=  1762
A iface f100   fields=  65 chars=  1763
```

Those are S1's N100 figures to the character (65 fields, 1 756–1 763 chars), so
the cap is in the printer and not in the machine.

**B has no such cap.** Same instrument, same n, on `/tmp/rf/bin/beni`
(`uptime`: ` 11:17:28 up 19 min,  3 users,  load average: 1.37, 0.97, 0.64`
for n = 100, ` 11:18:09 up 20 min,  3 users,  load average: 0.78, 0.87, 0.62`
for n = 200):

```
B types f1     clauses=   1 chars=    39   f1 : a -> b where a.m1 : a, number -> b
B types f2     clauses=   2 chars=    79
B types f10    clauses=  10 chars=   315
B types f50    clauses=  50 chars=  1555
B types f64    clauses=  64 chars=  1989
B types f65    clauses=  65 chars=  2020
B types f66    clauses=  66 chars=  2051
B types f70    clauses=  70 chars=  2175
B types f99    clauses=  99 chars=  3075
B types f100   clauses= 100 chars=  3109
B types f150   clauses= 150 chars=  4759   (n=200 tree)
B types f199   clauses= 199 chars=  6376   (n=200 tree)
B types f200   clauses= 200 chars=  6409   (n=200 tree)
B iface f1     clauses=   1 chars=    45
B iface f65    clauses=  65 chars=  2026
B iface f100   clauses= 100 chars=  3115
B iface f200   clauses= 200 chars=  6415   (n=200 tree)

$ grep -c '<error>' b-types-200.txt b-iface-200.txt
b-types-200.txt:0
b-iface-200.txt:0
```

Reading: **the `where` printer prints every clause, without a cap, and the
interface carries every one of them.** f200's scheme renders at **200 clauses /
6 409 characters** in `dump --stage=types` and **6 415** in
`dump --stage=interface`, growing at a dead-straight **31 characters per
clause** (2 020 at 65, 3 109 at 100, 6 409 at 200), and `<error>` appears
nowhere. The structural reason is that a `where` list is **flat** where a record
extension is a **chain**: nothing here recurses 64 or 512 deep, so neither
`writeRecord`'s guard nor `Schemes.Writer.max_depth` is reached.

That is better and worse than C0 at the same time, and report 19 should say
both. Better: the branch's interface is **honest** — it prints the constraint
the caller actually has to satisfy, where C0 silently truncates the record to 65
fields and then writes `<error>` into the interface of a module `check` accepts.
Worse: there is now no bound at all on what one unannotated declaration can
write into an interface, so the 6.4 kB scheme above is a real interface entry,
and the churn M3 measures is churn over text of that size.

---

### M3 — interface churn (A and B, machine 2)

`plans/static-dispatch-spike.md` §7 M3. Both sides re-taken here per the machine
rule, **interleaved ABBA** (A-1, B-1, B-2, A-2) per corpus.

A is run from `../beni-s1` with **that tree's own `bench/churn.sh` and its own
`bench/corpus`/`core`** — which is how the S1 C0 row at `:220-289` was taken, and
is the only way to take it: C1 rewrote both corpora, so the C0 side must edit the
C0 sources. B is run from the branch with `--beni=/tmp/rf/bin/beni`. The script
copies the root into `mktemp -d` and restores (`churn.sh:151-153`), so neither
worktree is written to; every run below printed `tree restored: yes`.

One difference between the two scripts is worth naming: the S6b flake fix (a tmp
dir whose name begins with `-` parsed as an option, ~1 run in 32) is in the
branch's `churn.sh` and **not** in `c870e9a`'s. No A run below shows it — both A
runs are identical to each other and to the N100 table — but it is a reason the A
side is worth running twice.

**Load before A-1 (bench/corpus):** ` 11:21:19 up 23 min,  3 users,  load average: 0.07, 0.50, 0.52`
**Load before B-1:** ` 11:21:29 up 23 min,  3 users,  load average: 0.21, 0.51, 0.52`
**Load before B-2:** ` 11:21:39 up 24 min,  3 users,  load average: 0.39, 0.54, 0.53`
**Load before A-2:** ` 11:21:50 up 24 min,  3 users,  load average: 0.96, 0.65, 0.57`

```
$ (A, in ../beni-s1) sh bench/churn.sh --corpus=bench/corpus
A1 corpus: bench/corpus
A1 modules excluded (the pristine root does not resolve them): JsonCodecs.beni NotesApp.beni
A1 tree restored: yes
A1 edit    variant       changed/accepted  applied  skipped  rejected  decls
A1 ------  ------------  ----------------  -------  -------  --------  -----
A1 E1      annotated               0/20       20       83         0    103
A1 E1      unannotated             0/19       21       82         2    103
A1 E2      annotated                0/1        2      101         1    103
A1 E2      unannotated              0/1        4       99         3    103
A1 E3      annotated               0/52       84       19        32    103
A1 E3      unannotated             5/52       84       19        32    103
A1 E3poly  annotated                0/0        5       98         5    103
A1 E3poly  unannotated              4/4        7       96         3    103
A1 real	0m10.458s  user	0m5.859s  sys	0m8.714s

$ (B) sh bench/churn.sh --corpus=bench/corpus --beni=/tmp/rf/bin/beni
B1 corpus: bench/corpus
B1 modules excluded (the pristine root does not resolve them): JsonCodecs.beni NotesApp.beni
B1 tree restored: yes
B1 edit    variant       changed/accepted  applied  skipped  rejected  decls
B1 ------  ------------  ----------------  -------  -------  --------  -----
B1 E1      annotated               0/20       20       83         0    103
B1 E1      unannotated             0/19       25       78         6    103
B1 E2      annotated                0/1        2      101         1    103
B1 E2      unannotated              0/1        8       95         7    103
B1 E3      annotated               0/70       84       19        14    103
B1 E3      unannotated            29/68       85       18        17    103
B1 E3poly  annotated                0/0        5       98         5    103
B1 E3poly  unannotated              4/4       11       92         7    103
B1 real	0m10.301s  user	0m6.195s  sys	0m8.406s

B2 (byte-identical table to B1)
B2 E1 annotated 0/20 20 83 0 103 · E1 unannotated 0/19 25 78 6 103
B2 E2 annotated 0/1 2 101 1 103 · E2 unannotated 0/1 8 95 7 103
B2 E3 annotated 0/70 84 19 14 103 · E3 unannotated 29/68 85 18 17 103
B2 E3poly annotated 0/0 5 98 5 103 · E3poly unannotated 4/4 11 92 7 103
B2 real	0m10.445s  user	0m6.038s  sys	0m8.591s

A2 (byte-identical table to A1)
A2 E1 annotated 0/20 20 83 0 103 · E1 unannotated 0/19 21 82 2 103
A2 E2 annotated 0/1 2 101 1 103 · E2 unannotated 0/1 4 99 3 103
A2 E3 annotated 0/52 84 19 32 103 · E3 unannotated 5/52 84 19 32 103
A2 E3poly annotated 0/0 5 98 5 103 · E3poly unannotated 4/4 7 96 3 103
A2 real	0m10.778s  user	0m6.039s  sys	0m8.747s
```

**Load before A-1 (core):** ` 11:22:06 up 24 min,  3 users,  load average: 0.89, 0.65, 0.57`
**Load before B-1:** ` 11:22:20 up 24 min,  3 users,  load average: 0.99, 0.69, 0.58`
**Load before B-2:** ` 11:22:34 up 24 min,  3 users,  load average: 0.99, 0.70, 0.59`
**Load before A-2:** ` 11:22:48 up 25 min,  3 users,  load average: 1.07, 0.73, 0.60`

```
$ (A, in ../beni-s1) sh bench/churn.sh --corpus=core --core
A1 corpus: core
A1 tree restored: yes
A1 edit    variant       changed/accepted  applied  skipped  rejected  decls
A1 ------  ------------  ----------------  -------  -------  --------  -----
A1 E1      annotated               0/15       15      129         0    144
A1 E1      unannotated             0/15       15      129         0    144
A1 E2      annotated                0/7        8      136         1    144
A1 E2      unannotated              0/7        8      136         1    144
A1 E3      annotated               0/88      111       33        23    144
A1 E3      unannotated             8/94      111       33        17    144
A1 E3poly  annotated                0/0       16      128        16    144
A1 E3poly  unannotated            14/14       16      128         2    144
A1 real	0m14.188s  user	0m7.088s  sys	0m10.325s

$ (B) sh bench/churn.sh --corpus=core --core --beni=/tmp/rf/bin/beni
B1 corpus: core
B1 tree restored: yes
B1 edit    variant       changed/accepted  applied  skipped  rejected  decls
B1 ------  ------------  ----------------  -------  -------  --------  -----
B1 E1      annotated               0/15       15      123         0    138
B1 E1      unannotated             0/15       15      123         0    138
B1 E2      annotated                0/7        8      130         1    138
B1 E2      unannotated              0/7        8      130         1    138
B1 E3      annotated               0/74      105       33        31    138
B1 E3      unannotated            50/90      105       33        15    138
B1 E3poly  annotated                0/0       13      125        13    138
B1 E3poly  unannotated            12/12       13      125         1    138
B1 real	0m13.713s  user	0m6.998s  sys	0m9.583s

B2 (byte-identical table to B1)  real	0m13.824s  user	0m6.811s  sys	0m9.949s
A2 (byte-identical table to A1)  real	0m14.649s  user	0m7.389s  sys	0m10.511s
```

| corpus | edit | variant | A (C0) | B (C1) |
|---|---|---|---:|---:|
| `bench/corpus` | E1 | annotated | 0/20 | 0/20 |
| | E1 | unannotated | 0/19 | 0/19 |
| | E2 | annotated | 0/1 | 0/1 |
| | E2 | unannotated | 0/1 | 0/1 |
| | E3 | annotated | 0/52 | 0/70 |
| | **E3** | **unannotated** | **5/52 (9.6 %)** | **29/68 (42.6 %)** |
| | E3poly | annotated | 0/0 | 0/0 |
| | **E3poly** | **unannotated** | **4/4 (100 %)** | **4/4 (100 %)** |
| `core` | E1 | annotated | 0/15 | 0/15 |
| | E1 | unannotated | 0/15 | 0/15 |
| | E2 | annotated | 0/7 | 0/7 |
| | E2 | unannotated | 0/7 | 0/7 |
| | E3 | annotated | 0/88 | 0/74 |
| | **E3** | **unannotated** | **8/94 (8.5 %)** | **50/90 (55.6 %)** |
| | E3poly | annotated | 0/0 | 0/0 |
| | **E3poly** | **unannotated** | **14/14 (100 %)** | **12/12 (100 %)** |

Reading.

**Every number in this table is byte-identical to the N100's.** A reproduces the
S1 C0 table at `:240-247` and `:263-270` row for row; B reproduces the S6b C1
table at `:845-852` and `:868-875` row for row. That is not a coincidence and it
is worth stating as a result in its own right: **`changed/accepted` is a property
of the compiler and the corpus and not of the machine**, so M3 is the one row
above where the N100 and machine-2 figures could be quoted interchangeably —
though this file quotes only the machine-2 run, per the header.

**Every `annotated` row is 0 on both compilers and both corpora**, E3 and E3poly
included. An annotation is the whole interface, so a body edit cannot move it,
and static dispatch has not changed that. This is the answer to report 18 §2.3's
objection and it is now measured twice on two machines.

**The cost is confined to unannotated `pub` declarations, where it is 4.4× and
6.5× worse.** E3 unannotated on `core` moves the interface 50/90 = 55.6 % against
C0's 8/94 = 8.5 %; on `bench/corpus` 29/68 = 42.6 % against 5/52 = 9.6 %. Only
the ratios are comparable, not the raw counts: C1's `core` has 138 declarations
against C0's 144, because `core/Dict/String.beni` and `core/Dict/Int.beni` are
deleted with six `pub` values and `Dict.comparatorOf` with them.

**E3poly — the bare-type-variable row report 18 §2.3 is actually about — was
already 100 % on C0 and stays 100 %.** 4/4 and 14/14 on C0, 4/4 and 12/12 on C1.
The polymorphic case was never the difference the objection claims.

**E3's `annotated` accepted count moves in opposite directions on the two
corpora**, as S6b recorded: on `bench/corpus` 70 accepted against C0's 52 (and 14
rejected against 32), because `p == p` on a bare type variable now type-checks
under an inferred `where`; on `core` 74 against 88, because the declaration set
itself shrank.

---

### M4 — output size, with the per-method split (A and B, machine 2)

`plans/static-dispatch-spike.md` §7 M4. **Both sides re-taken here, by ONE
script** — the branch's `bench/size.mjs`, which this slice extended with the six
split fields (`eq_functions`/`eq_bytes`, `compare_functions`/`compare_bytes`,
`order_tables`/`order_bytes`) on the floor line, every program line and the
total. `git diff c870e9a HEAD -- bench/size.mjs bench/runtime.mjs` is **empty**,
so the script the S1 C0 row at `:293` used and the one used here differ by
nothing but this slice's addition, and pointing it at A's binary and A's corpora
is the same instrument rather than a second one.

The A invocation therefore names the C0 corpora explicitly and the program
labels carry a `../beni-s1/` prefix; that prefix is the only difference from
S1's labels. **Interleaved ABBA** (A-1, B-1, B-2, A-2). Both repeats were
**byte-identical** to their first run (`cmp` printed nothing), which is expected
— `size.mjs` measures bytes, not time — and is recorded because it is the check
that the two builds in between changed nothing.

**Load before A-1:** ` 11:25:47 up 28 min,  3 users,  load average: 0.16, 0.45, 0.51`
**Load before B-1:** ` 11:25:50 up 28 min,  3 users,  load average: 0.23, 0.46, 0.52`
**Load before B-2:** ` 11:25:55 up 28 min,  3 users,  load average: 0.45, 0.50, 0.53`
**Load before A-2:** ` 11:26:01 up 28 min,  3 users,  load average: 0.50, 0.51, 0.53`
**Load after:** ` 11:26:04 up 28 min,  3 users,  load average: 0.50, 0.51, 0.53`

```
$ (A) node bench/size.mjs --beni=../beni-s1/zig-out/bin/beni --corpus=../beni-s1/tests/corpus/run --corpus=../beni-s1/bench/corpus
A {"floor":true,"entry":"Empty","files":21,"raw_bytes":65214,"gzip_bytes":15410,"brotli_bytes":12932,"derived_bytes":0,"derived_functions":0,"eq_functions":0,"eq_bytes":0,"compare_functions":0,"compare_bytes":0,"order_tables":0,"order_bytes":0}
A {"program":"../beni-s1/bench/corpus","entry":"BenchMain (synthesised)","modules_measured":7,"modules_excluded":["Data/Parser.beni","ExprParser.beni","JsonCodecs.beni","NotesApp.beni"],"files":28,"raw_bytes":109053,"gzip_bytes":24085,"brotli_bytes":20423,"derived_bytes":0,"derived_functions":0,"eq_functions":0,"eq_bytes":0,"compare_functions":0,"compare_bytes":0,"order_tables":0,"order_bytes":0,"net_raw_bytes":43839,"net_gzip_bytes":8675,"net_brotli_bytes":7491}
A {"program":"../beni-s1/tests/corpus/run/Adt.beni","entry":"Adt","files":21,"raw_bytes":66350,"gzip_bytes":15694,"brotli_bytes":13196,"derived_bytes":0,"derived_functions":0,"eq_functions":0,"eq_bytes":0,"compare_functions":0,"compare_bytes":0,"order_tables":0,"order_bytes":0,"net_raw_bytes":1136,"net_gzip_bytes":284,"net_brotli_bytes":264}
A {"program":"../beni-s1/tests/corpus/run/Arithmetic.beni","entry":"Arithmetic","files":21,"raw_bytes":66218,"gzip_bytes":15591,"brotli_bytes":13101,"derived_bytes":0,"derived_functions":0,"eq_functions":0,"eq_bytes":0,"compare_functions":0,"compare_bytes":0,"order_tables":0,"order_bytes":0,"net_raw_bytes":1004,"net_gzip_bytes":181,"net_brotli_bytes":169}
A {"program":"../beni-s1/tests/corpus/run/BindPipeRhs.beni","entry":"BindPipeRhs","files":21,"raw_bytes":66072,"gzip_bytes":15592,"brotli_bytes":13112,"derived_bytes":0,"derived_functions":0,"eq_functions":0,"eq_bytes":0,"compare_functions":0,"compare_bytes":0,"order_tables":0,"order_bytes":0,"net_raw_bytes":858,"net_gzip_bytes":182,"net_brotli_bytes":180}
A {"program":"../beni-s1/tests/corpus/run/CaseLiterals.beni","entry":"CaseLiterals","files":21,"raw_bytes":65928,"gzip_bytes":15594,"brotli_bytes":13087,"derived_bytes":0,"derived_functions":0,"eq_functions":0,"eq_bytes":0,"compare_functions":0,"compare_bytes":0,"order_tables":0,"order_bytes":0,"net_raw_bytes":714,"net_gzip_bytes":184,"net_brotli_bytes":155}
A {"program":"../beni-s1/tests/corpus/run/CharOps.beni","entry":"CharOps","files":21,"raw_bytes":66104,"gzip_bytes":15614,"brotli_bytes":13110,"derived_bytes":0,"derived_functions":0,"eq_functions":0,"eq_bytes":0,"compare_functions":0,"compare_bytes":0,"order_tables":0,"order_bytes":0,"net_raw_bytes":890,"net_gzip_bytes":204,"net_brotli_bytes":178}
A {"program":"../beni-s1/tests/corpus/run/Closures.beni","entry":"Closures","files":21,"raw_bytes":66370,"gzip_bytes":15701,"brotli_bytes":13201,"derived_bytes":0,"derived_functions":0,"eq_functions":0,"eq_bytes":0,"compare_functions":0,"compare_bytes":0,"order_tables":0,"order_bytes":0,"net_raw_bytes":1156,"net_gzip_bytes":291,"net_brotli_bytes":269}
A {"program":"../beni-s1/tests/corpus/run/Comparison.beni","entry":"Comparison","files":21,"raw_bytes":66271,"gzip_bytes":15582,"brotli_bytes":13132,"derived_bytes":0,"derived_functions":0,"eq_functions":0,"eq_bytes":0,"compare_functions":0,"compare_bytes":0,"order_tables":0,"order_bytes":0,"net_raw_bytes":1057,"net_gzip_bytes":172,"net_brotli_bytes":200}
A {"program":"../beni-s1/tests/corpus/run/ConsPatterns.beni","entry":"ConsPatterns","files":21,"raw_bytes":66798,"gzip_bytes":15708,"brotli_bytes":13201,"derived_bytes":0,"derived_functions":0,"eq_functions":0,"eq_bytes":0,"compare_functions":0,"compare_bytes":0,"order_tables":0,"order_bytes":0,"net_raw_bytes":1584,"net_gzip_bytes":298,"net_brotli_bytes":269}
A {"program":"../beni-s1/tests/corpus/run/DebugLog.beni","entry":"DebugLog","files":21,"raw_bytes":65837,"gzip_bytes":15561,"brotli_bytes":13032,"derived_bytes":0,"derived_functions":0,"eq_functions":0,"eq_bytes":0,"compare_functions":0,"compare_bytes":0,"order_tables":0,"order_bytes":0,"net_raw_bytes":623,"net_gzip_bytes":151,"net_brotli_bytes":100}
A {"program":"../beni-s1/tests/corpus/run/Dictionaries.beni","entry":"Dictionaries","files":21,"raw_bytes":66145,"gzip_bytes":15635,"brotli_bytes":13114,"derived_bytes":0,"derived_functions":0,"eq_functions":0,"eq_bytes":0,"compare_functions":0,"compare_bytes":0,"order_tables":0,"order_bytes":0,"net_raw_bytes":931,"net_gzip_bytes":225,"net_brotli_bytes":182}
A {"program":"../beni-s1/tests/corpus/run/ExitCode.beni","entry":"ExitCode","files":21,"raw_bytes":65407,"gzip_bytes":15472,"brotli_bytes":12983,"derived_bytes":0,"derived_functions":0,"eq_functions":0,"eq_bytes":0,"compare_functions":0,"compare_bytes":0,"order_tables":0,"order_bytes":0,"net_raw_bytes":193,"net_gzip_bytes":62,"net_brotli_bytes":51}
A {"program":"../beni-s1/tests/corpus/run/HigherOrder.beni","entry":"HigherOrder","files":21,"raw_bytes":66469,"gzip_bytes":15734,"brotli_bytes":13202,"derived_bytes":0,"derived_functions":0,"eq_functions":0,"eq_bytes":0,"compare_functions":0,"compare_bytes":0,"order_tables":0,"order_bytes":0,"net_raw_bytes":1255,"net_gzip_bytes":324,"net_brotli_bytes":270}
A {"program":"../beni-s1/tests/corpus/run/ImportedModule.beni","entry":"ImportedModule","files":21,"raw_bytes":65847,"gzip_bytes":15558,"brotli_bytes":13084,"derived_bytes":0,"derived_functions":0,"eq_functions":0,"eq_bytes":0,"compare_functions":0,"compare_bytes":0,"order_tables":0,"order_bytes":0,"net_raw_bytes":633,"net_gzip_bytes":148,"net_brotli_bytes":152}
A {"program":"../beni-s1/tests/corpus/run/Interpolation.beni","entry":"Interpolation","files":21,"raw_bytes":65879,"gzip_bytes":15633,"brotli_bytes":13148,"derived_bytes":0,"derived_functions":0,"eq_functions":0,"eq_bytes":0,"compare_functions":0,"compare_bytes":0,"order_tables":0,"order_bytes":0,"net_raw_bytes":665,"net_gzip_bytes":223,"net_brotli_bytes":216}
A {"program":"../beni-s1/tests/corpus/run/LetNesting.beni","entry":"LetNesting","files":21,"raw_bytes":65919,"gzip_bytes":15610,"brotli_bytes":13095,"derived_bytes":0,"derived_functions":0,"eq_functions":0,"eq_bytes":0,"compare_functions":0,"compare_bytes":0,"order_tables":0,"order_bytes":0,"net_raw_bytes":705,"net_gzip_bytes":200,"net_brotli_bytes":163}
A {"program":"../beni-s1/tests/corpus/run/LibraryArgumentOrder.beni","entry":"LibraryArgumentOrder","files":21,"raw_bytes":66948,"gzip_bytes":15797,"brotli_bytes":13266,"derived_bytes":0,"derived_functions":0,"eq_functions":0,"eq_bytes":0,"compare_functions":0,"compare_bytes":0,"order_tables":0,"order_bytes":0,"net_raw_bytes":1734,"net_gzip_bytes":387,"net_brotli_bytes":334}
A {"program":"../beni-s1/tests/corpus/run/ListBuild.beni","entry":"ListBuild","files":21,"raw_bytes":66385,"gzip_bytes":15624,"brotli_bytes":13131,"derived_bytes":0,"derived_functions":0,"eq_functions":0,"eq_bytes":0,"compare_functions":0,"compare_bytes":0,"order_tables":0,"order_bytes":0,"net_raw_bytes":1171,"net_gzip_bytes":214,"net_brotli_bytes":199}
A {"program":"../beni-s1/tests/corpus/run/ListFold.beni","entry":"ListFold","files":21,"raw_bytes":66587,"gzip_bytes":15689,"brotli_bytes":13174,"derived_bytes":0,"derived_functions":0,"eq_functions":0,"eq_bytes":0,"compare_functions":0,"compare_bytes":0,"order_tables":0,"order_bytes":0,"net_raw_bytes":1373,"net_gzip_bytes":279,"net_brotli_bytes":242}
A {"program":"../beni-s1/tests/corpus/run/MaybeResult.beni","entry":"MaybeResult","files":21,"raw_bytes":66604,"gzip_bytes":15701,"brotli_bytes":13167,"derived_bytes":0,"derived_functions":0,"eq_functions":0,"eq_bytes":0,"compare_functions":0,"compare_bytes":0,"order_tables":0,"order_bytes":0,"net_raw_bytes":1390,"net_gzip_bytes":291,"net_brotli_bytes":235}
A {"program":"../beni-s1/tests/corpus/run/NumericEdge.beni","entry":"NumericEdge","files":21,"raw_bytes":66621,"gzip_bytes":15650,"brotli_bytes":13148,"derived_bytes":0,"derived_functions":0,"eq_functions":0,"eq_bytes":0,"compare_functions":0,"compare_bytes":0,"order_tables":0,"order_bytes":0,"net_raw_bytes":1407,"net_gzip_bytes":240,"net_brotli_bytes":216}
A {"program":"../beni-s1/tests/corpus/run/Patterns.beni","entry":"Patterns","files":21,"raw_bytes":66398,"gzip_bytes":15699,"brotli_bytes":13185,"derived_bytes":0,"derived_functions":0,"eq_functions":0,"eq_bytes":0,"compare_functions":0,"compare_bytes":0,"order_tables":0,"order_bytes":0,"net_raw_bytes":1184,"net_gzip_bytes":289,"net_brotli_bytes":253}
A {"program":"../beni-s1/tests/corpus/run/PipeFirst.beni","entry":"PipeFirst","files":21,"raw_bytes":66117,"gzip_bytes":15594,"brotli_bytes":13107,"derived_bytes":0,"derived_functions":0,"eq_functions":0,"eq_bytes":0,"compare_functions":0,"compare_bytes":0,"order_tables":0,"order_bytes":0,"net_raw_bytes":903,"net_gzip_bytes":184,"net_brotli_bytes":175}
A {"program":"../beni-s1/tests/corpus/run/PipeNestedGrouping.beni","entry":"PipeNestedGrouping","files":21,"raw_bytes":66062,"gzip_bytes":15557,"brotli_bytes":13063,"derived_bytes":0,"derived_functions":0,"eq_functions":0,"eq_bytes":0,"compare_functions":0,"compare_bytes":0,"order_tables":0,"order_bytes":0,"net_raw_bytes":848,"net_gzip_bytes":147,"net_brotli_bytes":131}
A {"program":"../beni-s1/tests/corpus/run/Placeholder.beni","entry":"Placeholder","files":21,"raw_bytes":66320,"gzip_bytes":15642,"brotli_bytes":13131,"derived_bytes":0,"derived_functions":0,"eq_functions":0,"eq_bytes":0,"compare_functions":0,"compare_bytes":0,"order_tables":0,"order_bytes":0,"net_raw_bytes":1106,"net_gzip_bytes":232,"net_brotli_bytes":199}
A {"program":"../beni-s1/tests/corpus/run/PlaceholderAndBind.beni","entry":"PlaceholderAndBind","files":21,"raw_bytes":66644,"gzip_bytes":15732,"brotli_bytes":13208,"derived_bytes":0,"derived_functions":0,"eq_functions":0,"eq_bytes":0,"compare_functions":0,"compare_bytes":0,"order_tables":0,"order_bytes":0,"net_raw_bytes":1430,"net_gzip_bytes":322,"net_brotli_bytes":276}
A {"program":"../beni-s1/tests/corpus/run/Records.beni","entry":"Records","files":21,"raw_bytes":65867,"gzip_bytes":15582,"brotli_bytes":13125,"derived_bytes":0,"derived_functions":0,"eq_functions":0,"eq_bytes":0,"compare_functions":0,"compare_bytes":0,"order_tables":0,"order_bytes":0,"net_raw_bytes":653,"net_gzip_bytes":172,"net_brotli_bytes":193}
A {"program":"../beni-s1/tests/corpus/run/Recursion.beni","entry":"Recursion","files":21,"raw_bytes":66315,"gzip_bytes":15655,"brotli_bytes":13146,"derived_bytes":0,"derived_functions":0,"eq_functions":0,"eq_bytes":0,"compare_functions":0,"compare_bytes":0,"order_tables":0,"order_bytes":0,"net_raw_bytes":1101,"net_gzip_bytes":245,"net_brotli_bytes":214}
A {"program":"../beni-s1/tests/corpus/run/RestOfBlockBind.beni","entry":"RestOfBlockBind","files":21,"raw_bytes":66247,"gzip_bytes":15686,"brotli_bytes":13197,"derived_bytes":0,"derived_functions":0,"eq_functions":0,"eq_bytes":0,"compare_functions":0,"compare_bytes":0,"order_tables":0,"order_bytes":0,"net_raw_bytes":1033,"net_gzip_bytes":276,"net_brotli_bytes":265}
A {"program":"../beni-s1/tests/corpus/run/SaturatedCalls.beni","entry":"SaturatedCalls","files":21,"raw_bytes":66693,"gzip_bytes":15730,"brotli_bytes":13235,"derived_bytes":0,"derived_functions":0,"eq_functions":0,"eq_bytes":0,"compare_functions":0,"compare_bytes":0,"order_tables":0,"order_bytes":0,"net_raw_bytes":1479,"net_gzip_bytes":320,"net_brotli_bytes":303}
A {"program":"../beni-s1/tests/corpus/run/ShortCircuit.beni","entry":"ShortCircuit","files":21,"raw_bytes":65635,"gzip_bytes":15526,"brotli_bytes":13012,"derived_bytes":0,"derived_functions":0,"eq_functions":0,"eq_bytes":0,"compare_functions":0,"compare_bytes":0,"order_tables":0,"order_bytes":0,"net_raw_bytes":421,"net_gzip_bytes":116,"net_brotli_bytes":80}
A {"program":"../beni-s1/tests/corpus/run/Sorting.beni","entry":"Sorting","files":21,"raw_bytes":66196,"gzip_bytes":15642,"brotli_bytes":13164,"derived_bytes":0,"derived_functions":0,"eq_functions":0,"eq_bytes":0,"compare_functions":0,"compare_bytes":0,"order_tables":0,"order_bytes":0,"net_raw_bytes":982,"net_gzip_bytes":232,"net_brotli_bytes":232}
A {"program":"../beni-s1/tests/corpus/run/StringBuilding.beni","entry":"StringBuilding","files":21,"raw_bytes":66052,"gzip_bytes":15633,"brotli_bytes":13124,"derived_bytes":0,"derived_functions":0,"eq_functions":0,"eq_bytes":0,"compare_functions":0,"compare_bytes":0,"order_tables":0,"order_bytes":0,"net_raw_bytes":838,"net_gzip_bytes":223,"net_brotli_bytes":192}
A {"program":"../beni-s1/tests/corpus/run/StringOps.beni","entry":"StringOps","files":21,"raw_bytes":66350,"gzip_bytes":15710,"brotli_bytes":13229,"derived_bytes":0,"derived_functions":0,"eq_functions":0,"eq_bytes":0,"compare_functions":0,"compare_bytes":0,"order_tables":0,"order_bytes":0,"net_raw_bytes":1136,"net_gzip_bytes":300,"net_brotli_bytes":297}
A {"program":"../beni-s1/tests/corpus/run/Tuples.beni","entry":"Tuples","files":21,"raw_bytes":66402,"gzip_bytes":15724,"brotli_bytes":13218,"derived_bytes":0,"derived_functions":0,"eq_functions":0,"eq_bytes":0,"compare_functions":0,"compare_bytes":0,"order_tables":0,"order_bytes":0,"net_raw_bytes":1188,"net_gzip_bytes":314,"net_brotli_bytes":286}
A {"total":true,"programs":35,"files":742,"raw_bytes":143834,"gzip_bytes":31997,"brotli_bytes":27563,"floor_raw_bytes":65214,"floor_gzip_bytes":15410,"floor_brotli_bytes":12932,"net_raw_bytes":78620,"net_gzip_bytes":16587,"net_brotli_bytes":14631,"gross_raw_bytes":2361110,"gross_gzip_bytes":555937,"gross_brotli_bytes":467251,"derived_bytes":0,"derived_functions":0,"eq_functions":0,"eq_bytes":0,"compare_functions":0,"compare_bytes":0,"order_tables":0,"order_bytes":0}
```

```
$ (B) node bench/size.mjs --beni=/tmp/rf/bin/beni
B {"floor":true,"entry":"Empty","files":19,"raw_bytes":68791,"gzip_bytes":16399,"brotli_bytes":13838,"derived_bytes":3159,"derived_functions":22,"eq_functions":8,"eq_bytes":1041,"compare_functions":9,"compare_bytes":1874,"order_tables":5,"order_bytes":244}
B {"program":"bench/corpus","entry":"BenchMain (synthesised)","modules_measured":7,"modules_excluded":["Data/Parser.beni","ExprParser.beni","JsonCodecs.beni","NotesApp.beni"],"files":26,"raw_bytes":121965,"gzip_bytes":26465,"brotli_bytes":22507,"derived_bytes":11659,"derived_functions":59,"eq_functions":24,"eq_bytes":4121,"compare_functions":21,"compare_bytes":6561,"order_tables":14,"order_bytes":977,"net_raw_bytes":53174,"net_gzip_bytes":10066,"net_brotli_bytes":8669}
B {"program":"tests/corpus/run/Adt.beni","entry":"Adt","files":19,"raw_bytes":71039,"gzip_bytes":16827,"brotli_bytes":14245,"derived_bytes":4199,"derived_functions":28,"eq_functions":10,"eq_bytes":1329,"compare_functions":11,"compare_bytes":2514,"order_tables":7,"order_bytes":356,"net_raw_bytes":2248,"net_gzip_bytes":428,"net_brotli_bytes":407}
B {"program":"tests/corpus/run/Arithmetic.beni","entry":"Arithmetic","files":19,"raw_bytes":69795,"gzip_bytes":16579,"brotli_bytes":14000,"derived_bytes":3159,"derived_functions":22,"eq_functions":8,"eq_bytes":1041,"compare_functions":9,"compare_bytes":1874,"order_tables":5,"order_bytes":244,"net_raw_bytes":1004,"net_gzip_bytes":180,"net_brotli_bytes":162}
B {"program":"tests/corpus/run/BindPipeRhs.beni","entry":"BindPipeRhs","files":19,"raw_bytes":69649,"gzip_bytes":16573,"brotli_bytes":13968,"derived_bytes":3159,"derived_functions":22,"eq_functions":8,"eq_bytes":1041,"compare_functions":9,"compare_bytes":1874,"order_tables":5,"order_bytes":244,"net_raw_bytes":858,"net_gzip_bytes":174,"net_brotli_bytes":130}
B {"program":"tests/corpus/run/CaseLiterals.beni","entry":"CaseLiterals","files":19,"raw_bytes":69505,"gzip_bytes":16579,"brotli_bytes":13982,"derived_bytes":3159,"derived_functions":22,"eq_functions":8,"eq_bytes":1041,"compare_functions":9,"compare_bytes":1874,"order_tables":5,"order_bytes":244,"net_raw_bytes":714,"net_gzip_bytes":180,"net_brotli_bytes":144}
B {"program":"tests/corpus/run/CharOps.beni","entry":"CharOps","files":19,"raw_bytes":69681,"gzip_bytes":16603,"brotli_bytes":14012,"derived_bytes":3159,"derived_functions":22,"eq_functions":8,"eq_bytes":1041,"compare_functions":9,"compare_bytes":1874,"order_tables":5,"order_bytes":244,"net_raw_bytes":890,"net_gzip_bytes":204,"net_brotli_bytes":174}
B {"program":"tests/corpus/run/Closures.beni","entry":"Closures","files":19,"raw_bytes":69947,"gzip_bytes":16683,"brotli_bytes":14069,"derived_bytes":3159,"derived_functions":22,"eq_functions":8,"eq_bytes":1041,"compare_functions":9,"compare_bytes":1874,"order_tables":5,"order_bytes":244,"net_raw_bytes":1156,"net_gzip_bytes":284,"net_brotli_bytes":231}
B {"program":"tests/corpus/run/Comparison.beni","entry":"Comparison","files":19,"raw_bytes":69864,"gzip_bytes":16588,"brotli_bytes":13973,"derived_bytes":3208,"derived_functions":23,"eq_functions":9,"eq_bytes":1090,"compare_functions":9,"compare_bytes":1874,"order_tables":5,"order_bytes":244,"net_raw_bytes":1073,"net_gzip_bytes":189,"net_brotli_bytes":135}
B {"program":"tests/corpus/run/ConsPatterns.beni","entry":"ConsPatterns","files":19,"raw_bytes":70375,"gzip_bytes":16690,"brotli_bytes":14083,"derived_bytes":3159,"derived_functions":22,"eq_functions":8,"eq_bytes":1041,"compare_functions":9,"compare_bytes":1874,"order_tables":5,"order_bytes":244,"net_raw_bytes":1584,"net_gzip_bytes":291,"net_brotli_bytes":245}
B {"program":"tests/corpus/run/ConstantMethodCall.beni","entry":"ConstantMethodCall","files":19,"raw_bytes":69750,"gzip_bytes":16606,"brotli_bytes":14021,"derived_bytes":3327,"derived_functions":24,"eq_functions":9,"eq_bytes":1106,"compare_functions":10,"compare_bytes":1977,"order_tables":5,"order_bytes":244,"net_raw_bytes":959,"net_gzip_bytes":207,"net_brotli_bytes":183}
B {"program":"tests/corpus/run/ConstrainedMutualRecursion.beni","entry":"ConstrainedMutualRecursion","files":19,"raw_bytes":70255,"gzip_bytes":16673,"brotli_bytes":14090,"derived_bytes":3258,"derived_functions":23,"eq_functions":8,"eq_bytes":1041,"compare_functions":10,"compare_bytes":1973,"order_tables":5,"order_bytes":244,"net_raw_bytes":1464,"net_gzip_bytes":274,"net_brotli_bytes":252}
B {"program":"tests/corpus/run/ConstrainedPartEvidence.beni","entry":"ConstrainedPartEvidence","files":19,"raw_bytes":72258,"gzip_bytes":16919,"brotli_bytes":14262,"derived_bytes":3884,"derived_functions":28,"eq_functions":13,"eq_bytes":1598,"compare_functions":10,"compare_bytes":2042,"order_tables":5,"order_bytes":244,"net_raw_bytes":3467,"net_gzip_bytes":520,"net_brotli_bytes":424}
B {"program":"tests/corpus/run/DebugLog.beni","entry":"DebugLog","files":19,"raw_bytes":69414,"gzip_bytes":16545,"brotli_bytes":13918,"derived_bytes":3159,"derived_functions":22,"eq_functions":8,"eq_bytes":1041,"compare_functions":9,"compare_bytes":1874,"order_tables":5,"order_bytes":244,"net_raw_bytes":623,"net_gzip_bytes":146,"net_brotli_bytes":80}
B {"program":"tests/corpus/run/DecodeInto.beni","entry":"DecodeInto","files":19,"raw_bytes":70577,"gzip_bytes":16786,"brotli_bytes":14180,"derived_bytes":3332,"derived_functions":25,"eq_functions":10,"eq_bytes":1143,"compare_functions":10,"compare_bytes":1945,"order_tables":5,"order_bytes":244,"net_raw_bytes":1786,"net_gzip_bytes":387,"net_brotli_bytes":342}
B {"program":"tests/corpus/run/DerivedEquality.beni","entry":"DerivedEquality","files":19,"raw_bytes":74108,"gzip_bytes":16993,"brotli_bytes":14385,"derived_bytes":5396,"derived_functions":35,"eq_functions":15,"eq_bytes":1875,"compare_functions":12,"compare_bytes":3092,"order_tables":8,"order_bytes":429,"net_raw_bytes":5317,"net_gzip_bytes":594,"net_brotli_bytes":547}
B {"program":"tests/corpus/run/DerivedEqualityEdges.beni","entry":"DerivedEqualityEdges","files":19,"raw_bytes":72006,"gzip_bytes":16805,"brotli_bytes":14183,"derived_bytes":3652,"derived_functions":28,"eq_functions":13,"eq_bytes":1431,"compare_functions":10,"compare_bytes":1977,"order_tables":5,"order_bytes":244,"net_raw_bytes":3215,"net_gzip_bytes":406,"net_brotli_bytes":345}
B {"program":"tests/corpus/run/DerivedOrdering.beni","entry":"DerivedOrdering","files":19,"raw_bytes":75205,"gzip_bytes":17218,"brotli_bytes":14578,"derived_bytes":6281,"derived_functions":39,"eq_functions":12,"eq_bytes":1786,"compare_functions":17,"compare_bytes":3870,"order_tables":10,"order_bytes":625,"net_raw_bytes":6414,"net_gzip_bytes":819,"net_brotli_bytes":740}
B {"program":"tests/corpus/run/DictRecordKey.beni","entry":"DictRecordKey","files":19,"raw_bytes":70804,"gzip_bytes":16819,"brotli_bytes":14192,"derived_bytes":3440,"derived_functions":24,"eq_functions":8,"eq_bytes":1041,"compare_functions":11,"compare_bytes":2155,"order_tables":5,"order_bytes":244,"net_raw_bytes":2013,"net_gzip_bytes":420,"net_brotli_bytes":354}
B {"program":"tests/corpus/run/DictStructuralEquality.beni","entry":"DictStructuralEquality","files":19,"raw_bytes":70437,"gzip_bytes":16689,"brotli_bytes":14076,"derived_bytes":3318,"derived_functions":24,"eq_functions":10,"eq_bytes":1200,"compare_functions":9,"compare_bytes":1874,"order_tables":5,"order_bytes":244,"net_raw_bytes":1646,"net_gzip_bytes":290,"net_brotli_bytes":238}
B {"program":"tests/corpus/run/Dictionaries.beni","entry":"Dictionaries","files":19,"raw_bytes":69786,"gzip_bytes":16627,"brotli_bytes":14016,"derived_bytes":3159,"derived_functions":22,"eq_functions":8,"eq_bytes":1041,"compare_functions":9,"compare_bytes":1874,"order_tables":5,"order_bytes":244,"net_raw_bytes":995,"net_gzip_bytes":228,"net_brotli_bytes":178}
B {"program":"tests/corpus/run/EvidenceCapture.beni","entry":"EvidenceCapture","files":19,"raw_bytes":69971,"gzip_bytes":16625,"brotli_bytes":14008,"derived_bytes":3475,"derived_functions":25,"eq_functions":9,"eq_bytes":1098,"compare_functions":10,"compare_bytes":2074,"order_tables":6,"order_bytes":303,"net_raw_bytes":1180,"net_gzip_bytes":226,"net_brotli_bytes":170}
B {"program":"tests/corpus/run/ExitCode.beni","entry":"ExitCode","files":19,"raw_bytes":68984,"gzip_bytes":16459,"brotli_bytes":13868,"derived_bytes":3159,"derived_functions":22,"eq_functions":8,"eq_bytes":1041,"compare_functions":9,"compare_bytes":1874,"order_tables":5,"order_bytes":244,"net_raw_bytes":193,"net_gzip_bytes":60,"net_brotli_bytes":30}
B {"program":"tests/corpus/run/HigherOrder.beni","entry":"HigherOrder","files":19,"raw_bytes":70046,"gzip_bytes":16715,"brotli_bytes":14098,"derived_bytes":3159,"derived_functions":22,"eq_functions":8,"eq_bytes":1041,"compare_functions":9,"compare_bytes":1874,"order_tables":5,"order_bytes":244,"net_raw_bytes":1255,"net_gzip_bytes":316,"net_brotli_bytes":260}
B {"program":"tests/corpus/run/ImportedModule.beni","entry":"ImportedModule","files":19,"raw_bytes":69424,"gzip_bytes":16541,"brotli_bytes":13956,"derived_bytes":3159,"derived_functions":22,"eq_functions":8,"eq_bytes":1041,"compare_functions":9,"compare_bytes":1874,"order_tables":5,"order_bytes":244,"net_raw_bytes":633,"net_gzip_bytes":142,"net_brotli_bytes":118}
B {"program":"tests/corpus/run/Interpolation.beni","entry":"Interpolation","files":19,"raw_bytes":69456,"gzip_bytes":16622,"brotli_bytes":14012,"derived_bytes":3159,"derived_functions":22,"eq_functions":8,"eq_bytes":1041,"compare_functions":9,"compare_bytes":1874,"order_tables":5,"order_bytes":244,"net_raw_bytes":665,"net_gzip_bytes":223,"net_brotli_bytes":174}
B {"program":"tests/corpus/run/LetNesting.beni","entry":"LetNesting","files":19,"raw_bytes":69496,"gzip_bytes":16588,"brotli_bytes":14013,"derived_bytes":3159,"derived_functions":22,"eq_functions":8,"eq_bytes":1041,"compare_functions":9,"compare_bytes":1874,"order_tables":5,"order_bytes":244,"net_raw_bytes":705,"net_gzip_bytes":189,"net_brotli_bytes":175}
B {"program":"tests/corpus/run/LibraryArgumentOrder.beni","entry":"LibraryArgumentOrder","files":19,"raw_bytes":71377,"gzip_bytes":16941,"brotli_bytes":14341,"derived_bytes":3252,"derived_functions":23,"eq_functions":8,"eq_bytes":1041,"compare_functions":10,"compare_bytes":1967,"order_tables":5,"order_bytes":244,"net_raw_bytes":2586,"net_gzip_bytes":542,"net_brotli_bytes":503}
B {"program":"tests/corpus/run/ListBuild.beni","entry":"ListBuild","files":19,"raw_bytes":69962,"gzip_bytes":16603,"brotli_bytes":13985,"derived_bytes":3159,"derived_functions":22,"eq_functions":8,"eq_bytes":1041,"compare_functions":9,"compare_bytes":1874,"order_tables":5,"order_bytes":244,"net_raw_bytes":1171,"net_gzip_bytes":204,"net_brotli_bytes":147}
B {"program":"tests/corpus/run/ListElementEq.beni","entry":"ListElementEq","files":19,"raw_bytes":72715,"gzip_bytes":16843,"brotli_bytes":14235,"derived_bytes":3600,"derived_functions":25,"eq_functions":10,"eq_bytes":1271,"compare_functions":10,"compare_bytes":2085,"order_tables":5,"order_bytes":244,"net_raw_bytes":3924,"net_gzip_bytes":444,"net_brotli_bytes":397}
B {"program":"tests/corpus/run/ListFold.beni","entry":"ListFold","files":19,"raw_bytes":70250,"gzip_bytes":16694,"brotli_bytes":14080,"derived_bytes":3240,"derived_functions":23,"eq_functions":8,"eq_bytes":1041,"compare_functions":10,"compare_bytes":1955,"order_tables":5,"order_bytes":244,"net_raw_bytes":1459,"net_gzip_bytes":295,"net_brotli_bytes":242}
B {"program":"tests/corpus/run/ListMemberEq.beni","entry":"ListMemberEq","files":19,"raw_bytes":70425,"gzip_bytes":16685,"brotli_bytes":14086,"derived_bytes":3597,"derived_functions":25,"eq_functions":10,"eq_bytes":1269,"compare_functions":10,"compare_bytes":2084,"order_tables":5,"order_bytes":244,"net_raw_bytes":1634,"net_gzip_bytes":286,"net_brotli_bytes":248}
B {"program":"tests/corpus/run/ListOrdering.beni","entry":"ListOrdering","files":19,"raw_bytes":71601,"gzip_bytes":16803,"brotli_bytes":14208,"derived_bytes":3408,"derived_functions":24,"eq_functions":8,"eq_bytes":1041,"compare_functions":11,"compare_bytes":2123,"order_tables":5,"order_bytes":244,"net_raw_bytes":2810,"net_gzip_bytes":404,"net_brotli_bytes":370}
B {"program":"tests/corpus/run/MaybeResult.beni","entry":"MaybeResult","files":19,"raw_bytes":70181,"gzip_bytes":16687,"brotli_bytes":14073,"derived_bytes":3159,"derived_functions":22,"eq_functions":8,"eq_bytes":1041,"compare_functions":9,"compare_bytes":1874,"order_tables":5,"order_bytes":244,"net_raw_bytes":1390,"net_gzip_bytes":288,"net_brotli_bytes":235}
B {"program":"tests/corpus/run/MethodCalls.beni","entry":"MethodCalls","files":19,"raw_bytes":70387,"gzip_bytes":16696,"brotli_bytes":14106,"derived_bytes":3309,"derived_functions":24,"eq_functions":9,"eq_bytes":1097,"compare_functions":10,"compare_bytes":1968,"order_tables":5,"order_bytes":244,"net_raw_bytes":1596,"net_gzip_bytes":297,"net_brotli_bytes":268}
B {"program":"tests/corpus/run/NestedConstrainedCalls.beni","entry":"NestedConstrainedCalls","files":19,"raw_bytes":71119,"gzip_bytes":16822,"brotli_bytes":14172,"derived_bytes":3828,"derived_functions":26,"eq_functions":9,"eq_bytes":1247,"compare_functions":11,"compare_bytes":2270,"order_tables":6,"order_bytes":311,"net_raw_bytes":2328,"net_gzip_bytes":423,"net_brotli_bytes":334}
B {"program":"tests/corpus/run/NestedConstrainedListKeys.beni","entry":"NestedConstrainedListKeys","files":19,"raw_bytes":74993,"gzip_bytes":17379,"brotli_bytes":14686,"derived_bytes":4006,"derived_functions":27,"eq_functions":11,"eq_bytes":1412,"compare_functions":11,"compare_bytes":2350,"order_tables":5,"order_bytes":244,"net_raw_bytes":6202,"net_gzip_bytes":980,"net_brotli_bytes":848}
B {"program":"tests/corpus/run/NumericEdge.beni","entry":"NumericEdge","files":19,"raw_bytes":70198,"gzip_bytes":16636,"brotli_bytes":14037,"derived_bytes":3159,"derived_functions":22,"eq_functions":8,"eq_bytes":1041,"compare_functions":9,"compare_bytes":1874,"order_tables":5,"order_bytes":244,"net_raw_bytes":1407,"net_gzip_bytes":237,"net_brotli_bytes":199}
B {"program":"tests/corpus/run/OrderValues.beni","entry":"OrderValues","files":19,"raw_bytes":70404,"gzip_bytes":16664,"brotli_bytes":14063,"derived_bytes":3516,"derived_functions":25,"eq_functions":10,"eq_bytes":1208,"compare_functions":10,"compare_bytes":2064,"order_tables":5,"order_bytes":244,"net_raw_bytes":1613,"net_gzip_bytes":265,"net_brotli_bytes":225}
B {"program":"tests/corpus/run/OrderingPrimitives.beni","entry":"OrderingPrimitives","files":19,"raw_bytes":70133,"gzip_bytes":16632,"brotli_bytes":14002,"derived_bytes":3159,"derived_functions":22,"eq_functions":8,"eq_bytes":1041,"compare_functions":9,"compare_bytes":1874,"order_tables":5,"order_bytes":244,"net_raw_bytes":1342,"net_gzip_bytes":233,"net_brotli_bytes":164}
B {"program":"tests/corpus/run/ParametricEquality.beni","entry":"ParametricEquality","files":19,"raw_bytes":73192,"gzip_bytes":16864,"brotli_bytes":14241,"derived_bytes":3628,"derived_functions":27,"eq_functions":11,"eq_bytes":1265,"compare_functions":11,"compare_bytes":2119,"order_tables":5,"order_bytes":244,"net_raw_bytes":4401,"net_gzip_bytes":465,"net_brotli_bytes":403}
B {"program":"tests/corpus/run/Patterns.beni","entry":"Patterns","files":19,"raw_bytes":70419,"gzip_bytes":16758,"brotli_bytes":14161,"derived_bytes":3476,"derived_functions":26,"eq_functions":10,"eq_bytes":1175,"compare_functions":11,"compare_bytes":2057,"order_tables":5,"order_bytes":244,"net_raw_bytes":1628,"net_gzip_bytes":359,"net_brotli_bytes":323}
B {"program":"tests/corpus/run/PipeFirst.beni","entry":"PipeFirst","files":19,"raw_bytes":69801,"gzip_bytes":16601,"brotli_bytes":13994,"derived_bytes":3241,"derived_functions":23,"eq_functions":8,"eq_bytes":1041,"compare_functions":10,"compare_bytes":1956,"order_tables":5,"order_bytes":244,"net_raw_bytes":1010,"net_gzip_bytes":202,"net_brotli_bytes":156}
B {"program":"tests/corpus/run/PipeNestedGrouping.beni","entry":"PipeNestedGrouping","files":19,"raw_bytes":69639,"gzip_bytes":16541,"brotli_bytes":13961,"derived_bytes":3159,"derived_functions":22,"eq_functions":8,"eq_bytes":1041,"compare_functions":9,"compare_bytes":1874,"order_tables":5,"order_bytes":244,"net_raw_bytes":848,"net_gzip_bytes":142,"net_brotli_bytes":123}
B {"program":"tests/corpus/run/Placeholder.beni","entry":"Placeholder","files":19,"raw_bytes":69897,"gzip_bytes":16624,"brotli_bytes":14016,"derived_bytes":3159,"derived_functions":22,"eq_functions":8,"eq_bytes":1041,"compare_functions":9,"compare_bytes":1874,"order_tables":5,"order_bytes":244,"net_raw_bytes":1106,"net_gzip_bytes":225,"net_brotli_bytes":178}
B {"program":"tests/corpus/run/PlaceholderAndBind.beni","entry":"PlaceholderAndBind","files":19,"raw_bytes":70221,"gzip_bytes":16713,"brotli_bytes":14100,"derived_bytes":3159,"derived_functions":22,"eq_functions":8,"eq_bytes":1041,"compare_functions":9,"compare_bytes":1874,"order_tables":5,"order_bytes":244,"net_raw_bytes":1430,"net_gzip_bytes":314,"net_brotli_bytes":262}
B {"program":"tests/corpus/run/PrimitiveEvidence.beni","entry":"PrimitiveEvidence","files":19,"raw_bytes":70884,"gzip_bytes":16712,"brotli_bytes":14118,"derived_bytes":3615,"derived_functions":26,"eq_functions":9,"eq_bytes":1097,"compare_functions":11,"compare_bytes":2129,"order_tables":6,"order_bytes":389,"net_raw_bytes":2093,"net_gzip_bytes":313,"net_brotli_bytes":280}
B {"program":"tests/corpus/run/Records.beni","entry":"Records","files":19,"raw_bytes":69444,"gzip_bytes":16565,"brotli_bytes":13998,"derived_bytes":3159,"derived_functions":22,"eq_functions":8,"eq_bytes":1041,"compare_functions":9,"compare_bytes":1874,"order_tables":5,"order_bytes":244,"net_raw_bytes":653,"net_gzip_bytes":166,"net_brotli_bytes":160}
B {"program":"tests/corpus/run/Recursion.beni","entry":"Recursion","files":19,"raw_bytes":69824,"gzip_bytes":16626,"brotli_bytes":14042,"derived_bytes":3159,"derived_functions":22,"eq_functions":8,"eq_bytes":1041,"compare_functions":9,"compare_bytes":1874,"order_tables":5,"order_bytes":244,"net_raw_bytes":1033,"net_gzip_bytes":227,"net_brotli_bytes":204}
B {"program":"tests/corpus/run/RestOfBlockBind.beni","entry":"RestOfBlockBind","files":19,"raw_bytes":69824,"gzip_bytes":16667,"brotli_bytes":14063,"derived_bytes":3159,"derived_functions":22,"eq_functions":8,"eq_bytes":1041,"compare_functions":9,"compare_bytes":1874,"order_tables":5,"order_bytes":244,"net_raw_bytes":1033,"net_gzip_bytes":268,"net_brotli_bytes":225}
B {"program":"tests/corpus/run/SaturatedCalls.beni","entry":"SaturatedCalls","files":19,"raw_bytes":70623,"gzip_bytes":16786,"brotli_bytes":14179,"derived_bytes":3450,"derived_functions":24,"eq_functions":9,"eq_bytes":1117,"compare_functions":10,"compare_bytes":2089,"order_tables":5,"order_bytes":244,"net_raw_bytes":1832,"net_gzip_bytes":387,"net_brotli_bytes":341}
B {"program":"tests/corpus/run/ShortCircuit.beni","entry":"ShortCircuit","files":19,"raw_bytes":69212,"gzip_bytes":16509,"brotli_bytes":13923,"derived_bytes":3159,"derived_functions":22,"eq_functions":8,"eq_bytes":1041,"compare_functions":9,"compare_bytes":1874,"order_tables":5,"order_bytes":244,"net_raw_bytes":421,"net_gzip_bytes":110,"net_brotli_bytes":85}
B {"program":"tests/corpus/run/Sorting.beni","entry":"Sorting","files":19,"raw_bytes":69993,"gzip_bytes":16673,"brotli_bytes":14089,"derived_bytes":3239,"derived_functions":23,"eq_functions":8,"eq_bytes":1041,"compare_functions":10,"compare_bytes":1954,"order_tables":5,"order_bytes":244,"net_raw_bytes":1202,"net_gzip_bytes":274,"net_brotli_bytes":251}
B {"program":"tests/corpus/run/StringBuilding.beni","entry":"StringBuilding","files":19,"raw_bytes":69629,"gzip_bytes":16619,"brotli_bytes":14004,"derived_bytes":3159,"derived_functions":22,"eq_functions":8,"eq_bytes":1041,"compare_functions":9,"compare_bytes":1874,"order_tables":5,"order_bytes":244,"net_raw_bytes":838,"net_gzip_bytes":220,"net_brotli_bytes":166}
B {"program":"tests/corpus/run/StringOps.beni","entry":"StringOps","files":19,"raw_bytes":69927,"gzip_bytes":16693,"brotli_bytes":14079,"derived_bytes":3159,"derived_functions":22,"eq_functions":8,"eq_bytes":1041,"compare_functions":9,"compare_bytes":1874,"order_tables":5,"order_bytes":244,"net_raw_bytes":1136,"net_gzip_bytes":294,"net_brotli_bytes":241}
B {"program":"tests/corpus/run/StringOrdering.beni","entry":"StringOrdering","files":19,"raw_bytes":70085,"gzip_bytes":16676,"brotli_bytes":14061,"derived_bytes":3159,"derived_functions":22,"eq_functions":8,"eq_bytes":1041,"compare_functions":9,"compare_bytes":1874,"order_tables":5,"order_bytes":244,"net_raw_bytes":1294,"net_gzip_bytes":277,"net_brotli_bytes":223}
B {"program":"tests/corpus/run/Tuples.beni","entry":"Tuples","files":19,"raw_bytes":69979,"gzip_bytes":16712,"brotli_bytes":14087,"derived_bytes":3159,"derived_functions":22,"eq_functions":8,"eq_bytes":1041,"compare_functions":9,"compare_bytes":1874,"order_tables":5,"order_bytes":244,"net_raw_bytes":1188,"net_gzip_bytes":313,"net_brotli_bytes":249}
B {"program":"tests/corpus/run/TwoSlotsNested.beni","entry":"TwoSlotsNested","files":19,"raw_bytes":75897,"gzip_bytes":17197,"brotli_bytes":14466,"derived_bytes":3389,"derived_functions":25,"eq_functions":10,"eq_bytes":1184,"compare_functions":10,"compare_bytes":1961,"order_tables":5,"order_bytes":244,"net_raw_bytes":7106,"net_gzip_bytes":798,"net_brotli_bytes":628}
B {"program":"tests/corpus/run/TypeDispatch.beni","entry":"TypeDispatch","files":19,"raw_bytes":69641,"gzip_bytes":16600,"brotli_bytes":14020,"derived_bytes":3311,"derived_functions":24,"eq_functions":9,"eq_bytes":1098,"compare_functions":10,"compare_bytes":1969,"order_tables":5,"order_bytes":244,"net_raw_bytes":850,"net_gzip_bytes":201,"net_brotli_bytes":182}
B {"program":"tests/corpus/run/UserEqInsideParametric.beni","entry":"UserEqInsideParametric","files":19,"raw_bytes":70845,"gzip_bytes":16735,"brotli_bytes":14104,"derived_bytes":3627,"derived_functions":25,"eq_functions":10,"eq_bytes":1289,"compare_functions":10,"compare_bytes":2094,"order_tables":5,"order_bytes":244,"net_raw_bytes":2054,"net_gzip_bytes":336,"net_brotli_bytes":266}
B {"program":"tests/corpus/run/UserEqInsideRecord.beni","entry":"UserEqInsideRecord","files":19,"raw_bytes":70800,"gzip_bytes":16745,"brotli_bytes":14146,"derived_bytes":3778,"derived_functions":27,"eq_functions":12,"eq_bytes":1444,"compare_functions":10,"compare_bytes":2090,"order_tables":5,"order_bytes":244,"net_raw_bytes":2009,"net_gzip_bytes":346,"net_brotli_bytes":308}
B {"program":"tests/corpus/run/UserEquality.beni","entry":"UserEquality","files":19,"raw_bytes":69710,"gzip_bytes":16609,"brotli_bytes":13997,"derived_bytes":3551,"derived_functions":24,"eq_functions":9,"eq_bytes":1218,"compare_functions":10,"compare_bytes":2089,"order_tables":5,"order_bytes":244,"net_raw_bytes":919,"net_gzip_bytes":210,"net_brotli_bytes":159}
B {"total":true,"programs":61,"files":1166,"raw_bytes":229568,"gzip_bytes":45187,"brotli_bytes":38338,"floor_raw_bytes":68791,"floor_gzip_bytes":16399,"floor_brotli_bytes":13838,"net_raw_bytes":160777,"net_gzip_bytes":28788,"net_brotli_bytes":24500,"gross_raw_bytes":4357028,"gross_gzip_bytes":1029127,"gross_brotli_bytes":868618,"derived_bytes":216942,"derived_functions":1497,"eq_functions":562,"eq_bytes":72603,"compare_functions":608,"compare_bytes":127773,"order_tables":327,"order_bytes":16566}
```

#### The floor

| | A (C0, `c870e9a`) | B (C1, `eb03b77`) | Δ |
|---|---:|---:|---:|
| files | 21 | 19 | −2 (`Dict.String`, `Dict.Int` deleted) |
| raw | 65 214 | 68 791 | **+3 577, +5.5 %** |
| gzip | 15 410 | 16 399 | +989, +6.4 % |
| brotli | 12 932 | 13 838 | +906, +7.0 % |
| `derived_bytes` / `derived_functions` | 0 / 0 | **3 159 / 22** | — |
| `eq_bytes` / `eq_functions` | 0 / 0 | **1 041 / 8** | 130.1 B per function |
| `compare_bytes` / `compare_functions` | 0 / 0 | **1 874 / 9** | 208.2 B per function |
| `order_bytes` / `order_tables` | 0 / 0 | **244 / 5** | 48.8 B per table |

#### `bench/corpus` and the 35 programs that exist on both sides

| | A (C0) | B (C1) | Δ |
|---|---:|---:|---:|
| `bench/corpus` raw | 109 053 | 121 965 | +11.8 % |
| `bench/corpus` net raw | 43 839 | 53 174 | +21.3 % |
| `bench/corpus` derived | 0 / 0 | 11 659 B / 59 fns | **197.6 B per derived function** |
| `bench/corpus` split | — | eq 24 / 4 121 · compare 21 / 6 561 · order 14 / 977 | — |
| net raw summed over the **35 programs present on both sides** | **78 620** | **91 141** | **+12 521, +15.9 %** |
| median per-program net-raw change over those 35 | — | — | **0 bytes** |

The six largest and the three smallest of those 35, by change in `net_raw_bytes`:

```
bench/corpus                                43839 ->  53174  +9335
tests/corpus/run/Adt.beni                    1136 ->   2248  +1112
tests/corpus/run/LibraryArgumentOrder.beni   1734 ->   2586   +852
tests/corpus/run/Patterns.beni               1184 ->   1628   +444
tests/corpus/run/SaturatedCalls.beni         1479 ->   1832   +353
tests/corpus/run/Sorting.beni                 982 ->   1202   +220
tests/corpus/run/StringOps.beni              1136 ->   1136     +0
tests/corpus/run/Tuples.beni                 1188 ->   1188     +0
tests/corpus/run/Recursion.beni              1101 ->   1033    −68
```

#### The 26 programs with no C0 counterpart, by construction

B measures **61** programs against A's 35. The 26 extra are the spike's own
`run/` fixtures and cannot be compared with anything on the C0 side — they do
not exist there and several of them would not compile there. They are listed so
that no total below mixes them into a before/after:

```
ConstantMethodCall  ConstrainedMutualRecursion  ConstrainedPartEvidence
DecodeInto  DerivedEquality  DerivedEqualityEdges  DerivedOrdering
DictRecordKey  DictStructuralEquality  EvidenceCapture  ListElementEq
ListMemberEq  ListOrdering  MethodCalls  NestedConstrainedCalls
NestedConstrainedListKeys  OrderValues  OrderingPrimitives
ParametricEquality  PrimitiveEvidence  StringOrdering  TwoSlotsNested
TypeDispatch  UserEqInsideParametric  UserEqInsideRecord  UserEquality
```

`DecodeInto` is the one that is new **since** the S6b M4 run at `:916-988`,
which covered 60 programs; it is S7's forwarded-evidence fixture. Every other
line of B's run is unchanged from that entry.

B's total line, for completeness — 61 programs, and **not** a before/after of
anything:

```
{"total":true,"programs":61,"files":1166,"raw_bytes":229568,"gzip_bytes":45187,"brotli_bytes":38338,…,"derived_bytes":216942,"derived_functions":1497,"eq_functions":562,"eq_bytes":72603,"compare_functions":608,"compare_bytes":127773,"order_tables":327,"order_bytes":16566}
```

Reading.

**Every byte in this row is machine-independent, and that is checked rather than
assumed.** A's floor here is **65 214 / 15 410 / 12 932** over 21 files and its
total is **143 834 raw, 78 620 net, 2 361 110 gross** — every one of them
identical to the N100's S1 figures at `:306` and `:342`. B's floor is **68 791 /
16 399 / 13 838** with `derived_bytes` 3 159 over 22 functions, identical to the
N100's S6b figures at `:926`. So M4 is the second row (after M3) whose numbers do
not depend on the machine, and report 19 may say so.

**The split, which is the number this slice exists to take.** Derived `eq` is
**1 041 bytes over 8 functions (130.1 each)**; derived `compare` is **1 874
bytes over 9 (208.2 each)**; the `$$order` tables are **244 bytes over 5 (48.8
each)**. **A derived `compare` costs 1.60× what a derived `eq` costs**, which is
§9's lexicographic-with-early-return shape against a chain of `&&`, and the
`$order` table is the part with no `eq` counterpart at all. Over all 61 programs
the per-function figures hold to within a byte — eq 129.2, compare 210.2, order
50.7 — so this is a property of the emitted shape and not of core's particular
types. **Three numbers, never a sum**, per §11 and A.38.

**Correction to the S6b entry's hand-taken split at `:997`.** That line reports
`eq_bytes 1050, compare_bytes 1889, order_bytes 244` from an ad-hoc `node -e`
walk. Those three sum to **3 183**, while the same entry's `derived_bytes` is
**3 159** — they do not add up, so at least one of them is 24 bytes long. The
split is now taken **inside the same walk that produces `derived_bytes`**, from
the same statement slices, so it adds up by construction; `build_test` asserts
both `eq_functions + compare_functions + order_tables == derived_functions` and
`eq_bytes + compare_bytes + order_bytes == derived_bytes`. The counts (8, 9, 5)
were right in S6b and are unchanged; the byte figures to use are **1 041 / 1 874
/ 244**.

**The floor grew 5.5 % and 4.6 % of the floor is derived code.** 3 159 of the
68 791 bytes an empty program ships are derived functions nothing calls. The
rest of the +3 577 is `core/List.js` and `core/Dict.beni`'s seventeen `where`
clauses against the two deleted modules. Six of the twenty-two floor functions
are new with the comparator rewrite and nothing calls any of them — S6b priced
that at `:1020-1027` and this run does not move it.

**Per program the cost is small, concentrated, and mostly zero.** Over the 35
programs that exist on both sides the net total is 78 620 → 91 141, **+15.9 %**,
but the **median program moves by 0 bytes** and three of them move by 0 or less
(`Recursion` is 68 bytes *smaller*). The whole of the change is in a handful:
`bench/corpus` (+9 335), `Adt` (+1 112), `LibraryArgumentOrder` (+852, which
also gained three lines of source). The mechanism is eager derivation — a
program pays per *type it declares*, not per line it writes.

**Every number here is an upper bound, and the reason is in the row above it.**
There is no DCE (§11). 216 942 bytes of derived code across 61 programs, of
which the overwhelming majority is never called, is what "grows per type ×
method" costs *before* the elimination pass that M3's build order owes.

---

### M5 — runtime of the emitted JavaScript, all six programs (machine 2)

`plans/static-dispatch-spike.md` §7 M5. `bench/runtime.mjs` builds each program
with `beni build` and runs it under Node, 20 runs, best / median / ns per op net
of a measured process floor. `git diff c870e9a HEAD -- bench/runtime.mjs` and
`-- bench/runtime/c0/` are both **empty**, so the harness and the six C0 programs
are the same files S1 measured; only the compiler and the `c1/` directory differ.

**The two C1 programs this slice wrote.** `bench/runtime/c1/R5EvidenceForwarding.beni`
and `c1/R6Megamorphic.beni` are new, written to their C0 headers: the same
`-- ops:` count (10 000 000 and 3 000 000), `where a.compare : a, a -> Order` on
all three levels, `x.compare mark` at the call site, one hidden evidence
parameter, **no comparator parameter, no closure built to carry one, and no
`key` call** in R5. Both printed the C0 checksum on the first run.

**R4's C1 side is the branch binary against `--variant=c0`**, per the manager
decision — R4 is a program about `==`, C1 changes nothing in its source, and
copying it into `c1/` would only have created a second file to keep in step.

**One session, interleaved C1 → C0 → C1 → C0, `--runs=20`, all six rows, inside
80 seconds.**

**Load before C1 round 1:** ` 11:29:52 up 32 min,  3 users,  load average: 0.29, 0.42, 0.49`
**Load before C0 round 1:** ` 11:30:08 up 32 min,  3 users,  load average: 0.68, 0.50, 0.51`
**Load before C1 round 2:** ` 11:30:29 up 32 min,  3 users,  load average: 0.97, 0.58, 0.54`
**Load before C0 round 2:** ` 11:30:46 up 33 min,  3 users,  load average: 1.19, 0.66, 0.57`
**Load after:** ` 11:31:07 up 33 min,  3 users,  load average: 1.20, 0.70, 0.58`

```
$ node bench/runtime.mjs --variant=c1 --runs=20 --beni=/tmp/rf/bin/beni
C1r1 {"program":"R1DictString","variant":"c1","runs":20,"ops":120000,"floor_ms":26.8,"best_ms":216.7,"median_ms":224.18,"ns_per_op":1582.5,"checksum":"60000 288894"}
C1r1 {"program":"R2DictRecord","variant":"c1","runs":20,"ops":120000,"floor_ms":27.81,"best_ms":101.75,"median_ms":107.61,"ns_per_op":616.2,"checksum":"60000 18600000"}
C1r1 {"program":"R3Sorting","variant":"c1","runs":20,"ops":120000,"floor_ms":27.3,"best_ms":120.41,"median_ms":124.57,"ns_per_op":775.9,"checksum":"4000 499313"}
C1r1 {"program":"R5EvidenceForwarding","variant":"c1","runs":20,"ops":10000000,"floor_ms":27.58,"best_ms":51.67,"median_ms":55.25,"ns_per_op":2.4,"checksum":"5000000"}
C1r1 {"program":"R6Megamorphic","variant":"c1","runs":20,"ops":3000000,"floor_ms":27.98,"best_ms":95.98,"median_ms":100.46,"ns_per_op":22.7,"checksum":"1352000"}

$ node bench/runtime.mjs --variant=c0 --runs=20 --beni=/tmp/rf/bin/beni --program=R4Equality
C1r1 {"program":"R4Equality","variant":"c0","runs":20,"ops":220200,"floor_ms":27.01,"best_ms":40.8,"median_ms":43.56,"ns_per_op":62.6,"checksum":"400 20000 200 0 6"}

$ node bench/runtime.mjs --variant=c0 --runs=20 --beni=../beni-s1/zig-out/bin/beni
C0r1 {"program":"R1DictString","variant":"c0","runs":20,"ops":120000,"floor_ms":27.95,"best_ms":223.16,"median_ms":229.97,"ns_per_op":1626.8,"checksum":"60000 288894"}
C0r1 {"program":"R2DictRecord","variant":"c0","runs":20,"ops":120000,"floor_ms":27.87,"best_ms":105,"median_ms":109.83,"ns_per_op":642.8,"checksum":"60000 18600000"}
C0r1 {"program":"R3Sorting","variant":"c0","runs":20,"ops":120000,"floor_ms":28.02,"best_ms":120.87,"median_ms":125.54,"ns_per_op":773.8,"checksum":"4000 499313"}
C0r1 {"program":"R4Equality","variant":"c0","runs":20,"ops":220200,"floor_ms":28.13,"best_ms":126.17,"median_ms":130.87,"ns_per_op":445.2,"checksum":"400 20000 200 0 6"}
C0r1 {"program":"R5EvidenceForwarding","variant":"c0","runs":20,"ops":10000000,"floor_ms":27.65,"best_ms":105.19,"median_ms":109.84,"ns_per_op":7.8,"checksum":"5000000"}
C0r1 {"program":"R6Megamorphic","variant":"c0","runs":20,"ops":3000000,"floor_ms":27.99,"best_ms":114.59,"median_ms":117.91,"ns_per_op":28.9,"checksum":"1352000"}

C1r2 {"program":"R1DictString","variant":"c1","runs":20,"ops":120000,"floor_ms":26.87,"best_ms":228.47,"median_ms":233.77,"ns_per_op":1680,"checksum":"60000 288894"}
C1r2 {"program":"R2DictRecord","variant":"c1","runs":20,"ops":120000,"floor_ms":27.71,"best_ms":105.75,"median_ms":112.21,"ns_per_op":650.3,"checksum":"60000 18600000"}
C1r2 {"program":"R3Sorting","variant":"c1","runs":20,"ops":120000,"floor_ms":28.44,"best_ms":123.71,"median_ms":131.28,"ns_per_op":793.9,"checksum":"4000 499313"}
C1r2 {"program":"R5EvidenceForwarding","variant":"c1","runs":20,"ops":10000000,"floor_ms":27.78,"best_ms":53.86,"median_ms":57.46,"ns_per_op":2.6,"checksum":"5000000"}
C1r2 {"program":"R6Megamorphic","variant":"c1","runs":20,"ops":3000000,"floor_ms":27.85,"best_ms":98.49,"median_ms":103.34,"ns_per_op":23.5,"checksum":"1352000"}
C1r2 {"program":"R4Equality","variant":"c0","runs":20,"ops":220200,"floor_ms":28.62,"best_ms":42.38,"median_ms":46.43,"ns_per_op":62.5,"checksum":"400 20000 200 0 6"}

C0r2 {"program":"R1DictString","variant":"c0","runs":20,"ops":120000,"floor_ms":27.35,"best_ms":222.09,"median_ms":241.11,"ns_per_op":1622.8,"checksum":"60000 288894"}
C0r2 {"program":"R2DictRecord","variant":"c0","runs":20,"ops":120000,"floor_ms":28.02,"best_ms":105.81,"median_ms":112.68,"ns_per_op":648.3,"checksum":"60000 18600000"}
C0r2 {"program":"R3Sorting","variant":"c0","runs":20,"ops":120000,"floor_ms":28.41,"best_ms":126.87,"median_ms":130.51,"ns_per_op":820.5,"checksum":"4000 499313"}
C0r2 {"program":"R4Equality","variant":"c0","runs":20,"ops":220200,"floor_ms":27.91,"best_ms":128.95,"median_ms":136.61,"ns_per_op":458.9,"checksum":"400 20000 200 0 6"}
C0r2 {"program":"R5EvidenceForwarding","variant":"c0","runs":20,"ops":10000000,"floor_ms":27.95,"best_ms":109.5,"median_ms":111.38,"ns_per_op":8.2,"checksum":"5000000"}
C0r2 {"program":"R6Megamorphic","variant":"c0","runs":20,"ops":3000000,"floor_ms":28.63,"best_ms":119,"median_ms":124.5,"ns_per_op":30.1,"checksum":"1352000"}
```

**Checksum agreement, stated explicitly because the row is void without it.**
Every program printed the **same checksum in every one of the four runs**, C0 and
C1 alike:

| program | checksum, all four runs |
|---|---|
| R1DictString | `60000 288894` |
| R2DictRecord | `60000 18600000` |
| R3Sorting | `4000 499313` |
| R4Equality | `400 20000 200 0 6` (the fourth field is `nearMisses` and must be 0) |
| **R5EvidenceForwarding** | **`5000000`** — the C0 header's figure, met by the new C1 program |
| **R6Megamorphic** | **`1352000`** — likewise |

| program | C0 ns/op (r1, r2) | C1 ns/op (r1, r2) | C1 ÷ C0 |
|---|---|---|---|
| R1 `Dict` over `String` keys | 1 626.8, 1 622.8 | 1 582.5, 1 680.0 | **1.00×** (noise) |
| R2 `Dict` over a record key | 642.8, 648.3 | 616.2, 650.3 | **0.98×** (noise) |
| R3 `List.sort` ×3 | 773.8, 820.5 | 775.9, 793.9 | **0.98×** (noise) |
| **R4 equality** | **445.2, 458.9** | **62.6, 62.5** | **0.138× — 7.2× FASTER** |
| **R5 evidence forwarding** | **7.8, 8.2** | **2.4, 2.6** | **0.31× — 3.2× faster** |
| **R6 megamorphic** | **28.9, 30.1** | **22.7, 23.5** | **0.78× — 1.28× faster** |

Reading.

**R1–R3 cost nothing measurable, which reproduces S6b's reading on a machine
four times as fast.** Every difference is inside the round-to-round spread of the
same variant (C1's own R1 moves 6.2 % between rounds, C0's R3 6.0 %), and on R1
the sign flips between rounds. An evidence parameter passed as a hidden first
argument and called directly is the same work V8 was already doing when the
comparator was an explicit one — §8.1's prediction, now measured on two machines.

**R4 is the largest effect in the whole spike: 7.2× faster.** 452 ns/op against
62.6. This is the same 1.40× S5 measured at `:699` grown by everything S6 added:
S5's derived `eq` still sent every list and every nested `Maybe (List Int)`
through `Basics.eq`'s structural walk because `List a` had no method yet, and
S6's `pub foreign eq` on `List` closed that. **The structural walk is now
entirely absent from R4's profile** (below). Note that both sides of this row run
the *same source file* — `bench/runtime/c0/R4Equality.beni` — through two
compilers, so it is the cleanest comparison of the six.

**R5 is 3.2× faster, and the header says why it is not purely dispatch.** C0
allocates a closure per `tallyBy` call and pays two `key` calls per comparison;
C1 allocates nothing and calls `compare` directly. Both of those are consequences
of the feature — `where a.compare` is what makes the closure and the key
unnecessary — but a reader who wants "the cost of one indirect call against one
direct call" will not find it here. What R5 does say is that at **2.4 ns/op over
10 M ops** the evidence path has no measurable overhead of its own: 2.4 ns is
about six cycles on this machine for a fold step, a call and a comparison.

**R6 is 1.28× faster, and it is the row report 18 §1.4 asked for.** Three element
types through one call site, and the branch is *faster*, not slower: the
megamorphic evidence call did not defeat V8.

#### `--cpu-prof` on R4 and R6, both sides, fresh directory each

Four runs, each into an empty `--prof-dir`, each producing exactly one
`.cpuprofile`. Self time is summed from `samples` × `timeDeltas`; V8 emits one
node per call site / optimisation tier, so the same function name can appear more
than once and the duplicates are summed by name here (the top-10 tables keep them
as V8 reported them).

**Load before C0 R4:** ` 11:31:37 up 33 min,  3 users,  load average: 0.80, 0.65, 0.57`
**Load before C1 R4:** ` 11:31:40 up 34 min,  3 users,  load average: 0.82, 0.65, 0.57`
**Load before C0 R6:** ` 11:31:42 up 34 min,  3 users,  load average: 0.82, 0.65, 0.57`
**Load before C1 R6:** ` 11:31:45 up 34 min,  3 users,  load average: 0.83, 0.66, 0.57`
**Load after:** ` 11:31:48 up 34 min,  3 users,  load average: 0.83, 0.66, 0.57`

```
{"program":"R4Equality","variant":"c0","runs":20,…,"best_ms":124.05,"ns_per_op":436.8,"checksum":"400 20000 200 0 6","cpu_prof_dir":"…/prof-c0-r4"}
{"program":"R4Equality","variant":"c0","runs":20,…,"best_ms":40,"ns_per_op":55,"checksum":"400 20000 200 0 6","cpu_prof_dir":"…/prof-c1-r4"}   (the BRANCH binary)
{"program":"R6Megamorphic","variant":"c0","runs":20,…,"best_ms":115.72,"ns_per_op":29.2,"checksum":"1352000","cpu_prof_dir":"…/prof-c0-r6"}
{"program":"R6Megamorphic","variant":"c1","runs":20,…,"best_ms":97.96,"ns_per_op":23.4,"checksum":"1352000","cpu_prof_dir":"…/prof-c1-r6"}
```

```
# R4 C0 — CPU.20260918.113140.259247.0.001.cpuprofile   total sampled 113.9 ms
      21.2 ms   18.6%  structuralEq  Basics.foreign.mjs:93
      13.8 ms   12.1%  eq  Basics.foreign.mjs:110
      11.1 ms    9.8%  (garbage collector)
       9.5 ms    8.4%  structuralEq  Basics.foreign.mjs:93
       9.5 ms    8.4%  (anonymous)  R4Equality.mjs:35
       7.8 ms    6.9%  (program)
       7.4 ms    6.5%  structuralEq  Basics.foreign.mjs:93
       7.4 ms    6.5%  foldl  List.foreign.mjs:22
       6.4 ms    5.6%  (anonymous)  R4Equality.mjs:39
       4.2 ms    3.7%  structuralEq  Basics.foreign.mjs:93

# R4 C1 — CPU.20260918.113142.259633.0.001.cpuprofile   total sampled 28.2 ms
       7.8 ms   27.6%  (program)
       2.1 ms    7.5%  eq  List.foreign.mjs:48
       1.2 ms    4.1%  #getOrCreateModuleJobAfterResolve  loader:522
       1.1 ms    3.8%  buildAllowedFlags  per_thread:385
       1.1 ms    3.8%  (anonymous)  performance_entry:1
       1.1 ms    3.8%  compileForInternalLoader  realm:383
       1.1 ms    3.8%  List$map2  List.mjs:15
       1.1 ms    3.8%  List$rangeHelp  List.mjs:9
       1.1 ms    3.8%  compileForInternalLoader  realm:383
       1.1 ms    3.8%  compileSourceTextModule  utils:316

# R6 C0 — CPU.20260918.113145.260023.0.001.cpuprofile   total sampled 106.6 ms
      28.1 ms   26.4%  codePoints  String.foreign.mjs:24
      16.9 ms   15.9%  (garbage collector)
       8.0 ms    7.5%  (program)
       7.4 ms    7.0%  (anonymous)  R6Megamorphic.mjs:25      <- tallyPeople's comparator lambda
       7.3 ms    6.8%  (anonymous)  R6Megamorphic.mjs:23      <- tallyNumbers' comparator lambda
       6.1 ms    5.7%  R6Megamorphic$tally  R6Megamorphic.mjs:17
       5.3 ms    5.0%  (anonymous)  R6Megamorphic.mjs:37      <- the main loop
       4.2 ms    4.0%  (anonymous)  R6Megamorphic.mjs:24      <- tallyTexts' comparator lambda
       2.1 ms    2.0%  codePoints  String.foreign.mjs:24
       2.1 ms    2.0%  codePoints  String.foreign.mjs:24

# R6 C1 — CPU.20260918.113148.260409.0.001.cpuprofile   total sampled 89.9 ms
      16.9 ms   18.8%  codePoints  String.foreign.mjs:24
      10.2 ms   11.4%  R6Megamorphic$tally  R6Megamorphic.mjs:21
       9.5 ms   10.6%  (anonymous)  R6Megamorphic.mjs:31      <- the main loop
       8.1 ms    9.0%  (program)
       5.3 ms    5.9%  (anonymous)  R6Megamorphic.mjs:29      <- tallyPeople's eta-expanded evidence
       4.2 ms    4.7%  (garbage collector)
       3.2 ms    3.5%  (anonymous)  R6Megamorphic.mjs:17      <- building the `people` list
       2.6 ms    2.9%  compare  String.foreign.mjs:45
       2.4 ms    2.6%  foldl  List.foreign.mjs:22
       2.1 ms    2.4%  codePoints  String.foreign.mjs:24
```

The line numbers are read off the emitted JavaScript, built separately with the
same binaries so the profile can be read at all. C1's `R6Megamorphic.mjs`:

```
  5| const R6Megamorphic$compare$prim = ($x, $y) => $x < $y ? "LT" : $x > $y ? "GT" : "EQ";
  6| const R6Megamorphic$compare$r$age$name = ($m$0, $m$1, $x, $y) => { … $m$0($x.age, $y.age) … $m$1($x.name, $y.name) };
 21| const R6Megamorphic$tally = ($m$0, xs$1, mark$2) => List$foldl(xs$1, 0, (x$3, acc$4) => { const $t$1 = $m$0(x$3, mark$2); … });
 25| const R6Megamorphic$level2 = ($m$0, xs$1, mark$2) => R6Megamorphic$tally($m$0, xs$1, mark$2);
 26| const R6Megamorphic$level1 = ($m$0, xs$1, mark$2) => R6Megamorphic$level2($m$0, xs$1, mark$2);
 27| const R6Megamorphic$tallyNumbers = (xs$1, mark$2) => R6Megamorphic$level1(R6Megamorphic$compare$prim, xs$1, mark$2);
 28| const R6Megamorphic$tallyTexts   = (xs$1, mark$2) => R6Megamorphic$level1(String$compare, xs$1, mark$2);
 29| const R6Megamorphic$tallyPeople  = (xs$1, mark$2) => R6Megamorphic$level1(($p$2, $p$3) => R6Megamorphic$compare$r$age$name(R6Megamorphic$compare$prim, String$compare, $p$2, $p$3), xs$1, mark$2);
```

and C0's, for the same three lines:

```
 17| const R6Megamorphic$tally = (xs$1, mark$2, cmp$3) => List$foldl(xs$1, 0, (x$4, acc$5) => { const $t$2 = cmp$3(x$4, mark$2); … });
 23| const R6Megamorphic$tallyNumbers = (xs$1, mark$2, scale$3) => R6Megamorphic$level1(xs$1, mark$2, (a$4, b$5) => R6Megamorphic$flipOrder(Basics$compare(a$4, b$5), scale$3));
 24| const R6Megamorphic$tallyTexts   = (xs$1, mark$2, scale$3) => R6Megamorphic$level1(xs$1, mark$2, (a$4, b$5) => R6Megamorphic$flipOrder(String$compare(a$4, b$5), scale$3));
 25| const R6Megamorphic$tallyPeople  = (xs$1, mark$2, scale$3) => R6Megamorphic$level1(xs$1, mark$2, (a$4, b$5) => { … });
```

Reading the profiles.

**On R4 the structural walk is gone, not reduced.** Summed across all its nodes,
C0 spends **46.3 ms in `structuralEq` plus 13.8 ms in its `eq` wrapper — 60.1 ms
of a 113.9 ms sample, 52.8 %** — and it is the single largest thing in the
program. In C1, `structuralEq` **does not appear at any tier**: the only
comparison frames are `eq List.foreign.mjs:48` at 3.6 ms and the derived
`R4Equality$eq$prim` at 0.6 ms, **4.2 ms of a 28.2 ms sample**. The C1 sample is
so short that 27.6 % of it is `(program)` and another quarter is Node's module
loader — the work finishes in about 12 ms above a 27.9 ms process floor — which
is itself the result: **derived `eq` reduces R4 from a program dominated by one
shared walk to a program dominated by starting Node.** That is the direct answer
to report 18 §1.4's runtime argument.

**On R6, V8 folds the primitive comparison into the call site and keeps the
other two as calls — so the direct call is inlined, partially and where it
matters.** In C0 the three comparator lambdas are three separate frames summing
to **24.2 ms of self time** (8.5 + 8.3 + 7.4 at `.mjs:23/24/25`), plus 6.1 ms in
`tally` itself. In C1 they are gone: `tally` carries **10.2 ms** — up from 6.1,
because it has absorbed work — `R6Megamorphic$compare$prim` shows only **2.1 ms**
although it answers one comparison in three, and `R6Megamorphic$compare$r$age$name`
**does not appear at all**, having been inlined into the one wrapper at `.mjs:29`
(7.5 ms). `String$compare` remains a real frame (5.7 ms) because it is a foreign
function with a loop. Net comparison-side self time is **30.3 ms on C0 against
17.8 ms on C1**, which is the shape of the 1.28× wall-clock win.

**One cost the C1 side does pay, and it is visible here rather than argued.**
`tallyPeople` at `.mjs:29` **allocates a closure per call** — the eta-expansion
§8.1 performs when a piece of evidence itself needs evidence (the record's
derived `compare` takes `$m$0`/`$m$1` for its two fields). So "dispatch removes
the closure" is true of R5 and of two of R6's three types, and **false for a
compound key whose evidence is nested**; that wrapper is 5.9 % of C1's R6 sample.
Report 19 should carry this as a limit of §8.1 rather than as a defect.

**GC halves.** 16.9 ms → 4.2 ms on R6 and 11.1 ms → below the top ten on R4,
which is consistent with three fewer closure allocations per `tally` call and
with `structuralEq` no longer walking the heap.

---

### M8 — ergonomics, both trees counted by the same greps (machine 2)

`plans/static-dispatch-spike.md` §7 M8. These are **counts, not timings**, so the
machine is irrelevant to them; they are under the machine-2 heading only because
that is where this session's appends go. What is new here is that **both columns
are now produced by the same two greps run over both trees** — the S1 C0 column
at `:448` was a hand count taken while `plans/static-dispatch-c1-rewrite.md` was
written, and the S6b C1 column at `:1119` was a grep. One of the two was never
checked against the other's method until now.

**Load:** ` 11:34:35 up 36 min,  3 users,  load average: 0.70, 0.65, 0.58`

```
$ (branch, eb03b77) grep -rnE '\(\w+, ?\w+ -> Order\)' --include='*.beni' core bench/corpus tests/corpus
core/List.beni:433:pub sortWith : List a, (a, a -> Order) -> List a
core/List.beni:477:mergeWith : List a, List a, (a, a -> Order) -> List a
core/List.beni:482:mergeWithHelp : List a, List a, List a, (a, a -> Order) -> List a
bench/corpus/DictExtra.beni:144:pub toSortedList : Dict String v, (v, v -> Order) -> List ( String, v )
                                                                           -> 4 lines

$ (branch) grep -rn 'Dict\.String\|Dict\.Int' --include='*.beni' core bench/corpus tests/corpus | wc -l
0

$ (../beni-s1, c870e9a) grep -rnE '\(\w+, ?\w+ -> Order\)' --include='*.beni' core bench/corpus tests/corpus
core/Dict.beni:41:    = Dict (k, k -> Order) (Tree k v)          <- the TYPE, not a parameter
core/Dict.beni:60:pub empty : (k, k -> Order) -> Dict k v
core/Dict.beni:69:pub singleton : k, v, (k, k -> Order) -> Dict k v
core/Dict.beni:85:getHelp : Tree k v, k, (k, k -> Order) -> Maybe v
core/Dict.beni:165:insertHelp : Tree k v, k, v, (k, k -> Order) -> Tree k v
core/Dict.beni:227:removeHelp : Tree k v, k, (k, k -> Order) -> Tree k v
core/Dict.beni:287:removeHelpEQGT : Tree k v, k, (k, k -> Order) -> Tree k v
core/Dict.beni:594:pub fromList : List ( k, v ), (k, k -> Order) -> Dict k v
core/List.beni:387:pub sortWith : List a, (a, a -> Order) -> List a
core/List.beni:431:mergeWith : List a, List a, (a, a -> Order) -> List a
core/List.beni:436:mergeWithHelp : List a, List a, List a, (a, a -> Order) -> List a
bench/corpus/DictExtra.beni:144:pub toSortedList : Dict String v, (v, v -> Order) -> List ( String, v )
core/Set.beni:36:pub empty : (t, t -> Order) -> Set t
core/Set.beni:44:pub singleton : t, (t, t -> Order) -> Set t
core/Set.beni:117:pub fromList : List t, (t, t -> Order) -> Set t
core/Set.beni:128:pub map : Set a, (b, b -> Order), (a -> b) -> Set b
                                                                           -> 16 lines

$ (../beni-s1) grep -rn 'Dict\.String\|Dict\.Int' --include='*.beni' core bench/corpus tests/corpus | wc -l
30
```

The 30 C0 lines split, by inspection of the listing, into **7 `import` lines, 7
doc-comment mentions and 16 code lines** — and `DictExtra.beni:108` carries two
occurrences on its one line, so 16 lines / **17 use sites**, which is exactly the
hand count at `:468`.

| Measure | C0 (`c870e9a`), counted here | C1 (`eb03b77`), counted here | S1/S6b said | Verdict |
|---|---:|---:|---|---|
| lines matching `(x, x -> Order)` | 16 | **4** | — | — |
| of those, the `Dict` type's own field (not a parameter) | 1 (`Dict.beni:41`) | 0 | — | — |
| **declarations taking a comparator parameter** | **15** | **4** | 15 → 4 | **met, and the C0 15 is now reproduced by grep** |
| `Dict.String` / `Dict.Int` lines, all kinds | 30 | **0** | — | — |
| of those, `import` lines | **7** | **0** | 7 → 0 | met |
| of those, code use sites | **16 lines / 17 occurrences** | **0** | 17 → 0 | met |
| of those, doc-comment mentions | 7 | 0 | not previously counted | — |
| core modules deleted | — | **2** | 2 | met |

Reading: **the two headline ergonomic numbers hold, and the C0 side of the
larger one is no longer a hand count.** 15 comparator parameters on `master`
against 4 on the branch, and the four survivors are the ones rule 2 of the
rewrite plan protects — `List.sortWith`, `List.mergeWith`, `List.mergeWithHelp`
and `DictExtra.toSortedList` — every one of which orders by something that is
*not* the type's own order and so was never the tax. `Dict.String`/`Dict.Int`
vanish completely: 7 imports, 17 use sites and 7 doc mentions on C0, none on C1,
and the two sugar modules are gone with them.

The one number this grep does **not** reproduce is the "17 call sites passing an
ordering function as an argument" of `:461`, which has no single-line spelling to
grep for; it stays a hand count and report 19 should say so.

---

### M9 — the three gates on this machine, at `eb03b77` plus this slice's files

`plans/static-dispatch-spike.md` §7 M9. Run at the end of the session, so the
tree under test is `eb03b77` **plus** everything S8a owns: the six split fields
in `bench/size.mjs`, the assertions for them in `tests/blackbox/build_test.zig`,
and the two new `bench/runtime/c1/` programs. No `src/` file is touched by this
slice and `git status` shows none.

**Load before:** ` 11:35:28 up 37 min,  3 users,  load average: 1.20, 0.79, 0.63`

```
$ zig build          real	0m0.135s   exit 0   (already installed; this is the cache probe)
$ zig build test         real	0m6.665s   user	0m6.203s   sys	0m0.888s   exit 0
$ zig build test-blackbox real	0m46.811s  user	1m38.324s  sys	0m22.140s  exit 0
$ zig build fmt-check    real	0m0.171s   exit 0
```

**Load before the second `test-blackbox`:** ` 11:36:26 up 38 min,  3 users,  load average: 1.92, 1.12, 0.76`

```
$ zig build test-blackbox   (second run)
real	0m49.241s   user	1m42.846s   sys	0m22.510s   exit 0
```

**Load after:** ` 11:37:16 up 39 min,  3 users,  load average: 2.37, 1.40, 0.88`

**All four gates pass, twice for the black-box suite.** The wall times above are
recorded as what the gate costs and **not** as idle-machine measurements: the
suite spawns the installed binary across all 32 threads (`user` 1m38 against
`real` 0m46) and is itself what drives the load average to 2.37 by the end. That
is the one place in this file where a figure is taken above the 2.0 bar, and it
is the suite's own load, not a neighbour's.

What the pass covers that matters to the spike: the `--stage=raw` byte comparison
at `tests/blackbox/blackbox_test.zig:3286-3331` ("the interface record is
byte-identical at `--jobs=1` and `--jobs=8`"), whose assertions include
`where compare term=`, `where eq term=` and `where close term=` — the `where`
blocks of spike §6.5 written **sorted by name text, never by symbol id**, with an
annotated clause and an inferred one both present. That is the determinism
property the whole feature rests on and it is checked on this machine, which has
32 threads against the N100's 4 and so exercises `--jobs=8` on real parallelism
rather than on oversubscription.

Also passing, and new with this slice: the extended
`bench/size.mjs counts a derived-shaped name and not core's hand-written one`
scenario, which now asserts `eq_functions == 9`, `compare_functions == 9`,
`order_tables == 5`, and that the split adds up to `derived_functions` and
`derived_bytes` on both axes.

**A correction to this entry's own header, made here rather than by editing it.**
The machine-2 header above says "Three gates were green on this machine at
`eb03b77` before any row was taken". That was the manager's setup report, taken
on trust when the header was written and not verified by this session. What **is**
verified is the block above: the gates are green at the end of the session on
`eb03b77` plus S8a's files. A reader should treat the header's sentence as
provenance and this block as the evidence.

---

### M7 — compiler cost: the spike's own diff, build time, binary size, test time (machine 2)

`plans/static-dispatch-spike.md` §7 M7. The S1 row at `:500-593` measured the
**harness**; this one measures the **spike**. Its wall times are **N100 figures**
(68.8 s, 13 317 664 B, 11.5 s), so they are not compared against here: a second
throwaway worktree at `c870e9a` was built on this machine instead, and both sides
of every time below are from this session.

#### The diff, gross and net of the S1 harness

```
$ git diff --shortstat master..HEAD
 372 files changed, 29730 insertions(+), 821 deletions(-)
$ git diff --shortstat master..c870e9a      (the S1 harness, already measured at :529)
 19 files changed, 8512 insertions(+), 81 deletions(-)
$ git diff --shortstat c870e9a..HEAD        (the spike itself)
 361 files changed, 21409 insertions(+), 931 deletions(-)
```

By area (`git diff --numstat`, folded):

| area | gross `master..HEAD` | net `c870e9a..HEAD` |
|---|---|---|
| `src/check` | 9 files, +5 311 −70 | 9 files, **+5 273 −58** |
| `src/js` | 2 files, +2 309 −32 | 2 files, **+2 309 −32** |
| `src/bir` | 4 files, +515 −45 | 4 files, +515 −45 |
| `src/parse` | 3 files, +203 −15 | 3 files, +203 −15 |
| `src/resolve` | 2 files, +160 −7 | 2 files, +160 −7 |
| `src/` (other) | 13 files, +525 −25 | 12 files, +510 −21 |
| **`src/` total** | **33 files, +9 023 −194** | **32 files, +8 970 −178** |
| `core/` | 9 files, +280 −254 | 9 files, +280 −254 |
| `tests/corpus` | 295 files, +7 050 −265 | 295 files, +7 050 −265 |
| `tests/blackbox` | 4 files, +1 930 −13 | 4 files, +1 483 −24 |
| `bench/` | 20 files, +3 462 −92 | 12 files, +373 −111 |
| `docs/design` | 3 files, +5 352 −0 | 2 files, +1 056 −96 |
| `plans/` | 7 files, +2 628 −0 | 6 files, +2 192 −0 |
| other | 1 file, +5 −3 | 1 file, +5 −3 |

New files added by the spike (`--diff-filter=A c870e9a..HEAD`): **260 in
`tests/corpus`**, 3 in `bench/`, 5 in `plans/`, 3 in `src/`. The 260 fixtures by
sub-corpus:

```
  12 tests/corpus/bir
  92 tests/corpus/check
  57 tests/corpus/dispatch
  27 tests/corpus/emit
   4 tests/corpus/fmt
  16 tests/corpus/parse
  52 tests/corpus/run
```

Four files are deleted: `core/Dict/Int.beni`, `core/Dict/String.beni`, and
`tests/corpus/check/args/DictEmptyMissingComparator.{beni,diag}`.

Reading the diff: **the feature is 8 970 lines of `src/`, and 5 273 of them —
59 % — are in `src/check`**, with `src/js` a distant second at 2 309. The parser
is +203 lines, which is `where` and the dot-call, and `src/resolve` is +160. And
the spike wrote **260 new fixtures against 32 changed `src/` files**, a ratio of
eight fixtures per source file touched.

#### Build time, binary size, test time — both commits, this machine, this session

Two throwaway worktrees, `../beni-s8` at `eb03b77` and `../beni-s8a` at
`c870e9a`, each with `rm -rf .zig-cache zig-out` before the cold build. **The
global cache `~/.cache/zig` was NOT cleared**, per the standing rule, so these
are cold-local / warm-global numbers exactly as S1's were. Both worktrees are
removed at the end of the session.

```
=== ../beni-s8a at c870e9a (the C0 proxy) ===
### uptime before the cold build
 11:41:37 up 43 min,  3 users,  load average: 0.81, 1.26, 0.95
$ time zig build -Doptimize=ReleaseFast
real	0m46.921s   user	0m46.965s   sys	0m1.279s
$ stat -c '%s' zig-out/bin/beni
13253088
### uptime before zig build test
 11:42:24 up 44 min,  3 users,  load average: 0.97, 1.24, 0.96
$ time zig build test
real	0m8.553s    user	0m11.211s   sys	0m2.456s
### uptime before the warm repeats
 11:42:32 up 44 min,  3 users,  load average: 1.20, 1.28, 0.98
$ time zig build test        (warm)
real	0m6.973s
$ time zig build -Doptimize=ReleaseFast   (warm)
real	0m0.127s
$ time zig build test-blackbox
real	0m31.366s   user	1m21.708s   sys	0m21.082s
### uptime after
 11:43:11 up 45 min,  3 users,  load average: 1.90, 1.45, 1.05

=== ../beni-s8 at eb03b77 (the spike) ===
### uptime before the cold build
 11:38:30 up 40 min,  3 users,  load average: 1.06, 1.21, 0.85
$ time zig build -Doptimize=ReleaseFast
real	1m4.136s    user	1m3.964s    sys	0m1.349s
$ stat -c '%s' zig-out/bin/beni
16751800
### uptime before zig build test
 11:39:34 up 41 min,  3 users,  load average: 1.38, 1.28, 0.90
$ time zig build test
real	0m8.794s    user	0m11.405s   sys	0m2.634s
### uptime before the warm repeats
 11:39:42 up 42 min,  3 users,  load average: 1.55, 1.32, 0.92
$ time zig build test        (warm)
real	0m7.000s
$ time zig build -Doptimize=ReleaseFast   (warm)
real	0m0.127s
$ time zig build test-blackbox
real	0m50.534s   user	1m49.557s   sys	0m25.546s
### uptime after
 11:40:40 up 43 min,  3 users,  load average: 2.03, 1.51, 1.01
```

| | C0 (`c870e9a`) | C1 (`eb03b77`) | C1 ÷ C0 |
|---|---:|---:|---:|
| cold-local ReleaseFast build | **46.9 s** | **64.1 s** | **1.37×** |
| installed ReleaseFast binary | **13 253 088 B** | **16 751 800 B** | **1.264×** (+3 498 712 B) |
| `zig build test`, first run | 8.55 s | 8.79 s | 1.03× |
| `zig build test`, warm repeat | 6.97 s | 7.00 s | 1.00× |
| warm ReleaseFast rebuild | 0.127 s | 0.127 s | 1.00× |
| `zig build test-blackbox` | **31.4 s** | **50.5 s** | **1.61×** |

Reading.

**Compiling the compiler costs 37 % more and the binary is 26 % larger.** 46.9 s
→ 64.1 s and 13.25 MB → 16.75 MB, for 8 970 lines of `src/` of which 59 % is in
the checker. The 0.127 s warm rebuild on both sides confirms both cold numbers
were real compilation and not cache probing.

**The unit tests do not move; the black-box suite costs 61 %.** `zig build test`
is 8.55 s against 8.79 s — inside the noise, as it should be, since the in-source
tests are a supplement and the spike added few. `test-blackbox` goes 31.4 s →
50.5 s, and that is **the 260 new fixtures being compiled and run**, not the
compiler being slower: it is the cost of the asset, and it is the number a
`master` adoption inherits every time the gates run.

**Two small binary-size observations, recorded and not explained.** The
ReleaseFast binary built in `../beni-s8` is **16 751 800 B** where the same
commit built in the main checkout with `--prefix /tmp/rf` is **16 751 760 B**
(40 bytes), and `../beni-s8a`'s is **13 253 088 B** where `../beni-s1`'s is
**13 253 080 B** (8 bytes). In both cases the only difference is the length of
the source directory path, which Zig embeds; that is the obvious candidate and it
was not verified, so it is stated as an observation. Both differences are far
below the 3.5 MB the feature costs and neither disturbs any figure above.

---

### Summary — S8a on machine 2

| Row | Headline (machine 2; C0 sides re-taken here) |
|---|---|
| M2 | **The branch's worst row.** B is ~cubic: check 50.8 / 382 / 3 114 ms and peak RSS 53 / 403 / 3 307 MB at n = 100 / 200 / 400, against A's 4.96 / 14.6 / 47.5 ms and 6 / 15 / 51 MB. **At n = 1 000 B reaches 29.2 GiB and is killed after 46 s**, where A finishes in 0.25 s / 261 MB. `obligations` are now `n(n+1)/2 + 49` where S3 recorded them linear. The `where` printer has **no cap**: 200 clauses / 6 409 chars, no `<error>`, against C0's 65-field / ~1 760-char truncation |
| M3 | **Byte-identical to the N100 on all 32 rows.** Annotated: 0 everywhere, both compilers, both corpora. Unannotated E3: `core` 8/94 → 50/90 (6.5×), `bench/corpus` 5/52 → 29/68 (4.4×). E3poly already 100 % on C0 and still 100 % |
| M4 | Floor 65 214 → 68 791 raw (+5.5 %); split **eq 1 041 B / 8 fns, compare 1 874 B / 9 fns, order 244 B / 5 tables** — compare is **1.60× eq per function**; `bench/corpus` +11.8 % with 197.6 B per derived function; over the 35 programs both sides share, net raw +15.9 % with a **median program change of 0 bytes**. Every byte identical to the N100's |
| M5 | ns/op C0 → C1: R1 1 626.8 → 1 582.5, R2 642.8 → 616.2, R3 773.8 → 775.9 (all noise); **R4 452 → 62.6 (7.2× faster)**, **R5 8.0 → 2.5 (3.2×)**, **R6 29.5 → 23.1 (1.28×)**. All six checksums agree across both variants and both rounds. Profiles: `structuralEq` is **60.1 ms of 113.9 on C0 R4 and absent from C1**; on R6 the three comparator closures (24.2 ms) collapse into `tally` (6.1 → 10.2 ms) plus one eta-expansion wrapper |
| M7 | Spike diff net of the harness **361 files, +21 409 −931**; `src/` **+8 970 −178**, 59 % of it `src/check`; **260 new fixtures**. Cold ReleaseFast **46.9 s → 64.1 s (1.37×)**, binary **13 253 088 → 16 751 800 B (1.264×)**, `zig build test` 8.55 → 8.79 s (flat), `test-blackbox` **31.4 → 50.5 s (1.61×)** |
| M8 | 15 comparator parameters → **4**, now counted by the same grep on both trees; `Dict.String`/`Dict.Int` 7 imports + 17 use sites + 7 doc mentions → **0**; 2 core modules deleted |
| M9 | `zig build`, `test`, `test-blackbox` (×2) and `fmt-check` all **exit 0** at `eb03b77` plus S8a's files |

Not taken on this machine, deliberately: **M1a and M1b**, which stay N100-only
(`:1199` and `:1318`), and **M6**, which is S8b's and reads goldens rather than
running an instrument.

Re-run after the M7 worktrees were removed, to close the session:
`zig build && zig build test && zig build test-blackbox && zig build fmt-check`
then `zig build test-blackbox` again — **all exit 0**
(` 11:44:11 up 46 min,  3 users,  load average: 0.70, 1.18, 0.98` before,
` 11:45:56 up 48 min,  3 users,  load average: 2.18, 1.59, 1.15` after; the load
at the end is the black-box suite's own).

---
