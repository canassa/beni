# The ownership checker v2 — design and implementation plan

*Draft 2026-10-25. Part of #1006. The WHAT is [`ownership-requirements.md`](ownership-requirements.md) (R-n.m
below); this document is the HOW. Where the two disagree, the requirements win and this document has a bug.
The owner's decisions it builds on: the end state (lists and records enforced on every platform); no algorithmic
cap, only named resource limits no real program reaches (§4.4); no copy fallback, warning or coarsening;
deterministic output; time and memory linear in program size, never in value size; the `Ref` loan model (#981);
ordered `Dict` only (#961); room for #587 and for an in-place shared cell type.*

**Reading order for an implementer.** §1 says why the shape family; §2 is the semantics every module obeys and
§2.14 the lemma each rule must keep; §3 is the layout of every table; §5 the files and the layering gate; §8 the
slice you are on. Appendix A maps every requirement to its section.

**Sources cited.** Papers in `/home/canassa/src/github.com/canassa/ownership-library/` (`SOURCE-STUDY.md` for
file:line into the vendored checkers; `papers/`, `catalogue/`), `docs/design/research/68`, `69`,
`docs/thesis/ownership/` (thesis §n), the frozen v1 (`src/own/`, `ownership-checker.md` = oc §n) and its review
(`~/.cache/beni-agents/ownership-review-fable/report.md`).

---

## 1. The choice of family

### 1.1 What the requirements demand of the domain

Seven precision properties, each with the requirement that forces it, decide the family:

| | Property | Forced by |
|---|---|---|
| P1 | per-field, per-path liveness at any depth; a later read of an untouched field is no use | R-4.1.2, R-4.8.2, R-4.3.5 |
| P2 | per-path reads and writes of a callee (`changed` never reads `.todos`; a W at `π2.todos` only) | R-2.6, R-4.3.5, R-4.8.5, R-5.1.1 |
| P3 | provenance: the result *is* argument 1 / is fresh / holds `cb_j`'s answer; a fresh cell numbered so two result paths naming one number are one object | R-4.10.1–R-4.10.3, R-5.1.2, R-5.2.4 |
| P4 | callbacks: what a callee supplies (owned or borrowed), what it needs of a result, what it keeps; folds' feedback | R-5.2, R-5.3, R-5.8 |
| P5 | exclusive contents of a container, kept through destructive reads, refuted by a taken element stored back | R-4.6, R-4.10.7–R-4.10.13 |
| P6 | levels of a recursive value told apart where the text does, folded finitely where it does not | R-4.7 |
| P7 | directional aliasing (`ys = xs` then a write through `ys` with `xs` dead is accepted), branches that keep the old value | R-4.1.5, R-4.2 |

Plus: a soundness argument per rule (R-3), a size linear in the program (R-7.2), modular summaries in the
interface hashed with it (R-5.7), and a three-place diagnostic naming holder, write and later use (R-6.6).

### 1.2 The four candidates, judged

**(b) Inferred uniqueness types, Clean-style** (`src/clean/frontend/refmark.icl`, `unitype.icl`; research 69
§2.1). Attributes `*`/`.` on every type position, inferred by coercion inequalities `u ≤ v` solved eagerly; sharing
found by counting occurrences per field (`SelectiveUse`, R:33-37), sequencing marking earlier uses non-unique
(`seqCombineRefCount`, R:804-830). P1: per field, yes. P7: no — `[ …xs, List.length xs ]` (R-4.1.3) counts two
occurrences of `xs` and refuses, where the requirement accepts; a unification-based attribute poisons every value a
shared one touches (Emre et al., thesis §3.4). P2/P3: an attribute says *unique* or *shared*, never "the result is
argument 1" (R-4.10.1) or "fresh number 2" (R-5.2.4's alias at the caller). P4: function types force invariance
(`TopSign`, U:840-864); no supply/need. P5: deep uniqueness `*[*a]` exists (Barendsen–Smetsers; Plasmeijer §9.2)
but no materialisation of a taken element (R-4.6.9). Diagnostics: "demanded attribute cannot be offered by
shared object" (R:913) names one place. **Rejected as the core.** Taken: deep uniqueness as the meaning of
`excl`, and the demand living in the library's types (rows as data).

**(c) Borrow inference plus a static contract** — Lean 4 (`src/lean4/.../InferBorrow.lean`), Koka `fip`
(`src/koka/src/Core/CheckFBIP.hs`), Roc (`src/roc-zig/src/lir/arc_solve.zig`). Per-variable owned/borrowed on a
two- to four-point lattice, per-SCC fixpoint, parameters borrowed by default. P1: Lean is per variable, a
projection owning its parent (InferBorrow:378-380); Roc tracks `ret_unique_fields` (arc_sig.zig:82-122) — partial.
P3: none; the systems lean on run-time reference counts (`isShared`) to decide reuse, which R-1.2 forbids. P4:
Koka refuses or warns on higher-order (F:264-279); Lean owns every closure argument (403-405). P5/P6: no. Koka's
`fip` is the one system whose *contract fails loudly* when reuse cannot be proved — the owner's rule. **Rejected
as the core.** Taken: the loud contract; borrowed-by-default callbacks; the per-SCC driver whose facts only grow
(Lean 263-326; Roc's "every parameter bit is queued at most once", arc_solve.zig:25-29) for the `use` bits.

**(d) Morphic per-slot modes with `u ≤ v` constraints** (`src/morphic/.../annot_modes.rs`,
`inequality_graph2.rs`). Per *slot* of a type's shape (`Shape::num_slots`), recursive types parameterised per type
SCC so the slots are finite (`SccParameterizer`, A:295-432); lifetimes as program-path trees; constraints solved by
one topological pass over the condensed graph (I:114-171), linear. P1: per slot, yes. P6: folded per type SCC —
the right place set. P3/P4/P5: a mode is *owned or borrowed*, not *which object*; Morphic needs a separate
must-alias analysis for that, and its IR is first-order (no closures, A: "no closure case"). **Rejected as the
core.** Taken: the type-shaped slot set folded per type SCC (our places, §2.1), signature variables over which a
summary's facts are expressed (our atoms over parameter cells, §2.9), the lifetime-as-path-tree view of branches.

**(a) A shape graph: abstract interpretation with materialisation** — Chase–Wegman–Zadeck's storage shape graphs
(`papers/1990-chase-…`), Sagiv–Reps–Wilhelm's materialisation and sharing predicate
(`papers/1996-sagiv-…`, `1998-…toplas`: the `is` predicate, *focus*), Whaley–Rinard's escape graphs as per-method
summaries composed at calls by grafting (`papers/1999-whaley-…` §4), Sălcianu–Rinard's write effects per parameter
path (`papers/2005-salcianu-…`), Deutsch's folded access paths over recursive types (INDEX.md; Mazur's type
selector in `src/mercury/compiler/ctgc.selector.m:417-541`). An abstract value is a graph whose nodes stand for
objects at the paths of a type, labelled with the provenances (cells) that may be there; a summary is such a graph
over the parameters' and result's paths; a call grafts the callee's graph onto the arguments'; a taken element is
*materialised* out of its summary node (`elem`/`others`), which is the 30-year-old answer to #970/#971. P1–P7 are
all expressible: P1/P2 are the graph's paths, P3 its labels, P4 the grafting with callback placeholders, P5 the
sharing predicate as an instrumentation predicate per node, P6 the folded type paths with materialisation at a
match, P7 the directional (inclusion, Andersen-style) flow over an IR in evaluation order. Soundness is the
standard abstract-interpretation argument: a concretisation per node and an over-approximation obligation per
transfer rule (§2.14). Diagnostics fall out of provenance: the holder, its binding, its later use.

Its known cost, and v1's failure, is **representation**: enumerated paths are exponential in value depth (#856),
unbounded through cyclic types (#955), pairwise in width (#693), and a summary stated as a list is instantiated as
a list (#716). The thesis (§3.4) and the Lean oracle (`Domain.lean`) both specified a hash-consed, type-shaped
value; v1 built neither.

### 1.3 The choice

**v2 is (a), with (d)'s place set, (c)'s contract and driver, and Clean's deep uniqueness as its sharing
predicate.** Concretely:

1. **Places are type-shaped and folded per type SCC** (Morphic; Mercury's type selector). A place graph is derived
   from the solved type graph, which `unify` already builds coinductively (`checker-v2.md` §7.3, as built): a cyclic type with
   no name (#955's accumulator) is one place because it is one store variable. A type parameter is not a level
   (R-4.7.3) because its instantiation is another type.
2. **Abstract values are hash-consed shape nodes over places**, with a *delta* node for a record update and for the
   join of arms over one base (§2.3), so `w5`'s result is 17 nodes (#856) and an `update` of N arms over an N-field
   model is O(N) (#716, #975).
3. **Cells carry provenance; refinements (`elem`, `others`, `level`) are materialised at a pattern match or a
   destructive read** (SRW focus), so a taken element stored back refutes exclusivity (R-4.6.9), two distinct fresh
   elements keep it (R-4.6.7), and the levels of a recursive value are told apart where a match names them (R-4.7.7).
4. **Exclusivity is one condition per node**, a conjunction of atoms over arrivals with a single `apart{…}` atom per
   construction (#693), checked where relied on and published as `xreq` (Clean's `*[*a]`; thesis §3.11).
5. **Summaries are classes over a function type's places** (thesis §4.7; Whaley–Rinard), instantiated by grafting
   with a memo per node; a function parameter's class is a placeholder (`cb_j`) resolved at the call. A class is a
   value with no declaration identity, which is the room #587 needs (§2.10).
6. **One fixpoint driver** (Lean's SCC loop, Roc's monotone queue) serves recursive groups, local-function groups,
   a callback fed its own result, and the entry's model; it terminates because every lattice is finite and every
   round joins (thesis §4.6), with no round cap (R-7.4).
7. **Rows are data**: ownership words (oc §24) extended by four words and an alias form (§2.13.6) carry every asserted row of
   `core/`, the platforms and the test platforms; a declared class on a function-type alias (`Send`) is the one
   place behaviour rides on a type today, by the mechanism #587 would generalise.
8. **The contract fails loudly** (Koka `fip`): every unprovable write is an error with a named fix; a resource limit
   is an `ownership_limit`; nothing is ever a copy.

---

## 2. The semantic core

Notation: `ε` the empty path; steps `.f` (record field), `.i` (tuple index), `C#i` (constructor argument),
`[*]` (list or dictionary position), `◇` (a closure's environment), `◆` (a `Ref`'s contents), `⟨n⟩` (slot n of an
opaque type), `⟲` (the levels at or below a recursive place). `A(e)` the abstract value of expression `e`.
`Σ` the frame state. `γ` concretisation. BIR = `src/bir/Bir.zig`, every declaration a contiguous instruction range
in evaluation order, every binding a distinct local index.

### 2.1 Places

A **place** is a node of the *place graph* of a type: the type's structure with one node per store variable
reachable from it, children by step, and a type variable, function type, foreign type or crossing primitive as a
leaf. It is computed by one memoised walk over the solved type graph (`Walk.structural`), with knot-tying: a
variable reached again while on the walk's stack is the node already being built, so a recursive type (named or
not) folds onto itself; two occurrences of a *different* instantiation (`Tree (Tree (List Int))`'s inner tree,
`Maybe (Maybe a)`'s inner `Maybe`, `Dict String (Dict String (List Int))`'s inner dictionary) are different
variables and so different places (R-4.7.3, oc §16.7 *folding never goes through a type parameter*).

| Place kind | Steps | Holds a cell of kind | Notes |
|---|---|---|---|
| `record` | `.f` per field | `record` | every record type, whatever its fields (R-4.8.1) |
| `tuple` | `.i` | none | a tuple is never written |
| `ctor` (a `type` with constructors) | `C#i` per constructor and argument | none | its arguments' places; a record-alias constructor is a `record` |
| `list` | `[*]` | `list` | `[*]` is a *summary* place (positions merged) |
| `dict` | `[*]` (values) | `dict` | keys cross (R-4.10.9); `Set` is `Dict k ⊤` |
| `ref` | `◆` | `ref` | `Ref a`, `Deferred a` (R-5.12.3) |
| `closure` (a function type) | `◇` | `closure` | the environment; its children are the captured paths (§2.6 *lambda*); a class slot for #587 |
| `opaque` (a foreign type that is not crossing) | `⟨n⟩` per published slot | `opaque` | `Js.Value`, `Html`, a program (R-4.6.5: may hold a record) |
| `var` (a type variable) | none | any | may hold anything (R-5.5.11) |
| `cross` (primitive, `⊤`, `⊥`, a nominal type reaching no tracked place, a crossing foreign type) | none | none | holds nothing (oc §4.4 as amended by §31.2) |

A place graph is **interned per module** by its structure: key `(kind, head identity, children place ids)` where
the head identity is the type key of `checker-v2.md` §36 for a nominal or foreign type, so two solved types with
one key share one place and a cast back to the same full type lands on the same place (R-4.11.1). Opaque types
are read through the interface's published slots (thesis Change 9; R-5.7.1), never their definition: the
defining module computes its opaque type's slots as the canonical paths of its representation type that may hold a
cell, numbered in canonical-path order, each published with its kind and the type key of what it holds; an
importer's place graph gives the opaque place one child `⟨n⟩` per slot of that kind, and a block names a path into
an opaque value by slot number, so two slots are told apart without the definition. Size: the
place graph of a type is O(size of its definition as the store holds it) — linear in the program, by construction.

A **canonical path** from a root place `p₀` is a step sequence in which a place appears at most once: a step that
re-enters a place already on the path pops the path back to that place and appends `⟲` (if not already last). So
for `type Tree = Node Tree (List Int) Tree`: `#Node.1` is the root's list, exact; `#Node.0⟲` the levels at or
below the left child; `#Node.0⟲#Node.1` a list at some level under the left child. Length ≤ 2·|places|. Canonical
paths name symbolic cells (§2.2) and summary entries in blocks (§3.6); they are what folds recursive values finitely
(oc §16.7 (c)), with ⟲ the one representative place (thesis §3.1).

### 2.2 Cells

A **cell** names an object or a class of objects. `Cell = (origin, kind)`; kind ∈ {`list`, `dict`, `record`,
`ref`, `closure`, `opaque`}, read from the place it is made at.

| Origin | Meaning | Projection by a step `s` |
|---|---|---|
| `site ι` | the object a literal, construction, `Record.copy`, `List.copy`, `Dict.empty ⊤` or lambda at instruction ι makes | nothing (its contents are the node's children) |
| `param πᵢ·q` | the object at canonical path `q` of parameter `i` as it arrived | `param πᵢ·(q·s)` canonicalised |
| `env x·q` | in a frame: the object at `q` of the captured local `x` | `env x·(q·s)` |
| `shared M.v·q` | the object at `q` of the top-level value `M.v` | `shared M.v·(q·s)` |
| `result ι·k` | the `fresh_k` of the callee at call ι (a summary's numbered fresh cell, instantiated) | nothing |
| `esc ι·k` | the same, escaped (in Esc from birth) | nothing |
| `cb j·q` | what function parameter `j` returned, at `q` (a placeholder, resolved at the call) | `cb j·(q·s)` |
| `msg` | the message `update` receives (every payload) | `msg` |
| `⊤` | an object the analysis cannot name | `⊤` (prefix-closed, thesis §3.4) |
| `elem c·ι` | *materialised*: the one position of summary place `[*]` of `c` taken at ι | `proj(c, [*])·s` refined |
| `others c·ι` | the other positions of `c`'s `[*]` after ι took one | as `elem` |
| `level c·ι` / `below c·s·ι` | the level a constructor pattern at ι matched out of representative `c⟲` (its non-recursive arguments), and the levels beneath its recursive child `s` | likewise |
| `loan c·ι` | `Ref.get` at ι: a loan of the contents cell `c` (R-5.12.3) | `c`'s projection, loaned |

Symbolic origins (`param`, `env`, `shared`, `cb`, `msg`, `⊤`) **stand for everything under them**: projecting is
appending a step (oc §4.3). Concrete origins (`site`, `result`, `esc`) have their contents as children. A
refinement has a `parent` cell and a split instruction; `base(c)` climbs refinements to the first non-refinement.

**May-alias.** `alias(a, b)` holds iff `base(a) ~ base(b)`, where symbolic cells are `~` when one's canonical path
is a prefix of the other's (a `⟲` matching any continuation), concrete cells when equal, `⊤` with everything;
**except** when `a` and `b` descend from one split ι on *different sides* (`elem` vs `others`, `level` vs a
`below`, two `below`s of distinct recursive steps, or two `level`s of distinct steps of one match): then they do
not alias **under the split's condition** — `alias` answers *no*, *yes*, or *under `κ`*, where `κ` is the
container's condition at ι (§2.9) recorded on the split. A Dead or Disjoint test that passes only *under `κ`*
relies on `κ`: `yes` passes outright, `and{atoms}` passes and records the atoms as `xreq` of the frame's class
(so `o/Split`'s `construction r: accepted param … xreq excl π1` is reproduced), `shared`/`lost` is the refusal
`exclusive` (SRW's materialisation; the Lean oracle's `aliases`, `Domain.lean`). **Paths that diverge at a
`ctor` place on different constructors are alternatives, not two positions**: one value has one constructor, so
`param π₂·status#Editing.2` and `param π₂·status#Saving.1` never coexist and are not a sharing of one argument
(R-4.8.15); two *elements* of one list built with different constructors are two positions and are compared by
`apart` at the construction as any two stored values are. This one
relation is what every holder test, `sep` atom and disjointness check reads; v1's eight `holds*` predicates and
two `mayShare`s collapse into `alias` plus the place kinds of §2.1.

Cells are interned per walk in first-sight order (§3.2); the ids are never printed.

### 2.3 Abstract values: shape nodes

An abstract value is a **shape node**, hash-consed per walk (thesis §4.2 "abstract values are hash-consed";
Chase–Wegman–Zadeck). It denotes a function from paths of its place graph to sets of `(cell, approx)` pairs.

| Node kind | Fields | Meaning |
|---|---|---|
| `leaf` | `place`, `cells` | `cells` at `ε`; below `ε` whatever the symbolic cells project to; concrete cells have nothing below |
| `node` | `place`, `cells`, `children: [step → NodeId]` (dense over the place's steps; `none` = nothing stored) | a built value: `cells` at `ε` plus the children |
| `delta` | `base: NodeId` (never itself a delta), `over: OverId` (a persistent sorted tree of `(step, NodeId)`, path-copied on insert: O(log F) insert and lookup, structure shared between a chain of updates) | the base with some children overridden: at `ε` the base's cells (the same object, written), at `s` the override or the base's child; a chain of k updates to one record costs O(k log F), not O(k²) |
| `recast` | `place`, `inner: NodeId` | `inner` read at another type (§2.13.9): every cell of `inner`, approximate, at every path |
| `union` | `members: sorted [NodeId]` (≥ 2, flattened: never a `union` member) | the lazy join of its members: `cellsAt(ε)` is their union, `proj` the union of their projections. Made only where the eager fast paths of `join` do not apply |
| `cyclic` | a `node` whose child names an ancestor | a recursive value a fixpoint built (§2.12); the knot is tied through the node table, no special kind |

Operations, each memoised on its node arguments in a per-walk table (§3.3):

- `proj(n, s)`: `node` → child or the projection of its symbolic cells; `delta` → override else `proj(base, s)`;
  `leaf` → its symbolic cells projected; `recast` → `recast(child place, inner)`. O(1) plus the cells' projection.
- `cellsAt(n, q)`: `proj` along `q`. **Holders are found by a reverse index, not by a set per node**: every node
  records the cells at its `ε` (`cell → nodes` in first-sight order), every child or override edge records a parent
  link `(parent, step)`, and every binding, pending operand and capture records `node → holder`. `holdersOf(c)` =
  from the nodes whose `ε` cells alias `c` (the interned cells of `c`'s canonical-path ancestors and refinement
  bases: O(path length) lookups), climb parent links once each (a stamp) to the holders, reading the path off the
  climb. Cost: O(ancestor nodes reached), which is the holders found plus the shared nodes between; no set is
  ever unioned, so a chain of k updates adding k cells costs O(k), where a materialised `reach` set per node would
  cost O(k²).
- `join(n₁ … nₖ)`: n-ary. The members are deduplicated and **grouped by base** (a bare node is `delta(n, ∅)` for
  this purpose). Eager fast paths: one member → itself; a group of deltas over one base → one
  `delta(base, s ↦ join of the overrides present and the base's child)` over the union of override steps, O(Σ|Oᵢ|);
  leaves with no children → one leaf with the union of cell sets. What remains after grouping (at most one node per
  distinct base, plus leaves) is **not expanded**: it becomes a `union` node, O(members), whose projections are
  computed lazily and memoised per `(union, step)`. So a join never multiplies sizes: every operation is linear in
  its inputs' representation, and a projection through a union costs O(members) once per step asked. The BDD
  `apply` bound of an eager DAG join (Bryant 1986) is never paid, because the joined function is only ever
  materialised at the paths the program asks for. Memo key: the sorted member tuple (a composite key).
- `put(n, s, m)`: the node with child `s` replaced by `m`: a `delta(n, [(s, m)])` when `n`'s `ε` cells are the
  same object after the write (a record update), else a copy with one child changed (a construction's fresh base).
- `map(n, f)`: the functor relabelling cells by `f` (read-off, instantiation), memoised per node, so a DAG stays
  a DAG and `w5`'s 17-node result costs 17 applications (#856).
- `leq(n, m)`: lockstep inclusion, memoised per pair; the fixpoints' stop test.
- `expand(n, bound)` (safety builds only): the enumerated `(path, cell)` set up to `bound` paths, for the
  cross-checks of §7.5.

**Approximation.** Each `(cell, approx)` pair carries one bit: *exact* when every step from its birth to here was
exact, *approximate* when it came through a `recast`, a joined `res` naming two provenances for one path
(`if c then [ 0 ] else xs`, R-5.1.4), a `⊤`, a conservative call, or a split on a container not known exclusive.
A refusal resting on an approximate pair alone is an approximate cause (R-6.3); an exact failure always wins.
An empty cell set means *provably no cell*, never unknown (thesis §3.4); a `⊤` means any.

**Invariant I-shape.** `γ(n)` = every concrete value whose object at each path `q` is in `γ(cellsAt(n, q))`.
Every operation above is extensive on `γ` (§2.14 O3).

### 2.4 The state of a frame

A **frame** is a declaration body or a lambda body (oc §7.3). Its state during the forward walk:

- `Σ`: the **binding log**, an append-only list of `(local, NodeId)`; a local is bound once (BIR locals are
  distinct per binding and lexically scoped), so a `case` never needs its arms' states joined: only the arms'
  *values* join (§2.6), and the log is popped to the mark taken at the arm's start. The in-scope bindings at a
  point are the log segments of its enclosing regions (§2.7).
- `Esc`: the monotone set of escaped cells, each with the point it escaped at (flow-insensitive: thesis §3.4).
- `taken`: the materialisations in force (which containers have a position or level taken out, under which
  condition). `taken` and `pending` are stacks popped to the arm's mark with the binding log; `Esc` is not
  popped (it is a set of `(cell, point)` and §2.8 reads it by compatibility).
- `uses`, `demands`: recorded, resolved after the walk (§2.7, §2.8).
- `pending`: the operands already evaluated whose consumer has not run (an earlier argument, field, item): a
  stack mirroring the BIR's nesting, each entry a `NodeId`.

### 2.5 Regions and points

A **point** is an instruction index. The **region tree** of a declaration (`Regions.zig`) is read off the BIR
once: a region per `case` arm (its body's contiguous range), per `let` body, per lambda body (a frame boundary),
with `start`, `end`, `parent`, and the case it belongs to. Two points are **compatible** when neither lies in an
arm of a case the other lies in a different arm of (oc §7.2). "After `p`, compatible" is the union of
`(p, end(arm(p))]`, `(end(case(arm(p))), end(parent arm)]`, …, up to the frame's end: at most `depth` ranges, each
a binary search in a sorted use list (§2.7). The `Maybe.withDefault (Maybe.map m f) d` shape of R-4.2.3 is read
as a two-arm case by one rewrite in `Rows` (§2.13.12), so it has arms in this tree.

### 2.6 Transfer rules

One pure function per BIR tag, `Transfer.eval(frame, inst) → NodeId`, recording uses at the consumer (R-4.1.1)
and demands where §2.8 says. Table (thesis Table 3.2; oc §5 as amended by §31.3):

| BIR tag | `A(inst)` | Uses recorded | Demands |
|---|---|---|---|
| `local x` | `Σ(x)`; in a lambda, for a local of an enclosing frame, a capture: `env x·ε`'s leaf, and `(x, ε)` added to the lambda's capture list | at the consumer | — |
| `field_access e.f`, `tuple_index e.i` | `proj(A(e), s)`; on a local inside a lambda the capture is `(x, .f)`: captures are per path (R-5.4.6) | at the consumer, at path `.f` | — |
| `top`, `ext_value` (a value with no parameters) | its summary's `res` with `shared M.v·q` for its own cells (§2.10); under initialization transfer (§2.13.11) the transferred cells are `site`s | — | — |
| `top`, `ext_value` (a function), `ctor` (as a value) | a `leaf` of kind `closure` with cells `{site ι}` and a class: the declaration's summary, or the constructor's class (§2.13.1) | — | — |
| `int`, `float`, `char`, `string`, `interp`, `unit` | a crossing leaf (`∅`) | the interpolated parts | — |
| `list` (no spread) | `node(place, {site ι}, [*] ↦ join(items))`; condition `apart{items}` (§2.9) | each item at ι | — |
| `list` with a spread | §2.13.2: a prepend copies; a construction with anything after the first spread is a write on the first spread's operand | every item at ι | the construction (R-2.3) |
| `tuple`, `record` literal, `pat`-less `ctor` application | `node(place, cells, children)`; a record literal's cells are `{site ι}` (R-4.8.1), a tuple's and constructor's `∅` | each part at ι | — |
| `record_update { r \| F = … }` | `delta(A(r), F ↦ new values)`: the same object, written over (oc §31.3) | `r` at every field but `F` (R-4.8.2's "an update reads the fields it keeps"); each value at ι | an `update` demand on `A(r)@ε` with fields `F` (R-2.5); nested updates are two demands (R-4.8.4) |
| `call` | §2.11 | per the callee's class `use` | call-site demands per `W`, supply/need/keep edges |
| `method_call` | the dispatch table's callee, as `call`; a resolved nullary method is a call (R-5.1.7); a field whose type is a function is a call of the field's value reading only that field (R-5.5.7); a method resolving to neither answers unknown (R-5.5.4) | as `call` | as `call` |
| `type_dispatch` | unknown (R-5.5.4, R-5.13.2): a `⊤` leaf, and every operand's cells join Esc, as a wordless `foreign`'s do (O1) | its operands | — |
| `lambda` | a `node` of kind `closure`: cells `{site ι}`, child `◇ ↦ env node` whose children are the captured `(x, q)` pairs' nodes **at creation** (eager field reads, R-5.4.6); the body is walked as its own frame now, yielding the lambda's class (§2.10); a body that writes a capture makes the closure **once** (R-2.8): its creation is a demand on each written capture | none at creation; captures are used where the closure is consumed (R-5.4.1) | the capture demands of a once closure |
| `let` / `let_def` / `let_pattern` / `let_stmt` | the body; `let_def` with parameters is a local function (a frame, part of the block's local group, §2.12); `let_pattern` as a one-arm case; `let_stmt` consumes its expression | the value at the binding | — |
| `case` | per arm: the pattern's locals bound to projections/materialisations of `A(scrutinee)` (§2.13.3); the arms' values joined n-ary (§2.3) | the scrutinee at the `case` | — |
| `branch` | its body's value; the arm's region | — | — |
| `try` (`e?`) | the `Ok`/`Just` payload projected; on `Result` the `Err` payload joins the result of the definition `?` returns from (R-5.1.6) | `e` | — |
| `markup` | a call of the markup row (§2.13.8): render slots read, event slots retained in the result | its values | — |

Arguments are evaluated left to right and consumed at the call; items of a construction before its base is written
(R-4.1.3). Every forwarded result — an arm's value, a block's tail, a frame's body, a `?`'s early return — is a use
at that point of what it forwards (R-4.1.4, oc §29).

### 2.7 Uses and liveness

A **use** is `(local, place-path, point, kind)`; kind ∈ {read, whole, pattern, capture}. It is recorded at the
consuming instruction (R-4.1.1): an argument at its call at the paths the callee's class reads (per `use` entry, so
`changed { model | draft = "" } …` reads `model` at every path but `.todos`: R-4.3.5), a field at its literal, a
scrutinee at its `case` (whole), a `let` value at its binding, a result at the end of its body, an update's base at
every field but `F`, a closure's captures at every point the closure is consumed (R-5.4.1), a comparison at the root
(whole).

**The liveness index** (`Liveness.zig`), built once per frame after the walk: for each `(local, place)` the uses
sorted by point, and at each place the *subtree* list (every use at or below it). Queries at a demand point `p`
on a holder `(h, q)` of cell `c`:

| Query | Lists read | Lookups |
|---|---|---|
| a whole use of `h` at an ancestor of `q` or at `q` after `p`, compatible | `(h, q')` for each ancestor `q'` of `q` and `q` itself | `depth(q)` × `depth(regions)` binary searches |
| a use under a written field `f ∈ F` (record demand) | the subtree list of `(h, q.f)` | `\|F\|` lookups → each a *hoist* (R-4.8.2) |
| a use under `q` (list demand) | the subtree list of `(h, q)` | 1 |
| an untouched field's use | never read | 0 |

So R-4.8.2's cases cost nothing for untouched fields and one lookup per written field; the first use found names
the later use the message prints. A holder bound after the write, a container, or a call result that may be the
record is read whole (R-4.8.2 bullet 4): their uses are recorded at `ε` of the holder.

Captured paths: a use of a closure value at point `p` is a use of each `(x, q)` in its capture list at `p`, through
the closure's holders (a local bound to it, a structure holding it, a pending argument, a call result that keeps it:
oc §7.3, R-5.4.1). A named local function sees bindings declared after it (R-5.4.1): its captures resolve at its
calls.

### 2.8 Demands and the check

A **demand** is `(point, kind, base: NodeId, fields F, operands: [NodeId], pending: [NodeId], context)`; kinds:
`writer` (R-2.1, R-2.4, R-2.12), `construction` (R-2.3), `append` (R-2.2: a `++` chain is one demand with the
leftmost base; `(a ++ b) ++ c` two), `update` (R-2.5), `callsite` (R-2.6: W on an argument at a path, `F` and the
deep flag from the callee), `send` (R-2.9: deep, every cell of the payload), `once` (R-2.8: a closure's creation on
each written capture; each call on the closure's own cell), `entry` (R-2.10, §2.13.4), `consumed` (R-2.11, deep),
`focus` (R-2.12: the callback's write on the taken element).

**Resolution** (`Demands.zig`), after the frame's liveness index exists, in evaluation order. For each cell
`c ∈ cellsAt(base, ε)` (every `⊤`-like approximate entry whose kind may be the base's included), the five
conditions in cause-precedence order (R-4.3.6; oc §8.1): **Known** (`c ≠ ⊤`, and not `loan` where a loan may not
be written), **Unescaped** (`c` did not join Esc at a point before `p` and *compatible* with it — an escape in a sibling
arm does not count, one before the `case`, in an enclosing arm or in an already-joined `case` does, R-4.2.2; `c`
not `shared`: `top-level`; `view`/`subscriptions` model: `read-only`), **not captured** (`c` not an `env` cell written outside a once closure's own frame: `captured-edit`),
**Disjoint** (no other operand, no other path of the same argument, and no cell of the callee's environment aliases
`c`: R-4.3.2, R-4.3.4, R-5.1.5; for `update`, no new field value holds `c` whole: R-4.8.3), **Dead** (no pending
operand holds `c` at a path the consumer touches: `held-operand`, R-4.3.3; no in-scope holder `(h, q)` with
`alias(cell, c)` is used after `p` compatibly at an overlapping path per §2.7: `later-use` for the base's own
variable, `alias` for another holder, `captured` for a closure, `element` when the only live holders hold `c` at a
`[*]` not materialised apart). Then **Exclusive** (§2.9) where the demand relies on a container's contents, decided
after Dead so a live holder is named first (R-4.6.1).

Holders of `c` at `p`: `holdersOf(c)` through the reverse index (§2.3), filtered to bindings in scope at `p` (the log
segments of `p`'s enclosing regions) and to holders whose **last use** is after `p` — the liveness index gives each
local's last use in O(1), so a holder that is dead for good is skipped without a lookup, and a chain of k updates
whose intermediate holders each die at the next update costs O(1) per demand. Cost per demand: O(ancestor nodes
reached + live holders × the lookups of §2.7) (§4.1).

**Verdicts** (R-0.3): `accepted kind` with kind ∈ {`fresh`, `call`, `param`, `callback-param`, `once`, `entry`};
`pending detail` (a writing function value out of sight, §2.11.4); `refused cause` with the cause table of R-6.3,
each cause exact, approximate or position by the pairs it rested on. Among failing holders the one used first, ties
to the earlier binding (R-4.3.6). Cause precedence is a fixed enum order checked by `rules_test`.

A `writer` demand whose base cells are a parameter's gives the summary `W` at that parameter path (`param`
acceptance, discharged by callers: R-5.1.3); a callback parameter's gives `callback-param` and the frame class's
`W`; a `site`/`result` base is `fresh`/`call`; `entry` the entry's. The result of every writer, construction,
append and update **is its base's object** (R-0.1, R-4.10.1): the node returned is the base's node (`delta` for an
update, `put` for a construction's stored items), so the next holder is the new version.

### 2.9 Conditions: exclusive contents

Each node carries a **condition** `κ(n)`: whether the container at `n` is exclusive (thesis §3.11: no cell at two
positions, distinct paths within a position hold distinct cells recursively, no live outside holder — the third
checked at the write by Dead, oc §18.2). `κ` is an interned conjunction:

| Condition | Meaning |
|---|---|
| `yes` | holds outright |
| `and{atoms}` | holds iff every atom does; atoms name **arrivals only** (parameters, captures, callback results) |
| `shared` | fails exactly: the text puts one cell at two positions (`[ r, r ]`, `{ a = xs, b = xs }`, a taken element stored back) |
| `lost` | fails approximately: `⊤`, a conservative call, a spread of a variable after the base (R-4.6.1), a recast, a pessimistic summary |

Atoms: `excl c` (c deeply exclusive), `sep c d` (c and d share no cell), **`apart{c₁…cₙ}`** (pairwise `sep` over a
construction's stored operands — one atom per construction, so a literal of `n` parameters or a record of `N` fields
costs `n` cells in one atom, not `n²` atoms: #693, `ListOfParams`), `keep cb_j` (the callback puts back what it
was handed or a fresh value: "keeps shape"), `owned cb_j` (the callback returns owned, §2.11.3). A conjunction is a **hash-consed binary `and(CondId, CondId)`**, O(1) to form and shared between a chain of
constructions over one value (a chain of W stores costs O(W), not O(W²)); it is flattened to a sorted,
deduplicated atom run only when printed, compared for the fixpoint's stop test or written to a block, once per
distinct condition (memoised). `and` of `shared` is `shared`, of `lost` is `lost` unless `shared`.

Where `κ` is set: a literal `[ v₁ … vₙ ]` → `and(deep(v₁) … deep(vₙ), apart{cells of v₁ … vₙ})` where `deep(v)` is
`v`'s cells' conditions and `apart` over its cells at distinct paths; a construction → the base's `κ` lowered by what
it stores (`apart{stored, base[*]}` and the stored value's `deep`), a later spread of a *temporary* stored element
by element, of a *variable* `lost` (R-4.6.1); a call → the callee's `res` entry's `κ`, instantiated (atoms over
`πᵢ·q` become the argument's `deep` at `q`, `sep` the two arguments' separation, `owned cb_j`/`keep cb_j` the
actual class's facts: oc §18.4); a `delta` → the base's `κ` lowered by the new field values; a `recast`, `⊤`,
`List.append` by name (`xs ++ []` and `[] ++ ys` copy) → `lost`; a split (`[ x, …rest ]`, a constructor match on
`⟲`) under `yes` keeps `yes` on `rest` and marks the materialisation exclusive (§2.2).

`sep c d` is decided by `alias`: two concrete cells are separate when distinct (`yes`), one cell twice is
`shared`, a `⊤` or an approximate pair is `lost`, and two arrivals that do not alias are the **atom** `sep c d` —
unknown inside the body, discharged by the caller. `apart{c₁…cₙ}` is the conjunction of every `sep` over the set,
stated once: at a construction the stored cells are sorted once, a duplicate is `shared` at once, the concrete
distinct ones need no atom, and the arrivals among them form one `apart` group (an interned sorted cell set).
Discharging an instantiated `apart` at a call is the same sort over the arguments' cells — O(n log n), and the
arrivals among *them* form one `apart` group of the caller's own, so the atom count never multiplies. Record exclusivity reads only places that may hold a record (R-4.6.5); list exclusivity only places
that may hold a list — the same `κ` with a per-kind filter on the cells read (`rules_test` fences that no verdict of
one kind reads the other's cells: R-8.6), **not** a second table (v1's `r`-twins).

Where `κ` is relied on (oc §18.4): a callback writing what a destructive read supplies (`List.update`, `map`'s
element, `Dict.focus`, `traverseAt`); the split (`[ x, …rest ]` then a write of `x` needs the scrutinee's `κ` and
the scrutinee dead: R-4.5.3); a callee's `xreq`; a recursive update of every level (`incAll`: the tree's `κ` below
the written part, R-4.7.5, R-4.7.8). Relying on `yes` records nothing; on `and{atoms}` records the atoms as `xreq`
of the frame's class (callers discharge, across modules too: R-4.6.6); on `shared`/`lost` refuses `exclusive`,
exact or approximate. A storage permutation (`swap`, `sortBy`, `insertAt`, `List`'s writers) lowers no value's
`κ` (R-4.10.11).

Materialisation and `κ` are what settle the R-8.2 rows: `[ p, …_ ] → [ …l, p ]` stores `elem(l·ι)` into `l`
whose `[*]` holds `others(l·ι)` — `elem` and `others` are refinements of one base, so `apart{elem, others}` is
`shared` (R-4.6.9); `List.update … 0 λ_ → xs` stores a cell already in the container's `[*]` → `shared`
(R-4.6.10); `List.push (List.push [] [1]) [2]` stores two distinct `site`s → `yes`, and the later
`List.update … λl → List.push l 9` relies on `yes` (R-4.6.7); `[ xs, List.copy xs ]` stores two distinct cells
→ `yes` (R-4.6.8); the `Dict` twins the same way through `Dict.insert`'s `stored` row (R-4.10.12, R-4.10.13).

### 2.10 Classes and summaries

A **class** describes a function *type's* behaviour (thesis §4.7). A **summary** is a declaration's class. Over
parameters `π₁ … πₙ` and result `ρ`:

| Field | Content |
|---|---|
| `use(i)` | a shape over πᵢ's places whose labels are bit sets `{R, A, E, W}` plus `W`'s written field set `F` (`W{F}`, oc §31.7) and a deep flag `S` (a send or `consumed`: every cell at or below); `unused` where nothing is named |
| `res` | a shape node over ρ's places whose cells are provenances: `πᵢ·q`, `fresh k`, `esc k`, `shared M.v·q`, `cb j·q`, `⊤`; `fresh` numbered by the canonical result path of the cell's first occurrence (oc §16.6 *a member's fresh numbers are the same in every round*), so two paths naming one `k` are one object |
| `κ(res)` | each `res` node's condition, atoms over `πᵢ·q`, `cb j`, `env x·q` (a parameter's own `excl` left implicit, oc §18.3) |
| `xreq` | the atoms the body relied on (§2.9) |
| `fun(j)` for each function-typed πⱼ | `calls ∈ {0, ≤1, many}`; `supply(k)`: a shape of provenances handed as its `k`th argument with an `owned` bit and `κ` per node, `taken` where it is a materialised element; `need ∈ {nothing, owned}`; `seen`; `keep` edges (R-5.2.4) with their conditional writers (oc §16.4 CK-268) |
| `writes` | one bit: the body, or a callee's class, has a `W` or `S` on a parameter path, a capture or a `shared` cell, or lets one escape — a write of something that arrived, never a write of a cell the body made (a builder's `Builder` is fresh) (R-5.13.1) |
| `once` | per function-typed result place: may the value be once |
| `limit` | absent, or the resource limit reached: the pessimistic class (every `πᵢ` `RAEW` at `ε`, `res = ⊤`, every `fun(j)` unseen with `calls many`, `need owned`) |

**Lattice.** Pointwise: bits by inclusion; a shape of provenances by `leq` (the lower order on down-closed sets,
`fresh k ⊑ esc k ⊑ ⊤`, thesis §4.6); `owned ⊑ borrowed`; `calls 0 ⊑ ≤1 ⊑ many`; `κ`: `yes ⊑ and{A} ⊑ and{A ∪ B} ⊑ lost`, with `shared` beside `lost` (exact, and it wins as a cause) —
`and{A} ⊔ and{B}` is `and{A ∪ B}` (one condition for `if c then xs else ys`, as v1's `xreq` is), `lost ⊔ x` is
`lost` unless `x` is `shared`; `limit` above all. Finite for a fixed declaration (cells are bounded by
the parameters' canonical paths, the result paths and the body's sites), so every fixpoint of §2.12 terminates.

**Read-off** (oc §16.3): after resolution, `W` at `(i, q)` when a demand's base cells include `param πᵢ·q`
(verdict irrelevant); `E` when in Esc at the end; `A` when `res` holds it; `R` from uses; `res` = `map(A(body),
f)` with `f`: `site`/`result` → `fresh k` or `esc k` by Esc, `param` → `πᵢ·q`, `env` → `env x·q` (a lambda's class
only), `shared`, `cb`, `⊤` unchanged, a materialised cell → its base's image (approximate); `fun(j)` from the calls
of πⱼ met. A top-level value with no parameters: `res` with each cell its definition makes as `shared M.v·q` at
the path it is made at and nothing else (R-4.9.2: `Dict.empty ⊤` makes none). A lambda's class is read off its
frame over its own parameters with `env` provenances.

**Room for #587.** A class names no declaration: it is a value over a function type's places. Today a class is
found through a declaration (summary), a lambda (its frame), a constructor (synthesised) or a *declared class on a
function-type alias* (§2.13.6, `Send`). #587 would attach an inferred class id to every `closure` place (§2.1's
class slot) and carry it through `Instantiate` as effect classes are (`src/check/Effects.zig`); nothing in
`Calls` would change but where it looks the class up. An in-place shared cell type is a `ref`-kind place with its
own rows (§2.13.7), the same shape as `Ref`.

### 2.11 Calls

`Calls.apply(S, args: [NodeId], actuals: [ClassSet], ι) → (result: NodeId, obligations)`, for a callee with class
`S` (oc §16.4, kept as meaning):

1. **Uses**: argument `aᵢ` that is a variable path `x.p` is used at `x.p.q` for each `use(i)` entry at `q` with
   bits ≠ ∅; a temporary's closures have their captures used.
2. **Pending operands**: an earlier argument holds the demanded cell only at the paths the call touches (oc §16.4
   item 2).
3. **W**: for each `(i, q, W{F}, S?)`, a `callsite` demand on `cellsAt(aᵢ, q)` with `F` and the deep flag, Disjoint
   against every other argument and every other path of `aᵢ`, and against `S`'s environment cells (R-5.1.5).
4. **E**: `cellsAt(aᵢ, q)` join Esc. **Callbacks**: for each function-typed πⱼ the actual's classes (a lambda's, a
   local function's, a top-level function's summary, a constructor's, the caller's own function parameter → the
   caller's `fun` gains `S.fun(j)` translated, or nothing → `⊤`): the **supply edge** (an actual writing its `k`th
   parameter where `S.supply(k)` is borrowed → refuse `supply`; owned with provenance `πᵢ·q″` → a `callsite` demand
   on `aᵢ` at `q″`; `cb j′` → asks the actual for πⱼ′ to return owned), **need** (`S.fun(j).need = owned` → the actual
   must return owned: `need`), **keep** (an actual that may keep its `k`th parameter while the callee writes it
   after → `supply (a)`, R-5.2.4; a callee returning the kept list beside the result makes aliases at the caller),
   **seen** (an actual that writes a parameter handed where `S` loses sight → `pending`).
5. **Returns owned**: every provenance of the actual's `res` is `fresh`, a parameter supplied owned and not
   escaped, or `cb j` itself (the guard being established), no provenance at two result paths; `env`, `shared`,
   `esc`, `⊤`, a borrowed parameter are not owned (thesis §3.7). Owned supplies the callee relies on are followed to
   the caller as `callsite` demands (oc §16.4 CK-233).
6. **Result**: `map(S.res, inst)` with `inst`: `πᵢ·q` ↦ `proj(aᵢ, q)` (grafting: Whaley–Rinard §4), `fresh k` ↦
   `result ι·k`, `esc k` ↦ `esc ι·k` joined to Esc, `shared` kept, `⊤` kept, `cb j·q` ↦ the actual's own `res`
   instantiated with its `π_k` replaced by `S.supply(k)` and its `env x·q` by the captured nodes — a callee that
   hands a callback its own earlier result (a fold) makes `cb j` a least fixpoint (§2.12). A crossing result is
   `∅`. Approximate pairs stay approximate; a `res` path naming two provenances makes its instantiation approximate
   (R-5.1.4).
7. **Conditions**: `κ(res)` instantiated as §2.9 says; `S.xreq` discharged on the arguments, a failure reported
   on that call's line (R-4.6.6).

**Function values** (R-5.5): a value's classes are read off its node's `closure` cells: a lambda's `site` → its
frame's class; a top-level function → its summary; a constructor → §2.13.1; an alias of a function (`writer =
List.push`, `mkBox = Box`) → the aliased class, through any chain (R-5.5.6: chains are resolved by the module
pre-pass of §2.12, no hop count); a partial application `f a _` → `f`'s class with the fixed arguments bound
(R-5.5.2); several classes (a join of lambdas, R-5.5.5) → applied as each and joined; a declared class on the
value's type (§2.13.6); none → unknown, `⊤call` (R-5.5.4). A writing function value that leaves sight — stored,
returned, passed as evidence (R-5.5.10), handed to a callee whose `fun(j)` is unseen — is **pending** at the point
it leaves, naming where (R-5.5.3), except a top-level alias of a writer, which is a call of the writer (R-5.5.6).

### 2.12 Fixpoints: one driver

`Fix.zig` runs every iteration of the checker:

| Instance | Members | Unknown | Start | Step |
|---|---|---|---|---|
| a recursive top-level group (R-5.6.1) | the SCC's declarations (`check/Scc.zig`) | each member's summary | bottom (every path unused, `res ∅`, `fun` seen, no supply, `κ yes`) | walk every member against the current assumptions; `xᵢ₊₁ = xᵢ ⊔ F(xᵢ)` |
| a block's local functions (oc §18.7) | the `let_def`s with parameters of one block | their classes | bottom | the same, at the block's entry |
| a callback fed its own result (R-5.3.2; `Dict.merge`'s cycle, R-5.3.6) | the callbacks of one call | each `cb j`'s node | `∅` | instantiate each callback with the current `cb`s |
| the entry's model (R-5.8.4, §2.13.4) | `update` (and `settle`) | the model node `M` and `κ(M)` | `init`'s model | `M ⊔ res(update)[π₂ := M, π₁ := msg]` |

The step is **chaotic iteration with a worklist**, not Jacobi: members are walked in the SCC's reverse
postorder reading the *latest* assumptions, and a member is re-queued only when the class of a callee it reads
changed, so a cycle of k functions passing a fact one hop each settles in O(k) walks, not k rounds of k walks.
Termination: every unknown ranges over a finite lattice (§2.10), every step joins, so the chain is finite
(thesis §4.6: "termination comes from the join, not from monotonicity"); no round cap (R-7.4, R-5.6.3). Inside a
group a member's fresh cells are numbered by result path, the same in every round (oc §16.6 as amended), so the
join never pairs a root's list with a subtree's. After the fixpoint one **validation** round walks the members
against the final assumptions, must read off `F(x) ⊑ x`, and is the round whose demands are reported. Polymorphic
recursion (R-5.6.2) adds nothing: the member's class is over its own places; a call at another type grafts
through `proj`/`recast` and the places of a nested datatype are finite by §2.1.

The module pre-pass (`Groups.zig`): SCCs over the BIR `refs` edges; alias chains of function values resolved
(R-5.5.6); private parameterless values' read counts for initialization transfer (R-4.9.3); which declarations are
a type's `eq`/`compare` (from `Dispatch`, R-5.13.1).

### 2.13 Reductions: every surface construct to the core

1. **Constructors as values** (R-4.8.10, R-5.5.8, R-5.5.12): a constructor's class is synthesised from its type:
   `res` is a `node` at the type's place with `C#i ↦ πᵢ`, every πᵢ `A`; a record-alias constructor is a record
   literal (`fresh`). `Pushed : Value → Msg` holds a crossing `Value`: `res ∅` (R-5.5.12). A constructor is
   rebuilt, never written (R-4.8.9).
2. **Lists** (R-2.2, R-2.3, R-2.13, R-4.4): `[ x₁ … xₖ, …xs ]` (one spread, last) is a **prepend**: a `node` with
   cells `{site ι}` ∪ `cellsAt(xs, ε)` approximate (the result may be the base itself: re-cons, R-4.4.2), `[*] ↦
   join(x₁ … xₖ, proj(xs, [*]))`, `κ = lost` — **except** when every front item is a `List` whose `ε` cells are a *non-empty* set of `site`/`result` cells
   not in Esc and held nowhere under `xs` (`holdersOf` finds no node of `xs`), or a fresh record/constructor
   (a `site` at `ε`) (R-4.4.3): then the cells are `{site ι}` alone. A scalar front item (`∅` cells), a parameter, a
   capture, a taken element, a top-level value or a callback result keeps the base's cells, approximate (`call (a)`). `List.cons` by name is not narrowed. A construction with anything after the first spread is a
   `construction` demand with base = the first spread's operand; each item stored lowers `κ`; a spread literal
   inside another's last spread is its own write. `[ …xs ]` is `xs`; `[]` and every literal a fresh `site`
   (R-4.10.5). `++` chains per R-2.2. The emitted prepend writes no existing array (R-4.4.4): the lowering's
   obligation, asserted under runtime safety.
3. **Patterns and views** (R-2.14, R-4.5, R-4.6.9): `[ x, …rest ]` on scrutinee `n`: `x` ↦ `elem(c·ι)` for each
   `c ∈ cellsAt(n, [*])`, `rest` ↦ a node with `n`'s `ε` cells (a view shares the storage) and `[*] ↦ others(c·ι)`;
   the split is exclusive iff `κ(n) = yes` at ι (then `x` and `rest`'s elements do not alias) — a `κ` of
   `and{atoms}` records the atoms as `xreq` when a write later relies on the split. A constructor pattern on a
   recursive place materialises `level(c·ι)` for the matched node's own non-recursive arguments and **one
   `below(c·C#i·ι)` per recursive child step** `C#i`, apart from each other and from `level` under the split's
   condition (R-4.7.1; `RNode { l, v, r }`: `l`'s lists and `r` are two `below`s, so pushing under `l` while
   returning `r` is accepted, R-4.7.7); a pattern nested two constructors deep splits the inner `below` again, so
   `v` and `v2` of `Node (Node l v r) v2 r2` are distinct cells; a non-recursive constructor's arguments are plain projections (distinct
   paths need no materialisation). `List.tail`, `List.drop` are views because their bodies call the `view` primitive, whose words say `returned` at
   `ε` (the view shares the base's storage) and whose `[*]` is the base's (R-4.5.1).
   Rebuilding the matched shape is a prepend over the view: an alias of the scrutinee (R-2.14).
4. **Program entry** (R-2.10, R-5.8): a declaration with an `entry` word on a record parameter (R-5.8.1) gives its
   constructor an entry class; at a call with the record's functions' classes in sight (a literal, or values whose
   nodes yield one class each): the protocol is chosen by the callbacks' types (hosted when `settle` is present).
   `M₀ = res(init)[flags := ⊤ crossing, Host := crossing]`, a value `init` returns that is top-level stays `shared`
   (R-5.8.3), captures of `init` move into `M₀` only when no other entry callback keeps them. The fixpoint of §2.12
   over `M` and `κ(M)` (the exclusivity invariant, R-5.8.7), the message `msg` plus the view's event-slot cells
   (§2.13.8; R-5.8.9), `settle` a second writer (R-5.8.11). Then at the call: `update`'s `E` on π₂, its command
   half, `init`'s commands, `subscriptions`' result and whatever `view`/`subscriptions` escape join Esc
   (R-5.8.5); each `W{F}` of `update` on `π₂·q` is an `entry` demand on `M@q` (Known, Unescaped, Disjoint against
   the message and the model's other paths, Dead trivially by P1; `update`'s `xreq` on `(msg, M)`); a `W` on the
   message is `payload`/`entry` per R-5.8.8; a `W` of `view`/`subscriptions` on the model is `read-only`
   (R-5.8.6, R-3.3). A shape other than the protocol's leaves the writers pending (R-5.8.1). The runtime's
   P1–P4, P7 are trusted (R-5.8.13, R-3.6). Arms of `update` are told apart because `res(update)` is the n-ary
   join of the arms' deltas, so a record moved between variants of one field is one holder (R-4.8.15, R-5.8.9's
   Conduit case).
5. **Sends** (R-2.9, R-5.9): `Send msg` is `pub type alias Send msg = consumed msg → ⊤` — a function-type alias
   carrying a parameter word, allowed in core and platform packages only (the one nested-word form, §2.13.6). A
   call of a `Send`-typed value is a call of that class, read where the value *arrives*: the alias node in the
   scheme of the declaration whose callback parameter hands it over (`perform`'s), which the store keeps interned
   and never expands; the lookup walks the variable's class for any alias descriptor carrying words and joins the classes it finds
   (two worded aliases on one variable can only make the class more pessimistic); a send whose alias the store did
   not keep is an unknown function value (`⊤call`, loud), never an acceptance: `W` deep (`S`) on its argument, so a send is a `send`
   demand on every cell of the payload, closures expanded, send values excluded by crossing (R-5.9.4); a function
   that sends its parameter gets `S` on it; a send handed to a callee needs the callee's supply owned (the supply
   edge, R-5.9.5); a lambda sending a capture is once (R-5.4.2); taggers are the callbacks whose `need` is owned
   (R-5.9.6); commands take values (R-5.9.7) so nothing here is special. The alias replaces v1's asserted send
   positions by name (R-5.9.9; `Hosted.job`, `tap`, …, `Cmd.perform`, `Sub.on`, `Sub.map` need no row of their own).
6. **Foreign words and rows as data** (R-5.10): `Rows.fromWords` builds a class from oc §24.2's words, defaults
   pessimistic (R-5.10.3). Four words (one of them in two positions) and one alias form are added so that every row R-5.10.8 asserts is
   written in the source beside its type, and `Rows.zig` contains no declaration name: parameter `written` (`W` at `ε` only — a storage
   write, R-4.10.9), parameter `stored` (the argument is retained at the result's `[*]` and takes part in the
   construction rule of §2.9: `Dict.insert`'s value), `taken` on a function parameter (the supply is a materialised
   element of the first container argument, owned iff that container is exclusive, owned and dead outside the call;
   the callback's result replaces it, a shape-keeping result keeping `κ`: `List.focus`, `Dict.focus`,
   `Dict.update`) and `taken` on a result (the result is a materialised element of parameter 1, a distinct
   position per call — the sibling's obligation, pinned: `foreign pure traverseAt : List a, Int → taken a`, which
   every core loop reads its elements through, so `map`/`foldl`/`filter`'s inferred classes supply elements as
   v1's asserted rows did; `at` stays `aliased`), result `lent` (a loan of parameter 1's `◆`: `Ref.get`), and words on a **function-type alias**
   (`Send`). `crossing` on a `foreign type` as today. Every worded or asserted declaration keeps R-5.10.7's pinning
   fixture, flip report and body hash (`o/trusted-surface.txt`, `o/word-bodies.txt`), and the schema engine's
   obligation stays trusted. `misplaced_ownership_word` gains the alias form's rules (a word in an alias only in a
   platform or core package, only on a function type's parameters). A wordless `foreign` lets every argument escape
   and answers `⊤` unless crossing (R-5.10.1). Words are erased by lowering (R-5.10.5).
7. **`Ref` loans** (R-5.12.3, #981): `Ref a` is a `ref` place with `◆`, and **`◆` is a barrier**: a holder of a
   `Ref` is not a holder of its contents, `holdersOf` and Esc stop at `◆` (a `Ref` captured by a handler or a
   spawned fiber, or escaped to JavaScript, does not escape its contents, because nothing but the worded `Ref`
   operations can reach them: rule 6), and the only outside holders of the contents are loans. `Ref.make v` =
   fresh `site` with `◆ ↦ v`, a `consumed` store of `v`.
   `Ref.get r` (word `lent`) answers `loan(c·ι)` for each `c ∈ cellsAt(r, ◆)`: a holder that may be read and
   passed to callees reading it, used to build values; a loan reaching `res`, Esc, a send, JavaScript, a closure
   that outlives its frame, or a model is refused (`loan-escapes`, printed as `later-use`'s code with the fix
   `List.copy (Ref.get r)`); a loan whose holder is live across an instruction whose effect rung may suspend (the
   effect checker's per-call rung, an input of §3.7) is refused. `Ref.set`, `update`, `modify` (`written` on the
   `Ref`, `taken owned` on the callback) are a `writer` demand on the `◆` cell: Known/Unescaped as always, Dead
   requires every live `loan` of an aliasing contents cell dead — within a fiber by liveness, across fibers by the
   suspension rule; the callback's parameter is the taken contents, and any `Ref` operation inside the callback on
   a `Ref` whose `◆` cell may alias the focused one is a use of a taken container → refused at compile time (R-5.12.3's
   re-entry rule), never a trap. `Deferred` likewise. `Js.ref` is wordless → `⊤` (R-5.12.4). `Js.maySuspend f`
   neither uses nor loses `f` (its words: `borrowed`, `unused`-sight, R-5.12.5). A spawned fiber or queued body
   holds its captures as an escaped closure (R-5.12.1).
8. **Markup** (R-1.6, R-5.8.9, R-5.8.12): a `markup` instruction is a call of a synthesised row from the lowering's
   slot kinds: render slots are `R` of their values; event slots (handlers, children's events, mapped taggers'
   captures) are `A` into the result at the `Html` place's `⟨event⟩` slot, borrowed payloads (`payload (a)` on an
   `update` write reaching them); a `For` row callback's parameter is supplied borrowed (`read-only`, R-5.8.6); a row
   handler capturing a scalar key holds nothing. A markup construction's result is `fresh` at `ε` (its `assumed`
   acceptance counted, R-6.3).
9. **Casts through `Js.Value`** (R-4.11): a `returned Value → a` call whose argument type key differs from its
   result's makes a `recast(place(a), inner)`: every cell of `inner` approximate at every path; a later read *of the recast node itself* (no step taken since the cast) at a place with the inner node's type key
   (the same full resolved type, portable by type key across modules and the cache) restores `inner` exactly; a
   projection of a recast is a recast over the same inner, approximate, and is never restored, so a child of a
   recast recursive value is not taken for its root; any other read keeps the recast. A recast never cancels an alias (`(xs, xs)` read
   as a list of lists is still `shared`, R-4.11.2); a child of a recast of a recursive value is a level of it. Casts
   compose to one `recast` (the inner never a recast), so paths are finite without a marker count.
10. **Schemas** (R-4.7.10, R-5.11): a run (`parse`, `decode*`, `read*`, `encode*`, …) is a call of a row derived from
    the resolved schema plan (`check/SchemaPlan.zig`): `res` fresh at every place the direction builds, holding the
    conversions' captured or top-level cells where the plan says a conversion runs (R-5.11.2: a conversion placing
    one list twice makes the answer `⊤`), `⊤` for an interpreting builder or an unplaceable schema, a runner handed
    on as a value with an unknown input part; a `default` is fresh per decode (R-5.11.6); issues are fresh
    (R-5.11.5); `Type` and `Encoded` are different types and so different places (R-4.7.10); schema constructors are
    §2.13.1's constructors folded by their family's place graph (R-5.11.4). `Json.decode*` and a run of a schema
    built at run time answer no record twice: their `κ` is `yes` for records (R-5.11.3). The engine's obligation is
    trusted (R-5.10.7).
11. **Top-level values and initialization transfer** (R-4.9): a reference to a parameterless value yields its `res`
    with `shared` cells (`top-level (p)` on any write reaching them, through `init`, a view message, a callback, a
    schema conversion or another module). Transfer: the module pre-pass counts reads of each private parameterless
    value (direct, outside lambdas, deferred bodies counted); when exactly one, by a parameterless non-recursive
    initializer of the same application module with no `where` evidence and no function-valued result, the reader
    sees the value's `site` cells as its own (fresh); the destination is still top-level for a function (R-4.9.3). A
    fold's result keeps its provenance (R-4.9.4).
12. **`Maybe.withDefault (Maybe.map m f) d`** and the `Result` twin (R-4.2.3): `Rows` recognises the two-call shape
    over variable paths `m`, `d` and `f` a lambda, partial application or top-level value, and `Transfer` reads it as
    `case m of Just x → f x; Nothing → d` — a region with two arms, so `d`'s read is in the other arm. Mixing modules,
    an eager handler call, an expression default, an edit while computing `m` and `andThen` do not match and are
    ordinary calls (refused `later-use`); a record default is `held-operand`. The one syntactic rule of v2, in one
    table.
13. **Comparison** (R-5.13.1): a declaration `Dispatch` marks as a type's `eq`/`compare` whose class has `writes`
    (own demand, or a callee's `writes`) is `comparison_changes_value` at its first demand (or at the call of the
    writing callee). A call through type dispatch is unknown (R-5.13.2).
14. **`?`** (R-5.1.6): as §2.6; an error type holding no cell adds nothing.
15. **Index exchange** (R-4.8.17, #869): a callback of a row that supplies the position index as a scalar
    (`List.indexedMap`; the index parameter is the row's first supply) keeps the source's `κ` when every arm of
    the callback either returns the element parameter (`elem`) or is reached only under a path condition `i == e`
    on the index with `e` free of `i` (read off the arm's region: a `case` on `Basics.eq i e`), returns a distinct
    `elem` of the *same* exclusive source taken outside the callback (`a`, `b` bound by a pattern or `List.get`), and
    no two arms return one cell: such an arm fires at most once, so every position still holds a distinct cell and
    the result's `κ` is the source's under `excl source`. `swapAt` and `List.drop` over an exclusive source keep
    `κ` as storage permutations and views do (R-4.10.11, §2.13.3). A shape that puts one row at two positions —
    one cell in two arms, or an arm not guarded by an equality on the index — stays `exclusive`. The guard is read
    from the region tree (§2.5), the one place a path condition is consulted.
16. **Core's library**: every function of `core/` not asserted (R-5.10.8) is inferred from its body like
    application code (R-1.10, R-4.10.2's builders return `fresh` because their bodies build in a `Builder`;
    `List.append` by name: `returned` π₁ with `κ lost` at `[*]`, and a `κ` that keeps records' `rexcl` when each
    input is exclusive and they are separate — one condition, kind-filtered, R-4.10.7, R-4.10.8).

### 2.14 Soundness

**Concretisation.** A configuration of the in-place semantics `S_u` (thesis §6.2: every cell versioned, every
reference stamped) is related to a frame state by: `γ(c)` = the objects `c` may name (a `site ι`: the objects
instruction ι allocated in this frame's activations; `param πᵢ·q`: the objects at `q` of argument `i` on entry,
with `⟲` ranging over every level; `elem c·ι`/`others c·ι`: the object taken at ι and the others; `⊤`: all);
`γ(n)` as §2.3; `γ(Σ)` = configurations in which each bound local `x` holds a value in `γ(Σ(x))`.

**Lemma (holder completeness).** *At every point `p` of an execution of an accepted program, in every open frame,
for every object `o` that some continuation of `p` may dereference, call or compare by identity, and every
reference to `o` the configuration holds: either (i) `o ∈ γ(c)` for a cell `c` in `Esc(p)`, or (ii) the reference is
held by a local `x` bound in scope at `p` and `o ∈ γ(cellsAt(Σ(x), q))` at the path `q` the reference is reached
by, or (iii) it is held by a pending operand `m` and `o ∈ γ(cellsAt(m, q))`, or (iv) it is held through the frame's
own parameters or environment and the enclosing call's `use(i)` bit at that path reports it (`A`, `E` or `W`), or
(v) it is held by the runtime, JavaScript, a top-level value or a message, and `o ∈ γ(c)` for an `esc`, `⊤`,
`shared` or `msg` cell at one of the above.*

*Proof sketch.* Induction on the length of the execution prefix (thesis §6.3: not on call depth — a TEA program
dispatches without end). The base case is a frame's entry: every object reachable from an argument is in
`γ(param πᵢ·q)` at its path by the definition of canonical paths (a folded `⟲` covers every level: O6), every
captured object in `γ(env x·q)`, every top-level object in `γ(shared)`. Each step is one transfer rule or one
runtime step; per rule the obligations O1–O9 below give that the rule's result node contains every object the
construct can produce from its parts and that every holder the step creates is recorded. A call: the callee's
`res` over-approximates what it returns (induction on the callee's own accepted walk, instantiated by O5), its `E`
bits every object it hands to something the caller cannot see (O5), and its `fun(j)` what it hands a callback (O5);
a callee with no facts yields `⊤` and escape (O1, O10); a limit yields the pessimistic class (O11). A pattern match: `elem ∪ others` and `level ∪ below` cover the
scrutinee's cells (O6). A record update: the delta keeps every untouched child and the base's object (O7). A join:
union (O4). An escape is permanent (O8). A row: what its body does (O9, the trusted surface). ∎

**Corollary (no stale read).** If a demand at `p` on cell `c` is accepted, then by the five conditions no reference
to any `o ∈ γ(c)` other than the demand's own result is dereferenced after `p` in a compatible branch: not by a
local (Dead), not by a pending operand or another operand (Dead, Disjoint), not by a closure (Dead through
captures), not by a callee (its `use` bits recorded the use at the call), not by the runtime or JavaScript
(Unescaped), not by a top-level value (Unescaped), not through another position of a container (Exclusive and
materialisation), not by a stale view (a view shares the cell). Hence no step of `S_u` uses a stale reference, and
by thesis Lemma 6.1 (no stale use) the trace of `S_u` equals the value semantics' (R-3.1, R-3.2). Per-field
acceptance is sound because the lowering reads each written field a later use needs *before* the store (R-1.12's
hoist), so the later read observes the value the value semantics would — which needs O12: every such read is one
the liveness index enumerated (a field chain, a record pattern, a closure's field capture, a callee's `use` at the
field), so the channel names it.

**Obligations each rule and table must meet** (the review checklist of every slice; `rules_test` names them in
the file headers):

| | Obligation | Where it binds |
|---|---|---|
| O1 | *Over-approximation.* The result node of a construct contains every object it can produce from its operands' nodes; a construct without facts yields `⊤` and escape | every row of §2.6, §2.11, §2.13 |
| O2 | *Uses at consumers.* Every read of a holder is recorded at the point it is consumed, at a path at or above the one read, in the right region | §2.7; every `use` entry of a class |
| O3 | *Extensive operations.* `proj`, `put`, `join`, `map`, `recast` are extensive on `γ`; `leq` implies `γ`-inclusion | §2.3 |
| O4 | *Join is union.* `γ(join(…)) ⊇ ∪ γ(nᵢ)`; `Esc` only grows | §2.3, §2.4 |
| O5 | *Summaries cover bodies.* A class read off a frame over-approximates every object the frame returns, escapes, writes and supplies; instantiation substitutes extensively | §2.10, §2.11, §2.12's validation round |
| O6 | *Materialisation partitions.* `γ(elem c·ι) ∪ γ(others c·ι) = γ(proj(c, [*]))`; the sides are disjoint only when `κ` held at ι; a canonical path's `⟲` covers every level | §2.2, §2.13.3 |
| O7 | *Delta is the base written.* `γ(delta(b, O))` = `γ(b)` with children in `O` replaced; the `ε` object is `b`'s | §2.3, §2.6 `record_update` |
| O8 | *Escape is forever; shared is shared.* A cell in Esc at `p` is in Esc at every later point; a `shared` cell is never owned | §2.4, §2.8 |
| O9 | *Rows state their bodies.* Every worded or asserted class is implied by the declaration's sibling or body, pinned by hash and fixture | §2.13.6, R-5.10.7 |
| O10 | *Unknown is never empty.* A place whose type may hold a cell and whose value the analysis cannot place holds `⊤`, never `∅` | §2.3, §2.11.6, R-3.4 |
| O11 | *No bound accepts.* A resource limit yields the pessimistic class and an error, never an acceptance | §4.4, R-3.7 |
| O12 | *Hoisted reads are enumerable.* Every read of a written field through a holder bound before the write is a use the liveness index recorded with its path, so the lowering channel names each one and the lowering reads it before the store | §2.7, §3.7, R-1.12 |

The Lean oracle (`proofs/ownership/`) stays advisory (R-8.11): Zig accepting what Lean refuses is a defect.

---

## 3. Data-oriented design

`fast-compiler.md` §5's rules hold in every table: `MultiArrayList` columns, `u32` ids as `enum(u32)` with
`.none = maxInt`, `extra: []u32` sidecars for variable-length payloads, no pointer in any table, no per-node
allocation, one arena per walk, no `HashMap` keyed by a dense id (`src/rules_test.zig`; the allowlist entries v1
needed in `summary_bytes.zig` go with it).

### 3.1 Places (`Place.zig`)

```
Place.Table (per module; lives for the module's check)
  kind      : u8          record | tuple | ctor | list | dict | ref | closure | opaque | var | cross
  head      : u32         type key (checker-v2 §36) for nominal/foreign; 0 otherwise
  steps     : Range       into `step_tab`: the steps this place has, sorted (field by name text, index, ctor·arg)
  holds     : u8 bits     may hold: list | dict | record | ref | closure | opaque | any (var)
  class     : ClassId     closure places only: a declared class (§2.13.6), .none otherwise; #587's slot
step_tab    : MultiArrayList { step: Step (u32: kind:4 | payload:28), child: PlaceId }
intern      : hash of (kind, head, steps' (step, child) run) → PlaceId     -- composite key, not a dense id
by_var      : stamped column Var → PlaceId   (memo of the type walk; `stamped.zig`, one stamp per module)
```

A `Step` payload is a field symbol (field steps compare by name *text* through the interner, never by id: §3.8),
a tuple index, a `(ctor, arg)` pair index into a per-module constructor table, or 0 for `[*]`, `◇`, `◆`, `⟨n⟩`.
Canonical paths are runs in `path_bytes: []u32` interned by content (`path_intern`), written as steps with `⟲`
= a reserved step kind; `pathOf(root PlaceId, steps) → PathId` canonicalises by the stack rule of §2.1 in O(len).

### 3.2 Cells (`Cell.zig`)

```
Cell.Table (per walk)
  origin  : u8          site | param | env | shared | result | esc | cb | msg | top | elem | others | level | below | loan
  kind    : u8          list | dict | record | ref | closure | opaque
  a       : u32         site/result/esc/elem/…: instruction; param: index; env: local; shared: decl ref; cb: j
  b       : u32         result/esc: k; param/env/shared/cb: PathId; refinements: parent CellId; loan: parent CellId
  place   : PlaceId     the place it was made at (type filter, R-5.1.8)
  split_x : u1          refinements: the container was exclusive at the split
intern    : hash of (origin, kind, a, b) → CellId
cellsets  : interned sorted runs of (CellId, approx bit) in `set_words: []u32`; `SetId` by content hash
```

`alias(a, b)` is a few column reads: climb `b` parents to the base (refinement chains are shallow: one per split
the text wrote), compare origins, and for symbolic origins compare the two paths by prefix through `path_bytes`
(`⟲` matches any suffix): O(path length).

### 3.3 Shape nodes (`Shape.zig`)

```
Shape.Table (per walk)
  kind     : u8          leaf | node | delta | recast
  place    : PlaceId     (recast: the outer place; delta: the base's)
  cells    : SetId       (delta: the base's, redundantly, so cellsAt(ε) is one read)
  cond     : CondId      κ(n)
  a        : u32         node: Range start into `child_tab`; delta: base NodeId; recast: inner NodeId
  b        : u32         node: Range len (= the place's step count, dense, `.none` children allowed); delta: Range into `over_tab`
child_tab  : []NodeId    dense per `node`, in the place's step order
over_tab   : MultiArrayList { step: Step, child: NodeId, left: OverId, right: OverId }   persistent sorted tree, path-copied
parents    : MultiArrayList { node: NodeId, step: Step, next: ParentLink }   one link per child/override edge, a list per node
by_cell    : CellId → first NodeId whose ε holds it, chained through `next_by_cell` (a column per node)   -- the reverse index
holders    : MultiArrayList { node: NodeId, kind: u8 (local | pending | capture), id: u32, next }   a list per node
intern     : hash of (kind, place, cells, a-run, b-run) → NodeId
memo_proj  : stamped column NodeId → small inline cache of (step, NodeId) (hit rate measured; a miss recomputes in O(1))
memo_join  : hash of sorted NodeId tuple (composite key) → NodeId
memo_map   : stamped column NodeId → NodeId, one stamp per `map` call
memo_leq   : hash of (NodeId, NodeId) → bool
```

The dense-id rule: the only maps keyed by a single `u32` would be memos per node; they are stamped columns
(`stamped.zig`), cleared by one stamp increment per use, as `check/Retained.zig`'s boundary sets are. The join
memo and the intern tables have composite keys. Nodes are never freed within a walk; the walk's arena is reset
per declaration group (§3.9).

### 3.4 Conditions (`Cond.zig`)

```
Cond.Table (per walk; summary conditions are relabelled into it on instantiation)
  kind   : u8      yes | and | shared | lost
  atoms  : Range   into `atom_tab`, sorted, deduplicated (and only)
atom_tab : MultiArrayList { kind: u8 (excl | sep | apart | keep | owned), a: u32 (CellId or cb j), b: u32 (CellId or GroupId) }
groups   : interned sorted CellId runs (`apart` members)
intern   : hash of (kind, atoms run) → CondId
memo_sep : hash of (CellId, CellId) → u8 {yes, no, cond}; memo_deep: stamped column NodeId → CondId
```

### 3.4a The liveness index (`Liveness.zig`)

```
uses       : MultiArrayList { local: u32, place: PlaceId, point: u32, kind: u8, region: u32 }   sorted by (local, place, point)
by_local   : column local → Range into `uses` (dense: a declaration's locals)
by_place   : within a local's range, a sorted run of (place, Range) — sparse, binary-searched; never a local × place table
subtree    : the same two levels over uses recorded at every ancestor place of their own (depth entries per use)
last_use   : column local → point (the dead-holder skip of §2.8)
```

### 3.5 Classes and summaries (`Summary.zig`)

A class is a **sub-table**: its own node/cell/cond rows in the walk's tables, plus:

```
Class
  params   : Range        into `use_tab`: per parameter a NodeId over its places with labels (bits:4, F: SetId of field symbols, S: 1) in a parallel label column
  res      : NodeId
  xreq     : Range        atoms
  funs     : Range        into `fun_tab` { calls: u2, need: u1, seen: u1, supply: Range of { k, node: NodeId, owned: u1, taken: u1 }, keeps: Range }
  writes   : u1
  once     : Range        function-typed result places that may be once
  limit    : u8 + u32     which limit, the measured value; 0 = none
```

The module's summaries live in the module arena (they outlive the walks: callers read them) in **normal form**:
cells relabelled to provenances in canonical order (`param` by (i, path), `fresh`/`esc` by k, `cb` by (j, path),
`shared` by (module, decl, path)), node ids reassigned by a canonical DFS (children in step order), so two equal
summaries are byte-equal and `summaryEql` is a run compare (determinism, §3.8; fixpoint stop test).

### 3.6 Blocks: the interface's ownership section (`Block.zig`)

One block per module, in the interface record (`Interface.ownership`, hashed with it: R-5.7.2) and in the cache
entry (R-5.7.4). Format `OWN2` version 1; every later rule change bumps it (R-5.7.4; a block of another version is
absent, a declaration whose summary does not decode is unknown, a block that does not decode is no block). Nothing
names a session id: modules by package and dotted name through a head table; declarations by BIR index;
constructors by module and index into the module's constructor table (BIR's, then each tagged schema's, as oc §28.4);
field steps by name through a string table; a path as canonical steps; a type key by its §36 bytes.

```
head      : magic "OWN2", version u32, module table (package u8, name offset u32)*, string table, type-key table
directory : per declaration (u32 BIR index, u32 offset, u32 length) — read lazily, one summary at a time (oc §28.4 #814)
summary   : places used (as (root type key, canonical path) pairs, numbered), cells (origin, kind, a, b over the local numbering), cellsets, conds/atoms/groups, nodes (kind, place#, set#, cond#, children/overrides), the Class record
value facts : per parameterless value, whether it may hold a cell (R-5.7.5's footer)
```

Reading re-interns into the reader's tables (O(block read)); a path is mapped onto the reader's place graph for
the imported type (built from the interface's type), an opaque type's slots by number (R-5.7.1). A fact that does
not decode inside a block that does is *unknown* for that declaration alone (R-5.7.4).

### 3.7 Inputs and outputs

Inputs (R-1.6, borrowed, read-only): the module's `Bir`, `Check.Module` (`inst_type`, `local_type`, `decl_scheme`,
the store), `Dispatch` (method callees, which declarations are a type's `eq`/`compare`, evidence sites), the type
key table, imports' interfaces with their blocks, the schema plan, the lowering interface's slot kinds, the
effect checker's per-call rung (new, built in S8: `Effects` seeds rungs per class variable today, and S8 adds a
per-call-instruction column read off the solved classes, for §2.13.7), the ownership
words (`Decl.own_*`), the module's package kind. Never read (R-1.7): platform or constructor names, any mode flag,
session ids, completion order, paths on disk.

Outputs (R-1.8): diagnostics through `Message.zig` (§6); the report (`Report.zig`, R-7.15's grammar, verdict and
count lines required, `summary`/`hoist`/`limit` lines v2's own); the block (§3.6); the **lowering channel**
(`Hoists.zig`, kept: `Table{clean, demands, reads, fields, paths, names}`, format v2 with list writes added for
O5): per accepted write its instruction and written fields, per hoisted read the holder, the read chain, the
written-field prefix, the placement and phase per R-1.12's rules — a placement is the instruction before which
the read runs: the demand's own instruction (phase 0 / phase 1 after operands), or, for a read after the join of
a `case` one arm wrote in, the first instruction of the innermost region containing both the write and the read
(the dominating statement), always after the holder's binding and before the first write the read's version does
not see; a closure's field captures at its creation. The channel is versioned, outside the interface hash, with no
cache-key dependency; a non-clean, report-only or unchecked module authorises no store (R-1.12).

### 3.8 Determinism

Every id is assigned in a walk order that is a function of the BIR: parameters, then instructions ascending; cells
in first-sight order; nodes by creation; places by the type walk from each declaration's scheme in declaration
order. Nothing printed is an id: the report prints source names and canonical paths with field *names*; summary
text is printed from normal form (§3.5) with fields in name-text order and provenances in canonical order;
blocks write names and canonical paths; ties in a message go to source order (R-7.6). A module's result is a
function of its BIR and its imports' blocks alone, so `--jobs=1` and `--jobs=8` are byte-identical and a cached
module equals a rechecked one (R-5.7.5, R-7.7). The `ordering_test` rule holds because SCCs are computed from
references, the module pre-pass sorts by declaration index only where it prints a position, and no verdict reads
declaration order.

### 3.9 Arenas and lifetimes

Per worker (R-7.8): one **module arena** (summaries in normal form, the block, the report, the channel) released
when the module's interface is published; one **walk arena** (place memos' stamps, cells, nodes, conds, uses,
demands of the group being walked) reset after each declaration group's validation round; the liveness index on
the walk arena. Growable `std.ArrayList`s only (no fixed arrays, R-7.12); the DFS of §2.3 and the region walk use
explicit stacks (no recursion over a value: `dump` of `parse/good/Lambdas.beni` terminates, R-7.12).

---

## 4. Complexity

Let |P| be the size of a module's BIR, |T| the size of its types as the store holds them (a DAG), |S_f| the size
of callee f's summary in normal form, D the demands, H the live holders a demand finds, U the uses.

### 4.1 Per phase

| Phase | Bound | Why |
|---|---|---|
| place graphs | O(\|T\|) per module | one memoised walk per store variable; interning per node is O(children) |
| region tree, module pre-pass (SCC, alias chains, read counts) | O(\|P\|) | Tarjan + a counting sort (`check/Scc.zig`); one pass over references |
| forward walk of a frame | O(\|P_f\| + Σ_{calls} \|S_callee\| + Σ_{updates} \|F\| log F) nodes created | an instruction creates O(1) nodes; a record update one delta with \|F\| path-copied override insertions; a call `map`s the callee's `res` once per summary node (memo) and creates at most \|S\| nodes; a record literal costs its width, which the program wrote |
| liveness index | O(U log U) | sort per `(local, place)`; subtree lists by one pass bottom-up over places with a merge |
| resolution | O(Σ_D (ancestors reached + H_D · (depth + \|F\|) · depth(regions) · log U)) | holders by the reverse index with the dead-holder skip; per live holder the lookups of §2.7 |
| conditions | O(atoms gathered) once per node; `sep` memoised per pair asked | `apart` makes a construction's condition O(width) |
| read-off | O(\|A(body)\|) | `map` with memo |
| group fixpoint | walks × the above; a member is re-walked only when a callee's class changed, so walks ≤ members × (facts that can change along the cycle), O(k) for a k-cycle passing one fact; no cap | §2.12 |
| block write/read | O(\|S\|) per summary; read lazily per declaration asked | §3.6 |
| join of k arms | O(k + Σ\|Oᵢ\|): grouping, one merged delta per base, one `union` over the groups; a later projection through the union O(groups) per step asked, memoised | §2.3 |

**Linear in the program.** Every table above is sized by what the program writes: nodes by instructions and
callee summaries, places by types, cells by parameters' canonical paths × sites, atoms by constructions. A value's
*size* (its depth, the number of places one object fills) never appears: a DAG node stands for every path that
reaches it, and a `union` node stands for a join without computing it. No operation's output is larger than its
inputs' representations plus O(1); the one multiplicative factor anywhere is a projection through a `union` of g
groups (g ≤ the distinct bases among one `case`'s arms, a syntactic measure), paid once per `(union, step)` the
program asks for. The gate measurement of §7.6 pins the corpus and the research applications.

### 4.2 The six places v1 went superlinear

| v1 | v2 |
|---|---|
| #856: `w5`'s result holds `x` at 2¹⁶ places, 1 276 786 entries | `node(tuple, [n₄, n₄])` with `n₄ = node(tuple, [n₃, n₃])`…: 17 nodes; the summary's `res` is 17 nodes; instantiating it at `w4 (w4 x)` is 17 `map` steps; `p/DeepTupleDag` checks with no limit line |
| #955: a `foldr` with an accumulator of the cyclic type `List (List …)` never settles — `[*]^k` grows a path per round | the cyclic store variable is one place; `[*]` of it is itself; `cb`'s feedback fixpoint settles in 2 rounds (`res π2` ⊔ `[*] ↦ π2`), no path grows; `CyclicArgumentsUnify` is clean |
| #693: N(N−1)/2 `sep` atoms for a record of N fields of one parameter | one `apart{π1.f₁ … π1.f_N}` atom: N cells in one group; `sep` is a group membership test |
| #716: the entry grows ×6.8 from N = 64 to 256 | `res(update)` is `delta(π2, {fᵢ ↦ {π2.fᵢ, fresh_i}})` over N arms joined n-ary in O(N); an `update` returning `model × Cmd msg` makes a 2-child tuple node per arm whose `.0` children are those deltas (the fast path) and whose `.1` children are command cells (a set union), still O(N); `M_{k+1} = M_k ⊔ res[π2 := M_k]` is O(N) per round and settles in 2; the invariant's condition is one `apart` over the model's fields |
| #975: Conduit +41 % | the same mechanism (the entry was the cost, oc §28.8), plus lazy block reads and `reach` memos; measured by `test-perf` at S9 against R-7.1's +10 % |
| `ListOfParams` O(n⁴): a literal of n list parameters conjoined one atom at a time | `and(excl π₁ … excl πₙ, apart{π₁ … πₙ})` gathered once: O(n) |

And the rest of R-7.2's table: `WideModelArms` (×4 width ≤ ×4–5): deltas and n-ary join, O(N) per arm's update
plus O(N) for the join; `MutualCycles` (12 mutually naming types): one place graph with 12 nodes; routed-app at
N = 128 and the 256-widget application: summaries bounded by signatures, blocks read per declaration asked;
interface reads O(modules) each costing what it holds (lazy directory, R-7.2's #848); `Schema.read` pays for the
summaries it asks (lazy, #814); wide values and conditions never refuse (no width anywhere).

### 4.3 Memory

A walk's tables are proportional to §4.1's node counts and are reset per group (§3.9). A summary in normal form
is O(|S|). The block is O(Σ|S|) per module. No table is sized by a value.

### 4.4 Resource limits

R-7.4: no algorithmic cap — nothing bounds a callback chain, a fixpoint's rounds, a summary's width, a path's
depth, an alias chain or a probe. The only limits are on what a program *writes*, each sized so that no real
program reaches it, each a loud `ownership_limit` naming the limit and the measured value (R-6.11), each with a
gate test that the corpus, the examples and the research applications stay at or below a tenth of it:

| Limit | Value | What it bounds | Why it exists |
|---|---|---|---|
| `record_fields` | 65 536 | fields of one record type | a `Step` payload is 28 bits; a dense children run per node |
| `tuple_arity` | 65 536 | components of one tuple type | the same |
| `constructor_args` | 65 536 | arguments of one constructor | the same |
| `type_places` | 2²⁴ | places of one module's place table | the `PlaceId` space a block addresses per module |
| `path_steps` | 65 536 | steps of one canonical path | ≤ 2·places of a type; a block's path length field |
| `declaration_insts` | 2³¹ | instructions of one declaration | BIR's own `u32` indices |
| `block_bytes` | 2³¹ | one module's ownership block | the cache entry's section length |

Reaching one gives the declaration the pessimistic class and one `ownership_limit`; refusals resting on it have
cause `limit` and are not reported apart; an exact refusal still wins (R-6.11). v1's eleven caps (R-7.5) have no
counterpart: `CallbackChain`, `InitializationLimit`, `LimitOwnedAtoms`, `LimitSpine`, `SplitCap`, `AliasWriter`,
`OwnershipRounds`, `OwnershipEntryRounds`, `OwnershipLimitPessimistic` get ordinary verdicts (R-8.1).

---

## 5. Module structure

`src/own2/` while v1 exists (imports the shared `bir/`, `check/`, `resolve/`, `cache/`, `InternPool`, `stamped`,
`diagnostic` and never `src/own/`); renamed `src/own/` when v1 is deleted (§8.3), as `check2/` became `check/`.

```
L9  Ownership.zig ─────────────── Enforce.zig
      │                              │
L8  Report.zig   Message.zig   Hoists.zig   Block.zig
      │               │             │           │
L7  Groups.zig ───────────────── Entry.zig
      │                              │
L6  Walk.zig
      │
L5  Transfer.zig   Demands.zig   Fix.zig
      │               │            │
L4  Calls.zig      Liveness.zig   Rows.zig
      │               │            │
L3  Summary.zig    Cond.zig
      │               │
L2  Shape.zig
      │
L1  Cell.zig      Regions.zig
      │
L0  Place.zig
      │
    bir/Bir, check/{TypeStore,Types,TypeKeys,Walk,Dispatch,SchemaPlan,Effects,Scc}, resolve/Interface, parse/Ast (words), InternPool, stamped
```

Edges go downward only; a file imports files of strictly lower layers; same-layer files never import each other;
no file below `Walk` names a state struct of a layer above it (upward needs go through a small interface struct
passed down: `Calls` asks "the class of callee d" through `ClassOf{ctx, get}`, as `check/`'s phases take their
tables); no `@This()` god struct holds more than its own layer's state.

| File | Layer | Single responsibility | Public API | Size target (lines) |
|---|---|---|---|---|
| `Place.zig` | 0 | the place graph of a type; steps; canonical paths; holds/crossing | `Table`, `of(store, var)`, `child`, `steps`, `kind`, `holds`, `pathOf`, `PathId`, `canonical` | ≤ 900 |
| `Regions.zig` | 1 | a declaration's region tree, points, compatibility, in-scope log segments | `Tree`, `build(bir, decl)`, `compatible`, `rangesAfter(p)`, `frameOf` | ≤ 400 |
| `Cell.zig` | 1 | origins, kinds, refinements, interning, `alias`, cell sets | `Table`, `Cell`, `intern`, `alias`, `base`, `SetId`, `set`, `union`, `member` | ≤ 600 |
| `Shape.zig` | 2 | shape nodes and their operations; the reverse index | `Table`, `NodeId`, `leaf`, `node`, `delta`, `recast`, `proj`, `cellsAt`, `put`, `join`, `map`, `holdersOf`, `leq`, `expand` | ≤ 1 400 |
| `Cond.zig` | 3 | conditions, atoms, `apart` groups, `sep`, deep conditions, instantiation | `Table`, `CondId`, `yes/lost/shared`, `and`, `deep`, `sep`, `lower`, `instantiate`, `rely` | ≤ 1 000 |
| `Summary.zig` | 3 | the class record, lattice, normal form, equality, pessimistic, text | `Class`, `join`, `leq`, `eql`, `normalize`, `pessimistic`, `print` | ≤ 1 100 |
| `Calls.zig` | 4 | instantiation at a call, callback edges, function values' classes | `apply`, `classesOf`, `Obligation`, `ClassOf` | ≤ 1 500 |
| `Liveness.zig` | 4 | the use index and its queries | `Index`, `build`, `useAfter`, `useUnder`, `Use` | ≤ 700 |
| `Rows.zig` | 4 | words → classes; the alias class; constructors' classes; entry protocol shapes; schema-plan rows; markup rows; the `withDefault` rewrite; the `writes` bit of `eq`/`compare` | `fromWords`, `ctorClass`, `aliasClass`, `entryShape`, `schemaRow`, `markupRow`, `defaultShape` | ≤ 1 100 |
| `Transfer.zig` | 5 | one function per BIR tag | `eval`, `Frame`, `State` | ≤ 1 800 |
| `Demands.zig` | 5 | demand records, the five conditions, holders, causes, verdicts | `Demand`, `Verdict`, `Cause`, `resolve`, `holders` | ≤ 1 200 |
| `Fix.zig` | 5 | the fixpoint driver and validation round | `run(Instance)`, `Instance` | ≤ 400 |
| `Walk.zig` | 6 | one declaration or lambda frame: walk, index, resolve, read off | `walk(decl) → {Class, []Demand, []Use}` | ≤ 1 500 |
| `Groups.zig` | 7 | the module: pre-pass, SCCs, order, limits, initialization transfer, summary table | `checkModule`, `ensureClass` | ≤ 900 |
| `Entry.zig` | 7 | the entry protocol at a constructor call | `check(call)` | ≤ 900 |
| `Block.zig` | 8 | class ⇄ bytes, lazy directory | `write`, `open`, `summary(d)`, `version` | ≤ 900 |
| `Hoists.zig` | 8 | the lowering channel (kept, format v2) | `Table`, `Builder`, `write`, `read` | ≤ 500 |
| `Message.zig` | 8 | diagnostics text and JSON fixes (ported from v1 over `Demands.Demand`; `own2/` imports nothing of `own/`) | `build`, `limit`, `code` | ≤ 900 |
| `Report.zig` | 8 | the dump's lines and totals | `print`, `totals` | ≤ 600 |
| `Ownership.zig` | 9 | the facade: `Input`, `run`, `ModuleReport` | ≤ 300 |
| `Enforce.zig` | 9 | session glue: inputs from the session, the DAG hook, cache entry and interface sections | ≤ 450 |
| `rules_test.zig` | — | the layering, size and fence gate (below) | — |

**The layering gate**: `src/own2/rules_test.zig`, a unit test and so part of `zig build test` (the gate): it reads
every file of the directory, parses its `@import("…")` lines, checks each against the layer table above (an import
of a same-layer or higher-layer file fails, naming both files), checks no file is over its size target, checks
the fences — `Transfer`/`Calls`/`Demands` never name a declaration or module by string (every `std.mem.eql` against
a literal is listed and justified, as `src/rules_test.zig`'s allowlist is), only `Cell.alias` compares cells, only
`Place` reads the type store's children, `Demands.Cause` is in R-6.3's order, every `switch` over `Cell.Origin`,
`Shape.Kind` and `Cond.Kind` is exhaustive (no `else`) — and that `src/own2/` imports nothing of `src/own/`. The
same test can be pointed at another directory later.

---

## 6. Diagnostics

Every refusal is produced from a resolved `Demand` (§2.8) by `Message.zig`, ported from v1 over v2's `Demand`, which reads: the
demand's kind and base instruction (the span, widened to balanced brackets for a construction or `++` chain, a
writer's call, a call that writes an argument, a send; an entry line spans the constructor's name; `ownership_limit`
the declaration's name: R-6.5), the base as written (a local or field path, a top-level name, `<literal>`, `<call
M.f>`, `<lambda>`, `<expression>`, `<record>`, a payload as written), the cause with its kind (exact / approximate /
position, from the `approx` bits of the pairs it rested on and the condition's `shared`/`lost`), the holder named
(local, canonical path printed in source terms: field names, tuple indices, constructor names, never a report path
like `model#Article.0.errors`: R-6.12), its binding point, the later use point and its label, and the fix.

| Produced | From |
|---|---|
| code (R-6.1) | demand kind × cause kind: exact list → `list_still_used`; exact record → `record_still_used`; `top-level` → `top_level_list_changed` / `top_level_record_changed`; `read-only` → `view_changes_model`; approximate or pending → `list_may_be_shared` / `record_may_be_shared`; a limit → `ownership_limit`; `writes` in `eq`/`compare` → `comparison_changes_value`; `Dict`/`Set` storage uses the list codes |
| verdict line (R-6.2) | exact and position: "This is sharing the checker can see: …" or the rule; approximate, pending, `level`, limit: "This is a limit of the checker, not proof of sharing: …" naming the limit — never "not yet"; the kind is decided by the pairs, so an exact label never rests on an approximation (R-6.3) |
| sentence 1 (R-6.6) | the operation, the base and the problem, from the demand kind and base text |
| places (R-6.6) | the holder's binding, the write, the later use, in source order, right-aligned line numbers, carets, labels; several places on one line share it; an entry line adds the constructor; `top-level` adds "defined here" last, with the path for another file; a place in another file is prefixed by its path |
| what the program would see (R-6.6) | exact and position only, from the cause |
| the fix (R-6.7) | the table of R-6.7 keyed by cause and base kind: the base text wrapped in `List.copy`/`Dict.copy`/`Set.copy`/`Record.copy` (`{ Record.copy r \| … }`, `(Record.copy r)` at an argument), "or read `h` before line N" for `alias`, "To be safe, change a copy:" for approximate, `x ⊤` or `List.copy x` for top-level, `init ⊤ = …` for a top-level reached through `init` with the `λ⊤ → x` warning, the `view`/`subscriptions` fix, the `need` fix, the pending fix (a code line for a lambda), the `payload` fix, the `level` fix, the entry fix, `Dict.copy` for a storage read after a write, and for shared `Dict` values the exact/approximate split of R-6.7 (never `Record.copy`) |
| the `need` message (R-6.8) | names the function value as written, "a lambda" or "a function value"; places "the function is handed on here" and "the function here may return a list it does not own" |
| the `unknown` detail (R-6.9) | from the `⊤` cell's birth: a call of a function the checker cannot identify / a function value that may be one of several |
| grouping (R-6.10) | one diagnostic per (position, verdict, cause, detail) listing every base |
| `ownership_limit` (R-6.11) | one per declaration and limit, with the measured value; dependent refusals carry `limit` and are not reported; a function value's own pending line is never hidden |
| JSON (R-6.6) | the same text, and each code fix as a machine-applicable edit (span, replacement) |

Reported modules are the application modules this run checked, a cached refused report rechecked included
(R-6.4); core and platform verdicts are never reported again. `check` fails with the ownership codes alone exactly
when the report has a refused, pending or limit line (R-8.1). Under `--release --allow-debug` the diagnostics are
identical and nothing is written (R-7.11).

---

## 7. Verification

1. **The corpus and the gap fixtures** (R-8.1, R-8.2). `tests/corpus/ownership/`, every `build/bad/` and
   `check/bad/` fixture carrying a §6 code, `run/` and `browser/` unchanged; goldens compared on verdict and count
   lines (R-7.15), `summary`/`hoist`/`limit` lines regenerated as v2's own. `tests/pending/ownership/` (the
   eleven pinned and the ~45 R-8.2 rows another lane writes red) are v2's acceptance: each moves to the corpus as
   its slice turns it green; `test-pending` stays red for the rest. At O4a/O4b the `check` pass→fail flips of
   R-8.1 happen with the dump goldens unchanged.
2. **Whole-corpus verdict diff against frozen v1** (R-8.3). `bench/ownership-everywhere.mjs` grows a
   `--diff=<beni-v1>,<beni-v2>` mode: every root of oc §30.7 O1 (the positive corpus and platform variants, the
   examples, the bench applications, core, every platform surface: 1 505 roots) dumped under both
   (`--ownership=v1|v2`, hidden), verdict lines compared per `(module, line:col)`; the output is three lists — same,
   v2 accepts where v1 refused (each justified by a requirement or pinned as a defect of v1), v2 refuses where v1
   accepted (a stop condition unless the requirement says v1 was unsound: #952, #970, …). Zero unjustified
   differences is a switch-over criterion (§8.2).
3. **The stale-read sanitiser, the arbiter** (R-8.5; thesis §12.2). `--sanitize-records` exists in `js/Lower.zig`;
   S0 adds `--sanitize-lists` by the same method: every array and record the emitted code creates carries a version
   in a side `WeakMap`, every reference stored on an edge (a local, a field, an element, a closure's environment, a
   pending operand) carries the stamp it was stored with, every dereference/identity comparison/call through a stale
   stamp traps with the reference's origin and the write that made it stale; `List.map`'s exempt identity
   comparison is recorded. Under runtime safety the lowering also asserts every in-place store is an accepted write
   of a clean module and a read reached before its placement panics (R-8.9). Every `run/` program runs plain, under
   the sanitiser and under `--release` against its spread-recorded golden (`zig build test-records-in-place`,
   extended to lists at O5); every `browser/` page likewise. A trap on an accepted program is a soundness defect
   regardless of what any checker says.
4. **Differential fuzzing.** The Lean bridge's program generator (`proofs/ownership/BRIDGE.md`, its recorded
   seeds) extended to records, `Dict`, patterns and callbacks: each program checked by v1 and v2, run under the
   sanitiser where both accept, and judged by Lean where it models the construct; disagreement classes: v2 accepts ∧
   sanitiser traps (soundness, stop), v2 accepts ∧ Lean refuses (advisory, R-8.11), v2 refuses ∧ v1 accepts ∧ no trap
   in 10⁴ runs (a precision lead, triaged). `zig build fuzz` grows an `own` sweep; not a gate.
5. **Debug cross-checks** (R-8.8), on `std.debug.runtime_safety`, permanent, over the whole black-box suite:
   `Shape.expand` of every demand's base and every summary's `res` up to 4 096 paths compared with v1-style
   enumerated projection; `join` against the pairwise definition; `delta` against the explicit node; `apart`
   groups against pairwise `sep`; the liveness index against a linear scan of uses; `alias` against the Lean
   `aliases` definition on refinements; the block round-trip `read(write(S)) == S`; a `-Downership-full-cross-check`
   twin without the path bound for the slow run.
6. **Cost gates** (R-7.1, R-7.2): `test-perf` scenarios: `WideModelArms` at N = 64/256 (ratio ≤ 5), `DeepTupleDag`
   to depth 32, `ListOfParams` n = 300, `MutualCycles`, the routed app at N = 128 and 256 (ratio ≤ 2.2), Conduit
   and Bike Wars `check` with the pass on vs off (≤ +10 %), the 100k-line throughput; `bench` records them. A miss
   is reported (CLAUDE.md rule 10), never answered by a cap or by turning the pass off.
7. **Rule mutations** (R-8.7): `-Downership-mutation=<rule>` disables one refusal rule or flips one trusted word;
   `zig build test-own-mutations` requires each to fail some fixture (the pinning fixture of R-5.10.7 for words).
8. **Lists independent of records** (R-8.6): `--ownership-records-lost` keeps every list line byte-identical
   (`test-records-lost`), which the kind filter of §2.9 makes true by construction and the test keeps true.

---

## 8. The implementation plan

Slices are PR-sized, in dependency order; "acceptance" is what turns green (fixtures named as in the
requirements); estimates are working days for one implementer agent under the owner-away rules (one `@claude`
review per PR); everything is under the hidden `--ownership=v2` until §8.2.

| # | Slice | Builds | Acceptance | Depends on | Parallel with | Est. |
|---|---|---|---|---|---|---|
| S0 | **The arbiter** | `--sanitize-lists` beside `--sanitize-records` (§7.3), `test-records-in-place` over lists, the `--diff` mode of `bench/ownership-everywhere.mjs` (§7.2), v1 behind `--ownership=v1\|v2` with v2 refusing until S3 | the sanitiser runs the `run/` and `browser/` corpora clean under v1 on `browser-inline` and `node` (`--ownership-everywhere`); the diff tool prints three lists | — | S1 | 3 |
| S1 | **L0–L2** | `Place`, `Regions`, `Cell`, `Shape` with unit tests; `rules_test` (layering, sizes, fences, dense-id); `expand` and the join/delta cross-checks | `zig build test` green with the gate; `DeepTupleDag`'s place graph and the `(x,x)` DAG unit-tested at 17 nodes; a cyclic type is one place | — | S0 | 4 |
| S2 | **L3–L4 without calls** | `Cond`, `Summary` (lattice, normal form, print), `Liveness`, `Rows.fromWords` (today's words) | unit tests; `Summary.print` reproduces v1's `summary` line grammar for hand-written classes; `ListOfParams`' condition is O(n) in a unit test | S1 | — | 4 |
| S3 | **Lists in one module** | `Transfer` (all tags but `markup`/`try`'s return), `Demands`, `Calls` for direct calls of summarised declarations and words, `Walk`, `Groups` (SCC fixpoint via `Fix`), `Report`, `Message` wired, `Ownership`/`Enforce` for `dump --stage=ownership --ownership=v2` on a single module | the list lines of every single-module `o/` fixture with no callbacks, closures or records (Accumulator, LaterRead, StoredTwice, Disjoint, Spreads, SelfSpreads, Prepend, PrependFresh, Split, ViewAliases, Binders, Question, Toplevel, Recursion, ReturnsFresh, ReturnsArg, CallerSide, PathCut, Nest, MutualTypes, MutualCycles, ParamHole, OneListTwoLevels, DeeperLevel, MarkerAcross, LevelLimit…); the R-8.2 rows for R-4.7.4, R-4.7.7, R-4.7.8, R-4.7.9, R-5.5.6, R-5.6.3's three fixtures, R-6.6's JSON fix edit, R-7.12 #954, R-7.6 #428 | S2 | S4's design | 7 |
| S4 | **Callbacks, closures, folds** | `Calls` supply/need/keep/seen, returns-owned, the feedback fixpoint, function values and pending, once closures, local groups, initialization transfer, the `withDefault` rewrite | Callbacks, NeedLabels, NeedUnknown, CallbackKeeps, ConditionalCallbackKeep, FoldAccumulators, FoldKeepsInner*, Once, Clo*, ClosureCapture, CapturedParam, SlotInLambda, LambdaParamNeed, CarriedLambda, LocalGroups, PolyRec*, MergeCallbackCycle, MaybeDefault, ResultDefault, Initialization*, UnknownCallee*; R-8.2 rows R-4.6.7–R-4.6.10, R-5.2.8, R-5.2.9, R-5.3.7, R-5.4.3–R-5.4.5, R-5.4.9, R-5.5.5, R-5.5.6 (#279), R-5.5.12, R-6.3 #996 (a limit's message says "a limit of the checker") | S3 | S5 | 7 |
| S5 | **Records** | record cells, `delta`, `update` demands, per-field Dead with hoists, `Hoists` v2, record exclusivity through the kind filter, `Record.copy`, once closures over records, `comparison_changes_value` | every `Record*` fixture, `RecordCells`, `RecordDemands`, `RecordHoistChannel`, `run/RecordHoistValues`, `run/RecordInPlace*`, the `.in-place` fixtures; pending RecordSplitPushBack, RecordWriteBeforeKeep, RecordKeptInLiteral, RecordInnerKept, RecordForItem (needs S7), RecordSchemaRun (needs S7); R-8.2 rows R-4.8.7, R-4.8.12–R-4.8.15, R-4.8.17 (ExchangeRows, IndexGuard, KeyedEnds), R-4.10.4, R-4.10.8, R-5.13.1 | S3 | S4 | 6 |
| S6 | **Modules, blocks, cache, core** | `Block` v1, the interface section and hash, cache entry section, lazy reads, the firewall test, core and platform facts in the checked core, `dump` of embedded core, every platform reported at beni's build | CrossModule, ApartAcrossModules, OpaqueSlots, WideCtorBlock, SchemaCtorBlock, SchemaMemberExt, SchemaCtorCached, every `.cached` fixture, `cache_test`; core and every platform clean under v2 (R-1.10, R-8.4's core half) | S4, S5 | S7 | 5 |
| S7 | **Entry, sends, taggers, markup, schemas** | `Entry` (direct and hosted protocols, the model and invariant fixpoints), the `Send` alias class and the alias-word rule in lowering, markup rows from slot kinds, schema-plan rows, `?`'s early return, casts (`recast`) | Entry*, HostedEntry*, WideModel, WideModelArms, SplitArmsJoin, OwnedSend, SendInPayload, NestedLambdaSend, SubOnShared, HttpAnswer*, RandomGenerate, EntryUrlTaggers, Conduit (R-8.2 rows R-5.8.9 #957, R-5.8.10 #412, R-5.9.3 #976, R-5.9.9 #440), ViewEventPayload, Schema* and core/*Cast*, RecordForItem, RecordSchemaRun; R-8.2 rows R-4.4.3, R-5.11.5, R-5.11.6, R-5.12.2 | S4, S5 | S6, S8 | 7 |
| S8 | **`Dict`, `Ref`, the new words** | the new words and the alias form through the lexer/parser/lowering (`misplaced_ownership_word` rules), `Dict` rows on #961's branch (`written`, `stored`, `taken`), `Ref`/`Deferred` loans and the suspension rule, `Task.callback`'s `Resume`, worded `Js`/`Task`/schema surfaces re-justified and pinned | DictFocus, DictValueWritten, DictTupleFocus*, Permutations, WriteExtents, pending DictFocusGrow, DictHelperAlias, DictRecordAlias, DictTupleAlias; R-8.2 rows R-5.10.12, R-5.12.3 (the chat server, the loan across a send, the stored loan, the re-entrant callback, RefUpdateImpure); `Words`, `WordsBrowser`, `JsPure`, `TaskWords`, core/JsWords | S4, #961 | S7 | 6 |
| S9 | **Parity and cost** | the whole-corpus diff to zero unjustified differences; every pending ownership fixture green or re-filed with a requirement; `test-perf` scenarios of §7.6; the mutation suite; the fuzz sweep's first 10⁵ programs; the full cross-check run | R-8.1 whole, R-8.2 whole, R-8.3, R-8.4, R-8.6, R-8.7, R-8.8; R-7.1's +10 % on Conduit and Bike Wars or a report | S6, S7, S8 | — | 6 |
| S10 | **Switch-over and deletion** | §8.2's criteria met; v2 the default; `--ownership=v1` and `src/own/` deleted; `src/own2/` renamed; goldens' v2-own lines blessed; `skills/beni/` and `language.md` §10 updated for the new words and the alias form; O4a (#320) and O4b (#978) land on v2 | the gates green with every R-8.1 flip; `zig build gates -Dllvm` green | S9 | — | 3 |

Total ≈ 58 implementer-days; with two implementers on the parallel pairs (S0‖S1, S4‖S5, S6‖S7‖S8) about 7–9
calendar weeks, which matches the review's 6–8 weeks plus the entry and `Ref` work it did not count.

### 8.1 Risks and what de-risks each

| Risk | De-risked by |
|---|---|
| the join's worst case shows up on a real program | S1's cross-check and a `test-perf` scenario with crosswise sharing; the three fast paths; if a real program hits it, a fourth canonical form (per-place node normalisation) is a `Shape.zig`-only change |
| `recast` loses exactness core's `Schema` needs (v1's `cast_*` was 20 fields) | S7 runs core's `Schema` under the diff first; type-key identity is already portable (§36); a miss is a *refusal* of core, which fails beni's build loudly (R-1.10) and names the function |
| the five new words are not enough for a row | each asserted row of R-5.10.8 is written in words in S8's first commit before any Zig; a row that cannot be written stops the slice and is reported (rule 10), never matched by name |
| per-field hoist placement after a join is wrong | `run/RecordHoistValues`, the sanitiser, and R-8.9's runtime-safety assertion in the lowering |
| the entry fixpoint's invariant (`κ(M)`) does not settle fast on Conduit | the lattice is finite; S7 measures rounds on Conduit and Bike Wars; the `apart` group keeps each round O(width) |
| the Lean oracle models a different algorithm (#399) | advisory only (R-8.11); the sanitiser is the arbiter |
| v2 refuses something v1 accepted that the requirements do not cover | a stop condition in S9: reported with the program, never worked around (R-8.3) |
| `--ownership=v2` leaks a behaviour difference into cached entries | blocks are versioned `OWN2`, v1's `entry_bytes` section is a different section; a mixed cache is a miss |

### 8.2 Switch-over criteria

All of: (1) `zig build gates` green with v2 default on every platform; (2) the whole-corpus diff has zero
unjustified differences, each justified one cited to a requirement in the PR; (3) every `tests/pending/ownership/`
fixture is green or re-filed as a new requirement; (4) the sanitiser runs the `run/` and `browser/` corpora and the
examples clean with lists and records in place on `node` and `browser-inline`; (5) `test-perf`'s §7.6 scenarios
pass or their misses are reported with numbers; (6) core and every platform are clean (R-1.10); (7) the `-Dllvm`
gates pass; (8) the diary and the skill are updated.

### 8.3 Deletion of v1

In S10, one PR: delete `src/own/` and `--ownership=v1`, rename `src/own2/` to `src/own/` (imports `"../own/…"`
unchanged for callers of the facade), drop v1's `rules_test` allowlist entries and the `cache/Entry.zig`
`ownership` section's v1 format, retire the `-Downership-full-cross-check` name in favour of §7.5's, archive
`ownership-checker.md` as history with a header pointing here (never renumbered: rule 2), and move the dated
amendments the requirements already fold in to a `plans/` note. The frozen v1 is in git; nothing else is kept.

---

## 9. Open design questions

Only what the requirements and the owner's decisions leave open; each with a recommendation.

1. **Where the `Send` class is declared.** Recommended: a parameter word inside a function-type alias of a core or
   platform package (`pub type alias Send msg = consumed msg → ⊤`, §2.13.5), the one nested-word form, because it
   makes every send position a plain worded call and is the exact shape #587 would generalise. The alternative, a
   `Send` foreign type with a worded `Send.to` operation, changes the platforms' API for the same effect.
2. **The five row words versus a row file.** Recommended: words (`written`, `stored`, `taken`, `lent`, and the
   alias form), because the parser, `misplaced_ownership_word` and the pinning discipline exist; a separate row
   grammar would be a second trusted surface. If a row of R-5.10.8 cannot be written with them, that is the finding,
   and the word set grows by one named word in that slice.
3. **The guard the index-exchange rule reads.** §2.13.15 reads one path condition, `i == e` on the index
   parameter. Recommended: exactly that and no more (no ranges, no `||`), since it covers every fixture of #869
   and a wider guard language would be a second checker; a shape outside it is refused `exclusive` with
   `List.swap` named in the message.
4. **The `level (a)` cause.** v2 can print it only where a `below` refinement is written while a `level` of the
   same split is read later (the one approximate case left, R-4.7.2). Recommended: keep the cause for that case
   and nothing else, so the message names the fix (copy where the list is put into the value) where it is true.
5. **Hoisting across a frame boundary.** A hoisted read whose holder is bound in an enclosing frame and read in a
   lambda created after the write is an eager capture at creation (R-5.4.6) and needs no hoist; one created
   *before* the write is a whole use (the closure holds the object). Recommended: as stated; the channel never
   crosses a frame.

---

## Appendix A. Requirement coverage

Each requirement of `ownership-requirements.md` and the section of this document that discharges it. "(fixture)"
marks requirements met by the corpus or pending fixtures the sections build toward; the slice column is §8's.

| Req | Section | Slice |
|---|---|---|
| R-0.1 | §2.8 (the result is the base's object) | S3 |
| R-0.2 | §2.8 holders, §2.14 lemma (i)–(v) | S3 |
| R-0.3 | §2.8 verdicts, §2.11 pending | S3 |
| R-0.4 | §2.14 corollary | S3 |
| R-1.1 | §2.8, §3.7 channel | S3 |
| R-1.2 | §1.3 item 8, §4.4 (no fallback anywhere) | all |
| R-1.3 | §3.7 (no mode input), §8 S10 | S10 |
| R-1.4 | §2.13.4 entry by word, §3.7 never-read inputs | S7 |
| R-1.5 | §3.7 (runs on a type-clean module; Enforce) | S3 |
| R-1.6 | §3.7 inputs | S3 |
| R-1.7 | §3.7 never-read; §5 fences | S3 |
| R-1.8 | §3.7 outputs | S3, S6 |
| R-1.9 | §3.7 (out of scope stays with the type checker and lowering) | — |
| R-1.10 | §2.13.16, §7, §8 S6 | S6 |
| R-1.11 | §2.14 O9, §2.13.6 | S8 |
| R-1.12 | §3.7 channel and placement | S5 |
| R-2.1–R-2.4 | §2.8 kinds, §2.13.2, §2.13.6 (`written`) | S3, S8 |
| R-2.5 | §2.6 `record_update`, §2.8 | S5 |
| R-2.6 | §2.11 item 3 | S3 |
| R-2.7 | §2.11 function values | S4 |
| R-2.8 | §2.6 `lambda`, §2.8 `once` | S4 |
| R-2.9 | §2.13.5 | S7 |
| R-2.10 | §2.13.4 | S7 |
| R-2.11 | §2.8 `consumed`, §2.13.6 | S3 |
| R-2.12 | §2.13.6 `taken`, §2.8 `focus` | S8 |
| R-2.13, R-2.14 | §2.13.2, §2.13.3 | S3 |
| R-2.15 | §2.2 `site` for copies, §2.13.16 | S3, S5, S8 |
| R-2.16 | §2.13.16 builders fresh, §2.13.10 schema runs | S3, S7 |
| R-3.1, R-3.2 | §2.14 | S3 |
| R-3.3 | §2.8 Unescaped (`top-level`, `read-only`) | S3, S7 |
| R-3.4 | §2.14 O10 | S3 |
| R-3.5 | §2.14, §3.6, §2.12, §2.13.9 | S6 |
| R-3.6 | §2.14 O9, §2.13.4, §2.13.10 | S7, S8 |
| R-3.7 | §2.14 O11, §4.4 | S3 |
| R-4.1.1 | §2.6, §2.7 | S3 |
| R-4.1.2 | §2.1 places, §2.7 index | S3 |
| R-4.1.3 | §2.6 (items before the base) | S3 |
| R-4.1.4 | §2.6 forwarded results | S3 |
| R-4.1.5 | §2.8 Dead | S3 |
| R-4.1.6 | §2.4 binding log (distinct locals), §2.7 | S3 |
| R-4.2.1 | §2.5 compatibility, §2.7 ranges | S3 |
| R-4.2.2 | §2.8 Unescaped (compatible point), §2.4, §2.5 | S3 |
| R-4.2.3 | §2.13.12 | S4 |
| R-4.3.1 | §2.8 Dead (`alias`) | S3 |
| R-4.3.2 | §2.8 Disjoint | S3 |
| R-4.3.3 | §2.8 Dead (`held-operand`), §2.11 item 2 | S3 |
| R-4.3.4 | §2.11 item 3 | S3 |
| R-4.3.5 | §2.11 item 1, §2.7 | S3 |
| R-4.3.6 | §2.8 order, §5 fence | S3 |
| R-4.3.7 | §2.4 Esc, §2.8 Unescaped | S3 |
| R-4.3.8 | §2.8 Dead (`element`) | S3 |
| R-4.4.1–R-4.4.4 | §2.13.2 | S3, S7 |
| R-4.5.1–R-4.5.3 | §2.13.3, §2.2 (a split's alias is a condition) | S3 |
| R-4.6.1–R-4.6.6 | §2.9 | S3, S4 |
| R-4.6.7–R-4.6.10 | §2.9 last paragraph, §2.2 refinements | S4 |
| R-4.7.1 | §2.1 canonical paths, §2.13.3 `level`/`below` | S3 |
| R-4.7.2 | §9 item 4 | S3 |
| R-4.7.3 | §2.1 (a type parameter is another place) | S3 |
| R-4.7.4 | §2.1 (place graph over the mutual SCC) | S3 |
| R-4.7.5, R-4.7.8 | §2.9 relied-on (`incAll`) | S3 |
| R-4.7.6 | §2.9 construction lowering, §2.13.3 | S3 |
| R-4.7.7 | §2.13.3 (`below` per recursive step) | S3 |
| R-4.7.9 | §2.2 `alias` by prefix (nested constructors are paths) | S3 |
| R-4.7.10 | §2.13.10 | S7 |
| R-4.8.1 | §2.1 `record` place, §2.6 literal | S5 |
| R-4.8.2 | §2.7 queries, §2.8 Dead per field, §3.7 channel | S5 |
| R-4.8.3 | §2.8 Disjoint (update), §2.6 order | S5 |
| R-4.8.4 | §2.6 `record_update` (two demands) | S5 |
| R-4.8.5, R-4.8.6 | §2.11 item 1 with `W{F}`; §2.8 (a callee without facts reads whole) | S5 |
| R-4.8.7 | §2.8, §2.11 item 3 | S5 |
| R-4.8.8 | §2.8 Dead/Disjoint | S5 |
| R-4.8.9 | §2.13.1, §2.11 item 3 | S5 |
| R-4.8.10 | §2.13.1 | S5 |
| R-4.8.11 | §2.11 item 4 keep, §2.14 O1 (a fresh literal handed on holds its parts) | S5 |
| R-4.8.12 | §2.7 pattern reads under a written field (hoist) | S5 |
| R-4.8.13 | §2.11 keep per path, §2.9 kind filter | S5 |
| R-4.8.14 | §2.8 (every base has cells: O10) | S5 |
| R-4.8.15 | §2.13.4 (arms joined n-ary) | S7 |
| R-4.8.16 | §2.9, §2.11 (one mechanism, kind-filtered) | S5 |
| R-4.8.17 | §2.13.15 | S5 |
| R-4.9.1, R-4.9.2 | §2.13.11, §2.10 read-off of a value | S3 |
| R-4.9.3 | §2.13.11, §2.12 pre-pass | S4 |
| R-4.9.4 | §2.13.11 | S4, S8 |
| R-4.10.1 | §2.8 (result is the base), §2.13.16 | S3 |
| R-4.10.2 | §2.13.16 | S3 |
| R-4.10.3 | §2.2 `site`, §2.13.16 | S3 |
| R-4.10.4 | §2.13.16, §2.6 `record_update` with a call base | S5 |
| R-4.10.5 | §2.13.2 | S3 |
| R-4.10.6 | §2.13.6 words | S3 |
| R-4.10.7, R-4.10.8 | §2.9 kind filter, §2.13.16 | S5 |
| R-4.10.9–R-4.10.14 | §2.1 `dict`, §2.13.6 (`written`, `stored`, `taken`), §2.9 | S8 |
| R-4.10.15 | §2.13.4 (no exemption: platforms are modules) | S7 |
| R-4.11.1, R-4.11.2 | §2.13.9 | S7 |
| R-5.1.1 | §2.11 | S3 |
| R-5.1.2 | §2.10 `res`, §2.11 item 6 | S3 |
| R-5.1.3 | §2.8 `param`, §2.11 item 3 | S3 |
| R-5.1.4 | §2.3 approximation, §2.11 item 6 | S3 |
| R-5.1.5 | §2.11 item 3 (environment cells) | S4 |
| R-5.1.6 | §2.6 `try`, §2.13.14 | S7 |
| R-5.1.7 | §2.6 `method_call` | S3 |
| R-5.1.8 | §2.14 O10, §3.2 `place` column (type filter) | S3 |
| R-5.2.1–R-5.2.7 | §2.11 items 4–5 | S4 |
| R-5.2.8 | §2.11 item 5 (deep demands only where relied on) | S4 |
| R-5.2.9 | §2.9 `keep cb_j`, kind filter | S4 |
| R-5.3.1–R-5.3.6 | §2.11 item 6, §2.12 feedback instance | S4 |
| R-5.3.7 | §4.2 (#955) | S3 |
| R-5.4.1 | §2.6 `lambda`, §2.7 captures | S4 |
| R-5.4.2 | §2.8 `once` | S4 |
| R-5.4.3–R-5.4.5 | §2.8 Dead through captures, §2.7 (captures used where consumed) | S4 |
| R-5.4.6 | §2.6 `lambda` (eager field captures) | S5 |
| R-5.4.7 | §2.1 `◇` children per capture; §2.9 `apart` | S4 |
| R-5.4.8, R-5.4.9 | §2.11 item 6 (`cb` with `env` substituted), function values | S4 |
| R-5.5.1–R-5.5.4 | §2.11 function values | S4 |
| R-5.5.5 | §2.11 (several classes joined) | S4 |
| R-5.5.6 | §2.11, §2.12 pre-pass (alias chains) | S3, S4 |
| R-5.5.7 | §2.6 `method_call` | S3 |
| R-5.5.8 | §2.13.1 | S5 |
| R-5.5.9 | §2.11 item 4 (translated `fun`), §2.12 | S4 |
| R-5.5.10 | §2.11 pending (evidence) | S4 |
| R-5.5.11 | §2.1 `var` place, §2.11 item 3 | S3 |
| R-5.5.12 | §2.13.1 | S4 |
| R-5.5.13 | §2.10 room for #587, §2.1 class slot | — |
| R-5.6.1–R-5.6.3 | §2.12 | S3, S4 |
| R-5.7.1 | §2.1 (slot computation and publication), §3.6 | S6 |
| R-5.7.2 | §3.6 (interface section, hashed) | S6 |
| R-5.7.3 | §3.6, `cache_test` | S6 |
| R-5.7.4 | §3.6 versions | S6 |
| R-5.7.5 | §3.8, §3.6 | S6 |
| R-5.8.1–R-5.8.13 | §2.13.4 (entry), §2.13.8 (markup payloads), §2.14 O9 (P1–P4, P7 trusted) | S7 |
| R-5.9.1–R-5.9.9 | §2.13.5 | S7 |
| R-5.10.1–R-5.10.12 | §2.13.6, §2.13.7 | S8 |
| R-5.11.1–R-5.11.6 | §2.13.10 | S7 |
| R-5.12.1 | §2.13.7 (fiber = escaped closure) | S4 |
| R-5.12.2 | §2.13.6 (`once` word on `Log.*`'s `work`) | S8 |
| R-5.12.3 | §2.13.7 (`◆` barrier, loans, suspension) | S8 |
| R-5.12.4, R-5.12.5 | §2.13.7 | S8 |
| R-5.13.1 | §2.13.13, §2.10 `writes` (a write of what arrived) | S5 |
| R-5.13.2 | §2.6 `type_dispatch` | S3 |
| R-6.1–R-6.12 | §6 | S3, S5, S7 |
| R-7.1 | §4, §7.6 | S9 |
| R-7.2 | §4.1, §4.2 | S9 |
| R-7.3, R-7.4, R-7.5 | §4.4 | all |
| R-7.6, R-7.7 | §3.8 | S3 |
| R-7.8 | §3.9 (per-worker arenas, the DAG hook in `Enforce`) | S6 |
| R-7.9 | §3.7 (the pass emits nothing) | S3 |
| R-7.10 | §3, §5 | S1 |
| R-7.11 | §6 last paragraph | S9 |
| R-7.12 | §3.9 (explicit stacks), §4.4 | S1 |
| R-7.13 | §8 S6 (checked core) | S6 |
| R-7.14 | §3.7, §7.2 (`dump`, hidden flags: `--ownership-totals`, `--ownership-flips`, `--ownership-records-lost`, `--sanitize-records`, `--sanitize-lists`, `--records-in-place`, `--ownership=v1\|v2`; `--ownership-everywhere` is transitional for S0's v1 runs and is deleted at S10 with the `"lists"` key) | S3–S9 |
| R-7.15 | §3.7 `Report` | S3 |
| R-8.1–R-8.11 | §7, §8 | S9, S10 |
