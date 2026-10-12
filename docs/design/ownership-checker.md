# The ownership checker — the in-compiler contract

*Normative from 2026-10-12. Slice 1 (report mode, intra-procedural) is specified here and built;
slices 2–5 are specified as a plan (§13) and are not built. Sections are never renumbered
(CLAUDE.md rule 2): a later amendment appends text to the section it changes, dated, or a new
section after the last.*

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
the chain.

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

### 6.2 The rows slice 1 has

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
it, a structure holding it, a pending argument, a call's result that may retain it (§6.1).

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
