# What static dispatch costs, measured: the spike's results

**Commissioned by** [`research/18-static-dispatch-revisited.md`](18-static-dispatch-revisited.md),
which re-tested [`fast-compiler.md`](../fast-compiler.md) §3.1 and found three of its four stated
reasons wrong while leaving two things unmeasured: whether the runtime trade on a JavaScript target
really inverts (18 §1.4, §1.5), and what an accumulating method constraint does to beni's *inferred*
interface (18 §2.3). Report 18 §7 listed both under "could not determine". This report is the
measurement.

**The spike is a branch that never merges.** `spike/static-dispatch` builds Roc's shipped semantics —
dot-call, `where` clauses, `eq` and `compare` as well-known methods with structural derivation, and
return-type dispatch — on beni's own checker and backend, rewrites `core/`, `bench/corpus` and
`tests/corpus` to use it, and measures the result against `master`. It is evidence, not a proposal.

**Deliverables.**

| | |
|---|---|
| the branch | `spike/static-dispatch`, cut from `master` at `f466aac`; 365 files, +23 383 −936 against the harness commit (`results:3337`) |
| the normative spec | [`static-dispatch-spike.md`](../static-dispatch-spike.md) — §1–§11 plus **81** Appendix A rows, each with the alternative it rejected |
| the raw numbers | [`plans/static-dispatch-spike-results.md`](../../../plans/static-dispatch-spike-results.md), append-only, every instrument line verbatim |
| this report | every figure in it cites a line of that file as `results:N` |

**Citations.** `results:N` is a line of `plans/static-dispatch-spike-results.md`. `§N` with no
document is a section of this report; `spec §N` and `A.N` are
`docs/design/static-dispatch-spike.md`. A figure with no `results:` citation is not a measurement,
and §16 lists what could not be measured at all.

---

## 0. Findings

- **The interface churn report 18 §2.3 predicted is real, and it is confined to unannotated `pub`
  declarations.** Every `annotated` row of the churn instrument is **0 interface changes** — E1, E2,
  E3 and E3poly alike, on both corpora, on both compilers, on both machines (`results:1925-1942`).
  Unannotated, adding one `==` to a parameter moves the interface **8/94 → 50/90 on `core`** and
  **5/52 → 29/68 on `bench/corpus`**: 6.5× and 4.4× worse (`results:1959-1961`). The
  bare-type-variable row the objection is actually about — E3poly — was **already 100 % on C0**
  (4/4, 14/14) and stays 100 % (4/4, 12/12) (`results:1966-1967`). An annotation removes the cost
  entirely; nothing else does. §4.
- **Report 18 §1.4's runtime inversion holds, and by more than it forecast.** C1 is **7.2× faster on
  equality** (445–459 → 62.6 ns/op), **3.2× faster on evidence forwarding** (7.8–8.2 → 2.4–2.6) and
  **1.28× faster with three types at one call site** (28.9–30.1 → 22.7–23.5); `Dict` and `sort` do not move outside
  round-to-round noise (`results:2304-2311`). The shared structural walk is **not reduced but
  absent** from C1's R4 profile — 60.1 ms of a 113.9 ms C0 sample, zero frames in C1
  (`results:2440-2450`). The megamorphic evidence call did not defeat V8. One closure survives, where
  a piece of evidence itself needs evidence (`results:2464-2469`). §6.
- **The cost that is real is output size, and every figure is an upper bound because there is no
  DCE.** The floor an empty program ships grows **65 214 → 68 791 raw bytes, +5.5 %**, of which
  3 159 bytes are derived functions nothing calls (`results:2112-2121`); `bench/corpus` grows
  **+11.8 %** at **197.6 bytes per derived function** (`results:2127-2129`); over the 35 programs on
  both sides net output grows 15.9 % while the **median program moves 0 bytes**
  (`results:2131-2132`) — a program pays per type it declares, not per line it writes. Removing one
  function-typed field from one core type added **six uncalled functions to every program in the
  language** (`results:1020-1027`). §5.
- **`compare` costs 1.60× what `eq` costs, and the two must never be summed.** Derived `eq` is
  1 041 bytes over 8 functions (130.1 each); derived `compare` is 1 874 over 9 (208.2 each); the
  `$$order` tables are 244 over 5 (`results:2119-2121`, `results:2186-2194`). `compare` is **not**
  one of the six methods Roc derives, and making it well-known is a *separate* decision from
  dispatch (A.38, spec §11). Half the size cost belongs to that decision and not to this one.
- **Check time: 20.3 % on code that never uses the feature, and 7.8 % more for writing it.** On the
  100 159-line generated corpus, `check` is 71.88/72.23 ms on `master` against 86.57/86.79 on the
  branch — **1.203×**, with an ABBA spread of 0.5 % inside each binary — and `emit` is **1.480×** for
  25.8 % more output (`results:1274-1276`, `results:1286`). Writing the same program in the dot-call
  style costs a further **7.8 % of `check`** and 8.5 % of wall time (`results:1371-1373`). Most of
  what the feature costs is paid by code that never uses it.
- **On an unannotated accumulating chain the branch is quadratic in time and in memory, and that
  quadratic is the program's own constraint count.** `constraints_promoted` reads **n(n+1)/2 to the
  unit** at every n — 55, 5 050, 20 100, 80 200, 500 500, 2 001 000, 4 501 500 — and the fitted
  growth exponent settles on **2.0** in both time and space from n = 200 up (`results:3129-3149`).
  At the five n where both compilers are clean, B ÷ A is **1.17× to 1.82×**; at n = 2 000 and 3 000
  the branch checks cleanly where `master`'s checker refuses the chain outright
  (`results:3110-3122`). §3.
- **The ergonomic tax report 18 §5 counted is gone.** 17 ordering arguments → **0**; 15 declarations
  taking a comparator parameter → **4**, all four ordering by something that is not the type's own
  order; `Dict.String`/`Dict.Int` 7 imports + 17 use sites + 7 doc mentions → **0**, with both sugar
  modules deleted (`results:2529-2547`). §9.
- **The table design held; the obligation bookkeeping needed five passes, and the gates caught none
  of them.** Every blocking defect after the spec review was an implementation defect in
  `Solve.zig`'s bookkeeping, and the recurring failure mode was **exit-0 wrongness** — a program that
  compiled, ran and printed the wrong answer, which a fully green suite coexisted with every
  time. §11.

---

## 1. Method

### 1.1 Two machines, and which rows are on which

Every row in the results file up to `results:1422` was taken on one **Intel N100** (4 cores /
4 threads, 6 MiB L3, single memory channel, 16 GB RAM, Linux 7.2.2), and every row from
`results:1423` down on **machine 2**, an **AMD Ryzen 9 5950X** (16 cores / 32 threads, 31 GiB RAM,
Linux 6.12.110 NixOS). Both used Zig 0.16.0 and Node v24.19.0 from the flake's dev shell.

| Row | Machine | Note |
|---|---|---|
| M1a — the feature's cost to code that never uses it | **N100 only** (`results:1199-1316`) | not re-taken; `results:1434` says so explicitly |
| M1b — the cost of writing the feature | **N100 only** (`results:1318-1420`) | likewise |
| M2 — constraint accumulation | **machine 2**, both sides (`results:2788-3189`) | the S8a′ re-take after A.81; supersedes `results:1466-1735` |
| M3 — interface churn | **machine 2**, both sides (`results:1814-1975`) | byte-identical to the N100 run (`results:1946-1952`) |
| M4 — output size | **machine 2**, both sides (`results:1978-2226`) | byte-identical to the N100 run (`results:2178-2184`) |
| M5 — runtime of the emitted JS | **machine 2**, both sides (`results:2229-2474`) | the N100's S5 and S6b rows are cited as earlier readings only |
| M6 — diagnostics | machine-independent | goldens under `tests/corpus/`, plus two reproductions (§1.6) |
| M7 — compiler cost | **machine 2**, both sides (`results:2614-2759`) | the S1 N100 wall times are not compared against |
| M8 — ergonomics | machine-independent counts (`results:2478-2551`) | greps over two trees |
| M9 — the gates | **machine 2** (`results:2555-2610`, `results:3293-3318`) | pass/fail only |

**No table in this report puts an N100 figure beside a machine-2 figure as a comparison.** Where both
exist — M5's R4 and R1–R3, M2 — the machine-2 row is the headline and the N100 row is named in prose
as the earlier reading. M3 and M4 were *checked* to be machine-independent rather than assumed
(`results:1946-1952`, `results:2178-2184`).

### 1.2 The two binaries, and why the C0 proxy is valid

**A, the C0 proxy**, is `../beni-s1` at `c870e9a`, built `-Doptimize=ReleaseFast`. `c870e9a` is
`master` at `f466aac` plus the measurement harness — 19 files, +8 512 −81, of which the whole `src/`
half is **+53 −16**: five `= 0` counter fields on `Solve.Counters`, the matching `Profile.Counter`
names, and a reflective `Counters.add` (`results:509-548`). Nothing in constrain, solve,
generalisation, lowering or emission is touched, so A's *behaviour* is `master`'s. **B, the branch**,
is built `--prefix /tmp/rf` and never installed into the branch's own `zig-out`: 16 751 760 bytes at
`eb03b77`, 16 752 152 at `e4c56d6` after A.81 (`results:1453-1455`, `results:2804-2811`). A is
13 253 080 bytes on machine 2 against 13 317 664 on the N100 — same commit, same Zig, a difference
recorded and **not** explained (`results:1445-1452`).

### 1.3 Interleaving, and why

Every before/after pair is taken **ABBA in one machine state**, because the alternative is on the
record: the S5 entry measured R6 at 58.2 ns/op in one session and 41.8 in another on an unchanged
program (`results:718-721`), and S6b's "check costs 8 %" compared a B run at 03:39 with an A run from
the previous afternoon — interleaved, it reads **20.3 %** (`results:1290-1298`). `uptime` is recorded
verbatim before every instrument and no figure is recorded above a 1-minute load average of 2.0; the
one exception is the black-box gate, which generates the load it is measured under (`results:2581-2586`).

### 1.4 C0 against C1, and exactly what is comparable

**C0** is the current sources; **C1** is the same programs with the comparator argument removed,
`Dict.String`/`Dict.Int` deleted, and both corpora rewritten by hand. Four limits, each carried in
the table where the number lives:

1. **M1a compares two cores, not one program through two checkers.** A checks 635 modules and B 633,
   and B's `core/Dict.beni` carries seventeen `where` clauses A's does not (`results:1220-1225`). The
   generator header is byte-identical on both sides (`results:1216-1217`), so the *user* code is the
   same 624 files and 1 835 619 bytes.
2. **M2 carries the same caveat** — 12 modules against 10 — and adds a second: past ≈64 links
   `master`'s checker stops building the chain and emits one `UNKNOWN FIELD`, so its ~250 ms at
   n = 2 000 and n = 3 000 is the cost of a refusal (`results:2886-2894`). Those rows are marked `†`.
3. **M4 measures two different program sets** — 61 against 35, the 26 extras being the spike's own
   fixtures, several of which would not compile on C0 (`results:2148-2163`). Only three comparisons
   are honest and only those are made: the floor, `bench/corpus`, and the per-program net over the 35
   that exist on both sides.
4. **M1b's `--dispatch` generator has moved** since S1 (1 887 474 bytes against 1 885 570), so the
   acceptance row is re-taken as **one directory, two compilers** (`results:1390-1419`).

### 1.5 Corrections to earlier entries, carried here so no superseded figure is quoted

The results file is append-only, so a correction is new text further down. Five apply:

| Corrected | Where | What to use |
|---|---|---|
| S6b's header claimed M5's C0 side was S1's ReleaseFast binary; it was a Debug rebuild of the same commit | `results:1154-1195` | harmless — M5 times the emitted JavaScript under Node and the compiler runs outside the timed loop; A's ReleaseFast install reproduced 13 317 664 bytes exactly |
| S6b's "check costs 8 % on the plain tree" | `results:1290-1298` | **20.3 %**, interleaved; 87.63 against 71.77 is +22.1 %, an arithmetic slip on its own numbers |
| S6b's hand-taken `eq`/`compare`/`order` byte split (1 050 / 1 889 / 244) sums to 3 183 against a `derived_bytes` of 3 159 | `results:2196-2205` | **1 041 / 1 874 / 244**, taken inside the same statement walk that produces `derived_bytes` and asserted by `build_test` to add up. The counts (8, 9, 5) were right and are unchanged |
| S8a read M2 as a regression between S3 and `eb03b77` — "obligations were linear and are quadratic now" | `results:2823-2853` | **wrong**. n(n+1)/2 obligations is the correct A.57 count on this input and matches `constraints_promoted`, which has read n(n+1)/2 since S3. S3's `obligations: 1014` is a different, under-registering checker, not a baseline |
| S8a presented a 29.2 GiB out-of-memory kill as the feature's cost | `results:2855-2865` | it was **a bookkeeping defect** (A.81). The same tree now checks in 441 ms at 411 MB. What static dispatch costs on this input is the quadratic of §3 |

A.81 changed `Solve.attachConstraint` only, and the claim that nothing else moves was **checked
rather than argued**: M4 re-ran byte-identical across all 63 lines (`results:3199-3218`), M3
re-ran identical in every cell of both tables (`results:3220-3265`), M5's five C1 checksums were
re-confirmed (`results:3267-3291`), and on the plain 100 159-line corpus the only counter that moved
is `constraints_merged` **4 → 3** (`results:3372-3380`). M1a and M1b were taken on the pre-fix
binary and were **not** re-taken; that one counter is the whole footprint of the fix on ordinary
code.

### 1.6 The disclaimer

Two machines, one project, one corpus. The *signs, ratios and orderings* are the findings; absolute
timings are indicative, and the two machines differ by roughly a factor of four on the same work.
Two items are not instrument readings at all: §7.5 and §7.6 are reproductions run for this report
against the installed **Debug** binary (they are diagnostics, so the optimisation level is not in
them). Everything else in §7 is quoted from a golden with its path.

---

## 2. M1a and M1b — what the feature costs (N100)

### 2.1 M1a: code that never uses it

**Question.** What does a compiler that *has* static dispatch cost a program that never writes a
dot-call or a `where` clause?

**Instrument.** `zig build bench -- --generate=100000 --iterations=5`, best of 5 after a warm-up,
`--jobs=1`, interleaved ABBA inside 20 seconds (`results:1204-1266`).

| phase | A (`c870e9a`) ms | B (`99e0a05`) ms | B ÷ A |
|---|---:|---:|---:|
| lex / parse / lower / resolve | 9.9, 6.7, 9.5, 5.62 | 9.4, 6.8, 9.4, 5.52 | 0.98–1.02× |
| **check** | **71.88, 72.23** | **86.57, 86.79** | **1.203×** |
| **emit** | **33.36, 33.27** | **49.32, 49.30** | **1.480×** |
| **total** | **139.1, 138.7** | **169.2, 169.3** | **1.218×** |

`results:1268-1276`. Both runs are clean, both read the same 1 835 619 bytes, and the ABBA spread
inside each binary is 0.5 % — a twelfth of the gap.


| counter | A | B |
|---|---:|---:|
| modules / unifications / generalisations / instantiations | 635 / 231 352 / 101 320 / 55 228 | 633 / 228 143 / 104 086 / 52 346 |
| obligations | 3 151 | 3 486 |
| constraints created / merged / deferred / discharged / promoted | 0 / 0 / 0 / 0 / 0 | 281 / 4 / 476 / 2 710 / 1 |
| `js_bytes` | 3 075 595 | 3 870 047 (**+25.8 %**) |

`results:1278-1286`. On the final tree `constraints_merged` reads **3** rather than 4
(`results:3372`); no other counter moves.

**Reading.** The 20 % is **not** extra unification — B does 3 209 *fewer* unifications and 2 882
fewer instantiations than A. It is obligation bookkeeping on top: 281 constraints created, 476
deferred and 2 710 discharged on a corpus that never writes a `where` clause, which is `==` and `<`
lowering to method calls (spec §3.1) and then resolving against a concrete receiver. The 48 % on
`emit` and 25.8 % more output are eager derivation with no DCE, the same number §5 measures from the
other side. The front end is flat to within noise — the half of M1a report 18 §2.1 asks about. What
the row does *not* say is that this is one program through two checkers (§1.4 item 1).
### 2.2 M1b: what writing it costs, one compiler, both sides

**Instrument.** The same command against the plain and the `--dispatch` generated trees, PDDP inside
eight seconds, on B alone (`results:1326-1363`).

| phase | plain (ms) | `--dispatch` (ms) | ratio |
|---|---:|---:|---:|
| lex / parse / lower / resolve | 9.7, 6.7, 9.5, 5.26 | 9.8, 7.3, 10.0, 5.71 | 1.04–1.08× |
| **check** | **86.52, 86.22** | **93.07, 93.12** | **1.078×** |
| emit | 49.52, 49.31 | 55.47, 55.42 | 1.122× |
| **total** | **169.4, 168.8** | **183.5, 183.6** | **1.085×** |

`results:1365-1373`. The dispatch tree is the same 624 modules in the dot-call style: +168 lines,
+49 951 bytes, +14 666 tokens, +10 320 AST nodes, +7 498 BIR instructions (`results:1376-1377`). Per
byte the front end is flat — the 4–8 % on `lex`/`parse`/`lower` is the extra 2.7 % of source, not a
slower pass. Constraint counters, plain → dispatch: created 281 → 347, merged 4 → 80, deferred
476 → 1 203, discharged 2 710 → 5 134, promoted 1 → 77 (`results:1381-1382`).

**Reading.** Writing 100 327 lines in the dot-call style costs **7.8 % of `check`** and 8.5 % of wall
time over writing the same program without it — smaller than M1a's 20.3 %. Most of what the feature
costs is paid by code that never uses it.

### 2.3 The acceptance row — one corpus, two compilers

B generates the `--dispatch` tree; that exact directory is then handed to A.

```
$ ../beni-s1/zig-out/bin/beni check --jobs=1 .zig-cache/bench-gen-dispatch --diagnostics=json
exit 1; 596 429 bytes of JSON on stderr; 1683 diagnostics
  type_mismatch 1425, wrong_type_arity 129, unexpected_token 129

$ /tmp/rf/bin/beni check --jobs=1 .zig-cache/bench-gen-dispatch --diagnostics=json
exit 0; 0 bytes on stderr; 0 diagnostics
```

`results:1400-1409`. The 129 `unexpected_token` diagnostics are the `where` clauses and the 1 425
`type_mismatch` are the dot-calls landing on `master`'s row-polymorphic field access. This is the
spike's acceptance test with both halves over the same input.

---

## 3. M2 — constraint accumulation in unannotated code (machine 2)

**Question.** Report 18 §2.1 and §2.2 say an unannotated function's inferred type becomes a trace of
its call sequence, and that Roc accepted "constraints accumulating in un-annotated programs" as a
risk it was not worried about. What does that cost on a real checker?

**Instrument.** `bench/gen.zig --pathological=constraint-chain=n` generates n unannotated `pub`
functions, each adding one method call on its polymorphic parameter and calling the previous one;
best of 5, `--jobs=1`, ABBA per n. The generated program is byte-identical on both sides at every n,
asserted by `cmp` (`results:2879-2884`).

| n | A `check` ms (r1, r2) | B `check` ms (r1, r2) | B ÷ A | A peak RSS | B peak RSS | `constraints_promoted` |
|---:|---:|---:|---:|---:|---:|---:|
| 10 | 1.59, 1.62 | 1.98, 1.86 | 1.17× | 3.7 MB | 3.9 MB | 55 |
| 100 | 4.84, 4.80 | 6.60, 6.24 | 1.30× | 6.5 MB | 7.7 MB | 5 050 |
| 200 | 14.44, 15.49 | 18.40, 19.75 | 1.27× | 14.7 MB | 19.5 MB | 20 100 |
| 400 | 46.65, 47.06 | 72.19, 73.43 | 1.55× | 50.3 MB | 68.4 MB | 80 200 |
| 1 000 | 239.71, 240.04 | 441.02, 437.38 | 1.82× | 262 MB | 411 MB | 500 500 |
| 2 000 | 245.40 †, 250.00 † | 1 912.46, 1 928.59 | 7.79 †× | 257 MB † | 1 667 MB | 2 001 000 |
| 3 000 | 248.72 †, 256.34 † | 4 442.51, 4 477.26 | 17.86 †× | 258 MB † | 3 754 MB | 4 501 500 |

`results:3110-3118`, times from `results:2902-3038` and peak RSS from `results:3054-3094`.

† **A emits `diagnostics: 1` and exits 1 at n = 2 000 and n = 3 000.** `master`'s checker refuses the
chain past ≈64 links — the `UNKNOWN FIELD` message is quoted verbatim at `results:152-167` — so its
~250 ms and ~257 MB there are the cost of a refusal, not of checking the chain. **The ratio in those
two rows is B working against A not working, and is not a slowdown figure** (`results:3120-3122`).

**Growth.** Fitting `log(t₂/t₁) / log(n₂/n₁)` on best-of-2 over the six intervals 10→100→200→400→
1 000→2 000→3 000 gives B time exponents **0.53, 1.56, 1.97, 1.97, 2.13, 2.08** and B peak-RSS
exponents **0.30, 1.34, 1.81, 1.96, 2.02, 2.00** (`results:3129-3136`). Both series settle on **2.0**
from n = 200 up; the low exponents at the small end are the fixed floor (checking `core` costs
~1.5 ms and ~3.7 MB whatever n is). A pays its own super-linear price on the same input — 1.59, 1.69,
1.79 in time and 1.18, 1.78, 1.80 in space, driven by `generalisations` going 17 617 → 1 509 367 as
the accumulated open record is re-walked (`results:3156-3160`). **So the comparison is quadratic
against roughly n^1.8, not quadratic against linear.**

**What the quadratic is.** `constraints_promoted` reads **n(n+1)/2 to the unit** at every n and
`obligations` reads n(n+1)/2 + 49, the 49 being `core`'s own (`results:3147-3151`). Link k of an
unannotated chain genuinely accumulates k constraints because nothing pins them, so the chain carries
n(n+1)/2 of them and A.57 asks for exactly that count. **This is the feature's cost on this input,
not a defect.**

**The history, told straight.** S8a measured this row as **cubic** and could not check n = 1 000 at
all: the process reached **29.2 GiB on a 31 GiB machine** and was killed after 46 seconds with no
diagnostic (`results:1664`, `results:1617-1634`). The cause is A.81: `Solve.attachConstraint` rebuilt
an entire constraint set — copying it, joining a site list with itself, redirecting every index to the
copy of itself — to fold a constraint onto the set it was **already in** (`results:2813-2821`). The
fix is a three-comparison guard, +22 lines of `src/check/Solve.zig` (`results:3346-3347`). Post-fix,
**the exponent dropped by exactly one in both time and space**: speed-ups at the points S8a reached
are 7.9× / 20.8× / 43.1× in time and 6.9× / 20.7× / 48.4× in peak RSS (`results:3138-3145`). The
counter that localises it is `constraints_merged` — it counts set rebuilds and read n(n+1)/2 + n − 1
where the honest number is n − 1, which is what every post-fix block reads. `obligations`,
`constraints_created`, `constraints_deferred`, `constraints_discharged` and `constraints_promoted`
are unchanged to the unit at every n S8a recorded (`results:3165-3172`), which is the assertion that
no obligation was dropped to buy the speed.

**Reading.** The branch checks a 3 000-link unannotated chain that `master` refuses outright, and
pays n² obligations and 3.6 GB of resident memory for it. It does **not** say ordinary code is
quadratic: the 100 159-line corpus creates 281 constraints, defers 476 and promotes 1 across 633
modules (`results:3372`), and `bench/corpus` and `core` check in milliseconds. It says the shape
report 18 §2.3 is about is where the bookkeeping goes non-linear, and that at n = 1 000 — the last n
at which both compilers are clean — B holds 410 MB against A's 262 MB.

### 3.1 The `where` printer has no cap, where C0's record printer does

S1 recorded two pre-existing `master` printer limits (`results:177-216`) and both reproduce exactly
on machine 2 (`results:1745-1761`): `Render.writeRecord` flattens at most 64 extension links, so from
f65 on every rendered type is the same **65-field closed** record at 1 756–1 763 characters with the
`| r` tail dropped; and `Schemes.Writer.max_depth = 512` writes `<error>` into an interface entry
that `beni check` exits 0 on. The branch's `where` printer has neither cap (`results:1772-1793`):

| | C0 (A) | C1 (B) |
|---|---|---|
| f65 rendered | 65 fields / 1 756 chars | 65 clauses / 2 020 chars |
| f100 rendered | **65** fields / 1 757 chars (truncated) | 100 clauses / 3 109 chars |
| f200 rendered | — | **200 clauses / 6 409 chars** |
| f200 in the interface | — | **6 415 chars** |
| `<error>` in either dump | yes, past ~64 links | **none** (`grep -c` = 0) |

Growth is a dead-straight **31 characters per clause**. The structural reason is that a `where` list
is **flat** where a record extension is a **chain**, so neither guard is reached
(`results:1795-1802`).

**This is better and worse at once.** Better: the branch's interface is honest — it prints the
constraint a caller actually has to satisfy, where C0 silently truncates and then writes `<error>`
into an interface `check` accepts. Worse: there is now **no bound at all** on what one unannotated
declaration can write into an interface, so a 6.4 kB scheme is a real interface entry, and the churn
§4 measures is churn over text of that size (`results:1804-1810`).

---

## 4. M3 — interface churn (machine 2)

**Question.** Report 18 §2.3's load-bearing claim: under static dispatch an unannotated `pub`
function's inferred scheme carries its accumulated constraints, that scheme *is* beni's interface,
and so adding one method call re-checks every importer.

**Instrument.** `bench/churn.sh` applies four edit classes to every `pub` declaration and byte-diffs
`dump --stage=raw` before and after, in each of two variants (annotation kept / stripped). E1 changes
a literal (the control), E2 duplicates an operator application already used on a parameter, E3 adds a
new `==` on any parameter, and **E3poly** restricts E3 to a parameter typed with a bare type variable
— the row the objection is about. Both sides re-taken here, ABBA per corpus; A runs from `../beni-s1`
against the C0 sources, because C1 rewrote both corpora (`results:1816-1830`).

| corpus | edit | variant | A (C0) | B (C1) |
|---|---|---|---:|---:|
| `bench/corpus` | E1, E2 | either variant | 0/20, 0/19, 0/1, 0/1 | identical |
| | E3 | annotated | 0/52 | 0/70 |
| | **E3** | **unannotated** | **5/52 (9.6 %)** | **29/68 (42.6 %)** |
| | E3poly | annotated | 0/0 | 0/0 |
| | **E3poly** | **unannotated** | **4/4 (100 %)** | **4/4 (100 %)** |
| `core` | E1, E2 | either variant | 0/15, 0/15, 0/7, 0/7 | identical |
| | E3 | annotated | 0/88 | 0/74 |
| | **E3** | **unannotated** | **8/94 (8.5 %)** | **50/90 (55.6 %)** |
| | E3poly | annotated | 0/0 | 0/0 |
| | **E3poly** | **unannotated** | **14/14 (100 %)** | **12/12 (100 %)** |

`results:1925-1942`. Caveat, in the table's own terms: **only the `changed/accepted` ratios are
comparable between the two runs, not the raw counts.** C1's `core` has 138 declarations against C0's
144, because the two sugar modules are deleted with six `pub` values between them and
`Dict.comparatorOf` with them (`results:1962-1964`).

**Reading.**

- **Every `annotated` row is 0 on both compilers and both corpora**, E3 and E3poly included. An
  annotation is the whole interface — spec §6.4's promotion table says an annotated declaration never
  promotes — so a body edit cannot move it, and static dispatch has not changed that. This is the
  direct answer to the objection.
- **The cost is confined to unannotated `pub` declarations, where it is 4.4× and 6.5× worse.** On C0
  a new `==` on a parameter adds an `equatable` flag the interface may or may not already carry; on
  C1 it adds a `where` clause the interface always prints.
- **E3poly was already 100 % on C0 and stays 100 %.** What made the C0 `annotated` E3poly rows read
  0/0 is that every such edit was *rejected*: on `master`, adding `==` to a bare type variable does
  not type-check at all (`results:284-289`) — itself the ergonomic finding, and why C1's
  `bench/corpus` E3 `annotated` accepts 70 edits against C0's 52 (`results:1970-1974`).
- **Every number here is byte-identical to the N100's** (`results:1946-1952`) and identical again
  when re-run after A.81 (`results:3262-3265`): `changed/accepted` is a property of the compiler and
  the corpus, not of the machine.

---

## 5. M4 — output size (machine 2)

**Question.** Report 18 §1.5's "grows per type × derived method" row asked for a number and could not
supply one.

**Instrument.** `bench/size.mjs` builds every `tests/corpus/run/` fixture and `bench/corpus` with
`beni build` and reports raw, gzip and brotli bytes. Both sides taken by **one script** — the
branch's, which differs from S1's only by this slice's six split fields, since
`git diff c870e9a HEAD -- bench/size.mjs` is empty (`results:1980-1994`). ABBA; both repeats were
byte-identical. **Caveat governing every figure below: there is no DCE, so every number is an upper
bound** (spec §11).

### 5.1 The floor — what an empty program ships

| | A (C0) | B (C1) | Δ |
|---|---:|---:|---:|
| files | 21 | 19 | −2 (`Dict.String`, `Dict.Int` deleted) |
| raw | 65 214 | 68 791 | **+3 577, +5.5 %** |
| gzip | 15 410 | 16 399 | +989, +6.4 % |
| brotli | 12 932 | 13 838 | +906, +7.0 % |
| `derived_bytes` / `derived_functions` | 0 / 0 | **3 159 / 22** | — |
| `eq_bytes` / `eq_functions` | 0 / 0 | **1 041 / 8** | 130.1 B per function |
| `compare_bytes` / `compare_functions` | 0 / 0 | **1 874 / 9** | 208.2 B per function |
| `order_bytes` / `order_tables` | 0 / 0 | **244 / 5** | 48.8 B per table |

`results:2112-2121`. **Three numbers, never a sum**, per spec §11 and A.38: `compare` is not one of
the six methods Roc derives, so a single summed figure would charge static dispatch for the cost of a
separate decision. A derived `compare` costs **1.60×** a derived `eq` — spec §9's
lexicographic-with-early-return against a chain of `&&` — and the `$order` table has no `eq`
counterpart at all. Over all 61 programs the per-function figures hold to within a byte (eq 129.2,
compare 210.2, order 50.7), so this is a property of the emitted shape, not of core's particular
types (`results:2186-2194`).

**4.6 % of the floor is derived code nothing calls.** The rest of the +3 577 is `core/List.js`
gaining two loops and `core/Dict.beni` gaining seventeen `where` clauses, against the two deleted
modules. Six of the twenty-two floor functions are new with the comparator rewrite and **nothing
calls any of them** — `Dict$Dict$$eq`, `Dict$Dict$$compare`, `Set$Set$$eq`, `Set$Set$$compare`,
`Set$eq$unit`, `Set$compare$unit` — because `Dict k v` held a function-typed field before the rewrite
and spec §6.3.1's function-payload exclusion gave it neither method, with `Set` inheriting the
exclusion (`results:1020-1027`). **Removing one function-typed field from one core type added six
functions to every program in the language** — eager derivation meeting no DCE, priced.

### 5.2 `bench/corpus` and the 35 programs that exist on both sides

| | A (C0) | B (C1) | Δ |
|---|---:|---:|---:|
| `bench/corpus` raw | 109 053 | 121 965 | +11.8 % |
| `bench/corpus` net raw | 43 839 | 53 174 | +21.3 % |
| `bench/corpus` derived | 0 / 0 | 11 659 B / 59 fns | **197.6 B per derived function** |
| `bench/corpus` split | — | eq 24 / 4 121 · compare 21 / 6 561 · order 14 / 977 | — |
| net raw over the **35 programs on both sides** | **78 620** | **91 141** | **+12 521, +15.9 %** |
| median per-program net-raw change | — | — | **0 bytes** |

`results:2123-2132`. The change is concentrated in a handful — `bench/corpus` +9 335, `Adt` +1 112,
`LibraryArgumentOrder` +852 (which also gained three lines of source), `Patterns` +444,
`SaturatedCalls` +353, `Sorting` +220 — while `StringOps` and `Tuples` move by **0** and `Recursion`
is 68 bytes *smaller* (`results:2137-2145`). **A program pays per type it declares, not per line it
writes.**

The 26 programs B measures with no C0 counterpart are listed at `results:2155-2163` so that no total
mixes them into a before/after. B's own total over 61 programs is 216 942 bytes of derived code
across 1 497 functions (`results:2173`) — mostly never called, and the upper bound the elimination
pass the backend's build order owes would work against.

---

## 6. M5 — runtime of the emitted JavaScript (machine 2)

**Question.** Report 18 §1.4 and §1.5 argued from what the code does — a worklist, an `Object.keys`
allocation per node, a megamorphic property access — that beni's dispatch-free route is *slower* than
a direct call, and §7 recorded that nobody had measured it.

**Instrument.** `bench/runtime.mjs` builds each program with `beni build` and runs it under Node, 20
runs, best / median / ns per op net of a measured process floor. `git diff c870e9a HEAD --
bench/runtime.mjs` and `-- bench/runtime/c0/` are both empty, so the harness and the six C0 programs
are the files S1 measured (`results:2231-2235`). One session, interleaved C1 → C0 → C1 → C0, inside
80 seconds. R4's C1 side is the branch binary against `--variant=c0`: R4 is a program about `==`, C1
changes nothing in its source, so both sides run **the same source file** through two compilers
(`results:2244-2246`).

**Checksums, stated because the row is void without them.** Every program printed the same checksum
in all four runs, C0 and C1 alike — `60000 288894`, `60000 18600000`, `4000 499313`,
`400 20000 200 0 6` (whose fourth field is R4's `nearMisses` counter and must be 0), **`5000000`**
and **`1352000`**, the last two being the C0 headers the newly-written C1 programs had to meet
(`results:2291-2302`), re-confirmed after A.81 (`results:3287-3291`).

| program | C0 ns/op (r1, r2) | C1 ns/op (r1, r2) | C1 ÷ C0 |
|---|---|---|---|
| R1 `Dict` over `String` keys | 1 626.8, 1 622.8 | 1 582.5, 1 680.0 | **1.00×** (noise) |
| R2 `Dict` over a record key | 642.8, 648.3 | 616.2, 650.3 | **0.98×** (noise) |
| R3 `List.sort` ×3 | 773.8, 820.5 | 775.9, 793.9 | **0.98×** (noise) |
| **R4 equality** | **445.2, 458.9** | **62.6, 62.5** | **0.138× — 7.2× faster** |
| **R5 evidence forwarding** | **7.8, 8.2** | **2.4, 2.6** | **0.31× — 3.2× faster** |
| **R6 megamorphic** | **28.9, 30.1** | **22.7, 23.5** | **0.78× — 1.28× faster** |

`results:2304-2311`.

**R1–R3 cost nothing measurable.** Every difference is inside the round-to-round spread of the same
variant (C1's own R1 moves 6.2 % between rounds, C0's R3 6.0 %) and the sign flips between rounds on
R1. An evidence parameter passed as a hidden first argument and called directly is the same work V8
was already doing when the comparator was explicit. The N100 read the same three programs flat at S6b
(`results:1089-1093`), so this reproduces on a machine four times as fast.

**R2 carries one deliberate difference, and it is not dispatch's.** `c1/R2DictRecord.beni` reads the
point's fields through a `weight : Point -> Int` helper where the C0 program writes `(p.x + p.y)`
inline, **because the inline form does not compile** (§13). So R2's C1 side pays one extra direct
call per insert — 60 000 of them — and still lands inside the noise (`results:1103-1109`).

**R4 is the largest effect in the spike.** The earlier N100 reading at S5 was 1.40× faster
(737.3 → 525.2 ns/op, `results:697-702`) and was recorded as a lower bound, because `List a` had no
method of its own yet and every list and every nested `Maybe (List Int)` still went through
`Basics.eq`'s walk. S6 gave `List` its own `eq`, and the machine-2 measurement reads **7.2×**.

**R5 is 3.2× faster, and the header says why it is not purely dispatch.** C0 allocates a closure per
`tallyBy` call and pays two `key` calls per comparison; C1 allocates nothing and calls `compare`
directly. Both are consequences of the feature, but a reader who wants "one indirect call against one
direct call" will not find it here. What R5 does say is that at **2.4 ns/op over 10 M ops** — about
six cycles for a fold step, a call and a comparison — the evidence path has no measurable overhead of
its own (`results:2331-2338`).

### 6.1 The profiles — does V8 inline the direct call?

Four `--cpu-prof` runs, each into a fresh empty directory; self time summed from `samples` ×
`timeDeltas` (`results:2344-2413`). **On R4 the structural walk is gone, not reduced.** Summed across all its nodes, C0 spends **46.3 ms
in `structuralEq` plus 13.8 ms in its `eq` wrapper — 60.1 ms of a 113.9 ms sample, 52.8 %** — the
single largest thing in the program. In C1 `structuralEq` **does not appear at any tier**: the only
comparison frames are `eq List.foreign.mjs:48` at 3.6 ms and the derived `R4Equality$eq$prim` at
0.6 ms, **4.2 ms of a 28.2 ms sample**. The C1 sample is so short that 27.6 % of it is `(program)`
and another quarter is Node's module loader (`results:2440-2450`). **Derived `eq` reduces R4 from a
program dominated by one shared walk to a program dominated by starting Node.** That is the direct
answer to report 18 §1.4, and the earlier N100 C0 profile read the same shape from the other side —
43.9 % `structuralEq` plus 5.5 % `eq` (`results:431-433`).

**On R6, V8 folds the primitive comparison into the call site and keeps the other two as calls.** In
C0 the three comparator lambdas are three frames summing to **24.2 ms** of self time, plus 6.1 ms in
`tally`. In C1 they are gone: `tally` carries **10.2 ms**, having absorbed work;
`R6Megamorphic$compare$prim` shows 2.1 ms although it answers one comparison in three; the record's
derived `compare` does not appear at all, inlined into one wrapper; and `String$compare` stays a real
frame at 5.7 ms, being a foreign function with a loop. Net comparison-side self time is **30.3 ms on
C0 against 17.8 ms on C1** (`results:2452-2462`). **The megamorphic evidence call did not defeat
V8** — the row report 18 §1.4 asked for, answered the opposite way to the fear.

**One cost C1 does pay, visible rather than argued.** `tallyPeople` **allocates a closure per call** —
the eta-expansion spec §8.1 performs when a piece of evidence itself needs evidence. So "dispatch
removes the closure" is true of R5 and of two of R6's three types and **false for a compound key
whose evidence is nested**; that wrapper is 5.9 % of C1's R6 sample (`results:2464-2469`). A limit of
spec §8.1, not a defect.

**GC halves**, 16.9 → 4.2 ms on R6 and out of the top ten on R4, consistent with three fewer closure
allocations per call and with `structuralEq` no longer walking the heap (`results:2472-2474`).

---

## 7. M6 — diagnostic quality

**Question.** Report 18 §2.4: twenty months into Roc's static dispatch, a missing constraint on a
*caller* is still reported at a line inside the *callee* — "a game of spot-the-difference". Does beni
do better? Every message below is quoted from a golden under `tests/corpus/` with its path, except
§7.5 and §7.6, which are reproductions (§1.6). **No claim here is based on running Roc**; the
comparison is against Roc's *described* behaviour in reports 18 and 20 only.

### 7.1 The headline — `missing_where_constraint` on a caller (spec §10.4)

`tests/corpus/check/bad/MissingWhereCaller/` is two modules. `Lib.beni` declares the constrained
callee — `pub top : a, a -> a where a.pick : a, a -> a` — and `Main.beni` calls it from an annotated
function with no constraint, at line 12. `_expected.diag`, **primary span `Main.beni:12:5-12:12`**:

```
MISSING CONSTRAINT
I need `a.pick` here, and the annotation does not allow it.

This call needs `a` to have a method `pick`:

    pick : a, a -> a

but `a` is any type at all. `pick` is required by `top`.

Hint: add it to the annotation:
    where a.pick : a, a -> a
```

**beni points at the call the author wrote and names the callee in the prose.** Roc's reports, as
report 20 §7.2 establishes from its source, highlight `constraint.fn_var`'s region — for a
`where`-clause constraint the *callee's* annotation node, which survives being copied to a caller.
beni records the same two instructions Roc does; spec §10's preamble makes the caller primary and the
callee a follow-on note, and the fixture **asserts the order, not merely the set**. The cheapest win
over Roc in the whole spike is one ordering rule. `MissingWhereConstraint.diag` (same module) and
`NotEquatableRigid.diag` (`==` on a rigid) use the same template with "the annotation says `a` is any
type at all".

### 7.2 `unknown_method` and `private_method` (spec §10.1, §10.2)

`check/bad/UnknownMethod.diag` names the rule that failed rather than the symbol that is missing:
*"`Shape` has no method called `volume`. I resolve `x.volume` in the module that declares `x`'s type.
That module is `UnknownMethod`, and it has no `pub` value called `volume`."* — then a did-you-mean
over that module's `pub` names. `UnknownMethodThroughGeneric/_expected.diag` is the same code with the
requirement arriving by instantiation: the span is in `Main.beni` and the message gains *"`draw` was
required by `render`'s annotation."* `PrivateMethod/_expected.diag`: *"`Token.bump` is not `pub`.
`Token` declares `bump`, but without `pub` it is private to that module … Hint: add `pub` to `bump`
in `Token`."*

The second arm of §10.1 is the receiver nothing ever determines —
`check/bad/WhereNonWellKnownAtLiteral.diag`:

```
UNKNOWN METHOD
I cannot tell which type `describe` is being asked of here.
…
    `number` — a literal I never had to choose between `Int` and `Float` for

`eq` and `compare` I could still answer, because they mean the same thing
at every type. `describe` I cannot — it is declared for some type, and there
is no type here to look it up in.

Hint: annotate the value at the type you mean.
```

The fixture's header records what this replaced: the check used to exit 0 with the evidence slot
empty and the emitted call one argument short, caught only by an `internal` compiler-bug report about
a program whose only fault is never saying which type it means. S7's `TypeDispatchUnpinnedResult.diag`
reaches the same arm through return-type dispatch, substituting *"a type variable no use of this
value determines"*.

### 7.3 `no_methods_on_shape` (spec §10.3) — five goldens, four bodies

A tuple (`MethodOnTuple.diag`): *"A tuple has no methods, so I cannot resolve `.fst` here:
`( Int, Int )`. Methods are resolved in the module that declares a type, and this shape is declared
nowhere."* A function (`CompareOnFunction.diag`): the same, plus *"Hint: functions have no ordering.
Pass an ordering function instead."* A type that *holds* a function
(`CompareOnTypeHoldingFunction.diag`, `IndirectFunctionPayload.diag`, `WhereCallOnUnorderableType.diag`):
*"This type has no `compare`: `Handler`. There is a function inside it, and functions have no ordering
— so the compiler cannot write one for the type that holds them either. Hint: order by something you
can compare — a name, an id — that sits next to the function."* And a type holding an unordered
`foreign type` (`core/CompareOnWrappedForeign.diag`,
`core/CompareOnForeignWithUnrelatedCompare.diag`, `core/PrivateForeignCompare/_expected.diag`):
*"Something it holds has no ordering of its own — a function, or a `foreign type` whose module
declares no `compare` — and I derive an ordering only over parts that already have one. Hint: a
`foreign type` is ordered by a `pub compare` in the module that declares it."* Two of these fixtures
emit **two** diagnostics, the `compare` one and a `not_equatable` for `==` on the same type — the
pre-existing code spec §3.4 keeps because it is the better message.

### 7.4 The rest of the catalogue, one line each

| Code | Golden | The distinctive sentence |
|---|---|---|
| `method_constraint_mismatch` (spec §10.5) | `check/bad/MethodConstraintMismatch.diag` | *"`render` is used at two different types here … One variable carries one constraint per method name, so these have to agree. Hint: give the two uses different type variables, or annotate."* — the rank-2 shape from Roc's August-2026 thread, refused by design (spec §6.1 invariant 3) |
| the A.49 boundary | `check/bad/LetConstrainedTwice.diag` | a plain `type_mismatch`, then a hint of its own: *"`show` is a `let` binding whose type needs a `render` method, and such a binding is used at ONE type inside the definition that holds it … Move `show` out to a top-level declaration and annotate it"* |
| `where_variable_unbound`, both triggers (spec §10.6) | `parse/bad/WhereVariableUnbound.diag`, `WhereConstraintFreeVariable.diag` | (a) *"`a` is not a type variable of this annotation. A `where` clause constrains a variable of the type above it, and `a` does not appear in `Int -> String`."* (b) *"`x` appears in a constraint but not in the type … A constraint may only mention variables the annotation quantifies, because those are the ones a caller gets to choose"* — fires once per free variable |
| the comma rule (spec §2.3, A.41) | `parse/bad/WhereConstraintBracketedComma.diag` | one `where_variable_unbound` for `b`, then `expected_token`: *"I was parsing a type and ran into `.c`, but I was expecting `->` here."* |
| `duplicate_where_constraint` (spec §10.7) | `parse/bad/DuplicateWhereConstraint.diag` | *"`a.eq` is constrained twice; the first constraint is on line 5."* |
| `type_dispatch_needs_annotation` (spec §10.8), both triggers | `check/bad/TypeDispatchUnannotated.diag`, S7's `TypeDispatchMethodNotInWhere.diag` | *"`a` is a type, not a value, and I need to be told what `a.decode` is … That needs a `where` clause naming it: `where a.decode : a -> Result String a2`"* |
| `constrained_constant` (spec §10.10) | `check/bad/ConstrainedConstant.diag` | *"`equals` takes no arguments but needs `a.eq`. A value that needs a method has to receive it, which would make `equals` a function of one hidden argument, and that is not what its type says."* |
| the module-rule clash (spec §11) | `check/bad/ModuleRuleClash.diag` | *"a module's `pub` values are ONE namespace — so `eq` is the method of every type `ModuleRuleClash` declares. Hint: … Move one of the types into a module of its own, or give the two methods different names."* |
| argument region | `check/bad/MethodCallArgumentRegion.diag` | a wrong argument to a method call reports at the *argument*, with the existing `type_mismatch` prose and numeric hint |

One cosmetic defect, recorded and not fixed: spec §10.8's message renders its argument types as
unresolved flexes, because the rigid arm reports before the same constraint's arguments are solved.

### 7.5 `ambiguous_method_receiver` (spec §10.9) — reproduced, because there is no fixture

This code has no corpus fixture; it is asserted by `tests/blackbox/blackbox_test.zig:3151`.
Reproducing that test's program against the installed Debug binary:

```
$ beni check --explain Main.beni
-- CONSTRAINT IN AN INFERRED INTERFACE --------------------------- Main.beni:1:5

`bigger` is `pub`, has no annotation, and its inferred type carries 1 method constraint(s):

    a, a -> Bool where a.compare : a, a -> Order

Editing the body can change this, and changing it re-checks every importer.

Hint: an annotation pins it.

1|pub bigger a b =
      ^^^^^^
exit=0
```

The program's second declaration, `annotated : Int, Int -> Bool`, is **not** reported: it pins its
type, carries no constraint, and is the hint the message gives. The flag is off by default, the
severity is `warning` and the exit code stays 0, so `--explain` can never turn a passing build into a
failing one (A.10). **This is §4's churn made visible to the author at the moment they create it** —
the one piece of tooling the spike built specifically for report 18's objection.

### 7.6 The worst message the spike produces

Spec §11's deferred-receiver row says `x.m a` with `x`'s type still unknown is a method constraint and
never a field call, so a lambda parameter that later turns out to be a record is
`no_methods_on_shape` with a hint to write the field call. There is no golden; reproduced with
`later (\r -> r.f 1) { f = \x -> x + 1 }` over an unannotated `later g v = g v`:

```
A record has no methods, so I cannot resolve `.f` here:

    { f : number -> number }
…
Hint: write `(x.f) a` to call the field `f`.
```

**It does carry the hint**, spelled with a literal `x` rather than the receiver's name. The larger
limit is that the *same* message is what an author gets for A.28's open-record refusal, where they
never wrote the method name at all: spec §11's own example,
`List.foldl points Dict.empty (\p d -> Dict.insert d p (p.x + p.y))`, gives *"A record has no methods,
so I cannot resolve `.compare` here: `{ x : Int, y : Int }` … Hint: write `(x.compare) a` to call the
field `compare`."* The author wrote no `.compare` and has no field to call; the requirement came from
`Dict.insert`'s `where` clause. This is what `bench/runtime/c1/R2DictRecord.beni` had to be rewritten
around (§6), and §13 carries it.

---

## 8. M7 — compiler cost (machine 2)

**The diff.** `git diff --shortstat c870e9a..HEAD` — the spike net of the S1 harness — is **365 files,
+23 383 −936** (`results:3337`), against the harness's own 19 files, +8 512 −81 (`results:529`).

| area | net `c870e9a..HEAD` |
|---|---|
| `src/check` | 9 files, **+5 273 −58** |
| `src/js` · `src/bir` · `src/parse` · `src/resolve` · other `src/` | +2 309 −32 · +515 −45 · +203 −15 · +160 −7 · +510 −21 |
| **`src/` total** | **32 files, +8 992 −178** |
| `core/` · `bench/` · `docs/design` | +280 −254 · +373 −111 · +1 056 −96 |
| `tests/corpus` · `tests/blackbox` | 295 files, +7 050 −265 · 4 files, +1 483 −24 |

`results:2635-2650` with A.81's +22 in `src/check/Solve.zig` folded in (`results:3339-3347`).

**The feature is ~9 000 lines of `src/`, and 59 % of them are in `src/check`.** The parser is +203
lines — `where` and the dot-call — and `src/resolve` is +160. The spike wrote **260 new fixtures**
against 32 changed `src/` files, eight per source file touched: 92 under `check`, 57 under
`dispatch`, 52 under `run`, 27 under `emit`, 16 under `parse`, 12 under `bir`, 4 under `fmt`
(`results:2652-2664`). Four files are deleted: the two `core/Dict/` sugar modules and the fixture
pair that asserted `Dict.empty` needed a comparator.

**Build and test.** Two throwaway worktrees, `rm -rf .zig-cache zig-out` before each cold build, the
global Zig cache deliberately not cleared, so these are cold-local / warm-global figures both sides:

| | C0 (`c870e9a`) | C1 (`eb03b77`) | C1 ÷ C0 |
|---|---:|---:|---:|
| cold-local ReleaseFast build | **46.9 s** | **64.1 s** | **1.37×** |
| installed ReleaseFast binary | **13 253 088 B** | **16 751 800 B** | **1.264×** (+3 498 712 B) |
| `zig build test`, first run / warm | 8.55 s / 6.97 s | 8.79 s / 7.00 s | 1.03× / 1.00× |
| warm ReleaseFast rebuild | 0.127 s | 0.127 s | 1.00× |
| `zig build test-blackbox` | **31.4 s** | **50.5 s** | **1.61×** |

`results:2729-2736`. A.81 moves the binary by **+392 bytes**, leaving the 1.264× unchanged to three
decimal places (`results:3343-3345`).

**Reading.** Compiling the compiler costs 37 % more and the binary is 26 % larger; the 0.127 s warm
rebuild on both sides confirms both cold numbers were real compilation. The unit tests do not move —
in-source tests are a supplement here and the spike added few — while `test-blackbox` costs 61 %
more, and **that is the 260 new fixtures being compiled and run, not the compiler being slower**. It
is the cost of the asset, and a `master` adoption inherits it every time the gates run.

---

## 9. M8 — ergonomics

Counts, not timings, so the machine is irrelevant. New here: **both columns are produced by the same
two greps over both trees**, where the C0 column had been a hand count (`results:2480-2486`).

| Measure | C0 (`c870e9a`) | C1 (`eb03b77`) | Verdict |
|---|---:|---:|---|
| lines matching `(x, x -> Order)` (one of the C0 16 is the `Dict` type's own field, not a parameter) | 16 | **4** | — |
| **declarations taking a comparator parameter** | **15** | **4** | met, and the C0 15 is now reproduced by grep |
| `Dict.String` / `Dict.Int` lines, all kinds | 30 | **0** | — |
| of those, `import` lines · code use sites · doc mentions | **7** · **16 lines / 17 occurrences** · 7 | **0** · **0** · 0 | met (doc mentions not previously counted) |
| core modules deleted | — | **2** | met |
| **call sites passing an ordering function as an argument** | **17** | **0** | met — **hand count**, see below |

`results:2529-2538`. The four survivors — `List.sortWith`, `List.mergeWith`, `List.mergeWithHelp`,
`DictExtra.toSortedList` — each order by something that is **not** the type's own order, so none was
ever the tax (`results:2540-2547`).

**One number is not reproduced by grep and this report says so.** "17 call sites passing an ordering
function as an argument" has no single-line spelling to match; it remains the hand count of
`results:461` and `results:2549-2551`.

**The module rule.** 21 modules across the three trees declare two or more nominal types, unchanged
from C0 to C1 — no module gained or lost a type. **One collides today** (`core/Basics.beni`, where
seven types want `eq` and seven want `compare`), plus one latent (`core/Dict.beni`, both extra types
private), and **six would collide under the style the rule rewards** — the two core modules plus
`ExprParser`, `JsonCodecs`, `PrettyPrinter` and `Router` in `bench/corpus` (`results:480-496`). The
`Basics` collision is bought off by spec §3.2's well-known table and §5.1's move of `String` and
`Char` into their own modules. **That the workaround was needed at all, in the first module of the
standard library, is itself the finding.**

---

## 10. M9 — determinism and the gates

All four gates exit 0 on machine 2, with `test-blackbox` run twice, at `eb03b77` plus S8a's files
(`results:2563-2576`) and again at `e4c56d6` after A.81 (`results:3293-3311`). What matters here is the `--stage=raw` byte comparison at
`tests/blackbox/blackbox_test.zig:3286-3331` — "the interface record is byte-identical at `--jobs=1`
and `--jobs=8`" — whose assertions include `where compare term=`, `where eq term=` and
`where close term=`: spec §6.5's `where` blocks written **sorted by name text, never by symbol id**,
with an annotated clause and an inferred one both present (`results:2588-2596`). Machine 2 has 32
threads against the N100's 4, so `--jobs=8` is real parallelism rather than oversubscription. A
second scenario pins the dispatch table itself across the same four runs (A.29). New with the
measurement slice: `build_test` asserts `eq_functions == 9`, `compare_functions == 9`,
`order_tables == 5` and that the split adds up on both axes (`results:2598-2602`); new with A.81, an
`abuse_test.zig` scenario reading all six dispatch counters out of `--self-profile` at 64 and 128
links (`results:3315-3318`).

**Determinism held throughout.** No figure in this report depended on thread timing, and the two
outputs the feature adds — the `where` suffix in an interface and the dispatch table — are both under
byte-comparison at two job counts.

---

## 11. What the review found

Every slice was implemented by one agent and reviewed read-only by another. The blocking and
near-blocking findings, from `plans/diary.md` 2026-09-17 13:57 onward:

| # | Defect | Slice | Found by | Design or implementation |
|---|---|---|---|---|
| 1 | the dispatch table's own worked example miscompiled; caller/callee evidence order could silently disagree; no way to request a derived function from a using module | S0 (the spec) | read-only review of the **document** | **design**, and caught before any code |
| 2 | `type_dispatch` compiled to `undefined` with exit 0; `basicsValue` emitted `undefined` when core lacked a value; operator sections lost their name and pre-solve type in diagnostics | S2 | review, building programs outside the corpus | implementation |
| 3 | `attachConstraint` rebuilt the whole constraint set on every attach — quadratic in the set | S3 | **measurement** (M2) | implementation |
| 4–5 | the per-instantiation obligation duplicated Rule U3's deferral, so every failing `where`-clause diagnostic printed twice and one success path passed the same evidence twice; and `declaresCompare` ignored `pub` and was module-scoped, so an unrelated `pub compare : Tag, Tag -> Order` made `Wraps Handle`'s `<` compile to an unsound call | S3 fix pass | review | implementation (A.54) |
| 6 | a `number` literal against an *imported* constrained callee got no evidence site; the emitted call was one argument short and Node threw at load | S3/S4 | the other slice running the first's table | implementation |
| 7 | the A.55 branch sent every `foreign type` — `List` included — to `Basics.eq`, turning a correct refusal into a silent `False` | S3/S4 | the other slice | implementation, **exit-0 wrongness** |
| 8 | the evidence wall did not check arity: too-long and too-short evidence lists both emitted wrong-arity calls that ran; four silent `undefined` returns | S4 | review | implementation |
| 9 | three exit-0 miscompiles — a constrained value-position call of wrong arity, a private `eq` suppressing the derived row while the importer still named it, and `Shapes$Box$eq` colliding with module `Shapes.Box`'s own `eq` | S5 | review | implementation (A.61–A.63) |
| 10 | `Basics`' own `pub foreign eq`/`pub compare` excluded every type it declares from eager derivation, so `Order` and `Never` had no rows while uses referenced them | S5 | review | **design-adjacent**: spec §3.3's step order, fixed by consulting the table before the exclusion |
| 11 | a latent `Bool`-into-`Order` fallback in value position; every evidence slot of one instruction numbered `1`, masked by a stable sort | S6a | review | implementation |
| 12 | breadth-first site numbering: `pair [[1]] [[2]]` under `where a.eq, b.eq` emitted a four-deep evidence tree for `a` and none for `b`, exit 0 | S6a → S6b | the S6a evidence cursor | implementation, **exit-0 wrongness** |
| 13–14 | a rebuilt constraint set stranded its inputs as live obligations, so one instruction's slot 0 was written twice; and a joined constraint instantiated its callee's `where` clause for the first instruction only | S6b | `tests/corpus/run/Dictionaries.beni` failing to build, and the corpus rewrite | implementation (A.75, A.76) |
| 15 | `attachConstraint` rebuilt an entire set to fold a constraint onto the set it was **already in** — cubic time and memory, a 29.2 GiB kill at n = 1 000 | pre-dates S6b; found at S8a | **measurement** (M2) | implementation (A.81) |

**Four generalisations.**

1. **Every blocking defect after the spec review was an implementation defect in `Solve.zig`'s
   constraint bookkeeping, and the table design held.** Rows 3, 4, 5, 12, 13, 14 and 15 are all one
   thing — how a constraint set is rebuilt, indexed, numbered and counted. Nothing in spec §6.1's
   representation or spec §7.1's table shape had to change.
2. **The obligation plumbing needed five passes, not four.** S3's fix pass, S5, S6a's numbering,
   S6b's A.75/A.76, and S8-fix's A.81 (`plans/diary.md`, `## 2026-09-18 12:16 CEST — S8-fix: the
   constraint chain was cubic, and the bisect lied`). Three of the five were found by a reviewer, one
   by a sibling slice, and **two by a measurement** — rows 3 and 15, both of which the gates were
   green over.
3. **The recurring failure mode is exit-0 wrongness, which the gates do not catch.** Rows 2, 7, 9 and
   12 all compiled, ran, and printed a wrong answer with a fully green
   `zig build test && zig build test-blackbox` — CLAUDE.md rule 3 restated by measurement. Row 15 is
   the sharpest case: **every corpus fixture and all three gates were green over a cubic checker**,
   because no fixture is long enough for a quadratic factor to show.
4. **"Answered exactly once" needs an identity, and an index into an append-only list is not one.**
   Constraint sets are half-open ranges of an append-only list, so every rebuild changes the index,
   and everything keyed on it — obligations, `resolved_methods`, `deferred` — must follow a redirect
   (A.75). The same lesson appears in the `evidence_index` key (row 11) and in the pre-order site
   numbering (row 12).

**One methodological finding worth carrying beyond the spike.** `git bisect` called S6b's parent
"good", but that commit already reads 21.1 / 132.0 / 934.7 ms at n = 100 / 200 / 400 — cubic too;
S6b's A.75 redirect map multiplied the constant by ~3.3× and did not introduce the exponent
(`results:2836-2853`). **A bisect over a continuous quantity finds where that quantity crossed the
threshold you bisected on, not where its growth rate changed.** For a complexity defect, fit the
curve on both sides of the "good" commit first. The same error produced the superseded "obligations
went linear → quadratic" reading (§1.5), by treating two counters from two commits as one series.

---

## 12. Decisions a `master` adoption would have to ratify

Language-and-interface decisions the spike took to get itself built. Each was reversible by editing
the spec and none is after adoption; each row names the alternative the spec records.

| # | Decision | Where | The alternative |
|---|---|---|---|
| 1 | **The module rule**: a method of `T` is any `pub` value of the module declaring `T` — which forces `String` and `Char` out of `core/Basics.beni` | spec §1.2, §5.1, A.6 | Roc's own answer since October 2025: a per-type method block. Lookup is keyed on `(TypeId, name)`, so this is a front-end change. §9 measures how often the clash bites: 1 module today, 6 under the style the rule rewards |
| 2 | **Derivation is eager**: every declared nominal type ships an `eq` and a `compare`, called or not | A.23, spec §8.5 | derive on demand in the *consuming* module — impossible for a `pub opaque type`, and duplicated per consumer otherwise — or a second checking pass, which is a scheduling change. Under no DCE this is what §5's numbers cost |
| 3 | **`compare` is well-known at all** | plan §0, A.38, spec §3.2 | **this is not a static-dispatch decision.** Roc derives six methods and `compare` is not among them; making it well-known is the reversal of `fast-compiler.md` §3.1 point 3, which report 18 §5 said should be argued on its own merits. It is 1 874 of the floor's 3 159 derived bytes |
| 4 | **Code-point order for `String` and `Char` `<`**, at the cost of a call rather than a JS `<` | spec §3.2, A.26 | UTF-16 code-unit `<`, which is faster and disagrees with `String.compare` for astral characters. M5 R3 is where the cost would show and it is inside the noise (§6) |
| 5 | **No `let` generalisation over a constrained variable**, and no promoted-requirements side table | A.30, A.49 | build the side table, which is Roc's answer. The price paid instead is that a constrained `let` helper used at two types is a `type_mismatch` at the second use (§7.4) |
| 6 | **`where` on `pub foreign`, with the sibling's arity unenforced** | spec §5.2, A.7 | add an arity check to `Sibling.zig` — which needs a JavaScript parser, the dependency the `foreign` wall exists to avoid — or refuse `where` on `foreign` and give `List` an uncons primitive instead. This widens CLAUDE.md rule 6's surface |
| 7 | **N hidden positional evidence parameters in canonical scheme order, eta-expanded in value position** | spec §8.1, §8.2, A.24, A.25 | one dictionary record per instantiation, which is report 18 §1.4's megamorphic-IC risk and coarser DCE granularity. §6's R6 says the N-argument encoding did not defeat V8 |
| 8 | **The A.53 bridge**: a `number` or `equatable` variable discharges a well-known constraint with **no** `where` clause, detached | A.53 | rewrite `Basics.compare`/`max`/`min`/`clamp` and `List.member` to carry `where` clauses. This is the one row that keeps ordinary arithmetic's *interface* free of `where` — without it `isEven n = n < 1` publishes a constrained scheme, and §4's churn would reach every numeric function in the language |
| 9 | **`--explain`** as an opt-in `warning` with no effect on the exit code | A.10, spec §10.9 | emit it always (noisy), never (§4 has nothing to count), or add a third severity, which is a change to a schema three tools read |

---

## 13. Known limits that turn a decision

Each of these is measured or pinned, and each is a place where the adoption decision is about
language semantics rather than about dispatch.

- **Structural `==` on a `Dict` compares red-black trees.** Module `Dict` declares no `pub eq`, so
  spec §3.3 falls through to derivation over the shape. `tests/corpus/run/DictStructuralEquality`
  builds one dictionary forwards and one backwards from the same four pairs and prints
  `4 / 4 / False / True / True`: **the two hold the same four pairs, answer `False` to `==`, and their
  `toList`s answer `True`.** Four keys is the smallest number that shows it. Giving `Dict` and `Set`
  methods of their own was out of the spike's scope (A.74); the decision is handed back.
- **A `where` constraint that meets a record only after a field access is refused**, and the message
  is wrong for it (§7.6). `List.foldl points Dict.empty (\p d -> Dict.insert d p (p.x + p.y))` does
  not compile; the same fold behind an annotated helper does. Spec §6.2's "resolve-method-first only
  fires on a concrete receiver" meets §6.3's refusal of an open record, and
  `bench/runtime/c1/R2DictRecord.beni` had to be rewritten around it.
- **An `err` part is written when the receiver is resolved, not when both operands are.** `Ok 1 ==
  Err "a"` records `err` for the `x` position although the argument later pins it to `String`. It is
  harmless — the receiver always pins the position its own constructor carries, so the `err` position
  is the one the tag test rejects first — but fixing it means resolving a target's parts in a second
  pass, a change to spec §6.3 and spec §7.1 together (spec §11, A.67).
- **The `Order` / `Never` case is the clearest evidence about the module rule.** `core/Basics.beni`
  declares `pub compare : number, number -> Order`, so step 1 of spec §3.3 said "`Order` has its own
  `compare`" and nothing derived for it — a type in the first module of the standard library silently
  losing the method it needs, because seven types share one namespace. The table has to be consulted
  *before* the exclusion. The module rule bit core exactly where spec §11 predicted it would.
- **`equatable` and `eq` now overlap**: a type that has an `eq` is equatable and a function type has
  neither, so the marker is redundant with the constraint. Both are left in place (spec §3.4);
  `not_equatable` survives as the better message for `==` on a function. **A nullary method is also
  unreachable by dot-call** — `x.m` with no arguments is a field access, so `t.toString` must be
  written `M.toString t`, which is why spec §5 adds no zero-argument methods to core.
- **`Float` ordering is not total**: `compare` returns `EQ` for any pair involving `NaN`, so
  `Dict Float v` and `List.sort` over a list containing one are ill-behaved. Today's behaviour for
  `==` and Elm's for `compare`; making `compare` well-known makes it reachable in more places.
- **No DCE exists, so every size in §5 is an upper bound** — 216 942 bytes of derived code across 61
  programs, mostly never called (`results:2173`).

---

## 14. What landing this would require

**The branch does not merge.** It carries a normative document of its own, and CLAUDE.md rule 1 puts
the contract for each phase in `frontend.md`, `checker.md`, `backend.md` and `boundary.md`. Landing
means a re-slice folding spec §1–§10 into those four **without renumbering a single section**
(rule 2) — editorial work the spike deliberately did not do. **And the C1 corpus is a language
change, not a refactor**: `core/Dict`, `core/Set` and the `List` sort family lose a parameter, the
two sugar modules are deleted, and `String` and `Char` move module — each a breaking change to a
published interface.

**Owed before it could ship.**

1. **Dead-code elimination.** Every figure in §5 is an upper bound and the floor carries six functions
   nothing calls. Eager derivation without DCE is not a shippable combination.
2. **A `foreign` arity check, or withdrawal of `where` on `foreign`** (decision 6 of §12). A
   `core/List.js` whose `eq` forgot its leading evidence parameter fails at runtime, not at build
   time, and `boundary.md` §4's two automated checks do not look at arity.
3. **The two pre-existing `master` printer defects** §3.1 reproduces — `Render.writeRecord`'s 64-link
   flatten dropping the `| r` tail, and `Schemes.Writer.max_depth` writing `<error>` into an interface
   `beni check` exits 0 on. Not the spike's, but the spike is the reason to fix them.
4. **A decision about the unbounded `where` suffix**: no cap on what one unannotated declaration
   writes into an interface, a 6.4 kB entry being reachable (§3.1), with §4's churn over text of that
   size.
5. **A position on the n² obligation count** of §3. It is the correct count for the program, and an
   annotation removes it entirely; whether a language ships a checker that is quadratic on a shape a
   user can write by accident is a decision, not a bug.

**Deliberately deferred**, costed in the spec rather than built (spec §11, "Stretch, only after S8"):
partitioning same-name constraints by origin class — Roc's *shipped* principality fix, not the design
the Zulip thread described — with its backend half; the per-type method block; and a
record-per-variable evidence encoding behind a flag.

---

## 15. The trade-offs

**The plain problem first.** beni has no ad-hoc polymorphism beyond `number` and `appendable`.
Ordering is passed explicitly, equality is one shared structural walk, and two pre-bound core modules
exist only to hide a comparator argument. The measured tax is 17 argument sites, 15 declarations
carrying a comparator parameter, 7 imports and 17 use sites of the sugar modules (§9) — the thing any
of these options is buying off. No verdict is offered; four options, each with what it buys, what it
measurably costs, and what it forecloses.

| Option | Buys | Measured cost | Forecloses |
|---|---|---|---|
| **(a) Keep `fast-compiler.md` §3.1 as it stands** | nothing new; the unifier stays one-question, `==` stays an obligation, output stays smallest | none | the ergonomic tax stays: 17 argument sites, 15 comparator parameters, the two sugar modules (§9). `==` stays one megamorphic structural walk — 52.8 % of R4's C0 profile (§6.1) |
| **(b) Adopt the whole spike** | `where` constraints, dot-call, derived `eq` **and** `compare`, return-type dispatch; the ergonomic tax goes to 0/4 (§9); R4 7.2×, R5 3.2×, R6 1.28× faster (§6) | `check` **+20.3 %** on code that never uses it and **+7.8 %** more for code that does (§2); floor output **+5.5 %**, `bench/corpus` **+11.8 %**, ~198 B per derived function, all upper bounds with no DCE (§5); unannotated `pub` interface churn **4.4–6.5× worse** (§4); **n² obligations** on an unannotated chain (§3); compiler +8 992 lines of `src/`, cold build 1.37×, binary 1.264×, black-box gate 1.61× (§8) | the interface is now unbounded text (§3.1); the module rule constrains module shape — 6 of 21 multi-type modules collide under the style it rewards (§9); §14's five owed items become blockers |
| **(c) Adopt the operator half only** — derived `eq` and `compare` for structural and nominal shapes, **no** `where` clauses, **no** dot-call, no user-named methods | the whole of §6's runtime win (R4 7.2×, and R3/R1 unchanged), and the whole of §9's ergonomic win, since `Dict`/`Set`/`sort` only ever needed the two well-known names | the output-size figures of §5 **in full** — derivation is what produces them, and this option keeps all of it, `compare`'s 1.60×-per-function included. **The check-time cost is not measured**: no configuration of the spike has `eq`/`compare` derivation without the constraint machinery underneath it, so M1a's +20.3 % is an upper bound on this option and nothing in this report bounds it from below | user-named methods, return-type dispatch, and decoding into a type — report 18 §3's prize. Note it *also* forecloses nothing about §4: with no `where` clause there is nothing new to put in an interface, so the churn finding does not apply to this option at all |
| **(d) Report 18 §6's two recommendations only** — generalise obligation discharge from a hardcoded set to a mechanism, and separate the codec question from the dispatch question | keeps the door genuinely additive rather than nominally so; lets structural codec derivation be decided on its own, since it needs no nominality and no dispatch | small and unmeasured; the spike measured neither, because it built the whole feature instead | nothing. This is the only row that closes no door — and it buys none of §9's ergonomics either |

**Two questions only the user can answer.**

1. **Is 4.4–6.5× churn (§4) on unannotated `pub` declarations acceptable, given that an annotation removes it
   entirely?** The measurement is unambiguous both ways: annotated declarations are at **0 interface
   changes in every edit class on both corpora on both compilers**, unannotated ones go from 8.5 % to
   55.6 % on `core`. `fast-compiler.md` §3.1 made top-level annotations *optional* on purpose, and
   report 18 §2.3 argued that this is what makes static dispatch expensive here and cheap in Roc. The
   spike prices it rather than resolving it, and adds `--explain` so an author sees the moment they
   create one (§7.5).
2. **Should `compare` be decided in the same breath as dispatch?** A separate decision the spike
   deliberately bundled, and the bundling is visible in the numbers: 1 874 of the floor's 3 159
   derived bytes, and the whole of `fast-compiler.md` §3.1 point 3. Option (c) exists precisely
   because §9's ergonomic win comes almost entirely from `compare` and almost not at all from
   dispatch — and report 18 §5 said the `comparable` decision "should be argued on its own merits, not
   carried by the dispatch decision".

---

## 16. Could not determine

- **The check-time cost of option (c)** — derivation without the constraint machinery. No build of the
  spike has one without the other, so M1a's +20.3 % bounds it from above and nothing bounds it from
  below. This is the single largest gap in the report, because (c) is the option the ergonomic numbers
  most favour.
- **Whether M1a's 20.3 % is the feature or the two missing core modules.** A checks 635 modules and B
  633, and B's `core/Dict.beni` carries seventeen `where` clauses A's does not (`results:1220-1225`).
  The user code is byte-identical; the cores are not. A run of C1's core through both checkers is not
  possible, because C1's core does not check on `master`.
- **M1a and M1b on machine 2**, and **R4/R5/R6 on the N100 after S6 and S7.** M1a/M1b stay N100-only
  by the machine rule (`results:1434`), with one machine-2 counter line for the plain corpus
  (`results:3372`). The S5 N100 reading of R4 (1.40×) predates `List` getting its own `eq`, and R5 and
  R6 were never measured on the N100 with their C1 programs, which were written on machine 2.
- **Which supervisor killed the pre-fix n = 1 000 run.** `systemd-oomd` was active and
  `/proc/pressure/memory` read `full avg60=20.05`, but the ring buffer carried no OOM-killer line and
  `sudo` was unavailable; only that the process reached 29.2 GiB and was terminated
  (`results:1627-1634`). Moot after A.81, and recorded because the S8a reading rested on it.
- **Why `../beni-s1`'s ReleaseFast binary is 64 584 bytes smaller on machine 2 than on the N100** at
  the same commit with the same Zig. A different native target is the obvious candidate and was not
  verified (`results:1445-1452`); likewise the 40- and 8-byte differences between the same commit
  built in two directories (`results:2752-2759`).
- **What a changed interface costs an importer.** §3.1 measures the text and §4 how often it changes,
  but interface *hashing* does not exist yet (spec §11) — and that is the quantity report 18 §2.3's
  argument turns on.
- **Whether the module rule's 6-of-21 collision count generalises.** One count over three trees
  written before the rule existed; a codebase written *under* it would organise differently, and
  report 18 §4.3 quotes Roc's own people disagreeing about whether that is a benefit or a cost.
- **Any comparison against Roc's measured behaviour.** Roc was never run for this report; every
  statement about Roc here is its *described* behaviour, from reports 18 and 20.
- **The cost of the `--explain` warning at scale.** One black-box scenario on a two-declaration
  program; nothing measures how many warnings a real corpus produces or whether the output is usable.
