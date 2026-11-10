# 110 — Ownership checker v2: a design review

*Research report, 2026-11-10. The owner asked for it (issue #2445). It is not normative. Every decision it
names is the owner's. The review read the design, its history, the code and the issues. It measured the
checker on a ReleaseFast compiler built from `origin/master` at `96e93db4af`.*

The owner asked two questions. Is the design correct? Is the project on the right path? This report answers
both, and it gives a target design and a way to get there.

---

## 0. Executive summary

**Correctness: not shown, and the present structure cannot show it.** The design's own soundness section says
that its theorem "does not say that an accepted program is safe". It says that the argument "cannot reject a
wrong fix, because nothing in it runs" (`ownership-v2.md` lines 4847 to 4860). The issues agree. 86 soundness
holes have an issue since 2026-10-25. 40 of them are on the present domain, which reached `master` five days ago.
Nine are open today. Reviews of pull requests found 28 of the 40, most often the review of the fix before.
Three properties of the design cause the holes, and they are structural:

1. **The default answer is the permissive one.** A read that finds no entry means "no object here", and the
   checker reads that as "fresh". So each reader that misses a fact accepts a wrong write.
2. **One object has many names.** A slot is a path, and a path through a recursive type folds. After a fold,
   one object has several slot names. Each reader must list them all. Nine holes had this one form.
3. **Function values are a list of routes.** The design says so itself: "a list of routes, not a derivation"
   (line 5067). 22 holes of the slot domain are in this class, and no single invariant covers it.

**Precision: lower than v1 on real code, and it falls with each soundness fix.** On the real code of this
repository v1 accepts 308 of 308 list writes. v2 refuses 32 of its 340. Three of them are the one-line folds
`Dict.keys`, `Dict.values` and `Dict.toList` of `core/`. The goal "never refuse a safe program" is not reachable
for a static checker. The reachable goal is a rule that a developer can read and predict.

**Speed: outside the budget, by design and not by tuning.** On real code the type check runs at 573 000 lines
per second on one core. v2's pass runs at 113 000. The budget for all of checking is 250 000. The pass costs
five times the type check. 92 % of its work goes to declarations that write nothing. The cost has no hot loop:
it is the number of facts. A contract lists one entry for each path of a type. One four-line function has a
contract of 96 entries, and its type has four places that hold an object. The size limit is a guard, not a
budget. On `master`, five small declarations of the benchmark JSON decoder stop at the limit. They need five to
eight times the limit, and none of them writes a list.

**Direction: the carrier is right, the path is not.** The move of 2026-11-02 to a domain that the types index
was correct, and it stays. Two parts built on it do not converge: the names of objects in recursive types, and
function values. The stages that remain (records, modules, program entry, sends, `Dict`, the in-place lowering)
each add readers and routes to the same structure. The two-pass record design adds a second full walk and a
second alias model. So the present path leads to more cases, not to an end.

**Recommendations, ranked.**

1. **Run one experiment that decides** (§7, step 0). Build the three changes of §6 for lists only, behind a
   hidden flag, on the lower half of v2. Measure it on the 308 real writes, on the sanitiser fixtures and on
   time. It is small, and it uses the test assets that exist.
2. **If the experiment passes, rebuild the upper half of v2 on three changes** (§6):
   - *one name for each object*: facts sit on the places of a type, and all levels of a recursive part share
     one name;
   - *facts are permissions*: "this is the only reference" is a positive fact, and the default is "no claim",
     which refuses;
   - *a function value has a contract on its type position*: one rule covers every route.
   Keep the lower half (places, values, liveness, holders, diagnostics) and every test asset.
3. **Until then, stop new stages on the present upper half.** Do not merge the two-pass record design as the
   end state. Fix only holes that have a failing program.
4. **Change four requirements** (§5.5). Each of them forces part of the present cost or complexity. They
   are: no merge of call contexts, parity with v1 on each fixture, levels told apart across calls, and the
   size limit.
5. **If the owner keeps the present design**, do the five actions of §8 first. They make the two invariants
   of the value half structural, close the program entry, and put time into the gates.

The largest unknown of the target design is how many fixtures it refuses that v1 accepts. The evidence from
real contracts says "few" (§3.8, §6.9). Step 0 measures it before anything is committed.

---

## 1. What this review read and measured

**Read.**

- `ownership-requirements.md`, `ownership-v2.md` (today, and the first version `eab0827279` with its two
  revisions), `ownership-checker.md`, `backend.md` §4, `language.md` §6.8.
- Research reports 68, 69, 71, 74, 76 to 79 and 109.
- `src/own2/` (170 files, 38 021 lines) and `src/own/` (v1).
- The issues and pull requests on ownership v2: the soundness holes, the cost issues, the precision issues,
  and the records stack #2426 to #2444 with #2443.

**Measured.** A ReleaseFast LLVM compiler, one thread, the best of five runs. Appendix A has each command.
The script is `bench/ownership-v2-review.mjs`, added with this report.

**Not available.** The owner's prompt names files on another machine: the manager's log
`TRACKING-ownership-v2.md`, and the audits and generators under `~/.cache/beni-agents/`. This review did not
read them. It used the quotes of those audits in issues #2377, #2393, #1713 and #2275. Two findings depend on
them, and §9 names both.

**Counts of issues are counts of the test effort too.** No hole came from a user's program, because v2 is
behind a hidden flag. v1, which ships, has nine open soundness issues of the same kinds.

---

## 2. The design today, in short

The checker gives each in-place write a verdict. A write is safe when nothing reads the old value later.

- **Places.** A place is a node of a graph that has the shape of a type. A recursive type folds onto itself.
- **Slots.** A slot is a path through that graph from a root. The first return to a place is a plain step.
  A later return folds into a level mark, written `⟲`.
- **Values.** A value of a frame is a small tree: what the frame built, with references to positions of roots
  (a parameter, a call's result). Each value has a set of leaves, the objects it can hold.
- **The relation.** One relation compares two leaves: apart, apart under a condition, or possibly the same.
- **Conditions.** A condition is a selection: a set of parameter slots whose objects must be distinct.
- **Contracts.** A contract describes a function over slots. It says where the result's objects come from.
  It says what the body reads, writes and lets escape, and what it asks of its caller.
- **Labels.** A function parameter is a label. A contract says what the callee hands the label, what it
  keeps, how often it calls it, and what it needs of its answer.
- **The check.** A walk records uses. A write is accepted when its target is known, did not escape, and no
  live holder can reach it.

**How it got here.** The first design (2026-10-25) was a shape graph over values. It claimed a cost "linear in
the program" in 21 files and 19 050 lines. The linear claim was withdrawn the same day, and a budget of 65 536
records for each declaration replaced it. The shape engine grew to 57 515 lines in nine days. It did not
check `Dict.removeMin` inside the budget. Report 109 found the cause: facts indexed by values, not by types.
The owner replaced the carrier on 2026-11-02 (#1685). The slot domain reached `master` on 2026-11-05 with
29 554 lines in 84 files. Today it has 38 021 lines in 170 files, and the callbacks stage is open.

---

## 3. Correctness

### 3.1 The argument does not claim soundness

`ownership-v2.md` §2.14 was rewritten on 2026-11-06 after a review. It is honest, and it is the first evidence:

- "It is not a proof, and the Lean oracle does not cover it" (line 4844).
- "*The argument maps holes, and it cannot reject a wrong fix, because nothing in it runs*" (line 4847).
- "**What the Theorem does not claim.** It does not say that an accepted program is safe" (line 4858).
- One hypothesis of the theorem is that the checker's own reads are right. The text says of it: "No fact of a
  program shows that a read of the checker was not short" (line 5033).

The Lean proofs do not help here. They model the first thesis design, they hold three `sorry`, and they do not
name `src/own2` (`proofs/ownership/README.md`).

**Does the argument cover the whole language?** No. It covers each part to a different degree
(`ownership-v2.md` §2.14, its lemmas and its gap list):

| Part of the language | State of the argument |
|---|---|
| Recursive functions | a fixed point with a validation round; the round runs the same code again |
| Recursive types | two rules for readers, stated on 2026-11-09 (§3.3) |
| Non-regular types | one graph for a family since 2026-11-07; sound by an induction; the levels inside the family's payload are lost |
| Open records | a slot for the row since 2026-11-06; the rule for each reader is "checked by nothing" (line 5180) |
| Closures and callbacks | a table of six holder classes on each route; no single lemma (§3.4) |
| Cells (`Ref`, `Deferred`) | a coarse rule: an escape reaches through a cell; a contract cannot name a loan (#2422) |
| Fibers | a coarse lemma: what two fibers reach did escape; the specified suspension rule is not built |
| `foreign` and the loops of `core/` | trusted rows; 45 worded declarations of `core/` have no check of their body |
| The program entry, a `--library` export | no caller judges the write: two open holes (#2004, #2151) |
| Records | no argument yet |

So soundness is reached case by case.

### 3.2 Finding 1: the default answer is the permissive one

A contract's result is a tree with an entry only where the read-off recorded an arrival. A reader looks up a
slot by its steps. When no kid matches a step, the reader returns nothing:

```zig
n = t.kidAt(n, words[d]) orelse { … return @intCast(d + 1); };     // src/own2/Forest.zig:46
```

Nothing means "no object here", and the caller reads that as fresh. The design states it: "a slot with no entry
reads fresh" (line 221), and "An empty set is the most permissive answer there is" (line 4949). So each reader
must prove each empty read. The design gives the rule ("each empty read carries its reason", line 4955) and
then says: "The rule can be stated, and it is not built". Issue #2145 is open.

The review of 2026-11-06 tried the opposite default: an empty read is unknown. It refused `core/` (five
refusals in `core/Markdown`, two in a platform). So the representation cannot tell "no object" from "no
information". That is the defect. The opposite default is not available as a patch.

Seven of the 40 holes have this form. The graph cannot name a step or a place, the read is empty, and the
write is accepted (#2043, #2056, #2057, #2069, #2172, #2222, #2283).

### 3.3 Finding 2: one object has many names

A slot is a path. Inside a recursive type, the first return is a plain step and later returns fold. On a
cycle of two types or more, the levels fold through several routes. So one object has more than one slot
name, and the name changes when a value moves to another root.

The contract tree is keyed by one of the names. A reader that looks under another name finds nothing, and
finding 1 turns that into an accepted write. `ownership-v2.md` §2.1 records seven amendments of this one form
in three days (lines 218 to 225). Each quotes a program that "was edited in place":

- every route to a level (#2192);
- a call's result (#2195);
- a slot written out into a result (#2197);
- a fold that the caller's instance adds (#2223);
- a read below a slot (#2359);
- a slot under another root (#2353);
- a read below a join (#2354).

On 2026-11-09 the design stated two rules for all readers, *One below* and *Every name*. That was the right
step. But each rule is a duty of each reader. §2.1 names 13 readers of a call's tree. It names eight places
that move a slot to another root. A list that people keep by hand says which readers can skip the rule. The one
mechanical check of it runs under a build flag that no gate uses.

The same choice costs time (§4.2). `MutualCycles`, five types that name each other, has more than 10⁸ slots
below one parameter (line 438). The design then added a symbol for "everything below". The code now has nine
encodings of the one idea that a fact covers a subtree.

### 3.4 Finding 3: function values are a list of routes

A slot names objects. It does not name code. So the design follows a function value by a label, and each way
that a function value can travel needs its own rule. The design's own review says:

> "It is a list of routes, not a derivation." (line 5067)
>
> "Each amendment of §2.11.3 is one row of that table on one route … Nothing makes a new route answer every
> row" (lines 5093 and 5094)

That section had 602 lines and 15 amendments on 2026-11-06. It has 974 lines and 25 amendments today. A
contract now has 14 conditions about callbacks: `kept`, `taken`, `sep`, `below`, `each`, `walk`, `fed`,
`fresh`, `answers`, `calls`, `once`, `answer_left`, `need`, and a need on a supply. Six files of the last two
days each add a route or a row (`RunKeeps`, `HandedWrites`, `KeepsNot`, `FnSite`, `CaptureRuns`, `AltCodes`).

The holes follow. 22 holes of the slot domain are in this class, and three are open. Pull requests found
and fixed at least four more with no issue. One fact that the design marked "no counterexample" has one (#2367). The
sweep of 2026-11-09 trapped 390 of 720 generated programs before the fix of #2393, and that fix is known to be
incomplete.

A requirement drives part of this. R-7.3 forbids any merge of call contexts: "Precise ordinary per-call-site
callback labels stay distinct". No published inferred system does that, as report 109 said.

### 3.5 The holes on the present domain, by class

40 holes since the slot domain reached `master` (2026-11-05 to 2026-11-10). The classes are this review's.

| Class | Holes | One invariant covers it? | A machine checks it? |
|---|---:|---|---|
| Function values: who runs which code, how often, what it keeps | 10 | no | in part (two mutants, one run-time check) |
| Recursive levels: one object, several names | 9 | yes, since 2026-11-09 | in part; the cross-check runs in no gate |
| A step or place with no name: an empty read is fresh | 7 | yes | no (#2145) |
| Cells and loans | 5 | in part | no check that each reader handles each leaf kind |
| A contract does not cover its body | 3 | yes | mutants |
| The solver's own memo | 2 | yes | by construction for the pair relation |
| No caller judges (program entry, `--library`) | 2 | yes | no; not built |
| One entry counted once for many slots | 1 | yes | two of three paths |
| Records | 1 | not yet | no |

Holes opened on each day: 15, 5, 7, 3, 6, 4. The median time to close one is nine hours. Nine are open:
#2004, #2151, #2213, #2302, #2393, #2416, #2422, #2424, #2443.

**Is this convergence?** It differs by class.

- The levels class has an invariant since 2026-11-09, and no new hole in it since then. That is a day and a
  half of evidence. But the invariant lives in reader discipline, and a new fast path is a new reader. The
  cost work of 2026-11-10 proved it: the first version of a fast path accepted a wrong write, and its review
  found #2424.
- The empty-read class has an invariant that nothing enforces.
- The function-value class shows no convergence. Each fix is one row on one route.
- Cells wait for a concept: a contract cannot name a loan (#2422).

And each soundness fix costs precision. The phrase "Refused that a perfect checker accepts" is on 22 lines of
the design. One fix added 486 refusals at the size limit on 526 programs near it (#2348).

### 3.6 The invariants that carry soundness

| Invariant | Where it is stated | What checks it today |
|---|---|---|
| A value's leaves name every object it can hold | §2.14.4 | mutants on single readers |
| An empty read has a reason | §2.14.3 | nothing |
| One below, Every name | §2.1 | mutants; a cross-check under a flag that no gate runs |
| A contract covers its body | §2.14.4 | the validation round, which runs the same code again |
| A need goes only to a caller that discharges it | §2.11.3 | one mutant on the publishing side; none on the discharge |
| The runs of a closure add up | §2.11.3 | nothing |
| A selection holds where a write relies on it | §2.14.4 | mutants |
| Escape is deep and has no end | §2.14.6 | mutants |

Two facts about this table.

- **No small kernel exists.** The design's obligations name functions in more than 40 files. Mutation sites
  are in 72 files. More than 20 000 lines must be right at the same time.
- **The validation round is not a second opinion.** It runs the same evaluation code on a candidate. It
  finds a wrong candidate. It does not find a wrong rule.

Can the invariants be stated once and checked by a machine? Two of them can, inside the present design, and
§8 says how. The function-value invariants cannot, because they are not one invariant.

### 3.7 Verification

What exists is good, and it is worth more than the checker code:

- a sanitiser that traps a stale read at run time;
- generators with an oracle;
- 296 `run/Sanitiser*` programs, 99 of them accepted twins;
- a mutation harness with 190 rule mutants;
- a whole-corpus diff against v1.

What it cannot do:

- **Generators show what they generate.** The design records that one class was called empty three times and
  was not (line 5180).
- **The sanitiser has blind spots.** The level audit found 798 accepted programs with a wrong output and no
  trap (#2377).
- **About one rule in six is pinned by nothing.** 32 of 172 mutants failed no test on 2026-11-07. The mutation
  step is not a gate.
- **The diff against v1 has 9 026 excused lines.** A reviewer cannot read that list.
- **Review of the last fix is the main detector.** A fix is then no evidence about its neighbours.

What makes soundness evident and not only tested:

1. A representation in which the two value invariants hold by construction (§6.2, §6.3).
2. One invariant for the whole checker, small enough to state on a page and to prove on a core calculus.
3. A kernel of a few thousand lines that a model in Lean can follow rule by rule. `proofs/ownership/` has the
   interpreters and the oracle bridge for that work.

### 3.8 Precision

**No static checker accepts every safe program.** So "precise enough that it never refuses a real, safe
program" needs a testable form. This review proposes two forms: the real programs of the repository are clean,
and a developer can predict a refusal from a short written rule.

**Real code today** (Appendix A, command 2; 32 roots: `core/`, the platforms, the examples, the benchmark
programs):

| | Demands | Accepted | Refused |
|---|---:|---:|---:|
| v1 | 308 | 308 | 0 |
| v2 | 340 | 308 | 32 |

v2's causes: `disjoint` 14, `held-operand` 6, `unknown` 5, `escaped` 3, `top-level` 2, `call` 1, `need` 1.
Seven refusals are in `core/`, and the requirements forbid any refusal there. Three of the seven are these:

```beni
keys dict = foldl dict [] λkey _ keyList → List.push keyList key          -- core/Dict.beni:550
values dict = foldl dict [] λ_ value valueList → List.push valueList value
toList dict = foldl dict [] λkey value list → List.push list ( key, value )
```

Each folds over a dictionary and pushes onto a new list. v2 refuses each as `disjoint`.

Two facts make the real picture worse than the table. v2 makes no demand at a program's entry yet, so `update`
of each application is unchecked. And v2 treats a record update as a copy.

**The known list.** `tests/blackbox/ownership-v2-known.txt` has 9 026 entries. 382 are "v1 accepts, v2
refuses", and 1 173 are a demand that only v2 makes and refuses. The design says that the parity requirement
"is not met" (line 141).

**The whole-corpus diff today** (Appendix A, command 7; 2 721 roots). 5 230 demands have the same verdict
under v1 and v2. 8 971 differ in a way that the known list excuses. v2 makes none of v1's 9 688 record-update
demands. The diff is not clean on `master`: 10 demands differ with no line in the list, 55 lines of the list
no longer occur, and one root does not end (§4.3).

**Structural losses, in the order that real code meets them.**

| Loss | Cause in the design | Would a permission on a type position have it? |
|---|---|---|
| Folds and loops with an accumulator | the answer of a callback is tracked by label and route | no |
| A function value that no label names (returned, stored, composed) | a code has no name but a label | no |
| The program entry | not built | no |
| Two objects at one slot: one atom for all fresh objects of a call | a slot names a family, not an object | no |
| Cells with fibers | the suspension rule is not built; an escape has no end | in part |
| The size limit on ordinary programs | contracts list paths | no |
| A value inside one arm of two unrelated choices | inherent | yes |
| JavaScript and unknown values | inherent | yes |

**The four rules that the owner names.**

- *Cells and the suspension rule (#1734, #2401).* Structural. A contract has no fact about suspension, and an
  escape has no end. So two coarse rules stand in for the specified one.
- *The returned writer (#2394).* Structural. A function that leaves its frame has no label, so the checker
  refuses it at the return. The sweep of 2026-11-09 counts 5 184 refusals of 5 184 such programs.
- *Keep then hand (#2326).* A rule not yet written, in part. A holder of a callback's answer keeps the
  callback's argument without a condition. An amendment is approved and is not on `master`.
- *An entry with no caller (#2004).* A stage that is not built. It is a hole and a refusal at the same time.

**What real contracts need.** This review read all 1 872 contracts that v2 computes for `core/`, the TEA
platform and `bench/corpus`:

- 45 contracts write a parameter (2.4 %).
- No contract writes at a level slot. The level mark is in 149 contracts, only where a result or a read is
  described.
- In each requirement, the slots that must be unique are exactly the written slots. Each other slot only has
  to be apart from them.

So real code uses one fact about a write: "the caller owns this parameter here". The precision that level
paths and selections add serves fixtures, not the programs in the repository.

---

## 4. Speed

### 4.1 Measurements

ReleaseFast compiler, `--jobs=1`, the best of five runs, `dump --stage=ownership --ownership-everywhere`.
"Lines" are the lines of the modules that the pass walked. A platform root walks `core/` too.

| Root | Lines | Type check ms | v1 ms | v2 ms | Type check lines/s | v1 lines/s | v2 lines/s |
|---|---:|---:|---:|---:|---:|---:|---:|
| `core` | 21 816 | 37.2 | 271.7 | 180.7 | 587k | 80k | 121k |
| `platforms/browser` | 43 032 | 73.7 | 265.3 | 530.1 | 584k | 162k | 81k |
| `platforms/browser-tea` | 15 694 | 25.5 | 119.9 | 86.9 | 616k | 131k | 181k |
| `examples/conduit` | 3 560 | 9.2 | 35.7 | 34.6 | 385k | 100k | 103k |
| `examples/bike-wars` | 1 520 | 3.6 | 12.6 | 10.1 | 424k | 121k | 151k |
| `bench/corpus` | 3 795 | 8.0 | 52.5 | 77.0 | 473k | 72k | 49k |
| **all 32 roots** | 169 826 | 296.3 | 1 204.6 | 1 498.0 | **573k** | **141k** | **113k** |

- v2's pass costs 5.1 times the type check. v1's costs 4.1 times.
- The type check and v2 together run at about 95 000 lines per second on one core. The budget for all of
  checking is more than 250 000 (`fast-compiler.md` §2, requirement R-7.1).
- A build's own run (`check --no-cache`) of the 24 application roots walks 15 699 lines. There the type
  check runs at 419 000 lines per second, v1 at 192 000 and v2 at 94 000.

R-7.1 also names a target for the pass: "≤ +10 %" on `check`. The table gives the pass's time against the rest
of the same run (one thread, `check --no-cache`):

| Root | Rest of the run ms | v1 adds | v2 adds |
|---|---:|---:|---:|
| `examples/conduit` | 21.5 | +118 % | +145 % |
| `examples/bike-wars` | 11.4 | +69 % | +70 % |
| `examples/sternhalma` | 9.8 | +41 % | +63 % |
| `examples/todo/page` | 10.5 | +21 % | +44 % |
| `bench/corpus` | 15.9 | +169 % | +453 % |

No gate tests the target. The design moves that test to the last stage, and accepts "a report" in its place
(line 6701).

The generated modules of the cost gate are all green: 0.7 to 24.7 ms against a bound of 2 000 ms. They are
small, and the bound is 80 times the largest measurement.

### 4.2 Where the cost goes

**Into declarations that write nothing.** v2 gave an account to 4 355 declarations of the 32 roots and used
9.5 million records. 4 209 of the declarations hold no write. They used 91.9 % of the records. In all that
code, 340 writes need a verdict: fewer than five for each thousand lines.

**Into facts for each path of a type.**

```beni
decodeValue decoder value =                 -- bench/corpus/Codec/Decode.beni:24
    case decoder of
        Decoder run →
            run value
```

This function returns what a callback answers. Its result type is `Result Error a`. `Error` is recursive and
holds a JSON `Value`, which is recursive too. Four places of that type hold an object: three lists and the
type variable. The contract has 96 entries, 57 of them at a level mark. Each entry says the same thing: "the
callback's answer". The function costs 9 569 records.

**No hot loop.** The profile is flat (Appendix A, command 4). The fixed dictionaries, the accounts and the
interning of `Ids.zig` take 13 to 21 %. The allocator takes 10 to 12 %. The standard containers take 8 to
10 %. Then about 40 files take less than 6 % each. The cost is the count of facts and the tables that hold
them. No single optimisation removes it.

### 4.3 Bounded by design, or by the limit

Mostly by the limit, and in places by nothing.

- **By design:** interning, the use index, the holder index, one walk for each code.
- **By the limit only:**
  - the size of a contract: result slots times parameter slots, each named by path and by route;
  - calls times the callee's obligations;
  - demands times holders;
  - pairs of leaves through call chains;
  - rounds times the size of a group.
- **By nothing:** work that reserves no record. A diamond of type aliases costs 4ⁿ instructions (#2121). One
  corpus file ran for 81 CPU hours with no refusal (#2139). This review met the same file,
  `tests/corpus/check/good/AliasDiamondChain`: its v2 dump used one core for 24 minutes, and the review
  stopped it.

**The limit is a guard, not a budget.** A declaration is refused only past about 1 024 records for each
instruction, plus 65 536. A program can stay under that on each declaration and still take seconds.

**The limit refuses ordinary code on `master`.** Under v2, five declarations of the benchmark JSON decoder
stop at it: `field`, `index`, `listHelp`, `pairsHelp`, `oneOfHelp`. Each has 8 to 13 lines, and none writes a
list. With the limit raised, they need 356 669 to 527 025 records: five to eight times the default. For
`field`, 295 826 of the records are conditions. No line of the known list covers this, so no gate sees it.
Issue #2199 reports the same for hand-written TEA, `Dict` and AST programs.

**The blow-ups of this week.**

| Issue | Shape | Growth | State |
|---|---|---|---|
| #2034 | a tower of wrappers that pass a callback on | 2ⁿ, in the type checker and not in this pass | fixed there, by shared type nodes |
| #2035 | a wide record of callback answers | N × M, three times | two structural fixes and a certificate bit for the fresh case; the other case is still N × M |
| #2412 | a holder of a call's wide result | the limit at 128 fields | the same certificate bit; its first version accepted a wrong write |
| #2418 | a chain of calls that each rebuild a record | 2ⁿ, the limit at 12 calls | a memo; n² stays (#2420), the limit near 70 calls |
| #2385 | a slot moved to another root by every route | one function of `bench/corpus` at 99.75 % of its allowance when filed | open; a later cost fix lowered that function |
| #2348 | the arrivals of a join at each level path | n² arrivals for a slot; 486 new refusals at the limit | open |
| #2391 | `hg (hg f)` over a cycle of four types | 415 854 of 524 288 records | open |
| #2139 | three diamonds of type aliases | no end | open |

**The fixes removed instances, not causes.** Two were structural. One was a certificate bit for
the fresh case, and it left the other case at the limit. One was a memo. The owner's rule is "no caches except
`Pairs.solved`", but `Relation.zig` alone has about ten more result tables (lines 125 to 190). The
representation computes each answer again by default, so each chain needs a table to stay under the limit.

**The design text contradicts the code in four places.** §4.4 says that no round limit exists. The code stops
a group at 4 096 rounds (`Groups.zig:1698`). The distinct check gives up at 4 096 rounds and answers
"unprovable" in silence (`Distinct.zig:521`). Label depth stops at 8 and at 32 (`FedThrough.zig:22`,
`CaptureRuns.zig:20`), and a choice of closures stops at 64 arms (`AltCodes.zig:20`). The requirements forbid
each such cap.

### 4.4 Will this architecture meet the budget

No. Three properties of the architecture prevent it, and tuning does not change them:

1. Each body is walked, evaluated, read off and committed, with or without a list.
2. A contract's size follows the paths of the types, not the source.
3. Each code of a declaration scans the whole declaration, and each round of a recursive group evaluates
   each member again from nothing.

A pass inside the budget does work in proportion to the source and to the places of the types it meets. §6
gives one.

### 4.5 The two-pass record design

The records stack (#2426 to #2444) checks each module twice. The list pass reads a record update as a new
record. The record pass reads it as a write of its base. The two passes share no alias fact.

- **Cost.** The only numbers are from a Debug compiler: Conduit 237 ms with one pass, 388 ms with two
  (#2426). That is the "+40 to 65 %". No ReleaseFast number exists. A second walk of the same size halves
  the rate of the pass on each module that has a record update. The figures of §4.1 are the start.
- **Why two passes.** One model for both moved 70 list lines in 41 fixtures. That broke the requirement that
  list verdicts do not depend on record facts. The split is a way round limits of the slot domain: one
  requirement for each contract, marks with no kind, no path for a scalar field.
- **Is the split forced by the language?** No. A record and a list are both objects that a write edits. A
  record differs in one point. A write needs the *field*, not the whole object, so liveness is by field. v1
  did records in one walk. Its record conditions cost about 2.4 % of the walk of `core/`.
- **Risks.** The precision work moves into the record pass (it has its own width cap of 64 places). Each rule
  has two behaviours. Record verdicts are reported and not enforced, and no record sanitiser exists for v2.
  #2443, an accepted wrong update, stood behind seven clean reviews.

**Verdict.** Two passes are acceptable as a scaffold with a stated exit. They are not the end state. In the
target design a record is an object with one cell for each field, and one pass judges both (§6.6).

---

## 5. Direction

### 5.1 Convergence, or a wrong domain

Both, in different parts.

- **The carrier converged.** No amendment since 2026-11-02 changed slots as the index, values, leaves or the
  fields of a contract. The cost wall that ended the shape engine fell in three days. The contract format did
  not change for the last ten fixes.
- **Two parts built on it did not.** The section on places grew from 13 kB to 72 kB in eight days. The
  section on callbacks grew from 602 to 974 lines in four. A new named concept entered on each work day. New
  sanitiser fixtures for each day since 2026-11-05: 60, 47, 74, 22, 51. The amendments follow programs that
  failed. The argument did not predict them.

The mechanisms that the owner lists sort the same way. `CallFolds`, `BelowAnchors` and `relsBelow` are one
invariant applied three times, so that part converges. `RunKeeps`, `HandedWrites`, `KeepsNot`, `FnSite`,
`CaptureRuns` and `AltCodes` are six rows of a table with no end. `Peel` and the fresh-only bit are cost work,
and one of them opened a hole.

### 5.2 The stage order

The plan runs callbacks, then records, then modules and the cache, then program entry and sends. After
those come `Dict`, the in-place lowering, parity and cost, and the switch.

- **The value comes last.** A plain array edited in place reaches a user only after each other stage. Today
  the lowering channel has one reader, the sanitiser.
- **The most common real case comes late.** `update` and `view` of each application have no caller that
  judges them until the entry stage. That is an open soundness hole (#2004), and it is where most application
  writes are.
- **Cost and parity come last, as a report.** The first design made the same choice, and its cost claim fell
  on the first day.
- **Each stage adds routes.** Records add a second pass. Entry, sends, markup, schemas and `Dict` each add
  rows of trusted words and new readers of the same trees.

A better order builds one thin path from the entry to the lowering first: lists and records, known
callbacks, one platform. Then it widens. §7 uses that order.

### 5.3 Prior art

| System | What it does | What beni can take |
|---|---|---|
| Clean uniqueness types; de Vries and others, 2007 | one attribute for each type position, inferred | the carrier: a small lattice on type positions |
| Futhark uniqueness types (Henriksen and others, 2017) | in-place array updates in a pure language, a compile error when unsafe, no fallback | the nearest contract to beni's; its limits (annotations, first order) are known |
| Lean 4 and Koka: borrow inference, Perceus, `fip` | parameters are owned or borrowed, inferred for each group of functions | borrowed by default, the optimistic fixed point, the loud contract |
| Roc's Morphic | modes for each slot of a type, folded for each type cycle | one name for each place of a cycle; Roc removed it for its speed, so measure |
| OxCaml modes (Lorenzen and others, 2024) | uniqueness and locality as modes, inferred inside a function | a closure that owns a unique value is used once |
| Rust NLL and Polonius | places, loans, liveness | liveness decides when an alias is dead; v2 has this and must keep it |
| Type qualifier inference (Foster, Fähndrich, Aiken, 1999; Rehof and Fähndrich, 2001) | a lattice of qualifiers on types, polymorphic, solved as reachability | a contract on a function-typed position, instantiated at each call |
| Multiplicity inference (Mogensen 1997; Matsuda 2020; Morris 2016) | principal types with inferred use counts for higher-order code | evidence that callbacks need no written signatures |
| Shape analysis; bi-abduction (Calcagno and others, 2009) | summaries as footprints; materialise and summarise | a callee's contract speaks only of what it touches |
| Summaries over a finite fact domain (Reps, Horwitz, Sagiv, 1995) | context-sensitive summaries with a polynomial bound | a cost bound by construction, which the present design does not have |
| Region inference (Tofte and Talpin; Cyclone) | a lifetime for each group of objects | only the loan of a cell's contents is a region question here |
| Dimoulas and Wand, 2009 | in-place update for higher-order programs with a proof | a second opinion on closures and nested arrays |
| ASAP (Proust, 2017) | static memory management with no annotations for an ML | prior evidence that the analysis cost is the hard part |

The project's research covered the first six and named regions. Six rows have no mention in the project's
ownership documents: qualifier inference, multiplicity inference, bi-abduction, the finite-domain summaries,
Dimoulas and Wand, and ASAP. Report 109 named the central point: cheap inferred systems put facts on type positions. The slot domain took the
index and kept two habits of the alias-analysis family. Facts say "which object", and the absence of a fact
means "no alias".

**The two families differ in one way that decides soundness.** An alias analysis accepts a write when it
knows every other holder and each is dead. That is a claim about everything else, and it needs every reader to
be complete. A permission system accepts a write when the reference carries the fact "I am the only one".
That is a claim about one thing. When a rule forgets a case, the first family accepts a wrong write. The
second refuses a right one. v2 needs both: permissions for what a frame did not build, and liveness of
holders for what it did. Today it derives the first from the second.

### 5.4 Keep, change, throw away

Lines are counted by subject over `src/own2` (this review's grouping).

| Part | Lines | Verdict |
|---|---:|---|
| Places, values, positions, the walk, liveness, regions, holders, verdicts, words, reports | 14 447 | **keep** |
| Sanitiser, generators, fixtures, mutation harness, corpus diff, layering gate | (tests) | **keep**; they are the main asset |
| Contracts, trees, read-off, grafting, fixpoint rounds | 8 022 | **change**: dense tables over places |
| Conditions and the relation: selections, pairs, routes, tags | 5 621 | **change**: a permission bit; the relation is a lookup |
| Function values: labels, supplies, needs, answers, runs | 4 243 | **replace**: a contract on the type position |
| Names of recursive levels: paths, folds, joins, anchors | 2 384 | **throw away** |
| Accounts, lanes, the growth limit and its attribute | part of 3 304 | **throw away**, when cost is bounded by design |

### 5.5 Requirements to change

Each is the owner's decision. Each forces a part of today's cost or complexity.

1. **R-7.3, no merge of call contexts.** Replace it with two rules. Each call site instantiates the
   callee's contract. Calls through one function parameter inside one body share that parameter's contract.
2. **R-8.3, parity with v1 on each fixture.** Replace it with two rules. The real roots are clean. Each
   refusal has a cause from a short written list, with a fix. The fixture corpus then measures precision.
   It does not define it.
3. **Levels told apart across calls.** `language.md` §6.8 already documents the limit for users: "The checker
   keeps one place for all the levels of one part of a recursive value". v2 tried to lift it. No real contract
   uses the result.
4. **The size limit and `@ownership_summary_size`.** The owner said: "I don't want limits, we must design a
   checker that works with any program". A cost bounded by the types needs no limit.
5. **Lists independent of records (R-8.6).** Keep the intent: a record fact never changes a list verdict.
   Test it as a property of the one pass, not by a second pass.

---

## 6. The target design

It keeps v2's lower half and changes three things. Each change removes one of the findings of §3.

This section is a sketch for the owner's decision. It is not a specification. If the owner takes it, a
normative text comes before the code (rule 1 of `CLAUDE.md`).

### 6.1 The three changes

| | Today | Target | Removes |
|---|---|---|---|
| Names | a slot is a path; levels fold by route | a **location** is a place with its context outside cycles; one location for all levels | finding 2; the path blow-up |
| Facts | which objects can arrive; no entry means fresh | a **permission** for each location; the default is no claim | finding 1 |
| Function values | labels and routes | a **contract on the function-typed location**; one rule for a function that flows into it | finding 3 |

### 6.2 Names: one location for each object

Keep the place graph. Define the locations of a type like this:

- Outside a type cycle, a location is the path to a place. So two fields of one record are two locations.
- Inside a cycle, each place of the cycle is one location, for all levels and all routes.
- A type variable is one location that stands for everything below it.

Each object of a value then has exactly one location, and a location is a node, not a route. For `Result Error
a` of §4.2 the object locations are four. For five types that name each other they are the places of the five
types, not 10⁸ paths.

Take the hole #2353. `cut t0 = case t0 of W ( W m, _ ) → W m; _ → E` returns a part of its argument that is two
levels down. With paths, the deeper lists of `m` have one name below `t0` and another below the result, and a
reader used one route. With locations, the lists of `m`, of `t0` and of the result are one location of the
type. The contract has one row: the lists of the result come from the lists of the first parameter.

A call maps the caller's locations to the callee's by the type substitution. One function computes that map,
by a walk of the two type graphs together. It is the only code that knows how names move between frames. It
has an exact specification, and a test can check it against concrete paths.

Levels stay apart where the text of one frame names them. A pattern `Node xs l r` gives three positions, as
today. A contract speaks of locations only. That is the limit that `language.md` §6.8 documents.

*Option.* Two locations for each place of a cycle: the level of the entry, and all deeper levels. The names
stay unique. It keeps "write the root's list while a deeper list is live" across a call. Decide it by
measurement on the fixtures of requirement R-4.7.1.

### 6.3 Facts: permissions

For each position of a root and each location below it, the frame holds one permission:

- **own**: each cell here is held once in this value, and nothing outside the frame's known holders reaches it;
- **shared**: no claim.

A table holds a permission for each location of the type. A location with no object does not exist in the
table, and the type decides that. So no lookup can miss, and nothing reads as fresh by default.

- An allocation gives `own`.
- A result of a call gets what the callee's contract says, as a positive term. The contract also says which
  argument locations the result can hold. The frame records the result as a holder of those arguments.
- A value from JavaScript, from a cell or from a top-level value is `shared`.
- The same position put twice into one location gives `shared` there: `[ r, r ]`.
- A parameter is `own` where the body needs it, and the contract asks that of the caller.
- Two different positions that are both `own` name different objects. So "apart" needs no table of pairs
  and no selection.

A write is accepted when its target is `own`, did not escape, and each other holder in the frame is dead
after it. The third test is today's liveness and holder check, unchanged. It is what accepts
`[ …xs, List.length xs ]` and a dead alias, which a type system with no liveness refuses.

### 6.4 Contracts

A contract is a table over the locations of the signature:

- for each parameter location: read, written (needs `own`), kept, escaped; for a record, the fields;
- for each result location: `own` if a named set of parameter locations is `own`; the parameter locations it
  can come from; or `shared`;
- for each function-typed location: a contract of the same form (§6.5).

Its size follows the places of the signature's types, not their paths. The contract of `decodeValue` is one
row: the result is the answer of the function at the first parameter. A contract mentions the caller's
permissions by name, so each call site instantiates it. That is context sensitivity at each call with no
labels.

### 6.5 Function values

A function-typed location carries a contract. The contract says:

- what a call hands each parameter;
- what the function can do with it: borrow, keep or write;
- what its answer is made of;
- how often it runs.

The rules:

- A function that flows into such a location must satisfy the location's contract. This one rule replaces the
  routes. It applies at an argument, a record field, a list element and a result alike.
- A higher-order function states what it hands its callback and what it expects. `foldl` hands the
  accumulator on from the first value and from the callback's own answer. Then "the accumulator is `own` in
  each run" is the largest solution of two inequalities. It replaces the induction rules for fed answers.
- A closure that writes a captured value is used up by a call. So a location that runs its function many
  times refuses it.
- The loops of `core/` that hand each element once stay trusted rows, as today.

With these rules the three folds of `core/Dict.beni` in §3.8 are accepted: `[]` is `own`, the lambda writes
its own third parameter and answers it, and `foldl` hands the answer on.

This is the least certain part of the target. A function that returns a function made from its arguments
needs a contract with variables, which v2 has today as a "called contract". Step 2 of §7 builds it and
measures it.

### 6.6 Records, cells, fibers, the entry

- **Records.** A record has one cell for each field. `{ r | f = v }` needs `own` on the field `f` of `r`, and
  no other holder that reads `f` later. Liveness by field exists today. An old read of `f` moves before the
  write, as the requirements say. One pass judges lists and records.
- **Cells.** What a `Ref` holds is `shared` when read out. A `modify` hands the contents as `own` to its
  callback, and the callback must give them back and keep nothing. The rule of §6.5 carries that through a
  helper, which is the open hole #2422.
- **Fibers.** A value that a spawned closure captures moves into the fiber at its last use. If not, it is
  `shared`. A loan does not live across a point that can suspend. The checker infers those points today.
- **The entry.** A platform row says that the runtime hands `update` a model that is `own` and keeps
  nothing. `view` gets the model `shared`.

### 6.7 The algorithm and its cost

For each module, visit declarations in dependency order.

1. Walk a body once. Compute values and positions as today, plus one permission table for each root.
2. Build the liveness index as today.
3. Judge each write: permission, escape, live holders.
4. Read the contract off the tables.
5. For a recursive group, iterate. The lattice of a location has two points. So the rounds are bounded by
   the number of locations, and in practice by two or three.

Let n be the instructions of a body, and L the locations of the types it touches. The walk costs O(n · L) at
most, and less with shared tables: a table that is uniform below a place is one node. A call costs the size
of the callee's contract. A contract has at most L rows, and a row names at most L parameter locations. The
instantiation map costs the product of two type graphs once for each instance of a signature.

No part depends on the number of paths, on call depth or on the count of labels. So no growth limit is
necessary. The target is the budget of R-7.1. Step 0 measures it.

### 6.8 The soundness argument

**One invariant.** Take a frame, a position `p` and a location `ℓ` with the permission `own`. Each cell at
`ℓ` below `p` has one path from `p`. It has no path from anything else, with two exceptions: the holders that
the frame records, and the caller's own reference to an argument.

**The proof has one case for each rule.** About 25 instruction rules, the call rule and the function rule.
Each keeps the invariant. A recursive group uses the validated fixed point, as today.

**The theorem.** A write is accepted only when its target is `own`, did not escape, and each recorded holder
is dead. Then no live reference reads the old value, and the in-place program prints what the copying program
prints.

**What is closed by construction.**

- A forgotten case gives `shared`, which refuses.
- A name cannot be missed: a location is one node, and one function maps names at a call.
- A new way for a function value to travel needs no new rule. The rule sits on the location that the value
  reaches.

**What stays a claim that needs a check.** Three facts are still negative. A holder is dead. A value did not
escape. A parameter is only borrowed. The first is one dataflow pass, and a second computation can check it.
The other two come from a classification of each use, with "escapes" as the default for a use that no rule
names.

**The model.** The rules are small enough for Lean. `proofs/ownership/` has a typed core language, a copying
interpreter, an in-place interpreter and a bridge to the compiler. Point it at these rules.

### 6.9 What the target refuses that v2 accepts

1. A write at one level of a recursive value across a call while another level is shared or live. The option
   of §6.2 keeps the root level.
2. A result that depends on which of two calls of one callback, inside one body, got which argument.
3. A relation between two parameters where neither is written. No write needs it.
4. A case that needs two unrelated choices to agree. Keep v2's choice values inside a frame if the
   measurement shows a need.

The evidence that this is small is §3.8. In 1 872 real contracts no write is at a level slot, and the unique
slots are exactly the written ones. The evidence is indirect. Step 0 replaces it with a count.

---

## 7. Migration

Each step runs behind a hidden flag beside v1 and today's v2, as v2 runs beside v1 now. Nothing switches
until a gate passes. So the corpus stays green in each step.

| Step | Build | It proves | Gate |
|---|---|---|---|
| **0. The experiment** | Locations (§6.2) with a first instantiation map, permission tables (§6.3), contracts for first-order code and for known lambdas at the worded loops of `core/`. Lists only. Reuse the place graph, the walk, liveness, holders, words and reports. | Whether the simple facts carry real code, and what they cost | No sanitiser trap on the corpus and the generators. At least 300 of the 308 real writes accepted. Each lost fixture has a class. The pass runs at more than 500 000 lines per second on the 32 roots. |
| **1. Names, complete** | The test of the instantiation map against concrete paths. Type families and open rows as locations. Then delete level paths, joins and folds. | The levels class is closed by construction | The 85 `run/SanitiserLevel*` and `run/SanitiserFamily*` programs keep their verdicts or have a named class. The level generators find nothing. |
| **2. Function values** | Contracts on function-typed locations, the flow rule, closures used once, contracts with variables for returned functions | One rule covers the routes | `core/` and the platforms have no refusal. Each callback fixture that must be refused stays refused. Each rule has a mutant that a fixture kills. |
| **3. Records and the entry** | Field cells and hoists in the same pass; the entry rows; sends | One pass, and the first whole application | The examples and benchmark applications are clean with `update` checked. The record fixtures pass. A record sanitiser runs. |
| **4. Blocks and the cache** | A contract is a table of fixed shape, so the block is a flat table with a directory | Module boundaries and warm builds | The cold and warm verdicts are the same. The interface hash moves only with a contract. |
| **5. The proof** | The Lean model of the kernel, and the differential oracle against the compiler | The invariant holds for the rules as written | No `sorry` in the kernel theorem for lists, records and first-order calls. |
| **6. Lowering and the switch** | In-place lowering from the clean channel; then delete v1 and the retired parts of v2 | The value reaches a user | The list sanitiser runs the corpus clean. The cost gates of R-7.1 are tests, not a report. |

**The numbers of the first gate are proposals.** The owner sets them. The speed number has this basis: the
type check takes about 1.75 µs for a line, and the budget of 250 000 lines per second leaves about 2.25 µs.

**Cost.** Step 0 writes a few thousand lines on a lower half that exists. It is the cheapest step, and it
decides the rest. Steps 1 to 3 are a rebuild of about the size of the slot rebuild. That rebuild took the
same team three days from decision to merge. This project's estimates were wrong by a factor of three before,
so read these as sizes and not as dates. The steps delete more code than they add. A smaller kernel replaces
about 20 000 lines of the upper half, and the account with its limit goes.

**Risk.** This is the third carrier in three weeks. Three things lower that risk. The gate of step 0 comes
before any commitment. The test assets carry over unchanged: each `run/Sanitiser*` fixture stays a
regression test. And the kernel is small enough to prove, which neither earlier carrier was.

**If step 0 fails.** The count of lost fixtures and their classes say what the simple facts miss. That is
the evidence that §6 lacks today, and §8 then applies.

---

## 8. If the owner keeps the present design

Five actions, in this order. None adds a concept.

1. **One reader for a contract tree.** Each read of a result tree goes through one function that takes every
   anchor and every name. Forbid a read of a kid by a word outside it. The layering test already lists the
   11 files that do it.
2. **A read cannot be empty with no reason.** Build the rule of line 4955 (#2145). An empty read returns
   one of the five reasons by name. An empty read with no reason panics under run-time safety.
3. **Entry before records.** Close #2004 first. It is a hole in each application, and it is where real
   writes are.
4. **Time in the gates.** Put a lines-per-second test on the real roots and a time bound on each corpus root.
   Charge or bound each loop that reserves nothing (#2121, #2139). Add `bench/corpus` to the parity net.
5. **Records in one evaluation, or two passes with a stated exit.** The exit test: the record pass's list
   lines equal the list pass's over the corpus.

Also run the mutation step and the cross-check build in CI. And require the design's own rule: a pull
request that adds a route for a function value walks the six holder classes in its text. No pull request
does that today.

These actions make two of the three findings structural. They do not change finding 3, the cost of §4, or
the precision of §3.8.

---

## 9. What this review did not establish

- **The precision of the target design on the corpus.** No prototype exists. §6.9 argues from contracts, not
  from verdicts. Step 0 settles it.
- **That function contracts stay small and principal** for functions that return functions. Step 2 settles it.
- **The audits on the owner's machine.** The level audit and the callback sweep are known here only through
  the quotes in #2377 and #2393. The hole classes of §3.5 come from issues and can move by about five holes
  between neighbours.
- **Whether a quoted failing program still fails on `96e93db4af`.** This review ran no generator.
- **Memory.** Only time and records were measured.
- **Whole-process time of `check` on a large application.** The figures of §4.1 are phase times from the
  self-profile. The 100 000-line generated corpus is mostly `Int` code and tells little about this pass.
- **The papers of §5.3** are cited from memory and from the project's own reports. Check each before it
  enters a normative document.

---

## Appendix A. Commands

All from the repository root, with the ReleaseFast compiler at `zig-out/perf/bin/beni`. `TMPDIR` must point
to a directory on disk.

1. **The compiler.** `zig build test-perf "-Dtest-filter=generated module of §7.6"`. It installs the
   compiler and times the generated modules (14 lines, all green, 0.7 to 24.7 ms).
2. **Cost and verdicts on real code (§3.8, §4.1, §4.2).**
   `node bench/ownership-v2-review.mjs --roots=real --runs=5 --jobs=1`. It runs
   `beni dump --stage=ownership --ownership-everywhere --ownership=v1|v2 --jobs=1 --self-profile=<file>` on
   each root of `bench/ownership-roots.mjs` that is not a test fixture. The times are sums of the `check`,
   `ownership` and `ownership2_module` events. With `--mode=check` it times `beni check --no-cache` on the
   application roots and prints what the pass adds to the rest of the run.
3. **The limit on the JSON decoder (§4.3).**
   `beni dump --stage=ownership --ownership-everywhere --ownership=v2 --platform=node --root=bench/corpus bench/corpus`
   prints five `limit` lines. For the records that each declaration needs, copy `bench/corpus` and put
   `@ownership_summary_size(module, 400000000)` before the first import of `Codec/Decode.beni`.
4. **The profile (§4.2).**
   `perf record -e instructions:u -c 100000 beni dump --stage=ownership --ownership-everywhere --ownership=v2 --jobs=1 core`,
   then `perf report --sort symbol`, grouped by source file.
5. **The shapes of real contracts (§3.8).** The `summary` lines of the v2 dumps of `core`,
   `platforms/browser-tea/Tea.beni` and `bench/corpus`: count `writes`, `req`, `label` and the level mark.
6. **The known list (§3.8).** `grep -v '^#' tests/blackbox/ownership-v2-known.txt`, split on ` :: `.
7. **The whole-corpus diff (§3.8).**
   `node bench/ownership-everywhere.mjs --diff=v1,v2 --beni=zig-out/perf/bin/beni --jobs=4`. The script gives
   a dump no time limit, so the root of #2139 holds it until someone stops that process.

## Appendix B. More numbers

**Records for each declaration** (4 355 accounts).

- The median is 351, the 90th percentile 2 713 and the 99th percentile 55 094.
- The largest is 167 021: `shapeOf` in `core/`, with no write.
- 88 declarations use more than half of their source-proportional allowance. 57 use growth.

**Whole-process instructions** (`perf stat`, one run of the dump).

| Root | v1 | v2 |
|---|---:|---:|
| `core` | 2.22 G | 1.52 G |
| `platforms/browser` | 2.22 G | 4.32 G |
| `bench/corpus` | 0.37 G | 0.66 G |

**Kinds of accepted writes on real code.**

| The base of the write | v1 | v2 |
|---|---:|---:|
| a parameter | 185 | 220 |
| a call's result | 51 | 0 |
| a fresh value | 36 | 75 |
| a callback's parameter | 20 | 13 |
| an entry's model | 16 | 0 |

**Growth of the design and the code.**

| Date | `ownership-v2.md` lines | `src/own2` files | `src/own2` lines |
|---|---:|---:|---:|
| 2026-10-25 | 1 318 (first version) | — | plan: 21 files, 19 050 lines |
| 2026-11-02 | 11 422 (before the slot domain) | 43 | 57 515 |
| 2026-11-05 | 8 891 | 84 | 29 554 (the slot domain reaches `master`) |
| 2026-11-10 | 9 991 | 170 | 38 021 |
