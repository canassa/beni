# 136 — The ownership kernel v3: a module earns its budget by its work

*Research report, 2026-11-14. A fix of `src/own3/` for the open finding of research report 135 §9: a
module earned its budget for each token of its source, so a large literal earned seconds of work that
its walk never needed, and other declarations of the module spent them. The kernel is
`ownership-v3-kernel.md`; this report changes its §8. Nothing in `src/own/`, `src/own2/`, a platform or a
runtime changed.*

---

## 1. Result

- **A literal earns about what its walk costs.** Report 135's program (six modules of 200 lines, each a
  literal of 9 000 numbers and 30 functions over nested pairs of 4 096 lists) took 5.7 s of v3 at
  `--jobs=1`; it now takes 0.11 s, and each module stops at its own budget at its first such function.
  Negated numbers, strings, `Maybe`s, tuples and records of literals end the same way (0.11 to 0.19 s).
- **No real root comes closer to a budget.** `TailModConsBranches` went from 0.92 to 0.85 of its module
  budget, `NotesApp` from 0.33 to 0.29. No root reaches a budget it did not reach before.
  `DeepWrittenPath` passed its module budget before and does 0.95 of it now (won).
- **The sweeps, the sanitiser corpus and the real writes are the same**, program for program, but one
  fault program (§7).
- **Not closed, and the reason I stopped.** Two things that the rule cannot fix by what it counts:
  - The gates fail on one test. `blind8g-faults/group-rounds-control.dead`, a safe probe that a gate
    test pins as accepted, is now refused at its module budget, and `runtime-calls-faults/locals-after-limit.dead`
    reaches the module's budget before the declaration's, which the same test pins (§7, §9).
  - Dense lines of cheap references or calls still earn 32 768 units an instruction, and a function over a
    large type spends them: 2 059 formatted lines took 4.4 s (§4, §9).
  Both have one cause: the walk of a declaration over a large type costs about the square of the
  type's layout, and no count of instructions follows that. The fix is a decision of rule (§9).

## 2. The rule before

A module could do 65 536 units of work, and 16 384 more for each token of its source (or each
instruction, where it had more), and never more than 2²⁷ (report 135's cap). A token of a literal
earned as much as a token of a call. But the walk of a literal is cheap: it evaluates each element once,
one call of the walk, 32 units. So a module with a literal of 9 000 numbers on one line earned the cap,
and 30 functions `f p = p` over nested pairs of 4 096 lists (8.8 million units each, for 4
instructions) spent it. Six such modules, 1 261 lines, took 5.7 s of v3 at `--jobs=1` (report 135 §8).

## 3. The rule now

A module earns for what its walks can cost (`Mod.earnedUnits`, kernel §8). One pass over its
instructions, in their order:

| What | Units | Why |
|---|---:|---|
| an instruction that a walk evaluates: a reference, a call, a binding, a pattern, a `case` and its arms, a function, a record update, a markup site, a list of things that are not literals | 32 768 (`inst_units`) | the walks of a declaration grow faster than its size; the most that a module of an ownership root needs is 18 900 for each of its instructions (`TailModConsBranches`) |
| an instruction of a literal | 128 (`literal_units`) | the walk evaluates it once: 32 units for each number of a list, 80 for each level of a tuple nested 511 deep |
| a pair of two lists in a literal | 2 (`pair_units`) | a list is a cell, and the walk tests each pair of the cells of a value (`deriveLinear`): a literal of `n` fresh lists took about n²/2 + 142·n units |
| an instruction of a type or of a schema's plan | 128 (`type_units`) | no walk evaluates it; the location table counts what it builds: 48 units for each level of an annotation nested 511 deep |

A literal is a number, a character, a string, `⊤`, a constructor, a negated number, and a tuple, a list,
a record or a constructor applied whose elements are all literals. A negated number is a call of
`Basics.negate` (`Lower`): the call and the reference to `negate` are both part of the literal.

The module's floor (65 536) and its cap (2²⁷) stay. Each module has its own budget. It depends only on the
module's own instructions, so it is the same at any `--jobs` and in any order of the modules.

**The bound in time.** At 12 ns a unit, the slowest of v3's own walks that report 135 measured, an
instruction that a walk evaluates earns at most 0.4 ms of work, and one of a literal or a type 1.5 µs.
A line that `beni fmt` writes holds up to about 45 evaluated instructions (a call with 20 arguments,
twice, in 93 columns): at most about 18 ms a line. A line of three to five instructions, the common case,
earns 1 to 2 ms. On the shapes of §4 a unit took 5.4 ns (ReleaseFast, LLVM): 805 million units in
4.4 s.

## 4. Shapes

Six modules each, at `--jobs=1`, v3's time from `--self-profile`. ReleaseFast LLVM after; the
before is report 135 §8 (ReleaseSafe LLVM, 5.7 s for the first row) and the gates' compiler (19.7 s for
the test of §6). Each module also has the nested-pair aliases and 30 functions `f p = p` over them, which
spend whatever the module earns.

| Shape (one line in each module unless said) | Lines | v3 after | v3 a 1 000 lines | Ends at |
|---|---:|---:|---:|---|
| a list of 9 000 numbers (report 135) | 1 261 | 0.11 s | 0.08 s | own budget, `f0` |
| 9 000 negated numbers | 1 259 | 0.19 s | 0.15 s | own budget |
| 3 000 tuples of a number, a negated number and a string | 1 259 | 0.15 s | 0.12 s | own budget |
| 9 000 empty lists `[ [], [], … ]` | 1 259 | 0.58 s | 0.46 s | the declaration's steps, at the literal |
| 9 000 reads of a parameter `[ k, k, … ]` | 1 259 | 4.4 s | 3.5 s | the cap |
| a record of 9 000 fields `{ a0 = k, … }` | 1 271 | 4.4 s | 3.5 s | the cap |
| `k + k + … ` 4 000 times | 1 259 | 4.4 s | 3.5 s | the cap |
| a `case` of 9 000 arms, formatted | 163 271 | 4.4 s | 0.03 s | the cap |
| formatted: 40 functions of two calls with 20 arguments | 2 159 | 2.1 s | 0.97 s | own budget |
| formatted (the review): a list of 190 calls with 20 arguments | 2 059 | 4.4 s | 2.1 s | the cap |

Literals now end fast. The last five rows earn by instructions that a walk evaluates: the decision
keeps those at a fixed rate, and §9 says why that rate cannot match their walk.

## 5. Real programs and margins

Every ownership root (2 314 programs, 2 884 distinct modules), dumped under `--ownership=v3` with a
measuring line that printed each module's units and budget, before and after:

- **The units of every module are the same**, so every walk did the same work: no verdict moved but through
  a budget. One module changed its verdict: `DeepWrittenPath` passed its budget before (1.84) and does
  0.95 of it now. `DeepPathThroughList` passes its budget before and after.
- Closest to the budget after, with before: `TailModConsBranches` 0.85 (0.92), `OwnershipAnnotationDag`
  0.67 (0.88), `EvidenceDagBuildDepth32` 0.48 (0.58), `check/depth/InferredOk` 0.42 (0.002),
  `PatternWideFresh1000` 0.35 (0.01), `NotesApp` 0.29 (0.33), `ConduitEditor` 0.26 (0.28).
- The median module's budget is the same (1.00 times), the largest grew 1.84 times, and modules with large
  literals or types lost nearly all of theirs.

How the constants were set: `inst_units` from `TailModConsBranches` (8.9 million units over 473
instructions; at 16 384 a non-literal instruction it would be at 1.26 of its budget, at 24 576 at 0.98);
`literal_units` and `type_units` from `InferredOk` and `AnnotationOk` (80 and 48 units an instruction);
`pair_units` from literals of 250 to 4 000 fresh lists (0.49 n² + 142 n units).

## 6. Tests

`tests/blackbox/check_test.zig`, *a literal earns what its walk costs, not what its tokens would*: six
modules, each with a literal of 3 000 tuples of a number, a negated number and a string on one line, and
30 functions `f p = p` over nested pairs of 4 096 lists. Each module must reach its own budget at `f0`,
not the cap, within 10 s at `--jobs=1` on the gates' compiler. It takes 1.3 s. Run on `a982e4641d` in a
second worktree, the check did not end in 10 s (19.7 s measured; every module reached the cap at `f15`).

*A table of literal rows beside a name is accepted*: a list of 1 400 literal rows headed by a name, and 8
groups of 250 such rows. The first was refused on `47f11a817a`, the second on `f233b3815c` (§8).

The tests of report 135 still pass with their programs unchanged: the cap (*no module does more than the
most for any module*: eight chains of 400 writes still earn more than the cap), the module past its
budget that publishes nothing (*in any order*), and *one budget for each module, in proportion to its
size*.

## 7. Gates

All on the self-hosted ReleaseSafe compiler of `54c5bfc41f`. The before is report 135 §7.

**The sweeps** (`run.mjs --checker=v3`, every generator and fault folder): 82 716 programs. 0 TRAP, DIFF
or CRASH, and no timeout. Every folder has the same SAME and REFUSED counts as report 135's after, but
one: `blind8g-faults` SAME 4 → 3, REFUSED 4 → 5. The changed program is `group-rounds-control.dead`, the
safe control of `group-rounds-slow`: it needs 23.0 million units (one declaration over nested pairs of
1 024 lists does 20.6 million) and earns 16.5 million, because its 164 numbers and its small lists of them
earn 128 an instruction now. Before, its tokens earned about 33 million.

**The sanitiser corpus**: 347 fixtures, 93 same, 254 refused, 0 traps, differences or crashes, as before.

**Real writes** (`--checkers=v1,v3 --roots=real`): of the 308 writes v1 judges, v3 accepts 287, refuses
20 and has no line for 1, as before. No write is lost or won.

**Speed** (ReleaseFast LLVM, `--checkers=v1,v2,v3 --runs=3 --jobs=1`, two runs): v3 on v2's modules at
586k and 612k lines/s (289.6 and 277.5 ms for 169 846 lines), against report 135's 629k and 635k on a
quieter machine. The new pass is one walk of each module's instructions; I did not build the base with
LLVM to measure the two on one machine.

**`zig build gates`: red, one test.** *runtime calls into the program, and one step budget per
declaration* wants `group-rounds-control.dead` accepted (it is refused at the module budget) and
`locals-after-limit.dead` refused at the declaration's steps (it is refused at the module's budget, 20.8
million: its record of 2 040 lists is a type, and earns 128 an instruction now). Every other test passes
(1 974 of 1 991, 16 skipped). I did not change the test: it pins what the rule of report 129 and 130
promised, and changing it is the owner's call (§9).

## 8. The review

Three fresh readers had the code and the kernel, not this report.

- **First reader. Found, not fixed: dense references still buy the cap.** Six formatted modules of 340
  lines, each a list of 190 calls `g zz … zz` with 20 arguments beside 16 functions over the pairs, take
  43 s on the gates' compiler (4.4 s ReleaseFast). Each reference earns 32 768 units and costs a few
  hundred; the module pools them, and the functions over the pairs spend them. §9.
- **First reader. Found, fixed: a table of literal rows beside one name was refused.** `[ first, [ 0, 1 ],
  … ]` with 1 400 rows passed the module budget, because only a literal earned the pairs of its lists. Every
  construction earns the pairs of the literal lists in it now (`f233b3815c`).
- **Second reader. Found, fixed: the same, one level down.** 8 groups of 250 rows, each headed by the name,
  were refused: a construction that was no literal handed on no cells. Every construction hands on its cells
  now (`54c5bfc41f`). The test *a table of literal rows beside a name is accepted* checks both shapes; on
  `47f11a817a` and `f233b3815c` respectively each was refused.
- **Second reader. Found, not fixed: a function that answers a large literal of lists is walked again in
  each caller**, and the re-test of the pairs earns nothing: `rows base = [ [ base, base ], … 1 400 ]` with
  one caller is refused. A refusal only, loud, of a probe.
- **Third reader. Found, not fixed: a group built by a call** (`[ List.reverse [ first, … ], … ]`) breaks
  the count of cells, and 2 500 rows are refused. The cells of a call's answer are not known before the walk.
- **Third reader, outside this change:** a literal list nested 400 deep (63 lines) takes 6.5 s of v3 and
  is then refused with a budget of 384 752 units: that time is work that no unit counts. About 8 000 literal
  list cells reach the declaration's steps.
- **Held:** each pair is earned once at any depth; the arithmetic saturates; a negated number's reference is
  counted once; a classification that fails only earns more; the budget depends only on the module's own
  instructions, so it is the same at any `--jobs`. A table of 4 000 records with lists and tuples is
  accepted in 0.86 s.

## 9. What is open

- **I stopped here.** The gates are red on one test (§7), and the target (no check more than a few
  seconds per few thousand lines) is met for literals but not for dense evaluated code (§4). Both come
  from one fact: a declaration over a large type costs about the square of its layout (`f p = p` over
  nested pairs of 4 096 lists: 8.8 million units for 4 instructions), and the module's budget is pooled.
  A count of instructions either earns too little for such a declaration (so a safe module that used to be
  paid for by its literals is refused) or too much for a cheap one (so cheap lines pay for it). Three ways
  out, each a change of rule, and the owner's:
  1. **Earn by layout entries**: an instruction earns for the entries of its type's layout. To follow the
     cost it must grow with the square of the layout, so one annotation line over a large type would earn
     millions; the rule then bounds work by the types a program names, not by its lines.
  2. **A declaration spends only what its own instructions earn**, and a floor. This ends the pooling that
     both the attack and `group-rounds-control` rely on, but refuses every small function over a large
     type, real or not; the data of §5 would have to show that no real root has one.
  3. **Accept the refusals**: `group-rounds-control` is the same shape as the attack (literals earn, a
     function over a large type spends), and change the test to want its module's limit. This keeps the
     dense-code gap.
  My recommendation is 2, measured on every root first, because only it makes a line's time bounded by
  the line, but I have not built it.
- A function that answers a large literal of lists, or groups built by calls, earn nothing for the pairs
  that each caller's walk tests (§8): refusals of probes.
- A literal list nested 400 deep takes 6.5 s of uncounted work (§8).
- The commits are on the local branch `fix136`, not pushed: they would make the gates of #2451 red.

## 10. How to reproduce

```sh
git worktree add -b fix136 wt origin/ownership-v2-design-review
(cd wt && zig build beni-fmt-check)            # zig-out/safe/bin/beni, self-hosted ReleaseSafe
for g in bench/ownership-sweeps/*.mjs; do node $g sweeps/$(basename $g .mjs); done   # not run.mjs
node bench/ownership-sweeps/run.mjs --beni=<compiler> --checker=v3 --jobs=24 --tmp=<disk> sweeps/<name>
node bench/ownership-step0-sanitiser.mjs --beni=<compiler> --jobs=14
node bench/ownership-v2-review.mjs --beni=<compiler> --checkers=v1,v3 --roots=real --runs=1 --jobs=8
node bench/ownership-v2-review.mjs --beni=<ReleaseFast compiler> --checkers=v1,v2,v3 --roots=real --runs=3 --jobs=1
zig build test-blackbox-check "-Dtest-filter=ownership v3: a literal earns"
```

The units of a module need a measuring line that is not in the commits: print `m.module_units +
m.loc.units` and `m.module_budget` at the end of `Check.checkModule`.

## 11. What became of §9 (research report 138)

Research report 138 took the way out that §9 recommended, after it made the walks that grew with the
square of a type about linear:

- **The duplicate test is about linear in the cells** (`Frame.runsShare`). `f p = p` over nested pairs of
  4 096 lists costs 0.43 million units, not 8.8 million, with the same answer.
- **A declaration spends only what its own instructions earn** (kernel §8, `Mod.declBudget`): 2²⁰, what
  §3's table gives its instructions, and 128 units for each entry of the layout of each instruction that a
  walk evaluates, at most 2²⁵; the location table's work counts against the module alone. The module's budget is the sum of its declarations' and of its types', with
  §2's floor and the cap of 2²⁷. Nothing is pooled, so cheap lines pay for nothing beside them.
- **The two red tests pass for their reasons.** `group-rounds-control.dead` is accepted (`rot` costs 21
  million units and earns the most for a declaration), and `locals-after-limit.dead` stops at its
  declaration's limit of 33 554 432 units. `group-rounds-slow.dead` now stops there too, not at the
  module's.
- **The shapes of §4 are accepted**, at 0.06 to 0.13 s of v3 for a thousand lines (ReleaseFast, LLVM).
- **The literal nested 400 deep** made a projection for each level after the budget was passed; it stops
  at its module's budget in about 0.3 s on the gates' compiler, not 4.1 s.
