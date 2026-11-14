# 134 — The ownership kernel v3: what a lowering keeps, and every walk counted

*Research report, 2026-11-14. A fix of `src/own3/` and of the markup lowering interface for the two
faults of research report 133. The kernel is `ownership-v3-kernel.md`; this report changes its §5, §5.3,
§6.12, §6.14, §8 and §9, and `boundary.md` §9.4.6 and §9.4.8. Nothing in `src/own/`, `src/own2/` or a
runtime changed, and no lowering emits anything new.*

---

## 1. Result

- **A value that a lowering keeps beyond the call that made it is now a fact the lowering states.** The
  `dom` root keeps a `let` that only it reads from one render to the next. The checker walked `view` as
  if the `let` were made on each call, so it accepted a push onto it, and the next render pushed onto
  the same array. Now the lowering says which `let`s it keeps, the checker finds the candidates with the
  emitter's own analysis, and each kept `let` escapes where it is bound. Every write of it is refused.
- **Every walk of the runs of new names is counted and done once.** A chain of 400 writes took 17.8 s
  after the budget was passed. Now it takes 53 ms, and 5 000 writes reach the limit in 1.4 s.
- **No walk goes on after its budget.** `finish` does not run past the budget, the rows of the derived
  methods are not read past it, and a module that passes its budget only in those reads has a limit line.
- **The sweeps:** 0 traps, differences or crashes in 82 714 programs (25 before, all from report 133's
  first fault). Every generator's SAME count is unchanged except `blind10i` (two fewer, §6).
- **The review** found two more holes and one more uncounted climb. All are fixed, with tests (§7).

## 2. The rule: a lowering says what it keeps

The kernel's clock orders one call of the code (§5.3). A value that one call makes and a later call
reads is outside that order. The walk sees a value made on each call, but the program reads a value an
earlier call made and maybe wrote. So such a value is a holder the walk does not follow, and it must
escape where it is made.

Only the lowering knows what it keeps. So the lowering tells the checker, through the interface it
implements:

- `Lowering.keeps_let(tree, root, k)` (interface 1.26, `src/markup/Interface.zig`): whether the
  lowering keeps root `root`'s `k`-th `let` beyond the call that made it. **The default keeps every
  one.** A lowering that says nothing is read on the side that refuses. A lowering that does not
  `groups` evaluates no `let` of its own and is not asked.
- The candidates are `Root.lets`, which the compiler computes, not the lowering. The check builds the
  module's markup tree with `MarkupTree.build`, the function the emitter calls, and then asks the
  lowering (`MarkupTree.keptLets`, `Enforce.keptLets`). Every declaration is live in that build, so its
  roots are a superset of the emitter's. A root that the emitter does not group after all evaluates its
  `let`s in place, so the set is never smaller than what is kept.
- The walk escapes each kept `let`'s value where it is bound (`Frame.binding`). Test 3 of §5 then refuses
  every write of it, or of a cell it shares, at any time of the walk.

The `dom` lowering's answer (`keepsLet`, `platforms/browser/zig/dom.zig`) is the test it emits: a `let`
is made again only when a path it reads is not `===` the one it was made from. A path whose value is not
identity-safe (a list, or a record that holds one) is never compared, so a `let` that reads one is made
again on every render, before it is read. That `let` is not kept. Every other one is. A safe-build check
in the emitter asserts that the emitted test and `keepsLet` agree.

`browser-inline` says it keeps none (`keepsNoLet`): a `let` is a `const` of each binding function that
reads it, and one that two functions read is refused.

### 2.1 The audit of every lowering

| Lowering | What it keeps beyond the call that made it | What the checker knows |
|---|---|---|
| `dom` (`browser`, `browser-tea`) | a root's `let` in `d<k>` (`hoistGroupedKind`) | each kept `let` escapes where it is bound |
| `dom` | the last value of an operand, for a test by `===` (`a<k>`, `l<k>_<j>`, `g<k>_<j>`): identity-safe ones only (`identityOperand`); a class or style list's written `Set`, which the runtime makes | nothing to know: an identity-safe value holds no list |
| `dom` | a row's inputs for a skip: the runtime compares only the identity-safe ones (`rememberInputs`) | nothing to know |
| `dom` | a skipped helper's or component's block, restated: its call had identity-safe arguments only, so it is the call made before | rule 12: the markup held what it holds when it was made |
| `dom` | a `Show`'s key, and a `For`'s items and keys, kept by the runtime to match rows | not known: #2504, a breach of `boundary.md` §9.4.8, out of this work |
| `inline` | nothing of a root; the model, which the entry holds | nothing to know |
| `ssr`, `toy`, `shared-toy` | nothing: they do not group, and render as the markup is made | nothing to know |

The kept `let` was already listed as a known breach of §9.4.8 (#2503). It is no longer a hole of the
checker; the lowering still keeps the `let`, and a program that writes one is refused.

## 3. The tests

- `tests/blackbox/check_test.zig`, *a let that a markup lowering keeps, and a long chain of writes*: the
  16 programs of `bench/ownership-sweeps/blind10i-faults/`. Report 133's four, and the siblings it
  named: a record, a list of lists, a chain of two writes, a helper's root, a component's root, a root
  that is a component call alone. Each `live` is refused, each `dead` accepted, the chain refused by its
  limit in 10 s. Before the fix, seven live programs were accepted and the chain did not end in 10 s.
- *The contexts that a pair of a write and a read climb are counted*: writes 200 cases deep beside
  10 000 reads in the other arm. Before: accepted, with the climb uncounted. After: the walk's limit.
- Pages: `browser/dom/KeptLetInPlace` and `browser/tea/KeptLetInPlace` carry a new
  `.sanitize-lists-v3-refuses` file: v3 must refuse exactly the push of the kept `let`. Before the fix
  both fail (`SanitisedRefusalAccepted`). `browser/dom/KeptLetRemade` (`.sanitize-lists-v3`) is the safe
  twin, written in place under the sanitiser. The corpus harness reads the new file for a page
  (`corpus_test.zig`, `v3Page`).
- Two older tests pinned `later-use` for a `let` that is now kept. Each program was changed so that its
  `let` reads a list of the model, which the root makes again on every render, so the rule each test is
  for (markup holds its holes' inputs) is still the one that refuses.

The first test and the pages were run on the base commit in a second worktree and failed there. The two programs the review found (§7) were shown on the base compiler: the component root traps, and the deep cases are accepted with the climb uncounted.

## 4. The charges

Report 133 found `markAtomIn` recursing through the runs of `version` entries with no unit counted, once
for each write. The audit of `src/own3/` looked at every recursive function and every loop over versions,
atoms, parts, places, escapes, uses, demands and answers.

**Fixed:**

| Where | Before | Now |
|---|---|---|
| `markAtom` (the flags of a contract) | recursion over the runs, again for each write, uncounted | a work list; each entry marked once for each flag in the walk (`RunFact`); each entry and atom counted |
| `groundOf` (what a line rests on) | the same | a work list; the highest ground of each entry's run kept; counted |
| `atomSrcs` (the sources of a contract) | recursion, uncounted | a work list, counted |
| `demand`, `finishDemands` | the escapes and reads in another context or at an earlier time were passed over uncounted; so were the answers compared | each counts 1 |
| `compatible` (found by the review) | the climb of two contexts to their common case, uncounted, for each pair | each step counted; past the budget the two are compatible |
| `project` of a `join`, `fnMembers` | each arm visited uncounted | counted; past the budget the part is unknown |
| the markup walks (`formCalls`, `keptItems`, `helperHoles`), the pattern walks (`bindPattern`, `unbindPattern`, `readsList`) | uncounted | 1 for each node |
| `walkDecl`, `walkSchema`, `walkExports`, `solveCodes` | `finish` ran after the budget was passed | not run: no line, no contract |
| `rowInfo` | read on past the budget | answers "writes and keeps" past it, at entry and in its loop |
| the module's derived facts | read after a module passed its budget | not read; a module that passes its budget only there has a limit line |

The runs of new names are walked once because a run never changes once its entry is made, and marking
is idempotent. The facts sit in an array beside `rents`, not a hash map: a hash per atom was most of the
time left after the first change.

**Held** (no change needed): `flow`, `resolve`, `answerOwn`, `partsOf` and `answerOf` tick or have a depth
cap; `leaves`, `reach`, `uniqueTail`, `overlapAny`, `dupOverlap`, `deriveLinear` and `useReaches` were
counted already; `runtimeCall` over a `join` calls `applyAt`, which ticks; `Loc`'s layout walks count
against the module (report 130). The review found one climb left uncounted, `Loc.comparable` on two atom
paths, bounded by a pattern's depth (at most 512 levels); it is a constant factor and was left.

## 5. The chain of writes

| Writes in one function | Before (LLVM ReleaseSafe) | After (LLVM ReleaseSafe) | Verdict after |
|---:|---:|---:|---|
| 400 (`chain-of-writes.slow`) | 17.6 s | 53 ms | module limit |
| 2 000 | more than 120 s | 0.35 s | declaration limit |
| 5 000 | — | 1.37 s | declaration limit |

The time is now linear in the counted work. The counted work of a chain is still quadratic in its
length: each write's operand holds every older name of the cells (§5.1), and the tests of pairs
compare them. So a chain longer than about 85 writes in one function still passes the budget. That is
a precision loss, unchanged by this work, and is not won back here.

## 6. Gates

All on LLVM ReleaseSafe compilers of `e267acd081` (before) and of this work (after), one at a time.

**The sweeps** (`bench/ownership-sweeps/run.mjs --checker=v3`, every generator and every fault folder,
82 714 programs; 17 326 SAME before, 17 324 after):

| Generator | Programs | SAME before | SAME after | REFUSED before | REFUSED after | TRAP, DIFF, CRASH before | after | Verdicts changed |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| aliased-arguments | 5160 | 1183 | 1183 | 3977 | 3977 | 0 | 0 | 0 |
| answers-beside | 240 | 77 | 77 | 163 | 163 | 0 | 0 | 0 |
| blind | 9792 | 1675 | 1675 | 8117 | 8117 | 0 | 0 | 0 |
| blind-faults | 24 | 11 | 11 | 13 | 13 | 0 | 0 | 0 |
| blind10i | 474 | 150 | 148 | 192 | 212 | 18 | 0 | 20 |
| blind10i-faults | 14 | 5 | 5 | 2 | 9 | 7 | 0 | 7 |
| blind2 | 1202 | 502 | 502 | 700 | 700 | 0 | 0 | 0 |
| blind2-faults | 20 | 7 | 7 | 13 | 13 | 0 | 0 | 0 |
| blind3 | 417 | 160 | 160 | 257 | 257 | 0 | 0 | 0 |
| blind3-faults | 10 | 3 | 3 | 7 | 7 | 0 | 0 | 0 |
| blind4a | 160 | 24 | 24 | 136 | 136 | 0 | 0 | 0 |
| blind4a-faults | 12 | 1 | 1 | 11 | 11 | 0 | 0 | 0 |
| blind4b | 6596 | 1229 | 1229 | 5367 | 5367 | 0 | 0 | 0 |
| blind4b-faults | 8 | 4 | 4 | 4 | 4 | 0 | 0 | 0 |
| blind5c | 226 | 81 | 81 | 145 | 145 | 0 | 0 | 0 |
| blind5c-faults | 10 | 5 | 5 | 5 | 5 | 0 | 0 | 0 |
| blind5d | 1234 | 456 | 456 | 778 | 778 | 0 | 0 | 0 |
| blind5d-faults | 10 | 5 | 5 | 5 | 5 | 0 | 0 | 0 |
| blind6e | 238 | 90 | 90 | 141 | 141 | 0 | 0 | 0 |
| blind6e-faults | 12 | 4 | 4 | 8 | 8 | 0 | 0 | 0 |
| blind7f | 960 | 404 | 404 | 556 | 556 | 0 | 0 | 0 |
| blind7f-faults | 2 | 0 | 0 | 1 | 1 | 0 | 0 | 0 |
| blind8g | 121 | 21 | 21 | 100 | 100 | 0 | 0 | 0 |
| blind8g-faults | 8 | 4 | 4 | 4 | 4 | 0 | 0 | 0 |
| blind9h | 3213 | 852 | 852 | 2361 | 2361 | 0 | 0 | 0 |
| bounded-walk | 34 | 5 | 5 | 23 | 23 | 0 | 0 | 0 |
| bounded-walk-faults | 12 | 2 | 2 | 9 | 9 | 0 | 0 | 0 |
| callbacks-keep | 720 | 108 | 108 | 612 | 612 | 0 | 0 | 0 |
| evaluation-order | 440 | 276 | 276 | 164 | 164 | 0 | 0 | 0 |
| folds-callbacks | 30300 | 5392 | 5392 | 24908 | 24908 | 0 | 0 | 0 |
| function-values | 1960 | 304 | 304 | 1656 | 1656 | 0 | 0 | 0 |
| handed-back | 2592 | 0 | 0 | 2592 | 2592 | 0 | 0 | 0 |
| recursive-levels | 16131 | 4140 | 4140 | 11991 | 11991 | 0 | 0 | 0 |
| runtime-calls-faults | 8 | 2 | 2 | 6 | 6 | 0 | 0 | 0 |
| wider-functions | 354 | 144 | 144 | 210 | 210 | 0 | 0 | 0 |

The changed verdicts are all in `blind10i` and its faults: 18 memo programs and 7 fault programs went
from TRAP to REFUSED, and two programs from SAME to REFUSED (`memo.dom.update.live`,
`memo.tea.update.live`). Those two are `live` programs that printed the same only because a
`List.update` with the same element gives the same list; the kept `let` is written in place, so a refusal
is right. The two `view-let-wrap` programs, written after the sweeps were generated, ran on their own:
`live` TRAP before and REFUSED after, `dead` SAME both times.

**The sanitiser corpus** (`bench/ownership-step0-sanitiser.mjs`): 347 fixtures, before and after the same: 93 same, 254 refused, 0 traps, differences or crashes.

**Real writes** (`bench/ownership-v2-review.mjs --checkers=v1,v3 --roots=real`): of the 308 writes v1 judges, v3 accepts 287, refuses 20 and has no line for 1, before and after, line for line. No write is lost or won.

**Speed** (ReleaseFast LLVM, v3 on v2's modules): `--checkers=v1,v2,v3 --runs=3 --jobs=1`, two runs each, 169 846 lines: **545k and 545k lines/s before, 539k and 535k after** (311.6 → 316.3 ms, 1.5% slower). The cost is the markup tree that the check now builds for each module of a build whose lowering groups, and the units counted.

**`zig build gates`:** green on the final commit.

## 7. The review

A fresh reader had the code, the kernel and the lowerings, not this report, and was asked for a value a
lowering or runtime keeps that the checker does not know, an uncounted loop, or a limit that accepts.

- **Found: a root that is a component call alone.** Such a module has no row in the markup section of
  its dispatch table, and the check skipped it on that ground. The emitter finds roots from the
  `markup` instructions, so it kept the `let`s of `wrap n = xs = [ 1, 2 ]; ys = List.push xs n;
  <Comp.counter s={show ys} />`, and the page trapped. **Fixed:** the shortcut is gone; the tree finds
  the roots. A test.
- **Found: `compatible` climbed contexts uncounted** (§4). Writes 2 000 cases deep beside 20 000 reads
  took 3.9 s and counted 1.2 million units. **Fixed:** the climb counts. A test.
- **Found, bounded:** `rowInfo` checked the budget only at entry. Its loop checks it now, and lets go of
  the slots it claimed, so no later call can read a slot of a list it did not build.
- **Held:** the other early exits of `keptLets` (no lowering, no vocabulary, no root) are the emitter's
  own; the inputs that differ between the check's tree and the emitter's (`live`, `comparison`) do not
  change which `let`s a root takes; `keepsLet` agrees with the emitted test; values the runtime keeps
  (handlers, messages, props, rows' functions) escape under rule 12; stored test operands and row inputs
  are identity-safe; a restated block holds nothing the program can write while it is kept; no partial
  walk publishes a line, a contract or a derived fact.
- **Observed, open:** a chain of one-level `case` projections over a recursive type
  (`type Tree = Node (List Int) (Maybe Tree) | Leaf`) grows the counted work exponentially with its
  length: 20 levels pass the module budget in 4.9 s, and 400 levels take about 22 s before the
  declaration's limit. The work is counted, so §8's bound holds, but at about 0.7 µs a unit on this
  shape one declaration can take 20 s before its limit line. A hand-written tree descent of 20 levels
  is refused by the limit. Neither is fixed here.

## 8. What is open

- #2504: a `For` by reference and a keyed `Show` keep items and keys and compare them by identity. The
  interface has the place to say so (§2), and it is not said.
- The counted work of a chain of writes is quadratic (§5), and the exponential `case` chain (§7).
- The plain build's emit of 20 nested `For`s takes 40 s (report 133 §7). Not looked at.

## 9. How to reproduce

```sh
git worktree add --detach base e267acd081
(cd base && zig build -Doptimize=ReleaseSafe --prefix ../before)
(cd wt && zig build -Doptimize=ReleaseSafe --prefix ../after)
for g in bench/ownership-sweeps/*.mjs; do node $g sweeps/$(basename $g .mjs); done   # not run.mjs
node bench/ownership-sweeps/run.mjs --beni=<compiler> --checker=v3 --tag=<tag> --jobs=24 --tmp=<disk> sweeps/<name>
node bench/ownership-step0-sanitiser.mjs --beni=<compiler> --jobs=14
node bench/ownership-v2-review.mjs --beni=<compiler> --checkers=v1,v3 --roots=real --runs=1 --jobs=8
node bench/ownership-v2-review.mjs --beni=<ReleaseFast compiler> --checkers=v1,v2,v3 --roots=real --runs=3 --jobs=1
zig build test-blackbox-check "-Dtest-filter=a let that a markup lowering keeps" \
  "-Dtest-filter=the contexts that a pair"
zig build test-blackbox-corpus -Dcorpus=KeptLet
```
