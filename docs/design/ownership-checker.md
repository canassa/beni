# The ownership checker — the in-compiler contract

> Test policy, 2026-10-22: per-test instruction limits, grants and reference CPU
> requirements were removed (#740). Each test or corpus case now has a
> 120-second wall-clock hang guard. Older counts and budget references below
> describe historical evidence, not a current gate or an outstanding grant.
> Performance remains the job of `test-perf` and `bench`.


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
*Amended 2026-10-17: records written in place (the owner). Every record update consumes its base, on every
platform; one the checker cannot prove safe is a compile error, never a copy. Specified, with a measurement and
the decisions still open, in §31.*

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

*Amended 2026-10-17 (§31.2):* a record type never crosses, whatever its fields: a record is an object written in
place, so it carries its cell. A tuple of crossing components still crosses, and a nominal type crosses only if
its definition reaches no record either. The record type's clause above is withdrawn.

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

*Amended 2026-10-17 (§31.3):* the `record` row gains `(ε, site(ι))`, the object the literal makes; the
`{ r | f = y }` row is replaced by §31.3's: the result is the base's own object, `(ε, c ∖ F)`, and the update is a
demand on it.

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

*Amended 2026-10-16 (§30.11):* item 3's cell made by the call is withdrawn for every call but a markup
construction: a function the checker cannot identify may return a list something else holds, so its result
is `⊤call`, never owned. A record field called with a dot is the field's value called.

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

*Amended 2026-10-17 (§31.4):* a record update is a demand too, with the same five conditions read for a record
object: Disjoint deep, Captured through once closures, and Dead per field — a later read of any field is
accepted, a written one read first by the lowering (§31.14), and a later whole use refused. §31.4 states them.

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
  search, which is locals × entries per demand. Each corpus case has a
  120-second hang guard. Performance claims belong in `test-perf` and `bench`.

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
   *Amended 2026-10-16 (§30.11):* that rule's result is `⊤call`, never owned, except for a markup construction.
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
| Width cap (§4.6, §4.9) | built, then **deleted** 2026-10-16 (§16.7): no summary is cut to fit; what outgrows the source is limited, each limit an error |
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

*Amended 2026-10-16 (#220): how the read-off is computed, not what it reads.* Read pair by pair, a result's spine
conditions (§18.3's `sc`: a returned container shares no cell with the result's other positions) cost a sweep
of every other entry per entry, each conjunction re-sorting the atoms gathered so far, and the fresh numbering
a sweep of the result per new cell: 94% of the pass on #220's dashboard once nothing was cut. The read-off now
sorts the result's entries once by what §18.2's separation can say of a pair. A pair whose kinds alone make it
`yes` — a closure; a top-level value's cell beside any but its own value's; a cell made here beside one that
arrived, unless that one is a callback's result — is never formed: each entry is compared with the taken, `⊤`
and message cells, with the cells that arrived when it arrived, with the callbacks' results when it was made
here, and with its own value's or call's cells for `covers`; a cell found at two paths is `lost` at once; and
the atoms are sorted once per entry. The fresh numbering sorts `(cell, path)` pairs. Every condition is the
pairwise definition's — under runtime safety the two are compared for every result of up to 8 entries — and
no verdict moved: the dashboard's reports at 16 to 256 widgets are byte for byte the pairwise ones.
*Amended 2026-10-17 (issue #272):* the build option `-Downership-full-cross-check` compares the two for every
result, whatever its width, in a safety build; it is slow, so the gates refuse it and the budget does not hold it
(without changing assertions). The whole black-box suite passed it on 2026-10-17 with no difference.

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

*Amended 2026-10-16 (issue #281): the keep edge.* Item 4's supply edge covers an actual that **writes** what
it is supplied, not one that **keeps** it in its result. A callee that hands a callback a list, keeps what the
callback returns, and then writes that list changes a list the result holds:

```elm
kParam f xs =
    t = f xs
    ( t, List.push xs 9 )   -- with f = λys → ( ys, 1 ), t.0 is xs, pushed onto
```

Inside the callee the callback's result is `cb_j`, which holds nothing the walk can see, so the write was
accepted there, and the caller saw only a fresh argument. Two rules close it:

- **A parameter, at the call.** For every borrowed supply `(k, q′, πᵢ.q″)` of the callee — borrowed because
  the callee uses `πᵢ` after the call — whose `πᵢ` is changed after the call, an actual whose class may keep
  its `k`th parameter is rejected, cause `supply`. `πᵢ` is changed when the callee writes it (`(i, q, U ∋ W)`,
  `q` overlapping `q″`) or hands it to another callback whose actual writes the part supplied, has no class, or
  is the caller's own function parameter (`keepThenHand f g xs = t = f xs; ( t, g xs )`). The path at which
  the class keeps `π_k` is not compared with the path changed: a keeper of one field and a write of another
  are refused too, approximately, as is a callee that writes `πᵢ` before the call and only reads it after. A class may keep it when a
  `res` entry has provenance `π_k`, `cb` (what its own callbacks return) or `⊤`; an actual with no class may
  keep anything. The rejection is approximate: the summary says that the callee uses `πᵢ` after the call,
  not that the write is that use. When the actual is the caller's own function parameter πⱼ″, the caller's
  `fun(j″)` gains `need = owned` (item 4): a function that returns a borrowed supply does not return owned.
- **A list the callee makes, in the callee.** A call of the declaration's function parameter (§16.4 item 4)
  hands it cells; for a later write of one of them that is not one of the declaration's parameters, the
  callback's result is a holder, approximately (§8.1's holders; the rejection's cause is `call`). The write is
  the callee's own, so the callee decides. The callback's result keeps no new entry in the summary: at the
  call, `cb_j` is instantiated from the actual's class, which says exactly what it keeps.
- **A list the callee makes and returns, at the call.** When that list also leaves the callee in its result,
  a caller may write it while the kept result lives (`makeKeepReturn f = xs = [ 1 ]; t = f xs; ( t, xs )`). A
  supply of a cell the result numbers keeps that fresh number, renumbered as the result's entries are (§16.3, where
a supply's number was always 0),
  and at the call it is instantiated as the result's cell, not as a new one of the callback's depth, so the
  caller's `kept` and `xs` share it and the caller's own checks see the alias.

`ownership/CallbackKeeps` pins them: a keeper rejected, a dropper accepted, a second callback that writes the
kept list, a callee that writes a list it made after handing it on, one that returns it beside the kept result,
and a wrapper whose own function parameter must then return owned. The
`need` line of that wrapper says the callee "edits what it returns": `need` carries no reason (#272).

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

*Amended 2026-10-22 (#210, CK-268): keep the possible writer conditional.*
When a keep edge's only possible writer is another function parameter or slot
of the enclosing declaration, its keeper gains an owned-result requirement
conditional on that writer, rather than an unconditional `need`. The summary
names each such writer by its function parameter or slot. Through a wrapper,
its actual is mapped to the wrapper's own function parameter or slot. A known
actual with no list write discharges this condition; a known writer, an unknown
class, a limit, or a class whose own callbacks may write keeps the requirement.
A concrete write in the callee still requires an owned result unconditionally.
When the keeper is already concrete but its writer remains unknown, the
existing conservative keep-edge check remains. No unknown callable is made
known, no opaque value is made fresh, and no record obligation changes.

The dependencies are sorted and deduplicated, joined monotonically and counted
under the existing summary entry limit. Summary block v26 encodes them and
summary equality compares their contents. `ConditionalCallbackKeep` pins the
nonwriting and sharing cases through a record slot and wrapper;
`ScalarCallbackSlots` pins a unit-state Durable Object. The latter's opaque
response needs no freshness assertion: its concrete handlers write no list.

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
*Amended 2026-10-16 (§30.11):* that covers what such a function writes, not what it returns: its result is
`⊤call`, which no write and no `need` may rely on.

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

*Amended 2026-10-22 (#754): an annotation with a container condition is one per result path.* The rule above
merged a member's annotations too (the `condition(…)` entries of the dated amendment *fold ownership follows
the written path* under §28, #720). An annotation's container condition (`sep_root a b`) names the arrays at
its own place: at a call, its guards go under the entry's path, one for each array of `a`. Merged, one
annotation stood at every path any of them stood at and carried all their conditions, so each place put the
other places' guards under itself, `[*]` at a tuple's root and `.0[*][*]` below a list. The next round read
those guards off and put theirs a level deeper again, until the cut of §16.7: `Result.partitionHelp` and
`List.unzipHelp` took 18 rounds, and their summaries held guards at every depth down to the cut. Inside the
group, a call now makes one annotation per result path for each entry whose container condition has a
`sep_root` atom, numbered apart from every fresh and callback number, and still one cell for the member's
allocations and for its other annotations, whose deep and record conditions name cells and not places. The
numbering stays finite, since the result paths do. This is the instantiation a caller outside the group makes,
so it is as sound as that one is. No verdict of the corpus or of core changed;
`ownership/RecursiveTupleGuards` settles in 3 rounds.

### 16.7 Limits, and no width cap

*Amended 2026-10-16 (the owner, #220): the width cap of 64 paths and coarsening are deleted. The text they
replaced is in this section's history; what follows is normative.*

**Nothing a type bounds is capped.** A summary names paths of its parameters and its result, and those are
bounded by their types: cut at k (§4.1) and folded where a type is recursive (below). The fresh numbers are
bounded by the result paths (thesis §4.6's `k ≤ |Q|`, next paragraph), and the provenances by the parameters'
paths, the declaration's own cells and the top-level values it reads. So a summary is as wide as the program
it describes, and it keeps every fact: **no summary is cut, merged or made approximate to fit a limit**. A TEA
`update`'s parameter is the model, and its paths are the model's: thesis §4.9's "say 64" counted that, and #220
measured what it cost — a 256-widget dashboard whose `step` needs 167 result paths had its summaries coarsened,
silently, from 16 widgets on, and its build refused at 256 under a message that blamed a list "from
JavaScript" the program had already copied.

**What can outgrow the source is limited, and reaching a limit is an error.** The checker's limits are on
what grows faster than the program — products of paths and provenances, conditions between pairs of result
positions, rounds of a fixpoint:

| Limit | At most | What it bounds |
|---|---|---|
| `entries` | 262 144 | a summary's entries in all, `use`, `res` and `supply` together |
| `path-entries` | 4 096 | its entries at one result path, or at one `(j, k, q)` of a supply |
| `conditions` | 1 048 576 | the atoms of its conditions (§18.3) in all |
| `rounds` | 32 | the rounds of a recursive group (§16.6) or of a block's local functions (§18.7) |
| `owned-atoms` | 8 | the distinct `returns owned` atoms `(j, q)` its `owned` bits rest on (§16.4 item 5) |
| `value-cells` | retired 2026-10-22 (#712) | the same deep condition is computed through a cell-family index; the wire ordinal is kept, but no walk produces this limit |
| `fixpoint` | 32 | the rounds of a fixpoint inside a walk: the model at entry and its exclusivity invariant (§20.4), a callback's result, a fold's shape and its spine (§16.4 item 6). *Amended 2026-10-16 (#229):* their cells are finite, so they settle in a bounded number of rounds (§28's dated amendment *the entry's fixpoints settle*); before, each ended on a silent backstop: 8 rounds for the model, 4 for a callback's result and a fold's shape, 32 for the invariant and a fold's spine |
| `callbacks` | 4 | *Added 2026-10-16 (#271):* a chain of callbacks, each instantiated inside the one before or handed the result of the one before (§16.4 items 5 and 6). Before, a fifth callback ended the walk silently: a demand was dropped, or a callback's result became a `⊤` with no alias of what the chain was handed |

A declaration whose summary would pass one is reported as **one error at the declaration**,
`ownership_limit`: it names the declaration, the limit and what it measured, and says that the limit is the
compiler's and not sharing in the program. The declaration's summary is then the pessimistic one of §16.2,
`limit <name> <measure>` in its line, so that the walk can go on; a rejection elsewhere that rests on it — a
call-site demand it makes, a `⊤` it returns, `⊤limit` in a summary line, however far they travel — has the
`limit` cause (§16.11); a run that reports a limit does not report those rejections as errors too, since they
follow from it.
The dump prints `limit f: <name> <measure>, over <limit>` after the module's summary lines (`limit f: rounds,
unsettled after 32` for a fixpoint).
*Amended 2026-10-17 (#272, #233): what follows from a limit takes its cause.* "Rests on it" covers two more
ways, which before were printed as errors of their own beside the limit's:

- **A call applied a pessimistic summary** (a callee whose summary is past a limit): every line the call makes
  for its function arguments — a `need`, a `pending` "keeps it" line, a borrowed supply a callback writes —
  takes the `limit` cause, as the call-site demands on its arguments already did.
- **A condition the walk lowered at a limit** — a fixpoint's seeds (§20.4, §16.4 item 6), a value past
  `value-cells`, a class whose summary is the pessimistic one — is `cond_limit`, which fails as a lost condition
  does; a demand that fails only through it takes the `limit` cause. An exact failure still wins: it is sharing
  the checker can see. A demand that fails through `cond_limit` and through an approximate cause too takes the
  `limit` cause, on purpose: the build already fails on the limit, and once the limit is gone the condition is
  computed and an approximate failure that remains is printed then.

A function value's line of its own is never hidden by one that follows from a limit: a lambda handed to the
limited callee and also stored where the walk loses sight of it is reported for the store, and a sight made
under the limit does not count as a top-level function's report.

A declaration whose walk reached a limit inside it (a fixpoint, `value-cells`, `callbacks`) now has the pessimistic summary,
as this section says of every limit; before, only `rounds` and the summary-size limits made it, and a caller saw
a condition the callee lowered as a plain lost one, a second error. So a call of a declaration past a limit reports none of
its own errors until the limit is gone: what it does to its arguments rests on the limit, as it always did for
`rounds` and the summary-size limits.

`check/bad/direct/OwnershipLimitPessimistic` and `OwnershipLimitValueCells` pin both: each build has the limit's
error alone, and every error of its own besides.

The bounds are set from the largest summaries measured, #220's dashboard at 1 024 widgets — one module of
22 000 lines, its `step`, `pushed` and `update` the widest: 23 456 entries, 300 at one path and 87 764
condition atoms, each about a tenth of its limit. The `owned-atoms` guard counts distinct atoms; before
2026-10-16 it counted the supply entries that rest on one, so that `Dict.merge`, 13 entries over 3 atoms,
reached it and had its last five owned supplies made borrowed, silently. *Amended 2026-10-16 (#229):* the
fixpoints inside a walk are under this rule too — the `fixpoint` row. Before, they ended on silent backstops,
and the model's exclusivity invariant (§28's dated amendment) reached its backstop in every application
measured, because each round made a carried lambda anew (§28's dated amendment *the entry's fixpoints settle*).

*Amended 2026-10-17 (issue #293): a conjunction of many conditions is gathered once, and the `conditions`
limit holds while it grows.* A list literal of n list parameters stores n items, whose condition (§18.2's
table) has an `excl` atom per item and a `sep` atom per pair. It was built one `condAnd` at a time, each
copying and re-sorting every atom gathered so far: O(n⁴) time and memory, 12.6 billion instructions at
n = 100, over 10 GB at n = 300, and the limit, checked on the finished summary, stopped nothing. Every
conjunction over a loop — a stored list's items, a value's deep condition, two values' separation, a
spine's, a taken element's, and the instantiated conditions of a callback's supplies — now gathers its
atoms and sorts and deduplicates them once, as §16.3's read-off already did; the verdict is the same
(`condAnd`'s order: shared, then a limit, then lost). A conjunction whose distinct atoms pass the
`conditions` limit while it is gathered is that limit, at once, and keeps nothing more. At n = 100, 200
and 300 `dump --platform=browser-direct` costs 1.6, 2.3 and 3.6 billion instructions, 1.5 of them the
platform's own at n = 1 (it was 13.5, 203 and out of memory at 10 GB), with the same report; `ownership/ListOfParams` pins n = 100 under the budget it was three times over.

*Amended 2026-10-16 (#271): every cap, loud or conservative.* A cap is **loud** when reaching it is an
error (one `ownership_limit` at the declaration, its rejections given the `limit` cause), and
**conservative** when the walk goes on with a rule that is sound for every program, at a cost in
precision. No cap may be silent, that is, accept a program because the walk stopped. The ones in the
code:

| Cap | Value | Where | Past it | Kind |
|---|---|---|---|---|
| `entries`, `path-entries`, `conditions`, `rounds`, `owned-atoms`, `value-cells`, `fixpoint`, `callbacks` | the table above | summaries and walks | the table above | loud |
| the path cut `k` (`k_limit`) | 8 | every path (§4.1) | the step is dropped, so two places merge into one: a call that writes one of them is not seen to write the other | **silent**, issue #286 (below) |
| `type_depth` | 16 | the walks over types: what a type may hold or share (`tracked`, `holdsList`, `mayShare`, `mayHold`, `ownMayHold`), a type's facts | "may hold", "may share" | conservative |
| `type_depth` in `occursBelow` | 16 | `mayShare`'s shortcut (rule 4) | "does not occur": the shortcut is not taken | conservative |
| `type_depth` in `typeExprHeads` | 16 | which types a type names, for "is this type recursive" | the type may be taken for one that is not: only "exact" becomes "approximate" or the reverse in a line; both reject | conservative |
| `split_cap` | 8 | a supply probed cell by cell (§30.9 rule 5) | probed whole | conservative |
| the evidence walk (`evidenceSight`) | was 8 levels of nesting | a writing function passed as evidence (§16.5) | *before 2026-10-16:* not reported, silently; now every term is walked, each once per site, and there is no cap (`ownership/EvidenceDeep`) | removed |
| `termTaint` | 8 levels of nesting | a codec's evidence (§30.10) | `⊤` in both slots | conservative |
| `markupEvents` | `k` | the events of markup inside lists and `Maybe`s | the whole value, not its events | conservative |
| `aliasTarget` | 8 hops | a point-free top-level alias (§30.9 rule 9) | no name: the value is called as §6.1's call | conservative only with §30.11's `⊤call`; before it, the #216 hole |
| `inst_depth` | 4 | `instProv`, `callbackLoanDemands`, `returnedParamDemands`, `provOwned` | the `callbacks` limit (`ownership/CallbackChain`) | loud |
| a reference the provenance does not resolve | — | `.top` and `.ext_value` | *before 2026-10-16:* holds nothing; now `⊤` | conservative |
| a capture a walk has not bound, in a condition | — | `classSide` | *before 2026-10-16:* holds nothing; now `⊤` | conservative |
| a limit reached outside a declaration | — | `hitLimit` | unreachable: every walk names its declaration, and a safety build asserts it | — |
| `wide_index` | 256 | an index of wide values by their first step | not a cap: the same entries, found faster | — |
| a constructor step's fields | 64 | a path step `#C.i` is `c · 64 + i`, and a summary block refuses `i ≥ 64` | *before 2026-10-17:* field 64 of a constructor named field 0 of the next constructor, so two places merged, and across modules writing the block crashed `check`; now a step names its constructor and field through a table of `(constructor, field)` pairs, exact for any field, and the block writes the field as a u32 (version 15; `ownership/WideCtor`, `ownership/WideCtorBlock`) | removed, issue #289 |
| a carried lambda nested in a summary block | 16 | `readSummary` | the block is refused as not one | unreachable: the walk carries no lambda that deep; an assertion, not a cap |
| `rootToken` | 64 steps | the first token of a variable path, for a message | a later token of the path | diagnostic position only |

**The path cut stays silent for now (issue #286).** The cut is relative to the root of each value, so a caller
can cut a path its callee does not: a caller that passes `r.a.b` to a callee that writes `s.c.d.e.f.g.h.x` and
then reads `.y`, where `.x` and `.y` hold one list, has `r.a.b.c.d.e.f.g.h.x` cut at 8 steps, and the call is
accepted while its depth-7 twin is rejected `disjoint`. A loud cut is no answer: core's `Schema` (`parserOf`,
`collect`, `unpack`, `made`, `productOf`) reaches it at 8 steps and at 16, because those paths have no fixed
depth — nested tuples, one level per schema field, and chains of `parent` records — and the cut is what keeps
their summaries finite. So the cut must become conservative: an entry that the cut merged stands for more than
one position, through projection, wherever a check relies on two paths being two places. Issue #286 owns that
design, its measurements and its fixture. The owner decided on 2026-10-17 to land the other caps first.

The fresh numbers do not count toward any limit: as thesis §4.6 bounds them (`k ≤ |Q|`), a number only says
which result paths may hold one new cell, so the read-off of §16.3 gives two new cells that appear at the
same result paths the same number — a TEA `update` that builds its model from forty literals has a handful.

**Recursive types are folded** (thesis §3.1, which slice 1 did not need, §1.2): a constructor step into a
value of a type the path has already entered goes on from where the path first entered that type, so
`t#Node.3#Node.1` is `t#Node.1`, and a summary over a `Dict` or a tree names a few paths instead of every
level to the cut. Folding only merges places, so it adds aliasing and never removes a holder; a demand
on a folded path is checked against every level it stands for. Folding is what makes a recursive type's paths
finite, and so is part of what bounds them, not a limit.

*Amended 2026-10-17 (issue #286, the owner's decision (b)): a projection keeps the levels folding merged.*
"A demand on a folded path is checked against every level it stands for" held only where nothing was taken
apart. A value's folded entry `t#Node.1` holds the root's list and every level's below it; a pattern that took
`l` out of `t` at `#Node.0` kept only the entries whose first step was `#Node.0`, and folding had left none
there, so `l` held nothing and `case l of Node _ zs _ → List.push zs 1` was accepted `fresh` while `zs` was
the `xs` the function returns. A projection along a constructor step `#C.i` of a recursive type `T` now also
keeps every entry whose first step is a constructor step of `T`, approximately (the derivation *a place that
stands for several*, cause `element`):

- at its own path, when field `i` is a value of `T` (`Node Tree …`'s `#Node.0`);
- at `⋆`, when `T` is further down (`List Rose`, `Maybe Tree`, a function's captures, a `foreign type`), where
  the path to it is not written;
- nowhere, when the field cannot hold a `T`, or holds one only through a type parameter (below).

**Folding never goes through a type parameter.** A level folds onto the first step into `T` since the path last
went through a field that holds `T` only through a parameter of the type: below `Dict`'s value field of a
`Dict String (Dict String (List Int))` is another dictionary, not a level of this one, and merging it would ask
every projection of a value to keep what may lie below it. Each inner value folds onto itself instead; the paths
stay finite because the type is.

The same commit fixes what a type may hold for mutually recursive types (§4.4). Whether a nominal type holds a
cell is read off its definition, a type being read taken to hold nothing; `type B = B A` read while
`type A = A B (List Int)` was saw `A` hold nothing and was remembered so, so `B` crossed and a `B` held no
cell. Only the outermost type of such a cycle is remembered from that read now.

`ownership/FoldLevels` and `ownership/MutualTypes` pin it: each push was accepted `fresh` before and is rejected
now. The cost is one refusal of safe code, `FoldLevels.pushRoot`, which builds a fresh list at every level and
edits the root's while reading a subtree: the levels share one place, so the root's list may be the subtree's.
Telling the levels apart is the representatives' exclusivity of thesis §3.1, which is not built. The corpus,
`bench/ownership-everywhere.mjs`, core and every platform refuse nothing new.

*Amended 2026-10-18 (review of PR #341).* Three findings on the amendment above:

- **Precision lost on `Dict`.** A projection into a dictionary's subtree now keeps the levels folded below it, so
  the conditions a summary states on a dictionary's subtrees — that they share no list with each other or with the
  values — are `{lost}` where they were atoms: `Toplevel.bump`'s `#Dict.0#Node.3` and `#Node.4` went from
  `{excl …, sep …}` to `{lost}`. No verdict in the corpus, the bench, core or a platform moves, but code that
  relies on a dictionary's subtrees not sharing, through a callee's `xreq`, is refused, approximately, until the
  levels can be told apart.
- **Mutually recursive types are solved once per cycle.** The fix of what a type may hold remembered only the
  outermost type of a cycle, and read every other one again on each path through it: exponential in the cycle,
  27 s for twelve types that each name all the others. What a type holds is now the least fixpoint of each strongly
  connected group of the types definitions name, solved once per group in Tarjan's order, every member starting
  from nothing (`ownership/MutualCycles`, under 1 s).
- **A parameter's folded levels are not yet checked** (open). "A demand on a folded path is checked against every
  level it stands for" holds for a value the body builds, whose entries the projection now keeps, and not for a
  parameter, whose symbolic cells compare paths step by step: `param(t, #Node.0)`, the left subtree, does not cover
  `param(t, #Node.1)`, the lists of every level, so `case t of Node l ys _ → ( List.push ys 1, l )` is accepted, as
  on master, while the same body over a tree built inline is rejected (`Rose` and `Pair (List Int) (Maybe Pair)`
  alike). Relating the two cells is sound but refuses `browser-direct`'s own `Tea.want`: `Dict.update` relies on the
  dictionary's values being exclusive, and a subtree that may be any level holds every value. The caller must
  instead discharge that the levels are pairwise distinct, which is the representatives' exclusivity above; the hole
  closes with it. The hole is called **`paramHole`** below. It is CK-254, and the red fixture
  `tests/pending/ownership/ParamHole.beni` tracks it: `shared` hands `hole` a tree that holds one list at two
  levels, and both are accepted today.

*Not yet built: decision (a), folding only types that reach themselves.* Folding any type the path already
entered — `Maybe` inside `Maybe` — is what keeps core's `Schema` finite today: a value cast through `Js.Value`
and back is read at another type, and the paths of `unpack`, `collect` and `productOf` grow by one step per
cast, `#Just.0#NonNull.0#Just.0…` and `.parent.parent…`. Folding only recursive types sends `Schema.run` and
`descend` past the `entries` limit and four more of its functions past `value-cells`, so (a) waits for the cast
marker of the next decision; until then `Maybe (List Int × Maybe (List Int))` folds its inner `Maybe` onto the
outer one, and the hole of `pushInner` (accepted through a call, rejected inline) stays.

*Amended 2026-10-18 (issue #286, the owner's go-ahead): the design pass for the path cut.* This is a design and
a record of measurements; nothing in it is built. The path cut `k` (§4.1) is silent (the table above): it merges
two places at the cut, so a write of one is not seen at the other (`writeRead`/`deep`, a nine-step path cut at
eight). Removing it needs every source of unbounded paths to have a fold point, and each fold point must keep
summaries finite and stay sound. Four sources were found (the investigation of 2026-10-17 and the reviews of
#341): recursive types, which fold today; closures that capture closures; casts through `Js.Value`; and
polymorphic recursion over a nested datatype. Each fold point below gives its soundness argument and its own
rejection delta, measured separately on `master` (`2cabeed03`) with an experiment patch that was not committed,
over `bench/ownership-everywhere.mjs` (873 programs, every platform's modules and core, browser-inline's pages,
goldens and modules included) and the verdict lines of `tests/corpus/ownership/`.

**F1. Closures fold at their environment step.** *The first form below, its three bullets and its delta are
superseded by the amendments after them (the fold under the marker); they are kept as the record of what was
measured.* A function type is taken to be recursive: a `◇` step on a
path that already has one goes on from where the first entered, so `◇p◇q` is `◇q`, and a projection along `◇`
keeps every entry whose first step is `◇` at its own path, approximately (`approx_place`), as §16.7's
amendment does for a field that is the type itself ("here").
- *Soundness (superseded: unsound, see the amendment).* Folding merges places: the environments of a closure and of every closure it captured share one
  place, so every cell any of them captured is held at `◇q`, and a demand on one of them sees every holder of
  any. A projection along `◇` keeps the folded entries, so nothing merged is dropped when a closure's
  environment is taken apart (`instProv`'s `◇x.q`, `expandInto`). Folding `◇p◇q` into `◇q` also merges every
  place at `p`, the steps between the two `◇`s, into the place at `◇q`; that too is only more aliasing. The fold
  only adds aliasing, so it stays sound.
- *Finite (superseded).* A path holds at most one `◇`. `mk n xs = if n == 0 then λx → x + List.length xs else (g = mk (n -
  1) xs; λx → g x)`, whose summary is `res ◇ π2, ◇◇ π2, …` cut at eight today, is `res ◇ π2`.
- *Delta: none (superseded: measured for the first form).* The bench is unchanged, browser-inline's pages, goldens and modules included; in
  `tests/corpus/ownership/` fifteen goldens change, only in summary lines (`◇◇…` merged), and no verdict line.
  The owner's concern — that closures capturing closures become one place, so higher-order code and
  browser-inline's generated handlers pick up refusals — does not show: a closure's demand is on the cells its
  environment holds, and the merged place holds the same cells. A capture of a capture written while the outer
  closure lives is still rejected `captured`.
- *Amended 2026-10-19 (the review of #378): F1 folds under the level marker.* `◇p◇q` → `◇q` is unsound as
  written above, and "the fold only adds aliasing" was not the argument: a fold can also *remove a containment*.
  Folded, the inner environment's `◇q` is a prefix, step by step, of the outer environment's other places, so the
  inner `◇`'s cells read as the container of the outer `.b`, and a deep condition, which does not separate a
  container from what it holds, never compared them: `g = λ⊤ → List.length xs; s = { a = g, b = xs }` and a
  closure over `s` hold `xs` twice, and `[ f ]` was `{excl π1}` where it is `{shared}` (`ownership/EnvPrefix`).
  The same fold lost that `◇.g` holds what `g` captured, and kept an exact entry at the rest of `◇q` that stood
  for `◇p◇q`. So a function type is taken for a recursive type of its own, whose one region step is `◇`: a `◇` on
  a path that has one already goes under the marker of that region, `◇p◇q` is `◇⟨◇⟩◇q` (the places `q` of the
  environment of every closure at or below the first environment), and everything the marker's text above says
  applies — overlap and holding through the marker, projection keeping a marked entry whole, a marker's place a
  representative. The marker stands where the value may be a closure or not (`.maybe`): an environment holds
  closures further down (`◇p◇q`, `p` not empty) or is one, a closure captured directly (`◇◇q`, the empty
  expansion), so its expansion may begin with any step and may be empty. (As first built the marker was
  `.below`, never empty, and the place `p = ∅` was reached only through the empty path's overlap with every
  path; the review of #403 found it, and `ownership/DirectCapture` pins the direct capture read, written live,
  written after, written inside, stored and passed through a summary, each verdict master's.) The fold now keeps a mark wherever it merged places, and the soundness
  argument is the marker's: a place the fold merged is one the marker stands for, so containment through it is
  approximate, never lost. (This paragraph ended "and no pair a deep condition must compare is taken for a
  container and its contents"; as built that was false, and the next amendment corrects it.)
  *Finite*: a path holds one `◇` and at most one closure marker after it. `mk`'s summary is `res ◇ π2, ◇⟨◇⟩◇ π2`.
  *Built 2026-10-19.* The bench is unchanged; in `tests/corpus/ownership/` sixteen goldens change, in summary lines
  only (`◇◇` and `◇.a◇` become `◇⟨◇⟩◇`). `ownership/Clo` pins `mk`, `EnvPrefix` stays `{shared}`, and
  `ownership/ClosureLevels` pins a capture written while a closure that holds it is held through a record field,
  through a closure in a closure in a record, and through a call. The summary block's marker step names no
  module for this type. Core's check costs 3 324M instructions, less than before F1.
- *Amended 2026-10-19 (the review of #403): two environments the fold merges are still compared.* The marker
  keeps containment, but it also puts two *sibling* environments at one place: `g1` and `g2` both capture `xs`,
  `s = { a = g1, c = g2 }` and `f = λ⊤ → s.a ⊤ + s.c ⊤` hold `xs` at `◇.a◇` and `◇.c◇`, which fold to the one
  path `◇⟨◇⟩◇`. A deep condition compares entries at two paths, and here both entries sat at one, so `[ f ]` was
  `{excl π1}` where it is `{shared}`; the same loss dropped `sep π1 π2` (one list per closure) and
  `sep π1#Node.0 π1#Node.1` (two parts of one tree). So the deep condition also judges the pairs the closure
  expansion brings to one place. Each (closure, capture) the expansion enters is a frame of its own, and two
  entries at one path from different frames are compared as two paths are. One cell is `{shared}`, unless both
  entries are approximate (a merge the fold made, which already stands for the same cell twice). Two cells are
  `sep`, unless one covers the other. Every deep condition is then the one the unfolded checker gives, or
  `lost`. `ownership/SiblingEnvs` pins the record, tuple, nested record and constructor shapes (`{shared}`), two
  lists (`sep π1 π2`) and two parts of a tree (`sep π1#Node.0 π1#Node.1`): each is master's condition, and each
  was wrong before this amendment.

**F2. A cast marker that records the type it was read at.** *The measured head-only
prototype below is historical; the dated 2026-10-22 amendments supersede it.* Today `Js.from` and `Js.to` are `returned`: the
answer is the argument's cells at their own paths, so a value cast to `Js.Value` and back is read at its new
type by the old type's paths. Projected again across a recursive call, those paths grow without bound —
`Schema.unpack`'s `π1.0.0.0…`, `collect`'s `π1.parent.parent…`, `run`'s `π1.fail#Just.0#NonNull.0…` — and
only today's folding of every type seen twice and the cut keep them finite. The marker: a step `⟨as T⟩`, `T`
the head of a type (a named type, a tuple of n, a record, a function). At a call whose parameter is returned at
another type, read off the call's own types (`instRes`, `arg_types`, `result_ty`; a type variable on either side
is no cast, since the concrete caller casts):
- into an opaque type (`Js.Value`, any `foreign type` but `List`), the value's entries below its root are put
  under `⟨as T⟩`, `T` the type it was made at; its cells at its root stay (a cast is the same array);
- out of an opaque type into `T`, an entry under `⟨as T⟩` loses the marker and is exact; one under another
  type's marker, or one no cast marked, is at `⋆` (it is read at a type it was not made at); a symbolic cell
  `param(x, q)` becomes `param(x, q⟨as T⟩)`, so what is read below it is read in `T`'s steps;
- a second `⟨as T⟩` on a path folds onto the first as the deeper level `⟨as T⟩⟨as T⟩`, which a projection keeps
  wherever it goes until a read at `T` takes the marker off.
- *Soundness.* Exactness is kept only where the type read at is the type made at; everything else is `⋆`, which
  overlaps every path. Two cells that differ only by a trailing marker are one array (`covers`, the spine index).
  A path with a marker overlaps any path that differs at the marker (`overlapSteps`), so liveness never misses a
  use through a cast. The folded levels behave as §16.7's do for a recursive type.
- *A gap in the head.* The marker names a head, not a type: `Maybe String` and `Maybe (List Int)` share the
  head `Maybe`. Nothing rules out a cast made at one and read at the other. `Js.to` is `returned Value → a`,
  unchecked, and "the caller answers for the type" (`core/Js.beni:45–47`); the checker reads it as any `returned`
  foreign, the result being the argument's cells at their own paths (`wordsRow`,
  `src/own/Ownership.zig:2464–2467`), and `src/own/` has no cast marker and no rule for `Js.to`. So a marker of
  the head alone would call such a read exact. The marker would need the type's arguments too, or a read whose
  arguments differ would go to `⋆`. This is part of the finding; the design is not chosen.
- *Finite.* A path holds at most two markers of one type. `unpack` becomes `π1⟨as ×2⟩.0, π1⟨as ×2⟩⟨as ×2⟩.0, …`,
  `collect` `π1⟨as Step⟩.parent, π1⟨as Step⟩⟨as Step⟩.parent`. The bound is combinatorial, not small: two
  markers per type, and every ordering of the types a value is cast through (the delta below).
- *Delta: a finding, not a design.* Core's `Schema` refuses itself: core's demands go from 116, none rejected,
  to 1 035, 481 rejected and 29 pending, every one in `Schema`. They follow from three `value-cells` limits
  (§16.7): `ctorArgs` 390, `fieldsFrom` 590 and `printWith` 450 cells, over 256, whose pessimistic summaries
  write every parameter of `run`, `descend`, `elementsFrom` and their group. These three are not the "four more
  functions past `value-cells`" of (a) below and of §16.7's earlier text: those were measured without a marker,
  folding only types that reach themselves. They are two experiments. The cause is the cells the marker
  makes, not the `⋆`s: trusting an unmarked or mismatched entry instead of putting it at `⋆` (unsound, measured
  only to find the cause) changes no count. Each cast of a symbolic cell names a new cell, and `Context.fail`
  is read through `Maybe`, `Nullable` and `Presence` in every order, so `π1.fail⟨as Nullable⟩#NonNull.0⟨as
  Maybe⟩⟨as Maybe⟩#Just.0` and its permutations are distinct cells: the per-type fold bounds each type to two
  markers, and the orderings of the types still multiply. The coarser marker, every cast at `⋆` (2026-10-17),
  refused safe programs too: twelve more rejections among the schema fixtures and five more programs
  (`browser/direct/ApiItems` on two platforms, BikeWars on two, `examples/bike-wars`), all `~need`. **The owner
  decides** between bounding the cells a cast makes — every marker after the first folding onto it, whatever its
  type, which keeps `Schema`'s own round trips (`Step` to `Js.Value` and back) exact only at the first level —
  and raising `value-cells` (which the bounds paragraph above sets from measured summaries, and which a pairwise
  condition makes quadratic). Neither is measured yet.

*Amended 2026-10-22 (issue #286, the owner’s full-type decision): cast markers.*
A cast marker names the entire resolved structural type: nominal identity and every
argument, each tuple member, record field and extension, and all function parameters
and its result. Aliases are read through their expansion. Unresolved variables keep
their identity; a variable at the root on either side is not a cast. Type keys are
interned and compared by identity after structural equality, never by a type head or
an unchecked hash. Cached summaries store the complete key, not a session type id.

A returned parameter crossing between an opaque foreign type and a concrete type
uses the call’s instantiated types. Into the opaque type, entries below the root
are placed under ⟨as T⟩; the root itself is the same object. Out of it, entries
marked with precisely T lose that marker; mismatched or unmarked contents become
approximate ⋆ entries. A symbolic root is read through ⟨as T⟩, preserving the
relation to its source. These rules also apply when a summary projects a cast.
A second entry into T folds the intervening walk under the first marker, retaining
a second ⟨as T⟩ for deeper levels. Projection keeps folded contents approximately;
overlap treats a cast boundary conservatively, and a trailing boundary never makes
one physical object separate from itself. Every merged occurrence remains subject
to the existing construction conditions. Interning, projection and summary encoding
must share the same full-type identity. No cap, condition or budget changes here.

The soundness argument is preservation of every holder: exact cancellation requires
full type equality, other reads retain all contents at ⋆, and a folded marker retains
the deeper occurrences rather than dropping them. Each type has at most two cast
markers on a path. The existing path cut remains until the separate cut-removal
change; this amendment does not claim that it has been removed. Validation starts
with a fixture red before implementation, then the unchanged gates. Any newly refused
safe program or exceeded budget stops this work and is reported on #286. The owner’s
current no-measurement instruction supersedes the historical prerequisite above.

*Amended 2026-10-22 (issue #712, resumed under the owner’s precision clarification):*
The first entry into a full type is an exact cast boundary, not a representative
place. Only re-entry into the same full type folds, with a distinct folded step
that represents the deeper occurrences. Exact boundaries cancel on a matching read
and do not lower conditions merely because they are cast boundaries. This corrects
the first candidate’s treatment of every cast as a representative. Physical-object
identity ignores trailing exact boundaries; folded occurrences retain the containing
value’s construction conditions. Full-type keys in caches must be portable, including
the identity of variables, and must never serialize a TypeStore index as that identity.

*Amended 2026-10-22 (issue #712): deep conditions scale with cast paths.*
The value-cells backstop is retired: above the old pairwise threshold the checker
computes the same deep condition through the cell-family index used for spine
conditions. It omits only pairs whose cell kinds prove separation unconditionally;
all potentially sharing pairs still use nested and sepCells, and every entry keeps
its own condition. A safety cross-check compares the indexed and pairwise answers
on small values, or on every value under ownership-full-cross-check. The conditions
limit still guards actual atom growth. This replaces the old width refusal with
the full check, not a larger allowance or a pessimistic approximation.

The implementation also makes the marker's type vocabulary portable. A variable
is named by its declaring module, BIR declaration and its ordinal in a traversal
of the declared type, instruction types and locals in source order (record labels
in text order), never by a TypeStore node index. A summary that uses this vocabulary
carries its full function type. At a call, its variable keys are substituted with
the call's full parameter and result types throughout paths, atoms, callback supplies
and carried classes; substituted result entries are sorted again. The summary block
is version 24, after version 23's projection-aware conditions, and carries these
function signatures and full cast keys. Malformed encoded type keys are refused on read.

An exact trailing cast boundary names the same physical object as its source.
`coversAt`, list and record separation, and the indexed spine condition use that
identity. Comparing incompatible typed views below that object remains approximate;
a matching first type boundary itself is exact. A cast boundary ends the old nominal
region, so two `Maybe` applications cannot fold merely because their heads match.
Only re-entry into the same full cast type folds. Folded projection retains symbolic
places and every concrete matching boundary; storing aliases at two levels keeps
the containing value's separation annotation. The existing path cut remains for its
separate removal; this change does not claim that it is gone.

`ownership/core/FullCast` pins different nominal arguments, tuple members, record
fields and function parameters; first-entry writes, trailing alias refusals, generic
specialization, repeated record casts, and containing-value sharing. `core/CastAcross`
pins imports and cached signatures. The former `OwnershipLimitValueCells` input is
now `ownership/WideDeepCondition`: the whole fresh input is accepted by the full
condition check, with an aliasing twin still refused. No ownership check is dropped
and no budget is raised.

The full keys are stored once in a canonical type table in each summary block;
cast steps and signatures name that table by index. Reading a key already interned
compares its complete bytes and reuses it. Validation is done when a full key first
enters the session, not once per path that refers to it. Closed keys are memoized by
module and solved store node only in memory; open keys retain the declaration's
portable variable scope. None of these memos changes type equality or a verdict.

Analysis slots are not physical fields. A cast preserves a root's `⟨decoded⟩`,
`⟨encoded⟩` and markup slots at the root, and a slot query ignores physical paths
under a cast marker. An unknown runtime suffix is `any` with argument 1; ordinary
unknown suffixes keep argument 0. Both overlap physical paths conservatively; the
runtime suffix cannot introduce a synthetic analysis slot. The argument is carried
in version 24's path encoding. Schema's conversion-slot analysis reads its engine-owned
`Pair` representation at its complete record type before projecting `there` and `back`.

*Amended 2026-10-22 (#712): the full type is an interned graph.* Type nodes
retain their complete head, labels and child identities. Equality compares that
complete structural key; a child identity is assigned only after equal structure
has been interned. A parent never embeds a fresh copy of its child's text. The
summary's type table orders children before parents, in canonical depth and key
order, and a parent references only earlier entries of that block. Reading checks
these references and rebuilds the same full structure in the receiving session.
These are block-local references, never TypeStore or session identities. Human
reports expand the graph only when printed. This changes representation and cost,
not any fold point or condition.

*Amended 2026-10-22 (#712, after the written-element-path rule):* format 24
follows format 22’s recursive classes and format 23’s projection-aware conditions. A variable’s
scope also includes the declaring platform package’s manifest name for a platform
layer; nominal identities use the same scope. Package bytes are escaped so that
they cannot collide with type-key delimiters.

Nominal keys delimit module and type names separately: a schema member named
`Bar.Type` in `Foo` cannot be the type `Type` in the nested module `Foo.Bar`.

The deep-condition and spine indexes also retain the exact failure that takes
precedence over an approximate one: after a conjunction is already false, candidates
that can prove exact sharing are still checked. Physical prefix buckets name those
ordinary-cell candidates, and taken/except wrappers keep the general relation.
Pairs at one abstract path are alternative provenances, not two placements. The
pairwise definitions remain the safety cross-checks. Record-pair deduplication uses
an indexed set of `(cell, cell, exact)` keys instead of a linear scan of prior pairs.

*Amended 2026-10-22 (the owner's validation instruction):* instruction budgets
are ignored for this work. Run the complete unit, black-box and formatting checks
with budgets disabled; do not change budget grants. This supersedes the budget-stop
condition above. A newly refused safe program still requires fixing the precision
or reporting a reduced case if the intended design itself cannot accept it.

*Amended 2026-10-22 (#712, cast and nominal regions):* a summary with cast
paths retains the expanded nominal facts. The nominal canonical abbreviation
inserts a level marker; composing that abbreviation with a cast prefix can
consume the existing path cut before the expanded fact does. Retaining those
facts avoids that loss. The canonical/expanded cross-check stays unchanged.

*As built 2026-10-22 (#712):* the exact-first rule accepts every existing
core list line (117 accepted, none pending or rejected). FullCast pins trailing
views with different types as an exact physical alias. A changed consumer of a
cached generic provider gives the same alias diagnostic as an uncached check.
The complete unit, black-box and formatting checks pass with the owner-directed
budget override. The full cross-check passes core, the ownership/core fixtures,
WideDeepCondition and SchemaAnswers; the wider run exposed the unrelated
#427 and #694 failures, reproduced on unchanged master `daa996be1`. Neither check is weakened.

*Amended 2026-10-22 (#712, nested nonrecursive constructors):* the historical
constructor-head fold for nonrecursive types is retired with the cast marker.
`Maybe (Maybe a)` has two distinct constructor places; neither is a recursive
level. Host round trips now fold only at a repeated full cast type. The existing
recursive nominal rules and core Dict’s tree rule remain separate.

*Amended 2026-10-22 (after the owner’s repository-wide budget retirement):*
final validation uses ordinary `zig build gates` on current master. The earlier
`-Dtest-budget=0` runs above record the pre-retirement validation; that override
is no longer needed or supported. Existing hang guards remain unchanged.

*Stopped 2026-10-22 (#760, the owner’s safe-program stop rule):* the checks
above describe the candidate, not a merged implementation. The unchanged
integration base `b8724f19e` accepts this reduced core-mode program; the candidate
refuses it because its summary does not settle in 32 rounds:

```text
import Js

pub build : Int, a → Js.Value
build n xs =
    if n == 0 then
        Js.from [ xs ]
    else
        build (n - 1) [ xs ]
```

`check --core --ownership-everywhere --platform=node Main.beni` exits 0 on the
baseline and 1 on the candidate. The function only allocates arrays. Its recursive
call instantiates `a` with `List a`, producing the distinct full cast types
`List a`, `List (List a)`, and so on. There is no repeated full type for this rule
to fold. The existing path cut cannot bound a growing alphabet of type ids, and
interning a type DAG cannot make infinitely many instantiated types finite.
Erased polymorphic recursion therefore needs an additional rule before this
candidate can merge. No head fold, approximate first cast, limit raise or weakened
check is substituted for that decision. PR #748 stays draft; #760 records the
accepted baseline, refused candidate and preserved reproducer.

*Amended 2026-10-22 (#760, the owner's composed-type fold):* the stop above
is superseded. The adopted composed-path fold in point 4 also applies inside
a cast marker's full type. At a group-internal growing call, match the complete
declared and actual parameter types to find the variables instantiated at a
structure. Substitution of those variables in a marker crosses the same growth
boundary as composition of a value path. The first crossing keeps the complete
substituted type and sets the entry's existing crossed-growing-call mark. A later
crossing replaces only the growing substituted term with the type wildcard `⋆`.
The fixed surrounding type remains complete. Outside a growing call, all type
substitutions remain exact. The mark follows the same projection, composition,
join, binding and group-settlement rules as the path fold.

A wildcard type denotes all instantiations of its term. It never proves an exact
cast cancellation or separation: a read whose type contains a wildcard retains
all possible holders approximately. Folding can therefore merge places and their
conditions, but cannot discard an alias or turn a failed construction condition
into exclusivity. As with the value-path fold, the containing value's occurrence
conditions remain in force when the merged entries are normalized. Exact trailing
casts continue to denote their source's physical object. Closed fixed types,
including `List Int` and `List String`, never acquire a wildcard through this rule.
The finite declared type context and the one exact crossing bound growing marker
types; the wildcard absorbs further substitutions. This supplies the missing bound
on the marker alphabet without a depth cap or a change to any existing check.

The implementation computes exact and folded type alternatives before composing
result and callback-supply entries, and chooses with the existing crossing mark.
It retains the exact source paths for the existing merged-occurrence check.
The same entry mark governs types in its provenance and condition paths too.
A carried body crosses when its enclosing call instantiates it, even if the body
will be invoked later: its first substitution records the mark, and subsequent
ones fold the growing terms and keep the resulting view approximate. Merged
entries conjoin their list, spine and record conditions; deferred instantiation
retains those conditions and all holder provenances.
Read, write and escape effects carry the same mark while their group is solved;
otherwise a read alone could keep growing an alphabet of cast types after the
result stabilized. Read-off and record-split memoization distinguish marks, and
normalization joins them. Settlement clears effect marks with result and supply
marks, so cache blocks never depend on these in-memory crossing bits.
Local functions and lambdas also carry their full function signature when their
markers are open. Their signatures use the checked body and pattern variables,
including the complete type of unused parameters, so call-site specialization
closes their markers as precisely as a top-level declaration's. A cached returned
local class is specialized by the freshly checked consumer too. Callback
invocation uses the checked full function type, following record, tuple, list
and constructor slots with their type arguments. Result, effect and ownership
queries use the same specialization. Lazy definition references and memoized
structural views retain complete types without mutating the checker store.
Record-object rows carry the mark through composition, read-off, cloning and
settlement too; otherwise record growth would leave the marker alphabet unbounded.
A wildcard key is interned and encoded as part of the same full-type DAG, and its
presence is memoized on DAG nodes. Both new and decoded wildcard casts are folded
steps, never cancellable exact steps. A holder retained as unknown contents after
a cast cannot be discarded by comparing its old static type with the view's type:
that comparison ceased to prove physical separation at the host boundary.
The summary block is version 26, following version 25's folded-Dict condition
invalidation; old blocks are rechecked rather than decoded as full-type keys.

*Amended 2026-10-22 (#748, unknown views at a write's root):* the two unknown
suffix flags denote the same set of locations. A root wildcard may be the written
root; a wildcard below a field, element or constructor remains below that prefix.
An incompatible-view flag disables the old static-type filter, but cannot erase
an otherwise precise prefix. Write-root selection therefore accepts either flag
only at the root wildcard, retaining the baseline rule for strict descendants.
All such descendants remain holders for the alias and construction checks.

*Amended 2026-10-22 (after conditional callback requirements landed):* the
summary block is version 27, following version 26's conditional writer sets. It
retains those sets together with full cast keys and signatures.

*Amended 2026-10-23 (#748, deferred capture composition):* a carried binding
is composed at the enclosing call with the same declared/actual parameter types
and crossed-growing-call mark as a direct result. Its native path suffix and
its cast types therefore take one exact crossing and fold at a later one, even
when the carried function has not yet been invoked. For each binding, preserve
all rows before composition and compare the merged rows before normalization:
the existing occurrence check conjoins the conditions of coexisting placements.
Alternative provenances at one original place remain alternatives. A carried
site's equality includes entry marks and approximation, so a metadata-only change
cannot stop the fixpoint before the fold has propagated. No capture or condition
is discarded, and the callable class's own requirements remain unchanged.

**F3. A type variable of a nested datatype is a fold point.** `type T a = Leaf a | Wrap (T (List a))` recurs at
another argument than its own, so `wrap n x = if n == 0 then Leaf x else Wrap (wrap (n - 1) [ x ])` returns a
value whose list is `n` levels of `List` deep: `res #Leaf.0[*][*]…`, cut at eight today, with no cast and no
closure. A recursive type is *irregular* when one of its own occurrences in its definition applies it to
anything but its parameters in order; below a constructor field of such a type whose declared type *mentions*
one of its type variables, the path is `⋆` from the first step at which the variable is reached. The field need
not be the variable itself: `type T a = Leaf (Maybe a) | Wrap (T (List a))` gives `#Leaf.0#Just.0[*][*]…`
through a `Maybe`, so the rule must fire on `Leaf (Maybe a)` too.
- *A group of types.* Irregularity may come through mutual recursion: `type T a = W (U (List a))` and `type U a
  = V (T a)` apply neither type to anything but its parameters in its own definition, yet `T a` reaches `T (List
  a)`. So the rule is read over a strongly connected group of the types definitions name, not one type: a group
  is irregular when an occurrence of any member, in any member's definition, applies it to anything but its
  parameters in order, and every member's fields that mention a type variable then fold to `⋆`. The groups are
  the ones the checker already solves once per cycle, in Tarjan's order (`solveNominal`,
  `src/own/Ownership.zig:3382`, behind `nominalFacts`, 3357; "Mutually recursive types are solved once per cycle"
  above).
- *Soundness.* `⋆` stands for every place at or below it and overlaps every path; it only merges.
- *Finite.* `wrap` is `res #Leaf.0 π2, #Leaf.0⋆ π2`.
- *Delta: none*, on the bench and in `tests/corpus/ownership/`: no golden changes. Only irregular types pay, and
  the corpus has none but the probe. So there is no evidence of soundness beyond the argument: when F3 is built,
  `Leaf (Maybe a)` and the mutual pair `T`/`U` each need a fixture beside `wrap`'s.
- *Amended 2026-10-19 (the owner's option 2): F3 is replaced by a fold at a polymorphic-recursive call.* The rule
  above is read off types, and types are not where the growth is: `g : Int, a → (Int → Int)`, `g n x = if n == 0
  then λk → k + List.length [ x ] else g (n - 1) [ x ]` has no nested datatype and grows `res ◇[*][*]…`, and
  `type U a = ULeaf (Int → Int) | UWrap (U (List a))` grows under a field that mentions no type variable. What
  every one of them has is a call, inside the recursive group being solved, that instantiates a type variable of
  the callee at a type that is not a variable: `a` at `List a`. That call is the fold point.
  - *The rule.* At a call of a member of the recursive group being solved — a top-level group (§16.6), or a block's
    local functions (§18.7), whose annotated members may recur at other types too — each argument's declared
    parameter type, the member's own (its rigid variables, as its body was checked), is walked beside the
    argument's type at the call along every entry's path. Where the declared type is a variable and the argument's
    type there is not, the entry's path from the step after that position on is `⋆`: the entry stands for every
    place below the variable's value. A step under `◇` into a function type, or into a `foreign type`'s
    arguments, where the declared type and the argument's differ at a variable, is a place below the variable too,
    since what is there is not written in the type; there the rest is `⋆` from that step. Every other path stays
    exact: what the declared type writes above the variable, and everything of an argument whose type is the
    declared one.
  - *Soundness.* `⋆` stands for every place at or below it and overlaps every path; the fold only merges places
    of one argument, as F1's and a recursive type's do, and it changes nothing a call outside the group sees, since
    those instantiate the settled summary.
  - *Finite.* A path a group member's summary names is a path of its declared types: through a call inside the
    group it can grow only below a variable the call instantiates at a structure, and there it is `⋆`. `g` is
    `res ◇ π2, ◇⋆ π2`; `wrap` is `res #Leaf.0 π2, #Leaf.0⋆ π2`; `U`'s `uwrap` is `res #ULeaf.0◇ π2,
    #ULeaf.0◇⋆ π2`.
  - *What it costs.* An argument whose type at a group-internal call instantiates a variable at a structure loses
    the paths below that variable, and only in the group's own fixpoint: a function that recurs at `List a` on a
    list of lists keeps its lists' elements at `⋆`.
  - Fixtures: `ownership/PolyRec` (`g`, `wrap`, `Leaf (Maybe a)`, the mutual pair `T`/`U`, `uwrap`) and
    `ownership/LocalPolyRec` (`g` as an annotated `let` function).
- *Amended 2026-10-19 (the owner's choice (a)): the fold is on the composed path, not on the argument.* The fold at
  the call above loses a verdict master gives, and a build error that never goes away is a precision loss. Measured:
  `wrap`, `mwrap`, `pwrap` and `uwrap` lose every result condition (`{lost}` for `{excl π2}`), and `pushArg xs =
  case wrap 1 xs of Wrap (Leaf ys) → case ys of [ zs ] → List.push zs 1` is refused `exclusive` where master accepts
  it `param`. Keeping the argument's first step exact does not help. The recursive call's argument is always `[ x ]`,
  `{ε fresh, [*] π2}`, and the growth is not in it but in instantiation (§16.4), which puts the callee's summary
  path in front of the argument's (`instRes`: `⟨T⟩⁺#Leaf.0[*]` and `[*]` make `⟨T⟩⁺#Leaf.0[*][*]`). A fold of
  the argument makes the base case's entry and the deeper levels' end in one suffix. A constructor step then puts
  them at one path, one cell at two places that may both hold it, which is honestly `lost`.
  - *The rule.* Arguments are not folded. At a call of a member of the group being solved, top-level (§16.6) or
    local (§18.7), each argument entry `(q, c)` has a *boundary* `b`: the number of steps of `q` above the first
    variable of the member's declared parameter type that the call instantiates at a structure (the walk of the
    rule above). The entry is *below* when `q` has more than `b` steps. Instantiating a summary entry `r` at path
    `P` whose provenance is parameter `i` at `p` composes `P` with the rest of `q` after `p`, whose boundary is
    `b − |p|` (at least 0):
    - when `r` and the argument entry are both unmarked, the composed entry is `P ++ rest`, exact as before,
      and it is *marked* when the entry is below;
    - when either is marked and the entry is below, the composed entry is `P ++ rest[0 .. b − |p|] ++ ⋆`,
      approximate (`approx_place`), and marked.
    The mark rides on every entry made from a marked entry: a projection, a placement (`shift`, `under`), a join
    of branches, a binding, a call. It reaches the summary as a mark on the result entry. A callee's marks ride
    only at a call inside the group being solved: an instantiation outside it clears the callee's marks, since
    only a group's own fixpoint composes its summary with itself. The caller's own marks, on what it passes,
    ride through any call, a function outside the group included (`ownership/PolyRecThrough`). So the first
    composition of an entry below a grown variable stays exact, and every later one is `⋆`.
  - *Why a mark, and not the result type.* Walking the member's declared result type along `P` cannot tell
    whether `P` already went below a grown variable. Under a marker the level is unknown: in `T a`, the places
    `⟨T⟩⁺#Leaf.0` are `T (List a)`'s, `T (List (List a))`'s, and so on. So `⟨T⟩⁺#Leaf.0[*]` is a typed place
    (level 1's `a`) and the composition of one too. The mark records what the type cannot. It is kept in memory
    while a group is solved and is not written to the summary block: a settled summary is instantiated only
    outside its group, where the mark is cleared, so the block's format does not change. A mark that a
    transformation dropped costs termination, not soundness: the entry grows one composition more per round. So
    each fixture checks that no summary path reaches the cut.
  - *Soundness.* An exact composition is today's instantiation. A `⋆` stands for every place at or below it and
    only merges. The places this keeps apart are the ones master kept apart: the base case's `π2` at
    `#Leaf.0[*]`, which a constructor step places at `⟨T⟩⁺#Leaf.0[*]`, and the deeper levels' at
    `⟨T⟩⁺#Leaf.0[*]⋆`. That pair is now a container and what it may hold, a prefix step by step, so a deep
    condition takes it for one place (`nested`), and a fold that put the two at one path (`foldedBeside`) does
    not arise. *Why `nested` may take it for one place.* Values are acyclic: a cell is never held both at a place
    and strictly below it in one value, so when one cell is at `X` and at `X⋆`, one run holds it at `X`, or the
    two describe different runs. `⋆` also stands for `X` itself. Either way it is one list at one place, never
    two places in one value. For two different cells at `X` and `X⋆`, `nested`'s rule is §18.2's container and
    contents, unchanged.
  - *Finite.* An entry's path takes at most one exact composition below a grown variable. The next adds `⋆`,
    after which `child` absorbs every step, and the steps above the variable (`rest[0 .. b − |p|]`) walk the
    finite type graph, where 1–3 of the bound argument fold them. `wrap` is `res #Leaf.0 π2, ⟨T⟩⁺#Leaf.0 fresh,
    ⟨T⟩⁺#Leaf.0[*] π2 fresh, ⟨T⟩⁺#Leaf.0[*]⋆ π2 fresh`; `g` is `res ◇ π2 fresh, ◇[*] π2 fresh, ◇[*]⋆ π2
    fresh`; `PolyRecThrough`'s `wrap2` is `wrap`'s.
  - *What it still costs.* Below a grown variable, a value's places past the first composition are one place:
    two lists that a program puts at the second and third level of `List (List (List a))` inside one nested
    value are separated only by their cells. The differential measurement against master with `k` counts every
    verdict and condition that differs, in each direction, before this is built beyond a spike.
  - *Amended 2026-10-19 (the reviews of #429): every route of the growth, and the pairs the fold merges.* As
    first built, the fold fired only at a direct call of a member with a variable as its declared parameter. The
    growth has other routes, and the path cut still bounded each of them:
    - a function outside the group that calls back into it: `apply (g (n - 1) _) [ x ]`;
    - a let-bound lambda: `k = λy → g (n - 1) y`, then `k [ x ]`. A let-bound lambda is generalised, so the call
      inside it grows nothing, and the call `k [ x ]` grows `k`'s own variable;
    - continuation-passing: `h (n - 1) [ x ] (λt → f (Wrap t))` grows what `h` hands its callback, its supply;
    - a destructured parameter: `wt n ( x, k )`.
    So the rule holds at every instantiation, not at the call alone.
    - *The mark is a pair:* "marked", and a *pending boundary*. At a call inside the group that grows a
      variable, a symbolic cell (a parameter, a capture, a callback's result) that reaches the variable without
      passing below it has places that are below it, which a later instantiation supplies. Its entry takes the
      boundary, how many more steps of that cell are above the variable. A summary entry that carries a pending
      boundary composes, wherever it is instantiated, as at the grown call. The pending boundary takes a step
      off along a projection.
    - *Where the boundary is read:*
      - the call's own types: the member's declared parameter types, a destructured parameter's from the
        declaration's own type, and the types of the arguments;
      - a closure's parameters' types, at a call of the closure while a recursive group is being solved, since
        a let-bound lambda may grow its own variable;
      - otherwise, the summary entry's pending boundary.
      The composition is the same for a result (`instRes`) and for a supply, both a callback's parameter
      (`instCbOnce`) and a lambda's (`fromLambda`). Supply entries carry the mark as result entries do.
    - *A callee's marks ride everywhere*, and a group clears its members' marks when it settles. Only a group's
      own fixpoint composes its summaries with themselves. A settled summary carries none, so nothing leaks into
      a caller outside the group, and a summary made in this run equals one read back from the summary block.
    - *Merged pairs.* A cut can put two places at one path: `( x, y )` and `( y, y )` grown through a tuple put
      two lists at `⋆`. As first built, the instantiation then lost what the deep condition said of the pair.
      The pairs the fold merges are judged as `shift` judges a fold's, by `foldedBeside`'s rule: one cell at
      both is one list at two places, two cells are `sep`. So no condition becomes weaker than what the
      unfolded composition would give. `ownership/PolyRecTuples` keeps `{sep π2 π3}`.
    - *Why `nested` may take one cell at `X` and at `X⋆` for one place* (asked of an abstract cell that stands
      for many lists, one per level). The pair is skipped only for the condition "the list at `X` is the list
      below `X`". For a run-time list that is impossible, since values are acyclic, whichever run-time lists
      the cell stands for. Two of them at `X` and below `X` are two lists, which no sharing condition concerns.
      Sharing inside the `⋆` region, one list at two places below `X`, is what the merged-pair rule above
      states when the fold makes it. `ownership/PolyRecLevels` writes a list the recursion made while the list
      that holds it is read, refused.
    - *Measured.* Every probe of the reviews is finite, and no summary path reaches the cut. Verdicts against
      master: every verdict of the corpus, the bench and core is the same. In the probes, three lines differ:
      - `cwrap`'s `cus` and `freshC` (`ownership/PolyRecShared`) put one list at both fields of `B`. The cut
        accepted writing one while the other is read, and the fold refuses it. That is a master defect this
        fixes.
      - `once` (`ownership/PolyRecTwice`) writes the one list `wm` placed. The cut merged its levels into
        `{shared}` and refused it; it is accepted `param`, and its callers that read the list after it are
        refused. Where the list is placed twice (`wm2`), the write is refused on both.
      - Rows the cut invented and that name no list are gone: a write of `π1[*]` of a `List Int`.
      Conditions: where master has `{shared}` from levels the cut merged, the fold has `{lost}` or the condition
      of the one placement (`{excl π2}`). Where it has `{sep π2 π3}`, the fold keeps it.

**(c) Removing `k`.** Issue #286's (c) is this step, with F1, F2 and F3 as its fold points. With F1, F3 and a
cast marker the owner accepts, `k` goes: every path buffer (`[k_limit + 1]Step`, about twenty) becomes a slice,
the depth column widens, and the summary block's path length is a `u32`. The `writeRead`/`deep` hole is then
rejected `disjoint`, as its depth-seven twin is. Whether core settles within the existing rounds cannot be
measured until F2 is decided: with F2 as measured it does not get that far.

**(a) Fold only types that reach themselves.** Measured on 2026-10-17 without a cast marker: `Schema.run` and
`descend` pass the `entries` limit (302 670 and 319 438) and four functions pass `value-cells`. It needs F2;
until then `Nest.pushInner` stays accepted through a call. Its soundness is §16.7's first amendment: a type that
does not reach itself has no levels, so two of its steps on a path are two places.

**(d) The levels of a recursive value are pairwise distinct.** Thesis §3.1's representatives' exclusivity, as a
condition atom of §18.2: `lvl c` holds when no list is reachable at two levels of the recursive value `c`, or at
one of its levels and above it.
- *Made* by a construction of a recursive constructor: `Node l xs r` has `lvl` when `l` and `r` have it, `xs`'s
  cells are separate from every level of `l` and `r` (`sep`), and `l` and `r` are separate; a literal leaf has it;
  a callee's fresh result has the `lvl` its summary publishes.
- *Kept, or lowered, by a write.* `lvl` is a condition of §18.2, so its rule holds: a cell's condition is one
  that "a write in place only ever lowers", and a construction's is the base's "lowered by each item stored".
  A `Dict.insert` that places a list already held at one level at a second level lowers `lvl` of its result:
  the new item is not `sep` from the level that holds it. No later write can raise `lvl` again, so a value
  that once had it and was then written keeps it only if the write's own `sep` holds.
- *Relied on* where a holder reaches the written list only through a folded level (`approx_place`) while the
  demand reached it at one exact level: the holder is another level, so with `lvl` it is not this list, and the
  demand does not count it. `FoldLevels.pushRoot` is accepted. At a parameter, the reliance is recorded as `xreq
  lvl πᵢ.q` (§18.4), which every caller discharges.
- *How it would close `paramHole`.* `covers` relates `param(t, #Node.0)` to `param(t, #Node.1)` (the fold
  point below a recursive step, the patch measured for #341), and the relation fails only `lvl`. `paramHole` is
  then rejected unless its caller shows the levels distinct: `ParamHole.shared` is refused at its call. Until
  (d) is built the hole stays open on `master`, and `tests/pending/ownership/ParamHole.beni` stays red. Its
  golden holds the sound verdict the relation alone gives, the push rejected `element`; (d) re-blesses it.
  `Tea.want`, which the relation alone refuses, is *predicted* to be accepted once `Dict.insert` and
  `Dict.update` publish `lvl` of their result, since their bodies build a dictionary level by level. That is not
  measured; it is the first thing to measure when (d) is built. If they cannot publish it, (d) is still sound but
  refuses `Tea.want`, and that is a finding before (d) lands.
- *Size.* A new atom kind threaded through the condition columns, the read-off (`xres`), instantiation and the
  summary block (which will be version 16; `src/own/summary_bytes.zig` is at 15); the two reliance sites; the
  `covers` relation; and a §26.7 row or a Lean model of it. About 600 lines and a dozen fixtures, larger than a
  fix; the owner's go-ahead is needed before it is built.

**(e) The one permanent refusal: level-dependent sharing.** `alt n a b = Node (alt (n - 1) b a) a Leaf` puts
`a` at every other level and `b` between: the levels are not pairwise distinct, so `lvl` fails, though the
program is safe whenever it writes one level and reads another that does not hold the same list. No finite set
of abstract levels separates every period of alternation, so a sound checker refuses it. With (d) built, it is
the one place the strict rule refuses safe code for good. Its error, a cause `level` of its own:

```
-- LIST MAY BE SHARED -------------------------------------------- Alt.beni:20:23

`List.push` changes `xs`, a list of one level of `t`, and the checker cannot tell
the levels of a recursive value apart: it keeps one place for all of them, and
`t` may hold `xs` at another level too.

To be safe, copy the list at the level that shares it:

    Node (alt (n - 1) b a) (List.copy a) Leaf

For a record field, the copy is `Record.copy` (§31.15), which lands with #315.
```

It is pinned by a `build/bad/direct` project and an ownership fixture, and `language.md` gains it as a language
limit in §6.8, *Lists*, beside where `Record.copy` is described once #327's text reaches it: the one place an
author must copy a list that is never shared at the same time, and why.

**Order.** F1 and F3 can land now, each with its fixtures (`Clo`'s `mk`; `Poly`'s `wrap`, `Leaf (Maybe a)` and
the mutual pair), and change no verdict. F2 waits for the owner's decision above, then (a) and (c), the removal
of `k`; (d) waits for its go-ahead, then (e).

*Amended 2026-10-18 (issue #379, CK-256; the owner's decision): the level marker `⟨T⟩` replaces (d).* (d) cannot
be built as written above. Folding sent `#Node.0#Node.1`, a list of the left subtree, to `#Node.1`, the root's own
list, so a parameter's symbolic cell for a deeper level's list *was* the cell of level 0's list:
`case t of Node l _ _ → case l of Node _ zs _ → ( List.push zs 1, l )` was accepted `param` while `l`, returned,
holds `zs`, and its summary is `ParamHole`'s `hole`'s, which writes the root's list. No condition on the levels can
tell the two apart once they are one cell (`tests/pending/ownership/DeeperLevel`). The fold now keeps a level it
reached apart from the level it started at, with a step of its own:

- **What `⟨T⟩` stands for.** `T` is a recursive type. A path `Q⟨T⟩r` names the places `r` of *every value of type
  `T` at or below the position `Q`*, within the region of `T` that holds `Q` (the region ends at a field that holds
  `T` only through a type parameter: #341's rule, *Folding never goes through a type parameter*). At or below:
  when the value at `Q` is a `T` it is one of them; when it is not (a `List Rose`, a `Maybe Tree`, a closure) only
  the `T`s inside it are. So `t#Node.0⟨Tree⟩#Node.1` is every list of `t`'s left subtree, its root's included, and
  `t#Node.1` is `t`'s own list and nothing else: a path with no marker names one place at each level it writes.
- **The fold.** A constructor step `s` of `T` added to a path that is already inside a region of `T` goes on from
  the region's first step, under the marker: the region's first step into `T` is the step `s₀` at the position `P`,
  and the result is `P s₀ ⟨T⟩ s`; when the region has its marker already (`… M⟨T⟩ …`), it is `M⟨T⟩ s`. So
  `#Node.0#Node.1` is `#Node.0⟨Tree⟩#Node.1`, `#Node.0#Node.0#Node.2` is `#Node.0⟨Tree⟩#Node.2`,
  `#Node.0⟨Tree⟩#Node.0#Node.1` is `#Node.0⟨Tree⟩#Node.1`, and `Rose`'s `#Rose.1[*]#Rose.0` is
  `#Rose.1⟨Rose⟩#Rose.0`: the steps between the region's first step and the folded one (`[*]`, `#Just.0`, a tuple's)
  are inside the marker. A `⟨T⟩` added inside a region folds onto it the same way (onto `P s₀ ⟨T⟩`, or onto the
  marker already there); added anywhere else it is a step of its own, which a summary's paths and `concat` make
  (`π1⟨Tree⟩#Node.1`: every list of the tree). The fold takes place before the cut, like F1's, and a region holds at
  most one marker, so the paths stay finite: the level a region starts at, its first step, then one marker.
  Different first steps are different regions, so the left and the right subtree are two places: `#Node.0⟨Tree⟩#Node.1`
  and `#Node.2⟨Tree⟩#Node.1` do not overlap.
- **Where a marker stands.** A marker right after a region's first step `s₀` stands at `P s₀`, whose value is a
  `T` when `s₀`'s field is a `T` itself (`levelOf`'s `here`: `Node Tree …`'s `#Node.0`) and is not when the `T`s
  are further down (`below`: `Rose`'s `List Rose`). Any other marker — one a summary's path begins with, one `concat`
  puts on a path that is in no region, one the canonical form below writes — stands at a position whose value is a
  `T`: such markers are only made there. A parameter's own root is in no region, so a path from it with no marker
  is exact (`π1#Node.1` is the root's own list), and `P s₀⟨T⟩` with nothing after it is its own path, held exactly
  by `P s₀` (a prefix): what is stored under the one is stored under the other, so the two are one storage (the
  Lean oracle's reading, #386).
- **Overlap** *(amended 2026-10-18: exact, no longer as `⋆`).* At the first index `k` where `p` has a marker
  `⟨T⟩r` standing at `Q` and `q` has not the same marker: the two overlap when `q` ends before `k` (a prefix);
  when `q[k]` is `⋆` or a marker of another type; when `q[k]` is a step the marker's expansion may begin with
  (*a region step*: when the value at `Q` is a `T`, a constructor step of `T` whose field can hold a `T`; when it
  is not, any step); and, when the value at `Q` is a `T`, when `r` overlaps `q` from `k` (the expansion that is
  empty: `Q` itself is one of the `T`s). Otherwise they do not. Two markers of one type at one index are compared
  on, both read as standing at a `T`, whatever their kinds: there the rule is coarser than exact, on purpose
  (the empty expansion is let through where `below` or `⁺` would refuse it). A marker that, while it expands, meets a
  marker of its type on the other path either goes on through all that one stands for, or ends inside it and lets
  that one take the rest (`expand`): `⟨Tree⟩#Node.0` overlaps `#Node.0⟨Tree⟩#Node.2`, a subtree two levels down. So `#Node.1` and
  `#Node.0⟨Tree⟩#Node.1` are two places, `#Node.0` and `#Node.0⟨Tree⟩#Node.1` are a holder
  and what it holds; `⟨Tree⟩#Node.1` overlaps `#Node.1` (the root's list is one of every tree's lists) and every
  path into a subtree, and for `type T = N (List Int) (List Int) T`, `⟨T⟩#N.0` does not overlap `#N.1`. Where the region's first
  step leads to a value with fields that cannot hold `T` beside ones that can (`C (List Int × T)`'s `#C.0`), the
  marker's position is not a `T`, and any step counts as a region step: conservative, since the path does not say
  which component the marker went through.
- **Holding a symbolic cell** (`covers`, `levelHolds`). `param(x, O)` holds `param(x, I)` exactly when `O` is a
  prefix of `I`, as before: `param(t, #Node.0)` holds `param(t, #Node.0⟨Tree⟩#Node.1)`. It holds it
  *approximately* (a place that stands for several, `approx_place`, cause `element`), with `⋆` between, when at the
  first index `k` where they differ:
  - `I` has a marker standing at `Q`, and `O[k]` is a region step of it (`O`'s value is below `Q`, inside the
    region, and may hold some of the `T`s), or the value at `Q` is a `T` and `O` holds `I`'s rest after the marker
    from `k` (`Q` itself is one of them);
  - `O` has a marker standing at `Q`, and `I[k]` is a region step of it, or the value at `Q` is a `T` and `O`'s
    rest after the marker holds `I` from `k`;
  - both passed the same marker just before `k`, and `O[k]` is a constructor step of `T` whose field can hold a
    `T` (`#Node.0⟨Tree⟩#Node.0`, the left subtrees below, holds some of `#Node.0⟨Tree⟩#Node.1`).
  Otherwise it does not hold it. An exact prefix stays exact through a marker both share: `P⟨T⟩r₁` holds
  `P⟨T⟩r₁r₂` with no approximation of its own, on purpose; that each stands for several places is said where it
  matters, by `representative()` and the entries' own `approx`, not by the holding.
- **The canonical form.** A fact written at `P r`, where `P` is a position whose value is a `T` and is in no region
  of `T`, and at `P s⟨T⟩r` for *every* region step `s` of `T` at `P`, is one fact about every `T` at or below `P`,
  `P` included, and is written once as `P⟨T⟩r`. A fact written at every region but not at the root (or a different
  one there) is one fact about every `T` strictly below `P`, and is written once as `P⟨T⟩⁺r`: a marker that stands
  at a `T` and whose expansion is never empty (its kind `under`; *Overlap* and *Holding* read it as a marker at a
  `T` with the empty expansion left out). The region steps counted are those of `T` as it is written: a field
  holds a `T` through constructors, records, tuples and `List`, not through a function's captures, a `foreign
  type`'s arguments or a schema's slots, which a path reaches only by a cast; a canonical place still stands for
  those too, which is sound, and the cross-check below shows no verdict changes for it. By the overlap and
  holding rules, a canonical place and the set it replaces stand for the same places otherwise. A summary's
  read-off writes it (§16.3) for the facts it states per path — a use's bits, a result path's entries, a result
  entry's provenance among those at one result path, a supply's entries — and drops a fact at one of a canonical
  place's places when the canonical fact already states it (a use's bits are within its bits; a result's or a
  supply's entry is one of its entries), which is what a fixpoint's join of an expanded round with a canonical one
  leaves. It is applied innermost region first and again until nothing changes. Measured: core `Schema`'s summaries
  wrote 2 393 of their 4 238 use entries under a marker, 443 facts each repeated over the 4 regions of `Made` or
  the 7 of `Node`; with the canonical form its summaries are 128 KB of text (293 KB expanded, 70 KB on `master`,
  before the marker). Under `-Downership-full-cross-check`, every report is computed again with the expanded form,
  and each site's verdict — the worst of its lines, accepted, pending or rejected, since one canonical write may be
  several expanded lines — must be the same, or the build panics. A rejection's cause may differ: the expanded
  form sees two places where the canonical one sees one written under a marker (`disjoint` against `exclusive`).
  The summaries are compared too, declaration by declaration, by text since the two runs number their paths
  apart: each canonical entry is written out as its member places (and as itself, a marker a projection made
  being one the expanded run writes as it is), and every use bit, result entry and supply the expanded run states
  must be among them, and a supply owned in the canonical run must be owned in the expanded one.
  *Amended 2026-10-22 (#763): fresh numbers are compared by what they name.* Each run numbers its fresh cells
  in an order of its own, and the canonical run, coarser, may state a cell the expanded one does not (#720's
  guards), which moves every later number; comparing the numbers as text panicked on core `Schema`. An
  allocation's number says which paths may hold one new cell, so the cell the expanded run numbers `n` must be
  one cell of the canonical run, under one number, at every place the expanded run puts it, and a supply of it
  must be a supply of that number. An annotation's number says only which entries instantiate as one cell,
  which shares nothing and holds every condition its entries state, so each place the expanded run annotates
  must be one the canonical run annotates, under any number. The same build
  also checks the matcher against concrete places: for each recursive type with no parameter in a reported module,
  every concrete path to seven steps is folded and every pair compared with the concrete relation (a prefix either
  way overlaps; a prefix holds), and so is every place of `⟨T⟩r` and `⟨T⟩⁺r`, written out (`checkMatch`;
  `ownership/MarkerTypes` holds `Tree`, `Rose`, `N (List Int) (List Int) N` and `C (List Int × C)`). It found that a
  marker meeting a marker of its type at another index must be able to go on through all the second stands for
  (`ownership/MarkerAcross`, a write accepted while a deeper subtree that holds its lists was returned).
- **What a call instantiates.** A callee's cell `πᵢ.p` is the caller's argument projected along `p` (§16.4): the
  entries whose paths overlap `p` under the rule above, each at the rest of its path or kept whole, approximately,
  under a marker (*Projection*, below). The Lean oracle (#386) matches every entry whose path conflicts with `p`,
  which is coarser and sound; the bridge (#386) compares the two.
- **Projection.** Along a step `s`, an entry whose first step is `s` is kept at the rest of its path, as before. An
  entry whose first step is a marker `⟨T⟩r` stands for values at or below the root: it is kept whole,
  approximately, when the field `s` reaches may hold a `T` (a constructor step of `T` whose field can hold `T`, or
  any step that is not a constructor step of `T`); and when `r` begins with `s`, it is also kept at the rest of `r`,
  approximately (the value at the root is one of the `T`s). Every other entry is dropped. In particular an entry
  whose first step is *another* constructor step of `T` is dropped: it is another field of the same level, and #341's
  rule, which kept those entries because the levels shared their paths, is withdrawn with the reason it had. A
  symbolic cell is projected to the cell at the folded path (`param(t, #Node.0)` along `#Node.1` is
  `param(t, #Node.0⟨Tree⟩#Node.1)`).
- **With `[*]` and `◇`.** `⟨T⟩` is the region's marker and nothing else: a `[*]` or `◇` step after it is a step of
  the places it names (`#Rose.1⟨Rose⟩#Rose.1[*]`, the kids lists' elements, deeper than the root), and one before it
  is part of where the region is (`π1[*]#Node.1` stays exact, an element's own list). A function field is a level
  below (`levelOf`'s `below`), so a closure that captures a `T` starts no region of its own: F1 folds its `◇`, and a
  `T` reached under it folds as any other. The two folds are independent: a path holds at most one `◇` and one marker
  per region of a recursive type.
- **Representatives.** A path names a place that stands for several when it holds `[*]` or a marker; every other
  path is one place, a level's own field included (`#Node.1` is exact now, where #341 took every step into a recursive
  type for a representative).
- **Exclusivity, and what it does not say.** A value's deep condition (§18.2) has `sep` between the cells at every
  two of its paths that neither holds nor overlaps the other, so `excl π1` of a tree now includes
  `sep π1#Node.1 π1#Node.0⟨Tree⟩#Node.1`: level 0 shares no list with the left subtree. That is what (d)'s `lvl`
  was to state between levels, and it is checked where `excl` is, by the call-site demand that already compares an
  argument's other paths (`disjoint`): `ParamHole.shared`'s tree holds `xs` at `#Node.1` and at
  `#Node.0⟨Tree⟩#Node.1`, so `hole`'s write of `π1#Node.1` is refused there, and `hole` itself stays accepted. **What
  no condition states is sharing among the levels inside one region.** A marked cell stands for every list of its
  region, as `π1[*]` stands for every element; a write of one of them while another is held is a write of the one
  cell, refused approximately (`element`), however distinct the two are: in
  `case t of Node (Node _ a (Node _ b _)) _ _ → ( List.push a 1, b )`, `a` and `b` are both
  `t#Node.0⟨Tree⟩#Node.1`. Telling those apart would need a place per level, and the levels of a recursive value are
  unbounded, so a finite summary cannot name them; `master` refused the same programs, since all of a tree's lists
  were one cell there. This is (e)'s limit, wider than (e) says: (e) is the case where the sharing is real. It
  is a stated limit, not a design to come (the owner, 2026-10-18).
- **A callee's places that are one cell at its caller** *(amended 2026-10-19, the review of #393)*. A callee takes
  two of its parameter's places that neither holds nor overlaps the other for two places, and at its caller they
  may be one cell: `two t` pushes `t#Node.1` and `t#Node.0⟨Tree⟩#Node.1`, and a caller that hands it a subtree
  `l = param(t, #Node.0)` reads both as `param(t, #Node.0⟨Tree⟩#Node.1)`, every list of that subtree. So a
  call-site demand on the written place `q` also compares, with the cell it writes, the argument's cells at each of
  the callee's other places of that argument (`call_uses`). A cell that is not the written one is another holder,
  approximately, like the argument's other paths. The written cell itself, when it is a symbolic cell that stands
  for several places (under `[*]` or a marker), is two of them only if the argument is exclusive at the place
  before the step that makes it stand for several, and the demand relies on that (§18.4): `viaLeft` records
  `xreq excl π1#Node.0`, and a caller whose subtree holds one list at two levels is refused there. Any other cell
  there is one list at two places. core `Dict`'s tree, under its exemption, is not compared so.
  The argument's *other paths* (§16.4 item 3, `disjoint`) are operands only where the callee uses them: a path
  under none of its uses, or under one that only reads a place above it (a read of a node is not a read of what
  is below it), it never reaches, so a list there is not another operand. Before the marker every level's list was
  at one path, and a tree that shares its root's list with an unused subtree was accepted by not seeing it; it
  stays accepted, by seeing that the callee does not look (the bridge's `run` family).
- **A write under a marker.** A callee that writes a place under a marker writes the lists of every place the
  marker stands for, one by one, and they are distinct lists only if the argument is exclusive where the marker's
  region begins: the call-site demand relies on the argument's deep condition at the path before the marker. A
  recursive update of every level of a tree (`incAll`) is refused on a tree that holds one list at two levels.
- **What a fold hides.** A value placed one step down (a constructor's argument) may have two of its places fold
  onto one marked path, and no later deep condition can see them apart. So the fold lowers their cells'
  conditions as the value's deep condition would have said of the pair: `sep` of two cells, and for one cell at
  both, `excl` of the place before it stands for several when it is a symbolic cell that does, else the pair's
  `sepCells` (`shared` for one list at two places, exactly). A pair the deep condition does not compare
  (§16.7, *Pairs a deep condition compares*) is left alone. `ownership/LevelPlacesCall`, `LevelPlacesKinds` and
  `LevelRecursiveUpdates` pin the three: each refused call was accepted before.
- **Pairs a deep condition compares.** A deep condition (§18.2) and a spine condition (§20.4) do not separate
  two entries of a value when one path is a prefix of the other, since that is a container and what it holds.
  That holds for a prefix step by step. A prefix only through `⋆` or a marker is a place that stands for several,
  so the two entries are compared unless their cells are two that hold one another (`covers`). One cell at
  both is two places that share it, unless one of the two entries is approximate: a projection keeps a marked
  entry whole and also at the rest of its path, and those two are one entry, not two places.
  (`ownership/EnvPrefix` pins the shape that made F1's `◇q` unsound: one list in a closure's environment and
  in the closure that environment holds.)

*Scope (the owner, 2026-10-18).* Two folds keep their form from before this amendment:

- **Folds of a type that does not reach itself are unchanged from `master`.** A path into such a type twice was
  cast through `Js.Value` and read again, and it folds onto where it first entered the type, with no marker;
  F2, the cast marker with the full type and a check made to scale (the owner's option iii), is where those
  folds change. Markers there were measured: `Schema`'s `ctorArgs`, `fieldsFrom` and `printWith` went past
  `value-cells`, F2's finding again, so this amendment does not touch them.
- **core `Dict`'s tree keeps the merged fold, until #294** (the dictionary on a `Map`, which removes the tree),
  and with it #341's projection rule (a step into the tree keeps the entries of its other fields, at their own
  path or at `⋆`), and its paths are representatives (`representative()` is true for every path through the
  tree, so a demand or a holder there stays approximate). Why #379's hole cannot occur there: the hole is a
  write of a list at one exact level, which the fold merged with another, while a holder of the other level is
  read afterwards. In `core/Dict` no function writes a key or a value (they are `k` and `v`, which no writer
  applies to); a value is written only by a callback the module hands it to, as a call-site demand on the
  dictionary at `#Dict.0#Node.2`, the one place of every value, which a caller outside the module cannot split,
  since it cannot name a level. Inside, what keeps a write from being seen at another position is §20.9's
  one-position obligation — no function of `core/Dict` places one value at two positions of a tree — read for
  callbacks: **no function of `core/Dict` hands a callback, or writes, a value that a position it reads afterwards
  holds.** A traversal meets it because a position read later is another position. The audit, function by
  function:
  - `mapTree` binds one node's `value`, reads `left` before `func` and `right` after, neither of which holds it;
    `foldlTree`/`foldrTree` hand `value` to `func` and then read the other subtree, which does not hold it.
  - `filter` and `partition` go through `foldlTree`: `isGood key value`, then `insert dict key value`. The value
    is then in the input tree and in the result, which is a result's provenance like any other (`res` names `π1`'s
    values), checked at the caller, and no position the traversal reads later holds it.
  - `union` is `foldl t1` inserting into `t2`, `diff` is `foldl t2` removing from `t1` (no value reaches a
    callback), and `merge` makes `toList leftDict`, then `foldl rightDict` and `List.foldl` hand `lValue`, `rValue`
    and the leftovers to the caller's callbacks, each once, from a list position or a tree position no later read
    holds: the callbacks' writes are supplies of `π1`'s and `π2`'s values, call-site demands at the caller.
  - `focus` is the asserted destructive read of §20.8.

  The exemption protects precision as much as safety: under the marker, the tree's levels came apart and
  `browser-direct`'s `Tea.want` was refused, approximately, because rebalancing moves a value from one region to
  another, so `Dict.insert`'s result held one input cell at two result paths. #294 is its only exit, and its work
  list includes: delete `dictTree`, the `unmarked` branch of `Walker.proj` and the other-places exception in
  `callSiteDemandDeep`, and remove the obligation's clause above. `ownership/DictValueWritten` pins the
  exemption: a dictionary's value written while the dictionary is still read is refused.

*Amended 2026-10-19 (issue #286): the bound argument — why four sources of growth, and no fifth.* Removing the
path cut `k` (c) is sound only if every path the checker builds is bounded without it. The paragraph above
names four sources of unbounded paths. This one argues there is no fifth, and gives each source its fold. It is a
design text recording the owner's composed-path decision and the remaining proof obligations. `k` stays:
casts through records and tuples still have no fold (F2). #447's prefix correction is recorded below.

*Where a path grows.* A path is built only by `child`, one step at a time, and a step is added in three ways:
a projection or a construction mirrors one step of the value (a field, a tuple slot, a constructor field, a
list's elements, a closure's environment, a markup or schema slot); `shift` places a value one step down; and
instantiation at a call (§16.4) puts a callee's summary path in front of an argument's path. A `⋆` absorbs every
step after it (`childRaw`), so a path with `⋆` grows no further. The markup and schema slots are added only at a
value's root (`⟨render⟩` over `ε` or `⋆`, events at `⋆`, `⟨decoded⟩`/`⟨encoded⟩` at the root), so each adds at
most one step and none chains.

*A path walks a type.* Every other step is a step into the type of the value at the place it leaves: a field of a
record type, a slot of a tuple, a field of a constructor, the element of a `List`. So a path is a walk in the type
graph, from the root's type, with two exceptions where the step is not read off the type: a closure's `◇`, whose
captures a function type does not write, and a cast through `Js.Value`, after which the path is read at a type
it was not made at. A walk is finite unless it goes round a cycle of the graph, or the graph it walks is
infinite. That gives the four sources, and only four:

1. **A cycle: a recursive type.** Folded by the level marker `⟨T⟩` (the amendments above): a constructor step
   into a type a path is already inside goes under that region's marker, and a marker asked for where there is
   one folds onto it. A path holds at most one marker per region, and there are finitely many types, so the walk
   between markers is acyclic and bounded by the type graph. A region ends at a constructor field that
   reaches the type only through a type parameter (`regionOf`, for example a `Dict` value). Passing that
   boundary walks the finite type argument term; nested `Dict` arguments are not a recursive region. An
   unbounded family of such terms can arise only through the polymorphic instantiation in 4. Issue #379
   (`#Node.0#Node.1` folded onto `#Node.1`, so a deeper level's list was the root's) is closed by the marker. `ownership/DeeperLevel` pins it.
   Two exemptions keep the merged fold, each bounded by the same count: core `Dict`'s tree until #294, and a
   type that does not reach itself until F2.
2. **A step the type does not write: a closure's environment.** F1, built: a function type is a recursive type of
   its own whose region step is `◇`, so `◇p◇q` is `◇⟨◇⟩◇q` and a path holds one `◇` and at most one closure
   marker after it (the F1 amendments, `ownership/Clo`, `ClosureLevels`, `SiblingEnvs`, `DirectCapture`).
3. **A walk read at another type: a cast.** F2, the cast marker `⟨as T⟩`. *Corrected 2026-10-19:* this source
   has no fold for record or tuple casts yet. Until F2 lands, a constructor of a type that a path enters
   twice, with no recursion, was cast and read again, and it folds onto where it first entered, with no marker. That bounds a cast that
   re-reads a *named type* by the number of types. A cast that re-reads a *record* or a *tuple* is not bounded.
   A field or tuple step carries no type in the path, so the fold cannot see the second entry. Core's
   `Schema` grows that way:
   - `collect`: `π1.parent.parent…`;
   - `unpack`: `π1.0.0.0…`;
   - `productOf`: `res .0.0.0…`.
   On `master` the cut holds them at eight steps. Without it they never settle, and the `rounds` limit makes
   them pessimistic (measured 2026-10-19 with `k` removed). So casts are F2's, and `k` cannot go before F2.
   The owner decided F2 on 2026-10-18: option (iii), the check made to scale (not `value-cells` raised), with a
   marker that records the full type, not the head. Its measurement goes to the owner before it is built.
4. **An infinite graph: polymorphic recursion.** Instantiation composes paths. Outside a recursive group this is
   bounded by induction over the recursive groups of the call graph and the acyclic module graph
   (§16.9): a callee's summary, including an imported one, is settled before a caller instantiates it. Each
   concatenation walks a finite composed type. The bound depends on the program, not a universal constant:
   a chain that adds a `List` at every call adds a step per link. A recursive type in the composition folds
   as in 1. Inside a group, the fixpoint instantiates the group's own summaries repeatedly. Without a substitution that places a group type variable inside a structure containing a
   group variable (monomorphic recursion, the common case), variable renamings, including cycles of
   variables, walk the same finite graph, and 1–3 bound it. A substitution such as `a` at `List a`, including
   one reached through a cycle of group variables, can instead grow the graph:
   the types along the composed path are drawn from an infinite family (`List a`, `List (List a)`, …), and no
   fold of 1–3 sees a repeated region. `wrap n x = if n == 0 then Leaf x else Wrap (wrap (n - 1) [ x ])` returns
   `#Leaf.0[*][*]…`, and `g` (a closure, no nested datatype) returns `◇[*][*]…`. *Decided
   (2026-10-19):* the owner chose the fold on the composed path (the amendment above, *the owner's choice
   (a)*). #429 implements it on every route of growth. The soundness correction to `nested` in #447 is
   recorded in the dated amendment below; removal of `k` is not claimed here.
   - *The rejected fold at the call* (the earlier F3 amendment, *a fold at a polymorphic-recursive call*):
     an argument's places below a variable the call instantiates at a structure go to `⋆` (or keep their
     first step and go to `⋆` below it). Finite and sound (`⋆` only merges), but it loses a verdict master
     gives: `wrap`, `mwrap`, `pwrap` and `uwrap` lose every result condition (`{lost}` for `{excl π2}`).
     `pushArg xs = case wrap 1 xs of Wrap (Leaf ys) → case ys of [ zs ] → List.push zs 1` is refused
     `exclusive` (approximate), where master accepts it `param`. The base case's entry (`#Leaf.0⋆`) and
     the deeper levels' (`⟨T⟩⁺#Leaf.0⋆`) end in one suffix, and a constructor step folds them onto one
     path, one cell at two places that may both hold it. Keeping the first step exact recovers nothing:
     the argument is always `[x]`, and growth is in composition, not in the argument.
   - *The adopted fold on the composed path:* argument paths stay exact. Summary entries record whether
     they have already crossed a growing call; the first composition below its type-variable boundary stays
     exact and records the crossing, and a later one folds the growing suffix to `⋆` (the rule and all
     routes in the amendment above). This supplies the information the earlier sketch lacked; it is no
     longer an unmeasured alternative awaiting the owner. A concrete place cannot hold a cell and hold
     that same cell strictly below itself, by acyclicity. A prefix containing a representative step names
     several places, so that argument alone does not justify treating its entries as one place: #447
     supplies that comparison, with #456's construction conditions (the dated amendments below).

*Why no fifth.* Every step is one of: a typed step (bounded by 1 on a finite type graph); a root-only slot; `◇`
(2); a step after a cast (3, unbounded for records and tuples until F2); or a `⋆`, which ends growth. The type
graph is finite except through instantiation inside a recursive group at a structure (4), since outside a group instantiation is settled bottom-up, and the
types a module names are finite. Symbolic cells (`param(x, q)`, `env`, `cbres`) carry paths built by the same
`child`, so the same argument bounds them. Hand-authored primitive summaries (§16.8) contain finite
authored paths; instantiating their rows uses the same composition and folds, and adds no new source of growth.
A spine condition (§20.4) names cells, not new paths. A fifth source would need a step that is neither typed, root-only, environment, nor cast, or an infinite type family that does
not come from instantiation inside a group. The checker has no such step (`StepKind` lists them all), and the
type checker gives no other way to make one.

*What else `k` holds up.* Besides the cut in `childRaw`, `k_limit` sizes the path buffers (`[k_limit + 1]Step`,
about twenty) and guards `markupEvents`'s walk of a type term. That walk is bounded by the term's size, a finite
type, so the guard goes with `k`. The order of (c): F1 has landed; 4 has #429, #447's prefix correction
and #456's construction conditions; 3 waits for F2. The owner withdrew the measurement prerequisite below. Then `k` goes: the cut, the buffers (as stack room
that spills, not a limit), and the summary block's one-byte path length and `n_steps > k_limit` check. A larger
program can have a larger finite type and path; neither storage nor serialization may impose the old
constant-length bound.

*Amended 2026-10-22 (issue #456, the owner's implementation decision): construction conditions belong to the containing value.*
**Implementation and accepted precision debt (the owner, 2026-10-22):** the two core ownership
tests have budgets of 5 300M. The one known false refusal is `DictFocus.grow`, whose folded
dictionary construction annotations have lost deep conditions; `tests/pending/ownership/DictFocusGrow`
still expects acceptance. The additional rejected callback inside `DictFocus.readLater` has the
same cause; that complete program was already rejected for reading the dictionary after updating it.
Both are accepted debt until #294 replaces the folded tree, tracked by #663. This is a temporary
precision defect, not real sharing or a language restriction. Any other whole program moving from
accepted to rejected stops landing.
An approximate entry is not evidence that two occurrences are one. Projecting `ee` through `wrap`, then
storing that alias beside `ee` at another recursive level, makes two simultaneous occurrences even when
one or both entries are approximate. The approximate-copy exception of `nested` cannot supply the missing
proof. Neither can a stricter path-overlap test: the missing fact is that two operands coexist in one
construction. Permanently lowering either operand's cell condition is wrong too: selecting one operand
and discarding the other must recover its original exclusivity (`ConstructorDiscardedAlias`).

The level marker of issue #379 remains the single spatial abstraction for recursive values. A use of
that marker carries the conditions of the constructions it represents. The interned marker `(type, kind)`
cannot itself carry a condition: it is shared by unrelated values, whereas a condition belongs to one
containing value. Transport the condition at that construction's result-relative path through the same
placement, fold and projection as its entries. No second matcher, unfolding identity, or depth/count cap
is introduced.

- A tuple, record or constructor records, at its root, the conjunction of separation of its stored
  operands, before folding their positions. List and record separation use their independent domains.
  Lists already record these obligations on their real container. A trivial conjunction needs no entry.
- A condition-only entry represents this annotation, not an allocation. It has an explicit discriminator
  in local cells and summary provenance. It cannot be a mutation target, a holder, an escape, a fresh
  allocation, a returned spine, or evidence that an allocation is owned. Deep list and record queries
  read its respective conditions; allocation separation ignores it.
- Placement prefixes its containing path once. A fold carries it under the existing level marker.
  Projection selecting one operand discards an annotation at the discarded construction root. An
  annotation inside the selected value survives, rebased by the ordinary projection; a marked path
  retains the possible containing constructions exactly as the marker's existing expansion specifies.
  Multiple approximate views do not become multiple allocations.
- A branch union carries only annotations made within each arm. It creates no separation between
  operands returned by mutually exclusive arms (`chooseNode`).
- Direct constructors, constructor-function summaries and ordinary helpers publish the same condition.
  Calls instantiate it on a result-owned annotation, never on either actual operand's allocation.
  Captures, callback supplies, top-level values and imported/cache summaries retain both the discriminator
  and the condition. The summary block is version 19; provenance flag bit 2 denotes an annotation.
- A call-site demand under a marker queries the deep condition at the existing marker anchor before
  projecting the target. That query sees the surviving construction conditions. A later query after
  a subtree was discarded does not inherit a condition on the discarded container. Ordinary live-holder
  and escape checks still reject aliases outside the selected value.

The invariant is conditional deep exclusivity: for every concrete value represented by an abstract value,
its allocation/container conditions and surviving construction annotations together imply that mutable
allocations in different stored operands are separate. The operands of one annotation belong to the
same concrete construction when its marker expands; they are not independently chosen recursive levels.
Projection preserves that implication for retained subvalues and may discard a condition only with its
containing construction. Substitution preserves annotation scope and allocation identity; branch union
preserves the implication separately for each alternative. This is the obligation for the ownership
oracle as well as for the compiler, not a claim that the current Lean model proves it.

The owner withdrew the pre-implementation cost-report conditions on 2026-10-22. The two core ownership tests retain all their assertions. Both projected-alias twins and constructor/helper routes must be refused;
`ConstructorDiscardedAlias`, `EntryInvariantCommand` and the retained `ValuePath` program must stay
accepted. The owner accepts the pending `DictFocusGrow` false refusal and the extra callback
refusal inside the already-rejected `DictFocus.readLater` (#663, until #294); any other whole program
changing from accepted to rejected stops landing. The incorrect `restMayBeEmpty` tightening is excluded.

*Amended 2026-10-22 (review of #447, after #456): representative prefixes.*
`nested` exempts a step-by-step prefix pair from separation in three cases:
the entries have different cells (a container and its contents); the same cell
occurs at a prefix naming one place (acyclicity rules out holding itself); or
at least one entry is approximate. For the second case the shorter path must
contain neither a representative (`[*]`, a level marker or the Dict tree) nor
`⋆`. Two exact entries of one cell under such a prefix may be distinct stored
occurrences and are compared. This includes `⋆`, which can also name the root.
For overlapping paths without a step-by-step prefix, the existing cell-holding
and approximate-view rules are unchanged.

The approximate case is an exemption from this pair comparison, **not a proof
that approximate entries denote only one occurrence**. #456 disproved that
assumption. Its surviving, value-scoped construction conditions separately
require simultaneous stored operands to be separate, including exact/approximate
and approximate/approximate aliases. `ApproximateAliasLevels` pins the projected,
constructor-alias and helper routes; `ConstructorDiscardedAlias` pins recovery
when an unused alias-bearing subtree is discarded. The containing conditions,
ordinary holder checks and representative-prefix comparison are used together.
No `restMayBeEmpty` tightening is part of this rule.

*As built 2026-10-22 (#684): what the construction conditions cost.* A construction's condition names
every pair of its operands, so a record built from 64 fields of one parameter carries 2 016 `rsep`
atoms, and each call instantiates them. Instantiation projected the argument along both of an atom's
paths afresh, and a projection of a value narrower than `wide_index` scans it: cubic in the record's
width. Three changes remove the repeated work and change no fact. (1) One condition's instantiation
projects each parameter provenance once (`ProvMemo`): the projection reads only what the call is handed
and interns its cells, so the first atom that names it makes every cell in the order it always did. The
cells `sepValues` and `rsepValues` read are kept with it for a value that holds no closure; a closure's
expansion reads the captured locals an atom that walks a callback may bind, so it is read again. Any
other provenance kind may act and is instantiated at every atom. (2) `containingCondition` reads each
operand's cells once, at the pair that first needs them. (3) `rbase` is kept per cell, and a build
renders no summary line, which only the ownership dump prints (`format_summaries`; nor does a
totals-only dump). Ownership-phase instructions (callgrind, ReleaseFast) on the research dashboard at
N = 16, 64 and 256: 23.2M, 85.9M and 571M before #665; 31.2M, 305M and 1 914M after it; 25.2M, 121M
and 1 140M now. `ownership/WideFieldConditions` was 5 444M on the budget's reference and is 2 764M.
What stays is quadratic and is the representation's: the summary states each pair as an atom, so its
size, its text and each call's instantiation grow with the square of a construction's width. Making it
linear needs an atom for "these operands pairwise apart", a change to the summary vocabulary, its block
format and every golden that prints a construction condition; it is not built.

*Amended 2026-10-22 (issue #693, the manager's decision under the owner's delegation): pairwise apart is one
atom.* The construction's condition keeps its meaning and changes its representation. No verdict changes.
The Lean model of atoms gets the same atom under #704.

**The atom.** `apart G₁ … Gₙ` (n ≥ 2) is one atom of a condition. Each group Gᵢ is a nonempty set of cells in
the walk, or of provenances in a summary. It states that no member of one group shares a cell with a member
of another group. Its meaning is its **expansion**, the conjunction of `sep a b` for every a in Gᵢ and b in Gⱼ
with i < j. This includes `sep a a` when a member is in two groups, and for a callback's result that means
*fresh across calls*, as in §18.2. In a record condition (§31.4 item 6), the expansion is `rsep`. A spine
condition's form is `apart-spine`, whose expansion is `sep-spine` (§20.4). `spineOfSep` maps `apart` to
`apart-spine` as it maps `sep` to `sep-spine`.

**Where it is made.** It is made in two places, and in both the pairwise text was a clique, every operand
against every other:

- a construction's containing condition (above). This covers a tuple, a record, a constructor's operands and
  a constructor function's summary, in its list and its record form;
- a list literal's stored items, against each other and against what the list already holds (§18.2's table,
  `storedCond` and `rstoredCond`). A literal of n items is `apart [v₁] … [vₙ] [elements]`, beside each
  item's deep condition.

**Its form.** A condition holds an `apart` only when its expansion has more atoms than the apart has members,
that is Σᵢ<ⱼ |Gᵢ|·|Gⱼ| > Σ |Gᵢ|. Otherwise the condition holds the expansion. So `( a, b )` stays `sep π1 π2`,
three single operands stay three `sep`s, and a condition is never longer than linear in its members. The
groups are canonical: members distinct and in order, no group empty, groups in order. An apart is not merged
with a plain `sep` that one of its pairs repeats, because a conjunction that states one atom twice says the
same thing.

**Computing it, in one pass.** The pass gives the conjunction of §18.2's `sepCells` over every pair of members
of distinct groups, the same verdict and the same atoms. A condition whose operands' cells have no more pairs
than members is its expansion (above), and it is computed pair by pair, which is its definition. The pass
forms only the pairs whose kinds do not settle them alone, as §16.3's amendment does for a result's spine
conditions:

- a closure, a function value and a condition-only cell are `yes` against every cell. A top-level value's
  cell and a cell the body made are `yes` against every cell of another family, except that a made cell
  against a callback's result is not settled by kind. These pairs are not formed. For a record condition, a
  cell that cannot hold a record is also `yes`;
- two cells are related (`covers`, either way) only within one family (kind, owner), and only when one path is
  the other's step-by-step prefix. Each cell's ancestors are looked up in a table of its family's paths. A
  family with a `⋆` path, where a marker may hold a place, is compared pair by pair. A related pair is
  `sepCells`'s own answer (`shared` exact, else `lost`);
- a callback's result against the cells made in the other groups: one `reaches` for each callback result;
- `⊤`, a message (`payload`), a taken element and an `except` cell against every member of the other
  groups: pair by pair, as before. Inside core `Dict` (§20.8, where one arrival at a folded path is several
  places) the whole condition is pair by pair;
- the arrivals that are left (parameters, captures, callbacks' results) are the apart's groups, as
  `atomFacing` maps them for a list condition and as `rbase` names them for a record condition. A member with
  no list-facing cell leaves its group, and this removes exactly the pairs that named it.

**Instantiating it at a call.** Each group's provenances are instantiated once (`ProvMemo`) and joined. Their
cells are read once, and the pass above runs over them. A callback's result that two groups name (`sep cb_j
cb_j`, *fresh across calls*, which is not `sepValues` of the two instantiations) and every `apart-spine`
instantiate their expansion, pair by pair. These two shapes stay quadratic. A callback's `xreq` (`classReq`)
also instantiates its expansion.

**Relying on it.** A frame owns an apart when it owns every member. Every member is in some pair of the
expansion, so this agrees with the pairs. A requirement goes to `xreq` as the apart. When a call's `xreq`
apart fails, the call instantiates its expansion pair by pair. This reports each failure on the argument it
names, as before (§18.4 item 3). The entry protocol (§20.5) and a callback's `xreq` read an update's or a
class's requirements through their expansion, because their reports take the first failure in atom order. A
requirement that the read-off cannot name drops only that member. A condition with a member that the
read-off cannot name fails approximately, as any of its pairs would.

**Limits, the block and the text.** The `conditions` limit counts an apart as its members. The summary block
advances to version 21 (§28.4). An atom's kind byte comes first. An `apart` or `apart-spine` then writes its
group count (u32), and for each group its member count (u32) and its members as provenances. Members and groups
are in the block's canonical order. A summary line prints `apart [π1.f1 π1.f1.a] [π1.f2 π1.f2.a] …`, with
members and groups sorted by their text. So the only goldens that change are the ones that print a construction
condition or a list literal's condition of four or more operands, or a requirement made from one of them.

**Checked against its expansion.** Until #704 lands, a safety build compares each apart with its expansion.
At a construction, the condition the pass builds is compared with the one that `sepOfCells` and
`rsepOfCells` build pair by pair. At a call, the instantiation is compared with the instantiation of the
expanded atoms. Two conditions are the same when they have one verdict and, with every apart expanded, the
same atoms. The check runs in every safety build for an apart whose expansion has at most 64 pairs, and for
every apart with `-Downership-full-cross-check` (#272). A difference is a panic.

**What stays quadratic, and why.** §20.4's spine conditions of a result (`sc`, `sep-spine`) are per entry. Each
of a result's N list entries has its own condition, which separates it from every other entry. This is N
conditions of N − 1 atoms each, a star around each entry and not a clique inside one condition. One apart per
entry would still hold N(N − 1) members in all. A linear form needs one condition shared by the entries,
which is a change to the `res` entry's format, and this amendment does not make it. These conditions stay
pairwise, and #665's parent was already quadratic through them.

*As built 2026-10-22 (#693).* As specified. `pairwiseApart` is the one pass, `pairwiseApartByPairs` the
definition it is checked against, and `instPairwiseApart` the instantiation. The summary atom is
`XAtom.groups`, and in the walk an `apart` atom's `a` indexes an interned table of groups. A call's `xreq`
apart that fails is discharged again pair by pair (`relyReqs`). The entry protocol and a callback's `xreq`
read the expansion. The construction keeps #684's order of reading the operands' cells. Every verdict and
diagnostic is unchanged. Six ownership goldens print new condition text and no other change:
`FoldAccumulators` (browser-tea+everywhere), `LevelRecursiveUpdates`, `ListOfParams`, `MarkerAcross`,
`SplitCap` (browser-inline) and `WideFieldConditions`. The last golden fell from 261 KB to 79 KB, and what
is left of it is its 833 update lines. `ownership/ApartAcrossModules` reads a list literal's apart and a
record's apart through another module's summary. Its distinct operands are accepted and a list handed twice
is refused. `-Downership-full-cross-check` on `ownership/` fails only `RecordTree` (#427) and
`LevelPlacesKinds` (#694), as on `master`, and `test-records-lost` shows no difference in 1 091 programs.
The ownership phase's instructions (callgrind, ReleaseFast, `build --release --no-cache --jobs=1`) on the
research dashboard went from 25.2M to 23.3M at N = 16, from 121M to 87.8M at N = 64, and from 1 140M to 597M
at N = 256. On `nowd` they went from 122M to 90.4M. #665's parent measured 23.2M, 85.9M, 571M and 85.4M. Every
output hash is unchanged. On the safe binary, which is the budget's reference, `WideFieldConditions` fell from
2 617M to 1 579M. The two core ownership tests rose from 4 716M to 4 755M (*surface*) and from 4 563M to
4 603M (*clean*), and Conduit's dump rose from 3 160M to 3 189M. Of each rise, 21M to 23M is the safety
build's check against the expansion, which builds each checked condition a second time, and 8M to 17M is
the one pass's own bookkeeping. A condition no longer than its members is built pair by pair, so a
construction of two or three operands costs what it did. From N = 64 to 256 the phase still grows ×6.8,
as #665's parent did (×6.6), and the construction conditions are not the cause. At N = 256,
`containingCondition` and `instPairwiseApart` take 43M of the phase's 597M, and the entry protocol
(`entryFn`) takes 501M (#716).

*As built 2026-10-22 (#716): what a wide model cost.* The 501M under `entryFn` was not the entry's own
work: `entryFn` asks for the summaries of `update` and `view`, so it is the walk of the program's
functions. The dashboard routes every message through `step`, a `case` of N arms that each write one
field, `{ model | wᵢ = Wᵢ.update m model.wᵢ }`, and through `replaced`, the same shape again. Six loops
multiplied the width by itself there. (1) Each arm split `model` into the other N − 1 fields (§31.3's
closed split), and projected and read off each field again. (2) Each arm's base use was read off as
N − 1 uses, and normalizing sorted N² of them. (3) The arms' join sorted the N² entries they held.
(4) Each demand looked for its holders among every local, the N other arms' pattern bindings
included, and then scanned every later use of `model`: the other arms' uses and, at the call `step
msg model`, the call's own N uses for each of the N fields it writes. (5) At the entry, each of the N
writes asked whether the model's other paths reach it by scanning them, and `entryConditions` asked
init's whole record for each of the model's cells. (6) A construction's `except` operands, the
widgets' written models, were paired with every operand of the other groups, and each pair in a list's
condition was `yes`. Each is now done once or skipped by an index, and the answers are the same
answers: the split is kept per base cell and field, computed at the first update that needs the field,
so cells and paths are interned in the order they were; the read-off emits each field's use once; a
join of many parts merges them; holders are looked for among the locals bound outside the earlier arms
of the cases the walk is in (`bound_log`), and the uses are skipped past a case's other arms, before
the demand's point and over a call's own run; the entry's demands read the model through an index by the
key `covers` needs (`reachesIndexed`, `coveredBy`), which asks the entries a scan asks in the order it
asks them and leaves out only those that answer null and touch nothing; and an `except` operand that
no list faces is paired only with the operands it may be related to and those whose pair is not `yes`.
A record object's number in a read-off is a column; a path's written fields are joined in one sort.
Small declarations, records and unions keep the direct way, which costs less there;
`-Downership-full-cross-check` takes the indexed way everywhere and checks it against the direct one.
Every verdict, dump and output is unchanged.

Ownership-phase instructions (callgrind, ReleaseFast for the reference CPU, `build --release --no-cache
--jobs=1`) on the research dashboard at N = 16, 64 and 256: 28.3M, 91.4M and 621M on `master` before
(×6.8 from 64 to 256); 27.1M, 67.8M and 202M now (×3.0). `nowd` went from 93.1M to 66.6M. Every output
hash is unchanged. On the safe build, the core surface test went from 11 230M to 11 227M, the core clean
test from 10 954M to 10 952M, and Conduit's report from 4 340M to 4 333M (#754: `master`'s are
higher than #693's figures above, not yet explained). `ownership/WideModelArms`, a model of 256 records in the shape
above, has its report in 2 517M instructions on the safe build, where it took 4 438M.

What stays superlinear, and why. (a) The arms' values: §31.3 makes the value of `{ model | wᵢ = … }`
the other N − 1 fields, so a `case` of N such arms builds N² entries before the join folds them. Making
it linear needs an entry that stands for a split, a change to the abstract domain. It is now copying
and merging, not projecting and sorting. (b) A model of N records that each hold a list: `update`'s
summary has N list entries in its result, each with a spine condition naming the N − 1 others, as
#693's amendment above says, and instantiating them at the entry is N² atoms. In the dump of a
256-record model with a list in each record, the ownership work grows ×4.0 from 128 to 256 records.
A linear form needs a result condition shared by its entries, a change to the summary's format.

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
  *Amended 2026-10-16 (§30.11):* an accepted line says `(no summary: M.f)` only for a markup construction.

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
*Amended 2026-10-16 (#229): the set of cells is finite and every round of this fixpoint and of the invariant
below is counted against §16.7's `fixpoint` limit: §28's dated amendment *the entry's fixpoints settle*.*

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

*Amended 2026-10-22:* Browser.hosted writes entry on its callback record.
The hosted row and its P1–P4 and P7 obligations are specified and audited in
§30.3, including update and settle installing their returned state.

What the checker takes on trust, each item privileged code whose error is a correctness bug (thesis §6.5):

- `core/List`'s asserted primitive rows (§16.8, §18.5);
- `traverseAt`'s obligation, met by `foldlFrom`, `foldrFrom`, `mapHelp`, `indexedMapHelp` and `filterMapHelp`,
  the only functions that call it, core-private and audited (§19 item 3);
- `Dict.focus`'s destructive read, and `core/Dict`'s obligation that no function places one value at two
  positions of a tree (§20.8); *amended 2026-10-18 (§16.7's level marker, until #294):* read for callbacks:
  no function of `core/Dict` hands a callback, or writes, a value that a position it reads afterwards holds;
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
| Command constructors that take values (O5) | **built**: `Storage.save`, `Http.send`, `Cmd.log` (`Log.write` until 2026-10-20) (§22.3; `boundary.md` §9.8.16 (b)) |
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
`Body` (text, or parts of text) and whose `expect` is a function of the response; `Cmd.log level line`
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
| `EntryValueCommand` (browser-direct and browser-tea) | O5, §22.3–§22.4 | `Storage.save`, `Http.send` and `Cmd.log` of the model's text, then a push: `entry`; the same save through `Cmd.do` capturing `model`: `escaped` |
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

*Amended 2026-10-19 (#426): `browser-inline`'s send positions.* `browser-inline` builds its commands and
subscriptions over no `Hosted`: its runtime hands the bodies their sends from `Cmd` and `Sub` themselves, so
those are its asserted rows. Before, it had none, and a send's demand was never made: `SendInPayload` and
`NestedLambdaSend` built on the platform that edits lists in place.

| Function (`browser-inline`) | Row |
|---|---|
| `Cmd.perform body` | `job`'s: π₁ `calls many`, `sends π1` |
| `Sub.on k start tag` | `tap`'s one parameter along, past the key: π₂ `calls many`, `sends π1`; π₃ `calls many`, `need owned`, supplied **borrowed** — two declarations of one key share one listener, and each value goes through both taggers (`Sub.on`'s documentation) |
| `Sub.map sub tag` | `mapTap`'s: π₂ as `tap`'s tagger, borrowed |

`Listen.on`, which a start forwards its send to, has no row yet: a start written as a top-level function that
hands its send to it is rejected as a limit (`approx`), where a lambda of a platform layer is not reported on.

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

*Amended 2026-10-17 (issue #272):* a function parameter's summary fact says whether its `need` comes only from
a send (`sends`): the read-off sets it when every demand on what the parameter returns is a send's (`S`), and
every `need` it takes from a callee is a `sends` one; the hosted rows' taggers and mapped functions have it. A
`need` line through such a parameter says "`Cmd.task` sends what it returns, which may be a list it does not
own", whatever the function value is — a constructor keeps the sentence above — and one through any other says
that the callee edits what it returns. Before, a lambda or a named function handed as a tagger read "`Cmd.task`
edits what it returns". The fact changes no verdict.

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
           | 'once' | 'many' | 'owned' | 'fresh' | 'exclusive' | 'unknown' | 'entry'
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
| not an entry record | entry on a parameter other than a written-out record, or with an unknown callback field (§30.3) |
| impossible | two words that cannot both hold: a word twice; `unused`, `borrowed` or `entry` with any other; `aliased` with `returned`; `consumed` on a function; `once` with `many`; `owned` without `once` or `many`; two of `fresh`, `escaped`, `unknown`; `exclusive` without `fresh` |

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
| `Schema.print`, `printWith` | `borrowed Schema e a, aliased a → fresh Result …` | the engine reads the value and `JSON.stringify` reads what it made; an issue it answers may hold the value it was handed (`Issue.input`). Re-read 2026-10-15: a compiled schema's encoding worker (`schema.md` §6, *A statically known schema runs compiled*) reads the value and builds the host object the same way, and its issues hold the value as the engine's do. Re-read 2026-10-19: `print` builds its options with `defaultOptions ⊤`, a new record per call (§31.16), which reads neither argument |
| `Schema.parse`, `parseWith` | `borrowed Schema e a, String → unknown Result …` | `JSON.parse` makes new values, but the answer holds what the schema's own mapping, injection and conversion functions return, which may be anything (thesis §6.5). Re-read 2026-10-15: a compiled schema's decoding worker also returns its conversions' answers, so the answer is still unknown |
| `Debug.toString` | `borrowed a → String` | `toStringAs` walks the value; the set of objects being printed holds each only while it is printed |
| `Debug.log` | `String, returned a → a` | prints `toStringAs` of the value — a string, so the console keeps no reference to the value — and returns the value |
| `Hosted.keyOf` | `String, aliased k → fresh Key` | `Hosted.js`: `({ t: type, c: compare, v: value })`, a new object holding the value |
| `Html.Event` | `crossing` | a DOM event, made by the host: no beni value is ever put in one |
| `Node.print`, `Node.exitWith` | `→ fresh Program` | `Node.js`: `({ code, out })`, a new object of a number and a string |
| `Node.printLines` | `borrowed List String → fresh Program` | `items.join("\n")` on the list's array |
| `Ssr.render` | `borrowed Html msg → String` | `Ssr.js`: `html.t`, the markup's text |

*Amended 2026-10-16 (§30.9):* `Task.timeout`, `Task.raceOk` and `crossing Int32` have words, justified
there; a `List` of functions written out takes a function's words, which describe each element.

*Amended 2026-10-16 (§30.10, issue #218):* `Schema.parse` and `parseWith` carry no words. Their rows, and
`decode`'s, `read`'s, `encode`'s and `write`'s, are the checker's: a run answers what it builds and what its
schema's slot of that direction holds. `print` and `printWith` keep theirs.

**Without words, by choice.** Each `foreign` that handles only values that cross — `Js`'s bit operations and `rem`
(numbers), `regExp` (two string literals), `development`, `maySuspend` (read by the checker as a static bit, §23.3),
the platforms' `Dom`, `Browser.Events` and `Html.targetValue`/`targetChecked` (strings, numbers and a `crossing`
event) — has nothing a word could say. Each whose honest row is the thesis's — `Js.global`, `get`, `set`, `call`,
`apply`, `construct`, `at`, `setAt`, `instanceOf`, `method` (a getter, a method or a constructor of the host may keep
what it is handed), `Io.finish` and `Io.startRead` (kept by the runtime) — keeps the default, which is that row.
`Hosted.compareKeys` only reads, but only the runtime's own key comparisons reach it, where every key has already
escaped with its command (§20.4): no verdict depends on its row, so it keeps the default, which is the safe side. `core/List`'s primitives, `Dict.focus`, `Hosted`'s send positions and the program constructors
keep their rows in the checker (§24.5).

*Entry-word audit, 2026-10-22 (#750).* The entry word is a protocol, not a
replacement for the inferred body summary. Its obligations are audited in
§20.9 and §30.3. Browser.program adapts its callbacks to Browser.hosted;
Browser.hosted and host install each state result and retain no previous state.
Tea.sandbox, element, document and application adapt their callbacks to that
hosted driver. Browser-inline's foreign constructors are lowering markers;
the inline runtime owns its current state. Page.sandbox packages the callbacks,
and its runtime's run, patch, create and renderAttributes retain only the
current rendered view, with messages dispatched through the installed state.
The constructor bodies and the browser and page runtime helpers are pinned in
word-bodies.txt. Entry declarations print an entry line marked (words), separate
from their inferred summaries. Removing entry in a flip exposes the callback
writers as pending; the hosted and ordinary-program fixtures pin that boundary.

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
  Not in a recursive group, whose rounds would number the slots apart, and not inside a lambda
  (*withdrawn 2026-10-16*, §30.9 rule 1: inside a lambda a slot is the declaration's, as a parameter is).
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
§12.2's stale-read sanitiser, §13.4, is what will judge that). On 2026-10-15 it was one, CK-233, pinned red;
with §16.4's amendment of the same day it is zero.

| Rule | Where | What is unsound if the rule is wrong |
|---|---|---|
| The writers `List.pop`, `swap`, `insertAt` and `removeAt` (§3.1, §22.5) | `writerName`, the library rows | a demand on their base whose row is wrong (a `swap` that keeps exclusivity it should lose, an `insertAt` that stores without separation): two holders of one array, one written. The core has none of them; only Zig fixtures test them. |
| The re-cons rule (§3.2, *Not demands*): a list rebuilt in the shape a pattern matched is an alias | `reconsed` | a rebuilt `[ h, …t ]` taken to be fresh while it is the scrutinee's array, then written. The core's views alias their source, but no construction is ever read as a re-cons. |
| The multi-item prepend `[ a, b, …xs ]` (§3.2, §25.2) | `prepended` | as the single prepend's row below. The core's prepend takes one item. |
| A `++` on a generic type, dispatched through hidden evidence | dispatch identities, conservative call | none found: the checker reads it as a conservative call that escapes its operands (`appendable`), not as a construction, and the bridge spells `++` only where its operands are known lists. If slice 5 lowered an evidence-dispatched append in place, this row would become unsound. |
| Record field assignment (§31; *rewritten 2026-10-17*, the owner) | `evalRecordUpdate` and §31's `update` demand, in `src/own/` | two holders of one record, one assigned in place. It is judged by the checker on every platform, and every record update consumes its base (§31.3–§31.8). Its evidence is the generated differential test, the stale-read sanitiser and the mutation controls of §31.12. It is not modelled by this oracle; #316 (Jayson) models it later. Until then the bridge's confirmed-unsafe count says nothing of records. |
| A prepend of a list made after its base (§26.3) | `madeAfter` | a write onto the prepend's result reaches the base through a re-cons the rule took to be impossible. Copying prepend and conservative backing provenance are modelled; offset views and the re-cons identity optimization are absent, so made-after precision cannot be tested faithfully. |
| Ownership words on `foreign` signatures, and the thesis row for a `foreign` with none (§24) | `wordsRow` | a word claiming less than the JavaScript does: a write or an escape the checker does not see. The core has no foreign declarations or JavaScript sibling validation. |
| The decoder followed through `Expect` (§24.9) | `carry`, `carriedEnv` | a decoder's captures held past the call that runs it. No decoder/opaque carrier syntax; captures are tested as ordinary closures only. |
| Runtime entry delivery (§20, §22) | `entryCall` | Initialization transfer, retained callback captures, recursive Chain payloads and finite model preservation are modelled. The renderer, effects, opaque entry rows and unbounded event delivery remain outside the core; their actual runtime retention still needs platform fixtures. The shipping bridge skips every entry projection, so Zig's `entryCall` verdicts (a fifth of the real apps' demands, 2026-10-15) are never compared with the oracle. |
| Owned sends and navigation commands (§23) | `send_class`, `checkSender` | a payload a fiber, a command or the next dispatch still reads after the send, edited in place. *Amended 2026-10-15:* the send rule itself (§23.2, a send is a write of everything it is handed) is not modelled: the core has no send, and its `owned` boundary is the returns-owned rule and retained-callback obligations only. Fibers, navigation capabilities and asynchronous delivery have no core semantics, so runtime payload retention remains untested |
| `Dict.focus`'s destructive read (§20.8) | `assertDictFocus` | two positions of a tree holding one value, both written. List focus is modelled; the core has no tree, keys or dictionary representative separation. |
| Markup/constructor lowering and opaque carrier encodings | markup transfer and summary blocks | Slots and constructor payload retention are modelled as positional records; HTML syntax, wildcard opaque paths, import serialization and actual row/component lowering are absent. Their encoding must preserve the modelled slots and conservative fallback |
| Fold dictionary representatives and recursion | fold/focus summaries | Container ownership is modelled for lists and positional records; no dictionary keys, mutually recursive declarations or unknown or limited (§16.7) foreign rows exist in the core, so those implementations and their precision backstops still need Zig fixtures |
| Hidden-evidence initialization and suspension | `initializationTransfer`, dispatch identities/requirements | Private single-read transfer, captured-local exclusion and retained initialization environments are modelled. The core has no hidden evidence parameters, suspension or limited (§16.7) foreign summaries; their eligibility guards remain compiler-fixture boundaries. |
| *Amended 2026-10-16 (§30.9, O1):* a function slot or a function parameter called or handed on inside a lambda, and env calls of nested lambdas (rules 1–2) | `slotOf`, `envCall`, `passOn`, `applyEnvCalls` | a call the walk makes in the wrong frame, or a probe it drops on the way out: a supply taken for owned that a lambda still on the stack reads. The core's closures call their captures, but it has no function stored in a record (a slot) and no callee summary handed a lambda's own parameter, so neither rule is compared with the oracle. |
| A send value is never a list (rule 3) | `flat`, `probeDemand` | a cell the walk takes for the runtime's function while it is a list. The core has no send (row above). |
| What a custom type may hold, read off its constructors (rule 4) | `mayHold`, `ownMayHold`, `birMayHold` | a cell the type filter drops while the value may hold it: an alias lost. The core is untyped for this purpose; only Zig fixtures and the corpus test it. |
| Supplies probed cell by cell, a capture of the declaration's frame named and borrowed, a borrowed supply that holds nothing at a call (rule 5) | `passOn`, `declView`, `returnsOwned` | a cell taken for owned because the probe of its neighbour passed, or a supply skipped as empty while the argument holds a cell. The core's supplies are one value per call, so the split is not compared. |
| What a callee relies on of the declaration's own function, and of an enclosing lambda's parameter (rules 6–7) | `provOwned`, `deferLambdaNeed`, `dischargeLambdaNeeds`, `undischargedNeeds` | an obligation dropped where a lambda is consumed out of the walk's sight. The sync's "forwarding an enclosing callback's owned-result obligation" models the declaration's half; a lambda's own parameter, decided at each consumer, is not modelled. |
| A carried lambda's calls of what the caller passed, re-carrying, and a top-level value's lambda whose captures hold nothing (rule 8) | `carry`, `callThrough`, `carriedCallOwned`, `carried`, `sharedOf` | a function value's result taken for made by the call while its class returns a list another holder keeps. The core's closures are not carried through results with their classes. |
| A top-level value that names a function (rule 9), and the entry's URL taggers (rule 10) | `aliasTarget`, `entryTagger` | the wrong summary applied to a point-free name; a tagger the runtime sends from unchecked. Neither has core syntax; entry delivery is outside the core (row above). |
| Words on a `List` of functions, `Task.timeout`'s and `raceOk`'s, `crossing Int32` (§30.9) | `wordsRow` | as the words row above: the fiber runtime and its scope are not modelled. |
| *Amended 2026-10-16 (#229):* a carried lambda named by where it is made, and the walk's fixpoints settled over finite cells and capped by the `fixpoint` limit (§28's dated amendment *the entry's fixpoints settle*) | `carry`, `entryConditions`, `entryCall`, `instCb`, `instFold` | a lambda whose merged captures miss what one instantiation captured: an alias lost; or a round taken for settled while a carried lambda still grew. The Lean model already names what a traversal or the model makes by its site (`.position site`) and fails a fixpoint that does not settle within its 24 rounds loudly, as a rejection (`throw "limit: …"`); Zig's cap is 32 and an error at the declaration. It carries no lambdas through results (rule 8's row), and the bridge skips entry projections, so neither the merge nor the caps are compared. |
| *Amended 2026-10-16 (§30.10):* a schema's slots, the derivation from its declaration, and what a run answers | `schemaRunRow`, `schemaMakerRow`, `schemaTaint`, `schemaMemberRow`, `conversionSlots`, `codecRunRow`, `settleRun` | a list a conversion, a `Value` or a codec returns taken for built by the run, and written in place while its other holder keeps it. The core has no schemas, no JSON and no evidence; the bridge never emits one, so its confirmed-unsafe count says nothing of this rule. Zig fixtures (`ownership/SchemaAnswers`, `check/bad/direct/SchemaConversionShared`) and the corpus test it. |
| *Amended 2026-10-16 (§30.11):* a call of a function the checker cannot identify answers `⊤call`; a record field called with a dot is its value called; a schema declaration's member handed on as a value has its run's row for its class, and a tagged schema's constructor is a constructor (#269) | `conservativeAV`, `unknownCb`, `fieldFunction`, `callValue`, `memberValue`, `ctorClass` | a write accepted onto a list a function returned while another holder keeps it. The core calls only closures it can name — no function is read out of a dictionary, a record field or a list, and no callee is handed one — so it has no unknown callee and no dot-called field, and neither rule is compared with the oracle. The core has no schemas either (the §30.10 row). The corpus fixtures (`ownership/UnknownCallee`, `UnknownCalleeTagger`, `UnknownCalleeForms`, `DotFieldCall`, `SchemaMemberHanded`, `SchemaMemberExt`) test them. |
| *Amended 2026-10-17 (#291):* the keep edge (§16.4's amendment, #281) | `callbackKeeps`, `returnsOwned`, `readOffFrame` | **compared with the oracle**: the core needs no rule of its own, because it answers a callback's class at the call site, so a kept result holds what the callee handed it; `Fixtures.lean`'s CK-251 ports give the goldens' verdicts, except the two approximate rejections (`writeFirst`, `kFresh` under a dropping callback), which the core accepts with the two interpreters agreeing. Constructors as callbacks (`keepCtor`, `keepOne`) have no core syntax. |
| *Amended 2026-10-17 (#291):* the `callbacks` limit (§16.7, #271) | `inst_depth`, `instProv` | **compared with the oracle**: the core counts the hand-on chain per binder (`Domain.rhsChain`) and refuses the fifth callback as `limit: callbacks` in both checkers; nesting cannot occur in the core. `Fixtures.lean`'s CK-249 ports give the goldens' verdicts. |
| *Amended 2026-10-17 (#305):* §30.9's `need` and a lambda's own parameter relied on (rules 6–7), and the labels (rule 11) | `provOwned`, `deferLambdaNeed` | **compared with the oracle** for the shapes the core states (`Fixtures.lean`'s #305 ports): the core answers a callback's class at the call site, so a `need` is the shared root's cell refused; labels are diagnostics. A function below an input path and a lambda capturing a function parameter are its limits (`LambdaParamNeed`, `RandomGenerate`). |
| *Amended 2026-10-17 (#305):* a top-level value that names a function, through at most eight names (§30.9 rule 9) | `aliasTarget` | **not reachable by the core**: it has no top-level values. Its alias-chain fixtures bind the aliases locally, which both checkers follow precisely through any length (the Zig checker refuses the local chains as `later-use`, with no cap), so the cap and the `⊤call` past it are never compared. |
| *Amended 2026-10-17 (#305):* §30.11's `⊤call` | `unknownCb`, the conservative call | **not reachable by the core**: every function it calls is a known closure or a symbolic input its frames resolve, so it never produced §30.11's hole and cannot state the rule; the `UnknownCallee` shapes it states are decided precisely, and the two checkers agree on them; a function out of a list a declaration is handed, where Zig answers `⊤call`, is the core's limit. The owner decided on 2026-10-17 (Cesar, dashboard `ownership-proofs-q6`) to record the gap rather than add an opaque function value to the core: the rule stays with the Zig fixtures. |

### 26.8 Open questions

1. **`List.cons` written as a call** keeps its approximate row; only the construction is narrowed (§26.3). No
   measured program writes the call with a fresh front item.
2. **Fresh items that are not lists.** A record or a constructor value made after the base cannot be `Js.same` as
   a stored element either, but the domain gives a record no cell of its own, so §26.3 cannot see that it is new.
   No measured program needs it.
   *Answered 2026-10-17 (§31.2):* a record is a cell once records are written in place, `site(ι)` for a literal,
   so a record made after the base is seen to be new. A constructor value still has no cell.

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
read it; no measured summary reaches the cap. *Amended 2026-10-16 (#220):* no longer — the guard counts distinct
atoms, whatever their order, and reaching it is an error, not a cut; `Dict.merge` had reached it all along.

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
  module's constructor table — both functions of the module's source, which the key covers. *Amended
  2026-10-15 (issue #156):* that table is the BIR's constructors, then each tagged schema's (`schema.md`
  §4), in declaration order, its `Type` family's variants before its `Encoded` family's. A pattern on a
  schema's constructor, local or imported, names it there. It had been given an id with no module, which
  no block can name, and writing the block crashed. Block version 10;
- a **path** step by step (§4.1), a field by its name, a constructor step by its constructor and argument;
- a **local** of a carried lambda (§24.9) by its index in the declaration, as BIR numbers it.

The format is versioned with the rule set (`summary_bytes.version`, thesis §8.5): a block of another version is
absent. *Amended 2026-10-22 (#693):* version 21 writes the `apart` atom's groups (§16.7). Reading a block re-interns its paths, re-sorts each summary by this run's ids (§16.6's normal form) and
re-merges nothing.

*Amended 2026-10-23 (#814): a block is read as far as the run asks.* Version 27 writes each summary's length
(u32) before it. Opening a block reads its head, its module and string tables, the offset of each path in its
path table and the span of each declaration's summary, and whether each value may hold a list. A summary is read
and put in normal form the first time the run asks for it (`blockSummary`), and a path is interned the first
time a summary being read names it; both are kept. A summary that does not read, or names a path that does not,
is no summary for its declaration: a callee with no summary, as a block that does not read is (§16.4). A block
whose head, tables or directory do not read is still no block. Nothing a summary says changes, and no verdict:
only which of a module's summaries a run reads. Before, opening a block read and normalised every summary in it.
Core `Schema`'s block holds 300 or so, and a program that calls `Schema.read` read them all, 14.8M
instructions in every build of a TEA program that uses it, where every other module's block costs 0.2M or less.
*As built:* the ownership phase's instructions (callgrind, ReleaseFast, `build --release --no-cache --jobs=1`)
on the research dashboard went from 26.5M to 11.4M at N = 16 and from 68.7M to 53.7M at N = 64, and on `nowd`
from 68.2M to 53.4M. Opening all ten blocks a dashboard build reads costs 0.19M at N = 16. Every output hash is
unchanged; `test-records-lost` shows no difference in 1 168 programs, and `-Downership-full-cross-check` on
`ownership/` fails only `RecordTree` (#427) and `LevelPlacesKinds` (#694), as on `master`.

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
*Amended 2026-10-16 (§30.9 rule 8):* the carried generator is now followed, so
`Random.generate (Random.list generator n)` is accepted when the generator makes what it returns;
`Random.constant` with a shared list is still rejected (`ownership/RandomGenerate`).

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
*Amended 2026-10-16 (§30.11):* an acceptance can rest on such a callee's result only when the call is a markup
construction; a write onto what a function the checker cannot identify returned is an approximate `unknown`
rejection.

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

*Amended 2026-10-16 (#220):* a fifth, `ownership_limit` (`OWNERSHIP CHECK TOO LARGE`), for a declaration whose
summary reached one of §16.7's limits: an `error`, on the same platforms, one per declaration and limit, its span
the declaration's name, its message the declaration, the limit and what it measured, and that the limit is the
compiler's. Its excerpt is the renderer's. A run that reports one does not report the rejections with the
`limit` cause (§16.7).

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

*Amended 2026-10-17 (issue #272):* a `need` line (§16.2, §30.9) is about a function value, not a list, and its
message says so. Its sentence names the function value — the argument as written, "a lambda", or "a function
value" when nothing names it — says that it must return a list it owns, and why that fails: the exact detail, or
that the checker cannot show it does. Its places are the call that hands it on ("the function is handed on
here") and, when the function that fails is known, where it is: the lambda or local function as written, or
the call or value that carried it here ("the function here may return a list it does not own"). Its fix is in prose: have the function return a list it owns, a
new one or a copy made with `List.copy`. Before, the message said that the function changes a list it is
handed, put "the list is changed in place here" under the call, suggested a copy before the change, and named
a lambda's own parameter `<function value>`.

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

*Amended 2026-10-19 (issue #423, the retirement of `browser-direct`):* the harness no longer names
`browser-direct`. **Whether a build enforces is the chain's**: its first `"lists"` down the chain (§28.2), read
from the shipped manifests under `platforms/` or a test platform's own, or the hidden `--ownership-everywhere`
(§30.7). The whole-program lowerings, `browser-direct` and `browser-inline`, are the platforms whose chains say
`"in-place"`. Hence:

- **The dump against the build** holds for every `.platform` token whose chain enforces. A token
  `<platform>+everywhere` is that platform with `--ownership-everywhere`, its golden
  `X.<platform>+everywhere.ownership`; `browser-tea+everywhere` is the enforcing build of a program written for
  `browser-tea` (`ownership/LaterUseEnforced`).
- **`build/bad/everywhere/`** projects are built for `browser-tea` with `--ownership-everywhere`: the checker's
  refusals, apart from any lowering's. **`check/bad/inline/`** fixtures are checked with
  `--platform=browser-inline`, as `check/bad/direct/`'s are with `browser-direct`.
- **The `browser-tea` cross-build** of the first bullet is made for every enforcing `build/bad/` project whose
  golden holds only the codes of §28.6: under `build/bad/direct/`, `build/bad/inline/` or a project's own
  `platform/` on an in-place chain, and under `build/bad/everywhere/`, where it is the same build without the
  flag.
- **The release refusal**: every enforcing `build/bad/` project is built again with `--release --allow-debug`
  and must be refused with the same diagnostics and nothing written. `--allow-debug` is there because `Debug`'s
  own refusal is `build/bad-release/`'s claim.

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

### *Amended 2026-10-16 (#229, the owner's decision):* the entry's fixpoints settle

**Why they did not.** Each round of a fixpoint inside a walk instantiates the same summaries again, and a
fixpoint has settled when a round adds nothing: the model's union is as long as before (§20.4), every cell's
condition is what it was (the invariant above), a callback's result is as long as before (§16.4 item 6). That
test is right only if a round that changes nothing makes no new cell. Every cell instantiation makes is named by
where it is made — `result(call, k)`, a taken element by its container and call, a callback's result by its
parameter and call — but one was named by when: a lambda a callee's result carries (§24.9's `carry`) was a new
closure, so a new cell, at every instantiation. `update` returns its commands' lambdas (`Cmd.perform λsend →
…`), so every round of the invariant made two new cells, the table of conditions grew, and the comparison failed
in every round — after round two on T29, every one of 32 rounds; then the backstop lowered every seed to `lost`,
silently. TodoMVC, Conduit, Bike Wars and the defect pages reached it, and a recursive tree that `update` grows
was rejected for it as soon as an arm returned a command with a lambda (`ownership/EntryInvariantCommand`). A
callback that returns a decoder (`List.foldr names decoder field`) reached a callback's backstop of 4 the same
way and added `⊤`. The model's own backstop of 8 was a second silent loss: a model that relays a list one field
per message needs a round per field, and at nine fields the `⊤` it added made an unrelated field's edit a list
"from JavaScript" (`ownership/EntryRelay`).

**The rule: the cells are finite, and each fixpoint is computed over them.**

1. *A carried lambda is named by where it is made*: the call, the callee's summary, the lambda's place in it, the
   callback depth and the entry's namespace (§20.4) — one closure per place, standing for every lambda made there,
   whose captures are the union of every instantiation's. This is the abstraction `result(call, k)` already makes
   of the lists a call makes in every round; it only adds aliasing. It loses nothing the fixpoint kept before:
   the rounds' values were already joined, so the model held every round's lambda, each capturing a subset of what
   the merged one captures.
2. *A round has settled* when it makes no cell, grows no carried lambda's captures, and moves no condition (or,
   for a shape, adds no entry). With (1) every cell a round can make is one of finitely many — calls, summary
   entries, paths a type bounds (§16.7) — and a condition only goes down a chain of finite height (`yes`, then
   more atoms over finitely many cells, `lost`, `shared`), so each fixpoint reaches its least or greatest
   fixpoint in a number of rounds bounded by the program: by the longest chain of messages a value needs to
   reach its place in the model, not by a constant.
3. *Every one of these fixpoints has the same cap*, §16.7's `fixpoint` limit of 32 rounds: the model at entry
   (formerly 8), its exclusivity invariant, a callback's result and a fold's shape (formerly 4) and a fold's
   spine. **Reaching it is an error**, `ownership_limit` at the declaration that makes the call: a shape adds
   `⊤limit`, whose rejections have the `limit` cause and are not reported beside it; an invariant lowers its
   seeds to `lost`, a partial proof accepting nothing. The rounds a fixpoint needs grow with the program, as
   a model that relays a list from field to field one message at a time needs one round per field; the cap
   bounds the work of such a chain, rounds times the model, and a program that needs more is told so.

**Measured** (2026-10-16): over the 948 programs of `bench/ownership-everywhere.mjs`'s set and the ownership
corpus, core and every platform, the model at entry settles in at most 4 rounds, its invariant in 2, a
callback's result in 3, a fold's shape in 3 and its spine in 2; the research dashboard (shared components,
`beni-direct`, N = 1 … 1 024) in 3 and 2. No program reaches the cap. The verdicts of all of them are unchanged;
one summary is more precise (`bench/corpus`'s `Decode.at` loses a `⊤`). The checker does fewer instructions on
Conduit (−15 % instructions, a ReleaseFast `check`), as it runs 2 rounds where it ran 32. Summary blocks advance to version 13.

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
classes, summaries past a limit (§16.7) and exhausted solvers establish no invariant.
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

### *Amended 2026-10-22 (#720):* fold ownership follows the written path

Amends §16.4 item 6 and the dated fold-invariant amendment above. A fold's
accumulator conditions distinguish each element path. In a table of pairs,
`acc[*].0` may hold shared comparison keys while `acc[*].1` holds separately
owned value-list containers. Sharing the keys does not refute ownership of the
outer table array or of the value-list arrays. It does refute a write of the
keys unless their own conditions establish ownership.

The greatest must-invariant retains each written container's `spine` condition
and its `sep_spine` conditions against every other result position, including
unwritten keys. A focus's `keep_spine` selects the replacement at the written
path; its descendants are not implicitly owned. A container write relies on
these path-qualified conditions rather than deep exclusivity of the entire
accumulator element. Deep writes retain their deep conditions. This changes
neither the initial-value check nor the non-escape and liveness obligations.

The induction is per written path: its initial containers are owned; each
callback transfers them once or creates fresh replacements; separation from
all retained positions preserves the next step. Keys may alias each other,
but a key that aliases a written value list refutes separation, and writing a
key still held by the table refutes liveness. The list-key table fold of #720
must be accepted, with its String-key and explicit-call controls; both unsafe
twins must remain refused. No table representation change is required.

**Construction evidence.** Before equal `[*]` entries are merged, a construction
records a value-scoped container condition at each path whose containers must
be separated from another operand's containers. Repeated placement at that
path refutes its condition. A duplicate at the key path therefore refutes the
key condition without refuting the value path. These annotations follow the
containing value through projection, results and callback supplies; they do
not weaken an allocation globally. Summary blocks carry the container
condition of a supplied annotation as well as its existing deep and record
conditions. Old blocks are invalidated.

*Amended 2026-10-22 (#773).* At a call, such an annotation with no deep
condition is never an alternative allocation at its result path, whatever
its record condition says: whether a path has several choices decides how
the entries of a list are approximated, and a list's line reads no record
condition (§31.4 item 6). Before, a failing record condition made the
annotation a second choice, and the list lines of four corpus programs
moved under `--ownership-records-lost`.

The dictionary's existing asserted focus row (§20.8) states the tree algorithm's
structural separation itself. Construction annotations made inside that
algorithm are not additional arrivals or results of the primitive: the row
publishes the actual selected value under its existing conditional loan and
the actual result under its existing keep/keep_spine proof. Caller annotations
on the selected value still follow projection and remain checked. In
particular, a caller's duplicate value or key/value alias is not an internal
tree annotation and is never discarded by this rule.

**A symbolic operand keeps a projection rule.** A guard for two whole parameter
values cannot be reduced to a fixed root condition: `[ row, row ]` also shares
`row.1`, and two different rows may share that field. The guard records
`sep_root(a, b)`: the array at the selected root of `a` is separate from every
array reachable in `b`. Projecting the annotation projects `a` and retains `b`.
Instantiation distributes it over the actual entries of `a`, at their own
relative result paths, and over all entries of `b`, before equal entries merge.
Thus a guard over an opaque tuple becomes distinct guards for its key and value
paths when the tuple is supplied. It is asymmetric and is never canonicalised
by swapping its operands. Callback supplies and cached summaries retain the
projection rule. This requires neither a path enumeration cap nor a deep
exclusivity assumption for an unwritten sibling.

At a polymorphic-recursive call, an annotation uses the same variable boundary
and first-mark/next-fold rule as its selected source. The boundary remains
anchored when distributing the annotation has already expanded its result
path. Folding merges the annotations at that boundary and creates no new
array provenance. These marks are cleared before a settled summary is
published, as the existing data-path marks are.

### *Amended 2026-10-22 (#759):* preserve the folded tree's conditional positions

Amends the construction-evidence rule above, under the existing §20.8–§20.9
Dict obligation. Inside core Dict, structural paths of the same incoming tree
name its separate positions conditionally. Their construction guard retains
the selected position's container condition, including caller annotations.
It does not instantiate their possible contents as two simultaneously stored
values: after recursive folding, both alternatives can name the same input
value without the tree storing that value twice. This applies to a parameter,
capture or callback result of that same arrival, not to distinct arrivals.

Other construction guards retain asymmetric `sep_root` and its projection
rule. In particular, inserting a value already stored at another key, placing
one list in both tuple fields, and aliasing a key with its value remain
refused. Per-written-path fold conditions and #720's negative twins are
unchanged. Summary blocks made under the earlier interpretation are invalidated.

The singleton tuple reduction of #759 is accepted again, as are
SubscriptionTapAppend, DictFoldLeft, DictFoldRight and FoldRight. The separate
#663 DictFocusGrow limit remains deferred to #294.

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

*Amended 2026-10-22 (issue #709):* the same conditional proof applies when a
callee sees its tagger calls and supplies its input borrowed. Seeing the calls
does not give a retained capture ownership, and losing sight of the calls is
not required to publish the no-tracked-cell requirement. Every other result
position and every supplied parameter still passes the usual returns-owned
proof. This clears generic constant-message subscription wrappers when their
actual messages hold no list, without accepting a retained list.

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
public values, foreign values, recursive initializers, summaries past a limit (§16.7),
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

*Clarification, 2026-10-16 (a write in `main`).* This rule is why `main`, or any
other parameterless value, may write a private top-level list that a function
may not. Take `xs = [ 1, 2, 3 ]`, private and named nowhere else, and
`main = … List.set xs 0 9 …`: the write is accepted, and the report prints the
cause `call`, because the read is the instantiated result of `xs`'s summary, as
a callee's result is. `bump n = List.set xs 0 n` is rejected `top-level`
(`top_level_list_changed`), because a function's body may run many times. The
acceptance is sound in place. After the write, no source-level reader of `xs`
is left that could see it: the module names `xs` once, and that one read runs
once. A second read anywhere in the module, a read in a lambda or a local
function, or a `pub` on `xs` makes the write `top-level` again, and the
destination stays shared, so a function that writes it is `top-level` too
(`destinationStillShared`). `InitializationTransfer` has a case for each of
these, and `issueRead` (accepted) and `functionRead` (rejected) are the two
halves of this one. §26.7 records that the oracle models the rule.

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
| `browser` | `Browser.program`, `Browser.hosted` | program was the template row; hosted uses the dated amendment below. `programs` and `mountAt` take `Program` values, not records of functions, and need none |
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

*Amended 2026-10-22 (the owner, #750, #319, #294): hosted programs and the
first implementation of the entry word.* The word, rather than a declaration's
name or package name, selects the entry protocol. The record's callback types
determine whether a result is the whole state or a state/command pair, and
whether init receives application arguments. Renaming a constructor changes no
ownership verdict. All existing entry demands and refusals remain in force.

This first piece preserves existing verdicts while the rest of O3 is pending:
the existing renderer-mode check (the in-place platform property, or
ownership-everywhere for checking the future universal contract) still decides
whether an otherwise accepted entry write is reported as platform-refused.
The declaration is selected only by entry, never by a constructor's name.
Browser-inline's Tea.sandbox and Tea.element also carry entry, preserving the
rows the existing in-place-property lookup gave them.

A record with a settle field declares the **hosted protocol**. Its callbacks
are init : Host msg → state; update : Host msg, msg, state → state;
settle : Host msg, state → state; and view : state → Html msg. Here Host
is Browser.Host: the Host argument is crossing at these runtime calls, including
init, update and settle; it supplies no owned application cell. This is a fact
of this argument, not a declaration that arbitrary Host values cannot retain a
callback. A callback that stores state through a Host operation still escapes
that state and is refused when the escaped state is written.

The runtime installs init's result, applies settle before the first view, and
thereafter installs every update result. At a render it calls settle on the
current state, installs its result, and then calls view on that state. Update
and settle receive the state owned. Neither can leave an old state available to
a later runtime read. Settle may change the state, so its uses, escapes, result
aliases, exclusivity requirements and writes participate in the same entry
analysis as update's. The finite state invariant includes init and both
transitions, with separate fresh-cell namespaces for update and settle.
A view event's retained cells, callback captures, and values escaped by either
transition are checked against both writers. View remains read only.

This adds settle to the allowed field names of an entry record. An unknown
field name, a parameter that is not a record written out, a nested entry word,
or entry on a result is misplaced_ownership_word. Entry is a protocol on the
record, not an assertion replacing the constructor's inferred summary with
unknown defaults. Other ownership words retain §24.2's defaults. The row requires update to
have the protocol's two or three parameters and hosted settle to have two;
a hosted update returns the whole state. An unsupported shape supplies no entry
row and leaves its writers pending, rather than dropping a state parameter.

Browser.hosted joins §20.9's trusted surface. Its implementation in
platforms/browser/Browser.beni (hosted, host) meets the obligations:

- **P1:** host reads its model reference, calls update or settle synchronously,
  and writes the returned state to that reference. It keeps no previous state.
  Init is called once per mount; its result goes through settle before view.
- **P2:** after either callback returns, host reads only the installed result.
  Reentrant messages enter the inbox while dispatching; rendering is guarded
  during dispatch and settlement. No old state is handed to a concurrent call.
- **P3:** handlers and messages retained by view are part of the entry's event
  slots. Their captures are checked against writes by update and settle; a
  rendered handler retaining a written list is refused.
- **P4:** after settlement host recomputes the whole view from the installed
  state. It retains the rendered result, not an extra snapshot of state.
- **P7:** the renderer must not use a written list's identity to decide that it
  is unchanged (backend.md §15.5). The hosted adapter adds no such comparison;
  its dirty/started flags decide whether a render is due, not whether a list
  value changed.

These are privileged runtime obligations, not an exemption for Tea or private
tables. User code cannot write entry. Shared initial state, duplicate state
paths, retained callback captures, view-event aliases and state stored through
a Host continue to be judged and refused by the ordinary entry checks.

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

  *As built (2026-10-15, issue #156).* The crash could be reached on `browser-direct`, so its fix landed
  first, in #195 (§28.4's amendment of the same date). The flag is **`--ownership-everywhere`**. It is
  on `Cli.Common`, so `check`, `build` and `dump --stage=ownership` all take it, and no usage text lists it.
  It does what the patch did:
  - every chain enforces, and every chain reports its platforms to the maker;
  - every platform module counts as in place for §20.2's rows;
  - the name table also gives the direct row to `browser`'s `Browser.program` and `page`'s `Page.sandbox`.

  The checked core is read as built: its blocks were made under the ordinary rows, and the patch read
  them that way too. A key that told the flag's entries apart would also miss every module of the
  checked core, which more than doubles the cost, so the flag does not change the key. Instead, a
  cache's entries go to its `ownership-everywhere/` subdirectory. That keeps blocks made under the
  flag's rows away from an ordinary run. The script is `bench/ownership-everywhere.mjs`, and its first
  run is in `bench/README.md`.
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

  *As built (2026-10-16, issue #210):* §30.9. 31 of 835 programs rejected became 3, and the two lines
  of `browser-tea`'s `Tea.application` none. The three left wait on the owner: `ApiItems` and `ApiLogin`
  on what `Schema.parse`'s answer holds (#218), `RefModify` on whether a `Ref`'s value may be lent
  owned (#219). Until they are answered O1 is not accepted.
  *Amended 2026-10-22 (the owner's 2026-10-18 plan for #315):* O1's
  acceptance condition counts **LIST** demands only. Record-update refusals
  remain report-only input to R4; R4 enforces and clears them after #286.

  *As built (2026-10-22, #210):* the #737 folded Dict tree regression is
  recovered by #761, with #720 and its negative twins preserved. #780 repairs
  the pending index; the owner-deferred #663 DictFocusGrow keeps its checked
  red signature under #294. #782 narrows PointerEvents' handler capture to
  the scalar it reads. #792 builds the Cloudflare host conversions as native
  fresh lists. #794 retains the possible writer on generic callback keep
  edges until the concrete callback is known, recovering the Workers
  corpus without ownership assertions. The remaining four genuine Ref
  sharings use explicit List.copy in the fixture, the two server apps and
  LogSetMinimum, following #219. The Ref API is unchanged.

  The complete audit covers **1,505 roots/module sets and 1,295 LIST
  lines: 0 rejected, 0 pending**, with no check or dump errors. It includes
  the positive corpus and its platform variants, development Debug fixtures,
  the Workers corpus, every example, live benchmark app, core and platform
  surface, including the schema prototype's platform. Intentional LIST
  refusal controls retain their verdicts. The audit driver and result are
  attached to #210. Record reports are separately inventoried for R4 on
  #315 (comment 6349557915), with every site and cause in its two linked
  inventory parts.

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

  *Amended 2026-10-17 (the owner, #322):* O6 is the language's, not `browser-direct`'s. Every record
  update consumes its base on every platform, and one the checker cannot prove safe is a compile error.
  §31 specifies it and supersedes C4. It comes after O5 and after #286, #289 and #293 (§31.12). The three
  identity sections above are amended for records with §31 (§31.11), on every platform.

*Amended 2026-10-22 (#315, the owner's 2026-10-18 plan):* record work builds the hoist channel
and the record sanitiser before O5, and O5 reuses them. The channel alone does not depend on #286;
record enforcement and in-place record lowering do. This supersedes O6's earlier ordering above.

### 30.8 Open questions

The platform question is closed, and the slices have no open question. One decision is the owner's,
under CLAUDE.md rule 10, and O1 waits for it: **which of the persistence and identity tests of
causes 2 and 3 are retired, and which are rewritten with `List.copy`.** These are `ListPersistence`,
`ListForms`, `ListPrepend`, `ListSpreadPatterns`, `ListIdentity`, `ListIndexedIdentity` and
`WriteRowsIdentity`. The rest of O1 is decided as §30.7 writes it. That covers the cause-1 fixtures,
`QueuedListSnapshot`, the precision work, and the correction of the eight tagger lines that print as
exact, which is part of O1 and not left to choose.

*Answered 2026-10-16 (the owner, issue #210):* the three identity tests (`ListIdentity`,
`ListIndexedIdentity`, `WriteRowsIdentity`) are retired — the identity promises they pinned were
dropped on 2026-10-13 (§27). The four persistence tests (`ListPersistence`, `ListForms`, `ListPrepend`,
`ListSpreadPatterns`) are rewritten with an explicit `List.copy` where a version is kept, each with a
rejected twin in `check/bad/direct/` that pins the ownership error. §30.9 records how O1 was built.

**`entry` on a third-party platform** is checked the way every ownership word is (§24.6). Its
placement and shape are refused when wrong (§30.3). Whether the runtime behind it keeps P1–P4 and P7
is not checked. It is trusted, as a `foreign`'s words and its sibling's behaviour are. The platform is
privileged code (CLAUDE.md rule 6), and a false claim is a defect in that platform. Shipped and test
platforms are pinned by `trusted-surface.txt`. A third party's are not.

### 30.9 O1 as built: the corpus, and the precision rules (2026-10-16)

*Amends §16.5, §18.9, §20.3, §23.4, §24.2, §24.4, §24.8, §24.9, §28.5 and §30.3. Issue #210; it also fixes
#212.*

**The corpus.** The real sharing of §30.2's causes 1–3 is the programs': each fixture now makes its list
where it writes it (a top-level value made a function: `ListIndexed`, `ListIndexedDeep`, `ListForms`'s
forms, `KeyedInPlace`'s rows) or keeps the version it reads again with `List.copy` (the constrained
constants, `Int32Keys`, `ListDirectDeep`, `NestingFlatList`, `QueuedListSnapshot`'s snapshot and the four
persistence tests, §30.8). The three identity tests are deleted. No `List.copy` was added to core or to a
platform.

**The rules.** Each is general — no row names a program — and each only adds facts a body shows or the words
state. None accepts a write the rules before it rejected for a reason the text shows.

1. **Function slots, and the declaration's function parameters, inside a lambda** (§18.9, §24.9). A capture
   of one of the declaration's own parameters, at a path, is a slot of the declaration in the lambda too.
   Calling it inside the lambda is an env call (§18.9), made wherever the lambda runs. Handing it, or a
   function parameter, on to a callee inside a lambda passes the callee's facts to the declaration
   (§16.4 item 4: `calls` — `many`, since the lambda may run more than once — `need`, `seen`, the send
   position) and its supplies. A callee's result through it is that parameter's result, `cb` of the
   declaration (§18.9). Before, a pass inside a lambda only lost sight of the parameter and dropped its
   `need`, so a tagger handed on inside a lambda was never asked to return owned (#212,
   `ownership/LambdaPassNeed`). §24.9's "not inside a lambda" is withdrawn; "not in a recursive group"
   stays.
2. **Nested lambdas** (§18.9). An env call of a lambda checked inside another lambda is that lambda's env
   call, its arguments in the outer lambda's vocabulary, made wherever the outer one is checked. Each
   lambda on the way keeps its probe, and a supply is owned only when every probe passed; the call counts
   `many` when some lambda on the way runs more than once (`ownership/NestedLambdaSend`).
3. **A send value is not a list** (§23.2). A send's payload gives up every cell it holds but a send value:
   the runtime's function, which holds nothing of the program's (`ownership/SendInPayload`).
4. **What a custom type may hold is read off its constructors** (§6.1's type filter). Whether a value of
   a type with a body may be, or hold, an object of another type is decided by its constructors' fields
   and an alias's body as written, a type parameter being the caller's argument. Before, every type that
   held anything was taken to hold anything (`ownership/NominalHolds`: a `Validation` never holds a list
   of functions).
   *Amended 2026-10-16 (issue #270):* a value of a type variable `a` may hold a `List a`. The filter took "`a`
   occurs below `List a`" to mean that no value of `a` holds one, which is false where `a` is a recursive type:
   with `type Tree = Node (List Tree) | Leaf`, a callback `List a → a` may answer `Node xs`, which holds `xs`,
   and `List.push xs t` put `xs` inside itself, accepted `param` (`ownership/RecursiveHolds`). "May hold"
   (`mayHold`) no longer takes that shortcut. "May be the same object" (`mayShare`) keeps it, which asserts
   more than "a value of `a` is not the `List a` it is an element of": that a value of `a` is never the same
   object as any value of a type in which `a` occurs below. That is false for an unboxed recursive type — with
   `type One = One (List One)`, one constructor with one field, `One xs` is the array `xs` — so the shortcut
   rests on another rule: a summary names the path `#One.0` where such a value holds its list, and the one
   way a program reaches such a value through a type variable with no summary, a call of a function the
   checker cannot identify, answers `⊤call` (§30.11). The probes of PR #280 found no accepted program with
   §30.11 in place.
5. **Supplies, cell by cell** (§16.4 item 4). A callee's supply passed on is probed one cell at a time (up
   to eight cells; a wider one is probed whole), so a cell the call made is not borrowed because another
   supplied beside it is. Inside a lambda, a capture of the declaration's own frame is named as that frame
   holds it — a parameter stays the parameter, not `⊤` — and is borrowed: the declaration may read it again
   while the lambda runs. A borrowed supply of the callee's parameter that holds no cell at a call hands
   nothing there (§16.4 item 5): `Http.send` hands its decoder the issues of an `Unprintable` body,
   borrowed, and a `stringBody` has none (`ownership/HttpSendBody`).
6. **The declaration's own function relied on** (§16.4 item 5). When a callee relies on what the function
   it is handed returns, and that function is the declaration's own parameter or slot, the declaration
   needs it to return owned: its callers are asked (`need`), not the walk here (`ownership/SlotInLambda`).
7. **A lambda's own parameter relied on.** When it is the enclosing lambda's own parameter, at a path, the
   obligation waits for where the lambda is handed on or called. There the function is known: what the
   callee supplies the lambda's parameter, or the call's argument, at the path. It is decided then: it
   returns owned, it is the declaration's own (rule 6), or it is a further enclosing lambda's, which
   waits again. Every place the lambda is consumed must decide it. One that cannot — a runtime's entry, a
   callee with no summary, a place out of sight — leaves it undecided, and so does a lambda never handed
   on or called; an undecided obligation is a `need` rejection, approximate. A lambda with one is not
   carried (§24.9) (`ownership/LambdaParamNeed`).
8. **Carried lambdas call what the caller passed** (§24.9). A carried lambda's calls of the declaration's
   slots, and its passes of a parameter or slot on to a callee, go to what the caller passed there. When
   that is a function value whose classes the walk knows, the call returns what they return, each handed
   `⊤`; returns-owned (§16.4 item 5) judges such a call by those cells: owned when each was made by it. A
   supply of part of a callback's result (`cb_j.q`) asks only the result's paths that overlap `q`. A
   lambda a callee's result carried into this body is carried on in this body's result, its bindings read
   off here and its class copied (it may be a block's). A top-level value carries its lambda when what it
   captured holds no cell (`ownership/RandomGenerate`).
9. **A top-level value that names a function is called as it.** `list = Pcg.list`: a call of `list` is a
   call of `Pcg.list`, through `Pcg.list`'s summary, when the arities agree and no `where` clause stands
   between them.
10. **The entry's taggers** (§30.3). The runtime calls `onUrlRequest` and `onUrlChange` with values that
    cross and sends what they return, so the entry checks that each returns owned, as a send is checked
    where it is made (§23.6): a function the walk cannot place is rejected, approximately; one that
    returns a list it does not own, exactly (`ownership/EntryUrlTaggers`). `browser-tea`'s own
    `Tea.application` forwards the two inside its subscriptions' lambda, where rule 1 gives the
    declaration the obligation the entry now discharges.
11. **Labels** (§28.5). A `need` rejection of a function value is approximate exactly when it fails only
    through an approximate entry, `⊤`, what another callback returns, or a function the checker cannot
    place; the eight lines §30.2 found printed as exact now print approximate.

*Amended 2026-10-22 (issue #223):* a lambda's call of its own function
parameter has that parameter's result in its class, as a declaration's
function parameter does. The call keeps its argument provenances in the
class's supply rows, conservatively borrowed. At a consumer, the callee's
supplies identify that function; instantiating the class follows the supplied
function's result, or keeps the unidentified-call result when it cannot. An
owned-result obligation follows the same supplies and reaches a declaration's
function slot when one supplies it. This supplies no ownership permission to
a local write onto the still-symbolic result: that write retains the
conservative unknown verdict. A callback result is scoped to the frame whose
function parameter it names, never to a parameter with the same index in
another frame.

*Amended 2026-10-22 (issue #223):* recursive summary joins retain returned
read-only lambda classes. Compatible classes join all result, read, capture,
callback and ownership requirements; different arities or send/record-result
protocols stay alternatives. Fixpoint equality compares the contents of the
classes as well as their indices. Function slot numbers stay stable across
rounds: each walk begins with the declaration's previous slot table and
appends new keys. This replaces the earlier prohibition on slots and carried
classes in recursive groups.

An empty current approximation of a recursive member returning a function
is callable bottom at its solved arity, with no result or effect facts.
A function whose class cannot be carried is instead an unknown alternative
(`λ?`, class index `none`), including through a top-level value. It never
becomes callable bottom. Captured list cells retain their ordinary facts.
Other unidentified callees keep §30.11's conservative answer. Ownership
blocks advance to version 22 so old summaries cannot bypass the new facts.

The owner confirmed on 2026-10-22 that moving `RecursiveHolds`'s refusal
from `pushed`'s generic body to `run` and `runOne` is correct: the supplied
callbacks return `Node xs` and `One xs`, retaining the list that the callee
then pushes onto. Each call has real sharing and would make a cycle. No
safe whole program changes from accepted to rejected. Such a safe-program
regression remains a stop condition, with a reduced reproduction.

**Words** (§24.2, §24.4, §24.8, amended). A parameter of type `List` of a function written out takes a
function's words, which describe each element: the summary's function slot at the parameter's `[*]`
(`many aliased List (⊤ → a)`). Three new rows in §24.8:

| Declaration | Words | Why |
|---|---|---|
| `Task.timeout` | `borrowed Duration, once aliased (⊤ → a) → fresh Maybe a` | `startIn` runs the work once as a child of the call's own scope, and `within` closes that scope before the call returns; `valueOf` reads the child's outcome, which is what the work returned, and the `Just` around it is new. Nothing keeps the work or its value after the call |
| `Task.raceOk` | `many aliased List (⊤ → Result e a) → fresh Result (List e) a` | each thunk runs once as a child of the call's scope, closed before it returns; the answer is the winner's `Ok` payload or a new list of every `Err` |
| `Int32` | `crossing` | an `Int32` is a JavaScript number, `Math.imul`'s and the bit operations': it holds no list and no function |

They are pinned in `trusted-surface.txt` (`ownership/TaskWords`, `ownership/RandomGenerate`) and their bodies,
with `within`, `startIn` and `valueOf`, in `word-bodies.txt`.

**What O1 does not clear** (`bench/ownership-everywhere.mjs`, 2026-10-16: 3 of 835 programs; core and every
platform hold no rejected or pending line):

- `browser/tea/ApiItems` and `ApiLogin`: a `need` through `Schema.parse`, whose words say its answer is
  `unknown` (§24.8). The answer holds what the schema's mapping, injection and conversion functions return,
  and one function serves both directions — in the encoding direction it is handed the program's own value
  — so no word can say "returns what it is handed, owned, when decoding". A precise answer needs the
  decoding direction's functions told apart from the encoding direction's: a design question, issue #218.
- `run/RefModify`: `Ref.update` hands its callback the cell's value borrowed, `⊤`. That is not only a
  limit: a `Ref`'s value is shared state by design — any holder of the `Ref`, in any fiber, may have read
  it with `Ref.get` and still hold it — so editing it in place in the callback would change a value another
  reader holds. Lending it owned would need every `get`'s result tracked across the program. The owner
  decides whether the fixture copies in its callback, as `ListPersistence` does (issue #219).

  *Amended 2026-10-16 (the owner, issue #219):* real sharing, and the error is correct. `run/RefModify`'s
  callback pushes onto `List.copy ns`, and `check/bad/direct/RefUpdateShared` — a `snapshot` read with
  `Ref.get` before the `update` — pins the refusal. `Ref`'s API and words do not change.

A defect found on the way, not fixed here: a conservative call's result (§6.1) counts as made by the call,
so a function value with no class that returns a list somebody else holds is written in place, accepted
`assumed` (issue #216). *Fixed 2026-10-16 by §30.11.*

### 30.10 What a schema's run answers (the owner, 2026-10-16; issue #218)

*Amends §24.8 (`Schema.parse`, `parseWith`), §24.5's list of rows the checker asserts, §26.7 and §30.9's
"What O1 does not clear". Sections 1–30.9 keep their text.*

**The decision**, verbatim from the issue: "don't look for one ownership word for every schema. Schemas are
compiled and statically known (schema.md §6), so the compiler derives the ownership of each schema's
`parse`/`decode` result (and the encode direction) from its declaration, per direction: fresh where the value
is built from the input, borrowed or unknown only where a conversion returns something it captured, or the
program's own value in the encode direction. A genuinely runtime-built schema keeps the conservative word."

**Two slots.** A value of `Schema e a` has two analysis slots, `⟨decoded⟩` and `⟨encoded⟩`, in the sense of
Change 9 and as the markup type has `⟨render⟩` and `⟨events⟩` (§28, *markup slots*): paths of the analysis,
not fields of the JavaScript. A slot holds what a run in that direction may answer that the run did not build
from its input. Everything else the schema value holds — the functions of its conversions and what they
captured, its arguments — stays where §16's summaries put it, so a list a conversion captured is still held by
the schema for as long as the schema is, whatever the slots say. A slot can also hold the *input mark*: the
run may answer part of what it was handed. The mark is a `⊤` (printed `⊤input`) wherever a run does not read
it, so a mark that escapes its slot is as unknown as anything.

**What a run answers.** `Schema.parse`, `parseWith`, `decode`, `decodeWith`, `read` and `readWith` answer a
fresh value, which may hold anywhere what the schema's `⟨decoded⟩` slot holds; `encode`, `encodeWith`,
`write` and `writeWith` the same with `⟨encoded⟩`. Where the slot holds the input mark and the run was handed
a program's value (every run but `parse`, whose input is a string), the answer may hold any part of that
value; where it does not, the answer holds nothing of it. `print` and `printWith` keep their words (§24.8): a
string. These are rows the checker asserts (§24.5), keyed by `core/Schema`'s names, and `parse` and
`parseWith` lose their words. A run that is not seen as one — a runner handed on as a function value — keeps
its row with the mark unread, which is `⊤`.

**What fills the slots.** A slot is filled where the schema is made, by its maker:

| Maker | `⟨decoded⟩` | `⟨encoded⟩` |
|---|---|---|
| a primitive but `Schema.value` | nothing | nothing |
| `Schema.value` | the input mark | the input mark |
| `list s`, `nullable s`, `erased s` | `s`'s | `s`'s |
| `converted s c` | `s`'s and `c`'s | `s`'s and `c`'s |
| `conversion forward backward` | what `forward` may return that its call did not make and that is not its argument: what it captured, a top-level value, `⊤` for a function the walk cannot place; nothing when the target `a` holds no list | the same of `backward`, except that its argument is the program's value: what it returns of it is the input mark; nothing when the source `b` holds no list |
| `S.schema a₁ … aₙ`, a declaration's | the arguments' and the declaration's own (below) | the same |
| an interpreting builder (`record`, `tagged`, `recursive`, `flip`, `typeOnly`, `encodedOnly`: whatever calls `box`) | `⊤` | `⊤` |
| `derived ⊤`, `structural ⊤`, and `Json`'s runs | the codec its `where a.codec` evidence names at the call (below); `⊤` where the evidence is a parameter | the same |

`list`, `nullable`, `erased` and `converted` branch on their argument's engine at run time, and their
interpreting arm boxes a node: that arm runs only for an argument whose slots hold `⊤` already, so their slots
are their arguments' and nothing else. A schema from anywhere else — a `foreign`, a `Js` value, a call with no
summary — has `⊤` in both slots (a cell a callee with no summary made holds `⊤` at a slot; one a callee with a
summary made holds there only what that summary names).

**A declaration's own slots — the derivation.** The compiler holds the declaration's resolved plan
(`schema.md` §4), so the checker reads it, closed over every declaration and derived codec it names: each
`via` contributes its conversion value, each `value` primitive the input mark, and each `codec_value` (a type's
module's `codec`, `schema.md` §12.10) the slots its summary names. A `via`'s conversion is a top-level
expression the declaration evaluates once (`schema.md` §6, *The `via`s*): a reference to a top-level value
contributes the slots that value's summary names — a cell its definition made is that value's own, shared
(§16.3) — and any other expression `⊤`, in each direction whose end holds a list. A declaration's schema
parameters are the arguments of the member's call. `S.parse` and `S.parseWith` answer a fresh value holding
the declaration's `⟨decoded⟩` (the input mark dropped: the input is a string); `S.print` and `S.printWith` a
string, as `print`'s words say.

**Derived codecs.** `Json.decode`, `decodeWith`, `decodeValue` and `encodeValue`, and `Schema.derived` and
`structural`, are read at each call through the call's evidence (`schema.md` §12.10): a derived codec
definition's slots are derived as a declaration's, each of its slots' evidence adding its own; a type's
module's `codec` contributes what its summary names. An evidence parameter — the codec of a type variable —
is `⊤`. `Http.expectJson`, a value whose evidence is its own, keeps `⊤` in its lambda.

**Soundness.** A list the answer may hold arrives in one of four ways: the run built it from the input (fresh,
no other holder); a conversion's function returned it (its slot names it: what it captured, a top-level
value, `⊤`); a `Value` or a `backward` returned part of the run's input (the mark, which the run turns into
the input); or a default (`schema.md` §11), which is not built yet and must enter its direction's slot when it
is (§11.3's "a pure default may be evaluated once by the backend" is observable once lists are written in
place: a default that holds a list is a shared cell in the slot). Each maker puts every such cell in a slot or
writes `⊤`; a schema the checker cannot place is `⊤` in both. Forward conversions are handed what the run
built, so their argument is not a holder; backward conversions are handed the program's value, so theirs is.
That first half rests on every decoding worker building what it hands `forward` from fresh cells — arrays and
records it makes, or the array `JSON.parse` made (`schema.md` §6, *Lists are arrays*). A worker that reused a
list across runs (a cache, a hoisted constant) would break it silently, and must put that list in its slot.
The type filter drops a conversion whose end holds no list: such a conversion cannot answer one.

*Amended 2026-10-16 (issue #268):* "not a holder" is true of `forward`'s argument, not of where `forward` puts
it, and a list `forward` makes is new only until it is placed twice. A `forward` that returns one cell at two
places of its result — its argument, a part of it, or a list it makes: `λxs → Ok ( xs, xs )`, `{ all = xs,
first = xs }`, `( xs, [ xs ] )`, `λ_ → Ok (dup [ 1 ])`, `λxs → Ok (dup (List.copy xs))` — puts one list at two
positions of the answer, and a write at one changes the other. Its `⟨decoded⟩` slot then holds `⊤twice`, a `⊤`
that names its cause, so a write onto the answer is rejected `unknown`, approximately. For the argument, two
places are two result paths whose argument paths overlap where neither is the other's placement: `π1` at `.0`
and `π1[*]` at `.0[*]` are one placement; a part whose type holds no cell does not count (the `Int`s of a
`List Int`, also found in a reversed copy); a `⋆` that blurs the alignment counts as two places. For a list it
makes, two places are two result paths that name one fresh number (§16.3), unless the longer one, read in the
decoded type below the result's `Ok`, holds no cell: a recursive builder (`range n = … List.push (range (n -
1)) n`) numbers its `Int` elements as the list. The slot holds no position, so the
`⊤` reaches every list of the answer: a program that writes one position and drops the other, or that writes
another field of the same answer, is rejected too — the issue's "loses separation". A list's elements need no
change, because the elements of a run's answer may share one list already (§18.4). Fixture:
`ownership/SchemaConversionTwice` (CK-247).

**The corpus.** `browser/tea/ApiItems` and `ApiLogin` hold
no line under `--ownership-everywhere`: `Schema.list (Item.schema ⊤)` holds nothing in its slots. `ApiLogin`'s
`tests/pending/browser/direct/` twin is promoted; `ApiItems`' twin, four builds in one case (as `HttpJson`, #184),
is over the test budget (4 780M) and is deleted: the `browser-tea` page runs it. Fixtures:
`ownership/SchemaAnswers` (declared, composed and generic schemas, a conversion that builds, one that returns
a top-level list and one that returns a capture; `Json.decode` of a derived codec; the encode direction with a
`backward` that returns its argument), `check/bad/direct/SchemaConversionShared` (a conversion returning a
captured list, written: refused).

*Measured (2026-10-16):* `bench/ownership-everywhere.mjs`, with #219's `RefModify` copy, rejects 0 of 848
programs (§30.9's 3 of 840); core and every platform hold no rejected or pending line. The Lean bridge at the
CI bound (`node scripts/bridge.mjs --ci`): 1 341 programs, 959 translated, none confirmed unsafe — the rule is
§26.7's last row, outside what the bridge emits.

### 30.11 A call of a function the checker cannot identify answers `⊤` (2026-10-16)

*Amends §6.1 item 3, §15 decision 2, §16.5 and §28.5. Issues #216 and #269.*

**The hole.** §6.1 gave a callee with no summary the result `(ε, result(ι, ε))`, a cell *made by the call*,
on the ground that the worst pure function "makes its result". That is a claim about the callee, and for a
function the walk cannot identify nobody made it. A function read out of a `Dict`, out of a record field
the walk cannot follow, out of a list of functions, or handed to a callee whose actual has no class
(`unknownCb`) may return a list somebody else holds — a top-level value, a list a closure captured, the
model. §28.5 accepted a write onto it as `call (no summary)`, *assumed*, and §16.5's argument for that only
covers a function that **writes** what it is handed, not one that **returns** a list it does not own. So
on `browser-direct` the top-level `shared` below was pushed onto in place:

```elm
handlers : Dict Int (⊤ → List Int)
handlers = Dict.fromList [ ( 0, λ⊤ → shared ) ]

grow ⊤ =
    f = Dict.get handlers 0 ▷ Maybe.withDefault λ⊤ → []
    List.push (f ⊤) 3
```

**The rule.** The result of a call of a function the checker cannot identify holds, at `ε`, the cell
**`⊤call`**: unknown provenance, never owned, printed `⊤call` in a summary. Its `(⋆, c)` entries for the
arguments' cells stay as §6.1 writes them. The calls it covers are every §6.1 call but a markup
construction: a function value whose classes the walk does not know; a function value that may be one of
several classes the walk knows, which it does not join (issue #278; the line says "it came from a call of a
function value that may be one of several functions"); a method call that resolves to no declaration and is
not a record field (below); a type dispatch; a callee whose summary is unreadable. A top-level value with no
parameters called as a function is called as the function value it is, unless §30.9 rule 9 names the
function it is: the class its definition carries (§30.9 rule 8), so `mkBox = Box` called with a fresh list
is accepted and `named ⊤` with `named = λ⊤ → shared` is rejected `top-level`, exactly; `⊤call` when it
carries none. `ownership/UnknownCalleeForms` pins a type dispatch through a `where` method, two lambdas
merged, a dot call on a call's result and a top-level constructor alias. A callback whose actual has no class is instantiated the same way:
what it returns is `⊤call` (`unknownCb`). A summary carries `⊤call` to its callers like any `⊤`.

Consequences, each through rules that already exist:

- A write onto `⊤call` is rejected **`unknown`**, *approximately*: "it came from a call of a function the
  checker cannot identify, which may return a list something else holds". It is a limit, not proof of
  sharing (§28.5), and its message says how to make the program provable: call a function the checker can
  see, or copy with `List.copy`.
- A `need` resting on it — a tagger or callback whose result is sent or written — is not owned: rejected
  `need`, approximately (§30.9 rule 11). A borrowed supply of what a callback returned before
  (`List.foldl` handing back its accumulator) whose callback's result is `⊤call` is rejected `supply`, and
  approximately when it fails only through `⊤` or an approximate entry, as a `need` is.
- No acceptance rests on a callee with no summary any more except a markup construction, whose node is the
  one result §6.1's "made by the call" is true of. §28.5's `assumed` count is that.

**A record field called with a dot is the field's value called.** `r.load a`, where the receiver's type is a
record that lists a field `load` — closed, or extensible (`{ r | load : … }`) — and no declaration is the method, is a call of `r.load`'s value, exactly as
`(r.load) a` is: a slot of the declaration's parameter (§24.9, called inside a lambda by §30.9 rules 1–2), a
class the walk knows, or a function it cannot identify. Before, the dot form was a conservative call, which
the rule above would have turned into a rejection of every `api.search q` on a record of functions
(`DebouncedSearch`). The call reads `r.load`, not all of `r`, as `(r.load) a` does: a write onto `r.items`
before it is not a write of a list the call reads (`ownership/DotFieldCall`).

**Schema declarations** (issue #269). The rule has no exception for them:

- A constructor of a tagged schema (`Tree.Leaf { value = n }`, `schema_ctor_top` and `ext_schema_ctor`) is a
  constructor. Its application holds each argument at its payload's step, as §6's table gives for any
  constructor application (`ownership/SchemaCtorBlock`). Handed on as a value, its class is that row: its
  arguments at `C#i` (§6.2, `ctorClass`).
- A member of a schema declaration (`Tags.parse`, `schema_member_top` and `ext_schema_member`) called directly
  is applied §30.10's row (`schemaMemberRow`). Handed on as a value — to a callee, to a local, to
  `Result.andThen` — its class is the same row, at the arity its type gives (`memberValue`). A callee that calls
  it answers what that row names. That run is not seen as one, so a slot's input mark stays a `⊤`, as §30.10
  says of a runner handed on.

Before, the walk gave both §6.1's cell made by the call wherever it met them as a function value. So
`apply f s = f s` handed `Fixed.parse`, whose conversion answers the top-level `kept`, and
`case apply Fixed.parse input of Ok f → List.push f.text "x"` was accepted and pushed onto `kept`. Its line
said `call (no summary: S.apply)`: the cell named the call that handed the member on, a function with a
summary. Now that program is rejected `top-level`, exactly, as the direct call `Fixed.parse input` is
(CK-246, `ownership/SchemaMemberHanded`; across modules, `ownership/SchemaMemberExt`). No acceptance rests on a schema callee's cell made by the call, so
no `assumed` line names the wrong function.

**Measured** (`bench/ownership-everywhere.mjs`, 2026-10-16, 847 programs): no new rejection in the corpus,
the examples or the bench apps but `bench/corpus`'s `FormValidation`, six lines: `all` calls each validator
of a `List (Validator a)` inside a fold, and `validateSignUp` calls `(firstOf [ … ]) "email" form.email`, a
function a call returned. Every validator the program writes makes the list it returns, so this is the
checker's limit, not sharing: a function value carried through a list's elements or out of a call's result
has no class (§16.1). It is the correct loud error until classes travel with those values (issue #223).
Conduit, TodoMVC, Sternhalma and Bike Wars hold no rejected line.
*Measured again 2026-10-16, on §30.10 and with schema members as classes (issue #269):* 1 of 850 programs is
rejected, `bench/corpus` with the same six lines; core and every platform hold no rejected or pending line.
Conduit, TodoMVC (all four), Sternhalma and Bike Wars check clean on `browser-direct`. Conduit's report changes
only in the fresh numbers of its summaries.

## 31. Records written in place (the owner, 2026-10-17; specified, not built)

*Amends §4.2, §4.4, §5, §7.1, §8.1–§8.3, §16.2, §16.3, §16.11, §18.2, §20.4–§20.6, §23.2, §23.6, §26.7,
§26.8 and §30.7 (O6). Sections 1–30 keep their numbers and their text, and each carries a dated note that points
here. Where this section changes a rule, it wins. It specifies; it builds nothing. Issue #315, part of #322 (O6)
under #317. The Lean oracle's part is #316.*

### 31.0 Decisions

*Revised 2026-10-17, the same day: the owner answered the four questions of this section's first version, and
changed the rule (§31.14). The answers stand here; the questions they answered are in this file's history.*

**Decided (the owner, 2026-10-17):**

1. **Liveness per field, and the lowering hoists** (§31.4 item 5, §31.14). A later read of a field that the write
   did not touch is accepted. So is a later read of a *written* field: the lowering reads it into a temporary
   before the write, which is Perceus-style reuse, where the compiler makes the old value dead by reading what it
   needs first and the author does not reorder. A later use of the record **whole** — stored, returned, sent,
   compared, captured whole, bound to another variable, the base of another update, or handed to a function whose
   summary reads a written field — is `record_still_used`, because no temporary can stand in for the object. Its
   fix is `Record.copy`.
2. **`Record.copy`, spelled `{ Record.copy r | f = … }`**, with a call allowed as an update's base (§31.15). The
   `record_still_used` error names it as the fix.
3. **No exemption for `core/` or the platforms.** `Schema.defaultOptions` becomes a function, as `init` did for
   lists (§22.2), and `core/Schema`'s engine makes fresh child contexts. §31.16 lists every core and platform
   site.
4. **Enforce, and rewrite only what the rule still refuses.** `run/Records` and `run/ListPersistence` keep their
   versions with `Record.copy`, Bike Wars stops updating a top-level constant, and nothing is retired. The report
   mode records each rejection's **fix class** — `hoisted` (accepted by the lowering's reads), `copy` or
   `restructure` — so that the cost of the departure from value semantics is a number (§31.12).
5. **A closure that captures a field path reads the field when it is made** (§31.6). This is the hoisting rule for
   closures, and the only sound lowering beside a refusal: a closure that held the record would see later writes.
   The report mode's count decides only whether an eager read is ever a cost worth a refusal instead.

6. **Calls are read through the callee's summary** (the owner, 2026-10-17). A record handed to a function is
   used at the paths the callee's summary reads (§16.4 item 1): a callee that reads only untouched fields is no use
   of a written one, and one that reads a written field reads it in its own body, where no temporary of the caller
   can stand in, so the update is refused. **The owner's condition:** a callee whose summary is capped or
   conservative reads the record **whole**, and the update is refused, with the cause named in the error. §31.4
   item 5 states the condition and its causes.
7. **Aliases** (the owner, 2026-10-17). A local bound to the record **before** the update is a holder whose later
   field reads are hoisted, as the base's are. A binding of the record made **after** the update, a container that
   holds it, a whole capture, and a call result that may be it are whole uses (§31.14, soundness step 4).
8. **`Record` is a prelude module, for qualified use only** (the owner, 2026-10-17), as `List`, `Debug` and the
   others are (`language.md` §6.2). It exposes no unqualified name, so it takes no name from a program, and the
   fix an error offers needs no import.

No decision of this section is open.

### 31.1 The decision

The owner, 2026-10-17, on #315 and #317: **a record update that the checker cannot prove safe in place is a
compile error, exactly as a shared list edit is. It is never a spread, never a silent copy, never a warning and
never an opt-in mode. The checker, in-place lists and in-place records are the base language, on every
platform, not a platform feature.** The program copies explicitly where it must keep the old value, with
`Record.copy` (§31.15). *Revised the same day (§31.14):* **the checker reads liveness per field, and the
lowering hoists.** A later read of a written field is not a reason to refuse: the lowering reads it first.

So:

- **Every `{ r | f = v }` consumes `r`**, on every platform, in every module: application code, `core/`, the
  platforms and the test platforms, and not only on a model's paths. Where it builds, it is lowered as an
  assignment into `r`'s object (§31.10).
- **There is no per-platform promise.** Every runtime drops its identity skips on records, as O3 drops them for
  lists (§30.7, `backend.md` §15.5). `browser` and `browser-tea` matter little: the target is `browser-inline`
  (#296). Their cost is recorded, and it is not a bar (§31.11).
- **No limits** (the owner, 2026-10-16 and 2026-10-17: "I don't want limits, we must design a checker that works
  with any program"). No rule in this section introduces a cut, a cap or a coarse approximation. Where an
  existing cut touches records (§31.12) it is named with its issue, and it is a precondition, not something
  designed around.
- **No Lean work in this issue.** Nothing under `proofs/` changes. §26.7's row is rewritten, and #316
  models the rules later.

### 31.2 Cells: a record is one

§26.8 question 2 recorded that "the domain gives a record no cell of its own". That held because nothing wrote a
record. The code today:

- a record literal's abstract value is its fields' entries, shifted by their steps, and nothing at ε
  (`src/own/Ownership.zig:5886`–`5898`);
- a record update's result is the base's entries without those under the updated fields, plus the new values
  (`evalRecordUpdate`, `src/own/Ownership.zig:6245`–`6293`). A symbolic entry of the base is split into one
  entry per other field of a closed record type (`:6262`–`:6283`), so the result holds nothing at ε either;
- a record type whose fields all cross crosses, and carries no entries (`tracked`, `:3318`–`:3341`; §4.4).

**From this section, a record value is an object, and it is a cell.**

- **`site(ι)`** (§4.2) is also the object that a record literal at ι makes. A record-alias constructor's
  application (`backend.md` §4: it *is* the record literal) is a record literal.
- **A record's cell is the object only.** A symbolic cell stands for everything under it (§4.3): `param(x, q)`
  projected at `.g` is `param(x, q.g)`. That stays. An entry may also carry an **exception set** of fields,
  `(ε, c ∖ F)`: the object at ε is `c`, and projecting `.g` from it gives `c.g` only for `g ∉ F`. The set is the
  updated fields of the update that made the entry (§31.3), so it comes from the source and is as large as the
  update, with no cap.
- **Crossing (§4.4) is amended.** A record type never crosses, even if every field does: the object is written
  in place, so a value of the type carries its cell. A tuple whose components cross still crosses, because a
  tuple is never written in place. A nominal type crosses only if its definition reaches no record, as well as
  no `List`, no function and no `foreign type` but the primitives. `Int32`, `String`, `Bool` and the other
  primitives still cross. More values are tracked as a result, and the cost is measured, not capped (§31.12).

*As built (2026-10-18, slice R2a of #315):* the cells, with the record demand still to come (R2b), so no list
verdict moves. In `src/own/Ownership.zig`:

- **`site(ι)`.** A record literal's value has its object at ε, a site cell that projects nothing; its fields
  are entries of their own, as before. A field whose type crosses holds no entry, whatever its value's
  abstract value says (a `Js.to` answers `⊤` at any type), and a read of a local at a type filters out a
  `⊤` at a crossing path (`typeFilter`) — both invisible while the record around them crossed.
- **`c ∖ F`** is a cell kind, `except`: the record cell `c` and an interned, sorted field set, or every
  field. Its projection at a field of `F` is nothing, at any other field `c`'s; two updates in turn make one
  cell over the first base with the union of the sets. An update's result is `except(c, F)` for each record
  cell `c` at ε of the base. For a closed type the other fields are still split out, and the object is
  `except(c, all)`. For an open type the exception set replaces the whole base entry the result kept before,
  so `{ r | items = [] }`'s `items` no longer holds `r.items`. This is the one place list precision moves:
  `ownership/RecordCells`'s `open` is accepted where the whole base made it `alias`. No other program of the
  corpus changes.
- **Crossing.** `tracked` treats every record as holding a cell, and a nominal type that reaches a record
  (`NominalFacts.record`) as not crossing. The old rule stays as `listTracked`.
- **What lists read.** A cell is `nonlist` when it is a record literal's object, an `except` cell, or a
  cell whose value, by its type, holds records and nothing a list's facts read (a record of numbers, a
  `List Point`'s element, a constructor's record payload): tracked by §31.2's rule and crossing by the old
  one. The type is read at the cell's own path, from the type it was made with or the nearest cell above
  it made with one, through fields, tuples, list elements and constructors' fields as their declarations
  write them, so a record object is filtered at ε and below alike; a type the cell's key does not decide
  (a top-level value's, read at each use's own type) is never read, and the cell stays a list's. A list's
  facts read cells through `listFacing`, which drops `nonlist` cells and reads an `except` cell with fields
  as the cell it was written over: demands' cells, a summary's uses, writes, escapes, results and supplies,
  a carried lambda's bindings, condition atoms (`mkCond`), a tagger's `need`, and a closure's use of a
  capture of a record object. An escape of an `except` cell with fields is also one of the cell it was
  written over. A field split out of a closed update reaches a summary only when its type is
  `listTracked`. The switches over cell kinds on these paths name every kind, so a new kind is a compile
  error rather than a default. So summaries move only where they named record objects: a read of a record
  field below a tracked root through a closure's capture is gone with the capture's object, and a list of
  records no longer names its elements' objects (`HostValueOnePlace`'s `π2.items[*] A`, Conduit's comments);
  Conduit gains the callback results its record fields hold.

- **Deferred to R2b and R2c**, with the record demand and `W{F}`: the record literal's stored-construction
  condition on its object (§31.4 item 6); record cells in summaries, which need the result's
  object-only provenance; and `Record.copy`'s fresh object at ε (§31.15), whose row stays "the copy holds
  what π₁ holds".

### 31.3 The demand

**A record update `{ r | f₁ = v₁, …, fₙ = vₙ }` is a demand** (§3) of a new kind, `update`. Its **base** is `r`:
the name as written (`language.md` §6.3), a top-level value, a call (`{ Record.copy r | … }`, §31.15), or the
expression of a markup spread (`language.md` §11.8). A call's result is a temporary: the demand's cells are what
the call answers, `site(ι)` for `Record.copy`, which nothing else holds. Its **written fields** are `F = {f₁ … fₙ}`, and its point comes after every vᵢ (§31.10's
order). Its base cells are `C = A(r)@ε`, the record objects that `r` may be, together with every `⋆` entry whose
cell's type may be `r`'s.

**Transfer** (§5's `{ r | f = y }` row, replaced):

| Form | `A(e)` | Uses recorded (§7.1) |
|---|---|---|
| record literal `{ g₁ = w₁, … }` at ι | `(ε, site(ι))` ∪ each `A(wᵢ)` shifted by `.gᵢ` | each field, at ι |
| `{ r \| f = y }` | `(ε, c ∖ F)` for each `c ∈ C` (the same object, written), `A(r)`'s entries under the fields not in `F` (a symbolic one split per field of a closed type, as now), and `A(y)` shifted by `.f` | `r` at every path but those under `F`, at the update; each `vᵢ` |

So the result of an update **is its base's object**: `s = { r | a = 1 }` makes `s` and `r` two holders of one
cell, and `s` is the version after the write. This is what lets an update be judged like a writer, whose result
is its input (§27.4, *the writers' rows*).

**Nested updates are two demands.** `{ model | form = { form | name = n } }`, with `form = model.form`, demands
the cell at `model.form` (written field `name`) and then the model's (written field `form`). The inner demand's
holders are `form` and `model`, which holds the cell at `.form`. The outer update's base use reads `model` at
every path but `.form` (§7.1), so it does not reach the inner write. This is the mechanism that accepts thesis
I5 for lists (`ownership/RecordField`, §11): a pending base that is a variable path is never a pending holder
(`src/own/Ownership.zig:10617`), and its use excludes the fields it replaces (`useOperand`'s `except`,
`:5271`). The lowering of the outer one assigns `model.form = form`, which is the object it already held. The
lowering may drop that store, and nothing else changes.

### 31.4 The conditions

At an `update` demand, each `c ∈ C` must satisfy, in §8.1's order:

1. **Known**: `c ≠ ⊤`. A record from JavaScript, from a `foreign` with no `fresh` word, from `⊤call`
   (§30.11) or from a schema slot that holds `⊤` (§30.10) is `unknown`, approximately.
2. **Unescaped**: `c` is not a top-level value's (`top-level`, position), and it has not joined Esc before the
   demand (`escaped`, approximate). What escapes is the record **whole**: handed to JavaScript, kept by a
   `foreign` without words, or captured whole (`λ⊤ → model`) by a closure that a command, a subscription or a
   view handler keeps. A closure that reads only a field path, `λs → … model.label …`, reads the field when it is
   made (§31.6), so it keeps the field's value and not the record, and the record does not escape through it.
   *Revised the same day (§31.14):* the first version qualified Esc by read path; the eager read makes that
   unnecessary, and nothing is lost: the closure no longer reads the record at all.
3. **Disjoint, deep**: no new field value `vᵢ`, closures expanded, holds `c` whole. That would make the record
   contain itself, which no value semantics can produce. A field value that reads a field of the base is
   evaluated before any store (§31.10), and a closure among the new values that captures a field path reads it
   when it is made (§31.6): `{ r | f = λ⊤ → r.f }` answers the old `f`, as value semantics does, and is accepted.
   *Revised the same day (§31.14):* the first version refused it.
4. **Captured** is not a condition of its own. A write of a captured record inside a lambda makes the lambda
   **once** (§18.8): its creation is a demand on the capture, at the written fields, and each call of it a
   demand on the closure. `captured-edit` stays for a capture the walk cannot place in a closure.
   *Specified 2026-10-19 (R2d of #315).* The captures a lambda's body writes (`env_writes`) include its record
   writes, each with the fields it writes, so the lambda is once by a record write as by a list's. Its creation
   is a record demand on the capture, in the enclosing body, at the written fields: Known, Unescaped and
   Disjoint as at any update, and Dead per field (item 5) with one difference — a read of a written field
   after the creation is a whole use, not a hoist, because the write happens at a call of the closure, which
   the lowering cannot place before the read; a read of an untouched field stays untouched. Each call of the
   closure is §18.8's demand on its own cell, and handing it to a callee is accepted where the callee calls it
   at most once (`seen`, `calls ≤1`); `Maybe.map (handleInput model _)` is such a call. The write inside the
   lambda is then accepted `once`, or rejected with the creation demand's cause, or `once`.
5. **Dead, per field** (*revised the same day*, §31.14): no pending operand holds `c` (`held-operand`), and no
   local holder of `c` is used **whole** after the demand, in a compatible branch (§7.2). A holder `h` that holds
   `c` at path `q` and is used after the demand at `u`:
   - `u` extends `q` by a field `g ∉ F`: an untouched field, unchanged by the write. Accepted, nothing to do;
   - `u` extends `q` by a field `f ∈ F`: a written field. Accepted, and the read becomes a **hoist** of the
     demand: the lowering reads `c.f` into a temporary before the write and the later read reads the temporary
     (§31.14). A pattern that destructures the record reads its fields the same way;
   - `u` is a prefix of `q`, the record or a container of it used whole: `later-use` or `alias`, exact. That is
     a store of it into a structure, its return, a send, `==` at ε, its binding to another variable, a whole
     capture, and its use as the base of another update (which reads every field but its own, §7.1);
   - `u` is an argument of a call: the call reads it at the paths the callee's summary reads (§16.4 item 1). A
     read there of an untouched field is accepted; a read there of a written field, or a whole use, a keep or an
     escape, is a whole use for the caller, since the read is in the callee's body (§31.0 item 6).
     **A callee whose summary is capped or conservative reads the record whole** (the owner's condition, §31.0
     item 6), and the update is refused. That is the case for:
     - a callee with no summary: an unknown function value, a callee the walk cannot identify (§30.11), a
       `foreign` without words (§24.5), a `Js` operation. The cause is `call` or `unknown`, and the detail names
       the callee and says that the checker cannot see which fields it reads;
     - a summary that reads the argument at `⊤` or at `⋆` (§6.1, §16.2), so that no field set can be read off it.
       The cause is `call`, and the detail says the callee may read any field;
     - a function-valued argument that the summary cannot follow (`seen` false, §16.2), when the record reaches
       it: what the function reads is not known. The cause is `supply`, and the detail names the function value;
     - a pessimistic summary, past one of §16.7's limits. The cause is `limit`, and the detail names the limit,
       as §16.7 does.

     A callee in a recursive group is read through the group's settled summary. §16.6 starts a group from the
     bottom summary and judges no demand until the validation round, so no verdict rests on a summary still at
     the fixpoint's start. A group that does not settle is past the `rounds` limit, and so falls under the last
     case. Each of these lines is approximate, `record_may_be_shared` (§31.9): a limit of the checker, which
     the message names, never a silent acceptance.

   So after `s = { r | a = 1 }`, reads of `r.a` and `r.b` are accepted, the first hoisted, and `( s, r )` is
   `later-use`. A local bound to a value inside the record, `x = r.a`, holds that value, not `r`'s object, and is
   no holder of `c`. `next = { model | count = n }` followed, in a compatible arm, by `{ model | heard = … }` is
   `later-use`: the second update's result is the object the first wrote (`browser/tea/TypedKeys`, §31.13).
6. **Exclusive contents** (§18.2, §18.4) when the record is an element. A callback that writes the record it is
   handed by a destructive read (`List.map rows (λr → { r | done = True })`, `List.update`, `Dict.update`) relies
   on its container's exclusivity: no record object at two positions. Since a record has a cell, `[ r, r ]` now
   fails exactly, and a list of records built by `List.repeat n r` fails as `[ cell, cell ]` does (T59).
   *Specified 2026-10-19 (R2e of #315; proposed the same day, the parallel domain chosen by the owner).* A
   list's conditions (§18.2) read no record object: `mkCond` drops an atom over one (§31.2). Records get a
   condition of their own, beside a list's, in the same lattice and with the same operations, kept in a
   second table so that no list's condition, cap or verdict reads it:
   - **Atoms.** `rexcl c`: no record object is reachable from two positions of `c`, nor at two paths of one
     position; `rsep c d`: `c` and `d` share no record object. As a list's, they name arrivals only —
     parameters, captures, callback results — never a cell the body makes.
   - **A cell's record condition** starts by its kind, as `cellCond` does: an arrival is `rexcl` of itself; a
     site holds; a call's result is its summary entry's record condition, instantiated; ⊤, a payload, a
     result no summary made fail approximately; a taken element is its container's.
   - **A value's deep record condition** is the conjunction of its cells' record conditions and of `rsep`
     between its record objects at every two paths neither of which is a prefix of the other. It is built
     without pairing every two cells: one object at two such paths is the same cell twice, which a sort finds
     (it fails exactly); an atom is needed only between two distinct arrivals. So it has **no cap** (the
     owner forbids one): its size is bounded by the program, and a value of many fresh records costs a sort.
   - **Where it is computed**: where §18.2 computes a list's — a literal `[ v₁, …, vₙ ]` is every item's deep
     record condition and `rsep` between every two items (`[ r, r ]` fails exactly); a construction is the
     base's lowered by what it stores, a later spread of a variable failing approximately; a call through a
     summary is its `res` or `objs` entry's record condition, instantiated; a conservative call fails
     approximately.
   - **Where it is relied on** (§18.4): where a callback writes a record a destructive read hands it, as
     item 6's opening says, and on a callee's `rxreq`. Relying on one that fails is a rejection, cause
     `exclusive`, exact when it failed exactly; relying on one that holds records its atoms as `rxreq` of the
     frame's summary, which every caller discharges, as `xreq` is (§18.3).
   - **In a summary** (§18.3, format v18): each `res`, `objs` and supply entry carries its record condition
     `rxc` beside `xc`, and the summary its `rxreq`. A row core asserts states its record conditions by the
     same reasoning as its list ones, about where each element comes from: its `rxc` is the twin of its `xc`
     (`excl` → `rexcl`, `sep` → `rsep`, `keep` → a record keep, the callback putting back the record it
     was handed or one it made; a spine has none).
   A list's verdicts read none of it, so none moves, and the 57 pending `List.map rows λr → { r | … }` lines
   are decided.

   *As built (2026-10-19, R2e of #315).* As specified, with three things the specification left open.
   - **Only a place that may hold a record is one.** A record condition reads the cells whose type may be
     or hold a record (`holdsRecord`): a record, a type variable, and anything the checker cannot see into
     — a `foreign type` such as `Js.Value` or a program, a declaration that holds a list, a function or a
     foreign type — may. Two records that share a `List Int` share no record, and `{ a = xs, b = xs }`
     stored once holds. *Revised the same day (#421's review):* the first build took a `foreign type` to
     hold no record, so core's lists, built on `Js.Value`, and the model at the entry (whose cells have
     the program's type) stated record conditions that held outright, and lists holding a record twice
     were accepted (`ownership/RecordContentsBuilt`, `RecordContentsCore`, `RecordContentsReturned`).
   - **The model at the entry** keeps its record condition as an invariant, as it keeps a list's (§20.4):
     its cells, and the record cells `update` wrote objects over, start holding, the rounds lower them by
     what `update` stores, and `update`'s `rxreq` is discharged on its record lines
     (`ownership/RecordContentsEntry`, `RecordContentsTwice`).
   - **A caller's failed `rxreq`** is reported on the record demand the call makes of that argument, or on
     a record line of its own, cause `exclusive`.
   - **No list verdict reads a record condition**, and `zig build test-records-lost` shows it mechanically:
     every corpus program is checked again with every record condition failing (`--ownership-records-lost`,
     hidden and test-only), and its list lines must be the same, byte for byte. The one place the two
     tables met, the entry's rounds (§20.4), now settles them apart: a record table that does not settle
     is lowered to the limit alone, and only a list table that does not settle makes the declaration an
     error. The record table does settle: a record condition only gains atoms, over the walk's cells, which
     a round makes no more of once the list table has settled.
   - **A `keep`** (`rkeepShape`) rests on what the callee hands its callback being taken (`rtakenSupply`
     refuses a supply that is not), which is #419's surface too: until #419's fix, a split element pushed
     back onto its own list is accepted for records as for lists (CK-264, `tests/pending`).
   - **A `foreign`'s `exclusive` word** speaks of its list's lists, so the record twin of a words row's
     made result fails approximately unless it is the row's argument.
   A summary line prints a record condition after the list one, `r{…}`, nothing when it holds outright.
   Over the 1 092 programs of the comparison, no list line moves against master, and the 64 pending item 6
   lines are all decided: each callback now relies on its list's records, as `rxreq` of its declaration.
   The record lines go from 2 861 accepted, 70 pending and 95 rejected to 2 859, 6 and 156. The 63
   `exclusive` lines, all approximate, are where those `rxreq`s are discharged on a list whose record
   condition fails: `Schema`'s decoders and printers (13: their issues are a `foreign`'s, `{lost}` as a
   list's are), and 48 at the entry of TodoMVC-, Bike Wars- and keyed-row-shaped programs, whose `update`
   passes its rows through a core row that loses the condition as it loses a list's (`List.append`,
   `List.filter`, `swapAt`, …; #420), or stores a row the model already holds (KeyedEnds' `CopyLast`), and
   2 in KeyedEnds' callbacks over `swapAt`'s answer.
   Master accepted those without asking. The record domain costs core's whole walk about 100 million
   instructions; a cheaper hash for the checker's memos pays for it, and the two tests that walk core count
   4 203 and 4 218 million.

   *Compared (2026-10-19); the owner chose the parallel domain.* The alternative is one lattice whose atoms carry a domain:
   `excl`/`sep` over list cells and over record objects in one condition, `mkCond` tagging a record atom
   instead of dropping it, a list's demand reading the list atoms, a record's reading both.
   - *Soundness.* A list's demand may ignore a record atom: two positions that share a record object but no
     list are written apart by a list write, which touches no record object. So both designs are sound for
     lists. But a condition *fails* whole (exactly or approximately), and `[ r, r ]` fails on its record atom;
     one lattice therefore needs a failure per domain too, or a list's reliance on that container fails where
     it holds today. With the failure tagged, the one lattice is two conditions sharing their holding atoms.
   - *Lines and sites.* One lattice touches §18.2–§18.4's sites once, but every operation on a condition —
     its meet, `xsumOf`, instantiation, `rely`, `xreq` — learns the domain, in code every list verdict runs
     through. The parallel domain leaves that code as it is and adds a record twin at each site: more lines,
     none of them on a list's path.
   - *Summary format.* One lattice: a domain bit on an atom and a failure per domain, in the fields a summary
     has (smaller). Parallel: `rxc` beside `xc` on `res`, `objs` and supply entries, and `rxreq` (larger).
     Either is v18.
   - *Risk to list verdicts.* One lattice: real. A record atom joins a list's conditions, counts toward
     `condition_cap` (§16.7) and so can move a list summary to a limit, and a mistake in the domain filter
     moves list lines. Parallel: none by construction; a list's conditions never see a record atom, and the
     comparison over the corpus has nothing to show.
   - *Cost per walk.* About equal: one table of larger conditions, or two tables. Record conditions are few
     outside programs with lists of records.

   **Recommended: the parallel domain.** Both are sound, and the one lattice is smaller in the summary, but
   it puts records into the code and the caps every list verdict depends on. The parallel domain keeps the
   list analysis untouched, which is what every record slice so far has held to (no list line moves).

The verdicts are §8.2's (`fresh`, `call`, `param`, `callback-param`, `once`, `entry`), and the causes are §8.3's
and their later additions. No cause is new: a record demand is rejected for the reasons a list demand is.

### 31.5 Records in lists and in constructors

- **A record inside a list** (`model.rows[*]`) is written through a callback handed it by `traverseAt`'s loops or
  a focus (§18.5, §20.8). The supply must be owned and **taken**, and the container exclusive (§31.4 item 6). The
  container's later reads count as holders, as they do for lists: after `List.map model.rows (λr → { r | … })`, a
  read of `model.rows` (the old list, whose elements were written) is `later-use`, while a read of the map's
  result is the new version. A record pattern element (`[ item, …rest ]`) is a split (§18.4 item 4): `item` is
  taken from the scrutinee, so `rest` does not hold it, and writing `item` relies on the scrutinee being
  exclusive.
- **A record inside a constructor** (`Article page`, `Just form`) is held at the constructor's step `#C.i`.
  `case model.page of Article page → Article { page | errors = … }` demands the cell at `model.page#Article.0`.
  The constructor is rebuilt as written, and a constructor is never written in place. The 64-field encoding of a
  constructor step (§16.7's table, issue #289) applies to these paths as it does to lists.
- **Two positions, one record.** `[ { item | doc = left }, { item | doc = right }, …rest ]`
  (`bench/corpus/PrettyPrinter.beni:125`) writes `item` twice while the first result waits in the list: the
  second demand is `held-operand`, exact. In place, both items would be one object holding `right`.

### 31.6 Closures, messages and commands

- **A closure that captures a field path reads it when the closure is made** (*revised the same day*, §31.0
  item 5). A capture of `x` at a path `q` that reaches into a record — `model.label` — is lowered as a read of
  `x.q` at the closure's creation, bound to a temporary the closure captures. The closure then holds the field's
  value, not the record, and no later write of the record changes what it sees: value semantics, since the
  closure of value semantics captured the old record, whose `label` never changes. It is the only sound lowering
  beside a refusal; a closure that held the record would see later writes. The read is pure and cannot fail
  (`language.md` §11.11), so making it earlier is unobservable. A capture of a record **whole** (`x` itself, used
  whole in the body) holds the object, and is a whole use wherever the closure is consumed (§31.4 item 5).
  Report mode counts the eager reads (§31.12).
- **A send gives up every cell its payload holds** (§23.2, `bit_d`). Record objects are among those cells now, so
  `send (Saved model.form)` from a body whose arm keeps `model` is `later-use` at the send, as a list is.
- **A command, a subscription or a view handler that keeps a closure** escapes what the closure holds (§31.4
  item 2). `Cmd.perform λsend → … model.query …` holds the value of `model.query` read when it was made, so a later
  dispatch's write of `model.query` is accepted. One that captures `model` whole escapes the model record, and a
  later write of it is `escaped`.
- **View events** (§23.6). A view event's payload is borrowed, and a record in it is no exception:
  `onClick={Edit todo}` hands `update` a record that the model and the render's handlers still hold. An arm that
  writes it, `Edit t → { model | todos = … { t | … } … }`, is `payload`, approximate. The program writes the
  model's own record instead, found by its key (`Dict.update`, `plans/direct-rewrite.md` §9's D2), or copies the
  payload.

### 31.7 Parameters, summaries and the interface

- **W carries its written fields.** A demand whose cells include `param(πᵢ, q)` adds `W` to `(i, q)` with the
  written field set: `(i, q, W{f, g})`, printed `π2.form W{name}` in a summary line (§16.11). A list demand's W has
  no field set and means "the array is written", as before. A record W without its fields would make every later
  read of the caller's argument a conflict. That is a coarsening, and §31.1 refuses it.
- **The caller's side** (§16.4 item 3): a call-site demand on `aᵢ`'s cells at `q`, checked by §31.4 with
  `F = {f, g}`: Disjoint against the other arguments and against `aᵢ`'s other paths, and Dead per field (§31.4 item 5).
  It reaches the caller's own summary when the cell is its parameter. So `shift dx p = { p | x = p.x + dx }`
  writes `π2 W{x}`. In `run/Records`, `shift 3 origin` followed by `origin.x` would be hoisted at the caller, but
  the next `(shift 3 origin).x` hands `origin` whole to a callee that reads its written `x`, which is a whole use:
  rejected at the call, fixed with `shift 3 (Record.copy origin)` (`tests/corpus/run/Records.beni:18`–`:30`).
  A caller's later reads of a written field of its argument are hoisted before the call, as after an update.
- **Hoists across a call are the caller's.** A read inside the callee's body of what it wrote is the callee's
  own (§31.14 applies there). A read of a written field by the caller after the call is the caller's hoist, placed
  before the call.
- **Function values** (§16.5, §30.4): a lambda that writes its record parameter is a writing class like any
  other: checked where its calls are in sight and `pending` where it leaves sight. `{ handler = λr → { r | … } }`
  stored in a record is pending, and so an error.
- **The summary block** (§28.4) gains the field set of each W, and the cache entry the hoist table (§31.10). Its version
  moves when the rule lands. The interface firewall needs nothing new: a summary change is an interface change
  (§16.10, O2).

### 31.8 The model at entry

§20.4–§20.6 apply to records with §31.4's conditions:

- **`init`'s records are fresh** when `init` builds them. A top-level record returned by `init`
  (`init = λ⊤ → initialModel`) is shared, so the first write of the model is `top-level`, as T53 is for lists. The
  same holds for an arm that starts again from a top-level record, `{ initModel | status = Running }`
  (`examples/bike-wars/src/Game.beni:148`).
- **For each path `q` where `update` writes its model's record** (`W{F}` on `π2.q`), the entry line is checked as
  a call-site demand: Known, Unescaped at the written fields (commands, subscriptions and view handlers that keep
  closures reading them, §31.6), Disjoint against the message and against the model's other paths (one record at
  two model paths fails exclusive contents), and Dead, which holds on the direct row because nothing holds the
  model after the call (P1). It is accepted `entry`.
- **`view` and `subscriptions`** writing a record they are handed, including a row's item, are `read-only`,
  exact.
- **The model's exclusivity invariant** (§28's dated amendment) covers record cells as it covers list cells. An
  arm that stores one record at two model paths refutes it.

*As built (2026-10-19, slice R2c of #315), §31.7 and this section.* A summary carries a record's facts in
bits no list's fact reads: `bit_f`, the write, with its field set (`W{f, g}`; `W{}` read back from a block
that cannot say which); `bit_q`, a read of a record's field, printed `R`; and `bit_k`, the escape of a
record's object, printed `E`. What the result holds of records — a record's object alone (`◦`), or a record of
numbers whole — is `objs`, kept apart from `res`, so that no list's fact sees it; instantiated, its cells are
copies that no list's fact reads and that escape with the cells they copy. A call applies the callee's `bit_f`
as a call-site `update` demand on the argument's objects at the path, with the fields written (§16.4 item 3);
the callee's own reads at the call are its body's, not a later use. A parameter's write is `accepted param`
in the body and decided at each call; a call's answer is `call`, decided by the callee's `objs`. At the entry,
each path `update` writes is an `update entry …` line: its object escapes where a command, a subscription or
`update` keeps it (only the object, so that no list below it moves), and a message's record a view event
builds is `payload` (the view's record objects reach the record lines only). A callback's write of a record
its callee supplies needs the supply owned (`supply`), and a closure that writes only a record is decided by
its consumers, `pending` where it leaves sight, as a list's write is. `{ Record.copy r | … }` gives the copy a
new object, its fields split from `r`'s when the record type is closed. A base no provenance names is
`pending`. A callback's write of a record a destructive read hands it (`List.map rows λr → { r | … }`) writes
the callee's parameter's elements, and so the caller's argument, at the call (`π1[*] W{F}`); it relies on the
list holding no record at two positions (§31.4 item 6), which a list's conditions cannot say (they read no
record object), so the callback's line is `pending` until that is built. Over the 1 071 programs of the
comparison (master after #393), 276 have record updates: 2 832 demands (1 775 in bodies, 666 at calls, 391 at
entries), 2 577 accepted, 66 pending — 57 of them §31.4 item 6, 4 stored in a record, 3 returned, 1 out of
sight, 1 with no provenance — and 189 rejected, in 51 programs: 75 `top-level`, 36 `later-use`, 22 `payload`,
10 `captured-edit`, 9 `alias`, 9 `unknown`, 9 `escaped`, 7 `element`, 5 `call`, 3 `disjoint`, 2
`held-operand` and 2 `supply`; 12 lines with hoists and 296 eager reads. No list line moves against master.
CK-260 and CK-261 are green (`ownership/RecordPayload`, `RecordCapture`, `RecordCaptureField`). Left: a `For`
row callback's write of its item is `pending`, for a list and a record alike, so CK-262 stays red (#402);
records' exclusive contents (§31.4 item 6); a captured record's write making its closure once (§31.4 item 4,
the 10 `captured-edit` lines); a summary that reads an update's base whole, which refuses the TodoMVCs'
`changed model (List.map model.todos …)` (#405); and a base use under a marker (#404). The summary block is
version 17.

*Revised 2026-10-19 (R2d of #315, from its review).* A callee's `bit_k` is an escape at the call: the record
objects at the path escape, alone, after the callee's writes, so `twice d = keep 2 (keep 1 d)`, whose `keep`
writes its record and then hands it to JavaScript, refuses the second write (`escaped`). A callback's keep of
a record it is handed escapes that record's objects through the callee's supplies, list and record ones: a
`bit_k`, or a list's `E`, at the path it keeps, whole; a field kept keeps the field's objects and not the
record's (`ownership/core/RecordKeepJs`). And a callback's write of the answer an earlier call of it returned
(a fold's accumulator) reads two of that answer's objects: its own, at ε, and the one at the path the write
writes. Each must be the caller's — one it made, or one the callee supplied it owned — not kept at its own
path or above it, and at no other path of the answer. A record held below the one written is not written, so
what the host keeps of a driver's state (its fibers, its scope) does not refuse the state's update, while
`( r, List.push hist r )` refuses the next step's write of `r` (`ownership/RecordFoldBelow`).

### 31.9 The errors

Lines with the same position, verdict, cause and detail are one diagnostic (§28.5). The codes follow §28.6's
four, with the subject a record. They are appended to `language.md` §10's catalogue by the slice that builds them:

| Code | Title | Lines |
|---|---|---|
| `record_still_used` | `RECORD CHANGED WHILE STILL IN USE` | exact rejections |
| `top_level_record_changed` | `TOP-LEVEL RECORD CHANGED` | `top-level` |
| `view_changes_model` | `VIEW CHANGES THE MODEL` (shared with lists) | `read-only` |
| `record_may_be_shared` | `RECORD MAY BE SHARED` | approximate rejections and pending lines |

A message has §28.6's fixed shape. It names **what is shared** (the record and the holder that keeps it),
**where** (the update, the holder, and the later read as places, with carets), **what the program would see** (the
whole use sees the written fields' new values), and **what to write instead**: `{ Record.copy r | … }`
(§31.15), a restructuring where one exists, and for a top-level value a function that builds it. The verdict line
says whether this is sharing the checker can see or a limit of the checker (`plans/direct-rewrite.md` §9: a
language rule never says "not yet", and a compiler limit says so). For example (`tests/corpus/browser/tea/TypedKeys/Main.beni:65`–`:81`), where the second update's base is the
object the first one wrote:

```
-- RECORD CHANGED WHILE STILL IN USE ------------------------------ Main.beni:65:12

`{ model | count = n }` changes `model` itself, but `model` is used whole
afterwards, as the base of another update.

65|    next = { model | count = n }
              ^^^^^^^^^^^^^^^^^^^^^ the record is changed in place here
81|            ( { model | heard = model.heard ++ [ "${tagger} heard ${name}" ] }, Cmd.none )
                  ^^^^^ and `model` is used here, after the change

If the record were changed in place, this update would start from the changed
record, and carry its new `count`.

To change a copy and leave `model` as it was, copy it there:

65|    next = { Record.copy model | count = n }

Or, if only the `ByAlpha` … `ByPost` arms need `next`, compute it in those arms.

This is sharing the checker can see: `model` is used whole on line 81, after the
change on line 65.
```

A read of a field after the change is never in such a message: the lowering reads it first (§31.14). The first
version of this section showed TodoMVC's `model.nextId` here. That program is correct under value semantics, and
it is accepted by the revised rule.

### 31.10 What the lowering consumes, and what it emits

**The fact.** A module reaches lowering only if its check, the ownership pass included, reported no error
(`Session.zig:2249`–`2258`, §28.3). A cache entry exists only for such a module (§28.4). So in a program that
builds, **every record update was accepted, and every one is lowered in place**; no lowering chooses between a
spread and an assignment, and there is no spread path to fall back to. What the lowering needs from the checker
is therefore not a verdict but **the hoists** (*revised the same day*, §31.14). Per module, indexed by BIR
instruction, the pass publishes a table: for each accepted demand — a `record_update`, or a call whose callee
writes a record argument (§31.7) — the written fields whose old values are read later, and for each such field:

- the holder whose version the reads name (a local, or the base);
- the read instructions to rewrite: `field_access` chains, record-pattern bindings, and the captures of a lambda
  read when it is made (§31.6), which are listed at the lambda;
- the **placement**: the instruction before which the temporary is bound (§31.14's rule).

The list demands of O5 share the table, with no hoists. It reaches `src/js/Lower.zig` as the dispatch table does,
as a field of the `Lowerer` beside `dispatch` (`src/js/Lower.zig:151`). Because a cached module is lowered from
its cached BIR, the table is a section of the module's **cache entry** and of the checked core, beside the
summary block (§28.4), and its format is versioned with it. It names only BIR instructions and locals, functions
of the module's source, so determinism holds (§10). Under runtime safety, `Lower` asserts that every
`record_update` it lowers is an accepted demand of a module whose entry is clean.

*Amended 2026-10-22 (#315): the channel precedes mutation and enforcement.* The channel may be
built independently of #286 and of record enforcement. Until the in-place lowering lands, every
record update still emits a spread. A table distinguishes an accepted demand from a **clean
module**: all its record demands were accepted and it was checked under ownership enforcement.
Report-only and unchecked modules cannot authorise a store. The lowering's store guard requires
both facts; retaining a table never enables mutation by itself.

The table has its own versioned section in the cache entry (including entries in the checked core),
beside the summary block. Its format uses module-local BIR instructions, declaration-local locals
qualified by their declaration, and offsets into a module-local field-name blob. It contains no
ownership path, cell, frame or interner id. A field path is copied from the BIR without a depth limit. Each accepted
record demand names its instruction and written fields; each hoist names its holder, the read
instruction or record-pattern binding to rewrite, the prefix through the written field, and its
placement. Captured paths additionally name the closure creation at which they are read eagerly.
A placement says either before an instruction or after an update's operands and before its stores;
a call's hoists go before the call. A write in a branch with reads after the join uses the enclosing
statement before the branch. Two writes that invalidate the same read retain the first placement.
A bad or unknown table format is a cache miss. The table is implementation information, outside the
interface record. It adds no dependency to the existing cache-key and interface-firewall rules.

*Amended 2026-10-22, cache replay:* a nullary dot is a call in checked BIR and a field-access
instruction in the cached frontend BIR. The table is validated before the cached nullary rewrite
is replayed: such a demand must have a callee site in the cached dispatch table. A field read
without that callee is not a demand. No ownership fact is recomputed on a hit.

The ownership dump exposes the table's hoists by source positions and written paths, without
internal ids. Its goldens pin placement before stores, across branches, at calls, and at closure
creation. These are channel tests; running the corresponding programs under spreads records the
value-semantics answers for the subsequent in-place lowering. A test-only wrong-placement mutation
must change a golden before any store is enabled.

*As built 2026-10-22 (#315), the channel only.* `own/Hoists.zig` format 1 is section seven
of cache-entry format 13, in the checked core as in the on-disk cache. `Check.hoists` owns fresh
and installed tables; `Lower.Input.ownership` borrows its module's table. A table's `clean` bit
stays false while records are report-only. No record update's emitted JavaScript changes.
`ownership/RecordHoistChannel` pins direct and call-site writes, a branch join, an old alias,
a record pattern, a capture after a write, two writes in sequence, and a ten-field capture path.
`tests/generate-record-hoists.mjs` (seed 315) writes `run/RecordHoistValues`: its 30 answers were
recorded under spreads and compared with the pre-channel compiler (59b52e349). The existing generated
research pages, `browser/inline/ResearchS2` and `ResearchS3`, retain their spread transcripts.
These files and the rest of `run/`, `browser/` and `emit/` are the subsequent lowering's differential
corpus. All five record mutation controls are caught, including `wrong-placement`. The sanitiser,
eager loads, stores and optimiser barrier remain the subsequent lowering's work; the two research
scenarios' `rr check` at multiple sizes and seeds remain its and the inline integration's gates.

**The order** (`language.md` §6's *Evaluation order*, unchanged: the base, then the updated fields in written
order). The base is evaluated into a temporary `b`, and each new value into a temporary `tᵢ`, in written order.
Then the fields are assigned, `b.f₁ = t₁; …; b.fₙ = tₙ`, and the update's value is `b`. Every value is evaluated
before any field is assigned, so `{ r | a = r.b, b = r.a }` swaps. Today the update is the spread
`({ ...b, f: v })` (`src/js/Lower.zig:4602`–`4619`). Assigning a field the object already has keeps its hidden
class. Under `--release` the field has its short name (`backend.md` §9, *Item 4, taken up*), and the store uses
the same name.

**The optimiser barrier.** A record demand is a barrier to §9's optimiser, as a list demand is (`backend.md` §4,
*`--release`*; thesis A5):
- no read of the base's written fields, or of anything that may alias the base, is moved across it;
- no single-use binding of such a read is inlined past it;
- it is never dropped as an unused pure expression.

### 31.11 Identity, on every platform

`language.md` §11.12's first promise stands: an untouched field keeps its identity. Its second is amended (that
section's dated note): **a written record keeps its identity too**, and so does every value that holds it. So no
runtime and no lowering may conclude "unchanged" from the identity of a value that may hold a record, as none
may for a list (`backend.md` §15.5, `boundary.md` §9.4.4, amended with this section). On `browser` and
`browser-tea` (the `dom` lowering and `Rt`), the following identity tests go for a value whose type may hold a
record:
- a row's item test (`item === i.x`);
- the keyed reconciler's reuse of a row's key when its item is `===` the last one;
- row inputs, component props, a `Show`'s value and its body's inputs;
- holes;
- a root's value groups whose read paths reach a record.

A value whose type holds no record and no list (a scalar, a string, an all-nullary constructor) keeps its test.
`browser-inline` and `browser-direct` drive their groups from write sets and never from identity
(`browser-direct.md` §7.4's first rule), so nothing changes there. The cost on `browser` and `browser-tea` is
measured on research 29's harness when the skips go, and it is recorded, not a bar (§31.1). The `ssr` lowering
keeps nothing across renders.

### 31.12 What lands before, and in what order

**Preconditions** (#317's order: these land before the record checker, because both change the summary format):

- **#286, the path cut.** A record path deeper than `k = 8` (`src/own/Ownership.zig:63`) merges with its
  neighbours, so a write of one field would be taken for a write of the merged place, or not seen at all. Records
  make deep paths common (a model, a page, a form, a field), so the cut must be the precise rule #286 designs.
- **#289, constructor steps past 64.** These are records inside constructors with more than 64 fields (§31.5).
- **#293, the O(n⁴) list literal.** A record literal is a stored construction (§18.2's table): its fields'
  objects are pairwise separated, so a literal of n record- or list-valued fields asks `sep` of every pair.
  `run/WideRecordDerivedEq` already has a 300-field record. The fix #293 makes for list literals must cover record
  literals, at no coarser rule.
- **O5** (§30.7): the in-place channel and the stale-read sanitiser, which this section reuses.

**The slices** after this specification, each with the gates green:

1. **Report mode for records.** Record cells (§31.2), the `update` demand and its conditions (§31.3–§31.8) in
   `dump --stage=ownership`, with errors off. This is the faithful version of §31.13's measurement, run on the
   same program set, and its numbers replace §31.13's. Fixtures under `tests/corpus/ownership/` for each rule of
   §31.4–§31.8, including the three of #315: a stored `msg` payload, a captured `model.form` and a `For` item. Also
   the mutation controls: a checker that hoists a whole use, one with no held-operand for records, one with no
   Disjoint on records, and one that publishes a hoist with the wrong placement. Each must fail at least one
   fixture, as C2's `RecordUpdate2` witness does. **Each rejection's line records its fix class**: `copy` (a
   whole use the copy answers), `restructure` (a top-level base, a value made a function, an arm reordered), and
   beside the rejections a count of the accepted demands that carry hoists (`hoisted`), and of the eager reads of
   captured field paths (§31.6). The `total` line sums them per class, so the cost of the departure from value
   semantics is a number per program, and §31.0 item 5 is decided on it.

   *As built (2026-10-19, slice R2b of #315), the demand in a body.* Every `record_update` is an
   `update` line in `dump --stage=ownership`, in report mode only: no diagnostic (`Enforce` skips record
   lines), no `W` in a summary and no requirement stated for callers (§31.7, R2c). Its cells are the
   record objects at ε of the base, an `except` cell read as the object it was written over. Known,
   Unescaped (a top-level record's object is a `shared` cell of its own), Disjoint against the new values,
   held-operand and Dead run as for a list. Dead is per field (`recordUse`): a later use at or above a
   holder's path is a whole use, but an update's base use of a field it replaces; a use below it
   through a field the update did not write is none; through a written one it is a hoist, unless a
   callee makes it in its own body, which is a whole use. Each evaluation of a field path is a use of its
   own (`Use.record_read`) that only a record demand reads, so that a read of a number field is a hoist
   like any other; the step into a written field is the caller's own read when it is part of the
   argument's path (`List.length r.items`). A call with no summary reads the record whole, `call`, and
   so does a call the checker cannot see into (a `foreign` without a summary, a `Js` call): each operand
   it is handed is a use at its own path. A record pattern (`{ x } = p`, a one-arm `case`) reads the
   fields it binds, not the record (`Use.destructure`). A closure made after the update reads each
   field path it captures when it is made (§31.6), so such a read of a written field is a hoist where
   the closure is built, a number's and a list's alike; each read is counted once, at the use that
   makes it. A read through a wrapper of the old record (`case Just p of Just r → r.x`, a tuple
   pattern) is still a whole use, #394.

   *Pending, not accepted, until R2c.* What decides an update the walk cannot see is a summary that does
   not name a record's object yet (`Prov.obj`, §31.7), so these lines print `pending`, never
   `accepted`: a base that is a parameter or what a callee hands a callback; a base that is what a
   call returns; a base with no cell at all, as a summary's results leave a record of numbers, or a
   top-level value read once at initialisation and handed over; and a base handed to a callee whose
   summary does not yet say which of a record's fields it reads. A rejection is kept: the uses it
   rests on are the walk's own. `{ Record.copy r | … }` demands the copy's new object, which nobody
   holds (§31.15), while `Record.copy`'s row still aliases π₁ for the fields it shares. In
   `browser-direct`'s corpus check, which fails `check` exactly when a report has a rejected or
   pending line, a record line does not count until R4 enforces it. A rejection's line ends in its
   fix class, `[copy]` or `[restructure]` (a top-level base), an accepted or pending one with hoists in
   `[hoisted n]`, and each module and the run end in a `records` line: demands, accepted, pending,
   rejected by fix, the lines with hoists, and the eager reads of captured field paths (§31.6), counted
   once per lambda, local and path. The mutation controls are `-Downership-record-mutation=` (hidden),
   run by `zig build test-record-mutations` outside the gates, which refuse the option: `hoist-whole`,
   `no-held-operand`, `no-disjoint` and `call-as-hoist` (a callee's read of a written field taken for a
   hoist), each caught by `ownership/RecordDemands`; the control of a hoist's placement waits for the
   hoist table (R5). A cell's key holds `nonlist`, so a top-level record's object is never the cell a
   summary's result makes at the same place (`ownership/RecordTopOrder`, checked reversed by
   `ordering_test`), and a hoist is counted once per use. Left to R2c, with `W{F}` in summaries: a
   write through a callee, the entry's checks (§31.8; #315's three cases are `tests/pending/ownership/Record*`,
   CK-260–262), a callback's supply of a record (§31.5), records' exclusive contents (§31.4 item 6), and
   a captured record's write making its closure once (§31.4 item 4; reported `captured-edit` until then).
   Over the 1 043 programs of the comparison, 271 have record updates: 1 741 demands, 4 accepted (local
   literals and `Record.copy`), 1 685 pending — 1 489 parameter bases, 176 callback parameters, 14
   handed to a callee, 5 with no cell, 1 a call's answer — and 52 rejected: 40 `top-level`, 6
   `later-use`, 2 `held-operand`, 2 `element` and 2 `unknown`, approximately; 9 lines with hoists and
   296 eager reads. No list line moves but `ownership/RecordCells`' `open`, which R2a's cells made
   precise.
2. **Enforcement**: §31.9's codes; the corpus rewritten only where the rule still refuses (§31.0 item 4); `core/`
   and the platforms clean (§31.16).
3. **The lowering** (§31.10, §31.14): the stores and the hoists, with the identity skips removed (§31.11).
   Evidence:
   - every `run/`, `browser/` and `emit/` golden, recorded under spreads before this slice, which is value
     semantics by construction;
   - the stale-read sanitiser extended to records: each record object carries a version, and a read through a
     holder older than the object's last write traps;
   - a generated differential test: programs whose expected output is recorded with the compiler of the commit
     before this slice, run in place under the sanitiser. The generator writes reads of written fields after an
     update in every position §31.14 names (the next argument, a later `let`, another arm, after a `case` that
     writes in one arm, inside a closure made before and after the write), so that a misplaced hoist is a
     difference.

   No test-only spread lowering is kept: it would be the fallback the owner refused (`browser-direct.md`, C3 as
   amended). `browser-inline` then emits an in-place field write for a single-module program, pinned by an
   `emit/release/inline/` golden and a page that behaves as the spread version did (#315, *Done when*).

### 31.13 Measured (2026-10-17): a static approximation, not the checker

**The checker's count (2026-10-19, R2c of #315), which replaces the approximation below.** Over the same set,
1 071 programs now, 276 have record updates and the checker makes 2 832 record demands: 1 775 updates in
bodies, 666 call-site lines (§31.7) and 391 entry lines (§31.8). 189 are rejected, in 51 programs, and 66 are
`pending`, 57 of them because records' exclusive contents are not built (§31.8's *As built*):

| Rejected | Lines | Where | Fix |
|---|---|---|---|
| `top-level` | 75 | a top-level base in a function, or in a `main` that names it twice: `run/Schema*`'s `defaultOptions`, `note`, `person` and `sample` (and more `run/` programs), Bike Wars' `initModel` and `initBikes` at the entry, `run/ListPersistence`'s `empty` (19) | `restructure` (§31.16: `Schema.defaultOptions ⊤`; `initModel ⊤`) |
| `later-use`, `alias`, `held-operand` | 47 | `core/Schema`'s `Context` handed whole to the next `run` (13), the seven TodoMVCs' `changed model (List.map model.todos …)` (14, an over-refusal, #405), Bike Wars, `run/ListPersistence`, `run/Records`, `run/MarkupFieldIdentity`, `TypedKeys` ×2, `PrettyPrinter` (`bench/corpus`), `browser/direct/RecordUpdateCompare` | `copy` |
| `payload` | 22 | the three Conduit pages and `examples/conduit` (P6: the entry does not tell `update`'s arms apart), `StoredBranchPlacement` | — (the list's rule, §23.6) |
| `captured-edit` | 10 | Bike Wars' `handleInput` writes a captured model (§31.4 item 4, not built), `run/ListPersistence` | — |
| `unknown`, `escaped` | 18 | a record from JavaScript (`core/Schema.beni:1231`'s `{ last \| … }`, `browser-direct`'s `Tea.beni` at `Tea.commands` and `Tea.subscriptions`, `run/ReleaseFieldsAcrossJs`) or from a schema the checker does not follow (`run/SchemaDepth`, 5); Conduit's `ChangedUrl` address, kept by the runtime (7); both `Tea.beni` platforms' `perform` state, kept by `List.foldl` | `copy` (R3) |
| `element`, `call`, `disjoint`, `supply` | 17 | the TodoMVCs' edit of one todo, Sternhalma's `board.cells[*]`, `KeyedEnds`, `run/ListPersistence`'s `walk`, `BranchReturn`'s entry, the `List.foldl` accumulator of both `Tea.beni` platforms | — |

The approximation's 9 certain programs are all among them, as are `run/Records` and `core/Schema`'s contexts,
which it counted as possible.

**Why an approximation.** The checker gives a record no cell (§31.2), so it cannot count record rejections. A
faithful count needs the checker change of §31.12's first slice, and this slice changes no `src/`. The numbers
below are therefore a **conservative syntactic approximation**, labelled as one. A script walks every module's
`beni dump --stage=bir` in §2.1's evaluation order:

- it records uses at their consuming instruction (§7.1) and branch contexts (§7.2);
- it records holders: locals bound to a variable path, pattern bindings with their paths, closures' captures
  expanded where the closure is consumed, and pending temporaries;
- it applies §31.4's conditions: per-field Dead (§31.4 item 5), held-operand, `top-level` and `read-only`;
- for `update`, `view` and `subscriptions`, it applies escapes through command, subscription and handler closures
  that capture the model whole;
- within one module, it carries the "writes its parameter" bit through calls of top-level functions (§31.7).

Its set is the one of `bench/ownership-everywhere.mjs`: `run/`, `browser/` (all four kinds), `emit/`, the three
examples, the ten bench apps, `bench/corpus`, `core` and the five platforms. That is 1 050 programs, with 1 041
record updates in 267 of them. Bike Wars' source is counted three times, as its two pages read it.

**Under the rule as revised (§31.0 item 1, §31.14):**

| What | Count |
|---|---|
| updates with a later read of a written field, hoisted by the lowering | 15 (14 accepted with nothing else to decide) |
| programs with **a certain rejection**: a whole use after an update | **9** (12 updates; 7 distinct sources) |
| programs with a possible rejection | 51 (204 lines, 54 of them call-site lines in `core/Schema`) |
| … of which a whole record handed to a call (§31.0 item 6) | 85 lines in 11 files; with the certain ones, 16 files under the coarser reading |

**What "certain" means.** A certain rejection is a whole use of the old record after an update, which the checker
refuses whatever its summaries say: a store, a return, a binding, the base of another update, a whole capture, a
temporary that holds the record, or a top-level base in a function. So **9 programs is a lower bound** on the
programs §31.4 refuses, short of a defect in the approximation. It misses, for example, holders across modules,
holders inside containers it does not project, escapes to JavaScript and exclusive-contents failures.

**What "possible" means.** A possible rejection rests on something only summaries decide: a whole record handed
to a call, a callback whose callee the script does not know, a payload, a lambda out of sight, or an update in a
`main` whose top-level base the read-once transfer of §28's 2026-10-15 amendment might accept. So **51 is an
approximation, not an upper bound**: the misses above can add to it. 39 of the possible lines are top-level bases
in a parameterless `main`. Most of those are refused, because `main` names the value more than once
(`run/SchemaRunners` names `note` nine times).

**The certain ones, and their fix class** (§31.12):

| Program | What | Fix |
|---|---|---|
| `browser/tea/TypedKeys`, `browser/direct/TypedKeys` (2) | `next = { model \| count = n }`, then `{ model \| heard = … }` in an arm of a later `case` (`Main.beni:65`, `:81`): the second update's base is the written object | `restructure` (compute `next` in its arms), or `copy` |
| `bench/corpus` (`PrettyPrinter`) | `[ { item \| doc = left }, { item \| doc = right }, …rest ]` (`:125`, `:167`): the first result waits while the second writes the same object | `copy`: `{ Record.copy item \| doc = right }` |
| `run/SchemaDepth`, `run/SchemaDeclDepth` (2) | `bound d = { defaultOptions \| maxDepth = d }`, a top-level base in a function | `restructure`: `Schema.defaultOptions ⊤` (§31.16) |
| Bike Wars ×3 | `{ initModel \| status = Running }` in `handleInput` (`Game.beni:148`) | `restructure`: `initModel ⊤` |
| `run/ListPersistence` | versions of a record model kept in a `Dict` and stepped | `copy`, as its lists already are (§30.9) |

`run/Records` (`shift 3 origin` again after `origin.x`) is not among them only because the script counts a whole
record handed to a call as possible; under §31.0 item 6 it is refused too, and fixed with `copy` (§31.7).

**The first count, reclassified.** This section's first version counted 17 programs as certain under a
per-record rule, which refused any later read of a written field. Ten of them were correct programs that such a
rule would refuse: the seven TodoMVCs, whose `changed { model | draft = "", nextId = model.nextId + 1 }
(model.todos ++ [ { id = model.nextId, … } ])` reads `nextId` in the next argument (`TodoMVC.beni:147`–`148`), and
`run/SchemaDepth`'s and `run/SchemaDeclDepth`'s `Show.issue { i | path = [] } ++ … List.length i.path` (`:99`).
They are correct under value semantics, and they are **not** sharing and not defects: the read after the write is
a cost of an in-place rule, not a bug the rule catches. The revised rule hoists them, and they are accepted.
TodoMVC's `commit` (a closure capturing `ed.id` from `model.editing` before `{ model | editing = Nothing }`) moved
from `captured` to an eager read in the same way. The other seven programs of the first count are the ones above.
The first version called `PrettyPrinter` and `TypedKeys` accidental sharing. That was wrong as well: both are
correct under value semantics, and the rule refuses them because the old record is used whole, so they pay a copy
or a restructuring.

**A sample of the possible ones:**
- the `core/Schema` engine's `Context` is refused under §31.0 item 6: `fieldsFrom` hands `c` whole to the next
  field's `descend`, whose `run` reads `c.src` (§31.16);
- `browser/tea/QueuedListSnapshot`'s captured snapshot is a whole capture, the record twin of its list case;
- TodoMVC's `List.map model.todos (λt → { t | completed = … })` followed by `changed model …`, whose summary
  reads only `model`'s other fields, is an idiom the checker is expected to accept;
- `Tea.put` and `core/Schedule.shifted` are flagged only because the script cannot see that `List.filter` and
  `step` make fresh values;
- the Conduit `…Errors` pages' "payload" lines are the script's error: it does not shift a tuple scrutinee's parts
  by their index.

The script was run outside the tree, and it is not part of the build. Its rules are the list above, and §31.12's
first slice replaces its numbers with the checker's.

### 31.14 Liveness per field, and the hoist (the owner, 2026-10-17)

The owner's rule, which revises §31.4 item 5: the checker already computes liveness per `(variable, path)` (§7.1,
thesis §3.9). The write rule reads it per field, and the lowering makes the old value dead by reading what it
needs first. This is Perceus-style reuse (Reinking et al., "Perceus", PLDI 2021): the compiler reuses the object,
and the author does not reorder the program to let it.

**What is hoisted.** For an accepted demand `D` on the object `c`, writing `F`, a **hoist** is a field `f ∈ F`
together with the later reads of `c.f` through holders whose version precedes `D`: the base, a local bound to
`c` before `D`, a pattern variable bound to `c`, and captures of `c.f` in closures (§31.6). A read through the
update's own result, or through anything bound after `D`, names the new version and is not hoisted.

**Where the temporary goes.** The lowering binds `t = h.q.f` (the holder's path to `c`, then the field) at the
**placement** `P`, and rewrites every read of the hoist to read `t`. `P` is:

- **immediately before the stores of `D`**, after its new values are evaluated (§31.10's order), when `D`'s scope
  dominates every read of the hoist: a later `let` of the same block, a later argument of the same call, the
  arms of a `case` nested after `D`;
- otherwise **in the nearest enclosing scope that dominates `D` and every read**, immediately before the statement
  of that scope that contains `D` — for a write in one arm of a `case` whose result is read after the `case`, before
  the `case`. The scope is a block, an arm or a function body; `D` and its later reads are always in one frame
  (§7.3), so it exists;
- and in either case **after the holder is bound and before the first accepted write of `c.f` that the read's
  version does not see**, on every path from the holder's binding to the read. When two updates write `f` in turn
  (`s = { r | a = 1 }; u = { s | a = 2 }; … r.a`), the read of `r.a` is placed before the first.

For a capture of a field path, `P` is the closure's creation (§31.6). For a write made by a callee (§31.7), it is
before the call.

**Soundness.** The argument is the thesis's (§6.3, versions and stale references), with one step for the hoist:

1. *No other writer of the old version exists once `D` is accepted.* §31.4's conditions show that no holder of `c`
   is used whole after `D` and that no pending operand holds it. So the only later accesses to `c` that see a
   version older than `D` are field reads, and a read of an untouched field returns what it returned before `D`.
2. *A hoisted read returns the value of the version it names.* `t` is bound before every write of `c.f` that the
   read's version does not see, and after the holder's binding, so it holds `c.f` as that version had it, which is
   what value semantics reads at the original read.
3. *Moving the read is unobservable.* A field read is pure and cannot fail: a record always has its fields, and the
   type says which (`language.md` §11.11, "a field read of a record cannot fail and computes nothing"). So the read
   may leave a branch that would not have run it, an arm, or the body of a closure that runs later or never. It
   costs one load where it did not run, and changes no value and no effect. `Debug` cannot see a field read.
4. *Aliases are whole uses.* A holder the checker cannot read field by field — a container that holds `c`, a whole
   capture, a call result that may be `c`, a binding of `c` made after `D` — is a whole use and refused. So every
   access that could see `c` after `D` is either a hoisted read, a read of an untouched field, or a read of the new
   version.

**Where it happens.** In the lowering (`src/js/Lower.zig`), from the checker's per-field facts: the table of
§31.10. BIR is unchanged, and the checker does not rewrite the program. The optimiser barrier (§31.10) keeps
`t`'s binding where the table put it: item 1 may not move it past `D`.

**What it costs.** One load and one local per hoisted field, which is what the author would have written to make
the program in-place-safe by hand. It is counted by report mode (§31.12).

### 31.15 `Record.copy`, and a call as an update's base (the owner, 2026-10-17)

**The module.** `core/Record.beni`, a new core module with one value:

```elm
--| A shallow, fresh copy of a record: the same fields, holding the very same
--| values (`language.md` §11.12), in an object nobody else holds.
pub copy : { r | } → { r | }
```

- **The type `{ r | }`** is an extensible record with no named field, "any record". The grammar refuses it
  today (`language.md` §3, `TypeAtom`'s extensible-record rule takes one field or more). It is admitted everywhere,
  not only in core, so a program can write a generic helper over any record (CLAUDE.md rule 7). It unifies with
  every record type, closed or extensible, and with nothing else.
- **Its row** is asserted, as `List.copy`'s is (§16.8): π₁ `R`, and every field of π₁ `A`; `res ε fresh₁`, whose
  every field is π₁'s at that field. It writes nothing and is not a demand.
- **Its body** is written over `Js`, as `List.copy`'s is (§3.4): `({ ...r })`. The spread copies the keys in their
  order, so the copy has the record's hidden class, and under `--release` the short names are already the keys.

  *Amended 2026-10-18 (the owner, #381):* the body is a one-line `foreign` sibling, `core/Record.js`'s
  `export const copy = (r) => ({ ...r });`, not `Js`. Only a spread keeps the record's hidden class: on Node 24,
  `%HaveSameMap(r, { ...r })` is true and `%HaveSameMap(r, Object.assign({}, r))` false, since V8 builds the second
  from the empty object's map. `Js` has no spread, and `Object.assign` is all it can write. The `foreign` has no
  ownership words: the asserted row above replaces its summary, as `List.length`'s does.
- **Where it is**: `Record` is a prelude module for qualified use (§31.0 item 8), so the fix an error
  offers needs no import.

**The language change.** `language.md` §6.3 says "the update target is a plain name". It becomes: **the base of an
update is a name, or a call** — an application whose head is a name or a qualified name and whose arguments are
atoms, `{ Record.copy r | f = v }`, `{ defaults ⊤ | f = v }`. Any other expression is written in parentheses,
`{ (pick model) | f = v }`. The grammar's update rule (`language.md` §3, *Atom*) changes from `'{' lower_ident '|'
Field … '}'` to `'{' UpdateBase '|' Field … '}'` with `UpdateBase := lower_ident | qualified_lower Arg* |
lower_ident Arg+ | '(' Expr ')'`. A record literal still begins `lower_ident '='`, so one token of lookahead
after the name still tells a literal from an update. The formatter keeps the base as written. Markup's spread
(`language.md` §11.8) already updates an expression and is unchanged.

`{ Record.copy r | f = v }` is then the update of a fresh object: its demand's cells are `Record.copy`'s
`fresh₁`, accepted `call`, and `r` is only read.

### 31.16 Core and the platforms (the owner, 2026-10-17: no exemption)

Every site of `core/` and the platforms that §31's measurement or reading found, and what each becomes:

| Site | Today | Becomes |
|---|---|---|
| `core/Schema.beni:251`, `pub defaultOptions : Options` | a top-level record, updated by programs and passed to every `…With` | **a function**, `defaultOptions : ⊤ → Options`, as `init` became one (§22.2); its six readers in core (`decode`, `encode`, `read`, `write`, `parse`, `print`, `:2952`–`:3086`) call `defaultOptions ⊤` |
| `core/Schema.beni:1053` (`hostEnds`), `:2118`, `:2125`, `:2128`, `:3577` | child contexts as `{ c \| … }` while the parent goes on with `c` (`fieldsFrom`, `:2706`–`:2736`) | **fresh child contexts**: each child's `Context` a record literal, or `{ Record.copy c \| … }`; measured on the schema benchmarks (`schema.md` §16) |
| `core/Schema.beni:1225`, `{ last \| key = external, renamed = True }` | an update of a record the engine built | expected accepted; checked in report mode |
| `core/Schedule.beni:244`, `{ m \| attempt = …, elapsed = since }` | writes the `Metadata` the schedule's runner hands its step | accepted if the runner's summary hands it owned; otherwise the step makes a new record |
| `platforms/browser-tea/Tea.beni:203`, `:230`, `:364`, `:472`, `:480`; `platforms/browser-direct/Tea.beni:132`, `:159`, `:293`, `:401`, `:409` | the driver's `State` record (`model`, `jobs`, `live`) | expected accepted: each is the driver's own state, threaded; `put`'s callers are flagged by the approximation only because it cannot see `List.filter` makes a fresh list. A refusal here is fixed in the platform's code, never by a copy added to get green (§30.7, O1's rule) |

`core/` and every platform must hold no rejected or pending record line when beni is built (§28.7). Every row is
checked by the report-mode slice before enforcement.

*As built (2026-10-19, slice R3 of #315), the table and §31.13's programs.* `Schema.defaultOptions` is
`⊤ → Options`; core's readers and a compiled schema's root wrappers call it (`defaultOptions()`, one record
per run), and the bound it holds is named once, `defaultMaxDepth`, which `shapeMax` reads. The engine's child
contexts — `hostEnds`, `belowBackward` and `run`'s `NConverted`, `NFlipped` and `NProjected` — are
`{ Record.copy c | … }`, and `:1231`'s `{ last | … }`, a record read back from the engine's array, is a
copy: `core/` holds no rejected record line. The programs, each with the fix its line named and no checker
change: PrettyPrinter's `Concat` and `Group` (a copy, and `{ flat | mode = Break }`), and its `fits`, which
only looks and so copies; both TypedKeys, which update in the arms that need it; Bike Wars' `initBikes`,
`initModel` and `init` as functions of `⊤`, and a copy of the red bike for `Bike.shoot` and `Bike.update`;
Sternhalma's `setOccupant`; `KeyedInPlace`'s and `KeyedInPlaceMap`'s `rows ⊤`; `BranchReturn`'s page and
`home` as two records, an alias the rule refuses (one record at two model paths, §31.8) rather than sharing
anything observes; `run/ListPersistence`'s model functions; NotesApp's `editNote`, whose callback is handed a
note the history keeps; Conduit's Editor and Settings saves, whose commands kept the model's form (`escaped`,
§31.6), though a command's fiber starts in the microtask drain (`core/Task.beni`), before further input, so
no save could read a later form; `run/Records`, `run/MarkupFieldIdentity`, `run/TeaLoop`, and the `run/`
programs whose top-level test value an update used (`Record.copy`). `run/ReleaseFieldsAcrossJs`' test
platform declares its `origin` `fresh`, which its sibling makes, and needs no copy. Three copies that only
answered an over-refusal were taken back (rule 10): Conduit's `Route.fromUrl` (#412), `run/SchemaDepth`'s
issues (#413), and `run/SpecializeEscapeThenSpread`, which keeps its escaped record reaching a spread, a
refusal from R4 on, beside `run/SpecializeEscapeThenCopy`, the program that passes. Every `run/`, `browser/`
and `emit/` golden prints what it did; the emit goldens change only by `Schema$defaultOptions()`. Over the
1 083 programs, 105 record lines stay rejected, none of them a program's to fix: the TodoMVCs'
`changed model (List.map model.todos …)` and their edit of one todo (#405, 19), `KeyedEnds`' callback that
reads `List.length rows` (a read at ε, the same summary limit, 4), Conduit's Editor `status` at the entry,
one form at two variants of one field (#410, 28), its `ChangedUrl` address (#412, 7), Conduit's and
`StoredBranchPlacement`'s `payload` (P6, 29), `run/SchemaDepth`'s issues (#413, 5), Bike Wars'
`handleInput model _` (§31.4 item 4, 6), `run/SpecializeEscapeThenSpread` (1), and the two `Tea.beni`
platforms (6): `Direct.beni`'s state read back from JavaScript (`Tea.commands (Js.to self)`) and `perform`'s
`List.foldl` accumulator, whose record supply the checker does not yet follow through the callback's loans.
Those wait for the checker (R2d) or a decision on the driver's state; none was rewritten to pass.

---

## 32. Ordered Dict and Set (specified 2026-10-22)

*Specifies the owner's decisions of 2026-10-17 and 2026-10-19 (#294), before
implementation. Amends §4.4, §16.7, §16.8, §20.8, §20.9 and §24. The API is
`language.md` §6.8, the representation `backend.md` §4, **Ordered dictionaries**.
These rules take effect together with the representation change. Until then
the tree's existing rules remain the implementation contract.*

### 32.1 Places and storage

A dictionary owns mutable collection storage, independently of whether its value
type holds a cell. Its entries are key/value pairs, and its index maps scalar
keys to positions. Keys cross: only Int and String are valid. Every value has
its own concrete place. The finite ownership summary uses `[*]` for the values'
representative, as for List, never a recursive Tree path. The root `ε` names the
collection's storage (header, entries, private pairs and Map treated as one
allocation unit), and `[*]q` names place `q` of its stored values. Nested
collections retain their own roots under that step.

The representative does not mean that distinct keys alias. `excl d` says the
values at distinct positions are disjoint from each other and from the
collection storage; repeated references inside a value also count, following
the existing deep conditions. Storing the same List at two keys fails it.
Storing a tuple or record containing that List at two keys fails it too. The
property belongs to that particular dictionary value, not to the allocation of
one operand or to a globally interned path. The sound construction conditions
of #456 stay intact. No Dict exemption is added to recover acceptance.

An edit of the collection's storage demands ownership of `d` at `ε`, not of
all cells in its values. A callback that writes a selected value adds its own
demand on the supplied place; it does not indiscriminately write every value.
A borrowed lookup aliases the selected value and grants no exclusive loan.
Reading the old dictionary after a writer prevents the storage write even if
the read observes only size. A copy separates storage but retains every value
alias, including tuple/record payloads and their deep sharing conditions.

This is the meaning of the finite insertion-ordered map and `dictFocus` in
#522/#580: get, body, insert-or-remove, on one entries allocation. The Lean
model uses Int keys and a Result for Maybe; String is another scalar key and
Maybe has the corresponding payload path. It is not necessary to change its
meaning model to match the host's index. The model's read-then-replace `reads`
program is refused while the original dictionary remains live (#579). That
program writes storage despite only reading the supplied value. This work
makes no theorem claim beyond the proof work's own stated coverage.

### 32.2 Primitive rows

Every foreign declaration carries its summary in core, beside its type. These
are precise primitive rows, like List's element-supply rows; §24's coarse words
alone cannot express a root-only write or a conditional destructive supply.
They must not be replaced by a deep `consumed Dict` row, which would require
ownership of values an insertion never edits. The declared row is validated,
published in interfaces and summary caches, used for function-value calls, and
printed by `dump --stage=ownership`. A name in an unrelated module cannot
acquire a Dict row. Missing declarations are conservative foreign calls, never
optimistic borrowed calls.

In the table, `D` is argument 1, `V` its `[*]` representative, `W ε` is a demand
on collection storage only, and `fresh` means fresh storage with the listed
value aliases. A row keeps no host reference after the call. Scalar arguments
cross. Callback results include their captured aliases and retain their full
conditions; fresh storage never implies exclusive values.

| Dict primitive | Uses and result | Callback supply and conditions |
|---|---|---|
| `empty ⊤` | fresh root; no value cells; exclusive | an ordinary unit function, fresh on every call, including calls through function values |
| `singleton k v` | read/alias argument 2 at result `[*]`; fresh root | exclusivity is that of `v`, with no other entry |
| `get d k` | read `ε` and `V`; result `#Just.0` aliases `V`, or Nothing | borrowed; result is not fresh value storage |
| `member d k`, `size d`, `isEmpty d` | read `ε`; scalar result | no value read or write |
| `insert d k v`, `insertAt d i k v` | read and `W ε`; return root `D`; retain old values plus supplied value | result exclusivity requires exclusive stored values and separation of the arrival from retained values; no value write |
| `remove d k` | read and `W ε`; return `D` and retained values | preserves their exclusivity; conservative value provenance may retain the removed value |
| `swap d a b` | read and `W ε`; return `D` with the same values | permutation preserves both value and spine conditions |
| `sortBy d f` | read and `W ε`; return `D` with the same values | call `f` once per entry, in order, key scalar and value borrowed; callback results are temporary sort keys, not retained values; writes to supplied values are refused |
| private `focus d k f` | read and `W ε`; return `D`, retained values and callback's Just payload | call argument 3 exactly once with Maybe v; its `#Just.0` aliases the selected `V`, taken and owned conditionally on `excl D`; absence supplies no value |
| `copy d` | read `ε` and `V`; fresh root; values alias `V` | preserves value exclusivity internally, but shares them with `d`; no demand on input storage |
| `keys d` | read `ε`; fresh exclusive List of scalar keys | no value alias |
| `values d` | read `ε` and `V`; fresh List, result `[*]` aliases `V` | preserves internal exclusivity, shares with `d` |
| `toList d` | read `ε` and `V`; fresh List and tuples; result `[*].1` aliases `V` | tuple keys cross; private entry pairs never escape |
| `eq left right` | read both roots and value representatives; scalar result | sync value-equality evidence borrows each value; identity shortcut first |

Private storage primitives used by beni loops have the corresponding subset
of these rows. In particular, an internal index read is borrowed; a store
writes only `ε` and aliases the value at `[*]`; a fresh builder has no values;
a builder finish transfers the same root and its precise stored-value aliases.
No unworded host operation may erase the builder's aliases or conditions.

A focus removes the selected occurrence from the dictionary's holders for the
callback, as List.focus does. Ownership of its supplied value is conditional
on the dictionary being exclusive and the collection being owned and dead
outside this call. The loan cannot overlap a value kept elsewhere, in another
key, in a capture, or in a callback result that remains live at a later write.
When the callback returns its taken value with shape preserved, the write-back
recovers its exclusivity and spine conditions. A replacement must be separated
from the other retained values; an unknown or aliasing callback does not gain
that property by assertion. A callback that only reads needs no value loan,
but focus still demands the storage write. `update` is a beni wrapper over
focus with its inferred summary, not a second independent assertion.

### 32.3 Derived operations and Set

The following public bodies are inferred from the primitives and their actual
beni callback loops. This table fixes the behaviour their inferred rows must
express; a foreign implementation must declare the equivalent precise row.
The callback protocol, including suspension and accumulator loans, is the
existing one (§18 and §28).

| Operation | Ownership contract |
|---|---|
| `Dict.fromList pairs` | fresh dictionary root; values alias `pairs[*].1`; repeated entries may lose exclusivity; reading and building never consumes the input List |
| `Dict.map d f` | fresh dictionary root; callback results at `[*]`; callbacks in insertion order; each value supplied taken/owned only under `excl d` and the usual call-site demand when the actual edits it; retained outputs participate in subsequent holder checks |
| `Dict.foldl`, `Dict.foldr` | borrowed dictionary values, no destructive value supply; accumulator supply/result follows the fold invariant; callback order forward/reverse; result is the final accumulator and may alias inputs through it |
| `Dict.filter d f` | fresh root, retained values alias `V`; callback borrows each key/value; no value ownership granted; preserve order |
| `Dict.partition d f` | two distinct fresh roots, each retaining input values; callback borrows; a representative may approximate both partitions, never fabricate their separation |
| `Dict.union left right` | fresh root; left values and right-only values alias the inputs; exclusivity requires separation between retained values, even at distinct keys |
| `Dict.intersect`, `Dict.diff` | fresh root; retained left values alias the left; right is borrowed for membership only |
| `Dict.merge` | both dictionaries borrowed; one of three callbacks per distinct key; accumulator supply/result follows the folds; no taken value supply from either dictionary |
| `Dict.update` | exactly focus's inferred row, including the unconditional root write |
| `Set.empty ⊤`, `singleton`, `fromList`, `map` | fresh dictionary storage; members cross; map callbacks borrowed, outputs checked as valid scalar keys |
| `Set.insert`, `remove`, `swap`, `insertAt`, `sortBy` | Dict's root-write row on the wrapped dictionary; same root returned; sort keys transient |
| `Set.copy`, `filter`, `union`, `intersect`, `diff` | fresh dictionary storage; inputs read only; no member cells |
| `Set.partition` | two distinct fresh dictionary roots; scalar members |
| `Set.member`, `size`, `isEmpty`, `eq` | read wrapped dictionary roots; scalar result |
| `Set.toList` | fresh exclusive List of scalar members |
| `Set.foldl`, `Set.foldr` | scalar members borrowed; accumulator protocol unchanged |

Set has no independently asserted row: its wrapper bodies infer these contracts
through Dict. Neither Dict nor Set has a compare primitive or derived compare.
Dict storage is a mutable cell even with a crossing value type; Set's wrapper
therefore does not cross merely because its members are scalar.

### 32.4 Removal of the tree exceptions and acceptance evidence

Once the ordered representation and rows are built, delete `dictTree`, its
path helper where unused, the `unmarked` branch in projection and the Dict skip
in call-site other-place checks. Remove the tree-specific self-separation and
fold exemptions from §16.7 and the trusted-surface exemption from §20.9.
Retain the precise focus row on the trusted surface: the tree's exemption is
withdrawn, not the need to audit a destructive loan.

Runtime fixtures pin insertion order, duplicate replacement, remove/reinsert,
forward/reverse folds, ordered equality, stable sort with callback order,
swap (including missing keys), insert-at (including existing keys and clamped
bounds), in-place storage edits and explicit shallow copies. Set gets the same
behavioural checks. Build refusals name the scalar-key restriction and
`Dict.copy`/`Set.copy` for a live old collection. A copied collection whose
shared List payload is edited remains refused unless the payload itself is
copied. No identity test is allowed to excuse a rendering error.

The pending `DictFocus.grow` acceptance must recover and return to the corpus
(#663), preserving the refused twins for repeated values, tuple/record
payloads, captured aliases and live old dictionaries. The read-then-replace
case in #579 must now refuse. An unexpected safe refusal or an instruction
budget failure is a stop condition, not a reason to weaken the rows or tests.
This section adds no keyed For, Dict write-set positions (O3), or recogniser
for List.map keyed updates. Those belong to the rendering work.

### *Amended 2026-10-22 (#670):* a write's extent

A summary use carrying W also carries an **extent**, `storage` or `deep`.
`storage` at p writes the collection's own slots and order, including inserting,
replacing or removing a slot; it does not write any value stored in those slots.
`deep` at p may write every value below p, as the previous keep-edge overlap
rule assumed. A write that edits a stored value is deep at that value's path.
An unclassified write is deep. This distinction is independent of the send bit
S (§23.2), which continues to give up every cell of its payload.

For a storage write at p, a value loan strictly below p (in particular p[*])
does not overlap the write. A loan at p, or above p, still overlaps: keeping
the collection observes its slots and order. A deep write uses the existing
symmetric path overlap. Paths containing wildcards or recursive level markers
retain their set-of-places meaning (§16.7): storage overlap asks whether some
loan place is an ancestor of, or equal to, some written place. Unknown places
remain conservative. Neither extent grants ownership or a destructive loan.

The keep edge (§16.4), including a write through another callback, uses this
extent-aware overlap. The supply edge uses it too: changing container storage
does not edit a supplied value strictly below that storage. All demands on the
written storage still require Known, Unescaped, Disjoint and Dead. Deep writes,
value aliases, exclusive-content conditions and sends keep their prior checks.

Extent is carried through inferred wrappers, function classes, captured writes,
callback write-back, normalization, joins and summary serialization. At the same
parameter and path, any deep write makes the joined write deep; a read without
W does not change a storage write's extent. Canonicalization must not discard
a deep write under a storage-only fact. Existing unclassified rows default to
deep. Summary blocks advance from version 19 to 20 and serialize the extent;
an older block is absent and is recomputed, never read with the new rules.
The report keeps W/w and S/s spelling and marks a storage W as W[storage]
(or w[storage]).

List's precise slot writers (`set`, `insertAt`, `put`, `push`, `pop`,
`removeAt`, `swap`, `done`, `append` and the root write of `focus`) are storage
writes. Their result aliases and callback/value-write demands remain unchanged.
List operations inferred from these primitives preserve the extent. In §32.2,
every W ε is storage-only, including private `permute`, stores and builder
finish; a callback's own value write is deep at its supplied value, or storage
at that value's own collection root when its precise primitive says so. Set
inherits these facts through its wrapper, with no separate trusted assertion.
The ordered Dict rows take effect with §32's representation change.

Regression evidence must accept a borrowed-value identity callback followed by
a storage permutation, and refuse the twins that write the kept value, retain
the storage itself, or send the value. Existing verdicts stay unchanged.
The Lean model's write paths need the same extent and overlap distinction;
#316 tracks that oracle work alongside #165, in Jayson's files. This amendment
makes no new theorem claim for rules the oracle does not yet judge.
