# 111 — Ownership step 0: the prototype of report 110, measured

*Research report, 2026-11-11. The owner asked for it on pull request #2451. It is not normative. It gives the
measurements of the step 0 prototype of [report 110](110-ownership-v2-design-review.md) (§6, §7), and one
verdict. The prototype is `src/own3/`, behind the hidden flag `--ownership=v3`. It does not change v1 or v2.*

---

## 0. Verdict

**Go, with changes.** On the 32 real roots the step 0 prototype accepts 299 of the 308 list writes that v1
judges, with no refusal at another position, and it runs at 1 049 000 lines per second on the modules that v2
walks (v2: 119 000; v1: 147 000). So the speed gate of 500 000 holds, and the gate of 300 accepted writes is
missed by one write: the nine losses have four causes, and each is a part that report 110 put in a later step
(§4.4). The gate "no trap" holds at the end and did not hold at the first measurement: the first full run of
the sanitiser corpus found 19 programs that the prototype accepted and must refuse, and a probe and the
generator found three more faults. Each is fixed, and the final runs have no trap and no different output on
345 fixtures and 44 000 generated programs (§4.2). 16 of the 19 were in the contract of a function
parameter, where report 110's rule "a forgotten case gives `shared`, which refuses" does not hold: a missing
fact about a function gives an accepted write (§3.9). So the changes are these. The first-order core of
report 110 (locations, `own` and `shared`, one write rule) carries real code at about nine times v2's speed
on the same modules, and it is the next path. The contract of function values is not a small part of it: it has most of the rules (§2.6),
it had 16 of the 19 faults that the corpus found, and with its coarse rules the prototype refuses 68 of the
163 sanitiser fixtures that v2 accepts (§4.4). It needs a normative text, and the sanitiser corpus as a gate, before more
code (§7). And step 0's gate cannot be met with step 0's scope: `List.foldl` is ordinary beni code, and 23 of
the 308 writes are at a program's entry or at a send (§3.4).

---

## 1. What the prototype is

| | |
|---|---|
| Code | `src/own3/`: 5 files, 5 156 lines. `src/own2/` has 170 files and 38 021 lines |
| Flag | `--ownership=v3` on `check`, `build` and `dump --stage=ownership`; hidden and test-only, as `--ownership=v2` |
| Domain | lists only; a record update is a copy; a cell's contents are `shared` |
| Run | the Driver's hook, one module at a time, in the module DAG; the lowering channel of `--sanitize-lists` |
| Not built | blocks in the interface, the cache and the checked core; so a run under the flag checks `core/` from source |

**What it takes from v2 by import, unchanged.**

- The place graph: `own2/Place.zig` and the adapter of `own2/Groups.zig` (types to places, cycles, families).
- The pre-pass: `own2/Prepass.zig` (groups of declarations in dependency order, alias chains, `eq`/`compare`).
- The report: `own2/Facts.zig`, `own2/Report.zig` and the names of `own2/Message.zig`. The dump has v2's grammar.
- The lowering channel: `own2/Hoists.zig`. The list sanitiser reads the prototype's verdicts with no change.
- The ownership words of `core/` and the platforms (`Bir.ownSlotsV2`).

**What it does not take.** The walk, the values, liveness, regions and holders of v2 are written over slots
(paths) and accounts. The prototype has its own walk (`own3/Frame.zig`). §3.3 says why.

| File | Lines | What it holds |
|---|---:|---|
| `Loc.zig` | 621 | locations, layouts, the call map, paths |
| `Contract.zig` | 319 | contracts, their join, the form that another module reads |
| `Frame.zig` | 3 073 | one walk of one code: values, reads, the write rule, calls, function parameters, the entry |
| `Check.zig` | 921 | one module: groups, worded rows, the lines' text |
| `Enforce.zig` | 222 | the session: the Driver's hook, the channel, the dump |

---

## 2. The design as built

This section states the rules that the code has. A normative text can start from it.

### 2.1 Locations

A location names the cells of a value by its type. It is a path of labels through the place graph.

- Outside a cycle of the type, a location is the path of steps to a place. Two fields of one record are two
  locations.
- Inside a cycle, the **entry level** is each place that a path reaches before it comes back to a place that it
  left. These places have their own locations, as outside a cycle.
- Everything past the first return is the **deep level**. It has one location for each object place of the
  cycle, and one for each step out of the cycle, whatever the depth and the route.
- A type variable, a function, a foreign value and a cell are one location each. Nothing is below them.

So `type Tree = Leaf | Node (List Int) Tree Tree` has two locations: the list of the root node, and the lists
of all deeper nodes. This is the option of report 110 §6.2. It was necessary (§3.2).

A **layout** is the list of the locations of one type. A type with an empty layout holds no object. Most
values of a program are of such a type, and the walk does no work for them.

A label holds no id of a module: a field's text rank, a constructor's ordinal, a type's `TypeId`. So a
location means the same in the callee's module and in the caller's.

### 2.2 The call map

`Loc.cover` maps each location of a caller's type to the location of the callee's signature that covers it:

1. the same label path; or
2. a wide location above it (a type variable, a row); or
3. for the deep level of a cycle that the signature does not have, the one wide location inside that cycle's
   entry level; or
4. `all`: each location of the signature covers it.

Rule 4 is the default. It is sound: the caller reads the callee's flags of every location.

### 2.3 Values, roots and atoms

The walk gives each expression a value: `none` (no object), `shared`, a part of a root, a made tuple, record
or constructor application, one of several branch values, a known function, or "every cell of these values".

A **root** is a parameter, a captured local, a value that the frame made (a list literal, a call's result), or
the answer of a function parameter. An **atom** is `(root, path, location)`: the cells of one location of a
root, at or below a path of concrete steps. Two atoms can be one cell only when they have one root and one
location, and one path is a prefix of the other. This is "levels stay apart where the text of one frame names
them" (report 110 §6.2).

A location of a made root is one of:

| Kind | Meaning |
|---|---|
| `own` | cells that the frame made |
| `shared` | no claim; the sources stay, so a holder check still sees what the location can hold |
| `derived` | cells of other roots, in an order of its own (a call's result that holds its arguments) |
| `version` | the new name of cells that a callee wrote, or handed to a function that could write them, and answers; the old names stay in the location, each with the instruction of that call |
| `taken` | an element that a trusted loop of `core/` took out of its list |

### 2.4 The write rule

A write of a set of target atoms is accepted when all of these are true:

1. no target is `shared`, a capture, or the answer of a function parameter;
2. no value that escaped before the write reaches a target;
3. no other operand that the operation reads reaches a target;
4. no read after the write reaches a target.

Rule 3 has one more case. Where a function writes a part of what a type variable stands for
(`List.update rows 0 grow` writes the field `kids` of an element), each other part below the same location of
the written operand is another operand.

**A write makes a new name.** Where a callee writes a location and answers it, the result's location is a new
atom. Each reference made before the write names the old cells. So rule 4 is one test, and no rule needs the
point where a local was bound. A later write of the new name is a write of the old names too.

**An old name has the point of its write.** The value that holds the new name is no reader of the old value:
the write that made the name, and each write before it, do not count that value as a holder. Each later write
does, because the cells are the same. The first version had a mark with no point, and it was wrong (§3.10).

**A prepend can answer an array that exists.** `List.cons` answers the array that `xs` is a view of when the
item in front is the element stored before the view. So the storage of `[ x, …xs ]` has the storage of `xs`
as a source, unless the item's own instruction made the item: a record, tuple or list literal, a record
update, a call whose contract says that each answer is one of these (`old_result` is false), or a call that
answers a list with the one source `fresh`. This is rule 2 of `ownership-v2.md` §2.3.4.

**A read is at a consumer.** A call reads its argument at the locations that the callee's contract flags. An
unknown callee reads all of it. A list pattern reads its list. The frame's result is read where it is
answered. A binding, a field access and a construction read nothing: they make another holder. A value of
another arm of the same `case` is not a holder.

### 2.5 Contracts

A contract is a table over the locations of a signature.

| Part | Content |
|---|---|
| each parameter location | `R` the body reads it, answers it or hands it on; `W` the body writes it, so the caller must hand it `own`; `E` the body lets it escape; `S` the body hands it to a function parameter that can write it |
| each result location | its sources: `fresh`, `shared`, a parameter location, the answer of a function parameter |
| each function parameter | what the body hands each of its parameters (sources); `free`: the body does not read what it handed; `answer-escapes`: the body lets the function's answer escape, or a cell keeps it; `rewrites`: the body writes a cell after it handed that cell to the function |
| the whole | `nonlinear`: a cell of a parameter can be at two places of the result; `old_result`: an answer can be an object that was there before the call |

A location with no source holds no cell. A group of declarations that calls itself starts from empty
contracts and is walked again until no contract changes. The contracts only grow, so the verdicts of the last
round stand on the least fixed point.

A declaration with ownership words is not inferred: its words are its contract. A `foreign` with no word has no
contract: each argument escapes, and the answer is `shared`.

### 2.6 Function values

- A lambda and a local function have a contract of their own. Their captures are more parameters.
- A constructor used as a function has the contract "the result's argument `k` is parameter `k`".
- A call of a function parameter records what the body hands it. The check "could the function write this"
  is the write rule, with no report line. It gives `free`.
- At a call that hands a known function to a function parameter, each location that the function writes is
  judged against the callee's sources for it. A source that is the caller's argument gives a demand at the call
  site. A source that is the function's own answer asks the function to answer `own` there.
- A function that the frame was handed and hands on (`foldl xs acc func = foldlFrom … func`) joins the
  callee's sources into the frame's own. The same holds through a lambda that calls a captured function
  parameter (`Tea.tableFoldl`).
- A function value that writes its parameter and goes where no rule follows it is refused at that place
  (`cause call`). So an unknown caller never runs it with a value that is not `own`. A function that goes there
  escapes with each value that it captured.

The rules below were not in the first version. The sanitiser corpus found that each was necessary (§3.9).

- **An answer with no claim keeps what it can hold.** The answer of a known function holds the values that
  the function captured and answers. Where no rule follows an answer (a function in a `case`, a function that
  a call answers), it can hold a cell of each argument of the call.
- **An answer in a supply is followed.** A callee can hand a function the answer of another function, or its
  own answer at another part. What that answer holds, this answer can hold. The walk stops at an answer that
  is in work already: the result is the least fixed point.
- **`answer-escapes`.** At the call that gives the function, each cell that the answer can hold escapes.
- **An answer that comes back.** A callee can hand a function its own answer (`List.foldl`). A function that
  writes that parameter must answer `own` there. It must not let the answered value escape, it must not hand
  it to a function that can keep it, and its contract must not be `nonlinear`.
- **`rewrites`.** A function that keeps its parameter cannot go where the callee writes the handed cell later.
- **A captured function.** A known function that goes to a callee can call a function that it captured. If
  that function is the frame's own parameter, the frame's contract composes the two. If not, no rule composes
  them: the captured function must not write its parameter, and if it can keep one, each argument of the call
  escapes.
- **Evidence.** A declaration that a call hands as `where` evidence must not write its parameter.

### 2.7 The entry and sends

- A call whose callee has the word `entry` on parameter 0 takes a record of functions. The runtime hands
  `update` a model that is `own` at each location where `init` and `update` answer it `own`, no location is
  answered two times, and no other function of the record keeps it.
- The word counts only where the parameter's type has the state protocol (v2's shape test,
  `Prepass.entryProtocol`). If not, the record goes to code that the checker does not see.
- `update` owns its message. This holds because each call of the runtime's `send` is a demand on the message
  (each list cell of it must be the sender's own), and because a function or a made value that a view puts into
  markup escapes.
- A view's other markup operands are read, not kept. v1 has the same rule.

---

## 3. Where the sketch of report 110 was wrong or silent

### 3.1 The call map is not the identity

Report 110 §6.2 says that one function maps names at a call "by the type substitution", and §6.8 says that a
name cannot be missed. This is false for a type argument that names the container again:

```beni
type Node = Leaf Int | Quote (List Node)

collect : List Node, Dict String Int → List Node × Dict String Int
collect nodes refs = List.foldl nodes ( [], refs ) λnode ( acc, r ) → …    -- core/Markdown.beni:1270
```

`List.push : List a, a → List a` has two locations: the list, and the type variable. In `List Node` the list is
on a cycle, and the signature's type is not. One caller location then holds cells of both signature
locations. Rules 3 and 4 of §2.2 are the fix. The first version of the prototype had the identity only, and it
gave no verdict at all for the six writes of `core/Markdown`.

### 3.2 The option of §6.2 is necessary

With one location for all levels, the accumulator of `collect` and the lists inside its elements are one
location. A write of the accumulator then asks for each nested list, and `Dict`'s rotations lose the root.
With the entry level apart, these are accepted. The measurement that §6.2 asked for is: 6 of the 308 writes,
and the false refusals of each recursive function over a tree.

### 3.3 "Today's liveness, unchanged" was not usable

Report 110 §6.3 keeps v2's liveness and holder check. They are written over slots (paths with level marks) and
over the account of each declaration. The prototype needs two facts that v2's index does not have:

- **which locations the consumer reads.** `changed { model | draft = "" } (model.todos ++ [ … ])` is in each
  TodoMVC of the repository. The first argument holds `model.todos`. It is a holder only when `changed` reads
  that field. So a contract needs a read flag for each parameter location, and a read is recorded at the
  consumer with that mask.
- **which name is new.** `a = f rows`, `b = f a` is a chain of writes. With a new atom for each written
  result, "read after the write" needs no definition point.

The first run with reads at each local reference accepted 247 of 308. These two rules gave 267.

### 3.4 Step 0's scope does not reach step 0's gate

Report 110 §7 puts "contracts for first-order code, and for known lambdas at the worded loops of `core/`" in
step 0, function contracts in step 2, and the entry and sends in step 3. But:

- `List.foldl`, `List.map`, `Dict.foldl` and `Tea.tableFoldl` are ordinary recursive beni functions with no
  word. So the contract of a function parameter must be inferred, with its fixed point, in step 0.
- 16 of the 308 writes are at a program's entry, and 7 are sends. Without them the best count is 285.

The prototype has both. They are most of `Frame.zig`, and they are where a normative text is most necessary
(§3.9).

### 3.5 "A forgotten case gives `shared`, which refuses" is half of the rule

`shared` refuses a write of the location. It does not say what the location holds. The first generator run
found three traps in 80 programs (§4.2), all one fault:

```beni
v0 = [ q, q ]        -- one cell at two positions: the element location is `shared`
v3 = [ …q, 8 ]       -- accepted, and wrong: `v0` is read later
```

The element location lost its sources when it became `shared`, so `v0` was no holder of `q`. The rule is now:
**a `shared` location keeps its sources**, in a value and in a contract. Report 110 §6.3 must say it.

### 3.6 Two trusted rows are by name

- `Dict.focus` of `core/` hands out the value at a key and puts the answer back. Its row is asserted in its
  comment, and v1 reads it by name. The prototype does the same (`Check.isDictFocus`). The row belongs in a
  word, as `List.focus` has (`once taken stored`).
- The runtime's `send` is the alias `Send msg` of a platform. The word `sender` exists for it, and no platform
  uses it. The prototype reads the alias by its name (`Check.isSender`).

### 3.7 A function that rearranges its argument

`Dict.insert` rotates a tree. Its result holds each cell of its argument once, at another place. A contract of
sources alone cannot say this, so two parts of the result looked like one cell. The `nonlinear` bit says it.
The same fault is still in `Dict.remove`, through two levels of calls (§4.4, cause 3).

### 3.8 "A value from JavaScript is `shared`" costs real writes

Report 110 §6.3 has this rule. The feed of `examples/conduit` comes from the network, through decoders that are
`foreign`. It is `shared`, so a send of it is refused (2 of the 308). A row must say that a decoder makes a
`fresh` value. v1 and v2 read each unworded `foreign` answer as the caller's own; that is not safe for
`Js.get`.

### 3.9 The contract of a function parameter was not closed

Report 110 §6.3 and §6.8 say that a forgotten case gives `shared`, and `shared` refuses. This is true for a
value. It is false for a function value. A fact that is missing from the contract of a function parameter does
not give `shared`: it gives "nothing happens", and the write is accepted.

The first full run of the sanitiser corpus showed it (§4.2). The prototype accepted 19 of the 182 programs
that v2 refuses. 18 of them trap, and one prints a different text. A probe found one more program.

| Cause | Programs | What was missing |
|---|---:|---|
| An answer with no claim lost what it holds | 8 | A known function answers a list that it captured, or the answer of another function. The answer became `shared` with no source, so a later write of the captured list saw no holder. This is §3.5 again, in `expandAnswer` |
| Where the answer goes | 5 | The callee lets the answer of a function parameter escape (a task reads it), or a cell keeps it. The contract had no flag for it |
| A function that keeps what the callee changes later | 1 | The callee hands a list to the function and writes the list later. A function that keeps its parameter reads the edit |
| Two parts of one handed value | 2 | A function writes one field of what a callee hands it. Another field of the same value held the same list. The test compared locations of the callee's signature, where the two fields are one location |
| A prepend | 1 | The prototype read `[ x, …xs ]` as a copy. The row of `List.cons` says that it can answer the base's array |
| Evidence | 1 | The evidence of a call is at the call instruction. The prototype read it at the callee's reference, so no call was checked. A fault of the code, not of the design |
| An `entry` record of an unknown shape | 1 | The prototype read each record with the word as a program of the state protocol |
| A captured function that writes (a probe, not in the corpus) | 1 | A lambda that goes to `List.foldl` calls a function that it captured, and that function writes its parameter. No demand was made on the supply |

16 of the 19 are about function parameters. Each fix is small: the eight fixes and the two of §3.10 and §3.11
are 453 added lines. No fix changed a location, a permission or the write rule for first-order code. But the
design did not find these cases: the corpus did, and it was written against v2's holes.

v2 has each of these facts in a precise form (`ownership-v2.md` §2.9.2, §2.11.3, §2.13.7). The prototype now
has a coarse form of each, and it refuses more programs for it (§4.4). So "a sound core that is small" is
shown for first-order code only. For function values the prototype is smaller than v2 because it refuses
more, and the corpus is the only evidence that its rules are complete.

### 3.10 A new name is not a fact about each later write

§2.4's "a write makes a new name" had a second fault. The second family of the generator found it in its
first 600 programs (§4.2):

```beni
callBoth : (List Int → List Int), (List Int → List Int), List Int → List Int × List Int
callBoth f g xs =
    a = f xs
    ( a, g a )

v1 = (callBoth ident ident q).1            -- `callBoth` hands `q` to a function that could write it
v2 = { v0 | a = List.push v0.a 1 }         -- `v0.a` is `q`: accepted, and wrong
"${show v1}"                               -- `v1` is `q`
```

The contract of `callBoth` says that its function can write `xs`. So the result got a new name, and the name
`q` was marked old. `ident` does not write, so no write demand was made at the call, and the old name stayed
in use. The later write of `q` then did not see `v1` as a holder: an old name was no holder for any write.

The rule is now: an old name has the instruction of the call that made it old. For that call and for each
write before it, the value with the new name is no reader of the old value. For each later write it holds
the cells. Report 110 §6.3 has no text for this, because it keeps v2's liveness.

### 3.11 "`shared` keeps its sources" has a cost

The rule of §3.5 copies the sources of a location each time a value is read through a wider location. On
`bench/corpus/Ui/Html.beni` (a recursive type with 16 locations, and a `map` over it) one run of atoms held
each atom many times, and `Frame.finish` compares runs in pairs. That module took 415 ms of the 566 ms that
the prototype used on all 32 roots. A run of atoms is a set now (`Frame.uniqueTail`), and the module takes
4.9 ms. The first speed figure of the prototype (before §3.5) did not have this cost.

---

## 4. Measurements

All figures are of the pull request's head merged with `master` (`59ea68b8eb`), on a ReleaseFast compiler
(Zig 0.17.0, LLVM), one machine, 2026-11-11. Appendix A has each command.

### 4.1 Real list writes

The 32 real roots are those of report 110: `core`, the six platforms, the eight examples and 17 roots under
`bench/`. Each is dumped with `--ownership-everywhere`.

| | v1 | v2 | prototype |
|---|---:|---:|---:|
| lines of the report | 308 | 340 | 331 |
| accepted | 308 | 308 | 311 |
| refused | 0 | 32 | 20 |
| of the 308 writes that v1 judges: accepted at the same position | 308 | 252 | **299** |

The prototype refuses nine of v1's 308 and has a line for each. It has no refusal at a position where v1 has
no line. Its 20 refused lines are these nine positions (a write of a value with several locations has one line
for each location). The figure for v2 is a lower bound: v2 has no line at 29 of the positions (16 are the
entry lines, which v2 prints in another form).

By the ground of v1's verdict:

| v1's ground | writes | the prototype accepts |
|---|---:|---:|
| `param` (a parameter that the body writes) | 185 | 185 |
| `call` (a call's result) | 51 | 44 |
| `fresh` (a value that the frame made) | 36 | 34 |
| `callback-param` (a lambda writes what a loop hands it) | 20 | 20 |
| `entry` (the program's model) | 16 | 16 |

### 4.2 Traps and output differences

A program is built two times. The oracle is a plain build: no list is edited in place. The second build has
`--ownership=v3 --ownership-everywhere --sanitize-lists`: each write that the prototype accepts runs on a copy
and poisons the list that it wrote, so a later read of that list throws. A **trap** is such a throw. A
**difference** is another text or another exit code.

**The sanitiser corpus.** 345 fixtures of `tests/corpus/run` have a `.sanitize-lists-v2` file. v2 accepts 163
of them and refuses 182.

| | first full run | final run |
|---|---:|---:|
| v2 refuses, the prototype refuses | 163 | **182** |
| v2 refuses, the prototype accepts: trap | **18** | 0 |
| v2 refuses, the prototype accepts: different output | **1** | 0 |
| v2 accepts, same output | 98 | 95 |
| v2 accepts, the prototype refuses | 65 | 68 |

The first full run was at the end of the precision work, when the count of §4.1 was 299 already. §3.9 has the
19 programs by cause. The fixes cost three fixtures that v2 accepts, and no real write.

**The generator** (`bench/ownership-step0-generator.mjs`). A program is one function of three to seven
bindings over lists, pairs, records, lists of lists and a tree with a list at each node. A binding takes its
operands from earlier bindings, most often the newest, so many programs read a list after a write of it. The
first family is first-order, with a few lambdas at `List.foldl`, `List.update` and `List.map`. The second
family (`--family=higher`) adds function values in locals, lambdas that answer a list that they captured, a
pair accumulator that the lambda swaps, a function that calls two functions, and cells.

| run | programs | same output: v1 | v2 | prototype | traps and differences of the prototype |
|---|---:|---:|---:|---:|---:|
| first family, first run (Debug compiler, before §3.5's fix) | 80 | | | | **3** traps, one fault (§3.5) |
| second family, first run (Debug compiler) | 600 | 218 | | 219 | **1** trap, seed 144 (§3.10) |
| first family, final | 2 000 | 450 | 450 | 502 | 0 |
| second family, final | 2 000 | 708 | 458 | 700 | 0 |
| first family, long run (seeds 2 001 to 22 000) | 20 000 | 4 641 | 4 641 | 5 058 | 0 |
| second family, long run (seeds 2 001 to 22 000) | 20 000 | 7 152 | 4 739 | 7 212 | 0 |

In the long runs the prototype accepts 463 programs of the first family that v1 and v2 refuse, and refuses 46
that they accept. In the second family it accepts 263 that v1 refuses and refuses 203 that v1 accepts;
against v2 the figures are 2 648 and 175.

v2 has no trap and no difference in any run. **v1 traps on 4 of the 20 000 programs of the second family's
long run.** Each has one shape: a `Ref.update` callback answers a list that it captured, the list is written
in place, and the cell is read. It is the fixture `SanitiserCellStoredCapture`, which v2 and the prototype
refuse and v1 accepts (#2474). A plain build is right today, because a build copies.

**Probes.** 19 programs written by hand for this report, each a function value that goes somewhere (a `case`,
a record field, a list, a constructor, a partial application, a call's result, a local recursive function).
One was accepted and trapped (the last row of §3.9's table). It is a black-box test now.

**What this does not cover.** No page ran under the prototype, so the entry rule and the sends have only the
check of §4.1's 23 lines, and no run. The generator has no recursion, no module boundary and no `entry`.

### 4.3 Speed

`bench/ownership-v2-review.mjs`, five runs for each checker, the best time of each phase, `--jobs=1`. The time
of a checker is the sum of its `ownership_module`, `ownership2_module` or `ownership3_module` profile events.

| | lines | ms | lines per second |
|---|---:|---:|---:|
| type check (for scale) | 171 766 | 286.0 | 601 000 |
| v1 | 171 766 | 1 170.0 | 147 000 |
| v2 | 171 766 | 1 447.4 | 119 000 |
| prototype, on the modules that v2 walks | 171 766 | 163.7 | **1 049 000** |
| prototype, on all that it walks | 558 336 | 422.5 | 1 321 000 |

The prototype reads no block of the checked core, so in each root it walks `core/` and the platform again:
558 336 lines in all. v1 and v2 walk a root's own modules. The fourth row is the like-for-like figure: the
prototype's time on the files that v2 walked.

The slowest roots, in lines per second of the prototype's own walk: `platforms/browser` 728 000 (44 007
lines, 60.5 ms; v2 523.0 ms), `bench/corpus` 882 000, `examples/conduit` 1 135 000. No root is below the gate.
Before the fix of §3.11, `bench/corpus` ran at 35 000 and the like-for-like figure was 300 000: one module
can move the total, and the 32 roots have one such module. The figures have no cost of a block, of a cache or
of diagnostics with a fix text (§6).

### 4.4 Losses

**Against v1, on real code: 9 writes, 4 causes.**

| Cause | Writes | Where | The part of report 110 that has it |
|---|---:|---|---|
| A function that a call answers is called (`(firstOf [ … ]) "email" form.email`): its answer has no claim, and `andMap` writes it | 5 | `bench/corpus/FormValidation.beni` 212 to 216 | step 2, a contract on a function-typed result |
| A function taken out of a list is called by the fold's lambda; its answer comes back to the lambda, which writes it | 1 | `FormValidation.beni` 128 | step 2 |
| The fold's lambda answers `Dict.update acc …`. `Dict.update` can remove a key, and the removal rebuilds the tree through two levels of calls: the contract is `nonlinear` (§3.7), and the answer comes back | 1 | `FormValidation.beni` 275 | step 1, a contract that says "each cell once" through calls |
| A value from JavaScript is `shared`, and it is sent (§3.8) | 2 | `examples/conduit` `Home` 135, `ProfilePage` 164 | a `fresh` row on a decoder |

**Against v2, on real code.** v2 accepts 308 lines. At the same position the prototype accepts 256, refuses 5
and has no line for 47. The 5 are one write (`FormValidation.beni` 275, five locations; the third row above).
42 of the 47 are demands on a cell, and 5 are `Ref.make` and `Task.onExit` lines: the prototype has no cells
and no fibers. v2 refuses 32 lines. The prototype accepts 21 of them (v2's causes: `disjoint` 13,
`held-operand` 6, `call` 1, `escaped` 1), refuses 6 and has no line for 5.

**Against v2, on the sanitiser corpus: 68 of the 163 fixtures that v2 accepts.** Each of these fixtures is the
accepted twin of a fault that v2 once had, so it sits at the edge of what v2 can show. By the subject of the
fixture: function values 36, the rows and levels of a type 18, cells 10, other 4. By the prototype's cause (a
fixture counts once for each cause that it has):

| Cause | Fixtures | What it is in the prototype |
|---|---:|---|
| `call` | 23 | a function that writes goes where no rule follows it (a `case`, a field, a result), or is called by a function that goes on |
| `unknown` | 22 | a value with no claim: the answer of an unknown function, a value from a cell, a wide location that the cover maps to `all` |
| `supply` | 17 | a function writes or keeps what a callee hands it, and the coarse test of §2.6 cannot show that it is `own` |
| `captured` | 7 | a write of a value that a closure captured |
| `later-use` | 7 | a holder that the precise relation of v2 shows to be apart |
| `escaped` | 3 | |
| `disjoint` | 1 | |

**Against v1 and v2, on generated programs.** §4.2: 46 of 20 000 in the first family, 203 (v1) and 175 (v2)
of 20 000 in the second.

---

## 5. The gate

| Gate of the owner's request | Result | |
|---|---|---|
| At least 300 of the 308 real list writes accepted | 299 | **missed by one** |
| No trap | 0 traps and 0 different outputs on 345 fixtures and 44 000 generated programs, after the faults of §3.5, §3.9 and §3.10 were fixed | **holds at the end; did not hold at the first run** |
| More than 500 000 lines per second on the 32 roots | 1 049 000 on v2's modules; 1 321 000 on its own walk | **holds** |

The gates of the repository (`zig build gates`) are green on the same tree.

---

## 6. What the prototype does not show

- **Soundness is tested, not shown.** The generator makes two families of programs. The sanitiser fixtures
  were written against v2's holes, and they found 19 of the prototype's. A fault of the prototype that v2
  never had has no fixture. No proof exists. The first-order rules of §2.1 to §2.5 are small enough for the
  Lean model that report 110 §6.8 names. The rules of §2.6 are a list of cases, and nothing shows that the
  list is complete. That work did not start.
- **The entry rule rests on the runtime.** `update` owns its message and its model only if the page renders
  again after each `update` and keeps no list of the view. v1 has the same assumption. No page test ran under
  the prototype.
- **No module boundary on disk.** Contracts go from a module to its importers in memory. No block, no cache and
  no row in the checked core exist. The speed figures do not have the cost of a block.
- **No cells, no records in place, no fibers.** A cell's contents are `shared`. v2 has 52 lines on the real
  roots (cells, fibers, a top-level value) at which the prototype has no line.
- **One thread.** The hook runs on each module's worker, and the contracts are in one slot for each module, so
  a run with more jobs works. Only `--jobs=1` was measured.
- **The walk is recursive.** A very deep expression can use up the stack. v2's walk has an explicit stack.
- **Diagnostics.** A refusal has a cause and a short text. It has no fix text of v1's quality.

---

## 7. The next step

Each item is the owner's decision.

1. **Set the first gate.** The count is 299 of 308, one below the number that report 110 proposed. The nine
   losses are in §4.4. Six of them are one rule that step 2 has (a function that a call answers).
2. **Make the sanitiser corpus a gate of the flag before more code.** One run of the 345 fixtures takes 20
   seconds on a ReleaseFast compiler. It found 19 faults that 299 accepted real writes did not show. A pass of
   the corpus under `--ownership=v3` (refused, or the same output as a plain build) must be green before each
   later step. A black-box test has the 19 programs now. The generator belongs beside it, as a `zig build`
   step.
3. **Write the normative text** (rule 1 of `CLAUDE.md`). §2 is its outline. The first-order part is short:
   locations with an entry level and a deep level; the call map with its fallback; the write rule with new
   names, the point of an old name, and reads at consumers; contracts with four flags, sources and the
   `nonlinear` bit. The part for function values (§2.6) is the hard one. It must say, for each way a function
   value can go, which fact the contract has and who checks it. v2's text for the same facts
   (`ownership-v2.md` §2.9.2, §2.11.3) is the list to check it against.
4. **A mutant for each rule of §2.4 to §2.7**, as `zig build test-own2-mutations` has for v2. Each fix of §3.9
   is one condition in `Frame.zig`. A mutant that removes it must make a fixture fail.
5. **Put a row where the prototype reads a name.** The word `sender` on the platforms' `Send`. Words on
   `Dict.focus`. A `fresh` row for the decoders that make a value from JavaScript.
6. **Functions as results, and precise supplies** (report 110, step 2). A contract on a function-typed result
   location gives back six of the nine real losses. The 36 lost fixtures about function values need v2's
   precision for supplies and answers; the prototype's coarse rules are the floor, not the plan.
7. **Blocks** (report 110, step 4, moved earlier). `Contract.Published` holds no id of a module already.
   Until a block exists, a run under the flag checks `core/` from source, and no build can use the prototype.
8. **Records, cells and fibers** (report 110, step 3), on the same atoms: a record's field is a location.
9. **The Lean model**, for §2.1 to §2.5 first.

Do not start items 5 to 9 before items 2 and 3. The prototype's code is a measurement tool. It has by-name
rows and no explicit stack, its text of a refusal is short, and its rules for function values were found by
tests, not derived.

---

## Appendix A. Commands

All from the repository root. `TMPDIR` must point to a directory on disk.

1. **The compiler.** `zig build test-perf "-Dtest-filter=generated module of §7.6"` installs the ReleaseFast
   compiler at `zig-out/perf/bin/beni`.
2. **Real writes and speed (§4.1, §4.3, §4.4).**
   `node bench/ownership-v2-review.mjs --checkers=v1,v2,v3 --roots=real --runs=5 --jobs=1`. The last part of
   its output is the prototype's table, the list of the writes of v1 that the prototype does not accept, and
   the same comparison with v2's lines. About 40 seconds.
3. **The sanitiser corpus (§4.2).** `node bench/ownership-step0-sanitiser.mjs --beni=zig-out/perf/bin/beni --jobs=4 --list`.
   It builds each `tests/corpus/run` fixture that has a `.sanitize-lists-v2` file two times: plain (the
   oracle), and with `--ownership=v3 --ownership-everywhere --sanitize-lists`. About 20 seconds.
4. **The generator (§4.2).**
   `node bench/ownership-step0-generator.mjs --beni=zig-out/perf/bin/beni --count=2000 --seed=1 --jobs=4`,
   and the same with `--family=higher`. About one minute for each. The long runs have
   `--count=20000 --seed=2001`. `--print=<seed>` prints one program. `--keep=<dir>` keeps each program.
5. **One module.** `beni dump --stage=ownership --ownership=v3 --ownership-everywhere --platform=node M.beni`
   prints each verdict and each declaration's contract (`summary` lines: `W` and `E` flags, the sources of each
   result location, and what each function parameter is handed).
