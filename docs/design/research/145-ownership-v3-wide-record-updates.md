# 145 — The ownership kernel v3: an update of a wide record costs its width

*Research report, 2026-11-15. A blind round found a performance fault in the checker v3
(`--ownership=v3`): a record literal of 3 000 fields and one update that writes all of them took 7.9 s
of the ownership check on ReleaseSafe, and stopped at no limit. The time grew with the square of the
width. This report finds the loops, makes each a lookup with the same answers, makes the work that was
not counted count, and measures the change. The kernel is `ownership-v3-kernel.md`; this report adds to
its §8. Nothing outside `src/own3/` changed but the adapter of `src/own2/Groups.zig`, whose answers are
the same.*

---

## 1. Result

- **The fault**: 6.9 s of v3 on the gates' ReleaseSafe compiler before (the round measured 7.9 s), 0.27
  s after; 0.82 s → 0.07 s on ReleaseFast LLVM. It is accepted, as before. v3's time on the program is
  now linear in the width: 3.0 ms and 6.1 ms at 1 500 and 3 000 fields (ReleaseFast), against 184.5 and
  810.8 ms. The type check of the same file takes 17 s on the gates' compiler and 4.3 s on ReleaseFast;
  that is the type check's cost (it copies the record's type for each reference), not v3's.
- **A timing scenario** (`test-perf`, *the v3 ownership check of an update of every field of a wide
  record is linear in its width*): the `ownership3_module` event of 1 500 and 3 000 fields, a ratio of
  2.05 (at most 2.5), and 6.2 ms at 3 000 fields (at most 200). The base: 4.4, and 811 ms. On the gates'
  compiler the same two files take 24.8 and 49.7 ms of v3.
- **The cause** (§2): five loops, each over the record's width for each of its fields. One was not
  counted at all and was almost all of the time: the budget of a declaration read the type of each
  reference to the record, and each reference's type is a copy of the record's type that the type check
  made for that reference alone.
- **The fix** (§3): each loop is a lookup, the adapter's work counts, and no test costs more units than
  the one it replaces (the review, §7). Units now track time on these shapes (§4).
- **Verdicts**: every dump of the 2 751 ownership roots is the same, byte for byte (§5).
- **Sweeps** (§6): every generator, every fault folder and the corpus, 86 318 programs under
  `run.mjs --mode=both` (sanitised, in place, and both under `--release`) on the last commit: no new
  fault. The three TRAPs are the corpus's known ones (§6).
- **Speed on the real roots**: v3 takes 1 046.4 ms against 1 037.7 ms before at the best of three runs
  (+0.8 %), with the same 1 477 demands, 1 370 accepted and 107 refused.

## 2. Root cause

The program (`blindO/faults/perf-wide-record-update`):

```text
go n =
    r0 = { f0 = 0, f1 = 1, …, f2999 = 2999 }
    r1 = { r0 | f0 = r0.f1, f1 = r0.f2, …, f2999 = r0.f0 }
    String.fromInt (r1.f0 + r1.f2999)
```

A profile of the ReleaseSafe compiler (`perf`, 3 000 fields) put 34 % of the whole run, and 97 % of v3's
part, in `Mod.declBudget` → `placeOfInst` → `Groups.Adapter.ofVar`. The walks took 0.7 %.

1. **The budget read each reference's copy of the type** (`Mod.declBudget`). A declaration earns 128
   units for each layout entry of each instruction that a walk evaluates (kernel §8), so the budget asks
   the place of every such instruction. `r0`'s fields are `number`, so the type check generalises `r0`
   and gives each of the 3 000 references `r0` (in `r0.fK`) its own copy of the record type. The adapter
   memoises by store variable, so it read each copy whole, field by field, with a stack allocated for
   each field: 3 000 × 3 000 reads. The copies are one structure, so they add one place, and
   `chargePlaces` counted nothing. The walk itself never reads those copies: the value of a reference to
   a local is the local's (`evalInner`, `.local`).
2. **A field read scanned the record's parts** (`project` of a `built` value): each of the n reads of a
   field compared its step with each of the n parts. Counted, 9 million units at 3 000 fields.
3. **A later read was compared with every slot written** (`atomsReach`, `overlapAny`, `rootReach`): the
   update writes n slots, and each later read of a field (`r1.fK`) was compared atom by atom with all
   n. Counted; the square of the fields when an update is followed by another (`fault2`: 18.5 million
   units at 2 000).
4. **`rootReach` scanned every entry of a root for its runs**: an operand of the update that is a part
   of the literal's root looked at each of its n entries, though none of a literal's has a run. Counted.
5. **A projection kept an array as wide as the record** (`Loc.proj`'s inverse `down_off`): the
   projection of each field of a record of n fields made an array of n, so n² in the location table
   (the module's work, and the memory). Counted: a record of 2 000 lists spent 8 million units there.

And one loop that was not counted: the copy of an update compared each field of the record with each
field the update names (`recordUpdate`), n × k.

**Why the budget did not stop it.** The work that took the time (1) was not counted. The work that was
counted (2–5) was paid for by a budget that grows with the same square: n references to a layout of
about 2n entries earn 256·n² units, capped at 2²⁵ for the declaration. At 3 000 fields the walk did
10.5 million counted units of its 33.5 million, and spent 7 s outside them.

## 3. The fix

Each change gives the answer the old loop gave (§5), and no test costs more units than the old one did
(the review's finding, §7). Kernel §8, *A wide record costs its width, not its square*.

| Loop | Now | Where |
|---|---|---|
| the budget read each reference's copy | a reference to a local earns for the local's layout, the value the walk makes | `Mod.budgetPlace` |
| the adapter's reads were not counted | each variable it closes and each field it reads is a lookup (4 units), charged to the module; a field whose type is a leaf is read with no stack | `Adapter.var_work`, `Check.var_units`, `Adapter.childId` |
| the budgets kept being made past the cap | they stop once the location table's work passes `module_cap`: the module is over its budget whatever the rest earns | `checkModule`, `declBudget` |
| a field read scanned n parts | a construction of more than 16 parts projected twice is indexed by step, once in the frame; the first two projections cost a scan each, each later one a lookup | `Frame.builtPart` |
| a read compared with every slot written | a write of more than 32 atoms is grouped by root and entry (and by root); an atom compares its group only, and each test costs at most what the scan cost | `indexWrite`, `atomsReachIndexed`, `overlapIndexed`, `rootReach` |
| `rootReach` scanned every entry | the entries of a root with a run are listed once, after its entries are made (`linear` decided); the first list costs the scan | `runEntries`, `runsReach` |
| the inverse of a projection was dense | where the child is under an eighth of the parent, it names only the parent's entries that the child's are at | `Loc.Proj.down_keys` |
| the update's copy compared n × k | a sorted list of the fields named, a binary search | `recordUpdate` |

Safe builds check that a root's listed entries are the ones a scan finds (kernel §9), for roots of at
most 256 entries.

**What stays quadratic, and counted.** Each pair of a write and a later read is a step (kernel §5, test
4): n writes each read later are n² pairs. A record of n lists, each pushed in one update, and a record
of n records, each written by a helper, reach the declaration's budget at about 500 fields (#2534). A
reference to a top-level value still reads its own copy of the type, which the walk projects (`.top`):
it is counted now, so the module's cap bounds it. A record passed through calls costs about 1 000 units
for each layout entry of each call, more than an instruction earns (#2535; the same before).

## 4. Units and time

Units are deterministic; they come from a measuring build that prints each declaration's count (not in
the commits). `units` is the walks' count + the location table's; `LIMIT` is a limit line.

**The fault shape** and its relatives, base `273cc9426f` and after:

| Shape | Base units | After units |
|---|---:|---:|
| the fault, 1 000 fields | 1.51 M + 0.13 M | 0.52 M + 0.06 M |
| the fault, 2 000 fields | 5.03 M + 0.25 M | 1.03 M + 0.13 M |
| the fault, 3 000 fields | 10.54 M + 0.38 M | 1.55 M + 0.18 M |
| two updates of all 250 / 500 / 1 000 / 2 000 fields | 0.57 / 1.63 / 5.26 / 18.52 M | 0.32 / 0.63 / 1.27 / 2.53 M |
| ten updates of all 250 / 500 / 1 000 fields | 25.7 M / LIMIT / LIMIT | 4.5 / 9.0 / 18.0 M |
| a record of 250 / 500 / 1 000 / 2 000 lists, each moved to the next field | 0.27 + 0.14 / 0.79 + 0.53 / 2.58 + 2.06 / 9.17 + 8.11 M | 0.15 + 0.02 / 0.29 + 0.03 / 0.59 + 0.06 / 1.17 + 0.12 M |
| a record of 250 / 500 lists, each pushed | 13.6 M / LIMIT | 13.5 M / LIMIT |
| 10 / 20 / 40 / 80 records of 30 fields, each written by a helper | 1.58 / 4.66 / 15.4 M / LIMIT | the same |
| an entry model of 1 000 / 3 000 fields, all written | 1.17 + 1.05 / 3.52 + 9.14 M | 1.17 + 0.10 / 3.52 + 0.29 M |
| a top-level record of 3 000 fields read field by field (refused) | 6.1 + 9.4 M | 6.1 + 72.2 M (the adapter's reads, counted now) |

The walks' units are linear in the width for every shape but the two of #2534, and the location table's
too.

**Time.** v3's time from `--self-profile` (every `ownership3_module` event of the run, core's
included), `check --jobs=1`, ReleaseFast LLVM compilers of `273cc9426f` and of the fix, built and run
on one machine, alternated, best of three. The shapes are `<scratch>/shapes.mjs`'s.

| Shape | Base | After |
|---|---|---|
| the fault, 1 000 fields | 0.09 s, accepted | 0.02 s, accepted |
| the fault, 2 000 fields | 0.34 s, accepted | 0.04 s, accepted |
| the fault, 3 000 fields | 0.82 s, accepted | 0.07 s, accepted |
| the fault, 6 000 fields (two updates of 3 000: the parser takes at most 4 096 fields in one) | 3.31 s, limit | 0.07 s, limit |
| two updates of all 2 000 fields | 0.67 s, accepted | 0.07 s, accepted |
| ten updates of all 500 fields | 0.26 s, limit | 0.05 s, accepted |
| ten updates of all 1 000 fields | 0.85 s, limit | 0.11 s, accepted |
| thirty updates of all 1 000 fields | 2.41 s, limit | 0.36 s, limit |
| fifty updates of 60 of 3 000 fields | 0.98 s, limit | 0.34 s, limit |
| 3 000 `Int` fields from a parameter (no copy of the type) | 0.02 s, accepted | 0.02 s, accepted |
| 2 000 lists, each moved to the next field | 0.03 s, accepted | 0.02 s, accepted |
| 2 000 lists, each pushed | 0.08 s, limit | 0.07 s, limit |
| 30 records of 40 fields, written as literals | 0.01 s, accepted | 0.01 s, accepted |
| 50 records of 60 fields, each written by a helper | 0.06 s, limit | 0.06 s, limit |
| a record of 3 000 fields through 40 calls | 0.22 s, limit | 0.20 s, limit |
| a `browser-inline` model of 1 000 / 3 000 fields, all written | 0.03 / 0.07 s, accepted | 0.03 / 0.05 s, accepted |
| a top-level record of 2 000 / 3 000 fields, read field by field | 0.46 / 1.08 s, refused | 0.35 / 0.84 s, refused |

**Research report 138's shapes** (`fix137/gen.mjs`, six modules each), the same compilers:

| Shape | Base | After |
|---|---|---|
| a list of 9 000 numbers, 30 `f p = p` | 0.15 s, accepted | 0.15 s, accepted |
| 9 000 negated numbers | 0.16 s, accepted | 0.17 s, accepted |
| 9 000 reads of a parameter | 0.15 s, accepted | 0.15 s, accepted |
| a record of 9 000 fields | 0.05 s, limit | 0.05 s, limit |
| `k + k + …` 4 000 times | 0.16 s, accepted | 0.16 s, accepted |
| a list of 190 calls with 20 arguments | 0.09 s, accepted | 0.09 s, accepted |
| 40 functions of two calls with 20 arguments | 0.15 s, accepted | 0.15 s, accepted |
| 30 functions with a list of 45 references, nested pairs of 4 096 lists | 0.14 s, accepted | 0.15 s, accepted |
| the same, 130 references | 0.15 s, accepted | 0.15 s, accepted |
| a literal list nested 400 deep | 0.06 s, limit | 0.06 s, limit |
| 30 functions each a list of 45 references to nested pairs of 2 048 lists | 0.89 s, accepted | 0.91 s, accepted |
| the same with 45 calls | 1.69 s, limit | 1.70 s, limit |
| 1 400 rows of two lists | 0.01 s, accepted | 0.01 s, accepted |
| 2 500 calls in one group | 0.02 s, accepted | 0.02 s, accepted |

(The record of 9 000 fields stops at the layout limit on the base too: each field's slot is a location
since research report 142.) The first fix made the lists of 45 references 27 % slower (1.13 s): a
projection of a list's element, which covers most of its layout, searched a sparse inverse for each
entry. A projection keeps its dense inverse unless the child is under an eighth of the parent now.

**The real roots** (`bench/ownership-v2-review.mjs --checkers=v1,v3 --roots=real --runs=5 --jobs=1`,
556 564 lines, three runs each, alternated): 

| | run 1 | run 2 | run 3 | best |
|---|---:|---:|---:|---:|
| base, v3 ms | 1 038.8 | 1 037.7 | 1 039.7 | 1 037.7 |
| after, v3 ms | 1 046.4 | 1 050.9 | 1 048.8 | 1 046.4 |

+0.8 % at the best run; the verdicts are the same in every run: 1 477 demands, 1 370 accepted, 107
rejected. The first version of the fix was +4.6 % (1 083.7 ms): `examples/conduit` +12 %, from a hash
index built for constructions read once and `overlapAny` made non-`const` (§3, the third commit).

## 5. Verdicts

- **Every dump of the 2 751 ownership roots** (`o1Roots` with every ownership fixture,
  `dump --stage=ownership --ownership=v3 --ownership-everywhere`) is the same, byte for byte, on the
  base and after.
- **Programs that now finish instead of hitting a limit** (no ownership root is one):
  ten updates of every field of a record of 500 and of 1 000 fields (§4); the program of *one budget
  for each module* below; a module of eight chains of 400 writes; and, of the review's probes, a few
  limit lines of records of lists and of records passed through calls (1 456 → 1 452 and 1 599 →
  1 598), whose newly accepted writes are not read again.
- **Two tests changed with them**, each a program that hit a limit and now does not:
  - *one budget for each module, in proportion to its size*: a record of 1 000 lists at 30 types passed
    the module's budget in the location table (cause 5). It is accepted now, in 2.4 s on the gates'
    compiler, most of it the type check.
  - *no module does more than the most for any module*: eight chains of 400 writes passed the module's
    cap; each chain costs half its units now (cause 3: a write names every older name), so the test has
    eighteen.
- **The limit text** can name another type: where a module meets the layout limit, the first type to
  meet it can now be a local's and not its reference's copy (the review's `poly/p2`: "a record" where
  it said "a list"). Both refuse the module.

## 6. Sweeps

`bench/ownership-sweeps/run.mjs --checker=v3 --mode=both --jobs=24`, the self-hosted ReleaseSafe compiler of
the last commit, every program of the 25 generators of the folder (the corpus included) and of its 13
fault folders, and the round's fault (86 318 programs):

| Verdict | Programs |
|---|---:|
| SAME (every leg) | 18 649 |
| REFUSED | 67 490 |
| LIMIT | 15 |
| PLAINFAIL, BOTHFAIL (the generator's or the program's, not the checker's) | 124, 12 |
| TIMEOUT | 25 |
| TRAP | 3 |
| DIFF, IPTRAP, IPDIFF, RIPTRAP, RIPDIFF, CRASH | 0 |

- The three TRAPs are the corpus's known ones, as in research report 144: `run/ListSanitiserTrieHolder`
  traps as its golden says, and `browser/dom/ShowAndBranches` and `browser/tea/ShowAndBranches` are
  #2504 (`dom` and `browser-tea`, out of this report's scope).
- 24 TIMEOUTs are `TIMEOUT plain`: the oracle, the program built with no checker, runs past 20 s by
  design (the DAGs of closures of `bounded-walk` and its faults, `blind7f-faults/closure-dag`). One is
  `run/TailModConsMerge` under the sanitiser on a loaded machine (report 142 §5).
- The 15 LIMITs are the folders' known ones (`bounded-walk`'s `climb` and `group.local`,
  `group-rounds-slow`, `locals-after-limit`, `EvidenceDagBuildDepth32`, `blind4b`'s and `blind5c`'s
  sizes); each dumps the same on the commit the earlier sweeps ran and on the last.
- The sweeps ran on the first two commits before, with no fault, and then whole on the last; between
  the first two, `dump --stage=ownership` of 25 861 of the programs is the same, and of the LIMIT
  programs too.

## 7. The review

One fresh adversarial reader (Opus), given the diff and the kernel, not this report.

- **Found, fixed: a construction projected once cost more units than before**, so a declaration at its
  cap gave up earlier and refused writes the base accepted (`List.push … accepted call` became
  `rejected limit` and `rejected later-use`). `builtPart` charged 4 units for each part to build its
  index, where the scan it replaced cost 1 for each part, and `indexWrite` and `runEntries` charged
  their indexes up front too. Now the first two projections cost a scan each (the second makes the
  index), each later test costs at most what its scan cost, and the indexes are paid by the scans they
  replace. The
  reader's three programs print what the base prints.
- **Found, answered: the limit text** of `poly/p2` (§5).
- **Found, fixed: the safe-build check of `runEntries`** read every entry of the root at each call,
  which made the gates' compiler grow faster than linear (356 ms at 3 000 fields, 107 at 1 500). It runs
  for roots of at most 256 entries now.
- **Found, not changed: shapes that stay slow and stop at the cap**: a chain of 1 000 one-field updates
  of a record of 1 000 fields (6.05 s → 4.37 s on the gates' compiler), 200 updates of 20 of 2 000
  fields (15.6 s → 2.9 s). Both are the pairs of #2534 and the copy of every slot under a new name at
  each update (kernel §11 rule 3), counted.
- **Held**: 3 596 existing programs (all of `tests/corpus/run`, the 720 of the records round, part of
  `recursive-levels`) dump the same; 172 generated wide-record programs at 3, 33, 40 and 70 fields
  (twins `.live`/`.dead`, joins, lists of lists, escapes, helpers, `==`) are REFUSED where live and SAME
  where dead under `--mode=both`; `--jobs=1` and `--jobs=8` print the same; no safe-build assertion fired.
  By reading: the sparse `downOf` gives the same runs in the same order, the leaf path makes the ids
  `ofVar` makes, the identity of the indexed write cannot match another slice (the walk's arena never
  reuses memory, and a nested demand turns the index off), and the cap's break runs only past the
  budget.

## 8. Reproduce

```sh
node <scratch>/shapes.mjs <dir>            # the shapes of §4
node <scratch>/time.mjs <beni> <dir>       # v3 ms, units, limits
node bench/ownership-sweeps/run.mjs --beni=zig-out/safe/bin/beni --checker=v3 --mode=both --jobs=24 --tmp=<disk> <dir>
zig build test-perf "-Dtest-filter=wide record is linear in its width"
```

The units need a measuring line that is not in the commits: print `m.decl_steps[di]` and
`m.decl_budget[di]` for each declaration, and `m.module_units`, `m.loc.units` and `m.module_budget`, at
the end of `Check.checkModule`.
