# The ownership checker v2 — design and implementation plan

*Draft 2026-10-25, revised for the owner's decisions of that date; approval covers this design and the
requirements amendments in this PR. Part of #1006. The WHAT is
[`ownership-requirements.md`](ownership-requirements.md) (R-n.m below); this document is the HOW. Where they
disagree, the requirements win. End state: lists and records enforced on every platform; no copy fallback,
warning or resource-triggered coarsening; deterministic output; the `Ref` loan model (#981); ordered `Dict`
only (#961); room for #587 and an in-place shared cell type.*

**Decided resource contract [O 2026-10-25].** Precise ordinary callback labels stay. The one analysis-size
resource, `ownership_summary_size`, defaults to 65,536 records per owning declaration, including its nested
classes, environments, contexts, sets and retained analysis memo records. It is charged before expansion and
fails with `ownership_limit`; an attribute can raise it (§4.4). Genuine recursive summary dependencies use
§2.10's graph backreferences, never a merge of ordinary invocation contexts. §4.1 proves the total bounded
cost and identifies the fragments with stronger linear bounds; it makes no general source-linear claim.
The structural measurement's maximum **10** at `o/LimitOwnedAtoms.beni:45` counts callback labels, not the
complete new resource; S2b must measure the latter. The former complexity blocker is resolved by this explicit
owner decision, not by claiming exponential labels became linear.

**Reading order for an implementer.** §1 says why the shape family; §2 is the semantics every module obeys and
§2.14 the lemmas each rule must keep; §3 the layout of every table; §5 the files and the layering gate; §8 the
slice you are on. Appendix A maps every requirement to its section; Appendix B every pending fixture to its slice.

**Sources cited.** Papers in `/home/canassa/src/github.com/canassa/ownership-library/` (`SOURCE-STUDY.md` for
file:line into the vendored checkers; `papers/`, `catalogue/`), `docs/design/research/68`, `69`,
`docs/thesis/ownership/` (thesis §n), the frozen v1 (`src/own/`, `ownership-checker.md` = oc §n), its review
(`~/.cache/beni-agents/ownership-review-fable/report.md`) and the two reviews of this document's first draft.

---

## 1. The choice of family

### 1.1 What the requirements demand of the domain

| | Property | Forced by |
|---|---|---|
| P1 | per-field, per-path liveness at any depth; a later read of an untouched field is no use | R-4.1.2, R-4.8.2, R-4.3.5 |
| P2 | per-path reads and writes of a callee (`changed` never reads `.todos`; a W at `π2.todos` only) | R-2.6, R-4.3.5, R-4.8.5, R-5.1.1 |
| P3 | provenance: the result *is* argument 1 / is fresh / holds `cb_j`'s answer; fresh cells numbered so two result paths naming one number are one object | R-4.10.1–R-4.10.3, R-5.1.2, R-5.2.4 |
| P4 | callbacks: what a callee supplies (owned or borrowed), needs of a result, keeps; folds' feedback | R-5.2, R-5.3, R-5.8 |
| P5 | exclusive contents of a container, per written path, kept through destructive reads, refuted by a taken element stored back | R-4.6, R-4.10.7–R-4.10.13 |
| P6 | levels of a recursive value told apart where the text does, folded finitely where it does not | R-4.7 |
| P7 | directional aliasing (`ys = xs` then a write through `ys` with `xs` dead is accepted), branches that keep the old value | R-4.1.5, R-4.2 |

Plus a soundness argument per rule (R-3), the proved-fragment and resource bounds (R-7.2–R-7.4), modular summaries hashed with the
interface (R-5.7), and a three-place diagnostic (R-6.6).

### 1.2 The four candidates, judged

**(b) Inferred uniqueness types, Clean-style** (`src/clean/frontend/refmark.icl`, `unitype.icl`; research 69
§2.1). Attributes on every type position, inferred by coercion inequalities solved eagerly; sharing by counting
occurrences per field (`SelectiveUse`, R:33-37), sequencing marking earlier uses non-unique (R:804-830). P1 yes.
P7 no: `[ …xs, List.length xs ]` (R-4.1.3) counts two occurrences and refuses; a unification-based attribute
poisons every value a shared one touches (Emre et al., thesis §3.4). P2/P3 no: an attribute never says "the result
is argument 1" (R-4.10.1) or "fresh number 2". P4: function types force invariance (U:840-864). P5: deep uniqueness
`*[*a]` exists (Barendsen–Smetsers) but no materialisation (R-4.6.9). Diagnostics name one place (R:913).
**Rejected as the core.** Taken: deep uniqueness as the meaning of `excl`; the demand in the library's types.

**(c) Borrow inference plus a static contract** — Lean 4 (`InferBorrow.lean`), Koka `fip` (`CheckFBIP.hs`), Roc
(`arc_solve.zig`). Per-variable owned/borrowed, per-SCC fixpoint, borrowed by default. P1 partial (Lean per
variable, 378-380; Roc `ret_unique_fields`). P3 none; reuse rests on run-time reference counts, which R-1.2
forbids. P4: Koka warns on higher-order (F:264-279). P5/P6 no. Koka's `fip` is the one contract that *fails loudly*
when reuse cannot be proved. **Rejected as the core.** Taken: the loud contract; borrowed-by-default callbacks; a
driver whose facts only grow and re-visits a member only when a dependency changed (Lean 263-326; Roc
arc_solve.zig:25-29).

**(d) Morphic per-slot modes with `u ≤ v` constraints** (`annot_modes.rs`, `inequality_graph2.rs`). Slots per type
shape, recursive types parameterised per type SCC (`SccParameterizer`, A:295-432); lifetimes as path trees;
constraints solved in one topological pass over the condensed graph (I:114-171). P1 yes; P6 the right place set.
P3/P4/P5: a mode is *owned or borrowed*, not *which object*; first-order IR, no closures. **Rejected as the core.**
Taken: type-shaped slots folded per type SCC (our places), signature variables (our atoms over arrivals), and the
condensed-graph propagation for the fixpoints that carry cells along inclusion edges (§2.12).

**(a) A shape graph: abstract interpretation with materialisation** — Chase–Wegman–Zadeck (`papers/1990-chase-…`),
Sagiv–Reps–Wilhelm (`1996-sagiv-…`, `1998-…toplas`: the `is` sharing predicate, *focus*), Whaley–Rinard escape
graphs composed by grafting (`1999-whaley-…` §4), Sălcianu–Rinard write effects per parameter path
(`2005-salcianu-…`), Deutsch's folded access paths (Mazur's type selector, `ctgc.selector.m:417-541`). Nodes stand
for objects at the paths of a type, labelled with provenances; a summary is such a graph over parameters and
result; a call grafts; a taken element is *materialised* out of its summary node. P1–P7 are all expressible;
soundness is the standard per-rule over-approximation argument; diagnostics fall out of provenance. Its known
cost, and v1's failure, is representation: enumerated paths exponential in value depth (#856), unbounded through
cyclic types (#955), pairwise in width (#693), instantiated as lists (#716).

### 1.3 The choice

**v2 is (a), with (d)'s place set and solver, (c)'s contract and driver, and Clean's deep uniqueness as its sharing
predicate.**

1. **Places are type-shaped and folded per type SCC**, derived from the solved type graph, which `unify` builds
   coinductively (`checker-v2.md` §7.3 as built): a cyclic type with no name (#955) is one place.
2. **Abstract values are structurally interned shape nodes over places**, with a `delta` node for a record update, a lazy
   `union` node for a join that cannot merge, and *widening onto the place graph* in every fixpoint unknown, so
   `w5`'s result is 17 nodes (#856), an `update` of N arms is O(N) (#716, #975), and every fixpoint must range over a
   finite lattice (§2.12), with inventory growth guarded before expansion (§4.4).
3. **Cells carry provenance and are singleton or summary**; refinements (`elem`, `others`, `level`, `below`) are
   materialised at a match or a destructive read (SRW focus) and their non-alias is a *condition*, so a taken
   element stored back refutes exclusivity (R-4.6.9), distinct fresh elements keep it (R-4.6.7), `List.map`'s
   result is exclusive when its callback's results instantiate to distinct cells (R-5.2.9), and a split on a parameter yields `xreq`.
4. **Exclusivity is a condition per node**, which is per *path* under a summary position (R-4.6.4), with one
   `apart{…}` atom per construction (#693) and the invariant I-κ of §2.14.
5. **Summaries are classes over a function type's places**, instantiated by grafting with a memo per node; a
   function parameter's class is a placeholder (`cb_j`) resolved at the call; a closure a class returns or supplies
   carries its own class (R-5.4.8, R-5.4.9). A class names no declaration: the room #587 needs (§2.10).
6. **Two fixpoint shapes, one driver**: a worklist over frames for groups and local functions, and sparse
   propagation of cells over per-path inclusion edges for a callback's feedback and the entry's model (Morphic
   I:114-171), both use finite lattices, no round cap (R-7.4); their retained operation graphs obey §4.1.
7. **Rows are data**: ownership words (oc §24) extended by four words (§2.13.6); a send is a call of a worded
   operation on a nominal `Send` type (§2.13.5). No Zig names a declaration.
8. **The contract fails loudly** (Koka `fip`): every unprovable write is an error with a named fix; a resource limit
   is an `ownership_limit`; nothing is ever a copy.

---

## 2. The semantic core

Notation: `ε` the empty path; steps `.f`, `.i`, `C#i`, `[*]` (list/dictionary position), `◇` (closure
environment), `◆` (`Ref` contents), `⟨n⟩` (opaque slot), `⟲` (one or more levels below a recursive place).
`A(e)` the abstract value of `e`; `Σ` the frame state; `γ` concretisation. BIR = `src/bir/Bir.zig`: a declaration
is a contiguous instruction range in evaluation order, every binding a distinct local index (`Lower.bindLocal`
appends; nothing rebinds).

### 2.1 Places

A **place** is a node of the *place graph* of a type: one node per store variable reachable from it, children by
step; a type variable, function type, foreign type or crossing primitive is a leaf in the type graph; lexical closure environments are additional accounted edges. Computed by one memoised walk
over the solved type graph (`check/Walk.zig`'s `structural` successors) with knot-tying: a variable reached again
while on the walk's stack is the node being built, so a recursive type, named or not, folds onto itself; a
*different instantiation* (`Tree (Tree (List Int))`'s inner tree, `Maybe (Maybe a)`, `Dict String (Dict String …)`'s
inner dictionary) is another variable and another place (R-4.7.3).

| Place kind | Steps | Holds a cell of kind | Notes |
|---|---|---|---|
| `record` | `.f` per field | `record` | every record type (R-4.8.1) |
| `tuple` | `.i` | none | never written |
| `ctor` | `C#i` per constructor and argument | none | **a sum**: paths through different constructors are alternatives (§2.2); a record-alias constructor is a `record` |
| `list` | `[*]` | `list` | `[*]` is a *summary* place (positions merged) |
| `dict` | `[*]` (values) | `dict` | keys cross (R-4.10.9); `Set` is `Dict k ⊤` |
| `ref` | `◆` | `ref` | `Ref a`, `Deferred a`; `◆` is a barrier (§2.13.7) |
| `closure` | `◇` | `closure` | the environment; children are the captured paths; carries a class slot (§2.10) |
| `opaque` | `⟨n⟩` per published slot | `opaque` | `Js.Value`, `Html`, a program (R-4.6.5) |
| `var` | none | any | a type variable may hold anything (R-5.5.11) |
| `cross` | none | none | primitives, `⊤`, `⊥`, a nominal type reaching no tracked place, a crossing foreign type |

**Identity.** Initial construction uses the dense `by_var` memo: each solved store variable is visited once,
including its outgoing edges. It does not need global structural interning to construct a cyclic graph.
Structural identity compares `(kind, head, children)` where the head is the session `TypeId` of a nominal or
foreign type, the field names (by text) of a record, the arity of a tuple. Comparisons/re-interning needed by an
owner or codec use charged graph-pair tasks, not an unproved linear structural-isomorphism operation. §36's
type keys are *not* used: they exist only for closed, non-wild types of application modules
(`check/TypeKeys.zig:20-28`, `682-688`; `check/Module.zig:432`), so neither core nor `Schema` nor a polymorphic
type has one. Across modules and the cache a place is named **structurally**: a block (§3.6) writes a place as
`(kind, head name as package·module·type, children)` and the reader re-interns it onto its own graph, which is
the same graph because both were built from the same definition. A cast (§2.13.9) compares places by this
structural identity. Opaque types are read through the interface's slots (thesis Change 9; R-5.7.1): the defining
module computes its opaque type's slots as the canonical paths of its representation type that may hold a cell,
numbered in canonical-path order, each published with its kind and the structural identity of what it holds; an
importer's opaque place has one child `⟨n⟩` per slot, so two slots are told apart without the definition.

**Canonical paths.** From a root place, a step sequence in which a place appears at most once: a step that
re-enters a place already on the path pops the path back to that place and appends `⟲` (if not already last).
`⟲` means *one or more levels below*. For `type Tree = Node Tree (List Int) Tree`: `#Node.1` is the root's list,
exact; `#Node.0` re-enters the `Tree` place and so is `⟲` — the subtrees of either side are one representative,
and `⟲#Node.1` is a list at some level below the root. Left and right are told apart only by `below`
materialisation at a match (§2.13.3), which is where the text names them. Length ≤ 2·|places|. Canonical paths
name symbolic cells (§2.2) and block entries (§3.6); `⟲` is what folds recursive values finitely (thesis §3.1).

### 2.2 Cells

`Cell = (origin, kind)`; kind from the place it is made at. Every cell labels one object per occurrence (the rule below).

| Origin | Meaning | Projection by `s` | Occurrence position |
|---|---|---|---|
| `site ι` | the object a literal, construction, copy, `Dict.empty ⊤` or lambda at ι makes, per activation | nothing (children) | singleton |
| `param πᵢ·q` | the object at canonical path `q` of parameter `i` on entry | `param πᵢ·(q·s)` canonical | singleton unless `q` holds `[*]` or `⟲` |
| `env x·q` | in a frame: the object at `q` of captured local `x` | `env x·(q·s)` | as `param` |
| `shared M.v·q` | the object at `q` of top-level `M.v` | `shared M.v·(q·s)` | as `param` |
| `result λ·k` / `esc λ·k` | the callee's `fresh k`/`esc k` at the frame's call ι, or `(ι·λ′)·k` when minted by the instantiation of a callback label λ′ (§2.11 item 6); a callee's own `result` cells are renumbered into its `fresh` at read-off | nothing | ordinary unless at a summary position |
| `cb j@λ·q` | what function parameter `j` returned at `q`; λ is this frame's own call instruction ι, or the interned pair `(ι, L)` referring to a callee label. Supplies are attached to the label; identity and the uniform summary/recursion fold are defined below. Explicit pairs are **not** a linear representation (§4.1). | `cb j@λ·(q·s)` | ordinary, or folded by the stated rule |
| `msg·q` | the message `update` receives, at `q` | `msg·(q·s)` | as `param` |
| `⊤` | an object the analysis cannot name | `⊤` (prefix-closed) | summary |
| `elem c·ι` / `others c·ι` | materialised: the one position of `c`'s `[*]` taken at ι, and the others | `proj(c,[*])·s` refined | singleton / summary |
| `level c·ι` / `below c·s·ι` | the node a constructor pattern at ι matched out of `c⟲` (its non-recursive arguments) / the levels under its recursive child `s` | likewise | singleton / summary |
| `loan c·ι` | `Ref.get` at ι: a loan of contents cell `c` (§2.13.7) | `c`'s, loaned | as `c` |

Symbolic origins (`param`, `env`, `shared`, `cb`, `msg`, `⊤`) stand for everything under them: projecting appends
a step. Concrete origins (`site`, `result`, `esc`) have their contents as children. A refinement has a `parent`
cell and a split ι; `base(c)` climbs to the first non-refinement. **The cells form a trie**: every symbolic cell's
parent is its path minus one step, every refinement's parent is the cell it refines, so the descendants of `c`
that the program ever named are enumerable (§2.8's deep demands; cost = the trie nodes under `c`).

**Labels and the fold.** An ordinary label is an interned `(call instruction, callee label id)` pair; a
direct callback call has no callee label. This records a call chain without copying its tail. Distinct labels
at distinct ordinary paths stay distinct: `wp f = pair f` preserves `.0` and `.1`. Merely finding two labels
with the same first instruction is **not** a fold trigger. Size never triggers this fold; exhaustion stops compilation (§4.4).

At read-off, a first instruction ι folds if any of its labels occurs under `[*]` or `⟲`, has a folded callee
label, or calls into the frame's own recursive group. Fold **every** label with first instruction ι throughout
`res`, κ, supplies (including supply keys), `refs` and the carried class table to `ι⋆`, joining their supplies.
This includes a supplies-only recursion such as `h f x = if p x then ⊤ else h f (f x)`. Thus no unfolded label
coexists with a folded label containing its chains. Refinement chains fold with their invocation labels.
Two occurrences of one label remain two occurrences of that label; the fold does not invent a comparison.
§2.10 alone translates an existing comparison between different labels into `within`.

This is exact identity within the stated abstraction, not a linear-size claim. Ordinary wrapper labels can
be exponential; each explicit label and its context is reserved against its **owning declaration's** resource
before creation (§4.4). No nested class gets a fresh allowance. A lazy view shares the actual template but
never silently merges two ordinary labels. Recursive folding includes dependencies through carried closure
environments (§2.10), not merely direct declaration calls.

**The one rule: a cell labels one object per occurrence; "many" is a property of a position, never of a label.**
Every occurrence of a cell at an ordinary path of a value in one activation denotes one object, and two occurrences
of one label in one value denote the same object or — when the label is folded (`⋆`, `⟲`) — possibly two objects
the fold merged: `sep(c, c)` is `shared` for an unfolded label and `lost` (approximate) for a folded one, never
an atom; no "summary cell" exists, and `fun(j).calls` decides nothing about identity (it serves once closures,
R-5.4.2, and the re-walk triggers). The places where one label stands for several objects are
exactly the **summary positions** — `[*]` (positions), `⟲` (levels) — and the folded labels `⋆`; at none of them
is distinctness ever *derived* from the label: whether distinct positions hold distinct objects is κ, computed at
every *store* by comparing the stored value's cells with the container's then-contents and carried as atoms (§2.9).
**Two different `cb j` labels are compared by instantiation, never by a predicate on the callback**: the atom
`sep(cb j@λ₁, cb j@λ₂)` is discharged where the actual's class is in hand (a call of the frame, or validation) by
interpreting two views of the actual's shared `res` template (§2.11 item 5) — its `π_k` by the supplies published for λ₁ and for λ₂, its `fresh k` by
`result (ι·λ₁)·k` and `result (ι·λ₂)·k`, its `env` by the closure's environment, its own `cb` by this rule
recursively — and running `apart` over the two instantiated cell sets. So a callback that returns fresh gives two
fresh cells, distinct; one that returns its parameter gives the two supplies, which are the caller's own cells and
may be one object (`h g x y = [ g x, g y ]` with `h (λl → l) x x`: both supplies are `site x` → `shared`); one
that returns a capture gives the same `env` cell twice → `shared`; `⊤` → `lost`. There is no "returns owned"
predicate: `need` and a feedback supply are discharged the same way, by instantiating the result and demanding
the cells it names (§2.11 item 5). The self-atom `within(λ⋆)` (§2.10) is discharged the same way too, as an `apart` over the instantiated cell
set in which a folded label counts as two occurrences: a `result (ι·λ⋆)·k` passes unless it is also reached through
a feedback supply (a result handed back and re-returned is a previous call's object); a supply the row marks
`taken` passes **under κ of its container at the supply's path** — two `taken` positions are two objects only where
the container is exclusive there (`twoAt g xs = ( g (traverseAt xs 0), g (traverseAt xs 1) )`, or `List.map` itself,
over `[ a, a ]` hands one object twice): `yes` passes, `and{…}` records `xreq`, `shared`/`lost` fails; a non-`taken`
parameter, a projection or refinement of a supply, an `env`, a `shared`, a `⊤` cell, or two labels of different
containers' elems that alias, fails; an instantiation that yields the caller's *own* `cb` label (a lambda calling a
captured function parameter) carries the atom forward to the caller's class, as every `sep` over arrivals is. **Instantiation denotes a least fixpoint over the label/supply graph.** The intended implementation is
§2.12's sparse propagation (labels are nodes, "the supplies of λ name λ′" the edges, cell sets pushed over the
condensed graph, a cycle's members sharing one set). A demand or `apart` must read the settled interpretation,
not an incomplete cycle. The dependency graph includes carried lambdas and their environments (§2.10–§2.12). Shapes are widened
(§2.3); split chains fold with the labels (`elem(xs·(ι_rec·(ι_rec·ι_t)))` becomes `elem(xs·ι_rec⋆)`).
Reserve new graph records before following their children. Finite monotone facts terminate at a fixed
inventory; §4.4 stops inventory growth. A proof dependency cycle cannot prove its own `sep`, `within`,
`need` or generativity claim. No demand reads an unsettled interpretation.

**Soundness.** A run-time object enters a value at an ordinary path once per
store, and each store is one occurrence of one label; the label of a callback's result is a function of the
concrete call chain, so two different unfolded labels never name one call; whether two calls' results are one
object is decided by instantiating what the callback returns under what each call handed it, which is exactly the
run-time question; a folded label admits that it may name two objects and is approximate. **Checked**: `twice f =
(y = f ⊤; _ = f ⊤; [ y, y ])` → `cb f@ι₁` twice → `shared`; `once f = f ⊤; dup f = (a = once f; [ a, a ])` →
`cb f@(ι·L)` twice → `shared`; `h f = (_ = f ⊤; f ⊤); k f = (a = h f; [ a, a ])` → one label twice → `shared`;
the recursive `h f n = if n == 0 then f ⊤ else h f (n − 1)` → `{cb f@ι₁, cb f@ι_rec⋆}` (the recursive call's
labels folded at read-off), each stored twice by `[ a, a ]` → `shared`/`lost`; `pair f = ( f ⊤, f ⊤ )` → `.0 =
cb f@ι₁`, `.1 = cb f@ι₂`, two labels; at a caller with `λ⊤ → [ 1 ]` two `result` cells → distinct, with `λl → l`
the two supplies (`⊤` here, crossing) → the caller's cells (precise); `h g x y = [ g x, g y ]` as above; a
deeper activation's result beside this one's (`List.push (g f (n − 1)) y`) → `cb f@ι_g⋆` under `[*]` against
`cb f@ι_y` → instantiated apart; a fold accumulator → the fold's recursion, likewise; a lambda capturing `a = f ⊤`
then `[ a, g ⊤ ]` → `env a ↦ cb f@ι` beside `cb f@ι` → `shared`; a returned closure `mk f = (a = f ⊤; λ⊤ → a)`
called twice by `k` → both instantiate to `cb f@(ι_use·L_a)` → `shared`. `mapHelp`: §2.12. (R-5.2.9, R-4.10.7)

**May-alias.** `alias(a, b)` ∈ {no, yes, under split ι}: `base(a) ~ base(b)`, where symbolic cells are `~` when
one canonical path is a prefix of the other (`⟲` matching any continuation), **except** that two paths diverging
at a `ctor` place on *different constructors* are alternatives and never `~` (one value has one constructor;
`π₂·status#Editing.2` and `π₂·status#Saving.1` are not a sharing of one argument, R-4.8.15; two *elements* built
with different constructors are two positions and are compared by `apart` at the construction); concrete cells
`~` when equal; `⊤` with everything; and when `a`, `b` descend from one split ι on different sides (`elem`/
`others`, `level`/`below`, two `below`s of distinct steps, two `level`s of distinct steps) the answer is *under
ι*; and when `a`, `b` are two `taken` `elem`s of one container from *distinct* splits (`elem(xs·ι_t)` and
`elem(xs·(ι_rec·ι_t))`: two positions read once each, O9) the answer is *under the container's κ*; the general
`under` rule: not aliases if the split's condition `κ` held at ι. A test that passes only *under ι* **relies** on κ(ι)
(§2.9): `yes` passes, `and{atoms}` passes and records `xreq`, `shared`/`lost` is the refusal `exclusive`.
`o/Split`'s `construction r: accepted param … xreq excl π1` is this rule. `alias` is the one relation every
holder test, `sep` atom and Disjoint reads; it costs O(path length) column reads.

**Materialisations in force.** A frame's `taken` set holds `(container cell c, split ι, κ(ι))` from a destructive
read (`taken`-worded supply or result, §2.13.6) until the write-back of a `focus` or the frame's end. While ι is in
force, a holder of `c` whole holds `others c·ι` and not `elem c·ι`: SRW's focus edits the summary node the
container stands for, so a pending operand holding the container (the recursive call's `a` in `mapHelp`) does not
hold the element handed to the callback. The frame then has `W` on `c[*]` if the element was written, and the
split's κ is `xreq`. Sound because the element is a distinct position of an exclusive container, read once by
the obligation on the callers of a `taken` primitive (§2.13.6, pinned).

### 2.3 Abstract values: shape nodes

Structurally interned per owning summary with deterministic comparison trees (thesis §4.2; Chase–Wegman–Zadeck). A node denotes a function from paths to sets of
`(cell, approx)`.

| Node kind | Fields | Meaning |
|---|---|---|
| `leaf` | `place`, `cells` | `cells` at `ε`; below, whatever the symbolic cells project to |
| `node` | `place`, `cells`, `children: [step → NodeId]` dense over the place's steps (`none` = nothing) | a built value |
| `delta` | `base: NodeId` (never a delta), `over: OverId` — a persistent sorted tree of `(step, NodeId)`, path-copied, O(log F) insert and lookup, structure shared along a chain of updates | the base written: at `ε` the base's cells, at `s` the override or the base's child; a chain of k updates costs O(k log F) |
| `recast` | `place`, `inner: NodeId` | `inner` read at another type (§2.13.9): `inner`'s cells, approximate, at every path |
| `union` | `left: NodeId`, `right: NodeId` (a binary DAG; never flattened) | the lazy join: `cellsAt` the union, `proj` the union of projections, both memoised per `(union, step)` |
| `cyclic` | a `node` whose child names an ancestor | a widened recursive value (§2.12); no special kind, the knot is in the table |

Operations, memoised on their node arguments:

- `proj(n, s)`; `cellsAt(n, q)` = `proj` along `q`.
- `reach(n)`: the **persistent** set of cells anywhere in `n` (an ordered tree with structure sharing, §3.2: union
  shares unchanged subtrees; a union pays for the source entries/set nodes it inspects, not only the cells it
  adds). `reach(delta) = reach(base) ∪ reach(overrides)`,
  `reach(union) = reach(l) ∪ reach(r)`, computed once per node; a chain of k updates adding k cells costs
  O(k log C) when each override contributes one cell and the unchanged base root is shared. General unions,
  including scans adding nothing, are charged by §4.1; this special case is not a union theorem. Membership O(log C).
- `join(n₁…nₖ)`: deduplicate, **group by base** (a bare node is `delta(n, ∅)`): one group of deltas over one base →
  one `delta(base, s ↦ join(overrides present, base's child))`, O(k + Σ|Oᵢ|) grouping work before recursive child joins and set unions; leaves with no children → one leaf with
  the set union; the groups left (one per distinct base, plus leaves) → a balanced `union` DAG over them,
  O(groups) outer nodes; inner work uses §4.1 accounting. A join can have product query work; a projection through a union costs O(groups) once per `(union, step)`.
- `put(n, s, m)`: `delta(n, [(s, m)])` when the `ε` object is the same after the write (an update), else a copy
  with one child changed (a construction's fresh base).
- `map(n, f)`: the functor relabelling cells, memoised per node, so a DAG stays a DAG (`w5`: 17 steps, #856).
- `leq(n, m)`, `eq(n, m)`: **coinductive** lockstep inclusion/equality, memoised per immutable-version pair with a **shape-only** coinductive assumption on
  entry (so cyclic nodes compare in O(|n|·|m|) pairs at most, O(|n| + |m|) when shapes agree).
- `widen(n)`: the place-graph quotient used by every fixpoint unknown and every read-off: a node whose descendant
  along a re-entering step sits at the same place is joined into that ancestor and the edge tied back to it, so
  a shape has at most one node per canonical path of its place graph. Over a non-recursive type it is the
  identity (no re-entering step), so `w5`'s DAG is untouched.
- `expand(n, bound)` (safety builds): the enumerated `(path, cell)` set up to `bound` paths, for §7.5.

**Approximation.** A `(cell, approx)` pair is approximate when it came through a `recast`, a joined `res` naming
two provenances at one path (`if c then [ 0 ] else xs`, R-5.1.4), a `⊤`, a conservative call, or a side of a
split whose κ was `lost`. A refusal resting on approximate pairs alone is approximate (R-6.3); an exact failure
wins. An empty set means *provably no cell* (thesis §3.4); `⊤` means any (O10).

**Invariant I-shape.** `γ(n)` = every value whose object at each path `q` is in `γ(cellsAt(n, q))`; every
operation above is extensive on `γ` (O3).

### 2.4 The state of a frame

A frame is a declaration body or a lambda body (oc §7.3):

- `Σ`: the **binding log** `(local, NodeId)`, append-only; a local is bound once and lexically scoped, so a `case`
  never joins states — only the arms' *values* join (§2.6); the log, `taken` and `pending` are popped to the mark
  taken at an arm's start. In-scope bindings at a point = the log segments of its enclosing regions (§2.5).
- `Esc`: the monotone set of `(cell, point)` escapes (thesis §3.4). **Escape is deep and directional**: escaping a
  node marks every cell in `reach(n)` (once per node, memoised); a cell is *escaped at p* when it or any trie
  ancestor of it (a symbolic prefix or a refinement's parent; concrete containment needs no link because escaping a node marks its `reach` eagerly) escaped at a
  compatible point before `p`. A *deep* demand (send, `consumed`, focus) is also blocked by an escaped descendant;
  a storage write is not (a callback keeping a list stored inside the accumulator does not refuse writes to the
  accumulator, R-5.2.5 #749). O8.
- `taken` (§2.2), `pending` (operands evaluated whose consumer has not run), `uses`, `demands`, `supplies` (each
  call of a function parameter: the point and the nodes handed, §2.11).

### 2.5 Regions and points

A **point** is an instruction index. `Regions.zig` reads the region tree off the BIR once: a region per `case` arm,
`let` body and lambda body (a frame boundary), with `start`, `end`, `parent`, its case, and for an arm its *guard*
when the scrutinee is `i == e`, a `method_call` of `eq` `Dispatch` resolves to `Int`'s (§2.13.15). Two points are **compatible** when neither lies in an arm of a
case the other lies in a different arm of (oc §7.2). "After `p`, compatible" is at most `depth` ranges, each a
binary search in a sorted use list (§2.7). The `withDefault (map m f) d` shape (R-4.2.3) is marked by the BIR
pre-pass (§2.12) as a two-arm region, so it has arms in this tree.

### 2.6 Transfer rules

`Transfer.eval(frame, inst) → NodeId`, one case per BIR tag, recording uses at the consumer (R-4.1.1) and demands
where §2.8 says:

| BIR tag | `A(inst)` | Uses | Demands |
|---|---|---|---|
| `local x` | `Σ(x)`; in a lambda, for an enclosing frame's local: the capture leaf `env x·ε` and `(x, ε)` added to the lambda's capture list | at the consumer | — |
| `field_access`, `tuple_index` | `proj(A(e), s)`; a lambda's capture is `(x, .f)`: per path (R-5.4.6) | at the consumer, kind `field` | — |
| `top`/`ext_value` (a value) | its summary's `res` with `shared M.v·q` for its own cells (§2.10); transferred `site`s under §2.13.11 | — | — |
| `top`/`ext_value` (function), `ctor`/`ext_ctor` (as a value) | a `closure` leaf `{site ι}` carrying the declaration's summary or the constructor's class (§2.13.1) | — | — |
| `int`, `float`, `char`, `string`, `chunk`, `interp`, `unit` | crossing (`∅`) | interpolated parts | — |
| `error` | `⊤`, operands escape | — | — |
| `list` (a literal) | `node(place, {site ι}, [*] ↦ join(items))`; κ per §2.9 | items at ι | — |
| a **spread chain** (§2.13.2; one BIR fact from `Lower`) | prepend or construction | items at ι | the construction (R-2.3) |
| `tuple`, `record`, constructor application | `node(place, cells, children)`; a record's cells `{site ι}` (R-4.8.1), a tuple's and constructor's `∅` | parts at ι | — |
| `record_update { r \| F = … }` | `delta(A(r), F ↦ values)`: the same object, written (oc §31.3) | `r` at every field but `F`, kind `field`; values at ι | `update` on `A(r)@ε` with `F`; nested updates are two (R-4.8.4) |
| `call` | §2.11; a call of a *function parameter* πⱼ at instruction ι: the result leaf `{cb j@ι·ε}` with the callee's class slot, each argument recorded as a supply `(j, k, node, point)` and used at ε, kind `call` | per the class `use`, kind `call` | call-site demands, edges |
| `method_call` | the dispatch table's callee as `call`; a nullary method is a call (R-5.1.7); a field of function type is a call of the field's value reading only that field (R-5.5.7); unresolved → unknown (R-5.5.4) | as `call` | as `call` |
| `type_dispatch` | `⊤`; every operand's cells join Esc (as a wordless `foreign`, O1) | operands | — |
| `lambda` (also `f a _`, which `Lower` makes a lambda, `Lower.zig:2725-2733`) | a `closure` node: cells `{site ι}`, child `◇ ↦ env node` whose children are the captured `(x, q)`'s nodes at creation; the body walked now as its own frame → the lambda's class (§2.10). **Captures**: a *field* capture `(x, .f…)` is a **read at creation**, kind `field` (hoistable: a closure created after a write of that field reads the old value through the hoist, R-3.2; created before, it holds the field's value, not the record, and is no use of the record, R-5.4.6); a *whole* capture `(x, ε)` is a holder, used wherever the closure is consumed (R-5.4.1). A body writing a capture makes the closure **once** (R-2.8): its creation is a demand on each written capture | field captures at ι; whole captures at consumption | once demands |
| `let`, `let_def`, `let_pattern`, `let_stmt` | the body; a `let_def` with parameters is a local function (a frame in the block's local group, §2.12); `let_pattern` a one-arm case; `let_stmt` consumes its expression | the value at the binding | — |
| `case`, `branch` | per arm: the pattern's locals bound to projections/materialisations of `A(scrutinee)` (§2.13.3); the arms' values joined | the scrutinee, kind `whole` | — |
| `try` (`e?`) | the payload projected; on `Result` the `Err` payload joins the result of the definition `?` returns from (R-5.1.6) | `e` | — |
| `markup` | a call of the markup row (§2.13.8) | its values | — |
| `schema_*` references | a schema member or constructor: the schema row (§2.13.10) | — | — |

Arguments are consumed at the call, items before the base is written (R-4.1.3); every forwarded result is a use
at that point (R-4.1.4).

### 2.7 Uses and liveness

A **use** is `(local, PathId, point, kind, callee-use-node?)`; kinds: `field` (this frame's own field chain,
record pattern or field capture — **hoistable**), `whole` (a scrutinee, a comparison at the root, a store, a
return, a send, a whole capture at consumption), `call` (an argument: the callee reads it at the paths its class
`use` names — recorded once as `(local, p, use-node U)` and answered lazily by projecting `U` along the queried
remainder; **never hoistable**, since the read happens inside the callee: R-4.8.2 bullet 4, R-4.8.7). Uses are
keyed by **path**, never by place (two fields of one record type share a place).

**The index** (`Liveness.zig`, §3.4a): per `(local, PathId)` the uses sorted by point, and per path the *subtree*
list (uses at or below it, each use entered at its ancestors: depth entries per use); per local its last use.
Queries at a demand point `p` for holder `(h, q)` of cell `c`:

| Query | Lists | Answer |
|---|---|---|
| a use of `h` at an ancestor of `q` or at `q`, after `p`, compatible | `(h, q')` for each prefix `q'` of `q` | a whole use (`later-use`/`alias`); a `call` use counts the same when its node `U` is non-empty at the remainder of `q`, or (record demand) at `q·f` for some `f ∈ F`; a `call` use non-empty only at untouched fields is no use |
| a use under a written field `f ∈ F` (record demand) | subtree of `(h, q.f)` | kind `field` → a **hoist**; kind `call`/`whole` → a whole use, refused |
| a use under `q` (list demand) | subtree of `(h, q)` | a use |
| an untouched field's use | never read | — |

Cost per query O((depth(q) + |F|) · depth(regions) · log U). `R-4.8.2`'s untouched fields cost nothing.

### 2.8 Demands and the check

A **demand** is `(point, kind, base NodeId, F, operands, pending, deep?)`; kinds: `writer` (R-2.1, R-2.4, R-2.12),
`construction` (R-2.3), `append` (R-2.2: one demand per `++` chain with the leftmost base), `update` (R-2.5),
`callsite` (R-2.6), `send` (R-2.9, deep), `once` (R-2.8), `entry` (R-2.10), `consumed` (R-2.11, deep), `focus`
(R-2.12).

**Resolution** (`Demands.zig`), after the frame's index exists, in evaluation order, for each `c` in the demand's
**cell set** — `cellsAt(base, ε)` for a shallow demand; for a *deep* one (send, `consumed`, focus) `reach(base)`
together with the trie descendants of its symbolic cells, so a concrete container's contents (`inner` inside
`ys = [ inner ]`) and a parameter's fields (`param π₂·.a` under `param π₂·ε`) are both demanded — approximate
`⊤`-like pairs whose kind may be the base's included, in cause-precedence order (R-4.3.6):

1. **Known**: `c ≠ ⊤`; not a `loan` where a loan may not be written.
2. **Unescaped**: `c` not escaped at `p` per §2.4 (ancestors; for a deep demand descendants too); not `shared`
   (`top-level`, position); not the model of `view`/`subscriptions` (`read-only`).
3. **Not captured**: `c` is not an `env` cell written outside its once closure's frame (`captured-edit`).
4. **Disjoint**: no other operand, no other path of the same argument, no cell of the callee's environment aliases
   `c` (R-4.3.2, R-4.3.4, R-5.1.5); for `update`, no new field value holds `c` whole (R-4.8.3).
5. **Dead**: no pending operand holds `c` at a path its consumer touches (`held-operand`); no live holder of `c` is
   used after `p` compatibly at an overlapping path (`later-use` the base's own variable, `alias` another local,
   `captured` a closure, `element` when the only live holders hold `c` at an unmaterialised `[*]`).
6. **Exclusive** (§2.9), after Dead so a live holder is named first (R-4.6.1).

**Holders of `c` at `p`** come from the frame's **inverted index**, never from a scan of the scope: every
**live** persistent-set node (§3.2) whose key is a cell is chained from that cell (a column of `Cell.Table`,
`set_head`, with `prev`/`next_same_cell` on the set nodes: dense ids indexing columns, not a map) — a node is
linked when its live count goes 0 → 1 and unlinked when it returns to 0, so a dead or never-registered node is
never in a chain — every set node keeps its live parent links with a live count, and every holder — a binding, a pending operand, a capture — registers on the
root of its node's `reach` set. A holder **expires** at its last use (known from the index) during the
evaluation-order sweep — **after** the point's own result has been registered, so a result whose `reach` shares its
operand's set nodes keeps them live across the hand-over (`mₖ = { mₖ₋₁ | f = [ k ] }`: `mₖ`'s root is registered,
then `mₖ₋₁` expires; the shared subtree never drops to 0 and is never relinked, O(log) per step, not O(k)) — it is
unregistered, and a root with no holders decrements its children's live counts
recursively, so a set node with no live parent is skipped. `holdersOf(c)`: for `c`, its trie ancestors and (deep
demands) its trie descendants, walk the chain of set nodes keyed by that cell and climb their *live* parents to
the roots. Every set node visited is live and contains the cell (the chains hold live nodes only), so no dead scope is scanned. A DAG can nevertheless have many live parent routes to the same holder;
use a query-local stamped visited column and charge every inspected live edge (§4.1). Maintenance is O(nodes whose live count changes) per
registration or expiry, each node once per transition: at `bₖ = List.push aₖ 0` with N other bindings live, only `aₖ`'s set contains `site aₖ`, and a chain of
k record updates finds only `m_{k−1}` once `m₁…m_{k−2}` have expired. Then, for each holder, the paths at which it
holds the cell (a pruned walk of its node guided by `reach`), and §2.7's queries. Cost per demand includes the live parent edges, holder-path visits and queries actually inspected;
§4.1 bounds their module total. Distinct routes to one root are visited once per query. The second review's `ys = r.a` then `send (Got r)` is found: `send` is deep, `param π₂·.a` is a trie
descendant of `param π₂·ε`, `ys` holds it and is used after → refused (R-5.9.1).

**Verdicts** (R-0.3): `accepted` {`fresh`, `call`, `param`, `callback-param`, `once`, `entry`}; `pending detail`
(§2.11); `refused cause` per R-6.3, exact/approximate/position by the pairs it rested on; among failing holders
the one used first, ties to the earlier binding. The result of every writer, construction, append and update **is
its base's object** (R-0.1, R-4.10.1): a `delta` or the base's node, so the next holder is the new version.

### 2.9 Conditions: exclusive contents

Each node `n` carries a **condition** κ(n), a column of `Cond` keyed by `NodeId`: whether the objects at `n`'s path
are exclusive — **per path**: for a node under a summary position (`[*]`, `⟲`), κ(n) says *across positions, the
cells at this path are pairwise apart, and within a position this node's deep condition holds* (thesis §3.11
conditions 1–2; condition 3, no live outside holder, is Dead at the write: oc §18.2). So keys at `acc[*].0` and
values at `acc[*].1` have separate conditions, and a write at `.1` relies on κ of the node at `[*].1` only
(R-4.6.4, `o/Beside*Helper`). The kind filter of R-8.6 reads only cells of the written kind.

| κ | Meaning |
|---|---|
| `yes` | holds |
| `and(κ₁, κ₂)` / an atom | an interned binary conjunction (O(1) to form; a chain of W stores creates O(W) outer nodes); semantic conjunctions are deduplicated atom sets in fixpoints; flattening, including overlap visits, is charged by §4.1 |
| `shared` | fails exactly: one cell at two positions or two paths (`[ r, r ]`, `{ a = xs, b = xs }`, a taken element stored back) |
| `lost` | fails approximately: `⊤`, a conservative call, a spread of a variable after the base (R-4.6.1), a recast, a pessimistic class |

Atoms name **arrivals only** (parameters, captures, callback results, the cells under a summary position of one):
`excl c`, `sep c d` (also between two `cb j` labels, discharged by instantiation), `apart{c₁…cₙ}` (every `sep` over a set, stated
once), `keep cb_j` (the callback puts back what it was handed, at the same path, or a fresh value: "keeps shape"),
`writes cb_j`.

`sep(a, b)`: two concrete cells, distinct → `yes`; an unfolded cell twice → `shared`, a folded one (`⋆`, `⟲`) twice
→ `lost` — unless the pair arose from a fold of two different labels, which is the self-atom `within(ι⋆)` (§2.10)
(§2.2's one rule); two *different* `cb j` labels → the atom `sep(cb j@λ₁, cb j@λ₂)`, discharged by
instantiation (§2.2); `⊤`/approximate → `lost`; two other arrivals not aliasing → the atom `sep a b`. A construction sorts its
stored cells once: duplicates decide at once (`shared`), the arrivals among them form one `apart` group;
discharging an instantiated `apart` is O(n log n) only when identity/ordered-prefix tests settle it in one
sort. General supplies, overlapping paths or split conditions require additional comparisons, individually
charged by §4.1. Unresolved arrivals form one `apart` of the caller's own (#693, `ListOfParams`), not an
eager quadratic array of `sep` atoms.

Where κ is set: a literal `[ v₁…vₙ ]` → per element path `p`: `and(deep of each vᵢ at p, apart{cellsAt(vᵢ, p)})`;
a record, tuple or constructor literal → `apart` over its field values' cells at every two distinct paths (I-κ's
two-paths clause: `{ a = xs, b = xs }` is `shared`);
a construction → the base's κ lowered by each stored value (`apart{stored, base[*]}` and the value's deep
condition), a later spread of a *variable* `lost`; a call → `κ(res)` instantiated (atoms over `πᵢ·q` become the
argument's deep condition at `q`, `sep` the two arguments' separation, `keep`/`writes cb_j` the actual class's facts and a `sep`/`within` over labels by instantiation: oc §18.4); a `delta` → the base's κ lowered by the new field values; a storage permutation
(`swap`, `sortBy`, `insertAt`, the `List` writers) lowers nothing (R-4.10.11); a `recast`, `⊤`, `List.append`
by name (`xs ++ []`/`[] ++ ys` copy) → `lost`; a split on a container with κ keeps κ on `rest` and records κ on the
split (§2.2); `List.copy`/`Dict.copy` keep value conditions and separate storage only (R-4.10.9).

Where κ is relied on (oc §18.4): a callback writing what a destructive read supplies (`List.update`, `map`'s
element, `Dict.focus`, a `taken` element); the split then a write of the taken part (R-4.5.3); a callee's `xreq`;
a recursive update of every level (`incAll`, R-4.7.5, R-4.7.8); a `below` written while a `level` of the same split
is read (the one `level (a)` case left, R-4.7.2). Relying on `yes` records nothing; on `and{…}` records the atoms
as `xreq` of the frame's class, discharged by every caller (R-4.6.6); on `shared`/`lost` refuses `exclusive`.

The R-8.2 rows: `[ p, …_ ] → [ …l, p ]` stores `elem(l·ι)` into `l` whose `[*]` holds `others(l·ι)`, both
refinements of one base → `shared` (R-4.6.9, `p/PatternStoredBack`); `List.update … 0 λ_ → xs` stores a cell the
container's `[*]` already holds → `shared` (R-4.6.10, `p/UpdateReturnsHeld`); `List.push (List.push [] [1]) [2]`
stores two singletons → `yes`, and `List.update … λl → List.push l 9` relies on `yes` (R-4.6.7,
`p/ExclusiveFreshHelper`); `[ xs, List.copy xs ]` two distinct cells → `yes` (R-4.6.8, `p/CopyApart`); `Dict`
twins through `insert`'s `stored` word (R-4.10.12, R-4.10.13).

### 2.10 Classes and summaries

A **class** describes a function type's behaviour (thesis §4.7); a **summary** is a declaration's class. Over
`π₁…πₙ`, `ρ`:

| Field | Content |
|---|---|
| `use(i)` | a shape over πᵢ's places labelled `{R, A, E, W}` plus `W`'s field set `F` and deep flag `S`; `unused` where nothing is named |
| `res` | a shape over ρ's places whose cells are provenances `πᵢ·q`, `fresh k`, `esc k`, `shared`, `cb j@λ·q`, `⊤`; `fresh` numbered after solving by canonical result path of first occurrence (two sites at one path may share a number, adding aliasing only; κ is published, not re-derived; inference uses stable allocation/port keys) |
| `κ` | per `res` node, atoms over arrivals (a parameter's own `excl` implicit) |
| `xreq` | the atoms the body relied on |
| `fun(j)` | `calls ∈ {0, ≤1, many}`; `supply(k)`: nodes handed as πⱼ's `k`th argument with `owned`, `taken` and κ; `need`; `seen`; `keeps`: the keep edges of §2.11 |
| `classes` | **a summary-local class table**: every `closure` node in `res`, `supply` or `use` (a lambda returned, a lambda handed on, a closure in a record) carries a `ClassId` into it, in normal form, serialised with the block (R-5.4.8, R-5.4.9, R-5.5.9); the fixpoint joins classes pointwise |
| `refs` | the `◆` cells of `Ref` places the body operates on, by provenance (`Ref.set/update/modify/get` directly or through a callee), for §2.13.7's re-entry rule |
| `writes` | one bit: the body or a callee has `W`/`S` on a parameter path, a capture, a `shared` cell or lets one escape — a write of something that *arrived*; a `Builder`'s fresh stores do not set it (R-5.13.1) |
| `once` | per function-typed result place; exhaustion is a terminal error, never a published class |

**Lattice.** Pointwise (closure code/port identities fixed by the rule below): bits by inclusion; provenance shapes by `leq` (the lower order, `fresh k ⊑ esc k ⊑ ⊤`,
thesis §4.6) **after widening** (§2.3), so a shape ranges over at most one node per canonical path and the
shape structure is finite at a fixed inventory (§2.12); growth is guarded by §4.4; `owned ⊑ borrowed`; `calls 0 ⊑ ≤1 ⊑ many`; κ: `yes ⊑ and{A} ⊑ and{A ∪ B} ⊑ lost`, `shared`
beside `lost` and winning as a cause; classes pointwise over the stable code/port graph below. `shared` records a definite witness, never a
stronger acceptance; a limit is outside this lattice and aborts inference.

**Carried classes and recursion [O 2026-10-25].** A callable is `(CodeId, EnvId)`: lexical code ids are
assigned before inference and never contain captures. Every code has fixed capture-slot names. An environment
is a graph of original-origin values and callable edges, including returned/supplied lambdas, known projected
classes and partial applications. Different code layouts remain different alternatives, even at one function
type. Unknown is `⊤call`, never an empty environment.

1. An ordinary context is an immutable invocation/receiving-port chain. Ports are static result, supply or
   capture slots projected on §2.1's canonical place graph; they are not paths through a freshly unfolded
   environment and contain no round number. Keep distinct ordinary chains, including two uses of the same
   code: `wrap k = λx → k x; a = wrap base; b = wrap a` has two ordinary contexts. Reserve each new context,
   port, class alternative and environment edge under the enclosing declaration's account **before** visiting
   its children. The ordinary occurrence DAG may be exponentially large; §4.4, not a false linear claim,
   guards that inventory.
2. A backreference is allowed only on a genuine **summary-variable dependency cycle**. Before quotienting a variable is `(ordinary root/context, lexical frame, static result/supply/capture/condition
   port)`, so two acyclic uses of `wrap` have different variables. A call into the enclosing recursive declaration SCC with its participating input/output dependencies, or
   a dependency back to an already active variable, witnesses the recursive segment; only that segment may
   be quotiented. Variables name a
   lexical frame's result, formal supply, capture slot or condition port; dependency edges say which variable
   is read to compute another. Include edges through callable actuals and carried environments, and a lambda's
   enclosing declaration SCC. Discover edges before expanding the dependency they name, including a deferred
   call once its actual code is known. Re-entry to an active summary variable is a cycle witness; an SCC of
   these edges is the equivalent batched test. Repeated CodeId or repeated function type alone is no witness.
   Thus `grow`'s returned wrapper capturing the recursive result closes a dependency even with zero callback
   labels; `h → wrap → lambda → h` closes through h's enclosing frame. No source-name test or context-depth
   threshold is used. Dependency search steps and the stack are charged records (§4.1).
3. Within that dependency, re-entry to `(CodeId, canonical closure port)` under the **same preserved ordinary
   outer root** ties an edge to the existing recursive slot; join corresponding capture slots and code
   alternatives. Collapse the recursive segment only, not its ordinary prefix or siblings. If a dependency is
   discovered after provisional nodes exist, join their facts into the representative and rewrite references
   uniformly; retain the old records in the account. Splits and callback labels use §2.2's uniform fold in
   results, supplies, κ, refs and **all** carried classes. A stored duplicate never becomes `within`.
4. Calling a closure substitutes its **original** captures. Only allocations evaluated during this invocation
   acquire its fresh identity. Captured callback results, recursive results and feedback supplies do not become
   fresh by crossing a class backreference. Solve may-origins, environments, alternatives, use/escape bits and
   obligations to a post-fixed point before judging any write; then validate against that same point. An
   unresolved recursive proof edge is not `yes`: a finite independent base/step certificate must discharge it
   (§2.12). Graph encoding uses explicit backreferences (§3.6).

The recursive quotient can join captures from different recursive activations, yielding `lost` at a demanded
write. This is the stated recursion abstraction, not exhaustion coarsening. A producer of a shared closure is
legal. Copy its returned list at the eventual write if needed; copying a closure or its outer container does
not copy captures. Appendix B fixes the fresh/alias `grow` answers and the existing carried-recursion sites.

**Read-off** (oc §16.3): `W` at `(i, q)` when a demand's base cells include `param πᵢ·q` (verdict irrelevant); `E`
from Esc; `A` from `res`; `R` from uses; `res = widen(map(A(body), f))` with `f`: `site`/`result` → `fresh k`/`esc k`,
`param` → `πᵢ·q`, `env` → `env x·q` (a lambda's class), `shared`/`⊤` kept, `cb j@λ` **folded uniformly by first instruction** (§2.2's trigger, applied over `res`, the κ
atoms, every supply and every class of the class table at once), each folded label carrying the union of its
labels' supplies; **a fold that merges the two sides of an atom `sep(X, Y)` (X ≠ Y, both into `ι⋆`) produces the
self-atom `within(ι⋆)`** — *the calls `ι⋆` stands for return pairwise distinct objects where they were compared* —
whereas two occurrences of one folded label stored from one value stay `lost`; a refinement in `res` → its
base's image, approximate, but a `taken` supply keeps its `elem(πᵢ·λ)` with its split's label; `fun(j)` from the recorded supplies and keep edges; `classes` from the closure nodes reached. A
parameterless value: `res` with each cell its definition makes as `shared M.v·q` at its path (R-4.9.2).

**Room for #587.** A class names no declaration and lives in a class table a summary owns; a `closure` place has a
class slot (§2.1). #587 attaches an inferred class to every function type and copies it through `Instantiate` as
effect classes are; `Calls` changes only where it looks the class up. An in-place shared cell type is a
`ref`-kind place with rows like `Ref`'s (§2.13.7).

### 2.11 Calls

`Calls.apply(S, args, actuals, ι) → (result, obligations)` for a callee of class `S` (oc §16.4 as meaning):

1. **Uses**: an argument `x.p` is used at `(x, p, U = S.use(i))`, kind `call`; a temporary's closures have their
   whole captures used.
2. **Pending operands** hold the demanded cell only at paths the call touches.
3. **W**: per `(i, q, W{F}, S?)`, a `callsite` demand on `cellsAt(aᵢ, q)` (Disjoint against every other argument,
   every other path of `aᵢ`, and `S`'s environment cells: R-5.1.5).
4. **E**: `cellsAt(aᵢ, q)` escape deeply. **Callbacks**: per function-typed πⱼ, the actual's classes (a lambda's,
   a top-level function's, a constructor's, a class in a summary's table, the caller's own parameter → the caller's
   `fun` gains `S.fun(j)` translated; none → `⊤`): the **supply edge** (the actual writes its `k`th parameter where
   `S.supply(k)` is borrowed → `supply`; owned with provenance `πᵢ·q″` → a `callsite` demand on `aᵢ` at `q″`; `cb j′`
   → the actual for πⱼ′'s result is instantiated and demanded, item 5), **need**, **keep** (below), **seen** (an actual writing a parameter handed
   where `S` loses sight → `pending`, R-5.5.3).
5. **What a callback's result is**: wherever the callee relies on what its callback returned — a `need` (it writes
   the result), a feedback supply (it hands the result back), a `sep` between two of its labels, a store into an
   exclusive container — the actual's `res` is instantiated as in item 6 under the supplies published for that
   label, and the demand or `apart` is run on the cells that come out: fresh cells pass, a supplied cell is a
   `callsite` demand on the caller's argument (oc §16.4 CK-233), an `env`, `shared` or `⊤` cell fails. No
   predicate "returns owned" exists; what used to be it is this instantiation (thesis §3.7's atom, made concrete).
   **Representation, without eager copies.** For one call and one actual-class alternative, prepare the
   actual's `res` once as a template with a symbolic invocation label **and** a symbolic supply environment.
   Each callee callback label selects a view `(template, invocation, supply-environment)`; it does not copy the
   result graph. A projection interprets only the requested node/path. Memoise by the full
   `(template-node, invocation, supply-environment, path)` context (a context id may subsume these fields), never
   by the template node alone. `fresh` and `esc` receive the invocation identity; parameters graft the selected
   supplies; captures and `shared` retain their original identity. A nested callback's actual class may depend
   on a supply, so that lookup is deferred too. `need`, `sep`, `within`, carried classes and feedback use this
   same interpretation, with feedback settled before reading a result. There is no "fresh means apart" shortcut
   for two occurrences of the **same** invocation.

   Setup costs one template plus constant-size view records, rather than labels × template size. This is an
   exact sharing of substitution, not a coarsening. It does **not** establish a linear total: the number of
   demanded contexts and comparison pairs is instead guarded by the one summary-size resource (§4.1, §4.4). Deep conditions, `reach`,
   read-off and block writing must not silently force every view. They use the same charged operation graph; neither a deep walk nor block encoding may expand uncharged work.
6. **Result**: semantically `map(S.res, inst)`, interpreted by the views in item 5: `πᵢ·q ↦ proj(aᵢ, q)` (grafting), `fresh k ↦ result ι·k`, `esc k ↦ esc ι·k` (escaped),
   `shared`/`⊤` kept; a callee's `cb j@L·q ↦` the actual's `res` with its `π_k` replaced by the supplies published
   for `L`, `env` by the captured nodes, its `fresh k` by `result (ι·L)·k`, and a `cb` of the actual's own function
   parameter by this rule recursively — one `result` cell per label, so `pair f = ( f ⊤, f ⊤ )` yields two objects
   at the caller when `f` returns fresh and two `shared` cells when `f = λ⊤ → shared`; when the actual is the
   caller's own function parameter `j′`: **`cb j′@(ι·L)·q`**, a new label whose supplies are `L`'s instantiated,
   whatever the callee's `calls` — so `k f = (a = h f; [ a, a ])` stores one label twice and is `shared`; a
   lambda's class whose body calls a captured function parameter `f` at ι_in publishes `cb f@ι_in`, which a call of
   the lambda at ι_c instantiates as `cb f@(ι_c·ι_in)`; a feedback supply is a fixpoint (§2.12); a class carried in `S.classes` keeps its `cb` cells over the callee's
   parameters **deferred**: the closure's `◇` env holds the actual's node, and a later call of the closure at ι_c
   instantiates `cb f@ι_in` through that env as `cb f′@(ι_c·ι_in)` or `result (ι_c·ι_in)·k` — never eagerly at
   the call that returned the closure, which would mint one cell for every later call; a closure node in `res` carries its class from `S.classes`
   instantiated the same way. Crossing → `∅`.
7. **Conditions**: κ(res) instantiated; `S.xreq` discharged on the arguments, reported on that call's line (R-4.6.6).

**Calling a function parameter** πⱼ in the body (the rule v1 lacked where #982, #1000, #1001 lived): the result is
the leaf `{cb j@ι·ε}` (ι the call instruction, §2.2); each argument's node `Nₖ` is recorded as a supply `(j, k, Nₖ, p)`, its cells used at `ε`.
**Keep edges**: after the walk, for every supply `(j, k, N, p)` and every later compatible demand in the frame with
`W` (own or `callsite`) whose base cells alias a cell in `N` — the written cell equal to or a trie descendant of a
cell in `reach(N)` (the keeper may hold the parent or the part), or a trie *ancestor* of one only when the next
step of the kept path is a written field (`b = f o.inner; { o | y = 3 }` writes `o` at `y`, off the kept path
`.inner`, and records no edge: a keeper of one field with a write of another is accepted, R-4.8.13, R-5.2.4); a
list storage write never counts against the elements it holds — record `keep(j, k, path of the cell in N, written
path)`; `supply(k).owned` is decided by Dead at
`p` as for any demand. At the caller: an actual whose class may hold its `k`th parameter at a path aliasing the
kept path in its result (`res` names `π_k·q` with `q` overlapping, or `cb`, or `⊤`) is refused `supply (a)` at the
function value supplied (R-4.8.11, `p/RecordKeptInLiteral`: `f [ r ]` supplies a fresh list whose `[*]` holds `r`,
so the kept path `[*]` and the written `r` alias through `reach`; `p/RecordInnerKept`: the write through
`i = o.inner` is a demand whose cell is `param o·.inner`, a trie descendant of the supplied `param o·ε`); a known
non-writer discharges a keep whose only possible writer is another function parameter (R-5.2.4); a record written
*before* it is handed and returned beside the kept answer records no edge (`p/RecordWriteBeforeKeep`, R-4.8.11).

**Function values** (R-5.5): read off a node's `closure` cells: a lambda's class, a summary, a constructor's class
(§2.13.1), an alias chain of any length (the pre-pass, §2.12), a class from a summary's table (a returned or
carried lambda), several (joined, R-5.5.5), a `Send` (§2.13.5), none → `⊤call` (R-5.5.4). `f a _` is a lambda
(`Lower.zig:2725`) and needs no rule of its own: its class is read off its body, its captures are per path, and
R-5.5.2 and R-5.4.5 follow from the lambda rules.
For `both r = (r.run ⊤, r.run ⊤)`, when `r` is a record parameter with no class known for `.run`, each field
call is `⊤call`, not a fresh callback label: v2's `cb j` protocol currently describes a function parameter,
not an unidentified function in one of its fields. The result may alias either call's answer, an argument or
the closure environment, so no distinctness follows from the two call sites; a write through it is
`unknown (a)`. The ordinary unknown-call uses and pending obligations still apply. This is sound but less
precise than tracking the field's callback protocol. A known lambda or carried class projected from a record
still follows the known-class rule; record syntax itself does not erase a class (R-5.5.7). This is a statement
of v2's rule, not of v1: `Ownership.zig:14150–14166` has a `slotOf` branch for parameter fields, and
`15288–15303` resolves a field call before falling back to unknown.
 A writing function value leaving sight is **pending** at that
point, naming where (R-5.5.3), except a top-level alias of a writer (R-5.5.6).

### 2.12 Fixpoints and the pre-pass

Two instance shapes, one driver (`Fix.zig`). Both use finite inventories guarded by §4.4,
with no round cap (R-7.4, R-5.6.3), and the charged operation graph of §4.1:

| Instance | Unknown | Shape | Step |
|---|---|---|---|
| a recursive group of declarations (R-5.6.1) or a block's local functions (oc §18.7) | each member's class | **worklist over frames, cells by propagation**: a walk of a member records, beside its shape, the inclusion edges a recursive call makes (argument node → callee parameter path, callee result path → call result); the cells then flow along the whole group's edges by the sparse propagation below, so growing cell sets never cause a re-walk. The `R`/`A`/`E`/`W` bits (with `F` and `S`) flow along the same edges in the other direction (a callee's `W` at `π_k·q` becomes `W` on the argument node's cells at `q`, hence on the caller's parameter path they came from), and so do the `callsite` demands they imply, so `rot a₁ … aN n = … rot a₂ … aN a₁ (n − 1)` records N edges once and its `W` reaches every parameter by propagation, not by N re-walks. After propagation the frame's resolution sweep (§2.8) runs once over all demands, the propagated `callsite` ones included, and reads off `supply.owned` and the keep edges, which depend on it. A member is re-walked, in the SCC's reverse postorder reading the latest assumptions (Lean 263-326; Roc's queue), only when a callee's facts of *shape* changed: `calls`, `need`, `seen`, a `supply.owned` bit or a keep edge (monotone: owned → borrowed, edges only added, bounded by the callee's own supplies), κ's atoms, a class's structure, a `res` node's shape (cells arriving at an existing node are not a shape change) | `xᵢ₊₁ = widen(xᵢ ⊔ F(xᵢ))` per member; cells and bits by propagation; owned/keeps by the sweep |
| a callback fed its own result (R-5.3.2, `Dict.merge`'s cycle R-5.3.6) and the entry's model (§2.13.4) | the `cb`/`M` node and its κ | **sparse propagation over per-path inclusion edges** (Morphic I:114-171): the step's `res` is read once as edges `source path ⊆ target path` (a `delta` over π₂ gives one edge per override; `π₂.f_{k-1} ⊆ π₂.f_k` for the rotate family); the edges' graph is condensed into SCCs and the cells are pushed along it in topological order with persistent sets, so each cell crosses each edge once and a set that grows by one shares the rest | push the difference, never re-instantiate the whole |

**Termination.** At a fixed inventory, each may-membership, edge, code alternative and use bit is added at
most once; each guarantee only weakens in its finite order. Conditions use a finite set of atoms over those
inventory ids: `and(A,A)=A`, no new syntax nesting each round, and `apart` groups are canonical persistent sets.
Finite slots and ids imply a finite possible atom inventory (not a linear one). Dependency SCCs use §2.10's
backreferences. Facts are processed by deduplicated `(edge, fact)` deliveries or immutable-root union tasks;
a newly discovered edge receives existing facts once. No update is lost because a task saw an earlier root.
Thus a fixed inventory has finite monotone height and a fair worklist terminates. If inventory or operation
records continue growing, reserving record L+1 stops **before** its work (§4.4). This proves that every input
finishes or reports the named limit, including polymorphic recursion through carried classes, without a round cap.

**Recursive proofs.** May-facts begin empty only for inference, never for acceptance. A recursion in a Boolean
proof request has status `waiting`, not `proved`. After may-facts settle, build a finite obligation graph.
A recursive invariant is established only by an independently checked base and a preservation check with its
explicit invariant assumption (for example owned initial accumulator plus `keep`, or fresh allocation on every
returning alternative). Merely traversing a cycle discharges nothing. Every outgoing capture/feedback/unknown
alternative must satisfy the obligation. The validation walk checks the certificate and `F(x) ⊑ x`; a residual
unjustified cycle fails the demand approximately, not by accepting the initial empty facts. This proof graph and
validation work are part of the same account; coinductive shape equality is not a separation certificate.



Every component is joined round to round, κ included: a `sep` between two `cb j` labels is an atom inside every
class, discharged only by instantiation where the actual's class is in hand (§2.2), so nothing a round reads off
depends on an assumed `calls` and κ is monotone. `mapHelp`
re-derived: `put b i (func (traverseAt a (o + i)))` stores `cb₅@ι` (this activation's one call) into `b` whose
`[*]` holds `π₆[*]`; round 1 reads off κ(res[*]) = `apart{cb₅@ι, π₆[*]}` = `sep(cb₅@ι, π₆[*])` (an atom over two
arrivals) and `res[*] = {cb₅@ι, π₆[*]}`, published under `[*]` as `cb₅@ι⋆` with its supply `elem(π₁·ι_t)`; round 2's
recursive call at ι_rec instantiates the callee's `cb₅@ι⋆` as `cb₅@(ι_rec·ι⋆)` with supply `elem(a·(ι_rec·ι_t))`,
so the store compares this activation's `cb₅@ι` (supply `elem(a·ι_t)`) with the deeper activations' label — two
different labels, never the same call — giving `sep(ι⋆, ι_rec⋆) ∧ sep(ι⋆, π₆[*]) ∧ sep(ι_rec⋆, π₆[*])`.
Round 3 instantiates the callee's `sep(ι⋆, ι_rec⋆)` at ι_rec as `sep((ι_rec·ι⋆), (ι_rec·ι_rec⋆))`, whose two sides
fold into one `ι_rec⋆`: the fold emits `within(ι_rec⋆)`, so κ(res[*]) = `sep(ι⋆, ι_rec⋆) ∧ within(ι_rec⋆) ∧
sep(ι⋆, π₆[*]) ∧ sep(ι_rec⋆, π₆[*])`, stable (round 4 re-folds to the same atoms). `List.map xs f` is one call of
`mapHelp` at ι_m, so its published κ folds both labels to `ι_m⋆` and the `sep` into `within(ι_m⋆)` with every
supply a `taken` elem of `xs`. At a caller `within` is discharged by instantiation under κ: `λl → List.push l 1`
returns its `taken` supply, two positions of `xs` apart *under κ(xs[*])* — `List.map xs λl → …` keeps `xs`'s
exclusivity (R-4.10.2's "elements keep identity") and `List.map [ x, x ] λl → l` fails it (κ `shared`); `λ_ →
[ 1 ]` gives a fresh `result` per call, pass; `λ_ → shared` fails — so `List.map xs λl → …` is exclusive and
`List.map xs λ_ → shared` is not. `twice`'s `[ y, y ]` stores
`cb₁@ι₁` twice: `shared`, so `List.update (twice λ⊤ → [ 1 ]) 0 λl → List.push l 9` is refused `exclusive`
(`p/CallbackResultTwice`, a red twin to write). Validation: one more walk against the final assumptions must read off
`F(x) ⊑ x` (coinductive `leq`) and is the walk whose demands are reported. Inside a group use stable allocation/port keys, not first-discovered numbers. Final fresh numbering is
canonical by result path only after solving, with a simultaneous rewrite of all references; it never feeds
another inference round. `go n t = … go (n − 1) (Node t [ n ] t)` grafts
one level per step without widening; with it, `res` is the cyclic `Node(self, {fresh, π₂·#Node.1}, self) ∪ π₂` after
two steps. Polymorphic recursion (R-5.6.2) adds nothing: a call at another type grafts through `proj`/`recast`.

**The BIR pre-pass** (`Prepass.zig`, L3, reads the BIR, the dispatch table and the graph): SCC edges = `refs` ∪
the callees `Dispatch` resolves for `method_call` (BIR adds no `refs` edge for them, `Bir.zig:329-330`) ∪ derived
`eq`/`compare`; alias chains of function values (R-5.5.6); read counts of private parameterless values (R-4.9.3);
the enclosing frame of each lambda (for the dynamic summary-dependency edges of §2.10);
which declarations are a type's `eq`/`compare`; the spread chains `Lower` recorded (§2.13.2); the
`withDefault (map m f) d` shapes (§2.13.12), recognised through the `WellKnown` symbols `Lower` itself uses — the
one allowlisted name comparison of the fence in §5.

### 2.13 Reductions: every surface construct to the core

1. **Constructors as values** (R-4.8.10, R-5.5.8, R-5.5.12): a constructor's class from its type: `res` a `node` at
   the type's place with `C#i ↦ πᵢ`, every πᵢ `A`; a record-alias constructor is a record literal. `Pushed : Value →
   Msg` holds a crossing value: `res ∅`. Constructors are rebuilt, never written (R-4.8.9).
2. **Lists** (R-2.2, R-2.3, R-2.13, R-4.4): `Lower.lowerSpreadList` (`Lower.zig:2563-2611`) lowers a spread literal
   to right-nested `List.cons`/`List.append` calls stamped with the `…` token. **A BIR fact replaces reading those
   calls back**: `Lower` also records, per declaration, each spread chain as `Bir.Spread{ root call, items (inst,
   is_spread) in source order }` in `extra` (`Decl.spreads_start/end`), with no change to the instructions the type
   checker and the emitter read. `Transfer` evaluates the chain as one instruction at its root: `[ x₁…xₖ, …xs ]`
   (one spread, last) is a **prepend**: cells `{site ι}` ∪ `cellsAt(xs, ε)` approximate (re-cons may answer the
   base, R-4.4.2), `[*] ↦ join(x₁…xₖ, proj(xs, [*]))`, κ `lost` — **except** when every front item is a `List` whose
   `ε` cells are a non-empty set of `site`/`result` cells not escaped and not in `reach(xs)`, or whose *instruction*
   is a record literal, a constructor application or a tuple (fresh objects by construction, whatever their cells —
   a tuple's and constructor's cells are `∅`): then `{site ι}` alone (R-4.4.3, `p/PrependFreshRecord`); a scalar, parameter,
   capture, taken element, top-level value or callback result keeps the base's cells (`call (a)`). Anything after
   the first spread is a `construction` demand with base = the first spread's operand, each stored item lowering κ,
   a spread literal inside another's last spread its own write. `[ …xs ]` is `xs`; a literal is a fresh `site`
   (R-4.10.5); `++` chains per R-2.2. The emitted prepend writes no existing array (R-4.4.4): the lowering's
   obligation, asserted under runtime safety.
3. **Patterns and views** (R-2.14, R-4.5): `[ x, …rest ]` on `n`: `x ↦ elem(c·ι)` per `c ∈ cellsAt(n, [*])`,
   `rest ↦` a node with `n`'s `ε` cells (a view shares the storage) and `[*] ↦ others(c·ι)`; the split records
   κ(n) at ι (§2.2). A constructor pattern on a recursive place materialises `level(c·ι)` for the matched node's
   non-recursive arguments and one `below(c·C#i·ι)` per recursive child step, pairwise apart under κ (R-4.7.1,
   R-4.7.7: `l`'s lists and `r` are two `below`s; `p/WriteOneLevel`); a pattern nested two constructors deep splits
   the inner `below` again, so `v` and `v2` of `Node (Node l v r) v2 r2` are distinct cells; a non-recursive
   constructor's arguments are plain projections. `List.tail`/`List.drop` are views because their bodies call the
   `view` primitive, whose words say `returned` at `ε` (R-4.5.1). Rebuilding the matched shape is a prepend over
   the view (R-2.14).
4. **Program entry** (R-2.10, R-5.8): a declaration with `entry` on a record parameter gives its constructor an
   entry class; at a call whose record's functions have classes: protocol by the callbacks' types (hosted with
   `settle`); `M₀ = res(init)[flags, Host := crossing]`, a top-level value `init` returns stays `shared`
   (R-5.8.3); captures of `init` move into `M₀` only when no other callback keeps them. The sparse fixpoint of
   §2.12 over `M` and κ(M) (the exclusivity invariant, R-5.8.7) with the message `msg` (symbolic, so `Got a b`'s
   payloads are `msg·#Got.0` and `msg·#Got.1`) plus the view's event-slot cells (R-5.8.9), `settle` a second
   writer (R-5.8.11). Then: `update`'s `E` on π₂, its command half, `init`'s commands, `subscriptions`' result and
   what `view`/`subscriptions` escape join Esc (R-5.8.5); each `W{F}` of `update` on `π₂·q` is an `entry` demand on
   `M@q` (Known, Unescaped, Disjoint against `msg` and the model's other paths — alternatives of one `ctor` place
   excluded, so `p/RecordVariantMove` is accepted — Dead trivially by P1; `xreq` on `(msg, M)`); a `W` on the
   message is `payload`/`entry` (R-5.8.8); a `W` of `view`/`subscriptions` on the model `read-only` (R-5.8.6). An
   unsupported shape leaves the writers pending (R-5.8.1). P1–P4, P7 and P-sync (§2.13.7) are trusted (R-5.8.13).
   browser-inline's generated root closures are no holders by the lowering interface's slot kinds (R-5.8.12).
5. **Sends** (R-2.9, R-5.9): `Send msg` becomes a **nominal type** of the `browser` base platform, `pub foreign type
   Send msg`, with one operation `pub foreign pure to : Send msg, consumed msg → ⊤` (called `send.to m` by dot-call,
   or `Send.to send m`); the runtime hands a `Send` value whose sibling export is the dispatch. A send is then a
   call of a worded operation: `S` on its argument, a `send` demand on every cell of the payload (R-5.9.1), send
   values crossing (R-5.9.4); a function that sends its parameter gets `S` on it; a send handed to a callee needs the
   callee's supply owned (R-5.9.5); a lambda sending a capture is once; taggers are callbacks with `need owned`
   (R-5.9.6). The alias form of the first draft was rejected because `Unify.expand` (`Unify.zig:826-843`) expands a
   non-generalised alias that meets its expansion, so a `Send` passed through a helper annotated `msg → ⊤` would lose
   its class and be refused; beni has no users, so the API changes (`Hosted.job`, `tap`, …, `Cmd.perform`,
   `Sub.on`, `Sub.map` need no row of their own, R-5.9.9).
6. **Foreign words and rows as data** (R-5.10): `Rows.fromWords` builds a class from oc §24.2's words, defaults
   pessimistic (R-5.10.3). **Four words are added** so that every row R-5.10.8 asserts is written beside its type
   and `Rows.zig` names no declaration: parameter `written` (`W` at `ε` only: a storage write, R-4.10.9);
   parameter `stored` (retained at the result's `[*]`, taking part in §2.9's construction rule: `Dict.insert`'s
   value, `put`'s); `taken`, on a function parameter (the supply is a materialised element of the first container
   argument: `List.focus`, `Dict.focus`, `Dict.update`) **and on a result** (`foreign pure traverseAt : List a, Int →
   taken a`: the result is a materialised element of parameter 1, in force for the rest of the frame); result
   `lent` (a loan of parameter 1's `◆`: `Ref.get`). A `taken` element is owned iff the container is exclusive, owned, and
   has no holder of the *element* outside the call — a holder of the container holds `others`, not the taken
   element, while the split is in force (§2.2), so `mapHelp`'s pending `a` does not borrow it; and an owned item
   does not make an accumulator outliving the call owned (R-5.3.4).
   **The index obligation**: a body that calls a `taken`-result primitive reads the container only through it, once
   per index, moving one way (`core/List.beni:516-521`); every such body (`mapHelp`, `foldlFrom`, …) is listed with
   a body hash in `o/word-bodies.txt` and a gate fails when one is added unlisted or changes — R-5.10.7's mechanism
   extended to the callers of a `taken` result; these pinned bodies *are* part of the trusted surface, and R-3.6 and
   R-5.10.7 now name them and P-sync (§2.13.7), amended in this PR [O 2026-10-25]. Derived `eq`/`compare` have no body and
   get a synthesised read-only class. Every worded declaration keeps its pinning fixture and flip report; a wordless
   `foreign` lets every argument escape and answers `⊤` unless crossing (R-5.10.1); words are erased by lowering
   (R-5.10.5); `misplaced_ownership_word` gains the new words' placement rules (`taken` only on a function parameter
   or a result; `lent` only on a result; `written`/`stored` only on parameters). `Js.maySuspend f`: `f` `unused`
   (R-5.12.5). `Log.annotate`/`span`/`withSink`'s `work` is `once` (R-5.12.2, `p/LogAnnotateUpdate`);
   `Task.keepLogContext` `returned` (#774).
7. **`Ref` loans** (R-5.12.3, #981): `Ref a` is a `ref` place; **`◆` is a barrier**: a holder of a `Ref` is not a
   holder of its contents, `reach` and Esc stop at `◆` (a `Ref` captured by a handler, a spawned fiber or JavaScript
   does not escape its contents, since only the worded operations reach them: rule 6), and the only outside
   holders of the contents are loans. `Ref.make v`: fresh `site` with `◆ ↦ v`, `consumed` on `v`. `Ref.get`
   (`lent`): `loan(c·ι)` per `c ∈ cellsAt(r, ◆)`, a holder that may be read, passed to readers and used to build
   values; a loan reaching `res`, Esc, a send, a model or a closure outliving its frame is refused (`list_still_used`
   with the fix `List.copy (Ref.get r)`); a loan whose holder is live across an instruction whose effect rung may
   suspend (`Dispatch.effectAt`, `EffectPlan.zig`; `poly` counts as may-suspend) is refused. `Ref.set/update/modify`
   (`written` on the `Ref`, `taken owned` on the callback): a `writer` demand on the `◆` cell; Dead requires every
   live loan of an aliasing contents cell dead; **re-entry**: the class field `refs` (§2.10) lists the `◆` cells a
   body or its callees operate on, by provenance, so a callback (or anything it calls) that operates on a `Ref`
   whose `◆` may alias the focused one is refused at compile time (`p/RefOwnsContents`). **P-sync**, a trusted
   obligation of every platform, pinned: the runtime never enters beni code synchronously from inside a host call
   beni made (an event a host API raises synchronously is queued to the next dispatch), so within one fiber no
   beni code runs between two points that do not suspend. `Deferred` likewise; `Js.ref` is wordless → `⊤`
   (R-5.12.4); a spawned fiber or queued body holds its captures as an escaped closure (R-5.12.1).
8. **Markup** (R-1.6, R-5.8.9, R-5.8.12): a `markup` instruction is a call of a row synthesised from the lowering's
   slot kinds: render slots `R`; event slots `A` into the result's `⟨event⟩` slot as borrowed payloads (`payload
   (a)` on an `update` write reaching them); a `For` row callback's parameter supplied borrowed (`read-only`,
   R-5.8.6, `p/RecordForItem`); a handler capturing a scalar key holds nothing. The construction's result is
   `fresh` (`assumed`, R-6.3).
9. **Casts** (R-4.11): a `returned Value → a` call whose argument place differs structurally from its result's
   makes `recast(place(a), inner)`; a later read **of the recast node itself** (no step taken since) at a place
   structurally identical to `inner`'s restores `inner` exactly; a projection of a recast is a recast over the same
   inner, approximate, never restored, so a child of a recast recursive value is not taken for its root
   (R-4.11.2); `(xs, xs)` read as a list of lists stays `shared`; casts compose to one `recast`.
10. **Schemas** (R-4.7.10, R-5.11): a run is a call of a row derived from the resolved schema plan
    (`check/SchemaPlan.zig`): `res` fresh at every place the direction builds, holding conversions' captured or
    top-level cells where a conversion runs (a conversion placing one list twice makes the answer `⊤`, R-5.11.2),
    `⊤` for an interpreting builder or an unplaceable schema, a runner handed on as a value with an unknown input
    part; a `default` fresh per decode (R-5.11.6); issues fresh (R-5.11.5, `p/SchemaIssuesFresh`); `Type` and
    `Encoded` are different places (R-4.7.10); schema constructors are §2.13.1's folded by their family's places
    (R-5.11.4); `Json.decode*` and a run of a schema built at run time answer no record twice: κ `yes` for records
    (R-5.11.3, `p/RecordSchemaRun`). The engine's obligation is trusted (R-5.10.7).
11. **Top-level values and initialization transfer** (R-4.9): a reference to a parameterless value yields its `res`
    with `shared` cells (`top-level (p)` on any write reaching them). Transfer: when the pre-pass counts exactly one
    read of a private parameterless value — direct, outside lambdas, deferred bodies counted — by a parameterless,
    non-recursive initializer of the same application module, with no explicit or inferred `where` evidence, no
    return-type dispatch, a non-function result and a successfully inferred class, the reader sees the value's `site`
    cells as its own; a `pub`, `foreign` or schema source, a second read, a read in a lambda, a recursive
    initializer or an unknown result transfers nothing (R-4.9.3); the destination is still top-level for a
    function; a fold's result keeps its provenance (R-4.9.4).
12. **`Maybe.withDefault (Maybe.map m f) d`** and the `Result` twin (R-4.2.3): the pre-pass recognises the two-call
    shape over variable paths `m`, `d`, `f` a lambda, partial application or top-level value, both calls resolved to
    the same core module; `Regions` makes it a two-arm region and `Transfer` reads it as `case m of Just x → f x;
    Nothing → d`. `d`'s read is in the other arm; `m` written inside `f` is a write of a capture under the arm; `d`
    aliasing `m`'s payload is the other arm's read of a cell the first arm wrote, compatible-exclusive, so accepted
    as a `case` is. Non-matching shapes are ordinary calls (`later-use`); a record default `held-operand`.
13. **Comparison** (R-5.13.1): a declaration `Dispatch` marks as a type's `eq`/`compare` whose class has `writes` is
    `comparison_changes_value` at its first demand on an arrival (or the call of the writing callee). Type dispatch
    is unknown (R-5.13.2).
14. **`?`** (R-5.1.6): §2.6; an error type holding no cell adds nothing.
15. **Index exchange** (R-4.8.17, #869, `p/RecordIndexExchange`): a callback of `List.indexedMap` (its index
    supplied as a scalar) keeps the source's κ when it is an **exact permutation**, which is a *flat decision chain* on the index
    and nothing else: the body is `if i == e₁ then t₁ else if i == e₂ then t₂ … else r` — each test a `case` on
    `i == eₖ` (a `method_call` of `eq` that `Dispatch` resolves to `Int`'s, `Lower.zig:5112-5147`) whose `True` arm is a take `tₖ` and whose `False` arm is the next test or the element parameter
    `r`, no other instruction between the tests, no take nested under another guard's arm (§2.5's region tree has
    the chain as a right spine of guards); each `eₖ` a local not rebound in the callback or an integer literal;
    each take `tₖ` bound outside the callback by a pattern on `List.get xs e'ₖ` (`Just rowₖ`), a list pattern, or `List.drop xs e'ₖ ▷ List.head`
    (a view of the same source then its head) from the *same* exclusive source — **the very local the `indexedMap`
    maps**, not a view, `drop` or copy of it, else a take from `xs` lands at another offset in `List.drop xs 1` —
    used in exactly one arm; and the
    guard indices `{eₖ}` and the take indices `{e'ₖ}` are the same set (locals by identity, literals by value).
    **And the chain must stay a permutation under every equality partition of its indices**, which holds in
    exactly two shapes: (a) every index is an integer literal and the literals are pairwise distinct — no two
    positions can coincide, so the chain places the row of `e'_{σ(k)}` at `eₖ` for a bijection σ and every other
    position keeps its row; (b) exactly two guards on locals, `if i == a then rowB else if i == b then rowA else r`
    with `rowA = get a`, `rowB = get b` (the one swap): with `a ≠ b` it exchanges the two rows; with `a = b` the first
    arm fires at the one position and places `rowB = xs[a]`, its own row, so the result is `xs`. A chain of three or
    more guards on locals is refused even when flat and with guard set = take set: with `a = 0, b = 1, c = 1`,
    `if i == a then rowB else if i == b then rowC else if i == c then rowA else r` puts `xs[1]` at positions 0 and 1
    — the arm for `c` is dead and `rowA` is never placed — and so does a product of two swaps whose locals coincide
    across the swaps (`a = c`: position `a` gets `rowB`, position `d` gets `rowC = xs[a]`, and `rowD` is lost);
    only the trivial partition keeps a k-cycle a bijection, and locals cannot prove it. The 3-cycle is a red twin of
    `p/RecordIndexExchange` beside `dup2`. A take whose index is not a guard (`dup`'s `i == a → rowB`) puts one row at two
    positions and is refused `exclusive`, as is one cell in two arms, an unguarded arm, three or more guards on
    locals, any chain mixing literals and locals, a literal repeated, or a take nested under
    another guard (`dup2`'s `if i == a then (if i == b then rowA else (if i == a then rowB else r)) else r`, whose
    guard and take sets agree yet position `b` keeps `rowB` beside position `a`'s `rowB`: a red twin of
    `p/RecordIndexExchange`). `swapAt` and `List.drop`
    over an exclusive source keep κ as a storage permutation and a view (R-4.10.11, §2.13.3).
16. **Core's library**: every function of `core/` not asserted (R-5.10.8) is inferred from its body (R-1.10): the
    builders return `fresh` because they build in a `Builder` whose `put` is `written`/`stored`; `List.append` by
    name: `returned` π₁ with κ `lost` at `[*]` for lists and κ kept for records when each input is exclusive and
    they are separate (one condition, kind-filtered, R-4.10.7, R-4.10.8, `p/SchemaIssuesExclusive`). A worked
    derivation of `mapHelp` and `foldlFrom` (§2.2's materialisations in force, the `taken` result, the callee
    `put`'s `stored` word) is the first commit of S2b, before any walker code.

### 2.14 Soundness

**Concretisation.** `γ(c)`: `site ι` the objects ι allocates in this frame's activations; `param πᵢ·q` the objects at
`q` of argument `i` on entry (`⟲` every level); `elem c·ι`/`others c·ι` the position taken at ι and the others;
`level`/`below` likewise; `loan c·ι` the objects of `c`; `env x·q`, `shared M.v·q`, `msg·q` the objects at `q` of the
capture, the top-level value, the message; `result ι·k`/`esc ι·k` the objects the callee's allocation `k` made in
the activation the frame's call ι started; `cb j@λ·q` the object at `q` the frame's parameter `j` returned at the
concrete call λ labels (every call in λ's chains when λ is folded); `⊤` all. `γ(n)` as §2.3; `γ(Σ)` the configurations where
each bound local holds a value in `γ(Σ(x))`.

**Lemma 1 (holder completeness).** *At every point `p` of an execution of an accepted program, in every open frame,
for every object `o` some continuation of `p` may dereference, call or compare by identity, and every reference to
`o` the configuration holds: either (i) `o ∈ γ(c)` for a cell `c` escaped at `p` (§2.4: `c` or a trie ancestor, at a
compatible point), or (ii) the reference is held by a local `x` in scope at `p` and `o ∈ γ(cellsAt(Σ(x), q))` at the
path `q` it is reached by — except that while a split ι is in force (§2.2) a holder of the container does not name
`elem c·ι` although it still references that position at run time: no continuation of `p` reads that index until
the write-back or the frame's end, which is O9's pinned obligation on the callers of a `taken` primitive, so the
clause holds for every reference a continuation may use — or (iii) by a pending operand `m` and `o ∈ γ(cellsAt(m, q))`, or (iv) through the frame's
parameters or environment and the enclosing call's `use` reports it (`A`, `E`, `W`), or (v) by the runtime,
JavaScript, a top-level value or a message, and `o ∈ γ(c)` for an `esc`, `⊤`, `shared` or `msg` cell held at one
of (i)–(iv).*

*Proof sketch.* Induction on the execution prefix (thesis §6.3). Base: a frame's entry, every reachable object
in `γ(param πᵢ·q)` by canonical paths (`⟲` covers every level, O6), captures in `γ(env)`, top-level in `γ(shared)`.
Step: one transfer rule (O1–O4, O6, O7) or a call (O5: the callee's `res` over-approximates its result, its `E`
what it hands on, its `fun(j)` what it supplies; its `refs` the `Ref` cells it touches; a callee without facts
yields `⊤` and escape, O1, O10; a limit stops compilation and authorises no write, O11), a pattern match (O6), a record update (O7), a
join (O4), an escape (O8, deep), a row (O9). ∎

**Lemma 2 (labels).** *Within one activation, two occurrences of one unfolded label denote one object, and two
different `cb j` labels denote the results of two different calls of `j`.* The first because a label enters a value
only at the store of the value it names (O1, O2); the second because a label is a function of the concrete call
chain (the frame's instruction, then the callee's label, which is the same function one level down), so different
labels have disjoint chains — which the uniform fold keeps: a first instruction is folded everywhere or nowhere in
a class, so no unfolded label's chains lie inside a folded label's. Whether two different calls' results are one object is what §2.11 item 5's
instantiation decides from what the callback returns under what it was handed (O14). A folded label is
approximate: two occurrences of it from one value are `lost`, and `within` rests on two per-cell claims, each an
obligation — a `result` not reached through a feedback supply is allocated afresh by each call (O1), and two `taken`
positions of a container exclusive at that path are two objects (I-κ, O9). A closure call changes the
identity of its new allocations only, never captured origins. The recursive environment quotient unions
possibilities and keeps every capture edge; settled facts and independently validated obligations are required.
A cycle or exhausted resource cannot establish either claim. ∎

**Invariant I-κ (exclusivity).** *For every node `n` whose κ(n) holds at `p` (`yes`, or `and{atoms}` with every
atom true of the actual arrivals), no object of `γ(n)` sits at two distinct positions of a summary place, nor at
two distinct paths of one position at or below `n`'s path, and no two positions' cells at `n`'s path alias.*
Kept by O13–O15; relied on by Exclusive (§2.8), the split (§2.2) and `taken` (§2.13.6).

**Corollary (no stale read).** If a demand at `p` on `c` is accepted, no reference to any `o ∈ γ(c)` other than the
demand's own result is dereferenced after `p` compatibly: not by a local (Dead: holders found through `reach` and
the trie, Lemma 1 (ii)), a pending or other operand (Dead, Disjoint, (iii)), a closure (Dead through captures), a
callee (its `use` recorded the use; a callee's read is whole, never hoisted), the runtime or JavaScript (Unescaped,
deep, (i), (v)), a top-level value (Unescaped), another position of a container (Exclusive and I-κ), a stale view (a
view shares the cell), a loan (Dead over loans; P-sync for the suspension rule). Hence no step of `S_u` uses a
stale reference and by thesis Lemma 6.1 the trace equals the value semantics' (R-3.1, R-3.2). Per-field acceptance
is sound because every read of a written field a later use needs is a `field`-kind use this frame's index
enumerated (O12), and the lowering reads it before the store (R-1.12).

**Obligations** (each slice's review checklist; `rules_test` names them in file headers):

| | Obligation | Binds |
|---|---|---|
| O1 | *Over-approximation.* A construct's result node contains every object it can produce; a construct without facts yields `⊤` and escape | §2.6, §2.11, §2.13 |
| O2 | *Uses at consumers,* at a path at or above the one read, in the right region, with the right kind (`field` only for this frame's own reads) | §2.7, every `use` entry |
| O3 | *Extensive operations.* `proj`, `put`, `join`, `map`, `recast`, `widen` are extensive on `γ`; `leq` implies `γ`-inclusion | §2.3 |
| O4 | *Join is union;* `Esc` only grows | §2.3, §2.4 |
| O5 | *Summaries cover bodies:* `res`, `E`, `W`, `fun`, `classes`, `refs`, `writes`; instantiation is extensive | §2.10–§2.12 |
| O6 | *Materialisation partitions:* `γ(elem) ∪ γ(others) = γ(proj(c,[*]))`, `γ(level) ∪ ⋃γ(below·s) = γ(c⟲)`; the sides are disjoint only under κ(ι); `⟲` covers every level | §2.2, §2.13.3 |
| O7 | *Delta is the base written:* `γ(delta(b, O))` = `γ(b)` with children in `O` replaced; the `ε` object is `b`'s | §2.3, §2.6 |
| O8 | *Escape is deep, directional and forever:* an escaped node's every cell is escaped; a write is blocked by an escaped ancestor-or-self, a deep demand also by a descendant; never undone; `shared` never owned | §2.4, §2.8 |
| O9 | *Rows state their bodies;* the index obligation of a `taken` result is pinned on each caller; P-sync and P1–P4, P7 on each runtime | §2.13.6, §2.13.7, R-5.10.7 |
| O10 | *Unknown is never empty* | §2.3, §2.11, R-3.4 |
| O11 | *No bound accepts:* reserve before expansion, terminal error on exhaustion; no partial summary or lowering channel | §4.4, R-3.7 |
| O12 | *Hoisted reads are this frame's own:* every hoist is a `field`-kind use the index recorded (a field chain, a record pattern, a field capture of a closure created after the write), never a callee's or a whole use | §2.7, §3.7 |
| O13 | *Constructions keep I-κ:* a literal's or construction's κ is `yes` only when the stored cells are pairwise apart per path and each stored value's deep condition holds; a stored refinement of the base's own `[*]` is `shared` | §2.9 |
| O14 | *Instantiation keeps I-κ:* κ(res) instantiated is `yes` only when every atom holds of the actual arrivals (a `sep` over two labels holds if their instantiations under their supplies are apart; a `within` holds if each instantiated cell is distinct per call — a fresh `result` not reached through a feedback supply, or a `taken` supply under its container's κ; folding is uniform per first instruction, so distinct labels have disjoint chains); a `delta`, a storage permutation and a `taken` write-back lower κ exactly as the stored value's condition says | §2.9, §2.10, §2.11, §2.13.15 |
| O15 | *Join lowers κ:* κ(join) is below every member's κ (`and{A} ⊔ and{B} = and{A ∪ B}`), and a union's κ is the join of its members'; computed by `Cond.lower` where `Transfer` and `Summary` join, since `Shape.join` knows no κ | §2.3, §2.9, §2.10 |

The Lean oracle stays advisory (R-8.11).

---

## 3. Data-oriented design

`fast-compiler.md` §5's rules hold in every table: `MultiArrayList` columns, `u32` ids as `enum(u32)` with
`.none = maxInt`, `extra: []u32` sidecars, no pointer in any table, no per-node allocation, one arena per walk, no
`HashMap` keyed by a dense id (`src/rules_test.zig`; v1's `summary_bytes.zig` allowlist entries go with it). All id
newtypes and the low-level resource account live in `Ids.zig` (L0), all record types that cross layers (`Use`, `Demand`, `Obligation`, `Supply`,
`Split`) in `Facts.zig` (L2), so no table refers upward.

### 3.1 Places (`Place.zig`)

```
Place.Table (per module)
  kind      : u8          record | tuple | ctor | list | dict | ref | closure | opaque | var | cross
  head      : u32         TypeId of a nominal/foreign type; the record's field-name run; the tuple arity
  steps     : Range       into `step_tab`, sorted (field by name text, index, ctor·arg)
  holds     : u8 bits     may hold: list | dict | record | ref | closure | opaque | any
  class     : ClassId     closure places: a declared class, else .none (#587's slot)
step_tab    : MultiArrayList { step: Step (kind:4 | payload:28), child: PlaceId }
identity    : structural graph-pair tasks per consuming owner; source graph built by by_var without a global hash interner
by_var      : stamped column Var → PlaceId   (the type walk's memo; `stamped.zig`)
path_bytes  : []u32 canonical path step records (`⟲` reserved); charged construction/traversal per step, no copied uncharged path string
```

### 3.2 Cells (`Cell.zig`)

The explicit `labels` table preserves identity and is charged before each insertion (§4.4).
Acyclic wrapper composition may exhaust the resource; it never merges ordinary labels to fit.
The callback views of §2.11 use `u32` template/context ids, `MultiArrayList` columns for invocation and supply
environment, and composite memo keys; neither pointers nor a map keyed by a dense id are needed. Their query
records count against the same owning-summary allowance; layout alone proves no linear bound.

```
Cell.Table (per walk)
  origin   : u8     site | param | env | shared | result | esc | cb | msg | top | elem | others | level | below | loan
  kind     : u8     list | dict | record | ref | closure | opaque
  a, b     : u32    site: instruction; result/esc: LabelId + k; refinements: parent CellId + LabelId (the split's chain); param/env/shared/msg: index + PathId; cb: LabelId + PathId
labels     : MultiArrayList { inst: u32, callee_label: LabelId (.none = the frame's own call or a folded `ι⋆`), folded: u1 (set for `ι⋆` and for any composite whose callee label is folded), supplies: Range }   interned by (inst, callee_label, folded); refinements' `b` is a LabelId too (a split's chain)
  place    : PlaceId
  parent   : CellId   the trie parent: the path minus one step, or the refined cell; .none at a root
  children : Range    into `child_cells`: the trie children in first-sight order (the descendants of a cell the program named)
intern     : owner-local comparison tree (origin, kind, a, b) → CellId
set_head   : column CellId → SetNode   (the first persistent-set node keyed by this cell; the inverted index's entry)
sets       : persistent sets of (CellId, approx) as balanced trees ordered by CellId in a MultiArrayList
             { key: CellId, approx, left, right, prev_same_cell, next_same_cell: SetNode (linked only while live), parents: ParentLink, live: u32 }, path-copied,
             `union` sharing the larger operand, `member` O(log) by comparison (no hashing of a dense id);
             roots carry holder lists { kind: local | pending | capture, id, path, next }
splits     : MultiArrayList { container: CellId, inst: u32, cond: CondId }   (the `taken` set's records; `alias` returns a SplitId)
```

### 3.3 Shape nodes (`Shape.zig`)

```
Shape.Table (per walk)
  kind     : u8        leaf | node | delta | recast | union
  place    : PlaceId
  cells    : SetId     (delta: the base's)
  a, b     : u32       node: Range into child_tab; delta: base NodeId + OverId; recast: inner; union: left, right
  reach    : SetId     memo, persistent (.none until asked)
child_tab  : []NodeId          dense per node in the place's step order
over_tab   : MultiArrayList { step, child: NodeId, left, right: OverId }   persistent sorted tree
intern     : owner-local comparison tree (kind, place, cells, child-run id, b) → NodeId; runs built by charged chunks
memo_proj  : stamped column NodeId → bounded inline cache of (step, immutable input version, NodeId); misses use owner-local operation records
memo_join  : owner-local comparison tree (canonical member-run id) → NodeId; memo_leq / memo_eq: (NodeId, NodeId, immutable version ids) → u8 (coinductive shape assumption only)
memo_map   : stamped column NodeId → NodeId within one immutable substitution context/version; different contexts never reuse that stamp
```

κ is **not** a column of this table (D1): `Cond` owns it (§3.4). Holders are found through the live inverted set index (§2.8), never a scope scan.
Live parent links and their transition/query tasks use §4.1 accounting.

### 3.4 Conditions (`Cond.zig`)

```
Cond.Table (per walk)
  kind    : u8      yes | and | atom | shared | lost
  a, b    : u32     and: (CondId, CondId); atom: (atom kind: excl | sep | within | apart | keep | writes, operands)
groups    : canonical persistent CellId sets (`apart` members); sorted runs only on charged export
intern    : owner-local comparison tree (kind, a, b) → CondId
kappa     : column NodeId → CondId   (κ, owned here; dense per walk, cleared with the walk arena)
flat      : memo CondId → sorted atom run (print, compare, block)
memo_sep  : owner-local comparison tree (CellId, CellId, interpretation/κ version) → CondId; memo_deep: (NodeId, κ/input version) → CondId
```

### 3.4a The liveness index (`Liveness.zig`)

```
uses      : MultiArrayList { local, path: PathId, point, kind: u8, region, use_node: NodeId (.none unless kind call) }
            sorted by (local, path, point)
by_local  : column local → Range into `uses` (dense: a declaration's locals)
by_path   : within a local's range a sorted run of (PathId, Range), binary-searched — never a local × path table
subtree   : the same two levels over uses entered at every ancestor path of their own (depth entries per use)
last_use  : column local → point
```

### 3.5 Classes and summaries (`Summary.zig`)

A class is a sub-table of the walk's tables plus:

```
Class
  params   : Range   per parameter a NodeId over its places, labels in a parallel column (bits:4, F: SetId of field symbols, S: 1)
  res      : NodeId
  xreq     : Range   atoms
  funs     : Range   { calls: u2, need: u1, seen: u1, supply: Range of { k, node, owned: u1, taken: u1 }, keeps: Range of { k, kept_path: PathId, written_path: PathId, writer: u32 } }
  classes  : Range   into the summary-local class table: ClassId per closure node reachable from res/supply/use
  refs     : SetId   the `◆` cells touched, by provenance
  writes   : u1
  once     : Range
  account  : SummaryAccountId   -- owner declaration, inherited by every nested class
```

Summaries live in the module arena in **normal form**: cells relabelled to provenances in canonical order, nodes
renumbered by a canonical DFS with backreferences (children in step order, unions in canonical semantic member order), classes in reference order, so
equal summaries are byte-equal. Normalisation occurs after solving, never renumbers inference keys.
The retained analysis memo graph is workspace, not interface semantics; §4.4 defines its charging and lifetime.

### 3.6 Blocks (`Block.zig`)

The format writes every semantic graph record once and every edge as a local id. A class table is flat:
classes and environments refer to table entries, not recursively embedded class copies. Assign canonical ids
before writing children; an already numbered child is a backreference, including a cycle. Application views
store template, invocation and supply references. Normalisation, comparison, hashing and decoding obey §4.1
accounting; they may not expand a graph into paths. The first import of a callee's complete semantic table is
charged once to each consuming owner, even if immutable bytes are physically shared. Unknown bytes never imply
an empty class. Analysis memo tasks are not serialized as callable semantics; the block records the resource
policy/version, effective allowance and measured category totals for cache diagnostics. The effective allowance
and accounting-policy version participate in the cache key; a formerly successful larger allowance cannot
bypass a smaller one. Same-module and cached/imported calls consume the same canonical semantic table API.
Operation memos are owner-local: no free reuse of a callee's transient inference memo is allowed. A cached
complete owner reuses its recorded computation only with the matching inputs, policy and allowance.

One block per module, in the interface record (`Interface.ownership`, hashed with it: R-5.7.2) and in the cache
entry (R-5.7.4); format `OWN2` v1, bumped by every rule change. Names nothing by session id: modules by package and
dotted name; declarations by BIR index; constructors by module and constructor-table index (BIR's, then each
tagged schema's: oc §28.4); **places structurally** (`kind`, head as `package·module·type` or field names or
arity, children) so a reader re-interns them onto its own graph; paths as canonical steps; opaque slots by number.

```
head       : "OWN2", version, module table, string table, place table (structural)
directory  : per declaration (BIR index, offset, length) — summaries read lazily, one at a time (oc §28.4 #814)
summary    : cells (origin, kind, a, b over the local numbering), labels (own instruction, callee module·declaration·label index, folded, supplies), sets, conds/atoms/groups, nodes
             (kind, place#, set#, κ#, children/overrides/union), the flat class/environment table (id edges and backreferences), the Class record
value facts: per parameterless value whether it may hold a cell (R-5.7.5)
```

A declaration whose summary does not decode is unknown; a block that does not decode is no block (R-5.7.4).

### 3.7 Inputs, outputs, and where the pass runs

Inputs (R-1.6): the module's `Bir` with the new spread table (§2.13.2), `Check.Module` (`inst_type`, `local_type`,
`decl_scheme`, the store), `Dispatch` (method callees, `eq`/`compare` declarations, `effectAt` for the per-call
rung: `Dispatch.zig:477`, `EffectPlan.zig`), the imports' interfaces with their blocks, the schema plan, the
lowering interface's slot kinds, the ownership words (`Decl.own_*`), the package kind. Never read (R-1.7):
platform or constructor names, mode flags, session ids, completion order, paths.

**Where it runs.** The per-module hook exists: `check/Driver.zig:443` calls `Enforce.checkModule(ctx, d, m, tid)`
in the worker that checked `m`, after its type check and before `Incremental.publish`; `Enforce.zig:171` publishes
the block into `d.interfaces[m].ownership`, and `Incremental.zig:300` hands importers their blocks from the
interfaces. v2 keeps this hook unchanged (`Enforce.zig` is ported), so the firewall (R-5.7.3), the interface hash
(R-5.7.2) and R-7.8 (a module's pass runs in its own worker, no new wait) hold as today. The serial
`Enforce.run` of `Session.zig:2255-2270` is the serial `dump` path.

Outputs (R-1.8): diagnostics (§6); the report (R-7.15); the block; the lowering channel (`Hoists.zig`, format v2:
`Step` gains a constructor-argument kind for pattern reads through a wrapper, R-4.8.12; list writes added at the plan item O5 of oc §30.7, not obligation O5):
per accepted write its instruction and fields; per hoisted read the holder, chain, written-field prefix, placement
(the demand's instruction, phase 0/1, or for a read after a join the first instruction of the innermost region
containing write and read; always after the holder's binding and before the first write the read's version does
not see; a field capture at the closure's creation) — every read a `field`-kind use (O12); versioned, outside the
interface hash; a non-clean or unchecked module authorises no store (R-1.12).

### 3.8 Determinism

Scheduling and resource totals use a fixed owner-local order: qualified declaration name and lexical frame/
instruction/port order, never declaration enumeration or inter-module completion order. Canonical semantic
input names/ports determine task ordering; mutable allocation ids do not choose which dependency runs first.
Every resource-policy version pins this schedule, including watcher delivery order; source-declaration
permutations are a limit/verdict determinism test (§7).
Ids in walk order (parameters, then instructions; cells in first sight; nodes by creation; places by the type walk
in declaration order). Nothing printed is an id: source names, canonical paths with field names, normal-form
summary text with fields in name-text order; blocks write names and structural places; ties go to source order
(R-7.6). A module's result is a function of its BIR and its imports' blocks (R-5.7.5, R-7.7).

### 3.9 Arenas and lifetimes

Per worker: a **module arena** (normal-form summaries, block, report, channel) released at publication; a **walk
arena** (cells, nodes, conds, sets, uses, demands and retained operation records of the group) reset only
after that group's final validation/encoding, never between its fixpoint rounds. The account lives through
publication; validation and encoding inherit it, without a fresh allowance. Growable lists and explicit stacks only (R-7.12).

---

## 4. Complexity

E, P, N_f and L_f are defined in §4.1. In local operation bounds C counts cells, U uses, D demands,
and H live holders; these local bounds are not substitutes for the whole-module accounting.

### 4.1 Per phase

Let **E** count written BIR/type/capture-schema edges and imported bytes actually read; **P** is the total
selected path steps traversed by the fresh-result fragment, not the number of queries. Let F be the number of
owning declarations, L_f its effective summary allowance, and N_f the number of retained constant-size
analysis records charged to f (including records shared physically with another owner). N_f ≤ L_f on success.
Source-derived place/region tables are built once in O(E); inferring memberships, canonical paths, proof
contexts and derived indexes is not hidden in E. An input string/name is interned once in input time.

| Phase | Bound actually proved | Scope |
|---|---|---|
| place graphs, initial pre-pass, regions | O(E) time and storage | memoised graph walk and ordinary static SCC pass; dynamic dependency discovery is charged below |
| fresh-result selected-path fragment | O(E+P) traversal, plus deterministic dictionary lookup cost where needed | shared templates/scopes, first-divergence comparison of selected occurrences, only after whole-template generativity/internal-sharing certificates; no supplied/captured/feedback result assumed fresh |
| actual template setup | O(B+V) traversal | B prepared template/binding edges, V requested constant-size views; neither is multiplied eagerly |
| persistent `reach`, cell/κ sets, inverted index, general liveness/resolution, joins and shape comparisons | O(N_f log(N_f+2)) per owner | the retained operation graph and proof below include failed/zero-growth work, all live-parent routes, projected paths and all intermediate nodes |
| recursive groups, feedback, entry | O(N_f log(N_f+2)) per owner | all deliveries, union tasks, shape-triggered re-walk continuations and validation belong to the same account; no fresh budget per round or class |
| normalisation and block write/read | O(N_f log(N_f+2)) per owner plus bytes read/written | graph references, no recursive unfolding; inferred order/comparison work charged; fixed-size record encoding linear once ordered |

**Fresh-fragment certificate and algorithm.** For a settled result-template DAG whose every tracked origin
is a fresh allocation k, with no parameter/capture/shared/unknown/feedback dependency, certify that property
once per node using a dense stamped column. Repeated references to k remain repeated references: a fresh outer
record does not prove its children separate. A selected result occurrence is `(scope occurrence path, k)`;
same occurrence and k is shared, different allocation ids or allocating invocation occurrences are apart.
Walk scope edges to the first divergence and retain selected-path memos; total traversed edges are P.
The certificate scan plus selected-path traversal is O(E_template+P); fixed-key interning adds its stated
logarithmic cost. This is a subalgorithm, **not** O(E+P) construction of every explicit ordinary wrapper label.
Exported labels, full κ queries and contexts outside this fragment still count in N_f, and the unforced scope
DAG must not conceal required export work.

The **whole module** therefore costs
`O(E + Σ_f N_f log(N_f+2))` time and `O(E + Σ_f N_f)` arena space, up to fixed record sizes.
On an exhausted owner its bound uses L_f+1 for the failed reservation. In particular the uniform-default bound
is `O(E + F L log(L+2))`, L=65,536. This is a **resource-parameter bound**, not an assertion of linear growth
as unrestricted written programs get bigger. A raised L raises the bound. The O(E+P) fragment does not prove
P=O(E), nor does a finite fixpoint prove cheap evaluation. Budgeted general operations may stop with a loud
error; ordinary labels are never merged to make the resource fit.

**Persistent sets: representation and total accounting.** Use immutable AVL/red-black search trees in
columns, keys ordered by stable ids; path copying shares unchanged subtrees. Dense roots/memos use columns.
Owner-local composite-key dictionaries and operation memos use deterministic comparison trees over constant-size keys; do not rely on average
hash-table cost for this bound. Variable-length paths, groups and child lists are persistent cons/tree records
with bounded-size keys; constructing or comparing their sequences uses the tasks below. Physically shared
nodes are logically registered once to each owner which relies on them. Structural node interning is not
canonical median rebuilding: singleton insertion copies O(log C) nodes. Equal-content trees may have different
roots. Inserting an existing key and union adding no facts return the original destination root; charged
inclusion/equality tasks settle different roots. This semantic idempotence, not a unique balancing shape,
prevents spurious fixpoint changes. Condition joins have the same idempotence requirement.

The complete retained analysis workspace is a **memoised operation graph**, not only the final semantic class.
A record is either semantic data, a membership/dependency edge, or a real memo/continuation needed to evaluate
an operation. Every record has one fixed-size kind layout (at most 16 u32 words). Variable-size runs use one
record per bounded-size chunk and must reserve each chunk before filling it. No record contains an uncharged
list, child array or arbitrary-size set. Every inference operation is one of these bounded-step tasks:

| Operation | Task key / retained output |
|---|---|
| insert/member/union for cell, reach, κ or class-alternative sets | operation, immutable input root ids, key or subtree cursor; result root and continuation edges; union visits already-present entries as well as additions |
| substitution, projection, deep/reach walk, `apart`, `alias`, `leq` | operation, immutable roots, invocation/supply context, path or pair cursor; a long path/pair product is a sequence of tasks, never a loop hidden in one task |
| holder registration/expiry and inverted-index search | holder event (binding/result plus program point and immutable state version), set node, edge cursor; every live-count transition, parent link traversal and path traversal is retained; stamp visited nodes per query |
| fixpoint propagation and shape-triggered re-walk | delivery `(edge,fact)` or immutable-root union request; new-edge replay of existing facts; watcher/notification edges; instruction cursor and immutable dependency version for each re-walk |
| dependency cycle search, validation, numbering, block codec | graph/version plus DFS/worklist cursor, visited record and continuation; cycles write id backreferences |

A task is reserved **before** execution, runs at most once, reads/writes O(1) already-addressable words and
creates at most a fixed number of successor requests/notification edges. Iterating a long adjacency run,
copying a variable-width key, bulk allocation, traversing children and retrying an unsuccessful lookup all
require continuations. Dictionary navigation of a fixed key may do O(log(N_f+2)) comparisons without a record
per comparison; variable-key equality is not such a comparison. Source scans outside the account execute
once, O(E), using dense columns/radix ordering over input ids, and only reserve initial tasks. A source seed
that needs composite lookup first reserves its unique source-event task in O(1) via a dense slot; the lookup
then belongs to that charged task. This avoids an uncharged E log N term; no uncharged interpreter loop, SCC rescan, polling or repeated
frame walk is allowed. A completed-task cache hit is reached only from one of those bounded successor edges
(or an O(E) source seed), so hits are bounded too. Each waiter/notification edge is registered and fired once
per immutable input version; an in-progress cyclic request returns a dependency edge, not a recursive call.
Mutable input ids are forbidden as sole cache keys: a changed fact set yields a new canonical immutable root,
and a new task if necessary. Deduplicate facts and notifications before scheduling them. Queue links live in
the task records; dequeue once, never spin on a waiting cycle. Reusing an already completed pure result is free
of new semantic allocation, not a licence to execute its body again. All such evaluation is on explicit stacks.

**Proof.** Charge data, tasks, continuation/notification edges and set-tree copies before allocating them;
never refund within an owner's computation. There are N_f retained records. Every task executes once and
issues boundedly many requests, every registered edge fires once, and source seeds total O(E). Thus there are
O(E) direct source steps and O(Σ N_f) charged steps/fixed-key dictionary operations. Their height is O(log(N_f+2)); every
variable-width operation was split into accounted steps. Summing gives the displayed module bound, including
zero-addition unions, repeated holder activations, failed separation and validation. Workspace teardown happens
after validation and encoding, not between rounds; normalisation/compaction cannot refund the allowance. In an
SCC each task is attributed to the declaration whose summary it computes; a task used by two owners is logically
registered to both. A nested class uses its enclosing owner, never its own counter. This also accounts imported
semantic records before traversal, with no dependence on whether an import was checked or cached. ∎

These are **real retained memo/continuation records**, used for deduplication, invalidation, dependency
resumption and diagnostics, not a second counter of instructions or rounds. Dropping them to retry work later
is outside this implementation. The limit's meaning is deliberately the full analysis summary workspace
(§4.4); counting only final serialized facts would not prove the bound. Instrument category counts separately.

**Families and stronger special cases.**

- `A_i = A_(i−1) ∪ {x_i}` uses one persistent insertion per step, O(n log C) copied nodes/tasks, including
  `reach` for a chain of single-cell deltas. Flattening all n roots would be Θ(n²) and is neither necessary nor
  free. General union of independently built A={1,…,n}, B={2,4,…,n} may inspect Θ(n) entries while adding none;
  those union tasks are retained and charged. Different overlapping operands can exhaust the allowance.
- N seed origins → one relay → N consumers can deliver Θ(N²) `(edge,fact)` pairs on O(N) written edges.
  Share immutable roots when applicable; otherwise every delivery and membership is charged. Sparse propagation
  alone proves no O(E log C) theorem. A rotating single W bit and a chain of nested sets do have O(E log C)
  work; this special case does not license a general claim for the model fixpoint.
- Register/expire the same N-node reach root at K separate events: Θ(NK) live-count work is possible even if
  no set node is allocated. Event/node continuations charge it before traversal; keeping nodes across hand-over
  avoids it in the single-delta chain. Multiple live paths to one holder also cost inspected edges, not merely
  the number of holders returned. The inverted index avoids unrelated scope scans, not every product.
- For `w0 f=(f ⊤,f ⊤); wk f=(w(k−1) f,w(k−1) f)`, explicit labels number 2^(k+1) in wk; tails do not deduplicate
  distinct pairs. Precise labels and their companion records stop at the first failed reservation, possibly
  before 65,537 **labels** because labels are not the only charged records. The fixed-type closure tower in
  Appendix B has zero formal callback labels but exponentially many ordinary environments; it stops likewise.
- `h f={a1=f ⊤,…,aN=f ⊤}` and an M-field actual prepare one template plus N views, O(N+M) setup. General
  descendant comparisons can still create NM context tasks. Fresh-only certificates avoid that particular
  product when applicable; no such certificate is assumed for supplied/captured/feedback descendants.
  Independent N-way/M-way callback-result unions can require NM pair tasks too. Both products are charged,
  even if every comparison succeeds or no cell is newly added.
- Canonical path **length** ≤2·places does not bound their **number**; a small acyclic graph can have
  exponentially many paths. Enumerate only on demand and reserve each path/continuation first. Keep shared
  shape DAGs shared (`DeepTupleDag`), use genuine dependency backreferences for recursion, and never prebuild
  the Cartesian inventory before applying the guard.

### 4.2 The six places v1 went superlinear

| v1 | v2 |
|---|---|
| #856: `w5`'s result at 2¹⁶ places | 17 hash-consed nodes; `map` 17 steps; `widen` is the identity on a non-recursive type; `p/DeepTupleDag` checks with no limit line |
| #955: `foldr` with a cyclic accumulator type never settles | the cyclic store variable is one place; `[*]` of it is itself; the feedback edge `cb ⊆ π₂ ∪ [*]` settles in one push; `p/CyclicFold` clean |
| #693: N(N−1)/2 `sep` atoms | one `apart` group of N cells |
| #716: the entry ×6.8 from N = 64 to 256 | `res(update)` is a delta over π₂ per arm (a tuple node around it for `model × Cmd msg`, its `.0` the fast path), joined n-ary in O(N); N inclusion edges, one push each |
| #975: Conduit +41 % | the same mechanism plus lazy blocks; measured at S9 against +10 % |
| `ListOfParams` O(n⁴) | `and(excl π₁…πₙ, apart{π₁…πₙ})` gathered once |

Also from R-7.2: `MutualCycles` one 12-node place graph; routed-app and the 256-widget application: shared signature-shaped summaries with the resource contract of §4.1; blocks read per declaration; interface reads O(modules); `Schema.read` lazy; these required fixtures must stay under the default allowance; arbitrary generated width is subject to §4.4.

### 4.3 Memory

O(E + Σ_f N_f) fixed-size records including persistent intermediates, tasks and live-index links (§4.1).
Imported immutable storage may be physically shared; each owner still charges every referenced semantic record
once. The inference account lasts through final validation and encoding; a group arena is then released.
Blocks encode only semantic graphs, bounded by the same account; they never contain recursively embedded copies.

### 4.4 Resource limits

**`ownership_summary_size` [O 2026-10-25]: 65,536 records per owning declaration by default.** Its unit is one
constant-size record of the complete analysis summary workspace (§4.1), including callback labels, paths,
closure classes and environments, contexts, carried class tables, cells, set-tree nodes, membership edges,
conditions, persistent intermediates and retained operation/dependency records. A nested lambda, local function,
entry analysis or carried class inherits the enclosing top-level declaration's account; parameterless values
are owners too. Imported tables are charged to each consuming owner on first use. Every variable-width run is
chunked and charged; physical interning does not give one owner another owner's unused allowance.

Reserve before work: the next new record at used=L fails before allocation, child enumeration, substitution,
set inspection or propagation. Preflight a known-sized run by checked arithmetic; otherwise stream one charged
chunk/task at a time. Stop that computation immediately with `ownership_limit`; publish no partial summary,
clean bit or lowering channel. A dependent member gets no acceptance from that failure. Do not allocate L+1
records, finish an expansion, then count. Work before failed reservation is bounded by §4.1. No separate
iteration, alias-depth, callback-count or work-fuel limit exists. Genuine recursive/summary-position folds are
semantic rules (§2.2, §2.10), not a means of squeezing an ordinary summary under L.

**Raise attribute (new language feature).** A standalone line at column 1:

```text
@ownership_summary_size(module, 262144)
```

sets the file/module default; it may appear once in the leading module preamble, before the first import or
declaration (comments/blank lines may precede it). A standalone line immediately before a top-level function's
annotation, or its definition when unannotated:

```text
@ownership_summary_size(131072)
large : ⊤ → List Int
large ⊤ = …
```

raises that declaration's allowance and applies to all its nested classes. A parameterless top-level value may
also carry it, since it owns a summary. It is not allowed on expressions, lambdas, local definitions, types,
fields or imported declarations; use the owning function's attribute. Comments may separate attribute and
declaration, another attribute/declaration may not. One attribute per owner. The argument is a decimal integer
literal, no expression/sign/separator, at least the inherited allowance; a function override may not lower the
module default. Parse with checked arithmetic, maximum 2³²−2 (u32 ids reserve `.none`). Invalid placement,
duplicates, a smaller value or overflow is `invalid_ownership_summary_size` at the attribute. Formatting keeps
it on its own line with the spelling above. Available to user, core and platform packages; never erased from
analysis inputs/cache keys. It changes no runtime code, types or ownership proof rules. Increasing it permits
more analysis, never permits a write without proof. S2b adds parser/lowering/formatter/diagnostic and corpus
coverage, `language.md` and **`skills/beni/` in that implementation PR** (CLAUDE.md rule 7 and skill policy).

**Evidence and instrumentation.** The measurement scanned 11,346 .beni files (3,578 repository files and 7,768
generated apps); the largest structurally resolved callback-label count was **10**, `o/LimitOwnedAtoms.beni:45`
(`hand9`), versus 65,536. That is not a measurement of full workspace records or proof about unresolved calls.
S2b records each category, total high-water N_f, effective L_f and largest owners for corpus/examples/core/
platforms and generator-deduplicated research apps. Repeat as S4 adds classes/callbacks and S7 entry analysis.
Report to the owner if N_f reaches one tenth of its default allowance; do not silently raise defaults, add
attributes to core, or coarsen. `own_limits_test` checks the measured headroom. A new memo design changing the
unit or deleting retained work records requires a new bound and policy version, not a silent budget refund.

Existing huge **input/format** limits remain; these are not extra inference budgets. Each has its own named
`ownership_limit` and measured value, checked before allocation. They are not changed by the raise attribute.

| Limit | Value | Bounds |
|---|---|---|
| `record_fields`, `tuple_arity`, `constructor_args` | 65,536 each | written fields/components/arguments, dense source/type runs |
| `type_places` | 2²⁴ | places in one module's source-derived table |
| `path_steps` | 65,536 | canonical path length, in addition to charged derived path records |
| `declaration_insts` | 2³¹ | written BIR instructions of one declaration |
| `block_bytes` | 2³¹ | bytes in one module's encoded block |

v1's precision/round caps (R-7.5) have no counterpart. Their existing small fixtures must get ordinary verdicts,
not merely be renamed to this limit. Exhaustion is a compiler-resource error with restructure/raise suggestions
(§6), never an approximate ownership answer, copy, warning or automatic alternative algorithm.

---

## 5. Module structure

`src/own2/` while v1 exists; renamed `src/own/` at S10. Imports go to strictly lower layers; same-layer files never
import each other; upward needs go through interface structs passed down (`ClassOf{ctx, get}` for `Calls`,
`Fix.Instance{ctx, step, join, leq}` for the driver, `Obligation.entry` records for `Entry`).

```
L13 Enforce
L12 Ownership
L11 Report  Message  Hoists  Block
L10 Groups  Entry
L9  Walk
L8  Transfer  Fix
L7  Calls
L6  Rows  Demands
L5  Summary  Liveness
L4  Regions  Cond
L3  Prepass  Shape
L2  Cell  Facts
L1  Place
L0  Ids
     bir/Bir, check/{TypeStore,Types,Walk,Dispatch,SchemaPlan,EffectPlan,Scc}, resolve/{Interface,Graph}, parse/Ast, InternPool, stamped
```

| File | L | Responsibility | Public API | Imports (own2) | Lines |
|---|---|---|---|---|---|
| `Ids.zig` | 0 | every id newtype (`PlaceId`, `PathId`, `CellId`, `SetId`, `NodeId`, `OverId`, `CondId`, `SplitId`, `ClassId`, `UseId`, `DemandId`, `SummaryAccountId`, `TaskId`); the constant-record account/reservation and one-shot queue primitives of §4.1 | types, `Account.reserve`, `Task.enqueueOnce` | — | ≤ 600 |
| `Place.zig` | 1 | place graphs, steps, canonical paths, holds, opaque slots, structural encoding | `Table`, `of`, `child`, `steps`, `kind`, `holds`, `pathOf`, `encode`, `decode` | Ids | ≤ 1 000 |
| `Cell.zig` | 2 | origins, kinds, class, the trie, interning, persistent sets, splits, `alias`, charged union/query continuations | `Table`, `intern`, `parent`, `children`, `alias`, `Set.{union,member,insert}` | Ids, Place | ≤ 800 |
| `Facts.zig` | 2 | the shared records: `Use`, `Demand`, `Obligation`, `Supply`, `Keep`, `Verdict`, `Cause` (R-6.3's order) | the types | Ids | ≤ 300 |
| `Prepass.zig` | 3 | SCC edges incl. dispatch callees, alias chains, read counts, `eq`/`compare` decls, spread chains, `withDefault` shapes | `run(bir, dispatch, graph) → Facts.Prepass` | Ids, Facts | ≤ 600 |
| `Shape.zig` | 3 | nodes and their operations, `reach`, `widen`, coinductive `leq`/`eq` | `Table`, `leaf`, `node`, `delta`, `recast`, `union`, `proj`, `cellsAt`, `put`, `join`, `map`, `reach`, `widen`, `leq`, `eq`, `expand` | Ids, Place, Cell | ≤ 1 500 |
| `Regions.zig` | 4 | region tree, points, compatibility, guards, virtual `withDefault` arms | `Tree`, `build`, `compatible`, `rangesAfter`, `guard` | Ids, Facts, Prepass | ≤ 450 |
| `Cond.zig` | 4 | κ column, atoms, `apart`, `sep`, deep conditions, instantiation, rely | `yes/lost/shared`, `and`, `atom`, `kappa`, `deep`, `sep`, `lower`, `instantiate`, `rely`, `flat` | Ids, Cell, Shape | ≤ 1 000 |
| `Summary.zig` | 5 | the class record and table, lattice (κ joined through `Cond`), normal form, equality, unknown class, text | `Class`, `join`, `leq`, `eq`, `normalize`, `unknown`, `print` | Ids, Place, Cell, Shape, Cond | ≤ 1 200 |
| `Liveness.zig` | 5 | the use index and queries | `Index`, `build`, `useAfter`, `useUnder`, `lastUse` | Ids, Facts, Regions, Shape | ≤ 700 |
| `Rows.zig` | 6 | words → classes; constructor, derived-method, markup and schema classes; entry shapes; `Send` | `fromWords`, `ctorClass`, `derivedClass`, `entryShape`, `schemaRow`, `markupRow` | Ids, Place, Cell, Shape, Cond, Summary | ≤ 1 100 |
| `Calls.zig` | 7 | instantiation, callback edges, keep edges, function values' classes | `apply`, `classesOf`, `callParam`, `keepEdges` | Ids, Facts, Cell, Shape, Cond, Summary, Rows | ≤ 1 500 |
| `Demands.zig` | 6 | the six conditions, holders, causes, verdicts | `resolve`, `holders` | Ids, Facts, Cell, Shape, Cond, Liveness | ≤ 1 200 |
| `Transfer.zig` | 8 | one case per BIR tag; the frame state | `eval`, `Frame` | Ids, Facts, Place, Cell, Shape, Cond, Regions, Rows, Calls | ≤ 1 800 |
| `Fix.zig` | 8 | the two fixpoint shapes, closure dependency cycles, charged delivery/notification tasks and validation | `worklist(Instance)`, `propagate(Edges)` | Ids, Cell, Shape, Cond, Summary | ≤ 900 |
| `Walk.zig` | 9 | one frame: walk, index, resolve, keep edges, read off | `walk(decl) → {Class, []Demand}` | Ids, Transfer, Demands, Fix, Liveness, Calls, Summary, Facts | ≤ 1 500 |
| `Groups.zig` | 10 | the module: pre-pass, order, limits, transfer, summary table | `checkModule`, `ensureClass` | Ids, Walk, Fix, Prepass, Summary, Facts | ≤ 900 |
| `Entry.zig` | 10 | the entry protocol at a constructor call | `check(Obligation.entry)` | Ids, Calls, Fix, Demands, Rows, Cond, Shape | ≤ 900 |
| `Block.zig` | 11 | class ⇄ bytes, lazy directory | `write`, `open`, `summary`, `version` | Ids, Summary, Place, Cell, Shape, Cond | ≤ 1 200 |
| `Hoists.zig` | 11 | the lowering channel, format v2 | `Table`, `Builder`, `write`, `read` | Facts | ≤ 500 |
| `Message.zig` | 11 | diagnostic text and JSON fixes (ported from v1 over `Facts.Demand`) | `build`, `limit`, `code` | Facts | ≤ 900 |
| `Report.zig` | 11 | dump lines and totals | `print`, `totals` | Facts, Summary | ≤ 600 |
| `Ownership.zig` | 12 | facade | `Input`, `run`, `ModuleReport` | Groups, Entry, Block, Hoists, Message, Report | ≤ 300 |
| `Enforce.zig` | 13 | the Driver hook, inputs, interface and cache sections (ported) | `checkModule`, `inputs` | Ownership, Block | ≤ 450 |
| `rules_test.zig` | — | the gate below | — | — | — |

There are **24 production files plus `rules_test.zig`, on 14 layers (L0–L13)**.
Every edge in the *Imports* column points to a strictly lower layer (checked by hand against the layer numbers
above, and by the gate). **The layering gate** (`own2/rules_test.zig`, in `zig build test`): reads every file's
`@import` lines against this table (an import of a same-layer or higher file, or of anything in `src/own/`,
fails naming both files); size targets; fences — `Transfer`/`Calls`/`Demands`/`Rows` compare no name to a string
literal (every `std.mem.eql` against a literal is allowlisted with a reason), only `Cell.alias` compares cells,
only `Place` reads type children, `Facts.Cause` is in R-6.3's order, every `switch` over `Cell.Origin`,
`Shape.Kind`, `Cond.Kind` and `Use.Kind` is exhaustive.

---

## 6. Diagnostics

Every refusal is produced from a resolved `Facts.Demand` by `Message.zig` (ported), which reads: the demand's kind
and base instruction (span widened to balanced brackets for a construction or `++` chain; a writer's call; a call
writing an argument; a send; an entry line spans the constructor; `ownership_limit` the declaration: R-6.5), the
base as written (a local or field path, a top-level name, `<literal>`, `<call M.f>`, `<lambda>`, `<expression>`,
`<record>`, a payload), the cause and its kind (exact/approximate/position from the pairs and κ), the holder (local,
canonical path printed in source terms: field names, indices, constructor names, never a report path, R-6.12), its
binding, the later use and its label, the fix.

| Produced | From |
|---|---|
| code (R-6.1) | kind × cause kind: exact list `list_still_used`; exact record `record_still_used`; `top-level` `top_level_list_changed`/`top_level_record_changed`; `read-only` `view_changes_model`; approximate or pending `list_may_be_shared`/`record_may_be_shared`; a limit `ownership_limit`; `writes` in `eq`/`compare` `comparison_changes_value`; `Dict`/`Set` storage uses the list codes |
| verdict line (R-6.2) | exact/position: "This is sharing the checker can see: …" or the rule; approximate/pending/`level`/limit: "This is a limit of the checker, not proof of sharing: …" naming the limit; an exact label never rests on an approximation (R-6.3; `p/LogAnnotateUpdate`'s message) |
| sentence, places, what the program would see, fix (R-6.6, R-6.7) | the demand kind and base text; the holder's binding, the write, the later use in source order with carets and labels, shared lines, the constructor on an entry line, "defined here" last for `top-level` with another file's path; exact and position only for the observation; R-6.7's fix table keyed by cause and base kind (`List.copy`/`Dict.copy`/`Set.copy`/`Record.copy` wrappings, "or read `h` before line N", "To be safe, change a copy:", `x ⊤`, `init ⊤ = …` with the `λ⊤ → x` warning, the `view`, `need`, pending, `payload`, `level`, entry fixes, the exact/approximate `Dict` split, never `Record.copy` for a `Dict` value) |
| `need` (R-6.8), `unknown` (R-6.9) | the function value as written / "a lambda" / "a function value" with its two places; the `⊤` cell's birth |
| grouping (R-6.10), limits (R-6.11) | one diagnostic per (position, verdict, cause, detail); one `ownership_limit` per owning declaration and limit; exhaustion stops dependent inference without secondary refusals; existing independent pending lines remain |
| JSON (R-6.6) | the same text plus each code fix as a machine-applicable edit (span, replacement) |

**Summary-size exhaustion.** Code `ownership_limit`, title **OWNERSHIP CHECK TOO LARGE**, span the owning
function/declaration name (a lambda is reported through that owner). Example at the default allowance:

> Ownership summary for `w16` needs more than 65,536 records (`ownership_summary_size`). The next record
> would make 65,537. Put repeated results in a list, make the wrapper chain recursive, or replace a closure
> tower with data and one fold. You can raise the limit with `@ownership_summary_size(131072)` on `w16`, or
> `@ownership_summary_size(module, 131072)` in this module's preamble.
>
> This is a limit of the checker, not proof of sharing.

Print the effective allowance (and its attribute location when raised), attempted count and category of the
failed reservation. Stop inference immediately; no dependent ownership noise and no clean output. This fix
is a restructure/raise suggestion, not `List.copy`: copying does not in general reduce summary size. Ordinary
aliasing refusals keep their copy fix. An attribute larger than the representable maximum is diagnosed by
`invalid_ownership_summary_size`; never suggest an overflowing doubled value. JSON may insert a validated
raise attribute, but must not pretend to rewrite a closure tower automatically. The invalid-attribute code
and both placements enter `language.md`'s diagnostic catalogue and `skills/beni/` when S2b lands.

Reported modules are the application modules this run checked (R-6.4). `check` fails with the ownership codes alone
exactly when the report has a refused, pending or limit line (R-8.1). Under `--release --allow-debug` the diagnostics
are identical and nothing is written (R-7.11).

---

## 7. Verification

1. **Corpus and pending fixtures** (R-8.1, R-8.2). `tests/corpus/ownership/`, every `build/bad/` and `check/bad/`
   fixture with a §6 code, `run/` and `browser/` unchanged; goldens compared on verdict and count lines (R-7.15).
   `tests/pending/ownership/` — 45 fixture roots (47 .beni source files, including project support files) at f309230 (CK-262 to CK-311) — is v2's acceptance; Appendix B
   maps each to its slice; each moves to the corpus as it turns green.
2. **Whole-corpus verdict diff against frozen v1** (R-8.3). `bench/ownership-everywhere.mjs --diff=<v1>,<v2>`: every
   root of oc §30.7 O1 (1 505 roots) dumped under both (`--ownership=v1|v2`, hidden), verdict lines compared per
   `(module, line:col)`: same / v2 accepts where v1 refused (each cited to a requirement or pinned as a v1 defect) /
   v2 refuses where v1 accepted (a stop condition unless the requirement says v1 was unsound). Zero unjustified
   differences is a switch-over criterion.
3. **The stale-read sanitiser, the arbiter** (R-8.5). `--sanitize-records` exists (`Cli.zig:345`, `js/Lower.zig:340`,
   `6379`): an accepted record write **copies** the object and makes each written field of the old object a read
   that throws, so a holder older than the write traps where it reads — copy-and-poison, which needs no stamps on
   edges and no boxing. S0 extends the same mechanism to lists: an accepted list write copies and poisons the old
   array (its indices and `length` become throwing accessors; a view's base likewise), `Dict` storage likewise; the
   hoisted reads run before the write as today. Under runtime safety the lowering asserts every in-place store is
   an accepted write of a clean module (R-8.9). `zig build test-records-in-place` (new: every `run/` and `browser/`
   program plain, sanitised and `--release` against its golden; `BENI_IN_PLACE=all`; the step exists at `build.zig:775` for `run_dev` only and is extended) and its list twin at oc §30.7's O5. A trap
   on an accepted program is a soundness defect regardless of any checker.
4. **Differential fuzzing.** The Lean bridge's generator (`proofs/ownership/BRIDGE.md`, recorded seeds) extended to
   records, `Dict`, patterns and callbacks: each program checked by v1 and v2, run under the sanitiser where both
   accept, judged by Lean where modelled; v2 accepts ∧ sanitiser traps is a stop. `zig build fuzz` grows an `own`
   sweep (S9); not a gate.
5. **Debug cross-checks** (R-8.8), on `std.debug.runtime_safety`, permanent: `Shape.expand` of every demand's base
   and every `res` up to 4 096 paths against enumerated projection; `join` and `union` against the pairwise
   definition; `delta` against the explicit node; `apart` against pairwise `sep`; the liveness index against a
   linear scan; `alias` against the Lean `aliases` on refinements; `widen` idempotent and extensive; the block
   round-trip; `-Downership-full-cross-check` without the path bound.
6. **Cost gates** (R-7.1, R-7.2) in `test-perf`: `WideModelArms` N = 64/256 (≤ ×5), the rotate `update` at N =
   64/256 (≤ ×5 in *time*; its facts are Θ(N²) but shared), `DeepTupleDag` to depth 32, `ListOfParams` n = 300,
   `MutualCycles`, routed-app N = 128/256 (≤ ×2.2), Conduit and Bike Wars `check` on vs off (≤ +10 %), the
   100k-line throughput, a one-body warm edit (< 15 ms). A miss is reported (rule 10).
   Add `CallbackWrapperDag` at depths 8/16/24, `WideCallbackResult` with independent N/M=16/64/256/512
   (record and tuple results, fresh and supplied/captured variants), `CallbackUnionComposition` N/M=16/64/256,
   and `ClosureTower` (Appendix B) at depths 8/16/24. Smaller cases retain their exact semantic answers;
   generated cases exceeding the full allowance **must** fail with `ownership_limit`. The explicit `w0..wk`
   labels and closure tower are forced by summary export even when no caller selects a leaf; no uncharged
   expansion before the check. Use N=512/M=512 nonfresh demanded descendants for the wide-product
   guard test, keeping each written record below `record_fields`. That fixture must actually force the product; a fresh-only shortcut is tested separately.
   On dagon's pinned ReleaseFast build, each default-limit generated module above must stop in **≤2 seconds
   of ownership-pass wall time**, after type checking, with no new process startup included; record CPU/model,
   build id, peak bytes and category counts. This is an implementation acceptance target, not a measurement
   already obtained or an asymptotic-to-seconds inference. Double excess depth/width and require ≤1.25×
   post-input ownership time once the same owner is exhausting; compare input processing separately.
   Count successful reservations, failed reservation, tasks executed, notification edges, set inspections,
   live-count transitions, template/path visits and bytes. Assert every task executes at most once and no
   work occurs after exhaustion. Fixed-size counters/queue events must match §4.1's accounting proof.
   Add zero-growth unions, N-seed/relay/N-consumer propagation, repeated holder-root activation, recursion
   through wrappers, mutual carried lambdas and supplies-only feedback. Run the same fixtures with module and
   function raises; errors become ordinary semantic verdicts where the enlarged allowance suffices, never
   changed alias answers. `OwnershipSummarySizeRaised` in Appendix B pins syntax and override precedence.
   These scenarios start with accounting in S1/S2b, callback/class cases in S4, complete run in S9.
   Soundness twins must retain: `twice`, `once/dup` and `h/k` (including recursive h) yield non-exclusive
   repeated answers; `pair` and `wp` preserve two fresh answers; `List.map` with a fresh-returning actual is
   exclusive, with a shared-returning actual is not, and with `λl → List.push l 1` relies on the input's κ.
   Mapping identity over `[x,x]` may run but its result is not exclusive; mapping an inner writer over it is
   refused. `twoAt` over `[x,x]` cannot establish distinct objects from distinct positions.
7. **Rule mutations** (R-8.7): `-Downership-mutation=<rule>`; `zig build test-own-mutations` requires each to fail a
   fixture; every trusted word's flip fails its pinning fixture. **Limits gate** (R-7.4): `own_limits_test.zig`.
8. **Lists independent of records** (R-8.6): `--ownership-records-lost` keeps every list line byte-identical.

---

## 8. The implementation plan

**Accounting precedes expansion.** The owner's chosen bound is §4.1's proved-fragment plus complete
summary-workspace resource contract, not a deferred search for a universally linear label algorithm.
S1 introduces reservations and one-shot operation records before it creates a label, inferred set or class;
every later slice extends the same account. No intermediate implementation may postpone charging to read-off.

PR-sized slices in dependency order; acceptance names fixtures (`o/`, `p/` as in the requirements); estimates are
implementer-days under the owner-away rules (one `@claude` review per PR). Everything is behind the hidden
`--ownership=v2` until §8.2. **#961 (ordered `Dict`)** is open and held by the v1 freeze; it lands *on v2* at S8:
its runtime half is rebased, its ownership half rewritten as words.

| # | Slice | Builds | Acceptance | Deps | ∥ | Days |
|---|---|---|---|---|---|---|
| S0 | **The arbiter** | the list sanitiser beside the record one (§7.3), `test-records-in-place` and its list twin, `--records-in-place`, `--diff` in `bench/ownership-everywhere.mjs`, v1 behind `--ownership=v1\|v2` | the sanitiser runs `run/` and `browser/` clean under v1 on `node` and `browser-inline`; the diff prints three lists | — | S1, S2 | 7 |
| S1 | **L0–L4 foundations** | `Ids`, `Place`, `Cell` (trie, persistent sets, splits, `alias`), `Facts`, `Prepass`, `Shape` (`union`, `widen`, coinductive `leq`), `Regions`; `rules_test` (layering, sizes, fences, dense-id); the §7.5 cross-checks for these; **Accounting from the first allocation:** `Ids.Account`, fixed-size chunks, retained operation/dependency records, deterministic fixed-key dictionaries, failed-reservation path, explicit stacks; sets/holders never run uncharged loops. | `zig build test` green; unit tests: `w5`'s DAG at 17 nodes, a cyclic type one place, `widen` on `go`'s shape, a chain of k deltas O(k log), `alias` on refinements returning a split | — | S0 | 9 |
| S2 | **Conditions and summaries** | `Cond` (κ column, per-path), `Summary` (classes table, lattice, normal form, print), `Liveness` (by path, lazy callee use-node), `Rows.fromWords` for today's words, derived-method and constructor classes (the four new words are taught to `fromWords` in S2b, which S3a's `List.push` needs through `written`); Recursive class/environment schema, stable inference keys, idempotent κ sets and the same account through class normalisation. | unit tests; `Summary.print` reproduces v1's `summary` grammar; `ListOfParams`' condition O(n); the use index answers the four queries of §2.7 | S1 | S0 | 7 |
| S2b | **Words, the spread fact, core in-process** | the four words through lexer/parser/lowering with `misplaced_ownership_word`'s rules; `Bir.Spread` recorded by `Lower`; the nominal `Send` type and `Send.to` in the browser platforms (every `send m` → `send.to m`); `core/List.beni`'s array primitives worded as R-5.10.8 asserts them (`push`, `set`, `swap`, `pop`, `insertAt`, `removeAt`, `append`, `cons`, `copy`, `length`, `at`, `view`, `put`, `traverseAt`, `focus`), the `Js.*` surface of R-5.10.9, `Dict.beni`, `Ref.beni`, `Deferred.beni`, `Log.beni`, `Task.beni` worded; `o/word-bodies.txt` extended to `taken` callers; `Rows.fromWords` taught `written`, `stored`, `taken`, `lent`; the worked derivation of `mapHelp`/`foldlFrom` in §2.13.16; **a minimal `Block`** (write/read of a normal-form class with structural places, no lazy directory, no cache section) published through the existing hook so core's inferred classes reach an application module in the same session; Raise-attribute grammar, placement, formatting, cache input and diagnostics (§4.4), `OwnershipSummarySizeRaised`, `language.md` and `skills/beni/`; **instrumentation:** record full per-owner/category high-water sizes on corpus and research apps, generator-deduplicated, report any ≥10% of default to owner. Initially record supported constructs, never call unsupported zero; repeat in S4/S7. Minimal blocks already encode class/environment backreferences. | `zig build gates` green under v1 (words erased, R-5.10.5); `cb/core/MisplacedOwnershipWord` extended; the derivation reviewed; a block round-trips | S2 | — | 10 |
| S3a | **Lists in one declaration** | `Transfer` (literals, spread chains, patterns, updates excluded, calls of worded rows only), `Demands`, `Walk` without groups, `Report`, `Message`, the facade and the ported `Enforce` hook under `--ownership=v2` (so core's worded classes reach a module through S2b's block); a declaration whose body uses a construct not yet built gets the pessimistic class behind the hidden flag, never a refusal, until S5 | whole fixtures with no callback, closure or record demand (records only as literal containers): LaterRead, StoredTwice, Spreads, SelfSpreads, Split, ViewAliases, Nest, PathCut, ParamHole, DeeperLevel, MarkerAcross (each calls only `push`, `set`, `copy`, `length`, checked by grep); `p/DeepTupleDag`. Fixtures with a callback, closure, builder or record line stay red until S4/S5 (Accumulator, Disjoint, Prepend, PrependFresh, Toplevel, Binders' `Maybe.andThen`, OneListTwoLevels' `concat`) | S2b | — | 6 |
| S3b | **Declarations call each other** | `Calls` for summarised declarations (W/E/A, `res`, κ instantiation, `xreq`), `Groups` with the worklist `Fix` **and `Fix.propagate`** (cells and bits along a group's edges), levels, initialization transfer, `eq`/`compare`'s `writes`; Charged dynamic dependency graph, fact deliveries, notifications and shape-triggered re-walks; validation shares the owner account. | ReturnsFresh, ReturnsArg, CallerSide, MutualTypes, MutualCycles, LevelLimit, LevelPlaces*, AliasWriter (Recursion's `List.close` waits for S4); `p/MutualListField`, `p/WriteOneLevel`, `p/AliasWriterCall`; the R-5.13.1 fixture; R-7.6 #428. RecursiveFunctions, FoldLevels and Initialization* need S4/S7/S8 and stay red | S3a | — | 7 |
| S4 | **Callbacks, closures, folds** | `callParam`, supply/need/keep edges, shared actual templates and label/supply views (`sep`/`within`/`need`), §7.6's callback cost scenarios, the sparse feedback fixpoint, function values and pending, once closures, local groups, `withDefault`, carried classes; §2.10 closure-recursion rule, captures retain original identity, settled facts and independent proof certificates; all 13 carried-recursion definition sites in Appendix B, GrowFresh/GrowAlias, ClosureTower. Repeat full-size instrumentation. | Callbacks, Need*, CallbackKeeps, ConditionalCallbackKeep, FoldAccumulators, FoldKeepsInner*, Once, Clo*, ClosureCapture, CapturedParam, SlotInLambda, LambdaParamNeed, CarriedLambda, CarriedFold, LocalGroups, PolyRec*, MergeCallbackCycle, MaybeDefault, ResultDefault, UnknownCallee*, Accumulator's fold, Prepend's `map`, Disjoint's `capture`; `p/CyclicFold`, `p/NeedOuterOnly`, `p/EditAnsweredList`, `p/OnceOtherHolder`, `p/CalledTwicePusher`, `p/JoinedFunctionValue`, `p/PatternStoredBack`, `p/ExclusiveFreshHelper`, `p/UpdateReturnsHeld`, `p/AppliedLambdaRecursion` (R-7.12), RecursiveFunctions, Recursion, Binders, OneListTwoLevels, Accumulator, Disjoint, Prepend, PrependFresh | S3b | — | 12 |
| S5 | **Records** | record cells, `delta`, `update` demands, per-field Dead with `field`/`call` use kinds, hoists and `Hoists` v2 (constructor step), record κ through the kind filter, `Record.copy`, once closures over records, field captures | every `Record*` fixture, `run/RecordHoistValues`, `run/RecordInPlace*`, the `.in-place` fixtures; `p/RecordSplitPushBack`, `p/RecordWriteBeforeKeep`, `p/RecordKeptInLiteral`, `p/RecordInnerKept`, `p/RecordWrapperRead`, `p/RecordProvenanceCallbackResult`, `p/RecordCopyOpen`, `p/RecordIndexExchange`, `p/ReturnedLambdaWrite`, `p/OnceLaterArgument`, `p/PrependFreshRecord`, Toplevel; R-4.8.7's fixture | S4 | — | 7 |
| S6 | **Modules, blocks, cache, core** | `Block` completed (class tables, lazy directory, versioning), the cache entry section, firewall test, core and platform facts in the checked core, `dump` of embedded core; Backreference graph encoding, no nested class copies; resource policy and allowances in cache metadata; imports charged identically cached or fresh. | CrossModule, ApartAcrossModules, OpaqueSlots, WideCtorBlock, SchemaCtorBlock, SchemaMemberExt, SchemaCtorCached, every `.cached` fixture, `cache_test`; core and every platform clean under v2 (R-1.10, R-8.4) | S5 | S7 | 6 |
| S7 | **Entry, sends, markup, schemas, casts** | `Entry` (both protocols, the sparse model fixpoint, the invariant), `Send.to` as a worded call, markup rows, schema rows, `try`'s early return, `recast` | Entry*, HostedEntry*, WideModel, WideModelArms, SplitArmsJoin, OwnedSend, SendInPayload, NestedLambdaSend, SubOnShared, Http*, RandomGenerate, EntryUrlTaggers, Conduit, ViewEventPayload, Question, Schema*, core/*Cast*; `p/ConduitEntryRecords`, `p/SendRecordObjects`, `p/ListenTopLevelStart`, `p/PushTagger`, `p/RecordForItem`, `p/RecordSchemaRun`, `p/RecordVariantMove`, `p/RecordProvenance{CtorValue,EntryPage,SameVariant,TopLevelOk}`, `p/SchemaIssuesFresh`, `p/SchemaIssuesExclusive`, Initialization*, FoldLevels | S5 | S6 | 8 |
| S8 | **`Dict`, `Ref`, `Log`** | #961 rebased onto v2 with its `Dict` rows as words; `Ref`/`Deferred` loans, `refs`, the suspension rule via `effectAt`, P-sync pinned per platform; `Task.callback`'s `Resume`; the worded `Js`/`Task`/`Log`/schema surfaces re-justified | DictFocus, DictValueWritten, DictTupleFocus*, Permutations, WriteExtents; `p/DictFocusGrow`, `p/DictHelperAlias`, `p/DictRecordAlias`, `p/DictTupleAlias`, `p/CopyApart`, `p/RefOwnsContents`, `p/LogAnnotateUpdate`; R-5.10.12's fixtures; Words, WordsBrowser, JsPure, TaskWords, core/JsWords | S4, #961 | S6, S7 | 7 |
| S9 | **Parity, cost, gates** | the whole-corpus diff to zero unjustified differences; every pending fixture green or re-filed; `test-perf` scenarios of §7.6; the mutation suite; `own_limits_test`; the fuzz sweep's first 10⁵ programs; the full cross-check run; Fail-fast time and accounting counters of §7.6, including zero-label closure towers and non-growing unions; resource headroom report to owner. | R-8.1–R-8.8 whole; R-7.1's +10 % or a report | S6, S7, S8 | — | 10 |
| S10 | **Switch-over and deletion** | §8.2 met; v2 default; `src/own/`, `--ownership=v1`, `--ownership-everywhere` and the `"lists"` key deleted; `src/own2/` renamed; goldens' v2-own lines blessed; `skills/beni/` and `language.md` §10 checked current (attribute updated in S2b, words, `Send.to`); O4a (#320) and O4b (#978) on v2 | gates green with every R-8.1 flip; `-Dllvm` green | S9 | — | 3 |

The estimate is **99 implementer-days across 13 slices**, including accounting, the raise attribute,
closure recursion, measurement and adversarial tests. The serial dependency path is **89 days**
(S1→S2→S2b→S3a→S3b→S4→S5→S7→S9→S10); S0 and parts of S6/S8 overlap. With two implementers, allow
**18–20 calendar weeks**, excluding owner/review wait time. S4 and S5 remain sequential (shared files).
S9 may uncover v1 defects needing requirement decisions; report those as issues, never weaken parity.

### 8.1 Risks and what de-risks each

| Risk | De-risked by |
|---|---|
| the full workspace reaches the chosen allowance on real code | S2b/S4/S7 category measurements and §7.6 fail-fast tests; report ≥10% headroom use, no silent cap or default change |
| `mapHelp`/`foldlFrom`'s inferred classes are not v1's asserted rows | S2b's worked derivation before any walker code; if inference cannot reach them, the finding is reported and the rows are asserted with pinned bodies under R-5.10.8 as the owner's decision (rule 10), never matched by name |
| the rotate-`update` family's Θ(N²) facts cost time on a real app | `test-perf` at N = 64/256; sharing keeps the representation O(N); no real TEA app in the corpus has it |
| `recast` loses exactness core's `Schema` needs | S7 runs core's `Schema` under the diff first; structural place identity covers core; a miss is a refusal of core, which fails beni's build loudly (R-1.10) |
| the nominal `Send` churns the platforms and corpus | one mechanical edit in S2b (`send m` → `send.to m`), before S3a reads a send |
| the keep-edge rule still misses a path | `p/RecordKeptInLiteral`, `p/RecordInnerKept`, `p/RecordWriteBeforeKeep` plus the sanitiser over `run/` |
| the entry's sparse fixpoint and κ invariant do not settle fast on Conduit | §2.10–§2.12's recursive quotient and §4.1's total operation-graph proof; S7 measures pushes on Conduit and Bike Wars |
| the Lean oracle models another algorithm (#399) | advisory (R-8.11); the sanitiser is the arbiter |
| v2 refuses what v1 accepted outside the requirements | a stop condition in S9, reported, never worked around (R-8.3) |
| `--ownership=v2` leaks into cached entries | `OWN2` blocks are a different section; a mixed cache misses |

### 8.2 Switch-over criteria

(0) §4.1's accounting invariants implemented and instrumented, §4.4's headroom gate green, no unapproved precision loss;
(1) gates green with v2 default on every platform; (2) the whole-corpus diff has zero unjustified differences; (3)
every `tests/pending/ownership/` fixture green or re-filed as a requirement; (4) the sanitiser runs `run/`,
`browser/` and the examples clean with lists and records in place on `node` and `browser-inline`; (5) §7.6's
scenarios pass or their misses are reported with numbers; (6) core and every platform clean (R-1.10); (7) `-Dllvm`
green; (8) diary and skill updated.

### 8.3 Deletion of v1

One PR at S10: delete `src/own/`, `--ownership=v1`, `--ownership-everywhere`, the `"lists"` manifest key; rename
`src/own2/` to `src/own/`; drop v1's allowlist entries and cache section; archive `ownership-checker.md` with a
header pointing here (never renumbered: rule 2).

---

## 9. Open design questions

1. **`Send` nominal.** Resolved in this revision: a `foreign type Send msg` with `Send.to` (§2.13.5), because the
   alias form loses its class through `Unify.expand`. Recorded here so the first draft's recommendation is seen to
   be reversed.
2. **The four row words versus a row file.** Recommended: words, because the parser, `misplaced_ownership_word`
   and the pinning discipline exist; a row that cannot be written stops the slice and is reported.
3. **Index exchange as an exact permutation only.** Recommended: exactly §2.13.15's two shapes (distinct literal
   indices with any permutation; one swap on two locals), since they cover #869's fixtures (`exchange` on literals
   1 and 3, `swapAt` on two locals) and any wider shape needs index arithmetic the checker does not do; outside
   them the message names `List.swap`.
4. **The `level (a)` cause.** Kept only for a `below` written while a `level` or another `below` of the same split
   is read later (§2.9); nothing else prints it.
5. **Requirements amendments — done in this PR [O 2026-10-25].** R-3.6 and R-5.10.7 now name pinned callers
   of a `taken` result and P-sync as trusted; R-5.9.9 uses nominal `Send.to`'s `consumed` word instead of
   name-based send positions (R-5.10.8's list is aligned). The core rules and O9 match those amendments.
6. **Inferring `map`/`fold` versus asserting them.** Recommended: infer, with the `taken` result word and the
   pinned index obligation on their callers (§2.13.6); if S2b's derivation shows a gap, assert with pinned bodies
   and record the deviation from R-5.10.8 as the owner's decision.

7. **Callback precision, resource and recursion — decided [O 2026-10-25].** Ordinary per-call-site labels
   stay precise. The default `ownership_summary_size` is 65,536 complete workspace records per owning summary,
   with module/function raise attributes, pre-work charging and terminal `ownership_limit` (§4.4, §6).
   Proved: place-graph O(E), fresh-result selected-path O(E+P), and the whole-module
   O(E + Σ_f N_f log(N_f+2)) time / O(E + Σ_f N_f) storage bound of §4.1. General persistent unions,
   holder transitions, context products and class tables are **resource-bounded**, not asserted linear.
   Genuine recursive summary dependencies tie backreferences, preserve original captures, settle before any
   acceptance and never discharge their own proof (§2.10–§2.12). The former rule-10 representation wall is
   resolved by these owner decisions. Implementation must meet the accounting and perf obligations; a miss
   remains a finding, not permission to merge labels or add another cap.

---

## Appendix A. Requirement coverage

| Req | Section | Slice |
|---|---|---|
| R-0.1 | §2.8 (the result is the base's object) | S3a |
| R-0.2 | §2.8 holders, §2.14 Lemma 1 | S3a |
| R-0.3 | §2.8 verdicts, §2.11 pending | S3a |
| R-0.4 | §2.14 corollary | S3a |
| R-1.1 | §2.8, §3.7 | S3a |
| R-1.2 | §1.3 item 8, §4.4 | all |
| R-1.3 | §3.7, S10 | S10 |
| R-1.4 | §2.13.4, §3.7 | S7 |
| R-1.5 | §3.7 (the hook runs on a type-clean module) | S3a |
| R-1.6, R-1.7 | §3.7, §5 fences | S3a |
| R-1.8 | §3.7 | S3a, S6 |
| R-1.9 | §3.7 | — |
| R-1.10 | §2.13.16, §8 S6 | S6 |
| R-1.11 | §2.14 O9, §2.13.6 | S2b |
| R-1.12 | §3.7 channel | S5 |
| R-2.1–R-2.4 | §2.8, §2.13.2, §2.13.6 (`written`) | S3a, S8 |
| R-2.5 | §2.6 `record_update`, §2.8 | S5 |
| R-2.6 | §2.11 item 3 | S3b |
| R-2.7 | §2.11 function values | S4 |
| R-2.8 | §2.6 `lambda`, §2.8 `once` | S4 |
| R-2.9 | §2.13.5 | S7 |
| R-2.10 | §2.13.4 | S7 |
| R-2.11 | §2.8 `consumed` | S3a |
| R-2.12 | §2.13.6 `taken`, §2.8 `focus` | S4, S8 |
| R-2.13, R-2.14 | §2.13.2, §2.13.3 | S3a |
| R-2.15 | §2.2 `site`, §2.13.16 | S3a, S5, S8 |
| R-2.16 | §2.13.16, §2.13.10 | S3b, S7 |
| R-3.1, R-3.2 | §2.14 | S3a |
| R-3.3 | §2.8 Unescaped | S3a, S7 |
| R-3.4 | §2.14 O10 | S3a |
| R-3.5 | §2.14, §3.6, §2.12, §2.13.9 | S6 |
| R-3.6 | §2.14 O9, §2.13.4, §2.13.7 (P-sync), §2.13.10 | S7, S8 |
| R-3.7 | §2.14 O11, §4.4 | S3a |
| R-4.1.1 | §2.6, §2.7 | S3a |
| R-4.1.2 | §2.1, §2.7 (uses by path) | S3a |
| R-4.1.3 | §2.6 | S3a |
| R-4.1.4 | §2.6 | S3a |
| R-4.1.5 | §2.8 Dead | S3a |
| R-4.1.6 | §2.4 (distinct locals), §2.7 | S3a |
| R-4.2.1 | §2.5, §2.7 | S3a |
| R-4.2.2 | §2.8 Unescaped (compatible point), §2.4 | S3a |
| R-4.2.3 | §2.13.12, §2.12 pre-pass | S4 |
| R-4.3.1 | §2.8 Dead (`alias`) | S3a |
| R-4.3.2 | §2.8 Disjoint | S3a |
| R-4.3.3 | §2.8 Dead (`held-operand`), §2.11 item 2 | S3a |
| R-4.3.4 | §2.11 item 3 | S3b |
| R-4.3.5 | §2.11 item 1, §2.7 (`call` uses by the callee's shape) | S3b |
| R-4.3.6 | §2.8 order, `Facts.Cause` | S3a |
| R-4.3.7 | §2.4 Esc (deep), §2.8 | S3a |
| R-4.3.8 | §2.8 Dead (`element`) | S3a |
| R-4.4.1–R-4.4.4 | §2.13.2 | S3a |
| R-4.5.1–R-4.5.3 | §2.13.3, §2.2 (a split's alias is a condition) | S3a |
| R-4.6.1–R-4.6.6 | §2.9 (per path), §2.14 I-κ | S3a, S3b, S4 |
| R-4.6.7–R-4.6.10 | §2.9 last paragraph, §2.2 | S3b, S4 |
| R-4.7.1 | §2.1 canonical paths, §2.13.3 | S3a |
| R-4.7.2 | §2.9 (the one `level` case), §9 item 4 | S3b |
| R-4.7.3 | §2.1 | S3a |
| R-4.7.4 | §2.1 (one place graph over the mutual SCC) | S3b |
| R-4.7.5, R-4.7.8 | §2.9 relied-on | S3b |
| R-4.7.6 | §2.9, §2.13.3 | S3b |
| R-4.7.7 | §2.13.3 (`below` per recursive step) | S3b |
| R-4.7.9 | §2.2 `alias` by prefix | S3a |
| R-4.7.10 | §2.13.10 | S7 |
| R-4.8.1 | §2.1 `record`, §2.6 | S5 |
| R-4.8.2 | §2.7 (use kinds; a callee's read is whole), §2.8, §3.7 | S5 |
| R-4.8.3 | §2.8 Disjoint (update) | S5 |
| R-4.8.4 | §2.6 `record_update` | S5 |
| R-4.8.5, R-4.8.6 | §2.11 item 1 with `W{F}`; §2.8 (no facts reads whole) | S5 |
| R-4.8.7 | §2.7 (`call` use never hoisted) | S5 |
| R-4.8.8 | §2.8 Dead/Disjoint | S5 |
| R-4.8.9, R-4.8.10 | §2.13.1 | S5 |
| R-4.8.11 | §2.11 keep edges (per path, through `reach` and the trie) | S4, S5 |
| R-4.8.12 | §2.7 `field` use under a written field; `Hoists` constructor step | S5 |
| R-4.8.13 | §2.11 keep per path, §2.9 kind filter | S5 |
| R-4.8.14 | §2.8 (every base has cells, O10) | S5, S7 |
| R-4.8.15 | §2.2 (constructor paths are alternatives), §2.13.4 | S7 |
| R-4.8.16 | §2.9, §2.11 | S5 |
| R-4.8.17 | §2.13.15 | S5 |
| R-4.9.1, R-4.9.2 | §2.13.11, §2.10 | S3a |
| R-4.9.3 | §2.13.11 (the refusal list), §2.12 pre-pass | S3b |
| R-4.9.4 | §2.13.11 | S4, S8 |
| R-4.10.1 | §2.8, §2.13.16 | S3a |
| R-4.10.2 | §2.13.16, §2.2 (materialisations in force) | S4 |
| R-4.10.3 | §2.2 `site`, §2.13.16 | S3a |
| R-4.10.4 | §2.13.16, §2.6 | S5 |
| R-4.10.5 | §2.13.2 | S3a |
| R-4.10.6 | §2.13.6 | S2b |
| R-4.10.7, R-4.10.8 | §2.9 kind filter, §2.13.16 | S5 |
| R-4.10.9–R-4.10.14 | §2.1 `dict`, §2.13.6, §2.9 | S8 |
| R-4.10.15 | §2.13.4 | S7 |
| R-4.11.1, R-4.11.2 | §2.13.9, §2.1 (structural identity) | S7 |
| R-5.1.1 | §2.11 | S3b |
| R-5.1.2 | §2.10 `res`, §2.11 item 6 | S3b |
| R-5.1.3 | §2.8 `param`, §2.11 item 3 | S3b |
| R-5.1.4 | §2.3 approximation | S3b |
| R-5.1.5 | §2.11 item 3 | S4 |
| R-5.1.6 | §2.6 `try`, §2.13.14 | S7 |
| R-5.1.7 | §2.6 `method_call` | S3b |
| R-5.1.8 | §2.14 O10, §3.2 `place` | S3b |
| R-5.2.1–R-5.2.4 | §2.11 items 4–5, keep edges | S4 |
| R-5.2.5 | §2.4 (a storage write is not blocked by an escaped descendant) | S4 |
| R-5.2.6, R-5.2.7 | §2.11 items 4–5 | S4 |
| R-5.2.8 | §2.11 item 5 | S4 |
| R-5.2.9 | §2.2 (two `cb j` labels compared by instantiation), §2.9 | S4 |
| R-5.3.1–R-5.3.3, R-5.3.5, R-5.3.6 | §2.11 item 6, §2.12 sparse feedback | S4 |
| R-5.3.4 | §2.13.6 (`taken` owned only within the call) | S4 |
| R-5.3.7 | §4.2 (#955) | S4 |
| R-5.4.1 | §2.6 `lambda` (whole captures), §2.7 | S4 |
| R-5.4.2 | §2.8 `once` | S4 |
| R-5.4.3–R-5.4.5 | §2.8 Dead through captures, §2.7, §2.11 (`f a _` is a lambda) | S4 |
| R-5.4.6 | §2.6 `lambda` (field captures read at creation) | S5 |
| R-5.4.7 | §2.1 `◇`, §2.9 `apart` | S4 |
| R-5.4.8, R-5.4.9 | §2.10 `classes`, §2.11 item 6 | S4 |
| R-5.5.1–R-5.5.4 | §2.11 function values | S4 |
| R-5.5.5 | §2.11 (several classes joined) | S4 |
| R-5.5.6 | §2.11, §2.12 pre-pass (alias chains) | S3b |
| R-5.5.7 | §2.6 `method_call` | S3b |
| R-5.5.8 | §2.13.1 | S5 |
| R-5.5.9 | §2.10 `classes`, §2.11 item 4 | S4 |
| R-5.5.10 | §2.11 pending | S4 |
| R-5.5.11 | §2.1 `var`, §2.11 item 3 | S3b |
| R-5.5.12 | §2.13.1 | S4 |
| R-5.5.13 | §2.10 room for #587, §2.1 class slot | — |
| R-5.6.1–R-5.6.3 | §2.12 | S3b, S4 |
| R-5.7.1 | §2.1 (slot computation), §3.6 | S6 |
| R-5.7.2 | §3.6, §3.7 (the existing hook) | S6 |
| R-5.7.3 | §3.7, `cache_test` | S6 |
| R-5.7.4 | §3.6 versions | S6 |
| R-5.7.5 | §3.8, §3.6 | S6 |
| R-5.8.1–R-5.8.11, R-5.8.13 | §2.13.4, §2.13.8, §2.14 O9 | S7 |
| R-5.8.12 | §2.13.4, §2.13.8 (the lowering interface's slot kinds) | S7 |
| R-5.9.1–R-5.9.9 | §2.13.5 | S7 |
| R-5.9.8 | §2.13.5, §2.10 `classes` (the `Expect` decoder's class travels in the summary) | S7 |
| R-5.10.1–R-5.10.11 | §2.13.6 | S2b |
| R-5.10.12 | §2.13.6, §2.13.7 | S8 |
| R-5.11.1–R-5.11.6 | §2.13.10 | S7 |
| R-5.12.1 | §2.13.7 | S4 |
| R-5.12.2 | §2.13.6 (`Log`'s `work` once; `Task.keepLogContext`) | S8 |
| R-5.12.3 | §2.13.7 (`◆` barrier, loans, `refs`, P-sync) | S8 |
| R-5.12.4, R-5.12.5 | §2.13.7, §2.13.6 | S8 |
| R-5.13.1 | §2.13.13, §2.10 `writes` | S3b |
| R-5.13.2 | §2.6 `type_dispatch` | S3b |
| R-6.1–R-6.12 | §6 | S3a, S5, S7 |
| R-7.1 | §4, §7.6 (incl. the warm edit) | S9 |
| R-7.2 | §4.1 proved fragments and total resource bound, §4.2; §7.6 | S1–S9 |
| R-7.3, R-7.4, R-7.5 | §4.4 precise labels, complete account and raise attribute; §6, §7.7; §9 item 7 | S1, S2b, S9 |
| R-7.6, R-7.7 | §3.8 | S3a |
| R-7.8 | §3.7 (the existing per-module hook, no new wait), §3.9 | S6 |
| R-7.9 | §3.7 | S3a |
| R-7.10 | §3, §5 | S1 |
| R-7.11 | §6 | S9 |
| R-7.12 | §3.9, §4.4; `p/AppliedLambdaRecursion` | S1, S3a |
| R-7.13 | S6 | S6 |
| R-7.14 | §3.7, §7 (hidden flags: `--ownership-totals`, `--ownership-flips`, `--ownership-records-lost`, `--sanitize-records`, `--sanitize-lists`, `--records-in-place`, `--ownership=v1\|v2`; `--ownership-everywhere` transitional, deleted at S10) | S0–S9 |
| R-7.15 | §3.7 `Report` | S3a |
| R-8.1–R-8.11 | §7, §8 | S9, S10 |

## Appendix B. Pending fixtures (PR #1008, `tests/pending/ownership/`) by slice

| Fixture (CK) | Requirement | Slice |
|---|---|---|
| DeepTupleDag (269) | R-7.2 | S3a |
| MutualListField (279), WriteOneLevel (280), AliasWriterCall (284) | R-4.7.4, R-4.7.8, R-5.5.6 | S3b |
| PatternStoredBack (278), ExclusiveFreshHelper (275), UpdateReturnsHeld (277), AppliedLambdaRecursion (311), CyclicFold (296), NeedOuterOnly (294), EditAnsweredList (295), OnceOtherHolder (297), CalledTwicePusher (298), JoinedFunctionValue (301) | R-4.6.9, R-4.6.7, R-4.6.10, R-7.12, R-5.3.7, R-5.2.8, R-5.2.9, R-5.4.3, R-5.4.4, R-5.5.5 | S4 |
| RecordSplitPushBack (264), RecordWriteBeforeKeep (272), RecordKeptInLiteral (273), RecordInnerKept (274), RecordWrapperRead (290), RecordProvenanceCallbackResult (291), RecordCopyOpen (309), RecordIndexExchange (283), ReturnedLambdaWrite (300), OnceLaterArgument (299), PrependFreshRecord (282) | R-4.6.9, R-4.8.11, R-4.8.12, R-4.8.14, R-4.10.4, R-4.8.17, R-5.4.9, R-5.4.5, R-4.4.3 | S5 |
| ConduitEntryRecords (—), SendRecordObjects (305), ListenTopLevelStart (306), PushTagger (—), RecordForItem (262), RecordSchemaRun (271), RecordVariantMove (292), RecordProvenanceCtorValue (291), RecordProvenanceEntryPage (291), RecordProvenanceSameVariant (291), RecordProvenanceTopLevelOk (291), SchemaIssuesFresh (307), SchemaIssuesExclusive (293) | R-5.8.9, R-5.9.3, R-5.9.9, R-5.5.12, R-5.8.6, R-5.11.3, R-4.8.15, R-4.8.14, R-5.11.5, R-4.10.8 | S7 |
| DictFocusGrow (267), DictHelperAlias (270), DictRecordAlias (270), DictTupleAlias (270), CopyApart (276), RefOwnsContents (286), LogAnnotateUpdate (308) | R-4.10.12, R-4.10.13, R-4.6.8, R-5.12.3, R-5.12.2 | S8 |
| *to write, red twins found by review:* CallbackResultTwice (`twice f = (y = f ⊤; _ = f ⊤; [ y, y ])` then `List.update … 0 λl → List.push l 9`: `exclusive`), CallbackResultForwarded (`h f = (_ = f ⊤; f ⊤); k f = (a = h f; [ a, a ])`, its recursive `h f n` twin, and `once`/`dup`: `exclusive`), the `dup2` and 3-cycle twins of RecordIndexExchange (`exclusive`) | R-4.6.2, R-4.8.17 | S4, S5 |

**Additional callback fixtures to write with S4 (not added by this docs-only revision).** `CallbackPairWrapper`
pins `wp f = pair f` with a fresh actual: a write through .0 with .1 later live is accepted; the shared-returning actual is
refused at that write. A separate `pairArg f x = (f x, f x)` twin with identity passes one list twice and is
refused at the inner write. It prevents adopting a first-instruction
fold unnoticed. `CallbackTakenDuplicate` pins identity `List.map [x,x]` and `twoAt` followed by an inner write,
plus the map-with-writer supply refusal. `RecordCallbackUnknown` pins the unidentified record-parameter field
and a known-lambda-field control. The performance generators `CallbackWrapperDag`, `WideCallbackResult` and
`CallbackUnionComposition`, including recursive and mutual-wrapper variants, are specified in §7.6.


**Owner-decision fixtures to write (docs-only PR; source files land in the slices below).** These additions are
part of the acceptance inventory, not claimed existing files. Alias twins are red for the write, green controls
must accept; a resource twin is expected to fail compilation with `ownership_limit`.

| Fixture | Required answer and minimal program | Requirement | Slice |
|---|---|---|---|
| `GrowFresh` | `grow n = if n == 0 then (λ⊤ → [0]) else (previous = grow (n - 1); λ⊤ → previous ⊤)`; `g=grow n; a=g ⊤; b=g ⊤; (List.push a 1,b)` accepts with owned local results. Recursive dependency backreference, each invocation reaches a fresh allocation, no feedback result stored. | R-5.4.8, R-5.6.3 | S4 |
| `GrowAlias` | replace base with `λ⊤ → xs`, thread xs through recursion; `g=grow n xs; a=g ⊤; b=g ⊤; (List.push a 1,b)` refuses (`alias`/`disjoint` according to the consuming probe). Same original xs through all captured backreferences. Copy a at the write gives the green twin. | R-3.1, R-5.4.8, R-5.6.2 | S4 |
| `ClosureTower` | `w0 ⊤=(xs=[0]; λflag → xs)`; each written `wk ⊤=(a=w(k−1) ⊤; b=w(k−1) ⊤; λflag → if flag then a flag else b flag)`. Fixed type `⊤ → (Bool → List Int)`, zero formal callback labels, no recursive dependency: enumerate exact ordinary creation contexts at export, trip the full summary-size limit, never fold by repeated CodeId. Generate k=24; smaller/raised twins test preserved captures. | R-7.2–R-7.4, R-7.12 | S4 |
| `OwnershipSummarySizeRaised` | source syntax below; a generated acyclic wrapper owner exceeding 65,536 full records but below 131,072 errors unannotated, checks with function raise and with module raise; a deliberately shared-result write still refuses at both settings. A 262,144 module default plus 131,072 function value is invalid (cannot lower); duplicate/local/zero/overflow attributes refuse `invalid_ownership_summary_size`. | R-7.3, R-7.4, R-7.6 | S2b, S4 |

The raise fixture's source preamble and declaration forms (replace the body with the generator's wrapper):

```text
@ownership_summary_size(module, 131072)
import List

@ownership_summary_size(262144)
large : ⊤ → List Int
large ⊤ = [1]
```

The hand-written small body checks syntax only. The resource test generator emits successive wrappers until a
count in (65,536,131,072] is reached, records the concrete generated source in the fixture, and pins the actual
category totals; it must not assume one callback label equals one full resource record. Tests never lower the
production default merely to make a trivial program exhaust it.

**Carried-recursion corpus obligations (source locations at f309230).** Nine sites from the measurement,
plus g2 and the three mutually recursive definitions: 13 definition sites. These are per-use verdicts, not
blanket approval of fixtures containing deliberate errors. All are S4, cross-module repeat S6; together map
R-5.4.8, R-5.5.9, R-5.6.1–R-5.6.3, R-5.7.1 and R-7.12.

| Source definition | v2 answer / reason |
|---|---|
| `core/Schedule.beni:184` while | Accept ordinary read-only use, terminate: returned step carries next Schedule through a genuine recursive dependency; retain schedule/predicate captures. |
| `core/Schedule.beni:259` modifyDelay | Accept read-only use, terminate with the same recursive step graph; f returns crossing Duration, captures remain. |
| `tests/corpus/browser/inline/ReturnedValidator.beni:14` firstOf | Accept run's fresh-error-list push; settle returned validator classes and their list captures before using the fresh base result. |
| `tests/corpus/check/bad/inline/RecursiveValidatorShared.beni:7` firstOf | Refuse run's push: kept top-level errors propagate through the same recursive class. |
| `tests/corpus/ownership/NominalHolds.beni:49` firstOf | Terminate; check's fresh errors accepted; twice's shared errors refused; held's validator-list push accepted (nominal type filtering); heldLists' xs push still refused. |
| `tests/corpus/ownership/PolyRecCps.beni:13` h | Terminate without an ownership refusal in h: CPS capture chain folds on recursive dependency; Int result crosses, canonical supplies kept. |
| `tests/corpus/ownership/PolyRecCps.beni:21` cps | Terminate; useCps's write at :32 refused, because original xs is read afterwards. The recursive wrapper never freshens xs. |
| `tests/corpus/ownership/RecursiveFunctions/Validators.beni:7` firstOf | Finite exported class graph; fresh-validator callers accept, shared-error callers refuse exactly as in-module. unknown's held list remains shared. |
| `tests/corpus/ownership/RepresentativePrefix.beni:11` supply | Terminate with scalar callback result; preserve representative-prefix supplies and their shared κ, no fresh proof from CPS recursion. |
| `tests/corpus/ownership/PolyRecCps.beni:39` g2 | Terminate; Int-returning closure has no ownership write; nested captures join only on the genuine recursive result dependency despite changing polymorphic input. |
| `tests/corpus/check/bad/inline/RecursiveClassGrowth.beni:7/:11/:15` a/b/c | All three settle together; bad's push at :25 refuses the shared base. No provisional-empty or self-proving cycle acceptance. |
