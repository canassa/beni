# 127 — The ownership kernel: every walk bounded by design

*Research report, 2026-11-13. Fixes the fault of research report 126 (a v3 check that does not end) in
`src/own3/`, branch `ownership-v2-design-review`, from `36ad2cb1fb`. Kernel §6.8, §6.9 and §8 are
revised. This report is not normative.*

---

## 0. Summary

- **The rule.** `flow` judges each function once for each use that is equal in what the judgment
  reads. A judgment that read nothing above its own use is kept for the rest of the walk. The walks of
  values (`leaves`, `leavesOwn`, `reach`) walk each value once in one walk. What no memo bounds is
  bounded by one loud limit: a declaration's walk takes at most 1 048 576 steps, and past it the
  declaration gives up with an `ownership_limit` line.
- **The complexity argument.** A DAG of `n` closures with `e` captures costs O(e) judgments and O(n)
  value walks; anything else costs at most `max_walk_steps` steps per declaration, and one step is
  polynomial in the size of the layouts it reads. So the work of a module is polynomial in its size.
- **The depth rule is gone.** Kernel §8 said "a `flow` deeper than 16 is the `top` use". The code reset
  the depth to 0 there, so it bounded nothing. Worse, it did not let what the deep use handed the
  function escape: a list handed down 18 closures to one that kept it in a `Ref` was written in place,
  and the `Ref` read the new value. This was a soundness hole, found by this audit (`deep-keeper`).
- **Siblings.** The same blow-up was in the walks of values (`leaves`, `leavesOwn`, `reach`): a record of
  closures that capture the record of the level below, and a DAG of values chosen by `if`. Both are
  fixed. A group of declarations that did not settle in 64 rounds published its last round's contracts;
  it publishes none now.
- **Out of scope, and still open:** a diamond of type aliases (`tests/corpus/check/good/AliasDiamondChain`)
  does not end under v3. The cost is in `src/own2/Groups.zig` (`Adapter.ofTerm`), which v3 shares with
  v2; it is issue #2121. This work does not touch `src/own2/`.

## 1. The rule

### 1.1 One judgment for each use

`flow(v, use)` judges the function value `v` in a location whose holder does `use`. A use is a chain:
a captured function's use (`inner`) is composed with the use of the function that captured it (`up`).
Report 126's DAG reaches one closure by 3ᴺ chains. Each chain is a different use, so a memo by "the
use" does not help. The question is what a judgment reads of the chain.

A judgment reads its own use: the holder's contract (`c`), the holder's contract for this function
(`fnc`), the capture (`j`), the captured values (`args`), the holder (`holder`) and its kind. It can
also read above it:

| What it reads | Where | Treated as |
|---|---|---|
| the use above (`up`), when it is not the default | `resolve` of a parameter of the holder, `lostAnswer`, `EscSink.lost`, `supplyLost` | context: `upOf` records it |
| whether the use above is the default | everywhere `up.kind == .top` is tested | a field of the key (`up_top`) |
| whether a holder above writes what it handed on | `Use.rewrites`, which walked the chain | a fact set where the use is made (`Use.up_rewrites`), a field of the key |
| the key (a hash of the whole chain from the walk's root) | `freshAtom`: a cell a holder made is named by its key | context for every judgment in work |
| a draft of the frame's own function parameter | `flowOwn` | context: the draft changes as the walk goes on |
| what an answer of a function parameter was handed | `noteEscape` of an answer root | context: it grows as the walk goes on |

`flow` saves the lowest depth of a use whose context the judgment read (`ctx_floor`). When the
judgment read nothing above its own use, it is kept in `flow_memo` under its key (`FlowKey`) and its
values, compared exactly. An equal use later in the same walk is not judged again. A judgment met
again while it is in work (`flow_active`) is a function that reaches itself through what it captured:
the walk gives up (kernel §3.3). The memo lives for one walk of `flow` from one call or mention, so the
site of every judgment in it is the same.

Why a kept judgment is safe for an equal use: the effects of a judgment are escapes, demands,
refusals and a draft's supplies. All of them are sets: a second equal judgment adds nothing. And a
kept judgment read nothing that differs between the two uses, so the second would make the same
effects. A judgment that read anything else is judged again on every path, as before.

### 1.2 One walk for each value

`leaves(v)` of a closure is the cells of everything it captured. A record of three closures that each
capture the record of the level below makes `leaves` walk 3ᴺ paths, and so does a value chosen by `if`
among three values of the level below (`leavesOwn` of a `join`). In one walk of values, each value is
walked once for each set of entries (`leafHit`, `leafKeep`). Where the walk reaches it again, it copies
the atoms it found, without repeats (`uniqueTail`), and the value's own `dup`. The atoms of a value are
a set, and `dup` is the value's own, so the copy is what a second walk finds; `partDup` between two
parts still sees one cell in both. `reach` keeps the values it reached in one walk (`reach_seen`): a
value reached before did not reach the target, or the walk would have ended.

### 1.3 No depth limit

The old rule cut `flow` at depth 16 and went on at the `top` use with depth 0. So the cut repeated
every 16 levels and bounded nothing. It also lost a fact: the `top` use hands nothing, so what the cut
use handed the function never escaped. `deep-keeper.live` (§3) was accepted and trapped. With the memo,
a depth limit is not needed for a DAG, and a cycle gives up. So `flow` follows every use; a use whose
callee loses the function (`Fn.lost`) is the only one that goes to the default (`lostAt`).

### 1.4 The step limit

Some walks read the chain above them on every path, so no memo keeps them: a closure that hands its
own parameter down one of three captured closures, which write it (`climb`), and closures that hand a
new list down (the key names it). Their work is bounded by `Check.max_walk_steps`: each call of
`flow`, `resolve`, `answerOf`, `answerOfCode`, `leaves`, `leavesOwn`, `reach`, `partsOf`,
`ownSupply`, `answerOwn` and `expandSrcs` is a step (`Frame.tick`). Past 1 048 576 steps every walk
returns at once, the declaration gives up, publishes no contract, and the module has an
`ownership_limit` line: "the walk took more than 1048576 steps (a function or a value that it reaches by
many paths), so the checker judges no write of the module". The largest walk of any of the 2 310
ownership roots (every corpus program and every real root) took 49 383 steps (`changeRouteTo` of
`examples/conduit`), so the limit is twenty times that.

### 1.5 One refusal line for each site

The review (§6) found that a walk on many paths made one refusal line on each path: `climb.live` printed
126 992 equal diagnostics, 52 MB. `addRefusal` keeps one line for each instruction, cause and detail
now. `SanitiserFoldAlternativesShared` had three of its refusals twice; it prints five lines now.

## 2. The sibling audit

| Walk | Verdict |
|---|---|
| `flow`, `flowCaptures`, `defaultParams` | **fixed** (§1.1): the memo; a cycle gives up; the rest is under the step limit |
| `leaves`, `allLeaves`, `leavesOwn`, `leavesSet` | **fixed** (§1.2): `record-dag` and `join-dag` took 3ᴺ |
| `reach` | **fixed** (§1.2): a visited set |
| `resolve` | bounded: depth 12 for one chain; the chains of many paths are under the step limit (`climb`) |
| `answerOf`, `answerOfCode` | bounded: depth 8 and 24 answers in work for one answer; many paths are under the step limit (`answers-dag` ends in 0.1 s) |
| `partsOf`, `valueApart` | bounded: depth 8, and a value's parts are a type's places, at most 4 096 locations |
| `ownSupply`, `answerOwn` | bounded: 32 supplies in work, and under the step limit |
| the entry's fixed point (`entryCall`) | bounded: each round takes `own` away from at least one model location, so it runs at most once per location |
| a group of local functions | bounded: 16 rounds, then it gives up |
| a group of declarations | bounded: 64 rounds, each a walk under the step limit; **fixed**: past 64 rounds no member publishes a contract (a round's contract that is not the last says less than the group does, and a limit line of a module outside the app is no error, so an importer read it) |
| `Loc.cover`, `locsMeet` | bounded: one cover per pair of layouts, kept (`covers`); each costs entries × depth × entries, and a layout has at most 4 096 entries. A list under `Just` nested 100 times checks in 0.3 s |
| a diamond of type aliases | **not bounded, out of scope**: `Groups.Adapter.ofTerm` in `src/own2/` expands an alias applied twice twice (#2121). `AliasDiamondChain` does not end under v3, before and after |

The generator `bench/ownership-sweeps/bounded-walk.mjs` writes each shape at 24 levels (34 programs).
Times of `check` with a ReleaseSafe build, 24 levels:

| Shape (live and dead twin) | before | after | after verdict (live / dead) |
|---|---:|---:|---|
| a DAG of closures, three per level (`dag.3`), called, from a `Ref`, by `List.map` | does not end in 60 s | 42 ms | refused / accepted |
| a DAG of closures, two per level (`dag.2`) | ends | 42 ms | refused / accepted |
| the same, the leaf writes (`dagw.2`, `dagw.3`) | does not end | 42 ms | refused / refused |
| closures that hand their parameter down (`climb`) | does not end | 115 ms | the step limit |
| closures that hand a new list down (`fresh`) | does not end | 41 ms, 192 ms | refused / the step limit |
| closures that answer captured closures' answers (`answers`) | does not end | 54 ms | refused / refused |
| the DAG of top-level functions (`helpers`), of `Ref`s (`refs`) | ends | 47 ms | refused / accepted |
| a DAG of records of functions (`record`) | does not end | 46 ms | refused / accepted |
| a ring of 40 functions, local (`group.local`) and top-level (`group.top`) | ends | 45 ms | gives up (16 rounds) / refused and accepted |
| a list under `Just` nested 100 times (`deeptype`) | ends | 41 ms | refused / accepted |

"Before" is a ReleaseSafe build of `36ad2cb1fb` under `run.mjs`, which stops a build at 60 s. "After" is
`beni check` alone on a quiet machine. The accepted dead twins of `dag.3`, `helpers`, `record` and
`refs` are `BOTHFAIL` in the sweep: the program itself makes 3²⁴ calls, so neither its plain build nor
its checked build ends its run in 20 s.

## 3. The faults and their tests

`tests/blackbox/check_test.zig`, "ownership v3: walks that reach one function or value by many paths
end", checks report 126's fault and the siblings of `bench/ownership-sweeps/bounded-walk-faults/`, each
with a 10 s timeout:

| Program | Wanted | Before |
|---|---|---|
| `closure-dag.live`, `.dead` (report 126) | refused (`later-use`), accepted | does not end |
| `dag-writer.live`, `.dead` | refused (`later-use`), refused (`supply`) | does not end |
| `record-dag.live`, `.dead` | refused, accepted | does not end |
| `join-dag.live`, `.dead` | refused, accepted | does not end |
| `answers-dag.live`, `.dead` | refused (`unknown`) | does not end |
| `climb.live`, `.dead` | the step limit | does not end |
| `deep-keeper.live`, `.dead` | refused (`escaped`), accepted | `.live` accepted, and the sanitiser traps |

In a second worktree at `36ad2cb1fb` with this test and the fault folder, the test fails: eleven cases
do not end in 10 s, and the test reaches its 120 s hang guard. On this work every case ends; the
slowest, `climb`, takes about 0.1 s.

## 4. The gate

ReleaseSafe compilers of `36ad2cb1fb` (before) and of this work (after), the same programs.

**Every generator and fault folder** (`run.mjs --checker=v3`, the generators at their defaults):

| Generator | Programs | before SAME | before REFUSED | before TRAP/DIFF/CRASH | after SAME | after REFUSED | after TRAP/DIFF/CRASH |
|---|---:|---:|---:|---:|---:|---:|---:|
| bounded-walk | 34 | 5 | 9 | 18 (timeouts) | 5 | 23 | 0 |
| bounded-walk-faults | 12 | 1 | 0 | 11 (10 timeouts, 1 TRAP: `deep-keeper.live`) | 2 | 9 | 0 |
| blind7f-faults | 2 | 0 | 0 | 2 (timeouts) | 0 | 1 | 0 |
| blind7f | 960 | 404 | 556 | 0 | 404 | 556 | 0 |
| blind6e-faults | 12 | 4 | 8 | 0 | 4 | 8 | 0 |
| blind6e | 238 | 90 | 141 | 0 | 90 | 141 | 0 |
| blind-faults | 24 | 11 | 13 | 0 | 11 | 13 | 0 |
| blind2-faults | 20 | 7 | 13 | 0 | 7 | 13 | 0 |
| blind3-faults | 10 | 3 | 7 | 0 | 3 | 7 | 0 |
| blind4a-faults | 12 | 1 | 11 | 0 | 1 | 11 | 0 |
| blind4b-faults | 8 | 4 | 4 | 0 | 4 | 4 | 0 |
| blind5c-faults | 10 | 5 | 5 | 0 | 5 | 5 | 0 |
| blind5d-faults | 10 | 5 | 5 | 0 | 5 | 5 | 0 |
| blind | 9 792 | 1 675 | 8 117 | 0 | 1 675 | 8 117 | 0 |
| blind2 | 1 202 | 502 | 700 | 0 | 502 | 700 | 0 |
| blind3 | 417 | 160 | 257 | 0 | 160 | 257 | 0 |
| blind4a | 160 | 24 | 136 | 0 | 24 | 136 | 0 |
| blind4b | 6 596 | 1 229 | 5 367 | 0 | 1 229 | 5 367 | 0 |
| blind5c | 226 | 81 | 145 | 0 | 81 | 145 | 0 |
| blind5d | 1 234 | 456 | 778 | 0 | 456 | 778 | 0 |
| evaluation-order | 440 | 276 | 164 | 0 | 276 | 164 | 0 |
| answers-beside | 240 | 77 | 163 | 0 | 77 | 163 | 0 |
| wider-functions | 354 | 144 | 210 | 0 | 144 | 210 | 0 |
| callbacks-keep | 720 | 108 | 612 | 0 | 108 | 612 | 0 |
| function-values | 1 960 | 304 | 1 656 | 0 | 304 | 1 656 | 0 |
| handed-back | 2 592 | 0 | 2 592 | 0 | 0 | 2 592 | 0 |
| aliased-arguments | 5 160 | 1 183 | 3 977 | 0 | 1 183 | 3 977 | 0 |
| recursive-levels | 16 131 | 4 140 | 11 991 | 0 | 4 140 | 11 991 | 0 |
| folds-callbacks | 30 300 | 5 392 | 24 908 | 0 | 5 392 | 24 908 | 0 |

**0 TRAP, DIFF or CRASH after**, and no timeout. SAME is equal for every generator; no program moved
between SAME and REFUSED in any generator that existed before. The remaining rows are `BOTHFAIL` (§2)
and `blind6e`'s seven `PLAINFAIL`, the same before and after.

- **The sanitiser corpus** (`bench/ownership-step0-sanitiser.mjs`, 347 fixtures): 93 same, 254 refused,
  0 traps, differences or crashes, before and after.
- **Real writes** (`bench/ownership-v2-review.mjs --checkers=v1,v3 --roots=real`): of the 308 writes v1
  judges, v3 accepts 287, refuses 20 and has no line for 1, before and after; the list of refused writes
  is the same line for line. No write is lost or won.
- **Speed** (ReleaseFast LLVM compilers, `zig build test-perf`, the same script, best of three, one
  after the other): v3 on v2's modules (169 846 lines) **594k lines/s before, 574k after** (286.1 →
  295.7 ms, 3 %). The cost is the memo tables of `flow` and of the walks of values. Report 125's 589k
  was this machine's figure for the same head; the cautious cycle rule of `Loc.cover` (report 125 §4)
  was not changed, as no sound sharper rule was found in this work.
- **`zig build gates`:** green on the final commit.

## 5. Precision

No sweep program, sanitiser fixture or real write moved. Two kinds of program change:

- **Won:** a closure reached through more than 16 holders is now judged precisely, not at the default.
  No program of the sweeps has such a chain.
- **Lost, loudly:** a declaration whose walk passes 1 048 576 steps gives up, and its module authorises no
  write. Before, the same program either took minutes (`climb` at 13 levels took 3 s, at 15 levels 75 s)
  or did not end. The largest real walk is 49 383 steps.
- One refusal line for each site (§1.5): `SanitiserFoldAlternativesShared` printed three of its
  refusals twice (eight lines); it prints five lines now. The verdicts are the same.

## 6. The review

One fresh Opus reviewer had the code and the kernel, and was asked for a program whose check does not end
quickly, or for a memo or limit that turns an unknown into "safe".

- **Found:** the step limit bounded the steps but not the refusal lines. `climb.live` printed 126 992
  equal diagnostics (52 MB), and ten copies of it in one module took 5.4 s and 1.8 GB. Fixed by one
  line for each site (§1.5): ten copies now take 0.7 s, with 20 lines.
- **Found:** the memo of `flow` compared a 64-bit hash of a use's values, not the values. No collision
  was produced; the values are compared exactly now.
- **Not found:** a soundness hole. The reviewer read every read of a judgment against `FlowKey` and
  `ctx_floor`, the copy of a value walk's atoms, the visited set of `reach`, the step limit and the
  64-round limit, and ran seven sweeps (6 860 programs) and hand-written chains of 3 to 40 levels: no
  trap, no difference.
- Each change after the review (§1.5, the exact compare, and a cheaper memo that keeps nothing for the
  value a walk starts at and nothing for a part of a root) was checked again by the reviewer, with the
  sweeps run again: no finding.
