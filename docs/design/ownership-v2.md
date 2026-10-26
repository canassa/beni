# The ownership checker v2 — design and implementation plan

*Normative design and implementation plan. Part of #1006. The WHAT is
[`ownership-requirements.md`](ownership-requirements.md) (R-n.m below); this document is the HOW. Where they
disagree, the requirements win. End state: lists and records enforced on every platform; no copy fallback,
warning or resource-triggered coarsening; deterministic output; the `Ref` loan model (#981); ordered `Dict`
only (#961); room for #587 and an in-place shared cell type.*

**Decided resource contract [O 2026-10-25].** Precise ordinary callback labels stay. The one analysis-size
resource, `ownership_summary_size`, defaults to 65,536 **growth** records per owning declaration. Source-proportional records and unchanged
import reads have proved, nonfungible baseline lanes; nested classes, environments, contexts, sets and memo
records outside those lanes all count (§4.1). It is charged before expansion and
fails with `ownership_limit`; an attribute can raise it (§4.4). Genuine recursive summary dependencies use
§2.10's graph backreferences, never a merge of ordinary invocation contexts. §4.1 proves the total bounded
cost and identifies the fragments with stronger linear bounds; it makes no general source-linear claim.
The structural measurement's maximum **10** at `o/LimitOwnedAtoms.beni:45` counts callback labels, not the
complete new resource; S3a must measure the latter (#1056). The resource bounds explicit label growth; it does not make that growth linear.

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
**Rejected as the core.** Taken: the demand in the library's types, and uniqueness as a predicate of one type
position. `excl` claims exclusivity at the path it names, never at every descendant (§2.9, I-κ); Clean's deep
`*[*a]` is not taken.

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

**v2 is (a), with (d)'s place set and solver, (c)'s contract and driver, and a per-path sharing predicate in place of
Clean's deep uniqueness: exclusivity is claimed at one path under a summary position, never at every descendant
(§2.9, I-κ).**

1. **Places are type-shaped and folded per type SCC**, derived from the solved type graph, which `unify` builds
   coinductively (`checker-v2.md` §7.3): a cyclic type with no name (#955) is one place.
2. **Abstract values are structurally interned shape nodes over places**, with a `delta` node for a record update, a lazy
   `union` node for a join that cannot merge, and *widening onto the place graph* in every fixpoint unknown, so
   `w5`'s result is 17 nodes (#856), an `update` of N arms is O(N) (#716, #975), and every fixpoint must range over a
   finite lattice (§2.12), with inventory growth guarded before expansion (§4.4).
3. **Cells label one object per occurrence; positions and folded labels can denote many occurrences**; refinements (`elem`, `others`, `level`, `below`) are
   materialised at a match or a destructive read (SRW focus) and their non-alias is a *condition*, so a taken
   element stored back refutes exclusivity (R-4.6.9), distinct fresh elements keep it (R-4.6.7), `List.map`'s
   result is exclusive when its callback's results instantiate to distinct cells (R-5.2.9), and a split on a parameter yields `xreq`.
4. **Exclusivity is a condition per value interpretation and path** under a summary position (R-4.6.4), with one
   `apart{…}` atom per construction (#693) and the invariant I-κ of §2.14.
5. **Summaries are classes over a function type's places**, instantiated by grafting with a memo per node; a
   function parameter's class is a placeholder (`cb_j`) resolved at the call; a closure a class returns or supplies
   carries its own class (R-5.4.8, R-5.4.9). A class names no declaration: the room #587 needs (§2.10).
6. **Two fixpoint shapes, one driver**: a worklist over frames for groups and local functions, and sparse
   propagation of cells over per-path inclusion edges for a callback's feedback and the entry's model (Morphic
   I:114-171), both use finite lattices, no round cap (R-7.4); their retained operation graphs obey §4.1.
7. **Rows are data**: ownership words (oc §24) extended by the type/value words in §2.13.6; a send is a call of a worded
   operation on a nominal `Send` type (§2.13.5). No Zig names a declaration.
8. **The contract fails loudly** (Koka `fip`): every unprovable write is an error with a named fix; a resource limit
   is an `ownership_limit`; nothing is ever a copy.

---

## 2. The semantic core

Notation: `ε` the empty path; steps `.f`, `.i`, `C#i`, `[*]` (list/dictionary position), `◇` (closure
environment), `◆` (`Ref` contents), `⟨n⟩` (opaque slot), `⟲` (one or more levels below a recursive place).
`A(e)` the abstract value `(shape, κ interpretation)` of `e`; node operations below project the shape
component, and semantic transfer transports both; `Σ` the frame state; `γ` concretisation. BIR = `src/bir/Bir.zig`: a declaration
is a contiguous instruction range in evaluation order, every binding a distinct local index (`Lower.bindLocal`
appends; nothing rebinds).

### 2.1 Places

A **place** is a node of the type-shaped graph, with children by step. Structural store nodes and nominal
constructor applications supply its nodes; lexical closure environments add accounted edges. A type variable,
function type, crossing primitive or foreign type without published slots is a leaf. **The graph source**
combines the solved structural store with each nominal type's *constructor templates*:
`Walk.structural`'s successors of an `app` are its type arguments, and a constructor's payloads are not in the
store at all. For a type of the module being checked the templates are its BIR `ctors` over `declTypeParams`; for
an imported type they are the interface's `arg_terms` (what `Schemes.instantiateCtorWith` reads), an opaque type
read through its published slots. A record, tuple or function type is read off the store variable as before.
The walk substitutes the argument *places* for the type parameters — an environment over places, never fresh store
variables (`Instantiate.ctorType` allocates flex variables per use, needs a live checker frame and would unfold a
recursive type forever) — and memoises on `(head TypeId, argument PlaceIds)`, which is this section's own
structural identity `(kind, head, children)`: so a recursive type, named or not, folds onto itself at its head,
a *different instantiation* (`Tree (Tree (List Int))`'s inner tree, `Maybe (Maybe a)`, `Dict String (Dict String …)`'s
inner dictionary) is another place (R-4.7.3), and a non-regular nested type (`Nest a = Cons a (Nest (List a))`),
whose instantiations never repeat, folds at its head after the first level — one place for every `Nest`, the
argument places joined — so the graph stays finite. `Place.zig` is a pure graph walk over a `Place.Source`
interface that describes one node as `(kind, head, children)`; the adapter from the checker's tables is built at
the `Enforce`/`Groups` boundary (§8, S3a) and is the one piece of `own2/` that reads a type's structure (§5).

| Place kind | Steps | Holds a cell of kind | Notes |
|---|---|---|---|
| `record` | `.f` per field | `record` | every record type (R-4.8.1) |
| `tuple` | `.i` | none | never written |
| `ctor` | `C#i` per constructor and argument | none | **a sum**: paths through different constructors are alternatives (§2.2); a record-alias constructor is a `record` |
| `list` | `[*]` | `list` | `[*]` is a *summary* place (positions merged); supplied for List and Builder by `sequence` metadata (§2.13.6) |
| `dict` | `[*]` (values) | `dict` | keys cross (R-4.10.9); `Set` is `Dict k ⊤` |
| `ref` | `◆` | `ref` | types carrying `cell` metadata, including Ref/Deferred; `◆` is a barrier (§2.13.7) |
| `closure` | `◇` | `closure` | the environment; children are the captured paths; carries a class slot (§2.10) |
| `opaque` | `⟨n⟩` per published slot | `opaque` | `Js.Value`, `Html`, a program (R-4.6.5) |
| `var` | none | any | a type variable may hold anything (R-5.5.11) |
| `cross` | none | none | primitives, `⊤`, `⊥`, a nominal type reaching no tracked place, a crossing foreign type |

**Identity.** Initial construction uses a dense `by_var` memo for structural source nodes and the adapter's
`(head, argument places)` memo for nominal applications. Each source graph node and outgoing edge is visited
once; no global structural interning is required to construct its cycles. SCC/reverse-edge work computes
`holds` in O(nodes+edges), never by rescanning the whole graph until unchanged. Constructor-template
substitution and non-regular joins are charged adapter operations, not free solved-store edges.
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
| `mark u` | a use label: `{R,A,E,W}`, fields and deep bit at a parameter path | same mark through a use leaf; explicit children select finer use paths | not a runtime object |

`mark` cells inhabit use shapes only. Their payload is an interned use record; they never enter object
provenance, `apart`, or a result shape. This uses the same cell/set machinery without a NodeId-keyed label
column: two structurally shared nodes can carry different use facts through different cell sets.

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
R-5.4.2, and dependent-transfer invalidation). The places where one label stands for several objects are
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
`taken` passes **under κ of its container at the supply's path** when the occurrences are splits of **one
traversal** (*Traversals* below; splits of two traversals fail, `lost`) — two `taken` positions are two objects only where
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
one canonical path is a prefix of the other, or — **`⟲` matching** — when, past
their deepest common node, one side continues with `⟲` re-entering a place `P` and the other side's divergent
step leads to a place that can reach `P` again (the step is on `P`'s cycle: the places in `P`'s strongly connected
component of the place graph), because the levels below `P` include whatever that step reaches; a step off the
cycle stays `no` (`Node Tree (List Int) Tree`: `π·#Node.1`, the root's own list, against `π·⟲`, the subtrees; but
`Rose (List Rose)`: `π·#Rose.0`, the root's children list, against `π·⟲`, the subtrees, is `yes`, since the
subtrees are its elements). Holder discovery agrees with this relation for every demand, shallow or deep: §2.8's
*cycle anchors* find the holders of every cell that `⟲` matching relates to the demanded one, not only those of its
trie ancestors and descendants. **Except** that two paths diverging
at a `ctor` place on *different constructors* are alternatives and never `~` (one value has one constructor;
`π₂·status#Editing.2` and `π₂·status#Saving.1` are not a sharing of one argument, R-4.8.15; two *elements* built
with different constructors are two positions and are compared by `apart` at the construction); concrete cells
`~` when equal; `⊤` with everything; and when `a`, `b` descend from one split ι on different sides (`elem`/
`others`, `level`/`below`, two `below`s of distinct steps, two `level`s of distinct steps) the answer is *under
ι*; and when `a`, `b` are two `taken` `elem`s of one container from *distinct* splits **of one traversal**
(`elem(xs·ι_t)` and `elem(xs·(ι_rec·ι_t))`: two positions read once each, O9; *Traversals* below) the answer
is *under the container's κ*, while two `taken` `elem`s of one container from **two traversals** may be one
position and alias (`lost` in a `sep`, never an atom: a traversal visits every index again, #1029); the general
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

**Traversals** (#1029). Let G be the recursive group of a pinned `taken`-result caller (§2.13.6, O9:
`mapHelp`, `foldlFrom`, …). One **traversal** is one activation of G entered from outside G, together with
every G activation it reaches through G's own recursive calls. The index obligation holds per traversal:
"once per index, one way" is true inside one traversal and says nothing across two. A second traversal of the
same container hands out the same positions again.

**The `single` bit.** A folded label keeps only its first instruction and drops its tail, so a split cannot
be traced back to its traversal by its chain. It therefore carries a bit, `single`, which says that every
activation its label stands for belongs to one traversal.

- **Set** when `traverseAt` makes the split in G's frame. G's own recursion (`ι_rec⋆`) keeps it: those
  activations are the same traversal.
- **Kept** when the split leaves a frame through a plain call instruction's view, even when that instruction
  is folded *ordinarily* (under `[*]`/`⟲`, or a folded callee label). One execution of that call in one
  activation of the frame is still one traversal. So `List.map`'s splits are `single` at `ι_m⋆`, and so are
  a caller's at `(ι_c·ι_m)`.
- **Cleared** in two cases:
  - the label folds an instruction *recursively* (it calls into its frame's own recursive group, outside G);
  - a cell that a callback's actual class makes itself (a split made at any depth under the actual's frame,
    in nested callees and closures and on captured containers alike, under the labels `(ι·λ)·…`; only the
    cells grafted from the actual's supplies are excluded) is carried out through a **folded callback label** `λ⋆`, or through a callback with
    `calls many`.

  In the second case, the actual's activations are many, and each may be another traversal. Cells grafted
  from the supplies (the actual's `π_k`) keep their own bit: a supply is substitution and makes no split.
- **Joins**: where both triggers fold one instruction, *recursive* wins, and the bit of a joined cell is the
  AND of its parts (a fold that merges splits of two traversals into one folded split is not `single`).

**Traversal provenance.** A split certifies a container lineage, an entry occurrence, and at most one
traversal of that lineage within the occurrence. The pinned once-per-index discipline supplies distinct
positions only inside that certificate. `single` and `entry` encode its cardinality and entry identity;
neither bit nor label equality alone proves separation. Substitution preserves the lineage and the
certificate; the clearing and join rules above weaken it when repeated entries are possible.

**Comparing two `taken` elements of one container.** Two *distinct* split cells are apart under the
container's κ only if both are `single` and their entry prefixes are the same. One folded split cell met
twice stays §2.9's `sep(c, c)` (`lost`), unless the comparison is a `within` made by a fold over an existing
`sep` atom. The entry prefix is the prefix of the label's chain up to
and including the call that last entered the G whose `traverseAt` made the split. In G's own frame it is
empty; each instantiation prepends the caller's call instruction.

Everything else is two traversals, which give `lost` (approximate) wherever a `sep` or `within` compares
them:
- different entry prefixes (`List.map xs` and `List.foldl xs` in one body);
- a split that is not `single`: a recursive caller traversing `xs` once per activation, or
  `each ws xs f = List.map ws (λ_ → List.map xs f)`, whose inner traversal runs once per element of `ws`.

No κ of the container separates two traversals: each visits every index again. The red twins
`TwoTraversalsShared`, `FoldOverFoldShared`, `NestedTraversalShared` and, across modules, `NestedTraversalAcrossModules` (Appendix B) check the rule. Blocks carry the bit and the entry (§3.6 *Traversal marks*).

### 2.3 Abstract values: shape nodes

Structurally interned per owning summary with deterministic comparison trees (thesis §4.2; Chase–Wegman–Zadeck). A node denotes a function from paths to sets of
`(cell, approx)`.

| Node kind | Fields | Meaning |
|---|---|---|
| `leaf` | `place`, `cells` | `cells` at `ε`; below, whatever the symbolic cells project to |
| `node` | `place`, `cells`, `children: [step → NodeId]` dense over the place's steps (`none` = nothing) | a built value |
| `delta` | `base: NodeId` (never a delta), `over: OverId` — a persistent sorted tree of `(step, NodeId)`, path-copied, O(log F) insert and lookup, structure shared along a chain of updates | the base written: at `ε` the base's cells, at `s` the override or the base's child; a chain of k updates costs O(k log F) |
| `recast` | `place`, `inner: NodeId` | `inner` read at another type (§2.13.9): `inner`'s cells, approximate, at every path |
| `union` | `left: NodeId`, `right: NodeId` (a binary DAG; never flattened) | the lazy join of **alternatives** (control-flow and fixpoint joins): `cellsAt` the union, `proj` the union of projections, both memoised per `(union, step)`; a cell repeated across sides is one position |
| `positions` | `left: NodeId`, `right: NodeId` (a binary DAG; never flattened) | a **positional collection**: the elements under one built value's `[*]` (a literal's elements, a spread's combined positions), all present at once; `proj` keeps the kind and `cellsAt` is the set of the sides' cells, while the κ read counts a cell that both sides hold once more (below), so a cell repeated across sides is two positions and `apart` runs over the multiset of the sides' arrivals (§2.9) |
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
  one `delta(base, s ↦ join(overrides present, base's child))`, O(k + T log(T+2)) grouping/sorting work for T=Σ|Oᵢ| before recursive child joins and set unions; leaves with no children → one leaf with
  the set union; the groups left (one per distinct base, plus leaves) → a balanced `union` DAG over them,
  O(groups) outer nodes; inner work uses §4.1 accounting. A join can have product query work; a projection through a union costs O(groups) once per `(union, step)`.
- `collect(n₁…nₖ)` (`Shape.collect`): a built value's elements under `[*]` → a balanced `positions` DAG, never
  deduplicated or absorbed, built like `join`'s outer DAG; one element is itself. `join` itself only ever makes
  `union`. `map` and `propagate` preserve the kind.
- `proj(positions(a, b), s) = positions(proj(a, s), proj(b, s))`: projection keeps the kind and so the
  multiplicity. `cellsAt` of a `positions` node is the **set** of its sides' cells, as for a union; the multiset
  belongs to the κ read (`Cond`'s `dagKappa`, §2.9), the one reader of multiplicity, which counts each cell held by
  both sides of a positions node once more (`Radix.intersection` of the sides' cell sets, one descent per node).
  Reading a positions node as a union would drop a repeated argument's second arrival and accept
  `PositionsRepeatArg` (unsound).
- `leq` is **γ-inclusion and kind-blind**: `n ≤ m` iff `cells(n) ⊆ cells(m)` and `proj(n, s) ≤ proj(m, s)` at
  every step `s` of n's place, whatever the two nodes' kinds. So `x ≤ a` gives `x ≤ union(a, b)`, a `union` is
  below `y` when both its sides are (every member is below its join, O4), and two `positions` nodes compare by
  their cells per path, independent of their members' order and of the balanced tree's shape. Multiplicity is not
  part of γ: it is compared only through κ, by `Cond.kappaLeq` (§2.9). A structural rule — `x ≤ union(a, b)` iff
  `x ≤ a` or `x ≤ b`, with two `positions` nodes matched member to member as multisets — cannot settle §2.12's
  `F(x) ⊑ x` under `widen`: widen keeps a collection as a side beside its class image (below), so
  `positions(x, x) ≤ union(image, positions(a, b))` would need `x ≤ a`, which is false although γ holds, and the
  fixpoint would keep growing. γ-inclusion settles `F(x) ⊑ x` in one step for `Rose [ x, x ]` over the widened
  value, at the coinductive pair cost and with no matching task.
- `widen` across kinds: widen never expands a `union`'s or a `positions` node's sides and never unifies two
  sides pairwise. A member of a congruence class that is not explicit structure rides beside the class image:
  the class's leaves (and a delta's leaf base) fold into one leaf, and a recast, union or positions member stays
  as it is; these are the sides of a `union` with the image. A class with no explicit member is its side alone.
  The image is a newly built `node`, so it has no stored κ, and a read through it derives `lost` (§2.9's rule for
  a built node). Folding recursion ties the children of `Rose [ Rose [], Rose [] ]` to the root class, so a repeat
  across them reads `lost` (approximate), as a folded label does (§2.2), never exact `shared`
  (`FoldedPositionsLost`, Appendix B). This is coarser than exact for a non-repeat, which also reads `lost` there
  where an exact `apart` would hold. **Invariant: no stored κ reaches a widened image at a summary position**; a
  condition set there is that position's own derivation (the read-off's, S3a), never one carried from a member's
  snapshot.
- `put(n, s, m)`: `delta(n, [(s, m)])` when the `ε` object is the same after the write (an update), else a copy
  with one child changed (a construction's fresh base).
- `map(n, f)`: relabel cells once per node per immutable substitution context, so a DAG stays a DAG
  (`w5`: 17 steps, #856). Its correspondence hook reports old/new node and child edges, including backedges;
  `Cond` transports the associated κ snapshot through that mapping in S3b. Shape sharing alone never selects
  or overwrites a condition.
- `leq(n, m)`, `eq(n, m)`: **coinductive** lockstep inclusion/equality (the kind-blind γ-inclusion above), memoised per immutable-version pair with a **shape-only** coinductive assumption on
  entry (so cyclic nodes compare in O(|n|·|m|) pairs at most, O(|n| + |m|) when shapes agree).
- `widen(n)`: the place-graph quotient used by every fixpoint unknown and every read-off: a node whose descendant
  along a re-entering step sits at the same place is joined into that ancestor and the edge tied back to it, so
  a shape has at most one node per canonical path of its place graph. Over a non-recursive type it is the
  identity (no re-entering step), so `w5`'s DAG is untouched. Compute the quotient by a canonical-path
  worklist and congruence closure: union node classes on re-entry, merge their step maps, enqueue the
  corresponding child pairs, and emit the quotient once. Union-by-size/path compression and smaller-to-larger
  fixed-word radix step-map merging give O((nodes+edges) log(nodes+edges)) structural work; path/set tasks remain charged.
  Do not repeat a whole DFS after each merge or rescan all children. Preserve a delta's non-node base
  projections and every unwritten sibling. Fold joined leaves into a set leaf, not an expanding union chain.
- `expand(n, bound)` (safety builds): the enumerated `(path, cell)` set up to `bound` paths, for §7.5.

**Memo safety.** Reserve before any interner/dictionary lookup, including a hit. Publish a memo result
only after every fallible operation establishing it succeeds. Cyclic builders may register provisional
backreferences, but these are transaction-local: failure removes/invalidates them and no other owner reads
them as completed answers. `leq` tracks pairs, not only left nodes; provisional coinductive assumptions are
shape-only and all dependent provisional answers are invalidated on false or error. Reach uses SCC results
for all members of a cycle, not repeated backedge path walks.

**Approximation.** A `(cell, approx)` pair is approximate when it came through a `recast`, a joined `res` naming
two provenances at one path (`if c then [ 0 ] else xs`, R-5.1.4), a `⊤`, a conservative call, or a side of a
split whose κ was `lost`. A refusal resting on approximate pairs alone is approximate (R-6.3); an exact failure
wins. An empty set means *provably no cell* (thesis §3.4); `⊤` means any (O10).

**Invariant I-shape.** `γ(n)` = every value whose object at each path `q` is in `γ(cellsAt(n, q))`; every
operation above is extensive on `γ` (O3).

### 2.4 The state of a frame

A frame is a declaration body or a lambda body (oc §7.3):

- `Σ`: the **binding log** `(local, NodeId, KappaId)`, append-only; a local is bound once and lexically scoped, so a `case`
  joins arm values but not SSA binding logs (§2.6); the log, `taken` and `pending` are popped to the mark
  taken at an arm's start. In-scope bindings at a point = the log segments of its enclosing regions (§2.5).
- `contents`: the versioned cell-slot relation `contents(handle-origin, ◆)` (§2.13.7). Fork its root at a
  branch, apply ordered slot effects in each arm, join possible contents at the continuation; unlike SSA
  binding logs this state MUST join. A loop/group propagates slot memberships and ordered effects to its
  settled post-fixpoint before writes/loans are judged.
- `Esc`: the monotone set of `(cell, point)` escapes (thesis §3.4). **Escape is deep and directional**: escaping a
  node marks every cell in `reach(n)` (once per node, memoised); a cell is *escaped at p* when it or any trie
  ancestor of it (a symbolic prefix or a refinement's parent; concrete containment needs no link because escaping a node marks its `reach` eagerly) escaped at a
  compatible point before `p`. A *deep* demand (send, `consumed`, focus) is also blocked by an escaped descendant;
  a storage write is not (a callback keeping a list stored inside the accumulator does not refuse writes to the
  accumulator, R-5.2.5 #749). O8.
- `taken` (§2.2), `pending` (operands evaluated whose consumer has not run), `uses`, `demands`, `supplies` (each
  call of a function parameter: the point and the nodes handed, §2.11).

### 2.5 Regions and points

A **point** is an instruction index. `Regions.zig` reads the region tree off the BIR once, using
subtree starts for a forward `let` body and retaining actual sibling-arm exclusions in virtual
`withDefault` regions (a virtual continuation does not make every later sibling compatible): a region per `case` arm,
`let` body and lambda body (a frame boundary), with `start`, `end`, `parent`, its case, and for an arm its *guard*
when the scrutinee is `i == e`, a `method_call` of `eq` `Dispatch` resolves to `Int`'s (§2.13.15). Two points are **compatible** when neither lies in an arm of a
case the other lies in a different arm of (oc §7.2). The region tree is series-parallel: a case's arms are parallel,
everything else is in sequence. `Regions` numbers a case's arms so that they tile the case's span after its
scrutinee, and gives each region `base₂`, its start in the **second order**, which lists every case's arms
(virtual `withDefault` arms included) in reverse. **Precondition: each case's arms are adjacent in the point
order**, so that they tile its span; `rank₂` is correct exactly where this holds. The pipeline form
`m |> Maybe.map f |> Maybe.withDefault d` lowers the `withDefault` reference between the map call and `d`; that
point lies between the arms, but it has no use and no demand, so no query asks about it and no compatibility
answer changes. A child region spans the same length in both orders, so a point
x directly in region r keeps its offset: `rank₂(x) = base₂(r) + (x − start(r))`. A series-parallel order has
dimension two, so for points p < u, **p and u are compatible exactly when `rank₂(p) < rank₂(u)`**. "After `p`,
compatible" is therefore one threshold on `rank₂`, never a list of ranges (§2.7). The binary-lifting ancestor
slots of §4.1 answer the same test for a pair of points and name the case and arms that separate them.
In the virtual `withDefault (map m f) d` region the inner `map` call belongs to the f arm, so the two arms tile
the span from the f arm's first point to d's last. The call writes only through `f`, on a payload that exists only
when `m` matches, which is the f arm's case; so a demand at the call never has a write that d's uses could
observe, and making the call incompatible with d loses nothing. Without this, the call would be compatible with
both arms while the arms are not compatible with each other, which no pair of orders can express. S2's
`compatible` must give the call this answer, and S4's `MaybeDefault` and `ResultDefault` pin it. The `withDefault (map m f) d` shape (R-4.2.3) is marked by the BIR
pre-pass (§2.12) as a two-arm region, so it has arms in this tree.

### 2.6 Transfer rules

`Transfer.eval(frame, inst) → Value{node: NodeId, kappa: KappaId}`, one case per BIR tag, recording uses at the consumer (R-4.1.1) and demands
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
| `call` | §2.11; a call of a *function parameter* πⱼ at instruction ι: the result leaf `{cb j@ι·ε}` with the callee's class slot, each argument recorded as a supply `(j, label, k, node, κ, point)` and used at ε, kind `call` | per the class `use`, kind `call` | call-site demands, edges |
| `method_call` | the dispatch table's callee as `call`; a nullary method is a call (R-5.1.7); a field of function type is a call of the field's value reading only that field (R-5.5.7); unresolved → unknown (R-5.5.4) | as `call` | as `call` |
| `type_dispatch` | `⊤`; every operand's cells join Esc (as a wordless `foreign`, O1) | operands | — |
| `lambda` (also `f a _`, which `Lower` makes a lambda, `Lower.zig:2725-2733`) | a `closure` node: cells `{site ι}`, child `◇ ↦ env node` whose children are the captured `(x, q)`'s nodes at creation; the body walked now as its own frame → the lambda's class (§2.10). **Captures**: a *field* capture `(x, .f…)` is a **read at creation**, kind `field` (hoistable: a closure created after a write of that field reads the old value through the hoist, R-3.2; created before, it holds the field's value, not the record, and is no use of the record, R-5.4.6); a *whole* capture `(x, ε)` is a holder, used wherever the closure is consumed (R-5.4.1). A body writing a capture makes the closure **once** (R-2.8): its creation is a demand on each written capture | field captures at ι; whole captures at consumption | once demands |
| `let`, `let_def`, `let_pattern`, `let_stmt` | the body; a `let_def` with parameters is a local function (a frame in the block's local group, §2.12); `let_pattern` a one-arm case; `let_stmt` consumes its expression | the value at the binding | — |
| `case`, `branch` | per arm: the pattern's locals bound to projections/materialisations of `A(scrutinee)` (§2.13.3); the arms' values joined | the scrutinee, kind `whole` | — |
| `try` (`e?`) | the resolved success payload projected; the `failure`-marked payload (§2.13.6) joins the result of the definition `?` returns from (R-5.1.6) | `e` | — |
| `markup` | a call of the markup row (§2.13.8) | its values | — |
| `schema_*` references | a schema member or constructor: the schema row (§2.13.10) | — | — |

Arguments are consumed at the call, items before the base is written (R-4.1.3); every forwarded result is a use
at that point (R-4.1.4).

### 2.7 Uses and liveness

A **use** is `(atom, local, PathId, point, kind, callee-use-node?)`, where `atom` is the use occurrence: unique in
its declaration and deterministic, not the operand instruction, so one instruction reading a local twice has two
uses and the transfer rules of §2.6 need no change. Kinds: `field` (this frame's own field chain,
record pattern or field capture — **hoistable**), `whole` (a scrutinee, a comparison at the root, a store, a
return, a send, a whole capture at consumption), `call` (an argument: the callee reads it at the paths its class
`use` names — recorded once as `(local, p, use-node U)` and answered lazily by projecting `U` along the queried
remainder; **never hoistable**, since the read happens inside the callee: R-4.8.2 bullet 4, R-4.8.7). Uses are
keyed by **path**, never by place (two fields of one record type share a place).

**The index** (`Liveness.zig`, §3.4a): per `(local, PathId)` the uses sorted by point; each use is stored once at its own path.
Paths are ordered lexicographically by their steps, so a path's subtree is one contiguous range and no use is
copied to an ancestor. Construction gives every canonical path node that an indexed path passes through its rank
in that order and its subtree's rank interval, once, so a query navigates by one-word comparisons of ranks and
never rereads a path's steps. Per-local last-use and range-index nodes use the one-key lanes of §4.1. A query
descends the range index explicitly; every node and candidate it visits is a retained query task, classified
before work into §4.1's direct-demand query lane or growth.

**Compatibility is a threshold.** Each index entry carries its use's `rank₂` (§2.5), and each merge-sort node keeps
a max tree over the `rank₂` of its pairs. "The first use of this range after p and compatible with p" is then one
descent: a binary search past p by point, and a max-tree search for the first `rank₂` above `rank₂(p)`. Every
candidate it returns is compatible, so a nested `case` produces no region intervals and no rejected incompatible
candidate. The binary-lifting ancestry query (§4.1) decides the same relation for a pair in hand: a holder's use in
`Demands`, a keep edge.

**One query per prefix.** A demand reads its path once. For the direct holder (the base's own local at the written
path q = s₁…s_d), the query for prefix q_i = s₁…s_i is one rank lookup (q_i is q's trie ancestor, so no step is
compared) and one exact-run descent, both on step s_i's own direct-demand lane (§4.1). The subtree query at q, or at
q·f for each written field f ∈ F, is one rank-interval descent on the last step's lane or on f's; a `call`
candidate's use node is tested at q·f on f's lane too. **Per demand,
the direct holder costs d + |F| direct-demand kernels, each O(log² U) fixed-word work in its own baseline lane:
no growth, whatever d and the case nesting depth.** Up to two further holders per
demand are baseline as well: in `let items = model.items in { model | items = List.push items x }`, `model` also
holds the written cell. Each runs the same prefix queries over the path at which it holds the cell, on the lanes
of §4.1's *holder and callee path words*. Separately reserved: a `call` candidate the kind filter rejects (its
use node empty at the remainder of q), holders beyond those two, a joined or deep cell set's further cells, and
inferred alternatives. These are §4.1's demand×use and demand×holder products.
Queries at a demand point `p` for holder `(h, q)` of cell `c`:

| Query | Lists | Answer |
|---|---|---|
| a use of `h` at an ancestor of `q` or at `q`, after `p`, compatible | `(h, q')` for each prefix `q'` of `q` | a whole use (`later-use`/`alias`); a `call` use counts the same when its node `U` is non-empty at the remainder of `q`, or (record demand) at `q·f` for some `f ∈ F`; a `call` use non-empty only at untouched fields is no use |
| a use under a written field `f ∈ F` (record demand) | subtree of `(h, q.f)` | kind `field` → a **hoist**; kind `call`/`whole` → a whole use, refused |
| a use under `q` (list demand) | subtree of `(h, q)` | a use |
| an untouched field's use | never read | — |

Query cost is the bound of *One query per prefix* for the direct holder; other holders and rejected `call`
candidates pay their own reserved tasks (§4.1). No bound solely by returned uses is asserted. `R-4.8.2`'s untouched
fields cost nothing.

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

1. **Known**: `c ≠ ⊤`; a loan cannot be written, consumed, sent or escaped. Every `cellstored`
   payload and every store into ◆ has a deep no-loan demand, inspected **before** constructing the destination
   barrier; a crossing result does not omit this demand. Reads through a loan remain permitted while its
   lifetime is valid. Projections, aliases and casts preserve the loan tag; a shallow outer copy does not clear
   tags on its children. Ordinary `stored` preserves each payload's loan tags at the destination paths;
   a fresh outer container does not erase them. Reads and such local construction are permitted. Only
   genuinely copied/rebuilt storage has a new non-loan origin, at precisely the copied depth.
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
**live** persistent-set node (§3.2) whose key is a cell is chained from that cell (a column of `Demands`' holder index,
`set_head`, with `prev`/`next_same_cell` on the set nodes: dense ids indexing columns, not a map) — a node is
linked when its live count goes 0 → 1 and unlinked when it returns to 0, so a dead or never-registered node is
never in a chain — every set node keeps its live parent links with a live count, and every holder — a binding, a pending operand, a capture — registers on the
root of its node's `reach` set. A holder **expires** at its last use (known from the index) during the
evaluation-order sweep — **after** the point's own result has been registered, so a result whose `reach` shares its
operand's set nodes keeps them live across the hand-over (`mₖ = { mₖ₋₁ | f = [ k ] }`: `mₖ`'s root is registered,
then `mₖ₋₁` expires; the shared subtree never drops to 0 and is never relinked, O(log) per step, not O(k)) — it is
unregistered, and a root with no holders decrements its children's live counts
recursively, so a set node with no live parent is skipped. `holdersOf(c)`: for `c`, its trie ancestors, (deep
demands) its trie descendants and the live cells its cycle anchors name (*Holders across a cycle*, below), walk the chain of set nodes keyed by that cell and climb their *live* parents to
the roots. This is candidate discovery, not the final holder answer. When ι is in force, reinterpret a
whole-container holder as `others c·ι` before testing overlap with `elem c·ι`; the split's κ at q
excludes only the corresponding path q in other positions. It never excludes an alias at another sibling
path. For `xs=[(a,b),(b,a)]`, writing the first component while retaining the second must still fail
Disjoint/holder checks, despite each component being individually exclusive across positions. Explicit element aliases still hold it, and missing/lost κ supplies no exclusion.
Use the same refinement-aware `alias` predicate for ancestors, pending operands and reached paths, so climbing
to the container cannot undo materialisation or refuse mapHelp's pending input. Every set node visited is live and contains the cell (the chains hold live nodes only), so no dead scope is scanned. A DAG can nevertheless have many live parent routes to the same holder;
use a query-local stamped visited column and charge every inspected live edge (§4.1). Maintenance is O(nodes whose live count changes) per
registration or expiry, each node once per transition: at `bₖ = List.push aₖ 0` with N other bindings live, only `aₖ`'s set contains `site aₖ`, and a chain of
k record updates finds only `m_{k−1}` once `m₁…m_{k−2}` have expired. Then, for each holder, the paths at which it
holds the cell (a pruned walk of its node guided by `reach`), and §2.7's queries. Cost per demand includes the live parent edges, holder-path visits and queries actually inspected;
§4.1 bounds their module total. Distinct routes to one root are visited once per query. The second review's `ys = r.a` then `send (Got r)` is found: `send` is deep, `param π₂·.a` is a trie
descendant of `param π₂·ε`, `ys` holds it and is used after → refused (R-5.9.1).

**Holders across a cycle (`⟲`).** Trie ancestors and descendants are not every cell `alias` relates to `c`. Take
`type Rose = Rose (List Rose)` and `case r of Rose kids → (kids, incKids r)`, where `incKids` writes only
`π₁·⟲·#Rose.0`. The call's demand is on `r·⟲·#Rose.0`, the subtrees' lists; its trie ancestors are `r·⟲` and `r`.
`kids` holds `r·#Rose.0`, a `List Rose` whose elements are the cycle, and `alias` says yes: the step `#Rose.0` is on
`Rose`'s SCC (§2.2). So `kids`, the tuple's pending operand, is a holder, and the call is refused `held-operand`. A
climb alone misses `kids`, and the subtrees' lists are then pushed in place. The rule, for every demand:

- A **cycle anchor** of a symbolic path q is a prefix q₀ of q whose place P lies on a cyclic SCC of the place graph
  and whose next step s in q stays on that SCC: s is `⟲`, or a step to a place of the SCC. Anchors are read off
  the canonical path when a cell is interned, so a cell has at most L(P) of them, L(P) ≤ 2·|places| the longest
  canonical path below its root place P in P's SCC-folded graph: a type-sized count of that value's own type.
- **Refinements** (`elem`, `others`, `level`, `below`) hang off the cell they refine, not off the trie node of
  their canonical path, so neither a climb nor an anchor reaches them by path. In
  `case r of Rose kids → case kids of [ c, …_ ] → case c of Rose ck → (ck, incKids r)`, `ck`'s canonical path is
  `r·⟲·#Rose.0`, the written cell itself; with `xss : List (List Int)`, `elem(xss·ι)` is canonically `xss·[*]`.
  So a refinement is also linked into the **refinement chain** of its canonical path, keyed by
  `(base origin, canonical PathId)`, and anchors by that canonical path.
- `Demands` keeps one anchor chain per `(base origin, anchor PathId, step class)`, where the step class is `⟲` or
  `on-cycle`, beside the refinement chains. A cell is linked into its chains when its live count goes 0 → 1, and
  unlinked when it returns to 0, beside its `set_head` link, so a chain holds live cells only. A cell's first
  activation links it on the lane of the source atom that interned it, role *anchor links*, at most L records
  (the excess reserves growth when L > 512); a later activation relinks as growth, as every later activation does
  (§4.1).
- For each cell c of the demand's cell set (a deep demand's enumerated cells included), read the refinement chain
  at c's canonical path and at each of its trie ancestors; and for each anchor q₀ of c's path with next step s:
  - if s is `⟲`, read chain `(q₀, on-cycle)`: an on-cycle container's holder reaches the written levels through
    its contents (the `kids` case);
  - if s is an on-cycle step and the demand is **deep**, read chain `(q₀, ⟲)`: the levels below are contents of
    the demanded container. A shallow demand skips this chain: a list storage write never counts against the
    elements it holds (§2.11 *Keep edges*), and an immutable value cannot hold its own container at a level
    below, so `List.push kids x` with a subtree held is accepted, as its non-recursive twin is.

  The cells found are candidates. `alias`, refinement- and constructor-aware, decides each one; the holders of an
  aliasing cell then come from `set_head` and the live parent climb, as for any cell.
- Concrete cells (`site`, `result`, `esc`) need no anchors: their contents are explicit children, found through
  `reach`.

Cost: the first cell of the cell set reads at most two anchor chain heads and one refinement chain head per
prefix, on the lane of the demand's step at that prefix (§2.7 *One query per prefix*); each further cell of a
joined or deep cell set reads its own as growth (a demand × alternative product). Each live cell found costs
O(log C) plus the climb's charged edges. A chain never holds a dead cell, and every cell it holds has a live
holder, so no cell without a holder is visited: O(Σ over the cell set of its anchors + holders found × log C)
per demand. Holders found this way are charged as §2.7 says for holders beyond the direct one. `RoseKidsHeld`,
`RoseAlias`, `MaybeTreeAlias` and `MutualAlias` (Appendix B) check a write under `⟲` while an on-cycle container
or a level above is held, and a deep demand on an on-cycle container while a level below it is held.

**Verdicts** (R-0.3): `accepted` {`fresh`, `call`, `param`, `callback-param`, `once`, `entry`}; `pending detail`
(§2.11); `refused cause` per R-6.3, exact/approximate/position by the pairs it rested on; among failing holders
the one used first, ties to the earlier binding. The result of every writer, construction, append and update **is
its base's object** (R-0.1, R-4.10.1): a `delta` or the base's node, so the next holder is the new version.

**Record lowering boundary (S5).** A write authorization is tied to a settled demand, the receiver's
value version, written fields and phase. A hoist names the old value version, field/constructor path and
placement dominating the read but after its binding. Branch/loop compatibility and pending operands are
part of that proof, not reconstructed by the emitter from source names. `Hoists` publishes an immutable,
versioned channel only for a clean checked module; a refused, pending or exhausted module publishes no
write authorization. Test mutation through a stale field holder after a join, closure capture before the
write, and hoists across constructor projections. `--ownership-records-lost` changes record facts only and
must not leak into list acceptance or a cache built without that mode.

### 2.9 Conditions: exclusive contents

A value interpretation is `(shape root, κ snapshot)`. Its **condition at path q**, κ(v,q), says that the
tracked objects at that path in distinct positions of the enclosing summary place are pairwise apart.
A shallow write at `[*].1` asks only about that path; it does not require exclusivity at sibling `.0`
or at descendants it will not write (R-4.6.4, `o/Beside*Helper`). The kind filter of R-8.6 selects the
written kind. Outside holders are checked separately by Dead. Cross-path sharing remains in the shape
and `sep`/holder checks; a fresh record with two fields containing `x` still contains one `x` twice.

**No shape node owns a mutable fact**, neither a condition nor a use label (`mark` cells, §2.2). Nodes are
interned structurally, so one node stands in several values, rounds and classes; a fact keyed by the node
alone would leak between them. A κ snapshot is therefore immutable and is selected by **each value interpretation**: a value
interpretation is `(shape root, κ snapshot)`. The snapshot travels with its value through bindings, operands,
projections, results and supplies, and is joined only where values join: a branch or fixpoint join, a union, and
a construction, which combines its children's snapshots and joins them where they bind one key. It is never mutated through another value. Values may share the same immutable map root;
that sharing is preserved when the values cross a block boundary (§3.6). So a dead `a = [ r, r ]` stores `shared` for the leaf `{site r}`
in `a`'s snapshot only; a live `b = [ r ]` reads its own snapshot, `yes`, and a write into `b`'s element is
accepted, as v1 accepts it (`DeadDuplicateLive`, Appendix B). A class is per value already: its κ is `res`'s,
with one root reference per supply; use shapes carry marks, not value κ. A frame holds `value → KappaId`, one persistent hash-consed root reference per
value. Updating a binding path-copies the affected trie/map nodes; it does not mutate other references.

**Within a value the key is `(NodeId, path)`**: the node and the path at which the value reaches it, **relative
to the root of the snapshot that stores it** [M 2026-10-26, #1073]. Two positions of one value that reach one
interned node keep separate conditions: in `([ r ], [ r, r ])`, `.0[*]` reads its own `yes`, never `shared` from
`.1[*]`'s store (`OnePairTwoPositions`, Appendix B). A path names its position class (whether it crosses `[*]` or
`⟲`), so the key subsumes that split. The path is the sequence of steps a read takes from that root, not a
canonical `PathId`: canonical folding (§2.1) depends on the prefix above a value, so a child's canonical paths are
not a suffix of its parent's wherever the child's step is on a cycle of the parent's place (`t = Node xs` with
`type T = Node (List T)`: `xs`'s own `⟲` is `t`'s `⟲#Node.0`). A value built level by level therefore has a
position per level, and a snapshot, being finite, has finitely many.

**The snapshot is a trie over steps, so no binding is re-keyed.** A position is a trie node: the conditions it
stores, by node, and its links, by step. A construction does not copy its children's bindings under the parent
path: the new value's snapshot links each child's snapshot under that child's step, one persistent
`(step, child KappaId)` record per written child, and the child's subtree is shared unchanged. Children at one
step — a literal's items under `[*]` — are one position, the merge of their snapshots (a charged union joined
where they bind one key). A store adds one map node at its own path. A read of κ(v, q) walks q's steps through
those links, one step per path step on the read's own prefix lanes (§2.7): **a read crosses a link by re-rooting**,
the linked child's paths being relative to its own root, which is the position it is linked at. Nesting depth
costs the read its path length and nothing at construction: length stays baseline. `Shape.map` carries a
snapshot through an instantiation by relabelling each binding's node, its paths unchanged because they are
relative to the value's root, and the argument's snapshot is linked under the argument's path at the graft
(relabelling and linking are charged).

**`widen`, and only `widen`, folds a snapshot at recursive places** [M 2026-10-26, #1073]. A fixpoint unknown and
a read-off widen their shape (§2.3); their snapshot is folded with it. In a folded snapshot, the position at
which a route through the widened shape first meets a node it has already passed (a knot `widen` tied, at a
recursive place) is a **fold**: every position below it is that position, its links lead back to itself, and its
conditions are keyed by node alone. `propagate`, which builds every snapshot over a joined or widened shape,
folds wherever the shape it walks cycles, joining (`alternatives`) every member position that folds into it; a
shape cycles only where `widen` tied a knot, so every snapshot of that shape carries the widen's fold. **The fold never makes a
read stronger than the read of any unfolded member position it covers:** the stored condition at the fold is the
lattice join of theirs, and a join only weakens (`yes ⊑ and ⊑ lost ⊑ shared`); the derivation at the fold reads
the widened node, whose cells include each folded level's (§2.3, `F(x) ⊑ widen(x)`), and the derivation is
monotone in the cells. So folding can add a refusal and never removes one. Because the widened shape is finite
and a fold has one position for all its levels, a fixpoint over folded snapshots terminates and `kappaLeq` on
them is a finite simulation, as on folded shapes. A construction never folds: a recursive construction chain of
n levels costs O(n) links, where re-keying each child into its parent's canonical paths would cost O(n²).

**The join's premise, and the two kinds of fold** [#1113's review]. A missing entry for a leaf, a recast or a union
adds nothing (stored κ only adds constraints there), but a missing entry for a built node or a delta reads `lost`.
So the join argument above holds only where every built node of a covered position carries its entry there.
`propagate` guarantees this: it writes an entry, `lost` included, for every built node it visits, so its fold is
**exact**. A snapshot **collapsed** into a fold by `kappaFold` cannot see which covered position lacked an entry.
This happens where a fold meets another snapshot in `kappaMerge`, or at a graft's knot. A collapsed fold
therefore reads every built node and delta as `lost`, which is the join of the reads it covers whenever one of
them is `lost`, and never stronger. Its leaves, recasts and unions read stored ⊔ derived as anywhere. Merging two
exact folds stays exact, because each covers its own nodes. **A fold keeps the steps it saw** (its links lead
back to itself), so the frontier below a fold is sparse too: an entry is reached only along steps some route
through the fold took.

**What S2 builds, and what S3a and S3b change.** In S2 a κ root (`Cond.Kappas`, an `Ids.KappaId`) is an immutable,
hash-consed persistent radix map `(NodeId, position class) → CondId`, where the position class is whether the
read's path crossed `[*]` or `⟲`. The holder owns it and threads it: `kappaSet` returns a new root and never
changes the old one, a class carries one root for `res` and a supply carries the root of the value it hands.
It is one map per value, with the coarser key, not yet the trie. The read rule below keeps the coarser key
sound. S3a gives each frame value its own root (`value → KappaId`) and moves the key to the trie above, with
paths relative to the root of the snapshot that stores them and the fold in `widen`; S3b adds the relabelling
through summarised declarations' grafts.

**A read of κ(v, q) is defined by node kind at the selected position.** A built node or delta reads its
construction certificate, or `lost` when none was stored; its storage cells alone do not certify its children.
At a summary position a built node's read is its certificate and `excl` of each storage arrival standing for many
positions, as a leaf's derivation has (the certificate alone where it is `shared`) [M 2026-10-26, #1112]: the
obligation is the position's, so a node reads it wherever it is linked, never because a walk wrote it there.
A leaf joins its stored condition with the condition derived at that position: `apart` over its arrivals,
`excl` for an arrival standing for many positions, `yes` at a plain path, `lost` for `⊤` or an approximate
cell. A recast derives `lost` wherever the reinterpreted place holds objects below it, otherwise `yes`. For leaves/recasts a stored condition can only add constraints; it never weakens the derivation.
Construction certificates must themselves obey the construction rule. A missing entry is thus not uniformly
`yes`: treating it as such changes the meaning of built nodes. Derivation is charged per read; any cache of
a completed read must key the complete immutable interpretation, position and traversal context. A union reads as the join of its sides' reads and of what v stored for the union
itself; at a summary position it also derives the leaf rule over its united cell set (`CallbackFieldPositionsUnion`,
Appendix B). A positional collection derives `apart` over the multiset of its sides' arrivals instead: wherever it
sits, its read is one at a summary position, and each cell held by both sides of a positions node in the DAG counts
once more (below). The key is a precision split only: a constraint stored at one position never tightens another
(`CallbackFieldPositions`, `CallbackFieldPositionsBranch`). Projection returns both the projected shape and the
snapshot. A join returns a new snapshot and changes neither operand. S3b adds a substitution's invocation and
supply roots to the snapshot's key, with `Shape.map`'s correspondence. Split conditions refer to settled
snapshots; a fixpoint weakening creates a new version and reschedules its dependants.

**The observable-position contract.** A stored constraint is observable wherever projection can reach it,
including under leaves/recasts and at empty projections. Propagation, comparison, substitution and encoding
all preserve this same frontier. `κ_a ⊑ κ_b` means inclusion at **every** such position; comparing the roots
alone, or stopping because the left shape is a leaf, is insufficient. A join reads each operand under its
own snapshot and retains every reachable constraint in the new interpretation. Extra stored constraints at
empty shapes still matter to the read rule. A finite worklist over `(node, position class, trie cursor)` per
interpretation closes the frontier; a fold's links lead back to the fold, so recursive values end the walk
(above), and nothing enumerates path strings. A trie transition must migrate all of these readers and the
codec together.
A position is a path, so the frontier's transitions are steps, and **the frontier is sparse**: from a position
it takes the steps the structure names (a node's or a delta's overrides, a union's or a positions node's sides'
named steps, a recast's inner's) and the steps the snapshots read there link (a member's in `propagate`, either
operand's in `kappaLeq`). Every other step of the place reaches a projection whose read is derived from
structure the reader already reads and where no snapshot stores anything, so it is omitted (§3.6's omission
criterion): a type's width costs a read nothing. The other
nodes at a position's path belong to it as follows. A union's and a positions node's sides are read by the read
of the node itself, above. A recast changes the type, not the path, so a recast and its inner are **one
position**: the read at the recast joins what is stored at either with the recast's derivation, and the inner's
projections are the position's transitions too, read for what a snapshot stores there (an unstored inner adds
nothing to the recast's derived read; §2.13.9's restoration reads the same entries). A delta's base is not a
position: a built node's read is the walk's certificate, so a constraint stored for the base alone is observable
nowhere. `Cond.frontier` is that one transition function; `propagate`, `kappaLeq` and `deep` walk it and nothing
else.
Visited states use exact interned member-and-snapshot runs, never equality of a hash. A hash may index an
exact equality check. Store run offsets/ids, not slices that an append can invalidate. Different contexts
at the same node remain separate states; revisiting a completed identical state reuses its answer.
This is a required repair to S2's propagation/comparison before S3b relies on it (#1063, #1064).

**Unions and positional collections.** A `union` node means **alternatives** (§2.3): a control-flow or fixpoint
join, where one run takes one side, so a cell repeated across sides is one position. A `positions` node is a
**positional collection**, built by `Shape.collect`: the elements under one built value's `[*]` (a literal's
elements, the combined positions of a spread), where every side is present at once, so a cell repeated across sides is two positions and
`apart` runs over the multiset of the sides' arrivals. `f a b = [ { a = a }, { a = b } ]` called as `f x x`
reaches `[*].a` through `positions(leaf{π₁}, leaf{π₂})`, and instantiation makes both sides `x`: the multiset
`{x, x}` is `shared`, so an element write is refused `exclusive` (`PositionsRepeatArg`, Appendix B). But
`if c then [ x ] else [ x ]` joins two one-position literals into `union`, and κ at `[*]` stays `yes`: a write
into the element is accepted (`BranchSameElement`). `proj`, `Shape.map` and `propagate` preserve the kind, and
`widen` keeps a positions member as it is (§2.3); nothing turns a `positions` node into a `union`. `leq` is
kind-blind, so the multiplicity a positions node carries is compared through κ only (`Cond.kappaLeq`).

A **single-arrival leaf** may default to `yes` at its own ordinary occurrence. A projected symbolic
summary arrival requires `excl` at the selected path. This is what makes `List.map xs λl → …` record
`xreq excl xs[*]`: the elements of a parameter list are one arrival projected under `[*]`, and their exclusivity
is the caller's to discharge. A multi-arrival leaf must derive its condition from its arrivals there. A union's
condition is derived from its members, never defaulted to `yes`. Empty/crossing
children make no object obligations. Thus a fresh list of plain integers has a fresh storage cell and κ
`yes`; crossing elements do not make the list `lost`. Freshness of outer storage says nothing about shared
nested cells.

| κ | Meaning |
|---|---|
| `yes` | holds |
| `and(κ₁, κ₂)` / an atom | an interned binary conjunction (O(1) to form; a chain of W stores creates O(W) outer nodes); semantic conjunctions are deduplicated atom sets in fixpoints; flattening, including overlap visits, is charged by §4.1 |
| `shared` | fails exactly: one cell at two positions or two paths (`[ r, r ]`, `{ a = xs, b = xs }`, a taken element stored back) |
| `lost` | fails approximately: `⊤`, a conservative call, a spread of a variable after the base (R-4.6.1), a recast at an incompatible tracked path, a pessimistic class |

Atoms name **arrivals only** (parameters, captures, callback results, the cells under a summary position of one):
`excl c`, `sep c d` (also between two `cb j` labels, discharged by instantiation), `apart{c₁…cₙ}` (every `sep` over a set, stated
once), `keep cb_j` (the callback puts back what it was handed, at the same path, or a fresh value: "keeps shape"),
`writes cb_j`.

`sep(a, b)`: two concrete cells, distinct → `yes`; an unfolded cell twice → `shared`, a folded one (`⋆`, `⟲`) twice
→ `lost` — unless the pair arose from a fold of two different labels, which is the self-atom `within(ι⋆)` (§2.10)
(§2.2's one rule); two *different* `cb j` labels → the atom `sep(cb j@λ₁, cb j@λ₂)`, discharged by
instantiation (§2.2); `⊤`/approximate → `lost`; two other arrivals not aliasing → the atom `sep a b`.
Here folded includes a symbolic path containing `[*]` or `⟲`, as well as a folded invocation. A literal
forms one ordered arrival group; a sequence of stores persistently inserts only its new arrivals. Never
re-sort or re-enumerate the accumulated group at every store. An exact unfolded duplicate at distinct positions decides
`shared`; a folded/summary duplicate gives `lost` under the `sep` rule above; the arrivals among them form one `apart` group;
discharging an instantiated `apart` is O(n log n) only when identity/ordered-prefix tests settle it in one
sort. General supplies, overlapping paths or split conditions require additional comparisons, individually
charged by §4.1. Unresolved arrivals form one `apart` of the caller's own (#693, `ListOfParams`), not an
eager quadratic array of `sep` atoms.

Where κ is set, always **at the selected path p**:

- A literal `[v₁…vₙ]` joins the conditions of `vᵢ` at p and forms one `apart{cellsAt(vᵢ,p)}` group.
  The group compares **positions**, not only one path: each position's cells at p are tested against every
  other position's whole `reach`. In `[ (a, b), (b, a) ]` the cells at `.0`, `a` and `b`, are distinct, but `b`
  at `[1].0` is also `[0].1`, so κ at `[*].0` is `shared`. A comparison at p alone hides this sibling-component
  alias. Holders are the other half: a live holder of `[0].1` is found by §2.8 (S3a).
  A record/tuple/constructor supplies the conditions of its children at their respective paths; explicit
  comparisons between two paths use their cells. A repeated child never becomes fresh through its parent.
  **A literal of one element, and a join of one alternative, is a link** [M 2026-10-26, #1112]: the position is
  the member's own snapshot position, linked as it is, and nothing below it is walked or written. This reads
  exactly the member, because there is nothing for `propagate` to add. (1) `apart` compares positions, and one
  element is one position. Two objects of one element at two paths are the shape's and the `sep`/holder
  checks' (above), never κ's. (2) A leaf's summary derivation and a built node's summary `excl` (the read
  rule above) are the reader's, at the reader's position class. So the summary obligations `propagate`
  would have written at `[*]` and below are read wherever the member is linked. (3) A join of one
  alternative is that alternative (`join` is idempotent). An alternative that is an empty leaf with nothing
  stored reads `yes` at every position below, and `yes` is the join's unit, so it does not count. A join
  therefore walks only where at least two alternatives differ. A tower of one-element literals, or of joins
  with an empty alternative, walks each level once (N levels, O(N log N) work, the sets' depth).
- A construction lowers the base's condition at `[*].p` by the stored value's condition at p and
  `apart{cellsAt(stored,p), cellsAt(base,[*].p)}`, compared by position as for a literal. A later spread of a variable loses the relevant condition.
- A call instantiates κ(res): `excl πᵢ·q` asks the argument's condition **at q**; `sep` and `within`
  interpret cells under their label-specific supplies (§2.11); `keep`/`writes` use the actual class's facts.
- A `delta` retains unaffected bindings and lowers the written paths by the new values. Storage
  permutations preserve conditions; a `recast` or unknown loses facts at paths whose interpretation is
  unknown. `concatenated` has its declared row; the two literal-empty `++` cases copy (§2.13.2).
- A split keeps the container's projected conditions on the remainder and records them on the split.
  `List.copy`/`Dict.copy` separate storage and preserve value conditions (R-4.10.9).

There are no deep `sep`/`apart` atoms. A genuinely deep demand enumerates its tracked paths and conjoins
those paths' obligations through `Cond.deep` (S2): a walk of the value's explicit structure that meets a
projected summary arrival as `excl` at that arrival's path. S3a's deep demands (send, `consumed`, focus) conjoin
`deep` over their cell set. A deep demand does not strengthen every shallow atom into a deep one. All enumeration, union and substitution work uses §4.1. A chain of W single-arrival stores makes O(W)
outer condition nodes plus O(W log C) persistent group insertion work, not a quadratic sequence of sorts.

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
| `κ` | immutable interpretation of `res` at each selected path, atoms over arrivals (a parameter's own `excl` implicit); supply/use values retain their corresponding snapshots |
| `xreq` | the atoms the body relied on |
| `fun(j)` | `calls ∈ {0, ≤1, many}`; `supply(λ, k)`: per callback label λ and argument index k, the node handed as πⱼ's `k`th argument at λ, with `owned`, `taken` and κ; `need`; `seen`; `keeps`: the keep edges of §2.11 |
| `classes` | **a summary-local class table**: every `closure` node in `res`, `supply` or `use` (a lambda returned, a lambda handed on, a closure in a record) carries a `ClassId` into it, normalised by Block for publication (R-5.4.8, R-5.4.9, R-5.5.9); the fixpoint joins classes pointwise |
| `slots` | function-typed parameter ports, including a list of callbacks, keyed by parameter and path; separate from mutable cell slots |
| `effects` | selected callback-result write-backs (§2.13.6) and the ordered versioned cell-slot transformations (§2.13.7), preserved by substitution, joins and blocks |
| `refs` | stable `(handle origin, ◆)` slot identities the body may operate on, independent of currently stored value; top for unknown calls (directly or through a callee), for §2.13.7's re-entry rule |
| `writes` | one bit: the body or a callee has `W`/`S` on a parameter path, a capture, a `shared` cell or lets one escape — a write of something that *arrived*; a `Builder`'s fresh stores do not set it (R-5.13.1) |
| `once` | per function-typed result place; exhaustion is a terminal error, never a published class |

**Functional operations.** `Summary.join(a,b)` builds a new class, including new κ roots, without
mutating a or b. `leq` is a simulation over pairs of shape nodes **and their κ interpretations**, including
carried class pairs; a left node reached against two right nodes requires two checks. Local ids or a DFS
serialisation are not semantic equality. Supplies are keyed by `(callback label, argument index)`; S4 adds the
receiving port of a carried class (item 1 below) to the key. Join only equal keys. A program point or the smallest of two points is never a substitute for a label.

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
   `fun` gains `S.fun(j)` translated; none → `⊤`): the **supply edge** (for each label L of πⱼ, the actual writes its `k`th
   parameter where `S.supply(L, k)` is borrowed → `supply`; owned with provenance `πᵢ·q″` → a `callsite` demand on `aᵢ` at `q″`; `cb j′`
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
   for two occurrences of the **same** invocation. A feedback supply's `callsite` demand runs on the caller's
   *argument* (item 4), so its Disjoint sees the initial value, not the settled feedback node. A duplication
   that only the feedback creates (an arm returning `.0` and also storing it at `.1[*]`) is refused instead by
   §2.12's preservation certificate (*Recursive proofs*), which S4 implements (Appendix C.6).

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

**Instantiation boundary (S3b).** Instantiate a **value interpretation**, never a shape followed by
an unrelated κ copy. The correspondence hook maps source semantic positions to destination positions
under one immutable substitution/supply context, including projected leaves, empty nodes and knot
backreferences. It is not merely a NodeId→NodeId map. For each source read, substitute its atoms and retain
that obligation at the mapped position; derive the destination read there too. Grafted arguments keep their
original origins, captures, loan regions and snapshot subtree. Two template uses under different supplies
cannot share an interpretation memo; repeated uses under the same immutable inputs can. An identity map
preserves every observable read. Callback-result labels are freshened only by invocation; captured cells
are never freshened. Map cyclic nodes with a transaction-local explicit worklist, tie once and publish the
correspondence only after success; nested substitutions cannot reset an outer call's memo.

`Groups` owns the resolver and versioned dependencies; `Calls` consumes its passed-down interface, never
starts an uncontrolled recursive `ensureClass`. A changed result, κ, write-back, keep or `refs` fact wakes
its exact consumers. Use exact context keys and compare the full summary, not local normal-form words.
Before a group is accepted, joins must be upper bounds at every observable position (#1063), and validation
must check all equations and pending obligations against the same settled generation (§2.12).

**Calling a function parameter** πⱼ in the body (the rule v1 lacked where #982, #1000, #1001 lived): the result is
the leaf `{cb j@ι·ε}` (ι the call instruction, §2.2); each argument's value `Nₖ` is recorded as a supply `(j, ι, k, Nₖ, κₖ, p)`, its cells used at `ε`. The retained supply key includes the call's label and argument index;
point p locates diagnostics only, and does not identify calls across wrappers.
**Keep edges**: after the walk, for every label-keyed supply `(j, λ, k, N, κ, p)` and every later compatible demand in the frame with
`W` (own or `callsite`) whose base cells alias a cell in `N` — the written cell equal to or a trie descendant of a
cell in `reach(N)` (the keeper may hold the parent or the part), or a trie *ancestor* of one only when the next
step of the kept path is a written field (`b = f o.inner; { o | y = 3 }` writes `o` at `y`, off the kept path
`.inner`, and records no edge: a keeper of one field with a write of another is accepted, R-4.8.13, R-5.2.4); a
list storage write never counts against the elements it holds — record `keep(j, k, path of the cell in N, written
path)`; `supply(λ, k).owned` is decided by Dead at
`p` as for any demand. At the caller: an actual whose class may hold its `k`th parameter at a path aliasing the
kept path in its result (`res` names `π_k·q` with `q` overlapping, or `cb`, or `⊤`) is refused `supply (a)` at the
function value supplied (R-4.8.11, `p/RecordKeptInLiteral`: `f [ r ]` supplies a fresh list whose `[*]` holds `r`,
so the kept path `[*]` and the written `r` alias through `reach`; `p/RecordInnerKept`: the write through
`i = o.inner` is a demand whose cell is `param o·.inner`, a trie descendant of the supplied `param o·ε`); a known
non-writer discharges a keep whose only possible writer is another function parameter (R-5.2.4); a record written
*before* it is handed and returned beside the kept answer records no edge (`p/RecordWriteBeforeKeep`, R-4.8.11).

**Carried-class boundary (S4).** Class table identity is `(code, canonical port, preserved ordinary
context)`; a table index or matching array length is not identity. Join alternatives by that key, including
ones appearing in only one branch, then solve recursive class pairs by a worklist with backreferences.
`Summary.join`'s current equal-length positional nested arrays are S2 scaffolding, not an implementation
of this rule. Read-off produces `within` only from a recorded pair of distinct pre-fold labels; neither
`Cond.sep(c,c)` nor an imported self atom can invent that provenance. Serialize the pair's folded proof
obligation and traversal certificate together. Whole-graph coinductive equality is never evidence of
freshness. All pending proof requests carry immutable input generations; failure cannot leave a proved
answer in a shared memo.

**Once use is affine by closure identity (R-5.4.2).** The closure allocation/result occurrence, not its local
name, owns a consumption token. Copying/aliasing/projecting it preserves that token. A direct call consumes it;
forwarding to a seen callee whose `calls≤1` consumes it once for that use; mutually exclusive arms join usage
by maximum, sequential compatible uses add (0,1,many). A second compatible call, a many/unknown callback use,
or self-recursive use refuses `once`. Creating fresh closures at different ordinary invocations gives different
tokens, but a closure stored twice does not. Out-of-sight use is pending; no unknown callee can discharge once.
Creation's captured-write demand and other-holder checks still apply. Tokens/use edges are inferred facts in
the same account and are settled before judging calls.

**Function values** (R-5.5): read off a node's `closure` cells: a lambda's class, a summary, a constructor's class
(§2.13.1), an alias chain of any length (the pre-pass, §2.12), a class from a summary's table (a returned or
carried lambda), several (joined, R-5.5.5), a `Send` (§2.13.5), none → `⊤call` (R-5.5.4), whose `refs` is top (may touch every cell slot), never empty. `f a _` is a lambda
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
| a recursive group of declarations (R-5.6.1) or a block's local functions (oc §18.7) | each member's class | **worklist over frames, cells by propagation**: a walk of a member records, beside its shape, the inclusion edges a recursive call makes (argument node → callee parameter path, callee result path → call result); the cells then flow along the whole group's edges by the sparse propagation below, so growing cell sets never cause a re-walk. The `R`/`A`/`E`/`W` bits (with `F` and `S`) flow along the same edges in the other direction (a callee's `W` at `π_k·q` becomes `W` on the argument node's cells at `q`, hence on the caller's parameter path they came from), and so do the `callsite` demands they imply, so `rot a₁ … aN n = … rot a₂ … aN a₁ (n − 1)` records N edges once and its `W` reaches every parameter by propagation, not by N re-walks. After propagation the frame's resolution sweep (§2.8) runs once over all demands, the propagated `callsite` ones included, and reads off `supply.owned` and the keep edges, which depend on it. Build transfer equations once. A callee shape change schedules only dependent transfers through the charged dependency graph, not a replay of unrelated body instructions. Affected facts include: `calls`, `need`, `seen`, a `supply.owned` bit or a keep edge (monotone: owned → borrowed, edges only added, bounded by the callee's own supplies), κ's atoms, a class's structure, a `res` node's shape (cells arriving at an existing node are not a shape change) | `xᵢ₊₁ = widen(xᵢ ⊔ F(xᵢ))` per member; cells and bits by propagation; owned/keeps by the sweep |
| a callback fed its own result (R-5.3.2, `Dict.merge`'s cycle R-5.3.6) and the entry's model (§2.13.4) | the `cb`/`M` node and its κ | **sparse propagation over per-path inclusion edges** (Morphic I:114-171): the step's `res` is read once as edges `source path ⊆ target path` (a `delta` over π₂ gives one edge per override; `π₂.f_{k-1} ⊆ π₂.f_k` for the rotate family); the edges' graph is condensed into SCCs and the cells are pushed along it in topological order with persistent sets, so each cell crosses each edge once and a set that grows by one shares the rest | push the difference, never re-instantiate the whole |

**Termination.** At a fixed inventory, each may-membership (including cell-slot contents), ordered slot-effect alternative, edge, code alternative and use bit is added at
most once; each guarantee only weakens in its finite order. Conditions use a finite set of atoms over those
inventory ids: `and(A,A)=A`, no new syntax nesting each round, and `apart` groups are canonical persistent sets.
Finite slots and ids imply a finite possible atom inventory (not a linear one). Dependency SCCs use §2.10's
backreferences. Facts are processed by deduplicated `(edge, fact)` deliveries or immutable-root union tasks;
a newly discovered edge receives existing facts once. No update is lost because a task saw an earlier root.
Thus a fixed inventory has finite monotone height and a fair worklist terminates. If inventory or operation
records continue growing, reserving growth record R_f+1 stops **before** its work (§4.4). This proves that every input
finishes or reports the named limit, including polymorphic recursion through carried classes, without a round cap.

**Recursive proofs.** May-facts begin empty only for inference, never for acceptance. A recursion in a Boolean
proof request has status `waiting`, not `proved`. After may-facts settle, build a finite obligation graph.
A recursive invariant is established only by an independently checked base and a preservation check with its
explicit invariant assumption (for example owned initial accumulator plus `keep`, or fresh allocation on every
returning alternative). Merely traversing a cycle discharges nothing. Every outgoing capture/feedback/unknown
alternative must satisfy the obligation. One final source validation walk per original body has its own bounded lane (§4.1); validation traversing inferred records retains pre-reserved growth continuations. The validation walk checks the certificate and `F(x) ⊑ x`; a residual
unjustified cycle fails the demand approximately, not by accepting the initial empty facts. This proof graph and
validation work are part of the same account; coinductive shape equality is not a separation certificate.



Every component is joined round to round, κ included: a `sep` between two `cb j` labels is an atom inside every
class, discharged only by instantiation where the actual's class is in hand (§2.2), so nothing a round reads off
depends on an assumed `calls` and κ is monotone. `mapHelp`
re-derived: `put b i (func (traverseAt a (o + i)))` stores `cb₅@ι` (this activation's one call) into `b` whose
`[*]` holds `π₆[*]`; round 1 reads off κ(res[*]) = `apart{cb₅@ι, π₆[*]}` = `sep(cb₅@ι, π₆[*])` (an atom over two
arrivals) and `res[*] = {cb₅@ι, π₆[*]}`, published under `[*]` as `cb₅@ι⋆` with its supply `elem(π₁·ι_t)`; round 2's
recursive call at ι_rec instantiates the callee's `cb₅@ι⋆` as `cb₅@(ι_rec·ι⋆)` with supply `elem(a·(ι_rec·ι_t))`
(strictly a refinement of `others(π₁·ι_t)`, which the pending `a` holds while ι_t is in force; both reduce to
κ(π₁[*])),
so the store compares this activation's `cb₅@ι` (supply `elem(a·ι_t)`) with the deeper activations' label — two
different labels, never the same call — giving `sep(ι⋆, ι_rec⋆) ∧ sep(ι⋆, π₆[*]) ∧ sep(ι_rec⋆, π₆[*])`.
Round 3 instantiates the callee's `sep(ι⋆, ι_rec⋆)` at ι_rec as `sep((ι_rec·ι⋆), (ι_rec·ι_rec⋆))`, whose two sides
fold into one `ι_rec⋆`: the fold emits `within(ι_rec⋆)`, so κ(res[*]) = `sep(ι⋆, ι_rec⋆) ∧ within(ι_rec⋆) ∧
sep(ι⋆, π₆[*]) ∧ sep(ι_rec⋆, π₆[*])`, plus `excl π₆ ∧ excl(ι⋆) ∧ excl(ι_rec⋆)` (the stored values' conditions at those paths, which §2.9's construction rule adds through `put`'s `stored`), stable (round 4 re-folds to the same atoms). `List.map xs f` is one call of
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

**The BIR pre-pass** (`Prepass.zig`, L3, reads the BIR, the dispatch table and the graph): SCC edges come
from `check/Edges.declEdges`, including ordinary refs, every resolved dispatch/evidence call site and
derived bodies; no locally reconstructed two-tag approximation; alias chains of function values (R-5.5.6); read counts of private parameterless values (R-4.9.3);
the enclosing frame of each lambda (for the dynamic summary-dependency edges of §2.10);
the spread chains `Lower` recorded (§2.13.2). `Groups` supplies semantic targets for a type's `eq`/`compare`
and `withDefault (map m f) d` recognition (§2.13.12). Resolve those through the lowerer's well-known symbols
at the adapter boundary; Prepass itself neither compares declaration-name strings nor owns class resolution.

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
   a spread literal inside another's last spread its own write. `[ …xs ]` is `xs` and records no spread fact (including nested single spreads);
   every recorded root is a distinct call made by that literal. A literal is a fresh `site`
   (R-4.10.5); `++` chains per R-2.2. The emitted prepend writes no existing array (R-4.4.4): the lowering's
   obligation, asserted under runtime safety.
3. **Patterns and views** (R-2.14, R-4.5): `[ x, …rest ]` on `n`: `x ↦ elem(c·ι)` per container cell
   `c ∈ cellsAt(n, ε)` (§2.2: the position of `c`'s `[*]` taken at ι),
   `rest ↦` a node with `n`'s `ε` cells (a view shares the storage) and `[*] ↦ others(c·ι)`; the split records
   the container's interpretation at ι: its κ snapshot projected through `[*]`, κ(n, `[*]`·q) at each path q (§2.9). A constructor pattern on a recursive place materialises `level(c·ι)` for the matched node's
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
   (R-5.9.6). The alias form remains a temporary v2 input protocol below; the final API is nominal because `Unify.expand` (`Unify.zig:843–870`) expands a
   non-generalised alias that meets its expansion, so a `Send` passed through a helper annotated `msg → ⊤` would lose
   its class if ownership facts followed only erased types; v2 instead keeps value provenance during migration. At S10 the API changes (`Hosted.job`, `tap`, …, `Cmd.perform`,
   `Sub.on`, `Sub.map` need no row of their own, R-5.9.9).
   **Migration with v1 frozen (S2b/S7→S10).** v2 reads both the existing callable alias and the final nominal
   form; `src/own/` is never edited. Until switch-over, existing platforms/corpus keep `Send msg = msg → ⊤`
   and `send message`, so the whole-corpus v1 diff baseline is unchanged. A v2-only contextual type word
   marks the protocol source: `pub sender type alias Send msg = msg → ⊤` in core/platform packages. It is
   validated as a one-argument function alias returning ⊤. The frontend preserves `sender` type metadata and original alias-use terms before expansion
   (not a new tag in v1's row enum); S7 resolves the protocol role from those terms;
   type equivalence and emitted runtime code stay unchanged. S2b's compatibility test requires the old v1
   inputs/outputs byte-identical, with no adapter in `src/own/`.

   The S7 adapter reads unexpanded BIR alias references and interface alias terms before type erasure
   (#1056), then publishes a v2 callable-port role on its protocol row. If a frontend path cannot retain
   that provenance, add the role column there; never recover it from `msg → ⊤` or a type name. Cold/warm and
   cross-package tests must include wrappers annotated with the expanded function type.

   Entry/platform protocol rows use those marked ports to supply a known callable class with `S` on its sole
   argument, crossing result and no retained payload. The authority is the pinned runtime dispatch protocol,
   not the alias name or merely the expanded function type. The class travels as ordinary value provenance
   through wrappers, captures and erased aliases, including a helper annotated `msg → ⊤`; an unmarked function
   of that same type is not a send. If provenance is actually lost, apply the ordinary unknown/pending rule,
   never guess a send class from type shape. `sender` on a name supplies no class by itself at an arbitrary
   expression: only a protocol-produced value or an already tracked class has that capability. Foreign
   protocol producers and their checked interface ports are pinned under R-5.10.7.

   S7 tests both forms on paired v2-only fixtures while the existing full corpus and platform API stay in the
   alias form. S9's v1/v2 diff uses that unchanged corpus. S10 then migrates platform declarations, callers,
   documentation and skills to nominal Send/Send.to and runs the migrated corpus under v2, comparing it to
   the recorded pre-migration semantic results before deleting v1. No v1 golden is reblessed to accommodate
   nominal Send. R-5.9.9 and the rule above describe the final API; this temporary alias provenance is an
   implementation bridge inside v2, removed with the switch-over.
6. **Foreign words and rows as data** (R-5.10): `Rows.fromWords` builds a class from oc §24.2's words, defaults
   pessimistic (R-5.10.3). **The words and selectors below** express every row R-5.10.8 asserts beside its type
   and `Rows.zig` names no declaration: parameter `written` (`W` at `ε` only: a storage write, R-4.10.9);
   parameter `stored` (a value retained at the result's `[*]`, or a callback whose selected result is
   stored as specified below; both take part in §2.9's construction rule); `taken`, on a function parameter (the supply is a materialised element of the first container
   argument: `List.focus`, `Dict.focus`, `Dict.update`) **and on a result** (`foreign pure traverseAt : List a, Int →
   taken a`: the result is a materialised element of parameter 1, in force for the rest of the frame); result
   `lent` (a loan of parameter 1's `◆`: `Ref.get`). A `taken` element is owned iff the container is exclusive, owned, and
   has no holder of the *element* outside the call — a holder of the container holds `others`, not the taken
   element, while the split is in force (§2.2), so `mapHelp`'s pending `a` does not borrow it; and an owned item
   does not make an accumulator outliving the call owned (R-5.3.4).
   **The index obligation and pins [O 2026-10-26].** A body that reads a `taken` result reads that
   container only through the certified traversal, once per index in one direction. Pin the primitive,
   every body reading its result, and every forwarder of that result, across modules and packages. Find
   forwarders as a least fixpoint over result flow through calls, aliases, lets, lambdas/partial applications
   and case arms, including resolved dispatch. A caller of a completed fold does not owe a pin merely
   because the fold reads taken elements. The gate keys pins by package plus declaration, not `Module.name`.
   Pin the implementation that executes: codegen-inlined primitives include the `Operator` dispatch and
   `js/Lower` lowering regions, not only their unused sibling exports. Every row retains its pinning fixture
   and unsafe-direction flip report (R-5.10.7). Helpers on which an asserted body relies are followed across
   module/package boundaries to a separately justified pinned contract; an unworded beni helper is not a
   trust boundary. Foreign siblings and P-sync remain explicit trusted leaves. This closes Task/Deferred's
   helper gap (#1061) in S8 without editing v1. Derived eq/compare compose component classes (§2.13.13).
   Wordless `foreign` is pessimistic (R-5.10.1). Words erase only from runtime representation; checked metadata
   survives interfaces. `misplaced_ownership_word` validates the placement/companions below; the S3a signature
   adapter additionally rejects a resolved type that lacks the required kind, rather than silently treating
   an invalid asserted word as absent (#1056).
   **A word on a bare type variable applies at every depth** [M 2026-10-26, #1105]. A parameter whose
   declared type is a type variable (`borrowed a`, `returned a`, `stored a`, or an alias that expands to one,
   `type alias Id a = a`, expanded before deciding; not `List a`) can hold any
   structure at the call, and the callee — a `foreign`, `Js`, or evidence — may read anything inside it. So
   every word there is its deep form: `borrowed a` is `R` at `ε` and at every path below (a leaf of marks,
   §2.10), and so `A`, `E` and `W` for the words that give them. `Rows.fromWords` reads this from the
   callee's annotation (`Rows.Param.type_variable`), never from the call site's instantiated places, where
   `ε` would end at the instantiated type's root. A word on `List a` keeps its own depth (`List.length`
   reads only `ε`, R-4.3.5). Fixture: `ownership/core/HeldIntoTypeVariable.beni`.
   `Js.maySuspend f` gives `f` `unused`; Log's work is `once`; `Task.keepLogContext` is `returned`. Their
   v2 wording and Dict's rows land at S8 (#1053), with v1's input columns and verdicts unchanged.
   **Type metadata, published as data (S2b).** These are contextual ownership words, permitted only in core/
   platform declarations, parsed/lowered with `misplaced_ownership_word`, erased from runtime types but retained
   in typed interfaces, checked core and ownership blocks. `Rows`/`Place` switch on enum metadata, never a
   module/type/constructor spelling. User code cannot assert them. The exact forms are:

   ```text
   pub equatable sequence foreign type List a
   sequence foreign type Builder a
   pub opaque cell type Ref a = Ref Js.Value
   pub opaque cell type Deferred a = Deferred Js.Value
   pub type Result e a = Ok a | failure Err e
   ```

   `sequence` precedes `foreign type`, after `pub`/`equatable` if present, on a unary type only: storage kind
   list, one `[*]` child of its formal parameter, even when its runtime representation is opaque. `cell`
   precedes `type` after `pub opaque` (or precedes `foreign type`) on a unary type only: a stable handle cell,
   one barrier `◆` child typed by its formal parameter, independent of representation fields. An unworded
   opaque/foreign type does **not** acquire either contract. `failure` precedes one unary constructor of a
   two-constructor type; the other constructor is unary success. The type checker publishes the instantiated
   success/failure payload paths for `try`; ownership reads those resolved paths instead of looking up `Result`
   or `Err`. Incorrect arity, duplicate/conflicting words or placement outside core/platform is an error.
   A renamed test type/constructor with these words must behave identically. Every such type/constructor's
   representation and associated operations enter R-5.10.7's pinning/mutation gate.

   **Value words selecting those slots (S2b).** In addition to `written`, `stored`, `taken`, `lent`, add the
   following contextual parameter/result words. Numeric roles below are fixed by the word and verified against
   the signature; they are not special knowledge of the declaration's name. Unmentioned parameters still
   require explicit existing words (otherwise pessimistic). The spellings below are the source words.

   | Word / placement | Exact row semantics; declarations carrying it |
   |---|---|
   | result `elementof` | Parameter 1 is a sequence with element type equal to the result; result `π₁[*]`, π₁ `R` at ε and `A` at `[*]`. No split, no `taken`, no ownership transfer. `at`/`unsafeGet`: `borrowed List a, borrowed Int → elementof a`. The root `borrowed` does not suppress the word's element `A`. Additional parameters have explicit words. |
   | result `copyof` | Parameter 1 and result are sequences with the same element type. Result storage fresh, `[*] = π₁[*]`; π₁ `R`, `[*]` `A`. List-kind descendant κ is `lost`; record-kind descendant κ is the corresponding `excl π₁` path, not unconditional `yes`; crossing paths are `yes`. Copying storage removes only that root's loan tag. `copy`, `sliceOf`, pinned `sortWith` (its comparator additionally `many`, borrowed supplies). Companion π₁ `borrowed`; reject `fresh`, `exclusive`, `returned` or another result selector beside it. |
   | result `prepended` | Exactly two parameters: `stored a, returned List a → prepended List a`. Result storage is π₂'s storage (re-cons: a view over, or a header sharing, π₂'s base) or fresh (copy), π₂ `RA`, π₁ `RA`; contents are the positional collection of π₁ and π₂[*], not a branch union. At each path κ is `excl π₁ ∧ excl π₂[*] ∧ sep(π₁,π₂[*])`, with the construction's cross-path comparisons. No existing storage write is demanded: prepend allocates or reconstructs a view. Surface prepend's fresh-front refinement is §2.13.2, never a name test for `cons`. |
   | callback parameter `stored` | Store its **result**, not the closure. Without a cell selector, the answer is put back at the element position `[*]` of the written container, whatever its kind: a `sequence`'s `[*]` or a `dict`'s value position `[*]` (keys cross). **Row:** the callback is invoked at most once with the taken element; its stored answer replaces that element at the destination's `[*]`, the result's `[*]` is the join of the stored answer and the remainder, and κ there is derived as §2.9's construction rule derives it with the remainder (the taken position removed first). The answer is either the element type `a`, and then the whole answer is stored, or a resolved Maybe-like two-constructor carrier (one nullary, one unary whose payload is `a`, validated by shape as for `lentoptional`, no name test). For the carrier, the unary payload path (`Just`'s payload) is the selected result path that is stored, and the nullary alternative (`Nothing`) is a removal: it stores nothing, the taken position is gone, and the result's `[*]` is the remainder only; the result row joins the two alternatives. **Placement:** on the callback parameter. **Companions:** the callback is `once taken`; parameter 1 is the sole `written returned` destination, a `sequence` or a `dict` whose element type is `a`; the callback's argument is `a` or the same carrier over `a` (the taken element at its payload path; the nullary argument alternative takes nothing); the answer type must match the argument form. `List.focus` carries `once taken stored` with `a → a`; `Dict.focus` carries it with `Maybe v → Maybe v` over a `dict` destination, worded in S8 (#1021, #1053). With `cellupdate`, store result ε at π₁◆; with `cellmodify`, store only result .1 at π₁◆ and return .0 under the loan/disjointness rule below. These selectors require `stored sync` and imply once/taken/owned; reject duplicate/conflicting invocation or destination words. |
   | result `cellnew` | Result is a fresh `cell` handle, ◆ initially parameter 1; require parameter 1 `consumed`. `Ref.make : consumed a → cellnew Ref a`. Inspect the payload for loans **before** installing the barrier. |
   | result `cellempty` | Fresh `cell` handle with initially empty ◆, no payload; unit argument `unused`. `Deferred.make`. Empty is an initial state, not the result of later reads. |
   | parameter `cellread` + result `lent` | First parameter must be `cell`; record its stable slot in `refs`, no write, return a loan of the current ◆ at the resolved result payload path. `Ref.get`, `Deferred.wait`; the latter may suspend and the loan is born at return. |
   | parameter `cellread` + result `lentoptional` | Same, but result is a resolved Maybe-like two-constructor carrier (one nullary, one unary matching contents); empty alternative or loan at its unary payload path. `Deferred.poll`. No name test; validate the shape and publish the path. |
   | parameter `cellread` + crossing result | Read only, no loan in the result; `Deferred.isDone`. |
   | parameter 1 `cellwrite`, parameter 2 `consumed cellstored` | Update parameter 1's ◆ with parameter 2; shallow write of handle is **not** this operation. `Ref.set`. The payload has a deep Known/no-loan demand before the barrier store, then ownership/holder checks. |
   | parameter 1 `cellwrite`, parameter 2 `cellupdate stored sync` | Second parameter is a→a, invoked once with taken owned contents under κ; while focused it must have no possibly-aliasing `refs`. Its `stored` effect puts the whole callback result back into the same slot, with a deep no-loan/consumed demand on that result. `Ref.update`. `cellupdate` implies once/taken/owned, cannot duplicate those words. |
   | parameter 1 `cellwrite`, parameter 2 `cellmodify stored sync` | Callback a→(b×a) is once/taken/owned; `stored` puts .1 back with the deep no-loan/consumed demand **only on .1**, and .0 is returned. Compare .0's reachable cells with the stored .1 and remaining slot contents: any overlapping or unknown component returns as a **loan of that slot**; only proved disjoint transferred/fresh components return ordinary origins. `Ref.modify`. Thus `(xs,xs)` cannot export unloaned contents. |
   | parameter 1 `cellcomplete`, parameter 2 `consumed cellstored` | Single-assignment cell: join already-completed/no-store and empty/store alternatives; first accepted payload stays the slot's contents. Bool result crosses. `Deferred.complete`; callbacks/resumptions get loans, not ownership of independent copies. |
   | result `builderdone` | Unary sequence storage in parameter 1 is returned as the result sequence with **the same cells, children and κ**; changes only nominal wrapper and logical length. `List.done`; not fresh exclusive. Parameter 1 is `written returned` (setting the logical length is a storage write at `ε`), length parameter crossing/borrowed. |
   | result `concatenated` | Two sequence parameters, result storage may be parameter 1 or fresh; contents are the union of both `[*]` shapes. List-kind descendant κ is lost, record-kind κ preserved only if both inputs are exclusive and mutually apart. `List.append`; no `List.append` name test. Both inputs get their read/use rows, with the existing write demand on the first storage argument at EVERY call, direct or through an alias/wrapper/method (R-2.2/R-2.7); the `written` companion is mandatory. Spread/`++` fusion lowers that same demand once per surface construction. |

   **Write-back is a summary effect, not a Boolean `need`.** Retain a flat effect record
   `(callback label/port, selected result path, destination parameter/path, mode)` with mode `element`
   (a `sequence`'s or a `dict`'s `[*]`) or `cell`; an `element` effect over a Maybe-like answer also records
   that its nullary alternative removes the taken position and stores nothing. `Calls` instantiates the callback once, projects that path with its κ, records retention at
   the destination and applies its store rule. Carry effects through forwarding, joins and blocks even
   when the enclosing result crosses. Ordinary `stored` preserves loan tags; a cell write-back first
   demands no loans and consumable ownership. `cellmodify` never demands ownership of the unrelated .0;
   `.0` aliasing `.1` is returned loan-tagged, not silently transferred. Element focus (sequence or dict) removes the taken
   position before comparing the replacement with the remainder; returning the taken value is permitted,
   returning another held element loses exclusivity. A callback `need` on its entire answer cannot encode
   these effects (#1052). `Rows.Signature` must expose the callback result place as well as its arguments. The no-call alternative
   (an out-of-range focus index) returns the original sequence unchanged; `once` means at most once.

   The new result selectors are mutually exclusive, result-only, and cannot be combined with `taken`,
   `lent`, `unknown`, `escaped` or other storage selectors. A source parameter cannot be `unused`/`escaped`.
   Validate element and callback-result types after solving, including through aliases; reject ambiguous
   destinations and `stored` on a list of callbacks. These selectors are new v2 syntax (#1052), not claims about S2b's parsed word set. Word metadata is versioned separately from v1; adding
   these v2 words moves all of that declaration's ownership words to the v2 column. Runtime code is unchanged.

   `cellstored` is a destination-specific store word: it means parameter 1's ◆, unlike `stored`, which means
   the result container's element position `[*]` (a sequence's or a dict's). `cellstored` creates a deep no-loan payload demand even when the result crosses.
   Ordinary `stored` grafts the payload shape and its path-indexed loan origins/lifetime into the result,
   including its deep has-loan condition; no no-loan demand is made merely for building a local collection.
   Later consumption/escape/suspension of that collection checks the retained tags. `cellnew`, `cellwrite`, `cellupdate`, `cellmodify`, `cellcomplete` and `cellread` use the
   versioned slot relation in §2.13.7. A row missing mandatory companion words/arity/types, or using both
   `fresh exclusive` and `builderdone`, is rejected during word validation. These are specified new syntax,
   not assertions that origin/master already parses it. The slice introducing each word updates parser, formatter, published type/row metadata, cache versions,
   diagnostic catalogue, `language.md` and `skills/beni/` together (S2b baseline, S3a #1052 completion).

   **Builder derivation.** `builder : unused Int → fresh exclusive Builder a` starts with empty `[*]`;
   `put : written returned Builder a, borrowed Int, stored a → Builder a` stores parameter 3 into `[*]`,
   computing κ by §2.9 at every store; `done`'s `builderdone` transfers that κ unchanged. The type's `sequence`
   metadata makes the contents visible without a name test. Hence mapHelp's recursive store/within calculation
   (§2.12) sees actual callback results: `List.map xs (λ_ → shared)` may produce a value but its inner write is
   refused (same shared object across calls); `List.map xs (λ_ → [1])` retains exclusive fresh elements; and
   `λl → List.push l 1` needs the input's κ. No Builder row asserts the final contents always exclusive.

7. **`Ref` loans** (R-5.12.3, #981): `Ref a` is a `ref` place; **`◆` is a barrier**: a holder of a `Ref` is not a
   holder of its contents, `reach` and Esc stop at `◆` (a `Ref` captured by a handler, a spawned fiber or JavaScript
   does not escape its contents, since only the worded operations reach them: rule 6), and the only outside
   holders of the contents are loans. `Ref.make v`: fresh `site` with `◆ ↦ v`, `consumed` on `v`. `Ref.get`
   (`lent`): `loan(c·ι)` per `c ∈ cellsAt(r, ◆)`, a holder that may be read, passed to readers and used to build
   values. Implement `lent` as a lazy overlay tagging every reachable mutable storage path in the cell's
   contents, stopping at nested ◆ barriers; scalars/crossing descendants carry no tag. A projection retains
   the overlay at the selected descendant. Loan origins carry the introducing region id (u32) and stable
   slot identity; summary substitution maps incoming region variables to the caller's original ids, never
   fresh regions. Thus a shallow copied outer list still has loan-tagged inner lists; a loan reaching Esc, a send, a model or a closure/return outliving its loan region is refused
   (`list_still_used`, with the depth-correct copy fix below). A callee returning an incoming loan
   through its `res` preserves the caller's original region; this is not itself escape. Thus `Dict.insert`,
   `List.push`, `filter` and forwarding helpers may return values carrying an incoming loan to its still-live
   caller. A locally introduced loan may not escape its introducing region except through an explicit
   trusted `lent` protocol. All loan-bearing descendant paths participate in later lifetime checks; a loan whose holder is live across an instruction whose effect rung may
   suspend (`Dispatch.effectAt`, `EffectPlan.zig`; `poly` counts as may-suspend) is refused. Call entry includes
   every argument, callback capture and callee environment until that call returns, even if the caller's last
   syntactic use is the call itself. Therefore `show (Ref.get r)` is refused when show may suspend; so are a
   passed closure capturing the loan and a suspending callee environment containing it. Existing pending
   operands are included. A loan returned by a suspending read is born **after** that suspension; it may be
   read synchronously, but cannot survive a later suspension. Indirect/unknown effects remain pessimistic. `Ref.set/update/modify`
   (the `cellwrite`/`cellstored`/`cellupdate`/`cellmodify` rows above): a `writer` demand on the `◆` cell; Dead requires every
   live loan of an aliasing contents cell dead; **re-entry**: the class field `refs` (§2.10) lists the `◆` cells a
   body or its callees operate on, by **stable handle/slot** identity, so a callback (or anything it calls) that operates on a `Ref`
   whose slot may alias the focused slot is refused at compile time (`p/RefOwnsContents`). **P-sync**, a trusted
   obligation of every platform, pinned: the runtime never enters beni code synchronously from inside a host call
   beni made (an event a host API raises synchronously is queued to the next dispatch), so within one fiber no
   beni code runs between two points that do not suspend. `Deferred` follows its explicit rows above. `Js.ref` is **worded**, but is not a `cell`-marked type:
   `ref : escaped a → fresh Ref a`, `read : borrowed Ref a → unknown a`, `write : borrowed Ref a, escaped a → ⊤`
   (`core/Js.beni:193–202`). Thus stored contents escape and reads are unknown, per R-5.12.4; a spawned fiber or queued body holds its captures as an escaped closure (R-5.12.1).
   **Slot state and loans.** A versioned frame relation `contents(handle-origin, ◆)` supplies current stored
   origins/κ. `cellnew`/`cellempty` initialise it; set/update/modify write-back changes it after the callback,
   and complete joins the already-complete/no-op and empty/store alternatives. Strong update is allowed only
   for one definitely identified slot; possible aliases get a weak union. Branches/recursive feedback join and
   settle this relation like other shape facts. Summaries publish these slot reads/writes and ordered
   transformations, so a later get cannot read only the original make payload. A handle alias names the same
   slot; replacing contents never makes an operation on that handle distinct for re-entry. Unknown callable
   `refs=top` touches every slot: refuse it inside a focus, and refuse any live loan across a call that may
   replace its slot even when the call is synchronous. Cross-module facts preserve these effects.
   Read the **value being stored** for loans before installing ◆; ordinary reach of an already-owned handle
   still stops at its own barrier. This rejects `Ref.set r2 (Ref.get r1)` and `Ref.make (Ref.get r1)` even if
   neither loan local is read later. `Ref.modify r (λxs → (xs,xs))` returns a loan, not an ownership escape;
   a subsequent update while it is live is refused. A proved-disjoint fresh result can still leave modify.
   **Copy depth and diagnostics.** `List.copy` copies only list storage; `Record.copy` only the record and
   `Dict.copy` only dictionary storage. Remove the loan at that copied root, preserve tags on every shared
   descendant. A copy/filter/map with fresh outer storage is therefore sufficient for `List Int` (and for
   opaque crossing handles), not for borrowed inner lists. For `r : Ref (List (List Int))`, a fully independent
   snapshot is `List.map (Ref.get r) List.copy` when the inner elements cross; `List.copy (Ref.get r)` alone
   retains `[*]` loans. Further nesting requires copying/rebuilding each loan-bearing path that will escape
   or survive suspension. Diagnostics list those paths and suggest a type-correct reconstruction whose
   inferred result has no such tags; if no finite fix is known, give a manual “copy these borrowed paths”
   explanation without a bogus automatic JSON edit. Never claim a shallow outer copy discharges deep tags.

   **S8 boundary.** A callback's selected write-back and its returned projection are evaluated under
   one snapshot before slot mutation. Slot effects form an ordered graph of alternatives: sequential
   writes compose; branch joins union alternatives; they are not an unordered set of writes. `refs` is a
   may-touch set keyed by handle/slot, not current payload identity. Cell/loan overlays, original region
   variables, store destinations and that order survive forwarding and disk blocks. Re-entry and may-suspend
   tests consume effect/class facts from the same settled generation; no syntactic-last-use shortcut.
   `Deferred.complete`'s no-op branch does not transfer ownership anew or erase live loans.

8. **Markup** (R-1.6, R-5.8.9, R-5.8.12): a `markup` instruction is a call of a row synthesised from the lowering's
   slot kinds: render slots `R`; event slots `A` into the result's `⟨event⟩` slot as borrowed payloads (`payload
   (a)` on an `update` write reaching them); a `For` row callback's parameter supplied borrowed (`read-only`,
   R-5.8.6, `p/RecordForItem`); a handler capturing a scalar key holds nothing. The construction's result is
   `fresh` (`assumed`, R-6.3).
9. **Casts** (R-4.11): a `returned Value → a` call whose argument place differs structurally from its result's
   makes `recast(place(a), inner)`; a later read **of the recast node itself** (no step taken since) at a place
   structurally identical to `inner`'s restores `inner` exactly; a projection of a recast is a recast over the same
   inner, approximate, never restored, so a child of a recast recursive value is not taken for its root
   (R-4.11.2). Retain the inner value interpretation, including its snapshot and loan overlay, not only its
   shape: an unstepped restoration restores those facts together (a recast and its inner are one position,
   §2.9, so what the snapshot stores at the inner and below it is read at the recast), while a stepped recast cannot recover
   a stronger certificate by finding a structurally equal type later; `(xs, xs)` read as a list of lists stays `shared`; casts compose to one `recast`.
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
    is unknown (R-5.13.2). A derived eq/compare class joins the actual component eq/compare classes,
    including uses, result aliases, escapes, callback effects and `writes`. It is not an unconditional
    read-only row. Apply the existing `writes` prohibition after that join; do not introduce a separate
    ban on an `A`/`E` label instead of computing the class.
14. **`?`** (R-5.1.6): §2.6; an error type holding no cell adds nothing.
15. **Index exchange** (R-4.8.17, #869, `p/RecordIndexExchange`): a callback of `List.indexedMap` (its index
    supplied as a scalar) keeps the source's κ when it is an **exact permutation**, which is a *flat decision chain* on the index
    and nothing else: the body is `if i == e₁ then t₁ else if i == e₂ then t₂ … else r` — each test a `case` on
    `i == eₖ` (a `method_call` of `eq` that `Dispatch` resolves to `Int`'s, `bir/Lower.zig:2540–2547, 2621–2630, 2873–2891`) whose `True` arm is a take `tₖ` and whose `False` arm is the next test or the element parameter
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
16. **Core's library**: every function of `core/` not asserted (R-5.10.8) is inferred from its body (R-1.10).
    `List.base`, `offset`, `unsafeGet` and `sliceOf` read the runtime representation, so they are **`List` array
    primitives** under R-5.10.8. They are asserted with the result selectors below and pinned under R-5.10.7 (decided
    2026-10-25, Appendix C.9):
    - `base : returned List a → List a`: π₁ `RA`, res π₁.
    - `offset : borrowed List a → Int`: π₁ `R`, crossing.
    - `unsafeGet` and `at` use result `elementof`: π₁ `R`, `[*]` `A`, res π₁`[*]`.
    - `sliceOf` and `copy` use result `copyof`: fresh storage, `[*]` π₁`[*]`, list κ `lost`, record κ `excl π₁`.

    **`sortWith` is asserted with `copyof` and a pinned body [O 2026-10-26]** (R-5.10.8, C.9): fresh storage,
    `[*]` aliases π₁[*], list κ `lost`, record κ `excl π₁`, comparator many with borrowed supplies.
    **Fold accumulator element κ remains `lost` [O 2026-10-26]** unless S4 independently proves C.9
    gap 3's narrowed rule; a storage-write proof alone cannot strengthen that condition.

    The builders return fresh storage because they start in the `sequence` Builder
    with empty contents, whose `put` is `written`/`stored` and whose `done` preserves provenance/κ; the result word
    `concatenated`: `returned` π₁ with κ `lost` at `[*]` for lists and κ kept for records when each input is exclusive and
    they are separate (one condition, kind-filtered, R-4.10.7, R-4.10.8, `p/SchemaIssuesExclusive`). A worked
    derivation of `mapHelp` and `foldlFrom` (§2.2's materialisations in force, the `taken` result, the callee
    `put`'s `stored` word) is specified before walker code in Appendix C and verified by S2b/S4's acceptance tests.

### 2.14 Soundness

**Concretisation.** Use-label `mark` cells have no object concretisation and never enter result cells.
For object cells, `γ(c)`: `site ι` the objects ι allocates in this frame's activations; `param πᵢ·q` the objects at
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
join (O4), an escape (O8, deep), a row (O9). Slot reads use the settled `contents` relation; ◆ writes fork/join it
by control flow and reject every borrowed stored payload. Ordinary collection stores retain loan origins
and lifetimes, including through summaries; only a copy of the corresponding storage removes its tag. Returned aliases of stored contents are loans.
Call-boundary uses include arguments/captures/environments throughout a possible suspension, even on the
last caller use. An unknown class touches every slot. Thus ◆ hides only owned contents, never an external
loan the caller may still read (§2.13.7). ∎

**Lemma 2 (labels).** *Within one activation, two occurrences of one unfolded label denote one object, and two
different `cb j` labels denote the results of two different calls of `j`.* The first because a label enters a value
only at the store of the value it names (O1, O2); the second because a label is a function of the concrete call
chain (the frame's instruction, then the callee's label, which is the same function one level down), so different
labels have disjoint chains — which the uniform fold keeps: a first instruction is folded everywhere or nowhere in
a class, so no unfolded label's chains lie inside a folded label's. Whether two different calls' results are one object is what §2.11 item 5's
instantiation decides from what the callback returns under what it was handed (O14). A folded label is
approximate: two occurrences of it from one value are `lost`, and `within` rests on two per-cell claims, each an
obligation — a `result` not reached through a feedback supply is allocated afresh by each call (O1), and two `taken`
positions of one traversal (§2.2) of a container exclusive at that path are two objects (I-κ, O9). A closure call changes the
identity of its new allocations only, never captured origins. The recursive environment quotient unions
possibilities and keeps every capture edge; settled facts and independently validated obligations are required.
A cycle or exhausted resource cannot establish either claim. ∎

**Invariant I-κ (exclusivity).** *If κ(v,q) holds at program point p (`yes`, or a conjunction whose atoms
hold of the actual arrivals), objects of the written kind reached at q in distinct positions of its
summary place are pairwise apart. This is a claim at q, not at every descendant. Sharing between explicit
paths remains represented by their cells and is tested when those paths are compared or held. A deep
demand must establish the invariant at every tracked path it demands.*
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
| O5 | *Summaries cover bodies:* `res`, `E`, `W`, `fun`, `classes`, `slots`, `refs`, `writes`; instantiation is extensive | §2.10–§2.12 |
| O6 | *Materialisation partitions:* `γ(elem) ∪ γ(others) = γ(proj(c,[*]))`, `γ(level) ∪ ⋃γ(below·s) = γ(c⟲)`; the sides are disjoint only under κ(ι); `⟲` covers every level | §2.2, §2.13.3 |
| O7 | *Delta is the base written:* `γ(delta(b, O))` = `γ(b)` with children in `O` replaced; the `ε` object is `b`'s | §2.3, §2.6 |
| O8 | *Escape is deep, directional and forever:* an escaped node's every cell is escaped; a write is blocked by an escaped ancestor-or-self, a deep demand also by a descendant; never undone; `shared` never owned | §2.4, §2.8 |
| O9 | *Rows state their bodies;* the index obligation of a `taken` result is pinned on each caller; P-sync and P1–P4, P7 on each runtime | §2.13.6, §2.13.7, R-5.10.7 |
| O10 | *Unknown is never empty* | §2.3, §2.11, R-3.4 |
| O11 | *No bound accepts:* reserve before expansion, terminal error on exhaustion; no partial summary or lowering channel | §4.4, R-3.7 |
| O12 | *Hoisted reads are this frame's own:* every hoist is a `field`-kind use the index recorded (a field chain, a record pattern, a field capture of a closure created after the write), never a callee's or a whole use | §2.7, §3.7 |
| O13 | *Constructions keep I-κ:* a literal's or construction's κ is `yes` only when the stored cells are pairwise apart per path and each stored value's condition at that path holds; a stored refinement of the base's own `[*]` is `shared` | §2.9 |
| O14 | *Instantiation keeps I-κ:* κ(res) instantiated is `yes` only when every atom holds of the actual arrivals (a `sep` over two labels holds if their instantiations under their supplies are apart; a `within` holds if each instantiated cell is distinct per call — a fresh `result` not reached through a feedback supply, or a `taken` supply of one traversal (§2.2) under its container's κ; folding is uniform per first instruction, so distinct labels have disjoint chains); a `delta`, a storage permutation and a `taken` write-back lower κ exactly as the stored value's condition says | §2.9, §2.10, §2.11, §2.13.15 |
| O15 | *Join lowers κ:* κ(join) is above (no stronger than) every member's κ (`and{A} ⊔ and{B} = and{A ∪ B}`), and a union's κ is the join of its members'; derived functionally from immutable operand snapshots where `Transfer` and `Summary` join; `Shape.join` knows no κ and cannot mutate it | §2.3, §2.9, §2.10 |

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
identity    : charged structural graph-pair tasks; pure source nodes memoised by by_var
ctor_steps  : interned (constructor id, argument index) pairs; Step payload indexes this table
              compare/encode the pair semantically, never the pair-table index
by_var      : stamped column Var → PlaceId   (the type walk's memo; `stamped.zig`)
path_bytes  : []u32 canonical path step records (`⟲` reserved); charged construction/traversal per step, no copied uncharged path string
```

### 3.2 Cells (`Cell.zig`)

The explicit `labels` table preserves identity and is charged before each insertion (§4.4).
Acyclic wrapper composition may exhaust the resource; it never merges ordinary labels to fit.
The callback views of §2.11 use `u32` template/context ids, `MultiArrayList` columns for invocation and supply
environment, and composite memo keys; neither pointers nor a map keyed by a dense id are needed. Their query
records enter the same owning-summary account (baseline lanes or growth); layout alone proves no linear bound.

```
Cell.Table (per walk)
  origin   : u8     site | param | env | shared | result | esc | cb | msg | top | elem | others | level | below | loan | mark
  kind     : u8     list | dict | record | ref | closure | opaque
  a, b     : u32    site: instruction; result/esc: LabelId + k; refinements: parent CellId + LabelId (the split's chain); param/env/shared/msg: index + PathId; cb: LabelId + PathId
labels     : MultiArrayList { inst: u32, callee_label: LabelId (.none = the frame's own call or a folded `ι⋆`), folded: u2 (no | ordinary | recursive; recursive wins), supplies: Range }   interned by (inst, callee_label, folded); refinements' `b` is a LabelId too (a split's chain)
  place    : PlaceId
  parent   : CellId   the trie parent: the path minus one step, or the refined cell; .none at a root
  children : Range    into `child_cells`: the trie children in first-sight order (the descendants of a cell the program named)
intern     : owner-local comparison tree (origin, kind, a, b, c, place) → CellId
sets       : persistent compressed binary radix sets of (CellId, approx), u32 keys; at most 33 nodes per insertion
             union shares unchanged subtrees; duplicate exact evidence wins (approx ⊑ exact in the evidence order);
             `Radix`: insert, member, unionWith, subset, intersection (the common keys, approximate when either
             is; one descent, O(min) nodes: the κ read's repeated cells, §2.3)
splits     : MultiArrayList { container: CellId, inst: u32, label: LabelId, cond }   (S1)
             the split instruction, its label chain and the container's projected interpretation; immutable per version
             S4 adds single: u1 and entry: LabelId (§2.2 *Traversals*); .none entry = this recursive group's entry
marks      : MultiArrayList { bits: u4, fields: SetId, deep: u1 }  interned use-label payloads
```

### 3.3 Shape nodes (`Shape.zig`)

```
Shape.Table (per walk)
  kind     : u8        leaf | node | delta | recast | union | positions
  place    : PlaceId
  cells    : SetId     (delta: the base's)
  a, b     : u32       node: Range into child_tab; delta: base NodeId + OverId; recast: inner; union, positions: left, right
  reach    : SetId     memo, persistent (.none until asked)
child_tab  : []NodeId          dense per node in the place's step order
over_tab   : MultiArrayList { step, child: NodeId, left, right: OverId }   persistent sorted tree
intern     : owner-local comparison tree (kind, place, cells, child-run id, b) → NodeId; runs built by charged chunks
memo_proj  : stamped column NodeId → bounded inline cache of (step, immutable input version, NodeId); misses use owner-local operation records
memo_join  : owner-local comparison tree (canonical member-run id) → NodeId; memo_leq / memo_eq: (NodeId, NodeId, immutable version ids) → u8 (coinductive shape assumption only)
memo_map   : stamped column NodeId → NodeId within one immutable substitution context/version; different contexts never reuse that stamp
```

κ is **not** a column of this table, and neither is a use label: no node owns a mutable fact (§2.9).
`Cond`'s per-value snapshots carry κ (§3.4); `mark` cells carry use labels (§2.2).
The inverted holder index belongs to `Demands` (S3a), over Cell's persistent set nodes: dense
`CellId → live set-node head`, same-cell links, a live count per set node, live parent links, holder-root lists,
and §2.8's anchor and refinement chains (heads in an owner-local comparison tree keyed by
`(base origin, PathId, class)`, links in dense columns). Cell itself
contains neither liveness nor a holder registry. Holders are found through the live inverted set index (§2.8), never a scope scan.
Live parent links and their transition/query tasks use §4.1 accounting.

### 3.4 Conditions (`Cond.zig`)

```
Cond.Table (per walk)
  kind    : u8      yes | and | atom | shared | lost
  a, b    : u32     and: (CondId, CondId); atom: (atom kind: excl | sep | within | apart | keep | writes, operands)
groups    : canonical persistent CellId sets (`apart` members); sorted runs only on charged export
intern    : owner-local comparison tree (kind, a, b) → CondId
kappa     : KappaId roots, one per value interpretation (shape root, KappaId); a frame holds value → KappaId and
            a class one root for res and each supply; use shapes carry marks, not value κ. Each is an immutable
            persistent hash-consed trie: a position record `{ here, links, fold }`, `here` a radix map
            NodeId → CondId (the conditions stored at this position), `links` a radix map step word → KappaId
            (the position one step below; a child's snapshot linked at a construction, never re-keyed), `fold`
            set on a position `widen` folded (exact, from `propagate`, or collapsed by `kappaFold`, §2.9),
            whose links are the steps it saw and lead to itself. A key (NodeId, path) has its path
            relative to the root of the snapshot that stores it; a reader holds a cursor (a KappaId) and moves it
            by `kappaChild` along the steps it takes, re-rooting at a link. S2 built one radix map
            (NodeId, position class) → CondId per value; S3a gives frame values their own roots and moves the key
            to the trie (`kappaGet`/`kappaSet` at a cursor, `kappaSetAt` along steps from a root, `kappaLink`,
            `kappaMerge`, `kappaFold`, `kappaOf` the read); S3b relabels nodes through Shape.map and links an
            argument's snapshot at the graft of a summarised declaration. It travels with its value and is
            joined only where values join (a branch or fixpoint join, a union, a construction of its children),
            never mutated through another value; equal immutable roots may be shared across values and remain
            shared after decode. Reads obey §2.9's kind-specific rule: stored construction certificate (or lost)
            for node/delta; stored plus derived for a leaf/recast; side reads, stored term and the appropriate
            set/multiset derivation for union/positions. The observable frontier includes projected leaves and
            empty nodes, through the snapshot's links. Every reader, join, comparison, substitution and block
            codec uses that frontier. Read memos require the complete immutable interpretation/context, the
            cursor included; never a mutable column NodeId → CondId
flat      : memo CondId → sorted atom run (print, compare, block)
memo_sep  : owner-local comparison tree (CellId, CellId, interpretation/κ version) → CondId; `deep` walks per query and stores nothing in a root
```

### 3.4a The liveness index (`Liveness.zig`)

```
uses      : MultiArrayList { atom, local, path: PathId, point, rank2: u32, kind: u8, region, use_node: NodeId (.none unless kind call) }
            atom: the use occurrence, unique in the declaration (asserted at build under runtime safety)
            sorted by (local, path rank, point)
by_local  : column local → Range into `uses` (dense: a declaration's locals)
path_rank : stamped column PathId → (rank, subtree rank interval) for every canonical path node an indexed path
            passes through, assigned once by one walk of the path trie
by_path   : within a local's range a sorted run of (path rank, Range), binary-searched by one-word comparisons —
            never a local × path table
subtree   : merge-sort tree of (point, rank2, UseId) runs over rank intervals, each node with a max tree over rank2
            each use belongs to at most 33 tree nodes; paths stored once, no ancestor copies
last_use  : column local → point
```

### 3.5 Classes and summaries (`Summary.zig`)

A class is a sub-table of the walk's tables plus:

```
Class
  params   : Range   per parameter a use-shape NodeId; labels are Cell.Origin.mark payloads
  kappa    : KappaId immutable interpretation root for res and corresponding roots on supply/use values
  res      : NodeId
  xreq     : Range   atoms
  funs     : Range   { calls: u2, need: u1, seen: u1, supply: Range of { label: LabelId, k, node, taken: u1, kappa: KappaId, owned: u1, port }, keeps: Range of { k, kept_path: PathId, written_path: PathId, writer: u32 } }
  classes  : Range   into the summary-local class table: ClassId per closure node reachable from res/supply/use
  slots    : Range   function-typed parameter ports {param, path}
  effects  : Range   selected callback result write-backs and ordered versioned handle/◆ transformations
  refs     : SetId   stable handle/◆ slots touched; top bit for unknown
  writes   : u1
  once     : Range
  account  : SummaryAccountId   -- owner declaration, inherited by every nested class
```

In S2 a supply is keyed by `(label, k, node, taken)`: a fun's supplies are sorted by that key, and a join
merges two supplies only when the whole key is equal. The S2 record also carries `j`, `owned` and the handed
value's κ root (`Facts.Supply`); S4 adds the receiving `port` of a carried class (§2.10) to the key.

Summaries live in the module arena as immutable local graphs. Local normalisation orders graph references
and supply keys for comparison/printing; its words still contain owner-local ids and are neither hashed
nor published. Semantic equality is mutual simulation, not equality of these local words. Only Block's
id-free normal form below can feed interfaces and caches. The retained analysis memo graph is workspace,
not interface semantics; §4.4 defines its charging and lifetime.

### 3.6 Blocks (`Block.zig`)

The block is a serialization of **observable class meaning**, not a dump of the tables. At every
reachable result/supply position, a decoded value must read the same κ as the exported value under §2.9,
with the same aliases, multiplicity, effects and callback obligations. Test those reads directly; stable
pretty-printing and write/read/write bytes alone cannot establish this property.

**Positions and owners.** A value position is `(shape node, trie cursor, position class)`: the cursor is the
snapshot position the reader has reached from its owner's root (§2.9), so two positions of one value at one
node are two records. A use shape has mark cells and a separate non-value owner. A value owner names an
immutable snapshot and all value roots using it. Equal snapshot roots share an owner and a decoded snapshot;
distinct values need not own distinct physical tries. Neither sharing a shape nor equal node ids permits
sharing an interpretation with different facts.

For each owner, close its roots under the transitions any κ reader uses (§2.9's sparse frontier): the steps
the structure names, a recast's inner's included (the two are one position), with union/positions sides read
with their node, and the steps the owner's snapshot links at the cursor. Explicit parts, a delta's base among
them, may be walked as structure; a base alone holds nothing observable. A link reaches stored constraints
under a leaf, under a recast and at an empty shape, so the routes to them are the links themselves and need no
search of a type's fields. The finite worklist keys states by `(node, cursor, class)`; a fold is one state for
all its levels. An implementation may omit a state only when its reads are derived entirely from preserved
structure and no reachable stored entry affects them; this criterion is shared with `propagate`, `kappaLeq`,
`deep` and substitution. A written position also records whether its cursor is a fold, exact or collapsed,
so the reader rebuilds the fold; a fold's steps are the steps its members take. Adding a reader requires updating this closure contract and its tests.

Each written position encodes κ **as stored**: what the snapshot stores at that position and nothing
derived (#1069). Every reader adds the derivation from the structure the block rebuilds, so the
reconstructed read is identical, including `lost` for a built node with no certificate and the
multiplicity a union/positions node derives from its sides; a reader that uses only what is stored at a
position (`deep` below a leaf) reads the same after decoding as before. Do not interpret absent stored κ
as a uniform bottom. Initial refinement colours include these read facts, place, kind, cells, step labels
and position class: structurally equal knots with different κ are not the same semantic position.

An owner record names the union of all its roots and reachable constraints; every class/supply using it
names that record. Decode its complete map once, then give the same immutable root to each member. Closing
per owner but decoding separately per value loses a constraint when a second root reaches it by another
route (#1060 fifth review). If shape interning absorbs a union or merges pure nodes, retain separate
interpretation positions where their reads differ; never strengthen one by dropping a stored constraint,
and do not silently weaken another through accidental map-key collision. The path trie provides that
precision independently of structural sharing. A new interpreter key requires a block version bump.

**One canonical graph, including cycles.** Write each place, path, label, split, cell, set, condition,
position, owner, supply, keep, write-back effect, class and environment record once, with ordinal edges.
Canonicalise the whole reachable place graph and whole position graph, not one knot or one DFS root at a
time. Global partition refinement identifies equal labelled structure/read facts; a cycle's length or a
mapped copy outside its SCC cannot affect its quotient. Nominal heads, fields and constructors use
package-qualified names and canonical semantic ranks; ctor steps encode the pair, not its intern index.
Use exact signatures to distinguish equal hashes: hashes alone neither prove equality nor order ties.
Canonical ordinals follow semantic root/member/supply order after refinement; they are never discovery,
worker, session or intern ids. Local `Summary.normalize` words are not this form.

A knot group reserves all its members before edges are tied. Cycles may cross typed child/projection
edges and class/environment backreferences; unions, recasts and other constructors may not point to
unfinished non-child inputs unless a corresponding constructor explicitly supports that knot. Readers
check this grammar, node/child/base/cell places, tag/range/arity, supplied projection correspondence and
mark/value separation before invoking operations that assume them. Recompute place SCCs after decoding.
A source cell is interned with its place as part of its interpretation (#1055); type variables of a block
have a separate namespace, never a base chosen from the reader's highest *queried* type id.

**Cost and sharing.** Let V and A count distinct reached position states and edges across distinct
snapshot owners; Q and T count the shared place graph; B the other bounded records and bytes. Repeated
supplies under one owner add only their reference records, not another walk of its value. Different
interpretations really can cost their product with shape size; this is charged growth, not source-linear
by assertion. Position discovery costs O(V+A+B) charged transitions plus the invoked κ/projection tasks.
Canonical refinement targets O((V+A+Q+T) log(V+Q+2)+B) with explicit stacks: smaller-half scheduling moves
each predecessor edge O(log(V+Q+2)) times; fixed-word radix grouping orders `(predecessor,label)` and
`(block,signature)` runs in linear work per moved edge. Exact variable signatures use shared tries/runs
charged per word; never re-encode an entire reachable place graph for each place key. General κ derivation
work remains in §4.1's N_f, not hidden in this refinement bound. Comparison-sorting every splitter adds an
extra log factor and is not this algorithm (S2b's `Refine` no longer does it, #1065). Every scan, sort,
dictionary access, trial decode and commit is reserved **before** its work, including failed decoding.

**Module and cache boundary (S6).** One versioned `OWN2` block per module contains a shared record table,
canonical declaration directory and per-parameterless-value holding facts. Directory entries refer into
the shared table; a lazy read resolves only its reachable graph with a block-local ordinal memo. Reading
several declarations must not copy a shared class/environment table per root. Package-qualified import
names and declaration/local occurrence ordinals are resolved at the adapter, never by module basename.
The format version changes with semantics; do not hardcode the end-state version as S2b's version.

`Interface.ownership` hashes only canonical semantic sections. Resource policy, allowance, baseline/growth
measurements and category counters belong to the cache envelope, not the public class hash: a body-only
change in inference work must not invalidate clients whose exported class is unchanged. Cache keys include
compiler/ownership format, input and imported semantic hashes, effective allowance, accounting policy and
engine selection; lowering channels have their own version. A cached success under a larger allowance
cannot bypass a smaller one. Same-session core, fresh dependencies and disk imports use the same class API;
no importer may see a producer's provisional tables or analysis memos. Register consumed semantic records
once per owning declaration's import lane, even when immutable storage is physically shared.

Decode into isolated scratch state and reserve a validated remap/commit plan before touching live tables.
The plan accounts actual destination operations as well as the trial; do not assume a replay into a
populated table costs the same as a fresh-table trial. Publish roots atomically after validation, never a
partially tied class. Malformed/truncated/old-version bytes are a cache miss (or unknown imported summary,
R-5.7.4), not an empty class; a genuine resource exhaustion is the named loud error. For source available
locally, a cache miss recomputes. A missing/corrupt dependency cannot authorize a write. Neither case may
leave cells, splits or a completed memo that contaminates a later successful read.

**Traversal marks** (§2.2). Every taken refinement carries its settled `single` bit and `entry` label;
`none` entry means this recursive group's entry. Labels carry their fold kind (`no`, `ordinary`,
`recursive`), and recursive wins when folding. Supplies retain their `taken`, owned and κ fields; splits
retain parent/container, label and projected condition; `sep`/`within` and callback write-back effects
retain the same label references. Instantiate entry labels by prepending the calling instruction exactly
as for other labels. The frame's in-force materialisation set stays local. Missing/inconsistent marks,
out-of-range entries and `single` on a non-taken cell are decode failure, never default `single`.
Marks are numbered and written only after solving. The S4 block extension is required before a carried
callback/traversal crosses a module; S6 adds disk/lazy infrastructure, not delayed soundness.

**As built in S2b (the minimal block).** `Block.zig` writes and `BlockRead.zig` reads (§5). A class means
κ *as read* (§2.9: stored ⊔ derived at the position), so its shape nodes are written as **positions**: a
node, its position class and its owner's map (one owner per hash-consed map, so supplies that share a map
share their positions; a use shape is no value and carries none). An `owner` record names every value
under its map, from every class and supply of the block, and the reader builds ONE map for the owner from
all of them and gives it to each, so the closure below, made per owner, is the reader's too. The positions are the owner's values,
closed under the node's parts (the children it holds, a delta's base, a recast's inner, a union's or a positions
node's sides — never the steps of its place type, so a type's width costs nothing), and **every entry of the owner's map that a read can reach**, with the
projections that lead to it from those (found along `Cond.frontier`'s transitions: as built in S2b every step of a place, while the map held an entry not yet found, a map keyed by node giving no route from the entry; since S3a's trie (#1073) the snapshot's own links, so a type's width costs nothing here either). That set is closed for every read: `kappaOf` at a `proj` path
from a value, as `kappaLeq`, `propagate`, `join` and `map` make, and `dagKappa` through a union's sides,
reaches either a written position, which carries the κ read there, or a node with nothing stored, whose κ
is derived from the structure the block rebuilds alone, in the writer as in the reader. Each position
carries the κ read there (a union's or a positions node's: what is stored there, as its sides are read
with it) and the positions `proj` makes that the node's parts do not name. The reader stores exactly that
κ at exactly those positions and checks that `proj` makes each of them, so every read of the decoded class
is the written one's. A union whose constructor absorbs it into a side (its sides merged) has its κ read
as written and joined into the side: exact at its position, never less below. Different maps over one
value are different owners and each costs the value's positions: that cost is the input's.

One record table: labels, paths, cells, splits, cell sets, atom sets, conditions, atoms, positions,
supplies, keeps, slots and classes, each written once and named by its ordinal. A record follows its parts,
except in a knot: the positions of one cycle are one `group` record whose members are numbered together;
a child step or a projected position may name any member, every other part an earlier record. The order is
canonical and exact (#1065), and no hash reaches it: `Refine.rank` orders keys by their words with a merge
sort and makes equal neighbours one rank. The places the records name, closed under their children, are
refined once as one graph, so a place's rank is shared by every key that names it and no place's reachable
graph is encoded per key. The records no position reaches are ranked a height at a time, each naming its
parts by their keys; all of the block's positions are partitioned once by Hopcroft's algorithm
(`Refine.blocks`) from their kind, class, place, cells, κ and steps; the owners, supplies and classes are
ranked last, by height. The refinement is unlabelled with counted edges: a position with more than one
labelled part has a port state per part, so a union's two sides are a count, not an order. The touched
predecessors are grouped by lists threaded through per-state and per-count arrays, never a comparison sort of
a splitter's edges; the blocks that split are taken in number order and a block's parts in count order
(sorts of at most two items per new block). Those numbers follow the split history, which copies of a state
steer, so the quotient — one state per block — is refined once more and its numbers are the keys: bisimilar
position or place graphs, however many copies they hold, get equal keys and bytes, and write ∘ read ∘ write is
write. Each edge is read O(log n) times; the refinements are O((V + A) log V) and O((Q + T) log Q), the
ranking O((E + R) log R). Records of one key are one record, and a final sort checks that no two units
spell the same words. Every lookup, token, scan, sort and word is reserved before it is done (#1066) on the
codec's lane (§4.1, `codec_factor`), and nothing reaches the output before all of it is paid: a refused
write leaves no output and no memo the next write would read. The κ reads and projections run on the lane; the
owner's growth sees only a class's second interpretations of a node, counted as if the class were alone, on
its own declaration's charge. The table is a post-order walk from the classes. The reader builds a
knot's nodes and deltas as nodes no constructor interns and ties their child maps when the knot is read;
everything else is its constructor's, and a node no constructor makes (sides at two places, a child at a
place its step does not reach) is no block. It decodes into tables of its own first, on the codec's lane:
its allowance is `codec_factor`'s bound of the block's length, set before any word is read, and its records
are the caller's baseline. A decode past that bound is no block; one past the room in the caller's place
table is the caller's limit, never "no block". Only then does it build in the caller's tables, with the
block's places in a namespace of their own.

**Where S2b's block is short of the contract above.** The note describes the code; the text before it is
the target. (1) `Cond.kappaOf` already reads κ by §2.9's kind-specific rule, and `Block` writes through it;
the gap is the frontier: `propagate` and `kappaLeq` stop at leaves and recasts and skip empty projections, so
a stored constraint below them is not carried or compared, and `propagate`'s visited hash and retained slices
are unsound (#1063, #1064). Both are repaired before S3b. (2) The absorbed-union merge is
conservative under S2's coarser `(NodeId, position class)` key; the path-trie precision above arrives with
S3a's trie. (3) and (4), a comparison sort per splitter and variable work done before its reservation, are
repaired (#1065, #1066): the note above is the code. The ranking's sorts are by the words alone, per
height and per refinement, within the stated bound. The record table also holds `owner` records
(`Block.Kind.owner`), which the list in the note leaves out.

### 3.7 Inputs, outputs, and where the pass runs

Inputs (R-1.6): the module's `Bir` with the new spread table (§2.13.2), `Check.Module` (`inst_type`, `local_type`,
`decl_scheme`, the store), `Dispatch` (method callees, `eq`/`compare` declarations, `effectAt` for the per-call
rung: `Dispatch.zig:503`, `EffectPlan.zig`), the imports' interfaces with their blocks, the schema plan, the
lowering interface's slot kinds, the ownership words (`Decl.own_*`), the package kind. Never read (R-1.7):
platform or constructor names, mode flags, session ids, completion order, paths.

**Where it runs.** The per-module hook exists: `check/Driver.zig:443` calls `Enforce.checkModule(ctx, d, m, tid)`
in the worker that checked `m`, after its type check and before `Incremental.publish`; `Enforce.zig:171` publishes
the block into `d.interfaces[m].ownership`, and `Incremental.zig:300` hands importers their blocks from the
interfaces. v2 keeps this hook unchanged (`Enforce.zig` is ported), so the firewall (R-5.7.3), the interface hash
(R-5.7.2) and R-7.8 (a module's pass runs in its own worker, no new wait) hold as today. `Session.zig:2528–2557` builds `Enforce.inputs` and passes `Enforce.Context` into the driver;
there is no `Enforce.run` entry point on the reviewed master.

Outputs (R-1.8): diagnostics (§6); the report (R-7.15); the block; the lowering channel (`Hoists.zig`, format v2:
`Step` gains a constructor-argument kind for pattern reads through a wrapper, R-4.8.12; list writes implemented in S8b (plan item O5 of oc §30.7, not obligation O5)):
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
Before inference, assign source/import semantic ranks by canonical package/module/qualified declaration
name, then lexical instruction/port and structural type/field order. Interned spelling addresses, source
*declaration* enumeration and session `TypeId`s never order ownership keys. Sort original name bytes/runs once
(charged to written input); map physical checker ids to these ranks at the boundary. Imported structural
records get the same ranks cached or fresh. During inference, new ids follow the pinned canonical task and
watcher schedule; they are immutable, never globally re-ranked when a new id appears. Fixed-bit set structure
and lane/operation keys therefore have the same insertion order and counts after declaration permutation.
Serialization's final canonical renumbering rewrites references together and never feeds inference. Nothing
printed is an id: source names, field names and normal-form text; equal-position diagnostic ties use source
order (R-7.6). Test counts/verdicts just below, at and above the allowance under permutations and worker counts.
A module's result is a function of its BIR and imports' blocks, excluding physical enumeration (R-7.7).

### 3.9 Arenas and lifetimes

Per worker: a **module arena** (normal-form summaries, block, report, channel) released at publication; a **walk
arena** (cells, nodes, conds, sets, uses, demands and retained operation records of the group) reset only
after that group's final validation/encoding, never between its fixpoint rounds. The account lives through
publication; validation and encoding inherit it, without a fresh allowance. Growable lists and explicit stacks only (R-7.12).

---

## 4. Complexity

E, P, S_f, B_f, G_f, N_f and R_f are defined in §4.1. In local operation bounds C counts cells, U uses, D demands,
and H live holders; these local bounds are not substitutes for the whole-module accounting.

### 4.1 Per phase

Let **E** count written BIR/type/capture-schema edges and imported bytes actually read; **P** is the total
selected path steps traversed by the fresh-result fragment, not the number of queries. Let F be the number of
owning declarations, R_f its growth allowance, G_f its charged growth records and B_f its proved source-sized
records. N_f=B_f+G_f is its complete workspace (including logically owned shared records). G_f≤R_f on success;
B_f≤16,384 S_f under the source/import lane construction below. N_f is not capped at 65,536.
Source-derived place/region tables are built once in O(E); inferring memberships, canonical paths, proof
contexts and derived indexes is not hidden in E. An input string/name is interned once in input time.

| Phase | Bound actually proved | Scope |
|---|---|---|
| supplied place graph, initial pre-pass, regions | O(E) time and storage | each supplied graph edge once, reverse-edge/SCC worklists; constructor-template instantiation, structural graph comparisons and dynamic dependency discovery charged below |
| fresh-result selected-path fragment | O(E+P) traversal, plus deterministic dictionary lookup cost where needed | shared templates/scopes, first-divergence comparison of selected occurrences, only after whole-template generativity/internal-sharing certificates; no supplied/captured/feedback result assumed fresh |
| actual template setup | O(B+V) traversal | B prepared template/binding edges, V requested constant-size views; neither is multiplied eagerly |
| persistent `reach`, cell/κ sets, inverted index, general liveness/resolution, joins and shape comparisons | O(N_f log(N_f+2)) per owner | the retained operation graph and proof below include failed/zero-growth work, all live-parent routes, projected paths and all intermediate nodes |
| recursive groups, feedback, entry | O(N_f log(N_f+2)) per owner | all deliveries, union tasks, affected-transfer continuations and validation belong to the same account; no fresh budget per round or class |
| normalisation and block write/read | O(N_f log(N_f+2)) per owner plus bytes read/written | graph references, no recursive unfolding; inferred order/comparison work charged; fixed-size record encoding linear once ordered |

These are bounds for the specified completed algorithms, not measurements proving all S2 kernels meet
them. `Cond.lower` must index arrivals by original base so W distinct-base insertions do not rescan W
members (#1054); exact same-base comparisons remain individually charged. `Cond.propagate`/`kappaLeq`
need the observable frontier and exact states of §2.9 (#1063/#1064). Block refinement and shared place
keys meet §3.6 since #1065, with pre-work reservations since #1066. Charged superlinear work is never made source-linear by the limit.

**The codec lane and `codec_factor`** (the owner's decision, 2026-10-26: the allowance counts summary growth,
so the codec does not spend it). Encoding and decoding a block are the *codec/import index*'s work: the
writer's lookups, tokens, scans, sorts, refinements and output words, and the reader's trial decode, are
baseline records (B_f) on one codec lane per block, each reserved before its step. The lane is bounded by
`codec_factor`·(S + 16)·⌈log₂(S + 2)⌉ records, where S counts the records and edges the writer reads from the
tables — including the source-derived place graph, so a type's depth or width never spends R_f — or the words a
reader decodes. `codec_factor` is **16**. The algorithm's own bound is O(S log S) (the refinements and the
ranking's sorts above), and the measured maximum over the block tests is 1.9·(S + 16)·⌈log₂(S + 2)⌉, so 16 is
margin for a defect, not a budget. Past the bound the writer stops with `ownership_accounting_invariant` (the
codec broke its own bound), and the reader returns no block (no writer makes those bytes). The κ reads and
projections the writer makes are on the lane too. The only growth is a class's own summary, counted as if
the class were alone in the block (so editing another declaration never changes it): the positions it reaches
past one per node — a node under another κ map (§3.6). A many-map class still meets the limit loudly.

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
On an exhausted owner G_f=R_f and the failed next growth reservation does no work. Substitute
N_f≤16,384 S_f+R_f for the actual resource bound; there is no declaration-length cap at 65,536. This is a **resource-parameter bound**, not an assertion of linear growth
as unrestricted written programs get bigger. A raised R_f raises only the growth allowance. The O(E+P) fragment does not prove
P=O(E), nor does a finite fixpoint prove cheap evaluation. Budgeted general operations may stop with a loud
error; ordinary labels are never merged to make the resource fit. The three general R-7.4 cases are explicitly qualified below.

**Persistent sets: representation and total accounting.** Use persistent 32-bit radix trees in
columns, keys ordered by canonical semantic ranks; path copying shares unchanged subtrees. Dense roots/memos use columns.
Owner-local composite-key dictionaries and operation memos use deterministic comparison trees over constant-size keys; do not rely on average
hash-table cost for this bound. Variable-length paths, groups and child lists are persistent cons/tree records
with bounded-size keys; constructing or comparing their sequences uses the tasks below. Physically shared
nodes are logically registered once to each owner which relies on them. The tree is a fixed bitwise trie with unary paths compressed only canonically: insertion copies at most
33 nodes, with no median rebuilding. Equal-content sets have the same canonical structure/rank order. Inserting an existing key and union adding no facts return the original destination root; charged
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
| fixpoint propagation and affected-transfer evaluation | delivery `(edge,fact)` or immutable-root union request; new-edge replay of existing facts; watcher/notification edges; transfer cursor and immutable dependency version for each affected evaluation |
| dependency cycle search, validation, numbering, block codec | graph/version plus DFS/worklist cursor, visited record and continuation; cycles write id backreferences |

A task/request is reserved **before** dictionary lookup (hit or miss), interning, climbing a parent,
walking a path/region, allocating an output or scheduling an edge. A query never walks region ancestors
or siblings: compatibility is §2.5's `rank₂` threshold inside the range descent, or the bounded ancestry
kernel for a pair. Memoise a completed answer only after all fallible checks succeed;
provisional cycle knots are private and invalidated on failure. A task runs at most once, reads/writes O(1) already-addressable words and
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

**Proof.** Classify every data/task/edge/tree-copy record before allocation: consume its unique source lane or reserve growth;
never refund within an owner's computation. There are N_f retained records, baseline plus growth as defined below. Every task executes once and
issues boundedly many requests, every registered edge fires once, and source seeds total O(E). Thus there are
O(E) direct source steps and O(Σ N_f) charged steps/fixed-key dictionary operations. Their height is O(log(N_f+2)); every
variable-width operation was split into accounted steps. Summing gives the displayed module bound, including
zero-addition unions, repeated holder activations, failed separation and validation. Workspace teardown happens
after validation and encoding, not between rounds; normalisation/compaction cannot refund the allowance. In an
SCC each task is attributed to the declaration whose summary it computes; a task used by two owners is logically
registered to both. A nested class uses its enclosing owner, never its own growth counter or renewed source lane. This also accounts imported
semantic records before traversal, with no dependence on whether an import was checked or cached. ∎

These are **real retained memo/continuation records**, used for deduplication, invalidation, dependency
resumption and diagnostics, not a second counter of instructions or rounds. Dropping them to retry work later
is outside this implementation. The cost counts the full workspace, and the limit guards all records outside the proved source lanes
(§4.4); counting only final serialized facts would not prove the bound. Instrument category counts separately.

**Source work versus growth [O 2026-10-25].** The resource counter is **G_f**,
non-source-proportional retained records, not every record of a declaration. Its default allowance **R_f** is
65,536. N_f = B_f + G_f counts the whole workspace for cost measurement. B_f has nonfungible source/import
provenance: a record can enter B_f only through one of the fixed lanes below. No global pool of unused source
credit can pay for a context expansion. This chooses the owner's permitted “charge only growth” alternative.
A fungible L=65,536+c·(source+imports) is rejected: w_k could pay for twice its predecessor's expanded table
from that table's import credit forever. Reading an imported label is baseline; minting a product of call contexts and imported labels
is growth. A singleton result label or a label selected by an explicit written caller path may use that
call/path atom's direct-obligation lane below; unselected multi-label summary export cannot. A callee's own
source credit never pays for its caller's expansion.

S_f counts the declaration's written BIR records and sidecar words (operands, fields, arms, explicit paths and
capture/schema edges), plus each distinct canonical imported **semantic record/edge** actually consumed once.
**Holder and callee path words:** S_f also counts 3·L(a) words per written demand or written call argument a,
L(a) ≤ 2·|places| the longest canonical path below the place of a's own value (the demanded value, or the
argument) in that place's SCC-folded graph, the count §2.8's anchors use. A holder path longer than L(a) pays
its excess steps as growth. Each word is an original atom
`(written demand or argument, slot, k)`: slot 0 pays step k of a callee's `W` path below the written argument;
slots 1 and 2 pay step k of the path at which the first two holders beyond the direct one hold the demanded cell
(§2.7). Their lanes are direct-demand query lanes. These are multiples of written atoms by the depth of their
own values' types, never inferred contexts and never a module-wide credit. **S_f, and so the baseline, is
therefore source size × type depth, not source size alone.**
It includes nested lexical bodies owned by f once, not their instantiations; mutually recursive originals are
source graphs, not repeatedly credited copies. A table is identified by package/module/declaration and semantic
block identity, not by cache address. Transitive unchanged table references get one read credit per identity;
caller-generated tasks, contexts, expanded paths, newly inferred memberships and tables never increase S_f.
Unchanged serialized contexts/paths already present in an imported semantic table get one read lane, but
recontextualizing or substituting them never does.
Imported work must stream through the original table: a precomputed transitive expansion is not “input”.

**Constructive baseline bound.** Cell/condition/index sets use persistent binary
radix trees on **canonical u32 semantic ranks**, at most 32 decisions plus a leaf. Dense columns need no tree.
This bounds one-key path copying independently of declaration length; it does not make general union cheap.
For each source/import atom reserve named lanes, each used once:

| Lane | Permitted source-sized work (no invocation/version Cartesian product) |
|---|---|
| direct data/seeds | ≤32 constant-size records: original typed place/IR edge, local allocation or direct callback label, initial shape/capture/condition reference, direct use, call view and task seed; wide runs supply their own written edge atoms |
| cell/provenance index | one insertion for this atom's directly named origin; imported origin read unchanged |
| shape/override index | one direct child/override edge; return/graft of an unchanged imported graph is a reference |
| condition index | one directly written construction/atom membership, no flatten of every older condition |
| reach index | one one-key extension caused by this source edge; bulk union requires per-member source evidence or growth |
| liveness index | one source-use record, indexed at its own path; no ancestor copies |
| holder index | one directly written binding/operand/capture registration reference |
| escape/use index | one direct source escape/use flag; deep traversal gets an atom only for the first visit to the corresponding original graph edge |
| codec/import index | one unchanged semantic record/edge read, numbered or written; no substitution or expanded copy |

Each of the eight index lanes has **≤512** records: ≤33 copied tree nodes, ≤66 child-parent links, ≤33 descent
continuations, ≤132 first activation/expiry edge continuations, and ≤32 root/event/memo records =296.
The baseline one-key kernel permits at most four result/notification links per copied trie node (≤132),
so the total is ≤428<512. Additional watchers/fanout are growth tasks, never hidden lane work. First activation and expiry are attached
to the created node/edge, not a new credit per holder root. Later activation or inspection of it is growth.
An unchanged subtree's root hand-over does not deactivate it (§2.8). Iterating all members of a set, traversing
an ancestor path composed through aliases, repeated transfer versions, or creating a watcher with
new inferred dependencies cannot fit into a one-key lane. The routine lanes below cover initial/final source
walks, direct queries/calls and entry deltas; work outside those proved kernels uses growth tasks. The additional routine lanes below are separate roles; none renews this one-key allowance. An implementation
may split a lane into smaller records but cannot silently change its 512 bound or invent another role.

**Routine passes and queries.** The one-key lanes above are not the entire source allowance.
The following disjoint lanes cover routine work. A
lane is indexed by an original written/imported atom and a fixed role/phase, never by a discovered context,
iteration number, declaration spelling or “first task to arrive”. Original local-function bodies belong to
their enclosing owner once; executing an inferred copy is not a new original body.

| Additional lane | Bounded kernel and eligibility |
|---|---|
| final source validation | One final walk per original body/atom after settling, including recursive groups and local functions. It has its own copy of the 32 direct + eight 512-record lanes. It reads immutable solved facts; existing proof results are references. It does not renew inference lanes or flatten inferred graphs. Validation of growth records reserves its continuation in G_f when those records are created. |
| direct demand query | ≤512 records per written demand/explicit path-step atom: one path-rank lookup, one range query whose candidates are compatible by construction (§2.7), one direct holder/root candidate, and the chain-head reads of the prefix's cycle anchors (§2.8). The merge-sort index decomposes a range into at most 64 nodes; each reserved inspection does one ≤32-comparison binary search by point and one ≤64-step search of the node's `rank₂` max tree (up, then down) (O(log² U) fixed-word work for the query). At most 64 inspection records, one candidate, 64 cursor/link records and 32 root/event records give ≤161 records; the rank lookup is ≤32 one-word comparisons in one record, and a prefix has at most two anchor chain heads, leaving room inside 512 for the fixed query result/notification links. This is a distinct kernel from the 428-record one-key update; do not compose both under one lane. Original region preorder/parent/arm data is source input; precompute 32 binary-lifting ancestor slots and `base₂` per region (u32 values), charging them to its source settlement lane (428+33≤461<512). LCA/first-differing-arm queries take at most 64 fixed-word steps, independent of nesting depth; additional non-tree guard obligations are general proof tasks. A chain of written path steps has one atom per step. Enumerating multiple holders, composed paths or matching a demand against inferred alternatives is not this kernel. |
| call view and direct obligation | ≤512 per written call/argument/explicit path atom: template+actual-root references, constant-width substitution environment link, and one selected direct label/`W`/use/κ/xreq obligation per original call, argument or explicit-path atom (never per inferred obligation). A singleton callback-result template can instantiate its one label at each written call; multiple unselected labels cannot use that singleton case. A direct obligation is a terminal test or one fixed-width decomposition step, never a recursive/compound κ or xreq descent. Descending a group/graph requires corresponding original path atoms or pre-reserved growth tasks; calling it “one obligation” gives no exemption. Share original callee condition/use graphs; do not eagerly copy their paths at every call. **All** obligations still must be discharged before acceptance: an M-obligation summary at N distinct actual substitutions can require NM checks. Neither “callsite” nor “import” creates NM baseline atoms. |
| static transfer settlement | ≤512 per original transfer/dependency atom: initial equation, one final resolved evaluation and its bounded notification links. Build the dependency graph once; on fact changes schedule affected transfer nodes, not a full body replay. Further versions and `(edge,fact)` products require G_f. The initial and final source scans therefore cost O(S_f), regardless of body length or recursive/local status. |
| entry identity/delta | ≤512 per original/imported model-field or written override atom: unchanged fields are shared identity equations; gather changed fields once and retain one root/substitution per arm. A same-field identity-or-fresh update joins its origin set once, forwarding the shared root, not all memberships to every arm. No model-width×arm materialisation. General cross-field feedback, many alternatives or repeated obligation comparisons are not this kernel. |

Except for the direct-demand range-query kernel just bounded, each additional 512-record kernel has the fixed-word bound: at most 33 visited/copied index nodes,
66 links, 33 cursor records, 132 activation/expiry continuations, 32 root/event/memo records and 132
result/notification links, ≤428 for the **entire** admitted kernel, not 428 per lookup composed inside it.
The range-query bound is for one contiguous range and one candidate. Compatibility never splits the range (the
`rank₂` threshold is applied inside the descent), so case nesting adds no work. A `call` candidate the kind filter
rejects, the cells a cycle anchor's chain holds and inferred-holder alternatives are separately reserved tasks.
A query compares ranks, never path steps. `useAfter` reads the demand's path once and runs one charged range query
per prefix with fixed-key navigation: prefix q_i on step s_i's lane, one rank lookup and one descent. No step is
reread, and no prefix×interval product exists. A demand whose path continues below its written steps (a callee's
`W` at q) runs each step below them on its own direct-demand lane, the call argument's *holder and callee path
word* for that step (S_f, above); no range query runs on the call-view lane.
The at-most-64-step ancestry query is an iterative fixed-word primitive with no per-step allocation;
its ≤32 precomputed slots belong to the separate original-region atom. Region preprocessing, original arm/field runs and written actual arguments
have their own original atoms; they cannot be hidden variable-size payloads in a call/query lane.
The total source bound is now
`B_f ≤ [2·(32+8·512) + 4·512] S_f = 10,304 S_f < 16,384 S_f`.
The initial walk is the original lane set; the final validation is its sole second copy. The four other
lanes never buy another frame walk. This is a constructive bound for the specified kernels, **not** a theorem
that arbitrary holder queries, callee discharges or entry propagation are source-linear.

**Lane identity and reservation.** Every lane key is `(owning declaration, original atom, role, phase)`.
An atom is a stable original use occurrence/region/path-step or imported semantic edge, not a sorted-array index,
an operand instruction or a frame-local counter. Nested frames share their owner's namespace; inference and final validation have
distinct real phases. Liveness construction charges the ≤33 index entries per use to that use's lane, the rank and
interval of a canonical path node at depth k to written step k of the earliest use occurrence whose path passes
through it (role *path rank*), and a region's ancestor slots and `base₂` to the original
region's settlement lane. A path's steps each use their own atoms.
No declaration, nested function or later slice renews or aliases a lane accidentally.

**Runtime enforcement of the kernel bound.** Each lane has a dense provenance slot and checked record count.
Reserve before its fixed-size operation; the 513th record in a 512 lane (or 33rd direct-data record) is an
`ownership_accounting_invariant` compiler-defect diagnostic, naming owner, role and phase, and stops that
owner without a clean block. It is not `ownership_limit`, cannot be repaired by a raise, and fails the
implementation gates. Never spill a purported bounded kernel into G_f based on its counter, silently drop
work or renew the lane. Structurally general operations choose their growth task **before** starting, by the
rules in this table. This check validates the implementation of the proof; it is not another program limit.

**Name-independent allocation of credit.** Baseline eligibility is attached to the original syntax/port edge
and fixed semantic role before interning, worklist ordering or memo lookup. There is no shared pool, first
visitor winner, first-activation credit stolen from another atom, or recycled lane. Alpha-renaming bijects
these slots and leaves their eligibility/count ceilings unchanged; names/ranks may order dictionaries but
never select baseline versus growth. Physical memo interning never chooses accounting provenance: each semantic request/owner has its
preassigned logical ledger entry regardless of who first produced the shared result. A baseline consumer
references it through its lane; a derived-context request reserves its logical growth entry even on a cache
hit. No producer's lane is transferred to another request, and no first producer decides B versus G.
Unchanged source incidence, not an identifier's lexicographic position, defines the split. Test lane maps
under alpha-renaming and declaration permutation, in addition to the existing diagnostic-order tests.

**R-7.4 cases, proved versus qualified.**

| Family | Claim that is actually proved |
|---|---|
| Long recursive function/local group | **Proved for fixed-topology identity/single-bit transfer:** append any number of scalar/direct-construction statements to `go n xs = …; if n==0 then xs else go (n-1) xs`. Initial scan, one settlement per original equation, direct queries and one final validation are baseline O(S_f); length alone spends no G_f. **Qualified in general:** K shape changes affecting N transfer nodes can require Θ(NK) tasks. Incremental scheduling removes gratuitous full re-walks, not this product; it reserves growth. |
| Long update with many record-update arms | **Proved for identity-or-fresh, same-field deltas with direct holder proofs:** each written arm/override is processed once, unchanged model roots are shared, region compatibility is indexed; A arms and W written overrides cost O(A+W) kernels (plus written paths). **Qualified in general:** D demands against H overlapping live holders can require Θ(DH), and N calls each with M callee obligations can require Θ(NM). No claim that arbitrary long update bodies avoid the limit. |
| main with a wide model | **Proved for the preceding identity/delta entry fragment:** F imported fields plus A arms/W overrides give O(F+A+W) equations/root transfers, not F·A; imported records and final validation are baseline. **Qualified in general:** cross-field feedback can make N origins reach N queried fields; distinct substitutions/κ conditions may require Θ(N²) deliveries or comparisons. Root sharing does not prove those obligations in linear time. Such inferred multiplication may exhaust G_f, even in otherwise ordinary safe applications. |

Thus “not a cap on declaration size” means that adding written instances of these kernels never spends
G_f merely for another pass/call/query. It **does not** promise that every long recursive function, every
many-arm update or every wide-model main avoids the limit. This is the remaining general-bound qualification,
recorded in R-7.4; no silent approximation or unproved linear claim closes it. The linear kernels are mandatory
implementation obligations, not recognition by the example function names.

**Ordinary-length theorem (qualified by the three cases above).** Any declaration formed from arbitrary repetitions of these direct construction,
scalar/control-flow, alias/graft and one-key update kernels, including the routine pass/query/call/entry kernels above, but without extra context/products,
has G_f=0 and B_f≤c S_f. Its length alone cannot exhaust `ownership_summary_size`; nor can merely reading its
callees' unchanged tables. General safe programs can still require growth (for example many queries over one
shared wide value); “ordinary” is this constructive source-linear fragment, not a claim of semantic completeness.
The four review witnesses are in the fragment for ownership: Inline/Main.view (:287) is written markup/scalar
reads; PairLookupTable.cell (:15) is scalar branches; LetChain.view (:19) is scalar bindings/markup; CapS.update
(:20) writes one literal of crossing integers. Scalar subtrees produce no descendant object sets. Their direct
tracked containers/field edits and written children have source lanes. Their sizes are not grounds for a refusal.
`main` pays only baseline reads for update/view tables and source call-view roots; genuinely multiplied entry
contexts/queries are growth. A callee's raised R never propagates as a required caller attribute just to import it.

**Whole-module bound with this trigger.** Keep the retained-operation proof above with N_f=B_f+G_f. It gives
O(E + Σ_f (c S_f+R_f) log(c S_f+R_f+2)) time and O(E + Σ_f (c S_f+R_f)) storage for general analysis; the
radix-only source kernel takes O(E+Σ S_f) fixed-word work; source seeds that use
comparison-tree composite dictionaries instead cost O((E+Σ S_f) log(N_max+2)), where N_max=max_f N_f.
The storage bound B_f≤c S_f holds in both cases; the logarithmic dictionary traversal allocates no
unaccounted continuation records (an iterative fixed-key lookup). Sum S_f honestly counts import reads per owner,
not just the bytes in the module. This is not an unrestricted source-linear theorem. Wrapper label products and
closure-context copies outside direct-obligation lanes remain growth even when their originals were imported, so exponential families still
hit G_f=R_f before their next expansion. No blanket exemption applies to “first per instruction”: a single
instruction can request arbitrarily many growth contexts or set inspections. Source/init lane changes version
the policy and its proof. The headroom gate measures **G_f/R_f**, while reporting B_f, S_f and N_f separately.

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
  before 65,537 **labels** because composite labels are not the only growth records. The fixed-type closure tower in
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
Imported immutable storage may be physically shared; each owner registers every referenced semantic record
once in its baseline import lane; derived contexts/tasks use growth. The inference account lasts through final validation and encoding; a group arena is then released.
Blocks encode only semantic graphs, bounded by the same account; they never contain recursively embedded copies.

### 4.4 Resource limits

**`ownership_summary_size` [O 2026-10-25]: 65,536 growth records per owning declaration by default.**
§4.1 defines G_f and the nonfungible source/import lanes: length alone never spends this allowance. Every
record still has an owner and is counted in N_f=B_f+G_f for memory/cost reporting. Composite callback labels, instantiated classes/environments, multiplied contexts/paths, set work and
retained operation records reserve G_f before work unless they match an explicit bounded lane in §4.1;
ordinary singleton call instantiation and final source validation have their own nonrenewable lanes. Nested lambdas, local functions and entry analysis share their
enclosing top-level declaration's counter; parameterless values are owners too. An unchanged imported semantic
table is read through its baseline lanes once. New substitutions and contexts derived from it are growth;
callee raises do not require caller raises merely to import those tables.

Reserve before work: at G_f=R_f, the next growth record fails before allocation, child enumeration,
substitution, set inspection or propagation. Preflight bounded runs by checked arithmetic, otherwise stream
charged chunks/tasks. The owning declaration stops immediately, retains an exhaustion marker and publishes no
class or clean lowering channel. Other work follows the deterministic failure policy of §6; the process is
not killed according to which worker happened to fail first. No round, alias-depth or separate fuel limit exists.
Recursive folds are semantic rules, never a way to squeeze ordinary contexts under R_f. Baseline credit cannot
be moved to a different lane, imported as spending credit, or refunded to finance later growth.

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

raises that declaration's **growth** allowance R_f and applies to all its nested classes. A parameterless top-level value may
also carry it, since it owns a summary. It is not allowed on expressions, lambdas, local definitions, types,
fields or imported declarations; use the owning function's attribute. Comments may separate attribute and
declaration, another attribute/declaration may not. One attribute per owner. The argument is a decimal integer
literal, no expression/sign/separator, at least the inherited allowance; a function override may not lower the
module default. Parse with checked arithmetic, maximum 2³²−2 (u32 ids reserve `.none`; total table index overflow remains the named input/format resource error). Invalid placement,
duplicates, a smaller value or overflow is `invalid_ownership_summary_size` at the attribute. Formatting keeps
it on its own line with the spelling above. Available to user, core and platform packages; never erased from
analysis inputs/cache keys. It changes no runtime code, types or ownership proof rules. Increasing it permits
more analysis, never permits a write without proof. S2b adds parser/lowering/formatter/diagnostic and corpus
coverage, `language.md` and **`skills/beni/` in that implementation PR** (CLAUDE.md rule 7 and skill policy).

**Evidence and instrumentation.** The measurement scanned 11,346 .beni files (3,578 repository files and 7,768
generated apps); the largest structurally resolved callback-label count was **10**, `o/LimitOwnedAtoms.beni:45`
(`hand9`), versus 65,536. That is not a measurement of baseline/growth records or proof about unresolved calls.
S3a records each category, baseline B_f, growth G_f, input S_f, total N_f and effective R_f and largest owners for corpus/examples/core/
platforms and generator-deduplicated research apps. Repeat as S4 adds classes/callbacks and S7 entry analysis.
Report to the owner if G_f reaches one tenth of its default growth allowance; do not silently raise defaults, add
attributes to core, or coarsen. `own_limits_test` checks the measured headroom. A new memo design changing the
unit or deleting retained work records requires a new bound and policy version, not a silent budget refund.

Existing huge **input/format** limits remain; these are not extra inference budgets. Each has its own named
`ownership_limit` and measured value, checked before allocation. They are not changed by the raise attribute.

| Limit | Value | Bounds |
|---|---|---|
| `record_fields`, `tuple_arity`, `constructor_args` | 65,536 each | written fields/components/arguments, dense source/type runs |
| `type_places` | 2²⁴ | places in one module's source-derived table |
| `path_steps` | 65,536 | canonical path length, in addition to charged derived path records |
| `ctor_steps` | 2²⁸ | distinct `(constructor, argument)` steps in one module's place table (a step has a 4-bit kind and a 28-bit pair-table index); reserve/check before interning, named `ctor_steps`; never split 28 bits into small independent constructor/argument caps |
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
L14 Enforce
L13 Ownership
L12 BlockRead
L11 Report  Message  Hoists  Block
L10 Groups  Entry  Refine
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
     bir/Bir, check/{TypeStore,Types,Walk,Dispatch,Edges,SchemaPlan,EffectPlan,Scc}, resolve/{Interface,Graph}, parse/Ast, InternPool, stamped
```

| File | L | Responsibility | Public API | Imports (own2) | Lines |
|---|---|---|---|---|---|
| `Ids.zig` | 0 | every id newtype (`PlaceId`, `PathId`, `CellId`, `SetId`, `NodeId`, `OverId`, `CondId`, `SplitId`, `KappaId`, `ClassId`, `UseId`, `DemandId`, `SummaryAccountId`, `TaskId`); the constant-record account/reservation, named input limits, `Charge` (a lane or growth, chosen before an operation), the kernel a walk is in (`Account.enter`/`leave`), chunks, the fixed-key dictionary and one-shot queue primitives of §4.1 | types, `Account.reserve`, `Account.limit`, `Charge`, `Task.enqueueOnce` | — | ≤ 700 |
| `Place.zig` | 1 | place graphs, steps, canonical paths, holds, opaque slots, structural encoding | `Table`, `of`, `child`, `steps`, `kind`, `holds`, `pathOf`, `encode`, `decode` | Ids | ≤ 1 000 |
| `Cell.zig` | 2 | origins, kinds, class, the trie, interning, persistent sets, splits, `alias`, charged union/query continuations | `Table`, `intern`, `parent`, `children`, `alias`, `Radix.{insert,member,unionWith,subset,intersection}` | Ids, Place | ≤ 900 |
| `Facts.zig` | 2 | the shared records: `Use`, `Demand`, `Obligation`, `Supply`, `Keep`, `Verdict`, `Cause` (R-6.3's order) | the types, `ProofRequest`, `ProofAnswer` | Ids | ≤ 350 |
| `Prepass.zig` | 3 | SCC edges (`check/Edges.zig`'s three legs, derived bodies included), alias chains, read counts, `eq`/`compare` decls, spread chains, `withDefault` shapes | `run(bir, dispatch, graph) → Facts.Prepass` | Ids, Facts | ≤ 600 |
| `Shape.zig` | 3 | nodes and their operations, `reach`, `widen`, coinductive `leq`/`eq` | `Table`, `leaf`, `node`, `delta`, `recast`, `union`, `collect`, `proj`, `cellsAt`, `put`, `join`, `map`, `reach`, `widen`, `leq`, `eq`, `expand` | Ids, Place, Cell | ≤ 1 500 |
| `Regions.zig` | 4 | region tree, points, compatibility (the second order and its `rank₂`, §2.5), guards, virtual `withDefault` arms | `Tree`, `build`, `compatible`, `rank2`, `guard` | Ids, Facts, Prepass | ≤ 450 |
| `Cond.zig` | 4 | per-value immutable κ snapshots, atoms, shallow `apart`/`sep`, `deep` (a walk of a value's observable frontier, §2.9; `excl` at the path of a projected summary arrival), instantiation, rely | `yes/lost/shared`, `and`, the atoms, `Kappas`, `kappaGet`, `kappaSet`, `kappaOf`, `kappaLeq`, `deep`, `sep`, `apart`, `lower`, `propagate`, `instantiate`, `rely`, `flat`, `print` | Ids, Facts, Cell, Shape | ≤ 1 785 |
| `Summary.zig` | 5 | the class record and table, lattice (κ joined through `Cond`), normal form, equality, unknown class, text; each fun's selected write-backs (§2.13.6) | `Class`, `join`, `leq`, `eq`, `normalize`, `unknown`, `print` | Ids, Facts, Place, Cell, Shape, Cond | ≤ 1 500 |
| `Liveness.zig` | 5 | the use index and queries | `Index`, `build`, `useAfter`, `useUnder`, `lastUse` | Ids, Facts, Place, Regions, Shape | ≤ 700 |
| `Rows.zig` | 6 | words → classes; constructor, derived-method, markup and schema classes; entry shapes; `Send` | `fromWords`, `ctorClass`, `derivedClass`, `entryShape`, `schemaRow`, `markupRow` | Ids, Place, Cell, Shape, Cond, Summary | ≤ 1 100 |
| `Calls.zig` | 7 | instantiation, callback edges, keep edges, function values' classes | `apply`, `classesOf`, `callParam`, `keepEdges` | Ids, Facts, Cell, Shape, Cond, Summary, Rows | ≤ 1 500 |
| `Demands.zig` | 6 | the six conditions, live inverted holder index, refinement/cycle-aware trie queries, causes, verdicts | `resolve`, `holders` | Ids, Facts, Cell, Shape, Cond, Liveness, Regions | ≤ 1 200 |
| `Transfer.zig` | 8 | one case per BIR tag; the frame state | `eval`, `Frame` | Ids, Facts, Place, Cell, Shape, Cond, Regions, Rows, Calls | ≤ 1 800 |
| `Fix.zig` | 8 | the two fixpoint shapes, closure dependency cycles, charged delivery/notification tasks and validation | `worklist(Instance)`, `propagate(Edges)` | Ids, Cell, Shape, Cond, Summary | ≤ 900 |
| `Walk.zig` | 9 | one frame: walk, index, resolve, keep edges, read off | `walk(decl) → {Class, []Demand}` | Ids, Transfer, Demands, Fix, Liveness, Calls, Summary, Facts, Regions | ≤ 1 500 |
| `Groups.zig` | 10 | the module: source/signature adapters, pre-pass, order, limits, transfer, summary table | `checkModule`, `ensureClass` | Ids, Place, Rows, Walk, Fix, Prepass, Summary, Facts | ≤ 1 100 |
| `Entry.zig` | 10 | the entry protocol at a constructor call | `check(Obligation.entry)` | Ids, Calls, Fix, Demands, Rows, Cond, Shape | ≤ 900 |
| `Refine.zig` | 10 | exact ranks of variable words and Hopcroft's partition refinement with canonical block numbers (the block's places and positions), with the meter that reserves before work | `rank`, `blocks`, `Graph`, `Meter` | Ids | ≤ 500 |
| `Block.zig` | 11 | class → bytes, the format | `write`, `version`, `Names`, `Remap` | Ids, Summary, Place, Cell, Shape, Cond, Refine | ≤ 1 660 |
| `BlockRead.zig` | 12 | bytes → classes, lazy directory | `read`, `open`, `summary` | Ids, Summary, Place, Cell, Shape, Cond, Block | ≤ 950 |
| `Hoists.zig` | 11 | the lowering channel, format v2 | `Table`, `Builder`, `write`, `read` | Facts | ≤ 500 |
| `Message.zig` | 11 | diagnostic text and JSON fixes (ported from v1 over `Facts.Demand`) | `build`, `limit`, `code` | Facts | ≤ 900 |
| `Report.zig` | 11 | dump lines and totals | `print`, `totals` | Facts, Summary | ≤ 600 |
| `Ownership.zig` | 13 | facade | `Input`, `run`, `ModuleReport` | Groups, Entry, Block, BlockRead, Hoists, Message, Report | ≤ 300 |
| `Enforce.zig` | 14 | the Driver hook, inputs, interface and cache sections (ported) | `checkModule`, `inputs` | Ownership, Block, BlockRead | ≤ 450 |
| `rules_test.zig` | — | the gate below | — | — | — |

**Input adapters.** `Groups` builds `Place.Source` and `Rows.Signature` together, reading
`Decl.annotation`, `ownSlots`, solved types, BIR constructor templates and interface argument terms.
A list-of-functions signature gets callback-list behaviour only under explicit `once`, `many` or
`unused`, preserving v1's rule; a plain/borrowed list is a plain argument. Unknown shapes remain
pessimistic. Derived methods obtain component classes through the passed-down class resolver.
These are input adapters at L10, available from S3a even before group solving lands in S3b.

**Callback proof interface.** `Cond` does not synchronously call `Calls`. When `apart`/`sep` reaches
callback labels needing actual-class interpretation, it emits a `Facts.ProofRequest{owner, labels,
actual_template, path, immutable_input_versions}` and returns `waiting(RequestId)`. `Calls` consumes those
records, instantiates selected paths and returns `ProofAnswer` nodes/obligations; the higher-level `Fix`/`Walk`
queue feeds them back to `Cond` for ordinary separation. Requests, answers and notification edges use the
same account and one-shot scheduling; a cycle is waiting, never proof. `Cond` knows only Facts' lower-layer
ids/records, not class internals or a `Calls` import. `Demands` and `Walk` explicitly import `Regions` for
compatibility/continuation points. Passed-down interface contexts are ephemeral, never pointers in an IR.

There are **26 production files plus `rules_test.zig`, on 15 layers (L0–L14)**.
Targets count production lines before `const testing`, excluding tests; the implemented foundation/S2
interfaces fix the imports here, including Summary→Facts and Liveness→Place. Tests may import helpers
under the gate's test rules.
Every edge in the *Imports* column points to a strictly lower layer (checked by hand against the layer numbers
above, and by the gate). **The layering gate** (`own2/rules_test.zig`, in `zig build test`): reads every file's
`@import` lines against this table (an import of a same-layer or higher file, or of anything in `src/own/`,
fails naming both files); size targets; fences — `Transfer`/`Calls`/`Demands`/`Rows` compare no name to a string
literal (every `std.mem.eql` against a literal is allowlisted with a reason), only `Cell.alias` compares cells,
only the `Groups` source/signature adapters read solved type children/constructor templates; `Place` consumes their pure graph interface, `Facts.Cause` is in R-6.3's order, every `switch` over `Cell.Origin`,
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
| grouping (R-6.10), limits (R-6.11) | one diagnostic per (position, verdict, cause, detail); one `ownership_limit` per failed owner/limit selected by the deterministic failure policy below; no secondary refusals; independent completed diagnostics remain |
| JSON (R-6.6) | the same text plus each code fix as a machine-applicable edit (span, replacement) |

**Accounting invariant failure.** `ownership_accounting_invariant` reports an implementation defect in a
proved source kernel, with owner/role/phase/count (§4.1). Check it in every build before excess work; use the
same deterministic dependent-blocking policy as an exhausted owner. No raise/copy fix and no ownership verdict.

**Summary-size exhaustion.** Code `ownership_limit`, title **OWNERSHIP CHECK TOO LARGE**, span the owning
function/declaration name (a lambda is reported through that owner). Example at the default allowance:

> Ownership summary for `w16` needs more than 65,536 growth records (`ownership_summary_size`). The next growth record
> would make 65,537; source-sized records are reported separately and do not spend this allowance. Put repeated results in a list, make the wrapper chain recursive, or replace a closure
> tower with data and one fold. You can raise the limit with `@ownership_summary_size(131072)` on `w16`, or
> `@ownership_summary_size(module, 131072)` in this module's preamble.
>
> This is a limit of the checker, not proof of sharing.

Print the effective allowance (and its attribute location when raised), attempted count and category of the
failed reservation. Stop this owner immediately; apply the deterministic failed-dependency policy below, with no dependent ownership noise or clean output. This fix
is a restructure/raise suggestion, not `List.copy`: copying does not in general reduce summary size. Ordinary
aliasing refusals keep their copy fix. An attribute larger than the representable maximum is diagnosed by
`invalid_ownership_summary_size`; never suggest an overflowing doubled value. JSON may insert a validated
raise attribute, but must not pretend to rewrite a closure tower automatically. The invalid-attribute code
and both placements enter `language.md`'s diagnostic catalogue and `skills/beni/` when S2b lands.

**Deterministic failure policy (R-6.11).** An owner aborts immediately on its failed reservation, as a terminal
`exhausted`, never an unknown class. Process each recursive dependency component's owners/tasks in §3.8's
canonical order; the first failing owner terminates that component. Its other members and all dependent
owners/modules become `blocked-by-limit`, with no ownership verdict or downstream pending/refusal lines.
Independent components finish, even on another worker; collect their diagnostics and root limit diagnostics
in canonical module/declaration/source order. No process-global “first worker failure” shortcut. Already
completed independent exact/pending diagnostics remain; unfinished dependent ones do not. A module with an
exhausted/blocked owner publishes no clean block or lowering channel and the build emits no code. This single
policy is what “stops compilation” means throughout: stop the affected proof immediately, finish independent
reporting deterministically, return failure. The report may name blockers but never manufactures refusals.

Reported modules are the application modules this run checked (R-6.4). `check` fails with the ownership codes alone
exactly when the report has a refused, pending or limit line (R-8.1). Under `--release --allow-debug` the diagnostics
are identical and nothing is written (R-7.11).

---

## 7. Verification

1. **Corpus and pending fixtures** (R-8.1, R-8.2). `tests/corpus/ownership/`, every `build/bad/` and `check/bad/`
   fixture with a §6 code, `run/` and `browser/` unchanged; goldens compared on verdict and count lines (R-7.15).
   `tests/pending/ownership/` — 45 fixture roots (47 .beni source files, including project support files) at f309230 (CK-262 to CK-311) — is v2's acceptance; Appendix B
   maps each to its slice; each moves to the corpus as it turns green.
2. **Whole-corpus verdict diff against frozen v1** (R-8.3). `bench/ownership-everywhere.mjs --diff=<v1>,<v2>`
   dumps every audit root (`bench/ownership-roots.mjs`) under both hidden ownership selections. Compare per
   `(root,module,position,operation,base,repetition ordinal)` and print **four lists**: same, v2 accepts where
   v1 refused, v2 refuses where v1 accepted, and one-sided demands. A failed root or any nonempty difference
   list exits nonzero; every difference needs a requirement or a pinned v1-defect explanation before switch-over.
   The reference v1/v1 measurement at `e5421ac3d` is 1,621 roots, 10,937 equal demands, zero differences;
   enumerate roots on every run rather than freezing that count as coverage.

   **The gates carry the same net** (#1103), so it never depends on someone running the bench. The corpus
   harness compares v2's demands with v1's for every `ownership/` fixture (against its v1 golden), every
   `run/` program, every `browser/` page and core, under the same rule, from one `dump --ownership-both`
   per program. Justified differences are `tests/blackbox/ownership-v2-known.txt`, keyed by root, module,
   position, occurrence (`#k`, alike demands at one position counted from 0), demand text and **both
   verdicts** (`absent` for a one-sided demand), so an entry excuses that one difference and nothing else;
   an entry no case of a whole walk uses is stale and fails. A difference inside a declaration v2 does not
   check is excused only because the declaration is listed: each fixture, program and page commits a
   `.v2.unchecked` golden naming every such declaration with its reason and construct (`not built: call`),
   and core's is `tests/corpus/ownership/core.v2.unchecked`, so marking a construct not built, or building
   one, changes a golden and fails the gate, and the parity can never pass vacuously. A v2 limit (§4.4) is a
   failure, not an exemption, except in a fixture with a `.v2` golden of its own, whose limits that golden
   pins.
3. **The stale-read sanitiser, the arbiter** (R-8.5). A sanitised accepted write runs on a copy and poisons
   the old storage: a subsequent read through a stale holder traps. Hoisted reads precede the write.
   `--sanitize-records` traps reads of written old fields; its copy result must remain assigned even when
   the inline backend normally discards an in-place update result. Disable that write-set elimination under
   the sanitiser. `--records-in-place` enforces clean-module records on any platform chain; until O4a it
   also enforces lists. A build without these hidden flags retains its ordinary output.

   `--sanitize-lists` is build-only, development-only and requires enforcement (otherwise exit 2).
   In clean application modules wrap accepted `set`, `update`, `push`, `pop`, `swap`, `insertAt`,
   `removeAt`, `append`, constructions and list `++`, including dot calls, let aliases and writers supplied
   as callback values. Operands and callbacks evaluate before copy/poison in the original order. A spread
   or `++` chain has one demand on its first operand, so wrap it once, not every nested lowering call.
   Under runtime safety every in-place store must name an accepted demand of a clean module (R-8.9).
   A branch's accepted write/consuming call remains under that branch; hoisting it into an eager arm is
   a backend soundness defect (#1028, fixed by #1033), not an ownership refusal to suppress.

   For `.sanitize-lists` fixtures and `test-lists-in-place`, `checkSanitisedSites` compares accepted dump
   sites with wrapped sites by module, position and writer, **as sets** (lowering can emit a site twice).
   Element-supply lines such as `rows[*].1` are checked at the callback's actual writer site. A missing or
   extra wrapper fails; a module not emitted is not compared. `test-records-in-place` and its list twin run
   every `run/` program and `browser/inline/` page; normal gates include the marked fixtures. The intended
   S8b/S9 coverage is §8.2. A trap on an accepted program is a soundness defect regardless of any oracle.

   **Specified limits of this instrument:**

   - A plain array's `length` is non-configurable: it retains its old number. Indexed reads/methods trap,
     but a stale length-only read does not. Do not claim complete stale-read detection from a green run.
   - Persistent `Dict` writes have no v1 demand to justify poisoning. Add Dict storage poisoning with
     #961 at S8; until then it is outside this instrument's coverage.
   - v1's clean table covers application modules, not core/platform bodies. Writers escaping sight inside
     a record/list/constructor are not wrapped by the alias/callback-value mechanism; any accepted site
     they expose is still subject to the coverage check. Identity-skipping browser/browser-tea/test
     runtimes (#966) are outside the node/browser-inline sanitiser runs. S9 requires clean v2 core/platform
     facts and reports remaining coverage exclusions explicitly.
   - A trapped branch write (#1028) is a regression fixture, not a permanent excluded page: the backend
     must preserve guards (#1033). Sanitiser passes may not skip a page or weaken its hang guard to pass.
   - During the trie transition, copy/poison is O(1) in list length: poison the header/head/tail/plain
     copy/tree/root, excluding the shared empty tree, and leave internal path-copied nodes untouched.
     `List.drop` copies its first leaf into a new head, so a stale holder reading only that copied leaf
     is not caught (#1035). S8b's array/view representation must remove this coverage gap and add the
     corresponding trapping twin. A whole-trie recursive poison is forbidden: it makes long push loops
     quadratic. The existing hidden-holder/trie-holder fixtures must trap on covered storage.
4. **Differential fuzzing.** The Lean bridge's generator (`proofs/ownership/BRIDGE.md`, recorded seeds) extended to
   records, `Dict`, patterns and callbacks: each program checked by v1 and v2, run under the sanitiser where both
   accept, judged by Lean where modelled; v2 accepts ∧ sanitiser traps is a stop. `zig build fuzz` grows an `own`
   sweep (S9); not a gate.
5. **Debug cross-checks** (R-8.8), permanent but explicitly **excluded from the normal gates binary**:
   `-Downership-full-cross-check` enables enumerated `Shape.expand`/projection, pairwise `join`/`union` and
   `apart`/`sep`, explicit `delta`, liveness versus a full scan, `rank₂` compatibility against the
   binary-lifting ancestry query for every pair of points of a frame (§2.5), Lean-model refinement alias checks,
   widening checks and block round-trips. Run this dedicated build in S9 and targeted development tests under the
   existing hang guards. `std.debug.runtime_safety` alone enables only constant-work-per-record invariants
   already counted by §4.1; ReleaseSafe gates must not run the quadratic/exponential oracle paths. The
   explicit oracle build is outside the production cost claim and compares ordinary verdicts without making
   its enumeration part of a production resource count. No oracle sampling cap changes an analysis answer.
6. **Cost gates** (R-7.1, R-7.2) in `test-perf`: `WideModelArms` N = 64/256 (≤ ×5), the rotate `update` at N =
   64/256 (≤ ×5 in *time*; its facts are Θ(N²) but shared), `DeepTupleDag` to depth 32, `ListOfParams` n = 300,
   `MutualCycles`, routed-app N = 128/256 (≤ ×2.2), Conduit and Bike Wars `check` on vs off (≤ +10 %), the
   100k-line throughput, a one-body warm edit (< 15 ms). A miss is reported (rule 10).
   Add `CallbackWrapperDag` at depths 8/16/24, `WideCallbackResult` with independent N/M=16/64/256/512
   (record and tuple results, fresh and supplied/captured variants), `CallbackUnionComposition` N/M=16/64/256,
   and `ClosureTower` (Appendix B) at depths 8/16/24. Smaller cases retain their exact semantic answers;
   generated cases exceeding the growth allowance **must** fail with `ownership_limit`. The explicit `w0..wk`
   labels and closure tower are forced by summary export even when no caller selects a leaf; no uncharged
   expansion before the check. Use N=512/M=512 nonfresh demanded descendants for the wide-product
   guard test, keeping each written record below `record_fields`. That fixture must actually force the product; a fresh-only shortcut is tested separately.
   A direct N-field `h` with scalar/fresh leaves stays baseline at arbitrary written width; only N×M
   nonfresh demanded expansion consumes growth. Repeat the four large declarations in §4.1 and a `main`
   that reads their unchanged tables; require ordinary verdicts and no growth spent on input length.
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

**The v1 freeze is absolute:** no slice edits `src/own/`; compatibility lives in v2/frontend input columns.

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
| S0 | **The arbiter** | the list sanitiser beside the record one (§7.3), `test-records-in-place` and its list twin, `--records-in-place`, `--diff` in `bench/ownership-everywhere.mjs`, v1 behind `--ownership=v1\|v2` | the sanitiser runs `run/` and `browser/` clean under v1 on `node` and `browser-inline`; the diff prints same, v2-only accepts, v2-only refuses and one-sided demands | — | S1, S2 | 7 |
| S1 | **L0–L4 foundations** | `Ids`, `Place`, `Cell` (trie, persistent sets, splits, `alias`), `Facts`, `Prepass`, `Shape` (`union`, `widen`, coinductive `leq`), `Regions`; `rules_test` (layering, sizes, fences, dense-id); the §7.5 cross-checks for these; **Accounting from the first allocation:** `Ids.Account`, fixed-size chunks, retained operation/dependency records, deterministic fixed-key dictionaries, failed-reservation path, explicit stacks; sets/holders never run uncharged loops; checked owner-original-atom/role/phase lane counters, internal-error overrun path, no spill to growth. | `zig build test` green; unit tests: `w5`'s DAG at 17 nodes, a cyclic type one place, `widen` on `go`'s shape, a chain of k deltas O(k log), `alias` on refinements returning a split | — | S0 | 10 |
| S2 | **Conditions and summaries** | `Cond` (per-value immutable κ snapshots (NodeId, position class) → CondId that travel with their value's shape root, `deep`, position-level `apart`, cell use marks, derived multi-arrival/union conditions, the `positions` kind and its κ rule, a multiset `apart` (§2.3, §2.9)), `Summary` (classes table, functional join, pair simulation, local normalisation, print), `Liveness` (by path; one charged range query per prefix with fixed-key rank navigation and no path reread; per-written-demand query lanes; §2.5's `rank₂` threshold inside the range descent; fixed-word region ancestry for pairs; lazy callee use-node), `Rows.fromWords` for today's words, derived-method and constructor classes (all new type/value words are taught to `fromWords` in S2b, which S3a's `List.push` needs through `written`); Recursive class/environment schema, stable inference keys, idempotent κ sets and the same account through class normalisation. | unit tests; `Summary.print` reproduces v1's `summary` grammar; `ListOfParams`' condition O(n); the use index answers the four queries of §2.7 | S1 | S0 | 8 |
| S2b | **Words, the spread fact, core in-process** | Frontend type/value ownership columns, placement/companion validation, Builder/List/Ref/Deferred words implemented by #1057–#1059; type `sender` metadata without an alias-use port column; `Bir.Spread` and verification (single-spread identity has no fact); package-qualified body-pin gate, taken readers/forwarders and codegen pins; Appendix C construction/instantiation tests with read-off supplied explicitly; minimal `Block`/`BlockRead`/`Refine` with observable κ positions and shared owners (§3.6), no disk directory; `@ownership_summary_size` grammar/formatting/BIR and skills. Log/Task/Js/Dict wording belongs to S8 (#1053); missing result selectors/write-back belong to S3a (#1052). Hook publication, type-kind errors, behavioural raise test and real-owner instrumentation are S3a (#1056); structural place re-interning is S6 (#1055). | gates under unchanged v1; column isolation and frontend/cache version bumps; every #1060 round-trip test compares observable κ, shared-owner and cyclic/build-order twins; the derivation tests do not claim walker inference; BIR raise fixture only | S2 | — | 18 |
| S3a | **Lists in one declaration** | the `Place.Source` adapter from the checker's tables (§2.1: constructor templates over argument places, memoised on `(head, argument places)`; built at the `Enforce`/`Groups` boundary), `Transfer` (literals, spread chains, patterns, updates excluded, calls of worded rows only), `Demands`, `Walk` without groups, `Report`, `Message`, the facade and the ported `Enforce` hook under `--ownership=v2` (so core's worded classes reach a module through S2b's block); the `Decl → Rows.Signature` adapter beside Place.Source (annotation, ownSlots and solved types; list-of-functions only under `once`/`many`/`unused`, never an unworded/borrowed list); constructor-component eq/compare classes; the live holder index in `Demands`, with §2.8's cycle-anchor chains for every demand, shallow or deep (*Holders across a cycle*), and the holder half of the cross-path twin `[ (a, b), (b, a) ]` (§2.9); deep demands over `Cond.deep`; per-value κ roots in the frame (`value → KappaId`) keyed `(NodeId, PathId)` (§2.9, §3.4); `Transfer` builds a literal's and a spread's `[*]` with `collect` (§2.3); the layering gate brought to §5: `rules_test.zig` lets the `Groups` source/signature adapters read the type modules (today only `Place` may) and raises `Groups`' size target from 900 to 1 100 lines; a declaration whose body uses a construct not yet built gets the pessimistic class behind the hidden flag, never a refusal, until S5  Complete #1052: `elementof`/`copyof`/`prepended` and stored-callback selectors through frontend/Rows/format/skills; exact selected write-back effects, executed by S4/S8. Fix #1054 before ordinary store-chain acceptance. Pre-work codec reservations (#1066) are repaired. Complete #1056: resolved type-kind diagnostics, minimal-block hook, cold/warm worded-core parity, behavioural OwnershipSummarySizeRaised, and source/use atoms unique per owner in release as well as safety builds. Measure B_f/G_f/S_f/N_f and category highs on corpus and generator-deduplicated research apps; unsupported is never zero; report G_f ≥10% of default. | whole fixtures of one declaration at a time, with no callback, closure or record demand (records only as literal containers): LaterRead, StoredTwice (once #1052's `copyof` words `List.copy`), Spreads, SelfSpreads, ViewAliases (each calls only `push`, `set`, `copy`, `length`, checked by grep); `p/DeepTupleDag`; RoseAlias, MaybeTreeAlias, MutualAlias (Appendix B). Inside fixtures S3b finishes, S3a already pins the single-declaration lines: Split's `bumpHead` and `readAfter` (the latter accepted, R-4.3.5), Nest's `pushInner` and `local`, PathCut's `writeRead`, ParamHole's `hole`, DeeperLevel's `inner`. Fixtures with a callback, closure, builder or record line stay red until S4/S5 (Accumulator, Disjoint, Prepend, PrependFresh, Toplevel, Binders' `Maybe.andThen`, OneListTwoLevels' `concat`) | S2b | — | 12 |
| S3b | **Declarations call each other** | `Calls` for summarised declarations (W/E/A, `res`, κ instantiation, `xreq`), a call's view by reference (§4.1's *call view and direct obligation*: template plus actual-root references and a constant-width substitution, never a copy of the callee's class over the arguments, #1097), Shape.map's correspondence hook transporting κ snapshots with graph relabelling and the substitution context in a κ root's key, relabelling nodes only (snapshot paths stay relative to the value's root, the argument's snapshot linked at the graft) and preserving the `positions` kind (§2.3, §2.9, §3.4), `Groups` with the worklist `Fix` **and `Fix.propagate`** (cells and bits along a group's edges), levels, initialization transfer, `eq`/`compare`'s `writes`; Build transfer equations once; charged dynamic dependencies reschedule only affected transfers, never a full frame replay. Separate initial/final source phases and direct-call lanes, singleton result-label instantiation, growth for cross-products; validation of inferred records pre-reserved. R-7.4 qualified-family scaling fixtures.  Observable-position κ propagation and simulation (#1063/#1064); context-scoped, explicit-stack Shape.map correspondence including grafts and projections; full effect preservation and exact join keys (§2.11). Read-off keeps each recorded pair of distinct pre-fold `sep` labels through direct calls of summarised declarations, for S4's `within`; calls of a function parameter, and with them Appendix C.2–C.5's walker derivation, are S4's. | a straight-line chain of pushes and `ValueCellsGuards.rebuilt` both have G_f flat at the per-instruction cost, and the wide graft never spends growth (#1097); Split, Nest, PathCut, ParamHole, DeeperLevel, MarkerAcross (their calls of summarised declarations of the module; MarkerAcross's `incAll` a recursive group; moved from S3a, whose lines of one declaration they keep), RoseKidsHeld (Appendix B; defined by such a call); ReturnsFresh, ReturnsArg, CallerSide, MutualTypes, MutualCycles, LevelLimit, LevelPlaces* (LevelPlacesKinds' 64:5 stays refused: where `viaKid` folds `twoR`'s two `W` paths into one, the fold creates the reliance v1 records, `xreq excl π1#Rose.1`), AliasWriter (Recursion's `List.close` waits for S4); `p/MutualListField`, `p/WriteOneLevel`, `p/AliasWriterCall`; the R-5.13.1 fixture; local ordering tests (core-dump #428 waits for S6). RecursiveFunctions, FoldLevels and Initialization* need S4/S7/S8 and stay red  KappaLeafJoin, KappaEmptyProjection, IdentityMapKappa and joins under two shared-owner routes; validation after a new κ constraint arrives; no stale memo after failure. | S3a | — | 15 |
| S4 | **Callbacks, closures, folds** | `callParam`, supply/need/keep edges, shared actual templates and label/supply views (`sep`/`within`/`need`), §7.6's callback cost scenarios, the sparse feedback fixpoint, function values and pending, once tokens across aliases/forwarding, local groups, `withDefault`, carried classes and the supply key's `port` (§3.5); split `single`/`entry` (§2.2 *Traversals*, §3.2, §3.6 *Traversal marks*); §2.10 closure-recursion rule, captures retain original identity, settled facts and independent proof certificates; all 13 carried-recursion definition sites in Appendix B, GrowFresh/GrowAlias, ClosureTower. Repeat baseline/growth instrumentation. Implement request/answer callback proof scheduling and test unresolved cycles. This slice owns the new recursion/identity/alias-token work, not only porting v1.  Replace S2 positional nested-class arrays with the keyed code/port/context graph; selected callback stored effects; exact run/worklist keys; constructor-supported cyclic class/environment codec and traversal marks before any import, with canonical cross-module twins. Read-off creates `within` from distinct pre-fold `sep` labels (§2.11 *Carried-class boundary (S4)*). | Appendix C.2–C.5 (`mapHelp`, `List.map`, `foldlFrom`, `List.foldl`/`foldr`) derived by the walker, not supplied by a test; Callbacks, Need*, CallbackKeeps, ConditionalCallbackKeep, FoldAccumulators, FoldKeepsInner*, Once, Clo*, ClosureCapture, CapturedParam, SlotInLambda, LambdaParamNeed, CarriedLambda, CarriedFold, LocalGroups, PolyRec*, MergeCallbackCycle, MaybeDefault, ResultDefault, UnknownCallee*, Accumulator's fold, Prepend's `map`, Disjoint's `capture`; `p/CyclicFold`, `p/NeedOuterOnly`, `p/EditAnsweredList`, `p/OnceOtherHolder`, `p/CalledTwicePusher`, `p/JoinedFunctionValue`, `p/PatternStoredBack`, `p/ExclusiveFreshHelper`, `p/UpdateReturnsHeld`, `p/AppliedLambdaRecursion` (R-7.12), RecursiveFunctions, Recursion, Binders, OneListTwoLevels, Accumulator, Disjoint, Prepend, PrependFresh | S3b | — | 22 |
| S5 | **Records** | record cells, `delta`, `update` demands, per-field Dead with `field`/`call` use kinds, hoists and `Hoists` v2 (constructor step), record κ through the kind filter, v2 `--ownership-records-lost` (list verdicts unchanged; record conditions deliberately removed, dump/CLI parity fixtures), `Record.copy`, once closures over records, field captures  Settled-version authorization and hoist placement contract (§2.8), independent record/list mode caches. | every `Record*` fixture, `run/RecordHoistValues`, `run/RecordInPlace*`, the `.in-place` fixtures; `p/RecordSplitPushBack`, `p/RecordWriteBeforeKeep`, `p/RecordKeptInLiteral`, `p/RecordInnerKept`, `p/RecordWrapperRead`, `p/RecordProvenanceCallbackResult`, `p/RecordCopyOpen`, `p/RecordIndexExchange`, `p/ReturnedLambdaWrite`, `p/OnceLaterArgument`, `p/PrependFreshRecord`, Toplevel; R-4.8.7's fixture | S4 | — | 9 |
| S6 | **Modules, blocks, cache, core** | `Block` completed (class tables, lazy directory, versioning), the cache entry section, firewall test, core and platform facts in the checked core, `dump` of embedded core; Backreference graph encoding, no nested class copies; resource policy and allowances in cache metadata; imports charged identically cached or fresh.  Structural re-interning (#1055), global place/position refinement and counted grouping (#1065, built in S2b's writer), exact read-frontier/owner sharing, transactional populated-table decode/remap, same-session vs disk parity and semantic-only firewall hash (§3.6). | CrossModule, ApartAcrossModules, OpaqueSlots, WideCtorBlock, SchemaCtorBlock, SchemaMemberExt, SchemaCtorCached, every `.cached` fixture, `cache_test`; R-7.6 #428 core dumps under jobs=1/8; core/platform block publication and cache parity for supported constructs; full clean-core verdict waits for S9 after S7/S8  unchanged exported reads after internal body/accounting changes do not invalidate clients; different κ does; mixed versions, corrupt labels/effects and repeated lazy imports. | S5 | S7 | 12 |
| S7 | **Entry, sends, markup, schemas, casts** | `Entry` (both protocols, the sparse model fixpoint, the invariant), v2's dual alias-provenance/nominal `Send.to` inputs (§2.13.5), v2-only paired fixtures and cold/warm parity; existing platform API/corpus unchanged, no v1 adapter, markup rows, schema rows, `try`'s early return, `recast`  Resolve sender alias roles before expansion from BIR/interface terms, preserve capability through expanded-type wrappers and cached packages; add a role column only where the existing terms lose it (§2.13.5). Model feedback uses the same observed κ frontier; view/command roots join before any final authorization. Repeat instrumentation. | Entry*, HostedEntry*, WideModel, WideModelArms, SplitArmsJoin, OwnedSend, SendInPayload, NestedLambdaSend, SubOnShared, Http*, RandomGenerate, EntryUrlTaggers, Conduit, ViewEventPayload, Question, Schema*, core/*Cast*; `p/ConduitEntryRecords`, `p/SendRecordObjects`, `p/ListenTopLevelStart`, `p/PushTagger`, `p/RecordForItem`, `p/RecordSchemaRun`, `p/RecordVariantMove`, `p/RecordProvenance{CtorValue,EntryPage,SameVariant,TopLevelOk}`, `p/SchemaIssuesFresh`, `p/SchemaIssuesExclusive`, Initialization*, FoldLevels | S5 | S6 | 10 |
| S8 | **`Dict`, `Ref`, `Log`** | #961 rebased onto v2 with its `Dict` rows as words; `Ref`/`Deferred` slot state and ordered transforms, deep no-loan ◆/consumed/escape checks, ordinary stored loan propagation and depth-correct copy diagnostics, `Ref.modify` loan returns, unknown refs=top, call-boundary suspension liveness via `effectAt`, P-sync pinned per platform; `Task.callback`'s `Resume`; the worded `Js`/`Task`/`Log`/schema surfaces re-justified  Complete cross-package pin closure through Task.callback/resume and all asserted helpers (#1061); specify ownership metadata independently of frozen v1 for Log.once, Task.keepLogContext, Js.maySuspend and Dict (#1053, §9); word `Dict.focus` with callback `stored` in its `dict`/Maybe form (§2.13.6, #1021). Implement selected cellmodify .1 write-back, ordinary stored loans and region/effect serialization (§2.13.7); no blanket ownership demand on .0. | DictFocus, DictValueWritten, DictTupleFocus*, DictUpdateStoredAnswer, Permutations, WriteExtents; `p/DictFocusGrow`, `p/DictHelperAlias`, `p/DictRecordAlias`, `p/DictTupleAlias`, `p/CopyApart`, `p/RefOwnsContents`, `p/LogAnnotateUpdate`; R-5.10.12's fixtures; Words, WordsBrowser, JsPure, TaskWords, core/JsWords; all new loan twins in Appendix B | S5, S7, #961 | S6 | 14 |
| S8b | **In-place list lowering (oc O5)** | consume v2's clean list-write channel; replace trie/claimability fallback with the decided array/read-only-view representation on every platform, emit accepted writes in place, remove automatic copying paths, keep explicit `List.copy`; make refused/unchecked modules emit no writes  Authorize only channel-listed writes after all module checks; preserve operand evaluation order and views/base offsets; no claim/copy fallback, no unchecked inlining path. Re-pin every changed primitive/helper/codegen implementation, rerun unsafe-direction flips and sanitiser blind-spot #1035, and version the lowering channel. | list sanitiser and accepted-write traps on node/browser, list run/browser hashes, O5 black-box scenarios; switch-over criterion (4) demonstrated | S5, S8 | S6 | 10 |
| S9 | **Parity, cost, gates** | the whole-corpus diff to zero unjustified differences; every pending fixture green or re-filed; `test-perf` scenarios of §7.6; the mutation suite; `own_limits_test`; the fuzz sweep's first 10⁵ programs; the full cross-check run; Fail-fast time and accounting counters of §7.6, including zero-label closure towers and non-growing unions; resource headroom report to owner. | R-8.1–R-8.8 whole; core and every platform clean under v2 (R-1.10, R-8.4); R-7.1's +10 % or a report | S6, S7, S8b | — | 12 |
| S10 | **Switch-over and deletion** | §8.2 pre-migration criteria met; nominal Send/Send.to migration of platforms/callers, compare migrated v2 results to the frozen alias-form corpus results; v2 default; `src/own/`, `--ownership=v1`, `--ownership-everywhere` and the `"lists"` key deleted; `src/own2/` renamed; goldens' v2-own lines blessed; `skills/beni/` and `language.md` §10 checked current (attribute updated in S2b, words, `Send.to`); O4a (#320) and O4b (#978) on v2 | gates green with every R-8.1 flip; `-Dllvm` green | S9 | — | 5 |

The planning allocation is **164 reference implementer-days across 14 slices**, with a **145-day
reference dependency path** (S1→S2→S2b→S3a→S3b→S4→S5→S7→S8→S8b→S9→S10). S6 runs from S5 alongside
S7/S8; S8 waits for S7's effect/protocol integration, and S9 waits for S6 and S8b. The merged S0/S1/S2
scope accounts for 25 reference days; the remaining 139 include S2b's final codec review and deferrals.
These numbers allocate implementation/review scope, **not elapsed agent days**. The repository records
S1 starting 2026-10-25 22:27 and the S2b pin correction at 2026-10-26 09:31 (+0100); overlapping work and
review compressed much of the old allocation into less than a day. There is no measured agent-hours
series from which to fit a reliable calendar multiplier. Five block reviews also show that the old S6
six-day allocation omitted semantic closure, canonicalisation and sharing decisions. S3a rises to 12
for its adapters, word gaps and accounting; S3b to 15 for observable-state transport; S6 to 12 for the
package/disk boundary; S4's 22 protects the independent recursive proofs and includes Appendix C's walker derivation, which needs its
`callParam` and `within`. Re-estimate at each slice's
integration review using actual active/review time and unresolved witnesses, never just changed lines.
S9 may uncover v1 defects needing requirement decisions; report those as issues, never weaken parity.

### 8.1 Risks and what de-risks each

| Risk | De-risked by |
|---|---|
| growth beyond source/import lanes reaches the chosen allowance on real code | S3a/S4/S7 category measurements and §7.6 fail-fast tests; report ≥10% growth headroom use, no silent cap or default change |
| implementation does not reproduce Appendix C's map/fold classes | S2b checks construction under supplied substitutions; S4 reproduces the derivation with pinned representation primitives, over S3b's call instantiation; sortWith is asserted and fold-element κ stays lost as decided. Any further mismatch is reported to the owner, not repaired by a new implicit trusted row |
| the rotate-`update` family's Θ(N²) facts cost time on a real app | `test-perf` at N = 64/256; sharing keeps the representation O(N); no real TEA app in the corpus has it |
| `recast` loses exactness core's `Schema` needs | S7 runs core's `Schema` under the diff first; structural place identity covers core; a miss is a refusal of core, which fails beni's build loudly (R-1.10) |
| the nominal `Send` churns the platforms and corpus | S7 handles both inputs inside v2; S9 keeps the old API/corpus diff intact; S10 migrates the API and checks the recorded semantic baseline before deleting v1 |
| the keep-edge rule still misses a path | `p/RecordKeptInLiteral`, `p/RecordInnerKept`, `p/RecordWriteBeforeKeep` plus the sanitiser over `run/` |
| the entry's sparse fixpoint and κ invariant do not settle fast on Conduit | §2.10–§2.12's recursive quotient and §4.1's total operation-graph proof; S7 measures pushes on Conduit and Bike Wars |
| the Lean oracle models another algorithm (#399) | advisory (R-8.11); the sanitiser is the arbiter |
| v2 refuses what v1 accepted outside the requirements | a stop condition in S9, reported, never worked around (R-8.3) |
| `--ownership=v2` leaks into cached entries | `OWN2` blocks are a different section; a mixed cache misses |

### 8.2 Switch-over criteria

(0) §4.1's accounting invariants implemented and instrumented, §4.4's headroom gate green, the three §4.1 qualified families reported separately, no unapproved precision loss;
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

The semantic representation, final rows, nominal `Send` with its v2-only transition, exact index-exchange shapes and
resource policy are specified in §2–§4; they are not open forks. The trusted surface is R-3.6/R-5.10.7–8.
[O 2026-10-25] Precise ordinary labels, pre-work growth reservations and loud exhaustion remain mandatory.
[O 2026-10-26] `sortWith` uses its pinned asserted row; a fold accumulator's element condition stays `lost`.

One source-metadata choice remains for S8 (#1053): existing-word-only assertions on Log/Task/Js must
populate only v2's ownership column while v1 still supplies S9's comparison baseline. The recommended
spelling is a core/platform-only `@ownership_v2` declaration attribute that routes that signature's words
to `own2` without changing runtime or v1 metadata. Its adoption remains an open owner decision (#1053), to be taken at S8;
S8 may not instead change frozen v1's column or smuggle a semantically unrelated v2 word into the row.
If adopted, parser/formatter/placement diagnostics, interface/cache versions and skills change together.
This staging choice does not reopen the decided final rows.

The remaining proof question is whether the **narrowed** current-taken-element versus earlier-feedback
rule in C.9 gap 3 can preserve I-κ. S4 must obtain an independent proof/verifier result against every C.11
red twin before proposing that precision change. It is not an implementation shortcut or assumed lemma.
S3a–S9 must also discharge their stated adapter, accounting, import and performance obligations. A miss is
a finding to report with a witness, not authority to merge labels, silently copy, or weaken a requirement.

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
| R-1.10 | §2.13.16, §8 S6 publication / S9 full verdict | S6, S9 |
| R-1.11 | §2.14 O9, §2.13.6 | S2b, S8 |
| R-1.12 | §3.7 channel | S5 |
| R-2.1–R-2.4 | §2.8, §2.13.2, §2.13.6 (`written`) | S3a, S8 |
| R-2.5 | §2.6 `record_update`, §2.8 | S5 |
| R-2.6 | §2.11 item 3 | S3b |
| R-2.7 | §2.11 function values | S4 |
| R-2.8 | §2.6 `lambda`, §2.8 `once`, §2.11 affine identity token | S4 |
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
| R-3.6 | §2.14 O9, §2.13.6 pins, §2.13.4, §2.13.7 (P-sync), §2.13.10 | S2b, S7, S8 |
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
| R-4.7.2 | §2.9 (the one `level` case), §2.13.3 | S3b |
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
| R-5.4.2 | §2.8 `once`, §2.11 affine identity token | S4 |
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
| R-5.10.1–R-5.10.11 | §2.13.6 (words, resolved placements and pins) | S2b, S3a, S8 |
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
| R-7.3, R-7.4, R-7.5 | §4.1 source lanes/growth proof; §4.4 precise labels and raise attribute; §6, §7.7; §9 | S1, S2b, S9 |
| R-7.6, R-7.7 | §3.8; core-dump #428 at S6 | S3a, S6 |
| R-7.8 | §3.7 (the existing per-module hook, no new wait), §3.9 | S6 |
| R-7.9 | §3.7 | S3a |
| R-7.10 | §3, §5 | S1 |
| R-7.11 | §6 | S9 |
| R-7.12 | §3.9, §4.4; `p/AppliedLambdaRecursion` | S1, S3a |
| R-7.13 | S6 | S6 |
| R-7.14 | §3.7, §7 (hidden flags: `--ownership-totals`, `--ownership-flips`, `--ownership-records-lost`, `--sanitize-records`, `--sanitize-lists`, `--records-in-place`, `--ownership=v1\|v2`, `--ownership-both` (one check, both reports, for §7.2's parity), `--ownership-skew-sites` (the dump's cross-check with the module check, shown to fire); `--ownership-everywhere` transitional, deleted at S10) | S0–S9 |
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
| *to write, red twins found by the S1 review (§2.2's `⟲` matching):* RoseAlias (`type Rose = Rose (List Rose)`: a write through the root's children list with a subtree held → refused `alias`; the prefix reading of `⟲` accepted it), MaybeTreeAlias (`type T = T (Maybe T) (List Int)`: the same through `Maybe`), MutualAlias (`type A = A B | …`, `type B = B (List A)`: a write to `B`'s list with an `A` below held). In all three the write is under `⟲` or the demand is deep; a shallow storage write of the container while a level below is held is accepted (§2.8 *Holders across a cycle*) | R-4.7.1, R-4.7.4 | S3a |
| *to write, green twin of §2.9's per-value snapshots:* DeadDuplicateLive (`r = [ 1 ]; a = [ r, r ]; b = [ r ]` with `a` dead, then `List.update b 0 (λl → List.push l 9)` and `b` returned: accepted, as v1 accepts it; `a`'s `shared` lives in `a`'s snapshot and never reaches `b`'s) | R-4.6.7, R-8.3 | S4 |
| *to write, twins of §2.9's positional collections:* PositionsRepeatArg (`f a b = [ { a = a }, { a = b } ]` called as `f x x`, then an element write at `[*].a`: the `positions` node's multiset `{x, x}` is `shared`; refused `exclusive`), BranchSameElement (green: `if c then [ x ] else [ x ]` is a `union` of alternatives, κ at `[*]` stays `yes`, a write into the element is accepted) | R-4.6.2, R-4.6.7 | S4 |
| *to write, twin of §2.3's folded positions:* FoldedPositionsLost (a recursive function over `type Rose = Rose (List Rose)` building `Rose [ Rose [], Rose [] ]`-shaped values, whose read-off widens the children into the root class, the collection kept as a side of a `union` beside the class image (§2.3), then a write into one child's list: never refused `shared` (exact); where the fold leaves no proof the cause is `exclusive (a)`, approximate, and where the written path needs no exclusivity the write is accepted) | R-4.7.5, R-6.3 | S3b |
| *to write, green twin of §2.9's `(NodeId, PathId)` key:* OnePairTwoPositions (`r = [ 1 ]; p = ( [ r ], [ r, r ] )`, then a write into `p.0`'s element through `List.update (Tuple.first p) 0 (λl → List.push l 9)` with `p.1` dead: accepted; `.1[*]`'s `shared` is stored at its own path and never answers `.0[*]`) | R-4.6.4, R-8.3 | S4 |
| *to write, red twin of §2.9's union read:* CallbackFieldPositionsUnion (`[ { a = (g 1).a }, { a = (g 2).a } ]`, whose `[*].a` is `union(leaf{cb@ι₁·.a}, leaf{cb@ι₂·.a})` read from an empty snapshot, as an instantiation's fresh union is, then an element write at `[*].a` with `g = λ_ → shared`: the read derives `apart` over the united cells, never `yes`; refused `exclusive`) | R-4.6.2, R-4.6.4 | S5 |
| *to write, red twin of §2.9's position-exact key:* CallbackFieldPositions (`w = if c then (g 1).a else (g 2).a` beside `List.update [ g 1, g 2 ] 0 (λr → { r \| a = … })` with `g = λ_ → shared`: the branch's `yes` at a plain path must not answer the element write at `[*].a`, which reads the same interned leaf under a summary position; refused `exclusive`. S2 pins the κ half as a unit test), CallbackFieldPositionsBranch (`if c then [ (g 1).a ] else [ (g 2).a ]` beside `List.update [ g 1, g 2 ] 0 (λr → { r \| a = … })`: the leaf `{cb@ι₁·.a, cb@ι₂·.a}` stored `yes` at a summary position in one branch is the same interned leaf as `[ g 1, g 2 ]`'s `[*].a`; the read derives `apart` over its arrivals and records `xreq`, never the stored `yes`; refused `exclusive` with `g = λ_ → shared`) | R-4.6.2, R-4.6.4 | S5 |
| *to write, red twin of §2.8's cycle anchors:* RoseKidsHeld (`type Rose = Rose (List Rose)`; `case r of Rose kids → (kids, incKids r)` with `incKids` writing only `π₁·⟲·#Rose.0`: refused `held-operand` at the call, since `kids` holds the container of the subtrees whose lists are written; a climb of trie ancestors alone accepted it and pushed the subtrees' lists in place) | R-4.7.1, R-4.7.4 | S3b |

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
| `ClosureTower` | `w0 ⊤=(xs=[0]; λflag → xs)`; each written `wk ⊤=(a=w(k−1) ⊤; b=w(k−1) ⊤; λflag → if flag then a flag else b flag)`. Fixed type `⊤ → (Bool → List Int)`, zero formal callback labels, no recursive dependency: enumerate exact ordinary creation contexts at export, trip the summary-growth limit, never fold by repeated CodeId. Generate k=24; smaller/raised twins test preserved captures. | R-7.2–R-7.4, R-7.12 | S4 |
| `OwnershipSummarySizeRaised` | source syntax below; a generated acyclic wrapper owner exceeding 65,536 growth records but below 131,072 errors unannotated, checks with function raise and with module raise; a deliberately shared-result write still refuses at both settings. A 262,144 module default plus 131,072 function value is invalid (cannot lower); duplicate/local/zero/overflow attributes refuse `invalid_ownership_summary_size`. S2b pins the syntax and the invalid attributes on BIR only; S3a owns the behavioural cases (#1056). | R-7.3, R-7.4, R-7.6 | S2b, S3a |

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
baseline/growth category totals; it must not assume one callback label equals one growth record, or that baseline records spend the allowance. Tests never lower the
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


**Full-review red/green twins to implement (S2b metadata, S4 calls, S8 cell semantics).**

| Fixture | Red probe and required green control | Requirement | Slice |
|---|---|---|---|
| `LoanStoredInCell` | `Ref.set r2 (Ref.get r1)`; then update r1/read r2: refuse at set. `Ref.make (Ref.get r1)` twin refuses at make. Copy the stored list before set/make accepts; copying an outer container containing the loan does not. | R-5.12.3, R-3.1 | S8 |
| `LoanAtSuspendingCall` | `show (Ref.get r)` with show sleeping before reading its argument refuses; also captured/environment/indirect-callee variants. A sync reader accepts; `show (List.copy (Ref.get r))` accepts when only copied storage is read. | R-5.12.3 | S4, S8 |
| `LoanModifyReturn` | `a=Ref.modify r (λxs → (xs,xs)); Ref.update r …; List.length a` refuses the update; disjoint fresh .0 with owned .1 accepts. Replacing a cell's contents must not change its re-entry slot identity. | R-5.12.3 | S8 |
| `UnknownCellReentry` | unknown synchronous callback within a focus, or while a possibly touched slot has a live loan, refuses; known sync callback with disjoint/no refs accepts. | R-5.12.3, R-5.5.4 | S8 |
| `LoanSend` | sending/consuming a loan directly or nested in payload refuses before hand-over; copying the actually borrowed storage accepts. | R-5.9.1, R-5.12.3 | S7, S8 |
| `MetadataRenamedTypes` | renamed sequence/cell/failure types get the same Builder/slot/try behavior; missing/wrong metadata is pessimistic or a placement error, never empty contents. | R-5.10.7, R-5.5.11 | S2b, S4 |
| `BuilderCallbackSharing` | map's shared-result inner write refuses, fresh-result inner write accepts; `builderdone` preserves κ; direct and imported versions agree. | R-5.2.9, R-4.6.3 | S4 |
| `OnceThroughAlias` | `g=f` then compatible `f ⊤` and `g ⊤` refuses once; two mutually exclusive arms calling the same closure accept if captures are otherwise safe. | R-5.4.2 | S4 |
| `ConcatenatedAliasWrite` | renamed `concatenated`/`written` function, direct alias and wrapper: `a=[1]; b=appendAlias a [2]; List.length a` refuses the write; copied base accepts. Same facts with direct name and `++`/spread demand fusion. | R-2.2, R-2.7 | S2b, S4 |
| `SlotStateBranches` | Ref.set to a new payload then get/update, and alternative-arm stores, must use the joined current slot contents; aliases of the same handle never evade re-entry. Disjoint fresh handles are the green control. | R-5.12.3 | S8 |

**Acceptance fixtures for loans, accounting and traversal provenance.**

| Fixture | Required answer / accounting | Requirement | Slice |
|---|---|---|---|
| `LoanStoredLocal` | `xs=Ref.get r; d=Dict.insert Dict.empty 0 xs` and `ys=List.push [] xs` followed by synchronous lookup/reading accept while the same loan region remains live. Return/store the built value outside that region, send it or hold it across suspension: refuse. Same answers through a forwarding helper. | R-5.12.3 | S8 |
| `LoanCopyDepth` | r:Ref(List(List Int)); outer List.copy/filter then suspension/escape refuses for inner loans; List.map (Ref.get r) List.copy accepts with Int leaves. Chat's List(String×Socket) filter is green because children cross. | R-5.12.3 | S8 |
| `RoutineBaselineFamilies` | Scale source-sized recursive bodies/local functions, identity-or-fresh record-update arms and the corresponding wide-model main independently. Initial/final scans, direct queries/calls and entry equations stay baseline; never Θ(length) G_f just for another validation/query. Counter-twins require transfer×version, demand×holder, call×obligation or cross-field products and exercise the same loud limit, not silent coarsening. | R-7.2, R-7.4 | S1, S3b, S5, S7, S9 |
| `BaselineLaneInvariant` | A test mutation making a 512-record kernel request record513 produces ownership_accounting_invariant in all build modes, no clean block, never growth spill/raise suggestion. Alpha-renaming/permutation preserves baseline eligibility by source incidence; no first-visitor credit. | R-7.4, R-7.6, R-7.7 | S1, S9 |
| `SendDualProvenance` | Alias protocol value forwarded through msg→⊤ helper remains a send; an arbitrary same-type function does not become one. Nominal Send.to agrees under v2. Legacy corpus/API/v1 inputs remain unchanged before S10; migrated v2 corpus matches recorded semantic baseline at S10. | R-5.9.9, R-8.3 | S2b, S7, S9, S10 |
| `TwoTraversalsShared` | Red: `ys = List.push (List.map xs λl → l) (List.foldl xs [] λx _ → x)`, then `List.map ys λl → List.push l 1`, `xs : List (List Int)` exclusive and dead. `ys` holds `xs`'s last list twice, and the element write must be refused `exclusive` (approximate): the two splits come from two traversals of `xs` (§2.2, #1029). Green: `List.map xs λl → List.push l 1` over an exclusive `xs` stays accepted. v1 refuses the red on `browser-inline` and under `--ownership-everywhere` (#1029). | R-4.6.9, R-3.1 | S4 |
| `FoldOverFoldShared` | Red: `r = List.foldl xs (List.foldr xs [] λx a → List.push a x) λx a → List.push a x`, then `List.map r λl → List.push l 1`. `r` holds every list of `xs` twice; the element write is refused. Both folds stay accepted `callback-param` (their accumulator writes are storage writes). The fold-element condition stays lost (Appendix C.9); any future narrowed rule must still refuse this twin. | R-5.3.2, R-3.1 | S4 |
| `FeedbackPrevTwice` | Red: `st = Tuple.second (List.foldl xs ( [], [] ) λx ( prev, st ) → ( x, List.push (List.push st prev) x ))`, then `List.map st λl → List.push l 1`. Each list is in `st` twice (once as `x`, once as the next round's `prev`), so the element write is refused. Two cells that came back through the feedback are never called apart (Appendix C.9 gap 3). | R-5.3.2, R-3.1 | S4 |
| `NestedTraversalShared` | Red: `each ws xs f = List.map ws (λ_ → List.map xs f)`; `zs = each [ 1, 2 ] xs (λl → l)`, then `List.map zs (λinner → List.map inner (λl → List.push l 1))`. `zs[0][j]` and `zs[1][j]` are one list, so the nested write must be refused: the inner traversal's splits leave the lambda through `List.map`'s folded callback label and are not `single` (§2.2 *Traversals*). Green: `each [ 1, 2 ] xs (λ_ → [ 1 ])` stays exclusive (a fresh result per call). v1 refuses the red (`exclusive`, approx). | R-4.6.9, R-3.1 | S4 |
| `NestedTraversalAcrossModules` | `NestedTraversalShared` with `each` in module `A` and the caller in module `B`, which imports it. The red must be refused through `A`'s block, which carries `single` cleared (§3.6 *Traversal marks*); with a cache directory and `--no-cache`, the same verdict. Green: `B` calling `List.map xs λl → List.push l 1` over an exclusive `xs` stays exclusive through core's block, because `single` is set. A block whose marks are corrupted is unknown, never `single`. | R-4.6.9, R-5.7.1, R-5.7.4 | S6 |

**Value interpretations and source-adapter twins.** These fixture contracts are implemented in the named
slice; foundation unit tests do not replace the direct/imported corpus pair.

| Fixture | Required answer / invariant | Requirement | Slice |
|---|---|---|---|
| `ProjectedKappa` | A write at pair `.1` ignores an unrelated shared `.0`; `xs=[(a,b),(b,a)]` with a first-component writer and retained second component refuses the cross-path alias; an alias at `.1` refuses. `make ⊤ = (x=[1];(x,x))` and a fresh record containing it never justify two writes. | R-4.6.4, R-4.10.3, R-3.1 | S2, S4, S5 |
| `KappaArrivalJoin` | Single fresh arrival has yes; a projected multi-arrival leaf derives its atoms. Joining a shared alternative weakens only the returned snapshot; an earlier class keeps its own κ. Reusing the same Shape NodeId with two snapshots cannot bypass either condition. | R-4.6.3, R-5.5.5, R-3.1 | S2, S4 |
| `KappaTransport` | Direct and wrapped map of a fresh callback accepts; capture-returning callback and `[x,x]` with an element writer refuse. Relabel, projection, union and imported/cached blocks preserve the κ interpretation and label-keyed supplies. | R-5.2.9, R-5.7.1, R-5.7.4 | S3b, S4, S6 |
| `PlainFreshList` | `[1,2]` is fresh with yes; wrapping shared lists in a fresh outer record does not make its children exclusive. | R-4.6.3, R-4.6.4 | S2, S3a, S5 |
| `ConstructorTemplatePlaces` | Own/imported recursive constructor payloads produce the same places, including Rose/Maybe/mutual cycles; distinct ordinary type arguments stay distinct, non-regular growth folds conservatively. Test direct/cached and definition order permutations. | R-4.7.3, R-5.7.1, R-7.7 | S3a, S6 |
| `CallbackListWords` | A borrowed/plain list of callbacks is not calls-many; only once/many/unused metadata enables the callback-list contract. Derived eq/compare propagates component classes and rejects writes under the existing rule. | R-5.10.5, R-5.13.1 | S3a, S3b |
| `AccountBeforeQuery` | Fault-inject failure before interning, a path/region climb and a cyclic projection: no completed memo, partial published graph or follow-up work. Distinct local functions use unique owner atoms and real phases; declaration renaming preserves lanes. | R-3.7, R-7.4, R-7.7 | S1, S2, S3a, S9 |
| `CanonicalOwnershipBlock` | Vary intern ids, union insertion order and declaration order: semantic-equal classes have identical published bytes and hashes. Supply keys are sorted before ordinals; corrupt traversal marks decode unknown. | R-5.7.2, R-5.7.4, R-7.7 | S2b, S6 |
| `KappaLeafJoin`, `KappaEmptyProjection`, `IdentityMapKappa` | Propagation, comparison and identity substitution preserve stored constraints below leaves/recasts and empty nodes; both shared-owner routes survive. Red until #1063/#1064 and S3b. | R-3.1, R-4.6.4, R-5.7.4 | S3b, S6 |
| `StoredCallbackResult`, `ModifyResultPaths` | Focus puts a returned capture into the sequence (later captured-holder write refused); returning the taken item stays precise. Modify .1 is consumed/no-loan; independent .0 remains returnable, aliased .0 is a loan. | R-4.6.10, R-5.12.3 | S4, S8 |
| `DictUpdateStoredAnswer` | `d2 = Dict.update d k (λ_ → Just c)` with `c` a list, then `List.push c 1` while `d2` is live: refused, since `d2[*]` holds `c` through callback `stored`'s `Just` payload. `λ_ → Nothing` stores nothing; copying `c` first accepts. | R-4.10.12, R-5.10.8 | S8 |
| `BlockSharedOwner`, `BlockPositionClosure`, `BlockGlobalKnots` | Compare semantic κ at paths after decode, not only bytes: leaf/empty/projected paths, two roots of one map, distinct-map equal shapes, unequal rings and map/widen copies. Corrupt/effect/traversal records never authorize a write. | R-5.7.2, R-5.7.4, R-7.7 | S2b, S4, S6 |
| `BlockFirewallBodyOnly`, `BlockPlacesShared` | A body-only cost change leaves an unchanged semantic interface hash; nested place suffixes and repeated lazy imports are processed once, not expanded per class. | R-5.7.3, R-7.2, R-7.4 | S6 |

## Appendix C. Worked derivations of the core loops (S2b, before walker code)

*Part of #1014; §8.1's derivation risk. Done on paper with §2's rules alone, against `core/List.beni` at
`7013ed4ac`. C.9 records the decisions for the three inference gaps. C.10 states the obligations used by these
derivations.* Notation as §2: `excl(c)` is the condition of an arrival `c` at the selected path, `sep`/`within` as §2.9–§2.10.
Instructions are named by role: `ι_t` the `traverseAt`, `ι_f` the call of the function parameter, `ι_p` the
`put`, `ι_rec` the recursive call, `ι_d` the `done`. **Rounds count from ⊥**: round k is the class after the
k-th walk under the class of round k − 1. §2.12's propagation computes the same limit, and §2.12's prose
counts its rounds from the first walk that crosses the self-edge, which is round 2 here.

S2b's tests exercise `Cond.lower`, `instantiate`, joins and `leq` against this derivation; the tests supply
the call substitution and read-off fold. They do **not** infer uses, calls, supplies or `within`. S4's
walker/read-off must produce those classes and discharge them for actual callbacks: `mapHelp` and `foldlFrom`
call their function parameter (`ι_f`), which needs S4's `callParam` and its supply/`within` read-off (§2.11
*Carried-class boundary (S4)*), over S3b's instantiation of direct calls. In particular,
`Cond.sep` on an already folded self pair returns `lost`; only a distinct pre-fold `sep` supplies `within`.
The verdicts below are conditional derivations, not evidence that end-to-end inference is already built.

### C.1 Rows taken as given

Asserted (R-5.10.8; §2.13.6's words):

| Row | Class used |
|---|---|
| `traverseAt : List a, Int → taken a` | π₁ `R` at ε, `A` at `[*]`; result `elem(c·ι)` for the container cell `c` of argument 1; `(c, ι, κ(c at [*]))` joins the frame's `taken` set (§2.2) |
| `put : written returned Builder a, borrowed Int, stored a → Builder a` | `W` (storage) at π₁·ε; result π₁'s object, `[*] ↦ join(π₁[*], π₃)`; κ at `[*]` is `κ(π₁[*]) ∧ apart{π₃, π₁[*]} ∧ excl(π₃)` (§2.9 construction) |
| `builder : unused Int → fresh exclusive Builder a` | fresh, `[*]` empty, κ `yes` |
| `done` (`builderdone`) | parameter 1's node unchanged: the same cells, children and κ |
| `length` | π₁ `R`; crossing result |

**`base` and `offset`.** These representation readers have asserted primitive rows (§2.13.16):
`base` has π₁ `RA`, res π₁; `offset` has π₁ `R` and a crossing result. C.7 explains why body inference
cannot supply those contracts through host reads.

### C.2 `mapHelp`

```text
mapHelp a o i n func b =                     π₁ a, π₂ o, π₃ i, π₄ n, π₅ func, π₆ b
    if i < n then mapHelp a o (i + 1) n func (put b i (func (traverseAt a (o + i))))
    else done b n
```

**Walk** (then-arm in BIR order: arguments before their call, inner before outer, §2.6). The operands are
`a` (operand 1 of ι_rec), `o`, `i + 1`, `n` and `func` (operand 5), then `b` (operand 1 of ι_p), `i` and
`o + i`, and `a` again (operand 1 of ι_t). Then:

1. ι_t: `A = elem(π₁·ι_t)`; the `taken` set gains `(π₁, ι_t, excl π₁)`. While the split is in force, the
   pending `a` holds `others(π₁·ι_t)` at `[*]` (§2.2, *Materialisations in force*).
2. ι_f: this is a call of π₅. The result is `{cb₅@ι_f}`. It records the supply `(5, 1, elem(π₁·ι_t), ι_f)`:
   `taken`, κ `excl π₁`, and **owned**. Dead holds at ι_f, because the one other holder, `a`, holds `others`
   (§2.13.6).
3. ι_p: a writer demand on `{param π₆}`. Known; Unescaped (a parameter); Disjoint (`i` crosses, and
   `cb₅@ι_f` is another arrival, so `alias` is no); Dead (the last use of `b`). Accepted `param`. Read-off:
   `W` at π₆·ε. Call the result `N_p`: π₆'s object with `[*] ↦ {π₆[*], cb₅@ι_f}` and
   `κ(N_p[*]) = excl π₆ ∧ sep(cb₅@ι_f, π₆[*]) ∧ excl(cb₅@ι_f)`.
4. ι_rec: `Calls.apply(C, …)` with π₁ ↦ `a`, π₅ ↦ the frame's own π₅, π₆ ↦ `N_p`.
5. Else-arm, ι_d: π₆'s node, κ `excl π₆`. `res = join(A(ι_rec), A(ι_d))`.

**No keep edge.** After ι_f the frame's only `W` demands are on π₆'s cells (the `put`, and the callee's `W` on
π₆ instantiated onto `N_p`'s ε cells `{π₆}`). Neither aliases `elem(π₁·ι_t)`. **No `xreq`**: the body never
writes a taken element. It hands the element on, and κ goes with the supply.

| Round | What changes | Class after read-off |
|---|---|---|
| 0 | — | ⊥ |
| 1 | `A(ι_rec) = ∅` | res ε `{π₆}`, `[*]` `{π₆[*]}`; κ `excl π₆`; `fun(5)` calls ≤1, supply ι_f: `elem(π₁·ι_t)` |
| 2 | at ι_rec: the callee's `W` π₆ is a `callsite` demand on `{π₆}` (accepted `param`). Its supply is the label `(ι_rec·ι_f)`, supply `elem(π₁·(ι_rec·ι_t))`. Its res gives `[*] = proj(N_p,[*]) = {π₆[*], cb₅@ι_f}`, and `excl π₆ ↦ κ(N_p[*])`. Read-off: ι_f occurs under `[*]`, so it folds to `ι_f⋆`; ι_rec calls the frame's own group, so it folds to `ι_rec⋆` (§2.2) | res `[*]` `{π₆[*], ι_f⋆}`; κ `excl π₆ ∧ excl(ι_f⋆) ∧ sep(ι_f⋆, π₆[*])`; calls many; supplies `ι_f⋆ ↦ elem(π₁·ι_t)`, `ι_rec⋆ ↦ elem(π₁·ι_rec⋆)` |
| 3 | the callee's `ι_f⋆` gives `cb₅@(ι_rec·ι_f⋆)`, and its `π₆[*]` gives `{π₆[*], cb₅@ι_f}`. So `sep(ι_f⋆, π₆[*])` gives `sep((ι_rec·ι_f⋆), π₆[*]) ∧ sep((ι_rec·ι_f⋆), ι_f)`, and `excl` follows | res `[*]` `{π₆[*], ι_f⋆, ι_rec⋆}`; κ `excl π₆ ∧ excl(ι_f⋆) ∧ excl(ι_rec⋆) ∧ sep(ι_f⋆, π₆[*]) ∧ sep(ι_rec⋆, π₆[*]) ∧ sep(ι_f⋆, ι_rec⋆)` |
| 4 | the callee's `sep(ι_f⋆, ι_rec⋆)` gives `sep((ι_rec·ι_f⋆), (ι_rec·ι_rec⋆))`. Both sides fold into `ι_rec⋆`, so the fold emits `within(ι_rec⋆)` (§2.10 read-off) | round 3 `∧ within(ι_rec⋆)` |
| 5 | `within(ι_rec⋆)` gives `within((ι_rec·ι_rec⋆))`, which is `within(ι_rec⋆)` | = round 4: **fixpoint**. The validation walk under it reads it off again (`F(x) ⊑ x`) |

**`mapHelp`'s class.** π₁ `R`, `[*]` `R` (§2.10: `A` comes from `res`, which names no `π₁[*]`; the element reaches a caller only through a callback label). π₅ `R`, called many times (an operand of ι_rec). π₆ `RAW` (storage, ε), `[*]` `A` (res names `π₆[*]`). res ε `{π₆}`, `[*]`
`{π₆[*], cb₅@ι_f⋆, cb₅@ι_rec⋆}`. κ(res[*]) `= excl π₆ ∧ excl(ι_f⋆) ∧ excl(ι_rec⋆) ∧ sep(ι_f⋆, π₆[*]) ∧
sep(ι_rec⋆, π₆[*]) ∧ sep(ι_f⋆, ι_rec⋆) ∧ within(ι_rec⋆)`. `fun(5).supply(1)`: `elem(π₁·ι_t)` at `ι_f⋆` and
`elem(π₁·ι_rec⋆)` at `ι_rec⋆`, each `taken`, owned and κ `excl π₁`. This is §2.12's result plus the
`excl` atoms that §2.9's construction rule adds through `put`'s `stored` (the value's condition at that path), which
§2.12's narrative leaves out (C.10). **v1** (its
inferred row, `beni dump --stage=ownership --core core/List.beni`): `π5 calls many, supply 1 π1[*] owned
taken{excl π1}`, κ `{excl cb5, sep cb5 cb5, sep π6[*] cb5}`. These are the same facts. v1's one `sep cb5 cb5`
is v2's `sep(ι_f⋆, ι_rec⋆) ∧ within(ι_rec⋆)`.

### C.3 `List.map`

`map xs func = mapHelp (base xs) (offset xs) 0 (length xs) func (builder (length xs))` is one call, ι_m. Its
arguments: π₁ ↦ `base xs` (π₁'s object), π₅ ↦ the frame's own π₂, π₆ ↦ `result(ι_n)·1` (the builder: fresh,
`[*]` empty, κ `yes`). The callee's `W` π₆ is a `callsite` demand on the fresh builder: accepted `fresh`.
res: ε `fresh 1`. `[*]`: `π₆[*] ↦ ∅`, `ι_f⋆ ↦ cb₂@(ι_m·ι_f⋆)`, `ι_rec⋆ ↦ cb₂@(ι_m·ι_rec⋆)`. The read-off folds
every label whose first instruction is ι_m into `cb₂@ι_m⋆` (they occur under `[*]`). κ: `excl π₆ ↦ yes`;
`sep(·, π₆[*])` is an `apart` over the empty set, so `yes`; `sep(ι_f⋆, ι_rec⋆)` and `within(ι_rec⋆)` give
`within(ι_m⋆)`. Supplies fold to `elem(π₁·ι_m⋆)`, which is owned because no holder outside the call is left
after ι_m. They are splits of one traversal (§2.2): their entry prefix is `(ι_m)`, and ι_m's fold is ordinary (under `[*]`, folded callee labels), and the splits are `single`, so `within(ι_m⋆)` may be discharged under κ(xs[*]).

**`List.map`'s class.** π₁ `R`, `[*]` `R`. π₂ `R`, called many times. res `fresh 1` with `[*]` `{cb₂@ι_m⋆}`;
κ(res[*]) `= excl(ι_m⋆) ∧ within(ι_m⋆)`. `fun(2).supply(1) = elem(π₁·ι_m⋆)`: `taken`, owned, κ `excl π₁`.
**v1**: `π2 calls many, supply 1 π1[*] owned taken{excl π1}`, κ `{excl cb2, sep cb2 cb2}`: the same facts. v1
also lists approximate `fresh2` entries at `[*]`, which come from its `builder` row (`res fresh1` with no
contents). v2's `builder` has an empty `[*]`, so v2 is tighter there.

### C.4 `foldlFrom`

```text
foldlFrom a i stop acc func =                π₁ a, π₂ i, π₃ stop, π₄ acc, π₅ func
    if i < stop then foldlFrom a (i + 1) stop (func (traverseAt a i) acc) func
    else acc
```

**Walk.** The operands are `a` (operand 1 of ι_rec), `i + 1` and `stop`. Then:

1. ι_t: `elem(π₁·ι_t)`, taken. The pending `a` holds `others`.
2. ι_f: `{cb₅@ι_f}`. Supplies `(5, 1, elem(π₁·ι_t))` (`taken`, owned, κ `excl π₁`) and `(5, 2, π₄)`
   (owned: this is the last use of `acc` in the arm).
3. `func` (operand 5), then ι_rec with π₄ ↦ `cb₅@ι_f`.

Else-arm: `π₄`. The frame has no `W` demand at all, so there are no keep edges and no `xreq`.

| Round | What changes | Class after read-off |
|---|---|---|
| 1 | `A(ι_rec) = ∅` | res `{π₄}`; κ `excl π₄`; supply ι_f: `(elem(π₁·ι_t), π₄)` |
| 2 | the callee's res π₄ gives `cb₅@ι_f`. The callee's supply is the label `(ι_rec·ι_f)`: `(elem(π₁·(ι_rec·ι_t)), cb₅@ι_f)`. Its second component is a **feedback supply** (this frame's callback result, handed back to the callback, §2.11 item 5). It is owned (it has no other holder at ι_rec), and it is an obligation on what π₅'s actual returns, carried to the caller (R-5.2.7). Read-off: ι_rec folds. ι_f is a direct callback call that is not under `[*]` or `⟲`, so it does not fold | res `{π₄, cb₅@ι_f}` (approximate: two provenances at one path, §2.3); κ `excl π₄ ∧ excl(ι_f)`; supplies ι_f: `(elem(π₁·ι_t), π₄)`, `ι_rec⋆`: `(elem(π₁·ι_rec⋆), cb₅@ι_f)` |
| 3 | the callee's `cb₅@ι_f` gives `cb₅@(ι_rec·ι_f)`, which is `ι_rec⋆` | res `{π₄, ι_f, ι_rec⋆}`; κ `∧ excl(ι_rec⋆)`; `ι_rec⋆`'s supply 2 is `{cb₅@ι_f, cb₅@ι_rec⋆}` |
| 4 | nothing new | fixpoint |

**`foldlFrom`'s class.** π₁ `R`, `[*]` `R`. π₄ `RA` (a supply argument, used at ε, §2.6). π₅ `R`, called many times. res `{π₄, cb₅@ι_f, cb₅@ι_rec⋆}`;
κ `excl π₄ ∧ excl(ι_f) ∧ excl(ι_rec⋆)`. Supply 1: `elem` `taken`, owned, κ `excl π₁`. Supply 2: π₄ owned,
and the feedback cells `{cb₅@ι_f, cb₅@ι_rec⋆}`. **v1**: `π4 RA; res ~cb5 π4; supply 1 π1[*] owned taken{excl
π1}, supply 2 cb5 owned{excl cb5}, supply 2 π4 owned{excl π4}`: the same facts.

### C.5 `List.foldl` and `List.foldr`

`foldl xs acc func = foldlFrom (base xs) (offset xs) (offset xs + length xs) acc func` is one call, ι_l, with
π₄ ↦ π₂ and π₅ ↦ the frame's own π₃. The labels `(ι_l·ι_f)` and `(ι_l·ι_rec⋆)` have a folded callee label,
so every label of ι_l folds into `ι_l⋆`. **`List.foldl`'s class:** π₁ `R`, `[*]` `R`. π₂ `RA`. π₃ `R`, called many
times. res `{π₂, cb₃@ι_l⋆}`; κ `excl π₂ ∧ excl(ι_l⋆)`. Supply 1: `elem(π₁·ι_l⋆)`, `taken`, owned, κ
`excl π₁`. Supply 2: `{π₂ owned, cb₃@ι_l⋆ feedback}`. **`List.foldr`**: `foldrFrom` is `foldlFrom` with the
index going down (still one direction, so the index obligation holds) and the same parameter roles. The walk
and every round are the same, and so is the class. **v1**: the same rows for both.

### C.6 The callers

| Program | Derivation | Result | Required |
|---|---|---|---|
| `List.map xs λl → List.push l 1`, `xs : List (List Int)` | The actual is `W` (storage) on its π₁, with res π₁. **Supply edge**: owned with provenance π₁·`[*]` (taken), so there is a `callsite` demand on `xs` at `[*]`. It is Disjoint (the lambda captures nothing) and Dead (only when `xs` is not used later), and it relies on `κ(xs[*])` (§2.9, *map's element*). **κ**: `excl(ι_m⋆)` instantiates to the supply's condition at the selected path. `within(ι_m⋆)` instantiates to the taken supply twice, which passes under `κ(xs[*])` | exclusive iff `xs` is exclusive at `[*]` (`yes` passes, an atom set goes into `xreq`) | exclusive (R-4.10.2, R-5.2.9) ✓ |
| `List.map xs (λ_ → [ 1 ])` | each label instantiates to `result(ι_c·ι_m⋆)·1`, which is fresh and is not reached through a feedback supply: `within` passes, and `excl` is `yes` | κ `yes`, whatever `xs` is | exclusive ✓ |
| `List.map xs (λ_ → shared)` | every label instantiates to `shared M.shared`, and `within` fails on a `shared` cell (§2.2) | κ `shared`. A write into an element is refused `top-level` (Unescaped, §2.8 step 2, comes before Exclusive, step 6) | not exclusive ✓ |
| `List.map [ x, x ] λl → l` | the actual writes nothing, so there is no demand. `within` runs on the taken supply under κ of the literal at `[*]`, which is `apart{x, x}` = `shared` | κ `shared`, exact | not exclusive ✓ |
| `List.foldl xs [] λx acc → List.push acc x` | The actual is `W` (storage) on π₂ and stores π₁; its res is π₂. **Supply 2**: (i) the provenance π₂ is the literal `[]`, so the `callsite` demand is accepted `fresh`. (ii) For the feedback `cb₃@ι_l⋆`, the actual's res is its π₂, which is the supply itself. The least fixpoint of the feedback node (one inclusion edge, §2.12) is `{site []}`. **Proof (§2.12, *Recursive proofs*)**: the base is `[]`, owned at the call. The step returns the container it received, with no escape, capture or second store. κ(result[*]): the lambda's `sep(π₁, π₂[*])` instantiates with one folded label, `elem(xs·ι_l⋆)`, on both sides. That is "a folded one twice → `lost`" (§2.9), and the fold "does not invent a comparison" (§2.2) | accepted `callback-param`, in place; κ(result[*]) `lost` (approximate) | accept (R-5.3.1, R-5.3.2) ✓; the κ is a precision gap (C.9 gap 3) |
| `List.foldl xs ( [], [] ) λx ( cur, hist ) → if x == 0 then ( cur, List.push hist cur ) else ( List.push cur x, hist )` | Arm 1 keeps `cur` at `.0` and at `.1[*]`, so those two explicit paths name one cell; per-path κ cannot erase that sharing. Arm 2 writes π₂·`.0`. The feedback node's `.1[*]` gains the cell of `.0` (instantiated from arm 1). The supply-edge `callsite` demand runs on the caller's argument (§2.11 items 4–5), the literal `( [], [] )`, whose `.1[*]` is empty, so Disjoint passes there. The refusal is §2.12's *Recursive proofs*: the step must preserve "`.0` owned, held once", and arm 1, an outgoing feedback alternative, breaks it (R-5.3.2's "storing it at a second position") | refused, exact. v1's cause for the record twin is `supply` (`RecordFoldBelow.ownership`); S9's diff must map the two causes | refuse: stored at a second position (R-5.3.3; R-5.3.5's list twin) ✓ |
| `List.foldl xs [] λx acc → if x == 0 then saved else List.push acc x`, `saved` captured | the lambda returns the capture and does not write it, so it is not `once`; the next call writes it. The instantiated feedback cells include `env saved`, and "an `env` … cell fails" (§2.11 item 5). (A lambda that writes `saved` itself is refused `once` earlier, §2.6, §2.11) | refused | refuse: replaced by a borrowed value (R-5.3.2) ✓ |
| `edit list f = List.map list λrow → if c row then f row else row` | `within(ι_m⋆)` instantiates to `edit`'s own `cb f` label and the taken supply. That label is the caller's own `cb` label, so it carries the atoms to `edit`'s class (§2.2, last clause). They are discharged at `edit`'s caller | `editL` with a writer `f` is exclusive under `κ(list[*])`; with an `f` that answers a capture, one `env` cell twice fails | R-5.2.9 ✓ |

### C.7 Why the asserted rows are needed

v1's `assertedRow` (`src/own/Ownership.zig`, *The asserted rows*) covers `set`, `insertAt`, `put`, `push`,
`pop`, `removeAt`, `swap`, `done`, `cons`, `append`, `copy`, `sliceOf`, `sortWith`, `length`, `offset`, `at`,
`unsafeGet`, `traverseAt`, `focus`, `view`, `base` and `builder`. v2 asserts the representation-reader rows, Builder protocol and pinned `sortWith` row specified in
§2.13.16. The following counterfactual derivations explain why **body inference alone** cannot replace
those contracts for `base`, `offset`, `unsafeGet`, `sliceOf` and `sortWith`.

- **`base`** (`if isPlain v then xs else … Js.to (Js.call v "$plain" []) … Js.to (Js.get v "b")` under
  `Js.pure`). `Js.get` and `Js.call` carry no ownership word, so every argument escapes and the answer is `⊤`
  (R-5.10.1). `isPlain` is a top-level value built by `Js.to (Js.get …)` and has no class, so it is `⊤call`
  (§2.11, *Function values*). `v = Js.from xs` is a recast of `env xs` (§2.13.9), and escaping `v` escapes
  `reach(v) ∋ env xs`. `Js.pure` returns the lambda's answer and carries its `E`. **Inferred:** π₁ `RAE`, res
  `{π₁, ⊤}` approximate. v1's row: π₁ `RA`, res π₁. v1's own walk agrees (its dump has `isTrie: π1 RE`).
- **`offset`**: the same tests. **Inferred:** π₁ `RE`, crossing. v1: π₁ `R`.
- **`unsafeGet`** (`Js.at`, `Js.get`). **Inferred:** π₁ `RE`, res `⊤` (`A` comes from `res`, which names no π₁). v1: π₁ `R`, `[*]` `A`, res π₁`[*]`.
- **`sliceOf`**, even with v1's rows for `base` and `offset`: `Js.call (Js.from (base xs)) "slice" …` escapes
  π₁'s object and answers `⊤`. **Inferred:** π₁ `RE`, res `⊤`. v1: fresh, `[*]` π₁`[*]`, list κ `lost`,
  record κ `excl π₁`. `copy` has the same body and is on the S2b list.
- **`sortWith`**, with v1's rows for the four above. `merge` reads `x = at xs i`, which is not taken: `at` makes
  no split, and after `GT` the next round reads `at xs i` again. So each `put b (i + j) x` stores the symbolic
  `π₁[*]` into a `b` whose `[*]` already holds `π₁[*]`, from the deeper rounds instantiated over the same
  `xs`. `sep(π₁[*], π₁[*])` compares a summary position with itself, and distinctness is never derived from a
  label (§2.2), so the answer is `lost`. The two halves are `sortRange` results over the same π₁, and their
  `[*]` cells are both `π₁[*]`, which again gives `lost`. Even taken reads would fail: "two labels of different
  containers' elems that alias, fails" (§2.2). `cmp`'s supplies are borrowed: `x` is used in the `_` arm and
  `y` in the `GT` arm after the call, and `xs` is live. **Inferred:** res fresh, `[*]` π₁`[*]`, κ `lost` for
  lists **and records**; `cmp` borrowed. v1's asserted row: record κ `excl π₁`. v1's own walk of
  `sortRange`/`merge` also gives `{lost}r{lost}`, and that is why v1 asserts the row.

**What follows downstream.** With `base` and `offset` inferred, every loop that reads through them gets π₁
`E` and `⊤` supplies: `map`, `indexedMap`, `filter`, `filterMap`, `reverse`, `foldl`, `foldr`, `any`, `eq`,
`compare`, `concat` and `map2`–`map5`. The `maximum`, `minimum` and `intersperse` loops also get them through
`unsafeGet`. Then `List.map xs f` lets `xs` escape: a later `List.push xs 1` is refused `escaped`, and a
callback that writes its element is refused `unknown`. That is against R-4.10.2, R-4.10.6, R-5.2.9 and
R-5.3.2. C.2–C.6 hold only when `base` and `offset` have v1's rows, which the decision on gap 1 gives them.

`elementof` is the no-split `at`/`unsafeGet` row; `copyof` is the fresh-storage, aliased-elements row
of `copy`/`sliceOf`/pinned `sortWith`; `prepended` names cons's parameter-2-or-fresh storage. Callback `stored`
records focus's put-back explicitly. Inferring those primitives with an approximate `aliased` recast or
making `at` taken does not substitute for these contracts (#1052).

### C.8 Verdicts

| Function | Verdict | Reason |
|---|---|---|
| `mapHelp` | **reaches the required row** (with `base`/`offset` asserted, C.9 gap 1) | C.2. It is v1's row with `sep cb cb` refined into `sep ∧ within` |
| `List.map` | **reaches it** (same condition) | C.3. The four C.6 cases come out as required |
| `foldlFrom`, `foldrFrom` | **reaches it**, with one precision loss | C.4. The in-place accumulator is accepted, and the keeping and replacing twins are refused. The accumulator's element κ is `lost` (gap 3); no requirement names it |
| `List.foldl`, `List.foldr` | **reaches it** (same condition), with gap 3's precision loss | C.5 |
| `base`, `offset` | **weaker when inferred; decided: asserted** (gap 1) | Inferred, π₁ `E` and res `⊤` instead of v1's rows. Lost: everything downstream (R-4.10.2, R-4.10.6, R-5.2.9, R-5.3.2) |
| `unsafeGet` | **weaker when inferred; decided: asserted** (gap 1) | Inferred, π₁ `E` and res `⊤`. Its callers `maximum`, `minimum` and `intersperse` let their argument escape (R-4.10.2, R-4.10.6) |
| `sliceOf` | **weaker when inferred; decided: asserted** (gap 1) | Inferred, π₁ `E` and res `⊤`. Required: a fresh read with aliased elements that keeps record exclusivity (R-4.10.6, R-4.10.7) |
| `sortWith` | **asserted with pinned body** [O 2026-10-26] | Body inference gives record κ `lost`; the pinned row gives `excl π₁`. Required: "`sortWith` keeps it" (R-4.10.7, R-4.10.8, `o/RecordSortWith`) |

**The paper derivation requires every obligation in C.10. A caller's discharge additionally needs
§2.2's *Traversals* rule (#1029, C.11).** Each inferred class
contains its body's behaviour (O5). Each acceptance in C.6 rests on an atom that a run-time fact discharges.
C.11 gives the required refusal witnesses for separate and repeated traversals.

### C.9 Inference gaps and decisions

All three choices are decided. The fold rule below remains a possible future proof task, not part of the
accepted semantics.

**Gap 1 — `base`, `offset`, `unsafeGet`, `sliceOf`: decided 2026-10-25 (manager, from R-5.10.8).**

Why inference falls short: §2.13.16 ("every function not asserted is inferred") applied to four bodies that
read the runtime representation. No rule of §2 can see through a host read:
- `Js.get` and `Js.call` are pessimistic by R-5.10.1 and O10.
- No truthful word fits them, because a getter or a method runs arbitrary JavaScript.
- A cast loses exactness after a step (§2.13.9).

They are representation readers, as `view` and `copy` are, so they are `List` array primitives. R-5.10.8
already asserts those without enumerating them. The decision names them in §2.13.16 and in §8's S2b list,
with §2.13.6's exact selectors, each pinned under R-5.10.7:

| Function | Words | Row |
|---|---|---|
| `base` | `returned List a → List a` | π₁ `RA`, res π₁ |
| `offset` | `borrowed List a → Int` | π₁ `R`, crossing |
| `unsafeGet` | `borrowed List a, borrowed Int → elementof a` | π₁ `R`, `[*]` `A`, res π₁`[*]` |
| `sliceOf` | π₁ `borrowed`, crossing indices `borrowed`, result `copyof List a` | fresh storage, `[*]` π₁`[*]`, list κ `lost`, record κ `excl π₁` |

These are v1's rows, so C.2–C.6 hold. No requirement changes. No body change removes the need: `traverseAt`
reads `a[i]` of an array that `base` returned.

**Gap 2 — `sortWith`: asserted with pinned body [O 2026-10-26], #1014.** Its merge-sort body does
not establish that each original position is stored exactly once in this domain: `at` makes no split and
the two halves both project to π₁[*]. Assert v1's row with result `copyof`: storage fresh, `[*]` π₁[*], list κ `lost`, record κ
`excl π₁`, comparator called many times with borrowed supplies. Pin the body and row under R-5.10.7;
R-5.10.8 names this exception. Do not add index arithmetic or replace the sorting algorithm to infer it.

**Gap 3 — the element condition of a fold's accumulator stays `lost` [O 2026-10-26], #1017.**
`List.foldl xs [] λx acc → List.push acc x` is accepted and edited in place, so R-5.3.2 is met. But its κ at
`[*]` is `lost` (C.6), and a later write into an element of the result is refused `exclusive` (approximate).
No requirement names the case.

Why: §2.10 makes `within` only when a fold merges the two sides of a `sep` between *different* labels. In a
fold the callback stores this call's supply beside cells that came back through the feedback. Both sides are
one folded label `elem(xs·ι_l⋆)`, and §2.9 makes that `lost`.

**The unrestricted fix is unsound.** Treating any two taken elements under the folded split label as apart
under κ(xs[*]) accepts this:

```text
st = Tuple.second (List.foldl xs ( [], [] ) λx ( prev, st ) → ( x, List.push (List.push st prev) x ))
ys = List.map st λl → List.push l 1
```

Each `x` is stored once as `x` and once more as the next round's `prev`, so `st` holds each list twice. Under
the unrestricted rule the lambda's `sep(π₂.0, π₂.1[*])` is `elem⋆` against `elem⋆`, and it would be called
apart. `List.map st …` would then pass `within` under κ(xs[*]) and push one list twice in place. The fold
writes nothing, so §2.12's certificate never runs. Two values that came back through the feedback may come
from **one** earlier call, and the fold erases which call supplied each.

**Future proof task, excluded from the rule.** The narrowed proposal would discharge `sep(X,Y)` under
κ(xs[*]) only when X is the current call's own taken supply, Y comes through earlier feedback, and both
belong to the same traversal certificate. Two feedback-derived cells, and a cell already in the initial
accumulator, are excluded. The pinned index discipline suggests distinct positions, but the argument
must survive closure captures, joins, nested traversals and feedback substitution. It is not a proof.
S4's independent verifier must prove this rule and retain `FeedbackPrevTwice` plus every C.11 red refusal
before it can replace the current `lost`. The current accumulator storage writes remain accepted.

### C.10 Obligations used by the derivation

1. `elem(c·ι)` is made per **container** cell in `cellsAt(n,ε)`, not per element cell (§2.13.3).
2. `builderdone` is `written returned`: shortening its result writes `length`, and it preserves the
   builder's cells/children/per-path κ (§2.13.6).
3. The recursive call's pending `a` holds `others(π₁·ι_t)` while the split is in force. Its deeper taken
   supply refines that remainder; the conditions reduce to κ(π₁[*]) in the same traversal (§2.12).
4. A feedback supply's callsite demand sees the caller's initial accumulator. Duplication introduced only
   by later feedback must fail the independent preservation certificate (§2.11–§2.12), not be waved through
   by the initial demand.
5. `put`'s stored value contributes its per-path `excl` atoms as well as `apart`; fresh outer storage does
   not suppress those atoms (§2.9).

### C.11 Two traversals of one container (#1029)

Distinct `taken` splits justify disjointness only inside one traversal certificate (§2.2). Different
entries or a split whose `single` bit is cleared give `lost`; imports carry exactly those settled facts.

**Counterexample 1** (`TwoTraversalsShared`), with `xs : List (List Int)` exclusive and dead after `ys`:

```text
ys = List.push (List.map xs λl → l) (List.foldl xs [] λx _ → x)
List.map ys λl → List.push l 1
```

- `List.map xs λl → l`: `[*] = {elem(xs·(ι₁·ι_m⋆))}`, κ `yes` under κ(xs[*]) (one traversal).
- `List.foldl xs [] λx _ → x`: res `{site [], elem(xs·(ι₂·ι_l⋆))}`. The callback returns its taken supply.
- `List.push`: `apart{stored, base[*]}` compares `elem(xs·(ι₂·ι_l⋆))` with `elem(xs·(ι₁·ι_m⋆))`.
  The entry prefixes `(ι₁·ι_m)` and `(ι₂·ι_l)` differ. κ(ys[*]) is `lost`, so the second map's
  element write is refused `exclusive` (approximate).

**Counterexample 2** (`FoldOverFoldShared`):

```text
r = List.foldl xs (List.foldr xs [] λx a → List.push a x) λx a → List.push a x
List.map r λl → List.push l 1
```

- The initial accumulator's `[*]` holds `elem(xs·(ι_r·…))`.
- Each outer step stores `elem(xs·(ι_l·…))`.
- Gap 3 keeps the element condition lost; even a future narrowed rule must compare only one traversal.
- The `ι_l` against `ι_r` pairs are two traversals, so `lost`.
- κ(r[*]) is `lost`, and the element write is refused. Both folds stay accepted (storage writes).

**Counterexample 3** (`NestedTraversalShared`):

```text
each ws xs f = List.map ws (λ_ → List.map xs f)
zs = each [ 1, 2 ] xs (λl → l)
List.map zs (λinner → List.map inner (λl → List.push l 1))
```

- The inner traversal of `xs` runs once per element of `ws`.
- Its splits leave the lambda through `List.map`'s folded callback label, and the fold at `each`'s read-off
  drops the tail that showed that.
- Equal ordinarily folded prefixes do not certify one traversal: activations of the lambda may repeat it.
- The `single` bit is cleared where the lambda's own splits pass the folded callback label, so the write is
  refused. v1 refuses it as well.

**Every use of the rule, re-checked:**

| Use | Splits compared | One traversal? | Verdict |
|---|---|---|---|
| `mapHelp` (C.2) | `elem(π₁·ι_t)`, `elem(π₁·ι_rec⋆)` | yes: empty entry prefix; `ι_rec⋆` is after the entry | unchanged |
| `foldlFrom` (C.4) | the same pair; no κ atom compares them | yes | unchanged |
| `List.map` (C.3) | `within(ι_m⋆)` | yes: entry `(ι_m)`, ordinary fold | unchanged |
| `List.foldl`/`foldr` (C.5) | none in κ | — | unchanged |
| C.6 map rows: push, `λ_ → [1]`, `λ_ → shared`, `[x, x]` | `within` at a caller: entry `(ι_c·ι_m)`; the split is map's own and `single` | yes | unchanged |
| C.6 `edit` | at `edit`'s caller the prefix is `(ι_e·ι_c⋆·ι_m)`, `ι_c` ordinarily folded; the split is map's own supply, grafted into the lambda, not made by it, so it stays `single` | yes | unchanged |
| C.6 fold rows | κ already `lost`; the twins are refused by the certificate or by `env` | — | unchanged |
| gap 3 narrowed proposal | not enabled | — | element κ remains lost |
| a recursive caller that maps `xs` once per activation and stores the results under `[*]` | prefix `(ι_rec⋆·ι_c·ι_m)` carries a recursive fold | no | `lost`: an imprecision only where each activation maps another list |

C.8's verdicts for the core rows hold. The callers' discharge of `within` and `sep` is sound only with the whole *Traversals* rule, `single` bit included.

The frozen v1 baseline at `19714094f` refuses the two outer-fold counterexamples on `browser-inline`
and under enforcement (`exclusive`, approximate); on node its non-enforcing report still refuses them.
These fixtures protect v2's proof rule; they do not authorize edits to v1. Additional adversarial cases
include captured containers/elements, initial accumulators holding an element, callback results returning
captures, `λl → (l,l)`, and `maximum`'s `foldlFrom` call.
