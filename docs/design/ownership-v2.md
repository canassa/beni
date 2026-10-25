# The ownership checker v2 — design and implementation plan

*Draft 2026-10-25, revised the same day after two independent reviews. Part of #1006. The WHAT is
[`ownership-requirements.md`](ownership-requirements.md) (R-n.m below); this document is the HOW. Where the two
disagree, the requirements win and this document has a bug. The owner's decisions it builds on: the end state
(lists and records enforced on every platform); no algorithmic cap, only named resource limits no real program
reaches (§4.4); no copy fallback, warning or coarsening; deterministic output; time and memory linear in program
size, never in value size; the `Ref` loan model (#981); ordered `Dict` only (#961); room for #587 and for an
in-place shared cell type.*

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

Plus a soundness argument per rule (R-3), size linear in the program (R-7.2), modular summaries hashed with the
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
2. **Abstract values are hash-consed shape nodes over places**, with a `delta` node for a record update, a lazy
   `union` node for a join that cannot merge, and *widening onto the place graph* in every fixpoint unknown, so
   `w5`'s result is 17 nodes (#856), an `update` of N arms is O(N) (#716, #975), and every fixpoint ranges over a
   finite lattice (§2.12).
3. **Cells carry provenance and are singleton or summary**; refinements (`elem`, `others`, `level`, `below`) are
   materialised at a match or a destructive read (SRW focus) and their non-alias is a *condition*, so a taken
   element stored back refutes exclusivity (R-4.6.9), distinct fresh elements keep it (R-4.6.7), `List.map`'s
   result is exclusive when its callback returns owned (R-5.2.9), and a split on a parameter yields `xreq`.
4. **Exclusivity is a condition per node**, which is per *path* under a summary position (R-4.6.4), with one
   `apart{…}` atom per construction (#693) and the invariant I-κ of §2.14.
5. **Summaries are classes over a function type's places**, instantiated by grafting with a memo per node; a
   function parameter's class is a placeholder (`cb_j`) resolved at the call; a closure a class returns or supplies
   carries its own class (R-5.4.8, R-5.4.9). A class names no declaration: the room #587 needs (§2.10).
6. **Two fixpoint shapes, one driver**: a worklist over frames for groups and local functions, and sparse
   propagation of cells over per-path inclusion edges for a callback's feedback and the entry's model (Morphic
   I:114-171), both over finite lattices, no round cap (R-7.4).
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
step; a type variable, function type, foreign type or crossing primitive is a leaf. Computed by one memoised walk
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

**Identity.** Within a module a place graph is interned by `(kind, head, children place ids)` where the head is the
session `TypeId` of a nominal or foreign type, the field names (by text) of a record, the arity of a tuple. §36's
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

`Cell = (origin, kind, class)`; kind from the place it is made at; class ∈ {**singleton**, **summary**}.

| Origin | Meaning | Projection by `s` | Class |
|---|---|---|---|
| `site ι` | the object a literal, construction, copy, `Dict.empty ⊤` or lambda at ι makes, per activation | nothing (children) | singleton |
| `param πᵢ·q` | the object at canonical path `q` of parameter `i` on entry | `param πᵢ·(q·s)` canonical | singleton unless `q` holds `[*]` or `⟲` |
| `env x·q` | in a frame: the object at `q` of captured local `x` | `env x·(q·s)` | as `param` |
| `shared M.v·q` | the object at `q` of top-level `M.v` | `shared M.v·(q·s)` | as `param` |
| `result ι·k` / `esc ι·k` | the callee's `fresh k`/`esc k` at call ι | nothing | singleton, unless ι is inside a feedback loop (§2.12) |
| `cb j·q` | what function parameter `j` returned, at `q` | `cb j·(q·s)` | summary: `sep(cb j, cb j)` is always the deferred atom `distinct cb_j`, decided where the class is discharged (§2.9), so no round's `calls` decides it inside the class |
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

**Singleton or summary.** A singleton cell stands for one object per activation of its frame; a summary cell for
many (positions, levels, the results of a callback called many times, `⊤`). `sep(c, c)` for a singleton is
`shared`; for a summary it is the atom `distinct c`: for `cb j` it is **always deferred** — the atom `distinct cb_j`
stands in the class whatever the round's `calls`, and is decided only where the class is discharged (a call with
the actual's class in hand, or validation): with the final `calls ≤ 1` it is `shared` (one result stored twice);
with `many`, *the callback returns owned at every call* (the `owned cb_j` atom: every result provenance `fresh`, an
owned supply, or `cb j` itself, none at two result paths). So no κ a round reads off depends on an assumed
`calls`, and κ is joined round to round like every other component; for `elem`/`[*]` arrivals `excl` of the container; for `⟲`
levels `excl` of the value; for a `result ι·k` inside a feedback loop `yes` (each iteration's call allocates
afresh); for `⊤` `lost`. This is what makes `mapHelp`'s `put b i (func …)` store `cb₅`
exclusively when `func` returns owned (P1 of the second review; R-5.2.9, R-4.10.7).

**May-alias.** `alias(a, b)` ∈ {no, yes, under split ι}: `base(a) ~ base(b)`, where symbolic cells are `~` when
one canonical path is a prefix of the other (`⟲` matching any continuation), **except** that two paths diverging
at a `ctor` place on *different constructors* are alternatives and never `~` (one value has one constructor;
`π₂·status#Editing.2` and `π₂·status#Saving.1` are not a sharing of one argument, R-4.8.15; two *elements* built
with different constructors are two positions and are compared by `apart` at the construction); concrete cells
`~` when equal; `⊤` with everything; and when `a`, `b` descend from one split ι on different sides (`elem`/
`others`, `level`/`below`, two `below`s of distinct steps, two `level`s of distinct steps) the answer is *under
ι*: not aliases if the split's condition `κ` held at ι. A test that passes only *under ι* **relies** on κ(ι)
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

Hash-consed per walk (thesis §4.2; Chase–Wegman–Zadeck). A node denotes a function from paths to sets of
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
  shares the larger operand, O(k log) for k new cells). `reach(delta) = reach(base) ∪ reach(overrides)`,
  `reach(union) = reach(l) ∪ reach(r)`, computed once per node; a chain of k updates adding k cells costs
  O(k log), where a flat set per node would cost O(k²). Membership O(log).
- `join(n₁…nₖ)`: deduplicate, **group by base** (a bare node is `delta(n, ∅)`): one group of deltas over one base →
  one `delta(base, s ↦ join(overrides present, base's child))`, O(Σ|Oᵢ|); leaves with no children → one leaf with
  the set union; the groups left (one per distinct base, plus leaves) → a balanced `union` DAG over them,
  O(groups). No join multiplies sizes; a projection through a union costs O(groups) once per `(union, step)`.
- `put(n, s, m)`: `delta(n, [(s, m)])` when the `ε` object is the same after the write (an update), else a copy
  with one child changed (a construction's fresh base).
- `map(n, f)`: the functor relabelling cells, memoised per node, so a DAG stays a DAG (`w5`: 17 steps, #856).
- `leq(n, m)`, `eq(n, m)`: **coinductive** lockstep inclusion/equality, memoised per pair with the pair assumed on
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
| `call` | §2.11; a call of a *function parameter* πⱼ: the result leaf `{cb j·ε}` with the callee's class slot, each argument recorded as a supply `(j, k, node, point)` and used at ε, kind `call` | per the class `use`, kind `call` | call-site demands, edges |
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
evaluation-order sweep: it is unregistered, and a root with no holders decrements its children's live counts
recursively, so a set node with no live parent is skipped. `holdersOf(c)`: for `c`, its trie ancestors and (deep
demands) its trie descendants, walk the chain of set nodes keyed by that cell and climb their *live* parents to
the roots. Every set node visited is live and contains the cell (the chains hold live nodes only), so the cost is
O(live holders found × log C), not the scope, and the maintenance is O(nodes whose live count changes) per
registration or expiry, each node once per transition: at `bₖ = List.push aₖ 0` with N other bindings live, only `aₖ`'s set contains `site aₖ`, and a chain of
k record updates finds only `m_{k−1}` once `m₁…m_{k−2}` have expired. Then, for each holder, the paths at which it
holds the cell (a pruned walk of its node guided by `reach`), and §2.7's queries. Cost per demand O(holders found
× (log C + query)). The second review's `ys = r.a` then `send (Got r)` is found: `send` is deep, `param π₂·.a` is a trie
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
| `and(κ₁, κ₂)` / an atom | a hash-consed binary conjunction (O(1) to form; a chain of W stores is O(W)); flattened to a sorted atom run only when printed, compared or written, once per distinct condition |
| `shared` | fails exactly: one cell at two positions or two paths (`[ r, r ]`, `{ a = xs, b = xs }`, a taken element stored back) |
| `lost` | fails approximately: `⊤`, a conservative call, a spread of a variable after the base (R-4.6.1), a recast, a pessimistic class |

Atoms name **arrivals and summary cells only**: `excl c`, `sep c d`, `distinct c` (a summary cell's positions or
calls are pairwise distinct: `owned cb_j` for a callback result), `apart{c₁…cₙ}` (every `sep` over a set, stated
once), `keep cb_j` (the callback puts back what it was handed, at the same path, or a fresh value: "keeps shape"),
`writes cb_j`.

`sep(a, b)`: two singleton concrete cells, distinct → `yes`; one singleton twice → `shared`; a summary cell twice
→ `distinct c`; `⊤`/approximate → `lost`; two arrivals not aliasing → the atom `sep a b`. A construction sorts its
stored cells once: duplicates decide at once, the arrivals and summary cells among them form one `apart` group;
discharging an instantiated `apart` at a call is the same sort over the arguments' cells, O(n log n), the
arrivals among *them* one `apart` of the caller's own (#693, `ListOfParams`).

Where κ is set: a literal `[ v₁…vₙ ]` → per element path `p`: `and(deep of each vᵢ at p, apart{cellsAt(vᵢ, p)})`;
a construction → the base's κ lowered by each stored value (`apart{stored, base[*]}` and the value's deep
condition), a later spread of a *variable* `lost`; a call → `κ(res)` instantiated (atoms over `πᵢ·q` become the
argument's deep condition at `q`, `sep` the two arguments' separation, `owned`/`keep`/`writes cb_j` the actual
class's facts: oc §18.4); a `delta` → the base's κ lowered by the new field values; a storage permutation
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
| `res` | a shape over ρ's places whose cells are provenances `πᵢ·q`, `fresh k`, `esc k`, `shared`, `cb j·q`, `⊤`; `fresh` numbered by the canonical result path of first occurrence (two distinct sites at one path share a number, which only adds aliasing; their κ is published, not re-derived) |
| `κ` | per `res` node, atoms over arrivals (a parameter's own `excl` implicit) |
| `xreq` | the atoms the body relied on |
| `fun(j)` | `calls ∈ {0, ≤1, many}`; `supply(k)`: nodes handed as πⱼ's `k`th argument with `owned`, `taken` and κ; `need`; `seen`; `keeps`: the keep edges of §2.11 |
| `classes` | **a summary-local class table**: every `closure` node in `res`, `supply` or `use` (a lambda returned, a lambda handed on, a closure in a record) carries a `ClassId` into it, in normal form, serialised with the block (R-5.4.8, R-5.4.9, R-5.5.9); the fixpoint joins classes pointwise |
| `refs` | the `◆` cells of `Ref` places the body operates on, by provenance (`Ref.set/update/modify/get` directly or through a callee), for §2.13.7's re-entry rule |
| `writes` | one bit: the body or a callee has `W`/`S` on a parameter path, a capture, a `shared` cell or lets one escape — a write of something that *arrived*; a `Builder`'s fresh stores do not set it (R-5.13.1) |
| `once`, `limit` | as before: per function-typed result place; the pessimistic class past a resource limit |

**Lattice.** Pointwise: bits by inclusion; provenance shapes by `leq` (the lower order, `fresh k ⊑ esc k ⊑ ⊤`,
thesis §4.6) **after widening** (§2.3), so a shape ranges over at most one node per canonical path and the
lattice is finite; `owned ⊑ borrowed`; `calls 0 ⊑ ≤1 ⊑ many`; κ: `yes ⊑ and{A} ⊑ and{A ∪ B} ⊑ lost`, `shared`
beside `lost` and winning as a cause; classes pointwise, a class identified by its closure node's canonical position in the shape; `limit` above all.

**Read-off** (oc §16.3): `W` at `(i, q)` when a demand's base cells include `param πᵢ·q` (verdict irrelevant); `E`
from Esc; `A` from `res`; `R` from uses; `res = widen(map(A(body), f))` with `f`: `site`/`result` → `fresh k`/`esc k`,
`param` → `πᵢ·q`, `env` → `env x·q` (a lambda's class), `shared`/`cb`/`⊤` kept, a refinement → its base's image,
approximate; `fun(j)` from the recorded supplies and keep edges; `classes` from the closure nodes reached. A
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
   → the actual for πⱼ′ must return owned), **need**, **keep** (below), **seen** (an actual writing a parameter handed
   where `S` loses sight → `pending`, R-5.5.3).
5. **Returns owned**: every result provenance `fresh`, a parameter supplied owned and not escaped, or `cb j` itself,
   none at two result paths (thesis §3.7); owned supplies relied on are followed to the caller (oc §16.4 CK-233).
6. **Result**: `map(S.res, inst)`: `πᵢ·q ↦ proj(aᵢ, q)` (grafting), `fresh k ↦ result ι·k`, `esc k ↦ esc ι·k` (escaped),
   `shared`/`⊤` kept, `cb j·q ↦` the actual's `res` with its `π_k` replaced by `S.supply(k)` and `env` by the
   captured nodes; a feedback supply is a fixpoint (§2.12); a closure node in `res` carries its class from `S.classes`
   instantiated the same way. Crossing → `∅`.
7. **Conditions**: κ(res) instantiated; `S.xreq` discharged on the arguments, reported on that call's line (R-4.6.6).

**Calling a function parameter** πⱼ in the body (the rule v1 lacked where #982, #1000, #1001 lived): the result is
the leaf `{cb j·ε}`; each argument's node `Nₖ` is recorded as a supply `(j, k, Nₖ, p)`, its cells used at `ε`.
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
R-5.5.2 and R-5.4.5 follow from the lambda rules. A writing function value leaving sight is **pending** at that
point, naming where (R-5.5.3), except a top-level alias of a writer (R-5.5.6).

### 2.12 Fixpoints and the pre-pass

Two instance shapes, one driver (`Fix.zig`), both over finite lattices with no round cap (R-7.4, R-5.6.3):

| Instance | Unknown | Shape | Step |
|---|---|---|---|
| a recursive group of declarations (R-5.6.1) or a block's local functions (oc §18.7) | each member's class | **worklist over frames, cells by propagation**: a walk of a member records, beside its shape, the inclusion edges a recursive call makes (argument node → callee parameter path, callee result path → call result); the cells then flow along the whole group's edges by the sparse propagation below, so growing cell sets never cause a re-walk. The `R`/`A`/`E`/`W` bits (with `F` and `S`) flow along the same edges in the other direction (a callee's `W` at `π_k·q` becomes `W` on the argument node's cells at `q`, hence on the caller's parameter path they came from), and so do the `callsite` demands they imply, so `rot a₁ … aN n = … rot a₂ … aN a₁ (n − 1)` records N edges once and its `W` reaches every parameter by propagation, not by N re-walks. After propagation the frame's resolution sweep (§2.8) runs once over all demands, the propagated `callsite` ones included, and reads off `supply.owned` and the keep edges, which depend on it. A member is re-walked, in the SCC's reverse postorder reading the latest assumptions (Lean 263-326; Roc's queue), only when a callee's facts of *shape* changed: `calls`, `need`, `seen`, a `supply.owned` bit or a keep edge (monotone: owned → borrowed, edges only added, bounded by the callee's own supplies), κ's atoms, a class's structure, a `res` node's shape (cells arriving at an existing node are not a shape change) | `xᵢ₊₁ = widen(xᵢ ⊔ F(xᵢ))` per member; cells and bits by propagation; owned/keeps by the sweep |
| a callback fed its own result (R-5.3.2, `Dict.merge`'s cycle R-5.3.6) and the entry's model (§2.13.4) | the `cb`/`M` node and its κ | **sparse propagation over per-path inclusion edges** (Morphic I:114-171): the step's `res` is read once as edges `source path ⊆ target path` (a `delta` over π₂ gives one edge per override; `π₂.f_{k-1} ⊆ π₂.f_k` for the rotate family); the edges' graph is condensed into SCCs and the cells are pushed along it in topological order with persistent sets, so each cell crosses each edge once and a set that grows by one shares the rest | push the difference, never re-instantiate the whole |

Termination: finite lattices (cells bounded by canonical paths × sites; shapes widened to one node per canonical
path), every step a join (thesis §4.6). Every component is joined round to round, κ included: the one non-monotone case — a `cb` cell whose `sep(c, c)`
would flip from `shared` to an atom as `calls` grows — does not arise, because §2.2 keeps `distinct cb_j` deferred
inside every class and a group-internal call instantiates the assumed κ with that atom intact (`mapHelp`: round 1
reads off κ(res) = `distinct cb₅ ∧ apart{cb₅, π₆[*]}`, round 2 instantiates the same at the recursive call and
reads off the same; at `List.map`'s caller the atom is discharged against the lambda's class). Validation: one more walk against the final assumptions must read off
`F(x) ⊑ x` (coinductive `leq`) and is the walk whose demands are reported. Inside a group a member's fresh numbers
are by result path, the same in every round (oc §16.6 as amended). `go n t = … go (n − 1) (Node t [ n ] t)` grafts
one level per step without widening; with it, `res` is the cyclic `Node(self, {fresh, π₂·#Node.1}, self) ∪ π₂` after
two steps. Polymorphic recursion (R-5.6.2) adds nothing: a call at another type grafts through `proj`/`recast`.

**The BIR pre-pass** (`Prepass.zig`, L3, reads the BIR, the dispatch table and the graph): SCC edges = `refs` ∪
the callees `Dispatch` resolves for `method_call` (BIR adds no `refs` edge for them, `Bir.zig:329-330`) ∪ derived
`eq`/`compare`; alias chains of function values (R-5.5.6); read counts of private parameterless values (R-4.9.3);
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
   R-5.10.7 are to be amended to name them and P-sync (§2.13.7) — a requirements change, listed in §9. Derived `eq`/`compare` have no body and
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
    return-type dispatch, a non-function result and a class not past a limit, the reader sees the value's `site`
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
    each take `tₖ` bound outside the callback as `List.get xs e'ₖ`, a pattern, or `List.drop xs e'ₖ ▷ List.head`
    (a view of the same source then its head) from the *same* exclusive source — **the very local the `indexedMap`
    maps**, not a view, `drop` or copy of it, else a take from `xs` lands at another offset in `List.drop xs 1` —
    used in exactly one arm; and the
    guard indices `{eₖ}` and the take indices `{e'ₖ}` are the same set (locals by identity, literals by value).
    Then position `eₖ` receives exactly the take whose index is another guard, every other position keeps its own
    row, and the rows are permuted — also when two guard locals are equal at run time, since the first matching
    arm decides and the positions coincide (so every taken row's own position is overwritten: the swap `i == a → rowB; i == b → rowA` with `rowA =
    get a`, `rowB = get b`). A take whose index is not a guard (`dup`'s `i == a → rowB`) puts one row at two
    positions and is refused `exclusive`, as is one cell in two arms, an unguarded arm, or a take nested under
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
`level`/`below` likewise; `loan c·ι` the objects of `c`; `⊤` all. `γ(n)` as §2.3; `γ(Σ)` the configurations where
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
yields `⊤` and escape, O1, O10; a limit the pessimistic class, O11), a pattern match (O6), a record update (O7), a
join (O4), an escape (O8, deep), a row (O9). ∎

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
| O11 | *No bound accepts* | §4.4, R-3.7 |
| O12 | *Hoisted reads are this frame's own:* every hoist is a `field`-kind use the index recorded (a field chain, a record pattern, a field capture of a closure created after the write), never a callee's or a whole use | §2.7, §3.7 |
| O13 | *Constructions keep I-κ:* a literal's or construction's κ is `yes` only when the stored cells are pairwise apart per path and each stored value's deep condition holds; a stored refinement of the base's own `[*]` is `shared` | §2.9 |
| O14 | *Instantiation keeps I-κ:* κ(res) instantiated is `yes` only when every atom holds of the actual arrivals and summary cells (`distinct cb_j` ⇔ returns owned); a `delta`, a storage permutation and a `taken` write-back lower κ exactly as the stored value's condition says | §2.9, §2.11, §2.13.15 |
| O15 | *Join lowers κ:* κ(join) is below every member's κ (`and{A} ⊔ and{B} = and{A ∪ B}`), and a union's κ is the join of its members'; computed by `Cond.lower` where `Transfer` and `Summary` join, since `Shape.join` knows no κ | §2.3, §2.9, §2.10 |

The Lean oracle stays advisory (R-8.11).

---

## 3. Data-oriented design

`fast-compiler.md` §5's rules hold in every table: `MultiArrayList` columns, `u32` ids as `enum(u32)` with
`.none = maxInt`, `extra: []u32` sidecars, no pointer in any table, no per-node allocation, one arena per walk, no
`HashMap` keyed by a dense id (`src/rules_test.zig`; v1's `summary_bytes.zig` allowlist entries go with it). All id
newtypes live in `Ids.zig` (L0), all record types that cross layers (`Use`, `Demand`, `Obligation`, `Supply`,
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
intern      : hash of (kind, head, (step, child) run) → PlaceId   -- composite key
by_var      : stamped column Var → PlaceId   (the type walk's memo; `stamped.zig`)
path_bytes  : []u32 interned canonical paths (`⟲` a reserved step kind); `pathOf(root, steps) → PathId` in O(len)
```

### 3.2 Cells (`Cell.zig`)

```
Cell.Table (per walk)
  origin   : u8     site | param | env | shared | result | esc | cb | msg | top | elem | others | level | below | loan
  kind     : u8     list | dict | record | ref | closure | opaque
  class    : u1     singleton | summary
  a, b     : u32    site/result/esc/refinements: instruction, k or parent CellId; param/env/shared/cb/msg: index + PathId
  place    : PlaceId
  parent   : CellId   the trie parent: the path minus one step, or the refined cell; .none at a root
  children : Range    into `child_cells`: the trie children in first-sight order (the descendants of a cell the program named)
intern     : hash of (origin, kind, a, b) → CellId
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
intern     : hash of (kind, place, cells, a-run, b) → NodeId
memo_proj  : stamped column NodeId → inline cache of (step, NodeId)
memo_join  : hash of the sorted member tuple → NodeId;  memo_leq / memo_eq: hash of (NodeId, NodeId) → u8 (with the coinductive assumption bit)
memo_map   : stamped column NodeId → NodeId, one stamp per `map`
```

κ is **not** a column of this table (D1): `Cond` owns it (§3.4). Holders are found through `reach` and the scope
(§2.8), so there is no reverse index to keep in step.

### 3.4 Conditions (`Cond.zig`)

```
Cond.Table (per walk)
  kind    : u8      yes | and | atom | shared | lost
  a, b    : u32     and: (CondId, CondId); atom: (atom kind: excl | sep | distinct | apart | keep | writes, operands)
groups    : interned sorted CellId runs (`apart` members)
intern    : hash of (kind, a, b) → CondId
kappa     : column NodeId → CondId   (κ, owned here; dense per walk, cleared with the walk arena)
flat      : memo CondId → sorted atom run (print, compare, block)
memo_sep  : hash of (CellId, CellId) → CondId;  memo_deep: stamped column NodeId → CondId
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
  limit    : u8 + u32
```

Summaries live in the module arena in **normal form**: cells relabelled to provenances in canonical order, nodes
renumbered by a canonical DFS (children in step order, unions by member order), classes in reference order, so
equal summaries are byte-equal (determinism; the fixpoint's stop test is `eq`).

### 3.6 Blocks (`Block.zig`)

One block per module, in the interface record (`Interface.ownership`, hashed with it: R-5.7.2) and in the cache
entry (R-5.7.4); format `OWN2` v1, bumped by every rule change. Names nothing by session id: modules by package and
dotted name; declarations by BIR index; constructors by module and constructor-table index (BIR's, then each
tagged schema's: oc §28.4); **places structurally** (`kind`, head as `package·module·type` or field names or
arity, children) so a reader re-interns them onto its own graph; paths as canonical steps; opaque slots by number.

```
head       : "OWN2", version, module table, string table, place table (structural)
directory  : per declaration (BIR index, offset, length) — summaries read lazily, one at a time (oc §28.4 #814)
summary    : cells (origin, kind, class, a, b over the local numbering), sets, conds/atoms/groups, nodes
             (kind, place#, set#, κ#, children/overrides/union), the class table (each class the same encoding), the Class record
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

Ids in walk order (parameters, then instructions; cells in first sight; nodes by creation; places by the type walk
in declaration order). Nothing printed is an id: source names, canonical paths with field names, normal-form
summary text with fields in name-text order; blocks write names and structural places; ties go to source order
(R-7.6). A module's result is a function of its BIR and its imports' blocks (R-5.7.5, R-7.7).

### 3.9 Arenas and lifetimes

Per worker: a **module arena** (normal-form summaries, block, report, channel) released at publication; a **walk
arena** (cells, nodes, conds, sets, uses, demands of the group being walked) reset after each group's validation
round. Growable lists and explicit stacks only (R-7.12).

---

## 4. Complexity

|P| the module's BIR, |T| its types as the store holds them, |S_f| callee f's summary, D demands, H live holders
per demand, U uses, C cells.

### 4.1 Per phase

| Phase | Bound | Why |
|---|---|---|
| place graphs | O(\|T\|) | one memoised walk per store variable |
| pre-pass, region tree | O(\|P\| + dispatch sites) | Tarjan + counting sort; one pass over references and sites |
| forward walk | O(\|P_f\| + Σ_calls \|S_callee\| + Σ_updates \|F\| log F) nodes | O(1) nodes per instruction; one delta per update; `map` once per summary node; a literal costs its width, which the program wrote |
| `reach` and the inverted index | O(new cells · log) per node; O(nodes whose live count changes) per holder registration or expiry | persistent union shares the larger operand; a chain of k updates is O(k log); live-count transitions link and unlink chain entries once each |
| liveness index | O(U · depth · log U) | each use entered at its ancestors; sorted per (local, path) |
| resolution | O(Σ_D (path + trie descendants + H_D · (log C + (depth + \|F\|) · depth(regions) · log U))) | the inverted index over persistent-set nodes with expiry: each set node visited is live and holds the cell; untouched fields never read |
| conditions | O(1) per `and`; a flatten once per distinct condition; `apart` O(n log n) per construction | hash-consed conjunctions |
| join | O(k + Σ\|Oᵢ\|) for k arms; a projection through a union O(groups) once per (union, step) | §2.3 |
| `widen`, `leq`, `eq` | O(\|n\|) / O(\|n\| + \|m\|) when shapes agree, O(\|n\|·\|m\|) pairs at most, memoised | coinductive, per pair |
| group / local fixpoint | re-walks ≤ members × the height of the *shape* lattice (`calls` 2, `need` 1, `seen` 1 per function parameter, κ's atoms, class structure, `res` shape — each bounded by the member's own text, not by the group's parameter count); cells and `use` bits flow along the recorded edges by propagation, O(E · log C) | §2.12: a walk yields a shape and an edge graph; cells and bits propagate; `rot`'s rotating `W` costs N edge pushes, not N walks of N |
| feedback / entry fixpoint | O(E · log C): E per-path inclusion edges (one per override of `res(update)`, one per argument of a recursive call), one persistent union per edge in topological order sharing the larger operand, so a chain whose sets nest costs O(E log C) however many facts they denote | sparse propagation over the condensed graph |
| block write/read | O(\|S\|) per summary, read lazily | §3.6 |

**Linear in the program.** Every table is sized by what the program writes: nodes by instructions and callee
summaries, places by types, cells by canonical paths the program named × sites, atoms by constructions, edges by
overrides. A value's size never appears: a DAG node stands for every path reaching it, a `union` for a join not yet
asked for, a persistent set for a set that grew by one. The one honest superlinear family is a fixpoint whose
*facts* are quadratic — the rotate `update` (`S_k → { model | f_k = model.f_{k−1} }`) makes `f_N` hold N
provenances, Θ(N²) facts — which sparse propagation represents in O(N) shared sets (each `f_k`'s set is
`f_{k−1}`'s plus one) and computes in O(N log N): one union per edge, the union sharing the larger operand, so
the facts are never enumerated and §7.6's ≤ ×5 bar from N = 64 to 256 holds. A recursive function rotating N
parameters (`rot a₁ … aN n = … rot a₂ … aN a₁ (n − 1)`, writing `a₁`) is the same family inside a group: its walk
records N argument→parameter edges once and both the cells and the `W` bit flow along them, N pushes in all,
with no re-walk, since nothing of shape changes. `WideModel`,
`WideModelArms`, `EntryRelay` and Conduit have independent arms and are O(N). §7.6 pins all three families.

### 4.2 The six places v1 went superlinear

| v1 | v2 |
|---|---|
| #856: `w5`'s result at 2¹⁶ places | 17 hash-consed nodes; `map` 17 steps; `widen` is the identity on a non-recursive type; `p/DeepTupleDag` checks with no limit line |
| #955: `foldr` with a cyclic accumulator type never settles | the cyclic store variable is one place; `[*]` of it is itself; the feedback edge `cb ⊆ π₂ ∪ [*]` settles in one push; `p/CyclicFold` clean |
| #693: N(N−1)/2 `sep` atoms | one `apart` group of N cells |
| #716: the entry ×6.8 from N = 64 to 256 | `res(update)` is a delta over π₂ per arm (a tuple node around it for `model × Cmd msg`, its `.0` the fast path), joined n-ary in O(N); N inclusion edges, one push each |
| #975: Conduit +41 % | the same mechanism plus lazy blocks; measured at S9 against +10 % |
| `ListOfParams` O(n⁴) | `and(excl π₁…πₙ, apart{π₁…πₙ})` gathered once |

Also from R-7.2: `MutualCycles` one 12-node place graph; routed-app and the 256-widget application: summaries
bounded by signatures, blocks read per declaration; interface reads O(modules); `Schema.read` lazy; no width
anywhere refuses.

### 4.3 Memory

Walk tables proportional to §4.1's counts, reset per group; summaries O(|S|); blocks O(Σ|S|); persistent sets and
conditions shared.

### 4.4 Resource limits

R-7.4: no algorithmic cap. The only limits are on what a program *writes*, each a loud `ownership_limit` with the
measured value (R-6.11), each with a gate test (`own_limits_test.zig`, S9) that the corpus, the examples and the
research applications stay at or below a tenth:

| Limit | Value | Bounds | Why |
|---|---|---|---|
| `record_fields` | 65 536 | fields of one record type | a `Step` payload is 28 bits; a dense children run |
| `tuple_arity` | 65 536 | components of one tuple | the same |
| `constructor_args` | 65 536 | arguments of one constructor | the same |
| `type_places` | 2²⁴ | places of one module's table | the `PlaceId` space a block addresses |
| `path_steps` | 65 536 | steps of one canonical path | ≤ 2·places of a type |
| `declaration_insts` | 2³¹ | instructions of one declaration | BIR's `u32` |
| `block_bytes` | 2³¹ | one module's block | the entry's section length |

v1's eleven caps (R-7.5) have no counterpart; their fixtures get ordinary verdicts (R-8.1).

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
| `Ids.zig` | 0 | every id newtype (`PlaceId`, `PathId`, `CellId`, `SetId`, `NodeId`, `OverId`, `CondId`, `SplitId`, `ClassId`, `UseId`, `DemandId`) | the types | — | ≤ 150 |
| `Place.zig` | 1 | place graphs, steps, canonical paths, holds, opaque slots, structural encoding | `Table`, `of`, `child`, `steps`, `kind`, `holds`, `pathOf`, `encode`, `decode` | Ids | ≤ 1 000 |
| `Cell.zig` | 2 | origins, kinds, class, the trie, interning, persistent sets, splits, `alias` | `Table`, `intern`, `parent`, `children`, `alias`, `Set.{union,member,insert}` | Ids, Place | ≤ 800 |
| `Facts.zig` | 2 | the shared records: `Use`, `Demand`, `Obligation`, `Supply`, `Keep`, `Verdict`, `Cause` (R-6.3's order) | the types | Ids | ≤ 300 |
| `Prepass.zig` | 3 | SCC edges incl. dispatch callees, alias chains, read counts, `eq`/`compare` decls, spread chains, `withDefault` shapes | `run(bir, dispatch, graph) → Facts.Prepass` | Ids, Facts | ≤ 600 |
| `Shape.zig` | 3 | nodes and their operations, `reach`, `widen`, coinductive `leq`/`eq` | `Table`, `leaf`, `node`, `delta`, `recast`, `union`, `proj`, `cellsAt`, `put`, `join`, `map`, `reach`, `widen`, `leq`, `eq`, `expand` | Ids, Place, Cell | ≤ 1 500 |
| `Regions.zig` | 4 | region tree, points, compatibility, guards, virtual `withDefault` arms | `Tree`, `build`, `compatible`, `rangesAfter`, `guard` | Ids, Facts, Prepass | ≤ 450 |
| `Cond.zig` | 4 | κ column, atoms, `apart`, `sep`, deep conditions, instantiation, rely | `yes/lost/shared`, `and`, `atom`, `kappa`, `deep`, `sep`, `lower`, `instantiate`, `rely`, `flat` | Ids, Cell, Shape | ≤ 1 000 |
| `Summary.zig` | 5 | the class record and table, lattice (κ joined through `Cond`), normal form, equality, pessimistic, text | `Class`, `join`, `leq`, `eq`, `normalize`, `pessimistic`, `print` | Ids, Place, Cell, Shape, Cond | ≤ 1 200 |
| `Liveness.zig` | 5 | the use index and queries | `Index`, `build`, `useAfter`, `useUnder`, `lastUse` | Ids, Facts, Regions, Shape | ≤ 700 |
| `Rows.zig` | 6 | words → classes; constructor, derived-method, markup and schema classes; entry shapes; `Send` | `fromWords`, `ctorClass`, `derivedClass`, `entryShape`, `schemaRow`, `markupRow` | Ids, Place, Cell, Shape, Cond, Summary | ≤ 1 100 |
| `Calls.zig` | 7 | instantiation, callback edges, keep edges, function values' classes | `apply`, `classesOf`, `callParam`, `keepEdges` | Ids, Facts, Cell, Shape, Cond, Summary, Rows | ≤ 1 500 |
| `Demands.zig` | 6 | the six conditions, holders, causes, verdicts | `resolve`, `holders` | Ids, Facts, Cell, Shape, Cond, Liveness | ≤ 1 200 |
| `Transfer.zig` | 8 | one case per BIR tag; the frame state | `eval`, `Frame` | Ids, Facts, Place, Cell, Shape, Cond, Regions, Rows, Calls | ≤ 1 800 |
| `Fix.zig` | 8 | the two fixpoint shapes and validation | `worklist(Instance)`, `propagate(Edges)` | Ids, Cell, Shape, Cond, Summary | ≤ 500 |
| `Walk.zig` | 9 | one frame: walk, index, resolve, keep edges, read off | `walk(decl) → {Class, []Demand}` | Transfer, Demands, Fix, Liveness, Calls, Summary, Facts | ≤ 1 500 |
| `Groups.zig` | 10 | the module: pre-pass, order, limits, transfer, summary table | `checkModule`, `ensureClass` | Walk, Fix, Prepass, Summary, Facts | ≤ 900 |
| `Entry.zig` | 10 | the entry protocol at a constructor call | `check(Obligation.entry)` | Calls, Fix, Demands, Rows, Cond, Shape | ≤ 900 |
| `Block.zig` | 11 | class ⇄ bytes, lazy directory | `write`, `open`, `summary`, `version` | Summary, Place, Cell, Shape, Cond | ≤ 1 000 |
| `Hoists.zig` | 11 | the lowering channel, format v2 | `Table`, `Builder`, `write`, `read` | Facts | ≤ 500 |
| `Message.zig` | 11 | diagnostic text and JSON fixes (ported from v1 over `Facts.Demand`) | `build`, `limit`, `code` | Facts | ≤ 900 |
| `Report.zig` | 11 | dump lines and totals | `print`, `totals` | Facts, Summary | ≤ 600 |
| `Ownership.zig` | 12 | facade | `Input`, `run`, `ModuleReport` | Groups, Entry, Block, Hoists, Message, Report | ≤ 300 |
| `Enforce.zig` | 13 | the Driver hook, inputs, interface and cache sections (ported) | `checkModule`, `inputs` | Ownership, Block | ≤ 450 |
| `rules_test.zig` | — | the gate below | — | — | — |

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
| grouping (R-6.10), limits (R-6.11) | one diagnostic per (position, verdict, cause, detail); one `ownership_limit` per declaration and limit; dependent refusals carry `limit`; a pending line never hidden |
| JSON (R-6.6) | the same text plus each code fix as a machine-applicable edit (span, replacement) |

Reported modules are the application modules this run checked (R-6.4). `check` fails with the ownership codes alone
exactly when the report has a refused, pending or limit line (R-8.1). Under `--release --allow-debug` the diagnostics
are identical and nothing is written (R-7.11).

---

## 7. Verification

1. **Corpus and pending fixtures** (R-8.1, R-8.2). `tests/corpus/ownership/`, every `build/bad/` and `check/bad/`
   fixture with a §6 code, `run/` and `browser/` unchanged; goldens compared on verdict and count lines (R-7.15).
   `tests/pending/ownership/` — the 45 fixtures of PR #1008 (CK-262 to CK-311) — is v2's acceptance; Appendix B
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
7. **Rule mutations** (R-8.7): `-Downership-mutation=<rule>`; `zig build test-own-mutations` requires each to fail a
   fixture; every trusted word's flip fails its pinning fixture. **Limits gate** (R-7.4): `own_limits_test.zig`.
8. **Lists independent of records** (R-8.6): `--ownership-records-lost` keeps every list line byte-identical.

---

## 8. The implementation plan

PR-sized slices in dependency order; acceptance names fixtures (`o/`, `p/` as in the requirements); estimates are
implementer-days under the owner-away rules (one `@claude` review per PR). Everything is behind the hidden
`--ownership=v2` until §8.2. **#961 (ordered `Dict`)** is open and held by the v1 freeze; it lands *on v2* at S8:
its runtime half is rebased, its ownership half rewritten as words.

| # | Slice | Builds | Acceptance | Deps | ∥ | Days |
|---|---|---|---|---|---|---|
| S0 | **The arbiter** | the list sanitiser beside the record one (§7.3), `test-records-in-place` and its list twin, `--records-in-place`, `--diff` in `bench/ownership-everywhere.mjs`, v1 behind `--ownership=v1\|v2` | the sanitiser runs `run/` and `browser/` clean under v1 on `node` and `browser-inline`; the diff prints three lists | — | S1, S2 | 7 |
| S1 | **L0–L2** | `Ids`, `Place`, `Cell` (trie, persistent sets, splits, `alias`), `Facts`, `Prepass`, `Shape` (`union`, `widen`, coinductive `leq`), `Regions`; `rules_test` (layering, sizes, fences, dense-id); the §7.5 cross-checks for these | `zig build test` green; unit tests: `w5`'s DAG at 17 nodes, a cyclic type one place, `widen` on `go`'s shape, a chain of k deltas O(k log), `alias` on refinements returning a split | — | S0 | 6 |
| S2 | **L3–L4** | `Cond` (κ column, per-path), `Summary` (classes table, lattice, normal form, print), `Liveness` (by path, lazy callee use-node), `Rows.fromWords` for today's words, derived-method and constructor classes | unit tests; `Summary.print` reproduces v1's `summary` grammar; `ListOfParams`' condition O(n); the use index answers the four queries of §2.7 | S1 | S0 | 5 |
| S2b | **Words, the spread fact, core in-process** | the four words through lexer/parser/lowering with `misplaced_ownership_word`'s rules; `Bir.Spread` recorded by `Lower`; the nominal `Send` type and `Send.to` in the browser platforms (every `send m` → `send.to m`); `core/List.beni`'s array primitives worded as R-5.10.8 asserts them (`push`, `set`, `swap`, `pop`, `insertAt`, `removeAt`, `append`, `cons`, `copy`, `length`, `at`, `view`, `put`, `traverseAt`, `focus`), the `Js.*` surface of R-5.10.9, `Dict.beni`, `Ref.beni`, `Deferred.beni`, `Log.beni`, `Task.beni` worded; `o/word-bodies.txt` extended to `taken` callers; the worked derivation of `mapHelp`/`foldlFrom` in §2.13.16; **a minimal `Block`** (write/read of a normal-form class with structural places, no lazy directory, no cache section) published through the existing hook so core's inferred classes reach an application module in the same session | `zig build gates` green under v1 (words erased, R-5.10.5); `cb/core/MisplacedOwnershipWord` extended; the derivation reviewed; a block round-trips | S2 | — | 7 |
| S3a | **Lists in one declaration** | `Transfer` (literals, spread chains, patterns, updates excluded, calls of worded rows only), `Demands`, `Walk` without groups, `Report`, `Message`, the facade and the ported `Enforce` hook under `--ownership=v2` (so core's worded classes reach a module through S2b's block); a declaration whose body uses a construct not yet built gets the pessimistic class behind the hidden flag, never a refusal, until S5 | whole fixtures with no callback, closure or record demand (records only as literal containers): LaterRead, StoredTwice, Spreads, SelfSpreads, Split, ViewAliases, Nest, PathCut, ParamHole, DeeperLevel, MarkerAcross (each calls only `push`, `set`, `copy`, `length`, checked by grep); `p/DeepTupleDag`. Fixtures with a callback, closure, builder or record line stay red until S4/S5 (Accumulator, Disjoint, Prepend, PrependFresh, Toplevel, Binders' `Maybe.andThen`, OneListTwoLevels' `concat`) | S2b | — | 6 |
| S3b | **Declarations call each other** | `Calls` for summarised declarations (W/E/A, `res`, κ instantiation, `xreq`), `Groups` with the worklist `Fix` **and `Fix.propagate`** (cells and bits along a group's edges), levels, initialization transfer, `eq`/`compare`'s `writes` | ReturnsFresh, ReturnsArg, CallerSide, MutualTypes, MutualCycles, LevelLimit, LevelPlaces*, AliasWriter (Recursion's `List.close` waits for S4); `p/MutualListField`, `p/WriteOneLevel`, `p/AliasWriterCall`; the R-5.13.1 fixture; R-7.6 #428. RecursiveFunctions, FoldLevels and Initialization* need S4/S7/S8 and stay red | S3a | — | 6 |
| S4 | **Callbacks, closures, folds** | `callParam`, supply/need/keep edges, returns-owned, the sparse feedback fixpoint, function values and pending, once closures, local groups, `withDefault`, carried classes | Callbacks, Need*, CallbackKeeps, ConditionalCallbackKeep, FoldAccumulators, FoldKeepsInner*, Once, Clo*, ClosureCapture, CapturedParam, SlotInLambda, LambdaParamNeed, CarriedLambda, CarriedFold, LocalGroups, PolyRec*, MergeCallbackCycle, MaybeDefault, ResultDefault, UnknownCallee*, Accumulator's fold, Prepend's `map`, Disjoint's `capture`; `p/CyclicFold`, `p/NeedOuterOnly`, `p/EditAnsweredList`, `p/OnceOtherHolder`, `p/CalledTwicePusher`, `p/JoinedFunctionValue`, `p/PatternStoredBack`, `p/ExclusiveFreshHelper`, `p/UpdateReturnsHeld`, `p/AppliedLambdaRecursion` (R-7.12), RecursiveFunctions, Recursion, Binders, OneListTwoLevels, Accumulator, Disjoint, Prepend, PrependFresh | S3b | — | 8 |
| S5 | **Records** | record cells, `delta`, `update` demands, per-field Dead with `field`/`call` use kinds, hoists and `Hoists` v2 (constructor step), record κ through the kind filter, `Record.copy`, once closures over records, field captures | every `Record*` fixture, `run/RecordHoistValues`, `run/RecordInPlace*`, the `.in-place` fixtures; `p/RecordSplitPushBack`, `p/RecordWriteBeforeKeep`, `p/RecordKeptInLiteral`, `p/RecordInnerKept`, `p/RecordWrapperRead`, `p/RecordProvenanceCallbackResult`, `p/RecordCopyOpen`, `p/RecordIndexExchange`, `p/ReturnedLambdaWrite`, `p/OnceLaterArgument`, `p/PrependFreshRecord`, Toplevel; R-4.8.7's fixture | S4 | — | 7 |
| S6 | **Modules, blocks, cache, core** | `Block` completed (class tables, lazy directory, versioning), the cache entry section, firewall test, core and platform facts in the checked core, `dump` of embedded core | CrossModule, ApartAcrossModules, OpaqueSlots, WideCtorBlock, SchemaCtorBlock, SchemaMemberExt, SchemaCtorCached, every `.cached` fixture, `cache_test`; core and every platform clean under v2 (R-1.10, R-8.4) | S5 | S7 | 5 |
| S7 | **Entry, sends, markup, schemas, casts** | `Entry` (both protocols, the sparse model fixpoint, the invariant), `Send.to` as a worded call, markup rows, schema rows, `try`'s early return, `recast` | Entry*, HostedEntry*, WideModel, WideModelArms, SplitArmsJoin, OwnedSend, SendInPayload, NestedLambdaSend, SubOnShared, Http*, RandomGenerate, EntryUrlTaggers, Conduit, ViewEventPayload, Question, Schema*, core/*Cast*; `p/ConduitEntryRecords`, `p/SendRecordObjects`, `p/ListenTopLevelStart`, `p/PushTagger`, `p/RecordForItem`, `p/RecordSchemaRun`, `p/RecordVariantMove`, `p/RecordProvenance{CtorValue,EntryPage,SameVariant,TopLevelOk}`, `p/SchemaIssuesFresh`, `p/SchemaIssuesExclusive`, Initialization*, FoldLevels | S5 | S6 | 8 |
| S8 | **`Dict`, `Ref`, `Log`** | #961 rebased onto v2 with its `Dict` rows as words; `Ref`/`Deferred` loans, `refs`, the suspension rule via `effectAt`, P-sync pinned per platform; `Task.callback`'s `Resume`; the worded `Js`/`Task`/`Log`/schema surfaces re-justified | DictFocus, DictValueWritten, DictTupleFocus*, Permutations, WriteExtents; `p/DictFocusGrow`, `p/DictHelperAlias`, `p/DictRecordAlias`, `p/DictTupleAlias`, `p/CopyApart`, `p/RefOwnsContents`, `p/LogAnnotateUpdate`; R-5.10.12's fixtures; Words, WordsBrowser, JsPure, TaskWords, core/JsWords | S4, #961 | S6, S7 | 7 |
| S9 | **Parity, cost, gates** | the whole-corpus diff to zero unjustified differences; every pending fixture green or re-filed; `test-perf` scenarios of §7.6; the mutation suite; `own_limits_test`; the fuzz sweep's first 10⁵ programs; the full cross-check run | R-8.1–R-8.8 whole; R-7.1's +10 % or a report | S6, S7, S8 | — | 8 |
| S10 | **Switch-over and deletion** | §8.2 met; v2 default; `src/own/`, `--ownership=v1`, `--ownership-everywhere` and the `"lists"` key deleted; `src/own2/` renamed; goldens' v2-own lines blessed; `skills/beni/` and `language.md` §10 updated (words, `Send.to`); O4a (#320) and O4b (#978) on v2 | gates green with every R-8.1 flip; `-Dllvm` green | S9 | — | 3 |

Total 83 implementer-days; with two implementers on S0‖S1–S2 and S6‖S7‖S8, 10–12 calendar weeks. S4 and S5 are
sequential (both edit `Transfer`, `Calls`, `Demands`). Not in a slice because it is a review activity: the S9
parity triage may surface v1 defects that need requirement decisions; those are issues, not slices.

### 8.1 Risks and what de-risks each

| Risk | De-risked by |
|---|---|
| `mapHelp`/`foldlFrom`'s inferred classes are not v1's asserted rows | S2b's worked derivation before any walker code; if inference cannot reach them, the finding is reported and the rows are asserted with pinned bodies under R-5.10.8 as the owner's decision (rule 10), never matched by name |
| the rotate-`update` family's Θ(N²) facts cost time on a real app | `test-perf` at N = 64/256; sharing keeps the representation O(N); no real TEA app in the corpus has it |
| `recast` loses exactness core's `Schema` needs | S7 runs core's `Schema` under the diff first; structural place identity covers core; a miss is a refusal of core, which fails beni's build loudly (R-1.10) |
| the nominal `Send` churns the platforms and corpus | one mechanical edit in S2b (`send m` → `send.to m`), before S3a reads a send |
| the keep-edge rule still misses a path | `p/RecordKeptInLiteral`, `p/RecordInnerKept`, `p/RecordWriteBeforeKeep` plus the sanitiser over `run/` |
| the entry's sparse fixpoint and κ invariant do not settle fast on Conduit | finite lattices; S7 measures pushes on Conduit and Bike Wars |
| the Lean oracle models another algorithm (#399) | advisory (R-8.11); the sanitiser is the arbiter |
| v2 refuses what v1 accepted outside the requirements | a stop condition in S9, reported, never worked around (R-8.3) |
| `--ownership=v2` leaks into cached entries | `OWN2` blocks are a different section; a mixed cache misses |

### 8.2 Switch-over criteria

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
3. **Index exchange as an exact permutation only.** Recommended: exactly §2.13.15's shape (guard locals = take
   locals, same source), since it covers #869's fixtures and anything wider needs index arithmetic; outside it the
   message names `List.swap`.
4. **The `level (a)` cause.** Kept only for a `below` written while a `level` or another `below` of the same split
   is read later (§2.9); nothing else prints it.
5. **Two amendments the requirements need** (not open, but the requirements win and must say it): R-3.6 and
   R-5.10.7 list the pinned callers of a `taken` result and P-sync (§2.13.6, §2.13.7) as part of the trusted
   surface; R-5.9.9's send positions become `Send.to`'s word.
6. **Inferring `map`/`fold` versus asserting them.** Recommended: infer, with the `taken` result word and the
   pinned index obligation on their callers (§2.13.6); if S2b's derivation shows a gap, assert with pinned bodies
   and record the deviation from R-5.10.8 as the owner's decision.

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
| R-5.2.9 | §2.2 (`distinct cb_j`), §2.9 | S4 |
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
| R-7.2 | §4.1, §4.2 | S9 |
| R-7.3, R-7.4, R-7.5 | §4.4, §7.7 (the limits gate) | S1, S9 |
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
