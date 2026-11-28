# 130 — The ownership kernel v3: one budget for each module, in proportion to its size

*Research report, 2026-11-14. A fix of `src/own3/` for the open finding of research report 129 §10: the
budget was per declaration, so declarations that each stayed under it added up. The kernel is
`ownership-v3-kernel.md`; this report changes its §8. Nothing in `src/own/`, `src/own2/` or a platform
runtime changed.*

---

## 1. Result

- **A module does at most 65 536 + 16 384·n units of work**, where n is its size: the tokens of its
  source, or its BIR instructions where it has more (`Check.moduleBudget`). The declaration's budget of
  2²⁵ units stays. So a build does at most 16 384 units for each token and 65 536 for each module:
  linear in the size of the program, whatever its types or its number of declarations.
- **Every loop of the check counts, not only the walks.** The location table (layouts, projections,
  paths, call maps), the reading of imported contracts and the place graph count against the module's
  budget. Four loops that cost the product of two layouts are linear now, and the facts of derived
  methods are found once for each row, not once for each row above it.
- **The worst program found takes 5.2 s for 7 767 lines** (40 modules over one record of 2 040 lists).
  Before, the worst took 76 s for 4 450 lines.
- **Nothing that matters moved.** Every sweep has the same SAME count; 0 TRAP, DIFF or CRASH; the
  sanitiser corpus has 0 traps; v3's verdicts on the 308 real writes are the same, line for line; v3
  runs at 540k lines/s on v2's modules (550k before).
- **Lost, loudly:** three corpus programs with paths more than a hundred levels deep now reach the
  module's budget (§8).

## 2. The rule, and why

The goal: a check that ends in a few seconds on any program, and whose time a reader can bound from
the code. Three rules were possible.

- **A fixed budget for each module.** A large real module would pass it, and a program can have many
  modules. It bounds nothing about a build. Rejected.
- **A budget in proportion to the size times a layout factor** (units for each token, times the largest
  layout the module uses). A layout can have 4 096 locations from a type of a dozen lines, so this
  allows 4 096 times more work than the source. That is the shape that was slow. Rejected.
- **A budget in proportion to the size.** The units that a token may cost are fixed. Work that a
  layout makes large has to fit in the budget of the source that names it. Chosen.

**The constant comes from the densest program we must keep.** I counted every module of the 2 731
ownership roots (every corpus program and every real root) and of the 136 fault programs, with the
budget turned off. The units for each token:

| Module | Tokens | Units | Units for each token |
|---|---:|---:|---:|
| `tests/corpus/check/good/RequirementBelowDepth512` | 178 | 2.3 M | 13 100 |
| `tests/corpus/run/TailModConsBranches` | 587 | 8.3 M | 14 100 |
| `blind8g-faults/group-rounds-control.dead` | 1 427 | 22.6 M | 15 800 |
| `examples/conduit` `Main` (the largest of a real root) | 941 | 3.8 M | 4 000 |
| `bench/corpus` `NotesApp` | 1 536 | 5.7 M | 3 700 |

So 16 384 units for each token keeps all of them, with a margin of 4 for the real roots. Half of it
would halve the worst time and lose the first three. The floor of 65 536 is small on purpose: a floor
is paid for each module, and many small modules over one large type would turn a large floor into the
bound. It covers a module of a few lines with no large type.

**Determinism.** A module's budget depends on its own tokens and instructions, and its count on its
own walks and the contracts of its imports. Both are the same at any `--jobs` (CLAUDE.md rule 5). The
token count comes from the artifacts, so a run from the cache trips at the same declaration.

**Past the budget.** The same as past the declaration's: every walk returns at once, the declaration
gives up, a limit line names the budget ("the walks of the module took more than N units of work (65536,
and 16384 for each of its n tokens)"), no other declaration of the module is walked, and the module
publishes nothing and authorises no write.

## 3. What the count did not see

The per-declaration budget counted the walks. A program could still take a long time in work that no
budget saw. A generator of worst shapes (§5) and two reviews (§9) found these. Each is counted now.

1. **The location table.** Building a layout, a projection, a path and a call map was kept once for each
   key but never counted. A module that instantiates a record of 2 040 lists at 200 types built 200
   layouts and their maps: 76 s. Each step of a visit and of a projection's path is a lookup (4 units),
   each entry built is a unit, and a copy of a path is one unit for each four words. A location is found
   in a layout of more than 16 entries by an index, not a scan (`Loc.Table.indexOf`). The down map of a
   projection is a counting sort, not a scan of every child entry for every parent entry.
2. **The product of two layouts in the walks of values.** A walk of a construction looped over every
   entry asked for each part: 2 040 parts × 2 040 entries for each walk of a record. A reading through
   another layout tested every entry of the call map against every entry asked. A set of entries
   tested each new member against all the members. Each is linear now and gives the same entries in the
   same order. A part of a construction costs a lookup of its projection, 4 units.
3. **The pairs of empty locations** (the first review). The end of a walk tests every pair of its
   result's locations for a cell that both hold, and counted the atoms it compared. 4 096 locations
   that hold no atom were 8 million free pairs in each declaration: 1 000 functions `gN n = gN n` over
   nested pairs took 22 s before and 8 s with the module budget. Only locations that hold an atom are
   paired now, in this test and in the two like it.
4. **Imported contracts** (the second review). Reading a contract of another module extended a location
   for each label of each entry, once for each pair of importer and imported module. A type 250 levels
   deep has paths of 250 labels. Each label is a lookup now, and an entry shares the prefix of its labels
   with the one before it, so only the rest is looked up.
5. **The place graph.** `own2`'s adapter builds the places of each type a module names. Each place and
   step it adds is 32 units, about what it costs. `src/own2/` did not change: the module counts the
   growth of the place table after each call.
6. **Derived methods** (the third review). The facts a module publishes of its derived `eq` and
   `compare`, and each piece of evidence that a walk judges, walked every derived row below them
   again, once for each row or site: 1 000 types that each hold 32 earlier ones took 7 s with no other
   code. A row's answer is kept now until a contract that it read changes (`Mod.rowInfo`), and rows
   that name each other are solved together from a worklist. Another module's facts are sorted and
   found by a binary search, not a scan.

The work that is still outside the count is linear in counted work: the indexes of a frame
(`MeetIndex`, `CoverIndex`), memo hits in the location table, and the export of the module's contracts.
One piece is not, and is not v3's own: `own2`'s prepass collects the dispatch edges of each declaration
(`Edges.declEdges`) the way the type check does, and costs what the type check costs there (§9).

## 4. The units of the roots

With the final count, the module of an ownership root nearest to its budget is
`tests/corpus/run/TailModConsBranches` (8.3 million units, 0.86 of its budget), and of a real root
`examples/conduit`'s `Main` (3.8 million, 0.24). No real root reaches its budget, and no declaration of a
root reaches the declaration's. Three corpus programs pass their module budget; §8 names them.

## 5. The worst shapes

A generator (`worst.mjs` in the scratch directory of this work; not kept in the repository) writes
programs that maximise v3's time for each line: many declarations over a record of 2 040 or 4 000 lists
(`decls`); many modules over one such record (`mods`); nested pairs of up to 4 096 lists (`deep`); many
local functions (`locals`); a record of `List a` at many types, in the module or imported (`inst`,
`instx`); pairs of two such records (`pairs`); functions that answer a value of 4 096 locations
(`self`); the second review's 120 small modules over four types 250 levels deep (`rev.g7`); and the
third review's chains of nominal types (`rev.g2`, `rev.g5`).

ReleaseSafe LLVM compilers of `7c8a25550e` (before) and of this work (after), `beni check --jobs=1`,
the `ownership3_module` phase against the `check` phase of the same run, one run each:

| Program | Lines | Before: v3 / check (ms) | After: v3 / check (ms) | After: verdict |
|---|---:|---:|---:|---|
| `inst.F2040.N200` | 4 450 | 76 057 / 339 | 241 / 377 | limit |
| `self.K12.N3000` | 15 059 | 64 854 / 76 | 704 / 79 | limit |
| `pairs.F2040.N200` | 5 493 | 53 380 / 817 | 260 / 1 968 | limit |
| `mods.F2040.M40.N4.L30` | 7 767 | 37 518 / 1 040 | 5 209 / 1 041 | limit |
| `mods.F2040.M100.N1.L10` | 3 847 | 24 130 / 496 | 1 367 / 490 | limit |
| `mods.F2040.M10.N10.L30` | 5 577 | 23 145 / 618 | 2 155 / 624 | limit |
| `decls.F2040.N100.L30` | 5 550 | 22 953 / 478 | 238 / 723 | limit |
| `self.K12.N1000` | 5 059 | 21 656 / 38 | 244 / 38 | limit |
| `instx.F2040.N50` | 2 649 | 17 372 / 103 | 234 / 105 | limit |
| `self.F4000.N600` | 7 010 | 13 141 / 6 995 | 1 252 / 7 447 | accepted |
| `rev.g2.300.32.3000` | 16 211 | 12 626 / 6 037 | 6 158 / 6 015 | accepted |
| `mods.F4000.M20.N2.L100` | 8 267 | 12 629 / 1 118 | 2 524 / 1 122 | limit |
| `deep.K11.N1000.L2` | 13 055 | 11 621 / 36 | 3 431 / 37 | limit |
| `rev.g7.K4.M120` | 4 985 | 9 119 / 7 773 | 2 363 / 7 143 | limit |
| `rev.g2.1000.32.0` | 4 011 | 7 007 / 102 | 14 / 106 | accepted |
| `deep.K11.N400.L10` | 18 055 | 5 379 / 33 | 4 472 / 34 | limit |
| `rev.g5.4000.600.16` | 18 410 | 5 191 / 104 | 19 / 110 | accepted |
| `deep.K10.N1000.L4` | 21 051 | 3 336 / 40 | 3 788 / 42 | accepted |

- **Worst lines per second of v3's walks:** 58 before (`inst.F2040.N200`), 1 491 after
  (`mods.F2040.M40.N4.L30`).
- **Worst ratio of v3 to the type check:** 857 before (`self.K12.N3000`), 131 after
  (`deep.K11.N400.L10`, where the type check reads nested pairs as 11 aliases and takes 34 ms for 18 000
  lines).
- `rev.g2.300.32.3000` (3 000 functions that compare a value of the last of 300 such types) still takes
  6.2 s, as long as its type check. Almost all of it is `own2`'s prepass, which walks the dispatch edges
  of each declaration through every derived row, as the type check does (§9).
- **Time for each unit:** 1.4 to 6.3 ns on every shape but one, measured with an instrumented build of
  the same code. The exception is a module of a few lines that names large types (`rev.g7`): about
  25 ns, where the type check of the same module takes three times longer than v3.

So the bound that §8 states is the one the code keeps: at most 16 384 units for each token, which is
at most about 0.1 ms for each token. A program of a few thousand lines ends in a few seconds. The
constant is not small: the densest programs we must keep set it (§2).

## 6. Tests

Black-box, `tests/blackbox/check_test.zig`, three new tests, each run on the commit before it in a second
worktree (never `git stash`):

| Test | Program | Before | After |
|---|---|---|---|
| one budget for each module | a record of 2 040 `List a` in one module, instantiated at 30 types in another | did not end in 10 s (on `7c8a25550e`) | the module's limit, 1.5 s |
| the pairs of a result's locations | 1 000 functions `gN n = gN n` over nested pairs of 4 096 lists | did not end in 10 s (on `caaf187ab7`) | the module's limit |
| each derived row is read once | 1 000 nominal types, each holding 32 of the types before it | did not end in 10 s (on `3fa6f5b252`) | accepted |

The tests run on the gates' self-hosted ReleaseSafe compiler, which is about seven times slower than an
LLVM build. `group-rounds-slow.dead` of report 129's test now reaches the module's budget before the
declaration's, and the test names the module's limit. `group-rounds-control.dead` is still accepted.

## 7. Gates

ReleaseSafe LLVM compiler of the final commit. The "before" of the sweeps, the sanitiser and the real
writes is report 129 §8's "after", which is the same code (`ca717d194c`; the commits after it change
only text).

**Sweeps** (`run.mjs --checker=v3`, every generator and every fault folder). **0 TRAP, DIFF or CRASH, no
timeout. SAME is unchanged in every folder:**

| Folder | Programs | SAME | REFUSED | Other |
|---|---:|---:|---:|---|
| blind-faults | 24 | 11 | 13 | |
| blind2-faults | 20 | 7 | 13 | |
| blind3-faults | 10 | 3 | 7 | |
| blind4a-faults | 12 | 1 | 11 | |
| blind4b-faults | 8 | 4 | 4 | |
| blind5c-faults | 10 | 5 | 5 | |
| blind5d-faults | 10 | 5 | 5 | |
| blind6e-faults | 12 | 4 | 8 | |
| blind7f-faults | 2 | 0 | 1 | 1 BOTHFAIL |
| blind8g-faults | 8 | 4 | 4 | |
| bounded-walk-faults | 12 | 2 | 9 | 1 BOTHFAIL |
| runtime-calls-faults | 8 | 2 | 6 | |
| aliased-arguments | 5 160 | 1 183 | 3 977 | |
| answers-beside | 240 | 77 | 163 | |
| blind | 9 792 | 1 675 | 8 117 | |
| blind2 | 1 202 | 502 | 700 | |
| blind3 | 417 | 160 | 257 | |
| blind4a | 160 | 24 | 136 | |
| blind4b | 6 596 | 1 229 | 5 367 | |
| blind5c | 226 | 81 | 145 | |
| blind5d | 1 234 | 456 | 778 | |
| blind6e | 238 | 90 | 141 | 7 PLAINFAIL |
| blind7f | 960 | 404 | 556 | |
| blind8g | 121 | 21 | 100 | |
| bounded-walk | 34 | 5 | 23 | 6 BOTHFAIL |
| callbacks-keep | 720 | 108 | 612 | |
| evaluation-order | 440 | 276 | 164 | |
| folds-callbacks | 30 300 | 5 392 | 24 908 | |
| function-values | 1 960 | 304 | 1 656 | |
| handed-back | 2 592 | 0 | 2 592 | |
| recursive-levels | 16 131 | 4 140 | 11 991 | |
| wider-functions | 354 | 144 | 210 | |

`runtime-calls-faults` has 8 programs: report 129's table was made before its review added
`locals-after-limit.dead`.

- **The sanitiser corpus** (`bench/ownership-step0-sanitiser.mjs`, 347 fixtures): 93 same, 254 refused,
  0 traps, differences or crashes, as before.
- **Real writes** (`bench/ownership-v2-review.mjs --checkers=v1,v3 --roots=real`): of the 308 writes v1
  judges, v3 accepts 287, refuses 20 and has no line for 1. The list is the same as on `7c8a25550e`, line
  for line. **No write is lost or won.**
- **Speed** (ReleaseFast LLVM compilers, `--checkers=v1,v2,v3 --runs=3 --jobs=1`): v3 on v2's modules
  (169 846 lines) **550k lines/s before, 540k after** (308.6 → 314.8 ms, 2 %), on a quiet machine;
  an earlier pair of runs, with the first two commits, gave 539k both times.
- **`zig build gates`:** green on each commit.

The sweeps, the sanitiser corpus and the real writes were run again on the compiler of the fourth
commit, with the same results.

## 8. Precision

- **Lost, loudly:** `tests/corpus/ownership/DeepWrittenPath`, `DeepPathThroughList` and
  `DeepWrittenPathCall` reach the module's budget (about 15 million units for about 550 tokens: paths
  more than a hundred levels deep). Each took 100 to 175 ms before, for a module of 40 lines: they are
  the shape the budget exists to stop. v3 is not run on them in the gates. Winning them back needs the
  path that a projection follows for each entry (`Loc.abstractPath`) computed once for each shared
  prefix, not once for each entry.
- **Lost, loudly, as intended:** the generated shapes of §5 that end with the limit.
- **Won:** none.

## 9. The reviews

A fresh reader had the code and the kernel after each commit, and was asked for a program that takes
more than a few seconds, or a limit that accepts.

- **First review** (of the module budget): **found** the uncounted pairs of empty locations (§3.3): 1 000
  three-line functions took 8 s, and a record of 4 000 lists with 600 such functions 16 s, accepted. Fixed,
  with the second test. It also found that "the module passes its budget by at most one entry of the
  table" was wrong: a loop that has begun ends its pass. The kernel says so now, and the walk of a
  construction stops at the budget. **Held:** no write accepted past a limit; the same output at
  `--jobs=1` and `--jobs=8`; the cache trips at the same declaration.
- **Second review** (of that fix): **found** that reading an imported contract was uncounted and done again
  for each importer (§3.4): 120 modules of 7 lines over four types 250 levels deep took 4.2 s of v3,
  accepted. And a module that names large types cost about 0.5 µs of `own2`'s place graph for each place
  (§3.5). Both fixed. **Held:** no limit accepts; the second commit changes no answer except through the
  budget.
- **Third review** (of those fixes): **found** that the facts of derived methods walked every row below
  each row again, and each piece of evidence did the same for each site (§3.6): 7 s for 1 000 types and
  no code; and an imported fact was found by a scan over every fact, 5 s for 600 types over 4 000
  imported ones. Both fixed, with the third test. **Held:** no limit accepts; the last commit changes no
  answer except through the budget; over 700 corpus programs, only the three of §8 dump differently. It
  also found two things this work did not fix. The prepass of `own2` walks the dispatch edges of each
  declaration through every derived row, as the type check does (`Edges.declEdges`), so 3 000 sites of
  `==` over 300 such types cost 6 s, as long as the type check. And three corpus programs panic in
  `checkCovered` (`schema_ctor_top … no walk evaluated`) under `dump --platform=node`, on this work and on
  the commit before it: 54 of the 2 731 ownership roots, all of them programs that name a schema.
- **Fourth review** (of the memo of derived rows): see §10.

## 10. The fourth review, and what is open

**Held:** the memo of derived rows gives what the old code gave. Over 235 corpus and fault programs that
use `==`, `compare`, `where` or `pub eq`, the v3 dumps of the commit before it and of it are the same.
Every change of a contract of the module goes through `contractChanged`; the facts of other modules do
not change; the worklist reaches the least fixpoint; the binary search finds the fact the scan found.

**Fixed:** a first read of a worded contract inside `rowInfo` cleared the read bits set before it, so a
kept answer could miss a later change of another contract. The reader could not reach it from a
program; the bit is set after the read now.

**Open, not fixed: `own2`'s adapter is quadratic in the module.** `Groups.Adapter.ofTerm` makes a new
table, keyed by instruction index, for each constructor argument it describes, so the cost is the
number of arguments times the instruction index. A chain of nominal types, each holding 32 earlier
ones, and one function over the last type, is accepted after 2.75 s (1 000 types), 10.9 s (2 000) and
22.6 s (3 000), against a type check of 0.1 to 0.35 s. On `7c8a25550e` the 2 000-type program took
48 s. The place graph counts its places and steps (§3.5), which grow linearly here; the table does not
show in them. The fix is in `src/own2/Groups.zig` (one table reused for the module, or a sparse one),
which this work did not change. Kernel §8 names it as outside the count.

**Open, not fixed:** `own2`'s prepass walks dispatch edges as the type check does (§9, third review),
and 54 of the 2 731 ownership roots, each a program that names a schema, panic in `checkCovered` on this
work and on the commit before it.

So the bound of §8 holds for v3's own work. Two pieces of `own2` that v3 calls are outside it.
