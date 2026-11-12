# 117 — Ownership v3: the principled kernel

*Research report, 2026-11-12. The owner ordered it on pull request #2451 after report 116: "Write the rules
and do a principled fix on the core. Delete the other patches if possible. This is still a prototype, so feel
free to do whatever you think is best. The core must have soundness." It is not normative:
`docs/design/ownership-v3-kernel.md` is. It compares the branch head `8c63889ffc` (before) with this work
(after) on the same programs, with ReleaseSafe compilers of each.*

---

## 0. Summary

The kernel text came first, then the code. One rule: **every fact a verdict depends on negatively is derived
from named, positive facts, and a fact no rule derives is the pessimistic one** (kernel §1). It is applied
in the five forms report 116 §5.2 named, with one change of shape found while building: a fresh cell's
name must be canonical, or a recursive group never settles (§2.2).

The five faults of report 115 are refused; the three fault folders have 0 traps, 0 differences and 0 crashes;
every generator of `bench/ownership-sweeps/` has 0 traps (§3). The real writes and the markup cost are in
§4 and §5. The mechanisms that the principle subsumes are gone (§2.3). The code is about the same size,
because each `switch` is exhaustive and each rule carries its argument; what left was the arguments by hand.

## 1. What changed

### 1.1 Values: no state reads "unknown" as "empty"

`v_shared` meant two things and was returned at 14 sites. It is gone. A value is now `outside` only where a
positive fact says that every cell of it is outside the frame (a top-level value, a function that captured
nothing), `unknown(V)` where the walk cannot follow it (and it holds every cell of V), and a walk that
cannot go on **gives up**: the declaration publishes no contract and accepts no write (kernel §3). Before,
a failed walk published its contract, and every importer read it. The value of a local before its binding
is a poison that safe builds assert is never read.

Every `switch` over a value kind, a root kind, an entry kind, a source kind, a use kind and the BIR tags has
no `else`.

### 1.2 Names: a fresh cell has one

`Src.fresh` was a flag. It is `fresh(k, escaped)`: `k` the allocation site, `escaped` whether the body let
the cell go. In a caller, every reader of one call names one cell by one root (`freshAtom`), so an answer at
two places overlaps with itself, a cell handed to a callback and answered is the cell in the result, and an
escaped cell is escaped where the caller reads it. These are the three shapes of report 115 §4.1.

### 1.3 Duplicates: one test, `linear` derived

`REntry.twice` is set where a run is built, by one test (`partDup`). `Root.linear` is three-valued and has
one writer (`deriveLinear`); a reader that meets `undecided` is a failed assertion in a safe build. A
callee's claim that its result's parts are apart is taken only as far as the callee could see: when the
arguments are apart, and never for an entry that holds a callback's answer, which the callee's own frame saw
as an opaque root. That last clause closed a hole the first version of this work opened (§2.1).

### 1.4 No fact by a name

- `methodCall` read `eq`/`compare` by their names as "only reads". It now runs the code the dispatch table
  names: a declaration is a call of its contract; a derived function, a codec or an evidence parameter reads
  its operands; anything else is unknown code. The by-name check of `pub` annotated methods in `Check.zig`
  is deleted; the dispatch rule covers every method, annotated or not. Evidence that keeps its operand is
  refused as evidence that writes is.
- `Check.isSender` read the alias `Send` by its name. The platform's alias now carries the word the design
  reserved for it (`pub sender type alias Send msg`, `platforms/browser/Browser.beni`), and the checker reads
  the word, through aliases of it.
- `Check.isDictFocus`/`trustFocus` edited `Dict.focus`'s inferred contract by the function's name. Deleted.
  Report 115 §5 had already found that no `Dict.update` writes in place under any checker, so it wins no
  write today.
- A worded row that does not say what it hands a function parameter handed it `shared`, which escaped
  nothing (report 115 §4.3). It hands every cell of every parameter, not `free`. A worded row whose result
  no word describes gave `shared`, which held nothing: it is `outside` plus every cell of every parameter.
  The word `fresh` named one site for the whole result, so a builder's storage and its elements were one
  cell; each location of the result is its own site.

### 1.5 Markup holds its holes

The value of markup is `unknown` over the values of its holes and the arguments of a helper call in a hole
(kernel §6.12). The `late` reads at the frame's end, which approximated this, are gone. The cost is §5.

## 2. What was learned while building

### 2.1 Three holes the first version of this work had

Each was found by the existing black-box tests and the sanitiser corpus before any sweep ran, and each is a
state that read "unknown" as "empty" in a new place:

1. **An escape recorded inside a run under construction.** `freshAtom` noted the escape of a callee's cell
   as a range into `atoms`, and the run was then compacted by `uniqueTail`: the range dangled. An escape
   now owns a copy of its atoms (`esc_atoms`).
2. **A callee's `linear` claim covered an answer it could not see.** `withBoth f xs = ( f xs, xs )` derives
   `nonlinear = false` in its own frame, because the answer root and the parameter root never overlap
   there. With `f` the identity the two parts are one list. The old `sourcesApart` step 2 checked this by
   hand; the first version deleted it and trusted the claim. The caller now tests every pair of entries
   where one holds an answer (`deriveLinear`'s `answers`).
3. **The by-name `eq` rule deleted, an evidence parameter became unknown code.** `a.eq` under
   `where a.eq` is a `param` term of the dispatch table. Read as unknown code, `List.member` let its
   operands escape, and every fold that handed `member` on refused. The caller that hands the evidence is
   judged (`evidence`), so a call of an evidence parameter reads.

### 2.2 A fresh name must be canonical

Numbering fresh cells by first appearance made a recursive group grow a new name each round:
`List.sortRange` was walked 16 times in a minute and never settled. A cell the frame made is named by the
instruction that made it; a cell a callee made by the call, the callee and the callee's site; a cell of a
callee whose contract is still a draft by the call and the callee alone (`Mod.drafts`, `Mod.siteId`). The
rounds settle, and collapsing two cells into one name is on the pessimistic side.

### 2.3 What was deleted

`Src.also`; `Src.shared` as the answer for everything unnamed (`Src.outside` names the one case that is
positive); `EKind.shared`; the `smear` value; `v_shared`; `SrcState`'s `fresh`, `shared` and `dup`;
`sourcesApart`, `linearFn`, `handsOn` and the arguments by hand in their comments (the one named exception
that survives is `alternatives`, kernel §4.4); the `late` reads of markup; `isDictFocus`/`trustFocus`;
`isSender` by name; the by-name `eq`/`compare` check; the `methodCall` read-by-name rule; the depth caps of
`markAtom` and `groundOf` (the runs are acyclic); the silent `evidenceTerm` depth cap (a refusal now).

What stays, and the rule that needs it: `unknown` (kernel §3.2), `later`/`capVal`/`solveCodes` (§6.3: a
capture bound after the closure is made is the value bound there), `twice` (§4.4), the clock (§5.3),
`argsApart`/`partsOf` (§4.4: a contract is conditional on apart arguments), the resource limits (§8).

### 2.4 Lines

| | before | after |
|---|---:|---:|
| `src/own3/` | 6 800 | 6 978 |

The deletions are about 400 lines; the additions are the exhaustive `evalInner` (every BIR tag named), the
three-valued `linear`, the fresh roots, and a doc comment on each rule naming its kernel section.

## 3. The gate

ReleaseSafe compilers; the same generated programs; `run.mjs --checker=v3`.

| Generator | Programs | before SAME | before REFUSED | before TRAP | before DIFF | before CRASH | after SAME | after REFUSED | after TRAP | after DIFF | after CRASH |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| blind-faults | 24 | 11 | 13 | 0 | 0 | 0 | 11 | 13 | 0 | 0 | 0 |
| blind2-faults | 20 | 9 | 11 | 0 | 0 | 0 | 9 | 11 | 0 | 0 | 0 |
| blind3-faults | 10 | 5 | 0 | 5 | 0 | 0 | 3 | 7 | 0 | 0 | 0 |
| blind3 | 417 | 172 | 122 | 123 | 0 | 0 | 160 | 257 | 0 | 0 | 0 |
| blind2 | 1202 | 502 | 700 | 0 | 0 | 0 | 502 | 700 | 0 | 0 | 0 |
| evaluation-order | 440 | 288 | 152 | 0 | 0 | 0 | 288 | 152 | 0 | 0 | 0 |
| answers-beside | 240 | 62 | 178 | 0 | 0 | 0 | 78 | 162 | 0 | 0 | 0 |
| wider-functions | 354 | 171 | 183 | 0 | 0 | 0 | 152 | 202 | 0 | 0 | 0 |
| callbacks-keep | 720 | 108 | 612 | 0 | 0 | 0 | 108 | 612 | 0 | 0 | 0 |
| function-values | 1960 | 250 | 1710 | 0 | 0 | 0 | 304 | 1656 | 0 | 0 | 0 |
| handed-back | 2592 | 0 | 2592 | 0 | 0 | 0 | 0 | 2592 | 0 | 0 | 0 |
| aliased-arguments | 5160 | 963 | 4197 | 0 | 0 | 0 | 1195 | 3965 | 0 | 0 | 0 |
| recursive-levels | 16131 | 4291 | 11840 | 0 | 0 | 0 | 4526 | 11605 | 0 | 0 | 0 |
| folds-callbacks | 30300 | 6182 | 24118 | 0 | 0 | 0 | 6146 | 24154 | 0 | 0 | 0 |

The 5 `live` programs of `blind3-faults/` are refused: `answer-twice` and `answer-supply` as `later-use`,
`answer-escape` and `sortwith-keep` as `escaped`, `compare-unannotated` as `later-use` at the `==`. Their
safe twins: three accepted; `answer-escape.dead` and `sortwith-keep.dead` refused, because a cell that
escaped into a `Ref` is never written again (kernel §5, test 3), whether or not the program reads the cell.

Safe twins (`dead`, `none`) refused, before → after, of the twins in the generator:
- `blind-faults`: 0 → 0 of 11
- `blind2-faults`: 1 → 1 of 10
- `blind3-faults`: 0 → 2 of 5
- `blind3`: 43 → 55 of 215
- `blind2`: 35 → 35 of 468
- `evaluation-order`: 4 → 4 of 292
- `answers-beside`: 0 → 0 of 0
- `wider-functions`: 6 → 25 of 177
- `callbacks-keep`: 0 → 0 of 0
- `function-values`: 786 → 732 of 980
- `handed-back`: 0 → 0 of 0
- `aliased-arguments`: 468 → 0 of 960
- `recursive-levels`: 1086 → 851 of 5377
- `folds-callbacks`: 6256 → 6292 of 10476

Where the kernel refuses a safe twin that the old code accepted, the cause is a named one: `wider-functions` (19,
`disjoint`/`element`) and `recursive-levels` (42, `element`) are summary locations read through a type
variable, where one reading of the type now contributes the same atom to two parts and the location is
`twice`; `folds-callbacks` (36, `supply`) are nested folds whose accumulator is a list of lists written
through a callback; `blind3` (35) are comparators and `eq`s that keep an operand, refused as `escaped`
whether or not the program reads the cell again. Where it accepts more: `aliased-arguments` (468 safe twins
won back, every one), `recursive-levels` (277), `function-values` (54), `blind3` (23): the fresh names and
the atom test replaced `shared`, which refused every write of a location it touched.

Sanitiser corpus (`bench/ownership-step0-sanitiser.mjs`, 347 fixtures):

SANITISER_TABLE

## 4. Real writes

`bench/ownership-v2-review.mjs --checkers=v1,v3 --roots=real`, the 32 real roots of report 110, the 308 list
writes v1 judges.

REAL_WRITES

## 5. Markup: the owner's decision

The sound default makes a markup value hold its holes' values. Measured on the 308 real writes:

MARKUP_TABLE

## 6. Speed

ReleaseFast LLVM compiler, `bench/ownership-v2-review.mjs --checkers=v1,v2,v3 --roots=real --runs=3 --jobs=1`,
best of three, one machine.

SPEED_TABLE

## 7. The review

REVIEW

## 8. What this report does not show

- Two fresh readers on the kernel (report 116 §9 item 1): the experiment that says whether the holder side
  converges. This work ran the author's tests.
- Records, cells and fibers (report 116 §5.4): the same five forms, not built.
- The resource limits are still a prototype's constants (kernel §8); each falls to the pessimistic side.

## Appendix A. Commands

All from the worktree root, `ZIG_GLOBAL_CACHE_DIR` as `flake.nix` sets it.

1. The compilers: `zig build -Doptimize=ReleaseSafe --prefix <dir>` for each of the two commits; `zig build
   test-perf "-Dtest-filter=generated module of §7.6"` installs the ReleaseFast compiler at `zig-out/perf/bin/beni`.
2. The sweeps: for each generator, `node bench/ownership-sweeps/<generator>.mjs <out>/<generator>`, then
   `node bench/ownership-sweeps/run.mjs --beni=<beni> --checker=v3 --tag=<tag> --jobs=10 --tmp=<disk> <out>/<generator>`;
   the three fault folders are run the same way.
3. The sanitiser corpus: `node bench/ownership-step0-sanitiser.mjs --beni=<beni> --jobs=6`.
4. Real writes and speed: `node bench/ownership-v2-review.mjs --beni=<beni> --checkers=v1,v3 --roots=real --runs=1`
   (verdicts, any compiler) and `--checkers=v1,v2,v3 --runs=3 --jobs=1` with the ReleaseFast compiler (speed).
5. The markup cost: the same real-writes run twice, the second with `evalInner .markup` answering
   `unknownOf(place, &.{})` in place of `unknownOf(place, held.items)`, a one-line local edit that was not committed.
