# The ownership checker — the in-compiler contract

*Normative from 2026-10-12. Slice 1 (report mode, intra-procedural) is specified here and built;
slices 2–5 are specified as a plan (§13) and are not built. Sections are never renumbered
(CLAUDE.md rule 2): a later amendment appends text to the section it changes, dated, or a new
section after the last.*

*Amended 2026-10-12: slice 2 — summaries, the caller's side of a written parameter, the recursion
fixpoint and the library's asserted primitive rows — is specified in §16 and built; §15 records the
manager's answers to §14.*

*Amended 2026-10-12: slice 3a — the destructive read as two primitives, exclusive contents, local-function
groups, once closures and capture paths of function parameters — is specified in §18 and built; §17 records
the manager's answers to §16.14.*

The argument for the checker is the thesis `docs/thesis/ownership/` ("Edit in Place or Not at
All", 2026-10-11, with its five reviews and responses in `reviews/`). This document is not that
argument. It is the contract the compiler implements: which IR the pass reads, which abstract
domain it computes, what it prints, and what each later slice adds. Citations of the thesis are
by chapter and section in its own numbering — Chapter 3 is *The Model*, 4 *Inference*, 6
*Soundness*, 7 *The Hard Cases*, 8 *Error Reporting*, 9 *Integration with the Compiler*, 11
*Changes to the Language and Library*, 12 *Evaluation Plan* — and by the programs of its Table
6.2, T1–T59. The Lean reference model in `proofs/ownership/` (`DESIGN.md`, `COVERAGE.md`) is the
executable statement of the core rules; where this document and the Lean model disagree on a rule
both implement, that is a defect in one of them.

---

## 0. The answer in eight sentences

1. **What it is.** A pass that finds every *demand* — an operation that would write a list in
   place under the thesis's rule: the named writers of `core/List` and every list construction
   with a spread or a `++` (thesis §3.8, Change 1) — and decides whether the list it writes is
   *unique at the site* (thesis §3.3, Definition 3.1): no holder of it is read afterwards.
2. **Slice 1 changes nothing a program does.** It runs only under `beni dump --stage=ownership`,
   prints one line per demand, and writes no file; emitted JavaScript, interfaces, cache keys and
   run hashes do not move (§10).
3. **It runs on BIR, after the checker**, reading the solved type of every expression instruction
   — the one hook it adds to the checker, a table kept only when a dump asks for it (§2).
4. **Its domain is the thesis's** (§3.4): abstract values that map typed paths to sets of
   abstract cells, with per-path liveness over the walk's evaluation order (§4–§7), restricted in
   slice 1 to one declaration at a time.
5. **Calls are conservative in slice 1, and exactly so** (§6): a call reads every list its
   arguments reach, and its result is a fresh cell plus every argument cell its type could hold;
   only the demands themselves and `List.copy` have rows.
6. **A rejection names its cause**, from a closed list (§8.3), and says whether it is real sharing
   the text shows (*exact*), a limit of the analysis (*approximate*), or the position rule
   (*position*) — the thesis's three verdicts (§8.4), so the evaluation can count them.
7. **The report is an upper bound only on what calls cost**: a rejection whose every cause is a
   conservative call may vanish with summaries, and an acceptance that rests on a parameter or a
   call result is *pending* — slice 2 decides it (§8.2). Research 74 measures slice 1 on core, the
   platforms, the corpus and the applications.
8. **Slices 2–5** publish summaries in interfaces, run the external Elm corpus of thesis §12.4,
   make a rejection a compile error with the messages of thesis Chapter 8, and generate in-place
   code on `browser-direct`, differential-tested against the Lean oracle (§13).

---

## 1. Scope

### 1.1 What the full checker is

Thesis Chapters 3 and 4: per function, a forward walk computes abstract values; a backward pass
computes per-path liveness; at every demand four side conditions are checked — **Known** (the
cell is not ⊤), **Unescaped** (not escaped, not a top-level value's), **Dead** (no holder is read
later), **Disjoint** (no other operand reaches it) — and the function's summary is read off and
published (thesis §3.7, §4.4). Recursive groups iterate to a fixpoint (§4.5); function values carry
ownership classes (§3.6, §4.7); containers carry an exclusive-contents flag (§3.11); a TEA program's
entry state is computed from `init`'s and `update`'s summaries (§7, *The TEA runtime*).

### 1.2 What slice 1 builds

Slice 1 builds the forward walk, liveness and the four side conditions **inside one declaration**,
with the restrictions below. It publishes nothing and reports everything.

| Thesis piece | Slice 1 |
|---|---|
| Demands (§3.8): writers, constructions, `++` chains | built (§3) |
| Abstract values, paths, cells (§3.4) | built, without opaque slots and representatives (§4) |
| Transfer rules (§3.5, Table 3.2) | built for every form, calls conservative (§5, §6) |
| Liveness per path (§3.9), evaluation-order uses (§3.3) | built (§7) |
| Known, Unescaped, Dead, Disjoint (§3.10) | built (§8) |
| Summaries and their read-off (§3.7, §4.4) | **not built**: calls use §6 |
| Recursion fixpoint (§4.5) | not built: a self call is a call |
| Ownership classes, once closures (§3.6, §4.7) | not built: an edit of a captured list is rejected as a limit (§8.3, `captured-edit`) |
| Exclusive contents (§3.11) | not built: an element edit whose container lives is rejected as a limit (`element`) |
| Opaque slots, folding of recursive types (§3.1) | not needed: paths are walked on demand and cut at k = 8 |
| TEA entry protocol, renderer obligation (§7, P1–P7) | not built |
| Derivation tags (§8.4) | built for the causes slice 1 can produce (§8.3) |
| Messages (§8.1–§8.3) | not built: the report line (§9) is for people and tests |

### 1.3 The platform

The thesis's decision is that only `browser-direct` writes lists in place (Change 8, rule 7 of thesis
§2). Slice 1 does not depend on the platform: the verdict is a function of the source and of
`core/`, and the dump runs under any `--platform` (§9). Slice 5 is the first that is
platform-specific.

---

## 2. Where it runs

### 2.1 The IR: BIR, walked in evaluation order

The thesis assumes "an evaluation-order normal form … in the style of A-normal form" (§3.3) and
says beni's IR "is already a sequence of instructions in evaluation order" (§4.2). The compiler has
two IRs. **JsIr** (`backend.md` §3) is in evaluation order but has no types, and the thesis needs
types (§9.1: "It cannot run later, because beni's backend sees no types"). **BIR**
(`frontend.md` §3.6, `src/bir/Bir.zig`) is typed by the checker but is a *tree*, not a flat
sequence, and its instruction indices are not in evaluation order: a `let`'s `let_def` records
precede the values they bind. So the pass, like the write-set analysis (`write-sets.md` §3.3) and
effect inference (`checker-v2.md` §26), **walks BIR's expression tree in evaluation order** —
callee, then arguments left to right, then the call; a structure's items in source order, then the
structure; a `let`'s items in source order, then its body; a `case`'s scrutinee, then each arm
separately — and gives every consuming instruction a **point**, a counter that increases along that
walk. The normal form of thesis §3.3 is the walk's order, not a materialised IR: an operand that is
a variable is a *use at the instruction that consumes it* (§7.1), which is exactly what the normal
form buys.

A cell site is named by its BIR instruction index (thesis §9.1); points are what liveness compares.

### 2.2 Where in the pipeline

After the checker, on every module the run checked, before anything is emitted — the position of
thesis §9.1, beside effect inference. In slice 1 it runs only inside `beni dump --stage=ownership`
(§9), after `Session.check_phases`, with `keep_type_stores` set. It reads:

- each module's BIR (`Artifacts.bir`);
- each module's kept check tables (`Check.Module`): `local_type` (one variable per local) and the
  new **`inst_type`** (§2.3);
- the dispatch table (`Check.dispatch`): `appends` says which `++` is on lists (`language.md`
  §6.8, O6), and a method call's resolved callee;
- the resolver's provenance tables, to turn an `ext_value` into `(module, declaration)`;
- the session type table (`check/Types.zig`), to decide crossing (§4.4).

### 2.3 The one checker hook: `inst_type`

`Check.Module` gains `inst_type: []Var.Optional`, indexed like `Bir.insts`. The constraint generator
writes, for every expression instruction it constrains, the variable it was constrained against
(`constrain/Expr.zig`'s `expected`), which after solving is that instruction's type. It is allocated
only when the run keeps the type stores (`dump --stage=types`, `--msg-types`, `--stage=ownership`)
and is never read by the checker: `Context`'s rule that the solver reads no generation-time context
(`checker-v2.md` §6.2) holds, because nothing in `src/check/` reads the table. A build allocates
nothing and writes nothing.

### 2.4 Why a dump stage and not a `build` flag

`write-sets.md` §8.1 set the precedent: a read-only pass ships first as a dump stage, whose output
is a corpus golden. The thesis's own report mode names the same command (§12.3: "for instance under
`beni dump --stage=ownership`"). A `build --ownership-report` flag would have to prove at every
build that the report does not change the output; a dump writes no output to change. The stage
**resolves imports** like `types`, `dispatch` and `writes` (`Cli.stageResolvesImports`), so it takes
`--platform`, `--core` and `--core-root`. It takes a file or a directory (§9.1). The stage is
**hidden** — parsed, but listed in no usage text and no error message — until slice 4 makes the
checker a diagnostic; `--writes-work` and `--allow-debug` are hidden the same way.

---

## 3. Demands

Thesis §3.8. A demand is an operation whose operand — the **base** — it would write in place.

### 3.1 The named writers

A call whose callee is core `List.set`, `update`, `push`, `pop`, `swap`, `insertAt` or `removeAt`
demands its first argument; `List.cons` its second; `List.append` its first. Only core's `List`
module counts: a platform module named `List` is not core's. A writer passed as a value and called
through a local is not a demand in slice 1; it is a conservative call (§6).

### 3.2 Constructions

**A list literal with a spread is one construction, and its base is the operand of its first spread**
(Change 1). Lowering writes such a literal as right-nested `List.cons` and `List.append` calls, each
stamped with a `…` token (`Lower.lowerSpreadList`, `language.md` §6.8). The pass reads it back as one
construction: a call of core `List.cons` or `List.append` whose main token is an `…` is a
construction's call, and the calls nested in its last argument belong to the same construction when
the tokens between their two `…`s are balanced brackets (a spread literal written inside the last
spread is a construction of its own). Its items, in source order, are the first argument of each
call plus the last spread's operand or trailing literal; the base is the first spread's operand.

**A `++` chain on lists is one construction** whose base is its leftmost operand: `a ++ b ++ c` is
`[ …a, …b, …c ]` (thesis §3.8, *Chains are flattened on purpose*). A `++` is on lists when the
dispatch table's `appends` lists it. Its right operand, when it is itself a `++` on lists, is part of
the chain. `++` is right-associative and BIR keeps no parentheses, so `a ++ (b ++ c)` written with
them is the same tree as `a ++ b ++ c` and is read as the same one construction, whose base is `a`;
`(a ++ b) ++ c` is two, the inner one's base `a` and the outer one's the inner result. The backend
does not yet lower either way in place (slice 5 lowers the flattened chain, Change 1).

**Not demands** (thesis §3.8): `[ …xs ]`, which lowering already writes as `xs`; a literal with no
spread, which allocates; a pattern, which only reads; and a list re-built in the shape a pattern just
matched — `[ h, …t ]` whose items are exactly the locals that `[ h, …t ]` bound in an enclosing arm,
or `[ …init, last ]` after `[ …init, last ]` — which is an alias of the scrutinee.

### 3.3 The order of a construction

A construction is one point. Every item is evaluated first, in source order (`language.md` §6.8,
*Evaluation*), and then the base is written: so `[ …xs, List.length xs ]` reads the length before the
push, and is accepted (thesis §3.3).

### 3.4 `List.copy`

Change 2 adds `List.copy : List a → List a`, "new, shallow and fresh". Slice 1 adds it to
`core/List.beni` (a plain array copy over `Js`, as `slice` is) and gives it its row (§6.2): its result
is a fresh cell whose elements are the argument's. It is not a demand.

---

## 4. The abstract domain

Thesis §3.1 and §3.4, restricted.

### 4.1 Paths

A path is a sequence of at most k = 8 steps (thesis §3.1; `write-sets.md` §2.2): a record field
`.f`, a tuple index `.i`, a constructor argument `C#i`, a list position `[*]`, the environment step
`◇` of a closure, and a slice-1 step **`⋆`**, "at some path at or below here", which is what a
conservative call's aliases are placed at (§6.1). A projection past the cut stays at the cut; a
`⋆` overlaps every path. Two paths **overlap** when one is a prefix of the other, step by step, with
`⋆` overlapping anything; that is the prefix order of thesis §3.9 without folding, which slice 1 does
not need because it walks no type's definition into paths.

### 4.2 Cells

| Cell | Meaning | Thesis |
|---|---|---|
| `site(ι)` | the array a list literal, a construction's fresh base or a `List.copy` at instruction ι makes | `site(ι)` |
| `param(x, q)` | the cell at path `q` of the parameter (or pattern root) `x` of a declaration or lambda, as it arrived | `πᵢ.q` |
| `result(ι, q)` | the fresh cell at path `q` of the result of the call at ι (§6.1) | `fresh_k` of a summary |
| `env(x, q)` | inside a lambda: the cell at path `q` of the captured local `x` | `◇.q` |
| `shared(v, q)` | a cell of the top-level value `v` | `shared(v)` |
| `⊤` | a cell the analysis cannot name: the result of `Js` or a `foreign` | `⊤` |

A closure is not a cell in slice 1 (no once closures, §1.2). It is a **closure value** that records
which `(local, path)` pairs its body reads (§5, *lambda*); the cells it holds are those pairs'
cells, looked up when needed, so a local function may name a local bound after it.

Every cell carries the type it was made at (the instruction's or local's solved type), which §6.1's
type filter reads.

### 4.3 Abstract values

An abstract value is a finite set of entries `(path, cell)`, sorted and deduplicated. Two conventions
from thesis §3.4 hold: an empty set means *provably no cell*, never "unknown"; and a symbolic cell
stands for everything under it — projecting `.f` from `(ε, param(x, q))` gives `(ε, param(x, q.f))`.
An entry also carries its **derivation** (§8.4): exact, or approximate with the instruction of the
call whose conservative aliasing introduced it.

Beside the values the walk keeps, per declaration, the set **Esc** of cells passed to `Js` or a
`foreign`, each with the point it escaped at (thesis §3.4: escape is not undone).

### 4.4 Crossing

Thesis §3.1, *Mode crossing*. A value whose type cannot contain a cell carries no entries. A type
**crosses** when it is a primitive (`Int`, `Float`, `Char`, `String`, `Bool`, `Order`, `⊤`, `⊥`), or a
record or tuple whose components cross, or a nominal type whose definition — read from BIR, for the
whole program, as `TypeFacts.zig` reads it — reaches no `List`, no function type and no `foreign
type` other than the primitives, and none of whose type parameters is instantiated at a type that
does not cross. A type variable, a function type, `List`, and every other `foreign type` (`Html`,
`Cmd`, `Js.Value`, …) do not cross. Reading imported definitions is what thesis Change 9 decides an
interface will publish (an opaque type's slots); slice 1 reads the BIR the session already holds, and
slice 2 replaces it with the published facts (§13.1).

---

## 5. Transfer rules

Thesis Table 3.2, as slice 1 computes them. `A(e)` is the abstract value of `e`.

| Form | `A(e)` | Uses recorded (§7.1) |
|---|---|---|
| local `x` | the current value of `x`; inside a lambda, for a local of an enclosing scope, `(ε, env(x, ε))` and the pair `(x, ε)` added to the lambda's captures | at the consumer |
| `r.f`, `t.i` | the projection; on a local `x`, inside a lambda, the capture is `(x, .f)` — captures are per path | at the consumer |
| top-level value `v` (no parameters) | `(ε, shared(v, ε))` unless its type crosses | — |
| top-level function, constructor, or literal of a crossing type | `∅` | — |
| list literal with no spread | `(ε, site(ι))` ∪ each element shifted by `[*]` | the elements, at ι |
| construction (§3.2) | `A(base)` ∪ each element shifted by `[*]` ∪ each later spread's `[*]` entries | every item, at ι; a demand on `A(base)@ε` |
| record, tuple, constructor application | each part shifted by its step | each part, at ι |
| `{ r | f = y }` | `A(r)` without its entries under `.f`, plus `A(y)` shifted by `.f`; a symbolic entry of `r` is split into one entry per field of `r`'s record type (an open record keeps it whole) | `r` at every path but `.f`; `y` |
| `case x of p → e` | per arm, the pattern's variables bound to projections of `A(x)`; a list pattern's elements to `[*]`, its spread to `A(x)` itself (a view, thesis §7, *Views*); the arms joined by union | `x`, at the `case` |
| `let x = e` | `x` holds `A(e)` | `e`, at the binding |
| `let (p) = e` | as a one-arm `case` | `e` |
| lambda, local function | a closure value; its body is walked as a frame of its own (§7.3) | none at creation |
| call | §6 | §6 |
| `e?` | `A(e)` with every entry moved to `⋆` (the unwrapped payload is somewhere in it) | `e` |
| markup | a conservative call over its value instructions (§6.1), result type `Html` | its values |
| interpolation, arithmetic, comparison | conservative calls; a crossing result has `∅` | their operands |

## 6. Calls in slice 1

### 6.1 The conservative call — exactly

A call `f a₁ … aₙ` (or a method call, `==`, `<`, a type dispatch, a markup root) whose callee is not
one of §6.2's rows:

1. **Every argument is read at the call.** An argument that is a variable or a field path of one is a
   use of that path at the call's point (§7.1). An argument that is a closure value, or holds one,
   is a use of every `(local, path)` the closure captured, at the call's point. Nothing is recorded as
   written: slice 1 has no summary that says a callee writes its argument.
2. **No argument escapes**, unless the callee is a `foreign` declaration whose rung is `impure` or
   `suspends` (`Js.get`, `Js.call`, `Js.write`, a platform's I/O): then every cell of every argument
   joins **Esc** at the call's point and the result is `(ε, ⊤)` when its type does not cross (thesis
   Table 3.2, the `foreign` row). A `foreign pure` (`List.length`, `Js.from`) promises it changes and
   keeps nothing, so it is a conservative call like any other: it can only return what it was given.
   This narrows the thesis's row, under which every `foreign` without ownership words escapes its
   arguments; those words are Change 5's and slice 2's, and without them `List.length xs` would make
   every list it measures unwritable.
3. **The result** is `∅` when its type crosses. Otherwise it is
   - `(ε, result(ι, ε))`, a fresh cell made by the call — what an ideal summary would call
     `fresh_1` — and
   - `(⋆, c)` for every cell `c` reachable from any argument (closures expanded) **whose type the
     result's type could hold**: the result's type, or a part of it, may be the same run-time object as
     a value of `c`'s type. Two types may be one object when they unify structurally, treating a type
     variable as anything; a function type, an `Html` and every `foreign type` but `List` may hold
     anything; and a nominal type of one constructor with one field may be its field (the release
     representation, thesis §3.1, A10). These entries are **approximate**, tagged with the call.

   So `List.length xs` holds nothing; `List.map xs String.fromInt : List String` is a fresh list that
   cannot be `xs : List Int`; `List.filter xs p` may be `xs` (thesis §3.8's identity promise falls out
   of the rule); and `List.map xs (λ_ → ys)` may hold `ys` at `⋆`.

Read the other way, slice 1 assumes of every callee what a summary would say of the worst pure
function of that type: it may return any argument it was given, and it makes its result. It does
**not** assume a callee might write an argument in place, keep it beyond its result, or return a
top-level or escaped list: those are facts only a summary can supply (§13.1), and §8.2 marks every
acceptance that rests on them.

*Amended 2026-10-12: from slice 2, this is the rule for a callee with no summary only; a callee with
one is applied by §16.4.*

### 6.2 The rows slice 1 has

*Amended 2026-10-12: slice 2 replaces these rows with §16.8's asserted primitive rows and the
summaries inferred for `update` and `swap`; constructions keep §3.2.*

| Callee | Row |
|---|---|
| `List.set`, `update`, `push`, `pop`, `swap`, `insertAt`, `removeAt`, `append` | a demand on argument 1; result `A(a₁)` ∪ the stored element (or callback's result, or `a₂`'s elements) at `[*]` |
| `List.cons` | a demand on argument 2; result `A(a₂)` ∪ `A(a₁)` at `[*]` |
| `List.copy` | result `(ε, site(ι))` ∪ `A(a₁)`'s `[*]` entries |
| a constructor | its arguments at `C#i` |
| a `foreign`, any `Js` value | §6.1 item 2 |

These are thesis §3.8's asserted rows, restricted to what slice 1 reads: which operand is written
and which cell is returned. Their exclusivity and callback clauses are slice 2's.

---

## 7. Liveness

Thesis §3.9 and §4.3.

### 7.1 Uses

A use is `(local, path, point)`. Uses are recorded at the **consuming instruction**, never at the
variable's textual position (thesis §3.3): an argument at its call, a field of a record literal at
the literal, a scrutinee at its `case`, a `let`'s value at the binding, the declaration's result at
the end of the body, a record update's base at the update with every path but the updated fields.
A field path `model.todos` is a use of `(model, .todos)` and not of `model.name` (thesis §3.9:
field-sensitive deadness).

### 7.2 Branches

Every use and every demand carries its **branch context**: the chain of `(case, arm)` it sits in. A use
is *after* a demand when its point is greater and the two are not in different arms of one `case`
(thesis §7, *Branches that keep the old value*). An `if` is a `case` on `Bool`.

### 7.3 Frames

A lambda or local function's body is a **frame**: its own uses, demands and pending operands, walked
at the closure's creation but not ordered with the enclosing body's points. A use inside it of an
enclosing local is not a use in the enclosing frame; it is a **capture**, and the closure holds that
local at that path for as long as the closure is live (thesis §4.3: "a captured path is live wherever
the closure value is live"). The closure is live through the holders of its value: a local bound to
it, a structure holding it, a pending argument, a call's result that may retain it (§6.1). So a use
of a variable holding a closure is recorded where the variable is consumed — at the call it is passed
to or called by — not where the lambda was written; a closure passed directly as a temporary is a use
of each of its captures at that call.

When two holders are first read at the same point, the report names the one with the lower local
index, then the path that sorts first as written, so the line does not depend on ids that other
declarations' walks assign.

### 7.4 Holders

At a demand on a cell `c`, its holders are:

- every local of the frame already bound, at every path `q` where its value — closures expanded —
  holds `c`;
- every **pending operand**: a value already evaluated whose consumer has not run yet — an earlier
  argument of an enclosing call, an earlier field of an enclosing record, an enclosing construction's
  earlier items (thesis Table 3.1, the pending row);
- every other operand of the demand itself (Disjoint).

A self tail call is a call (§1.2); slice 1 does not rebind parameters across a jump.

---

## 8. The check

### 8.1 Conditions

At a demand on the base `b` with cells `C = A(b)@ε` (with every `⋆` entry whose cell's type may be the
base's), each `c ∈ C` must satisfy, in this order:

1. **Known**: `c ≠ ⊤`.
2. **Unescaped**: `c` did not join Esc before the demand, and is not `shared`.
3. **Captured** (slice 1 only): `c` is not an `env` cell — the demand is not inside a closure on a
   list the closure captured.
4. **Disjoint**: no other operand of the demand holds `c`.
5. **Dead**: no pending operand holds `c`, and no local holder of `c` is used after the demand, at an
   overlapping path, in a compatible branch.

### 8.2 Verdicts

**Accepted**, with the provenance of `C`:

- `fresh` — every cell is a `site`;
- `call` — some cell is a call's `result`: accepted *if the callee's summary will say fresh*, which is
  slice 2's to decide;
- `param x` — some cell is a declaration's parameter: the function writes its parameter in place, and
  its *callers* must pass it unique (thesis §3.10: "discharged at its callers");
- `callback-param x` — some cell is a lambda's parameter: its caller is a library function whose row
  (`foldl`'s accumulator, `update`'s element) slice 2 supplies.

**Rejected**, with the first failing condition's cause.

### 8.3 Causes

| Cause | Condition | Verdict kind (thesis §8.4) |
|---|---|---|
| `unknown` | Known | approximate: "came from JavaScript" |
| `escaped` | Unescaped | approximate: "was given to JavaScript, which may keep it" |
| `top-level` | Unescaped | position: a top-level value's list (thesis §3.10) |
| `captured-edit` | Captured | approximate, slice 1's limit: whether the closure runs once is an ownership class (thesis §3.6), slice 2 |
| `disjoint` | Disjoint | exact |
| `held-operand` | Dead (pending) | exact |
| `later-use` | Dead: the base's own variable (any path of it) is read after | exact |
| `alias` | Dead: another local holds the cell and is read after | exact |
| `captured` | Dead: a closure holding the cell is used after | exact |
| `element` | Dead, where the base is an element (its path has `[*]`) and the only live holders hold it at `[*]` | approximate: "the checker does not tell the elements of `rows` apart" — exclusive contents are slice 2 |
| `call` | Dead, where every live holder holds the cell only through a conservative call's `⋆` entry; or a pending temporary holds it and its consumer is a call with no row | approximate: "`f` may return its argument", "`f` may read it" — summaries are slice 2 |

A Dead failure picks the holder whose use comes first, ties by the earlier binding; when an exact
holder and an approximate one both fail, the cause is the exact one.

### 8.4 What the causes say about slices to come

A rejection by `call` or `element` or `captured-edit` may disappear with summaries, exclusive
contents and ownership classes; one by `later-use`, `alias`, `captured`, `held-operand`, `disjoint`
or `top-level` would be rejected by the full checker too, unless a callee in the chain turns out not to
alias at all (an exact Dead failure through a `⋆` is reported `call`, not exact). An acceptance by
`call`, `param` or `callback-param` may become a rejection in slice 2: the callee may return a shared
list, or a caller may pass a list it reads afterwards. Research 74 reports each separately.

---

## 9. The report

### 9.1 `beni dump --stage=ownership <file|dir>`

Every module whose file is the argument, or is under the directory, in path order. Embedded core and
platform modules are included when the argument names their directory (`core`, `platforms/node`) and
never under `.`. For each module, every demand in source order:

```
module StoredTwice
  17:15 construction pair.a: rejected alias: pair.b holds it and is read at 18:25
  25:15 construction pair.a: accepted fresh
  32:14 construction todos: rejected alias: saved holds it and is read at 33:24
  demands 3: accepted 1 (fresh 1, call 0, param 0, callback-param 0), rejected 2
total 3: accepted 1 (fresh 1, call 0, param 0, callback-param 0), rejected 2
cause alias 2
```

- **Position** is the line and column (code points, `language.md` §12.7) of the demand's own token:
  a construction's base `…` (lowering stamps the outermost call of a spread literal with its first
  spread's `…`), the first `++` of a chain, a writer call's main token.
- **Operation** is `construction`, `++`, or the writer as `List.<name>`.
- **Base** is the base as written when it is a variable or top-level value with a field path
  (`model.todos`, `Toplevel.seed`), else `<call M.f>`, `<literal>`, `<expression>`.
- **Verdict** is §8.2's; a rejection adds its cause and a sentence naming the holder and the position
  of the use that keeps it live — the consuming instruction's position (§7.1). `(approx)` closes an
  approximate cause.
- **`demands`** closes each module; **`total`** closes the run with the same line summed, followed by
  one `cause` line per cause that occurred, in §8.3's order.

Nothing printed is an id; the output is a function of the program's text.

### 9.2 What it is for

Corpus goldens (`tests/corpus/ownership/`, `§11`), and the measurement of research 74. It is not a
diagnostic: no exit code depends on a rejection, and nothing reads the dump but people and tests
(thesis §12.3).

---

## 10. What does not change

- **Emitted bytes.** The pass runs only in `dump`. The checker hook allocates only when a dump keeps
  the stores (§2.3), so emitted JavaScript does not depend on the pass. One thing the slice adds does
  move bytes: `List.copy` (§3.4). Core's shadowing rule made three locals of `List.beni` named `copy`
  collide with it, and they were renamed `copied`; a development build prints local names, so the
  `List.mjs` of a program that reaches `viewPlain`, `claim` or `changed` changes by that name, and
  every `List.mjs.map` embeds the source. `--release` output is byte-identical, and so is every
  development module but `List.mjs`. The run hashes were re-recorded for it, in a commit of its own.
- **Interfaces and cache keys.** Nothing is published in slice 1; the interface version does not move.
- **Determinism** (CLAUDE.md rule 5, `fast-compiler.md` §10). The pass runs after the parallel check,
  on one thread, walking modules in path order and each declaration's body in evaluation order; ids
  (paths, cells, points) are assigned in that walk; everything printed is sorted by position or text.
  A test runs the dump at `--jobs=1` and `--jobs=8`, twice each, and compares the bytes.
- **Cost.** Linear in instructions times the width of abstract values (thesis §4.9), except the holder
  search, which is locals × entries per demand. Every corpus fixture must stay within the per-test
  instruction budget.

---

## 11. Testing

Rule 3: the corpus kind `tests/corpus/ownership/`, one fixture per rule, each `X.beni` with
`X.ownership`, run as `check` (clean) then `dump --stage=ownership`. A project directory takes
`_expected.ownership`. Each fixture's leading comment names the thesis section or T-program it pins.
The first set:

| Fixture | Pins | Expected |
|---|---|---|
| `Accumulator` | I1 (thesis §5.2), the tail-recursive `[ …acc, x ]` | accepted, `param` |
| `LaterRead` | thesis §3.3's second consequence | rejected, `later-use` |
| `RecordField` | I5, `{ model | items = List.push model.items x }` | accepted |
| `StoredTwice` | T17, T10's shape at top level | rejected, `alias` |
| `BranchKeeps` | thesis §7, *Branches that keep the old value* | rejected in the arm that keeps; accepted in the other |
| `ClosureCapture` | T7, and a demand on a capture (thesis §7, *Closures*) | rejected, `captured`; rejected, `captured-edit` |
| `Spreads` | Change 1: the first spread is the base, `++` chains, `[ …xs ]` and re-consing | per the thesis |
| `Copy` | Change 2, T33's fix | accepted after `List.copy` |
| `Toplevel` | T3, T21 | rejected, `top-level` |
| `Disjoint` | T1, thesis Table 3.1's pending row | rejected, `disjoint`, `held-operand` |
| `Conservative` | §6.1: the type filter, T52's shape | `call` rejected and accepted; `disjoint` |

---

## 12. What is shared with the write-set analysis

`write-sets.md` is the direct platform's whole-program analysis of *which model paths a message may
change*. The two meet where thesis §9.4 says they do — the entry protocol and the renderer — and
nowhere in slice 1.

**Shared:** the walk (BIR in evaluation order, `Writes.eval`'s order of operands); the path steps
`.f`, `.i`, `C#i`, `[*]` and the k-limit of 8 (`write-sets.md` §2.1–§2.2), which thesis §3.1 extends
with `◇` and opaque slots; the `appends` bit for `++`; `ext_value` resolution through provenance. The
code is not shared: `Writes.zig`'s terms are hash-consed identity facts (`Same`, `Fresh`, `Alt`) over
paths rooted at the model, and this pass's values are cell sets over paths rooted at locals; neither
domain is the other's (thesis §3.4: "the write-set analysis's abstract domain with its identity facts
replaced by cell sets").

**Not shared:** the write-set analysis is whole-program, per message key, untyped, and summarises by
inlining; this pass is per declaration, typed, and (from slice 2) summarises by interfaces. The write
set's "changed" means "not `===`"; this pass's "written" means "the array's contents change while its
identity stays". Thesis §9.4 (*Lemma: writes*) is what lets the renderer read both without the
write-set contract changing.

---

## 13. The plan: slices 2–5

### 13.1 Slice 2 — summaries in interfaces

*Superseded 2026-10-12 by §16, the slice-2 contract as built: classes and the library rows are narrower
there (§16.1, §16.8), and the interface block is specified but published only once the pass runs in
every build (§16.10). The plan below is kept as written.*

- **Summaries** (thesis §3.7, §4.4): `use` (R, A, E, W) per tracked parameter path, `res` per result
  path with provenances `πᵢ.q`, `fresh_k`, `esc_k`, `◇.q`, `shared`, `⊤`, and `xres`/`xreq`, `fun`. Read
  off after the walk; a demand on a parameter path adds W, and the call site discharges it.
- **Recursion** (§4.5): SCC order over the module's declarations (the checker's `Scc` already has it),
  optimistic fixpoint, validation round; self tail calls rebind parameters.
- **Classes and once closures** (§3.6, §4.7), retiring `captured-edit`.
- **Exclusive contents** (§3.11), retiring most of `element`.
- **The library's rows**: thesis §3.8's asserted rows for every `core/List` writer, `map`, `foldl`,
  `foldr`, `update`, `initialize`, the dictionary functions, and the `Js`/`foreign` boundary rows of
  Change 5 — each pinned by a corpus program (thesis §6.5, *The trusted surface*). Everything else in
  `core/` is inferred from its body.
- **Interfaces**: a summary block per value in the interface record, versioned with the rule set
  (thesis §8.5); the interface version moves; the interface firewall fires on a summary change, so a
  body edit that changes a summary is a signature edit (thesis §9.8). Crossing facts per exported type
  (Change 9's slots) are published with it.
- **Cache keys**: a module's key already covers its imports' interfaces; nothing else is needed
  (thesis §9.8). Interface churn is measured with the instrument of thesis §12.5.

### 13.2 Slice 3 — the external corpus and the thesis's evaluation

Thesis §12.4–§12.8: open-source Elm applications chosen by a stated rule, ported mechanically,
frozen by commit before any repair; the counts of thesis §12.5 per corpus; the idiom classifier
(I1–I7); hand classification (§12.6); the decision criteria of §12.8 applied to the external corpus
only. The dump gains the idiom label and the `summary`, `once` and `entry` lines of thesis §12.3.

### 13.3 Slice 4 — enforcement

A rejection becomes an `error` diagnostic — on `browser-direct` only, the one platform that writes in
place — with thesis Chapter 8's fixed shape: three places, a consequence, a machine-applicable
`List.copy` fix and an alternative, and the verdict line naming exact sharing or the limit (thesis
§8.3, Table 8.1). The stability policy of thesis §8.5 begins: every later release runs the previous
release's accepted corpus.

### 13.4 Slice 5 — in-place code on `browser-direct`

Thesis §9.5, Table 9.1: on `browser-direct`, an accepted demand is the in-place operation; the trie
goes; constructions lower from the base, left to right (Change 1). The release optimiser treats a
demand as a barrier (thesis §9.6, A5). Each accepted corpus program is run under value semantics and
in place with the stale-read sanitiser of thesis §12.2, and the verdicts and traces of the Lean model
(`proofs/ownership/`, the `Oracle`) are compared with the compiler's on the generated programs of
thesis §12.1 — the differential test against the oracle.

---

## 14. Open questions for the manager

1. **`List.copy` in core now.** Change 2 is decided, and slice 1 needs the function to exist for its
   fixture; it is added to `core/List.beni` with this slice. Is adding a public core function in a
   report-mode slice acceptable, or should it wait for slice 4?
2. **Optimistic call results.** §6.1 treats a call's result as fresh plus its arguments. A callee that
   returns a top-level or escaped list makes an acceptance wrong; slice 1 reports such acceptances as
   `call` (pending), not as accepted outright. Should the dump instead count them as unknown (`⊤`),
   which is the thesis's no-summary row for `foreign` only?
3. **Parameters.** A demand on a parameter is accepted locally and pending its callers. Slice 1 does
   not check the callers' side at all. Is that the right split for the first measurement, or should a
   caller-side check with a "writes its parameter" bit be pulled into slice 1?
4. **The base of `++` written as a call.** `Basics.append xs ys` written by name is a `++` by the
   dispatch table and is treated as a construction. The thesis speaks only of `++`; confirm.
5. **The report's home.** The dump prints per module; the measurement of research 74 sums totals over
   many invocations. Should a hidden `--ownership-totals` print only the totals line, for scripts?
6. **`foreign pure` as a conservative call.** §6.1 item 2 narrows the thesis's `foreign` row (escape
   by default) for slice 1 only. Slice 2's Change 5 words must replace it: this question stays open
   until every `foreign pure` that handles a cell in core and the platforms has its ownership words,
   and §6.1 is then amended to the thesis's row.

*Answered 2026-10-12: §15.*

---

## 15. The manager's decisions on §14 (2026-10-12)

1. **`List.copy` stays** in core: Change 2 is decided, and the function is a language feature, not a
   report-mode convenience.
2. **Call results come from callee summaries** (§16). Where a callee has none — a `foreign` without
   Change 5's ownership words, a `Js` operation, evidence received as a parameter, a function value whose
   class the checker cannot see — §6.1's conservative rule is kept, and the report line says so
   (`(no summary: M.f)`, §16.11).
3. **Caller-side checks of parameters are slice 2's** (§16.4): a call whose callee's summary writes a
   parameter path is a demand at the call.
4. **A named `Basics.append` call is a construction exactly like `++`**, consuming its base: §3.2 as
   written.
5. **A totals-only output for scripts**: the hidden `--ownership-totals` (§16.11).
6. **`foreign pure` as a plain call stays open** until Change 5's words exist: §6.1 item 2 is kept, and
   §16.14 flags what it costs in slice 2 (a `Js.pure` lambda's escapes do not reach the cells it
   captured).

---

## 16. Slice 2 — summaries (normative from 2026-10-12)

*Amends §1.2's table, §6, §8 and §9, and replaces §13.1 as the slice-2 contract. §1–§12 keep their
numbers and their slice-1 text; where slice 2 changes a rule, the rule here wins.*

### 16.1 What slice 2 builds

| Thesis piece | Slice 2 |
|---|---|
| Summaries and their read-off (§3.7, §4.4) | **built** (§16.2–§16.3), for every top-level value with parameters, and as a *class* for every lambda and local function of a body (§16.5) |
| Applying a summary at a call, and the caller's side of a written parameter (§3.10) | **built** (§16.4) |
| Recursion fixpoint (§4.5, §4.6) | **built** (§16.6): optimistic, joined, validated |
| The library's rows (§3.8, §6.5) | inferred from every beni body; **asserted only for primitives** (§16.8) |
| Width cap (§4.6, §4.9) | **built** (§16.7) |
| Folding of recursive types (§3.1) | **built** for constructor steps (§16.7); representatives' exclusivity is not |
| Ownership classes of function values (§3.6, §4.7) | built for function values whose origin the walk sees — a lambda written in the body, a local function, a top-level function, a function parameter passed on — and **not** carried through types: a function value read out of a structure or a call result has no class (§16.5) |
| Once closures (§3.6) | not built: `captured-edit` stays (§8.3) |
| Exclusive contents (§3.11) | not built: every `xres` is `no` and no `xreq` is `yes` (§16.2); an edit that needs it is rejected (`element`, `supply`) |
| Local-function groups (§3.6, *Local functions*) | not built: a local function that calls itself and writes a parameter is `pending` (§16.5) |
| Interfaces and cache keys (§4.10) | **specified** (§16.10); slice 2 publishes nothing, because the pass still runs only in `dump` |
| TEA entry protocol (§7) | not built: a writing function the runtime calls is `pending` (§16.5) |

### 16.2 The summary

For a declaration `f` with parameters π₁ … πₙ (thesis §3.7; numbered from 1 in print and here):

- **`use`**, a set of entries `(i, q, U)` with `U ⊆ {R, A, E, W}` for a tracked path `q` of πᵢ (§4.1's
  paths, cut at k). A path that no entry names, and that no entry is a prefix or an extension of, is
  `unused`. A demand on `π₁.todos` gives `(1, .todos, W)`; `{ model | todos = … }` gives `A` at each
  other tracked field of `model` and nothing at `.todos` (§5's split).
- **`res`**, a set of entries `(q′, p, d)`: the result may hold at its path `q′` a cell of provenance `p`
  (thesis §3.7's `Prov`), with a derivation `d`, exact or approximate (§16.4 item 7). The provenances:
  `πᵢ.q`; `fresh_k`, a cell made during the call that nothing else holds when it returns, numbered in the
  body's instruction order so that two result paths naming one `k` may be one cell; `esc_k`, the same but
  escaped; `shared(M.v)`, a cell of the top-level value `M.v`; `⊤`; **`cb_j`**, whatever the
  function-typed parameter πⱼ returned (thesis §4.7's `g.res`); and, in a lambda's class only, `◇x.q`, a
  cell the lambda captured from the local `x`.
- **`xres`** and **`xreq`** are part of the format (thesis §3.11) and constant in slice 2: no exclusive
  flag is built, so every `xres(q′)` is `no` and every `xreq(i, q)` is `no`. `xres = no` is the
  pessimistic end of a must fact; `xreq = no` is sound only because no acceptance in slice 2 rests on an
  exclusive container — an edit that would need one is rejected.
- **`fun(j)`**, for each function-typed parameter πⱼ:
  - `calls ∈ {0, ≤1, many}`: the direct calls of πⱼ in the body, summed over arms (conservative), `many`
    if one is in a recursive group, joined with what each callee it is passed on to says. Published;
    nothing reads it until once closures are built.
  - `supply`, a set of entries `(k, q, p, owned)`: at some call of πⱼ, its `k`th argument held at `q` a
    cell of provenance `p`; `owned` when that cell passed Known, Unescaped, Disjoint and Dead at that call
    (§16.4 item 4), so that πⱼ may write it. An entry whose `p` is `cb_j′` is owned only when, in
    addition, the actual for πⱼ′ *returns owned* (§16.4 item 5) — the one guard atom slice 2 has.
  - `need ∈ {nothing, owned}`: `owned` when the body writes in place a cell of provenance `cb_j`, so the
    actual must return owned.
  - `seen`: whether every use of πⱼ in the body is a direct call or a pass to a function-typed position
    of a callee with a summary that is itself `seen` there. When it is not — πⱼ is stored, returned,
    captured by a lambda, or handed to a callee with no summary — the body has lost sight of its calls,
    and an actual that writes a parameter is `pending` at the call (§16.5).
- **`limit`**: absent, or why the summary is the pessimistic one (§16.7): every parameter `RAEW` at ε,
  `res ε = ⊤`, every `fun(j)` not seen, with `calls many`, `need owned` and no supply.

The lattice is thesis §4.6's restricted to these fields: `use` bits by inclusion; `res` and `supply` entry
sets by inclusion (the lower order: a set is stored by its elements, and `⊤` among them means "any cell");
`owned ⊑ borrowed`; `calls` `0 ⊑ ≤1 ⊑ many`; `need` `nothing ⊑ owned`; `seen` `yes ⊑ no`; a `limit` above
everything. The join is pointwise.

### 16.3 Reading a summary off a body

After the walk (§5, §7) and the resolution of its demands (§8):

- **W** at `(i, q)` when some demand's cells — a construction's base, a writer's operand, a call-site
  demand (§16.4 item 3) — include the parameter cell `param(πᵢ, q)` (thesis §4.4: the local holders were
  discharged by Dead, the caller discharges the rest). A demand's verdict does not matter: a rejected one
  still writes.
- **E** when `param(πᵢ, q)` is in Esc at the end of the body (§4.3), which now includes the escapes a
  callee's summary reports (§16.4 item 4).
- **A** when the result's abstract value holds `param(πᵢ, q)` at any path.
- **R** when a use (§7.1) reads a local whose value holds `param(πᵢ, q)` at a path the use reads.
- `res` from the result's abstract value, closures expanded, by thesis §4.4's rule: a `site` or a
  callee's fresh result is `fresh_k`, or `esc_k` if it is in Esc, numbered in instruction order; the result
  of calling πⱼ is `cb_j`; an entry that came through an approximate step (a conservative call's `⋆`, an
  identity promise) stays approximate.
- `fun(j)` from the calls of πⱼ the walk met (§16.4 item 4), the supply entries' `owned` bits once their
  probes are resolved.

A lambda's class is read off its frame the same way, over its own parameters, with `◇x.q` for its captured
cells.

A top-level value with no parameters is read off the same way, and its `res` is what a reference to it holds:
each cell its definition makes is `shared(M.v)` at the path it is made at, and a cell of another value it
names is that value's. *What is shared is the cells the definition makes, and nothing else* (thesis §3.10):
`Dict.empty`, `Dict Leaf`, makes none, so a dictionary started from it is nobody's top-level list (T51). This
amends §4.2 and §5's top-level row, under which a value of a type that does not cross was one shared cell
whatever it held.

Derivation tags of supplies (§16.8's findings, §16.11): a supply is borrowed *exactly* when its probe failed
an exact condition (a parameter the body reads later, a top-level list), and *approximately* when it failed
only through an approximate step — a list's element, a level of a recursive value that folding merged
(§16.7; thesis §3.1's representatives), a cell from JavaScript.

### 16.4 Applying a summary at a call

A call `f a₁ … aₙ` — of a top-level value, of a method the dispatch table resolves to one, of a local whose
value holds closures or top-level functions, or of a function parameter — whose callee has a summary `S`:

1. **Uses.** An argument that is a variable path `x.p` is used at the call at `x.p.q` for each entry
   `(i, q, U ≠ ∅)` of `S.use`, and not at all when πᵢ is `unused`. A temporary argument's closures have
   their captures used, as in slice 1. This is what accepts thesis I5, TodoMVC's
   `changed { model | draft = "" } (model.todos ++ [ new ])`: `changed` never reads its first argument
   at `.todos`.
2. **Pending operands** (§7.4). An argument evaluated before a demand and waiting for this call holds the
   demanded cell only at paths the call touches: a pending argument that reaches the cell only at paths
   `S.use` leaves `unused` is no holder, and one the call touches is a `held-operand` holder — exact, where
   slice 1 said `call`.
3. **W: the caller's side of a written parameter.** For each entry `(i, q, U ∋ W)`, the cells of `aᵢ` at
   `q` (§8.1's base cells) are a **call-site demand** at the call's point, checked exactly as §8.1 checks a
   demand, with Disjoint against every other argument *and every other path of `aᵢ`* (thesis §3.10,
   "including Disjoint against the caller's other paths of the same argument"; T48). It is a line of the
   report (§16.11). When a cell is the caller's own parameter, the caller's summary gains W in turn.
   A W carries its derivation: it is *exact* when every step from the demand to the parameter is exact,
   and *approximate* when the demand's cells reached the parameter only through an approximate entry
   (a conservative call's `⋆`, an identity promise) — printed `w`. A call-site demand whose W is
   approximate and that fails an exact condition is reported as the `call` cause, approximate: the
   callee may not write at all.
4. **E** — for each `(i, q, U ∋ E)` the cells of `aᵢ` at `q`, closures expanded, join Esc at the call —
   and **callbacks**. For each function-typed parameter πⱼ, the actual `aⱼ` is resolved to the classes its
   value may have (a lambda's, a local function's, a top-level function's), to the caller's own function
   parameter, or to nothing (§16.5):
   - *the supply edge* (thesis §4.7): for every `(k, q, U ∋ W)` of the actual's class, every `S.supply`
     entry `(k, q′, p, owned)` with `q′` overlapping `q` must be owned; a borrowed one rejects the
     actual's demand, cause `supply`. An owned entry whose provenance is `πᵢ.q″` of `f` is a call-site
     demand on `aᵢ` at `q″`, as in item 3; one whose provenance is `cb_j′` asks that the actual for πⱼ′
     return owned (item 5);
   - an actual whose class escapes its `k`th parameter escapes the cells supplied there;
   - `S.fun(j).need = owned` asks that the actual return owned (cause `need`);
   - when the actual is the caller's own function parameter πⱼ″, the caller's `fun(j″)` gains `S.fun(j)`
     translated: its `calls`, its `need`, its `seen`, and its supply entries, each provenance instantiated
     through this call (item 6) and each `owned` kept only if the cells it now names pass the four
     conditions at this call — a *probe*, a demand that is resolved but not printed;
   - when `S.fun(j)` is not `seen`, an actual that writes a parameter is `pending` (§16.5).
5. **Returns owned** (thesis §3.7, *A callback's result is owned only when the rules show it*): the
   actual's class returns owned when every provenance of its `res` is some `fresh_k`, a parameter path
   `π_k.q` that `S` supplies owned at every overlapping entry and that the class does not escape, or `cb_j`
   itself (the guard being established), and no provenance appears at two distinct result paths. `◇`,
   `shared`, `esc_k`, `⊤` and a borrowed parameter are not owned (T46).
6. **The result** is `S.res` instantiated: `πᵢ.q` becomes `aᵢ`'s cells at `q`; `fresh_k` a fresh cell
   `result(ι, k)` of this call (a demand on it is accepted as `call`); `esc_k` the same cell, joined to Esc;
   `shared(M.v)` a cell of `M.v`; `⊤` the unknown cell; `cb_j` the actual's own `res` instantiated, its
   `π_k` replaced by `S.supply`'s provenances for `k` and its `◇x.q` by the captured local's cells — or,
   for the caller's own function parameter, the caller's `cb_j″` cell, or, for an actual with no class,
   §6.1's conservative result. A result whose type crosses is `∅`. A callee that hands a callback its own
   earlier result (a fold's accumulator) makes `cb_j` a least fixpoint, iterated from nothing; one that
   does not settle in four rounds adds `⊤`.
   **The type filter** (§6.1, thesis §3.8): an approximate entry at the result's ε whose provenance is
   an argument the result's type cannot be — by the argument's type, or by the cell's — is dropped, so
   `List.map xs String.fromInt` is never `xs`. A `List` and `core/List`'s `Builder` are one run-time
   object (`done` hands the one over as the other), so the filter never separates them.
7. **Derivations** (thesis §8.4): an instantiated entry is exact when its `res` path names one provenance;
   when it names two or more — the two outcomes of an identity promise, `List.filter`'s `{fresh, π₁}`,
   arms joined path-insensitively — every entry instantiated from it is approximate, tagged with the call,
   and a rejection through it is the `call` cause.

A call whose callee has no summary is §6.1's conservative call, unchanged (§15 decision 2).

### 16.5 Function values

A **class** is what a summary is for a function value: a lambda's or local function's, read off its frame at
its creation; a top-level function's, its summary. A function value is *checked* where the walk sees its
calls: as the callee of a call (its class applied as in §16.4, `◇x.q` instantiated from the captured local
`x`), or as the actual of a function-typed parameter of a callee whose `fun(j)` is `seen`. A lambda's
demands on its own parameters (`callback-param`) are decided there: accepted when every supply is owned, or
when every call is local and the call-site demands carry the obligation; rejected `supply` when a supply is
borrowed.

A function value whose class writes a parameter is **`pending`** wherever it leaves the walk's sight: stored
in a structure, returned, captured by a lambda, passed as evidence, passed to a callee whose `fun(j)` is not
`seen`. The report gets a `value` line there (§16.11), and the lambda's own demands on that parameter are
`pending` too. A TEA program's `update` goes there: the runtime calls it, and the entry protocol (thesis §7)
that would check those calls is not built. A writing function value passed to a callee with no summary —
a `foreign` without ownership words — keeps slice 1's rule: the lambda's demand on its parameter is
accepted `callback-param`, and the line says `(no summary: M.f)` (§15 decision 2).

A function value read out of a structure, out of a call's result or out of a parameter's field has no
class, and calling it is §6.1's conservative call, which assumes no write. That is sound only with the rule
above: every writing function that reached such a place was reported `pending` where it got there.

A local function that calls itself is walked once, its own calls conservative; if its class then writes a
parameter, its demands on that parameter are `pending` — the group fixpoint of thesis §3.6 is not built.

### 16.6 Recursion

Thesis §4.5–§4.6, as the Lean model does it (`proofs/ownership/`, `Checker.lean`'s `inferFunction`): a
module's top-level declarations are split into strongly connected groups by their references to each other
(`check/Scc.zig`'s `sccGroups`), dependencies first. A group of one declaration that does not name itself is
walked once. A recursive group starts from the bottom summary for every member (every path `unused`, `res`
empty, every `fun` seen with no supply, `need nothing`); each round walks every member against the current
assumptions and **joins** what it reads off into them, `xᵢ₊₁ = xᵢ ⊔ F(xᵢ)`, until nothing changes.
Termination comes from the join, not from monotonicity: the owned bit of a supply is not monotone in the
callback's class (thesis §4.6, as revised in round 5), but each round that changes anything adds a fact to a
finite lattice. A cap of 32 rounds is a backstop a correct lattice does not reach; reaching it gives every
member the pessimistic summary with `limit rounds` (§16.7). **Validation**: the members are walked once more
against the final assumptions, what that walk reads off must be below them, and that walk is the one whose
demands the report prints.

A self tail call is a call through the group's summary like any other recursive call; rebinding the
parameters at the jump (thesis §3.9) changes no verdict a summary gives and is not built.

Within a group being solved, a call of a member makes **one** fresh cell per call however many
`fresh_k` the member's assumption names: the numbering of §16.2 counts the cells a body's
instructions make, and a recursive call's fresh results would otherwise be numbered anew in every
round, so the chain would never settle. Merging them is sound (two cells taken for one only adds
aliasing) and loses nothing the group's callers see, since a caller outside the group instantiates the
final summary.

### 16.7 The width cap

A summary's width is the number of distinct paths in its largest component (`use`'s parameter paths,
`res`'s result paths, `supply`'s `(j, k, q)`) — thesis §4.9's *w*. Above **64**, thesis §4.9's "say 64", a
type with too many tracked paths "is tracked as a whole": the summary is **coarsened** — the parameter with
the most paths is tracked whole, its bits joined at ε (a write there approximate), until the uses fit, and
the result's and the supplies' paths are cut shallower, the rest of each replaced by `⋆` and made
approximate, until they fit — and its line says `coarse`. Coarsening only merges places, so it adds holders
and never removes one. A summary still too wide (a coarsened one cannot shrink further) is the pessimistic
one of §16.2 with `limit width`, and a rejection it causes is reported with the `limit` cause, approximate —
a call-site demand it makes, and a `⊤` it returns, carry the mark however far they travel (`⊤limit` in a
summary line). A recursive group that reaches the round cap gets `limit rounds`.

The fresh numbers do not count toward the width: as thesis §4.6 bounds them (`k ≤ |Q|`), a number only says
which result paths may hold one new cell, so the read-off of §16.3 gives two new cells that appear at the
same result paths the same number — a TEA `update` that builds its model from forty literals has a handful.

**Recursive types are folded** (thesis §3.1, which slice 1 did not need, §1.2): a constructor step into a
value of a type the path has already entered goes on from where the path first entered that type, so
`t#Node.3#Node.1` is `t#Node.1`, and a summary over a `Dict` or a tree names a few paths instead of every
level to the cut. Folding only merges places, so it adds aliasing and never removes a holder; a demand
on a folded path is checked against every level it stands for. Without it every `Dict` function's summary
exceeded the cap. The guard atoms are bounded by the function-typed parameters: a summary whose `owned` bits
would depend on more than **8** `returns owned` atoms treats the entries past the eighth as borrowed. A cap
never accepts: each turns facts pessimistic.

### 16.8 The library

Thesis §6.5 as revised in round 5 keeps three kinds of trust apart, and slice 2 follows it:

- **Inferred** — every beni body, in `core/` and the platforms as in application code: the folds, `map` and
  its family, `initialize`, `update`, `swap`, `filter`, `slice`, `close`, `Dict`, `Set`, `Debug.log`. Their
  rows in thesis §3.8 and §4.7 are *derived contracts*, and slice 2 asserts none of them.
- **Asserted primitive rows** — `core/List`'s functions whose bodies are `Js` or `foreign` and handle a
  list's array: what connects beni's semantics to JavaScript. Each row replaces the body's summary, is pinned
  by a fixture under `tests/corpus/ownership/`, and is a correctness bug in privileged code if wrong.
- **Slice 1's rule** for every other `foreign` and `Js` operation (§6.1 item 2; §15 decision 6).

| Function | Row | Thesis |
|---|---|---|
| `cons x xs` | π₁ `A`; π₂ `RAW`; `res ε = π₂`, `[*] = π₂[*], π₁` | §3.8, the writers |
| `append xs ys` | π₁ `RAW`; π₂ `R`, π₂`[*]` `A`; `res ε = π₁`, `[*] = π₁[*], π₂[*]` | §3.8, with its decided change: `[] ++ ys` is the base, not `ys` |
| `set xs i v`, `insertAt xs i v` | π₁ `RAW`; π₃ `A`; `res ε = π₁`, `[*] = π₁[*], π₃` | §3.8 |
| `push xs v` | π₁ `RAW`; π₂ `A`; `res ε = π₁`, `[*] = π₁[*], π₂` | §3.8 |
| `pop xs`, `removeAt xs i` | π₁ `RAW`; `res ε = π₁`, `[*] = π₁[*]` | §3.8 |
| `copy xs` | π₁ `R`, π₁`[*]` `A`; `res ε = fresh₁`, `[*] = π₁[*]` | §3.8, Change 2 |
| `length xs` | π₁ `R` | §3.8 |
| `at xs i`, `unsafeGet xs i` | π₁ `R`, π₁`[*]` `A`; `res ε = π₁[*]` | §3.8's `at`; §6.5, the element read |
| `sliceOf xs a b` | π₁ `R`, π₁`[*]` `A`; `res ε = fresh₁`, `[*] = π₁[*]` | §6.5, a fresh copy of a range |
| `view xs k` | π₁ `RA`; `res ε = π₁, fresh₁`, `[*] = π₁[*]` | §6.5, the view representation (thesis §7, *Views*): a view is its base's array |
| `base xs` | π₁ `RA`; `res ε = π₁`, `[*] = π₁[*]` | §6.5: the array a list is a suffix of — its own, a view's, or the plain copy its trie keeps |
| `offset xs` | π₁ `R` | §6.5 |
| `builder n` | `res ε = fresh₁` | §6.5, the builder |
| `put b i x` | π₁ `RAW`; π₃ `A`; `res ε = π₁`, `[*] = π₁[*], π₃` | §6.5, the builder's fill: a write in place, so a demand on the builder |
| `done b n` | π₁ `RAW`; `res ε = π₁`, `[*] = π₁[*]` | §6.5, the hand-over, which sets the array's length |
| `identical x y` | nothing | §6.5, the identity primitives: compares references, dereferences neither |
| `kept same xs ys` | π₂ `A`, π₃ `A`; `res ε = π₂, π₃`, `[*] = π₂[*], π₃[*]` | §6.5, `map`'s return of its input |

`swap`, `update`, `close`, `slice`, `take`, `drop`, `map` and the rest are inferred over these. Two
consequences are findings, not rows:

- **A destructive read is not inferable.** `update`'s body is `set xs i (func (unsafeGet xs i))`: the element
  is handed to `func` while `xs` waits for `set`, so the inferred supply is *borrowed*; `map`'s and the folds'
  loops hand out `at a i` while `a` is read by the next iteration, so theirs is borrowed too. The thesis
  asserts these rows (§3.8, §3.11), and they need exclusive contents as well, which slice 2 does not build.
  So a callback that edits its element — T40's `List.update rows i (λr → { r | tags = … })`, T42's edit by
  id through `map` — is rejected `supply` in slice 2, an approximate limit.
- **T59 is rejected** by the same edge, and its round-5 fix holds by construction: no asserted row takes a
  callback, so none can hand out a callback's result as exclusive, and every inferred `res` that holds a
  callback's result says `cb_j`, never `fresh`, so a `[ cell, cell ]` initializer's results are never
  supplied owned. T59's accepted variant, two literals, is rejected too — the price of not building
  exclusive contents.

### 16.9 Order of computation

**In a build** (from the slice that runs the pass there): module m's summaries are computed by the worker that
checked m, right after its check, from m's BIR and solved types and its imports' summary blocks, which the DAG
has already produced (`fast-compiler.md` §10). A summary is a function of m's source and its imports'
interfaces, so per-module parallelism cannot change one.

**In the dump** (slice 2): summaries are computed on demand on one thread. A call of a declaration whose summary
is missing first computes the group holding it, recursively — imports before importers, since the module graph
is acyclic, and groups in dependency order within a module. The result is the same function of the program as
the per-module order, because a group's summary depends only on its bodies and its dependencies' summaries.
Every line is printed in source order and every fact in text order, never by an id the walk assigned (§10).

A summary is read off solved types, which only a module the run checks keeps (§2.3), so the dump checks every
module itself: it reads nothing from the checked core embedded in the binary (`fast-compiler.md` §8, *The
checked core, embedded*), and core is checked in the dump's process. `check` and `build` keep reading it.

### 16.10 Interfaces and cache keys

*Specified now; published from the slice that runs the pass in every build. Slice 2 runs only in `dump`, so
publishing would change every interface and every `check/good` golden for nothing that reads them.*

- **The summary block.** The interface record of each `pub` value gains a block after its effect facts (thesis
  §4.10): the `use`, `res`, `fun` and `limit` of §16.2, paths written as steps — a field by name, a tuple index,
  a constructor by its index in its type, `[*]`, `◇`, `⋆` — and provenances by parameter index, fresh or esc
  number, shared value by module and name, `cb_j` by parameter index. The block names no id of the session
  that produced it, and no crossing path.
- **Change 9's slots.** For each exported opaque type the interface publishes its slots — the tracked paths
  inside its definition, numbered in the definition's order — and a summary over the type names `⟨T⟩.k` instead
  of the steps, so an importer checks Disjoint between two slots (T48) without seeing the definition. A type
  with no slot crosses. Slice 2 still reads imported definitions from the session's BIR, as slice 1 did (§4.4).
- **Version and hash.** The block is versioned with the rule set (thesis §8.5) and hashed with the interface.
  A body edit that changes a summary changes the interface hash and re-checks the importers: the interface
  firewall treats it as a signature edit (thesis §4.10). The cache key needs nothing new — a module's key
  already covers its own source and its imports' interfaces, and a summary is a function of exactly those.
  The interface version moves when the block is first written.

### 16.11 The report

Each module's demand lines (§9.1) gain:

- **call-site demands** (§16.4 item 3): operation `call M.f` — or `List.<writer>` for the named writers, as
  before — base the argument as written, with the parameter path when it is not ε (`p#.a`);
- **value lines** (§16.5): operation `value`, base the function's name or `<lambda>`, for a writing function
  value where it is checked or leaves the walk's sight;
- a **`pending`** verdict beside accepted and rejected: `pending value: <why>`, an obligation slice 2 does not
  discharge;
- the causes **`supply`** (a callback writes what its caller supplies borrowed), **`need`** (a callback's
  result is edited and the callback may return a list it does not own) and **`limit`** (§16.7), after `call` in
  §8.3's order — `supply` approximate when the borrowed bit comes from a limit (an element: §16.8), `need`
  exact, `limit` approximate;
- the summary that decided it, in parentheses: `(Main.addOne writes π1)`, `(List.update supplies π1[*]
  borrowed)`, `(no summary: Js.pure)`.

After a module's demand lines, a **summary line** for each top-level value with parameters, in source order:
`summary f: <facts>` — each parameter path's bits (`π2.todos RAW`, `w` for an approximate write), the result
grouped by path (`res π1 fresh1, [*] π1[*]`, an approximate provenance prefixed `~`), each function parameter
(`π3 calls many, need owned, unseen, supply 2 π2 owned`), `limit <why>`, and `(asserted)` for §16.8's rows —
omitting what is empty, `unused` when nothing is left. A constructor step prints as `#Name.i`. The `demands`
and `total` lines count `pending` beside accepted and rejected, and say how many acceptances rest on no
summary (`assumed`): `demands 6: accepted 4 (fresh 1, call 0, param 2, callback-param 1; assumed 0),
pending 1, rejected 1`.

A writing top-level function gets one `value` line in a declaration, where it first leaves the walk's sight.

**`--ownership-totals`**, hidden like the stage, prints only the `total` and `cause` lines.

### 16.12 What does not change

The pass still runs only under `dump --stage=ownership`: emitted JavaScript, interfaces, cache keys, run
hashes, and the work `check` and `build` do are byte for byte slice 1's. The one change outside the pass is
that the ownership dump checks core itself (§16.9). The determinism test runs the slice-2 dump at `--jobs=1`
and `--jobs=8`.

### 16.13 Testing

New fixtures in `tests/corpus/ownership/`, each citing its thesis section or T-number:

| Fixture | Pins | Expected |
|---|---|---|
| `ReturnsArg` | §16.4 item 6; T12's shape | a helper that returns its argument: editing the result while the argument is read later is rejected, exact |
| `ReturnsFresh` | §16.3, `fresh_k` | a helper that builds its result: the edit is accepted, `call` |
| `CallerSide` | §16.4 item 3; thesis §3.10 | a helper that writes its parameter: rejected at a caller that reads the argument later, accepted at one that does not |
| `Callbacks` | §16.4 items 4–5; T15, T46, I2 | `foldl`'s accumulator supplied owned (accepted); a callback that may return a top-level list (rejected); a callback that consumes its element (rejected `supply`); one that reads it (accepted) |
| `T59` | T59, §16.8 | the `[ cell, cell ]` initializer edited through `update`: rejected |
| `Recursion` | §16.6; T12 | a building loop that consumes its argument, and mutual recursion |
| `CrossModule` (project) | §16.9–§16.10 | a summary used across a module boundary |
| `OpaqueSlots` (project) | T48, Change 9 | a write to one slot of an opaque value whose two slots hold one list: rejected `disjoint`; distinct lists accepted |
| `Changed` | I5, thesis §5.2 | TodoMVC's `changed`: accepted |
| `Differential` | Table 6.2 against `proofs/ownership/`'s fixtures | T1, T2, T3, T10, T14, T33, T52 agree with the Lean model; T40, T42 and T57 (the distinct variants) disagree, by §16.8's finding |

The slice-1 fixtures' goldens move where slice 2 decides what slice 1 left pending.

### 16.14 Open questions

1. **`foreign pure` and `Js.pure`** (§15 decision 6). A `Js.pure` lambda that hands a captured list to
   `Js.call` escapes it in the lambda's frame, and slice 2 does not carry that escape to the captured cell,
   because `Js.pure` has no summary and §6.1 item 2 calls it with no escape. Change 5's words, or an asserted
   row for `Js.pure` (`calls ≤1`, its callback's escapes and result passed through), would close it.
2. **The derived rows.** Whether `update`, `map`, `indexedMap`, `filterMap` and the folds should get asserted
   destructive-read rows (thesis §3.8, §3.11) together with exclusive contents, which would turn slice 2's
   `supply` rejections of element edits into acceptances; or whether the analysis should learn to tell one
   iteration's element from the next, so that they are derived.
3. **Local-function groups and once closures** (thesis §3.6): the `pending` and `captured-edit` counts are what
   they would recover.

*Answered 2026-10-12: §17.*

---

## 17. The manager's decisions on §16.14 (2026-10-12)

1. **Element ownership in `update`, `map`, the folds and `Dict.update`** (§16.14 question 2). No row is
   asserted for any of them. Following the round-5 review (`reviews/review-5.md` item 1.4) and the Lean
   model (`proofs/ownership/Ownership/Library.lean`, whose `map`, `initialize`, `foldl` and `update` are
   ordinary declarations over `traverse`, `focus`, `builder` and `close`), the destructive read becomes a
   **primitive** with an asserted row — a *traversal* primitive and a *focus* primitive — and `core/List`'s
   `map`, `indexedMap`, `filterMap`, `update`, `foldl`, `foldr` and `initialize` are written over them, so
   that their summaries are inferred. Exclusive contents (thesis §3.11) are built with them, with the
   round-5 condition that a callback's fresh result be exclusive inside (T59). The rewrite changes no
   behaviour; a slowdown is a finding. §18.
2. **`Js.pure` lambdas capturing lists** (§16.14 question 1): a function value handed to a `foreign` with
   no summary escapes what it captured, and the report line says so, until Change 5's words exist. §18.6.
3. **Local-function groups and once closures** (§16.14 question 3) are built. §18.7, §18.8.
4. **A function parameter captured by a lambda** stays in sight: its calls inside the lambda are calls of
   the declaration's parameter, made wherever the lambda runs. §18.9.
5. **Cost**: the pass is profiled and brought toward 20 % of a check without changing a verdict. §18.11.

---

## 18. Slice 3a — destructive reads, exclusive contents, closures (normative from 2026-10-12)

*Amends §1.2's and §16.1's tables, §8.2–§8.3, §16.2, §16.4, §16.5, §16.8 and §16.11. Sections 1–16 keep their
numbers and text; where this section changes a rule, it wins. Research 77 measures it.*

### 18.1 What slice 3a builds

| Thesis piece | Slice 3a |
|---|---|
| Exclusive contents (§3.11) | **built** (§18.2–§18.4): conditions 1 and 2 as a condition on each list cell; condition 3 at the write; `xres` and `xreq` published |
| The destructive read (§3.8, §3.11; review 5 item 1.4) | **built** as two asserted primitives, `traverseAt` and `focus` (§18.5); `map`, `indexedMap`, `filterMap`, `update`, `foldl`, `foldr` and `initialize` inferred over them |
| The split of `[ x, …rest ]` (§3.11) | **built** (§18.4 item 4) |
| The exempt identity comparison (§6.2, A11) | **built**, at `kept` alone (§18.5) |
| `Js.pure` and function values handed to JavaScript | conservative: what they captured escapes, and the line says so (§18.6) |
| Local-function groups (§3.6, *Local functions*) | **built** (§18.7) |
| Once closures (§3.6, *Affinity*) | **built** (§18.8) |
| Capture paths of function parameters (§3.6, §4.7) | **built** (§18.9) |
| `Dict.update`'s owned value | not built: a dictionary needs a focus of its own (§18.13) |
| TEA entry protocol (§7) | not built: slice 3b |

### 18.2 Exclusive contents as a condition

Thesis §3.11's three conditions are split by when they can be known. **Conditions 1 and 2** — no cell is
reachable from two positions of the list, and within one position distinct paths hold distinct cells,
recursively — are facts about how a list was *built*, and the walk computes them where it is built.
**Condition 3** — no cell reachable through the container has a live holder outside it — is a liveness
fact, and the walk checks it where it matters: at the write, as the call-site demand on the written path
already does (§16.4 item 3). A list whose outside holder is read only *before* the edit is exclusive here,
which the thesis's construction-time check refuses; the edit is no less safe, since a dead holder observes
nothing.

The fact is a **condition**, because most lists a function sees arrived from outside. Every cell has one,
which a write in place only ever lowers, so a table of them per walk is sound at every point:

- it *holds*, *fails exactly* (one cell at two positions, or at two paths of one value, as the text shows:
  `[ cell, cell ]`, `{ a = xs, b = xs }`), or *fails approximately* (a value from JavaScript, a conservative
  call's result, an append of a list that lives on, two places the analysis cannot tell apart);
- when it holds, it rests on **atoms**, each about cells that arrived from outside the body — parameters,
  captures, callback results: `excl c` (`c` is deeply exclusive) and `sep c d` (`c` and `d` share no cell;
  `sep c c` of a callback's result: *two calls' results share none*, the thesis's "fresh across calls").

A cell the body makes (a literal, a construction's fresh base, a callee's `fresh_k`) shares no cell with
one that arrived from outside, except with a callback's result when it was handed to that call; so atoms
name only arrivals, and a summary can state them over its parameters.

| Where | The list cell's condition |
|---|---|
| a list literal `[ v₁, …, vₙ ]` | every item's deep condition, and `sep` between every two items |
| a construction (§3.2) | the base's, lowered by each item stored: its deep condition, `sep` against the base's elements and the other items; a later spread stored element by element when it is a temporary, and *failing approximately* when it is a variable (thesis §3.8: an append copies in a list that lives on) |
| a call through a summary | its `res` entry's condition (§18.3), instantiated |
| a conservative call, `⊤`, `List.copy`, `List.append` by name | fails approximately |

A value's **deep condition** is the conjunction of its cells' conditions, closures expanded, and of `sep`
between the cells at every two of its paths neither of which is a prefix of the other.

### 18.3 The summary's new facts

§16.2's `xres` and `xreq`, constant in slice 2, become real:

- **`xres`**: each `res` entry carries its cell's condition, atoms written over the summary's parameters —
  `excl πᵢ.q`, `excl cb_j`, `sep πᵢ.p πⱼ.q`, `sep cb_j cb_j`, in a class `excl ◇x`, and `focus`'s
  `keep cb_j πᵢ` (§18.5). A parameter's own `excl` is left out: instantiation supplies it.
- **`xreq`**: the atoms the body *relied on* (§18.4), which every caller discharges.
- **each `supply` entry** carries the condition of what it supplies, and is **taken** when it is an element
  handed out by a destructive read (§18.5).

A summary line prints a condition after its provenance — `π1{excl π2, sep π1[*] π2}`, `{lost}` when it
fails approximately, `{shared}` exactly — `taken` on a destructive supply, and `xreq …` after the function
parameters. An `excl` that another implies (`excl π1[*]` beside `excl π1`) is not printed.

### 18.4 Relying on a condition

A condition is **relied on** where a write is safe only if the contents are exclusive:

1. a callback writes what a destructive supply gives it: the container must be exclusive, so that writing
   one position is not seen at another;
2. a callback's class has `xreq`: what the callee supplies it there;
3. a callee has `xreq`: the arguments, instantiated;
4. **the split** (thesis §3.11): `[ x, …rest ]` (or `[ …init, x ]`) binds `x` to its position *taken* from
   the scrutinee — a cell that the pattern's other bindings do not hold, and every other holder of the
   scrutinee does. A write of `x` relies on the scrutinee being exclusive.

To rely on a condition that fails is a rejection, cause **`exclusive`** ("the elements of `rows` may share
one list"), exact when the condition failed exactly, and decided after `Dead`, so that a live holder is
named first. To rely on one that holds records its atoms: on the declaration's own parameters and callback
results, as `xreq` of its summary; on a lambda's parameters or captures, as `xreq` of its class, which the
lambda's caller discharges against what it supplies or what the lambda captured. Instantiating an atom at a
call (§16.4) evaluates it in the caller: `excl πᵢ.q` becomes the argument's deep condition at `q`, `sep`
the condition that two arguments share no cell, and an atom about a callback the condition of the actual
class's result — `sep cb_j cb_j` holds when every provenance of it is `fresh_k`, or the element the callee
hands it destructively (each call gets another position).

A callee's `xreq` that fails at a call is reported on the call-site demand of the argument it names; an
`xreq` is recorded only beside a write of that parameter, so the line exists.

### 18.5 The two primitives, and the exempt comparison

Thesis §6.5 (round 5) keeps *primitive contracts* — what connects beni's semantics to JavaScript — apart from
*derived contracts*, and review 5 item 1.4 names the destructive read as the missing primitive: "a traversal
primitive establishes that successive elements occupy separated positions; a focus operation temporarily
removes one position from the container's usable contents". `core/List` gains both, not `pub`, and asserts
their rows (§16.8's table gains them); everything built on them is inferred.

**`traverseAt : List a, Int → a`** — the traversal primitive. It reads element `i` of an array `base`
returned, and lowers to `a[i]` exactly as `at` does. Its row: π₁ `R`, π₁`[*]` `A`; `res ε = π₁[*]`,
*taken*. A **taken cell** (`taken(B, ι)`: the element cell `B`, taken at the instruction `ι`) is held by
no holder of its container, within the body that takes it — the container's later reads are of other
positions, by the obligation below; every other rule sees through it to `B` (escaped, shared or unknown
when `B` is). Read off, a supply of a taken cell is **taken**; a result never is. *The obligation*, which
the trusted surface lists and every use meets: **the body that calls `traverseAt a i` reads `a` only
through it, once per index, at an index that moves one way.** `foldlFrom`, `foldrFrom` (downward),
`mapHelp`, `indexedMapHelp` and `filterMapHelp` are such loops; no other function calls it.

**`focus : List a, Int, (a → a) → List a`** — the focus primitive: `set xs i (func (unsafeGet xs i))` in
range, else `xs`. Its row: π₁ `RAW`, π₁`[*]` `A`; π₃ `calls ≤1`, supply 1 `π₁[*]` *owned, taken*, condition
`excl π₁`; `res ε = π₁` with condition `keep cb₃ π₁`, `[*] = π₁[*], cb₃`. `keep` (the thesis's "keeps
shape") holds when every provenance of the callback's result at a path `q` is `fresh_k` or the element's
own `π₁.q`, and the result is exclusive inside.

**At a call** whose callee supplies a taken element of its argument `πᵢ.q` — directly or through a supply it
passes on — a callback that writes its parameter at `p` makes, as for any owned supply (§16.4 item 4), a
call-site demand on the argument at `q.p`, and relies on the argument's condition at `q` (§18.4 item 1).

**The exempt comparison** (thesis §6.2, A11): `map` and `indexedMap` return their input itself when every
result is the element it was given. Their loops now answer the array `a` they traversed in that case, and
`map` answers `kept (identical r a) xs r`. `kept`'s row marks its second parameter **`K`**: aliased by the
result, never read, and no use at the call. It is the one exempt site — it chooses between two results that
hold the same elements at every position when it chooses the first; no other row has `K`, and `K` is never
inferred.

**The rewrite.** `foldl`, `foldr`, `map`, `indexedMap` and `filterMap` read their element with `traverseAt`
where they read it with `at`; `mapHelp` and `indexedMapHelp` no longer take `xs`; `update` is `focus`;
`initialize` is unchanged, its builder loop already inferable. Every loop keeps its own call site of the
callback (a shared higher-order `traverse` was measured first and costs `foldl` 65 % where callbacks are many,
§18.13).

### 18.6 Function values handed to JavaScript

A function value passed to a `foreign` with no summary (`Js.pure`, `Js.method`, …) escapes every cell it
captured, at the call: the foreign may keep it and call it later (§15 decision 6). A parameter escaped only
so is `J` in a summary — `E` for every other rule — and a rejection through either says it is this rule:
"a function value that `Debug.toString` hands to JavaScript captured it, and JavaScript is taken to keep it".

### 18.7 Local-function groups

A block's local functions are one group (thesis §3.6, *Local functions*): their closures exist, each with the
bottom class, from the block's entry. When a member names a member, the group is solved as a recursive
top-level group is (§16.6): each round walks every member against the current classes and joins what it
reads off; a round's demands, uses, supplies and conditions are discarded before the next, and the round
that changes nothing is the walk the report keeps. 32 rounds is the backstop, with pessimistic classes.
§16.5's `pending` for a local function that calls itself is withdrawn.

### 18.8 Once closures

A lambda or local function whose body writes a cell it captured is **once** (thesis §3.6, *Affinity*):

- **its creation** is a demand on the captures it writes, in the enclosing body, where the lambda is written
  — for a local function, at each call, since its captures are read when it runs; the closure's own uses of
  what it captured are no later use;
- **each call of it** is a demand on the closure's own cell, so a holder of it read after a call — a second
  call — fails `Dead`; handing it to a callee is accepted only where the callee's `fun(j)` is `seen` with
  `calls ≤1`; a once local function that calls itself fails; anywhere else out of sight is `pending`, and a
  callee with no summary is a rejection.

The write inside it is then **accepted `once`** (a new acceptance kind) or rejected with the creation
demand's own cause, or the cause **`once`** ("it is handed to `List.map`, which may call it more than
once"). `captured-edit` is left for a write of a capture the walk cannot place in a closure.

### 18.9 Capture paths of function parameters

A call of the declaration's function parameter `πⱼ` inside a lambda is recorded with the lambda, its
arguments probed there, in the lambda's vocabulary. Where the lambda is checked — handed to a callee whose
`fun(k)` is `seen`, or called — the call becomes a call of `πⱼ` in the declaration: `fun(j).calls` gains the
callee's calls of the lambda, and each argument is a supply of `πⱼ` whose provenance is what the callee
supplies the lambda (or the call passes), owned when the lambda's probe, the callee's supply and a probe at
the call all pass. A lambda's class names such a result `cb_j` of the enclosing declaration. A lambda that
leaves the walk's sight takes `πⱼ` out of sight with it. So `Set.foldl`'s callback, handed to `Dict.foldl`
inside a lambda, is supplied `Dict.foldl`'s accumulator owned.

### 18.10 The report

Acceptance kinds (§8.2) gain **`once`**, counted after `callback-param`; causes (§8.3) gain **`exclusive`**
and **`once`**, after `limit`. When the base's own variable holds the written cell and is read after, the
cause is `later-use` even where the base is an element; a holder found through a split element is `alias`,
exact.

### 18.11 Cost

The pass still runs only in `dump`. Work that changes no verdict — checked by dumping core, the platforms,
Conduit, `bench/corpus` and the corpus with the binary before and after each step — brought it back to
slice 2's cost while it does slice 3a's work: an index of Esc by cell, columns for the conditions and the
path arithmetic, `tracked` remembered per type variable, uses indexed by local, the empty summary of a
declaration whose parameters and result all cross read without a walk, and no verdict or line text built
in a walk whose lines nobody prints. Research 77 §6 gives the figures; the 20 % target is reached on the
100 000-line program and not on the smaller ones; on Conduit two thirds of the time is summarising the
library the program reaches, again, in every dump.

### 18.12 Testing

New fixtures in `tests/corpus/ownership/`:

| Fixture | Pins | Expected |
|---|---|---|
| `Differential` (updated) | T40, T42, T57, T59 against the Lean model | the parameter forms accepted with `xreq`; distinct callers accepted, repeated ones rejected `exclusive` — the model's verdicts |
| `T59` (updated) | review 5 item 1.1, `initialize` and `map` | `[ cell, cell ]` rejected `exclusive`; two literals accepted |
| `ElementEdits` | §18.5; the slice-2 flips (`NestedFor`) | an element edit through `update` and `map` accepted when the list is unique, exclusive and dead; rejected when it is read after, not exclusive, or held outside |
| `Split` | §18.4 item 4; thesis `bumpHead` | accepted on exclusive contents; rejected when they share and when the scrutinee is read after |
| `LocalGroups` | §18.7 | recursive local functions writing their accumulator, one group, and a caller that reads after |
| `Once` | §18.8 | called once (accepted), twice, captured list read after creation, `Maybe.map` (accepted), `List.map` |
| `CapturedParam` | §18.9 | a lambda calling a function parameter, handed to `List.foldl` and `Set.foldl`; one stored out of sight |
| `JsPure` | §18.6 | a list shown with `Debug.toString` then extended: `escaped`, the rule named |

### 18.13 Open questions

1. **`Dict.update`.** It hands out the value at one key while the tree waits; its owned supply needs a
   dictionary focus of its own (thesis §7, *Containers*), a primitive over the tree, not `List`'s.
2. **The traversal's obligation is on its callers.** `traverseAt` is sound only in a loop that reads its
   array once per index; the obligation is stated beside it and met by five loops. A higher-order
   `traverse`, whose one loop carries it, would shrink the trusted surface to one body, but costs a call per
   element: measured in Node, `foldl` written over it is 65 % slower where its callbacks are many.
3. **Writes that propagate.** Now that `List.map` supplies its element owned, `Cmd.map`'s `mapItem`, which
   extends each command's key path in place, is accepted inside the platform and becomes a write of every
   caller's command: Conduit's 57 rejections (research 77 §3) are this one choice. Copying the path in
   `mapItem`, or a key-path representation that is not a list, would remove them.
4. **Cost.** On Conduit two thirds of the pass is summarising the library, in every dump; the summaries belong in the
   embedded checked core and the interfaces (§16.10), which is slice 4's.
