# Checker v2 — the architecture of the rewritten type checker

**Status.** Normative in three stages, set by the slices of
[`plans/checker-rewrite.md`](../../plans/checker-rewrite.md):

- **Shared code, from the slice that lands each part, for both checkers.**
  - §13 (the evidence-tree contract) from R2a, and §12.5 (`Convention`) from R2b.
  - §14.2 (interface v3) from R3.
  - §15.1's `Session` quiet rule from R1.
- **`src/check2/`**, the new checker, for everything else from R4b. The flag and harness exist from R4a.
- **`src/check/`**, the whole document, at the cut-over (R11).

Written 2026-09-24 at `master` = `7427828`. **Slice references.** Round 3 split four slices. A bare "R2" below means R2a, the tree contract, except where it names `Convention` (R2b). "R4" means R4a for the flag, harness and cache key, and R4b for the foundation. "R6" means R6a for resolution and `check`, and R6b for elaboration and `build`. "R8" means R8a for the fixpoint, D4 and install, and R8b for D1 privacy and schema endpoints. `checker-rewrite.md` §4 is authoritative. Revised the same day after a read-only design review
(`review-design.md`, items B1–B7, S1–S22 and N1–N13; the revision is traced in §24). Every owner
decision it depends on was **taken by the owner on 2026-09-24** (§21), and the amendments the
review required are dated in §21.

**Why this document exists.** Five reviews of the checker at `7427828` found 61 defects,
catalogued as CK-01 … CK-61 in [`plans/checker-findings.md`](../../plans/checker-findings.md).
About half compile a program and then give a wrong answer at run time. They fall into fourteen
root-cause classes, K1 … K14. The owner decided to rewrite the checker from the ground up, so that
**its structure makes each class impossible, or checked**, rather than patching each finding.

**What it supersedes, and what it does not.** [`checker.md`](checker.md) and
[`static-dispatch-spike.md`](static-dispatch-spike.md) stay normative for every external behaviour
not listed in §20. They also stay normative for the old checker until the cut-over. The table below
maps each old section to its replacement. Each of those sections carries a pointer note back here.
No section of either document is renumbered (CLAUDE.md rule 2).

| Old section | Replaced by | What changes |
|---|---|---|
| `checker.md` §5, the constraint set on `Flags` | §4.1, §4.2 | constraints become references to *wanteds*; their types are graph children |
| `checker.md` §6.2, "two additions … inside `unify`" | §7 | `unify` never resolves and never reports |
| `checker.md` §6.3, "a constrained `let` binding is not generalised" | §8.4, D5 | rule (a) is retired |
| `checker.md` §6.4, obligations | §8.5 | obligations whose variable escapes move to the outer rank |
| `checker.md` §6.5, `?` | §8.6, D2 | a deferred obligation, not a greedy probe |
| `checker.md` §6.6, the per-declaration gate | §15.2 | a failure bit, not diagnostic regions |
| `checker.md` §6.7, "has evidence parameters" defers | §12.5 | one `Convention` function |
| `static-dispatch-spike.md` §3.3, private methods | §11.3, D1 | |
| `static-dispatch-spike.md` §6.1–§6.4 | §4, §7–§10 | |
| `static-dispatch-spike.md` §6.3.1 step 4, capability paragraphs | §11 | |
| `static-dispatch-spike.md` §7.1–§7.3, the dispatch table | §13 | evidence *trees* |
| `static-dispatch-spike.md` §8.1–§8.2, what `Lower` recounts | §13.3 | |
| `static-dispatch-spike.md` §9.4, "one evidence parameter per type parameter" | §11.2, D4 | one parameter per context entry |
| `static-dispatch-spike.md` §10.12, `method_needs_annotation` | §10, D3 | retired |
| `static-dispatch-spike.md` §11, "a constrained `let` binding is monomorphic" | D5 | |

---

## 1. The fourteen classes, and the mechanism that closes each

| Class | Findings | Mechanism | § |
|---|---|---|---|
| **K1** Annotation generality unchecked | CK-01, CK-10 | **I1.** Every annotated binding is read once, as rigid variables at its own rank. After generalisation, every rigid must still be a distinct rigid root at the generalised rank; otherwise `rigid_mismatch` at the recorded capture site | §8.3 |
| **K2** Constraints and obligations outside the graph | CK-02, CK-05, CK-06, CK-18, CK-29 | **I2.** Every walk takes its successors from one of two `Walk` functions and declares which. `owned` includes a variable's wanteds' method types and serves rank adjustment, copy, the error scan, publication and the merge's rank lowering. `structural` excludes them and serves occurs, the marker walk and the resolver walks. **I15.** A wanted's method-type variables never outrank its receiver: attaching lowers them. **I3.** Obligations ride on their variables, like wanteds, and share one rank (§4.5), so one whose variable escaped travels with it | §4.1, §7.1, §8 |
| **K3** Walks that are not total | CK-03, CK-04, CK-08, CK-10, CK-37 | **I4.** No walk has a fixed-size stack, and none answers when it gives up. Every walk that can meet a cycle uses the epoch colour of §4.1 over `structural` successors and reports `infinite_type` when it does. A lambda's and a case branch's binders are occurs-checked when the lambda or branch ends. Every boundary occurs-checks after its last unification. Records are normalised on merge, and closedness reads the whole chain | §4.1, §7.3, §8.2 |
| **K4** Evidence computed in many places | CK-25, CK-27, CK-28, CK-30, CK-31, CK-32, CK-33, CK-34, CK-35 | **I5–I7.** An evidence slot is a *wanted* created by instantiating a scheme, so the number of slots comes from the callee's requirement list by construction. One elaboration pass writes trees. `Lower` never counts. One `Convention` function decides how a value with evidence is defined and called | §9, §12, §13 |
| **K5** Default answers | CK-16, CK-17, CK-20, CK-21 | **I8.** "Unknown" is never "yes". A rigid without the method is reported at the wanted's origin. A shortcut (the `number` bridge) unifies the declared method type before it answers. The contract has no `err` term, and a missing answer is `internal` | §9.3, §13 |
| **K6** Own-method ordering | CK-36 | **I9.** A use of a module's own method that has no scheme yet demands that method's group, which is checked nested **at that moment** (§10.2). A dispatch or value back-edge merges groups. There are no priority groups, and `method_needs_annotation` survives only for §11.2's non-ordering case | §10 |
| **K7** Capability computed several ways | CK-19, CK-22, CK-23, CK-24, CK-26 | **I10.** "Can `T` answer `m`?" *is* instance resolution. Derived instance contexts come from one memoised fixpoint that the module worker owns. They are published in the interface and read back on a cache hit, never recomputed | §11 |
| **K8** Stale generation context | CK-09 | **I11.** Constraint generation resolves a `.local` reference to its `Var` when it builds the node. The solver never reads `env.local_var` | §6.2 |
| **K9** Intra-module pipeline | CK-11–CK-15 | **I12.** Named sequential phases. Failure is a per-declaration bit set by the reporter on *errors*. `quiet` is enforced once, in the one emit path. There is one scheme-publication routine | §5, §14, §15 |
| **K10** Interface representation gaps | CK-38, CK-39 | interface v3: `u16` arity, record-alias constructor rows, derived contexts | §14.2 |
| **K11** Super-linear bookkeeping | CK-40, CK-41, CK-42 | epoch marks instead of store-sized memsets; an own-name index built once; the fixpoint is lazy and memoised; no per-group settling | §4.1, §18 |
| **K12** Id-order dependence | CK-07 | **I13.** Every choice among several diagnostics is made in name-text order | §7.2 |
| **K13** Diagnostic selection | CK-48–CK-61 | the resolver reports at `origin`; mismatch *categories* for method clauses and `?` legs; the cycle path is rendered | §15.4 |
| **K14** Outside the checker | CK-43–CK-47 | fixed in shared code before the rewrite | `checker-rewrite.md` R1 |

---

## 2. Invariants

Each invariant is enforced **by construction**: no code path can violate it. Where construction
alone is not enough, it is also checked by an **assert**, a debug assertion plus `internal` in a
release build. The fixtures of the CK entries in §1 are the black-box evidence.

| # | Invariant | Enforced by |
|---|---|---|
| **I1** | After a binding with an annotation is generalised, each rigid variable its annotation introduced is still a rigid root with that name, is not merged with another of its rigids, and has rank `generalized` | construction (§8.3); CK-01 |
| **I2** | Every walk over the type graph takes its successors from `Walk.structural` or `Walk.owned` (§4.1), and the choice is part of the walk's declaration | construction: `TypeStore` exposes no raw payload accessor outside `Walk.zig`. Review rule: a new walk that names neither is refused, and so is one whose choice contradicts §4.1's table. *Revised 2026-09-24 (B1): a single successor function that yielded method types made every constrained variable look cyclic to occurs.* |
| **I3** | An open obligation or wanted rides on its variables. It is decided when a variable is bound (readied), or closed when a variable is quantified. One whose variable escaped is still attached to it, so it is decided by whichever boundary quantifies or binds it | construction (§4.5). *Revised 2026-09-24 (round 2, N1): buckets removed.* |
| **I4** | No walk stops at a fixed depth or stack size without reporting. A walk that can meet a cycle detects it by colour and reports `infinite_type` | construction (`Walk.zig` is the only DFS); `check/depth/` pairs for the reported guards |
| **I5** | The evidence of an instruction that instantiates a scheme is exactly one wanted per requirement of that scheme, in the scheme's canonical order (§12.1) | construction (`Instantiate.zig` creates them); assert in `Dispatch.finish` |
| **I6** | Every wanted is answered exactly once, by one of: a given, an instance term, a promotion to a parameter, or a proven-undetermined default. An open wanted at elaboration is `internal` | construction (§12.2); assert |
| **I7** | For every term with arguments, `args.len == evidenceCount(callee)`, where the count is read from the callee's `DeclInfo`, interface entry or derived row | assert in `Dispatch.finish` and again in `Lower` (cheap) |
| **I8** | No failure to decide is answered as success. The walk, resolver and elaborator results are `yes`, `no (reason)` or `blocked (on what)`, and `blocked` is never read as `yes` | construction (the result types have no "unknown → accept" arm) |
| **I9** | Whether a program checks, and what it computes, does not depend on the order of top-level declarations | construction, by three rules. (1) Every nesting is demanded by the frame directly below it, through per-frame `ready` queues drained after every constraint node (§9.1). (2) A re-entrant derived-context query runs a fresh fixpoint (§11.2). (3) Inside a recursive group, D14 lowers the method type of **every wanted** (a method callee, instantiation evidence or a sub-wanted) that is resolved or attached while its receiver is group-level, and every variable of an obligation that has a group-level deciding variable, in `Resolve`'s single resolution function (§10.7). **One stated exception:** the nesting budget (§10.2) can refuse very deep generated code in one order only. Tested by R7's permutation scenario and `test-v2`. *Restated 2026-09-24 (round 3: B-1, B-2, B-3; round 4: R7-1, R7-3).* |
| **I10** | Whether `T` answers `m` has one answer per module, computed by one function, and a cache hit installs the published answer | construction (§11) |
| **I11** | The solver reads no generation-time context | construction: `Solve` has no `Env.local_var` |
| **I12** | A declaration's failure bit is set iff an **error** diagnostic was attributed to it or to a member of its binding group. Every consumer that must skip failed declarations reads the bit | construction (§15.2) |
| **I13** | When several independent failures could be reported and only one is, the one reported is the first in name-text or source order, never in id order | construction (§7.2) |
| **I14** | Nothing written during speculation survives a rollback. Every write a probe can make, including the in-place `Wanted.state` and `answers` writes of `unify`, is either an append truncated by rollback or a journalled in-place write. A probe never calls `Resolve`, `Instances`, `Groups`, the obligation deciders or `Report` | construction (§7.5); a debug assertion that those entry points are not reached while `journal.depth > 0`. *Revised 2026-09-24 (B5).* Consequence: a probe never nests a group check, because only resolution nests and a probe never resolves (round 3, N-1). |
| **I15** | For every wanted `w` whose receiver is **not generalised**, every variable reachable from `w.method_type` by `Walk.owned` has rank ≤ `rank(find(w.receiver))`. All variables of one open obligation have one rank | construction: attaching, and re-attaching on merge, lowers them (§7.1, §4.5), OCaml's `update_level` on binding. A debug assert checks the wanteds and obligations met during each boundary's own generalisation walk, which is linear (S-new-6). A promoted wanted on a generalised receiver is exempt: its method type may mention outer variables free, the HM(X) reading of §8.4 (S-new-4). *Added 2026-09-24 (B2); restricted and extended in round 2 (N1, S-new-4, S-new-6).* |
| **I16** | A boundary generalises only after nothing it runs can unify any more, and it occurs-checks after the last unification | construction: §8.1's fixpoint loop precedes occurs and generalisation. *Added 2026-09-24 (B3).* |

---

## 3. Prior art

The design is conventional, and deliberately so. Each mechanism has a published or shipped
ancestor.

- **Constraint generation, then solving, with levels.** Elm's `Type/Constrain.hs` and
  `Type/Solve.hs`, already beni's model (`fast-compiler.md` §7). Rémy's levels (Rémy 1992) and
  Kiselyov's account of the OCaml checker ("How OCaml type checker works — or what polymorphism
  and garbage collection have in common", 2013). Generalisation scans the young pool and never the
  environment.
- **Constraint variables live at their carrier's level.** HM(X), Odersky, Sulzmann and Wehr, "Type
  inference with constrained types", TAPOS 1999. A constrained scheme `∀ā. C ⇒ τ` quantifies only
  variables that neither `C`'s outer part nor the environment fixes. OCaml's `update_level`, which
  lowers a type's levels when it is bound to a variable of a lower level, is the mechanism I15
  copies.

  **The constraint edges of `Walk.owned` are new relative to both Elm and Roc, and unexercised**
  (§23). Elm has no constraint sets. Roc stores constraints on `Flex` variables
  (`references/roc/src/types/types.zig:303-349`) but deliberately does **not** treat them as graph
  edges:
  - its occurs check skips flex constraints ("Flex variables are not checked for cycles - they are
    allowed to have self-referential constraints", `src/check/occurs.zig:262-265`);
  - its generalisation does not descend into them ("Constraints are deliberately not descended
    into", `src/types/generalize.zig:422`, `:428`).

  Roc keeps outer-receiver requirements in a side table instead (`design.md:5461-5540`). v2 splits
  the two successor functions, so occurs follows Roc and level adjustment follows HM(X).
  *Citation corrected 2026-09-24 (B1): the first draft called this "the same idea in code".*
- **Rigid escape.** Elm checks the `let`'s rigids with `isGeneric` after solving `CLet`. OCaml
  reports "the type constructor … would escape its scope" by a level test. I1 is the level test
  applied after generalisation.
- **Occurs check at every binder.** Elm's `Constrain` gives lambda arguments and case patterns
  their own `CLet` headers, so `Solve` occurs-checks them. §8.2 does the same without the extra
  headers.
- **Dictionary passing with evidence variables, elaborated after solving.** Wadler and Blott, "How
  to make ad-hoc polymorphism less ad hoc", POPL 1989. OutsideIn(X), Vytiniotis, Peyton Jones,
  Schrijvers and Sulzmann, JFP 2011: *wanteds* carry evidence variables, *givens* come from
  annotations, and the solver binds evidence that desugaring reads. §9 and §12 are OutsideIn
  restricted to single-parameter classes with head-matching instances, no overlap and no
  superclasses.
- **One enumeration defines the evidence parameters, and callers derive theirs from it.** Roc's
  `dispatch_evidence.zig:1-27` and `design.md:9044-9075`, with its `validateDispatchEvidence`
  totality check (`checked_artifact.zig:31800-31830`). See I5–I7.
- **Derived instance contexts by fixpoint.** The Haskell 2010 Report §11 (derived instances), and
  GHC's `deriving`, which infers the context of a derived instance by iterating to a least fixpoint
  (`simplifyDeriv`). §11.2.
- **Deferral of a dispatch into an unchecked, untyped local method.** Roc
  `Check.zig:31704-31762` and `:13978-14045` (`resolveGroupPendingDispatchTargets`), and
  `design.md:2197-2231` ("group suspension and merge need no dedicated machinery"). Roc accepts
  exactly the program row 75 refuses (`scheme_use_evidence_test.zig:96-122`). §10.
- **Rejection as a class flag, not poison.** Roc `store.zig:756-771` and `design.md:8860-8880`
  (CK-37).
- **Migration behind a flag, with the old implementation as the oracle.** rustc's next-generation
  trait solver shipped behind `-Znext-solver` and ran the test suite and crater under both before
  switching (§22).

**What is not copied from Roc**, per `review-roc.md` §6:
- the promoted-requirements side table for outer-rank receivers (`design.md:5461-5760`, the most
  bug-dense part of Roc). I2 makes it unnecessary: a requirement on an outer receiver lives at the
  outer rank;
- `.lss` monomorphisation;
- `EvidenceChainIndex.depth`, because closures capture lexically;
- numeric-literal dispatch.

---

## 4. Data structures

### 4.1 The store

`check2/TypeStore.zig` is the current store, adapted. The union-find with path compression, the
Rémy rank kept separate from the tree rank, roots-only accessors, and the nested undo journal whose
snapshot truncates `vars` and `extra` are all kept.

```zig
pub const Descriptor = struct {       // MultiArrayList column set, unchanged except `mark`
    parent: Var,
    rank: u32,                        // `generalized` = 0
    content: Content,
    mark: u32,                        // an EPOCH stamp; see below
    copy: Var.Optional,               // the instantiation memo
};
pub const Flags = struct {            // flex and rigid payload
    name: Symbol.Optional = .none,
    kind: Kind = .any,                // any | number | appendable, closed (fast-compiler §3.1)
    equatable: bool = false,          // the core-only structural marker (§11.4)
    wants: WantList.Optional = .none, // NEW: a range into `want_links`: the wanteds riding here
    obls: OblList.Optional = .none,   // NEW: a range into `obl_links`: the open obligations riding here (§4.5)
};
```

- **`wants` replaces `constraints`.** The entries are `WantedId`s (§4.2), not copies of
  constraints. A variable's method requirements are therefore one table, not one table per variable
  plus site lists. `want_links` is append-only. A merge appends the union and leaves both inputs, so
  a rollback is a truncation (I14).
- **Two successor functions, and every walk names one** (I2). For a root `v`:

  | Content | `Walk.structural(v)` | `Walk.owned(v)` |
  |---|---|---|
  | `structure` | every argument, parameter, result, field type and the extension | the same |
  | `alias` | the arguments and `actual` | the same |
  | `flex` | nothing | **the `method_type` of every wanted in `wants`** |
  | `rigid` | nothing | the `method_type` of every wanted, and of every given |
  | `err` | nothing | nothing |

  Which walk uses which:

  | Walk | Successors | Why |
  |---|---|---|
  | occurs (§8.2), the marker walk (§11.4), `recordRow`, resolver and instance walks (§9.5), `unify` | `structural` | a method type nearly always mentions its own receiver (`x.eq : x, x -> Bool`), so following it would make every constrained variable a false cycle, and would find a function inside every `==`'s receiver. This matches Roc (§3) |
  | `adjustRank`, `copyHelp`, `hasError`, `Schemes.Writer`, `lowerTo` (I15, §7.1), the merge's rank lowering (§10.4), the I15 assert | `owned` | what a variable's requirements mention must be copied with it, generalised with it, published with it, and never outrank it |

  A self-reference through `owned` is expected and harmless. `owned` walks are rank or memo walks
  that stop at a visited node (epoch mark). They are not colour walks and never report a cycle.

  `owned` alone does not close CK-02. Elm's `adjustRank` descends only from young-pool entries, and
  CK-02's receiver `x` is not young. So I15 **lowers** a method type's variables when the wanted is
  attached (§7.1). With both, CK-02 and CK-29 are closed by construction.
  *Revised 2026-09-24 (B1, B2).*
- **Epoch marks, not memsets.** `mark` holds the epoch of the walk that last visited the node. A walk
  takes `epoch = store.nextEpoch()` and tests `mark == epoch`, so there is no clearing pass and no
  store-sized allocation per walk. A three-colour walk (occurs, cycle-safe resolution) takes two
  consecutive epochs, one for grey and one for black. This also fixes `Schemes.Writer.resetMemo`
  (CK-41) and `schemaPropertiesWithDeps`' `seen` (CK-40).
- **Growable DFS stacks only** (I4). `Walk.zig` owns one reusable `std.ArrayList` stack per walk
  kind on the module's scratch arena. There are no fixed arrays.
- **Records are normalised on merge** (CK-08). When `unifyRecord` merges two records, the surviving
  root's content is the *flattened* record: the union of the fields, sorted by symbol for the
  merge-join, plus the final extension. So a closed record stays one node with `ext =
  empty_record`. `Walk.recordRow(v)` follows an extension chain to its end and is the only
  closedness test. A chain can still exist transiently inside a `unify` call.

  Symbol order is internal to the merge-join. **Everything that shows or chooses among fields orders
  them by name text:** `Render`, `Schemes.Writer`, the failure choice of §7.2 and the derived
  `Shape.record` key. This is already true of `Render` and the writer today, and it keeps CK-07's
  class out of messages (N5).

### 4.2 Wanteds, givens and evidence

These tables are per module, append-only and index-based (`check2/Evidence.zig`). None is keyed by
anything but its own index.

```zig
pub const WantedId = enum(u32) { _ };   // also the evidence variable: one wanted, one EvId
pub const Wanted = struct {
    method: Symbol,
    receiver: Var,                      // the carrier; may become concrete
    method_type: Var,                   // the method's type AT THIS USE
    origin: Bir.Inst.Index.Optional,    // the instruction in THIS module that raised it (primary region);
                                        // .none for P5 eager rows and fixpoint wanteds (§11.2), which
                                        // have no instruction and never report at a site
    origin_decl: Origin,                // decl(DeclIndex) | derived(TypeId, Kind): the owner of the
                                        // failure bit (§15.2) and the "origin module" D1 reads (always
                                        // this module: wanteds are per module)
    region: Bir.Inst.Index,             // where the requirement was written (a where clause, an operator)
    owner: Binder,                      // whose evidence parameters an answer may name (§4.3)
    frame: FrameId,                     // the frame current at creation: whose `ready` queue it joins (§9.1)
    seq: u32,                           // module-wide creation sequence, shared with obligations (§9.1)
    state: enum(u8) { open, ready, answered, promoted, defaulted, failed },
};
pub const Given = struct {              // from an annotation's `where`, or a derived body's context
    rigid: Var, method: Symbol, method_type: Var, binder: Binder, k: u16,
};
pub const Answer = union(enum(u8)) {    // what a wanted is bound to; the evidence TERM, pre-elaboration
    param: struct { binder: Binder, k: u16 },
    alias: WantedId,                    // a Rule-U1 join: this wanted IS that one
    top: struct { decl: Bir.DeclIndex, args: WantRange },
    ext: struct { module: Graph.Index, value: Interface.ValueIndex, args: WantRange },
    derived: struct { index: u32, args: WantRange },
    ext_derived: struct { module: Graph.Index, type: Types.TypeId, kind: Derived.Kind, args: WantRange },
    primitive: Dispatch.Primitive,
    undetermined,                       // §9.4 proven-undetermined default (§13.1)
    field,                              // the callee of a dot-call on a record's function field
    group_call: struct { callee: Bir.DeclIndex },  // args filled from the callee's final list (§12.3)
};
answers: []Answer.Optional              // indexed by WantedId
inst_evidence: []WantRange              // per instruction that instantiated a constrained scheme
inst_callee: []WantedId.Optional        // per `method_call`/`type_dispatch`: the wanted naming the function
```

- **An instantiation creates the evidence.** Instantiating a scheme with requirements `R₀ … Rₙ₋₁`
  (canonical order, §12.1) creates `n` fresh wanteds whose `method_type`s are copied through the
  same memo as the body. The instantiating instruction records them as `inst_evidence[inst]`. The
  count is the scheme's by construction (I5). No cursor, parent pointer or site list exists.
- **A `method_call` node creates one wanted**, the callee, recorded as `inst_callee[inst]`.
  Resolving it may create sub-wanteds, the target's own evidence, as its `args`.
- **A join is an alias.** When two variables that both carry a wanted named `m` merge (Rule U1), the
  two `method_type`s are unified and the younger wanted is answered `alias(older)`. There is no
  `resolved_methods`, no `superseded` redirect, no `adopt` and no `committed_copy`: an alias is the
  whole mechanism (disp R2).
- **In-place writes are journalled** (I14, B5). `Wanted.state` and `answers[id]` can be written for
  a wanted created before a speculation's snapshot:
  - the alias of a join;
  - `open → ready` when a flex is bound;
  - `→ failed` against `err`.

  Each such write goes through `TypeStore.journal` as a `WantUndo { id, old_state, old_answer }`
  entry, so `rollback` restores it exactly as it restores a descriptor. Resolution, promotion and
  elaboration write the same fields, but they never run inside a probe (I14), so they need no
  journal.

### 4.3 Binders

```zig
pub const Binder = union(enum(u8)) {
    decl: Bir.DeclIndex,         // a top-level declaration's evidence parameters
    let_def: Bir.Inst.Index,     // a generalised constrained `let` binding (D5)
    derived: u32,                // a derived function's context parameters (§11.2)
};
```

A `param` answer names a binder and an index into that binder's requirement list. The elaborator
checks that the binder encloses the site. A `param` that names a non-enclosing binder is `internal`.

### 4.4 Groups

`check2/Groups.zig` owns the SCC decomposition, exactly as today's `bindingGroups`: top-level values
over `refs`, `let` bindings over local references. Per top-level group it holds:

```zig
status: enum { unchecked, checking, done },
frame: ?u32,           // index into the frame stack while `checking`
merged_into: ?GroupId, // union-find parent after a back-edge (§10.4); none = its own root
```

The **effective status** of a group is the status of `root(g)`, following `merged_into` to the
root, as in union-find. A group merged into a root that is now `done` reads as `done`, and a
back-edge to a merged group merges from its root (S-new-3).

*Simplified 2026-09-24 (review round 2, N3).* The `parked` lists, the `value_deps` prefix lists and
the `merged` status are deleted. Nesting happens at demand (§10.2), so nothing waits in a group.

### 4.5 Obligations ride on their variables

`tuple_index`, `interpolatable`, `equatable` (explicit `Basics.eq`/`neq`) and `try` (§8.6) are
`Obligation { kind, vars, region, state, frame, seq }` rows (`frame` and `seq` as for wanteds, §9.1) in one append-only table, exactly like wanteds.
An **open** obligation is attached to each of its flex variables through `Flags.obls`, a range into
the append-only `obl_links`, which merges like `wants`.

- **`Walk.owned` yields an obligation's other variables**, as it yields a wanted's method type:
  the `tuple_index` result, and the `try` subject, target result and instruction result.
- **All variables of one obligation share one rank** (I15, extended). Creating an obligation runs
  `lowerTo(vars, min rank of vars)`. So does every merge that moves it, because the surviving
  root's rank can only be lower.
  - What is lowered is the closure of the **result** variables (the `tuple_index` result, the `try`
    instruction result). The **deciding** variables, the tuple and the `try` subject and target, are
    flex roots for as long as the obligation is open, so their closure is just themselves and their
    own requirements. Nothing else, such as a subject's success type, is over-lowered. R5's reviewer
    tests a `let`-local `?` whose target escapes and whose subject is otherwise young (round 3, N-3).
  - In N1's program, `a = p.0` has its result `r` lowered to `p`'s outer rank, so `a` is not
    generalised to `∀r. r`, and `( a + snd p, String.length a )` is the `type_mismatch` it should
    be.
- **Readied through their variable**, as wanteds are. When a flex carrying it is bound to a
  structure or a rigid, the obligation goes on **its creation frame's** `ready` queue (§9.1; row field `frame`, round 4 R4-1). It is decided in the
  settle loop of the frame that drains it (§8.1).
- **Decided at quantification.** When generalisation quantifies a variable that still carries open
  obligations, the boundary's close step reports or folds them, per §8.5. That is where v1 already
  handles the `equatable` flag.
- **Carried by escape.** An obligation whose variable escaped is simply still attached to it. There
  are no buckets and nothing to re-bucket (I3).

The cost is linear: each obligation is attached once, readied at most once and closed at most once
(S-new-2). *Revised 2026-09-24 (review round 2, N1 and S-new-2): per-rank buckets, and extras
"treated as children" without any lowering, let an outer variable's obligation extras be
generalised.*

---

## 5. The per-module pipeline

`check2/Module.zig` runs these phases in this order, once per module, with no re-settling. Each
phase reads and writes only what its row says.

| Phase | Name | Reads | Writes |
|---|---|---|---|
| P1 | `setup` | Bir, interfaces of imports | store, the tables of §4, schema state (`Schema.State.buildAll`) |
| P2 | `annotations` | every annotated value and its `where` | each annotated declaration's **published scheme**, read at rank `generalized` (§6.6); `DeclInfo.requirements` for bodiless `foreign … where`. No rigid of P2 is ever unified |
| P3 | `index` | the declaration table | own-name index `Symbol → DeclIndex` (all values; `pub` bit), own nominal types; replaces the linear `ownDeclNamed` scans (CK-42) |
| P4 | `groups` | everything above | per group in SCC order, **skipping groups whose effective status is already `done`** because a nesting checked them (round 3, S-7), through `checkGroup` (§10.2): constrain, solve, resolve (nesting other groups at demand), occurs, generalise, check generality, promote |
| P5 | `derived` | the fixpoint of §11 (already memoised during P4) | the eager derived rows for every own nominal type (A.23) |
| P6 | `elaborate` | answers, `inst_evidence`, `inst_callee`, group-call records | the dispatch table's trees (§12.2, §13) |
| P7 | `exhaustive` | failure bits (§15.2), Bir | `missing_patterns`, `redundant_pattern`, refutable-pattern diagnostics |
| P8 | `publish` | schemes, derived contexts | the interface record through the one routine (§14.1) |
| P9 | `finish` | the dispatch table | `Dispatch.finish` (sort, assert I5–I7), `--roundtrip-dispatch`, `Cycles.run`, then the schema plan, gated on the module having **no error after cycles** (CK-15) |

- The profile events `constrain`, `solve`, `resolve`, `derived`, `elaborate`, `exhaustive` and
  `publish` nest inside `check`, one per phase. Nothing super-linear can then hide *between* events
  (orch F3).
- `--roundtrip-interfaces` stays where it is, after P8.
- The inter-module machinery is kept (§19): the DAG scheduler, the core gate, the cutoff-key
  protocol and cache install. It moves out of `Check.zig` into `Driver.zig` and `Incremental.zig`,
  and calls `Module.check(m)` or `Module.install(m, entry)`.

---

## 6. Constraint generation

`check2/constrain/` holds `Expr.zig`, `Pattern.zig` and `Decl.zig`, about 700 lines each. The
per-form rules are `checker.md` §6.1's table, kept verbatim. The changes are these.

### 6.1 One tree per group, generated in one pass

Unchanged in shape: Elm's `Constrain` over a binding group, producing `equal`, `let`, `and`,
pattern constraints, obligations, and the `method` node of `static-dispatch-spike.md` §6.2 Rule U0.
The tree is solved left to right.

### 6.2 `.local` resolved at generation (I11, CK-09)

The generator resolves a `.local` reference to its `Var` while it builds the node. It reads the
member's own `local_type` slice, which it holds at that point, and emits `instantiate(var)` for a
generalised local or `equal(var)` for a monomorphic one. The solver's `schemeOf` has no `.local`
arm. `Env.local_var` is not visible to `Solve`.

### 6.3 Binders are registered

Every variable a binder introduces is appended to the current boundary's `binders` list: a lambda
parameter, a case-pattern variable, a `let` header and a `<-`-bound pattern. So is the top-level
header. §8.2 occurs-checks the list.

The generator also emits a **`binders_end` node** after a lambda's body constraints and after each
case branch's constraints. The node runs the occurs check over that lambda's parameters or that
branch's pattern variables at that point in the tree, before any enclosing constraint is solved.
This is Elm's placement, where each lambda and branch is a `CLet` header.

So `(\y -> y y) "s"` reports `infinite_type` at `y` before `"s"` is unified against the unrolled
arrow. `y` is then poisoned, and the application adds no second diagnostic. *Added 2026-09-24
(S4).*

### 6.4 Operator sections (CK-32)

`(==)` lowers to `lambda [%a, %b] -> method_call %a .eq [%b]` (BIR is unchanged). The "S3 shim"
(`Constrain.zig:910-914`) is deleted. A call of an operator section is an ordinary call of the
lambda, and the `method_call` inside it gets its callee wanted like any other. The evidence then
lives on the instruction `Lower` reads it from.

### 6.5 Records are constrained before they meet the expectation (CK-59)

A record literal's fields are constrained first. The literal's type is then unified with the
expected type, so a mismatch renders the literal's field types (`{ n : number, name : String }`)
and not fresh variables.

### 6.6 Annotations: one scheme, one checked instance

*Revised 2026-09-24. Round 1 (S16): the rank of P2's rigids had been unspecified. Round 2 (N8):
recursive uses must see the scheme, not the rigid instance.*

- **Every annotation has a scheme before anything uses it.**
  - A top-level annotation's scheme is built in P2 at rank `generalized`.
  - A `let` annotation's scheme is built the same way when the `let` group's frame is pushed, before
    any of its bodies is constrained.
  - No rigid of a scheme is ever unified.
- **Every reference to an annotated binding instantiates its scheme**, by value or by dispatch. That
  includes a reference from its own body, from its own binding group, and from a nested or merged
  frame. A reference to an annotated binding is therefore:
  - never an in-flight link (§10.3);
  - never a back-edge (§10.4);
  - never a demand for nesting (§10.2).

  So polymorphic recursion through an annotation works. v1 accepts
  `depth : List a -> Int` with a recursive `depth [ 1 ]`, and the same shape in a `let`, and so does
  v2 (round 2, N8).
- **Only the body check uses a rigid instantiation** of the scheme. It is made in the checking frame
  at that frame's rank, with its rigids pooled there and its `where` clause turned into givens. At
  the frame's boundary the rigids are quantified with the frame, and I1 checks them (§8.3).

This is not CK-01's "two readings". The defect there was that the checked copy was never validated.
Here the checked copy is an instance of the published scheme, and I1 validates it. A failure is an
error (`rigid_mismatch`), so a false annotation never compiles, even though dependents checked
earlier had already instantiated its scheme.

---

## 7. Unification

`check2/Unify.zig`, about 900 lines. It is today's `unifyFlat`, `unifyRecord`, `unifyAlias` and
kind lattice with the dispatch arms removed.

### 7.1 `unify` merges and queues. It never resolves and never reports

`unify(a, b) → Result` where `Result = ok | mismatch(Problem)`. The **caller** reports the problem
with its category (Elm's split). Inside `unify`:

- **flex ⊓ flex** merges kinds, `equatable` and `wants`. For a method name present on both sides it
  unifies the two `method_type`s, and on failure returns `mismatch(.method_constraint, younger
  origin)`. It then answers the younger wanted `alias(older)` (§4.2).
- **flex ⊓ structure, alias or rigid** binds the flex, and moves each of its wanteds and open
  obligations to the `ready` queue (a journalled write, §4.2). Nothing is resolved.
- **Every bind appends the bound variable to `touched`** (§8.1, N6). A merge also moves `obls`
  and runs §4.5's shared-rank lowering.
- **Attaching a wanted keeps I15.** Three things attach a wanted to a receiver: a `method` node on a
  flex, an instantiation creating one, and a merge moving `wants` onto the surviving root. Each then
  runs `lowerTo(w.method_type, rank(find(w.receiver)))`. This is an `owned` walk that lowers every
  variable it reaches to at most that rank, like `adjustRank` but downward only, stopping at nodes
  already at or below it.
  - In CK-02, `x.combine y` attaches to the outer `x`, so `y`'s type drops to `f`'s rank and `g` is
    not generalised over it.
  - A young receiver merged later with an outer variable is covered by the pool table: the young
    receiver's pool entry now reads the outer root's rank and `adjustRank` descends its `owned`
    successors.

  The cost is one walk of the method type per attachment. A method type is a function of two or
  three nodes. *Added 2026-09-24 (B2).*
- **flex ⊓ err** marks each wanted `failed` silently: poisoned, and never reported.
- **rigid ⊓ non-identical** is `mismatch(.rigid)`, as today.
- **rigid capture.** When a rigid is merged with a flex whose rank is lower than the rigid's, `unify`
  appends `Capture { rigid, region }` to the boundary's capture list. §8.3 reads it for the region of
  an escape.
- **records** use the four-way merge-join of today, producing a normalised record (§4.1).

### 7.2 Choice among failures is by text (I13, CK-07)

`unifyRecord` unifies every shared field and collects the failures. The one returned is the
smallest by field **name text**, not by symbol id. For the one-failure case, which is the common
one, the cost is zero.

### 7.3 Depth

`unify` recurses on structure. Its guard stays `Parse.max_depth + 104` (`checker.md` §5). The guard
is reachable two ways:

- through a cyclic graph, which §8.2 and §9.5 keep short-lived;
- through a **legitimately deep acyclic** type. A chain of `let`s can build an inferred type deeper
  than `Parse.max_depth`, as CK-13's 600-deep tuple does.

Past the guard, `unify` returns `mismatch(.too_deep)`, which the caller reports as
`nesting_too_deep`, the same code and cure as the other depth guards. It never returns "ok" (CK-10
item 3). *Wording corrected 2026-09-24 (N3).*

### 7.4 Kinds

The kind lattice is unchanged: `any ⊒ number`, `any ⊒ appendable`, `number ⊓ appendable = ⊥`.
Numeric literals through primitive aliases keep queue row 67's rule.

### 7.5 Speculation (I14, CK-35)

`TypeStore.Snapshot` is `{ journal_len, vars, extra, want_links, obl_links, wanteds, obligations,
answers, binders, captures, seq, frames: []FrameLengths }`.
- Every field except `journal_len` and `frames` is the length of a module-wide append-only table.
- `frames` holds, for **every open frame**, the lengths of that frame's own `ready` queue and
  `touched` list: `FrameLengths = { frame, ready_len, touched_len }`.
- `rollback` truncates all of them, then replays the journal backwards. That restores descriptors
  and the in-place wanted and obligation writes of §4.2 (I14).

*Revised 2026-09-24, round 4 (R4-1). The round-3 Snapshot still listed one `ready` queue and no
`touched`.* A probe's `unify` can bind a variable of **any** open frame. So it can append to any
open frame's `touched` list, and ready an item onto any open frame's queue. Every one of those lists
must therefore be restored.

**Why per-frame lists with all open frames' lengths**, rather than one tagged table per kind with a
cursor per frame:
- **Per-frame lists keep each frame's entries contiguous.** §8.1's occurs pass, S-3's linear bound
  and the hand-down on merge all walk one frame's list and nothing else. A tagged shared table would
  interleave nested frames' entries, and every walk would have to skip them. That is the O(n²) S-3
  removed.
- **The price is O(open frames) per snapshot.** That is paid only by the diagnostic probe, which
  runs only after a failure, and the open-frame count is bounded by the nesting budget (§10.2).

**Only one operation speculates:** the diagnostic "which of two did you mean" unifications, run
after a failure to choose a message.

`?` is **not** speculative in v2. §8.6 decides it from a concrete head, or by default, and then
unifies and reports. *Revised 2026-09-24 (S21): the first draft listed "`?` shape trials" here and
said the opposite in §8.6.*

A probe unifies and nothing else. It never calls `Resolve`, `Instances`, `Groups`, an obligation
decider or `Report` (I14), and it cannot create a dispatch-table row, because rows do not exist
until P6. That is what deletes `TargetProbe`, `forgetResolvedSince` and the other hand-journalled
tables.

---

## 8. Levels, generalisation and obligations

`check2/Generalize.zig`, about 450 lines. Elm's `generalize` and `adjustRank` with pools per rank
are ported as they are today, except that `adjustRankContent` descends by `Walk.owned` (I2).

### 8.1 Boundaries

A frame is pushed for every boundary: a `let` group, or a top-level group. §10 adds nested top-level
groups. At the boundary of frame `F`, with young rank `r` (I16):

1. **Settle.** Drain the frame's `ready` queue until it is empty (§9.1). A `let` frame drains its enclosing top-level frame's queue. Resolution may check a group nested
   at demand (§10.2), and may decide obligations whose variable became concrete (§8.5, §8.6).
   **No defaults are applied here.**
2. **Adjust ranks without quantifying.** Run Elm's `poolToRankTable` + `adjustRank` over `F`'s
   young pool, by `Walk.owned` successors. After this pass, a variable's rank says whether it
   escapes `F`. Every later step reads adjusted ranks only.
3. **Defaults.** Skip this step if `F` is a top-level frame merged into another (§10.4, N4).
   - Collect, in obligation-id order, the undecided `try` obligations attached to variables of `F`'s
     pool whose variables **all still have rank `r`**.
   - Apply every one of them, which defaults it to `Result` (§8.6).
   - If any was applied, or anything was readied since step 1, go back to step 1.

   Applying all at once is equivalent to applying them one at a time: a default only makes
   `Result`s, so it can only turn another undecided `?` into a `Result` decision.
4. **Occurs** over `F`'s `binders`, and over `F`'s `touched` list (§8.2, N6; per frame since round 3), by
   `Walk.structural`.
5. **Quantify** the rank-`r` variables of the pool (§8.4).
6. **Generality check** for the annotated bindings of `F` (§8.3).
7. **Close.** For each variable just quantified:
   - its open wanteds are promoted, or proven undetermined and defaulted (§9.4);
   - its open obligations are reported or folded (§8.5).

   Wanteds and obligations on escaped variables stay attached to them (I3).
8. Pop `F`.

**A merged top-level frame** (§10.4) runs steps 1 and 2 at its own end. It then hands its pool,
`binders` and `touched` segment to the merge root's frame, and pops. It runs no default, no occurs
check and no quantification: those happen once, at the root.

**`touched`** (N6) records the variables `unify` binds. The undo journal cannot serve here, because
it records nothing outside speculation. It is **one list per frame** (round 3, S-3): `unify` appends
to the current frame's list, and a merged frame hands its list down with its pool.

A nested frame's entries are therefore never in its demander's list. Those variables were already
generalised or handed down, so a chain of *n* nested groups costs O(n) occurs work, not O(n²).
Each list is an append-only table, truncated on rollback (§7.5).

**Termination.** Every return from step 3 to step 1 follows one of two things:
- a default applied, of which there are finitely many;
- a wanted or obligation readied, each of which happens at most once.

Step 7 can unify: a structural default resolves against a shape. It runs only on variables step 5
quantified, which no open constraint can reach any more, so it can neither ready an outer wanted nor
form a cycle through a structure that step 4 cleared. A debug-only occurs re-run over what step 7
touched asserts this.

*Revised 2026-09-24.*
- *Round 1, B3:* occurs had run before the unifying steps.
- *Round 2, N2:* defaults had read stale ranks.
- *Round 2, N4:* a merged frame had defaulted before the root's facts arrived.
- *Round 2, N6:* the "journal segment" does not exist.

### 8.2 Occurs at every binder (CK-04, CK-03)

The occurs check runs in two places:
- at each `binders_end` node, over that lambda's or branch's binders (§6.3);
- at step 4 of every boundary, over the boundary's `binders` and the frame's `touched` segment (§8.1).

Each is one walk. The walk is three-colour over **`Walk.structural`** successors (I2, B1), with the
two epochs of §4.1 and a growable stack. A variable whose only self-reference is through its own
requirement (`x.eq : x, x -> Bool`) is not a cycle.

A cycle is `infinite_type` at the binder, or at the first unified variable on the cycle for one
made in the settle loop. The walk returns the cycle's path, and `Render` prints the structure with
the repeated variable (CK-57): `a = { a | x : a }`, not `a = … a …`. The variable is then poisoned
(`err`). Elm pays the same cost for the same guarantee. §18 has the measurement obligation,
including the nested-`let` case.

**Why both defences.** Resolution during solving, through U0 inline resolution on a concrete
receiver or in the settle loop, can still meet a graph made cyclic since the last check. So §9.5
also makes every resolver walk cycle-safe. Neither defence alone is enough, and both are cheap.

### 8.3 Annotation generality (I1, CK-01)

For each binding of the boundary that has an annotation, and for each rigid of its checked instance
(§6.6), after step 5 all three of these must hold:

- the rigid's root is still `rigid` with its own name;
- no other rigid of the same annotation shares that root. Rigid-rigid merges are already
  `rigid_mismatch` inside `unify`, and this is the assert;
- its rank is `generalized`.

A rigid that fails the third is an **escape**: the annotation says "any type" and the body tied the
variable to an enclosing one. It is reported as `rigid_mismatch` (D7) at the first `Capture` region
recorded for that rigid (§7.1), or at the annotation when none was recorded, because the rank was
lowered by `adjustRank`. The message names the outer binding and says the annotation is too
general. The binding's scheme is then poisoned, so callers are not checked against a false
annotation.

**Top-level declarations.** The check runs there too, because their rigid instance lives in the
frame's pool (§6.6). A top-level rigid has no enclosing binder to escape into except a suspended
frame's live variables through a dispatch back-edge, and §10.4 merges those frames first. So a
failure there is `internal`, never a user error. *Revised 2026-09-24 (S16).*

### 8.4 Generalisation, and constrained `let` bindings (D5)

Rule (a) of `static-dispatch-spike.md` §6.4 is **retired** (D5). Generalisation is plain HM(X) on
levels.

- **Step 5 quantifies exactly the variables whose rank after step 2 is `r`**, whether or not they
  carry wanteds. `adjustRank` computes a structure's rank as the maximum of its children, as in
  Elm.
- **A wanted on an outer-rank receiver** keeps its method type's variables at the outer rank (I15),
  so none of them is quantified. That is the answer to CK-02's `g y = x.combine y`: `y`'s type sits
  in the method type of a wanted on the outer `x`, so `g` is monomorphic in `y`.
- **A wanted on a young receiver** whose method type mentions an outer variable is still
  quantified, with the outer variable **free** in the promoted requirement. That is sound HM(X):
  `g y = y.combine x` gives `g : ∀b. b -> r where b.combine : b, X -> r`, with `X` being `x`'s outer
  type, shared by every instantiation. I15 does not apply once the receiver is generalised
  (S-new-4).
- **The `let` binding's open wanteds on its own quantified variables are promoted** to the binding
  (`Binder.let_def`, §9.4). Uses instantiate them as they would a top-level scheme's (I5).

*Restated 2026-09-24 (round 2, S-new-4). "Provided everything reachable through `owned` is young"
was not what `adjustRank` computes.*

Slices R4–R13 ship with a **`let_constrained_monomorphic` switch** that keeps rule (a)'s behaviour,
so the pre-cut-over corpus compares like with like. R14 deletes the switch (`checker-rewrite.md`).

### 8.5 Obligations at a boundary (I3, CK-05)

Obligations ride on their variables (§4.5). By kind:

| Kind | A variable became concrete: decided when drained (§8.1 step 1) | Still open on a variable step 5 quantified: step 7 | On an escaped variable |
|---|---|---|---|
| `tuple_index` | check the arity (unifies the result) | `ambiguous_tuple` | stays attached |
| `interpolatable` | check membership | `ambiguous_interpolation` | stays attached |
| `equatable` | the §11.4 walk | fold the flag into the variable | stays attached |
| `try` | §8.6 | never reached: §8.1 step 3 defaults first | stays attached |

At the **module's last boundary**, the top-level group, nothing escapes.

### 8.6 `?` as a deferred obligation (D2, CK-06, CK-51)

`try(e, target_result, region)` is an obligation on both of its variables. `target_result` is the
result variable of the `?`'s **target**: the declaration or the `let_def` named by the instruction
(`checker.md` §6.5). Its two variables share one rank (§4.5). It is decided at the first of these:

- **(a)** When drained, because either variable got a `Result` or `Maybe` head. This can happen in
  any frame's settle step.
- **(b)** Otherwise, **by default to `Result`**, in step 3 of the boundary of the frame at whose
  rank its variables still sit after that frame's rank adjustment. That is the frame that owns them,
  normally the target's own generalisation boundary.
  - An obligation whose variables escaped, as in round 2's N2 program, is defaulted, or decided by a
    later fact, further out.

  In N2's program, `f h = let g u = h (u?) in ( g (Just 1), Maybe.withDefault (h 5) 0 )`, the
  target result escapes `g` to `f` through `h`. It is decided as `Maybe` when `f`'s body meets
  `Maybe.withDefault`, and the program checks.

*Clarified 2026-09-24 (round 1, S3): the target may be a `let_def`, and deciding its `?` after that
`let` generalised would unify generalised variables. Revised (round 2, N2): ownership is read on
adjusted ranks.*

Deciding is today's three unifications (`checker.md` §6.5): `e ~ Shape x a`,
`target_result ~ Shape x b`, and the instruction ~ `a`. They are **not speculative** (§7.5): the
shape is chosen first, from a concrete head or by default, and then the three are unified and a
failure is reported.

A failure reports **which** leg failed, through the categories `.try_leg(subject | enclosing |
error)`, and the message names it:
- "the enclosing definition returns `Result String Int`, and this is a `Maybe Int`";
- "the error types differ: `Int` here, `String` in the enclosing result".

When both sides are concrete and disagree in head, the subject's head chooses the shape, and the
enclosing leg then fails with the message above.

---

## 9. The resolver

`check2/Resolve.zig` (about 1 100 lines) and `check2/Instances.zig` (about 700). The resolver owns
every wanted from the moment it is `ready` until it is answered.

### 9.1 When resolution runs

- **Inline, Rule U0.** Solving a `method` node whose receiver is already concrete calls
  `Resolve.now(wanted)` before the argument constraints are solved. This is the same function the
  drain uses, and it keeps the message quality of `static-dispatch-spike.md` §6.2.
- **At every boundary**, in step 1's settle loop (§8.1), the resolver drains the frame's queue until
  it is empty.
- **Drain order** (round 4, S4-4). Wanteds and obligations share **one creation sequence number**,
  `seq`, stamped on both tables from one module counter at creation. A queue is drained in ascending
  `seq`, which is creation order and a function of the source (I9).
- **One `ready` queue per top-level frame, and one per fixpoint frame** (round 3, B-1).
  - **Routing is by the frame id recorded when the item is created** (round 4, R4-1), not by
    `origin_decl`.
    - Every wanted and obligation row carries `frame: FrameId`: the frame that was current when it
      was created.
    - A sub-wanted, and an evidence wanted created by an instantiation, takes the frame current at
      its creation.
    - A `let` frame routes to its enclosing top-level-kind frame.
    - A readied item goes on **its own frame's** queue, whichever frame's unification readied it.
  - `origin_decl` could not serve for routing, for two reasons. Two fresh fixpoints (§11.2) share
    `origin_decl = derived(T, m)`, and obligation rows have no `origin_decl`.
  - **Merges.** A merged frame that is still running keeps draining its **own** queue until it hands
    down (§10.4). At hand-down, whatever is left in its queue is appended to the root frame's queue,
    in `seq` order, and its items' `frame` fields are re-pointed to the root.
  - A frame drains **only its own** queue, so a nested group's settle step can never resolve (and so
    nest from) a wanted of the frame below it.
  - The frame stack therefore stays a true **demand chain**: every nested frame was demanded by the
    frame directly beneath it.
- **Eager draining** (round 3, B-1). The solver drains the current frame's queue **after every
  constraint node**, outside `unify`, so I14 is untouched.
  - A wanted is resolved as soon as its receiver is bound, at the same solving step at which a group
    checked first would have given its answer. That is v1's "resolve when the receiver is bound".
  - Round 3's `rq1` and `rq2`, a `case` scrutinee whose method is written after its use, and before
    it, both check.
  - The boundary settle step (§8.1 step 1) is then only the last drain.
- *S-new-5's round-2 text ("one queue per module; answers never depend on which frame drains") was
  wrong once draining can nest groups.*

### 9.2 One step, by the receiver's root

`Resolve.step(w)` looks at `find(w.receiver)`:

| Root | Action |
|---|---|
| `flex` of kind `number`, method `eq` or `compare` | **the `number` bridge** (D9): unify `w.method_type` with `t, t -> Bool\|Order` (category `.where_clause` when the wanted came from a clause), then answer `primitive strict_eq\|num_compare`. This runs when the wanted is first drained, with no waiting, as v1 does. Every `number` is `Int` or `Float`, and both answer the same primitive |
| any other `flex` | leave `open` (re-queued when bound, §7.1). At the boundary that quantifies it, §9.4 |
| `rigid` | 1. a given `(rigid, w.method)`: unify the method types (category `.where_clause`, CK-55), answer `param(binder, k)`; 2. else, a rigid of kind `number` with `eq`/`compare`: the `number` bridge, as for a flex; 3. else `missing_where_constraint` at **`w.origin`** (CK-48), and the wanted is `failed` |
| `err` | `failed`, silently |
| `app T args` / `alias` / record / tuple / unit / `func` | `Instances.lookup(w)` (§9.3) |

*Revised 2026-09-24 (B4, S5).* The first draft put the bridge inside `lookup`, which §9.2 reaches
only for concrete roots, and had no bridge for rigids. `core/Basics.beni:319`'s
`abs : number -> number` with `n < 0`, `max`/`min`, and `tests/corpus/run/DecodeInto.beni:86`'s
`number.eq x y` would have been `missing_where_constraint`, so `core` could not check under v2. v1
has the rigid bridge at `Solve.zig:2750-2753`. D9 is amended accordingly (§21).

### 9.3 Instance lookup: matching a head, with the context as sub-wanteds

`Instances.lookup(w)` returns `answer(term, sub-wanteds)`, `blocked(on)` or `fail(reason)`. It never
returns "unknown, accept" (I8).

1. **Well-known table** (`static-dispatch-spike.md` §3.2), for `eq` and `compare` on a core
   primitive: `primitive p`. First, `w.method_type` is unified with the well-known signature
   `t, t -> Bool|Order` (CK-21).
2. *(Moved on 2026-09-24, B4/S5.)* The `number` bridge is now a row of §9.2's receiver table, for
   flex and rigid roots. It creates no evidence parameter, the same ABI as today, and it checks the
   declared type first (CK-21). There is no `appendable` bridge. The step numbers are kept, so
   references to steps 3–6 stay valid.
3. **The module rule.** `T`'s declaring module:
   - **This module.** The P3 index gives declaration `d`:
     - annotated, or its group is `done`: take the scheme;
     - its group is `checking` or `unchecked`: §10.
   - **Another module.** `Interface.findValue`:
     - `pub`: take the scheme;
     - private: `fail(private_method)` (§11.3).
4. **Matching.** Instantiate the method scheme. Unify its **first parameter** with the receiver, and
   the whole scheme with `w.method_type`, with category `.method_signature` naming the method.
   - The instantiation's own requirements are the **sub-wanteds**, created by I5 in canonical
     order.
   - The answer is `top(d, args)` or `ext(m, v, args)`.
   - Because the requirements come from the instantiated scheme, their receivers are whatever
     unification made them. That is the fix for CK-27 and CK-28: `Holder (List a)`'s `a.eq` gets
     the element's `eq`, not the list's.
5. **Derived.** Not found, the method is well-known, and the call is marked (§1.3 of the spike):
   - **nominal `T args`**: `Instances.derivedContext(T, m)` (§11.2):
     - `present(ctx)`: answer `derived(index)` in this module or `ext_derived`, with one sub-wanted
       per context entry `(i, m')` on `args[i]`;
     - `absent(reason)`: fail with the reason's code: `not_equatable`, `no_methods_on_shape` or
       `private_method`;
     - `blocked(group)`: §10.
   - **closed record, tuple, unit**: `derived(shape)` with one sub-wanted per field or element
     (`static-dispatch-spike.md` §9.2 and §9.3, unchanged). A record's closedness is
     `Walk.recordRow` (CK-08).
   - **open record**: `fail(no_methods_on_shape, .open_record)` (CK-54).
   - **`func`**: `fail(not_equatable)` for `eq`, `fail(no_methods_on_shape)` otherwise.
6. **Not found**: `unknown_method` with the edit-distance suggestions.

Sub-wanteds are resolved in the same drain. A rigid inside a derived shape (CK-20) is a sub-wanted
on a rigid, so it reaches the `rigid` row of §9.2, which gives a missing-constraint error at the
comparison, not a structural answer.

### 9.4 Promotion and the undetermined default

At the boundary that quantifies a flex receiver:

| Situation | Answer |
|---|---|
| the binder is annotated | a wanted not covered by a given was already `missing_where_constraint` (Rule U2) |
| unannotated top-level declaration, or a `let` binding (D5) | **promote**. The requirement lists of a binding group are computed per member from each member's own scheme (§12.3). A wanted raised in member `m`'s body is answered `param(m, k)`, where `k` is `(q, method)`'s index in **`m`'s** list. If `q` is not in `m`'s list, §12.3's cases 2 and 3 apply. Several wanteds of one name on one variable are already aliases (§4.2). *Revised 2026-09-24 (round 2, N7): "promote to the binder" was ambiguous for a group.* |
| over `max_inferred_constraints` (64) | `too_many_inferred_constraints`, with each receiver named (CK-58). The binder promotes nothing, as today (spike §10.11) |
| `pub`, unannotated, with ≥ 1 requirement | `ambiguous_method_receiver` warning, unchanged |
| `pub`, zero parameters, inferred requirements | `constrained_constant`, unchanged. Its scope is decided by §12.5 |
| the receiver is **not reachable** from the binder's scheme type, and is not quantified by any enclosing binder (proven undetermined) | the §7.2 default. On a shape, `eq`/`compare` resolve by that shape's structural `derived` function, as `settleUndetermined` does today. On a bare variable they get the `undetermined` leaf (§13.1). For any other method, `missing_where_constraint`-class ambiguity at `origin`. This is the only structural answer the resolver gives, and only on proof |

### 9.5 Termination and cycles (CK-03, CK-37)

- **Cycle-safe walks, and one report per cycle.** Every resolver walk over a receiver (instance
  lookup, derived-context queries, `recordRow`) goes through `Walk.zig` with colours, over
  `structural` successors (I2).
  - **Which defence fires first is fixed** (pinned 2026-09-24 for CK-37). A cycle is closed by a
    unification in some constraint node. Eager draining (§9.1) runs right after that node, before
    any later node, `binders_end` or boundary. So when a wanted on the cyclic receiver exists, the
    **resolver walk** meets the cycle first.
  - That first detection reports **one** `infinite_type`, at `w.origin`, and **poisons the cycle's
    root** (`err`), as Elm does for an infinite type. Every later wanted on it, and the
    `binders_end` and boundary occurs checks that later reach it, see `err` and stay silent. One
    infinite type gives one message.
  - When no wanted is on the cyclic variable, the `binders_end` or boundary occurs check is the
    first to see it, and does the same.
  - **A non-cycle rejection** (`unknown_method`, `private_method`, `no_methods_on_shape`,
    `not_equatable`, `missing_where_constraint`) does **not** poison the receiver. The wanted is
    `failed`, and a `dispatch_rejected` flag is set on its receiver's class, OR-merged on union as
    Roc does (`store.zig:756-771`). It silences only later wanteds *of the same method* on that
    class, so unrelated uses of the receiver still report (CK-37).
  - *Both behaviours are what `7427828` already does* (round 4 probes `cyc1`, `indep`), so CK-37's
    fixtures are regression guards.
- **A lineage rule replaces `cycle_check_depth`.**
  - Each sub-wanted records its parent.
  - Resolving a wanted whose `(method, target)` equals an ancestor's **and whose receiver root is
    the ancestor's receiver root, or reaches it by `structural` successors**, is `infinite_type` at
    the root wanted's `origin`.
  - Receivers are compared by **root identity** and reachability. "Strictly larger" is not defined
    on the cyclic graphs this rule exists for.
  - An equal-root repeat is **not** answered by the ancestor. A cyclic evidence term cannot be
    represented (`Term` is a tree), and P6 would not terminate.

  On an acyclic receiver an equal repeat cannot arise from well-typed input:
  - sub-wanted receivers are images of a scheme's quantifiers, strictly inside the parent receiver;
  - nominal recursion goes through the §11.2 fixpoint, not through resolution.

  So the rule only ever fires on the cyclic case. The drain backstop `1 << 20` stays as a reported
  backstop (`nesting_too_deep` plus poison), as `static-dispatch-spike.md` §6.3 requires. It counts
  **resolution steps per module, cumulatively** across every eager drain, frame and fixpoint (round
  4, S4-3).
  *Revised 2026-09-24 (S14): the first draft let an equal repeat be "answered by the ancestor".*

---

## 10. Own methods without a scheme: deferral, nesting and merging (D3, CK-36)

This replaces priority groups (`Check.zig:1254-1308`), the capability re-settles between them, and
`method_needs_annotation`.

### 10.1 The situation

Resolution, a derived-context query, or a **value** reference reaches a declaration `d` of this
module. `d` is **unannotated** (§6.6: an annotated `d` is always instantiated from its scheme), and
the effective status of its group `G_d` (§4.4) is not `done`.

*Rewritten 2026-09-24, review round 2 (N3). The round-1 design parked such a use until the frame's
boundary, and that was still order-dependent: the parked result stayed a flex for the rest of the
body, where the other declaration order would have made it concrete at once. Nesting **at demand**
removes that difference, and it deletes parking, park lists, settle-time nesting, pinning and the
value-prefix closure.*

### 10.2 Nesting at demand

There are two cases, by `G_d`'s effective status.

- **`unchecked`: check it now.**
  - `checkGroup(G_d)` runs immediately, in a fresh top-level-kind frame at rank `top + 1`, in the
    middle of whatever is being solved.
  - Its own references do the same, recursively: a value reference to another unchecked group nests
    that group on first reference. That is the whole of the old "prefix" rule, because SCC order
    guarantees nothing about a group reached out of order.
  - When `checkGroup(G_d)` returns **`done`**, `d` has its scheme. Resolution instantiates it and
    continues, at the same solving step at which it would have continued had `G_d` been checked
    first.
  - When it returns **merged** into a frame below (its check found a back-edge), `d` has no scheme
    yet. The demanding site takes the in-flight path instead: §10.3, or for a fixpoint payload
    §11.2's in-flight branch. *(Round 3, S-1.)*
  - **Nesting depth is bounded, and reported** (round 3 S-4; revised in round 4, R7-3).
    - **One budget.** The recursion guards of `Constrain` and `Solve` (`checker.md` §5) become one
      budget for the whole stack of frames, rather than one per walk. The budget is **2 × (one
      declaration's worth, `Parse.max_depth + 104`)**. `check_stack_size` (64 MiB) is already twice
      the 32 MiB that M2b measured for one declaration (`Check.zig:412-421`), so the existing
      argument covers it.
    - **Admission.** Every nested `checkGroup`, and every fixpoint frame (§11.2), charges `nest_cost`
      units. A frame is **admitted only if the remaining budget is at least one full declaration's
      worth plus `nest_cost`**.
      - So a nested group that has started can never run out inside its own expression walks.
      - The refusal is always at the demanding use: `nesting_too_deep` with the hint "annotate
        `<method>`". An annotated method is never a demand for nesting (§6.6). The use is then
        poisoned, and the method's own group is never poisoned by it.
    - **`nest_cost` is a counted constant.** It is calibrated once, in a **Debug** build, where
      frames are largest, recorded in the source, and never measured at run time. So Debug and
      ReleaseFast refuse the same programs, and the result is deterministic for a given source (rule
      5): it is per module and single-threaded.
    - **What reaches it.** Not "only thousands of methods": two declarations can.
      - For example, a method whose body is about 2 500 levels deep, used about 2 500 levels deep
        inside another declaration, is refused when the use is checked first and accepted in the
        other order. That is generated code in practice.
      - The limit is **order-dependent at that extreme**, and this is stated, not hidden (I9's one
        exception).
      - Rule 7 holds. It bounds a real blow-up, a native stack overflow on valid input, and an
        annotation or a reordering lifts it, as with the 64-constraint cap.
    - *Rejected alternative:* an explicit continuation stack. It would have to turn `constrain`,
      `solve` and `resolve`, three mutually recursive tree walks, into a state machine. That is the
      largest complexity cost in the design, paid for input no person writes.
    - **Tested** by generated scenarios (`checker-rewrite.md` R7):
      - a reverse-ordered method chain, under the budget and over it;
      - a pair of deep declarations.

      Over the budget there must be exactly one `nesting_too_deep`, at the demand and with the hint,
      and never a crash.
- **`checking`: a back-edge.** Take the in-flight link (§10.3) and merge (§10.4).

```
checkGroup(G):
    G.status = checking; push frame (rank = top + 1)
    constrain G; solve G      -- any demand on an unchecked group nests right here;
                              -- any demand on a checking group is a back-edge
    boundary (§8.1)           -- or, if G's frame was merged, steps 1–2 and hand-down
    G.status = done; pop
```

**Why nesting at any point is sound, and why it restores I9.**
- A nested group is a top-level group. Its frame is above every open frame, and it shares no
  variable with any of them. The only exception is a back-edge, which §10.4 turns into a merge.
- So it is solved, defaulted and generalised exactly as it would be at top level, and its scheme is
  a function of its members and of the schemes of the groups it depends on.
- The demanding site then sees that scheme at the same solving step as in the order where the group
  came first. So every later constraint of the site's body (a U0 resolution, a `let` generalisation)
  meets the same types in both orders.

Round 2's N3 program is the witness. With the `makeBox` use written before `makeBox`, the scrutinee
is resolved inline to `Box Int`, `g : ∀b. (Int -> b) -> Box b` generalises, and the program checks,
as it does with the declarations reversed.

**Where v2 departs from Roc.** Roc nests only at group boundaries, pinning the waiting relation to
the group's rank (`references/roc/design.md:2201-2208`). So an inner `let` that uses a
not-yet-checked method can be generalised in one order but not in the other. Nesting at demand
removes that dependence.

**Pinning is retired.** Ordinary rank adjustment makes it unnecessary.

### 10.3 The in-flight link

When `d` is unannotated and its group is `checking` (effective status), whether it is the group
currently being solved or one lower on the stack, the use is monomorphic. That is the ML rule for
recursion:

- a dispatch use unifies `w.method_type` with `d`'s header variable, with no instantiation, and the
  wanted is answered `group_call(d)`;
- a value reference is `d`'s header variable, and is recorded as `group_call(d)` for evidence.

§12.3 fills the arguments from the per-member requirement lists after the group's promotion. **A
reference to an annotated `d` never takes this path** (§6.6, round 2 N8).

### 10.4 A back-edge merges top-level groups (D11)

A back-edge from the current nested chain reaches `d`, unannotated, in a group whose root frame is
`j`, lower on the stack. Because each frame drains only its own `ready` queue (§9.1), the stack is
a **demand chain**: frame `j` demanded the next top-level frame, and so on up to the top, and the
top now demands `j`. *(Round 3, B-1: with one shared queue this premise was false, and an unrelated
group could be merged.)* So the groups of the **top-level-kind** frames from `j` up form a cycle
through value or dispatch edges, which makes them mutually recursive.

- **Only top-level-kind frames merge** (round 2, N5). Their groups get `merged_into = root(j)`, as a
  union-find union.
- **`let` frames never merge.** Each generalises at its own boundary. Ranks already keep it from
  quantifying anything that reached a merged frame, because such variables took the lower rank.
  Round 2's N5 program is the witness: `g` inside `weight` generalises `y` whichever of `size` and
  `weight` comes first.
- **A merged top-level frame runs only steps 1 and 2 of §8.1 at its end.** It hands its pool,
  `binders` and `touched` segment to `root(j)`'s frame, lowering their ranks to that frame's, and
  pops. It applies **no `?` default** (round 2, N4). Defaults, occurs, quantification, the
  generality check and promotion happen once, at the root's boundary, when every member's facts
  are in.
  - Round 2's N4 program checks in both orders: `bm`'s `m?` waits for `am`'s `Box (Just n)`.
  - Debug assert: no group is nested after a frame has applied its first default, whether the
    frame is a top-level root or a `let` frame (round 3, N-2). A default only makes a `Result`, whose
    methods are `core`'s and already `done`.
- **All members of a merged group share one failure bit** (§15.2) and are generalised **together**.
  Their calls to each other are group calls (§12.3).
- **A back-edge to a group already merged into a root merges from that root** (S-new-3).

This is how `eq a b = compare a b == EQ` together with a `compare` that uses `==` on its own type
checks, whatever order they are written in.

### 10.5 Properties

- **Terminates.** A group enters `checking` once. Nesting follows demands, and a demand on a
  `checking` group is a back-edge, not a nesting, so the nesting depth is at most the number of
  groups.
- **Order-independent (I9)**, by the three rules I9 names. *(Restated 2026-09-24, round 3.)*
  - **Outside a recursive group.** A group's scheme is determined by its members and by the schemes
    of the groups it depends on, by value or by dispatch. Every such group is `done` when the scheme
    is needed: checked earlier at top level, or nested at the demand.
    - A nested check is exactly a top-level check in a fresh frame (§10.2).
    - Per-frame queues keep the stack a demand chain.
    - Eager draining gives every use its answer at the solving step at which the other order would
      have given it (§9.1).
  - **Re-entrant derived queries** run a fresh fixpoint, so they see the same inputs in every order
    (§11.2).
  - **Inside a recursive group** (a value SCC of two or more members, or a merged group), members
    are solved in source or demand order, so one member can see another's partial facts early in
    one order and late in the other. D14 (§10.7) makes every such observation pessimistic, which
    makes it order-independent. Where a merge begins is a function of each member's own body
    prefix (§10.7).
  - Merging depends only on which top-level groups form a cycle through value or dispatch edges to
    unannotated declarations. That is a function of the program.
  - The remaining choices are made in id order.
  - R7's permutation scenario tests this over every counterexample of review rounds 1–3
    (`checker-rewrite.md`).
  - **One stated exception:** the nesting budget of §10.2. A generated pair of very deep
    declarations, or a long reverse-ordered chain, can reach it in one order and not the other
    (round 4, R7-3).
- **Deterministic (rule 5).** Everything above is per module, single-threaded, and ordered by
  source-derived indices.
- **What still needs an annotation:** nothing, for ordering reasons (D3). Two things need one for
  non-ordering reasons, as in Elm:
  - **Polymorphic recursion through an unannotated recursive group**, where a member is used at two
    types inside its own group, by value or through dispatch. It is monomorphic by §10.3, so it is a
    `type_mismatch`, with §10.6's hint. An annotation lifts it (§6.6).
  - **A derived instance whose parameter-indexed context depends on an in-flight inferred method**
    (§11.2): `method_needs_annotation` (D3 as amended, §21.1).
  - **A method call on a group-level receiver inside a recursive group, whose result a `let`
    helper would need to be polymorphic in** (D14, §10.7). An annotation on the member that
    produces the receiver lifts it, and the hint names that member.

  In every other case `method_needs_annotation` is no longer emitted. Its code stays in
  `diagnostic.Code` and in `language.md` §10's catalogue.

### 10.6 Worked examples

Every program below is a planned fixture (`checker-rewrite.md` R7). All are written in valid beni: a
method needs at least one argument besides its receiver, because `x.m` alone is a field access
(`static-dispatch-spike.md` §11). Round 2's programs are corrected accordingly, as `.size ()`.

**Nesting inside a `let`** (round 1, B6):

```elm
type Box a = Box a
f u = let g x = (Box x).size () in ( g 1, g "s" )
pub size (Box _) u = 1          -- unannotated, written after f
```

`(Box x).size ()` demands `size`'s group while `g`'s body is being solved. `size` is checked nested
(`Box a, b -> Int`), the wanted resolves, and `g` generalises. The program checks, as it does with
`size` written first. The same holds for `g : a -> Int; g y = (Box y).size ()`, which must not report
a spurious escape. v1 refuses the unannotated order with `method_needs_annotation` (CK-63).

**Order-dependent refusal made strict: D11 is stricter than Roc** (round 1, S17). Take a module with:
- `type K = K Int` and `type Box a = Box a`;
- an unannotated `pub show (K n) u` that compares `Box 1 == Box 2` and `Box "x" == Box "y"`;
- an unannotated `pub eq (Box a) (Box b)` whose body mentions `\w -> (K 0).show ()`.

`show` and `eq` form a cycle through dispatch, so v2 merges them (§10.4). Inside the merged group
`eq` is monomorphic, so its uses at `Box Int` and `Box String` are a `type_mismatch` in **every**
declaration order.

Roc lets a nested group generalise whatever does not reach the suspended frame
(`design.md:2221-2225`), so it accepts this program in one order and rejects it in the other.

v2 keeps D11. It is deterministic (I9), and the program needs one annotation (`eq`'s), which the
message says:
- `type_mismatch` at the second use;
- plus the hint "`eq` is used at two types inside a group that is recursive through method calls
  (`eq` → `show` → `eq`); an annotation on `eq` lets each use instantiate it".
- The printed cycle starts at the member whose name is smallest by text, so the message is
  byte-identical in every declaration order (round 2 nit).

Rule 7 is kept: the refusal stands only where the alternative is order-dependent, and it names its
escape hatch. v1 refuses it with `method_needs_annotation`, so the fixture is pending (CK-70).

### 10.7 Recursive groups: canonical pessimism (D14)

*Added 2026-09-24, round 3 (B-3). This is decision D14, taken under the owner's standing
instruction to take the reviewers' recommendations, and flagged to the owner.*

**The problem.** Inside a recursive group, members are solved in an order: source order for a value
SCC, demand order for a merge. A `let` helper that makes a method call on a **group-level**
receiver, meaning a variable whose rank is the group's top-level rank, such as another member's
result, sees different facts in different orders. Round 3's `sccA`/`sccB` shows it:

```elm
pub combine (Box a) z = Box a
f n = let r = g n
          q z = r.combine z
      in ( q 1, q "s" )
g n = if n > 100 then Box n else let _ = f (n + 1) in Box n
```

- **`g` written first:** `r : Box number` is already known, the call resolves inline, `q`
  generalises, and the program is accepted.
- **`f` written first:** `r` is `g`'s unsolved result. The call attaches to a flex, I15 lowers `z`,
  and `( q 1, q "s" )` is a `type_mismatch`.
- **v1:** `check` accepts both orders. `build` then stops with two *different* internal errors, one
  per order (CK-72).

**The rule, over wanteds** (restated 2026-09-24, round 4, R7-1). The round-3 rule looked only at a
method-call node's receiver. Two kinds of wanted slipped past it:
- **instantiation evidence**: `useMix r z` with `useMix : a, b -> a where a.mix : …` (`evA`/`evB`);
- **sub-wanteds of an inline resolution on a young receiver**: `(Box r).combine z` with
  `combine … where a.mix …` (`subA`/`subB`).

Either could be resolved inline in one order and attached-and-lowered in the other. The rule is
therefore stated over **every wanted and every obligation**, at the one place all of them pass
through: **`Resolve`'s single resolution function**, used both inline and by the drain, together
with the attach path of §7.1.

> In a recursive group — a value SCC of two or more members, or a group that has merged (§10.4) —
> whenever **any wanted** is **resolved or attached** while its receiver's root has rank ≤ `R`, run
> `lowerTo(its method type, R)`. That covers a method node's callee, instantiation evidence and a
> sub-wanted alike. For an **obligation**, a deciding variable (the tuple, the interpolated
> variable, the `?` subject or target) at rank ≤ `R` lowers **all** the obligation's variables.
>
> `R` is the rank of the top-level-kind frame of the member whose body contains the wanted's
> creating node. That is the member's own frame rank, even inside a merged group before hand-down,
> where members sit at different ranks with `let` ranks in between (S4-1).

- **Why this is order-independent.** In the order where the receiver is still a flex, the same
  wanted is attached to the same group-level root, and I15 lowers the same closure. In the other
  order, this rule lowers it at resolution. Eager draining (§9.1) resolves right after the creating
  node in both orders, on the same side of the member's merge point, so the "inside a recursive
  group yet?" answer is the same.
- **The result.** In every order the answer is the pessimistic one: `q` is monomorphic, and
  `sccA`/`sccB`, `evA`/`evB` and `subA`/`subB` all report the `type_mismatch`.
- **Single-member groups are untouched.** Round 3's `capt`, which v1 accepts, stays accepted: its
  receiver's facts come only from its own body, so their order is fixed.
- **Where it is built.** An R7 hook in R6a's `Resolve` resolution function. It is local and
  additive.

**Why the rule is order-independent.**
- **Value SCCs** are known before solving, from the SCC decomposition.
- **Merges.** Take each member of a cycle. The node at which it demands the next member of the cycle
  is fixed by its own body, and the merge becomes known while every member is paused at that node,
  in every order. Before that node, a member's body sees no other member's facts, in any order; after
  it, it is inside the merged group, in every order.
  - So "is this node inside a recursive group" is a function of the member's own body prefix.
  - This is argued, not proven. §23 carries it, and R7's permutation scenario tests
    it on 3-cycles.

**The message.** The `type_mismatch` D14 causes carries a hint:
- "`r` comes from `g`, which is in a recursive group with `f`, so its type is not known here yet.
  Annotate `g` and each use can instantiate it".
- **The named member is chosen syntactically** (round 4, R7-2), so the diagnostic is byte-identical
  in every declaration order.
  - The constraint generator records, for each variable a `let` binding or a parameter introduces,
    the group member whose **reference** produced its value in the current member's body:
    `r = g n` records `g`.
  - The hint names that member when the lowered wanted's receiver came from exactly one such
    reference.
  - Otherwise it names **every unannotated member of the group, sorted by text**. The group is the
    value SCC, or the members merged so far, which is prefix-determined per the argument below.
  - The round-3 rule, "the member whose header variable the receiver's root came from", depended on
    union-find class membership, which depends on order. Annotating the member it named could even
    leave the receiver group-level.
- Solving records which variables D14 lowered, so the reporter knows when to add the hint.

**Rule 7.** The refusal buys a guarantee, I9's order-independence. Without it, a program's
acceptance would depend on declaration order, which is exactly what CK-36 and its family exist to
remove. The escape hatch is always available: annotating the member instantiates its scheme (§6.6),
so the receiver is no longer group-level. The annotated `sccA`/`sccB` is accepted in both orders, as
it is by v1. It is the same kind of limit as monomorphic recursion in Elm.

**Alternatives considered**, from the review:
- **HM(X) for outer receivers.** Principal, but it is Roc's side table, which §3 rejects, and it
  reverses CK-02's expectation.
- **Restating I9 with an exception.** It gives up the guarantee.

---

## 11. Capabilities, derived contexts and privacy

`check2/Instances.zig`.

### 11.1 One question, one answer (I10, CK-26)

"Can `T args` answer `m`?" is `Instances.lookup` succeeding. There is no separate capability table:

- `Types.Entry.answers_eq`, `answers_compare`, `public_eq`, `public_compare`, and the
  `eq/compare_param_requirements` bitmasks are deleted;
- so are `Types.settleDispatchCapabilities`, `Solve.settleOrdinaryCapabilities`,
  `restoreDerivedCapabilities` and `summarizeCapabilityTarget`.

The session `Types` table becomes `*const` everywhere, with no `@constCast`. Each module's derived
contexts live in the module worker's own state, and are **published** in the interface (§14.2).

### 11.2 Derived contexts by fixpoint (D4, CK-25, CK-23)

For an own nominal type `T` with parameters `p₀ … pₙ₋₁` and a well-known method `m` that `T` does
not define, the **context** `ctx(T, m)` is a set of `(i, m')` pairs: "to answer `m` on `T args`,
`args[i]` must answer `m'`".

- **Computation.** Each constructor payload type is resolved as a wanted `(payload, m)` in a context
  where each `pᵢ` is a rigid carrying one given per method name. A given `(pᵢ, m')` that gets used
  adds `(i, m')` to the context. Resolution of the payloads uses §9.3 in full. A payload's custom
  method, `Holder.eq where a.key`, contributes its instantiated requirements: `(0, key)`.
- **The unit is (type-level SCC) × {`eq`, `compare`}** (round 4, R8-2). One fixpoint computes
  `ctx(X, m)` **jointly** for every own nominal type `X` in one strongly connected component of the
  "payload mentions" graph, and for both methods.
  - Each entry lives in the lattice `present(∅) ⊂ present(larger sets) ⊂ absent(reason)`. Every
    entry starts at `present(∅)`, and entries only move up.
  - A worklist re-resolves `X`'s payloads for `m` when an entry they read has changed.
  - The lattice is finite and every step is monotone, so the fixpoint terminates. This is GHC's
    `deriving` inference, taken over both methods at once.
  - **Why joint.** Derived contexts depend *across* methods: `H.eq where a.compare` makes `eq` on a
    wrapper of `H.Holder T` need `T`'s `compare`. A per-`(T, m)` fixpoint would memoise
    `ctx(T, compare) = present` permanently after reading a partial `(T, eq)` approximation. It
    would then answer `a < a` with a derived `compare` whose payload needs an `eq` that turns out
    absent (round 4's `xm`/`xm2`).
- **Reading the approximation, or running fresh** (round 4, R8-1). Let `F` be the fixpoint frame of
  unit `U`. A query for `(X, m)` with `X` in `U`:
  - **reads `F`'s current approximation** when no top-level-kind group frame lies above `F` on the
    stack. That is always true of `F`'s own payload resolution, and of any query made directly by
    it. Such a read is not a new query;
  - **runs a fresh fixpoint** for `U` (a new frame, worklist and approximation) only when a
    top-level-kind group frame **was pushed above `F`**, because `F`'s resolution nested a group
    whose body asks again.

  *The round-3 text said "fresh on re-entry". Read literally, that made `F`'s own payload queries
  re-enter `U` fresh forever: `xm` recursed without bound.*
- **Well-foundedness.** Take any stack of frames.
  - **Between two fixpoint frames of the same unit** there is always a group frame, by the rule
    above. Every group frame was pushed for a group that was `unchecked` at that moment, because a
    demand on a `checking` group is a back-edge (§10.3) and pushes nothing. And no group is ever
    pushed twice. So the number of fixpoint frames per unit on the stack is at most (number of
    groups + 1).
  - **Between fixpoint frames of different units with no group frame in between**, each query
    follows a type mention from one unit to another. The units form a DAG (they are the SCCs of the
    mentions graph), so such a chain is at most the number of units long.
  - **So the stack depth is bounded** by (units × (groups + 1)) plus groups. In practice the budget
    of §10.2, which fixpoint frames also charge (`nest_cost`), bounds it far sooner and reports.
  - This replaces round 3's argument, which was false for the literal reading.
- **Absent.** If any payload wanted **fails**, the instance is `absent(reason)`:
  - a function with no method boundary: `not_equatable` / `no_methods_on_shape`;
  - a private method of another module: `private_method`, per §11.3;
  - a schema endpoint's exclusion: the endpoint's own reason (CK-24).

  The reason is kept for the use-site message.
- **Blocked.** A payload can need an own unannotated method, or a schema endpoint whose conversion
  group is not `done`. **A context computed while any input was in flight is memoised only under its generation, with a
  replay list** (see "Memo generations and replay" below). The cases:
  - **The group is `unchecked`:** it is checked nested at demand (§10.2), from inside the query.
    The fixpoint frame is simply lower on the stack. Then the query continues.
  - **The group is `checking`** (in flight): the payload wanted resolves to an in-flight method `d`.
    Look at the payload receiver:
    - **It mentions no parameter of `T`.** It is closed, as in `type W = W (H.Holder T)` with
      `H.eq where a.key`, where the in-flight method is `T`'s `key`. Then it contributes **no
      context entry**, whatever `d` infers.
      - **The method-type check is an ordinary wanted in the asking frame** (round 4, R8-3). The
        receiver type is instantiated in the frame of the wanted that asked the query (its creation
        frame, §9.1), not in the fixpoint frame, whose variables are discarded. A `(receiver, key)`
        wanted is created there and **resolved by the ordinary resolver**.
        - `d`'s group is `checking`, so that resolution takes §10.3's in-flight link **and §10.4's
          merge** whenever the asking frame belongs to a different top-level group. The round-3 text
          "unified with `d`'s header" skipped the merge, and broke §10.2's premise that a nested
          group shares variables only through a back-edge.
        - Round 4's `cbA`/`cbB` show it: `pick` compares `W`s, and `key` uses `pick 1` and
          `pick "s"`. `pick` and `key` now merge in both orders, and `pick "s"` is a
          `type_mismatch` in both. Annotating `pick` or `key` lifts it.
      - The derived body's term for that position is `top(d, args)`, with `args` filled from `d`'s
        final list after its group's promotion, as for a group call (§12.3).
      - Nothing else is refused (rule 7).
    - **It mentions a parameter of `T`.** An example is `type W a = W (H.Holder (T a))` with an
      unannotated `key (T x) u` whose body compares `W` values. Then a context entry of `W` is
      indexed by that parameter and depends on `d`'s final requirements, which depend back on the
      instance. There is no sound monomorphic reading of a *derived* instance, which is not a member
      of the group.
      - So it is refused with **`method_needs_annotation`**, naming `d`. An annotation on `d` always
        lifts it.
      - The refusal is order-independent: whichever declaration comes first, the cycle is the same.

  *Added 2026-09-24 (round 1, S1). Narrowed in round 2 (S-new-1). The round-1 example,
  `type U a = U (T a)` beside an unannotated `T.eq`, cannot occur under the module rule: `U`'s `eq`
  would be that same `eq`.*
- **Frame and rank.** The fixpoint runs in its **own frame**, pushed on top of the stack at rank
  `top + 1`.
  - Its rigids, givens, payload instantiations and wanteds are created there.
  - None of them is unified with a variable of any other frame. Payload types are instantiated
    fresh from the declarations, and the asking wanted's receiver is never passed in: only the unit is.
  - When the fixpoint finishes, the frame is popped with its variables **discarded**. Its product is
    the list of `(i, m')` pairs, not a type.
  - A debug assert walks the frame's pool and checks that no variable of it is reachable, by
    `owned`, from any variable older than the frame.

  So the fixpoint cannot run at `generalized` or leak variables into an inner `let`, which is
  CK-10 item 2's trap. *Added 2026-09-24 (S1).*
- **Fresh fixpoints, and the result for CK-74** (round 3 B-2, amended in round 4). Round 3's
  program (`key` compares `W`s, `same` compares `W`s, `other = (T 1).key "s"`) gives the same
  result in both orders:
  - with `same` first, `W`'s fixpoint `F` nests `key`, whose query runs fresh (a group frame is now
    above `F`);
  - with `key` first, `key`'s query is the first;
  - either way, `key`'s query reaches the in-flight `key` through the closed branch. That creates an
    ordinary wanted in `key`'s own frame, which is the in-flight link within one group, so no merge
    is needed;
  - so `key : T, () -> Int`, and `other` is a `type_mismatch` in both orders. CK-69's refusal fires
    in both orders too.
- **Memo generations and replay** (round 3 S-6, amended in round 4 R8-3).
  - A **unit** result computed from `done` inputs only is memoised permanently.
  - One computed while an input was in flight is memoised under the current **generation**, a
    counter bumped whenever any group completes, and a lookup hits only in the same generation.
    Such an entry also **stores the list of in-flight methods its closed branches reached**.
  - A hit **replays**, for its asker, one ordinary method-type wanted per listed method, in the
    asker's frame. So every asker in the generation merges exactly as the first did (R8-3), and
    whether a second asker merges does not depend on who asked first.
  - A result that read a partial approximation of **another** unit is never memoised: that other
    unit was on the stack below, so its reader is inside it, and it is recomputed with it.
- **Explicit ranks** (round 3, S-2). `Instantiate` and every function that creates variables take
  an explicit rank and pool, and none uses "the top frame" implicitly. The closed in-flight branch
  creates its method-type wanted with the **asking** frame's rank, pool and queue, even though the
  fixpoint frame is on top.
- **Worklist** (N12). The fixpoint keeps, per own type in the unit, the set of types whose payloads
  mention it. When `ctx(X, m)` grows, only the `(type, method)` entries that read it are re-resolved. It iterates until the
  worklist is empty.
- **Memoised** per **unit** for the module once computed from `done` inputs only (above). P5 reads
  the memo for the eager rows. Nothing is ever re-settled (CK-40).
- **ABI (D4).** The derived function takes **one evidence parameter per context entry**, in
  `(i, m'-text)` order. `static-dispatch-spike.md` §9.4's "one per type parameter, used or not" and
  A.20 are superseded.
  - `type Outer a = Outer (Holder a)` with `Holder.eq where a.key` gives
    `Outer$eq = ($m$0 /* a.key */, x, y) => Holder$eq($m$0, x.a, y.a)`.
  - A phantom parameter contributes nothing, so `Tag (Int -> Int)` is comparable (CK-23).
  - Types whose every parameter is compared with the method being derived, which is nearly all of
    them (`Maybe a`, `Result x a`, `List`), get exactly today's parameter list. So their emitted
    JavaScript does not change (§20.3).
  - **The calling convention past 4 096 entries** is one array `$m`, for every shape (spike §9.2
    *The wide form*, A.87, CK-81): the context is the same, only its JavaScript spelling changes,
    decided by the entry count in `Convention` (R2b).
- **Structural shapes** (record, tuple, unit) keep "one parameter per field or element, same
  method" (spike §9.2 and §9.3). Their context is positional and trivially known. Past 4 096
  positions they take one array, as every shape does (the D4 bullet above).

### 11.3 Private methods (D1, CK-22)

*Amended 2026-09-24 (R0's finding on CK-22). The first text claimed "`M`'s derived `Holder` eq uses
`M`'s private `eq`". Under the module rule no such derived function exists.*

**The module rule is unchanged by privacy** (`static-dispatch-spike.md` §3.3 step 1). A module's
values, `pub` or not, are **one namespace**, so a private `eq` in `M` is `M`'s `eq` for **every**
type `M` declares.
- `M`'s other nominal types get no derived `eq`. Inside `M`, `Holder (T 1) == Holder (T 11)` is the
  module-rule clash: a `type_mismatch`, because `eq : T, T -> Bool`.
- From another module, `M.Holder … == …` reaches `M`'s private `eq`, so it is `private_method`.
- `7427828` already does both, so neither is a finding.

**Inside `M`**, the private `eq` answers every wanted whose `origin` is in `M`. That covers:
- direct `T` comparisons;
- **structural shapes derived in `M`**: `( a, 0 ) == ( b, 0 )` at `T`, a record, a list;
- `M`'s derived rows of structural shapes whose positions reach `T`.

**Outside `M`**, any wanted that reaches `(T, eq)` is `fail(private_method)`: directly, or through a
derived context computed in that other module (a `W M.T`, a tuple, a record, a list). So no
comparison anywhere gives an answer that differs from `M`'s. Where one would differ, it is refused.
That is D1's coherence guarantee, and the part `7427828` gets wrong (CK-22).

`static-dispatch-spike.md` §3.3 and A.63 ("a private `eq` still lets every other module derive")
are superseded.

### 11.4 The `equatable` marker (CK-16, CK-17, CK-19)

The marker stays what `static-dispatch-spike.md` §3.4 says: a structural guarantee for explicit
`Basics.eq` and `Basics.neq`, and **never** an `eq` method. The resolver never consults it, which
deletes `builtinRigidTarget`'s arm (CK-19). The `equatable` obligation's walk:

- uses `Walk.zig` over `structural` successors: growable and cycle-safe (CK-17). A flex that carries
  an `eq` wanted is therefore not "a function" through its own method type (B1);
- descends, at a nominal `T args`, only into the arguments whose parameter **occurs in a
  constructor payload** (D10). That is `payload_params(T)`, a bitset per type:
  - an own type computes it from its constructors;
  - an imported type reads it from interface v3 (§14.2), so an opaque type's hidden payloads need
    not be read;
  - a `foreign type` has every parameter set, which is today's behaviour.

  So a phantom function argument is fine (CK-23, for the marker). Through payloads that mention
  another nominal type, the walk continues with that type's own `payload_params`. *Revised
  2026-09-24 (S15): "descend into payloads" could not be done for an imported opaque type.*
- **propagates the flag** to a flex it meets inside a structure. It **requires** the flag of a rigid
  it meets, and without it reports `not_equatable` at the obligation's region (CK-16);
- answers `no(function at …)` or `yes`. It has no `unknown`.

### 11.5 Schema endpoints (CK-24)

A schema endpoint type is a nominal type whose payloads come from the plan. Its derived context is
computed by the same §11.2 function, and its exclusions are that function's `absent`. A wrapper
around it asks the same memoised question, so it inherits the answer. `Schema.settleProperties`
and its per-group calls are deleted. The schema **plan**, which needs the endpoints' properties,
reads them from the memo in P9.

---

## 12. Evidence and elaboration

`check2/Evidence.zig`, about 500 lines.

### 12.1 Canonical order, one function

`Evidence.requirements(scheme) → []Requirement{ quantified, var_name, method }` computes the list
of a scheme in `static-dispatch-spike.md` §7.2's canonical order: quantifiers in `Schemes.Writer`
discovery order, then method name text. It is **the same function** for:

- promotion (§9.4), which writes `DeclInfo.requirements`;
- local instantiation (I5);
- `Schemes.Writer`, which writes the interface `where` blocks.

An importer reads the list in stored order. Because exporter and importer derive it the same way,
they agree (Roc's property 1).

**Quantifier discovery order is v1's** (N10). The writer discovers quantifiers by a
`Walk.structural` walk of the scheme's body, in v1's order: fields by text, parameters left to
right. Only then does it write each quantifier's constraint types. A variable reached only through a
constraint's method type is not a quantifier. §2.4 of the spike (A.21) requires every variable of a
constraint type to occur in the annotated type, and the same holds for an inferred scheme, whose
constraints ride on its own quantifiers.

The `owned` edges therefore cannot reorder the list. R6's exit criteria include a byte comparison of
every `core` and corpus interface's `where` blocks under both checkers.  *Added 2026-09-24.*

### 12.2 Elaboration (P6)

For every instruction with `inst_callee` or `inst_evidence`, P6 follows each wanted's answer,
through `alias` chains, and writes a `Dispatch.Term` tree (§13):

- `param(binder, k)` → `param`, after checking that `binder` encloses the instruction;
- `top`, `ext`, `derived`, `ext_derived` → the same node with its `args` elaborated recursively;
- `primitive`, `undetermined`, `field` → leaves;
- `group_call(d)` → `top(d, args)`, per §12.3.

**An `open` or `ready` wanted at P6 is `internal`**, and never a structural answer (I6).
A `failed` wanted means an error was reported, so the module has errors, the backend never runs,
and P6 writes nothing for that instruction.

### 12.3 Calls inside a binding group (CK-30, CK-31)

A reference from one member of a group to another, or from a member to itself, or through an
in-flight link (§10.3), does not instantiate a scheme, because the callee is monomorphic in flight.
The solver records it as `group_call(callee)`. After the group's promotion, P6 elaborates it:

**Every member's requirement list** is `Evidence.requirements(member's scheme)`. It is computed
after the group's generalisation from the member's **own** generalised type, reading the `wants` of
the quantified variables that type reaches. It does not depend on which member's body *raised* the
wanted.

In CK-30's `m1b` (`f x y = if x == y then True else g x y`, `g x y = f y x`), `g` raises no wanted
of its own. But its type `a, a -> Bool` reaches the shared `a`, which carries `f`'s `eq`, so both
lists are `[a.eq]`. Several wanteds of one name on one variable are aliases (§4.2), so they give one
entry. *Clarified 2026-09-24 (S2).*

For each requirement `(q, m)` of the callee's **final** list, the argument is found by these cases,
in order:

1. **`q` is quantified by the caller.** Within the group, the callee's `q` is the very variable the
   caller uses, because in-group references share variables. The caller's own list contains
   `(q, m)` at some index `k` of its canonical order, and the argument is `param(caller, k)`.
2. **`q` is quantified by an enclosing binder of the caller** (a generalised constrained `let`
   around the call, D5). The argument is `param(that binder, k)`, where `k` is `(q, m)`'s index in
   that binder's list. §9.4's middle row covers this too.
3. **Otherwise**: `q` is reachable neither from **the site's own member's** scheme nor from an
   enclosing binder. It is then undetermined *for this site*, and the argument is the `undetermined`
   leaf (§13.1).

   This is sound by parametricity. The site's member cannot produce or consume a value of `q`'s
   type except through the callee, and the callee is polymorphic in `q`.

   Round 2's N7 program shows the case: in `f u = if g [] then 1 else 0` with
   `g xs = case xs of [] -> f 0 == 0; a :: _ -> a == a`, `g`'s `a` is quantified by the group
   but is not in `f`'s type. So `f`'s call `g []` passes `undetermined` for `a.eq`, and the list is
   empty.

The case "in the member's type, but not in its list" cannot arise, because of how the lists are
computed above. The elaborator asserts it (`internal`). *Revised 2026-09-24 (round 2, N7): the
first revision sent the N7 program to that assert.*

The number of arguments is the callee's requirement count by construction, and the index is the
**caller's** (CK-31). A requirement answered concretely, such as the `number` bridge or a type found
later, is never promoted. So neither the callee nor the call carries it (CK-30a). A requirement
promoted after the reference was solved is covered too, because nothing is emitted at reference
time (CK-30b).

### 12.4 Derived bodies

The body of an own derived function for `(T, m)` is one term per constructor argument position. It
is resolved in §11.2's context, and `param(derived i, k)` names the context entries.
`static-dispatch-spike.md` §9.4's emitted shapes (tag switch, padding, order tables, recursion by
name) are unchanged. Only the parameter list follows D4.

### 12.5 One calling convention (CK-33, CK-34)

`check/Convention.zig` is shared by `Cycles`, `Edges`, `js/Reach` and `js/Lower`. It lands in **R2b**
on the old checker, together with the tree record, and is kept.

It needs `value_arity` and `evidence` per declaration in the checker→backend record. Today's
`Dispatch` has no such column, so it rides on R2a's `DeclInfo` record, with its own `dispatch_bytes` bump in R2b (round 3 split). *Moved from R1
2026-09-24 (S8): R1 would have needed its own record change and format bump, and it touches the
same four files as R2.*

```zig
pub const Convention = union(enum) {
    plain,                              // no evidence
    function: struct { evidence: u16 }, // params > 0, or a lambda body, or a zero-parameter value of
                                        // FUNCTION type (its arity is the type's): defined as
                                        // ($m…, $p1…$pn) => …, called flat f(ev…, args…)
    thunk: struct { evidence: u16 },    // zero parameters, NON-function type: defined ($m…) => value,
                                        // every read is f(ev…) — it RUNS at each read
};
pub fn of(decl_params: u32, body_is_lambda: bool, value_arity: u32, evidence: u16) Convention
```

- The checker writes `value_arity` (the type's arity, 0 for a non-function) and `evidence` into
  `DeclInfo`. Every consumer calls `of`.
- `Cycles` treats `thunk` as **running**, not deferring (CK-34), and `function` as deferring.
- `Lower` defines and calls through the same answer, so the definition and the call agree (CK-33).
- `constrained_constant` keeps its scope, unannotated `pub` zero-parameter values, because the
  convention now makes every other form correct.

*Amended 2026-09-24 by R2b, which found these points the text above leaves open (the code is
`src/check/Convention.zig`):*

- **The column is the tag alone.** `DeclInfo.convention` is `enum(u8) { plain, function, thunk }`
  (byte 10 of the `decls` row, `dispatch_bytes` 3). The counts the union above carries are not
  repeated: the evidence is `requirements.len` and the arity `value_arity`, one source each.
  `dispatch_bytes` refuses a row whose convention is `plain` exactly when it has requirements, or the
  reverse. `of` takes `u32` counts and is exactly the three rules above: no evidence is `plain`;
  parameters, a `lambda` body or a non-zero `value_arity` is `function`; otherwise `thunk`.
- **An import has no `DeclInfo`**, so `Convention.ofImport` computes the answer with the same `of`
  from what the interface publishes: `Dispatch.extRequirementCount` and the arity of the scheme's
  body, **looking through `alias` terms** as `TypeStore.paramCount` does for the exporter (CK-84:
  `pub same : Pred a` with `type alias Pred a = a -> Bool` has arity 1 on both sides). It passes 0
  parameters and no lambda, and gets the exporter's answer, because a checked value's parameter
  count, and a lambda body's, is its type's arity. So the interface needs no convention column.
- **A caller's arity** (`Convention.Use.arity`) is the written parameter count when there is one and
  `value_arity` otherwise.
- **The readings are four functions**, and every consumer calls them rather than reading parameter
  counts:
  - `definition(convention, params, body_is_lambda)` → `constant` (plain, no parameters, not a
    lambda: `const f = value`), `params` (`($m…, p…) => body`), `lambda` (`($m…, x…) => e` for a body
    `\x… -> e`, with or without evidence — §8's narrow rule of `backend.md`), `applied`, and `thunk`
    (`($m…) => value`). **`applied`** is the zero-parameter `function` whose body is not a lambda:
    `($m…, $p1…$pn) => body($p1…$pn)` over `value_arity` fresh parameters, the body evaluated at each
    call. When the body is a reference to a constrained function of that arity (`h = maxOf`) the call
    goes straight to it, `maxOf($m$0, $p$1, $p$2)`, not through its eta-expansion.
  - `defers(definition)` for `Cycles`: only `params` and `lambda` defer. `constant` runs at load,
    `thunk` at every read (CK-34), and `applied` is a node that RUNS too (see the review amendment
    below).
  - `call(convention)`: `flat`, `f(ev…, args…)`, for `plain` and `function`; `applied`,
    `f(ev…)(args…)`, for a `thunk`. A thunk's type is not a function, so no checked program calls
    one; the answer is what its definition implies.
  - `referenceArity(use)` for a reference in value position, and for a `top`/`ext` evidence term:
    `null` is the bare name (`plain`), 0 the evidence applied (`thunk`, A.85), and `n` the
    eta-expansion over the arity (`function`, A.25).
- **`Edges` and `js/Reach` read none of these.** An edge is a reference whatever the callee's
  convention, and reachability does not depend on when a body runs, so neither needed a change;
  they are listed above because the brief assumed they did.
- **The wide form is a fifth reading** (spike §9.2, A.87): `derivedEvidence(count)` answers
  `positional` or `array`, and `max_positional_evidence` (4 096) lives in `Convention.zig`.
  `Lower.derivedArrow` and every caller that packs a derived function's evidence ask it; `Lower`
  keeps only the mechanics (the `$m` parameter and the array literal).

*Amended 2026-09-24 by the manager on R2b's review, before the code changed:*

- **`applied` RUNS for `Cycles`; the bullet above that makes `function` deferring is withdrawn for
  it** (review B1). `language.md` §7 states the initialisation rule over the SOURCE: a value
  written without parameters and without a `lambda` body is a VALUE, and may not be reachable from
  its own initialiser. A `where` is a type annotation; it must not change which programs are
  accepted. With `applied` deferring, `h = compose h g` under a `where` was accepted and overflowed
  the stack at its first call, while its twin without the `where` is `cyclic_value` — which is also
  what its twin would throw at load. So `defers` is true for `params` and `lambda` only, and a
  point-free member of a recursive group (`biggest = go` with `go` calling `biggest`) is refused
  exactly as without the `where`; written `biggest = \xs acc -> go xs acc` it defers. `Lower`
  still DEFINES an `applied` value as an arrow: only the cycle reading changed. Fixtures:
  `check/bad/EvidenceFunctionConstantCycle*.beni` (direct, mutual, partial application, through a
  lambda-valued declaration) and the accepted controls `run/EvidenceFunctionRecursionAccepted.beni`.
- **The `cyclic_value` message names the per-use case.** "A top-level value is computed once, when
  the module is loaded" is false for a `thunk` and an `applied` value, which are computed at each
  read or call; when the circle holds one, the message says so and names it. Other circles keep the
  old text byte for byte.
- **An `applied` body is evaluated at EACH CALL, and that is observable** (review S1): a
  `Debug.log` in it prints per call, and a table it precomputes is rebuilt per call, where the same
  value without the `where` computes it once. Kept for now and documented in `language.md` §6
  *Evaluation order*; `run/EvidenceFunctionBodyPerCall.beni` pins the count. Hoisting it once per
  call site is CK-85 (unassigned).
- **`constrained_constant` is narrowed to NON-function types** (review S3, rule 7). The bullet
  above keeping its scope assumed only unannotated `pub` values were at risk; an unannotated `pub`
  of function type (`pub equals = (==)`, `pub eqs = \a b -> a == b`, `pub bigger = maxOf`) is
  defined, called and imported as the function it is, so the refusal bought no guarantee. It now
  refuses only a zero-parameter unannotated `pub` whose type is not a function (a thunk). Spike
  §10.10 and the message's hint are amended with it.
- **`boundary.md` §4 check 4 reads `Convention`** (review S2): a `foreign`'s expected parameter
  count is `use.evidence + use.arity`, and "not a function" is `use.arity == 0`, so an alias-typed
  `foreign` is counted as its calls are made.
- **"Is the body a lambda" is asked in one place**, `Convention.bodyIsLambda`, and
  `Convention.definitionOf(dispatch, bir, decl)` is what `Cycles` and `Lower` read (review N2).
  `dispatch_bytes` also refuses a `thunk` row with a non-zero arity (N1), and the flat call sites
  that never meet a thunk (`receiverCall`, `typeDispatchExpr`, `applyEvidence`, `namedPartCall`)
  assert `Convention.call` is `flat` (N3).

---

## 13. The checker → backend contract

### 13.1 The record

`Dispatch` is rewritten (`check/Dispatch.zig`, about 600 lines), and is still flat, index-based,
per module and immutable once built.

```zig
pub const Term = union(enum(u8)) {
    param: struct { binder: Binder, k: u16 },
    top: struct { decl: Bir.DeclIndex, args: Range },          // Range into `args` (term indices)
    ext: struct { module: Graph.Index, value: Interface.ValueIndex, args: Range },
    derived: struct { index: u32, args: Range },
    ext_derived: struct { module: Graph.Index, type: Types.TypeId, kind: Derived.Kind, args: Range },
    primitive: Primitive,                                      // strict_eq | num_compare | char_compare | string_compare
    undetermined,                                              // §9.4's proven-undetermined default, lowered as
                                                               // today's structural answer (`Basics$eq`, or
                                                               // `num_compare` for compare). v2 writes it only on
                                                               // proof; v1's converter (R2) maps a legacy `err`
                                                               // PART to it, preserving today's bytes
    field,                                                     // a callee only
};
pub const Site = struct {
    inst: Bir.Inst.Index,
    callee: TermIndex.Optional,     // `method_call` / `type_dispatch` only
    evidence: Range,                // roots, one per requirement of the instantiated scheme, in order
};
pub const DeclInfo = struct { requirements: Range, convention: Convention, value_arity: u16 };
pub const LetInfo = struct { inst: Bir.Inst.Index, requirements: Range };   // D5 only
pub const Requirement = struct { quantified: u16, var_name: SymbolIndex, method: SymbolIndex };
pub const ContextEntry = struct { param: u16, method: SymbolIndex };
pub const Derived = struct {
    kind: Kind, shape: Shape,
    context: Range,                 // into `contexts`: its evidence parameters (D4); positional for shapes
    body: Range,                    // NOMINAL: one term per constructor argument position; else empty
};
terms: []Term, args: []TermIndex, sites: []Site (ascending inst), decls: []DeclInfo,
lets: []LetInfo (present and EMPTY from R2, so R14 owes no format bump — N6), requirements: []Requirement, contexts: []ContextEntry,
derived: []Derived (sorted by emitted name text, §8.5 of the spike), tries: []Try, symbols: []Symbol
```

**No `err` term exists.** A module with errors never reaches the backend. A module without errors
has every wanted answered (I6).

**`undetermined` is the one structural leaf, and it is not a hole.** v2 writes it only for a wanted
§9.4 *proved* undetermined. Its receiver is reachable from no scheme and quantified by no binder, so
no value of that type can reach the comparison except through a crash (`Debug.todo`, the payload of
an empty list).

During R2–R10, v1 still produces flat sites, and `Dispatch.finish`'s converter maps v1's `err`
**part** to `undetermined`. That is exactly how `Lower` answers such a part today, so emitted
JavaScript does not move in R2. It also keeps CK-20's wrong answer on v1 until v2 replaces v1. That
is deliberate: R2 changes the contract, not behaviour. v1's `err` **site** (not part) maps to no
term, and `Lower` refuses it as `internal`, as it does since row 75.

**`Dispatch.finish`** sorts `derived` and remaps indices, as today. It then walks every term and
asserts I7:
- `top d`: `args.len == decls[d].requirements.len`;
- `ext`: the interface value's requirement count;
- `derived`: `context.len`;
- `ext_derived`: the interface's published context length.

A violation is `internal` at the site.

*Amended 2026-09-24 by R2a, which found these points the text above leaves open:*

- **`DeclInfo` in R2a is `{ requirements, value_arity }`.** `convention` joins it in R2b with
  `Convention.zig` (§12.5), which is also when `dispatch_bytes` goes 2 → 3 (§14.3). `value_arity` is
  the parameter count of the declaration's solved type (`TypeStore.paramCount`), 0 for a
  non-function, filled by v1 and read by nobody until R2b.
- **`Binder` is `decl | let(inst) | derived(i)`.** `decl` carries no index: a site belongs to exactly
  one declaration, the one whose instruction range holds it, and a `param` term inside it names that
  declaration's `k`th requirement. `derived(i)` indexes the SORTED `derived` table.
- **The tree is acyclic by construction.** Terms are allocated in pre-order, so every argument's
  `TermIndex` is greater than its owner's. `dispatch_bytes` verifies exactly that on load, which is
  what lets every walker recurse without a depth guard against a corrupt table.
- **I7 also covers the roots.** A site on a `method_call` or `type_dispatch` has a callee; a
  `derived`/`ext_derived` callee carries its evidence as its own `args` and the site's `evidence` is
  empty, a `top`/`ext` callee has no `args` and `evidence.len` is its requirement count, and
  `primitive`, `field` and `param` take none. A site on a `call` has `evidence.len` equal to the
  requirement count of the Bir callee (a `top` or `ext_value` reference; 0 otherwise), and a site on
  a bare reference likewise for the value it names. A `method_call` or `type_dispatch` site with no
  callee, a v1 `err` site that the converter dropped, and a MISSING site where the Bir needs one
  (a `method_call` or `type_dispatch` with none, a `call` of a constrained callee with none) are
  violations too — the answer `Lower` gives, one phase earlier. **It is not "what `build` would
  say" everywhere:** `Lower` only meets the code DCE (`backend.md` §9) keeps, and the assert walks
  every declaration. So a v1 miscount (CK-30, CK-72, CK-76) in a declaration nothing reaches, which
  built and ran before R2a, is refused by `check` since R2a — `tests/pending/run/DeadMiscount.beni`
  is that program. The manager kept this on purpose (review of R2a, S1): the table is wrong whether
  or not it is emitted, and v2 removes the miscount itself.
- **The assert runs only on a module that reported no error.** A module with errors never reaches
  the backend, and v1 still leaves `err` sites in one; asserting there would add an `internal` to
  every `check/bad` golden that has a dispatch-bearing error. It therefore runs LAST in the
  module's check — after `fillInterface`, `reportTooDeep`, `Cycles` and the dispatch round trip —
  so an error any of those reports gates it too (review of R2a, S2; `check/bad/CycleNoEvidenceNoise`).
- **Which method an `undetermined` leaf answers** is the kind of the nearest enclosing `derived` or
  `ext_derived` term (or row, for a body position) — exactly the `kind` `Lower` threaded through
  `partValues` before R2a. An `undetermined` with no such ancestor is `internal` in `Lower`: v1's
  converter never writes one, because an `err` SITE becomes no term.
- **`Lower` asserts I7 again**, cheaply, with the same counting function (`Dispatch.requirementCount`),
  and its message is the old "hidden arguments do not add up".

- **During R2–R10 it is `internal` in every build, never a panic.** v1 has known miscounts that
  `check` accepts today: CK-30 is caught only by `build`. A Debug panic in `Dispatch.finish` would
  turn `check` of such a fixture into exit 134 and change the red reasons R0 recorded. R2 greps the
  corpus with the assert on before landing.
- **From R11 (v2 only)** a debug build panics, because a violation is then a v2 bug with no known
  exception.

*Revised 2026-09-24 (S10).*

### 13.2 `dump --stage=dispatch`, format v2

```
module <Name>
  decl <name> evidence=<n> convention=<plain|function|thunk>
    requirement <k> quantified=<q> var=<v> method=<m>
  let <inst> evidence=<n>                                   (D5 only)
    requirement <k> quantified=<q> var=<v> method=<m>
  try <inst> <maybe|result>
  derived <i> <eq|compare> <shape> context=<n>
    context <k> param=<i> method=<m>
    body <j> <term>
  site <inst> [callee <term>]
    evidence <term>
      <arg terms, indented two more spaces, recursively>
```

Terms print as:
- `param <k>` inside a declaration, `param let <inst> <k>` or `param derived <i> <k>` elsewhere;
- `top <decl>`, `ext <Module> <value>`, `derived <i>`, `ext_derived <Module>.<Type> <kind>`;
- `primitive <p>`, `undetermined`, `field`.

A tree is printed as a tree, so the pre-order-versus-index discussion of A.68 is gone. The existing
`tests/corpus/dispatch/` goldens are re-blessed **once**, in R2, when the format changes, and
reviewed against the old goldens one by one.

*Amended 2026-09-24 by R2a.* In R2a the `decl` line is `decl <name> evidence=<n> arity=<a>`, where
`arity` is `DeclInfo.value_arity`; R2b appends ` convention=<…>` when `Convention` exists, and
re-blesses the `decl` lines then. Every value declaration prints a `decl` line, in source order, as
in format v1, and a module whose table is entirely empty prints its `module` line alone. A term's
arguments print one per line, two spaces deeper than the line holding the term. A callee's OWN
arguments (a derived callee's evidence) print under the `site` line as `arg <term>` lines, before
the first `evidence <term>` line, so the two keywords keep them apart (review of R2a, N6); below
them, arguments are bare terms.

*Amended 2026-09-24 by R2b.* The `decl` line is now
`decl <name> evidence=<n> arity=<a> convention=<plain|function|thunk>`; every `tests/corpus/dispatch/`
golden moved in its `decl` lines and nowhere else, and `dispatch/Conventions.beni` shows all three.

### 13.3 What `Lower` changes

| Today (`js/Lower.zig`) | After R2 |
|---|---|
| `siteRangeOf`, pre-order reading with a cursor, `Site.parent` | `sites[inst]` gives the callee term and the evidence roots |
| `targetEvidence`, `externalEvidence`, `ownEvidence`, `valueEvidence`: recounting | deleted. A term's argument count is in the table; the callee's count is only asserted |
| `evidenceShapeOk` → "hidden arguments do not add up" | the I7 assert. Its message stays for the assert's `internal` |
| `partValue`'s `.err → Basics.eq / num_compare` | becomes the `undetermined` leaf's lowering: same output, a different input. There is no `err`, and a missing site where the Bir needs one is `internal` |
| `declaration`'s zero-parameter branch, `callExpr`'s flat call, `externalArity`, `targetArity` | one `Convention` (§12.5) |
| derived bodies from `Derived.parts` with `evidence k` leaves | from `Derived.body` with `param derived` leaves. Emitters unchanged |
| evidence parameters `$m$<k>` | unchanged for a declaration and a derived function. A `let` binder's are `$l<inst>$<k>` (D5), so an inner binder never shadows an outer `$m$k` it also captures |
| eta-expansion of a constrained value in value position (spike §8.2) | unchanged: computed from the term plus `Convention` |

`Edges.zig` and `js/Reach.zig` walk `sites` and nested `args` instead of flat sites plus `parts`.

### 13.4 What stays in the contract

The primitive table (spike §8.3), the naming and emission order (§8.5), every derived body emitter
(§9), the `?` rows, the operator pinning, and "the backend sees no types".

---

## 14. Publication

### 14.1 One routine (CK-13)

`check2/Publish.zig`: `publishScheme(root) → SchemeIndex` is the only way a solved type enters an
interface. In order it runs `hasError` (three-valued, budgeted, kept verbatim), `writer.add`, the
`too_deep` check, a report on failure, and `<error>` instead of a truncated scheme.

It serves value schemes, schema member types, schema constructor types and constructor terms
(`fillCtorTerms`). Its callers pass a region and a name, and nothing else.

### 14.2 Interface v3

`iface_bytes.format_version` 2 → 3, `Digest.digest_version` 1 → 2 (R3). The changes:

| Change | Why |
|---|---|
| `Type.arity: u16` (and `Types.Entry.arity`) | CK-38. A saturating `u8` cast becomes an error at 65 535 |
| constructor rows gain `result: enum { nominal, record_alias }`, and a `record_alias` row carries its **field names in declaration order** (a `SymbolIndex` range, argument `i` is field `i`) | CK-39. `Schemes.instantiateCtor` builds the record alias for the second. The names are what the backend needs to emit an imported alias's constructor as the record and to read its pattern's arguments (`backend.md` §4, D12); the alias body's record term cannot give them, because its fields are canonicalised and the constructor's argument order is the declaration's. *Amended 2026-09-24 by R1's review (S6).* |
| per exported nominal type, per `eq`/`compare`: `derived: { present, context: [](param u16, method SymbolIndex) sorted by (param, text) }`, or `absent: reason` | D4, I10: importers resolve `ext_derived` against the published context, and a cache hit installs it without recomputing |
| per exported nominal type: `payload_params: bitset over its parameters` (the parameters that occur in a constructor payload; all set for a `foreign type`) | D10 and S15: the marker walk descends only where a payload can hold a value, without reading an opaque type's constructors  Accepted consequence: a change in which parameters an opaque type's payloads use changes its interface digest (round 2 nit) |
| value `where` blocks | unchanged in bytes. `Evidence.requirements` writes them in the same order as today | (§12.1) |

R3 lands on the old checker, which writes contexts as "one entry per type parameter, method = the
derived method". That is exactly its ABI, so the format is shared by both checkers.

*As built by R3 (2026-09-25).* The points the table left open:

- **Where the rows live.** The per-type facts widen the `types` row (16 → 32 bytes: `arity: u16`,
  then `payload_params`, `eq` and `compare` as `extra` ranges and two status bytes) rather than
  adding a column: one row per exported type, sorted with it. They exist for every exported type;
  an alias's say `alias` and have no bitset. The constructor row grows 20 → 28 bytes (`fields`,
  `result`). `checker.md` §7's serialized-form table has the layout.
- **"Absent: reason"** is a status byte, one vocabulary (settled by R3's review, N1), decided in
  the order v1's eager pass decides (`Solve.deriveOneParts`), the first that applies:
  - `unchecked` — the module was never checked; `alias` — a type alias, not nominal;
  - `present` — the module emits the derived function;
  - `primitive` — §3.2's table answers the method with a JavaScript operator (`Int`, `Float`,
    `Char`, `String`, `Bool` both methods, `Order`'s `eq`; A.18). `Order`'s `compare` and
    `Never`'s two are derived, so `present`;
  - `own_method` — the type's module declares a `pub` value of the method's name: the type's own
    method or, under the module rule (§3.3 step 1), one for another type of the module;
  - `foreign` — a `foreign type` of ANY arity that neither of those answers: no body to derive over
    (A.55; `Schema.Conversion`, of two parameters, is one);
  - `function` — a function is reachable in a payload; `unanswerable` — a payload cannot answer the
    method for any other reason.

  v1 writes `present` exactly when its eager pass (A.23) put the row in
  its dispatch table, with that row's evidence count as the context, so the record states the ABI
  every `ext_derived` is already written against. Nothing in v1 READS the rows yet; R8a's importer
  does, and D4's inferred contexts change the entries, not the format.
- **`payload_params`** is computed from every constructor of the declaration through the
  annotation reader, so a parameter an ALIAS's expansion drops (`type alias Ph a = Int`) is not in
  a payload, and a parameter under a nominal application's argument is. A declaration too deep to
  read (already reported) sets every bit — "may hold a value" is the safe side of the marker walk.
- **The 65 535 error** is a new code, `too_many_type_parameters`, reported by lowering at the
  65 536th parameter (`language.md` §10). The declaration keeps its first 65 535, so no `u16` below
  it ever saturates. Lowering's duplicate-parameter check was pairwise, 35 s of a Debug build at
  that width; it sorts now.
- **`Schemes.Writer` on epoch marks** (CK-41): a slot of the memo is live while its stamp is the
  current epoch, a new scheme is one increment, and the arrays grow at least ×2. The CK-41 scenario
  is the first promoted into `test-perf` (`plans/checker-rewrite.md` §2.5).
- **A gap this table does not close — CK-89.** The rows exist per EXPORTED type, but `==` in an
  importer can reach a PRIVATE type through a `pub` scheme (`pub make : a -> Hidden a`, then
  `A.make 1 == A.make 1` in another module — v1 answers it with `ext_derived` to `A`'s own derived
  function). "Importers resolve `ext_derived` against the published context" has nothing to
  resolve against there. R8a must publish a context for every type a `type_refs` row of the record
  names (the set the dependency digest already uses), or decide otherwise, before v2 reads the
  rows. *The manager assigned it to R8a (2026-09-25): this section is amended first, so the rows
  cover every nominal type reachable from a published scheme, before R8a reads them.*

### 14.3 Cache and table versions

- `dispatch_bytes` 1 → 2 (R2a, the tree record with `DeclInfo.value_arity`), then 2 → 3 (R2b,
  `Convention`). *Amended by R2a: `value_arity` rides with the tree record, as §12.5 and the R2a brief
  say; only `convention` is left for R2b.*
- `entry_bytes` 2 → 3 (R2a).
- The schema plan stays 1.
- A version mismatch is a miss, as today (`fast-compiler.md` §8.3).
- **The checker is part of the cache key, R4–R11** (S22). v1 and v2 write the same entry format
  into the same `.beni-cache`. After R8, D4 gives a derived function a different evidence ABI
  under v2, so a warm cache must never mix one checker's output with the other's callers.
  - From R4a, the compiler-identity component of the cutoff key (`cache/Key.zig`) includes the
    checker id, `v1` or `v2`.
  - R12 removes the component together with the flag. A single checker needs none, and the build
    id already changes with the binary.
  - A "warm under v2" result in R10 is therefore written by v2 by construction.
  - *As built by R4a:* the id is the text `v1` or `v2`, written as `checker_len: u32, checker`
    right after the build id in every module's own-terms blob, core's included, and `key_version`
    is 3 (`fast-compiler.md` §8). `--cutoff-compare`'s transitive key shares the blob, so it moves
    with the flag too.
  - *R9 note (R4a review, N5):* the text `v2` means "v2 checks the root package, v1 checks `core`"
    from R4a to R8, and "v2 checks everything" from R9. A `--cache-build-id` pins the build id
    across that change, so R9 must also change the id text (say `v2c`) or bump `key_version`.
    Otherwise a `core` entry v1 wrote under `v2` could be read by a v2 that checks `core`.

---

## 15. Diagnostics and recovery

### 15.1 One emit path, `quiet` once (CK-14)

`Report.emit(diagnostic)` is the only way to append to a module's diagnostics. It:

- drops the diagnostic if the module is `quiet`;
- stamps the declaration attribution;
- sets the failure bit (§15.2) if the severity is `error`.

Schema errors, `verifyReads` and `internalAlways` go through it. The 37 hand-written guards are
gone. `Session`'s `quiet[m]` counts errors only (CK-12, R1).

### 15.2 Failure is state (I12, CK-11)

`decl_failed: DynamicBitSet` over declarations. The reporter sets the bit of the declaration being
solved, which is the frame's current member, or the wanted's `origin` declaration for resolver
errors. At the group's boundary, if any member failed, **every member** of the group is marked,
because they share variables. **Groups merged by §10.4 are one group for this rule:** a failure
anywhere in the merge marks every member of every merged group (N11). P7 exhaustiveness and the P9
plan gate read the bits. Nothing tests
a diagnostic's region against an instruction range.

### 15.3 Stable texts

Every diagnostic code keeps its code and its text, except:
- the CK entries whose fix is the text: CK-48 to CK-59;
- `rigid_mismatch`'s escape variant (§8.3);
- `try_shape`'s legs (§8.6);
- `infinite_type`'s rendering (§8.2).
- the D14 hint on its `type_mismatch` (§10.7), written in R7;
- the nesting-budget hint on `nesting_too_deep` (§10.2), written in R7;
- a derived-context variant of `private_method`, written in R8b. Spike §10.2's text says "`x.<m>` cannot reach it", but `[ M.t1 ] == [ M.t2 ]` in another module names no `.m`, so the variant names the type and the derived shape that reached it. *(Round 4, S4-2.)*

`method_needs_annotation` is retired except for §11.2's one case (§10.5). Exact wordings are written in
the slice that changes them, blessed there, and reviewed:
- **R4**: the escape and cycle rendering, CK-01 and CK-57 (S20);
- **R5**: `?` legs;
- **R6**: `.where_clause` and `.method_signature`;
- **R7**: the recursive-dispatch hint;
- **R13**: the rest.

### 15.4 Regions and categories

- The resolver reports at `w.origin`, the instruction in this module (spike §6.2's promise).
  `s.region` is gone (CK-48).
- Unification categories gain `.where_clause`, `.method_signature` and `.try_leg(enclosing |
  subject | error)`. Their messages name the clause or leg (CK-55, CK-51).
- The module-rule clash hint is printed only when the module declares at least two types and the
  method's first parameter names a different one (CK-52). CK-49, CK-50, CK-53, CK-54, CK-56, CK-58,
  CK-59 and CK-60 are R13's, written against this reporter.

---

## 16. Exhaustiveness, cycles and the schema plan

- **`Exhaustive.zig` is kept verbatim.** Only its gate input changes, to failure bits. CK-61
  corrects `checker.md` §6.6's sentence about solved types.
- **`Cycles.zig`** is adapted to `Convention` and the tree walk. Its algorithm and messages are
  unchanged.
- **The schema plan** is built in P9 after `Cycles`, gated on "no error in the module", and reads
  endpoint properties from the §11 memo.

---

## 17. Determinism (rule 5)

Unchanged across modules: ids before threads, one writer per slot, concatenation in graph order.
Within a module, every order the checker chooses is one of these:

- SCC order, tie-broken by source;
- demand order for nested checking (§10.2), which is the order of the demanding constraint nodes, a
  function of the source;
- ascending `WantedId`, which is creation order, a function of the tree walk, which is a function
  of the source;
- name text for fields, requirements and contexts (I13).

The `--jobs=1` versus `--jobs=8` determinism test and the matrix test run under `--checker=v2` from
R9 (§22).

---

## 18. Performance

**Budget.** `fast-compiler.md` §2 asks for more than 250k LOC/s per core for checking. At
`7427828` the check phase of `zig build bench -- --generate=100000` runs **55.2 ms**, about 1.8 M
LOC/s. The diary's last entry (2026-09-24 00:17) records the dispatch-heavy medians the rewrite is
held to, ReleaseFast, `--self-profile`, median of 7:

| Program | ms |
|---|---|
| `s_tup6000` | 21.7 |
| `s_int6000` | 15.7 |
| `gen` | 76.0 |

**Rule.** v2 must be ≤ 1.10× each of those at R9 (the `test-v2` parity slice) and at the cut-over
(R11). It must be linear on the three perf scenarios (CK-40, CK-41, CK-42). R12 re-measures after
v1 is deleted.

**What gets cheaper**

- No speculative probes (`TargetProbe`, `localMethodAcceptsApplication`, commit copies).
- No repeated capability settles: up to eight per module today.
- No per-group schema settling.
- No site-list copying on join (aliases instead), and no quadratic `siteOrigins`/`appendSite`
  de-duplication.
- An O(1) own-name index instead of linear scans.
- Epoch marks instead of memsets.

**What gets dearer, and how it is bounded**

- **Occurs at every binder** (§8.2). One walk per `binders_end` node or boundary, over the binders'
  reachable graph (`structural`), with a shared epoch, so each node is visited once per walk. Nested
  `let`s and nested lambdas revisit outer structure once per nesting level, the same cost Elm pays.
  R4 measures three things:
  - `bench`;
  - a 5 000-lambda flat scenario;
  - **a nested scenario**, 200 `let`s deep, each binding a 50-field record type built from the one
    above it. This is the quadratic case (S4). If it exceeds 3 % of the check phase, the fallback is Elm's exact placement, occurs only
  on binders whose variable was unified since the last boundary, which the journal can tell.
- **`Walk.owned` yields constraint method types, and attaching lowers them (I15).** A variable's
  `wants` is almost always empty, so the cost is one branch. An attachment walks a two- or
  three-node method type.
- **The settle loop** (§8.1) re-runs until nothing changes. Each iteration after the first is
  triggered by a default (§8.1 step 3), so there are at most three iterations of O(pool) each. Eager
  draining after each constraint node is linear in the number of readied items.
- **Obligations ride on their variables** (§4.5). Each is attached once, readied at most once and
  closed at most once.
- **Rank adjustment runs once per settle iteration** (§8.1 step 2). A second iteration happens only
  after a default, and there is at most one round of defaults per `?`. In practice there are at most
  two iterations.
- **The I15 debug assert** checks only what the boundary's own generalisation walk meets, so it is
  linear even in Debug, and cannot flake the performance ratios (S-new-6).
- **Elaboration (P6)** is linear in sites plus terms.
- **The derived-context fixpoint** iterates at most (#params × #methods) times per type-level SCC,
  and the typical SCC has one type and one iteration.

---

## 19. What is kept from the current code

| Piece | Decision | Notes |
|---|---|---|
| `TypeStore.zig`: union-find, Rémy rank, journal, `extra`, roots-only access | **adapted** | `Flags.wants`; epoch marks; `Snapshot` per §7.5 |
| `Solve.unifyFlat`, `unifyRecord` (four-way merge-join), `unifyAlias`, kind lattice | **adapted** | dispatch arms removed; `Result` returned; normalised records; text-ordered failure |
| `Solve.call` and the arity suite (`checker.md` §8.3) | **verbatim** | |
| `Solve.generalize`, `adjustRank`, pools | **adapted** | `Walk.owned`; §8.3 check; switch for rule (a) until R14 |
| `makeCopy` / `copyHelp` | **adapted** | constraint method types through the same memo (they are children); wanteds created by I5 |
| `occurs` (iterative three-colour) | **adapted** | `Walk.structural`, epochs, returns the cycle path |
| `Constrain.zig` per-form rules | **rewritten**, rules verbatim | split into three files; §6.2–§6.5 changes |
| `Solve.zig`'s ~3 000 dispatch lines, and `Types.zig`'s capability walk | **rewritten** | `Resolve`, `Instances`, `Evidence` |
| `Types.Builder` (annotation and `where` reading) | **adapted** | produces givens |
| `Types` session table | **adapted** | capability fields deleted; `arity: u16` |
| `Schemes.zig` writer and reader | **adapted** | `Evidence.requirements` order; derived contexts; ctor result kind; epochs |
| `Check.zig` driver: scheduler, core gate, `claim`/`compareKey`/`publish`/`install`/`verifyReads` | **moved verbatim** into `Driver.zig` and `Incremental.zig` | `install` loses its capability rebuild and reads published contexts |
| `ModuleCheck.run` | **rewritten** | §5's phases |
| `fillInterface`, `fillCtorTerms`, `hasError`, round trips | `hasError` and round trips **verbatim**; the rest into `Publish.zig` | |
| `Dispatch.zig` | **rewritten** | §13 |
| `Exhaustive.zig` | **verbatim** | gate input only |
| `Cycles.zig`, `Edges.zig` | **adapted** | `Convention`, trees |
| `Render.zig` | **verbatim**, plus cycle rendering | |
| `Diagnostics.zig` texts | **verbatim** except §15.3; reporter core **rewritten** | `Report.zig` plus message files |
| `Schema.zig`, `SchemaPlan*.zig` | **adapted** | properties from the §11 memo; plan in P9 |
| `reads.zig`, `Command.zig`, `InterfaceTerms.zig` | **verbatim** | |

### 19.1 The target layout of `src/check2/`

Renamed to `src/check/` at R12. No file over about 1 500 lines.

```
check2/
  Check.zig          ~300   public API: run, Module, Options (same shape as today's)
  Driver.zig         ~700   DAG scheduler, core gate (moved)
  Incremental.zig    ~600   cutoff key, claim, publish, install, verifyReads (moved)
  Module.zig         ~600   §5's phases
  TypeStore.zig     ~1000
  Walk.zig           ~400   structural and owned successors, lowerTo, DFS, occurs, recordRow, epochs
  Unify.zig          ~900
  Generalize.zig     ~450   pools, adjustRank, generalise, generality check
  Instantiate.zig    ~350   copy, scheme instantiation, evidence creation (I5)
  constrain/Expr.zig ~800   constrain/Pattern.zig ~500   constrain/Decl.zig ~600
  Solve.zig          ~900   tree walk, boundaries, calls, obligations, `?`
  Groups.zig         ~450   SCCs, effective status, frames, nesting at demand, merge (§10)
  Resolve.zig       ~1100   wanteds, givens, drain, promotion, lineage
  Instances.zig      ~800   module rule, well-known table, matching, derived contexts, privacy, marker walk
  Evidence.zig       ~500   tables, canonical order, elaboration
  Publish.zig        ~500
  Report.zig         ~400   emit path, quiet, failure bits
  Types.zig          ~900   session type table (capability fields gone)
  shared, unchanged path: Exhaustive, Cycles, Edges, Render, Diagnostics (texts), Schemes,
  Schema*, reads, Command, InterfaceTerms, Dispatch, Convention
```

Until R12, `check2` imports the shared files from `src/check/` and does not copy them.

---

## 20. External contracts

### 20.1 Stable (the corpus is the oracle)

- **CLI.** Every command and flag. The one addition is the hidden, test-only `--checker=v1|v2`,
  which exists R4–R11 and is deleted at R12.
- **Dump stages.** `tokens`, `ast`, `bir`, `types`, `interface` and `graph` keep their text
  formats.
- **Diagnostics.** Every diagnostic code, the JSON diagnostic format, exit codes and streams.
- **Emitted JavaScript**, except §20.3.

### 20.2 Changed on purpose

| What | When | Version |
|---|---|---|
| `dump --stage=dispatch` format (§13.2) | R2a | — |
| the `Convention` column (§12.5) | R2b | `dispatch_bytes` v3 |
| `dump --stage=raw` gains the §14.2 columns | R3 | — |
| dispatch table bytes | R2a | `dispatch_bytes` v2, `entry_bytes` v3 |
| interface record | R3 | `iface_bytes` v3, digest v2 |
| texts of §15.3 | R5, R6, R13 | — |
| `method_needs_annotation` retired | R7 | — |

### 20.3 Emitted JavaScript that changes

1. **Derived functions of parametric types whose context is not "every parameter, same method"
   (D4).** A phantom parameter loses its parameter, and a nested requirement gains a
   different-method parameter. `emit/Derived*` goldens are reviewed individually at R11. `Maybe`,
   `Result`, `List` and every type that compares each parameter do not change.
2. **Every CK fix.**
3. **`let` evidence parameters (D5, R14).**

### 20.4 Existing fixtures whose expectations change

These change at the slice named, and are re-blessed with review, never in bulk:

| Fixture | Slice | Why |
|---|---|---|
| `tests/corpus/dispatch/*` | R2 | the format |
| `check/bad/MethodNeedsAnnotation/` | R11 | D3: becomes a `run/` fixture that prints the answers |
| `check/bad/PriorityGroupSpecializedPayloadEq/` | R11 | its refusal is re-derived without priority groups. Expected to stay a refusal, with a new region |
| `run/DerivedEqInPriorityGroup/` | R11 | must still pass. Only its intent comment changes |
| `check/bad/LetConstrainedTwice.beni` | R14 | D5: `show` generalises; the diagnostic becomes whatever `Int`/`String` lack (`unknown_method render`) |
| `check/bad/LetHelperCyclicReceiver` | R14 | D5: the program is valid. It becomes `run/LetHelperCyclicReceiver` |
| `abuse_test.zig`'s row-76 scenario | R14 | expects exit 0 within the bound |

---

## 21. Decisions

All **taken by the owner on 2026-09-24** ("go with the recommendations"). Each names the spec text
it changes, and the slice that writes that change where this document does not already.

| # | Decision | Rationale | Spec change and slice |
|---|---|---|---|
| **D1** | **Private methods answer dispatch only inside their module.** Derived functions the module emits may use them. *(Amended: that means structural shapes derived in the module; see the D1 round-4 row of §21.1.)* Any wanted from another module that reaches one, directly or through derivation, is `private_method` | Coherence: the same two values never compare differently in two places. The refusal protects no-silent-wrong-answer (rule 7), and `pub` is always available | §11.3 here; `static-dispatch-spike.md` §3.3 and A.63, pointer now; R8 implements |
| **D2** | **`?` is a deferred obligation**, decided when either side is concrete, defaulting to `Result` only at the enclosing declaration's boundary | The greedy order refuses valid programs (CK-06) and protects nothing | §8.6; `checker.md` §6.5, pointer now; R5 |
| **D3** | **No annotation is ever required on a method for ordering reasons.** Own untyped methods are deferred (§10). `method_needs_annotation` is retired | The refusal was an implementation ordering limit, not a guarantee (rule 7). Roc shows the deferral works | §10; `static-dispatch-spike.md` §10.12 and §6.3.1 step 4, pointer now; `language.md` §10 catalogue marks the code retired in R7 |
| **D4** | **A derived function takes one evidence parameter per entry of its inferred context**, not one per type parameter | Closes row 73 (CK-25) and the phantom case (CK-23), and it is smaller output. The emitted ABI is unchanged for every type that compares all its parameters | §11.2; `static-dispatch-spike.md` §9.4 and A.20, pointer now; interface v3 (R3); R8 |
| **D5** | *(Amended 2026-09-24, round 2 S-new-4: read the D5 row of §21.1, which states the HM(X) rule. The text that follows is the original wording.)* | **D5** | **A constrained `let` binding is generalised when every variable its requirements reach is its own**. Rule (a) is retired, and levels keep outer-receiver requirements monomorphic. Let binders get evidence parameters `$l<inst>$<k>` | HM(X) is sound here once I2 holds, and rule (a) protected no guarantee (rule 7). Row 76's trigger disappears | §8.4, §13; `static-dispatch-spike.md` §6.4, §11 and A.30, pointer now; `backend.md` §4's constrained-declaration row gains `let` in R14 |
| **D6** | **Build v2 in parallel** (`src/check2`, hidden `--checker=v2`), with the old checker as the oracle, then switch and delete | §22 | `checker-rewrite.md` |
| **D7** | An annotation escape is reported as **`rigid_mismatch`**, with no new code | It is a rigid mismatch against an outer variable. The Elm-style text is enough | §8.3 |
| **D8** | A float literal pattern gets a dedicated message under **`unexpected_token`**, with no new code | The grammar already excludes it (`language.md` §3). Only the message was wrong | `checker-rewrite.md` R1 |
| **D9** | The **`number` bridge** exists only for `eq`/`compare` on a `number`-kinded variable, and unifies the declared method type first | Keeps today's ABI (no evidence for `number`) while checking `where` clauses (CK-21) | §9.3 |
| **D10** | The `equatable` marker walk descends into **payloads**, not type arguments | "Comparable exactly when everything it can hold is", which is the message's own promise | §11.4 |
| **D11** | A **dispatch back-edge merges** the groups on the nested stack into one mutually recursive group | The ML rule. The only sound alternative is an annotation, which D3 rules out | §10.4 |
| **D12** | The **record-alias constructor** emits the record literal, keys in canonical order | Elm's semantics (`language.md` §0) | `backend.md` §4 row, written in R1 |
| **D13** | **Pending fixtures** live in `tests/pending/` with the corpus layout, and are run by `zig build test-pending`, not by the gates | Rule 4: never commit red | `checker-rewrite.md` §2 |
| **D14** | **Canonical pessimism in recursive groups** (§10.7). In a value SCC of two or more members, or a merged group, a method call or obligation whose receiver is group-level at its constraint node has its method type lowered to the group's rank, even when it resolves inline. The resulting `type_mismatch` carries a hint naming the member to annotate. *Taken 2026-09-24 by the manager under the owner's standing instruction to take the recommendations (review round 3, B-3, option (i)); flagged to the owner.* | Rule 7: the refusal buys I9's order-independence, a guarantee, and annotating a member lifts it. Without it, `sccA` and `sccB` are accepted in one order and refused in the other | §10.7, I9 restated; R7 |

### 21.1 Amendments of 2026-09-24, from the design review

The owner's instruction was "go with the recommendations", so these amendments stand as decided.
Each one records what changed and why.

| Decision | Amendment | Rationale |
|---|---|---|
| **D2** | "The enclosing declaration's boundary" means **the boundary that owns the obligation's variables**: the `?`'s target's own generalisation boundary, which may be a `let` (§8.6). The default happens inside that boundary's settle loop, as a last resort | S3. Under D5 a `let` generalises, and deciding its `?` later would unify generalised variables |
| **D3** | `method_needs_annotation` survives for **one non-ordering case**: a derived instance whose context depends on an in-flight inferred method of the group being checked (§11.2). The refusal is the same in every declaration order, and an annotation always lifts it | S1. A derived instance is not a group member, so there is no monomorphic reading of it. A mixed fixpoint over inference and derivation is not worth its complexity for this rare shape. Rule 7 is kept: a named escape hatch, and no silent wrong answer |
| **D9** | The `number` bridge applies to a **flex or rigid** of kind `number`. It is a row of §9.2's receiver table, applied when the wanted is first drained, and always unifies the method type first | B4. Without the rigid case, `core` (`abs`, `max`, `min`) and `run/DecodeInto` do not check. v1 has it at `Solve.zig:2750-2753` |
| **D10** | "Payloads" is made checkable across modules by **`payload_params`** in interface v3. A `foreign type` has all parameters | S15. An imported opaque type's payloads are not in its interface |
| **D11** | **Value back-edges merge too.** (Round 1 wording, superseded by the round-2 row below.) Nested checking happens at the innermost boundary that drains a wanted, not only at top level, and it checks the value-dependency prefix first. The Roc comparison and the two-types example are recorded in §10.6, with a hint on the resulting `type_mismatch` | B6, B7, S17. Top-level-only pinning made results order-dependent, and a nested group's value dependencies were unchecked. v2 is stricter than Roc on purpose, because Roc's laziness is order-dependent |
| **D2** (round 2) | Whether a `?` default is due is read on **adjusted** ranks: §8.1 step 2 runs before step 3. A top-level frame merged into another never defaults; its root does | N2, N4. Stale young ranks defaulted an escaping `?` to `Result` too early, and a merged frame defaulted before the root's facts arrived |
| **D3** (round 2) | The surviving `method_needs_annotation` case is narrowed to a derived context entry **indexed by a type parameter** that depends on an in-flight method. A closed payload contributes nothing and is filled like a group call | S-new-1. The broader refusal guarded nothing (rule 7) |
| **D14** (round 4) | D14 is stated over **every wanted resolved or attached** on a group-level receiver (a method callee, instantiation evidence, a sub-wanted), and every variable of an obligation with a group-level deciding variable. It is checked in `Resolve`'s single resolution function. `R` is the member's own top-level frame rank. The hint names the member **syntactically** (the reference that produced the receiver's value), or else every unannotated member, sorted by text | R7-1, R7-2, S4-1. The round-3 rule missed evidence and sub-wanteds (`evA`/`evB`, `subA`/`subB` were order-dependent), and its hint depended on union-find class membership |
| **D1** (round 4) | A private method is still the module's method for **every** type the module declares (the module rule is unchanged by privacy). "Derived functions the module emits use it" covers structural shapes derived in the module. The module's other nominal types have no derived `eq`, and comparing them is the module-rule clash | R0 found the round-1 text contradicted §3.3 step 1. `7427828` already behaves this way |
| **D8** (round 4) | Elm's `exposing (T(..))` also gets a dedicated message under an existing code: **`expected_token`** at the `(` after the type name, suggesting `exposing (T, Ctor1, Ctor2)` (`language.md` §5.2). Later uses of the unexposed constructors stay quiet. *As built by R1 (2026-09-24): every unknown constructor in that file stays quiet, not only `T`'s — lowering is per file and cannot tell which names are `T`'s constructors, and resolution, which can, finds only silent error instructions. No guarantee is lost: the file already fails, and a misspelt constructor is reported once the import is corrected.* | CK-47. Same reasoning as D8: the grammar already refuses it, and only the message and the cascade were wrong |
| **D5** (round 2) | Generalisation is plain HM(X) on levels. A young receiver's promoted requirement may mention outer variables free. I15 binds only receivers that are not generalised | S-new-4. The round-1 wording contradicted `adjustRank`, and I15 |
| **D11** (round 2) | **Nesting happens at demand**, not at a boundary. **Only top-level frames merge**, and every `let` frame generalises at its own boundary. **A reference to an annotated binding is never a back-edge**. It instantiates the scheme (§6.6) | N3, N5, N8. Boundary-time nesting was still order-dependent; merging `let` frames was order-dependent; treating annotated members as in-flight killed polymorphic recursion that v1 accepts. The at-demand design also deletes parking, pinning and prefix closures |

---

## 22. Migration

**Recommendation, adopted as D6: build the new checker in parallel.** The choice was between
building it beside the old one and replacing the old one in place, slice by slice.

The parallel build wins, for four reasons:

1. **The old checker is the only complete oracle.** 289 black-box cases, about 580 fixtures and
   the determinism and matrix tests encode what the checker must keep doing. With both checkers
   runnable on the same input, every difference is either a CK entry, which is listed, or a v2 bug.
   Replacing in place loses the comparison the moment the first piece is swapped.
2. **The architecture does not decompose into swappable pieces.** Unify-without-resolution,
   wanteds, elaboration and deferral each change the interface between `Unify`, `Solve` and the
   dispatch code. An in-place sequence would build and then delete adapters at every step. That is
   the accretion this rewrite exists to end.
3. **The three gates stay meaningful.** Until the cut-over they run v1, which only improves (R1–R3
   land fixes in shared code). v2 is held to `test-v2` and `test-pending` at every slice (§22.2),
   and they become part of the gates' meaning at the switch.
4. **Precedent.** rustc's next-generation trait solver shipped behind `-Znext-solver`. The test
   suite and crater ran under both until parity, then the default flipped.

**Its costs, stated.**
- Two checkers co-exist for about eight slices.
- Shared code (`Lower`, `Dispatch`, interfaces, `Cycles`) has to serve both. R2 and R3 therefore
  make the **contract** change on v1 first, so v2 targets a contract that already exists and that
  v1 already produces.
- Pending fixtures fixed only by v2 wait in `tests/pending/` until the cut-over, protected by
  `tests/pending/CLAIMED`.

**Amendment of 2026-09-25 (the owner): v1 is frozen.** The owner does not require `master` to keep
working during the conversion. v1 is kept only as the **oracle**: it checks `core` and the
dependencies, so the corpus goldens keep running as v2 grows. It is **frozen**: no further fixes
or features land on v1, and its remaining bugs are fixed by v2 only. v1 is deleted as soon as v2
can check `core` and pass the corpus (R9–R11). This narrows reason 3 above: the gates stay
meaningful because v1 stops changing, not because R1–R3-style fixes keep landing on it.

### 22.1 The switch

- **R4–R8.** `--checker=v2` checks the **root package** with v2 and **every non-root package** with v1:
  `core`, and platform packages such as `Node` (N4). The `--core` corpus fixtures, which make their
  own module part of `core`, therefore still run v1 under `BENI_CHECKER=v2` before R9. They are
  listed in `tests/pending/v2-expected.md` as "not yet v2" rather than counted as passes (N13). Both read and
  write the same interface format, so the black-box corpus can run against v2 before v2 can check
  `core`.
- *As built by R4a:* "the root package" is `SourceStore.Package.app` without `--core`
  (`check2/Check.zig`'s `Options.usesV2`). A module an earlier phase already reported on, or one
  the graph poisoned, is checked silently by v2 as by v1 (`checker.md` §4.3), so R4a's stub reports
  `not_implemented` only on the root modules that reach it clean.
- **R9.** `--checker=v2` covers every package including `core`, and `test-v2` becomes strict.
- **R11.** The default flips.
- **R12.** v1, the flag and `check2`'s name are deleted.

### 22.2 How v2 is held between slices

| Step | Runs | Mode |
|---|---|---|
| `zig build test-v2` | the whole `tests/corpus/` with `--checker=v2` | **report** (R4–R8): pass/fail per fixture, exit 0. **strict** (R9–R11): must be all green except the listed expected-difference fixtures |
| `zig build test-pending` | `tests/pending/` under v1 and v2 | fails if a fixture is green under the default checker (promote it), or if a fixture in `tests/pending/CLAIMED` is red under v2 |

*As built by R4a:* report mode is not quite "exit 0". It skips the fixtures of
`tests/pending/v2-expected.md`, and it FAILS for a red fixture listed in
`tests/pending/v2-green.txt` (the ratchet, S12), or for a line of either file that names no
fixture the walk runs (`checker-rewrite.md` §2.4). The scenarios of `pending_test.zig` run under
the default checker only.

Both are part of every rewrite slice's exit criteria (`checker-rewrite.md`), beside the three
gates.

---

## 23. What is not settled

These are honest uncertainties for the implementing slices, not open owner decisions.

1. **The merge rule of §10.4 has not been exercised on real code.** The argument is the ML rule,
   but the frame bookkeeping (handing pools downwards, lowering ranks) is new. R7's reviewer must
   check it against a permutation scenario over at least 4 mutually dispatching own methods, and
   against Roc's `type_checking_integration.zig:10490-10530` shapes.
2. **The occurs cost at binders (§18)** is unmeasured on beni. The fallback is stated.
3. **The proven-undetermined default (§9.4)** is today's `settleUndetermined` with a sharper
   precondition. Which existing fixtures exercise it is unknown until R6 runs the corpus.
4. **Interface v3's context rows for `core`.** `core`'s derived types (`Maybe`, `Result`, `Order`)
   get contexts equal to today's ABI. That must be confirmed by `emit/` goldens not moving in R8.
5. **Schema endpoints in the fixpoint (§11.5)** depend on S3/S4 of `schema.md`, which have not
   landed. R8 covers S2's check-only endpoints, and later schema slices must use `Instances`, not
   add a property pass.
6. **The constraint edges of `Walk.owned`, and I15's lowering on attach, are new relative to both
   Elm and Roc** (§3). No shipped checker treats method types as level-carrying graph edges this
   way. R4 and R6 must prove on the corpus that I15 never lowers a variable a program needed to stay
   polymorphic. The known costs are D5's outer-receiver case (CK-02), where it is the point, and
   nothing else yet. The R6 reviewer runs the I15 assert over `bench/corpus`.
7. **Nesting at demand (§10.2) departs from Roc**, which nests only at group boundaries. The
   soundness argument is in §10.2: a nested group shares no variable with the open frames except
   through a back-edge. The prior art closest to it is Roc's own nested check, which the design
   copies, but at a different point.
8. **D14's merge argument (§10.7)**, "whether a node is inside a recursive group is a function of the
   member's own body prefix", is argued, not proven. R7's permutation scenario must include 3-cycles,
   and a member that demands the cycle at two different nodes.
. **The joint derived-context fixpoint (§11.2)**, with its approximation-or-fresh rule and memo
    replay, is new. R8a's reviewer checks the well-foundedness argument against `xm`, `cbA` and a
    cross-unit chain.

## 24. Revision trace: the design review of 2026-09-24

Every item of `review-design.md` and where it landed. "Disagree" rows say why.

| Item | Resolution |
|---|---|
| **B1** `children` makes constrained variables cyclic | §4.1 two successor functions; I2 restated; §3 Roc citation corrected; §8.2 and §11.4 use `structural`; §23 item 6 |
| **B2** constraint edges alone do not close CK-02 | I15; `lowerTo` on attach (§7.1); §4.1 note |
| **B3** occurs before the unifying steps | §8.1 rewritten as a settle fixpoint, then occurs over binders and unified variables, then generalise; I16 |
| **B4** no `number` bridge for rigids | §9.2 table; §9.3 step 2 moved; D9 amended (§21.1) |
| **B5** in-place writes survive rollback | §4.2 journalled `WantUndo`; §7.5; I14 restated with the entry-point assertion |
| **B6** pinning to top-level rank | §10.2 rewritten: park on the innermost frame, nest at its boundary, pinning retired; §10.6 example; D11 amended. *Superseded in round 2 (N3): nesting is at demand; see §24.1.* |
| **B7** nested checks ignore value dependencies | §10.2 `checkNested` checks the value-dependency prefix; value back-edges merge (§10.3, §10.4); `Groups.value_deps`. *Superseded in round 2 (N3): the prefix check is "nest on first reference".* |
| S1 derived query blocked on the current group | §11.2: never memoised while blocked; blocked-on-self → `method_needs_annotation` (D3 amended); the fixpoint's own frame; assert |
| S2 member requirement lists | §12.3: lists from each member's own scheme; three cases; assert |
| S3 D2's boundary | §8.6; D2 amended. R5's reviewer focus corrected in `checker-rewrite.md` |
| S4 CK-04 diagnostics | §6.3 `binders_end` occurs at the lambda or branch end, which keeps `infinite_type` ×2; §18 nested measurement |
| S5 bridge placement | with B4 |
| S6 rescanned obligations | §4.5 per-rank buckets; I3. *Superseded in round 2 (N1, S-new-2): obligations ride on their variables.* |
| S7 infeasible slice claims | `checker-rewrite.md`: CK-08, CK-09 (`.beni` with `==`) and CK-11's v2 check move to R6 |
| S8 R1 depends on R2 | `Convention` moved to R2 (§12.5); R1 → R2 strictly ordered |
| S9 R1's CK-17 fix | `checker-rewrite.md` R1: make v1's walk growable, not `.unknown` → refusal |
| S10 I7 assert on v1 | §13.1: `internal`, never a panic, R2–R10 |
| S11 environment leaks into gates | `checker-rewrite.md` §2.4 |
| S12 no ratchet in report mode | `checker-rewrite.md` §2.4 `v2-green.txt` |
| S13 wrong-reason passes | `checker-rewrite.md` §2.4–§2.5: red signatures, permutation asserts, best of 3 |
| S14 lineage | §9.5 rewritten: equal-root repeat is `infinite_type`; root identity |
| S15 D10 across modules | §11.4, §14.2 `payload_params`; D10 amended |
| S16 rank of P2's rigids | §5 P2, §6.6, §8.3 |
| S17 D11 vs Roc | §10.6; hint; fixture in R7 |
| S18 stale invariant numbers | `checker-findings.md` CK-10, 14, 18, 26, 35 corrected |
| S19 normative scope | Status line |
| S20 R4 messages | §15.3 |
| S21 `?` speculation | §7.5: no longer speculative; §8.6 |
| S22 cache not keyed by checker | §14.3 |
| N1 | `checker-findings.md`: CK-10 is K3; new class K15 (specification drift) for CK-61 |
| N2 | `checker-findings.md` CK-22 program annotated |
| N3 | §7.3 wording |
| N4, N13 | §22.1 |
| N5 | §4.1 text order for everything shown |
| N6 | §13.1 `lets` present and empty from R2 |
| N7 | §4.2 `origin` optional plus `origin_decl` |
| N8 | `checker.md` §6.7 sentence fixed now |
| N9 | `language.md` §10 pointer note added |
| N10 | §12.1 discovery order; R6 byte-comparison criterion |
| N11 | §10.4, §15.2 |
| N12 | §11.2 worklist |

### 24.1 Round 2 (`review-design-2.md`)

| Item | Resolution |
|---|---|
| **N1** obligation extras escape generalisation | §4.5: obligations ride on their variables; all variables of one obligation share one rank (I15 extended); `owned` yields them. Program: CK-68 |
| **N2** `?` default reads stale ranks | §8.1 is now settle (no defaults) → adjust ranks → defaults on still-rank-`r` obligations → loop; §8.6; D2 amended. Program: CK-62 (`n2try`) |
| **N3** settle-time nesting order-dependent | §10 rewritten: **nesting at demand**. Deleted: parking, park lists, pinning, settle-time nesting, the value-prefix closure, `Groups.parked` and `value_deps`. Program: CK-63 (`n3box`) |
| **N4** merged frames default early | §8.1 and §10.4: a merged frame runs steps 1–2 and hands down, with no defaults; debug assert. Program: CK-65 (`n4ambm`) |
| **N5** merged `let` frames | §10.4: only top-level-kind frames merge. Program: CK-65 (`n5sw`) |
| **N6** journal-segment occurs | §8.1: an append-only `touched` log with per-frame start; §7.1 |
| **N7** group variable outside the caller's scheme | §12.3 case 3 → `undetermined` by parametricity; §9.4 promotes per member. Program: CK-66 |
| **N8** annotated recursion | §6.6: every reference to an annotated binding instantiates its scheme and is never in-flight or a back-edge; only the body sees the rigid instance. Program: `run/AnnotatedPolymorphicRecursion` guard |
| S-new-1 | §11.2 narrowed (closed payload filled like a group call); D3 amended; programs CK-67 (valid) and CK-69 (refused) |
| S-new-2 | §4.5, §8.1: obligations readied through their variable; defaults applied in one batch |
| S-new-3 | §4.4 effective status via union-find root; §10.4 |
| S-new-4 | §8.4 restated as HM(X); I15 restricted; D5 amended |
| S-new-5 | §9.1: one `ready` queue, drained by the innermost settle step |
| S-new-6 | I15 assert bounded to the boundary's own walk; §18 |
| S18 (still open after round 1) | now edited in place in `checker-findings.md` (CK-10, 14, 18, 26, 35), plus the erratum table |
| Nits | `checker.md` §5 and §6.5 notes updated; prefix closure moot (deleted); D11 hint prints the cycle from the smallest name by text (§10.6); `payload_params` puts an opaque type's phantom-ness in its digest, which is accepted and noted in §14.2 |

**Round-2 correction to the reviewer's programs.** Several of them used a nullary dot-call
(`(Box x).size`, `(K u).makeBox`). beni parses that as a **field access**
(`static-dispatch-spike.md` §11), so v1's refusal of them is correct. The fixtures use `.size ()` and
a `u` parameter. Two also used Elm's argument order for `Maybe.withDefault`, where beni's is
subject-first. Both behaviours were re-checked on the v1 binary.

### 24.2 Round 3 (`review-design-3.md`)

| Item | Resolution |
|---|---|
| **B-1** shared `ready` queue | §9.1: one queue per top-level frame and per fixpoint frame; each frame drains only its own; eager draining after every constraint node; §8.1 step 1; §10.4's demand-chain premise now justified. Programs: `rq1` (CK-73), `rq2` (guard), the merge variant (CK-73 fixture) |
| **B-2** re-entrant derived query | §11.2: a fresh fixpoint on re-entry; terminates by nesting. Program: CK-74 (`other = (T 1).key "s"`, both orders) |
| **B-3** I9 inside recursive groups | **D14** (§10.7, §21), option (i), with a hint. I9 restated with its three rules; §10.5 rewritten. Programs: CK-72 (`sccA`/`sccB` refused with the hint in both orders), guard `run/RecursiveGroupAnnotatedReceiver` (annotated form), guard `capt` |
| S-1 | §10.2: a `checkGroup` that returns merged sends the demand down the in-flight path |
| S-2 | §11.2: explicit rank and pool for `Instantiate` |
| S-3 | §8.1: one `touched` list per frame; reversed-chain perf scenario in R7 |
| S-4 | §10.2: one cumulative recursion budget across nested frames, `nesting_too_deep` with an annotation hint; explicit stack rejected, with reasons; generated deep-chain scenario in R7 |
| S-5 | `checker-rewrite.md`: R4 split into R4a and R4b; R4b includes obligation-free constraint generation; its subset excludes obligation forms |
| S-6 | §11.2: memo generations |
| S-7 | §17 demand order; §18 settle-loop cost; §5 P4 skips `done` groups; the §21 D5 row points to its amendment |
| N-1 | I14: a probe never nests |
| N-2 | §10.4: the no-nesting-after-default assert also covers `let` frames |
| N-3 | §4.5: only result variables' closures are lowered; R5 reviewer test |
| Slice sizing | `checker-rewrite.md`: R2a/R2b, R4a/R4b, R6a/R6b, R8a/R8b; the CK → slice index updated |

### 24.3 After R0 (2026-09-24)

| Item | Resolution |
|---|---|
| CK-22's inside fixture was ambiguous | D1 amended (§11.3, §21.1): the module rule is unchanged by privacy, so a private `eq` is the method of every type the module declares. `run/PrivateEqInsideModule/` is a v1-green guard |
| CK-37's fixture depended on which cycle check fires first | §9.5 pins it: eager draining makes the resolver walk first; one `infinite_type`; the cycle's root is poisoned; a non-cycle rejection flags one method and does not poison. Both are v1's behaviour, so both fixtures are guards |
| CK-71 (R0: `Session` ids depend on thread timing) | assigned to R1: merge interners in path order |
| CK-47's code | D8 amended: `expected_token` at the `(`, confirmed |
| CK-73's merge-variant `.iface` | wrong under D14. The fixture is split into a D14 `check/bad` and a `check/good` without the `q` helper |

### 24.4 Round 4 (`review-design-4.md`)

| Item | Resolution |
|---|---|
| **R4-1** Snapshot and routing | §7.5: the Snapshot records every open frame's `ready`/`touched` lengths. Per-frame lists stay contiguous, which S-3's bound needs, and the cost falls only on failure probes. §9.1: rows carry `frame` and `seq`; routing is by creation frame; a merged frame drains its own queue until hand-down. §4.5's stale "one queue" is fixed |
| **R7-1** D14 misses evidence and sub-wanteds | §10.7 restates D14 over every wanted resolved or attached, and over all of an obligation's variables, in `Resolve`'s one resolution function; I9 rule (3) restated; D14 amended (§21.1). Programs `evA`/`evB`, `subA`/`subB` (`checker-rewrite.md` §5.6) |
| **R7-2** the hint's member depended on order | §10.7: syntactic naming by the introducing reference, falling back to the text-sorted unannotated members |
| **R7-3** the nesting budget | §10.2: budget = 2 × one declaration; admission requires one full declaration's worth left, so the refusal is always at the demand with the hint; `nest_cost` is a counted constant calibrated in Debug; fixpoint frames charge it; the "thousands" claim is corrected and the exception added to I9 |
| **R8-1** fresh-on-re-entry did not terminate | §11.2: a fixpoint's own payload queries read its approximation; fresh only when a group frame lies above it; a real well-foundedness argument (group frames are unique and bounded; cross-unit chains follow a DAG) |
| **R8-2** per-method fixpoint was unsound | §11.2: the unit is (type-level SCC) × {`eq`, `compare`}, iterated jointly. Guard `xm`/`xm2` |
| **R8-3** closed in-flight branch skipped the merge | §11.2: the method-type check is an ordinary wanted in the asking frame, so it merges via §10.3/§10.4; memo-generation hits replay it. Programs `cbA`/`cbB` |
| S4-1 | §10.7: `R` is the member's own top-level frame rank |
| S4-2 | §15.3: D14 hint, nesting hint, and derived `private_method` variant added |
| S4-3 | §9.5: the backstop counts resolution steps per module, cumulatively |
| S4-4 | §9.1: one creation sequence `seq` across wanteds and obligations |
| S4-5 | `checker-rewrite.md` R6a: "privacy" means spike §1.2's direct `private_method` only; D1's reach through derivation is R8b's |
| N-4 | spike §3.3 note and the §21 D1 row now say "structural shapes" |
| N-5 | left to R0's `CLAIMED`/`RED` notes (R0's region); flagged in the report |
