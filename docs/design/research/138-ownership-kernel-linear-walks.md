# 138 — The ownership kernel v3: walks about linear, and a budget for each declaration

*Research report, 2026-11-14. A fix of `src/own3/` that follows research report 136 §9. Two walks of
`--ownership=v3` grew faster than the program, so no count of instructions could pay for them. They are
about linear now, with the same answers. Then each declaration spends only what its own instructions
earn. The kernel is `ownership-v3-kernel.md`; this report changes its §4.2, §4.4 and §8. Nothing in
`src/own/`, `src/own2/`, a platform or a runtime changed.*

---

## 1. Result

- **The duplicate test is about linear in the cells.** `f p = p` over nested pairs of 4 096 lists cost
  8.8 million units for 4 instructions. It costs 0.43 million now, and every answer is the same.
- **A recursive group with a recursive local function settles.** `TailModConsBranches.chunks` was walked
  66 times and stopped at "the group did not settle" (8.9 million units). It settles now (16 000 units
  in all) and publishes a contract.
- **Each declaration spends only what it earns.** The budget is no longer pooled over the module.
- **No ownership root is newly refused.** Of the 2 314 roots, two dumps changed: `TailModConsBranches`
  (its group settles) and `DeepPathThroughList` (refused at its module's budget before and after; the
  budget in its limit line is larger).
- **Every shape of reports 135 and 136 is accepted**, at 0.06 to 0.13 s of v3 for a thousand lines
  (ReleaseFast, LLVM, `--jobs=1`). Before, they stopped at a budget after 1.2 to 3.4 s a thousand lines.
- **The literal nested 400 deep** takes 0.33 s on the gates' compiler, not 4.2 s.
- **The two red tests of report 136 pass** for their reasons (§6).

## 2. The duplicate test

A summary location can hold one cell at two places, and a value built from parts can hold one cell in two
parts (kernel §4.4). Six places test this: `partDup` (the parts of a construction or a list), `deriveLinear`
(the entries of a root), `finish` (the entries of a result), `operandLeaves`, `runsApart` and
`expandSrcs`. Each compared every pair of runs, atom by atom (`dupOverlap`). That is the square of the
cells: 8.4 million pairs for the 4 096 lists of `f p = p`, and each part of a list compared with every part
before it.

**The new test** (`Frame.runsShare`) gives the same answer for a set of runs. Two atoms are one cell when
they have the same root and entry, comparable paths, and were not read through two apart parts of one
root (`viaApart`). With a selection (`deriveLinear` with a callee's claim), a pair counts only when one of
its runs is selected. The test:

1. Takes the runs one at a time. Each atom of a run is tested against the atoms of the runs before it;
   then the run's atoms are added. So a pair of atoms from one run is never tested. The largest run is
   taken last: it is only looked up, never added.
2. Puts each atom in the group of its root and entry, one lookup. Only atoms of one group can overlap.
3. Compares each pair in a group of at most 32 atoms. So the cost is at most 32 for each atom.
4. Gives a larger group tables by path. For each path a table keeps two atoms at that path, and two at
   that path or below it. The two have different `via` keys: 0 for an atom that no other can be apart
   from (no `via`, or a `via` root that is not linear), else the `via`. An atom looks up its own path for
   atoms at or below it, and each path above it to the group's shallowest. If any atom there has a
   different `via` key, one of the two kept has, and it is one cell with the atom. A group has a table of
   all its atoms and one of its selected atoms, so the selection needs no third key.
5. Gives the atoms read through one part (`via`, `via_e`) their own tables. A pair found there is
   tested for its `via_path`. If that fails, the atom is compared with each atom of its part: the only
   place where the test can still cost the square, and it is counted.

Each atom grouped, and each path looked up or added to, is a lookup (4 units); each pair compared is a
unit. Past the budget the answer is "one cell", as before.

**The same answers.** A set of at most 64 atoms keeps the old test, and its old cost. In a safe build,
each such set is also tested by `runsShare` twice, with groups compared in pairs and with every group in
tables, and both answers must be the old one (`checkShare`). The 2 314 roots and every sweep run on the
safe build, so that check ran on every small set they made. The large sets are checked by the dumps:
every dump is the same, but the two of §1.

**Two tests that need no answer.** `expandSrcs` and the `partDup` sites skip the test when the location is
already `twice` or a part already holds a cell twice: the answer is "yes" either way.

**The walk of a construction.** `finish` walks each entry of the result. For a construction of many parts
the walk of one entry looked up the projection of every part: a record of 800 fields cost 640 000
lookups. A walk of at most 8 entries now reads only the parts that hold a location at one of them
(`builtIndex`, made once in a frame). A part that holds none added nothing, so the walk finds the same
atoms in the same order.

## 3. The groups that walked many times

| Declaration | Before (units, walks) | After | Why |
|---|---:|---:|---|
| `tests/corpus/run` `TailModConsBranches.chunks` | 8.9 M, 66, "did not settle" | 16 000, settles | a local function's contract named its own cells again in each walk |
| `bench/corpus` `NotesApp.viewSidebar` | 5.0 M, 1 | 1.85 M | not a group: the duplicate test of its markup's parts |
| `NotesApp.view` | 0.93 M | 0.76 M | the same |
| `core` `Dict.descend` | 1.4 M, 4 | 0.93 M | the pairs of 16 sources of each of 12 entries, in each call (`expandSrcs`) |
| platform `Ui.Html.map` | 1.8 M, 3 | 1.58 M | the duplicate test of its parts; the rest is linear work |
| `f p = p` over nested pairs of 4 096 lists | 8.8 M | 0.43 M | the duplicate test of the result's 4 096 entries |

**Why `chunks` never settled.** `chunks` holds a local function `first` that calls itself. `solveCodes`
solves `first`'s rounds inside each walk of `chunks`. It starts them from `first`'s contract of the walk
before. That contract was taken out of the drafts when its rounds ended, so in the next walk it was read
as a finished contract. A finished contract names the cells of a callee by the call and the callee's site
(kernel §4.2). So `first`'s recursive call named its cells again, with new names, and each walk of
`chunks` added four names to its result. The fix: a contract of an earlier walk is a draft while the rounds
run, as a bottom contract is. A draft names its cells by the call alone, so the names stop growing. This is
the rule that bounds the names of every other recursion; nothing new is assumed.

**The others** were not groups that failed to settle. `Dict.descend` and `Ui.Html.map` settle in 4 and 3
walks, and each walk costs what it reads: the contracts of their callees. `NotesApp` reads markup values
whose contracts hold hundreds of sources. What remains is the copy of those atoms and their dedup
(`uniqueTail`), linear in them.

## 4. The budget

**The rule** (`Mod.declBudget`, kernel §8). A declaration may do, over all of its walks, including the
location table's work in them:

    min(2²⁰ + Σ its instructions' earnings + 128 · Σ layout entries of its evaluated instructions, 2²⁵)

The location table's work counts against the module alone, not the declaration: the table keeps what it
built for the whole module, so the first declaration to need a layout or a projection pays for it, and which
one that is depends on their order (§8). Each declaration's budget is made before any walk. An instruction earns as report 136 §3 says: 32 768 if a walk evaluates it, 128 for a literal or a type,
and 2 for each pair of lists that a construction brings together. A module's budget is 65 536, plus the
earnings of its instructions, plus 2²⁰ for each value declaration, plus the layout terms of the
declarations it walks, and never more than 2²⁷. So a module passes its own budget only by the work of its
types or by the cap.

**How the constants were chosen.** A measuring build printed each declaration's cost and its parts of the
budget, for all 2 314 roots (14 204 distinct declarations), with no budget:

| Floor | Per instruction | Per layout entry | Declarations over | Closest |
|---:|---:|---:|---|---|
| 2²⁰ | 32 768 | 128 | 0 | `Ui.Html.map` 0.59, `NotesApp.viewSidebar` 0.56, `Dict.descend` 0.52 |
| 2²⁰ | 32 768 | 64 | 0 | the same |
| 2²⁰ | 16 384 | 128 | 0 | `viewSidebar` and `Html.map` 0.84 |
| 2²⁰ | 8 192 | 128 | 2: `viewSidebar`, `Html.map` | |
| 2²⁰ | 4 096 | 128 | 4 | |
| 2¹⁸ | 4 096 | 128 | 8 | |
| 2¹⁸ | 32 768 | 128 | 0 | `Dict.descend` 0.93, `NotesApp.view` 0.91 |

I kept report 136's 32 768 for each instruction, the first row: it is the one with room for the small
functions that read large contracts (`Dict.descend`: 22 instructions, 0.93 million units). The layout term
is what lets the functions over the largest types (`f p = p`, `group-rounds-control`'s `rot`) do their
linear work; without it `rot`, 21 million units, earns 17 million. The module closest to its budget is
`DeepPathThroughList`, which passes it as before (its location table costs about 450 units for each layout
entry, quadratic in the depth of its paths); then `DeepWrittenPath` at 0.59.

**The bound.** A declaration does at most 2²⁵ units, and a module at most 2²⁷: at the 2.2 ns a unit
measured where a module reaches its cap, 0.3 s (ReleaseFast). Within that, a line pays for itself: an
instruction earns at most 32 768 + 128 · 4 096 units (a layout has at most 4 096 entries), so a line
over small types earns a fraction of a millisecond, and a line that walks the largest layouts many
times earns more, in proportion to the entries it walks. The walks the budget pays for are about
linear in those entries now (41 to 270 units for each entry of each instruction on the shapes of §5).

## 5. Shapes

v3's time from `--self-profile`, `--jobs=1`, ReleaseFast LLVM, base `a982e4641d` and after, built and
run on one machine. Six modules each (one for `deep400`, `groupscall` and `rowsfn`), as generated: a
dense line is one line. The first ten rows are the shapes of reports 135 and 136 and of the measurements
that led here.

| Shape | Lines | Base: v3, ends at | After: v3, ends at | After, a thousand lines |
|---|---:|---|---|---:|
| a list of 9 000 numbers, 30 `f p = p` | 1 260 | 4.30 s, the cap | 0.15 s, accepted | 0.12 s |
| 9 000 negated numbers | 1 260 | 4.31 s, the cap | 0.16 s, accepted | 0.13 s |
| 9 000 reads of a parameter | 1 260 | 4.32 s, the cap | 0.15 s, accepted | 0.12 s |
| a record of 9 000 fields | 1 260 | 4.34 s, the cap | 0.17 s, accepted | 0.13 s |
| `k + k + …` 4 000 times | 1 260 | 4.32 s, the cap | 0.16 s, accepted | 0.13 s |
| a list of 190 calls with 20 arguments | 870 | 2.38 s, the cap | 0.09 s, accepted | 0.11 s |
| 40 functions of two calls with 20 arguments | 2 460 | 1.32 s, module budget | 0.14 s, accepted | 0.06 s |
| 30 functions with a list of 45 references, answering nested pairs of 4 096 lists | 1 410 | 1.71 s, module budget | 0.15 s, accepted | 0.11 s |
| the same, 130 references | 1 410 | 4.34 s, the cap | 0.14 s, accepted | 0.10 s |
| 30 `f p = p` alone | 210 | 0.04 s, module budget | 0.03 s, accepted | 0.16 s |
| a literal list nested 400 deep | 65 | 0.23 s, module budget | 0.06 s, its declaration's budget | — |
| 30 functions each a list of 45 references to nested pairs of 2 048 lists | 1 230 | 0.85 s, module budget | 0.93 s, accepted | 0.75 s |
| 30 functions each a list of 45 calls of a function over them | 1 260 | 0.42 s, a declaration's steps | 1.76 s, the cap | 1.40 s |

The last two rows are the slowest shapes I found. They are linear work, not a square: 41 units for each
entry of each reference, and 270 for each entry of each call (`applyAt` reads the callee's contract
entry by entry). The last one reaches the cap of each module, which bounds it at 0.3 s a module. In each
list of 45 a formatter writes one element a line, so the lines `beni fmt` writes are many more.

## 6. Tests

`tests/blackbox/check_test.zig`, each run on the gates' compiler; on `a982e4641d` (in a second worktree)
each fails:

- *The duplicate test of a value is linear in its cells*: 20 functions `f p = p` over nested pairs of
  4 096 lists and 5 lists of 8 references to nested pairs of 2 048 lists, accepted, 0.54 s. Base: refused
  at the module's budget.
- *A group whose local function calls itself settles*: `chunks`, with its contract in the dump. Base: no
  contract, the module's budget passed in the group's rounds.
- *A declaration spends what its own instructions earn*: two modules of 30 functions that each hold a list
  of 45 references and answer nested pairs of 4 096 lists, accepted, 0.74 s. Base: refused at the
  module's budget after 2.8 s.

**The two red tests of report 136**, in *runtime calls into the program, and one step budget per
declaration*: `group-rounds-control.dead` is accepted (its `rot` costs 21 million units and earns the
cap of a declaration); `locals-after-limit.dead` stops at its declaration's limit, "the walk took more
than 33554432 steps" (200 local functions over a record of 2 040 lists cost 42 million). The same test
wanted `group-rounds-slow.dead` at the module's limit; it stops at its declaration's now, and the test
says so.

Four tests pinned the pooled budget, and say what the new rule does with the same programs:
- *One budget for each module, in proportion to its size*: `g0`, a record update over 2 040 fields, passes
  its own budget (0.7 s).
- *A literal earns what its walk costs, not what its tokens would*: six modules of a literal and 30
  `f p = p` are accepted.
- *A module past its budget publishes no contract, in any order*: the heavy declaration is now a literal
  list nested 200 deep, which passes its own budget; the module still publishes nothing, in either order.

## 7. Gates

(below)

## 8. The review

(below)

## 9. What is open

- **The deep-path programs pass their module's budget.** Their location tables cost about 450 units for
  each layout entry, quadratic in the depth of their paths. `DeepPathThroughList` was refused for it
  before and is now.
- **A record update over many fields** walks each field for each entry it projects (`project` of a
  `built` value scans its parts): the record of 2 040 fields in *one budget for each module* passes its
  declaration's budget. It is counted.
- **A literal list nested deep** builds layouts whose cost grows with the cube of the depth: 100 levels
  pass the declaration's budget. It is counted, and stops in 0.33 s at 400 levels on the gates' compiler.
- **Reading a large contract** costs about 270 units for each of its entries at each call. A program of
  many calls of a function over the largest layouts reaches the module's cap (§5).

## 10. How to reproduce

```sh
git worktree add -b fix wt origin/ownership-v2-design-review
(cd wt && zig build beni-fmt-check)            # zig-out/safe/bin/beni, self-hosted ReleaseSafe
zig build install -Doptimize=ReleaseFast -p rf # the LLVM compiler for the times of §5
node bench/ownership-sweeps/run.mjs --beni=<compiler> --checker=v3 --jobs=20 --tmp=<disk> <folder>
zig build test-blackbox-check "-Dtest-filter=ownership v3"
```

The units of a declaration need a measuring line that is not in the commits: print `m.decl_steps[di] +
m.decl_loc[di]` and `m.decl_budget[di]` for each declaration at the end of `Check.checkModule`, with
`Mod.overBudget` made false.
