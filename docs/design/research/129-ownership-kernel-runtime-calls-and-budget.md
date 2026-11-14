# 129 — The ownership kernel v3: the program's callers, derived, and one budget per declaration

*Research report, 2026-11-13. A fix of `src/own3/` for research report 128 (blind reader G), on pull
request #2451. The kernel is `ownership-v3-kernel.md`; this report changes its §5, §6.9, §6.11, §8 and §9
and adds §6.14. Nothing in `src/own/` or `src/own2/` and no platform runtime changed.*

---

## 1. Result

Report 128 found a function named in a schema's `via` that the compiled print worker calls with a value
that the program still holds. No walk read a schema declaration, so a write of that function's parameter
was accepted. It was the third time that the kernel's hand-written list of "calls that the runtime makes
into the program" proved incomplete.

This report replaces the hand-written list by a derived one, and fixes the rule as a whole:

- **The list is read off the backend.** Every edge and root of `js/Reach.zig` that reaches a declaration
  of the program, and every call that the lowerings emit that is not the lowering of a call in a body,
  is a row of a table in kernel §6.14, each with the rule that applies it (§2).
- **A fourth caller was found:** host JavaScript in a `--library` build. It calls each exported function
  with arrays that it still holds. v3 accepted a write of the parameter, and the host's array changed.
- **One rule covers both new rows.** A `via` conversion and an exported function are in the default
  location (kernel rule 8): each function in them goes to the `top` use, where one that writes its
  parameter is refused (§3).
- **A mechanical check** (`Check.checkCovered`, safe builds) fails when an instruction that names code,
  in a declaration whose code the backend emits, was not walked. With the schema walk turned off, the
  first program with a `via` panics (§4).
- **One step budget per declaration.** Every loop that no memo bounds counts against it: the rounds of
  a recursive group, the entry's fixed point, the pairs of writes with escapes and reads, and each
  expression evaluated. The entry's fixed point now reads each fact once and takes away along a
  worklist (§5).
- **The give-up audit** found one more accept: a method written as a constant (`pub eq = keeper`) read
  as code that only reads, to derived code and to evidence. It is fixed (§6).

## 2. The program's callers

The question was: where does code that is not the program's own walked body call a function of the
program, or take a value of the program that it can keep or call later? I did not answer it from the
kernel. I read where the backend emits and roots code:

- **Which declarations have code.** `Reach.zig` (its loop over declarations) and `Lower.zig`
  (`declaration`): a `value` (its body, once or twice: the second is the suspendable twin) and a `schema`
  (only its `via` expressions, lowered by `Lower.schemaViaExpr`). A `foreign` is its sibling's
  JavaScript, a markup primitive is the runtime's. The other kinds emit nothing.
- **Every edge and root of `Reach.zig` into a declaration of the program**: `declEdgesAt` (references in
  a body), `markupEdgesAt` and `privateExtractor` (the vocabulary), `memberEdges` and `codecEdges`
  (schemas and codecs), the dispatch table's edges (`Edges.zig`), `effectEdges` and `evidenceTwins`
  (suspendable code), and `collectRoots` (the entry; every export of a `--library` build).
- **Every call that a lowering emits that is not a call in a body**: `SchemaLower.zig` (the workers call
  the `via` functions: `compiledBackward` hands `back` the value it is printing, `compiledForward` hands
  `there` a value it made; a worker calls the workers of the schemas it names; a derived codec calls the
  type module's `codec` value by name), `Lower.markupComponentCall` and the `dom` lowering (components,
  rows, keys, helpers re-made at render), the `browser-inline` program hook (the record of `Tea.sandbox`
  is never built; its parts are inlined into the mount), and the entry file (`run(main)`).

The result is the table of kernel §6.14. Each row has one of two rules: **a call** (rule 2), where the walk
knows where the caller gets the arguments (the markup's rows and keys, rule 12; the entry's record, rule
13; the dispatch table, rule 11; a callee's contract); or **the default location** (rule 8), where it does
not: the function is handed values with no claim, so it may write none. Two rows had no rule:

| Caller | Before | After |
|---|---|---|
| a schema's compiled workers and `S.schema` call the `via` functions | no walk read a schema declaration: a `via` function that writes its parameter was accepted (report 128) | the `via` is walked, and is a value in the default location |
| host JavaScript calls the exports of a `--library` build | an exported function that writes its parameter was accepted on the ground `param` ("every caller checked"); the host's array changed | each exported function is in the default location |

The `--library` hole, on the commit before this one:

```beni
pub push3 : List Int → List Int
push3 l = List.push l 3
```

`beni build --library --ownership=v3 --ownership-everywhere --sanitize-lists` accepted it, and the emitted
`Main$push3` edited its argument in place: a host that ran `const a = [1, 2]; M.Main$push3(a)` found
`a.length` to be 3. It is refused now.

Rows I checked and found covered: a component (the module's `view`) is a value at an item of markup,
so it goes to `top` and one that writes its props is refused (probe in §7); an event's `via` extractor is
a vocabulary declaration of the platform; `listEq` and `listCompare` call the element's comparator, which
is evidence (rule 11); a declared `codec` is a walked declaration whose functions pass through
`Schema.conversion`, which loses them; `main`'s value goes to the platform function it is handed to. Three
rows rest on trust in a lowering, not on a rule of the checker: the `browser-inline` program hook, the
suspendable twins and the helpers re-made at render keep the program's calls and their order
(`language.md` §6). The kernel says so in the table.

## 3. The rule

**A schema's `via`.** The workers hold the conversion for as long as the program runs and call its
functions at any time: a print or encode worker with a part of the value it was handed, a parse or decode
worker with a value it made. So the conversion is a value in the default location. `Check.walkSchema`
walks each `via` expression of a schema declaration in a frame of its own (`Frame.walkHeld`): the
expression is evaluated as a value, so each function in it goes to the `top` use (`mention`), and its
cells escape. A function at `top` that writes its parameter is refused there (`writesOwn`). The other half
was already true: a call of a worker (`Box.print v`) is a call of code with no contract, so `v` escapes at
the call. So a `via` function writes nothing it is handed, and what it keeps had escaped already. This holds
from every caller of a worker: another schema's worker, a derived codec, `core/Schema`'s runners through
`S.schema`. It is the rule that a conversion that is a top-level value (`via conv`) already met; the
inline form now meets it too.

**A `--library` build.** The session knows the build is a library (`Session.Options.library`, set by
`beni build --library`). `Check.walkExports` sends each exported function to the `top` use
(`Frame.walkExported`): the `pub` values of the root package's modules and the entry declaration, as
`Reach.collectRoots` roots them. A constant that holds a function sent it to `top` where it was made; a
derived row reads, and the methods it calls are `pub`.

## 4. The mechanical check

`Check.checkCovered` runs at the end of each module in safe builds. For each declaration whose code the
backend emits, it asks: was every instruction that names or runs code evaluated by a walk, or accounted
for by a rule? If not, the compiler panics and names the instruction and the declaration.

- "Names or runs code" is `namesCode`, a `switch` over every instruction tag with no `else`: references
  to values, lambdas, calls of every kind and markup are in; constructors, literals, constructions,
  projections, bindings, types, patterns and schema plans are out.
- "Whose code the backend emits" is a `switch` over every kind of declaration with no `else`: a `value`'s
  body; a `schema`'s instructions (its `via`s); a `foreign` and a markup primitive are JavaScript, rules
  10 and 12.
- A walk marks each instruction it evaluates (`evalInner`), each callee it resolves by name (`call`),
  each code it walks in a frame of its own (`solveCodes`), and the calls of a spread or `++` chain, which
  the construction rule accounts for (`noteChain`, `appendChain`).
- A declaration whose walk gave up or passed its budget is not checked: it publishes nothing and its module
  authorises no write.

**It finds report 128's fault on its own.** With `walkSchema` turned off, `schema-via.live` stops at once:
"instruction 22 (ext_value) of Box names code that no walk evaluated". So a new kind of declaration with
code, a new kind of instruction, or a part of a declaration that the walk skips fails the gates on the first
program that has one.

**What it cannot catch.** A call with no instruction behind it: a name that the compiler makes up (a
derived row, a dispatch edge, the entry's protocol, one schema's worker calling another's, the exports of a
`--library` build, a codec found by the name `codec`). The `--library` hole is of this kind: the check
did not find it, the read of `Reach.collectRoots` did. It cannot catch a contract of `core/`, a platform
or a `foreign` that is wrong either, or a lowering that changes which calls run. These are the rows of the
table in kernel §6.14 that a person must keep.

## 5. The budget

Report 128 §5 found two loops outside the step limit: the rounds of a recursive group (each walk had a
new count) and the entry's fixed point (no step counted). Kernel §8 said "per declaration"; the code
bounded each walk.

- **One budget for each declaration** (`Mod.decl_steps`, 2²⁵ = 33 554 432 units): a walk starts its
  count where the declaration's last walk stopped. The rounds of a recursive group count together; a
  member past the budget stops the rounds, and no member publishes a contract. After one declaration
  passes it, no other declaration of the module is walked (the module authorises no write anyway).
- **Every loop that no memo bounds is counted.** A call is 32 units: each expression the walk evaluates,
  the calls of the walks of values and functions (as before), each pair of a write and an escape and of
  a write and a later read, and in the entry each pair of locations that meet and each step of the
  taking away. An element visited inside a call is 1 unit: each atom compared in a test of two runs of
  atoms, each pair of entries `deriveLinear` tests, each part a walk of values, a projection or a record
  update visits, each atom sorted or copied, each entry of a call map read (`Frame.charge`; added after
  the review, §10). Past the budget the walk goes no deeper, the rounds of local functions stop, every
  test of atoms answers on the pessimistic side, every line is refused, and the entry takes every model
  location out of `own`.
- **The entry's fixed point is linear in what it reads.** It started from `own` everywhere and took one
  location away per round, and each round compared every model location with every entry of the answer
  and every parameter location (`locsMeet`): n⁴ for n list fields. It now reads each producer's facts
  once — a location with a source that has another holder is `bad`, and one that comes from a location of
  the model parameter needs that location (`deps`) — and takes away along a worklist. The pairs that meet
  come from an index of the two call maps (`Frame.meetsOf`, `MeetIndex`), so a lookup costs the size of
  its answer, not the size of the layout. Safe builds check the index against `locsMeet` for every pair
  of layouts of at most 64 entries.

| Program | Before | After |
|---|---|---|
| `entry-shift-slow.dead` (800 fields) | SAME, 19.2 s | SAME, 0.16 s |
| `entry-shift-control.dead` | SAME, 0.21 s | SAME, 0.15 s |
| `group-rounds-slow.dead` | SAME, 6.7 s | **LIMIT**, 0.11 s |
| `group-rounds-control.dead` | SAME, 0.16 s | SAME, 0.08 s |

*ReleaseSafe LLVM compilers, `beni check`, one run each.* `group-rounds-slow.dead` is safe, and is now
refused with the loud limit: its group needs about 60 rounds (report 128 §5.2), and together they pass
the budget. That is the budget doing what §8 says.

## 6. The give-up audit

Every place in `src/own3/` where the checker gives up, reaches a limit, falls to `top`, the default,
`outside`, `unknown` or `Loc.all`, misses a lookup, or meets something it has no fact for. A fresh
reader did the first pass, with the code and the kernel; I checked each verdict that it gave and each
that it doubted. **One accepted: a method written as a constant.** It is fixed.

**The accept.** `Mod.edgeEffect` reads what a method that derived code calls can do off the method's
contract. A method written as a constant, `pub eq = keeper`, has the contract of a constant: arity 0, no
flag, so it read as "reads only". A derived `eq` of a tuple that holds the type calls it with its operands,
`keeper` keeps one of them in a `Ref`, and the operand was then written in place
(`constant-method.live`: accepted, and the sanitised build trapped). A direct `x == y` was safe:
`methodCall` checks the arity. The fix: a contract of arity 0, or no contract, is no fact, unless the
declaration's own type says that it is no function (kernel §6.11). The same read fed `where` evidence
and the derived facts that a module publishes, and both are fixed with it.

| Where | What it does | Verdict |
|---|---|---|
| `Check.edgeEffect`, a constant method or a method with no contract | was "reads only" | **accepted; fixed** |
| `Check.edgeEffect`, another module's method with no published fact; `.ext_derived` with no fact | writes, keeps, no contract | refuses |
| `Check.edgeEffect`, `.derived` | the row's own body is walked with the edges | safe |
| `Check.edgeEffect`, `.primitive`, `.undetermined`, `.codec` | `===`, number and string comparisons; a derived codec is a function of `⊤` (kernel §6.11) | safe |
| `Mod.placeOf` and `ctorStep` on an error of the place graph | one wide location for the type; a projection misses and is `unknown`; a constructor past 65 536 arguments shares a step | safe, but silent: no limit line (a prototype constant, R-7.4) |
| `Loc.stepLabel` (an argument past 4 096, an ordinal past 32 767) | two locations share a label | not reachable by a program the parser takes in practice; silent |
| `Mod.isView` deeper than 4, `isMarkup` false | not a view: its answer is kept | refuses |
| `Mod.aliasIsSender` deeper than 8 | not a sender: a message sent through it is no demand | safe: what it is handed escapes, and the message is never `own` (rule 13) |
| `Mod.calleeOf`, an alias chain past 16 | the call reads a constant's contract of arity 0: a partial application, every argument escapes | refuses |
| `Mod.entryShape` null, `EntryField.unknown`, a field with no known code, a field the type does not name, a record not written at the call | no location is `own`; the function goes to `top` | refuses |
| `walkDecl` past the budget or given up | a limit line; no contract | publishes nothing |
| `solveGroup` past 64 rounds, or a member past the budget | a limit line; no member publishes a contract | publishes nothing |
| the worded declarations' loop resets `failed_decl` | the contract is the words; a limit line of the walk stays | the module authorises no write |
| `walkSchema`, `walkExports` past the budget or given up | a limit line | the module authorises no write |
| `Frame.tick` in each walk (an early return drops atoms) | the declaration is past its budget: a limit line, every demand refused (`finishDemands`) | refuses |
| `reach` on a tick | answers "reaches" | refuses |
| the new ticks in `demand` and `finishDemands`; `eval` | `refused = .limit`; the walk goes no deeper | refuses |
| `meetsOf` past the budget | every model location out of `own`; every write the entry judges refused | refuses |
| `MeetIndex` | the inverse image, the decided image, or the undecided entries: what `locsMeet` says, pair for pair (checked in safe builds) | safe |
| `entryCall`'s fixed point | the greatest fixed point, as before; a write needs `!failed` and the budget | refuses where it should |
| `ctorValue` with no row | `outside`: a function that captured nothing; a use of it is `flowUnknown` | safe |
| a top-level constant with no contract or with arity ≠ 0 | `outside` | safe: the position rule |
| a name with no declaration | `unknown` over nothing | safe |
| `project` that misses | `unknown`; a construction names every part that holds a cell | safe |
| `leavesOwnWalk` with no root entry | `outside_atom` | refuses a write |
| `unknownOf` of values that hold nothing | `outside` | safe |
| `giveUp`, a local read before its binding, a flow that meets itself, a frame past 200, local functions past 16 rounds | `failed`: every demand refused, no contract | publishes nothing |
| a schema member | `outside`: unknown code, each argument escapes | safe (kernel §6.14) |
| `evidenceAt` with no site | no evidence | safe |
| `methodCall` of an evidence parameter | reads (rule 11: the caller judged the evidence) | safe |
| `otherReaches`: none, `outside`, a function, no flag | no other operand | safe by the contract |
| `otherReaches`: a location of the written operand that the map answers `Loc.all`, skipped | it is in the written set: `argEntries` adds every `all` entry to W, so it is the written part, and every other place is tested against W | safe |
| `slotsOf`, `fe == all` | false unless nothing meets: the caller falls to every supply | safe |
| `resolve` deeper than 12, `answerOfCode` deeper than 8, an answer of a parameter that misses | a lost answer: every argument in sight escapes, or the supply is refused | refuses |
| `partsOf` deeper than 8 | not apart: `twice` | refuses |
| `fns[j] orelse continue` in `apply` | the argument was evaluated as a value: it went to `top` | safe |
| `flowUnknown` at `top` | the default asks nothing (rule 8) | safe |
| `mention` of a `join`, `built` or `unknown` | each part went to `top` where the value was made | safe |
| `formCalls` with no list; `keptOf` with no value or no dispatch row | an invalid form; a missing row is "kept" | refuses or safe |
| markup: a `join` or `ref` at a hole is read, not escaped | the markup holds it until it is rendered (rule 12) | safe |
| `Contract.join` and `joinFn` on two layouts | not reachable: a signature's layouts are fixed across rounds | safe |
| `Contract.Reader` misses | no contract: unknown code | refuses |
| `Loc.cover` answers `all` | every reader above reads `all` on the pessimistic side | safe |

The audit also found §8's "more than 24 answers" and "more than 32 supplies" stale: neither limit is in
the code. The kernel lists the limits that are.

## 7. Tests

Black-box, `tests/blackbox/check_test.zig`, two new tests. Each fails on the commit before this one,
run there with the test file copied in:

| Program | Before | After |
|---|---|---|
| `blind8g-faults/schema-via.live` | accepted | refused at the `via` |
| `blind8g-faults/schema-via.dead` | accepted | refused (precision, §9) |
| `blind8g-faults/schema-via-tea.live` | accepted | refused |
| `blind8g-faults/schema-via-tea.dead` | accepted | accepted |
| `blind8g-faults/entry-shift-slow.dead` | did not end in 10 s | accepted |
| `blind8g-faults/entry-shift-control.dead` | accepted | accepted |
| `blind8g-faults/group-rounds-slow.dead` | did not end in 10 s | the loud limit |
| `blind8g-faults/group-rounds-control.dead` | accepted | accepted |
| `runtime-calls-faults/via-module.live` (`Util.back`) | accepted | refused |
| `runtime-calls-faults/via-partial.live` (`back 3 _`) | accepted | refused |
| `runtime-calls-faults/via-lambda.live` | accepted (no line) | refused |
| `runtime-calls-faults/via-nested.live` (a schema that names one with a `via`) | accepted | refused |
| `runtime-calls-faults/via-copy.dead` | accepted | accepted |
| `runtime-calls-faults/constant-method.live` | accepted | refused |
| `runtime-calls-faults/constant-method.dead` | accepted | accepted |
| `runtime-calls-faults/locals-after-limit.dead` (the review, 200 local functions) | the limit, 1.4 s | the limit, 0.46 s |
| a `--library` export that writes its parameter (inline) | accepted | refused |
| the same export writing a copy | accepted | accepted |

The tests run on the self-hosted ReleaseSafe compiler of the gates, which is slower than an LLVM build,
and each case has a 10 s guard. There, on a machine busy with a sweep, `entry-shift-slow.dead` took
1.1 s, as long as its control (most of it is checking `core/` from source), and `group-rounds-slow.dead`
1.7 s. On the LLVM ReleaseSafe compiler they take 0.16 s and 0.28 s (§5).

Corpus: `tests/corpus/run/SchemaViaWrites` with `.sanitize-lists-v3-refuses`. On the commit before, the
sanitised build traps ("a stale read of a list (read length), which `List.push` … changed in place");
after, the build refuses the `via` at 17:27, the refusal the file names.

A probe, not kept as a test: a component (another module's `view`) that writes its props is refused,
"value Row.view is refused: call: a function that writes its parameter goes where the checker does not
follow it". It needs no change.

## 8. Gates

ReleaseSafe LLVM compilers of `5d299c1dd3` (before) and of this work (after), on the same programs.

**Sweeps** (`run.mjs --checker=v3`, every generator and every fault folder; `blind7f` at its default
of 960 programs). **0 TRAP, DIFF or CRASH after, and no timeout.** SAME before → after:

| Folder | Programs | SAME | REFUSED | TRAP | Other |
|---|---:|---|---|---|---|
| blind-faults | 24 | 11 → 11 | 13 → 13 | 0 → 0 | |
| blind2-faults | 20 | 7 → 7 | 13 → 13 | 0 → 0 | |
| blind3-faults | 10 | 3 → 3 | 7 → 7 | 0 → 0 | |
| blind4a-faults | 12 | 1 → 1 | 11 → 11 | 0 → 0 | |
| blind4b-faults | 8 | 4 → 4 | 4 → 4 | 0 → 0 | |
| blind5c-faults | 10 | 5 → 5 | 5 → 5 | 0 → 0 | |
| blind5d-faults | 10 | 5 → 5 | 5 → 5 | 0 → 0 | |
| blind6e-faults | 12 | 4 → 4 | 8 → 8 | 0 → 0 | |
| blind7f-faults | 2 | 0 → 0 | 1 → 1 | 0 → 0 | 1 BOTHFAIL |
| **blind8g-faults** | 8 | 6 → 4 | 0 → 4 | **2 → 0** | |
| bounded-walk-faults | 12 | 2 → 2 | 9 → 9 | 0 → 0 | 1 BOTHFAIL |
| **runtime-calls-faults** | 7 | 3 → 2 | 0 → 5 | **4 → 0** | |
| aliased-arguments | 5 160 | 1 183 → 1 183 | 3 977 → 3 977 | 0 → 0 | |
| answers-beside | 240 | 77 → 77 | 163 → 163 | 0 → 0 | |
| blind | 9 792 | 1 675 → 1 675 | 8 117 → 8 117 | 0 → 0 | |
| blind2 | 1 202 | 502 → 502 | 700 → 700 | 0 → 0 | |
| blind3 | 417 | 160 → 160 | 257 → 257 | 0 → 0 | |
| blind4a | 160 | 24 → 24 | 136 → 136 | 0 → 0 | |
| blind4b | 6 596 | 1 229 → 1 229 | 5 367 → 5 367 | 0 → 0 | |
| blind5c | 226 | 81 → 81 | 145 → 145 | 0 → 0 | |
| blind5d | 1 234 | 456 → 456 | 778 → 778 | 0 → 0 | |
| blind6e | 238 | 90 → 90 | 141 → 141 | 0 → 0 | 7 PLAINFAIL |
| blind7f | 960 | 404 → 404 | 556 → 556 | 0 → 0 | |
| **blind8g** | 121 | 58 → 21 | 45 → 100 | **18 → 0** | |
| bounded-walk | 34 | 5 → 5 | 23 → 23 | 0 → 0 | 6 BOTHFAIL |
| callbacks-keep | 720 | 108 → 108 | 612 → 612 | 0 → 0 | |
| evaluation-order | 440 | 276 → 276 | 164 → 164 | 0 → 0 | |
| folds-callbacks | 30 300 | 5 392 → 5 392 | 24 908 → 24 908 | 0 → 0 | |
| function-values | 1 960 | 304 → 304 | 1 656 → 1 656 | 0 → 0 | |
| handed-back | 2 592 | 0 → 0 | 2 592 → 2 592 | 0 → 0 | |
| recursive-levels | 16 131 | 4 140 → 4 140 | 11 991 → 11 991 | 0 → 0 | |
| wider-functions | 354 | 144 → 144 | 210 → 210 | 0 → 0 | |

SAME is the same in every folder but three. Every program that moved is in `blind8g`'s `schema` family
(55, and one of its `slow` family), the two fault folders of the schema fault (the via programs, `constant-method.live`), and
`group-rounds-slow.dead` and `blind8g`'s `slow.group-rounds.r30.dead` (SAME → the loud limit). No program
moved from REFUSED to SAME. The BOTHFAIL and
PLAINFAIL rows are the same before and after.

- **The sanitiser corpus** (`bench/ownership-step0-sanitiser.mjs`, 347 fixtures): 93 same, 254 refused,
  0 traps, differences or crashes, before and after.
- **Real writes** (`bench/ownership-v2-review.mjs --checkers=v1,v3 --roots=real`): of the 308 writes v1
  judges, v3 accepts 287, refuses 20 and has no line for 1, before and after; the lists are equal line
  for line. **No write is lost or won.**
- **Units.** The largest declaration of all 2 311 ownership roots does 5.2 million units (`chunks` of
  `tests/corpus/run/TailModConsBranches`), and the largest of a real root 3.6 million (`viewSidebar` of
  `bench/corpus`'s `NotesApp`). No root reaches the budget of 33.5 million, about 6 and 9 times them.
  Counted as before this work (calls only), the largest was 49 480 (`changeRouteTo` of
  `examples/conduit`).
- **Speed** (ReleaseFast LLVM compilers of each tree, `ownership-v2-review.mjs --checkers=v1,v2,v3
  --runs=3 --jobs=1`, one after the other): v3 on v2's modules (169 846 lines) **565k lines/s before,
  553k after** (300.5 → 306.9 ms), 2 %.
- **`zig build gates`:** green on the final commit.

## 9. Precision

- **Lost, by the default rule for `via`:** a print whose value nothing reads after, a `via` function that
  writes in the parse direction (whose value is new), and a `via` lambda that writes (it had no line at
  all before, so it was never in place). In `blind8g`'s `schema` family that is 37 programs that printed
  the same and are refused now. Winning them back needs the workers applied as calls, with the path from
  the worker's argument to what each `via` function is handed; the kernel does not have that fact.
- **Lost, loudly:** a recursive group whose rounds together pass the budget (`group-rounds-slow.dead`,
  `blind8g`'s `slow.group-rounds.r30.dead`), and the declarations of a module after one that passed it.
- **Lost, by the constant-method rule:** a method written as a constant (`pub eq = keeper`) is code with
  no contract to derived code and to evidence. Written as a function, it is judged by its contract.
- **Won:** none. `entry-shift-slow.dead` is accepted as before, in 0.16 s and not 19 s.

## 10. The review

One fresh reader had the code and the kernel, and was asked for a call into the program with no rule, a
give-up that accepts, or a check that does not end fast.

- **Not found: a call with no rule.** Fifteen probes: `--library` exports in seven shapes (a constant
  that names a writer, a record of one, a lambda, an export that answers one, an opaque type that holds
  one, a constant made by a call, a partial application); a `via conv` and a schema built in a body and
  run with `Schema.encode`; constant methods called directly and by a dot-call; a write in one hole of
  markup that an earlier hole reads, on `browser-tea` and `browser-inline`. Each was refused where it
  should be. The reader also read `Reach.zig`'s edges against §6.14's table.
- **Not found: a give-up that accepts.** Every limit and give-up in an application module fails the
  build, and the other modules authorise no write.
- **Found: checks that do not end fast.** The step limit counted steps, and a step's own cost grew with
  the layout: a declaration over a record of 2 040 lists took 6.3 s under the limit and was accepted;
  three of them took 17.9 s; 30 declarations over nested pairs of 2 048 lists took 9.6 s. The commit
  before this work took the same time, so it is not new, but it is what §8 claimed not to be. **Fixed:**
  the budget counts units of work: a call is 32, and every loop inside a call counts the elements it
  visits (§8). Four loops now cost their answer and not their layout: a record update reads its base's
  parts, `argEntries` reads an index of the call map (`CoverIndex`), `deriveLinear` pairs only entries
  that hold an atom, and with the callee's claim only pairs with an answer of a function parameter.
- **Found: a wrong claim.** §8 said the index of meets was kept "so no round repeats it"; it is kept for
  a frame, and each round makes a frame. The text says so now.
- **The mechanical check:** "sound as described"; its blind spot is the one it names.

**The second pass**, on the diff of those fixes:

- **Not found:** an early answer past the budget that is optimistic. Every caller of a test that charges
  reads `true` on the pessimistic side, and every such answer has set the declaration past its budget,
  which ends in a limit line. The rewritten loops give the results they gave before (a record update's
  fast path copies at most more parts, the conservative side).
- **Found: work after the budget.** The rounds of local functions still built, joined and compared
  contracts of the layout's size for each local function after the budget was spent: 800 local
  functions over a record of 2 040 lists took 6 s past the limit. **Fixed:** `solveCodes` stops at the
  budget, and a module walks no other declaration after one passes it (`locals-after-limit.dead`, a
  test). The budget's reset now comes before a declaration's frame is made.
- **Open, by design:** the budget is per declaration, so declarations that each stay under it add up.
  Ten declarations of 300 lines over a record of 2 040 lists are accepted in 7.8 s, against 1.2 s for the
  plain check. A budget per module would bound it; this work did not add one (§12).

**The third pass**, on the commit of those fixes (`ca717d194c`): no finding. The reader traced a module
past its budget, a module of `core/` or a platform (where a limit is no error), a worded declaration, a
recursive group cut by the stop, and the values that `solveCodes` hands back past the budget; each ends
in a limit line, no contract, or both. Past the limit, 800 called local functions now take 2.9 s against
3.8 s for the plain check (9.8 s before).

The final figures, ReleaseSafe LLVM compiler, on a quiet machine:

| Program | Check | Plain check | Verdict |
|---|---:|---:|---|
| 2 040-field record, one declaration (review) | 1.39 s | 0.35 s | limit |
| the same, three declarations | 2.07 s | 1.01 s | limit (the first; the rest not walked) |
| nested pairs of 2 048 lists, 30 declarations | 1.21 s | 0.03 s | accepted |
| 800 local functions (review) | 1.87 s | 1.68 s | limit |
| 10 declarations each under the budget (review) | 7.81 s | 1.23 s | accepted |
| `climb.live` | 0.10 s | 0.01 s | limit |
| `locals-after-limit.dead` | 0.46 s | 0.26 s | limit |

## 11. How to reproduce

```sh
# compilers: the commit before, and this work
(cd base && zig build -Doptimize=ReleaseSafe --prefix ../before)
(cd wt && zig build -Doptimize=ReleaseSafe --prefix ../after)
# programs: each generator into sweeps/gen/<name>; each fault folder gets a LIST of its program directories
node bench/ownership-sweeps/<generator>.mjs sweeps/gen/<generator>
node bench/ownership-sweeps/run.mjs --beni=<compiler> --checker=v3 --tag=<old|new> --jobs=24 --tmp=tmp <folder>
# the sanitiser corpus and the real writes
node bench/ownership-step0-sanitiser.mjs --beni=<compiler> --jobs=14
node bench/ownership-v2-review.mjs --beni=<compiler> --checkers=v1,v3 --roots=real --runs=1 --jobs=8
# speed: a ReleaseFast LLVM compiler of each tree
zig build test-perf "-Dtest-filter=generated module of §7.6"
node bench/ownership-v2-review.mjs --beni=zig-out/perf/bin/beni --checkers=v1,v2,v3 --roots=real --runs=3 --jobs=1
# the tests before the fix: the test file, the fault folder and the fixture copied into base
(cd base && zig build test-blackbox-check "-Dtest-filter=ownership v3: ")
(cd base && zig build test-blackbox -Dcorpus=SchemaViaWrites)
```

The steps of §8 were counted by a compiler with a print of each declaration's steps after each walk,
built for the measurement and not kept, over every root of `bench/ownership-roots.mjs`.

## 12. Open

- **A budget per module.** The per-declaration budget bounds one declaration to about a second at worst
  on the shapes measured, and a module to its number of declarations times that.
- **Precision of the `via` rule** (§9): the workers applied as calls would win back the prints whose
  value nothing reads after.

