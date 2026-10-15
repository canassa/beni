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

*Amended 2026-10-12: slice 3b — the entry protocol of the functions a platform calls, per platform, and the
dictionary's focus primitive — is specified in §20 and built; §19 records the manager's answers to §18.13.*

*Amended 2026-10-12: slice 3c — `init` a function on every platform, commands that take values, and `swap`'s row
— is specified in §22 and built; §21 records the owner's decisions on §20.11.*

*Amended 2026-10-12: slice 3d — owned sends (thesis Change 7, the owner's decision of 2026-10-12) and navigation
as commands — is specified in §23 and built; §23.1 records the decisions it builds, the manager's answers to §22.7
among them.*

*Amended 2026-10-12: slice 3e — ownership words on the signatures of core and the platforms (thesis Change
5(a), the owner's decision of 2026-10-12; 5(b) refused), the thesis's row for a `foreign` that carries none, and
HTTP decoders followed through `Expect` — is specified in §24 and built.*

*Amended 2026-10-12: slice 3f — a prepend copies and demands nothing (the owner's decision that `[ x, …xs ]`
copies), `map`'s identity promise read with the record types, and `Maybe.withDefault (Maybe.map m f) d` walked as
the two arms it means — is specified in §25 and built.*

*Amended 2026-10-12: slice 3g — the argument that no compiler-made binding can make a later read resolve to the
wrong binding, the early return of `?` (a defect that argument's review found), a prepend whose front item is a
list made after its base, and `Result.withDefault (Result.map m f) d` — is specified in §26 and built, with the
rules not yet modelled in the Lean oracle listed in §26.7.*

*Amended 2026-10-13: the owner dropped the identity promises of `core/List`'s functions that build, reversing
thesis O2 — `map`, `filter` and their kin return a fresh list, their summaries say so, and `identical`, `kept`,
the exempt comparison and §25.3 are gone — in §27.*
*Amended 2026-10-13: slice 4 — enforcement: a platform that edits lists in place declares it, and on such a
platform `check` and `build` run the pass and every rejected or pending line is an error with an Elm-quality
message; core's and the platforms' summaries ship in the checked core — is specified in §28.*
*Amended 2026-10-15: ownership everywhere (the owner). The pass is the language's: every platform edits lists in
place, `"lists"` is withdrawn, and every program constructor has the direct row. The whole corpus is measured
under enforcement, and the slices O0–O6 that build it are listed — in §30.*

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

*Amended 2026-10-13 (slice 4, §28.2): whether a verdict is an error is the platform's — a platform declares that it
edits lists in place (`"lists": "in-place"`), and only on such a platform do `check` and `build` run the pass. The
verdicts themselves still do not depend on the platform, but for §20.2's entry rows.*

*Amended 2026-10-15 (the owner, §30): no platform decides it. The pass runs in every `check` and
`build`, lists are edited in place on every platform, `"lists"` is withdrawn, and every program
constructor has the direct row.*

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

*Amended 2026-10-13 (slice 4, §28.3): the stage is listed in `dump`'s usage text; `--ownership-totals` and
`--ownership-flips` stay hidden, the first being for scripts and the second for tests.*

---

## 3. Demands

Thesis §3.8. A demand is an operation whose operand — the **base** — it would write in place.

### 3.1 The named writers

A call whose callee is core `List.set`, `update`, `push`, `pop`, `swap`, `insertAt` or `removeAt`
demands its first argument; `List.cons` its second; `List.append` its first. Only core's `List`
module counts: a platform module named `List` is not core's. A writer passed as a value and called
through a local is not a demand in slice 1; it is a conservative call (§6). *Superseded
(amended 2026-10-15, §30.4): since slice 2 such a value carries its class (§16.5). A call through
it is a demand where the class is in sight, and the value is pending, which is an error, where it
leaves sight. Neither case writes unchecked, and neither copies.*

*Amended 2026-10-12 (slice 3f, §25.2):* `List.cons` is not a writer. A prepend copies its base (the owner's
decision of 2026-10-11), so it reads its second argument and demands nothing.

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

*Amended 2026-10-12 (slice 3f, §25.2):* nor a **prepend**, a construction whose items all precede its one spread
(`[ x, …xs ]`, `[ a, b, …xs ]`): it copies its base, reads it, and its result is a new list that may be the
base's array (a re-cons). A construction with anything after its first spread still demands its base.

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

*Amended 2026-10-12 (slice 3g, §26.2):* `e?` on a `Result` also returns: `A(e)`'s `Err` payload, under `Err`, joins
the result of the definition the `?` targets.

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
   *Amended 2026-10-13 (§27):* `filter`'s promise is gone, and its summary says `res ε = fresh₁`; the
   rule still says "may be `xs`" of a callee with no summary, which is what it is for.

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

*Amended 2026-10-12 (slice 3f):* `List.cons`'s row is §25.2's — no demand.

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

*Amended 2026-10-12 (slice 3f, §25.4):* so is `Maybe.withDefault (Maybe.map m f) d` with `m` and `d` variable
paths and `f` a lambda or a top-level value: the call of `Maybe.map` is one arm, the read of `d` the other.

*Amended 2026-10-12 (slice 3g, §26.4):* and `Result.withDefault (Result.map m f) d`, under the same restrictions.

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

*Amended 2026-10-13: §28 is the slice-4 contract as built. The message shape is thesis Chapter 8's; the
stability policy of thesis §8.5 is not started (§28.11).*

### 13.4 Slice 5 — in-place code on `browser-direct`

Thesis §9.5, Table 9.1: on `browser-direct`, an accepted demand is the in-place operation; the trie
goes; constructions lower from the base, left to right (Change 1). The release optimiser treats a
demand as a barrier (thesis §9.6, A5). Each accepted corpus program is run under value semantics and
in place with the stale-read sanitiser of thesis §12.2, and the verdicts and traces of the Lean model
(`proofs/ownership/`, the `Oracle`) are compared with the compiler's on the generated programs of
thesis §12.1 — the differential test against the oracle.

*Amended 2026-10-15 (the owner):* "the trie goes" is now the decision itself, not a consequence of
this slice. `List` is a plain array (`backend.md` §4, *The representation: a plain array*), the
trie leaves every bundle, and `browser-direct.md`'s S7 is rewritten as "replace `core/List`'s
representation". S7 carries the conditions C1–C5 of the independent review of this checker's
oracle and bridge (`browser-direct.md`, its last amendment). One of them changes this section:
C1 makes the oracle's model of constructions a precondition of the trie's removal, not an
option. Without a trie, a construction that keeps copying makes every `[ …acc, x ]` building
loop O(n²).

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
   *Amended 2026-10-12 (slice 3f, §25.3):* two closed record types are one object only when they name the
   same fields, each pair of which may be one object; `List.map explosions toObstacle` is never `explosions`.
   *Withdrawn 2026-10-13 (§27.4):* `map` is fresh, and the record rule went with its promise.
7. **Derivations** (thesis §8.4): an instantiated entry is exact when its `res` path names one provenance;
   when it names two or more — the two outcomes of an identity promise, `List.filter`'s `{fresh, π₁}`,
   arms joined path-insensitively — every entry instantiated from it is approximate, tagged with the call,
   and a rejection through it is the `call` cause.
   *Amended 2026-10-13 (§27):* no core function has an identity promise now, and `filter`'s result is
   `{fresh₁}`; arms joined path-insensitively — `if c then [ 0 ] else xs` — are what still names two.

*Amended 2026-10-15 (CK-233, returned parameters are the caller's):* item 5 asks whether a supply is
owned, and a supply of the callee's own parameter `πᵢ.q″` is owned only in the callee's frame — its holder
there is dead after the callback's call, but the cell is the caller's argument. So wherever the callee
**relies** on an actual returning owned — `need` (item 4), or an owned supply of provenance `cb_j′` that
another callback writes (the supply edge) — each entry `(q′, π_k.q, d)` of the actual's `res` at or above
the written path is the cell the callee supplied at `π_k.q`, and every owned supply entry there is followed
to the caller:

- provenance `πᵢ.q″` of the callee: a **call-site demand** on `aᵢ` at `q″`, extended by the rest of `q`
  below the supply's path and by the rest of the written path below `q′`, exactly as the supply edge demands
  for a callback that writes its parameter (item 4); approximate when the supply or the result entry is;
- provenance `cb_j′`: the same question asked of the actual for πⱼ′, at the path its result is written at,
  to the instantiation depth;
- `fresh_k`: nothing — made during the call, no caller holds it.

`need` does not say which path of the result the callee writes, so its demands are **deep** (every cell at
or below, as a send's, §23.2) and cover every result entry, not only those at ε; the supply edge's are deep
when the written use is (`bit_d`). The rule covers every class item 5 is asked of: a lambda's, a top-level
function's, a constructor handed as a tagger (§23.5), a function slot (§24.9), and the class of a tagger
whose calls are not seen. `need` itself (§16.2) is read off through taken elements: a demand on an element
taken from a list (§18.5) whose cell is what πⱼ returned — the first item of `List.map rows f`, matched by a
pattern — writes πⱼ's result, so `need` is `owned`; before, only an untaken callback result counted, and a
callee that pushed onto that element asked nothing of `f`. It replaces §29's narrower result-loan walk, which followed only *taken* item
supplies: an untaken parameter supply was trusted, so `pushReturned xs identity`, whose callee pushes onto
what `identity` returns, wrote `xs` while the caller still read it. A demand is placed only where ownership
is relied on — a rejected `need` or a borrowed supply is reported as before, with no second line.

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
| `cons x xs` | π₁ `A`; π₂ `RAW`; `res ε = π₂`, `[*] = π₂[*], π₁` — *amended 2026-10-12 (slice 3f, §25.2):* π₁ `A`; π₂ `RA`, π₂`[*]` `A`; `res ε = fresh₁, π₂`, `[*] = π₂[*], π₁` | §3.8, the writers; the owner's decision that a prepend copies |
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
| `identical x y` | nothing | §6.5, the identity primitives: compares references, dereferences neither. *Removed 2026-10-13 with the primitive (§27)* |
| `kept same xs ys` | π₂ `A`, π₃ `A`; `res ε = π₂, π₃`, `[*] = π₂[*], π₃[*]` | §6.5, `map`'s return of its input. *Removed 2026-10-13 with the primitive (§27)* |

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
*Withdrawn 2026-10-13 (§27):* `map` and `indexedMap` return a fresh list always. `identical`, `kept`, their rows
and the `K` bit are gone, so there is no exempt comparison; `mapHelp` and `indexedMapHelp` answer their builder.

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

---

## 19. The manager's decisions on §18.13 (2026-10-12)

1. **`Cmd.map`'s and `Sub.batch`'s key paths** (§18.13 question 3): the platform must not edit a caller's list
   in place. `Cmd.map` builds each item's extended key path as a list of its own, and `Sub.batch` its joined
   list, so the write stops propagating into callers. Behaviour must be identical, and a slowdown or size
   growth beyond noise is a finding. *As built*: a key path is held outermost segment first and `Cmd.map` writes
   `[ …[ segment ], …path ]` — the new one-segment list is the construction's base, and `path` is only read
   into it — so browser-tea's architecture no longer reverses a path when it reads an item; `Sub.batch` joins
   with `[ …[], …list, …more ]`. Research 78 §2 gives the measurements, and the two forms rejected for them
   (`List.copy`, `List.concat`).
2. **A dictionary focus primitive for `Dict.update`**: built as `List.focus` is, `Dict.update` inferred over
   it (§20.8).
3. **`traverseAt`'s obligation by convention** (§18.13 question 2) is accepted while it is core-private and
   met by the five loops §18.5 names; the trusted surface lists it (§20.9).
4. **Cost** (§18.13 question 4) is deferred to slice 4, which embeds core's summaries with the checked core.

---

## 20. Slice 3b — the entry protocol (normative from 2026-10-12)

*Amends §1.2's, §16.1's and §18.1's tables, §8.2–§8.3, §16.5 and §16.11. Sections 1–19 keep their numbers
and text; where this section changes a rule, it wins. Research 78 measures it.*

### 20.1 What slice 3b builds

| Thesis piece | Slice 3b |
|---|---|
| TEA entry protocol (§7, Table 7.1, P1, P5) | **built** (§20.2–§20.6): the abstract model at entry as a fixpoint of `init` and `update`, checked at the program constructor's call, per platform |
| `init` is a function (Change 4) | **met by the direct platform's mount** (§20.3); no platform API changes |
| Payloads (P6, Change 7) | every send is supplied borrowed: the owned bits of command values are not built (§20.5) |
| `view` and `subscriptions` read only (T13) | **built** (§20.3, §20.6) |
| The renderer obligation (P7) and P2–P4 | not the checker's: obligations on browser-direct before slice 5 writes in place (§20.9) |
| `Dict.update`'s owned value (§7, *A dictionary*) | **built** (§20.8), with the separation of what is stored at one folded path |

### 20.2 Entry rows

Thesis §7, *The protocol*: the protocol "is an asserted row on the function the runtime actually calls … the
program constructors", whose record parameter holds the functions the runtime calls. Until Change 5's words let
a platform declare its rows, the checker asserts them:

| The build's platform | Program constructors | Row |
|---|---|---|
| `browser-direct` | `Tea.sandbox`, `Tea.element`, `Tea.document`, `Tea.application` | **direct**: thesis Table 7.1 |
| `browser-tea` | `Tea.sandbox`, `Tea.element`, `Tea.document`, `Tea.application` | **template** |
| `browser` | `Browser.program` | **template** |

A constructor is the declaration of that name, in the module of that name, of the platform package of that name
(the chain layer's manifest `"name"`).

*Amended 2026-10-13 (slice 4, §28.2):* the direct row is chosen by the property, not by the name: `Tea.sandbox`,
`element`, `document` and `application` of a platform package whose own manifest declares `"lists": "in-place"` have
the direct row, whatever the package is called, so that the row survives `browser-direct`'s rename to `browser-tea`.
The template rows keep their names (`browser-tea`'s `Tea`, `browser`'s `Browser.program`) and apply only to a
package that does not declare the property. Any other program constructor — `Browser.hosted`, which a program never
meets, or a test platform's — has no row: the functions it is handed stay `pending` (§16.5).

*Amended 2026-10-15 (the owner, §30.3):* the template rows and the `platform` cause are
withdrawn. Every program constructor has the direct row, declared by the ownership word `entry`
on its record parameter instead of by this table: `browser-direct`'s and `browser-tea`'s `Tea.*`,
`browser`'s `Browser.program` and the test platform `page`'s `Page.sandbox`.

**Which platform.** Thesis §7 checks every program against the direct row "so that a source has one verdict on
both browser back ends"; Change 8 keeps in-place lists to the direct platform. Both hold here: a template row
computes everything the direct row does, and then an edit the direct row would accept is rejected with the cause
**`platform`**, of the position kind — browser-tea's and browser's runtimes keep the model they hand `update`
(the renderer compares the values the last render read by identity, and keeps that render's handlers), so they
hand it nothing owned. Every other rejection is the same line on every browser platform. Verdicts therefore
differ between platforms by exactly the `platform` lines.

### 20.3 What each function receives (the direct row)

- **`init`** (Change 4). On `browser-direct` the expression in the record's `init` field is evaluated by the
  mount, once per mount (`browser-direct.md` §11.1 as built), and one program value mounted twice is refused
  (`program_mounted_twice`): the expression *is* the body of Change 4's `init ⊤`. The cells it makes — its
  literals, its callees' fresh results — are fresh at entry; a top-level value it names is shared (T53:
  `init = initialModel` is rejected at the first in-place edit, `init = initialModel ⊤` or a literal is accepted).
  So no platform's API changes in this slice. On the template platforms `init` is a value evaluated with `main`,
  which their `platform` rejection makes moot. `application`'s `init` is a function of the page's address,
  which crosses, and its navigation key, a foreign type: its class is applied to `∅` and `⊤`.
- **`update msg model`**: the model owned (P1); the message as §20.5 says. Its result's model half is the next
  entry model; everything its command half holds escapes (thesis §7, *Fibers and commands*).
- **`view model`**: the model to read only. A write of view's on its model is rejected (T13), cause
  **`read-only`**; what its summary escapes on the model (E, J) escapes at entry; its result escapes nothing
  (P3: a handler made by one render reads the model at its event).
- **`subscriptions model`**: to read only, as `view`; everything its result holds escapes.
- **`onUrlRequest`, `onUrlChange`**: their arguments cross; nothing.

The model a function receives is its record field's model half: `init`'s whole value for `sandbox` and
`Browser.program`, its first component otherwise; `update`'s parameter 2 and result alike.

### 20.4 The model at entry

Thesis P5: the abstract model at entry is a least fixpoint, computed at the constructor's call from the classes of
the record's functions (§16.5: a top-level function's summary, a lambda's class):

    M₀ = init's model        Mₖ₊₁ = Mₖ ∪ update's result's model half, instantiated with π₁ = the message, π₂ = Mₖ

Instantiation is §16.4 item 6's. update's `fresh_k` is the one cell `result(constructor call, k)` in every round
— two dispatches' new lists taken for one, which only adds aliasing, as §16.6 merges a recursive group's — so the
fixpoint is over a finite set of cells; `esc_k` is that cell, escaped; `shared` and `⊤` are carried; a parameter
cell's condition is lowered by its `xres` (§18.3). A fixpoint not reached in 8 rounds adds `⊤` (a backstop).

*As built*: the rounds compute cells only, and the round that settles is taken once more with the conditions its
instantiation lowers. The message carried round the loop is `msg` alone; the cells a view puts in messages
(§20.5) are read once, from the settled model, because every demand they could reach is the payload rule's
already — a model path where an arm stored a message holds `msg`, and a model cell a view message holds is
rejected where it is written. Carrying them round the loop doubled Conduit's model at entry for no verdict. A view message's cells are its
value's with closures expanded: a handler that captured a model list names that list, so no cell a message can
reach is missing from them. Where `update` has several classes, a path's line takes the worst derivation and
exclusivity any of them gives (PR #63's review).
Two bounds keep a wide model cheap, neither of which accepts anything: a value of more than 256 entries is
projected through an index by its first step, and one of more than 256 cells has the pessimistic deep
condition (`lost`) rather than a pair-by-pair one.

Then, at the call's point: **(a)** every cell update's summary escapes on π₂, its result's command half holds,
`init`'s command half holds, `subscriptions`' result holds, and `view`'s or `subscriptions`' summary escapes on
their model joins Esc; **(b)** the demands of §20.6, after (a), so that an escape at any dispatch is seen.

### 20.5 Messages (P6, Change 7)

The message `update` receives is a symbolic cell of its own, **`msg`**, standing for every payload, together
with every cell `view`'s result holds: a message built in markup from a model path (`onClick={Keep model.rows}`)
holds the model's cell, at every arm (thesis P6, *View events*: coarse, a limit). A send is a supply to `update`
(Change 7) whose owned bit is a fact of each command value; slice 3b does not build those bits — the rows of
`Cmd.perform`, `Cmd.map`, `Cmd.batch`, `Cmd.task` and the subscription constructors that carry them — so **every
payload is supplied borrowed**. A demand that reaches `msg` is rejected, cause **`payload`**, approximate: "a
message's payload may still be held by its sender, and owned sends are not built (Change 7)". That covers
`update` writing its message in place (W on π₁, T50) and an arm editing a model path where another stored a
payload (T38). A payload that reaches no cell written in place is accepted (T34).

### 20.6 The demands at the entry

At the constructor's position, after (a):

- **for each path `q` at which `update` writes its model** (W on π₂.q): a line `entry M.update`, base `model`
  with `q` (`model.todos`), checked as a call-site demand (§16.4 item 3) on the entry model at `q` — Known,
  Unescaped, Disjoint against the model's other paths and the message, Dead (on the direct row nothing holds
  the model after the call, P1) — then `update`'s `xreq` on `(msg, M)`, a failure the `exclusive` cause.
  Accepted with the new kind **`entry`**: the runtime hands `update` the model owned;
- **for each path `p` at which `update` writes its message** (W on π₁.p): base `msg` with `p`, rejected
  `payload`;
- **for each path at which `view` or `subscriptions` writes its model**: rejected `read-only`, exact.

The template row turns each accepted `entry` line into `rejected platform`. The record's functions are in sight
at a constructor with a row: a writing `update`, `view`, `init` or `subscriptions` gets no `value … pending`
line there (§16.5), and a lambda's demands on its own parameters are decided by the entry lines (`decided at its
calls`).

### 20.7 The report

Acceptance kinds (§8.2) gain **`entry`**, after `once`. Causes (§8.3) gain, after `once`, **`payload`**
(approximate), **`read-only`** (exact) and **`platform`** (position).

### 20.8 The dictionary's focus

`core/Dict` gains `focus : Dict k v, k, (Maybe v → Maybe v) → Dict k v`, not `pub`, whose body is the one
`update` had — the value at the key handed to `alter`, its answer inserted or the key removed — and `update` is
`focus`. Its row is its body's summary, inferred, with one fact asserted (thesis §7, *A dictionary*: "the
module's one asserted row"): the supply to `alter` at `#Just.0` is the value at the key, **taken** and **owned**,
on condition `excl π₁` — a destructive read when the dictionary is exclusive, as §18.5's `focus` is for a list.
The row writes nothing of its own: a callback that edits what it is handed makes a call-site demand on the
dictionary's values (§18.5, *At a call*), and one that only reads leaves the dictionary aliased by the result
(T51).

What `excl` of a dictionary means is a fact about representatives (thesis §3.1; §7: the slots `⟨Dict⟩.k` and
`⟨Dict⟩.v` are "containers whose positions are the nodes"), which §16.1 left unbuilt. Slice 3b builds the part
the focus relies on:

- **What is stored beside what is there.** A constructor application that places cells of two of its arguments
  at one folded path — a node's value, and its subtree's values, both at `#Node.2` — lowers the condition of each
  pair of distinct cells there by `sep` (§18.2): what is stored at a representative shares no cell with what is
  there. So `Dict.insert`'s inferred result says `π3{sep π3 π1#Dict.0#Node.2}`, and one list inserted at two keys
  fails `exclusive`, exactly (thesis §7: insert "keeps `excl` only if both were stored exclusively, disjoint from
  each other and from the rest").
- **The positions of one arrival.** A cell that arrived from outside (a parameter, a capture, a callback's
  result) at a folded path of core `Dict`'s tree stands for the values at all of its positions, so `sep` of it
  with itself is its own condition: distinct positions of an exclusive dictionary share no cell. This rests on
  an obligation on `core/Dict` that the trusted surface lists (§20.9): **no function of `core/Dict` places one
  value at two positions of a tree.** Every other folded path keeps §18.2's rule: a cell that stands for many is
  not separated from itself, approximately.

### 20.9 The trusted surface

What the checker takes on trust, each item privileged code whose error is a correctness bug (thesis §6.5):

- `core/List`'s asserted primitive rows (§16.8, §18.5);
- `traverseAt`'s obligation, met by `foldlFrom`, `foldrFrom`, `mapHelp`, `indexedMapHelp` and `filterMapHelp`,
  the only functions that call it, core-private and audited (§19 item 3);
- `Dict.focus`'s destructive read, and `core/Dict`'s obligation that no function places one value at two
  positions of a tree (§20.8);
- the entry rows (§20.2): the template rows are what browser-tea and browser do today; the direct row is what
  browser-direct must meet — P1's hand-over, and P2–P4 and P7, which the checker does not see — before slice 5
  writes a list in place (thesis §7, *The obligation a future slice must meet*).

### 20.10 Testing

New fixtures in `tests/corpus/ownership/`, named `Entry…`. A fixture beside a `.platform` file is checked and
dumped under each platform the file names, one golden per platform (`EntryPush.browser-direct.ownership`):

| Fixture | Pins | Expected |
|---|---|---|
| `EntryPush` | P1, I5 | `update` pushes onto `model.items`: accepted `entry` on browser-direct, rejected `platform` on browser-tea |
| `EntryKeepsOld` | T17 at the entry | an arm keeps the old list in the model and edits a copy target: rejected |
| `EntryCommand` | T20, thesis §7 *Fibers* | a command captures `model.items` and another arm pushes: rejected `escaped` |
| `EntryInit` | T53, Change 4 | `init = initialModel`: rejected `top-level`; `init = initialModel ⊤`: accepted |
| `EntryPayload` | P6, *View events* | a view event carries `model.rows`, an arm pushes: rejected `payload` |
| `EntryView` | T13 | `view` extends a model list: rejected `read-only` |
| `DictFocus` | §20.8, T44, T51, T32 | `Dict.update` editing its value accepted on an exclusive dictionary; rejected when one list is at two keys, or a key and a value; a reading callback consumes nothing |

and the applications (Conduit, TodoMVC, the table app) are measured per platform by research 78.

### 20.11 Open questions

1. **Owned sends** (Change 7): the bit per message path on command and subscription values, and its rows. Until
   it is built every payload is borrowed, and research 78 counts what that rejects.
2. **`init` on the template platforms**: Change 4 changes every constructor so that `init` is a function. On
   browser-direct the mount already evaluates it per mount (§20.3); on browser-tea and browser it is evaluated
   once with `main`, which is sound only because they write nothing in place. Whether to change their API anyway,
   so that one source's `init` means the same on all three, is the owner's.
3. **View-event payloads** are aliased with the model at every arm (P6). A summary of `update` split by its
   message's constructor would confine them to the arm that receives them; research 78 counts how often the
   coarse rule fires.

---

## 21. The owner's decisions on §20.11 (2026-10-12)

1. **Owned sends** (§20.11 question 1, Change 7): accepted, and built by slice 3d, not 3c. Until then
   every payload is borrowed, as §20.5 says, and research 79 counts the `payload` rejections that
   leaves.
2. **`init` on the template platforms** (question 2): **`init` is a function on every platform** —
   `browser-tea`'s `Tea.sandbox`, `element`, `document`, `browser`'s `Browser.program` and
   `browser-direct`'s constructors all take `init : ⊤ → …`, called once per mount; `Tea.application`'s
   already was a function of its address and key. One API everywhere (`boundary.md` §9.8.16 (a)).
3. **Platform commands take values, not closures that read the model later** (thesis O5): every platform
   command that persists or sends data takes the value already computed — `Storage.save`, an HTTP body as
   encoded text, the log line — and a body that genuinely needs the list later says `List.copy`
   (`boundary.md` §9.8.16 (b)).
4. **View-event payloads** (question 3) are not decided: the coarse rule of §20.5 stays, and research 79
   counts it again.

The manager adds one: **`List.swap` keeps exclusive contents**, as the thesis's row says (`swap … excl
if π₁ excl`), and the other writers' rows are checked against the thesis the same way (§22.5).

---

## 22. Slice 3c — `init` a function, value commands, permutations (normative from 2026-10-12)

*Amends §20.3 and §20.9. Sections 1–21 keep their numbers and text; where this section changes a rule,
it wins. Research 79 measures it.*

### 22.1 What slice 3c builds

| Thesis piece | Slice 3c |
|---|---|
| `init` is a function (Change 4) | **built on every platform** (§22.2; `boundary.md` §9.8.16 (a)), with `beni fmt --migrate-init` |
| Command constructors that take values (O5) | **built**: `Storage.save`, `Http.send`, `Log.write` (§22.3; `boundary.md` §9.8.16 (b)) |
| The writers' rows (thesis §3.11) | `swap` **asserted** with `pop`'s row; the others checked (§22.5) |
| Owned sends (Change 7) | not built: slice 3d (§21 item 1) |

### 22.2 `init` at the entry

§20.3's first bullet is replaced. On every row `init` is one of the record's functions, like `update`:
its classes are read off as §20.4 reads `update`'s, and the model at entry starts from its result
applied to `⊤`, which holds no cell —

    M₀ = init's result, instantiated with π₁ = ∅      (Tea.application: π₁ = ∅, π₂ = ⊤, as §20.3 had)

— its model half for `element`, `document` and `application`. A function the walk cannot place makes
a model it cannot know: `M₀` is `⊤`. The runtime calls `init` once per mount (`boundary.md` §9.8.16), so
the cells its body makes — literals, its callees' fresh results — are fresh at entry, on every
platform, whether `init` is a lambda written in the record (`init = λ⊤ → { todos = [] }`) or a named
function (`init = initialModelOf`); a top-level value it returns is shared (T53), and that is rejected
`top-level` at the first in-place edit through either spelling — `init = λ⊤ → initialModel` and
`init ⊤ = initialModel` alike. The template rows keep their `platform` rejection (§20.2); a `top-level`
or any other cause is the same line on every platform.

`init` is in sight at a constructor with a row, as §20.6 says of the other fields: a lambda's demands on
its own parameters are decided at the entry, and no `value … pending` line is printed for it.

### *Amended 2026-10-15 (init captures):* arrivals are not allocations

The cells an `init` body allocates are fresh. Returning a captured local does
not allocate its cells again. Such cells can transfer into the initial model
only when no other retained holder can read them. In particular, the environments
of `update`, `view`, subscriptions and the other entry callbacks remain live
across runtime calls and must be disjoint from each model path edited in place.
The entry's disjointness check includes every non-`init` field of its record,
with closures expanded into their captures, alongside the other model paths.
A helper-returned closure retains its instantiated bindings and callback values
as well; carrying its class across a call does not erase its environment.
Only a path known to start with the `init` field is excluded: root and wildcard
entries may contain other callbacks and remain retained.
Ordinary Dead and escape obligations still cover holders outside that record.

Thus `init = λ⊤ → m` with `view = λ_ → …m.items…` cannot authorize editing
`model.items`, whether `m` was a local literal or arrived through a private
single-read top-level initializer. A local used only by `init` can still transfer;
a literal allocated inside `init` remains fresh. This narrows §22.2's allocation
claim and adds no permission. Cached ownership blocks advance to version 8 so
an older entry proof cannot survive the corrected rule.

### 22.3 Commands that take values

Nothing in the checker changes for them: what a command holds escapes at the constructor's call (§20.4
(a)), and a value command holds only what it was handed. `Storage.save area key text failed` captures
three strings, which cross, and a function of the error; `Http.send request tag` a record whose body is a
`Body` (text, or parts of text) and whose `expect` is a function of the response; `Log.write level line`
a string. So a model list reaches none of them unless the program puts it there, and an arm that saves
or sends the model's text leaves the model's lists unescaped. The three are beni over the direct forms,
their summaries inferred; none is asserted.

What a value command does **not** remove is the encoder's own escape. A text computed by a core function
over `Js` — `String.join`, a schema's `print`, `Debug.toString` — hands the list to a `Js.pure` lambda,
which §18.6 takes to keep it, so the list escapes in the arm that encodes it whichever way the command is
built. That is Change 5's (ownership words on those functions), not this slice's; research 79 counts it.

### 22.4 The closures that stay

Every constructor that takes a function stays (`boundary.md` §9.8.16 (c)): a body, the work of
`Cmd.task` and `Cmd.do`, a tag, a subscription's listener are effects or message maps, not data. A body
that captures a model list holds it, the list is escaped at every dispatch after the one that made the
command (§20.4 (a)), and an in-place edit of it is rejected `escaped` (`EntryCommand`,
`EntryValueCommand`) — never accepted unnoticed. The program that means the command to keep the list
writes `List.copy`.

### 22.5 Permutations, and the writers' rows against the thesis

Thesis §3.11's rows, against what slice 3b had:

| Writer | Thesis | Slice 3b | Slice 3c |
|---|---|---|---|
| `set`, `insertAt` | `excl if π₁ excl and π₃ stored exclusively` | asserted, the same | the same |
| `push` | the same, for π₂ | asserted, the same | the same |
| `pop`, `removeAt` | `excl if π₁ excl` | asserted, the same | the same |
| `swap` | `excl if π₁ excl` | **inferred** from `set (set xs i y) j x`, which stores two of the list's own elements back into it: `{lost}` | **asserted** with `pop`'s row |
| `update` | `excl if π₁ excl and g keeps shape` | `focus` (§18.5) | the same |
| `cons`, `append` | as written | asserted, the same | the same |

`swap`'s body is a permutation: the element at `i` goes to `j` and the one at `j` to `i`, so distinct
positions still hold distinct cells, which no inference over two `set`s can see (each `set` stores a cell
the list already holds at another position). The row is asserted, and the trusted surface (§20.9) gains
it: **`List.swap` only permutes**. `insertAt`'s row was already the thesis's; `Permutations` pins all five.

### 22.6 Testing

New and changed fixtures in `tests/corpus/ownership/`:

| Fixture | Pins | Expected |
|---|---|---|
| `EntryInit` (rewritten; browser-direct and browser-tea) | Change 4, T53, T14, T21 | `init = λ⊤ → initialModel` and `init = initTop` with `initTop ⊤ = initialModel`: `top-level` on both; a named function and a lambda that build the list: `entry` on browser-direct, `platform` on browser-tea; a top-level seed: `top-level` |
| `EntryInitProgram` (browser) | `Browser.program`'s `init` | `top-level` for a top-level list, `platform` for a fresh one |
| `EntryValueCommand` (browser-direct and browser-tea) | O5, §22.3–§22.4 | `Storage.save`, `Http.send` and `Log.write` of the model's text, then a push: `entry`; the same save through `Cmd.do` capturing `model`: `escaped` |
| `Permutations` | §22.5 | an element edit after `swap`, `pop`, `removeAt` and `insertAt` of a literal: accepted with `xreq excl π1`; one list inserted twice, and `[ row, row ]` swapped: `exclusive` |

and on the pages: `browser/tea/ValueCommands` (the three commands' effects), `StorageFaults` (`save`'s two
failures as its tag), `browser/direct/InitThrows` (one golden on both platforms).

### 22.7 Open questions

1. **Navigation as commands.** Elm's `Browser.Navigation.pushUrl` is a command that takes values; beni's
   is a direct form, so a page writes `Cmd.do λ⊤ → Navigation.pushUrl key url`, and Conduit's one capture
   of the whole model (research 78 §5) was such a body computing its key inside. It is fixed by computing
   the key first; command forms of the navigation calls would make that the only spelling, at the cost of
   names beside the direct forms that already took Elm's.
2. **The encoders** (§22.3): `String.join` and `Schema.print` escape what they read until Change 5's words
   say they only read; research 79 counts the lines that cause.
3. **`Http.send` has no tracker and no `riskySend`**: a page that needs either writes a body. To be added
   when a program needs one. *(Closed 2026-10-14: `boundary.md` §9.8.19 adds `send`'s `tracker`,
   `Http.track` and `riskySend`. Both commands take values, as `send` did, so §22.3 holds them as
   before.)*

---

## 23. Slice 3d — owned sends, and navigation as commands (normative from 2026-10-12)

*Amends §16.2, §16.11, §18.8, §20.2–§20.9 and §22.3. Sections 1–22 keep their numbers and text; where this
section changes a rule, it wins. Research 80 measures it.*

### 23.1 The decisions it builds

- **Owned sends** (the owner, 2026-10-12; thesis Change 7, §21 item 1). *A message's payload is handed to
  `update` owned: the sender gives it up.* The checker verifies it where the send is written: a send consumes
  every list cell its payload holds, and a later use by the sender, or the payload still being reachable from
  the model or from another live holder, is a rejection **at the send**, with its reason — never a copy. Every
  way a payload reaches `update` is covered: command results (`Cmd.perform`, `keyed`, `afterRender`, `task`,
  `do`, `Http.send`, `Storage.save`, `Random.generate`), subscriptions, the platform's own sends, and view
  events, which §23.6 says exactly what the checker does with.
- **Navigation as commands** (the manager's answer to §22.7 item 1): elm/browser's `Browser.Navigation` —
  `pushUrl`, `replaceUrl`, `back`, `forward`, `load`, `reload` are commands that take values, so an `update`
  that changes the address hands the runtime the key and the address, not a function that reads the model
  later. `boundary.md` §9.8.17 is the API; §23.8 is what the checker sees.
- **`Http.send`'s tracker and credentials** (§22.7 item 3): a capability gap, out of this slice
  (`plans/queue.md` row 82). **The `init` purity bytes** (queue row 81): out of this slice.
- **Change 5** (ownership words on `foreign`) waits on the owner and is not built; research 80 counts the
  rejections it would clear (§22.7 item 2: `String.join`, `Schema.print`, and the HTTP answers of §23.9).

The owner's rule is stronger than the thesis's. Change 7 makes a send *owned* when the payload is unique there and
*borrowed* otherwise, and rejects only a borrowed payload that reaches a cell written in place (T34: a sender
that keeps using a payload no arm writes is accepted). Here every send gives its payload up, so T34's sender is
rejected at the send. The guarantee it buys is modularity at the receiving end: `update` may write any payload
it is handed, in any arm, with no reach analysis from the sends to the arms; §23.11 item 1 asks whether a send
whose payload no arm writes should be a warning rather than an error once slice 4 enforces (CLAUDE.md rule 7).

### 23.2 A send is a write of everything it is handed

A **send value** is a function the runtime hands a body to send messages with (§23.3). Calling one is a
**send**, and a send is a call-site demand (§16.4 item 3) of its argument — the payload — on **every cell the
payload holds**, closures expanded, not only the one at its root: thesis §3.8's demands write one array, a send
gives up the whole value. It is checked as §8.1 checks any demand, at the send's point:

- **Known** — a list from JavaScript is not the sender's to give (`unknown`, approximate);
- **Unescaped** — an escaped or top-level list (`escaped`, `top-level`);
- **Disjoint** — no other operand holds it;
- **Dead** — no holder is read after the send: the sender's own later reads of the list (`later-use`), a local
  that holds it (`alias`), a pending operand. A lambda's later read of a list it captured counts too (§23.7);
- a cell the body captured makes the body **once** (§18.8): its creation is the demand on the capture, in the
  body that writes the lambda — so a body that sends `model.rows` while its arm keeps `model` in the next model
  is rejected there, `later-use`, naming the model — and a body handed where it may run more than once is
  rejected `once` (a command's body: §23.3);
- a parameter cell makes the write the summary's (§16.3): a function that sends its parameter **gives it up**,
  printed `S` in a summary line (`s` when derived through an approximate step), and its callers make a call-site
  demand on every cell their argument holds there. The bit is `W` with a *deep* flag (`bit_d`); every rule
  that reads `W` reads the deep flag with it — §16.4 item 3, the supply edge of item 4, a once closure's
  creation (§18.8), the entry's demands (§20.6).

A send whose payload holds no cell gives nothing up and is no line. The line's operation is `send`, its base
the payload as written (`<Loaded …>` for a constructor's application).

### 23.3 Send positions

Where a send value comes from is a fact of the function the runtime is handed it through — a **send
position**: `fun(j).send = k` says that the callee hands its function parameter πⱼ, as πⱼ's parameter k, a send
value; printed `sends πk` after the parameter's other facts. The runtime hands its bodies their sends in
JavaScript, which no beni body shows, so the send positions are **asserted rows** of `browser`'s `Hosted`, the
module every command and subscription is built over (§20.9's trusted surface gains them). Each is the body's
inferred summary — what the value it makes holds, so that a command still holds what its body captured, and
that escapes at the entry (§20.4 (a)) — with these facts replaced:

| Function | Row |
|---|---|
| `job body`, `later body` | π₁ `calls many`, `sends π1`: the runtime calls a body with a send, as often as the command value that holds it is returned |
| `tap body tag`, `hook start tag` | π₁ as `job`'s: it sends raw values; π₂ `calls many`, `need owned`, supplied **borrowed**: one value goes through the tagger of every current subscription of its key (`Hosted.through`) |
| `mapJob j tag`, `mapLater l tag` | π₂ `calls many`, `need owned`, supplied **owned**: what the inner send gave up |
| `mapTap t tag` | π₂ as `tap`'s tagger: borrowed |
| `runJob j send`, `callJob j send` | π₂ `calls many`, no supply: the runtime hands the send to a body whose sends were checked where it was made, at `job`'s row |

Everything above them is inferred. A function parameter handed to a send position takes the fact (§16.4
item 4's translation), so `Cmd.perform`, `keyed`, `afterRender`, `Sub.listen` and `Sub.on` get `sends π1`, and
a parameter handed to one stays in sight where the value the position made keeps it (§16.5's `pending` would
otherwise fire on every command). `Js.maySuspend f` (`backend.md` §4) reads the bit the checker inferred for `f`
and nothing of `f`'s value: it is no use and no loss of sight. What the runtime sends a tagger's result to is a
`need` (§16.2): `Cmd.task work tag` sends `tag (work ⊤)` from a body, so its `tag` needs to return owned, and the
tagger a program hands it is checked there (§23.5).

### 23.4 What is checked where

A function value handed to a send position is checked where it is handed:

- **a lambda written there** (`Cmd.perform λsend → …`, `Cmd.perform (search q _)`): its parameter k *is* a send
  value, known before its body is walked, so each call of it in the body is a `send` line (§23.2), and handing
  it to a function's parameter is the supply edge (§16.4 item 4) with the send as the actual: every supply the
  callee makes to that parameter must be owned — a borrowed one is a `send` line at the call, rejected `supply`
  ("`Main.search` sends what it may still hold (π1)") — and an owned one of the callee's own parameter is a
  call-site demand, every cell, on the argument (`search q _` gives up `q`);
- **a top-level function** (`Cmd.perform body`): its summary's supplies to its parameter k, at the hand-over: a
  borrowed one, or one of a parameter or a callback's result that nothing supplies owned, is a `send` line
  rejected `supply`; one that calls its send where it loses sight of it, the same;
- **anything else** — a lambda bound to a local first, a local function, a value read out of a structure: its
  sends are not followed (§16.5: a lambda's class does not follow its own function parameters), and it is a
  `send` line rejected `supply`, approximately.

None of these is a line when the message type can hold no list `update` could write: a type **holds a list**
when a `List` is reachable in it without going through a function or a `foreign type` other than `List` — a
closure's captures are §16.5's to follow, and what JavaScript holds is `⊤` wherever it is read. So the platform's
key and pointer subscriptions, whose payloads are `Html.Event`s, are no lines.

### 23.5 Taggers

A constructor handed as a function (`Cmd.task work Loaded`) has a class: it returns each argument whose type
holds a list at its own field (`res #Loaded.0 π1`). So a tagger's `need` is checked against what the callee
supplies it: `Loaded` returns owned exactly when `Cmd.task`'s work does (§16.4 item 5), and `Cmd.task (λ⊤ →
model.rows) Loaded` is rejected `need` at the tagger — "`Cmd.task` sends what it returns, and it returns what
`Cmd.task` hands it, which may be a list the sender still holds" — exactly when the work returns a list the
model holds, approximately when only an approximate step made it so (a list from JavaScript, a conservative
call's result).

### 23.6 The entry: messages are owned

§20.5 is replaced. The message `update` receives is the symbolic cell **`msg`**, standing for every payload a
send gave up, together with the lists a view's messages may carry:

- **`msg` is owned.** Every send was checked where it was written (§23.2–§23.5), so a demand that reaches `msg`
  only is accepted, `entry` on the direct row (`platform` on the template rows, §20.2). Nor is a model path
  that holds a stored payload Disjoint-checked against the message in hand: a send gave each payload up, so the
  one a dispatch receives is not the one an earlier dispatch stored. So T38's and T50's edits are accepted,
  and the owned-send `payload` rejections of slice 3c are gone.
- **A view event is not a send.** Nothing gives its payload up: the runtime builds the message from the
  markup when the event fires — from the model current then (P3), and from a markup value's kept handlers,
  which keep the message a render built from one dispatch to the next — so a list in it may be the model's, or
  one handed over twice. Every such list is borrowed — the view's result's cells, closures expanded, but its
  own root node and the top-level values whose type holds no list (a footer it includes): the model's lists
  it reads and the lists it made. They reach the model only where an arm stores a payload, which the cell
  `msg` marks wherever it is stored, so they are not carried round the fixpoint (§20.4) — carrying them
  doubled the pass on Conduit and changed no verdict. A demand that reaches one of them, or reaches `msg`
  when the view's messages may hold any list, is
  rejected **`payload`**, approximately: "a message a view event builds may hold it — a list of the model, or one
  a handler keeps from one dispatch to the next — and the check does not tell update's arms apart". That is
  thesis P6's coarse rule; O6 (a summary split by the message's constructor) would confine a view event's
  payload to the arm that receives it, and research 80 counts how often it fires.
- **`update`'s `xreq` on its message** is checked as on the model (§20.6): `msg`'s condition is `lost` — a
  send's payload is unique, but whether its elements share is not carried to the entry — so an arm that edits
  an element of its message's list relies on what fails, approximately (`exclusive`).

The cause `payload` (§20.7) is now the view-event rule's alone.

### 23.7 Once closures read what they captured

§18.8, made precise for sends. A use inside a lambda of a local it captured from an enclosing frame is recorded
in the lambda's frame (§7.1, which recorded uses of the frame's own locals only), and a demand on a captured
cell has the captured local as a holder there. So a body that sends `rows` and then reads `rows` is rejected
at the send, as the same two lines outside a lambda are. And where a once closure's write is decided (§18.8), an
exact failure of its creation — a live holder of what it captured — is reported before the place that may call
it more than once, which is reported before a `pending` place: the holder is the reason a program can act on.

### 23.8 Navigation

`Browser.Navigation.pushUrl key url refused` is `Cmd.perform` over the direct form `push` (`boundary.md`
§9.8.17): a lambda whose captures are the key, the address and the tagger, none a model list. So an arm that
changes the address and returns its model leaves the model's lists unescaped, which a `Cmd.do` that read its
key from the whole model did not (`NavigationCommands`): Conduit's shape. Nothing else in the checker changes
for them.

T29's ordering — a batch whose first body sends, dispatched at once before the second body runs (`boundary.md`
§9.8.4) — is unchanged, and so is its verdict: the second body's capture escapes `kept`, and `Toggle`'s edit is
rejected `escaped` (`T29`; `browser/tea/SyncCommandOrder` pins the order at run time).

### 23.9 The trusted surface

§20.9 gains, approved by the manager on 2026-10-12 on condition that each row names the runtime code that
justifies it. The browser runtime is beni over `Js` (`platforms/browser/Hosted.js` holds only the keys), so the
references are to its beni functions:

| Row (§23.3) | What it asserts | Justified by |
|---|---|---|
| `Hosted.job`, `Hosted.later` | the runtime calls the body it keeps, as often as the command that holds it is returned, with a send of its program | `platforms/browser-tea/Tea.beni`: `spawn`, `spawnAfter` and `queue` run each `Perform`/`Now` job through `Hosted.runJob`/`callJob` handed `Hosted.emit o _`; `platforms/browser/Hosted.beni`: `afterRender` calls a `later` body with a function that `send`s to its host |
| `Hosted.tap`, `Hosted.hook` | the body or listener is handed a send of raw values; each value goes through the tagger of **every** current subscription of the key, so a tagger receives it borrowed | `platforms/browser/Hosted.beni`: `run` and `hear` hand the body or listener `λvalue → tagged r value`; `tagged` and `through` apply every tap's tagger of the relay to the one value; `platforms/browser-tea/Tea.beni`: `arrive`/`begin` start one relay per key |
| `Hosted.mapJob`, `mapLater` | the tagger is handed what the inner send gave up, once | `platforms/browser/Hosted.beni`: `mapJob` wraps the send as `λm → s (tag m)`, `mapLater` composes its tagger in front of the outer one |
| `Hosted.mapTap` | the tagger is handed what an inner tagger made of a fanned-out value: borrowed | `platforms/browser/Hosted.beni`: `mapTap` composes `f` after the inner tagger, which `through` applies per tap |
| `Hosted.runJob`, `callJob` | the send handed to them only reaches a body whose sends were checked at `job`'s row | `platforms/browser/Hosted.beni`: `runJob`/`callJob` apply the job to the send and nothing else |

and **the runtime's forwarding**: what a send hands the runtime reaches `update` once, as the message `update`
receives, and the runtime keeps nothing of it after the dispatch — `platforms/browser/Hosted.beni`: `emit` and
`send` (one `Js.call h "send"` per message); `platforms/browser/Browser.beni`: `host`'s `send`, which applies a message, or queues one
sent during a dispatch and applies it after, in order (`boundary.md` §9.8.4); `platforms/browser-direct/Direct.beni`:
`send`, the dispatch guard's queue.

### 23.10 The report

Operations gain **`send`** (§23.2, §23.4); a summary line's bits gain **`S`** and `s` (§23.2) and a function
parameter's facts **`sends πk`** (§23.3). No acceptance kind or cause is new: a send is accepted as any demand is
(`fresh`, `call`, `param`, `callback-param`, `once`), and rejected with §8.3's causes, `supply` (§23.4) and
`need` (§23.5).

### 23.11 Testing

New fixtures in `tests/corpus/ownership/` (each beside a `.platform` file, §20.10):

| Fixture | Pins | Expected |
|---|---|---|
| `OwnedSend` (browser-direct, browser-tea) | §23.2, §23.5, §23.6; T38, T50 | a payload a work builds, stored and then pushed: `entry` on browser-direct; `update` pushing its message's list: `entry`; a body that sends a list and reads it after: `alias` at the send; `Cmd.task (λ⊤ → model.rows) Loaded`: `need` at the tagger, exact; a body that sends `model.rows` while the arm keeps `model`: `later-use` at the send |
| `ViewEventPayload` (browser-direct) | §23.6, P6 | a view whose messages hold no list: both edits `entry`; a view event carrying `model.rows`, and one carrying a list the view made: `payload` |
| `NavigationCommands` (browser-direct, browser-tea) | §23.8; `boundary.md` §9.8.17 | `Navigation.pushUrl` in Conduit's shape: the visits push `entry`; the slice-3c body that reads the key from the whole model: `escaped` |
| `T29` (browser-direct) | §23.8, T29 | `escaped`, as before |
| `EntryPayload` (rewritten) | §23.6 | `stores` and `edits` accepted `entry`; `pins` `payload`, now the view-event rule |

and the page `browser/tea/NavigateCommands` (the commands' effects and refusals). `NavigatePush` and
`NavigateErrors` keep testing the direct forms, renamed.

T34-shaped sends — a sender that reads a list after sending it, where no arm of `update` writes what the
payload reaches — are rejected by the strict rule (§23.12 item 1); the external-corpus slice (§13.2) counts them,
and the rule is revisited if they appear.

### 23.12 Open questions

1. **A send whose payload no arm writes** (T34). The owner's rule rejects it at the send; the thesis accepts it,
   since nothing is written in place that the sender's later read could see. When slice 4 makes rejections
   errors, rule 7 asks whether this one is a warning: no guarantee is lost by it on the template platforms, and
   on the direct platform only the arms that write a payload need it. Research 80 counts the lines.
   *Answered 2026-10-12 (the manager):* the strict rule stays, and stays an error under rule 7 — it buys a real
   guarantee, that `update` may write any payload it is handed with no reach analysis from the sends to the arms —
   while no measured line pays for it. The external-corpus slice (§13.2) counts T34-shaped sends, and the decision
   is revisited if they appear (`plans/queue.md` row 83).
2. **The HTTP answer.** A list an `Http` answer's decoder builds reaches the tagger through `Expect`, a function
   stored in a record (§16.5: not followed) over text from JavaScript, so every `Cmd.task` over `Http.request`
   and every `Http.send` whose answer holds a list is rejected `need`, approximately — Conduit's nineteen.
   Change 5's words on the decoder's `Js` (the array `JSON.parse` makes is new and nobody else's) and a class
   for `Expect`'s callback would clear them.
   *Answered 2026-10-12 (the manager):* Change 5(a), ownership words on `foreign` (approved by the owner), is
   the next slice, 3e, together with following the decoder stored in `Expect`.
3. **View events** (P6): O6, now that the view-event rule is the only `payload` rejection.

---

## 24. Slice 3e — ownership words, and the decoder in `Expect` (normative from 2026-10-12)

*Amends §4.4, §6.1 item 2, §15 decision 6, §16.5, §16.8, §16.11, §18.6 and §20.9. Sections 1–23 keep their
numbers and text; where this section changes a rule, it wins. Research 81 measures it.*

### 24.1 The decisions it builds

- **Change 5(a)** (the owner, 2026-10-12): *ownership words on `foreign` declarations, in core and the
  platforms only — the only packages that may write `foreign`.* A signature in those packages may say what a
  call does with each argument and what it returns, and the checker takes the words for the declaration's
  summary (§16.2), which no body shows.
- **Change 5(b) is not approved**: no ownership words on a user's declarations. The checker infers every beni
  declaration of a user package from its body, as it did, and a word written there is refused (§24.4).
- **A `foreign` that carries no words gets the thesis's row** (Table 3.2's `foreign` row): it escapes every
  argument and returns `⊤`. §15 decision 6 kept §6.1 item 2's narrowing — a `foreign pure` read and kept
  nothing — *until every `foreign pure` that handles a cell in core and the platforms has its words*; this slice
  writes them (§24.8), so the narrowing is withdrawn, as §14 question 6 said it would be.
- **HTTP decoders are followed** (the manager's answer to §23.12 item 2): the function an `Expect` holds is
  called where `Http` calls it, so a tagger's payload holds what the decoder returns (§24.9).

### 24.2 The words

A word says one fact of §16.2's summary. Each stands in front of the type it describes.

**On a parameter** (thesis Change 5: "`unused`, `borrowed`, `aliased`, `escaped` or `consumed`"; "is parameter
*i*", which the thesis puts on the result, is written on the parameter as `returned`):

| Word | Meaning | Summary (§16.2) |
|---|---|---|
| `unused` | the call neither reads nor keeps it | no bits |
| `borrowed` | read during the call; not kept, not in the result | `R` |
| `aliased` | read; the result may hold it, or part of it, somewhere | `RA`; `res ⋆ πᵢ`, approximate |
| `returned` | read; the result *is* it | `RA`; `res ε πᵢ` |
| `escaped` | JavaScript may keep it after the call returns | `RE` |
| `consumed` | written in place or given up: every cell at or below it | `RW` deep (`S`, §23.2) |

**On a parameter whose type is a function written out** (thesis: "a function-typed one how often it is called"
and what it is handed):

| Word | Meaning | Summary |
|---|---|---|
| `once` | called at most once, during the call | `calls ≤1`, seen |
| `many` | called any number of times, during the call | `calls many`, seen |
| `owned` | each call is handed values nobody else holds | each supply fresh and owned |
| `escaped` | kept by JavaScript and called later: what it captured escapes | `RE`, `calls many`, unseen |
| `returned` | the result is what it returns | `res ε cb_j` |
| `aliased` | the result may hold what it returns | `res ⋆ cb_j`, approximate |
| `unused` | never called, not kept | `calls 0` |

Without `owned`, what a call of it is handed is borrowed (`supply ⊤ borrowed`): the host may still hold it.

**On the result** (thesis: "a result `fresh`, … `escaped` or `unknown`, and whether it is exclusive"):

| Word | Meaning | Summary |
|---|---|---|
| `fresh` | made by the call; nobody else holds it | `res ε fresh₁{lost}` |
| `exclusive`, with `fresh` | and no cell inside it is held twice (§18.2) | `res ε fresh₁` |
| `escaped` | made by the call, and JavaScript keeps it too | `res ε esc₁{lost}` |
| `unknown` | anything | `res ε ⊤` |

**On a `foreign type`**: `crossing` — a value of the type holds no list and no function, so it carries no cell
(§4.4, thesis §3.1's mode crossing). `pub crossing foreign type Event`. With `equatable` it comes first,
`pub crossing equatable foreign type T`, never after (`check/bad/core/CrossingAfterEquatable`).

**What is not written.** A declaration that carries a word anywhere is read entirely from its words: a parameter
with none is `escaped` (a function-typed one is kept and called later), and a result with none is `unknown` —
unless a parameter is `returned`, when the result is exactly the `returned` parameters. What a word leaves out
is the worst case, never the best: no default is optimistic.

A word on a parameter or a result whose type crosses (§4.4) is allowed and says nothing the type does not.

### 24.3 The syntax

```
Signature := Owned (',' Owned)* '→' Owned                  -- a top-level signature of a function
Owned     := OwnWord* Product
OwnWord   := 'unused' | 'borrowed' | 'aliased' | 'returned' | 'escaped' | 'consumed'
           | 'once' | 'many' | 'owned' | 'fresh' | 'exclusive' | 'unknown'
Foreign   := 'crossing'? 'equatable'? 'foreign' 'type' upper_ident lower_ident*
```

```elm
pub join : borrowed List String, String → String
pub foreign pure from : returned a → Value
pub foreign pure pure : once returned sync (⊤ → a) → a
pub foreign impure array : aliased elements → fresh Value
pub crossing foreign type Event
```

The words are contextual, as the rung and `sync` are (`language.md` §5.4): a word is one only in a top-level
signature, in front of something that starts a type — `borrowed List a`, `borrowed a`, `borrowed (a, b)` — and an
ordinary type variable everywhere else (`unknown → a` names a variable). They are erased by lowering: the
type, the interface, the emitted JavaScript and every check but this one are what they were without them.

*Rejected:*

- **A clause after the type** (`join : List String, String → String owns 1 borrowed`), like `where`: it numbers
  the parameters, and a reader matches numbers to positions by counting commas.
- **Parentheses**, as `sync` takes (`borrowed (List String)`): `sync` needs them because it marks one arrow
  inside a type; a word describes the whole parameter, so it needs no delimiter, and `List` binds as it does
  anywhere.
- **"Is parameter *i*" on the result** (`→ is 1 a`), the thesis's spelling: a number again. `returned` on the
  parameter says the same thing in place, and on a function-typed parameter says what the thesis's `cb_j` says.
- **Symbols** (`&`, `!`, `↑`) as in Rust or OxCaml: beni's notation is symbols for operators and words for
  meanings, and these are meanings a reader of core should not need a table for.

### 24.4 Where a word may stand, and what is refused

A word may be written in the signature of a top-level declaration — a `foreign` value or an annotated beni
value — of a package that may write `foreign` (core, and a package whose manifest says `"platform": true`,
`boundary.md` §2): the wall `sync` has (`language.md` §5.4, R47-4). A beni declaration of core or a platform
whose body is written over `Js` — `String.join`, `Debug.toString`, `Schema.print` — is `foreign` in all but form:
its body calls JavaScript the checker cannot see into, which is why thesis Change 5 gives "the core library's
functions over `Js`" the same words. Its summary is its words, and its body is still walked for its own demand
lines (§24.5). *Decided 2026-10-12 (the manager):* this reading stands — thesis Change 5 lets "the core library
and the platforms … assert a summary that a body cannot show" (its reasons A2, A6, A10), and the owner's 5(a) is
"core and the platforms only", which is the package wall, not the `foreign` keyword (§24.11 item 3 answered).
*Decided 2026-10-12 (the owner):* keep the words on the thirteen, with a change-detection guard: the code each
worded declaration was justified by reading is pinned by a hash, and the build fails when it changes (§24.6).

Refused, as `misplaced_ownership_word`, reported by lowering, and the word dropped (the declaration otherwise
lowers as written):

| Reading | When |
|---|---|
| outside a platform | any word in a package that may not write `foreign` — **Change 5(b)**: the checker infers a user's declaration from its body |
| nested | a word anywhere but in front of a parameter of the signature's outermost arrow or its result — inside a type, or on a value that is not a function, which every reader shares and nothing makes per call |
| not a function | `once`, `many` or `owned` on a parameter whose type is not a function written out |
| on the result / on a parameter | a result word (`fresh`, `exclusive`, `unknown`) on a parameter, or a parameter word (`unused`, `borrowed`, `aliased`, `returned`, `consumed`, `once`, `many`, `owned`) on the result |
| impossible | two words that cannot both hold: a word twice; `unused` or `borrowed` with any other; `aliased` with `returned`; `consumed` on a function; `once` with `many`; `owned` without `once` or `many`; two of `fresh`, `escaped`, `unknown`; `exclusive` without `fresh` |

`crossing` is read only directly in front of `foreign` (or `equatable foreign`) and is refused outside a
platform with the same code.

### 24.5 How the checker reads them

- **A declaration with words** has the summary its words give (§24.2), marked asserted, printed with `(words)`
  after it (§16.11). For a beni declaration the words replace the summary read off its body; the body is still
  walked, once, for the demand lines a report on its module prints.
- **The rows the checker asserts itself** keep precedence: `core/List`'s primitives (§16.8, §18.5, §22.5),
  `Dict.focus` (§20.8), `Hosted`'s send positions (§23.3) and the program constructors' entry rows (§20.2). Their
  facts — an element path, a taken supply, `K`, a send position — are finer than the vocabulary can state, so
  those declarations carry no words.
- **A `foreign` with no words** has the thesis's row: every parameter `escaped` — its cells join Esc at the call,
  and a function value handed to it escapes what it captured (§18.6) — and the result `⊤` unless its type
  crosses. The rung does not change it. §6.1 item 2 and §16.5's "keeps slice 1's rule" for a `foreign` without
  words are withdrawn.
- **A `crossing` foreign type** crosses in §4.4's sense: a value of it carries no entries, so a `⊤` it is read
  from does not stand for a list.

### 24.6 The trusted surface

§20.9 gains every declaration with words: each is privileged code whose wrong word is a correctness bug, as an
asserted row is (thesis §6.5). Each word is justified by reading the sibling's export, or the `Js` operations
the body is compiled to (§24.8), and **each annotated declaration is pinned by a test program** whose verdict
depends on its row: `tests/corpus/ownership/trusted-surface.txt` lists every one with the fixture that pins it,
and a black-box test fails when the ownership dump of core or a platform prints a `(words)` summary that the
list does not name, or the list names a fixture that does not exist or does not mention the declaration.

*Amended 2026-10-12 (an adversarial review of PR #73).* **A pin must notice the word moved the unsafe way.** Each
row of `trusted-surface.txt` also names its *flips*: the declaration's words moved toward the optimistic end — an
argument claimed less of (`aliased` → `borrowed`, `escaped` → `borrowed`, `many` → `once`, `borrowed` → `unused`), a
result claimed more of (`unknown` → `fresh`, `returned` → `fresh`). A hidden, test-only flag, `beni dump
--stage=ownership --ownership-flips=<Module.name:slot:from>to>|…`, runs the pass once as written and once per flip
and prints whether each changes the report; `check_test.zig` runs every pinning fixture under its rows' flips and
fails unless every flip changes it — so the fixture's golden would fail were the word wrong that way. A row whose
words have no unsafer neighbour a verdict can see says `-` with the reason beside it: `unused` is the bottom of the
order and `fresh exclusive` the top; `crossing` is the unsafe end already; a one-argument function's `borrowed` read
happens at the call and is no later use, so `unused` is not observable there.

*Amended 2026-10-12 (the owner's guard).* **The code a word was justified by is pinned.** `tests/corpus/ownership/word-bodies.txt`
lists every worded declaration — the thirteen beni bodies over `Js` and the `foreign`s — with a hash of the code its
words were read off: for a beni declaration its signature and definition as they stand in the `.beni` file, for a
`foreign` its sibling's export (`export const name = …`, or the `const` an `export { x as name }` names, to its
closing `;`, and the helpers in the same file it calls, such as `Js.js`'s `args`), each folded to single spaces and hashed (SHA-256, as the run hashes are). `check_test.zig` fails when one changes, saying to
read the code again, re-justify the words in §24.8 and update the pin; and fails when a worded declaration has no
pin. *Why the source text and not the BIR*: the text is what the justification read, and nothing but an edit of
that declaration moves it — not an edit elsewhere in the file, not a change to lowering or to the instruction set,
which would move every BIR hash at once and train editors to update pins without reading; folding whitespace lets
the formatter re-lay a body without a false alarm, while a changed comment inside it still alarms, on the safe
side. A `crossing` type has no body and is not pinned. The helpers a body calls in its own file are pinned beside
it — `Js.js`'s `args`, `Node.js`'s `spine`, `String`'s `elements`, `Debug`'s `logAs` and `toStringAs` — but not
transitively: the schema engine behind `Schema`'s four, and `Debug`'s printer below `toStringAs`, move no pin, and a
change there relies on review.

The tests pin that each row exists and that a verdict depends on it in both directions where one can; they do not
prove it true. **A word on a
beni body is not compared with that body**, deliberately: every such body goes through `Js.call` or `Js.get`, whose
honest row escapes everything, so the body's own summary is always worse than the words — which is why the words
exist. Reading the sibling or the `Js` operations, as §24.8 records, is the check, as it is for a `foreign`'s rung.

### 24.7 The report

A summary read from words prints `(words)` where an asserted row prints `(asserted)`, and a `crossing foreign type`
prints a line of its own, `crossing Event (words)`, after its module's demand lines. The note `(no summary: M.f)`
(§16.11) no longer names a `foreign`: every `foreign` has a summary, from its words or the thesis's row.

*As built*, two notes on what the report shows. A need rejection (§23.5) whose only failing provenance is a list
the checker cannot place — `⊤`, from JavaScript, or an approximate step — is approximate and says so: "which may
hold a list the checker cannot place — from JavaScript, or through a call it does not see into". A function slot
prints as its parameter and path, `π1.expect#Expect.1 calls ≤1`, and what it returns as `cb(π1.expect#Expect.1)`; a
lambda a result carries prints `λ` at its path (§24.9).

### 24.8 The annotated surface

Every annotated declaration, and the reading of the code that justifies each word. `tests/corpus/ownership/trusted-surface.txt`
names the fixture that pins each (§24.6).

| Declaration | Words | Why |
|---|---|---|
| `Js.from`, `Js.to` | `returned a → Value`, `returned Value → a` | `Js.js`: `(v) => v`, compiled to nothing |
| `Js.same`, `isNull`, `isUndefined`, `isNullish` | `unused` arguments, `fresh` result | `a === b`, `v === null`, `v == null`: a reference compared, nothing dereferenced, a boolean made |
| `Js.typeOf`, `Js.typeIs` | `unused Value` (`borrowed name`), `fresh` | `typeof v` reads the value's tag, not its contents |
| `Js.fingerprint` | `unused k, unused order → fresh name` | the compiler writes the type's identity in place; `x` is evaluated and not read (its doc comment) |
| `Js.array`, `Js.object` | `aliased … → fresh Value` | `args(xs)`, `Object.fromEntries(…)`: a new array or object holding the elements or field values |
| `Js.each` | `escaped Value, many (Value → ⊤) → ⊤` | `for (const x of xs) f(x)`: the iteration protocol is the host's, so the iterable is taken to escape; `f` is called during the call, any number of times, and not kept |
| `Js.throw` | `escaped Value → fresh a` | `throw v`: JavaScript keeps what is thrown; the call never returns, so what it returns is the call's own |
| `Js.ref`, `Js.read`, `Js.write` | `escaped a → fresh Ref a`; `borrowed Ref a → unknown a`; `borrowed Ref a, escaped a → ⊤` | `{ v }`, `r.v`, `r.v = v`: what a cell holds can be read by anyone holding it, at any time later, so what goes in escapes and what comes out is unknown |
| `Js.pure`, `Js.suspending` | `once returned sync (⊤ → a) → a` | `body()`, compiled to the lambda's body |
| `Js.finally` | `once returned sync (⊤ → a), once sync (⊤ → ⊤) → a` | `try { return body() } finally { cleanup() }` |
| `Js.catchIf` | `once returned` body, `once` test, `once returned` handler | `try { return body() } catch (e) { if (!test(e)) throw e; return handler(e) }`: each called at most once, the answer the body's or the handler's |
| `String.join`, `String.fromList` | `borrowed List …` | `Array.prototype.join` on the list's array or its `$plain()`, which keeps nothing |
| `String.split`, `words`, `lines`, `toList`, `indexes` | `→ fresh exclusive List …` | `split`, `Array.from`, `filter` and a `Js.array` the body fills make a new array of strings or numbers, which no cell is held twice in |
| `Schema.print`, `printWith` | `borrowed Schema e a, aliased a → fresh Result …` | the engine reads the value and `JSON.stringify` reads what it made; an issue it answers may hold the value it was handed (`Issue.input`). Re-read 2026-10-15: a compiled schema's encoding worker (`schema.md` §6, *A statically known schema runs compiled*) reads the value and builds the host object the same way, and its issues hold the value as the engine's do |
| `Schema.parse`, `parseWith` | `borrowed Schema e a, String → unknown Result …` | `JSON.parse` makes new values, but the answer holds what the schema's own mapping, injection and conversion functions return, which may be anything (thesis §6.5). Re-read 2026-10-15: a compiled schema's decoding worker also returns its conversions' answers, so the answer is still unknown |
| `Debug.toString` | `borrowed a → String` | `toStringAs` walks the value; the set of objects being printed holds each only while it is printed |
| `Debug.log` | `String, returned a → a` | prints `toStringAs` of the value — a string, so the console keeps no reference to the value — and returns the value |
| `Hosted.keyOf` | `String, aliased k → fresh Key` | `Hosted.js`: `({ t: type, c: compare, v: value })`, a new object holding the value |
| `Html.Event` | `crossing` | a DOM event, made by the host: no beni value is ever put in one |
| `Node.print`, `Node.exitWith` | `→ fresh Program` | `Node.js`: `({ code, out })`, a new object of a number and a string |
| `Node.printLines` | `borrowed List String → fresh Program` | `items.join("\n")` on the list's array |
| `Ssr.render` | `borrowed Html msg → String` | `Ssr.js`: `html.t`, the markup's text |

**Without words, by choice.** Each `foreign` that handles only values that cross — `Js`'s bit operations and `rem`
(numbers), `regExp` (two string literals), `development`, `maySuspend` (read by the checker as a static bit, §23.3),
the platforms' `Dom`, `Browser.Events` and `Html.targetValue`/`targetChecked` (strings, numbers and a `crossing`
event) — has nothing a word could say. Each whose honest row is the thesis's — `Js.global`, `get`, `set`, `call`,
`apply`, `construct`, `at`, `setAt`, `instanceOf`, `method` (a getter, a method or a constructor of the host may keep
what it is handed), `Io.finish` and `Io.startRead` (kept by the runtime) — keeps the default, which is that row.
`Hosted.compareKeys` only reads, but only the runtime's own key comparisons reach it, where every key has already
escaped with its command (§20.4): no verdict depends on its row, so it keeps the default, which is the safe side. `core/List`'s primitives, `Dict.focus`, `Hosted`'s send positions and the program constructors
keep their rows in the checker (§24.5).

### 24.9 The decoder in `Expect`

`Http.request r` calls the function `r.expect` holds — `transfer`'s pattern `(Expect accept read)` binds it and
calls it on the answer — and a `Cmd.task` tagger is handed what that function returns. Two things the walk did not
follow stood in the way: a function stored in a structure, and a lambda returned by a call (§16.5: no class). Both are
built, for the declaration's own frame:

- **Function slots.** A call of a function stored at a path `q` of the declaration's parameter `πᵢ` — `read` above,
  `π7#Expect.1` — is a call of the *slot* `(i, q)`, recorded as a call of a function parameter is (§16.4 item 4):
  its count, what each call is handed, what it returns (`cb`), and whether it is seen. The summary lists its slots
  after its parameters; `funs`, `supply` and `cb` name a slot by number. At a call, the actual for a slot is the
  argument's value at `q`; the caller's own parameter or slot there takes the callee's facts (`request`'s
  `π1.expect#Expect.1` from `transfer`'s `π7#Expect.1`), and a function value there is called through its class.
  Not in a recursive group, whose rounds would number the slots apart, and not inside a lambda.
- **Carried lambdas.** A lambda the result holds keeps its class in the summary, with what each capture held in the
  declaration's vocabulary, when calling it needs nothing but its result and its reads: its class writes nothing,
  escapes nothing, relies on nothing (§18.4) and is not once, and no capture holds a function value. Where the call
  is instantiated the lambda is a closure of the caller, its captures bound to what the caller passed; its calls of
  the declaration's function parameters go to what the caller passed there, which leaves the caller's sight — the
  checker does not see what the lambda hands it. A top-level value's lambda is carried when it captured nothing.

Soundness rests where it did: a writing function stored in a structure was reported `pending` where it was stored
(§16.5), so a slot needs only the result; a carried class that writes or escapes is not carried and its call stays
§6.1's.

*Amended 2026-10-12 (an adversarial review of PR #73).* **A `need` with no class is rejected.** A callee that
edits what a function parameter or slot returns (`need`, §16.2) is checked against the actual's class; where the
checker knows none — a function read out of a `Ref`, from JavaScript, out of a structure — or a class has no
summary, nothing shows it returns a list it owns, and the edit is rejected `need`, approximately (`NeedUnknown`).
Before, such a call checked nothing and the callee's write was accepted outright — on master too, for a function
parameter.

*As built:* `Http.request`, `get` and `post` return `cb(π1.expect#Expect.1)`, and Conduit's `Api.send` returns
`#Ok.0` what its parser returns and `#Err.0` fresh errors — but also, at `#Err.0#Failed.0#BadRequest.0`, a `⊤`:
`expectStringResponse`'s decoders forward the request's `Problem` from the answer, and the answer comes back through
`Task.callback`, from JavaScript, when the request fails in flight (`Http.wait`'s `Failed (Response String)`). So
Conduit's 19 `need` lines and 2 `unknown` sends stand, with that cause, approximately (research 81). A decoder that
does not forward a failure's list is followed to an owned payload (`HttpAnswer`). `Http.send`'s decoder is called
inside the body `Cmd.task` runs, a lambda, where slots are not built: its tagger stays §6.1's.

### 24.10 Testing

| Fixture | Pins | Expected |
|---|---|---|
| `fmt/OwnershipWords` | §24.3 | the words kept in order, one space after each; `crossing`; a broken signature as it would be without them |
| `check/bad/OwnershipWordOutsidePlatform` | §24.4, Change 5(b) | `misplaced_ownership_word` at the first word of a user's signature |
| `check/bad/core/MisplacedOwnershipWord` | §24.4 | every reading: nested, on a value, not a function, a result word on a parameter and the reverse, each impossible pair |
| `ownership/ForeignNoWords` (`tests/platforms/page`) | §24.5 | a list handed to a `foreign` without words, and one a handler handed to it captured: `escaped`; `String.join`'s read: accepted |
| `ownership/Words` (node), `ownership/core/JsWords`, `ownership/JsPure`, `ownership/WordsBrowser` (browser-direct, browser-tea) | §24.8 | each annotated declaration's row, against what the default would give |
| `ownership/CarriedLambda` | §24.9 | a list a returned lambda captured, written before the lambda is called: `captured`; after: accepted |
| `ownership/HttpAnswer` (browser-direct) | §24.9 | a decoder whose answer is owned: no line; Conduit's forwarding decoder: `need`, approximately; a top-level answer: `need`; the model's list: `need` |

and `check_test.zig`'s four tests of `trusted-surface.txt` (§24.6).

### 24.11 Open questions

1. **The HTTP failure.** `Http.wait` resumes its fiber with a `Step` whose `Failed` carries a whole `Response String`,
   though only `Timeout_` and `NetworkError_` ever travel there; through `Task.callback` it is `⊤`. Measured on the
   branch with a two-constructor failure in its place — no change of behaviour or API — every one of Conduit's 19
   `need` lines and 2 `unknown` sends is accepted (research 81 §4). The other way is a row for the fiber runtime's
   resume (thesis A2): `Task.callback`'s result is what its `Resume` is handed, given up. Neither is built: the first
   reshapes platform code to clear a check, which is the owner's call (CLAUDE.md rule 10); the second is a slice of
   the task runtime's rows.
   *Answered 2026-10-12 (the owner):* the first. Rule 9 wants each failure typed precisely, and the loose type was
   what let the checker — correctly — assume a response from JavaScript could reach the decoders. `wait`'s `Step` is
   `Failed Failure` with `type Failure = TimedOut | Unreachable`, read back as `Timeout_` and `NetworkError_` where
   the answer is read (`boundary.md` §9.8.12 (c), as amended); no behaviour, API or transcript changes. Measured:
   Conduit is 29 lines, 24 accepted, 5 rejected, all `payload` (O6), on both TEA platforms — its 19 `need` lines
   are gone and its 2 `unknown` sends are accepted `call`. In the corpus, `ApiLogin`'s `GotName` and
   `HttpMultipart`'s `Got` lose their `need` line, and `HttpCancel`'s and `HttpProgress`'s sends go from `unknown`
   to accepted `call`, on both platforms; nothing else moves. `HttpAnswerEdited` pins Conduit's shape. The other
   `need` lines on TEA targets stay, each for a cause of its own: a request made inside the work's own lambda
   (`ApiItems`, `ApiLogin`'s `GotToken`, `HttpAnswer`'s `Fetched`), requests run inside a lambda handed to `Task`'s
   combinators (`RaceTwoServices`, `TimeoutAroundRequest`), `Http.send`'s decoder (`ValueCommands`) and
   `Random.generate` — the slots-inside-a-lambda limit of §24.9 and research 81 §4's rows. A row for
   `Task.callback`'s `Resume` is still the general answer for other callbacks.
2. **Words on core's other functions over `Js`.** Only declarations whose rows some verdict depends on carry words.
   `Ref`, `Deferred`, `Task` and the schema engine are inferred over the `Js` words; their summaries escape what they
   hand to `Js.call`, honestly. A row per public function of those modules (thesis §6.5's "several dozen to a hundred
   and fifty") is the trusted surface's next step, measured against what it clears.
3. **Interpreting 5(a).** The words stand on core's and the platforms' functions over `Js` as well as on their
   `foreign`s (§24.4), because the thesis gives those functions the same words and they are `foreign` in all but
   form; the owner approved words on `foreign` declarations in core and the platforms. If that is read narrowly,
   the thirteen beni declarations with words — `String.join`, `fromList`, `split`, `words`, `lines`, `toList`,
   `indexes`, `Debug.log`, `Debug.toString`, `Schema.parse`, `parseWith`, `print`, `printWith` — lose them and are
   inferred, escaping what they hand to JavaScript.
   *Answered 2026-10-12 (the manager):* the words stay on all thirteen — thesis Change 5 lets the core library and
   the platforms assert a summary a body cannot show (A2, A6, A10), and 5(a) is "core and the platforms only"
   (§24.4). Item 1 goes to the owner (rule 10) and is not built.
   *Decided 2026-10-12 (the owner):* the thirteen keep their words, guarded by the body hashes of §24.6.

## 25. Slice 3f — a prepend copies, `map` across types, and the default read on the other path (normative from 2026-10-12)

*Amends §3.1, §3.2, §6.1 item 3, §6.2, §7.2, §16.4 item 6 and §16.8. Sections 1–24 keep their numbers and text;
where this section changes a rule, it wins. Research 85 measures it on the first external port (research 82) and
the rest.*

### 25.1 The decisions it builds

- **A prepend is not an in-place demand** (the manager, 2026-10-12, on the owner's decision of 2026-10-11 that
  `[ x, …xs ]` copies: `language.md` §6.8, *`[ x, …xs ]` copies*; `backend.md` §4, *The claimable head*, its
  amendment). Change 1 was written when a prepend could claim room in front of its base; with no such room, a
  prepend builds a new array and cannot make an old version observable, so it must not consume its base. The
  forms that append — `[ …acc, x ]`, `[ …a, …b ]`, `++`, `List.push` — keep consuming their base. This departs
  from thesis Change 1's "`[ x, …acc ]` also consumes `acc`", by that decision.
- **`map`'s identity promise is named only where it can fire** (thesis §3.8, the paragraph on `map`): the type
  filter of §16.4 item 6 is applied as the thesis states it. Research 82's R4 had it applied, but §6.1's "may be
  one object" answered *yes* for any two record types.
- **The default read on the path where no edit happened** (research 82's R5): the narrowest path-sensitive rule
  that accepts `m ▷ Maybe.map (edit model _) ▷ Maybe.withDefault model` and stays sound (§25.4).

### 25.2 A prepend copies

A **prepend** is a construction (§3.2) whose items all precede its one spread, which is last:
`[ x₁, …, xₖ, …xs ]` with k ≥ 1; and a call of core `List.cons`. It is **not a demand**:

1. **Its base is read**, at the construction's point (§3.3): every item and the base are used there, as the
   operands of any consumer are (§7.1). A copy reads what it copies.
2. **Its result** is a new cell made at the construction — `site(ι)`, whose contents are exclusive when the
   items are, are apart from one another and from the base's elements, and the base's contents are (§18.2's
   table) — **and the base's own cells, approximately**: core's `cons` re-conses onto a view whose previous
   element is the one put in front, answering a header over the base's own array (`backend.md` §4, the two
   re-cons rows), so the result may be the base. The text does not show when that happens, so those entries are
   tagged with the construction, and a rejection through them is the `call` cause (§16.4 item 7). The base's
   elements are the result's elements, exactly. The base's condition is not lowered: nothing is stored into it.
3. A construction with anything after its first spread — `[ x, …xs, y ]`, `[ x, …xs, …ys ]` — still appends onto
   its base (it lowers to `List.cons x (List.append xs …)`, `language.md` §6.8), so it is §3.2's demand,
   unchanged. A re-built `[ h, …t ]` after `[ h, …t ]` stays an alias of the scrutinee (§3.2), exactly.

`List.cons`'s asserted row (§16.8) becomes: π₁ `A`; π₂ `RA`, π₂`[*]` `A`; `res ε = fresh₁, π₂`,
`[*] = π₂[*], π₁`, with `fresh₁`'s condition `excl π₁, excl π₂, sep π₁ π₂[*]`. Its two provenances at `ε` make
a demand through it approximate, as item 2 says of the construction.

*Amended 2026-10-12 (slice 3g, §26.3):* item 2's base cells are left out when the front item is a list made after
the base.

**The backend agrees** (checked for slice 3f, research 85 §2). Every prepend is emitted as a call of
`List.cons`, which is `pushFrom` onto a new `[ x ]`, one `concat` into a new array, or a re-cons that answers a
header over the base's array and writes nothing (`core/List.beni`). A function's result `[ f x, …go rest ]` is
the tail-modulo-cons loop (`backend.md` §8), which pushes onto its own array and closes with `List.close`: the
tail's elements copied after the loop's array, or the tail itself when the loop built nothing — never a write of
the tail. A prepend onto a loop's accumulator is `List.cons` at each step, and a pattern's suffix re-built in a
walk over scalar views is an offset (`list - 1`), which writes nothing. So no prepend writes an array that
existed before it, on any platform, today. **Slice 5 must keep it so**: a prepend lowered in place on
`browser-direct` would be a correctness bug, since this rule accepts programs that read the base afterwards.
`emit/PrependShapes` pins the shapes.

### 25.3 `map` across types

*Withdrawn 2026-10-13 (§27.4): `map` returns a fresh list, so nothing here is needed; the text is kept as the
record.*

§6.1 item 3's "may be one object" decides the type filter of §16.4 item 6. A record value is one run-time
object of one type, so **two closed records** — their extension chains end in the empty record — **may share
only when they name the same fields, each pair of which may share**. A record with an open row may be any
record, as before. A record against a nominal type of one constructor with one field may be that field (the
release representation), as before; a record against any other type may not share. So
`List.map explosions Explosion.toObstacle`, from `{ center, size, ticksLeft }` to `{ n, e, s, w }`, is a new
list, and `List.map items (λi → i)` from a record type to itself keeps π₁.

*Soundness.* A record value is made by one record literal or update, at one type. Two closed record types with
different field names do not unify, so no value has both; with the same names, one value at both types holds one
value at each field, which must then be one object at both field types. A function `Explosion → Obstacle` can
therefore never return what it was handed, and `map` returns its input only when every result was its element
(`identical`, `core/List.beni`).

### 25.4 The default read on the other path

§7.2's branch contexts gain one shape that is not a `case` in the text. A call

    Maybe.withDefault (Maybe.map m f) d

where `Maybe.withDefault` and `Maybe.map` are core's, **`m` and `d` are variable paths** (a local, or a field or
tuple path of one: §7.1's references) and **`f` is a lambda written there** — `handleInput model _` is one, by
lowering — **or a top-level value**, is walked as a `case` of its own with two arms. The evaluation of
`Maybe.map m f` — `m`, `f`, the call, and every demand the call makes through `f` — is in arm `Just`; the use of
`d` at `withDefault`'s call is in arm `Nothing`. What is read after the whole expression is ordered after both
arms, as after any `case`.

*Soundness.* `Maybe.map` (`core/Maybe.beni`) calls `f` only when `m` is `Just`, and answers `Nothing` exactly
when `m` is `Nothing`; `Maybe.withDefault` answers `d` exactly when its argument is `Nothing`. So on a run where
`f` was called, `d` is discarded unread, and on a run where `d` is the result, `f` was not called. The operands
are restricted so that the arms hold nothing else: evaluating a variable path, a lambda or a top-level value
reads and writes no list, while a call in `f`'s place (`Maybe.map m (handler model)`) would edit whatever `m` is,
a call in `m`'s place would edit before the match, and an expression in `d`'s place would read the edited model
on the `Just` path. Those forms are walked as ordinary calls, and rejected where the old value is read after an
edit (§25.6). The fact rests on the two bodies in `core/Maybe.beni`: it joins the trusted surface (§20.9) as a
rule of the checker, and a change to either body must revisit it.

Not built: `Maybe.andThen`, `Result.map` with `Result.withDefault`, and a `case` on `Maybe.map`'s result. The
argument is the same; no measured program needs them (research 85 §4).

### 25.5 The report

Unchanged in form. A prepend prints no line; a demand on a value a prepend made names the construction as the
approximate step (`… may hold it through the call at L:C`), as a call with an identity promise does.

### 25.6 Testing

| Fixture | Pins | Expected |
|---|---|---|
| `ownership/Prepend` | §25.2; research 82 R1 (`Helpers` 51), R4 (`Bike` 60); T33 | a prepend and `List.cons` onto a list read afterwards: no line; the suffix re-built after `[ a, b, …tail ]`: its walk writes nothing; a prepend onto `map`'s result: no line; T33's stack: accepted; `[ …s, 0 ]` and `[ x, …s, x ]` with `s` read afterwards: `later-use`; extending a prepend's result with its base read afterwards: `call`, approximate; with the base dead: accepted |
| `ownership/MapAcrossTypes` | §25.3; research 82 R4 | an append onto a map between two closed records: accepted; onto a map from a record type to itself, and from a one-field wrapper to its field: `call`, approximate. *Amended 2026-10-13 (§27):* all three accepted, `map` being fresh |
| `ownership/MaybeDefault` | §25.4; research 82 R5 (`Game` 127) | the pipeline, the lambda and the `case`: accepted; the old model read after the expression, an eager handler, a default that is not a variable, an edit while computing `m`, `Maybe.andThen`: `later-use` |
| `ownership/Differential` | T33 against the Lean model | the prepend form accepted, with no Lean counterpart (the model has no prepend); `t33Pushed`, the model's projection onto a push: kept rejected, copied accepted, as in the model |
| `ownership/Recursion`, `ownership/Split` | §25.2 through a recursion and a split | `appendTo` reads `ys` and may return it; `bumpHead` writes its rows, not its spine |
| `emit/PrependShapes` | §25.2, *The backend agrees* | every prepend shape emitted as `List.cons`, the tail-modulo-cons loop ending in `List.close`, or a scalar-view offset: a golden change there must be checked against §25.2 before it is blessed |

### 25.7 Open questions

1. **A prepend of fresh items.** A re-cons needs the item put in front to be the element already before the
   view, so a prepend whose items were all made after its base cannot alias it. In bike-wars that would clear
   `Bike.update`'s `[ frontWall other, …omitLastSections current.trail ] ++ …` and the line it causes in
   `Game.stepGame` (research 85 §3). The domain has no notion of "made after"; not built.
2. **`Maybe.andThen` and `Result`.** §25.4's argument covers them; they wait for a program that needs them.

*Amended 2026-10-12 (slice 3g, §26.8):* item 1 is built for a front item that is a list made after the base
(§26.3). Item 2 is half built: `Result.map` with `Result.withDefault` is §26.4's; `andThen`, of either module, is
**refused** — §25.4's argument does not cover it, because its `f` may answer `Nothing` or `Err` after it ran.

---

## 26. Slice 3g — binders, `?`'s early return, a prepend of fresh items, `Result`'s default (normative from 2026-10-12)

*Amends §5 (the `e?` row), §7.2, §25.2 item 2 and §25.7. Sections 1–25 keep their numbers and text; where this
section changes a rule, it wins. Research 86 measures it.*

### 26.1 A later read resolves to the binding it reads

The Lean reference model found a soundness defect in its own checker (PR #65): with shadowing, a `let` handed the
outer continuation's live set to the inner scope, so liveness took a later read of the outer name for a read of
the inner binding, and the Dead check passed. beni's source refuses shadowing (`language.md` §7), but the
compiler makes bindings of its own. This section is the argument that none of them can make a later read resolve
to the wrong binding in `src/own/`.

**How the checker names a variable.** Never by name. BIR's `local` instruction carries a **local index**,
declaration-relative, which lowering resolved lexically (`Lower.lookupLocal`) when it wrote the instruction.
Every binder — written or compiler-made — gets its index from `Lower.bindLocal`, which appends to the
declaration's `locals` table: the index is the binder's position in it, so **no two binders of a declaration
share an index**, whatever their names. The walk keys every fact about a variable by that index: its value
(`local_av`), its frame and branch context (`local_frame`, `local_ctx`), every read (`Use.local`), every holder
of a demand (`Holder.local`), every capture (`Capture.local`) and the `env` cell of a capture (`Cell.a`). The Dead
check (§8.1 item 5) compares a holder's index with a read's index, in the same frame, at a later point, in a
compatible branch. Liveness is not computed backwards from continuations, so there is no live set for an inner
scope to inherit.

**Why one index is one binding.** BIR is a tree, and the walk evaluates each instruction once per walk of its
frame, so each binder binds its index once. The one re-walk is a local-function group's fixpoint rounds
(§18.7), and `restore` returns `local_av`, `local_frame` and `local_ctx` to the snapshot taken before the first
round. A lambda's or local function's body is a frame of its own, walked once (§7.3); its locals are bound in it
and nowhere else. `Walker.bindLocal` asserts the property under `std.debug.runtime_safety`, the build every test
runs: binding an index already bound in the walk traps. A run of `dump --stage=ownership` over core, every corpus
`.beni` file under each platform, and the applications (research 86 §2) never trips it.

**Every binder kind**, and what lowering makes of it:

| Binder | Lowered to | Indices |
|---|---|---|
| `x = e`, `f a = e` in a block or `let` | `let_def` | one, `bindVar` |
| a pattern in a block or `let` | `let_pattern` | one per variable |
| a statement | `let_stmt` | none |
| `case` arms: `pat_var`, `pat_as`, `pat_record`, `pat_ctor`, `pat_tuple`, `[ x, …rest ]` | patterns | one per variable; a spread's binds a view (§5) |
| lambda and local-function parameters | patterns | one per variable |
| the `_` placeholder (`f a _`) | a lambda over a `fresh` local | one, `freshLocal` |
| `.field` | `λr → r.field` over a `fresh` local | one |
| `(==)` and its relatives | `λa b → a == b` over two `fresh` locals | two |
| `x ← f a` | `f a (λx → rest)` | the written `x`'s, inside the lambda |
| `▷`, `◁` | the call, its arguments lowered in source order | none |
| `{ r \| f = y }` | `record_update` over the resolved `r` | none |
| `[ x, …xs ]`, `++` | nested `List.cons` / `List.append` calls | none |
| `if` without `else` | a `case` on `Bool` | none |
| `e?` | one `try` instruction | none — but it returns from its definition (§26.2) |

Inlining, decision trees for patterns and every other rewrite happen after BIR, on JsIr (`backend.md` §3), and
the checker never sees them. **Slice 5's obligation**: a rewrite of JsIr that duplicates, reorders or renames a
binding the checker reasoned about must keep each read in its order relative to the in-place write it was
checked against.

`ownership/Binders` puts each binder kind between a write and a later read of the original binding — the Lean
probe itself is `nested` — and each is rejected, naming the original.

### 26.2 `?` returns its `Err` payload

Reviewing the binders found a real defect, the last row of the table above. `e?` on a `Result` means "the `Ok`
payload, or return `Err x` from the definition the `?` targets" (`language.md` §6.6). §5 gave `A(e?)` and nothing
else: the early return was dropped, so a definition's summary did not say that its result may hold its
argument's `Err` payload. `pick r = n = r?; Ok (n + 1)` had an empty `res`, and a caller that wrote `xs` while
reading the `Err xs` that `pick (Err xs)` returned was **accepted**: in place on `browser-direct`, the read would
have seen the write.

**The rule.** At `e?` where `e`'s solved type is core's `Result x a`, the walk adds `A(e)` projected on `Err`'s
payload and placed back under `Err` to the result of the frame being walked. That frame is the definition the
`?` targets: a `?` under a lambda is refused (`question_in_lambda`), and a `let` constant is not a frame. The
entries are exact — on that path the payload is what is returned. A `Maybe`'s `Nothing` holds nothing, and a
payload type that crosses (§4.4) adds nothing. Nothing else changes: on the path that continues the payload is
not returned, and on the path that returns nothing after the `?` runs, so the early return adds no read inside
the frame.

`ownership/Question` pins it: `keepsErr`, a local function's `?` (`local`) and a statement `?` (`statement`) are
rejected `alias`. Before, `keepsErr` and `statement` were accepted, and `local` was rejected only because its
result held `xs` at a `⋆` under `Ok`. A `Maybe` and a `String` error stay accepted.

### 26.3 A prepend of a list made after its base

§25.2 item 2 gave a prepend's result the base's own cells, approximately, because core's `cons` may re-cons: it
answers a value over the base's array when the item put in front is `Js.same` as the element stored just before
the base's view (`b[o − 1]`), or as the one in a trie head's slack slot (`reconsed`, `core/List.beni`). Either
element was stored in an array the base shares before the base existed as that view: it is an element of a list
whose array the base's cells name, and the domain names it at the base's cells' `[*]` (a view is its scrutinee's
cells, §5; a callee's view result names its argument, as `List.drop`'s and `tail`'s rows do).

**The rule.** In a prepend `[ x₁, …, xₖ, …b ]`, the result holds its new cell and not the base's when the front
item `xₖ`, the one put directly before the base:

1. has a `List` type — a list is compared by identity, unlike an `Int` or a `String`, which `Js.same` compares by
   value;
2. has at least one entry at `ε`, and each is **exact** and is a `site` (a list literal's new array) or a callee's
   fresh `result` (a summary's `fresh`, never §6.1's assumed one), not escaped (§4.3);
3. is not reached by `A(b)` — closures expanded, approximate and `⋆` entries included.

The base's elements are still the result's elements, exactly, and the new cell's condition is §25.2's.

*Soundness.* By 1 and 2 the item is a new array, made by a literal or a callee, which only its own holders can
name; by 3 no cell of the base holds it, at any path. The element a re-cons compares with is held by the base's
cells, so it is not the item: the innermost `cons` builds a new plain array at offset 0, and each outer `cons` —
a construction's other items — copies too, since a re-cons needs a view past offset 0 or a trie. The rule rests on
`cons`'s body and on `Js.same` being identity on arrays; `cons` is on the trusted surface (§20.9) through §25.2,
and a change to its re-cons conditions must revisit this rule. `List.cons x xs` written as a call keeps its
asserted row (§25.2); only the construction is narrowed.

*Not "made after" in general.* The domain still has no time. An item that is a parameter, a capture, a taken
element, a top-level value or a callback's result may be stored before the view, and so may a fresh list the
base's computation was handed (`ownership/PrependFresh`: `storedBefore`, where the re-cons really happens, and
`baseHolds`).

### 26.4 `Result.withDefault (Result.map m f) d`

§25.4's shape, for core's `Result`: `Result.map` (`core/Result.beni`) calls `f` exactly when `m` is `Ok` and
answers `Err x` when it is not; `Result.withDefault` answers `d` exactly when its argument is `Err`. The same
restrictions hold — `m` and `d` variable paths, `f` a lambda or a top-level value — and the two calls must be one
module's. Both bodies join the trusted surface beside `Maybe`'s.

**`andThen` is refused, in both modules.** `Maybe.andThen m f` calls `f` when `m` is `Just` and answers whatever
`f` answers, which may be `Nothing`; `withDefault` then reads `d` on a run where `f` ran. The same holds for
`Result.andThen` and `Err`. §25.7 item 2 said §25.4's argument covers them; it does not. Accepting them would read
the old model after an edit whenever `f` edits and then fails. `ownership/ResultDefault` pins both, with an `f`
that edits and answers `Nothing` or `Err`, as `later-use`.

### 26.5 The report

Unchanged in form. A definition whose `?` returns a payload prints it in its summary (`res #Err.0 π1#Err.0`); a
prepend whose front item was made after its base names no approximate step.

### 26.6 Testing

| Fixture | Pins | Expected |
|---|---|---|
| `ownership/Binders` | §26.1 | every binder kind between a write and a later read of the original: rejected, naming the original; `distinct`: accepted |
| `ownership/Question` | §26.2 | `keepsErr`, `local`, `statement`: `alias` (the first and last accepted before); `maybeOk`, `stringOk`: accepted; `twoFrames`: each `?` returns from its own definition |
| `ownership/PrependFresh` | §26.3; research 82 `Bike` 56 | a literal, a callee's fresh list, and the Bike Wars line in front: accepted; an item stored in the base first (`storedBefore`), handed to the base's call (`baseHolds`), taken from the base (`elementFront`), an `Int` (`intFront`): `call`, approximate |
| `ownership/ResultDefault` | §26.4 | the pipeline and the lambda: accepted; `andThen` of either module with an `f` that edits and fails, a read after, a default that is an expression, a `Maybe.map` converted first: `later-use` |

### 26.7 Not yet modelled in the Lean oracle

The owner's process rule (2026-10-12): every checker rule a slice adds or changes is modelled in the Lean oracle
(`proofs/ownership/`) or listed here, with the soundness risk of leaving it unmodelled. The oracle's language has
`let`, primitives, closures, calls, recursion, a branch on an integer, traversals and focus (`Syntax.lean`); it
has positional records, copying prepend, typed `Result`, a definition-local CPS lowering of `?`, and the
recursive type `Chain a = End | Link a (Chain a)`. *Amended 2026-10-15 (the oracle review):* it also has
constructions (§3.2: `++` chains and spread literals, the base the first spread, items before it, every later
operand in Disjoint) and list views (a pattern's `…rest` or `…init`, sharing its source's array). A record update
is the record of its base's other fields, which the bridge prints as `{ r | f = y }`. It has no dictionaries,
effects or platform execution. `entry` models one initialization followed by model updates with retained callback environments;
private single-read initialization transfers and captured-local exclusion follow PR #116's contract. It is
a core projection, not a model of the browser's scheduler or rendering. The sync in
`proofs/ownership/Ownership/Sync.lean` models branch-local escapes,
the inductive model and fold container invariants over finite record/list models, and the four Conduit rules:
render/event slot projection, carried zero-capture constructor callbacks, unseen taggers with conditionally
cell-free captures, and forwarding an enclosing callback's owned-result obligation. Each has executable
accepted/rejected projections and a required enumerator control. The model uses integer branches for the
`Maybe`/`Result.withDefault (map …)` case rule and numbered, distinct binders for §26.1 (already enforced since
PR #65). A prepend reads its base and conservatively retains its backing provenance.

The §29 rules have separate required planted holes for arm results, block results, capture creation reads,
conditional fold loans, recursive capture substitution and callee-environment disjointness. The initialization
projection has shared-root, retained-field, transfer-frame and spent-transfer-authority holes; Result/`?` and recursive payload retention each have one.
Every hole must admit a typed interpreter disagreement which the corrected checker refuses, both as a fixed
fixture and through the seed-independent targeted enumeration. The bridge translates Result cases and the
canonical question lowering to actual beni `case` and `?`, and recursive Chains to a native recursive ADT;
entry projections remain counted skips because the bridge does not implement runtime entry delivery.

This is a core model, not a proof that the Zig walk or lowering implements the rules. `DESIGN.md` specifies
its boundaries; `RESULTS.md` records the campaigns and holes. The residual gaps below remain explicit.

**What the bridge's confirmed-unsafe count covers.** Only the writers the core models: `List.set`, `List.push`,
`List.update`'s focus, `List.copy`, the copying prepend, constructions (`++`, spread literals, `List.append`) and
views, on the translated common subset. Views are judged under the most aliased lowering (a live `rest` sees a
push of its source), which is stronger than the shipping runtime's fixed-length view, so view coverage is a
statement about the checker's aliasing rule, not about the shipping view. The count says nothing about the rows
of the table below, nor about the code slice 5 will emit: the bridge's emitted library still uses persistent
lists, and the Lean in-place interpreter is a model of the checker's promise, not of the lowering (thesis
§12.2's stale-read sanitiser, §13.4, is what will judge that). On 2026-10-15 it is one, CK-233, pinned red.

| Rule | Where | What is unsound if the rule is wrong |
|---|---|---|
| The writers `List.pop`, `swap`, `insertAt` and `removeAt` (§3.1, §22.5) | `writerName`, the library rows | a demand on their base whose row is wrong (a `swap` that keeps exclusivity it should lose, an `insertAt` that stores without separation): two holders of one array, one written. The core has none of them; only Zig fixtures test them. |
| The re-cons rule (§3.2, *Not demands*): a list rebuilt in the shape a pattern matched is an alias | `reconsed` | a rebuilt `[ h, …t ]` taken to be fresh while it is the scrutinee's array, then written. The core's views alias their source, but no construction is ever read as a re-cons. |
| The multi-item prepend `[ a, b, …xs ]` (§3.2, §25.2) | `prepended` | as the single prepend's row below. The core's prepend takes one item. |
| A `++` on a generic type, dispatched through hidden evidence | dispatch identities, conservative call | none found: the checker reads it as a conservative call that escapes its operands (`appendable`), not as a construction, and the bridge spells `++` only where its operands are known lists. If slice 5 lowered an evidence-dispatched append in place, this row would become unsound. |
| Record field assignment on owned model paths (`browser-direct.md` §7.4, S7) | the write-set interpreter, not `src/own/` | two holders of one model record, one assigned in place. Neither the ownership checker nor this oracle judges it; it needs its own specification check and differential test before it is emitted. |
| A prepend of a list made after its base (§26.3) | `madeAfter` | a write onto the prepend's result reaches the base through a re-cons the rule took to be impossible. Copying prepend and conservative backing provenance are modelled; offset views and the re-cons identity optimization are absent, so made-after precision cannot be tested faithfully. |
| Ownership words on `foreign` signatures, and the thesis row for a `foreign` with none (§24) | `wordsRow` | a word claiming less than the JavaScript does: a write or an escape the checker does not see. The core has no foreign declarations or JavaScript sibling validation. |
| The decoder followed through `Expect` (§24.9) | `carry`, `carriedEnv` | a decoder's captures held past the call that runs it. No decoder/opaque carrier syntax; captures are tested as ordinary closures only. |
| Runtime entry delivery (§20, §22) | `entryCall` | Initialization transfer, retained callback captures, recursive Chain payloads and finite model preservation are modelled. The renderer, effects, opaque entry rows and unbounded event delivery remain outside the core; their actual runtime retention still needs platform fixtures. The shipping bridge skips every entry projection, so Zig's `entryCall` verdicts (a fifth of the real apps' demands, 2026-10-15) are never compared with the oracle. |
| Owned sends and navigation commands (§23) | `send_class`, `checkSender` | a payload a fiber, a command or the next dispatch still reads after the send, edited in place. *Amended 2026-10-15:* the send rule itself (§23.2, a send is a write of everything it is handed) is not modelled: the core has no send, and its `owned` boundary is the returns-owned rule and retained-callback obligations only. Fibers, navigation capabilities and asynchronous delivery have no core semantics, so runtime payload retention remains untested |
| `Dict.focus`'s destructive read (§20.8) | `assertDictFocus` | two positions of a tree holding one value, both written. List focus is modelled; the core has no tree, keys or dictionary representative separation. |
| Markup/constructor lowering and opaque carrier encodings | markup transfer and summary blocks | Slots and constructor payload retention are modelled as positional records; HTML syntax, wildcard opaque paths, import serialization and actual row/component lowering are absent. Their encoding must preserve the modelled slots and conservative fallback |
| Fold dictionary representatives and recursion | fold/focus summaries | Container ownership is modelled for lists and positional records; no dictionary keys, mutually recursive declarations or unknown/coarsened foreign rows exist in the core, so those implementations and their precision backstops still need Zig fixtures |
| Hidden-evidence initialization and suspension | `initializationTransfer`, dispatch identities/requirements | Private single-read transfer, captured-local exclusion and retained initialization environments are modelled. The core has no hidden evidence parameters, suspension or coarsened foreign summaries; their eligibility guards remain compiler-fixture boundaries. |

### 26.8 Open questions

1. **`List.cons` written as a call** keeps its approximate row; only the construction is narrowed (§26.3). No
   measured program writes the call with a fresh front item.
2. **Fresh items that are not lists.** A record or a constructor value made after the base cannot be `Js.same` as
   a stored element either, but the domain gives a record no cell of its own, so §26.3 cannot see that it is new.
   No measured program needs it.

---

## 27. The identity promises dropped (the owner, 2026-10-13; normative from 2026-10-13)

*Amends §6.1 item 3, §16.4 items 6–7, §16.8, §18.5, §25.1, §25.3 and §25.6. Sections 1–26 keep their numbers and
text; where this section changes a rule, it wins. It supersedes thesis O2 (`docs/thesis/ownership/ch-changes.tex`,
"O2: decided—the identity promises are kept"), whose text is not edited: the thesis records the decision as it
was taken, and this section records its reversal. Research 90 measures it.*

### 27.1 The decision

The owner, 2026-10-13: **drop the list identity promises now.** Until then `List.filter` that kept every element,
`List.map` and `indexedMap` whose every result was `===` its element, `slice` and `take` of everything, `xs ++ []`
and `[] ++ ys`, `concat` and `concatMap` of one non-empty list, and `reverse`, `sort`, `sortBy` and `sortWith` of
fewer than two elements returned **their input itself**. From now on they return a **fresh list**, each at the
cost it had (`language.md` §6.8, *What an operation returns unchanged*; `backend.md` §4, *Identity*, both
amended). The reason: the promises served one consumer, `browser-tea`'s renderer, which skips a `For` whose list
is the same object as at the last render; `browser-tea` is to be deleted once `browser-direct` — which re-renders
from compile-time write sets, not from identity — proves out, and the owner accepts that `browser-tea` skips less
meanwhile. beni has no users, so nothing else is owed.

What the promises cost here is thesis O2's own list: a result that may be its input aliases it (`res ε = {fresh₁,
π₁}`), so an edit of the result's spine while the source is read later — the splices of thesis Table 6.3, a
filtered copy kept beside its source and extended (T52), research 88's S3 — was rejected, approximately, through
the call (§16.4 item 7).

### 27.2 What the checker infers now

Nothing in `src/own/` was added for the change: the bodies changed, and the summaries are read off the bodies
(§16.8: `map` and its family, `filter`, `slice` are inferred). `beni dump --stage=ownership core/List.beni`
before and after:

| Function | `res ε` before | after |
|---|---|---|
| `map`, `indexedMap` | `~fresh₁ ~π₁` | `fresh₁` |
| `filter` | `~fresh₁ ~π₁` | `fresh₁` |
| `slice` | `fresh₁ π₁` | `fresh₁` |
| `take` | `fresh₁ ~fresh₂ ~π₁` | `fresh₁` |
| `reverse` | `fresh₁ π₁` | `fresh₁` |
| `sort` | `~fresh₁ ~fresh₂ ~π₁` | `fresh₁` |
| `sortWith` | `~fresh₁ ~fresh₂ π₁` | `fresh₁` |
| `sortBy` | `~fresh₂ π₁` | `fresh₂` |
| `concat` | `fresh₁ π₁[*]` | `fresh₁` |
| `concatMap` | `~cb₂ ~fresh₁ ~π₁[*]` | `fresh₂` |

Each also loses its `A` on π₁ (and on π₁`[*]` where the result held the input's elements only through the
promise): the parameter is read, not kept. `map`'s and `indexedMap`'s result elements are still `cb₂`, and
`filter`'s, `slice`'s and the sorts' still `π₁[*]` — element identity (`backend.md` §4, invariant 6) is not a
promise this section drops, so an edit *inside* an element of a filtered list still demands the source's element,
as thesis O2 says it must.

`append`'s row is asserted (§16.8) and does not change: π₁ `RAW`; `res ε = π₁`. Its body now copies `xs` when
`ys` is empty and `ys` when `xs` is, so the row's "`[] ++ ys` is the base, not `ys`" (§16.8, *with its decided
change*) is what the body does: before this section the body returned `ys` itself there, which the row did not
name. No in-place write existed for that to break.

### 27.3 What is removed

- **`identical` and `kept`**, `core/List`'s two core-private `foreign`s that carried `map`'s promise, with their
  sibling exports, their two `Operator` entries (`backend.md` §4, *`List.beni`'s loops read and write in place*)
  and their asserted rows (§16.8's table).
- **The exempt comparison** (§18.5) and the **`K`** bit it introduced: no row has `K`, so `noUse` is "no bits".
- `filterFirst`, the loop that walked `filter`'s input without building until the first rejected element, and
  `firstFrom`, which found `concat`'s one non-empty list.

### 27.4 What stays, and why

- **The writers' rows.** `set`, `update`, `swap`, `insertAt`, `removeAt`, `pop` and `push` still return their
  input when they have nothing to write. A writer's result is its input — `res ε = π₁` — whether it wrote in place
  or not; that is the meaning of the row, and making a no-op copy would not change it.
- **Views.** `drop`, `tail`, `view` and a pattern's `rest` share their base's array by representation, O(1)
  (§16.8's `view` row: `res ε = π₁, fresh₁`). `drop xs 0` is `xs` for the same reason.
- **§16.4 item 6's type filter.** It was written with the identity promises as its example, and with none left
  in core it decides no line of any program research 90 measured: a binary with the filter disabled gives the same
  verdict on every line of the 1 299 units of research 90 §2, and the whole of `zig build test-blackbox` passes
  without it: **no test reaches it now.** Only a summary whose result is a coercion through `Js` could make it
  fire, and only core and the platforms may import `Js`, so no fixture can be written for it from a program.
  It is known debt, kept for one reason: it is `instRes` and `applySummary`'s tail, the walk slice 4 is
  changing, and removing it there now would collide with that work. It goes in the first change after slice 4
  lands, unless a platform summary gives it a fixture first.
- **§25.3 is withdrawn.** Two closed records with different fields are no longer told apart by §6.1's "may be one
  object": the rule existed for `map`'s promise (§25.1: "`map`'s identity promise is named only where it can
  fire"), and a binary without it gives the same verdict on every line research 90 measured, as research 85
  §1.2 found of every line but `map`'s. `recordsMayShare` and `closedFields` are removed, and a record against a
  record may share, as before slice 3f — coarser, and sound.
- **Element identity**, at `[*]`, as above.

### 27.5 Testing

| Fixture | Pins | Expected |
|---|---|---|
| `run/ListIndexedIdentity` | §27.1, `backend.md` §4 | the builders' lines `copied` (slice and take of everything, filter of all, reverse and the sorts of fewer than two, map and indexedMap of the identity); the writers' and `drop 0` lines `same` |
| `run/ListIdentity` | §27.1 | the elements passed through `same`; `append xs []`, `append [] ys`, `concat` of one, `concatMap` alone, `sort` of one `copied` |
| `run/ListScalarView` | `backend.md` §8 | `whole at the start` still `same`: the probe returns the list a walk was given without `append`, which copies now |
| `ownership/Conservative` | §27.2 | T52's shape (`filtered`) and `mirrored`'s `reverse` accepted |
| `ownership/Disjoint` | §16.4, thesis Table 3.1's pending row | the held call temporary through a helper of two arms (`forCall`): `call`, approximate; through `List.reverse` (`forFresh`): accepted |
| `ownership/Differential` | T52 against the Lean model | `t52` accepted, the model's copied projection |
| `ownership/MapAcrossTypes` | §25.3, §27.2 | all three appends accepted |

---

## 28. Slice 4 — enforcement (normative from 2026-10-13)

*Amends §1.3, §2.4, §9.2, §13.3, §16.9, §16.10 and §20.2. Sections 1–27 keep their numbers and text; where this
section changes a rule, it wins. Research 89 measures it.*

### 28.1 The decisions it builds

- **An unsafe in-place edit is a compile error** (the owner, 2026-10-11; thesis Change 2): never a silent copy and
  never a slower algorithm. The fix a message offers is an explicit `List.copy`, or a restructuring.
- **Errors only where lists are edited in place** (the owner, 2026-10-12): on every other platform nothing is
  edited in place, so the checker is silent there — no error and no warning. The rule is a property a platform
  declares (§28.2), not a platform's name: `browser-direct` is expected to take `browser-tea`'s name.
- **beni has no users**: no flag turns enforcement off, and nothing is deprecated first.

| Piece | Slice 4 |
|---|---|
| A platform declares that it edits lists in place | **built**: `"lists": "in-place"` (§28.2; `boundary.md` §5.2) |
| The pass in `check` and `build` | **built**, on such a platform only, after the module check (§28.3) |
| Summaries across a module boundary at build time | **built** as a *summary block* per module, in the cache entry and the checked core (§28.4); not yet in the interface record (§16.10, §28.11) |
| Rejections and pending lines as errors | **built**: every one, exact, approximate and position alike (§28.5) |
| Messages in thesis Chapter 8's shape | **built**: three places, a consequence, a `List.copy` fix and a verdict line (§28.6) |
| Core and the platforms checked once, when beni is built | **built**: the checked core carries their blocks, and refuses an in-place chain with a rejection (§28.7) |
| The stability policy (thesis §8.5) | not started (§28.11) |
| In-place code | slice 5 (§13.4) |

### 28.2 Which platform

A platform package's manifest may say

```json
"lists": "in-place"
```

and it is then an **in-place platform**: the code it emits may write a list's array where §8's verdict accepted
the demand (slice 5), so an accepted demand is a promise the build relies on and a rejected one is a program the
build cannot compile. `"in-place"` is the only value; any other is the chain's exit-2 `malformed` failure, as any
manifest field of the wrong shape is (`boundary.md` §5.3). The field is inherited first-found down the chain like
every other (`boundary.md` §9.1), so a platform layered on an in-place platform is one. `browser-direct` declares
it; `browser-tea`, `browser`, `html` and `node` do not, and `tests/platforms/*` do not.

The entry rows of §20.2 read the same property, of the package that declares the program constructor (§20.2's
amendment).

*Amended 2026-10-15 (the owner's decision that `List` is a plain array; `backend.md` §4, *The representation: a
plain array*):* with no trie, a platform that is not in-place has no cheap write. There, every writer and every
construction copies its base, O(n). Whether the property should stay a platform's, or become the language's so
that the checker runs and lists are edited in place on every platform, is open with the owner. The question and
the recommendation are in `backend.md` §4, in the same subsection.

*Amended 2026-10-15 again (the owner, §30):* the question is closed. The property is the
language's, and `"lists"` is withdrawn. §28.3's pass runs in every `check` and `build`, on every
platform and with no platform. §28.7's rule that a platform's modules have no rejected or pending
line holds for every platform.

### 28.3 When the pass runs

**`check` and `build`, when the chain is in-place, and the run's own check produced no error.** The pass
reads solved types (§2.3), and a module with a type error has none worth reading; one message at a time is
Elm's rule (`Check.Options.quiet`), and the ownership errors of a program follow its type errors as type errors
follow its parse errors. A run with no platform, or with a platform that is not in-place, runs no pass, keeps no
type store and allocates no `inst_type` table: it is byte for byte what it was.

**Where.** After `Check.run` returns, on one thread, before the check's diagnostics are reported and before the
cache entries are written — so an ownership error is one of the module's diagnostics, and a module with one is
never cached (`Session.storeEntries`' rule). Moving the pass onto the DAG, beside the module's check, is §16.9's
design; §28.11 says why this slice does not.

**What it walks.** The run keeps every checked module's type store (§2.3). Each module the run checked is walked
from its BIR; every module the run installed — from the checked core, or from the cache directory — is read from
its summary block (§28.4). **A module sees another only through a block**, also when both were checked in this
run: the first time a caller in another module asks for a declaration's summary, that summary is **sealed** —
written as a one-row block and read back in place of what the walk gave — and under runtime safety, the build every
test runs, the two must be equal field by field or the compiler stops. So the block loses nothing, a verdict does
not depend on whether an import was checked or installed, and the dump (§9.1), which seals the same way, prints the
verdicts a build enforces: every `tests/corpus/ownership/` golden is unchanged by the slice. Sealing is per
declaration, not per module, because a report that summarised the whole of every module it touches went over the
test budget on `EntryValueCommand` (4 651 million instructions); per declaration it summarises no more of the
library than before. *One known way a block and a walk could still differ*: the cap on guard atoms (§16.7) keeps
the first eight in an order by id, and a session that computed the summary itself assigns other ids than one that
read it; no measured summary reaches the cap.

**What it reports.** The modules of the app's packages that the run checked: an installed app module was cached
clean, which by §28.5 means without an ownership error. Core and the platforms are not reported — their verdicts
are the checked core's (§28.7).

### 28.4 The summary block

A module's summaries, as bytes: every top-level declaration with a summary (§16.2) — functions, values with no
parameters, asserted and worded rows alike — with the one fact about a value with no parameters that a caller in
another module reads besides its summary, whether its type may hold a list (§23.6's view footer). The block names
nothing by a session's id:

- a **module** by its package and dotted name, through a table at the block's head;
- a **declaration** by its index in its module's BIR, and a **constructor** by its module and its index in that
  module's constructor table — both functions of the module's source, which the key covers;
- a **path** step by step (§4.1), a field by its name, a constructor step by its constructor and argument;
- a **local** of a carried lambda (§24.9) by its index in the declaration, as BIR numbers it.

The format is versioned with the rule set (`summary_bytes.version`, thesis §8.5): a block of another version is
absent. Reading a block re-interns its paths, re-sorts each summary by this run's ids (§16.6's normal form) and
re-merges nothing.

**Where it is kept.** In the module's **cache entry**, as a fifth section (`entry_bytes` format 10), written by
every run that summarises the module and empty otherwise; so also in the checked core, whose rows are entries.
Not in the interface record, which §16.10 specifies for the slice that moves the pass onto the DAG.

**What the key must cover.** A module's verdicts are a function of its source and of its imports' blocks, and a
block is a function of the module's source and of *its* imports' blocks. The firewall's import term — the
interface hash and the dependency digest (`fast-compiler.md` §8) — does not cover a block, so **in a run that
enforces**, two rules keep a hit sound:

1. **An entry with no block is a miss.** An entry a run that did not enforce wrote — the same key, since nothing
   in a module's own terms says whether the run enforces — is checked again, and its entry rewritten with a block.
2. **Every module the run did not install from the checked core publishes, for its importers' keys, the hash of
   its interface record followed by its own key**, in place of the interface hash. Its key covers its source and,
   by induction, every import's; so an importer's key moves whenever any block it can read may have moved — the
   transitive recipe, for in-place builds only. A module from the checked core publishes its interface hash as
   always: its block is fixed by the build id, and its importers' keys inside core must stay the checked core's.

The price is the firewall, on in-place builds only: an edit to a module's body re-checks every module that
imports it, directly or not, where a build elsewhere re-checks only those whose imports' interfaces moved. §28.11
item 1 is how it comes back.

### 28.5 What is an error

*Amended 2026-10-14 (tagger diagnostics):* deciding that a callback does not
return an owned value and deciding that this is proven sharing are separate
questions. The exact-only diagnostic probe ignores approximate supply rows,
just as it ignores approximate result rows. A borrowed supply whose `approx`
bit holds records a loss of precision, not a demonstrated alias. This affects
only the diagnostic (`list_may_be_shared` rather than `list_still_used`); the
ordinary ownership proof still checks every supply and refuses the program.
`Random.generate (Random.list generator n)` exercises this distinction: its
summary cannot preserve the generator's fresh-list result through the opaque
generator carrier. `Random.constant` can retain a shared list, so accepting
every generator instead would be unsound. No ownership verdict is relaxed.

**Every rejected line and every pending line of a reported module is an `error`.** One sentence per kind, each
against CLAUDE.md rule 7's test — what guarantee does the error buy?

- **Exact rejections** (`later-use`, `alias`, `captured`, `held-operand`, `disjoint`, and `once`, `supply`, `need`,
  `exclusive` when exact): real sharing the text shows. Writing in place would make an old value observable; the
  guarantee is value semantics, and an error is the only alternative to a silent copy, which the owner refused.
- **Position rejections** (`top-level`, `read-only`, and `platform` should a template row ever meet an in-place
  build): the language's rule for which lists may be written — a top-level value is shared by every part of the
  program and never changes; the model `view` reads is the runtime's to keep. Writing either in place breaks the
  same guarantee, on every run that reaches the write.
- **Approximate rejections** (`unknown`, `escaped`, `captured-edit`, `element`, `call`, `supply`, `need`, `limit`,
  `exclusive`, `once`, `payload` when approximate): the checker could not prove the write safe. Accepting them would
  write in place a list the checker cannot show unique — the guarantee lost exactly where the analysis is weakest —
  and copying them silently is what the owner refused. So they are errors too, and their message says that it is a
  limit, not proof of sharing (thesis §8.4), and how to make the program provable or copy.
- **Pending lines** (§16.5): a function that writes a parameter in place has gone where the checker cannot see
  every call of it. A build cannot leave an obligation undischarged, so a pending line is a rejection, with the
  approximate rejection's code: its message names where the function left the checker's sight.

**Acceptances are not errors**, including one that rests on a callee with no summary (`assumed`, §15 decision 2): a
writing function value that reaches such a callee is pending where it gets there (§16.5), so the obligation is
reported once, at that place.

*Diagnostic guidance, 2026-10-15.* At an entry, a `top-level` refusal recommends
building the value inside `init ⊤ = …` and cites §22.2: returning a top-level
value from `init`, even through a lambda, keeps that value shared. Outside an
entry, recommend making the top-level value a function, or changing a copy with
`List.copy <name>` (§4.2). These are the existing position rules, not a checker
limit or a new permission. A still-used base keeps the local copy suggestion,
including `List.copy a ++ b` for an append whose base remains live.

**One diagnostic per root cause.** Lines of one module with the same position, verdict, cause and detail are one
diagnostic, listing every base — the entry's lines for several model paths that one top-level list or one view
event reaches are one message, not one per path. Lines at different positions are different diagnostics.

### 28.6 Diagnostics

Four codes, appended to `language.md` §10's catalogue:

| Code | Title | Lines |
|---|---|---|
| `list_still_used` | `LIST CHANGED WHILE STILL IN USE` | exact rejections, and `platform` |
| `top_level_list_changed` | `TOP-LEVEL LIST CHANGED` | `top-level` |
| `view_changes_model` | `VIEW CHANGES THE MODEL` | `read-only` |
| `list_may_be_shared` | `LIST MAY BE SHARED` | approximate rejections and pending lines |

All four are `error`s, the checker's, and only on an in-place platform. The diagnostic's span is the edit — a
construction from its `[` to its `]`, a `++` chain, a writer's call, a call that writes an argument, a send — and
its file the module's.

**The message has thesis §8.3's fixed shape**:

1. **One sentence** naming the operation, the list, and why that is a problem here. A construction "adds to the end
   of `acc` itself"; a `++` "adds to the end of `a` itself"; a writer "changes `xs` in place"; a call whose callee
   writes its argument names the callee; an entry line names `update`; a send "gives up" its payload.
2. **The places, in source order**, each as `N|` and the line, a caret run under the place and a label: the place
   that keeps the list ("`saved` keeps the list here", "`show` holds the list here", "this value, computed first,
   still holds the list"), the edit ("the list is changed in place here"), and the later use ("and `saved` is read
   here, after the change", "`show` is called here, after the change"). A place in another file is preceded by the
   file's path. Line numbers are right-aligned to the widest.
3. **The consequence**, one sentence: what the later use would see if the change happened in place.
4. **The fix**, a replacement line: the edit's line with its base wrapped in `List.copy` — `[ …List.copy acc, x ]`,
   `List.copy a ++ b`, `List.push (List.copy xs) 4` — which is always correct, since it changes a list nobody else
   holds; and, where one exists, a fix without the copy (read before the change; build the list in `init`). A base
   that is not written in the source (a temporary, a record's path) gets the fix in prose.
5. **The verdict line**: "This is sharing the checker can see: …" for an exact rejection, "This is a limit of the
   checker, not proof of sharing: …" naming the limit (thesis Table 8.1) for an approximate one or a pending line,
   and for a position rejection the language's rule it follows.

The trailing excerpt every other diagnostic gets is not printed: the message holds its places. A JSON diagnostic
carries the same message.

Example, a later read through another name (`build/bad/direct/OwnershipAlias`):

```
-- LIST CHANGED WHILE STILL IN USE ----------------------------- Main.beni:25:20

`[ …model.todos, n ]` adds to the end of `model.todos` itself, but `saved` still
holds the old list and is read afterwards.

24|            saved = model.todos
               ^^^^^ `saved` keeps the list here
25|            next = [ …model.todos, n ]
                      ^^^^^^^^^^^^^^^^^^^ the list is changed in place here
26|            { model | todos = next, before = List.length saved }
                                                            ^^^^^ and `saved` is read here, after the change

If the list were changed in place, `saved` would see the change when it is read
on line 26.

To change a copy and leave `model.todos` as it was, copy it there:

25|            next = [ …List.copy model.todos, n ]

Or, if `saved` only needs the list as it was, read it before line 25.

This is sharing the checker can see: `saved` is read on line 26, after the
change.
```

A limit of the checker (`build/bad/direct/OwnershipLimit`):

```
-- LIST MAY BE SHARED ------------------------------------------ Main.beni:23:12

`[ …picked, 9 ]` adds to the end of `picked` itself, and the checker cannot show
that nothing else still holds the list.

21|shown rows =
         ^^^^ `rows` keeps the list here
22|    picked = orFallback rows
                ^^^^^^^^^^ `rows` may hold the list through this call
23|    more = [ …picked, 9 ]
              ^^^^^^^^^^^^^^ the list is changed in place here
24|    List.length more + List.length rows
                                      ^^^^ and `rows` is read here, after the change

To be safe, change a copy:

23|    more = [ …List.copy picked, 9 ]

This is a limit of the checker, not proof of sharing: rows may hold it through
the call at 22:14, and is read at 24:24.
```

### 28.7 Core and the platforms

Their summaries are computed once, when beni is built: the maker of the checked core (`src/core_pack_main.zig`)
keeps type stores and runs the pass over every module it checks, so every core and platform row of the checked core
carries its block, and a build reads them instead of summarising the library again — the cost §18.11 and §18.13
item 4 measured, two thirds of the pass on Conduit. Core's blocks are computed in the run that checks core alone; a
platform's in the run for its chain, over core's rows.

**Core must have no rejected or pending line, and an in-place chain's platform modules neither**: they are
privileged code (CLAUDE.md rule 6), shipped in the binary, which no program can repair with a `List.copy`. The maker
reports core's modules in the run that checks core, and a platform's in the run for its chain when the chain is
in-place, so a line there is one of the run's errors, and fails the build of beni with its message, as a core that
does not check does. On 2026-10-13 core and
`browser-direct`'s chain have none: 117 and 5 lines, all accepted.

### 28.8 Cost

The target: the pass adds at most 10 % to `check` on Conduit and the corpus pages, on `browser-direct`, and leaves
the 100 000-line benchmark's check throughput where it was. The benchmark has no platform, so it runs no pass and
keeps no store. Research 89 gives the figures.

*As built (research 89 §3):* met on the corpus pages (+2.6 %), TodoMVC (+6.0 %) and the table app (+5.6 %); the
100 000-line check moves −0.006 %; a `browser-tea` check +0.04 %. **Missed on Bike Wars (+18 %) and Conduit
(+112 %)**: what dominates there is not the library, which the blocks removed, but the entry protocol's fixpoint
(§20.4) over a wide model — on Conduit `entryCall` is 22 % of the process. Reported, not worked around (CLAUDE.md
rule 10); §28.11 item 4.

### 28.9 What does not change

Emitted JavaScript, interfaces and run hashes: the pass writes nothing a build emits. Builds on every platform
that is not in-place, byte for byte, including their cache keys and entries but for the entry's format version. The
verdicts: the dump's lines are the same as before the slice, the sealing (§28.3) changing none — `tests/corpus/
ownership/` is the check. **Determinism**: the pass is serial and walks in graph order (§10); a block is a function
of the module's source and its imports' blocks; the determinism test runs `check --platform=browser-direct` at
`--jobs=1` and `--jobs=8` and compares its diagnostics.

### 28.10 Testing

- **`build/bad/direct/Ownership…`**, one project per kind of error: `OwnershipLaterUse`, `OwnershipAlias`,
  `OwnershipCaptured`, `OwnershipHeldOperand`, `OwnershipTopLevel`, `OwnershipView`, `OwnershipLimit` (an
  approximate rejection), `OwnershipEscaped`, `OwnershipPending`, and `OwnershipGrouped` (one diagnostic for several
  model paths). Each is built for `browser-direct` and fails with its golden; **each is also built for
  `browser-tea`, which must succeed with no diagnostic at all** — the corpus harness does that for every
  `build/bad/direct/` project whose golden holds only the four codes of §28.6.
- **Every `browser/direct/` page still builds**: they are built for `browser-direct` already. A page that a rule
  rejects is either a real unsafe edit, reported and fixed with the message's own fix, or a checker limit (research
  89 §3).
- **The dump against the build**: the `ownership/` corpus kind checks each `browser-direct` fixture with `check`
  as well as dumping it, and the check must fail, with the four codes and no others, exactly when the dump has a
  rejected or pending line (`tests/blackbox/corpus_test.zig`, `ownershipReport`).
- **The block**: every summary a report reads across a module boundary is sealed (§28.3), and under runtime safety
  the read-back must equal the walk's; the corpus's ownership goldens, unchanged by sealing, are the semantic check.
- **The cache**: an enforcing run after a run on another platform checks again (rule 1 of §28.4); a body edit that
  makes a leaf write its argument fails its warm importer (rule 2) — `tests/blackbox/cache_test.zig`.
- **Determinism**: `blackbox_test.zig`'s ownership errors at `--jobs=1` and `--jobs=8`, twice each.
- **The checked core**: its refusal is a core or platform module with an error, which the maker already refuses
  with the diagnostics; core and `browser-direct`'s chain have no rejected line to refuse today.

### 28.11 Open questions

1. **The pass on the DAG, and the block in the interface.** §16.9 and §16.10 put the summaries in the interface
   record, computed by the worker that checked the module; the firewall then holds on in-place builds as
   elsewhere, a summary change being a signature change. This slice runs the pass after the check instead, on one
   thread, because the pass's state — its path table, its constructor ids, its on-demand recursion — is the whole
   program's, and making it per module is a refactor of the pass rather than of the build. The cost of not doing it
   is the firewall on in-place builds (§28.4) and a serial pass; research 89 measures the second.
2. **Stability** (thesis §8.5): every later release runs the previous release's accepted corpus. Not started: the
   corpus is this repository's, whose goldens already pin every verdict.
3. **Machine-applicable fixes.** The `List.copy` line is written for a person; a `--fix` that inserts it is the
   formatter's, not this slice's.
4. **The entry fixpoint's cost** (§28.8): instantiating `update`'s whole result each round over a wide model. A
   result split by the message's constructor (O6) or a memo of a class's instantiation at a model already seen would
   bring Conduit toward the 10 % target; either changes verdict-making code and is measured against every entry
   golden on its own.
5. **Model paths in messages** are printed as the report prints them (`model#Article.0.errors`); a rendering for
   people is a message-only change.

### *Amended 2026-10-13 (enforcement precision):* escapes in alternative arms

The Unescaped check at a demand uses only earlier escapes whose branch context is
compatible with that demand's context (§7.2). An escape in `Restart` cannot reject a
write in the sibling `Concurrent` arm of the same `case`. An escape before the case,
in an enclosing compatible arm, or in an arm whose case has already joined still
rejects the write. Nested cases use the same context-compatibility relation as Dead.
The escape index keeps the events' contexts; summary read-off still joins every arm's
E/J bits and classifies a returned cell escaped if any arm escapes it. Nothing changes
the conservative contract a caller sees.

**Soundness.** Two distinct arms of one case cannot execute in one invocation. Removing
an escape from an incompatible arm therefore removes no runtime holder at the demand.
The rule does not infer mutual exclusion between unrelated cases, test values across
calls, or an asynchronous body's choices: those remain compatible or are joined by a
callee's summary. The unsafe twin starts a fiber holding the list and then appends in
the same execution; it remains rejected. The accepted twin places that escape and the
append in different arms. This resolves the command driver's two Concurrent-arm limits
without dropping an escape from the driver's published summary.

### *Amended 2026-10-13 (enforcement precision):* the model's exclusivity invariant

The entry protocol's shape fixpoint (§20.4) is followed by a must-fact fixpoint for
the conditions of update's fresh result cells. Init's cells keep their established
conditions. Update's own fresh cells start at the holding condition, then every
reachable update result's summary condition is instantiated and conjoined, repeatedly,
until no cell's condition changes. An unknown result, escaped cell or explicit loss
in a summary is never seeded as a proven exclusive input. On exhaustion of the
32-round backstop, update's fresh conditions become lost; a partial proof accepts
nothing. The conditions are then used by the ordinary entry demands.

**Soundness.** Exclusivity at entry is an inductive invariant: init establishes it,
and every update arm must preserve it. Fresh allocations of a future update are not
unknown external cells. Starting those allocations at the holding end of the must
lattice and monotonically lowering them computes the greatest invariant satisfying
all reachable summary constraints, including the constraints coming from init and
from aliasing paths. The previous single evaluation fed an uninitialised fresh cell's
lost condition into its own preservation constraint, and rejected a recursive tree
whose grow operation preserves exclusive child lists. Lists duplicated at two
positions, retained elsewhere in the model, introduced by a sharing update arm or
obtained from an unknown source still fail the existing separation/exclusivity tests.
No recursive type is trusted exclusive merely because of its declaration.

### *Amended 2026-10-14 (the subscription tap builder):* fresh folds remain a limit

The runtime's `wanted` dictionary starts at `Dict.empty` each render. Each fold
iteration consumes the previous accumulator and returns its replacement; the
builder does not retain dictionary snapshots or reuse one tap-list container at
different keys. A generic aliased-input twin does not establish sharing in this
runtime builder. The earlier classification as real sharing was incorrect.

`Dict.update`, implemented through `Dict.focus`, is the intended expression of
ownership transfer: remove the selected entry, hand its value to the callback,
and restore the replacement. The isolated `want` helper checks without a copy.
The complete driver's `List.foldl` still rejects the call to `want`, because it
cannot establish the supplied accumulator's deep exclusivity. Opaque taps and
keys can share captured values; this does not imply that the freshly allocated
tap-list containers share. The current proof domain fails to separate those facts.

This is an unresolved checker limit, pinned by the focused subscription fold in
`tests/pending/browser/direct/SubscriptionTapFold`. No `List.copy` is added to the
platform to bypass it. The platform's original get/append/insert implementation
is retained until the focused builder can be checked; the dependent direct
subscription implementation remains blocked. A future precision change must
prove ownership of the actual written containers while preserving rejection of
aliased containers, retained accumulators and escaping callbacks. Freshness of
the outer dictionary alone is insufficient to assert deep exclusivity.

### *Amended 2026-10-13 (summary blocks):* invalidate the old precision rules

The ownership block version (§28.4) advances from 1 to 2. Its binary layout stays
unchanged; the rule set changed, so cached blocks from the previous checker are not
reused. The existing ownership corpus keeps every prior golden. New accepted and
rejected twins pin alternative-arm escapes, real escapes before a write, duplicated
recursive children at init and through update, and intentionally shared dictionary
tap lists (a rejected generic helper, not evidence of runtime sharing). The full copied driver is also checked through the embedded-platform
maker: three refusals before the changes, only the borrowed tap refusal after the
branch fix, and the focused rewrite still rejects the fold
accumulator. The third driver refusal remains pending; no platform copy is retained.

### *Amended 2026-10-14 (review of enforcement precision):* condition-only rounds

Condition rounds instantiate summaries without recording escapes or function-value
boundary diagnostics; only the final ordinary evaluation records those effects.
Runtime-safety assertions require the demand, use and escape lists to stay unchanged
through a condition round. Callback-result instantiation propagates this mode.
Unknown callback results (fresh number zero) and any cell already reachable at init
are excluded from optimistic seeding, also when a callback uses a lower namespace.
The entry namespaces have named constants shared by the shape and condition passes.
The unknown-tree-result twin installs an opaque callback's result into the model and
then grows it: it stays rejected. The recursive escape twin spawns a reader in one
arm and tail-calls into the appending arm; the call remains rejected through the
function's joined E/W summary, even though the append alone in its arm is accepted.

### *Amended 2026-10-14 (fold invariants):* owned accumulator edits

A fold supplies one accumulator to its callback and uses that callback's result
as the next accumulator. This applies to `List.foldl`, `List.foldr`, `Dict.foldl`
and `Dict.foldr`; iteration order does not change the ownership argument.
The initial accumulator establishes the invariant: `Dict.empty`, an empty list,
a literal or a proven fresh call result establishes ownership only for the
containers it actually makes, not for shared values stored inside it.

The callback must preserve the ownership of every container it writes. Each
such result container is either freshly allocated or the owned container it
received, with separation from the other result positions. No callback arm may
escape that container, capture it in a retained closure, store it at a second
position, or replace it with a borrowed/shared/unknown container. Its existing
Known, Unescaped, Disjoint and Dead obligations still apply. Unknown callback
classes, coarsened summaries and exhausted solvers establish no invariant.
A fresh outer dictionary alone proves nothing about its stored lists.

**The written footprint.** Exclusivity of a list's container is distinguished
from deep exclusivity of everything it holds. Appending a tap changes the list
container, not the opaque tap's captures. A result/supply condition may therefore
state container exclusivity at a path, retaining separation between the different
positions represented by that path. This fact never licenses a write below that
path. Destructive focus may use it only for the callback's actual write footprint;
a callback that writes a nested child requires that child's own condition.
Deep conditions retain their existing meaning. Dictionary focus still removes
one selected value before its callback runs, and its replacement must preserve
separation from the retained entries. Shared captures of taps do not establish
sharing of their enclosing list containers, nor are those captures asserted owned.

The fold first computes the finite shape of its callback results. It then solves
container conditions as a greatest must-invariant: future fresh allocations start
at the holding condition, while the initial accumulator's established constraints,
shared/unknown arrivals and escapes are never optimistically reseeded. Callback
result conditions are instantiated and conjoined until stable. The proof rounds
record neither escapes nor diagnostics; final checking records those effects normally. Exhaustion loses
the candidate facts. The invariant is used for callback demands and retained in
the result's container conditions, never as an unconditional deep-exclusive row.
Shape instantiation records the cells made by the callback's fresh result
provenances. Only recorded cells that occur in the shape may be seeded;
instantiating supplies and projecting arrivals records no allocation. Numeric
namespace ranges establish no ownership, and any cell reachable from an initial
argument is still never reseeded.

**Soundness.** Induct on the number of callback invocations. The initial value
establishes the base. Given owned written containers, destructive edits transfer
those containers once, and a fresh replacement has no earlier holder. Separation
of result positions and the callback's non-escape obligations establish the next
step. Duplicate placement, retained closures and escaped containers refute that
step; a shared initial value refutes the base. The greatest must-fixpoint checks
all callback classes and result arms rather than trusting the loop's syntax.
Unwritten opaque descendants are not mutated by this proof; a later nested write
must separately establish ownership of its target. Dictionary representative
separation remains load-bearing, including when two keys share the same list.

The subscription fold previously left pending is promoted only after this proof
accepts its copy-free `Dict.update` builder. Rejected twins pin escaped, captured,
duplicated and shared-start accumulators for both fold directions and families.
Ownership summary blocks change version when the container conditions are added;
old cached summaries cannot supply the new proof.

**Summary representation.** Ownership blocks are version 3. Each result entry
stores both its existing deep condition and its container condition. The latter
uses path-qualified `spine`, `sep_spine` and `keep_spine` atoms; they are collected,
joined and serialized canonically like deep conditions. The path of a focus's
`keep_spine` atom selects its replacement's root. A parent provenance that only
stands for that root is insufficient to certify the replacement. Coarsened or
limited callback/supply rows cannot use the narrower focus proof. Existing deep
proofs remain available when the narrower proof cannot establish separation.
Recursive summary convergence compares both conditions: an unchanged deep
condition cannot hide a container condition that is still weakening.

A scoped `returns owned` check examines aliases at **every** other result position,
including an earlier position and one outside the written footprint. Restricting
that comparison to the written paths misses a closure stored beside the written
list: its first construction may pass, but the retained closure sees a later fold
step mutate what it captured. The capture-after-append twin pins this boundary.

This amendment resolves the earlier dated subscription-fold limit. The library's
`Tea.want` now uses `Dict.update`, with no copy. Existing ownership corpus verdicts
remain unchanged; new container facts do not replace the existing deep proofs.
The new capture-after-append rejection closes an existing unsound acceptance:
master accepted that retained-closure twin. Its negative regression fails with
the fix set aside; no pre-existing golden is changed.

### *Amended 2026-10-14 (markup slots):* rendered data is not an event payload

The platform-declared markup type has two internal opaque slots in the sense
of Change 9: `render` retains everything the previous conservative markup
transfer retained, and `events` retains the cells its event messages and
handlers may hold. These are analysis paths, not JavaScript fields. General
alias, escape, disjointness and later-read checks continue to see both slots.
Only the entry's view-event payload projection excludes a proven render slot.
Unknown values, wildcard paths and exhausted precision remain conservative.
The ownership summary-block version advances for this rule and slot encoding.

A markup event stores its message or handler's captures in `events`. A child
markup hole projects the child's event slot, including through `Maybe` and
`List` markup. Text and ordinary attributes retain their operands in `render`.
For and Show rows use the ordinary callback result summaries on borrowed
elements; their returned markup contributes its event slot. An unknown row
retains its arguments and captures conservatively. Components not analysed as
ordinary calls retain their operands conservatively. The declared `text` and
`map` markup primitives obey the same slots: map preserves its child's event
slot and includes its tagger's captures and possible result cells. Neither a
tagging callback nor a row receives an ownership permission from this rule.

**Soundness.** Induct on the markup tree and its helper/callback summaries.
Only event attributes, a child's event slot, and mapped event results can
produce a message. Render-only operands remain live aliases in the complete
markup value, so editing while that value is held still fails. At an entry,
rendering is read-only under the existing platform protocol; reading a list
for a For does not hand its container to an event. A row does receive an
element, so its event results and retained captures remain borrowed. All
opaque symbolic arrivals are projected by slot rather than discarded: a
caller with unknown markup must still supply its event descendants. Summary
instantiation preserves those projections across imports and carried lambdas.
A wildcard loses the distinction and keeps both possibilities. Thus dropping a
proven render-only path from the event projection drops no list a handler can
send or retain; actual message lists still trigger §23.6, including lists made
in the view, captured by a handler, or produced by a mapped tagger.

Conduit's Article, Home/Feed, Profile and Profile/Feed errors are checker
limits: `Page.viewErrors` renders List String and its sole button stores the
crossing dismiss constructor. Neither its rows nor the dismiss message holds
the container. Each page appends errors from owned HTTP failure delivery.
No application change is required. Accepted fixtures reproduce all four
nested paths; rejected twins retain the corresponding list in an event or
handler. The unchanged application now has a corpus ownership report and enforcing
check with all 26 demands accepted. Its three browser scripts remain pending
for a separate document-helper lowering gap, pinned as `not_implemented`,
not as an ownership rejection (research 93).

Constructor-valued callbacks use §23.5's existing exact constructor row as a
zero-capture carried class through helper arguments and markup slots.
The existing constructor/tagger checking path still runs, including when the
callee loses sight of its callback calls: the exact constructor row
checks `need` independently of `seen`, so it cannot send a borrowed list as
owned. Other callback classes retain their existing checking protocol.
Their result retains each potentially list-bearing argument under its own
constructor argument step; they neither read captures nor allocate an unknown
list. Treating a list-bearing argument as crossing would be unsound, so the
row retains the existing `holdsList` test and unresolved types stay tracked.

**Unseen taggers.** A callee's `need` holds even when `seen` is false. The
previous lambda branch skipped it; a lambda returning a global shared list
could consequently send that list as owned. The finer render projection must
not expose that hole. Every such tagger now checks its returned provenance.

A generic helper such as Page.slowThreshold captures its `passed` message.
A returned capture cannot be owned while the tagger keeps it. When its cells
are symbolic arrivals of the declaration or enclosing frame, the helper may
therefore publish the conditional requirement that these captures contain no
tracked cell. This is encoded by the existing separation atom `sep π π`:
instantiation over two empty abstract values succeeds; a nonempty arrival
shares with itself and fails. Only parameter/environment arrivals may use
this encoding, never callback-result arrivals: `sep cb cb` has the different
fresh-across-calls meaning of §18.2. Concrete retained cells, shared values,
unknown results and failed requirements remain rejected. After excluding only
captures proven empty by these requirements, the usual returns-owned proof
checks every remaining result position and supply.

Thus the generic helper checks for a scalar message, without accepting a list
kept by its tagger. This does not confer an owned or once permission on a
callback. Lambda taggers retaining global lists, and helpers supplied a
list-bearing message, have rejected twins; scalar-message uses remain valid.

When a tagger returns the enclosing declaration's callback result (§18.9),
its owned-result obligation is published as that callback parameter's `need`,
using the existing supply/call facts. It is not rejected before its callers
are known, and it is not assumed owned: each caller must satisfy the normal
returns-owned check. The requirement conservatively covers the whole callback
result even when the tagger forwards only a projection. Keyboard.downs'
Browser.Events callback is this generic forwarding shape; its actual scalar
message constructors satisfy the requirement.

A concrete callback result whose solved type is crossing needs no owned
result proof: there is no tracked cell to donate. This uses the existing
recursive tracked test, including opaque types, function captures and type
parameters. Functions remain tracked even though holdsList excludes them. Unresolved result types remain tracked. This keeps specialized
identity taggers on Int and String valid. A work function stored inside a
traversal callback remains the existing §24.9 slot-inside-lambda limit: its
result ownership cannot yet be propagated, so HttpFailures remains pending
with an approximate tagger-result diagnostic after the unseen check is closed.

**Nullary methods (2026-10-15).** Static-dispatch-spike.md §1.1's checked-form
invariant applies here: a resolved `x.m` method is an ordinary zero-argument
`method_call`, never a field path. In particular `current.trail.copy` applies
`copy`'s fresh-result summary; record `x.f` retains its field path and identity.

### *Amended 2026-10-15 (initialization transfer):* a private value read once

A private, parameterless value may transfer its freshly allocated cells to its
sole read when that read executes directly in another nonrecursive,
parameterless initializer of the same application module. The whole module
must contain exactly one reference to the value. Reads in closures or functions,
public values, foreign values, recursive initializers, coarsened summaries,
evidence-parameterized values and unknown results receive no permission. The reference count is over BIR value
instructions, including deferred bodies, not over reachable calls.

The value's ordinary result summary is instantiated at that read, preserving
allocation identities, result-position aliases, escapes and both exclusivity
conditions. Shared arrivals stay shared. This transfers only allocations of the
private initializer; it does not assert that their descendants are exclusive.
The destination is still a top-level value: later reads of it use the ordinary
shared-value rule. No initializer is re-executed and no copy is inserted.

**Soundness.** Module initialization executes the consuming expression at most
once. Privacy and the unique reference leave no other source-level reader of
the transferred binding. Existing summary escape and separation obligations
cover retained aliases and repeated result positions. A read in a closure could
execute repeatedly, so it is excluded even when the closure itself has one
syntactic occurrence. A later use of the destination must still be rejected.
The cached ownership block version advances from 4 to 6 with this rule and its
reviewed evidence guard.


*Review clarification, 2026-10-15.* Ordinary top-level values cannot suspend
(`transparent-effects-proposal.md` §15.2 item 7); delayed work in a lambda is
not executed by initialization, and its reads get a nonzero ownership frame.
A parameterless value carrying explicit or inferred `where` evidence, or a
hidden identity parameter, can instead be evaluated at its uses. Neither the
source nor the consumer may have such hidden parameters. Their presence is
read from the solved dispatch table, not merely the source annotation.
An explicit-evidence pop of a private polymorphic empty list pins this guard.

Known private expression names lower through `resolveValue` to `.top`, also
inside schema `via` expressions and markup holes; schema namespace references
name schema declarations, which are ineligible sources. A private value cannot
be a public static-dispatch member; function-valued result provenances are also
ineligible for this transfer. The new schema and markup second-read twins pin
the ordinary-value path. Ownership currently walks modules serially; its lazy
reference-count memo would need synchronization before parallelizing that walk.

## 29. Result liveness and ownership across calls (2026-10-15)

Every expression that forwards a result consumes that result in its own evaluation
context. This includes every case/if arm, a block's terminal expression, a function
or callback body, and early returns. A compound expression cannot hide a terminal
variable path from Dead. Arm uses retain their branch contexts, so mutually
exclusive arms do not keep each other's values live. A write's newly returned
version is transferable; reading an old holder after the write remains sharing.

Captures are read at the enclosing consumer of a closure as well as in its body.
A later callback returning an outer value therefore keeps that holder live across
earlier writes. Named closures still resolve captures when invoked, including
bindings declared after their definitions. A closure's own permitted once transfer
is excluded only from its own capture demand, never from an earlier unrelated write.

Recursive summary instantiation preserves symbolic environment provenance in the
frame being summarized. An environment not yet bound is not the empty abstract
value. A write through a recursive captured result contributes the captured write
and the once obligation; callers must discharge both. Missing provenance remains
conservative, never proof that a result contains no cell.

Disjointness at a call includes the callee's environment alongside every explicit
argument and every other argument path. A written argument cannot alias a capture
which the callee may read or return, even if the closure's last invocation is this
call. This applies equally to direct local calls and calls through carried classes.

A callback result supplied to a later invocation must establish ownership for its
whole lifetime on that feedback edge. An owned destructive item supply is a loan
from its container, conditional on that container's exclusivity and the absence of
retained readers. It does not establish ownership of an accumulator that outlives
the item invocation. Returns-owned checks preserve the taken-container condition
and separation from retained inputs and later item positions. Both fold directions
and nested callback results obey this rule; fresh or transferred owned accumulators
continue to satisfy the existing invariant. No new permission is introduced.

Ownership summary blocks advance version when these rules land, so cached older
summaries cannot bypass the corrected checks. The Lean oracle models these rules
with required independent holes; its bridge preserves the historical generator and
enumeration streams and appends the new fixtures. The runtime confirmation boundary
is unchanged; interpreter-confirmed unsafe accepted originals
must be zero at the CI bound and the three recorded generator seeds. Reverse leads
are counted separately from confirmed soundness failures.

`if` lowers to BIR `case` (`Lower.lowerIf`). The `?` form remains BIR `try`:
its existing transfer consumes the operand at the try site and `earlyReturn`
retains the `Err` payload in the frame result (§26.2). The terminal-result rule
also applies when that operand is itself a case or block. A nested callback
result whose ownership cannot be established remains refused; the result-loan
walk never supplies permission in place of the ordinary returns-owned check.

## 30. Ownership everywhere (the owner, 2026-10-15; normative from 2026-10-15)

*Amends §1.3, §3.1, §16.5, §20.2, §20.9, §24.5, §28.1–§28.3, §28.6–§28.8, §28.10 and §28.11, and the
amendment of 2026-10-15 to §28.2. Sections 1–29 keep their numbers and text. Where this section changes a
rule, it wins. It specifies; it builds nothing. The slices of §30.7 build it.*

### 30.1 The decision

The owner, 2026-10-15, verbatim: **"no 'fallbacks', i want a proper implementation. this is no longer a
platform decision, it's core to beni."**

- **Ownership is the language's rule.** Every `check` and every `build` runs the pass. This holds on every
  platform (`node`, `html`, `browser`, `browser-tea`, `browser-direct`, the test platforms and any
  third party's) and with no platform at all. §28.1's "errors only where lists are edited in place" and
  §28.3's "when the chain is in-place" are withdrawn: lists are edited in place everywhere.
- **`"lists": "in-place"` is withdrawn** (§28.2, `boundary.md` §5.2 amended). No platform declares how a
  list is written, and nothing reads the key. `browser-direct`'s manifest drops it. A manifest that still
  writes it has an unknown key, which is ignored (`boundary.md` §5.2).
- **No fallback.** No platform copies where ownership is not proved. There is no copying writer, no trie,
  and no interim in which a construction copies over a plain array (`backend.md` §4, *Every platform edits
  in place*). A demand the checker cannot prove safe is an error (§28.5) on every platform. Its message is
  §28.6's, and its fix is `List.copy`.
- **The template row and the `platform` cause are withdrawn** (§20.2). Every program constructor has the
  direct row (§30.3). One source has one verdict on every platform, which thesis §7 asked for. A
  `build/bad/direct/Ownership…` project that fails on `browser-direct` must now fail on `browser-tea`
  with the same diagnostics. The §28.10 rule that it must succeed there is reversed.
- **Pattern `rest` views stay read-only**, as `backend.md` §4, *The representation: a plain array*,
  specifies.

### 30.2 The precondition, measured (2026-10-15)

`backend.md` §4's open question made a whole-corpus measurement a hard precondition of this choice. It was
taken before the decision was written down here.

**How it was measured.** There is no flag that turns enforcement on for a platform that does not declare
`"lists"`. So this measurement used a local patch, not committed, on the tree of PR #148. The patch:

- read one environment variable;
- made `Chain.inPlace` true for every chain;
- marked every platform module as in-place for §20.2's rows. That gives `browser-tea`'s `Tea.*`, and
  `browser`'s `Browser.program`, the direct row;
- gave the test platform `page`'s `Page.sandbox` the direct row.

Each fixture was then checked with `check --platform=<its corpus platform> --diagnostics=json`, and the
ownership codes were counted. The causes come from `dump --stage=ownership` under the same rows. A program
is a corpus file, or a project directory. The table counts programs, not demands:

| What | Platform | Programs | Rejected |
|---|---|---|---|
| `run/` (files and projects) | `node`, or the project's `platform/` | 459 | **16**, and 4 that crash (below) |
| `browser/` top level and `OwnPlatform` | `tests/platforms/page`, own | 4 | 0 |
| `browser/dom/` | `browser` | 52 | **1** |
| `browser/tea/` | `browser-tea` | 88 | **13** |
| `browser/direct/` | `browser-direct` (as today) | 214 | 0 |
| `browser/direct/`, the same sources | `browser-tea` | 214 | 0 |
| `examples/` (Bike Wars, Conduit, Sternhalma) | `browser-tea` | 3 | 0 |
| `bench/` apps: TodoMVC ×4, `ui` ×4, `jfb` ×2 | `browser-tea`, `browser-direct` | 10 | 0 |
| `bench/corpus` | `node` | 1 project | **1** |
| core | — | 116 demands | 0 |
| the platform modules: `node`, `html`, `browser`, `browser-direct` | — | — | 0 |
| the platform modules: `browser-tea` | — | — | **2 lines** (`Tea.application`) |

`bench/markup` and `bench/size-apps` do not check today, for reasons that have nothing to do with
ownership, and are left out. **31 of 831 programs are rejected (3.7 %): 17 of them really share, and 14 are limits of the checker.** Every page of `browser/direct/`
also passes on `browser-tea`, and so do all three examples.

**By cause, and whether the program really shares.** A program can have lines of more than one
cause, so the causes overlap: `ListForms`, `ListPrepend` and `ListIndexedIdentity` are each counted
twice. Counted once each, causes 1–3 are 17 programs and cause 4 is 14.

1. **A top-level list written** (`top-level`, position; `top_level_list_changed`). 11 programs, 9 of
   them for this cause alone (`run/ListForms` and `ListPrepend` also have exact lines):
   - `run/`: `ConstrainedConstant`, `ConstrainedFunctionConstant`, `ConstrainedFunctionConstantRoutes`,
     `Int32Keys`, `ListDirectDeep`, `ListIndexed` (29 lines), `ListIndexedDeep` and `NestingFlatList`;
   - `browser/dom/KeyedInPlace`, whose `init` returns the top-level `rows`.

   *Real.* In place, the top-level value would change for every later reader, and for every later mount.
   Example: `xs = [ 1, 2, 3 ]` at the top level, then `List.set xs 0 9` in `main`.
2. **Real sharing that the text shows** (`later-use`, `alias`, `disjoint`, `captured`, exact;
   `list_still_used`). 5 programs, each a test of persistence or identity: `run/ListForms`,
   `ListPrepend`, `ListSpreadPatterns`, `ListIdentity`, and 2 of `ListIndexedIdentity`'s lines.
   *Real.* In place, each would print something else. Example: `ys = xs ++ [ 4 ]`, then `xs` read again.
3. **Real sharing that the checker reports as a limit** (approximate). 4 programs:
   - `run/ListPersistence` (7 lines, `call`): it edits old versions kept in a `Dict`. It is a test of
     the trie and retires with it;
   - `browser/tea/QueuedListSnapshot` (`escaped` at the entry): a queued command reads the list that a
     later arm extends. Its own comment says that an in-place append would change what it prints;
   - `run/ListIndexedIdentity` and `run/WriteRowsIdentity` (`escaped`, 17 lines): the lists reach
     `refEq`, a test platform's `foreign` with no ownership words. These programs observe identity, so
     in place they would print something else.
4. **Checker limits, with no sharing in the program** (approximate, or exact only in name).
   14 programs and the platform's own `Tea`:
   - **A tagger's result through a command**, the largest family (§23.5 `need`; 10 `browser/tea/`
     programs, 14 lines). Examples are `Http.send { … } (Got "send" _)`, `Cmd.task work (Got label _)`
     and `Random.generate Rolled …`. The payload holds no list the program kept. Eight of these lines
     print as exact (`list_still_used`) where §28.5 would call them a limit, and that is a defect of
     the message.
   - **`Tea.application`'s forwarding of `onUrlRequest`/`onUrlChange`** (`need`, 2 lines in
     `browser-tea`'s own `Tea`). Under §28.7 this fails the build of beni itself.
   - `browser/tea/DebouncedSearch` (`supply`: a function parameter loses sight of `send`).
   - `browser/tea/ReentrantSend` (`disjoint` on a message that carries the `send` function: a closure
     is taken for a list).
   - `run/RefModify` (`supply`: `Ref.update` hands its callback the value borrowed, `⊤`).
   - `bench/corpus`'s `FormValidation` (`call`, 4 lines: an applicative `andMap` chain through
     function values with no summary).

**A defect found on the way.** Under enforcement, `check` crashes on four `run/` projects:
`SchemaDeclDepth`, `SchemaDeclGeneric`, `SchemaDeclModules` and `SchemaDeclTagged`. A ReleaseFast build
gets `SIGSEGV`. A Debug build panics with "index out of bounds: index 4294967295" in
`summary_bytes.write`'s module sort (`SortModules.less`, `packages[none]`), reached from
`Ownership.writeBlock` through `Enforce.run`. It happens only when the run writes cache entries. With
`--no-cache` all four check clean, with no ownership lines. A summary row names a module index of
`none`, and a schema declaration's rows are where it comes from. Whether `browser-direct` can reach it
today was not established: a minimal schema program there does not crash.

**Cost.** This is the whole process at `--jobs=1 --no-cache`, the best of 7 runs, with the ReleaseFast
build of the patch:

| Program | Without | With the pass | Change |
|---|---|---|---|
| Conduit on `browser-tea` | 95 ms | 165 ms | +74 % |
| Conduit on `browser-direct`, as today | — | 174 ms | — |
| Bike Wars on `browser-tea` | 65 ms | 83 ms | +28 % |
| `bench/corpus` on `node` | 84 ms | 137 ms | +63 % |

§28.8's target of 10 % is now missed on every platform, not only on `browser-direct`. The 100 000-line
benchmark has no platform, so until now it ran no pass. After this decision it runs one, and that has
not been measured. §28.4's transitive cache keys, which cost the firewall, now apply to every build.
§30.6 makes both preconditions.

### 30.3 Entry rows: what every platform provides

Every program constructor gets **the direct row** (§20.3–§20.6, Table 7.1 of the thesis). Nothing takes
its place where a row is missing. A constructor with no row leaves its functions pending (§16.5), and a
pending line is an error (§28.5).

**Who declares the row.** §20.2 asserted the rows by name "until Change 5's words let a platform declare
its rows". That table cannot cover a test platform or a third party's, so words now declare the row.
A new ownership word, **`entry`**, stands in front of a record-typed parameter of a platform declaration
(§24.2–§24.4: core and platform packages only, `misplaced_ownership_word` elsewhere). It says that the
runtime calls the record's functions as a program:

- `init` once per mount, handed `⊤` (or its address and key, for `application`);
- `update` with the model owned (P1), and the message as §23.6 says;
- `view` and `subscriptions` with the model to read only;
- `onUrlRequest` and `onUrlChange` with crossing arguments.

A field of the record that has none of those names is refused with `misplaced_ownership_word`. A word on
a parameter that is not a record written out is refused the same way. The words replace §20.2's table:

| Platform | Constructors that write `entry` | Note |
|---|---|---|
| `browser-direct` | `Tea.sandbox`, `element`, `document`, `application` | as today, by word instead of by name |
| `browser-tea` | `Tea.sandbox`, `element`, `document`, `application` | was the template row |
| `browser` | `Browser.program` | was the template row. `programs` and `mountAt` take `Program` values, not records of functions, and need none |
| `tests/platforms/page` | `Page.sandbox` (a `foreign`) | had no row |
| `node` | none | `main` is a value. `print`, `printLines` and `exitWith` take values and carry words. `Io.run`'s body is beni, and its summary is inferred |
| `html`, `tests/platforms/toy`, `layered`, `oracle` | none | no program takes functions |

A declaration that writes `entry` puts the direct row's obligations on its platform. These are P1–P4 and
P7 of thesis §7, which the checker does not see. §20.9's trusted surface lists each such declaration with
how its runtime meets them:

- **`browser-direct`**, as designed (`browser-direct.md` §7.4).
- **`browser` and `browser-tea`**, once slice O3 lands, and not before:
  - **P1 and P2.** The runtime reads nothing of the old model after `update` returns. The Tea driver
    hands `update` the model and keeps only the result.
  - **P3.** Handlers made by a render may be called before the next render. Their messages and captures
    are the view's event slot (the 2026-10-14 amendment to §28, *markup slots*). §20.5 rejects a write
    to any list they hold, so a handler never reads a list written since its render.
  - **P4.** It holds, because `view` is recomputed whole.
  - **P7.** `backend.md` §15.5's amendment of 2026-10-15: the renderer never decides "unchanged" from a
    list's identity.
- **`Page.sandbox`**: its `runtime.js` renders the whole view after every message and keeps no list. Its
  entry in the trusted surface says so, and a fixture pins it.

### 30.4 A writer handed as a value

`backend.md` §4's plain-array amendment found a conflict, and this resolves it. §3.1 said that "a writer
passed as a value and called through a local is not a demand in slice 1". On an in-place platform that
would have let it write unchecked or copy silently. Neither happens, and neither has happened since
slice 2:

- A writer named as a value (`List.push`, a placeholder such as `List.push _ 4`, a lambda that writes
  its parameter) **is a function value whose class writes that parameter** (§16.5). The value is the
  in-place writer, the only one there is.
- **Where the class is in sight**, every call of it is a call-site demand (§16.4). Examples are a callee
  whose `fun(j)` is seen, and a local called directly. It is accepted, or rejected with §8.3's cause,
  like any demand.
- **Where it leaves sight**, it is a **pending** line, and so an error (§28.5, `list_may_be_shared`).
  Leaving sight means being stored in a structure, returned, captured, passed as evidence, or passed to a
  callee that does not see it (a `foreign` with no words, §24.5).

Measured on 2026-10-15 with the patch of §30.2:

- `apply f xs = f xs 4`, then `ys = apply List.push xs` followed by a read of `xs`: rejected
  `later-use`, with the fix `apply List.push (List.copy xs)`.
- `{ f = List.push }`: pending, "it is stored in a record".

Neither is a silent copy. §3.1's sentence is superseded by §16.5 and by this section. No rule is new:
what is new is that the rule now holds on every platform.

### 30.5 `foreign`, siblings and the platforms' own modules

- **Words are load-bearing everywhere.** §24.5 is unchanged. A `foreign` with no words escapes every
  argument and returns `⊤`, which is sound and may be imprecise. A sibling that keeps a list past the
  call must not carry `borrowed`, so its default `escaped` is the safe reading (`boundary.md` §4,
  amended). A sibling still never writes a list it is handed, and returns only a fresh array or one it
  was given.
- **Every platform's modules are checked when beni is built** (§28.7). The rule had applied only to
  in-place chains. The maker now reports every platform module in the run for its chain. Core and every
  platform must have no rejected or pending line. On 2026-10-15 every platform passes but `browser-tea`,
  which has 2 lines (§30.2, cause 4).
- **A test platform's `foreign`s** that take lists get words like the shipped platforms' do. Examples
  are `refEq` and `Page.element`'s children. They are privileged code, held to the same standard
  (§24.6, *the trusted surface*).

### 30.6 Cost, the firewall and the benchmark

Two properties that held only on `browser-direct` now cover every build, so they become preconditions of
turning enforcement on (O4):

- **The firewall.** §28.4 rule 2 makes every importer's key move when any block it reads may move.
  §28.11 item 1, moving the pass onto the DAG and putting the summary block in the interface record
  (§16.9–§16.10), brings the firewall back. It is slice O2.
- **The budgets.** `fast-compiler.md` §2's budgets for checking (250 000 lines a second, cold, per core)
  and for an 800 ms build of 100 000 lines now include the pass. §28.8's 10 % target is re-measured on
  the 100 000-line benchmark (run with `--platform=node`, since it needs a platform's `main`), Conduit,
  Bike Wars and the corpus pages. A miss is reported under CLAUDE.md rule 10. It is never answered by
  turning the pass off on a platform.

### 30.7 The slices, in order

No slice introduces a fallback. Every slice keeps `zig build gates` green on `master`. Until O5,
programs run on E1tp unchanged. O0–O4 only tighten what compiles, which is never a fallback, because no
behaviour changes.

- **O0 — the defect and the measurement in the gates.**
  - *Builds:* the fix for §30.2's summary-block crash, with a red-first fixture in `tests/corpus/ownership/`
    that writes cache entries;
  - a check of whether the crash is reachable on `browser-direct` today. If it is, the fix is a bug
    fix and lands at once, on its own branch, ahead of the rest of O0;
  - a hidden, test-only flag that reproduces §30.2's patch whole, so that the measurement is a test
    rather than a patch. Like `--allow-debug`, it is listed in no usage text, and it is deleted in O4.
    The flag does three things:
    - it enforces on any chain;
    - it gives every program constructor the direct row, by the same name table §20.2 uses today,
      extended with `browser-tea`'s `Tea.*`, `browser`'s `Browser.program` and `page`'s
      `Page.sandbox`;
    - it leaves the table for O3's `entry` word to replace;
  - the measurement script in `bench/` that runs it.

  *Accepted when:* the four `SchemaDecl*` projects check under enforcement with a cache, and the script
  reproduces §30.2's table.
- **O1 — the corpus, by the owner's rule-10 decision on §30.2's list.**
  - *Builds:* causes 1–3, which are real, take their fix from the message (`List.copy`, or the top-level
    value made a function) wherever the fixture tests something other than persistence. A fixture that
    tests persistence itself (`ListPersistence`, the identity tests through `refEq`) is the owner's to
    rewrite or retire, and it retires with the trie in O5 at the latest.
  - Each cause-4 limit gets a red fixture in `tests/pending/` first, then precision work in the checker,
    measured against every ownership golden (§28.11 item 4's rule). The work covers the tagger family,
    `Tea.application`'s forwarding, the function-valued `send`, `Ref.update`'s words and the applicative
    `andMap` chain.
  - The tagger messages that print exact are corrected to approximate.

  *Accepted when:* O0's flag finds no rejected and no pending line in the whole corpus, the examples, the
  bench apps, core and every platform. No limit is answered by adding a `List.copy` to a platform or to
  core (the 2026-10-14 *subscription tap builder* amendment's rule).
- **O2 — the pass on the DAG, and the block in the interface** (§28.11 item 1, §16.9–§16.10).
  - *Accepted when:* the firewall holds for every build, as `cache_test.zig` shows. The 100 000-line
    benchmark, Conduit and the corpus pages meet §28.8's target with the pass on, or the miss is reported
    with its profile.
- **O3 — every runtime meets the direct row.**
  - *Builds:* the `entry` word (§30.3) and its refusals, with `trusted-surface.txt` rows and flips; §20.2's
    name table deleted;
  - `backend.md` §15.5's identity rule in the `dom` lowering and `Rt`: no `items === s.b`, no `same`, no
    list-typed item, input, value or hole skipped by `===`, and `s.b` no longer kept;
  - the P1 audit of `browser-tea`'s driver and `browser`'s runtime;
  - the template row and the `platform` cause deleted.

  *Accepted when:*
  - research 29's harness runs every operation on `browser` and `browser-tea`, before and after, against
    Solid 2 (CLAUDE.md rule 8), and any loss is reported, not put back;
  - fixtures pin a `For` over a list written in place and a row whose item is a list written in place
    (thesis T35–T37, T47). They are red against a runtime that keeps the skip, which O5 proves once the
    write is really in place;
  - the `browser/` corpus is unchanged.
- **O4 — enforcement is the language's.**
  - *Builds:* the pass in every `check` and `build`, with a platform or without one; `"lists"` removed
    from `Manifest` and from `browser-direct`'s manifest; O0's flag deleted; §28.7's maker reporting
    every platform;
  - §28.10's `build/bad/direct/Ownership…` projects failing on `browser-tea` with the same golden, and a
    `node` project for each kind of error under `build/bad/`;
  - the determinism test run on `node` as well.

  - the tests of `src/js/Manifest.zig` for `"lists"` changed to read the key as unknown and ignore
    it, whatever its value;
  - the normative text that still says "on an in-place platform", or that `browser-direct` alone
    declares `"lists"`, rewritten to say every platform. These amendments supersede that text but
    leave it in place: `backend.md` §4's plain-array subsection (its *Writes*, invariants 1 and 8,
    *Identity* and the open question), `language.md` §6.8's cost table and §10's row, this
    document's §20.2, §28.2 and §28.6, and `boundary.md` §5.2. The slice's PR lists every passage it
    rewrote.

  *Gated on:* O2's measurements of the 100 000-line benchmark, Conduit and the corpus pages with the
  pass on. Where one misses §28.8's target or `fast-compiler.md` §2's budgets, the owner accepts the
  measured number, or the miss is fixed, before O4 turns the pass on for every build. A miss reported
  in O2 does not let O4 go ahead by itself.

  *Accepted when:* the gates are green with no golden changed but O1's, and the run hashes are unchanged:
  nothing emitted moves.
- **O5 — the representation and the in-place lowering, together, on every platform.** This is
  `browser-direct.md`'s S7, items 1 and 2, and it needs the oracle conditions C1–C5 first.
  - *Preconditions:* C1–C5 (`browser-direct.md`, the last amendment and its 2026-10-15 follow-up), and
    W27's `language.md` §11.12 amendment written.
  - *Builds:* `backend.md` §4, *The representation: a plain array*, with *Every platform edits in place*:
    the trie deleted; plain arrays and read-only views; every accepted demand lowered in place, including
    every construction and `++` chain; the public writers in place; the optimiser barrier; fresh literals
    (invariant 7). The run hashes are re-recorded.
  - *Accepted when:*
    - C3's fixtures pass;
    - the whole `run/`, `browser/` and `emit/` corpus prints its value-semantics goldens, recorded under
      E1tp before this slice, with no golden changed but those of `emit/` that show the lowering;
    - the stale-read sanitiser build (thesis §12.2, a hidden test-only flag that versions each array and
      traps a read through an old holder) runs the corpus clean;
    - `size-parts.mjs` finds no `trie*` part in any bundle;
    - `bench/arrays`, research 29's harness, TodoMVC and Conduit are measured before and after;
    - and a search of `core/List` finds no copying twin of a writer.
- **O6 — record assignment** (`browser-direct.md` §7.4, its condition C4) stays `browser-direct`'s. It
  comes after O5, under C4, and nothing here waits for it. **It consumes the identity rule, though.**
  The rule that only a list loses its `===` skip holds only while lists are the one thing written in
  place. That rule is in `backend.md` §15.5, `language.md` §11.11 and `boundary.md` §9.4.4, all
  amended 2026-10-15.
  - Before O6 assigns through a record, those three are amended for every container type it writes,
    on every platform whose runtime may meet such a record.
  - `browser-direct`'s own skips already obey its §7.4 first rule: no group decides "unchanged" from
    the identity of any object on a path written in place, records included. So O6 changes nothing
    there.

### 30.8 Open questions

The platform question is closed, and the slices have no open question. One decision is the owner's,
under CLAUDE.md rule 10, and O1 waits for it: **which of the persistence and identity tests of
causes 2 and 3 are retired, and which are rewritten with `List.copy`.** These are `ListPersistence`,
`ListForms`, `ListPrepend`, `ListSpreadPatterns`, `ListIdentity`, `ListIndexedIdentity` and
`WriteRowsIdentity`. The rest of O1 is decided as §30.7 writes it. That covers the cause-1 fixtures,
`QueuedListSnapshot`, the precision work, and the correction of the eight tagger lines that print as
exact, which is part of O1 and not left to choose.

**`entry` on a third-party platform** is checked the way every ownership word is (§24.6). Its
placement and shape are refused when wrong (§30.3). Whether the runtime behind it keeps P1–P4 and P7
is not checked. It is trusted, as a `foreign`'s words and its sibling's behaviour are. The platform is
privileged code (CLAUDE.md rule 6), and a false claim is a defect in that platform. Shipped and test
platforms are pinned by `trusted-surface.txt`. A third party's are not.
