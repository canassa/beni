# 112 — The ownership prototype, round 2: one rule for function values

*Research report, 2026-11-11. The owner asked for it on pull request #2451 (`plans/ownership-v3-round2-prompt.md`,
issue #2497). It is not normative. It continues [report 111](111-ownership-step0-prototype.md): the prototype
is `src/own3/`, behind the hidden flag `--ownership=v3`. It does not change v1 or v2.*

---

## 0. Verdict

**Converges for the ways that a function value travels. The border with the first-order core needed four
rounds of fixes, and then held in one blind sweep.** One rule replaces the case rules of report 111. A
function value is judged against the use of the location that it is in (`flow`), and a location that no
contract describes has the default, which refuses a function that asks for something (§2). The rule explains
the 173 of the 175 faults so far that are about a function value; the other two are first-order (§3). Before
any test ran, it predicted seven more faults of report 111's prototype, and each of the seven traps there
(§3.3). The prototype that is built to it passes the gate: 0 traps, differences and crashes on the 49 743
programs of the four sweeps, on the 44 000 programs of report 111's generators and on the 345 fixtures of the
sanitiser corpus; 299 of the 308 real writes; 954 000 lines per second (§5). The new family, 1 960 programs
of which 21 of the 28 carriers are shapes that no test had, found no fault in its one run. Report 111's
prototype traps on 371 of the same programs (§6.2). So a new way to travel did not need a new case.

Two limits belong to this verdict.

First, a search by hand after that run found three faults: 15 of 97 programs trap (§6.3). None is a way to
travel, and `flow` did not change. Two are the match between the type of a function and the type of its
holder. The third is a claim of a contract that two sources of a result are two cells. The claim rests on
answers and on arguments that a callee cannot know. It took four rounds. The fixes of the first two rounds
were cases, and each next round found a form that the fix before it did not cover: that is the pattern that
this round asks about, and here it occurred. The third fix is one check for each pair of sources, and the
fourth round added one form to that check. Two forms of this fault have no function value: they are faults
of the first-order core. Report 111's prototype traps on 14 of the 15 programs, and one is a fault that this
round made. Then a blind sweep for this claim, 3 870 programs, ran one time on the final code and found no
fault; the two earlier prototypes trap on 146 of its programs (§6.4). The sweep is blind for the checker and
not for its author: a form that the hand search did not suggest is not in it. Each run of the gate and the
family was repeated on the final code with no fault.

Second, the rule pays with precision where a function goes through a default location (a function-typed
result, a function in a value). On the new family the prototype accepts 18 % of the safe programs, and v2
48 %. The check of the third fault pays too: where one list is at two places of a call's arguments, the
prototype accepts 40 % of the safe programs of the blind sweep, and v2 each one. On real code the round
costs no write.

---

## 1. The question

Report 111's prototype is fast and precise on real code. Its rules for function values were found by tests,
not derived (report 111 §2.6, §3.9). The sweeps of `bench/ownership-sweeps/` then found 153 programs that it
accepts and that read a list after an in-place write. `master`'s v2 refuses each one.

This round decides one question: **do function values converge under one rule, or do they need a new case
for each new shape, as they did in v2?**

The method has four steps, in this order.

1. Write one rule. Show that it explains each of the 175 faults so far (§3).
2. Build the prototype to that rule. Replace the case rules (§4).
3. Pass the gate (§5).
4. Write a generator family that no earlier test covers. Run it one time. Report what it finds (§6).

---

## 2. The rule

### 2.1 Terms

- A **function-typed location** is a location whose kind is "function" (report 111 §2.1): a parameter of a
  function type, a field or an element of a function type, a result of a function type, a value that a
  function captured.
- A function value is **code** and the **cells that it captured**. The captured cells are leaves of the value,
  as the fields of a record are. So the first-order rules already say who holds them.
- The **contract of the code** says what the code does with each of its parameters and with each captured
  value: the flags `R`, `W`, `E`, the sources of its answer, and a contract for each function among them
  (report 111 §2.5). A captured value is a parameter of this contract.
- A **use** says what the holder of a function-typed location does with a function there:
  - what it hands each parameter (the sources), and if the function can write that (`free`: the holder does
    not read it again, and it hands the cell to no other call);
  - if it runs the function (`called`);
  - if it writes a cell after it handed that cell to the function (`rewrites`);
  - where the function's answer goes (the sources of the holder's result, `answer-escapes`).

### 2.2 The two states

A function value is in one of two states.

- **Known.** The frame has the code and the captured values. Or the value is the frame's own function
  parameter: the frame does not have the code, and it writes the use into its own contract, where each caller
  reads it.
- **Default.** The value is in a location that no contract describes. The default contract has two halves:
  - *What the function can ask.* Nothing. It does not write a parameter. It can keep each parameter. Its
    answer has no claim, and the answer can hold each parameter and each captured cell.
  - *What the holder can do.* Anything. It can run the function at any time, any number of times. No argument
    is the function's own. It keeps the answer.

**A missing fact is the default.** This is the one design decision of the rule. In report 111's prototype, a
function parameter with no recorded fact meant "the body does nothing with it". Each of the 153 traps, and 19
of the 22 faults of report 111, came from a fact that was not recorded and was then read as "nothing happens"
(§3).

### 2.3 The rule

> **`flow(v, U)`: the function value `v` is in a location whose holder does `U`.**
> A known function value leaves the known state only through `flow`. Each consumer of a function value is a
> `flow` with one of three uses.

The three uses:

| Use | The location | What the holder does |
|---|---|---|
| `call` | a function parameter of a callee with a contract, at a call | what the callee's contract says of that parameter, with the call's arguments |
| `inner` | a function that a known function captured | what the known function's contract says of that capture, **composed** with the use of the known function itself |
| `top` | each other location: an item of a record, tuple, list or constructor, an argument at a parameter that is no function parameter, a result, `where` evidence, a `case` as callee, an unknown callee, markup | the default of §2.2 |

A direct call is the base case: the callee is the holder, and the arguments are what it hands.

`flow` has one case for each thing that `v` can be. It has no case for where the location is.

| `v` is | `flow(v, U)` does |
|---|---|
| **known code** with contract `c` | For each parameter that `c` writes: each source that `U` hands there must be `own` (the write rule of report 111 §2.4, at the call), and `U` must hand it `free`. For each parameter that `c` lets escape: what `U` hands there escapes. If `U` writes a cell later and `c` keeps a parameter: refused. For each captured value that `c` lets escape: it escapes here, if `U` can run the function. For each captured function: `flow(captured, inner(c, U))` |
| **the frame's own function parameter** | The frame hands the function what `U` hands it. The frame's contract records that, and each caller judges its own function against it |
| **one of several values** (a `case`) | `flow` of each of them |
| **a default value** | Nothing to check: it asks nothing. What `U` hands it escapes, because it can keep it |

For `U = top` the known-code case is short: the code must write no parameter, and each captured function
flows to `inner(c, top)`.

### 2.4 Composition

`inner(c, U)` is the use of a function `g` that a known function `f` captured. `c` is `f`'s contract, and `U`
is the use of `f`.

- `c` says what `f` hands `g`, in terms of `f`'s own parameters, `f`'s captured values, fresh values and
  answers.
- A source that is a parameter of `f` is what `U` hands `f` there. So the sources of `U` take its place. If
  `U` is `top`, the source has no claim.
- A source that is a captured value of `f` is that value, as this frame has it. It is never `free`: each run
  of `f` hands the same cell.
- A source that is an answer is the answer of the function that is in that location (below).

So a chain of any depth is one `inner` in another. `comp f g = λx a → g x (f x a)` needs no rule of its own:
its result goes to `top` where `comp` answers it, so `f` and `g` flow to `inner(c, top)`, and `comp`'s
contract says that both are run with values that have no claim.

### 2.5 Answers

Where a holder's contract names "the answer of the function at this location" (in a result, or in a supply:
`List.foldl` hands the function its own answer), the answer is read off the function that flowed there:

| The function is | Its answer can hold |
|---|---|
| known code | what its contract says: fresh cells, what the use hands the parameters that it answers (by §2.4), each captured value that it answers (with no claim), and the answer of each captured function (by this table, with `inner`) |
| the frame's own function parameter | a root of its own in this frame, which holds what the function was handed |
| a default value, or anything that no row names | no claim, and each cell of each value in sight: each argument of the call, and each captured value of each known function on the way |

An answer that comes back to the function that made it (a fold) adds no cell: this is the least fixed point.

A known function that writes a parameter that is handed its own answer needs that answer `own`: made by the
function, or a parameter that it was handed as its own and did not let go. This is the largest solution, as
report 110 §6.5 says. The answer of a captured function is `own` by the same test, with `inner`.

### 2.6 Why the rule is closed

The rule has one invariant: **a known function becomes a default value only through `flow(v, top)`.**
`flow(v, top)` refuses code that writes a parameter, and it sends each captured function to `inner(c, top)`.
So each function in a default location keeps the default contract, by induction over the captures.

The places where the walk can lose the code of a known function are a finite list, and each is a `flow` to
`top` in `src/own3/Frame.zig`:

- an expression that is evaluated for its value (`mention`);
- a callee that is not one known function (`call`);
- a call with the wrong number of arguments (`apply`);
- a local function that an earlier local function names before it is bound (`usedEarly`);
- a field of an entry record that the entry rule does not describe, and each function that a described field
  captured (`entryCall`);
- a use that is too deep to follow (`flow`).

A function-typed location that `call` and `inner` do not name is `top`. So a new way for a function value to
travel (a new holder shape) is `top` until a contract describes it. It can lose precision. It cannot make a
fact "nothing happens".

### 2.7 Two things at the border of the rule

The search by hand of §6.3 found three faults. None changed `flow`. They are at the border between the rule
and the first-order core, and the rule needs both of these to be right:

- **Two readings of one type.** A known function has its own type, and its location has the holder's type.
  Both are readings of the type that the value has where it flows, and either can be the wider one (a
  function over `a` in a holder over `List (List Int)`; a function over `List Int` in a holder over `a`). A
  location of one reading is, in the other reading: the location at the same place; a wide location above
  it; and, when it is wide itself, each location at or below its place.
- **A claim that two sources are two cells is checked where the sources are known.** A contract can say what
  the callee does with an answer (§2.1). It cannot say what the answer is, and it cannot say if two of its
  arguments are one cell. A contract claims in two ways that two sources of its result are two cells: two
  locations of the result are apart, and one location that holds many cells (the elements of a list) holds
  each cell one time. The callee can know that of one source that it puts at one place. So for each pair of
  sources, and for the answer of a function at a location that holds many cells, the caller reads what the
  sources are in its own frame. If they can be one cell, the claim does not hold there (`sourcesApart`).
  The same holds one level down for the answer of a function: only a known function whose contract can know
  it has the claim that two parts of its answer are apart. The frame's own function parameter does not have
  it, and a function whose answer holds the answer of another function does not (`linearFn`). So the
  function that a recursive function hands on to itself never gets that claim. That is coarse and sound.

### 2.8 What the rule does not have

- **A contract on a function-typed result, or on a function in a value.** A function that a call answers is a
  default value, and so is a function in a record, a list or a `Maybe`. So the caller of `comp` cannot hand
  `comp` a function that writes. Report 110 §6.5 names this ("a contract with variables"); §6.2 and §7 have
  the measurement of what it costs.
- **A closure that is used up.** A closure that writes a captured value is refused in its own frame (report
  111 §2.4, rule 1). The rule keeps that.
- **First-order faults.** Two of the 22 faults of report 111 are not about a function value (§3.1).

---

## 3. The rule explains the faults

### 3.1 The 22 faults of report 111

Report 111 has 19 programs of the sanitiser corpus (its §3.9), one probe, and two faults that its generator
found (its §3.5, §3.10). 20 of the 22 are about a function value. Each is a fact about a function that was
not recorded, or that was recorded at the place the value went to and not at the function.

| Fault of report 111 | Programs | The clause of the rule |
|---|---:|---|
| An answer with no claim lost what it holds (`PairCycle*`, `PairCrossEdge*`, `LabelRounds*`) | 8 | §2.5: an answer is read off the function that flowed there. The row "anything that no row names" has no claim and holds each value in sight. No row gives "holds nothing" |
| Where the answer goes (`AnswerLeft`, `FoldKeepsAnswer`, `CellStoredCapture`, `CellStaleLength`, `FoldAnswerFedKept`) | 5 | §2.1: where the answer goes is a part of the use. `flow` lets each cell that the answer can hold escape, for each kind of value. `top` keeps the answer |
| A function that keeps what the callee changes later (`FoldHandsLabelKeeps`) | 1 | §2.1, §2.3: `rewrites` is a part of the use. Known code that keeps a parameter is refused there. A default value is refused there, because it can keep |
| Two parts of one handed value (`FoldAlternativesShared`, `RecordCallbackShared`) | 2 | §2.3: each source that the use hands at the written part must be `own`. The demand is the write rule on the part, with the other parts as operands. One place makes each such demand (`OwnSink.atoms`) |
| Evidence (`EvidenceWriter`) | 1 | §2.3: `where` evidence is a consumer that no contract describes: `top` |
| An `entry` record of an unknown shape (`EntryUnsupported`) | 1 | §2.3: a record of functions that goes to code with no contract: each field flows to `top` |
| A captured function that writes (the probe) | 1 | §2.4: `inner`. Report 111 refused each such program. The rule judges it: the write is a demand on what the fold hands the lambda, and the safe twin is accepted |
| A new name with no point (the generator, seed 144) | 1 | §2.3: "the holder could let a function write" is a fact of the use. If a write happens is a fact of the function that flows there. Report 111 took the first for the second. Its fix (a point on the old name) is the sound encoding, and it stays |
| A prepend (`PrependFrontHeld`) | 1 | not a function value: a first-order row of `List.cons` was wrong |
| `[ q, q ]` lost its sources (the generator's first run) | 1 | not a function value. It is the first-order form of the same default: a location with no claim keeps what it can hold |

So the rule explains the 20 faults that are about a function value. The other two are faults of the
first-order core. The rule does not explain them and does not need them. The second is the same design
decision (§2.2) in first-order form.

### 3.2 The 153 traps of the sweeps

| Class | Programs | What happened | The clause of the rule |
|---|---:|---|---|
| A nested fold whose callback is a composition (`nest.acc.*.comp.*`) | 129 | `cb` is a known function in `scenario`. The outer lambda captured it, so in the lambda's frame it is a function parameter. The lambda hands it to `comp`, and `comp`'s contract had no fact for its function parameters. So the lambda's contract had no fact for `cb`, and nothing judged `cb`'s write | §2.2: `comp` answers a function, so its result is `top`, and its two functions flow to `inner(c, top)`. `comp`'s contract says that it runs both with values that have no claim. The lambda's contract says the same of `cb` (the frame's own function parameter). `scenario` judges `cb` against that: refused |
| A closure handed back without a run, then run two times (`zero.*.via`) | 24 | The closure `λ⊤ → p k` hands the captured list `k` to the captured function `p`, which writes its parameter. The closure writes none of its own parameters, so the test "does it write its parameter" passed, and it went into a `Maybe` | §2.3, §2.4: the closure flows to `top`, so `p` flows to `inner(c, top)`. `c` hands `p` a captured value in each run. That is never `free`: refused |

### 3.3 Seven faults that the rule predicted

The rule was written before the prototype was rebuilt. The invariant of §2.6 gives a list of the places where
the walk can lose a known function. Each place in that list with no `flow` in report 111's prototype is a
fault. Seven probes were written from the list, before any generator ran on the new code. Each one traps on
report 111's prototype (`1692066993`).

| Probe | The shape | The clause |
|---|---|---|
| `joinArg` | `List.map xs (case c of 0 → λl → List.push l 1; _ → λl → l)`: a function in an arm of a `case`, at a function parameter | §2.3: one of several values: `flow` of each |
| `joinCallee` | `(case c of 0 → λl → List.push l 1; _ → λl → l) q`: a `case` as callee | §2.6: a callee that is not one known function: `top` |
| `later` | a local function `a` calls the local function `b` before `b` is bound, and `b` writes its parameter | §2.6: a function that was used before it was known: `top` where it is bound |
| `selfPass` | a local function hands itself to `List.map` | §2.2: a function that names itself is the known function, with its contract so far |
| `capEsc` | `List.map [ 1 ] λx → …Ref.set r k…`: a closure puts a captured list into a cell | §2.1, §2.3: a captured value is a parameter of the code's contract. What the code lets escape escapes where the function goes to a holder that can run it |
| `capEsc2` | the same closure, answered by a function | the same, at `flow` to `top` |
| `ansTwice` | `r = f xs`, `[ r, r ]`: one answer of a function parameter at two elements | §2.5: the answer of the frame's own function parameter is a root of the frame. One root at two places is one cell at two places |

The seven are black-box tests now (`tests/blackbox/check_test.zig`, "the faults of round 2 are refused"),
with the two classes of §3.2. Report 111's prototype accepts each write of that test's module.

---

## 4. The prototype as built

### 4.1 What changed

All changes are in `src/own3/`. `src/own/` and `src/own2/` did not change.

| | Report 111 | This round |
|---|---:|---:|
| `Frame.zig` | 3 073 lines | 3 828 |
| `Check.zig` | 921 | 971 |
| `Loc.zig` | 621 | 658 |
| `src/own3/`, all | 5 162 | 6 010 |

**Removed** (each was a rule for one way that a function value travels):

| Report 111's function | What it was |
|---|---|
| `leak` | a known function that is evaluated for its value: refuse it if it writes a parameter |
| `handFunction` | a known function at a callee's function parameter; three branches by the kind of the value |
| `passFunction` | the frame's own function parameter at a callee's function parameter |
| `throughClosure` | the frame's own function parameter, captured by a known function at a callee's function parameter (two levels, written out) |
| the rule "a captured function cannot write" in `handFunction` | another captured function: no composition, a refusal |
| `supplyOwn`, `handedBack`, `expandAnswer`, `escapeAnswer`, `escapeSupplies` | each read a supply as "a source of the callee `c` with the arguments `args`": one level |
| `selfCode` | a local function that calls itself: a contract with no captured value, or an unknown callee |

**Added** (`Frame.zig`, the part "function values: one rule"):

| Function | What it is |
|---|---|
| `Use` | the three uses of §2.3. `inner` has a pointer to the use of the function that captured: a chain of any depth |
| `flow` | §2.3: the cases by what the value is |
| `flowCode`, `flowOwn`, `flowUnknown` | the three rows of the table of §2.3 |
| `flowCaptures`, `innerUse`, `captureEscapes` | §2.4, and the contract's flags on a captured value |
| `resolve` | what a source of a use is in this frame. A parameter of a known function that has the location is what that function's own use hands it. This is the one place where two contracts compose |
| `OwnSink`, `EscSink`, `DraftSink`, `FlatSink` | what is done with each part that `resolve` gives: it must be `own`; it escapes; it goes into the frame's contract; it is a cell that an answer can hold |
| `ownSupply`, `answerOwn`, `passesOn`, `handedBack` | §2.5: a written parameter, and an answer that comes back |
| `answerOf`, `answerOfCode`, `answerOfParam`, `lostAnswer` | §2.5: the table of answers |
| `mention`, `flowTop`, `usedEarly`, `selfValue` | §2.6: the places where a function becomes a default value, and a function that names itself |
| `slotsOf`, `answersAt`, `partBelow`, `Loc.belowWide` | §2.7: two readings of one type (added after the search by hand of §6.3) |
| `sourcesApart`, `argsApart`, `partsOf`, `linearFn`, `handsOn` | §2.7: a claim that two sources of a result are two cells is checked where the functions and the arguments are known (added after §6.3) |

Outside that part:

- `finish` writes a contract for each parameter of a function type, also when the body does nothing with it.
  A parameter with no function contract is one that the checker does not follow: a caller hands it a function
  as to `top`.
- `Check.bottomContract`: the rounds of a recursive group, and of a local function that names itself, start
  from "the body does nothing with the function", not from "no contract". Contracts only grow, and "lost"
  does not go away.
- `call` and `methodCall` evaluate an argument at a function parameter with no `mention`. An argument of an
  identity stays the function that it is.
- `dupOverlap` reads one answer at two places as one cell at two places (§3.3, `ansTwice`).
- `Loc.noObject`: a function's type can be wider than the holder's (a function over `List a`, handed a `List
  Int`). The location of `a` has no cell there. Report 111's prototype read that as "no rule follows": no
  claim, and each argument in sight. It refused a fold with a `let`-bound callback for it (§5.5).

### 4.2 What stays a case

The rule has no case for where a function goes. Three things are still lists, and each has a default:

1. **The kinds of value in `flow`**: known code, the frame's own function parameter, one of several, default.
   A kind that the walk does not name is the default.
2. **The places of `mention`** (§2.6). The default of the walk is `mention`: an expression is evaluated in the
   mode `value` unless its consumer is a callee position, an argument at a function parameter, or a binding.
3. **The entry rule** (report 111 §2.7). It is a row of the platform, not a rule for function values. Its
   functions' captured functions flow to `inner(c, top)`.

---

## 5. The gate

All figures are of the final code (`51a1bb0eff`, after the fixes of §6.3) merged with `master`
(`40a78316a1`), on one machine, 2026-11-11. The speed figures and the first run of each sweep are of a
ReleaseFast compiler (Zig 0.17.0, LLVM). The second run of each sweep is of a ReleaseSafe compiler of the
same sources, in which each bounds check of the checker is on. Appendix A has each command.

The prototype passed this gate two times. The first time was before the family of §6 ran (`f5a4bea289`,
with the ReleaseFast compiler). The second time was on the final code. The tables have the figures of the
final code. Against the first time: three of the four sweeps have the same verdict for each program, and
`recursive-levels.mjs` has 84 safe programs fewer with `SAME` (§5.1); the figures of §5.2 are the same; in
§5.3 the final code accepts one more fixture.

| Gate of the owner's request | Result | |
|---|---|---|
| 0 `TRAP`, `DIFF` and `CRASH` on the four sweep generators | 0 of 49 743 programs, with each of the two compilers (§5.1) | **holds** |
| 0 on report 111's two generators | 0 of 44 000 programs (§5.2) | **holds** |
| 0 on the sanitiser corpus | 0 of 345 fixtures (§5.3) | **holds** |
| At least 299 of the 308 real list writes accepted | 299 (§5.4) | **holds** |
| More than 500 000 lines per second | 954 000 on the modules that v2 walks; 1 172 000 on its own walk (§5.4) | **holds** |

The gates of the repository (`zig build gates`) are green on the same tree.

### 5.1 The four sweeps

| Generator | Programs | `SAME` | `REFUSED` | `TRAP` | `DIFF` | `CRASH` | `LIMIT` |
|---|---:|---:|---:|---:|---:|---:|---:|
| `recursive-levels.mjs` | 16 131 | 4 276 | 11 855 | 0 | 0 | 0 | 0 |
| `folds-callbacks.mjs` | 30 300 | 6 182 | 24 118 | 0 | 0 | 0 | 0 |
| `callbacks-keep.mjs` | 720 | 108 | 612 | 0 | 0 | 0 | 0 |
| `handed-back.mjs` | 2 592 | 0 | 2 592 | 0 | 0 | 0 | 0 |

Each of the 153 programs of `traps-v3-1692066993.txt` is `REFUSED`.

**Precision against v2.** A program with the twin `dead` or `none` reads nothing after the write, so it is
safe, and `SAME` is the right verdict. `kept` programs keep a value: some are safe (each run of the callback
gets a new list), and `SAME` is a correct verdict for those.

| Generator | Twin | Programs | `SAME`: v2 | report 111's prototype | this round | v2 only | this round only |
|---|---|---:|---:|---:|---:|---:|---:|
| `recursive-levels.mjs` | `dead` | 5 377 | 5 208 | 4 360 | 4 276 | 1 047 | 115 |
| `folds-callbacks.mjs` | `dead` | 10 476 | 2 981 | 3 299 | 4 220 | 505 | 1 744 |
| `folds-callbacks.mjs` | `kept` | 9 348 | 1 456 | 1 510 | 1 962 | 411 | 917 |
| `callbacks-keep.mjs` | all | 720 | 105 | 108 | 108 | 0 | 3 |
| `handed-back.mjs` | all | 2 592 | 476 | 60 | 0 | 476 | 0 |
| the two `dead` rows | | 15 853 | 8 189 (52 %) | 7 659 (48 %) | 8 496 (54 %) | | |

Report 111's prototype also has 153 `TRAP` on these programs (129 and 24), which are not in its `SAME`
columns.

- **Recursive levels.** v2 accepts 97 % of the safe twins, and the prototype 80 %. This corner is first-order.
  The prototype of the first gate had report 111's verdict on each of its programs (4 360 safe twins). The
  final code refuses 84 of those. Each of the 84 has a callee over a recursive type that answers its argument
  or a part of it (`cut : G a → G a`), and an argument that is deep enough for the type to fold. The frame
  records one list of such a value at two of the folded locations. The check of pairs of §2.7 reads the one
  argument at two of its locations, finds that list at both, and makes the parts of the result "not apart".
  That is the price of the fix of §6.3 in a first-order corner. The exact check for two locations of one
  argument is the argument's own claim that its parts are apart, and the frame has it. That change was not
  made: it is a change after the last run of the gate (§8).
- **Folds and callbacks.** The prototype accepts more safe twins than v2 (40 % and 28 %), and more than
  report 111's prototype (31 %). It refuses 157 programs that report 111's prototype accepted with the same
  output, and it accepts 1 512 that report 111's refused. v2 accepts 505 safe twins that the prototype
  refuses. Most are a composition (`comp`) of a callback that writes: a function-typed result is a default
  value (§2.8).
- **Handed back.** Each program of this generator has a closure that writes a captured list. The prototype
  refuses each such closure in its own frame (report 111 §2.4), and the closure that hands a captured list
  to a captured function that writes (§3.2). v2 accepts 476 of the programs, where the closure runs one
  time. Report 111's prototype accepted 84, and 24 of those trapped.

### 5.2 Report 111's two generators

| Run | Programs | Same output: v1 | v2 | prototype | Traps and differences of the prototype |
|---|---:|---:|---:|---:|---:|
| first family | 2 000 | 450 | 450 | 502 | 0 |
| second family | 2 000 | 708 | 458 | 705 | 0 |
| first family, long run (seeds 2 001 to 22 000) | 20 000 | 4 641 | 4 641 | 5 058 | 0 |
| second family, long run (seeds 2 001 to 22 000) | 20 000 | 7 152 | 4 739 | 7 247 | 0 |

The first family is first-order, and its figures are those of report 111. In the second family's long run the
prototype accepts 7 247 programs (report 111: 7 212). It accepts 265 that v1 refuses and refuses 170 that v1
accepts; against v2 the figures are 2 657 and 149. v1 traps on 4 of the 20 000, as in report 111 (#2474).

### 5.3 The sanitiser corpus

345 fixtures of `tests/corpus/run` have a `.sanitize-lists-v2` file. v2 accepts 163 of them and refuses 182.

| | Report 111, final | This round |
|---|---:|---:|
| v2 refuses, the prototype refuses | 182 | 182 |
| v2 refuses, the prototype accepts: trap or different output | 0 | 0 |
| v2 accepts, same output | 95 | 100 |
| v2 accepts, the prototype refuses | 68 | 63 |

The 63 losses by the prototype's cause (a fixture counts once for each cause that it has): `call` 22,
`unknown` 19, `supply` 18, `captured` 7, `later-use` 6, `escaped` 3, `disjoint` 1.

### 5.4 Real code and speed

`bench/ownership-v2-review.mjs` on the 32 real roots of report 110, five runs, the best time of each phase,
`--jobs=1`.

| | Report 111 | This round |
|---|---:|---:|
| Of the 308 writes that v1 judges: accepted at the same position | 299 | 299 |
| Refusals at a position where v1 has no line | 0 | 2 |
| Lines per second, on the modules that v2 walks | 1 049 000 | 954 000 |
| Lines per second, on all that it walks | 1 321 000 | 1 172 000 |
| v2, lines per second | 119 000 | 121 000 |

`master` has more lines than at report 111: v2 walks 185 325 lines (report 111: 171 766), and the prototype
572 966 (558 336). The code of the first gate, on `master` at `59ea68b8eb`, measured 962 000 and 1 216 000
lines per second. The final code is 1 % and 4 % below that, on a `master` with more lines. Against report
111 the two figures are 9 % and 11 % lower.

The nine writes that the prototype does not accept are the nine of report 111 §4.4, with the same causes. Six
of them are a function that a call answers (§2.8).

**The two new refusals** are `compare` and `eq` of `platforms/browser/Hosted.beni`:

```beni
compare a b = Js.pure λ⊤ →
    …  ta = Js.get (Js.from a) "t"  …
```

`Js.get` is a `foreign` with no word, so each argument escapes (report 111 §2.5). The lambda captured `a` and
`b`, so its contract says that it lets them escape. Report 111's prototype did not read that flag where the
lambda went to `Js.pure` (§3.3, `capEsc`). The rule reads it. Then `compare` lets its operands escape, and the
prototype refuses a comparison that does that. The refusal is correct for the rules that the prototype has.
It goes away with a row on `Js.get` (report 111 §7, item 5).

### 5.5 What the rule gave back

The rule was written to close holes. It also accepts programs that report 111's prototype refused, because a
case that was a refusal there is a composition here:

```beni
h = λa x → List.push a x
r = List.foldl [ 1, 2 ] q λx acc → h acc x      -- a write of `q`, at the call of the fold
List.length r                                    -- `q` is not read later: accepted
```

Report 111 refused each lambda that calls a captured function that writes. Here the write of `h` is a demand
on what the fold hands the lambda: `q`, and the lambda's own answer. With `List.length q` after it, the
demand is refused for the right cause (`later-use`).

---

## 6. The convergence test

### 6.1 The family

`bench/ownership-sweeps/function-values.mjs` makes 1 960 programs. It was written after the rule was fixed.
It was checked with a plain build only (each program builds and runs with no checker), and then it ran one
time under the prototype, after the gate of §5 passed. No program of it ran under a checker before that.

Each program has a callback `cb` of type `Int, List Int → List Int`. The name of a program is
`<carrier>.<runner>.<act>.<mode>`.

| Part | Values |
|---|---|
| carrier: how the callback gets to the runner (28) | as it is (`dir`); compositions two and three deep (`comp2a`, `comp2b`, `comp3`), a function that answers a function made from its argument (`wrap`, `wrap2`), both (`deep`); a type variable (`ident`, `first`); a record field (`rec`, `recarg`), a tuple (`tup`), a list of one and of two callbacks run by a fold (`lst`, `lst2`), a `Maybe` (`may`, `mayarg`), a cell (`ref`); one of two functions (`join`); partial application of a function that runs the callback, and of a top-level function with the act (`part`, `parttop`); a function that answers the callback, and one that answers a function that answers it (`ret`, `retret`); a callback that answers a callback (`cbcb`); a callback that runs a fold with the callback (`viafold`); two top-level functions that call each other and run the callback (`mutual`); a local function that calls itself, that hands itself to a fold, and two local functions that call each other (`selfrec`, `selfpass`, `later`) |
| runner: how the carried function is run on the shared list `s` (7) | one call; two calls in a chain; two runs on the same list; `List.foldl`; a hand-written fold; a nested fold; `List.map` over a list that holds `s` |
| act: what the callback does (5) | writes the list that it is handed (`push`); writes it, and a task reads the written list later (`keep`); hands a captured list to a captured function that writes (`pushcap`); answers a captured list, and the caller writes the answer (`anscap`); answers the list that it is handed, and the caller writes the answer (`same`) |
| mode (2) | `live`: the program reads `s` and the captured list after the run. `dead`: it reads only the result |

**What is new in it.** The four sweeps have, as the origin of a callback: a lambda, a local, a top-level
function, a function that answers the callback, `ident`, a composition one deep, and a partial application of
one argument. `handed-back.mjs` has a closure that a callee hands back in a record, a tuple or a `Maybe`. The
new family has those as controls (`dir`, `ident`, `comp2a`, `ret`), and it adds:

- a composition two and three deep, and a composition of a function that answers a function;
- a callback in a record or a `Maybe` that goes to a function which runs it; in a list, run by a fold; in a
  cell;
- one of two functions;
- a function that answers a function that answers the callback, and a callback that answers a callback;
- recursion through a callback: two top-level functions, a local function that calls itself or hands itself
  on, and two local functions that call each other;
- each of these with each runner, among them two runs on one list and a nested fold;
- a callback that answers a list (captured, or the one that it was handed), where the caller then writes the
  answer.

Four carriers are controls. Three carriers (`join`, `later`, `selfpass`) have the shapes of three probes of
§3.3: the rule predicted those, and the prototype was built with them in mind. The other 21 carriers are
shapes that no test of the prototype ran before.

### 6.2 The result

One run, 2026-11-11, a ReleaseSafe compiler of the prototype that passed the gate (`f5a4bea289`).

| | Programs | `SAME` | `REFUSED` | `TRAP` | `DIFF` | `CRASH` |
|---|---:|---:|---:|---:|---:|---:|
| the prototype of this round | 1 960 | 236 | 1 724 | **0** | **0** | **0** |
| v2, the same programs | 1 960 | 522 | 1 438 | 0 | 0 | 0 |
| report 111's prototype (`1692066993`), the same programs | 1 960 | 288 | 1 301 | **371** | 0 | 0 |

**The family found no fault of the prototype.** The third row is the control: it says that the family can
find faults of this kind. Report 111's prototype traps on 371 of the programs, in each of the 28 carriers
(from 4 programs of `dir`, `ident`, `rec`, `tup`, `wrap` and `wrap2` to 30 of `later`). By act: 285 hand a
captured list to a captured function that writes, 43 write the handed list, and 43 write and keep it.

**Precision.** The prototype accepts 180 of the 980 `dead` twins (18 %), and v2 468 (48 %). v2 accepts 321
`dead` twins that the prototype refuses, and the prototype 33 that v2 refuses. By carrier, the `dead` twins
that each accepts, of 35:

| Carrier | v2 | prototype | | Carrier | v2 | prototype |
|---|---:|---:|---|---|---:|---:|
| `dir` | 23 | 21 | | `ref` | 2 | 2 |
| `ident` | 23 | 21 | | `join` | 19 | 5 |
| `comp2a` | 19 | 2 | | `part` | 25 | 12 |
| `comp2b` | 15 | 2 | | `parttop` | 25 | 21 |
| `comp3` | 19 | 2 | | `ret` | 14 | 2 |
| `wrap` | 25 | 2 | | `retret` | 2 | 2 |
| `wrap2` | 25 | 2 | | `cbcb` | 2 | 2 |
| `deep` | 25 | 2 | | `viafold` | 0 | 14 |
| `first` | 21 | 2 | | `mutual` | 12 | 8 |
| `rec` | 23 | 11 | | `selfrec` | 12 | 14 |
| `recarg` | 25 | 2 | | `selfpass` | 3 | 8 |
| `tup` | 23 | 11 | | `later` | 12 | 2 |
| `lst`, `lst2` | 12, 12 | 2, 2 | | | | |
| `may`, `mayarg` | 25, 25 | 2, 2 | | | | |

The prototype is near v2 where the callback stays a known function (`dir`, `ident`, `parttop`), and ahead
of it where the rule composes contracts (`viafold`, `selfrec`, `selfpass`). It is far behind where the
callback goes through a default location: a function-typed result (`comp*`, `wrap*`, `ret`), or an item of a
value (`lst`, `may`, `ref`; and `rec` and `tup` for a callback that writes). Where the figure is 2, it accepts
only the programs in which the callback writes nothing and the caller does not write its answer. This is the
cost of §2.8, measured.

The causes of the 1 724 refusals: `supply` 692, `unknown` 519, `call` 364, `later-use` 131, `captured` 14,
`escaped` 4.

### 6.3 After the run: a search by hand

The family varies how a function travels. It does not vary the types: each list in it is a `List Int`, no
result in it has two parts, and no call in it has one list at two arguments. So after the run, 97 programs
were written by hand against the prototype, in five rounds. Each program comes from a question that the
family does not ask. **15 of the 97 trap. They are three faults.** v2 refuses each of the 15. Report 111's
prototype traps on 14 of them and refuses one.

| Round | Programs | Trap | The question of the round | Fault |
|---|---:|---:|---|---|
| 1 | 37 | 5 | what the family does not vary: a callback and a holder of two different types, an answer beside its argument, a method call, a callback that takes a callback, recursion that wraps the callback again, a callback over a tree or a `Dict`, a constructor as a function, a function in a cell | 1, 2, and 3 (an answer beside an argument) |
| 2 | 6 | 4 | a question of the review of this pull request: are two parts of one wide value always apart? | 3 (the arguments; a function that a handed function captured) |
| 3 | 7 | 3 | the same claim for one location that holds many cells | 3 (one location, two sources) |
| 4 | 13 | 3 | one function that is called two times | 3 (one location, one source) |
| 5 | 34 | 0 | the same claim through a captured value, a partial application, `List.append`, `List.concat`, a spread, a projection of an argument, a pattern in place of `List.update`, a list that a handed function captured, an argument that the callee reads before the function gets it, and a fold with one list in the list and in the accumulator | none |

**Fault 1: a function with a wider type than its holder.**

```beni
idp : a → a
run2 : (List (List Int) → List (List Int)), List (List Int) → List (List Int)
run2 f v = f v

inner = [ c ]
r = run2 idp [ inner ]
w = List.update r 0 λm → List.push m 9     -- accepted, and wrong: `inner` is read later
```

`idp` has one location: the type variable. The holder's type has two: the outer list and the inner lists.
The prototype mapped a location of the function to a location of the holder with the call map (report 111
§2.2), which goes from the wider type to the narrower one. Here the function's type is the wider one. So the
inner lists of the answer had no source, and a location with no source holds no cell.

**Fault 2: the same match, one level down.** The holder is over `a → a`, and the function is over `List b →
List b`. The function's variable `b` is a part of the holder's `a`. The prototype took the argument's cell
at that part, and not the cells below it, which `b` stands for too. A write of the innermost list of the
answer was accepted.

Both are one fault of the design as built: **the match between the function's reading of a type and the
holder's reading works in one direction.** It is not a way for a function to travel. Report 111's prototype
has it too. The fix makes the match work in both directions (`slotsOf`, `answersAt`, `partBelow`): a wide
location of one reading holds each cell of the other reading's locations at or below its place (§2.7).

**Fault 3: a contract's claim that two sources are two cells.**

A contract says which sources each location of a result has (report 111 §2.2). It says in two ways that two
sources are two cells: two locations of the result are apart (the bit `nonlinear` is false), and one location
that holds many cells (the elements of a list) holds each cell one time. The caller trusted both. The callee
can know that of one source that it puts at one place. For more than that, the claim rests on three things
that only the caller knows:

- what a function answers that the callee was handed;
- if the arguments are apart;
- what a function answers that a handed function captured.

The search found the fault in four forms, one round after the other:

```beni
withBoth f xs = ( f xs, xs )           -- round 1: an answer beside the argument
r = withBoth (λl → l) [ c ]            -- `r.0` and `r.1` are one list

keep2 p = ( p.0, p.1 )                 -- round 2: no function value
r = keep2 ( q, q )                     -- `r.0` and `r.1` are one list

pack p = [ p.0, p.1 ]                  -- round 3: one location, two sources
v = pack ( q, q )                      -- `q` is at two elements

each f x y = [ f x, f y ]              -- round 4: one location, one source
v = each (λl → l) q q                  -- `q` is at two elements
```

Each program then writes one of the two places in place and reads the other
(`w = List.update v 0 λm → List.push m 9`, and then each element of `w`). The prototype accepted the write.

- **Two of the forms have no function value.** `keep2 ( q, q )` and `pack ( q, q )` are faults of the
  first-order core, and report 111's prototype has them. Its two generators and the four sweeps have no call
  with one list at two places of the arguments.
- **One program is a fault that this round made.** `mkv build q = build q`, with `build = λq → ( q, g q )` and
  a captured `g` that answers its parameter. Report 111's prototype read the answer of a captured function as
  "no claim", and that refused the program. The rebuilt prototype reads that answer exactly, and it still
  trusted the bit of `build`'s contract. The search found it in round 2.
- **The fixes of rounds 1 and 2 were cases.** Round 1 added a check for an answer beside another part of
  the result. Round 2 added a check of the arguments. Each closed the form that its round found, and the next
  round found a form that it did not cover. That is the pattern that this round asks about (§1). It did not
  occur in `flow`. It occurred in the check of a contract's claims.
- **The fix of round 3 is one check** (`sourcesApart`, §2.7). It replaced the two cases. For each pair of
  sources of a result, the caller reads what the two are in its own frame. If they can be one cell, the claim
  does not hold: two locations are not apart, or the one location has no claim. Round 4 found the one form
  that a check of pairs cannot see: one answer source is each answer of each call of the function. The same
  check has it now: when the arguments are not apart, a location that holds many cells and has an answer has
  no claim. Round 5 found no fault.

**What the three faults have in common.** None is a new way for a function to travel. Each is at the border
between the rule and the first-order core: how a location of one type maps to a location of another, and
which first-order claim of a contract depends on a function or on an argument. The family of §6.1 could not
find them.

**Two sweeps for the three faults.** `bench/ownership-sweeps/wider-functions.mjs` makes 354 programs: a function
over a type variable (`a → a`, `List a → List a`, `x, a → a`), as a top-level function, a local and a
lambda, goes to a holder of a concrete type or of a type variable, over a list of lists, a list of lists of
lists, a pair, a record and a `Maybe`. The program writes the innermost list of the answer, with
`List.update` or through a pattern.

`bench/ownership-sweeps/answers-beside.mjs` makes 240 programs: 18 callees whose result has two sources (a
pair, a record or the elements of a list; an answer and an argument, two answers, or two parts of one
argument; one level down, through one more function, over a type variable, with a function that the handed
function captured) × what the function answers (its parameter, a new list, a captured list) × what the
caller does with the two parts. Four callees have no function. One callee is the safe form of round 4: two
lists that are apart.

| | `wider-functions.mjs` (354) | | | `answers-beside.mjs` (240) | | |
|---|---:|---:|---:|---:|---:|---:|
| | `SAME` | `REFUSED` | `TRAP` | `SAME` | `REFUSED` | `TRAP` |
| report 111's prototype (`1692066993`) | | | | 69 | 145 | **26** |
| the prototype that passed the first gate (`f5a4bea289`) | 159 | 157 | **38** | 69 | 144 | **27** |
| the final prototype | 171 | 183 | 0 | 61 | 179 | 0 |
| v2 | 129 | 225 | 0 | 103 | 137 | 0 |

The price of the fixes is in the second table: the final prototype accepts 61 of the programs of
`answers-beside.mjs`, and the prototype of the first gate 69 with the same output. The eight are safe
programs in which one list is at two elements and nothing is read after the write. The first-order core
has the same price for a list that is built in place with one cell two times.

**The gate and the family again.** The fixes changed the prototype after the one run of §6.2. So each run of
§5 and the family were repeated on the final code (`51a1bb0eff`). §5 has the figures of the final code.
Three of the four sweeps have the same verdict for each program as at the first gate, and
`recursive-levels.mjs` has 84 safe programs fewer with `SAME` (§5.1). The family has 240 `SAME` and 1 720 `REFUSED`, and no program has a `TRAP`,
a `DIFF` or a `CRASH`. The sanitiser corpus has one more accepted fixture (100). The real writes stay at 299. The first version of
the fix of round 1 cost one real write (`Tea.tableFoldl`, a fold over a nested accumulator): two parts of one
wide entry of a callee's result are parts of one value, and the check reads them so.

### 6.4 A blind sweep for the border

The two sweeps of §6.3 were written after the faults that they pin. So after the last fix, one more generator
was written for the claim of §2.7, and it ran one time on the final code. Before that run, 441 of its programs
were built with no checker, to show that the generator makes programs that build and run. No checker ran on
a program of it before the one run.

`bench/ownership-sweeps/aliased-arguments.mjs` makes 3 870 programs. A callee makes a result with two parts
from two inputs, and the caller hands it one list `q` as both inputs.

| Dimension | Values |
|---|---|
| How the list is at two places (9) | two arguments; two items of a tuple, of a record or of a list; a local tuple; a local list; a projection of a local; an element of a list and an argument; and the control, two lists that are apart |
| The callee's result (8) | a pair; a pair with the parts in the other order; a record; a `Maybe` and a list; a list; `List.append`; a spread; a list of lists |
| The function between an input and a part (10) | none; one function at the first input, or at both inputs, that answers its parameter, a new list, or `q`, which it captured; a function that captured `q` at the second input; two functions that answer their parameter, or `q` |
| What the caller does (6) | both parts into one list and a write of one element; a write of the first part and a read of the second; a write of the second and a read of the first; a write of the first and a read of `q`; a write and no read (the safe twin); a write of an element of the result itself (the three callees that answer a list) |

| | `SAME` | `REFUSED` | `TRAP` | `DIFF` | `CRASH` |
|---|---:|---:|---:|---:|---:|
| the final prototype, ReleaseFast (the one run) | 642 | 3 228 | 0 | 0 | 0 |
| the final prototype, ReleaseSafe | 642 | 3 228 | 0 | 0 | 0 |
| v2 | 1 080 | 2 790 | 0 | 0 | 0 |
| report 111's prototype (`1692066993`) | 734 | 2 990 | **146** | 0 | 0 |
| the prototype that passed the first gate (`f5a4bea289`) | 734 | 2 990 | **146** | 0 | 0 |

- **No fault in the one run.** The two earlier prototypes trap on the same 146 programs. Each of the 146 has
  no function, or functions that answer their parameter. Six of the nine alias forms have traps. The two forms
  with a list `[ q, q ]` have none: the first-order core has no claim on the elements of such a list. The
  control has none.
- **Precision.** Each of the 720 `dead` programs is safe. v2 accepts each one, and the prototype 290 (40 %).
  Where one list is at two places of the arguments, the prototype gives the result's location no claim. v2
  refuses the write only when a read follows. For a write of an element of the result itself, the prototype
  accepts 60 of the 270 programs, and v2 9.
- **What the sweep does not show.** Its dimensions come from the forms that the hand search found. It is
  blind for the checker and not for its author. A form that the author did not think of is not in it.

---

## 7. What the round does not show

- **Soundness is still tested, not shown.** The rule has one invariant (§2.6), and the list of the places
  where the walk can lose a function is finite and in one file. That list was checked by hand and by the
  tests of this report. No proof exists. The rule is small enough for the Lean model that report 110 §6.8
  names: one judgement `flow`, three uses, four kinds of value.
- **The cost of the default.** A function-typed location with no contract is `top`. The measured cost:
  - six of the nine real writes that the prototype does not accept (§5.4);
  - the safe programs of §6.2 where the callback goes through a function-typed result or an item of a value:
    v2 accepts 321 `dead` twins of the new family that the prototype refuses;
  - each closure that writes a captured value, also when it runs one time (`handed-back.mjs`: v2 accepts 476
    programs, the prototype none).
- **The border of the rule has one blind test.** The three faults of §6.3 were found by 97 programs that
  the questions of one worker and one reviewer gave. The third fault had four forms in four rounds. The
  evidence that no fifth form exists is one round by hand with no fault, and one blind sweep whose
  dimensions the same worker chose (§6.4). The two sweeps of §6.3 were written after the faults. The claim
  of §2.7 has a list of the pairs that need no check (the comment on `sourcesApart`), and each line of that
  list is an argument by hand. The match of two types (§2.7) has no blind test: `wider-functions.mjs` was
  written after its two faults. That match is correct in both directions now, and it is coarse in two places
  on purpose: a wide location takes each cell below its place, and it reads an answer below it as a whole.
  The exact form maps both readings to the type of the value at the place where it flows. That work did not
  start.
- **The first-order core had no test with one list at two places of a call's arguments.** Two forms of the
  third fault are first-order. Report 111's generators and the four sweeps did not find them.
  `aliased-arguments.mjs` is the first such test, and 32 of the 146 programs on which the earlier prototypes
  trap have no function. No random generator has that form yet.
- **The check of pairs is coarse for two locations of one argument.** It costs 84 safe programs of
  `recursive-levels.mjs` (§5.1).
- **No sweep has a function value with a recursive type, a record with a row, or a cell in the accumulator.**
  The family of §6.1 has flat lists. `wider-functions.mjs` has nested lists, a pair, a record and a `Maybe`.
  Five programs by hand have a callback over a tree, and six have a `Dict`, a row or a list of functions.
- **The entry, cells, fibers, records, blocks.** As in report 111 §6. No page ran under the prototype.

## 8. The next step

Each item is the owner's decision.

1. **A contract on a function-typed result** (§2.8). It is one more location with a contract, not a new rule:
   the callee's contract says "my result is this known function, and its captured values are these
   parameters", and the caller then has a known function, which flows as each other one does. It gives back
   the costs of §7's second item. The eight generators are the gate for it.
2. **Make the sweeps and the sanitiser corpus a gate of the flag**, as report 111 §7 item 2 says. One run of
   the eight generators takes about 25 minutes on seven cores with a ReleaseFast compiler.
3. **Vary the types in the sweeps, and run them blind.** `function-values.mjs` with the shapes of
   `folds-callbacks.mjs` (a list of lists, a record, a tuple, a `Maybe`, a constructor) and with a recursive
   type; one list at two places of the arguments in report 111's random generators. §6.3 is the reason. The
   match of two types has no blind test yet.
4. **The normative text** (rule 1 of `CLAUDE.md`). §2 of this report and report 111 §2.1 to §2.5 are its
   outline.
5. **A row on `Js.get`, on `Dict.focus` and on the platforms' `Send`** (report 111 §7 item 5; §5.4 here).
6. **A mutant for each `flow` to `top` of §2.6**, as `zig build test-own2-mutations` has for v2. Each is one
   line. A mutant that removes it must make a program of the sweeps trap.
7. **The exact check for two locations of one argument** (§5.1). In `sourcesApart`, a pair of two parameter
   sources of one argument needs the argument's own claim that its parts are apart (`argsApart`), not a
   comparison of cells. `partsOf` must then read each arm of a value that is one of several. It gives back
   the 84 safe programs of `recursive-levels.mjs`. The eight generators are the gate for it.

---

## Appendix A. Commands

All from the repository root. `TMPDIR` and `--tmp` must point to a directory on disk.

1. **The compilers.** `zig build test-perf "-Dtest-filter=generated module of §7.6"` installs the ReleaseFast
   compiler at `zig-out/perf/bin/beni`. `zig build test-blackbox-check` installs the ReleaseSafe compiler at
   `zig-out/safe/bin/beni` and runs the black-box tests of the prototype.
2. **The four sweeps, the new family and the three new sweeps (§5.1, §6).** For each generator `g` of
   `bench/ownership-sweeps/`:
   `node bench/ownership-sweeps/g.mjs out/g`, then
   `node bench/ownership-sweeps/run.mjs --beni=zig-out/safe/bin/beni --checker=v3 --jobs=6 --tmp=out/tmp out/g`.
   The same with `--checker=v2` gives v2's verdicts. `--tag=<name>` names the results file.
3. **Report 111's generators (§5.2).**
   `node bench/ownership-step0-generator.mjs --beni=zig-out/perf/bin/beni --count=2000 --seed=1 --jobs=4`, and
   the same with `--family=higher`. The long runs have `--count=20000 --seed=2001`.
4. **The sanitiser corpus (§5.3).**
   `node bench/ownership-step0-sanitiser.mjs --beni=zig-out/perf/bin/beni --jobs=4 --list`.
5. **Real writes and speed (§5.4).**
   `node bench/ownership-v2-review.mjs --checkers=v1,v2,v3 --roots=real --runs=5 --jobs=1`.
6. **One module.** `beni dump --stage=ownership --ownership=v3 --ownership-everywhere --platform=node M.beni`
   prints each verdict and each declaration's contract. A `summary` line has `fn` after a function parameter:
   `called`, `lost` (the parameter goes to `top`), `answer-escapes`, `rewrites`, and what each parameter of
   the function is handed (`held`: not `free`).
