# 109 — Ownership v2 against the theory: where the quadratic costs come from

*Draft research report, 2026-11-02. A reading task: nothing was built, run or measured for this
report. Every figure below is quoted from an issue, a diary entry, `ownership-v2.md` or an
experiment report, and is cited there. The question is the owner's: the ownership checker v2 keeps
meeting quadratic blow-ups. Is it off the theoretical path, and if so, what does the theory say to
do? This report is not normative. Every decision it names is the owner's.*

**Read for this report.**
- `ownership-v2.md`: §1, §2.1–§2.3, §2.9 (its opening rules), §2.12, §4.1–§4.2, §8's Q8 paragraphs
  and §9.
- `ownership-requirements.md`: R-1.2, R-4.1, R-4.6, R-7.1–R-7.4.
- Research 68, 69 and 71 (§2.4, §3.5, §3.8).
- The module headers of `src/own2/` (`Shape`, `Cond`, `Propagate`, `Calls`, `Summary`, `Walk`, `Fix`,
  `Holders`).
- Issues #1054, #1120, #1372, #1414, #1420, #1427, #1446, #1450, #1488, #1590 and #1620, with
  their comments.
- The diaries of 2026-11-02 (`0726-own2-manager-day…`, `1220-slot-domain-decision-experiment`), and
  the slot-domain report (`experiments/slot-domain/report.md` on branch `exp-slot-domain`).
- The talk `references/talks/2025-unknown-rust-and-the-price-of-ignoring-theory/` and its
  `sources/pdf/*.txt`.

---

## 0. Summary

**The verdict: partly.** v2 is not ad hoc in its parts. Almost every component has a published
ancestor, and §1.2 names most of them (§2 below has the table). The departure from theory is one
decision, and it is the one that costs: **the carrier of the abstract domain.** §1.3 chose candidate
(a), a shape graph over *values*, with nodes that the program's computation makes: `union`,
`choice`, `positions`, `view`, `delta`, `recast` and folded knots (§2.3). Its κ is keyed by
`(NodeId, path)` per value interpretation (§2.9). Every inference system that checks uniqueness or
ownership with no annotations and stays cheap uses a carrier indexed by *type positions* instead:
- Clean's uniqueness attributes;
- Aspinall–Hofmann–Konečný's usage aspects;
- Morphic's per-slot modes;
- Brandon et al.'s inferred borrows;
- OxCaml's mode inference;
- research 71's own `Path ⇀ ℘(Cell)`.

The facts per program point in those systems are bounded by the types, and the joins are pointwise.
v2's state has no such bound. §4.1 says so: "No part bounds a group whose class itself grows per
round", and v2 "makes no general source-linear claim". The resource account (R-7.4) bounds what the
domain does not.

§1.2 assumed that (a)'s cost was a matter of representation ("Its known cost, and v1's failure, is
representation"). The issues refute that. Interning, memos, fold-first and the data-oriented S0–S4
work each cut a constant, but the record counts stay superlinear. The diary of 2026-11-02 says why:
"cutting cost per record (DOD) and cutting the number of records (the domain) are separate
problems". The 2026-11-02 experiments on `Dict.removeMin` isolate the cause.
- **Contracts + S6d** (a fixed slot contract at recursive boundaries, v2's body walk kept): best
  1 151 314 records.
- **Slot domain** (the local values also slot-keyed): **20 214** records, growth 0, against a limit
  of 65 536.
- The slot domain's first-order sample showed 0 accept→refuse lines and 17 documented-safe
  refuse→accept lines (§8 Q8).

That experiment re-derived a type-indexed carrier, but it was not framed as theory. This report
supplies the framing and the parts of the theory the build still needs.

**The owner's hypothesis is wrong in two places:**
1. **"Type-directed instead of constraint-based" is the wrong axis.** v2 is not constraint-based.
   It is abstract interpretation. The cheap inferred systems *are* constraint-based (Clean's
   attribute inequalities, Morphic's `u ≤ v`, Brandon et al.'s Datalog equations). What matters is
   what the constraints range over: type positions, or values.
2. **The annotated systems in the talk do not apply as they stand.** Granule, QTT, Linear Haskell,
   fractional uniqueness and Oxide all need written signatures, which beni has refused. Granule
   needs top-level signatures, has no inference, and has undecidable checking in general
   (`granule-…icfp19.txt` l.123, l.1261). Used as typed systems, they would refuse programs v2
   accepts by design (§4).

**The three largest causes of the quadratic trouble, and the theory's answer:**

| # | Cause in v2 | Issues | The theory's answer |
|---|---|---|---|
| 1 | Value-indexed abstract values. Towers and recursive ports keep one structure per level or round: choices keep their arms (§2.3, #1128); widen is the identity on acyclic values; read-off mints new ids each round. | #1120, #1372, #1420, #1427, #1446, #1450, #1590, #1620 | A carrier fixed by the function's type: facts per type slot, joined pointwise, with a fixpoint whose height is bounded by slots × origins (Clean, Morphic, AHK 2008). **Measured** on `removeMin` by the slot experiment. |
| 2 | Exclusivity as a relation. It is re-derived on each read from cell multisets and stored as nested `apart` groups and pairwise per-base comparisons. | #1054, #1427, #1488, #1414 | **Multiplicity as a grade.** Coexisting parts *add* (QTT's Γ₁+Γ₂), and alternatives share one context. **Separation as a set** (an iterated separating conjunction, Reynolds 2002; the slot report's "selection"), where a conjunction is a union. Both are O(1) per occurrence. No theory removes #1414's refinement chains; only dropping materialisation does. |
| 3 | Lazy call views and per-round identities. A call's result is a view forced at each reader; every round re-images the port with new NodeIds. | #1372 (causes A and D), #1488, #1146 | **Instantiation is substitution:** apply a polymorphic summary's attribute or grade variables eagerly, once per call site (Clean; Granule's grade polymorphism; Morphic's signature variables). This is cheap only once cause 1 is fixed, because then the summary is small. |

**The recommendations, ranked** (§6 has the detail):
1. Take Q8's slot-keyed local domain as the carrier, specified as type-position attributes plus one
   selection. This is the owner's decision: it reverses §1.3 and changes verdicts.
2. Multiplicity as a grade, and Sep as a normalised union of selections. Its v2-side pieces, #1054's
   index and #1427's subsumption, fit inside the current contract.
3. Eager per-call-site substitution of contracts. It fits inside R-7.3.
4. Semi-naive delivery along recursive edges. It fits inside the contract and needs (1).
5. A soundness argument per rule, following Entente's past/future split. It fits inside the
   contract.

**Not recommended:**
- annotated graded, linear or fractional types (a language decision; rule 7);
- Perceus or Lean reuse (forbidden by R-1.2);
- unification-based attributes (Emre et al.);
- more constant-factor work on the shape domain.

---

## 1. What the prior surveys did, and where they stop

- **Research 68** (survey) and **69** (deep dive) weigh the field for **precision and ergonomics**:
  - which systems infer and which report errors;
  - false-error rates, Sisal's 1.4 %, and Clean's recipe;
  - the hard places: closures, polymorphic plumbing, containers and modules.

  69 §1.3 lists what makes a checker precise. Neither weighs **asymptotic cost by family**. Granule,
  QTT, fractional uniqueness, Oxide and Mezzo appear in 68 §3 and §5 as a reading list, with one
  line each. 69 §2.6 notes Linear Haskell's n² `newXBeside` functions, which is an API cost, not
  an analysis cost.
- **Research 71** (thesis) chose a **type-path carrier**. Its §2.4 is `A(e) : Path ⇀ ℘(Cell)` over
  list-typed paths. Its §3.8 bound is O(|body|·w) per round, with w the number of tracked paths of
  the widest type. Its §3.5 bounds the rounds at `h ≤ 2·P + R + 2·F`, citing AHK 2008 and Lean for
  the optimistic fixpoint. **That carrier is the theory's shape.** v1 built it and failed in the
  ways §4.2 lists:
  - #856: paths enumerated exponentially;
  - #955: cyclic types;
  - #693: pairwise `sep`;
  - #716: lists instantiated as lists.
- **`ownership-v2.md` §1.2** read those failures as failures of representation. It rejected:
  - (b), Clean: on P2, P3, P5 and P7;
  - (d), Morphic: because "a mode is owned or borrowed, not which object", with no closures.

  It kept (d)'s *place set* but not its *carrier*. It then put the value precision of P3, P5 and P6
  into the shape graph. **No document weighed the cost of that move against the type-indexed
  alternatives.** That gap is what this report fills. The 2026-11-02 experiments supplied the
  measurement after the fact.

What the surveys got right still stands:
- reads before writes;
- directional flow, not unification;
- the optimistic fixpoint;
- summaries in the interface;
- the demand only in `core/`.

None of those is a cause of the quadratic trouble.

---

## 2. v2's semantic core, mapped to known systems

| v2 component (§) | Known system | Faithful, adapted, or new |
|---|---|---|
| Places folded per type SCC, canonical paths with `⟲` (§2.1) | Morphic's `SccParameterizer` (A:295-432); Deutsch's folded access paths; Mazur's type selector (Mercury CTGC) | Faithful in idea. The *first return* rule (#1253) and *one position, one name* (2026-10-31) are new, made for P6 precision. |
| Cells: `site`, `param`, `result`, `cb`, `⊤` (§2.2) | Allocation-site abstraction (Chase–Wegman–Zadeck 1990); research 71 §2.4 | Faithful |
| Refinements `elem`, `others`, `level`, `below`, part cells (§2.2) | Sagiv–Reps–Wilhelm *focus*, i.e. materialisation | Adapted. The part cells of #1390 are new. |
| Shape nodes, structurally interned, with `union`, `delta`, `view` (§2.3) | Shape graphs (CWZ, SRW); Whaley–Rinard escape graphs composed by grafting | Faithful as a family. Using them as a *summary carrier* for inference with no widening on acyclic values is v2's own. |
| `choice` against `positions` (#1128) | **QTT and Granule**: coexisting subterms *add* their usage (`Γ₁ + Γ₂`, `atkey-qtt-lics18.txt` l.173-175, l.228); branches share one context (`ElimBool`, l.229) | **A re-derivation of graded context addition**, applied per node occurrence instead of per variable or slot |
| κ: `yes`, `apart{…}`, `excl`, `shared`, `lost` per `(NodeId, path)` (§2.9) | Clean's deep uniqueness `*[*a]` (Barendsen–Smetsers 1996); separation predicates (`is`, SRW) | Adapted. The keying by `(NodeId, path)`, root-relative tries, the path-multiset primitive and the fold certificate are **new**. |
| `xreq` / `req`, and a callee's requirement discharged at the caller (R-4.6.6) | Clean's attribute variables with `u ≤ v` propagation; uniqueness polymorphism (de Vries et al. 2007) | Faithful in purpose |
| Liveness per path; dead aliases accepted (§2.7, P7) | Rust NLL; Oxide's flow-sensitive typing; Lean's and Perceus's last use | Faithful |
| Demand = no other holder ∧ exclusive contents (§2.8) | **Entente cordiale** (Marshall, Vollmer, Orchard, ESOP 2022): linearity restricts the *future*, uniqueness guarantees the *past* (`entente-cordiale-esop22.txt` l.396-408) | v2's check is the conjunction of the two: holders and liveness are the future half, κ and provenance the past half. Nobody in the repository has said so. |
| Summaries as classes; a function parameter is a placeholder `cb_j` (§2.10) | Clean's attribute-polymorphic function types; Koka's borrowed-by-default parameters | Adapted. Per-call-site callback labels (R-7.3) are stronger than any published inferred system. |
| Optimistic fixpoint, then validation (§2.12) | AHK 2008 §6.2; Lean `InferBorrow`; Brandon et al. 2026 §4.4 (Datalog) | Faithful in the *driver*. The *unknown* is a whole versioned class with κ (§2.12, *Equations over recursive value interpretations*), not a finite fact set. This is the departure. |
| Loud contract, no fallback (§1.3 item 8) | Koka `fip` | Faithful |
| `Ref` loans (§2.13.7, #981) | Oxide's loans and provenances | Close in vocabulary. Not traced further. |
| The account: lanes, continuation, growth (§4.1, §4.4) | none | New. It exists because the domain has no a-priori bound (§3.1 below). |

So the hypothesis "v2 ignores theory" is false for the parts. It is true for their combination: a
type-theoretic *check* (Entente's two halves) computed over a shape-analysis *carrier*. Shape
analysis is the part of the literature known for its cost. 69 §2.2 quotes the earlier
update-in-place analyses as "exponential or doubly exponential".

---

## 3. The quadratic families, by cause

### 3.1 The carrier: abstract values that grow with the computation

**The families.**
- **Towers.**
  - #1120, `Rose [ r_{k−1}, Rose [] ]`: block n^2.4, 31 cells where the value holds 2.
  - #1420: K at 307 332 records for 100 levels; `Rose [ r, r ]` refused at 100.
  - #1450: K's block writes Θ(n²) positions.
  - #1427: the T tower keeps one `apart` group per level.
  - #1446: a deep `T (List T)` literal passed to a writer is n routes × n nodes.
- **Recursive groups.**
  - #1372: GroupFieldShift's port is 2 056 nodes at n = 16, with only 37 structurally distinct;
    each round costs O(round²), so the total is about n⁴.
  - #1590: `removeMin`'s port grows about 4× in arms per round, with every κ `lost`.
  - #1620: `propagate`'s Σ fans out by recast inners, from 2.8 to 12.9 states per joined node.

**What in the design causes it.**
- §1.3 item 2 makes abstract values "structurally interned shape nodes", widened "in every fixpoint
  unknown" only, and §2.3 widens only on cycles ("widen is the identity on an acyclic value",
  #1372's comment on C).
- A `choice` keeps every arm (§2.3, #1128). The fixpoint step is `x_{i+1} = widen(x_i ⊔ F(x_i))`
  over a whole class (§2.12). So the class can gain arms every round, and nothing bounds it but
  R-7.4.
- Every reader then pays per element of that class: `propagate` (`Propagate.zig`, linear in Σ,
  which is unbounded), `kappaRelabel`, `Shape.proj` and views. §4.1 says this outright: "A later
  walk … costs about c · |x_r| records, where |x_r| is the whole port it reads".
- The code shows the same thing. `Shape.map` mints a new id for every image each round
  (`Walk.zig:675`, #1372 cause A). `Shape.joinAlternatives` (`Shape.zig:2638`) exists only to stop
  the choice DAG nesting r³/6 deep (#1372 cause B).

**What the theory does.**
- In Clean, AHK, Morphic and Brandon et al., the summary of `f : τ₁ … τₙ → σ` is a map from the
  **type positions** of τ̄ and σ to a finite lattice:
  - a uniqueness attribute (Clean);
  - a usage aspect from 1 to 3 (AHK);
  - owned or borrowed, plus a lifetime (Morphic, Brandon).
- A branch joins pointwise, so the join costs O(|positions|). A recursive group is a monotone
  system over a lattice of height h = O(|positions| · |lattice|). Kleene iteration ends in at most
  h rounds, each costing O(Σ|body| · |positions|) (research 71 §3.5, §3.8, citing AHK 2008 §6.2 and
  Brandon et al. 2026 §4.4).
- A tower like K, `if c then Rose [r] else r`, is then n bindings over one type with fixed slots,
  each joined pointwise: O(n · |slots|). That is linear by construction, with no fold certificate
  and no arm quotient.
- **Measured** (§8 Q8, *the slot-domain experiment*): generic `removeMin` takes 20 214 records over
  4 rounds on a 20-slot contract. Fields 1/2/4/8 are linear, and copies cost exactly ×k. On the
  same module, v2 makes 605 664 calls into `Shape`, `KappaRead` and `Propagate`, and the slot path
  makes 0.

**What a type-indexed carrier loses, and how the slot domain buys it back.** A pure attribute per
type position cannot say:
- that two levels of a tower hold different objects (P6);
- that the arms of a branch are correlated across paths (#1590's caveat: "a pointwise join loses
  which cells occur together in one arm across paths");
- that element `elem c·ι` is not `others c·ι` (P5).

The slot domain adds three things on top of type slots:
- **positions**, the source projections from a root (a parameter or one call site's result). Their
  number is bounded by the source, as Oxide's loans are bounded by the borrow expressions;
- **choice tags**, so that two values of one choice are compared arm by arm;
- **origins** per slot (P3's provenance).

This is the standard way to stay finite: precision that the *text* names is source-bounded, and
everything else folds at the type. Clean does the same, counting syntactic occurrences over
attributed types.

In the sample this lost nothing (0 accept→refuse in 280 demand positions), but the full ledger of
477 tokens has not been run, so that result is not settled.

**One risk that no document has measured.** `p/DeepTupleDag` (R-7.2: "a 16-deep tuple holding `x`
at 2¹⁶ places", no limit allowed) has a *type* that is a DAG with 2¹⁶ canonical paths. A carrier
keyed by canonical paths would be exponential there. v2 fixed #856 with hash-consed *nodes*. A slot
domain must keep slots shared per place, and split them by path only where a reader asks. Clean's
attributes on a tree-shaped type term would have the same problem. The slot report does not
mention this fixture.

### 3.2 Exclusivity as a relation over occurrences

**The families.**
- #1054: `Cond.lower` compares each arrival with every member of a different base, which costs
  O(W²) (`Cond.zig`, the `base(g) != base(c)` skip). W = 400 exhausts the allowance.
- #1427: one `apart` group per level, each a superset of the last: Θ(n²) atoms in the block.
- #1488: `deep` over a knot chain is Θ(n²), because "a knot's union cells hold every cell below it".
- #1414: a refinement chain is climbed per read, so the cost is quadratic in pattern and
  projection depth.
- The slot prototype's own first version had the same problem: "a pairwise check over leaves
  brought the fields quadratic back" (diary 1220).

**What in the design causes it.** κ is not a property of a binding or a slot. It is "the join of
the stored κ with the κ DERIVED at the read's position from the node's cells" (`Cond.zig` header,
§2.9). It is derived from a *path-multiset primitive* that counts "occurrences in the pre-fold
source structure" (§2.3). So multiplicity is re-computed from structure at every read, and `apart`
facts are kept as nested groups per construction.

**What the theory does.** Two mechanisms, both linear.

1. **Multiplicity is a grade, and it composes by the semiring.** In QTT (Atkey 2018) a pair's
   context is `Γ₁ + Γ₂` (l.228): the occurrences of x in coexisting parts *add*. An eliminator's
   branches are typed in one shared context (l.229): alternatives take the maximum under
   subusaging. With the semiring {0, 1, ω}:
   - `[ x, x ]` gives x the grade 1 + 1 = ω, and `if c then x else x` gives 1;
   - each occurrence costs O(1), at the point where it is made;
   - nothing is re-derived when the value is read.

   v2's `positions`/`choice` distinction (#1128) is exactly this rule. It was found again from a
   soundness defect (`kidsPush`, `onePush`). But it is applied per *node occurrence* in a DAG that
   folds, so the count must be recovered through the fold (§2.9's primitive, `Calls.preimage`).
   Graded on slots and origins instead, it is a counter per (origin, slot) that a construction
   adds to.
2. **Separation is a set, not a table of pairs.** Separation logic's iterated separating
   conjunction (Reynolds 2002), alias types (Smith–Walker–Morrisett 2000) and fractional
   permissions (Boyland 2003) all state disjointness as one predicate over a *collection*. Splitting
   a permission is linear, and a superset implies every subset. The slot domain's *selection* is
   this predicate: "(parameter, slot) occurrences whose objects occur once among them. A
   conjunction is a union, never a table of pairs" (diary 1220). Under it:
   - #1427's nested groups collapse to the largest one;
   - #1054's comparison becomes a lookup of a grade per base.

Entente's substitution reading (l.403-408) gives the rule for calls. A unique value substituted in
stays unique, so instantiating a callee's selection on its arguments needs no pairwise check.
Instead, two callee occurrences that reach one caller value by one route ask for that value's own
selection. This is the slot experiment's route rule (requirement 2 in its report), which it found
by a failing control.

**Where the theory does not help.** #1414 comes from materialisation: refinement cells nested as
deep as the patterns. No type theory has `elem` against `others`. Clean's `*[*a]` makes every
element of a unique list unique and distinct. That accepts R-4.6.7 (`ExclusiveFreshHelper.two`) and
refuses R-4.6.9 (`PatternStoredBack`: `l` is used again after `p` is taken out of it), with no
refinement at all. A type-indexed carrier with source positions removes the chain. The cost is the
precision of `part` cells (#1390) beyond what positions name.

### 3.3 Lazy views and identities minted per round

**The families.**
- #1372 cause A: read-off images are new NodeIds every round, so every node-keyed memo misses.
- #1372 cause D: n views of one template are forced separately. Joining them was rejected as
  unsound without 4c's hypothesis node.
- #1488: a deep read of a view over a knot chain.
- #1146 (closed): `linkArgs` was quadratic over the same chain.

**What in the design causes it.** §2.11 *Representation of a view*: "a call's result by reference
… forced one step at a time, never copied". Views are lazy because a class can be large: a class
is a shape DAG. Laziness then moves the cost to every reader. §2.9 *Keyed where a reader looks*
needs a projection-correspondence machinery (`proj_origins`, `Cond.projectedImage`) only to find
where a view's κ lives.

**What the theory does.** In every typed system, instantiating a summary is **substitution**:
Clean's attribute variables, Granule's grade polymorphism, Morphic's signature variables.
- It is done once per call site, eagerly.
- It costs O(|scheme|), and the result is ordinary facts in the caller's slots.
- The slot experiment does this ("a call is instantiated once per call site per summary
  generation").
- Its measured cost per written instruction is about 62 records, against 7 400 for contracts with
  S6d.

This fits R-7.3: per-call-site labels stay distinct, and each one costs |slots|. It is only cheap
once §3.1 is fixed. Under v2's carrier, eager instantiation would copy a DAG that §4.1 cannot bound.

### 3.4 Routes below `⟲`

**The families.**
- #1446: each write route below a `⟲` walks the actual again.
- #1420 `Rose [ r, r ]`: each projection of a `positions` chain of depth d makes d nodes.
- #1253 (closed): first returns and the K² closure.

**What in the design causes it.** P6 asks that the levels be "told apart where the text does".
§2.1's first-return rule and §2.11 item 3's "one demand per path of the pair graph" serve that
request.

**What the theory does.**
- Type-SCC folding (Morphic; Clean's one attribute per position of a recursive type definition)
  gives one slot per level class. That is linear, but it cannot tell `l` from `r`.
- The slot domain keeps v2's `Place` (first returns, `expandLevels`), so this precision stays at
  the type level, and tells concrete levels apart only through positions.

So the theory helps partly. The type side is bounded. The route-per-pair-graph walk of #1446
becomes a walk over positions, and positions are bounded by the source.

### 3.5 Fixpoint re-walks

**The families.**
- #1372 cause E: every walk after the second re-reads the whole port.
- #1589: delivering only new arms is "unproved and stays off".
- In the slot prototype: `rotate` is O(N²), because it re-walks the body each round.

**What the theory does.** Semi-naive (differential) evaluation of monotone equations: the standard
Datalog technique that Brandon et al. rely on. Each round propagates only the delta. It needs the
unknowns to be a **monotone set of facts**. v2's unknown is not one: κ weakens, the structure
changes, and §2.12 forbids "reconstructing every level of `apart` … on each delivery". The sparse
inclusion-edge propagation of §2.12 (after Morphic I:114-171) is already semi-naive for *cells*. A
slot carrier makes the *whole* summary a monotone fact set:
- arrivals only grow;
- `res_cond` only weakens (slot report, Checkpoint 2).

Semi-naive delivery then applies to all of it. This depends on §3.1.

### 3.6 What no theory removes

- **Callbacks and closures with no annotation** (R-5.2, R-5.4). Every typed system in the talk's
  sources needs signatures:
  - Granule: "top-level definitions must have a type signature (inference and principal types is
    further work)", l.123;
  - QTT and Idris 2: multiplicities on binders, which default to unrestricted;
  - Linear Haskell: multiplicity on arrows;
  - fractional uniqueness: explicit `withBorrow`, `split` and `join`.

  The inferred ones are weak on higher-order code. Clean's report calls that part "complex and
  moreover incomplete" (research 69 §1.1), and Koka warns on it. The slot experiment is first-order
  only: 748 core declarations are `unsupported`. Its next checkpoint (callbacks, accumulator folds,
  retained values, loans) is where context growth "will show first" (its report, S3). No paper says
  this will be cheap.
- **The precision demanded by R-7.3** (no silent coarsening, distinct per-call-site labels) has no
  analogue in any published inferred system. Under a slot carrier it is affordable, because each
  label costs |slots|. But it is a requirement beyond theory, not a theorem.
- **Evidence against "type-indexed is automatically cheap".** Roc removed Morphic because "the core
  algorithm can get way too slow to be worth running during a roc build" (research 68 §4, Zulip).
  Morphic specialised whole programs per alias mode. A per-module slot domain with summaries in the
  interface does not specialise, so this does not transfer directly. Still, a type-indexed carrier
  still needs its cost measured. It is not proved by citing a paper.

---

## 4. What an annotated typed system would refuse

The talk's positive models, used as type systems, would refuse programs that the requirements
oblige v2 to accept. The table is a reading of the rules against the fixtures, not a run.

| Program (requirement, fixture) | v2 | Linear or graded by occurrence (Granule, QTT, Linear Haskell) | Clean (inferred uniqueness) | Oxide / NLL |
|---|---|---|---|---|
| `[ …xs, List.length xs ]` (R-4.1.3) | accept | refuse unless the read is a written borrow (`withBorrow`, fractional) | refuse without an observer or strict `let` (§1.2) | accept (two-phase borrow) |
| a read before the write, `List.set xs i (List.get xs j + 1)` (R-4.1.5) | accept | needs a written borrow | needs observers | accept |
| `a = [ r, r ]` dead, `b = [ r ]` written (`DeadDuplicateLive`, Appendix B) | accept | refuse: r has grade ω | refuse: three occurrences | accept |
| `ys = xs`, write through `ys`, `xs` dead (P7) | accept | accept | accept | accept |
| distinct fresh elements, `want (push (push [] [1]) [2])` (R-4.6.7, `ExclusiveFreshHelper.two`) | pending fixture, red on master | accept with `*(List Int)` elements, written | accept (`*[*a]`) | n/a |
| an element stored back (R-4.6.9, `PatternStoredBack`) | must refuse | refuse | refuse | n/a |
| `model.todos` written, `model.name` read later (R-4.1.2) | accept | needs a record split by hand | accept (`SelectiveUse`) | accept (disjoint places) |
| `List.map list λrow → if … then f row else row` keeps exclusivity (R-5.2.9) | accept | needs `f`'s multiplicity written | partial (invariant function types, §1.2) | needs lifetimes |
| one view of a tree written, two refused (`FoldCertificate.oneView` / `twoViews`) | accept / refuse | accept / refuse, with `incAll : *Tree ⊸ *Tree` written | accept / refuse | accept / refuse |
| `w = mkPusher xs; ( w 1, w 2 )` (R-5.4.4, `CalledTwicePusher`) | must refuse | refuse (the closure is linear) | refuse (a closure holding a unique value is unique) | refuse |

What this shows:
- A typed discipline is sound on the refusals, and would add **annotations on every writer's
  signature**.
- It would refuse the dead-alias and read-before-write rows, unless they are rewritten with explicit
  borrows.
- Liveness is what makes those rows pass, and liveness is Oxide/NLL's territory, not the graded
  systems'.
- Adopting any of them as the user-facing model is a language change, the owner's under rule 7. It
  would also reverse research 69's finding that the demand lives only in `core/`.

The useful lesson is the *internal* one. v2 already computes Entente's two halves:
- the future half, as liveness and holders;
- the past half, as κ and provenance.

The theory says to compute the past half over type positions with grades and separation sets, and
the future half flow-sensitively, as Oxide does.

---

## 5. Judgment on the hypothesis

| Claim | Verdict |
|---|---|
| v2 is ad hoc where a principled formulation exists | **Partly.** The check, the driver, the places, the cells, liveness and the contract are each published technique. The shape-graph carrier for summaries, κ keyed by `(NodeId, path)`, the path-multiset primitive, the fold certificate and the account are new, and the cost lives in them. |
| A principled formulation would avoid the quadratics by construction | **For causes 1–3 and 5: yes, if "principled" means a type-indexed carrier with grades and separation sets.** The slot experiment is the evidence (20 214 against 1.15M+ records). **For #1414 and the callback contexts: not shown.** For a DAG-shaped type such as `DeepTupleDag`: a naive type-path carrier is *worse*. |
| Linearity, uniqueness, graded or QTT types are the fix | **No, as types.** They need written signatures and would refuse required programs (§4). **Yes, as the algebra inside the inference:** grades add for coexisting parts and take the maximum over alternatives, and Sep is a set. |
| Regions or fractional ownership are the fix | Regions: only for `Ref` loans (#981), where Oxide is the right model. Fractional: it explains reads-before-writes as temporary borrows. v2 infers those scopes by liveness, which the theory leaves to the programmer. |
| Type-directed instead of constraint-based | **The wrong axis.** The cheap inferred systems are constraint-based. The axis that matters is a *type-indexed* carrier against a *value-indexed* one. |

The manager's diary of 2026-11-02 has a line that is the strongest evidence for the owner's
suspicion: "Rules that are exact on paper keep turning out to depend on the representation. Every
review round found a real hole". Five unsound accepts were fixed in that period: #1516, #1523,
#1530, #1526 and #1582. In a type-indexed system, soundness is argued per typing rule and does not
depend on how a DAG is interned. v2's I-κ (§2.14) has to hold across interning, folding,
relabelling and laziness, which is where the holes were found.

---

## 6. Recommendations, ranked

The ranking weighs the quadratic trouble removed against the cost to the design.

**1. Make the type-indexed slot domain the local carrier, specified as theory.** Q8's next step,
with the framing this report supplies.
- **The specification.**
  - Slots are type positions, per `Place`, with `expandLevels`.
  - Facts per slot form a finite lattice: arrivals (origins), W, a grade, a selection.
  - Coexisting parts add and alternatives share one context (QTT).
  - Separation is one selection per condition, a union, normalised by inclusion.
  - Calls instantiate by substitution, once per call site.
  - The group fixpoint starts at ⊥, iterates over a monotone fact set, then validates.
- **What it removes.** §3.1–§3.3 and §3.5, and §3.4 in part. The open issues it addresses are
  #1120, #1372, #1420, #1427, #1446, #1450, #1488, #1590 and #1620. #1054 vanishes as a
  consequence.
- **What it costs.**
  - It replaces `Shape`, `Cond`, `KappaRead`, `Propagate` and most of `Calls`, `Summary` and the
    block codec: about 27 000 of `src/own2/`'s 57 515 lines (line counts of those files on master).
  - It needs a spec amendment, which the slot report sketches in seven items.
  - It has the slot report's S1–S6 stages.
- **Whose decision.** **The owner's.** It reverses §1.3's choice of family. It changes verdicts:
  - 17 refuse→accept and 26 partial→refused in the sample;
  - the full ledger is not measured;
  - a selection "asks each region to be internally separate", which is stronger than pairwise
    `apart`. Programs with a read-only region that repeats an object beside a write would be
    newly refused. No sampled fixture does that, but **this is rejecting more programs, stated
    plainly**.
- **Gates before the decision.** Two checks should come before committing to the domain:
  - the callback checkpoint (the slot plan's S3);
  - `p/DeepTupleDag` (§3.1's risk).

  Those are the two places where theory gives no guarantee.

**2. Multiplicity as a grade; Sep as a normalised set.** This is most of (1)'s algebra, and part
of it applies to v2 today.
- `Cond.lower` indexed by base: #1054's own done-criterion, which is O(1) per arrival as a grade.
- #1427's subsumed groups dropped, because Sep over a superset implies Sep over every subset.

Inside the current contract; it removes #1054 and #1427 only. It does not touch cause 1.

**3. Eager per-call-site substitution of summaries.** Within R-7.3, because labels stay distinct.
It removes #1372's causes A and D and the view machinery of §2.9 *Keyed where a reader looks*.
Worth doing only with (1): under v2's carrier it would copy unbounded DAGs.

**4. Semi-naive delivery along recursive edges.** Datalog's standard technique. Inside the
contract. It removes the per-round re-walk: `rotate`'s O(N²) in the slot prototype, and #1589's
unproved delivery in v2. It needs a monotone fact set, which only (1) provides.

**5. A soundness argument per rule, on Entente's split.** State the demand as uniqueness (the past:
provenance and selection) ∧ linearity of the continuation (the future: liveness and holders).
Prove subject reduction per transfer rule over the slot carrier in `proofs/ownership/`. Inside the
contract. It removes no cost, but it addresses the run of unsound accepts that depended on the
representation (§5).

**Not recommended:**
- **Annotated graded, linear, QTT or fractional types for users.** A language decision, with
  signatures on every writer, and §4's refusals. The talk itself concedes that Granule has no
  "automatic operational interpretation" (notes, 26:04).
- **Perceus or Lean reset/reuse.** These need a reference count at run time, which R-1.2 forbids.
- **Unification-based attributes.** Emre et al.: four unsafe pointers poison 85 % of the program
  (research 69 §1.1).
- **More memos, interning and data-oriented work on the shape carrier.**
  - S0–S4 cut instructions 3.2–3.4×, but the budget counts records (diary 0726).
  - S6d removed 15–20 % of records and is "close to its ceiling" (Q8).
  - #1590's arm quotient made walks costlier.

  Each was correct work, and none changes the asymptotics, because the carrier has no bound.

---

## 7. What this report did not establish

- **No measurement of its own.** The slot domain's figures are its report's: Debug builds, a
  first-order scope, and 22 fixtures with 280 demand positions, not the 477 tokens.
- **Whether a type-indexed carrier stays linear through callbacks**, folds with accumulators,
  `Ref` loans and suspension. This is the open research question that research 69 §1.3 item 9
  already named.
- **`p/DeepTupleDag` under slots.**
- **Whether Clean's attribute inference, run on beni's corpus, would match the slot domain's
  verdicts.** That would be a cheap oracle to build, and no one has built it.
- Perceus, Counting Immutable Beans, Clean's reports, Mezzo and Brandon et al. are cited through
  research 68/69 and `ownership-v2.md` §1.2. They were not re-read for this report. The talk's
  `sources/pdf/` copies (Entente, Granule, QTT, Idris 2, fractional uniqueness, Oxide) were read
  only at the lines cited.

## Sources

- `ownership-v2.md`: §1.2–§1.3, §2.1, §2.3, §2.9, §2.11, §2.12, §4.1, §4.2, §8 Q8 (the
  recursive-contract, contracts + S6d and slot-domain paragraphs), §9.
- `ownership-requirements.md`: R-1.2, R-4.1.2–R-4.1.5, R-4.6.7–R-4.6.9, R-5.2.9, R-7.2–R-7.4.
- Research 68 §3–§4; 69 §1.1, §1.3, §2.2, §2.6; 71 §2.4, §3.5, §3.8.
- Branch `exp-slot-domain`, `experiments/slot-domain/report.md`. Diaries
  `plans/diary/2026-11-02-0726-own2-manager-day-s3b-dod-experiments.md` and
  `2026-11-02-1220-slot-domain-decision-experiment.md`.
- Issues #1054, #1120, #1146, #1372, #1414, #1420, #1427, #1446, #1450, #1488, #1589, #1590 and
  #1620, read on 2026-11-02.
- Code: `src/own2/Shape.zig` (`joinAlternatives` :2638, `map` :2972, `widen` :3524),
  `Propagate.zig:117`, `KappaRead.zig` (`deep` :2534, `lower` :2835), `Calls.zig:2255` (`apply`),
  `Groups.zig:1730` (`solveGroup`), `Walk.zig:675` (the read-off relabel, per #1372).
- Under `references/talks/2025-unknown-rust-and-the-price-of-ignoring-theory/sources/pdf/`:
  - Marshall, Vollmer, Orchard, *Linearity and Uniqueness: An Entente Cordiale*, ESOP 2022:
    `entente-cordiale-esop22.txt` l.390-408;
  - Atkey, *Syntax and Semantics of Quantitative Type Theory*, LICS 2018: `atkey-qtt-lics18.txt`
    l.163-175, l.228-229;
  - Orchard, Liepelt, Eades, *Quantitative Program Reasoning with Graded Modal Types*, ICFP 2019:
    `granule-quantitative-reasoning-icfp19.txt` l.99-100, l.123, l.1261;
  - Marshall, Orchard, *Functional Ownership through Fractional Uniqueness*, OOPSLA 2024;
  - Weiss et al., *Oxide*, 2019;
  - Brady, *Idris 2*, ECOOP 2021;
  - Bernardy et al., *Linear Haskell*, POPL 2018.
- Cited through research 68, 69 and 71:
  - Barendsen & Smetsers, MSCS 1996, and de Vries, Plasmeijer, Abrahamson, IFL 2006/2007 (Clean);
  - Aspinall, Hofmann, Konečný, JFP 2008;
  - Brandon et al., *Fully-Automatic Type Inference for Borrows with Lifetimes*, OOPSLA 2026;
  - Reinking et al., *Perceus*, PLDI 2021;
  - Ullrich & de Moura, *Counting Immutable Beans*, IFL 2019;
  - Reynolds, LICS 2002;
  - Smith, Walker, Morrisett, ESOP 2000;
  - Boyland, SAS 2003;
  - Emre et al., OOPSLA 2023;
  - Sagiv, Reps, Wilhelm (shape analysis), and Chase, Wegman, Zadeck 1990, as `ownership-v2.md`
    §1.2 cites them;
  - Roc's Zulip on removing Morphic (research 68 §4).
