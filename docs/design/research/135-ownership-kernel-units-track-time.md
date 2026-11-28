# 135 — The ownership kernel v3: a unit tracks time

*Research report, 2026-11-14. A fix of `src/own3/` for the open findings of research report 134 §7–§8:
a chain of `case` reads into a recursive type did exponential work, a unit of the budget could stand for
about 0.1 µs, and the counted work of a chain of writes was quadratic with a large constant. The kernel is
`ownership-v3-kernel.md`; this report changes its §8 and §9. Nothing in `src/own/`, `src/own2/`, a platform
or a runtime changed.*

---

## 1. Result

- **A unit tracks time.** Over the 101 measured programs that do more than 5 million units, a unit takes
  4.9 ns at the median and 8.3 ns at the 90th percentile (LLVM ReleaseSafe). Before, the 90th percentile
  was 83 ns and the worst 108 ns. The worst where v3's own code takes the time is now 12 ns.
- **No measured program takes more than 1 s of v3 to reach a limit.** Before, eight shapes took 3.1 to
  3.8 s, and the review found modules that took 3.2 and 6.4 s. A declaration now reaches its budget in at
  most 0.45 s, and a module in at most 0.85 s: **no module does more than 2²⁷ units** (`module_cap`, §8),
  so at the slowest unit of v3's own code no module takes more than about 1.6 s to its limit.
- **The exponential is gone.** A chain of `case`s, each of which can answer the value of the `case`
  before it, projected each shared part once for each path to it. A part of a value at one step is now
  made once in a frame. 100 levels took 3.2 s to a limit; now they are accepted in 43 ms.
- **The pairs of a chain of writes cost a step each.** A read of a late name of a chain tests its run of
  old names in one step when all of them are old for the write. About 85 writes in one function passed
  the module's budget; now about 550 pass the declaration's, and report 134's chain of 400 writes is
  accepted. The counted work is still quadratic: one step for each pair of a write and a later read.
- **A module past its budget publishes no contract of a walk** (found by the review). It published
  those of the declarations walked before the limit, so an importer's verdict depended on the order of
  the module's declarations.
- **`Loc.comparable` is counted**, and so are the other loops that were not: copies of runs, the climb of
  a path, the scans of flags, maps and layouts, and the indexes built for each frame.
- **Nothing else moved.** The dumps of all 2 734 ownership roots that check are the same, byte for byte.
  The sweeps have no trap, difference or crash; four programs went from REFUSED to SAME, all chains of
  writes (§7). The real writes are the same, line for line. v3 runs at about 630k lines/s on v2's modules (530k
  before).

## 2. How a unit was calibrated

A build of the same code with one added line printed, for each module, the units of its walks and of
its location table (`Mod.module_units`, `Loc.Table.units`) and the largest declaration's count. The time
of the module came from `--self-profile` (`ownership3_module`). The ratio is the time of a unit. The
measuring line is not in the commits.

The programs, 307 in all:

- the sweeps' every fault folder (136 programs), and a random 150 programs of each generator (3 307;
  these all do 2 to 5 million units, mostly in `core/`, at 4.5 to 9 ns a unit);
- report 131's worst shapes (`worst.mjs`: chains of nominal types, diamonds of aliases, `==` sites,
  schemas);
- report 130's shapes, written again (its generator was not kept): records of 2 040 and 4 000 lists read
  and written at many calls, arms and lets; nested pairs of 4 096 lists through 300 and 1 000 functions;
- the corpus programs nearest their budgets (`TailModConsBranches`, `OwnershipAnnotationDag`,
  `EvidenceDagBuildDepth32`, `RequirementBelowDepth512`, `DeepWrittenPath`, `DeepPathThroughList`);
- new shapes for report 134's open findings: chains of `case` reads into `type Tree = Node (List Int)
  (Maybe Tree) | Leaf`, 5 to 400 levels, where each level answers its projection or the level before
  (`casekeep`), the level two before (`casefib`), or a record of the tree and a list (`caserec`), and
  nested descents and plain chains; chains of 50 to 5 000 writes of one list.

`perf` found where the time of each slow shape went.

## 3. What was slow, and why

LLVM ReleaseSafe, one run each, v3's module time:

| Program | Before: ms, units, ns a unit | After: ms, units, ns a unit | Verdict before → after |
|---|---|---|---|
| `casefib.400` | 3 799, 35.9 M, 106 | 245, 36.0 M, 6.8 | limit → limit |
| `caserec.400` | 3 784, 35.9 M, 105 | 224, 36.0 M, 6.2 | limit → limit |
| `casekeep.400` | 3 684, 35.9 M, 103 | 225, 36.0 M, 6.2 | limit → limit |
| `caserec.100` | 3 663, 35.9 M, 102 | 45, 10.2 M, 4.4 | limit → accepted |
| `casekeep.100` | 3 163, 29.7 M, 107 | 43, 10.2 M, 4.2 | limit → accepted |
| `casefib.100` | 3 170, 29.5 M, 108 | 26, 6.5 M, 4.0 | limit → accepted |
| `casekeep.20` | 682, 8.7 M, 78 | 12, 2.6 M, 4.5 | limit → accepted |
| `writes.5000` | 1 479, 35.9 M, 41 | 436, 36.0 M, 12.1 | limit → limit |
| `writes.400` | 30, 35.9 M, 0.8 | 33, 20.2 M, 1.6 | limit → accepted |
| `deep.K12.N1000` | 951, 168 M, 5.7 | 962, 168 M, 5.7 | limit → limit |
| `readsx.F2040.N8000` | 648, 41.3 M, 16 | 615, 61.8 M, 10.0 | limit → limit |
| `readsy.F2040.N8000` | 448, 3.5 M, 128 | 427, 24.0 M, 17.8 | accepted → accepted |
| `eqtop.300.6000` | 475, 7.9 M, 60 | 492, 8.0 M, 62 | accepted → accepted |
| `OwnershipAnnotationDag` | (module) 0.31 M | (module) 0.64 M | accepted → accepted |

The units are the whole program's, `core/` included (about 2.4 million). The causes:

1. **A DAG of joins copied as a tree** (`casekeep`, `casefib`, `caserec`). `t1 = case t0 of Node _ (Just t)
   → t; _ → t0` is a join of a part of `t0` and `t0` itself. `project` of a join made the join of its arms'
   parts, again for each arm, so the next level made the parts of `t0` twice, and level `n` 2ⁿ times.
   Each projection was counted as its arms, but allocated two lists, looked up a projection and made a
   node: about 0.1 µs a unit.
2. **Sorts and copies of runs of atoms** (`writes`, `casekeep` after the first fix). A name late in a
   chain of writes holds every older name in its run. Each read of a run copied it (`copyAtoms`,
   uncounted), and `uniqueTail` sorted runs of more than 16 atoms, counted as one unit for each atom.
   The test of a demand against a later read counted every atom of the read's run as compared with every
   target, though an old name is compared with nothing.
3. **Scans of a layout or of a contract's flags at each call** (`readsy`). `applyAt` scans the callee's
   flags three times, and `readBy` the call map of the argument, a step each for a record of 2 040 lists,
   at every one of 8 000 calls. None was counted.
4. **Climbs of paths** (`caselet`, a chain of plain projections, 17 to 25 ns a unit at 400 levels). A
   path into a recursive type is as deep as the chain of projections that made it: 800 steps at 400
   levels. `Loc.comparable` climbs one path to the depth of the other, once for each pair of atoms
   compared, counted as one.
5. **`own2`'s code that v3 calls.** In `readsy` most of the remaining time is `own2`'s adapter reading
   the types of 8 000 calls (`Adapter.ofVar`, and the freeing of its tables). In `eqtop` (6 000 `==` sites
   over records whose module declares `pub eq`) it is the pre-pass. Neither is counted, and the type check
   of the same module takes 27 and 15 times as long as v3 (11.5 s, 7.4 s). Not changed here (§9).

## 4. The fixes

### 4.1 A part of a value at a step is made once

`project` keeps the part of each join that it makes, by the join and the step, for the rest of the frame
(`Frame.proj_memo`). The argument that this changes no answer:

- A value is a node of the frame's tables. A node, its kids and its arms never change once made: the one
  write to `lists` is `capVal`'s, which replaces a `later` slot of a closure's captures by the value bound
  there, and a closure's captures are never a join's arms. So `project(v, s)` reads only what was there
  when `v` was made, the location table (whose projections are kept) and the budget.
- Past the budget the part is `unknown` over the value, whether it is kept or made again: the walk has
  given up by then (§3.3), and no line it makes is accepted.
- So the kept part has the same content as a part made again. A second projection gave a new node of
  that content before; now it gives the same node. Every reader of a value reads its content: the walks
  of values and `reach` key their memos by node, and a node of the same content answers the same.

The dumps of the 2 734 ownership roots confirm it: each root that checks dumps the same text (§5).

A chain of `n` `case`s now makes at most one part for each of its values and each step. A part that is a
join is a call (32 units) where it is made and a lookup where it is kept.

### 4.2 An old run is read in one step

The run of a `version` entry (§5.1 of the kernel) holds the older names of its cells, each with the time
from which it is old (`Atom.dead`). For a write at time `t`, an atom with `dead ≥ t` is no holder
(`isOld`): `atomsReach` skips it, and so skips the answer it may hold. A run never changes once its entry
is made, so its lowest `dead` is a fact of the entry: `RunFact.old`, found by one scan the first time a
read asks. A run all of whose atoms are old for the write in judgement reaches nothing (`runReaches`), so
the test answers in one step what the scan answered. A read of a part of a root tests the atoms that
`leaves` would copy where they are (`refReaches`, the atoms of `leavesOwnWalk` and `rootLeaves`; the `via`
that a copy sets is not read by `atomsReach`). Safe builds check, for runs of at most 64 atoms, that a run
skipped as old holds only old names.

In a chain of `n` writes each read of a late name was `n` atoms, for each of the `n` writes before it:
`n³` work. It is now a step for each pair of a write and a later read: `n²`, with no atom scanned twice.

### 4.3 The rest is counted

| Where | What was not counted | Now |
|---|---|---|
| `Frame.comparable`, `Frame.pathPrefix` (`Loc.comparable`, `Loc.pathPrefix`) | the climb of a path to another's depth | 1 unit for each four steps |
| `copyAtoms` | each atom copied out of a run | 1 for each |
| `leafKeep` | the copy into the memo of the walks of values | 1 for each atom |
| `uniqueTail` | a sort of `n` atoms, counted `n` | a hash set kept by the module: `n` plus a lookup for each |
| `atomsReach` | an answer's handed atoms compared with each target | counted as targets; an old name is 1, not the targets |
| `rootReach` | the targets, the part's entries and the root's layout | 1 for each |
| `project` | a projection of a part of a root, of a join | a lookup; a join's part made is a call |
| `applyAt`, `readBy`, `otherReaches`, `keepsOwn`, `writesOwn` | the scans of flags and call maps | a scan of the flags; 1 for each entry of the map |
| `selfAtoms`, `readSelf`, `newItem`, a top-level value | the scan of a layout or a map for one location | a scan |
| `answerOwn`, `answerOfCode`, `DraftSink.answer`, `ownAnswer` | the scans of an answer's layout and map | a scan |
| `meetIndex`, `coverHits` | the index of two layouts, built once for each frame | twice the two layouts |

A scan is `Loc.scanUnits`: one unit, and one for each four words.

## 5. Precision and margins

The ownership roots (every corpus program and every real root, 2 734 of them), dumped with
`--ownership=v3` before and after: every root that checks dumps the same text. Nine roots that do not
build dump their own paths in their errors, which differ between the two worktrees; run in one place
they are the same.

| | Before | After |
|---|---:|---:|
| largest declaration of a root | 8.3 M (`TailModConsBranches`) | 8.9 M |
| largest declaration of a real root | 3.6 M (`NotesApp`) | 5.0 M |
| module closest to its budget | `TailModConsBranches`, 0.86 | 0.92 |
| real root closest to its module budget | `examples/conduit` `Main`, 0.24 | `bench/corpus` `NotesApp`, 0.33 |
| `OwnershipAnnotationDag` (a corpus program) | 0.50 | 0.88 |
| roots past their module budget | 3 (`Deep*`) | the same 3 |

The units of a few programs grew because their work was not counted before: `OwnershipAnnotationDag`
makes one run of 65 536 copies of one atom unique: a sort counted as it costs would be 1 million
units, and the hash set is about 330 000. No root passes a budget it did not pass before.

**Won** (a side effect of counting only the work done and reading old runs in one step; no fact is
new): chains of up to about 550 writes in one function are accepted (about 85 before), and chains of
100 `case` reads into a recursive type (a limit before). **Lost:** none.

## 6. Tests

`tests/blackbox/check_test.zig`, *chains of case reads and of writes end, and a unit tracks time*:
`casekeep`, `casefib` and `caserec` at 100 levels (accepted) and 400 levels (the declaration's limit),
and chains of 400 writes (accepted) and 5 000 writes (the declaration's limit), each in 10 s on the
gates' self-hosted compiler. On it they take 0.4 to 2.4 s. Run on `c3a52dd200` in a second worktree, the
six `case` programs did not end in 10 s and the chain of 400 writes was refused.

Report 134's test *a let that a markup lowering keeps, and a long chain of writes* wanted the module's
limit for `blind10i-faults/chain-of-writes.slow`, 400 writes; it is accepted now, and the sweep runs it
to SAME.

Two tests for the reviews' findings (§8): *no module does more than the most for any module* (eight
chains of 400 writes in one module reach the cap, 1.2 s on the gates' compiler; accepted on the commit
before the cap), and *a module past its budget publishes no contract, in any order* (a function before
or after three functions over nested pairs; the importer's push is refused and the dump prints no
walked contract, in both orders; on `c3a52dd200` the push is accepted when the function comes first).

## 7. Gates

All on LLVM ReleaseSafe compilers of `c3a52dd200` (before) and of this work (after). The "before" of
the sweeps, the sanitiser corpus and the real writes is report 134 §6's "after", which is the same code;
the folders that changed were run again on the before compiler. The sweeps, the sanitiser corpus and
the real writes were run again on the compiler of each fix of the reviews (§8), the last of `46aa4e3821`,
with the same results; the last commit changes only the type of a count.

**The sweeps** (`run.mjs --checker=v3`, every generator and every fault folder):

82 716 programs (report 134's 82 714 and the two `view-let-wrap` programs). 0 TRAP, DIFF or CRASH, before
and after, and no timeout. SAME 17 325 before, 17 329 after. The counts of each folder:

| Folder | Programs | SAME before | SAME after | REFUSED before | REFUSED after | TRAP, DIFF, CRASH after |
|---|---:|---:|---:|---:|---:|---:|
| aliased-arguments | 5160 | 1183 | 1183 | 3977 | 3977 | 0 |
| answers-beside | 240 | 77 | 77 | 163 | 163 | 0 |
| blind | 9792 | 1675 | 1675 | 8117 | 8117 | 0 |
| blind-faults | 24 | 11 | 11 | 13 | 13 | 0 |
| blind10i | 474 | 148 | 151 | 212 | 209 | 0 |
| blind10i-faults | 16 | 6 | 7 | 10 | 9 | 0 |
| blind2 | 1202 | 502 | 502 | 700 | 700 | 0 |
| blind2-faults | 20 | 7 | 7 | 13 | 13 | 0 |
| blind3 | 417 | 160 | 160 | 257 | 257 | 0 |
| blind3-faults | 10 | 3 | 3 | 7 | 7 | 0 |
| blind4a | 160 | 24 | 24 | 136 | 136 | 0 |
| blind4a-faults | 12 | 1 | 1 | 11 | 11 | 0 |
| blind4b | 6596 | 1229 | 1229 | 5367 | 5367 | 0 |
| blind4b-faults | 8 | 4 | 4 | 4 | 4 | 0 |
| blind5c | 226 | 81 | 81 | 145 | 145 | 0 |
| blind5c-faults | 10 | 5 | 5 | 5 | 5 | 0 |
| blind5d | 1234 | 456 | 456 | 778 | 778 | 0 |
| blind5d-faults | 10 | 5 | 5 | 5 | 5 | 0 |
| blind6e | 238 | 90 | 90 | 141 | 141 | 0 |
| blind6e-faults | 12 | 4 | 4 | 8 | 8 | 0 |
| blind7f | 960 | 404 | 404 | 556 | 556 | 0 |
| blind7f-faults | 2 | 0 | 0 | 1 | 1 | 0 |
| blind8g | 121 | 21 | 21 | 100 | 100 | 0 |
| blind8g-faults | 8 | 4 | 4 | 4 | 4 | 0 |
| blind9h | 3213 | 852 | 852 | 2361 | 2361 | 0 |
| bounded-walk | 34 | 5 | 5 | 23 | 23 | 0 |
| bounded-walk-faults | 12 | 2 | 2 | 9 | 9 | 0 |
| callbacks-keep | 720 | 108 | 108 | 612 | 612 | 0 |
| evaluation-order | 440 | 276 | 276 | 164 | 164 | 0 |
| folds-callbacks | 30300 | 5392 | 5392 | 24908 | 24908 | 0 |
| function-values | 1960 | 304 | 304 | 1656 | 1656 | 0 |
| handed-back | 2592 | 0 | 0 | 2592 | 2592 | 0 |
| recursive-levels | 16131 | 4140 | 4140 | 11991 | 11991 | 0 |
| runtime-calls-faults | 8 | 2 | 2 | 6 | 6 | 0 |
| wider-functions | 354 | 144 | 144 | 210 | 210 | 0 |

The four changed verdicts, each REFUSED before and SAME after, are chains of writes of one list, all
`dead` twins: `blind10i/slow.chain100.dead`, `slow.chain200.dead`, `slow.chain400.dead` and
`blind10i-faults/chain-of-writes.slow`. Each passed the module's budget before (§5). The other kinds of
verdict are unchanged: `blind10i` 114 PLAINFAIL, `blind6e` 7 PLAINFAIL, `bounded-walk` 6 BOTHFAIL,
`bounded-walk-faults` and `blind7f-faults` 1 BOTHFAIL each.


**The sanitiser corpus** (`bench/ownership-step0-sanitiser.mjs`): 347 fixtures, before and after the same: 93 same, 254 refused, 0 traps, differences or
crashes.

**Real writes** (`bench/ownership-v2-review.mjs --checkers=v1,v3 --roots=real`): of the 308 writes v1 judges, v3 accepts 287, refuses 20 and has no line
for 1, before and after; every root's lines, demands, verdicts, causes and limits are the same. No write is
lost or won.

**Speed** (ReleaseFast LLVM, v3 on v2's modules, `--checkers=v1,v2,v3 --runs=3 --jobs=1`, two runs each):
v3 at **536k and 534k lines/s before, 632k and 615k after** (317.0 → 268.8 ms and 318.0 → 276.2 ms for 169 846
lines), on the commit before the cap; on the final commit, a second pair: **523k and 530k before, 629k and
635k after**. About 18 % faster: the hash set of `uniqueTail` and the reads of old runs in one step cost
less than the sorts and scans they replace.

**`zig build gates`:** green on the final commit. A first run failed to compile the `wasm32-wasi`
compiler: a scan's units are a `u64`, and `charge` took a `usize`, 32 bits there; it takes a `u64` now.

## 8. The review

A fresh reader had the code and the kernel, not this report, and was asked for a program whose v3 check
takes more than 2 to 3 s, an uncounted loop, or a memo or limit that accepts.

- **Found: a module's budget from its tokens is too large for a small module.** At 16 384 units for each
  token, a literal earns far more budget than its walk costs (a number is one call, 32 units). A module of 360 lines (nested pairs of 4 096 lists,
  a list of the numbers 0 to 14 999 on one line, 60 functions `fK p = p` over the pairs) took 3.2 s to the
  module's limit, and one of 660 lines 6.4 s; 3 000 identity functions over the pairs took 3.2 s, and
  1 000 functions that swap a pair 2.1 s. The work is counted, at about 6.4 ns a unit; the base takes
  the same time. **Fixed:** no module does more than 2²⁷ units (`Check.module_cap`, kernel §8), about 15
  times the most a module of an ownership root does (8.9 million). The four programs now end at the cap
  in 0.78 to 0.85 s. A test (*no module does more than the most for any module*): eight chains of 400
  writes in one module, each accepted alone, reach the cap in 1.2 s on the gates' compiler. On the commit
  before the cap they are accepted; on the base, the first passes the declaration's budget.
  Report 130 §2 rejected a fixed budget for each module, because a program can have many modules. The
  cap is not that budget: the budget is still in proportion to the module's size, and the cap bounds the
  time of each module, not of a build.
- **Noted, not v3:** 3 000 functions `g x y = x == y` over 300 types that each hold 32 earlier ones take
  6.7 s of the type check and 0.02 s of v3 (report 131 §10, `check/Cycles.zig`).
- **Held:** a declaration reached its budget in 0.1 to 0.5 s, at most about 14 ns a unit, on every shape
  the reader tried: the three `case` chains from 100 to 800 levels; chains of `push`, `set`, a record
  field, a pair of lists, `length` reads, nested lists and `if`-joined writes up to 8 000 writes; flat
  `case`s of 30 000 arms and 1 000 nested `if`s; chains of `List.map` and `List.foldl`; mutual recursion,
  local and top-level; DAGs of closures and of a recursive tree. `proj_memo` is sound: the key is
  injective, nodes and arms are only appended, and `project` reads nothing that changes.
  `runReaches` skips only when every atom is old under `isOld`, also with no time in judgement.
  `refReaches` gives the atoms of `leaves`. The hash set keeps the first of each repeat in order. Two
  sanitiser sweeps of 1 056 new programs (chains of 2 to 130 writes with a holder made before a write and
  read after it; the `case` chains with a write at the end and a read of an earlier level) had no trap and
  no difference; every `live` program that could read a stale list was refused.

A second fresh reader reviewed the cap.

- **Found, not fixed: the cap bounds a module, not a program.** Six modules, each a literal of 9 000
  numbers and 30 functions `f p = p` over the pairs (1 238 lines, about 60 000 tokens), take 5.7 s of v3
  at `--jobs=1` and 1.2 s at `--jobs=8`, all of it v3's own walks (11.1 s without the cap). The work of a
  build is linear in its tokens, at about 0.1 ms each, as report 130 chose; a literal earns its tokens'
  units and costs a call for each element. A budget for the program would make one module's verdict depend on the
  others' work, and the order they are checked in (CLAUDE.md rule 5). A budget that a literal does not
  earn changes report 130's rule. Either is the owner's decision; neither is taken here (§9).
- **Found, fixed: a module past its budget still published the contracts of the declarations walked
  before the one that passed it.** So with `pub len l = List.length l` before three functions over the
  pairs, `Main`'s push of a list it handed to `A.len` was accepted, and with `len` after them it was
  refused: the order of a module's declarations changed an importer's verdict. Both builds failed on
  `A`'s limit, so nothing wrong ran. The module publishes no contract now (kernel §8), and a test checks
  both orders (*a module past its budget publishes no contract, in any order*; on the base it fails for
  `len` first).
- **Found, fixed: kernel §8 said a module reaches the cap in at most 1.6 s,** and two sentences before
  gave shapes at 18 and 62 ns a unit. That time is `own2`'s, which no unit counts; §8 says so now.
- **Answered: the cap's test takes 1.2 to 1.5 s** on the gates' compiler. The CPU budget of 1 s is the
  unit tests' (`tests/test_runner.zig`); a black-box case has its own hang guard of 10 s. Any program
  that reaches the cap does 2²⁷ units, so the test cannot be shorter.
- **Held:** with the cap, no ownership root reaches it or takes more than 2 s; output is the same at
  `--jobs=1` and `--jobs=8` and from a cold or a warm cache; the budget is set before the first test of
  it; a member of a recursive group past the budget publishes nothing for any member of the group.

A third reader reviewed the fix of the second finding.

- **Found, fixed: the dump still printed the contracts of the declarations walked before the limit**,
  built before they were cleared, so the text of `dump --stage=ownership` changed with the order of the
  module's declarations. The summaries are built from what the module publishes now, and the test
  checks the dump in both orders.
- **Found, fixed: clearing every contract also dropped a worded declaration's contract**, its words,
  which no walk made (kernel §6.10, §7). Only refusing more, so not unsound, but a module of `core/` or a
  platform past its budget would have made every importer read `List.push` as unknown code. The words
  stay now.
- **Held:** with the fix, both orders refuse the push and print the same; a constant and a function of
  the module past its budget are read as unknown code; no write of that module is authorised (its
  lowering channel is empty past a limit); every path past a budget sets `module_over` (`walkDecl`,
  `solveGroup`, `walkSchema`, `walkExports`, the reads of derived rows); the output is the same from the
  cache and at `--jobs=1` and `--jobs=8`.

A fourth reader reviewed that fix and found no defect. Two effects, both as kernel §7 and §8 say: a
worded contract of a module past its budget is read by its importers again (a worded `fresh` answer of
such a module, pushed by the importer, is accepted in either order; only `core/` and platforms write
words, and none of their modules nears its budget), and a module past the layout limit dumps no
contract (`blind4b-faults/dag-type.hang` printed five; no golden pins them). Held: the kept contracts
are exactly the worded ones; the dump and the check are the same in both orders, at `--jobs=1` and
`--jobs=8`, and from the cache; the safe-build check that a walk that gave up publishes nothing still
holds.





## 9. What is open

- **A program's v3 time is bounded by its tokens, not by a few seconds.** This is the one place where
  the goal of this work (no program's check takes more than a few seconds) and the rule of report 130
  (a budget in proportion to the size of each module) disagree, and the decision is the owner's. Each
  module now ends in at most about 1.6 s, but a program of many modules near their caps takes the sum at
  `--jobs=1`: six modules of 200 lines whose literals of 9 000 numbers earn their budgets take 5.7 s
  (§8). Two ways out, each a change of rule: a token of a literal earns only what its walk costs (a number is one
  call), or a budget for the program, which needs an order of the modules that does not depend
  on the threads (rule 5).
- **The module's cap is a constant.** A real module that needs more than 2²⁷ units is refused, loudly.
  No root comes within 15 times of it; a module of more than about 8 000 tokens now has the cap for its
  budget. A cheaper unit, not a smaller cap, is the way to a faster limit.
- **`own2`'s code that v3 calls is outside the count**: the adapter's reading of types, and the pre-pass.
  On the measured shapes it costs a fraction of the type check of the same module.
- **A record of 2 040 lists made in one function passes the declaration's budget** (`mk`, 33.6 million
  units): `finish` walks each entry of its result through each of its 2 040 parts, counted. That is a
  precision loss of a quadratic walk, not a time hole.
- The counted work of a chain of writes is quadratic: a step for each pair of a write and a later read.
- The exact program of report 134 §7 that took 22 s was not kept. The shapes of §3 are the closest found
  (3.6 to 3.8 s at 400 levels before), and they end in 0.25 s now.

## 10. How to reproduce

```sh
git worktree add --detach base c3a52dd200
(cd base && zig build -Doptimize=ReleaseSafe --prefix ../before)
(cd wt && zig build -Doptimize=ReleaseSafe --prefix ../after)
for g in bench/ownership-sweeps/*.mjs; do node $g sweeps/$(basename $g .mjs); done   # not run.mjs
node bench/ownership-sweeps/run.mjs --beni=<compiler> --checker=v3 --tag=<tag> --jobs=24 --tmp=<disk> sweeps/<name>
node bench/ownership-step0-sanitiser.mjs --beni=<compiler> --jobs=14
node bench/ownership-v2-review.mjs --beni=<compiler> --checkers=v1,v3 --roots=real --runs=1 --jobs=8
node bench/ownership-v2-review.mjs --beni=<ReleaseFast compiler> --checkers=v1,v2,v3 --roots=real --runs=3 --jobs=1
zig build test-blackbox-check "-Dtest-filter=chains of case reads and of writes"
```

The time of a unit needs the measuring line: print `m.module_units + m.loc.units` at the end of
`Check.checkModule`, and divide the module's `ownership3_module` time of `--self-profile` by it.
